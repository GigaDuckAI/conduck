// SPDX-License-Identifier: Apache-2.0

// Conduck
// AppleSpeechTester.swift
//
// Drives the Settings → Voice → Apple "Try it" live-recording test: record a
// short clip from the mic, transcribe it ON-DEVICE via the engine the user is
// visibly testing, and surface the transcript inline. The on-device analogue of
// TTS "Speak a sample" — real proof the pipeline works, not a hollow "Connected"
// (an on-device, keyless provider is ALWAYS "connected", so the only meaningful
// signal is "speak → see what Apple heard").
//
// Models `InAppAudioRecorder`: composes the same `AudioRecorder`, the macOS
// `SpeechExclusivity` mic-lease dance, and the stable `.recording(startedAt:)`
// timer decoupling (the mm:ss display ticks in a leaf `TimelineView`, so this
// @Observable state does NOT republish 10×/sec — the macOS layout-recursion
// trap). It DIVERGES deliberately: it transcribes through `AppleSpeechRunner`
// with an EXPLICIT engine (so the result is attributed to the engine actually
// tested, even before a just-flipped iCloud-KVS value propagates), and it NEVER
// touches `activeSTTSnapshot` / `PendingRetryStore` / conversations — the clip it
// records is written to temp and `defer`-deleted on every path, and a test must
// leave behind no audio, transcript, or retry (privacy invariant — see
// docs/ai-context/spec.md).
//
// `#if !os(watchOS)` — depends on `AppleSpeechRunner` (no Speech symbols on Watch).

#if !os(watchOS)

import Foundation
import AVFoundation
import Observation
import Speech

/// Live-test lifecycle for the Apple on-device "Try it" surface.
enum AppleSpeechTestState: Equatable {
    case idle
    /// STABLE start instant — the `mm:ss` display derives elapsed inside a leaf
    /// `TimelineView` (`LiveRecordingStatusIndicator`), so this state is set ONCE
    /// and does not mutate every tick (avoids the macOS @Observable-tick →
    /// AppKit layout-recursion freeze).
    case recording(startedAt: Date)
    case transcribing
    /// Terminal success — carries the engine actually used so the UI can label
    /// which engine produced the transcript (supports the A/B "feel the
    /// difference" loop where the user re-tests after switching engines).
    case result(text: String, engine: AppleOnDeviceEngineMode)
    case failed(message: String)
}

@MainActor
@Observable
final class AppleSpeechTester {
    /// The view binds to this to render the record button / live timer / result.
    private(set) var state: AppleSpeechTestState = .idle

    /// Hard cap for a test clip — short by design (production's 300 s cap is
    /// irrelevant here). Driven by `autoStopTask`, NOT the recorder's own cap.
    static let maxTestDuration: TimeInterval = 15

    /// Underlying capture engine (composed, like `InAppAudioRecorder`).
    private let recorder = AudioRecorder()

    /// Fires the 15 s auto-stop. Cancelled on a manual stop / re-record / dismiss.
    private var autoStopTask: Task<Void, Never>?

    /// Monotonic guard: a re-record, engine switch, or screen dismiss bumps this
    /// so a late transcription can't land a result under the wrong engine or after
    /// the user has left the screen.
    private var generation = 0

    /// Engine + language FROZEN at record start — never re-resolved post-recording.
    private var frozenEngine: AppleOnDeviceEngineMode = .dictation
    private var frozenLanguage: String?

