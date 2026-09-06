// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import WatchKit

/// Root Watch surface for Conduck — a LAUNCHPAD (avatar + Ask + Conversations +
/// the watch-disabled state) and the NAV HOST for the capture-in-
/// thread model. The two quick-capture triggers differ by DESTINATION as well
/// as by gateway.
///
/// Ask opens the DESTINATION CHOOSER on every press — every configured gateway
/// in roster order, then Add to Work — and pushes either a (possibly draft)
/// chat THREAD via `WatchRoute.capture(...)` or the private
/// `WatchRoute.workCapture(...)` screen, auto-starting the recorder inside it;
/// there is no transient reply card any more (a chat reply lands as a bubble in
/// the thread).
///
/// The headless ControlWidget / Action-Button intent resolves the DEFAULT
/// gateway and continues-or-news per the session-continuation policy. It never
/// reaches Work: a trigger with no screen in front of the person must not route
/// a private thought to the desk, nor a desk note to a gateway.
struct WatchNoteView: View {
    /// Shared singleton so the two background hops (STT + converse) drive one
    /// state machine, and the conversation thread shares one TTS synthesizer.
    @State private var recordingService = WatchRecordingService.shared
    @State private var conversationViewModel = WatchConversationViewModel()
    @State private var path = NavigationPath()
    /// Drives the destination chooser the in-app "Ask" button opens on EVERY
    /// press: every configured gateway (always-new conversation + explicit
    /// gateway binding), then Add to Work.
    @State private var showDestinationChooser = false
    /// Snapshot of configured refs backing the Ask chooser, captured ONCE at
    /// tap time in `beginInAppAsk()`. `configuredBackendRefs()` performs a
    /// per-ref Keychain token read — inlining it as the `confirmationDialog`
    /// ForEach data expression re-ran those reads on every body evaluation.
    @State private var askGatewayRefs: [String] = []
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced
    /// Warm-resume safety net for the headless capture trigger — see the
    /// `scenePhase` handler in `body`.
    @Environment(\.scenePhase) private var scenePhase
    private let coordinator = WatchRecordingCoordinator.shared
    /// Survives cold-launch ordering like `WatchRecordingCoordinator`: a tapped
    /// suspended-reply notification stashes its `conversationID` here; this view
    /// drains it into a `.capture(.existing(id))` push (deep-link into the right
    /// thread). Observed so a tap that lands before this view mounts is not lost.
    private let deepLinkCoordinator = WatchReplyDeepLinkCoordinator.shared
    /// Track settings by re-reading on view renders. `WatchSettingsReader` is
    /// `@Observable`, so reads here participate in the observation graph.
    private var settingsReader: WatchSettingsReader { WatchSettingsReader.shared }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                // The root shows the launchpad. A live capture is NOT shown here
                // — it lives in the pushed thread (`.capture` route). Only a
                // root-level error that surfaced with no thread on the stack
                // (e.g. the watch-disabled guard) takes over the root.
                if case .error(let message) = recordingService.state, path.isEmpty {
                    errorView(message: message)
                } else {
                    launchpadView
                }
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: WatchRoute.self) { route in
                // NOTE: the `nav.push` breadcrumb is emitted at the imperative
                // push sites (`drainCoordinatorIfNeeded` / deep-link / Ask),
                // NOT here — this builder closure re-runs on every body re-eval
                // while a value is on the stack, so logging here spams one line
                // per render pass instead of one per actual push.
                switch route {
                case .conversations:
                    WatchConversationListView(viewModel: conversationViewModel)
                case .capture(let target, let nonce):
                    WatchConversationThreadView(
                        captureTarget: target,
                        requestID: nonce,
                        viewModel: conversationViewModel
                    )
                case .thread(let id):
                    WatchConversationThreadView(conversationID: id, viewModel: conversationViewModel)
                case .attachmentText(let conversationID, let messageID, let attachmentID):
                    WatchAttachmentTextView(
                        conversationID: conversationID,
                        messageID: messageID,
                        attachmentID: attachmentID
                    )
                case .workCapture(let nonce):
                    WatchWorkCaptureView(requestID: nonce, recordingService: recordingService)
                }
            }
        }
        .onAppear {
            recordingService.restoreInFlightStateIfNeeded()
            drainDeepLinkIfNeeded()
            drainCoordinatorIfNeeded()
        }
        .onChange(of: coordinator.pendingStart) { _, _ in
            drainCoordinatorIfNeeded()
        }
        .onChange(of: scenePhase) { _, newPhase in
            // Belt-and-suspenders: a `.foreground(.immediate)` Action-Button
            // intent can flip `coordinator.pendingStart` while the app is
            // suspended and `.onChange(of: pendingStart)` isn't observing. The
            // `.active` edge on resume re-drains it. `consumePending()` is
            // atomic, so this never double-fires a press already handled by
            // `.onAppear` or the `pendingStart` observer.
            if newPhase == .active { drainCoordinatorIfNeeded() }
        }
        .onChange(of: deepLinkCoordinator.pendingConversationID) { _, _ in
            drainDeepLinkIfNeeded()
        }
    }

    // MARK: - Trigger draining

    /// Consume any external headless trigger (Action Button / ControlWidget
    /// intent) that arrived before this view was mounted. Safe to call from both
    /// `.onAppear` and `.onChange` because `consumePending()` is atomic.
    ///
    /// Resolves the capture TARGET at trigger time (continue the active thread
    /// within the session-continuation TTL, else a new one bound to the default
    /// gateway) so a pointer / default-gateway change mid-recording cannot
    /// reroute the turn, then pushes `.capture(target)` and auto-records inside
    /// the (possibly draft) thread.
    ///
    /// The resolution can also be a REFUSAL — the default gateway is not one
    /// this Watch can send to — in which case nothing is pushed and nothing is
    /// recorded. The refusal arrives as a value, so the ORDER stays here where
    /// it belongs: a live turn and the master switch both outrank it.
    private func drainCoordinatorIfNeeded() {
        guard coordinator.consumePending() else { return }
        // Resolve existing-vs-new + the gateway ref NOW (trigger time), incl.
        // the default-gateway re-check (a TTL-fresh pointer continues only a
        // thread still bound to the CURRENT default). Async because the
        // re-check reads the thread's persisted backend from the store. The
        // routing verdict itself is pure (`HeadlessDrainDecision`, unit-
        // tested) — this method only executes its side effects.
        Task { @MainActor in
            let resolution = await recordingService.resolveHeadlessCaptureTarget()
            // A refusal has no target. `.new` with an empty ref can never
            // produce `.directStart` (that arm needs `.existing` matching the
            // displayed thread), so passing it asks the ladder only the
            // question we actually need from it: does a LIVE turn, or the
            // master switch, outrank this press? Reusing `HeadlessDrainDecision`
            // rather than re-testing `state` inline keeps one copy of the
            // ordering rule — two copies would drift.
            let verdict = HeadlessDrainDecision.make(
                target: resolution.captureTarget ?? .new(backendRef: ""),
                displayedConversationID: conversationViewModel.selectedConversationID,
                state: recordingService.state,
                watchEnabled: settingsReader.isWatchEnabled()
            )
            WatchLog.note(.capture, "actionbtn.drain", [
                "state": recordingService.state.phaseKind,
                "hasDisplayed": conversationViewModel.selectedConversationID != nil
            ])
            if case .refused(let message) = resolution {
                switch verdict {
                case .refuse:
                    // A genuinely live turn still owns the machine. Same haptic
                    // + log as the ordinary refusal — the gateway problem waits
                    // for the next press.
                    WKInterfaceDevice.current().play(.failure)
                    WatchLog.note(.capture, "actionbtn.refused", ["state": recordingService.state.phaseKind])

                case .disabledError:
                    // The master switch outranks the gateway: with Conduck
                    // turned off for Watch, "pick a different AI" is not the
                    // user's next step.
                    //
                    // A root error takes the root over, so an Ask chooser left
                    // open under it would be a live sheet in front of a message
                    // the person cannot read — every arm below that writes one,
                    // or replaces the navigation, drops the sheet first.
                    showDestinationChooser = false
                    // xcstrings
                    recordingService.state = .error(
                        message: String(localized: "Conduck is turned off for Apple Watch. Enable it in iPhone Settings.")
                    )

                case .directStart, .pushAndStart:
                    // The only two arms that would have armed the mic. Refuse
                    // instead: no route push, no draft thread, nothing
                    // recorded. The log carries the phase kind only — never the
                    // ref, the URL or anything token-shaped.
                    WKInterfaceDevice.current().play(.failure)
                    WatchLog.note(.capture, "actionbtn.gatewayRefused", ["state": recordingService.state.phaseKind])
                    showDestinationChooser = false
                    recordingService.state = .error(message: message)
                }
                return
            }
            guard let target = resolution.captureTarget else { return }
            switch verdict {
            case .refuse:
                // A genuinely LIVE turn (arming / recording / uploading /
                // waiting) is never interrupted. Surface the drop — foreground
                // banners are suppressed, so without the haptic a swallowed
                // press is indistinguishable from a dead button. The haptic
                // lives HERE, at the trigger level, NOT in `startCapture`'s
                // idle guard: that guard also fires on the healthy
                // belt-and-suspenders duplicate below and would buzz on every
                // normal capture start.
                WKInterfaceDevice.current().play(.failure)
                WatchLog.note(.capture, "actionbtn.refused", ["state": recordingService.state.phaseKind])

            case .disabledError:
                // "Enable on Watch" master switch. When the iPhone has
                // turned the Watch surface off, suppress the record action and
                // surface a brief disabled state instead of starting a recording.
                //
                // ACCEPTED V1 LIMITATION (reviewer-confirmed): with the switch
                // OFF, a ControlWidget press still COLD-LAUNCHES the app to this
                // disabled state — no public API lets a companion truly suppress
                // a ControlWidget action, so gating the action here (not the
                // widget) is the correct V1 behavior. The app opens, shows the
                // disabled message, does nothing else.
                showDestinationChooser = false
                // xcstrings
                recordingService.state = .error(
                    message: String(localized: "Conduck is turned off for Apple Watch. Enable it in iPhone Settings.")
                )

            case .directStart:
                clearAskHintForHeadlessEntry()
                // This press takes the machine, so a chooser opened while it
                // was idle has nothing left to pick.
                showDestinationChooser = false
                // NO-REMOUNT FIX: the resolved target is the thread ALREADY on
                // screen — re-pushing the identical `.capture(.existing(id))`
                // route is a SwiftUI no-op (the destination view is reused, so
                // its one-shot auto-start `.task` never re-runs and the app
                // "just shows the chat" without recording; reproduces when
                // Conduck was the last app, so the active-conversation pointer
                // is fresh and resolves to the very thread you're viewing).
                // Start the capture DIRECTLY on the mounted thread instead:
                // preserves its scroll / history / draft, no reload flicker.
                // `selectedConversationID` is the live displayed-thread signal
                // (set by the thread's `.task`, cleared on its `.onDisappear`)
                // and also covers a `.new` draft that has already adopted its
                // minted id.
                if case .existing(let id) = target {
                    WatchLog.note(.capture, "actionbtn.directstart", ["id": WatchLog.shortID(id)])
                }
                // No route is pushed here, so no draft can adopt anything — a
                // fresh id simply gives the turn an owner.
                recordingService.startCapture(boundTo: target, requestID: UUID())

            case .pushAndStart:
                clearAskHintForHeadlessEntry()
                showDestinationChooser = false
                path = NavigationPath()
                // Fresh nonce → a distinct route value every trigger, so the
                // NavigationStack ALWAYS remounts a fresh thread (its auto-start
                // `.task` re-runs) even on a rapid re-press that would otherwise
                // reset-then-re-append a value-equal route (the "nothing happens"
                // no-remount bug).
                let nonce = UUID()
                let route = WatchRoute.capture(target, nonce: nonce)
                WatchLog.info(.nav, "nav.push", ["route": route.logLabel])
                path.append(route)
                // Belt-and-suspenders: drive the capture from the SERVICE too
                // (spec: Watch recording is service-driven, independent of
                // navigation), so the mic is deterministic even if the pushed
                // view's `.task` is delayed/cancelled by a racing re-trigger.
                // The pushed thread starts the SAME request id, so its
                // redundant `.task` call reports `.alreadyRunning` rather than a
                // refusal — which is what lets that view treat a genuine
                // refusal as a reason to dismiss itself.
                recordingService.startCapture(boundTo: target, requestID: nonce)
            }
        }
    }

    /// AUTHORITATIVE no-silent-reroute guarantee: a headless capture must
    /// NEVER consume a pending in-app "Ask" hint left behind by an abandoned
    /// in-app Ask. The only incorrect consumer is a headless turn, so we clear
    /// at the headless entry — on every PROCEED verdict, and only there (a
    /// refused press must not touch a live Ask's hint). Immune to every
    /// STT-stage error path.
    private func clearAskHintForHeadlessEntry() {
        settingsReader.clearPendingInAppNewConversationBackend()
    }

    /// Drain a tapped suspended-reply notification into a deep-link push. Opens
    /// the EXISTING thread the reply belongs to (browse, no auto-capture). Atomic
    /// consume so a tap that arrives before mount (or twice) deep-links once.
    private func drainDeepLinkIfNeeded() {
        guard let id = deepLinkCoordinator.consumePending() else { return }
        // Don't yank the user out of a live capture — defer is unnecessary because
        // the notification only fires for a delivered reply (no capture in flight
        // for that turn), but guard anyway so a concurrent capture is never lost.
        guard !recordingService.isCapturing else { return }
        // Notification-tap auto-speak: the wrist was down at delivery (else
        // `willPresent` returned `[]` and no banner existed), and the user
        // EXPLICITLY tapped the reply — so when the toggle is on, the thread
        // speaks the latest agent message on open. Source-independent by
        // design (the tap is the intent signal). App is `.active` by
        // definition here — the tap just foregrounded it. Armed BEFORE the
        // route push so the thread's load-completion hook finds it pending.
        if WatchSettingsReader.shared.readRepliesAloud() {
            AutoSpeakMailbox.shared.request(id)
        }
        // An accepted deep link replaces the root's navigation: the chooser
        // goes with it rather than reopening over the thread it pushed.
        showDestinationChooser = false
        path = NavigationPath()
        // BROWSE route — never `.capture(...)`: a notification tap opens the
        // thread to READ the reply; auto-starting the mic here would record
        // without intent.
        let route = WatchRoute.thread(id)
        WatchLog.info(.nav, "nav.push", ["route": route.logLabel])
        path.append(route)
    }

    /// In-app "Ask" entry point. Opens the destination chooser on EVERY press —
    /// every configured gateway in roster order, then Add to Work — so the desk
    /// is always offered beside the gateways and no press silently assumes one.
    /// A gateway row starts a NEW conversation bound to that gateway; the Work
    /// row starts a private capture that reaches no gateway. Headless triggers
    /// never come here.
    private func beginInAppAsk() {
        // Refuse before the chooser, so the user is never asked to pick a
        // destination for a capture that cannot start.
        guard !refuseAskIfBusy() else { return }
        askGatewayRefs = settingsReader.configuredBackendRefs()
        showDestinationChooser = true
    }

    /// Push a new draft thread bound to `ref` and start recording into it.
    ///
    /// The choke point for every gateway row, so the busy check lives here as
    /// well as in `beginInAppAsk` — the chooser can be answered seconds later,
    /// by which time a headless turn may own the machine.
    private func pushNewCapture(ref: String) {
        guard !refuseAskIfBusy() else { return }
        // The master switch is read when the launchpad is DRAWN, and this row
        // can be picked after the phone has turned the wrist off. Refusing here
        // pushes nothing, starts nothing and writes no hint.
        guard settingsReader.isWatchEnabled() else {
            WatchLog.note(.capture, "ask.disabled")
            return
        }
        let target = WatchCaptureTarget.new(backendRef: ref)
        let nonce = UUID()
        let route = WatchRoute.capture(target, nonce: nonce)
        WatchLog.info(.nav, "nav.push", ["route": route.logLabel])
        path.append(route)
        // Start at the PUSH SITE, mirroring the headless `.pushAndStart` arm.
        // The check above and this start are both synchronous with no `await`
        // between them, so nothing can occupy the machine in the gap; leaving
        // the start to the pushed view's `.task` reopens exactly that gap (an
        // idle-edge deferred drain slipping in, and the draft stranded on a
        // spinner). The view starts the same request id and gets
        // `.alreadyRunning`.
        recordingService.startCapture(boundTo: target, requestID: nonce)
    }

    /// In-app "Add to Work" entry point — a private voice capture that lands on
    /// the Work desk and touches no gateway, no conversation and no reply.
    ///
    /// Reached ONLY from the destination chooser's Add to Work row: A PER-PRESS
    /// PICK, NEVER A MODE. There is no last-destination preference to leave
    /// switched on, and `startWorkCapture` stamps `.work` and clears the Ask
    /// hint and every conversation pin — so nothing from an earlier gateway
    /// press can ride along into the desk.
    ///
    /// Starts at the PUSH SITE for the same reason `pushNewCapture` does — the
    /// checks and the start are synchronous with no `await` between them, so
    /// nothing can occupy the machine in the gap. The pushed view starts
    /// nothing: it reads the service and renders it — including a capacity
    /// refusal, which is why the start's return value is deliberately ignored.
    private func beginWorkCapture() {
        guard !refuseAskIfBusy() else { return }
        // Same re-check as the gateway rows, for the same reason: the chooser
        // outlives the draw that read the switch.
        guard settingsReader.isWatchEnabled() else {
            WatchLog.note(.capture, "ask.disabled")
            return
        }
        let nonce = UUID()
        let route = WatchRoute.workCapture(nonce: nonce)
        WatchLog.info(.nav, "nav.push", ["route": route.logLabel])
        path.append(route)
        recordingService.startWorkCapture(requestID: nonce)
    }

    /// Refuse an in-app Ask while another turn owns the state machine, matching
    /// the headless trigger's own ordering rule — `isBusy` is exactly
    /// `HeadlessDrainDecision`'s refuse set, so the Action Button and the Ask
    /// button now refuse under identical conditions.
    ///
    /// Refusing at the TRIGGER rather than letting the draft cope is what keeps
    /// the fix out of the pushed view: `.pushAndStart` deliberately starts one
    /// capture twice, so "the draft saw a refusal" is not by itself a defect
    /// signal. No refused draft is ever pushed from here.
    private func refuseAskIfBusy() -> Bool {
        guard recordingService.isBusy else { return false }
        WatchLog.note(.capture, "ask.refused", ["state": recordingService.state.phaseKind])
        return true
    }

    /// Display name for a ref string in the Ask chooser — `WatchGatewayLabel`'s
    /// short form, disambiguated when another gateway shortens to the same
    /// string.
    ///
    /// A SHORT form because this is a confirmation-dialog button on a watch
    /// face and a 40-character custom name is what the save cap allows; a
    /// DISAMBIGUATED one because a row the user cannot tell from the one above
    /// it defeats the entire job of this chooser.
    private func displayName(forRef ref: String) -> String {
        guard let parsed = RemoteAgentRef(rawString: ref) else { return ref }
        return WatchGatewayLabel.visible(for: parsed, customs: settingsReader.customGateways)
    }

    /// The same row's name in full, for VoiceOver. A cut label is a reading
    /// problem on a watch face; spoken aloud there is no face to run out of, so
    /// the name is never cut for the ear.
    private func spokenName(forRef ref: String) -> String {
        guard let parsed = RemoteAgentRef(rawString: ref) else { return ref }
        return WatchGatewayLabel.spoken(for: parsed, customs: settingsReader.customGateways)
    }

    // MARK: - Launchpad

    private var launchpadView: some View {
        VStack(spacing: 12) {
            if isLuminanceReduced {
                // Always On Display: dim brand mark, no waveform/mic glyph — a voice
                // metaphor on an idle screen reads as "secretly listening" on a
                // privacy-first product. Low opacity + grayscale keeps OLED draw down.
                Image("conduck-avatar")
                    .resizable()
                    .scaledToFit()
                    .frame(height: 30)
                    .clipShape(Circle())
                    .grayscale(1.0)
                    .opacity(0.5)
                // "Raise to ask" only when the feature is on — asking won't work when
                // the Watch is disabled in iPhone Settings, so the dim mark stands alone.
                if settingsReader.isWatchEnabled() {
                    Text("Raise to ask")  // xcstrings
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Image("conduck-avatar")
                    .resizable()
                    .scaledToFit()
                    .frame(height: 56)
                    .clipShape(Circle())

                if settingsReader.isWatchEnabled() {
                    Button {
                        beginInAppAsk()
                    } label: {
                        Label("Ask", systemImage: "mic")  // xcstrings
                            .font(.headline)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                    // Legible BEFORE the tap. A haptic on the tap was the other
                    // option and is what the headless trigger uses, but that
                    // trigger has no on-screen affordance to grey out — here a
                    // dead-looking button with a reason under it beats a buzz
                    // with none. (A disabled Button never receives the tap, so
                    // the two cannot be combined.)
                    // `path.isEmpty` on both: busy UI belongs to the pushed
                    // thread. `pushNewCapture` appends the route before arming
                    // the recorder in the same transaction, so without the nav
                    // guard the launchpad re-renders as "Recording…" during the
                    // dialog-dismiss + push animations — a visible flash.
                    .disabled(recordingService.isBusy && path.isEmpty)

                    if recordingService.isBusy && path.isEmpty {
                        Group {
                            if recordingService.isCapturing {
                                Text("Recording…")  // xcstrings
                            } else if recordingService.captureDestination == .work {
                                // The Work screen's back button is enabled the
                                // moment the mic is off, so the launchpad is
                                // reachable mid-save. Calling a private save
                                // "answering your last question" is the one
                                // sentence this lane must never show.
                                Text(String(localized: LocalizedStringResource(
                                    "watch.work.capture.saving",
                                    defaultValue: "Saving to Work…"
                                )))
                            } else {
                                Text("Still answering your last question.")  // xcstrings
                            }
                        }
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 6)
                    }
                } else {
                    Text("Turned off for Apple Watch. Enable it in iPhone Settings.")  // xcstrings
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 6)
                }

                NavigationLink(value: WatchRoute.conversations) {
                    Label("Conversations", systemImage: "bubble.left.and.bubble.right")  // xcstrings
                        .font(.caption)
                }
                .buttonStyle(.bordered)
            }
        }
        // Deliberately NOT on the Ask button: that button carries
        // `.disabled(isBusy)`, and `isEnabled` propagates through the
        // environment into presented content — so an Action-Button press while
        // this chooser was open (accepted, because the machine was idle when it
        // opened) would leave every destination row dead with only Cancel
        // alive. `pushNewCapture` and `beginWorkCapture` each refuse a busy
        // pick, which is the authoritative check either way.
        .confirmationDialog(
            String(localized: LocalizedStringResource(
                "watch.ask.destination.title",
                defaultValue: "Where to?"
            )),
            isPresented: $showDestinationChooser,
            titleVisibility: .visible
        ) {
            ForEach(WatchAskDestinationRows.rows(configured: askGatewayRefs), id: \.self) { row in
                switch row {
                case .gateway(let ref):
                    Button(displayName(forRef: ref)) {
                        pushNewCapture(ref: ref)
                    }
                    // The visible label is already distinct from every other
                    // row's; this hands the ear the name in full on top of
                    // that, so a long custom name is not chosen by its first
                    // fifteen characters.
                    .accessibilityLabel(spokenName(forRef: ref))
                case .work:
                    Button(String(localized: LocalizedStringResource(
                        "watch.ask.destination.work",
                        defaultValue: "Add to Work"
                    ))) {
                        beginWorkCapture()
                    }
                }
            }
        } message: {
            if WatchAskDestinationRows.showsNoAILine(configured: askGatewayRefs) {
                Text(String(localized: LocalizedStringResource(
                    "watch.ask.destination.noAI",
                    defaultValue: "No personal AI available."
                )))
            }
        }
        // The switch is read at DRAW time, and this sheet outlives the draw:
        // a phone that turns the wrist off while it is open must not leave a
        // live chooser in front of a surface that is now off.
        .onChange(of: settingsReader.isWatchEnabled()) { _, enabled in
            if !enabled { showDestinationChooser = false }
        }
    }

    // MARK: - Error State (root-level only)

    /// Root error surface — shown only when an error surfaced with no thread on
    /// the nav stack (e.g. the watch-disabled guard). Capture / send errors that
    /// occur inside a pushed thread surface there as an inline banner instead.
    private func errorView(message: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title3)
                .foregroundStyle(.orange)

            Text(message)
                .font(.caption)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            Button {
                recordingService.retry()
            } label: {
                // "Try Again" only when preserved audio exists to re-run —
                // every converse-stage failure has none (STT success deletes
                // the file), where `retry()` just resets to idle. Label that
                // honestly as a dismiss so the button never lies.
                if recordingService.canRetry {
                    Label("Try Again", systemImage: "arrow.clockwise")
                        .font(.caption)
                } else {
                    Label(String(localized: LocalizedStringResource(
                        "watch.error.dismiss",
                        defaultValue: "Dismiss"
                    )), systemImage: "xmark")  // xcstrings: hardening
                        .font(.caption)
                }
            }
            .buttonStyle(.bordered)
        }
    }
}

