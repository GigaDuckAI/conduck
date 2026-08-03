// SPDX-License-Identifier: Apache-2.0

#if os(iOS)
import Foundation
import AVFoundation

/// Audio-session configuration for the in-app **chat** read-aloud path (the
/// per-bubble Speak control + the notification-open auto-speak), iOS/iPadOS only.
///
/// Why this exists: `ReplyVoice` / `SpeechPlayer` deliberately NEVER call
/// `setCategory` / `setActive` — they ride the *caller's* session (load-bearing
/// for CarPlay's deactivate-once invariant — see the single-speak-boundary rule
/// in `docs/ai-context/spec.md`). CarPlay's
/// caller is `CarPlayAudioSession`. The iOS chat path had **no** such caller, so
/// chat TTS played into whatever the session happened to be: `.soloAmbient` on a
/// fresh launch (silenced by the hardware mute switch) or `.record` + inactive
/// left by `AudioRecorder` after an in-app mic capture (playback not permitted at
/// all) → no audio. macOS has no `AVAudioSession`, which is why the same control
/// worked there. This enum is the chat path's session owner, the iOS-chat analog
/// of `CarPlayAudioSession` — `ThreadSpeaker` configures it around the speak
/// lifecycle and skips it entirely while CarPlay holds the session.
///
/// `.playback`: spoken replies are AUDIBLE regardless of the hardware silent
/// switch (a user-tapped Speak — and opt-in auto-speak — is intentional playback,
/// like tapping a voice message; matches CarPlay's always-audible posture). It
/// also routes to the speaker by default (no `.defaultToSpeaker`, which is a
/// `.playAndRecord`-only option). `.spokenAudio` is Apple's documented mode for
/// spoken-word playback (podcasts / audiobooks / TTS). `.duckOthers` dips music
/// during the reply rather than stopping it; `deactivate()` un-ducks it via
/// `.notifyOthersOnDeactivation` at the terminals (completion / stop) AND on
/// user pause — a paused reply must not keep other apps' audio ducked; the
/// resume path re-activates. The pause un-duck is BEST-EFFORT: a leg that
/// still holds audio I/O while paused (the Apple synth keeps `isSpeaking`)
/// can make `setActive(false)` throw busy — swallowed, the duck persists
/// until a terminal, exactly the pre-release behavior.
enum ChatPlaybackSession {
    /// Configure + activate the shared session for chat read-aloud. Idempotent —
    /// safe to call on every fresh speak / resume; `AVAudioSession` reconciles.
    static func configureAndActivate() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try session.setActive(true, options: [])
    }

    /// Release the session when read-aloud reaches a terminal state (completion /
    /// stop) or pauses (the resume path re-activates).
    /// `.notifyOthersOnDeactivation` tells ducked music / podcasts to resume.
    static func deactivate() throws {
        try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
#endif
