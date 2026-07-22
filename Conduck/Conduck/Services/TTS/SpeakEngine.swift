// Conduck
// SpeakEngine.swift
//
// The CROSS-PLATFORM speak abstraction that unifies the per-message "Read aloud"
// state machine across iPhone / iPad / Mac AND Apple Watch. Foundation-only and
// watch-safe (NO `#if os` guard — this file compiles into BOTH the iOS/macOS
// `Conduck` target and the `ConduckWatch Watch App` target).
//
// `ThreadSpeaker` (the shared `@Observable` UI state machine — idle → loading →
// playing → paused) drives the footer/inline Speak control off `SpeakState`, and
// talks to whatever speak ENGINE is injected:
//   - iOS / macOS → `ReplyVoice` (cloud-TTS orchestration + Apple fallback).
//   - watchOS     → `WatchReplySpeaker` (the wrist's local cloud-or-Apple player).
// Both conform to `SpeakEngine`, so the state machine + control are implemented
// ONCE, not per surface.
//
// `SpeakState` + `SpeechActivity` live here (lifted out of `ThreadSpeaker` and
// `ReplyVoice` respectively) so the watch engine + the shared state machine can
// reference them without importing an iOS-only file.

import Foundation

// MARK: - Speak phase (shared UI state)

/// Per-message speak lifecycle the Speak control is state-driven off:
/// `.loading` covers the cloud-TTS fetch (1–3s); `.playing` once audio actually
/// begins (cloud or Apple); `.paused` after a tap pauses it — the audio is kept
/// in place, so a subsequent tap RESUMES from position with no re-synthesis.
/// `.idle` whenever nothing is speaking. Was nested in `ThreadSpeaker`; lifted
/// to top-level so the shared state machine + the watch view both reference it.
enum SpeakState: Equatable { case idle, loading, playing, paused }

// MARK: - Engine playback truth-snapshot (Watch dim-cut reconciliation)

/// A cheap read of the ENGINE's real playback state, used by `ThreadSpeaker` to
/// reconcile its UI state after watchOS silently suspends built-in-speaker audio
/// on the always-on ambient dim (which fires NO terminal delegate, so the state
/// machine would otherwise stay stuck in `.playing`). Distinct from `SpeakState`
/// (the UI phase): this is what the audio engine is ACTUALLY doing right now.
/// - `active`: audio is genuinely playing.
/// - `pausedResumable`: playback is paused with position preserved — a
///   `resume()` continues it (the OS-pause-on-dim case; user-confirmed the
///   `AVAudioPlayer` is only paused, not torn down).
/// - `inactive`: nothing playing and nothing to resume (idle, finished, or
///   torn down).
/// Only meaningfully overridden by `WatchReplySpeaker`; the protocol default is
/// `.active` (a no-op for the reconcile, which only the watch view invokes).
enum PlaybackStatus { case active, pausedResumable, inactive }

// MARK: - Speak progress signal (chat-only, additive)

/// A NON-LATCHED progress signal for the CHAT speak path's UI (idle → loading →
/// playing). PURELY ADDITIVE and isolated from the exactly-once `completion`
/// contract: it never funnels through the one-shot latch, and the
/// `previewSample` path never emits it (it passes nil). CarPlay pattern-matches
/// `.startedPlaying` only. Lifted verbatim out of `ReplyVoice` so the watch
/// engine + the shared state machine share it.
enum SpeechActivity {
    /// Playback has actually begun (cloud `AVAudioPlayer.play()` returned true,
    /// or Apple's synth posted `didStart`). UI transitions loading → playing.
    case startedPlaying
    /// The APPLE FALLBACK leg's audio has actually begun for a turn whose
    /// intended engine was a cloud voice (fallback transparency): emitted at the
    /// fallback leg's real audio start — never merely when a fallback is
    /// DECIDED (an Apple leg that never starts settles as gave-up instead).
    /// When the fallback is also the turn's first audio, `.startedPlaying` is
    /// emitted first, so `.startedPlaying`-only consumers (CarPlay's
    /// Thinking → Replying flip) are unaffected. `ThreadSpeaker` maps this to
    /// the per-message "used built-in voice" marker. An INTENDED Apple turn
    /// (`apple-tts` active) never emits it.
    case fallbackStarted
}