/// Navigation routes from the Watch root.
enum WatchRoute: Hashable {
    case conversations
    /// A (possibly draft) capture-first thread pushed from the root. `.existing`
    /// continues a thread; `.new` is a draft shell minted lazily at the first
    /// transcript. Auto-starts recording inside `WatchConversationThreadView`.
    /// The `nonce` gives every push a UNIQUE route identity: `WatchCaptureTarget`
    /// is value-equal (two `.new("hermes")` hash the same), so without it a
    /// re-push of the same target is a NavigationStack no-op — the destination
    /// view is reused, its one-shot auto-start `.task` never re-runs, and
    /// GigaAction "does nothing" (esp. when two rapid Action-Button presses race
    /// the `path` reset). The nonce forces a fresh remount on every trigger.
    case capture(WatchCaptureTarget, nonce: UUID)
    /// BROWSE an existing thread from the root (suspended-reply notification
    /// deep-link) — no auto-capture, unlike `.capture(.existing(...))`.
    case thread(UUID)
    /// View a locally-synced text/code attachment full-screen (watchOS has no
    /// QuickLook). IDs ONLY — never a filename or content in the route value
    /// the viewer loads the decoded text from the store by id.
    case attachmentText(conversationID: UUID, messageID: UUID, attachmentID: UUID)
    /// A private voice capture bound for the Work desk. Carries NO capture
    /// target: a Work capture has no conversation and no gateway, which is the
    /// structural reason it can never be confused with `.capture` — the two are
    /// distinct route cases holding distinct payloads, so no equality or hash
    /// collapse can route one into the other's destination. The `nonce` plays
    /// the same role it does there: a unique route identity per tap, so a
    /// second Add to Work pick always remounts a fresh screen instead of
    /// re-presenting the previous capture's terminal line.
    case workCapture(nonce: UUID)

