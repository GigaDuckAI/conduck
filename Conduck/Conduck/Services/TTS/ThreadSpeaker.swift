// Conduck
// ThreadSpeaker.swift
//
// The SHARED per-message speak-state machine for the chat thread, used on EVERY
// surface (iPhone / iPad / Mac AND Apple Watch). NO `#if os` guard — this file
// compiles into both the iOS/macOS `Conduck` target and the `ConduckWatch Watch
// App` target. It is the UI source of truth for the Speak control: idle →
// loading → playing → paused, plus the toggle / supersede / stale-callback
// guards.
//
// Backed by a `SpeakEngine` (the cross-platform speak abstraction): `ReplyVoice`
// on iOS/macOS (cloud-TTS orchestration + Apple fallback), `WatchReplySpeaker`
// on watchOS (the wrist's local cloud-or-Apple player). The state machine is
// implemented ONCE here rather than duplicated per platform.
//
// `sanitize: true` — the engine reads the Markdown-stripped text, so literal
// `**asterisks**` / URLs / emoji aren't spoken. Driven by the per-bubble tap
// AND by the opt-in read-aloud auto-speak paths (iOS notification-open, Watch
// arrival/open — both staged through the shared `AutoSpeakMailbox`) — every
// path routes through this same machine so the bubble shows playing state and
// pause works identically.

import Foundation
#if os(iOS)
import AVFoundation
#endif

/// Thin `@Observable` wrapper around a `SpeakEngine`. One per thread view. Routes
/// the tapped bubble's text through the active speak engine and tracks which
/// bubble is the active one + its phase, so the Speak control + the amber
/// active-speaking outline are state-driven. Speaking a new utterance supersedes
/// the prior one (`engine.cancel()` before the new `speak`).
@Observable
@MainActor
final class ThreadSpeaker {
    private let engine: SpeakEngine

    /// Injectable clock for the auto-resume freshness window — mirrors
    /// `AutoSpeakMailbox` so tests drive expiry deterministically.
    private let now: () -> Date

    /// How long after a SYSTEM pause (watchOS ambient-dim suspension) a
    /// wrist-raise still auto-resumes. Beyond it, the reply stays paused and
    /// tappable (one-tap resume) but never auto-restarts — so "lower wrist, walk
    /// away, raise much later" can't jump-scare.
    private let autoResumeWindow: TimeInterval = 30

    /// - Parameter engine: the speak engine. iOS/macOS pass `ReplyVoice()`; the
    ///   Watch passes `WatchReplySpeaker()`. Tests inject a `ReplyVoice` built
    ///   with fake seams so the loading→playing→idle state machine can be driven
    ///   deterministically with no audio hardware.
    /// - Parameter now: injectable clock (defaults to the real clock); tests pass
    ///   a fake to drive the auto-resume freshness window.
    init(engine: SpeakEngine, now: @escaping () -> Date = { Date() }) {
        self.engine = engine
        self.now = now
        #if os(macOS)
        // Join the macOS exclusivity bus (weak registry — dies with the view).
        // The PARTY is this state machine, not the engine: a preempting stop
        // must reset the bubble's speak state, which an engine-level cancel
        // can't (it never fires the guarded completion). macOS-only: on iOS
        // the audio session arbitrates, and CarPlay's speaker must never be
        // preemptible.
        SpeechExclusivity.shared.register(self)
        #endif
        #if os(iOS)
        setupInterruptionObserver()
        #endif
    }

    #if os(iOS)
    deinit {
        // Block-observer tokens are NOT auto-removed on dealloc. Nonisolated
        // deinit may read stored properties (exclusive access), and
        // NotificationCenter removal is thread-safe. The observer block holds
        // self weakly — no retain cycle — so this deinit actually runs when
        // the owning view's @State is discarded.
        if let interruptionObserver {
            NotificationCenter.default.removeObserver(interruptionObserver)
        }
    }
    #endif

    /// The message currently being spoken (or being fetched for). Nil when idle.
    /// The single anchor for "which bubble is the active one" — every callback
    /// guards against it so a superseded turn can't mutate state.
    private(set) var speakingMessageID: UUID?

    /// The active speak phase for `speakingMessageID`. `.idle` whenever nothing
    /// is speaking.
    private(set) var state: SpeakState = .idle

