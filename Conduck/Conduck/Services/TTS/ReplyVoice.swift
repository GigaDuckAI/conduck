// SPDX-License-Identifier: Apache-2.0

// Conduck
// ReplyVoice.swift
//
// Cloud Text-to-Speech orchestration boundary (iOS / macOS — NOT the Watch
// target). The SINGLE place where "speak this reply" resolves the active TTS
// engine, fetches cloud audio (or skips to Apple), plays it, and — on ANY
// failure — falls back to Apple's on-device voice. Every speak surface that
// can reach a cloud voice (CarPlay, the iOS tap-to-speak bubble) routes through
// here, so the exactly-once-completion contract + the cloud→Apple fallback tree
// are implemented + tested in ONE place rather than four.
//
// THE THREE-PART VOICE INVARIANT this boundary realizes:
//   - SPEECH CONTINUITY: a chat turn's spoken reply always finishes — Apple
//     substitutes on any cloud failure (missing/unreadable key, fetch throw,
//     unplayable audio, chunk failure, stall). CarPlay hands-free depends on it.
//   - FALLBACK TRANSPARENCY: every substitution leaves a trace — the
//     `.fallbackStarted` activity (per-message marker) + a device-local
//     `TTSOutcomeLog` ring event, both privacy-safe. "Silent" fallback means no
//     AUDIBLE interruption, never an unrecorded one. That includes the user's
//     PICKED Apple voice (`AppleVoice.swift`) failing to start: the system
//     default voice re-speaks the reply, and the substitution is marked the
//     same way.
//   - VALIDATION HONESTY: `previewSample` NEVER substitutes — a cloud failure
//     (fetch OR playback) reports `.failure` and plays nothing.
//
// CONTRACT (cross-agent — the Settings half codes against `previewSample`):
//   - `speak(_:sanitize:completion:)` — speak an agent reply via the ACTIVE TTS
//     provider; completion fires EXACTLY ONCE on every path, TYPED with how the
//     turn settled (`SpeakTerminal`: `.finished` = the complete reply was
//     delivered; `.incomplete` = the turn settled without full audio — watchdog
//     gave up, system cancelled the synth, empty text). The exactly-once
//     completion is load-bearing for CarPlay deactivate-once, and the terminal
//     value is load-bearing for CarPlay's heard-marker (only `.finished` may
//     mark a conversation read). CarPlay routes through `speak`, never
//     `previewSample`.
//   - `previewSample(providerID:voice:apiKey:completion:)` — speak a sample via
//     an EXPLICIT provider (Settings "Speak a sample"). DIVERGES from `speak`:
//     completion is `(Result<Void, AppError>) -> Void` and the preview does NOT
//     fall back to Apple on a cloud failure — a fetch throw fires
//     `.failure(error)`; fetched-but-UNPLAYABLE audio fires
//     `.failure(.ttsSynthesisFailed)` (the typed player outcome closes the old
//     false-green where bytes that wouldn't decode still reported success).
//     The Apple-sentinel / no-key case still plays Apple and reports `.success`
//     (a legit "this provider uses Apple" preview; the Settings VM preflights
//     the missing-key case loudly BEFORE calling here); cloud SUCCESS plays the
//     cloud audio and reports `.success`. Still EXACTLY ONCE on every path.
//   - `cancel()` — stop any in-flight playback without firing the completion.
//   - `ReplyVoice.shared` — the instance the Settings half calls from
//     `SettingsViewModel`.
//
// EXACTLY-ONCE + SETTLEMENT GUARANTEE:
//   The completion is wrapped in a one-shot latch (`makeOneShot`) at the top of
//   every public entry point (at-most-once), and the APPLE INACTIVITY WATCHDOG
//   below upgrades that to eventual settlement: every Apple leg (intended or
//   fallback) is bounded by an inactivity deadline that re-arms on every synth
//   progress tick (didStart + word ranges) — a synth that is genuinely speaking
//   is never cut off; one that silently produces nothing is stopped and the
//   turn's latch FIRED (`gaveUp`), so CarPlay can never hang on a dead Apple
//   leg. The FIRST-AUDIO watchdog (cloud phase) is disarmed the moment any
//   Apple leg begins — the two watchdogs are never armed simultaneously, so
//   they cannot race into a double handoff.
//
// AUDIO SESSION: `ReplyVoice` never touches the session — `SpeechPlayer` plays
// on the caller's held session (CarPlay deactivate-once safe; see SpeechPlayer).

#if !os(watchOS)
import Foundation

// `SpeechActivity` lives in the shared, watch-safe `SpeakEngine.swift` (it's
// referenced by the cross-platform `ThreadSpeaker` state machine + the watch
// engine), so it is not declared here.

// MARK: - Injectable seams (for ReplyVoiceFallbackTests)

/// The cloud-fetch seam. Production conformer wraps `TTSClient.synthesize`; the
/// test substitutes a fake that returns bytes or throws, with no network. NOT
/// `Sendable` — the conformer is stored on the `@MainActor ReplyVoice` and only
/// ever called from the main actor (the args it forwards are themselves
/// Sendable, so the hop into the `TTSClient` actor is safe).
protocol TTSFetching {
    func synthesize(text: String, provider: TTSProvider, voice: String?, customModel: String?, apiKey: String, customConfig: CustomTTSConfig?) async throws -> Data
}

/// The playback seam. Production conformer is `SpeechPlayer`; the test
/// substitutes a fake that records which path ran + invokes the done-handler
/// synchronously, with no audio hardware.
@MainActor
protocol SpeechPlaying: AnyObject {
    /// `onStart` (P3, additive, NON-LATCHED) fires when playback actually
    /// begins — OUTSIDE the exactly-once `onDone` funnel. `onDone` carries the
    /// TYPED outcome; the ORCHESTRATOR decides what a failure means (chat →
    /// Apple fallback; preview → loud `.failure`).
    func playCloud(
        _ data: Data,
        onStart: (@MainActor @Sendable () -> Void)?,
        onDone: @escaping @MainActor @Sendable (CloudPlaybackOutcome) -> Void
    )
    /// `onDone` is TYPED (`SpeakTerminal`): `.finished` only on the synth's
    /// natural end; `.incomplete` on a system-driven `didCancel` — a
    /// caller-initiated `stop()` fires nothing. CarPlay's heard-marker
    /// depends on the distinction.
    func playApple(
        _ text: String,
        onStart: (@MainActor @Sendable () -> Void)?,
        onDone: @escaping @MainActor @Sendable (SpeakTerminal) -> Void
    )
    /// Language- and progress-aware variant — `language` is a BCP-47
    /// content-language hint for the reply (nil → device language);
    /// `onProgress` is the REPEATED Apple synth activity tick (didStart + every
    /// word range) the inactivity watchdog re-arms on. A default in the
    /// extension below forwards to the 3-arg version ignoring both, so
    /// existing conformers (the test fakes) need no changes; `SpeechPlayer`
    /// overrides it to honor them.
    func playApple(
        _ text: String,
        language: String?,
        onStart: (@MainActor @Sendable () -> Void)?,
        onProgress: (@MainActor @Sendable () -> Void)?,
        onDone: @escaping @MainActor @Sendable (SpeakTerminal) -> Void
    )
    /// Voice-aware variant — `voiceIdentifier` is the user's picked Apple
    /// voice (nil → the language default). The extension default below drops
    /// it and forwards to the language/progress variant, so fakes that don't
    /// care need no changes; `SpeechPlayer` overrides it to honor it.
    ///
    /// PROGRESS CONTRACT the picked-voice guard relies on: `onStart` fires with
    /// the synth's `didStart`, and that same event delivers exactly ONE
    /// `onProgress` tick right after it; every later tick is a spoken word
    /// boundary. `didStart` alone does not prove a voice is audible — a word
    /// boundary is the evidence `ReplyVoice` accepts.
    func playApple(
        _ text: String,
        language: String?,
        voiceIdentifier: String?,
        onStart: (@MainActor @Sendable () -> Void)?,
        onProgress: (@MainActor @Sendable () -> Void)?,
        onDone: @escaping @MainActor @Sendable (SpeakTerminal) -> Void
    )
    func stop()
    /// Pause in-flight playback preserving position (chat play/pause/resume) —
    /// does NOT fire the done-handler or tear down the player. No-op if idle.
    func pause()
    /// Resume playback paused by `pause()` from its position (no re-synthesis).
    func resume()
}

