// SPDX-License-Identifier: Apache-2.0

// Conduck
// InAppAudioRecorder.swift
//
// Owns the in-app mic recording flow for the iOS conversation
// thread (`ContentView` → `ConversationThreadView`). Composes
// existing infrastructure:
//   - `AudioRecorder` (Services/AudioRecorder.swift) for capture
//   - `AudioCompressor` (Services/AudioCompressor.swift) for M4A compression
//   - `STTClient.shared.transcribe(...)` for the foreground STT round-trip
//   - `PendingRetryStore` for reactive save on retryable failure
//
// Why no `PendingRetryGuard` here: this recorder runs entirely in-app on
// the main actor — there is no SiriKit-style OS-kill risk between
// `startRecording` and `stopAndUpload`. The mic-button flow is interactive,
// the user is watching the spinner; a transient STT failure goes through
// `PendingRetryStore.save()` reactively in the error path so the retry
// card can surface, but we don't need the preempt-save + deferred
// notification dance that `TranscribeIntent` uses (mirrors the macOS
// rationale: no silent auto-retry — fast-fail with a visible retry).
//
// The WORK lane (`retryDestination == .work`, the desk's own voice sheet and
// the Mac menu bar) runs a second, two-phase settlement over the same capture,
// and THE WORDS ARE THE ONLY THING IT EVER PUTS ON THE DESK. Phase one PARKS
// the compressed recording in `PendingRetryStore` — a device-local, non-syncing
// App-Group file — and reserves it. Phase two publishes the transcript as a
// words-only card through `WorkVoiceCaptureCoordinator.publishTranscript`, then
// deletes the recording. So a refused key, an offline device or an abandoned
// request leaves the bytes parked and the desk empty, which is exactly what the
// retry card is offering: nothing half-finished appears on the board, and no
// voice note ever rides the person's private CloudKit as a desk card.
//
// A Work capture may also carry a SCREENSHOT — the region dragged before the
// microphone came up — and it is a card of its own, published through
// `WorkVoiceScreenshotCoordinator` ahead of the recording. The bytes are STAGED
// until Stop rather than published at the drag, so one Esc still gets out of an
// accidental capture with nothing on the desk; and once there is a capture id
// they go out first, because a picture held only in memory is the one artifact
// a crash between Stop and the desk can destroy.
//
// The two artifacts answer separately. Either may be owed while the other is
// finished, each retries on its own terms, and a refused picture never costs
// the parked recording or the words. What it does cost is the CAPTURE: a picture still
// owed leaves the capture unfinished and retryable at EVERY exit — silence and
// a missing key included, which are terminal for the words and say nothing
// about the picture — answering with `.workScreenshotWriteFailed`, keeping its
// queue entry as the only place those bytes survive this process, and letting
// `workCaptureFacts` say artifact by artifact what actually landed.
//
// The other direction is not symmetrical: a PARK that fails and a desk write
// that fails are both retryable errors, never a quiet fall back to text. A park
// that fails is not durable — the bytes are in this process's memory and
// nowhere else — so the capture stays pending with whatever it achieved and
// finishes only when a card owns the words, because a Work capture that reports success
// with no card behind it has turned a recording into composer text nobody asked
// for. Chat captures are untouched by all of it: their transcript IS the
// artifact, and a conversation has no card to hold bytes.
//
// `PendingRetryStore` is a QUEUE keyed by capture id, so arming can never cost
// another capture its recording. What this class still owns is the LIFETIME of
// its own entry: it arms only while a capture is genuinely unfinished, and it
// RELEASES that entry the moment the capture completes or the person starts
// over — an answered capture left queued is one the retry card offers to
// re-transcribe. It lets go of a capture only once a replacement microphone is
// actually live, so a refused start leaves the previous capture's Try Again
// exactly where it was, and it releases only the entry it armed itself: one
// armed by an earlier process belongs to whichever surface recovers it.
//
// That last rule is enforced by a RESERVATION, not by an id comparison alone.
// The desk's voice sheet and the app's retry card are reachable on one screen
// and read the same queue, so "the entry I armed" and "the entry nobody else is
// finishing" are different claims: a Try Again reserves the capture before it
// touches the recording and refuses when another surface holds it, and every
// clear goes through that reservation so a completed capture can never delete a
// recording somebody else is mid-transcription on.

import Foundation
import AVFoundation
import Observation
import Speech
import os.log

/// What a capture surface does to the retry queue, named as ONE seam.
///
/// It refines `PendingRetryQueueWriting` — arming and the durable write — with
/// the RESERVATION half, because a surface that finishes a capture has to be
/// able to prove the capture is still its own. An id-keyed clear cannot: the
/// desk's voice sheet and the app's retry card are reachable on one screen, so
/// a sheet that let go of "its" entry by id could delete the recording the card
/// was in the middle of transcribing.
///
/// It exists as a protocol for the same reason its parent does:
/// `PendingRetryStore.shared` is a process-global singleton over one App-Group
/// file every capture test in the bundle shares, and what these surfaces assert
/// is WHICH capture they reserve, hold and release — a property of the surface,
/// not of the wire format.
/// The three answers a reservation request can have, kept apart because two of
/// them demand opposite behavior and `claim(id:duration:)` returns nil for both.
///
/// A capture that was never queued leaves the bytes in hand as the only copy of
/// what somebody said, so its retry must go ahead. One another surface is
/// holding must be refused, or two surfaces transcribe one recording and attach
/// different words to the same card. Collapsing them is how a PARTIAL save —
/// the sidecar and the audio written, the screenshot's write throwing — became
/// an entry the queue adopts, that nobody's local bookkeeping knows about, and
/// that every surface therefore believes is theirs alone.
nonisolated enum PendingRetryReservation: Sendable {
    /// Reserved, with the claim to renew and release.
    case claimed(PendingRetryClaim)
    /// Nothing is queued under this id — or its recording is unreadable, which
    /// the store finishes exactly as `claimNext` does.
    case absent
    /// Queued, and somebody else's reservation is live over it.
    case heldElsewhere
}

nonisolated protocol PendingRetryLaneReserving: PendingRetryQueueWriting {
    /// Reserve exactly the capture named, for the surface that ARMED it.
    /// Nil when it is not queued, when another reservation is live over it, or
    /// when its recording cannot be read.
    func claim(id: UUID, duration: TimeInterval) async -> PendingRetryClaim?

    /// The same reservation, with a refusal that says WHY — in one pass under
    /// the store's own lock, so the two answers cannot swap between a claim and
    /// a follow-up question.
    func reserve(id: UUID, duration: TimeInterval) async -> PendingRetryReservation

    /// Extend this holder's reservation by the horizon it was granted.
    @discardableResult
    func renew(_ claim: PendingRetryClaim) async -> Bool

    /// Does this claim still hold its capture? Reads only.
    func confirmOwnership(_ claim: PendingRetryClaim) async -> Bool

    /// Give the capture back unfinished — the entry and its recording stay.
    func release(_ claim: PendingRetryClaim) async

    /// Finish exactly the capture this claim holds, and nothing else.
    @discardableResult
    func clear(_ claim: PendingRetryClaim) async -> Bool

    /// Retire just the parked SCREENSHOT of the capture this claim holds, now
    /// that a card owns the picture. The entry, its recording and its verdict
    /// stay: the words may still be owed.
    ///
    /// It is a separate operation from `clear` because the image file is not
    /// merely a copy — it is the EVIDENCE the expiry sweep reads to decide the
    /// entry still shelters the only picture of something. Left behind after
    /// publication it exempts that capture from the clock for ever, so the one
    /// surface that knows the picture landed has to say so.
    @discardableResult
    func discardWorkImage(_ claim: PendingRetryClaim) async -> Bool

    /// Write onto the entry what this holder has OBSERVED about the capture it
    /// is finishing — the words, once a provider has produced them, and the
    /// verdict on whether the desk holds them. Metadata only: the recording is
    /// not rewritten and no other capture is touched.
    ///
    /// It is what parks paid-for words before the desk write that follows them,
    /// so a death in that gap costs a store round trip and not a transcription.
    @discardableResult
    func recordPublicationState(
        _ claim: PendingRetryClaim,
        transcript: String?,
        publicationState: PendingRetryPublicationState
    ) async -> Bool

    /// Retire just the RECORDING of the capture this claim holds, now that the
    /// desk holds its words. The entry stays, because the screenshot parked
    /// beside it may still be the only copy of itself.
    ///
    /// The words are the artifact; the recording is waste the moment they land.
    /// An entry that keeps both goes on sheltering audio on a container the
    /// parked picture exempts from the clock, which is the recording outliving
    /// the words it produced.
    @discardableResult
    func retireRecording(_ claim: PendingRetryClaim) async -> Bool
}

extension PendingRetryLaneReserving {
    /// A lane that cannot tell the two refusals apart says so by answering
    /// `absent` for both — the shape a double that never queues anything is
    /// right about, and the shape the real store OVERRIDES. Only a store that
    /// reads the queue and the lease under one lock can distinguish them, and
    /// only it is on the path where the distinction decides whether a second
    /// surface may transcribe somebody else's recording.
    func reserve(id: UUID, duration: TimeInterval) async -> PendingRetryReservation {
        if let claim = await claim(id: id, duration: duration) { return .claimed(claim) }
        return .absent
    }

    /// A lane that parks no screenshot has none to retire, and answering
    /// "nothing was retired" is the honest reply. The store overrides it; this
    /// default is what lets a lane double that never stores image bytes conform
    /// without pretending to delete any.
    @discardableResult
    func discardWorkImage(_ claim: PendingRetryClaim) async -> Bool { false }

    /// A lane that keeps no record of its own restates nothing, and says so.
    /// Every caller of these two reads the answer and carries on — parking the
    /// words is worth one round trip and is never worth failing a capture over,
    /// and a recording no lane parked is one no lane has to retire.
    @discardableResult
    func recordPublicationState(
        _ claim: PendingRetryClaim,
        transcript: String?,
        publicationState: PendingRetryPublicationState
    ) async -> Bool { false }

    @discardableResult
    func retireRecording(_ claim: PendingRetryClaim) async -> Bool { false }
}

extension PendingRetryStore: PendingRetryLaneReserving {}

extension PendingRetryClaim {
    /// This reservation with the parked recording dropped: the same capture,
    /// the same token, and nothing any store operation reads.
    ///
    /// WHY AN ARMING LANE HOLDS THIS AND NOT THE CLAIM AS ISSUED. `claim(id:)`
    /// answers with the bytes, because a surface that SELECTED a capture out of
    /// the queue needs them to finish it. A lane that ARMED the capture already
    /// holds those bytes — it recorded them — so retaining the store's copy for
    /// the span of the work is a second recording of up to
    /// `Constants.maxAudioSize` beside the first, in an App Intent process that
    /// has to survive a speech hop. Everything a holder does with a reservation
    /// — `renew`, `release`, `clear`, `confirmOwnership`,
    /// `recordPublicationState` — reads the capture id and the token and
    /// nothing else, so the copy buys nothing.
    ///
    /// It lives beside `PendingRetryLaneReserving` because both arming lanes —
    /// this recorder and `PendingRetryGuard` — hold a reservation this way, and
    /// the vocabulary for that belongs in one place.
    var reservationOnly: PendingRetryClaim {
        PendingRetryClaim(
            entry: PendingRetryEntry(
                audioData: Data(),
                metadata: entry.metadata,
                workImageData: nil
            ),
            token: token
        )
    }
}

/// State of an in-app mic capture session. View models drive UI off this.
enum InAppAudioRecorderState: Equatable {
    case idle
    /// `startedAt` is the capture's start instant — a STABLE value set ONCE,
    /// NOT a ticking elapsed. The `mm:ss` display derives elapsed from it inside
    /// a leaf `TimelineView` (`LiveRecordingStatusIndicator`), so `state` no
    /// longer mutates 10×/sec. The old `.recording(elapsed:)` re-published every
    /// 0.1s, which re-evaluated the whole composer (a sibling of the heavy chat
    /// `ScrollView`) and drove the macOS layout-recursion freeze.
    case recording(startedAt: Date)
    case processing
    /// Self-heal in place: the active Apple on-device model isn't installed, so
    /// the composer is downloading it before transcribing the SAME recording.
    /// `nil` = indeterminate (request spin-up, before any progress reports);
    /// `0…1` once the AssetInventory download reports a fraction. NOT a re-record
    /// — the compressed audio is held in hand and transcribed the moment the
    /// model lands. (Apple-in-process path only; cloud providers never enter it.)
    case preparingVoice(progress: Double?)
    case error(AppError)

    static func == (lhs: InAppAudioRecorderState, rhs: InAppAudioRecorderState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle), (.processing, .processing):
            return true
        case (.recording(let a), .recording(let b)):
            return a == b
        case (.preparingVoice(let a), .preparingVoice(let b)):
            return a == b
        case (.error(let a), .error(let b)):
            return a.errorCode == b.errorCode
        default:
            return false
        }
    }
}

/// In-app mic recorder. `@MainActor @Observable` so SwiftUI views can bind
/// to `state` directly without an `@Published` Combine bridge.
@MainActor
@Observable
final class InAppAudioRecorder {
    /// Current state — view binds to this and renders mic button / spinner / bubble.
    private(set) var state: InAppAudioRecorderState = .idle

    /// Terminal-result hook for the DURATION-CAP auto-stop path (Part 1e). When
    /// the recorder hits `Constants.maxAudioDuration` it stops itself and runs
    /// the STT round-trip internally — but a mic-tap stop returns its result to
    /// the view via `stopAndUpload()`, whereas an auto-stop has no caller to hand
    /// the result to. Without this hook the capped capture's transcript was
    /// silently discarded (never reached the composer). The host (`ContentView`)
    /// assigns this to route an auto-stop into the same success handler as the
    /// mic-tap path, so a capped recording POPULATES the field rather than
    /// vanishing. Default nil → standalone use (previews/tests) just drops it.
    var onAutoStopResult: ((Result<String, AppError>) -> Void)?

