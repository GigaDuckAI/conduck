// SPDX-License-Identifier: Apache-2.0

// Conduck
// WatchConversationThreadView.swift
//
// Watch conversation thread. PLAINTEXT chat bubbles
// (user-right / agent-left); NO Markdown render on Watch ("Watch —
// plaintext only"). Per-message tap-to-speak routes the bubble text through
// `ReplySanitizer.spoken(_:)` + route-aware `WatchReplySpeaker`.
//
// Graceful no-op if the conversation UUID was deleted on another device — the
// VM's `loadThread` returns an empty array rather than erroring, so
// the view shows an empty thread instead of crashing.

import SwiftUI
import UIKit
import WatchKit

struct WatchConversationThreadView: View {
    /// The conversation this thread shows. NIL while a `.new` capture target is
    /// still a DRAFT shell (no conversation minted yet); it adopts the real id
    /// the instant the recording service mints it (see `resolvedConversationID`
    /// + `adoptMintedIDIfNeeded`). For the list-tap / deep-link paths it is set
    /// from `init(conversationID:)` and never nil.
    @State private var conversationID: UUID?

    /// The capture target to auto-start when this thread is pushed from the root
    /// `.capture(...)` route. Nil for the list-tap / deep-link paths (which open
    /// an existing thread for browsing, not capture).
    private let autoCaptureTarget: WatchCaptureTarget?

    @Bindable var viewModel: WatchConversationViewModel

    /// Browse entry (list tap / suspended-reply deep-link): open an EXISTING
    /// conversation, no auto-capture.
    init(conversationID: UUID, viewModel: WatchConversationViewModel) {
        self._conversationID = State(initialValue: conversationID)
        self.autoCaptureTarget = nil
        self.viewModel = viewModel
    }

    /// Capture entry (root `.capture(target)` route): render a (possibly draft)
    /// thread shell and auto-start recording bound to `target`. A `.existing`
    /// target resolves its id immediately; a `.new` target starts as a draft
    /// (nil id) and adopts the minted id during the hop.
    init(captureTarget: WatchCaptureTarget, viewModel: WatchConversationViewModel) {
        switch captureTarget {
        case .existing(let id):
            self._conversationID = State(initialValue: id)
        case .new:
            self._conversationID = State(initialValue: nil)
        }
        self.autoCaptureTarget = captureTarget
        self.viewModel = viewModel
    }

    /// The shared cross-platform speak-state machine, backed by the Watch's
    /// `WatchReplySpeaker` engine — identical behavior to the iPhone/iPad/Mac
    /// per-message control (idle → loading → playing → paused, tap-to-pause /
    /// resume-from-position, supersede on a different reply).
    @State private var speaker = ThreadSpeaker(engine: WatchReplySpeaker())

    /// One-shot auto-speak requests (reply ARRIVAL while `.active`, armed by
    /// `WatchRecordingService.handleBackgroundReply`; NOTIFICATION-TAP open,
    /// armed by `WatchNoteView.drainDeepLinkIfNeeded`), drained into this
    /// thread's own `ThreadSpeaker` by `attemptAutoSpeak`. Plain `let` —
    /// `@Observable` reads in body register observation (the same idiom as
    /// `WatchNoteView.deepLinkCoordinator`).
    private let autoSpeakMailbox = AutoSpeakMailbox.shared

    /// True once the auto-capture has been kicked off, so a re-render (e.g. the
    /// draft adopting its minted id) can't re-trigger `startCapture`.
    @State private var didAutoStartCapture = false

    /// One-shot latch for `popDraftIfNeeded()`: a popped draft must never
    /// dismiss twice (counter echo after a direct pop) nor auto-start a
    /// capture while it is being dismissed.
    @State private var didPopDraft = false

    /// Per-instance (a new view is built per navigation push) — guarantees the
    /// spinner shows until the first load completes, with no first-frame empty
    /// flash and no stale-thread flash.
    @State private var hasLoaded = false

    /// Mirrors the recording service state machine so the inline "Thinking…"
    /// indicator above the composer surfaces in this thread.
    @State private var recordingService = WatchRecordingService.shared

    /// Always-On-Display state (wrist lowered → screen dimmed). Drives bubble
    /// dimming so the bright orange user bubbles don't blaze in AOD.
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced

    /// Pops this pushed route (the `NavigationPath` lives in `WatchNoteView`;
    /// `dismiss()` from a `navigationDestination` view pops its level).
    @Environment(\.dismiss) private var dismiss

    /// Scene phase — the "safe to play now" gate for auto-speak. A reply that
    /// landed while the wrist was down is staged but not spoken until the scene
    /// is `.active`; the `.onChange(of: scenePhase)` hook re-fires the speak on
    /// the wrist-raise (see `attemptAutoSpeak`).
    @Environment(\.scenePhase) private var scenePhase

    /// True iff this thread's in-flight turn (capture / STT / agent) belongs to
    /// us. A `.new` draft shell (`conversationID == nil`) matches ANY in-flight
    /// turn — it is the only capture on screen and adopts the minted id moments
    /// later, so claiming the overlay/banner immediately is correct and avoids a
    /// flicker between push and mint. An `.existing` thread matches by id.
    private var isOurInFlightTurn: Bool {
        if conversationID == nil { return true }
        return recordingService.inFlightConversationID == conversationID
    }

    /// True iff this view was pushed as a `.new` draft capture entry — the only
    /// shape that can end up permanently id-less (and therefore content-less)
    /// when its capture discards. Gates `popDraftIfNeeded()`.
    private var isDraftCaptureEntry: Bool {
        if case .new = autoCaptureTarget { return true }
        return false
    }

    /// True iff the recording service is actively CAPTURING (arming / recording)
    /// for THIS thread. Drives the dominant capture overlay.
    private var isCapturingHere: Bool {
        isOurInFlightTurn && recordingService.isCapturing
    }

    /// The in-flight "thinking" phase for THIS thread, or nil when no agent-side
    /// indicator should show. `.arming`/`.recording` are excluded — the dominant
    /// capture overlay owns the surface there; the indicator covers only the
    /// post-stop stages: `.uploading` (STT, dictated text not yet known, no user
    /// bubble) → `.transcribing`; `.waiting` (agent in flight, user bubble on
    /// screen) → `.answering`.
    private var inFlightPhase: ThinkingPhase? {
        guard isOurInFlightTurn else { return nil }
        switch recordingService.state {
        case .uploading: return .transcribing
        case .waiting: return .answering
        default: return nil
        }
    }

    /// The turn's start instant for the elapsed clock — only `.waiting` carries
    /// one (the `.uploading`/transcribing phase shows no clock; it's brief).
    private var inFlightStartedAt: Date? {
        guard isOurInFlightTurn,
              case .waiting(let startedAt) = recordingService.state else { return nil }
        return startedAt
    }

    /// The recording-service error to surface inline in THIS thread. The root
    /// `WatchNoteView` error view sits BEHIND the navigation push, so without
    /// this banner a failed bound turn is invisible here — and send/record
    /// guard on `.idle`, bricking the composer until the user pops to root.
    /// The pin (`inFlightConversationID`) survives most failure sites, but the
    /// converse-stage catch clears it (`clearInFlight()`) BEFORE setting
    /// `.error` — so a nil pin maps here too. Safe: headless/Ask captures
    /// reset the nav path to root before recording, so a nil-pin error visible
    /// behind a pushed thread can only be a composer send's. A pin for a
    /// DIFFERENT thread stays off this surface.
    private var inlineErrorMessage: String? {
        guard case .error(let message) = recordingService.state else { return nil }
        // A draft shell (nil id) owns any nil-pin error too — the converse-stage
        // catch clears the pin before setting `.error`, so a failed first turn in
        // a brand-new thread surfaces here rather than vanishing.
        guard conversationID == nil
                || recordingService.inFlightConversationID == conversationID
                || recordingService.inFlightConversationID == nil else { return nil }
        return message
    }

