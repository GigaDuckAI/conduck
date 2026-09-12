// SPDX-License-Identifier: Apache-2.0

// The current project board must expose whole-card native dragging in both
// readable layouts. Provider completion must not outlive its destination,
// change project membership, or move an invisible material. Geometry is local
// to a complete row/tile, so lazy offscreen rows need no guessed measurements.

import XCTest
import SwiftUI
@testable import Conduck

@MainActor
final class WorkDeskReadableReorderTests: XCTestCase {
    private let first = UUID()
    private let second = UUID()
    private let third = UUID()
    private let project = UUID()

    func testWholeTilesAndRowsWireToTheSameNativeDragModifier() throws {
        let board = try RefusalLaneSource.source(at: "Conduck/Views/Workboard/WorkDeskSourceBoard.swift")
        XCTAssertEqual(board.components(separatedBy: ".modifier(readableReorderCard(material))").count - 1, 2)
        XCTAssertTrue(board.contains("if let lastID = visibleIDs.last { trailingReorderTarget(after: lastID) }"))
        let modifier = try RefusalLaneSource.source(at: "Conduck/Views/Workboard/WorkDeskReadableReorder.swift")
        XCTAssertTrue(modifier.contains(".onDrag { isEnabled ? onBegin() : NSItemProvider() }"))
        XCTAssertTrue(modifier.contains(".onDrop(of: [.conduckWorkboardMaterial]"))
        XCTAssertFalse(modifier.contains("DragGesture("), "Native drag must not replace the nested controls' tap gestures.")
        XCTAssertTrue(board.contains("!viewModel.isCapturingIntoDesk"),
            "Decoding must not enqueue a scoped reorder behind another desk mutation.")
    }

    func testTileInsertionUsesReadingDirectionAndListInsertionUsesHeight() {
        let size = CGSize(width: 200, height: 100)
        XCTAssertEqual(placement(x: 20, y: 80, size: size, layout: .tiles), .before)
        XCTAssertEqual(placement(x: 180, y: 20, size: size, layout: .tiles), .after)
        XCTAssertEqual(placement(x: 20, y: 80, size: size, layout: .tiles, direction: .rightToLeft), .after)
        XCTAssertEqual(placement(x: 180, y: 20, size: size, layout: .tiles, direction: .rightToLeft), .before)
        XCTAssertEqual(placement(x: 180, y: 20, size: size, layout: .list), .before)
        XCTAssertEqual(placement(x: 20, y: 80, size: size, layout: .list, direction: .rightToLeft), .after)
    }

    func testUnknownMeasurementsAndSpatialLayoutNeverGuessAnInsertion() {
        XCTAssertNil(placement(x: 1, y: 1, size: .zero, layout: .tiles))
        XCTAssertNil(placement(x: .nan, y: 1, size: .init(width: 100, height: 100), layout: .list))
        XCTAssertNil(placement(x: 1, y: .infinity, size: .init(width: 100, height: 100), layout: .tiles))
        XCTAssertNil(placement(x: 1, y: 1, size: .init(width: CGFloat.infinity, height: 100), layout: .list))
        XCTAssertNil(placement(x: 1, y: 1, size: .init(width: 100, height: 100), layout: .desk))
    }

    func testHoverAndCancellationCreateNoPendingMove() {
        let reorder = WorkDeskReadableReorder()
        reorder.begin(first)
        reorder.hover(target)
        XCTAssertEqual(reorder.target, target)
        XCTAssertFalse(reorder.isResolving)
        reorder.leave(materialID: second)
        XCTAssertNil(reorder.target)
        reorder.hover(target)
        reorder.cancel()
        XCTAssertNil(reorder.sourceID)
        XCTAssertNil(reorder.target)
        XCTAssertFalse(reorder.isResolving)
        XCTAssertNil(reorder.resolve(payload, token: UUID(), current: context(), isEnabled: true))
    }

    func testLeavingAnOldCardCannotClearTheNextCardsInsertionEdge() {
        let reorder = WorkDeskReadableReorder()
        reorder.begin(first)
        reorder.hover(target)
        reorder.hover(.init(materialID: third, placement: .before))
        reorder.leave(materialID: second)
        XCTAssertEqual(reorder.target?.materialID, third)
        reorder.hover(.init(materialID: third, placement: .after, isTrailing: true))
        reorder.leave(materialID: third)
        XCTAssertEqual(reorder.target?.isTrailing, true)
    }

    func testDropResolvesExactlyOnceAndCanComeFromAnotherWindow() throws {
        let reorder = WorkDeskReadableReorder()
        // No local begin: the same-process provider came from another window.
        let token = try XCTUnwrap(reorder.accept(target, context: context()))
        XCTAssertEqual(reorder.resolve(payload, token: token, current: context(), isEnabled: true), target)
        XCTAssertNil(reorder.resolve(payload, token: token, current: context(), isEnabled: true))
        XCTAssertFalse(reorder.isResolving)
    }

    func testMalformedForeignAndSelfDropsNeverResolve() throws {
        let invalidPayloads: [WorkMaterialDragPayload?] = [nil,
            .init(itemID: UUID(), materialID: first),
            .init(itemID: Constants.workboardDeskItemID, materialID: second)
        ]
        for invalid in invalidPayloads {
            let reorder = WorkDeskReadableReorder()
            let token = try XCTUnwrap(reorder.accept(target, context: context()))
            XCTAssertNil(reorder.resolve(invalid, token: token, current: context(), isEnabled: true))
            XCTAssertFalse(reorder.isResolving)
        }
    }

