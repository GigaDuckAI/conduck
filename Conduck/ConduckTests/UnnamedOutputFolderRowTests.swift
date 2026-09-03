// SPDX-License-Identifier: Apache-2.0

// Conduck
// UnnamedOutputFolderRowTests.swift
//
// Locks the PURE selection rule behind the thread's folder-less row —
// `ConversationDetailViewModel.unnamedFolderRowIDs(in:currentLaneID:faultedSince:)`
// — the row that says a turn went out with no output folder because the user's
// file server stopped answering.
//
// WHY THIS RULE IS DELICATE, and why it earns its own file. In the persisted
// record, FOUR very different turns look identical (`outputScanLaneID` set,
// `outputBoxKey` nil): a wrist-originated turn (the Watch holds no file-server
// credential by design), a lane whose server does not implement `PROPFIND` at
// all, a row a device synced from CloudKit before the attribute landed, and the
// one case worth a word — a configured, tested-green lane that has since gone
// dark. Only the last may draw a row; a rule that catches the other three puts a
// standing complaint under years of perfectly ordinary turns.
//
// The two clauses that do the separating are the LIVE lane fault (the breaker
// says this lane is failing right now) and the CAUSALITY gate (the turn landed
// after that failure streak began). Everything below is a case where dropping
// one of them would be wrong.
//
// The later sections cover the TAP: a manual look resets the breaker before it
// probes, which would otherwise make the live fault clause answer "healthy" from
// the instant of the touch and delete the row the user just pressed.
// `unnamedFolderRowState` folds the resulting hold into the same selection, and
// `rootSearchGotAnAnswer` decides what may retire it — an answer out of the
// server, never the intent to ask. The view-model seam is in
// `UnnamedFolderRowTapLifecycleTests`.
//
// Deterministic + headless: no network, no Core Data, no Keychain, no clock.
// Synthetic fixtures only; no real filenames, keys, URLs or credentials.

import XCTest
@testable import Conduck

@MainActor
final class UnnamedOutputFolderRowTests: XCTestCase {

    // MARK: - Fixtures

    private let lane = String(repeating: "a", count: 64)
    private let otherLane = String(repeating: "b", count: 64)

    /// t0 is the reference instant every case is written relative to, so a
    /// "before"/"after" reads as arithmetic rather than as a date.
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    /// THE FIFTH FACT, run through the same two shipped functions production
    /// runs — the extractor and its post-exclusion window — rather than written
    /// out as a literal set, so a fixture whose text stops naming a file stops
    /// selecting instead of quietly keeping a row the real rule drops.
    ///
    /// NOT A SUBSTITUTE FOR THE VIEW MODEL'S OWN EXCLUSION ASSEMBLY. Production
    /// unions the agent turn's storedKeys with the conversation's inbound upload
    /// tokens, and only `refreshSearchableReplyNames` can reach the second;
    /// `inbound` here stands in for it so the exclusion path is exercised from
    /// both sides. What these cases lock is the RULE, not the plumbing that
    /// feeds it.
    private func searchable(
        _ messages: [MessageRecord],
        inbound: Set<String> = []
    ) -> Set<UUID> {
        Set(
            messages
                .filter { $0.role == "agent" }
                .filter { message in
                    !FileTransferOutputDetector.actionableCandidateWindow(
                        candidates: FileTransferOutputDetector
                            .extractCandidates(from: message.text),
                        excludedKeys: Set(message.attachments.compactMap(\.storedKey))
                            .union(inbound)
                    ).isEmpty
                }
                .map(\.id)
        )
    }

    /// `text` names a file BY DEFAULT, because the row's rule now requires one:
    /// a reply that names nothing draws no row however broken the lane is, so a
    /// fixture that named nothing would make every positive case below vacuous
    /// rather than wrong. `.txt` is on the extractor's allowlist; cases that
    /// want the silent side pass their own text.
    private func agent(
        id: UUID = UUID(),
        laneID: String?,
        boxKey: String?,
        at offset: TimeInterval,
        text: String = "Saved it to notes.txt."
    ) -> MessageRecord {
        MessageRecord(
            id: id,
            role: "agent",
            text: text,
            createdAt: t0.addingTimeInterval(offset),
            sourceDevice: "iphone",
            outputScanDone: false,
            outputScanLaneID: laneID,
            outputBoxKey: boxKey,
            attachments: []
        )
    }

