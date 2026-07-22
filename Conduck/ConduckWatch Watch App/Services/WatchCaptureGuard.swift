import Foundation

/// Pure capture-hygiene decisions for the Watch recording pipeline. Plain
/// values in, verdict out — no recorder, no state machine — so the thresholds
/// are unit-testable (`WatchCaptureGuardTests`) without driving
/// `AVAudioRecorder` on a simulator.
///
/// Both guards target the same field failure: a double-tap on the mic (the
/// second tap lands the instant `.arming` flips to `.recording`) stops the
/// recorder at 0.0 s, producing a header-only husk that would otherwise run
/// the full compression-failure cascade plus a billed STT round-trip just to
/// come back as "no speech detected" — an error that blames the user's voice
/// for an app-side mis-tap.
enum WatchCaptureGuard {

    /// Grace window after the `.recording` state flip inside which a stop tap
    /// is treated as the trailing half of a double-tap, not an intentional
    /// stop. 350 ms comfortably swallows a natural double-tap while sitting
    /// far below any intentional utterance. The max-duration hard stop
    /// bypasses the window by construction — it fires at
    /// `Constants.maxAudioDuration` (minutes), so its elapsed time can never
    /// land inside it.
    static let misTapStopWindow: TimeInterval = 0.35

    /// Byte floor below which a captured file is provably a header-only husk.
    /// 48 kHz mono AAC yields well over 2 KB for even a half-second of real
    /// audio (the field husk was 557 bytes — recorder metadata, zero frames).
    /// A byte predicate, not a duration one: `recordingTime` accumulates on a
    /// 0.1 s timer and is unreliable across interruption edges.
    static let minCaptureBytes = 2048

    /// True when a stop arriving `elapsedSinceRecordingFlip` seconds after the
    /// `.recording` flip should be discarded as a mis-tap. `nil` (no flip
    /// timestamp — defensive) never discards.
    static func isMisTapStop(elapsedSinceRecordingFlip: TimeInterval?) -> Bool {
        guard let elapsed = elapsedSinceRecordingFlip else { return false }
        return elapsed < misTapStopWindow
    }

    /// True when a captured file of `byteCount` bytes is too short to contain
    /// speech and must be discarded before compression/upload.
    static func isTooShortCapture(byteCount: Int) -> Bool {
        byteCount < minCaptureBytes
    }
}
