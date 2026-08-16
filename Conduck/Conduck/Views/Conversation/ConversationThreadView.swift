// SPDX-License-Identifier: Apache-2.0

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

    /// Whether the scene hosting this thread is the one the user is actually
    /// looking at. Read ONLY by `acknowledgeVisibleFailure` — a thread mounted
    /// in a backgrounded window or an inactive iPad scene must not retire a
    /// failure mark for an error nobody saw.
    @Environment(\.appearsActive) private var appearsActive

    /// The host-owned Settings VM, borrowed for ONE thing: the "Review file
    /// setup" route out of the output-discovery fault row. Passed in rather than
    /// minted here because every host already owns a stable instance, and the
    /// file-transfer editor is a buffered editor whose unsaved-changes state
    /// must not be duplicated across two live view models.
    let settingsVM: SettingsViewModel

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
    /// The gateway the user picked while this thread ends on an un-replied turn
    /// — held (not acted on) until they say whether to send that turn there.
    /// Non-nil IS the dialog's presentation state, so dismissing clears it and
    /// nothing is cloned: Cancel has to mean nothing happened, which is only
    /// true while the clone is still ahead of the question.
    @State private var pendingCloneTarget: RemoteAgentRef?

    /// Shared speaker (one synthesizer for the whole thread; restarting a new
    /// utterance stops the prior one cleanly). The cross-platform `ThreadSpeaker`
    /// state machine, backed by the iOS/macOS `ReplyVoice` speak engine.
    @State private var speaker = ThreadSpeaker(engine: ReplyVoice())

    /// 1.5 s checkmark flip after the toolbar "Copy conversation" tap —
    /// mirrors `MessageBubble.didCopy`.
    @State private var didCopyAll = false

    /// The terminal spoken-voice refusal behind the current built-in-voice
    /// fallback, until the user dismisses it (`.spokenReplyVoiceRefused`).
    /// EPHEMERAL and view-local, exactly like `usedFallbackVoice`: it describes
    /// one playback attempt on one device, so nothing about it belongs in the
    /// store or in sync.
    @State private var voiceRefusal: AppError?

    /// ONE Quick Look presenter for the whole thread — deliberately NOT
    /// per-chip: macOS `QLPreviewPanel` is application-shared and
    /// responder-chain controlled, so row-local presenters inside the
    /// recycling `LazyVStack` would compete for it (and scrolling could
    /// destroy the row that owns the active preview). Chips materialize their
    /// file (server chips download; inline text chips write the locally-stored
    /// bytes) and hand the adopted scratch file up here; the latest tap wins.
    @State private var filePreview = FilePreviewCoordinator()

    /// The file-transfer setup sheet, opened from an output-discovery fault row.
    /// Owned HERE and not per row, exactly like `filePreview`: the rows live in
    /// a recycling `LazyVStack`, so a row-owned sheet would be torn down by a
    /// scroll while presented.
    @State private var showingFileSetup = false

    /// The type-refusal review sheet, keyed on the turn whose entries it shows.
    /// Owned HERE for the same reason as the two above, and NOT by the row that
    /// opens it: a row-owned sheet inside the recycling `LazyVStack` is torn
    /// down by a scroll while presented.
    ///
    /// ITEM-DRIVEN rather than an `isPresented` flag beside a separate payload:
    /// the payload IS the presentation state, so dismissing cannot leave one
    /// turn's entries behind for the next tap to flash before it re-renders.
    @State private var reviewingRefusals: OutputRefusalReview?

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
                // The reply WAS spoken (in the built-in voice) — so this
                // explains, it never blocks, and it stays until dismissed.
                if let voiceRefusal {
                    voiceRefusalBanner(voiceRefusal)
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .spokenReplyVoiceRefused)) { note in
            guard let code = note.userInfo?[SpokenReplyVoiceRefusal.errorCodeKey] as? Int else { return }
            voiceRefusal = AppError.from(errorCode: code, message: nil)
        }
        .sheet(isPresented: $vm.showingGatewaySheet) {
            gatewayLockSheet
        }
        // "Review file setup" from an output-discovery fault row. A SHEET, not a
        // navigation push: a mid-conversation diagnostic must let the user peek
        // at the setup and land back in the thread, never eject them into
        // Settings (same reasoning as `TroubleshootButton`). On dismiss the
        // lane identity is re-resolved, so a repointed or removed server retires
        // its fault rows immediately rather than on the next unrelated reload.
        .sheet(isPresented: $showingFileSetup, onDismiss: {
            Task { await viewModel.refreshFileLaneDerivedState() }
        }) {
            if let ref = viewModel.boundRef {
                NavigationStack {
                    // Cancel/Save chrome comes from the content's
                    // `bufferedEditorChrome` — no host Done button.
                    FileTransferSetupGuideView(
                        viewModel: settingsVM,
                        ref: ref,
                        titleOverride: settingsVM.displayName(for: ref),
                        context: .settings
                    )
                }
                .frame(minWidth: 520, minHeight: 600)
            }
        }
        // "Review file…" from a held-back row: what the folder held that Conduck
        // does not open on its own, and the one way to get it anyway. A SHEET
        // for the same reason the setup route is one — a mid-conversation
        // diagnostic must land the user back in the thread.
        // NO `NavigationStack` around it, unlike the setup sheet above: this one
        // carries its own title and its own Done, exactly as `CertificateTrustSheet`
        // does, so a navigation container would only add an empty bar above copy
        // that already says what the sheet is.
        .sheet(item: $reviewingRefusals) { review in
            OutputRefusalReviewSheet(
                entries: review.entries,
                boundRef: viewModel.boundRef,
                expectedLaneID: review.laneID
            )
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
            // The acknowledgement seam. Opening the thread IS the act of
            // looking at it, so it stamps the device-local read marker (which
            // un-bolds its list row) and retires any banner still sitting in
            // Notification Center pointing here.
            markThreadViewed()
            acknowledgeVisibleFailure()
            NotificationDeepLink.clearDelivered(for: viewModel.conversationID)
            // Clone continuation: claimed only AFTER the line above, so the
            // reply that comes back is suppressed as an on-screen thread rather
            // than banner-and-sound at a user already reading it.
            claimCloneContinuation()
            #if os(iOS)
            // Auto-speak hook 1/3: the deep-link navigation just mounted this
            // thread (warm launch — messages typically already loaded). The
            // cold-launch ordering (mounted before the fetch lands) is hook 2's
            // job in `handleMessageCountChange`.
            attemptAutoSpeak()
            #endif
        }
        // A reply landing while the user is READING must never light the row
        // they are looking at, so re-stamp on every new tail. Keyed on the tail
        // id rather than the count: a cold-launch fetch replaces the whole array
        // without necessarily growing it.
        .onChange(of: viewModel.messages.last?.id) { _, _ in
            markThreadViewed()
            acknowledgeVisibleFailure()
        }
        // A send failing under the user's eyes flips the tail's STATUS without
        // changing its id, so neither hook above fires for it. Without this, the
        // one row the user is already staring at is the one that goes red.
        .onChange(of: viewModel.messages.last?.status) { _, _ in
            acknowledgeVisibleFailure()
        }
        // Coming BACK to a window that was inactive when the failure landed. The
        // gate above rejected it then; the user is looking at the error now, so
        // this is the moment it counts as seen. Without this arm the mark would
        // survive until the thread was navigated away from and re-entered.
        .onChange(of: appearsActive) { _, isActive in
            if isActive { acknowledgeVisibleFailure() }
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
                    // Deliberately the CLAIM, not `showsGatewayWaitIndicator`:
                    // this suppresses the empty-thread hint from the instant a
                    // send is claimed, so a first turn on macOS can't flash the
                    // empty state during the pre-dispatch window. Don't "fix"
                    // this to match the rows below it.
                    if viewModel.messages.isEmpty && !viewModel.isAwaitingReply
                        && viewModel.hasLoadedInitialMessages {
                        emptyThreadHint
                    }

                    ForEach(viewModel.messages) { message in
                        MessageBubble(
                            message: message,
                            showsGatewayWaitIndicator: viewModel.showsGatewayWaitIndicator,
                            boundRef: viewModel.boundRef,
                            speakState: speaker.speakState(for: message.id),
                            usedFallbackVoice: speaker.usedFallbackVoice(for: message.id),
                            showsOutputDiscoveryFault: viewModel.outputDiscoveryFaultIDs.contains(message.id),
                            showsUnnamedFolderFault: viewModel.outputFolderUnnamedIDs.contains(message.id),
                            outputRecheckState: viewModel.outputRecheckStates[message.id],
                            canRecheckOutputs: ConversationDetailViewModel.canRecheckOutputs(message),
                            canSearchMentionedFiles: ConversationDetailViewModel
                                .canSearchMentionedFiles(message),
                            awaitsCloneContinuation: awaitsCloneContinuation(message),
                            filePreview: filePreview,
                            onCopy: { viewModel.copy(message) },
                            onSpeak: { speaker.speak(message.text, messageID: message.id) },
                            onRetry: { Task { await viewModel.retry(message) } },
                            onResendWithoutPhoto: { Task { await viewModel.resendWithoutPhoto(message) } },
                            onKeepChattingWithoutPhotos: { Task { await viewModel.enableHideEarlierPhotos() } },
                            onRecheckOutputs: { Task { await viewModel.recheckOutputs(for: message) } },
                            onSearchMentionedFiles: { Task { await viewModel.searchMentionedFiles(for: message) } },
                            onOpenFileSetup: { showingFileSetup = true },
                            // The payload is derived HERE, from the record, so
                            // the row hands over an intent and never a snapshot
                            // it might have taken a repaint ago. The failable
                            // init is what keeps a turn with nothing to review
                            // from presenting an empty sheet.
                            onReviewHeldBack: { reviewingRefusals = OutputRefusalReview(message: message) }
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

                    // Gated on the DISPATCH flag, never on `isAwaitingReply`:
                    // on macOS the latter is claimed several awaits before the
                    // user's turn is written, which rendered this row ABOVE the
                    // bubble that provoked it. The pre-dispatch window is
                    // carried by the user bubble's own sending dot instead.
                    if viewModel.showsGatewayWaitIndicator {
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
            .onChange(of: viewModel.showsGatewayWaitIndicator) { _, awaiting in
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
                // macOS: NON-animated (see showsGatewayWaitIndicator above) — animated scroll
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

    /// Stamp the device-local "last looked at" marker for this thread.
    ///
    /// `lastActivityAt` is the newest bubble's stamp rather than `Date()` alone:
    /// message timestamps are local wall clock, so a reply mirrored from a
    /// device whose clock runs a little ahead would otherwise stay "newer than
    /// the marker" and keep its own row lit while the user reads it. The store
    /// clamps anything implausibly far ahead, so a badly-skewed device costs a
    /// stuck dot rather than silence.
    ///
    /// CAVEAT, benign and deliberate: on macOS a background window keeping a
    /// thread mounted marks it viewed. The menu-bar dot uses the stricter
    /// `appearsActive`-gated window report, so the more urgent cue is unaffected.
    private func markThreadViewed() {
        ReadStateStore.shared.markViewed(
            viewModel.conversationID,
            lastActivityAt: viewModel.messages.last?.createdAt
        )
    }

    /// Stamp the device-local "I have seen this thread's failure" marker, which
    /// is what retires the list row's red mark.
    ///
    /// A SEPARATE marker from `markThreadViewed`, and separately gated, because
    /// the read marker is stamped the instant the user's own message appears —
    /// before the send that will fail has failed. Reusing it would suppress the
    /// red mark for everything sent from the composer. See the `ReadStateStore`
    /// header.
    ///
    /// GATED ON THE TAIL, which is exact rather than an approximation: the list
    /// paints `.failed` only while the newest failed turn is still the
    /// conversation's last activity, which means it IS the tail. So this needs
    /// no store aggregate of its own and cannot drift from what the list shows.
    ///
    /// Mirrors `deliveryErrorRow`'s own suppression: a turn awaiting its clone
    /// continuation shows no error row here, so there is nothing for the user to
    /// have seen, and acknowledging it would retire a mark for an error the
    /// thread deliberately withheld.
    ///
    /// GATED ON `appearsActive`, unlike `markThreadViewed`, and the difference
    /// is deliberate. That method documents its background-window caveat as
    /// benign BECAUSE the menu-bar dot answers through the stricter
    /// `appearsActive` report, so the urgent cue survives. For the failure mark
    /// there is no second surface to fall back on — the list row is the only
    /// one — so a thread merely MOUNTED in a backgrounded window must not
    /// retire it. Same rule `WindowThreadVisibilityReporter` applies: a reply
    /// (or a failure) landing where nobody is looking has not been seen.
    private func acknowledgeVisibleFailure() {
        guard appearsActive,
              let tail = viewModel.messages.last,
              tail.role == "user",
              tail.status == "failed",
              !awaitsCloneContinuation(tail) else { return }
        ReadStateStore.shared.markFailureSeen(
            viewModel.conversationID,
            failedAt: tail.createdAt
        )
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
            // macOS: NON-animated (see `.onChange(of: showsGatewayWaitIndicator)`) — a reply
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

            // Shared resolver, so an unresolved gateway name falls back to a
            // bare "Answering…" rather than rendering " is answering…".
            Text(ThinkingIndicator.label(
                phase: .answering,
                backendName: viewModel.backendDisplayName
            ))
                .font(.callout)
                .foregroundStyle(AppColors.textSecondary)

            TimelineView(.periodic(from: .now, by: 1)) { context in
                // `liveTurnStartedAt`, not this instance's own stamp: the row
                // above renders for any turn live on this device, including one
                // a sibling VM, the background session, CarPlay or the share
                // drainer dispatched. Reading the stored stamp would map those
                // to `nil` → 0, so the `elapsed > 3` branch never fired and a
                // re-minted thread showed the words with no clock beside them.
                let elapsed = viewModel.liveTurnStartedAt.map {
                    context.date.timeIntervalSince($0)
                } ?? 0
                if elapsed > 3 {
                    Text(ThinkingStage.clock(max(0, elapsed)))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(AppColors.textTertiary)
                        .transition(.opacity)
                }
            }
            // Hidden from VoiceOver: the clock's text changes every second, and
            // an accessible label that rewrites itself on a timer produces a
            // stream of repeated announcements over the whole wait. The label
            // beside it already says a reply is in flight.
            .accessibilityHidden(true)

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
        .primaryCTAButton()
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
            .inlineLinkButton()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .transition(.opacity)
    }

    /// Quiet notice for a reply that was read aloud in the BUILT-IN voice
    /// because the chosen voice endpoint refused the request terminally. Muted
    /// chrome, not `AppColors.error`: nothing failed for the user — they heard
    /// their reply — but a refusal a retry cannot change would otherwise repeat
    /// on every reply with no explanation anywhere. Carries the cause AND the
    /// remedy, because this notice is the only place either appears: an
    /// untrusted certificate is fixed on the SERVER, and a pinned key that
    /// disagreed with a chain the system trusted warns that the connection may
    /// be intercepted.
    private func voiceRefusalBanner(_ error: AppError) -> some View {
        VStack(spacing: 6) {
            Text(LocalizedStringResource(
                "thread.voiceRefused.banner",
                defaultValue: "Read aloud in the built-in voice."))
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppColors.textSecondary)
            // No ref: this is a VOICE endpoint's refusal, not the gateway's,
            // so a gateway lane's capability would pick the wrong remedy.
            Text(verbatim: error.descriptionWithRecovery())
                .font(.caption2)
                .foregroundStyle(AppColors.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                voiceRefusal = nil
            } label: {
                Text(LocalizedStringResource(
                    "thread.voiceRefused.dismiss", defaultValue: "Dismiss"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppColors.brandAmber)
            }
            .inlineLinkButton()
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
            // Which gateway failed, and from where. With several gateways
            // configured, "your personal AI" doesn't identify anything, and a
            // failure that came off the wrist or the car looks identical to one
            // from this device.
            //
            // UI-ONLY: the real gateway name must never reach the pasteable
            // diagnostic report, which anonymises customs to `custom-gateway#N`.
            // It is safe here because this view is not a source for `copyBlock()`
            // — nothing renders into `checks`, `DiagnosticsFocus`, or any `fact*`.
            if let attribution = sendErrorAttribution {
                Text(attribution)
                    .font(.caption2)
                    .foregroundStyle(AppColors.textTertiary)
                    .multilineTextAlignment(.center)
            }
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

    /// "Home VPS" or "Home VPS · Watch" — the bound gateway, plus the originating
    /// surface when it was somewhere other than the device in the user's hands.
    ///
    /// The surface is named ONLY for the Watch and CarPlay. Those are the two
    /// places where a failure the user is now reading about happened somewhere
    /// else entirely, which is genuinely disorienting. Echoing "iPhone" back at
    /// someone holding an iPhone adds nothing, and `unknown` (the legacy/nil
    /// fallback) would be noise.
    private var sendErrorAttribution: String? {
        let gateway = viewModel.backendDisplayName
        guard !gateway.isEmpty else { return nil }
        guard let failedID = viewModel.sendErrorMessageID,
              let raw = viewModel.messages.first(where: { $0.id == failedID })?.sourceDevice,
              case let base = MessageRowFormatters.baseDevice(from: raw),
              base == "watch" || base == "carplay"
        else {
            // Pre-flight failures carry no message row, and same-device failures
            // need no surface — the gateway name alone is the useful half.
            return gateway
        }
        return "\(gateway) · \(MessageRowFormatters.label(forDevice: base))"
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
            .onAppear {
                showingCloneTargets = false
                pendingCloneTarget = nil
            }
            .confirmationDialog(
                Text(cloneSendPromptTitle),
                isPresented: Binding(
                    get: { pendingCloneTarget != nil },
                    set: { if !$0 { pendingCloneTarget = nil } }
                ),
                titleVisibility: .visible,
                // `presenting` (not a read of the state inside the action) —
                // SwiftUI holds this value for the presentation's lifetime, so
                // the chosen gateway survives the dismissal that clears the
                // binding on its way to running the action.
                presenting: pendingCloneTarget
            ) { ref in
                Button(LocalizedStringResource(
                    "thread.clone.sendLast.send", defaultValue: "Send now"
                )) {
                    cloneTo(ref, continueImmediately: true)
                }
                Button(LocalizedStringResource(
                    "thread.clone.sendLast.later", defaultValue: "Just clone"
                )) {
                    cloneTo(ref, continueImmediately: false)
                }
                Button(LocalizedStringResource(
                    "thread.clone.sendLast.cancel", defaultValue: "Cancel"
                ), role: .cancel) { }
            } message: { _ in
                Text(LocalizedStringResource(
                    "thread.clone.sendLast.body",
                    defaultValue: "Your last message hasn't been answered yet. If you just clone, it stays in the chat and goes along with your next message."
                ))
            }
        }
    }

    /// Title for the send-the-last-turn question, naming the gateway the user
    /// picked. Falls back to the un-named phrasing rather than an empty
    /// interpolation for the frame between the state clearing and the dialog
    /// finishing its dismissal, where the title is still read but the target
    /// is already gone.
    private var cloneSendPromptTitle: String {
        guard let ref = pendingCloneTarget else {
            return String(localized: "thread.clone.sendLast.title.generic",
                          defaultValue: "Send the last message there?")
        }
        return String(
            format: String(localized: "thread.clone.sendLast.title",
                           defaultValue: "Send the last message on %@?"),
            RemoteAgentRefMetadata.displayName(for: ref, customs: viewModel.customGateways)
        )
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
        .choiceCardButton(cornerRadius: 10)
    }

    private func cloneButton(_ ref: RemoteAgentRef) -> some View {
        let name = RemoteAgentRefMetadata.displayName(for: ref, customs: viewModel.customGateways)
        let color = RemoteAgentBadgePalette.color(for: ref, customs: viewModel.customGateways)
        return Button {
            // A thread ending on an un-replied turn poses a real question the
            // app can't answer for the user: send it on the new gateway now, or
            // let it wait. Everything else clones straight through — asking
            // when there is nothing to send would be a prompt with one answer.
            if viewModel.hasUnansweredTrailingTurn {
                pendingCloneTarget = ref
            } else {
                cloneTo(ref, continueImmediately: false)
            }
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
        .choiceCardButton(cornerRadius: 10)
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
                .inlineLinkButton()
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
    private func cloneTo(_ ref: RemoteAgentRef, continueImmediately: Bool) {
        Task {
            let newID = await viewModel.cloneConversation(
                to: ref, continueImmediately: continueImmediately)
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

    // MARK: - Clone continuation

    /// True while `message` is a cloned trailing turn whose first delivery has
    /// not been attempted yet — armed (before `.onAppear` claims it) or claimed
    /// and in flight. The answer is SHARED, not per-view, so a second window on
    /// the same conversation cannot render a Try Again for a turn this one is
    /// already dispatching.
    private func awaitsCloneContinuation(_ message: MessageRecord) -> Bool {
        PendingCloneContinuation.shared.isSuppressed(
            conversationID: viewModel.conversationID,
            messageID: message.id
        )
    }

    /// Claim this thread's pending clone continuation, if any, and fire it once.
    ///
    /// Prefers the VM's already-loaded messages and falls back to the store: on
    /// a cold launch this view can mount before the initial fetch lands, and
    /// `retry` needs only the record itself (it re-reads everything else and
    /// reloads afterwards). No polling, no ordering assumption.
    private func claimCloneContinuation() {
        let conversationID = viewModel.conversationID
        guard let messageID = PendingCloneContinuation.shared
            .take(conversationID: conversationID) else { return }
        Task {
            // Cleared however this ends — including the not-found arm below. A
            // suppression that outlived its attempt would hide the delivery row
            // (and its Try Again) for a turn nothing is going to deliver.
            defer { PendingCloneContinuation.shared.finish(conversationID: conversationID) }
            var record = viewModel.messages.first { $0.id == messageID }
            if record == nil {
                record = try? await ConversationStore.shared
                    .fetchMessages(for: conversationID)
                    .first { $0.id == messageID }
            }
            guard let record else { return }
            await viewModel.retry(record)
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
/// when the parent `MessageBubble` rebuilds for unrelated state (`showsGatewayWaitIndicator`,
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
            // Reply text is untrusted: markup attachment URLs are refused (so a
            // `![](https://…)` in an answer can never originate a fetch) and a
            // link tap only reaches the system for a web/mail scheme — any other
            // scheme shows its real destination and asks first, because the link
            // text is the agent's to choose. See MarkdownAttachmentPolicy.swift.
            .appliesUntrustedMarkdownPolicy()
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
    /// True once the turn has reached its gateway dispatch phase. When true, the
    /// per-message `sending` spinner is suppressed so the borderless thread
    /// "answering…" indicator is the SOLE in-flight signal (Retry on failure is
    /// unaffected). Deliberately NOT the VM's `isAwaitingReply`: that is claimed
    /// several awaits earlier on macOS, which would suppress this dot for the
    /// entire pre-dispatch window — exactly the window it exists to cover.
    let showsGatewayWaitIndicator: Bool
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
    /// This reply's output folder could not be READ — the only discovery outcome
    /// the user is told about. An empty or absent folder is the ordinary shape of
    /// a reply that produced nothing and shows no row at all. Derived by the VM,
    /// never persisted and never computed here.
    let showsOutputDiscoveryFault: Bool
    /// This turn went out with NO output folder because the configured file lane
    /// stopped settling the pre-dispatch freshness check — which covers a lane
    /// that answers unhelpfully every bit as much as one that has gone silent.
    /// MUTUALLY EXCLUSIVE with
    /// `showsOutputDiscoveryFault` by construction — that one needs a folder to
    /// have failed to read, this one needs there to have been no folder — and
    /// the two are separate flags rather than one enum because they make
    /// opposite claims about what is on the user's server.
    let showsUnnamedFolderFault: Bool
    /// Outcome of the user's last manual look at this turn, if any.
    let outputRecheckState: ConversationDetailViewModel.OutputRecheckState?
    /// Whether this turn has an output folder a tap could re-read. False for a
    /// wrist-originated turn and for a lane that cannot hold a nested collection
    /// — those keep the name search and lose only the folder re-read.
    let canRecheckOutputs: Bool
    /// Whether this turn has a file lane the name search could probe. False for
    /// every turn sent with no file server configured — the majority
    /// configuration — where the search verb would answer a tap with nothing at
    /// all. Derived by the VM from the same fields its handler guards on.
    let canSearchMentionedFiles: Bool
    /// This turn is a freshly cloned trailing turn whose automatic continuation
    /// has not been attempted yet. The row is genuinely `failed` in the store —
    /// the correct fail-safe if the dispatch never happens — but "No reply / this
    /// message wasn't delivered" would be a lie in the window before the first
    /// delivery is even attempted, so the delivery row waits. Suppression ends
    /// the moment the claim resolves: a continuation that really fails shows the
    /// row with its real verdict.
    let awaitsCloneContinuation: Bool
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
    /// Re-read this turn's output folder on demand ("Check again").
    let onRecheckOutputs: () -> Void
    /// Probe the filenames this reply mentioned, at the served root ("Search
    /// mentioned files") — the tail recovery for a gateway that ignored the
    /// folder it was given.
    let onSearchMentionedFiles: () -> Void
    /// Open the bound gateway's file-transfer setup ("Review file setup").
    let onOpenFileSetup: () -> Void
    /// Open the review sheet for this turn's type-refused entries ("Review
    /// file…"). Routed to the THREAD ROOT and never presented from here: these
    /// rows live in a recycling `LazyVStack`, so a row-owned sheet is torn down
    /// by a scroll while presented (same reasoning as `filePreview` and
    /// `showingFileSetup`).
    let onReviewHeldBack: () -> Void

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
    /// `Hashable` so its `==` covers text/status/attachments — and the persisted
    /// output census with them, which is why the held-back row needs no arm of
    /// its own here and no view-model state behind it.
    static func == (lhs: MessageBubble, rhs: MessageBubble) -> Bool {
        lhs.message == rhs.message
            && lhs.showsGatewayWaitIndicator == rhs.showsGatewayWaitIndicator
            && lhs.boundRef == rhs.boundRef
            && lhs.speakState == rhs.speakState
            && lhs.usedFallbackVoice == rhs.usedFallbackVoice
            && lhs.showsOutputDiscoveryFault == rhs.showsOutputDiscoveryFault
            && lhs.showsUnnamedFolderFault == rhs.showsUnnamedFolderFault
            && lhs.outputRecheckState == rhs.outputRecheckState
            && lhs.canRecheckOutputs == rhs.canRecheckOutputs
            && lhs.canSearchMentionedFiles == rhs.canSearchMentionedFiles
            && lhs.awaitsCloneContinuation == rhs.awaitsCloneContinuation
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
        VStack(alignment: isUser ? .trailing : .leading, spacing: 6) {
            bubbleRow
            if isUser, message.status == "failed", !awaitsCloneContinuation {
                deliveryErrorRow
            }
            // A POSITIVE FINDING, so it is a SIBLING of the fault chain below
            // rather than a fourth arm of it. That chain's arms are disjoint by
            // construction — one needs a folder that failed a read, the other
            // needs there to have been no folder — and this row is disjoint from
            // NEITHER: a turn whose listing recorded a refusal can later fail a
            // re-read, and both sentences stay true at once. Stacking is the
            // honest shape; an `else if` would silently drop whichever claim
            // lost the ordering.
            //
            // FIRST, nearest the bubble, because it is the only row here that
            // reports something the reply actually produced and the only one
            // whose action ends in a file. The fault rows report an inability,
            // which is the weaker claim, so they sit further out. Never more
            // than these two.
            if !isUser {
                outputHeldBackRow
            }
            // Handback diagnostic: sits UNDER the agent bubble, outside its
            // background — device-local metadata about THIS turn's delivery,
            // never a fabricated assistant bubble and never part of outbound
            // history. Same structural place the failed-turn row occupies on
            // the user side.
            if !isUser, showsOutputDiscoveryFault {
                outputDiscoveryFaultRow
            } else if !isUser, showsUnnamedFolderFault {
                // Ordered AFTER the read-fault row purely as a formality: the
                // two sets are disjoint by construction (one requires a folder,
                // the other requires none), and an `if/else` chain makes that
                // unrepresentable rather than merely unlikely.
                unnamedFolderFaultRow
            } else if !isUser {
                // The progress + verdict of a manual look on a turn with no fault
                // row to carry it — the common path, since a fault row is rare.
                // Without this a tap from the footer menu would report nothing at
                // all.
                outputLookStatusLine
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
                                messageID: message.id,
                                boundRef: boundRef,
                                expectedLaneID: isUser
                                    ? message.fileTransferLaneID
                                    : message.outputScanLaneID,
                                // Only an AGENT chip has a box to have come out
                                // of; a user chip is a file this device uploaded
                                // and needs no provenance hedge.
                                outputBoxKey: isUser ? nil : message.outputBoxKey,
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

                footerWithOutputActions
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
                || message.attachments.contains { $0.isText || $0.isServerFile },
            // The rule itself lives on `WordlessTurn` so it can be tested; note
            // it counts EVERY attachment, unlike `turnHasOwnImages` above.
            wordlessTurn: .of(text: message.text, attachmentCount: message.attachments.count),
            // The row's body is the failure's own remedy, so it has to know
            // which AI refused — the same binding the retry would re-fire at.
            ref: boundRef
        )
    }

    /// Persistent inline error row under a failed user turn: outcome + safe
    /// cause + REMEDY + the actions that can still change the outcome. Frozen
    /// copy via `DeclinedTurnPresentation`; vocabulary is "gateway", never
    /// "model". "Try again" is gated on `presentation.offersRetry` — a terminal
    /// refusal keeps its explanation and loses only the button that could never
    /// have honoured it.
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
            // A FOOTNOTE, and tertiary rather than the body's secondary for that
            // reason: the body is what the gateway's verdict supports, this is
            // something only the client knows about its own request. Quieter is
            // the whole containment — it must never read as the diagnosis.
            if let hint = presentation.hint {
                Text(hint)
                    .font(.caption2)
                    .foregroundStyle(AppColors.textTertiary)
                    .multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // Actions stack vertically (trailing) — the photo-recovery labels
            // are long, and a horizontal row overflows the narrow popover.
            VStack(alignment: .trailing, spacing: 6) {
                if presentation.offersRetry {
                    Button(action: onRetry) {
                        HStack(spacing: 3) {
                            Image(systemName: "arrow.clockwise")
                            Text(LocalizedStringResource("declinedTurn.action.tryAgain", defaultValue: "Try again"))
                        }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AppColors.error)
                    }
                    .inlineLinkButton()
                }
                if presentation.offersResendWithoutPhoto {
                    Button(action: onResendWithoutPhoto) {
                        Text(LocalizedStringResource("declinedTurn.action.resendWithoutPhoto", defaultValue: "Resend without photo"))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(AppColors.brandAmber)
                    }
                    .inlineLinkButton()
                }
                if presentation.offersKeepChattingWithoutPhotos {
                    Button(action: onKeepChattingWithoutPhotos) {
                        Text(LocalizedStringResource("declinedTurn.action.keepChatting", defaultValue: "Keep chatting without photos"))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(AppColors.brandAmber)
                    }
                    .inlineLinkButton()
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
        // Title carries no terminal period, the body and hint both do — hence the
        // explicit ". " after the title and a plain space before the hint.
        .accessibilityLabel(Text(verbatim: "\(presentation.title). \(presentation.body)"
            + (presentation.hint.map { " \($0)" } ?? "")))
    }

    // MARK: - Held-back row (what this reply's output folder kept)

    /// Standing row under an agent turn whose output folder was READ and held
    /// something it did not hand over — a name whose type Conduck does not open
    /// on its own, a name Conduck will not repeat, or a deliverable a budget
    /// left behind.
    ///
    /// AUTOMATIC, WITH NO TAP, because the alternative already shipped and was
    /// worse: an entry the app would not open was exactly as invisible as an
    /// empty folder, and the only user who ever learned otherwise was one who
    /// happened to tap "Check again" and read a count that died with the
    /// process.
    ///
    /// IT NAMES THE FILE (in the single case), and the licence for that is
    /// structural rather than a judgement. The extension test is the LAST guard
    /// in `FileServerClient.outboxEntryVerdict`, so an entry that reaches it has
    /// already cleared the single-path-component test, the Unicode accept-list,
    /// the leading-dot / leading-dash / whitespace / combining-mark tests and
    /// both length budgets. The name is therefore exactly as safe to render as a
    /// delivered chip's label — same name, same guards, one test further on. A
    /// SHAPE refusal never reaches a name-bearing surface anywhere in this app;
    /// its whole presentation is the count on one of the lines below.
    ///
    /// WARNING-TINTED, NOT ERROR-TINTED. Nothing failed: the server answered,
    /// the folder was read, the files are there. What happened is that Conduck
    /// declined to open something on its own — a policy, stated out loud.
    /// `AppColors.error` stays reserved for the delivery-error row, where the
    /// message genuinely did not land.
    ///
    /// DELIBERATELY NOT CHIP-SHAPED. A chip means "tap and this file opens", and
    /// this row means the opposite — hence radius 12 rather than 10, the full
    /// row measure rather than 220pt, a warning wash and stroke where a chip has
    /// a flat card fill and none, a warning triangle rather than the type-tinted
    /// file glyph, no `square.and.arrow.down`, and no size caption under the
    /// name (the size lives in the sheet, where it is metadata rather than a
    /// promise).
    ///
    /// The row is NOT one big button, and that is a consequence of it carrying
    /// up to two verbs: a sheet ("Review file…") and a server re-read ("Check
    /// again"). It therefore takes the fault rows' action-strip shape and their
    /// `.contain` accessibility treatment, which is what `.contain` is for —
    /// several independently focusable children inside one group.
    /// This turn's settled census of what its folder held and did not hand over,
    /// or nil when there is nothing standing to say. READ OFF THE RECORD, with
    /// no view-model state behind it: the census is a field on the row, and a
    /// bubble already repaints when its own `MessageRecord` compares unequal, so
    /// a changed census repaints for free and can never outlive its row.
    private var heldBackOutcome: OutputDeliveryOutcome? {
        ConversationDetailViewModel.outputDeliveryRow(for: message)
    }

    /// Whether the held-back row is the one that reports an in-flight look.
    ///
    /// EXACTLY ONE ROW UNDER A BUBBLE MAY, and that is why this is a rule rather
    /// than three independent `== .checking` tests: two "Checking…" indicators
    /// stacked one above the other read as two separate requests against the
    /// user's home server, when there is only ever one. The read-fault row wins
    /// when it is up — it is the row whose own verb started most of these looks
    /// — this row takes it otherwise, and `outputLookStatusLine` speaks only
    /// when neither row is present. (The folder-less row never competes: it
    /// requires no `outputBoxKey`, and this row requires one.)
    private var heldBackOwnsBusyIndicator: Bool {
        outputRecheckState == .checking && !showsOutputDiscoveryFault
    }

    @ViewBuilder
    private var outputHeldBackRow: some View {
        if let outcome = heldBackOutcome {
            let rescues = OutputTypeRefusal.rescuableEntries(in: message)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 5) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(AppColors.warning)
                    Text(LocalizedStringResource(
                        "thread.outputs.heldBack.title",
                        defaultValue: "Not everything came back"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AppColors.textSecondary)
                }
                heldBackLines(outcome, rescues: rescues)
                heldBackActions(outcome, rescues: rescues)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(AppColors.warning.opacity(0.10))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(AppColors.warning.opacity(0.35), lineWidth: 1)
            )
            .frame(maxWidth: 520, alignment: .leading)
            .accessibilityElement(children: .contain)
        }
    }

    /// One line per POPULATION, and only the ones that are non-zero. They are
    /// different facts about the same folder — a type Conduck does not open, a
    /// name it will not repeat (in two classes, which are two different
    /// sentences), and a deliverable a budget left behind — and each one carries
    /// its own count, because a single total would let the user read a shape
    /// refusal as something they could go and rescue.
    ///
    /// Each sentence is written so the noun phrase carries the inflection and
    /// the verb does not, which is what lets one string be grammatical at both
    /// counts (the shipped "held ^[N file](inflect: true) Conduck can't hand
    /// over" is the same construction).
    @ViewBuilder
    private func heldBackLines(
        _ outcome: OutputDeliveryOutcome,
        rescues: [OutputTypeRefusal]
    ) -> some View {
        // Resolved ONCE, before any sentence is chosen: every line in the type
        // arm has to agree about which of its numbers today's code can still
        // observe, and re-deriving that per line is how they drift apart.
        let claimed = OutputHeldBackCopy.claimedTypeCount(outcome, stillRefused: rescues.count)
        VStack(alignment: .leading, spacing: 4) {
            if outcome.typeRefusedCount > 0 {
                // Nothing to count is not the same as nothing to say — a
                // widening can leave the row with no provable number at all, and
                // the closing line below is what still speaks for that case.
                if claimed > 0 {
                    Text(LocalizedStringResource(
                        "thread.outputs.heldBack.type",
                        defaultValue: "The folder held ^[\(claimed) file](inflect: true) Conduck doesn't open on its own."))
                        .font(.caption2)
                        .foregroundStyle(AppColors.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    // THE NAME on a single refusal, nothing on several. One name
                    // is the whole answer; five stacked names are a list, and a
                    // list belongs in the sheet where each entry gets its own
                    // reason and its own action.
                    //
                    // BOTH COUNTS, because a name may only stand for the number
                    // the line above just printed. A census that counted three
                    // and kept one name prints the three and no name — one name
                    // under a claim of three reads as the whole population, and
                    // the capped line below is what explains that gap instead.
                    if claimed == 1, rescues.count == 1, let only = rescues.first {
                        Text(only.name)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(AppColors.textPrimary)
                            .lineLimit(1)
                            // MIDDLE, not tail: the extension is what this row is
                            // about, and tail truncation eats it first.
                            .truncationMode(.middle)
                    }
                    // The census counts the WHOLE folder; the record retains a
                    // bounded offer. When they disagree the sheet would silently
                    // show fewer files than the line above just claimed, so say
                    // so rather than let the user count.
                    //
                    // ONLY WHEN THE CAP IS WHAT BIT — the whole of that judgement
                    // lives in `blamesRetentionCap`, so it can be asserted
                    // rather than merely read.
                    if OutputHeldBackCopy.blamesRetentionCap(
                        outcome, stillRefused: rescues.count) {
                        Text(LocalizedStringResource(
                            "thread.outputs.heldBack.type.capped",
                            defaultValue: "Review lists the first ^[\(rescues.count) file](inflect: true)."))
                            .font(.caption2)
                            .foregroundStyle(AppColors.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                // NEVER A NUMBER WITH NOTHING BESIDE IT. With no rescuable name
                // there is no name under the count and no "Review files…" beside
                // it, so without this line the type arm states a bare figure and
                // offers neither a verb nor a reason — the dead end this whole
                // surface exists to remove.
                //
                // TWO STATES REACH IT and one sentence is true of both, which is
                // why it is one line rather than two: a census whose names never
                // decoded (a blob a newer build wrote, arriving through CloudKit
                // — the counts survive that intact, the names do not), and one
                // whose retained names are all deliverable today while the
                // retention cap left the rest of the folder unexamined. In both,
                // what Conduck lacks is a NAME for whatever it actually left
                // behind, and the file server is where that file still is.
                //
                // A PROVEN WIDENING IS A THIRD STATE AND THE SENTENCE IS FALSE OF
                // IT. When every retained name is deliverable today, Conduck has
                // those names and would now hand those files over — the row is
                // standing for its shape or remainder population, not for the
                // type one, and `typeClaimHasGoneStale` cannot retire it while
                // that other population is non-zero. Claiming the names are
                // missing there contradicts the recheck verb beside it, which is
                // enabled for exactly this case and is about to deliver them.
                if rescues.isEmpty,
                   !OutputHeldBackCopy.allowlistWidened(outcome, stillRefused: rescues.count) {
                    Text(LocalizedStringResource(
                        "thread.outputs.heldBack.type.unnamed",
                        defaultValue: "There's nothing here to review — Conduck doesn't have the names for what it left in the folder. It's all still on your file server."))
                        .font(.caption2)
                        .foregroundStyle(AppColors.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            // ONE LINE PER SHAPE CLASS, not one line for the population. The two
            // classes are two different sentences: a name refused only for its
            // LENGTH is an honest agent naming a file after a section heading,
            // and the accusation the single line made of it — that the name
            // could be read as an instruction, or hides itself from a listing —
            // described an attack that did not happen.
            ForEach(OutputHeldBackCopy.shapeLines(for: outcome.shapeRefused), id: \.self) { line in
                Text(OutputHeldBackCopy.sentence(for: line))
                    .font(.caption2)
                    .foregroundStyle(AppColors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let remainder = OutputHeldBackCopy.remainderLine(for: outcome.remainder) {
                heldBackRemainderLine(remainder)
                    .font(.caption2)
                    .foregroundStyle(AppColors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// What a budget left behind, and whether anything can still change it.
    ///
    /// NOTHING IS POLLING, and the copy must never imply otherwise. A truncated
    /// pass only keeps the turn OPEN; the next pass fires on a thread open, a
    /// foreground reload, a notification tap, or the user's own "Check again".
    /// A row reading "still checking" beside no spinner promises background work
    /// that is not happening, and the user who waits for it gets nothing.
    ///
    /// THE PERMANENT CASE IS READ OFF THE REMAINDER'S OWN CAUSE, never off
    /// `outputScanDone`. That column answers a different question — is the TURN
    /// CLOSED — and a merely truncated pass closes on AGE once
    /// `truncatedScanHorizon` elapses. A row deriving permanence from it would
    /// tell the user the ceiling was hit and nothing more will come, on a folder
    /// whose tail "Check again" would hand over immediately.
    ///
    /// The WORDS live in `OutputHeldBackCopy`, which is what makes the choice
    /// testable; what is left here is the one thing only a view can do — join the
    /// ceiling's two sentences into a single wrapping paragraph.
    private func heldBackRemainderLine(_ line: OutputHeldBackCopy.RemainderLine) -> Text {
        // The MESSAGE goes in because the second sentence is decided by the same
        // live chip count that gates "Check again" beside it. Passing the row
        // rather than a precomputed Bool is what keeps the two from drifting: a
        // caller cannot hand the sentence one answer and the verb another.
        let sentences = OutputHeldBackCopy.sentences(for: line, on: message)
        guard let first = sentences.first else { return Text(verbatim: "") }
        return sentences.dropFirst().reduce(Text(first)) { joined, next in
            joined + Text(verbatim: " ") + Text(next)
        }
    }

    /// Whether a later pass can still add to this turn — the ONE condition that
    /// makes "Check again" honest here. A folder whose only leftovers are
    /// refusals answers a re-read with the identical refusals, so offering the
    /// verb there would spend a request to reprint the same row.
    ///
    /// THE LIVE GATE IS THE CHIP COUNT, not the remainder's recorded cause. A
    /// `.ceilingCapped` remainder says the ceiling bound THAT PASS; the message
    /// itself still admits files whenever it has free slots, and those slots
    /// change as chips arrive from the user's other devices. Reading the census
    /// here would hide the verb on a row that would genuinely gain from it.
    ///
    /// A PROVEN WIDENING QUALIFIES ON THAT SAME STANDARD, and the entries it
    /// describes have no other way home: the turn is closed, so nothing re-lists
    /// it on its own, and the review sheet drops exactly the names that became
    /// deliverable. `rescuableEntries` has just re-asked the verdict and found a
    /// name this build delivers, so a re-read mints a chip for it — which is the
    /// one thing this verb is claiming.
    private func offersHeldBackRecheck(
        _ outcome: OutputDeliveryOutcome,
        rescues: [OutputTypeRefusal]
    ) -> Bool {
        // Suppressed under a read-fault row, which carries its own "Check
        // again": the two rows stack by design, and two identical verbs one
        // above the other read as two different actions.
        canRecheckOutputs
            && !showsOutputDiscoveryFault
            && (outcome.undeliveredCount > 0
                || OutputHeldBackCopy.allowlistWidened(outcome, stillRefused: rescues.count))
            && OutputHeldBackCopy.admitsMoreChips(message)
    }

    /// The action strip. Rendered only when it has something in it — an empty
    /// `HStack` still claims the parent `VStack`'s spacing.
    @ViewBuilder
    private func heldBackActions(
        _ outcome: OutputDeliveryOutcome,
        rescues: [OutputTypeRefusal]
    ) -> some View {
        let offersRecheck = offersHeldBackRecheck(outcome, rescues: rescues)
        if !rescues.isEmpty || offersRecheck || heldBackOwnsBusyIndicator {
            HStack(spacing: 14) {
                // NOT replaced by the busy indicator, unlike the server verb
                // beside it: this one opens a local sheet from a census that is
                // already on the record, so an in-flight look has no bearing on
                // whether it can be tapped.
                if !rescues.isEmpty {
                    Button(action: onReviewHeldBack) {
                        Text(rescues.count == 1
                            ? LocalizedStringResource(
                                "thread.outputs.heldBack.action.one",
                                defaultValue: "Review file…")
                            : LocalizedStringResource(
                                "thread.outputs.heldBack.action.many",
                                defaultValue: "Review files…"))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(AppColors.brandAmber)
                    }
                    .inlineLinkButton()
                }
                if heldBackOwnsBusyIndicator {
                    HStack(spacing: 5) {
                        ProgressView()
                            .controlSize(.small)
                            .tint(AppColors.textTertiary)
                        Text(LocalizedStringResource(
                            "thread.outputs.checking",
                            defaultValue: "Checking…"))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(AppColors.textTertiary)
                    }
                } else if offersRecheck {
                    Button(action: onRecheckOutputs) {
                        HStack(spacing: 3) {
                            Image(systemName: "arrow.clockwise")
                            Text(LocalizedStringResource(
                                "thread.outputs.action.checkAgainShort",
                                defaultValue: "Check again"))
                        }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AppColors.brandAmber)
                    }
                    .inlineLinkButton()
                }
            }
        }
    }

    // MARK: - Output-discovery fault row (the file server could not be read)

    /// Persistent inline row under an agent turn whose output folder could not be
    /// READ. Deliberately QUIETER than the delivery-error row: this is not a
    /// failure of the message, it is a fact about the user's own setup. Neutral
    /// tint, no warning red, no accusation.
    ///
    /// WHAT IT NEVER SAYS, and the reason the whole row is rare: it makes no
    /// claim about what the agent did. A folder that is empty, or that is not
    /// there at all, shows NO row — nothing creates it in advance, so that is
    /// what an ordinary reply with no files looks like, and it conflates
    /// "produced nothing", "ignored the instruction", "a mkdir failed" and "wrote
    /// somewhere else". This row appears only when the app could not read the
    /// server: a refused certificate, a rejected credential, a wall that answers
    /// everything, a host that is down.
    ///
    /// Three actions, all of which can change the outcome: re-read the folder,
    /// look for the names the reply mentioned somewhere else on the server, or go
    /// fix the setup.
    private var outputDiscoveryFaultRow: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Image(systemName: "questionmark.folder")
                    .font(.caption)
                    .foregroundStyle(AppColors.textTertiary)
                Text(LocalizedStringResource(
                    "thread.outputs.fault.title",
                    defaultValue: "Couldn't read your file server"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppColors.textSecondary)
            }
            // THE REASSURANCE IS ABOUT CONDUCK, NOT ABOUT THE SERVER, and that
            // is the only form it can honestly take here. A read that failed
            // establishes nothing about the folder — nothing creates it in
            // advance, so the app does not know it exists, let alone that it
            // still holds anything. What IS true by construction is that this
            // lane only ever LISTS and GETs: nothing in it writes to or deletes
            // from an output folder, so whatever the agent put there is
            // untouched. The conditional phrasing carries that without asserting
            // anything was put there at all.
            Text(LocalizedStringResource(
                "thread.outputs.fault.body",
                defaultValue: "Conduck couldn't check whether this reply returned any files. It only ever reads that folder, so anything your agent put there is untouched."))
                .font(.caption2)
                .foregroundStyle(AppColors.textTertiary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 14) {
                if outputRecheckState == .checking {
                    HStack(spacing: 5) {
                        ProgressView()
                            .controlSize(.small)
                            .tint(AppColors.textTertiary)
                        Text(LocalizedStringResource(
                            "thread.outputs.checking",
                            defaultValue: "Checking…"))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(AppColors.textTertiary)
                    }
                } else {
                    if canRecheckOutputs {
                        Button(action: onRecheckOutputs) {
                            HStack(spacing: 3) {
                                Image(systemName: "arrow.clockwise")
                                Text(LocalizedStringResource(
                                    "thread.outputs.action.checkAgainShort",
                                    defaultValue: "Check again"))
                            }
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(AppColors.brandAmber)
                        }
                        .inlineLinkButton()
                    }
                    // Same gate as the footer menu's copy: the handler returns
                    // immediately without a lane, so an ungated button answers a
                    // tap with nothing at all. A fault row implies a listing,
                    // which implies a lane — this is belt-and-braces against the
                    // two ever parting.
                    if canSearchMentionedFiles {
                        Button(action: onSearchMentionedFiles) {
                            Text(LocalizedStringResource(
                                "thread.outputs.action.searchMentionedShort",
                                defaultValue: "Search mentioned files"))
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(AppColors.brandAmber)
                        }
                        .inlineLinkButton()
                    }
                }
                Button(action: onOpenFileSetup) {
                    Text(LocalizedStringResource(
                        "thread.outputs.action.reviewSetup",
                        defaultValue: "Review file setup"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AppColors.brandAmber)
                }
                .inlineLinkButton()
            }
            // The verdict of the last manual look, and ONLY when it says
            // something the row doesn't already: a look that never got an answer
            // is a materially different claim from a folder the server read out
            // clean, and reporting the former as the latter would be the one lie
            // this row must never tell.
            if let resultCaption {
                Text(resultCaption)
                    .font(.caption2)
                    .foregroundStyle(AppColors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(AppColors.cardBackgroundElevated)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(AppColors.borderSubtle, lineWidth: 1)
        )
        .frame(maxWidth: 520, alignment: .leading)
        .accessibilityElement(children: .contain)
    }

    // MARK: - Unnamed-folder row (the turn went out with nowhere to put files)

    /// Persistent inline row under an agent turn that was dispatched WITHOUT an
    /// output folder, because the configured file server did not settle the
    /// pre-dispatch freshness check.
    ///
    /// A DIFFERENT STORY FROM THE ROW ABOVE, and the difference is the reason it
    /// exists. That row is about a folder this turn WAS given and the app then
    /// failed to read, so its copy points at a folder and at what Conduck does
    /// and does not do to one. Here there never was a folder: the turn went out
    /// with no location line at all, so the agent was never told where to put
    /// anything and nothing could come back with the reply. Reusing the other
    /// row's copy would point the user at a folder that does not exist.
    ///
    /// IT NAMES NO CAUSE, and that is a correctness constraint rather than a
    /// style choice. The turns this row covers are selected from a LANE-WIDE
    /// failure streak, and every answer short of a definite miss can open that
    /// streak: `.unreachable` (no HTTP response at all), `.indeterminate` (a
    /// rejected credential, a `5xx`, a redirect — the server answered),
    /// `.cannotAnswer` (a `405`/`501` on the route a missing path is served by),
    /// `.occupied` (a namespace that claims a freshly minted path is already
    /// there, or a `207` whose body settles nothing — the server answered, just
    /// not with anything that can be read as absence), plus the suppressed turns
    /// where the breaker spent no request at all. A title saying the server
    /// "didn't answer" is therefore false on four of those five, and worse than
    /// false: it sends a user whose server is responding perfectly off to debug
    /// reachability. The neighbouring "Couldn't finish the check just now."
    /// makes the same move for the same reason — when the causes are
    /// indistinguishable HERE, name none of them and say only what is true of
    /// all of them.
    ///
    /// A LANE THAT KEEPS CLAIMING OCCUPANCY STOPS DRAWING THIS ROW ALTOGETHER,
    /// which is the boundary this row's silence is measured against rather than
    /// a sixth population. An unbroken run of `.occupied` answers about
    /// different freshly minted names is a capability limit, not a fault, so
    /// `FileLaneWitnessBreaker` clears the streak `faultedSince` reads and the
    /// mint returns `.laneCannotReturn` — no row, because a row the user can
    /// neither act on nor dismiss is not information.
    ///
    /// THE FACT TRUE OF ALL OF THEM is what the copy says: this turn carried no
    /// folder, nothing could come back with it, and the lane is not currently
    /// producing one. The remedy is the same in every case too — the file
    /// server, or the setup screen behind it — so nothing actionable is lost by
    /// refusing to guess which of the four happened.
    ///
    /// NO "CHECK AGAIN". The verb re-reads a folder, and this turn has no folder
    /// to re-read; offering it would answer a tap with nothing at all. The two
    /// actions that CAN still change something are here instead: the name search
    /// (the agent may well have written a file somewhere the served root can
    /// see) and the setup screen, which is where a stale address is fixed.
    ///
    /// Same neutral tint as the read-fault row, and for the same reason: this is
    /// a fact about the user's own setup, not a failure of the message.
    private var unnamedFolderFaultRow: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Image(systemName: "folder.badge.questionmark")
                    .font(.caption)
                    .foregroundStyle(AppColors.textTertiary)
                Text(LocalizedStringResource(
                    "thread.outputs.noFolder.title",
                    defaultValue: "No folder for this reply"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppColors.textSecondary)
            }
            // "NOWHERE TO PUT FILES" WAS FALSE, and expensively so: the agent
            // always has its own working directory — frequently the very folder
            // the "Search mentioned files" button beside this copy probes — so
            // the old sentence told the user a file could not exist while the
            // button under it offered to go and find that file. What is actually
            // true is narrower: Conduck never told the agent WHERE, so nothing
            // could ride back with the reply. The remedy sentence is unchanged.
            Text(LocalizedStringResource(
                "thread.outputs.noFolder.body",
                defaultValue: "Conduck couldn't confirm a fresh folder on your file server for this message, so it never told the agent where to put files and nothing could come back with the reply. Anything the agent wrote went to its own working folder — if the reply names a file, you can search for it. Check your file server, then send again."))
                .font(.caption2)
                .foregroundStyle(AppColors.textTertiary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 14) {
                if outputRecheckState == .checking {
                    HStack(spacing: 5) {
                        ProgressView()
                            .controlSize(.small)
                            .tint(AppColors.textTertiary)
                        Text(LocalizedStringResource(
                            "thread.outputs.checking",
                            defaultValue: "Checking…"))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(AppColors.textTertiary)
                    }
                } else if canSearchMentionedFiles {
                    Button(action: onSearchMentionedFiles) {
                        Text(LocalizedStringResource(
                            "thread.outputs.action.searchMentionedShort",
                            defaultValue: "Search mentioned files"))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(AppColors.brandAmber)
                    }
                    .inlineLinkButton()
                }
                Button(action: onOpenFileSetup) {
                    Text(LocalizedStringResource(
                        "thread.outputs.action.reviewSetup",
                        defaultValue: "Review file setup"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AppColors.brandAmber)
                }
                .inlineLinkButton()
            }
            if let resultCaption {
                Text(resultCaption)
                    .font(.caption2)
                    .foregroundStyle(AppColors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(AppColors.cardBackgroundElevated)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(AppColors.borderSubtle, lineWidth: 1)
        )
        .frame(maxWidth: 520, alignment: .leading)
        .accessibilityElement(children: .contain)
    }

    /// Progress + verdict for a manual look started from the footer menu, on a
    /// turn with no fault row to carry them. Renders nothing at all in the
    /// resting state, which is almost always — this is a transient answer to a
    /// question the user just asked, not a standing diagnostic.
    ///
    /// The busy half stands down under a held-back row, which carries the
    /// indicator itself when no fault row does — see `heldBackOwnsBusyIndicator`
    /// for why exactly one row may.
    @ViewBuilder
    private var outputLookStatusLine: some View {
        if outputRecheckState == .checking, heldBackOutcome == nil {
            HStack(spacing: 5) {
                ProgressView()
                    .controlSize(.small)
                    .tint(AppColors.textTertiary)
                Text(LocalizedStringResource(
                    "thread.outputs.checking",
                    defaultValue: "Checking…"))
                    .font(.caption2)
                    .foregroundStyle(AppColors.textTertiary)
            }
            .frame(maxWidth: 520, alignment: .leading)
        } else if let resultCaption {
            Text(resultCaption)
                .font(.caption2)
                .foregroundStyle(AppColors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 520, alignment: .leading)
        }
    }

    /// Caption for the last manual look. A CLEAN SUCCESS has no caption: the
    /// chips appear and there is nothing left to annotate.
    ///
    /// The CHOICE lives in `ConversationDetailViewModel.lookResultCaption` — a
    /// pure function of the look's outcome and whether a standing row is up — so
    /// the rule that a tap is always answered is provable rather than buried in
    /// a `switch` inside a recycling row.
    private var resultCaption: LocalizedStringResource? {
        ConversationDetailViewModel.lookResultCaption(
            for: outputRecheckState,
            hasStandingRow: heldBackOutcome != nil
        )
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
            // so unrelated parent re-renders (read-aloud `speakState`, `showsGatewayWaitIndicator`
            // turn boundaries) can't re-touch Textual's selection layer mid-drag — the
            // macOS trackpad-selection fix. See `AgentMarkdownBody`.
            AgentMarkdownBody(messageID: message.id, text: message.text)
                .equatable()
        }
    }

    /// Whether the footer has a manual-look verb to offer at all. Both flags are
    /// false on a user row (the VM's predicates require an agent role) and on an
    /// agent row with no file lane.
    private var showsOutputActionsMenu: Bool {
        canRecheckOutputs || canSearchMentionedFiles
    }

    /// The footer, carrying the manual-look menu ONLY when it has something to
    /// put in it.
    ///
    /// ATTACHED CONDITIONALLY, and that is the whole point: a `.contextMenu`
    /// whose body evaluates to nothing still runs the long-press lift animation
    /// and then presents an EMPTY sheet. Attached unconditionally with its
    /// contents gated instead, a long press on the user's own sent message — and
    /// on any agent turn with no file lane, the majority configuration — lifts
    /// the bubble and offers nothing.
    ///
    /// ON THE FOOTER, not on the bubble, and that is deliberate too: the agent
    /// bubble's body is a Textual document with its own long-press/right-click
    /// selection, and a context menu over it would compete with the shipped
    /// selection gesture. The footer is the row's action strip already (Copy,
    /// Speak), so it is both conflict-free and where a user looks for verbs.
    ///
    /// Within an agent row that HAS a lane, the entry stays available whether or
    /// not the app decided to show a diagnostic row — including a turn whose
    /// folder was never named (a wrist-originated turn, a lane that cannot hold a
    /// nested collection), which is exactly the population that gets no automatic
    /// delivery. An affordance that appears only on a row the app decided to show
    /// is one the user cannot find when they need it.
    @ViewBuilder
    private var footerWithOutputActions: some View {
        if showsOutputActionsMenu {
            footer.contextMenu {
                if canRecheckOutputs {
                    Button(action: onRecheckOutputs) {
                        Label(
                            LocalizedStringResource(
                                "thread.outputs.action.checkAgain",
                                defaultValue: "Check for returned files"),
                            systemImage: "arrow.clockwise")
                    }
                }
                if canSearchMentionedFiles {
                    Button(action: onSearchMentionedFiles) {
                        Label(
                            LocalizedStringResource(
                                "thread.outputs.action.searchMentioned",
                                defaultValue: "Search for files this reply mentions"),
                            systemImage: "magnifyingglass")
                    }
                }
            }
        } else {
            footer
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
                // Suppress the per-message sending spinner once the turn is
                // dispatched — the borderless "answering…" indicator is the
                // single in-flight signal from then on. This dot owns the window
                // BEFORE that: attachment processing, the durable write, history
                // assembly, credential resolution. On macOS that window is the
                // long one, so this is the user's only "it went through" cue
                // until the gateway hop actually starts.
                if !showsGatewayWaitIndicator {
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
                // Radius matches `chipLabel`'s own rounded-rect fill. Plain
                // `.choiceCardButton` is wrong here: `chipLabel` caps itself at
                // 220pt INSIDE the label, so the style's `maxWidth: .infinity`
                // would paint the wash across the whole bubble column.
                .pointerHoverWash(cornerRadius: 10)
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
/// output file found by listing the folder this dispatch named, or turned up by
/// a user-tapped name search (assistant), or a file the user sent (user; its
/// bytes live on the file-server too, so it previews the same way). `outputBoxKey`
/// is what separates the first case from the second at render time, so the chip
/// can say which one it is. A tap downloads the real bytes from the user's gateway file-server
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
    /// The turn this chip hangs on. Carried so a completed download can patch
    /// the row's preview — the ONE thing that makes an agent file viewable on
    /// the Watch, which has no download capability by design.
    let messageID: UUID
    /// Conversation's bound gateway — resolves the file-server snapshot. Nil
    /// falls back to the Settings default ref.
    let boundRef: RemoteAgentRef?
    /// Durable owner of this chip's storedKey. A GET requires the exact same
    /// configured lane. Its mutable READY verdict gates new transfers, not
    /// access to an already-owned blob. Nil is unprovable and fails closed.
    let expectedLaneID: String?
    /// The folder THIS reply named for its own output, when it named one. A
    /// storedKey inside it is this reply's output; one outside it was found
    /// elsewhere on the file server by a user-tapped name search and gets a
    /// visibly weaker caption. Nil on a user chip, and on an agent turn that
    /// named no folder — both of which mean the stronger claim is unsupported.
    let outputBoxKey: String?
    /// The thread-level Quick Look presenter (single panel authority).
    let filePreview: FilePreviewCoordinator
    /// True on a user bubble — mirrors `InlineTextFileChip`'s role styling
    /// (dark-on-amber text, translucent fill) so the chip sits naturally on
    /// either bubble.
    let isUserBubble: Bool

    /// Tri-state download chrome: idle (no glyph — the chip itself is the tap
    /// target), busy (spinner), failed (error glyph + the inline message).
    ///
    /// `failed` carries `retryable` because a chip is a tap target by default,
    /// and re-tapping a terminal refusal (a certificate this device won't
    /// accept, a rejected file-server password, a URL that isn't a file server)
    /// only replays the same refusal over the message it just printed. Nothing
    /// but the taxonomy knows which failures those are, so the flag rides in
    /// from `AppError.isRetryable`; every failure with no `AppError` behind it
    /// stays retryable, because unknown is not terminal.
    private enum DownloadState: Equatable {
        case idle, downloading, failed(message: String, retryable: Bool)
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

    /// Whether a tap can still reach a different outcome. False while a
    /// download is in flight (already busy) and false once a terminal refusal
    /// has landed — the SINGLE gate every entry point reads, so the chip, the
    /// macOS Save As… button and its context-menu mirror can never disagree
    /// about whether this file is still reachable.
    private var acceptsTap: Bool {
        // Unaddressable rows are inert forever — there is no blob to GET, so a
        // tap could only produce a misleading refusal.
        guard isAddressable else { return false }
        switch state {
        case .downloading: return false
        case .failed(_, let retryable): return retryable
        case .idle: return true
        }
    }

    /// Whether this row names bytes that can be fetched at all — a non-empty
    /// `storedKey` AND a provable owning lane. False for a cross-lane clone's
    /// tombstone (key cleared) and for a legacy row with no lane owner.
    private var isAddressable: Bool {
        ServerFileChipAvailability.isAddressable(
            storedKey: attachment.storedKey,
            ownerLaneID: expectedLaneID
        )
    }

    /// The refusal text under the chip name, when the last attempt failed.
    /// Feeds the accessibility label too — the visible line wraps, but VoiceOver
    /// reads the chip as one element, so without this the reason is inaudible.
    private var failureMessage: String? {
        if case .failed(let message, _) = state { return message }
        return nil
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
                // Padding/background live on the outer HStack — keep the whole
                // label (Spacer included) tappable.
                .contentShape(Rectangle())
            }
            // `.plain`, and deliberately NO per-half style: this half and the
            // chip's padding ring are ONE action (preview), so the wash belongs
            // to the whole chip and arrives once, from `.pointerHoverWash` below.
            // A style here could only paint the label box inset inside the ring
            // and cut short by the Save As… button — a highlight in the shape of
            // something the user is not aiming at.
            .buttonStyle(.plain)
            .disabled(!acceptsTap)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(([
                // An inert chip must not be announced as a download action —
                // VoiceOver reads the chip as one element, so the label is the
                // ONLY signal that this row is passive.
                // Neither form names where the bytes live. The label's job is to
                // say what a tap does; the source only matters once a tap FAILS,
                // and `failureMessage` below appends whatever diagnostic that
                // failure carries — which is where a service belongs, named or
                // not according to whether this particular refusal knows one. A
                // source named up here is one more place for the gateway /
                // file-server split to be got wrong, and a longer label to sit
                // through before the verb arrives.
                String(
                    format: String(localized: isAddressable
                        ? LocalizedStringResource(
                            "fileTransfer.preview.accessibility",
                            defaultValue: "Download and preview file %@")
                        : LocalizedStringResource(
                            "fileTransfer.detachedReference.accessibility",
                            defaultValue: "File %@, unavailable here")),
                    name
                ),
                failureMessage
            ] as [String?]).compactMap { $0 }.joined(separator: ". ")))
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
        // The chip is ONE target on the pointer, so the wash traces the chip's
        // own fill (radius 10) rather than a box floating inside it, and the
        // padding ring the sub-`Button`s cannot reach previews too instead of
        // lighting up and swallowing the click. Split-action shape — see
        // `.pointerHoverWash(cornerRadius:action:)`. No-op off macOS.
        .pointerHoverWash(cornerRadius: 10) { download(route: .preview) }
        // OUTSIDE the wash so its `isEnabled` read sees this: a chip mid-download
        // or holding a terminal refusal stays unlit and inert, exactly as the
        // sub-`Button`s do.
        .disabled(!acceptsTap)
        #if os(macOS)
        // Redundant shortcut for the visible Save As… button (HIG: a context
        // menu may only mirror a visible control, never be the sole path).
        .contextMenu {
            Button(saveAsTitle) { download(route: .saveAs) }
                .disabled(!acceptsTap)
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
            if isAddressable {
                // No idle glyph — the whole chip is the Quick Look tap target;
                // an extra affordance would crowd the chip.
                EmptyView()
            } else {
                // The one idle case that DOES need a glyph: without it an inert
                // chip is visually identical to a live one, so the only signal
                // that a tap does nothing would be the tap doing nothing.
                Image(systemName: "slash.circle")
                    .font(.system(size: 15))
                    .foregroundStyle(secondaryTint)
            }
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
        .pointerIconButton()
        .disabled(!acceptsTap)
        .help(saveAsTitle)
        // Same rule as the chip's own label: an unaddressable row must not be
        // announced as a save action. This is a SEPARATE accessibility element,
        // so VoiceOver would otherwise convey only "dimmed", never why. Naming
        // no source, for the same reason as the chip label above.
        .accessibilityLabel(Text(String(
            format: String(localized: isAddressable
                ? LocalizedStringResource(
                    "fileTransfer.saveAs.accessibility",
                    defaultValue: "Save file %@")
                : LocalizedStringResource(
                    "fileTransfer.detachedReference.accessibility",
                    defaultValue: "File %@, unavailable here")),
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
        case .failed(let message, _):
            // NO line cap: this chip is the only place a download refusal is
            // ever shown, and the half that gets clipped first is the remedy —
            // the server-side routes to a trusted certificate, the setting to
            // correct. A taller chip on failure is the cheaper cost.
            Text(message)
                .font(.caption2)
                .foregroundStyle(AppColors.error)
                .fixedSize(horizontal: false, vertical: true)
        case .idle:
            if !isAddressable {
                // "Unavailable here" — NOT "not on this gateway". A legacy or
                // partially-synced row cannot prove where its bytes are; all
                // this thread can honestly say is that it cannot reach them.
                Text(LocalizedStringResource(
                    "fileTransfer.detachedReference",
                    defaultValue: "Unavailable here"
                ))
                    .font(.caption2)
                    .foregroundStyle(secondaryTint)
            } else if let idleCaption {
                Text(idleCaption)
                    .font(.caption2)
                    .foregroundStyle(secondaryTint)
                    // Wrap rather than truncate, for the same reason the failure
                    // branch does: the half that clips first is the tail, and on
                    // a user chip the tail is where the file actually is.
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The quiet metadata line under an idle chip's filename.
    ///
    /// On a USER turn it also names where the bytes ended up. A user-bubble chip
    /// renders only for a server reference, and only an addressable one reaches
    /// this branch, so "on your file server" restates exactly what this row
    /// proves — the file went up, and it is still reachable there. That is the
    /// fact worth carrying: it is the difference between a file that rode inline
    /// inside the request and one the agent has to go and open.
    ///
    /// A LOCATION, never a verdict. What the agent did with the file afterwards
    /// is not observable from this side of the wire — the same silent reply fits
    /// an agent that never opened it, one that read it and answered without
    /// naming it, and one whose PDF parser broke — so the caption stops at the
    /// last provable fact and says nothing about the reply.
    ///
    /// An ASSISTANT chip keeps the bare size when the file came out of THIS
    /// reply's own output folder — a path minted for this turn and named on the
    /// wire before the reply existed, so "this reply returned it" needs no
    /// hedging. A chip whose key is NOT inside that folder was turned up by a
    /// user-tapped name search somewhere on the file server, which says nothing
    /// about which turn produced it or whether any turn did, so it says so.
    /// Nil when there is nothing left to say (a box file of unknown size).
    private var idleCaption: String? {
        let size = attachment.byteSize > 0
            ? AttachmentChipStyle.formattedSize(attachment.byteSize)
            : nil
        guard isUserBubble else {
            guard !AttachmentRecord.isFromReplyOutputBox(
                storedKey: attachment.storedKey,
                outputBoxKey: outputBoxKey
            ) else {
                return size
            }
            let found = String(localized: LocalizedStringResource(
                "fileTransfer.found.onFileServer",
                defaultValue: "Found on your file server"))
            guard let size else { return found }
            return String(
                format: String(localized: LocalizedStringResource(
                    "fileTransfer.found.sizeOnFileServer",
                    defaultValue: "%@ · found on your file server")),
                size
            )
        }
        guard let size else {
            return String(localized: LocalizedStringResource(
                "fileTransfer.sent.onFileServer",
                defaultValue: "On your file server"))
        }
        return String(
            format: String(localized: LocalizedStringResource(
                "fileTransfer.sent.sizeOnFileServer",
                defaultValue: "%@ · on your file server")),
            size
        )
    }

    /// Button action. For a KNOWN very-large size, gate behind a soft-confirm
    /// (mirrors the upload-side large-file warning) before the multi-hundred-MB
    /// download begins; unknown size (byteSize == 0) downloads immediately.
    private func download(route: PostDownloadRoute) {
        guard acceptsTap else { return }
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
        guard acceptsTap else { return }
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
                // THE preview seam, and the only one: the bytes are already on
                // local disk because the user asked for them, so a bounded read
                // of the file this device just downloaded costs no network at
                // all. It runs BEFORE the hand-off so a Quick Look dismissal
                // that reclaims the scratch file cannot race the read.
                await patchPreviewFromDownload(at: tempURL, snapshot: snapshot)
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

    /// Store a bounded preview of the file this tap just downloaded.
    ///
    /// WHAT IT IS FOR: the Watch. `AttachmentRecord.watchDisplayClass` lands
    /// every previewless server file on `.serverPlaceholder`, and the wrist has
    /// no download capability by design — so without this an agent's output is a
    /// dead marker there forever. Nothing is fetched: the download already put
    /// the bytes on this device, and the read is capped by the same per-file
    /// budgets the preview builder has always enforced.
    ///
    /// BEST-EFFORT AND SILENT. A failure means "no preview", never a visible
    /// error — the user asked for the file, not for the thumbnail, and the file
    /// itself is already in hand. `applyPreviews` is first-writer-wins per field,
    /// so a re-tap cannot churn the row or the iCloud record behind it.
    private func patchPreviewFromDownload(
        at url: URL,
        snapshot: SettingsManager.FileTransferSnapshot
    ) async {
        guard let storedKey = attachment.storedKey, !storedKey.isEmpty,
              let filename = attachment.filename else { return }
        let patches = await FileTransferOutputDetector.previewPatchesForDownloadedFile(
            at: url,
            messageID: messageID,
            storedKey: storedKey,
            filename: filename,
            mimeType: attachment.mimeType,
            snapshot: snapshot
        )
        guard !patches.isEmpty else { return }
        _ = try? await ConversationStore.shared.applyPreviews(patches)
    }

    /// Cause AND remedy. The chip has no Troubleshoot chip, no detail sheet and
    /// no second slot, so `errorDescription` alone left a terminal refusal on
    /// screen naming a problem with no way to act on it — and, for a pinned key
    /// that disagreed with a chain the system trusted, without the warning that
    /// the connection may be intercepted (that sentence lives entirely in the
    /// remedy half).
    @MainActor
    private func presentError(_ error: AppError) {
        let message = error.descriptionWithRecovery(for: boundRef)
        state = .failed(
            message: message.isEmpty ? Self.genericFailureMessage : message,
            retryable: error.isRetryable
        )
    }

    /// No `AppError` behind it (an adoption failure, a non-taxonomy throw) —
    /// unknown is not terminal, so the chip stays tappable.
    @MainActor
    private func presentGenericError() {
        state = .failed(message: Self.genericFailureMessage, retryable: true)
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
            // Local adoption, not a server verdict — a fresh tap can succeed.
            state = .failed(message: Self.previewFailureMessage, retryable: true)
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
            // than silently going idle with no file written. A local write
            // failure (full disk, read-only volume) is not a server verdict, so
            // the chip stays tappable for another destination.
            state = .failed(message: Self.saveFailureMessage, retryable: true)
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