    /// Stable case label for nav breadcrumbs — the case KIND only, never the
    /// associated UUID / capture target.
    var logLabel: String {
        switch self {
        case .conversations: return "conversations"
        case .capture: return "capture"
        case .thread: return "thread"
        case .attachmentText: return "attachmentText"
        case .workCapture: return "workCapture"
        }
    }
}

/// The rows the Ask destination chooser offers, as a pure value so the truth
/// table is testable without a watch face: every configured gateway in roster
/// order, then Add to Work — always present, always last. Ask is the AI
/// button, so the AI rows lead; Work last is a stable RELATIONSHIP to them
/// rather than a fixed position.
nonisolated enum WatchAskDestinationRows {
    enum Row: Hashable {
        case gateway(String)
        case work
    }

    static func rows(configured: [String]) -> [Row] {
        configured.map(Row.gateway) + [.work]
    }

    /// An empty roster is explained in ONE line rather than hidden behind a
    /// thread that cannot send. "Available", not "set up": an empty roster is
    /// also what a locked keychain or an un-hydrated wrist reads (I3), and the
    /// wrist is a working private recorder either way.
    static func showsNoAILine(configured: [String]) -> Bool {
        configured.isEmpty
    }
}

/// The gateway name the WRIST shows where the person is picking a destination
/// or checking the one a live capture is bound to.
///
/// `RemoteAgentRefMetadata.shortDisplayName` is a HEAD cut at
/// `shortDisplayNameLimit`, and it is the right policy for the surfaces its
/// budget was derived from (the in-thread error banner, a notification title,
/// a sentence read aloud at the wheel). It is the wrong ANSWER for a choice:
/// two customs whose names agree over their first 15 characters ("Frankfurt
/// production alpha" / "Frankfurt production beta") render one identical
/// label, so the chooser stops being a choice and the recording caption names
/// a destination the person cannot check.
///
/// The shared policy is left exactly as it is — every other surface keeps it.
/// The fix is local and small: when a name shortens to the same string as
/// another gateway's, show it from where the names DIVERGE instead, behind a
/// leading ellipsis ("…alpha" / "…beta"). Names can only collide this way when
/// their heads are identical, so the head is the half that carries no
/// information for this decision. The leading ellipsis costs one character
/// beyond the shared budget, which neither of these two surfaces spends on the
/// 18-character sentence frame the budget was derived for.
///
/// VoiceOver is given `RemoteAgentRefMetadata.displayName` — the full,
/// untruncated name — at both call sites, so the SPOKEN label is never the
/// ambiguous one even where the visible label had to be cut.
///
/// Main-actor isolated (unlike the row builder beside it, which is pure): it
/// reads the roster through `RemoteAgentRefMetadata`, which is.
enum WatchGatewayLabel {

