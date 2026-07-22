// Conduck
// WatchReplySpeaker.swift
//
// Route-aware TTS for agent replies on Apple Watch. Wraps
// `AVSpeechSynthesizer` (Apple on-device) AND a local `AVAudioPlayer` for
// cloud-synthesized mp3 audio. The Watch's `SpeakEngine` conformer: driven by
// the shared cross-platform `ThreadSpeaker` state machine (idle → loading →
// playing → paused) exactly like `ReplyVoice` on iOS/macOS, so the per-message
// "Read aloud" control behaves identically on the wrist. Replies arrive silent
// by default; the user taps "Read aloud" to hear one — UNLESS the opt-in
// Read-replies-aloud toggle is ON, in which case headless/Ask replies are
// auto-spoken through this same engine via the thread's `ThreadSpeaker`
// (staged by the shared `AutoSpeakMailbox`; see `WatchAutoSpeakVerdict`).
//
// This mirrors the iOS/macOS `SpeechPlayer` funnel pattern (NSObject +
// AVAudioPlayerDelegate + AVSpeechSynthesizerDelegate): an `onStart` fired once
// when audio truly begins, and a single nil-then-call `completion` funnel
// (`fireCompletion()`) on every terminal — audio `didFinish` / decode-error,
// synth `didFinish` / `didCancel`. `SpeechPlayer` itself is iOS/macOS-only (NOT
// in the Watch target), so the Watch owns this local equivalent.
//
// Cloud TTS on the wrist: inside the audio-session activate-completion, the
// active TTS engine is resolved from `WatchSettingsReader` (broadcast from the
// iPhone via the extended STT envelope). Apple-active OR no key → the Apple
// `synthesizer.speak` path. Cloud-active + key present → fetch the mp3 via
// `WatchTTSClient` and play it through the LOCAL `AVAudioPlayer`. On ANY throw →
// fall back to the Apple voice (which then fires start + completion via its
// delegate).
//
// Markdown-strip mandate: EVERY speak path runs the reply through the
// shared `ReplySanitizer.spoken(_:)` first — Watch is a high-stakes TTS surface
// (Bluetooth route, hands occupied in car/kitchen). Feeding raw Markdown to a
// voice engine would read literal asterisks/backticks/URLs aloud.
//
// Apple voice is locked to `.default` — watchOS has no `.enhanced`/`.premium`/
// Personal Voice tier.
//
// watchOS audio activation: use the async
// `AVAudioSession.activate(options:completionHandler:)` — the watchOS-documented
// activation path — not the synchronous `setActive(true)` (which can fail on
// watchOS for a playback session). The `.playback` category write is
// audio-server IPC that can stall for seconds under a distressed daemon, so it
// rides the coordinator's FIFO config lane OFF the main actor (`runConfig`);
// the activation is issued only after the chained category write returns, so
// the session is classified for output before activation and `speak` never
// blocks the main thread on audio IPC.
//
// SESSION OWNERSHIP + TERMINAL DEACTIVATION: the watch's ONE shared session is
// arbitrated by `WatchAudioSessionCoordinator`. Each turn claims `.playback`
// immediately before the category write; every turn terminal
// (`fireCompletion` / `cancel()` / `stopInFlight()`) releases the claim via
// `releaseAndDeactivate`, which — iff the claim is still live — schedules
// `setActive(false, .notifyOthersOnDeactivation)` after a short grace. That
// deactivation is the DUCK-RESTORE: a `.duckOthers` playback session left
// active keeps the user's podcast/music dipped at the OS's discretion long
// after the reply ends. A stale claim (the recorder took the session, or a
// newer speak superseded this turn) releases as a no-op, so a late terminal
// can never tear down a session another owner just claimed; an immediate
// re-claim inside the grace (back-to-back speaks, tap-to-speak the next
// bubble) cancels the pending teardown, so consecutive turns never bounce the
// session through setActive(false). The first-audio watchdog handoff keeps
// the claim — the turn continues on the Apple voice over the same session.
//
// SUPERSEDE SAFETY: a late activation/fetch that resolves AFTER `cancel()` must
// be inert — it must never restart playback. A monotonically-incrementing
// `generation` token is captured at `speak` time; the async activate-completion
// and the cloud fetch both re-check it (and `Task.isCancelled`) before touching
// the engine, so a stale turn returns without playing.
//
// TIME AUTHORITY (first-audio watchdog — the wrist port of `ReplyVoice`'s):
// the Apple fallback only covers cloud legs that FAIL (throw); a synth request
// that HANGS would strand `ThreadSpeaker`'s `.loading` spinner for the whole
// transport timeout — dead air on the glanceability-premised surface. A
// per-turn watchdog bounds time-to-first-audio and hands a stalled turn to the
// Apple voice; after first audio, the chunk queue's seam-stall grace bounds
// the mid-turn seams instead.
//
// Privacy invariants (docs/ai-context/spec.md "Privacy & Security"): never log the reply text, the API key, or
// the synthesis URL. Cloud audio is in-memory `Data`, never written to disk.
// `WatchLog` milestones here carry metadata only (durations, byte counts,
// error codes, reason tokens).

import AVFoundation

/// Speaks agent replies through the active TTS engine (cloud mp3 or Apple's
/// on-device synthesizer), stripping Markdown first. Conforms to `SpeakEngine`
/// so the shared `ThreadSpeaker` state machine drives it identically to the
/// iOS/macOS `ReplyVoice`.
@MainActor
final class WatchReplySpeaker: NSObject, AVAudioPlayerDelegate, AVSpeechSynthesizerDelegate, SpeakEngine {

    /// True when the CURRENT output route survives the ambient dim. watchOS
    /// kills BUILT-IN-SPEAKER audio the moment the screen dims (hard platform
    /// limit, no terminal delegate) but keeps a Bluetooth route (AirPods)
    /// playing — so the thread view's dim-edge `systemDimPause()` call must
    /// fire only on the speaker route and never interrupt AirPods playback.
    static var outputRouteSurvivesDim: Bool {
        !AVAudioSession.sharedInstance().currentRoute.outputs
            .contains { $0.portType == .builtInSpeaker }
    }

    private let synthesizer = AVSpeechSynthesizer()

    /// Local cloud-audio player. Held only while a clip is playing; released in
    /// `fireCompletion()`. `SpeechPlayer` (iOS/macOS) is not in the Watch target,
    /// so the Watch owns its own bare player here.
    private var audioPlayer: AVAudioPlayer?

