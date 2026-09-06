// SPDX-License-Identifier: Apache-2.0

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

    /// Which START owns the input. Moved by every stop and every cancel,
    /// including the ones that find nothing to stop.
    ///
    /// The entry guard below is read BEFORE the microphone-permission prompt,
    /// so two starts can both pass it while that system sheet stands: the first
    /// to resume builds the recorder and captures, and the second used to build
    /// a SECOND one straight over `audioRecorder` and abandon the live one — a
    /// stop then returned the earlier recording and lost the speech the person
    /// was watching being recorded. A cancel during the prompt was invisible for
    /// the same reason: `cancelRecording()` had no recorder to reach, so the
    /// microphone came up afterwards with nothing left that could stop it.
    ///
    /// A reservation is the only thing a press can leave behind while this call
    /// owns nothing, which is exactly the window it covers.
    private var sessionGeneration = 0

    /// Start recording audio
    func startRecording() async throws -> Bool {
        // Idempotency: a second start while one is already live would build a
        // SECOND AVAudioRecorder on the same input and abandon the first — the
        // HAL "there already is a thread" double-start. Callers guard their own
        // state machines, but the primitive must be safe on its own.
        guard !isRecording else { return true }
        let session = sessionGeneration

        // Request microphone permission
        let permissionGranted = await AVAudioApplication.requestRecordPermission()
        guard permissionGranted else {
            throw AudioRecorderError.permissionDenied
        }

        // THE RESERVATION, checked on the far side of the prompt and above the
        // first line that takes the input. A stop or a cancel that landed while
        // it was up moved the session; so did a start that got here first, and
        // that one owns the recorder now. Either way this call starts nothing:
        // `false` says so, rather than reporting a capture whose bytes belong to
        // somebody else.
        guard session == sessionGeneration, !isRecording else { return false }

        // Configure audio session (iOS only - macOS doesn't need this), UNLESS
        // CarPlay owns it — see `deactivateSessionUnlessCarPlayOwnsIt()`.
        #if os(iOS)
        if !CarPlayRecordingService.anySessionActive {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.record, mode: .default)
            try audioSession.setActive(true)
        }
        #endif

        // Create temporary file URL. The `conduck-recorder-` prefix is
        // load-bearing: this is the raw microphone capture for menu-bar dictation
        // and both Settings STT test sections, and it is deleted only in-process
        // (`stopRecording`, `cancelRecording`, the delegate). A jetsam or
        // force-quit mid-capture strands it, and only `TempScratchSweeper` can
        // reclaim it — by prefix. A UUID rather than a timestamp because a
        // directory listing of timestamped names would itself reveal when the
        // user recorded. Written inline rather than via a `fileName` local so the
        // prefix is readable AT the call site — `TempScratchLeafDriftGuardTests`
        // reads leaves from source, and a leaf hidden behind a variable is exactly
        // the shape that let this site sit unclaimed for so long.
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("conduck-recorder-\(UUID().uuidString).m4a")

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
        // The session ends whether or not there is anything here to end. A stop
        // pressed while a start is still suspended in the permission prompt
        // finds no recorder at all, and without this the prompt's answer would
        // open the microphone after the stop.
        sessionGeneration &+= 1
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
        deactivateSessionUnlessCarPlayOwnsIt()
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
        // Same rule as the stop, and this is the press that most often has
        // nothing to act on: Esc during the permission prompt. The reservation
        // is what the resumed start reads.
        sessionGeneration &+= 1
        guard let recorder = audioRecorder else { return }

        userInitiatedStop = true
        recorder.stop()
        isRecording = false
        recordingTimer?.invalidate()
        recordingTimer = nil
        warningTimer?.invalidate()
        warningTimer = nil

        #if os(iOS)
        deactivateSessionUnlessCarPlayOwnsIt()
        #endif

        // Clean up temporary file
        let url = recorder.url
        try? FileManager.default.removeItem(at: url)
    }

    #if os(iOS)
    /// Give the shared `AVAudioSession` back — unless CarPlay is holding it.
    ///
    /// There is ONE session per process, so this primitive's category switch and
    /// its `setActive(false)` land on whoever else is using it. The other user is
    /// a live CarPlay voice session, and it is the one this surface cannot see:
    /// a capture that began before the car connected ends after it, and a bare
    /// deactivate there tears down the route the driver is talking into, mid
    /// sentence, from a window that is not even on screen. CarPlay's own legs are
    /// activate-once / deactivate-once, so a foreign deactivate is not something
    /// it can recover from by re-activating.
    ///
    /// Ownership is read from CarPlay's process-wide mirror rather than through
    /// `SpeechExclusivity`, because CarPlay registers nothing on that bus by
    /// construction. `ThreadSpeaker` guards the playback session with the
    /// identical read; this is the capture half of the same rule, and
    /// `InAppAudioRecorder.startRecording()` refuses outright rather than
    /// arriving here.
    private func deactivateSessionUnlessCarPlayOwnsIt() {
        guard !CarPlayRecordingService.anySessionActive else { return }
        try? AVAudioSession.sharedInstance().setActive(false)
    }
    #endif
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
