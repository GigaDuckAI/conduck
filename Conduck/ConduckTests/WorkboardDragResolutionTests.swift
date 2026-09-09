// SPDX-License-Identifier: Apache-2.0

// ConduckTests
// WorkboardDragResolutionTests.swift
//
// The two geometry rules a live drag needs that the mosaic engine does not
// answer, and the failure each one exists to prevent.
//
// A STILL POINTER OVER A MOVING BOARD. A drop delegate reports a location only
// when the pointer moves, and edge autoscroll is precisely the case where the
// pointer deliberately stops. The board therefore keeps the pointer in the
// space its own frame is measured in and re-derives the board-local point from
// the frame's current origin. Negative control: store the board-LOCAL point
// instead, and the scroll case below cannot change the accepted slot at all.
//
// A LIST'S LINES ARE MEASUREMENTS, NOT ARITHMETIC. The mosaic's slot lines are
// a pure function of (count, width, metrics) so they hold still while a card is
// lifted out of them; a list's come from measured row frames, rows have a
// minimum height rather than a fixed one, and the reflow moves every row the
// pointer is compared against. So the list freezes the frames at the lift — and
// refuses rather than answers once the order OR the heights they were measured
// in stop being the ones on screen. The refusal cases are the point of this suite: answering
// from a stale map moves a card the person never aimed at, which is exactly the
// class of bug a fixed-slot drag was adopted to remove.

import XCTest
@testable import Conduck

final class WorkboardDragResolutionTests: XCTestCase {

    // MARK: - The pointer, across a scroll

    /// The conversion is exact in both directions, because a drop location
    /// arrives board-local, is stored in the outer space, and is read back
    /// board-local on every layout pass.
    func testStoringAndRereadingAPointerChangesNothingWhileTheBoardHoldsStill() {
        let origin = CGPoint(x: 37.5, y: 412.25)
        let local = CGPoint(x: 128, y: 96.5)

        let stored = WorkboardDragResolution.globalPoint(board: local, boardOrigin: origin)
        let reread = WorkboardDragResolution.boardPoint(global: stored, boardOrigin: origin)

        XCTAssertEqual(reread.x, local.x, accuracy: 0.0001)
        XCTAssertEqual(reread.y, local.y, accuracy: 0.0001)
    }

    /// The board scrolls exactly one row band under a pointer that has not
    /// moved, and the accepted slot advances by exactly one row of cards.
    ///
    /// This is the whole reason the pointer is stored in the board's OUTER
    /// space: a board-local point cannot express this, because the delegate
    /// never fires and the local point never changes.
    func testAStillPointerAcceptsANewSlotOnceTheBoardScrollsUnderIt() throws {
        let engine = WorkboardMosaicEngine(metrics: .standard)
        let width: CGFloat = 1440
        let perRow = engine.cardsPerRow(forWidth: width)
        let count = perRow * 3
        let frames = engine.presentedSlotFrames(
            count: count,
            width: width,
            layoutDirection: .leftToRight
        )
        try XCTSkipUnless(frames.count == count && perRow >= 2, "the grid must place every card")

        let rowBand = frames[perRow].minY - frames[0].minY
        XCTAssertGreaterThan(rowBand, 0, "three rows of cards must occupy three bands")

        // The pointer sits in the first row, just left of the second slot's
        // midpoint, and never moves again.
        let originBefore = CGPoint(x: 24, y: 300)
        let pointer = WorkboardDragResolution.globalPoint(
            board: CGPoint(x: frames[1].midX - 1, y: frames[0].midY),
            boardOrigin: originBefore
        )

        func slot(boardOrigin: CGPoint) -> Int {
            engine.insertionSlot(
                at: WorkboardDragResolution.boardPoint(global: pointer, boardOrigin: boardOrigin),
                count: count,
                width: width,
                layoutDirection: .leftToRight
            )
        }

        let before = slot(boardOrigin: originBefore)
        // Scrolling the content up moves the board's own origin up by the same
        // amount; nothing else about the drag changes.
        let after = slot(boardOrigin: CGPoint(x: originBefore.x, y: originBefore.y - rowBand))

        XCTAssertEqual(before, 1)
        XCTAssertEqual(
            after,
            before + perRow,
            "one band of scroll under a still pointer is one row of cards further down the order"
        )
    }

