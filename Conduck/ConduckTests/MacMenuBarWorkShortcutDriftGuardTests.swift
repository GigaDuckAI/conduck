// SPDX-License-Identifier: Apache-2.0

// Conduck
// MacMenuBarWorkShortcutDriftGuardTests.swift
//
// SOURCE DRIFT GUARD over the macOS menu bar's Capture-to-Work lane (⌃⌘W).
//
// Six facts about that lane are load-bearing, invisible in a diff, and
// checkable by hand only on a signed Mac:
//
// (1) The shortcut EXISTS with its ⌃⌘W default. A `KeyboardShortcuts.Name`
//     whose default is dropped registers as unbound, and the feature then has
//     no discoverable entry at all — the founder's Mac would look exactly like
//     a working one until they pressed the keys.
// (2) `setup()` REGISTERS it. A declared-but-unregistered name is the same
//     silent nothing, one level further along.
// (3) The handler carries NO gateway machinery. `armQuickCapture()` latches the
//     quick CHAT lane's destination snapshot and
//     `isQuickCaptureKnownUnavailable` refuses a capture that no gateway can
//     deliver — both correct for an Ask, both wrong here: the desk is local, so
//     the guard would deny the one capture lane that still works when every
//     gateway is down, and the arm would bind a private note to a chat
//     destination. `handleQuickSend` is named too, because the plan's hard rule
//     is that nothing on the desk reaches a gateway, and a copy-paste from the
//     neighbouring handler is exactly how that rule breaks.
// (4) A live Work recording PINS the popover open and drives the status item.
//     The Work lane runs on its own recorder, so `dictationService.state` reads
//     `.idle` throughout: without the recorder in the tracked set and in the
//     behaviour branch, one click outside the popover would close it over a
//     live audio session.
// (5) Both the menu door and the Settings row exist, and the menu door routes
//     to the SAME handler as the hotkey — two entry points with two rule sets
//     is how a lane acquires a hole.
// (6) The press opens with the region overlay and nothing else. The overlay
//     covers the screen being photographed, so anything raised ahead of it is
//     in the shot; an Esc there abandons the press whole; the status item's
//     left-click is the only stop besides the hotkey (the HUD draws no button);
//     and the popover's Esc monitor, which sees every window's key-downs, must
//     leave the overlay's own Esc alone.
//
// Every file under test is `#if os(macOS)` and is never compiled by this suite,
// so each invariant is asserted where it is written, over comment-stripped
// source (`RefusalLaneSource`) — a header that DESCRIBES the rule can never
// stand in for the code that does it. A guard that fails because the shape
// legitimately changed is a guard to update, not a bug to route around.

import XCTest

final class MacMenuBarWorkShortcutDriftGuardTests: XCTestCase {

    private static let shortcutPath = "Conduck/MenuBar/GlobalShortcut.swift"
    private static let controllerPath = "Conduck/MenuBar/MenuBarController.swift"
    private static let coordinatorPath = "Conduck/MenuBar/MenuBarCoordinator.swift"
    private static let settingsPath = "Conduck/Views/Settings/MacGeneralCategory.swift"

    // MARK: - (1) The shortcut and its default

    func testTheWorkShortcutIsDeclaredWithItsControlCommandWDefault() throws {
        let source = try Self.squeezedSource(at: Self.shortcutPath)

        XCTAssertTrue(
            source.contains(Self.squeezed(
                #"static let captureToWork = Self("captureToWork", default: .init(.w, modifiers: [.control, .command]))"#
            )),
            "`captureToWork` no longer declares its ⌃⌘W default. A name declared without one registers "
            + "as unbound: the hotkey does nothing, the Settings recorder shows empty, and nothing about "
            + "the build looks broken."
        )
    }

    // MARK: - (2) Registration

    func testSetupRegistersTheWorkShortcutOnTheWorkHandler() throws {
        let body = try Self.controllerFunction("setup")

        XCTAssertTrue(
            body.contains(Self.squeezed("KeyboardShortcuts.onKeyUp(for: .captureToWork)")),
            "`setup()` no longer registers `.captureToWork`, so the declared shortcut is never wired to "
            + "anything and ⌃⌘W is silently inert."
        )
        XCTAssertTrue(
            body.contains("handleWorkCapturePress()"),
            "`setup()` no longer routes the Work shortcut to `handleWorkCapturePress()`; a Work press "
            + "reaching any other handler is a private capture entering the chat lane."
        )
    }

