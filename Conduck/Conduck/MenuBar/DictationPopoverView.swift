// SPDX-License-Identifier: Apache-2.0

#if os(macOS)
// Conduck
// DictationPopoverView.swift
//
// The macOS menu-bar popover is an ambient, HOTKEY-FIRST voice HUD — press
// ⌘⇧1, talk, read/hear/copy the answer, dismiss. NOT a scrolling mini-chat (the
// full thread lives in the window, "Open in Window"). Minimal chrome: a single
// quiet "Open in Window" icon top-right (HIDDEN while recording/transcribing —
// those are pure HUDs), the status/reply slot, and a CONTEXTUAL control row.
//
// Controls are hotkey-first: there is NO mic/stop button. ⌘⇧1 starts; ⌘⇧1 or
// clicking the menu-bar icon stops-and-sends; Esc cancels (wired in
// `MenuBarController`). The only on-screen buttons are a CANCEL while
// recording/thinking, and COPY + SPEAK on a settled reply. CANCEL (the X) and
// Esc both ABORT-AND-CLOSE — they discard the active recording / in-flight
// reply AND any staged ⌘⇧2 screenshot + typed draft, then dismiss the popover
// in one press (never land on the start screen). Only an IMPLICIT click-away
// preserves a staged composition.
//
// The `content` router resolves state in this PRIORITY:
//   1. service `.recording`  → `recordingStatusView` (timer + a compact Cancel X)
//   2. `isWorking`           → `workingView` — ONE view for the WHOLE turn: STT
//                              (`.processing` → "Transcribing…"), the brief
//                              hand-off gap (`coordinator.turnStarting`), and the
//                              agent wait (`isAwaitingReply` → "{gateway} is
//                              answering…"). Identical layout + size across all
//                              three (spinner + label, Cancel-X space always
//                              reserved) so transcribing → answering NEVER resizes
//                              the popover.
//   3. !isRemoteAgentConfigured → `unconfiguredEmptyState` (gear → Settings)
//   4. VM `sendError` (idle)  → `sendErrorView` — the AGENT turn failed (gateway
//                              unreachable / auth / timeout). Rendered in the
//                              content slot so the popover never falls back to
//                              the stale previous reply, which would read as the
//                              answer to the question that just failed.
//   5. retained quick-lane reply → `replyView` (self-sizing Markdown, scrolls past 300pt) —
//                              the reply to the most recent menu-bar/hotkey capture ONLY,
//                              NOT "the last agent message in the bound thread"
//   6. else                  → `startEmptyState` (single "press ⌘⇧1 to talk" hint)
//
// `turnStarting` is load-bearing: without it, the async gap between STT's
// `state=.idle` and the send Task claiming `isAwaitingReply` renders the
// PREVIOUS reply (or the empty hint) for a frame — the transcribing→answering
// flicker. No "Heard:" line (clutter); the reply is the hero.
//
// Header + the bottom footer band are HIDDEN during recording and the whole
// working phase (their Cancel X is inline), so chrome never pops in mid-turn.
// They return on the settled reply (Open-in-Window header + Copy/Speak footer),
// on error (Retry/Dismiss footer), and on the empty state. Copy + Speak mirror
// `ConversationThreadView.MessageBubble` (same `ThreadSpeaker` + `bubble.*`
// strings — play/pause/resume parity).
//
// The popover is the QUICK LANE: it renders the long-lived
// `coordinator.quickViewModel` (reused across popover open/close, so the last
// answer is RETAINED on reopen; a view reading `isAwaitingReply` +
// `lastPopoverReply` auto-re-renders when the quick-lane reply lands) — but
// the DESTINATION of the next capture renders from `coordinator.quickDestination`,
// the capture-time snapshot, NEVER from the bound VM. The VM names where the LAST
// turn landed; the snapshot names where the NEXT one will (and is exactly what
// `handleTranscript` consumes at send time, so display==send by construction).
// PROVENANCE GATE: the reply slot shows ONLY the reply to the most recent
// menu-bar/hotkey capture (`quickViewModel.lastPopoverReply`), never a
// window-typed or iPhone/Watch reply that merely landed in this shared VM's
// conversation via CloudKit — the menu bar must not claim authorship of a turn
// its lane never initiated. The window's explicit lane (`windowViewModel`) is
// invisible here — browsing or typing there never moves what this popover shows
// or targets. A cross-thread unread reply surfaces via the unread dot + the
// read-only dot-click override (`popoverOverrideViewModel`), whose reply slot
// DOES show that thread's latest agent message (an explicit peek).
//
// Sizing: compact HUD — width 300pt, height HUGS the content. The reply
// ScrollView self-sizes to the answer's natural height and caps at 300pt
// (short hugs, long scrolls); NSPopover animates the resize when the answer
// lands (no explicit outer-height animation).

import KeyboardShortcuts
import Textual
import SwiftUI

struct DictationPopoverView: View {
    let coordinator: MenuBarCoordinator
    /// Opens the `conversations` window. Injected by `MenuBarController` (the
    /// popover is hosted in an `NSHostingController`, outside the App scene
    /// graph, so `@Environment(\.openWindow)` is unavailable here).
    let onOpenWindow: () -> Void
    /// Closes the popover. Cancel actions and Esc both ABORT-and-CLOSE (one press
    /// = out), so the view needs a way to dismiss; injected by `MenuBarController`
    /// because the view can't reach the `NSPopover` directly.
    let dismiss: () -> Void

    private var service: DictationService { coordinator.dictationService }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Speak engine for the reply's Speak control — same `ThreadSpeaker` the
    /// chat bubble uses (play/pause/resume parity). View-local. Backed by the
    /// iOS/macOS `ReplyVoice` speak engine.
    @State private var speaker = ThreadSpeaker(engine: ReplyVoice())
    /// Drives the Copy control's 1.5s checkmark flip (mirrors `MessageBubble`).
    @State private var didCopy = false

    /// Measured natural height of the reply Markdown — lets the reply ScrollView
    /// self-size to its content up to a cap (so a short answer hugs instead of
    /// padding a fixed-tall box, a long one scrolls). Set via `.onGeometryChange`.
    @State private var replyHeight: CGFloat = 0

