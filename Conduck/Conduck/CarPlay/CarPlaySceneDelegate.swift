// SPDX-License-Identifier: Apache-2.0

// Conduck
// CarPlaySceneDelegate.swift
//
// CarPlay conversation picker + multi-turn voice session. The PERMANENT
// root is a CONVERSATION PICKER (`CPListTemplate`): row 0 "New voice chat" + a
// "Recent" section of conversations to continue (label + relative date ONLY —
// never message text, the driver-safety / entitlement rule). Tapping any
// row is an IMMEDIATE voice action: set the active-conversation pointer (New
// mints one), PRESENT the voice template MODALLY, and START the multi-turn
// session. On session end the voice modal is DISMISSED — the persistent picker
// root is already there, so the app never falls to the CarPlay dashboard. The
// list refreshes on `.conversationsDidChange` and is disabled while a session
// is active. No-gateway state = the "Set up your AI on iPhone first." row.
//
// The desk is a DESTINATION the driver picks from one place: the nav-bar
// switcher (shown whenever a gateway is configured, one included) opens a
// chooser of every gateway with "Add to Work" as its last row — a ONE-SHOT
// spoken note that lands on the driver's own desk and reaches no gateway.
// There it is an ACTION — it starts the note and is over — while every row
// above it is a drive-long gateway pick. Work is never a mode: no state
// outlives the tap, so the next "New voice chat" still goes to the gateway.
// Only the no-gateway state, which has no switcher, draws that row on the root
// itself — day one's only working row. Work CARDS are never listed here:
// content on a car screen is what the voice-based-conversation entitlement
// forbids, and the row only records.
//
// NAV MODEL: the list picker is the permanent root (set ONCE in `didConnect`,
// never removed); the `CPVoiceControlTemplate` is a modal-only template (SDK
// `presentTemplate` supports exactly {action-sheet, alert, voice-control}; it is
// NOT pushable and is non-idiomatic as a persistent root). A voice-as-root
// template is the root cause of "End exits to the dashboard" (gotcha g3); here
// we PRESENT/DISMISS the voice template modally over the picker root instead.
//
// What is KEPT verbatim (all load-bearing):
// - `applyState(_:service:animated:)` chokepoint (g1)
// - `startSession` with `service.beginSession()` INSIDE the `presentTemplate`
//   completion — g1, race against `AVAudioSession.setActive` → engine '!obj'
// - `ensureVoicePresented` / `ensureVoiceDismissed` modal discipline (audio
//   deactivated in the dismiss completion — after the modal is gone)
// - `observe(service:)` one-shot re-arm loop for `@Observable` tracking (g1)
// - `speakPermissionInstruction` driver-safe spoken UX

#if os(iOS)
import Foundation
import CarPlay
import UIKit
import AVFoundation
import Observation
import os.log

class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate, CPInterfaceControllerDelegate {
    // MARK: - Scene state

    private var interfaceController: CPInterfaceController?
    private var recordingService: CarPlayRecordingService?
    private var listTemplate: CPListTemplate?

    /// Tracks whether the voice template is currently presented MODALLY over
    /// the permanent list root. The list root is set once in `didConnect` and
    /// never removed, so this is the only navigation state we track. Reset on
    /// background/disconnect (the system may tear the modal down).
    ///
    /// Every write bumps `presentationGeneration` — that is what makes a
    /// present completion able to tell ITS presentation from the one that
    /// replaced it. Deliberately a `didSet` on the flag rather than a bump at
    /// each call site: the flag is written from eight places (connect, resign,
    /// become-active reconciliation, disconnect, `templateDidDisappear`, both
    /// halves of `ensureVoicePresented`, `ensureVoiceDismissed`) and a ninth
    /// added later would silently opt out of the identity check.
    private var isVoicePresented = false {
        didSet { presentationGeneration &+= 1 }
    }

    /// The identity of the CURRENT presentation transition.
    ///
    /// Connection identity is not presentation identity, and neither is enough:
    /// a presentation can be started, cancelled by a backgrounding, and
    /// replaced by a second one on the SAME controller while the first
    /// `presentTemplate` callback is still outstanding. That callback used to
    /// pass the controller check and then clear `isVoicePresented` — leaving a
    /// live modal behind a flag reading "nothing presented", which lets a later
    /// state change present a second time and makes `ensureVoiceDismissed`
    /// return without dismissing at End.
    private var presentationGeneration: UInt64 = 0

    /// One-shot picker hint: the last session ended because the microphone
    /// could not be started (activation failure / engine-start exhaustion).
    /// Those ends are SILENT by doctrine, so this row is their only feedback.
    /// Set via the service's `onCaptureStartFailed`; cleared on the next
    /// session start and on disconnect. Not observable state — the `.idle`
    /// transition's own `refreshPicker` renders it.
    private var oneShotStartFailureHint = false

    /// Re-armed after every observation fire (`@Observable` tracking is one-shot).
    private var observationGeneration = 0

    /// Observer token for `.conversationsDidChange` so the picker refreshes when
    /// a turn lands (this device or — when sync is on — another device).
    private var conversationsObserver: NSObjectProtocol?

    /// SESSION-LOCAL (this-drive-only) gateway override. CarPlay must NOT write
    /// the device-local global default (that silently re-points iPhone/iPad/Mac
    /// and clears their active-conversation pointers). Picking a gateway in the
    /// CarPlay chooser sets THIS, scoped to the live CarPlay connection and
    /// cleared on `didDisconnect`/`teardown` — it never persists, never touches
    /// the global default, and never touches any active-conversation pointer.
    /// The effective CarPlay ref is `sessionDefaultRefOverride ??
    /// (await SettingsManager.shared.defaultRemoteAgentRef())` and is used for
    /// the switcher button title + NEW-conversation minting; existing-conversation
    /// routing (reads `Conversation.backend`) is unaffected.
    private var sessionDefaultRefOverride: RemoteAgentRef?

    /// Monotonic id for the current start claim. Serials are never reused, so a
    /// claim left over from a previous connection can neither begin a session
    /// nor release the claim the new connection is holding.
    private var startClaimSerial: UInt64 = 0

    /// The ONE session start allowed to be in flight, from the row tap until the
    /// service's `begin…` has run or the start was refused.
    ///
    /// `startSession` suspends on the gateway pre-flight between its own idle
    /// test and `beginSession`; without a synchronous claim a tap on "Add to
    /// Work" during that suspension passes the same test, presents the modal,
    /// and the resumed chat start then wins `beginSession` underneath it — a
    /// private note becomes an AI chat, which is the boundary this whole lane
    /// exists to hold.
    private var pendingStart: (serial: UInt64, destination: CarPlayCaptureDestination)?

    /// The destination of the most recent start attempt. Read only by the
    /// one-shot mic-couldn't-start hint, so a failed Work start is told to tap
    /// the row it actually tapped rather than routing the repeated private
    /// thought to an AI.
    private var lastStartDestination: CarPlayCaptureDestination = .chat

    nonisolated private static let log = Logger(subsystem: Constants.identityNamespace, category: "CarPlayScene")