    /// The pending exactly-once completion (the shared state machine's terminal).
    /// Set by `speak`; nil-then-called by `fireCompletion()` so it can never fire
    /// twice. Mirrors `SpeechPlayer.completion`.
    private var completion: (@MainActor @Sendable () -> Void)?

    /// OPTIONAL fire-and-forget "playback actually began" signal (drives loading
    /// → playing). NOT part of the exactly-once completion contract — fired once
    /// (cloud: right after `play()` returns true; Apple: in `didStart`), then
    /// cleared. Mirrors `SpeechPlayer.onStart`.
    private var onStart: (@MainActor @Sendable () -> Void)?

    /// The RAW per-turn progress handler (unwrapped `onStateChange`). Kept
    /// ALONGSIDE the `onStart` latch so the FALLBACK-transparency signal
    /// `.fallbackStarted` can be emitted through it when a fallback Apple leg's
    /// audio ACTUALLY starts — including a mid-turn chunk fallback where the
    /// `onStart` latch already fired (latch nil → no `.startedPlaying`, but the
    /// stored handler still gets `.fallbackStarted`). Cleared at every terminal
    /// / supersede alongside `completion`. Mirrors `ReplyVoice`'s `onStateChange`
    /// threading into `startAppleLeg`.
    private var stateChangeHandler: (@MainActor @Sendable (SpeechActivity) -> Void)?

    /// Set true when an Apple leg with a fallback `reason` BEGINS (in
    /// `speakApple`); consumed once in `fireStart()` — after the `onStart` latch,
    /// it emits `.fallbackStarted` through `stateChangeHandler` and clears. An
    /// Apple leg that never starts (dead leg → the inactivity watchdog settles it
    /// as gave-up) clears the flag at its terminal WITHOUT emitting — the marker
    /// never claims audio that didn't happen. Cleared at terminals/supersede.
    private var fallbackPending = false

    /// The current turn's sanitized text + frozen content language — retained so
    /// a cloud clip that dies MID-PLAY (`didFinishPlaying(successfully: false)` /
    /// decode error) can hand the WHOLE reply to the Apple fallback (a partial
    /// repeat is acceptable; a silently-lost tail is not — audio-time → text
    /// mapping is unreliable, so no truncation is attempted). Set in `speak`
    /// after sanitize; cleared in `fireCompletion`/`cancel()`/`stopInFlight()`.
    private var currentTurnText: String?
    private var currentTurnLanguage: String?

    /// The in-flight async work for the current turn (session activation + cloud
    /// fetch). Cancelled by `cancel()` so a fetch that resolves after a supersede
    /// can't restart playback on a torn-down session. Mirrors `ReplyVoice.inFlight`.
    private var inFlight: Task<Void, Never>?

    /// The live chunk pipeline for a LONG cloud reply (`SpeechChunkQueue`, the
    /// same engine `ReplyVoice` uses — `.wristConservative` policy: longer
    /// head, small bounded tails so no single synth request can outlive the
    /// single-attempt `WatchTTSClient`'s 60 s transport timeout). Built with
    /// the wrist's `seamStallGrace` so a wedged tail fetch Apple-speaks the
    /// remainder instead of silencing a seam for the full transport timeout.
    /// Nil for short replies (the proven single-POST `speakCloud` path) and
    /// for the Apple voice. Torn down by `cancel()`/`stopInFlight()` and its
    /// own terminals.
    private var chunkQueue: SpeechChunkQueue?

    /// Monotonic turn token. Bumped on every `speak` / `cancel`. The async
    /// activate-completion + the cloud fetch capture the value at start and
    /// re-check it before touching the engine, so a LATE callback from a
    /// superseded/cancelled turn is inert (belt-and-braces with `Task.isCancelled`
    /// + the `completion != nil` check).
    private var generation = 0

    /// Identity of the utterance / player currently owned by the engine. The
    /// AVFoundation DELEGATE terminals carry no turn token, so they guard on these
    /// (via `ObjectIdentifier`, which is `Sendable` across the nonisolated→MainActor
    /// hop) — a STALE `didCancel`/`didFinish` from a superseded utterance/player is
    /// then a no-op instead of firing the NEW turn's `completion`. This is
    /// load-bearing on the Watch specifically: `speak` sets `completion`
    /// SYNCHRONOUSLY, so (unlike iOS, where ReplyVoice's async snapshot hop leaves a
    /// gap during which the stale terminal lands while `completion` is still nil)
    /// the stale terminal would otherwise hit the freshly-set new completion.
    private var currentUtteranceID: ObjectIdentifier?
    private var currentPlayerID: ObjectIdentifier?

    /// The cloud-synthesize seam's shape — `WatchTTSClient.synthesize` minus
    /// the session param. `@MainActor` like `SpeechChunkQueue.fetch`, so the
    /// single-POST path and the chunk-fetch wrapper both compose through ONE
    /// seam (mirrors `ReplyVoice`'s injectable `TTSFetching`).
    typealias CloudSynthesize = @MainActor (
        _ text: String, _ provider: TTSProvider, _ voice: String?,
        _ customModel: String?, _ apiKey: String
    ) async throws -> Data

    /// The Apple-leg seam's shape: (text, onStart, onDone). Injected only by
    /// tests — real `AVSpeechSynthesizer` delegate terminals are unreliable in
    /// watch-sim unit tests, so fakes record the text and drive the SAME
    /// start/completion funnels the delegates would.
    typealias AppleLeg = @MainActor (
        _ text: String,
        _ onStart: @escaping @MainActor () -> Void,
        _ onDone: @escaping @MainActor () -> Void
    ) -> Void

    /// Every cloud fetch (single-POST AND per-chunk) routes through this one
    /// seam. Production: `liveSynthesize` (the live client + forensic log).
    private let synthesize: CloudSynthesize

    /// TEST-ONLY Apple-leg override; nil in production (`speakApple` speaks
    /// through the real synthesizer, whose delegates fire the funnels via the
    /// utterance-identity guard).
    private let appleLegOverride: AppleLeg?

    /// Record⇄playback arbitration for the shared session (see the file-header
    /// SESSION OWNERSHIP note). Injectable so tests observe claim/release/
    /// deactivate semantics without an audio server.
    private let sessionCoordinator: WatchAudioSessionCoordinator

