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
// is active. No-gateway state = a single "Set up your personal AI on iPhone
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
        // silently; the in-flight converse still completes + syncs but is not
        // spoken (the unsolicited-audio guard). The service deactivates audio
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
    private func startSession(service: CarPlayRecordingService, conversationID: UUID?) {
        guard case .idle = service.state, !service.sessionActive else { return }
        Task { @MainActor in
            // Capture the effective CarPlay ref (session-local override ?? the
            // iPhone's device-local default) and stash it on the service so a
            // NEW-conversation mint uses it instead of reading the global default.
            // Existing-conversation routing (reads `Conversation.backend`) ignores
            // this. Captured at session start so a chooser change mid-session can't
            // retarget a live session.
            let defaultRef = await self.effectiveCarPlayRef()
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
                service?.beginSession(conversationID: conversationID, defaultRef: defaultRef)
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
                    Self.log.error("presentTemplate(voice) failed: \(error?.localizedDescription ?? "unknown", privacy: .public)")
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
                    Self.log.error("dismissTemplate(voice) failed: \(error?.localizedDescription ?? "unknown", privacy: .public)")
                }
                self?.recordingService?.deactivateAudioSession()
            }
        }
    }

    // MARK: - Picker construction + refresh

    /// Rebuild the picker sections in place. Off the main actor for the store
    /// read, then mutate the template on the main actor.
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

        let cap = CarPlayConversationLabel.recentCap(
            maximumItemCount: CPListTemplate.maximumItemCount
        )

        Task { @MainActor in
            // No-gateway → a single setup-hint row (no New voice chat: there's
            // nothing to talk to yet). Multi-gateway: the gate is "is ANY
            // gateway configured?" so CarPlay offers a new chat as soon as ≥1
            // backend is set up; the per-conversation send routing already
            // binds each chat to its own backend.
            let configuredRefs = await SettingsManager.shared.configuredRemoteAgentRefs()
            guard !configuredRefs.isEmpty else {
                // xcstrings
                let item = CPListItem(
                    text: String(localized: "Set up your personal AI on iPhone first."),
                    detailText: nil
                )
                item.setImage(UIImage(systemName: "iphone"))
                template.leadingNavigationBarButtons = []
                template.updateSections([CPListSection(items: [item])])
                return
            }

            // Custom roster (for labeling built-in vs custom refs in the
            // switcher + chooser). Fetched once per refresh.
            let customs = await SettingsManager.shared.customGateways()

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
                let title = RemoteAgentRefMetadata.displayName(for: current, customs: customs)
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
            let newSection = CPListSection(items: [newItem])

            // "Recent" section — conversations to continue (label + date only).
            var sections: [CPListSection] = [newSection]
            let recents = (try? await ConversationStore.shared.fetchRecentForPicker(limit: cap)) ?? []
            if !recents.isEmpty {
                let now = Date()
                let showGatewayBadge = configuredRefs.count >= 2
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
                text: RemoteAgentRefMetadata.displayName(for: ref, customs: customs),
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
            title: String(localized: "Choose gateway"),  // xcstrings
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
