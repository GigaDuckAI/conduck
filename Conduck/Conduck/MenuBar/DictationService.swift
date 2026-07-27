// SPDX-License-Identifier: Apache-2.0

#if os(macOS)
// Conduck
// DictationService.swift
//
// macOS menu-bar capture pipeline: record → STT (Mistral Voxtral) →
// HAND THE TRANSCRIPT TO THE COORDINATOR.
//
// Terminal step (`spec.md "Per-Surface Behavior → macOS"`): the STT-success step
// does NOT copy to clipboard, enter `.done`, or auto-dismiss.
// Instead it invokes `onTranscript: (String) -> Void` (set by
// `MenuBarCoordinator`) which forwards the transcript to the active
// `ConversationDetailViewModel.sendUserTurn(_:)` (the agent round-trip). The
// service returns to `.idle` once the transcript is handed off; the
// conversation thread + in-flight UX live on the VM, not here. This service
// owns ONLY the audio→STT hop (plus its `PendingRetryStore` cover).
//
// Pipeline:
//   1. `toggleRecording()` flips state idle → recording (or stops if recording).
//   2. `stopAndProcess()` writes audio to a temp file URL, transitions to .processing.
//   3. `processAudio()` reads API key + preferred language from SettingsManager,
//      calls `STTClient.shared.transcribe(audioFileURL:apiKey:language:)`.
//   4. Success: hand the transcript to `onTranscript`, state → .idle.
//   5. Transient failure (sttServerError/sttProviderUnreachable/persistentNetworkFailure):
//      save audio + metadata to PendingRetryStore, state → .error(isRetryable: true).
//   6. Non-retryable failure (sttAuthFailed/sttQuotaExceeded/audioInvalid/…):
//      state → .error(isRetryable: false).
//
// Pre-recording PendingRetryGuard is intentionally NOT used (per locked
// decision): macOS runs in-process on the main actor; no OS-kill risk between
// startRecording and stopAndProcess. Audio is preserved reactively on STT
// error only.

import AppKit
import AVFoundation
import Speech

/// Recording/transcription states for the menu bar capture flow.
///
/// There is no terminal `.done(text:)` state — STT success does not render a
/// "Copied to clipboard" terminal view. The transcript is handed to
/// `DictationService.onTranscript` and the service returns to `.idle`; the
/// agent reply (and its in-flight UX) lives on `ConversationDetailViewModel`,
/// surfaced by the popover's hosted `ConversationThreadView`. Only the
/// audio→STT lifecycle is modelled here.
enum DictationState: Equatable {
    case idle
    case recording
    case processing
    case error(message: String, isRetryable: Bool)
}

/// Orchestrates the menu-bar dictation pipeline: record → Mistral Voxtral →
/// clipboard. State is observed by `MenuBarController` (icon + popover) and
/// `DictationPopoverView` (compact UI). Single-instance, main-actor isolated.
@Observable
@MainActor
final class DictationService: RecordingExclusivityAuthority {
    private(set) var state: DictationState = .idle
    private(set) var recordingTime: TimeInterval = 0

    /// Terminal STT-success hook. Set by `MenuBarCoordinator`; invoked on
    /// the main actor with the decoded transcript the instant transcription
    /// succeeds. The coordinator forwards it to the active
    /// `ConversationDetailViewModel.sendUserTurn(_:)` (the agent round-trip).
    /// Default is a no-op so the service is usable standalone (previews/tests).
    ///
    /// This service is now the menu-bar / ⌘⇧1 quick-capture path ONLY (always
    /// direct-send). The in-window composer has its own host-owned
    /// `InAppAudioRecorder` (review-then-send into the draft), so the old
    /// `.composer` transcript-destination latch is gone.
    var onTranscript: (String) -> Void = { _ in }

    /// Typed mirror of the last AppError, set when `state` transitions to
    /// `.error`. The popover may branch on this for retryability hints; for
    /// V1 it's primarily an inspection aid (no inline upgrade card).
    private(set) var lastError: AppError?