    private func user(at offset: TimeInterval) -> MessageRecord {
        MessageRecord(
            id: UUID(),
            role: "user",
            text: "Write me a haiku about rain and save it.",
            createdAt: t0.addingTimeInterval(offset),
            sourceDevice: "iphone",
            attachments: []
        )
    }

    // MARK: - A file has to have been in play

    /// THE REPORTED BUG, verbatim. A greeting answered with a greeting, under a
    /// file server that has genuinely stopped, used to carry a paragraph about
    /// files neither side mentioned — and the row's own per-turn remedy, a
    /// search of the reply for the names it mentions, would have answered that
    /// tap with nothing.
    func testAPureTextExchangeDrawsNoRow() {
        let greeting = agent(laneID: lane, boxKey: nil, at: 1,
                             text: "Hi! How can I help you today?")

        XCTAssertTrue(
            ConversationDetailViewModel.unnamedFolderRowIDs(
                in: [user(at: 0), greeting],
                currentLaneID: lane,
                faultedSince: t0,
                repliesWithSomethingToSearchFor: searchable([greeting])).isEmpty,
            "a broken file server is not this conversation's business: nothing was lost, and the row's own search would find nothing to ask about")
    }

    /// A reply that DOES name a file still gets the row on the same broken lane
    /// — the row did not become quieter, it became specific.
    func testAReplyNamingAFileStillDrawsTheRow() {
        let named = agent(laneID: lane, boxKey: nil, at: 1,
                          text: "Done — I saved it to chart.png.")

        XCTAssertEqual(
            ConversationDetailViewModel.unnamedFolderRowIDs(
                in: [named],
                currentLaneID: lane,
                faultedSince: t0,
                repliesWithSomethingToSearchFor: searchable([named])),
            [named.id],
            "a turn whose reply names a file the search could ask about is exactly the turn this row exists for")
    }

    /// THE POST-EXCLUSION CASE, and the reason the gate is the search's WINDOW
    /// rather than the raw extraction. The user uploaded `report.csv`; the reply
    /// echoes that name back. A name already known to this turn is dropped
    /// before any probe, so the button would issue no request — and a row whose
    /// remedy issues no request is the thing being removed here.
    func testAReplyEchoingOnlyTheUsersOwnUploadDrawsNoRow() {
        let echo = MessageRecord(
            id: UUID(), role: "agent", text: "Done with report.csv.",
            createdAt: t0.addingTimeInterval(1), sourceDevice: "iphone",
            outputScanDone: false, outputScanLaneID: lane, outputBoxKey: nil,
            attachments: [
                AttachmentRecord(
                    id: UUID(), mimeType: "text/csv", filename: "report.csv",
                    thumbnailData: nil, extractedText: nil,
                    width: 0, height: 0, byteSize: 1, sequence: 0, createdAt: t0,
                    isServerReference: true, storedKey: "report.csv")
            ])

        XCTAssertTrue(
            ConversationDetailViewModel.unnamedFolderRowIDs(
                in: [echo],
                currentLaneID: lane,
                faultedSince: t0,
                repliesWithSomethingToSearchFor: searchable([echo])).isEmpty,
            "the only name in the reply is one this turn already knows about, so the search would probe nothing")
    }

    /// The exclusion that comes from the CONVERSATION rather than from the turn:
    /// the user uploaded `report.csv` earlier, the reply mentions it, and the
    /// search would drop it as a name this thread already knows.
    func testAReplyEchoingAnEarlierUploadInTheThreadDrawsNoRow() {
        let echo = agent(laneID: lane, boxKey: nil, at: 1,
                         text: "Done with report.csv.")

        XCTAssertTrue(
            ConversationDetailViewModel.unnamedFolderRowIDs(
                in: [echo], currentLaneID: lane, faultedSince: t0,
                repliesWithSomethingToSearchFor: searchable([echo], inbound: ["report.csv"])).isEmpty,
            "an inbound upload token excludes the name just as a storedKey on the turn does")
        XCTAssertEqual(
            ConversationDetailViewModel.unnamedFolderRowIDs(
                in: [echo], currentLaneID: lane, faultedSince: t0,
                repliesWithSomethingToSearchFor: searchable([echo])),
            [echo.id],
            "and without that token the very same reply DOES draw the row — the exclusion is what moved, not the text")
    }

