// SPDX-License-Identifier: Apache-2.0

// Conduck
// OutputHeldBackRowCopyTests.swift
//
// WHICH SENTENCE the file-return surfaces are allowed to say, and about which
// state. `OutputDeliveryOutcomeTests` locks the census itself and
// `OutboxReconcileTests` locks the arithmetic that produces it; this file locks
// the last hop — the one where a true value becomes a string a user reads.
//
// THE BUGS IT EXISTS FOR, every one of them the same bug in different clothes: a
// sentence the code could not prove.
//
//   - ONE SHAPE SENTENCE FOR NINE GUARDS. A name refused only for LENGTH — an
//     agent naming a file after a section heading — or only for a stray leading
//     SPACE was told its name "could be read as an instruction, or hides itself
//     from a listing", which describes an attack that did not happen, to the
//     author of a perfectly honest file.
//   - A CEILING LINE THAT CLAIMED FINALITY WITH A SLOT FREE. `.ceiling` proves
//     at least one file never arrives here, never that none will — and the
//     sentence stood directly above a verb that would then deliver one.
//   - A LOUDER WARNING TRUE OF THE CLASS BUT NOT OF ITS MEMBERS. Macro-enabled
//     Office documents sat in the installer class, whose sentence — "meant to
//     configure, install, or run something rather than to be read" — is false of
//     every one of them.
//   - A DELIVERY REPORTED AS AN EMPTY LOOK, on the tap that had just handed the
//     user their files.
//   - THE REMAINDER'S CAUSE READ OFF `outputScanDone`. That column says the TURN
//     IS CLOSED, and a merely truncated pass closes on AGE — so a recoverable
//     tail was reported as permanently lost, under a "Check again" the same rule
//     had just hidden.
//   - A COUNT THAT OUTLIVED ITS EVIDENCE. The allowlist can widen under a stored
//     census, and the rescue projection already re-asks the verdict; the row did
//     not, so it could print "the folder held 2 files Conduck doesn't open" with
//     no name and no action, over two files about to appear as ordinary chips —
//     and then blame the retention cap for a gap the allowlist had opened.
//   - A TAP ANSWERED WITH SILENCE. Both finding captions were suppressed
//     whenever a standing row was up — including on the row that offers the verb,
//     and including for the root search, which asks about a different place
//     entirely and cannot contradict the row at all.
//
// Deterministic + headless: pure value and string assertions. No network, no
// store, no clock. Synthetic names only, and nothing is logged.

import XCTest
@testable import Conduck

final class OutputHeldBackRowCopyTests: XCTestCase {

    // MARK: - Fixtures

    /// Resolved exactly the way the surfaces resolve them, so a reword lands here
    /// as a failing assertion rather than as silent drift.
    private func text(_ resource: LocalizedStringResource) -> String {
        String(localized: resource)
    }

    private func shapeText(_ line: OutputHeldBackCopy.ShapeLine) -> String {
        text(OutputHeldBackCopy.sentence(for: line))
    }

    /// A reply carrying `chips` server-file attachments and nothing else — the
    /// only thing the copy layer reads a message for.
    private func turn(chips: Int) -> MessageRecord {
        MessageRecord(
            id: UUID(), role: "agent", text: "reply", createdAt: Date(), sourceDevice: "phone",
            outputScanDone: true, outputScanLaneID: "lane", outputBoxKey: "conv/out-box",
            attachments: (0..<chips).map { index in
                AttachmentRecord(
                    id: UUID(), mimeType: "text/plain", filename: "f\(index).txt",
                    thumbnailData: nil, extractedText: nil,
                    width: 0, height: 0, byteSize: 1, sequence: index, createdAt: Date(),
                    isServerReference: true, storedKey: "conv/out-box/f\(index).txt")
            }
        )
    }

    /// The remainder sentences as the row prints them, on a reply holding
    /// `chips` files already. The count is a parameter because the ceiling arm's
    /// wording is chosen from it — see
    /// `testTheCeilingSentenceClaimsFinalityOnlyWhenNoSlotRemains`.
    private func remainderText(
        _ line: OutputHeldBackCopy.RemainderLine,
        chips: Int = 0
    ) -> String {
        OutputHeldBackCopy.sentences(for: line, on: turn(chips: chips))
            .map(text).joined(separator: " ")
    }

    // MARK: - One sentence per shape class, and each one true of its class