    /// Recovery routing is frozen when the recorder is created. Existing Chat
    /// composers use the default; capture surfaces that promise inert Work
    /// storage opt into `.work`, so a later retry can never cross into an agent
    /// send path.
    let retryDestination: PendingRetryDestination

    /// The Work desk card that owns this capture's words. Nil until the words
    /// are published — this lane puts nothing on the desk before then — nil for
    /// every Chat capture, and nil for a Work capture whose words turned out to
    /// have nowhere to land. Only then may the host hand the words to its own
    /// composer: a publication that could not be written is a retry, not a text
    /// fallback. Cleared once a replacement recording is actually live, so a
    /// second capture can never claim the first one's card and a refused start
    /// never strands the first one.
    private(set) var workRecordingMaterialID: UUID?

    /// The Work capture this recorder is still holding: its bytes, the card it
    /// published (nil while publication is owed) and the words recovered for it
    /// (nil while they are owed). Non-nil exactly while a Work capture has not
    /// finished, which is what `retryWorkCapture()` finishes and what the sheet
    /// offers a retry for. Nil for every Chat capture.
    private(set) var pendingWorkCapture: VoiceCapture?

    /// True while there is a Work capture left to finish. The affordance that
    /// reads it must ALSO ask whether the error is retryable: a missing API key
    /// leaves a published card owing words that the same tap cannot get.
    var canRetryWorkCapture: Bool { pendingWorkCapture != nil }

    #if !os(watchOS)
    /// What a Work capture actually achieved, artifact by artifact.
    ///
    /// A capture can produce up to three things and publish them in three
    /// separate writes, so "it worked" and "it failed" are not the states this
    /// lane has — every combination is reachable, and a surface that renders
    /// one sentence for a `Result` will sooner or later say something untrue
    /// about the rest. A picture on the desk beside a recording the store
    /// refused, and a recording with words beside a picture that never landed,
    /// are both ordinary outcomes here.
    ///
    /// So the recorder states the facts and the surface composes the sentence.
    struct WorkCaptureFacts: Sendable, Equatable {
        /// A card owns the AUDIO. False for every capture this lane makes —
        /// the recording is parked, never published — and true only where the
        /// words landed on a legacy recording an earlier build had already put
        /// on the desk.
        var recordingOnDesk: Bool
        /// The words are on the desk as a card, which is this lane's whole
        /// output. Nothing else it produces is a publication.
        var wordsOnDesk: Bool
        /// This capture carried a picture at all. False for every capture from
        /// a surface that stages none, which is what keeps a receipt from
        /// naming a missing screenshot nobody took.
        var screenshotStaged: Bool
        /// The picture's envelope was accepted by the durable inbox. That is
        /// the point past which it is no longer this process's to lose — and
        /// it is NOT the point at which it is a card: the drain that imports it
        /// runs afterwards and is best-effort, so a queued picture may still be
        /// waiting for the foreground observer.
        var screenshotQueued: Bool
        /// A card carrying the picture is standing on the desk, confirmed by
        /// reading it back. Only this may be described to a person as saved.
        var screenshotOnDesk: Bool
        /// A lookup confirmed that card at least once. It is what separates a
        /// picture the drain has NOT imported yet from one a person imported
        /// and then deleted: both are queued-and-not-on-the-desk, and only the
        /// first is still coming.
        var screenshotEverOnDesk: Bool

        /// The picture is durable and its card has not appeared yet. The only
        /// state in which anything may be said to be on its way — a picture
        /// that arrived and was deleted is not coming back, and saying so
        /// promises a card that will never appear.
        var screenshotImportPending: Bool {
            screenshotQueued && !screenshotOnDesk && !screenshotEverOnDesk
        }

        static let none = WorkCaptureFacts(
            recordingOnDesk: false,
            wordsOnDesk: false,
            screenshotStaged: false,
            screenshotQueued: false,
            screenshotOnDesk: false,
            screenshotEverOnDesk: false
        )
    }

    /// The Work capture in hand, or the last one this recorder finished. Reset
    /// to `.none` at every mint, on `cancelRecording()`, and when a replacement
    /// recording takes the microphone; updated at each publication step, so a
    /// surface reading it mid-capture sees what has landed so far rather than a
    /// prediction.
    private(set) var workCaptureFacts: WorkCaptureFacts = .none
    #endif

    /// One capture in flight, and what it has already achieved. Both phases key
    /// off `id`, and both are idempotent under it, so re-running either after a
    /// failure repairs the capture instead of duplicating it.
    struct VoiceCapture: Sendable {
        /// ONE identity for this capture, minted before anything durable is
        /// written. It names the desk card the WORDS become AND is the id the
        /// pending-retry record carries, so a retry hours later answers with
        /// that same card instead of publishing the recovered words a second
        /// time.
        let id: UUID
        /// The compressed bytes. The desk's copy is taken from these, never
        /// from the file below.
        let audio: Data
        let format: AudioFormat
        /// Where this capture's transcription copy is written. Named with the
        /// capture rather than at the moment of writing, so every failure path
        /// hands the retry lane one URL for one capture; the file itself exists
        /// only for the length of the speech hop.
        let transcriptionFileURL: URL
        /// When this capture came into being. Stable, and stored rather than
        /// read at the moment of use, because the screenshot's card is
        /// published from it and a capture may publish that card more than once
        /// — here, on an in-process retry, and from the durable record in
        /// another process. A `Date()` at each of those sites would date one
        /// picture three ways.
        let createdAt: Date
        /// The picture that was dragged before this capture started, moved in
        /// at the moment the capture was minted. It stays here until it is a
        /// card of its own: a Work capture's two artifacts are published
        /// separately, and this one exists nowhere else until it lands.
        var screenshot: Data?
        /// True once those bytes have been ACCEPTED by the durable inbox, which
        /// is the moment they stop being this process's only copy — not the
        /// moment a card exists, which the desk read alone can answer. Debt is
        /// measured against this rather than against the card, because a queued
        /// envelope the drain has not imported yet is nobody's to publish
        /// again: the foreground observer finishes it.
        ///
        /// The screenshot's own verdict, and it says nothing about the
        /// recording — the two publish independently, so either may be owed
        /// while the other is finished.
        var screenshotQueued = false
        /// The desk card this capture's WORDS landed on, once they have. It
        /// names the words-only card in every ordinary case, and a legacy
        /// recording an earlier build published in the one case where the seam
        /// found such a card standing at this id and wrote the words onto it.
        /// Nil is the state of every Work capture until phase two answers.
        var materialID: UUID?
        /// True once phase two has ANSWERED for these words — published them as
        /// a card, or written them onto a legacy recording standing at this
        /// capture's id. Both are final, so a resumed capture must not ask
        /// again: the question is a throwing store write, and its failure would
        /// report a desk error for a capture whose words were settled minutes
        /// ago.
        var transcriptSettled = false
        /// The desk has ANSWERED that this capture's card is gone — a card
        /// published here and then deleted, on this device or another. It is
        /// remembered on the capture because `materialID` is only a memory of a
        /// write, and a resumed capture that re-derived presence from it would
        /// report a card the desk has already denied.
        var recordingConfirmedGone = false
        /// The words, once speech recognition has produced them. Retained so a
        /// retry that owes only the publication does not spend a second round
        /// trip on the same bytes for the same answer.
        var transcript: String?

        /// True while this capture still carries a picture no card holds. What
        /// the retry republishes, what the durable record has to carry, and
        /// what keeps a capture whose words already landed from being retired.
        var owesScreenshot: Bool { screenshot != nil && !screenshotQueued }

        #if !os(watchOS)
        /// The picture card this capture's RECORDING belongs to, or nil when
        /// this press took no picture at all.
        ///
        /// Two facts, not one: bytes still in hand, OR an envelope the inbox
        /// has already taken. Either says a picture belongs to this press, and
        /// neither on its own covers the whole flow — phase 0 runs before phase
        /// one, so by the time the recording publishes the picture may already
        /// have left for the queue. Testing only the bytes would still be true
        /// today (nothing clears them), but it would make the link depend on a
        /// field this file is free to clear; testing only the flag would lose
        /// every capture whose picture never reached the queue at all, which is
        /// exactly the failure the link is meant to survive.
        ///
        /// A PROMISE ABOUT IDENTITY. It is the id the picture takes, derived
        /// from this capture's own id, whether or not the picture is a card
        /// yet: a retry that lands the picture tomorrow needs no repair,
        /// because the recording already names it.
        var attachedPictureID: UUID? {
            guard screenshot != nil || screenshotQueued else { return nil }
            return WorkVoiceScreenshotCoordinator.materialID(forCapture: id)
        }
        #endif

        init(
            id: UUID,
            audio: Data,
            format: AudioFormat,
            screenshot: Data? = nil,
            createdAt: Date = Date()
        ) {
            self.id = id
            self.audio = audio
            self.format = format
            self.screenshot = screenshot
            self.createdAt = createdAt
            self.transcriptionFileURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("conduck-inapp-\(id.uuidString).\(format.fileExtension)")
        }
    }

    #if CONDUCK_TESTING
    // TEST SEAMS — the three things this class cannot have on a simulator: a
    // microphone, a speech provider, and a desk store that is not the founder's
    // own. WHY THEY MUST EXIST: the ordering this class guarantees — the
    // recording is a durable, readable card BEFORE speech recognition is
    // attempted, and a failed recognition leaves that card standing — is
    // invisible to any test that cannot stand between the two phases, and no
    // assertion outside this process can. Each is nil in every other build, and
    // the whole block compiles only under `CONDUCK_TESTING`.

    /// Stands in for the microphone's bytes.
    var capturedAudioForTesting: Data?

    /// Stands in for the speech hop, called at the instant the real one would
    /// begin — after the card exists and the transcription copy is on disk, so
    /// a stub can assert both and then refuse.
    var transcriptionHopForTesting: (@MainActor (URL) async -> Result<String, AppError>)?

    /// The desk store the Work lane publishes into.
    var workStoreForTesting: ConversationStore?

    /// Stands in the gap between a SUCCESSFUL recognition and the write that
    /// puts its words on the card — the window "Cancel transcription" covers
    /// last and the one no other seam can reach.
    ///
    /// The hop seam above ends where the provider does, and the cancel checked
    /// there is the one this lane already had. What it cannot express is a press
    /// that lands after the answer is in hand: the publication suspends (the
    /// store's first-use load, then its own queued write), and a check taken
    /// only before that suspension answers about a moment that has passed.
    var transcriptAttachPauseForTesting: (@MainActor () async -> Void)?

    #if !os(watchOS)
    /// Stands in for the App-Group capture queue the screenshot rides through.
    /// `WorkCaptureInbox.shared` is one directory in the founder's own
    /// container that every capture surface in the process publishes into, and
    /// what these cases assert is what THIS recorder publishes and in which
    /// order — a property of this class, not of that directory.
    var workInboxForTesting: WorkCaptureInbox?

    /// Stands in for the image pipeline the screenshot is normalized by.
    /// `ImageProcessor` answers nil for bytes it cannot decode, which is every
    /// fixture a unit test can invent, so without this seam the publication
    /// under test would return "nothing publishable" before it ever reached the
    /// queue. It also stands exactly where the picture's publication BEGINS,
    /// which is the one place a test can read the desk back and see that the
    /// recording is not on it yet.
    ///
    /// `@MainActor` like the speech-hop seam beside it, and for the same
    /// reason: a stub asserts against the state this class is mutating, and the
    /// nonisolated shape the coordinator takes cannot reach it.
    var workScreenshotNormalizeForTesting: (@MainActor (Data) async -> Data?)?
    #endif

    /// Stands in for the App-Group retry queue. `PendingRetryStore.shared` is a
    /// process-global singleton over one file every capture test in the bundle
    /// shares, and the claims here are about WHICH capture this class arms and
    /// releases — a property of this class, not of the file format.
    var retryLaneForTesting: (any PendingRetryLaneReserving)?

    /// Stands in for the Speech-Recognition TCC verdict the start path reads.
    /// `VoicePermissions.ensureSpeechRecognitionForActiveProvider()` never
    /// PROMPTS under XCTest — it returns the machine's live status — so on any
    /// device or CI image whose row for this bundle is `denied` or
    /// `restricted`, `startRecording()` bails before the microphone seam it
    /// sits above and every ordering claim past that line silently becomes a
    /// failure about the machine. Pinning the verdict makes those cases say
    /// what they are about.
    var speechAuthorizationForTesting: SFSpeechRecognizerAuthorizationStatus?

    /// Stands in for CarPlay's process-wide session mirror.
    /// `CarPlayRecordingService.anySessionActive` is `private(set)` and is
    /// written only by a real car connection, so the refusal it arms is
    /// otherwise unreachable from a headless run — which is exactly how it went
    /// unbuilt: the one gate iOS has for this is a founder-QA item nobody can
    /// execute.
    var carPlaySessionActiveForTesting: Bool?

    /// Stands in for the microphone coming up. There is no input device on a
    /// simulator, and the claim this seam exists for is an ORDERING one: the
    /// capture a new recording replaces is let go only after the replacement
    /// microphone is live, so a refused start leaves the previous capture — and
    /// the Try Again that finishes it — untouched. Returns whether the mic came
    /// up, exactly as `AudioRecorder.startRecording()` does.
    var microphoneStartForTesting: (@MainActor () async -> Bool)?

    /// Stands in for the audio delegate's `successfully: false` callback, which
    /// no simulator can produce — there is no input device for a HAL abort to
    /// happen to. It runs exactly the handler the callback is wired to, and the
    /// wiring itself is what the source guard beside these cases asserts.
    func _failRecordingForTesting() async {
        await handleUnexpectedRecordingFailure()
    }

    /// Runs the capture the seams above describe. `stopAndUpload()` refuses
    /// unless the microphone is live, which no simulator run can arrange, and
    /// driving the orchestration is the whole point of the three seams.
    @discardableResult
    func _finishCaptureForTesting() async -> Result<String, AppError> {
        await runProcessingTask { await self.finishAndUpload() }
    }
    #endif

    /// The desk store this recorder writes to.
    private var workStore: ConversationStore {
        #if CONDUCK_TESTING
        return workStoreForTesting ?? .shared
        #else
        return .shared
        #endif
    }

