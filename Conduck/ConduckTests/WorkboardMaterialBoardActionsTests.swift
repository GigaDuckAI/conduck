// SPDX-License-Identifier: Apache-2.0

// ConduckTests
// WorkboardMaterialBoardActionsTests.swift
//
// The board is an ordered gallery: one footprint, and cards dragged into a new
// order. These tests hold what a reorder is — a complete permutation rewritten
// under a baseline the drag was planned on, so an arrival that lands while it
// is saving is kept rather than answered with a refusal.
//
// There is no resize gesture to separate it from any more: the board grants
// every card the same tile (`WorkboardFootprint`), so the desk writes no card
// size at all and the stored column is read-only to it.

import XCTest
@testable import Conduck

@MainActor
final class WorkboardMaterialBoardActionsTests: XCTestCase {
    private enum TestError: Error { case expectedFailure, unexpectedCall }

    private final class BoardHarness {
        var item: WorkboardItemSnapshot
        var reorderedOrders: [[UUID]] = []
        var reorderBaselines: [WorkboardReorderBaseline] = []
        var removedMaterialIDs: [UUID] = []
        var removeRevisions: [Int64] = []
        var reorderFails = false
        var removeFails = false
        var loadFails = false
        var loadCount = 0

        init(item: WorkboardItemSnapshot) {
            self.item = item
        }
    }

    // MARK: - Pure planning

    func testInsertionIndexPlanAccountsForTheRemovedCardAndSkipsNoOps() {
        let materials = makeMaterials(count: 4)
        let ids = materials.map(\.id)

        XCTAssertEqual(
            WorkboardMaterialOrdering.order(moving: ids[0], toInsertionIndex: 3, in: materials),
            [ids[1], ids[2], ids[0], ids[3]]
        )
        XCTAssertEqual(
            WorkboardMaterialOrdering.order(moving: ids[3], toInsertionIndex: 0, in: materials),
            [ids[3], ids[0], ids[1], ids[2]]
        )
        // A card dropped into either of its own bounding slots did not move.
        XCTAssertNil(WorkboardMaterialOrdering.order(moving: ids[1], toInsertionIndex: 1, in: materials))
        XCTAssertNil(WorkboardMaterialOrdering.order(moving: ids[1], toInsertionIndex: 2, in: materials))
        // Out-of-range slots clamp rather than trap: the engine reports slots
        // for the layout it just measured, which can lag a removal.
        XCTAssertEqual(
            WorkboardMaterialOrdering.order(moving: ids[0], toInsertionIndex: 99, in: materials),
            [ids[1], ids[2], ids[3], ids[0]]
        )
        XCTAssertNil(WorkboardMaterialOrdering.order(moving: UUID(), toInsertionIndex: 0, in: materials))
    }

    func testRelativeAndDirectionalPlansAgreeWithTheInsertionForm() {
        let materials = makeMaterials(count: 3)
        let ids = materials.map(\.id)

        XCTAssertEqual(
            WorkboardMaterialOrdering.order(
                moving: ids[2],
                relativeTo: ids[0],
                placement: .before,
                in: materials
            ),
            [ids[2], ids[0], ids[1]]
        )
        XCTAssertEqual(
            WorkboardMaterialOrdering.order(
                moving: ids[0],
                relativeTo: ids[1],
                placement: .after,
                in: materials
            ),
            [ids[1], ids[0], ids[2]]
        )
        XCTAssertNil(WorkboardMaterialOrdering.order(
            moving: ids[0],
            relativeTo: ids[0],
            placement: .before,
            in: materials
        ))

        XCTAssertEqual(
            WorkboardMaterialOrdering.order(moving: ids[1], direction: .later, in: materials),
            [ids[0], ids[2], ids[1]]
        )
        XCTAssertEqual(
            WorkboardMaterialOrdering.order(moving: ids[1], direction: .earlier, in: materials),
            [ids[1], ids[0], ids[2]]
        )
        XCTAssertNil(WorkboardMaterialOrdering.order(moving: ids[0], direction: .earlier, in: materials))
        XCTAssertNil(WorkboardMaterialOrdering.order(moving: ids[2], direction: .later, in: materials))
    }

