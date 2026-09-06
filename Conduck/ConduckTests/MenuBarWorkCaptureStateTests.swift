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

    /// A computed property's brace-matched body — the `RefusalLaneSource.body`
    /// of a `var`. It lives here rather than beside that helper because the
    /// rules this file pins moved onto computed properties, and the shared
    /// helper matches `func` only.
    private static func propertyBody(_ name: String, in source: String) throws -> String {
        guard let declaration = source.range(of: "var \(name): "),
              let opening = source.range(of: "{", range: declaration.upperBound..<source.endIndex) else {
            throw NSError(domain: "MenuBarWorkCaptureStateTests", code: 1, userInfo: [
                NSLocalizedDescriptionKey:
                    "No `var \(name)` in \(coordinatorPath) — update this guard."
            ])
        }
        var index = opening.upperBound
        let start = index
        var depth = 1
        while index < source.endIndex, depth > 0 {
            if source[index] == "{" { depth += 1 }
            if source[index] == "}" { depth -= 1 }
            index = source.index(after: index)
        }
        return String(source[start..<index])
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

    // MARK: - The voice lane's own ownership and its own receipt

    /// OWNERSHIP FIRST, SURFACE SECOND.
    ///
    /// `showPopover` reports the thread it opens onto as VISIBLE, and a thread
    /// reported visible is acknowledged as read and loses its arrival banner.
    /// The ⌃⌘W HUD is about to cover that thread, and nothing later can hand an
    /// unread mark back — so the claim has to precede the summon rather than
    /// arrive with the microphone start, which is a hop later.
    func testTheWorkVoiceSummonTakesThePopoverBeforeItShowsIt() throws {
        let controller = try Self.squeezedSource(at: Self.controllerPath)
        let press = try RefusalLaneSource.body(
            ofFunction: "handleWorkCapturePress",
            in: controller,
            path: Self.controllerPath
        )
        guard let claim = press.range(of: "coordinator.claimPopoverForWorkVoiceCapture()") else {
            return XCTFail(
                "The ⌃⌘W handler no longer claims the popover before summoning it, so the summon "
                + "acknowledges whatever reply the HUD is about to cover: \(press.prefix(500))"
            )
        }
        let before = String(press[..<claim.lowerBound])
        let after = String(press[claim.upperBound...])

        XCTAssertTrue(
            before.contains("openComposeForWorkOnly() showPopover() return"),
            "The one summon allowed ahead of the claim is the TEXT arm's, which returns — in text mode "
            + "the popover really does show the thread above the compose band: \(before.prefix(400))"
        )
        XCTAssertEqual(
            before.components(separatedBy: "showPopover()").count - 1, 1,
            "A second summon ahead of the claim is the bug this guard exists for: \(before.prefix(400))"
        )
        XCTAssertTrue(
            after.contains("showPopover()"),
            "The voice summon has to FOLLOW the claim: \(after.prefix(400))"
        )
        XCTAssertTrue(
            after.contains("beginWorkVoiceCapture(screenshot: screenshot)"),
            "…and the microphone start still follows the summon, carrying the region the overlay took "
            + "with it: \(after.prefix(400))"
        )

        let coordinator = try Self.squeezedSource(at: Self.coordinatorPath)
        let claimBody = try RefusalLaneSource.body(
            ofFunction: "claimPopoverForWorkVoiceCapture",
            in: coordinator,
            path: Self.coordinatorPath
        )
        XCTAssertTrue(claimBody.contains("isSummoningWorkVoiceCapture = true"), claimBody)
        XCTAssertTrue(
            claimBody.contains("setPopoverVisibleConversation(nil)"),
            "The claim is what takes the thread off screen; a claim that only raised a flag would let "
            + "the summon mark it read anyway: \(claimBody)"
        )
        XCTAssertTrue(
            coordinator.contains(
                "var workCaptureIsActive: Bool { if isSummoningWorkVoiceCapture "
                + "|| isStartingWorkVoiceCapture { return true }"
            ),
            "`showPopover` stands down on `workCaptureIsActive`, so the claim is only worth making "
            + "while that property counts it."
        )

        let begin = try RefusalLaneSource.body(
            ofFunction: "beginWorkVoiceCapture",
            in: coordinator,
            path: Self.coordinatorPath
        )
        guard let handover = begin.range(of: "isSummoningWorkVoiceCapture = false"),
              let reentrancy = begin.range(of: "guard !workCaptureIsActive else") else {
            return XCTFail("The start no longer takes the claim over: \(begin.prefix(400))")
        }
        XCTAssertTrue(
            handover.upperBound < reentrancy.lowerBound,
            "The start has to take the claim over BEFORE its own re-entrancy guard reads it, or every "
            + "⌃⌘W refuses the capture its own press claimed the popover for: \(begin.prefix(400))"
        )
    }

    /// The two Work receipts are not interchangeable.
    ///
    /// A TYPED note is inert: the words were written on the desk's own surface
    /// and nothing carried them anywhere, so "Nothing was sent" is true. A
    /// SPOKEN one was just transcribed by the speech provider the person
    /// configured, and `STTClient`'s roster is mostly cloud vendors — so the
    /// same sentence there denies the upload that produced the words on screen,
    /// which is the one claim a privacy surface may never make.
    func testTheVoiceReceiptNamesItsSpeechProviderAndTheTypedNoteKeepsItsInertness() throws {
        let source = try Self.squeezedSource(at: Self.coordinatorPath)

        let spokenPath = try RefusalLaneSource.body(
            ofFunction: "noteWorkCaptureFinished",
            in: source,
            path: Self.coordinatorPath
        )
        XCTAssertTrue(
            spokenPath.contains("\"workboard.menuBar.voice.saved\""),
            "The voice completion no longer prints its own receipt: \(spokenPath.prefix(400))"
        )
        XCTAssertFalse(
            spokenPath.contains("\"workboard.menuBar.saved\""),
            "The voice completion borrowed the typed note's receipt, which denies the transcription "
            + "that just happened: \(spokenPath.prefix(400))"
        )

        let typedPath = try RefusalLaneSource.body(
            ofFunction: "saveQuickDraftToWork",
            in: source,
            path: Self.coordinatorPath
        )
        XCTAssertTrue(
            typedPath.contains("\"workboard.menuBar.saved\""),
            "The typed note's receipt is true and stays: \(typedPath.prefix(400))"
        )
        XCTAssertFalse(
            typedPath.contains("\"workboard.menuBar.voice.saved\""),
            "…and it may not borrow the voice line either — nothing was handed to a speech provider "
            + "here: \(typedPath.prefix(400))"
        )

        let strings = try Self.catalogStrings()
        let spoken = try XCTUnwrap(
            Self.englishValue(strings["workboard.menuBar.voice.saved"]),
            "workboard.menuBar.voice.saved has no English row — the source default would ship "
            + "untranslatable"
        ).lowercased()
        XCTAssertTrue(
            spoken.contains("speech provider"),
            "The voice receipt has to name where the audio actually went: \(spoken)"
        )
        for denial in ["nothing was sent", "nothing is sent", "nothing leaves"] {
            XCTAssertFalse(
                spoken.contains(denial),
                "The recording was handed to the configured speech provider, so this receipt may not "
                + "deny it: \(spoken)"
            )
        }

        let typed = try XCTUnwrap(
            Self.englishValue(strings["workboard.menuBar.saved"]),
            "workboard.menuBar.saved has no English row"
        ).lowercased()
        XCTAssertTrue(
            typed.contains("nothing was sent"),
            "The typed note's inertness promise is TRUE and is the reason the lane exists: \(typed)"
        )
    }

    // MARK: - The Work screenshot has its own slot, and it never leaves the desk

    /// `pendingCaptureImage` is handed to the gateway as a
    /// `PendingAttachment.image` on the next chat turn. A ⌃⌘W screenshot parked
    /// there would therefore be uploaded by an Ask made minutes later — the
    /// word-level leak the two-composition design already prevents, except a
    /// picture of somebody's screen carries far more than they typed. So the
    /// chat send path may not so much as NAME the Work slot.
    func testTheChatSendPathCannotSeeTheWorkScreenshotSlot() throws {
        let source = try Self.squeezedSource(at: Self.coordinatorPath)

        for lane in ["handleQuickSend", "sendQuickTypedDraft", "handleTranscript", "typeInsteadFromCapture"] {
            let body = try RefusalLaneSource.body(
                ofFunction: lane,
                in: source,
                path: Self.coordinatorPath
            )
            XCTAssertFalse(
                body.contains("pendingWorkCaptureImage"),
                "`\(lane)` names the Work screenshot slot. Everything on this path ends at a gateway, "
                + "and the desk's picture is the one thing on this surface that may never get there: "
                + "\(body.prefix(300))"
            )
        }

        // Control: the chat lane still attaches its OWN screenshot, or the
        // assertions above are satisfied by a lane that attaches nothing.
        let send = try RefusalLaneSource.body(
            ofFunction: "handleQuickSend",
            in: source,
            path: Self.coordinatorPath
        )
        XCTAssertTrue(
            send.contains("pendingCaptureImage.map { [.image($0)] }"),
            "The ⌘⇧2 screenshot no longer rides its own turn: \(send.prefix(300))"
        )
    }

    /// One method serves both doors to the desk — the ⌃⌘W surface's Return and
    /// the Chat surface's "Add to Work" button — so it has to take the picture
    /// from the slot the AIM owns. A fixed slot publishes one composition's
    /// image under the other one's words in one direction, and silently drops
    /// the ⌘⇧2 screenshot that was the whole reason for the press in the other.
    func testTheDeskCommitTakesThePictureFromTheSlotItsAimOwns() throws {
        let source = try Self.squeezedSource(at: Self.coordinatorPath)
        let body = try RefusalLaneSource.body(
            ofFunction: "saveQuickDraftToWork",
            in: source,
            path: Self.coordinatorPath
        )
        XCTAssertTrue(
            body.contains(
                "let screenshotAtCommit = aimAtCommit == .work "
                + "? pendingWorkCaptureImage : pendingCaptureImage"
            ),
            "The commit reads one fixed image slot regardless of where the surface is aimed: "
            + "\(body.prefix(400))"
        )
        XCTAssertTrue(
            body.contains("if pendingWorkCaptureImage == screenshotAtCommit { clearPendingWorkCaptureImage() }"),
            "The Work picture is not consumed by the save that published it, so a second Return files "
            + "it again: \(body.prefix(400))"
        )
    }

    /// The bytes that actually reach the desk are the RECORDER's, staged before
    /// the microphone comes up. The coordinator's own slot is the HUD thumbnail
    /// and nothing more — a capture whose picture were published from here would
    /// lose it to any crash between the stop and the write.
    func testTheWorkVoiceStartStagesItsPictureOnTheRecorderFirst() throws {
        let source = try Self.squeezedSource(at: Self.coordinatorPath)
        let body = try RefusalLaneSource.body(
            ofFunction: "beginWorkVoiceCapture",
            in: source,
            path: Self.coordinatorPath
        )
        guard let reentrancy = body.range(of: "guard !workCaptureIsActive else"),
              let hud = body.range(of: "pendingWorkCaptureImage = screenshot"),
              let staged = body.range(of: "workVoiceRecorder.stageWorkScreenshot(screenshot)"),
              let microphone = body.range(of: "await workVoiceRecorder.startRecording()") else {
            return XCTFail("The start no longer stages its screenshot: \(body.prefix(500))")
        }
        XCTAssertTrue(
            reentrancy.upperBound < hud.lowerBound,
            "A refused second press stages its picture anyway, repainting the RUNNING capture's "
            + "thumbnail with a region belonging to words nobody is recording: \(body.prefix(400))"
        )
        XCTAssertTrue(
            staged.upperBound < microphone.lowerBound,
            "The recorder is handed the picture AFTER the microphone comes up, which loses it on "
            + "every start that is cancelled under its own suspension: \(body.prefix(400))"
        )
    }

    /// A cancel drops the picture with the words; a FAILURE keeps it. An
    /// unfinished capture still owns a card and the Try Again that completes it,
    /// and the thumbnail is what says which capture that is.
    func testTheWorkPictureIsDroppedByACancelAndKeptByAFailure() throws {
        let source = try Self.squeezedSource(at: Self.coordinatorPath)

        let cancel = try RefusalLaneSource.body(
            ofFunction: "cancelWorkVoiceCapture",
            in: source,
            path: Self.coordinatorPath
        )
        XCTAssertTrue(
            cancel.contains("if workCaptureIsActive { clearPendingWorkCaptureImage() }"),
            "The cancel either keeps a torn-down capture's picture or takes a PARKED composition's "
            + "along with it — `cancelActiveCapture` bails both lanes on one press, so an Esc typed "
            + "over the Chat surface arrives here too: \(cancel.prefix(300))"
        )

        let finished = try RefusalLaneSource.body(
            ofFunction: "noteWorkCaptureFinished",
            in: source,
            path: Self.coordinatorPath
        )
        guard let success = finished.range(of: "guard case .success = result else { return }"),
              let cleared = finished.range(of: "clearPendingWorkCaptureImage()") else {
            return XCTFail("The completion no longer retires the thumbnail: \(finished.prefix(400))")
        }
        XCTAssertTrue(
            success.upperBound < cleared.lowerBound,
            "The thumbnail is cleared on a FAILURE too, which strips the picture off the unfinished "
            + "capture whose Try Again is still on screen: \(finished.prefix(400))"
        )
    }

    // MARK: - A failure holds the surface until it is dismissed

    /// The HUD owes a failed capture an ACCOUNT, not a Try Again.
    ///
    /// A capture can fail with nothing to retry and plenty to report: an
    /// audio-less recording still publishes its screenshot, so "the picture is
    /// on your desk, the recording was empty" is precisely the sentence that
    /// goes missing if the surface stands down for want of retry debt. Gating
    /// the HUD on `canRetryWorkCapture` made the receipt's truthfulness depend
    /// on whether it happened to be actionable.
    func testEveryWorkErrorHoldsTheHUDRegardlessOfRetryDebt() throws {
        let source = try Self.squeezedSource(at: Self.coordinatorPath)
        let body = try Self.propertyBody("workCaptureIsActive", in: source)
        XCTAssertTrue(
            body.contains("case .recording, .processing, .preparingVoice, .error: return true"),
            "`.error` no longer holds the surface unconditionally, so a terminal failure with no "
            + "retry debt draws nothing at all — the router's Work arm never fires and the person is "
            + "told neither what reached the desk nor what did not: \(body)"
        )
        XCTAssertFalse(
            body.contains("canRetryWorkCapture"),
            "The HUD is gated on retry debt again. Whether a failure is ACTIONABLE and whether it "
            + "must be REPORTED are two different questions, and this one answers the second: \(body)"
        )

        // The ✕ is what takes it down, so the dismissal has to reach `.idle` —
        // otherwise the surface this test just pinned open can never close.
        let cancel = try RefusalLaneSource.body(
            ofFunction: "cancelWorkVoiceCapture",
            in: source,
            path: Self.coordinatorPath
        )
        XCTAssertTrue(
            cancel.contains("case .error: workVoiceRecorder.discardPendingWorkCapture()"),
            "The ✕ no longer drops the failed capture. It must do BOTH things the surface needs: "
            + "reach `.idle` (or the rule above pins the HUD open forever) and let the capture go "
            + "(or its Try Again is offered to the next ⌃⌘W as that capture's own). The durable "
            + "retry entry is the recovery and outlives this popover: \(cancel.prefix(400))"
        )
        XCTAssertTrue(
            cancel.contains("if workCaptureIsActive { clearPendingWorkCaptureImage() }"),
            "…and the dismissed receipt's thumbnail goes with it — `.error` now counts as active, so "
            + "this is the line that retires the picture: \(cancel.prefix(400))"
        )

        // `restartWorkVoiceCapture` is the deliberate exception: it holds the
        // capture until the replacement microphone is live, so a refused start
        // leaves the first capture and its Try Again exactly where they were.
        let restart = try RefusalLaneSource.body(
            ofFunction: "restartWorkVoiceCapture",
            in: source,
            path: Self.coordinatorPath
        )
        XCTAssertTrue(
            restart.contains("workVoiceRecorder.dismissError()"),
            "Start-over now DISCARDS the capture it is replacing, so a refused replacement leaves "
            + "the person with neither recording: \(restart)"
        )
        XCTAssertFalse(
            restart.contains("discardPendingWorkCapture"),
            "Start-over must not drop the capture before its replacement exists: \(restart)"
        )
    }

    /// The retry debt still decides ONE thing, moved to where it belongs: what a
    /// second ⌃⌘W means. A capture that owes a transcript is finished by it; a
    /// receipt is dismissed by it and the press goes on to take the capture the
    /// person actually asked for.
    func testADeadWorkErrorYieldsToAFreshPress() throws {
        let coordinator = try Self.squeezedSource(at: Self.coordinatorPath)
        let terminal = try Self.propertyBody("workCaptureErrorIsTerminal", in: coordinator)
        XCTAssertTrue(
            terminal.contains("return !workVoiceRecorder.canRetryWorkCapture"),
            "`workCaptureErrorIsTerminal` no longer asks whether anything is left to finish: \(terminal)"
        )

        let press = try RefusalLaneSource.body(
            ofFunction: "handleWorkCapturePress",
            in: try Self.squeezedSource(at: Self.controllerPath),
            path: Self.controllerPath
        )
        guard let dead = press.range(of: "coordinator.workCaptureErrorIsTerminal"),
              let active = press.range(of: "coordinator.workCaptureIsActive") else {
            return XCTFail("The press no longer separates a receipt from a capture: \(press.prefix(500))")
        }
        XCTAssertTrue(
            dead.upperBound < active.lowerBound,
            "The dead-error arm is asked AFTER the active check, which now answers true for every "
            + "error — so the press is swallowed and ⌃⌘W is inert until the ✕ is found: "
            + "\(press.prefix(500))"
        )
        let arm = String(press[dead.upperBound..<active.lowerBound])
        XCTAssertTrue(
            arm.contains("coordinator.cancelWorkVoiceCapture()"),
            "The dead error is not dismissed, so the fresh capture starts underneath a stale "
            + "failure: \(arm)"
        )
        XCTAssertFalse(
            arm.contains("return"),
            "The dead-error arm RETURNS instead of falling through. Dismissing without capturing "
            + "spends the press on housekeeping the person did not ask for: \(arm)"
        )
    }

    /// EVERY Chat door leaves the Work surface, and leaves it the same way.
    ///
    /// A Work-only composition survives every dismissal by design, so it is
    /// still standing when the next command arrives. If that command is one of
    /// Chat's, the aim has to come back with it: otherwise Return saves the
    /// question to the desk instead of sending it, and a ⌘⇧2 region is
    /// invisible on the way there, because the Work surface's thumbnail reads
    /// the Work slot rather than the Chat one.
    ///
    /// `closeWorkOnlyCompose` and not `discardWorkOnlyCompose`: these are
    /// navigations. The parked words and picture are re-entered by the next
    /// ⌃⌘W, and losing them to a command aimed somewhere else is the exact
    /// failure the aim-travels-with-the-words design exists to prevent.
    func testEveryChatDoorLeavesTheWorkSurfaceWithoutDiscardingIt() throws {
        let controller = try Self.squeezedSource(at: Self.controllerPath)

        for door in ["handleShortcutPress", "handleRegionCapturePress", "openPopoverForTyping"] {
            let body = try RefusalLaneSource.body(
                ofFunction: door,
                in: controller,
                path: Self.controllerPath
            )
            guard let leave = body.range(of: "coordinator.closeWorkOnlyCompose()") else {
                return XCTFail(
                    "`\(door)` opens Chat's surface without leaving the Work one. The composition "
                    + "outlives every dismissal, so it is still aimed at the desk when this command "
                    + "arrives — and its Return then saves what the person asked to send: "
                    + "\(body.prefix(500))"
                )
            }
            XCTAssertFalse(
                body.contains("discardWorkOnlyCompose"),
                "`\(door)` DISCARDS the Work composition. A command aimed at Chat may not throw away "
                + "words written for the desk: \(body.prefix(400))"
            )
            // The aim has to be right before the surface this command draws, or
            // the popover renders a frame of the desk over a question. Asserted
            // over what FOLLOWS the correction rather than over the function's
            // first summon: `handleRegionCapturePress` opens with a
            // gateway-refusal arm that shows the popover and returns, and that
            // arm is not the one this rule is about.
            XCTAssertTrue(
                body[leave.upperBound...].contains("showPopover()"),
                "`\(door)` corrects the aim but never summons the surface afterwards, so the "
                + "correction lands on a popover that is already showing the desk: \(body.prefix(400))"
            )
            // …and before the Chat picture is staged, or the thumbnail well the
            // surface draws is still the Work one.
            if let staged = body.range(of: "coordinator.setPendingCaptureImage(") {
                XCTAssertLessThan(
                    leave.upperBound, staged.lowerBound,
                    "`\(door)` stages the Ask screenshot while the surface is still aimed at the "
                    + "desk, where nothing draws it: \(body.prefix(400))"
                )
            }
        }
    }

    // MARK: - Catalog access (the shipped row, not the source default)

    /// The `strings` table of the app target's catalog. Read from disk because
    /// the catalog's `en` value wins over a source `defaultValue:` at runtime —
    /// a guard that resolved the string would prove nothing about the row that
    /// ships.
    private static func catalogStrings() throws -> [String: Any] {
        let url = RefusalLaneSource.projectContainerURL
            .appendingPathComponent("Conduck/Localizable.xcstrings")
        let json = try JSONSerialization.jsonObject(with: try Data(contentsOf: url)) as? [String: Any]
        return try XCTUnwrap(json?["strings"] as? [String: Any], "the catalog has no strings table")
    }

    private static func englishValue(_ entry: Any?) -> String? {
        guard let entry = entry as? [String: Any],
              let localizations = entry["localizations"] as? [String: Any],
              let english = localizations["en"] as? [String: Any],
              let unit = english["stringUnit"] as? [String: Any] else { return nil }
        return unit["value"] as? String
    }
}