    init() {
        #if os(macOS)
        // macOS has no AVAudioSession arbitration — join the mic-exclusivity bus so
        // a Settings test and the menu-bar `DictationService` can't double-start the
        // mic. Weakly held; iOS/watch never register (bus inert there).
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

    /// Begin a test recording for `engine` + `language` (both FROZEN here).
    /// Requests Speech Recognition + microphone permission up front so a denial
    /// fails fast instead of after a 15 s recording.
    func start(engine: AppleOnDeviceEngineMode, language: String?) async {
        switch state {
        case .recording, .transcribing:
            return                       // already busy — ignore
        case .idle, .result, .failed:
            break                        // restartable
        }

        frozenEngine = engine
        frozenLanguage = language
        generation &+= 1

        // Silence any "Speak a sample" TTS before opening the mic. `cancel()`
        // aborts the in-flight fetch + playback without firing the preview's
        // completion (fire-and-forget) — the same stop the macOS exclusivity bus
        // routes through.
        ReplyVoice.shared.cancel()

        // Speech Recognition auth BEFORE recording — never record 15 s then fail TCC.
        let auth = await AppleSpeechRunner.requestAuthorization()
        guard auth == .authorized else {
            state = .failed(message: Self.speechDeniedMessage)
            return
        }

        #if os(macOS)
        // Take the cross-process mic lease + silence registered speakers before the
        // input comes up (mirrors `InAppAudioRecorder` / `DictationService`).
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
            try? await Task.sleep(for: .seconds(AppleSpeechTester.maxTestDuration))
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

    /// Cancel an in-flight test (screen dismissed). Drops the recording + any
    /// pending transcription and resets to idle.
    func cancel() {
        autoStopTask?.cancel()
        autoStopTask = nil
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
        let engine = frozenEngine

        guard let audioData = recorder.stopRecording(), !audioData.isEmpty else {
            state = .failed(message: Self.noSpeechMessage)
            return
        }
        state = .transcribing

        // Write the recorder's 48 kHz mono AAC m4a to OUR OWN temp file. The runner
        // reads via `AVAudioFile` and does NOT delete temp files (only `STTClient`
        // does), so we own cleanup here.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("conduck-apple-test-\(UUID().uuidString).m4a")
        do {
            try audioData.write(to: url)
        } catch {
            state = .failed(message: Self.transcribeFailedMessage)
            return
        }
        defer { try? FileManager.default.removeItem(at: url) }

        do {
            let response = try await AppleSpeechRunner.transcribe(
                audioFileURL: url,
                language: frozenLanguage,
                engine: engine
            )
            guard generation == gen else { return }   // stale: re-recorded / switched / dismissed
            let text = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
            state = text.isEmpty
                ? .failed(message: Self.noSpeechMessage)
                : .result(text: text, engine: engine)
        } catch let error as AppError {
            guard generation == gen else { return }
            state = .failed(message: Self.message(for: error))
        } catch {
            guard generation == gen else { return }
            state = .failed(message: Self.transcribeFailedMessage)
        }
    }

    // MARK: - Error copy (localized; specific, never generic)

    private static func message(for error: AppError) -> String {
        switch error {
        case .speechPermissionDenied:        return speechDeniedMessage
        case .appleSpeechModelNotInstalled:  return modelMissingMessage
        case .appleSpeechLanguageUnsupported: return languageUnsupportedMessage
        case .noSpeechDetected:              return noSpeechMessage
        default:                             return transcribeFailedMessage
        }
    }

    private static var speechDeniedMessage: String {
        String(localized: LocalizedStringResource(
            "settings.voice.apple.test.error.speechDenied",
            defaultValue: "Speech Recognition is off. Turn it on in Settings → Privacy → Speech Recognition."
        ))
    }
    private static var micDeniedMessage: String {
        String(localized: LocalizedStringResource(
            "settings.voice.apple.test.error.micDenied",
            defaultValue: "Microphone access is off. Turn it on in Settings → Privacy → Microphone."
        ))
    }
    private static var micBusyMessage: String {
        String(localized: LocalizedStringResource(
            "settings.voice.apple.test.error.micBusy",
            defaultValue: "The microphone is busy. Stop other recording and try again."
        ))
    }
    private static var micFailureMessage: String {
        String(localized: LocalizedStringResource(
            "settings.voice.apple.test.error.micFailure",
            defaultValue: "Couldn't start recording. Try again."
        ))
    }
    private static var noSpeechMessage: String {
        String(localized: LocalizedStringResource(
            "settings.voice.apple.test.error.noSpeech",
            defaultValue: "No speech detected. Try again."
        ))
    }
    private static var modelMissingMessage: String {
        String(localized: LocalizedStringResource(
            "settings.voice.apple.test.error.modelMissing",
            defaultValue: "Setting up voice for this language — try again in a moment."
        ))
    }
    private static var languageUnsupportedMessage: String {
        String(localized: LocalizedStringResource(
            "settings.voice.apple.test.error.languageUnsupported",
            defaultValue: "Apple Speech doesn't support this language yet."
        ))
    }
    private static var transcribeFailedMessage: String {
        String(localized: LocalizedStringResource(
            "settings.voice.apple.test.error.transcribeFailed",
            defaultValue: "Couldn't transcribe that. Try again."
        ))
    }
}

#if os(macOS)
extension AppleSpeechTester: RecordingExclusivityAuthority {
    /// Mic-authority view for the macOS speech-exclusivity bus. True only while
    /// actively recording — NOT during `.transcribing` (mic released) or terminal
    /// states. Mirrors `InAppAudioRecorder.isActivelyRecording`.
    var isActivelyRecording: Bool {
        if case .recording = state { return true }
        return false
    }
}
#endif

#endif // !os(watchOS)
