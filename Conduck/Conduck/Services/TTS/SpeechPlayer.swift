// SPDX-License-Identifier: Apache-2.0

// Conduck
// SpeechPlayer.swift
//
// Cloud Text-to-Speech playback primitive (iOS / macOS — NOT the Watch
// target; the Watch owns a local player inside `WatchReplySpeaker`). Owns BOTH
// an `AVAudioPlayer` (for cloud mp3 `Data`) and an `AVSpeechSynthesizer` (the
// Apple on-device fallback), and funnels EVERY terminal — audio `didFinish`,
// synth `didFinish`, synth `didCancel`, audio decode error — through ONE
// nil-then-call funnel per leg, so a completion can never fire twice.
//
// TYPED TERMINALS: `playCloud` reports a `CloudPlaybackOutcome` —
// `.finished` only on a natural, successful end; `.failed(stage)` on
// undecodable bytes, a refused start, `didFinish(successfully: false)`, or a
// mid-clip decode error. The PLAYER never decides policy: `ReplyVoice` maps a
// failure to the Apple fallback (chat) or a loud `.failure` (preview). The
// Apple leg's completion carries a `SpeakTerminal`: `.finished` on the synth's
// natural `didFinish`, `.incomplete` on a `didCancel` the caller did NOT
// initiate (system interruption tearing the utterance down mid-reply) — an
// explicit `stop()`/`stopInFlight` clears the completion first and fires
// nothing. CarPlay's heard-marker relies on this distinction; see
// `SpeakTerminal` in `SpeakEngine.swift`.
//
// DELEGATE IDENTITY GUARDS (ported from `WatchReplySpeaker`, the reference
// pattern): AVFoundation delegate terminals carry no turn token, so each is
// guarded on the `ObjectIdentifier` of the player/utterance it belongs to. A
// STALE terminal from a superseded clip — one whose main-actor hop lands AFTER
// a new `playCloud`/`playApple` installed a fresh completion — is then a
// structural no-op instead of firing the NEW leg's completion. Both funnels
// clear the identity BEFORE invoking the pending closure, because the failure
// handler (`ReplyVoice.startAppleLeg`) re-enters this player immediately.
// Out-of-ORDER delivery between two Tasks hopping to the main actor (e.g. a
// `didFinish` overtaking its own `didStart`) is benign by construction: every
// handler is nil-then-call latched AND identity-guarded, so the late event
// no-ops — it can drop an optional progress signal, never corrupt a terminal.
//
// AUDIO SESSION — load-bearing invariant (CarPlay deactivate-once):
//   This type NEVER calls `setCategory` / `setActive`. It plays on whatever
//   session the CALLER already holds (CarPlay's single `.playAndRecord` /
//   `.voiceChat` session activated-once / deactivated-once; the iOS foreground
//   tap path; etc.). Swapping the category here would drop CarPlay's held HFP
//   route between turns and break the deactivate-once invariant. `ReplyVoice`
//   is the single boundary above this; both rely on the caller's session.
//
// MEMORY: the mp3 `Data` is retained ONLY for the player's lifetime (the
// `AVAudioPlayer` holds its own copy) and the player reference is released in
// the terminal funnel. Audio never touches disk.

#if !os(watchOS)
import Foundation
import AVFoundation

/// Plays a spoken reply via either a cloud mp3 (`AVAudioPlayer`) or Apple's
/// on-device `AVSpeechSynthesizer`, with per-leg exactly-once completion
/// funnels and delegate identity guards. Owned by `ReplyVoice`.
@MainActor
final class SpeechPlayer: NSObject, AVAudioPlayerDelegate, AVSpeechSynthesizerDelegate {

    // MARK: - State

    /// Cloud-audio player. Held only while a clip is playing; released in the
    /// terminal funnel. A new `playCloud` replaces any prior player.
    private var audioPlayer: AVAudioPlayer?

    /// Apple on-device synthesizer (the fallback voice). One instance reused
    /// across utterances — a new `playApple` stops any in-flight utterance.
    private let synthesizer = AVSpeechSynthesizer()

