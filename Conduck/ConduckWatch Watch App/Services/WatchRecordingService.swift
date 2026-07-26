import AVFoundation
import SwiftUI
import WatchConnectivity
import WatchKit

/// State machine for the watchOS recording + agent round-trip pipeline.
/// Drives the Conduck capture + reply surface on Apple Watch.
enum WatchRecordingState: Equatable {
    case idle
    /// Mic is being armed (permission + scene-active poll + audio-session
    /// activation). Shows "Starting…". Distinct from `.recording`: the mic is
    /// NOT yet live, so the `.start` haptic + recording visuals are withheld
    /// until `AVAudioRecorder` genuinely begins. Lets the capture overlay
    /// render immediately on the thread push without falsely claiming the user
    /// can speak.
    case arming
    case recording
    /// STT in flight (transcribing the captured audio).
    case uploading
    /// Agent hop in flight after STT succeeded — the "thinking…" state.
    /// `startedAt` drives the elapsed-time indicator + wrist-drop restoration.
    case waiting(startedAt: Date)
    case error(message: String)

    /// Coarse phase label for diagnostics — the case NAME only, never the
    /// associated `startedAt` Date or `.error` message. Drives the
    /// state-transition chokepoint in `state.didSet`.
    var phaseKind: String {
        switch self {
        case .idle:      return "idle"
        case .arming:    return "arming"
        case .recording: return "recording"
        case .uploading: return "uploading"
        case .waiting:   return "waiting"
        case .error:     return "error"
        }
    }
}

/// Where a quick-capture turn should land, resolved at TRIGGER time so a
/// pointer / default-gateway change mid-recording can never silently reroute
/// the turn (the gateway ref is captured the moment the trigger fires).
///
/// `.existing` targets an already-persisted conversation; `.new` is a DRAFT
/// shell that has NO conversationID yet — persistence is deferred to the first
/// non-empty transcript (the lazy mint in `resolveActiveConversationAndBackend`),
/// at which point the draft adopts the real id via
/// `WatchRecordingService.inFlightConversationID`.
enum WatchCaptureTarget: Hashable {
    case existing(UUID)
    /// A brand-new conversation to be minted lazily, bound to `backendRef`
    /// (a `RemoteAgentRef` rawString captured at trigger time).
    case new(backendRef: String)
}

@Observable
@MainActor
final class WatchRecordingService {
    /// Shared instance. The background converse delegate
    /// (`WatchAudioUploader.handleConverseCompletion`) routes the reply to this
    /// singleton so the open thread refreshes (`.conversationsDidChange`); the
    /// `WatchNoteView` + thread read the same instance. A singleton (not a
    /// per-view `@State`) so the two background hops +
    /// the views share one state machine.
    static let shared = WatchRecordingService()

    var state: WatchRecordingState = .idle {
        didSet {
            // Provenance-flag hygiene: `lastErrorIsRelayDeferral` is only
            // meaningful while ITS toast is the visible `.error`. ANY
            // transition (to `.idle`, to a DIFFERENT `.error`, into a fresh
            // capture) invalidates it — the single branch that sets the flag
            // (the relay-timeout path in `runRelay`) does so immediately
            // AFTER assigning `state`, so clear-then-set ordering is correct
            // by construction.
            lastErrorIsRelayDeferral = false

            // The `.uploading` watchdog is scoped to ONE uninterrupted
            // `.uploading` phase — any transition away means the stall it
            // guards against already resolved (delegate completion, cancel,
            // reply takeover). Cancelling here, at the chokepoint, covers
            // every exit site without scattering disarm calls.
            if oldValue == .uploading, state != .uploading {
                uploadingWatchdogTask?.cancel()
                uploadingWatchdogTask = nil
            }

            // State-transition chokepoint (observability): log coarse PHASE
            // changes only. Guard on `phaseKind` so the deliberate
            // `.waiting`→`.waiting` re-assignment (deferred-relay occupancy) and
            // same-value re-sets stay silent. Error CAUSES are logged separately
            // at each `.error` site — here the message is already a user string,
            // not the underlying code.
            let oldKind = oldValue.phaseKind
            let newKind = state.phaseKind
            if oldKind != newKind {
                WatchLog.note(.state, "state", ["from": oldKind, "to": newKind, "turn": turnTag])
            }
        }
    }
    var recordingTime: TimeInterval = 0

    /// True iff the CURRENT `.error` is the relay-deferral toast ("Sent to
    /// iPhone…"). Provenance gate for the deferred-relay machinery
    /// (`AppleRelayPendingQueue.drain` / `.reconcile`): deferred dispatch may
    /// run — and the toast may be auto-cleared — ONLY when the error on
    /// screen is this specific one. An unrelated error toast must never be
    /// stomped by background relay work (that's why the gate is provenance-
    /// based, not any-`.error`). Set ONLY by `runRelay`'s timeout branch;
    /// cleared by every other state transition (see `state.didSet`).
    private(set) var lastErrorIsRelayDeferral = false

    /// Gate for deferred-relay dispatch (queue drain + late-reply reconcile):
    /// the deferred machinery may take over the live state machine when it is
    /// idle OR when the only thing on screen is the relay-deferral toast —
    /// which the deferred work itself resolves (defect: the old `.idle`-only
    /// drain gate deadlocked behind the timeout toast until the user tapped
    /// X). Any OTHER state (live capture/upload/wait, an unrelated error)
    /// refuses; entries stay queued and the next idle edge re-fires them.
    var canAcceptDeferredDispatch: Bool {
        switch state {
        case .idle:
            return true
        case .error:
            return lastErrorIsRelayDeferral
        case .arming, .recording, .uploading, .waiting:
            return false
        }
    }
    /// True between the soft-warning fire and the hard cap. Drives the
    /// orange timer + "1 min left" label in the recording view.
    var nearMaxDuration: Bool = false

    /// Speaks agent replies through TTS (route-aware). Owned here so the
    /// foreground reply path and the tap-to-speak button share one synthesizer.
    let speech = WatchReplySpeaker()

    /// Conversation persistence this service resolves/mints/appends/restores
    /// through. Internal-with-default seam: production always uses the shared
    /// CloudKit-backed store; tests inject `ConversationStore(inMemory: true)`
    /// so the lifecycle/mint paths run without the persistent container.
    /// (`ConversationHistoryAssembler`, a shared cross-target file, keeps its
    /// own `.shared` read — the seam covers this service's direct calls.)
    var store: ConversationStore = ConversationStore.shared

    /// Foreground STT transport seam (default: the real
    /// `WatchNetworkClient.uploadSTT`). Injectable so the cancel-supersede
    /// contract in `runSTTUpload` is unit-testable without a network.
    var sttUpload: @MainActor (WatchSTTRequest, STTProvider) async throws -> STTResponse = { request, provider in
        try await WatchNetworkClient.uploadSTT(request: request, provider: provider)
    }

    /// iPhone-relay transport seam (default: the real
    /// `AppleSpeechRelayCoordinator.relay`). Injectable so the relay leg's
    /// cancel-supersede contract in `runRelay` is unit-testable without a
    /// paired iPhone or a live `WCSession` — the relay branch is the DEFAULT
    /// STT path (`apple-on-device`), so its cancel behaviour is the one most
    /// users depend on.
    var relayTranscribe: @MainActor (String, URL, String?, String?) async throws -> String = { requestID, audioFileURL, language, providerID in
        try await AppleSpeechRelayCoordinator.shared.relay(
            requestID: requestID,
            audioFileURL: audioFileURL,
            language: language,
            providerID: providerID
        )
    }

    /// Record-session activation seam (default: the real off-main
    /// `activateRecordSession` audio-server IPC). Injectable so the arm
    /// Task's post-activation stale-guard and failure paths are
    /// unit-testable without an audio server.
    var recordSessionActivator: @Sendable () async throws -> Void = {
        try await WatchRecordingService.activateRecordSession()
    }

    /// Mic-permission seam (default: the real TCC request). Injectable so
    /// the arm Task can run past the permission gate in a unit-test host,
    /// where the system prompt would otherwise park it indefinitely.
    var recordPermissionRequest: @MainActor () async -> Bool = {
        await AVAudioApplication.requestRecordPermission()
    }

    /// Audio-session ownership arbiter (seam: tests inject a private
    /// coordinator with an observable, inert `deactivate` closure).
    var sessionCoordinator: WatchAudioSessionCoordinator = .shared

    /// The recorder's live ownership tenure; non-nil exactly while this
    /// service holds the session claim. Always dropped via
    /// `releaseSessionClaim`, whose release posture branches on
    /// `sessionConfigured`.
    private(set) var sessionClaim: WatchAudioSessionCoordinator.Claim?

    /// True once the live tenure's `.record` config has actually committed
    /// through the coordinator's FIFO lane. Gates the release posture in
    /// `releaseSessionClaim`: a configured tenure releases PLAIN (the
    /// `.record` session staying active is deliberate); an unconfigured
    /// tenure that dies must release-and-deactivate — its claim may have
    /// superseded a live TTS turn whose `.playback + .duckOthers` config is
    /// still the session's active state, and without the guarded
    /// deactivation the user's ducked music never comes back. Reset at every
    /// new claim in `_startRecording`.
    private var sessionConfigured = false

    /// Monotonic capture-supersede token. Bumped by `cancelRecording()`; the
    /// STT-stage chain re-checks it after every await — the arm Task in
    /// `_startRecording`, `runSTTUpload`'s two exits (foreground),
    /// `WatchAudioUploader.handleSTTCompletion` (background fallback), and
    /// `runRelay` after its reply await (iPhone relay) — so a cancelled turn
    /// can never resurrect into a thread the user never chose. The
    /// `.waiting`-stage converse hop is deliberately NOT gated (wrist-drop
    /// resilience), nor is the DEFERRED Apple-relay drain (deferred
    /// delivery is the feature there — and a cancel removes its queue entry
    /// outright, so there is nothing left to drain).
    private(set) var captureGeneration = 0

    /// Bumped whenever a capture retires WITHOUT having minted a conversation
    /// (explicit cancel, mis-tap/too-short discard, empty transcript). A draft
    /// (`.new`) thread view observes this to pop itself back off the nav stack
    /// — the service stays navigation-blind; it only states the outcome.
    /// Deliberately an outcome COUNTER, not state inference: increments
    /// survive SwiftUI observation coalescing (a suspended view still sees
    /// old ≠ new exactly once on resume), and the minted path never touches
    /// it, so a wrist-down mint→reply race can never read as a discard. NOT
    /// bumped by `dismissError()` — that also runs as an internal
    /// error-supersede (new-attempt entry points, the relay-success
    /// auto-clear), where a bump would pop a LIVE draft mid-mint.
    private(set) var captureDiscardCount = 0

    /// The in-flight `processRecording` pipeline Task (read → compress → STT →
    /// converse chain). Stored so `cancelRecording()` can actually cancel it;
    /// `.cancel()` propagates into the async foreground URLSession upload.
    private var processTask: Task<Void, Never>?

    /// Claim token of the relay entry this capture durably enqueued, while it
    /// is in flight. The relay Task is deliberately detached from `processTask`
    /// (wrist-drop resilience), and the queue is enqueue-first durable — so the
    /// generation bump ALONE cannot stop it: after a relaunch the generation
    /// resets to 0 and the drain would ship a turn the user cancelled. Holding
    /// the id lets `cancelRecording()` CLAIM the entry, which is what makes the
    /// cancel authoritative (removes it, deletes the queued audio, cancels any
    /// outstanding transfer). Nil whenever no relay is in flight.
    private var pendingRelayRequestID: String?