    /// True between the soft-warning fire (T-60 s) and the hard cap (300 s).
    /// Drives the amber timer in `DictationPopoverView.recordingView`.
    private(set) var nearMaxDuration: Bool = false

    private let recorder = AudioRecorder()
    private var recordingStartTime: Date?
    private var displayTimer: Timer?

    init() {
        // Join the exclusivity bus as a mic authority: `claimForAutoSpeak`
        // consults it so the quick-lane arrival speak stays silent while a
        // capture is live. Weakly registered — this (the coordinator's popover
        // service) coexists with the main window's `InAppAudioRecorder` (also a
        // registered authority), and with SwiftUI's throwaway `@State` default
        // re-evaluations; the bus reports any-live-instance-recording.
        SpeechExclusivity.shared.register(recordingAuthority: self)
        recorder.onRecordingFinished = { [weak self] wasAutoStopped in
            Task { @MainActor in
                guard let self else { return }
                if wasAutoStopped {
                    // Audible cue so the user knows the cap fired (vs. wondering
                    // why recording silently stopped). Independent of any future
                    // user completion-feedback preference.
                    CompletionFeedbackPlayer.play(mode: "sound")
                }
                self.stopAndProcess()
            }
        }
        recorder.onWarningFired = { [weak self] in
            Task { @MainActor in
                self?.nearMaxDuration = true
            }
        }
        // A HAL-aborted capture (delegate `successfully: false`) with no user
        // stop must not strand the popover in `.recording` — that keeps the
        // display timer running AND (now) holds the mic lease against the window
        // composer until the next click. Roll to `.error` so the lease releases.
        recorder.onRecordingFailed = { [weak self] in
            Task { @MainActor in
                guard let self, self.state == .recording else { return }
                self.stopDisplayTimer()
                self.state = .error(
                    message: String(localized: "Recording stopped unexpectedly. Try again."), // xcstrings: chat-ui-mac-freeze
                    isRetryable: false
                )
            }
        }
    }

    // MARK: - Public Actions

    /// Toggle recording: idle → recording, recording → processing. The
    /// transcript always direct-sends (this is the menu-bar / ⌘⇧1 quick-capture
    /// path); the in-window composer's review-then-send flow lives on its own
    /// `InAppAudioRecorder`, not here.
    func toggleRecording() {
        switch state {
        case .idle, .error:
            startRecording()
        case .recording:
            stopAndProcess()
        case .processing:
            break // Can't toggle during processing
        }
    }

    /// Cancel an in-progress recording without processing, or dismiss an error state.
    func cancelRecording() {
        switch state {
        case .recording:
            recorder.cancelRecording()
            stopDisplayTimer()
            state = .idle
            lastError = nil
        case .error:
            state = .idle
            lastError = nil
        default:
            break
        }
    }

    /// Surface a post-STT hand-off failure on the SAME `.error` surface the
    /// popover renders for STT failures. Used by `MenuBarCoordinator` when the
    /// conversation mint fails AFTER a successful transcription — the only
    /// error channel the popover footer reads is this service's state.
    /// `isRetryable: false` because there is no saved audio behind this error
    /// (STT succeeded and cleared the retry store); the coordinator owns the
    /// transcript-level Retry affordance (`retryPendingFailedTurn`). Guarded to
    /// `.idle` so it never clobbers a live capture the user has since started.
    /// Returns whether the error was actually presented — on the `false`
    /// (no-op) branch the caller must NOT keep recovery state behind it, or an
    /// invisible stash would hijack a later, unrelated error's Retry.
    func presentHandoffError(message: String) -> Bool {
        guard state == .idle else { return false }
        lastError = nil
        state = .error(message: message, isRetryable: false)
        return true
    }

