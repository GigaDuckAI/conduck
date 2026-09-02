// SPDX-License-Identifier: Apache-2.0

#if os(iOS)
import Foundation
import AVFoundation

/// The ONE definition of the iOS audio session this app plays spoken word into:
/// the chat read-aloud path (the per-bubble Speak control + the
/// notification-open auto-speak) and the desk's voice-note cards. Both are the
/// same kind of output — a person tapped something and expects to hear a voice
/// — so the category, the mode, the options and the deactivation flag are
/// declared here once rather than per surface, where two copies would be free
/// to drift into two different postures on one shared session.
///
/// Why it exists at all: `ReplyVoice` / `SpeechPlayer` deliberately NEVER call
/// `setCategory` / `setActive` — they ride the *caller's* session (load-bearing
/// for CarPlay's deactivate-once invariant — see the single-speak-boundary rule
/// in `docs/ai-context/spec.md`). CarPlay's caller is `CarPlayAudioSession`. The
/// in-app paths had **no** such caller, so their audio played into whatever the
/// session happened to be: `.soloAmbient` on a fresh launch (silenced by the
/// hardware mute switch) or `.record` + inactive left by `AudioRecorder` after
/// an in-app mic capture (playback not permitted at all) → no audio. macOS has
/// no `AVAudioSession`, which is why the same controls worked there.
///
/// WHO CALLS IT, AND WHAT STAYS THEIRS: this type owns the session's SHAPE and
/// nothing else. Each caller keeps its own policy — `ThreadSpeaker` skips both
/// calls while CarPlay holds the session and swallows failures (a thrown error
/// must not enter the speak path), while `WorkboardAudioOutput` records WHICH
/// card holds the claim and treats a refused activation as a refusal rather
/// than playing blind. Merging those policies would be wrong: they are
/// different promises about the same hardware.
///
/// `.playback`: spoken audio is AUDIBLE regardless of the hardware silent
/// switch (a user-tapped Speak — or a tapped voice note — is intentional
/// playback, like tapping a voice message; matches CarPlay's always-audible
/// posture). It also routes to the speaker by default (no `.defaultToSpeaker`,
/// which is a `.playAndRecord`-only option). `.spokenAudio` is Apple's
/// documented mode for spoken-word playback (podcasts / audiobooks / TTS).
/// `.duckOthers` dips music during the utterance rather than stopping it;
/// `deactivate()` un-ducks it via `.notifyOthersOnDeactivation` at the terminals
/// (completion / stop) AND on user pause — paused audio must not keep other
/// apps' audio ducked; the resume path re-activates. That un-duck is
/// BEST-EFFORT at every call site: a leg that still holds audio I/O while
/// paused (the Apple synth keeps `isSpeaking`) can make `setActive(false)`
/// throw busy, and the duck then persists until a terminal.
enum SpokenAudioSession {
    /// Configure + activate the shared session for spoken-word playback.
    /// Idempotent — safe to call on every fresh start / resume;
    /// `AVAudioSession` reconciles.
    static func configureAndActivate() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try session.setActive(true, options: [])
    }

    /// Release the session when playback reaches a terminal state (completion /
    /// stop) or pauses (the resume path re-activates).
    /// `.notifyOthersOnDeactivation` tells ducked music / podcasts to resume.
    static func deactivate() throws {
        try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
#endif