    /// The bound gateway's name for the inline top bar — shown in place of the
    /// old first-sentence snippet, which DUPLICATED the first user bubble in the
    /// body. The gateway ("OpenClaw" / "Hermes" / a custom's name) is the
    /// genuinely useful header here (routing is per-conversation), so the top bar
    /// reads like an "AI as contact" name. Resolved from the shared VM's
    /// already-loaded list cache (no extra fetch) + the Watch custom roster;
    /// empty when the ref is unknown OR a custom missing from the roster (deleted
    /// / not-yet-synced) → a clean back+clock bar (no generic word).
    private var threadBackendName: String {
        guard let id = conversationID,
              let raw = viewModel.conversations.first(where: { $0.id == id })?.backend,
              let ref = RemoteAgentRef(rawString: raw) else { return "" }
        // The BADGE roster: a thread bound to a forgotten custom names it
        // "Forgotten gateway" rather than going blank, matching the colour tag
        // its row already carries in the list.
        let customs = WatchSettingsReader.shared.gatewayBadgeRoster
        // A custom missing from BOTH rosters → empty (no generic fallback word).
        if case .custom(let id) = ref, !customs.contains(where: { $0.id == id }) {
            return ""
        }
        return RemoteAgentRefMetadata.displayName(for: ref, customs: customs)
    }

    /// Drives the WhatsApp-style scroll-to-hide composer. Starts visible (a fresh
    /// thread opens scrolled to the latest turn); flipped by the near-bottom
    /// detector and forced true on send/reply so the composer always reappears.
    @State private var isComposerVisible = true

    /// Whether the error banner's full message is open on its own screen.
    ///
    /// The banner is a bottom OVERLAY, deliberately outside scroll layout, so its
    /// height is bounded by the screen and the crown belongs to the thread
    /// underneath — it can neither grow to fit a long message nor scroll one.
    /// Raising its line cap does not fix that: at large Dynamic Type the space
    /// simply is not there, and the tail still clips. Since the clipped tail is
    /// exactly the actionable half of a certificate verdict (the pointer to the
    /// phone; on a pin mismatch, the interception warning, which sits last), the
    /// full text needs a surface with room, and that means a screen of its own.
    /// Reset per message so a new error never inherits the old one's sheet.
    @State private var isErrorDetailPresented = false

    /// Live scroll-content height from `onScrollGeometryChange` — the settle
    /// signal for `snapToBottom`'s verification window. A signal, not an oracle:
    /// the height can read final while the lazy anchor map is still unresolved,
    /// which is why the verify loop also fires one unconditional delayed snap.
    @State private var liveContentHeight: CGFloat = 0

    /// The in-flight snap-verify loop. Each `snapToBottom` cancels the previous
    /// one (newest request wins), and `.onDisappear` cancels outright so a
    /// popped view never keeps a proxy-bound task alive.
    @State private var snapVerifyTask: Task<Void, Never>?

    /// Bottom sentinel id — drives the height-independent at-bottom detection
    /// (mirrors the iPhone thread's proven pattern in `ConversationThreadView`).
    /// The earlier `geo.contentSize.height`-based threshold math broke once the
    /// 48pt bottom content margin landed the rest-position distance inside the
    /// 45–60pt hysteresis dead zone, so the composer never reappeared at the end
    /// of a thread. An onAppear/onDisappear sentinel sidesteps the size math.
    private static let bottomAnchorID = "watch.thread.bottom.anchor"

    /// Constant id for the agent-side thinking row, so it keeps LazyVStack
    /// identity as its label flips Transcribing → answering (per Codex: never
    /// key the row's identity on phase/label/startedAt).
    private static let thinkingAnchorID = "watch.thread.thinking.anchor"

    /// In Always-On Display the composer slab is suppressed (battery + glanceable
    /// dim), so the bar only shows when near-bottom AND the wrist is raised.
    private var composerShown: Bool { isComposerVisible && !isLuminanceReduced }

    /// Deterministic snap to the bottom anchor: an immediate one-render-pass-hop
    /// snap (so the just-inserted bubble / just-removed thinking row are laid
    /// out BEFORE the anchor is resolved — otherwise the scroll lands against
    /// the pre-insert bottom, newest bubble under the composer / clipped),
    /// followed by a short bounded VERIFY window that re-snaps until the content
    /// geometry settles. The verify window exists because one hop is NOT a
    /// layout-settled point when several rows materialize at once into the
    /// LazyVStack (a thread that opened empty, then received CloudKit-synced
    /// rows + the new turn in ONE refresh pass): `scrollTo` resolves against
    /// transient estimated extent, overshoots, and watchOS never re-clamps — the
    /// viewport parks fully BELOW the content (blank screen until the user
    /// scrolls up). Verify rules:
    /// - One delayed re-snap is UNCONDITIONAL: `liveContentHeight` can read
    ///   final while the lazy anchor map is still unresolved, so height-change
    ///   must not be the only correction trigger.
    /// - Height compares use a 0.5pt tolerance; the loop can't exit before a
    ///   4-frame minimum window + 3 stable samples, capped at ~225ms. An
    ///   expired budget is safe — the next count-change snap supersedes.
    /// - NO `withAnimation` anywhere (and `disablesAnimations` on every snap):
    ///   on watchOS an animated `scrollTo` chases the still-moving height and
    ///   reflows/stutters at the bottom; non-animated snaps are glitch-free.
    private func snapToBottom(_ proxy: ScrollViewProxy) {
        snapVerifyTask?.cancel()  // coalesce: newest request wins
        snapVerifyTask = Task { @MainActor in
            // A cancelled-before-start task must not fire even one stale snap.
            if Task.isCancelled { return }
            scrollToBottomNow(proxy)
            var lastHeight = liveContentHeight
            var stable = 0
            var resnaps = 0
            var framesRun = 0
            for frame in 0..<14 {
                try? await Task.sleep(for: .milliseconds(16))
                if Task.isCancelled { return }
                framesRun = frame + 1
                if frame == 0 {
                    scrollToBottomNow(proxy)  // the unconditional delayed snap
                    resnaps += 1
                }
                if abs(liveContentHeight - lastHeight) < 0.5 {
                    stable += 1
                    if frame >= 4 && stable >= 3 { break }
                } else {
                    lastHeight = liveContentHeight
                    stable = 0
                    scrollToBottomNow(proxy)
                    resnaps += 1
                }
            }
            // Redaction-safe breadcrumb (counts only), emitted only when the loop
            // corrected BEYOND the unconditional delayed snap — zero noise on
            // the settled/common path.
            if resnaps > 1 {
                WatchLog.note(.nav, "snap.settle", ["resnaps": resnaps, "frames": framesRun])
            }
        }
    }

