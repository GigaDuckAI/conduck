// SPDX-License-Identifier: Apache-2.0

// ConduckTests
// WorkboardReorderRebaseTests.swift
//
// A drag is a gesture the person has already completed, so a capture that lands
// while it is saving must not cost them the move. The desk therefore REBASES:
// it accepts a proposal when its own canonical order is still the baseline the
// drag was planned on with new ids appended, and writes the proposal followed by
// those new ids.
//
// Two things a cheaper check gets wrong, and both are held here.
//
// A bare SUPERSET test — "every baseline id is still on the desk" — passes on
// "somebody else reordered, then something arrived", and writing the proposal
// then erases that reorder with nobody able to see it happen. Requiring the
// baseline as a PREFIX is what tells an append apart from a rearrangement.
//
// IDS ALONE cannot see a fold change. A recording arriving for a picture already
// on the board, or a picture arriving for a recording that was standing alone,
// both leave the baseline intact as a prefix while repartitioning the cards the
// person was dragging between — one card becomes two, or two become one. So the
// baseline carries the companion links too, and either direction is a refusal.

import XCTest
@testable import Conduck

final class WorkboardReorderRebaseTests: XCTestCase {

    // MARK: - Accepted

    /// The case the rebase exists for: a card moved here while a capture landed
    /// there. Both survive — the move is written, the arrival keeps its place at
    /// the end.
    func testAProposalRebasesOntoIdsThatArrivedWhileItWasSaving() {
        let (a, b, c, arrived) = (id(), id(), id(), id())

        XCTAssertEqual(
            rebase(proposed: [c, a, b], baseline: [a, b, c], current: [a, b, c, arrived]),
            [c, a, b, arrived],
            "the drag keeps its order and the arrival keeps its place after it"
        )
    }

    func testAnUntouchedDeskAcceptsThePlainProposal() {
        let (a, b, c) = (id(), id(), id())
        XCTAssertEqual(rebase(proposed: [b, c, a], baseline: [a, b, c], current: [a, b, c]), [b, c, a])
    }

    func testSeveralArrivalsAllKeepTheirOrderAfterTheMove() {
        let (a, b) = (id(), id())
        let arrivals = [id(), id(), id()]
        XCTAssertEqual(
            rebase(proposed: [b, a], baseline: [a, b], current: [a, b] + arrivals),
            [b, a] + arrivals
        )
    }

    // MARK: - Refused: the desk rearranged

    /// THE DEFECT A SUPERSET TEST ADMITS. Another device reordered the desk and
    /// then something arrived, so every baseline id is still present — and
    /// writing this proposal would silently undo that reorder.
    ///
    /// Negative control: a `Set(baseline).isSubset(of: current)` check returns
    /// the rebased order here instead of nil.
    func testAConcurrentReorderIsRefusedEvenThoughEveryBaselineIdIsStillThere() {
        let (a, b, c, arrived) = (id(), id(), id(), id())

        XCTAssertNil(
            rebase(proposed: [c, a, b], baseline: [a, b, c], current: [c, b, a, arrived]),
            "the desk was rearranged elsewhere, so this move cannot be replayed onto it"
        )
        XCTAssertTrue(
            Set([a, b, c]).isSubset(of: Set([c, b, a, arrived])),
            "the premise: the cheaper check would have accepted this"
        )
    }

    /// A card the drag was planned on is gone. The rewrite names every logical
    /// id exactly once, so accepting would try to resurrect it.
    func testARemovedBaselineCardRefusesTheWholeMove() {
        let (a, b, c) = (id(), id(), id())
        XCTAssertNil(rebase(proposed: [c, a, b], baseline: [a, b, c], current: [a, c]))
    }

