// Conduck
// CloudSTTTester.swift
//
// Drives the Settings → Voice → <cloud provider> "Record a test" live-recording
// test: record a short clip from the mic, send it to the CLOUD provider being
// configured (Mistral / OpenAI / ElevenLabs / Gemini / OpenRouter) for
// transcription, and surface what it heard inline. The cloud analogue of the
// Apple `AppleSpeechTester` — it REPLACES the old cheap "Test Connection"
// key-check in the STT section: a real-voice audition proves the key works AND
// shows transcription quality on the user's own voice (the cheap key check still
// lives in Provider Access → "Validate & Save").
//
// Deliberately a SEPARATE class from `AppleSpeechTester` (not one generic tester
// with a pluggable backend): Apple owns Speech TCC / engine-freeze / macOS
// speech quirks; cloud owns credentials, network latency, cancellation, timeout,
// and per-clip cost. The two failure surfaces age better apart.
//
// It mirrors `AppleSpeechTester`'s shape: composes the same `AudioRecorder`, the
// macOS `SpeechExclusivity` mic-lease dance, the stable `.recording(startedAt:)`
// timer decoupling (the mm:ss display ticks in a leaf `TimelineView`, so this
// @Observable state does NOT republish 10×/sec — the macOS layout-recursion
// trap), and the monotonic `generation` stale-guard. It DIVERGES: it transcribes
// over the network through `STTClient.transcribe` (retaining a cancellable
// `Task` so a screen-dismiss / re-record actually aborts the upload, not just
// drops a stale UI result), resolves the PROVIDER BEING DISPLAYED (never
// `activeSTTSnapshot()` — the user can test a non-active provider), re-reads the
// key from Keychain at transcribe time (so a key cleared mid-record fails
// cleanly), and never persists audio/transcript (privacy invariant — see the
// "Privacy & Security" section of docs/ai-context/spec.md).
//
// `#if !os(watchOS)` — the cloud provider detail screens are iOS/macOS only.

#if !os(watchOS)

import Foundation
import AVFoundation
import Observation

/// Live-test lifecycle for a cloud provider's "Record a test" surface.
enum CloudSTTTestState: Equatable {
    case idle
    /// STABLE start instant — the `mm:ss` display derives elapsed inside a leaf
    /// `TimelineView` (`LiveRecordingStatusIndicator`), so this state is set ONCE
    /// and does not mutate every tick (avoids the macOS @Observable-tick →
    /// AppKit layout-recursion freeze).
    case recording(startedAt: Date)
    case transcribing
    /// Terminal success — the transcript the cloud provider returned.
    case result(text: String)
    case failed(message: String)
}

@MainActor
@Observable
final class CloudSTTTester {
    /// The view binds to this to render the record button / live timer / result.
    private(set) var state: CloudSTTTestState = .idle

    /// Hard cap for a test clip — short by design (matches the Apple tester's
    /// 15 s; keeps the paid/accidental-cost story clean). Driven by `autoStopTask`,
    /// NOT the recorder's own 300 s cap.
    static let maxTestDuration: TimeInterval = 15

    /// Underlying capture engine (composed, like `AppleSpeechTester`).
    private let recorder = AudioRecorder()

    /// Fires the 15 s auto-stop. Cancelled on a manual stop / re-record / dismiss.
    private var autoStopTask: Task<Void, Never>?

    /// The in-flight network transcription. RETAINED so `cancel()` aborts the
    /// upload itself (Apple's generation guard alone would only drop the late
    /// result — a paid cloud call must actually stop).
    private var transcribeTask: Task<Void, Never>?

    /// Monotonic guard: a re-record, provider switch, or screen dismiss bumps
    /// this so a late transcription can't land a result for the wrong provider or
    /// after the user has left the screen.
    private var generation = 0

    /// Provider context FROZEN at record start — never re-resolved post-recording
    /// (the user could navigate / edit the model between speaking and the result).
    /// The KEY is deliberately NOT frozen here — it's re-read from Keychain at
    /// transcribe time so a key cleared mid-record fails cleanly.
    private var frozenPresetID: String = ""
    private var frozenProviderName: String = ""
    private var frozenLanguage: String?
    private var frozenCustomModel: String?

    init() {
        #if os(macOS)
        // macOS has no AVAudioSession arbitration — join the mic-exclusivity bus
        // so a Settings test and the menu-bar `DictationService` can't double-
        // start the mic. Weakly held; iOS/watch never register (bus inert there).
        SpeechExclusivity.shared.register(recordingAuthority: self)
        #endif
        // We drive our OWN 15 s cap via `autoStopTask`; the recorder's 300 s cap
        // should never fire first. If it somehow does, transcribe the clip anyway
        // (treat it like a manual stop) rather than discard it.
        recorder.onRecordingFinished = { [weak self] wasAutoStopped in
            guard let self, wasAutoStopped else { return }
            Task { @MainActor in await self.finishAndTranscribe() }
        }
        // A HAL-aborted capture with no user stop must surface an error, not hang.
        recorder.onRecordingFailed = { [weak self] in
            guard let self else { return }
            if case .recording = self.state {
                self.state = .failed(message: Self.micFailureMessage)
            }
        }
    }