    /// The label to draw: the WHOLE roster resolved together, and this
    /// gateway's answer handed back.
    ///
    /// Resolved as a set, never one name at a time, and the set is the whole
    /// roster rather than one colliding group. A label computed against only
    /// the names it collides with can land on a string another row ALREADY
    /// shows — a custom literally named "…alpha" beside a "Frankfurt production
    /// alpha" that shortens to exactly that — and two rows that read alike are
    /// one row as far as the person tapping is concerned.
    static func visible(for ref: RemoteAgentRef, customs: [CustomGateway]) -> String {
        let short = RemoteAgentRefMetadata.shortDisplayName(for: ref, customs: customs)
        // A built-in is not on the custom roster: its name is compiled in,
        // short, and nothing here may reshape it.
        guard let index = customs.firstIndex(where: { $0.ref == ref }) else { return short }
        return rosterLabels(customs: customs)[index]
    }

    /// One label per gateway, in ROSTER order, unique AS A SET — so every row
    /// resolves against the same list in the same order and the labels are
    /// stable across rows and redraws.
    ///
    /// Two passes, and both are load-bearing.
    ///
    /// **Divergence.** Each name the shortener CUT opens at the EARLIEST
    /// character that tells it from any name it collides with, so the label
    /// keeps every character that carries a difference rather than only the
    /// last one. "Frankfurt production alpha one" diverges from "…alpha two" at
    /// "one" but from "Frankfurt production one" at "alpha", and opening at
    /// "alpha" is exactly what stops it reading "…one" like that third name
    /// does.
    ///
    /// **Uniqueness, over the COMPLETE roster.** The untouched short forms are
    /// checked with the disambiguated ones, because a name the shortener never
    /// cut can still read exactly like a label the first pass produced, and two
    /// unnamed customs can share one monogram fallback. Residual duplicates —
    /// gateways named identically, divergent tails that truncate to the same
    /// string, a name that is a strict prefix of the ones it collides with —
    /// take a bounded ordinal by roster position: the only honest answer left
    /// is which of them this row is. Bounded by construction, since each
    /// ordinal is tried at most once per row.
    private static func rosterLabels(customs: [CustomGateway]) -> [String] {
        let refs = customs.map(\.ref)
        let names = refs.map { spoken(for: $0, customs: customs) }
        var labels = refs.indices.map { index -> String in
            let short = RemoteAgentRefMetadata.shortDisplayName(for: refs[index], customs: customs)
            // Only a name the shortener actually CUT can collide by cutting. A
            // short custom name and the monogram/generic fallback an unnamed
            // custom resolves to are each their own answer already — the
            // uniqueness pass below is what still holds them to being
            // DISTINGUISHABLE answers.
            guard short != names[index],
                  short == RemoteAgentRefMetadata.truncatedToShortLimit(names[index])
            else { return short }
            let colliders = names.indices.filter {
                $0 != index && RemoteAgentRefMetadata.truncatedToShortLimit(names[$0]) == short
            }
            guard !colliders.isEmpty else { return short }
            let divergence = colliders.map { commonPrefixCount(names[index], names[$0]) }.min() ?? 0
            let tail = String(names[index].dropFirst(divergence))
            // A name that is a strict prefix of every name it collides with has
            // no divergent tail of its own; the shared form is still the honest
            // answer for it, and the ordinal below tells it from the rest.
            guard !tail.isEmpty else { return short }
            return "…" + RemoteAgentRefMetadata.truncatedToShortLimit(tail)
        }
        var taken: Set<String> = []
        for index in labels.indices {
            let base = labels[index]
            var label = base
            var ordinal = 2
            while taken.contains(label) {
                label = numbered(base, ordinal)
                ordinal += 1
            }
            taken.insert(label)
            labels[index] = label
        }
        return labels
    }

    /// `label` with an ordinal appended, cut so the result still fits the shared
    /// budget plus the one leading ellipsis a disambiguated label is allowed.
    private static func numbered(_ label: String, _ ordinal: Int) -> String {
        let suffix = " \(ordinal)"
        let budget = RemoteAgentRefMetadata.shortDisplayNameLimit + 1 - suffix.count
        guard label.count > budget else { return label + suffix }
        return String(label.prefix(budget)) + suffix
    }

    /// The full, untruncated name — what VoiceOver reads.
    static func spoken(for ref: RemoteAgentRef, customs: [CustomGateway]) -> String {
        RemoteAgentRefMetadata.displayName(for: ref, customs: customs)
    }

    private static func commonPrefixCount(_ lhs: String, _ rhs: String) -> Int {
        zip(lhs, rhs).prefix { $0 == $1 }.count
    }
}