    #if !os(watchOS)
    /// The durable capture queue this recorder's screenshots ride through.
    private var workInbox: WorkCaptureInbox {
        #if CONDUCK_TESTING
        return workInboxForTesting ?? .shared
        #else
        return .shared
        #endif
    }

    /// The image pipeline the screenshot is normalized by. Nil means "the
    /// coordinator's own", which is the production answer — passing nil is
    /// exactly the default the coordinator declares, and it declares it as a
    /// nil-defaulted parameter because a default-argument expression would be
    /// evaluated in the caller's isolation.
    private var workScreenshotNormalize: (@Sendable (Data) async -> Data?)? {
        #if CONDUCK_TESTING
        guard let stub = workScreenshotNormalizeForTesting else { return nil }
        // A global-actor-isolated closure IS Sendable, so hopping to it is all
        // this adapter is — the coordinator's parameter is nonisolated because
        // a headless intent lane also calls it.
        return { data in await stub(data) }
        #else
        return nil
        #endif
    }

    /// Bytes of the screenshot that belongs to the NEXT Work capture. Held
    /// until Stop mints the capture id: the picture cannot be published before
    /// there is an id to derive its card's identity from, and minting one at
    /// the start would name a capture that Esc may still cancel.
    private var stagedWorkScreenshot: Data?
    #endif

    #if os(macOS)
    /// How many Work captures in this process have STOPPED and have not yet put
    /// their recording anywhere durable.
    ///
    /// The window is real and it is invisible: `AudioRecorder.stopRecording()`
    /// hands back the bytes and deletes the file, so from that line until the
    /// desk write copies them (or a retry record parks them) the recording
    /// exists nowhere but memory. Nothing else can see it — no gateway turn is
    /// involved, so the in-flight turn registry the quit guard reads is empty —
    /// and a ⌘Q pressed there takes the recording with no card and no Try Again
    /// left behind. `AppDelegate.applicationShouldTerminate` waits on this.
    ///
    /// A count rather than a flag: the menu bar's recorder and the desk sheet's
    /// are different instances and either may be mid-publication.
    private(set) static var workPublicationsInFlight = 0

    /// Give one declared window back. Floored, because the balance is a promise
    /// about quitting: a count that went negative would let a later capture's
    /// window read as already closed.
    private static func releaseWorkPublication() {
        workPublicationsInFlight = max(0, workPublicationsInFlight - 1)
    }