    /// THE SPLIT, at the seam where it becomes words. Each class gets its own
    /// sentence, and the sentences are not each other's.
    func testEachShapeRefusalClassGetsItsOwnSentence() {
        let overlong = shapeText(.overlong(count: 1))
        let spaced = shapeText(.whitespaceBounded(count: 1))
        let unusable = shapeText(.unusable(count: 1))
        XCTAssertEqual(Set([overlong, spaced, unusable]).count, 3,
                       "one string covering several classes is the defect this split repairs")

        // The accusation belongs to the class that earned it, and only there. A
        // long, ordinary filename is not an attack, and telling its author it
        // might be is worse than saying nothing.
        for accusation in ["instruction", "hides itself", "hide", "disguis", "pretend"] {
            for benign in [overlong, spaced] {
                XCTAssertFalse(benign.lowercased().contains(accusation),
                               "a benign sentence must not accuse: '\(accusation)' describes a "
                               + "guard that did not fire")
            }
        }
        // And each names the thing that DID fire, in a word the user can act on.
        XCTAssertTrue(overlong.lowercased().contains("long"),
                      "length is the whole of what happened, so length is what it says")
        XCTAssertTrue(unusable.lowercased().contains("instruction"),
                      "the remaining guards keep the sentence that is true of them")
    }

    /// REGRESSION — a name refused for a stray space gets that sentence and no
    /// other. The class exists because the residual's sentence ("could be read
    /// as an instruction, or hides itself from a listing") is an accusation, and
    /// a leading space is an accident an agent can be asked to fix.
    ///
    /// It may name the CHARACTER outright: the scalar-alphabet guard runs first
    /// and only U+0020 survives it, so "a space" is exactly what the code
    /// observed — a hedge to "whitespace" would be weaker than the evidence.
    /// What it may never name is the FILE, and it cannot: the verdict's shape arm
    /// is payload-free.
    func testAStraySpaceRefusalGetsItsOwnSentenceAndCarriesNoName() {
        XCTAssertEqual(FileServerClient.outboxEntryVerdict(" quarterly report.pdf"),
                       .refusedShape(.whitespaceBounded))
        XCTAssertEqual(FileServerClient.outboxEntryVerdict("quarterly report.pdf "),
                       .refusedShape(.whitespaceBounded),
                       "a trailing space is the same accident and the same remedy")

        let spaced = shapeText(.whitespaceBounded(count: 1))
        XCTAssertTrue(spaced.lowercased().contains("space"),
                      "the character is provable, so it is named rather than hedged")
        // The remedy is a REQUEST, not a prediction: Conduck does not trim the
        // stored key, and a space can hide a second refusal behind it.
        XCTAssertTrue(spaced.lowercased().contains("ask your agent"))
        for fragment in ["quarterly", "report", ".pdf"] {
            XCTAssertFalse(spaced.lowercased().contains(fragment),
                           "'\(fragment)' is a byte of the refused name, and the shape arm exists "
                           + "to keep every one of them out of the app's own voice")
        }
    }

    /// A class that did not occur says NOTHING — the row prints a line per
    /// population, never a zero.
    func testOnlyTheClassesThatOccurredGetALine() {
        XCTAssertEqual(OutputHeldBackCopy.shapeLines(for: .nothingRefused), [])
        XCTAssertEqual(
            OutputHeldBackCopy.shapeLines(for: ShapeRefusalCensus(
                overlongCount: 3, whitespaceBoundedCount: 0, unusableCount: 0)),
            [.overlong(count: 3)])
        XCTAssertEqual(
            OutputHeldBackCopy.shapeLines(for: ShapeRefusalCensus(
                overlongCount: 0, whitespaceBoundedCount: 5, unusableCount: 0)),
            [.whitespaceBounded(count: 5)])
        XCTAssertEqual(
            OutputHeldBackCopy.shapeLines(for: ShapeRefusalCensus(
                overlongCount: 0, whitespaceBoundedCount: 0, unusableCount: 2)),
            [.unusable(count: 2)])
        // All three, with the ACTIONABLE ones first: burying a line a user can
        // respond to under one they cannot is the same mistake in a smaller form.
        // Between the two actionable classes the order is the order their guards
        // run in, so the list never reorders under the user between two listings.
        XCTAssertEqual(
            OutputHeldBackCopy.shapeLines(for: ShapeRefusalCensus(
                overlongCount: 1, whitespaceBoundedCount: 2, unusableCount: 4)),
            [.overlong(count: 1), .whitespaceBounded(count: 2), .unusable(count: 4)])
    }