    // MARK: - (3) No gateway machinery on the Work lane

    func testTheWorkHandlerCarriesNoQuickCaptureGatewayMachinery() throws {
        let body = try Self.controllerFunction("handleWorkCapturePress")

        for forbidden in ["armQuickCapture", "isQuickCaptureKnownUnavailable", "handleQuickSend"] {
            XCTAssertFalse(
                body.contains(forbidden),
                "`handleWorkCapturePress` names `\(forbidden)`. The Work lane has no gateway and no "
                + "destination to latch: a readiness guard here refuses local captures for a remote "
                + "reason, an arm binds private words to the chat lane's snapshot, and a send is the "
                + "thing the desk exists not to do."
            )
        }
    }

    func testTheWorkHandlerStopsSavesAndBranchesOnInputMode() throws {
        let body = try Self.controllerFunction("handleWorkCapturePress")

        XCTAssertTrue(
            body.contains("coordinator.workCaptureIsActive"),
            "`handleWorkCapturePress` no longer asks whether a Work capture is live, so a second ⌃⌘W "
            + "starts a competing capture instead of stopping and saving the one in hand."
        )
        XCTAssertTrue(
            body.contains("finishWorkVoiceCapture()"),
            "The second press no longer finishes the capture — the recording has no other stop "
            + "affordance on this lane."
        )
        XCTAssertTrue(
            body.contains(Self.squeezed("coordinator.menuBarInputMode == .text")),
            "`handleWorkCapturePress` no longer branches on the input mode, so a text-mode user is "
            + "handed a microphone they deliberately turned off."
        )
        XCTAssertTrue(
            body.contains("openComposeForWorkOnly()"),
            "Text mode no longer opens the compose surface in its Work-ONLY state. The ordinary state's "
            + "Return sends to Chat, so this is the difference between saving a private note and "
            + "handing it to a gateway."
        )
        XCTAssertTrue(
            body.contains(Self.squeezed("beginWorkVoiceCapture(screenshot: screenshot)")),
            "Voice mode no longer starts the Work recorder WITH the region the overlay just took. A "
            + "start that dropped the argument would record the words and silently discard the "
            + "picture the person dragged for them."
        )
    }

    // MARK: - (6) The press opens with a screenshot, and the mouse can stop it

    /// The screenshot is the FIRST thing ⌃⌘W does, in both input modes.
    ///
    /// The overlay covers the very screen the person wants a picture of, so any
    /// surface raised ahead of it is in the shot; the start cue played ahead of
    /// it lands in the recording; and a microphone opened ahead of it records
    /// the seconds spent dragging.
    func testTheWorkPressTakesItsScreenshotBeforeItRaisesAnything() throws {
        let body = try Self.controllerFunction("handleWorkCapturePress")

        let capture = try XCTUnwrap(
            body.range(of: Self.squeezed("regionCapture.captureRegion(purpose: .work")),
            "`handleWorkCapturePress` no longer takes a region capture, so ⌃⌘W is a voice-only note "
            + "again: \(body.prefix(400))"
        )
        for later in [
            "coordinator.setPendingWorkCaptureImage(",
            "coordinator.openComposeForWorkOnly()",
            "coordinator.claimPopoverForWorkVoiceCapture()",
            "showPopover()",
            "CompletionFeedbackPlayer.play"
        ] {
            let raised = try XCTUnwrap(
                body.range(of: Self.squeezed(later)),
                "`handleWorkCapturePress` no longer names `\(later)`: \(body.prefix(400))"
            )
            XCTAssertLessThan(
                capture.lowerBound, raised.lowerBound,
                "`\(later)` runs AHEAD of the region capture: the overlay covers the screen being "
                + "photographed, so whatever this raises first is in the shot — and the start cue "
                + "played first lands inside the recording: \(body.prefix(400))"
            )
        }
    }