extension SpeechPlaying {
    /// Convenience overloads preserving the original 2-arg call sites
    /// (`previewSample`, CarPlay, tests) — forward with `onStart: nil`.
    func playCloud(_ data: Data, onDone: @escaping @MainActor @Sendable (CloudPlaybackOutcome) -> Void) {
        playCloud(data, onStart: nil, onDone: onDone)
    }
    func playApple(_ text: String, onDone: @escaping @MainActor @Sendable (SpeakTerminal) -> Void) {
        playApple(text, onStart: nil, onDone: onDone)
    }
    /// Default for the language/progress-aware requirement: ignore both hints
    /// and forward to the 3-arg path. Only `SpeechPlayer` overrides this to
    /// actually honor them; the test fakes inherit this default unchanged.
    func playApple(
        _ text: String,
        language _: String?,
        onStart: (@MainActor @Sendable () -> Void)?,
        onProgress _: (@MainActor @Sendable () -> Void)?,
        onDone: @escaping @MainActor @Sendable (SpeakTerminal) -> Void
    ) {
        playApple(text, onStart: onStart, onDone: onDone)
    }
    /// Default for the voice-aware requirement: drop the identifier and
    /// forward to the language/progress variant.
    func playApple(
        _ text: String,
        language: String?,
        voiceIdentifier _: String?,
        onStart: (@MainActor @Sendable () -> Void)?,
        onProgress: (@MainActor @Sendable () -> Void)?,
        onDone: @escaping @MainActor @Sendable (SpeakTerminal) -> Void
    ) {
        playApple(text, language: language, onStart: onStart, onProgress: onProgress, onDone: onDone)
    }
}

/// Production fetch seam — forwards to the `TTSClient` actor.
struct LiveTTSFetcher: TTSFetching {
    func synthesize(text: String, provider: TTSProvider, voice: String?, customModel: String?, apiKey: String, customConfig: CustomTTSConfig?) async throws -> Data {
        try await TTSClient.shared.synthesize(text: text, provider: provider, voice: voice, customModel: customModel, apiKey: apiKey, customConfig: customConfig)
    }
}

extension SpeechPlayer: SpeechPlaying { }

/// The active-TTS snapshot resolver seam. Production reads
/// `SettingsManager.activeTTSSnapshot()`; the test injects a fixed snapshot so
/// no actor / Keychain is touched. NOT `Sendable` (same rationale as
/// `TTSFetching`).
protocol TTSSnapshotResolving {
    func activeTTSSnapshot() async -> TTSSnapshot
    /// Record that `pick` did not start speaking, so later turns go straight
    /// to the system default voice and Settings can say why. The extension
    /// default is a no-op, so fakes that don't exercise a pick need nothing.
    func markAppleVoiceUnavailable(_ pick: AppleVoicePick)
}

extension TTSSnapshotResolving {
    func markAppleVoiceUnavailable(_ pick: AppleVoicePick) { }
}

/// Production snapshot seam — one actor hop into `SettingsManager`, plus the
/// device-local Apple voice pick, which lives outside the synced settings the
/// actor owns.
struct LiveTTSSnapshotResolver: TTSSnapshotResolving {
    func activeTTSSnapshot() async -> TTSSnapshot {
        var snapshot = await SettingsManager.shared.activeTTSSnapshot()
        snapshot.appleVoice = AppleVoicePreferences.currentPick()
        return snapshot
    }

    func markAppleVoiceUnavailable(_ pick: AppleVoicePick) {
        AppleVoicePreferences.markUnavailable(pick.identifier, forLocale: pick.locale)
    }
}

// MARK: - ReplyVoice

/// Orchestrates a spoken reply: resolve the active TTS engine → fetch cloud
/// audio (or skip to Apple) → play → fall back to Apple on ANY failure, firing
/// the completion exactly once on every path.
@MainActor
final class ReplyVoice: SpeakEngine {

    /// Shared instance the Settings half calls for the "Speak a sample"
    /// preview. Production seams. Each speak surface that needs its own player
    /// (CarPlay) may construct its own instance instead.
    ///
    /// On macOS the SHARED instance (and ONLY the shared instance) self-
    /// registers on the speech-exclusivity bus when first built — it is the
    /// always-alive engine behind the quick-lane arrival speak + the Settings
    /// sample preview, so a starting mic capture or a manual bubble speak must
    /// be able to silence it. Per-view `ThreadSpeaker` engines stay
    /// unregistered (their STATE MACHINE is the party — see ThreadSpeaker),
    /// and CarPlay's own instance must never be preemptible.
    static let shared: ReplyVoice = {
        let voice = ReplyVoice()
        #if os(macOS)
        SpeechExclusivity.shared.register(voice)
        #endif
        return voice
    }()

    private let fetcher: TTSFetching
    private let player: SpeechPlaying
    private let snapshot: TTSSnapshotResolving

    /// Which speak surface this instance serves — stamped into every ring
    /// event. The object cannot infer it reliably (the shared instance serves
    /// chat + macOS arrival; CarPlay builds its own), so it is INJECTED:
    /// default `.chat`; CarPlay passes `.carplay`. Preview/diagnostics events
    /// always record their own surface regardless of this value.
    private let surface: TTSOutcomeEvent.Surface

    /// Device-local outcome ring (fallback transparency). Injectable so tests
    /// write into a throwaway suite, never the real App Group.
    private let outcomeLog: TTSOutcomeLog

    /// Chunking policy for the CHAT `speak` path (see `SpeechSegmenter`).
    /// `.standard` (every production surface, incl. CarPlay's own instance)
    /// splits long replies so the first spoken word arrives after synthesizing
    /// only the head chunk; `.off` forces the whole-blob path (escape hatch —
    /// no production surface passes it). `previewSample` never chunks (fixed
    /// short sample) regardless of policy.
    private let chunkPolicy: SpeechSegmentationPolicy

    /// Per-chunk player factory for the chunked path (seam for tests).
    private let chunkPlayers: ChunkPlayerProviding

    /// The live chunk pipeline for a multi-chunk turn, nil otherwise (single-
    /// blob turns keep using `player` directly). Torn down by `cancel()`, a
    /// superseding `speak`/`previewSample`, and its own terminals.
    private var chunkQueue: SpeechChunkQueue?

    /// The in-flight async work for the current turn (snapshot resolution +
    /// cloud fetch + handoff to the player). Tracked so `cancel()` can abort a
    /// fetch that's still resolving — otherwise a cloud fetch that completes
    /// AFTER `cancel()` would call `player.playCloud`/Apple leg, restarting
    /// playback on a session the caller (CarPlay End / scene teardown) has torn
    /// down and driving a stray re-arm. A new `speak`/`previewSample` cancels
    /// any prior in-flight work first.
    private var inFlight: Task<Void, Never>?

    /// Monotonic turn token. Bumped on every `speak` / `previewSample` /
    /// `cancel`. Watchdog bodies and late player-outcome closures re-check it
    /// before touching the engine, so a superseded turn's deferred work is
    /// inert (belt-and-braces with `Task.isCancelled` + the player's own
    /// identity guards). Ported from `WatchReplySpeaker.generation`.
    private var generation = 0

    /// FIRST-AUDIO WATCHDOG for the chat `speak` path — bounds the CLOUD
    /// phase. A synth request that HANGS (neither returns nor throws) would
    /// otherwise leave the surface silent on a loading state for the whole
    /// transport timeout (CarPlay field bug: a wedged POST froze the session
    /// on "Thinking" indefinitely). Armed per turn in `speak`; disarmed on
    /// first audio, on the turn's terminal, on `cancel()`, on any supersede —
    /// AND the moment ANY Apple leg begins (`startAppleLeg`), so it can never
    /// race the Apple inactivity watchdog into a duplicate handoff. On expiry
    /// it kills the stalled leg WITHOUT firing (cancel semantics) and hands
    /// the WHOLE un-spoken reply to Apple through `startAppleLeg`.
    /// `previewSample` never arms it (the preview contract reports failures
    /// instead of substituting Apple; a hung preview resolves at the transport
    /// timeout).
    private var firstAudioWatchdog: Task<Void, Never>?

    /// Watchdog deadline. Generous on purpose: the head/ramp chunks (≤ ~280
    /// chars ≈ ≤ ~20 s of audio) synthesize well inside it at ≈ real-time
    /// synth speed, and a slow-but-working BYO endpoint must not be cut off
    /// mid-legitimate synth. Injectable for tests.
    private let firstAudioTimeout: Duration

