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
    private static let popoverPath = "Conduck/MenuBar/DictationPopoverView.swift"
    private static let settingsPath = "Conduck/Views/Settings/MacGeneralCategory.swift"
    private static let appDelegatePath = "Conduck/AppDelegate.swift"
    private static let recorderPath = "Conduck/Services/InAppAudioRecorder.swift"

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
        // EACH SHORTCUT IS PINNED TO ITS OWN CLOSURE. Asserting that both names
        // appear SOMEWHERE in `setup()` is satisfied by the two handlers being
        // swapped — ⌃⌘W would start an Ask capture that can reach a gateway, and
        // ⌘⇧1 would open the desk, with every string still present. So the
        // registration is read one closure at a time.
        let registrations: [(shortcut: String, handler: String)] = [
            (".captureToWork", "handleWorkCapturePress()"),
            (".toggleVoiceCapture", "handleShortcutPress()"),
            (".captureRegionAndVoice", "handleRegionCapturePress()"),
        ]
        for (shortcut, handler) in registrations {
            let closure = Self.squeezed(try RefusalLaneSource.trailingClosure(
                after: "KeyboardShortcuts.onKeyUp(for: \(shortcut))",
                in: try RefusalLaneSource.source(at: Self.controllerPath),
                path: Self.controllerPath
            ))
            XCTAssertTrue(
                closure.contains(Self.squeezed(handler)),
                "`\(shortcut)` no longer calls `\(handler)`. A shortcut wired to another lane's "
                + "handler is a private capture entering the chat lane, or the reverse: \(closure)"
            )
            for other in registrations where other.handler != handler {
                XCTAssertFalse(
                    closure.contains(Self.squeezed(other.handler)),
                    "`\(shortcut)`'s closure also calls `\(other.handler)`: one press, one flow."
                )
            }
        }
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

        // THE POST-OVERLAY GUARD ASKS ABOUT THE MICROPHONE ONLY IN VOICE MODE,
        // exactly as the pre-overlay stand-down does. A typed note needs no
        // microphone, so a live Ask recording is no reason to refuse one — and
        // refusing it HERE happens AFTER the drag, discarding a completed region
        // with no explanation at all. The Work-lane conditions stay
        // unconditional: two Work captures at once is still one too many.
        XCTAssertTrue(
            body.contains(Self.squeezed("textMode || dictationService.state != .recording")),
            "The post-overlay guard refuses a text-mode Work capture because the Ask microphone is "
            + "live, silently dropping the region the person just dragged: \(body.prefix(900))"
        )
        for laneCondition in ["!coordinator.workCaptureIsActive", "!workRecordingIsLive"] {
            XCTAssertTrue(
                body.contains(Self.squeezed(laneCondition)),
                "The post-overlay guard no longer refuses a second WORK capture (`\(laneCondition)`), "
                + "which text mode must not be exempt from: \(body.prefix(900))"
            )
        }

        // NEGATIVE CONTROL: the unconditional microphone condition this
        // replaced. It reads identically in both modes, which is the defect.
        let unconditional = Self.squeezed("""
        guard coordinator.workCaptureCancellationGeneration == cancellationAtPress,
              !coordinator.workCaptureIsActive,
              !workRecordingIsLive,
              dictationService.state != .recording else { return }
        """)
        XCTAssertFalse(
            unconditional.contains(Self.squeezed("textMode || dictationService.state != .recording")),
            "Control: a guard that asks about the microphone in text mode too must FAIL this check."
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
        // every path, before anything it might otherwise return early from. It
        // lives in its own method because the generation has to move on bails
        // that leave the Work RECORDER alone — see the Ask-microphone rule
        // below.
        let bail = try Self.coordinatorFunction("bailWorkCapturePress")
        XCTAssertTrue(
            bail.contains(Self.squeezed("workCaptureCancellationGeneration &+= 1")),
            "The Work bail no longer moves the generation, so nothing a press can observe records "
            + "that the person got out: \(bail.prefix(300))"
        )
        let cancel = try Self.coordinatorFunction("cancelWorkVoiceCapture")
        let bumped = try XCTUnwrap(
            cancel.range(of: "bailWorkCapturePress()"),
            "The Work teardown no longer invalidates the press in flight: \(cancel.prefix(300))"
        )
        XCTAssertEqual(
            bumped.lowerBound, cancel.startIndex,
            "The bump has to be the FIRST statement of the teardown — every branch below it is a "
            + "no-op for a press that is still acquiring its screenshot: \(cancel.prefix(300))"
        )
    }

    /// A bail takes what is ON SCREEN, resolved ONCE, and the press generation
    /// moves either way.
    ///
    /// The popover draws one thing at a time in a fixed order, so no single
    /// flag answers "what was the person looking at": the Work HUD covers a
    /// transcribing Ask, an Ask RECORDING covers the Work HUD, and the working
    /// view covers both compositions. Reading only the microphone got the
    /// recording case right and the `.processing` case wrong in BOTH directions
    /// — an Esc during transcription erased a hidden Work draft, and an Esc on
    /// the returned Work HUD invalidated a hidden Ask transcription that the
    /// HUD's own ✕ leaves alone.
    ///
    /// So the surface is resolved once, into `visibleBailOwner`, and that one
    /// answer routes the whole teardown. The PRESS generation still moves
    /// unconditionally: the Ask cancel frees the microphone synchronously, and a
    /// ⌃⌘W suspended in its screenshot await would otherwise sail through the
    /// post-await guard and bring a microphone up after the Esc.
    ///
    /// A source guard because `DictationService.state` is `private(set)` — the
    /// unsigned test host has no way to drive it to `.recording`.
    func testABailTakesOnlyTheSurfaceThatIsShowing() throws {
        let body = try Self.coordinatorFunction("cancelActiveCapture")

        // (1) ONE reading, and it is the first thing that happens.
        let read = try XCTUnwrap(
            body.range(of: Self.squeezed("let owner = visibleBailOwner")),
            "The bail no longer resolves the visible surface: \(body.prefix(600))"
        )
        XCTAssertEqual(
            read.lowerBound, body.startIndex,
            "The screen is read after something has already changed it — `cancelRecording()` sets "
            + "the state `.idle` synchronously, so every later question answers about the teardown "
            + "rather than about the surface: \(body.prefix(600))"
        )
        XCTAssertEqual(
            body.components(separatedBy: Self.squeezed("visibleBailOwner")).count - 1, 1,
            "The owner is resolved more than once, so two halves of one teardown can disagree about "
            + "which surface the press belonged to: \(body.prefix(600))"
        )

        // (2) The generation bump is unconditional and sits ABOVE every arm.
        let bump = try XCTUnwrap(
            body.range(of: Self.squeezed("bailWorkCapturePress()")),
            "The press generation no longer moves on a bail, so a ⌃⌘W suspended in its screenshot "
            + "await records after the Esc: \(body.prefix(600))"
        )
        XCTAssertEqual(
            body.components(separatedBy: Self.squeezed("bailWorkCapturePress()")).count - 1, 1,
            "The bump is written twice, so one of them can be deleted with no test failing."
        )

        // (3) Esc over the Work HUD IS the ✕: it takes the Work capture and
        //     returns, so the Ask transcription suspended underneath — which is
        //     not on screen, and whose words come back to a surface of their
        //     own — is left exactly as the ✕ leaves it.
        let workArm = Self.squeezed("""
        if owner == .workCapture {
            cancelWorkVoiceCapture()
            return
        }
        """)
        XCTAssertTrue(
            body.contains(workArm),
            "The Work-HUD arm is no longer one shape that ENDS the teardown. Falling through reaches "
            + "`dictationService.cancelRecording()`, which now answers for `.processing` too — so an "
            + "Esc on the Work HUD invalidates a hidden Ask transcription that the HUD's own ✕ does "
            + "not touch: \(body.prefix(700))"
        )
        let askCancel = try XCTUnwrap(
            body.range(of: Self.squeezed("dictationService.cancelRecording()")),
            "The Ask cancel is gone; this guard's ordering anchor needs updating."
        )
        XCTAssertLessThan(
            bump.upperBound, askCancel.lowerBound,
            "The bump sits below the Ask cancel: \(body.prefix(600))"
        )
        let workRange = try XCTUnwrap(body.range(of: workArm))
        XCTAssertLessThan(
            workRange.upperBound, askCancel.lowerBound,
            "The Work arm no longer precedes the Ask teardown, so the early return cannot protect "
            + "anything: \(body.prefix(700))"
        )

        // (4) The COMPOSITION teardown answers the same question, and it is the
        //     ONLY place a composition is discarded. A parked Work draft (typed
        //     but never saved, its dragged region in the Work slot) and a chat
        //     draft under a transcription are the same case: while EITHER
        //     capture is drawn, no composition is on screen at all.
        let compositionArm = Self.squeezed("""
        if owner == .composition {
            switch compose.target {
            case .work: discardWorkOnlyCompose()
            case .chat:
                quickDraft = ""
                discardStalledWorkSave(aimedAt: .chat)
            }
        }
        """)
        XCTAssertTrue(
            body.contains(compositionArm),
            "The composition teardown is no longer gated on the surface being SHOWN, so a bail "
            + "raised over a capture erases a composition the person cannot see and that exists "
            + "nowhere else: \(body.prefix(700))"
        )
        // …and it is the only discard in the function. A second, unconditional
        // call beside it satisfies every presence check above while doing
        // exactly the damage the gate exists to stop.
        XCTAssertEqual(
            body.components(separatedBy: Self.squeezed("discardWorkOnlyCompose()")).count - 1, 1,
            "The Work composition is discarded from more than one place in this teardown. One of "
            + "them is ungated, which restores the defect whole: \(body.prefix(700))"
        )
        XCTAssertEqual(
            body.components(separatedBy: Self.squeezed("quickDraft = \"\"")).count - 1, 1,
            "The chat draft is cleared from more than one place, which is the same hole read the "
            + "other way: \(body.prefix(700))"
        )

        // NEGATIVE CONTROL (a): the aim-only shape this replaced.
        let aimOnly = Self.squeezed("""
        if compose.target == .work {
            discardWorkOnlyCompose()
        } else {
            quickDraft = ""
        }
        """)
        XCTAssertFalse(
            aimOnly.contains(compositionArm),
            "Control: a teardown that reads the stored aim alone must FAIL this guard — the aim says "
            + "`.work` while the surface is showing an Ask capture."
        )

        // NEGATIVE CONTROL (b): the microphone-only shape, which is the exact
        // half-fix the verifier reopened. It gets `.recording` right and
        // `.processing` wrong, in both directions.
        let microphoneOnly = Self.squeezed("""
        let askMicrophoneIsLive = dictationService.state == .recording
        dictationService.cancelRecording()
        bailWorkCapturePress()
        if !askMicrophoneIsLive { cancelWorkVoiceCapture() }
        if compose.target == .work, !askMicrophoneIsLive { discardWorkOnlyCompose() }
        """)
        XCTAssertFalse(
            microphoneOnly.contains(compositionArm),
            "Control: reading the microphone instead of the surface must FAIL this guard."
        )
        XCTAssertFalse(
            microphoneOnly.contains(workArm),
            "Control: …and it never ends the teardown, so the Ask cancel runs under the Work HUD."
        )

        // NEGATIVE CONTROL (c): the mutation the shape checks alone would take —
        // the gated discard kept, an unconditional one added beside it.
        let doubled = compositionArm + Self.squeezed("discardWorkOnlyCompose()")
        XCTAssertTrue(
            doubled.contains(compositionArm),
            "Control: the doubled shape keeps the arm every presence check looks for, which is why "
            + "the count assertion above is the one that catches it."
        )
        XCTAssertEqual(
            doubled.components(separatedBy: Self.squeezed("discardWorkOnlyCompose()")).count - 1, 2,
            "Control: …and it is caught by COUNT."
        )
    }

    /// The owner the teardown reads is the popover's own render order, written
    /// once. Two rules live here, and both were defects before:
    ///
    /// - the Work HUD wins whenever the Ask microphone is not RECORDING, which
    ///   is what makes an Esc on the returned Work HUD leave a hidden Ask
    ///   transcription alone;
    /// - `.processing` is an Ask SURFACE, which is what stops an Esc during
    ///   transcription from erasing a hidden Work draft.
    func testTheVisibleOwnerMirrorsThePopoversRenderOrder() throws {
        let coordinator = try Self.squeezedSource(at: Self.coordinatorPath)
        let owner = Self.squeezed("""
        if workCaptureIsActive, dictationService.state != .recording { return .workCapture }
        if dictationService.state == .recording { return .askCapture }
        if dictationService.state == .processing { return .askCapture }
        if turnStarting { return .askCapture }
        if quickViewModel?.isAwaitingReply == true { return .askCapture }
        return .composition
        """)
        XCTAssertTrue(
            coordinator.contains(owner),
            "`visibleBailOwner` no longer answers with the popover's render order. Every arm here is "
            + "a surface that covers the ones below it, and a missing one is a press that stops "
            + "something the person cannot see."
        )

        // The mirror is only true if the popover still renders that way. This is
        // the anchor: the Work arm's own condition, in the view.
        let popover = try Self.squeezedSource(at: Self.popoverPath)
        XCTAssertTrue(
            popover.contains(Self.squeezed("if coordinator.workCaptureIsActive, service.state != .recording {")),
            "The popover's first arm no longer matches `visibleBailOwner`'s, so the teardown routes "
            + "by an order the screen does not use."
        )

        // NEGATIVE CONTROL: the microphone reading, which answers `.composition`
        // for a transcribing Ask and `.askCapture` for nothing at all.
        let microphoneOnly = Self.squeezed("""
        if dictationService.state == .recording { return .askCapture }
        return .composition
        """)
        XCTAssertFalse(
            microphoneOnly.contains(owner),
            "Control: an owner that stops at the live microphone must FAIL this guard — `.processing` "
            + "is exactly the state both directions of the defect live in."
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
            "The secondary-click route is gone from the click handler: \(body.prefix(500))"
        )

        // The ICON has to answer the same conflict the same way. A Work capture
        // parked in transcription keeps `workCaptureIsBusy` true while owning no
        // microphone; if the glyph resolved on that alone the menu bar would
        // read "Transcribing" over a live Ask recording — and that glyph is the
        // only ambient signal a recording exists at all.
        let icon = try Self.controllerFunction("updateIcon")
        XCTAssertTrue(
            icon.contains(Self.squeezed("if workCaptureIsBusy, dictationService.state != .recording {")),
            "`updateIcon` resolves the Work glyph on `workCaptureIsBusy` alone, so a live Ask "
            + "recording is narrated as somebody else's transcription: \(icon.prefix(400))"
        )
    }

    /// A SECONDARY click is the menu in every state, on both lanes.
    ///
    /// The arms below act on a primary click's meaning — `case .recording:` is
    /// stop-and-SEND — so a right-click that fell through to one would hand a
    /// turn to a gateway on the way to a menu the person was opening, including
    /// the "Capture to Work…" row whose entire point is that nothing is sent.
    /// HIG makes the secondary click the context-menu gesture unconditionally,
    /// and one rule in one place is the only shape that cannot drift per-arm.
    func testASecondaryClickIsTheMenuOnBothLanes() throws {
        let body = try Self.controllerFunction("statusBarButtonClicked")

        let hoisted = try XCTUnwrap(
            body.range(of: Self.squeezed("if isSecondaryClick() { return showContextMenu() }")),
            "The click handler no longer answers a secondary click before anything else: "
            + "\(body.prefix(500))"
        )
        let workArm = try XCTUnwrap(
            body.range(of: Self.squeezed("if coordinator.workCaptureIsActive")),
            "The Work arm is gone; this guard's ordering anchor needs updating."
        )
        let dictationArm = try XCTUnwrap(
            body.range(of: Self.squeezed("switch dictationService.state")),
            "The chat-lane switch is gone; this guard's ordering anchor needs updating."
        )
        // `squeezed` leaves no gap between adjacent statements, so the hoist's
        // last character and the next arm's first are the same index —
        // `LessThanOrEqual` is the strictest form that can hold, and an arm
        // ABOVE the hoist still fails it.
        XCTAssertLessThanOrEqual(
            hoisted.upperBound, workArm.lowerBound,
            "The secondary click is asked AFTER the Work arm, which can consume it: \(body.prefix(500))"
        )
        XCTAssertLessThanOrEqual(
            hoisted.upperBound, dictationArm.lowerBound,
            "The secondary click is asked AFTER the state switch, whose `.recording` arm stops and "
            + "SENDS: \(body.prefix(500))"
        )
        XCTAssertNil(
            body.range(of: "isSecondaryClick()", range: hoisted.upperBound..<body.endIndex),
            "A second `isSecondaryClick()` survives below the hoist. Two places answering one gesture "
            + "is how one of them loses it: \(body.prefix(500))"
        )

        // THE CLASSIFICATION ITSELF, not only where it is asked. A hoist that is
        // perfectly ordered still sends an Ask turn on an ordinary right-click
        // if the predicate under it answers about the wrong event — and every
        // assertion above stays green, because they only read the caller.
        // `RefusalLaneSource.body` returns through the function's own closing
        // brace, so the expected shape is compared against the body without it.
        let classifier = String(try Self.controllerFunction("isSecondaryClick").dropLast())
        XCTAssertEqual(
            classifier,
            Self.squeezed("""
            let ev = NSApp.currentEvent
            return ev?.type == .rightMouseUp
                || (ev?.modifierFlags.contains(.control) ?? false)
            """),
            "The secondary-click test is no longer exactly a right-mouse-up OR a Control modifier. "
            + "Both halves are the gesture HIG defines, and either one missing lets an ordinary "
            + "right-click fall into the `.recording` arm, which stops and SENDS: \(classifier)"
        )

        // NEGATIVE CONTROL: the shape this guard replaced — the check living
        // inside an arm — must not satisfy it.
        let perArm = Self.squeezed("""
        switch dictationService.state {
        case .recording:
            if isSecondaryClick() { showContextMenu() } else { dictationService.toggleRecording() }
        }
        """)
        XCTAssertFalse(
            perArm.contains(Self.squeezed("if isSecondaryClick() { return showContextMenu() }")),
            "Control: a per-arm secondary-click check must FAIL the hoist assertion."
        )
        // NEGATIVE CONTROL for the classification: the mutation the caller-only
        // assertions accept.
        let leftMouse = Self.squeezed("""
        let ev = NSApp.currentEvent
        return ev?.type == .leftMouseUp
            || (ev?.modifierFlags.contains(.control) ?? false)
        """)
        XCTAssertNotEqual(
            leftMouse,
            Self.squeezed("""
            let ev = NSApp.currentEvent
            return ev?.type == .rightMouseUp
                || (ev?.modifierFlags.contains(.control) ?? false)
            """),
            "Control: a predicate that answers about the LEFT button must FAIL the body assertion."
        )
    }

    /// "Start Recording" is the SAME door as ⌘⇧1, by delegation.
    ///
    /// The menu is reachable during an Ask recording and its transcription (the
    /// hoist above makes a secondary click open it in every state), and this
    /// item's own `armQuickCapture()` re-resolves the destination of a turn
    /// already in flight — a TTL boundary or a changed default can retarget the
    /// send the popover is displaying. `handleShortcutPress` arms only from
    /// `.idle`/`.error`, stops (never re-arms) from `.recording`, and carries
    /// the `discardPendingFailedTurn()` this door never had.
    func testTheMenuRecordingDoorIsTheHotkeyHandler() throws {
        let body = try Self.controllerFunction("startRecordingFromMenu")

        let delegated = try XCTUnwrap(
            body.range(of: "handleShortcutPress()"),
            "The menu door no longer runs the hotkey's handler, so it is a second Ask entry point "
            + "with a rule set of its own: \(body.prefix(400))"
        )
        for forbidden in ["armQuickCapture", "toggleRecording", "isQuickCaptureKnownUnavailable"] {
            XCTAssertFalse(
                body.contains(forbidden),
                "`startRecordingFromMenu` still names `\(forbidden)`. Pressed during a recording or "
                + "its transcription, an arm of its own re-latches the destination of a turn already "
                + "in flight: \(body.prefix(400))"
            )
        }

        // The one check that stays: text mode's ⌘⇧1 is a popover TOGGLE, so
        // delegating there would CLOSE the popover this menu item is opening.
        let typing = try XCTUnwrap(
            body.range(of: "openPopoverForTyping()"),
            "The text-mode re-check is gone, so a menu built a beat before a Settings change hands a "
            + "text-mode user the microphone they turned off: \(body.prefix(400))"
        )
        XCTAssertLessThan(
            typing.upperBound, delegated.lowerBound,
            "The mode re-check has to precede the delegation it is protecting: \(body.prefix(400))"
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
        for door in ["handleShortcutPress", "handleRegionCapturePress"] {
            let body = try Self.controllerFunction(door)
            XCTAssertTrue(
                body.contains(Self.squeezed("guard !workRecordingIsLive else { return standDownForBusyMicrophone() }")),
                "`\(door)` no longer stands down for a live Work recording. The press cannot start a "
                + "capture (the microphone lease refuses it), so all it can do is strand a "
                + "'microphone is in use' error behind the Work HUD, to appear after the conflict is over."
            )
        }
        // The third door satisfies the rule by DELEGATION — it runs
        // `handleShortcutPress`, which carries the gate above. Asserted rather
        // than assumed, because a door that quietly grew a body again would
        // lose the gate silently.
        let menuDoor = try Self.controllerFunction("startRecordingFromMenu")
        XCTAssertTrue(
            menuDoor.contains("handleShortcutPress()"),
            "`startRecordingFromMenu` neither carries the stand-down nor delegates to the door that "
            + "does: \(menuDoor.prefix(400))"
        )
    }

    /// ⌃⌘W stands down BEFORE it raises the crosshair while a microphone is
    /// already held.
    ///
    /// The overlay stands for as long as somebody takes to choose a region. A
    /// press that raised it anyway would let them drag, and only then drop the
    /// press at the post-await guard (the popover's own Ask recording) or refuse
    /// it at the microphone lease (the main window's composer) — either way
    /// after the drag was spent. `SpeechExclusivity.shared.isRecordingActive` is
    /// the question both cases answer, and it already exists.
    ///
    /// Never a stop: this key must never be the thing that sends an Ask turn.
    func testTheWorkPressStandsDownBeforeTheOverlayWhileAMicrophoneIsHeld() throws {
        let body = try Self.controllerFunction("handleWorkCapturePress")

        let asked = try XCTUnwrap(
            body.range(of: Self.squeezed(
                "if coordinator.menuBarInputMode == .voice, SpeechExclusivity.shared.isRecordingActive {"
            )),
            "The ⌃⌘W press no longer asks whether a microphone is already held before it raises the "
            + "overlay, so a held microphone costs the person a region drag: \(body.prefix(600))"
        )
        let capture = try XCTUnwrap(
            body.range(of: Self.squeezed("regionCapture.captureRegion(purpose: .work")),
            "The region capture is gone; this guard's anchor needs updating."
        )
        XCTAssertLessThan(
            asked.upperBound, capture.lowerBound,
            "The question is asked AFTER the crosshair, which is the whole defect: \(body.prefix(600))"
        )
        XCTAssertTrue(
            body.contains("standDownForBusyMicrophone()"),
            "The refused press no longer shows the capture that is actually running: \(body.prefix(600))"
        )
        XCTAssertTrue(
            body.contains(Self.squeezed(
                "if dictationService.state != .recording { coordinator.noteWorkCaptureRefusedMicrophoneBusy() }"
            )),
            "A microphone held OUTSIDE the popover (the window composer) leaves no surface to read, "
            + "so the refusal has to be said in words — and it must NOT be said over the popover's own "
            + "visible recording, which explains itself: \(body.prefix(600))"
        )

        // THE BRANCH RETURNS. Everything above is satisfied by a stand-down that
        // falls through into the crosshair — the drag this whole check exists to
        // save, spent anyway, with a refusal sentence already printed under it.
        // The whole branch is therefore asserted as one shape rather than as
        // three independent presences.
        let standsDown = Self.squeezed("""
        if coordinator.menuBarInputMode == .voice, SpeechExclusivity.shared.isRecordingActive {
            if dictationService.state != .recording { coordinator.noteWorkCaptureRefusedMicrophoneBusy() }
            return standDownForBusyMicrophone()
        }
        """)
        XCTAssertTrue(
            body.contains(standsDown),
            "The busy branch no longer ENDS the press. A stand-down that falls through raises the "
            + "overlay anyway, so the person drags a region for a capture that was already refused: "
            + "\(body.prefix(600))"
        )

        // NEGATIVE CONTROL: the same branch with the `return` deleted — every
        // other assertion in this test still passes on it — must fail that one.
        let fallsThrough = Self.squeezed("""
        if coordinator.menuBarInputMode == .voice, SpeechExclusivity.shared.isRecordingActive {
            if dictationService.state != .recording { coordinator.noteWorkCaptureRefusedMicrophoneBusy() }
            standDownForBusyMicrophone()
        }
        """)
        XCTAssertTrue(
            fallsThrough.contains(Self.squeezed("standDownForBusyMicrophone()")),
            "Control: the no-return shape still names the helper, which is why presence alone was "
            + "never the test."
        )
        XCTAssertFalse(
            fallsThrough.contains(standsDown),
            "Control: a busy branch that calls the helper and carries on must FAIL the shape above."
        )

        // The stand-down is a SHOW, never a stop and never a second capture.
        let helper = try Self.controllerFunction("standDownForBusyMicrophone")
        XCTAssertTrue(
            helper.contains("showPopover()"),
            "The stand-down no longer shows the surface that explains the refusal: \(helper)"
        )
        for forbidden in ["toggleRecording", "finishWorkVoiceCapture", "captureRegion"] {
            XCTAssertFalse(
                helper.contains(forbidden),
                "`standDownForBusyMicrophone` names `\(forbidden)`. A capture hotkey that ended or "
                + "committed somebody else's recording is the one thing worse than dropping the "
                + "press: \(helper)"
            )
        }
        // …and the SENSE of its one condition, asserted as the whole body.
        // Presence of `showPopover()` is satisfied by the inverted guard, which
        // shows the popover only when it is ALREADY open — so the refused press
        // returns silently with the explanation behind a closed surface, which
        // is the same silent no-op the stand-down exists to replace.
        // …minus the function's own closing brace, which `RefusalLaneSource.body`
        // returns as part of the body.
        XCTAssertEqual(
            String(helper.dropLast()), Self.squeezed("if !popover.isShown { showPopover() }"),
            "The stand-down is no longer exactly \"open it if it is closed\". Every other shape "
            + "either refuses silently or re-summons a popover that is already showing the capture "
            + "it is explaining: \(helper)"
        )
        XCTAssertNotEqual(
            Self.squeezed("if popover.isShown { showPopover() }"),
            Self.squeezed("if !popover.isShown { showPopover() }"),
            "Control: the inverted guard — the mutation that kept every presence check above green "
            + "— differs only by the `!`, which is why the whole body is asserted."
        )

        // NEGATIVE CONTROL: the shape before this fix — the lease question asked
        // only by the post-await guard — must not satisfy the ordering above.
        let afterTheDrag = Self.squeezed("""
        switch await regionCapture.captureRegion(purpose: .work, requiresMicrophone: !textMode) { }
        guard dictationService.state != .recording else { return }
        """)
        XCTAssertNil(
            afterTheDrag.range(of: Self.squeezed("SpeechExclusivity.shared.isRecordingActive")),
            "Control: a press that only asks the post-await guard must FAIL the pre-overlay check."
        )
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

    // MARK: - (7) A quit does not land inside the audio's crash window

    /// The quit guard waits for a Work capture that has stopped and has not yet
    /// been PARKED.
    ///
    /// `QuitGuard`'s live count is conversations this process holds a gateway
    /// claim on — by construction it can never see a Work capture, which is the
    /// whole point of the lane. But the recording is memory-only between the
    /// stop and the moment the retry queue takes it, so those are the
    /// milliseconds in which ⌘Q silently destroys it. Nothing of this lane ever
    /// reaches the desk as audio, so the queue is the whole of what "durable"
    /// means here. No alert: there is nothing for a person to decide, and the
    /// wait is bounded so a stuck write can never hold the app open.
    func testTheQuitGuardWaitsForAWorkCaptureThatHasNotBeenParked() throws {
        let body = try Self.appDelegateFunction("applicationShouldTerminate")

        let asked = try XCTUnwrap(
            body.range(of: Self.squeezed("InAppAudioRecorder.workPublicationsInFlight > 0")),
            "The quit guard no longer asks whether a stopped Work capture is still in this process's "
            + "memory, and the turn registry it does ask cannot see one: \(body.prefix(500))"
        )
        let deferred = try XCTUnwrap(
            body.range(of: Self.squeezed("return .terminateLater")),
            "…and it no longer defers the quit while one is: \(body.prefix(500))"
        )
        XCTAssertLessThan(
            asked.upperBound, deferred.lowerBound,
            "The deferral is not the answer to that question: \(body.prefix(500))"
        )
        XCTAssertTrue(
            body.contains(Self.squeezed("await InAppAudioRecorder.waitForWorkPublications(timeout:")),
            "The deferred quit waits on nothing, so `.terminateLater` would hang the app: "
            + "\(body.prefix(500))"
        )
        XCTAssertTrue(
            body.contains(Self.squeezed("NSApp.reply(toApplicationShouldTerminate: self.quitGuardPermitsTermination())")),
            "The deferred quit answers without consulting the gateway guard, so a wait for the desk "
            + "would quit through a live reply the alert exists to protect: \(body.prefix(500))"
        )

        // THE WAIT IS BOUNDED, so it can END with the recording still in
        // memory — and the answer there is NO. `quitGuardPermitsTermination`
        // counts gateway turns and by construction cannot see a Work capture,
        // so consulting it alone turns every slow compression or desk write
        // into a silent deletion once the timeout passes.
        let refusal = Self.squeezed("""
        guard InAppAudioRecorder.workPublicationsInFlight == 0 else {
            NSApp.reply(toApplicationShouldTerminate: false)
            return
        }
        """)
        XCTAssertTrue(
            body.contains(refusal),
            "The deferred quit does not re-read the count after its bounded wait, so a publication "
            + "that outlasts the timeout is answered by the gateway registry — which is empty for "
            + "every Work capture there has ever been: \(body.prefix(700))"
        )
        let refusalRange = try XCTUnwrap(body.range(of: refusal))
        let waited = try XCTUnwrap(
            body.range(of: Self.squeezed("await InAppAudioRecorder.waitForWorkPublications(timeout:")),
            "The wait is gone; this guard's ordering anchor needs updating."
        )
        let answered = try XCTUnwrap(
            body.range(of: Self.squeezed("NSApp.reply(toApplicationShouldTerminate: self.quitGuardPermitsTermination())"))
        )
        XCTAssertLessThan(
            waited.upperBound, refusalRange.lowerBound,
            "The re-read happens before the wait, so it measures nothing: \(body.prefix(700))"
        )
        // `squeezed` removes ALL whitespace, so the refusal's closing brace and
        // the gateway answer under it are adjacent: `LessThanOrEqual` is the
        // strictest form that can hold, and it still refuses an answer given
        // above the check.
        XCTAssertLessThanOrEqual(
            refusalRange.upperBound, answered.lowerBound,
            "The gateway answer is given before the count is checked, so the refusal is unreachable: "
            + "\(body.prefix(700))"
        )

        // …and the THRESHOLD is pinned, in the delegate and in the wait alike.
        // `> 1` satisfies every presence check and every count measurement in
        // the lane while leaving exactly one capture — the ordinary case —
        // unprotected.
        XCTAssertTrue(
            body.contains(Self.squeezed("if InAppAudioRecorder.workPublicationsInFlight > 0, !isPowerOffInProgress {")),
            "The deferral's own threshold moved off zero: \(body.prefix(700))"
        )
        // `RefusalLaneSource.body` returns through the function's own closing
        // brace, so the expected shape is compared against the body without it.
        let wait = String(try Self.recorderFunction("waitForWorkPublications").dropLast())
        XCTAssertEqual(
            wait,
            Self.squeezed("""
            let deadline = ContinuousClock.now.advanced(by: timeout)
            while workPublicationsInFlight > 0, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(50))
            }
            """),
            "The bounded wait is no longer \"while ANY publication is in flight, up to the deadline\". "
            + "A threshold above zero returns immediately for the single capture this whole lane is "
            + "about: \(wait)"
        )
        XCTAssertNotEqual(
            Self.squeezed("while workPublicationsInFlight > 1, ContinuousClock.now < deadline {"),
            Self.squeezed("while workPublicationsInFlight > 0, ContinuousClock.now < deadline {"),
            "Control: the off-by-one mutation differs only in the literal, which is why the whole "
            + "body is asserted rather than the property's name."
        )
        XCTAssertTrue(
            body.contains(Self.squeezed("!isPowerOffInProgress")),
            "A logout or restart is waited on. The OS is not asking politely there — it times the "
            + "app out — and `QuitGuard` already refuses to block one: \(body.prefix(500))"
        )

        // NEGATIVE CONTROL: the gateway-only shape this replaced must fail it.
        let gatewayOnly = Self.squeezed("""
        switch QuitGuard.verdict(
            liveCount: InFlightTurnRegistry.shared.liveCount,
            singleThreadTitle: coordinator.soleLiveThreadTitle,
            singleGatewayName: coordinator.soleLiveThreadGatewayName,
            powerOffInProgress: isPowerOffInProgress
        ) {
        case .quitNow:
            return .terminateNow
        case .ask(let prompt):
            return runQuitGuardAlert(prompt) ? .terminateNow : .terminateCancel
        }
        """)
        XCTAssertFalse(
            gatewayOnly.contains(Self.squeezed("InAppAudioRecorder.workPublicationsInFlight > 0")),
            "Control: a quit guard that counts only gateway turns must FAIL this check — the Work "
            + "lane never enters that registry."
        )
    }

    /// A capture nothing durable would take is a DIFFERENT state from one still
    /// being written, and waiting cannot resolve it.
    ///
    /// When `retryLane.save` fails, the bytes are in `pendingWorkCapture` and
    /// nowhere else — the desk never holds a recording in this lane, so the
    /// queue is the only place they could have gone — and the function-scope
    /// release handed the in-flight window back on the way out, so ⌘Q read an
    /// empty registry and quit with the only copy of a recording. The count is
    /// held instead, and the person is asked rather than refused in silence:
    /// a ⌘Q that simply did nothing leaves them no way out and no reason why.
    func testAQuitCannotSilentlyDiscardACaptureNothingDurableWouldTake() throws {
        let recorder = try Self.squeezedSource(at: Self.recorderPath)

        // The reading is taken on BOTH artifacts. A screenshot whose
        // publication and preservation both failed is memory-only even while
        // the recording is safely parked. `capture.materialID` names the card
        // that holds this capture's WORDS: once it exists the recording is
        // waste, which is why it reads as safe.
        let durability = try Self.recorderFunction("noteWorkDurability")
        for half in [
            "let audioSafe = audioInFlight || capture.audio.isEmpty || capture.materialID != nil || parked",
            "let pictureSafe = capture.screenshot == nil || capture.screenshotQueued"
                + " || (parked && !armedRetryOmittedPicture)",
        ] {
            XCTAssertTrue(
                durability.contains(Self.squeezed(half)),
                "The durability reading no longer covers `\(half)`, so one artifact can be "
                + "memory-only while the quit guard reads clear: \(durability)"
            )
        }
        XCTAssertTrue(
            durability.contains(Self.squeezed("""
            if audioSafe, pictureSafe {
                releaseUnsavedWorkCapture()
            } else {
                holdUnsavedWorkCapture(capture.id)
            }
            """)),
            "The reading no longer holds the quit window for what it found unsaved: \(durability)"
        )
        // The two artifacts are answered SEPARATELY because one arm can hold the
        // recording and not the picture: the screenshot's write is the only one
        // that can fail after the recording has already committed, and an entry
        // sheltering no picture is not a place the picture is safe. A
        // `pictureSafe` that reads plain `parked` calls that capture durable.
        XCTAssertFalse(
            durability.contains(Self.squeezed("capture.screenshotQueued || parked")),
            "Control: the picture's half reads the RECORDING's arm as covering it again, so a "
            + "save that parked the audio and lost the screenshot reads as fully durable."
        )

        // It is taken on every exit of the ONE place a capture is handed to the
        // retry lane — including the exits that park nothing at all, which are
        // exactly the ones this is about.
        let preserve = try Self.recorderFunction("preserveForRetry")
        let deferred = try XCTUnwrap(
            preserve.range(of: Self.squeezed("defer { noteWorkDurability(capture) }")),
            "The preservation no longer reports its own outcome to the quit guard, so a save that "
            + "threw still reads as durable: \(preserve.prefix(600))"
        )
        let firstGuard = try XCTUnwrap(
            preserve.range(of: Self.squeezed("guard error.shouldPreserveForRetry else { return }")),
            "The taxonomy guard is gone; this guard's ordering anchor needs updating."
        )
        // `squeezed` leaves no gap between adjacent statements, so the `defer`'s
        // last character and the guard's first are the same index —
        // `LessThanOrEqual` is the strictest form that can hold, and a `defer`
        // registered below the guard still fails it.
        XCTAssertLessThanOrEqual(
            deferred.upperBound, firstGuard.lowerBound,
            "The reading is registered below an early return, so the exits that park nothing skip "
            + "it — and those are the ones that strand bytes: \(preserve.prefix(600))"
        )

        // And the two answers that END the hold are the person's: the ✕ on the
        // capture, and a capture replaced by recording again.
        for release in ["discardPendingWorkCapture", "abandonPendingWorkCapture"] {
            let body = try Self.recorderFunction(release)
            XCTAssertTrue(
                body.contains(Self.squeezed("releaseUnsavedWorkCapture()")),
                "`\(release)` no longer gives the quit window back, so ⌘Q asks about a capture the "
                + "person already threw away: \(body.prefix(400))"
            )
        }
        // The count is DERIVED from the recorders still alive to answer for it,
        // never a number somebody has to decrement. A declaration is a claim
        // about bytes in one recorder's memory, so it can only be true while
        // that recorder exists — and the surface that made it releases nothing
        // when it is dismissed over a standing error, which is how the question
        // became permanent and unanswerable.
        //
        // The behaviour is measured in `WorkboardAudioCaptureTests`; what is
        // pinned here is that no second spelling of the count can drift from it.
        XCTAssertTrue(
            recorder.contains(Self.squeezed("""
            static var unsavedWorkCaptureCount: Int {
                unsavedWorkCaptureHolders.values.filter { $0.recorder != nil }.count
            }
            """)),
            "The unsaved count is no longer derived from the live holders, so a recorder that no "
            + "longer exists can go on holding a quit window open — or something else can write to "
            + "the number the quit guard reads."
        )
        XCTAssertTrue(
            recorder.contains(Self.squeezed("""
            private struct UnsavedWorkCaptureHolder {
                weak var recorder: InAppAudioRecorder?
            }
            """)),
            "The holders are no longer weakly held, so a dismissed surface's recorder is kept alive "
            + "by the very registry that is supposed to forget it."
        )
        XCTAssertFalse(
            recorder.contains(Self.squeezed("unsavedWorkCaptureCount += 1")),
            "The count is incremented by hand again. Its guard cannot see the difference between "
            + "`+= 1` and `+= 0`, and neither can Cmd-Q."
        )

        // The delegate asks it, on BOTH paths, and asks it as a QUESTION.
        let terminate = try Self.appDelegateFunction("applicationShouldTerminate")
        XCTAssertEqual(
            terminate.components(separatedBy: Self.squeezed("unsavedWorkCapturePermitsTermination()")).count - 1,
            2,
            "The unsaved-capture question is not asked on both the deferred and the direct path — "
            + "a delayed quit that skipped it is a quit that skipped the guard: \(terminate.prefix(700))"
        )
        let decision = try Self.appDelegateFunction("unsavedWorkCapturePermitsTermination")
        XCTAssertTrue(
            decision.contains(Self.squeezed("QuitGuard.unsavedCaptureVerdict(")),
            "The decision is no longer `QuitGuard`'s: \(decision.prefix(500))"
        )
        XCTAssertTrue(
            decision.contains(Self.squeezed("return alert.runModal() == .alertFirstButtonReturn")),
            "The unsaved capture is answered without asking anybody — a silent refusal is a ⌘Q that "
            + "does nothing forever, and a silent quit is the data loss: \(decision.prefix(500))"
        )
        XCTAssertTrue(
            decision.contains(Self.squeezed("alert.addButton(withTitle: prompt.quitButtonTitle).keyEquivalent = \"\"")),
            "The destructive button is reachable by Return again: \(decision.prefix(500))"
        )

        // The verdict itself: power-off wins, an empty count is silent, and
        // anything else is a question.
        let verdict = String(try Self.quitGuardFunction("unsavedCaptureVerdict").dropLast())
        XCTAssertEqual(
            verdict,
            Self.squeezed("""
            guard !powerOffInProgress else { return .quitNow }
            guard unsavedCount > 0 else { return .quitNow }
            return .ask(UnsavedCapturePrompt(count: unsavedCount))
            """),
            "The unsaved-capture verdict is no longer exactly \"power-off quits, nothing unsaved "
            + "quits, anything else asks\": \(verdict)"
        )

        // THE DECLARATION'S OWN POSITION, which no runtime measurement in this
        // bundle can reach. `AudioRecorder.stopRecording()` deletes the file and
        // the compression that follows is the longest step before anything
        // durable exists — so a declaration moved BELOW either of them leaves
        // the whole window it exists for uncovered, while every measurement
        // (taken during the picture pipeline and at the speech hop) still reads
        // exactly as it does now.
        let pipeline = try Self.recorderFunction("runCaptureToCompletion")
        let declared = try XCTUnwrap(
            pipeline.range(of: Self.squeezed("""
            if retryDestination == .work {
                Self.workPublicationsInFlight += 1
                workPublicationDeclared = true
            }
            """)),
            "The stopped recording is no longer declared in flight at all: \(pipeline.prefix(700))"
        )
        for later in ["recorder.stopRecording()", "await AudioCompressor.compress(audioData)"] {
            let step = try XCTUnwrap(
                pipeline.range(of: Self.squeezed(later)),
                "`\(later)` is gone; this guard's ordering anchor needs updating."
            )
            XCTAssertLessThan(
                declared.upperBound, step.lowerBound,
                "The quit window is declared AFTER `\(later)`, so a ⌘Q inside that step takes the "
                + "only copy of the audio: \(pipeline.prefix(900))"
            )
        }

        // The window is given back ONE at a time. The measurements above are
        // taken with a single recorder publishing, and a release that zeroed the
        // count would satisfy every one of them while the FIRST of two
        // overlapping publications removed the second's quit protection — the
        // menu bar's recorder and the desk sheet's are different instances and
        // either may be mid-publication. A two-line body is pinned whole.
        let release = try Self.recorderFunction("releaseWorkPublication")
        XCTAssertEqual(
            release.trimmingCharacters(in: CharacterSet(charactersIn: "}").union(.whitespacesAndNewlines)),
            Self.squeezed("workPublicationsInFlight = max(0, workPublicationsInFlight - 1)"),
            """
            The declared quit window is no longer given back one at a time: \(release). A count             reset to zero lets one finishing publication drop another's protection, and a count             that can go negative lets a later capture's window read as already closed.
            """
        )

        // …and the parked PICTURE's write still REPORTS its failure, exactly as
        // the recording's does one line above it. A swallowed one arms an entry
        // whose image was never written: the recovery it promises finds nothing
        // to republish, and the durability reading above is told a lie.
        //
        // What it may no longer do is abandon the arm. The sidecar and the
        // recording are committed above it and `reconcile` adopts that pair
        // whether or not the index row lands, so a throw taken at the picture
        // left a live entry its own author could neither reserve nor retire. The
        // row commits, the announcement goes out, and the picture's failure
        // arrives as its own outcome — in that order.
        let save = try Self.squeezedSource(at: "Conduck/Services/PendingRetryStore.swift")
        let pictureWrite = try XCTUnwrap(
            save.range(of: Self.squeezed("""
            try workImageData.write(
                to: container.appendingPathComponent(
                    PendingRetryFiles.workImage(metadata.id)
                ),
                options: [.atomic, .completeFileProtection]
            )
            """)),
            "The parked screenshot's write is no longer an unswallowed `try`: \(save.prefix(900))"
        )
        XCTAssertFalse(
            save.contains(Self.squeezed("try? workImageData.write")),
            "The parked screenshot's write swallows its own failure again, so `save` reports a "
            + "preservation that did not happen: \(save.prefix(900))"
        )
        let rowCommit = try XCTUnwrap(
            save.range(of: Self.squeezed(
                "try persist(PendingRetryQueue.upserting(metadata, into: existing), to: defaults)"
            )),
            "The index row's commit is gone; this guard's ordering anchor needs updating."
        )
        let reported = try XCTUnwrap(
            save.range(of: Self.squeezed("""
            if let pictureFailure {
                throw PendingRetrySaveOutcome.recordingParkedWithoutPicture(underlying: pictureFailure)
            }
            """)),
            "A screenshot write that failed no longer reaches the caller at all, so a picture held "
            + "only in memory reads as parked: \(save.prefix(1200))"
        )
        XCTAssertLessThan(
            pictureWrite.upperBound, rowCommit.lowerBound,
            "The picture is written after the index row, which is not the arm order this store's "
            + "recovery reads: \(save.prefix(1200))"
        )
        XCTAssertLessThan(
            rowCommit.upperBound, reported.lowerBound,
            "The picture's failure is raised BEFORE the index row commits, so the entry the "
            + "recording already made stays invisible to the surface that made it: \(save.prefix(1200))"
        )

        // …and the caller acts on that outcome rather than reading every throw
        // as "nothing was parked". It is read in `writeDurableRetry`, the ONE
        // write both entry points share — the park every Work capture takes
        // before its speech hop, and the preservation a failure takes after it
        // — so the partial outcome cannot be handled on one path and dropped on
        // the other.
        let writeBody = try Self.recorderFunction("writeDurableRetry")
        XCTAssertTrue(
            writeBody.contains(Self.squeezed(
                "catch PendingRetrySaveOutcome.recordingParkedWithoutPicture {"
            )),
            "The recorder reads a partial preservation as no preservation again, so the entry the "
            + "store armed is one it can neither reserve nor retire: \(writeBody.prefix(900))"
        )
        XCTAssertTrue(
            writeBody.contains(Self.squeezed("armedRetryOmittedPicture = true")),
            "A partial arm no longer records that the PICTURE is still memory-only, so the quit "
            + "guard reads a parked recording as covering both: \(writeBody.prefix(900))"
        )
        // Both entry points, or the rule holds on one path only.
        for entry in ["preserveForRetry", "parkForTranscription"] {
            let body = try Self.recorderFunction(entry)
            XCTAssertTrue(
                body.contains(Self.squeezed("writeDurableRetry(")),
                "`\(entry)` writes the durable record itself again, so a second spelling of the "
                + "arm can drift from the one the outcome above is handled in: \(body.prefix(600))"
            )
        }

        // NEGATIVE CONTROL: the silent preservation this replaced — a `guard`
        // that returns with nothing recorded anywhere.
        let silent = Self.squeezed("""
        guard (try? await retryLane.save(
            audioData: capture.audio,
            metadata: metadata,
            workImageData: capture.screenshotQueued ? nil : capture.screenshot
        )) != nil else { return }
        armedDurableRetryID = capture.id
        """)
        XCTAssertFalse(
            silent.contains(Self.squeezed("noteWorkDurability(capture)")),
            "Control: a preservation whose failure is invisible must FAIL this guard — that "
            + "invisibility IS the silent loss."
        )
        XCTAssertFalse(
            silent.contains(Self.squeezed("PendingRetrySaveOutcome")),
            "Control: the shape that read every throw as an empty queue must FAIL the outcome "
            + "assertions above."
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

    /// The app delegate's, for the one rule that is enforced neither in the
    /// controller nor in the coordinator: the quit that must not land inside a
    /// stopped capture's publication.
    private static func appDelegateFunction(_ name: String) throws -> String {
        let source = try RefusalLaneSource.source(at: appDelegatePath)
        return squeezed(try RefusalLaneSource.body(ofFunction: name, in: source, path: appDelegatePath))
    }

    /// One function's body from the shared recorder. The quit guard's promise
    /// is split across two files — the delegate defers, the recorder measures —
    /// so the threshold has to be pinned in both or the mutation just moves.
    private static func recorderFunction(_ name: String) throws -> String {
        let source = try RefusalLaneSource.source(at: recorderPath)
        return squeezed(try RefusalLaneSource.body(ofFunction: name, in: source, path: recorderPath))
    }

    /// One function's body from the pure quit verdict. The wording and the rule
    /// live there precisely so they can be asserted without driving AppKit
    /// modality.
    private static func quitGuardFunction(_ name: String) throws -> String {
        let path = "Conduck/MenuBar/QuitGuard.swift"
        let source = try RefusalLaneSource.source(at: path)
        return squeezed(try RefusalLaneSource.body(ofFunction: name, in: source, path: path))
    }
}
