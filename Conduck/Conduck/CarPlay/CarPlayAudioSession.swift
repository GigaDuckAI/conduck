// SPDX-License-Identifier: Apache-2.0

#if os(iOS)
import Foundation
import AVFoundation

/// Audio-session configuration for the CarPlay voice conversation flow.
///
/// Design choice: single category (`.playAndRecord`), single mode (`.voiceChat`),
/// single activation — held for the whole **SESSION** (multi-turn: across
/// every listen → upload → TTS → re-listen turn until the session ends), NOT
/// per-turn. Deactivated EXACTLY ONCE at session end (`.notifyOthersOnDeactivation`)
/// on every terminal path; otherwise the head unit stays locked in "call" state
/// and the driver loses radio/nav. Mid-session
/// category swaps on a car head unit can trigger a Bluetooth HFP reconfiguration
/// cycle (1–2 s of dead air), so we stay put. No `.duckOthers` / mix option: the
/// held `.playAndRecord` session INTERRUPTS other audio (music/podcast/radio) for
/// the whole session, so it PAUSES the instant listening starts rather than
/// merely dipping — a ducked-but-still-playing source bleeds into the cabin mic
/// and false-triggers the Silero VAD as never-ending speech. The interrupted app
/// resumes at session end via `deactivate(.notifyOthersOnDeactivation)`.
/// `configureAndActivate()` is idempotent — calling it again mid-session (e.g.
/// after an HFP route renegotiation) reconciles without a second deactivate.
///
/// `.voiceChat` is Apple's documented mode for voice-communication capture —
/// engages AGC and echo cancellation, useful for a noisy cabin with a
/// Bluetooth-HFP microphone. `.spokenAudio` is a playback mode (podcasts /
/// audiobooks) and is the wrong choice for dictation capture.
///
/// `.allowBluetoothHFP` is the iOS 17+ replacement for the deprecated
/// `.allowBluetooth` option. Required for cars that route the mic through a
/// Hands-Free Profile connection rather than the wired CarPlay mic.
enum CarPlayAudioSession {
    /// Configure and activate the shared audio session for a CarPlay turn.
    /// Idempotent — safe to call multiple times; AVAudioSession reconciles.
    static func configureAndActivate() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            .playAndRecord,
            mode: .voiceChat,
            options: [.defaultToSpeaker, .allowBluetoothHFP]
        )
        try session.setActive(true, options: [])
    }

    /// Tear down the audio session at the end of a turn. `.notifyOthersOnDeactivation`
    /// tells the interrupted music / podcast app it can resume.
    static func deactivate() throws {
        try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// INTERNAL recovery deactivation for the engine-start retry path — NOT a
    /// terminal session release. Used to recover a RemoteIO / `mediaserverd`
    /// connection wedged by a failed `engine.start()` (FourCC `'nope'`): the
    /// caller immediately reactivates and retries within the SAME session, so
    /// this MUST NOT use `.notifyOthersOnDeactivation` — Apple warns that option
    /// wakes competing apps (music/podcast resume), which is wrong for an
    /// internal reactivate cycle. The head unit's radio/nav must only resume at
    /// TRUE session end, which stays the `deactivate()` chokepoint above.
    static func deactivateForRecovery() throws {
        try AVAudioSession.sharedInstance().setActive(false, options: [])
    }
}
#endif