    // MARK: - The list's slot

    /// Rows have a minimum height and grow with their text, so the lines a list
    /// resolves against are unequal. The gap is decided by each row's own
    /// midpoint and by nothing uniform.
    func testAListResolvesEveryGapFromItsOwnUnequalRowMidpoints() {
        let ids = makeIDs(3)
        // 88 (the row minimum), then a tall row, then the minimum again.
        let frames = rowFrames(ids: ids, heights: [88, 176, 88])

        XCTAssertEqual(slot(y: 10, ids: ids, frames: frames), 0, "above the first midpoint is the head")
        XCTAssertEqual(slot(y: 43, ids: ids, frames: frames), 0)
        XCTAssertEqual(slot(y: 45, ids: ids, frames: frames), 1, "past the first midpoint is the first gap")
        XCTAssertEqual(slot(y: 175, ids: ids, frames: frames), 1, "the tall row keeps its own upper half")
        XCTAssertEqual(slot(y: 190, ids: ids, frames: frames), 2)
        XCTAssertEqual(slot(y: 400, ids: ids, frames: frames), 3, "below every midpoint appends")
    }

    /// The frozen map is true of ONE order. A capture that landed, a peer's
    /// reorder, or a recording folding into an arriving picture all leave it
    /// describing a board that is no longer on screen — and comparing the new
    /// order against the old midpoints names a different gap than the one under
    /// the pointer.
    func testAListRefusesOnceTheOrderItMeasuredIsNoLongerTheOrderOnScreen() {
        let ids = makeIDs(3)
        let frames = rowFrames(ids: ids, heights: [88, 88, 88])
        let pointer = CGPoint(x: 40, y: 190)

        XCTAssertNotNil(
            WorkboardDragResolution.listSlot(
                at: pointer,
                baseline: ids,
                displayedIDs: ids,
                frames: frames
            )
        )
        XCTAssertNil(
            WorkboardDragResolution.listSlot(
                at: pointer,
                baseline: ids,
                displayedIDs: [ids[2], ids[0], ids[1]],
                frames: frames
            ),
            "a peer rearranged the desk while the card was in the air"
        )
        XCTAssertNil(
            WorkboardDragResolution.listSlot(
                at: pointer,
                baseline: ids,
                displayedIDs: ids + makeIDs(1),
                frames: frames
            ),
            "a capture landed, and the arriving row has no measured line of its own"
        )
        XCTAssertNil(
            WorkboardDragResolution.listSlot(
                at: pointer,
                baseline: ids,
                displayedIDs: [ids[0], ids[1]],
                frames: frames
            ),
            "a card left the board"
        )
    }

    /// An incomplete measurement is a refusal, not a zero. Skipping the
    /// unmeasured row instead would make the gap above it unreachable through
    /// its own upper half, and falling back to the head of the board would move
    /// a card to a place the pointer was nowhere near.
    func testAnIncompleteOrNonsensicalMeasurementRefusesRatherThanGuesses() {
        let ids = makeIDs(3)
        var frames = rowFrames(ids: ids, heights: [88, 88, 88])
        frames[ids[1]] = nil

        XCTAssertNil(
            WorkboardDragResolution.listSlot(
                at: CGPoint(x: 40, y: 190),
                baseline: ids,
                displayedIDs: ids,
                frames: frames
            ),
            "one row without a measured frame invalidates the whole baseline"
        )
        XCTAssertNil(
            WorkboardDragResolution.listSlot(
                at: CGPoint(x: 40, y: CGFloat.nan),
                baseline: ids,
                displayedIDs: ids,
                frames: rowFrames(ids: ids, heights: [88, 88, 88])
            ),
            "a pointer that is not a number cannot name a gap"
        )
        XCTAssertNil(
            WorkboardDragResolution.listSlot(
                at: CGPoint(x: 40, y: 10),
                baseline: [],
                displayedIDs: [],
                frames: [:]
            ),
            "an empty board has no gap to name; the caller declines the drop"
        )
    }