    /// Messages whose LAST playback attempt fell back to the Apple built-in
    /// voice (the engine emitted `.fallbackStarted` — fallback audio actually
    /// began). EPHEMERAL by design: per-device, per-thread-view, never
    /// persisted to the store/CloudKit (a fallback describes one playback
    /// attempt on one device — syncing it would show other devices an event
    /// that never happened there; the durable forensic record is the
    /// device-local `TTSOutcomeLog` ring). Cleared for a message ONLY when a
    /// FRESH playback attempt starts for it — same-message pause / resume /
    /// loading-cancel taps keep the marker (the attempt it describes is still
    /// the latest one). Bounded by construction: one entry per re-spoken
    /// message in the open thread.
    private(set) var fallbackVoiceMessageIDs: Set<UUID> = []

    /// Whether the given bubble's latest playback used the built-in (Apple)
    /// fallback voice — drives the subtle per-message "Built-in voice" caption.
    func usedFallbackVoice(for id: UUID) -> Bool {
        fallbackVoiceMessageIDs.contains(id)
    }

    /// True when the CURRENT `.paused` state was caused by the SYSTEM (watchOS
    /// suspending built-in-speaker audio on the ambient dim), NOT by the user
    /// tapping pause. Only a system pause is eligible for wrist-raise auto-resume
    /// — the cardinal rule is that a reply the user paused BY HAND must never
    /// auto-restart. Set true ONLY in `systemDimPause()` (the dim-edge proactive
    /// pause) and `reconcileSystemPauseIfNeeded()` (the after-the-fact fallback);
    /// cleared by `clearSystemPauseMark()` on every transition that leaves
    /// `.paused` or starts a fresh turn.
    private(set) var pausedBySystem = false

    /// When the system pause was detected — bounds auto-resume to `autoResumeWindow`.
    private var systemPauseAt: Date?

    /// The speak state for a specific bubble — `.idle` unless that bubble is the
    /// active one. Drives both the footer glyph and the amber active-outline.
    func speakState(for id: UUID) -> SpeakState {
        id == speakingMessageID ? state : .idle
    }

