// SPDX-License-Identifier: Apache-2.0

// Conduck
// MenuBarWorkCaptureStateTests.swift
//
// The menu bar's Work lane, asserted where it can be: the RULES as values, and
// the WIRING as source shape.
//
// The rules come first because they are the ones a person loses words to. The
// popover's compose surface has two aims, and the aim is stored WITH the words
// rather than raised as a flag the popover clears on close — an outside click is
// an implicit dismissal that deliberately keeps the composition alive, so a flag
// cleared there would leave a private sentence sitting in the field Chat's
// Return sends. `MenuBarComposeState` is that rule, and it is a plain value so
// the rule can be exercised without AppKit, a popover, or a Mac.
//
// The wiring is asserted as source shape for the reason every `MenuBar/` guard
// in this bundle is: `MenuBarCoordinator` and `DictationPopoverView` are
// `#if os(macOS)`, this suite runs on an iOS simulator, and a SwiftUI popover is
// one long expression no unit test can mount. Four claims about it are
// load-bearing enough to be worth pinning anyway — the Work HUD outranks every
// other content arm, Return follows the surface rather than the habit, the Ask
// affordance is absent from the Work surface rather than merely disabled, and
// the acknowledgement opens the desk it is talking about.

import XCTest
@testable import Conduck

final class MenuBarWorkCaptureStateTests: XCTestCase {

    // MARK: - The aim travels with the words

    func testAFreshCompositionIsAimedAtChat() {
        let compose = MenuBarComposeState()
        XCTAssertEqual(compose.target, .chat,
                       "⌘⇧1 is the established summon; the Work aim is only ever taken explicitly.")
        XCTAssertTrue(compose.activeTextIsBlank)
    }

    func testTypingWritesTheSlotTheSurfaceIsAimedAt() {
        var compose = MenuBarComposeState()
        compose.activeText = "ask the gateway"
        compose.aimAtWork()
        compose.activeText = "a private thought"

        XCTAssertEqual(compose.chatText, "ask the gateway")
        XCTAssertEqual(compose.workText, "a private thought")
        XCTAssertEqual(compose.activeText, "a private thought",
                       "The field edits one slot at a time, and it is the aimed one.")
    }

    /// The founder-QA case, and the reason the aim is a stored value: an outside
    /// click is an IMPLICIT dismissal that keeps the composition. Nothing in this
    /// type releases the aim on a close, so a Work composition reopens as a Work
    /// composition — the only two things that release it are asserted below.
    func testAClickAwayDismissalReleasesNeitherTheWordsNorTheAim() {
        var compose = MenuBarComposeState()
        compose.aimAtWork()
        compose.activeText = "half a private thought"

        // A dismissal is the ABSENCE of a mutation. Re-reading after it is
        // exactly what the popover does when it is summoned again.
        let reopened = compose

        XCTAssertEqual(reopened.target, .work)
        XCTAssertEqual(reopened.activeText, "half a private thought")
        XCTAssertTrue(reopened.chatText.isEmpty,
                      "The Chat draft must never be where the Work words ended up.")
    }

    func testReturningToChatParksTheWorkWordsRatherThanLosingThem() {
        var compose = MenuBarComposeState()
        compose.aimAtWork()
        compose.activeText = "words for the desk"
        compose.chatText = "words for the gateway"

        compose.returnToChat()

        XCTAssertEqual(compose.target, .chat)
        XCTAssertEqual(compose.activeText, "words for the gateway",
                       "⌘⇧1 shows the Chat draft — never the Work one wearing Chat's chrome.")
        XCTAssertEqual(compose.workText, "words for the desk")

        compose.aimAtWork()
        XCTAssertEqual(compose.activeText, "words for the desk",
                       "The parked Work composition comes back on the next ⌃⌘W press.")
    }

    func testASecondAimAtWorkKeepsWhatIsAlreadyWritten() {
        var compose = MenuBarComposeState()
        compose.aimAtWork()
        compose.activeText = "still typing"
        compose.aimAtWork()

        XCTAssertEqual(compose.activeText, "still typing",
                       "⌃⌘W onto an open Work surface must not empty it.")
    }