    // MARK: - Reorder

    func testDropReordersOptimisticallyAndAdoptsTheStoredOrder() async {
        let materials = makeMaterials(count: 3)
        let item = makeDesk(materials: materials, revision: 9)
        let harness = BoardHarness(item: item)
        let viewModel = await makeViewModelShowingDesk(harness: harness)
        let ids = materials.map(\.id)

        let moved = await viewModel.reorderMaterial(ids[2], toInsertionIndex: 0)

        XCTAssertTrue(moved)
        XCTAssertEqual(harness.reorderedOrders, [[ids[2], ids[0], ids[1]]])
        XCTAssertEqual(
            harness.reorderBaselines.map(\.orderedIDs),
            [ids],
            "the drag carries the order the person saw as its baseline"
        )
        let stored = viewModel.desk?.materials ?? []
        XCTAssertEqual(stored.map(\.id), [ids[2], ids[0], ids[1]])
        XCTAssertEqual(stored.map(\.sequence), [0, 1, 2], "ranks stay dense")
        XCTAssertGreaterThan(viewModel.desk?.revision ?? 0, 9)
        XCTAssertNil(viewModel.notice)
    }

    func testAccessibilityMoveUsesTheSameStoreCallAsADrag() async {
        let materials = makeMaterials(count: 3)
        let item = makeDesk(materials: materials, revision: 4)
        let harness = BoardHarness(item: item)
        let viewModel = await makeViewModelShowingDesk(harness: harness)
        let ids = materials.map(\.id)

        let movedLater = await viewModel.moveMaterial(ids[0], direction: .later)
        XCTAssertTrue(movedLater)
        XCTAssertEqual(harness.reorderedOrders, [[ids[1], ids[0], ids[2]]])

        // The first card is now second; moving it earlier restores the order.
        let movedBack = await viewModel.moveMaterial(ids[0], direction: .earlier)
        XCTAssertTrue(movedBack)
        XCTAssertEqual(harness.reorderedOrders.last, [ids[0], ids[1], ids[2]])

        let refusedMove = await viewModel.moveMaterial(ids[0], direction: .earlier)
        XCTAssertFalse(refusedMove, "the first card cannot move earlier")
        XCTAssertEqual(harness.reorderedOrders.count, 2, "a refused move never reaches the store")
    }

    func testRefusedReorderRestoresTheOrderAndReportsIt() async {
        let materials = makeMaterials(count: 3)
        let item = makeDesk(materials: materials, revision: 9)
        let harness = BoardHarness(item: item)
        let viewModel = await makeViewModelShowingDesk(harness: harness)
        harness.reorderFails = true
        harness.loadFails = true
        let ids = materials.map(\.id)

        let moved = await viewModel.reorderMaterial(
            ids[0],
            relativeTo: ids[2],
            placement: .after
        )

        XCTAssertFalse(moved)
        XCTAssertEqual(viewModel.desk?.materials.map(\.id), ids)
        XCTAssertEqual(viewModel.desk?.materials.map(\.sequence), [0, 1, 2])
        XCTAssertNotNil(viewModel.notice, "a lost drag is never silent")
    }

    func testRefusedReorderPrefersTheLatestStoredOrderWhenItCanBeRead() async {
        let materials = makeMaterials(count: 3)
        let item = makeDesk(materials: materials, revision: 9)
        let harness = BoardHarness(item: item)
        let viewModel = await makeViewModelShowingDesk(harness: harness)
        harness.reorderFails = true
        // Another device already moved the last card to the front.
        let ids = materials.map(\.id)
        harness.item = makeDesk(
            materials: [materials[2], materials[0], materials[1]],
            revision: 12
        )

        let moved = await viewModel.reorderMaterial(ids[0], toInsertionIndex: 3)

        XCTAssertFalse(moved)
        XCTAssertEqual(harness.loadCount, 1)
        XCTAssertEqual(
            viewModel.desk?.materials.map(\.id),
            [ids[2], ids[0], ids[1]]
        )
    }