    /// Retry the last failed transcription from PendingRetryStore.
    /// Reads the audio file path + preferredLanguage from the simplified
    /// 6-field `PendingRetryMetadata`; resolves the API key fresh at retry
    /// time so a rotated key takes effect.
    func retryLast() {
        Task {
            guard case .error = state else { return }
            lastError = nil
            state = .processing

            guard let pending = await PendingRetryStore.shared.load() else {
                state = .error(
                    message: String(localized: "No saved recording to retry."), // xcstrings
                    isRetryable: false
                )
                return
            }

            // ATOMIC snapshot: (presetID, apiKey, provider)
            // resolved in one actor hop so a concurrent preset switch can't
            // produce a key/provider mismatch on retry.
            let snapshot = await SettingsManager.shared.activeSTTSnapshot()
            // In-process providers (Apple on-device) need no key. The
            // BYO custom endpoint with `.none` auth (keyless local server) also
            // needs no key.
            let apiKey: String
            if snapshot.provider.transport == .inProcess || snapshot.customConfig?.auth == STTAuthScheme.none {
                apiKey = ""
            } else if let key = snapshot.apiKey, !key.isEmpty {
                apiKey = key
            } else {
                state = .error(
                    message: AppError.sttMissingAPIKey.localizedDescription,
                    isRetryable: false
                )
                return
            }

            // Re-materialize the saved audio bytes to a fresh temp file URL —
            // PendingRetryStore.load returns Data, and STTClient.transcribe
            // owns the file's lifecycle via defer-remove.
            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("conduck_retry_\(UUID().uuidString).m4a")
            do {
                try pending.audioData.write(to: tempURL, options: [.atomic])
            } catch {
                state = .error(
                    message: String(localized: "Couldn't stage the retry audio."), // xcstrings
                    isRetryable: false
                )
                return
            }

            do {
                let response = try await STTClient.shared.transcribe(
                    audioFileURL: tempURL,
                    apiKey: apiKey,
                    language: pending.metadata.preferredLanguage,
                    provider: snapshot.provider,
                    customModel: snapshot.customModel,
                    customConfig: snapshot.customConfig
                )
                let trimmed = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else {
                    state = .error(
                        message: String(localized: "Transcription returned empty text. Please try again."), // xcstrings
                        isRetryable: true
                    )
                    return
                }
                await PendingRetryStore.shared.clear()
                // Hand off to the agent round-trip rather than copy to
                // clipboard. Return to idle — the conversation thread + reply
                // in-flight UX live on the coordinator's VM (popover).
                state = .idle
                onTranscript(trimmed)
            } catch let error as AppError {
                if error.shouldPreserveForRetry {
                    // Audio still on disk in PendingRetryStore — re-save metadata
                    // with bumped attempt count so the UI surfaces "Retry again".
                    try? await PendingRetryStore.shared.save(
                        audioData: pending.audioData,
                        metadata: PendingRetryMetadata(
                            id: pending.metadata.id,
                            createdAt: pending.metadata.createdAt,
                            audioFileURL: pending.metadata.audioFileURL,
                            preferredLanguage: pending.metadata.preferredLanguage,
                            attemptCount: pending.metadata.attemptCount + 1,
                            lastErrorCode: error.errorCode
                        )
                    )
                }
                lastError = error
                state = .error(
                    message: error.localizedDescription,
                    isRetryable: error.isRetryable
                )
            } catch {
                lastError = nil
                state = .error(message: error.localizedDescription, isRetryable: false)
            }
        }
    }

    // MARK: - Recording

    private func startRecording() {
        // Speech-Recognition preflight (A fallback) — MUST run BEFORE
        // `beginRecordingSession()` sets `.recording` / starts timers / takes
        // leases. The menu-bar shortcut calls `showPopover()` before toggling,
        // so the popover is visible and a prompt is contextual. If Apple
        // on-device STT is active AND Speech Recognition is `.notDetermined`,
        // prompt now; a determined `.denied`/`.restricted` surfaces the existing
        // `speechPermissionDenied` error and does NOT record. Cloud providers
        // no-op. `.authorized` / just-granted continues into the session.
        Task {
            let speechStatus = await VoicePermissions.ensureSpeechRecognitionForActiveProvider()
            if speechStatus == .denied || speechStatus == .restricted {
                lastError = .speechPermissionDenied
                state = .error(
                    message: AppError.speechPermissionDenied.localizedDescription,
                    isRetryable: false
                )
                return
            }
            beginRecordingSession()
        }
    }