// MARK: - Cloud playback outcome (typed player terminal)

/// The typed terminal of one CLOUD clip playback (`SpeechPlayer.playCloud` on
/// iOS/macOS; the Watch's local player handles its terminals inline). The
/// ORCHESTRATOR (`ReplyVoice`), not the player, decides what a failure means:
/// chat → Apple fallback; preview → loud `.failure`. Watch-safe + Foundation-
/// only so `TTSFallbackReason` below can carry the stage on both targets.
enum CloudPlaybackOutcome: Equatable, Sendable {
    /// The clip played to its natural end (`didFinish(successfully: true)`).
    case finished
    case failed(CloudPlaybackFailureStage)
}

/// Where a cloud clip's playback failed. Distinct stages because the ring
/// breadcrumb + tests distinguish "bytes were undecodable" (a provider/content
/// problem) from "the session refused to start" from "playback died mid-clip".
enum CloudPlaybackFailureStage: Equatable, Sendable {
    /// `AVAudioPlayer(data:)` threw — the fetched bytes are not decodable audio.
    case undecodable
    /// `play()` returned false — playback could not start (session not ready).
    case startRefused
    /// `didFinish(successfully: false)` or a mid-clip decode error — playback
    /// began but died before the natural end. The turn's text is re-spoken
    /// WHOLE by the Apple fallback (content preservation over de-duplication;
    /// audio-time → text mapping is unreliable, so no truncation is attempted).
    case playbackFailed
}

// MARK: - Fallback reason (transparency breadcrumb)

/// WHY a spoken turn's cloud leg handed off to the Apple on-device voice — the
/// typed, privacy-safe token that flows into the `.fallbackStarted` marker, the
/// device-local TTS outcome ring (iOS/macOS), and `WatchLog` (wrist). Never
/// carries text, keys, URLs, or provider payloads; the fetch arm carries only
/// the numeric `AppError.errorCode`.
enum TTSFallbackReason: Equatable, Sendable {
    /// A cloud provider is selected but no key is available on THIS device.
    case missingKey
    /// The key exists but the Keychain could not return it (locked/failed read).
    case keyUnreadable
    /// The synthesis fetch threw (`AppError.errorCode` — auth / rate limit /
    /// unreachable / bad voice / empty audio).
    case fetchFailed(errorCode: Int)
    /// Fetched audio could not be played (see `CloudPlaybackFailureStage`).
    case unplayableAudio(CloudPlaybackFailureStage)
    /// A chunked turn's chunk was unplayable — Apple speaks the remainder.
    case chunkFailed
    /// The first-audio watchdog expired (hung synth/pipeline, nothing audible).
    case stallTimeout
}

// MARK: - SpeakEngine

/// The speak ENGINE seam the shared `ThreadSpeaker` state machine drives. Both
/// `ReplyVoice` (iOS / macOS) and `WatchReplySpeaker` (watchOS) conform, so the
/// per-message control + its idle→loading→playing→paused machine are unified
/// across every surface rather than duplicated per platform.
///
/// Signatures match `ReplyVoice.speak` EXACTLY (`@MainActor @Sendable` closures,
/// `sanitize` always passed by the state machine). `onStateChange` is the
/// additive `.startedPlaying` progress signal; `completion` is the exactly-once
/// terminal. `pause()` / `resume()` preserve position (no re-synthesis);
/// `cancel()` is a hard stop that does NOT fire the pending completion.
@MainActor
protocol SpeakEngine {
    func speak(
        _ text: String,
        sanitize: Bool,
        onStateChange: (@MainActor @Sendable (SpeechActivity) -> Void)?,
        completion: @escaping @MainActor @Sendable () -> Void
    )
    func pause()
    func resume()
    func cancel()