    /// The placeholder stands in the source row's own measured height, so the
    /// rows below it do not travel when the card lifts out of them. A guess
    /// would move exactly the lines the drag is resolving against.
    func testTheListPlaceholderTakesTheSourceRowsOwnHeight() {
        let ids = makeIDs(2)
        let frames = rowFrames(ids: ids, heights: [88, 176])

        XCTAssertEqual(
            WorkboardDragResolution.placeholderHeight(for: ids[1], frames: frames, fallback: 88),
            176
        )
        XCTAssertEqual(
            WorkboardDragResolution.placeholderHeight(for: makeIDs(1)[0], frames: frames, fallback: 88),
            88,
            "an unmeasured source falls back to the row minimum rather than collapsing"
        )
        XCTAssertEqual(
            WorkboardDragResolution.placeholderHeight(
                for: ids[0],
                frames: [ids[0]: CGRect(x: 0, y: 0, width: 320, height: CGFloat.nan)],
                fallback: 88
            ),
            88
        )
    }

    // MARK: - Whether a live drag survives the desk moving

    /// A capture landing mid-drag is not a reason to cancel a TILES drag: its
    /// slot lines come from (count, width) and nothing the desk stores, so it
    /// rebases on the new count. Cancelling here would make the board unusable
    /// on a device that syncs while a person is arranging it.
    func testATilesDragRebasesThroughAnArrivalRatherThanCancelling() {
        let ids = makeIDs(3)
        let arriving = makeIDs(1)

        XCTAssertTrue(
            WorkboardDragResolution.dragSurvives(
                sourceID: ids[0],
                listBaseline: ids,
                displayedIDs: ids + arriving,
                isCommitted: false,
                resolvesByMeasuredRows: false
            )
        )
        XCTAssertFalse(
            WorkboardDragResolution.dragSurvives(
                sourceID: ids[0],
                listBaseline: ids,
                displayedIDs: ids + arriving,
                isCommitted: false,
                resolvesByMeasuredRows: true
            ),
            "a list has no arithmetic to rebase with — only measurements of an order that has gone"
        )
    }

    /// The three ends. Each one is a case where continuing would put the card
    /// somewhere the person never pointed at, or draw it twice.
    func testADragEndsWhenItsSourceGoesWhenItCommitsAndWhenAListBaselineDies() {
        let ids = makeIDs(3)

        XCTAssertFalse(
            WorkboardDragResolution.dragSurvives(
                sourceID: ids[1],
                listBaseline: ids,
                displayedIDs: [ids[0], ids[2]],
                isCommitted: false,
                resolvesByMeasuredRows: false
            ),
            "the lifted card was removed, or an arriving picture folded it away"
        )
        XCTAssertFalse(
            WorkboardDragResolution.dragSurvives(
                sourceID: ids[0],
                listBaseline: ids,
                displayedIDs: ids,
                isCommitted: true,
                resolvesByMeasuredRows: false
            ),
            "the view model owns the order once the commit lands"
        )
        XCTAssertFalse(
            WorkboardDragResolution.dragSurvives(
                sourceID: ids[0],
                listBaseline: ids,
                displayedIDs: [ids[2], ids[0], ids[1]],
                isCommitted: false,
                resolvesByMeasuredRows: true
            ),
            "a peer rearranged the rows the list had measured"
        )
        XCTAssertTrue(
            WorkboardDragResolution.dragSurvives(
                sourceID: ids[0],
                listBaseline: ids,
                displayedIDs: ids,
                isCommitted: false,
                resolvesByMeasuredRows: true
            ),
            "an untouched board keeps the drag alive in both layouts"
        )
    }

    // MARK: - The rows themselves being re-measured

    /// The order holds still and the ROWS change. A list row states a minimum
    /// height and grows with its text, so a resize or a Dynamic Type change
    /// re-measures every row without touching the order — and the frozen map
    /// keeps answering the gap that used to be under the pointer.
    ///
    /// The assertion is the wrong answer AND the refusal that now precedes it:
    /// at y = 70 the frozen 88-point rows name gap 1, the rows actually on
    /// screen put that point in gap 0, and `measuredRowsHold` is what stops the
    /// board from committing the first number.
    func testRowsReMeasuredTallerEndTheListDragRatherThanNameTheOldGap() {
        let ids = makeIDs(3)
        let frozen = rowFrames(ids: ids, heights: [88, 88, 88])
        let live = rowFrames(ids: ids, heights: [176, 176, 176])

        XCTAssertEqual(slot(y: 70, ids: ids, frames: frozen), 1)
        XCTAssertEqual(slot(y: 70, ids: ids, frames: live), 0)

        XCTAssertFalse(
            WorkboardDragResolution.measuredRowsHold(
                frozen: frozen,
                live: live,
                frozenWidth: 320,
                liveWidth: 320
            ),
            "a row that re-measured taller invalidates the map the drag froze"
        )
    }

