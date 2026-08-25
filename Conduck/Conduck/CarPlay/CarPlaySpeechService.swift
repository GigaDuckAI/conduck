// SPDX-License-Identifier: Apache-2.0

#if os(iOS)
import Foundation
import AVFoundation
import os.log

/// `AVSpeechSynthesizer` wrapper for CarPlay spoken acks.
///
/// Why on-device TTS (not server TTS):
/// - Free, fully on-device, offline — zero extra latency or cost per turn.
/// - At 1–4 word utterance length (e.g. "Noted.", "Saved for later."), the
///   usual critique of AVSpeechSynthesizer (flat prosody on long narration)
///   disappears. The neutral system voice reads as competent and crisp.
/// - V2 steerable TTS (OpenAI `gpt-4o-mini-tts`, ElevenLabs Flash) is a clean
///   swap at this service boundary if field feedback ever says the default
///   voice feels too clinical.
///
/// Voice selection mirrors the device language (not transcript language) and
/// excludes Novelty voices (Zarvox/Trinoids) and Personal Voices (user-cloned).
/// Both exclusions matter — we do not want a Conduck system ack spoken in a
/// robotic alien voice or in the user's own cloned voice.
@MainActor
final class CarPlaySpeechService: NSObject, AVSpeechSynthesizerDelegate {
    // MARK: - Singleton

    /// Shared instance. A single synthesizer is enough — CarPlay plays one
    /// ack at a time, sequentially with recording turns.
    static let shared = CarPlaySpeechService()

    // MARK: - Internal state

    /// On-device synthesizer for fixed-string acks (errors, sign-off, "Done.").
    /// Built LAZILY on first speak — see `synthesizer`. Constructing an
    /// `AVSpeechSynthesizer` eagerly adds idle audio pressure that, on the
    /// CarPlay Simulator, can amplify a `mediaserverd` reacquisition failure;
    /// a session that ends without ever speaking (the common case) now never
    /// instantiates one.
    private var _synthesizer: AVSpeechSynthesizer?

    /// Lazy on-device synthesizer accessor. Wires the delegate + pins the shared
    /// app audio session on first build (NEVER its own; `true` is
    /// the default, pinned to document intent + guard a default change).
    private var synthesizer: AVSpeechSynthesizer {
        if let s = _synthesizer { return s }
        let s = AVSpeechSynthesizer()
        s.delegate = self
        s.usesApplicationAudioSession = true
        _synthesizer = s
        return s
    }

    /// CarPlay-scoped TTS orchestrator. Owns its OWN `ReplyVoice` (not the
    /// `.shared` Settings-preview one) so its in-flight cloud/Apple playback is
    /// independent of any Settings "Speak a sample" the user might trigger.
    /// Routes AGENT replies (LLM content) only — fixed strings (`speak(_:)`,
    /// errors, sign-off) stay on the on-device `synthesizer` (never the cloud
    /// voice). Plays on Conduck's held `.playAndRecord`/`.voiceChat` session with
    /// NO category swap (`SpeechPlayer` and the chunk queue's per-chunk players
    /// both guarantee this), so the deactivate-once HFP invariant is
    /// preserved.
    ///
    /// Built LAZILY on the first AGENT reply (see `replyVoice`): `ReplyVoice()`
    /// constructs a `SpeechPlayer` with a SECOND `AVSpeechSynthesizer`, so eager
    /// construction doubled the idle audio pressure for every session — including
    /// ones that only ever play a fixed-string ack or end silently. Deferring it
    /// means `cancel()` / End on a never-spoke session touches no audio objects.
    private var _replyVoice: ReplyVoice?

    private var replyVoice: ReplyVoice {
        if let r = _replyVoice { return r }
        // `.standard` = the same chunked pipeline as iPhone/iPad/Mac: a long
        // cloud reply speaks from the small head chunk while the tail
        // synthesizes underneath — in the car, first-word latency that scales
        // with reply length reads as a dead session. Session-safe under the
        // deactivate-once invariant: the queue's per-chunk
        // `AVAudioPlayer`s ride the held session exactly like the single-blob
        // path (never `setCategory`/`setActive`), the completion stays
        // exactly-once through `ReplyVoice`'s latch on every terminal (final
        // chunk, mid-queue Apple fallback), and `cancel()` fires nothing.
        let r = ReplyVoice(chunkPolicy: .standard)
        _replyVoice = r
        return r
    }

