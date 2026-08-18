// SPDX-License-Identifier: Apache-2.0

#if os(macOS)
// Conduck
// MenuBarController.swift
//
// The menu-bar status item + popover lifecycle, now driving a
// conversation surface instead of a single-turn dictation popover. Owns:
//   - the NSStatusItem icon (6 states: idle / recording / processing-STT /
//     replying / error — plus the static idle),
//   - the popover (voice-only thread; transient idle, applicationDefined ONLY
//     during recording, transient again during the multi-minute agent wait),
//   - the context menu (Start Recording · Open Conversations · Launch at
//     Login · Settings · Quit),
//   - the global default-⌘⇧1 shortcut.
//
// 6th "replying" icon state: driven by `coordinator.quickViewModel?
// .isAwaitingReply` (between STT-done and reply-received) — the QUICK lane,
// because the menu-bar icon narrates the hotkey capture flow, not whatever
// thread the window is browsing. The controller observes BOTH
// `dictationService.state` and that flag via `withObservationTracking`.
//
// Popover lifecycle:
//   - `.transient` when idle (dismiss on outside click),
//   - `.applicationDefined` ONLY during recording (no orphaned audio session),
//   - back to `.transient` during the agent wait so the user can click away;
//     the in-flight Task survives on the long-lived VM, and a completion
//     notification + the 6th icon state carry progress.
//
// On show: the app is ACTIVATED and the popover window is made key+front so it
// receives keyboard events — notably Esc, caught by a local key-down monitor
// (`installEscMonitor`) and routed to `handleEscape`. Activation is required
// because a background app's windows can't become key (so neither a monitor nor
// the responder chain would see the key); ordering the popover front keeps it
// above any open `main`. Tradeoff: a ⌘⇧1 invocation from another app brings
// Conduck forward — the cost of an in-popover Esc.

import AppKit
import KeyboardShortcuts
import ServiceManagement
import SwiftUI

/// Notification names used by the macOS surface to drive Scene-based
/// window presentation from `ConduckApp`. The Scene branch subscribes via
/// `.onReceive(NotificationCenter.default.publisher(for:))` and routes the post
/// to `openWindow(id:)`.
extension Notification.Name {
    static let openOnboardingWindow = Notification.Name("openOnboardingWindow")
    static let openSettingsWindow = Notification.Name("openSettingsWindow")
    /// Open the dedicated Conversations library window (`Window("conversations")`).
    static let openConversationsWindow = Notification.Name("openConversationsWindow")
    /// Top-menu-bar / ⌘N "New Conversation" — opens `main` and starts a fresh thread.
    static let newConversation = Notification.Name("newConversation")
}

/// Manages the NSStatusItem (menu bar icon), popover, and context menu.
@MainActor
final class MenuBarController: NSObject, NSPopoverDelegate {
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private let coordinator: MenuBarCoordinator

    /// Local key-down monitor for Esc, live ONLY while the popover is open.
    private var escMonitor: Any?

    /// Brand-colored "reply arrived" unread dot, composited as a subview of the
    /// status button (created ONCE in `setup()`). Kept separate from the
    /// template `"menubar-conduck"` image so the duck's light/dark/click tinting
    /// stays system-correct — only the dot is custom-colored. Toggled (never
    /// recreated) by `updateUnreadBadge` from `updateIcon`.
    private var unreadBadge: NSView?

    /// Error-red "send failed" mark, the failure analog of `unreadBadge` — same
    /// 7pt top-trailing geometry + appear-pulse, created ONCE in `setup()`,
    /// toggled (never recreated) by `updateFailureBadge` from `updateIcon`. Red
    /// takes PRECEDENCE over yellow, so at most one of the two is ever visible.
    /// A filled TRIANGLE against the unread dot's circle, so the two states are
    /// distinguishable with the colour channel removed.
    private var failureBadge: NSView?

    /// Region-capture engine for "Screenshot & Ask" (⌘⇧2). Built in the parallel
    /// `ScreenCapture/RegionCaptureController.swift`; presents a drag-select
    /// overlay and returns the cropped region as PNG `Data`.
    private let regionCapture = RegionCaptureController()

    private var dictationService: DictationService { coordinator.dictationService }

    init(coordinator: MenuBarCoordinator) {
        self.coordinator = coordinator
        super.init()
    }

    func setup() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        if let button = statusItem?.button {
            applyIdleIcon(to: button)
            button.target = self
            button.action = #selector(statusBarButtonClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            installUnreadBadge(on: button)
            installFailureBadge(on: button)
        }

