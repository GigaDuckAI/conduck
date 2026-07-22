import Foundation
import AVFoundation
import Combine

/// Audio recorder for menu bar dictation and development testing
@MainActor
class AudioRecorder: NSObject, ObservableObject {
    @Published var isRecording = false
    @Published var recordingTime: TimeInterval = 0

    /// Called when recording finishes (max duration or delegate callback).
    /// `wasAutoStopped` is `true` when the cap fired without a user-initiated
    /// `stopRecording()` call — DictationService uses this to play the stop chime.
    var onRecordingFinished: ((_ wasAutoStopped: Bool) -> Void)?

    /// Called once at `Constants.maxAudioDuration - maxAudioDurationWarningOffset`
    /// during a recording. DictationService uses this to flip the popover into
    /// the "1 min left" warning state.
    var onWarningFired: (() -> Void)?

    /// Called when a recording finishes UNSUCCESSFULLY without a user-initiated
    /// stop (delegate `successfully: false` — the HAL aborted mid-capture). Lets
    /// the owner leave `.recording` and surface an error instead of hanging in a
    /// capture that will never produce audio.
    var onRecordingFailed: (() -> Void)?

    private var audioRecorder: AVAudioRecorder?
    private var recordingTimer: Timer?
    private var warningTimer: Timer?

    /// Set true when `stopRecording()` is called by user / state machine, so the
    /// delegate can distinguish a manual stop from a cap-fired auto-stop.
    private var userInitiatedStop = false

    /// Start recording audio
    func startRecording() async throws -> Bool {
        // Idempotency: a second start while one is already live would build a
        // SECOND AVAudioRecorder on the same input and abandon the first — the
        // HAL "there already is a thread" double-start. Callers guard their own
        // state machines, but the primitive must be safe on its own.
        guard !isRecording else { return true }

        // Request microphone permission
        let permissionGranted = await AVAudioApplication.requestRecordPermission()
        guard permissionGranted else {
            throw AudioRecorderError.permissionDenied
        }

        // Configure audio session (iOS only - macOS doesn't need this)
        #if os(iOS)
        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.record, mode: .default)
        try audioSession.setActive(true)
        #endif

        // Create temporary file URL
        let tempDir = FileManager.default.temporaryDirectory
        let fileName = "test_recording_\(Date().timeIntervalSince1970).m4a"
        let fileURL = tempDir.appendingPathComponent(fileName)

        // Configure recorder settings (AAC format, 48kHz)
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 48000.0,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]

        // Create and start recorder
        audioRecorder = try AVAudioRecorder(url: fileURL, settings: settings)
        audioRecorder?.delegate = self
        // `record(forDuration:)` returns false when the HAL rejects the start
        // (input busy / reconfig pending — the error-35 path). It was previously
        // ignored, so a rejected start still flipped the UI to `.recording` and
        // captured nothing. Surface it as a throw and tear the half-built
        // recorder down so the next attempt starts clean.
        guard audioRecorder?.record(forDuration: Constants.maxAudioDuration) == true else {
            audioRecorder = nil
            throw AudioRecorderError.recordingFailed
        }

        isRecording = true
        recordingTime = 0
        userInitiatedStop = false

        // Start timer for recording duration display.
        // Use .common run loop mode so the timer doesn't pause during menu interactions.
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            Task { @MainActor in
                self.recordingTime = self.audioRecorder?.currentTime ?? 0
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        recordingTimer = timer

        // Schedule the soft warning timer at T-warningOffset.
        let warningInterval = Constants.maxAudioDuration - Constants.maxAudioDurationWarningOffset
        if warningInterval > 0 {
            let warning = Timer(timeInterval: warningInterval, repeats: false) { [weak self] _ in
                guard let self else { return }
                Task { @MainActor in
                    guard self.isRecording else { return }
                    self.onWarningFired?()
                }
            }
            RunLoop.main.add(warning, forMode: .common)
            warningTimer = warning
        }

        return true
    }

    /// Stop recording and return audio data
    func stopRecording() -> Data? {
        guard let recorder = audioRecorder, isRecording else {
            return nil
        }

        userInitiatedStop = true
        recorder.stop()
        isRecording = false
        recordingTimer?.invalidate()
        recordingTimer = nil
        warningTimer?.invalidate()
        warningTimer = nil

        // Deactivate audio session (iOS only)
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false)
        #endif

        // Read audio file data
        let url = recorder.url
        let audioData = try? Data(contentsOf: url)

        // Clean up temporary file
        try? FileManager.default.removeItem(at: url)

        return audioData
    }

    /// Cancel recording without returning data
    func cancelRecording() {
        guard let recorder = audioRecorder else { return }

        userInitiatedStop = true
        recorder.stop()
        isRecording = false
        recordingTimer?.invalidate()
        recordingTimer = nil
        warningTimer?.invalidate()
        warningTimer = nil

        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false)
        #endif

        // Clean up temporary file
        let url = recorder.url
        try? FileManager.default.removeItem(at: url)
    }
}

// MARK: - AVAudioRecorderDelegate

extension AudioRecorder: AVAudioRecorderDelegate {
    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        Task { @MainActor in
            // Ignore a stale callback from a PRIOR recorder that finished late —
            // a new session may already own `audioRecorder`.
            guard recorder === audioRecorder else { return }
            guard isRecording else { return }
            warningTimer?.invalidate()
            warningTimer = nil
            let wasAutoStopped = !userInitiatedStop
            if flag {
                onRecordingFinished?(wasAutoStopped)
            } else {
                // The HAL aborted the capture with no user stop. Clear state AND
                // notify the owner so it can leave `.recording` and surface an
                // error rather than hang in a capture that yields no audio.
                isRecording = false
                recordingTimer?.invalidate()
                recordingTimer = nil
                // Remove the orphaned partial-capture temp file — this branch
                // never returns audio, and no owner calls cancel/stopRecording
                // here (stopRecording would early-return on the cleared
                // `isRecording`), so it would otherwise strand a partial .m4a.
                try? FileManager.default.removeItem(at: recorder.url)
                onRecordingFailed?()
            }
        }
    }
}

// MARK: - Error

enum AudioRecorderError: LocalizedError {
    case permissionDenied
    case recordingFailed

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return String(localized: "Microphone permission denied. Enable in Settings → Privacy → Microphone.")
        case .recordingFailed:
            return String(localized: "Failed to start audio recording.")
        }
    }
}