    // MARK: - The two things that DO release the aim

    func testACommittedCompositionIsConsumedAndReleasedBackToChat() {
        var compose = MenuBarComposeState()
        compose.aimAtWork()
        compose.activeText = "published"

        XCTAssertTrue(compose.clearCommitted("published", aimedAt: .work))
        XCTAssertTrue(compose.workText.isEmpty)
        XCTAssertEqual(compose.target, .chat,
                       "A finished Work capture hands the surface back; it is not a sticky mode.")
    }

    /// The commit runs across an `await`. Anything typed under it belongs to the
    /// NEXT capture, so the composition keeps both its words and its aim — a
    /// blanket clear here would delete a sentence that was never published.
    func testACompositionThatChangedUnderTheCommitKeepsItsWordsAndItsAim() {
        var compose = MenuBarComposeState()
        compose.aimAtWork()
        compose.activeText = "published"
        compose.activeText = "published and then some more"

        XCTAssertFalse(compose.clearCommitted("published", aimedAt: .work))
        XCTAssertEqual(compose.workText, "published and then some more")
        XCTAssertEqual(compose.target, .work,
                       "Words that survive a commit must not be handed to the gateway lane.")
    }

    /// The commit runs across an `await`, and ⌃⌘W can re-aim the surface under
    /// it. The published words are still sitting in the slot they were typed in,
    /// so the consume has to NAME that slot: clearing "whatever is active now"
    /// would leave a saved private sentence in the field Chat's Return sends,
    /// and would empty the untouched composition the person moved to instead.
    func testACommitConsumesTheSlotItTookTheWordsFromEvenAfterTheSurfaceIsReAimed() {
        var compose = MenuBarComposeState()
        compose.chatText = "a private note, saved with Add to Work"
        let aimAtCommit = compose.target          // .chat — the Chat surface's button
        let draftAtCommit = compose.activeText

        compose.aimAtWork()                        // ⌃⌘W lands while the save runs
        compose.activeText = "something else entirely"

        XCTAssertTrue(compose.clearCommitted(draftAtCommit, aimedAt: aimAtCommit))
        XCTAssertTrue(compose.chatText.isEmpty,
                      "Saved words must never survive in the field Chat's Return sends.")
        XCTAssertEqual(compose.workText, "something else entirely",
                       "The composition the person navigated to is not the one that gets emptied.")
        XCTAssertEqual(compose.target, .work,
                       "A commit for a slot nobody is looking at must not re-aim the surface.")
    }

    /// The mirror case: the Work surface's own Return, with ⌘⇧1 pressed under
    /// the save. The Work slot is consumed, the Chat draft the person landed on
    /// is untouched, and nothing hands them a surface they did not ask for.
    func testACommitOnAParkedSlotLeavesTheSurfaceWhereTheUserPutIt() {
        var compose = MenuBarComposeState()
        compose.aimAtWork()
        compose.activeText = "words for the desk"
        let aimAtCommit = compose.target
        let draftAtCommit = compose.activeText

        compose.returnToChat()                     // ⌘⇧1 under the save
        compose.activeText = "a chat draft"

        XCTAssertTrue(compose.clearCommitted(draftAtCommit, aimedAt: aimAtCommit))
        XCTAssertTrue(compose.workText.isEmpty,
                      "The published Work words are consumed, so a second Return cannot save them twice.")
        XCTAssertEqual(compose.chatText, "a chat draft")
        XCTAssertEqual(compose.target, .chat)
    }

    func testTheChatLaneCommitsThroughTheSameRule() {
        var compose = MenuBarComposeState()
        compose.chatText = "sent"

        XCTAssertTrue(compose.clearCommitted("sent", aimedAt: .chat))
        XCTAssertTrue(compose.chatText.isEmpty)
        XCTAssertEqual(compose.target, .chat)
    }