    /// Wall-clock stamp of the `.recording` state flip. Feeds the double-tap
    /// grace window in `stopRecording()`. Read only under
    /// `state == .recording`, and every flip re-assigns it first — so a stale
    /// value can never classify a later capture.
    private var recordingStartedAt: Date?

    /// In-memory watchdog for a live-app `.uploading` stall (background STT
    /// handed off, delegate never returns). Armed by
    /// `fallbackSTTToBackgroundUpload`; cancelled by `state.didSet` on ANY
    /// transition away from `.uploading`. `.uploading` does not survive a
    /// relaunch (only the `.waiting` marker persists), so in-memory is enough.
    private var uploadingWatchdogTask: Task<Void, Never>?

    /// `private(set)`: the arm stale-guard contract ("no recorder for a dead
    /// turn") is asserted directly in `WatchArmActivationTests`.
    private(set) var audioRecorder: AVAudioRecorder?
    private var recordingTimer: Timer?
    /// Soft-warning timer fires at `maxAudioDuration - warningOffset`.
    private var warningTimer: Timer?
    /// Hard auto-stop timer fires at `maxAudioDuration` and calls `stopRecording()`.
    /// Necessary because `AVAudioRecorder.record(forDuration:)` stops the *recorder*
    /// at the cap but does not advance the service's state machine without a
    /// `AVAudioRecorderDelegate`, which we don't currently wire on watchOS.
    private var maxDurationStopTimer: Timer?
    private var recordingFileURL: URL?
    private var interruptionObserver: Any?

    /// Compressed audio kept for background fallback retry
    private var compressedAudioData: Data?
    private var compressedAudioFormat: AudioFormat?

    /// When set, the next converse hop binds to THIS conversation and skips both
    /// the in-app-Ask hint AND the session-continuation pointer resolution —
    /// drives the "continue this thread from the composer" path. Set by
    /// `startRecording(boundTo:)` and `sendTypedText(_:into:)`. Cleared in EVERY
    /// terminal/reset site (success, error, cancel, retry-give-up) so a stuck
    /// value can never re-route a later headless capture into the wrong thread.
    private var pendingConversationID: UUID?

    /// Stamping verdict carried alongside `pendingConversationID`: true when
    /// the pin was set by an IMPLICIT capture (`startCapture(boundTo:
    /// .existing)` — the headless trigger continuing the quick lane, which
    /// must extend the pointer TTL), false when set by the EXPLICIT in-thread
    /// composer / deferred-drain entries, which must never retarget the
    /// per-device quick-capture pointer. Read by the resolver's bound path;
    /// meaningless while the pin is nil.
    private var pendingPinStampsQuickPointer = false

    /// The conversation id minted by the lazy resolver for a `.new` capture
    /// target (where `pendingConversationID` started nil). Lets a DRAFT thread
    /// shell adopt the real id the moment the service creates it, so the open
    /// thread can bind its busy banner + reply refresh to "this" conversation.
    /// Cleared on every terminal/reset boundary alongside `pendingConversationID`.
    private var mintedConversationID: UUID?

    /// True iff the in-flight turn is a typed (no-audio) send. Drives the
    /// `watch-text` modality stamp on the user-turn append; voice path leaves
    /// this false → stamps `watch-voice`.
    private var pendingTypedSend: Bool = false

    /// Where the in-flight turn ENTERED the pipeline (headless / Ask /
    /// composer voice / composer text); nil when no turn is latched. Read
    /// exactly once — at the TOP of `handleBackgroundReply`, BEFORE anything
    /// reaches `clearInFlight` (which wipes it) — to feed the pure
    /// `WatchAutoSpeakVerdict`. Latched at every entry point; cleared on every
    /// terminal/reset boundary alongside the other pending markers, so a stale
    /// tag can never classify a later, unrelated reply.
    private var captureSource: WatchCaptureSource?

    /// Local correlation id for the in-flight wrist turn, minted at trigger
    /// time and logged (as a short prefix via `turnTag`) across
    /// capture → STT → converse → reply/error so ONE session is greppable
    /// end-to-end. NEVER sent to the gateway. Mirrored to the App Group at
    /// converse-start (`persistInFlight`) so a wrist-drop restoration
    /// re-attaches the same id. Cleared on every terminal/reset boundary.
    private var inFlightTurnID: UUID?

    /// Redacted, safe-to-log tag for `inFlightTurnID` — its 8-char prefix, or
    /// "-" when no turn is latched.
    private var turnTag: String { inFlightTurnID.map(WatchLog.shortID) ?? "-" }

    /// Emit the `capture.start` milestone for the just-latched turn. Caller has
    /// already set `captureSource` + `inFlightTurnID`.
    private func logCaptureStart(_ via: String) {
        WatchLog.note(.capture, "capture.start", [
            "turn": turnTag,
            "via": via,
            "src": captureSource.map { String(describing: $0) } ?? "?"
        ])
    }

    /// Derived: true while we have a thread-bound turn in flight. Lets the
    /// thread view show its inline "Thinking…" indicator above the composer
    /// without leaking state-machine internals to the VM.
    var isBusy: Bool {
        switch state {
        case .arming, .recording, .uploading, .waiting: return true
        case .idle, .error: return false
        }
    }

    /// True while audio capture is being armed or is genuinely live for the
    /// in-flight target. Drives the dominant capture overlay in the thread.
    var isCapturing: Bool {
        switch state {
        case .arming, .recording: return true
        default: return false
        }
    }

    /// The conversation the in-flight turn targets, if any. Lets the thread view
    /// gate its capture overlay + busy indicator on "this thread specifically"
    /// so an unrelated headless capture in another thread doesn't surface here.
    /// Prefers the explicit composer pin; falls back to the id minted for a
    /// `.new` draft target so the DRAFT thread shell adopts the real id the
    /// instant the resolver creates it.
    var inFlightConversationID: UUID? {
        pendingConversationID ?? mintedConversationID
    }

    /// True iff a preserved audio capture exists to re-run. Drives the error
    /// view's affordance label: every converse-stage failure has NO file (STT
    /// success deletes it) and the relay paths hand the file to the pending
    /// queue or clean it up — `retry()` without a file is a reset, not a
    /// retry, so the button must not say "Try Again".
    var canRetry: Bool {
        recordingFileURL != nil
    }

    // MARK: - Capture-target entry point (unified Ask + headless)
    //
    // The single entry the navigation layer drives after pushing a (possibly
    // draft) `.capture(target)` thread. The target was resolved at TRIGGER time
    // (existing-vs-new + the gateway ref) so a pointer / default-gateway change
    // mid-recording cannot reroute the turn. Persistence stays LAZY: a `.new`
    // target mints nothing here — it sets the one-shot Ask-ref hint so the
    // resolver mints + binds to the captured ref at the first non-empty
    // transcript. An `.existing` target pins the converse hop to that id.

    /// Start an audio capture bound to `target`. Drives `.arming` → `.recording`
    /// from the service independent of navigation (never gate the mic on the
    /// thread finishing its load). A lingering `.error` is superseded so a fresh
    /// capture is never bricked (mirrors iOS `recorder.dismissError()`).
    func startCapture(boundTo target: WatchCaptureTarget) {
        if case .error = state { dismissError() }
        // Guard-first (mirrors `startRecording(boundTo:)`): refuse BEFORE
        // mutating the pins/tag, so the direct-start headless path (the
        // no-remount fix) can never re-pin / re-label a turn that is already
        // live for another thread, and a refused start never leaves a stale
        // pin behind (the old flow set the pins, then `_startRecording`'s own
        // idle guard silently no-op'd without clearing them). `dismissError()`
        // above already reset a stale `.error` to `.idle`, so a recoverable
        // error still proceeds.
        guard state == .idle else {
            WatchLog.note(.capture, "capture.refused", ["via": "startCapture", "state": state.phaseKind])
            return
        }
        inFlightTurnID = UUID()
        switch target {
        case .existing(let id):
            // Pin the converse hop to this conversation; clear any stale Ask
            // hint so the resolver takes the bound branch, not the mint branch.
            // The pin is IMPLICIT here (headless quick-lane continuation), so
            // it KEEPS stamping rights on the per-device pointer — unlike the
            // explicit composer pins below.
            WatchSettingsReader.shared.clearPendingInAppNewConversationBackend()
            pendingConversationID = id
            pendingPinStampsQuickPointer = true
            // `.existing` only arrives via the headless trigger's quick-lane
            // continuation (resolveHeadlessCaptureTarget) — auto-speak set.
            captureSource = .headless
        case .new(let backendRef):
            // Draft shell: no conversation minted yet. Stamp the captured ref so
            // the resolver's Ask-hint branch mints + binds to EXACTLY this
            // gateway (survives a relaunched background-STT process via the App
            // Group), and leave the pin nil so that branch is taken.
            WatchSettingsReader.shared.setPendingInAppNewConversationBackend(backendRef)
            pendingConversationID = nil
            pendingPinStampsQuickPointer = false
            // Nominally the in-app Ask flow. This branch ALSO serves a headless
            // trigger whose TTL pointer missed (a `.new` draft bound to the
            // default) — both sources are in the auto-speak set, so the
            // mislabel is harmless by construction.
            captureSource = .ask
        }
        pendingTypedSend = false
        mintedConversationID = nil
        logCaptureStart("startCapture")
        _startRecording()
    }

    /// Trigger-time resolution for a HEADLESS capture (Action Button /
    /// ControlWidget): continue the quick-lane thread iff the per-device
    /// pointer is TTL-fresh AND that thread still exists AND it is still bound
    /// to the CURRENT default gateway. The default-gateway re-check is
    /// mirrored from the resolver's pointer branch — the headless path
    /// resolves at trigger time and PINS, and the bound branch deliberately
    /// never re-checks (a pinned thread routes to its persisted ref verbatim),
    /// so without this mirror a re-pointed default would be ignored. Any miss
    /// → a `.new` draft bound to the default.
    func resolveHeadlessCaptureTarget() async -> WatchCaptureTarget {
        let reader = WatchSettingsReader.shared
        if let pointerID = reader.resolveActiveConversationID(),
           let record = try? await store.fetchConversation(id: pointerID),
           record.backend == reader.defaultBackendRef {
            return .existing(pointerID)
        }
        return .new(backendRef: reader.defaultBackendRef)
    }

    // MARK: - Bound-conversation entry points (composer)
    //
    // Two new entry points the in-thread composer drives. Both pin the converse
    // hop to a SPECIFIC `conversationID` (the open thread) — distinct from the
    // always-new headless path (Action Button / ControlWidget / `GigaAction`),
    // which leaves `pendingConversationID` nil and falls through the existing
    // resolver. The headless path is byte-for-byte unchanged.

    /// Voice composer entry: start an audio recording whose transcript will be
    /// appended to `conversationID` on its stored backend (not a new thread).
    /// A lingering `.error` (the root error view sits BEHIND the thread push,
    /// so the user may never have seen it) must not brick the mic — a fresh
    /// capture supersedes it, mirroring iOS `recorder.dismissError()` semantics.
    func startRecording(boundTo conversationID: UUID) {
        if case .error = state { dismissError() }
        // Guard-first (the `sendTypedText` shape): `_startRecording()` would
        // refuse a non-idle state anyway, but by then this wrapper would have
        // already re-pinned + re-tagged a LIVE turn — e.g. a composer mic-tap
        // in thread Y while a headless turn for thread X is `.waiting` would
        // re-label X's turn `.composer` and silently cost it its legitimate
        // arrival auto-speak. Refuse before touching the pins.
        guard state == .idle else { return }
        pendingConversationID = conversationID
        pendingPinStampsQuickPointer = false
        pendingTypedSend = false
        // Composer voice send — NEVER auto-speaks (in-chat hard rule).
        captureSource = .composer
        inFlightTurnID = UUID()
        logCaptureStart("startRecording")
        _startRecording()
    }

