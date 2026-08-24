// SPDX-License-Identifier: Apache-2.0

// Conduck
// CarPlayRecordingService.swift
//
// CarPlay multi-turn voice conversation. A PER-SESSION state machine: the audio
// session is activated ONCE at session start, held across every
// listen → STT → think → speak → re-listen turn, and deactivated EXACTLY ONCE
// on every terminal path (else the head unit stays locked in "call" state and
// the driver loses radio/nav).
//
// CarPlay gotcha verification checklist (each MUST be preserved):
//   g1.  `service.beginSession()` runs inside the `presentTemplate` completion —
//        SceneDelegate's `startSession` enforces; the first listen is async.
//   g2.  `INFOPLIST_KEY_UIApplicationSceneManifest_Generation = NO` +
//        hand-authored Info.plist — manager-owned.
//   g3.  Voice template presented MODALLY over a persistent list-picker root
//        (a "voice-as-root" template caused "End exits to the dashboard"):
//        SceneDelegate's `ensureVoicePresented` does `presentTemplate`,
//        `ensureVoiceDismissed` does `dismissTemplate` + deactivates audio IN
//        the dismiss completion. The picker root always exists → the app never
//        falls to the dashboard.
//   g4.  Single fixed 16 kHz mono Float32 tap format — `captureFixedFormat`;
//        `AVAudioConverter` adapts at encoder feed only.
//   g5.  `AVAudioConverter` input block signals `.noDataNow` NEVER `.endOfStream`.
//   g6.  Single `AVAudioEngine` + tap; no `AVAudioRecorder` in parallel.
//   g7.  `MLModelConfiguration.computeUnits` simulator-aware — inside
//        `EndOfSpeechDetector.loadManager()`.
//   g8.  Observe `AVAudioEngineConfigurationChange` AFTER `engine.start()`.
//   g9.  Single audio-session activation per SESSION;
//        never swap category mid-session.
//   g10. `.voiceChat` mode (not `.spokenAudio`) — `CarPlayAudioSession`.
//   g11. No `audio` in `UIBackgroundModes`. The converse hop is a BACKGROUND
//        URLSession (survives suspension); the STT hop stays foreground inside
//        a short `beginBackgroundTask`.
//   g12. `AVSpeechSynthesizer` voice filter `.contains()` on `voiceTraits` —
//        inside `CarPlaySpeechService.selectVoice()`.
//   g13. 10s cold-connect initial-silence guard + 5s follow-up zero-input
//        guard + 300s per-recording hard cap — below; `Constants.maxAudioDuration`.
//
// Session behavior:
// - PER-SESSION lifecycle: `beginSession()` / `endSession(reason:)`; audio
//   activate-once / deactivate-once across all turns.
// - Multi-turn loop: after a spoken reply, wait `carPlayHFPSettleDelay` (~300 ms
//   — skipping it crashes engine.start() with '!obj'), then auto re-arm the mic
//   for the follow-up.
// - Zero-input follow-up timeout (~5s): mic re-armed but no `onSpeechStart` →
//   speak "Talk to you later." and end the session (cabin-noise guard).
// - Agent converse hop: STT success → append `user` turn (`sourceDevice
//   "carplay"`) + stamp pointer + assemble priors → BACKGROUND converse hop
//   (`CarPlayConverseUploader`). The agent turn is appended ONCE by the
//   converse delegate; the delegate routes the reply back here to speak (when
//   foreground + matching) or persist+sync only (unsolicited-audio guard).
// - CarPlay VAD preset: higher threshold + shorter min-silence to
//   reject road/cabin noise.
// - Deleted the fixed `"Done."` terminal — replaced by the agent reply (run
//   through `ReplySanitizer.spoken`).

#if os(iOS)
import Foundation
@preconcurrency import AVFoundation
import CarPlay
import UIKit
import os.log

/// Orchestrates a CarPlay multi-turn voice conversation SESSION.
///
/// Session state machine:
/// ```
/// permissionBlocked ← (mic denied / undetermined at scene connect)
///
/// idle ──(beginSession / row tap)──▶ recording ◀──────────────┐
///                                       │                      │ re-arm
///   ┌── VAD silence ── 5-min cap ──     │                      │ (after
///   ▼                                   ▼                      │  HFP
/// processing ──▶ (background converse) ──▶ speaking ───────────┘  settle)
///   │                                       │
///   │ error                                 │ Stop (end) / silence-timeout (end)
///   ▼                                       ▼
/// idle  ◀───────────── endSession ──────────────  idle
/// ```
/// Every terminal path runs `endSession(...)` exactly once → on the foreground
/// path the scene observer dismisses the voice modal and deactivates audio IN
/// the dismiss completion (returning to the refreshed picker root); on the
/// background/disconnect path the audio session is deactivated DIRECTLY (no
/// dismiss completion fires while backgrounded). Either way: deactivated once.
@MainActor
@Observable
final class CarPlayRecordingService {
    // MARK: - State

    enum State: Equatable {
        case idle
        case recording
        case processing
        case speaking
        /// Mic-muted (call-style): the session is LIVE but the microphone is off
        /// and no silence timer runs, so a muted session is never dropped for
        /// silence. The voice modal stays presented on the "Muted" screen; the
        /// audio route is held. `unmute()` re-arms the mic. NOT `.idle` (which
        /// would dismiss the modal and end the session).
        case muted
        case error(message: String)
        case permissionBlocked(PermissionReason)

        enum PermissionReason: Equatable {
            case undetermined
            case denied
        }
    }

    var state: State = .idle

    /// Whether a multi-turn session is currently live. Drives the scene's
    /// "disable the picker list while a session is active" rule.
    private(set) var sessionActive = false

    /// Process-wide mirror of `sessionActive` (instances are per-CarPlay-scene;
    /// the notification tap has no scene handle). Consumed by
    /// `NotificationDelegate` (via `ReplyAutoSpeakDecider`) so an iOS
    /// notification-tap auto-speak never competes with a live CarPlay voice
    /// session's held audio route. Why a plain Bool mirror can't leak: every
    /// terminal path runs `endSession` exactly once (class invariant — see the
    /// state-machine doc above), and `beginSession`/`endSession` are the ONLY
    /// two mutation sites of either flag, so the mirror flips in lockstep with
    /// the instance flag.
    @MainActor static private(set) var anySessionActive = false

    // MARK: - Voice control template

    private enum VoiceState {
        static let listening = "listening"
        static let processing = "processing"
        static let speaking = "speaking"
        static let muted = "muted"
    }

    @ObservationIgnored
    lazy var voiceControlTemplate: CPVoiceControlTemplate = {
        let listening = CPVoiceControlState(
            identifier: VoiceState.listening,
            titleVariants: [
                // xcstrings
                String(localized: "Listening"),
                // xcstrings
                String(localized: "Speak now")
            ],
            image: nil,
            repeats: false
        )
        let processing = CPVoiceControlState(
            identifier: VoiceState.processing,
            // xcstrings
            titleVariants: [String(localized: "Thinking…")],
            image: nil,
            repeats: false
        )
        let speaking = CPVoiceControlState(
            identifier: VoiceState.speaking,
            // xcstrings
            titleVariants: [String(localized: "Replying")],
            image: nil,
            repeats: false
        )
        let muted = CPVoiceControlState(
            identifier: VoiceState.muted,
            // xcstrings
            titleVariants: [String(localized: "Muted")],
            image: nil,
            repeats: false
        )
        return CPVoiceControlTemplate(voiceControlStates: [listening, processing, speaking, muted])
    }()

    // MARK: - Session state

    /// LOAD-BEARING invariant: `sessionActive`, `currentTurnToken`, and
    /// `isSceneActive` are mutated and read ONLY on the main actor with NO
    /// `await` between a flip and the guarded region that depends on it. The
    /// converse delegate's reply/error handlers re-check all three after their
    /// `@MainActor` hop, so the speak-or-sync decision stays race-free precisely
    /// because these flips are synchronous. Do not introduce a suspension point
    /// between flipping one of these and the code that relies on it.
    ///
    /// Monotonic per-turn token. Minted on each new recording; the converse
    /// delegate carries it so a STALE reply (the session moved on or ended)
    /// never speaks or re-arms — the stale-reply guard. `0` = no live turn.
    @ObservationIgnored private var currentTurnToken: UInt64 = 0

    /// The mint behind `currentTurnToken`, PROCESS-LIFETIME rather than
    /// per-instance. An instance of this service is constructed fresh on every
    /// `didConnect` and dropped on disconnect, while `CarPlayConverseUploader`
    /// is a process singleton whose pending-dispatch cancel claims are KEYED ON
    /// THIS TOKEN. A per-instance counter therefore restarted at 1 on each
    /// reconnect and re-minted tokens an earlier session had already spent:
    /// `endSession` marks its last token cancelled whether or not that turn is
    /// still live, so drive N+1's k-th turn drew a token drive N had already
    /// marked and was dropped before dispatch — no request, no spoken error,
    /// and a ledger row stored `cancelled` for a turn nobody cancelled.
    /// Monotonic across every session in the process, a token is minted at most
    /// once and a stale mark can never name a future turn.
    @MainActor private static var turnTokenCounter: UInt64 = 0

    /// The only mint site. Every token in the process comes from here, so the
    /// "never re-minted" property is one function's to keep.
    @MainActor static func mintTurnToken() -> UInt64 {
        turnTokenCounter &+= 1
        return turnTokenCounter
    }

    /// Tracks the single audio-session activation so deactivate runs EXACTLY
    /// ONCE per session, on whichever terminal path fires first.
    @ObservationIgnored private var audioActivated = false

    /// `true` once the scene reports it's no longer foreground. The converse
    /// reply still completes + syncs (background session), but it is NOT spoken
    /// (the unsolicited-audio guard) and the session ends silently.
    @ObservationIgnored private(set) var isSceneActive = true

    /// Mic-mute state (call-style), per session. When `true` the microphone is
    /// off and the session holds passive on the `.muted` screen — no listening,
    /// no silence sign-off, audio route still held — until `unmute()`. Agent
    /// replies still speak (output is unaffected by a mic-mute). The scene reads
    /// this to label the Mute/Unmute button. Reset on every `endSession`.
    @ObservationIgnored private(set) var isMicMuted = false