    nonisolated private static let log = Logger(subsystem: Constants.identityNamespace, category: "CarPlaySpeech")

    /// Callback invoked when the current utterance finishes (success) or is
    /// cancelled, TYPED with how it ended (`.finished` = natural `didFinish`;
    /// `.incomplete` = `didCancel`). Used by `CarPlayRecordingService` to drive
    /// state machine transitions back to idle; fixed-string callers wrap a
    /// parameterless closure that fires on either terminal (a cancelled ack
    /// still advances their flow — see `speak(_:completion:)`).
    private var completion: (@MainActor @Sendable (SpeakTerminal) -> Void)?

    /// OPTIONAL "audio actually began" signal for the CURRENT fixed-string
    /// utterance — fired from the synthesizer's `didStart` delegate, exactly
    /// once, then cleared. Set ONLY by `speakAgent`'s empty-reply "Done."
    /// branch (the fixed-string path has no `ReplyVoice` `.startedPlaying`
    /// hook): the heard-marker needs PROOF of audio, so the optimistic
    /// fire-before-speak this replaces was not enough. Cleared on every new
    /// utterance / cancel / media reset.
    private var pendingFirstAudio: (@MainActor @Sendable () -> Void)?

    /// Identity of the utterance the stored callbacks belong to (mirrors
    /// `SpeechPlayer.currentUtteranceID`). Delegate callbacks hop through
    /// async main-actor tasks, so a SUPERSEDED utterance's late `didCancel` /
    /// `didStart` can land AFTER a new speak installed fresh callbacks —
    /// without this guard it would consume or fire the NEW utterance's
    /// closures. Cleared by `fireCompletion` / cancel / reset.
    private var currentUtteranceID: ObjectIdentifier?

    // MARK: - Init

    override private init() {
        super.init()
        // The on-device `synthesizer` and the agent-reply `replyVoice` are built
        // lazily (see their accessors) — the delegate + `usesApplicationAudioSession`
        // are wired on first build, so the init does no eager audio work. Conduck
        // holds ONE `.playAndRecord`/`.voiceChat` session for the whole session
        // (activate-once / deactivate-once); both speech engines ride
        // it and NEVER create/tear down their own.
    }

    // MARK: - Public API

    /// Speak a short localized phrase. Calls `completion` on the main actor
    /// when finished or cancelled.
    ///
    /// - Parameters:
    ///   - phrase: The already-localized phrase to speak (1–4 words ideal).
    ///   - completion: Called exactly once, after `didFinish` or `didCancel`
    ///     (either terminal — a cancelled ack still advances the caller's flow).
    func speak(_ phrase: String, completion: @escaping @MainActor @Sendable () -> Void) {
        speakFixed(phrase, onFirstAudio: nil) { _ in completion() }
    }

    /// Typed fixed-string speak — the shared implementation behind
    /// `speak(_:completion:)` and `speakAgent`'s empty-reply "Done." branch
    /// (which needs the terminal value + a real first-audio signal).
    private func speakFixed(
        _ phrase: String,
        onFirstAudio: (@MainActor @Sendable () -> Void)?,
        completion: @escaping @MainActor @Sendable (SpeakTerminal) -> Void
    ) {
        // If a previous utterance is still in flight (rare — means the caller
        // didn't wait), stop it cleanly before enqueuing the new one. Its late
        // `didCancel` is identity-guarded below, so it cannot consume THIS
        // utterance's callbacks; the superseded caller's completion is dropped
        // (mirrors `SpeechPlayer.stopInFlight`'s replace-without-firing).
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }

        self.completion = completion
        self.pendingFirstAudio = onFirstAudio