    /// NO CLASS CARRIES A NAME, AND NONE CAN. Asserted structurally rather than
    /// by inspecting a string: the verdict's shape arm returns a payload-free
    /// case, so there is no name at the source to leak, and the census it feeds is
    /// three integers.
    func testNoShapeRefusalCarriesANameOrAnyByteOfOne() {
        let hostile = "../../.ssh/id_rsa"
        let overlong = String(repeating: "n", count: FileServerClient.storedKeyComponentMaxCharacters + 1) + ".pdf"

        for name in [hostile, overlong, " leading.pdf", ".hidden.pdf", "-dash.pdf", ""] {
            guard case .refusedShape(let reason) = FileServerClient.outboxEntryVerdict(name) else {
                XCTFail("a \(name.count)-character name must be shape-refused")
                continue
            }
            // A case with an associated value would show one child here; every
            // arm of `OutboxShapeRefusal` is a constant, so there is nothing for
            // a name to ride out on.
            XCTAssertTrue(Mirror(reflecting: reason).children.isEmpty,
                          "a payload on the shape arm is a name-shaped hole in the one gate that "
                          + "exists to keep a hostile string out of the app's own voice")
        }

        // And the class each guard produces, so a future reshuffle of the guard
        // order cannot silently re-file an accusation as benign or the reverse.
        XCTAssertEqual(FileServerClient.outboxEntryVerdict(overlong), .refusedShape(.overlong))
        XCTAssertEqual(FileServerClient.outboxEntryVerdict(" leading.pdf"),
                       .refusedShape(.whitespaceBounded))
        XCTAssertEqual(FileServerClient.outboxEntryVerdict(hostile), .refusedShape(.unusable))
        XCTAssertEqual(FileServerClient.outboxEntryVerdict(""), .refusedShape(.unusable),
                       "an empty name is unusable, not merely long — the length guard runs first "
                       + "and must not claim it")

        // The rendered sentences carry no fragment of any name.
        for rendered in [shapeText(.overlong(count: 1)),
                         shapeText(.whitespaceBounded(count: 1)),
                         shapeText(.unusable(count: 1))] {
            XCTAssertFalse(rendered.contains("id_rsa"))
            XCTAssertFalse(rendered.contains("ssh"))
            XCTAssertFalse(rendered.contains("nnn"))
        }
    }

    // MARK: - The remainder promises only what a pass proved

    /// THE THREE CAUSES, THREE SENTENCES, and no fallback between them. The
    /// unattributed case is the one a fallback would swallow, in whichever
    /// direction it fell.
    func testTheRemainderSentenceFollowsTheCauseAndNeverTheScanMarker() {
        XCTAssertNil(OutputHeldBackCopy.remainderLine(for: .nothingLeft),
                     "nothing left behind has nothing to report")
        XCTAssertEqual(OutputHeldBackCopy.remainderLine(for: .recoverable(count: 3)),
                       .batching(count: 3))
        XCTAssertEqual(OutputHeldBackCopy.remainderLine(for: .ceilingCapped(count: 3)),
                       .ceiling(count: 3))
        XCTAssertEqual(OutputHeldBackCopy.remainderLine(for: .unknownCause(count: 3)),
                       .unattributed(count: 3))

        let batching = remainderText(.batching(count: 3))
        // The ceiling arm is read at the cap, where its claim is at its
        // strongest — the free-slot arm is the subject of its own test below.
        let ceiling = remainderText(
            .ceiling(count: 3), chips: FileTransferOutputDetector.maxOutputChipsPerMessage)
        let unattributed = remainderText(.unattributed(count: 3))
        XCTAssertEqual(Set([batching, ceiling, unattributed]).count, 3,
                       "three causes, three sentences — a shared string is a shared claim")

        // The PROMISE appears only where a pass proved it.
        XCTAssertTrue(batching.lowercased().contains("picks up more"))
        XCTAssertFalse(ceiling.lowercased().contains("picks up more"))
        XCTAssertFalse(unattributed.lowercased().contains("picks up more"),
                       "an unproven promise is the one thing this case exists to make unspellable")

        // The FINALITY appears only where the arithmetic proved it. It is a claim
        // about THESE files rather than about the reply — the prose lane can
        // still chip a file the reply NAMED, from the served root.
        XCTAssertTrue(ceiling.lowercased().contains("can't bring these back"))
        for hedged in [batching, unattributed] {
            XCTAssertFalse(hedged.lowercased().contains("can't bring these back"),
                           "and neither may be read as final — the unattributed case is hedged in "
                           + "BOTH directions")
        }

        // No arm types the cap as a number. "Conduck shows at most N files from
        // one reply" is not a fact about a reply: `maxOutputChipsPerMessage`
        // bounds the FOLDER lane, while the tap-gated prose lane mints against
        // `maxCandidates` with no message-total check of its own.
        for sentence in [batching, ceiling, unattributed] {
            XCTAssertFalse(
                sentence.contains("\(FileTransferOutputDetector.maxOutputChipsPerMessage)"),
                "the cap is a lane's budget, not a promise about the reply")
        }
    }