    /// The synchronous record-start body: acquire the mic lease, silence
    /// speakers, set `.recording`, start the display timer, then spin up the
    /// underlying `AudioRecorder`. Split out of `startRecording()` so the
    /// Speech-Recognition preflight can run (and bail) BEFORE any of this state
    /// is taken.
    private func beginRecordingSession() {
        // macOS mic lease: refuse to start if the main-window composer mic (a
        // SEPARATE AVAudioRecorder instance) is already capturing — two concurrent
        // starts on the shared input produce the HAL "there already is a thread" /
        // error-35 thrash. Excluding self so this service never blocks itself; a
        // live capture is sacred, so the SECOND start is refused, never the first.
        guard SpeechExclusivity.shared.acquireMicLease(excluding: self) else {
            state = .error(
                message: String(localized: "Microphone is in use by another recording."), // xcstrings: chat-ui-mac-freeze
                isRetryable: false
            )
            return
        }

        // Mic wins: silence EVERY macOS speaker before the mic comes up — the
        // shared arrival/preview voice AND every view-owned ThreadSpeaker
        // (another window's playing bubble would otherwise bleed straight into
        // this capture; macOS has no audio-session arbitration). The nil claim
        // stops all registered parties, and the mic itself is never registered,
        // so nothing can reciprocally stop a live capture. While `state ==
        // .recording` the bus also refuses auto-speak (`claimForAutoSpeak`),
        // so a reply landing mid-capture stays silent rather than recording
        // itself into the audio.
        SpeechExclusivity.shared.claim(nil)

        // Set state synchronously to prevent race condition on rapid double-clicks.
        lastError = nil
        nearMaxDuration = false
        state = .recording
        recordingStartTime = Date()
        recordingTime = 0
        startDisplayTimer()

        Task {
            do {
                let started = try await recorder.startRecording()
                guard started else {
                    stopDisplayTimer()
                    state = .error(
                        message: String(localized: "Failed to start recording."), // xcstrings
                        isRetryable: false
                    )
                    return
                }
            } catch AudioRecorderError.permissionDenied {
                stopDisplayTimer()
                state = .error(
                    message: String(localized: "Microphone access denied. Open System Settings → Privacy & Security → Microphone to enable."), // xcstrings
                    isRetryable: false
                )
            } catch {
                stopDisplayTimer()
                state = .error(message: error.localizedDescription, isRetryable: false)
            }
        }
    }

    private func stopAndProcess() {
        guard state == .recording else { return }
        stopDisplayTimer()

        guard let audioData = recorder.stopRecording() else {
            state = .error(
                message: String(localized: "No audio data recorded."), // xcstrings
                isRetryable: false
            )
            return
        }

        state = .processing
        let startTime = recordingStartTime ?? Date()

        Task {
            await processAudio(audioData: audioData, startTime: startTime)
        }
    }

    // MARK: - Processing Pipeline