    // MARK: - CPTemplateApplicationSceneDelegate

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController
    ) {
        Self.log.info("didConnect")
        // A hard drop (cable yank, host kill, Simulator collapse) can skip
        // `didDisconnect` entirely; the previous connection's service would
        // then still be referenced here with its session-lifecycle observers
        // live — handlers on the SHARED `AVAudioSession` acting behind the new
        // session's back, and a possibly-running capture engine holding the
        // HFP input (the persistent-'nope' wedge). Tear it down first.
        // The SAME teardown the two disconnect callbacks run, not an ad-hoc
        // subset of it: a hard drop that skipped both of them would otherwise
        // leave this connection with the previous one's start claim, refresh
        // latch, session override and observer generation still set.
        if recordingService != nil {
            Self.log.info("didConnect found a stale recordingService — tearing it down first")
            disconnectCleanup()
        }
        self.interfaceController = interfaceController
        interfaceController.delegate = self

        let service = CarPlayRecordingService()
        self.recordingService = service

        // Live presentation query for the service's re-arm self-heal: the only
        // template presented modally over the picker root during a session is
        // the voice template, so `presentedTemplate != nil` ⟺ the voice modal
        // is up. Reading the live `presentedTemplate` (not a mirrored flag)
        // means it can't drift if a dismiss signal is ever dropped.
        service.isVoiceModalPresented = { [weak self] in
            self?.interfaceController?.presentedTemplate != nil
        }

        // Mic-couldn't-start feedback: the service fires this AFTER its silent
        // `endSession`, and this handler owns BOTH halves of that end — the
        // hint flag the refresh renders, and the dismiss-then-refresh itself.
        //
        // The state observer cannot own the second half here. A listen that
        // failed BEFORE `.recording` never left `.idle`, so `endSession`'s
        // closing `state = .idle` is an equal assignment and `@Observable`
        // publishes nothing for it: no observation fires, and the driver is
        // left on a Listening modal over a dead session whose "End" button is
        // already a no-op. Running the `applyState` chokepoint by hand here is
        // that missing transition — same dismiss (whose completion frees the
        // car audio session), same refreshed picker, now carrying the hint.
        service.onCaptureStartFailed = { [weak self, weak service] in
            guard let self, let service else { return }
            self.oneShotStartFailureHint = true
            self.applyState(service.state, service: service)
        }

        // Build the picker once; rebuilt-in-place on refresh + permission states.
        let template = CPListTemplate(
            title: String(localized: "Conduck"),  // xcstrings
            sections: []
        )
        self.listTemplate = template

        // The list picker is the PERMANENT root — set ONCE here, never removed.
        // The voice template is presented MODALLY over it per session (and
        // dismissed on end), so the app can never fall to the CarPlay dashboard.
        interfaceController.setRootTemplate(template, animated: false, completion: nil)
        isVoicePresented = false

        installVoiceTemplateButtons(service: service)
        observe(service: service)
        observeConversations()

        // Cold connect: paint the picker (or the permission state). Tapping a
        // row starts a session — there is no auto-listen on connect anymore
        // (the picker is the entry point, matching ChatGPT/Perplexity).
        applyState(service.state, service: service, animated: false)
        refreshPicker()
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        Self.log.info("sceneDidBecomeActive")
        guard let service = recordingService else { return }
        service.setSceneActive(true)
        service.refreshPermission()
        // Opportunistic top-up: warm the Standard on-device model so the first
        // CarPlay mic tap isn't a cold first-run race (CarPlay has no "Preparing…"
        // UI and can't self-heal). Self-gates on Apple active + authorized;
        // best-effort, never blocks scene activation.
        Task { await AppleSpeechPreparer.prepareStandardIfAuthorized() }
        // Re-paint permission + refresh the recent list (a turn may have landed
        // on the phone while we were backgrounded).
        if !service.sessionActive {
            // Reconcile the modal flag against reality before re-painting. The
            // system's teardown behavior for a backgrounded modal voice template
            // is undocumented, so sync `isVoicePresented` from the live
            // `presentedTemplate`: if a voice modal survived backgrounding, this
            // makes `applyState(.idle)` → `ensureVoiceDismissed` actually dismiss
            // it (instead of no-opping on a stale-false flag) so the driver lands
            // on the picker root, not a stale voice template.
            isVoicePresented = (interfaceController?.presentedTemplate != nil)
            applyState(service.state, service: service)
            refreshPicker()
        }
    }

    func sceneWillResignActive(_ scene: UIScene) {
        // DIAGNOSTIC (CarPlay dashboard-fall): capture the presented template +
        // audio route + service state at the instant of resign. Ordered against
        // the recording service's ROUTE CHANGE / INTERRUPTION / speakReply logs,
        // this pins whether an audio event drove the scene resign (real bug) or
        // the host resigned with no audio trigger (Simulator limitation).
        let session = AVAudioSession.sharedInstance()
        Self.log.info("sceneWillResignActive presented=\(String(describing: type(of: self.interfaceController?.presentedTemplate)), privacy: .public) state=\(String(describing: self.recordingService?.state), privacy: .public) out=[\(session.currentRoute.outputs.map(\.portType.rawValue).joined(separator: ","), privacy: .public)]")
        // Backgrounded (driver → Maps): the service ends any live session
        // silently, CANCELLING the in-flight converse (the turn shows failed +
        // Retry on the phone — see `endSession`). The service deactivates audio
        // directly on this background path (no dismiss completion to rely on).
        // Optimistically clear the flag (the system may tear the modal down
        // while backgrounded); `sceneDidBecomeActive` reconciles it against the
        // live `presentedTemplate` on return, which is the authoritative sync.
        isVoicePresented = false
        // A start still suspended in its pre-flight must not begin over Maps,
        // nor survive `sceneDidBecomeActive`'s reconciliation and present a
        // Listening modal the driver never asked for on their return.
        pendingStart = nil
        recordingService?.setSceneActive(false)
    }

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didDisconnect interfaceController: CPInterfaceController
    ) {
        Self.log.info("didDisconnect")
        disconnectCleanup()
    }

    /// The scene's session was discarded by UIKit. `CPTemplateApplicationSceneDelegate`
    /// refines `UISceneDelegate`, so this is a legitimate override point — and
    /// it fires on abrupt teardown paths that can skip the CarPlay-specific
    /// `didDisconnect` callback. Idempotent with it via `disconnectCleanup()`.
    func sceneDidDisconnect(_ scene: UIScene) {
        Self.log.info("sceneDidDisconnect")
        disconnectCleanup()
    }

    /// Shared, idempotent connection teardown — reachable from `didDisconnect`,
    /// `sceneDidDisconnect`, and (defensively) the top of the next `didConnect`.
    private func disconnectCleanup() {
        observationGeneration &+= 1
        if let conversationsObserver {
            NotificationCenter.default.removeObserver(conversationsObserver)
            self.conversationsObserver = nil
        }
        CarPlaySpeechService.shared.cancel()
        // Mic-mute lives on the per-connection recording service (reset in its
        // `endSession`/`teardown`); the next connection's fresh service starts
        // unmuted, so there's nothing to reset here.
        recordingService?.teardown()
        self.interfaceController = nil
        self.recordingService = nil
        self.listTemplate = nil
        self.isVoicePresented = false
        self.oneShotStartFailureHint = false
        // Per-connection like the flags above. UIKit can reuse this delegate
        // across disconnect/reconnect: a refresh still in flight at disconnect
        // would otherwise have its `defer` clear the flag out from under the
        // reconnect's own refresh, permitting the overlap the latch prevents.
        self.pickerRefreshInFlight = false
        self.pickerRefreshPending = false
        // Session-local override dies with the connection — the next drive
        // starts from the iPhone's device-local default again.
        self.sessionDefaultRefOverride = nil
        // A start suspended in its pre-flight when the cable dropped must not
        // begin, and must not hold the next connection's claim hostage.
        self.pendingStart = nil
        self.lastStartDestination = .chat
    }

    // MARK: - One start at a time

    /// Claim the single in-flight session start, SYNCHRONOUSLY, before the
    /// caller suspends on anything.
    ///
    /// Returns the serial the caller must carry to `startIsLive` /
    /// `releaseStart`, or nil when a start is already claimed or the service
    /// cannot start one. Consuming the one-shot hint here (rather than in each
    /// starter) is deliberate: the driver is acting again, and the row that
    /// disappears is the row whose failure the flag recorded.
    private func claimStart(
        _ destination: CarPlayCaptureDestination,
        service: CarPlayRecordingService
    ) -> UInt64? {
        guard service === recordingService else { return nil }
        var isIdle = false
        if case .idle = service.state { isIdle = true }
        guard CarPlayStartGate.mayClaim(
            isIdle: isIdle,
            sessionActive: service.sessionActive,
            claimHeld: pendingStart != nil
        ) else { return nil }
        startClaimSerial &+= 1
        pendingStart = (startClaimSerial, destination)
        lastStartDestination = destination
        oneShotStartFailureHint = false
        return startClaimSerial
    }

    /// Whether the claim `serial` may still act, asked after EVERY suspension
    /// group that precedes a side effect and again inside the present
    /// completion. The claim is bound to the live connection, so a start left
    /// over from a previous connection — or one suspended across a
    /// backgrounding, a permission flip or the driver's own End — answers false
    /// and mutates nothing.
    private func startIsLive(_ serial: UInt64, service: CarPlayRecordingService) -> Bool {
        var isIdle = false
        if case .idle = service.state { isIdle = true }
        return CarPlayStartGate.isLive(
            claimSerial: pendingStart?.serial,
            serial: serial,
            serviceIsCurrent: service === recordingService,
            controllerAttached: interfaceController != nil,
            sceneActive: service.isSceneActive,
            isIdle: isIdle,
            sessionActive: service.sessionActive
        )
    }

    /// Release the claim — BY SERIAL, so a stale completion from a previous
    /// connection can never clear the claim the new connection is holding. A
    /// picker refresh refused while the claim was held is retained rather than
    /// dropped, and this is where it drains: a start that never began still has
    /// to leave a correctly painted picker behind.
    private func releaseStart(_ serial: UInt64) {
        guard pendingStart?.serial == serial else { return }
        pendingStart = nil
        if pickerRefreshPending, recordingService?.sessionActive != true {
            refreshPicker()
        }
    }

    /// Drop a start that has been CLAIMED but has not begun a session yet.
    ///
    /// The two places the driver cancels such a start reach no session to end:
    /// "End" calls `endFromButton()`, whose `endSession` opens with `guard
    /// sessionActive`, and a modal dismissed before the present completion runs
    /// leaves the same nothing behind. Without this the claim survives both, and
    /// the present completion — which asks only whether the claim is still live
    /// — begins recording under a driver who has just cancelled it.
    ///
    /// Routed through `releaseStart` (by serial) so a picker refresh retained
    /// under the claim still drains, exactly as on every other refusal path.
    private func cancelPendingStart(for service: CarPlayRecordingService) {
        guard service === recordingService, let claim = pendingStart else { return }
        releaseStart(claim.serial)
    }

    /// Run the `.idle` transition for an end the state observer cannot deliver.
    ///
    /// `endSession` reaches this scene through ONE signal — `state = .idle` —
    /// and a session whose listen has not committed the microphone yet is
    /// ALREADY `.idle`: the cold-route settle and the VAD model load both sit
    /// above the commit, and `beginWorkNote`/`beginSession` flip `sessionActive`
    /// without touching `state`. So "End" during that window ends a real session
    /// and closes it with an EQUAL assignment, which `@Observable` publishes
    /// nothing for. Left to it the driver keeps a Listening modal over a session
    /// that has just died — its own "End" now a no-op, since `endSession` guards
    /// on `sessionActive` — the dismiss completion that frees the car radio
    /// never runs, and the abandoned startup supplies no signal either: it
    /// discards its engine and returns.
    ///
    /// The same chokepoint the observer would have used, so this is the missed
    /// transition and not a second, divergent one. Whether the state could
    /// change at all is asked at the CALL SITE, before the end — afterwards the
    /// answer is `.idle` either way.
    private func finishIdleEndTheObserverCannotDeliver(service: CarPlayRecordingService) {
        guard service === recordingService, service.state == .idle else { return }
        applyState(service.state, service: service)
    }

    // MARK: - CPInterfaceControllerDelegate (diagnostic only)

    func templateDidAppear(_ aTemplate: CPTemplate, animated: Bool) {
        Self.log.info("templateDidAppear: \(String(describing: type(of: aTemplate)), privacy: .public)")
    }

    /// AUTHORITATIVE session-teardown trigger (not diagnostic-only): when the
    /// voice modal disappears, the session MUST NOT continue. This catches a
    /// system/user dismiss that bypasses the "End" button handler — the bug
    /// where the picker re-appeared but the listen→speak→re-arm loop kept
    /// running behind it (`sessionActive` never flipped). The voice template
    /// never disappears between turns (inter-turn transitions — including the
    /// mic-`.muted` hold — only `activateVoiceControlState`; `reArmAfterSettle`
    /// goes `.speaking → .recording` directly), so this fires only on a genuine
    /// session end.
    func templateDidDisappear(_ aTemplate: CPTemplate, animated: Bool) {
        Self.log.info("templateDidDisappear: \(String(describing: type(of: aTemplate)), privacy: .public)")
        guard let service = recordingService,
              aTemplate === service.voiceControlTemplate else { return }
        // Set FIRST so a re-entrant `ensureVoiceDismissed` (driven by the
        // `state = .idle` below) no-ops instead of issuing a second dismiss.
        isVoicePresented = false
        // BEFORE the `sessionActive` guard below, which returns on exactly the
        // case this covers: the modal went away while a start was still inside
        // its present completion, so there is no session to end and the claim
        // would otherwise survive to begin a recording behind the picker.
        cancelPendingStart(for: service)
        // Our own dismiss (End button / sign-off) and the background path
        // already flipped `sessionActive` false → nothing left to do.
        guard service.sessionActive else { return }
        Self.log.info("Voice modal dismissed with live session — tearing down")
        // Stop TTS + tear down capture/VAD + flip `sessionActive` false (this
        // blocks any pending re-arm). The modal is already gone, so no dismiss
        // completion will fire — free the car audio session DIRECTLY here
        // (idempotent via `audioActivated`).
        service.endFromButton()
        service.deactivateAudioSession()
    }

    // MARK: - State → modal present/dismiss chokepoint

    private func applyState(
        _ state: CarPlayRecordingService.State,
        service: CarPlayRecordingService,
        animated: Bool = true
    ) {
        Self.log.info("applyState: \(String(describing: state), privacy: .public)")
        switch state {
        case .recording:
            ensureVoicePresented(service: service, voiceState: "listening", animated: animated)
        case .processing:
            ensureVoicePresented(service: service, voiceState: "processing", animated: animated)
        case .speaking:
            ensureVoicePresented(service: service, voiceState: "speaking", animated: animated)
        case .muted:
            // Mic-muted: the session is still live → keep the voice modal up on
            // the "Muted" screen. Do NOT dismiss or refresh the picker (that's
            // the `.idle`/end path); unmuting re-arms straight back to listening.
            ensureVoicePresented(service: service, voiceState: "muted", animated: animated)
        case .idle:
            // Session ended (or never started) → dismiss the voice modal (if
            // up) and land on the refreshed, persistent picker root.
            // NOTE: the Mute/Unmute button re-sync was MOVED to `startSession`
            // (before the next present). Mutating the voice template's
            // `trailingNavigationBarButtons` HERE — right after / during the
            // `ensureVoiceDismissed()` `dismissTemplate` on that same template —
            // is a post-dismiss template mutation, a known CarPlay assertion
            // source. `endSession` already reset `isMicMuted=false`; the next
            // `startSession` repaints the button on the (not-presented) template.
            ensureVoiceDismissed(animated: animated)
            refreshPicker()
        case .error:
            ensureVoiceDismissed(animated: animated)
            refreshPicker()
        case .permissionBlocked(let reason):
            ensureVoiceDismissed(animated: animated)
            refreshPicker()
            speakPermissionInstruction(reason)
        }
        // Buttons are STABLE for the session (End + Mute, installed once in
        // didConnect) — only the voice STATE changes per transition above.
    }

    /// Start a session for `conversationID` (nil = mint a new conversation).
    /// The picked id + the effective CarPlay default ref ride INTO the session
    /// via `beginSession(conversationID:defaultRef:)` — CarPlay session state is
    /// its own in-memory lane and never touches the shared per-device
    /// quick-capture pointer (implicit-only; a drive must not retarget the
    /// Action-Button/menu-bar thread) NOR the global default. The voice template
    /// is presented modally and the session starts INSIDE the `presentTemplate`
    /// completion (g1 audio race).
    ///
    /// PRE-FLIGHT before the modal. Whatever the destination turns out to be, it
    /// is decided BEFORE `ensureVoicePresented` — so a refusal simply never
    /// presents the voice template, and the g1 audio-race contract (beginSession
    /// inside the present completion) is untouched. A driver who cannot be sent
    /// anywhere hears why and is left on the chooser, one tap from the fix, on
    /// the screen already in front of them. The NEW-chat rule itself lives in
    /// `newChatPlan(resolution:configured:override:effectiveRef:)`, a pure static
    /// the test suite can drive without a CarPlay scene; this body only performs
    /// what that plan decided.
    private func startSession(service: CarPlayRecordingService, conversationID: UUID?) {
        // The claim is taken SYNCHRONOUSLY, before the first suspension below:
        // the idle test alone cannot hold the boundary, because "Add to Work"
        // passes it too while this body is parked in the pre-flight. It also
        // consumes the one-shot hint — the driver is acting again.
        guard let serial = claimStart(.chat, service: service) else { return }
        Task { @MainActor in
            // Every early return below — a missing token, a chooser repair, a
            // phone with nothing set up — releases the claim through this.
            var handedToPresent = false
            defer { if !handedToPresent { self.releaseStart(serial) } }
            // Capture the effective CarPlay ref (session-local override ?? the
            // iPhone's device-local default) and stash it on the service so a
            // NEW-conversation mint uses it instead of reading the global default.
            // Existing-conversation routing (reads `Conversation.backend`) ignores
            // this. Captured at session start so a chooser change mid-session can't
            // retarget a live session.
            var defaultRef = await self.effectiveCarPlayRef()
            guard self.startIsLive(serial, service: service) else { return }

            if let conversationID {
                // EXISTING chat: the thread is BOUND to its gateway. Apply the
                // same two conditions the send path applies (a snapshot must
                // resolve, and a `.bearer` scheme must have a non-empty token)
                // and REFUSE on failure — never reroute, never re-point. The
                // driver's exit is a new chat, which the picker already offers.
                let bound = try? await ConversationStore.shared.fetchConversation(id: conversationID)
                // A Work project's thread first: an archived project, or a free
                // library still to choose its active projects, refuses a new
                // turn at the write. Say so HERE — nothing presented, nothing
                // recorded, the claim released by the `defer` — rather than
                // letting the driver speak into a turn the store will reject.
                // The same await → re-validation contract as every other hop in
                // this pre-flight: the very next statement re-checks the claim.
                if let projectID = bound?.projectID {
                    let refusal = await ConversationStore.shared.workProjectActivityRefusal(projectID: projectID)
                    guard self.startIsLive(serial, service: service) else { return }
                    if let refusal {
                        CarPlaySpeechService.shared.speak(CarPlayProjectRefusalCopy.phrase(refusal)) { }
                        return
                    }
                }
                let snapshot = await SettingsManager.shared
                    .remoteAgentSnapshot(forConversationBackend: bound?.backend ?? "")
                guard self.startIsLive(serial, service: service) else { return }
                let tokenMissing = snapshot.map {
                    $0.authScheme.requiresToken && ($0.token?.isEmpty ?? true)
                } ?? true
                if tokenMissing {
                    // xcstrings
                    CarPlaySpeechService.shared.speak(
                        String(localized: "This chat's AI isn't available on your iPhone. Start a new chat to use another one.")
                    ) { }
                    return
                }
            } else {
                // NEW chat: the DEFAULT is the destination, so its verdict
                // decides. One snapshot turn feeds every branch below.
                let snap = await SettingsManager.shared.newChatPickerSnapshot()
                guard self.startIsLive(serial, service: service) else { return }
                let plan = Self.newChatPlan(
                    resolution: snap.resolution,
                    configured: snap.configuredRefs,
                    override: self.sessionDefaultRefOverride,
                    effectiveRef: defaultRef
                )
                switch plan {
                case .proceed(let ref, let adopt):
                    defaultRef = ref
                    if adopt {
                        // The resolver already proved the Keychain readable and
                        // cleared the pending-bearer-candidate gate, so the
                        // in-car adoption inherits exactly the same proof as
                        // everywhere else. SESSION-LOCAL, like every other
                        // CarPlay gateway decision: this drive only, never the
                        // phone's global default.
                        self.sessionDefaultRefOverride = ref
                        self.refreshPicker()
                    }
                case .chooseInstead(let unavailable, let candidates, let current):
                    // An override that reached here is no longer a member of the
                    // configured set, so it must stop titling the switcher and
                    // stop being this drive's target.
                    if self.sessionDefaultRefOverride != nil {
                        self.sessionDefaultRefOverride = nil
                        self.refreshPicker()
                    }
                    if let unavailable {
                        // Name it, then put the chooser on screen so the fix is
                        // one tap where the driver is already looking. "isn't
                        // available", not "isn't set up": the driver cannot
                        // finish a setup at the wheel, and the storage cannot
                        // prove one is even outstanding.
                        let name = RemoteAgentRefMetadata.shortDisplayName(for: unavailable, customs: snap.badgeRoster)
                        // xcstrings
                        CarPlaySpeechService.shared.speak(
                            String(localized: "Your default AI, \(name), isn't available. Choose another from the list.")
                        ) { }
                    } else {
                        // Nothing to name — no default has been chosen at all.
                        // xcstrings
                        CarPlaySpeechService.shared.speak(
                            String(localized: "Conduck doesn't know which AI to use. Choose one from the list.")
                        ) { }
                    }
                    self.presentGatewayChooser(configured: candidates,
                                               current: current,
                                               customs: snap.badgeRoster)
                    return
                case .setUpOnPhone:
                    // xcstrings
                    CarPlaySpeechService.shared.speak(
                        String(localized: "Set up your personal AI on iPhone first.")
                    ) { }
                    return
                }
            }
            // Freeze the ref before it crosses into the present completion — the
            // session's target is decided by now, and a captured mutable would
            // let a later statement re-aim a session already starting.
            let sessionRef = defaultRef
            // Re-sync the trailing Mute/Unmute button to the (reset) `isMicMuted`
            // state BEFORE presenting the voice template. `endSession` clears
            // `isMicMuted=false`, but a session that ended WHILE muted left the
            // button showing "Unmute"/`mic.slash.fill`. Setting it on the
            // not-yet-presented template (the same "install before present"
            // timing `installVoiceTemplateButtons` relies on) renders reliably
            // and avoids the post-dismiss mutation that used to live in
            // `applyState(.idle)`.
            self.setMuteButton(service: service)
            guard self.startIsLive(serial, service: service) else { return }
            // From here the claim belongs to the present completion, which
            // releases it on both of its exits.
            handedToPresent = true
            self.ensureVoicePresented(service: service, voiceState: "listening", animated: false) { [weak self, weak service] presented in
                guard let self, let service else { return }
                // Re-validated INSIDE the completion: the present is itself a
                // suspension, and a disconnect, a backgrounding or a revoked
                // microphone during it must not be answered with a session.
                guard presented, self.startIsLive(serial, service: service) else {
                    self.releaseStart(serial)
                    self.dismissModalLeftOverBy(refusedStart: service)
                    return
                }
                // Audio-race contract (g1): beginSession AFTER the
                // presentTemplate completion — calling it before CarPlay
                // finishes attaching the voice modal races AVAudioSession
                // .setActive (engine.start() FourCC '!obj' / 560947818).
                service.beginSession(conversationID: conversationID, defaultRef: sessionRef)
                self.releaseStart(serial)
            }
        }
    }

    /// Start a ONE-SHOT Work note: the driver says something, it lands on their
    /// own desk, and the session ends. `startSession` minus the gateway
    /// pre-flight, and the omission is the point — nothing on this lane is
    /// dispatched anywhere, so there is no default to resolve, no conversation
    /// to bind, no snapshot to read and nothing that can refuse the driver for
    /// a reason about an AI they have not set up. That is also why the row is
    /// offered before any gateway exists: the car is useful on day one.
    ///
    /// The g1 audio-race contract is preserved verbatim: the engine starts
    /// INSIDE the `presentTemplate` completion. This body has no suspension
    /// before that call, so — unlike `startSession` — it needs no `Task` hop.
    ///
    /// Split in two because the note has TWO doors — the day-one root row (no
    /// gateway configured, one tap) and the destination chooser's action row
    /// (which has to claim before it pops, then present on the far side of the
    /// pop animation). The claim is taken here, once, and `presentWorkNote`
    /// carries it; a second door that claimed twice would hold its own claim
    /// shut.
    private func startWorkNote(service: CarPlayRecordingService) {
        // Same synchronous claim the chat starter takes, and for the same
        // reason from the other side: a chat start suspended in its pre-flight
        // must not begin under this tap.
        guard let serial = claimStart(.work, service: service) else { return }
        presentWorkNote(serial: serial, service: service)
    }

    /// The presentation half of a Work note, entered with the claim ALREADY
    /// held: `serial` is the caller's, never a fresh one.
    ///
    /// A Work note shows END ONLY. `mute()` tears capture down and DELETES the
    /// partial recording, and Unmute starts a fresh listen — call-style mute on
    /// a multi-turn chat, silent data loss on a one-shot note. The button is
    /// cleared on the not-yet-presented template, the same "install before
    /// present" timing `setMuteButton` relies on; `startSession` repaints it
    /// before the next chat.
    private func presentWorkNote(serial: UInt64, service: CarPlayRecordingService) {
        service.voiceControlTemplate.trailingNavigationBarButtons = []
        self.ensureVoicePresented(service: service, voiceState: "listening", animated: false) { [weak self, weak service] presented in
            guard let self, let service else { return }
            guard presented, self.startIsLive(serial, service: service) else {
                self.releaseStart(serial)
                self.dismissModalLeftOverBy(refusedStart: service)
                return
            }
            service.beginWorkNote()
            self.releaseStart(serial)
        }
    }

    /// Clear the Listening modal a REFUSED start left standing — and only that
    /// one.
    ///
    /// Connection identity is not presentation identity. A present completion
    /// delayed past a backgrounding lands on a scene where the driver has
    /// already started again: the stale completion fails `startIsLive`, but its
    /// service still matches, and dismissing on that alone tears down the NEWER
    /// capture (`templateDidDisappear` then ends it and deletes its partial
    /// recording). So the dismiss is conditioned on the modal belonging to
    /// nobody: no claim held (`releaseStart` ran first, so a claim still here is
    /// someone else's) and no session behind it.
    private func dismissModalLeftOverBy(refusedStart service: CarPlayRecordingService) {
        guard service === recordingService,
              pendingStart == nil,
              !service.sessionActive else { return }
        ensureVoiceDismissed(animated: true)
    }

    /// Present the voice template MODALLY over the persistent list root (or, if
    /// already presented, just switch its live state). The live voice state is
    /// activated and `completion` fired INSIDE the present completion — this is
    /// where `beginSession()` runs (g1: engine.start() must not race
    /// `AVAudioSession.setActive`, which the present completion guarantees).
    ///
    /// `completion` is told WHETHER a modal is up: `true` when the template is
    /// presented (already, or by this call), `false` when there is no interface
    /// controller to present through or the present itself failed. A caller
    /// that starts a recording must never be told "presented" for a modal that
    /// is not there — that is the path that records behind the picker.
    private func ensureVoicePresented(
        service: CarPlayRecordingService,
        voiceState: String,
        animated: Bool,
        completion: (@MainActor (Bool) -> Void)? = nil
    ) {
        // BEFORE the already-presented fast path: with no controller there is
        // no modal, whatever a flag left over from the previous connection says.
        guard let controller = interfaceController else {
            isVoicePresented = false
            completion?(false)
            return
        }
        if isVoicePresented {
            service.voiceControlTemplate.activateVoiceControlState(withIdentifier: voiceState)
            completion?(true)
            return
        }
        isVoicePresented = true
        // Taken AFTER the write above, which is the write that owns this
        // presentation. Anything that touches the flag from here on — a
        // backgrounding, a dismiss, a replacement start — makes this callback
        // obsolete.
        let generation = presentationGeneration
        Self.log.info("Presenting voice template (modal)")
        controller.presentTemplate(
            service.voiceControlTemplate,
            animated: animated
        ) { [weak self, weak service] success, error in
            // `CPInterfaceController` is NOT `NS_SWIFT_UI_ACTOR`, so the SDK may
            // deliver this completion OFF the main thread (it does on the
            // Simulator). Re-hop to the genuine main actor before touching any
            // `@MainActor`/`@Observable` state — otherwise the compiler's
            // isolation-assuming prologue becomes an `unsafeForcedSync` and
            // `beginSession()`'s `@Observable` publishes (`sessionActive`,
            // `state`) fire from a background thread, corrupting the scene's
            // `observe(service:)` tracking. g1 (engine-start inside the present
            // completion) is preserved — it just runs one main-runloop tick
            // later, after the present transaction has drained.
            Task { @MainActor in
                guard let self else { completion?(false); return }
                // A present that belonged to a torn-down connection neither
                // flips this connection's flag nor answers its caller "yes".
                guard self.interfaceController === controller else {
                    completion?(false)
                    return
                }
                // And a present that was overtaken ON THIS controller answers
                // for nothing either — ABOVE both arms below, because each of
                // them writes presentation state: the failure arm clears the
                // flag (over a modal that a later start has since put up), and
                // the success arm activates a voice state on it. "No" is the
                // honest answer to the caller: this presentation is not the one
                // on screen, so nothing may begin behind it. The refusal path
                // dismisses only a modal that belongs to nobody
                // (`dismissModalLeftOverBy`), so a live replacement is safe.
                guard self.presentationGeneration == generation else {
                    completion?(false)
                    return
                }
                guard success else {
                    // NSError domain/code, never `localizedDescription` — see the
                    // same reduction in `CarPlayRecordingService`. A
                    // `CPInterfaceController` error cannot name a network host
                    // today, but the exemption that allowed the error TEXT here was
                    // file-scoped, so any future error logged in this file went
                    // unchecked. Domain + code are unconditionally safe.
                    let nsError = error.map { $0 as NSError }
                    Self.log.error("presentTemplate(voice) failed: \(nsError?.domain ?? "unknown", privacy: .public) \(nsError?.code ?? 0, privacy: .public)")
                    // No voice modal is up: the caller is told so, and for
                    // `startSession` that answer is what stops `beginSession()`
                    // recording behind the picker. Reset the flag so a later
                    // state change / tap can re-present.
                    self.isVoicePresented = false
                    completion?(false)
                    return
                }
                guard let service else { completion?(true); return }
                let live = self.voiceStateIdentifier(for: service.state) ?? voiceState
                service.voiceControlTemplate.activateVoiceControlState(withIdentifier: live)
                completion?(true)
            }
        }
    }

    private func voiceStateIdentifier(
        for state: CarPlayRecordingService.State
    ) -> String? {
        switch state {
        case .recording: return "listening"
        case .processing: return "processing"
        case .speaking: return "speaking"
        case .muted: return "muted"
        case .idle, .error, .permissionBlocked: return nil
        }
    }

    /// Dismiss the modal voice template (returning to the persistent list root)
    /// and, IN THE DISMISS COMPLETION, deactivate the audio session — AFTER the
    /// modal is gone, never before. This sequencing is the fix for "End exits
    /// to the dashboard": the list root always exists, so the scene can never
    /// fall through to the CarPlay home screen, and freeing the car radio after
    /// the dismiss avoids the synchronous-deactivate scene-teardown race.
    private func ensureVoiceDismissed(animated: Bool) {
        guard isVoicePresented else { return }
        isVoicePresented = false
        guard let controller = interfaceController else { return }
        Self.log.info("Dismissing voice template (modal)")
        controller.dismissTemplate(animated: animated) { [weak self] success, error in
            // Same off-main delivery caveat as `presentTemplate` (CPInterfaceController
            // is not `NS_SWIFT_UI_ACTOR`) — re-hop before calling the `@MainActor`
            // `deactivateAudioSession()` so the audio teardown can't run off-main.
            Task { @MainActor in
                // A dismiss belonging to a torn-down connection must not free
                // the NEW connection's audio route out from under a live session.
                guard let self, self.interfaceController === controller else { return }
                // Nor may one OVERTAKEN on this connection: a start claimed and
                // presented while this dismiss was in flight owns the modal and
                // the route now, and deactivating here would cut its capture and
                // its spoken acknowledgement.
                guard !self.isVoicePresented,
                      self.recordingService?.sessionActive != true else { return }
                if !success {
                    // NSError domain/code, never `localizedDescription` — see the
                    // sibling reduction above.
                    let nsError = error.map { $0 as NSError }
                    Self.log.error("dismissTemplate(voice) failed: \(nsError?.domain ?? "unknown", privacy: .public) \(nsError?.code ?? 0, privacy: .public)")
                }
                self.recordingService?.deactivateAudioSession()
            }
        }
    }

    // MARK: - Picker construction + refresh

    /// Rows the "Recent" section may take, given the picker's fixed row budget.
    ///
    /// `CPListTemplate.maximumItemCount` is a hard ceiling the framework
    /// enforces by TRUNCATING, so a row added to the first section without
    /// paying for it here silently costs the oldest conversation instead — a
    /// loss nobody would see in a diff. Two claims on the budget, and each is
    /// subtracted where it is decided:
    ///
    ///   • row 0, "New voice chat" — `CarPlayConversationLabel.recentCap`
    ///   • the one-shot mic-couldn't-start hint, only while it is shown
    ///
    /// "Add to Work" costs nothing here: where a gateway exists it lives in the
    /// chooser the nav-bar switcher opens, not in this list, and the no-gateway
    /// state that does draw it on the root draws no recents at all.
    ///
    /// Pure arithmetic, extracted so the budget is unit-tested without a
    /// CarPlay scene (and `recentCap` itself is left untouched — it answers the
    /// narrower question of what row 0 costs, and other callers ask it).
    static func recentRowBudget(maximumItemCount: Int, showsStartFailureHint: Bool) -> Int {
        CarPlayConversationLabel.recentCap(
            maximumItemCount: maximumItemCount - (showsStartFailureHint ? 1 : 0)
        )
    }

    /// The day-one "Add to Work" row: one tap, one spoken note, straight onto
    /// the driver's own desk.
    ///
    /// Drawn on the ROOT only while no gateway is configured — the one state
    /// with no switcher to open the destination chooser from, and the one where
    /// this is the only row that does anything at all. Everywhere else the
    /// desk is the last row of the "Choose AI" list, beside the gateways, so the
    /// driver picks a destination from one place. Kept as a builder rather than
    /// inline so its label and handler cannot drift from what that chooser row
    /// starts. It carries no detail text for the same reason row 0 does not: a
    /// head unit's row is read at a glance from the driver's seat.
    ///
    /// The desk is NEVER browsed here. Cards are content, and content on a car
    /// screen is what the voice-based-conversation entitlement forbids; this row
    /// only records.
    private func makeWorkNoteItem(service: CarPlayRecordingService) -> CPListItem {
        let item = CPListItem(
            // xcstrings
            text: String(localized: "carplay.picker.addToWork.title", defaultValue: "Add to Work"),
            detailText: nil
        )
        item.setImage(UIImage(systemName: "tray.and.arrow.down.fill"))
        item.handler = { [weak self, weak service] _, completion in
            defer { completion() }
            guard let self, let service else { return }
            guard !service.sessionActive else { return }  // disabled mid-session
            self.startWorkNote(service: service)
        }
        return item
    }

    /// Single-flight state for `refreshPicker()`. The picker's async half reads
    /// the store (`fetchRecentForPicker`) after suspending on `SettingsManager`,
    /// and `.conversationsDidChange` drives it — so an unlatched burst overlapped
    /// without bound, one live fetch per post. Each opens a fresh background
    /// context and parks a dispatch worker on a synchronous Core Data
    /// coordinator hop; at libdispatch's 512-thread ceiling the process wedges.
    /// Same bound, same reason, as `ConversationDetailViewModel.scheduleReload()`.
    private var pickerRefreshInFlight = false
    private var pickerRefreshPending = false

    /// Rebuild the picker sections in place. Off the main actor for the store
    /// read, then mutate the template on the main actor.
    ///
    /// COALESCED: at most one refresh in flight plus one trailing refresh for
    /// anything that arrived during it. Only the ASYNC half is latched — the
    /// synchronous prologue below always runs, because it paints permission
    /// state, and deferring that would leave a revoked microphone showing a
    /// fully-functional-looking picker whose rows cannot start a session.
    ///
    /// The trailing pass RE-ENTERS this function rather than looping the async
    /// body, so the prologue (permission state, the one-shot hint, the row
    /// budget) is recomputed from current state — a trailing pass that reused
    /// the first pass's captured `cap`/`service` could paint a stale template.
    /// Re-entry is safe: the in-flight flag is already cleared, and it schedules
    /// a fresh task rather than nesting, so depth cannot accumulate.
    private func refreshPicker() {
        guard let service = recordingService, let template = listTemplate else { return }

        // Permission-blocked → a single permission row (no New / Recent).
        if case .permissionBlocked(let reason) = service.state {
            let (title, detail) = permissionCopy(reason)
            let item = CPListItem(text: title, detailText: detail)
            item.setImage(UIImage(systemName: "mic.slash.fill"))
            item.handler = { [weak self, weak service] _, completion in
                defer { completion() }
                guard let service else { return }
                self?.speakPermissionInstruction(reason)
            }
            template.updateSections([CPListSection(items: [item])])
            return
        }

        let cap = Self.recentRowBudget(
            maximumItemCount: CPListTemplate.maximumItemCount,
            showsStartFailureHint: oneShotStartFailureHint
        )

        // A refresh is already running: record the ask and let its trailing pass
        // pick it up. Placed AFTER the synchronous prologue (so permission state
        // still paints immediately) and BEFORE the first suspension below — the
        // only placement that both bounds the fan-out and keeps the picker
        // honest about a revoked microphone.
        if pickerRefreshInFlight {
            pickerRefreshPending = true
            return
        }
        pickerRefreshInFlight = true

        Task { @MainActor in
            defer {
                // Scoped to THIS connection's template: a refresh still in
                // flight when the cable dropped must not unlatch the refresh
                // the reconnect is already running.
                if template === self.listTemplate {
                    self.pickerRefreshInFlight = false
                    if self.pickerRefreshPending {
                        // A start claim is held: KEEP the ask latched —
                        // `releaseStart` drains it — instead of dropping a
                        // repaint nothing else is going to run.
                        if self.pendingStart == nil {
                            self.pickerRefreshPending = false
                            // Re-apply the gate the notification path applies
                            // before it ever calls here: a session may have
                            // STARTED while this pass was in flight, and
                            // repainting the picker root under a presented voice
                            // modal is a known CarPlay assertion source. That
                            // ask is dropped, not queued — the session's own
                            // teardown refreshes the list on the way out.
                            if self.recordingService?.sessionActive != true {
                                self.refreshPicker()
                            }
                        }
                    }
                }
            }

            // COMPUTE FIRST. Every read this pass needs is gathered across the
            // suspensions below with NOT ONE template mutation between them, so
            // the gate that follows is asked exactly once. Painting as we went
            // meant a refusal landing between two mutations — the switcher
            // button of this pass over the rows of the last one.
            //
            // No-gateway → the setup-hint row (no New voice chat: there's
            // nothing to talk to yet) PLUS "Add to Work", which needs no
            // gateway at all: a note goes to the driver's own desk, so the car
            // is useful before any AI is set up and this is the one state where
            // it is the only working row. Any gateway: the gate is "is ANY
            // gateway configured?" so CarPlay offers a new chat as soon as ≥1
            // backend is set up; the per-conversation send routing already
            // binds each chat to its own backend. Once one exists the root
            // draws no Work row — the desk is reached through the switcher's
            // chooser, beside the gateways, which is why the switcher is drawn
            // for a single gateway too.
            let configuredRefs = await SettingsManager.shared.configuredRemoteAgentRefs()
            // Custom roster (for labeling built-in vs custom refs in the
            // switcher + chooser). Fetched once per refresh.
            var customs: [CustomGateway] = []
            // Effective CarPlay ref = session-local override (this drive) ?? the
            // iPhone's device-local default. NEVER reads the global default
            // directly so a CarPlay switch can't leak to the phone. Read only
            // when there is a switcher to title with it — any configured
            // gateway, since the chooser it opens is where "Add to Work" lives.
            var current: RemoteAgentRef?
            var recents: [ConversationStore.RecentConversation] = []
            // Badge visibility spans the WHOLE store, not `recents` — that slice
            // is capped, and the phone answers from every conversation. Failing
            // the fetch degrades to the displayed slice, which is the safe
            // direction: it can only under-report identities and hide the badge,
            // never draw a blank one.
            var allBackends: Set<String> = []
            if !configuredRefs.isEmpty {
                customs = await SettingsManager.shared.gatewayBadgeRoster()
                current = await self.effectiveCarPlayRef()
                recents = (try? await ConversationStore.shared.fetchRecentForPicker(limit: cap)) ?? []
                if !recents.isEmpty {
                    allBackends = (try? await ConversationStore.shared.distinctBackends())
                        ?? Set(recents.map(\.backend))
                }
            }

            // GATE ONCE, after the last suspension and before the first
            // mutation. A refusal is RETAINED, never dropped: a start claim
            // released without a session (the present failed, the pre-flight
            // refused) still has to leave a correctly painted picker behind, and
            // `releaseStart` is what runs this again.
            guard service === self.recordingService,
                  template === self.listTemplate,
                  self.pendingStart == nil,
                  !service.sessionActive else {
                self.pickerRefreshPending = true
                return
            }
            // The synchronous prologue already painted this state; repainting it
            // from here would only race it.
            if case .permissionBlocked = service.state { return }

            // PAINT.
            guard !configuredRefs.isEmpty else {
                // xcstrings
                let item = CPListItem(
                    text: String(localized: "setup.requiredOnPhone", defaultValue: "Set up your AI on iPhone first."),
                    detailText: nil
                )
                item.setImage(UIImage(systemName: "iphone"))
                // The WORKING row first. This state's setup row is not a
                // prerequisite for the note below it — reading as one is exactly
                // what putting it on top did — and on day one "Add to Work" is
                // the only row here that does anything at all.
                var firstSectionItems: [CPListItem] = [self.makeWorkNoteItem(service: service), item]
                // The one-shot mic-couldn't-start hint belongs in THIS state
                // too, and only became reachable here when "Add to Work" made
                // the state startable at all: a start failure ends the session
                // silently (no TTS over a wedged session, no CPAlertTemplate),
                // so without the row the modal simply vanishes and the picker
                // looks untouched. Its retry sentence names the row this state
                // actually draws — "New voice chat" is not offered here.
                if self.oneShotStartFailureHint {
                    let hint = CPListItem(
                        text: String(localized: "carplay.hint.captureStartFailed.title", defaultValue: "Mic couldn't start"),  // xcstrings
                        detailText: String(localized: "carplay.hint.captureStartFailed.detail.work", defaultValue: "Tap Add to Work to try again.")  // xcstrings
                    )
                    hint.setImage(UIImage(systemName: "mic.slash.fill"))
                    hint.handler = { _, completion in completion() }
                    firstSectionItems.insert(hint, at: 0)
                }
                // Three rows at most (hint + Work + setup), so this state cannot
                // reach `CPListTemplate.maximumItemCount`; it draws no recents,
                // which is what the hint's row is priced out of in the branch
                // below.
                template.leadingNavigationBarButtons = []
                template.updateSections([CPListSection(items: firstSectionItems)])
                return
            }

            // Default-gateway switcher (idle list ONLY — the picker is the root
            // and no voice modal is up while idle). Shown whenever a gateway is
            // configured, one included: the list it opens is the destination
            // chooser — every gateway, then "Add to Work" — so with a single
            // gateway it is still the only door to the desk from this state.
            // Titled with the current default's display name; tapping pushes
            // that chooser. List templates render nav-bar buttons reliably.
            if let current {
                // The SHORT form: this is a nav-bar button on a head unit, read
                // at a glance from the driver's seat, and a custom gateway's name
                // may be up to 40 characters. The car's own truncation is opaque
                // and varies by head unit; a known budget does not.
                let title = RemoteAgentRefMetadata.shortDisplayName(for: current, customs: customs)
                let switcher = CPBarButton(title: title) { [weak self] _ in
                    self?.presentGatewayChooser(configured: configuredRefs, current: current, customs: customs)
                }
                template.leadingNavigationBarButtons = [switcher]
            } else {
                template.leadingNavigationBarButtons = []
            }

            // Row 0 — "New voice chat".
            let newItem = CPListItem(
                text: String(localized: "New voice chat"),  // xcstrings
                detailText: nil
            )
            newItem.setImage(UIImage(systemName: "mic.fill"))
            newItem.handler = { [weak self, weak service] _, completion in
                defer { completion() }
                guard let self, let service else { return }
                guard !service.sessionActive else { return }  // disabled mid-session
                self.startSession(service: service, conversationID: nil)
            }
            var firstSectionItems: [CPListItem] = [newItem]

            // One-shot mic-couldn't-start hint, ABOVE "New voice chat" — the
            // only feedback a silent start-failure end gets (no TTS over a
            // wedged session; no CPAlertTemplate, which races the voice-modal
            // dismiss animation). Informational: tapping it does nothing.
            //
            // The sentence names the row that FAILED. A Work note can start
            // from this state too (the chooser's last row), so a failed Work
            // start told to "Tap New voice chat" would route the repeated
            // private thought to an AI.
            if oneShotStartFailureHint {
                let detail = self.lastStartDestination == .work
                    ? String(localized: "carplay.hint.captureStartFailed.detail.work", defaultValue: "Tap Add to Work to try again.")  // xcstrings
                    : String(localized: "carplay.hint.captureStartFailed.detail", defaultValue: "Tap New voice chat to try again.")  // xcstrings
                let hint = CPListItem(
                    text: String(localized: "carplay.hint.captureStartFailed.title", defaultValue: "Mic couldn't start"),  // xcstrings
                    detailText: detail
                )
                hint.setImage(UIImage(systemName: "mic.slash.fill"))
                hint.handler = { _, completion in completion() }
                firstSectionItems.insert(hint, at: 0)
            }

            // No "Add to Work" row here: with a gateway configured the desk is
            // the last row of the chooser the switcher above opens, beside the
            // gateways, so the root stays the conversation list the driver came
            // for — and `recentRowBudget` prices no Work row for the same reason.
            let newSection = CPListSection(items: firstSectionItems)

            // "Recent" section — conversations to continue (label + date only).
            var sections: [CPListSection] = [newSection]
            if !recents.isEmpty {
                let now = Date()
                let showGatewayBadge = RemoteAgentRefMetadata.shouldShowBadges(
                    configured: configuredRefs,
                    conversationBackends: allBackends,
                    customs: customs
                )
                let recentItems: [CPListItem] = recents.map { recent in
                    // A Work project's thread names its project after the
                    // date — the detail line is the row's only second text
                    // slot; the date leads so a clip only ever takes the name.
                    let item = CPListItem(
                        text: recent.label,
                        detailText: CarPlayConversationLabel.detailLine(
                            projectTitle: recent.projectTitle, lastActivityAt: recent.lastActivityAt, now: now
                        )
                    )
                    // Leading gateway badge (multi-gateway only) — color-codes
                    // which agent a thread belongs to where the thread text
                    // itself can't be shown while driving. Unresolvable refs
                    // (deleted custom) just get no image.
                    if showGatewayBadge, let ref = RemoteAgentRef(rawString: recent.backend),
                       let badge = GatewayBadge.image(for: ref, customs: customs) {
                        item.setImage(badge)
                    }
                    // …and wears a trailing folder on that same line — the
                    // TRAILING slot, so the leading gateway badge keeps its
                    // meaning; no colour crosses to the car, and the tap still
                    // resumes the thread. Live projects only; a deleted
                    // project's ghost membership draws and names nothing.
                    if recent.inLiveProject {
                        item.setAccessoryImage(UIImage(systemName: "folder"))
                    }
                    item.handler = { [weak self, weak service] _, completion in
                        defer { completion() }
                        guard let self, let service else { return }
                        guard !service.sessionActive else { return }
                        self.startSession(service: service, conversationID: recent.id)
                    }
                    return item
                }
                sections.append(
                    CPListSection(
                        items: recentItems,
                        header: String(localized: "Recent"),  // xcstrings
                        sectionIndexTitle: nil
                    )
                )
            }

            template.updateSections(sections)
        }
    }

    /// The gateway a CarPlay session may adopt as its SESSION-LOCAL override, or
    /// nil when the drive must use the effective ref it already had.
    ///
    /// Only `.adopted` and `.bootstrapped` qualify, and nothing else ever does.
    /// Those are the two verdicts where the resolver has already PERSISTED a
    /// pointer after proving the Keychain readable and clearing the
    /// pending-bearer-candidate gate — so the car inherits a decision the device
    /// already made, rather than making one of its own behind the wheel. Every
    /// other verdict either needs no change (`.usable`), needs the driver to
    /// choose (`.defaultUnavailable`, `.selectionRequired`), or must be left strictly
    /// alone (`.nothingConfigured`, `.setupUnfinished`, `.readingUnreliable`).
    ///
    /// A pure `static` on purpose, and not inlined in `startSession`: the
    /// authoritative suite runs on the iOS Simulator with no CarPlay scene to
    /// drive, so a rule written inside the delegate's `Task { @MainActor }` is
    /// never exercised by a test. `GatewayGate`'s header makes exactly this
    /// argument for exactly this reason.
    static func sessionOverrideRef(for resolution: DefaultGatewayResolution) -> RemoteAgentRef? {
        switch resolution {
        case .adopted(let ref, _): return ref
        case .bootstrapped(let ref): return ref
        case .usable, .defaultUnavailable, .selectionRequired,
             .nothingConfigured, .setupUnfinished, .readingUnreliable:
            return nil
        }
    }

    /// What a NEW CarPlay chat does, decided from the device verdict, the
    /// configured roster and the gateway the driver picked for THIS drive.
    enum NewChatPlan: Equatable {
        /// Mint on `ref`. `adoptAsSessionOverride` is true only when the ref
        /// comes from a resolver repair the car is inheriting, in which case the
        /// switcher title has to be re-rendered.
        case proceed(ref: RemoteAgentRef, adoptAsSessionOverride: Bool)
        /// Speak, then put the chooser on screen. `broken` is non-nil only when a
        /// stored pointer can be honestly named as the thing that is wrong.
        case chooseInstead(unavailable: RemoteAgentRef?, candidates: [RemoteAgentRef], current: RemoteAgentRef)
        /// There is nothing to choose from. Speak and stop.
        case setUpOnPhone
    }

    /// The NEW-chat rule, whole, as a pure function.
    ///
    /// A SESSION OVERRIDE WINS OVER THE DEVICE VERDICT, and that is the point of
    /// the first branch. The device verdict describes the PHONE's stored pointer;
    /// the override is the gateway the driver just picked from this car's own
    /// chooser, which lists nothing but configured refs and deliberately never
    /// writes the phone's default. Without this branch the refusals below are a
    /// closed loop: the only exit they offer is the chooser, and taking it
    /// changes nothing they read, so a driver whose phone default is broken (or
    /// unchosen) could not start a chat for the whole drive.
    ///
    /// Membership of `configured` is the gate, which is the same test `.usable`
    /// applies — so an override for a gateway forgotten on the phone mid-drive
    /// falls back to the verdict rather than routing somewhere that cannot send
    /// (I2 stays fail-closed). `.nothingConfigured` / `.setupUnfinished` need no
    /// special case: `configured` is empty there, so no override survives the
    /// membership test.
    ///
    /// A pure `static` for the same reason `sessionOverrideRef` is one — the
    /// authoritative suite runs on the iOS Simulator with no CarPlay scene, so a
    /// rule written inside the delegate's `Task { @MainActor }` is never
    /// exercised by a test.
    static func newChatPlan(
        resolution: DefaultGatewayResolution,
        configured: [RemoteAgentRef],
        override: RemoteAgentRef?,
        effectiveRef: RemoteAgentRef
    ) -> NewChatPlan {
        if let override, configured.contains(override) {
            return .proceed(ref: override, adoptAsSessionOverride: false)
        }
        if let adopted = sessionOverrideRef(for: resolution), adopted != effectiveRef {
            return .proceed(ref: adopted, adoptAsSessionOverride: true)
        }
        switch resolution {
        case .defaultUnavailable(let pointer, let candidates, let pointerIsParked):
            // `unavailable` is spoken aloud, so a pointer the APP parked after a
            // Forget must not travel: the driver never chose that gateway, and
            // hearing it named is an accusation about a choice they did not make.
            // `current` still carries it, because the chooser needs a row to check
            // even when nothing may be named. The phone, the wrist and the
            // headless lanes make the same collapse.
            return .chooseInstead(unavailable: pointerIsParked ? nil : pointer,
                                  candidates: candidates, current: pointer)
        case .selectionRequired(let candidates):
            return .chooseInstead(unavailable: nil, candidates: candidates, current: resolution.ref)
        case .nothingConfigured, .setupUnfinished:
            return .setUpOnPhone
        case .usable, .adopted, .bootstrapped, .readingUnreliable:
            // `.readingUnreliable` proceeds because refusing on a reading we
            // cannot trust would strand a driver whose gateways are all fine
            // behind a Keychain that has not opened yet.
            return .proceed(ref: effectiveRef, adoptAsSessionOverride: false)
        }
    }

    /// The ref CarPlay routes NEW conversations + titles the switcher with: the
    /// session-local override (this drive) if the driver picked one, else the
    /// iPhone's device-local default. Never reads or writes the global default
    /// beyond this read-fallback, so a CarPlay switch stays in-car.
    private func effectiveCarPlayRef() async -> RemoteAgentRef {
        if let override = sessionDefaultRefOverride { return override }
        return await SettingsManager.shared.defaultRemoteAgentRef()
    }

    /// Push a gateway-chooser `CPListTemplate` onto the idle list nav stack
    /// (standard CarPlay; no session is active, so no voice modal is up over the
    /// picker root). One row per configured REF (built-ins + customs), checkmark
    /// on the effective ref. Selecting a row sets the SESSION-LOCAL override
    /// (this-drive-only — `sessionDefaultRefOverride`), pops back, and re-runs
    /// `refreshPicker` so the switcher button title updates. It NEVER writes the
    /// global default (which would silently re-point the phone/iPad/Mac and clear
    /// their active-conversation pointers) and NEVER touches any active-conversation
    /// pointer. New chats mint on the effective CarPlay ref; existing recents keep
    /// their bound `Conversation.backend` — no routing change.
    ///
    /// The list ends with the desk: one **ACTION** row, "Add to Work", after
    /// every gateway row. Wherever a gateway exists this is THE door to the
    /// note — the root draws the same row only while no gateway is configured
    /// and there is no switcher to open this list from — so the destination
    /// picker the driver is looking at names every destination, including the
    /// one that is not an AI. That is also why the switcher is drawn for a
    /// single gateway: without it the desk would be unreachable from the car.
    /// It is an action precisely because the rows above it are not: a gateway
    /// row stores this drive's target, and a Work row that did the same would be
    /// a drive-long mode that survives the note, resets silently on the next
    /// reconnect, and one day answers a private thought with an AI. So it never
    /// carries a checkmark, never writes `sessionDefaultRefOverride`, and starts
    /// the note immediately: claim, pop, present. Nothing about the tap survives
    /// it, and the next "New voice chat" goes to the gateway exactly as it would
    /// have if this row had never been tapped.
    private func presentGatewayChooser(
        configured: [RemoteAgentRef],
        current: RemoteAgentRef,
        customs: [CustomGateway]
    ) {
        // The service this chooser was pushed over. A pick that lands after a
        // reconnect belongs to a connection that no longer exists.
        let service = recordingService
        var items: [CPListItem] = configured.map { ref in
            let item = CPListItem(
                // Short form, same reason as the switcher button that opens this
                // list: a row the driver cannot read to the end is a row they
                // cannot tell from the one above it.
                text: RemoteAgentRefMetadata.shortDisplayName(for: ref, customs: customs),
                detailText: nil
            )
            if ref == current {
                item.setImage(UIImage(systemName: "checkmark"))
            }
            item.handler = { [weak self, weak service] _, completion in
                defer { completion() }
                guard let self else { return }
                Task { @MainActor in
                    guard let service, service === self.recordingService,
                          !service.sessionActive, self.pendingStart == nil else { return }
                    // SESSION-LOCAL only: re-point THIS drive, never the global
                    // default and never any active-conversation pointer.
                    self.sessionDefaultRefOverride = ref
                    self.interfaceController?.popTemplate(animated: true, completion: nil)
                    self.refreshPicker()
                }
            }
            return item
        }
        // LAST, after every gateway row: the list is read top-down at the wheel
        // and the AIs are what the driver opened it for. Same words as the root
        // row — one action has one name — and the same symbol, so the two doors
        // read as the one thing they are.
        let workItem = CPListItem(
            // xcstrings
            text: String(localized: "carplay.picker.addToWork.title", defaultValue: "Add to Work"),
            detailText: nil
        )
        workItem.setImage(UIImage(systemName: "tray.and.arrow.down.fill"))
        workItem.handler = { [weak self, weak service] _, completion in
            defer { completion() }
            guard let self, let service else { return }
            guard service === self.recordingService, !service.sessionActive else { return }
            // CLAIMED BEFORE THE POP, synchronously, exactly as the day-one root
            // row claims before its present: the pop is a suspension, and "New voice
            // chat" is one tap away on the list underneath this one. A claim
            // taken on the far side would let that tap's chat start win the
            // guard and answer this note with an AI.
            guard let serial = self.claimStart(.work, service: service) else { return }
            // No controller, no pop and no note — and the claim must not be left
            // holding the next tap's door shut.
            guard let controller = self.interfaceController else {
                self.releaseStart(serial)
                return
            }
            // Present on the FAR SIDE of the pop: the voice modal goes up over
            // the picker root, which is where every other session presents from,
            // and never over a chooser that is still animating away.
            controller.popTemplate(animated: true) { [weak self, weak service] success, _ in
                // Same off-main delivery caveat as `presentTemplate`
                // (`CPInterfaceController` is not `NS_SWIFT_UI_ACTOR`).
                Task { @MainActor in
                    guard let self else { return }
                    // The claim carried through, never re-taken: a start refused
                    // here releases the serial it was given, and the picker
                    // refresh retained under it drains with it.
                    guard let service, success, self.startIsLive(serial, service: service) else {
                        self.releaseStart(serial)
                        return
                    }
                    self.presentWorkNote(serial: serial, service: service)
                }
            }
        }
        items.append(workItem)
        let chooser = CPListTemplate(
            title: String(localized: "chat.chooseAI.label", defaultValue: "Choose AI"),
            sections: [CPListSection(items: items)]
        )
        interfaceController?.pushTemplate(chooser, animated: true, completion: nil)
    }

    private func observeConversations() {
        conversationsObserver = NotificationCenter.default.addObserver(
            forName: .conversationsDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, let service = self.recordingService else { return }
                // Don't churn the list mid-session — it's disabled then
                // anyway, and the session's own teardown refreshes on the way
                // out, so that ask is dropped.
                guard !service.sessionActive else { return }
                // Under a CLAIMED start the refresh would be refused, so RETAIN
                // the ask instead of dropping it: `releaseStart` drains it. A
                // start that is then refused (the present failed, the pre-flight
                // said no) leaves nothing else to repaint the Recent list, and it
                // would stay stale for the rest of the drive.
                guard self.pendingStart == nil else {
                    self.pickerRefreshPending = true
                    return
                }
                self.refreshPicker()
            }
        }
    }

    // MARK: - Voice template buttons (stable End + Mute)

    /// Install the STABLE button pair on the voice template ONCE, in
    /// `didConnect`, BEFORE the template is ever presented. CarPlay does not
    /// reliably render nav-bar buttons swapped in AFTER a template is presented
    /// (the prior per-state swap left the corners blank); setting them once
    /// up-front — the Apple-approved `installEndButton` timing — renders.
    ///
    /// - Leading "End": ends the session in ANY state (`endFromButton`).
    /// - Trailing "Mute"/"Unmute": mic-mutes the session (`toggleMute`) then
    ///   re-assigns ITSELF to reflect the new state. Re-assignment on a discrete
    ///   user tap (not a per-state swap) is the supported update path.
    private func installVoiceTemplateButtons(service: CarPlayRecordingService) {
        let endButton = CPBarButton(title: String(localized: "End")) { [weak self, weak service] _ in  // xcstrings
            guard let service else { return }
            // A start still inside its present completion has no session yet, so
            // `endFromButton` alone returns on its `sessionActive` guard and the
            // completion goes on to record. Drop the claim FIRST.
            self?.cancelPendingStart(for: service)
            // Asked BEFORE the end, because afterwards the answer is `.idle`
            // either way — see `finishIdleEndTheObserverCannotDeliver`.
            let startupNeverLeftIdle = service.state == .idle
            service.endFromButton()
            if startupNeverLeftIdle {
                self?.finishIdleEndTheObserverCannotDeliver(service: service)
            }
        }
        service.voiceControlTemplate.leadingNavigationBarButtons = [endButton]
        setMuteButton(service: service)
    }

    /// Build (or rebuild) the trailing Mute/Unmute button to match the current
    /// `service.isMicMuted` state, with the matching mic SF Symbol.
    private func setMuteButton(service: CarPlayRecordingService) {
        let muted = service.isMicMuted
        let title = muted
            ? String(localized: "Unmute")  // xcstrings
            : String(localized: "Mute")    // xcstrings
        let image = UIImage(systemName: muted ? "mic.slash.fill" : "mic.fill")
        let muteButton = CPBarButton(image: image ?? UIImage()) { [weak self, weak service] _ in
            guard let self, let service else { return }
            service.toggleMute()
            // Reflect the new state on the button itself (discrete user tap).
            self.setMuteButton(service: service)
        }
        muteButton.title = title
        service.voiceControlTemplate.trailingNavigationBarButtons = [muteButton]
    }

    // MARK: - State observation

    private func observe(service: CarPlayRecordingService) {
        let currentGeneration = observationGeneration
        withObservationTracking {
            _ = service.state
        } onChange: { [weak self, weak service] in
            Task { @MainActor in
                guard let self, let service else { return }
                guard self.observationGeneration == currentGeneration else { return }
                self.applyState(service.state, service: service)
                self.observe(service: service) // re-arm
            }
        }
    }

    // MARK: - Permission UX

    private func speakPermissionInstruction(
        _ reason: CarPlayRecordingService.State.PermissionReason
    ) {
        let phrase: String
        switch reason {
        case .undetermined:
            // xcstrings
            phrase = String(localized: "Open Conduck on your iPhone to enable microphone access.")
        case .denied:
            // xcstrings
            phrase = String(localized: "Microphone access is off for Conduck. Turn it on in iPhone Settings.")
        }
        CarPlaySpeechService.shared.speak(phrase) { }
    }

    private func permissionCopy(
        _ reason: CarPlayRecordingService.State.PermissionReason
    ) -> (String, String) {
        switch reason {
        case .undetermined:
            // xcstrings
            return (
                String(localized: "Mic access needed"),
                String(localized: "Open Conduck on your iPhone to enable microphone access.")
            )
        case .denied:
            // xcstrings
            return (
                String(localized: "Mic access is off"),
                String(localized: "Turn it on in iPhone Settings.")
            )
        }
    }
}