    func testAnUnchangedOrderAndAnUnknownCardNeverReachTheStore() async {
        let materials = makeMaterials(count: 2)
        let item = makeDesk(materials: materials, revision: 3)
        let harness = BoardHarness(item: item)
        let viewModel = await makeViewModelShowingDesk(harness: harness)
        let ids = materials.map(\.id)

        let unchanged = await viewModel.reorderMaterial(ids[0], toInsertionIndex: 1)
        let unknownCard = await viewModel.reorderMaterial(UUID(), toInsertionIndex: 0)
        XCTAssertFalse(unchanged)
        XCTAssertFalse(
            unknownCard,
            "a card the desk does not hold is not a card this model can rearrange"
        )
        XCTAssertTrue(harness.reorderedOrders.isEmpty)
        XCTAssertNil(viewModel.notice)
    }

    // MARK: - Footprint

    /// The desk offers no way to change a card's footprint, so the write seam
    /// it used to hold is gone from `Dependencies` entirely — a closure the
    /// board cannot fire is a door that does not exist.
    ///
    /// The stored column survives: a row carrying `large` decodes as `large`
    /// and syncs untouched, and only the RENDERED footprint is normalised. That
    /// is what makes the one-footprint decision reversible on evidence —
    /// flipping `WorkboardFootprint.isUniform` has to find the sizes still
    /// there.
    func testTheDeskRendersOneFootprintWithoutRewritingWhatARowStores() async {
        var materials = makeMaterials(count: 3)
        materials[0].cardSize = .large
        materials[1].cardSize = .small
        let item = makeDesk(materials: materials, revision: 9)
        let harness = BoardHarness(item: item)
        let viewModel = await makeViewModelShowingDesk(harness: harness)

        XCTAssertEqual(
            viewModel.desk?.materials.map(\.cardSize),
            [.large, .small, .standard],
            "the board reads the column back exactly as the rows hold it"
        )
        XCTAssertEqual(
            viewModel.desk?.materials.map(\.renderedCardSize),
            [.standard, .standard, .standard],
            "and draws every one of them at the one footprint the board grants"
        )
        XCTAssertEqual(viewModel.desk?.revision, 9, "reading a footprint writes nothing")
    }

    // MARK: - Board removal

    func testBoardRemovalCASesOnTheItemRevisionWithNoEditorOpen() async {
        let materials = makeMaterials(count: 3)
        let item = makeDesk(materials: materials, revision: 7)
        let harness = BoardHarness(item: item)
        let viewModel = await makeViewModelShowingDesk(harness: harness)
        let ids = materials.map(\.id)

        let removed = await viewModel.removeMaterialFromBoard(ids[1])

        XCTAssertTrue(removed)
        XCTAssertEqual(harness.removedMaterialIDs, [ids[1]])
        XCTAssertEqual(harness.removeRevisions, [7], "the item's own revision is the CAS token")
        XCTAssertEqual(viewModel.desk?.materials.map(\.id), [ids[0], ids[2]])
        XCTAssertNil(viewModel.notice)
    }

    func testBoardRemovalOfAnUnknownCardNeverReachesTheStoreAndAFailureIsReported() async {
        let materials = makeMaterials(count: 2)
        let item = makeDesk(materials: materials, revision: 2)
        let harness = BoardHarness(item: item)
        let viewModel = await makeViewModelShowingDesk(harness: harness)

        let unknown = await viewModel.removeMaterialFromBoard(UUID())
        XCTAssertFalse(unknown)
        XCTAssertTrue(harness.removedMaterialIDs.isEmpty)

        harness.removeFails = true
        let failed = await viewModel.removeMaterialFromBoard(materials[0].id)
        XCTAssertFalse(failed)
        XCTAssertEqual(
            viewModel.desk?.materials.count,
            2,
            "a refused removal leaves the board alone"
        )
        XCTAssertNotNil(viewModel.notice, "a lost removal is never silent")
    }