    /// REGRESSION — the ceiling line claims finality ONLY when the reply has no
    /// slot left. `.ceiling` proves that AT LEAST ONE file never arrives here; a
    /// reply sitting one slot under the cap still takes one more, and "Check
    /// again" is offered on exactly that condition. A line saying nothing more
    /// will come, directly above a verb that then delivers a file, is the defect.
    ///
    /// Both arms are worded from `admitsMoreChips` — the SAME predicate the verb
    /// is gated on — so the sentence and the button cannot disagree.
    func testTheCeilingSentenceClaimsFinalityOnlyWhenNoSlotRemains() {
        let cap = FileTransferOutputDetector.maxOutputChipsPerMessage
        let withRoom = remainderText(.ceiling(count: 18), chips: cap - 1)
        let atCap = remainderText(.ceiling(count: 18), chips: cap)
        XCTAssertNotEqual(withRoom, atCap,
                          "one sentence for both states is the disagreement this split repairs")

        XCTAssertTrue(withRoom.lowercased().contains("checking again"),
                      "a free slot is a slot — the verb beside this line genuinely delivers")
        XCTAssertFalse(atCap.lowercased().contains("checking again"),
                       "at the cap the folder lane adds nothing further to this reply")

        // The SHORTFALL is the permanent part in both, and the only part both
        // claim: the count is the same sentence on either side.
        for sentence in [withRoom, atCap] {
            XCTAssertTrue(sentence.contains("18"),
                          "the shortfall is what `.ceiling` actually proved")
            XCTAssertTrue(sentence.lowercased().contains("file server"),
                          "and the escape hatch is true whichever arm printed")
        }
    }

    /// "Check again" is gated on what the MESSAGE can still hold, not on what the
    /// last census recorded — the chips are the live fact and they keep arriving
    /// from the user's other devices.
    func testTheRecheckGateIsTheLiveChipCensus() {
        XCTAssertTrue(OutputHeldBackCopy.admitsMoreChips(turn(chips: 0)))
        XCTAssertTrue(OutputHeldBackCopy.admitsMoreChips(
            turn(chips: FileTransferOutputDetector.maxOutputChipsPerMessage - 1)),
            "one free slot is still a slot — the verb can genuinely add a file")
        XCTAssertFalse(OutputHeldBackCopy.admitsMoreChips(
            turn(chips: FileTransferOutputDetector.maxOutputChipsPerMessage)),
            "at the ceiling a re-read spends a request to redraw the same row")
        XCTAssertFalse(OutputHeldBackCopy.admitsMoreChips(
            turn(chips: FileTransferOutputDetector.maxOutputChipsPerMessage + 3)),
            "and an over-full message (a CloudKit merge of two devices' inserts) stays closed")
    }

    // MARK: - A tap is always answered

    /// THE ROOT SEARCH ASKS ABOUT A DIFFERENT PLACE, so its answer cannot
    /// contradict a row about the folder — and going quiet leaves the user unable
    /// to tell a completed search from a tap that missed the button.
    @MainActor
    func testALookThatFoundNothingStillAnswersUnderAStandingRow() throws {
        let underRow = ConversationDetailViewModel.lookResultCaption(
            for: .noneFound(chipCount: 0), hasStandingRow: true)
        XCTAssertNotNil(underRow, "a tap is answered, always")
        let rendered = text(try XCTUnwrap(underRow))

        // It reports what the LOOK did, not what the folder holds — which is the
        // half the row cannot cover and the half that cannot contradict it.
        XCTAssertFalse(rendered.lowercased().contains("no returned files"),
                       "the specific discovery sentence would contradict a row naming a file")
        XCTAssertTrue(rendered.lowercased().contains("nothing new"))

        // With no row up it keeps the richer, specific sentence.
        let alone = ConversationDetailViewModel.lookResultCaption(
            for: .noneFound(chipCount: 0), hasStandingRow: false)
        XCTAssertEqual(text(try XCTUnwrap(alone)), "No returned files were discovered.")
    }