    /// Esc on the overlay abandons the whole press. Nothing may be staged,
    /// claimed, shown or started on the way out — one press in, one press out.
    /// `.unavailable` (a permission the person declined, Cancel chosen) leaves
    /// by the same door.
    func testACancelledRegionEndsTheWorkPressWithNothingStaged() throws {
        let body = try Self.controllerFunction("handleWorkCapturePress")

        let bail = try XCTUnwrap(
            body.range(of: Self.squeezed("case .cancelled, .unavailable: return")),
            "The ⌃⌘W press no longer bails outright on a cancelled or unavailable capture. Mapping "
            + "either one onto 'carry on without a picture' turns an Esc into a recording the person "
            + "did not ask for, and a declined permission into a silent success: \(body.prefix(400))"
        )
        for after in [
            "coordinator.setPendingWorkCaptureImage(",
            "coordinator.claimPopoverForWorkVoiceCapture()",
            "coordinator.beginWorkVoiceCapture(",
            "showPopover()",
            "CompletionFeedbackPlayer.play"
        ] {
            let step = try XCTUnwrap(
                body.range(of: Self.squeezed(after)),
                "`handleWorkCapturePress` no longer names `\(after)`: \(body.prefix(400))"
            )
            XCTAssertLessThan(
                bail.upperBound, step.lowerBound,
                "`\(after)` can be reached on the cancel path: \(body.prefix(400))"
            )
        }
    }

    /// A bail during the screenshot await ends the press.
    ///
    /// The overlay tears itself down before ScreenCaptureKit acquires the
    /// region, so the popover can take key again while the press is still
    /// suspended — and for that whole stretch the Work lane owns nothing: no
    /// recorder state, no claim, no flag. An Esc there would land, change
    /// nothing this handler looks at, and be answered seconds later by a
    /// microphone coming up behind the popover it had just closed. Only a
    /// generation reserved BEFORE the await and compared after it can see it.
    func testABailDuringTheScreenshotAwaitEndsTheWorkPress() throws {
        let body = try Self.controllerFunction("handleWorkCapturePress")

        let reserved = try XCTUnwrap(
            body.range(of: Self.squeezed(
                "let cancellationAtPress = coordinator.workCaptureCancellationGeneration"
            )),
            "The press no longer reserves a cancellation generation, so a bail pressed while the "
            + "screenshot is being acquired is invisible to it: \(body.prefix(500))"
        )
        let capture = try XCTUnwrap(
            body.range(of: Self.squeezed("regionCapture.captureRegion(")),
            "The region capture is gone; this guard's anchor needs updating."
        )
        let compared = try XCTUnwrap(
            body.range(of: Self.squeezed(
                "coordinator.workCaptureCancellationGeneration == cancellationAtPress"
            )),
            "The reserved generation is never compared, which makes reserving it decoration: "
            + "\(body.prefix(500))"
        )
        XCTAssertLessThan(
            reserved.upperBound, capture.lowerBound,
            "The generation has to be read BEFORE the await it protects, or it already carries the "
            + "cancellation it is supposed to detect: \(body.prefix(500))"
        )
        XCTAssertLessThan(
            capture.upperBound, compared.lowerBound,
            "…and compared AFTER it, which is where a bail can have landed: \(body.prefix(500))"
        )

        // The comparison has to gate everything the press would otherwise go on
        // to do — staging, claiming, summoning, the cue, the microphone.
        for step in [
            "coordinator.setPendingWorkCaptureImage(",
            "coordinator.openComposeForWorkOnly()",
            "coordinator.claimPopoverForWorkVoiceCapture()",
            "coordinator.beginWorkVoiceCapture(",
            "showPopover()",
            "CompletionFeedbackPlayer.play"
        ] {
            let later = try XCTUnwrap(
                body.range(of: Self.squeezed(step)),
                "`handleWorkCapturePress` no longer names `\(step)`: \(body.prefix(400))"
            )
            XCTAssertLessThan(
                compared.upperBound, later.lowerBound,
                "`\(step)` is reachable after a cancellation: \(body.prefix(500))"
            )
        }

        // …and the bail that moves the generation has to actually move it, on
        // every path, before anything it might otherwise return early from.
        let cancel = try Self.coordinatorFunction("cancelWorkVoiceCapture")
        XCTAssertTrue(
            cancel.contains(Self.squeezed("workCaptureCancellationGeneration &+= 1")),
            "The Work bail no longer moves the generation, so nothing a press can observe records "
            + "that the person got out: \(cancel.prefix(300))"
        )
    }