    /// Whether the reply ScrollView is scrolled to (or fits within) its bottom.
    /// Gates the bottom fade OFF at the end of a long reply so the last lines
    /// stay crisp — the fade is a "more below" cue, not permanent chrome. Driven
    /// solely by `onScrollGeometryChange` (never reset manually — that desyncs
    /// from the modifier's own last-transformed value across replies).
    @State private var replyAtBottom = false

    /// One-time "new ⌘⇧2 Screenshot & Ask" tip visibility, seeded from
    /// `SettingsManager.shouldShowScreenshotAskTip()` on appear. Shown once in the
    /// start state for existing users; dismissed (and persisted seen) on its X.
    @State private var showsScreenshotAskTip = false

    /// Focus for the TEXT-mode compose field — claimed on the surface's
    /// `.onAppear` (which re-fires on every popover open AND every
    /// hidden→shown re-mount, since the surface is conditionally rendered).
    @FocusState private var composeFocused: Bool

    /// Hover state for the staged-screenshot thumbnail in the compose surface —
    /// fades in its remove-✕ (text mode's only image-discard affordance).
    @State private var thumbnailHovering = false

    var body: some View {
        VStack(spacing: 0) {
            // The header (a single quiet "Open in Window" icon) is hidden while
            // recording/transcribing — those are pure capture HUDs with no chrome.
            if showsHeader {
                header
            }
            content
            // The footer band only renders when it has a control — so recording,
            // transcribing, and the no-reply start state don't leave an empty
            // strip below a divider.
            if hasFooterControls {
                Divider()
                micFooter
            }
            // TEXT input mode: the compose surface (staged thumbnail + field)
            // is the BOTTOM-MOST band, chat-convention — below the reply's
            // Copy/Speak (or an error's Retry/Dismiss) so those stay attached to
            // the content they act on. Present in the settled/idle states, hidden
            // while a turn is in flight (the chrome-free working HUD, matching voice).
            if showsComposeSurface {
                composeSurface
            }
        }
        // Compact HUD width — the small states hug their content (no forced tall
        // frame); only the reply ScrollView caps + scrolls (see `replyView`).
        .frame(width: 340)
        .background(
            LinearGradient(
                colors: [AppColors.gradientStart, AppColors.gradientEnd],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        // Pin the popover to dark mode — it's the one macOS surface that hosts in
        // a raw NSHostingController without inheriting the app's scheme (every
        // other surface pins it: MainWindowView, MacSettingsView, RootView). The
        // app paints its own hardcoded dark AppColors gradient regardless of
        // system appearance, but system-derived colors (the TextField
        // placeholder, dividers, the destination Menu chrome, caret/selection)
        // follow the effective appearance — so in Light Mode the placeholder
        // resolved to a dark gray and rendered black-on-dark. Pinning dark keeps
        // all of them consistent with the dark theme in both system modes.
        .preferredColorScheme(.dark)
        // Starting a capture must silence any in-progress reply playback: on
        // macOS there is no AVAudioSession to arbitrate playback vs. capture, so
        // a spoken reply (via Speak) would otherwise bleed through the speakers
        // INTO the live mic. Safe no-op when nothing is speaking.
        .onChange(of: service.state) { _, newState in
            if newState == .recording { speaker.stop() }
        }
        // Register this view's speaker with the coordinator so the popover
        // CLOSE teardown (`MenuBarController.popoverDidClose`) can stop it
        // deterministically — the retained hosting controller makes
        // `.onDisappear` an unreliable close signal. Idempotent (same @State
        // instance for the retained view's lifetime); weak on the coordinator.
        .onAppear { coordinator.popoverSpeaker = speaker }
        // Quick-lane speak-on-arrival, popover-OPEN case: the coordinator's
        // `replySpeaker` router stages through the shared `AutoSpeakMailbox`
        // instead of firing the headless shared engine, and THIS view consumes
        // — so the arrival speaks through the popover's own `ThreadSpeaker`
        // (Speak control shows loading→playing, pause/close work). Two hooks
        // because staging and the retained-reply render can land in either
        // order; `attemptAutoSpeak` no-ops until both are true.
        .onChange(of: AutoSpeakMailbox.shared.pending) { _, _ in attemptAutoSpeak() }
        .onChange(of: lastAgentReply?.id) { _, _ in attemptAutoSpeak() }
        // Glance-and-dismiss belt-and-braces: the AUTHORITATIVE close teardown
        // lives in `MenuBarController.popoverDidClose` (the NSPopoverDelegate
        // callback fires on EVERY close path; this `.onDisappear` does not
        // reliably fire from inside the app-lifetime-retained hosting
        // controller). Kept as a second net for any lifecycle path that DOES
        // unmount the view. TWO engines can be mid-utterance: the view-local
        // `speaker` (a bubble Speak tap or a consumed arrival) AND
        // `ReplyVoice.shared` (the popover-closed hands-free arrival voice) —
        // stop BOTH. `.shared.cancel()` is targeted (a bus-wide `claim(nil)`
        // would also kill a main-window ThreadSpeaker) and a no-op when
        // nothing is playing.
        .onDisappear {
            speaker.stop()
            ReplyVoice.shared.cancel()
        }
        // Seed the one-time Screenshot & Ask tip (existing users discovering the
        // feature). Resolved off-actor once; persisted-seen on dismiss.
        .task {
            showsScreenshotAskTip = await SettingsManager.shared.shouldShowScreenshotAskTip()
        }
    }

    // MARK: - Header
    //
    // Hotkey-first, minimal: no "Conduck" wordmark. Two quiet icons — a leading
    // "New chat" (only over the quick lane's own settled reply) and a trailing
    // "Open in Window" (the bridge from a glance to the full thread, which lives
    // in the window, not here). Hidden entirely while recording/transcribing
    // (`showsHeader`).

    /// Header shows only when NOT recording and NOT working (transcribing / gap /
    /// answering) — during capture + the whole turn the popover is a chrome-free
    /// HUD. The Open-in-Window icon returns on the settled reply / empty /
    /// unconfigured / error states.
    private var showsHeader: Bool {
        if service.state == .recording { return false }
        return !isWorking
    }

    private var header: some View {
        HStack(spacing: 8) {
            // "New chat" — the ONE explicit start-over affordance (a popover
            // response otherwise always continues the visible reply). Leading,
            // so create-left / expand-right. Shown only over the QUICK lane's own
            // settled reply (see `showsNewChatButton`).
            if showsNewChatButton {
                Button(action: { coordinator.startNewQuickChat() }) {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 13))
                        .foregroundStyle(AppColors.textSecondary)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .help(String(localized: LocalizedStringResource(
                    "popover.header.newChat",
                    defaultValue: "New chat"
                )))
            }

            Spacer()

            Button(action: onOpenWindow) {
                Image(systemName: "rectangle.on.rectangle")
                    .font(.system(size: 13))
                    .foregroundStyle(AppColors.textSecondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help(String(localized: LocalizedStringResource(
                "conversations.openInWindow",
                defaultValue: "Open in Window"
            )))
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 2)
    }

    /// The header "New chat" button shows only when the QUICK lane's own settled
    /// reply is the content ON SCREEN — NOT on a read-only shared-reply override
    /// (a dot-click peek at another thread; it has no compose box and its own
    /// "Read in window" affordance), NOT on the empty/start state (nothing to
    /// start over from), and NOT while a `sendError` / handoff `.error` is
    /// showing (there the ERROR view is the content, not the reply — and
    /// `startNewQuickChat`'s guard would no-op, so a visible button would be
    /// dead). Mirrors that guard (idle + no send error) so the affordance is
    /// live wherever it renders. `showsHeader` already gates it off during
    /// recording/working (`turnStarting` / `isAwaitingReply` / `.processing`).
    private var showsNewChatButton: Bool {
        service.state == .idle
            && coordinator.popoverOverrideViewModel == nil
            && coordinator.quickViewModel?.sendError == nil
            && coordinator.quickViewModel?.lastPopoverReply != nil
    }

    // MARK: - Content (status / reply / empty states)
    //
    // PRIORITY: recording, then the unified WORKING view (transcribing → gap →
    // answering — see `isWorking`), then a failed agent turn (`sendError`), then
    // the retained reply / empty states. The working phase wins over a retained
    // reply so the popover never flashes the previous answer between turns; the
    // send error wins over the retained reply so a failed turn never silently
    // collapses back to the PREVIOUS answer (which would read as the answer to
    // the question that just failed).

    @ViewBuilder
    private var content: some View {
        if service.state == .recording {
            recordingStatusView
        } else if isWorking {
            workingView
        } else if !coordinator.isRemoteAgentConfigured {
            unconfiguredEmptyState
        } else if service.state == .idle, let sendError = activeSendError {
            // Gated on `.idle` so a LATER STT `.error` (whose message renders in
            // the footer) isn't double-billed with a stale agent error up here.
            sendErrorView(message: sendError)
        } else if let reply = lastAgentReply {
            replyView(reply: reply)
        } else if coordinator.menuBarInputMode == .text {
            // TEXT mode start state: the compose surface (rendered below the
            // content slot) IS the affordance — no "press ⌘⇧1" hint, no tip
            // (its copy teaches the voice flow), no extra chrome.
            Color.clear.frame(height: 2)
        } else {
            startEmptyState
        }
    }

    /// True for the whole "turn in progress" phase so transcribing and answering
    /// render the SAME `workingView` at the SAME size: STT running
    /// (`.processing`), the brief hand-off gap before the send Task claims the
    /// flag (`coordinator.turnStarting`), and the agent wait (`isAwaitingReply`).
    private var isWorking: Bool {
        if service.state == .processing { return true }
        if coordinator.turnStarting { return true }
        return coordinator.quickViewModel?.isAwaitingReply == true
    }

    // MARK: - Recording view (clean — no stale reply, no mascot)

    /// ONE recording HUD for both capture modes — plain ⌘⇧1 voice and ⌘⇧2
    /// Screenshot & Ask render the SAME restrained layout: the shared dot+timer
    /// indicator and a compact Cancel (X). The ONLY divergence is the
    /// staged-screenshot thumbnail on top (⌘⇧2), showing what rides the turn. No
    /// send button and no hint text in either mode — sending is hotkey-first (a
    /// second ⌘⇧1/⌘⇧2 press or the menu-bar icon click stops-and-sends), so the
    /// two modes look and feel identical.
    private var recordingStatusView: some View {
        VStack(spacing: 16) {
            // Staged region screenshot (⌘⇧2) — renders nothing for plain voice.
            captureThumbnail

            RecordingStatusIndicator(
                elapsed: service.recordingTime,
                nearMaxDuration: service.nearMaxDuration
            )

            // Compact cancel, grouped right under the indicator (NOT a heavy
            // bottom-footer button). Cancel routes through the coordinator
            // chokepoint (discards audio AND any staged screenshot, no STT,
            // releases the armed destination), then dismisses — identical to Esc.
            cancelButton(action: {
                coordinator.cancelActiveCapture()
                dismiss()
            })
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
    }

    /// Thumbnail of the staged region screenshot (≤240×120, rounded + stroked).
    /// Reads the pending PNG bytes from the coordinator; an `NSImage(data:)`
    /// failure renders nothing rather than crashing.
    @ViewBuilder
    private var captureThumbnail: some View {
        if let data = coordinator.pendingCaptureImage, let nsImage = NSImage(data: data) {
            Image(nsImage: nsImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: 240, maxHeight: 120)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(AppColors.border, lineWidth: 1)
                )
                .accessibilityLabel(Text(String(localized: LocalizedStringResource(
                    "popover.capture.thumbnailLabel",
                    defaultValue: "Captured screen region"
                ))))
        }
    }

    // MARK: - Compose surface (TEXT input mode)
    //
    // The text-mode analog of the recording HUD: staged ⌘⇧2 thumbnail (with a
    // hover-✕ — text mode's ONLY image-discard affordance) + a multi-line
    // field. Return sends (`.onSubmit` — proven on
    // macOS vertical TextFields by `MessageComposerBar`); Shift+Return inserts
    // a newline at the cursor via the popover key monitor
    // (`MenuBarController.installEscMonitor`); the draft is COORDINATOR-owned
    // so it survives any dismissal. No send button, no mic — hard mode.

    /// Visible in the settled/idle states of TEXT mode only. Hidden while a
    /// turn is in flight (`isWorking` — the chrome-free working HUD), while a
    /// shared-service capture runs (window-composer mic edge), during an
    /// unresolved agent `sendError` (its footer owns the surface: Retry /
    /// Dismiss first), and when no gateway is configured. SHOWN over a
    /// handoff `.error` — typing anew is the natural recovery
    /// (`sendQuickTypedDraft` discards the stash + clears the error, the
    /// fresh-press parallel).
    private var showsComposeSurface: Bool {
        // Read-only shared-reply glance: when the popover is showing a display
        // override (a dot-click onto a share/background reply), there is no
        // compose box — the compose surface targets the QUICK lane, which is a
        // different thread, so typing here would send to the wrong conversation.
        // Continue the shown thread via "Read full reply in window".
        guard coordinator.popoverOverrideViewModel == nil else { return false }
        guard coordinator.menuBarInputMode == .text,
              coordinator.isRemoteAgentConfigured,
              !isWorking else { return false }
        switch service.state {
        case .recording, .processing: return false
        case .error: return true
        case .idle: return activeSendError == nil
        }
    }

    private var composeSurface: some View {
        // Local @Bindable bridge — the view holds the coordinator as a plain
        // `let`, and the field needs a Binding into its observable `quickDraft`.
        @Bindable var coordinator = coordinator
        return VStack(spacing: 10) {
            composeThumbnail

            TextField(
                // Same key + defaultValue as the window composer — one
                // catalog entry, one voice.
                String(localized: LocalizedStringResource(
                    "composer.placeholder",
                    defaultValue: "Message your personal AI"
                )),
                text: $coordinator.quickDraft,
                axis: .vertical
            )
            .textFieldStyle(.plain)
            .font(.callout)
            .foregroundStyle(AppColors.textPrimary)
            .lineLimit(1...6)
            .focused($composeFocused)
            .onSubmit { coordinator.sendQuickTypedDraft() }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(AppColors.cardBackgroundElevated)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(AppColors.border, lineWidth: 1)
                    )
            )
        }
        .padding(.horizontal, 14)
        .padding(.top, 6)
        .padding(.bottom, 12)
        // Conditional rendering means this fires on every popover open AND
        // every hidden→shown re-mount (turn settled) — exactly the moments
        // the field should reclaim focus.
        .onAppear { focusComposeField() }
    }

    /// Claim keyboard focus for the compose field — now, and again a tick
    /// later: setting `@FocusState` synchronously on appear inside an
    /// NSPopover races key-window establishment (`showPopover` activates +
    /// makes the popover window key asynchronously of this render).
    private func focusComposeField() {
        composeFocused = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 80_000_000)
            composeFocused = true
        }
    }

    /// Staged ⌘⇧2 screenshot above the field, with a hover-revealed remove-✕.
    /// Text mode keeps the image across an IMPLICIT click-away dismissal; Esc and
    /// the explicit Cancel/Dismiss controls discard it (together with the draft).
    /// This hover-✕ drops ONLY the image while keeping the popover open + draft.
    @ViewBuilder
    private var composeThumbnail: some View {
        if coordinator.pendingCaptureImage != nil {
            ZStack(alignment: .topTrailing) {
                captureThumbnail
                Button(action: { coordinator.clearPendingCaptureImage() }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(AppColors.textPrimary, AppColors.cardBackgroundElevated)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .opacity(thumbnailHovering ? 1 : 0)
                .padding(2)
                .accessibilityLabel(Text(String(localized: LocalizedStringResource(
                    "popover.compose.removeImage",
                    defaultValue: "Remove screenshot"
                ))))
            }
            .onHover { thumbnailHovering = $0 }
        }
    }

    // MARK: - Working view (transcribing → gap → answering)

    /// ONE view for the entire turn — STT, the hand-off gap, and the agent wait
    /// (see `isWorking`). The layout is IDENTICAL in every phase (a centered
    /// spinner + status label, with the Cancel-X's space ALWAYS reserved below),
    /// so the popover does not resize when "Transcribing…" becomes "{gateway} is
    /// answering…" — only the label crossfades. The X is interactive only once
    /// there's an in-flight reply to cancel (hidden-but-space-reserved during STT,
    /// since STT isn't cleanly cancellable); tapping it aborts the reply AND
    /// closes (mirrors Esc).
    private var workingView: some View {
        VStack(spacing: 16) {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(workingLabel)
                    .font(.callout)
                    .foregroundStyle(AppColors.textSecondary)
                    .lineLimit(1)
                    .contentTransition(.opacity)
            }

            cancelButton(action: {
                // ✕ == Esc: route through the universal teardown (cancels the
                // in-flight reply + resets state). Nothing else is staged during
                // the wait, so this is the in-flight cancel plus an idempotent
                // latch reset (matches `handleQuickSend`'s defer).
                coordinator.cancelActiveCapture()
                dismiss()
            })
            .opacity(service.state == .processing ? 0 : 1)
            .allowsHitTesting(service.state != .processing)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
        // Crossfade the label (Transcribing… → answering…) and fade the X in,
        // with NO size change. Instant under Reduce Motion.
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: workingLabel)
    }

    /// "Transcribing…" while STT runs, else "{gateway} is answering…". During the
    /// hand-off gap the VM may be momentarily nil (a fresh conversation being
    /// minted) — fall back to a plain "Answering…" so the label never blanks.
    private var workingLabel: String {
        if service.state == .processing {
            return String(localized: LocalizedStringResource(
                "popover.transcribing", defaultValue: "Transcribing…"))
        }
        if let name = coordinator.quickViewModel?.backendDisplayName {
            return String(localized: "\(name) is answering…")  // xcstrings: chat-ui
        }
        return String(localized: LocalizedStringResource(
            "popover.answering", defaultValue: "Answering…"))
    }

    // MARK: - Reply view (settled answer — the hero)

    /// The popover's scroll cap for a settled reply (a taller answer scrolls).
    private static let replyHeightCap: CGFloat = 260

    /// Long / code-heavy replies: the popover is a GLANCE surface (340pt wide),
    /// so a many-paragraph or fenced-code answer reads better full-size (the
    /// quiet header "Open in Window" icon is always available). We keep the
    /// capped scroll and fade its bottom edge as the "there's more" cue — until
    /// scrolled to the bottom, where the fade lifts so the last lines stay crisp.
    private func isLongReply(_ reply: MessageRecord) -> Bool {
        ReplyLengthClassifier.isLong(
            text: reply.text,
            measuredHeight: replyHeight,
            cap: Self.replyHeightCap
        )
    }

    /// The settled agent reply. The ScrollView self-sizes to the reply's natural
    /// height (a short answer hugs) and caps (a long one scrolls). Shown idle
    /// after a finished turn (and during `.error`, with the error in the footer).
    /// A long/code-heavy reply additionally fades its bottom edge as a "more
    /// below" cue while there's content past the fold (see `replyAtBottom`).
    private func replyView(reply: MessageRecord) -> some View {
        let long = isLongReply(reply)
        return ScrollView {
            StructuredText(markdown: reply.text)
                // Reply text is untrusted: markup attachment URLs are refused (so a
                // `![](https://…)` in an answer can never originate a fetch) and a
                // link tap only reaches the system for a web/mail scheme — any other
                // scheme shows its real destination and asks first, because the link
                // text is the agent's to choose. See MarkdownAttachmentPolicy.swift.
                .appliesUntrustedMarkdownPolicy()
                .foregroundStyle(AppColors.textPrimary)
                .textual.textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                // Threshold the write: feeding every sub-point height back into the
                // ScrollView's own `.frame(height:)` is a measure→constrain→remeasure
                // loop that churns Textual's layout/selection layer (the same
                // `AnyTextLayoutCollection` thrash as the main thread). Only commit a
                // change ≥1pt so a settled reply stops re-measuring.
                .onGeometryChange(for: CGFloat.self) { $0.size.height }
                    action: { if abs($0 - replyHeight) >= 1 { replyHeight = $0 } }
        }
        // Track whether we're at (or fit within) the bottom — gates the fade OFF
        // there. The modifier fires `action` ONLY when the transformed Bool flips,
        // and re-evaluates when the geometry changes (a new reply changes
        // contentSize), so `replyAtBottom` stays correct without a manual reset.
        .onScrollGeometryChange(for: Bool.self) { geo in
            let threshold: CGFloat = 2
            // Content that fits the cap isn't scrollable → treat as "at bottom".
            if geo.contentSize.height <= geo.containerSize.height + threshold { return true }
            return geo.visibleRect.maxY >= geo.contentSize.height - threshold
        } action: { _, atBottom in
            replyAtBottom = atBottom
        }
        // A new reply must re-measure from scratch (height drives `isLongReply`).
        .onChange(of: reply.id) { _, _ in replyHeight = 0 }
        .frame(height: min(max(replyHeight, 1), Self.replyHeightCap))
        .frame(maxWidth: .infinity, alignment: .topLeading)
        // Background-agnostic bottom fade (masks the content itself, so it works
        // over the popover material). Full-opaque when the reply isn't long OR
        // when scrolled to the bottom (the last lines read crisp — the fade is a
        // "more below" cue, not permanent chrome).
        .mask(alignment: .top) {
            if long && !replyAtBottom {
                LinearGradient(
                    stops: [
                        .init(color: .black, location: 0),
                        .init(color: .black, location: 0.82),
                        .init(color: .black.opacity(0), location: 1.0),
                    ],
                    startPoint: .top, endPoint: .bottom
                )
            } else {
                Color.black
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    // MARK: - Send-error view (the agent turn failed)

    /// The agent turn failed (gateway unreachable / auth / timeout) — the VM's
    /// transient `sendError`, the same message the main window banners. Rendered
    /// in the content slot INSTEAD of the retained previous reply, which would
    /// otherwise read as the answer to the question that just failed. The footer
    /// pairs it with Retry (when a failed bubble exists to re-fire) + Dismiss
    /// (`sendErrorActions`).
    private func sendErrorView(message: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 24))
                .foregroundStyle(AppColors.error)
            Text(message)
                .font(.callout)
                .foregroundStyle(AppColors.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
    }

    /// Compact sibling of `UnconfiguredEmptyState` — same strings (`UnconfiguredCopy`),
    /// own shape. The popover has no room for the mascot, and it is the only surface
    /// driven by a global shortcut, so it alone appends the shortcut hint.
    private var unconfiguredEmptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "gearshape.2")
                .font(.system(size: 40))
                .foregroundStyle(AppColors.brandAmber.opacity(0.7))
            Text(UnconfiguredCopy.headline)
                .font(.headline)  // compact surface — no .title2 promotion here
                .foregroundStyle(AppColors.textPrimary)
                .accessibilityAddTraits(.isHeader)
            Text(UnconfiguredCopy.body)
                .font(.callout)
                .foregroundStyle(AppColors.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 24)
            if let shortcut = KeyboardShortcuts.getShortcut(for: .toggleVoiceCapture) {
                Text(UnconfiguredCopy.menuBarShortcutHint(shortcut.description))
                    .font(.callout)
                    .foregroundStyle(AppColors.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 24)
            }
            Button {
                // Mirror MenuBarController.openSettings(): the main window may be
                // closed (the app persists after its window closes), so open it +
                // raise the deferred-present flag (consumed by
                // MainWindowView.onAppear) AND post the live bus (consumed by its
                // .onReceive when already open). Deep-link to Personal AI.
                NSApp.activate(ignoringOtherApps: true)
                coordinator.pendingSettingsCategory = .personalAI
                coordinator.pendingDiagnosticsFocus = nil   // Personal-AI deep-link: not a diagnostics focus
                coordinator.pendingShowSettings = true
                NotificationCenter.default.post(name: .openConversationsWindow, object: nil)
                NotificationCenter.default.post(name: .openSettingsWindow, object: nil)
            } label: {
                Text(UnconfiguredCopy.button)
                    .fontWeight(.semibold)
            }
            .buttonStyle(.borderedProminent)
            .tint(AppColors.brandAmber)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
    }

    /// Configured, no reply yet — a single hotkey-first "talk" hint (no mascot,
    /// no mic). For existing users a one-time ⌘⇧2 "Screenshot & Ask" tip sits
    /// below until dismissed. This state only renders when a gateway IS
    /// configured (the unconfigured arm wins earlier in `content`).
    private var startEmptyState: some View {
        VStack(spacing: 14) {
            if let shortcut = KeyboardShortcuts.getShortcut(for: .toggleVoiceCapture) {
                Text(String(localized: LocalizedStringResource(
                    "popover.start.withShortcut",
                    defaultValue: "Press \(shortcut.description) to talk"
                )))
                .font(.callout)
                .foregroundStyle(AppColors.textSecondary)
                .multilineTextAlignment(.center)
            } else {
                Text(String(localized: LocalizedStringResource(
                    "popover.start.noShortcut",
                    defaultValue: "Set a shortcut in Settings to start talking"
                )))
                .font(.callout)
                .foregroundStyle(AppColors.textSecondary)
                .multilineTextAlignment(.center)
            }

            if showsScreenshotAskTip {
                screenshotAskTip
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: showsScreenshotAskTip)
    }

    /// One-time dismissible inline tip teaching the new ⌘⇧2 Screenshot & Ask mode.
    /// Restrained: a small camera glyph + one line + an X. Dismiss persists the
    /// seen flag so it never returns.
    private var screenshotAskTip: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "rectangle.dashed.badge.record")
                .font(.system(size: 13))
                .foregroundStyle(AppColors.brandAmber)
            Text(String(localized: LocalizedStringResource(
                "popover.tip.screenshotAsk",
                defaultValue: "New: press ⌘⇧2 to grab a screen region, then talk — the screenshot and your words are sent together."
            )))
            .font(.caption)
            .foregroundStyle(AppColors.textTertiary)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            Button(action: {
                showsScreenshotAskTip = false
                Task { await SettingsManager.shared.markScreenshotAskTipSeen() }
            }) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(AppColors.textTertiary)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(String(localized: LocalizedStringResource(
                "popover.tip.dismiss",
                defaultValue: "Dismiss tip"
            ))))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(AppColors.cardBackgroundElevated, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .padding(.horizontal, 16)
    }

    // MARK: - Footer control row
    //
    // The footer band renders ONLY for the settled reply (Copy + Speak), for a
    // capture/STT error (Retry / Dismiss), and for a failed agent turn
    // (`sendError` → Retry / Dismiss). Recording's and the working phase's
    // cancel is inline in their own views, so the footer is hidden there (see
    // `hasFooterControls`) — no empty strip, no chrome pop-in mid-turn.

    private var micFooter: some View {
        VStack(spacing: 6) {
            switch service.state {
            case .error(let message, let isRetryable):
                // Screenshot & Ask recovery: when a staged screenshot is still
                // pending, offer Retry-Voice / Type-Instead / Discard instead of
                // the generic Retry/Dismiss — the screenshot is retained until the
                // user explicitly resolves it (the `.error` path never clears it).
                // VOICE mode only: in text mode the compose surface owns the
                // staged image (thumbnail + hover-✕) and typing is the natural
                // recovery — Retry-Voice would start a recording from a surface
                // whose contract is no mic affordances (hard mode).
                if coordinator.pendingCaptureImage != nil,
                   coordinator.menuBarInputMode == .voice {
                    captureRecoveryFooter(message: message)
                } else {
                    errorFooter(message: message, isRetryable: isRetryable)
                }
            case .idle:
                // A failed AGENT turn takes the footer over Copy/Speak — Retry
                // re-fires the failed bubble; Dismiss returns to the reply/hint.
                if activeSendError != nil, let vm = coordinator.displayedPopoverViewModel {
                    sendErrorActions(vm: vm)
                        .transition(.opacity)
                } else if let reply = lastAgentReply, let vm = coordinator.displayedPopoverViewModel {
                    // Copy + Speak on the retained reply (idle after a finished turn).
                    replyActions(reply: reply, vm: vm)
                        .transition(.opacity)
                }
            case .recording, .processing:
                // Footer is hidden in these states (`hasFooterControls`).
                EmptyView()
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .animation(
            reduceMotion ? nil : .spring(response: 0.34, dampingFraction: 0.82),
            value: footerPhase
        )
    }

    /// The agent reply the popover shows (drives the Copy + Speak control row +
    /// the reply view). Provenance-scoped, NOT "the last agent message in the
    /// bound conversation":
    /// - A dot-click OVERRIDE (a peek at another thread's unread reply) is an
    ///   explicit inspection → show THAT thread's latest agent message.
    /// - The quick lane shows ONLY the retained reply to the most recent
    ///   menu-bar/hotkey capture (`lastPopoverReply`). A window-typed reply,
    ///   or one synced from iPhone/Watch, that merely landed in this shared VM's
    ///   conversation is NOT surfaced — the menu bar must not claim authorship
    ///   of a turn its lane never initiated. Nil → the empty/start state shows.
    private var lastAgentReply: MessageRecord? {
        if let override = coordinator.popoverOverrideViewModel {
            return override.messages.last(where: { $0.role == "agent" })
        }
        // The quick lane's retained reply is a self-contained snapshot (set by
        // the send task), so it renders immediately with no `messages` lookup
        // and no dependency on the reload landing first.
        return coordinator.quickViewModel?.lastPopoverReply
    }

    /// The displayed VM's transient agent-turn failure (gateway unreachable /
    /// auth / timeout) — the same message the main window banners. Drives the
    /// send-error content arm + the Retry/Dismiss footer.
    private var activeSendError: String? {
        coordinator.displayedPopoverViewModel?.sendError
    }

    /// The most recent FAILED user turn — the bubble `vm.retry` re-fires (same
    /// path as the window's Retry chip). Nil when the send failed before a
    /// bubble was written (e.g. not-configured early return) — no Retry then.
    private var lastFailedUserTurn: MessageRecord? {
        coordinator.displayedPopoverViewModel?.messages.last(where: { $0.role == "user" && $0.status == "failed" })
    }

    /// Gates the bottom divider + footer band. Hidden during recording AND the
    /// whole working phase (their Cancel X is inline) so the popover doesn't pop a
    /// footer in mid-turn. Shows on error (Retry/Dismiss), on a failed agent turn
    /// (`sendError` → Retry/Dismiss), and on a settled reply (Copy + Speak).
    private var hasFooterControls: Bool {
        if service.state == .recording || isWorking { return false }
        switch service.state {
        case .error: return true
        case .idle: return lastAgentReply != nil || activeSendError != nil
        case .recording, .processing: return false  // covered above
        }
    }

    /// Discrete phase tag for the footer crossfade: error / reply-actions /
    /// empty / send-error.
    private var footerPhase: Int {
        switch service.state {
        case .error: return 0
        case .idle:
            if activeSendError != nil { return 3 }
            return lastAgentReply != nil ? 1 : 2
        case .recording, .processing: return 2
        }
    }

    /// Compact cancel control, shared by the recording view and the in-flight
    /// wait. `xmark.circle.fill` at 24pt — a lot lighter than a 40pt footer
    /// button; Esc does the same thing in both states.
    private func cancelButton(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 24))
                .foregroundStyle(AppColors.textSecondary)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(String(localized: LocalizedStringResource(
            "popover.cancel",
            defaultValue: "Cancel"
        ))))
    }

    // MARK: - Reply actions (Copy + Speak)
    //
    // Mirrors `ConversationThreadView.MessageBubble`'s footer locally (the
    // popover convention is to DUPLICATE small presentation, not extract). Same
    // `ThreadSpeaker` engine + the same `bubble.*` strings, so play/pause/resume
    // and the Copy checkmark flip behave exactly like the chat bubble. No iOS
    // foreground gate (this file is macOS-only).

    private func replyActions(reply: MessageRecord, vm: ConversationDetailViewModel) -> some View {
        HStack(spacing: 6) {
            // Copy + Speak trail right; the quiet header "Open in Window" icon is
            // the single escape to the full window (a long reply scrolls in place,
            // its bottom edge faded as the "more below" cue — no inline CTA).
            Spacer(minLength: 4)

            MessageActionButton(
                accessibilityLabel: Text(speakAccessibilityLabel(for: reply.id)),
                action: {
                    // Cross-engine arbitration (silencing the shared arrival
                    // voice) happens inside `ThreadSpeaker.speak` via the
                    // `SpeechExclusivity` bus.
                    speaker.speak(reply.text, messageID: reply.id)
                }
            ) {
                speakGlyph(for: reply.id)
            }

            MessageActionButton(
                systemImage: didCopy ? "checkmark" : "doc.on.doc",
                size: 14,
                tint: AppColors.textTertiary,
                accessibilityLabel: Text(didCopy
                    ? LocalizedStringResource("bubble.copy.copied", defaultValue: "Copied")
                    : LocalizedStringResource("bubble.copy.copy", defaultValue: "Copy")),
                action: { copyTapped(reply: reply, vm: vm) }
            )
        }
    }

    /// Consume a staged quick-lane arrival and speak it through the popover's
    /// OWN `ThreadSpeaker` — the popover-OPEN half of speak-on-arrival (the
    /// coordinator's `replySpeaker` router stages instead of firing the
    /// headless shared engine when this popover is visible on the reply's
    /// thread). Twin of `ConversationThreadView.attemptAutoSpeak` (iOS): same
    /// mailbox one-shot + freshness semantics, same `AutoSpeakSelection`
    /// resolver, and the speak routes through the same state machine as a
    /// manual tap — so the Speak control shows loading→playing and
    /// pause/close behave identically. Skipped while the mic is live or a
    /// capture is processing (parity with `claimForAutoSpeak`'s refusal); the
    /// staged one-shot survives until idle or the freshness window expires.
    /// `resolve` returning nil (reply not rendered yet) skips the DESTRUCTIVE
    /// consume so the one-shot survives to the `lastAgentReply` onChange.
    private func attemptAutoSpeak() {
        guard case .idle = service.state else { return }
        guard let convID = coordinator.displayedPopoverConversationID else { return }
        let latest = lastAgentReply.map { (id: $0.id, text: $0.text) }
        guard let target = AutoSpeakSelection.resolve(
            staged: AutoSpeakMailbox.shared.pending,
            arrayLatest: latest
        ) else { return }
        guard AutoSpeakMailbox.shared.consume(matching: convID) else { return }
        speaker.speak(target.text, messageID: target.id)
    }

    /// State-driven Speak glyph — uniform bare fills, sized to optically match the
    /// popover's smaller Copy glyph (`doc.on.doc` at 14pt). These run a touch
    /// smaller than the chat bubble's (17/16) because the popover footer is a
    /// compact HUD strip. Every state renders the gray idle tint
    /// (`textTertiary`) — the button reads uniform like the neighboring Copy
    /// glyph, and only the glyph SHAPE signals state: idle `speaker.wave.2.fill`
    /// 15pt (the wide-but-short symbol needs +1pt to area-match the dense 14pt
    /// Copy) → loading spinner (its motion confirms the tap; no color flip) →
    /// playing `pause.fill` 14pt → paused `play.fill` (glyph shape says
    /// "resumable").
    @ViewBuilder
    private func speakGlyph(for id: UUID) -> some View {
        switch speaker.speakState(for: id) {
        case .idle:
            Image(systemName: "speaker.wave.2.fill")
                .font(.system(size: 15))
                .foregroundStyle(AppColors.textTertiary)
        case .loading:
            ProgressView()
                .controlSize(.small)
                .tint(AppColors.textTertiary)
        case .playing:
            Image(systemName: "pause.fill")
                .font(.system(size: 14))
                .foregroundStyle(AppColors.textTertiary)
        case .paused:
            Image(systemName: "play.fill")
                .font(.system(size: 14))
                .foregroundStyle(AppColors.textTertiary)
        }
    }

    /// VoiceOver label for the Speak control, switching with the speak phase
    /// (same `bubble.speak.*` keys as the chat bubble).
    private func speakAccessibilityLabel(for id: UUID) -> LocalizedStringResource {
        switch speaker.speakState(for: id) {
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

    /// Copy the reply to the clipboard + flip to a checkmark for 1.5s (exact
    /// `MessageBubble.copyTapped()` logic).
    private func copyTapped(reply: MessageRecord, vm: ConversationDetailViewModel) {
        vm.copy(reply)
        withAnimation(.easeOut(duration: 0.15)) { didCopy = true }
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            withAnimation(.easeOut(duration: 0.2)) { didCopy = false }
        }
    }

    /// Screenshot & Ask recovery footer — shown on `.error` while a screenshot is
    /// still staged. The voice half failed but the screenshot is intact, so offer
    /// three ways forward (the image survives Retry/Type-Instead; only Discard
    /// drops it). Mirrors the recovery-actions contract in the integration spec.
    private func captureRecoveryFooter(message: String) -> some View {
        VStack(spacing: 8) {
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(AppColors.error)
                .multilineTextAlignment(.center)
                .lineLimit(3)
            HStack(spacing: 10) {
                // Retry Voice — re-record; the staged screenshot stays and rides
                // the next successful transcript.
                Button(action: { service.toggleRecording() }) {
                    Text(String(localized: LocalizedStringResource(
                        "popover.capture.retryVoice",
                        defaultValue: "Retry Voice"
                    )))
                    .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.borderedProminent)
                .tint(AppColors.brandAmber)
                .controlSize(.small)

                // Type Instead — bail into the typed composer with the screenshot
                // staged for review (coordinator parks it + opens the window).
                Button(action: {
                    coordinator.typeInsteadFromCapture()
                    dismiss()
                }) {
                    Text(String(localized: LocalizedStringResource(
                        "popover.capture.typeInstead",
                        defaultValue: "Type Instead"
                    )))
                    .font(.system(size: 12))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                // Discard — drop the screenshot + reset the capture (single
                // chokepoint), then close.
                Button(action: {
                    coordinator.cancelActiveCapture()
                    dismiss()
                }) {
                    Text(String(localized: LocalizedStringResource(
                        "popover.capture.discard",
                        defaultValue: "Discard"
                    )))
                    .font(.system(size: 12))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    /// True only when the failed capture's audio was actually preserved in
    /// `PendingRetryStore` (`shouldPreserveForRetry`) — the precondition for
    /// `retryLast` to succeed. Errors that are nominally retryable but save no
    /// bytes ("empty text", rate-limit, generic API failure) would dead-end in
    /// "No saved recording to retry", so they get Dismiss only.
    private var hasSavedRetryAudio: Bool {
        service.lastError?.shouldPreserveForRetry == true
    }

    private func errorFooter(message: String, isRetryable: Bool) -> some View {
        VStack(spacing: 8) {
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(AppColors.error)
                .multilineTextAlignment(.center)
                .lineLimit(3)
            HStack(spacing: 12) {
                if coordinator.hasPendingFailedTurn {
                    // Mint-failure recovery: the transcript survived on the
                    // coordinator; Retry replays the hand-off (no audio involved).
                    Button(action: { coordinator.retryPendingFailedTurn() }) {
                        Text(String(localized: LocalizedStringResource(
                            "popover.retry",
                            defaultValue: "Retry"
                        )))
                        .font(.system(size: 12, weight: .medium))
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(AppColors.brandAmber)
                    .controlSize(.small)
                } else if isRetryable && hasSavedRetryAudio {
                    // Audio-level retry — offered only when bytes were actually
                    // saved (`hasSavedRetryAudio`), so Retry never dead-ends.
                    Button(action: { service.retryLast() }) {
                        Text(String(localized: LocalizedStringResource(
                            "popover.retry",
                            defaultValue: "Retry"
                        )))
                        .font(.system(size: 12, weight: .medium))
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(AppColors.brandAmber)
                    .controlSize(.small)
                }
                Button(action: {
                    // Dismiss abandons the turn — route through the universal
                    // teardown (`cancelActiveCapture` now folds the stash discard
                    // + draft/screenshot clear + latch release): a clean slate, so
                    // nothing — stale stash, staged image, typed draft, or frozen
                    // destination snapshot — rides a later, unrelated error's Retry.
                    coordinator.cancelActiveCapture()
                }) {
                    Text(String(localized: LocalizedStringResource(
                        "popover.dismiss",
                        defaultValue: "Dismiss"
                    )))
                    .font(.system(size: 12))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    /// Retry / Dismiss for a failed AGENT turn (`sendError` — gateway
    /// unreachable / auth / timeout). Retry re-fires the failed user bubble via
    /// `vm.retry` (the window Retry chip's path; the VM's atomic in-flight claim
    /// keeps the turn exactly-once); it's offered only when a failed bubble
    /// exists — the not-configured early returns set `sendError` WITHOUT writing
    /// a bubble, so there's nothing to re-fire. Dismiss clears the error and the
    /// retained reply / start hint returns.
    ///
    /// Retry is ALSO gated on the verdict being retryable, the same question the
    /// window's failed-turn row answers through `DeclinedTurnPresentation`. The
    /// popover is that row's macOS twin and must not offer what the window
    /// withholds: a certificate this device refuses, a rejected bearer token or a
    /// URL that isn't an AI endpoint sends the identical request into the
    /// identical refusal, and the spinner covers the remedy the banner just
    /// printed.
    private func sendErrorActions(vm: ConversationDetailViewModel) -> some View {
        HStack(spacing: 12) {
            if let failed = lastFailedUserTurn, sendErrorIsRetryable(vm) {
                Button(action: { Task { await vm.retry(failed) } }) {
                    Text(String(localized: LocalizedStringResource(
                        "popover.retry",
                        defaultValue: "Retry"
                    )))
                    .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.borderedProminent)
                .tint(AppColors.brandAmber)
                .controlSize(.small)
            }
            // Troubleshoot — shown only for a failure Diagnostics can help with
            // (the `DiagnosticsFocus` filter). The popover is outside the SwiftUI
            // scene graph and can't present a sheet, so it routes through the
            // coordinator into the main window's Settings → Diagnostics, focused on
            // this failure (mirrors the unconfigured→Personal AI hand-off above).
            if let focus = DiagnosticsFocus(errorCode: vm.sendErrorCode, ref: vm.boundRef) {
                Button {
                    NSApp.activate(ignoringOtherApps: true)
                    coordinator.pendingSettingsCategory = .diagnostics
                    coordinator.pendingDiagnosticsFocus = focus
                    coordinator.pendingShowSettings = true
                    NotificationCenter.default.post(name: .openConversationsWindow, object: nil)
                    NotificationCenter.default.post(name: .openSettingsWindow, object: nil)
                } label: {
                    Label(
                        LocalizedStringResource("thread.troubleshoot", defaultValue: "Troubleshoot"),
                        systemImage: "stethoscope"
                    )
                    .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.bordered)
                .tint(AppColors.brandAmber)
                .controlSize(.small)
            }
            Button(action: { vm.clearSendError() }) {
                Text(String(localized: LocalizedStringResource(
                    "popover.dismiss",
                    defaultValue: "Dismiss"
                )))
                .font(.system(size: 12))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    /// Whether the failed agent turn can be re-sent, from `AppError.isRetryable`.
    ///
    /// Reconstructed from the banner's `sendErrorCode` — the same round-trip the
    /// Troubleshoot affordance beside it already makes — because that code is the
    /// only piece of the verdict the view is given. `nil` means a plain notice
    /// with no taxonomy behind it (a dropped attachment), which has never been a
    /// terminal transport refusal, so it keeps the button.
    private func sendErrorIsRetryable(_ vm: ConversationDetailViewModel) -> Bool {
        guard let code = vm.sendErrorCode else { return true }
        return AppError.from(errorCode: code, message: nil).isRetryable
    }
}
#endif