        // Configure popover — hosts the voice-only conversation surface. A local
        // key-down monitor (installed while the popover is open) handles Esc →
        // `handleEscape()`; the popover is set as our delegate so we tear the
        // monitor down on close. See `showPopover()` / `popoverDidClose(_:)`.
        let popoverView = DictationPopoverView(
            coordinator: coordinator,
            // The popover's "open in window" affordances hand the DISPLAYED
            // thread off to the window (continuity: glance → full thread) —
            // override-aware, so "Read full reply in window" on a shared reply
            // opens THAT thread, not the quick lane; nil (no thread yet) opens
            // the window plain.
            onOpenWindow: { [weak self] in
                self?.openConversationsWindow(
                    selecting: self?.coordinator.displayedPopoverConversationID
                )
            },
            dismiss: { [weak self] in self?.dismissPopover() }
        )
        popover.contentViewController = NSHostingController(rootView: popoverView)
        popover.delegate = self
        popover.behavior = .transient

        observeStateChanges()

        KeyboardShortcuts.onKeyUp(for: .toggleVoiceCapture) { [weak self] in
            Task { @MainActor in
                self?.handleShortcutPress()
            }
        }

        KeyboardShortcuts.onKeyUp(for: .captureRegionAndVoice) { [weak self] in
            Task { @MainActor in
                self?.handleRegionCapturePress()
            }
        }
    }

    // MARK: - Click Handling

    @objc private func statusBarButtonClicked(_ sender: NSStatusBarButton) {
        switch dictationService.state {
        case .recording:
            // Click during recording stops it (natural click-to-stop).
            dictationService.toggleRecording()
        case .processing:
            if !popover.isShown { showPopover() }
        case .idle, .error:
            // Left-click opens the popover (the primary surface); right-click or
            // control-click opens the context menu (Launch at Login / Show in
            // Dock / Settings / Quit). The button fires on both .leftMouseUp and
            // .rightMouseUp, so disambiguate via the current event.
            let ev = NSApp.currentEvent
            let isSecondary = ev?.type == .rightMouseUp
                || (ev?.modifierFlags.contains(.control) ?? false)
            if isSecondary {
                showContextMenu()
            } else {
                presentPopoverForClick()
            }
        }
    }

    /// The status-item left-click open. If the freshest unread reply is a thread
    /// OTHER than the quick lane (e.g. a share reply landed via
    /// `.remoteAgentTurnDidComplete`), show it read-only via the display override
    /// — set BEFORE `showPopover()` so the visible-thread bookkeeping marks the
    /// right conversation. A new capture (`armQuickCapture`) or a popover close
    /// clears the override. No unread / the freshest IS the quick thread ⇒ the
    /// usual quick-lane open.
    private func presentPopoverForClick() {
        // A FAILURE is more urgent than an unread reply (matches the red-over-
        // yellow dot precedence): a present failure routes the click to the
        // freshest failed thread; otherwise the freshest unread reply. The
        // override only fires when the target isn't already the quick lane;
        // `showPopover` → `setPopoverVisibleConversation` then clears its flag(s).
        let target = coordinator.hasFailure
            ? coordinator.mostRecentFailureConversationID
            : (coordinator.hasUnreadReply ? coordinator.mostRecentUnreadConversationID : nil)
        if let target, target != coordinator.quickViewModel?.conversationID {
            coordinator.setPopoverOverride(to: target)
        }
        showPopover()
    }

    // MARK: - Keyboard Shortcut

    private func handleShortcutPress() {
        switch dictationService.state {
        case .idle, .error:
            // TEXT input mode: ⌘⇧1 is a popover TOGGLE — open with the compose
            // field focused, or close when already shown (there is no recording
            // to stop-and-send). No `armQuickCapture` (text arms at Return —
            // the press analog is the send, not the summon), no
            // `discardPendingFailedTurn` (summoning isn't a fresh capture; the
            // stash dies via Dismiss / Esc-over-error / a successful send).
            if coordinator.menuBarInputMode == .text {
                if popover.isShown {
                    dismissPopover()
                } else {
                    showPopover()
                }
                return
            }
            // A capture with nowhere to land never starts. The quick lane mints
            // on the persisted default (Decision F), so when that gateway cannot
            // send, recording would spend a paid transcription and then seal a
            // conversation to a gateway that must refuse it — a dead thread in
            // the sidebar per press, since a bound ref never re-routes. The
            // popover's own empty state names the missing piece and offers the
            // one tap that fixes it, so open THAT instead of the recorder.
            guard !coordinator.isQuickCaptureKnownUnavailable else {
                coordinator.noteQuickCaptureRefused()
                showPopover()
                return
            }
            // Starting a fresh capture abandons any stashed mint-failure turn —
            // the user chose to speak anew; keeping it would let a LATER error's
            // Retry replay the stale words. (No-op from `.idle`, where no stash
            // can exist — it's only ever set alongside a presented error.)
            coordinator.discardPendingFailedTurn()
            // Freeze the capture destination AT THE PRESS (snapshot latch) so
            // what the popover displays is exactly where the words land — a
            // TTL boundary crossing during the recording must not retarget.
            coordinator.armQuickCapture()
            showPopover()
            dictationService.toggleRecording()
        case .recording:
            // Mode-independent: a live capture (in text mode only reachable via
            // the window composer's mic — the shared service) stops on press.
            dictationService.toggleRecording()
        case .processing:
            if !popover.isShown { showPopover() }
        }
    }

    /// "Screenshot & Ask" (⌘⇧2). If a capture's recording is already in flight,
    /// a second press stops-and-sends (mirrors ⌘⇧1's stop-on-second-press). Else
    /// it drag-selects a screen region, stages the screenshot on the coordinator,
    /// shows the popover, plays a subtle start cue, and starts the voice turn —
    /// the screenshot rides that turn (`MenuBarCoordinator.handleTranscript`).
    private func handleRegionCapturePress() {
        if dictationService.state == .recording {
            dictationService.toggleRecording()   // stop-and-send the in-flight capture turn
            return
        }
        // Same destination check as ⌘⇧1, and BEFORE the region drag: asking the
        // user to select a region, then a microphone, for a turn that cannot be
        // delivered is worse than the plain hotkey case. Covers text mode too —
        // its compose surface is gated on the same readiness, so a staged
        // screenshot would land somewhere with no thumbnail and no way to discard.
        guard !coordinator.isQuickCaptureKnownUnavailable else {
            coordinator.noteQuickCaptureRefused()
            showPopover()
            return
        }
        Task { @MainActor in
            let textMode = coordinator.menuBarInputMode == .text
            // `captureRegion()` returns nil on cancel / permission-deny / empty
            // selection — abort silently, nothing staged. Text mode skips the
            // mic half of the preflight — its question is typed, never recorded.
            guard let data = await regionCapture.captureRegion(
                requiresMicrophone: !textMode
            ) else { return }
            if textMode {
                // TEXT input mode: stage the region + open the compose surface
                // (thumbnail above the focused field; Return sends both as one
                // turn). No audio cue (nothing armed — the thumbnail IS the
                // cue), no destination arm (text arms at Return), no
                // stash-discard (summoning isn't a fresh capture). A second
                // ⌘⇧2 re-grabs and REPLACES the staged image.
                coordinator.setPendingCaptureImage(data)
                showPopover()
                await SettingsManager.shared.markScreenshotAskTipSeen()
                return
            }
            // Fresh capture start — same stash abandonment as ⌘⇧1 above.
            coordinator.discardPendingFailedTurn()
            coordinator.setPendingCaptureImage(data)
            // Quick-capture arms the popover lane (⌘⇧1 parity) — the screenshot
            // rides the voice turn, direct-sent to the active conversation.
            coordinator.armQuickCapture()
            showPopover()
            // Subtle "capture armed, start talking" cue (same player the auto-stop
            // cap cue uses) so the user knows the region was grabbed and the mic
            // is now live.
            CompletionFeedbackPlayer.play(mode: "sound")
            dictationService.toggleRecording()
            // Using the feature retires the one-time discovery tip.
            await SettingsManager.shared.markScreenshotAskTipSeen()
        }
    }

    // MARK: - Popover Management

    private func showPopover() {
        guard let button = statusItem?.button else { return }
        // Re-read gateway readiness on every summon. The cached flags can only go
        // stale in one direction that matters — a refresh that ran while the
        // Keychain was still locked reads a healthy `.bearer` gateway as gone —
        // and the press guards would then refuse forever, since a refusal is not
        // an event that triggers a re-read. The user opening the popover is.
        Task { [weak self] in await self?.coordinator.refreshGatewayReadiness() }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        // Keyboard focus WITHOUT `NSApp.activate`: activating a regular-policy
        // (Dock) app raises its main+key windows, so an open main chat window
        // would jump above the frontmost app (e.g. Safari) on every status-item
        // click — the "popover click drags the whole app forward" annoyance.
        // The popover's window is a non-activating panel that can become key
        // while the app stays inactive; keying it is enough for the compose
        // field AND the local Esc monitor (local monitors see any event
        // dispatched to THIS app's key window, active or not). Fallback: if the
        // OS refused key status (older behavior), fall back to full activation
        // — focus-steal is annoying, but a popover that can't take keystrokes
        // is broken.
        if let window = popover.contentViewController?.view.window {
            window.makeKey()
            if !window.isKeyWindow {
                NSApp.activate(ignoringOtherApps: true)
                window.makeKeyAndOrderFront(nil)
            }
        }
        installEscMonitor()
        // Report the quick thread as VISIBLE — the settled-visibility callback
        // that settles both of its attention markers — but ONLY when opening
        // onto settled content. During the window-composer-mic
        // auto-open (`handleStateChange` opens for a capture in
        // recording/processing/error) the popover shows a HUD, not the quick
        // thread, and the quick lane may be stale. `handleStateChange` re-sets
        // this when a reply settles into an already-open popover.
        if dictationService.state == .idle {
            coordinator.setPopoverVisibleConversation(coordinator.displayedPopoverConversationID)
        }
    }

    private func dismissPopover() {
        popover.performClose(nil)   // → popoverDidClose tears down the Esc monitor
    }

    // MARK: - Esc handling (local key monitor, popover-scoped)
    //
    // Esc is NOT a global shortcut (that would hijack Esc everywhere). A local
    // key-down monitor runs ONLY while the popover is open (installed on show,
    // removed on close), so it's naturally scoped. A local monitor — rather than
    // an `NSViewController.cancelOperation` override — is reliable regardless of
    // whether the SwiftUI hosting view synthesizes `cancelOperation` from the Esc
    // key; it inspects the raw key-down. Local monitors see events dispatched
    // to any of THIS app's windows — the keyed popover panel qualifies even
    // while the app itself stays inactive (see `showPopover()`).

    private func installEscMonitor() {
        guard escMonitor == nil else { return }
        escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if event.keyCode == 53 {   // Escape
                self.handleEscape()
                return nil             // consume — no beep, no double-close
            }
            // TEXT-input-mode compose keys. Same scoping as Esc PLUS a
            // key-window gate: the popover can be open while the MAIN window
            // is key (e.g. `handleStateChange` auto-opens it for a
            // window-composer mic capture) — these keys belong to the compose
            // field, so they fire only when the popover's window is the one
            // receiving keystrokes. Without the gate, `return nil` would
            // swallow an event meant for another window even when nothing
            // handled the re-dispatched action.
            if self.coordinator.menuBarInputMode == .text, self.popover.isShown,
               self.popover.contentViewController?.view.window?.isKeyWindow == true {
                // Shift+Return → literal newline AT THE CURSOR via the field
                // editor (the action Option+Return triggers natively). Plain
                // Return stays the field's `.onSubmit` send. NOT `.onKeyPress`
                // — interception ahead of the macOS field editor is unreliable,
                // and the iOS `draft += "\n"` prior art appends at the END,
                // ignoring the cursor.
                if event.keyCode == 36, event.modifierFlags.contains(.shift) {
                    NSApp.sendAction(
                        #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)),
                        to: nil, from: nil
                    )
                    return nil
                }
                // ⌘V/⌘C/⌘X/⌘A hardening: key equivalents normally route through
                // `NSApp.mainMenu` even under `.accessory` (the menu exists,
                // it just isn't displayed) — but that dispatch isn't verifiable
                // headless, so map the standard edit keys explicitly. First-
                // responder targeted, popover-scoped, zero global footprint.
                if event.modifierFlags.contains(.command) {
                    switch event.charactersIgnoringModifiers {
                    case "v":
                        NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil)
                        return nil
                    case "c":
                        NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil)
                        return nil
                    case "x":
                        NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: nil)
                        return nil
                    case "a":
                        NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
                        return nil
                    default:
                        break
                    }
                }
            }
            return event
        }
    }

    private func removeEscMonitor() {
        if let escMonitor {
            NSEvent.removeMonitor(escMonitor)
            self.escMonitor = nil
        }
    }

    /// `NSPopoverDelegate` — tear down the Esc monitor whenever the popover
    /// closes (incl. a transient outside-click, not just `dismissPopover()`).
    /// Also the coordinator's close hook: an unconsumed explicit destination
    /// pick is one-shot and dies with an IDLE dismiss (the hook itself guards
    /// every mid-turn case, so a transient click-away during the agent wait
    /// never resets the destination).
    func popoverDidClose(_ notification: Notification) {
        removeEscMonitor()
        coordinator.popoverDidCloseHook()
        // The refusal notice belongs to the press that raised it.
        coordinator.clearQuickCaptureRefusalNotice()
        // Popover no longer showing any thread — nothing is being looked at, so
        // a reply that lands now leaves its thread unseen and the dot follows.
        coordinator.setPopoverVisibleConversation(nil)
        // Drop any read-only shared-reply override so the next open shows the
        // quick lane unless a fresh dot-click re-selects one.
        coordinator.clearPopoverOverride()
        // AUTHORITATIVE speech teardown — this delegate fires on EVERY close
        // path (Esc, outside click, programmatic), unlike the content view's
        // `.onDisappear`, which the retained hosting controller makes
        // unreliable. Targeted stops only (never a bus-wide `claim(nil)`,
        // which would kill a main-window speaker mid-utterance):
        //   - the popover view's own ThreadSpeaker (guarded on an active turn
        //     — a bare `stop()` would VoiceOver-announce "Stopped" on every
        //     idle close),
        //   - the shared arrival engine (the popover-closed hands-free voice),
        //   - any staged-but-unconsumed arrival speak (a reply landing in the
        //     close race must not ambush the next popover open).
        if coordinator.popoverSpeaker?.speakingMessageID != nil {
            coordinator.popoverSpeaker?.stop()
        }
        ReplyVoice.shared.cancel()
        AutoSpeakMailbox.shared.clear()
    }

    /// Esc = unconditional cancel-and-CLOSE, every mode/state (one press = out).
    /// Routes through the coordinator's universal teardown, which discards a live
    /// recording (audio dropped, no STT), an in-flight agent reply, a staged ⌘⇧2
    /// screenshot, the typed draft, an error surface, and any stranded-turn stash,
    /// then resets the destination latch — so nothing spills into the next
    /// ⌘⇧1/⌘⇧2 summon and the popover never lands on a stale screen. Mirrors the
    /// on-screen Cancel/Dismiss controls (same teardown). The IMPLICIT click-away
    /// dismiss stays gentle and PRESERVES compose state (see `popoverDidCloseHook`).
    /// Driven by the local key monitor (`installEscMonitor`), live only while the
    /// popover is open → popover-scoped.
    private func handleEscape() {
        coordinator.cancelActiveCapture()
        dismissPopover()
    }

    /// Routes to the unified main window (`Window("Conduck", id: "main")`).
    /// `selecting` non-nil additionally lands the window on that thread by
    /// re-posting the EXISTING reply-notification deep-link seam
    /// (`.openConversationDeepLink` + `NotificationDeepLink.conversationIDKey`):
    /// `MenuBarCoordinator`'s observer binds the WINDOW lane and
    /// `MainWindowView.handleDeepLink` syncs the sidebar selection — the same
    /// two consumers a notification tap drives, so no second hand-off path can
    /// drift. The window-was-closed race is covered by `MainWindowView.onAppear`
    /// seeding from the already-bound window lane.
    private func openConversationsWindow(selecting conversationID: UUID? = nil) {
        NSApp.activate(ignoringOtherApps: true)
        NotificationCenter.default.post(name: .openConversationsWindow, object: nil)
        if let conversationID {
            NotificationCenter.default.post(
                name: .openConversationDeepLink,
                object: nil,
                userInfo: [NotificationDeepLink.conversationIDKey: conversationID.uuidString]
            )
        }
    }

    // MARK: - State Observation
    //
    // Self-re-arming `withObservationTracking` over BOTH the capture state and
    // the VM's in-flight flag, so the 6th "replying" icon state tracks the
    // agent wait even though that flag lives on a different @Observable.

    private func observeStateChanges() {
        func observe() {
            withObservationTracking {
                _ = dictationService.state
                _ = coordinator.quickViewModel?.isAwaitingReply
                // Both derived from the stored rows, so this also picks up a
                // reply or a read that arrived from another device by CloudKit
                // rather than from anything that happened in this process.
                _ = coordinator.unreadReplyConversationIDs   // drive the unread dot
                _ = coordinator.failedConversationIDs        // drive the failure dot
            } onChange: {
                Task { @MainActor [weak self] in
                    self?.handleStateChange()
                    observe() // Re-register for next change
                }
            }
        }
        observe()
    }

    private var isAwaitingReply: Bool {
        coordinator.quickViewModel?.isAwaitingReply ?? false
    }

    private func handleStateChange() {
        updateIcon()

        // Defer popover ops to the next run-loop tick to avoid layout recursion
        // ("not legal to call -layoutSubtreeIfNeeded") — SwiftUI re-renders the
        // hosted view synchronously on the state change.
        DispatchQueue.main.async { [self] in
            updatePopoverBehavior()

            switch dictationService.state {
            case .idle:
                // Don't auto-dismiss while a reply is in flight — the user may
                // be watching the thinking indicator. They can click away
                // (transient) if they choose.
                // If a reply just settled into an ALREADY-OPEN popover, mark its
                // thread as viewed (keeps `popoverVisibleConversationID` current
                // as the quick lane rebinds, and clears any dot the reply-
                // arrived event raised in the same tick).
                if popover.isShown {
                    coordinator.setPopoverVisibleConversation(coordinator.displayedPopoverConversationID)
                }
            case .recording, .processing:
                if !popover.isShown { showPopover() }
            case .error:
                if !popover.isShown { showPopover() }
            }
        }
    }

    private func updateIcon() {
        guard let button = statusItem?.button else { return }

        switch dictationService.state {
        case .recording:
            button.image = NSImage(systemSymbolName: "record.circle.fill",
                                   accessibilityDescription: String(localized: "Recording"))
        case .processing:
            button.image = NSImage(systemSymbolName: "ellipsis.circle.fill",
                                   accessibilityDescription: String(localized: "Transcribing"))
        case .error:
            button.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill",
                                   accessibilityDescription: String(localized: "Error"))
        case .idle:
            if isAwaitingReply {
                // 6th state — agent reply in flight.
                button.image = NSImage(systemSymbolName: "sparkles",
                                       accessibilityDescription: String(localized: "Waiting for reply"))
            } else {
                applyIdleIcon(to: button)
            }
        }

        // Status dots: ONLY in the plain idle state (precedence
        // recording → processing → error → awaiting(sparkles) → dot-idle). The
        // dots are colored badge subviews, independent of the image swaps above,
        // so they survive them. Within the dot-idle state RED (send failed) takes
        // precedence over YELLOW (reply arrived) — a failure is more urgent — so
        // at most one is ever visible.
        let dotIdle = dictationService.state == .idle && !isAwaitingReply
        let showFailure = dotIdle && coordinator.hasFailure
        let showUnread = dotIdle && !showFailure && coordinator.hasUnreadReply
        updateFailureBadge(visible: showFailure, on: button)
        updateUnreadBadge(visible: showUnread, on: button)
    }

    private func updatePopoverBehavior() {
        switch dictationService.state {
        case .recording:
            // Lock the popover open during recording so an outside click can't
            // orphan the audio session.
            popover.behavior = .applicationDefined
        case .idle, .processing, .error:
            // Transient otherwise — incl. the agent wait, so the user can click
            // away; the in-flight Task survives on the long-lived VM.
            popover.behavior = .transient
        }
    }

    // MARK: - Idle Icon

    private func applyIdleIcon(to button: NSStatusBarButton) {
        let icon = NSImage(named: "menubar-conduck")
        icon?.size = NSSize(width: 18, height: 18)
        icon?.isTemplate = true
        button.image = icon
    }

    // MARK: - Unread reply dot

    /// Create the brand-colored unread dot ONCE and pin it to the status
    /// button's top-trailing corner via Auto Layout (robust across the button's
    /// system-driven resizing). Starts hidden. The dot rides ON TOP of the
    /// template image, so the duck glyph keeps its light/dark/click tinting.
    private func installUnreadBadge(on button: NSStatusBarButton) {
        guard unreadBadge == nil else { return }
        let size: CGFloat = 7
        let dot = NSView()
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.wantsLayer = true
        // AppColors.accent (Conduck yellow rgb 1.0, 0.757, 0.027) as NSColor.
        dot.layer?.backgroundColor = NSColor(srgbRed: 1.0, green: 0.757, blue: 0.027, alpha: 1.0).cgColor
        dot.layer?.cornerRadius = size / 2
        // A hairline ring OUTSIDE the fill, never a tint of it: at 7 pt on a
        // light menu bar the amber disc can wash into the background, and the
        // ring restores the edge without touching the brand colour. The failure
        // badge is a TRIANGLE, so the two are distinguishable with the colour
        // channel removed — shape, not colour.
        dot.layer?.borderWidth = 0.5
        dot.layer?.borderColor = NSColor.black.withAlphaComponent(0.35).cgColor
        dot.isHidden = true
        button.addSubview(dot)
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: size),
            dot.heightAnchor.constraint(equalToConstant: size),
            dot.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: -1),
            dot.topAnchor.constraint(equalTo: button.topAnchor, constant: 1),
        ])
        unreadBadge = dot
    }

    /// Toggle the unread dot (never recreate it). Updates the button's
    /// accessibility label and plays a single appear-pulse (skipped under
    /// Reduce Motion) the first time it becomes visible.
    private func updateUnreadBadge(visible: Bool, on button: NSStatusBarButton) {
        guard let badge = unreadBadge else { return }
        let wasHidden = badge.isHidden
        badge.isHidden = !visible
        if visible {
            button.setAccessibilityLabel(String(localized: LocalizedStringResource(
                "menubar.replyReady",
                defaultValue: "Reply ready"
            )))
            if wasHidden { pulseBadge(badge) }
        } else if failureBadge?.isHidden ?? true {
            // Only clear the shared label when the OTHER (failure) badge isn't
            // claiming it — `updateIcon` calls both toggles per tick, so an
            // unconditional clear here would wipe a visible failure dot's label.
            button.setAccessibilityLabel(nil)
        }
    }

    // MARK: - Send-failure dot

    /// Create the error-red failure MARK once, pinned to the SAME top-trailing
    /// corner as the unread dot (mutually exclusive — red wins, so they never
    /// co-render and can't overlap). Starts hidden; rides ON TOP of the template
    /// image so the duck glyph keeps its system tinting.
    ///
    /// A TRIANGLE, not a second dot: unread and failure previously differed by
    /// colour alone, which is unreadable to a colour-blind user and gone
    /// entirely in a greyscale screenshot. `exclamationmark.triangle.fill` is
    /// already this app's "error" glyph (the `.error` status-item image uses
    /// it), so the menu bar keeps one vocabulary.
    private func installFailureBadge(on button: NSStatusBarButton) {
        guard failureBadge == nil else { return }
        let size: CGFloat = 7
        let mark = NSImageView()
        mark.translatesAutoresizingMaskIntoConstraints = false
        mark.wantsLayer = true   // `pulseBadge` animates the layer
        mark.image = NSImage(
            systemSymbolName: "exclamationmark.triangle.fill",
            accessibilityDescription: nil
        )?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: size, weight: .bold))
        // AppColors.error (rgb 0.937, 0.325, 0.314) as NSColor. `contentTintColor`
        // recolours the template symbol without touching the duck beneath it.
        mark.contentTintColor = NSColor(srgbRed: 0.937, green: 0.325, blue: 0.314, alpha: 1.0)
        mark.imageScaling = .scaleProportionallyUpOrDown
        mark.isHidden = true
        button.addSubview(mark)
        NSLayoutConstraint.activate([
            mark.widthAnchor.constraint(equalToConstant: size),
            mark.heightAnchor.constraint(equalToConstant: size),
            mark.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: -1),
            mark.topAnchor.constraint(equalTo: button.topAnchor, constant: 1),
        ])
        failureBadge = mark
    }

    /// Toggle the failure dot (never recreate it). Updates the button's
    /// accessibility label and plays a single appear-pulse (skipped under
    /// Reduce Motion) the first time it becomes visible. Mirrors
    /// `updateUnreadBadge`; the `updateIcon` precedence guarantees only one of
    /// the two badges is visible at a time, so the accessibility label is never
    /// contested.
    private func updateFailureBadge(visible: Bool, on button: NSStatusBarButton) {
        guard let badge = failureBadge else { return }
        let wasHidden = badge.isHidden
        badge.isHidden = !visible
        if visible {
            button.setAccessibilityLabel(String(localized: LocalizedStringResource(
                "menubar.sendFailed",
                defaultValue: "Send failed"
            )))
            if wasHidden { pulseBadge(badge) }
        } else if unreadBadge?.isHidden ?? true {
            // Symmetric to `updateUnreadBadge`: only clear the shared label when
            // the OTHER (unread) badge isn't claiming it.
            button.setAccessibilityLabel(nil)
        }
    }

    /// One subtle scale pulse when the dot first appears. No looping; skipped
    /// under Reduce Motion.
    private func pulseBadge(_ badge: NSView) {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              let layer = badge.layer else { return }
        let pulse = CABasicAnimation(keyPath: "transform.scale")
        pulse.fromValue = 0.3
        pulse.toValue = 1.0
        pulse.duration = 0.28
        pulse.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(pulse, forKey: "appearPulse")
    }

    // MARK: - Context Menu

    private func showContextMenu() {
        let menu = NSMenu()

        // First item follows the input mode (the menu is rebuilt per click, so
        // a Settings change is live immediately): voice starts a capture, text
        // opens the popover with the compose field focused.
        let recordItem: NSMenuItem
        if coordinator.menuBarInputMode == .text {
            recordItem = NSMenuItem(
                title: String(localized: LocalizedStringResource(
                    "menu.typeMessage",
                    defaultValue: "Type a Message…"
                )),
                action: #selector(openPopoverForTyping),
                keyEquivalent: ""
            )
        } else {
            recordItem = NSMenuItem(
                // Keyed (not the bare "Start Recording" literal) — that casing
                // collides at symbol-gen with the existing "Start recording"
                // accessibility key (punctuation/casing collision).
                title: String(localized: LocalizedStringResource(
                    "menu.startRecording",
                    defaultValue: "Start Recording"
                )),
                action: #selector(startRecordingFromMenu),
                keyEquivalent: ""
            )
        }
        recordItem.target = self
        menu.addItem(recordItem)

        let screenshotAskItem = NSMenuItem(
            title: String(localized: LocalizedStringResource(
                "menu.screenshotAndAsk",
                defaultValue: "Screenshot & Ask…"
            )),
            action: #selector(screenshotAndAskFromMenu),
            // No responder-chain key-equivalent (mirrors `recordItem`): the global
            // ⌘⇧2 is owned by KeyboardShortcuts. A live menu key-equivalent could
            // double-fire while the context menu is key-tracking.
            keyEquivalent: ""
        )
        screenshotAskItem.target = self
        menu.addItem(screenshotAskItem)

        let conversationsItem = NSMenuItem(
            title: String(localized: LocalizedStringResource(
                "conversations.openConversations",
                defaultValue: "Open Conversations"
            )),
            action: #selector(openConversationsFromMenu),
            keyEquivalent: ""
        )
        conversationsItem.target = self
        menu.addItem(conversationsItem)

        menu.addItem(.separator())

        let loginItem = NSMenuItem(
            title: String(localized: "Launch at Login"),
            action: #selector(toggleLaunchAtLogin(_:)),
            keyEquivalent: ""
        )
        loginItem.target = self
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(loginItem)

        // "Show in Dock" — same source string as MacGeneralCategory (shared
        // xcstrings key, no collision). Checkmark reflects the current pref via
        // the synchronous launch-path read; toggling persists + applies live.
        let dockItem = NSMenuItem(
            title: String(localized: "Show in Dock"),
            action: #selector(toggleShowInDock(_:)),
            keyEquivalent: ""
        )
        dockItem.target = self
        dockItem.state = SettingsManager.showDockIconAtLaunch() ? .on : .off
        menu.addItem(dockItem)

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(
            // Keyed (not the bare "Settings..." literal) — collides at
            // symbol-gen with the existing "Settings" key.
            title: String(localized: LocalizedStringResource(
                "menu.settings",
                defaultValue: "Settings…"
            )),
            action: #selector(openSettings),
            keyEquivalent: ","
        )
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: String(localized: "Quit Conduck"),
            action: #selector(quitApp),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem?.menu = menu
        statusItem?.button?.performClick(nil)
        statusItem?.menu = nil
    }

    // MARK: - Menu Actions

    @objc private func startRecordingFromMenu() {
        // Defensive mode re-check (the item is mode-conditional, but the menu
        // could have been built a beat before a Settings change landed).
        guard coordinator.menuBarInputMode == .voice else {
            openPopoverForTyping()
            return
        }
        // The third door into the quick lane, gated like the other two.
        guard !coordinator.isQuickCaptureKnownUnavailable else {
            coordinator.noteQuickCaptureRefused()
            showPopover()
            return
        }
        // Same press-time destination freeze as the ⌘⇧1 hotkey — this is a
        // quick-capture start by another door; unarmed it would leave the
        // snapshot refreshable mid-recording (a TTL boundary could retarget
        // the send away from what the popover displayed).
        coordinator.armQuickCapture()
        showPopover()
        dictationService.toggleRecording()
    }

    /// Text input mode's context-menu primary action — open the popover; the
    /// compose surface focuses its field on appear. No arm, no recording (the
    /// same open path as the text-mode ⌘⇧1 branch).
    @objc private func openPopoverForTyping() {
        if !popover.isShown { showPopover() }
    }

    @objc private func screenshotAndAskFromMenu() {
        handleRegionCapturePress()
    }

    @objc private func openConversationsFromMenu() {
        openConversationsWindow()
    }

    @objc private func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            #if DEBUG
            print("Launch at Login toggle failed: \(error)")
            #endif
        }
    }

    @objc private func toggleShowInDock(_ sender: NSMenuItem) {
        // Mirror MacGeneralCategory.setShowDockIcon: persist (App-Group, posts
        // `.settingsDidChangeRemotely`) + apply live via the same AppDelegate path
        // the Settings toggle uses. Flip off the synchronous current value.
        let newValue = !SettingsManager.showDockIconAtLaunch()
        Task { await SettingsManager.shared.setShowDockIcon(newValue) }
        (NSApp.delegate as? AppDelegate)?.applyDockVisibility(newValue)
    }

    @objc private func openSettings() {
        // Settings is a `.sheet` on the unified main window now. Foreground +
        // open the main window, raise the deferred-present flag (covers the
        // window-was-closed case via MainWindowView.onAppear), and post the live
        // bus (covers the window-already-open case via its .onReceive).
        NSApp.activate(ignoringOtherApps: true)
        coordinator.pendingSettingsCategory = nil  // root Settings, not a deep-link
        coordinator.pendingDiagnosticsFocus = nil  // root open: never a diagnostics deep-link
        coordinator.pendingShowSettings = true
        NotificationCenter.default.post(name: .openConversationsWindow, object: nil)
        NotificationCenter.default.post(name: .openSettingsWindow, object: nil)
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}
#endif