    /// One press, one flow.
    ///
    /// `coordinator.workCaptureIsActive` is false for the whole overlay — the
    /// lane is claimed only once the drag finishes — so a second ⌃⌘W pressed at
    /// the crosshair would read the lane as free and race the first press into
    /// it. The press therefore carries its own in-flight flag, which also means
    /// the answer does not depend on how the region controller happens to
    /// resolve a re-entrant call.
    func testASecondWorkPressDuringTheOverlayIsDropped() throws {
        let body = try Self.controllerFunction("handleWorkCapturePress")

        let drop = try XCTUnwrap(
            body.range(of: Self.squeezed("guard !workCapturePressInFlight else { return }")),
            "The press no longer refuses a second invocation while its own overlay is up: "
            + "\(body.prefix(400))"
        )
        let claimed = try XCTUnwrap(
            body.range(of: Self.squeezed("workCapturePressInFlight = true")),
            "…and nothing raises the flag it would refuse on: \(body.prefix(400))"
        )
        // `squeezed` removes ALL whitespace, so two adjacent statements leave no
        // gap between them: the guard's last character and the assignment's
        // first are the same index. `LessThanOrEqual` is therefore the strictest
        // form that can ever hold here, and it still refuses the shape this
        // guard exists to catch — an assignment ABOVE the read puts the guard's
        // upperBound past the assignment's lowerBound, not level with it.
        XCTAssertLessThanOrEqual(
            drop.upperBound, claimed.lowerBound,
            "The flag is raised before it is read, so every press refuses itself."
        )
        XCTAssertTrue(
            body.contains(Self.squeezed("defer { workCapturePressInFlight = false }")),
            "The flag is not released on EVERY exit. A cancelled capture that left it raised would "
            + "make ⌃⌘W inert for the rest of the session: \(body.prefix(400))"
        )

        // The flag may not outrank the stop. A second press while a capture is
        // actually running still has to finish it.
        let stop = try XCTUnwrap(
            body.range(of: "coordinator.workCaptureIsActive"),
            "The stop-on-second-press branch is gone; this guard's anchor needs updating."
        )
        XCTAssertLessThan(
            stop.lowerBound, drop.lowerBound,
            "The in-flight drop is asked BEFORE the stop, so ⌃⌘W can no longer end the recording it "
            + "started: \(body.prefix(400))"
        )
    }

    /// The mouse is the Work lane's only other stop.
    ///
    /// `statusBarButtonClicked` switches on `dictationService.state`, which reads
    /// `.idle` through an ENTIRE ⌃⌘W capture — and the Work HUD deliberately
    /// draws no "Stop and Save" button, so somebody who cleared the ⌃⌘W binding
    /// in Settings would otherwise have a live microphone and nothing to press.
    func testAStatusItemClickStopsALiveWorkRecording() throws {
        let body = try Self.controllerFunction("statusBarButtonClicked")

        let workArm = try XCTUnwrap(
            body.range(of: "coordinator.workCaptureIsActive"),
            "The click handler no longer resolves the Work lane at all, so a click during a ⌃⌘W "
            + "recording reads as a click on an idle app: \(body.prefix(400))"
        )
        let dictationArm = try XCTUnwrap(
            body.range(of: Self.squeezed("switch dictationService.state")),
            "The chat-lane switch is gone; this guard's ordering anchor needs updating."
        )
        XCTAssertLessThan(
            workArm.lowerBound, dictationArm.lowerBound,
            "The Work lane has to be asked FIRST. `dictationService.state` is `.idle` throughout a "
            + "Work capture, so a switch that ran first would answer for the wrong lane every time: "
            + "\(body.prefix(400))"
        )
        XCTAssertTrue(
            body.contains("workRecordingIsLive"),
            "The stop is no longer scoped to a LIVE recording, so a click during the start or the "
            + "transcription would try to finish a capture that has nothing to finish."
        )
        XCTAssertTrue(
            body.contains(Self.squeezed("await coordinator.finishWorkVoiceCapture()")),
            "A left-click on a live Work recording no longer stops and saves it: \(body.prefix(400))"
        )

        let arm = String(body[workArm.lowerBound..<dictationArm.lowerBound])
        for forbidden in ["beginWorkVoiceCapture", "captureRegion", "handleWorkCapturePress"] {
            XCTAssertFalse(
                arm.contains(forbidden),
                "A click during a Work start or its transcription names `\(forbidden)` — it would "
                + "launch a SECOND capture, which loses the microphone lease to the first and strands "
                + "the refusal behind the HUD that hid it: \(arm.prefix(400))"
            )
        }
    }

