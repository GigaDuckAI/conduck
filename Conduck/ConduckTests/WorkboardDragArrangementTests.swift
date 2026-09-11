// SPDX-License-Identifier: Apache-2.0

// ConduckTests
// WorkboardDragArrangementTests.swift
//
// What the board DRAWS while a card is lifted, and the one arithmetic trap that
// lives between drawing and committing.
//
// A slot is a gap in the CURRENT, source-present order. Two different pieces of
// code have to subtract one when the source sits before that gap — the renderer,
// to place the placeholder in the source-REMOVED array, and the planner, to turn
// a slot into a permutation. Doing it once each is correct; passing the
// renderer's already-adjusted index to the planner subtracts twice and lands the
// card one slot early. The equivalence test below is what pins the two together:
// wherever the placeholder is drawn, that is where the card must actually land.
//
// Negative control for that test: returning the renderer's adjusted index from
// `commitTarget`, or dropping the subtraction in `placeholderIndex`, makes every
// case with `slot > sourceIndex` fail.

import XCTest
@testable import Conduck

final class WorkboardDragArrangementTests: XCTestCase {

    // MARK: - The board while a card is lifted

    /// The lifted card leaves the sequence and a placeholder takes the slot it
    /// would land in. There is exactly one placeholder and it occupies space —
    /// a ghost drawn over the current arrangement would sit on an occupied card
    /// and read as replacement rather than insertion.
    func testTheSourceLeavesTheBoardAndAPlaceholderTakesItsSlot() {
        let ids = makeIDs(4)
        let entries = WorkboardDragArrangement.entries(
            displayedIDs: ids,
            sourceID: ids[0],
            acceptedSlot: 3
        )

        XCTAssertEqual(
            entries,
            [.card(ids[1]), .card(ids[2]), .placeholder, .card(ids[3])]
        )
        XCTAssertEqual(entries.count, ids.count, "the placeholder still occupies a slot")
        XCTAssertEqual(entries.filter { $0 == .placeholder }.count, 1)
        XCTAssertFalse(
            entries.contains(.card(ids[0])),
            "the source is excluded, so it can never be its own drop neighbour"
        )
    }

    /// No drag, no accepted slot, or a source the board no longer holds — it was
    /// deleted under the finger, or a picture arrived and folded it away — all
    /// draw the plain order. A placeholder left behind for a card that is gone
    /// is a gap nothing can fill.
    func testABoardWithNoLiveSourceDrawsThePlainOrder() {
        let ids = makeIDs(3)
        let plain: [WorkboardDragArrangement.Entry] = ids.map { .card($0) }

        XCTAssertEqual(
            WorkboardDragArrangement.entries(displayedIDs: ids, sourceID: nil, acceptedSlot: 2),
            plain
        )
        XCTAssertEqual(
            WorkboardDragArrangement.entries(displayedIDs: ids, sourceID: ids[1], acceptedSlot: nil),
            plain
        )
        XCTAssertEqual(
            WorkboardDragArrangement.entries(displayedIDs: ids, sourceID: UUID(), acceptedSlot: 1),
            plain
        )
        XCTAssertEqual(
            WorkboardDragArrangement.entries(displayedIDs: [], sourceID: UUID(), acceptedSlot: 0),
            []
        )
    }

    // MARK: - The trap

    /// THE INVARIANT: the placeholder is drawn where the card actually lands.
    ///
    /// Checked over every (source, slot) pair on a six-card board, including
    /// the twelve pairs where the move is a no-op — the planner answers nil for
    /// a card dropped into either of its own bounding slots, and the board must
    /// then look exactly as it did, with the placeholder back in the source's
    /// own position rather than one place to its left.
    func testThePlaceholderSitsWhereTheCardWillActuallyLand() {
        let ids = makeIDs(6)
        let materials = ids.map { makeMaterial(id: $0) }

        for sourceIndex in ids.indices {
            for slot in 0...ids.count {
                let entries = WorkboardDragArrangement.entries(
                    displayedIDs: ids,
                    sourceID: ids[sourceIndex],
                    acceptedSlot: slot
                )
                let drawnAt = entries.firstIndex(of: .placeholder)
                let planned = WorkboardMaterialOrdering.order(
                    moving: ids[sourceIndex],
                    toInsertionIndex: slot,
                    in: materials
                ) ?? ids
                let landsAt = planned.firstIndex(of: ids[sourceIndex])

                XCTAssertEqual(
                    drawnAt, landsAt,
                    "source \(sourceIndex) into slot \(slot): drawn at "
                        + "\(String(describing: drawnAt)), lands at \(String(describing: landsAt))"
                )
            }
        }
    }

