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
// The WORK lane (`retryDestination == .work`, the desk's own voice sheet) runs
// a second, two-phase publication over the same capture:
// `WorkVoiceCaptureCoordinator` puts the compressed recording on the desk as a
// playable card BEFORE the transcription hop, and writes the transcript onto
// that same card afterwards. So a refused key, an offline device or an
// abandoned request costs the words and never the recording.
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
// the recording or the words. What it does cost is the CAPTURE: a picture still
// owed leaves the capture unfinished and retryable at EVERY exit — silence and
// a missing key included, which are terminal for the words and say nothing
// about the picture — answering with `.workScreenshotWriteFailed`, keeping its
// queue entry as the only place those bytes survive this process, and letting
// `workCaptureFacts` say artifact by artifact what actually landed.
//
// The other direction is not symmetrical: a desk write that FAILS is a
// retryable error, never a quiet fall back to text. The capture stays pending
// with whatever it achieved — its bytes, its card, its words — and finishes
// only when a card owns the words, because a Work capture that reports success
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
nonisolated protocol PendingRetryLaneReserving: PendingRetryQueueWriting {
    /// Reserve exactly the capture named, for the surface that ARMED it.
    /// Nil when it is not queued, when another reservation is live over it, or
    /// when its recording cannot be read.
    func claim(id: UUID, duration: TimeInterval) async -> PendingRetryClaim?

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
}

extension PendingRetryLaneReserving {
    /// A lane that parks no screenshot has none to retire, and answering
    /// "nothing was retired" is the honest reply. The store overrides it; this
    /// default is what lets a lane double that never stores image bytes conform
    /// without pretending to delete any.
    @discardableResult
    func discardWorkImage(_ claim: PendingRetryClaim) async -> Bool { false }
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

    /// The Work desk card that owns this capture's words. Nil for every Chat
    /// capture, and for a Work capture whose id turned out to name no recording
    /// of its own — the Shortcuts lane publishes none, and a person can delete
    /// a card while speech recognition is in flight. Only then may the host
    /// hand the words to its own composer: a card that exists and could not be
    /// written to is a retry, not a text fallback. Cleared once a replacement
    /// recording is actually live, so a second capture can never claim the
    /// first one's card and a refused start never strands the first one.
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
        /// A card owns the audio: phase one published it and nothing has since
        /// reported that card gone.
        var recordingOnDesk: Bool
        /// The transcript is written onto that card.
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
        /// written. It names the desk card the recording becomes AND is the id
        /// the pending-retry record carries, so a retry hours later repairs
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
        /// The desk card this capture published, once it has one.
        var materialID: UUID?
        /// True once phase two has ANSWERED for these words — attached them, or
        /// reported that the card they belong to is gone. Both are final, so a
        /// resumed capture must not ask again: the question is a throwing store
        /// read, and its failure would report a desk error for a capture whose
        /// words were settled minutes ago. Named for the settlement rather than
        /// for attachment because the second answer settles the words just as
        /// finally as the first, without putting them on any card.
        var transcriptSettled = false
        /// The desk has ANSWERED that this capture's card is gone — the attach
        /// step's own `.recordingMissing`. It is remembered on the capture
        /// because `materialID` is only a memory of a write, and a resumed
        /// capture that re-derived presence from it would report a card the
        /// desk has already denied.
        var recordingConfirmedGone = false
        /// The words, once speech recognition has produced them. Retained so a
        /// retry that owes only the attachment does not spend a second round
        /// trip on the same bytes for the same answer.
        var transcript: String?