    /// Whichever lane holds the MICROPHONE is the one a click must stop.
    ///
    /// The two lanes are mutually exclusive at the microphone, not at the
    /// surface. A Work FAILURE holds the HUD open while owning no microphone at
    /// all, and ⌘⇧1 is deliberately gated on the live Work mic rather than on
    /// the HUD — so an Ask really can be recording underneath a standing Work
    /// error. A Work arm that claimed every click on `workCaptureIsActive` alone
    /// would swallow the only mouse stop that recording has.
    func testALiveChatRecordingOutranksANonRecordingWorkState() throws {
        let body = try Self.controllerFunction("statusBarButtonClicked")

        XCTAssertTrue(
            body.contains(Self.squeezed(
                "if coordinator.workCaptureIsActive, dictationService.state != .recording {"
            )),
            "The Work arm claims the click on `workCaptureIsActive` alone. With a terminal Work error "
            + "standing, ⌘⇧1 starts an Ask (its gate reads the live Work microphone, not the HUD) — "
            + "and the click that should stop it is consumed by a lane holding no microphone: "
            + "\(body.prefix(500))"
        )

        // Both routes the qualifier must leave intact.
        XCTAssertTrue(
            body.contains(Self.squeezed("await coordinator.finishWorkVoiceCapture()")),
            "A live WORK recording no longer stops on a click. The lanes never hold the microphone "
            + "at once, so a live Work recording reads `dictationService.state == .idle` and must "
            + "still reach this route: \(body.prefix(500))"
        )
        XCTAssertTrue(
            body.contains("isSecondaryClick()"),
            "The secondary-click route is gone from the Work arm: \(body.prefix(500))"
        )
    }

    /// Esc belongs to the window it was typed into.
    ///
    /// A local monitor sees key-downs dispatched to EVERY window of this app, so
    /// the popover's Esc monitor also sees the one the region-capture overlay is
    /// waiting for — and that overlay takes key while a popover can still be
    /// open behind it. An unconditional consume there means ⌃⌘W and ⌘⇧2 both
    /// lose their cancel, with the popover closing instead of the crosshair.
    func testTheEscMonitorLeavesAnotherWindowsEscAlone() throws {
        let body = try Self.controllerFunction("installEscMonitor")

        let escape = try XCTUnwrap(
            body.range(of: Self.squeezed("if event.keyCode == 53 {")),
            "The Esc arm is gone from the monitor; this guard's anchor needs updating."
        )
        let scope = try XCTUnwrap(
            body.range(of: "event.window", range: escape.upperBound..<body.endIndex),
            "The Esc arm no longer asks which window the key was typed into, so it swallows the "
            + "overlay's cancel: \(body.prefix(500))"
        )
        let teardown = try XCTUnwrap(
            body.range(of: "self.handleEscape()", range: escape.upperBound..<body.endIndex),
            "The Esc arm no longer tears the capture down; this guard's anchor needs updating."
        )
        XCTAssertLessThan(
            scope.upperBound, teardown.lowerBound,
            "The window check has to GATE the teardown, not trail it: \(body.prefix(500))"
        )
        XCTAssertTrue(
            body[escape.upperBound..<teardown.lowerBound].contains(Self.squeezed("return event")),
            "A key-down from another window has to be PASSED ON. Returning nil there consumes it "
            + "anyway, which is the whole bug: \(body.prefix(500))"
        )
    }