    /// This turn's ownership token — set when `speak` claims `.playback`, nil
    /// after a terminal releases it. Handing the token back through
    /// `releaseAndDeactivate` is what makes terminal deactivation safe: a
    /// stale token (superseded by the recorder or a newer speak) is a no-op.
    private var sessionClaim: WatchAudioSessionCoordinator.Claim?

    /// FIRST-AUDIO WATCHDOG — the wrist port of `ReplyVoice.firstAudioWatchdog`
    /// (see the file-header TIME AUTHORITY note). Armed per turn in `speak`
    /// AFTER the empty-after-sanitize early return (that path fires the
    /// completion synchronously and must not leave an armed watchdog);
    /// disarmed on first audio (`fireStart`), on the terminal
    /// (`fireCompletion`), and in `cancel()`/`stopInFlight()` (supersede +
    /// teardown). On expiry it kills the stalled leg WITHOUT firing and
    /// WITHOUT bumping the generation, then hands the WHOLE sanitized reply
    /// to `speakApple` — whose start + completion flow through the existing
    /// exactly-once funnel.
    private var firstAudioWatchdog: Task<Void, Never>?

    /// Watchdog deadline. 20 s — tighter than `ReplyVoice`'s 45 s because only
    /// the frozen cloud vendors ever reach `WatchTTSClient` (a BYO endpoint
    /// throws immediately → instant Apple fallback) and the
    /// `.wristConservative` head is ≤ 220 chars, normally a 2–5 s synth. NOT
    /// tighter, because the BT→paired-iPhone relay route is jittery — a
    /// too-tight deadline would misroute working cloud TTS to Apple on every
    /// slow-but-alive network. Injectable for tests.
    private let firstAudioTimeout: Duration

    /// APPLE INACTIVITY WATCHDOG — the wrist port of
    /// `ReplyVoice.appleInactivityWatchdog`. Bounds EVERY Apple leg (intended
    /// AND fallback) as an INACTIVITY deadline (not a total-duration timer):
    /// armed at each Apple-leg entry, re-armed on every synth progress tick
    /// (`didStart` + `willSpeakRangeOfSpeechString`), so a genuinely-speaking
    /// synth of any length is never cut off — but one that silently produces
    /// nothing (a wedged synth, a lost `didFinish`, or a test `appleLegOverride`
    /// that never calls back) is stopped and the turn SETTLED (`fireCompletion`),
    /// so the shared `ThreadSpeaker` spinner can never hang. Load-bearing pairing
    /// with the first-audio watchdog: the two are NEVER armed simultaneously
    /// (Apple-leg entry disarms the first-audio one FIRST), so they can't race
    /// into a double handoff. Disarmed on `fireCompletion`/`cancel()`/
    /// `stopInFlight()`/`pause()`; re-armed on `resume()` if an Apple leg is live.
    private var appleInactivityWatchdog: Task<Void, Never>?

    /// Re-arm closure for the CURRENT Apple leg's inactivity watchdog — captured
    /// at leg entry so the progress ticks AND `resume()` (after `pause()`
    /// suspended the watchdog) re-arm with the same turn. Nil when no Apple leg
    /// is live (so a cloud-path `fireStart`/`resume` re-arm is a no-op). Mirrors
    /// `ReplyVoice.appleInactivityRearm`.
    private var appleInactivityRearm: (@MainActor () -> Void)?

    /// Inactivity deadline between Apple synth progress ticks. Word-boundary
    /// ticks arrive at sub-second cadence while speaking, so the default only
    /// ever expires on a genuinely dead leg. Injectable for tests. Mirrors
    /// `ReplyVoice.appleInactivityTimeout`.
    private let appleInactivityTimeout: Duration

    /// Mid-turn seam grace handed to `SpeechChunkQueue`: once audio starts the
    /// first-audio watchdog is disarmed, so a wedged TAIL fetch would
    /// otherwise silence a seam for the full 60 s transport timeout. After
    /// 10 s of seam dead air the queue Apple-speaks the unplayed remainder.
    /// iOS/CarPlay pass nothing (their `TTSClient` retry loop self-heals).
    private static let seamStallGrace: Duration = .seconds(10)

    /// Production synthesize seam: the live `WatchTTSClient` wrapped with the
    /// forensic duration/byte-count log (metadata only — never the text,
    /// URL, or key; a failure logs the `AppError` code, never the payload).
    private static let liveSynthesize: CloudSynthesize = { text, provider, voice, customModel, apiKey in
        let clock = ContinuousClock()
        let started = clock.now
        do {
            let data = try await WatchTTSClient.synthesize(
                text: text, provider: provider, voice: voice,
                customModel: customModel, apiKey: apiKey
            )
            WatchLog.note(.state, "tts.synth",
                          ["ms": Int((clock.now - started) / .milliseconds(1)),
                           "bytes": data.count])
            return data
        } catch {
            WatchLog.error(.state, "tts.synth.fail",
                           ["ms": Int((clock.now - started) / .milliseconds(1)),
                            "code": (error as? AppError)?.errorCode ?? -1])
            throw error
        }
    }

    /// - Parameters:
    ///   - synthesize: cloud-fetch seam (default: the live `WatchTTSClient`).
    ///   - firstAudioTimeout: watchdog deadline (default 20 s; tests inject a
    ///     tiny value to exercise the stall handoff — mirrors `ReplyVoice`).
    ///   - appleLeg: TEST-ONLY Apple-voice seam (default nil = the real
    ///     `AVSpeechSynthesizer`).
    ///   - appleInactivityTimeout: Apple-leg inactivity deadline (default 10 s;
    ///     tests inject a tiny value to exercise the dead-leg settlement).
    ///   - sessionCoordinator: session-ownership arbiter (default: the shared
    ///     process-wide instance; tests inject one with a short grace + an
    ///     observed deactivate closure).
    init(
        synthesize: CloudSynthesize? = nil,
        firstAudioTimeout: Duration = .seconds(20),
        appleLeg: AppleLeg? = nil,
        appleInactivityTimeout: Duration = .seconds(10),
        sessionCoordinator: WatchAudioSessionCoordinator = .shared
    ) {
        self.synthesize = synthesize ?? Self.liveSynthesize
        self.firstAudioTimeout = firstAudioTimeout
        self.appleLegOverride = appleLeg
        self.appleInactivityTimeout = appleInactivityTimeout
        self.sessionCoordinator = sessionCoordinator
        super.init()
        synthesizer.delegate = self
        // Ride the app audio session. `usesApplicationAudioSession` is
        // iOS/watchOS-only; the Watch is always non-macOS, but the guard keeps
        // the intent explicit and mirrors `SpeechPlayer`.
        #if !os(macOS)
        synthesizer.usesApplicationAudioSession = true
        #endif
    }

