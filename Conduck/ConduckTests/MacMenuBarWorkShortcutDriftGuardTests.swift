// SPDX-License-Identifier: Apache-2.0

// Conduck
// MacMenuBarWorkShortcutDriftGuardTests.swift
//
// SOURCE DRIFT GUARD over the macOS menu bar's Capture-to-Work lane (⌃⌘W).
//
// Five facts about that lane are load-bearing, invisible in a diff, and
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
            body.contains("beginWorkVoiceCapture()"),
            "Voice mode no longer starts the Work recorder."
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

    func testTheContextMenuOffersRecordToWorkRightAfterScreenshotAndAsk() throws {
        let body = try Self.controllerFunction("showContextMenu")

        let screenshot = try XCTUnwrap(
            body.range(of: "menu.screenshotAndAsk")?.lowerBound,
            "The Screenshot & Ask item is gone; this guard's ordering anchor needs updating."
        )
        let work = try XCTUnwrap(
            body.range(of: "menu.recordToWork")?.lowerBound,
            "The context menu no longer offers the Work capture item, leaving ⌃⌘W with no discoverable "
            + "counterpart for a user who never opens Settings."
        )
        let conversations = try XCTUnwrap(
            body.range(of: "conversations.openConversations")?.lowerBound,
            "The Open Conversations item is gone; this guard's ordering anchor needs updating."
        )
        XCTAssertLessThan(screenshot, work, "The Work item must follow the capture items, not lead them.")
        XCTAssertLessThan(work, conversations,
                          "The Work item belongs with the CAPTURE group, above the navigation items — "
                          + "a capture action stranded among 'Open …' rows reads as a browse.")

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
}
