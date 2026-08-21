// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import WatchKit

/// Root Watch surface for Conduck — a LAUNCHPAD (avatar + Ask + Conversations +
/// the watch-disabled state) and the NAV HOST for the capture-in-
/// thread model. Both quick-capture triggers — the in-app "Ask"
/// button and the headless ControlWidget / Action-Button intent — push a
/// (possibly draft) chat THREAD via `WatchRoute.capture(...)` and auto-start
/// recording inside it; there is no transient reply card any more (the reply
/// lands as a bubble in the thread). The two triggers differ ONLY by gateway:
/// Ask = picker (≥2 gateways) → new thread; headless = default gateway →
/// continue-or-new per the session-continuation policy.
struct WatchNoteView: View {
    /// Shared singleton so the two background hops (STT + converse) drive one
    /// state machine, and the conversation thread shares one TTS synthesizer.
    @State private var recordingService = WatchRecordingService.shared
    @State private var conversationViewModel = WatchConversationViewModel()
    @State private var path = NavigationPath()
    /// Drives the gateway picker shown when ≥2 gateways are configured and the
    /// user taps the in-app "Ask" button (always-new conversation + explicit
    /// gateway binding). Single-gateway taps push straight into a new thread.
    @State private var showGatewayChooser = false
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
                // xcstrings
                recordingService.state = .error(
                    message: String(localized: "Conduck is turned off for Apple Watch. Enable it in iPhone Settings.")
                )

            case .directStart:
                clearAskHintForHeadlessEntry()
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
        path = NavigationPath()
        // BROWSE route — never `.capture(...)`: a notification tap opens the
        // thread to READ the reply; auto-starting the mic here would record
        // without intent.
        let route = WatchRoute.thread(id)
        WatchLog.info(.nav, "nav.push", ["route": route.logLabel])
        path.append(route)
    }

    /// In-app "Ask" entry point. ALWAYS starts a NEW conversation (option A) and
    /// lets the user pick its gateway when ≥2 are configured; single / none →
    /// pushes straight into a new thread bound to the only / default gateway.
    /// Distinct from the headless triggers, which continue-or-new per the
    /// session-continuation policy.
    private func beginInAppAsk() {
        // Refuse before the chooser, so the user is never asked to pick a
        // gateway for a capture that cannot start.
        guard !refuseAskIfBusy() else { return }
        let configured = settingsReader.configuredBackendRefs()
        if configured.count >= 2 {
            askGatewayRefs = configured
            showGatewayChooser = true
        } else {
            pushNewCapture(ref: configured.first ?? settingsReader.defaultBackendRef)
        }
    }

    /// Push a new draft thread bound to `ref` and start recording into it.
    ///
    /// THE CHOKE POINT for both in-app Ask paths (single-gateway tap and the
    /// chooser), so the busy check lives here as well as in `beginInAppAsk` —
    /// the chooser can be answered seconds later, by which time a headless turn
    /// may own the machine.
    private func pushNewCapture(ref: String) {
        guard !refuseAskIfBusy() else { return }
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

    /// Display name for a ref string in the Ask chooser. Built-in →
    /// `RemoteAgentBackend.shortDisplayName`; custom → its roster name, truncated
    /// (via `RemoteAgentRefMetadata`).
    ///
    /// The SHORT form: this is a confirmation-dialog button on a watch face, and
    /// a 40-character custom name is what the save cap allows. A row the user
    /// cannot read to the end is a row they cannot tell from the one above it,
    /// which is the entire job of this chooser.
    private func displayName(forRef ref: String) -> String {
        guard let parsed = RemoteAgentRef(rawString: ref) else { return ref }
        return RemoteAgentRefMetadata.shortDisplayName(for: parsed, customs: settingsReader.customGateways)
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
                    .disabled(recordingService.isBusy)

                    if recordingService.isBusy {
                        Group {
                            if recordingService.isCapturing {
                                Text("Recording…")  // xcstrings
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
        // opened) would leave every gateway row dead with only Cancel alive.
        // `pushNewCapture` still refuses a busy pick, which is the authoritative
        // check either way.
        .confirmationDialog(
            "Ask which gateway?",  // xcstrings
            isPresented: $showGatewayChooser,
            titleVisibility: .visible
        ) {
            ForEach(askGatewayRefs, id: \.self) { ref in
                Button(displayName(forRef: ref)) {
                    pushNewCapture(ref: ref)
                }
            }
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

    /// Stable case label for nav breadcrumbs — the case KIND only, never the
    /// associated UUID / capture target.
    var logLabel: String {
        switch self {
        case .conversations: return "conversations"
        case .capture: return "capture"
        case .thread: return "thread"
        case .attachmentText: return "attachmentText"
        }
    }
}