    /// The engine's REAL playback state right now (see `PlaybackStatus`). Read by
    /// `ThreadSpeaker.reconcileSystemPauseIfNeeded()` to recover from a silent
    /// watchOS suspension. The default is `.active` so `ReplyVoice` (iOS/macOS)
    /// needs no change — reconcile is only ever called from the watch view, where
    /// `WatchReplySpeaker` provides the real answer.
    var playbackStatus: PlaybackStatus { get }
}

extension SpeakEngine {
    var playbackStatus: PlaybackStatus { .active }
}

// MARK: - Watch auto-speak (pure decision types)

/// Where a Watch capture turn ENTERED the pipeline. Latched by
/// `WatchRecordingService` at each entry point and read exactly once by
/// `handleBackgroundReply` to compute the auto-speak verdict when the reply
/// lands. Lives in this SHARED Foundation-only file (not in the watch target)
/// so `ConduckTests` — which compiles against the iOS/macOS target — can
/// unit-test the verdict without referencing watch-target code.
enum WatchCaptureSource {
    /// Headless trigger — the ControlWidget / Action-Button intent, including
    /// the quick-lane `.existing` continuation it resolves at trigger time
    /// (`startCapture(boundTo: .existing)`), plus the defensive unbound
    /// `startRecording()` entry.
    case headless
    /// In-app "Ask" — the launchpad's always-new draft-shell capture
    /// (`startCapture(boundTo: .new)`).
    case ask
    /// In-thread composer VOICE send (`startRecording(boundTo:)`). Auto-speaks
    /// on the Watch — the wrist is a glance/hands-free surface, so in-thread
    /// VOICE follow-ups speak (a Watch carve-out to the cross-surface "in-chat
    /// composer send never auto-speaks" rule; see `WatchAutoSpeakVerdict`).
    case composer
    /// In-thread composer TYPED send (`sendTypedText(_:into:)`). Never
    /// auto-speaks — "voice speaks, text doesn't" (you're reading the screen you
    /// just typed a question into).
    case composerText
}

/// Pure decider for "auto-speak this reply on arrival?" — the Watch's
/// Read-replies-aloud feature. Operates on plain values only (no WatchKit, no
/// singletons), so the matrix is unit-testable from `ConduckTests`
/// (`WatchAutoSpeakVerdictTests`); `WatchRecordingService.handleBackgroundReply`
/// supplies the live inputs.
enum WatchAutoSpeakVerdict {
    /// Decides whether a landed reply is ELIGIBLE to auto-speak — i.e. whether
    /// `handleBackgroundReply` should STAGE the one-shot speak. It deliberately
    /// does NOT gate on app-active: staging happens the moment the reply lands
    /// (even wrist-down), and the SEPARATE "safe to play now" gate (scene
    /// `.active`) lives at the play site (`WatchConversationThreadView.attempt-
    /// AutoSpeak`), which re-fires on the wrist-raise (scenePhase → `.active`).
    /// So a reply that arrived while the wrist was down still speaks when the
    /// user raises their wrist to look — within the mailbox's freshness window
    /// (a much-later reply stays a tappable notification, never an unprompted
    /// jump-scare).
    ///
    /// True iff EVERY term holds:
    /// - `source` is a VOICE turn — `.headless` / `.ask` / `.composer` (in-thread
    ///   mic). TYPED sends (`.composerText`) never auto-speak, and a nil source
    ///   (no latched turn — e.g. a deferred-relay drain) stays silent. **Watch
    ///   carve-out** to the cross-surface "in-chat composer send never
    ///   auto-speaks" rule: the wrist is a glance/hands-free surface, so VOICE
    ///   follow-ups speak too; only TYPED stays silent → "voice speaks, text
    ///   doesn't".
    /// - `replyConversationID == inFlightConversationID`. Why: `handleBackground-
    ///   Reply` can receive a resurrected OLD background task's reply for a
    ///   DIFFERENT conversation (the same aliasing `handleBackgroundFailure`
    ///   defends against) — a mismatched reply must stay silent rather than
    ///   speak a stale answer over the turn the user is actually waiting on.
    ///   A nil in-flight id can't disambiguate → silent.
    /// - `toggleOn` — the iPhone-couriered Read-replies-aloud flag
    ///   (`WatchSettingsReader.readRepliesAloud()`, default OFF).
    static func shouldAutoSpeak(
        source: WatchCaptureSource?,
        replyConversationID: UUID,
        inFlightConversationID: UUID?,
        toggleOn: Bool
    ) -> Bool {
        guard toggleOn else { return false }
        switch source {
        case .headless, .ask, .composer:
            break
        case .composerText, .none:
            return false
        }
        guard let inFlight = inFlightConversationID,
              inFlight == replyConversationID else { return false }
        return true
    }
}