    /// Wait, bounded, for those publications to finish. Bounded because a quit
    /// that a stuck disk write could block for ever is a worse failure than the
    /// one this closes — and the recording is not lost by the wait ending, only
    /// by the process ending, which the caller then allows.
    static func waitForWorkPublications(timeout: Duration) async {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while workPublicationsInFlight > 0, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    /// How many Work captures have their only copy in this process's memory
    /// after everything durable has been TRIED and refused.
    ///
    /// The quit guard needs this apart from the count above. A publication in
    /// flight is answered by WAITING; this one has to be answered by the
    /// person, because nothing is still running that could finish it — the only
    /// ways out are the Try Again and the ✕ the capture's own surface is already
    /// showing.
    ///
    /// A count for the same reason the in-flight one is: the menu bar's
    /// recorder and the desk sheet's are different instances, and either may be
    /// holding bytes nothing durable would take.
    ///
    /// It is DERIVED from the recorders still alive to answer for it, never a
    /// number that has to be decremented by somebody. A declaration is a claim
    /// about bytes held in one recorder's memory, so it can only be true while
    /// that recorder exists: a desk sheet closed over a standing error released
    /// nothing — its ✕ does nothing in `.error`, and so does its disappearance —
    /// and every later ⌘Q then asked about a recording whose Try Again had gone
    /// with the surface. A weak set answers that by construction, and it is also
    /// the honest reading of "processing that finishes after the dismissal": a
    /// recorder its own task still holds is still there to be asked.
    static var unsavedWorkCaptureCount: Int {
        unsavedWorkCaptureHolders.values.filter { $0.recorder != nil }.count
    }

    /// One weakly-held recorder, so the declaration dies with the object that
    /// made it and with nothing else. The same shape `SpeechExclusivity` keeps
    /// its authorities in, and for the same reason — a registry that owned its
    /// members would keep alive exactly the objects it exists to forget.
    private struct UnsavedWorkCaptureHolder {
        weak var recorder: InAppAudioRecorder?
    }

    /// The recorders declaring one, keyed by identity so a second declaration
    /// from the same recorder is the same fact said twice. Compacted on every
    /// write: a dead entry costs a dictionary slot, and nothing else reads it.
    private static var unsavedWorkCaptureHolders: [ObjectIdentifier: UnsavedWorkCaptureHolder] = [:]
    #endif

    /// True while CarPlay holds this process's microphone and its shared
    /// `AVAudioSession`. False on every other platform, where there is no car
    /// session and no session to share.
    private var carPlayHoldsMicrophone: Bool {
        #if os(iOS)
        #if CONDUCK_TESTING
        if let pinned = carPlaySessionActiveForTesting { return pinned }
        #endif
        return CarPlayRecordingService.anySessionActive
        #else
        return false
        #endif
    }

    /// The retry queue this recorder arms and releases its own entry in.
    private var retryLane: any PendingRetryLaneReserving {
        #if CONDUCK_TESTING
        return retryLaneForTesting ?? PendingRetryStore.shared
        #else
        return PendingRetryStore.shared
        #endif
    }

    /// The capture whose queue entry this recorder itself armed AND whose write
    /// landed, so it releases only what it actually parked. An entry armed by
    /// another process — a capture that outlived an app launch — belongs to
    /// whichever surface recovers it, and a save that threw parked nothing at
    /// all: in both cases there is no entry of this recorder's to reserve or
    /// clear, and the retry runs on the bytes still in hand.
    private var armedDurableRetryID: UUID?

    /// Whether the entry named by `armedDurableRetryID` was armed WITHOUT this
    /// capture's screenshot, because that one write failed after the recording
    /// had already committed. The entry is real and the recording is safe; the
    /// picture exists only in this process's memory, which is precisely the
    /// question `noteWorkDurability` has to answer separately for each artifact.
    private var armedRetryOmittedPicture = false

    #if os(macOS)
    /// The capture this recorder has declared unsaved, so the declaration is
    /// given back exactly once and only for the capture that made it. See
    /// `noteWorkDurability`.
    private var unsavedWorkCaptureID: UUID?
    #endif

    /// The reservation this recorder holds over that entry while it finishes
    /// the capture, so no other surface can transcribe or delete the recording
    /// underneath it. Taken when a retry STARTS rather than when the capture is
    /// armed: a hold kept from the moment of failure would refuse the person
    /// their own recording on the retry card for as long as this sheet stayed
    /// open, and the recorder is not finishing anything in between.
    private var heldRetryClaim: PendingRetryClaim?

    /// Extends that reservation while the retry runs. A custom provider request
    /// is allowed 300 s and attempted three times, so one transcription can
    /// outlast the reservation that protects it. Cancelled on every exit.
    private var retryLeaseRenewal: Task<Void, Never>?

    /// How often the reservation is extended while a retry is live. Well inside
    /// `PendingRetryStore.claimLeaseDuration`, so a missed tick costs nothing.
    private static let retryLeaseRenewalInterval: TimeInterval = 120

    /// For the writes whose failure changes nothing this capture can act on and
    /// still must not pass in silence. It never carries a transcript, a URL or
    /// any part of what somebody said.
    nonisolated private static let log = Logger(
        subsystem: Constants.identityNamespace, category: "InAppCapture"
    )

    /// True when the last Try Again was refused because another surface holds
    /// this capture's queue entry. The sheet renders it instead of a typed
    /// error, because nothing failed: the recording is safe, is being finished
    /// elsewhere, and this tap changed nothing at all.
    private(set) var retryRefusedBusy = false

    /// Underlying capture engine. Composed (not inherited) so the
    /// AudioRecorder's `ObservableObject`-based timer callbacks stay in
    /// their existing shape without leaking into this view-facing API.
    private let recorder = AudioRecorder()

    /// In-flight post-stop STT round-trip. Stored so the composer's stall
    /// affordance can cancel a hung transcription via `cancelProcessing()`;
    /// nil outside `.processing`.
    private var processingTask: Task<Result<String, AppError>, Never>?

    /// True between `startRecording()`'s entry and the moment `state` is claimed
    /// (`= .recording`) — there's an `await recorder.startRecording()` gap (mic
    /// permission prompt / engine spin-up) where `state` is still `.idle`. Guards
    /// re-entry on a rapid double-tap (the `.idle` guard alone would let a second
    /// tap fire a second `recorder.startRecording()` during that gap), and it
    /// makes `isActivelyRecording` cover the startup window so no speaker or
    /// desk card can start audio in the gap before `.recording` is set.
    private var isStarting = false

    init(retryDestination: PendingRetryDestination = .chat) {
        self.retryDestination = retryDestination
        #if os(macOS) || os(iOS)
        // The composer mic joins the speech-exclusivity bus as a mic authority
        // (mirrors the menu-bar `DictationService`), so every playback surface
        // can ask ONE question — is a capture live? — before producing audio.
        // On macOS that is the only arbitration there is. On iOS the shared
        // session still cuts playback the moment this recorder takes `.record`,
        // but it tells no one: without this registration a desk audio card goes
        // on reporting `.playing` over silence, and `claimForAutoSpeak` cannot
        // refuse a reply that would speak into a live capture. Weakly held;
        // watchOS never registers.
        SpeechExclusivity.shared.register(recordingAuthority: self)
        #endif
        // Bridge the AudioRecorder's "finished" callback into our state
        // machine. Auto-stop (cap fired) goes straight to processing; the
        // view treats that as an implicit "stopped & uploading."
        recorder.onRecordingFinished = { [weak self] wasAutoStopped in
            guard let self else { return }
            if wasAutoStopped {
                Task { @MainActor in
                    // Auto-stop has no interactive caller to receive the result,
                    // so forward it via `onAutoStopResult` (Part 1e) — the host
                    // routes it into the same handler as a mic-tap stop, which
                    // POPULATES the composer field instead of discarding it.
                    let result = await self.runProcessingTask {
                        await self.finishAndUpload()
                    }
                    self.onAutoStopResult?(result)
                }
            }
            // User-initiated stops are driven through `stopAndUpload()` —
            // that path handles its own state transitions.
        }
        recorder.onRecordingFailed = { [weak self] in
            Task { @MainActor in await self?.handleUnexpectedRecordingFailure() }
        }
    }

    /// A HAL-aborted capture (delegate `successfully: false`) with no user stop.
    /// It must not strand this recorder in `.recording` — the composer would
    /// hang on a recording UI over a dead microphone.
    ///
    /// A Work capture carrying a staged PICTURE goes the long way round instead
    /// of ending here. The region was dragged before the microphone was asked
    /// for anything, an abort does not un-drag it, and it exists nowhere but
    /// this process — while ending here leaves it staged with no capture to
    /// hold it: Stop refuses because the recording is over, and Try Again has
    /// nothing to finish. The empty-audio path already mints a capture that
    /// owes no recording and settles the picture onto the desk, so the failure
    /// is routed through it. The answer is still `.audioMissingData`; what
    /// changes is that the picture survives and the facts say what landed.
    private func handleUnexpectedRecordingFailure() async {
        guard case .recording = state else { return }
        #if !os(watchOS)
        if retryDestination == .work, stagedWorkScreenshot != nil {
            _ = await runProcessingTask { await self.finishAndUpload() }
            return
        }
        #endif
        state = .error(.audioMissingData)
    }

    // MARK: - Public API

    #if !os(watchOS)
    /// Bytes of the screenshot that belongs to the NEXT Work capture. Held
    /// until Stop mints the capture id; dropped by `cancelRecording()`.
    ///
    /// Staging rather than publishing is what lets one Esc get out of an
    /// accidental capture: nothing durable exists between the drag and the
    /// stop, so a cancelled recording leaves the desk exactly as it was. The
    /// bytes move INTO the capture the moment one is minted, so both the
    /// in-process retry and the durable retry record carry them from there.
    ///
    /// A Chat recorder has no card to put a picture on, so a Work-only surface
    /// is the only caller; anything staged on a Chat recorder is dropped when
    /// its capture is minted rather than held for a publication that will never
    /// come.
    ///
    /// Empty bytes are not a picture, and they are normalized to "none" here
    /// rather than refused downstream: a capture that staged nothing publishable
    /// must not report an omitted screenshot, because a receipt that names a
    /// missing picture for a capture that never had one is as untrue as one
    /// that hides a real loss.
    func stageWorkScreenshot(_ data: Data?) {
        stagedWorkScreenshot = (data?.isEmpty ?? true) ? nil : data
    }
    #endif

    /// Begin recording. Transitions `state` to `.recording(startedAt:)` on
    /// success, `.error(...)` on permission / engine / mic-busy failure.
    ///
    /// A Work capture already in hand survives every failure path here: it is
    /// released only on the line below the successful start, because a person
    /// who tapped Record Again and was refused a microphone still has the first
    /// capture's card on the desk and must still be able to finish it.
    func startRecording() async {
        guard case .idle = state, !isStarting else { return }
        // Hold a "starting" claim across the async gap below — `state` stays
        // `.idle` until `recorder.startRecording()` returns, so without this a
        // rapid double-tap would fire a second capture, and audio could start in
        // the gap before `.recording` is set. Reset on EVERY exit path.
        isStarting = true
        defer { isStarting = false }

        #if !os(watchOS)
        // A refused start is not a capture, and the picture staged for it may
        // not ride the NEXT one: a region dragged at one moment, published
        // beside words spoken at another, is worse than no picture at all. The
        // stage therefore survives exactly one thing — a start that actually
        // took the microphone, which is the only exit that leaves `.recording`.
        // Below the re-entrancy guard by design: a press that arrives while a
        // capture is already live changes nothing and must not take that
        // capture's picture away from it.
        defer {
            if case .recording = state {
                // The microphone came up, so this capture owns the picture.
            } else {
                stagedWorkScreenshot = nil
            }
        }
        #endif

        // Mic wins: a new capture invalidates any staged read-aloud one-shot
        // (a notification-tap request still pending when the user starts the
        // composer mic would otherwise auto-speak OVER the live recording when
        // the thread's messages refresh). Mirrors the Watch's clear-on-capture.
        AutoSpeakMailbox.shared.clear()

        #if !os(watchOS)
        // Speech-Recognition preflight (A fallback). Catches existing users,
        // onboarding-skippers, restored installs, and stale TCC: if Apple
        // on-device STT is active AND Speech Recognition is `.notDetermined`,
        // prompt BEFORE entering the recording state — a denial never wastes a
        // recording. Cloud providers no-op. A determined `.denied`/`.restricted`
        // surfaces the existing `speechPermissionDenied` banner and bails
        // without recording; `.authorized` / just-granted proceeds.
        let speechStatus: SFSpeechRecognizerAuthorizationStatus
        #if CONDUCK_TESTING
        if let pinned = speechAuthorizationForTesting {
            speechStatus = pinned
        } else {
            speechStatus = await VoicePermissions.ensureSpeechRecognitionForActiveProvider()
        }
        #else
        speechStatus = await VoicePermissions.ensureSpeechRecognitionForActiveProvider()
        #endif
        if speechStatus == .denied || speechStatus == .restricted {
            state = .error(.speechPermissionDenied)
            return
        }
        #endif

        #if os(macOS)
        // macOS has no audio-session arbitration: acquire the cross-process mic
        // lease BEFORE the input comes up, so this recorder and the menu-bar
        // `DictationService` (separate `AVAudioRecorder` instances) can't
        // double-start the mic — the HAL "there already is a thread" / error-35
        // path. Excluding self by identity; a live capture is sacred, so a
        // SECOND start is refused, never the first.
        guard SpeechExclusivity.shared.acquireMicLease(excluding: self) else {
            state = .error(.audioMicBusy)
            return
        }
        #endif

        #if os(iOS)
        // iOS DOES have an audio session, and that is the whole problem: there
        // is ONE per process. This recorder's start moves it to `.record` and
        // its stop deactivates it — under whoever else is holding it. The other
        // holder is CarPlay, and it is the one surface that cannot see this one:
        // a driver mid-sentence, on a route this start would reconfigure and
        // this stop would tear down.
        //
        // CarPlay registers nothing on the speech bus BY CONSTRUCTION — its
        // exactly-once activate / deactivate-once legs must not be preemptable —
        // so ownership is read from its process-wide mirror, the same read
        // `ThreadSpeaker` and the desk's card player already make before they
        // touch the session. The lease side of that pair is
        // `AudioRecorder.deactivateSessionUnlessCarPlayOwnsIt()`, which covers
        // the capture that began BEFORE the car connected and can no longer be
        // refused here.
        //
        // A live car capture is sacred for exactly the reason a live macOS one
        // is: the SECOND start is refused, never the first. `audioMicBusy` is
        // already the taxonomy's word for "another surface has the microphone".
        guard !carPlayHoldsMicrophone else {
            state = .error(.audioMicBusy)
            return
        }
        #endif

        #if os(macOS) || os(iOS)
        // Silence every registered speaker before the mic comes up — a playing
        // reply or desk voice note would otherwise bleed into the capture, and
        // on iOS the session's own `.record` switch silences them WITHOUT
        // telling them, leaving a card reporting playback over a dead route.
        // The mic is never a registered party, so nothing stops it back;
        // CarPlay registers nothing, so the car's voice session is out of reach
        // of this broadcast. Mirrors `DictationService`.
        SpeechExclusivity.shared.claim(nil)
        #endif

        do {
            // Honor the start result: a `false` return / `.recordingFailed` means
            // the HAL rejected the start — surface an error instead of a fake
            // `.recording` that would capture nothing.
            #if CONDUCK_TESTING
            let started: Bool
            if let stub = microphoneStartForTesting {
                started = await stub()
            } else {
                started = try await recorder.startRecording()
            }
            #else
            let started = try await recorder.startRecording()
            #endif
            guard started else {
                state = .error(.audioMissingData)
                return
            }
        } catch let error as AudioRecorderError {
            // Mic permission denied or engine failure — surface as the
            // closest AppError so UI maps to the same banner taxonomy.
            switch error {
            case .permissionDenied:
                state = .error(.audioInvalid)
            case .recordingFailed:
                state = .error(.audioMissingData)
            case .microphoneBusy:
                // The same verdict the pre-prompt gate above raises, because it
                // is the same fact discovered one suspension later: the car took
                // the session while the permission sheet stood.
                state = .error(.audioMicBusy)
            }
            return
        } catch {
            state = .error(.unknown(error))
            return
        }

        // The replacement microphone is live, so — and only now — the capture it
        // replaces may be let go. Every path above this line is a refusal, and a
        // refusal replaces nothing: releasing the capture there leaves its card
        // standing wordless on the desk with nothing able to finish it.
        await abandonPendingWorkCapture()

        // STABLE start instant — the `mm:ss` display ticks inside the indicator's
        // leaf `TimelineView`, so `state` no longer mutates every 0.1s (which was
        // re-laying-out the chat pane and freezing macOS).
        state = .recording(startedAt: Date())
    }

    /// Stop recording and run the STT round-trip. Returns the transcript
    /// text on success, or the typed error. View calls this from the mic
    /// button's "stop" tap; auto-stop (cap fired) goes through the same
    /// downstream path internally.
    @discardableResult
    func stopAndUpload() async -> Result<String, AppError> {
        guard case .recording = state else {
            return .failure(.audioMissingData)
        }
        return await runProcessingTask { await self.finishAndUpload() }
    }

    /// Finish the Work capture this recorder is still holding, from wherever it
    /// stopped: publish the picture if no card holds it, park the recording if
    /// nothing durable does, recognize the words if none were recovered, and
    /// publish them as the card this capture becomes.
    ///
    /// The picture goes first and answers only for itself. A capture can owe
    /// the screenshot, the park, the words, or any combination, and each step
    /// asks its own question — so a retry after a refused picture does not
    /// re-transcribe, and a retry after a refused transcription does not
    /// republish a picture that already landed.
    ///
    /// The picture-only case therefore costs nothing but the publication: every
    /// other step finds its work already done and skips it, so ONE tap turns a
    /// capture whose words are already on the desk into a finished one, with no
    /// provider round trip and no second card anywhere.
    ///
    /// This is what a retry offered beside a failed Work capture must do. The
    /// alternative — starting a new recording — leaves the first capture with
    /// nothing on the desk at all, which is why recording again is a separate,
    /// separately labelled action that hands the first one back to the queue
    /// rather than ending it.
    ///
    /// It RESERVES the capture's queue entry first, and refuses when another
    /// surface — the app's retry card, the menu bar, a Shortcut host — is
    /// already finishing that recording. Refusing is not a failure: nothing is
    /// deleted, the state the sheet is showing is left exactly as it was, and
    /// `retryRefusedBusy` is what the sheet says about it.
    @discardableResult
    func retryWorkCapture() async -> Result<String, AppError> {
        guard let capture = pendingWorkCapture else {
            return .failure(.audioMissingData)
        }
        retryRefusedBusy = false
        guard await reserveDurableRetry(for: capture.id) else {
            retryRefusedBusy = true
            // The capture is still exactly as retryable as it was a moment ago,
            // by whoever holds it — so the state stands and the answer is the
            // error already on screen rather than a new one about a failure
            // that did not happen.
            if case .error(let standing) = state { return .failure(standing) }
            return .failure(.workDeskWriteFailed)
        }
        state = .processing
        let result = await runProcessingTask { await self.finishAndUpload(resuming: capture) }
        // Whatever the outcome, this recorder stops holding what it did not
        // finish: a capture that succeeded was cleared through the reservation
        // below, and one that failed is handed straight back so the next tap —
        // here or on the retry card — can take it without waiting out the lease.
        await handBackUnfinishedRetry()
        return result
    }

    /// Cancel a hung post-stop transcription (the composer's stall affordance,
    /// shown after `Constants.transcribeStallHintDelay`). Cooperative —
    /// URLSession requests and the retry loop's backoff sleeps both observe
    /// cancellation; `finishAndUpload` maps a cancelled run to `.idle` (no
    /// error banner, no retry save — the user chose to abandon the capture).
    func cancelProcessing() {
        processingTask?.cancel()
    }

    /// Cancel an in-flight recording without uploading. Used by a future
    /// "trash" button or scenePhase-leaving guard.
    ///
    /// The staged screenshot goes with it. A live-recording cancel promises
    /// that nothing has landed on the desk, and the picture is the one artifact
    /// that could have — which is exactly why it is published at Stop and not
    /// at the drag. A capture already PAST that point keeps whatever reached
    /// the desk; abandoning a transcription is `cancelProcessing()`, and it
    /// unpublishes nothing.
    func cancelRecording() {
        recorder.cancelRecording()
        #if !os(watchOS)
        stagedWorkScreenshot = nil
        workCaptureFacts = .none
        #endif
        state = .idle
    }

    /// The ✕ on a standing Work error: let go of the capture in hand.
    ///
    /// Distinct from `dismissError()`, which clears the banner for a surface
    /// that is about to record AGAIN — there the capture must survive, because
    /// a refused microphone replaces nothing and its Try Again has to be
    /// exactly where it was. This is the other press: the person is done with
    /// this capture.
    ///
    /// The durable entry is deliberately NOT retired. It was written before the
    /// speech hop and holds the only copy of the recording, so dismissing the
    /// surface hands the capture to the retry lane rather than deleting it. A picture that never reached the queue and a
    /// capture that was never parked (one with no recording of its own) are the
    /// two things this press really does end, and both are already the state
    /// the person is looking at.
    func discardPendingWorkCapture() {
        #if !os(watchOS)
        pendingWorkCapture = nil
        workRecordingMaterialID = nil
        workCaptureFacts = .none
        #endif
        #if os(macOS)
        // THE EXPLICIT DISCARD. The ✕ is one of the two answers the quit guard
        // is waiting for, and after it there is nothing left to lose.
        releaseUnsavedWorkCapture()
        #endif
        retryRefusedBusy = false
        state = .idle
    }

    /// Reset from `.error(...)` back to `.idle` so the user can try again.
    func dismissError() {
        retryRefusedBusy = false
        if case .error = state {
            state = .idle
        }
    }

    // MARK: - Private

    /// Run one terminal step inside a stored, cancellable Task so
    /// `cancelProcessing()` has a handle. Every terminal path — mic-tap stop,
    /// duration-cap auto-stop, and a Work retry — routes through here. `Task {}`
    /// inherits the MainActor context, so the body runs on the same actor.
    private func runProcessingTask(
        _ body: @escaping @MainActor () async -> Result<String, AppError>
    ) async -> Result<String, AppError> {
        // Single-flight: a duration-cap auto-stop and a near-simultaneous manual
        // Stop tap can both reach here. Join the in-flight run instead of firing
        // a second STT round-trip (double upload + double state churn).
        if let inFlight = processingTask {
            return await inFlight.value
        }
        let task = Task { await body() }
        processingTask = task
        let result = await task.value
        // Only clear OUR handle — a cancelled run resuming late must not null
        // a newer run's handle (that would silently disable its stall-Cancel).
        if processingTask == task {
            processingTask = nil
        }
        return result
    }

    /// Stop the recorder, compress, transcribe, and — on the Work lane — park
    /// the recording and publish its words as a card. Common path for a
    /// user-initiated stop, an auto-stop on the duration cap, and a retry.
    ///
    /// Re-entrant BY DESIGN: `resuming` carries what a capture already
    /// achieved, so a retry stops nothing, compresses nothing, parks only if
    /// nothing durable holds the bytes and transcribes only if no words landed.
    /// Both Work phases key off the capture's single id and both are idempotent
    /// under it, so a second run can neither duplicate the entry nor duplicate
    /// the card.
    private func finishAndUpload(
        resuming resumed: VoiceCapture? = nil
    ) async -> Result<String, AppError> {
        let outcome = await runCaptureToCompletion(resuming: resumed)
        #if !os(watchOS)
        let settled = await settleOwedScreenshot(after: outcome)
        #else
        let settled = outcome
        #endif
        // EVERY terminal exit hands back what it did not finish, and the FIRST
        // capture needs it as much as a retry does: phase one now reserves the
        // entry it parks, so a capture that fails there holds a lease nothing is
        // working on. Renewed for ever by a live recorder, that lease keeps the
        // recording out of `waitingCount()` — the retry card and the menu bar
        // stop drawing the row that offers it — and out of every other surface's
        // reach until the recorder dies. A capture that SUCCEEDED cleared its
        // entry through the same reservation, so there is nothing left to give
        // back and this is a no-op.
        await handBackUnfinishedRetry()
        return settled
    }

    #if !os(watchOS)
    /// THE DEBT CHECK, and it sits ABOVE the pipeline because a capture can end
    /// in a dozen places and the picture is owed at every one of them.
    ///
    /// Silence is the case that named this: `.noSpeechDetected` is terminal and
    /// NOT retryable, so a capture that ended there offered no Try Again at all
    /// — and the picture it was still holding had nowhere to go. Every other
    /// terminal exit has the same shape: a missing key, an unreadable one, a
    /// model that would not install, a card deleted mid-recognition. None of
    /// them is about the picture, and all of them were ending the capture.
    ///
    /// So the answer is rewritten. Whatever the speech hop did, a capture still
    /// owing its picture stays pending and reports the one retryable error whose
    /// copy names the artifact that is actually missing — the facts carry what
    /// else went wrong, which is what the surface renders. One Try Again then
    /// publishes the picture and lets the remaining speech outcome decide the
    /// final answer exactly as it would have.
    ///
    /// It cannot loop: each call answers once and waits for the next tap.
    private func settleOwedScreenshot(
        after outcome: Result<String, AppError>
    ) async -> Result<String, AppError> {
        guard retryDestination == .work else { return outcome }

        // THE REFRESH SITS ABOVE THE DEBT QUESTION, because both of its answers
        // print facts. A failure renders them beside its own sentence whether
        // or not a picture is owed, and a capture that DOES owe one is about to
        // become a failure here. `materialID` and a publication id are memories
        // of writes: a card deleted while recognition was in flight makes both
        // stale, and no exit before the publication asks the desk. Gated on the
        // debt instead, an emptied desk still reported a card and a picture
        // sitting on it — the exact untruth this refresh exists to stop. The durable `.published` verdict stays as it is, because it
        // answers a different question: whether a recovery would be
        // republishing a recording or resurrecting a card somebody deleted.
        if let pending = pendingWorkCapture {
            var ended = false
            if case .failure = outcome { ended = true }
            if ended || pending.owesScreenshot {
                await refreshDeskFacts(for: pending)
            }
        }

        // NOTHING OWED. The capture is finished — and if the person cancelled
        // on the way, that is the answer they get: everything durable landed,
        // it is retired, and the silence is deliberate. A `.success` returned
        // here prints "Added to Work." over a ✕ somebody had just pressed,
        // which is the one sentence a withdrawn request may not produce.
        guard let owed = pendingWorkCapture, owed.owesScreenshot else {
            guard Task.isCancelled else { return outcome }
            state = .idle
            return .failure(.unknown(CancellationError()))
        }

        // A refused DESK WRITE keeps its own answer. It is already retryable,
        // the same Try Again republishes the picture on its way through, and
        // "the recording is not saved" is the bigger news of the two.
        if case .failure(let existing) = outcome,
           existing.errorCode == AppError.workDeskWriteFailed.errorCode {
            return outcome
        }

        let surfaced = AppError.workScreenshotWriteFailed
        pendingWorkCapture = owed
        await preserveForRetry(error: surfaced, capture: owed, preferredLanguage: nil)
        // The state is the SAME whether this attempt ran to a verdict or the
        // person stopped it: the debt is unchanged either way, and the surface
        // that was offering Try Again goes on offering it. A cancelled attempt
        // returning to `.idle` instead took the capture off every affordance
        // there is — the popover draws no Work HUD over an idle recorder, the
        // hotkey's finish arm refuses an idle capture, and the next ⌃⌘W
        // replaces it. Two ✕ presses still leave: this one abandons the
        // attempt, and the one on the error surface dismisses the capture.
        state = .error(surfaced)
        // A cancelled attempt is not a verdict, so it answers as a cancel. The
        // caller prints nothing for it, which is what makes the return to the
        // error surface silent.
        if Task.isCancelled { return .failure(.unknown(CancellationError())) }
        return .failure(surfaced)
    }

    /// Re-read what the desk actually holds for this capture — BOTH cards.
    ///
    /// `materialID` and a publication id are memories of writes, not
    /// observations: a card can be deleted on another device between the
    /// publication and whatever ends the capture, and every exit that returns
    /// before this refresh never asks. A person who cleared their
    /// desk mid-capture must not be told either artifact is waiting on it.
    ///
    /// Nothing can be on a card that is gone, so both facts fall with it.
    /// `screenshotQueued` does NOT fall with the picture: it records that the
    /// inbox accepted the envelope, which stays true however the card that came
    /// of it is disposed of afterwards, and it is what says this capture owes
    /// nothing more.
    /// Writes the latch straight onto `pendingWorkCapture` rather than back
    /// through its argument: the capture passed in was read from it a moment
    /// ago on this actor, and every caller re-reads it afterwards.
    private func refreshDeskFacts(for capture: VoiceCapture) async {
        if let materialID = capture.materialID {
            // Only a DEFINITE answer moves a fact. A store that could not be
            // read says nothing about what is on the desk.
            if let present = await deskHoldsMaterial(materialID) {
                workCaptureFacts.wordsOnDesk = present
                if !present {
                    // The card is gone, so whatever it held is gone with it —
                    // the words in every case, and the audio in the legacy one
                    // where they were written onto a standing recording.
                    workCaptureFacts.recordingOnDesk = false
                    // LATCHED onto the capture in hand. A later pass cannot ask
                    // again when the store has stopped answering, and without
                    // this memory the historical id would be all it had to go
                    // on — which is how a cleared desk came to be described as
                    // holding a card.
                    pendingWorkCapture?.recordingConfirmedGone = true
                }
            }
        } else {
            // No card was ever published, which is the ordinary state of a
            // capture whose words never arrived.
            workCaptureFacts.recordingOnDesk = false
            workCaptureFacts.wordsOnDesk = false
        }

        guard workCaptureFacts.screenshotStaged else { return }
        let pictureID = WorkVoiceScreenshotCoordinator.materialID(forCapture: capture.id)
        if let present = await deskHoldsEligibleImage(pictureID) {
            noteScreenshotPresence(present)
        }
    }

    /// Record what a lookup found, and never forget a card it once found.
    ///
    /// The memory is the whole point: "queued but not on the desk" is two
    /// different states, and only one of them is still coming. A card that
    /// arrived and was deleted must not be described as on its way.
    private func noteScreenshotPresence(_ present: Bool) {
        workCaptureFacts.screenshotOnDesk = present
        if present { workCaptureFacts.screenshotEverOnDesk = true }
    }
    #endif

    /// The pipeline itself. Every terminal answer it produces passes through
    /// `finishAndUpload` above, which is where a capture that still owes an
    /// artifact is turned into one that says so.
    private func runCaptureToCompletion(
        resuming resumed: VoiceCapture? = nil
    ) async -> Result<String, AppError> {
        var capture: VoiceCapture
        #if os(macOS)
        // The recording leaves the file system at the stop below and reaches
        // nothing durable until phase one PARKS it. This declares that window,
        // so a ⌘Q cannot land inside it and take the audio; it is released the
        // moment the queue holds the recording, and by this `defer` on every
        // path that ends before then — nothing recorded, a picture-only
        // capture, a park that nothing would take.
        var workPublicationDeclared = false
        defer { if workPublicationDeclared { Self.releaseWorkPublication() } }
        #endif
        if let resumed {
            capture = resumed
        } else {
            state = .processing

            #if os(macOS)
            if retryDestination == .work {
                Self.workPublicationsInFlight += 1
                workPublicationDeclared = true
            }
            #endif

            #if CONDUCK_TESTING
            let recorded = capturedAudioForTesting ?? recorder.stopRecording()
            #else
            let recorded = recorder.stopRecording()
            #endif

            #if !os(watchOS)
            // The staged picture MOVES into the capture here, at the one moment
            // there is an identity to publish it under. Everything downstream —
            // the in-process retry and the durable retry record alike — carries
            // it from the capture, so there is exactly one copy and one owner.
            // A Chat recorder has no card to put a picture on, so anything
            // staged on one is dropped rather than held for ever.
            //
            // It is taken ABOVE the audio guard on purpose. A microphone that
            // gave nothing does not un-drag the region, and the picture exists
            // nowhere but this process — so it must not be dropped with the
            // silence, which is what a `guard` above this line did.
            let staged = retryDestination == .work ? stagedWorkScreenshot : nil
            stagedWorkScreenshot = nil
            // A new capture has achieved nothing yet, and the only fact known
            // at the mint is whether there is a picture to lose.
            workCaptureFacts = .none
            workCaptureFacts.screenshotStaged = staged != nil
            #else
            let staged: Data? = nil
            #endif

            if let audioData = recorded, !audioData.isEmpty {
                // Compress to M4A (16kHz mono AAC). Falls back to original on
                // failure — STTClient's pre-flight size guard still catches >15MB.
                let compressionResult = await AudioCompressor.compress(audioData)
                capture = VoiceCapture(
                    id: UUID(),
                    audio: compressionResult.data,
                    format: compressionResult.format,
                    screenshot: staged
                )
            } else if staged != nil {
                // A capture that owes NO recording. It exists only to carry the
                // picture to the desk and to be retryable while it does; the
                // audio guard's own answer is still what this run reports. The
                // format labels a temporary file this capture never writes.
                capture = VoiceCapture(
                    id: UUID(), audio: Data(), format: .aac, screenshot: staged
                )
            } else {
                state = .error(.audioMissingData)
                return .failure(.audioMissingData)
            }

            #if !os(watchOS)
            // The Work lane holds its capture until a card owns the words, so a
            // failure anywhere below has something to retry from.
            if retryDestination == .work { pendingWorkCapture = capture }
            #endif
        }

        #if !os(watchOS)
        // PHASE 0, and it runs BEFORE the recording's own publication: the
        // picture is the artifact that exists nowhere but this process, so the
        // window where the audio lands and an in-memory image is lost to a
        // crash is closed by publishing the image first.
        //
        // It is deliberately NOT nested under the recording's phase-one
        // condition. The two artifacts are published independently and either
        // may be owed while the other is finished, so a resumed capture asks
        // this question again on its own terms — which is what makes the
        // screenshot's retry independent of the audio's.
        //
        // A refusal here does not fail the RECORDING: the audio, the words and
        // the desk writes below carry on exactly as they would with no
        // screenshot at all, and the bytes stay on the capture so a retry
        // republishes them. It does leave the capture unfinished — see the debt
        // check in `finishAndUpload` — and it arms a durable record at once, so
        // a process death between here and the end does not take the picture.
        if retryDestination == .work, capture.owesScreenshot,
           let screenshot = capture.screenshot {
            if let materialID = await publishWorkScreenshot(screenshot, for: capture) {
                // QUEUED, which is a weaker claim than SAVED and the only one
                // this return licenses: the envelope was accepted, and the
                // drain that turns it into a card runs afterwards and is
                // best-effort. The debt is settled here all the same — a queued
                // envelope is nobody's to publish twice, and the foreground
                // observer imports it.
                capture.screenshotQueued = true
                workCaptureFacts.screenshotQueued = true
                // …so whether it is ON THE DESK is a separate question with a
                // separate answer, and it is asked of the desk rather than
                // inferred. Only a card read back may be described to a person
                // as saved. Asked over BOTH ids the picture can land under —
                // the drain that imports it escapes a kind collision once — and
                // over the KIND, so the card that caused an escape is never
                // mistaken for the picture that escaped it.
                noteScreenshotPresence(await deskHoldsEligibleImage(materialID) == true)
                // The picture is somewhere that survives this process now, so
                // whatever it was owed of the quit window is settled. The
                // recording's own declaration is separate and still standing,
                // which is what `audioInFlight` says.
                #if os(macOS)
                noteWorkDurability(capture, audioInFlight: workPublicationDeclared)
                #endif
                // The picture is durable now, so the parked copy is no longer
                // the only one — and a parked copy left behind would go on
                // telling the expiry sweep this entry shelters an irreplaceable
                // image, exempting it from the clock for ever.
                await discardParkedWorkImage(for: capture.id)
            } else {
                // The only shelter left for these bytes, and it arrives one
                // phase early: the park below would have written the same entry
                // a moment later, and a picture refused before it has nowhere
                // to go. The verdict is `.phaseOneFailed` — the desk holds
                // nothing for this capture, which stays true until the words
                // land — and it is what exempts the entry from the clock while
                // it shelters the only copy of that picture.
                await preserveForRetry(
                    error: .workScreenshotWriteFailed,
                    capture: capture,
                    preferredLanguage: nil
                )
            }
            pendingWorkCapture = capture
        }

        // A capture with no recording of its own has done everything it can the
        // moment its picture is settled: the phases below would publish empty
        // bytes as a voice note and buy a transcription of silence. The audio
        // guard's answer is what it reports, and the debt check above turns an
        // owed picture into the retryable one instead.
        if capture.audio.isEmpty {
            if capture.owesScreenshot {
                pendingWorkCapture = capture
            } else {
                pendingWorkCapture = nil
                await releaseDurableRetry(for: capture.id)
            }
            state = .error(.audioMissingData)
            return .failure(.audioMissingData)
        }

        // PHASE 1 of the Work voice capture: the recording is PARKED, and it is
        // never published. The desk gets the words and nothing else, so the one
        // thing this phase owes is durability — bytes that survive this process
        // while the speech hop runs, in a device-local file that syncs nowhere.
        //
        // A park that FAILS is not durable, and this is the only place that can
        // tell: `reserveDurableRetry` answers success for a capture that is not
        // queued at all, because a capture nobody queued is one nobody else can
        // be finishing. Read as "it is parked" that same answer would send this
        // capture into the speech hop with its recording in memory alone.
        if retryDestination == .work, !capture.transcriptSettled {
            guard await parkForTranscription(capture) else {
                // Nothing durable would take these bytes, so they stay in
                // memory and the capture says so: retryable, held, and the ✕
                // and Try Again on the surface are the only ways out.
                return await failPendingWorkCapture(capture)
            }
            pendingWorkCapture = capture
            #if os(macOS)
            // The bytes are somewhere that outlives this process, so a quit may
            // proceed. Released HERE — at the park rather than at any desk
            // write — because everything after this line is the speech hop: the
            // words are retryable, the recording is safe, and a ⌘Q should not
            // wait out a transcription to keep a promise that is already kept.
            if workPublicationDeclared {
                Self.releaseWorkPublication()
                workPublicationDeclared = false
            }
            // …and with the recording durable, re-read what is left. A
            // screenshot whose publication AND preservation both failed is
            // still memory-only, and the window that covered it has just been
            // given back.
            noteWorkDurability(capture)
            #endif
        }
        #endif

        // A retry that owes only the publication skips the whole speech hop:
        // these words were recognized once already, and running it again would
        // spend a second round trip on the same bytes for the same answer.
        if capture.transcript == nil {
            // A temp file for STTClient (which takes a URL + defer-deletes).
            // The extension comes from the compressor's own format truth —
            // `.original` fallbacks carry the recorder's untouched AAC M4A
            // bytes, never WAV, so no second mapping here that could contradict
            // `AudioFormat`.
            let audioFileURL = capture.transcriptionFileURL
            // ONE owner for that file, declared with it. Every exit below
            // passes through here, the write's own failure included — that is
            // the path that strands a partial file, and the generic scratch
            // sweeper would not reclaim one for 24 hours.
            defer { try? FileManager.default.removeItem(at: audioFileURL) }
            do {
                // Atomic, so a refused write leaves no half-written audio for a
                // retry to transcribe.
                try capture.audio.write(to: audioFileURL, options: [.atomic])
            } catch {
                state = .error(.audioMissingData)
                return .failure(.audioMissingData)
            }

            var recognized: Result<String, AppError>?
            var preferredLanguage: String?

            #if CONDUCK_TESTING
            // The stub stands exactly where the provider does: the card is
            // published and this file is on disk when it is called. Everything
            // after it — the silence check, the preservation, the state — is the
            // production path below.
            if let hop = transcriptionHopForTesting {
                recognized = await hop(audioFileURL)
            }
            #endif

            if recognized == nil {
                // Fetch settings on demand — the API key can rotate between sessions.
                // ATOMIC snapshot: pull (presetID, apiKey, provider)
                // in a single actor hop so a concurrent preset switch can't produce
                // a key/provider mismatch.
                let snapshot = await SettingsManager.shared.activeSTTSnapshot()
                preferredLanguage = await SettingsManager.shared.getPreferredLanguage()

                // FREEZE the Apple engine + language ONCE here (critical bug fix). The
                // engine-IMPLICIT `STTClient` in-process path would re-read
                // `getAppleOnDeviceEngineMode()` internally, so a mid-flight engine flip
                // (or the self-heal installing one engine's model while the runner
                // transcribes with another) could install ENGINE A's model and then
                // transcribe with ENGINE B — a guaranteed `appleSpeechModelNotInstalled`.
                // We freeze the pair and use it for BOTH install AND transcribe, routing
                // the Apple-in-process case through the engine-EXPLICIT runner directly
                // (the same path `AppleSpeechTester` uses) so install-engine ==
                // transcribe-engine. `nil` engine for every non-Apple provider.
                let isAppleInProcess = snapshot.provider.transport == .inProcess
                #if !os(watchOS)
                let frozenEngine: AppleOnDeviceEngineMode? = isAppleInProcess
                    ? await SettingsManager.shared.getAppleOnDeviceEngineMode()
                    : nil
                #else
                let frozenEngine: AppleOnDeviceEngineMode? = nil
                #endif

                // In-process providers (Apple on-device) need no API key — the runner's
                // TCC check is the moral equivalent — and neither does the BYO custom
                // endpoint configured with `.none` auth (a keyless local server). Both
                // live inside `STTKeyReadiness.requiresKey`, so this is one question.
                //
                // For every other provider the key must be there, and the TWO WAYS it
                // can fail to be are not the same fact. `snapshot.apiKey` is a collapsed
                // `String?`: nil means an empty slot OR a Keychain that could not answer
                // (keys are stored `kSecAttrAccessibleAfterFirstUnlock`, and a
                // protected-data read can also fail on a corrupted or empty item, which
                // is the reachable shape on a device that is by definition unlocked —
                // it is showing this composer). Code 23 asserts the slot is empty and is
                // TERMINAL, so it neither preserves the recording nor offers a retry;
                // code 75 says only that the key could not be READ, and its
                // `shouldPreserveForRetry` is what puts the capture in
                // `PendingRetryStore` on the way out (I3, I6).
                let apiKey: String
                switch await STTKeyReadiness.resolve(
                    presetID: snapshot.presetID,
                    snapshotKey: snapshot.apiKey,
                    provider: snapshot.provider,
                    customConfig: snapshot.customConfig
                ) {
                case .ready(let key):
                    apiKey = key
                case .notConfigured:
                    state = .error(.sttMissingAPIKey)
                    return .failure(.sttMissingAPIKey)
                case .unreadable:
                    // The lane's OWN preservation mechanism — the same reactive
                    // `PendingRetryStore.save` the STT failure below performs, gated on
                    // the same `shouldPreserveForRetry`. The retry card then re-runs
                    // this capture on the saved bytes, by which time the key may read
                    // fine.
                    await preserveForRetry(
                        error: .sttKeyUnreadable,
                        capture: capture,
                        preferredLanguage: preferredLanguage
                    )
                    state = .error(.sttKeyUnreadable)
                    return .failure(.sttKeyUnreadable)
                }

                // SELF-HEAL (Apple in-process only): the mic tap was the consent to set up
                // voice. If the frozen engine's per-locale model isn't installed, download
                // it IN PLACE (quiet progress) and transcribe the SAME audio — never force
                // a re-record. A genuine hard failure (unsupported language, or a failed
                // download) throws and falls to the inline error path below. The
                // compressed `uploadData` + the written temp file are already in hand, so
                // a re-tap re-runs install+transcribe on the same bytes.
                #if !os(watchOS)
                if let engine = frozenEngine,
                   !(await AppleModelInstaller.isReady(engine: engine, language: preferredLanguage)) {
                    state = .preparingVoice(progress: nil)
                    do {
                        try await AppleModelInstaller.install(engine: engine, language: preferredLanguage) { [weak self] fraction in
                            // Only advance progress while still preparing — a late KVO
                            // callback must not clobber a terminal state.
                            guard let self else { return }
                            if case .preparingVoice = self.state {
                                self.state = .preparingVoice(progress: fraction)
                            }
                        }
                    } catch {
                        // Couldn't set up voice — surface the inline "tap to retry" error
                        // (re-tapping the mic re-runs install+transcribe on the same audio).
                        // Reuse `appleSpeechModelNotInstalled` (its copy already reads
                        // "On-device voice model isn't ready…"); an unsupported-language
                        // throw keeps its own distinct hard-failure case.
                        let mapped = (error as? AppError) ?? .appleSpeechModelNotInstalled
                        let surfaced: AppError = (mapped.errorCode == AppError.appleSpeechLanguageUnsupported.errorCode)
                            ? .appleSpeechLanguageUnsupported
                            : .appleSpeechModelNotInstalled
                        state = .error(surfaced)
                        return .failure(surfaced)
                    }
                    // Back to the transcribe phase — the model is now installed.
                    state = .processing
                }
                #endif

                do {
                    let response: STTResponse
                    #if !os(watchOS)
                    if let engine = frozenEngine {
                        // Engine-EXPLICIT Apple path — install-engine == transcribe-engine
                        // (can't re-read a different persisted engine). `STTClient`'s own
                        // `defer` doesn't run here; this method's single owner does.
                        response = try await AppleSpeechRunner.transcribe(
                            audioFileURL: audioFileURL,
                            language: preferredLanguage,
                            engine: engine
                        )
                    } else {
                        response = try await STTClient.shared.transcribe(
                            audioFileURL: audioFileURL,
                            apiKey: apiKey,
                            language: preferredLanguage,
                            provider: snapshot.provider,
                            customModel: snapshot.customModel,
                            customConfig: snapshot.customConfig
                        )
                    }
                    #else
                    response = try await STTClient.shared.transcribe(
                        audioFileURL: audioFileURL,
                        apiKey: apiKey,
                        language: preferredLanguage,
                        provider: snapshot.provider,
                        customModel: snapshot.customModel,
                        customConfig: snapshot.customConfig
                    )
                    #endif

                    recognized = .success(response.text)

                } catch let error as AppError {
                    recognized = .failure(error)

                } catch {
                    if Task.isCancelled || error is CancellationError {
                        state = .idle
                        return .failure(.unknown(CancellationError()))
                    }
                    state = .error(.unknown(error))
                    return .failure(.unknown(error))
                }
            }

            guard let recognized else {
                // Unreachable: the branch above either assigned or returned.
                state = .error(.audioMissingData)
                return .failure(.audioMissingData)
            }
            switch await settle(
                recognized,
                capture: capture,
                preferredLanguage: preferredLanguage
            ) {
            case .success(let text):
                capture.transcript = text
                #if !os(watchOS)
                if retryDestination == .work { pendingWorkCapture = capture }
                #endif
            case .failure(let error):
                // `settle` owns the state and the retry preservation the error
                // taxonomy calls for. The recording the words never arrived for
                // is parked, the desk is untouched, and the capture stays
                // retryable on exactly those bytes.
                return .failure(error)
            }
        }

        guard let transcript = capture.transcript else {
            // Unreachable: the branch above either assigned or returned.
            state = .error(.audioMissingData)
            return .failure(.audioMissingData)
        }

        #if !os(watchOS)
        // PHASE 2: the words become the card. It is the ONLY publication this
        // lane performs, and until it lands the desk holds nothing at all for
        // this capture.
        //
        // Asked ONCE per capture. A resumed capture that owed only its picture
        // has words the desk answered for minutes ago, and asking again is a
        // throwing store read whose failure would report a refused publication
        // for a capture whose card was never in question.
        if retryDestination == .work, !capture.transcriptSettled {
            #if CONDUCK_TESTING
            // Exactly where a press can land after the words are bought and
            // before they are written. The production path has no statement
            // here at all.
            if let pause = transcriptAttachPauseForTesting { await pause() }
            #endif
            // THE LAST OWNERSHIP QUESTION BEFORE THE WORDS ARE WRITTEN. A
            // reservation this recorder took can lapse while the speech hop runs
            // (see `reserveDurableRetry`), and the surface that then claimed the
            // capture is transcribing the SAME recording for the SAME card. Two
            // writers, one card: whichever finishes last wins, and this one has
            // been suspended the longest. Refusing is not a failure of the
            // capture — the recording is parked and somebody is finishing it —
            // so the sheet's busy sentence is what says so.
            if let held = heldRetryClaim, held.id == capture.id,
               await retryLane.confirmOwnership(held) == false {
                stopRenewingRetryLease()
                heldRetryClaim = nil
                retryRefusedBusy = true
                return refuseOvertakenWorkCapture(capture)
            }
            // THE WORDS ARE PARKED BEFORE THE DESK WRITE, and the result is
            // read. They were bought from a provider; a death between here and
            // the publication below costs one more round trip if they are on
            // the record and the whole transcription if they are not. It is
            // never fatal — the words are in hand, and refusing to publish them
            // because a metadata write failed would spend the capture to
            // protect a bookkeeping entry.
            if let held = heldRetryClaim, held.id == capture.id {
                let parked = await retryLane.recordPublicationState(
                    held, transcript: transcript, publicationState: .phaseOneFailed
                )
                if !parked {
                    // Not silent, and not an error either: the entry is still
                    // there, the words are still in memory, and the publication
                    // below is what settles both. What it costs, if this process
                    // dies in the next line, is one more transcription.
                    Self.log.error("Work voice words were not parked before the desk write")
                }
            }
            do {
                // The cancellation the WRITE itself can read. `Task.isCancelled`
                // inside the store's `context.perform` closure answers about the
                // queue's own task, so a "Cancel Transcription" landing after
                // this call and before the insert would still publish. The box
                // is set from the handler, on whatever thread delivers it, and
                // read at the mutation boundary.
                let authorization = WorkVoiceWriteAuthorization()
                let outcome = try await withTaskCancellationHandler {
                    try await WorkVoiceCaptureCoordinator.publishTranscript(
                        transcript,
                        forCapture: capture.id,
                        createdAt: capture.createdAt,
                        // The picture this same press produced, named on the
                        // words. Derived from the capture id, so it is the value
                        // phase 0 published under and the one a retry from the
                        // durable record uses — and it is set even when phase 0
                        // failed, because the link is a promise about identity
                        // and the fold heals itself the moment the picture lands.
                        attachedTo: capture.attachedPictureID,
                        authorization: authorization,
                        store: workStore
                    )
                } onCancel: {
                    authorization.cancel()
                }
                capture.materialID = outcome.materialID
                capture.transcriptSettled = true
                workRecordingMaterialID = outcome.materialID
                pendingWorkCapture = nil
                // What the DESK now holds, artifact by artifact. The words, in
                // every case. The recording only in the legacy one: a card an
                // earlier build published is still standing and took these words
                // onto itself, which is the one outcome where audio is on the
                // desk at all.
                workCaptureFacts.wordsOnDesk = true
                workCaptureFacts.recordingOnDesk = {
                    if case .attachedToRecording = outcome { return true }
                    return false
                }()
                if let held = heldRetryClaim, held.id == capture.id {
                    if capture.owesScreenshot {
                        // The entry STAYS — its parked picture may be the only
                        // copy of itself — but the recording in it is waste the
                        // moment the words land, and the clock that exempts the
                        // picture would shelter the audio with it. So the audio
                        // alone goes, and the stamp goes with it.
                        _ = await retryLane.retireRecording(held)
                    } else {
                        // Stamped before the clear below, so a death in between
                        // leaves a record whose replay publishes nothing twice
                        // and buys nothing twice.
                        _ = await retryLane.recordPublicationState(
                            held, transcript: transcript, publicationState: .published
                        )
                    }
                }
            } catch WorkVoiceCaptureCoordinator.WorkVoiceTranscriptRefusal.noWords {
                // The provider answered with something the desk cannot make a
                // card of — punctuation alone, or a marker that normalizes to
                // nothing. It is silence by another route and it answers as
                // silence: terminal, no card, and the same answer however many
                // times it is asked.
                //
                // The words are NOT marked settled. Settled means "phase two has
                // answered for these words", and the tail of this function reads
                // it as licence to retire the entry — which would delete the only
                // copy of the recording with nothing on the desk behind it. The
                // capture stays unfinished, its bytes stay parked, and a later
                // attempt re-runs this publication rather than the provider.
                pendingWorkCapture = capture
                state = .error(.noSpeechDetected)
                return .failure(.noSpeechDetected)
            } catch {
                // "Cancel transcription" pressed while the words were on their
                // way to the desk. Nothing failed, so nothing is reported and
                // nothing is parked: the recording stays in the queue, the
                // capture keeps its debt and its Try Again, and the surface goes
                // quiet. Same answer `settle` gives for a cancel it caught one
                // step earlier — one press, one outcome, whichever hop it
                // landed in.
                if Task.isCancelled || error is CancellationError {
                    pendingWorkCapture = capture
                    state = .idle
                    return .failure(.unknown(CancellationError()))
                }
                // The words are held and the desk refused them. A capture
                // reported complete here would send its transcript into a
                // composer with nothing on the board behind it.
                return await failPendingWorkCapture(capture)
            }
        }

        // A capture is its artifacts, so words landing cannot finish one that
        // still owes a picture. The capture is put back in hand for the debt
        // check above to find — it is the ONE place that decides what an owed
        // picture answers — and its queue entry, which holds the only copy of
        // that picture, is not retired.
        let owesPicture = retryDestination == .work && capture.owesScreenshot
        if owesPicture {
            pendingWorkCapture = capture
        } else if retryDestination == .work {
            // The capture is finished: the words are settled and the picture is
            // durable, or there was never one. It is let go HERE rather than in
            // whichever step happened to answer last — a picture-only retry
            // reaches this line having skipped phase two entirely, and a
            // release conditioned on that step having run left the capture in
            // hand for ever, still offering a Try Again with nothing to do.
            pendingWorkCapture = nil
            #if os(macOS)
            // Everything this capture owned is durable — that is what "finished"
            // means here — so any declaration it was holding is settled.
            releaseUnsavedWorkCapture()
            #endif
            await releaseDurableRetry(for: capture.id)
        }
        #else
        let owesPicture = false
        #endif

        // The completion chime says "that is dealt with", so it is withheld
        // from a capture the debt check is about to hand back as unfinished —
        // and from one the person cancelled, whose answer is a cancellation
        // however far the pipeline had already got.
        if !owesPicture, !Task.isCancelled { CompletionFeedbackPlayer.play(mode: "sound") }
        state = .idle
        return .success(transcript)
    }


    /// The ONE place a recognized — or refused — transcript becomes this
    /// recorder's answer, so the real provider and the test stub cannot settle a
    /// capture on different terms: the silence check, the cancel check, the
    /// retry preservation, and the state the composer renders.
    private func settle(
        _ recognized: Result<String, AppError>,
        capture: VoiceCapture,
        preferredLanguage: String?
    ) async -> Result<String, AppError> {
        // ASKED BEFORE THE OUTCOME, because "Cancel transcription" is a promise
        // about the WRITE and not about the provider: the request cannot be
        // recalled, so what the ✕ cancels is the result. A success that lands
        // after it used to walk straight past this check into phase two and
        // attach its words to the card the person had already stopped waiting
        // for — the recording stays either way, so the visible damage was words
        // arriving on a capture that had been let go.
        //
        // The transcribe layer maps cooperative cancellation to whatever the
        // network taxonomy says, so the task flag is the only reading that
        // covers both arms. Cancel is not a failure: back to idle, no banner,
        // no retry save.
        if Task.isCancelled {
            state = .idle
            return .failure(.unknown(CancellationError()))
        }
        switch recognized {
        case .success(let text):
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                // Empty/whitespace-only text = no transcribable speech (silence).
                // Surface the accurate "no speech" message, NOT the catch-all
                // `.apiFailure` (which renders the misleading "Something glitched
                // on our end" banner). This is a message change, not a retry
                // path: the same silence transcribes to the same nothing.
                state = .error(.noSpeechDetected)
                return .failure(.noSpeechDetected)
            }
            return .success(text)

        case .failure(let error):
            // Reactive save on retryable failures — mirrors macOS DictationService
            // pattern: no preempt guard, but preserve audio if the user will
            // realistically want to retry from the in-app retry card.
            await preserveForRetry(
                error: error,
                capture: capture,
                preferredLanguage: preferredLanguage
            )
            state = .error(error)
            return .failure(error)
        }
    }