    /// Fetch credentials + stage audio to a temp file URL, hand off to STTClient.
    /// Conduck V1 has no audio compression and no per-mode/per-app personalization
    /// layers — the only request inputs are audio bytes, API key, and an optional
    /// language hint.
    private func processAudio(audioData: Data, startTime: Date) async {
        // ATOMIC snapshot: (presetID, apiKey, provider) in
        // one actor hop. Passed through to processTranscription so the
        // provider resolved here is the SAME preset whose key we read.
        let snapshot = await SettingsManager.shared.activeSTTSnapshot()
        // In-process providers (Apple on-device) need no key. The BYO
        // custom endpoint with `.none` auth (keyless local server) also needs
        // no key.
        let apiKey: String
        if snapshot.provider.transport == .inProcess || snapshot.customConfig?.auth == STTAuthScheme.none {
            apiKey = ""
        } else if let key = snapshot.apiKey, !key.isEmpty {
            apiKey = key
        } else {
            lastError = .sttMissingAPIKey
            state = .error(
                message: AppError.sttMissingAPIKey.localizedDescription,
                isRetryable: false
            )
            return
        }
        let preferredLanguage = await SettingsManager.shared.getPreferredLanguage()

        // Stage to a temp file URL — STTClient.transcribe owns lifecycle via
        // defer-remove, so this method does not need to clean up post-call.
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("conduck_capture_\(UUID().uuidString).m4a")
        do {
            try audioData.write(to: tempURL, options: [.atomic])
        } catch {
            state = .error(
                message: String(localized: "Couldn't stage audio for upload."), // xcstrings
                isRetryable: false
            )
            return
        }

        await processTranscription(
            audioData: audioData,
            audioFileURL: tempURL,
            apiKey: apiKey,
            provider: snapshot.provider,
            customModel: snapshot.customModel,
            customConfig: snapshot.customConfig,
            preferredLanguage: preferredLanguage,
            startTime: startTime
        )
    }

    /// Foreground STT call + state transitions. On transient failure the
    /// original audio bytes (not the temp URL — STTClient has consumed it)
    /// are saved to `PendingRetryStore` so the user can hit "Retry" later.
    /// `provider` is passed in by the caller from its atomic snapshot — never
    /// re-resolve here (avoids key/provider mismatch).
    private func processTranscription(
        audioData: Data,
        audioFileURL: URL,
        apiKey: String,
        provider: STTProvider,
        customModel: String?,
        customConfig: CustomSTTConfig?,
        preferredLanguage: String?,
        startTime: Date
    ) async {
        do {
            let response = try await STTClient.shared.transcribe(
                audioFileURL: audioFileURL,
                apiKey: apiKey,
                language: preferredLanguage,
                provider: provider,
                customModel: customModel,
                customConfig: customConfig
            )

            let trimmed = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                state = .error(
                    message: String(localized: "Transcription returned empty text. Please try again."), // xcstrings
                    isRetryable: true
                )
                return
            }

            // Clear any stale pending-retry slot — this capture succeeded.
            await PendingRetryStore.shared.clear()
            // Terminal step (`spec.md "Per-Surface Behavior → macOS"`): hand the
            // transcript to the coordinator (→ agent round-trip) and return to
            // idle. No clipboard, no `.done`, no auto-dismiss.
            state = .idle
            onTranscript(trimmed)

        } catch let error as AppError {
            if error.shouldPreserveForRetry {
                // Audio bytes preserved for in-app retry. PendingRetryStore.save
                // owns the App-Groups file write; we record metadata only.
                let pendingURL = FileManager.default
                    .containerURL(forSecurityApplicationGroupIdentifier: Constants.appGroupID)?
                    .appendingPathComponent("pending_retry_audio.m4a") ?? audioFileURL
                try? await PendingRetryStore.shared.save(
                    audioData: audioData,
                    metadata: PendingRetryMetadata(
                        id: UUID(),
                        createdAt: Date(),
                        audioFileURL: pendingURL,
                        preferredLanguage: preferredLanguage,
                        attemptCount: 1,
                        lastErrorCode: error.errorCode
                    )
                )
            }
            lastError = error
            state = .error(
                message: error.localizedDescription,
                isRetryable: error.isRetryable
            )
        } catch {
            lastError = nil
            state = .error(message: error.localizedDescription, isRetryable: false)
        }
    }

    // MARK: - Helpers

    /// Mic-authority view for the exclusivity bus. Only `.recording` counts —
    /// during `.processing` the mic is already released, so speaking is fine.
    var isActivelyRecording: Bool { state == .recording }

    private func startDisplayTimer() {
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.recordingTime = self?.recorder.recordingTime ?? 0
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        displayTimer = timer
    }

    private func stopDisplayTimer() {
        displayTimer?.invalidate()
        displayTimer = nil
    }
}
#endif
