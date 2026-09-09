// SPDX-License-Identifier: Apache-2.0

// Conduck
// WorkboardDragResolution.swift
//
// The two geometry questions a live drag asks that the mosaic engine cannot
// answer, kept pure so both are decidable without a pointer or a window.
//
// WHY THE POINTER IS STORED IN THE BOARD'S OUTER SPACE. `DropDelegate` reports
// a location only when the pointer MOVES. A board that scrolls under a still
// pointer therefore keeps a slot the pointer is no longer over — and edge
// autoscroll is exactly the case where the pointer stops moving on purpose. So
// the canvas keeps the pointer in the coordinate space the board's own frame is
// measured in, and re-derives the board-local point from the frame's current
// origin, which moves with every scroll. `boardPoint` and `globalPoint` are that
// one conversion, written once so the two directions cannot drift.
//
// WHY THE LIST RESOLVES AGAINST A FROZEN BASELINE. The mosaic's slot lines are a
// pure function of (count, width, metrics), so they hold still while a card is
// lifted out of them. A list's are not: its lines come from MEASURED row frames,
// rows have a minimum height rather than a fixed one, and the reflow that lifts
// the source moves every row the pointer is being compared against. The list
// therefore resolves against the frames measured at the lift, and — because a
// frozen map is only true of the order AND the heights it was measured in —
// refuses rather than answers the moment either stops matching the board.
// Refusing costs one gesture; answering from a stale map moves a card the
// person did not aim at.

import CoreGraphics
import Foundation

nonisolated enum WorkboardDragResolution {

    // MARK: - The pointer, across a scroll

    /// The pointer in the board's own coordinates, given the board's current
    /// origin in the outer space both were measured in.
    static func boardPoint(global: CGPoint, boardOrigin: CGPoint) -> CGPoint {
        CGPoint(x: global.x - boardOrigin.x, y: global.y - boardOrigin.y)
    }

    /// The inverse: a `DropInfo` location, which arrives board-local, stored in
    /// the outer space so a later scroll can re-derive it.
    static func globalPoint(board point: CGPoint, boardOrigin: CGPoint) -> CGPoint {
        CGPoint(x: point.x + boardOrigin.x, y: point.y + boardOrigin.y)
    }

    // MARK: - The list's slot

    /// The gap in the CURRENT, source-present order that a point falls in,
    /// `0...count`, where `count` appends — the same index the mosaic's
    /// `insertionSlot` returns, so both layouts hand the commit path one kind of
    /// number.
    ///
    /// Returns nil when the frozen baseline cannot honestly answer:
    ///
    ///   * `baseline` no longer equals what the board displays — a capture
    ///     landed, a peer reordered, or a recording folded into a picture. The
    ///     frozen midpoints then describe a layout that is not on screen, and
    ///     comparing the new order against them names a different gap than the
    ///     one under the pointer.
    ///   * a row in the baseline has no measured frame, so the map is
    ///     incomplete and the gap above that row is unreachable.
    ///   * the point itself is not a finite number.
    ///
    /// A nil is a REFUSAL, not a zero: the caller must decline the drop rather
    /// than fall back to the head of the board.
    static func listSlot(
        at point: CGPoint,
        baseline: [UUID],
        displayedIDs: [UUID],
        frames: [UUID: CGRect]
    ) -> Int? {
        guard !baseline.isEmpty, baseline == displayedIDs, point.y.isFinite else { return nil }
        var midpoints: [CGFloat] = []
        midpoints.reserveCapacity(baseline.count)
        for id in baseline {
            guard let frame = frames[id], frame.midY.isFinite else { return nil }
            midpoints.append(frame.midY)
        }
        for (index, midY) in midpoints.enumerated() where point.y < midY {
            return index
        }
        return baseline.count
    }

    // MARK: - Whether a live drag survives the desk moving

    /// Whether a drag in flight can still be answered honestly after the desk
    /// changed underneath it.
    ///
    /// A tiles board REBASES silently and is not asked: its slot lines are a
    /// function of (count, width, metrics) and of nothing the desk stores, so
    /// an arriving capture simply re-resolves. Three changes end a drag
    /// instead, and each is a case where continuing would move a card the
    /// person did not aim at:
    ///
    ///   * `isCommitted` — the release already happened and the view model owns
    ///     the order now. Holding the presentation past that draws the card in
    ///     two places at once.
    ///   * the source is no longer displayed — removed, or folded into a
    ///     picture that arrived. Clearing the whole drag rather than relying on
    ///     the renderer's own fallback is what stops a placeholder reappearing
    ///     if that identifier is ever displayed again without a new lift.
    ///   * `resolvesByMeasuredRows` and the order it measured is gone — the
    ///     list case, where the frozen frames describe a layout that is not on
    ///     screen.
    static func dragSurvives(
        sourceID: UUID,
        listBaseline: [UUID],
        displayedIDs: [UUID],
        isCommitted: Bool,
        resolvesByMeasuredRows: Bool
    ) -> Bool {
        guard !isCommitted, displayedIDs.contains(sourceID) else { return false }
        return !resolvesByMeasuredRows || listBaseline == displayedIDs
    }

    /// Whether the row measurements frozen at the lift still describe the rows
    /// on screen.
    ///
    /// The order test above catches the desk MOVING; this one catches the rows
    /// themselves being re-measured while the order holds still — the window
    /// resized, Dynamic Type changed, or a row's own content settled to a taller
    /// intrinsic height. A list row states a MINIMUM height and grows with its
    /// text, so any of those moves every midpoint the frozen map is being
    /// compared against: with three 88-point rows a point at y = 70 falls in gap
    /// 1, and the same point falls in gap 0 once those rows measure 176, while a
    /// frozen map keeps answering 1.
    ///
    /// The reflow a drag itself causes is NOT such a change: lifting a card and
    /// standing a placeholder in its slot moves row ORIGINS and leaves every
    /// remaining row's height alone. So heights are the signal, compared only
    /// for rows present in both maps — the lifted source has left the view tree
    /// and publishes no frame at all.
    static func measuredRowsHold(
        frozen: [UUID: CGRect],
        live: [UUID: CGRect],
        frozenWidth: CGFloat,
        liveWidth: CGFloat,
        tolerance: CGFloat = 0.5
    ) -> Bool {
        guard frozenWidth.isFinite, liveWidth.isFinite,
              abs(frozenWidth - liveWidth) <= tolerance else { return false }
        for (id, liveFrame) in live {
            guard let frozenFrame = frozen[id] else { continue }
            guard liveFrame.height.isFinite,
                  abs(liveFrame.height - frozenFrame.height) <= tolerance else { return false }
        }
        return true
    }

    /// The height a list placeholder stands in: the source row's own measured
    /// height, so the rows below it do not travel when the card lifts out.
    static func placeholderHeight(
        for sourceID: UUID,
        frames: [UUID: CGRect],
        fallback: CGFloat
    ) -> CGFloat {
        guard let height = frames[sourceID]?.height, height.isFinite, height > 0 else { return fallback }
        return height
    }
}