    #if !os(watchOS)
    /// Hand this capture's screenshot to the durable queue, ahead of the
    /// recording. Answers with the id its card will carry, or nil.
    ///
    /// NIL covers both ways the picture can fail to become durable, and they
    /// are one answer to every caller: the queue REFUSED the bytes (a throw),
    /// and the image pipeline could not make anything publishable of them.
    /// Neither is an error this capture reports — a picture that will not decode
    /// may not cost the words that came with it — and both leave the bytes
    /// exactly where they were, which is what the retry runs on.
    ///
    /// An id is not a card. The coordinator's own drain runs after the envelope
    /// is accepted and is deliberately best-effort, so the id is a promise the
    /// queue made, and only a desk read can turn it into a fact.
    ///
    /// The capture's own `createdAt` dates the card rather than the moment of
    /// this call, so a capture published here and again from its durable record
    /// produces one picture with one date.
    private func publishWorkScreenshot(
        _ imageData: Data,
        for capture: VoiceCapture
    ) async -> UUID? {
        do {
            return try await WorkVoiceScreenshotCoordinator.publish(
                imageData,
                forCapture: capture.id,
                createdAt: capture.createdAt,
                inbox: workInbox,
                store: workStore,
                normalize: workScreenshotNormalize
            )
        } catch {
            return nil
        }
    }