    // MARK: - SpeakEngine

    /// Speak the reply via the active TTS engine, sanitizing Markdown first.
    /// `onStateChange` emits `.startedPlaying` when audio truly begins;
    /// `completion` fires exactly once on every terminal. A new `speak`
    /// supersedes any prior turn (clears its completion so it never fires).
    func speak(
        _ text: String,
        sanitize: Bool,
        onStateChange: (@MainActor @Sendable (SpeechActivity) -> Void)?,
        completion: @escaping @MainActor @Sendable () -> Void
    ) {
        // Supersede any prior turn: tear down its playback WITHOUT firing its
        // completion (the caller has moved on), bump the generation so a late
        // activation/fetch from the prior turn is inert, and abort its in-flight
        // async work.
        stopInFlight()
        inFlight?.cancel()
        inFlight = nil
        generation += 1
        let turn = generation

        let spoken = sanitize ? ReplySanitizer.spoken(text) : text
        guard !spoken.isEmpty else {
            // Empty after sanitize (e.g. an all-emoji reply). Nothing to play —
            // fire the completion so the state machine returns to idle. No
            // `.startedPlaying` (nothing plays).
            completion()
            return
        }

        // Detect the reply's content language ONCE and freeze it for the whole
        // turn — every Apple leg (direct, cloud-fail, chunk-fallback, watchdog)
        // reuses this one hint so a fallback can't flip the voice mid-reply.
        // nil → device voice (Apple's default). Cloud TTS ignores it (providers
        // auto-detect).
        let language = SpeechLanguageDetector.detect(spoken)

        // Freeze the turn's text + language so a mid-play cloud failure can hand
        // the WHOLE reply to Apple (see `currentTurnText`).
        self.currentTurnText = spoken
        self.currentTurnLanguage = language

        // The additive start signal wired to the shared `.startedPlaying`, plus
        // the RAW handler retained for the `.fallbackStarted` transparency signal.
        self.completion = completion
        self.onStart = onStateChange.map { handler in { handler(.startedPlaying) } }
        self.stateChangeHandler = onStateChange

        // Cover the WHOLE pre-audio pipeline with the stall watchdog — armed
        // before the chained category write AND the async activation, so a
        // wedged category IPC or a hung activation is bounded too (mirrors
        // ReplyVoice arming before its snapshot hop).
        armFirstAudioWatchdog(text: spoken, language: language, turn: turn)

        // Take session ownership for this turn — SYNCHRONOUSLY, AFTER the
        // empty-after-sanitize early return (an empty speak must not churn
        // session ownership) and before the chained category write, so the
        // claim is visible to the caller the moment `speak` returns.
        // `stopInFlight()` above released the PRIOR turn's claim (possibly
        // scheduling its deferred deactivation); this claim cancels that
        // pending teardown by the coordinator's contract, so back-to-back
        // speaks never bounce the session through setActive(false).
        let claim = sessionCoordinator.claim(.playback)
        sessionClaim = claim

        // Resolve the active TTS engine from the iPhone-broadcast settings —
        // cheap main-actor reads, no IPC. Cloud-active + key present → fetch +
        // play mp3; else Apple on-device.
        let reader = WatchSettingsReader.shared
        let providerID = reader.activeTTSProviderID
        let provider = TTSProvider.lookup(id: providerID)
        let apiKey = reader.ttsApiKey
        let voice = reader.ttsVoice
        let customModel = reader.ttsCustomModel
        // SPLIT the "cloud provider selected" fact from "a usable key exists" so a
        // cloud provider with NO key on the wrist takes the Apple FALLBACK leg
        // (reason `.missingKey`, marker + `.fallbackStarted`) rather than being
        // silently conflated with an INTENDED-Apple turn. Mirrors `ReplyVoice`'s
        // key-state split.
        let cloudSelected = provider.id != TTSProvider.appleTTS.id
            && provider.bodyFactory != nil
        let hasKey = apiKey?.isEmpty == false
        let useCloud = cloudSelected && hasKey

        // Category + activation are audio-server IPC (hundreds of ms; seconds
        // under a distressed daemon) — `speak` returns here and the IPC runs in
        // a chained task: the category write rides the coordinator's FIFO
        // config lane off-main, and activation issues only after it returns so
        // the session is classified for output first. `.spokenAudio` mode +
        // `.duckOthers` so a music app dips rather than fights the reply.
        Task { @MainActor in
            var configured = true
            do {
                configured = try await self.sessionCoordinator.runConfig(for: claim) {
                    // sharedInstance() resolves INSIDE the closure — the session
                    // object never crosses an isolation boundary.
                    try AVAudioSession.sharedInstance().setCategory(
                        .playback, mode: .spokenAudio, options: [.duckOthers]
                    )
                }
            } catch {
                // The category write threw but the claim was live at issue
                // time. Proceed to activation anyway — it may still succeed on
                // the session's prior category, and the activate completion's
                // failure branch funnels the terminal if it can't.
            }
            // runConfig == false: this turn was superseded while its category
            // op sat queued. The superseding owner holds the session; its own
            // teardown/completion funnels handle state — return silently.
            guard configured else { return }
            // A supersede/terminal may have landed during the await — bail
            // before issuing the activation (the activate completion's own
            // guards remain the second belt). `firstAudioWatchdog != nil` is
            // the pre-audio-phase invariant: the stall watchdog's expiry hands
            // the turn to Apple WITHOUT bumping the generation or clearing the
            // completion (deliberately — the Apple leg reuses both), so the
            // generation/completion guards alone would let a wedged category
            // write that finally unblocks AFTER the handoff proceed and start
            // a cloud leg OVER the already-speaking Apple fallback. The
            // watchdog is armed for the whole pre-audio pipeline and nil the
            // moment any Apple leg begins, so it is exactly the "this turn is
            // still waiting for its cloud phase" signal.
            guard turn == self.generation, self.completion != nil,
                  self.firstAudioWatchdog != nil else { return }

            // watchOS-documented async activation. Speak/play in the completion
            // so the session is genuinely active before output. A late
            // activation from a superseded turn (generation changed) or a
            // cancelled one is inert.
            AVAudioSession.sharedInstance().activate(options: []) { [weak self] activated, _ in
                Task { @MainActor in
                    guard let self else { return }
                    // Same three-part guard as the pre-activation bail above —
                    // `firstAudioWatchdog != nil` keeps a wedged activation
                    // that unblocks after the stall→Apple handoff from
                    // resurrecting a cloud leg over the speaking fallback
                    // (generation/completion survive that handoff by design).
                    guard turn == self.generation, self.completion != nil,
                          self.firstAudioWatchdog != nil else { return }
                    guard activated else {
                        // Activation failed — playback can never begin for THIS
                        // turn. Funnel the exactly-once terminal so the shared
                        // `ThreadSpeaker` returns to idle instead of sitting in
                        // `.loading` forever (stuck spinner on the per-message
                        // control). `fireCompletion()` is nil-then-call, so the
                        // exactly-once invariant holds.
                        self.fireCompletion()
                        return
                    }
                    if useCloud, let apiKey {
                        // LONG replies chunk (head synthesizes + speaks first,
                        // tail synthesizes underneath) so time-to-first-word
                        // stops scaling with reply length; short replies keep
                        // the single-POST path byte-identical.
                        let segments = SpeechSegmenter.segments(for: spoken, policy: .wristConservative)
                        if segments.count > 1 {
                            self.startChunkedTurn(
                                segments: segments, language: language, provider: provider, voice: voice,
                                customModel: customModel, apiKey: apiKey, turn: turn
                            )
                        } else {
                            self.inFlight = Task { @MainActor in
                                await self.speakCloud(spoken, language: language, provider: provider, voice: voice,
                                                      customModel: customModel, apiKey: apiKey, turn: turn)
                            }
                        }
                    } else if cloudSelected {
                        // Cloud provider selected but no key on THIS wrist → Apple
                        // FALLBACK with the honest reason (marker + `.fallbackStarted`).
                        self.speakApple(spoken, language: language, reason: .missingKey)
                    } else {
                        // Apple is the INTENDED engine (apple-tts active, or a
                        // provider with no cloud bodyFactory) — no fallback marker.
                        self.speakApple(spoken, language: language, reason: nil)
                    }
                }
            }
        }
    }