    // MARK: - Public API

    /// Begin a test recording for the cloud provider `presetID` (display name +
    /// language + model override FROZEN here). Fails fast (no mic opened) when no
    /// key is stored yet — the record test doubles as the key check, but there's
    /// nothing to test without a key. Microphone permission is requested by
    /// `AudioRecorder` itself; there is no Speech-framework TCC here (cloud only).
    func start(presetID: String, providerName: String, language: String?, customModel: String?) async {
        switch state {
        case .recording, .transcribing:
            return                       // already busy — ignore
        case .idle, .result, .failed:
            break                        // restartable
        }

        frozenPresetID = presetID
        frozenProviderName = providerName
        frozenLanguage = language
        frozenCustomModel = customModel?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? customModel
            : nil
        generation &+= 1

        // Silence any "Speak a sample" TTS before opening the mic (same stop the
        // macOS exclusivity bus routes through).
        ReplyVoice.shared.cancel()

        // Nothing to test without a key — fail fast before recording 15 s.
        guard let key = await SettingsManager.shared.getAPIKey(forPresetID: presetID),
              !key.isEmpty else {
            state = .failed(message: Self.noKeyMessage(providerName))
            return
        }

        #if os(macOS)
        // Take the cross-process mic lease + silence registered speakers before
        // the input comes up (mirrors `AppleSpeechTester` / `DictationService`).
        guard SpeechExclusivity.shared.acquireMicLease(excluding: self) else {
            state = .failed(message: Self.micBusyMessage)
            return
        }
        SpeechExclusivity.shared.claim(nil)
        #endif

        do {
            guard try await recorder.startRecording() else {
                state = .failed(message: Self.micFailureMessage)
                return
            }
        } catch let error as AudioRecorderError {
            switch error {
            case .permissionDenied: state = .failed(message: Self.micDeniedMessage)
            case .recordingFailed:  state = .failed(message: Self.micFailureMessage)
            }
            return
        } catch {
            state = .failed(message: Self.micFailureMessage)
            return
        }

        // STABLE start instant (display ticks in the leaf TimelineView).
        state = .recording(startedAt: Date())

        // 15 s hard cap.
        let gen = generation
        autoStopTask?.cancel()
        autoStopTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(CloudSTTTester.maxTestDuration))
            guard let self, !Task.isCancelled else { return }
            guard self.generation == gen else { return }
            await self.stop()
        }
    }

    /// Stop recording and transcribe. No-op unless currently recording.
    func stop() async {
        guard case .recording = state else { return }
        autoStopTask?.cancel()
        autoStopTask = nil
        await finishAndTranscribe()
    }

    /// Cancel an in-flight test (screen dismissed / re-record). Drops the
    /// recording AND aborts a pending network transcription, then resets to idle.
    func cancel() {
        autoStopTask?.cancel()
        autoStopTask = nil
        transcribeTask?.cancel()
        transcribeTask = nil
        generation &+= 1
        if case .recording = state {
            recorder.cancelRecording()
        }
        state = .idle
    }

    /// Clear a terminal result/error back to idle (the "Record again" reset path).
    func reset() {
        switch state {
        case .recording, .transcribing: return
        case .idle, .result, .failed: state = .idle
        }
    }

    // MARK: - Private

    private func finishAndTranscribe() async {
        let gen = generation
        let presetID = frozenPresetID
        let providerName = frozenProviderName
        let language = frozenLanguage
        let customModel = frozenCustomModel

        guard let audioData = recorder.stopRecording(), !audioData.isEmpty else {
            state = .failed(message: Self.noSpeechMessage)
            return
        }
        state = .transcribing

        // Re-read the key at transcribe time (NOT frozen at start): if the user
        // cleared it mid-record, fail cleanly rather than send a stale key.
        guard let key = await SettingsManager.shared.getAPIKey(forPresetID: presetID),
              !key.isEmpty else {
            guard generation == gen else { return }
            state = .failed(message: Self.noKeyMessage(providerName))
            return
        }

        // Write the recorder's 48 kHz mono AAC m4a to OUR OWN temp file.
        // `STTClient.transcribe` deletes the URL via `defer`; the Task below also
        // defends with a removal in case the call never reaches that defer.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("conduck-cloud-stt-test-\(UUID().uuidString).m4a")
        do {
            try audioData.write(to: url)
        } catch {
            guard generation == gen else { return }
            state = .failed(message: Self.transcribeFailedMessage)
            return
        }

        // Provider-scoped resolution — the DISPLAYED provider, never the active
        // snapshot. Built-in cloud providers carry no `customConfig` (that's the
        // BYO custom-endpoint editor's concern).
        let provider = STTProvider.lookup(id: presetID)

        transcribeTask = Task { [weak self] in
            defer { try? FileManager.default.removeItem(at: url) }
            do {
                let response = try await STTClient.shared.transcribe(
                    audioFileURL: url,
                    apiKey: key,
                    language: language,
                    provider: provider,
                    customModel: customModel,
                    customConfig: nil
                )
                guard let self, self.generation == gen else { return }   // stale: cancelled / re-recorded
                let text = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
                self.state = text.isEmpty
                    ? .failed(message: Self.noSpeechMessage)
                    : .result(text: text)
            } catch is CancellationError {
                return                                                    // intentional drop
            } catch let error as AppError {
                guard let self, self.generation == gen else { return }
                self.state = .failed(message: Self.message(for: error, providerName: providerName))
            } catch {
                guard let self, self.generation == gen else { return }
                self.state = .failed(message: Self.transcribeFailedMessage)
            }
        }
    }

    // MARK: - Error copy (localized; specific, never generic; key/URL never leaked)

    private static func message(for error: AppError, providerName: String) -> String {
        switch error {
        case .sttAuthFailed, .sttMissingAPIKey:
            return String(localized: LocalizedStringResource(
                "settings.voice.cloudTest.error.auth",
                defaultValue: "The key was rejected. Check it in Provider Access."
            ))
        case .sttQuotaExceeded:
            return String(localized: LocalizedStringResource(
                "settings.voice.cloudTest.error.quota",
                defaultValue: "You're out of credits with this provider."
            ))
        case .sttProviderUnreachable, .noInternetConnection, .networkError, .requestTimeout, .sttServerError, .sttTooManyRequests:
            return String(localized: LocalizedStringResource(
                "settings.voice.cloudTest.error.unreachable",
                defaultValue: "Couldn't reach \(providerName). Check your connection and try again."
            ))
        case .audioTooLarge:
            return String(localized: LocalizedStringResource(
                "settings.voice.cloudTest.error.tooLong",
                defaultValue: "That clip was too long. Try a shorter test."
            ))
        case .noSpeechDetected:
            return noSpeechMessage
        case .audioProcessingFailed, .audioInvalid, .sttDecodingFailure:
            return String(localized: LocalizedStringResource(
                "settings.voice.cloudTest.error.unprocessable",
                defaultValue: "\(providerName) couldn't process that clip. Try again."
            ))
        default:
            return transcribeFailedMessage
        }
    }

    private static func noKeyMessage(_ providerName: String) -> String {
        String(localized: LocalizedStringResource(
            "settings.voice.cloudTest.error.noKey",
            defaultValue: "Add a \(providerName) key first, then record a test."
        ))
    }
    private static var micDeniedMessage: String {
        String(localized: LocalizedStringResource(
            "settings.voice.cloudTest.error.micDenied",
            defaultValue: "Microphone access is off. Turn it on in Settings → Privacy → Microphone."
        ))
    }
    private static var micBusyMessage: String {
        String(localized: LocalizedStringResource(
            "settings.voice.cloudTest.error.micBusy",
            defaultValue: "The microphone is busy. Stop other recording and try again."
        ))
    }
    private static var micFailureMessage: String {
        String(localized: LocalizedStringResource(
            "settings.voice.cloudTest.error.micFailure",
            defaultValue: "Couldn't start recording. Try again."
        ))
    }
    private static var noSpeechMessage: String {
        String(localized: LocalizedStringResource(
            "settings.voice.cloudTest.error.noSpeech",
            defaultValue: "No speech detected. Try again."
        ))
    }
    private static var transcribeFailedMessage: String {
        String(localized: LocalizedStringResource(
            "settings.voice.cloudTest.error.transcribeFailed",
            defaultValue: "Couldn't transcribe that. Try again."
        ))
    }
}

#if os(macOS)
extension CloudSTTTester: RecordingExclusivityAuthority {
    /// Mic-authority view for the macOS speech-exclusivity bus. True only while
    /// actively recording — NOT during `.transcribing` (mic released) or terminal
    /// states. Mirrors `AppleSpeechTester.isActivelyRecording`.
    var isActivelyRecording: Bool {
        if case .recording = state { return true }
        return false
    }
}
#endif

#endif // !os(watchOS)