    /// The single non-animated scroll primitive. `disablesAnimations` guards
    /// against an inherited transaction animating the snap.
    private func scrollToBottomNow(_ proxy: ScrollViewProxy) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
        }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    // Message rendering is gated on THIS view instance having
                    // loaded its OWN thread (`hasLoaded`) — the shared
                    // `WatchConversationViewModel.threadMessages` persists across
                    // navigations and may still hold a PREVIOUSLY-viewed
                    // conversation's bubbles (a `.new` Ask draft has no id to load
                    // until the mint publishes it during the hop). So until
                    // `hasLoaded`, never fall through to `ForEach(threadMessages)`,
                    // even while an in-flight phase is active: the agent-side
                    // indicator row below carries the wait, and the draft's history
                    // area stays empty rather than flashing the old thread. The
                    // spinner shows only when no in-flight indicator is present.
                    if !hasLoaded || viewModel.isLoadingThread {
                        if inFlightPhase == nil {
                            ProgressView()
                                .tint(AppColors.brandAmber)
                                .frame(maxWidth: .infinity)
                                .padding(.top, 24)
                                .transition(.opacity)
                        }
                    } else if viewModel.threadMessages.isEmpty && inFlightPhase == nil {
                        Text("This conversation is empty.")  // xcstrings
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.top, 24)
                            .transition(.opacity)
                    } else {
                        ForEach(viewModel.threadMessages) { message in
                            bubble(for: message)
                                .id(message.id)
                                // Opacity-only insertion (NOT .move — a vertical
                                // slide would fight the scroll-to-bottom below).
                                // Stable `.id(message.id)` means a whole-array
                                // refresh re-inserts ONLY the new row, never
                                // re-fades existing bubbles.
                                .transition(.opacity)
                        }
                    }

                    // Agent-side "thinking" indicator — the LAST content row,
                    // below the user bubble, mirroring the iOS chat. Constant id
                    // so the row keeps identity as its label flips phase.
                    if let phase = inFlightPhase {
                        thinkingRow(phase: phase, startedAt: inFlightStartedAt)
                            .id(Self.thinkingAnchorID)
                    }

                    // Bottom sentinel for at-bottom detection — always the last
                    // child (sibling to the content branches), so it exists once
                    // the view renders regardless of which branch drew. An 8pt
                    // band (not 1pt) damps rest-position jitter at the boundary.
                    Color.clear
                        .frame(height: 8)
                        .id(Self.bottomAnchorID)
                        // Plain assignment — the composer overlay's
                        // `.animation(…, value: composerShown)` (below) is the
                        // SINGLE driver of the hide/show. Wrapping here too
                        // double-animated the same visual change.
                        .onAppear { isComposerVisible = true }
                        .onDisappear { isComposerVisible = false }
                }
                .padding(.horizontal, 4)
                // ONLY the first-load crossfade is animated. The `inFlightPhase`
                // (thinking-row) and `threadMessages.count` (bubble insertion)
                // transactions are deliberately NOT animated: at the bottom of the
                // list they animate row height WHILE the snap-to-bottom runs, so
                // the scroll chases a still-moving target and the newest bubble
                // reflows / lands under the composer / clips. Deterministic snap
                // (see the scroll handlers below) beats animated choreography on
                // watchOS. The leaf `.transition(.opacity)` on the rows simply has
                // no driving transaction now, so bubbles/thinking-row pop instead
                // of fading — the intended glitch-free behavior.
                .animation(.easeInOut(duration: 0.2), value: hasLoaded)
            }
            // Reserve room under the last bubble for the floating composer so it
            // never obscures a message at the bottom.
            .contentMargins(.bottom, 44, for: .scrollContent)
            // Live content height feeding `snapToBottom`'s verify window.
            .onScrollGeometryChange(for: CGFloat.self, of: { $0.contentSize.height }) { _, newHeight in
                liveContentHeight = newHeight
            }
            .onChange(of: viewModel.threadMessages.count) { _, _ in
                guard !viewModel.threadMessages.isEmpty else { return }
                // A new send/reply must reveal the composer.
                isComposerVisible = true
                snapToBottom(proxy)
                // Auto-speak hook 2 — a reply just appended while this thread
                // is open (the ARRIVAL case: the service armed the request,
                // `.conversationsDidChange` refreshed the messages).
                attemptAutoSpeak()
            }
            .onChange(of: hasLoaded) { _, loaded in
                if loaded, !viewModel.threadMessages.isEmpty {
                    snapToBottom(proxy)
                }
            }
            // Reveal the indicator on a new draft while the thread is still EMPTY —
            // the only case where no message-count change fires to drive the scroll
            // (`.uploading` before any user bubble exists). Once a user bubble has
            // appended, the count-change handler above owns the scroll, so gating on
            // `isEmpty` prevents a second, redundant snap on the user-turn path.
            .onChange(of: inFlightPhase != nil) { _, showing in
                guard showing, viewModel.threadMessages.isEmpty else { return }
                isComposerVisible = true
                snapToBottom(proxy)
            }
        }
        // During capture the history defers (dims + ignores hits) so the
        // recording overlay dominates — but it stays MOUNTED (no teardown of the
        // scroll position / bubbles), so dropping out of capture restores it
        // instantly.
        .opacity(isCapturingHere ? 0.12 : 1)
        .allowsHitTesting(!isCapturingHere)
        .animation(.easeInOut(duration: 0.2), value: isCapturingHere)
        .navigationTitle(threadBackendName)
        .navigationBarTitleDisplayMode(.inline)
        // Hide the back-nav chrome while capturing so a stray edge-swipe can't
        // abandon the live mic; the cancel-X in the overlay is the only exit.
        .toolbar(isCapturingHere ? .hidden : .automatic)
        // Composer floats as a bottom OVERLAY (not `.safeAreaInset`): it never
        // participates in scroll layout, so toggling its visibility can't resize
        // the ScrollView mid-scroll (no stutter / feedback loop). Only offset +
        // opacity + hit-testing animate. Suppressed entirely during capture (the
        // overlay owns the surface).
        .overlay(alignment: .bottom) {
            if !isCapturingHere {
                VStack(spacing: 4) {
                    if let message = inlineErrorMessage { errorBanner(message: message) }
                    if let id = conversationID {
                        WatchMessageComposerBar(viewModel: viewModel, conversationID: id)
                    }
                }
                .frame(maxWidth: .infinity)
                .animation(.easeInOut(duration: 0.2), value: inlineErrorMessage)
                // Presented from HERE, not from inside `errorBanner`: the banner
                // is unmounted the moment the error clears, and a sheet owned by
                // a disappearing view goes with it — including the auto-clear on
                // a later relay success, which would yank the message out from
                // under someone mid-read.
                .sheet(isPresented: $isErrorDetailPresented) {
                    errorDetail(message: inlineErrorMessage ?? "")
                }
                // A new error closes the old one's screen: the sheet shows
                // whatever `inlineErrorMessage` holds, so leaving it open would
                // silently swap the text under the reader.
                .onChange(of: inlineErrorMessage) { _, _ in isErrorDetailPresented = false }
                // Edge-to-edge frosted slab + a 0.5pt top hairline reads as a
                // distinct surface above the thread (vs the old card-width thinMaterial
                // that left a visible seam at the screen edges).
                .background(alignment: .top) {
                    Rectangle()
                        .fill(.ultraThinMaterial)
                        .overlay(alignment: .top) {
                            Rectangle().fill(AppColors.border.opacity(0.5)).frame(height: 0.5)
                        }
                        .ignoresSafeArea(edges: .bottom)
                }
                .offset(y: composerShown ? 0 : 80)
                .opacity(composerShown ? 1 : 0)
                .allowsHitTesting(composerShown)
                .animation(.easeInOut(duration: 0.18), value: composerShown)
            }
        }
        // The dominant capture-first overlay: large stop target + monospaced
        // timer (the relocated `WatchNoteView.recordingView` visuals), with its
        // OWN Always-On-Display indicator so recording state survives wrist-down
        // (the composer — and any indicator living in it — is hidden in AOD).
        .overlay {
            if isCapturingHere {
                WatchThreadCaptureOverlay(
                    recordingService: recordingService,
                    onCancel: popDraftIfNeeded
                )
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: isCapturingHere)
        .task(id: resolvedConversationID) {
            // Bind the open-thread pointer + load history for whichever id is
            // resolved (nil while a `.new` draft hasn't minted — load is a no-op
            // then, and re-runs when the id adopts).
            guard let id = resolvedConversationID else { return }
            // Redaction-safe: a Bool for draft-vs-persisted origin, NEVER the id.
            let isDraft: Bool = { if case .new = autoCaptureTarget { return true } else { return false } }()
            WatchLog.info(.nav, "thread.load", ["isDraft": isDraft])
            viewModel.selectedConversationID = id
            await viewModel.loadThread(for: id)
            hasLoaded = true
            // Auto-speak hook 1 — the thread just finished loading (covers the
            // notification-tap deep-link open, where the request was armed
            // before the route push).
            attemptAutoSpeak()
        }
        .task {
            // Auto-start the bound capture exactly once, independent of the
            // history load finishing (never gate the mic on the thread view —
            // the service drives `.arming` → `.recording` on its own clock).
            // `!didPopDraft`: a cancel that raced a not-yet-run autostart
            // (headless entry starts the service at the push site) must not
            // restart capture on a view that is dismissing itself.
            guard let target = autoCaptureTarget, !didAutoStartCapture, !didPopDraft else { return }
            didAutoStartCapture = true
            WatchLog.info(.nav, "thread.autostart")
            // Stop any TTS the thread was playing before the mic activates
            // (guardrail 7 — this thread's own ThreadSpeaker, distinct from the
            // service's synthesizer).
            speaker.stop()
            recordingService.startCapture(boundTo: target)
        }
        .onChange(of: recordingService.inFlightConversationID) { _, newID in
            adoptMintedIDIfNeeded(newID)
        }
        .onChange(of: recordingService.captureDiscardCount) { _, _ in
            // Catches the service-internal discards a tap can't announce
            // (mis-tap grace, byte-floor, empty transcript) and doubles the
            // overlay X (deduped by `didPopDraft`). An outcome counter, not
            // `.idle` inference — the minted path never bumps it, so a
            // wrist-down mint→reply race can never pop a real conversation.
            popDraftIfNeeded()
        }
        .onChange(of: isCapturingHere) { _, capturing in
            // Any capture starting in THIS thread (auto-start OR the composer's
            // voice button) must yield the audio session — stop this thread's own
            // ThreadSpeaker so TTS never fights the mic (guardrail 7).
            if capturing { speaker.stop() }
        }
        .onChange(of: autoSpeakMailbox.pending) { _, _ in
            // Auto-speak hook 3 — the request was armed AFTER the load/refresh
            // hooks already ran (ordering race between the service's verdict
            // and the store-change refresh). `Request` is Equatable precisely
            // so this onChange can observe it.
            attemptAutoSpeak()
        }
        .onChange(of: scenePhase) { _, newPhase in
            // Auto-speak hook 4 — wrist-raise. A reply that landed while the
            // wrist was down was STAGED (see `handleBackgroundReply`) but not
            // spoken (the play gate in `attemptAutoSpeak` blocks while inactive).
            // Re-attempt on the `.active` edge so raising the wrist to read the
            // reply also speaks it — within the mailbox freshness window (a
            // much-later raise finds the request expired → stays a tappable
            // notification, no jump-scare).
            if newPhase == .active {
                resumeAfterDimIfNeeded()
                attemptAutoSpeak()
            } else {
                // Leaving the foreground (wrist-down / cover-to-mute) is a dim
                // cut for built-in-speaker audio — own the pause NOW, while we
                // still get runtime, instead of reconstructing it on the raise.
                pauseForDimIfNeeded()
            }
        }
        .onChange(of: isLuminanceReduced) { _, reduced in
            // Dim-cut handling, both directions. DIM edge: watchOS is about to
            // (or just did) suspend built-in-speaker TTS — pause it OURSELVES so
            // the state is truthful and the pause carries the system mark that
            // makes the raise auto-resume work (a suspended `AVAudioPlayer` can
            // freeze with `isPlaying == true`, blinding the after-the-fact
            // reconcile). UN-dim edge: reconcile any stuck `.playing` state and
            // auto-resume a reply the dim interrupted. Paired with the scenePhase
            // hook because the ambient dim may keep `scenePhase == .active` and
            // only toggle luminance — so luminance is the extra edge, not the only
            // one. All idempotent (a resumed/paused reply no-ops the second call).
            if reduced {
                pauseForDimIfNeeded()
            } else {
                resumeAfterDimIfNeeded()
            }
        }
        .onDisappear {
            speaker.stop()
            // A popped view must not keep a proxy-bound snap-verify task alive.
            snapVerifyTask?.cancel()
            // Clear the pointer so a background-reply notification fired AFTER
            // pop doesn't trigger a stale refresh on a no-longer-visible thread.
            if let id = conversationID, viewModel.selectedConversationID == id {
                viewModel.selectedConversationID = nil
            }
        }
    }

    /// The id the thread currently shows — published so `.task(id:)` re-runs the
    /// load when a `.new` draft adopts its minted id.
    private var resolvedConversationID: UUID? { conversationID }

    /// Adopt the id the recording service minted for a `.new` draft shell. Only
    /// fires while THIS thread is still a draft (nil id) AND a capture is in
    /// flight for it — so an unrelated headless mint in another context can't
    /// hijack the draft. Idempotent.
    private func adoptMintedIDIfNeeded(_ newID: UUID?) {
        guard conversationID == nil,
              autoCaptureTarget != nil,
              let id = newID else { return }
        conversationID = id
    }

    /// A `.new` draft whose capture retired without minting has nothing to
    /// show — its load `.task(id:)` can never run, so the only render is the
    /// forever-spinner. Pop back to the previous screen instead (the pre-push
    /// design's "cancel returns you home", restored). One-shot; no-op for
    /// adopted drafts (non-nil id) and `.existing` entries, which keep their
    /// thread on a cancel.
    private func popDraftIfNeeded() {
        guard !didPopDraft, isDraftCaptureEntry, conversationID == nil else { return }
        didPopDraft = true
        WatchLog.info(.nav, "nav.popDraft")
        dismiss()
    }

    /// Drain the one-shot auto-speak request for THIS thread (Read replies
    /// aloud — reply arrival + notification-tap open): speak the latest agent
    /// reply through this view's own `ThreadSpeaker` — the SAME path as the
    /// tap-to-speak control, so the bubble shows the playing state + pause
    /// control and audio ownership stays single. Three callers cover the three
    /// timing shapes: the `.task(id:)` load completion (notification-tap open),
    /// the message-count change (reply appended while the thread is open), and
    /// the coordinator's `pending` change (request armed AFTER the refresh
    /// already ran). `consume` is the LAST guard — it is destructive, so the
    /// request must survive until a speakable agent message actually exists.
    /// Wrist-raise / un-dim recovery for a spoken reply that watchOS silently
    /// suspended on the ambient dim (built-in-speaker audio can't survive the dim
    /// — a hard platform limit). Reconcile the stuck `.playing` UI state back to
    /// the engine's truth (button flips to the play glyph → one-tap resume), then
    /// auto-resume if the dim (not the user) paused it, within the speaker's
    /// freshness window. Order matters: reconcile FIRST so a stale `.playing` is
    /// flipped to `.paused` + marked system-paused, then auto-resume acts on it.
    private func resumeAfterDimIfNeeded() {
        speaker.reconcileSystemPauseIfNeeded()
        speaker.autoResumeIfSystemPaused()
    }

    /// Dim-edge proactive pause — the PRIMARY half of dim-cut handling (the
    /// reconcile above is the after-the-fact fallback). watchOS kills
    /// built-in-speaker audio the instant the screen dims, freezing the player
    /// in a state the reconcile can misread as still-active — so we pause it
    /// OURSELVES while the dim edge still gives us runtime: position preserved,
    /// button truthfully flips to the play glyph, and the system mark arms the
    /// wrist-raise auto-resume. Gate ORDER is load-bearing: the speaker-state
    /// check runs FIRST because `outputRouteSurvivesDim` is a synchronous
    /// audio-server IPC (`AVAudioSession.currentRoute`) and the dim/scene edges
    /// fire on every wrist lower — a thread with nothing playing must not pay
    /// the route query at all (it can stall the main thread for seconds when
    /// the audio daemon is distressed). Then route-gated: a Bluetooth route
    /// (AirPods) survives the dim and must keep playing.
    private func pauseForDimIfNeeded() {
        // Mirrors `systemDimPause()`'s own guard, hoisted above the route IPC.
        guard speaker.speakingMessageID != nil, speaker.state == .playing else { return }
        guard !WatchReplySpeaker.outputRouteSurvivesDim else { return }
        // Milestone fires only when a dim edge actually pauses playback
        // (event only, no content).
        WatchLog.note(.state, "tts.dimpause")
        speaker.systemDimPause()
    }

    private func attemptAutoSpeak() {
        guard let id = conversationID else { return }
        // Defense-in-depth: never speak under a live capture in this thread.
        // The service clears the coordinator whenever a capture starts, so
        // this shouldn't fire — but if a request ever slips through, the mic
        // wins (guardrail 7).
        guard !isCapturingHere else { return }
        // PLAY GATE (separate from the mailbox's staging eligibility): only speak
        // while the wrist is up. A reply that landed wrist-down is staged (see
        // `handleBackgroundReply`) but not spoken until the scene is `.active` —
        // the `.onChange(of: scenePhase)` hook re-fires this on the wrist-raise.
        // Guard BEFORE the destructive `consume`, so an inactive delivery never
        // burns the request; it survives (within the freshness window) until the
        // user looks. The notification-tap open is `.active` by construction, so
        // that path passes here too.
        guard scenePhase == .active else { return }
        // PEEK (no burn) the staged request, then let the pure picker decide
        // the text: a reply-arrival request carries the EXACT reply, which wins
        // over `threadMessages` — on a follow-up the array still holds the PRIOR
        // reply here (the new bubble lands via an async, coalesced refresh).
        // A notification-tap open carries no payload → falls back to the latest
        // agent bubble. `nil` = nothing speakable yet, so we skip the
        // destructive `consume` and the one-shot survives to the refresh.
        let staged = autoSpeakMailbox.pending
        let arrayLatest = viewModel.threadMessages
            .last(where: { $0.role == "agent" && !$0.text.isEmpty })
            .map { (id: $0.id, text: $0.text) }
        guard let pick = AutoSpeakSelection.resolve(staged: staged, arrayLatest: arrayLatest) else { return }
        guard autoSpeakMailbox.consume(matching: id) else { return }
        speaker.speak(pick.text, messageID: pick.id)
    }

    // MARK: - Busy banner

    // MARK: - Thinking indicator (agent-side, in-list)

    /// Agent-side "thinking" row rendered as the last item of the message list,
    /// mirroring the iOS chat indicator: a left-aligned gray bubble (matching
    /// agent bubbles) with a mini amber spinner, a phase label
    /// (`ThinkingIndicator.label` — "Transcribing…" → "{gateway} is
    /// answering…"), and — only while `.answering` — an elapsed `m:ss` clock that
    /// appears after 3s. Subdued in Always-On Display. Elapsed time recomputes
    /// from `startedAt` each tick, so a dropped wrist (where the timeline may not
    /// fire every second) catches up on the next update rather than drifting.
    @ViewBuilder
    private func thinkingRow(phase: ThinkingPhase, startedAt: Date?) -> some View {
        HStack {
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.mini)
                    .tint(AppColors.brandAmber)
                Text(ThinkingIndicator.label(phase: phase, backendName: threadBackendName))
                    .font(.caption2)
                    .foregroundStyle(AppColors.textSecondary)
                    // In-place crossfade of "Transcribing…" → "{gateway} is
                    // answering…" — the transaction comes from the LazyVStack's
                    // `.animation(…, value: inFlightPhase)`; the row keeps its
                    // constant `thinkingAnchorID` identity (no churn).
                    .contentTransition(.opacity)
                if let startedAt {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        let elapsed = context.date.timeIntervalSince(startedAt)
                        // Always laid out (reserves its width from the first
                        // tick) so the bubble never SNAPS wider at the 3 s mark —
                        // it fades in via opacity instead, and the digits roll
                        // with numericText. Keying the fade on the `> 3` Bool
                        // (not on isLuminanceReduced) keeps AOD swaps instant.
                        Text(ThinkingStage.clock(max(0, elapsed)))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(AppColors.textTertiary)
                            .contentTransition(.numericText())
                            .opacity(elapsed > 3 ? 1 : 0)
                            .animation(.easeInOut(duration: 0.25), value: elapsed > 3)
                            .animation(.snappy(duration: 0.2), value: Int(elapsed))
                    }
                }
            }
            .padding(8)
            .background(bubbleBackground(isUser: false))
            .opacity(isLuminanceReduced ? 0.5 : 1)
            Spacer(minLength: 16)
        }
        .transition(.opacity)
    }

    // MARK: - Error banner

    /// Compact in-thread error line above the composer — the thread-stack
    /// counterpart of the root error view. The xmark resets the service to
    /// idle (mirrors iOS `recorder.dismissError()`); a fresh send / mic tap
    /// also recovers on its own, so the banner never gates the composer.
    ///
    /// The line stays SHORT on purpose and tapping opens the whole message on
    /// its own screen. A banner tall enough for the longest message would bury
    /// the conversation it sits over and still clip at large Dynamic Type, so
    /// the preview is a summary with a way through — never the only copy of
    /// text the user has to act on. See `errorDetail`.
    @ViewBuilder
    private func errorBanner(message: String) -> some View {
        HStack(spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(AppColors.textSecondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                // The affordance that keeps the truncation honest: the ellipsis
                // alone reads as "that's all there is", which is how the clipped
                // remedy went unnoticed. A chevron says there is more and it is
                // reachable.
                Image(systemName: "chevron.forward")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(AppColors.textTertiary)
            }
            .contentShape(Rectangle())
            .onTapGesture { isErrorDetailPresented = true }
            // One element, so VoiceOver reads the whole message (it exposes the
            // untruncated string) rather than the icon and a clipped fragment.
            .accessibilityElement(children: .combine)
            .accessibilityHint(Text(String(localized: LocalizedStringResource(
                "watch.thread.error.expandHint",
                defaultValue: "Tap to show the full message"
            ))))  // xcstrings: hardening
            Button {
                recordingService.dismissError()
                // User abandonment is view-local knowledge — the service must
                // NOT emit a discard from `dismissError()` (it doubles as the
                // internal error-supersede on new attempts and the
                // relay-success auto-clear, where a bump would pop a live
                // draft mid-mint). A dismissed error on an un-minted draft is
                // a dead end (no composer without an id) — pop it here.
                popDraftIfNeeded()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(AppColors.textSecondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(String(localized: LocalizedStringResource(
                "watch.thread.error.dismiss",
                defaultValue: "Dismiss error"
            ))))  // xcstrings: hardening
        }
        .padding(.horizontal, 8)
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }

    /// The banner's message in full, on a screen that can hold it.
    ///
    /// A `ScrollView` rather than a taller banner: here the crown is this view's
    /// own, so the text fits at ANY Dynamic Type size and at any length a future
    /// localization reaches. That is the property the banner cannot have, and
    /// the reason this surface exists — a terminal error's remedy must never be
    /// unreachable, and on the wrist every certificate verdict is terminal.
    @ViewBuilder
    private func errorDetail(message: String) -> some View {
        ScrollView {
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.title3)
                    .foregroundStyle(.orange)
                Text(message)
                    .font(.caption)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(AppColors.textSecondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        }
    }

    // MARK: - Bubble

    @ViewBuilder
    private func bubble(for message: MessageRecord) -> some View {
        let isUser = message.role == "user"
        HStack {
            if isUser { Spacer(minLength: 16) }

            VStack(alignment: isUser ? .trailing : .leading, spacing: 4) {
                // Per-attachment rendering ordered by `sequence`, driven by the
                // shared `AttachmentRecord.watchDisplayClass` classifier. Images
                // render the small synced `thumbnailData` inline (~50KB, NEVER
                // full-resolution); a synced text/code file becomes a tappable row
                // into `WatchAttachmentTextView` (watchOS has no QuickLook); server
                // references + not-yet-synced + oversized files stay passive
                // markers. The Watch stays voice-only (no attach affordance; the
                // composer is `WatchNoteView`) — attachments here are display-only,
                // and the iPhone owns file transfer.
                // Server-file rows are deduped by `storedKey` (two devices'
                // concurrent retro output scans can merge duplicates — same guard
                // the iOS bubble uses via `MessageRowFormatters.dedupedServerFiles`);
                // other attachment kinds pass through untouched. Recombined + ordered.
                let serverFiles = MessageRowFormatters.dedupedServerFiles(
                    message.attachments.filter { $0.isServerFile }
                )
                let orderedAttachments = (message.attachments.filter { !$0.isServerFile } + serverFiles)
                    .sorted { $0.sequence < $1.sequence }
                ForEach(orderedAttachments) { attachment in
                    attachmentView(for: attachment, isUser: isUser, messageID: message.id)
                }

                // PLAINTEXT — no Markdown render on Watch, but AGENT
                // turns collapse Markdown links to their label
                // (`ReplySanitizer.linkCollapsed`): a raw `[name](target)` is
                // wrap-noise on a 40mm line AND the target can leak the
                // gateway host's filesystem path. User turns render verbatim
                // (their own words, links unlikely). When the turn is
                // attachment-only (empty text), skip the empty Text so the
                // placeholder IS the bubble body rather than an empty line.
                if !message.text.isEmpty || message.attachments.isEmpty {
                    Text(isUser ? message.text : ReplySanitizer.linkCollapsed(message.text))
                        .font(.caption)
                        .foregroundStyle(isUser ? .white : .primary)
                        .multilineTextAlignment(isUser ? .trailing : .leading)
                        .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
                }

                // Tap-to-speak — ASSISTANT (agent) replies only, docked at the
                // bubble's TRAILING (right) edge. State-driven glyph (idle →
                // loading → playing → paused), mirroring the iPhone/iPad/Mac
                // control: tap pauses/resumes from position, tapping a different
                // reply supersedes. The amber active outline (below) marks the
                // speaking bubble.
                if !isUser {
                    HStack(spacing: 4) {
                        // Fallback-voice transparency: when this reply's latest
                        // playback fell back to the Apple built-in voice (the
                        // engine emitted `.fallbackStarted`), surface a subtle
                        // caption at the footer's leading edge, opposite the
                        // speak control. Only rendered while the marker holds.
                        if speaker.usedFallbackVoice(for: message.id) {
                            Text(LocalizedStringResource(
                                "thread.speak.fallbackVoice",
                                defaultValue: "Built-in voice"
                            ))  // xcstrings: new key
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .accessibilityLabel(Text(LocalizedStringResource(
                                "thread.speak.fallbackVoice.a11y",
                                defaultValue: "Spoken with the built-in voice"
                            )))
                        }
                        Spacer(minLength: 0)
                        speakControl(for: message)
                    }
                }
            }
            .padding(8)
            .background(bubbleBackground(isUser: isUser))
            // Amber active-speaking outline on the agent bubble currently being
            // read aloud, so the user can locate the source. Suppressed in
            // Always-On Display (don't blaze in AOD). Only assistant bubbles ever
            // reach a non-idle speakState.
            .overlay {
                let speaking = speaker.speakState(for: message.id) != .idle
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(
                        AppColors.brandAmber.opacity(speaking && !isLuminanceReduced ? 0.6 : 0),
                        lineWidth: 1
                    )
                    // Fade the ring with the SPEAK state only — keying on
                    // `speaking` (not the AOD-combined value) leaves the AOD
                    // engage/disengage swap instant, per the AOD guard.
                    .animation(.easeInOut(duration: 0.2), value: speaking)
            }

            if !isUser { Spacer(minLength: 16) }
        }
    }

    /// Localized untitled fallback for a text attachment with no filename —
    /// shared by the tappable row label, the oversized marker, and the viewer's
    /// navigation title.
    private static let untitledFileResource = LocalizedStringResource(
        "watch.attachment.untitled",
        defaultValue: "Attached file"
    )  // xcstrings

    /// Render one attachment per its `WatchDisplayClass`. Server references +
    /// not-yet-synced rows collapse to the same passive "[File attached]" caption
    /// (they are distinct classes for the classifier's correctness + tests, but
    /// share the wrist's read-only presentation).
    @ViewBuilder
    private func attachmentView(for attachment: AttachmentRecord, isUser: Bool, messageID: UUID) -> some View {
        switch AttachmentRecord.watchDisplayClass(for: attachment) {
        case .imageThumbnail:
            imageAttachmentView(attachment, isUser: isUser)
        case .viewableText:
            viewableTextRow(attachment, isUser: isUser, messageID: messageID)
        case .oversizedText:
            oversizedTextMarker(attachment, isUser: isUser)
        case .serverPlaceholder:
            serverFileMarker(attachment, isUser: isUser)
        case .filePlaceholder:
            fileMarker(isUser: isUser)
        }
    }

    /// Image attachment — the small synced `thumbnailData` inline, with a
    /// caption-styled `[Image attached]` fallback for a thumbnail that hasn't
    /// synced yet (so the turn is never silently truncated).
    @ViewBuilder
    private func imageAttachmentView(_ attachment: AttachmentRecord, isUser: Bool) -> some View {
        if let image = Self.thumbnail(for: attachment) {
            image
                .resizable()
                .scaledToFit()
                .frame(maxWidth: 120, alignment: isUser ? .trailing : .leading)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
        } else {
            Text(LocalizedStringResource("[Image attached]"))  // xcstrings
                .font(.caption2)
                .foregroundStyle(isUser ? .white.opacity(0.85) : .secondary)
                .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
        }
    }

    /// Tappable row for a locally-viewable text/code file — pushes the
    /// `.attachmentText` route through the enclosing NavigationStack (the SAME
    /// `navigationDestination(for: WatchRoute.self)` host in `WatchNoteView` the
    /// launchpad's Conversations link uses; hit-testing is already suppressed
    /// during capture by the history's `.allowsHitTesting`). A row with no
    /// resolved `conversationID` (never happens once `hasLoaded`) degrades to the
    /// passive marker rather than a dead link.
    @ViewBuilder
    private func viewableTextRow(_ attachment: AttachmentRecord, isUser: Bool, messageID: UUID) -> some View {
        let name = attachment.filename ?? String(localized: Self.untitledFileResource)
        if let convID = conversationID {
            NavigationLink(value: WatchRoute.attachmentText(
                conversationID: convID,
                messageID: messageID,
                attachmentID: attachment.id
            )) {
                HStack(spacing: 4) {
                    Image(systemName: "doc.text")
                    Text(name)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .foregroundStyle(.tertiary)
                }
                .font(.caption2)
                .foregroundStyle(isUser ? .white.opacity(0.85) : .secondary)
                .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(LocalizedStringResource(
                "watch.attachment.view.a11y",
                defaultValue: "View attached file \(name)"
            )))  // xcstrings
        } else {
            fileMarker(isUser: isUser)
        }
    }

    /// Passive marker for a text file too large to lay out on the wrist — the
    /// filename plus a "too large" caption (no viewer route; laying out a
    /// multi-hundred-KB `Text` on watchOS is a realistic UI freeze).
    @ViewBuilder
    private func oversizedTextMarker(_ attachment: AttachmentRecord, isUser: Bool) -> some View {
        let name = attachment.filename ?? String(localized: Self.untitledFileResource)
        VStack(alignment: isUser ? .trailing : .leading, spacing: 2) {
            Text(name)
                .lineLimit(1)
            Text(LocalizedStringResource(
                "watch.attachment.oversized",
                defaultValue: "Too large to view on Apple Watch"
            ))  // xcstrings
            .foregroundStyle(.tertiary)
        }
        .font(.caption2)
        .foregroundStyle(isUser ? .white.opacity(0.85) : .secondary)
        .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
    }

    /// `.file`-style byte formatter for the server marker ("1.2 MB"). Static:
    /// `ByteCountFormatter` allocation isn't free and the row builder runs on
    /// every body pass (speak-state flips, AOD swaps, composer toggles).
    private static let fileSizeFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f
    }()

    /// Informative passive marker for a server-reference file the wrist can't
    /// download by design: the filename (untitled fallback) + a formatted size
    /// (omitted when `byteSize` is 0 / unknown) + a second line pointing to a
    /// capable device. AOD dims via the bubble opacity, not a layout branch here
    /// (mirrors `oversizedTextMarker`).
    @ViewBuilder
    private func serverFileMarker(_ attachment: AttachmentRecord, isUser: Bool) -> some View {
        let name = attachment.filename ?? String(localized: Self.untitledFileResource)
        VStack(alignment: isUser ? .trailing : .leading, spacing: 2) {
            Text(name)
                .lineLimit(1)
            if attachment.byteSize > 0 {
                Text(Self.fileSizeFormatter.string(fromByteCount: Int64(attachment.byteSize)))
                    .foregroundStyle(.tertiary)
            }
            Text(LocalizedStringResource(
                "watch.attachment.location",
                defaultValue: "On your iPhone, iPad or Mac"
            ))  // xcstrings
            .foregroundStyle(.tertiary)
        }
        .font(.caption2)
        .foregroundStyle(isUser ? .white.opacity(0.85) : .secondary)
        .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
    }

    /// The passive "[File attached]" caption for a not-yet-synced text row (nil
    /// `extractedText`, content still arriving via CloudKit).
    @ViewBuilder
    private func fileMarker(isUser: Bool) -> some View {
        Text(LocalizedStringResource("[File attached]"))  // xcstrings
            .font(.caption2)
            .foregroundStyle(isUser ? .white.opacity(0.85) : .secondary)
            .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
    }

    /// The state-driven Speak control for an agent bubble — idle (speaker glyph) →
    /// loading (amber spinner) → playing (amber pause) → paused (amber play),
    /// matching the iPhone/iPad/Mac footer control. Tap routes through the shared
    /// `ThreadSpeaker` (pause/resume/supersede).
    @ViewBuilder
    private func speakControl(for message: MessageRecord) -> some View {
        let state = speaker.speakState(for: message.id)
        Button {
            speaker.speak(message.text, messageID: message.id)
        } label: {
            Group {
                switch state {
                case .idle:
                    Image(systemName: "speaker.wave.2.fill")
                        .font(.caption2)
                        .foregroundStyle(AppColors.brandAmber)
                case .loading:
                    ProgressView()
                        .controlSize(.small)
                        .tint(AppColors.brandAmber)
                case .playing:
                    Image(systemName: "pause.fill")
                        .font(.caption2)
                        .foregroundStyle(AppColors.brandAmber)
                case .paused:
                    Image(systemName: "play.fill")
                        .font(.caption2)
                        .foregroundStyle(AppColors.brandAmber)
                }
            }
            // Fixed visual slot so the speaker → spinner → pause → play swap never
            // snaps the bubble width. NO crossfade: the glyph swaps the instant
            // `state` flips, so a tap reads as immediate (no animation is the right
            // animation here — the complaint was latency).
            .frame(width: 22, height: 22)
            // Forgiving ~40pt hit target around the compact 22pt glyph — a bare
            // 22pt plain button is half Apple's ~44pt HIG minimum, so taps on the
            // wrist were getting missed. `.contentShape` makes the whole slot tappable.
            .frame(width: 40, height: 40)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(speakAccessibilityLabel(for: state)))
    }

    /// VoiceOver label for the Speak control, switching with the speak phase —
    /// mirrors the iPhone control's labels.
    private func speakAccessibilityLabel(for state: SpeakState) -> LocalizedStringResource {
        switch state {
        case .idle: return LocalizedStringResource("Read aloud")  // xcstrings (existing key)
        case .loading: return LocalizedStringResource("Loading")  // xcstrings
        case .playing: return LocalizedStringResource("Pause")  // xcstrings
        case .paused: return LocalizedStringResource("Resume")  // xcstrings
        }
    }

    /// User bubbles are bright orange normally; in Always-On Display (wrist
    /// lowered) the solid orange is swapped for a dim gray fill + orange outline
    /// so it stays identifiable as "user" without blazing or draining battery.
    /// Agent bubbles are already subdued gray — unchanged.
    @ViewBuilder
    private func bubbleBackground(isUser: Bool) -> some View {
        if isUser {
            if isLuminanceReduced {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.gray.opacity(0.28))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(AppColors.brandAmber.opacity(0.5), lineWidth: 1)
                    )
            } else {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.orange.opacity(0.85))
            }
        } else {
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.gray.opacity(0.25))
        }
    }

    // MARK: - Thumbnail decode

    /// Decoded-thumbnail cache keyed by ATTACHMENT id — the key choice is
    /// load-bearing: `refreshThread` wholesale-replaces `threadMessages` on
    /// every `.conversationsDidChange`, so memoizing on the record itself would
    /// be redone each refresh, while the attachment id survives refetches.
    /// Bounded: thumbnails are ≤256px (`ImageProcessor.thumbnailMaxPixel`) and
    /// `NSCache` additionally evicts under memory pressure.
    private static let thumbnailCache: NSCache<NSUUID, UIImage> = {
        let cache = NSCache<NSUUID, UIImage>()
        cache.countLimit = 48
        // ~12 MiB decoded-RGBA budget on top of the count cap — a thread of
        // larger thumbnails can't pin more memory than the count limit alone
        // would let it (48 × a big decode ≫ 12 MiB). Cost is per-image below.
        cache.totalCostLimit = 12 * 1024 * 1024
        return cache
    }()

    /// watchOS analogue of `AttachmentImageGrid.platformImage(from:)` (the iOS /
    /// macOS file is not in the Watch target). Decodes the small synced
    /// `thumbnailData` into a SwiftUI `Image`, cached per attachment — the row
    /// builder runs on every body pass (speak-state flips, AOD swaps, composer
    /// toggles), and an uncached `UIImage(data:)` re-decodes each visible
    /// thumbnail on the main thread every time. Nil on missing data / decode
    /// failure drives the `[Image attached]` text fallback (never cached, so a
    /// thumbnail that syncs in later still renders).
    private static func thumbnail(for attachment: AttachmentRecord) -> Image? {
        if let cached = thumbnailCache.object(forKey: attachment.id as NSUUID) {
            return Image(uiImage: cached)
        }
        guard let data = attachment.thumbnailData, let ui = UIImage(data: data) else { return nil }
        // Decoded-RGBA cost estimate (pixels × 4) feeds `totalCostLimit`.
        let pixelW = ui.cgImage?.width ?? Int(ui.size.width * ui.scale)
        let pixelH = ui.cgImage?.height ?? Int(ui.size.height * ui.scale)
        thumbnailCache.setObject(ui, forKey: attachment.id as NSUUID, cost: pixelW * pixelH * 4)
        return Image(uiImage: ui)
    }
}