    /// The pending CLOUD completion (typed outcome). Set by `playCloud`;
    /// nil-then-called by `fireCloudCompletion(_:)` so it can never fire twice.
    /// Stored SEPARATELY from the Apple completion — one parameterless slot
    /// cannot safely represent both callback signatures, and a leg's terminal
    /// must never be able to fire the other leg's closure.
    private var cloudCompletion: (@MainActor @Sendable (CloudPlaybackOutcome) -> Void)?

    /// The pending APPLE completion, typed with how the utterance ended:
    /// `.finished` on the synth's natural `didFinish`, `.incomplete` on
    /// `didCancel` (a system/interruption stop — an explicit caller `stop()`
    /// clears this slot first, so it fires nothing). Set by `playApple`;
    /// nil-then-called by `fireAppleCompletion(_:)`.
    private var appleCompletion: (@MainActor @Sendable (SpeakTerminal) -> Void)?

    /// Identity of the clip / utterance this player currently owns. Delegate
    /// terminals guard on these (via `ObjectIdentifier`, `Sendable` across the
    /// nonisolated → MainActor hop); cleared by every terminal / stop BEFORE
    /// the pending closure runs. Ported from `WatchReplySpeaker`.
    private var currentPlayerID: ObjectIdentifier?
    private var currentUtteranceID: ObjectIdentifier?

    /// OPTIONAL, fire-and-forget "playback actually started" signal, set by
    /// `playCloud` / `playApple`. PURELY ADDITIVE (P3 chat speak-state UI): it
    /// is NOT part of the exactly-once completion contract — it never routes
    /// through the terminal funnels, never touches the audio session, and is
    /// cleared the moment it fires (cloud: right after `play()` returns true;
    /// Apple: in `speechSynthesizer(_:didStart:)`). Default callers (CarPlay /
    /// Settings) pass nil → byte-identical behavior. A `stop()` / `stopInFlight`
    /// clears it without firing (the start never happened / was abandoned).
    private var onStart: (@MainActor @Sendable () -> Void)?

    /// OPTIONAL, REPEATED Apple-leg progress signal — fired on the synth's
    /// `didStart` AND every `willSpeakRangeOfSpeechString`. NOT latched (unlike
    /// `onStart`): `ReplyVoice` re-arms its Apple inactivity watchdog on every
    /// tick, so a synth that is genuinely speaking can never be cut off, while
    /// one that silently stalls (no ticks) is settled. Cleared at every
    /// terminal / stop. nil for callers without a watchdog (Settings preview).
    private var onAppleProgress: (@MainActor @Sendable () -> Void)?

    // MARK: - Init

    override init() {
        super.init()
        synthesizer.delegate = self
        // Ride the caller's audio session — NEVER create/activate our own (see
        // the file header). `true` is the default; pinned to document intent +
        // guard against a default change. Do NOT set `false`.
        // `usesApplicationAudioSession` is iOS/watchOS-only (macOS has no
        // AVAudioSession), so gate it out of the macOS build.
        #if !os(macOS)
        synthesizer.usesApplicationAudioSession = true
        #endif
    }

    // MARK: - Public API