    /// The conversation this voice session is bound to (the scene's picker
    /// choice, or the fresh mint on the first turn of a "New voice chat").
    /// CarPlay session state is its own lane: it NEVER touches the shared
    /// per-device quick-capture pointer (implicit-only — a drive must not
    /// retarget the Action-Button/menu-bar thread). In-memory only, by design:
    /// the relaunch reply path rides the converse task metadata
    /// (`RemoteAgentBackgroundMetadata.conversationID`), and a relaunched
    /// process can't resume a live voice session anyway, so persisting this
    /// would buy nothing. Cleared on every `endSession` / `teardown`.
    @ObservationIgnored private(set) var sessionConversationID: UUID?

    /// The EFFECTIVE CarPlay default ref for this session (the scene's
    /// session-local override for this drive, else the iPhone's device-local
    /// default), captured at `beginSession`. The NEW-conversation mint in
    /// `startConverseHop` routes on THIS instead of reading the global default,
    /// so a CarPlay gateway switch is this-drive-only and never re-points the
    /// phone/iPad/Mac. Existing-conversation routing (reads `Conversation.backend`)
    /// ignores it. In-memory only; cleared on every `endSession` / `teardown`.
    @ObservationIgnored private(set) var sessionDefaultRef: RemoteAgentRef?

    /// The ref this session's turns ACTUALLY dispatch over — the conversation's
    /// bound gateway, which is `sessionDefaultRef` only on a fresh mint and is
    /// whatever `Conversation.backend` says when the picker resumed an existing
    /// thread. Recorded by `startConverseHop` the moment routing resolves, and
    /// read ONLY by `speakErrorAndEnd`, whose model arms must dispatch on the
    /// capabilities of the AI that failed rather than on the drive's default.
    /// Nil until the first turn routes → `.neutral` copy, which is the wording
    /// those arms already spoke. In-memory; cleared on `endSession` / `teardown`.
    @ObservationIgnored private var sessionBoundRef: RemoteAgentRef?

    /// Live "is the voice modal still presented?" query, injected by the scene
    /// delegate (reads `interfaceController.presentedTemplate`). The re-arm loop
    /// consults it before re-listening so it self-heals if the voice modal was
    /// dismissed by a path that didn't end the session (the SDK's modal
    /// lifecycle on `CPVoiceControlTemplate` is empirically unreliable — see
    /// the scene's `templateDidDisappear`). Nil → assume presented (treat the
    /// missing wiring as a no-op, never as "modal gone").
    @ObservationIgnored var isVoiceModalPresented: (@MainActor () -> Bool)?

    // MARK: - Recording state

    private var captureEngine: AVAudioEngine?
    private var captureFile: AVAudioFile?
    private var recordingURL: URL?
    private var recordingStartedAt: Date?
    private var recordingMaxDurationTimer: Timer?
    private var initialSilenceTimer: Timer?
    private var endOfSpeechDetector: EndOfSpeechDetector?
    private var engineConfigChangeObserver: NSObjectProtocol?

    /// Cold-connect / first-turn initial-silence guard (g13). The first
    /// VAD `.speechStart` cancels it.
    private static let initialSilenceTimeout: TimeInterval = 10