    /// Text composer entry: skip audio/STT entirely and run the converse hop
    /// directly with `text` as the user turn, into `conversationID`. A
    /// lingering `.error` is superseded like the voice entry above. Returns
    /// false when the send was a no-op (another turn genuinely in flight) so
    /// the composer keeps the draft instead of silently discarding it.
    @discardableResult
    func sendTypedText(_ text: String, into conversationID: UUID) async -> Bool {
        if case .error = state { dismissError() }
        guard state == .idle else { return false }
        // A NEW capture invalidates any unconsumed one-shot speak request —
        // this turn's reply must be decided on ITS OWN verdict, never inherit
        // a predecessor's. (Placed after the idle guard: a refused no-op send
        // must not drop a legitimately pending request.)
        AutoSpeakMailbox.shared.clear()
        pendingConversationID = conversationID
        pendingPinStampsQuickPointer = false
        pendingTypedSend = true
        // Composer typed send — NEVER auto-speaks (in-chat hard rule).
        captureSource = .composerText
        inFlightTurnID = UUID()
        logCaptureStart("sendTypedText")
        await startConverseHop(transcript: text)
        return true
    }

    // MARK: - Recording

    /// Shared inner — `startRecording(boundTo:)` and `startCapture(boundTo:)`
    /// both land here. Pin lifecycle is the caller's responsibility (the bound
    /// wrappers set the pin first).
    ///
    /// Drives `.arming` synchronously up front so the capture overlay renders
    /// the instant the thread is pushed — the mic itself comes up off the main
    /// path (permission → scene-active poll → audio-session activation) and only
    /// then flips to `.recording` + fires the `.start` haptic.
    private func _startRecording() {
        guard state == .idle else { return }

        // A NEW capture invalidates any unconsumed one-shot speak request —
        // the mic must never start with a pending speak waiting to fire under
        // it (the thread view also stops its speaker on capture; this kills
        // the not-yet-spoken request the same way).
        AutoSpeakMailbox.shared.clear()

        // Mark the recording flow as active so the app's notification-permission
        // `.task` defers itself and avoids colliding with the mic prompt.
        WatchRecordingCoordinator.shared.isRecordingFlowActive = true

        // Show "Starting…" immediately (independent of nav / thread loading).
        state = .arming

        // B1: if no STT envelope has resolved this process and the iPhone is
        // reachable, kick the (coalesced, idempotent) settings pull NOW so its
        // round-trip overlaps mic-permission + recording + compression. By the
        // time the upload path resolves the STT provider the reply has usually
        // applied (lastEnvelopeTimestamp > 0), so the post-compression freshness
        // wait collapses to a short remainder instead of charging a full
        // round-trip to the user. Coalesces onto any activation/reachability
        // pull already running, so it never double-round-trips.
        if WatchSettingsReader.shared.lastEnvelopeTimestamp == 0, WCSession.default.isReachable {
            Task { _ = await WatchSessionManager.shared.pullSettingsFromPhone() }
        }

        // Ownership claim BEFORE the speaker stop — ordering is load-bearing:
        // `speech.stop()` drives the speaker's terminal release, and that
        // release must observe a SUPERSEDED claim so its deferred
        // `setActive(false)` no-ops. A TTS teardown racing the mic claim
        // would deactivate the session the recorder is about to configure
        // (dead capture).
        let claim = sessionCoordinator.claim(.recording)
        sessionClaim = claim
        // Fresh tenure — no config committed yet. A death before the
        // `.record` config lands must deactivate (duck-restore for a
        // superseded TTS turn), so the flag starts pessimistic.
        sessionConfigured = false

        // Any TTS playing in the open thread must yield the audio session
        // before we activate the recording category (guardrail 7). Best-effort;
        // the shared speaker stops in-flight playback synchronously.
        speech.stop()

        // Supersede token + arm timestamp, captured BEFORE the async hops:
        // the token gates the Task against a cancel landing mid-arm; the
        // timestamp feeds the arm→record latency milestone.
        let generation = captureGeneration
        let armedAt = Date()

        Task {
            // Request mic permission
            let granted = await recordPermissionRequest()
            // Cancel-supersede: the user may have cancelled (overlay X /
            // composer) while the permission prompt was up — bail before any
            // state write, or a cancelled turn's arm Task would stomp the
            // `.idle` reset (and, past the session hop below, flip an
            // orphaned live mic back to `.recording`).
            guard generation == captureGeneration else { return }
            guard granted else {
                WatchLog.error(.capture, "mic.denied", ["turn": turnTag])
                releaseSessionClaim(claim)
                // xcstrings
                state = .error(message: String(localized: "Microphone access is required. Please enable it in Settings."))
                WatchRecordingCoordinator.shared.isRecordingFlowActive = false
                return
            }

            // Wait briefly for the scene to become active before activating
            // the audio session. On a cold launch foregrounded by the
            // ControlWidget intent, `applicationState` can still be `.inactive`
            // when this Task runs; activating the session in that window can
            // fail intermittently.
            await Self.waitForActiveScene(maxWaitSeconds: 1.0, pollIntervalMs: 50)
            guard generation == captureGeneration else { return }

            do {
                // Configure + activate the record session through the
                // coordinator's FIFO config lane (the injectable seam runs
                // inside it). The lane keeps the audio-server IPC off the
                // main thread — on MainActor it stalls the navigation
                // transition, and a distressed audio daemon would freeze the
                // UI outright — AND re-checks the claim at ISSUE time, so a
                // superseded turn's queued config is skipped instead of
                // landing on a newer playback turn's session.
                let activator = recordSessionActivator
                let configured = try await sessionCoordinator.runConfig(for: claim) {
                    try await activator()
                }
                guard configured else {
                    // Claim superseded while the op queued — the coordinator
                    // never issued the IPC; the turn is dead regardless of
                    // the generation token.
                    bailStaleArm(releasing: claim)
                    return
                }
                // The `.record` config is committed — from here on this
                // tenure's release posture is PLAIN (the session staying
                // active in `.record` is deliberate), even if the turn dies
                // on the guards below.
                sessionConfigured = true

                // Cancel-supersede AFTER the activation await (second belt
                // behind the coordinator's claim gate): a cancel landing
                // while the IPC was in flight has already reset the machine —
                // bail silently, no error state, no recorder. The session
                // having activated for a dead turn is harmless: the `.record`
                // session staying active is the recorder's normal posture
                // anyway.
                if bailIfStaleArm(generation: generation, claim: claim) { return }

                // Create temp file. The `watch-capture-` prefix is load-bearing,
                // not cosmetic: this is the raw voice recording, and every
                // cleanup path for it is in-process (`cleanupRecordingFile`, the
                // upload defers). A jetsam or force-quit mid-turn therefore
                // orphans it, and only `TempScratchSweeper` can reclaim it — by
                // prefix. A bare UUID name is invisible to that sweep forever.
                let fileURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent("watch-capture-\(UUID().uuidString)")
                    .appendingPathExtension("m4a")

                // Recording settings (M4A, 48kHz mono AAC — compressed to 16kHz before upload)
                let settings: [String: Any] = [
                    AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                    AVSampleRateKey: 48000.0,
                    AVNumberOfChannelsKey: 1,
                    AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
                ]

                // Recorder init stays HERE, on MainActor — `AVAudioRecorder`
                // is non-Sendable and must never cross the `@concurrent`
                // activation hop above.
                let recorder = try AVAudioRecorder(url: fileURL, settings: settings)
                recorder.record(forDuration: Constants.maxAudioDuration)

                self.audioRecorder = recorder
                self.recordingFileURL = fileURL
                self.recordingTime = 0
                self.nearMaxDuration = false
                // Only NOW is the mic genuinely live — flip off `.arming` and
                // fire the start haptic (the overlay swaps "Starting…" for the
                // recording UI). Pairs with the `waitForActiveScene` poll above.
                // Flip timestamp BEFORE the state assignment so `stopRecording`
                // can never observe `.recording` without it.
                self.recordingStartedAt = Date()
                self.state = .recording

                // Haptic: recording started
                WKInterfaceDevice.current().play(.start)

                // Resume recording after audio session interruptions (e.g. wrist-down)
                observeInterruptions()

                // Start timer for elapsed time display
                startTimer()

                // Soft warning + hard auto-stop timers.
                scheduleDurationGuards()

                WatchLog.note(.capture, "recording.start", ["turn": turnTag, "armMs": Int(Date().timeIntervalSince(armedAt) * 1000)])
            } catch {
                // A stale throw (cancel landed while the activation IPC was
                // in flight, then the activator failed) is nobody's news —
                // the machine is already reset; surfacing an error here
                // would stomp the user's cancel.
                if bailIfStaleArm(generation: generation, claim: claim) { return }
                WatchLog.error(.capture, "recording.failed", ["turn": turnTag, "code": (error as NSError).code])
                releaseSessionClaim(claim)
                // xcstrings
                state = .error(message: String(localized: "Could not start recording."))
                WatchRecordingCoordinator.shared.isRecordingFlowActive = false
            }
        }
    }