    /// Prose that is shaped like a filename is not one. The extractor's own
    /// allowlist is what makes this true, and it is why the gate reuses the
    /// shipped extractor instead of a filename-shaped regex of its own.
    func testProseThatLooksLikeAFilenameDrawsNoRow() {
        let prose = agent(laneID: lane, boxKey: nil, at: 1,
                          text: "That takes about 3.5 hours, e.g. overnight — see example.com for 2.50GB plans.")

        XCTAssertTrue(
            ConversationDetailViewModel.unnamedFolderRowIDs(
                in: [prose],
                currentLaneID: lane,
                faultedSince: t0,
                repliesWithSomethingToSearchFor: searchable([prose])).isEmpty,
            "decimals, abbreviations and domains are not files, and a row drawn on them would be the original complaint wearing a different hat")
    }

    /// THE DIRECTION OF THE RACE, asserted. The reply scan runs off the main
    /// actor and lands after the first draw, so an unscanned turn is momentarily
    /// absent from the set. That must make the row appear LATE, never make a
    /// standing row vanish — the latter is what the hold mechanism exists for.
    func testAnUnscannedReplyDrawsNoRowYetRatherThanTheWrongOne() {
        let named = agent(laneID: lane, boxKey: nil, at: 1,
                          text: "Saved it to notes.txt.")

        XCTAssertTrue(
            ConversationDetailViewModel.unnamedFolderRowIDs(
                in: [named], currentLaneID: lane, faultedSince: t0,
                repliesWithSomethingToSearchFor: []).isEmpty,
            "before the scan lands there is nothing to say")
        XCTAssertEqual(
            ConversationDetailViewModel.unnamedFolderRowIDs(
                in: [named], currentLaneID: lane, faultedSince: t0,
                repliesWithSomethingToSearchFor: searchable([named])),
            [named.id],
            "and once it lands the row arrives — the only direction this race may run")
    }

    // MARK: - The silent cases

    /// A lane that is answering produces the empty set, whatever the thread
    /// holds. This is the resting state of every healthy install and it must
    /// cost nothing and say nothing.
    func testAHealthyLaneSelectsNothing() {
        let messages = [
            user(at: 0),
            agent(laneID: lane, boxKey: nil, at: 1),
            agent(laneID: lane, boxKey: "conv/out-box", at: 2)
        ]

        XCTAssertTrue(
            ConversationDetailViewModel.unnamedFolderRowIDs(
                in: messages, currentLaneID: lane, faultedSince: nil,
                repliesWithSomethingToSearchFor: searchable(messages)).isEmpty,
            "no live fault means nothing to say, and no residue to clear by hand")
    }

    /// THE WRIST TURN, and the reason the causality gate exists. A wrist turn
    /// names no folder for a reason that is nobody's fault, and it is
    /// indistinguishable in the record from a folder-less dispatch. One tunnel
    /// hostname rotating today must not put a complaint under a turn from last
    /// month.
    func testTurnsThatPredateTheFailureStreakAreLeftAlone() {
        let old = agent(laneID: lane, boxKey: nil, at: -86_400)
        let recent = agent(laneID: lane, boxKey: nil, at: 60)

        let selected = ConversationDetailViewModel.unnamedFolderRowIDs(
            in: [old, recent], currentLaneID: lane, faultedSince: t0,
                repliesWithSomethingToSearchFor: searchable([old, recent]))

        XCTAssertEqual(selected, [recent.id],
                       "only the turn that landed after the lane broke can have been broken by it")
    }

    /// A turn dispatched to a DIFFERENT server is not evidence about the one
    /// that is currently failing. `==`, never `!= nil`.
    func testTurnsOnAnotherLaneAreLeftAlone() {
        let elsewhere = agent(laneID: otherLane, boxKey: nil, at: 60)

        XCTAssertTrue(
            ConversationDetailViewModel.unnamedFolderRowIDs(
                in: [elsewhere], currentLaneID: lane, faultedSince: t0,
                repliesWithSomethingToSearchFor: searchable([elsewhere])).isEmpty)
    }

    /// A turn with no lane at all was sent with no file server configured — the
    /// majority configuration. There is nothing it was promised and nothing it
    /// lost.
    func testTurnsWithNoLaneAreLeftAlone() {
        let unconfigured = agent(laneID: nil, boxKey: nil, at: 60)

        XCTAssertTrue(
            ConversationDetailViewModel.unnamedFolderRowIDs(
                in: [unconfigured], currentLaneID: lane, faultedSince: t0,
                repliesWithSomethingToSearchFor: searchable([unconfigured])).isEmpty)
    }