    /// g4. Fixed capture format — 16 kHz mono Float32.
    private static let captureFixedFormat: AVAudioFormat = {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        ) else {
            fatalError("AVAudioFormat 16 kHz mono Float32 unavailable")
        }
        return format
    }()

    nonisolated private static let log = Logger(subsystem: Constants.identityNamespace, category: "CarPlayCapture")

    /// One-line audio diagnostic for a failed `configureAndActivate()` /
    /// `engine.start()` — surfaces the real OSStatus (the start-failure path now
    /// ends the session SILENTLY rather than speaking over a wedged session), so
    /// a sim/head-unit run can distinguish a wrong-thread start, a route/HFP
    /// refusal (FourCC 'nope' 1852797029), and a genuine session-config error.
    /// Device-audio facts ONLY (never audio / transcript / URL / token).
    nonisolated private static func audioDiag(_ error: Error) -> String {
        let ns = error as NSError
        let s = AVAudioSession.sharedInstance()
        let inputs = s.currentRoute.inputs.map(\.portType.rawValue).joined(separator: ",")
        return "domain=\(ns.domain) code=\(ns.code) main=\(Thread.isMainThread) "
            + "cat=\(s.category.rawValue) mode=\(s.mode.rawValue) "
            + "inputAvailable=\(s.isInputAvailable) inputs=[\(inputs)]"
    }

    // MARK: - System hooks

    /// Short background task wrapping the FOREGROUND STT hop only (the converse
    /// hop runs on a background URLSession that needs no `beginBackgroundTask`).
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var interruptionObserver: NSObjectProtocol?
    /// DIAGNOSTIC (CarPlay dashboard-fall investigation): observes audio
    /// route changes so we can see whether a route renegotiation fires right
    /// before a `sceneWillResignActive`. Log-only — no behavior change.
    private var routeChangeObserver: NSObjectProtocol?

    /// Observes `mediaServicesWereResetNotification`. When `mediaserverd` is torn
    /// down (the `Connection invalidated` / `IPCAUClient can't connect` cascade
    /// a failed `engine.start()` can trigger on CarPlay), EVERY audio object is
    /// invalid; Apple requires disposing + recreating them before reuse.
    private var mediaResetObserver: NSObjectProtocol?

    // MARK: - Init / deinit

    init() {
        setupInterruptionObserver()
        setupRouteChangeObserver()
        setupMediaResetObserver()
        refreshPermission()
    }

    /// Explicit teardown from the scene delegate's `didDisconnect`.
    func teardown() {
        if let observer = interruptionObserver {
            NotificationCenter.default.removeObserver(observer)
            interruptionObserver = nil
        }
        if let observer = routeChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            routeChangeObserver = nil
        }
        if let observer = mediaResetObserver {
            NotificationCenter.default.removeObserver(observer)
            mediaResetObserver = nil
        }
        // Ensure the session is fully torn down. The scene is disconnecting, so
        // no dismiss completion will fire — free the audio session DIRECTLY
        // (idempotent; deactivate-exactly-once preserved).
        if sessionActive {
            endSession(speak: nil)
        }
        deactivateAudioSession()
        endBackgroundTask()
        invalidateTimers()
        tearDownCapture()
        CarPlayConverseUploader.shared.setActiveService(nil)
        // Belt-and-braces: `endSession` above already cleared these when a session
        // was live; this covers a disconnect with no live session (idempotent).
        sessionConversationID = nil
        sessionDefaultRef = nil
        sessionBoundRef = nil
    }

    // MARK: - Permission

    func refreshPermission() {
        let status = AVAudioApplication.shared.recordPermission
        switch status {
        case .granted:
            if case .permissionBlocked = state {
                state = .idle
            }
        case .denied:
            state = .permissionBlocked(.denied)
        case .undetermined:
            state = .permissionBlocked(.undetermined)
        @unknown default:
            state = .permissionBlocked(.denied)
        }
    }

    // MARK: - Scene activity (drives the unsolicited-audio guard)

    /// The scene delegate reports foreground/background transitions. When the
    /// app backgrounds mid-session (driver → Maps), the in-flight converse hop
    /// still completes + syncs, but the reply is NOT spoken and the session
    /// ends silently.
    func setSceneActive(_ active: Bool) {
        isSceneActive = active
        if !active, sessionActive {
            // Backgrounded mid-session: end silently. The in-flight converse
            // (if any) still completes + syncs via the background session; its
            // reply takes the persist-only path (handleBackgroundReply guards
            // on `isSceneActive`). `endSession` cancels any in-flight reply
            // TTS at its top — so a live chunk queue can't keep fetching /
            // starting audio from the background after the deactivate below.
            endSession(speak: nil)
            // Background path: no dismiss completion will fire (the scene is
            // backgrounded and may have torn the modal down), so free the audio
            // session DIRECTLY here. Idempotent — a later dismiss-completion
            // call is a safe no-op; this keeps "deactivate exactly once".
            deactivateAudioSession()
        }
    }

    // MARK: - Public API — session lifecycle

    /// Begin a new multi-turn session. Activates the audio session ONCE,
    /// registers as the converse-reply speak target, and starts the first
    /// listen. No-op unless `.idle`. `conversationID` is the scene picker's
    /// choice (nil = "New voice chat" → the first turn mints fresh on
    /// `defaultRef`); it seeds the in-memory session lane — see
    /// `sessionConversationID`.
    ///
    /// `defaultRef` is the EFFECTIVE CarPlay ref the scene resolved (its
    /// session-local override for this drive, else the iPhone's device-local
    /// default). Stashed on the service so a NEW-conversation mint uses it
    /// instead of reading the global default — so a CarPlay gateway switch
    /// stays in-car and never re-points the phone/iPad/Mac. Existing-conversation
    /// routing (reads `Conversation.backend`) ignores it. Cleared on `endSession`.
    func beginSession(conversationID: UUID?, defaultRef: RemoteAgentRef) {
        guard state == .idle, !sessionActive else { return }
        sessionConversationID = conversationID
        sessionDefaultRef = defaultRef
        sessionActive = true
        // Keep the process-wide mirror in lockstep (see `anySessionActive`).
        Self.anySessionActive = true
        CarPlayConverseUploader.shared.setActiveService(self)
        Task { await startListening(isFollowUp: false) }
    }

    /// Driver tapped the stable "End" button — end the session in ANY state.
    /// Cancels any in-flight TTS first, then runs the deactivate-once teardown
    /// (`endSession` guards on `sessionActive`, so this is safe in recording /
    /// processing / speaking and a no-op when no session is live). No TTS.
    func endFromButton() {
        CarPlaySpeechService.shared.cancel()
        endSession(speak: nil)
    }

    /// Driver tapped the stable "Mute" / "Unmute" button — mic-mute, call-style.
    /// The scene delegate reads `isMicMuted` after this returns to label/icon the
    /// button.
    func toggleMute() {
        if isMicMuted {
            unmute()
        } else {
            mute()
        }
    }

    /// Mute the MICROPHONE: stop listening and hold the session passive. Cancels
    /// the silence timer so a muted session is NEVER signed off for not talking
    /// (the bug a TTS-mute caused). The audio route stays held (call-style) — we
    /// stop the capture engine, not the session — so `unmute()` re-arms without a
    /// re-activation race. Agent replies in flight still land + speak (output is
    /// unaffected); the speak-completion routes to `.muted` instead of re-arming.
    private func mute() {
        guard sessionActive, !isMicMuted else { return }
        isMicMuted = true
        // Never drop a muted session for silence.
        invalidateTimers()
        if state == .recording {
            // We were listening — stop the mic now and discard the partial. Keep
            // the audio session ACTIVE (route held); mute toggles capture only.
            tearDownCapture()
            // Delete the orphaned partial-capture temp file (audio cleanup —
            // every discard path removes it; mute-while-recording must too).
            if let url = recordingURL {
                try? FileManager.default.removeItem(at: url)
            }
            recordingStartedAt = nil
            recordingURL = nil
            state = .muted
            voiceControlTemplate.activateVoiceControlState(withIdentifier: VoiceState.muted)
        }
        // If `.processing` / `.speaking`: leave state as-is so the in-flight reply
        // still lands + speaks; its speak-completion sees `isMicMuted` and parks
        // on `.muted` rather than re-arming.
    }

    /// Unmute: resume listening. The audio session was held active across the
    /// mute, so `reArmAfterSettle` re-arms the engine (with the modal-presence
    /// self-heal + HFP settle) without re-activating the session.
    private func unmute() {
        guard sessionActive, isMicMuted else { return }
        isMicMuted = false
        Task { await reArmAfterSettle() }
    }

    // MARK: - Listen

    /// g6/g4/g8. Build the single capture engine + tap + VAD, start the
    /// engine, transition to `.recording`. `isFollowUp` selects the silence
    /// guard: the cold-connect first listen uses the 10s initial-silence
    /// timeout; a re-armed follow-up uses the shorter 5s zero-input timeout,
    /// after which the session signs off ("Talk to you later.").
    private func startListening(isFollowUp: Bool) async {
        guard sessionActive else { return }

        // Activate the audio session ONCE for the whole session (idempotent if
        // a route renegotiation already re-activated it).
        var didActivateNow = false
        if !audioActivated {
            do {
                try CarPlayAudioSession.configureAndActivate()
                audioActivated = true
                didActivateNow = true
            } catch {
                Self.log.error("CarPlay configureAndActivate failed: \(Self.audioDiag(error), privacy: .public)")
                // End SILENTLY (no error TTS): there is no usable session to
                // speak on, and speaking over a half-activated session is what
                // escalates a recoverable start failure into a `mediaserverd`
                // teardown + CarPlay-scene drop. The modal dismissing back to the
                // picker is the feedback. (See `startCaptureEngineWithRetry`.)
                endSession(speak: nil)
                return
            }
        }

        // First listen of a session: let the HFP/route context settle before
        // starting the engine. A COLD cross-session start (the prior session's
        // `setActive(false, .notifyOthersOnDeactivation)` tore the HFP route
        // down) reacquires RemoteIO from scratch and needs a LONGER settle than
        // the in-session re-arm — `engine.start()` is otherwise refused with
        // FourCC 'nope' (1852797029). The re-arm path (`reArmAfterSettle`) keeps
        // the shorter `carPlayHFPSettleDelay`; either shortfall is also caught by
        // the retry/recovery below.
        if didActivateNow {
            try? await Task.sleep(for: .seconds(Constants.carPlayColdStartSettleDelay))
            guard sessionActive else { return }
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("carplay_\(UUID().uuidString).caf")

        // The capture file + VAD detector are built ONCE and REUSED across engine
        // retries — the VAD model load is costly, and the engine is the only part
        // the RemoteIO race kills. Any failure here ends the session SILENTLY
        // (same reasoning as the activation catch above).
        let fixedFormat = Self.captureFixedFormat
        let captureFile: AVAudioFile
        do {
            captureFile = try AVAudioFile(
                forWriting: url,
                settings: fixedFormat.settings,
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
        } catch {
            endSession(speak: nil)
            return
        }

        // CarPlay VAD preset: higher threshold + shorter min-silence to
        // reject road/cabin noise.
        let detector = EndOfSpeechDetector(
            threshold: Constants.carPlayVADThreshold,
            minSilence: Constants.carPlayVADMinSilence,
            onSpeechStart: { [weak self] in
                self?.initialSilenceTimer?.invalidate()
                self?.initialSilenceTimer = nil
            },
            onEndOfSpeech: { [weak self] in
                guard let self, self.state == .recording else { return }
                Task { await self.endRecordingForUpload() }
            }
        )
        do {
            try await detector.start()
        } catch {
            try? FileManager.default.removeItem(at: url)
            endSession(speak: nil)
            return
        }

        // Build + start the capture engine with bounded recover-and-retry, then
        // commit instance state only on success. On final failure end SILENTLY —
        // the retry path NEVER speaks an error over a wedged session.
        guard let engine = await startCaptureEngineWithRetry(
            captureFile: captureFile,
            fixedFormat: fixedFormat,
            detector: detector
        ) else {
            detector.stop()
            try? FileManager.default.removeItem(at: url)
            // Recovery may have ended the session (End / disconnect mid-retry) —
            // only end here if it is still live.
            if sessionActive { endSession(speak: nil) }
            return
        }

        // g8: observe reconfig only AFTER a successful start, on the engine
        // that actually started.
        engineConfigChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleEngineConfigurationChange()
            }
        }

        self.captureEngine = engine
        self.captureFile = captureFile
        self.endOfSpeechDetector = detector
        self.recordingURL = url
        self.recordingStartedAt = Date()
        state = .recording
        scheduleMaxDurationTimer()
        scheduleSilenceTimer(isFollowUp: isFollowUp)
    }

    /// Build a fresh `AVAudioEngine`, install the capture tap, and `start()` it —
    /// retrying with escalating recovery when the start is refused by the CarPlay
    /// HFP RemoteIO reacquisition race (FourCC 'nope' 1852797029, and the related
    /// '!obj'/'!int' route refusals). Returns the running engine, or nil once the
    /// attempt budget is exhausted — the caller then ends the session SILENTLY,
    /// because speaking the error over a wedged session is exactly what drops the
    /// CarPlay scene (`mediaserverd` `Connection invalidated`).
    ///
    /// Escalation: attempt 0 uses the settle the caller already applied; attempts
    /// 1+ do a HARD recovery — an internal deactivate (NO `.notifyOthersOnDeactivation`
    /// — see `CarPlayAudioSession.deactivateForRecovery`) + reactivate + settle —
    /// to clear the wedged `mediaserverd`/RemoteIO connection the failed start
    /// left behind. (A soft config re-assert does NOT clear it: the failing-trace
    /// gap was ~33 s, so the cross-session refusal is a wedged-state problem, not
    /// a wait-time one — only a deactivate/reactivate cycle recovers it.) `guard
    /// sessionActive` between awaits so an End / disconnect mid-recovery bails
    /// cleanly. The `captureFile` + `detector` are reused across attempts (each
    /// attempt builds its own engine + tap).
    private func startCaptureEngineWithRetry(
        captureFile: AVAudioFile,
        fixedFormat: AVAudioFormat,
        detector: EndOfSpeechDetector
    ) async -> AVAudioEngine? {
        let maxAttempts = 3
        for attempt in 0..<maxAttempts {
            guard sessionActive else { return nil }

            if attempt >= 1 {
                // Hard recovery: internal deactivate (no notify-others) +
                // reactivate to clear a wedged RemoteIO/`mediaserverd` connection.
                // `audioActivated` deliberately stays TRUE across the whole cycle:
                // it gates the owed TERMINAL release (`.notifyOthersOnDeactivation`),
                // NOT the transient internal active/inactive state. If the
                // reactivate below throws (session left inactive), keeping it true
                // ensures the terminal `deactivateAudioSession()` still fires its
                // notify-others release so ducked apps resume — else the head unit
                // can stay wedged (the radio/nav-stuck mode the deactivate-once
                // invariant guards). A redundant `setActive(false)` on an
                // already-inactive session there is a benign, logged no-op.
                try? CarPlayAudioSession.deactivateForRecovery()
                try? await Task.sleep(for: .seconds(Constants.carPlayColdStartSettleDelay))
                guard sessionActive else { return nil }
                do {
                    try CarPlayAudioSession.configureAndActivate()
                } catch {
                    Self.log.error("CarPlay recovery re-activate failed (attempt \(attempt, privacy: .public)): \(Self.audioDiag(error), privacy: .public)")
                    continue
                }
                try? await Task.sleep(for: .seconds(Constants.carPlayColdStartSettleDelay))
                guard sessionActive else { return nil }
            }

            let engine = AVAudioEngine()
            let nativeFormat = engine.inputNode.outputFormat(forBus: 0)
            guard nativeFormat.sampleRate > 0, nativeFormat.channelCount > 0 else {
                Self.log.error("CarPlay degenerate input format (attempt \(attempt, privacy: .public))")
                continue
            }
            guard Self.installCaptureTap(
                engine: engine,
                inputFormat: nativeFormat,
                fixedFormat: fixedFormat,
                captureFile: captureFile,
                detector: detector
            ) else {
                continue
            }
            do {
                engine.prepare()
                try engine.start()
                let session = AVAudioSession.sharedInstance()
                Self.log.info("CarPlay engine.start OK (attempt \(attempt, privacy: .public)); main=\(Thread.isMainThread, privacy: .public) inputs=[\(session.currentRoute.inputs.map(\.portType.rawValue).joined(separator: ","), privacy: .public)]")
                return engine
            } catch {
                Self.log.error("CarPlay engine.start failed (attempt \(attempt, privacy: .public)): \(Self.audioDiag(error), privacy: .public)")
                engine.inputNode.removeTap(onBus: 0)
                engine.stop()
            }
        }
        Self.log.error("CarPlay engine.start exhausted \(maxAttempts, privacy: .public) attempts; ending session silently")
        return nil
    }

    /// Arm the no-speech guard. First listen → 10s cold-connect cancel (silent).
    /// Follow-up → 5s zero-input timeout that signs off and ends the session.
    private func scheduleSilenceTimer(isFollowUp: Bool) {
        initialSilenceTimer?.invalidate()
        let timeout = isFollowUp
            ? Constants.carPlayFollowUpSilenceTimeout
            : Self.initialSilenceTimeout
        initialSilenceTimer = Timer.scheduledTimer(
            withTimeInterval: timeout,
            repeats: false
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.state == .recording else { return }
                if isFollowUp {
                    Self.log.info("Follow-up zero-input timeout; signing off")
                    // xcstrings
                    self.endSession(
                        speak: String(localized: "Talk to you later.")
                    )
                } else {
                    Self.log.info("Cold-connect initial silence; ending session")
                    self.endSession(speak: nil)
                }
            }
        }
    }

    // MARK: - Capture tap (g4 / g5 / g8)

    private static func installCaptureTap(
        engine: AVAudioEngine,
        inputFormat: AVAudioFormat,
        fixedFormat: AVAudioFormat,
        captureFile: AVAudioFile,
        detector: EndOfSpeechDetector
    ) -> Bool {
        guard let converter = AVAudioConverter(from: inputFormat, to: fixedFormat) else {
            log.error("AVAudioConverter \(inputFormat.sampleRate, privacy: .public)Hz → 16 kHz failed")
            return false
        }

        var rawTapCount = 0

        engine.inputNode.installTap(
            onBus: 0,
            bufferSize: 4096,
            format: inputFormat
        ) { [weak detector] buffer, _ in
            if rawTapCount < 5 {
                rawTapCount += 1
                log.info("RAW tap #\(rawTapCount, privacy: .public) frames=\(buffer.frameLength, privacy: .public) rate=\(buffer.format.sampleRate, privacy: .public)Hz \(buffer.format.channelCount, privacy: .public)ch")
            }
            guard let converted = convertToFixedFormat(
                buffer,
                using: converter,
                outputFormat: fixedFormat
            ) else { return }
            try? captureFile.write(from: converted)
            detector?.processFixedBuffer(converted)
        }
        return true
    }

    /// g5. Resample to the fixed format. `.noDataNow` (NOT `.endOfStream`).
    private nonisolated static func convertToFixedFormat(
        _ input: AVAudioPCMBuffer,
        using converter: AVAudioConverter,
        outputFormat: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        let inputSampleRate = input.format.sampleRate
        guard inputSampleRate > 0 else { return nil }

        let outputCapacity = AVAudioFrameCount(
            ceil(Double(input.frameLength) * outputFormat.sampleRate / inputSampleRate)
        )
        guard outputCapacity > 0,
              let output = AVAudioPCMBuffer(
                  pcmFormat: outputFormat,
                  frameCapacity: outputCapacity
              ) else { return nil }

        var error: NSError?
        var supplied = false
        let status = converter.convert(to: output, error: &error) { _, outStatus in
            if supplied {
                outStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            outStatus.pointee = .haveData
            return input
        }

        guard status != .error, error == nil, output.frameLength > 0 else {
            return nil
        }
        return output
    }

    /// g8. React to an `AVAudioEngineConfigurationChange` mid-recording.
    @MainActor
    private func handleEngineConfigurationChange() {
        guard state == .recording,
              let engine = captureEngine,
              let captureFile = self.captureFile,
              let detector = endOfSpeechDetector else {
            return
        }

        let newFormat = engine.inputNode.outputFormat(forBus: 0)
        Self.log.info("Engine reconfig: new input \(newFormat.sampleRate, privacy: .public)Hz \(newFormat.channelCount, privacy: .public)ch")

        guard newFormat.sampleRate > 0, newFormat.channelCount > 0 else {
            Self.log.error("Reconfig delivered degenerate format; ending turn")
            Task { await self.endRecordingForUpload() }
            return
        }

        engine.inputNode.removeTap(onBus: 0)

        guard Self.installCaptureTap(
            engine: engine,
            inputFormat: newFormat,
            fixedFormat: Self.captureFixedFormat,
            captureFile: captureFile,
            detector: detector
        ) else {
            Self.log.error("Tap reinstall failed after reconfig; ending turn")
            Task { await self.endRecordingForUpload() }
            return
        }

        if !engine.isRunning {
            do {
                try engine.start()
                Self.log.info("Engine restarted after reconfig")
            } catch {
                // Reduced to the NSError domain/code — never
                // `localizedDescription`. This file also does STT networking, so
                // an error text logged here can carry the user's gateway or
                // custom-endpoint hostname into the unified log (and from there
                // into any sysdiagnose attached to a public issue). Domain + code
                // are numbers/constants and cannot. Same reduction the two share
                // extensions use; it is what lets this file leave
                // `LoggingPrivacyDriftGuardTests.errorTextVettedFileNames`.
                let nsError = error as NSError
                Self.log.error("Engine restart failed after reconfig: \(nsError.domain, privacy: .public) \(nsError.code, privacy: .public)")
                Task { await self.endRecordingForUpload() }
            }
        }
    }

    /// Stop the capture engine, remove the tap, release the file. Idempotent.
    /// Does NOT deactivate the audio session — that is session-scoped.
    private func tearDownCapture() {
        if let observer = engineConfigChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            engineConfigChangeObserver = nil
        }
        if let engine = captureEngine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        captureEngine = nil
        captureFile = nil
        endOfSpeechDetector?.stop()
        endOfSpeechDetector = nil
    }

    /// g13. Per-recording hard cap (`Constants.maxAudioDuration`, 300s).
    private func scheduleMaxDurationTimer() {
        recordingMaxDurationTimer?.invalidate()
        recordingMaxDurationTimer = Timer.scheduledTimer(
            withTimeInterval: Constants.maxAudioDuration,
            repeats: false
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.state == .recording else { return }
                await self.endRecordingForUpload()
            }
        }
    }

    private func endRecordingForUpload() async {
        guard state == .recording else { return }
        await processRecording()
    }

    // MARK: - STT hop (foreground) + converse dispatch

    /// Compress → STT (foreground, short background-task wrap) → on success
    /// append the user turn + stamp the pointer + assemble priors + start the
    /// BACKGROUND converse hop. Stays in `.processing` ("Thinking…") while the
    /// converse hop runs; the converse delegate routes the reply back to
    /// `speakReply(...)` (foreground + matching) or persist-only.
    private func processRecording() async {
        guard let url = recordingURL else {
            // xcstrings
            endSession(speak: String(localized: "Couldn't save — try again."))
            return
        }

        invalidateTimers()
        tearDownCapture()

        let audioData: Data
        do {
            audioData = try Data(contentsOf: url)
            try? FileManager.default.removeItem(at: url)
        } catch {
            // xcstrings
            endSession(speak: String(localized: "Couldn't save — try again."))
            return
        }

        state = .processing
        voiceControlTemplate.activateVoiceControlState(withIdentifier: VoiceState.processing)
        beginBackgroundTask()

        let compression = await AudioCompressor.compress(audioData)

        let cachedKey = CarPlaySettings.shared.sttAPIKey
        let cachedLanguage = CarPlaySettings.shared.preferredLanguage
        // Per-preset custom model override (Feature 1). Cached atomically in
        // `CarPlaySettings.refreshFromSettings()` so it pairs with the active
        // preset; threaded into `transcribe(customModel:)` below so a Gemini /
        // Qwen override applies on the in-car surface too. The BYO custom
        // endpoint (`customConfig`) is not cached for CarPlay at V1.
        let cachedCustomModel = CarPlaySettings.shared.customModel
        // Bound ONCE, then reused for both the provider lookup and the key
        // re-read below, so the live Keychain read can only ever name the preset
        // this turn resolved.
        let cachedPresetID = CarPlaySettings.shared.activePresetID
        let provider = STTProvider.lookup(id: cachedPresetID)

        // BYO custom endpoint — excluded on CarPlay at V1 (no `customConfig`
        // is cached here, so the transcribe would throw
        // `sttCustomEndpointNotConfigured` anyway). Speak the ACCURATE copy
        // up front: with `.none` keyless auth there is no key to add, so the
        // missing-key prompt below would be misleading.
        if provider.dynamicEndpointKey != nil {
            // xcstrings: hardening
            endSession(
                speak: String(localized: "Custom voice endpoints aren't available in the car. Pick another provider in Conduck on your iPhone.")
            )
            return
        }

        // The key question through `STTKeyReadiness`, the same helper every other
        // refusal lane uses — in-process providers (Apple on-device, authorised
        // by TCC) need no key at all and that arm lives inside its `requiresKey`,
        // so this is one call and not two branches. `customConfig` is nil because
        // a dynamic-endpoint preset returned above; for every preset that reaches
        // here `requiresKey` ignores it.
        //
        // RE-RESOLVED at capture time, not read off the cache. `CarPlaySettings`
        // lives for the whole process and refreshes only at launch and on a
        // settings change, so a launch that happened before first unlock caches a
        // nil that no unlock ever clears — and the driver would hear "add your
        // STT key" for every capture of the drive, with the key sitting correctly
        // on the phone in their pocket. `resolve` short-circuits on a usable
        // cached key, so the happy path still never enters the Keychain from
        // CarPlay scene context (the stall this cache exists to avoid); only the
        // path that is about to refuse pays for a live read.
        let readiness = await STTKeyReadiness.resolve(
            presetID: cachedPresetID,
            snapshotKey: cachedKey,
            provider: provider,
            customConfig: nil
        )
        let apiKey: String
        switch readiness {
        case .ready(let key):
            apiKey = key
        case .notConfigured:
            // PROVABLE absence — the only reading this sentence is true of.
            // xcstrings
            endSession(
                speak: String(localized: "Add your STT key in Conduck on your iPhone.")
            )
            return
        case .unreadable:
            // The Keychain could not answer. Never "add your key": the driver
            // may well have one, and telling them to go and add it while they
            // are driving is both false and useless. Says what to do instead,
            // and names the device — CarPlay runs on the iPhone, so the phone in
            // the dock or the pocket is what has to be unlocked.
            //
            // The unlock is HEDGED, exactly as code 75's shared copy hedges it,
            // because a locked Keychain is only the common reading of
            // `.unreadable`: `APIKeyReadResult.classify` also lands an auth
            // failure, an IPC error and an `errSecDecode` payload here. An
            // unconditional "unlock your iPhone" would send a driver whose phone
            // is already unlocked to do the one thing that cannot help, once per
            // capture, for the rest of the drive. Kept to one short conditional
            // because this line is HEARD — a driver cannot re-read it.
            //
            // The capture itself is lost either way: CarPlay has no preservation
            // mechanism at all — no `PendingRetryStore` write, no queue — so
            // "try again" means speak again, which is exactly what the driver
            // can do once the phone is unlocked.
            // xcstrings
            endSession(
                speak: String(localized: "Couldn't read your STT key. If your iPhone just restarted, unlock it and try again.")
            )
            return
        }

        let uploadURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("carplay_upload_\(UUID().uuidString).m4a")
        do {
            try compression.data.write(to: uploadURL, options: .atomic)
        } catch {
            // xcstrings
            endSession(speak: String(localized: "Couldn't save — try again."))
            return
        }

        do {
            let response = try await STTClient.shared.transcribe(
                audioFileURL: uploadURL,
                apiKey: apiKey,
                language: cachedLanguage,
                provider: provider,
                customModel: cachedCustomModel
            )
            // Privacy invariant: never log the transcript text.
            Self.log.info("STT success: \(response.text.count, privacy: .public) chars")

            // STT hop landed — the converse hop is a background URLSession that
            // needs no `beginBackgroundTask`; release the short wrap now.
            endBackgroundTask()

            let transcript = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !transcript.isEmpty else {
                // The user DID speak (VAD endpointed real audio) but STT
                // returned nothing — say so instead of silently dismissing
                // the modal (the VAD no-speech path already speaks; this
                // empty-transcript path didn't). Same copy as
                // `speakErrorAndEnd(.noSpeechDetected)`.
                // xcstrings
                endSession(speak: String(localized: "Didn't catch that — try again."))
                return
            }

            await startConverseHop(transcript: transcript)

        } catch let error as AppError {
            // NO ref on purpose, both arms: only the STT hop throws into here
            // (`startConverseHop` above owns its own catch and never rethrows),
            // so the machine that failed is the speech provider and no gateway
            // capability is in play. `nil` → `.neutral`, today's wording.
            endBackgroundTask()
            speakErrorAndEnd(error)
        } catch {
            endBackgroundTask()
            speakErrorAndEnd(.unknown(error))
        }
    }

    /// Resolve-or-create the session's conversation, append the user turn,
    /// assemble client-owned priors, mint a fresh turn token, and start the
    /// BACKGROUND converse hop. Stays in `.processing`.
    private func startConverseHop(transcript: String) async {
        do {
            // CarPlay continuation is EXPLICIT + session-scoped: the scene's
            // picker seeded `sessionConversationID` at session start, and a live
            // voice session keeps that one thread across all turns even under
            // the `alwaysNew` policy (which governs only headless quick
            // captures, not CarPlay). The session lane is in-memory only and
            // never reads or writes the shared quick-capture pointer — see
            // `sessionConversationID`.
            //
            // REORDER (per-conversation routing): resolve-or-mint the conversation
            // FIRST, then route by ITS bound backend. The "New voice chat" path
            // seeded nil → mint a fresh conversation on the DEFAULT backend; an
            // existing thread routes to the gateway it was created with.
            let conversationID: UUID
            let snapshot: SettingsManager.RemoteAgentSnapshot
            let token: String
            // The bound gateway ref, hoisted from whichever fork resolves below —
            // drives the history assembler's image-history-policy lookup.
            let boundRef: RemoteAgentRef?
            if let existing = sessionConversationID {
                conversationID = existing
                let rawBackend = try? await ConversationStore.shared.fetchConversation(id: existing)?.backend
                boundRef = RemoteAgentRef(rawString: rawBackend ?? "")
                // Record it BEFORE anything below can throw, so this turn's
                // spoken failure answers for the AI it actually routed to.
                sessionBoundRef = boundRef
                guard let resolved = await SettingsManager.shared.remoteAgentSnapshot(forConversationBackend: rawBackend ?? "") else {
                    // Unknown raw OR unconfigured bound backend (Decision B — no
                    // silent reroute). This thread is BOUND to its gateway, so
                    // the line names the CHAT, not the default: "set up your
                    // personal AI" is false for a driver with five working
                    // gateways, and offering to re-point would break the
                    // per-conversation binding. Starting a new chat is the exit.
                    // xcstrings
                    endSession(
                        speak: String(localized: "This chat's AI isn't available on your iPhone. Start a new chat to use another one.")
                    )
                    return
                }
                snapshot = resolved
                // Keyless (`.none`) routes with no token; `.bearer` requires one
                // (fail closed — never keyless on a missing token).
                if snapshot.authScheme.requiresToken, (snapshot.token?.isEmpty ?? true) {
                    // xcstrings
                    endSession(
                        speak: String(localized: "This chat's AI isn't available on your iPhone. Start a new chat to use another one.")
                    )
                    return
                }
                token = snapshot.token ?? ""
            } else {
                // NEW-conversation mint: route on the session's effective ref
                // (the scene's session-local override for this drive, else the
                // iPhone's device-local default), captured at `beginSession`.
                // NEVER reads the global default here so a CarPlay gateway switch
                // can't leak to the phone/iPad/Mac. Fallback to the device-local
                // default only if (defensively) no ref was stashed.
                // ONE resolve for this branch — it supplies both the device-local
                // fallback pointer and whether that pointer is a placeholder.
                let deviceVerdict = await SettingsManager.shared.resolveDefaultGateway()
                let defaultRef: RemoteAgentRef = sessionDefaultRef ?? deviceVerdict.ref
                boundRef = defaultRef
                // Same reason as the resumed-thread fork above.
                sessionBoundRef = defaultRef
                // The roster, fetched ONCE for this branch, so a refusal can name
                // the gateway the driver actually chose — including a custom
                // they have since retired, which the roster still resolves.
                let mintRoster = await SettingsManager.shared.gatewayBadgeRoster()
                // A pointer the APP parked after a Forget is a placeholder, not a
                // gateway anyone picked, so a refusal about it drops the name and
                // speaks the unnamed sentence — the same collapse the phone, the
                // wrist and the headless lanes make. Scoped to the pointer the
                // verdict describes: a driver's own in-car pick is a choice, and
                // keeps its name even while the phone's default is parked.
                let mintName: String? =
                    (deviceVerdict.pointerIsParked && defaultRef == deviceVerdict.ref)
                    ? nil
                    : RemoteAgentRefMetadata.shortDisplayName(for: defaultRef, customs: mintRoster)
                guard let resolved = await SettingsManager.shared.remoteAgentSnapshot(for: defaultRef) else {
                    // NEW chat, so the default IS the problem — named when the
                    // driver or the user chose it, UNNAMED when the pointer is the
                    // placeholder the app parked (see `mintName` above; a nil
                    // there speaks "Conduck doesn't know which AI to use"). This
                    // is the one surface where the sentence is heard rather than
                    // read, so do not simplify `mintName` into a plain
                    // `shortDisplayName(for:customs:)` — that blames the driver
                    // aloud for a gateway nobody picked. The chooser is one tap away on
                    // the screen they are already looking at, which is what both
                    // phrasings point at.
                    speakErrorAndEnd(.remoteAgentDefaultNeedsSetup(gatewayName: mintName))
                    return
                }
                snapshot = resolved
                // Validate the default ref's auth BEFORE minting — a `.bearer`
                // URL-but-no-token default must take the not-configured error path
                // WITHOUT minting a stray empty thread. `.none` (keyless) mints on
                // URL alone (fail closed: keyless never inferred from a nil token).
                if snapshot.authScheme.requiresToken, (snapshot.token?.isEmpty ?? true) {
                    speakErrorAndEnd(.remoteAgentDefaultNeedsSetup(gatewayName: mintName))
                    return
                }
                token = snapshot.token ?? ""
                let fresh = try await ConversationStore.shared.createConversation(
                    backend: defaultRef.rawString
                )
                conversationID = fresh.id
                // Bind the session to the fresh mint so every follow-up turn
                // continues THIS thread. In-memory only — the relaunch reply
                // path rides the converse task metadata, and a relaunched
                // process can't resume a live session anyway.
                sessionConversationID = fresh.id
            }

            // Append the user turn FIRST (store is authoritative even if the
            // reply never lands). `sourceDevice "carplay"`. `status: "sending"`
            // so `CarPlayConverseUploader` can flip it to `sent`/`failed` — a
            // nil status was invisible to `markPendingUserTurns`, leaving a
            // dropped turn looking delivered on every surface.
            let userRecord = try await ConversationStore.shared.appendMessage(
                role: "user",
                text: transcript,
                conversationID: conversationID,
                sourceDevice: "carplay",
                status: "sending"
            )

            // Capture the exact READY file lane BEFORE history assembly. The
            // same immutable identity decides which historical storedKeys may
            // ride, gates the newest-turn outbox location, and pins
            // later output recovery.
            let fileTransferLane = await SettingsManager.shared
                .fileTransferReadySnapshot(for: snapshot.ref)

            // Shared history assembler — also resolves prior-turn image bytes
            // (CarPlay was image-blind before) + the bound ref's
            // image-history policy. A throw rides the surrounding do/catch
            // (mapped + spoken), exactly like the previous `fetchMessages`.
            let assembledHistory = try await ConversationHistoryAssembler.assemble(
                conversationID: conversationID,
                excludingUserMessageID: userRecord.id,
                excludingNewUserText: transcript,
                boundRef: boundRef,
                dispatchFileLaneID: fileTransferLane?.durableLaneID
            )
            let priorTurns = assembledHistory.turns

            // Mint the turn token: the converse delegate carries it so a stale
            // reply (session moved on / ended) never speaks.
            //
            // THE DISPATCH CARRIES THE MINTED TOKEN, not a re-read of
            // `currentTurnToken`. `endSession` zeroes that property before
            // cancelling, and awaits still separate this line from the upload —
            // so re-reading it handed the uploader the `0` sentinel for a turn
            // the driver had just ended, which is the one value that matches no
            // cancel claim and no in-flight lookup. The turn then dispatched
            // into a dead session and could never be cancelled afterwards.
            let dispatchTurnToken = Self.mintTurnToken()
            currentTurnToken = dispatchTurnToken

            // Revalidate the SAME ready physical lane immediately before
            // enqueue. Never replace A with whatever lane now occupies this
            // gateway slot; a removal/repoint leaves this turn failed instead
            // of exposing A-owned history or promising output on B.
            if let fileTransferLane {
                guard let currentLane = await SettingsManager.shared
                    .fileTransferReadySnapshot(for: snapshot.ref),
                      currentLane.durableLaneID == fileTransferLane.durableLaneID,
                      currentLane.identitySignature == fileTransferLane.identitySignature else {
                    throw AppError.fileTransferNotConfigured
                }
            }

            // Name THIS turn's output box here rather than inside the uploader:
            // the uploader receives only the lane's opaque identity, while this
            // caller holds the whole snapshot — the credential the absence
            // assertion needs. Hoisted AFTER the revalidation above so the
            // folder is named on the lane this turn actually dispatches over.
            //
            // The typed outcome is not read, and must not be acted on HERE of
            // all places: CarPlay has one line of text and a voice, and a
            // file-server diagnosis belongs on neither while someone is driving.
            // The phone's thread renders it after the fact, derived from the
            // lane's live witness health.
            let outboxKey = await BackgroundFileTransfer.mintOutboxKey(
                conversationID: conversationID,
                snapshot: fileTransferLane
            ).key

            // AWAITED: the uploader opens this turn's gateway-attempt row at its
            // final pre-transport boundary, after every preflight above has
            // already succeeded. Nothing here changes for the driver — the
            // upload is still a background one, and this returns as soon as the
            // task is resumed.
            try await CarPlayConverseUploader.shared.uploadConverse(
                backend: snapshot.backend,
                ref: snapshot.ref,
                url: snapshot.url,
                token: token,
                authScheme: snapshot.authScheme,
                model: snapshot.model,
                priorTurns: priorTurns,
                priorTurnShape: assembledHistory.shape,
                newUserText: transcript,
                conversationID: conversationID,
                // Exact per-message status flips (sent/failed/cancelled) — the
                // conversation-wide fallback would alias a concurrent in-app
                // turn in the same thread.
                userMessageID: userRecord.id,
                fileTransferLaneID: fileTransferLane?.durableLaneID,
                outboxKey: outboxKey,
                turnToken: dispatchTurnToken
            )
        } catch is CancellationError {
            // The driver pressed End while the uploader was at its final
            // boundary, so nothing was dispatched. `endSession` has already torn
            // the session down and spoken its sign-off, and the uploader has
            // already flipped this turn to `failed` for the Retry chip —
            // speaking a failure now would answer an empty seat with a problem
            // nobody has.
            return
        } catch {
            let mapped = (error as? AppError) ?? .remoteAgentUnreachable
            // The routing forks above set `sessionBoundRef` before anything in
            // this `do` can throw, so the spoken line dispatches on the failing
            // AI's capabilities rather than on the drive's default ref.
            speakErrorAndEnd(mapped, ref: sessionBoundRef)
        }
    }

    // MARK: - Converse-reply routing (called by CarPlayConverseUploader)

    /// The converse delegate landed a reply. SPEAK it only when this is the
    /// current live turn AND the scene is foreground on the voice template
    /// (the unsolicited-audio guard); otherwise the reply is already persisted
    /// + synced by the delegate — end the session silently. The agent turn is
    /// appended by the delegate (single owner); this method NEVER appends.
    func handleBackgroundReply(_ reply: String, conversationID: UUID, turnToken: UInt64?) {
        // Stale-reply guard: a reply for an old turn (or after the session
        // ended) does not speak. The store already has it.
        guard sessionActive,
              let turnToken,
              turnToken == currentTurnToken,
              state == .processing else {
            // Stale / old-turn reply, or the session has moved on to a newer
            // turn. The delegate already stored it (single owner). DROP SILENTLY —
            // do NOT tear down a live session the driver may be mid-follow-up on.
            return
        }

        guard isSceneActive else {
            // Backgrounded: reply synced, NOT spoken. End silently.
            endSession(speak: nil)
            return
        }

        speakReply(reply)
    }

    /// The converse delegate hit an error. Speak it + end ONLY when foreground +
    /// matching; otherwise drop silently (the user's turn is already stored).
    func handleBackgroundError(_ error: AppError, turnToken: UInt64?) {
        guard sessionActive,
              let turnToken,
              turnToken == currentTurnToken,
              state == .processing else {
            // Stale / old-turn error, or the session moved on. Drop silently —
            // the user's turn is already stored; don't disturb a live session.
            return
        }

        guard isSceneActive else {
            // Backgrounded: don't speak the error. End silently.
            endSession(speak: nil)
            return
        }

        // The converse hop failed, so the ref this turn dispatched over is the
        // one the phrase must answer for — see `sessionBoundRef`.
        speakErrorAndEnd(error, ref: sessionBoundRef)
    }

    /// Speak the sanitized agent reply, then (on finish) wait for the HFP route
    /// to settle and auto re-arm for the follow-up. Transitions to `.speaking`
    /// on FIRST AUDIO, not on entry: the head chunk's cloud synthesis takes
    /// seconds, and flipping the voice template to "Replying" over that
    /// silence reads as a hang (founder field report) — the template stays on
    /// the thinking visual until sound actually starts.
    private func speakReply(_ reply: String) {
        // DIAGNOSTIC (CarPlay dashboard-fall): timestamp the speaking entry +
        // current audio route so the next run shows whether a route-change /
        // interruption / sceneWillResignActive fires around TTS-start. Device-
        // audio facts only — never the reply text.
        let session = AVAudioSession.sharedInstance()
        Self.log.info("speakReply ENTER: main=\(Thread.isMainThread, privacy: .public) state=\(String(describing: self.state), privacy: .public) out=[\(session.currentRoute.outputs.map(\.portType.rawValue).joined(separator: ","), privacy: .public)] cat=\(session.category.rawValue, privacy: .public) audioActivated=\(self.audioActivated, privacy: .public)")
        let token = currentTurnToken
        CarPlaySpeechService.shared.speakAgent(reply, onFirstAudio: { [weak self] in
            guard let self else { return }
            Self.log.info("speakReply FIRST AUDIO: sessionActive=\(self.sessionActive, privacy: .public) tokenMatch=\(self.currentTurnToken == token, privacy: .public)")
            // Guarded to `.processing`: a mid-synth mute parks the state on
            // `.muted` (the reply still speaks, mic-mute only) and must keep
            // its visual; a stale turn / ended session must not repaint.
            guard self.sessionActive, self.currentTurnToken == token,
                  self.state == .processing else { return }
            self.state = .speaking
            self.voiceControlTemplate.activateVoiceControlState(withIdentifier: VoiceState.speaking)
        }) { [weak self] in
            guard let self else { return }
            Self.log.info("speakReply COMPLETION: sessionActive=\(self.sessionActive, privacy: .public) muted=\(self.isMicMuted, privacy: .public) tokenMatch=\(self.currentTurnToken == token, privacy: .public)")
            // Guard: the session may have ended (Stop/Cancel) or moved on while
            // TTS was playing. Only re-arm if this is still the live turn.
            guard self.sessionActive, self.currentTurnToken == token else { return }
            if self.isMicMuted {
                // Muted mid-reply: the reply was spoken (output is unaffected by a
                // mic-mute); park passive on `.muted` instead of re-arming the mic.
                self.state = .muted
                self.voiceControlTemplate.activateVoiceControlState(withIdentifier: VoiceState.muted)
            } else {
                Task { await self.reArmAfterSettle() }
            }
        }
    }

    /// Wait `carPlayHFPSettleDelay` (~300 ms) for the playback→capture HFP route
    /// to settle (skipping crashes engine.start()
    /// with FourCC '!obj'/560947818; '!int' is the different 560557684), then
    /// re-arm the mic for the follow-up turn.
    private func reArmAfterSettle() async {
        guard sessionActive else { return }
        try? await Task.sleep(for: .seconds(Constants.carPlayHFPSettleDelay))
        guard sessionActive else { return }
        // Muted during the settle window — hold passive on `.muted`, don't re-arm.
        guard !isMicMuted else {
            state = .muted
            voiceControlTemplate.activateVoiceControlState(withIdentifier: VoiceState.muted)
            return
        }
        // Self-heal: never re-listen if the voice modal is no longer on screen.
        // A dismiss that bypassed `endSession` (system/user pop, dropped
        // `templateDidDisappear`) would otherwise leave the loop recording behind
        // the picker. If the modal is gone, end the session instead of re-arming.
        guard isVoiceModalPresented?() ?? true else {
            endSession(speak: nil)
            return
        }
        // Go `.speaking → .recording` DIRECTLY — do NOT route through `.idle`.
        // Under the modal model `.idle` means "session ended → dismiss the voice
        // modal", so a transient inter-turn `.idle` would wrongly dismiss the
        // template (and flicker the UI) mid-session. `startListening` only guards
        // on `sessionActive`, so skipping `.idle` is safe; it sets `.recording`.
        await startListening(isFollowUp: true)
    }

    // MARK: - Error TTS + session end

    /// Map an `AppError` to a driver-safe spoken phrase, speak it, then end the
    /// session (no re-arm — an error ends the conversation).
    ///
    /// VOCABULARY, because everything here is SPOKEN: no line may say "gateway"
    /// and none may say "personal AI". "Gateway" is retained only on the
    /// self-hosted setup and troubleshooting screens, where it matches the
    /// `openclaw.json` keys the user hand-edits; a driver on the hosted lane
    /// runs no gateway, and the adjective in "your personal AI" claims a
    /// privacy posture a third-party routing service cannot honour. These lines
    /// name the CLASS — "your AI" — which is true on all four lanes.
    ///
    /// `ref` is the AI this turn actually dispatched over, and the arms that need
    /// it dispatch on CAPABILITY through `RemoteAgentFailureContext` — never on
    /// hosted-vs-self-hosted, which gets the model arms exactly backwards
    /// (OpenClaw and Hermes are self-hosted AND hide the model field). It is
    /// OPTIONAL because two call sites genuinely have no gateway in hand — the
    /// STT hop's catch, where the failing machine is the speech provider — and
    /// `nil` resolves to `.neutral`, i.e. the wording this switch already spoke.
    private func speakErrorAndEnd(_ error: AppError, ref: RemoteAgentRef? = nil) {
        let context = RemoteAgentFailureContext.resolve(ref)
        let phrase: String
        switch error {
        case .noSpeechDetected:
            // xcstrings
            phrase = String(localized: "Didn't catch that — try again.")
        case .audioInvalid, .audioTooLarge, .audioProcessingFailed, .audioMissingData:
            // xcstrings
            phrase = String(localized: "Couldn't save — try again.")
        case .speechPermissionDenied:
            // xcstrings: watch-stt-fix
            phrase = String(localized: "Speech Recognition is off. Allow it in iPhone Settings under Privacy and Speech Recognition.")
        case .sttAuthFailed:
            // xcstrings
            phrase = String(localized: "STT key isn't working. Update it in Conduck on your iPhone.")
        case .sttMissingAPIKey:
            // xcstrings
            phrase = String(localized: "Add your STT key in Conduck on your iPhone.")
        case .appleSpeechModelNotInstalled:
            // xcstrings: stt-dictation-default
            phrase = String(localized: "On-device voice isn't ready. Open Conduck on your iPhone to set it up.")
        case .sttQuotaExceeded:
            // xcstrings
            phrase = String(localized: "STT quota is exhausted. Top up with your provider.")
        case .sttTooManyRequests:
            // xcstrings
            phrase = String(localized: "Too many requests — try again in a moment.")
        case .remoteAgentDefaultNeedsSetup(let name):
            // Driver-safety rule the certificate arms below already state: say
            // which problem it is, then stop. A driver cannot act on a vague
            // line and must not be invited to fiddle with a phone — so this
            // points at the CarPlay list, which is already on the screen in
            // front of them, rather than at the iPhone.
            if let name {
                // xcstrings
                phrase = String(localized: "Your default AI, \(name), isn't available. Choose another from the list.")
            } else {
                // xcstrings
                phrase = String(localized: "Conduck doesn't know which AI to use. Choose one from the list.")
            }
        case .remoteAgentNotConfigured:
            // xcstrings
            phrase = String(localized: "setup.requiredOnPhone", defaultValue: "Set up your AI on iPhone first.")
        case .remoteAgentAuthFailed:
            // xcstrings
            phrase = String(localized: "carplay.error.authFailed.speak", defaultValue: "Your AI refused the key. Update it in Conduck on your iPhone.")
        case .remoteAgentCertMismatch, .sttCustomCertMismatch, .ttsCustomCertMismatch:
            // Driver-safe brevity argues for a SHORT line, not a vague one. The
            // shared compact form names the risk and points at the phone — the
            // same words the wrist speaks, so one cause keeps one wording.
            //
            // All three lanes speak it, mirroring the untrusted arm below: the
            // alternative is `default:` — "Something went wrong. Try again." —
            // which invites a retry on a terminal refusal AND drops the one
            // thing the driver must hear, that the connection may be
            // intercepted. The shared line is NEUTRAL about which machine it
            // means ("this server"), which is what makes one wording correct on
            // all three lanes — a custom voice endpoint is a different server
            // from the gateway, and this arm cannot tell the driver which.
            phrase = CertificateTrustCopy.pinMismatchRefusalCompact
        case .remoteAgentCertUntrusted, .sttCustomCertUntrusted, .ttsCustomCertUntrusted:
            // Spoken, so the full remedy would be unusable at the wheel — the
            // shared compact form says WHICH problem it is and stops. The named
            // routes to a trusted certificate wait on the phone, where the
            // driver can act on them.
            phrase = CertificateTrustCopy.untrustedRefusalCompact
        case .remoteAgentCertKeyUnpinnable, .sttCustomCertKeyUnpinnable, .ttsCustomCertKeyUnpinnable:
            // Spoken apart from the mismatch arm above, not folded into it: this
            // verdict is reached only AFTER system trust passed, so the
            // certificate is valid and nothing is intercepting anything. Speaking
            // the interception warning at a driver whose only problem is a key
            // algorithm Conduck can't hash is a false alarm on the one line that
            // must never cry wolf. `default:` is just as wrong — "Something went
            // wrong. Try again." invites a retry on a terminal refusal.
            phrase = CertificateTrustCopy.keyUnpinnableRefusalCompact
        case .remoteAgentTimeout, .remoteAgentUnreachable:
            // xcstrings
            phrase = String(localized: "error.unreachable.retry", defaultValue: "Couldn't reach your AI. Try again.")
        case .remoteAgentServerError, .remoteAgentInvalidResponse:
            // xcstrings
            phrase = String(localized: "carplay.error.serverError.speak", defaultValue: "Your AI had trouble replying. Try again.")
        case .sttProviderUnreachable, .noInternetConnection, .requestTimeout, .persistentNetworkFailure, .networkError:
            // xcstrings
            phrase = String(localized: "Couldn't reach the server. Try again.")
        case .sttServerError:
            // xcstrings
            phrase = String(localized: "STT service is having trouble. Try again.")
        case .sttCustomEndpointNotConfigured:
            // Defense in depth — the upload flow already pre-empts custom-active
            // before transcribe; this covers any other path that throws it.
            // xcstrings: hardening
            phrase = String(localized: "Custom voice endpoints aren't available in the car. Pick another provider in Conduck on your iPhone.")
        case .sttDecodingFailure:
            // Terminal: the provider answered in a shape Conduck can't parse, and
            // it will answer the same way on the next ask. The only lever the
            // driver has is a different provider, which lives on the phone.
            // xcstrings: carplay-terminal
            phrase = String(localized: "Your speech provider sent an unexpected response. Pick another provider in Conduck on your iPhone.")

        // ── Gateway verdicts with no lever at the wheel ─────────────────────
        // Each arm below exists for the SAME reason the certificate arms above
        // give: `default:` would speak "Something went wrong. Try again." at a
        // driver whose next ask reaches the identical refusal — the cause
        // dropped AND a retry invited, on a loop that cannot end. Most are
        // terminal (`isRetryable == false`). The 402 and 429 arms are the
        // exception and are named here deliberately: they ARE retryable on the
        // surfaces that own a Retry control, but the car owns none, and neither
        // topping up an account nor sitting out a daily cap is a thing the
        // driver can do at the wheel — so the honest line here is the cause and
        // no invitation. Reached from
        // `CarPlayConverseUploader` via `RemoteAgentStatusMap` (402/429) and
        // `RemoteAgentClient.classifyBodyError` (adapter wire codes + the
        // 400/404/413 heuristics).
        //
        // Wording follows this file's rule: name the problem, then point at the
        // ONE place the driver can act. For the three history-shaped verdicts
        // that place is the car itself — ending the session lands on the
        // list-picker whose first row is "New voice chat", and a fresh thread is
        // exactly what drops the oversized history. Everything else waits on the
        // phone, and the line says so instead of implying a fix at the wheel.
        case .remoteAgentOutOfCredits:
            // xcstrings: carplay-terminal
            phrase = String(localized: "Your AI provider is out of credits. Add credits with your provider.")
        case .remoteAgentRateLimited:
            // Names no remedy at all, deliberately: the fix is TIME, and every
            // phrasing of "wait, then ask again" is a retry invitation wearing a
            // delay. Saying why it happened is the honest stopping point.
            // xcstrings: carplay-terminal
            phrase = String(localized: "Your AI provider is rate-limiting you. Free models often have a daily limit.")
        case .remoteAgentModelUnavailable:
            // Branches on the MODEL POLICY, never on the lane. Where Conduck
            // hides the model field (OpenClaw / Hermes — self-hosted AND
            // `model == .unsupported`), "pick another in Conduck" sends a driver
            // after a control that is on no screen, spoken aloud with nothing to
            // glance back at. There is no lever at the wheel on that lane, so
            // the line states what is true and stops rather than inventing one.
            // "Your server" is accurate for everyone who can reach this branch:
            // customs are `.optional` and take the arm below.
            // xcstrings: carplay-terminal
            if context.userCanChooseModel {
                phrase = String(localized: "That AI model isn't available. Pick another in Conduck on your iPhone.")
            } else {
                phrase = String(localized: "carplay.error.modelUnavailable.speak.serverChosen", defaultValue: "The model your server chose isn't available.")
            }
        case .remoteAgentModelRequired:
            // Same inversion, same dispatch. Reached from
            // `RemoteAgentClient.classifyBodyError`'s body heuristics on
            // 400/404/413/422, which are NOT gated by lane — a self-hosted
            // gateway whose upstream demands a model raises it — so the
            // model-hidden lane really does hear this one.
            // xcstrings: carplay-terminal
            if context.userCanChooseModel {
                phrase = String(localized: "carplay.error.modelRequired.speak", defaultValue: "Your AI needs a model name. Set one in Conduck on your iPhone.")
            } else {
                phrase = String(localized: "carplay.error.modelRequired.speak.serverChosen", defaultValue: "Your server needs a default model.")
            }
        case .remoteAgentContextTooLong:
            // Deliberately UNBRANCHED, unlike 55 and 60 above: "the model" here
            // is the cause, not a control, and the remedy it names — start a new
            // voice chat — is one tap away on every lane (ending the session
            // lands on the picker whose first row is "New voice chat").
            // xcstrings: carplay-terminal
            phrase = String(localized: "This chat got too long for the model. Start a new voice chat.")
        case .remoteAgentImageTooLarge:
            // CarPlay attaches nothing itself — the offending image rides in the
            // client-owned history this session replays, so a new thread is the
            // whole fix and it is one tap away on the screen the driver is about
            // to land on.
            // xcstrings: carplay-terminal
            phrase = String(localized: "carplay.error.imageTooLarge.speak", defaultValue: "A photo in this chat was too large for your AI. Start a new voice chat.")
        case .remoteAgentVisionUnsupported:
            // Same history shape as the arm above. "Couldn't use a photo" rather
            // than "can't read images": the client cannot tell the adapter from
            // the engine, so it never attributes the decline.
            // xcstrings: carplay-terminal
            phrase = String(localized: "carplay.error.visionUnsupported.speak", defaultValue: "Your AI couldn't use a photo in this chat. Start a new voice chat.")
        case .fileTransferNotConfigured:
            // Thrown by this file's own pre-enqueue lane revalidation when the
            // ready file lane was removed or repointed mid-turn. Terminal for
            // this session; the lane is rebuilt on the phone.
            // xcstrings: carplay-terminal
            phrase = String(localized: "carplay.error.fileTransferNotConfigured.speak", defaultValue: "File transfer isn't set up. Check it in Conduck on your iPhone.")
        default:
            // The catch-all stays, and it asks the taxonomy instead of assuming.
            //
            // "Try again." is genuinely RIGHT for what actually lands here now:
            // `.unknown`, `.apiFailure` (the status map's fallback for an HTTP
            // code nobody specialised) and the transport blips — all retryable,
            // all plausibly different on the next ask.
            //
            // It is wrong for anything terminal, and the arms above cover only
            // the terminal codes reachable TODAY. A case added to `AppError`
            // later inherits this arm silently — which is precisely how a
            // terminal verdict acquired a retry invitation here in the first
            // place. So the split is made by `isRetryable`, the same property
            // every other surface gates on: an unrecognised terminal failure
            // degrades to a vague-but-honest line rather than a promise the
            // request cannot keep. Named arms above stay copy choices (that is
            // why `.noSpeechDetected` may still say "try again" — a re-ask there
            // carries different audio and really can succeed); this arm is the
            // safety net under them.
            if error.isRetryable {
                // xcstrings
                phrase = String(localized: "Something went wrong. Try again.")
            } else {
                // xcstrings: carplay-terminal
                phrase = String(localized: "Something went wrong. Check Conduck on your iPhone.")
            }
        }
        endSession(speak: phrase)
    }

    // MARK: - Audio-session deactivation (the deactivate-once chokepoint)

    /// Deactivate the CarPlay audio session EXACTLY ONCE per session.
    /// Idempotent — guarded by `audioActivated`, so a second call is a no-op.
    /// This is the SINGLE place that calls `CarPlayAudioSession.deactivate()`
    /// and flips `audioActivated = false`.
    ///
    /// Foreground terminal paths deactivate via the scene delegate's
    /// `dismissTemplate` completion (AFTER the voice modal is gone — never
    /// before, or the synchronous deactivate races the scene teardown and the
    /// app falls to the CarPlay dashboard). Background/disconnect paths call
    /// this DIRECTLY (a dismiss completion may never fire while backgrounded);
    /// because it's idempotent, a later dismiss-completion call is a safe no-op.
    func deactivateAudioSession() {
        guard audioActivated else { return }
        do {
            try CarPlayAudioSession.deactivate()
        } catch {
            // A failed/incomplete deactivate must not look clean to the next
            // session — surface it (the next cold-start activates + the
            // retry/recovery path re-asserts a wedged route from scratch).
            Self.log.error("CarPlay deactivate failed: \(Self.audioDiag(error), privacy: .public)")
        }
        audioActivated = false
    }

    // MARK: - Session end (drives the dismiss → deactivate chain)

    /// End the session: cancel any in-flight converse, tear down capture, and
    /// drive the state machine to `.idle` — which the scene observer turns into
    /// `ensureVoiceDismissed` → `dismissTemplate` → `deactivateAudioSession()`
    /// (the audio is freed in the dismiss completion, AFTER the modal is gone).
    ///
    /// Audio is NEVER deactivated inline on this foreground path (doing so before
    /// the dismiss is the "End exits to the dashboard" bug): freeing the car
    /// radio is owned by the dismiss completion. Background/disconnect callers
    /// free audio DIRECTLY via `deactivateAudioSession()` (see
    /// `setSceneActive(false)` / `teardown()`), because no dismiss completion
    /// fires while backgrounded.
    ///
    /// If `speak` is non-nil, speak it FIRST (the voice modal stays presented
    /// during the sign-off / error TTS) and set `state = .idle` ON COMPLETION,
    /// so the dismiss + deactivate happen only after the TTS finishes.
    /// Idempotent — a second call is a no-op (guards on `sessionActive`).
    private func endSession(speak: String?) {
        guard sessionActive else { return }
        // Kill any in-flight reply TTS at the terminal chokepoint, BEFORE the
        // teardown below — every session end funnels through here (End button,
        // backgrounding, disconnect, timeouts, errors). Load-bearing for the
        // CHUNKED reply path: unlike a single already-started blob, the chunk
        // queue keeps fetching tail chunks and STARTING new per-chunk players
        // on its own — left alive across a background/disconnect end it would
        // issue cloud synth calls and initiate audio AFTER
        // `deactivateAudioSession()` (unsolicited audio over Maps, implicit
        // session re-activation). Idempotent — the End path's own cancel in
        // `endFromButton` makes this a no-op there. The sign-off/error `speak`
        // arm below runs AFTER this cancel, so a non-nil `speak` still plays.
        CarPlaySpeechService.shared.cancel()
        sessionActive = false
        // Keep the process-wide mirror in lockstep (see `anySessionActive`).
        Self.anySessionActive = false
        isMicMuted = false
        // Session over → its conversation binding + effective-ref capture die
        // with it (the next session re-seeds via `beginSession(conversationID:defaultRef:)`).
        // `sessionBoundRef` clears here too: `speakErrorAndEnd` resolves its
        // phrase BEFORE calling this, so nothing downstream still needs it.
        sessionConversationID = nil
        sessionDefaultRef = nil
        sessionBoundRef = nil

        // Cancel the in-flight converse so a late reply never lands on a dead
        // session (the delegate sees `.cancelled` and drops it silently).
        let token = currentTurnToken
        currentTurnToken = 0
        if token != 0 {
            CarPlayConverseUploader.shared.cancel(turnToken: token)
        }
        CarPlayConverseUploader.shared.setActiveService(nil)

        invalidateTimers()
        endBackgroundTask()
        tearDownCapture()
        // Delete any orphaned partial-capture temp file (audio cleanup). The
        // End button (`endFromButton`) and the cold-connect initial-silence
        // timeout reach this terminal path directly from `.recording` with a live
        // `.caf` still on disk; every other discard path already removed it, so
        // this is a no-op there. `tearDownCapture()` above stopped the tap first.
        if let url = recordingURL {
            try? FileManager.default.removeItem(at: url)
        }
        recordingStartedAt = nil
        recordingURL = nil

        if let speak, !speak.isEmpty {
            // Keep the voice modal presented while the sign-off / error TTS
            // plays; only on completion drop to `.idle` → dismiss → deactivate.
            state = .speaking
            voiceControlTemplate.activateVoiceControlState(withIdentifier: VoiceState.speaking)
            CarPlaySpeechService.shared.speak(speak) { [weak self] in
                self?.state = .idle
            }
        } else {
            // No TTS → straight to `.idle`; the observer dismisses the modal and
            // the dismiss completion deactivates the audio session.
            state = .idle
        }
    }

    // MARK: - Timers

    private func invalidateTimers() {
        recordingMaxDurationTimer?.invalidate()
        recordingMaxDurationTimer = nil
        initialSilenceTimer?.invalidate()
        initialSilenceTimer = nil
    }

    // MARK: - Background task (STT hop only — g11)

    private func beginBackgroundTask() {
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(
            withName: "carplay-stt-hop"
        ) { [weak self] in
            Task { @MainActor in
                self?.endBackgroundTask()
            }
        }
    }

    private func endBackgroundTask() {
        let task = backgroundTask
        if task != .invalid {
            backgroundTask = .invalid
            UIApplication.shared.endBackgroundTask(task)
        }
    }

    // MARK: - Audio interruption

    private func setupInterruptionObserver() {
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor in
                self?.handleInterruption(notification)
            }
        }
    }

    /// DIAGNOSTIC (CarPlay dashboard-fall): log every audio route change with
    /// its reason + the resulting route + current state. Log-only — no behavior
    /// change. Lets the next run show whether a route renegotiation precedes a
    /// `sceneWillResignActive` at TTS-start.
    private func setupRouteChangeObserver() {
        routeChangeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            let reasonRaw = (notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt) ?? 99
            let session = AVAudioSession.sharedInstance()
            let outs = session.currentRoute.outputs.map(\.portType.rawValue).joined(separator: ",")
            let ins = session.currentRoute.inputs.map(\.portType.rawValue).joined(separator: ",")
            Task { @MainActor in
                Self.log.info("ROUTE CHANGE reason=\(reasonRaw, privacy: .public) state=\(String(describing: self?.state), privacy: .public) outs=[\(outs, privacy: .public)] ins=[\(ins, privacy: .public)]")
            }
        }
    }

    // MARK: - Media-services reset (mediaserverd torn down)

    /// Recover from a `mediaserverd` reset. After the `Connection invalidated` /
    /// `IPCAUClient can't connect` cascade (which a failed `engine.start()` over
    /// CarPlay can trigger), the capture engine + speech synthesizers are zombie
    /// objects — every subsequent session fails until they are recreated. Apple's
    /// contract: dispose all audio objects on reset and rebuild before reuse.
    private func setupMediaResetObserver() {
        mediaResetObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleMediaServicesReset()
            }
        }
    }

    private func handleMediaServicesReset() {
        Self.log.error("Media services were reset — disposing audio + ending session")
        // Drop the (now-invalid) capture engine + speech objects so the NEXT
        // session activates + builds fresh ones. `audioActivated = false` forces
        // a clean re-activation (the system already tore the session down, so the
        // dismiss-completion deactivate would be a no-op anyway).
        tearDownCapture()
        CarPlaySpeechService.shared.resetForMediaServicesReset()
        audioActivated = false
        // End the live session SILENTLY — the driver taps again for a fresh,
        // cleanly-activated session. Mid-reset recovery is not attempted (the
        // audio stack is being rebuilt by the system).
        if sessionActive {
            endSession(speak: nil)
        }
    }

    private func handleInterruption(_ notification: Notification) {
        // DIAGNOSTIC: log type + reason + state at entry (before the guard).
        let info0 = notification.userInfo
        let typeRaw = (info0?[AVAudioSessionInterruptionTypeKey] as? UInt) ?? 99
        let reasonRaw = (info0?[AVAudioSessionInterruptionReasonKey] as? UInt) ?? 99
        Self.log.info("INTERRUPTION type=\(typeRaw, privacy: .public) reason=\(reasonRaw, privacy: .public) state=\(String(describing: self.state), privacy: .public)")
        guard let info = notification.userInfo,
              let typeValue = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else {
            return
        }

        switch (type, state) {
        case (.began, .recording):
            // Phone call / Siri / nav prompt arrived while recording — upload
            // whatever landed (truncated transcript beats a discarded partial).
            Task { await self.endRecordingForUpload() }
        case (.began, .speaking):
            // `AVSpeechSynthesizer` auto-pauses on interruptions; let the
            // system drive it — our completion fires on its didFinish/didCancel.
            break
        default:
            // `.ended` — do not auto-resume.
            break
        }
    }
}

#endif
