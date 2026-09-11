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
// recording/thinking, and SPEAK + a message menu on a settled reply. The menu
// offers Copy message and Save message to Work; saving leaves the reply in place
// and reports the same capture receipt as the full chat thread. CANCEL (the X) and
// Esc both ABORT-AND-CLOSE — they discard the active recording / in-flight
// reply AND any staged ⌘⇧2 screenshot + typed draft, then dismiss the popover
// in one press (never land on the start screen). Only an IMPLICIT click-away
// preserves a staged composition.
//
// The `content` router resolves state in this PRIORITY:
//   0. `workCaptureIsActive` → `workCaptureView` — the ⌃⌘W Work HUD, which is
//                              arm 1's layout bound to the Work lane
//                              (`captureHUD`: thumbnail + indicator + one X),
//                              or the failure with the Try Again that finishes
//                              the capture. It outranks even a live chat
//                              recording, because the two lanes cannot both
//                              hold the microphone and this popover is the ONLY
//                              surface a ⌃⌘W capture has.
//   1. service `.recording`  → `recordingStatusView` (`captureHUD`: the staged
//                              screenshot if any, timer, one compact Cancel X)
//   2. `isWorking`           → `workingView` — ONE view for the WHOLE turn,
//                              with `workingPhase` choosing the copy: STT
//                              (`.processing` → "Transcribing…"), the local
//                              pre-dispatch window (`turnStarting` → "Sending…"),
//                              and the agent wait (the VM's resolved
//                              `liveTurnPhase` → "{gateway} is answering…").
//                              Identical layout + size across all three (spinner
//                              + label, Cancel-X space always reserved) so the
//                              phases NEVER resize the popover. The X is live
//                              only in the answering phase — it is the only one
//                              with a task to cancel.
//   3. !isQuickCaptureReady    → `unconfiguredEmptyState` (gear → Settings), in
//                              one of TWO wordings: the beginner "bring your own
//                              AI" pitch when nothing is configured, and the
//                              default-needs-setup wording when other gateways
//                              DO work and only the quick lane's destination
//                              does not (`GatewayGate` carries why that state is
//                              legitimate). The pitch on a device with five
//                              working gateways is simply false. Ranked BELOW
//                              the error and reply arms — it says "no NEW capture
//                              can start", never "there is nothing to show".
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
// They return on the settled reply (Open-in-Window header + Speak/menu footer),
// on error (Retry/Dismiss footer), and on the empty state. The reply actions mirror
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
    /// Drives the message menu's 1.5s copy checkmark (mirrors `MessageBubble`).
    @State private var didCopy = false
    @State private var copyFeedbackID: UUID?
    /// The async save belongs to the displayed reply, never the next quick turn
    /// or an unread-thread override selected while its material is being saved.
    @State private var replyWorkCaptureID: UUID?
    @State private var replyWorkCaptureNotice: MessageWorkCaptureNotice?

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
            // The Work acknowledgement, for the lanes with no compose surface
            // under it to carry the row — a ⌃⌘W VOICE capture, whose whole
            // surface is the HUD, and the settled state after one. Never drawn
            // twice: the compose surface renders the same row itself, attached
            // to the words it is about.
            if coordinator.workCaptureFeedbackIsShowing, !showsComposeSurface {
                workFeedbackBand
            }
            // The footer band only renders when it has a control — so recording,
            // transcribing, and the no-reply start state don't leave an empty
            // strip below a divider.
            if hasFooterControls {
                Divider()
                micFooter
            }
            // TEXT input mode: the compose surface (staged thumbnail + field)
            // is the BOTTOM-MOST band, chat-convention — below the reply's
            // Speak/menu (or an error's Retry/Dismiss) so those stay attached to
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
        .onChange(of: lastAgentReply?.id) { _, _ in
            clearReplyActionFeedback()
            attemptAutoSpeak()
        }
        .onChange(of: coordinator.displayedPopoverConversationID) { _, _ in
            clearReplyActionFeedback()
        }
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
        // The Work acknowledgement is announced from the BODY rather than from
        // the compose surface that used to own it: a ⌃⌘W voice capture never
        // mounts that surface, and an announcement attached to a view that is
        // not on screen is an announcement nobody hears.
        .onChange(of: coordinator.quickWorkCaptureFeedback) { _, feedback in
            if let feedback { AccessibilityAnnouncer.announce(feedback.message) }
        }
        // The HUD's own status line, announced on the same terms the desk sheet
        // announces it — the popover has no other way to narrate a capture that
        // is running with the pointer somewhere else entirely.
        .onChange(of: workCaptureStatus) { _, status in
            guard coordinator.workCaptureIsActive else { return }
            AccessibilityAnnouncer.announce(workStatusText(status))
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
        // A Work capture is a pure HUD for the same reason a chat capture is,
        // and its chrome would be worse than useless: "Open in Window" points at
        // a conversation the capture has nothing to do with.
        if coordinator.workCaptureIsActive { return false }
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
                .pointerIconButton()
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
            .pointerIconButton()
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
        if coordinator.workCaptureIsActive, service.state != .recording {
            // FIRST, but only while the Ask microphone is not live. The two
            // lanes are exclusive at the MICROPHONE, not at the surface: a Work
            // capture stays active through its transcription and through a
            // standing retryable error, and ⌘⇧1 is gated on the live Work mic
            // rather than on this HUD — so an Ask recording really can be
            // running underneath. Whichever lane holds the microphone is the one
            // the person has to be able to see and stop, and the status item's
            // click already resolves it that way; the surface must agree with
            // the click or one stops what the other hides.
            //
            // Otherwise this arm is first for the reason it always was: a ⌃⌘W
            // capture has no other surface anywhere — the desk sheet is in a
            // window this popover does not open — so whatever it shows here is
            // the only place the recording can be stopped or finished. The Work
            // HUD, its Try Again and its debt return the instant the Ask
            // microphone is released.
            workCaptureView
        } else if service.state == .recording {
            recordingStatusView
        } else if isWorking {
            workingView
        } else if coordinator.showsQuickCaptureUnavailableNotice {
            // A press was just REFUSED. This outranks the reply and the error
            // because it is the answer to what the user did a moment ago: without
            // it the popover opens on the previous answer and the hotkey reads as
            // a silent no-op. Raised by the press guards, dropped on close.
            unconfiguredEmptyState
        } else if service.state == .idle, let sendError = activeSendError {
            // Gated on `.idle` so a LATER STT `.error` (whose message renders in
            // the footer) isn't double-billed with a stale agent error up here.
            sendErrorView(message: sendError)
        } else if let reply = lastAgentReply {
            replyView(reply: reply)
        } else if coordinator.isQuickCaptureKnownUnavailable {
            // The PASSIVE arm — the user opened the popover with nothing else to
            // show. Ranked BELOW the error and reply arms, not above them:
            // readiness governs whether a NEW capture can start, and nothing else.
            // The popover is also a reply viewer, and the reply it retains was
            // delivered by a gateway that worked; discarding it because the next
            // capture has no destination would throw away an answer the user asked
            // for. A refusal that needs to outrank them raises the notice above.
            //
            // `isQuickCaptureKnownUnavailable`, not `!isQuickCaptureReady`: both
            // flags start false, so before the first refresh the raw flag would
            // render the beginner "bring your own AI" pitch on a device with five
            // verified gateways — the exact false statement this whole change
            // exists to remove, just transient.
            unconfiguredEmptyState
        } else if coordinator.menuBarInputMode == .text {
            // TEXT mode start state: the compose surface (rendered below the
            // content slot) IS the affordance — no "press ⌘⇧1" hint, no tip
            // (its copy teaches the voice flow), no extra chrome.
            Color.clear.frame(height: 2)
        } else {
            startEmptyState
        }
    }

    /// True for the whole "turn in progress" phase so all three sub-phases render
    /// the SAME `workingView` at the SAME size: STT running (`.processing`), the
    /// hand-off gap before the send Task claims the flag
    /// (`coordinator.turnStarting`), and the claimed turn (`isAwaitingReply`).
    ///
    /// Stays on the CLAIM, not the dispatch flag — the popover must not resize or
    /// blink between phases, and something genuinely is happening throughout.
    /// Which of the three the user is told about is `workingPhase`'s job.
    private var isWorking: Bool {
        if service.state == .processing { return true }
        if coordinator.turnStarting { return true }
        return coordinator.quickViewModel?.isAwaitingReply == true
    }

    /// Which in-flight phase the working view is describing.
    ///
    /// Order matters: the VM's own phase is asked BEFORE `turnStarting`, because
    /// `turnStarting` stays armed across the whole send and would otherwise pin
    /// the copy to "Sending…" for the entire agent wait.
    ///
    /// The VM answers with the phase it RESOLVED rather than a bare "a turn is
    /// live" flag, so this surface can never claim a gateway is answering before
    /// the request reached it. On macOS the answer is always `.answering` while a
    /// turn is live — dispatch is stamped at turn start on an ephemeral
    /// foreground session that fails fast and never parks — so this popover reads
    /// exactly as it does today, and `.waitingForNetwork` is unreachable here.
    private var workingPhase: ThinkingPhase {
        if service.state == .processing { return .transcribing }
        if let phase = coordinator.quickViewModel?.liveTurnPhase { return phase }
        return .sending
    }

    // MARK: - Capture HUD (one layout for every lane)

    /// THE capture HUD, and the only one: ⌘⇧1 voice, ⌘⇧2 Screenshot & Ask and
    /// ⌃⌘W Capture to Work all render these three rows and nothing else — the
    /// staged screenshot if the capture has one, one indicator, one compact ✕.
    /// The lanes differ ONLY in what the indicator counts and what the ✕
    /// cancels, which is the whole point: a person who has learned to read one
    /// capture has learned to read all three. No headline (the indicator says
    /// what is happening), no stop button (stopping is hotkey-first — a second
    /// press of the same hotkey, or a click on the status item), and no privacy
    /// paragraph (a boundary is a thing to state once, not on every capture).
    ///
    /// Kept as ONE function rather than three near-identical `VStack`s so the
    /// arms cannot drift apart: geometry, spacing and padding live here.
    private func captureHUD<Indicator: View>(
        screenshot: Data?,
        cancelLabel: LocalizedStringResource = Self.cancelLabel,
        cancel: @escaping () -> Void,
        @ViewBuilder indicator: () -> Indicator
    ) -> some View {
        VStack(spacing: 16) {
            // Renders nothing when the capture staged no image (plain voice).
            captureThumbnail(screenshot)

            indicator()

            // Compact cancel, grouped right under the indicator (NOT a heavy
            // bottom-footer button).
            cancelButton(label: cancelLabel, action: cancel)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
    }

    /// The chat lane's live recording — plain ⌘⇧1 voice and ⌘⇧2 Screenshot &
    /// Ask are the same HUD, differing only in whether an image rides the turn.
    /// Cancel routes through the coordinator chokepoint (discards audio AND any
    /// staged screenshot, no STT, releases the armed destination), then
    /// dismisses — identical to Esc.
    private var recordingStatusView: some View {
        captureHUD(
            screenshot: coordinator.pendingCaptureImage,
            cancel: {
                coordinator.cancelActiveCapture()
                dismiss()
            }
        ) {
            RecordingStatusIndicator(
                elapsed: service.recordingTime,
                nearMaxDuration: service.nearMaxDuration
            )
        }
    }

    /// Thumbnail of a staged region screenshot (≤240×120, rounded + stroked).
    /// Takes the bytes rather than reading one lane's slot, because the two
    /// lanes stage into SEPARATE slots (a Work screenshot must never ride a
    /// later Ask turn) and both draw the same thumbnail. An `NSImage(data:)`
    /// failure renders nothing rather than crashing.
    @ViewBuilder
    private func captureThumbnail(_ data: Data?) -> some View {
        if let data, let nsImage = NSImage(data: data) {
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
    //
    // It has TWO aims, and `coordinator.composeTarget` says which one is on
    // screen. Aimed at Chat it is unchanged. Aimed at Work (⌃⌘W in text mode) it
    // edits a SEPARATE composition, titles itself "Add to Work", draws no Ask
    // affordance at all, and routes both Return and ⌘Return to the desk. The two
    // texts never mix: the aim survives a click-away dismissal exactly as the
    // words do, so a private sentence can never be the thing Chat's Return
    // picks up on the next ⌘⇧1 summon.

    /// Visible in the settled/idle states of TEXT mode only. Hidden while a
    /// turn is in flight (`isWorking` — the chrome-free working HUD), while a
    /// shared-service capture runs (window-composer mic edge), and during an
    /// unresolved agent `sendError` (its footer owns the surface: Retry /
    /// Dismiss first). It deliberately remains available without a configured
    /// gateway because "Add to Work" is a private, local-only capture path;
    /// only the sibling Ask action is gated on gateway readiness. SHOWN over a
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
        // A live Work capture owns the surface — the HUD is the whole popover.
        guard !coordinator.workCaptureIsActive else { return false }
        // The Work-only state is reachable in text mode ONLY, but it is not
        // gated on the send-error / STT arms below: those describe the gateway
        // lane, and a desk composition has nothing to do with either.
        if coordinator.composeTarget == .work {
            return coordinator.menuBarInputMode == .text
        }
        guard coordinator.menuBarInputMode == .text,
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
        let isWorkOnly = coordinator.composeTarget == .work
        return VStack(spacing: 10) {
            // The Work-only state announces itself. Without a title the surface
            // is indistinguishable from the Chat one, and the difference is
            // where a Return press sends private words.
            if isWorkOnly {
                Label(
                    String(localized: LocalizedStringResource(
                        "workboard.menuBar.compose.work.title",
                        defaultValue: "Add to Work"
                    )),
                    systemImage: "tray.and.arrow.down"
                )
                .font(.callout.weight(.semibold))
                .foregroundStyle(AppColors.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityAddTraits(.isHeader)
            }

            composeThumbnail

            TextField(
                String(localized: isWorkOnly
                    ? LocalizedStringResource(
                        "workboard.menuBar.compose.work.placeholder",
                        defaultValue: "Write a note for your desk"
                    )
                    : LocalizedStringResource(
                        "workboard.menuBar.compose.placeholder",
                        defaultValue: "Write a note or message"
                    )),
                text: isWorkOnly ? $coordinator.quickWorkDraft : $coordinator.quickDraft,
                axis: .vertical
            )
            .textFieldStyle(.plain)
            .font(.callout)
            .foregroundStyle(AppColors.textPrimary)
            .lineLimit(1...6)
            .focused($composeFocused)
            .onSubmit {
                // Return follows the surface, never the habit: on the Work
                // surface it saves, and the gateway readiness that gates the
                // Chat send is not consulted at all — the desk needs none.
                if isWorkOnly {
                    coordinator.saveQuickDraftToWork()
                    return
                }
                guard coordinator.isQuickCaptureReady else { return }
                coordinator.sendQuickTypedDraft()
            }
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
            // The whole card is a focus target — the editable `TextField` is only
            // as tall as its text, so the card's 12pt side and 9pt top/bottom
            // padding were dead: a click there placed no caret. Same behind-content
            // hit layer the window composer uses (`MessageComposerBar`): a
            // `.background`, never an `.overlay` (which would steal clicks from the
            // field), and hidden from accessibility so it adds no phantom element.
            .background(
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { composeFocused = true }
                    .accessibilityHidden(true)
            )

            if let feedback = coordinator.quickWorkCaptureFeedback {
                workFeedbackRow(feedback)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            HStack(spacing: 10) {
                if isWorkOnly {
                    // The Work-only state's own exit. It is the ONLY way back
                    // to the Chat surface that also throws the words away, and
                    // it has to be visible: a composition aimed at the desk
                    // survives every dismissal, so a person who changed their
                    // mind needs somewhere to say so.
                    Button(String(localized: LocalizedStringResource(
                        "common.cancel",
                        defaultValue: "Cancel"
                    ))) {
                        coordinator.discardWorkOnlyCompose()
                    }
                    .buttonStyle(.plain)
                    .font(.callout)
                    .foregroundStyle(AppColors.textSecondary)
                    .pointerIconButton(shape: .capsule)

                    Spacer(minLength: 0)
                }

                Button {
                    coordinator.saveQuickDraftToWork()
                } label: {
                    HStack(spacing: 7) {
                        if coordinator.isSavingQuickDraftToWork {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "tray.and.arrow.down")
                        }
                        Text(String(localized: LocalizedStringResource(
                            "workboard.menuBar.addToWork",
                            defaultValue: "Add to Work"
                        )))
                    }
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(AppColors.textPrimary)
                    .padding(.horizontal, 12)
                    .frame(minHeight: 36)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(AppColors.cardBackgroundElevated)
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .stroke(AppColors.border, lineWidth: 1)
                            )
                    )
                }
                .choiceCardButton(cornerRadius: 10)
                .disabled(
                    !(isWorkOnly ? coordinator.hasWorkComposeState : coordinator.hasComposeState)
                        || coordinator.isSavingQuickDraftToWork
                )
                // ⌘Return commits the surface the person is looking at. On the
                // Chat surface it stays Ask's; here Ask is not drawn, so the
                // same press must reach the only action there is rather than
                // doing nothing.
                .keyboardShortcut(isWorkOnly ? KeyboardShortcut(.return, modifiers: .command) : nil)
                .help(String(localized: LocalizedStringResource(
                    "workboard.menuBar.addToWork.help",
                    defaultValue: "Save this as private work without contacting your AI"
                )))

                if !isWorkOnly {
                    Spacer(minLength: 0)

                    Button {
                        coordinator.sendQuickTypedDraft()
                    } label: {
                        Label(
                            String(localized: LocalizedStringResource(
                                "workboard.menuBar.ask",
                                defaultValue: "Ask"
                            )),
                            systemImage: "arrow.up"
                        )
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(Color.black)
                        .padding(.horizontal, 14)
                        .frame(minHeight: 36)
                        .background(
                            Capsule(style: .continuous)
                                .fill(AppColors.brandAmber)
                        )
                    }
                    .primaryCTAButton()
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(
                        !coordinator.hasComposeState
                            || !coordinator.isQuickCaptureReady
                            || coordinator.isSavingQuickDraftToWork
                    )
                    .help(String(localized: LocalizedStringResource(
                        "workboard.menuBar.ask.help",
                        defaultValue: "Send this to your default AI gateway"
                    )))
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 6)
        .padding(.bottom, 12)
        // Conditional rendering means this fires on every popover open AND
        // every hidden→shown re-mount (turn settled) — exactly the moments
        // the field should reclaim focus.
        .onAppear { focusComposeField() }
        // Re-focus when the surface flips between the two aims: the field is
        // the same view but a different binding, and a ⌃⌘W press onto an
        // already-open popover re-mounts nothing.
        .onChange(of: coordinator.composeTarget) { _, _ in focusComposeField() }
        .onChange(of: coordinator.compose.activeText) { _, newValue in
            if !newValue.isEmpty {
                coordinator.quickWorkCaptureFeedback = nil
            }
        }
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

    /// The staged screenshot above the field, with a hover-revealed remove-✕.
    /// Text mode keeps the image across an IMPLICIT click-away dismissal; Esc and
    /// the explicit Cancel/Dismiss controls discard it (together with the draft).
    /// This hover-✕ drops ONLY the image while keeping the popover open + draft.
    ///
    /// It follows the surface's AIM, exactly as the text field does: aimed at
    /// Work it shows the ⌃⌘W screenshot and its ✕ clears that slot, aimed at
    /// Chat it shows the ⌘⇧2 one. Reading a single slot would put a private
    /// screenshot above a field whose Return sends to a gateway — the image
    /// half of the leak the two-slot composition exists to prevent.
    @ViewBuilder
    private var composeThumbnail: some View {
        let isWorkOnly = coordinator.composeTarget == .work
        let staged = isWorkOnly ? coordinator.pendingWorkCaptureImage : coordinator.pendingCaptureImage
        if staged != nil {
            ZStack(alignment: .topTrailing) {
                captureThumbnail(staged)
                Button(action: {
                    if isWorkOnly {
                        coordinator.clearPendingWorkCaptureImage()
                    } else {
                        coordinator.clearPendingCaptureImage()
                    }
                }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(AppColors.textPrimary, AppColors.cardBackgroundElevated)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                // Circular wash, like `cancelButton`: the chrome is a filled
                // circle, so a rounded square tints only the corners around it.
                // Size stays at the 28pt floor — shrinking the wash to the 14pt
                // glyph would also shrink the live square below `minTarget`.
                .pointerIconButton(shape: .circle)
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

    // MARK: - Work capture HUD (⌃⌘W)
    //
    // The Ask HUD, bound to the Work lane. It renders `captureHUD` — the same
    // three rows, the same geometry — and diverges only in what its indicator
    // counts and what its ✕ cancels. That sameness is the design: ⌃⌘W is a
    // capture like the other two, and a person who has read one of these
    // surfaces has read all of them.
    //
    // What the desk's `WorkboardVoiceCaptureView` shows and this does NOT: the
    // status headline (the indicator already says which of the four things is
    // happening), the "Stop and Save" capsule (stopping is hotkey-first —
    // a second ⌃⌘W or a click on the status item), and the privacy paragraph
    // (the sheet is where somebody chose to start a recording and is reading;
    // a HUD that repeats a boundary on every capture is noise, not consent).
    // The state→sentence mapping is still shared through
    // `MenuBarWorkVoiceStatus`, because it is now what VoiceOver announces —
    // the two surfaces may not describe one recorder state with two words.
    //
    // Everything a gateway needs is absent by construction: no destination
    // picker, no Ask, no "send".

    private var workRecorder: InAppAudioRecorder { coordinator.workVoiceRecorder }

    private var workCaptureStatus: MenuBarWorkVoiceStatus {
        MenuBarWorkVoiceStatus.resolve(workRecorder.state)
    }

    /// The sentence for one status. Every key here already ships for the desk's
    /// own sheet — a capture that reads one way in a window and another way in
    /// the menu bar is the drift this borrows its way out of.
    private func workStatusText(_ status: MenuBarWorkVoiceStatus) -> String {
        switch status {
        case .starting:
            return String(localized: LocalizedStringResource(
                "workboard.voice.starting",
                defaultValue: "Starting the microphone…"
            ))
        case .listening:
            return String(localized: LocalizedStringResource(
                "workboard.voice.listening",
                defaultValue: "Listening"
            ))
        case .transcribing:
            return String(localized: LocalizedStringResource(
                "workboard.voice.transcribing",
                defaultValue: "Turning speech into text…"
            ))
        case .preparing:
            return String(localized: LocalizedStringResource(
                "workboard.voice.preparing",
                defaultValue: "Preparing on-device voice…"
            ))
        case .stopped:
            return String(localized: LocalizedStringResource(
                "workboard.voice.error.title",
                defaultValue: "Voice capture stopped"
            ))
        }
    }

    /// The whole ⌃⌘W surface, one arm per recorder state. Every arm is
    /// `captureHUD`; only the middle row and the ✕'s target change.
    @ViewBuilder
    private var workCaptureView: some View {
        switch workRecorder.state {
        case .recording(let startedAt):
            // The one arm with a timer, and it starts at the instant the
            // microphone actually went live — `LiveRecordingStatusIndicator`
            // owns its own per-second tick, so the recorder's observed state
            // stays stable for the length of the capture.
            captureHUD(
                screenshot: coordinator.pendingWorkCaptureImage,
                cancel: cancelWorkCapture
            ) {
                LiveRecordingStatusIndicator(startedAt: startedAt)
            }

        case .idle:
            // The start's own suspension: the popover is up because
            // `workCaptureIsActive` counts the summon, but the microphone is
            // not live yet. A timer here would count seconds of a recording
            // that does not exist, so this arm says only "something is
            // happening" — the one claim that is true.
            captureHUD(
                screenshot: coordinator.pendingWorkCaptureImage,
                cancel: cancelWorkCapture
            ) {
                ProgressView().controlSize(.small)
            }

        case .processing, .preparingVoice:
            // The recording is over and the words are being fetched. The ✕
            // STAYS — unlike the chat lane's working view, this phase owns a
            // real cancellable task (`cancelProcessing`) — and it says what it
            // cancels, because cancelling a transcription is not cancelling the
            // recording: the card the recording became stays on the desk.
            captureHUD(
                screenshot: coordinator.pendingWorkCaptureImage,
                cancelLabel: LocalizedStringResource(
                    "popover.cancelTranscription",
                    defaultValue: "Cancel transcription"
                ),
                cancel: cancelWorkCapture
            ) {
                workTranscriptionIndicator
            }

        case .error(let error):
            workCaptureErrorView(error)
        }
    }

    /// The transcription phase's middle row. A determinate bar when the Apple
    /// on-device model is coming down and the installer reports a fraction —
    /// that download runs for minutes, and a bare spinner would claim to know
    /// less than the recorder does. Everything else spins.
    @ViewBuilder
    private var workTranscriptionIndicator: some View {
        if case .preparingVoice(let progress) = workRecorder.state, let progress {
            ProgressView(value: progress)
                .frame(maxWidth: 200)
                .tint(AppColors.brandAmber)
        } else {
            ProgressView().controlSize(.small)
        }
    }

    /// The failure, in one sentence and at most two controls.
    ///
    /// The sentence is the recorder's own typed verdict rendered WITH its
    /// remedy: the buttons this HUD used to carry are gone, so the copy is the
    /// only guidance left and a cause-only line would delete the actionable
    /// half of a certificate or credential refusal.
    ///
    /// Above it sits the one fact the verdict cannot state, because it is about
    /// the desk rather than the failure: whether the recording landed. "The
    /// transcription failed" over a recording that is safely on the desk and
    /// over one that never reached it are two different pieces of news, and the
    /// person's next move differs (wait and retry vs. say it again).
    @ViewBuilder
    private func workCaptureErrorView(_ error: AppError) -> some View {
        VStack(spacing: 16) {
            // The picture stays through a failure, unlike every success path:
            // an unfinished capture still owns a card and a Try Again, and this
            // is what says WHICH capture the sentence below is about.
            captureThumbnail(coordinator.pendingWorkCaptureImage)

            VStack(spacing: 6) {
                if let outcome = workCaptureOutcomeText {
                    Text(outcome)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(AppColors.textPrimary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Text(workCaptureFailureText(error))
                    .font(.caption)
                    .foregroundStyle(
                        workRecorder.retryRefusedBusy ? AppColors.warning : AppColors.textSecondary
                    )
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 10) {
                // Try Again FINISHES this capture — the card it already
                // published, or the words it already recognized — never a
                // second recording beside the first. Withheld on a terminal
                // verdict (`isRetryable`), because the identical request
                // reaches the identical answer and the spinner buries the
                // sentence the person needed to read.
                if error.isRetryable, workRecorder.canRetryWorkCapture {
                    Button {
                        Task { await coordinator.finishWorkVoiceCapture() }
                    } label: {
                        Label(
                            String(localized: LocalizedStringResource(
                                "workboard.voice.tryAgain",
                                defaultValue: "Try Again"
                            )),
                            systemImage: "arrow.counterclockwise"
                        )
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(Color.black)
                        .padding(.horizontal, 14)
                        .frame(minHeight: 34)
                        .background(Capsule(style: .continuous).fill(AppColors.brandAmber))
                    }
                    .primaryCTAButton()
                }

                // The ✕ is the same control it is in every other state, and it
                // is destructive to nothing: clearing the error releases the
                // popover, and the capture the recorder is still holding stays
                // in the retry queue the desk offers.
                cancelButton(action: cancelWorkCapture)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
    }

    /// What the desk got, said before the reason it got no more.
    ///
    /// READ FROM THE RECORDER'S FACTS, never inferred from the error's identity.
    /// A Work capture publishes up to two things — a picture and the words — on
    /// two independent terms, and either can land while the other is refused. A
    /// sentence derived from the failure alone therefore lies in both
    /// directions: it says nothing arrived when the screenshot did, and it says
    /// only the picture is missing when the words went with it.
    /// `workCaptureFacts` is what actually happened.
    ///
    /// THE RECORDING IS NEVER PART OF THE NEWS, because it is never on the desk.
    /// It is parked on this Mac until the words are written and then deleted, so
    /// the honest thing to say about a capture whose words never arrived is that
    /// the recording is being KEPT — which is the sentence that makes Try Again
    /// mean something. `recordingOnDesk` survives for the one legacy shape it
    /// still describes: a recording an earlier build published, standing at the
    /// capture id, that took these words onto itself. That case lands with the
    /// words, so it needs no sentence of its own.
    ///
    /// `nil` when there is nothing to add: everything the capture carried is on
    /// the desk. Unreachable today (a capture with both landed is a success, not
    /// an error) — and the right answer if it ever is reachable, because
    /// inventing a third claim about the desk is what this exists to stop. The
    /// failure's own sentence still renders below.
    private var workCaptureOutcomeText: String? {
        let facts = workRecorder.workCaptureFacts
        // A picture is MISSING only when it is nowhere: not taken is not
        // missing (a voice note started with Return carries none, and telling
        // that person one is missing invents an artifact they never took), and
        // neither is an import still PENDING — that envelope is durable and its
        // card is coming, so the only honest word for it is "on its way".
        //
        // The pending flag, not the raw `screenshotQueued`: acceptance is
        // HISTORICAL and never taken back, so a picture whose card arrived and
        // was then deleted still reads as queued forever. Nothing is on its way
        // there; the person deleted the thing, and a surface still promising
        // its arrival is arguing with what they just did.
        let screenshotMissing = facts.screenshotStaged
            && !facts.screenshotOnDesk
            && !facts.screenshotImportPending

        guard facts.wordsOnDesk else {
            // The words are the whole of what a spoken capture produces, so
            // their absence is the news — and the recording that would have
            // produced them is the reassurance, because it is still here.
            if facts.screenshotOnDesk {
                return String(localized: LocalizedStringResource(
                    "workboard.voice.error.wordsMissing",
                    defaultValue: "Your screenshot is on your desk. The words are not yet."
                ))
            }
            // Accepted, not arrived. Publication hands back an id before the
            // desk has imported the envelope, so the two states are one
            // question apart and the sentence has to keep them apart: a
            // picture claimed as filed that no card holds is the same false
            // receipt in a smaller font.
            if facts.screenshotImportPending {
                return String(localized: LocalizedStringResource(
                    "workboard.voice.error.wordsMissingScreenshotQueued",
                    defaultValue: "Your screenshot is on its way to your desk. The words are not yet."
                ))
            }
            // Present tense, and scoped to THIS CAPTURE. "Nothing reached your
            // desk" is a claim about history, and it is false for a capture
            // whose cards were confirmed and then deleted — the state this
            // branch is reached in once presence is re-read rather than
            // remembered. "Nothing is on your desk" fixes the tense and breaks
            // the scope instead: the facts behind this sentence describe one
            // capture's artifacts and say nothing whatever about the cards
            // already on the board, which a person looking at a full desk can
            // see it contradicting.
            //
            // The second clause is the one that makes the first bearable, and
            // it is true of every capture that reaches here: the recording is
            // parked on this Mac, exempt from every clock, and Try Again is
            // what turns it into the note.
            return String(localized: LocalizedStringResource(
                "workboard.voice.error.captureAbsent",
                defaultValue: """
                    Nothing from this capture is on your desk yet. The recording \
                    is kept on this Mac for Try Again.
                    """
            ))
        }

        // The words landed, so the only thing that can have put this arm on
        // screen is a refused picture — and the Try Again below republishes
        // exactly that.
        guard screenshotMissing else { return nil }
        return String(localized: LocalizedStringResource(
            "workboard.voice.error.screenshotMissing",
            defaultValue: "Your words are on your desk. The screenshot is not."
        ))
    }

    /// The reason, in the recorder's own words — except while a Try Again was
    /// refused because ANOTHER surface (the retry card, a Shortcut host) is
    /// already finishing this recording. Nothing failed there and nothing was
    /// deleted, so the busy sentence is both truer and more useful than
    /// reprinting a verdict the person just acted on.
    private func workCaptureFailureText(_ error: AppError) -> String {
        if workRecorder.retryRefusedBusy {
            return String(localized: LocalizedStringResource(
                "pendingRetry.card.busy",
                defaultValue: "This recording is already being finished. Try again in a moment."
            ))
        }
        return error.descriptionWithRecovery()
    }

    /// The ✕'s action in every Work arm. Narrower than `cancelActiveCapture`
    /// on purpose: this button belongs to the Work capture, and a chat turn
    /// that happens to be in flight underneath the HUD is not the thing the
    /// person is cancelling. Discards the recording (nothing has reached the
    /// desk yet at that point), abandons a transcription in flight, or clears a
    /// standing error — and drops the staged screenshot with it — then dismisses,
    /// because ✕ and Esc are one press out everywhere else in this popover.
    private func cancelWorkCapture() {
        coordinator.cancelWorkVoiceCapture()
        dismiss()
    }

    // MARK: - Work acknowledgement

    /// The standalone "Added to Work" band, for the states with no compose
    /// surface to carry the row — a ⌃⌘W VOICE capture, whose whole surface is
    /// the HUD. Transient: it stays until the popover is dismissed, with no
    /// auto-dismiss timer, because a receipt that erases itself while somebody
    /// is reading it is a receipt they cannot check.
    /// It renders the feedback VALUE and nothing else. A partial capture never
    /// reaches this band: a refused picture leaves the recorder in a retryable
    /// error whose Try Again republishes it, so the HUD owns that outcome and
    /// this row only ever reports a whole success. Reading any recorder state
    /// here would also outlive the capture it described — the flags reset on
    /// the NEXT capture, not when a receipt is consumed, so a typed note saved
    /// in between would inherit a warning about a recording it has nothing to
    /// do with.
    private var workFeedbackBand: some View {
        Group {
            if let feedback = coordinator.quickWorkCaptureFeedback {
                workFeedbackRow(feedback)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }

    /// One acknowledgement row, in both places it is drawn.
    ///
    /// A SAVED row is a BUTTON, because the sentence it prints is a claim the
    /// person is entitled to check: the card is on the desk, the desk is one
    /// click away, and a banner that says a thing happened without offering to
    /// show it is asking to be believed. A FAILED row stays inert — there is
    /// nothing on the desk to go and look at. A QUEUED row stays inert for the
    /// same reason read the other way: the note is durable in the inbox but the
    /// import has not happened, so there is no card yet to offer, and a button
    /// here would promise one.
    @ViewBuilder
    private func workFeedbackRow(_ feedback: MenuBarWorkCaptureFeedback) -> some View {
        switch feedback.kind {
        case .saved:
            Button(action: openWorkboard) {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                    Text(feedback.message)
                        .multilineTextAlignment(.leading)
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                }
                .font(.caption)
                .foregroundStyle(AppColors.success)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointerIconButton(shape: .capsule)
            .help(String(localized: LocalizedStringResource(
                "workboard.menuBar.saved.open.help",
                defaultValue: "Open Work and see the new card"
            )))
        case .queued:
            Label(feedback.message, systemImage: "clock")
                .font(.caption)
                .foregroundStyle(AppColors.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .failed:
            Label(feedback.message, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(AppColors.error)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Raise the desk on the card that was just added. Same two lines the
    /// status-item menu's Work entry uses, so the popover and the menu reach the
    /// board the same way; the popover closes behind it, since the window it
    /// just raised is where the answer is.
    private func openWorkboard() {
        NSApp.activate(ignoringOtherApps: true)
        NotificationCenter.default.post(name: .showWorkboard, object: nil)
        dismiss()
    }

    // MARK: - Working view (transcribing → gap → answering)

    /// ONE view for the entire turn — STT, the hand-off gap, and the agent wait
    /// (see `isWorking`). The layout is IDENTICAL in every phase (a centered
    /// spinner + status label, with the Cancel-X's space ALWAYS reserved below),
    /// so the popover does not resize as "Transcribing…" becomes "Sending…"
    /// becomes "{gateway} is answering…" — only the label crossfades. The X is
    /// interactive only once there's an in-flight reply to cancel
    /// (hidden-but-space-reserved through STT and the pre-dispatch window);
    /// tapping it aborts the reply AND closes (mirrors Esc).
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
            // Interactive ONLY in `.answering`. During `.sending` there is no
            // task to cancel yet — an X there would dismiss the popover while
            // the send carried on underneath, which reads as "cancelled" and
            // isn't. Space stays reserved in every phase so the popover never
            // resizes.
            //
            // Through STT this is restraint, not inability: Esc DOES cancel a
            // transcription (`DictationService` invalidates the run's generation,
            // so its words never reach `onTranscript`), and one exit for one
            // phase is the popover's rule — a second control that says the same
            // thing is a second thing to explain.
            //
            // MACOS-SPECIFIC REASONING, and the phone deliberately does the
            // opposite: an iOS send has a real background `URLSessionTask` from
            // `resume()`, so its Stop is lit in every phase and stopping a turn
            // whose bytes never left names why it failed. Here there is nothing
            // to cancel until the foreground request exists, and macOS never
            // parks, so the pre-dispatch window is too short to need an exit.
            .opacity(workingPhase == .answering ? 1 : 0)
            .allowsHitTesting(workingPhase == .answering)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
        // Crossfade the label (Transcribing… → answering…) and fade the X in,
        // with NO size change. Instant under Reduce Motion.
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: workingLabel)
    }

    /// "Transcribing…" → "Sending…" → "{gateway} is answering…", through the
    /// shared resolver. During the hand-off gap the VM may be momentarily nil (a
    /// fresh conversation being minted); an absent or unresolved name falls back
    /// to a plain "Answering…" so the label never blanks and never renders a
    /// leading-space " is answering…".
    private var workingLabel: String {
        ThinkingIndicator.label(
            phase: workingPhase,
            backendName: coordinator.quickViewModel?.backendDisplayName ?? ""
        )
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
    ///
    /// TWO wordings. Nothing configured → the beginner pitch. Something configured
    /// but not the default → the `DefaultNeedsSetup` wording, which is the only one
    /// that is true there: the user has AI, this lane just has no destination.
    ///
    /// The condition reads the SHARED verdict rather than re-deriving one from a
    /// pair of booleans, so the popover and every other surface can never
    /// disagree about which state this device is in. `needsUserChoice` is true
    /// for exactly the two verdicts this arm exists for — a stored default that
    /// cannot send while others can, and no default chosen at all — and both are
    /// "gateways work here, but the quick lane has no destination the user
    /// picked". The shortcut hint is dropped in that arm: it reads "after setup,
    /// press ⌘⇧1", and here setup is not what is missing.
    private var unconfiguredEmptyState: some View {
        let needsDefault = coordinator.defaultGatewayResolution?.needsUserChoice == true
        return VStack(spacing: 12) {
            Image(systemName: "gearshape.2")
                .font(.system(size: 40))
                .foregroundStyle(AppColors.brandAmber.opacity(0.7))
                .accessibilityHidden(true)   // decorative — the headline is the label
            Text(needsDefault ? UnconfiguredCopy.DefaultNeedsSetup.headline : UnconfiguredCopy.headline)
                .font(.headline)  // compact surface — no .title2 promotion here
                .foregroundStyle(AppColors.textPrimary)
                .accessibilityAddTraits(.isHeader)
            Text(needsDefault ? UnconfiguredCopy.DefaultNeedsSetup.body : UnconfiguredCopy.body)
                .font(.callout)
                .foregroundStyle(AppColors.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 24)
            if !needsDefault, let shortcut = KeyboardShortcuts.getShortcut(for: .toggleVoiceCapture) {
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
                Text(needsDefault ? UnconfiguredCopy.DefaultNeedsSetup.button : UnconfiguredCopy.button)
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

            // The second hotkey, rendered from the user's ACTUAL binding for the
            // same reason the line above is: both are user-configurable, and a
            // hint naming the default is wrong on any machine that changed it.
            // "Capture" is the one word for this action everywhere it is named
            // — the status-item menu, the Settings shortcut row and this hint —
            // and it is the accurate one: the press takes a screenshot, a
            // recording or a typed note, and "a private note" describes only
            // the last of the three.
            if let workShortcut = KeyboardShortcuts.getShortcut(for: .captureToWork) {
                Text(String(localized: LocalizedStringResource(
                    "popover.start.captureToWork",
                    defaultValue: "Press \(workShortcut.description) to capture to Work"
                )))
                .font(.caption)
                .foregroundStyle(AppColors.textTertiary)
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
            .pointerIconButton()
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
    // The footer band renders ONLY for the settled reply (Speak + message menu), for a
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
                // A failed AGENT turn takes the footer over Speak/menu — Retry
                // re-fires the failed bubble; Dismiss returns to the reply/hint.
                if activeSendError != nil, let vm = coordinator.displayedPopoverViewModel {
                    sendErrorActions(vm: vm)
                        .transition(.opacity)
                } else {
                    // The queue's recovery sits BESIDE the reply's controls
                    // rather than instead of them. An `else if` would have been
                    // tidier and wrong: the popover retains its last answer
                    // indefinitely, so "there is a reply on screen" is the
                    // ordinary state, and a recovery ranked below it would be
                    // invisible almost always — which is the defect, not a
                    // narrower version of it. It is kept out of the
                    // send-error arm above for the opposite reason: that arm
                    // draws a Retry of its own, and two controls wearing one
                    // word in one row is worse than a missing one.
                    savedRecordingRecoveryAction
                        .transition(.opacity)
                    if let reply = lastAgentReply, let vm = coordinator.displayedPopoverViewModel {
                        // Speak + message menu on the retained reply (idle after a finished turn).
                        replyActions(reply: reply, vm: vm)
                            .transition(.opacity)
                    }
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

    /// The durable queue's own recovery, for the IDLE surface.
    ///
    /// The same control the error footer draws — same key, same `retryLast()`
    /// — because it is the same action: transcribe the bytes the store parked.
    /// It needs a second home only because a person can dismiss the error that
    /// parked them (the Work HUD's ✕ does), after which the recording has no
    /// affordance anywhere in the menu bar while the queue still holds it.
    /// Nothing accompanies it: it appears only while there is something to
    /// recover, so its presence is the message.
    ///
    /// THE GATE IS `canRecoverPendingQueue`, NOT `AppError.isRetryable`, and
    /// deliberately so. Bytes reach the queue only through
    /// `AppError.shouldPreserveForRetry`, which asks the sharper question: do
    /// these SAME bytes succeed on a second attempt. It answers yes for two
    /// verdicts `isRetryable` calls terminal — a default that needs setting up,
    /// and a locked key — precisely because the recording is bit-for-bit valid
    /// and the fix is one tap. Gating on retryability instead would strand a
    /// recording over a verdict the taxonomy already says is recoverable, and
    /// the count being non-zero is the only thing that makes `retryLast()`
    /// reach any bytes at all. Registered as a gate token in
    /// `ErrorSurfaceDriftGuardTests`.
    @ViewBuilder
    private var savedRecordingRecoveryAction: some View {
        // The gate lives HERE, not at the call site: a control whose condition
        // is one scope up can be drawn without it by the next edit, and this
        // one dead-ends in "No saved recording to retry" the moment it is.
        let availability = SavedRecordingRecoveryAvailability.resolve(
            isBusy: service.state == .recording || isWorking || coordinator.workCaptureIsActive,
            waitingCount: service.pendingRetryCount,
            hasUnsentRequest: coordinator.hasPendingFailedTurn
        )
        if service.canRecoverPendingQueue, availability == .ready {
            HStack(spacing: 12) {
                Button(action: { service.retryLast() }) {
                    Text(LocalizedStringResource(
                        "popover.retry.savedRecording.action",
                        defaultValue: "Retry saved recording"
                    ))
                    .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.borderedProminent)
                .tint(AppColors.brandAmber)
                .controlSize(.small)
                Spacer(minLength: 0)
            }
        }
    }

    /// The agent reply the popover shows (drives the Speak + message menu control row +
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
    /// (`sendError` → Retry/Dismiss), and on a settled reply (Speak + message menu).
    private var hasFooterControls: Bool {
        // The Work HUD owns the whole surface; Speak/menu/Retry below it would
        // act on a conversation that is not on screen.
        if coordinator.workCaptureIsActive { return false }
        if service.state == .recording || isWorking { return false }
        // The refusal notice replaces the content slot, so the reply's Copy /
        // Speak and the error's Retry / Dismiss would be operating on something
        // that is no longer on screen — and that Retry re-fires the same
        // undeliverable route. The passive arm needs no such term: it renders only
        // when there is no reply and no error to control.
        if coordinator.showsQuickCaptureUnavailableNotice { return false }
        switch service.state {
        case .error: return true
        // The queue joins the two reasons an idle footer already had. A parked
        // recording is reachable ONLY from here: the error that parked it can
        // be dismissed (the Work HUD's ✕ does exactly that), and dismissing an
        // error must not be what decides whether somebody's words survive.
        case .idle:
            return lastAgentReply != nil || activeSendError != nil
                || service.canRecoverPendingQueue
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

    /// The ✕'s default reading. Declared once so the four surfaces that draw a
    /// plain cancel cannot pick up four wordings of it.
    private static let cancelLabel = LocalizedStringResource("popover.cancel", defaultValue: "Cancel")

    /// Compact cancel control, shared by every capture HUD and the in-flight
    /// wait. `xmark.circle.fill` at 24pt — a lot lighter than a 40pt footer
    /// button; Esc does the same thing in every state.
    ///
    /// The LABEL is a parameter because the glyph is not always cancelling the
    /// same thing: on a Work transcription it abandons the words while the
    /// recording stays on the desk, and a VoiceOver user who heard only
    /// "Cancel" would have no way to know which of the two they were about to
    /// lose. Sighted users read that from the surface around it; this is the
    /// only place the distinction can be said out loud.
    private func cancelButton(
        label: LocalizedStringResource = Self.cancelLabel,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 24))
                .foregroundStyle(AppColors.textSecondary)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        // The 24pt filled circle fills most of the 32pt live square, so the wash
        // follows it — a rounded square would tint the corners around it.
        .pointerIconButton(size: 32, shape: .circle)
        .accessibilityLabel(Text(String(localized: label)))
    }

    // MARK: - Reply actions (Speak + message menu)
    //
    // Direct playback mirrors the thread's state machine; the shared menu owns
    // Copy and Save message to Work. Saving captures the complete displayed
    // reply, including its attachments, and never starts a turn or changes chat.

    private func replyActions(reply: MessageRecord, vm: ConversationDetailViewModel) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Spacer(minLength: 4)

                MessageActionButton(
                    accessibilityLabel: Text(speakAccessibilityLabel(for: reply.id)),
                    action: {
                        // Cross-engine arbitration happens inside ThreadSpeaker.
                        speaker.speak(reply.text, messageID: reply.id)
                    }
                ) {
                    speakGlyph(for: reply.id)
                }

                MessageActionsMenu(
                    didCopy: didCopy,
                    size: 14,
                    tint: AppColors.textTertiary,
                    onCopy: { copyTapped(reply: reply, vm: vm) },
                    onSaveToWork: { saveReplyToWork(reply, conversationID: vm.conversationID) }
                )
            }
            if let notice = replyWorkCaptureNotice {
                replyWorkCaptureFeedback(notice)
            }
        }
    }

    private func saveReplyToWork(_ reply: MessageRecord, conversationID: UUID) {
        let requestID = UUID()
        replyWorkCaptureID = requestID
        replyWorkCaptureNotice = nil
        Task { @MainActor in
            let notice: MessageWorkCaptureNotice
            do {
                let receipt = try await ConversationStore.shared.captureMessageToWork(
                    reply,
                    conversationID: conversationID
                )
                notice = MessageWorkCaptureNotice(receipt: receipt)
            } catch {
                notice = MessageWorkCaptureNotice(
                    itemID: nil,
                    message: error.localizedDescription,
                    isError: true
                )
            }
            guard replyWorkCaptureID == requestID,
                  coordinator.displayedPopoverConversationID == conversationID,
                  lastAgentReply?.id == reply.id else { return }
            replyWorkCaptureNotice = notice
            AccessibilityAnnouncer.announce(notice.message)
        }
    }

    /// A persistent, dismissible receipt: partial or refused attachments must be
    /// readable at the HUD's narrow width. Only a receipt with a saved card can
    /// open Work; the save itself keeps the person in the current reply.
    private func replyWorkCaptureFeedback(_ notice: MessageWorkCaptureNotice) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 6) {
                Label(notice.message, systemImage: notice.isError
                    ? "exclamationmark.triangle.fill" : "rectangle.stack.badge.checkmark")
                    .font(.caption)
                    .foregroundStyle(notice.isError ? AppColors.warning : AppColors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                MessageActionButton(
                    systemImage: "xmark",
                    size: 12,
                    tint: AppColors.textTertiary,
                    accessibilityLabel: Text(LocalizedStringResource("common.dismiss", defaultValue: "Dismiss"))
                ) {
                    replyWorkCaptureNotice = nil
                }
            }
            if let itemID = notice.itemID {
                Button {
                    NSApp.activate(ignoringOtherApps: true)
                    NotificationCenter.default.post(
                        name: .openWorkboardDeepLink,
                        object: nil,
                        userInfo: [NotificationDeepLink.workItemIDKey: itemID.uuidString]
                    )
                    dismiss()
                } label: {
                    Text(LocalizedStringResource("workboard.chatCapture.open", defaultValue: "Open Work"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AppColors.brandAmber)
                }
                .inlineLinkButton()
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func clearReplyActionFeedback() {
        replyWorkCaptureID = nil
        replyWorkCaptureNotice = nil
        copyFeedbackID = nil
        didCopy = false
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
    /// popover's compact message menu. These run a touch smaller than the chat
    /// bubble's (17/16) because the popover footer is a compact HUD strip. Every
    /// state renders the gray idle tint (`textTertiary`) — the button reads
    /// uniform like the neighboring menu, and only the glyph SHAPE signals
    /// state: idle `speaker.wave.2.fill` 15pt → loading spinner (its motion
    /// confirms the tap; no color flip) →
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

    /// Acknowledge copying after the menu closes; a newer copy or reply change
    /// supersedes the previous checkmark timer.
    private func copyTapped(reply: MessageRecord, vm: ConversationDetailViewModel) {
        vm.copy(reply)
        AccessibilityAnnouncer.announce(String(localized: LocalizedStringResource(
            "bubble.copy.copied", defaultValue: "Copied"
        )))
        let feedbackID = UUID()
        copyFeedbackID = feedbackID
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) { didCopy = true }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard copyFeedbackID == feedbackID else { return }
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { didCopy = false }
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
                // NO cap. `DictationService` routes this through
                // `descriptionWithRecovery`, so the string is cause AND remedy —
                // and at 340pt three lines hold ~150 characters against a
                // certificate refusal's ~320, which cut the remedy in half. The
                // pin-mismatch verdict was the dangerous one: "the connection may
                // be intercepted" sits at the very END of its remedy and was the
                // first thing dropped. The popover hugs its content with no
                // height cap, so wrapping just makes it taller — the only cost is
                // a bigger HUD on the rare turn that fails terminally.
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                // Retry Voice — re-record; the staged screenshot stays and rides
                // the next successful transcript.
                // The FOURTH door into the quick lane, and the only one not in
                // `MenuBarController`. Gated like the other three: the default can
                // go unready between the original capture and this retry (a peer's
                // Forget landing, a Settings edit mid-recording), and re-recording
                // into a lane that cannot deliver spends another paid
                // transcription for nothing.
                Button(action: {
                    guard !coordinator.isQuickCaptureKnownUnavailable else {
                        coordinator.noteQuickCaptureRefused()
                        return
                    }
                    service.toggleRecording()
                }) {
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

    /// True only when `PendingRetryStore` holds a recording to retry — the
    /// precondition for `retryLast` to succeed. The store's count is the
    /// direct answer: the error taxonomy (`shouldPreserveForRetry`) can only
    /// speak for the capture that just failed in THIS process, and says nothing
    /// about a capture still waiting after one finishes, or one armed by the
    /// Shortcuts lane before anything failed here. Errors that are nominally
    /// retryable but saved no bytes ("empty text", rate-limit, generic API
    /// failure) leave the count at zero and get Dismiss only, so Retry never
    /// dead-ends in "No saved recording to retry".
    private var hasSavedRetryAudio: Bool {
        service.pendingRetryCount > 0
    }

    private func errorFooter(message: String, isRetryable: Bool) -> some View {
        VStack(spacing: 8) {
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(AppColors.error)
                .multilineTextAlignment(.center)
                // NO cap. `DictationService` routes this through
                // `descriptionWithRecovery`, so the string is cause AND remedy —
                // and at 340pt three lines hold ~150 characters against a
                // certificate refusal's ~320, which cut the remedy in half. The
                // pin-mismatch verdict was the dangerous one: "the connection may
                // be intercepted" sits at the very END of its remedy and was the
                // first thing dropped. The popover hugs its content with no
                // height cap, so wrapping just makes it taller — the only cost is
                // a bigger HUD on the rare turn that fails terminally.
                .fixedSize(horizontal: false, vertical: true)
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
                // `fromPopover: true` — this button IS the menu-bar surface, so
                // the usage ledger credits the attempt to the menu bar even when
                // the original send came from the window (one VM serves both).
                Button(action: { Task { await vm.retry(failed, fromPopover: true) } }) {
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