    // MARK: - (4) A live Work recording owns the popover and the icon

    func testTheWorkRecorderIsInTheObservedStateSet() throws {
        let body = try Self.controllerFunction("observe")

        XCTAssertTrue(
            body.contains("coordinator.workVoiceRecorder.state"),
            "The observation set no longer tracks the Work recorder. `dictationService.state` stays "
            + "`.idle` through a Work capture, so nothing would re-evaluate the popover behaviour or "
            + "the status item while the microphone is live."
        )
    }

    func testALiveWorkRecordingPinsThePopoverOpen() throws {
        let body = try Self.controllerFunction("updatePopoverBehavior")

        let pin = try XCTUnwrap(
            body.range(of: "workRecordingIsLive")?.lowerBound,
            "`updatePopoverBehavior` no longer consults the Work recorder, so a click outside the "
            + "popover during a Work recording dismisses it and orphans the audio session."
        )
        let applicationDefined = try XCTUnwrap(
            body.range(of: ".applicationDefined", range: pin..<body.endIndex)?.lowerBound,
            "The Work branch no longer resolves to `.applicationDefined` — the pin is what keeps a "
            + "click-away from ending a recording the desk has already promised to keep."
        )
        XCTAssertLessThan(pin, applicationDefined)
    }

    func testABusyWorkRecorderDrivesTheStatusItem() throws {
        let body = try Self.controllerFunction("updateIcon")

        XCTAssertTrue(
            body.contains("workCaptureIsBusy"),
            "`updateIcon` no longer resolves the Work lane, so the menu bar shows the idle duck while "
            + "the microphone is live — the only ambient signal that a capture is running."
        )
    }

    /// Every ASK door refuses while the Work microphone is live. Without the
    /// gate the chat lane takes the lease refusal into `.error`, the Work HUD
    /// hides it, and it surfaces stale the moment the Work capture ends.
    func testEveryAskEntryPointStandsDownWhileTheWorkMicrophoneIsLive() throws {
        for door in ["handleShortcutPress", "handleRegionCapturePress", "startRecordingFromMenu"] {
            let body = try Self.controllerFunction(door)
            XCTAssertTrue(
                body.contains("workRecordingIsLive"),
                "`\(door)` no longer stands down for a live Work recording. The press cannot start a "
                + "capture (the microphone lease refuses it), so all it can do is strand a "
                + "'microphone is in use' error behind the Work HUD, to appear after the conflict is over."
            )
        }
    }

    /// A thread reported as VISIBLE is acknowledged as read and has its arrival
    /// banner suppressed. The Work HUD is the whole popover, so a reply landing
    /// behind it was never seen: neither the summon that opens onto a running
    /// capture nor the settled-state callback may report one while Work owns the
    /// surface — and the same callback is what restores it afterwards.
    func testNoThreadIsReportedVisibleWhileTheWorkHUDOwnsThePopover() throws {
        let summon = try Self.controllerFunction("showPopover")
        XCTAssertTrue(
            summon.contains(Self.squeezed(
                "if dictationService.state == .idle, !coordinator.workCaptureIsActive {"
            )),
            "`showPopover` reports the quick thread as visible even when a Work capture owns the "
            + "popover. The reply that lands behind the HUD is then marked read and loses its banner, "
            + "having never been on screen."
        )

        let settled = try Self.controllerFunction("handleStateChange")
        XCTAssertTrue(
            settled.contains(Self.squeezed(
                "if popover.isShown, !coordinator.workCaptureIsActive {"
            )),
            "The settled-state callback no longer stands down for a Work capture — and it is also the "
            + "path that RESTORES visibility once the capture releases the surface."
        )
    }

    // MARK: - (5) The menu door and the Settings row