    func testAnInvisibleSourceOrRemovedTargetCannotBeReordered() throws {
        let cases: [(WorkDeskReadableReorderContext, WorkDeskReadableReorderContext)] = [
            (context(ids: [second, third]), context()),
            (context(), context(ids: [second, third])),
            (context(), context(ids: [first, third]))
        ]
        for (previous, current) in cases {
            let reorder = WorkDeskReadableReorder()
            let token = try XCTUnwrap(reorder.accept(target, context: previous))
            XCTAssertNil(reorder.resolve(payload, token: token, current: current, isEnabled: true))
        }
        XCTAssertNil(WorkDeskReadableReorder().accept(target, context: context(ids: [first])))
    }

    func testSourceAndTargetHomesMustStillMatchEvenInAllMaterials() throws {
        for movedID in [first, second] {
            let previous = context(scope: .all, projects: [first: project, second: project])
            var homes = previous.projectIDs
            homes[movedID] = UUID()
            let reorder = WorkDeskReadableReorder()
            let token = try XCTUnwrap(reorder.accept(target, context: previous))
            XCTAssertNil(reorder.resolve(payload, token: token,
                current: context(scope: .all, projects: homes), isEnabled: true))
        }
    }

    func testNavigationSearchLayoutAndDisabledDestinationRefuseLateCompletion() throws {
        let changedContexts = [context(scope: .all), context(search: "different"), context(layout: .tiles)]
        for current in changedContexts {
            let reorder = WorkDeskReadableReorder()
            let token = try XCTUnwrap(reorder.accept(target, context: context()))
            XCTAssertNil(reorder.resolve(payload, token: token, current: current, isEnabled: true))
        }
        let reorder = WorkDeskReadableReorder()
        let token = try XCTUnwrap(reorder.accept(target, context: context()))
        XCTAssertNil(reorder.resolve(payload, token: token, current: context(), isEnabled: false))
    }

    func testLeavingAndReturningToSameScopeDoesNotReviveCancelledDrop() throws {
        let reorder = WorkDeskReadableReorder()
        let token = try XCTUnwrap(reorder.accept(target, context: context()))
        reorder.cancel()
        XCTAssertNil(reorder.resolve(payload, token: token, current: context(), isEnabled: true))
    }

    func testOldProviderCompletionCannotConsumeANewerDrag() throws {
        let reorder = WorkDeskReadableReorder()
        let oldToken = try XCTUnwrap(reorder.accept(target, context: context()))
        reorder.begin(third)
        let newToken = try XCTUnwrap(reorder.accept(target, context: context()))
        XCTAssertNil(reorder.resolve(payload, token: oldToken, current: context(), isEnabled: true))
        XCTAssertTrue(reorder.isResolving)
        let newPayload = WorkMaterialDragPayload(itemID: Constants.workboardDeskItemID, materialID: third)
        XCTAssertEqual(reorder.resolve(newPayload, token: newToken, current: context(), isEnabled: true), target)
    }

    func testArrivalDoesNotChangeTheNeighbourChosenAtRelease() throws {
        let reorder = WorkDeskReadableReorder()
        let token = try XCTUnwrap(reorder.accept(target, context: context()))
        let withArrival = context(ids: [UUID(), first, second, third])
        XCTAssertEqual(reorder.resolve(payload, token: token, current: withArrival, isEnabled: true), target)
    }

    func testFilteredReorderKeepsEveryHiddenMaterialAndItsRelativeOrder() throws {
        let hiddenA = UUID(), hiddenB = UUID()
        let visible = context(ids: [first, second, third])
        let reorder = WorkDeskReadableReorder()
        let token = try XCTUnwrap(reorder.accept(target, context: visible))
        let resolved = try XCTUnwrap(reorder.resolve(payload, token: token, current: visible, isEnabled: true))
        let allIDs = [first, hiddenA, second, hiddenB, third]
        let snapshots = allIDs.enumerated().map { index, id in
            WorkboardMaterialSnapshot(id: id, kind: .note, name: "Material", sequence: index)
        }
        let result = try XCTUnwrap(WorkboardMaterialOrdering.order(moving: first,
            relativeTo: resolved.materialID, placement: resolved.placement, in: snapshots))
        XCTAssertEqual(result, [hiddenA, second, first, hiddenB, third])
        XCTAssertEqual(result.filter { [hiddenA, hiddenB].contains($0) }, [hiddenA, hiddenB])
        XCTAssertEqual(Set(result), Set(allIDs))
    }

    private var target: WorkDeskReadableDropTarget { .init(materialID: second, placement: .after) }
    private var payload: WorkMaterialDragPayload { .init(itemID: Constants.workboardDeskItemID, materialID: first) }

    private func context(scope: WorkDeskScope? = nil, search: String = "", layout: WorkboardLayoutMode = .list,
                         ids: [UUID]? = nil, projects: [UUID: UUID]? = nil) -> WorkDeskReadableReorderContext {
        .init(scope: scope ?? .project(project), search: search, layout: layout,
              visibleIDs: ids ?? [first, second, third],
              projectIDs: projects ?? [first: project, second: project, third: project])
    }

    private func placement(x: CGFloat, y: CGFloat, size: CGSize, layout: WorkboardLayoutMode,
                           direction: LayoutDirection = .leftToRight) -> WorkboardReorderPlacement? {
        WorkDeskReadableReorder.placement(at: .init(x: x, y: y), size: size, layout: layout, direction: direction)
    }
}