    /// Tap handler for a message's Speak control — a play/pause/resume toggle on
    /// the ACTIVE bubble that NEVER re-synthesizes: re-tap while `.playing`
    /// pauses (audio kept in place), re-tap while `.paused` resumes from the same
    /// position, re-tap while `.loading` cancels (nothing has started, so there
    /// is no position to pause at). Tapping a DIFFERENT bubble supersedes the
    /// prior turn and starts a new one (loading → playing → idle). All engine
    /// callbacks are guarded by `messageID == speakingMessageID` so a stale,
    /// superseded turn's late callback can't resurrect/corrupt state.
    func speak(_ text: String, messageID: UUID) {
        // TAP PREFLIGHT: recover from a silent OS pause BEFORE the toggle switch,
        // so the FIRST tap after a watchOS ambient-dim suspension resumes instead
        // of "pausing" an already-stopped player (the stuck-`.playing`/two-tap
        // bug). If the engine is actually paused, this flips stale `.playing` →
        // `.paused`, and the `.paused` branch below then resumes on this SAME tap.
        // No-op off the Watch (engine's default `playbackStatus` is `.active`).
        reconcileSystemPauseIfNeeded()

        // Re-tapping the ACTIVE bubble is a play/pause/resume toggle (a different
        // bubble, below, supersedes + starts fresh).
        if speakingMessageID == messageID {
            switch state {
            case .playing:
                // Pause, preserving position. The reply's completion stays
                // pending (the turn isn't done); the next tap resumes from here.
                // A deliberate USER pause — never auto-resume it on wrist-raise.
                // On iOS the session is released below (other apps un-duck);
                // the resume branch re-activates it.
                clearSystemPauseMark()
                state = .paused
                engine.pause()
                #if os(iOS)
                // Release the chat session while paused — a paused reply must
                // not keep other apps' audio ducked (`.notifyOthersOnDeactivation`
                // un-ducks). AFTER engine.pause() so audio I/O is stopped before
                // setActive(false) (an active player throws '!act'; the try?
                // degrades to held-session behavior, never a broken pause).
                deactivatePlaybackSessionIfNeeded()
                #endif
                AccessibilityAnnouncer.announce(LocalizedStringResource(
                    "thread.speak.announce.paused", defaultValue: "Paused"))
                return
            case .paused:
                // Resume from the paused position — no re-fetch, no restart.
                #if os(macOS)
                // Resuming is audio starting again — silence the other macOS
                // speakers (e.g. an arrival speak that began while paused).
                SpeechExclusivity.shared.claim(self)
                #endif
                #if os(iOS)
                // Re-assert the chat playback session — the recorder or a route
                // change may have reset it while we were paused.
                activatePlaybackSessionIfNeeded()
                #endif
                // Resuming — this is now a fresh listen, so drop any system-pause
                // mark (whether it was a user or system pause, we're playing again).
                clearSystemPauseMark()
                state = .playing
                engine.resume()
                AccessibilityAnnouncer.announce(LocalizedStringResource(
                    "thread.speak.announce.reading", defaultValue: "Reading reply"))
                return
            case .loading:
                // Still fetching — nothing is playing, so a re-tap cancels.
                stop()
                return
            case .idle:
                break  // Defensive: idle ⇒ not actually active — start below.
            }
        }

        // Supersede any prior in-flight/playing/paused turn, then claim this one.
        // The cancel() drops the prior completion (it never fires) so its guarded
        // callbacks are doubly inert. Fresh turn ⇒ drop any prior system-pause mark.
        engine.cancel()
        clearSystemPauseMark()
        // FRESH attempt for this message — drop its stale fallback marker (this
        // is the ONLY clear site: pause/resume/loading-cancel taps on the same
        // message keep the marker, which still describes the latest attempt).
        fallbackVoiceMessageIDs.remove(messageID)
        #if os(macOS)
        // Silence every OTHER macOS speaker (the shared arrival/preview voice,
        // another window's ThreadSpeaker) — `engine.cancel()` above only covers
        // our own engine instance.
        SpeechExclusivity.shared.claim(self)
        #endif
        speakingMessageID = messageID
        state = .loading

        #if os(iOS)
        // Own the audio session for the chat read-aloud path — iOS has no other
        // caller that configures a playback session (ReplyVoice/SpeechPlayer ride
        // it; the recorder leaves it `.record`/inactive). Skipped while CarPlay
        // owns the session. See `ChatPlaybackSession`.
        activatePlaybackSessionIfNeeded()
        #endif

        engine.speak(
            text,
            sanitize: true,
            onStateChange: { [weak self] activity in
                guard let self, messageID == self.speakingMessageID else { return }
                switch activity {
                case .startedPlaying:
                    // Canonical "fresh playback really began" — clear any stale
                    // system-pause mark from a prior cycle.
                    self.clearSystemPauseMark()
                    self.state = .playing
                    AccessibilityAnnouncer.announce(LocalizedStringResource(
                        "thread.speak.announce.reading", defaultValue: "Reading reply"))
                case .fallbackStarted:
                    // The Apple FALLBACK leg's audio actually began for a turn
                    // whose intended engine was a cloud voice — mark the bubble
                    // (fallback transparency). A mid-turn fallback arrives with
                    // `state` already `.playing` (no `.startedPlaying` re-emit),
                    // so ensure the phase without re-announcing.
                    self.fallbackVoiceMessageIDs.insert(messageID)
                    self.state = .playing
                }
            },
            completion: { [weak self] in
                // Reset only if THIS turn is still the active one — a superseded
                // turn's completion must not clear a newer turn's state.
                guard let self, messageID == self.speakingMessageID else { return }
                self.speakingMessageID = nil
                self.state = .idle
                self.clearSystemPauseMark()
                #if os(iOS)
                // Terminal — release the chat playback session so ducked audio
                // resumes. A superseded turn returned above, so a newer turn's
                // session stays held.
                self.deactivatePlaybackSessionIfNeeded()
                #endif
            }
        )
    }

    /// Stop the active utterance (re-tap / external stop). Cancels playback
    /// without firing the completion (the engine's cancel() owns that), resets to
    /// idle, and announces for VoiceOver.
    func stop() {
        engine.cancel()
        speakingMessageID = nil
        state = .idle
        clearSystemPauseMark()
        #if os(iOS)
        deactivatePlaybackSessionIfNeeded()
        #endif
        AccessibilityAnnouncer.announce(LocalizedStringResource(
            "thread.speak.announce.stopped", defaultValue: "Stopped"))
    }

    // MARK: - Watch dim-cut reconciliation

    /// Reconcile the UI state with the ENGINE's real playback state — recovery
    /// from a watchOS ambient-dim suspension, which silently pauses (or stops)
    /// built-in-speaker audio while firing NO terminal delegate, so `state` would
    /// otherwise stay stuck at `.playing` (the stuck-pause-glyph / two-tap-resume
    /// bug). A pure no-op off the Watch: `SpeakEngine`'s default `playbackStatus`
    /// is `.active`, and only the watch view calls this. Called at three edges —
    /// the same-message tap preflight, the wrist-raise `scenePhase` `.active`
    /// edge, and the `isLuminanceReduced` un-dim edge — so we never depend on a
    /// single OS signal (a suspension interruption can be delivered late).
    func reconcileSystemPauseIfNeeded() {
        guard speakingMessageID != nil, state == .playing else { return }
        switch engine.playbackStatus {
        case .active:
            break
        case .pausedResumable:
            // The OS paused us with position preserved. Reflect it — button flips
            // to the play glyph, and this is a SYSTEM pause (auto-resume eligible).
            state = .paused
            pausedBySystem = true
            systemPauseAt = now()
        case .inactive:
            // Playback is truly dead (never resumable) yet no terminal fired —
            // reset silently. NOT `stop()`: this is a reconcile, not a user stop,
            // so it must not announce "Stopped" to VoiceOver.
            silentReset()
        }
    }