    /// Pause in-flight playback (cloud OR Apple), PRESERVING position so a later
    /// `resume()` continues from the same point — WITHOUT firing the completion
    /// and WITHOUT tearing down the player (no re-synthesis on resume). A no-op
    /// when nothing is playing. Keeps the session claim AND the active session —
    /// deactivation belongs to the turn terminals (`fireCompletion`/`cancel()`/
    /// `stopInFlight()`), so `resume()` continues without re-activation IPC.
    /// Mirrors `SpeechPlayer.pause`.
    func pause() {
        // Suspend the Apple inactivity watchdog (a paused synth emits no
        // progress ticks — expiry would wrongly settle a healthy paused turn).
        // PARTIAL disarm: keep the re-arm closure so `resume()` re-arms this
        // same leg. A no-op on the cloud/chunk path (no closure set).
        appleInactivityWatchdog?.cancel()
        appleInactivityWatchdog = nil
        if let chunkQueue {
            // Queue-wide pause: mid-chunk pauses in place; between chunks the
            // queue parks so a landing fetch can't start audio under the pause.
            chunkQueue.pause()
        } else if let player = audioPlayer {
            player.pause()
        } else if synthesizer.isSpeaking {
            // Pause immediately so tapping pause silences the wrist NOW (not at the
            // next word boundary); `continueSpeaking()` resumes from the pause point.
            synthesizer.pauseSpeaking(at: .immediate)
        }
    }

    /// The engine's REAL playback state right now — read by the shared
    /// `ThreadSpeaker` to reconcile its UI state after watchOS silently suspends
    /// built-in-speaker audio on the ambient dim (no terminal delegate fires, so
    /// the state machine would otherwise stay stuck in `.playing`). Cloud path:
    /// `AVAudioPlayer.isPlaying`; a NON-playing player that hasn't reached the end
    /// is a resumable OS-pause (position preserved, `play()` continues). A player
    /// AT the end is `.inactive` — the natural-finish delegate is about to fire —
    /// with a GENEROUS end tolerance so an optimistic (compressed-file) `duration`
    /// can't misread a done clip as resumable and ghost-replay it. Apple path:
    /// `isPaused` FIRST (a paused synth can still report `isSpeaking == true`),
    /// then `isSpeaking`.
    var playbackStatus: PlaybackStatus {
        if let chunkQueue { return chunkQueue.playbackStatus }
        if let player = audioPlayer {
            // Shared heuristic (single copy of the 0.3 s end tolerance —
            // see `PlaybackStatus.init(cloudPlayer:)` in SpeechChunkQueue).
            return PlaybackStatus(cloudPlayer: player)
        }
        if synthesizer.isPaused { return .pausedResumable }
        if synthesizer.isSpeaking { return .active }
        return .inactive
    }

    /// Resume playback paused by `pause()` from its position with NO re-fetch /
    /// re-synthesis. A no-op when nothing is paused. Mirrors `SpeechPlayer.resume`.
    func resume() {
        if let chunkQueue {
            // Resumes the paused chunk in place, or (paused between chunks)
            // un-parks the queue so the next ready chunk starts. Also covers
            // a SYSTEM-paused player (ambient dim) — `ThreadSpeaker`'s
            // reconcile flips UI state only, then calls `resume()` here.
            chunkQueue.resume()
        } else if let player = audioPlayer {
            player.play()
        } else if synthesizer.isPaused {
            synthesizer.continueSpeaking()
        }
        // Re-arm a live Apple leg's inactivity watchdog suspended by `pause()`
        // (a no-op on the cloud/chunk path — no re-arm closure).
        appleInactivityRearm?()
    }

    /// Hard stop: abandon the current turn WITHOUT firing the completion (the
    /// caller is superseding / leaving). Clears `onStart` + `completion` FIRST so
    /// a late synth `didCancel` delegate is a no-op, bumps the generation +
    /// aborts the in-flight async work so a late activation/fetch is inert, then
    /// stops the synth + player. Releases the session claim — a turn terminal,
    /// so the coordinator schedules the deferred duck-restore deactivation
    /// (stale claim = no-op). Mirrors `ReplyVoice.cancel` / `SpeechPlayer.stop`.
    func cancel() {
        completion = nil
        onStart = nil
        stateChangeHandler = nil
        fallbackPending = false
        currentTurnText = nil
        currentTurnLanguage = nil
        currentUtteranceID = nil
        currentPlayerID = nil
        disarmFirstAudioWatchdog()
        disarmAppleInactivityWatchdog()
        releaseSessionClaim()
        inFlight?.cancel()
        inFlight = nil
        chunkQueue?.cancel()
        chunkQueue = nil
        generation += 1
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        audioPlayer?.stop()
        audioPlayer = nil
    }