    // MARK: - One-time tutorial flag

    func testTutorialFlagFlipsOnAcknowledgementAndNeverOnAppearance() async {
        let defaults = InMemoryDefaultsStore()
        let manager = SettingsManager(dependencies: .inMemory(
            defaults: defaults,
            ubiquitous: InMemoryUbiquitousStore(),
            secrets: InMemorySecretStore(),
            cloudAvailable: true
        ))

        var shouldShow = await manager.shouldShowWorkboardTutorial()
        XCTAssertTrue(shouldShow, "an unseen tutorial shows on the first Work visit")

        // Reading the gate is not acknowledgement: a tutorial that never got
        // looked at still gets its turn.
        shouldShow = await manager.shouldShowWorkboardTutorial()
        XCTAssertTrue(shouldShow)

        await manager.markWorkboardTutorialSeen()

        shouldShow = await manager.shouldShowWorkboardTutorial()
        XCTAssertFalse(shouldShow)
        XCTAssertTrue(defaults.bool(forKey: Constants.workboardTutorialSeenKey))
    }

    // MARK: - Fixtures

    /// Work is one desk, so every board fixture carries the fixed desk id: a
    /// snapshot under any other id is not a board this model can address.
    private func makeDesk(
        materials: [WorkboardMaterialSnapshot],
        revision: Int64
    ) -> WorkboardItemSnapshot {
        WorkboardItemSnapshot(
            id: Constants.workboardDeskItemID,
            materials: materials,
            revision: revision
        )
    }

    private func makeMaterials(count: Int) -> [WorkboardMaterialSnapshot] {
        (0..<count).map { index in
            WorkboardMaterialSnapshot(
                kind: .note,
                name: "Thought \(index)",
                textContent: "Thought \(index)",
                sequence: index
            )
        }
    }

    /// The desk the person is looking at, seeded through the real load path.
    /// The seeding read is discounted so the counts below describe only the
    /// corrective reads a refused gesture triggers.
    private func makeViewModelShowingDesk(harness: BoardHarness) async -> WorkboardViewModel {
        let viewModel = makeViewModel(harness: harness)
        await viewModel.load()
        harness.loadCount = 0
        return viewModel
    }

    private func makeViewModel(harness: BoardHarness) -> WorkboardViewModel {
        WorkboardViewModel(dependencies: WorkboardViewModel.Dependencies(
            loadDesk: { [harness] in
                harness.loadCount += 1
                if harness.loadFails { throw TestError.expectedFailure }
                return harness.item
            },
            importMaterial: { _, _, _ in throw TestError.unexpectedCall },
            removeMaterial: { [harness] expectedRevision, materialID in
                harness.removedMaterialIDs.append(materialID)
                harness.removeRevisions.append(expectedRevision)
                if harness.removeFails { throw TestError.expectedFailure }
                harness.item = WorkboardItemSnapshot(
                    id: harness.item.id,
                    title: harness.item.title,
                    objective: harness.item.objective,
                    materials: harness.item.materials.filter { $0.id != materialID },
                    revision: harness.item.revision + 1
                )
                return harness.item
            },
            replaceMaterial: { _, _, _, _ in throw TestError.unexpectedCall },
            openMaterial: { _ in },
            reorderMaterials: { [harness] orderedIDs, baseline in
                harness.reorderedOrders.append(orderedIDs)
                harness.reorderBaselines.append(baseline)
                if harness.reorderFails { throw TestError.expectedFailure }
                let byID = Dictionary(
                    harness.item.materials.map { ($0.id, $0) },
                    uniquingKeysWith: { first, _ in first }
                )
                var reordered = orderedIDs.compactMap { byID[$0] }
                for position in reordered.indices { reordered[position].sequence = position }
                harness.item = WorkboardItemSnapshot(
                    id: harness.item.id,
                    title: harness.item.title,
                    objective: harness.item.objective,
                    materials: reordered,
                    revision: harness.item.revision + 1
                )
                return harness.item
            }
        ))
    }
}