    /// Play cloud-synthesized mp3 `data` on the caller's audio session. Calls
    /// `onDone` exactly once with the typed outcome: `.finished` on a natural
    /// successful end; `.failed(.undecodable)` when the bytes won't decode;
    /// `.failed(.startRefused)` when `play()` won't start; and
    /// `.failed(.playbackFailed)` on `didFinish(successfully: false)` or a
    /// mid-clip decode error. NEVER touches the session category/activation and
    /// NEVER falls back itself — the caller owns failure policy.
    ///
    /// `onStart` (OPTIONAL, default nil) is the fire-and-forget "playback
    /// actually began" signal — fired AFTER `player.play()` returns true,
    /// exactly once, OUTSIDE the terminal funnel. nil → unchanged.
    func playCloud(
        _ data: Data,
        onStart: (@MainActor @Sendable () -> Void)? = nil,
        onDone: @escaping @MainActor @Sendable (CloudPlaybackOutcome) -> Void
    ) {
        stopInFlight()
        self.cloudCompletion = onDone
        self.onStart = onStart

        do {
            let player = try AVAudioPlayer(data: data)
            player.delegate = self
            audioPlayer = player
            currentPlayerID = ObjectIdentifier(player)
            guard player.play() else {
                // `play()` returned false — couldn't start (e.g. session not
                // ready). Typed terminal; the completion still fires exactly
                // once. Playback never began → drop the start signal unfired.
                self.onStart = nil
                fireCloudCompletion(.failed(.startRefused))
                return
            }
            // Playback began. Fire the additive start signal (NOT the
            // completion funnel) and clear it so it can't fire twice.
            fireStart()
        } catch {
            // Undecodable / corrupt mp3 bytes. Typed terminal — the caller
            // (`ReplyVoice`) decides Apple-fallback vs loud failure. Never log
            // the bytes. Playback never began → drop the start signal.
            self.onStart = nil
            fireCloudCompletion(.failed(.undecodable))
        }
    }

    /// Speak `text` via Apple's on-device synthesizer on the caller's session.
    /// Calls `onDone` exactly once, typed: `.finished` on the natural
    /// `didFinish`, `.incomplete` on `didCancel` (a system-driven stop — an
    /// explicit `stop()` clears the completion first and fires nothing).
    ///
    /// `onStart` (OPTIONAL, default nil) is the fire-and-forget "playback
    /// actually began" signal — fired from `speechSynthesizer(_:didStart:)`,
    /// exactly once, OUTSIDE the terminal funnel. nil → unchanged.
    func playApple(
        _ text: String,
        onStart: (@MainActor @Sendable () -> Void)? = nil,
        onDone: @escaping @MainActor @Sendable (SpeakTerminal) -> Void
    ) {
        playApple(text, language: nil, onStart: onStart, onProgress: nil, onDone: onDone)
    }

    /// Language- and progress-aware variant. `language` is a BCP-47
    /// content-language hint for the reply (resolved once per turn by
    /// `SpeechLanguageDetector`); nil → the device-language voice. `onProgress`
    /// is the REPEATED synth-activity tick (didStart + every word range) that
    /// `ReplyVoice`'s Apple inactivity watchdog re-arms on; nil → no ticks.
    /// The 3-arg overload above is the distinct `SpeechPlaying` witness for
    /// callers that don't carry a hint.
    func playApple(
        _ text: String,
        language: String?,
        onStart: (@MainActor @Sendable () -> Void)? = nil,
        onProgress: (@MainActor @Sendable () -> Void)? = nil,
        onDone: @escaping @MainActor @Sendable (SpeakTerminal) -> Void
    ) {
        stopInFlight()
        self.appleCompletion = onDone
        self.onStart = onStart
        self.onAppleProgress = onProgress

        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = Self.selectVoice(language: language)
        currentUtteranceID = ObjectIdentifier(utterance)
        synthesizer.speak(utterance)
    }

    /// Stop any in-flight playback (cloud or Apple) WITHOUT firing the stored
    /// completion — the caller is abandoning the turn (e.g. user navigated
    /// away, a new utterance is starting). Mirrors `CarPlaySpeechService.cancel`
    /// (which also leaves the completion to the delegate, but here `stop()` is
    /// an explicit abandon so we clear it to avoid a late delegate callback
    /// firing a stale closure).
    func stop() {
        // Clear the completions + identities BEFORE stopping so the
        // synthesizer's `didCancel` delegate (which would otherwise fire one)
        // is a no-op — the caller is abandoning the turn, not completing it.
        // Drop the additive start/progress signals too (the start never
        // happened / was abandoned).
        cloudCompletion = nil
        appleCompletion = nil
        currentPlayerID = nil
        currentUtteranceID = nil
        onStart = nil
        onAppleProgress = nil
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        audioPlayer?.stop()
        audioPlayer = nil
    }

