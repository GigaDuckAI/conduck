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
    /// tap fire a second `recorder.startRecording()` during that gap), and on
    /// macOS it makes `isActivelyRecording` cover the startup window so an
    /// auto-speak can't slip in before `.recording` is set.
    private var isStarting = false

    init() {
        #if os(macOS)
        // macOS has NO AVAudioSession arbitration, so the in-window composer mic
        // joins the speech-exclusivity bus as a mic authority (mirrors the
        // menu-bar `DictationService`): while this recorder is starting/recording,
        // `claimForAutoSpeak` is refused so a reply can't auto-speak over a live
        // capture. Weakly held; iOS/watch never register (the bus is inert there).
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
                    let result = await self.runProcessingTask()
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
    func startRecording() async {
        guard case .idle = state, !isStarting else { return }
        // Hold a "starting" claim across the async gap below — `state` stays
        // `.idle` until `recorder.startRecording()` returns, so without this a
        // rapid double-tap would fire a second capture, and (macOS) an auto-speak
        // could slip in before `.recording` is set. Reset on EVERY exit path.
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
        // Lease held — silence every registered speaker before the mic comes up
        // (a playing reply would otherwise bleed into the capture). The mic is
        // never a registered party, so nothing stops it back. Mirrors `DictationService`.
        SpeechExclusivity.shared.claim(nil)
        #endif

        do {
            // Honor the start result: a `false` return / `.recordingFailed` means
            // the HAL rejected the start — surface an error instead of a fake
            // `.recording` that would capture nothing.
            guard try await recorder.startRecording() else {
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
        return await runProcessingTask()
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

    /// Run `finishAndUpload` inside a stored, cancellable Task so
    /// `cancelProcessing()` has a handle. Both terminal paths (mic-tap stop
    /// and duration-cap auto-stop) route through here. `Task {}` inherits
    /// the MainActor context, so `finishAndUpload` runs exactly as before.
    private func runProcessingTask() async -> Result<String, AppError> {
        // Single-flight: a duration-cap auto-stop and a near-simultaneous manual
        // Stop tap can both reach here. Join the in-flight run instead of firing
        // a second STT round-trip (double upload + double state churn).
        if let inFlight = processingTask {
            return await inFlight.value
        }
        let task = Task { await self.finishAndUpload() }
        processingTask = task
        let result = await task.value
        // Only clear OUR handle — a cancelled run resuming late must not null
        // a newer run's handle (that would silently disable its stall-Cancel).
        if processingTask == task {
            processingTask = nil
        }
        return result
    }

    /// Stop the recorder, compress, hit STTClient. Common path for both
    /// user-initiated stop and auto-stop on cap.
    private func finishAndUpload() async -> Result<String, AppError> {
        state = .processing

        guard let audioData = recorder.stopRecording(), !audioData.isEmpty else {
            state = .error(.audioMissingData)
            return .failure(.audioMissingData)
        }

        // Compress to M4A (16kHz mono AAC). Falls back to original on
        // failure — STTClient's pre-flight size guard still catches >15MB.
        let compressionResult = await AudioCompressor.compress(audioData)
        let uploadData = compressionResult.data
        let format = compressionResult.format

        // Write to a temp file for STTClient (which takes a URL + defer-deletes).
        // Extension comes from the compressor's own format truth — `.original`
        // fallbacks carry the recorder's untouched AAC M4A bytes, never WAV, so
        // no second mapping here that could contradict `AudioFormat`.
        let ext = format.fileExtension
        let audioFileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("conduck-inapp-\(UUID().uuidString).\(ext)")
        do {
            try uploadData.write(to: audioFileURL)
        } catch {
            state = .error(.audioMissingData)
            return .failure(.audioMissingData)
        }

        // Fetch settings on demand — the API key can rotate between sessions.
        // ATOMIC snapshot: pull (presetID, apiKey, provider)
        // in a single actor hop so a concurrent preset switch can't produce
        // a key/provider mismatch.
        let snapshot = await SettingsManager.shared.activeSTTSnapshot()
        let preferredLanguage = await SettingsManager.shared.getPreferredLanguage()

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

        // In-process providers (Apple on-device) need no API key —
        // the runner's TCC check is the moral equivalent. The BYO custom
        // endpoint configured with `.none` auth (keyless local server) also
        // needs no key. For every other network provider the missing-key guard
        // still applies.
        let apiKey: String
        if isAppleInProcess || snapshot.customConfig?.auth == STTAuthScheme.none {
            apiKey = ""
        } else if let key = snapshot.apiKey, !key.isEmpty {
            apiKey = key
        } else {
            try? FileManager.default.removeItem(at: audioFileURL)
            state = .error(.sttMissingAPIKey)
            return .failure(.sttMissingAPIKey)
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
                try? FileManager.default.removeItem(at: audioFileURL)
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
                // (can't re-read a different persisted engine). `STTClient`'s
                // `defer` doesn't run here, so we delete the temp file ourselves
                // on every exit (mirrors the cleanup it would have done).
                defer { try? FileManager.default.removeItem(at: audioFileURL) }
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

            guard !response.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                // Empty/whitespace-only text = no transcribable speech (silence).
                // Surface the accurate "no speech" message, NOT the catch-all
                // `.apiFailure` (which renders the misleading "Something glitched
                // on our end" banner). This guard returns directly without hitting
                // the retry `catch` below, so it's purely a message change.
                state = .error(.noSpeechDetected)
                return .failure(.noSpeechDetected)
            }

            CompletionFeedbackPlayer.play(mode: "sound")
            state = .idle
            return .success(response.text)

        } catch let error as AppError {
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
            if error.shouldPreserveForRetry {
                let metadata = PendingRetryMetadata(
                    id: UUID(),
                    createdAt: Date(),
                    audioFileURL: audioFileURL,
                    preferredLanguage: preferredLanguage,
                    attemptCount: 1,
                    lastErrorCode: error.errorCode
                )
                // Best-effort — save failure is logged inside the store but
                // we still surface the original STT error to the user.
                try? await PendingRetryStore.shared.save(audioData: uploadData, metadata: metadata)
            }
            // STTClient.transcribe's `defer` already removed audioFileURL.
            state = .error(error)
            return .failure(error)

        } catch {
            if Task.isCancelled || error is CancellationError {
                state = .idle
                return .failure(.unknown(CancellationError()))
            }
            state = .error(.unknown(error))
            return .failure(.unknown(error))
        }
    }
}

#if os(macOS)
extension InAppAudioRecorder: RecordingExclusivityAuthority {
    /// Mic-authority view for the macOS speech-exclusivity bus. True while the
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
