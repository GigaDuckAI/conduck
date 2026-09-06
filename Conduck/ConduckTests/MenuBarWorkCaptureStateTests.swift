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

    /// `.idle` means TWO things on the desk sheet, and only one of them is a
    /// startup.
    ///
    /// "Cancel Transcription" is answered by the recorder with `.idle` and no
    /// banner — correctly, because nothing failed and the recording it published
    /// is already a card. The sheet then drew "Starting the microphone…" over a
    /// microphone that was not starting, with `EmptyView()` for controls: a dead
    /// end on a capture whose Try Again was still live (`canRetryWorkCapture`
    /// stays true, and the words are still buyable). So the press is remembered,
    /// the two idles are rendered apart, and the capture's own action is on
    /// screen in the one the person is looking at.
    ///
    /// Source, because SwiftUI state cannot be driven headlessly here — and the
    /// regression is a rendering branch, not a value any seam exposes.
    func testTheDeskSheetRendersAStoppedTranscriptionApartFromAStartup() throws {
        let sheet = try Self.squeezedSource(at: "Conduck/Views/Workboard/WorkboardVoiceCaptureView.swift")

        XCTAssertTrue(
            sheet.contains(Self.squeezedLiteral("""
            if case .unknown(let underlying) = error, underlying is CancellationError {
                if recorder.canRetryWorkCapture {
                    transcriptionStopped = true
                } else {
                    onCancel()
                }
                return
            }
            """)),
            """
            The sheet ignores the recorder's cancellation answer again. `.idle` then renders the             startup line and no controls at all, over a capture that still owns a card, a             reservation and a Try Again.
            """
        )
        XCTAssertTrue(
            sheet.contains(Self.squeezedLiteral("if transcriptionStopped, recorder.canRetryWorkCapture {")),
            "The stopped state no longer offers the capture's own action, so the dead end is back."
        )
        XCTAssertTrue(
            sheet.contains(Self.squeezedLiteral("if transcriptionStopped { Text(LocalizedStringResource( \"workboard.voice.stopped.title\"")),
            "The stopped state no longer says what happened; it reads as a microphone starting."
        )
        XCTAssertTrue(
            sheet.contains(Self.squeezedLiteral("transcriptionStopped = false")),
            "Nothing clears the flag, so one stopped transcription relabels every later startup."
        )

        // NEGATIVE CONTROL: the shape this replaced — a failure arm that reads
        // no cancellation at all — must fail the first assertion above.
        let deaf = Self.squeezedLiteral("""
        case .failure:
            break
        """)
        XCTAssertFalse(
            deaf.contains(Self.squeezedLiteral("underlying is CancellationError")),
            "Control: the arm that dropped the result must FAIL this guard."
        )
    }

    // MARK: - Wiring (source shape — the popover cannot be mounted here)

    private static let popoverPath = "Conduck/MenuBar/DictationPopoverView.swift"
    private static let coordinatorPath = "Conduck/MenuBar/MenuBarCoordinator.swift"
    private static let controllerPath = "Conduck/MenuBar/MenuBarController.swift"

    /// Comments cannot satisfy any assertion below, and neither can formatting:
    /// every check runs over comment-stripped, whitespace-squeezed source.
    /// The same normalisation `squeezedSource` applies, over a literal — so a
    /// negative control is measured by exactly the reader the assertions use.
    private static func squeezedLiteral(_ source: String) -> String {
        RefusalLaneSource.stripComments(source)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

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

    /// The Work HUD leads the router — except while the Ask microphone is live.
    ///
    /// The two lanes are exclusive at the MICROPHONE, not at the surface:
    /// `workCaptureIsActive` stays true through a Work transcription and through
    /// a standing retryable error, both of which own no microphone, and ⌘⇧1 is
    /// gated on the live Work mic rather than on the HUD. So an Ask recording
    /// really can be running underneath a Work HUD — with its timer, its ✕ and
    /// its "you are being recorded" signal all hidden behind it, and the status
    /// item's click (which already resolves the live lane first) stopping and
    /// SENDING a recording nobody could see.
    func testTheWorkHUDIsTheFirstArmUnlessTheAskMicrophoneIsLive() throws {
        let source = try Self.squeezedSource(at: Self.popoverPath)
        guard let router = source.range(of: "private var content: some View {") else {
            return XCTFail("no `content` router in \(Self.popoverPath)")
        }
        let head = String(source[router.upperBound...].prefix(260))
        XCTAssertTrue(
            head.contains(
                "if coordinator.workCaptureIsActive, service.state != .recording { workCaptureView } "
                + "else if service.state == .recording { recordingStatusView }"
            ),
            "The Work HUD outranks a LIVE Ask microphone. A live microphone with no surface is the "
                + "one state the popover may never draw: the recording cannot be seen or stopped, and "
                + "the click that would stop it sends it instead. It still leads every other state — a "
                + "⌃⌘W capture has no other surface anywhere. Router head: \(head)"
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

    /// …and it refuses again for a composition ALREADY on its way to the desk.
    ///
    /// The Chat surface's "Add to Work" button commits across an await with the
    /// popover interactive and the words still in their slot (they are consumed
    /// on the way back). The Ask button is disabled for exactly that window —
    /// but Return does not read the button, so without this guard the same words
    /// and the ⌘⇧2 screenshot filed with them leave as a gateway turn, under a
    /// receipt that is about to say nothing was sent.
    func testTheSendPathRefusesWhileTheDeskCommitIsStillRunning() throws {
        let source = try Self.squeezedSource(at: Self.coordinatorPath)
        let body = try RefusalLaneSource.body(
            ofFunction: "sendQuickTypedDraft",
            in: source,
            path: Self.coordinatorPath
        )
        let refusal = try XCTUnwrap(
            body.range(of: "guard !isSavingQuickDraftToWork else { return }"),
            "A Return pressed during the desk commit still reaches the gateway: \(body.prefix(400))"
        )
        // …and it refuses BEFORE anything is consumed. Every line below the
        // claim is irreversible — the words are gone from the field and the
        // destination is armed — so a refusal underneath it would block a send
        // that had already eaten the composition.
        let claim = try XCTUnwrap(
            body.range(of: "let generation = beginQuickSend()"),
            "The send no longer claims the gap bridge and its cancellation identity together; "
            + "this guard's anchor needs updating."
        )
        XCTAssertLessThan(
            refusal.upperBound, claim.lowerBound,
            "The refusal sits below the state changes it exists to prevent: \(body.prefix(400))"
        )

        // NEGATIVE CONTROL: the shape before this fix — the aim guard alone —
        // must not satisfy it. The aim still reads `.chat` on the Chat surface's
        // own "Add to Work", which is precisely the door this closes.
        let aimOnly = Self.squeezedLiteral("""
        guard compose.target == .chat else { return }
        let trimmed = quickDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        """)
        XCTAssertFalse(
            aimOnly.contains("guard !isSavingQuickDraftToWork else { return }"),
            "Control: the aim guard alone must FAIL this check — a commit in flight leaves the aim "
            + "on Chat and the words in the field."
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
        // …and it is the ONLY arm that does. A queued envelope has no card to
        // offer yet and a failure has none at all, so a control on either would
        // promise something the desk cannot show. This is what makes the kind a
        // load-bearing value rather than a label.
        XCTAssertEqual(
            row.components(separatedBy: "Button(action: openWorkboard)").count - 1, 1,
            "More than one receipt arm offers to open Work: \(row.prefix(400))"
        )
        for inert in ["case .queued: Label(", "case .failed: Label("] {
            XCTAssertTrue(
                row.contains(inert),
                "The \(inert) arm is no longer an inert label, so a receipt that has imported "
                + "nothing is clickable: \(row.prefix(400))"
            )
        }
        // `Label(` is a SHAPE, not proof of inertness: a `.onTapGesture` hung on
        // one makes a queued receipt open a desk with no card on it, and every
        // assertion above still passes. So the row is asserted to carry no other
        // way to act at all — one control, and it is the Button.
        for actionable in [".onTapGesture", ".onLongPressGesture", ".gesture(", "Button(action:"] {
            let occurrences = row.components(separatedBy: actionable).count - 1
            let allowed = actionable == "Button(action:" ? 1 : 0
            XCTAssertEqual(
                occurrences, allowed,
                "The receipt row grew an interaction beyond its single saved-arm Button "
                + "(`\(actionable)` × \(occurrences)) — the queued and failed arms are inert "
                + "because there is nothing yet to open: \(row.prefix(500))"
            )
        }
        XCTAssertEqual(
            row.components(separatedBy: "openWorkboard").count - 1, 1,
            "The desk is reachable from more than one arm of the receipt, so a row that confirmed "
            + "no card still offers to show one: \(row.prefix(500))"
        )

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

        // …and the drain's ANSWER is what the sentence is chosen from. A
        // swallowed throw makes the ordering above decorative: the banner would
        // still say "Added" after an import that never happened.
        XCTAssertTrue(
            body.contains("let drained: Bool") && body.contains("drained = true") && body.contains("drained = false"),
            "The drain's answer is no longer bound. A `try?` here claims a card on the desk after an "
            + "import that threw: \(body.prefix(600))"
        )
        // …and the binding is only as good as the CALL under it. `try?` with a
        // `drained = true` beneath it satisfies every presence check above while
        // sending the receipt straight back to the claim it was corrected for,
        // so the whole ladder is asserted as one shape.
        XCTAssertTrue(
            body.contains(Self.squeezedLiteral("""
            do {
                _ = try await WorkCaptureDrainer(
                    sourceDevice: SourceDevice.current
                ).drainAvailableCaptures()
                drained = true
            } catch {
                drained = false
            }
            """)),
            "The drain is no longer an unswallowed `try await` whose throw sets `drained = false`: "
            + "\(body.prefix(600))"
        )
        XCTAssertFalse(
            body.contains("try? await WorkCaptureDrainer"),
            "The drain swallows its own throw again, which makes the `catch` below it unreachable and "
            + "every sentence chosen from `drained` a claim about an import nobody checked: "
            + "\(body.prefix(600))"
        )
        XCTAssertTrue(
            body.contains("quickWorkCaptureFeedback = landed ?"),
            "The receipt no longer branches on the drain: \(body.prefix(600))"
        )

        // …AND THE DRAIN'S ANSWER IS STILL NOT ABOUT THIS CAPTURE. It imports
        // whatever it can claim; the desk's own observer may have claimed this
        // envelope first, leaving this drain nothing to do and no way to know
        // whether that other import then failed and put the envelope back. So
        // the card is asked for BY NAME, and only a desk that answers yes earns
        // the "Added" sentence.
        XCTAssertTrue(
            body.contains("let published = try await WorkCaptureInbox.shared.publishAppCapture("),
            "The publication's capture id is discarded again, so there is no name to ask the desk "
            + "for: \(body.prefix(700))"
        )
        XCTAssertTrue(
            body.contains(Self.squeezedLiteral("""
            let landed = drained
                ? await deskHoldsWorkMaterial(
                    published,
                    expecting: screenshotAtCommit == nil ? .note : .image
                )
                : false
            """)),
            "The receipt no longer confirms the card against the desk — a successful EMPTY drain "
            + "still prints \"Added to Work\", or it confirms an id without the kind that tells "
            + "this capture's card from the unrelated occupant its import was refused for: "
            + "\(body.prefix(700))"
        )
        guard let drainRange = body.range(of: "drainAvailableCaptures()"),
              let confirm = body.range(of: "deskHoldsWorkMaterial(") else {
            return XCTFail("The drain/confirm pair is gone: \(body.prefix(700))")
        }
        XCTAssertTrue(
            drainRange.upperBound < confirm.lowerBound,
            "The desk is read before the drain that would put the card there: \(body.prefix(700))"
        )

        // NEGATIVE CONTROL for the confirmation: the shape this replaced — the
        // drain's own answer used directly — keeps every ordering assertion
        // above and is exactly the defect.
        let unconfirmed = Self.squeezedLiteral("""
        quickWorkCaptureFeedback = drained
            ? MenuBarWorkCaptureFeedback(kind: .saved, message: "")
            : MenuBarWorkCaptureFeedback(kind: .queued, message: "")
        """)
        XCTAssertFalse(
            unconfirmed.contains("deskHoldsWorkMaterial("),
            "Control: a receipt chosen from the drain alone must FAIL this guard — envelope "
            + "survival is not card arrival."
        )
        XCTAssertTrue(
            body.contains("workboard.menuBar.savedQueued"),
            "The thrown-drain sentence is gone, so the only thing left to say is the one claim that "
            + "is not true yet: \(body.prefix(600))"
        )

        // NEGATIVE CONTROL: the mutation the presence checks alone accept — the
        // branching scaffolding kept, the throw swallowed. `try?` cannot throw,
        // so `drained` is always true, the `catch` is dead code, and "Added" is
        // said after an import that failed. It must fail the two checks above.
        let swallowed = Self.squeezedLiteral("""
        let drained: Bool
        do {
            _ = try? await WorkCaptureDrainer(
                sourceDevice: SourceDevice.current
            ).drainAvailableCaptures()
            drained = true
        } catch {
            drained = false
        }
        """)
        XCTAssertTrue(
            swallowed.contains("let drained: Bool") && swallowed.contains("drained = false"),
            "Control: the swallowed shape keeps every binding the presence checks look for, which is "
            + "why they were not enough."
        )
        XCTAssertFalse(
            swallowed.contains(Self.squeezedLiteral("""
            do {
                _ = try await WorkCaptureDrainer(
                    sourceDevice: SourceDevice.current
                ).drainAvailableCaptures()
                drained = true
            } catch {
                drained = false
            }
            """)),
            "Control: a swallowed drain must FAIL the shape assertion."
        )
        XCTAssertTrue(
            swallowed.contains("try? await WorkCaptureDrainer"),
            "Control: …and it is caught by name, so the mutation cannot pass by reformatting."
        )
    }

#if os(macOS)
    /// The receipt's confirmation, DRIVEN rather than read from source.
    ///
    /// The guards above require the helper to be CALLED; they say nothing about
    /// what it confirms, and inverting its predicate left every one of them
    /// green. What it has to answer is "did THIS capture's card arrive", and an
    /// id alone cannot: both ids a capture may be published under can be held by
    /// cards of another kind — which is precisely why the desk refuses the
    /// import and the drainer retires the capture, reporting success. The kind
    /// is what tells an occupant from an arrival, and the escape id is where a
    /// capture that survived one collision actually stands.
    @MainActor
    func testTheReceiptConfirmsThisCapturesOwnCardRatherThanWhateverHoldsItsID() async throws {
        let store = ConversationStore(inMemory: true)
        let coordinator = MenuBarCoordinator(conversationStore: store)
        let capture = UUID()

        let onEmptyDesk = await coordinator.deskHoldsWorkMaterial(capture, expecting: .note)
        XCTAssertFalse(onEmptyDesk, "control: an empty desk confirms nothing")

        // The collision itself: an unrelated card of another kind standing under
        // this capture's id. The drainer refuses the import, retires the capture
        // and returns a successful report — so this read is the only thing
        // between a refused capture and the sentence "Added to Work".
        _ = try await store.upsertDeskMaterial(
            WorkMaterialDraft(
                id: capture,
                kind: .link,
                title: "somebody else's card",
                urlString: "https://example.com",
                storageMode: .metadataOnly
            )
        )
        let occupied = await coordinator.deskHoldsWorkMaterial(capture, expecting: .note)
        XCTAssertFalse(
            occupied,
            """
            MEASURED: an unrelated card standing under this capture's id was read as this \
            capture's arrival. That id being occupied is exactly WHY the import was refused, so \
            the receipt says "Added to Work" about a capture the queue threw away.
            """
        )

        // …and the capture's own card, under the escape id a refusal derives.
        // It is on the desk under a name the publication never returned, so a
        // read that asked only about the primary id would call it queued for
        // ever.
        let escaped = WorkMaterialCollisionEscape.materialID(forCapture: capture)
        _ = try await store.upsertDeskMaterial(
            WorkMaterialDraft(
                id: escaped,
                kind: .note,
                title: "the note that escaped",
                textContent: "the note that escaped",
                storageMode: .metadataOnly
            )
        )
        let escapedConfirms = await coordinator.deskHoldsWorkMaterial(capture, expecting: .note)
        XCTAssertTrue(
            escapedConfirms,
            "a capture republished under its escape id IS on the desk, whatever holds its first id"
        )

        // The payload half: a screenshot card with no picture behind it has not
        // arrived in any sense a person would recognise.
        let pictureless = UUID()
        _ = try await store.upsertDeskMaterial(
            WorkMaterialDraft(
                id: pictureless,
                kind: .image,
                title: "a card with no picture",
                storageMode: .metadataOnly
            )
        )
        let emptyImage = await coordinator.deskHoldsWorkMaterial(pictureless, expecting: .image)
        XCTAssertFalse(
            emptyImage,
            "an image card carrying no bytes is not the screenshot this capture published"
        )
    }
#endif

    /// "Added" is a claim about a CARD; a drain that threw put its claim back
    /// and imported nothing, so the only honest sentence there is "on its way".
    /// The envelope is durable either way — nothing is lost — which is exactly
    /// why the wrong word here is a lie rather than a bug report.
    func testTheTypedReceiptSaysQueuedWhenTheDrainThrew() throws {
        let source = try Self.squeezedSource(at: Self.coordinatorPath)
        let body = try RefusalLaneSource.body(
            ofFunction: "saveQuickDraftToWork",
            in: source,
            path: Self.coordinatorPath
        )
        guard let ternary = body.range(of: "quickWorkCaptureFeedback = landed ?"),
              let saved = body.range(of: "\"workboard.menuBar.saved\""),
              let queued = body.range(of: "\"workboard.menuBar.savedQueued\"") else {
            return XCTFail(
                "The receipt no longer chooses between an imported card and a queued envelope: "
                + "\(body.prefix(600))"
            )
        }
        XCTAssertTrue(
            ternary.upperBound <= saved.lowerBound,
            "The \"Added\" sentence sits outside the `drained` branch, so it is said unconditionally: "
            + "\(body.prefix(600))"
        )
        XCTAssertTrue(
            saved.upperBound < queued.lowerBound,
            "The two sentences are the wrong way round — `landed ?` takes the TRUE arm first, so a "
            + "thrown drain would claim the card: \(body.prefix(600))"
        )
        XCTAssertEqual(
            body.components(separatedBy: "\"workboard.menuBar.saved\"").count - 1, 1,
            "The \"Added\" key appears more than once, so one of them is outside the drained branch: "
            + "\(body.prefix(600))"
        )

        // THE KIND IS PART OF EACH ARM, and it is the half the sentence checks
        // above cannot see. `kind` is what the row is BUILT from: `.saved` draws
        // a button whose tooltip says "Open Work and see the new card", `.queued`
        // draws an inert label — so a queued arm carrying `kind: .saved` prints
        // the honest sentence under a control that offers a card the drain did
        // not import. Both arms are therefore asserted whole.
        XCTAssertTrue(
            body.contains(Self.squeezedLiteral("""
            quickWorkCaptureFeedback = landed
                ? MenuBarWorkCaptureFeedback(
                    kind: .saved,
                    message: String(localized: LocalizedStringResource(
                        "workboard.menuBar.saved",
                        defaultValue: "Added to Work. Nothing was sent."
                    ))
                )
                : MenuBarWorkCaptureFeedback(
                    kind: .queued,
                    message: String(localized: LocalizedStringResource(
                        "workboard.menuBar.savedQueued",
                        defaultValue: "On its way to Work. Nothing was sent."
                    ))
                )
            """)),
            "The receipt's two arms are no longer exactly (`.saved`, \"Added\") and (`.queued`, "
            + "\"On its way\"). A kind that does not match its sentence is the defect, not a "
            + "cosmetic one: \(body.prefix(900))"
        )
        XCTAssertEqual(
            body.components(separatedBy: "kind: .queued").count - 1, 1,
            "The queued kind is written a different number of times than the queued sentence, so "
            + "the two can drift: \(body.prefix(900))"
        )

        // NEGATIVE CONTROL for the kind: the mutation every other assertion in
        // this test accepts — the ternary intact, both sentences present and in
        // order, and the FALSE arm relabelled `.saved`.
        let queuedAsSaved = Self.squeezedLiteral("""
        quickWorkCaptureFeedback = landed
            ? MenuBarWorkCaptureFeedback(
                kind: .saved,
                message: String(localized: LocalizedStringResource(
                    "workboard.menuBar.saved",
                    defaultValue: "Added to Work. Nothing was sent."
                ))
            )
            : MenuBarWorkCaptureFeedback(
                kind: .saved,
                message: String(localized: LocalizedStringResource(
                    "workboard.menuBar.savedQueued",
                    defaultValue: "On its way to Work. Nothing was sent."
                ))
            )
        """)
        XCTAssertTrue(
            queuedAsSaved.contains("quickWorkCaptureFeedback = landed ?")
                && queuedAsSaved.contains("\"workboard.menuBar.savedQueued\""),
            "Control: the relabelled shape keeps the ternary and both sentences, which is why the "
            + "sentence checks alone were not enough."
        )
        XCTAssertEqual(
            queuedAsSaved.components(separatedBy: "kind: .queued").count - 1, 0,
            "Control: …and it is caught by the kind, which is the thing the row is built from."
        )

        // NEGATIVE CONTROL: the shape this guard replaced — a discarded `try?`
        // drain and one unconditional sentence — must not satisfy it.
        let discarded = Self.squeezedLiteral("""
        _ = try? await WorkCaptureDrainer(sourceDevice: SourceDevice.current).drainAvailableCaptures()
        quickWorkCaptureFeedback = MenuBarWorkCaptureFeedback(
            kind: .saved,
            message: String(localized: LocalizedStringResource("workboard.menuBar.saved", defaultValue: "Added to Work. Nothing was sent."))
        )
        """)
        XCTAssertFalse(
            discarded.contains("quickWorkCaptureFeedback = landed ?"),
            "Control: a swallowed drain with one unconditional receipt must FAIL this guard."
        )
        XCTAssertFalse(
            discarded.contains("workboard.menuBar.savedQueued"),
            "Control: …and it names no queued sentence, because it has nothing to say one about."
        )
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
                "let stagedAtCommit = aimAtCommit == .work "
                + "? pendingWorkCaptureImage : pendingCaptureImage"
            ),
            "The commit reads one fixed image slot regardless of where the surface is aimed: "
            + "\(body.prefix(400))"
        )
        // …and it CONSUMES that slot synchronously, at the commit, before the
        // publication suspends.
        //
        // A slot is the composition still AVAILABLE to send, and every sender
        // reads the slot rather than the in-flight flag: `handleQuickSend`
        // attaches whatever `pendingCaptureImage` holds, and it is reached
        // during this await by the error footer's Retry and by a ⌘⇧1 transcript
        // alike — neither of which passes through `sendQuickTypedDraft`'s
        // guard. A picture left staged while it is being filed privately is one
        // that reaches a gateway moments later.
        let consumed = Self.squeezedLiteral("""
        switch aimAtCommit {
        case .work: clearPendingWorkCaptureImage()
        case .chat: clearPendingCaptureImage()
        }
        """)
        let consumedRange = try XCTUnwrap(
            body.range(of: consumed),
            "The commit no longer takes the picture out of the composition at the press: "
            + "\(body.prefix(700))"
        )
        let published = try XCTUnwrap(
            body.range(of: "publishAppCapture"),
            "The publication is gone; this guard's ordering anchor needs updating."
        )
        XCTAssertLessThan(
            consumedRange.upperBound, published.lowerBound,
            "The picture is consumed on the way BACK, which leaves it in the slot for the whole "
            + "publication — the window the Retry and the voice turn both send in: \(body.prefix(700))"
        )

        // NEGATIVE CONTROL: the post-await consume this replaced. It is where
        // the leak lived, and it must not come back under either aim.
        for lateConsume in [
            "if pendingCaptureImage == screenshotAtCommit { clearPendingCaptureImage() }",
            "if pendingWorkCaptureImage == screenshotAtCommit { clearPendingWorkCaptureImage() }",
        ] {
            XCTAssertFalse(
                body.contains(Self.squeezedLiteral(lateConsume)),
                "The picture is consumed after the await again (`\(lateConsume)`), so it is still "
                + "attachable throughout the commit: \(body.prefix(700))"
            )
        }

        // …and a FAILED commit gives it back, into an empty slot only: nothing
        // was filed, and half a composition is worse than none, but a picture
        // staged during the await belongs to the next capture.
        //
        // …and when the slot is NOT empty it is HELD rather than dropped. The
        // newer capture keeps the slot, which is right; before this the older
        // one simply ceased to exist — no card, no envelope, no retry entry, no
        // composition reference — while the error banner described a note whose
        // picture it had silently deleted.
        XCTAssertTrue(
            body.contains(Self.squeezedLiteral("""
            if let screenshotAtCommit {
                let held = StalledWorkSave(
                    image: screenshotAtCommit,
                    aim: aimAtCommit,
                    text: draftAtCommit
                )
                switch aimAtCommit {
                case .work:
                    if pendingWorkCaptureImage == nil {
                        setPendingWorkCaptureImage(screenshotAtCommit)
                    } else {
                        stalledWorkSave = held
                    }
                case .chat:
                    if pendingCaptureImage == nil {
                        setPendingCaptureImage(screenshotAtCommit)
                    } else {
                        stalledWorkSave = held
                    }
                }
            }
            """)),
            "A refused publication either eats the screenshot it could not file — which makes the "
            + "transfer above a discard — or holds it without naming whose it is: \(body.prefix(700))"
        )

        // THE HOLD NAMES ITS OWNER, and a commit may take it only on an exact
        // match of BOTH halves: this surface, and these exact words.
        //
        // Unowned, the hold was a shared drawer. A picture staged for the desk
        // and stranded there was handed to the Chat surface's "Add to Work" for
        // unrelated text, and that publication's failure arm then put it into
        // `pendingCaptureImage` — one Return away from a gateway. Desk material
        // reaching a gateway is the one thing this lane exists to make
        // impossible.
        XCTAssertTrue(
            body.contains(Self.squeezedLiteral("""
            let heldForThisCommit: Data? = stalledWorkSave.flatMap {
                $0.aim == aimAtCommit && $0.text == draftAtCommit ? $0.image : nil
            }
            """)),
            "The hold is offered to a composition that does not own it — either half of the "
            + "identity missing is a picture that can wander: \(body.prefix(700))"
        )
        XCTAssertTrue(
            body.contains("let screenshotAtCommit = stagedAtCommit ?? heldForThisCommit"),
            "The held picture is never picked up again, so holding it only delays the loss: "
            + "\(body.prefix(700))"
        )

        // NEGATIVE CONTROL for the identity: the unowned pickup this replaced.
        // It satisfies "the hold is picked up" completely and is exactly the
        // cross-composition leak.
        let unowned = Self.squeezedLiteral(
            "let screenshotAtCommit = stagedAtCommit ?? stalledWorkSave?.image"
        )
        XCTAssertFalse(
            unowned.contains("heldForThisCommit"),
            "Control: a pickup that reads the hold directly must FAIL the assertions above — it "
            + "is how a Work screenshot reached a Chat composition."
        )

        // …and the hold ends when it is TAKEN, not merely because a commit
        // happened. An unconditional clear here is the second half of the same
        // loss: picture A is stranded, picture B claims the slot, the next
        // commit takes B and deletes A with no publication and no discard.
        let takesHeld = try XCTUnwrap(
            body.range(of: Self.squeezedLiteral(
                "if screenshotAtCommit != nil, stagedAtCommit == nil { stalledWorkSave = nil }"
            )),
            "The commit clears the hold whether or not it took it, or no longer clears the hold it "
            + "consumed — one drops a picture nothing else holds, the other files it twice: "
            + "\(body.prefix(700))"
        )
        XCTAssertLessThan(
            takesHeld.upperBound, published.lowerBound,
            "The hold is cleared after the publication, so a second commit racing this one files "
            + "the same picture again: \(body.prefix(700))"
        )

        // NEGATIVE CONTROL for the clear: R3's unconditional form. It keeps the
        // ordering assertion above and is the drop.
        let unconditionalClear = Self.squeezedLiteral("stalledWorkSave = nil")
        XCTAssertFalse(
            unconditionalClear.contains("stagedAtCommit == nil"),
            "Control: an unconditional clear must FAIL the shape assertion above — a hold dropped "
            + "because a newer screenshot exists is a picture that ceases to exist."
        )

        // The hold's OTHER end: the words it belongs to being filed. Gated on
        // `clearCommitted` actually having taken them, because a composition
        // edited during the await keeps its words and therefore keeps its hold.
        XCTAssertTrue(
            body.contains(Self.squeezedLiteral("""
            let filed = compose.clearCommitted(draftAtCommit, aimedAt: aimAtCommit)
            """)),
            "The commit no longer binds whether the words were actually consumed, so the hold "
            + "cannot be released with them: \(body.prefix(700))"
        )
        XCTAssertTrue(
            body.contains(Self.squeezedLiteral("""
            if filed,
               stalledWorkSave?.aim == aimAtCommit,
               stalledWorkSave?.text == draftAtCommit {
                stalledWorkSave = nil
            }
            """)),
            "A hold whose own words have been filed outlives them, so it hangs an old screen over "
            + "whatever note is written next: \(body.prefix(700))"
        )

        // NEGATIVE CONTROL for the failure arm: the arm with no hold at all —
        // it passes every other assertion in this test and is the original loss.
        let dropped = Self.squeezedLiteral("""
        if let screenshotAtCommit {
            switch aimAtCommit {
            case .work:
                if pendingWorkCaptureImage == nil {
                    setPendingWorkCaptureImage(screenshotAtCommit)
                }
            case .chat:
                if pendingCaptureImage == nil {
                    setPendingCaptureImage(screenshotAtCommit)
                }
            }
        }
        """)
        XCTAssertFalse(
            dropped.contains("stalledWorkSave = held"),
            "Control: a failure arm with no hold must FAIL this guard — a slot claimed during the "
            + "await deletes the picture that could not be put back."
        )

        // …and the two explicit discards are AIM-SCOPED. A Chat draft thrown
        // away says nothing about a ⌃⌘W Work draft parked behind it, and a
        // helper that cleared whatever it found would be the shared drawer
        // again, wearing a different name.
        let scopedDiscard = try RefusalLaneSource.body(
            ofFunction: "discardStalledWorkSave",
            in: source,
            path: Self.coordinatorPath
        )
        XCTAssertEqual(
            String(scopedDiscard.dropLast()).trimmingCharacters(in: .whitespaces),
            Self.squeezedLiteral("""
            guard stalledWorkSave?.aim == aim else { return }
            stalledWorkSave = nil
            """),
            "The scoped discard no longer checks the aim it was asked about — a body that clears "
            + "whatever it finds is the shared drawer again: \(scopedDiscard)"
        )
        for (owner, aim) in [("discardWorkOnlyCompose", ".work"), ("cancelActiveCapture", ".chat")] {
            let discardBody = try RefusalLaneSource.body(
                ofFunction: owner,
                in: source,
                path: Self.coordinatorPath
            )
            XCTAssertTrue(
                discardBody.contains(
                    Self.squeezedLiteral("discardStalledWorkSave(aimedAt: \(aim))")
                ),
                "`\(owner)` no longer ends the hold for the composition it discards, or ends it "
                + "for the other one too: \(discardBody.prefix(600))"
            )
        }

        // THE FLAG IS SET, not cleared. `sendQuickTypedDraft`'s Return guard
        // reads it, so `= false` here leaves every source assertion in this
        // suite green while re-opening the Return door whole.
        XCTAssertEqual(
            body.components(separatedBy: "isSavingQuickDraftToWork = true").count - 1, 1,
            "The commit no longer raises its in-flight flag exactly once: \(body.prefix(700))"
        )
        XCTAssertEqual(
            body.components(separatedBy: "isSavingQuickDraftToWork = false").count - 1, 1,
            "…and lowers it exactly once. Two `= false` writes is the shape the raise-to-false "
            + "mutation takes: \(body.prefix(700))"
        )
        let raised = try XCTUnwrap(body.range(of: "isSavingQuickDraftToWork = true"))
        XCTAssertLessThan(
            raised.upperBound, published.lowerBound,
            "The flag is raised after the publication starts, so the window it guards is open "
            + "first: \(body.prefix(700))"
        )
        // …and "before the publication" is not the same as "before the TASK".
        // Everything that takes ownership — the flag and the slot consume — has
        // to commit in the synchronous prologue, or a send arriving between the
        // press and the task's first resumption reads the old composition and a
        // flag that is still false.
        let taskOpen = try XCTUnwrap(
            body.range(of: "Task { @MainActor [weak self] in"),
            "The publication task's opening is gone; this guard's anchor needs updating."
        )
        XCTAssertLessThan(
            raised.upperBound, taskOpen.lowerBound,
            "The in-flight flag is raised INSIDE the task, so Return pressed before it runs sees "
            + "no save in flight: \(body.prefix(700))"
        )
        XCTAssertLessThan(
            consumedRange.upperBound, taskOpen.lowerBound,
            "The picture leaves the composition inside the task, so a send between the press and "
            + "the first resumption still finds it in the slot: \(body.prefix(700))"
        )
    }

    /// A queued RETRY carries no composition — least of all somebody else's
    /// screenshot.
    ///
    /// The footer's Retry replays a recording captured minutes, or launches,
    /// ago. The picture staged in `pendingCaptureImage` at that moment was
    /// dragged for a question still being composed, and the send reads the slot:
    /// so the Retry attached that picture to a gateway turn on unrelated words
    /// AND emptied the slot on its way out. A recovered transcript takes its own
    /// words and nothing else.
    ///
    /// The STASH replay is deliberately not this case: it is the SAME capture
    /// resuming, and its screenshot is its own.
    func testAQueuedRetryCarriesNoCompositionOfItsOwn() throws {
        let source = try Self.squeezedSource(at: Self.coordinatorPath)

        XCTAssertTrue(
            source.contains(Self.squeezedLiteral("""
            await self?.handleRecoveredTranscript(
                transcript,
                sendGeneration: generation
            )
            """)),
            "The recovered-transcript hand-off is no longer wired, so a Retry re-enters the live "
            + "capture's send and takes whatever is staged with it."
        )
        let recovered = try RefusalLaneSource.body(
            ofFunction: "handleRecoveredTranscript",
            in: source,
            path: Self.coordinatorPath
        )
        XCTAssertTrue(
            recovered.contains(Self.squeezedLiteral("""
            await handleQuickSend(
                transcript,
                modality: .voice,
                carriesComposition: false,
                sendGeneration: sendGeneration
            )
            """)),
            "A recovered transcript no longer declares that it owns no composition: \(recovered)"
        )

        // …AND IT KEEPS THAT DECLARATION THROUGH THE STASH. A recovered
        // recording whose destination is busy is parked in `pendingFailedTurn`,
        // and the footer's Retry replays it: a stash case that carried no
        // ownership restored the `true` default on the second hop, so the
        // screenshot staged for a question still being written was attached and
        // its slot emptied — the exact defect the first hop had just been fixed
        // for, one press later.
        XCTAssertTrue(
            source.contains(Self.squeezedLiteral(
                "case voice(transcript: String, carriesComposition: Bool)"
            )),
            "The voice stash no longer remembers whose composition its words own."
        )
        let replay = try RefusalLaneSource.body(
            ofFunction: "retryPendingFailedTurn",
            in: source,
            path: Self.coordinatorPath
        )
        XCTAssertTrue(
            replay.contains(Self.squeezedLiteral("""
            case .voice(let transcript, let carriesComposition):
            """)),
            "The replay no longer reads the ownership the stash recorded: \(replay.prefix(700))"
        )
        XCTAssertTrue(
            replay.contains(Self.squeezedLiteral("""
            await self?.handleQuickSend(
                transcript,
                modality: .voice,
                carriesComposition: carriesComposition,
                sendGeneration: generation
            )
            """)),
            "The replay hands the send a composition claim of its own instead of the one the stash "
            + "carries: \(replay.prefix(700))"
        )
        let stash = try RefusalLaneSource.body(
            ofFunction: "quickStash",
            in: source,
            path: Self.coordinatorPath
        )
        XCTAssertTrue(
            stash.contains(Self.squeezedLiteral(
                "case .voice: return .voice(transcript: text, carriesComposition: carriesComposition)"
            )),
            "The stash drops the ownership it was handed: \(stash)"
        )

        // NEGATIVE CONTROL for the stash: the ownership-free case this replaced.
        // It satisfies every "the first hop declares nothing" assertion above
        // and loses the declaration at the second.
        let forgetful = Self.squeezedLiteral("""
        case .voice(let transcript):
        await self?.handleTranscript(transcript, sendGeneration: generation)
        """)
        XCTAssertFalse(
            forgetful.contains("carriesComposition"),
            "Control: a replay that routes through the composition-carrying hand-off must FAIL the "
            + "assertions above — that is how a recovered recording re-acquires somebody's picture."
        )

        let send = try RefusalLaneSource.body(
            ofFunction: "handleQuickSend",
            in: source,
            path: Self.coordinatorPath
        )
        XCTAssertTrue(
            send.contains("if carriesComposition { clearPendingCaptureImage() }"),
            "The send clears the staged screenshot unconditionally again, so a Retry empties a slot "
            + "the person is still composing with: \(send.prefix(600))"
        )
        XCTAssertTrue(
            send.contains(Self.squeezedLiteral("""
            let attachments: [PendingAttachment] = carriesComposition
                ? (pendingCaptureImage.map { [.image($0)] } ?? [])
                : []
            """)),
            "The attachment is assembled from the slot regardless of who is sending, which is how a "
            + "Retry hands somebody else's screenshot to a gateway: \(send.prefix(900))"
        )
        // The STASH replay keeps its own picture — same capture, same shot — so
        // the default has to stay "carries".
        XCTAssertTrue(
            source.contains("carriesComposition: Bool = true"),
            "The composition default flipped, which silently strips the screenshot from every "
            + "ordinary ⌘⇧2 turn."
        )

        // NEGATIVE CONTROL: the unconditional shapes this replaced.
        let unconditional = Self.squeezedLiteral("""
        let attachments: [PendingAttachment] = pendingCaptureImage.map { [.image($0)] } ?? []
        """)
        XCTAssertFalse(
            unconditional.contains("carriesComposition"),
            "Control: an attachment read straight from the slot must FAIL this guard."
        )
    }

    /// The completion of a Work save may not re-aim a capture armed AFTER it.
    ///
    /// The save ends by resetting the quick destination when the composition
    /// looks empty — one-shot semantics for a pick that was consumed. But an
    /// empty composition says nothing about a ⌘⇧1 armed DURING the publication:
    /// that capture froze its own destination, and clearing it here sends its
    /// words wherever automatic resolution lands instead. The arm generation is
    /// what tells the two apart.
    func testTheDeskCommitCannotResetADestinationArmedAfterIt() throws {
        let source = try Self.squeezedSource(at: Self.coordinatorPath)
        let body = try RefusalLaneSource.body(
            ofFunction: "saveQuickDraftToWork",
            in: source,
            path: Self.coordinatorPath
        )
        let taken = try XCTUnwrap(
            body.range(of: "let armAtCommit = armGeneration"),
            "The commit no longer records the arm it was made under: \(body.prefix(700))"
        )
        let taskOpen = try XCTUnwrap(
            body.range(of: "Task { @MainActor [weak self] in"),
            "The publication task's opening is gone; this guard's anchor needs updating."
        )
        XCTAssertLessThan(
            taken.upperBound, taskOpen.lowerBound,
            "The arm is read inside the task, so it already reflects whatever landed during the "
            + "publication: \(body.prefix(700))"
        )
        XCTAssertTrue(
            body.contains(
                "if armAtCommit == armGeneration, quickDraft.isEmpty, pendingCaptureImage == nil "
                + "{ resetQuickDestinationAfterTurn() }"
            ),
            "The destination reset is no longer bound to the arm that owns it, so a Work save "
            + "completing behind a fresh Ask clears that Ask's frozen pick: \(body.prefix(700))"
        )

        // NEGATIVE CONTROL: the unbound reset this replaced. It reads only the
        // composition, which a newer capture's arm does not touch.
        let unbound = Self.squeezedLiteral("""
        if quickDraft.isEmpty, pendingCaptureImage == nil {
            resetQuickDestinationAfterTurn()
        }
        """)
        XCTAssertFalse(
            unbound.contains("armAtCommit == armGeneration"),
            "Control: a reset that consults only the composition must FAIL this guard."
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