    /// APPLE INACTIVITY WATCHDOG — bounds every APPLE leg (intended or
    /// fallback) as an INACTIVITY deadline, not a total-duration timer: it
    /// re-arms on every synth progress tick (didStart + each word range via
    /// `SpeechPlaying.playApple`'s `onProgress`), so a genuinely speaking
    /// synth of any length is never cut off, while one that silently
    /// produces nothing — including a lost `didFinish` — is stopped and the
    /// turn's latch FIRED (`gaveUp` ring event). This is what upgrades the
    /// at-most-once latch to eventual settlement: CarPlay's completion can
    /// never stay pending on a dead Apple leg. Disarmed on the terminal,
    /// `cancel()`, supersede, and user pause; re-armed on resume.
    private var appleInactivityWatchdog: Task<Void, Never>?

    /// Re-arm closure for the CURRENT Apple leg's inactivity watchdog —
    /// captured at leg start so `resume()` (after a user pause disarmed it)
    /// and the progress ticks re-arm with the same turn/latch. Nil when no
    /// Apple leg is live.
    private var appleInactivityRearm: (@MainActor () -> Void)?

    /// Inactivity deadline between Apple synth progress ticks. Word-boundary
    /// ticks arrive at sub-second cadence while speaking, so 10 s only ever
    /// expires on a genuinely dead leg. Injectable for tests.
    private let appleInactivityTimeout: Duration

    /// PICKED-VOICE START DEADLINE — bounds an Apple leg that speaks in the
    /// user's picked voice (`AppleVoicePick`) until its FIRST WORD BOUNDARY.
    /// A picked Enhanced/Premium voice can be listed yet absent (its assets
    /// removed) and then synthesizes silence; the inactivity watchdog would
    /// only give up on such a leg, while this deadline REPLACES it: stop, mark
    /// the pick unavailable, and speak the same text in the system default
    /// voice (`substitutedPick`). Disarmed on the first word, the turn
    /// terminal, `cancel()`, supersede; suspended by pause and re-armed by
    /// resume. Never armed for a default-voice leg.
    private var pickedVoiceDeadline: Task<Void, Never>?

    /// Re-arm closure for the live picked-voice deadline (pause → resume).
    private var pickedVoiceDeadlineRearm: (@MainActor () -> Void)?

    /// The live preview's OPTIONAL abandonment signal (`previewSample`'s
    /// `onAbandoned`). A preview that is cancelled or superseded never fires
    /// its completion (the same no-completion contract as `speak`), which
    /// would leave a Settings caller awaiting that completion stuck on
    /// "Playing…". This separate signal tells it the sample was dropped.
    /// Cleared when the preview reports; fired and cleared by
    /// `abandonPendingPreview()` on `cancel()` and every supersede.
    private var previewAbandon: (@MainActor () -> Void)?

    /// How long a picked voice may take to reach its first word. Long enough
    /// for a large Premium voice to load its model, short enough that a
    /// silent one is replaced before the listener gives up. Injectable.
    private let pickedVoiceStartTimeout: Duration

    /// - Parameters:
    ///   - fetcher: cloud-fetch seam (default: live `TTSClient`).
    ///   - player: playback seam (default: a fresh `SpeechPlayer`).
    ///   - snapshot: active-TTS resolver (default: live `SettingsManager`).
    ///   - surface: ring-event surface for CHAT-path events (default `.chat`;
    ///     CarPlay's own instance passes `.carplay`).
    ///   - outcomeLog: fallback-transparency ring (default: the shared
    ///     device-local ring; tests inject a throwaway).
    ///   - chunkPolicy: chat-path chunking policy (default `.standard`, which
    ///     every surface incl. CarPlay uses; `.off` = whole-blob escape hatch).
    ///   - chunkPlayers: per-chunk player factory (default: `AVAudioPlayer`-
    ///     backed; tests inject controllable fakes).
    ///   - firstAudioTimeout: first-audio watchdog deadline (default 45 s;
    ///     tests inject a tiny value to exercise the stall handoff).
    ///   - appleInactivityTimeout: Apple-leg inactivity deadline (default 10 s).
    ///   - pickedVoiceStartTimeout: picked-voice first-word deadline
    ///     (default 3 s).
    init(
        fetcher: TTSFetching? = nil,
        player: SpeechPlaying? = nil,
        snapshot: TTSSnapshotResolving? = nil,
        surface: TTSOutcomeEvent.Surface = .chat,
        outcomeLog: TTSOutcomeLog? = nil,
        chunkPolicy: SpeechSegmentationPolicy = .standard,
        chunkPlayers: ChunkPlayerProviding? = nil,
        firstAudioTimeout: Duration = .seconds(45),
        appleInactivityTimeout: Duration = .seconds(10),
        pickedVoiceStartTimeout: Duration = .seconds(3)
    ) {
        // Construct the live seams INSIDE this `@MainActor` init body (not as
        // default-argument expressions) so the call lands in an isolated
        // context — `LiveTTSFetcher`/`LiveTTSSnapshotResolver`/`SpeechPlayer`
        // have main-actor-isolated inits, and a nonisolated default-arg
        // position would warn (→ Swift-6 strict-concurrency error). Mirrors the
        // `player` seam's existing nil-then-construct pattern.
        self.fetcher = fetcher ?? LiveTTSFetcher()
        self.player = player ?? SpeechPlayer()
        self.snapshot = snapshot ?? LiveTTSSnapshotResolver()
        self.surface = surface
        self.outcomeLog = outcomeLog ?? .shared
        self.chunkPolicy = chunkPolicy
        self.chunkPlayers = chunkPlayers ?? AVChunkPlayerFactory()
        self.firstAudioTimeout = firstAudioTimeout
        self.appleInactivityTimeout = appleInactivityTimeout
        self.pickedVoiceStartTimeout = pickedVoiceStartTimeout
    }

    // MARK: - Public API

    /// Speak `text` via the ACTIVE TTS provider. Completion fires EXACTLY ONCE
    /// on every path (cloud success, cloud-fail→Apple, Apple direct, empty
    /// text, pathological all-fail — the inactivity watchdog settles that one).
    ///
    /// - Parameters:
    ///   - text: the agent reply to speak.
    ///   - sanitize: when true, run `ReplySanitizer.spoken(_:)` first (strip
    ///     Markdown/URLs/emoji). The iOS tap path + CarPlay pass `true`. When
    ///     the sanitized text is empty, the completion fires WITHOUT a cloud
    ///     call (the CarPlay caller maps empty→"Done." itself; the iOS tap just
    ///     no-ops audibly).
    ///   - onStateChange: OPTIONAL (default nil), NON-LATCHED progress signal.
    ///     Emits `.startedPlaying` when audio actually begins (chat wires it
    ///     to the per-message speak-state UI; CarPlay flips its voice template
    ///     Thinking → Replying on it) and `.fallbackStarted` when an APPLE
    ///     FALLBACK leg's audio actually begins (the per-message marker).
    ///     PURELY ADDITIVE — it is NOT the completion, never funnels through
    ///     the one-shot latch, and the empty-text / cancel paths never emit it.
    ///   - completion: called exactly once when playback finishes / fails,
    ///     typed with how the turn settled (`.finished` = complete reply
    ///     delivered; `.incomplete` = settled without full audio).
    func speak(
        _ text: String,
        sanitize: Bool,
        onStateChange: (@MainActor @Sendable (SpeechActivity) -> Void)? = nil,
        completion: @escaping @MainActor @Sendable (SpeakTerminal) -> Void
    ) {
        // A new turn supersedes any prior in-flight one — cancel it first so a
        // stale fetch can't resurrect playback after we've moved on. A live
        // chunk queue is torn down HERE (unlike the single-blob player, which
        // `playCloud`'s own `stopInFlight` replaces when the new audio lands):
        // the queue keeps fetching + starting chunks on its own, so leaving it
        // running would overlap the new turn's audio.
        inFlight?.cancel()
        chunkQueue?.cancel()
        chunkQueue = nil
        disarmFirstAudioWatchdog()
        disarmAppleInactivityWatchdog()
        abandonPendingPreview()
        generation += 1
        let turn = generation

        // Disarm both watchdogs whenever the turn terminates through the
        // latch — an Apple leg that completes without ever signalling start
        // must not leave a stale watchdog to re-speak the reply. Only while
        // this turn is still current: a superseded utterance can still finish
        // naturally (a supersede does not stop the player until the new turn
        // reaches audio), and its late terminal must not disarm the NEWER
        // turn's watchdogs.
        let fire = Self.makeOneShot { [weak self] terminal in
            if let self, turn == self.generation {
                self.disarmFirstAudioWatchdog()
                self.disarmAppleInactivityWatchdog()
            }
            completion(terminal)
        }
        let toSpeak = sanitize ? ReplySanitizer.spoken(text) : text

        guard !toSpeak.isEmpty else {
            // Empty after sanitize (e.g. an all-emoji reply). No cloud call,
            // no Apple call — fire the completion so the loop advances. The
            // CarPlay caller substitutes its own "Done." terminal; the iOS tap
            // path simply does nothing audible. No `.startedPlaying` (nothing
            // plays). `.incomplete`: no audio was delivered here.
            inFlight = nil
            fire(.incomplete)
            return
        }

        // Detect the reply's content language ONCE and freeze it for the whole
        // turn. Every Apple leg (direct, cloud-fail, chunk-fallback, watchdog)
        // reuses this one hint, so a fallback on an English-term-heavy tail can
        // never flip the voice mid-reply. nil → device-language voice (Apple's
        // default behavior). Cloud TTS ignores it (providers auto-detect).
        let language = SpeechLanguageDetector.detect(toSpeak)

        // Armed BEFORE the async pipeline so it also covers a hung snapshot
        // hop, not just a hung fetch. First audio / terminal / cancel /
        // Apple-leg entry disarm.
        armFirstAudioWatchdog(text: toSpeak, language: language, turn: turn, onStateChange: onStateChange, fire: fire)

        inFlight = Task { @MainActor in
            let snap = await self.snapshot.activeTTSSnapshot()
            // Cancelled while resolving the snapshot → abandon without firing
            // the completion (cancel() owns the abandon-without-completion
            // contract; see its doc).
            if Task.isCancelled || turn != self.generation { return }
            self.route(text: toSpeak, language: language, snapshot: snap, turn: turn, onStateChange: onStateChange, fire: fire)
        }
    }