    /// Own the watchOS dim-cut at the MOMENT it happens: the watch view calls
    /// this on the DIM edge (`isLuminanceReduced` flipping true / `scenePhase`
    /// leaving `.active`) when audio is on the built-in speaker, so the pause is
    /// OURS — position-preserving, state truthful, marked system-caused (the
    /// wrist-raise auto-resume acts on the mark). This edge is PRIMARY and the
    /// after-the-fact reconcile below is the fallback, because the reconcile's
    /// heuristic is blind to the commonest cut shape: a suspension can freeze an
    /// `AVAudioPlayer` with `isPlaying` still reading `true`, so `playbackStatus`
    /// reports `.active` and the stuck-`.playing` state survives every raise.
    /// Pausing at the edge also parks a chunk queue BETWEEN chunks, closing the
    /// dim-in-a-gap hole the reconcile documents as invisible. Route-gating
    /// (Bluetooth audio survives the dim and must not be interrupted) is the
    /// CALLER's job — this stays a pure, cross-target state transition. Guarded
    /// to `.playing`: a user-paused reply must never gain auto-resume
    /// eligibility, and an idle/loading turn has no audio to save.
    func systemDimPause() {
        guard speakingMessageID != nil, state == .playing else { return }
        state = .paused
        pausedBySystem = true
        systemPauseAt = now()
        engine.pause()
    }

    /// Auto-resume a reply the SYSTEM paused (ambient dim) on the wrist-raise —
    /// but only within `autoResumeWindow` (so a much-later raise can't jump-scare),
    /// and NEVER a reply the user paused by hand (`pausedBySystem` gates it). Past
    /// the window, the mark is cleared but the reply stays paused + tappable, so
    /// one-tap resume still works. Idempotent: once it resumes (`.playing`,
    /// `pausedBySystem == false`) a second raise-edge call no-ops.
    func autoResumeIfSystemPaused() {
        guard speakingMessageID != nil, state == .paused, pausedBySystem else { return }
        guard let at = systemPauseAt, now().timeIntervalSince(at) < autoResumeWindow else {
            clearSystemPauseMark()   // expired — keep it paused, drop auto eligibility
            return
        }
        #if os(macOS)
        SpeechExclusivity.shared.claim(self)
        #endif
        clearSystemPauseMark()
        state = .playing
        engine.resume()
    }

    /// Silent terminal reset for a dead-but-unreported turn (`.inactive` during
    /// reconcile). Drops the engine's still-pending completion (correct — playback
    /// is genuinely over) and returns to idle WITHOUT the VoiceOver "Stopped"
    /// announce that `stop()` makes.
    private func silentReset() {
        engine.cancel()
        speakingMessageID = nil
        state = .idle
        clearSystemPauseMark()
        #if os(iOS)
        deactivatePlaybackSessionIfNeeded()
        #endif
    }

    /// Clear the system-pause bookkeeping. Called on EVERY transition that leaves
    /// `.paused` or starts a fresh turn, so a user-paused reply can never inherit
    /// a stale auto-resume eligibility.
    private func clearSystemPauseMark() {
        pausedBySystem = false
        systemPauseAt = nil
    }

    #if os(iOS)
    /// Activate the iOS chat playback session before read-aloud starts or
    /// resumes — UNLESS CarPlay owns the session, in which case we ride it
    /// untouched (preserving CarPlay's single-activate / deactivate-once
    /// invariant). `try?`: a failed activation just leaves prior behavior, never
    /// a thrown error into the speak path. See `ChatPlaybackSession`.
    private func activatePlaybackSessionIfNeeded() {
        guard !CarPlayRecordingService.anySessionActive else { return }
        try? ChatPlaybackSession.configureAndActivate()
    }