        /// True while this capture still carries a picture no card holds. What
        /// the retry republishes, what the durable record has to carry, and
        /// what keeps a capture whose words already landed from being retired.
        var owesScreenshot: Bool { screenshot != nil && !screenshotQueued }

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
    /// stopped: publish the picture if no card holds it, publish the recording
    /// if none landed, recognize the words if none were recovered, and write
    /// them onto that same card.
    ///
    /// The picture goes first and answers only for itself. A capture can owe
    /// the screenshot, the recording, the words, or any combination, and each
    /// step asks its own question — so a retry after a refused picture does not
    /// re-transcribe, and a retry after a refused transcription does not
    /// republish a picture that already landed.
    ///
    /// The picture-only case therefore costs nothing but the publication: every
    /// other step finds its work already done and skips it, so ONE tap turns a
    /// capture whose words are already on the desk into a finished one, with no
    /// provider round trip and no second card anywhere.
    ///
    /// This is what a retry offered beside a failed Work capture must do. The
    /// alternative — starting a new recording — leaves the first card on the
    /// desk without its words and puts a second one beside it, which is why
    /// recording again is a separate, separately labelled action.
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
    /// The durable entry is deliberately NOT retired. It was written at the
    /// first failure and is the recovery for everything this capture still
    /// owes, so dismissing the surface hands the capture to the retry lane
    /// rather than deleting it. A picture that never reached the queue and a
    /// capture that was never parked (one with no recording of its own) are the
    /// two things this press really does end, and both are already the state
    /// the person is looking at.
    func discardPendingWorkCapture() {
        #if !os(watchOS)
        pendingWorkCapture = nil
        workRecordingMaterialID = nil
        workCaptureFacts = .none
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

    /// Stop the recorder, compress, transcribe, and — on the Work lane — put the
    /// recording on the desk and its words onto that card. Common path for a
    /// user-initiated stop, an auto-stop on the duration cap, and a retry.
    ///
    /// Re-entrant BY DESIGN: `resuming` carries what a capture already
    /// achieved, so a retry stops nothing, compresses nothing, publishes only
    /// if no card landed and transcribes only if no words did. Both Work phases
    /// key off the capture's single id and both are idempotent under it, so a
    /// second run can neither duplicate the recording nor duplicate the words.
    private func finishAndUpload(
        resuming resumed: VoiceCapture? = nil
    ) async -> Result<String, AppError> {
        let outcome = await runCaptureToCompletion(resuming: resumed)
        #if !os(watchOS)
        return await settleOwedScreenshot(after: outcome)
        #else
        return outcome
        #endif
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
        // stale, and no exit before the attach step asks the desk. Gated on the
        // debt instead, an emptied desk still reported a recording and a
        // picture sitting on it — the exact untruth this refresh exists to
        // stop. The durable `.published` verdict stays as it is, because it
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
    /// observations: a card is deleted while recognition is in flight often
    /// enough that the attach step has a whole outcome for it, and every exit
    /// that returns BEFORE that step never asks. A person who cleared their
    /// desk mid-capture must not be told either artifact is waiting on it.
    ///
    /// Words cannot be on a card that is gone, so they fall with the recording.
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
                workCaptureFacts.recordingOnDesk = present
                if !present {
                    workCaptureFacts.wordsOnDesk = false
                    // LATCHED onto the capture in hand, exactly as the attach
                    // step's own `.recordingMissing` is. A later pass cannot ask
                    // again when the store has stopped answering, and without
                    // this memory the historical id would be all it had to go
                    // on — which is how a cleared desk came to be described as
                    // holding a recording.
                    pendingWorkCapture?.recordingConfirmedGone = true
                }
            }
        } else {
            workCaptureFacts.recordingOnDesk = false
            workCaptureFacts.wordsOnDesk = false
        }

