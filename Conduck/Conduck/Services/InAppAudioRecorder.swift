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
// The other direction is not symmetrical: a desk write that FAILS is a
// retryable error, never a quiet fall back to text. The capture stays pending
// with whatever it achieved — its bytes, its card, its words — and finishes
// only when a card owns the words, because a Work capture that reports success
// with no card behind it has turned a recording into composer text nobody asked
// for. Chat captures are untouched by all of it: their transcript IS the
// artifact, and a conversation has no card to hold bytes.
//
// `PendingRetryStore` is ONE overwriting slot for the whole app, so this class
// treats a claim on it as a resource with a lifetime rather than a fire-and-
// forget save. It arms the slot only while a capture is genuinely unfinished;
// it RELEASES the claim the moment the capture completes or the person starts
// over, so nothing offers to re-transcribe an answered capture; it lets go of a
// capture only once a replacement microphone is actually live, so a refused
// start leaves the previous capture's Try Again exactly where it was; and it
// declines to arm at all when doing so would evict a record holding the only
// copy of some other lane's recording — this capture's audio is already a card
// on the desk by then, so what it would spend is somebody else's audio to save
// its own words.

import Foundation
import AVFoundation
import Observation
import Speech

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
        /// The desk card this capture published, once it has one.
        var materialID: UUID?
        /// The words, once speech recognition has produced them. Retained so a
        /// retry that owes only the attachment does not spend a second round
        /// trip on the same bytes for the same answer.
        var transcript: String?

        init(id: UUID, audio: Data, format: AudioFormat) {
            self.id = id
            self.audio = audio
            self.format = format
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

    /// Stands in for the App-Group retry slot. `PendingRetryStore.shared` is a
    /// process-global singleton over one file every capture test in the bundle
    /// shares, and the claims here are about WHICH capture this class arms,
    /// releases and refuses to evict — a property of this class, not of the
    /// file format.
    var retryLaneForTesting: (any PendingRetrySlotWriting)?

    /// Stands in for the microphone coming up. There is no input device on a
    /// simulator, and the claim this seam exists for is an ORDERING one: the
    /// capture a new recording replaces is let go only after the replacement
    /// microphone is live, so a refused start leaves the previous capture — and
    /// the Try Again that finishes it — untouched. Returns whether the mic came
    /// up, exactly as `AudioRecorder.startRecording()` does.
    var microphoneStartForTesting: (@MainActor () async -> Bool)?

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

    /// The single retry slot this recorder arms, releases and reads.
    private var retryLane: any PendingRetrySlotWriting {
        #if CONDUCK_TESTING
        return retryLaneForTesting ?? PendingRetryStore.shared
        #else
        return PendingRetryStore.shared
        #endif
    }

    /// The capture whose claim on the single retry slot this recorder itself
    /// armed, so it releases only what it took. A slot armed by another process
    /// — a capture that outlived an app launch — belongs to whichever surface
    /// recovers it, and clearing it from here would delete a recording this
    /// recorder is not finishing.
    private var armedDurableRetryID: UUID?

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
        // A HAL-aborted capture (delegate `successfully: false`) with no user
        // stop must not strand us in `.recording` — surface it as an error so
        // the composer leaves the recording UI instead of hanging.
        recorder.onRecordingFailed = { [weak self] in
            guard let self else { return }
            if case .recording = self.state {
                self.state = .error(.audioMissingData)
            }
        }
    }

    // MARK: - Public API

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
        let speechStatus = await VoicePermissions.ensureSpeechRecognitionForActiveProvider()
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
    /// stopped: publish the card if none landed, recognize the words if none
    /// were recovered, and write them onto that same card.
    ///
    /// This is what a retry offered beside a failed Work capture must do. The
    /// alternative — starting a new recording — leaves the first card on the
    /// desk without its words and puts a second one beside it, which is why
    /// recording again is a separate, separately labelled action.
    @discardableResult
    func retryWorkCapture() async -> Result<String, AppError> {
        guard let capture = pendingWorkCapture else {
            return .failure(.audioMissingData)
        }
        state = .processing
        return await runProcessingTask { await self.finishAndUpload(resuming: capture) }
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
    func cancelRecording() {
        recorder.cancelRecording()
        state = .idle
    }

    /// Reset from `.error(...)` back to `.idle` so the user can try again.
    func dismissError() {
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
            guard let audioData = recorded, !audioData.isEmpty else {
                state = .error(.audioMissingData)
                return .failure(.audioMissingData)
            }

            // Compress to M4A (16kHz mono AAC). Falls back to original on
            // failure — STTClient's pre-flight size guard still catches >15MB.
            let compressionResult = await AudioCompressor.compress(audioData)
            capture = VoiceCapture(
                id: UUID(),
                audio: compressionResult.data,
                format: compressionResult.format
            )

            #if !os(watchOS)
            // The Work lane holds its capture until a card owns the words, so a
            // failure anywhere below has something to retry from.
            if retryDestination == .work { pendingWorkCapture = capture }
            #endif
        }

        #if !os(watchOS)
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
        if let materialID = capture.materialID {
            do {
                switch try await WorkVoiceCaptureCoordinator.attachTranscript(
                    transcript,
                    toRecording: materialID,
                    store: workStore
                ) {
                case .attached:
                    pendingWorkCapture = nil
                case .recordingMissing, .notAudio:
                    // This capture owns no recording any more — deleted while
                    // recognition was in flight, or an id that names somebody
                    // else's card. Trying again cannot change either answer and
                    // the words must not be lost, so the claim is dropped and
                    // the host routes them the way it did before there were
                    // cards.
                    workRecordingMaterialID = nil
                    pendingWorkCapture = nil
                }
            } catch {
                // The card is on the desk and the words are held for it. A
                // capture reported complete here would strand an untranscribed
                // recording while its own transcript went into a composer.
                return await failPendingWorkCapture(capture)
            }
        }

        // The capture is finished: the words are on its card, or it owns no
        // card and the host has them. Its claim on the single retry slot is
        // released here, because a resolved claim left armed is one the retry
        // card offers to re-transcribe — and one an unrelated capture will
        // silently displace, deleting audio nobody is waiting for any more.
        if retryDestination == .work, pendingWorkCapture == nil {
            await releaseDurableRetry(for: capture.id)
        }
        #endif

        CompletionFeedbackPlayer.play(mode: "sound")
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
    /// A Work capture whose card, or whose transcript, the desk refused to
    /// hold. The capture stays pending with everything it has achieved, its
    /// bytes go somewhere that survives this process, and the failure is
    /// surfaced as retryable rather than completed: a capture reported
    /// successful with no card behind it is how a recording silently becomes
    /// composer text nobody asked for.
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

    /// Let go of the Work capture a new recording replaces, and of its claim on
    /// the single retry slot. Called only once a replacement microphone is
    /// actually live: recording again is a deliberate replacement, and the card
    /// this capture published — if it got one — keeps its bytes on the desk
    /// either way. What must not survive is the durable claim, which the new
    /// capture is about to need and whose recovery would re-transcribe a
    /// recording the person has already replaced.
    private func abandonPendingWorkCapture() async {
        workRecordingMaterialID = nil
        guard let abandoned = pendingWorkCapture else { return }
        pendingWorkCapture = nil
        await releaseDurableRetry(for: abandoned.id)
    }

    /// Release this recorder's own claim on the retry slot. Gated on the id it
    /// armed, so a slot won by another capture in the meantime — or one this
    /// process never armed at all — is left for whoever owns it.
    private func releaseDurableRetry(for id: UUID) async {
        guard armedDurableRetryID == id else { return }
        armedDurableRetryID = nil
        _ = await retryLane.clear(ifCurrentID: id)
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
    /// It also declines to arm at all when arming would evict a record holding
    /// the only copy of a recording. The slot is one overwriting slot for the
    /// whole app, and a capture whose own recording is already a card on the
    /// desk owes only its words: spending somebody else's audio to save them is
    /// the wrong trade in every direction. The words are still held in memory,
    /// so the sheet's Try Again finishes this capture regardless; only a
    /// process death costs them.
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
        let publicationState: PendingRetryPublicationState? = retryDestination == .work
            ? (capture.materialID == nil ? .phaseOneFailed : .published)
            : nil
        if publicationState == .published,
           let incumbent = await retryLane.currentSlot(),
           incumbent.id != capture.id,
           !incumbent.hasDurableRecording {
            return
        }
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
        try? await retryLane.save(
            audioData: capture.audio,
            metadata: metadata,
            workImageData: nil
        )
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