    /// A turn that DID get a folder is the other row's business: its folder
    /// exists on the server and may still be re-read. Two rows on one turn would
    /// make contradictory claims about what is out there.
    func testTurnsThatGotAFolderAreLeftAlone() {
        let delivered = agent(laneID: lane, boxKey: "conv/out-box", at: 60)

        XCTAssertTrue(
            ConversationDetailViewModel.unnamedFolderRowIDs(
                in: [delivered], currentLaneID: lane, faultedSince: t0,
                repliesWithSomethingToSearchFor: searchable([delivered])).isEmpty,
            "the folder-less row and the unreadable-folder row are disjoint by construction")
    }

    /// A user's own message never carries an agent-side diagnostic, whatever
    /// state the lane is in.
    func testUserTurnsAreNeverSelected() {
        XCTAssertTrue(
            ConversationDetailViewModel.unnamedFolderRowIDs(
                in: [user(at: 60), user(at: 61)], currentLaneID: lane, faultedSince: t0,
                repliesWithSomethingToSearchFor: searchable([user(at: 60), user(at: 61)])).isEmpty)
    }

    /// The lane is failing but the conversation is bound to a gateway with no
    /// ready lane — nothing to attribute anything to.
    func testNoCurrentLaneSelectsNothing() {
        let orphan = agent(laneID: lane, boxKey: nil, at: 60)

        XCTAssertTrue(
            ConversationDetailViewModel.unnamedFolderRowIDs(
                in: [orphan], currentLaneID: nil, faultedSince: t0,
                repliesWithSomethingToSearchFor: searchable([orphan])).isEmpty)
    }

    // MARK: - The surfaced case

    /// The reply always lands AFTER the dispatch whose witness failed, so the
    /// boundary instant is the case this row exists for — hence `>=`, not `>`.
    func testATurnLandingExactlyAtTheStreakStartIsSelected() {
        let boundary = agent(laneID: lane, boxKey: nil, at: 0)

        XCTAssertEqual(
            ConversationDetailViewModel.unnamedFolderRowIDs(
                in: [boundary], currentLaneID: lane, faultedSince: t0,
                repliesWithSomethingToSearchFor: searchable([boundary])),
            [boundary.id])
    }

    /// Every turn sent into a broken lane genuinely went out folder-less, so
    /// every one of them gets the row — including the ones dispatched during the
    /// backoff, where no request was spent. Suppressing the REQUEST is the point
    /// of the cooldown; suppressing the TRUTH would rebuild the silent
    /// degradation this row exists to end.
    func testEveryTurnSentIntoTheBrokenLaneIsSelected() {
        let first = agent(laneID: lane, boxKey: nil, at: 10)
        let second = agent(laneID: lane, boxKey: nil, at: 600)
        let third = agent(laneID: lane, boxKey: nil, at: 3_600)

        XCTAssertEqual(
            ConversationDetailViewModel.unnamedFolderRowIDs(
                in: [first, second, third], currentLaneID: lane, faultedSince: t0,
                repliesWithSomethingToSearchFor: searchable([first, second, third])),
            [first.id, second.id, third.id])
    }

    /// A thread mixing every disposition resolves to exactly the one turn that
    /// qualifies — the composite the individual cases above are pulled from.
    func testAMixedThreadSelectsOnlyTheQualifyingTurn() {
        let qualifying = agent(laneID: lane, boxKey: nil, at: 60)
        let messages = [
            user(at: -100),
            agent(laneID: lane, boxKey: nil, at: -99),          // predates the streak
            agent(laneID: nil, boxKey: nil, at: 50),            // no lane
            agent(laneID: otherLane, boxKey: nil, at: 55),      // another server
            agent(laneID: lane, boxKey: "conv/out-box", at: 58), // got a folder
            user(at: 59),
            qualifying
        ]

        XCTAssertEqual(
            ConversationDetailViewModel.unnamedFolderRowIDs(
                in: messages, currentLaneID: lane, faultedSince: t0,
                repliesWithSomethingToSearchFor: searchable(messages)),
            [qualifying.id])
    }

    // MARK: - The tap hold (the row must survive its own button)