    /// Release the iOS chat playback session at a terminal state (completion or
    /// stop) or on user pause — a paused reply must not keep other apps' audio
    /// ducked; the resume path re-activates. Skipped while CarPlay owns the
    /// session.
    private func deactivatePlaybackSessionIfNeeded() {
        guard !CarPlayRecordingService.anySessionActive else { return }
        try? ChatPlaybackSession.deactivate()
    }

    // MARK: - iOS system-interruption reconciliation

    /// One observer PER speaker instance (iPad split view / push-pop each own
    /// one): every handler guards on ITS OWN state, so only the actively
    /// speaking instance transitions; idle speakers no-op.
    /// `nonisolated(unsafe)`: written ONCE in `init`, read ONCE in the
    /// nonisolated `deinit` (a MainActor-isolated property can't be referenced
    /// there) — no concurrent access exists between those two points.
    /// `@ObservationIgnored` keeps it plain untracked storage (never UI state),
    /// so the deinit read is unambiguously a direct field access, not a
    /// registrar-tracked getter.
    @ObservationIgnored
    private nonisolated(unsafe) var interruptionObserver: (any NSObjectProtocol)?

    private func setupInterruptionObserver() {
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            // Parse to the scalar FIRST (Notification is not Sendable), then run
            // the handler INLINE — `queue: .main` guarantees the main thread, so
            // `assumeIsolated` holds. A deferred `Task { @MainActor }` hop would
            // open a runloop gap in which a bubble tap can supersede to a FRESH
            // turn that the stale `.began` would then wrongly pause/reset. (An
            // OS-post → main-queue-delivery gap remains and is unclosable — the
            // notification carries no turn identity to guard against.)
            guard let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            MainActor.assumeIsolated {
                self?.handleAudioInterruption(type)
            }
        }
    }

    /// Reconcile with a SYSTEM audio interruption (phone call / Siri / alarm /
    /// timer): the system pauses our audio and deactivates the session with NO
    /// terminal callback (`AVAudioPlayer` fires `didFinish` only on natural
    /// end; the synth auto-pauses without `didFinish`/`didCancel`), so `state`
    /// would otherwise stick at `.playing` over dead audio and the ducked
    /// session claim would never be reconciled. The iOS-chat analog of the
    /// Watch dim-cut hooks above. Internal so tests drive it directly (the
    /// reconcile-hooks precedent). Deliberately NOT gated on
    /// `CarPlayRecordingService.anySessionActive`: a phone-side reply riding
    /// CarPlay's session must still flip truthfully on a real interruption, and
    /// session safety needs no gate here — the only session call in any arm
    /// (`silentReset`'s deactivate) carries the CarPlay guard itself.
    func handleAudioInterruption(_ type: AVAudioSession.InterruptionType) {
        switch type {
        case .began:
            switch state {
            case .playing:
                // Mirror the user-pause branch (position preserved, the turn's
                // terminal stays pending, one tap resumes) — minus the
                // VoiceOver announce (the interruption IS the announcement)
                // and minus the session release (already system-deactivated).
                // `engine.pause()` on system-paused audio is harmless
                // (`AVAudioPlayer.pause` is idempotent; `pauseSpeaking` on a
                // paused synth returns false, ignored) and PARKS a chunk queue
                // so a landing fetch can't start audio — or Apple-fallback —
                // into the dead session.
                clearSystemPauseMark()
                state = .paused
                engine.pause()
            case .loading:
                // The in-flight fetch would land into an interrupted session;
                // a chunked turn could then Apple-fallback and speak unprompted
                // after the call ends. Reset silently — NOT `stop()`, which
                // announces "Stopped" over the incoming call.
                silentReset()
            case .paused, .idle:
                break
            }
        case .ended:
            // NEVER auto-resume — `.shouldResume` is deliberately ignored (a
            // reply resuming mid-sentence after a long call is a jump-scare,
            // not a podcast; mirrors CarPlay + the Watch's cardinal rule). The
            // user re-taps; the resume branch re-activates the session.
            break
        @unknown default:
            break
        }
    }
    #endif
}

#if os(macOS)
extension ThreadSpeaker: SpeechExclusivityParty {
    /// Preempted by another macOS party (a different speaker starting, or the
    /// mic). No-op when IDLE — every claim broadcasts to all registered
    /// speakers, and an idle one has nothing to stop; without the guard each
    /// mic start / bubble tap / arrival speak would make every idle speaker
    /// announce a spurious "Stopped" to VoiceOver. When active, full `stop()`
    /// — resets the bubble's speak state and announces (the utterance
    /// genuinely stopped).
    func stopForSpeechExclusivity() {
        guard speakingMessageID != nil else { return }
        stop()
    }
}
#endif