    /// Is a card with this id standing on the desk right now?
    ///
    /// NIL means the desk could not be read, which is not the same as "no", and
    /// the difference is load-bearing: a transient store failure answered as
    /// "no" would tell a person their recording had vanished. Callers downgrade
    /// a fact only on a definite answer.
    private func deskHoldsMaterial(_ materialID: UUID) async -> Bool? {
        do {
            let desk = try await workStore.fetchWorkItem(id: Constants.workboardDeskItemID)
            return desk?.materials.contains { $0.id == materialID } ?? false
        } catch {
            return nil
        }
    }

    /// Is this capture's PICTURE standing on the desk right now?
    ///
    /// Two candidates, in this order: the derived id the screenshot publishes
    /// under, and that id's collision escape. The drainer republishes a card
    /// under `WorkMaterialCollisionEscape.materialID(forCapture:)` when the
    /// first id already names a card of another kind, so an id-only lookup
    /// answers "not on your desk" for a picture that is sitting there under its
    /// escape — and it answers "on your desk" for the wrong-kind card that
    /// caused the escape in the first place. Both are receipts that lie.
    ///
    /// The KIND is what makes each candidate eligible. A row at the first id
    /// that is not an image is precisely the collision, and it must not stop
    /// the second candidate being examined.
    ///
    /// Nil for the same reason as `deskHoldsMaterial`: a store that could not
    /// be read has said nothing, and callers move a fact only on a definite
    /// answer.
    private func deskHoldsEligibleImage(_ pictureID: UUID) async -> Bool? {
        let candidates = [
            pictureID,
            WorkMaterialCollisionEscape.materialID(forCapture: pictureID)
        ]
        do {
            let desk = try await workStore.fetchWorkItem(id: Constants.workboardDeskItemID)
            guard let materials = desk?.materials else { return false }
            return candidates.contains { candidate in
                materials.contains { $0.id == candidate && $0.kind == .image }
            }
        } catch {
            return nil
        }
    }