    // A manual look RESETS the witness breaker before it probes, on purpose: a
    // user who has just repaired their tunnel must not wait out a cooldown they
    // cannot see. But `faultedSince` is the only live input above, so the reset
    // alone answers the empty set from the instant of the touch — the tapped row
    // would vanish under the finger, before the look ran, taking its explanation
    // and its "Review file setup" button with it, and every sibling folder-less
    // row in the thread with it too. `UnnamedFolderHold` is what separates
    // "re-enable probing" from "retract what the thread says".

    private func hold(ids: Set<UUID>, laneID: String, at offset: TimeInterval) ->
        ConversationDetailViewModel.UnnamedFolderHold {
        .init(laneID: laneID, ids: ids, takenAt: t0.addingTimeInterval(offset))
    }

    /// THE REGRESSION. Post-reset the derivation is empty (no streak), and the
    /// held rows are all that keep the tapped row and its siblings on screen.
    func testHeldRowsSurviveTheBreakerResetTheTapPerformed() {
        let tapped = agent(laneID: lane, boxKey: nil, at: 60)
        let sibling = agent(laneID: lane, boxKey: nil, at: 61)

        let state = ConversationDetailViewModel.unnamedFolderRowState(
            in: [tapped, sibling],
            currentLaneID: lane,
            faultedSince: nil,                            // the tap just reset the breaker
            hold: hold(ids: [tapped.id, sibling.id], laneID: lane, at: 62),
                repliesWithSomethingToSearchFor: searchable([tapped, sibling]))

        XCTAssertEqual(state.ids, [tapped.id, sibling.id],
                       "a row that evaporates on touch reads as a crash and removes the affordance the user was reaching for")
        XCTAssertNotNil(state.hold, "nothing has answered yet, so nothing has been earned")
    }

    /// The hold FREEZES a set; it never grows one. A wrist turn landing after the
    /// tap is folder-less for a reason that is nobody's fault, and the tap is not
    /// a licence to complain about it.
    func testTheHoldAdmitsNoNewTurns() {
        let held = agent(laneID: lane, boxKey: nil, at: 60)
        let laterWristTurn = agent(laneID: lane, boxKey: nil, at: 900)

        let state = ConversationDetailViewModel.unnamedFolderRowState(
            in: [held, laterWristTurn],
            currentLaneID: lane,
            faultedSince: nil,
            hold: hold(ids: [held.id], laneID: lane, at: 62),
                repliesWithSomethingToSearchFor: searchable([held, laterWristTurn]))

        XCTAssertEqual(state.ids, [held.id])
    }

    /// A LIVE streak still governs on its own terms. The hold adds to the
    /// derivation, it does not replace it — otherwise a tap would freeze the
    /// thread's diagnosis at the moment of the touch.
    func testALiveStreakStillSelectsAlongsideAHold() {
        let held = agent(laneID: lane, boxKey: nil, at: -50)
        let freshlyBroken = agent(laneID: lane, boxKey: nil, at: 60)

        let state = ConversationDetailViewModel.unnamedFolderRowState(
            in: [held, freshlyBroken],
            currentLaneID: lane,
            faultedSince: t0,
            hold: hold(ids: [held.id], laneID: lane, at: -49),
                repliesWithSomethingToSearchFor: searchable([held, freshlyBroken]))

        XCTAssertEqual(state.ids, [held.id, freshlyBroken.id])
    }

    /// EARNED, way one: a turn dispatched on this lane after the hold came back
    /// WITH a folder. Only a passing pre-dispatch witness mints a box key, so
    /// that turn IS the server answering — "your file server didn't answer" is
    /// now false and the rows go.
    func testALaterTurnThatGotAFolderSpendsTheHold() {
        let held = agent(laneID: lane, boxKey: nil, at: 60)
        let recovered = agent(laneID: lane, boxKey: "conv/out-box", at: 900)
        let taken = hold(ids: [held.id], laneID: lane, at: 62)

        XCTAssertTrue(
            ConversationDetailViewModel.unnamedFolderHoldIsSpent(
                taken, in: [held, recovered], currentLaneID: lane))

        let state = ConversationDetailViewModel.unnamedFolderRowState(
            in: [held, recovered], currentLaneID: lane, faultedSince: nil, hold: taken,
                repliesWithSomethingToSearchFor: searchable([held, recovered]))
        XCTAssertTrue(state.ids.isEmpty)
        XCTAssertNil(state.hold)
    }

