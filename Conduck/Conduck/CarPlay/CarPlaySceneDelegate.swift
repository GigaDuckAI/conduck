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
// is active. No-gateway state = a single "Set up your AI on iPhone
// first." row.
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
    private var isVoicePresented = false

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
        if let stale = recordingService {
            Self.log.info("didConnect found a stale recordingService — tearing it down first")
            stale.teardown()
            recordingService = nil
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

        // Mic-couldn't-start feedback: the service fires this BEFORE its silent
        // `endSession`, so the `.idle`-driven `refreshPicker` sees the flag.
        service.onCaptureStartFailed = { [weak self] in
            self?.oneShotStartFailureHint = true
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
        guard case .idle = service.state, !service.sessionActive else { return }
        // Consumed: the driver is acting again — the hint's job is done. (The
        // row disappears on the refresh after this session ends, whatever its
        // outcome; a NEW start failure sets it again.)
        oneShotStartFailureHint = false
        Task { @MainActor in
            // Capture the effective CarPlay ref (session-local override ?? the
            // iPhone's device-local default) and stash it on the service so a
            // NEW-conversation mint uses it instead of reading the global default.
            // Existing-conversation routing (reads `Conversation.backend`) ignores
            // this. Captured at session start so a chooser change mid-session can't
            // retarget a live session.
            var defaultRef = await self.effectiveCarPlayRef()

            if let conversationID {
                // EXISTING chat: the thread is BOUND to its gateway. Apply the
                // same two conditions the send path applies (a snapshot must
                // resolve, and a `.bearer` scheme must have a non-empty token)
                // and REFUSE on failure — never reroute, never re-point. The
                // driver's exit is a new chat, which the picker already offers.
                let bound = try? await ConversationStore.shared.fetchConversation(id: conversationID)
                let snapshot = await SettingsManager.shared
                    .remoteAgentSnapshot(forConversationBackend: bound?.backend ?? "")
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
            self.ensureVoicePresented(service: service, voiceState: "listening", animated: false) { [weak service] in
                // Audio-race contract (g1): beginSession AFTER the
                // presentTemplate completion — calling it before CarPlay
                // finishes attaching the voice modal races AVAudioSession
                // .setActive (engine.start() FourCC '!obj' / 560947818).
                service?.beginSession(conversationID: conversationID, defaultRef: sessionRef)
            }
        }
    }

    /// Present the voice template MODALLY over the persistent list root (or, if
    /// already presented, just switch its live state). The live voice state is
    /// activated and `completion` fired INSIDE the present completion — this is
    /// where `beginSession()` runs (g1: engine.start() must not race
    /// `AVAudioSession.setActive`, which the present completion guarantees).
    private func ensureVoicePresented(
        service: CarPlayRecordingService,
        voiceState: String,
        animated: Bool,
        completion: (@MainActor () -> Void)? = nil
    ) {
        if isVoicePresented {
            service.voiceControlTemplate.activateVoiceControlState(withIdentifier: voiceState)
            completion?()
            return
        }
        isVoicePresented = true
        Self.log.info("Presenting voice template (modal)")
        interfaceController?.presentTemplate(
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
                guard success else {
                    // NSError domain/code, never `localizedDescription` — see the
                    // same reduction in `CarPlayRecordingService`. A
                    // `CPInterfaceController` error cannot name a network host
                    // today, but the exemption that allowed the error TEXT here was
                    // file-scoped, so any future error logged in this file went
                    // unchecked. Domain + code are unconditionally safe.
                    let nsError = error.map { $0 as NSError }
                    Self.log.error("presentTemplate(voice) failed: \(nsError?.domain ?? "unknown", privacy: .public) \(nsError?.code ?? 0, privacy: .public)")
                    // No voice modal is up, so do NOT run the completion — for
                    // `startSession` that completion is `beginSession()`, and
                    // starting a recording session with no modal to host it is
                    // the path that records behind the picker. Reset the flag so
                    // a later state change / tap can re-present.
                    self?.isVoicePresented = false
                    return
                }
                guard let service else { completion?(); return }
                let live = self?.voiceStateIdentifier(for: service.state) ?? voiceState
                service.voiceControlTemplate.activateVoiceControlState(withIdentifier: live)
                completion?()
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
        Self.log.info("Dismissing voice template (modal)")
        interfaceController?.dismissTemplate(animated: animated) { [weak self] success, error in
            // Same off-main delivery caveat as `presentTemplate` (CPInterfaceController
            // is not `NS_SWIFT_UI_ACTOR`) — re-hop before calling the `@MainActor`
            // `deactivateAudioSession()` so the audio teardown can't run off-main.
            Task { @MainActor in
                if !success {
                    // NSError domain/code, never `localizedDescription` — see the
                    // sibling reduction above.
                    let nsError = error.map { $0 as NSError }
                    Self.log.error("dismissTemplate(voice) failed: \(nsError?.domain ?? "unknown", privacy: .public) \(nsError?.code ?? 0, privacy: .public)")
                }
                self?.recordingService?.deactivateAudioSession()
            }
        }
    }

    // MARK: - Picker construction + refresh

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

        // The one-shot start-failure hint occupies a row of the template's
        // fixed item budget while shown; `recentCap` already reserves row 0.
        let cap = CarPlayConversationLabel.recentCap(
            maximumItemCount: CPListTemplate.maximumItemCount - (oneShotStartFailureHint ? 1 : 0)
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
                self.pickerRefreshInFlight = false
                if self.pickerRefreshPending {
                    self.pickerRefreshPending = false
                    // Re-apply the gate the notification path applies before it
                    // ever calls here: a session may have STARTED while this
                    // pass was in flight, and repainting the picker root under a
                    // presented voice modal is a known CarPlay assertion source.
                    // The deferred ask is dropped, not queued — the session's
                    // own teardown refreshes the list on the way out.
                    if self.recordingService?.sessionActive != true {
                        self.refreshPicker()
                    }
                }
            }
            // No-gateway → a single setup-hint row (no New voice chat: there's
            // nothing to talk to yet). Multi-gateway: the gate is "is ANY
            // gateway configured?" so CarPlay offers a new chat as soon as ≥1
            // backend is set up; the per-conversation send routing already
            // binds each chat to its own backend.
            let configuredRefs = await SettingsManager.shared.configuredRemoteAgentRefs()
            guard !configuredRefs.isEmpty else {
                // xcstrings
                let item = CPListItem(
                    text: String(localized: "setup.requiredOnPhone", defaultValue: "Set up your AI on iPhone first."),
                    detailText: nil
                )
                item.setImage(UIImage(systemName: "iphone"))
                template.leadingNavigationBarButtons = []
                template.updateSections([CPListSection(items: [item])])
                return
            }

            // Custom roster (for labeling built-in vs custom refs in the
            // switcher + chooser). Fetched once per refresh.
            let customs = await SettingsManager.shared.gatewayBadgeRoster()

            // Default-gateway switcher (idle list ONLY — the picker is the root
            // and no voice modal is up while idle). Shown only when ≥2 gateways
            // (built-ins + customs) are configured (with one there is nothing to
            // switch). Titled with the current default's display name; tapping
            // pushes a chooser. List templates render nav-bar buttons reliably.
            if configuredRefs.count >= 2 {
                // Effective CarPlay ref = session-local override (this drive) ??
                // the iPhone's device-local default. NEVER reads the global
                // default directly so a CarPlay switch can't leak to the phone.
                let current = await self.effectiveCarPlayRef()
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
            if oneShotStartFailureHint {
                let hint = CPListItem(
                    text: String(localized: "carplay.hint.captureStartFailed.title", defaultValue: "Mic couldn't start"),  // xcstrings
                    detailText: String(localized: "carplay.hint.captureStartFailed.detail", defaultValue: "Tap New voice chat to try again.")  // xcstrings
                )
                hint.setImage(UIImage(systemName: "mic.slash.fill"))
                hint.handler = { _, completion in completion() }
                firstSectionItems.insert(hint, at: 0)
            }
            let newSection = CPListSection(items: firstSectionItems)

            // "Recent" section — conversations to continue (label + date only).
            var sections: [CPListSection] = [newSection]
            let recents = (try? await ConversationStore.shared.fetchRecentForPicker(limit: cap)) ?? []
            if !recents.isEmpty {
                let now = Date()
                // Badge visibility spans the WHOLE store, not `recents` — that
                // slice is capped, and the phone answers from every
                // conversation. Failing the fetch degrades to the displayed
                // slice, which is the safe direction: it can only under-report
                // identities and hide the badge, never draw a blank one.
                let allBackends = (try? await ConversationStore.shared.distinctBackends())
                    ?? Set(recents.map(\.backend))
                let showGatewayBadge = RemoteAgentRefMetadata.shouldShowBadges(
                    configured: configuredRefs,
                    conversationBackends: allBackends,
                    customs: customs
                )
                let recentItems: [CPListItem] = recents.map { recent in
                    let item = CPListItem(
                        text: recent.label,
                        detailText: CarPlayConversationLabel.relativeDate(recent.lastActivityAt, now: now)
                    )
                    // Leading gateway badge (multi-gateway only) — color-codes
                    // which agent a thread belongs to where the thread text
                    // itself can't be shown while driving. Unresolvable refs
                    // (deleted custom) just get no image.
                    if showGatewayBadge, let ref = RemoteAgentRef(rawString: recent.backend),
                       let badge = GatewayBadge.image(for: ref, customs: customs) {
                        item.setImage(badge)
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
    private func presentGatewayChooser(
        configured: [RemoteAgentRef],
        current: RemoteAgentRef,
        customs: [CustomGateway]
    ) {
        let items: [CPListItem] = configured.map { ref in
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
            item.handler = { [weak self] _, completion in
                defer { completion() }
                guard let self else { return }
                Task { @MainActor in
                    // SESSION-LOCAL only: re-point THIS drive, never the global
                    // default and never any active-conversation pointer.
                    self.sessionDefaultRefOverride = ref
                    self.interfaceController?.popTemplate(animated: true, completion: nil)
                    self.refreshPicker()
                }
            }
            return item
        }
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
                // Don't churn the list mid-session (it's disabled then anyway).
                guard !service.sessionActive else { return }
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
        let endButton = CPBarButton(title: String(localized: "End")) { [weak service] _ in  // xcstrings
            service?.endFromButton()
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
#endif
