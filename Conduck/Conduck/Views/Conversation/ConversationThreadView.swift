// Conduck
// ConversationThreadView.swift
//
// The iOS chat-bubble thread (NET-NEW: flat text ≠ chat
// bubbles). Renders one conversation's messages (createdAt-ascending) from
// `ConversationDetailViewModel`, plus the EPHEMERAL in-flight UX:
//   - optimistic user bubble (already in the store via `sendUserTurn`)
//   - staged "thinking" indicator + live elapsed timer (TimelineView)
//   - Cancel affordance (cancels the real URLSessionTask)
//   - smart scroll: auto-scroll only when pinned to bottom; otherwise a
//     floating "↓ New reply below" badge that snaps to bottom on tap
//
// Markdown: agent bubbles render via Textual's `StructuredText(...)`,
// which keeps SwiftUI's `Text` pipeline but renders the whole reply as one
// selectable surface — so drag-selection spans paragraphs/list items/headings
// (fenced code blocks keep their own selection context). User bubbles are
// plain `Text` (no Markdown in STT output).
//
// TTS: per-message "Speak aloud" routed through `ReplyVoice` (the cloud
// TTS boundary — active engine + Apple fallback), GATED to foreground-active
// (never auto-speak; user-initiated only in V1.0). One exception (iOS ONLY,
// compile-gated): a tapped agent-REPLY notification may auto-speak the latest
// agent reply via `AutoSpeakMailbox` — still tap-initiated, and routed
// through the SAME `speaker` so the bubble shows the playing state, pause
// works, and the thread keeps a single audio owner. macOS hosts of this view
// never consume the coordinator.

import SwiftUI
import Textual
// SwiftUI's `.quickLookPreview` lives in the SwiftUI×QuickLook cross-import
// overlay — both imports are required for the modifier to resolve.
import QuickLook
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif

struct ConversationThreadView: View {
    /// Parent-owned VM (iOS `ContentView.detailVM` / macOS the coordinator's
    /// registry lanes — `quickViewModel`/`windowViewModel`). A plain `let`,
    /// NOT `@State`:
    /// `@State` is initialized once per view identity and ignores a swapped-in
    /// instance, which froze the thread on whichever conversation was bound
    /// first (the launch-resolved one) regardless of the tapped row. The VM is
    /// `@Observable`, so reads in `body` still drive re-renders; callers append
    /// `.id(viewModel.conversationID)` so a thread switch gets fresh view-local
    /// scroll state.
    let viewModel: ConversationDetailViewModel

    /// Optional cap on the message-column width. When set (macOS unified window
    /// passes `Layout.chatContentWidth`), the `ScrollView` stays full-bleed — so
    /// the macOS overlay scrollbar sits at the window edge — while the message
    /// content is capped + centered inside it. `nil` (iPhone / iPad / popover)
    /// leaves the column full-width, unchanged.
    var contentMaxWidth: CGFloat? = nil

    /// The empty-thread mascot pose, owned by the host view (one per empty
    /// surface, refreshed on "new conversation"). Sourced from the host — NOT a
    /// fresh per-VM draw — so the host empty state and the empty thread agree on
    /// the same pose and don't flicker A→B during the launch render sequence
    /// (host start-empty → resolved empty conversation thread).
    let emptyMascot: String

    /// Whether the user is pinned to the bottom of the scroll. When true, a
    /// new reply auto-scrolls into view; when false (scrolled up), the
    /// floating "New reply below" badge appears instead.
    @State private var isAtBottom = true
    /// True when a reply landed while the user was scrolled up — drives the
    /// floating badge.
    @State private var hasUnseenReply = false

    /// USER rows currently inside THIS view's viewport (fed by
    /// `onScrollVisibilityChange` on each bubble). Drives the toast rule —
    /// the transient banner is suppressed while the failed row itself is
    /// visible. Tracks ALL user rows, not just failed ones: visibility events
    /// fire on viewport CROSSINGS, so a bubble that fails in place while
    /// already onscreen (the common bottom-of-thread case) emits no new event
    /// — status-gating the insert would miss it and double-surface banner +
    /// row. View-local so each window/scene judges its own viewport.
    @State private var visibleUserRowIDs: Set<UUID> = []
    @State private var lastMessageCount = 0

    /// State-A gate for the gateway lock sheet: while false the sheet shows only
    /// the lock explanation + a deliberate "Clone to another gateway…" button;
    /// tapping it flips this true to reveal the clone targets. Reset on each
    /// sheet open (the view instance persists across presentations) so a curious
    /// title tap never lands directly on clone-on-tap rows.
    @State private var showingCloneTargets = false

    /// Shared speaker (one synthesizer for the whole thread; restarting a new
    /// utterance stops the prior one cleanly). The cross-platform `ThreadSpeaker`
    /// state machine, backed by the iOS/macOS `ReplyVoice` speak engine.
    @State private var speaker = ThreadSpeaker(engine: ReplyVoice())

    /// 1.5 s checkmark flip after the toolbar "Copy conversation" tap —
    /// mirrors `MessageBubble.didCopy`.
    @State private var didCopyAll = false

    /// ONE Quick Look presenter for the whole thread — deliberately NOT
    /// per-chip: macOS `QLPreviewPanel` is application-shared and
    /// responder-chain controlled, so row-local presenters inside the
    /// recycling `LazyVStack` would compete for it (and scrolling could
    /// destroy the row that owns the active preview). Chips materialize their
    /// file (server chips download; inline text chips write the locally-stored
    /// bytes) and hand the adopted scratch file up here; the latest tap wins.
    @State private var filePreview = FilePreviewCoordinator()