        guard workCaptureFacts.screenshotStaged else { return }
        let pictureID = WorkVoiceScreenshotCoordinator.materialID(forCapture: capture.id)
        if let present = await deskHoldsMaterial(pictureID) {
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
        if let resumed {
            capture = resumed
        } else {
            state = .processing

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
                // as saved.
                noteScreenshotPresence(await deskHoldsMaterial(materialID) == true)
                // The picture is durable now, so the parked copy is no longer
                // the only one — and a parked copy left behind would go on
                // telling the expiry sweep this entry shelters an irreplaceable
                // image, exempting it from the clock for ever.
                await discardParkedWorkImage(for: capture.id)
            } else {
                // The only shelter left for these bytes. The verdict written
                // here is the conservative one — phase one has not run, so the
                // record says the desk holds no recording — and it is corrected
                // the moment the recording lands, because a stale
                // `.phaseOneFailed` is licence for a later recovery to
                // resurrect a card the person deleted.
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

        // PHASE 1 of the Work voice capture: the recording reaches the desk
        // before transcription is attempted, so a failure below costs the words
        // and never the recording. The coordinator COPIES these bytes into the
        // store; the temporary file written afterwards is ours alone.
        if retryDestination == .work, capture.materialID == nil {
            do {
                let card = try await WorkVoiceCaptureCoordinator.publishRecording(
                    captureID: capture.id,
                    audio: capture.audio,
                    fileExtension: capture.format.fileExtension,
                    mimeType: capture.format.mimeType,
                    store: workStore
                )
                capture.materialID = card.id
                pendingWorkCapture = capture
                workRecordingMaterialID = card.id
                // The ONE place presence is ASSERTED rather than observed, and
                // what it asserts is the line above it. A resumed capture never
                // comes through here, which is the point: re-deriving presence
                // from `materialID` on a resume undoes an absence the desk has
                // already answered for, because the id outlives the card. Every
                // other writer is a lookup.
                workCaptureFacts.recordingOnDesk = true
                // A refused screenshot may already have armed this capture's
                // entry, and it did so with the only verdict true at the time:
                // the desk held no recording. It holds one NOW, and the record
                // has to say so before anything else can end this capture —
                // silence, a missing key, a cancelled hop. `.phaseOneFailed`
                // left standing tells a recovery hours later to republish a
                // recording, which resurrects a card the person has deleted.
                if armedDurableRetryID == capture.id {
                    await preserveForRetry(
                        error: .workDeskWriteFailed,
                        capture: capture,
                        preferredLanguage: nil
                    )
                }
            } catch {
                // The recording exists only in this process. Transcribing on
                // and handing the words to a composer would report a Work
                // capture complete that has no card at all, so the capture
                // stays pending, its bytes go somewhere durable, and the person
                // is offered the retry that finishes it.
                return await failPendingWorkCapture(capture)
            }
        }
        #endif

        // A retry that owes only the attachment skips the whole speech hop:
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
                // taxonomy calls for. The card that could not get words stands
                // on the desk, playable, and keeps this capture retryable.
                return .failure(error)
            }
        }

        guard let transcript = capture.transcript else {
            // Unreachable: the branch above either assigned or returned.
            state = .error(.audioMissingData)
            return .failure(.audioMissingData)
        }