    /// Stop any in-flight speech (e.g. user navigates away). The view's
    /// `onDisappear` calls this; delegates to `cancel()` (a hard, completion-less
    /// stop) so there is a single teardown path.
    func stop() {
        cancel()
    }

    // MARK: - Private playback

    /// Fetch cloud audio for `text` and play it via the local `AVAudioPlayer`.
    /// On ANY throw (or a `play()` that won't start) → fall back to Apple (whose
    /// delegate then fires start + completion). The session is already active
    /// (called from inside the activate-completion). `turn` guards a late fetch:
    /// if the generation moved on (supersede) or the task was cancelled, return
    /// without touching the engine.
    private func speakCloud(
        _ text: String,
        language: String?,
        provider: TTSProvider,
        voice: String?,
        customModel: String?,
        apiKey: String,
        turn: Int
    ) async {
        do {
            let data = try await synthesize(text, provider, voice, customModel, apiKey)
            // The fetch may have resolved after a supersede / cancel — bail
            // before touching the player so a stale turn can't restart playback.
            if Task.isCancelled || turn != generation || completion == nil { return }
            let player = try AVAudioPlayer(data: data)
            player.delegate = self
            audioPlayer = player
            currentPlayerID = ObjectIdentifier(player)
            guard player.play() else {
                // Couldn't start playback — fall back to Apple's voice. Playback
                // never began, so don't drop the start signal (Apple's didStart
                // fires it).
                audioPlayer = nil
                currentPlayerID = nil
                WatchLog.note(.state, "tts.fallback", ["reason": "playRefused"])
                speakApple(text, language: language, reason: .unplayableAudio(.startRefused))
                return
            }
            // Playback began. Fire the additive start signal (NOT the completion).
            fireStart()
        } catch {
            // Cloud synthesis / decode failed — Apple is free + always available.
            // Never log the error payload, the text, or the key — the
            // seam already logged the metadata-only cause code.
            if Task.isCancelled || turn != generation || completion == nil { return }
            WatchLog.note(.state, "tts.fallback", ["reason": "synth"])
            speakApple(text, language: language,
                       reason: .fetchFailed(errorCode: (error as? AppError)?.errorCode ?? -1))
        }
    }

    /// Build + start the chunk pipeline for a LONG cloud reply — the same
    /// `SpeechChunkQueue` engine `ReplyVoice` uses, with the wrist's
    /// bounded-tail policy. Terminals funnel into the EXISTING exactly-once
    /// machinery: first audio → `fireStart()` (nil-then-call, so a duplicate
    /// is inert), final chunk → `fireCompletion()`, unplayable chunk → Apple
    /// speaks the UNPLAYED remainder via `speakApple` (whose delegate then
    /// fires start-if-not-yet + completion). Every callback re-checks the
    /// generation token so a superseded turn's late queue event is inert —
    /// same posture as `speakCloud`. The session is already active (activated
    /// once per TURN in `speak`; chunks ride it).
    private func startChunkedTurn(
        segments: [String],
        language: String?,
        provider: TTSProvider,
        voice: String?,
        customModel: String?,
        apiKey: String,
        turn: Int
    ) {
        // Capture the seam VALUE (not self) so the queue's fetch closure
        // doesn't retain the engine (mirrors ReplyVoice's fetcher capture).
        let synthesize = self.synthesize
        let queue = SpeechChunkQueue(
            segments: segments,
            fetch: { _, chunkText in
                try await synthesize(chunkText, provider, voice, customModel, apiKey)
            },
            players: AVChunkPlayerFactory(),
            seamStallTimeout: Self.seamStallGrace,
            onFirstAudio: { [weak self] in
                guard let self, turn == self.generation, self.completion != nil else { return }
                self.fireStart()
            },
            onFinished: { [weak self] in
                guard let self, turn == self.generation else { return }
                self.chunkQueue = nil
                self.fireCompletion()
            },
            onFallback: { [weak self] remaining, _ in
                // Generation guard FIRST (a stale turn must not touch
                // `chunkQueue` — it may already hold the NEW turn's queue),
                // then release the dead queue UNCONDITIONALLY so pause/resume/
                // playbackStatus can't route into it, THEN gate the speak.
                guard let self, turn == self.generation else { return }
                self.chunkQueue = nil
                guard self.completion != nil else { return }
                WatchLog.note(.state, "tts.fallback", ["reason": "chunk"])
                // `speakApple`'s didStart → `fireStart()` — a no-op for the
                // `.startedPlaying` latch if the first chunk already fired it
                // (nil-then-call), but the stored handler still emits
                // `.fallbackStarted` for this mid-turn fallback.
                self.speakApple(remaining, language: language, reason: .chunkFailed)
            }
        )
        chunkQueue = queue
        queue.start()
    }