    /// Pause in-flight playback (cloud OR Apple), PRESERVING the position so a
    /// later `resume()` continues from the same point — WITHOUT firing the
    /// stored completion (the turn isn't done) and WITHOUT tearing down the
    /// player, so the decoded audio is kept (no re-synthesis on resume). A no-op
    /// when nothing is currently playing. NEVER touches the audio-session
    /// category/activation (same invariant as the rest of this type — session
    /// moves belong to the session-owning caller; `ThreadSpeaker` releases the
    /// iOS chat session around a pause, see `ChatPlaybackSession`). The chat tap
    /// path is the only caller; CarPlay / Settings preview never pause (they
    /// `cancel()` / `stop()`).
    func pause() {
        if let player = audioPlayer {
            // Cloud mp3: `pause()` retains `currentTime`; `play()` resumes there.
            player.pause()
        } else if synthesizer.isSpeaking {
            // Apple synth: pause immediately so tapping pause silences NOW (not at
            // the next word boundary); `continueSpeaking()` resumes from the pause
            // point. (`isSpeaking` stays true while paused; `isPaused` reports paused.)
            synthesizer.pauseSpeaking(at: .immediate)
        }
    }

    /// Resume playback paused by `pause()`, continuing from the preserved
    /// position with NO re-fetch / re-synthesis. A no-op when nothing is paused
    /// (and harmless if already playing). `onStart` is NOT re-fired on resume —
    /// playback already began once; the chat UI drives paused → playing itself.
    func resume() {
        if let player = audioPlayer {
            player.play()
        } else if synthesizer.isPaused {
            synthesizer.continueSpeaking()
        }
    }

    // MARK: - Private

    /// Stop any in-flight playback in preparation for a new one, WITHOUT firing
    /// the previous completion (replacing a clip mid-flight should not invoke
    /// the old caller's done-handler). Clears completions + identities FIRST so
    /// the synthesizer's `didCancel` (and any already-hopping stale delegate)
    /// can't fire the soon-to-be-replaced closure.
    private func stopInFlight() {
        cloudCompletion = nil
        appleCompletion = nil
        currentPlayerID = nil
        currentUtteranceID = nil
        // Drop any pending start/progress signal from the prior clip — that
        // playback is being replaced and never reached its own start callback
        // (or already did and cleared this), so a stale `didStart` must not fire.
        onStart = nil
        onAppleProgress = nil
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        audioPlayer?.stop()
        audioPlayer = nil
    }

    /// CLOUD terminal funnel. Clears the identity + player + BOTH completions
    /// FIRST, then calls the captured cloud closure with the typed outcome, so
    /// a second terminal (e.g. a late `didFinish` after a decode error) is a
    /// no-op AND the closure may safely re-enter this player (the failure
    /// handler starts the Apple leg immediately). Releases the cloud player so
    /// the mp3 `Data` is freed.
    private func fireCloudCompletion(_ outcome: CloudPlaybackOutcome) {
        let pending = cloudCompletion
        cloudCompletion = nil
        appleCompletion = nil
        currentPlayerID = nil
        currentUtteranceID = nil
        // A terminal cancels any not-yet-fired start signal (e.g. cloud
        // `play()` returned false → no start happened). Independent of the
        // completion latch.
        onStart = nil
        onAppleProgress = nil
        audioPlayer = nil
        pending?(outcome)
    }

    /// APPLE terminal funnel — typed (`.finished` = natural `didFinish`,
    /// `.incomplete` = a `didCancel` the caller didn't initiate). Same
    /// clear-before-call discipline as the cloud funnel.
    private func fireAppleCompletion(_ terminal: SpeakTerminal) {
        let pending = appleCompletion
        appleCompletion = nil
        cloudCompletion = nil
        currentPlayerID = nil
        currentUtteranceID = nil
        onStart = nil
        onAppleProgress = nil
        audioPlayer = nil
        pending?(terminal)
    }

    /// Fire the OPTIONAL "playback began" signal exactly once, then clear it.
    /// PURELY ADDITIVE — separate from the terminal funnels: this is NOT a
    /// terminal, does NOT touch the completions / `audioPlayer` / the audio
    /// session, and does NOT participate in the exactly-once completion
    /// contract. Nil-then-call so a second `didStart` (or a redundant call) is
    /// a no-op.
    private func fireStart() {
        let started = onStart
        onStart = nil
        started?()
    }