    /// The subtraction stated on its own, plus its clamps: an out-of-range slot
    /// resolves rather than traps, because the geometry answers for the layout
    /// it last measured and a removal can arrive between the two.
    func testPlaceholderIndexAdjustsOnceAndClampsRatherThanTrapping() {
        XCTAssertEqual(
            WorkboardDragArrangement.placeholderIndex(forSlot: 4, sourceIndex: 1, count: 6),
            3,
            "a gap after the source shifts down by one when the source is lifted out"
        )
        XCTAssertEqual(
            WorkboardDragArrangement.placeholderIndex(forSlot: 1, sourceIndex: 4, count: 6),
            1,
            "a gap before the source is unmoved by the lift"
        )
        XCTAssertEqual(WorkboardDragArrangement.placeholderIndex(forSlot: 99, sourceIndex: 0, count: 6), 5)
        XCTAssertEqual(WorkboardDragArrangement.placeholderIndex(forSlot: -4, sourceIndex: 3, count: 6), 0)
        XCTAssertEqual(
            WorkboardDragArrangement.placeholderIndex(forSlot: 2, sourceIndex: nil, count: 6),
            2,
            "with no source lifted there is nothing to adjust for"
        )
        XCTAssertEqual(
            WorkboardDragArrangement.placeholderIndex(forSlot: 2, sourceIndex: 9, count: 6),
            2,
            "a source the board no longer holds adjusts for nothing"
        )
        XCTAssertEqual(WorkboardDragArrangement.placeholderIndex(forSlot: 0, sourceIndex: 0, count: 1), 0)
    }

    // MARK: - Commit

    /// Release names a CARD, not an integer. The drop decodes its payload
    /// asynchronously and the reorder then waits for the desk's mutation lane;
    /// an arrival landing in either gap changes what an integer means, while a
    /// neighbour id is re-found in whatever order the planner eventually sees.
    func testCommitTargetNamesAVisibleNeighbourAndASide() {
        let ids = makeIDs(3)

        assertTarget(slot: 0, in: ids, is: ids[0], .before)
        assertTarget(slot: 2, in: ids, is: ids[2], .before)
        // The append slot has no card of its own, so it is said as "after the
        // last one" — the only form the planner can re-resolve.
        assertTarget(slot: 3, in: ids, is: ids[2], .after)
        assertTarget(slot: 99, in: ids, is: ids[2], .after)
        assertTarget(slot: -7, in: ids, is: ids[0], .before)
        XCTAssertNil(WorkboardDragArrangement.commitTarget(slot: 0, displayedIDs: []))
    }

    /// The commit target and the slot agree: resolving a slot to a neighbour and
    /// planning from that neighbour gives the same order as planning from the
    /// slot directly. Otherwise release would land somewhere the hover never
    /// promised.
    func testCommitTargetPlansTheSameOrderTheSlotDid() {
        let ids = makeIDs(5)
        let materials = ids.map { makeMaterial(id: $0) }

        for sourceIndex in ids.indices {
            for slot in 0...ids.count {
                let bySlot = WorkboardMaterialOrdering.order(
                    moving: ids[sourceIndex], toInsertionIndex: slot, in: materials
                )
                let target = WorkboardDragArrangement.commitTarget(slot: slot, displayedIDs: ids)
                let byNeighbour = target.flatMap { target in
                    WorkboardMaterialOrdering.order(
                        moving: ids[sourceIndex],
                        relativeTo: target.neighbourID,
                        placement: target.placement,
                        in: materials
                    )
                }
                XCTAssertEqual(
                    bySlot, byNeighbour,
                    "source \(sourceIndex) into slot \(slot) planned two different boards"
                )
            }
        }
    }

    // MARK: - Helpers

    private func assertTarget(
        slot: Int,
        in displayedIDs: [UUID],
        is expectedID: UUID,
        _ expectedPlacement: WorkboardReorderPlacement,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let target = WorkboardDragArrangement.commitTarget(slot: slot, displayedIDs: displayedIDs) else {
            XCTFail("slot \(slot) resolved to no neighbour", file: file, line: line)
            return
        }
        XCTAssertEqual(target.neighbourID, expectedID, "slot \(slot)", file: file, line: line)
        XCTAssertEqual(target.placement, expectedPlacement, "slot \(slot)", file: file, line: line)
    }

    private func makeIDs(_ count: Int) -> [UUID] {
        (0..<count).map { _ in UUID() }
    }

    private func makeMaterial(id: UUID) -> WorkboardMaterialSnapshot {
        WorkboardMaterialSnapshot(id: id, kind: .note, name: id.uuidString)
    }
}