    /// A window resized mid-drag. The width the frames were measured at is part
    /// of what makes them true, so it is checked directly rather than waited
    /// for as a height change that may or may not follow.
    func testAWidthChangeEndsTheListDrag() {
        let ids = makeIDs(3)
        let frames = rowFrames(ids: ids, heights: [88, 88, 88])

        XCTAssertFalse(
            WorkboardDragResolution.measuredRowsHold(
                frozen: frames,
                live: frames,
                frozenWidth: 320,
                liveWidth: 520
            )
        )
        XCTAssertFalse(
            WorkboardDragResolution.measuredRowsHold(
                frozen: frames,
                live: frames,
                frozenWidth: .nan,
                liveWidth: 320
            ),
            "an unmeasured width cannot certify anything"
        )
    }

    /// The reflow a drag itself causes must NOT end it. The lifted card leaves
    /// the view tree and stops publishing a frame, and the rows below it move —
    /// their origins change, their heights do not — so the map still holds.
    func testTheDragsOwnReflowDoesNotEndIt() {
        let ids = makeIDs(3)
        let frozen = rowFrames(ids: ids, heights: [88, 120, 88])
        // The source is gone from the live map, and everything below it slid up
        // by its height plus the stack's spacing.
        var live: [UUID: CGRect] = [:]
        live[ids[1]] = CGRect(x: 0, y: 0, width: 320, height: 120)
        live[ids[2]] = CGRect(x: 0, y: 130, width: 320, height: 88)

        XCTAssertTrue(
            WorkboardDragResolution.measuredRowsHold(
                frozen: frozen,
                live: live,
                frozenWidth: 320,
                liveWidth: 320
            ),
            "a lifted source and shifted origins are the drag working, not the map expiring"
        )
    }

    /// Sub-point measurement noise is not a re-measure. Rows land on fractional
    /// heights, and a drag that died on a rounding difference would die on most
    /// boards.
    func testSubPointHeightNoiseKeepsTheListDragAlive() {
        let ids = makeIDs(2)
        let frozen = rowFrames(ids: ids, heights: [88, 88])
        let live = rowFrames(ids: ids, heights: [88.3, 87.8])

        XCTAssertTrue(
            WorkboardDragResolution.measuredRowsHold(
                frozen: frozen,
                live: live,
                frozenWidth: 320,
                liveWidth: 320.2
            )
        )
    }

    // MARK: - Point to commit, end to end

    /// The append edge, resolved the way the board actually resolves it: a
    /// point below every row becomes the slot past the last card, which
    /// `commitTarget` names as AFTER the last card and the planner then lands
    /// at the end of the order. The board's trailing padding is a real drop
    /// region precisely so this point exists.
    func testAPointBelowEveryRowCommitsToTheEndOfTheOrder() throws {
        let materials = (0..<3).map {
            WorkboardMaterialSnapshot(kind: .note, name: "Note \($0)", sequence: $0)
        }
        let ids = materials.map(\.id)
        let frames = rowFrames(ids: ids, heights: [88, 88, 88])

        let slot = try XCTUnwrap(
            WorkboardDragResolution.listSlot(
                at: CGPoint(x: 40, y: 900),
                baseline: ids,
                displayedIDs: ids,
                frames: frames
            )
        )
        XCTAssertEqual(slot, ids.count)

        let target = try XCTUnwrap(
            WorkboardDragArrangement.commitTarget(slot: slot, displayedIDs: ids)
        )
        XCTAssertEqual(target.neighbourID, ids[2])
        XCTAssertEqual(target.placement, .after)

        // The placeholder is drawn in the last position, and the planner lands
        // the card in that same position. The two subtractions stay one each.
        let entries = WorkboardDragArrangement.entries(
            displayedIDs: ids,
            sourceID: ids[0],
            acceptedSlot: slot
        )
        XCTAssertEqual(entries.lastIndex(of: .placeholder), entries.count - 1)
        XCTAssertEqual(
            WorkboardMaterialOrdering.order(
                moving: ids[0],
                relativeTo: target.neighbourID,
                placement: target.placement,
                in: materials
            ),
            [ids[1], ids[2], ids[0]]
        )
    }