    func testAnExplicitDiscardThrowsAwayOnlyTheCompositionOnScreen() {
        var compose = MenuBarComposeState()
        compose.chatText = "a chat draft nobody bailed on"
        compose.aimAtWork()
        compose.activeText = "abandoned"

        compose.discardActive()

        XCTAssertTrue(compose.workText.isEmpty)
        XCTAssertEqual(compose.chatText, "a chat draft nobody bailed on",
                       "Esc discards what the person was looking at, not a second composition they cannot see.")
        XCTAssertEqual(compose.target, .chat)
    }

    func testWhitespaceIsNothingToCommit() {
        var compose = MenuBarComposeState()
        compose.aimAtWork()
        compose.activeText = "  \n\t "
        XCTAssertTrue(compose.activeTextIsBlank,
                      "The commit paths trim, so the gate that offers the commit has to trim too.")
        compose.activeText = " a "
        XCTAssertFalse(compose.activeTextIsBlank)
    }

    // MARK: - One recorder state, one sentence

    func testEveryRecorderStateResolvesToTheDeskSheetsOwnCopy() {
        XCTAssertEqual(MenuBarWorkVoiceStatus.resolve(.idle), .starting)
        XCTAssertEqual(MenuBarWorkVoiceStatus.resolve(.recording(startedAt: Date())), .listening)
        XCTAssertEqual(MenuBarWorkVoiceStatus.resolve(.processing), .transcribing)
        XCTAssertEqual(MenuBarWorkVoiceStatus.resolve(.preparingVoice(progress: nil)), .preparing)
        XCTAssertEqual(MenuBarWorkVoiceStatus.resolve(.preparingVoice(progress: 0.4)), .preparing)
        XCTAssertEqual(MenuBarWorkVoiceStatus.resolve(.error(.audioMicBusy)), .stopped)
    }

    /// The raw values ARE the catalog keys, and every one of them already ships
    /// for `WorkboardVoiceCaptureView`. A capture that reads one way in a window
    /// and another way in the menu bar is the drift this borrowing exists to
    /// prevent, so a renamed key here has to be a deliberate act.
    func testTheStatusKeysAreTheOnesTheDeskSheetAlreadyRenders() {
        XCTAssertEqual(
            MenuBarWorkVoiceStatus.allCases.map(\.rawValue),
            [
                "workboard.voice.starting",
                "workboard.voice.listening",
                "workboard.voice.transcribing",
                "workboard.voice.preparing",
                "workboard.voice.error.title"
            ]
        )
    }

    // MARK: - Wiring (source shape — the popover cannot be mounted here)

    private static let popoverPath = "Conduck/MenuBar/DictationPopoverView.swift"
    private static let coordinatorPath = "Conduck/MenuBar/MenuBarCoordinator.swift"
    private static let controllerPath = "Conduck/MenuBar/MenuBarController.swift"