    /// A peer's material with an earlier rank lands in the MIDDLE of the
    /// canonical order rather than after it. No old card changed places, but
    /// accepting would need a rule for where a newcomer belongs relative to a
    /// rearrangement it never saw — so this is refused, deliberately and
    /// conservatively. A refusal costs one gesture; a wrong placement is
    /// invisible.
    func testAnArrivalRankedIntoTheMiddleIsRefusedRatherThanGuessedAt() {
        let (a, b, c, newcomer) = (id(), id(), id(), id())
        XCTAssertNil(rebase(proposed: [c, a, b], baseline: [a, b, c], current: [a, newcomer, b, c]))
    }

    // MARK: - Refused: the fold changed

    /// A recording arrives naming a picture the drag was planned around. The
    /// canonical prefix is intact — it appended — but the board the person was
    /// dragging on had one card there and now has a folded pair, so the
    /// proposal is about a partition that no longer exists.
    func testARecordingArrivingForABaselinePictureRefusesTheMove() {
        let (picture, other) = (id(), id())
        let recording = id()

        XCTAssertNil(
            WorkboardReorderRebase.rebased(
                proposed: [other, picture],
                baseline: WorkboardReorderBaseline(orderedIDs: [picture, other]),
                current: [picture, other, recording],
                currentAttachments: [recording: picture]
            )
        )
    }

    /// The other direction, and the one ids alone cannot see at all: a recording
    /// was standing on its own because the picture it names had not landed. The
    /// picture arrives and folds it away, so a card the person could see stops
    /// being a card.
    func testAPictureArrivingForAStandaloneBaselineRecordingRefusesTheMove() {
        let (recording, other) = (id(), id())
        let picture = id()
        let baseline = WorkboardReorderBaseline(
            orderedIDs: [recording, other],
            attachments: [recording: picture]
        )

        XCTAssertNil(
            WorkboardReorderRebase.rebased(
                proposed: [other, recording],
                baseline: baseline,
                current: [recording, other, picture],
                currentAttachments: [recording: picture]
            ),
            "the picture the standalone recording names has landed, so it is no longer standalone"
        )
    }

    /// A recording that was pointing at a picture stops pointing at it, or
    /// starts. Same ids, different cards.
    func testABaselineCardWhoseCompanionLinkChangedRefusesTheMove() {
        let (picture, recording, other) = (id(), id(), id())
        let paired = WorkboardReorderBaseline(
            orderedIDs: [picture, recording, other],
            attachments: [recording: picture]
        )

        XCTAssertNil(
            WorkboardReorderRebase.rebased(
                proposed: [other, picture, recording],
                baseline: paired,
                current: [picture, recording, other],
                currentAttachments: [:]
            ),
            "the link was dropped, so the pair is two cards now"
        )
        XCTAssertNil(
            WorkboardReorderRebase.rebased(
                proposed: [other, picture, recording],
                baseline: WorkboardReorderBaseline(orderedIDs: [picture, recording, other]),
                current: [picture, recording, other],
                currentAttachments: [recording: picture]
            ),
            "and the link was added, so two cards are one now"
        )
    }

    /// An arrival that names something OUTSIDE the dragged board is an ordinary
    /// append: the person was not dragging between its members.
    func testAnArrivalNamingAMaterialTheDragNeverSawIsAnOrdinaryAppend() {
        let (a, b) = (id(), id())
        let (strangerPicture, strangerRecording) = (id(), id())

        XCTAssertEqual(
            WorkboardReorderRebase.rebased(
                proposed: [b, a],
                baseline: WorkboardReorderBaseline(orderedIDs: [a, b]),
                current: [a, b, strangerPicture, strangerRecording],
                currentAttachments: [strangerRecording: strangerPicture]
            ),
            [b, a, strangerPicture, strangerRecording]
        )
    }