    /// Retire the parked copy of this capture's screenshot, now that a card
    /// owns the picture.
    ///
    /// Gated on the entry this recorder ARMED and on the reservation it holds,
    /// like every other write against the queue: an entry another surface took
    /// over is that surface's to finish. Both are true exactly on the path this
    /// matters — a retry reserves before it republishes, and a first Stop has
    /// nothing parked yet.
    private func discardParkedWorkImage(for id: UUID) async {
        guard armedDurableRetryID == id else { return }
        guard let claim = heldRetryClaim, claim.id == id else { return }
        await retryLane.discardWorkImage(claim)
    }

    /// A Work capture whose card, or whose transcript, the desk refused to
    /// hold. The capture stays pending with everything it has achieved, its
    /// bytes go somewhere that survives this process, and the failure is
    /// surfaced as retryable rather than completed: a capture reported
    /// successful with no card behind it is how a recording silently becomes
    /// composer text nobody asked for. An owed PICTURE is a different debt with
    /// its own code, settled by `settleOwedScreenshot` above every exit.
    ///
    /// For a WRITE that was refused, never for a claim that was: a capture
    /// another surface took over takes `refuseOvertakenWorkCapture` below,
    /// because parking a capture somebody else has already finished writes its
    /// retired entry back.
    private func failPendingWorkCapture(
        _ capture: VoiceCapture
    ) async -> Result<String, AppError> {
        pendingWorkCapture = capture
        // A desk write is not a speech verdict, and the taxonomy answers for it
        // in its own case: retryable, preserved, and carrying copy that names
        // the desk rather than an unexpected error.
        let surfaced = AppError.workDeskWriteFailed
        await preserveForRetry(
            error: surfaced,
            capture: capture,
            preferredLanguage: nil
        )
        state = .error(surfaced)
        return .failure(surfaced)
    }

    /// The last ownership question answered NO: another surface holds this
    /// capture and is finishing it.
    ///
    /// It PRESERVES NOTHING, and that is the whole difference from
    /// `failPendingWorkCapture` above. A refusal is not a failure of the
    /// capture — nothing was refused by the desk and nothing was lost — and the
    /// surface that overtook this one may already have finished the recording
    /// and RETIRED its queue entry. Parking here would write that entry back:
    /// the same id, this run's stale cached words, a capture the person has
    /// already been told is done. There is nothing to hand back either — the
    /// caller dropped the lapsed claim before it got here — so the only marks
    /// this leaves are the error state the sheet renders and
    /// `retryRefusedBusy`, which is the sentence that says who has it.
    ///
    /// The durability reading is still taken, because it is a reading and not a
    /// write: the recording is parked (phase one put it there before the words
    /// were ever bought), so a quit has nothing to hold for.
    private func refuseOvertakenWorkCapture(
        _ capture: VoiceCapture
    ) -> Result<String, AppError> {
        pendingWorkCapture = capture
        noteWorkDurability(capture)
        let surfaced = AppError.workDeskWriteFailed
        state = .error(surfaced)
        return .failure(surfaced)
    }
    #endif

    /// Let go of the Work capture a new recording replaces — and HAND ITS ENTRY
    /// BACK rather than delete it. Called only once a replacement microphone is
    /// actually live: recording again is a deliberate replacement, and this
    /// recorder stops being the surface that finishes the first capture.
    ///
    /// It does not stop being a capture. Nothing of it is on the desk — this
    /// lane publishes the words and only the words, and the words are exactly
    /// what it never got — so its parked entry is the ONLY copy of what somebody
    /// said, and a clear here is that recording deleted by a person who asked
    /// for a second one. What Record Again means is "I am not waiting for this
    /// one", not "throw it away": the reservation goes, the entry stays, and it
    /// surfaces as a retry card that anything can finish.
    ///
    /// The ✕ on a standing error is the other press, and it also keeps the
    /// entry (`discardPendingWorkCapture`). The only deletion in this lane is
    /// the one the retry card asks for by name.
    private func abandonPendingWorkCapture() async {
        workRecordingMaterialID = nil
        #if !os(watchOS)
        // The facts belong to the capture being replaced, so they go with it: a
        // receipt for the NEW capture must not report the old one's artifacts.
        workCaptureFacts = .none
        #endif
        #if os(macOS)
        // A capture the person replaced by recording again is one they let go
        // of, which is the other answer the quit guard accepts.
        releaseUnsavedWorkCapture()
        #endif
        guard pendingWorkCapture != nil else { return }
        pendingWorkCapture = nil
        // The entry is no longer this recorder's, so the bookkeeping that would
        // let a later step reserve, restate or retire it goes with the hold.
        armedDurableRetryID = nil
        armedRetryOmittedPicture = false
        await handBackUnfinishedRetry()
    }

    /// Take the reservation over the entry this recorder parked, before a retry
    /// touches the recording behind it.
    ///
    /// True when this recorder holds the capture, and true when there is nothing
    /// to hold — a capture with no entry has none any other surface could be
    /// finishing, and the bytes in hand are the only copy. FALSE means exactly
    /// one thing: the entry is queued and somebody else's reservation is live
    /// over it, so this retry would be a second transcription of one recording.
    ///
    /// THE QUEUE ANSWERS, not `armedDurableRetryID`. That flag records a save
    /// this recorder watched LAND, and a save can leave an entry without
    /// returning success: the sidecar and the audio commit, the screenshot's
    /// write throws, and reconciliation adopts the record anyway. The flag is
    /// then unset over an entry that is real and claimable, so a gate that
    /// treated it as proof of absence let this surface and whoever claimed that
    /// entry transcribe one recording and attach different words to one card.
    private func reserveDurableRetry(for id: UUID) async -> Bool {
        // A cached hold is a MEMORY of a reservation, and reservations expire.
        // The renewal loop deliberately never stops on a refusal — the store
        // answers the same `false` for a cross-process lock it could not take as
        // for a hold somebody overtook — so a long enough run of refused
        // renewals leaves this recorder certain it still owns a capture another
        // surface has since claimed. Ask the QUEUE rather than the memory; a
        // lapsed hold is dropped and re-taken honestly, or refused.
        if let held = heldRetryClaim, held.id == id {
            if await retryLane.confirmOwnership(held) { return true }
            stopRenewingRetryLease()
            heldRetryClaim = nil
        }
        switch await retryLane.reserve(
            id: id,
            duration: PendingRetryStore.claimLeaseDuration
        ) {
        case .claimed(let claim):
            heldRetryClaim = claim.reservationOnly
            startRenewingRetryLease()
            return true
        case .absent:
            return true
        case .heldElsewhere:
            return false
        }
    }

    /// Hand back a reservation this recorder is still holding after a retry that
    /// did not finish the capture. The entry and its recording stay exactly as
    /// they are; only the hold goes, so the next attempt does not wait it out.
    private func handBackUnfinishedRetry() async {
        stopRenewingRetryLease()
        guard let claim = heldRetryClaim else { return }
        heldRetryClaim = nil
        await retryLane.release(claim)
    }