    /// A turn that got a folder BEFORE the hold was taken proves nothing about
    /// the server now — it is the state the tap was reacting to.
    func testAnEarlierDeliveredTurnDoesNotSpendTheHold() {
        let delivered = agent(laneID: lane, boxKey: "conv/out-box", at: 10)
        let held = agent(laneID: lane, boxKey: nil, at: 60)

        XCTAssertFalse(
            ConversationDetailViewModel.unnamedFolderHoldIsSpent(
                hold(ids: [held.id], laneID: lane, at: 62),
                in: [delivered, held],
                currentLaneID: lane))
    }

    /// A delivered turn on ANOTHER server says nothing about the one being held.
    func testADeliveredTurnOnAnotherLaneDoesNotSpendTheHold() {
        let held = agent(laneID: lane, boxKey: nil, at: 60)
        let elsewhere = agent(laneID: otherLane, boxKey: "conv/out-box", at: 900)

        XCTAssertFalse(
            ConversationDetailViewModel.unnamedFolderHoldIsSpent(
                hold(ids: [held.id], laneID: lane, at: 62),
                in: [held, elsewhere],
                currentLaneID: lane))
    }

    /// EARNED, way two: the lane moved. The held rows describe a server that is
    /// no longer configured, so they are no longer about anything.
    func testTheHoldDiesWithItsLane() {
        let held = agent(laneID: lane, boxKey: nil, at: 60)
        let taken = hold(ids: [held.id], laneID: lane, at: 62)

        XCTAssertTrue(
            ConversationDetailViewModel.unnamedFolderHoldIsSpent(
                taken, in: [held], currentLaneID: otherLane))
        XCTAssertTrue(
            ConversationDetailViewModel.unnamedFolderHoldIsSpent(
                taken, in: [held], currentLaneID: nil))

        let state = ConversationDetailViewModel.unnamedFolderRowState(
            in: [held], currentLaneID: otherLane, faultedSince: nil, hold: taken,
                repliesWithSomethingToSearchFor: searchable([held]))
        XCTAssertTrue(state.ids.isEmpty)
        XCTAssertNil(state.hold)
    }

    // MARK: - What counts as an ANSWER (the root name search)

    // The other release: the look itself got something out of the server. The
    // trap is that `probeNamedCandidates` reports `conclusive == true` for an
    // EMPTY probe window without issuing a request, so `conclusive` alone would
    // retire the row for the intent to look — the exact defect the hold exists
    // to prevent.

    func testARootSearchThatProbedNothingIsNotAnAnswer() {
        XCTAssertFalse(
            ConversationDetailViewModel.rootSearchGotAnAnswer(
                candidates: [], excludedKeys: [], conclusive: true, foundAnything: false),
            "a reply that named no file was never sent to the server, so it learned nothing about it")
    }

    func testARootSearchWhoseEveryCandidateWasExcludedIsNotAnAnswer() {
        XCTAssertFalse(
            ConversationDetailViewModel.rootSearchGotAnAnswer(
                candidates: ["k__a.txt"],
                excludedKeys: ["k__a.txt"],
                conclusive: true,
                foundAnything: false),
            "a reply that only echoed this thread's own upload probes nothing — the exclusion empties the window")
    }

    func testARootSearchThatProbedAndGotDefinitiveAnswersIsAnAnswer() {
        XCTAssertTrue(
            ConversationDetailViewModel.rootSearchGotAnAnswer(
                candidates: ["k__a.txt", "k__b.txt"],
                excludedKeys: ["k__a.txt"],
                conclusive: true,
                foundAnything: false),
            "one candidate survived the exclusion and the server answered about it")
    }

    func testARootSearchThatFoundAFileIsAnAnswerEvenWhenInconclusive() {
        XCTAssertTrue(
            ConversationDetailViewModel.rootSearchGotAnAnswer(
                candidates: ["k__a.txt", "k__b.txt"],
                excludedKeys: [],
                conclusive: false,
                foundAnything: true),
            "a confirmed-present file is the server speaking, whatever the other probe did")
    }

    func testARootSearchThatLearnedNothingIsNotAnAnswer() {
        XCTAssertFalse(
            ConversationDetailViewModel.rootSearchGotAnAnswer(
                candidates: ["k__a.txt"],
                excludedKeys: [],
                conclusive: false,
                foundAnything: false),
            "an unreachable host or a refused certificate leaves the row exactly where it was")
    }
}