    /// Configures + activates the shared session for recording. `@concurrent`
    /// because both calls are audio-server IPC — hundreds of milliseconds
    /// routinely, seconds when the daemon is distressed — and on MainActor
    /// they stall the navigation transition the arm runs concurrently with.
    /// The synchronous `setActive(true)` is deliberate: only PLAYBACK
    /// sessions need the async `activate(options:completionHandler:)` API on
    /// watchOS (see the rationale in `WatchReplySpeaker`'s header); a
    /// `.record` session activates fine synchronously — the hop only moves
    /// the IPC off the main thread.
    @concurrent
    nonisolated static func activateRecordSession() async throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .default)
        try session.setActive(true)
    }

    /// Drops this service's session ownership. Release posture branches on
    /// whether the tenure's `.record` config ever committed:
    /// - configured → PLAIN release: the `.record` session staying active
    ///   after capture is its normal posture (the next speak re-categorizes
    ///   it anyway).
    /// - NOT configured → `releaseAndDeactivate`: the claim may have
    ///   superseded a live TTS turn whose `.playback + .duckOthers` config
    ///   is still the session's ACTIVE state — mic denied, a cancel during
    ///   arming, an activator throw, a stale bail all die here — and without
    ///   the guarded deactivation the user's ducked music never comes back.
    ///   Harmless no-op when the session was never active; the coordinator's
    ///   grace window + issue-time re-check keep it off any newer claimant.
    /// Token-scoped either way: a superseded turn's late bail can never drop
    /// a NEWER turn's live claim (stale tokens are coordinator no-ops).
    private func releaseSessionClaim(_ claim: WatchAudioSessionCoordinator.Claim?) {
        guard let claim else { return }
        if sessionConfigured {
            sessionCoordinator.release(claim)
        } else {
            sessionCoordinator.releaseAndDeactivate(claim)
        }
        if sessionClaim == claim { sessionClaim = nil }
    }

    /// Silent stale-arm exit shared by the arm Task's bail sites: log the
    /// milestone and drop the claim (posture decided by `sessionConfigured`)
    /// with no error state — a turn the user already cancelled must never
    /// surface a toast.
    private func bailStaleArm(releasing claim: WatchAudioSessionCoordinator.Claim) {
        WatchLog.note(.capture, "capture.staleArm", ["turn": turnTag])
        releaseSessionClaim(claim)
    }

    /// Returns `true` (after taking the stale-arm exit) when the turn died
    /// while an arm await was in flight — a cancel bumped the generation, or
    /// the machine already left `.arming`.
    private func bailIfStaleArm(generation: Int, claim: WatchAudioSessionCoordinator.Claim) -> Bool {
        guard generation != captureGeneration || state != .arming else { return false }
        bailStaleArm(releasing: claim)
        return true
    }

    /// Polls `WKApplication.applicationState` until `.active` or the timeout
    /// elapses. Used at the start of recording to dodge an audio-session
    /// activation race when the app was cold-launched by the ControlWidget
    /// intent and `applicationState` has not yet finished transitioning.
    private static func waitForActiveScene(maxWaitSeconds: TimeInterval, pollIntervalMs: UInt64) async {
        let deadline = Date().addingTimeInterval(maxWaitSeconds)
        while Date() < deadline {
            if WKApplication.shared().applicationState == .active { return }
            try? await Task.sleep(nanoseconds: pollIntervalMs * 1_000_000)
        }
    }

    func stopRecording() {
        guard state == .recording, let recorder = audioRecorder else { return }

        // Double-tap grace: a stop landing inside the mis-tap window after the
        // `.recording` flip is the trailing half of a double-tap (the capture
        // overlay mounts under the user's finger the instant arming
        // completes), not an intentional stop. Discard silently — no `.stop`
        // haptic, no upload, no error banner. The max-duration hard stop
        // (also a `stopRecording()` caller) fires minutes in, so it can never
        // land inside the window.
        let elapsed = recordingStartedAt.map { Date().timeIntervalSince($0) }
        if WatchCaptureGuard.isMisTapStop(elapsedSinceRecordingFlip: elapsed) {
            WatchLog.note(.capture, "capture.tooShort", [
                "turn": turnTag,
                "via": "grace",
                "ms": Int((elapsed ?? 0) * 1000)
            ])
            // `cancelRecording()` IS the discard: stops the recorder, removes
            // the file, clears pins/hint, resets `.idle`. Every capture
            // entry point re-establishes its own pins, so nothing the NEXT
            // capture needs is lost.
            cancelRecording()
            return
        }

        recorder.stop()
        // Capture over — drop session ownership (plain release; the `.record`
        // session stays active) so a follow-up speak's terminal teardown is
        // arbitrated against a claim that actually exists.
        releaseSessionClaim(sessionClaim)
        stopTimer()
        cancelDurationGuards()
        removeInterruptionObserver()

        // Haptic: recording stopped
        WKInterfaceDevice.current().play(.stop)

        WatchLog.note(.capture, "recording.stop", ["turn": turnTag, "secs": String(format: "%.1f", recordingTime)])

        // Transition to processing
        processRecording()
    }

    /// Cancel an in-flight capture. Handles BOTH `.arming` (mic not yet live —
    /// `audioRecorder` is nil, the `?.stop()` is a no-op) and `.recording`.
    /// Because no conversation is minted until the first non-empty transcript, a
    /// cancel before any speech leaves ZERO conversation behind (no eager-mint,
    /// no delete-on-exit needed — guardrail 2).
    func cancelRecording() {
        // Snapshot BEFORE the reset below: only a cancel that actually retired
        // an active capture counts as a discard. `.idle`/`.error` entries (no
        // current caller, but defensive) must not bump `captureDiscardCount` —
        // a spurious bump would pop an unrelated live draft.
        let retiredActiveCapture: Bool
        switch state {
        case .idle, .error: retiredActiveCapture = false
        case .arming, .recording, .uploading, .waiting: retiredActiveCapture = true
        }
        // Supersede FIRST: bump the generation and kill the stored pipeline
        // Task so an in-flight STT upload can never resurrect this turn —
        // `.cancel()` propagates into the async foreground URLSession upload;
        // the generation gate covers the background-daemon fallback, whose
        // upload outlives Task cancellation. The `.waiting`-stage converse
        // hop is deliberately untouched (wrist-drop resilience): by
        // then the user turn is already in the store.
        captureGeneration += 1
        processTask?.cancel()
        processTask = nil
        // The iPhone-relay leg is enqueue-first durable and its Task is
        // deliberately detached from `processTask`, so neither the generation
        // bump nor the Task cancel can retire it — the queue would simply drain
        // the turn later (in a relaunched process the generation is 0 again).
        // CLAIMING the entry is the authoritative cancel: it removes the entry,
        // deletes the queued audio (a cancel must strand nothing on disk)
        // and cancels any outstanding WCSession transfer. Claim-nil is fine
        // (a racing reply already consumed the verdict).
        if let relayRequestID = pendingRelayRequestID {
            _ = AppleRelayPendingQueue.shared.claimEntry(requestID: relayRequestID)
            pendingRelayRequestID = nil
        }
        audioRecorder?.stop()
        // Release posture rides `sessionConfigured`: a cancel after the
        // `.record` config committed leaves the session alone (plain); a
        // cancel mid-arm — the config never landed — deactivates, so a
        // superseded TTS turn's `.duckOthers` posture can't outlive the
        // capture. The cancelled arm Task's own late bail no-ops on this
        // already-released token.
        releaseSessionClaim(sessionClaim)
        stopTimer()
        cancelDurationGuards()
        removeInterruptionObserver()
        cleanupRecordingFile()
        compressedAudioData = nil
        compressedAudioFormat = nil
        nearMaxDuration = false
        state = .idle
        recordingTime = 0
        WatchRecordingCoordinator.shared.isRecordingFlowActive = false
        // A cancelled in-app Ask must not leave a stale pending-backend hint
        // that a later headless trigger would consume (no silent reroute).
        WatchSettingsReader.shared.clearPendingInAppNewConversationBackend()
        // Symmetric: a cancelled bound-conversation recording must drop the
        // pinned-thread hint too, or the NEXT capture (headless or otherwise)
        // would inherit it and land in the wrong thread.
        pendingConversationID = nil
        mintedConversationID = nil
        pendingTypedSend = false
        captureSource = nil
        inFlightTurnID = nil
        if retiredActiveCapture {
            captureDiscardCount += 1
        }
    }

    // MARK: - Processing Pipeline

    private func processRecording() {
        guard let fileURL = recordingFileURL else {
            // xcstrings
            state = .error(message: String(localized: "Recording file not found."))
            WatchRecordingCoordinator.shared.isRecordingFlowActive = false
            return
        }

        state = .uploading

        // Supersede token for the STT-stage chain, captured before the Task
        // so a cancel landing even before the body runs is still detected.
        // The Task itself is stored so `cancelRecording()` can cancel it
        // (which propagates into the async foreground upload).
        let generation = captureGeneration
        processTask = Task {
            // 1. Identity is no longer required for the upload itself (the
            // Mistral STT call is keyed by the bearer-token in
            // `WatchIdentityResolver.getSTTAPIKey()`). User-id resolution is
            // still wired up at app launch for cross-device continuity, but
            // we deliberately don't gate the recording flow on it here —
            // missing identity surfaces in the API-key check instead.

            // 2. Compress audio (48kHz → 16kHz mono AAC, ~4-5x smaller).
            let originalData: Data
            do {
                originalData = try Data(contentsOf: fileURL)
            } catch {
                // xcstrings
                state = .error(message: String(localized: "Could not read recording."))
                WatchRecordingCoordinator.shared.isRecordingFlowActive = false
                return
            }

            // Too-short floor: a header-only husk (double-tap mis-stop, an
            // interruption edge) would run the compression-failure cascade
            // plus a billed STT round-trip just to come back as "no speech" —
            // an error that blames the user's voice. Bail BEFORE compression
            // as a silent discard. Sits here (not only in `stopRecording`'s
            // grace window) so it also covers `retry()` re-runs and the
            // iPhone-relay branch below, which would otherwise enqueue the
            // husk durably.
            if WatchCaptureGuard.isTooShortCapture(byteCount: originalData.count) {
                WatchLog.note(.capture, "capture.tooShort", ["turn": turnTag, "via": "bytes", "bytes": originalData.count])
                // Same discard semantics as the grace window (see
                // `stopRecording`): `cancelRecording()` removes the file
                // and resets `.idle` without an error banner.
                cancelRecording()
                return
            }

            let compressionResult = await AudioCompressor.compress(originalData)
            let audioData = compressionResult.data
            let audioFormat = compressionResult.format

            #if DEBUG
            let ratio = Int(compressionResult.compressionRatio * 100)
            print("[Watch] Compression: \(compressionResult.originalSizeBytes) → \(compressionResult.compressedSizeBytes) bytes (\(ratio)%) in \(compressionResult.compressionTimeMs)ms")
            #endif

            // Cache for potential background fallback
            compressedAudioData = audioData
            compressedAudioFormat = audioFormat

            // Cancel-supersede: bail before ANY dispatch when the user
            // cancelled during compression — covers both branches below
            // (a cancelled turn must neither upload nor enqueue durably;
            // `cancelRecording()` already removed the audio file).
            guard generation == captureGeneration else { return }

            // Fresh-process race guard: no envelope has EVER been applied this
            // process AND the iPhone is reachable → pull current settings with a
            // short budget before resolving the provider, else a record fired
            // seconds after install resolves the apple-on-device default while the
            // real config sits in the lazy transferUserInfo queue. Reads
            // WCSession.default.isReachable directly — the published mirror updates
            // asynchronously. On timeout we proceed with current state; the iPhone
            // relay self-heals a stale nil-provider request anyway.
            //
            // The record-start prefetch (see `_startRecording`) already kicked the
            // same coalesced pull, so by here the round-trip has usually applied
            // and this guard is skipped (lastEnvelopeTimestamp > 0). This await is
            // the short remainder for the rare case the prefetch is still in
            // flight — a reachable sendMessage round-trip is sub-second, so 1.5 s
            // is a generous cap that closes the stale cloud-direct window without
            // charging a full 2.5 s to the user.
            if WatchSettingsReader.shared.lastEnvelopeTimestamp == 0, WCSession.default.isReachable {
                _ = await WatchSessionManager.shared.pullSettingsFromPhone(maxWait: 1.5)
            }

            // Resolve the active STT provider from settings. iPhone broadcasts
            // the active preset via WCSession envelope; we look up the matching
            // registry entry (falls back to Mistral Voxtral on unknown ID).
            let activePresetID = WatchSettingsReader.shared.activePresetID
            let provider = STTProvider.lookup(id: activePresetID)

            // iPhone-relay branch. Two provider
            // families MUST transcribe on iPhone, never on the wrist:
            //   1. Apple on-device (`apple-on-device`) — watchOS has no Speech
            //      framework, so the Watch ships the compressed .m4a to iPhone.
            //   2. The BYO custom OpenAI-compatible endpoint
            //      (`dynamicEndpointKey != nil`) — the Watch has no Tailscale,
            //      and the iPhone alone holds the base URL, cert pin, and long
            //      timeout. Transcribing it directly here is impossible AND a
            //      PRIVACY BUG: `STTProvider.lookup` falls back to Mistral on a
            //      provider the Watch can't reach, which would ship the user's
            //      audio + Mistral key to Mistral instead of their own server.
            // Declarative predicate (mirrors iPhone's `dynamicEndpointKey`
            // dispatch) rather than a second scattered `id ==` check.
            //
            // The compressed audio path mirrors the cloud-upload branch's bytes
            // (so iPhone receives the same content the user heard back in QA) —
            // but we write the bytes out as a separate file because
            // `AppleSpeechRelayCoordinator.relay` consumes a URL and the existing
            // `fileURL` is the unprocessed recorder output. When compression
            // FAILED (`didCompress == false` — the compressor fell back to the
            // original bytes), the on-disk recorder file already IS those
            // bytes, so we reuse `fileURL` directly.
            let needsiPhoneRelay = activePresetID == "apple-on-device"
                || provider.dynamicEndpointKey != nil
            if needsiPhoneRelay {
                let relayURL: URL
                if compressionResult.didCompress {
                    // Write compressed bytes to a fresh temp file so the
                    // pending-queue / coordinator can own its own URL.
                    let url = FileManager.default.temporaryDirectory
                        .appendingPathComponent("apple-relay-out-\(UUID().uuidString)")
                        .appendingPathExtension("m4a")
                    do {
                        try audioData.write(to: url)
                        relayURL = url
                    } catch {
                        // xcstrings
                        state = .error(message: String(localized: "Could not prepare recording for iPhone."))
                        WatchRecordingCoordinator.shared.isRecordingFlowActive = false
                        return
                    }
                } else {
                    relayURL = fileURL
                }
                // Stamp the provider ID only for the BYO custom endpoint so the
                // iPhone routes to `STTClient.transcribe(provider:)`; the Apple
                // path passes nil (nil now means the iPhone transcribes with ITS
                // current active provider — the settings authority; for an
                // Apple-active user that is Apple on-device, unchanged).
                let relayProviderID = provider.dynamicEndpointKey != nil ? provider.id : nil
                // Deliberately UNSTRUCTURED: the relay path is enqueue-first
                // durable, and a later `cancelRecording()` (which cancels the
                // stored `processTask`) must NOT propagate into the relay
                // await — a cancellation surfacing as an error there would
                // claim-and-remove the queued entry, killing the deferred
                // delivery the queue exists to guarantee.
                Task {
                    await runRelay(
                        audioFileURL: relayURL,
                        originalFileURL: fileURL,
                        providerID: relayProviderID
                    )
                }
                return
            }

            let request = WatchSTTRequest(
                audioData: audioData,
                audioFormat: audioFormat,
                language: WatchSettingsReader.shared.preferredLanguage,
                provider: provider,
                customModel: WatchSettingsReader.shared.activeCustomModel
            )
            await runSTTUpload(request: request, audioFileURL: fileURL, provider: provider, generation: generation)
        }
    }

    /// iPhone-relay path (claim-token, enqueue-first). Mints the requestID,
    /// persists the entry — with the audio MOVED into the queue-owned
    /// App-Group directory — BEFORE the first delivery attempt, then ships it
    /// via `AppleSpeechRelayCoordinator` (Apple on-device when
    /// `providerID == nil`, the BYO custom endpoint otherwise).
    ///
    /// Why enqueue-first: the old flow only enqueued AFTER the 30 s timeout,
    /// so a process death (wrist drop → suspend → jetsam) inside that window
    /// stranded the audio in purgeable tmp with no queue entry — the ask
    /// silently died. Now durability precedes the first byte leaving the
    /// Watch, and EVERY terminal transition is claim-gated so a live success
    /// and a late `reconcile` can never both dispatch the same turn.
    ///
    /// Timeout (`.sttProviderUnreachable`) is no longer a failure, just a UX
    /// deferral: the entry is already queued, the reply reconciles whenever
    /// it lands, and the toast (provenance-tagged via
    /// `lastErrorIsRelayDeferral`) auto-clears at that point.
    ///
    /// Internal (not private) + routed through the `relayTranscribe` seam so the
    /// cancel-supersede contract is unit-testable (`WatchCaptureGuardTests`).
    func runRelay(audioFileURL: URL, originalFileURL: URL, providerID: String?) async {
        let language = WatchSettingsReader.shared.preferredLanguage
        // Cancel-supersede token, re-checked once the reply await returns. This
        // Task is detached from `processTask` on purpose (a wrist-drop must not
        // kill a relay), so the generation is the ONLY thing that tells a live
        // reply apart from one the user already cancelled.
        let generation = captureGeneration

        // Claim token — the ONE id every delivery attempt / retry / late
        // reply for this capture correlates on (the iPhone dedups by it).
        let requestID = UUID().uuidString

        // ENQUEUE-FIRST. The queue takes SOLE ownership of the audio: if the
        // relay clip is a fresh compressed copy, the original recorder file
        // is now redundant — drop it (retain exactly ONE copy, the queued
        // one), and clear our handle either way. `enqueue` MOVES the clip
        // into the queue-owned directory, so we must relay from the URL it
        // returns, not the tmp one we passed in.
        if audioFileURL != originalFileURL {
            try? FileManager.default.removeItem(at: originalFileURL)
        }
        recordingFileURL = nil
        let queuedAudioURL = AppleRelayPendingQueue.shared.enqueue(
            requestID: requestID,
            audioFileURL: audioFileURL,
            language: language,
            providerID: providerID,
            conversationID: pendingConversationID
        )
        // Publish the id BEFORE the first byte leaves, so a cancel landing at
        // any point from here on can claim the entry out from under the relay.
        pendingRelayRequestID = requestID

        do {
            let transcript = try await relayTranscribe(requestID, queuedAudioURL, language, providerID)
            if bailIfCancelledRelay(generation: generation) { return }
            // The live relay leg is over: every branch below either claims the
            // entry itself or (deferral) deliberately hands it to the queue for
            // a later drain. Either way a subsequent cancel must NOT claim this
            // id — that cancel belongs to whatever capture comes next, and a
            // deferred turn is not its to destroy.
            pendingRelayRequestID = nil
            // STT success — CLAIM before dispatching (exactly-once). The
            // claim removes the entry + deletes the queued audio + cancels
            // any outstanding transfer. Claim-nil ⇒ superseded: a late-reply
            // `reconcile` already claimed + dispatched this very turn (e.g.
            // the timeout fired, the reply reconciled, and a drain re-fire's
            // continuation ALSO got the cached verdict) — reset silently, the
            // other path's hop is the one that counts.
            guard AppleRelayPendingQueue.shared.claimEntry(requestID: requestID) != nil else {
                compressedAudioData = nil
                compressedAudioFormat = nil
                WatchRecordingCoordinator.shared.isRecordingFlowActive = false
                state = .idle
                recordingTime = 0
                return
            }
            compressedAudioData = nil
            compressedAudioFormat = nil
            WatchRecordingCoordinator.shared.isRecordingFlowActive = false
            await startConverseHop(transcript: transcript)
        } catch {
            if bailIfCancelledRelay(generation: generation) { return }
            pendingRelayRequestID = nil
            // `AppError` has associated values, so Equatable is not
            // synthesized — `if case` is the canonical pattern match.
            if let appError = error as? AppError,
               case .sttProviderUnreachable = appError {
                // Reply-wait timeout. The entry is ALREADY queued (enqueue-
                // first) — do NOT enqueue again. Surface the deferral toast
                // and tag its provenance so the queue's drain/reconcile may
                // auto-clear it when the transcript lands (flag assignment
                // must FOLLOW the state assignment — `state.didSet` clears
                // the flag on every transition).
                // xcstrings: relay-convergence fix
                state = .error(message: String(localized: "Sent to iPhone. Your transcript will arrive when it reconnects."))
                lastErrorIsRelayDeferral = true
                compressedAudioData = nil
                compressedAudioFormat = nil
                WatchRecordingCoordinator.shared.isRecordingFlowActive = false
                return
            }
            if let appError = error as? AppError,
               case .appleSpeechModelNotInstalled = appError {
                // iPhone responded but the model isn't installed — no point
                // keeping the entry queued (the next attempt fails the same
                // way until the user installs the model on iPhone). Claim
                // first: claim-nil ⇒ a racing reconcile already surfaced this
                // verdict → silent reset.
                guard AppleRelayPendingQueue.shared.claimEntry(requestID: requestID) != nil else {
                    compressedAudioData = nil
                    compressedAudioFormat = nil
                    WatchRecordingCoordinator.shared.isRecordingFlowActive = false
                    state = .idle
                    recordingTime = 0
                    return
                }
                compressedAudioData = nil
                compressedAudioFormat = nil
                // xcstrings: stt-dictation-default
                state = .error(message: String(localized: "On-device voice isn't ready on your iPhone yet. Open Conduck there to set it up."))
                WatchRecordingCoordinator.shared.isRecordingFlowActive = false
                return
            }
            // Other AppError (or unknown) — permanent for this capture. Claim
            // first (same exactly-once rule as above), then surface.
            guard AppleRelayPendingQueue.shared.claimEntry(requestID: requestID) != nil else {
                compressedAudioData = nil
                compressedAudioFormat = nil
                WatchRecordingCoordinator.shared.isRecordingFlowActive = false
                state = .idle
                recordingTime = 0
                return
            }
            compressedAudioData = nil
            compressedAudioFormat = nil
            WatchLog.error(.stt, "stt.prep.failed", ["turn": turnTag, "code": (error as? AppError)?.errorCode ?? -1])
            let message = (error as? AppError)?.errorDescription
                ?? String(localized: "Could not send recording. Please try again.")
            state = .error(message: message)
            WatchRecordingCoordinator.shared.isRecordingFlowActive = false
        }
    }

    /// True when the capture that owns this relay leg was superseded while the
    /// reply was in flight. On THIS path that means exactly one thing — a
    /// `cancelRecording()` (the overlay X, the composer's in-flight cancel): the
    /// `.uploading` watchdog is armed only by `fallbackSTTToBackgroundUpload`
    /// (the cloud leg), so it can never bump the generation under a relay. The
    /// cancel has therefore already claimed + removed the queue entry (deleting
    /// the queued audio) and reset the machine, so the late reply must vanish
    /// without a trace: no conversation minted, and NO error banner over the
    /// user's own cancel (same posture as `bailStaleArm`).
    private func bailIfCancelledRelay(generation: Int) -> Bool {
        guard generation != captureGeneration else { return false }
        pendingRelayRequestID = nil
        compressedAudioData = nil
        compressedAudioFormat = nil
        WatchLog.note(.stt, "relay.staleCancel", ["turn": turnTag])
        return true
    }

    /// Foreground upload path. On any error, falls back to the background
    /// URLSession uploader so the system daemon can finish the upload even
    /// if the app suspends (user drops wrist).
    ///
    /// `generation` is the capture-supersede token captured at
    /// `processRecording` — BOTH exits re-check it after the await, so a
    /// cancelled turn's late transcript is dropped (and never takes the
    /// background fallback, which would resurrect it). Internal (not private)
    /// + routed through the `sttUpload` seam so the cancel-supersede contract
    /// is unit-testable (`WatchCaptureGuardTests`).
    func runSTTUpload(request: WatchSTTRequest, audioFileURL: URL, provider: STTProvider, generation: Int) async {
        do {
            let sentAt = Date()
            let response = try await sttUpload(request, provider)
            // Cancel-supersede: `cancelRecording()` ran while the upload was
            // in flight — drop the transcript. The pins/hint it would route
            // by are already cleared, so chaining would mint (or land) the
            // turn in a conversation the user never chose.
            guard generation == captureGeneration else {
                WatchLog.note(.stt, "stt.dropped", ["reason": "superseded", "provider": provider.id])
                // Privacy belt: cancel already removed the file; cover the narrow
                // interleave where our handle cleared first.
                try? FileManager.default.removeItem(at: audioFileURL)
                return
            }
            let text = response.text

            // Foreground STT succeeded — clean up the captured audio file here.
            // (Background fallback hands cleanup off to the uploader delegate
            // so we DON'T `cleanupRecordingFile()` on the fallback branch.)
            cleanupRecordingFile()
            compressedAudioData = nil
            compressedAudioFormat = nil
            WatchRecordingCoordinator.shared.isRecordingFlowActive = false

            // Privacy: never log the transcript itself (docs/ai-context/spec.md "Privacy & Security").
            // Char count + provider + upload latency is enough to diagnose
            // without leaking content.
            WatchLog.note(.stt, "stt.decoded", [
                "turn": turnTag,
                "provider": provider.id,
                "chars": text.count,
                "bytes": request.audioData.count,
                "ms": Int(Date().timeIntervalSince(sentAt) * 1000)
            ])

            // Chain the agent hop (always background).
            await startConverseHop(transcript: text)

        } catch {
            // Cancel-supersede: the thrown error here is usually the
            // cancellation itself (`processTask.cancel()` aborts the
            // URLSession call). A superseded turn must NEVER take the
            // background fallback — the daemon would finish the upload and
            // resurrect the cancelled turn.
            guard generation == captureGeneration else {
                WatchLog.note(.stt, "stt.dropped", ["reason": "superseded", "provider": provider.id])
                try? FileManager.default.removeItem(at: audioFileURL)
                return
            }
            let appError = error as? AppError
            // A NON-retryable error (no speech, auth failure, bad audio, …) will
            // not succeed on a background re-upload of the SAME audio — surface
            // it directly instead of a pointless second round-trip. Only
            // retryable transport errors fall back to the background daemon
            // (covers a wrist-drop / app-suspend mid-upload). With the unified
            // empty-transcript guard, a 200-empty now arrives here as
            // `.noSpeechDetected` and is surfaced, not silently dropped.
            if let appError, !appError.isRetryable {
                WatchLog.error(.stt, "stt.terminal", ["turn": turnTag, "code": appError.errorCode])
                cleanupRecordingFile()
                compressedAudioData = nil
                compressedAudioFormat = nil
                // Mirror handleBackgroundFailure: clear in-flight markers + the
                // bound-thread pin BEFORE surfacing .error, so a stale pin can't
                // scope this STT error's banner to an unrelated thread and the
                // next capture starts clean. (Deferred Apple-relay entries drain
                // at the idle edge via dismissError — not here, where the
                // .error state makes a drain a no-op.)
                clearInFlight()
                state = .error(message: appError.errorDescription
                    ?? String(localized: "Could not send recording. Please try again."))
                WatchRecordingCoordinator.shared.isRecordingFlowActive = false
                return
            }

            WatchLog.note(.stt, "stt.fallback", ["turn": turnTag, "code": appError?.errorCode.description ?? "transport"])
            fallbackSTTToBackgroundUpload(request: request, audioFileURL: audioFileURL, provider: provider, generation: generation)
        }
    }

    /// Fall back to background URLSession when foreground STT upload fails.
    /// Cleanup of `audioFileURL` is OWNED by `WatchAudioUploader`'s
    /// `didCompleteWithError` delegate (privacy mandate) — DO NOT call
    /// `cleanupRecordingFile()` on this branch, or the background daemon
    /// will resume and find an empty file. `generation` rides along so the
    /// delegate can drop a transcript whose capture was cancelled meanwhile.
    private func fallbackSTTToBackgroundUpload(request: WatchSTTRequest, audioFileURL: URL, provider: STTProvider, generation: Int) {
        do {
            try WatchAudioUploader.shared.uploadSTT(request: request, audioFileURL: audioFileURL, provider: provider, generation: generation)
            // Hand the file off to the background uploader; clear our handle
            // without deleting so the daemon can read it. STT is now in flight
            // in the background — the converse hop chains from the background
            // STT delegate (`WatchAudioUploader.handleSTTCompletion`) once the
            // transcript lands, possibly after suspend+relaunch. Stay in
            // `.uploading` (no `.done`, no auto-dismiss) so the user sees the
            // pipeline is still working.
            recordingFileURL = nil
            state = .uploading
            // Live-app stall guard: the background session now carries a real
            // resource timeout, but `.uploading` is in-memory-only (it does
            // not survive relaunch, and the 600 s stale-guard covers only the
            // persisted `.waiting` marker) — arm a watchdog so a wedged
            // daemon can't park the spinner forever while the app stays live.
            armUploadingWatchdog()
            compressedAudioData = nil
            compressedAudioFormat = nil
            WatchRecordingCoordinator.shared.isRecordingFlowActive = false
        } catch {
            // xcstrings
            WatchLog.error(.stt, "stt.fallback.failed", ["turn": turnTag, "code": (error as NSError).code])
            state = .error(message: String(localized: "Could not send recording. Please try again."))
            WatchRecordingCoordinator.shared.isRecordingFlowActive = false
        }
    }

    /// Arm the live-app `.uploading` watchdog. Budget = the STT session's
    /// resource timeout + slack, so the session's own timeout normally fires
    /// first and lands in the failure funnel via the delegate — this only
    /// catches the wedged-daemon case where it never does. On expiry it
    /// mirrors `handleBackgroundFailure` semantics (retryable error, live
    /// machine unstuck) and deletes NOTHING: audio-file cleanup is owned by
    /// the uploader's `didCompleteWithError` (privacy mandate), which may still
    /// arrive for the wedged task. Expiry ALSO bumps `captureGeneration`:
    /// this turn is declared dead the moment the user is told it failed, so
    /// the wedged task's late completion (success OR failure) must fall to
    /// the uploader's supersede gates instead of resurrecting a transcript
    /// the user has already re-recorded. Disarmed centrally in `state.didSet`
    /// on any transition away from `.uploading`.
    private func armUploadingWatchdog() {
        uploadingWatchdogTask?.cancel()
        uploadingWatchdogTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(WatchAudioUploader.sttResourceTimeout + 30))
            guard let self, !Task.isCancelled else { return }
            guard self.state == .uploading else { return }
            WatchLog.error(.stt, "stt.bg.watchdog", ["turn": self.turnTag])
            self.captureGeneration += 1
            // xcstrings (existing key — same copy the delegate surfaces)
            self.handleBackgroundFailure(
                String(localized: "Recording could not be sent. Please try again."),
                conversationID: nil
            )
        }
    }

    // MARK: - Agent Hop

    /// Resolve-or-create the active conversation, append the user turn, build
    /// the client-owned history, and start the ALWAYS-background converse hop.
    /// Transitions to `.waiting(startedAt:)` (the "thinking…" state).
    ///
    /// Idempotent failure: if the gateway isn't configured, surface an error
    /// (the user re-taps). The user turn lands in the store BEFORE the upload so
    /// the store is authoritative even if the reply never arrives.
    ///
    /// `consumeAskHint` (default true — every live call site keeps today's
    /// behavior): false ONLY for the deferred-relay drain path, whose turn
    /// predates any pending in-app Ask hint — consuming (or clearing) the
    /// one-shot hint there would steal the gateway binding from the LIVE Ask
    /// it belongs to.
    func startConverseHop(transcript: String, consumeAskHint: Bool = true) async {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            // Empty transcript — nothing to ask, and (per guardrail 1/2) NOTHING
            // was minted, so there is no orphan conversation to clean up. Just
            // reset to idle. Drop any pending in-app Ask hint (the headless entry
            // also clears it as a backstop); deferred turns
            // (`consumeAskHint == false`) leave a live Ask's hint alone.
            if consumeAskHint {
                WatchSettingsReader.shared.clearPendingInAppNewConversationBackend()
            }
            pendingConversationID = nil
            mintedConversationID = nil
            pendingTypedSend = false
            captureSource = nil
            inFlightTurnID = nil
            state = .idle
            recordingTime = 0
            WatchRecordingCoordinator.shared.isRecordingFlowActive = false
            captureDiscardCount += 1
            // Idle edge — deferred relay entries may be waiting on exactly
            // this transition. Fire-and-forget; `drain()` self-gates on
            // `canAcceptDeferredDispatch` + guards re-entry.
            Task { @MainActor in
                await AppleRelayPendingQueue.shared.drain()
            }
            return
        }

        do {
            // Resolve the conversation FIRST so we can route to
            // ITS bound REF: an existing conversation's persisted `.backend` ref
            // wins; a Watch-minted new conversation binds to the default ref. THEN
            // resolve that ref's gateway config (per-ref url/token/cert/model).
            // Decision B — an unconfigured / deleted bound ref surfaces the
            // not-configured error; NEVER silently reroute to the default.
            let (conversationID, ref, stampsQuickPointer) = try await resolveActiveConversationAndBackend(consumeAskHint: consumeAskHint)

            guard let config = WatchSettingsReader.shared.remoteAgentConfig(for: ref) else {
                WatchLog.error(.converse, "gateway.notConfigured", ["turn": turnTag])
                // xcstrings
                state = .error(message: String(localized: "Set up your personal AI on iPhone first."))
                return
            }
            let url = config.url
            let token = config.token
            let authScheme = config.authScheme
            let model = config.model

            // Modality stamp: typed composer turn → `watch-text`; recorded turn
            // → `watch-voice`. Mirrors iOS `iphone-text`/`iphone-voice` (the chip
            // glyph reader splits on `-`). Bound recordings are still voice, so
            // we key on `pendingTypedSend`, not on `pendingConversationID`.
            let sourceDeviceTag = pendingTypedSend ? "watch-text" : "watch-voice"

            // Append the user turn to the store (source of truth before upload).
            let userRecord = try await store.appendMessage(
                role: "user",
                text: trimmed,
                conversationID: conversationID,
                sourceDevice: sourceDeviceTag
            )

            // Anti-orphan: stamp the active-conversation pointer NOW —
            // right after the user-turn append, BEFORE the converse hop — for
            // EXISTING conversations too (a freshly-created one is already
            // stamped in `resolveActiveConversation`). Mirrors iOS `ConverseIntent`:
            // a process kill mid-converse must leave the user turn discoverable
            // via the pointer so the next capture continues the same thread
            // rather than orphaning it. GATED on the resolver's verdict: a
            // pinned (explicit) composer turn must not retarget the quick
            // lane — the pointer is implicit-captures-only.
            if stampsQuickPointer {
                WatchSettingsReader.shared.recordActiveConversation(conversationID)
            }

            // Build the client-owned prior-turn history (exclude the
            // just-appended user turn — the request assembler re-adds it) via
            // the shared assembler, which also resolves prior-turn image bytes
            // (the Watch was image-blind before). The parsed ref is ignored on
            // watchOS (the keep-images-inline flag is App-Group-only on iOS)
            // but passed anyway — zero call-site churn if the flag ever
            // broadcasts.
            let priorTurns = try await ConversationHistoryAssembler.assemble(
                conversationID: conversationID,
                excludingUserMessageID: userRecord.id,
                excludingNewUserText: trimmed,
                boundRef: RemoteAgentRef(rawString: ref)
            )

            // Persist in-flight markers for wrist-drop restoration.
            let startedAt = Date()
            persistInFlight(conversationID: conversationID, startedAt: startedAt)
            WatchLog.note(.converse, "converse.send", ["turn": turnTag, "priorTurns": priorTurns.count])
            state = .waiting(startedAt: startedAt)

            // Start the background converse upload. The stamping verdict rides
            // along so the reply-time pointer refresh obeys the same
            // implicit-only rule as the pre-hop stamp above.
            try WatchAudioUploader.shared.uploadConverse(
                ref: ref,
                url: url,
                token: token,
                authScheme: authScheme,
                model: model,
                priorTurns: priorTurns,
                newUserText: trimmed,
                conversationID: conversationID,
                stampsActiveConversation: stampsQuickPointer
            )
        } catch {
            // Log the cause BEFORE `clearInFlight()` wipes the turn tag.
            WatchLog.error(.converse, "converse.start.failed", ["turn": turnTag, "code": (error as? AppError)?.errorCode ?? -1])
            clearInFlight()
            let message = (error as? AppError)?.errorDescription
                ?? String(localized: "Couldn't reach your personal AI. Try again.")  // xcstrings
            state = .error(message: message)
        }
    }

    /// Deferred-relay drain entry (`AppleRelayPendingQueue.drain`): run the
    /// converse hop for a transcript whose audio was captured EARLIER (iPhone
    /// unreachable at record time). Without this dispatch the drained ask never
    /// reached the agent — the transcript notification implied success for a
    /// turn that silently died in the queue. Re-pins the original thread when
    /// the capture was bound (in-thread composer voice) so the deferred ask
    /// lands in the SAME conversation; nil (headless capture, or a pre-binding
    /// queue blob) falls through the resolver's pointer/new-default path WITH
    /// the in-app Ask hint excluded (`consumeAskHint: false`) — the one-shot
    /// hint belongs to a LIVE Ask, never to a turn captured earlier. Always
    /// voice modality. CALLER CONTRACT: dispatch only when
    /// `canAcceptDeferredDispatch` (the drain/reconcile gate) — this writes
    /// the shared pin + drives the live state machine, and it OCCUPIES the
    /// machine synchronously on entry (see below).
    func startDeferredConverseHop(transcript: String, boundTo conversationID: UUID?) async {
        // Occupy the state machine SYNCHRONOUSLY, before the first await:
        // `startConverseHop` only reaches its own `state = .waiting`
        // assignment after several awaits (conversation fetch, user-turn
        // append, history assembly — slow on long threads). If the machine
        // stayed `.idle` across that window, a concurrently scheduled drain
        // Task / late-reply reconcile / user capture would pass the
        // `canAcceptDeferredDispatch` (or `state == .idle`) gate and dispatch
        // a SECOND concurrent hop — state clobber + `persistInFlight`
        // clobber. Entering `.waiting` early is safe: every terminal inside
        // `startConverseHop` assigns state explicitly (the empty-transcript
        // guard resets to `.idle`, errors set `.error`, the happy path
        // re-assigns `.waiting` with its own `startedAt`), so the machine
        // can never wedge in this provisional state.
        state = .waiting(startedAt: Date())
        // No auto-speak source for a deferred drain: the Apple-relay deferred
        // reply is temporally detached from the wrist-raise that captured it —
        // speaking it unprompted minutes later would be a jump-scare, so
        // deferred replies must stay silent (nil source fails the verdict).
        captureSource = nil
        pendingConversationID = conversationID
        // Deferred drains are EXPLICIT for pointer purposes (they replay an
        // old turn; they must not retarget where the next headless capture
        // lands) — matches the pre-merge behavior of the bound path.
        pendingPinStampsQuickPointer = false
        pendingTypedSend = false
        await startConverseHop(transcript: transcript, consumeAskHint: false)
    }

    /// Resolve the active conversation pointer AND its bound
    /// REF together: an EXISTING conversation routes to its persisted `.backend`
    /// ref STRING verbatim ("openclaw" / "hermes" / "custom_<uuid>"); a
    /// Watch-MINTED new conversation binds to the default ref
    /// (`WatchSettingsReader.shared.defaultBackendRef`).
    ///
    /// CORRECTNESS FIX (Decision B — no silent reroute): an existing
    /// conversation's persisted ref is passed through UNCHANGED — it is NOT
    /// coerced to the default. An unknown / deleted bound ref then resolves nil
    /// in the downstream `remoteAgentConfig(for:)` gate and surfaces the
    /// not-configured error, rather than silently rerouting the turn to a
    /// different gateway. (The old enum-coercion path forced `?? defaultBackend`,
    /// which violated the invariant; this returns the raw ref so the gate honors it.)
    ///
    /// `stampsQuickPointer` is the stamping verdict for the per-device
    /// active-conversation pointer: only IMPLICIT (headless / Ask / minted)
    /// turns may write the quick lane; the pinned in-thread composer is
    /// EXPLICIT and returns `false`, gating both the anti-orphan pre-hop
    /// stamp in `startConverseHop` and the uploader's reply-time stamp.
    private func resolveActiveConversationAndBackend(consumeAskHint: Bool) async throws -> (id: UUID, ref: String, stampsQuickPointer: Bool) {
        // Composer-bound path: the in-thread composer pinned a specific
        // conversation. Look it up + route to its persisted ref VERBATIM.
        // CRITICAL: do NOT consume the in-app-Ask hint here — the always-new
        // flow's hint must survive a parallel bound send untouched.
        if let boundID = pendingConversationID {
            if let record = try await store.fetchConversation(id: boundID) {
                // Verdict rides the pin: an EXPLICIT composer / deferred-drain
                // pin must NOT touch the quick lane (the pointer is
                // implicit-captures-only, so composing in an old thread can't
                // hijack where the next headless capture lands), while an
                // IMPLICIT pin (`startCapture(boundTo: .existing)` — the
                // headless trigger continuing the quick lane) keeps stamping
                // so the pointer TTL extends. Each pin site sets the flag.
                return (boundID, record.backend, pendingPinStampsQuickPointer)
            }
            // Bound conversation vanished (deleted on another device between
            // the composer mount and the send). Surface as not-found rather
            // than silently rerouting into a new thread.
            throw ConversationStore.StoreError.conversationNotFound
        }

        // In-app "Ask" path: a one-shot hint forces ALWAYS-NEW + an explicit
        // gateway binding (chosen / only / default), as a ref STRING. Consume it
        // FIRST so it short-circuits the headless session-continuation policy
        // below. Headless triggers never set the hint, so their behavior is
        // byte-for-byte unchanged (they fall through to the policy/pointer logic).
        // Deferred-drain turns skip this branch entirely (`consumeAskHint ==
        // false`): the hint belongs to a LIVE Ask, never to an earlier capture.
        if consumeAskHint, let ref = WatchSettingsReader.shared.consumePendingInAppNewConversationBackend() {
            let record = try await store.createConversation(backend: ref)
            WatchSettingsReader.shared.recordActiveConversation(record.id)
            // LAZY-MINT ADOPTION: a `.new` draft shell pushed onto the nav stack
            // started with a nil conversationID — publish the real id NOW so the
            // open thread binds its overlay / busy banner / reply refresh to it.
            mintedConversationID = record.id
            return (record.id, ref, true)
        }
        if let pointerID = WatchSettingsReader.shared.resolveActiveConversationID() {
            // Confirm it still exists locally (could have been deleted on
            // another device) AND read its bound ref VERBATIM. Targeted fetch
            // by id — never load the whole roster to find one (mirrors the
            // sibling `resolveHeadlessCaptureTarget`).
            if let record = try await store.fetchConversation(id: pointerID) {
                // Default-gateway re-check: a TTL-fresh pointer continues only
                // a thread bound to the CURRENT default gateway — the default
                // may have been re-pointed since the stamp, and an implicit
                // capture must follow the default, never a stale binding. A
                // mismatch falls through to mint a fresh default-bound
                // conversation below.
                if record.backend == WatchSettingsReader.shared.defaultBackendRef {
                    return (pointerID, record.backend, true)
                }
            }
        }
        // Mint a new conversation bound to the default ref.
        let defaultRef = WatchSettingsReader.shared.defaultBackendRef
        let record = try await store.createConversation(backend: defaultRef)
        WatchSettingsReader.shared.recordActiveConversation(record.id)
        mintedConversationID = record.id
        return (record.id, defaultRef, true)
    }

    /// Called by the background converse delegate when the reply lands and the
    /// app is still (or again) frontmost. The reply is ALREADY appended to the
    /// store by the converse delegate, so the open thread surfaces it as a
    /// bubble via `.conversationsDidChange` → `refreshThread` with
    /// scroll-to-bottom — there is no transient reply card any more. This method
    /// just clears the in-flight markers + resets the live machine to idle (so a
    /// pinned-thread overlay / busy banner drops). Guards on conversation match
    /// so a stale reply for a different thread doesn't reset a newer turn.
    func handleBackgroundReply(_ reply: String, conversationID: UUID, messageID: UUID) {
        // AUTO-SPEAK VERDICT — computed FIRST, before ANY branch below reaches
        // `clearInFlight` (which wipes both `captureSource` and the in-flight
        // pin the verdict matches against). Pure decision (unit-tested in
        // `WatchAutoSpeakVerdictTests`); a true verdict only ARMS the one-shot
        // coordinator — the thread view performs the actual speak through its
        // own `ThreadSpeaker`, so the bubble shows the playing state + pause
        // control and audio ownership stays single.
        // Stage the one-shot speak whenever the reply is ELIGIBLE (a voice turn,
        // toggle on, matching the in-flight conversation) — regardless of whether
        // the app is `.active` RIGHT NOW. The "safe to play now" gate lives at the
        // play site (`attemptAutoSpeak`), which re-fires on the wrist-raise, so a
        // reply that lands wrist-down still speaks when the user raises their
        // wrist to look (within the mailbox freshness window). A wrist-down reply
        // ALSO posts a notification whose tap speaks — same mailbox.
        let speaks = WatchAutoSpeakVerdict.shouldAutoSpeak(
            source: captureSource,
            replyConversationID: conversationID,
            inFlightConversationID: inFlightConversationID,
            toggleOn: WatchSettingsReader.shared.readRepliesAloud()
        )
        if speaks {
            // Carry the EXACT reply (id + text) the converse delegate just
            // appended — the open thread speaks THIS reply, not the latest
            // agent bubble re-derived from a not-yet-refreshed array.
            AutoSpeakMailbox.shared.request(conversationID, messageID: messageID, text: reply)
        }
        // Only act on the live machine if we're waiting on THIS conversation
        // (or idle after a wrist-drop where the view was torn down).
        if case .waiting = state {
            // proceed
        } else if case .uploading = state {
            // background-STT chained → converse; also accept
        } else {
            // Not actively showing this turn — the store + thread refresh carry it.
            clearInFlight(forConversation: conversationID)
            // The machine may already be idle here (wrist-drop teardown) —
            // give queued deferred relays the same chance to dispatch as the
            // main path below. `drain()` self-gates, so a busy state no-ops.
            Task { @MainActor in
                await AppleRelayPendingQueue.shared.drain()
            }
            return
        }
        clearInFlight(forConversation: conversationID)
        state = .idle
        recordingTime = 0
        // Idle edge after an agent reply — the canonical moment to dispatch a
        // deferred relay entry (the live turn that blocked it just finished).
        Task { @MainActor in
            await AppleRelayPendingQueue.shared.drain()
        }
    }

    /// Failure counterpart of `handleBackgroundReply` — called by the
    /// background delegates (via `WatchAudioUploader.surfaceTurnFailure`) when
    /// a turn FAILS (transport / HTTP / decode). Load-bearing while the app is
    /// live: foreground notification banners are suppressed
    /// (`WatchNotificationDelegate.willPresent`), so without this transition
    /// the `.waiting`/`.uploading` spinner persists with ZERO feedback until
    /// pop-to-root or relaunch (the 600 s stale-guard only runs on
    /// restore-from-idle). Same state guard as the success path: only
    /// transition when the live machine is actually showing a turn — AND the
    /// failure is for THAT turn: a resurrected OLD task's failure
    /// (conversation B) must not overwrite the machine while it waits on a
    /// NEWER turn (conversation A), or B's error masquerades as A's and A's
    /// later success can't restore the machine. `conversationID` nil = an
    /// unmatchable turn (STT task / failed metadata decode) — those can't be
    /// pin-checked, so they keep the takeover (and clear the in-flight marker
    /// unconditionally).
    func handleBackgroundFailure(_ message: String, conversationID: UUID?) {
        if case .waiting = state {
            // proceed
        } else if case .uploading = state {
            // STT stage, or background-STT chained → converse; also accept
        } else {
            // Not actively showing this turn — the notification carries it.
            if let conversationID { clearInFlight(forConversation: conversationID) }
            return
        }
        // Conversation-match the TAKEOVER, not just the marker clear. A nil
        // live pin (headless turn) can't disambiguate → takeover stands.
        if let conversationID, let pinned = pendingConversationID, pinned != conversationID {
            // A different turn's failure — keep the live wait on screen; the
            // notification carries it. (The conversation-matched clear is a
            // no-op here unless the persisted marker really is that turn's.)
            clearInFlight(forConversation: conversationID)
            return
        }
        if let conversationID {
            clearInFlight(forConversation: conversationID)
        } else {
            clearInFlight()
        }
        state = .error(message: message)
    }

    /// Restore the in-flight or completed state when the view reappears mid-wait
    /// (wrist re-raised). If the reply already landed in the store, show it;
    /// otherwise restore the thinking view from the persisted `startedAt`.
    func restoreInFlightStateIfNeeded() {
        // Only restore from idle — don't stomp an active recording / live wait.
        guard state == .idle else { return }
        guard let (conversationID, startedAt) = loadInFlight() else { return }

        // Re-attach the turn correlation id from the App-Group mirror so a
        // restored wait keeps the same greppable id as its capture/STT logs.
        if inFlightTurnID == nil, let raw = appGroupDefaults.string(forKey: Self.inFlightTurnKey) {
            inFlightTurnID = UUID(uuidString: raw)
        }

        Task {
            // If the agent reply already landed (last message is an agent turn
            // newer than startedAt), the thread already shows it as a bubble —
            // just clear in-flight + stay idle. Otherwise restore the thinking
            // state so the busy banner reappears above the composer.
            if let records = try? await store.fetchMessages(for: conversationID),
               let last = records.last,
               last.role == "agent",
               last.createdAt >= startedAt {
                clearInFlight()
                state = .idle
                recordingTime = 0
            } else {
                // Reply not in yet — restore the thinking state.
                state = .waiting(startedAt: startedAt)
            }
        }
    }

    // MARK: - In-flight persistence (wrist-drop restoration)

    private static let inFlightConversationKey = "watch.inFlight.conversationID"
    private static let inFlightStartedAtKey = "watch.inFlight.startedAt"
    private static let inFlightTurnKey = "watch.inFlight.turnID"
    private var appGroupDefaults: UserDefaults {
        UserDefaults(suiteName: Constants.appGroupID) ?? .standard
    }

    private func persistInFlight(conversationID: UUID, startedAt: Date) {
        appGroupDefaults.set(conversationID.uuidString, forKey: Self.inFlightConversationKey)
        appGroupDefaults.set(startedAt.timeIntervalSinceReferenceDate, forKey: Self.inFlightStartedAtKey)
        // Mirror the turn correlation id so a wrist-drop restoration re-attaches
        // the SAME id its capture/STT logs used (in-memory id is lost on relaunch).
        // Clear it when this turn has none (e.g. a deferred-relay drain), so a
        // PRIOR turn's persisted id can never be restored against this one.
        if let turn = inFlightTurnID {
            appGroupDefaults.set(turn.uuidString, forKey: Self.inFlightTurnKey)
        } else {
            appGroupDefaults.removeObject(forKey: Self.inFlightTurnKey)
        }
    }

    private func loadInFlight() -> (UUID, Date)? {
        guard let raw = appGroupDefaults.string(forKey: Self.inFlightConversationKey),
              let id = UUID(uuidString: raw) else { return nil }
        let stamp = appGroupDefaults.double(forKey: Self.inFlightStartedAtKey)
        guard stamp > 0 else { return nil }
        let startedAt = Date(timeIntervalSinceReferenceDate: stamp)
        // Stale guard: an in-flight marker older than the resource timeout is
        // dead (the turn was dropped). Clear + ignore so we never restore a
        // permanently-stuck thinking view.
        guard Date().timeIntervalSince(startedAt) < Constants.remoteAgentConverseResourceTimeout else {
            clearInFlight()
            return nil
        }
        return (id, startedAt)
    }

    private func clearInFlight() {
        appGroupDefaults.removeObject(forKey: Self.inFlightConversationKey)
        appGroupDefaults.removeObject(forKey: Self.inFlightStartedAtKey)
        appGroupDefaults.removeObject(forKey: Self.inFlightTurnKey)
        inFlightTurnID = nil
        // Reset-to-idle: also drop any unconsumed in-app Ask hint so a failed
        // converse hop can't leave it for a later headless trigger.
        WatchSettingsReader.shared.clearPendingInAppNewConversationBackend()
        // Drop the composer-bound pin on the same reset boundary — symmetric
        // with the headless-hint clear, so a failed bound send can't re-route a
        // later capture.
        pendingConversationID = nil
        mintedConversationID = nil
        pendingTypedSend = false
        captureSource = nil
    }

    /// Clear only when the persisted marker matches `conversationID` — avoids a
    /// late reply for an old turn wiping a freshly-started one.
    private func clearInFlight(forConversation conversationID: UUID) {
        if let raw = appGroupDefaults.string(forKey: Self.inFlightConversationKey),
           raw == conversationID.uuidString {
            clearInFlight()
        }
    }

    /// Retry from error state
    func retry() {
        guard case .error = state else { return }
        if recordingFileURL != nil {
            // Retry the same captured audio — the converse hop will re-consume
            // any pending in-app Ask hint, so the retry binds to the chosen
            // gateway. Leave the hint in place.
            processRecording()
        } else {
            // No audio to retry (converse-stage failure / relay hand-off) —
            // this is a dismiss, not a retry; the error views label it so
            // (`canRetry`).
            dismissError()
        }
    }

    /// Reset from `.error(...)` back to `.idle` WITHOUT retrying — mirrors iOS
    /// `InAppAudioRecorder.dismissError()`. Drops any preserved capture, the
    /// unconsumed in-app Ask hint AND the bound-thread pin (an abandoned turn
    /// must never re-route a later capture), so a fresh send/record starts clean.
    func dismissError() {
        guard case .error = state else { return }
        cleanupRecordingFile()
        compressedAudioData = nil
        compressedAudioFormat = nil
        WatchSettingsReader.shared.clearPendingInAppNewConversationBackend()
        pendingConversationID = nil
        mintedConversationID = nil
        pendingTypedSend = false
        captureSource = nil
        state = .idle
        recordingTime = 0
        // Idle edge — entries that queued up while the error toast blocked
        // the machine (the old drain gated on `.idle` and deadlocked behind
        // the relay-timeout toast until this very tap — defect 4) get their
        // dispatch chance now. `drain()` self-gates + guards re-entry.
        Task { @MainActor in
            await AppleRelayPendingQueue.shared.drain()
        }
    }

    /// Reset the relay-deferral toast (`.error` + `lastErrorIsRelayDeferral`)
    /// back to `.idle`. Called by `AppleRelayPendingQueue` when a deferred
    /// reply lands — the toast's promise ("your transcript will arrive when
    /// it reconnects") was just kept, so it must not linger. Provenance-
    /// gated: any OTHER `.error` is left untouched, so a background reply can
    /// never stomp an unrelated error the user is reading. Reuses
    /// `dismissError()` wholesale — same reset semantics, including the
    /// hint/pin clears (the deferred hop about to be dispatched re-pins via
    /// `startDeferredConverseHop(boundTo:)` anyway).
    func clearRelayDeferralError() {
        guard case .error = state, lastErrorIsRelayDeferral else { return }
        dismissError()
    }

    // MARK: - Timer

    private func startTimer() {
        recordingTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.state == .recording else { return }
                self.recordingTime += 0.1
            }
        }
        RunLoop.current.add(recordingTimer!, forMode: .common)
    }

    private func stopTimer() {
        recordingTimer?.invalidate()
        recordingTimer = nil
    }

    /// Schedule the soft-warning and hard-auto-stop timers for the current
    /// recording. Soft warning fires `warningOffset` seconds before the cap;
    /// hard stop calls `stopRecording()` at the cap (which advances the state
    /// machine and uploads — without this, the recorder silently goes idle
    /// at the cap and the UI keeps incrementing the elapsed time).
    private func scheduleDurationGuards() {
        let warningInterval = Constants.maxAudioDuration - Constants.maxAudioDurationWarningOffset
        if warningInterval > 0 {
            let warning = Timer.scheduledTimer(withTimeInterval: warningInterval, repeats: false) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.state == .recording else { return }
                    self.nearMaxDuration = true
                    WKInterfaceDevice.current().play(.notification)
                }
            }
            RunLoop.current.add(warning, forMode: .common)
            warningTimer = warning
        }

        let stop = Timer.scheduledTimer(withTimeInterval: Constants.maxAudioDuration, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.state == .recording else { return }
                self.stopRecording()
            }
        }
        RunLoop.current.add(stop, forMode: .common)
        maxDurationStopTimer = stop
    }

    private func cancelDurationGuards() {
        warningTimer?.invalidate()
        warningTimer = nil
        maxDurationStopTimer?.invalidate()
        maxDurationStopTimer = nil
    }

    // MARK: - Audio Session Interruption

    private func observeInterruptions() {
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor in
                self?.handleInterruption(notification)
            }
        }
    }

    private func handleInterruption(_ notification: Notification) {
        guard state == .recording,
              let info = notification.userInfo,
              let typeValue = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }

        if type == .ended {
            // Resume rides the coordinator's FIFO config lane exactly like
            // the arm: the reactivation IPC can stall like the initial
            // activate (never block MainActor), and it must never land on a
            // session a newer turn owns — `runConfig` re-checks the claim at
            // issue time and skips a superseded tenure's op. setActive(true)
            // ONLY: the category is still `.record` from the arm, so
            // re-issuing setCategory here would just be a second stomp
            // vector for zero gain. Generation snapshot across the hop: a
            // stop/cancel landing mid-IPC must not resurrect a dead recorder
            // into a machine that already moved on.
            guard let claim = sessionClaim else {
                WatchLog.note(.capture, "capture.interrupt.stale", ["turn": turnTag])
                return
            }
            let generation = captureGeneration
            Task {
                do {
                    let configured = try await sessionCoordinator.runConfig(for: claim) {
                        try AVAudioSession.sharedInstance().setActive(true)
                    }
                    // Skipped op (superseded claim) or a machine that moved
                    // on mid-IPC — either way the turn is dead.
                    guard configured, state == .recording, generation == captureGeneration else {
                        WatchLog.note(.capture, "capture.interrupt.stale", ["turn": turnTag])
                        return
                    }
                    let resumed = audioRecorder?.record() ?? false
                    WatchLog.note(.capture, "capture.interrupt.resumed", ["turn": turnTag, "ok": resumed])
                } catch {
                    WatchLog.error(.capture, "capture.interrupt.reactivateFailed", ["turn": turnTag, "code": (error as NSError).code])
                }
            }
        }
    }

    private func removeInterruptionObserver() {
        if let observer = interruptionObserver {
            NotificationCenter.default.removeObserver(observer)
            interruptionObserver = nil
        }
    }

    // MARK: - Cleanup

    private func cleanupRecordingFile() {
        if let url = recordingFileURL {
            try? FileManager.default.removeItem(at: url)
            recordingFileURL = nil
        }
    }
}