    func testTheContextMenuOffersCaptureToWorkRightAfterScreenshotAndAsk() throws {
        let body = try Self.controllerFunction("showContextMenu")

        let screenshot = try XCTUnwrap(
            body.range(of: "menu.screenshotAndAsk")?.lowerBound,
            "The Screenshot & Ask item is gone; this guard's ordering anchor needs updating."
        )
        let work = try XCTUnwrap(
            body.range(of: "menu.captureToWork"),
            "The context menu no longer offers the Work capture item, leaving ⌃⌘W with no discoverable "
            + "counterpart for a user who never opens Settings."
        )
        let conversations = try XCTUnwrap(
            body.range(of: "conversations.openConversations"),
            "The Open Conversations item is gone; this guard's ordering anchor needs updating."
        )
        XCTAssertLessThan(screenshot, work.lowerBound,
                          "The Work item must follow the capture items, not lead them.")
        XCTAssertLessThan(work.lowerBound, conversations.lowerBound,
                          "The Work item belongs with the CAPTURE group, above the navigation items — "
                          + "a capture action stranded among 'Open …' rows reads as a browse.")

        // The rule that ENDS the capture group. Three verbs that start something
        // and two rows that merely open a window are two different kinds of
        // command; run together as five undifferentiated rows, the capture reads
        // as one more place to browse to.
        XCTAssertNotNil(
            body.range(of: Self.squeezed("menu.addItem(.separator())"),
                       range: work.upperBound..<conversations.lowerBound),
            "No separator between the Work capture item and the 'Open …' rows."
        )

        // The retired keys, checked as quoted literals: `menu.openWorkDesk`
        // contains `menu.openWork`, so a bare substring check would pass on the
        // very row it is supposed to catch.
        for retired in ["\"menu.recordToWork\"", "\"menu.openWork\""] {
            XCTAssertFalse(
                body.contains(retired),
                "\(retired) is still referenced. Reworded copy takes a NEW key (spec.md:552) — a "
                + "reused key ships every existing translation of the OLD sentence against the new "
                + "English one."
            )
        }
        XCTAssertTrue(
            body.contains("\"menu.openWorkDesk\""),
            "The Open Work row no longer carries its own key."
        )
        XCTAssertFalse(
            body.contains(Self.squeezed("defaultValue: \"Open Work…\"")),
            "\"Open Work\" carries an ellipsis again. The ellipsis promises the command will ask for "
            + "something first (HIG); this one raises the desk directly."
        )

        XCTAssertTrue(
            body.contains(Self.squeezed("action: #selector(captureToWorkFromMenu)")),
            "The Work menu item no longer targets `captureToWorkFromMenu`."
        )

        let action = try Self.controllerFunction("captureToWorkFromMenu")
        XCTAssertTrue(
            action.contains("handleWorkCapturePress()"),
            "The menu door no longer runs the hotkey's handler. Two entry points with two rule sets is "
            + "how one of them quietly loses the stop-on-second-press or the text-mode branch."
        )
    }

    func testTheSettingsShortcutSectionCanRemapTheWorkShortcut() throws {
        let source = try Self.squeezedSource(at: Self.settingsPath)

        XCTAssertTrue(
            source.contains(Self.squeezed("KeyboardShortcuts.Recorder(for: .captureToWork)")),
            "Settings → General no longer offers a recorder for `.captureToWork`, so a user whose ⌃⌘W "
            + "is taken by another app has no way to move it — and a shortcut that never fires is "
            + "indistinguishable from a feature that does not exist."
        )
        XCTAssertTrue(
            source.contains("settings.mac.general.shortcut.captureToWork.label"),
            "The Work recorder row lost its own label key, so the row cannot be relabelled in the "
            + "catalog without touching code."
        )
    }

    // MARK: - Control

    /// The squeeze is what makes the assertions above indifferent to line
    /// breaking, and comment stripping is what stops a file's PROSE about a rule
    /// from satisfying a check on the code that implements it. Both are asserted
    /// here, or every `contains` in this suite is a claim about nothing.
    func testTheSqueezeIgnoresFormattingAndCommentsCannotSatisfyAGuard() throws {
        let wrapped = Self.squeezed("""
        KeyboardShortcuts.onKeyUp(
            for: .captureToWork
        ) { }
        """)
        XCTAssertTrue(wrapped.contains(Self.squeezed("KeyboardShortcuts.onKeyUp(for: .captureToWork)")),
                      "Control: a wrapped registration must read the same as a one-line one.")

        let prose = Self.squeezed("""
        // We register .captureToWork and never call armQuickCapture here.
        let x = 1
        """)
        XCTAssertFalse(prose.contains("captureToWork"),
                       "Control: a comment describing the rule must not satisfy a check on the code.")
        XCTAssertFalse(prose.contains("armQuickCapture"),
                       "Control: a comment naming a forbidden call must not FAIL a check either — a "
                       + "guard that trips on prose gets deleted by the next person who reads it.")
    }