    /// A FOLDER RE-READ THAT CHANGES NOTHING is the commonest tap on the row that
    /// offers the verb, and it must not be the one that says nothing at all.
    @MainActor
    func testAReReadThatChangesNothingStillAnswers() throws {
        for state in [ConversationDetailViewModel.OutputRecheckState.noneFound(chipCount: 2),
                      .undeliverableEntries(count: 4, chipCount: 2)] {
            let caption = ConversationDetailViewModel.lookResultCaption(
                for: state, hasStandingRow: true)
            XCTAssertNotNil(caption, "\(state) is an answer, and the user asked a question")
            XCTAssertEqual(text(try XCTUnwrap(caption)), "Nothing new came back.",
                           "both finding states collapse to the one sentence that is true beside "
                           + "any row — the row already states what the folder holds, and a "
                           + "second copy of its count would print the same file twice")
        }

        // Without a row, the shape count is the more specific true thing and
        // keeps its own sentence.
        let alone = ConversationDetailViewModel.lookResultCaption(
            for: .undeliverableEntries(count: 4, chipCount: 0), hasStandingRow: false)
        XCTAssertTrue(text(try XCTUnwrap(alone)).contains("4"))
    }

    /// REGRESSION — a look that DELIVERED is never reported as an empty one.
    ///
    /// The two zero-delivery sentences are now spellable only from the branch
    /// that inserted nothing, so a pass that minted chips is structurally
    /// incapable of reaching "nothing new came back" — the count is a state the
    /// commit sets, not something a later comparison re-derives.
    ///
    /// Under a standing row the count is the ONLY on-screen proof the tap did
    /// anything: the row repaints identically after a delivery, so silence there
    /// reads as a tap that missed the button.
    @MainActor
    func testALookThatDeliveredFilesIsNeverReportedAsAnEmptyOne() throws {
        let underRow = ConversationDetailViewModel.lookResultCaption(
            for: .delivered(fileCount: 8), hasStandingRow: true)
        let rendered = text(try XCTUnwrap(underRow, "a tap is answered, always"))
        XCTAssertTrue(rendered.contains("8"),
                      "the count is what the commit observed, and the only proof on screen")
        for empty in ["nothing new", "no returned files"] {
            XCTAssertFalse(rendered.lowercased().contains(empty),
                           "'\(empty)' is a claim about a folder that just handed over eight files")
        }

        // With no row up, the new chips ARE the visible change and a clean
        // success has never carried a caption.
        XCTAssertNil(ConversationDetailViewModel.lookResultCaption(
            for: .delivered(fileCount: 8), hasStandingRow: false))
    }

    /// The two states that were never suppressed and must not become so. A look
    /// that could not finish reports what the LOOK did, and a look still running
    /// has nothing to report yet.
    @MainActor
    func testTheNonFindingStatesAreUnchangedByAStandingRow() throws {
        for hasRow in [true, false] {
            XCTAssertEqual(
                text(try XCTUnwrap(ConversationDetailViewModel.lookResultCaption(
                    for: .couldNotCheck, hasStandingRow: hasRow))),
                "Couldn't finish the check just now.",
                "a recorded refusal and a re-read that got no answer are both true at once")
            XCTAssertNil(ConversationDetailViewModel.lookResultCaption(
                for: .checking, hasStandingRow: hasRow))
            XCTAssertNil(ConversationDetailViewModel.lookResultCaption(
                for: nil, hasStandingRow: hasRow),
                "and a clean success has nothing to annotate — the chips are the answer")
        }
    }

    // MARK: - The type arm claims only what today's verdict still proves

    /// A census carrying `count` refusals of which `names` were retained.
    private func typeCensus(count: Int, names: Int) -> OutputDeliveryOutcome {
        OutputDeliveryOutcome(
            typeRefusedCount: count,
            shapeRefused: .nothingRefused,
            remainder: .nothingLeft,
            typeRefusedEntries: (0..<names).map {
                RefusedOutputEntry(name: "clip\($0).mp4", byteSize: 1024)
            }
        )
    }