// MARK: - Auto-speak one-shot mailbox (read-aloud, shared iOS + Watch)

/// The ONE cross-platform one-shot mailbox between an auto-speak TRIGGER and
/// the thread view that executes the speak. Shared by both targets (this file
/// compiles into the `Conduck` app AND the watch app) so the semantics can't
/// drift per platform — replaces two near-identical per-target coordinators.
///
/// Writers per platform:
/// - iOS: `NotificationDelegate.didReceive` stages a request on a reply-
///   notification tap (gated by `ReplyAutoSpeakDecider`).
/// - macOS: `MenuBarCoordinator`'s `replySpeaker` router stages a quick-lane
///   ARRIVAL when the popover is OPEN on the reply's thread (consumed by
///   `DictationPopoverView.attemptAutoSpeak`, so the speak runs on the
///   popover's own ThreadSpeaker — visible state, pause, close teardown).
///   macOS deep-links/notification taps still never stage — that invariant
///   is unchanged; a popover CLOSE clears any unconsumed request.
/// - watchOS: `WatchRecordingService.handleBackgroundReply` (arrival, gated by
///   `WatchAutoSpeakVerdict`) and `WatchNoteView.drainDeepLinkIfNeeded`
///   (notification tap). The two watch writers are mutually exclusive BY
///   CONSTRUCTION: arrival requires `.active`, where `willPresent` returns
///   `[]` — so no banner exists to tap.
///
/// Why a mailbox (not speaking at the trigger site): the trigger fires where
/// no view is guaranteed mounted (nonisolated notification delegate on a cold
/// launch; a wrist service with no view access), but the speak MUST route
/// through the mounted thread's own `ThreadSpeaker` so the bubble shows the
/// playing state, pause/resume works, and the thread keeps a single audio
/// owner. The observable one-shot bridges that mount-ordering gap.
///
/// Why the freshness window: cold-launch navigation can be lost (the deep-link
/// post lands on no host, the user backs out, the app reopens by hand much
/// later). Without a bound, the stale flag would auto-speak whenever the user
/// NEXT opens that thread. `consume` honors a request only strictly within
/// `freshness` seconds and clears an expired one on ANY consume attempt. The
/// window is per-platform (`Self.shared`): 15 s on the wrist (navigation is
/// immediate; anything older is stale), 60 s on iOS (cold launch + store
/// fetch can be slow).
@MainActor
@Observable
final class AutoSpeakMailbox {
    #if os(watchOS)
    static let shared = AutoSpeakMailbox(freshness: 15)
    #else
    static let shared = AutoSpeakMailbox(freshness: 60)
    #endif

    /// One staged auto-speak request. `Equatable` deliberately — thread views
    /// hang `.onChange(of: pending)` off it to catch a request set AFTER their
    /// load/refresh hooks already ran (e.g. a reply tap while the target
    /// thread is ALREADY open: no remount → no `.onAppear`, and the reply is
    /// already persisted → no message-count change).
    struct Request: Equatable {
        let conversationID: UUID
        let requestedAt: Date
        /// The exact reply the producer already holds (watch arrival path).
        /// Carried so the speak doesn't re-derive from the thread view's
        /// `threadMessages`, which on a FOLLOW-UP turn still holds the PRIOR
        /// reply at arm time (the new bubble lands via an async, coalesced
        /// store refresh). `nil` on the notification-tap paths (iOS/macOS +
        /// watch), where the thread is fully loaded before the speak → those
        /// keep falling back to the latest agent bubble. See `AutoSpeakSelection`.
        /// `var` (not `let`) so the synthesized memberwise init carries them as
        /// defaulted params — `let`-with-default is omitted from that init.
        var messageID: UUID? = nil
        var text: String? = nil
    }