    /// Comments cannot satisfy any assertion below, and neither can formatting:
    /// every check runs over comment-stripped, whitespace-squeezed source.
    private static func squeezedSource(at path: String) throws -> String {
        let stripped = RefusalLaneSource.stripComments(try RefusalLaneSource.rawSource(at: path))
        return stripped.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    func testTheWorkHUDIsTheFirstArmOfTheContentRouter() throws {
        let source = try Self.squeezedSource(at: Self.popoverPath)
        guard let router = source.range(of: "private var content: some View {") else {
            return XCTFail("no `content` router in \(Self.popoverPath)")
        }
        let head = String(source[router.upperBound...].prefix(120))
        XCTAssertTrue(
            head.contains("if coordinator.workCaptureIsActive { workCaptureView }"),
            "The Work HUD has to be the FIRST arm: the popover is the only surface a ⌃⌘W "
                + "capture has, so any arm above it can hide a live microphone. Router head: \(head)"
        )
    }

    func testReturnOnTheWorkSurfaceSavesAndNeverSends() throws {
        let source = try Self.squeezedSource(at: Self.popoverPath)
        let submit = try RefusalLaneSource.trailingClosure(
            after: ".onSubmit",
            in: source,
            path: Self.popoverPath
        )
        let workArm = try RefusalLaneSource.trailingClosure(
            after: "if isWorkOnly",
            in: submit,
            path: Self.popoverPath
        )
        XCTAssertTrue(workArm.contains("coordinator.saveQuickDraftToWork()"),
                      "Return on the Work surface commits to the desk: \(workArm)")
        XCTAssertFalse(workArm.contains("sendQuickTypedDraft"),
                       "…and reaches no gateway path at all: \(workArm)")
        XCTAssertTrue(workArm.contains("return"),
                      "The Work arm has to STOP there — falling through would send the same words: \(workArm)")
        XCTAssertTrue(submit.contains("coordinator.sendQuickTypedDraft()"),
                      "The Chat surface's Return is unchanged: \(submit)")
    }

    /// Absent, not disabled. A disabled Ask button on a Work surface still says
    /// the words could be sent from here, and the whole point of the separate
    /// composition is that they cannot.
    func testTheAskAffordanceIsNotDrawnOnTheWorkSurface() throws {
        let source = try Self.squeezedSource(at: Self.popoverPath)
        guard let guarded = source.range(of: "if !isWorkOnly {") else {
            return XCTFail("the Ask affordance is not gated on the aim in \(Self.popoverPath)")
        }
        let arm = String(source[guarded.upperBound...].prefix(600))
        XCTAssertTrue(arm.contains("coordinator.sendQuickTypedDraft()"),
                      "The gated arm has to be the one holding Ask: \(arm)")
    }

    /// The refusal is asserted where the gateway path BEGINS, not only in the
    /// view that hides the button — a second entry point (a key monitor, a menu
    /// item) must not be able to send a Work composition by calling the method.
    func testTheSendPathRefusesWhileTheSurfaceIsAimedAtWork() throws {
        let source = try Self.squeezedSource(at: Self.coordinatorPath)
        let body = try RefusalLaneSource.body(
            ofFunction: "sendQuickTypedDraft",
            in: source,
            path: Self.coordinatorPath
        )
        XCTAssertTrue(
            body.contains("guard compose.target == .chat else { return }"),
            "sendQuickTypedDraft must refuse a Work-aimed composition outright: \(body.prefix(200))"
        )
    }

    /// The acknowledgement is a claim the person is entitled to check, so the
    /// saved row is a button and the button raises the desk. Both halves matter:
    /// a row that posted nothing would be a banner asking to be believed.
    func testTheSavedAcknowledgementOpensTheDesk() throws {
        let source = try Self.squeezedSource(at: Self.popoverPath)
        let row = try RefusalLaneSource.body(
            ofFunction: "workFeedbackRow",
            in: source,
            path: Self.popoverPath
        )
        XCTAssertTrue(row.contains("Button(action: openWorkboard)"),
                      "The saved row has to be the control that opens Work: \(row.prefix(300))")

        let open = try RefusalLaneSource.body(
            ofFunction: "openWorkboard",
            in: source,
            path: Self.popoverPath
        )
        XCTAssertTrue(open.contains("NSApp.activate(ignoringOtherApps: true)"), open)
        XCTAssertTrue(open.contains("NotificationCenter.default.post(name: .showWorkboard"), open)
    }

    /// The drain is what makes "Added to Work" true. Publication only queues an
    /// envelope; without the import the card is invisible until something else
    /// opens the desk, so the banner would name a card that is not on the board.
    func testTheDeskCommitDrainsBeforeItClaimsTheCardIsThere() throws {
        let source = try Self.squeezedSource(at: Self.coordinatorPath)
        let body = try RefusalLaneSource.body(
            ofFunction: "saveQuickDraftToWork",
            in: source,
            path: Self.coordinatorPath
        )
        guard let publish = body.range(of: "publishAppCapture"),
              let drain = body.range(of: "drainAvailableCaptures()"),
              let banner = body.range(of: "workboard.menuBar.saved") else {
            return XCTFail("saveQuickDraftToWork no longer publishes, drains and acknowledges: \(body.prefix(400))")
        }
        XCTAssertTrue(publish.upperBound < drain.lowerBound,
                      "The drain follows the publication it is importing.")
        XCTAssertTrue(drain.upperBound < banner.lowerBound,
                      "The acknowledgement follows the drain that makes it true.")
    }

    /// Nothing on this lane may reach a gateway, asserted over the whole popover
    /// rather than over the Work arms alone: a Work path that grew a hop would
    /// have to name one of these to do it.
    func testNoPopoverPathReachesAGatewayHop() throws {
        let source = try Self.squeezedSource(at: Self.popoverPath)
        for forbidden in ["startConverseHop", "startDeferredConverseHop", "handleQuickSend"] {
            XCTAssertFalse(source.contains(forbidden),
                           "\(forbidden) has no business in the menu-bar popover.")
        }
    }

    /// The value rule above is only worth having if the commit actually uses it.
    /// `saveQuickDraftToWork` has to snapshot the SLOT alongside the words, or
    /// the consume it performs two `await`s later names whichever composition
    /// the person happens to be looking at by then.
    func testTheDeskCommitSnapshotsTheSlotItIsConsuming() throws {
        let source = try Self.squeezedSource(at: Self.coordinatorPath)
        let body = try RefusalLaneSource.body(
            ofFunction: "saveQuickDraftToWork",
            in: source,
            path: Self.coordinatorPath
        )
        XCTAssertTrue(body.contains("let aimAtCommit = compose.target"),
                      "The commit no longer snapshots the aim with the words: \(body.prefix(200))")
        XCTAssertTrue(
            body.contains("compose.clearCommitted(draftAtCommit, aimedAt: aimAtCommit)"),
            "The consume no longer names the slot it published from, so re-aiming the surface during "
            + "the save clears the wrong composition: \(body.prefix(400))"
        )
    }

    /// The recorder is `.idle` for the whole start, which is the one state
    /// `cancelWorkVoiceCapture` can do nothing about. Without a token the start
    /// carries, an Esc pressed while the microphone comes up closes the popover
    /// and the capture then begins behind it, with no surface left to stop it.
    func testAStartCancelledUnderItsOwnSuspensionTearsTheMicrophoneDown() throws {
        let source = try Self.squeezedSource(at: Self.coordinatorPath)
        let begin = try RefusalLaneSource.body(
            ofFunction: "beginWorkVoiceCapture",
            in: source,
            path: Self.coordinatorPath
        )
        guard let taken = begin.range(of: "let startToken = workVoiceStartToken"),
              let start = begin.range(of: "await workVoiceRecorder.startRecording()"),
              let check = begin.range(of: "guard startToken == workVoiceStartToken else"),
              let teardown = begin.range(of: "cancelWorkVoiceCapture()") else {
            return XCTFail("The start no longer carries a cancellable token: \(begin.prefix(500))")
        }
        XCTAssertTrue(taken.upperBound < start.lowerBound,
                      "The token has to be taken BEFORE the suspension it protects.")
        XCTAssertTrue(start.upperBound < check.lowerBound,
                      "…and checked after it, which is where a cancellation can have landed.")
        XCTAssertTrue(check.upperBound < teardown.lowerBound,
                      "A start that was cancelled under itself must tear the microphone down.")

        let cancel = try RefusalLaneSource.body(
            ofFunction: "cancelWorkVoiceCapture",
            in: source,
            path: Self.coordinatorPath
        )
        XCTAssertTrue(
            cancel.contains("workVoiceStartToken &+= 1"),
            "The cancel no longer invalidates a start in flight, so it is a no-op for exactly the "
            + "window in which the popover is closing: \(cancel.prefix(300))"
        )
    }

    /// A reply that lands behind the Work HUD was never seen. Reporting its
    /// thread as visible acknowledges it as read AND suppresses its banner, so
    /// the capture has to take the thread off screen when it takes the surface.
    func testStartingAWorkCaptureTakesTheVisibleThreadOffScreen() throws {
        let source = try Self.squeezedSource(at: Self.coordinatorPath)
        let begin = try RefusalLaneSource.body(
            ofFunction: "beginWorkVoiceCapture",
            in: source,
            path: Self.coordinatorPath
        )
        XCTAssertTrue(
            begin.contains("setPopoverVisibleConversation(nil)"),
            "The Work HUD takes the popover without releasing the thread underneath it, which is then "
            + "marked read for a reply nobody saw: \(begin.prefix(400))"
        )
    }

    /// The click-away rule, asserted where it can actually be broken.
    ///
    /// `testAClickAwayDismissalReleasesNeitherTheWordsNorTheAim` above proves
    /// that the VALUE releases nothing on a dismissal — but a dismissal is the
    /// ABSENCE of a mutation, so that test passes whether or not the production
    /// close path adds one. The two hooks every popover close runs through are
    /// where such a mutation would appear, and there it would be the exact
    /// failure the two-slot design exists to prevent: an outside click is an
    /// IMPLICIT gesture, and a private sentence taken by one is a sentence the
    /// person never chose to lose. Esc is the EXPLICIT bail and routes through
    /// `cancelActiveCapture`, which is not this path — so that name is forbidden
    /// here too, since routing the close hook into it would silently turn every
    /// click-away into a discard.
    func testNoPopoverCloseHookTouchesTheWorkComposition() throws {
        let coordinatorHook = try RefusalLaneSource.body(
            ofFunction: "popoverDidCloseHook",
            in: try Self.squeezedSource(at: Self.coordinatorPath),
            path: Self.coordinatorPath
        )
        let controllerHook = try RefusalLaneSource.body(
            ofFunction: "popoverDidClose",
            in: try Self.squeezedSource(at: Self.controllerPath),
            path: Self.controllerPath
        )

        // Control: prove both extractions landed on the real hook bodies, or
        // every `AssertFalse` below is a claim about an empty string.
        XCTAssertTrue(coordinatorHook.contains("resetQuickDestinationAfterTurn()"),
                      "The coordinator's close hook is not the body this guard read: \(coordinatorHook.prefix(200))")
        XCTAssertTrue(controllerHook.contains("coordinator.setPopoverVisibleConversation(nil)"),
                      "The controller's close hook is not the body this guard read: \(controllerHook.prefix(200))")

        for (path, hook) in [(Self.coordinatorPath, coordinatorHook),
                             (Self.controllerPath, controllerHook)] {
            for forbidden in [
                "discardWorkOnlyCompose",
                "closeWorkOnlyCompose",
                "discardActive",
                "clearCommitted",
                "returnToChat",
                "quickWorkDraft",
                "compose.workText",
                "cancelActiveCapture"
            ] {
                XCTAssertFalse(
                    hook.contains(forbidden),
                    "The popover close hook in \(path) names `\(forbidden)`. A close is an implicit "
                    + "dismissal that must PRESERVE the composition — dropping the words, or merely "
                    + "dropping the aim, hands a private sentence to the field Chat's Return sends. "
                    + "Hook: \(hook.prefix(400))"
                )
            }
        }
    }

    /// A read-only shared-reply override hides the compose surface outright, so
    /// ⌃⌘W onto one would show neither the Work field nor the words parked in
    /// it. Clearing it is a DISPLAY change; arming a chat capture here is not
    /// available to this lane at all.
    func testWorkComposeClearsTheReadOnlyOverrideWithoutArmingAChatCapture() throws {
        let source = try Self.squeezedSource(at: Self.coordinatorPath)
        let body = try RefusalLaneSource.body(
            ofFunction: "openComposeForWorkOnly",
            in: source,
            path: Self.coordinatorPath
        )
        XCTAssertTrue(body.contains("clearPopoverOverride()"),
                      "⌃⌘W over a read-only reply still has no compose surface: \(body)")
        XCTAssertTrue(body.contains("compose.aimAtWork()"), body)
        XCTAssertFalse(body.contains("armQuickCapture"),
                       "The Work lane may never latch the chat lane's destination snapshot: \(body)")
    }
}