    /// REGRESSION — the capped line blames the RETENTION CAP only when the cap is
    /// what produced the gap.
    ///
    /// The line exists because the sheet can list fewer files than the count line
    /// claimed, and the user should not have to count. But a WIDENED allowlist
    /// opens the same-looking gap for an entirely different reason, and there the
    /// count line has already dropped to exactly what the sheet lists — so the cap
    /// sentence would attribute a shortfall to the one mechanism that provably did
    /// not cause it.
    func testTheCappedLineBlamesTheCapOnlyWhenTheCapBit() {
        // The census counted five and kept two names; today's verdict still
        // refuses both, so nothing has moved and the cap is the only explanation
        // for the three the sheet cannot list.
        let capped = typeCensus(count: 5, names: 2)
        XCTAssertEqual(OutputHeldBackCopy.claimedTypeCount(capped, stillRefused: 2), 5,
                       "while nothing has moved the census is the better number — it covers the "
                       + "entries the cap kept no name for")
        XCTAssertTrue(OutputHeldBackCopy.blamesRetentionCap(capped, stillRefused: 2))

        // Same stored census, but one of the two retained names is deliverable
        // today. The count line drops to what the sheet lists, so there is no gap
        // left to explain and no cap to name.
        XCTAssertTrue(OutputHeldBackCopy.allowlistWidened(capped, stillRefused: 1))
        XCTAssertEqual(OutputHeldBackCopy.claimedTypeCount(capped, stillRefused: 1), 1)
        XCTAssertFalse(OutputHeldBackCopy.blamesRetentionCap(capped, stillRefused: 1),
                       "the allowlist opened this gap, not the cap")

        // And a census the record retained whole has no shortfall at all.
        let whole = typeCensus(count: 2, names: 2)
        XCTAssertFalse(OutputHeldBackCopy.blamesRetentionCap(whole, stillRefused: 2))
    }

    /// REGRESSION — a census with no names left to review is never a dead end.
    ///
    /// Two states reach it and the row must speak in both: one where every
    /// retained name is deliverable today (the count line is suppressed, because
    /// the stored integer counts files the app now opens on its own) and one where
    /// the names never decoded at all (a blob a newer build wrote, arriving
    /// through CloudKit — the counts survive that, the names do not).
    ///
    /// In the first the widening is itself the proof that asking again can still
    /// mint a chip, so the verb stays; in the second the count still prints. What
    /// closes both is the sentence that says where the files actually are — the
    /// row may lose its names, never its answer.
    func testACensusWithNoNamesLeftToReviewStillSaysSomething() {
        // Names decoded, all deliverable today.
        let widened = typeCensus(count: 2, names: 2)
        XCTAssertEqual(OutputHeldBackCopy.claimedTypeCount(widened, stillRefused: 0), 0,
                       "a number whose every named file would be delivered today is stale")
        XCTAssertFalse(OutputHeldBackCopy.blamesRetentionCap(widened, stillRefused: 0))
        XCTAssertTrue(OutputHeldBackCopy.allowlistWidened(widened, stillRefused: 0),
                      "which is what still offers the verb — these entries have no other way home")

        // Names never decoded: nothing was retained, so nothing widened, and the
        // count is all the row has.
        let undecoded = typeCensus(count: 2, names: 0)
        XCTAssertFalse(OutputHeldBackCopy.allowlistWidened(undecoded, stillRefused: 0))
        XCTAssertEqual(OutputHeldBackCopy.claimedTypeCount(undecoded, stillRefused: 0), 2)

        // The line that closes the arm in both states, and the reason it is not a
        // dead end: it says where the files are.
        let unnamed = text(LocalizedStringResource(
            "thread.outputs.heldBack.type.unnamed",
            defaultValue: "There's nothing here to review — Conduck doesn't have the names for what it left in the folder. It's all still on your file server."))
        XCTAssertTrue(unnamed.lowercased().contains("file server"),
                      "a row with no verb still owes the user the place their file is")
    }

    // MARK: - The louder warning