        #if !os(watchOS)
        // PHASE 2: the words join the recording they came from.
        //
        // Asked ONCE per capture. A resumed capture that owed only its picture
        // has words the desk answered for minutes ago, and asking again is a
        // throwing store read whose failure would report a refused recording
        // for a capture whose recording was never in question.
        if let materialID = capture.materialID, !capture.transcriptSettled {
            do {
                switch try await WorkVoiceCaptureCoordinator.attachTranscript(
                    transcript,
                    toRecording: materialID,
                    store: workStore
                ) {
                case .attached:
                    capture.transcriptSettled = true
                    pendingWorkCapture = nil
                    workCaptureFacts.wordsOnDesk = true
                case .recordingMissing, .notAudio:
                    // This capture owns no recording any more — deleted while
                    // recognition was in flight, or an id that names somebody
                    // else's card. Trying again cannot change either answer and
                    // the words must not be lost, so the claim is dropped and
                    // the host routes them the way it did before there were
                    // cards.
                    capture.transcriptSettled = true
                    capture.recordingConfirmedGone = true
                    workRecordingMaterialID = nil
                    pendingWorkCapture = nil
                    // The card this capture published is gone, so neither it
                    // nor its words are on the desk any more, whatever phase
                    // one observed a moment ago.
                    workCaptureFacts.recordingOnDesk = false
                    workCaptureFacts.wordsOnDesk = false
                }
            } catch {
                // The card is on the desk and the words are held for it. A
                // capture reported complete here would strand an untranscribed
                // recording while its own transcript went into a composer.
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
            // User-initiated cancel (stall affordance): the transcribe layer may
            // surface cooperative cancellation as a mapped AppError (URLError
            // .cancelled → network taxonomy), so check the task flag, not the
            // error type. Cancel is not a failure — return to idle with no
            // banner and no retry save; the user chose to abandon the capture.
            if Task.isCancelled {
                state = .idle
                return .failure(.unknown(CancellationError()))
            }
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
    #endif

    /// Let go of the Work capture a new recording replaces, and of its queue
    /// entry. Called only once a replacement microphone is actually live:
    /// recording again is a deliberate replacement, and the card this capture
    /// published — if it got one — keeps its bytes on the desk either way. What
    /// must not survive is the queue entry, whose recovery would re-transcribe
    /// a recording the person has already replaced.
    private func abandonPendingWorkCapture() async {
        workRecordingMaterialID = nil
        #if !os(watchOS)
        // The facts belong to the capture being replaced, so they go with it: a
        // receipt for the NEW capture must not report the old one's artifacts.
        workCaptureFacts = .none
        #endif
        guard let abandoned = pendingWorkCapture else { return }
        pendingWorkCapture = nil
        await releaseDurableRetry(for: abandoned.id)
    }

    /// Take the reservation over the entry this recorder parked, before a retry
    /// touches the recording behind it.
    ///
    /// True when this recorder holds the capture, and true when there is nothing
    /// to hold — a capture whose durable write never landed, or one this process
    /// never armed, has no entry any other surface could be finishing, and the
    /// bytes in hand are the only copy either way. FALSE means exactly one
    /// thing: the entry is queued and somebody else's reservation is live over
    /// it, so this retry would be a second transcription of one recording.
    private func reserveDurableRetry(for id: UUID) async -> Bool {
        guard armedDurableRetryID == id else { return true }
        if let held = heldRetryClaim, held.id == id { return true }
        guard let claim = await retryLane.claim(
            id: id,
            duration: PendingRetryStore.claimLeaseDuration
        ) else {
            return false
        }
        heldRetryClaim = claim.reservationOnly
        startRenewingRetryLease()
        return true
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
        _ = await retryLane.clear(claim)
    }

    /// The ONE place this recorder hands a capture to the retry lane, so the
    /// pre-flight refusal, the STT failure and the desk-write failure cannot
    /// preserve on different terms. The capture's own id is the record's id, so
    /// a Work retry recovered from it names the recording card that capture
    /// already published rather than minting a second capture beside it.
    /// No-ops unless the taxonomy says these bytes can succeed on a second
    /// attempt (`shouldPreserveForRetry`), which is what keeps a bad-input
    /// verdict from parking audio the user would only ever retry into the same
    /// refusal.
    ///
    /// It records what a later recovery cannot work out for itself: the WORDS,
    /// when recognition already succeeded and only the write onto the card
    /// failed (so the retry attaches them instead of buying the same answer a
    /// second time), and whether phase one PUBLISHED — the fact that separates
    /// a recording the desk never held from a card a person deleted, which call
    /// for opposite acts and look identical from the far side of a process
    /// death.
    ///
    /// Arming costs no other capture anything: the store is a queue keyed by
    /// capture id, so this record takes its place beside whatever is already
    /// waiting rather than displacing it.
    ///
    /// Best-effort: a save failure is logged inside the store and the caller
    /// still surfaces the original error — a silent swap to a storage error
    /// would tell the user the wrong thing about why their capture stopped.
    private func preserveForRetry(
        error: AppError,
        capture: VoiceCapture,
        preferredLanguage: String?
    ) async {
        guard error.shouldPreserveForRetry else { return }
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
        let metadata = PendingRetryMetadata(
            id: capture.id,
            createdAt: Date(),
            audioFileURL: capture.transcriptionFileURL,
            preferredLanguage: preferredLanguage,
            attemptCount: 1,
            lastErrorCode: error.errorCode,
            destination: retryDestination,
            transcript: capture.transcript,
            publicationState: publicationState
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
        guard (try? await retryLane.save(
            audioData: capture.audio,
            metadata: metadata,
            workImageData: capture.screenshotQueued ? nil : capture.screenshot
        )) != nil else { return }
        armedDurableRetryID = capture.id
    }
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