/// The one-start-at-a-time rule, as two pure answers.
///
/// Extracted for the same reason `newChatPlan` and `sessionOverrideRef` are:
/// the authoritative suite runs on the iOS Simulator with no CarPlay scene, so
/// a rule written inside `CarPlaySceneDelegate`'s private starters — which need
/// a `CPInterfaceController` and an audio engine to reach — is never exercised
/// by a test. What is at stake is the boundary itself: the driver who tapped
/// "Add to Work" must not end up in an AI chat because a chat start was parked
/// in its gateway pre-flight under their tap.
enum CarPlayStartGate {

    /// Whether a row tap may claim the single in-flight start. Every condition
    /// is a refusal: a service already recording, a live session, or a start
    /// already claimed and not yet begun.
    static func mayClaim(isIdle: Bool, sessionActive: Bool, claimHeld: Bool) -> Bool {
        isIdle && !sessionActive && !claimHeld
    }

    /// Whether the claim `serial` may still act after a suspension.
    ///
    /// Six independent protections, and each one is a way a start can be
    /// overtaken between the tap and the engine: the claim was released or
    /// replaced, the connection was torn down and rebuilt, the interface
    /// controller went away, the driver switched to Maps, the service is no
    /// longer idle, or a session already began.
    static func isLive(
        claimSerial: UInt64?,
        serial: UInt64,
        serviceIsCurrent: Bool,
        controllerAttached: Bool,
        sceneActive: Bool,
        isIdle: Bool,
        sessionActive: Bool
    ) -> Bool {
        claimSerial == serial
            && serviceIsCurrent
            && controllerAttached
            && sceneActive
            && isIdle
            && !sessionActive
    }
}
#endif