    /// EVERY SENTENCE TRUE OF EVERY MEMBER, ON THIS PLATFORM. The class
    /// deliberately spans formats Conduck's platforms cannot execute — `.msi`,
    /// `.deb`, `.rpm`, `.apk`, `.exe`, `.reg`, `.desktop` — because the file the
    /// user saves is one they can forward, sync, or open on another machine. So
    /// "can change YOUR device" is flatly false for a large minority of the set,
    /// and a warning the user can personally disprove is a warning they learn to
    /// skip — including on the `.mobileconfig` where it is exactly true.
    ///
    /// What IS true of every member is what the format is FOR.
    func testTheWarningClaimsNothingFalseOfAnyMemberOnThisPlatform() {
        let title = text(LocalizedStringResource(
            "thread.outputs.review.installer.title.v2",
            defaultValue: "This kind of file can change a device"))
        let what = text(LocalizedStringResource(
            "thread.outputs.review.installer.what.v2",
            defaultValue: "Files like this are meant to configure, install, or run something rather than to be read. A profile or certificate changes settings like Wi-Fi, VPN and trust; an installer or program puts software on a machine."))
        let when = text(LocalizedStringResource(
            "thread.outputs.review.installer.when.v2",
            defaultValue: "Saving it changes nothing. Opening it later — here, or wherever you move it — is the step that does."))

        // Claims that are FALSE for at least one member of the class, on the
        // platforms this sheet renders on.
        for overClaim in ["your device", "your iphone", "your ipad", "your mac",
                          "this device", "your computer"] {
            for sentence in [title, what, when] {
                XCTAssertFalse(sentence.lowercased().contains(overClaim),
                               "'\(overClaim)' is false of .msi/.deb/.apk/.exe here, and a "
                               + "disprovable warning is one the user learns to skip")
            }
        }

        // The MOMENT is still located at opening rather than saving — the one
        // claim that keeps "Save anyway" from reading as the dangerous step.
        XCTAssertTrue(when.lowercased().contains("saving it changes nothing"))
        // And no verdict about the user's own agent.
        for insinuation in ["malicious", "trust the source", "attack", "virus", "malware"] {
            for sentence in [title, what, when] {
                XCTAssertFalse(sentence.lowercased().contains(insinuation),
                               "'\(insinuation)' is a verdict Conduck cannot reach")
            }
        }
    }

    /// REGRESSION — EVERY MEMBER'S SENTENCE IS TRUE OF IT, in both directions.
    ///
    /// The macro tails used to sit in the installer class, where its sentence
    /// ("meant to configure, install, or run something rather than to be read")
    /// is false of every one of them: a `.docm` IS meant to be read. A test that
    /// only checked membership could not see that, which is how they got there.
    /// So this asserts the POSITIVE — each class holds only files its own
    /// sentence describes — and pins the two claims apart.
    func testEachWarningClassSaysSomethingTrueOfEveryOneOfItsMembers() {
        let installer = FileTransferOutputDetector.configurationInstallerExtensions
        let macro = FileTransferOutputDetector.macroEnabledDocumentExtensions

        // TWO CLASSES, NEVER ONE FILE IN BOTH: an extension in both draws two
        // warning blocks for a single file, which reads as an escalation the app
        // has no basis for.
        XCTAssertTrue(installer.isDisjoint(with: macro),
                      "overlap: \(installer.intersection(macro).sorted())")
        // And a macro tail is refused, never allowlisted — otherwise its warning
        // is dead code that reads like live protection.
        XCTAssertTrue(macro.isDisjoint(with: FileTransferOutputDetector.outputAllowlist))
        for ext in macro {
            XCTAssertEqual(ext, ext.lowercased(), "\(ext) would never match a folded extension")
        }

        // The installer sentence is false of a document format, so no document
        // format may be in that set. These are exactly the tails that were.
        for document in macro.union(["docx", "xlsx", "pptx", "pdf", "rtf", "csv"]) {
            XCTAssertFalse(installer.contains(document),
                           ".\(document) is meant to be read, which is the one thing the "
                           + "installer sentence says it is not")
        }

        // Every member of the macro class is flagged as one, and an unknown type
        // is flagged as neither — a type nobody can name cannot be asserted to
        // hold a macro any more than it can be asserted not to.
        for ext in macro {
            let entry = OutputTypeRefusal(
                name: "report.\(ext)", storedKey: "conv/out-box/report.\(ext)",
                byteSize: 1, reason: .unopenedExtension(ext))
            XCTAssertTrue(entry.isMacroEnabledDocument, ".\(ext) permits an embedded macro")
            XCTAssertFalse(entry.isConfigurationOrInstaller,
                           ".\(ext) is a document, so the installer block must not also draw")
        }
        XCTAssertFalse(OutputTypeRefusal(
            name: "README", storedKey: "conv/out-box/README",
            byteSize: 1, reason: .noReadableExtension).isMacroEnabledDocument)

        // And the sentence itself claims PERMISSION, not presence — Conduck read
        // a name and never a byte — and locates execution in the app that runs
        // macros rather than in the act of opening or in the device.
        let what = text(LocalizedStringResource(
            "thread.outputs.review.macro.what",
            defaultValue: "These file endings mark Word, Excel and PowerPoint files that are allowed to hold macros — small programs saved inside the file itself. The ending says a macro is allowed, not that there is one."))
        let when = text(LocalizedStringResource(
            "thread.outputs.review.macro.when",
            defaultValue: "Saving it changes nothing. Opening it in an app that runs macros — Word, Excel or PowerPoint — is the step that can run one."))
        XCTAssertTrue(what.lowercased().contains("not that there is one"),
                      "the ending is evidence of permission and of nothing else")
        XCTAssertTrue(when.lowercased().contains("saving it changes nothing"))
        for overClaim in ["your device", "your iphone", "your ipad", "your mac",
                          "this device", "your computer", "virus", "malware"] {
            for sentence in [what, when] {
                XCTAssertFalse(sentence.lowercased().contains(overClaim),
                               "'\(overClaim)' is a claim about a machine or a verdict about the "
                               + "file, and this warning is neither")
            }
        }
    }