    /// Keep the reservation alive while the speech hop runs. Without it a
    /// transcription longer than the lease loses the capture to whoever asks
    /// next — and the launch sweep could delete the recording being transcribed.
    private func startRenewingRetryLease() {
        retryLeaseRenewal?.cancel()
        retryLeaseRenewal = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(
                    nanoseconds: UInt64(Self.retryLeaseRenewalInterval * 1_000_000_000)
                )
                guard !Task.isCancelled, let self, let claim = self.heldRetryClaim else { return }
                // A refused renewal is NOT a reason to stop asking: the store
                // answers false for a cross-process lock it could not take as
                // well as for a hold somebody overtook, and stopping on the
                // first would give away a reservation that is still this
                // recorder's. Only `stopRenewingRetryLease` ends the loop.
                await self.retryLane.renew(claim)
            }
        }
    }

    private func stopRenewingRetryLease() {
        retryLeaseRenewal?.cancel()
        retryLeaseRenewal = nil
    }

    /// Retire this recorder's own queue entry, through the reservation over it.
    ///
    /// Gated on the id it armed, so an entry this process never armed — one that
    /// outlived an app launch — is left for whoever recovers it. And gated on
    /// the reservation, so a capture another surface took over is left for that
    /// surface to finish: an id-keyed clear here deleted the recording the retry
    /// card was mid-transcription on, because the desk's voice sheet and that
    /// card are reachable on one screen.
    private func releaseDurableRetry(for id: UUID) async {
        guard armedDurableRetryID == id else { return }
        stopRenewingRetryLease()
        var claim = heldRetryClaim
        heldRetryClaim = nil
        if claim?.id != id {
            claim = await retryLane.claim(
                id: id,
                duration: PendingRetryStore.claimLeaseDuration
            )
        }
        guard let claim else { return }
        armedDurableRetryID = nil
        armedRetryOmittedPicture = false
        _ = await retryLane.clear(claim)
    }

    /// The ONE place a FAILURE hands a capture to the retry lane, so the
    /// pre-flight refusal, the STT failure and the desk-write failure cannot
    /// preserve on different terms. The capture's own id is the record's id, so
    /// a Work retry recovered from it publishes the words under the id that
    /// capture already owns rather than minting a second capture beside it.
    /// No-ops unless the taxonomy says these bytes can succeed on a second
    /// attempt (`shouldPreserveForRetry`), which is what keeps a bad-input
    /// verdict from parking audio the user would only ever retry into the same
    /// refusal.
    ///
    /// It records what a later recovery cannot work out for itself: the WORDS,
    /// when recognition already succeeded and only the publication failed (so
    /// the retry publishes them instead of buying the same answer a second
    /// time), and whether the desk HOLDS them — the fact that separates a
    /// capture the board has nothing for from one whose card a person deleted,
    /// which call for opposite acts and look identical from the far side of a
    /// process death.
    ///
    /// Arming costs no other capture anything: the store is a queue keyed by
    /// capture id, so this record takes its place beside whatever is already
    /// waiting rather than displacing it.
    private func preserveForRetry(
        error: AppError,
        capture: VoiceCapture,
        preferredLanguage: String?
    ) async {
        // Every exit below is a verdict on where this capture's bytes now live,
        // so the durability reading is taken on all of them — including the two
        // that park nothing at all.
        defer { noteWorkDurability(capture) }
        guard error.shouldPreserveForRetry else { return }
        // CLAIM-GATED, and the claim is the whole question: a reservation this
        // recorder took can lapse while a speech hop runs, and the surface that
        // then claimed the capture may have finished it and RETIRED its entry.
        // A park written after that resurrects the entry — the same id, this
        // run's stale words, a capture the person has already been told is done
        // — and there is no clock that takes it back, because a Work entry the
        // desk holds nothing for is exempt from expiry by design. A recorder
        // holding no claim at all is not in that position: nobody else can be
        // finishing a capture no queue would reserve.
        if let held = heldRetryClaim, held.id == capture.id,
           await retryLane.confirmOwnership(held) == false {
            stopRenewingRetryLease()
            heldRetryClaim = nil
            return
        }
        await writeDurableRetry(
            capture: capture,
            lastErrorCode: error.errorCode,
            preferredLanguage: preferredLanguage
        )
    }

    /// PHASE ONE of a Work capture: put the recording somewhere that outlives
    /// this process, before a single word is asked for, and take the
    /// reservation that keeps another surface from finishing it underneath.
    ///
    /// This is `preserveForRetry` WITHOUT its taxonomy gate, because nothing has
    /// failed yet. A park is not a reaction to an error, it is the ordinary
    /// first step of every Work capture — so there is no error code to record,
    /// and the verdict is `.phaseOneFailed`: the desk holds nothing for this
    /// capture, which stays true until the words land.
    ///
    /// FALSE MEANS NOTHING IS PARKED, and it is the answer this whole function
    /// exists to give. `reserveDurableRetry` says "yes" for a capture that is
    /// not queued at all — correctly, because a capture nobody queued is one
    /// nobody else can be finishing — so a caller that read the reservation as
    /// proof of durability would send a recording held only in memory into the
    /// speech hop and report success over it. The WRITE is what answers, and
    /// `armedDurableRetryID` is set only by a write that landed.
    ///
    /// A capture already parked and still held is not re-written. A confirmed
    /// claim can only be minted from an entry that exists, so it IS the presence
    /// check the resume path needs: the entry is genuinely there, and this
    /// recorder is the one finishing it.
    private func parkForTranscription(_ capture: VoiceCapture) async -> Bool {
        defer { noteWorkDurability(capture) }
        if let held = heldRetryClaim, held.id == capture.id,
           await retryLane.confirmOwnership(held) {
            // Adopted as this recorder's own, so the clear at the end of the
            // capture can reach it. Holding the reservation IS holding the
            // capture; a release gated on an arm this run did not perform would
            // leave the entry offering a Try Again for work already finished.
            armedDurableRetryID = capture.id
            return true
        }
        await writeDurableRetry(capture: capture, lastErrorCode: nil, preferredLanguage: nil)
        guard armedDurableRetryID == capture.id else { return false }
        // The hold, and the renewal that keeps it alive for the length of the
        // speech hop. Refused only when another surface has this capture, and
        // the entry is durable either way — which is what was asked.
        _ = await reserveDurableRetry(for: capture.id)
        return true
    }

    /// THE ONE WRITE. Both entry points above land here, so a park taken before
    /// the speech hop and one taken after a failure cannot describe the same
    /// capture differently.
    ///
    /// THE RECORDING IS NOT WRITTEN BACK ONCE THE DESK HOLDS THE WORDS. A
    /// capture that still owes its picture is parked again after its words
    /// publish — the picture is the debt — and the recording was deleted at that
    /// publication precisely because it is waste from then on. Writing it back
    /// here resurrects the bytes this lane exists to retire, on an entry the
    /// parked picture exempts from every clock. What the entry then holds is the
    /// picture, the words and a `.published` verdict, which is the whole of what
    /// is left to settle.
    ///
    /// Best-effort: a save failure is logged inside the store and the caller
    /// still surfaces the original error — a silent swap to a storage error
    /// would tell the user the wrong thing about why their capture stopped.
    private func writeDurableRetry(
        capture: VoiceCapture,
        lastErrorCode: Int?,
        preferredLanguage: String?
    ) async {
        // A capture with NO recording of its own is not this lane's to park.
        // Every surface that recovers a queued capture begins by transcribing
        // it, so an entry holding no audio is one none of them can finish — it
        // would sit in the queue for ever offering a retry that cannot work.
        // Such a capture is held in memory only, and its picture is retried
        // from the surface that is looking at it.
        guard !capture.audio.isEmpty else { return }
        let publicationState: PendingRetryPublicationState? = retryDestination == .work
            ? (capture.materialID == nil ? .phaseOneFailed : .published)
            : nil
        // The link is recorded on its OWN terms, and the terms are not the
        // picture's bytes. Those bytes are handed to `save` below only while no
        // card holds them (`screenshotQueued ? nil : capture.screenshot`), so an
        // entry armed after the queue took the picture parks no image at all —
        // and a recovery that reconstructed the link from what is left would
        // find nothing and publish the words with no picture to fold into. A
        // Chat capture never carries one.
        #if !os(watchOS)
        let workAttachedToMaterialID: UUID? = retryDestination == .work
            ? capture.attachedPictureID
            : nil
        let recording = wordsAreOnTheDesk(capture) ? Data() : capture.audio
        #else
        let workAttachedToMaterialID: UUID? = nil
        let recording = capture.audio
        #endif
        let metadata = PendingRetryMetadata(
            id: capture.id,
            createdAt: Date(),
            audioFileURL: capture.transcriptionFileURL,
            preferredLanguage: preferredLanguage,
            attemptCount: 1,
            lastErrorCode: lastErrorCode,
            destination: retryDestination,
            transcript: capture.transcript,
            publicationState: publicationState,
            workAttachedToMaterialID: workAttachedToMaterialID
        )
        // The id is recorded only once the write LANDED. A save that threw
        // parked nothing, so there is no entry to reserve, nothing to clear, and
        // nothing another surface could be holding — and claiming otherwise
        // would have the next Try Again ask the queue for a capture that was
        // never queued and read the refusal as somebody else's hold.
        // The screenshot rides along only while no card holds it. Once it is
        // published the record must not carry a second copy: a recovery would
        // republish it (harmlessly, under the same derived id) while the bytes
        // sat in the App-Group container for as long as the entry did. A Chat
        // capture never carries one at all — the mint drops what was staged.
        do {
            try await retryLane.save(
                audioData: recording,
                metadata: metadata,
                workImageData: capture.screenshotQueued ? nil : capture.screenshot
            )
            armedRetryOmittedPicture = false
        } catch PendingRetrySaveOutcome.recordingParkedWithoutPicture {
            // The RECORDING is queued and only the picture is not. Read as a
            // plain failure this armed nothing, so the entry the store had
            // already made was one this recorder could neither reserve nor
            // retire: the next Record Again left it behind for a recovery to
            // re-transcribe a recording the person had replaced. It is armed,
            // and the picture's absence travels with it so the quit guard still
            // asks about the bytes only memory holds.
            armedRetryOmittedPicture = true
        } catch {
            return
        }
        armedDurableRetryID = capture.id
    }

    /// Does the desk hold this capture's words? The words card is the only card
    /// this lane publishes, so this is also "is anything of this capture on the
    /// board" — and it is what makes the parked recording waste.
    private func wordsAreOnTheDesk(_ capture: VoiceCapture) -> Bool {
        retryDestination == .work && capture.transcriptSettled && capture.materialID != nil
    }

    /// Whether this capture is holding a quit window open, and open or close it
    /// to match.
    ///
    /// Asked after every step that can change the answer: a publication that
    /// landed, a preservation that landed, and — the case this exists for — a
    /// preservation that did NOT. The declared window at the stop covers the few
    /// hundred milliseconds between `AudioRecorder.stopRecording()` deleting the
    /// file and the desk write copying the bytes; it is released by the function
    /// scope on the way out, which is correct for every path that ended with the
    /// bytes somewhere durable and wrong for the one that ended with them
    /// nowhere. There the audio, the picture, or both existed only in
    /// `pendingWorkCapture` while ⌘Q read an empty gateway registry and quit.
    ///
    /// BOTH artifacts, because either can be the orphan: a screenshot whose
    /// publication and preservation both failed is memory-only even while the
    /// recording is safely on the desk.
    ///
    /// A capture the queue holds is safe whatever the desk did — that is what
    /// the queue is for — so `parked` answers for both halves at once.
    ///
    /// `audioInFlight` is the declared window at the stop: while it is up the
    /// recording is not unsaved, it is BEING parked, and ⌘Q answers that by
    /// waiting rather than by asking. The two states must not be confused — a
    /// wait cannot resolve bytes nothing will take, and a question has no
    /// business interrupting a write that is about to land.
    ///
    /// `capture.materialID != nil` reads as safe because it names the card that
    /// holds this capture's WORDS. The recording is waste from that moment: the
    /// words are the artifact, they are on the desk and they sync, so there is
    /// nothing left for a quit to destroy.
    private func noteWorkDurability(_ capture: VoiceCapture, audioInFlight: Bool = false) {
        #if os(macOS)
        guard retryDestination == .work else { return }
        let parked = armedDurableRetryID == capture.id
        let audioSafe = audioInFlight || capture.audio.isEmpty
            || capture.materialID != nil || parked
        // The queue answers for the two artifacts SEPARATELY, because one arm
        // can hold the recording and not the picture: the screenshot write is
        // the only one that can fail with the recording already committed, and
        // an entry that shelters no picture is not a place the picture is safe.
        let pictureSafe = capture.screenshot == nil || capture.screenshotQueued
            || (parked && !armedRetryOmittedPicture)
        if audioSafe, pictureSafe {
            releaseUnsavedWorkCapture()
        } else {
            holdUnsavedWorkCapture(capture.id)
        }
        #endif
    }

    #if os(macOS)
    /// Declare that this recorder is holding bytes nothing durable would take.
    /// One per recorder, because one recorder holds one pending capture; a
    /// second declaration for the same capture is the same fact said twice.
    private func holdUnsavedWorkCapture(_ id: UUID) {
        guard unsavedWorkCaptureID != id else { return }
        releaseUnsavedWorkCapture()
        Self.unsavedWorkCaptureHolders = Self.unsavedWorkCaptureHolders
            .filter { $0.value.recorder != nil }
        Self.unsavedWorkCaptureHolders[ObjectIdentifier(self)] =
            UnsavedWorkCaptureHolder(recorder: self)
        unsavedWorkCaptureID = id
    }

    /// Let it go: the bytes reached somewhere durable, or the person threw the
    /// capture away. Those are the only two answers, and until one of them
    /// arrives the quit guard has a question to ask.
    private func releaseUnsavedWorkCapture() {
        guard unsavedWorkCaptureID != nil else { return }
        unsavedWorkCaptureID = nil
        Self.unsavedWorkCaptureHolders.removeValue(forKey: ObjectIdentifier(self))
        Self.unsavedWorkCaptureHolders = Self.unsavedWorkCaptureHolders
            .filter { $0.value.recorder != nil }
    }
    #endif
}

#if os(macOS) || os(iOS)
extension InAppAudioRecorder: RecordingExclusivityAuthority {
    /// Mic-authority view for the speech-exclusivity bus. True while the
    /// capture is STARTING or actively recording — NOT during `.processing` (the
    /// mic is released by then, so a reply may speak) and never on `.idle`/
    /// `.error`. Folds in `isStarting` so the startup gap is covered. Mirrors
    /// `DictationService.isActivelyRecording`.
    var isActivelyRecording: Bool {
        if isStarting { return true }
        if case .recording = state { return true }
        return false
    }
}
#endif