    var body: some View {
        @Bindable var vm = viewModel
        @Bindable var preview = filePreview
        return ZStack(alignment: .bottom) {
            scrollContent

            if hasUnseenReply && !isAtBottom {
                newReplyBadge
                    .padding(.bottom, 12)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .overlay(alignment: .top) {
            VStack(spacing: 8) {
                // Recovery banner: the bound gateway is gone/unconfigured — the
                // thread stays readable; offer Clone & continue (no dead-end).
                if !viewModel.messages.isEmpty && !viewModel.boundGatewayAvailable {
                    deletedGatewayBanner
                }
                // Compat mode: persistent, reversible — earlier photos
                // ride to THIS conversation's gateway as the canonical
                // disclosure until the user turns it back off.
                if viewModel.hideEarlierPhotos {
                    hiddenPhotosBanner
                }
                // Toast rule: suppress the transient banner while the
                // failed turn's own inline row is visible (the row is the
                // richer surface); pre-flight errors with no row (nil
                // messageID) always show.
                if let sendError = viewModel.sendError, shouldShowSendErrorBanner {
                    sendErrorBanner(sendError)
                }
            }
        }
        .sheet(isPresented: $vm.showingGatewaySheet) {
            gatewayLockSheet
        }
        // Quick Look for attachment files — downloaded server files AND
        // locally-stored inline text files (see `filePreview` doc).
        // The modifier nils the binding on user dismissal — that transition
        // (non-nil → nil, and ONLY that; scene backgrounding never fires it)
        // drives the iOS scratch-file reclaim inside `handleDismiss`.
        .quickLookPreview($preview.previewURL)
        .onChange(of: filePreview.previewURL) { oldValue, newValue in
            if oldValue != nil && newValue == nil {
                filePreview.handleDismiss()
            }
        }
        // Mark this conversation as on-screen so `NotificationDelegate.willPresent`
        // suppresses banners for replies that land for it. iPad multi-scene +
        // macOS multi-window register independently (Set<UUID> in the tracker).
        .onAppear {
            ActiveViewTracker.track(viewModel.conversationID)
            #if os(iOS)
            // Auto-speak hook 1/3: the deep-link navigation just mounted this
            // thread (warm launch — messages typically already loaded). The
            // cold-launch ordering (mounted before the fetch lands) is hook 2's
            // job in `handleMessageCountChange`.
            attemptAutoSpeak()
            #endif
        }
        .onDisappear { ActiveViewTracker.untrack(viewModel.conversationID) }
        // Copy conversation — declared HERE (not in the three host views) so
        // the child `.toolbar` merges into each host's nav bar: iPhone
        // `ContentView`, iPad `ConversationLibraryView` detail, macOS
        // `MainWindowView`. `.primaryAction` is valid on iOS AND macOS
        // (`.topBarTrailing` is iOS-only). Hidden — not disabled — on an
        // empty thread: a brand-new chat has nothing to copy.
        .toolbar {
            if !viewModel.messages.isEmpty {
                ToolbarItem(placement: .primaryAction) {
                    Button(action: copyAllTapped) {
                        Image(systemName: didCopyAll ? "checkmark" : "doc.on.doc")
                    }
                    .accessibilityLabel(Text(didCopyAll
                        ? LocalizedStringResource("thread.copyAll.copied", defaultValue: "Copied")
                        : LocalizedStringResource("thread.copyAll.button", defaultValue: "Copy conversation")))
                    .accessibilityIdentifier("toolbar.copyConversation")
                }
            }
        }
        #if os(iOS)
        // Auto-speak hook 3/3: a reply tap while THIS thread is already open —
        // no remount (no `.onAppear`) and no message-count change (the reply was
        // persisted before the notification fired), so the only signal is the
        // coordinator's `pending` flip. `AutoSpeakRequest` is `Equatable`
        // exactly so this `.onChange` can observe it.
        .onChange(of: AutoSpeakMailbox.shared.pending) { _, newValue in
            guard newValue != nil else { return }
            attemptAutoSpeak()
        }
        #endif
    }

    // MARK: - Scroll content

    private var scrollContent: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 12) {
                    if viewModel.messages.isEmpty && !viewModel.isAwaitingReply
                        && viewModel.hasLoadedInitialMessages {
                        emptyThreadHint
                    }

                    ForEach(viewModel.messages) { message in
                        MessageBubble(
                            message: message,
                            isAwaitingReply: viewModel.isAwaitingReply,
                            boundRef: viewModel.boundRef,
                            speakState: speaker.speakState(for: message.id),
                            usedFallbackVoice: speaker.usedFallbackVoice(for: message.id),
                            filePreview: filePreview,
                            onCopy: { viewModel.copy(message) },
                            onSpeak: { speaker.speak(message.text, messageID: message.id) },
                            onRetry: { Task { await viewModel.retry(message) } },
                            onResendWithoutPhoto: { Task { await viewModel.resendWithoutPhoto(message) } },
                            onKeepChattingWithoutPhotos: { Task { await viewModel.enableHideEarlierPhotos() } }
                        )
                        .equatable()
                        .id(message.id)
                        // Toast rule: the transient banner shows only when
                        // the failed turn's inline row is OFFSCREEN. Real
                        // viewport visibility (not lazy-lifecycle onAppear —
                        // lazy children stay instantiated while offscreen).
                        // Inserts are deliberately NOT status-gated: visibility
                        // events fire on viewport crossings only, so a bubble
                        // failing IN PLACE while visible emits no new event —
                        // a status gate would miss it and double-surface
                        // banner + row. Removal unconditional (no stale
                        // suppression entries).
                        .onScrollVisibilityChange(threshold: 0.2) { visible in
                            guard message.role == "user" else { return }
                            if visible {
                                visibleUserRowIDs.insert(message.id)
                            } else {
                                visibleUserRowIDs.remove(message.id)
                            }
                        }
                    }

                    if viewModel.isAwaitingReply {
                        thinkingIndicator
                            .id(Self.thinkingAnchorID)
                    }

                    // Bottom sentinel for at-bottom detection.
                    Color.clear
                        .frame(height: 1)
                        .id(Self.bottomAnchorID)
                        .onAppear { isAtBottom = true; hasUnseenReply = false }
                        .onDisappear { isAtBottom = false }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 16)
                // Cap the message column (macOS window) but keep the ScrollView
                // full-bleed, so the overlay scrollbar rides the window edge and
                // the content stays centered. `nil` → full-width (iOS/popover).
                .frame(maxWidth: contentMaxWidth ?? .infinity)
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .scrollContentBackground(.hidden)
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: viewModel.messages.count) { _, newCount in
                handleMessageCountChange(newCount, proxy: proxy)
            }
            .onChange(of: viewModel.isAwaitingReply) { _, awaiting in
                if awaiting {
                    // macOS: NON-animated — the synchronous NSView markdown layout
                    // beachballs if an animated scroll re-drives layout every frame.
                    #if os(macOS)
                    proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
                    #else
                    withAnimation(.easeOut(duration: 0.25)) {
                        proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
                    }
                    #endif
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .scrollThreadToBottom)) { _ in
                // macOS: NON-animated (see isAwaitingReply above) — animated scroll
                // compounds the synchronous markdown-layout cost.
                #if os(macOS)
                proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
                #else
                withAnimation(.easeOut(duration: 0.25)) {
                    proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
                }
                #endif
            }
            .onAppear {
                lastMessageCount = viewModel.messages.count
                proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
            }
        }
    }

    private func handleMessageCountChange(_ newCount: Int, proxy: ScrollViewProxy) {
        defer { lastMessageCount = newCount }
        #if os(iOS)
        // Auto-speak hook 2/3: deep-link-fired-before-messages-loaded. A
        // cold-launch tap stages the request before the VM's async fetch lands;
        // re-attempt once the messages arrive. Runs BEFORE the count guard —
        // the initial load can also DECREASE/equalize the count vs. a stale
        // `lastMessageCount`, and the attempt is a cheap no-op when nothing is
        // pending for this thread.
        attemptAutoSpeak()
        #endif
        guard newCount > lastMessageCount else { return }
        if isAtBottom {
            // macOS: NON-animated (see `.onChange(of: isAwaitingReply)`) — a reply
            // landing drives synchronous NSView markdown layout; an animated scroll
            // re-drives it every frame and beachballs on longer threads.
            #if os(macOS)
            proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
            #else
            withAnimation(.easeOut(duration: 0.25)) {
                proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
            }
            #endif
        } else {
            // A reply (or a turn) arrived while scrolled up — surface the badge.
            withAnimation { hasUnseenReply = true }
        }
    }

    // MARK: - Thinking indicator (borderless, left-aligned)

    /// Borderless in-flight indicator: a small spinner + "{Backend} is
    /// answering…" + a subtle elapsed clock that appears only after ~3s (so it
    /// doesn't flicker at 0:00). No card chrome, no inline Cancel — the
    /// composer's trailing Stop control owns cancellation.
    private var thinkingIndicator: some View {
        HStack(spacing: 10) {
            ProgressView()
                .progressViewStyle(.circular)
                .scaleEffect(0.8)

            Text(String(localized: "\(viewModel.backendDisplayName) is answering…"))  // xcstrings: chat-ui
                .font(.callout)
                .foregroundStyle(AppColors.textSecondary)

            TimelineView(.periodic(from: .now, by: 1)) { context in
                let elapsed = viewModel.inFlightStartedAt.map {
                    context.date.timeIntervalSince($0)
                } ?? 0
                if elapsed > 3 {
                    Text(ThinkingStage.clock(max(0, elapsed)))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(AppColors.textTertiary)
                        .transition(.opacity)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - New-reply badge

    private var newReplyBadge: some View {
        Button {
            withAnimation { hasUnseenReply = false }
            // Toggling isAtBottom triggers the sentinel onAppear path; the
            // explicit scroll happens via the message-count observer next
            // render. Drive it directly here for immediacy.
            NotificationCenter.default.post(name: .scrollThreadToBottom, object: nil)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.down")
                Text("New reply below")  // xcstrings
                    .font(.caption.weight(.semibold))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(AppColors.brandAmber)
            .foregroundStyle(AppColors.background)
            .clipShape(Capsule())
            .shadow(color: AppColors.shadow.opacity(0.4), radius: 6, y: 3)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Empty / error

    private var emptyThreadHint: some View {
        VStack(spacing: 16) {
            EmptyStateMascot(pose: emptyMascot, height: 150)
            Text("Type a message or tap the mic.")  // xcstrings: composer
                .font(.callout)
                .foregroundStyle(AppColors.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }

    /// Toast rule: a `sendError` tied to a persisted failed row shows the
    /// top banner only while that row is offscreen; a pre-flight error with no
    /// row (nil `sendErrorMessageID`) always shows. View-local visibility
    /// (this window's own viewport) — correct per-window on macOS/iPad.
    private var shouldShowSendErrorBanner: Bool {
        guard let id = viewModel.sendErrorMessageID else { return true }
        return !visibleUserRowIDs.contains(id)
    }

    /// Compat-mode banner — persistent while `hideEarlierPhotos` is on,
    /// with the reversal action inline ("Try photos again").
    private var hiddenPhotosBanner: some View {
        VStack(spacing: 6) {
            Text(LocalizedStringResource(
                "thread.hiddenPhotos.banner",
                defaultValue: "Earlier photos are hidden from this gateway in this chat."))
                .font(.caption)
                .foregroundStyle(AppColors.textSecondary)
                .multilineTextAlignment(.center)
            Button {
                Task { await viewModel.disableHideEarlierPhotos() }
            } label: {
                Text(LocalizedStringResource(
                    "thread.hiddenPhotos.tryAgain", defaultValue: "Try photos again"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppColors.brandAmber)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .transition(.opacity)
    }

    private func sendErrorBanner(_ message: String) -> some View {
        VStack(spacing: 6) {
            Text(message)
                .font(.caption)
                .foregroundStyle(AppColors.error)
                .multilineTextAlignment(.center)
            // Troubleshoot deep-link — shown only when the failure is one
            // Diagnostics can help with (the failable `DiagnosticsFocus` init is
            // the single filter: nil code or a non-troubleshootable class → no
            // button).
            if let focus = DiagnosticsFocus(errorCode: viewModel.sendErrorCode, ref: viewModel.boundRef) {
                TroubleshootButton(focus: focus)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .transition(.opacity)
    }

    // MARK: - Gateway lock/clone sheet

    /// Sheet explaining the per-conversation gateway lock. Explanation-first: in
    /// the still-locked state (State A) the clone targets sit behind a deliberate
    /// "Clone to another gateway…" reveal, so a curious title tap can't fork the
    /// thread by accident. In the gateway-gone recovery state (State B) clone is
    /// the only way forward, so the targets show directly with no gate.
    private var gatewayLockSheet: some View {
        let otherRefs = viewModel.configuredRefsForClone.filter { $0 != viewModel.boundRef }
        return NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if viewModel.boundGatewayAvailable {
                        // State A — still locked (accident-prone). Lead with the
                        // explanation; gate the clone behind a reveal.
                        Text(String(
                            format: String(localized: "thread.gatewayLock.body",
                                           defaultValue: "This chat stays on %@ to keep context consistent. To use another gateway, clone it — the original stays here unchanged, and your history reaches the new gateway only when you continue there."),
                            viewModel.backendDisplayName
                        ))
                            .font(.callout)
                            .foregroundStyle(AppColors.textSecondary)

                        if !otherRefs.isEmpty {
                            if showingCloneTargets {
                                cloneTargetList(otherRefs)
                                    .transition(.opacity.combined(with: .move(edge: .top)))
                            } else {
                                cloneRevealButton
                            }
                        }
                    } else {
                        // State B — gateway gone (recovery). Clone is the only way
                        // forward; show the targets directly, no reveal gate.
                        Text(String(
                            format: String(localized: "thread.gatewayGone.body",
                                           defaultValue: "Gateway '%@' is no longer available. This conversation stays readable; clone it to keep going on another gateway."),
                            viewModel.backendDisplayName
                        ))
                            .font(.callout)
                            .foregroundStyle(AppColors.textSecondary)

                        if !otherRefs.isEmpty {
                            cloneTargetList(otherRefs)
                        }
                    }
                }
                .padding(20)
            }
            .navigationTitle(Text(LocalizedStringResource("thread.gatewayLock.title", defaultValue: "Gateway")))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(LocalizedStringResource("thread.gatewayLock.done", defaultValue: "Done")) {
                        viewModel.showingGatewaySheet = false
                    }
                }
            }
            // Always open collapsed: the view instance persists across sheet
            // presentations, so reset the reveal each time the sheet appears.
            .onAppear { showingCloneTargets = false }
        }
    }

    /// The "Clone & continue on" header + one row per OTHER configured gateway.
    /// Shared by State A (after the reveal) and State B (shown directly).
    private func cloneTargetList(_ otherRefs: [RemoteAgentRef]) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(LocalizedStringResource(
                "thread.gatewayLock.cloneHeader",
                defaultValue: "Clone & continue on"
            ))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppColors.textPrimary)
            ForEach(otherRefs, id: \.self) { ref in
                cloneButton(ref)
            }
        }
    }

    /// State-A gate: a single deliberate control that reveals the clone targets.
    /// Keeps the sheet explanation-first so the clone rows aren't sitting under a
    /// curious title tap. "Clone to another gateway…" (not "switch") preserves the
    /// fork-never-rebind framing.
    private var cloneRevealButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                showingCloneTargets = true
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "square.on.square")
                    .foregroundStyle(AppColors.brandAmber)
                Text(LocalizedStringResource(
                    "thread.gatewayLock.cloneReveal",
                    defaultValue: "Clone to another gateway…"
                ))
                    .font(.body)
                    .foregroundStyle(AppColors.textPrimary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(AppColors.textSecondary)
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(AppColors.cardBackgroundElevated)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func cloneButton(_ ref: RemoteAgentRef) -> some View {
        let name = RemoteAgentRefMetadata.displayName(for: ref, customs: viewModel.customGateways)
        let color = RemoteAgentBadgePalette.color(for: ref, customs: viewModel.customGateways)
        return Button {
            cloneTo(ref)
        } label: {
            HStack(spacing: 10) {
                Circle().fill(color).frame(width: 12, height: 12)
                // Just the gateway name — the "Clone & continue on" section header
                // and the trailing arrow already convey the action, so repeating the
                // verb per row is redundant. Full phrase preserved for VoiceOver below.
                Text(name)
                    .font(.body)
                    .foregroundStyle(AppColors.textPrimary)
                Spacer()
                Image(systemName: "arrow.right.circle")
                    .foregroundStyle(AppColors.brandAmber)
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(AppColors.cardBackgroundElevated)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(String(
            format: String(localized: "thread.gatewayLock.cloneAction",
                           defaultValue: "Clone & continue on %@"),
            name
        ))
    }

    /// Recovery banner shown when the bound gateway is gone/unconfigured — the
    /// thread stays readable (no silent dead-end); offers the same Clone action.
    private var deletedGatewayBanner: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(
                String(
                    format: String(localized: "thread.gatewayGone.banner",
                                   defaultValue: "Gateway '%@' is no longer available."),
                    viewModel.backendDisplayName
                ),
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(.caption.weight(.semibold))
            .foregroundStyle(AppColors.warning)

            let otherRefs = viewModel.configuredRefsForClone.filter { $0 != viewModel.boundRef }
            if !otherRefs.isEmpty {
                Button {
                    viewModel.showingGatewaySheet = true
                } label: {
                    Text(LocalizedStringResource(
                        "thread.gatewayGone.cloneCTA",
                        defaultValue: "Clone & continue on another gateway"
                    ))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AppColors.brandAmber)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    /// Clone this thread onto `ref`, then make the new conversation active by
    /// posting the shared deep-link notification every host already observes.
    private func cloneTo(_ ref: RemoteAgentRef) {
        Task {
            let newID = await viewModel.cloneConversation(to: ref)
            // Dismiss on failure too — `cloneConversation` surfaces its error
            // via `sendError`, which renders in the THREAD's banner; leaving
            // the sheet presented hid that banner and made the tap read as a
            // dead button.
            viewModel.showingGatewaySheet = false
            if let newID {
                NotificationCenter.default.post(
                    name: .openConversationDeepLink,
                    object: nil,
                    userInfo: [NotificationDeepLink.conversationIDKey: newID.uuidString]
                )
            }
        }
    }

    // MARK: - Copy conversation

    private func copyAllTapped() {
        viewModel.copyEntireConversation()
        withAnimation(.easeOut(duration: 0.15)) { didCopyAll = true }
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            withAnimation(.easeOut(duration: 0.2)) { didCopyAll = false }
        }
    }

    #if os(iOS)
    // MARK: - Notification-tap auto-speak (read-aloud)

    /// Speak the LATEST agent reply iff `AutoSpeakMailbox` holds a
    /// fresh request for THIS conversation (staged by
    /// `NotificationDelegate.didReceive` on an agent-REPLY notification tap).
    /// Routed through the same `speaker` instance as the per-bubble Speak
    /// control, so the bubble shows the playing state, pause/resume works, and
    /// the thread keeps a single audio owner. No `AVAudioSession` setup — the
    /// per-bubble tap-to-speak path runs without any, and this is that path.
    ///
    /// Why `#if os(iOS)`: this view also hosts macOS threads (popover + main
    /// window). Compiling the hooks out makes "macOS deep-links never speak" a
    /// build-time guarantee, not a runtime check.
    ///
    /// Why the message is checked BEFORE consuming: on a cold launch the
    /// deep-link can mount this view before the VM's async fetch lands —
    /// consuming with no agent message yet would burn the one-shot request;
    /// leaving it pending lets the `messages.count` hook retry once the reply
    /// is there. (An empty-text agent turn is skipped the same way — there is
    /// nothing to speak.)
    private func attemptAutoSpeak() {
        guard let latest = viewModel.messages.last(where: { $0.role == "agent" }),
              !latest.text.isEmpty else { return }
        guard AutoSpeakMailbox.shared.consume(matching: viewModel.conversationID) else { return }
        speaker.speak(latest.text, messageID: latest.id)
    }
    #endif

    // MARK: - Anchors

    private static let bottomAnchorID = "thread.bottom.anchor"
    private static let thinkingAnchorID = "thread.thinking.anchor"
}

// MARK: - MessageBubble

/// Isolated agent-reply Markdown surface. `Equatable` on `(messageID, text)` so
/// SwiftUI skips re-rendering it (and re-touching Textual's selection/layout layer)
/// when the parent `MessageBubble` rebuilds for unrelated state (`isAwaitingReply`,
/// the read-aloud `speakState`). Load-bearing for macOS trackpad selection: Textual's
/// whole-document selection overlay keeps its in-drag state in an `NSView`, which a
/// parent-driven re-render of the `StructuredText` resets mid-drag (the "sticky,
/// 2–3 tries" symptom). Identity MUST stay stable — no `.id(...)`, no
/// `.drawingGroup()` (rasterizes → kills selection); the tight comparison is exactly
/// what preserves Textual's internal `@State` lifecycle. Base text color is the
/// constant `AppColors.textPrimary` (Textual's default inline style sets no base
/// color), so it isn't part of the equality key.
private struct AgentMarkdownBody: View, Equatable {
    let messageID: UUID
    let text: String

    static func == (lhs: AgentMarkdownBody, rhs: AgentMarkdownBody) -> Bool {
        lhs.messageID == rhs.messageID && lhs.text == rhs.text
    }

    var body: some View {
        StructuredText(markdown: text)
            .foregroundStyle(AppColors.textPrimary)
            .textual.textSelection(.enabled)
            // Mirror the user `Text` branch — take full natural height, no truncation.
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            // Cross-block trackpad text selection on SHORT (non-scrolling) replies relies
            // on a fix in the Textual fork (GigaDuckAI/textual, branch
            // fix/selection-model-single-frame-layout, pinned by revision in
            // project.pbxproj): the selection model is populated through a representable's
            // updateNSView rather than an onChange that SwiftUI drops for single-frame
            // layouts. Upstreamed as a PR; swap the pin back to upstream once it tags.
    }
}

private struct MessageBubble: View, Equatable {
    let message: MessageRecord
    /// True while an agent turn is in flight. When true, the per-message
    /// `sending` spinner is suppressed so the borderless thread "answering…"
    /// indicator is the SOLE in-flight signal (Retry on failure is unaffected).
    let isAwaitingReply: Bool
    /// The conversation's bound gateway ref — resolves the file-server snapshot
    /// for an assistant-bubble download-chip tap. Nil before the VM resolves it
    /// (a download falls back to the Settings default ref).
    let boundRef: RemoteAgentRef?
    /// This bubble's speak phase — `.idle` unless it's the actively-spoken
    /// one. Drives the footer Speak glyph (idle/loading/playing) + the amber
    /// active-speaking outline. Only meaningful on assistant bubbles.
    let speakState: SpeakState
    /// True when this message's LAST playback attempt fell back to the Apple
    /// built-in voice (the chat speak path substitutes Apple on cloud-TTS
    /// failure so the reply is never silent). An ephemeral, device-local marker
    /// — the transparency half of the never-silent-voice-fallback contract.
    /// Only ever true on assistant bubbles. Drives the footer fallback caption.
    let usedFallbackVoice: Bool
    /// The thread's single Quick Look presenter — download chips hand their
    /// adopted file up to it. A stable `@State`-owned reference (excluded from
    /// `==` alongside the closures).
    let filePreview: FilePreviewCoordinator
    let onCopy: () -> Void
    let onSpeak: () -> Void
    /// Re-fire a failed user turn (drives the delivery row's "Try again").
    let onRetry: () -> Void
    /// Enable compat mode AND re-fire this failed photo turn WITHOUT its
    /// photos (delivery row action on a declined photo turn). Non-destructive.
    let onResendWithoutPhoto: () -> Void
    /// Enable compat mode without resending (delivery row action on a
    /// poisoned chat — the user keeps typing, earlier photos ride as the
    /// canonical disclosure from the next send on).
    let onKeepChattingWithoutPhotos: () -> Void

    @State private var didCopy = false
    /// Full-screen gallery state (start index = tapped thumbnail).
    @State private var fullScreenStartIndex: Int?
    /// Drives static-vs-animated affordances (the active-speaking outline).
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Equatable on the rendering inputs ONLY (closures excluded — they re-fire
    /// the current action and capture stable references). Paired with `.equatable()`
    /// in the `ForEach`, this short-circuits a non-speaking bubble's `body` when the
    /// `@Observable ThreadSpeaker` publishes a phase change: only the bubble whose
    /// `speakState` actually changed re-renders, not the whole thread. `message` is
    /// `Hashable` so its `==` covers text/status/attachments.
    static func == (lhs: MessageBubble, rhs: MessageBubble) -> Bool {
        lhs.message == rhs.message
            && lhs.isAwaitingReply == rhs.isAwaitingReply
            && lhs.boundRef == rhs.boundRef
            && lhs.speakState == rhs.speakState
            && lhs.usedFallbackVoice == rhs.usedFallbackVoice
    }

    private var isUser: Bool { message.role == "user" }

    /// Inline image attachments (ordered by sequence), drives the grid + gallery.
    /// A server-reference image now carries `thumbnailData` (and an image
    /// `mimeType` is possible), so `isImage` alone is TRUE for it — the
    /// `!isServerFile` guard keeps it out of the grid/fullscreen gallery (whose
    /// lazy loader faults local bytes a server ref doesn't have); it renders as a
    /// download chip via `serverFileAttachments` instead.
    private var imageAttachments: [AttachmentRecord] {
        message.attachments.filter { $0.isImage && !$0.isServerFile }
    }

    /// Text/code attachments, drives the file chips.
    private var textAttachments: [AttachmentRecord] {
        message.attachments.filter { $0.isText }
    }

    /// Server-file attachments (file-transfer route): a SENT chip on a user
    /// bubble (file glyph + name, no thumbnail), a DOWNLOAD chip on an assistant
    /// bubble (the agent wrote an output file). Ordered by sequence.
    private var serverFileAttachments: [AttachmentRecord] {
        // Belt-and-braces dedupe by storedKey (keeps the lowest-sequence
        // occurrence) so two devices' near-simultaneous retro output scans can't
        // render duplicate download chips — see `dedupedServerFiles`.
        MessageRowFormatters.dedupedServerFiles(message.attachments.filter { $0.isServerFile })
    }

    var body: some View {
        // The delivery error row sits UNDER the bubble, outside its
        // background — persistent delivery metadata, never a fabricated
        // assistant bubble and never part of outbound history.
        VStack(alignment: .trailing, spacing: 6) {
            bubbleRow
            if isUser, message.status == "failed" {
                deliveryErrorRow
            }
        }
        .fullScreenCoverCompat(item: $fullScreenStartIndex) { startIndex in
            AttachmentFullScreenView(
                imageAttachments: imageAttachments,
                messageID: message.id,
                startIndex: startIndex
            )
        }
    }

    private var bubbleRow: some View {
        HStack {
            if isUser { Spacer(minLength: 48) }

            VStack(alignment: isUser ? .trailing : .leading, spacing: 8) {
                // Attachments render ABOVE the caption (user-role only — agent
                // turns never carry attachments).
                if isUser && !imageAttachments.isEmpty {
                    AttachmentImageGrid(
                        attachments: imageAttachments,
                        onTap: { index in fullScreenStartIndex = index }
                    )
                }
                if isUser && !textAttachments.isEmpty {
                    VStack(alignment: .trailing, spacing: 6) {
                        ForEach(textAttachments) { attachment in
                            InlineTextFileChip(
                                attachment: attachment,
                                filePreview: filePreview,
                                isUserBubble: isUser
                            )
                        }
                    }
                }
                // Server-file (file-transfer) chips — BOTH roles preview via
                // Quick Look: the agent's output files AND the user's own sent
                // files live on the file-server, so one chip re-pulls either.
                if !serverFileAttachments.isEmpty {
                    VStack(alignment: isUser ? .trailing : .leading, spacing: 6) {
                        ForEach(serverFileAttachments) { attachment in
                            ServerFileDownloadChip(
                                attachment: attachment,
                                boundRef: boundRef,
                                expectedLaneID: isUser
                                    ? message.fileTransferLaneID
                                    : message.outputScanLaneID,
                                filePreview: filePreview,
                                isUserBubble: isUser
                            )
                        }
                    }
                }

                if !message.text.isEmpty {
                    // Selection is enabled INSIDE `bubbleBody`, per role: SwiftUI's
                    // `.textSelection` on the user `Text`, and Textual's
                    // `.textual.textSelection` on the agent `StructuredText` (the two
                    // are independent selection systems — scoping each to its own
                    // branch avoids SwiftUI's per-fragment selection competing with
                    // Textual's whole-document overlay). Kept off the footer/chips.
                    bubbleBody
                }

                footer
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(bubbleBackground)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            // Active-speaking affordance: a thin amber outline on the
            // bubble currently being read aloud, so the user can locate the
            // source. Only assistant bubbles ever reach a non-idle speakState.
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(
                        AppColors.brandAmber.opacity(speakState != .idle ? 0.6 : 0),
                        lineWidth: 1
                    )
                    .animation(
                        reduceMotion ? nil : .spring(response: 0.34, dampingFraction: 0.82),
                        value: speakState
                    )
            }
            // Cap the bubble chrome (not just the text) at an intimate measure
            // so it doesn't stretch on the wide macOS/iPad surfaces. 520pt is a
            // deliberate no-op on iPhone (portrait content width < 520), so this
            // tightens iPad/Mac while leaving iPhone untouched. Alignment keeps
            // user-right / agent-left (paired with the `Spacer(minLength: 48)`).
            .frame(maxWidth: 520, alignment: isUser ? .trailing : .leading)

            if !isUser { Spacer(minLength: 48) }
        }
    }

    // MARK: - Delivery error row

    /// The presentation for this failed turn — derived from the PERSISTED
    /// record fields only (survives relaunch; no thread-scan, no ephemeral VM
    /// state). Shared classifier with the offscreen toast.
    private var declinedPresentation: DeclinedTurnPresentation {
        DeclinedTurnPresentation.classify(
            failureCode: message.failureCode,
            failureWireCode: message.failureWireCode,
            turnHasOwnImages: message.attachments.contains { $0.isImage && !$0.isServerReference },
            hadHistoryImages: message.failureHadHistoryImages,
            hasResendableNonPhotoContent: !message.text.isEmpty
                || message.attachments.contains { $0.isText || $0.isServerFile }
        )
    }

    /// Persistent inline error row under a failed user turn: outcome + safe
    /// cause + actions ("Try again", plus the photo-specific recovery). Frozen
    /// copy via `DeclinedTurnPresentation`; vocabulary is "gateway", never
    /// "model".
    private var deliveryErrorRow: some View {
        let presentation = declinedPresentation
        return VStack(alignment: .trailing, spacing: 5) {
            HStack(spacing: 5) {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(AppColors.error)
                Text(presentation.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppColors.error)
            }
            Text(presentation.body)
                .font(.caption2)
                .foregroundStyle(AppColors.textSecondary)
                .multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
            // Actions stack vertically (trailing) — the photo-recovery labels
            // are long, and a horizontal row overflows the narrow popover.
            VStack(alignment: .trailing, spacing: 6) {
                Button(action: onRetry) {
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.clockwise")
                        Text(LocalizedStringResource("declinedTurn.action.tryAgain", defaultValue: "Try again"))
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppColors.error)
                }
                .buttonStyle(.plain)
                if presentation.offersResendWithoutPhoto {
                    Button(action: onResendWithoutPhoto) {
                        Text(LocalizedStringResource("declinedTurn.action.resendWithoutPhoto", defaultValue: "Resend without photo"))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(AppColors.brandAmber)
                    }
                    .buttonStyle(.plain)
                }
                if presentation.offersKeepChattingWithoutPhotos {
                    Button(action: onKeepChattingWithoutPhotos) {
                        Text(LocalizedStringResource("declinedTurn.action.keepChatting", defaultValue: "Keep chatting without photos"))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(AppColors.brandAmber)
                    }
                    .buttonStyle(.plain)
                }
                // Diagnostics deep-link for troubleshootable generic failures —
                // the row supersedes the transient banner, so the affordance
                // must survive here (the failable `DiagnosticsFocus` init is
                // the single filter).
                if let focus = DiagnosticsFocus(errorCode: presentation.troubleshootCode, ref: boundRef) {
                    TroubleshootButton(focus: focus)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(AppColors.error.opacity(0.08))
        )
        .frame(maxWidth: 520, alignment: .trailing)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(verbatim: "\(presentation.title). \(presentation.body)"))
    }

    @ViewBuilder
    private var bubbleBody: some View {
        if isUser {
            // User role = plain Text, right-aligned (no Markdown in STT output).
            Text(message.text)
                .font(.body)
                .foregroundStyle(AppColors.background)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        } else {
            // Agent role = Markdown (GFM via Textual `StructuredText`), left-aligned.
            // Rendered through the Equatable `AgentMarkdownBody` leaf + `.equatable()`
            // so unrelated parent re-renders (read-aloud `speakState`, `isAwaitingReply`
            // turn boundaries) can't re-touch Textual's selection layer mid-drag — the
            // macOS trackpad-selection fix. See `AgentMarkdownBody`.
            AgentMarkdownBody(messageID: message.id, text: message.text)
                .equatable()
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            // Device chip is meaningful only for user turns (which device sent
            // it); agent replies have no originating device to show.
            if isUser {
                SourceDeviceChip(device: message.sourceDevice)
            }

            // Send-state (user-role only) — sending spinner / failed Retry.
            sendStateView

            // Subtle per-message timestamp (short time-of-day). Kept tertiary so
            // it doesn't crowd the chip row on the narrow popover footer.
            Text(message.createdAt, format: .dateTime.hour().minute())
                .font(.caption2)
                .foregroundStyle(AppColors.textTertiary)

            Spacer(minLength: 4)

            // Voice-fallback transparency marker (never-silent-voice-fallback
            // contract): when this reply's LAST playback fell back to the Apple
            // built-in voice (cloud TTS failed), surface a subtle caption so the
            // substitution is visible rather than silent. Assistant bubbles only;
            // conditional view → zero layout footprint when false. Sits with the
            // trailing speak/copy controls so it reads as playback metadata.
            if !isUser && usedFallbackVoice {
                Text(LocalizedStringResource(
                    "thread.speak.fallbackVoice", defaultValue: "Built-in voice"))
                    .font(.caption2)
                    .foregroundStyle(AppColors.textTertiary)
                    .accessibilityLabel(Text(LocalizedStringResource(
                        "thread.speak.fallbackVoice.a11y",
                        defaultValue: "Spoken with the built-in voice")))
            }

            // Speak: ASSISTANT bubbles only (agent replies). State-driven glyph
            // (speak → pause → resume), with a generous hit region + press style
            // (MessageActionButton). The foreground-active gate stays in
            // `speakTapped`.
            if !isUser {
                MessageActionButton(
                    accessibilityLabel: Text(speakAccessibilityLabel),
                    action: speakTapped
                ) {
                    speakGlyph
                }
            }

            MessageActionButton(
                systemImage: didCopy ? "checkmark" : "doc.on.doc",
                tint: footerTint,
                accessibilityLabel: Text(didCopy
                    ? LocalizedStringResource("bubble.copy.copied", defaultValue: "Copied")
                    : LocalizedStringResource("bubble.copy.copy", defaultValue: "Copy")),
                action: copyTapped
            )
        }
    }

    /// State-driven Speak glyph — all bare fills at a matched optical size so the
    /// footer controls read UNIFORM (no circle-enclosed chips, which look heavier
    /// + larger next to the bare `doc.on.doc` Copy glyph):
    ///   idle    → `speaker.wave.2.fill` at **17pt** — the FILLED variant gives
    ///             the right weight, but `speaker.wave.2.fill` is a WIDE-but-SHORT
    ///             symbol, so at the Copy glyph's 16pt it renders ~12% less ink
    ///             and reads smaller (equal point size ≠ equal rendered size
    ///             across differently-shaped SF Symbols). 17pt area-matches the
    ///             dense, near-square `doc.on.doc` (empirically: 16pt was −12%,
    ///             18pt overshot to +14%, 17pt ≈ parity).
    ///   loading → a `.small` spinner (NOT `.mini`, which visibly shrank the
    ///             control the instant it was tapped), gray footer tint — its
    ///             MOTION confirms the tap (no color flip).
    ///   playing → `pause.fill` (gray footer tint, 16pt) — tap to pause.
    ///   paused  → `play.fill`  (gray footer tint, 16pt) — tap to resume from
    ///             position.
    /// Every state reads the uniform gray footer tint (like the neighboring
    /// Copy glyph); only the glyph SHAPE signals state — nothing goes amber.
    @ViewBuilder
    private var speakGlyph: some View {
        switch speakState {
        case .idle:
            Image(systemName: "speaker.wave.2.fill")
                .font(.system(size: 17))
                .foregroundStyle(footerTint)
        case .loading:
            ProgressView()
                .controlSize(.small)
                .tint(footerTint)
        case .playing:
            Image(systemName: "pause.fill")
                .font(.system(size: 16))
                .foregroundStyle(footerTint)
        case .paused:
            Image(systemName: "play.fill")
                .font(.system(size: 16))
                .foregroundStyle(footerTint)
        }
    }

    /// VoiceOver label for the Speak control, switching with the speak phase.
    private var speakAccessibilityLabel: LocalizedStringResource {
        switch speakState {
        case .idle:
            return LocalizedStringResource("bubble.speak.aloud", defaultValue: "Speak aloud")
        case .loading:
            return LocalizedStringResource("bubble.speak.loading", defaultValue: "Loading")
        case .playing:
            return LocalizedStringResource("bubble.speak.pause", defaultValue: "Pause")
        case .paused:
            return LocalizedStringResource("bubble.speak.resume", defaultValue: "Resume")
        }
    }

    /// Send-state indicator (user-role only, keyed off `message.status`):
    /// `sending` → a small spinner; `sent`/nil → clean. A `failed` turn shows
    /// NOTHING here — the delivery error row under the bubble carries the
    /// outcome, cause, and every action (incl. "Try again", which replaced the
    /// old footer Retry chip).
    @ViewBuilder
    private var sendStateView: some View {
        if isUser {
            switch message.status {
            case "sending":
                // Suppress the per-message sending spinner while a reply is in
                // flight — the borderless "answering…" indicator is the single
                // in-flight signal. Show it only when NOT awaiting (e.g. a brief
                // window before the indicator appears).
                if !isAwaitingReply {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .controlSize(.mini)
                        .tint(AppColors.background.opacity(0.8))
                        .accessibilityLabel(Text(LocalizedStringResource(
                            "bubble.status.sending", defaultValue: "Sending")))
                }
            default:
                EmptyView()
            }
        }
    }

    private func copyTapped() {
        onCopy()
        withAnimation(.easeOut(duration: 0.15)) { didCopy = true }
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            withAnimation(.easeOut(duration: 0.2)) { didCopy = false }
        }
    }

    private func speakTapped() {
        // Foreground-gated: never speak when not active. Auto-speak
        // exceptions are staged through `AutoSpeakMailbox` and route through
        // the same `ThreadSpeaker` (see the file header) — this tap path stays
        // gate-checked for the manual case.
        #if canImport(UIKit)
        guard UIApplication.shared.applicationState == .active else { return }
        #endif
        // macOS cross-engine arbitration (manual tap silencing the shared
        // arrival/preview voice) lives inside `ThreadSpeaker.speak` via the
        // `SpeechExclusivity` bus — no per-call-site cancel needed here.
        onSpeak()
    }

    private var bubbleBackground: Color {
        isUser ? AppColors.brandAmber : AppColors.cardBackgroundElevated
    }

    private var footerTint: Color {
        isUser ? AppColors.background.opacity(0.7) : AppColors.textTertiary
    }
}

// MARK: - InlineTextFileChip (user-sent inline text/code file)

/// Chip for an INLINE text/code attachment on a user bubble (`isText`: txt /
/// md / json / csv / source code / … — any non-image, non-server-reference
/// type). The sent bytes already live in the local store (`extractedText` is
/// the exact UTF-8 content that rode the wire), so a tap needs NO download:
/// it writes the text into `AgentDownloadScratch` (clean leaf name +
/// type-carrying extension, same store the download chips use) and hands the
/// file to the thread's shared `FilePreviewCoordinator` for a Quick Look
/// preview — identical per-platform presentation + scratch reclaim to
/// `ServerFileDownloadChip`.
///
/// A record with NO local text (a partially-synced CloudKit row / a non-UTF-8
/// decode miss) renders the same chip as a passive label — nothing to preview.
///
/// PRIVACY: never logs the filename / content — a failure surfaces only as an
/// inline generic message.
private struct InlineTextFileChip: View {
    let attachment: AttachmentRecord
    /// The thread-level Quick Look presenter (single panel authority).
    let filePreview: FilePreviewCoordinator
    /// True on a user bubble — dark-on-amber text, translucent fill (mirrors
    /// `ServerFileDownloadChip`'s role styling).
    let isUserBubble: Bool

    /// Non-nil after a failed scratch write — the inline error line (cleared
    /// on the next successful tap).
    @State private var failureMessage: String?

    private var name: String {
        attachment.filename ?? String(localized: LocalizedStringResource(
            "attachment.file.untitled", defaultValue: "Attached file"))
    }

    /// The chip previews only when the sent bytes are locally present.
    private var isPreviewable: Bool { attachment.extractedText != nil }

    var body: some View {
        Group {
            if isPreviewable {
                Button(action: presentPreview) {
                    chipLabel
                        // Keep the whole label tappable (matches `ServerFileDownloadChip`).
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                // Passive full-opacity label, NOT a disabled Button — the
                // system's disabled dimming + "dimmed" VoiceOver trait would
                // make a real (just not-yet-synced) attachment look broken.
                chipLabel
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(String(
            format: String(localized: isPreviewable
                ? LocalizedStringResource(
                    "attachment.file.preview.accessibility",
                    defaultValue: "Preview attached file %@")
                : LocalizedStringResource(
                    "attachment.file.accessibility",
                    defaultValue: "Attached file %@")),
            name
        )))
    }

    private var chipLabel: some View {
        HStack(spacing: 8) {
            Image(systemName: AttachmentChipStyle.symbol(forMimeType: attachment.mimeType, filename: attachment.filename))
                .font(.system(size: 18))
                .foregroundStyle(AttachmentChipStyle.tint(forMimeType: attachment.mimeType, filename: attachment.filename))
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(isUserBubble ? AppColors.background : AppColors.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let failureMessage {
                    Text(failureMessage)
                        .font(.caption2)
                        .foregroundStyle(AppColors.error)
                        .lineLimit(2)
                } else if attachment.byteSize > 0 {
                    Text(AttachmentChipStyle.formattedSize(attachment.byteSize))
                        .font(.caption2)
                        .foregroundStyle(isUserBubble ? AppColors.background.opacity(0.7) : AppColors.textTertiary)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: 220, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isUserBubble ? AppColors.background.opacity(0.18) : AppColors.cardBackground)
        )
    }

    /// Write the locally-stored text into the scratch store and hand it to
    /// the Quick Look presenter. Claim minted at tap time (latest-tap-wins,
    /// same contract as the download chips — a slower concurrent download
    /// must not steal the panel from this later tap).
    private func presentPreview() {
        guard let text = attachment.extractedText else { return }
        let token = filePreview.beginRequest()
        Task {
            do {
                let item = try await AgentDownloadScratch.shared.adopt(
                    Data(text.utf8), preferredName: name, mimeType: attachment.mimeType)
                failureMessage = nil
                filePreview.present(item, token: token)
            } catch {
                failureMessage = String(localized: LocalizedStringResource(
                    "fileTransfer.preview.failed", defaultValue: "Couldn't preview the file."))
            }
        }
    }
}

// MARK: - ServerFileDownloadChip (assistant output file)

/// Chip for a server-reference attachment on EITHER bubble role — an agent
/// output file the client detected + probed (assistant), or a file the user
/// sent (user; its bytes live on the file-server too, so it previews the same
/// way). A tap downloads the real bytes from the user's gateway file-server
/// via `BackgroundFileTransfer.shared.downloadFile`, adopts them into
/// `AgentDownloadScratch` (clean leaf name + type-carrying extension), and
/// hands the file to the thread's shared `FilePreviewCoordinator` for a Quick
/// Look preview:
///   - iOS  : full-screen `QLPreviewController` — its share button covers
///            share AND Save to Files; the scratch file is reclaimed when the
///            preview dismisses.
///   - macOS: the shared `QLPreviewPanel` (share + "Open with"); a visible
///            trailing "Save As…" button (+ right-click menu) keeps the
///            `NSSavePanel` path for a durable save. Scratch files are
///            reclaimed by the age sweep, never on panel close ("Open with"
///            may still hold the path).
/// Re-tap re-downloads — no cache; the agent may have rewritten the file.
///
/// PRIVACY: never logs the storedKey / filename / URL — only an opaque progress
/// + error state surfaces in the UI.
private struct ServerFileDownloadChip: View {
    let attachment: AttachmentRecord
    /// Conversation's bound gateway — resolves the file-server snapshot. Nil
    /// falls back to the Settings default ref.
    let boundRef: RemoteAgentRef?
    /// Durable owner of this chip's storedKey. A GET requires the exact same
    /// configured lane. Its mutable READY verdict gates new transfers, not
    /// access to an already-owned blob. Nil is unprovable and fails closed.
    let expectedLaneID: String?
    /// The thread-level Quick Look presenter (single panel authority).
    let filePreview: FilePreviewCoordinator
    /// True on a user bubble — mirrors `InlineTextFileChip`'s role styling
    /// (dark-on-amber text, translucent fill) so the chip sits naturally on
    /// either bubble.
    let isUserBubble: Bool

    /// Tri-state download chrome: idle (no glyph — the chip itself is the tap
    /// target), busy (spinner), failed (error glyph + the inline message).
    private enum DownloadState: Equatable {
        case idle, downloading, failed(String)
    }
    /// What a completed download hands off to: the Quick Look preview (default
    /// tap) or — macOS only — the `NSSavePanel` "Save As…" verb.
    private enum PostDownloadRoute: Equatable {
        case preview
        #if os(macOS)
        case saveAs
        #endif
    }
    @State private var state: DownloadState = .idle
    /// Gates the large-download soft-confirm alert (mirrors the upload-side
    /// large-file warning). Only ever true when the size is KNOWN + over the cap.
    @State private var showingLargeDownloadConfirm = false
    /// The verb the soft-confirm is holding — so confirming a "Save As…" tap
    /// doesn't come back as a preview. Reset on cancel.
    @State private var pendingRoute: PostDownloadRoute = .preview

    private var name: String {
        attachment.filename ?? String(localized: LocalizedStringResource(
            "attachment.file.untitled", defaultValue: "Attached file"))
    }

    /// Role-aware secondary tint (size label, spinner-adjacent text, Save As
    /// glyph) — matches `InlineTextFileChip` / `footerTint` on each bubble color.
    private var secondaryTint: Color {
        isUserBubble ? AppColors.background.opacity(0.7) : AppColors.textTertiary
    }

    var body: some View {
        HStack(spacing: 8) {
            Button(action: { download(route: .preview) }) {
                HStack(spacing: 8) {
                    Image(systemName: AttachmentChipStyle.symbol(forMimeType: attachment.mimeType, filename: attachment.filename))
                        .font(.system(size: 18))
                        .foregroundStyle(AttachmentChipStyle.tint(forMimeType: attachment.mimeType, filename: attachment.filename))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(name)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(isUserBubble ? AppColors.background : AppColors.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        downloadStateLabel
                    }
                    Spacer(minLength: 4)
                    trailingGlyph
                }
                // Padding/background live on the outer HStack now — keep the
                // whole label (Spacer included) tappable.
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(state == .downloading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(String(
                format: String(localized: LocalizedStringResource(
                    "fileTransfer.preview.accessibility",
                    defaultValue: "Download and preview file %@ from your gateway")),
                name
            )))
            #if os(macOS)
            saveAsButton
            #endif
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: 240, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isUserBubble ? AppColors.background.opacity(0.18) : AppColors.cardBackground)
        )
        #if os(macOS)
        // Redundant shortcut for the visible Save As… button (HIG: a context
        // menu may only mirror a visible control, never be the sole path).
        .contextMenu {
            Button(saveAsTitle) { download(route: .saveAs) }
                .disabled(state == .downloading)
        }
        #endif
        // Large-download soft-confirm (>100 MB, KNOWN size) — mirrors the
        // upload-side warning so a multi-hundred-MB transfer never starts silently.
        // Unknown size (byteSize == 0) never reaches this gate → downloads at once.
        .alert(
            LocalizedStringResource("fileTransfer.download.softConfirm.title", defaultValue: "Download large file?"),
            isPresented: $showingLargeDownloadConfirm
        ) {
            Button(LocalizedStringResource("fileTransfer.download.softConfirm.download", defaultValue: "Download")) {
                beginDownload(route: pendingRoute)
            }
            Button(LocalizedStringResource("fileTransfer.softConfirm.cancel", defaultValue: "Cancel"), role: .cancel) {
                pendingRoute = .preview
            }
        } message: {
            Text(String(
                format: String(localized: LocalizedStringResource(
                    "fileTransfer.download.softConfirm.message",
                    defaultValue: "%1$@ is %2$@ in size. Large files can take a while to download."
                )),
                name,
                AttachmentChipStyle.formattedSize(attachment.byteSize)
            ))
        }
    }

    @ViewBuilder
    private var trailingGlyph: some View {
        switch state {
        case .downloading:
            ProgressView()
                .progressViewStyle(.circular)
                .controlSize(.small)
        case .failed:
            Image(systemName: "exclamationmark.circle")
                .font(.system(size: 16))
                .foregroundStyle(AppColors.error)
        case .idle:
            // No idle glyph — the whole chip is the Quick Look tap target;
            // an extra affordance would crowd the chip.
            EmptyView()
        }
    }

    #if os(macOS)
    private var saveAsTitle: String {
        String(localized: LocalizedStringResource("fileTransfer.saveAs", defaultValue: "Save As…"))
    }

    /// Visible durable-save affordance — the Quick Look panel's share menu has
    /// no save-to-disk verb, so the panel alone can't cover "keep it". Neutral
    /// secondary tint: it's the side verb, the chip tap (preview) is primary.
    private var saveAsButton: some View {
        Button(action: { download(route: .saveAs) }) {
            Image(systemName: "square.and.arrow.down")
                .font(.system(size: 15))
                .foregroundStyle(secondaryTint)
        }
        .buttonStyle(.plain)
        .disabled(state == .downloading)
        .help(saveAsTitle)
        .accessibilityLabel(Text(String(
            format: String(localized: LocalizedStringResource(
                "fileTransfer.saveAs.accessibility",
                defaultValue: "Save file %@ from your gateway")),
            name
        )))
    }
    #endif

    @ViewBuilder
    private var downloadStateLabel: some View {
        switch state {
        case .downloading:
            Text(LocalizedStringResource("fileTransfer.download.inProgress", defaultValue: "Downloading…"))
                .font(.caption2)
                .foregroundStyle(secondaryTint)
        case .failed(let message):
            Text(message)
                .font(.caption2)
                .foregroundStyle(AppColors.error)
                .lineLimit(2)
        case .idle:
            if attachment.byteSize > 0 {
                Text(AttachmentChipStyle.formattedSize(attachment.byteSize))
                    .font(.caption2)
                    .foregroundStyle(secondaryTint)
            }
        }
    }

    /// Button action. For a KNOWN very-large size, gate behind a soft-confirm
    /// (mirrors the upload-side large-file warning) before the multi-hundred-MB
    /// download begins; unknown size (byteSize == 0) downloads immediately.
    private func download(route: PostDownloadRoute) {
        guard state != .downloading else { return }
        pendingRoute = route
        if attachment.byteSize > Constants.fileTransferSoftConfirmBytes {
            showingLargeDownloadConfirm = true
        } else {
            beginDownload(route: route)
        }
    }

    /// Resolve the snapshot, download the bytes, then hand off per `route`
    /// (Quick Look preview / macOS save panel). Fail-fast with a visible error
    /// (NO silent retry).
    private func beginDownload(route: PostDownloadRoute) {
        guard state != .downloading else { return }
        state = .downloading
        // Preview requests mint their claim NOW (the moment of user intent),
        // BEFORE the async download — completion order must not decide which
        // file gets the panel (latest-tap-wins, see `FilePreviewCoordinator`).
        var previewToken: UInt64?
        if route == .preview { previewToken = filePreview.beginRequest() }
        Task {
            // `??` with an `await` RHS is rejected (the operator's autoclosure
            // isn't async) — resolve the ref with an explicit if-let instead.
            let ref: RemoteAgentRef
            if let boundRef {
                ref = boundRef
            } else {
                ref = await SettingsManager.shared.defaultRemoteAgentRef()
            }
            let snapshot = await SettingsManager.shared.fileTransferSnapshot(for: ref)
            guard FileTransferLaneOwnership.canAccessExistingBlob(
                    expectedLaneID: expectedLaneID,
                    snapshot: snapshot
                  ),
                  let snapshot else {
                presentError(AppError.fileTransferNotConfigured)
                return
            }
            do {
                let tempURL = try await BackgroundFileTransfer.shared.downloadFile(
                    snapshot: snapshot,
                    storedKey: attachment.storedKey ?? "")
                switch route {
                case .preview:
                    await presentPreview(tempURL: tempURL, token: previewToken ?? 0)
                #if os(macOS)
                case .saveAs:
                    await presentSavePanel(tempURL: tempURL)
                #endif
                }
            } catch let error as AppError {
                presentError(error)
            } catch {
                // `downloadFile` maps transport/HTTP failures to the AppError
                // family, so this is a belt-and-braces generic fallback.
                presentGenericError()
            }
        }
    }

    @MainActor
    private func presentError(_ error: AppError) {
        state = .failed(error.errorDescription ?? Self.genericFailureMessage)
    }

    @MainActor
    private func presentGenericError() {
        state = .failed(Self.genericFailureMessage)
    }

    private static var genericFailureMessage: String {
        String(localized: LocalizedStringResource(
            "fileTransfer.download.failed", defaultValue: "Couldn't download the file."))
    }

    private static var saveFailureMessage: String {
        String(localized: LocalizedStringResource(
            "fileTransfer.save.failed", defaultValue: "Couldn't save the file."))
    }

    private static var previewFailureMessage: String {
        String(localized: LocalizedStringResource(
            "fileTransfer.preview.failed", defaultValue: "Couldn't preview the file."))
    }

    /// Adopt the raw download into the scratch store (clean name +
    /// type-carrying extension) and hand it to the thread's Quick Look
    /// presenter. Adoption failure surfaces like a download failure and
    /// reclaims the raw temp.
    @MainActor
    private func presentPreview(tempURL: URL, token: UInt64) async {
        do {
            let item = try await AgentDownloadScratch.shared.adopt(
                tempURL, preferredName: name, mimeType: attachment.mimeType)
            filePreview.present(item, token: token)
            state = .idle
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            state = .failed(Self.previewFailureMessage)
        }
    }

    #if os(macOS)
    /// Present the `NSSavePanel` for the downloaded temp file, then clean it
    /// up. The durable-save verb — reached from the visible Save As… button or
    /// the context menu, never the default tap.
    @MainActor
    private func presentSavePanel(tempURL: URL) async {
        // Reclaim the downloaded temp file on every exit path.
        defer { try? FileManager.default.removeItem(at: tempURL) }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        guard panel.runModal() == .OK, let destination = panel.url else {
            state = .idle   // user cancelled — not a failure
            return
        }
        do {
            // Off-main: a cross-volume copy of a large downloaded file (external
            // USB / network share) blocks the main thread for seconds → beachball.
            // The panel + result handling stay on main; only the byte copy hops to
            // a detached task, then we resume on the MainActor to update `state`.
            try await Task.detached {
                if FileManager.default.fileExists(atPath: destination.path) {
                    // Atomic replace — never delete the existing file before the
                    // write succeeds (no data-loss window if the copy fails).
                    _ = try FileManager.default.replaceItemAt(destination, withItemAt: tempURL)
                } else {
                    try FileManager.default.copyItem(at: tempURL, to: destination)
                }
            }.value
            state = .idle
        } catch {
            // Surface save failures the way the download phase does, rather
            // than silently going idle with no file written.
            state = .failed(Self.saveFailureMessage)
        }
    }
    #endif
}

/// The thread's single Quick Look presenter — ONE per `ConversationThreadView`,
/// deliberately never per-chip: macOS `QLPreviewPanel` is application-shared
/// and responder-chain controlled, so row-local presenters inside the
/// recycling `LazyVStack` would compete for it. Chips mint a claim at tap time
/// and hand their adopted scratch item up on completion; the latest claim wins
/// and a stale completion reclaims its own bytes.
@MainActor @Observable
final class FilePreviewCoordinator {
    /// Drives the thread root's `.quickLookPreview` — the modifier nils it on
    /// user dismissal.
    var previewURL: URL?
    /// The scratch item currently on screen (reclaimed per-platform, see
    /// `handleDismiss`).
    private var currentItem: AgentDownloadScratch.ScratchItem?
    /// Monotonic claim counter — minted at tap time, checked at completion.
    private var latestToken: UInt64 = 0

    /// Mint a presentation claim at the moment of user intent (chip tap /
    /// soft-confirm), BEFORE the async download — completion order must not
    /// decide which file gets the panel.
    func beginRequest() -> UInt64 {
        latestToken &+= 1
        return latestToken
    }

    /// Present an adopted download — or, when a newer claim exists, discard it.
    func present(_ item: AgentDownloadScratch.ScratchItem, token: UInt64) {
        guard token == latestToken else {
            // A newer tap won while this download ran — reclaim quietly.
            Task { await AgentDownloadScratch.shared.discard(item) }
            return
        }
        #if os(iOS)
        // Replacing an on-screen preview: the old file is safe to reclaim (the
        // full-screen QLPreviewController is done with it once swapped). macOS
        // leaves a replaced file to the age sweep — "Open with" may hold it.
        if let old = currentItem {
            Task { await AgentDownloadScratch.shared.discard(old) }
        }
        #endif
        currentItem = item
        previewURL = item.url
    }

    /// The user dismissed the preview (the modifier nil'd the binding). iOS
    /// reclaims immediately — share / Save-to-Files copy before dismissal.
    /// macOS leaves the file to the age sweep: the panel's "Open with <app>"
    /// hands the target app the live path, so deleting here would yank it.
    func handleDismiss() {
        #if os(iOS)
        if let item = currentItem {
            Task { await AgentDownloadScratch.shared.discard(item) }
        }
        #endif
        currentItem = nil
    }
}

// MARK: - Notification name (scroll-to-bottom badge tap)

extension Notification.Name {
    static let scrollThreadToBottom = Notification.Name("scrollThreadToBottom")
}