    /// The pending one-shot, or nil. Set by `request(_:)`; cleared by
    /// `consume(matching:)` / `clear()` / freshness expiry.
    private(set) var pending: Request?

    private let freshness: TimeInterval
    private let now: () -> Date

    /// `now` is an injectable clock so tests drive the freshness window
    /// deterministically; production uses the real clock.
    init(freshness: TimeInterval, now: @escaping () -> Date = { Date() }) {
        self.freshness = freshness
        self.now = now
    }

    /// Stage a speak request for `conversationID`. Latest-wins: a second
    /// request before the first drains simply overwrites it — only one thread
    /// can be the speak target at a time.
    func request(_ conversationID: UUID) {
        pending = Request(conversationID: conversationID, requestedAt: now())
    }

    /// Stage a speak request that CARRIES the exact reply (watch arrival path).
    /// Same latest-wins semantics as `request(_:)`; the payload lets the thread
    /// view speak THIS reply instead of guessing the latest agent bubble from a
    /// not-yet-refreshed array. See `AutoSpeakSelection.resolve`.
    func request(_ conversationID: UUID, messageID: UUID, text: String) {
        pending = Request(
            conversationID: conversationID,
            requestedAt: now(),
            messageID: messageID,
            text: text
        )
    }

    /// Atomic check-and-clear used by a thread view when its messages are
    /// ready. Returns true — and clears the request — ONLY on a conversation
    /// match strictly within the freshness window. An EXPIRED request is
    /// cleared on ANY consume attempt (whichever thread is asking, the stale
    /// flag must die here rather than ambush a later open); a FRESH request
    /// for a DIFFERENT conversation is left pending (this host isn't its
    /// target — the deep-link navigation may still be bringing the right
    /// thread up, e.g. an iPad split view's other pane).
    func consume(matching conversationID: UUID) -> Bool {
        guard let current = pending else { return false }
        guard now().timeIntervalSince(current.requestedAt) < freshness else {
            pending = nil
            return false
        }
        guard current.conversationID == conversationID else { return false }
        pending = nil
        return true
    }

    /// Drop any unconsumed request without speaking. Called when a NEW capture
    /// starts on either platform — the mic must never come up with a pending
    /// speak waiting to fire under it.
    func clear() {
        pending = nil
    }
}

/// Pure picker for "which message should auto-speak fire on?" — extracted from
/// the watch thread view so the stale-array race is unit-testable headless
/// (`AutoSpeakSelectionTests`); `attemptAutoSpeak` is the thin wrapper.
///
/// When the staged request carries a payload (a watch reply-arrival), that reply
/// WINS — it is the exact one the producer just appended, so the speak no longer
/// guesses from `threadMessages`, which on a follow-up turn still holds the
/// PREVIOUS reply at arm time (the new bubble lands via an async, coalesced
/// refresh). Otherwise (a notification-tap open, where the thread is fully
/// loaded first) it falls back to `arrayLatest`, the latest agent bubble.
/// Returns `nil` when nothing is speakable yet — the caller must then SKIP the
/// destructive `consume` so the one-shot survives until a real reply exists.
enum AutoSpeakSelection {
    static func resolve(
        staged: AutoSpeakMailbox.Request?,
        arrayLatest: (id: UUID, text: String)?
    ) -> (id: UUID, text: String)? {
        if let staged, let id = staged.messageID, let text = staged.text, !text.isEmpty {
            return (id: id, text: text)
        }
        if let arrayLatest, !arrayLatest.text.isEmpty {
            return arrayLatest
        }
        return nil
    }
}