    // MARK: - Voice selection (Apple fallback)

    /// The Apple fallback voice = the system DEFAULT voice for the current
    /// language. We deliberately do NOT scan `speechVoices()` for the
    /// highest-`quality` voice: that list keeps reporting enhanced/premium
    /// voices that were downloaded once and later removed (common after an iOS
    /// major upgrade) with no installed flag, and selecting an uninstalled one
    /// synthesizes SILENCE. The language-default voice is always installed and
    /// honours the user's Settings → Accessibility → Spoken Content choice.
    /// Content-language selection mirrors `WatchReplySpeaker.speakApple` (the
    /// wrist sink); `CarPlaySpeechService.selectVoice` deliberately does NOT —
    /// it voices FIXED localized strings ("Done.", sign-offs), which stay in the
    /// device language, not the agent reply's.
    private static func selectVoice(language: String?) -> AVSpeechSynthesisVoice? {
        let deviceCode = AVSpeechSynthesisVoice.currentLanguageCode()
        // Prefer the reply's language when a voice for it is installed; a hint
        // with no matching voice (or no hint) degrades to the device-language
        // voice — never nil-voice silence. `reconcile` keeps the device region
        // (e.g. en-GB) when hint and device share a base language.
        let requested = SpeechLanguageDetector.reconcile(hint: language, deviceCode: deviceCode) ?? deviceCode
        return AVSpeechSynthesisVoice(language: requested)
            ?? AVSpeechSynthesisVoice(language: deviceCode)
    }

    // MARK: - AVAudioPlayerDelegate

    nonisolated func audioPlayerDidFinishPlaying(
        _ player: AVAudioPlayer,
        successfully flag: Bool
    ) {
        // `successfully: false` means playback died on a decoder error — a
        // FAILURE terminal, never a bare success (the silent-tail bug this
        // guard family fixes). Identity-guarded: a stale clip's terminal
        // landing after a new leg installed its completion is a no-op.
        let id = ObjectIdentifier(player)
        Task { @MainActor in
            guard self.currentPlayerID == id else { return }
            self.fireCloudCompletion(flag ? .finished : .failed(.playbackFailed))
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(
        _ player: AVAudioPlayer,
        error: Error?
    ) {
        // Decode error mid-playback — a FAILURE terminal. The caller decides
        // fallback policy. Never log the error payload.
        let id = ObjectIdentifier(player)
        Task { @MainActor in
            guard self.currentPlayerID == id else { return }
            self.fireCloudCompletion(.failed(.playbackFailed))
        }
    }

    // MARK: - AVSpeechSynthesizerDelegate

    /// Apple-fallback "playback began" hook. Fires the optional start signal +
    /// a progress tick — never a terminal funnel, never the audio session.
    /// A no-op when the signals are nil (CarPlay / Settings).
    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didStart utterance: AVSpeechUtterance
    ) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in
            guard self.currentUtteranceID == id else { return }
            self.fireStart()
            self.onAppleProgress?()
        }
    }

    /// Word-boundary progress tick — the Apple inactivity watchdog's re-arm
    /// signal. NOT latched (fires repeatedly while the synth is speaking).
    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        willSpeakRangeOfSpeechString characterRange: NSRange,
        utterance: AVSpeechUtterance
    ) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in
            guard self.currentUtteranceID == id else { return }
            self.onAppleProgress?()
        }
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didFinish utterance: AVSpeechUtterance
    ) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in
            guard self.currentUtteranceID == id else { return }
            self.fireAppleCompletion(.finished)
        }
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didCancel utterance: AVSpeechUtterance
    ) {
        // A `didCancel` that reaches this funnel was NOT caller-initiated
        // (`stop()`/`stopInFlight` clear the completion first) — it is the
        // system tearing the utterance down mid-reply (audio interruption,
        // media-services reset). The reply was NOT fully delivered.
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in
            guard self.currentUtteranceID == id else { return }
            self.fireAppleCompletion(.incomplete)
        }
    }
}
#endif