    /// AN ESCAPED ARRIVAL IS STILL A FOLD. A capture whose own id was already
    /// held by a card of another kind lands under
    /// `WorkMaterialCollisionEscape.materialID(forCapture:)`, and
    /// `eligibleParentID` resolves a link through that escape as its second
    /// candidate — so a picture arriving at the derived id folds a baseline
    /// recording away exactly like one arriving at the named id.
    ///
    /// Negative control: comparing raw attachment ids alone — the check this
    /// replaces — returns a rebased order for both of these.
    func testAnEscapedArrivalFoldsTheBoardAndIsRefusedLikeANamedOne() {
        let (recording, other) = (id(), id())
        let named = id()
        let escaped = WorkMaterialCollisionEscape.materialID(forCapture: named)

        // The picture the standalone recording names arrives under its escape.
        XCTAssertNil(
            WorkboardReorderRebase.rebased(
                proposed: [other, recording],
                baseline: WorkboardReorderBaseline(
                    orderedIDs: [recording, other],
                    attachments: [recording: named]
                ),
                current: [recording, other, escaped],
                currentAttachments: [recording: named]
            ),
            "the recording's picture landed under its escape, so it is no longer standalone"
        )

        // And the other direction: a recording arrives naming a picture that
        // itself escaped, so its link resolves onto a baseline card.
        let picture = id()
        let escapedPicture = WorkMaterialCollisionEscape.materialID(forCapture: picture)
        let arrival = id()
        XCTAssertNil(
            WorkboardReorderRebase.rebased(
                proposed: [other, escapedPicture],
                baseline: WorkboardReorderBaseline(orderedIDs: [escapedPicture, other]),
                current: [escapedPicture, other, arrival],
                currentAttachments: [arrival: picture]
            ),
            "the arrival's link resolves through the escape onto a card the drag was planned around"
        )
    }

    /// The escape check does not swallow ordinary appends: a link that resolves
    /// to neither candidate on this board is still just a newcomer.
    func testAnEscapeThatNamesNothingOnThisBoardStillAppendsCleanly() {
        let (a, b) = (id(), id())
        let strangerPicture = id()
        let strangerRecording = id()

        XCTAssertEqual(
            WorkboardReorderRebase.rebased(
                proposed: [b, a],
                baseline: WorkboardReorderBaseline(
                    orderedIDs: [a, b],
                    attachments: [a: strangerPicture]
                ),
                current: [a, b, strangerRecording],
                currentAttachments: [a: strangerPicture, strangerRecording: id()]
            ),
            [b, a, strangerRecording]
        )
    }

    // MARK: - Refused: a malformed request

    func testAProposalThatIsNotAPermutationOfItsBaselineIsRefused() {
        let (a, b, c) = (id(), id(), id())

        XCTAssertNil(rebase(proposed: [a, b], baseline: [a, b, c], current: [a, b, c]))
        XCTAssertNil(rebase(proposed: [a, b, id()], baseline: [a, b, c], current: [a, b, c]))
        XCTAssertNil(rebase(proposed: [a, a, b], baseline: [a, b, c], current: [a, b, c]))
        XCTAssertNil(rebase(proposed: [a, b, c], baseline: [a, b, b], current: [a, b, c]))
        XCTAssertNil(
            rebase(proposed: [a, b, c], baseline: [a, b, c], current: [a, b, c, c]),
            "a duplicated id on the desk is not an order this can reason about"
        )
    }

    func testAnEmptyBaselineOnlyAcceptsAnEmptyProposal() {
        let arrived = id()
        XCTAssertEqual(rebase(proposed: [], baseline: [], current: [arrived]), [arrived])
        XCTAssertNil(rebase(proposed: [arrived], baseline: [], current: [arrived]))
    }

    // MARK: - Helpers

    private func id() -> UUID { UUID() }

    private func rebase(proposed: [UUID], baseline: [UUID], current: [UUID]) -> [UUID]? {
        WorkboardReorderRebase.rebased(
            proposed: proposed,
            baseline: WorkboardReorderBaseline(orderedIDs: baseline),
            current: current,
            currentAttachments: [:]
        )
    }
}