    // MARK: - Source guards: the drop's own resolution

    private static let canvasPath = "Conduck/Views/Workboard/WorkboardCaptureCanvas.swift"

    private func dropBody() throws -> String {
        let source = try RefusalLaneSource.source(at: Self.canvasPath)
        return try RefusalLaneSource.body(
            ofFunction: "drop",
            in: source,
            path: Self.canvasPath
        )
    }

    /// A session the board is merely HOLDING must not answer for a drag it does
    /// not own — and must not silently eat the live-frame fallback either.
    ///
    /// THE FAILURE. Nothing clears `dragSession` when a local lift is released
    /// off the board, so a board can hold a frozen pair long after the gesture
    /// that froze it. Written as `session.map { slot(at:in:) } ?? slot(at:...)`
    /// the two paths never compose: `map` builds an `Int??`, `??` unwraps only
    /// the OUTER optional, and a frozen pair that has stopped describing the
    /// board therefore resolves to nil for everyone. A cross-window drop is then
    /// refused before its payload is decoded — the exact reorder the live-frame
    /// resolver was added to answer, lost to a stale local session.
    ///
    /// `flatMap` composes them: a frozen pair that still answers keeps its
    /// answer, and one that refuses falls through to the measurements that do
    /// describe the board.
    func testAFrozenPairThatRefusesFallsThroughToTheLiveMeasurements() throws {
        let body = try dropBody()

        XCTAssertTrue(
            body.contains("session.flatMap { slot(at: location, in: $0) }"),
            "the frozen resolution must FLATTEN into the live fallback"
        )
        XCTAssertFalse(
            body.contains("session.map { slot(at: location, in: $0) }"),
            "`map` nests the optional, so a refusing session swallows the fallback"
        )
        XCTAssertTrue(
            body.contains("baseline: displayedIDs"),
            "the fallback must ask the live order, not a frozen one"
        )
        XCTAssertTrue(
            body.contains("frames: rowFrames"),
            "the fallback must ask the live row frames, not a frozen map"
        )
    }

    /// The held destination belongs to the session that RESOLVED the drop.
    ///
    /// A board keeps drawing the destination between release and the desk's
    /// write, and that presentation is the lifted card's own hole. A session
    /// whose frozen pair refused drew no hole and is about some OTHER card, so
    /// committing the live slot onto it would open a hole at the wrong card
    /// until the decode disowned it — a visible jump on a board nobody dragged
    /// anything on.
    func testOnlyTheSessionThatResolvedTheSlotHoldsTheDestination() throws {
        let body = try dropBody()

        XCTAssertTrue(
            body.contains("if heldSlot != nil, var session {"),
            "the hold must be conditioned on the FROZEN resolution, not on a session existing"
        )
        XCTAssertFalse(
            body.contains("if var session {"),
            "holding for any session at all commits a hole for a card this drop is not about"
        )
    }

    // MARK: - Fixtures

    private func makeIDs(_ count: Int) -> [UUID] {
        (0..<count).map { _ in UUID() }
    }

    /// Rows stacked head to tail with a 10-point gap, the way the list's
    /// `VStack(spacing: 10)` measures them.
    private func rowFrames(ids: [UUID], heights: [CGFloat]) -> [UUID: CGRect] {
        var frames: [UUID: CGRect] = [:]
        var y: CGFloat = 0
        for (id, height) in zip(ids, heights) {
            frames[id] = CGRect(x: 0, y: y, width: 320, height: height)
            y += height + 10
        }
        return frames
    }

    private func slot(y: CGFloat, ids: [UUID], frames: [UUID: CGRect]) -> Int? {
        WorkboardDragResolution.listSlot(
            at: CGPoint(x: 40, y: y),
            baseline: ids,
            displayedIDs: ids,
            frames: frames
        )
    }
}