    /// The pin has to cover the START, not only the live recording.
    ///
    /// The microphone can take seconds to come up — a permission prompt, the
    /// speech preflight — and `workVoiceRecorder.state` reads `.idle` for every
    /// bit of it. A pin scoped to `.recording` therefore leaves the popover
    /// `.transient` across exactly the window in which there is nothing on
    /// screen to justify it yet: one click outside, and the recording begins
    /// behind a closed popover with no surface anywhere to stop it.
    func testTheWorkVoiceStartPinsThePopoverBeforeTheRecordingIsLive() throws {
        let behavior = try Self.controllerFunction("updatePopoverBehavior")
        let pin = try XCTUnwrap(
            behavior.range(of: "coordinator.workVoiceStartIsInFlight")?.lowerBound,
            "`updatePopoverBehavior` pins only the LIVE recording, so a click-away during the start "
            + "closes the popover and the microphone comes up behind it."
        )
        let applicationDefined = try XCTUnwrap(
            behavior.range(of: ".applicationDefined", range: pin..<behavior.endIndex)?.lowerBound,
            "The start no longer resolves to `.applicationDefined`."
        )
        XCTAssertLessThan(pin, applicationDefined)

        let observed = try Self.controllerFunction("observe")
        XCTAssertTrue(
            observed.contains("coordinator.workVoiceStartIsInFlight"),
            "The observation set no longer tracks the claim, so nothing re-evaluates the popover "
            + "behaviour when the start begins — or, worse, when it ends and the pin must be released."
        )

        let press = try Self.controllerFunction("handleWorkCapturePress")
        guard let claim = press.range(of: "coordinator.claimPopoverForWorkVoiceCapture()"),
              let applied = press.range(of: "updatePopoverBehavior()") else {
            return XCTFail("The ⌃⌘W press no longer pins the popover as it claims it: \(press.prefix(400))")
        }
        XCTAssertTrue(
            claim.upperBound <= applied.lowerBound,
            "The pin is applied from the press itself rather than waiting for an observation tick: "
            + "\(press.prefix(400))"
        )
        XCTAssertTrue(
            press[applied.upperBound...].contains("showPopover()"),
            "…and before the summon it protects: \(press.prefix(400))"
        )
    }

    // MARK: - Source access

    /// Comment-stripped and whitespace-free, so indentation and line breaks
    /// cannot change what the code says.
    private static func squeezed(_ source: String) -> String {
        RefusalLaneSource.stripComments(source).filter { !$0.isWhitespace }
    }

    private static func squeezedSource(at relativePath: String) throws -> String {
        squeezed(try RefusalLaneSource.rawSource(at: relativePath))
    }

    /// One function's body from `MenuBarController`, squeezed. Scoping to a
    /// single function is what keeps an assertion from being satisfied by an
    /// unrelated statement elsewhere in a 1,000-line controller — especially the
    /// forbidden-call checks, whose whole meaning is "not in THIS handler".
    private static func controllerFunction(_ name: String) throws -> String {
        let source = try RefusalLaneSource.source(at: controllerPath)
        return squeezed(try RefusalLaneSource.body(ofFunction: name, in: source, path: controllerPath))
    }

    /// The controller's sibling: some of the rules the ⌃⌘W press relies on are
    /// enforced on the other side of the call, and a guard that only read this
    /// file would pass while the thing it depends on was deleted.
    private static func coordinatorFunction(_ name: String) throws -> String {
        let source = try RefusalLaneSource.source(at: coordinatorPath)
        return squeezed(try RefusalLaneSource.body(ofFunction: name, in: source, path: coordinatorPath))
    }
}