    /// Speak a sample via an EXPLICIT provider — the Settings "Speak a sample"
    /// preview. The provider / voice / key come from the row the user is
    /// auditioning, NOT the active snapshot. The sample text is fixed +
    /// non-empty, so there is no sanitize/empty arm.
    ///
    /// DIVERGES from `speak` by design (the preview is auditioning a specific
    /// cloud voice — a silent Apple substitution would hide a misconfigured
    /// voice/key, which is the exact bug this fixes):
    ///   - Apple-sentinel / no-key / empty-key → play Apple, report `.success`
    ///     (a legit "this provider uses Apple" preview; the VM preflights the
    ///     cloud-provider-missing-key case loudly before calling here).
    ///   - cloud SUCCESS (fetched AND played) → report `.success`.
    ///   - cloud fetch THROW → `.failure(error)`, plays nothing.
    ///   - cloud audio UNPLAYABLE (typed player outcome) →
    ///     `.failure(.ttsSynthesisFailed)`, no Apple fallback — the exact
    ///     failure stage is preserved in the outcome ring.
    /// The outcome fires EXACTLY ONCE on every path (the one-shot latch).
    ///
    /// - Parameters:
    ///   - providerID: the `TTSProvider.id` being auditioned.
    ///   - voice: the voice override to preview (nil → the provider default).
    ///   - customModel: the per-provider MODEL override to preview (nil → the
    ///     provider's pinned default model). Never applies to the custom
    ///     endpoint (that uses its `customConfig.model`). Defaulted so
    ///     non-model-aware call sites (tests) stay valid.
    ///   - apiKey: the key for that provider (nil → no cloud; Apple sample).
    ///   - customConfig: the resolved BYO-endpoint config — non-nil ONLY when
    ///     auditioning the custom provider (`custom-openai-tts`). Carries the
    ///     synthesis URL, model, auth scheme, and cert pin. Nil for the others.
    ///   - appleVoice: the device-local Apple voice pick to audition (Apple
    ///     provider only; nil → the language default voice). A pick that does
    ///     not reach its first word reports `.failure(.ttsSynthesisFailed)` —
    ///     the preview never substitutes the default voice for it.
    ///   - recordSurface: ring-event surface (default `.preview`; Diagnostics
    ///     passes `.diagnostics`).
    ///   - completion: called exactly once with the outcome (`.success` on a
    ///     played Apple/cloud sample, `.failure(error)` on a cloud error).
    func previewSample(
        providerID: String,
        voice: String?,
        customModel: String? = nil,
        apiKey: String?,
        customConfig: CustomTTSConfig? = nil,
        appleVoice: AppleVoicePick? = nil,
        recordSurface: TTSOutcomeEvent.Surface = .preview,
        onAbandoned: (@MainActor () -> Void)? = nil,
        completion: @escaping @MainActor @Sendable (Result<Void, AppError>) -> Void
    ) {
        // Supersede any prior in-flight turn (e.g. a previous preview still
        // fetching, or a chunked chat turn still playing) so its late fetch
        // can't resurrect playback / keep speaking under the preview. The
        // superseded chat turn's watchdogs die with it — left armed they would
        // fire mid-preview and Apple-speak the OLD reply over the sample.
        inFlight?.cancel()
        chunkQueue?.cancel()
        chunkQueue = nil
        disarmFirstAudioWatchdog()
        disarmAppleInactivityWatchdog()
        abandonPendingPreview()
        generation += 1
        let turn = generation

        // Reporting settles the preview, so it can no longer be abandoned.
        previewAbandon = onAbandoned
        let report = Self.makeOneShotResult { [weak self] result in
            if let self, turn == self.generation {
                self.previewAbandon = nil
            }
            completion(result)
        }
        // Build the explicit-provider snapshot. Key state derives from the
        // ARGUMENTS (the VM resolved them from the store/buffers): a non-empty
        // key is `.present`; Apple / a keyless custom endpoint need none; an
        // absent key for a cloud provider is `.missing` (the legacy
        // Apple-substitution arm still runs for contract stability — the ring
        // records the honest key state either way).
        let provider = TTSProvider.lookup(id: providerID)
        let keyless = provider.dynamicEndpointKey != nil && customConfig?.auth == STTAuthScheme.none
        let keyState: APIKeyState
        if provider.id == TTSProvider.appleTTS.id || keyless {
            keyState = .notRequired
        } else if apiKey?.isEmpty == false {
            keyState = .present
        } else {
            keyState = .missing
        }
        let snap = TTSSnapshot(
            providerID: providerID,
            apiKey: (apiKey?.isEmpty == false) ? apiKey : nil,
            keyState: keyState,
            voice: voice,
            customModel: customModel,
            customConfig: customConfig,
            appleVoice: providerID == TTSProvider.appleTTS.id ? appleVoice : nil
        )
        routePreview(text: Self.sampleText, snapshot: snap, surface: recordSurface, report: report)
    }

    /// Stop any in-flight playback AND abort the in-flight fetch. Does NOT fire
    /// the pending completion (the caller is abandoning the turn — e.g. CarPlay
    /// End / scene teardown). Cancelling `inFlight` first means a fetch that
    /// resolves after this call sees `Task.isCancelled` and returns before
    /// touching the player, so it cannot restart playback on a torn-down
    /// session. Mirrors `SpeechPlayer.stop` / the CarPlay `cancel` semantics.
    func cancel() {
        inFlight?.cancel()
        inFlight = nil
        chunkQueue?.cancel()
        chunkQueue = nil
        disarmFirstAudioWatchdog()
        disarmAppleInactivityWatchdog()
        abandonPendingPreview()
        generation += 1
        player.stop()
    }

    /// Tell a live preview's caller its sample was dropped (see
    /// `previewAbandon`). Never fires the preview's completion.
    private func abandonPendingPreview() {
        let abandon = previewAbandon
        previewAbandon = nil
        abandon?()
    }

    /// Pause the in-flight spoken reply, PRESERVING position — chat-only (the
    /// per-message Speak control). Unlike `cancel()`, this does NOT abort the
    /// `inFlight` fetch or tear down the player and does NOT fire the completion
    /// (the turn isn't done); a later `resume()` continues from the same point
    /// with no re-synthesis. A no-op if nothing is playing yet. CarPlay /
    /// `previewSample` never call this — they use `cancel()` (a hard stop).
    /// A chunked turn pauses queue-wide (mid-chunk in place; between chunks the
    /// queue parks so a landing fetch can't start audio under the pause); after
    /// a fallback handoff the queue is gone, so this reaches the Apple player.
    /// A live Apple inactivity watchdog is SUSPENDED (a paused synth produces
    /// no progress ticks — expiry would wrongly settle a healthy paused turn);
    /// `resume()` re-arms it.
    func pause() {
        appleInactivityWatchdog?.cancel()
        appleInactivityWatchdog = nil
        // Suspend (not disarm) a picked voice's start deadline: a paused synth
        // speaks no words, and its re-arm closure survives for `resume()`.
        pickedVoiceDeadline?.cancel()
        pickedVoiceDeadline = nil
        if let chunkQueue {
            chunkQueue.pause()
        } else {
            player.pause()
        }
    }