// MARK: - Capture overlay (relocated from WatchNoteView.recordingView)

/// The dominant in-thread capture surface. Renders over the (dimmed) history
/// while the recording service is `.arming` / `.recording` for this thread.
/// Carries its OWN Always-On-Display branch (red dot + timer) so recording
/// state survives wrist-down — the thread's composer (and anything living in it)
/// is suppressed in AOD, so an indicator that lived only there would vanish.
///
/// Visuals are the relocated `WatchNoteView.recordingView` (large stop ring +
/// monospaced timer + the `isLuminanceReduced` minimal branch + cancel-X).
private struct WatchThreadCaptureOverlay: View {
    @Bindable var recordingService: WatchRecordingService
    /// Fired right after the cancel-X's `cancelRecording()` — the parent pops
    /// a discarded draft immediately on the tap itself (deterministic), rather
    /// than waiting for the `captureDiscardCount` echo.
    let onCancel: () -> Void
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced

    /// True once the mic is genuinely live (vs `.arming` = "Starting…").
    private var isLive: Bool {
        if case .recording = recordingService.state { return true }
        return false
    }

    var body: some View {
        ZStack {
            // Opaque backdrop so dimmed history doesn't bleed through the overlay.
            Rectangle()
                .fill(.black)
                .opacity(isLuminanceReduced ? 1 : 0.92)
                .ignoresSafeArea()

            if isLuminanceReduced {
                // AOD: minimal red dot + timer ONLY (battery + glanceable).
                VStack(spacing: 6) {
                    Circle()
                        .fill(.red.opacity(0.6))
                        .frame(width: 16, height: 16)
                    if isLive {
                        WatchRecordingIndicator(recordingService: recordingService, font: .title3)
                    }
                }
            } else {
                VStack(spacing: 10) {
                    if isLive {
                        ZStack {
                            Circle()
                                .stroke(Color.orange.opacity(0.3), lineWidth: 4)
                                .frame(width: 80, height: 80)
                            Circle()
                                .fill(Color.red)
                                .frame(width: 24, height: 24)
                        }

                        WatchRecordingIndicator(recordingService: recordingService, font: .title2)

                        if recordingService.nearMaxDuration {
                            Text("1 min left")  // xcstrings (relocated)
                                .font(.caption2)
                                .foregroundStyle(.orange)
                                .transition(.opacity)
                        }

                        Button {
                            WKInterfaceDevice.current().play(.click)
                            recordingService.stopRecording()
                        } label: {
                            Text("Tap to Stop")  // xcstrings (relocated)
                                .font(.caption)
                        }
                        .buttonStyle(.bordered)
                    } else {
                        // `.arming` — mic not yet live. Spinner + "Starting…"
                        // (plain literal key so it renders without an xcstrings
                        // entry under a headless build).
                        ProgressView()
                            .tint(.orange)
                        Text("Starting…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 8)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: recordingService.nearMaxDuration)
        // Swallow stray taps. Stop is the "Tap to Stop" BUTTON's job alone —
        // do NOT add a whole-surface tap-to-stop gesture: a full-screen stop
        // target lies under the cancel-X, so every near-miss on the X becomes a
        // stop-and-send, shipping the audio the user meant to discard. A tap
        // that hits neither button does nothing — the destructive direction here
        // is sending, not discarding.
        .contentShape(Rectangle())
        // Cancel-X (top-leading), wrist-raised only — the single exit while
        // capturing (back-nav is hidden). The visible circle is chrome AND
        // aiming aid; the outer frame is the real hit region (44pt, mirrors
        // WatchMessageComposerBar's trailing control). A bare `.caption` glyph
        // is a ~12pt target no wrist can reliably hit.
        .overlay(alignment: .topLeading) {
            if !isLuminanceReduced {
                Button {
                    WKInterfaceDevice.current().play(.click)
                    recordingService.cancelRecording()
                    onCancel()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.9))
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(.white.opacity(0.15)))
                        .frame(width: 44, height: 44)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Cancel"))  // xcstrings (relocated)
            }
        }
    }
}

/// Perf-isolated recording timer readout. Reading `recordingService.recordingTime`
/// (which ticks at 10 Hz) ONLY inside this leaf view keeps the 10 Hz invalidation
/// off the thread's bubble `LazyVStack` — only this tiny `Text` re-renders per
/// tick (guardrail 6).
private struct WatchRecordingIndicator: View {
    @Bindable var recordingService: WatchRecordingService
    let font: Font

    private var formattedTime: String {
        let minutes = Int(recordingService.recordingTime) / 60
        let seconds = Int(recordingService.recordingTime) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    var body: some View {
        Text(formattedTime)
            .font(font.monospacedDigit())
            .foregroundStyle(recordingService.nearMaxDuration ? .orange : .primary)
    }
}