    /// Speak `text` via Apple's on-device synthesizer — the SINGLE entry point
    /// for every Apple leg, INTENDED (`reason == nil`: apple-tts is the active
    /// engine) or FALLBACK (`reason != nil`: missing key, fetch failure,
    /// unplayable audio, chunk failure, stall). Start + completion are fired by
    /// the synth delegate callbacks. A test-injected `appleLegOverride` receives
    /// the SAME funnels the delegates drive (`fireStart`/`fireCompletion` are
    /// nil-then-call, so a stale or duplicate fake terminal stays inert exactly
    /// like a stale delegate).
    ///
    /// Convergence here makes the guarantees uniform: the FIRST-AUDIO watchdog is
    /// disarmed IMMEDIATELY (never armed concurrently with the inactivity
    /// watchdog → no double-handoff race), the INACTIVITY watchdog is armed for
    /// every leg (dead-leg settlement), and a FALLBACK leg latches
    /// `fallbackPending` so `.fallbackStarted` fires when its audio truly begins.
    private func speakApple(_ text: String, language: String?, reason: TTSFallbackReason?) {
        // Load-bearing: disarm the first-audio watchdog BEFORE arming the
        // inactivity one so the two never overlap near a deadline.
        disarmFirstAudioWatchdog()
        if reason != nil { fallbackPending = true }
        armAppleInactivityWatchdog(turn: generation)

        if let appleLegOverride {
            appleLegOverride(
                text,
                { [weak self] in self?.fireStart() },
                { [weak self] in self?.fireCompletion() }
            )
            return
        }
        // `language` is a BCP-47 content-language hint (nil → device language);
        // a hint with no installed voice degrades to the device-language voice
        // — never nil-voice silence. `reconcile` keeps the device region on a
        // base-language match.
        let deviceCode = AVSpeechSynthesisVoice.currentLanguageCode()
        let requested = SpeechLanguageDetector.reconcile(hint: language, deviceCode: deviceCode) ?? deviceCode
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: requested)
            ?? AVSpeechSynthesisVoice(language: deviceCode)
        currentUtteranceID = ObjectIdentifier(utterance)
        synthesizer.speak(utterance)
    }

    // MARK: - First-audio watchdog

    /// Arm the per-turn stall watchdog (see `firstAudioWatchdog`). The expiry
    /// body re-checks the generation + pending completion, so a disarm/
    /// supersede that ran first makes it inert (all main-actor-serialized —
    /// belt-and-braces with the Task cancellation).
    private func armFirstAudioWatchdog(text: String, language: String?, turn: Int) {
        firstAudioWatchdog?.cancel()
        let timeout = firstAudioTimeout
        WatchLog.info(.state, "tts.watchdog.armed", ["ms": Int(timeout / .milliseconds(1))])
        firstAudioWatchdog = Task { @MainActor [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled, let self else { return }
            self.firstAudioWatchdog = nil
            guard turn == self.generation, self.completion != nil else { return }
            // Kill the stalled leg WITHOUT firing and WITHOUT bumping the
            // generation (the utterance/player identity guards + `inFlight`
            // cancellation already make any late callback inert), then hand
            // the WHOLE reply to Apple — its delegate fires start + completion
            // through the existing exactly-once funnel. Nothing has played yet
            // by definition of first-audio, so the full text (not a remainder)
            // is correct even for a chunked turn.
            WatchLog.note(.state, "tts.watchdog.expired", ["ms": Int(timeout / .milliseconds(1))])
            self.inFlight?.cancel()
            self.inFlight = nil
            self.chunkQueue?.cancel()
            self.chunkQueue = nil
            // A wedged APPLE leg can sit enqueued with `isSpeaking == true` and
            // no `didStart` — stop it (identity cleared FIRST so its `didCancel`
            // is a guarded no-op, not a premature terminal) or the re-speak
            // below would queue behind it and double-speak on recovery. The
            // cloud player is nil-or-unstarted here (a started one disarmed us).
            self.currentUtteranceID = nil
            self.currentPlayerID = nil
            if self.synthesizer.isSpeaking {
                self.synthesizer.stopSpeaking(at: .immediate)
            }
            self.audioPlayer?.stop()
            self.audioPlayer = nil
            // Route through the reason-carrying Apple entry — it arms the
            // inactivity watchdog so even a wedged Apple leg still settles.
            self.speakApple(text, language: language, reason: .stallTimeout)
        }
    }

    /// Disarm sites mirror `ReplyVoice`: first audio (`fireStart`), the turn
    /// terminal (`fireCompletion` — covers the activation-failure branch too),
    /// and `cancel()`/`stopInFlight()` (supersede + teardown). All main-actor,
    /// so arm/fire/disarm are serialized.
    private func disarmFirstAudioWatchdog() {
        firstAudioWatchdog?.cancel()
        firstAudioWatchdog = nil
    }

    // MARK: - Apple inactivity watchdog

    /// (Re-)arm the current Apple leg's inactivity watchdog and remember its
    /// re-arm closure so the progress ticks (`fireStart` via `didStart`, and
    /// `willSpeakRangeOfSpeechString`) plus `resume()` re-enter through it. The
    /// closure re-checks the turn so a superseded leg's stale tick is inert.
    private func armAppleInactivityWatchdog(turn: Int) {
        let rearm: @MainActor () -> Void = { [weak self] in
            guard let self, turn == self.generation, self.completion != nil else { return }
            self.scheduleAppleInactivityExpiry(turn: turn)
        }
        appleInactivityRearm = rearm
        rearm()
    }

    /// Schedule (or reschedule) the inactivity deadline. Expiry — only reachable
    /// when the synth produced NO progress tick for the whole deadline (a wedged
    /// synth, a lost `didFinish`, or a test override that never calls back) —
    /// clears the identities FIRST (so a late delegate is a guarded no-op), stops
    /// the synth + player, logs `tts.gaveup`, then SETTLES the turn via
    /// `fireCompletion()` so the shared `ThreadSpeaker` spinner can never hang.
    /// Guarded on the turn + a pending completion, all main-actor-serialized.
    private func scheduleAppleInactivityExpiry(turn: Int) {
        appleInactivityWatchdog?.cancel()
        let timeout = appleInactivityTimeout
        appleInactivityWatchdog = Task { @MainActor [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled, let self, turn == self.generation, self.completion != nil else { return }
            self.appleInactivityWatchdog = nil
            self.appleInactivityRearm = nil
            self.currentUtteranceID = nil
            self.currentPlayerID = nil
            if self.synthesizer.isSpeaking {
                self.synthesizer.stopSpeaking(at: .immediate)
            }
            self.audioPlayer?.stop()
            self.audioPlayer = nil
            WatchLog.note(.state, "tts.gaveup", [:])
            self.fireCompletion()
        }
    }

    /// Full disarm (terminal / supersede): cancels the watchdog AND drops the
    /// re-arm closure so no leftover progress tick can revive it. `pause()` uses
    /// a PARTIAL disarm (cancels the task, keeps the closure) so `resume()` can
    /// re-arm the same leg.
    private func disarmAppleInactivityWatchdog() {
        appleInactivityWatchdog?.cancel()
        appleInactivityWatchdog = nil
        appleInactivityRearm = nil
    }

    /// Tear down any in-flight playback WITHOUT firing the previous completion
    /// (replacing a clip mid-flight must not invoke the old caller's terminal).
    /// Clears `completion`/`onStart` first so a synth `didCancel` is a no-op.
    /// Releases the prior turn's session claim; on the supersede path the
    /// deferred deactivation this schedules is cancelled by the new `speak`'s
    /// immediate re-claim, so a supersede never bounces the session.
    /// Mirrors `SpeechPlayer.stopInFlight`.
    private func stopInFlight() {
        completion = nil
        onStart = nil
        stateChangeHandler = nil
        fallbackPending = false
        currentTurnText = nil
        currentTurnLanguage = nil
        currentUtteranceID = nil
        currentPlayerID = nil
        disarmFirstAudioWatchdog()
        disarmAppleInactivityWatchdog()
        releaseSessionClaim()
        chunkQueue?.cancel()
        chunkQueue = nil
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        audioPlayer?.stop()
        audioPlayer = nil
    }

    /// Release this turn's session claim through the coordinator's terminal
    /// path — `releaseAndDeactivate`, which schedules the deferred duck-restore
    /// deactivation iff the claim is still live (stale claim = coordinator
    /// no-op). The SINGLE release site for every turn terminal — `cancel()`,
    /// `stopInFlight()`, `fireCompletion()` — mirroring
    /// `WatchRecordingService.releaseSessionClaim` (whose posture differs:
    /// plain `release`, the recorder never deactivates).
    private func releaseSessionClaim() {
        guard let claim = sessionClaim else { return }
        sessionClaim = nil
        sessionCoordinator.releaseAndDeactivate(claim)
    }

    /// Single completion funnel — nil-then-call so a second terminal (a late
    /// `didFinish` after `didCancel`) is a no-op. Releases the cloud player so
    /// the mp3 `Data` is freed, and disarms the watchdog (a terminal without
    /// first audio — e.g. activation failure — must not leave it armed).
    /// Releases the session claim BEFORE invoking the pending completion: the
    /// deferred duck-restore deactivation is scheduled first, so if the
    /// completion triggers the next speak (auto-speak chaining), that turn's
    /// re-claim cancels it and the session never bounces. Mirrors
    /// `SpeechPlayer.fireCompletion`.
    private func fireCompletion() {
        disarmFirstAudioWatchdog()
        disarmAppleInactivityWatchdog()
        let pending = completion
        completion = nil
        onStart = nil
        stateChangeHandler = nil
        fallbackPending = false
        currentTurnText = nil
        currentTurnLanguage = nil
        currentUtteranceID = nil
        currentPlayerID = nil
        audioPlayer = nil
        releaseSessionClaim()
        pending?()
    }

    /// Fire the OPTIONAL "playback began" signal exactly once, then clear it.
    /// PURELY ADDITIVE — not a terminal, doesn't touch `completion`/`audioPlayer`
    /// — but it IS the first-audio moment, so the stall watchdog disarms here.
    /// Mirrors `SpeechPlayer.fireStart`.
    private func fireStart() {
        disarmFirstAudioWatchdog()
        // A synth progress start re-arms the live Apple leg's inactivity
        // watchdog (a no-op on the cloud path — no re-arm closure is set).
        appleInactivityRearm?()
        let started = onStart
        onStart = nil
        started?()
        // A FALLBACK leg's audio has ACTUALLY started — emit the transparency
        // signal through the retained handler. Works mid-turn too (chunk
        // fallback), where the `onStart` latch already fired and is now nil.
        if fallbackPending {
            fallbackPending = false
            stateChangeHandler?(.fallbackStarted)
        }
    }

    // MARK: - AVAudioPlayerDelegate

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let id = ObjectIdentifier(player)
        Task { @MainActor in
            guard self.currentPlayerID == id else { return }
            if flag {
                // Natural end — the reply played to completion.
                self.fireCompletion()
            } else {
                // The clip DIED mid-play — a silently-truncated reply. Treat as a
                // PLAYBACK-FAILURE fallback rather than a terminal.
                self.handlePlaybackFailure()
            }
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        // Decode error mid-playback — the clip stopped short, so the tail is
        // lost. Treat as a PLAYBACK-FAILURE fallback (whole reply re-spoken by
        // Apple) rather than silently funnelling the completion. Never log the
        // error payload.
        let id = ObjectIdentifier(player)
        Task { @MainActor in
            guard self.currentPlayerID == id else { return }
            self.handlePlaybackFailure()
        }
    }

    /// A cloud clip died mid-play (`didFinishPlaying(successfully: false)` or a
    /// decode error). PRESERVE the completion / session claim / stored turn text
    /// + language / state-change handler; clear ONLY the player identity + player
    /// first (so a further stale delegate is a guarded no-op), then hand the
    /// WHOLE stored reply to the Apple voice (a partial repeat is acceptable; a
    /// silently-lost tail is not). Guarded on a pending completion + retained
    /// turn text so a stale/superseded callback is inert. Mirrors `ReplyVoice`'s
    /// `.unplayableAudio(.playbackFailed)` handoff.
    private func handlePlaybackFailure() {
        guard completion != nil, let text = currentTurnText else { return }
        currentPlayerID = nil
        audioPlayer?.stop()
        audioPlayer = nil
        WatchLog.note(.state, "tts.fallback", ["reason": "playback"])
        speakApple(text, language: currentTurnLanguage, reason: .unplayableAudio(.playbackFailed))
    }

    #if DEBUG
    /// TEST SEAM (Debug-only): drive the mid-play playback-failure handoff that a
    /// unit test cannot trigger through a real `AVAudioPlayer` delegate. Routes
    /// through the SAME `handlePlaybackFailure()` the `didFinishPlaying(
    /// successfully: false)` / decode-error delegates call, so the test exercises
    /// the production handoff (clear player → Apple leg speaks the WHOLE reply
    /// with reason `.unplayableAudio(.playbackFailed)` → `.fallbackStarted`).
    func simulatePlaybackFailureForTesting() {
        handlePlaybackFailure()
    }
    #endif

    // MARK: - AVSpeechSynthesizerDelegate

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in
            guard self.currentUtteranceID == id else { return }
            self.fireStart()
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, willSpeakRangeOfSpeechString characterRange: NSRange, utterance: AVSpeechUtterance) {
        // A word-boundary progress tick — re-arm the inactivity watchdog so a
        // genuinely-speaking synth of any length is never cut off (only a leg
        // that goes silent for the whole deadline settles as gave-up).
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in
            guard self.currentUtteranceID == id else { return }
            self.appleInactivityRearm?()
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in
            guard self.currentUtteranceID == id else { return }
            self.fireCompletion()
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in
            guard self.currentUtteranceID == id else { return }
            self.fireCompletion()
        }
    }
}