        let utterance = AVSpeechUtterance(string: phrase)
        prepare(utterance)
        currentUtteranceID = ObjectIdentifier(utterance)
        synthesizer.speak(utterance)
        // DIAGNOSTIC (CarPlay dashboard-fall investigation): timestamps the
        // synth-speak issue relative to the scene/route/interruption logs so we
        // can tell whether TTS-start precedes a scene resign. Device-audio
        // facts only — never the phrase/reply text.
        let session = AVAudioSession.sharedInstance()
        Self.log.info("speak() issued; main=\(Thread.isMainThread, privacy: .public) isSpeaking=\(self.synthesizer.isSpeaking, privacy: .public) out=[\(session.currentRoute.outputs.map(\.portType.rawValue).joined(separator: ","), privacy: .public)] cat=\(session.category.rawValue, privacy: .public)")
    }

    /// Speak an AGENT reply (LLM-generated content). Runs the shared
    /// `ReplySanitizer.spoken(_:)` Markdown strip FIRST so the synthesizer
    /// never reads literal `**asterisks**`, backticks, URLs, or emoji aloud —
    /// the TTS-strip mandate (CarPlay is the highest-stakes TTS
    /// surface: a driver can't easily dismiss a garbled multi-minute reply).
    /// Fixed-string TTS (errors, sign-off) uses `speak(_:)` and bypasses the
    /// strip — only LLM content needs sanitizing.
    ///
    /// `onFirstAudio` (optional, NON-LATCHED, at most once) fires when reply
    /// audio actually STARTS — the head chunk's cloud synthesis takes seconds,
    /// and the caller must not show "Replying" over that silence (it reads as
    /// a hang). Wired to `ReplyVoice`'s `.startedPlaying` signal, which covers
    /// every arm: cloud blob, chunked first chunk, and the Apple fallback; the
    /// "Done." branch wires it to the fixed synth's real `didStart` instead.
    /// It is PROOF of audio (the heard-marker gates on it) — never fire it
    /// optimistically before playback begins.
    ///
    /// `completion` carries the turn's `SpeakTerminal` — `.finished` only when
    /// the complete reply (or the "Done." substitute) was audibly delivered to
    /// its natural end.
    func speakAgent(
        _ reply: String,
        onFirstAudio: (@MainActor @Sendable () -> Void)? = nil,
        completion: @escaping @MainActor @Sendable (SpeakTerminal) -> Void
    ) {
        // Sanitize HERE (not via `ReplyVoice`'s sanitize flag) so we can detect
        // the empty-after-strip case and substitute CarPlay's own "Done."
        // terminal — `ReplyVoice` would otherwise fire the completion silently
        // on empty, which on CarPlay would advance the loop with no spoken cue.
        let sanitized = ReplySanitizer.spoken(reply)

        guard !sanitized.isEmpty else {
            // All-emoji / empty reply → speak a brief non-empty fallback via the
            // on-device synth (a fixed string, not LLM content → never cloud).
            // First audio is signalled from the synth's `didStart` delegate —
            // real proof, not the old optimistic fire (the on-device synth
            // starts near-instantly, so the template flip is not delayed).
            speakFixed(String(localized: "Done."), onFirstAudio: onFirstAudio, completion: completion)  // xcstrings: existing key
            return
        }

        // Route the sanitized LLM reply through the CarPlay-scoped `ReplyVoice`
        // (active TTS engine → cloud or Apple, Apple fallback on any failure).
        // `sanitize: false` because we already stripped above — never double-
        // sanitize. The completion is the SAME closure `CarPlayRecordingService`
        // passed (drives `reArmAfterSettle`); `ReplyVoice` fires it exactly once
        // on every path, INCLUDING a cloud-fetch failure, so the loop never
        // strands the driver.
        replyVoice.speak(
            sanitized,
            sanitize: false,
            onStateChange: { activity in
                if case .startedPlaying = activity { onFirstAudio?() }
            },
            completion: completion
        )
    }

    /// Shared utterance configuration (applied before `synthesizer.speak`).
    private func prepare(_ utterance: AVSpeechUtterance) {
        utterance.voice = Self.selectVoice()
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        utterance.pitchMultiplier = 1.0
        utterance.preUtteranceDelay = 0.05
        utterance.postUtteranceDelay = 0.0
    }

    /// Stop any in-flight utterance immediately. Used when tearing down the
    /// CarPlay scene or transitioning out of `speaking` under an error path.
    /// Touches the lazy engines ONLY if they were already built — End on a
    /// session that never spoke must not instantiate a synthesizer (the idle
    /// audio pressure this fix removes).
    func cancel() {
        if let s = _synthesizer, s.isSpeaking {
            s.stopSpeaking(at: .immediate)
        }
        // Also stop any in-flight AGENT-reply playback (cloud mp3 or the
        // `ReplyVoice` Apple fallback). `ReplyVoice.cancel()` does NOT fire the
        // completion (the caller is tearing down) — matching the synth branch
        // above where the delegate, not `cancel`, fires it.
        _replyVoice?.cancel()
    }

    /// Media-services reset recovery: `mediaserverd` was torn down, so the
    /// synthesizer + `ReplyVoice`/`AVAudioPlayer` objects are now invalid. Drop
    /// them (and any pending completion) so the next speak builds fresh ones.
    /// CarPlay-scoped — called from `CarPlayRecordingService`'s media-reset
    /// observer, which is also ending the session, so the dropped completion is
    /// moot (the turn token is cancelled there). Safe to mutate from a foreign
    /// trigger despite being a process-global singleton because CarPlay is
    /// effectively single-scene (one active `CPTemplateApplicationScene`) — there
    /// is no second live speak to clobber.
    func resetForMediaServicesReset() {
        if let s = _synthesizer, s.isSpeaking {
            s.stopSpeaking(at: .immediate)
        }
        _synthesizer = nil
        _replyVoice?.cancel()
        _replyVoice = nil
        completion = nil
        pendingFirstAudio = nil
        currentUtteranceID = nil
    }

    // MARK: - Voice selection

    /// The CarPlay fallback voice = the system DEFAULT voice for the current
    /// language. We deliberately do NOT scan `speechVoices()` for the
    /// highest-`quality` voice: that list keeps reporting enhanced/premium
    /// voices that were downloaded once and later removed (common after an iOS
    /// major upgrade) with no installed flag, and selecting an uninstalled one
    /// synthesizes SILENCE — the worst possible failure hands-free in the car.
    /// The language-default voice is always installed and honours the user's
    /// Settings → Accessibility → Spoken Content choice. Mirrors
    /// `SpeechPlayer.selectVoice` + `WatchReplySpeaker`.
    private static func selectVoice() -> AVSpeechSynthesisVoice? {
        AVSpeechSynthesisVoice(language: AVSpeechSynthesisVoice.currentLanguageCode())
    }

    // MARK: - AVSpeechSynthesizerDelegate

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didStart utterance: AVSpeechUtterance
    ) {
        // DIAGNOSTIC: confirms TTS audio actually began (vs. the scene resigning
        // before any audio rendered). Also the honest "audio began" moment for
        // the fixed-string first-audio signal ("Done." branch) — identity-
        // guarded so a superseded utterance's late didStart can't fire it.
        Self.log.info("synth didStart")
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in
            guard self.currentUtteranceID == id else { return }
            let started = self.pendingFirstAudio
            self.pendingFirstAudio = nil
            started?()
        }
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didFinish utterance: AVSpeechUtterance
    ) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in
            guard self.currentUtteranceID == id else { return }
            self.fireCompletion(.finished)
        }
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didCancel utterance: AVSpeechUtterance
    ) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in
            guard self.currentUtteranceID == id else { return }
            self.fireCompletion(.incomplete)
        }
    }

    @MainActor
    private func fireCompletion(_ terminal: SpeakTerminal) {
        let pending = completion
        completion = nil
        pendingFirstAudio = nil
        currentUtteranceID = nil
        pending?(terminal)
    }
}
#endif