    /// THE WARNING IS PER-CLASS, NOT PER-SHEET-CONTENT. A sheet holding one
    /// profile and one ordinary refusal warns because of the profile; the
    /// ordinary entry carries no warning of its own, so nothing in the sheet says
    /// a `.sqlite` can change anything.
    func testASheetWithOneWarnedEntryDoesNotWarnAboutTheOrdinaryOne() {
        let census = OutputDeliveryOutcome(
            typeRefusedCount: 2,
            shapeRefused: .nothingRefused,
            remainder: .nothingLeft,
            typeRefusedEntries: [RefusedOutputEntry(name: "profile.mobileconfig", byteSize: 4096),
                                 RefusedOutputEntry(name: "workspace.sqlite", byteSize: 8)]
        )
        let message = MessageRecord(
            id: UUID(), role: "agent", text: "reply", createdAt: Date(), sourceDevice: "phone",
            outputScanLaneID: "lane", outputBoxKey: "conv/out-box",
            outputDeliveryOutcome: census
        )
        let entries = OutputTypeRefusal.rescuableEntries(in: message)
        XCTAssertEqual(entries.map(\.name), ["profile.mobileconfig", "workspace.sqlite"])

        XCTAssertTrue(entries.contains(where: \.isConfigurationOrInstaller),
                      "the sheet warns — the profile is in the class")
        XCTAssertEqual(entries.map(\.isConfigurationOrInstaller), [true, false],
                       "and the flag stays on the entry that earned it, so the ordinary refusal "
                       + "has nothing warning-shaped attached to its own row")

        // A sheet with no member of the class does not warn at all.
        let ordinaryOnly = entries.filter { !$0.isConfigurationOrInstaller }
        XCTAssertFalse(ordinaryOnly.contains(where: \.isConfigurationOrInstaller))
    }

    /// Every member of the class earns the flag, and an UNKNOWN type never does —
    /// a type nobody can name cannot be asserted to be an installer any more than
    /// it can be asserted to be a document.
    func testEveryMemberOfTheClassIsFlaggedAndNothingElseIs() {
        for ext in FileTransferOutputDetector.configurationInstallerExtensions {
            let entry = OutputTypeRefusal(
                name: "payload.\(ext)", storedKey: "conv/out-box/payload.\(ext)",
                byteSize: 1, reason: .unopenedExtension(ext))
            XCTAssertTrue(entry.isConfigurationOrInstaller, ".\(ext) is in the warned class")
        }
        XCTAssertFalse(OutputTypeRefusal(
            name: "README", storedKey: "conv/out-box/README",
            byteSize: 1, reason: .noReadableExtension).isConfigurationOrInstaller,
            "an unknown type gets no claim made about it in either direction")
    }
}