    /// Resume a reply paused by `pause()`, continuing from its position with no
    /// re-fetch. Chat-only; a no-op if nothing is paused. Re-arms a suspended
    /// Apple inactivity watchdog (the leg's re-arm closure survives the pause).
    func resume() {
        if let chunkQueue {
            chunkQueue.resume()
        } else {
            player.resume()
        }
        appleInactivityRearm?()
        pickedVoiceDeadlineRearm?()
    }

    // MARK: - First-audio watchdog (cloud phase)

    /// Arm the per-turn stall watchdog (see `firstAudioWatchdog`). On expiry:
    /// kill the stalled pipeline WITHOUT firing (exactly the `cancel()`
    /// semantics — a later-landing fetch sees `Task.isCancelled` / the queue's
    /// `terminated` flag and stays inert), then hand the WHOLE reply to Apple
    /// through `startAppleLeg` (reason `.stallTimeout`): the completion still
    /// fires exactly once via the turn's one-shot latch, and the Apple leg is
    /// bounded by the inactivity watchdog.
    private func armFirstAudioWatchdog(
        text: String,
        language: String?,
        turn: Int,
        onStateChange: (@MainActor @Sendable (SpeechActivity) -> Void)?,
        fire: @escaping @MainActor @Sendable (SpeakTerminal) -> Void
    ) {
        firstAudioWatchdog?.cancel()
        let timeout = firstAudioTimeout
        firstAudioWatchdog = Task { @MainActor [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled, let self, turn == self.generation else { return }
            self.firstAudioWatchdog = nil
            self.inFlight?.cancel()
            self.inFlight = nil
            self.chunkQueue?.cancel()
            self.chunkQueue = nil
            self.startAppleLeg(
                text: text,
                language: language,
                reason: .stallTimeout,
                snapshotKeyState: nil,
                configSignature: nil,
                // The snapshot may not have resolved when the stall fires, so
                // this handoff always speaks in the system default voice.
                appleVoice: nil,
                turn: turn,
                startedAlready: false,
                onStateChange: onStateChange,
                fire: fire
            )
        }
    }

    /// Disarm sites: first audio (any leg), the turn terminal (`fire`),
    /// `cancel()`, every supersede, and Apple-leg entry. All main-actor, so
    /// arm/fire/disarm are serialized — a disarm that runs first makes the
    /// fire body inert.
    private func disarmFirstAudioWatchdog() {
        firstAudioWatchdog?.cancel()
        firstAudioWatchdog = nil
    }

    // MARK: - Apple leg (single entry) + inactivity watchdog

    /// The ONE entry point for EVERY Apple on-device leg of a chat turn —
    /// intended (`reason == nil`: the Apple sentinel is the active provider)
    /// or fallback (`reason != nil`: missing/unreadable key, fetch failure,
    /// unplayable audio, chunk failure, stall). Convergence here is what makes
    /// the transparency guarantees uniform:
    ///   - the FIRST-AUDIO watchdog is disarmed IMMEDIATELY (never armed
    ///     concurrently with the Apple inactivity watchdog → no double
    ///     handoff race);
    ///   - the APPLE INACTIVITY watchdog is armed for every leg, re-armed on
    ///     every synth progress tick, and settles the turn (`gaveUp`) if the
    ///     leg goes silent;
    ///   - a FALLBACK leg emits `.fallbackStarted` and records its ring event
    ///     when its audio ACTUALLY STARTS (an Apple leg that never starts
    ///     records `gaveUp` instead — the ring never claims audio that didn't
    ///     happen);
    ///   - `.startedPlaying` is emitted only when this leg is the turn's first
    ///     audio (`startedAlready == false`), so CarPlay's Thinking→Replying
    ///     flip and the chat UI behave identically to before;
    ///   - a leg that speaks in the user's PICKED voice must reach its first
    ///     word within `pickedVoiceStartTimeout`, or it is replaced by this
    ///     same entry point in the system default voice (`substitutedPick`),
    ///     which emits `.fallbackStarted` and records `appleVoiceSubstituted`
    ///     when its audio starts. The replacement reuses the turn's one-shot
    ///     `fire`, so the completion still fires exactly once.
    private func startAppleLeg(
        text: String,
        language: String?,
        reason: TTSFallbackReason?,
        snapshotKeyState: APIKeyState?,
        configSignature: String?,
        appleVoice: AppleVoicePick?,
        substitutedPick: Bool = false,
        turn: Int,
        startedAlready: Bool,
        onStateChange: (@MainActor @Sendable (SpeechActivity) -> Void)?,
        fire: @escaping @MainActor @Sendable (SpeakTerminal) -> Void
    ) {
        disarmFirstAudioWatchdog()
        disarmPickedVoiceDeadline()

        let keyState = snapshotKeyState ?? .notRequired
        let sig = configSignature ?? ""
        let surface = self.surface

        // Arm the inactivity watchdog and remember its re-arm closure (progress
        // ticks + post-pause resume re-enter through it).
        let rearm: @MainActor () -> Void = { [weak self] in
            guard let self, turn == self.generation else { return }
            self.armAppleInactivity(turn: turn, reason: reason, keyState: keyState, configSignature: sig, fire: fire)
        }
        appleInactivityRearm = rearm
        rearm()

        // The pick that would speak this reply (it applies to the reply's
        // language), if any. One already marked unavailable is not retried —
        // the default speaks, still marked as a substitution (no ring event:
        // the failure was recorded when it happened).
        let applicablePick = appleVoice.flatMap { $0.applies(toReplyLanguage: language) ? $0 : nil }
        let knownUnavailablePick = applicablePick?.isUnavailable == true

        // This leg's audio ACTUALLY began — the honest moment for the
        // additive signals and the ring events. A fallback leg records its
        // cloud-failure reason; a leg that replaced a silent picked voice
        // records the substitution (both, when a cloud fallback also lost its
        // pick). The message marker is emitted once either way.
        let began: @MainActor () -> Void = { [weak self] in
            guard let self, turn == self.generation else { return }
            if !startedAlready {
                onStateChange?(.startedPlaying)
            }
            if reason != nil || substitutedPick || knownUnavailablePick {
                onStateChange?(.fallbackStarted)
            }
            if let reason {
                self.outcomeLog.record(
                    surface: surface,
                    stage: Self.stage(for: reason),
                    outcome: .appleFallback,
                    errorCode: Self.errorCode(for: reason),
                    keyState: keyState,
                    configSignature: sig
                )
            }
            if substitutedPick {
                self.outcomeLog.record(
                    surface: surface,
                    stage: .apple,
                    outcome: .appleVoiceSubstituted,
                    keyState: keyState,
                    configSignature: sig
                )
            }
        }

        // No applicable pick, or one known to be unavailable → the language
        // default voice, trusted from `didStart` as always.
        guard let appleVoice = applicablePick, !knownUnavailablePick else {
            player.playApple(
                text,
                language: language,
                voiceIdentifier: nil,
                onStart: { began() },
                onProgress: { rearm() },
                onDone: fire
            )
            return
        }

        // PICKED voice: not trusted until its first word boundary (see
        // `pickedVoiceDeadline`). Until then the additive signals are held
        // back, so a silent pick never flips the UI to "playing" before the
        // default voice actually speaks. Replacement paths: the deadline
        // expires, or the synth reports a natural finish without ever
        // speaking a word. A system cancel (`.incomplete`) is an
        // interruption, not a broken voice — it settles the turn as usual.
        let attempt = PickedVoiceAttempt()
        let substitute: @MainActor () -> Void = { [weak self] in
            guard let self, turn == self.generation, !attempt.resolved else { return }
            attempt.resolved = true
            self.disarmPickedVoiceDeadline()
            self.player.stop()
            self.snapshot.markAppleVoiceUnavailable(appleVoice)
            self.startAppleLeg(
                text: text, language: language, reason: reason,
                snapshotKeyState: snapshotKeyState, configSignature: configSignature,
                appleVoice: nil, substitutedPick: true,
                turn: turn, startedAlready: startedAlready,
                onStateChange: onStateChange, fire: fire
            )
        }
        armPickedVoiceDeadline(turn: turn, onExpiry: substitute)

        player.playApple(
            text,
            language: language,
            voiceIdentifier: appleVoice.identifier,
            onStart: {
                attempt.awaitingStartTick = true
            },
            onProgress: { [weak self] in
                rearm()
                guard let self, turn == self.generation, !attempt.resolved else { return }
                // The tick `didStart` delivers alongside `onStart` is not a word.
                if attempt.awaitingStartTick {
                    attempt.awaitingStartTick = false
                    return
                }
                attempt.resolved = true
                attempt.proven = true
                self.disarmPickedVoiceDeadline()
                began()
            },
            onDone: { terminal in
                if attempt.proven || terminal == .incomplete {
                    fire(terminal)
                } else {
                    substitute()
                }
            }
        )
    }

    /// Arm the picked-voice start deadline for the live leg (or preview);
    /// `onExpiry` runs once if no word boundary disarms it first. The arm
    /// closure is kept so `resume()` can restart a deadline `pause()` cut.
    private func armPickedVoiceDeadline(turn: Int, onExpiry: @escaping @MainActor () -> Void) {
        let arm: @MainActor () -> Void = { [weak self] in
            guard let self, turn == self.generation else { return }
            self.pickedVoiceDeadline?.cancel()
            let timeout = self.pickedVoiceStartTimeout
            self.pickedVoiceDeadline = Task { @MainActor [weak self] in
                try? await Task.sleep(for: timeout)
                guard !Task.isCancelled, let self, turn == self.generation else { return }
                self.pickedVoiceDeadline = nil
                self.pickedVoiceDeadlineRearm = nil
                onExpiry()
            }
        }
        pickedVoiceDeadlineRearm = arm
        arm()
    }

    /// Disarm sites: the first word, a replacement, the turn terminal, and —
    /// through `disarmAppleInactivityWatchdog` — `cancel()` and every supersede.
    private func disarmPickedVoiceDeadline() {
        pickedVoiceDeadline?.cancel()
        pickedVoiceDeadline = nil
        pickedVoiceDeadlineRearm = nil
    }

    /// (Re-)arm the Apple inactivity watchdog for the current leg. Expiry —
    /// only reachable when the synth produced NO progress tick for the whole
    /// deadline — stops the player (clearing its completions so the stop can't
    /// double-fire), records `gaveUp`, and FIRES the turn latch: the one
    /// guaranteed settlement path when even Apple goes dead.
    private func armAppleInactivity(
        turn: Int,
        reason: TTSFallbackReason?,
        keyState: APIKeyState,
        configSignature: String,
        fire: @escaping @MainActor @Sendable (SpeakTerminal) -> Void
    ) {
        appleInactivityWatchdog?.cancel()
        let timeout = appleInactivityTimeout
        appleInactivityWatchdog = Task { @MainActor [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled, let self, turn == self.generation else { return }
            self.appleInactivityWatchdog = nil
            self.appleInactivityRearm = nil
            self.player.stop()
            self.outcomeLog.record(
                surface: self.surface,
                stage: .apple,
                outcome: .gaveUp,
                errorCode: reason.flatMap(Self.errorCode(for:)),
                keyState: keyState,
                configSignature: configSignature
            )
            // The leg went silent and was killed — the reply was NOT fully
            // delivered. `.incomplete` keeps a half-heard CarPlay reply unread.
            fire(.incomplete)
        }
    }

    /// Disarm sites: the turn terminal (`fire`), `cancel()`, every supersede,
    /// and user pause (resume re-arms via the stored closure).
    private func disarmAppleInactivityWatchdog() {
        appleInactivityWatchdog?.cancel()
        appleInactivityWatchdog = nil
        appleInactivityRearm = nil
        // Every site that ends an Apple leg ends its picked-voice deadline too.
        disarmPickedVoiceDeadline()
    }

    /// Ring stage token for a fallback reason.
    private static func stage(for reason: TTSFallbackReason) -> TTSOutcomeEvent.Stage {
        switch reason {
        case .missingKey, .keyUnreadable: return .key
        case .fetchFailed: return .fetch
        case .unplayableAudio(let stage):
            switch stage {
            case .undecodable: return .decode
            case .startRefused: return .playStart
            case .playbackFailed: return .playback
            }
        case .chunkFailed: return .chunk
        case .stallTimeout: return .stall
        }
    }

    /// Ring error code for a fallback reason (nil when no typed error drove it).
    private static func errorCode(for reason: TTSFallbackReason) -> Int? {
        if case .fetchFailed(let code) = reason { return code }
        return nil
    }

    // MARK: - Routing

    /// Shared route: Apple-sentinel → intended Apple leg; missing/unreadable
    /// key → FALLBACK Apple leg; else fetch cloud → play; on ANY failure →
    /// FALLBACK Apple leg. `fire` is the one-shot latch — every leaf hands off
    /// to a player path (whose funnel calls it) or calls it directly, so it
    /// fires exactly once; the Apple inactivity watchdog guarantees settlement.
    private func route(
        text: String,
        language: String?,
        snapshot snap: TTSSnapshot,
        turn: Int,
        onStateChange: (@MainActor @Sendable (SpeechActivity) -> Void)? = nil,
        fire: @escaping @MainActor @Sendable (SpeakTerminal) -> Void
    ) {
        let provider = TTSProvider.lookup(id: snap.providerID)
        let sig = TTSOutcomeLog.configSignature(for: snap)

        // Tracks whether ANY audio started this turn — the Apple fallback leg
        // consults it so `.startedPlaying` is emitted at most once (a chunk
        // fallback after audible chunks must not re-emit it).
        let startedFlag = StartedFlag()

        // The start signal wired to the CLOUD player's `onStart` hook: besides
        // emitting the additive `.startedPlaying`, it DISARMS the first-audio
        // watchdog — audio began, so the stall handoff must never fire.
        let onCloudStart: @MainActor @Sendable () -> Void = { [weak self] in
            self?.disarmFirstAudioWatchdog()
            startedFlag.value = true
            onStateChange?(.startedPlaying)
        }

        // Apple sentinel → the INTENDED Apple leg (no breadcrumb, no marker).
        guard provider.id != TTSProvider.appleTTS.id else {
            startAppleLeg(
                text: text, language: language, reason: nil,
                snapshotKeyState: snap.keyState, configSignature: sig,
                appleVoice: snap.appleVoice,
                turn: turn, startedAlready: false,
                onStateChange: onStateChange, fire: fire
            )
            return
        }

        // A cloud provider with no usable key on THIS device → Apple FALLBACK,
        // with the honest key state in the breadcrumb (missing vs unreadable —
        // the old nil-collapse couldn't tell them apart). A keyless custom
        // endpoint (`.notRequired`) proceeds to the cloud path with an empty key.
        switch snap.keyState {
        case .present, .notRequired:
            break
        case .missing, .unreadable:
            startAppleLeg(
                text: text, language: language,
                reason: snap.keyState == .missing ? .missingKey : .keyUnreadable,
                snapshotKeyState: snap.keyState, configSignature: sig,
                appleVoice: snap.appleVoice,
                turn: turn, startedAlready: false,
                onStateChange: onStateChange, fire: fire
            )
            return
        }
        let apiKey = snap.apiKey ?? ""

        // CHUNKED cloud path (long replies): synthesize the small head chunk
        // first and speak it while the tail synthesizes underneath — the
        // time-to-first-word fix. The snapshot was resolved ONCE above, so
        // every chunk of this turn uses the same provider/voice/key even if
        // Settings change mid-turn. Single-chunk replies fall through to the
        // proven one-POST path below, byte-identical.
        let segments = SpeechSegmenter.segments(for: text, policy: chunkPolicy)
        if segments.count > 1 {
            startChunkedTurn(
                segments: segments,
                language: language,
                provider: provider,
                snapshot: snap,
                configSignature: sig,
                apiKey: apiKey,
                turn: turn,
                startedFlag: startedFlag,
                onCloudStart: onCloudStart,
                onStateChange: onStateChange,
                fire: fire
            )
            return
        }

        // Cloud path. Fetch off the main actor; on success play the mp3 and
        // consume the TYPED outcome — `.finished` completes the turn,
        // `.failed(stage)` hands to the Apple fallback (the old bare-completion
        // path silently swallowed unplayable audio: fully silent turn, no
        // fallback). On a fetch throw → Apple fallback. Tracked in `inFlight`
        // so `cancel()` aborts it; every arm guards `Task.isCancelled` + the
        // turn generation so a late fetch (one that resolves after `cancel()`)
        // returns WITHOUT touching the player.
        inFlight = Task { @MainActor in
            do {
                let data = try await self.fetcher.synthesize(
                    text: text,
                    provider: provider,
                    voice: snap.voice,
                    customModel: snap.customModel,
                    apiKey: apiKey,
                    customConfig: snap.customConfig
                )
                if Task.isCancelled || turn != self.generation { return }
                self.player.playCloud(data, onStart: onCloudStart) { [weak self] outcome in
                    guard let self, turn == self.generation else { return }
                    switch outcome {
                    case .finished:
                        fire(.finished)
                    case .failed(let stage):
                        self.startAppleLeg(
                            text: text, language: language,
                            reason: .unplayableAudio(stage),
                            snapshotKeyState: snap.keyState, configSignature: sig,
                            appleVoice: snap.appleVoice,
                            turn: turn, startedAlready: startedFlag.value,
                            onStateChange: onStateChange, fire: fire
                        )
                    }
                }
            } catch {
                // Cloud synthesis failed (unreachable / 4xx / empty audio /
                // transport). Fall back to Apple — free + always available.
                // Never log the error payload or text. The breadcrumb
                // carries only the typed error code.
                if Task.isCancelled || turn != self.generation { return }
                let appError = error as? AppError
                let code = appError?.errorCode ?? -1
                // A TERMINAL refusal also gets one quiet user-visible verdict
                // (see `.spokenReplyVoiceRefused`) — posted BEFORE the fallback
                // starts, never instead of it. Transient failures stay silent.
                if let appError, !appError.isRetryable {
                    NotificationCenter.default.post(
                        name: .spokenReplyVoiceRefused,
                        object: nil,
                        userInfo: [SpokenReplyVoiceRefusal.errorCodeKey: appError.errorCode]
                    )
                }
                self.startAppleLeg(
                    text: text, language: language,
                    reason: .fetchFailed(errorCode: code),
                    snapshotKeyState: snap.keyState, configSignature: sig,
                    appleVoice: snap.appleVoice,
                    turn: turn, startedAlready: false,
                    onStateChange: onStateChange, fire: fire
                )
            }
        }
    }

    /// Build + start the chunk pipeline for a multi-chunk turn. The queue owns
    /// fetch-ahead and strict in-order playback (`SpeechChunkQueue`); this
    /// wires its terminals into the SAME exactly-once latch and fallback
    /// semantics as the single-blob path:
    ///   - every chunk fetch = one ordinary `fetcher.synthesize` call with the
    ///     turn's frozen snapshot (retries, status mapping, custom-endpoint
    ///     handling all unchanged inside `TTSClient`);
    ///   - first audible chunk → the additive `.startedPlaying` signal;
    ///   - final chunk finished → `fire` (the one-shot completion latch);
    ///   - any chunk unplayable (fetch failure, refused start, OR mid-clip
    ///     playback death) → Apple speaks the remainder FROM that chunk
    ///     (including a partially-played one — content preservation over
    ///     de-duplication) via `startAppleLeg`. Played chunks before it are
    ///     never re-spoken; if audio already started, `.startedPlaying` is not
    ///     re-emitted (the `.fallbackStarted` marker still is).
    private func startChunkedTurn(
        segments: [String],
        language: String?,
        provider: TTSProvider,
        snapshot snap: TTSSnapshot,
        configSignature sig: String,
        apiKey: String,
        turn: Int,
        startedFlag: StartedFlag,
        onCloudStart: @escaping @MainActor @Sendable () -> Void,
        onStateChange: (@MainActor @Sendable (SpeechActivity) -> Void)?,
        fire: @escaping @MainActor @Sendable (SpeakTerminal) -> Void
    ) {
        // Stop any prior single-blob playback BEFORE the queue starts. The
        // one-POST path gets this from `playCloud`/`playApple`'s own
        // `stopInFlight()` at audio handoff; the chunked path never routes new
        // audio through `player`, so without this a `speak()` issued while a
        // prior blob still plays (no interposed `cancel()`) would overlap two
        // voices. Mirrors `WatchReplySpeaker.stopInFlight`'s posture.
        player.stop()

        // Capture the seam VALUE (not self) so the queue's fetch closures
        // don't retain the engine; terminal closures are weak for the same
        // reason (queue → engine would otherwise cycle with engine → queue).
        let fetcher = self.fetcher
        let queue = SpeechChunkQueue(
            segments: segments,
            fetch: { _, chunkText in
                try await fetcher.synthesize(
                    text: chunkText,
                    provider: provider,
                    voice: snap.voice,
                    customModel: snap.customModel,
                    apiKey: apiKey,
                    customConfig: snap.customConfig
                )
            },
            players: chunkPlayers,
            onFirstAudio: { onCloudStart() },
            onFinished: { [weak self] in
                guard let self, turn == self.generation else { return }
                self.chunkQueue = nil
                fire(.finished)
            },
            onFallback: { [weak self] remaining, firstAudioFired in
                // Split the two "don't run the fallback" cases: an engine that
                // died mid-required-fallback must still SETTLE the turn
                // (`.incomplete` — the remainder was never spoken), while a
                // superseded/cancelled turn (`turn != generation`) must fire
                // NOTHING — cancel's no-completion contract.
                guard let self else {
                    fire(.incomplete)
                    return
                }
                guard turn == self.generation else { return }
                self.chunkQueue = nil
                self.startAppleLeg(
                    text: remaining, language: language,
                    reason: .chunkFailed,
                    snapshotKeyState: snap.keyState, configSignature: sig,
                    appleVoice: snap.appleVoice,
                    turn: turn, startedAlready: firstAudioFired,
                    onStateChange: onStateChange, fire: fire
                )
            }
        )
        chunkQueue = queue
        queue.start()
    }

    /// PREVIEW-ONLY route (Settings "Speak a sample" / Diagnostics voice
    /// preview). DIVERGES from `route`: NO Apple fallback anywhere on the
    /// cloud path — a fetch throw reports `.failure(error)`; fetched audio
    /// that won't play reports `.failure(.ttsSynthesisFailed)` (the typed
    /// player outcome — previously ANY completed `playCloud` reported success,
    /// so undecodable bytes false-greened). The Apple-sentinel / no-key arm
    /// still plays Apple and reports `.success`. `report` is the one-shot
    /// latch. Ring events are recorded here (the stage detail only this method
    /// sees); the VM's missing-key preflight records its own event because no
    /// call reaches here in that case. Never log the error payload or text.
    private func routePreview(
        text: String,
        snapshot snap: TTSSnapshot,
        surface: TTSOutcomeEvent.Surface,
        report: @escaping @MainActor @Sendable (Result<Void, AppError>) -> Void
    ) {
        let provider = TTSProvider.lookup(id: snap.providerID)
        let sig = TTSOutcomeLog.configSignature(for: snap)
        let keyState = snap.keyState
        let turn = generation

        // Apple sentinel OR no key → Apple on-device voice: a legit preview of
        // a provider that uses Apple — play it and report success (`appleOK`,
        // distinct from a cloud success). The honest key state is recorded, so
        // a bypassed preflight still leaves a truthful trace.
        guard provider.id != TTSProvider.appleTTS.id,
              keyState == .present || keyState == .notRequired else {
            // Auditioning the user's picked Apple voice: it must PROVE it
            // speaks (reach a word), or the preview fails loud — substituting
            // the default voice here would green-light a voice that is gone.
            if provider.id == TTSProvider.appleTTS.id, let pick = snap.appleVoice {
                previewPickedAppleVoice(
                    text: text, pick: pick, surface: surface,
                    keyState: keyState, configSignature: sig, turn: turn, report: report
                )
                return
            }
            // The preview contract predates the typed terminal and keeps its
            // behavior: any settled Apple sample reports `.success` (the
            // terminal value is a chat/CarPlay concern, not a preview one).
            player.playApple(text) { [weak self] _ in
                // A superseded sample that still finishes must not report
                // success into a newer preview.
                guard let self, turn == self.generation else { return }
                self.outcomeLog.record(
                    surface: surface, stage: .apple, outcome: .appleOK,
                    keyState: keyState, configSignature: sig
                )
                report(.success(()))
            }
            return
        }
        // The keyless custom endpoint (`.notRequired`) auditions with an empty
        // key; every other provider reaching here has a present key.
        let apiKey = snap.apiKey ?? ""

        // Cloud path. On success play the mp3 and consume the TYPED outcome;
        // on ANY failure report it and play NOTHING (no Apple fallback —
        // diverges from chat). Tracked in `inFlight` so `cancel()` aborts it;
        // every arm guards `Task.isCancelled` + the generation so a late fetch
        // returns WITHOUT touching the player or the latch.
        inFlight = Task { @MainActor in
            do {
                let data = try await self.fetcher.synthesize(
                    text: text,
                    provider: provider,
                    voice: snap.voice,
                    customModel: snap.customModel,
                    apiKey: apiKey,
                    customConfig: snap.customConfig
                )
                if Task.isCancelled || turn != self.generation { return }
                self.player.playCloud(data) { [weak self] outcome in
                    guard let self, turn == self.generation else { return }
                    switch outcome {
                    case .finished:
                        self.outcomeLog.record(
                            surface: surface, stage: .playback, outcome: .cloudOK,
                            keyState: keyState, configSignature: sig
                        )
                        report(.success(()))
                    case .failed(let stage):
                        // Fetched but unplayable — the old false-green. The
                        // exact stage lives in the ring; the surfaced error
                        // stays the terminal synthesis bucket.
                        let ringStage: TTSOutcomeEvent.Stage
                        switch stage {
                        case .undecodable: ringStage = .decode
                        case .startRefused: ringStage = .playStart
                        case .playbackFailed: ringStage = .playback
                        }
                        self.outcomeLog.record(
                            surface: surface, stage: ringStage, outcome: .failedLoud,
                            errorCode: AppError.ttsSynthesisFailed.errorCode,
                            keyState: keyState, configSignature: sig
                        )
                        report(.failure(.ttsSynthesisFailed))
                    }
                }
            } catch {
                if Task.isCancelled || turn != self.generation { return }
                let appError = (error as? AppError) ?? .ttsSynthesisFailed
                self.outcomeLog.record(
                    surface: surface, stage: .fetch, outcome: .failedLoud,
                    errorCode: appError.errorCode,
                    keyState: keyState, configSignature: sig
                )
                report(.failure(appError))
            }
        }
    }

    /// Preview of a picked Apple voice. Success = the synth reached a word
    /// boundary and then settled. Failure (`.ttsSynthesisFailed`, recorded
    /// `failedLoud` at the `.apple` stage) = the start deadline expired first,
    /// or the synth finished without speaking a word. Never substitutes.
    private func previewPickedAppleVoice(
        text: String,
        pick: AppleVoicePick,
        surface: TTSOutcomeEvent.Surface,
        keyState: APIKeyState,
        configSignature sig: String,
        turn: Int,
        report: @escaping @MainActor @Sendable (Result<Void, AppError>) -> Void
    ) {
        let attempt = PickedVoiceAttempt()
        let fail: @MainActor () -> Void = { [weak self] in
            guard let self, turn == self.generation, !attempt.resolved else { return }
            attempt.resolved = true
            self.disarmPickedVoiceDeadline()
            self.player.stop()
            self.outcomeLog.record(
                surface: surface, stage: .apple, outcome: .failedLoud,
                errorCode: AppError.ttsSynthesisFailed.errorCode,
                keyState: keyState, configSignature: sig
            )
            report(.failure(.ttsSynthesisFailed))
        }
        armPickedVoiceDeadline(turn: turn, onExpiry: fail)

        player.playApple(
            text,
            language: nil,
            voiceIdentifier: pick.identifier,
            onStart: {
                attempt.awaitingStartTick = true
            },
            onProgress: { [weak self] in
                guard let self, turn == self.generation, !attempt.resolved else { return }
                if attempt.awaitingStartTick {
                    attempt.awaitingStartTick = false
                    return
                }
                attempt.resolved = true
                attempt.proven = true
                self.disarmPickedVoiceDeadline()
            },
            onDone: { [weak self] _ in
                guard let self, turn == self.generation else { return }
                guard attempt.proven else {
                    fail()
                    return
                }
                // Proven by a spoken word: the voice works, even if the rest
                // of the sample was then interrupted.
                self.outcomeLog.record(
                    surface: surface, stage: .apple, outcome: .appleOK,
                    keyState: keyState, configSignature: sig
                )
                report(.success(()))
            }
        )
    }

    // MARK: - Turn-started flag

    /// Tiny reference box tracking "any audio started this turn" across the
    /// cloud and fallback legs (`@MainActor` — no lock needed).
    @MainActor
    private final class StartedFlag {
        var value = false
    }

    /// Per-attempt state for a leg (or preview) speaking in a PICKED voice.
    /// `awaitingStartTick`: `didStart` fired and its paired progress tick has
    /// not arrived yet (that tick is not a word). `resolved`: the attempt is
    /// decided — proven by a word, or replaced/failed — so no second decision
    /// can run. `proven`: a word boundary arrived.
    @MainActor
    private final class PickedVoiceAttempt {
        var awaitingStartTick = false
        var resolved = false
        var proven = false
    }

    // MARK: - One-shot completion latch

    /// Wrap `completion` so it can fire at most once, regardless of how many
    /// terminal callbacks reach it (the pathological all-fail leaf, a late
    /// delegate callback, a double-handoff). Guarantees the at-most-once
    /// contract at the orchestration boundary, independent of `SpeechPlayer`'s
    /// own funnel; the Apple inactivity watchdog supplies the eventual-
    /// settlement half.
    private static func makeOneShot(
        _ completion: @escaping @MainActor @Sendable (SpeakTerminal) -> Void
    ) -> @MainActor @Sendable (SpeakTerminal) -> Void {
        let box = OneShotBox(completion)
        return { @MainActor terminal in box.fire(terminal) }
    }

    /// Reference box holding the fire-once state. `@MainActor` so the `fired`
    /// flag needs no lock (all callbacks land on the main actor). The FIRST
    /// terminal wins — a late second terminal (whatever its value) is a no-op,
    /// preserving exactly-once.
    @MainActor
    private final class OneShotBox {
        private var pending: (@MainActor @Sendable (SpeakTerminal) -> Void)?
        init(_ completion: @escaping @MainActor @Sendable (SpeakTerminal) -> Void) {
            self.pending = completion
        }
        func fire(_ terminal: SpeakTerminal) {
            let c = pending
            pending = nil
            c?(terminal)
        }
    }

    /// `previewSample`'s outcome-carrying variant of `makeOneShot`. Same
    /// exactly-once guarantee; the payload is the `Result` (`.success` on a
    /// played sample, `.failure(error)` on a cloud error). The returned
    /// closure fires at most once regardless of how many terminal callbacks
    /// reach it.
    private static func makeOneShotResult(
        _ completion: @escaping @MainActor @Sendable (Result<Void, AppError>) -> Void
    ) -> @MainActor @Sendable (Result<Void, AppError>) -> Void {
        let box = OneShotResultBox(completion)
        return { @MainActor outcome in box.fire(outcome) }
    }

    /// Reference box holding the fire-once state for the `Result`-carrying
    /// preview latch. `@MainActor` so the flag needs no lock.
    @MainActor
    private final class OneShotResultBox {
        private var pending: (@MainActor @Sendable (Result<Void, AppError>) -> Void)?
        init(_ completion: @escaping @MainActor @Sendable (Result<Void, AppError>) -> Void) {
            self.pending = completion
        }
        func fire(_ outcome: Result<Void, AppError>) {
            let c = pending
            pending = nil
            c?(outcome)
        }
    }

    // MARK: - Sample text

    /// Fixed sample sentence for the Settings "Speak a sample" preview. Short,
    /// neutral, exercises prosody. English-only (V1 localization scope).
    private static let sampleText = String(
        localized: "tts.sample",
        defaultValue: "This is how your replies will sound."
    )
}

// MARK: - Terminal spoken-voice refusal (the one user-visible verdict)

/// `userInfo` contract for `.spokenReplyVoiceRefused`.
enum SpokenReplyVoiceRefusal {
    /// The refusing `AppError`'s numeric code. A CODE, not a message: the
    /// receiving surface rebuilds the error and renders the canonical copy, so
    /// the wording cannot fork here — and nothing text-shaped (reply content,
    /// endpoint URL, key material) can ride a `userInfo` dictionary by accident.
    static let errorCodeKey = "errorCode"
}

extension Notification.Name {
    /// A spoken reply's chosen voice was refused for a reason a retry cannot
    /// change, and the Apple on-device voice spoke the reply instead.
    ///
    /// Falling back is right — the user still hears their reply, which is the
    /// whole point of having a fallback. Falling back SILENTLY on a terminal
    /// refusal is not: a BYO voice endpoint whose certificate this device
    /// rejects would keep producing the built-in voice indefinitely with
    /// nothing anywhere saying why, and the device-local outcome ring is a
    /// forensic record, not a surface anyone reads. Transient failures stay
    /// silent by design — they resolve on their own, and a notice per flaky
    /// synthesis is noise that would teach the user to ignore this one.
    static let spokenReplyVoiceRefused = Notification.Name("spokenReplyVoiceRefused")
}

#if os(macOS)
extension ReplyVoice: SpeechExclusivityParty {
    /// Preempted by another macOS party (a manual bubble speak, the mic).
    /// `cancel()` is the right stop here: it aborts the in-flight fetch AND
    /// playback WITHOUT firing the pending completion — the arrival/preview
    /// callers are fire-and-forget, nothing awaits it. Only `ReplyVoice.shared`
    /// is ever registered (see `shared`).
    func stopForSpeechExclusivity() {
        cancel()
    }
}
#endif
#endif
