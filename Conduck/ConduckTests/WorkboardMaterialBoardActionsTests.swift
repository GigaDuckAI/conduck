// SPDX-License-Identifier: Apache-2.0

// ConduckTests
// WorkboardMaterialBoardActionsTests.swift
//
// The project board is a free card board: cards are dragged into a new order
// and resized. These tests hold the two properties that separates those two
// gestures — reorder rewrites canonical prompt order under the owner's
// optimistic revision, while a resize is presentation and must leave the
// revision, the brief and the shaping transcript untouched.

import XCTest
@testable import Conduck

@MainActor
final class WorkboardMaterialBoardActionsTests: XCTestCase {
    private enum TestError: Error { case expectedFailure, unexpectedCall }

    private final class BoardHarness {
        var item: WorkboardItemSnapshot
        var reorderedOrders: [[UUID]] = []
        var reorderRevisions: [Int64] = []
        var cardSizeWrites: [(materialID: UUID, size: WorkMaterialCardSize)] = []
        var removedMaterialIDs: [UUID] = []
        var removeRevisions: [Int64] = []
        var reorderFails = false
        var cardSizeFails = false
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
        let item = WorkboardItemSnapshot(title: "Launch", materials: materials, revision: 9)
        let harness = BoardHarness(item: item)
        let viewModel = makeViewModel(harness: harness)
        viewModel.items = [item]
        let ids = materials.map(\.id)

        let moved = await viewModel.reorderMaterial(ids[2], toInsertionIndex: 0, in: item.id)

        XCTAssertTrue(moved)
        XCTAssertEqual(harness.reorderedOrders, [[ids[2], ids[0], ids[1]]])
        XCTAssertEqual(harness.reorderRevisions, [9], "the drag carries the order the person saw")
        let stored = viewModel.item(withID: item.id)?.materials ?? []
        XCTAssertEqual(stored.map(\.id), [ids[2], ids[0], ids[1]])
        XCTAssertEqual(stored.map(\.sequence), [0, 1, 2], "ranks stay dense")
        XCTAssertGreaterThan(viewModel.item(withID: item.id)?.revision ?? 0, 9)
        XCTAssertNil(viewModel.notice)
    }

    func testAccessibilityMoveUsesTheSameStoreCallAsADrag() async {
        let materials = makeMaterials(count: 3)
        let item = WorkboardItemSnapshot(title: "Launch", materials: materials, revision: 4)
        let harness = BoardHarness(item: item)
        let viewModel = makeViewModel(harness: harness)
        viewModel.items = [item]
        let ids = materials.map(\.id)

        let movedLater = await viewModel.moveMaterial(ids[0], direction: .later, in: item.id)
        XCTAssertTrue(movedLater)
        XCTAssertEqual(harness.reorderedOrders, [[ids[1], ids[0], ids[2]]])

        // The first card is now second; moving it earlier restores the order.
        let movedBack = await viewModel.moveMaterial(ids[0], direction: .earlier, in: item.id)
        XCTAssertTrue(movedBack)
        XCTAssertEqual(harness.reorderedOrders.last, [ids[0], ids[1], ids[2]])

        let refusedMove = await viewModel.moveMaterial(ids[0], direction: .earlier, in: item.id)
        XCTAssertFalse(refusedMove, "the first card cannot move earlier")
        XCTAssertEqual(harness.reorderedOrders.count, 2, "a refused move never reaches the store")
    }

    func testRefusedReorderRestoresTheOrderAndReportsIt() async {
        let materials = makeMaterials(count: 3)
        let item = WorkboardItemSnapshot(title: "Launch", materials: materials, revision: 9)
        let harness = BoardHarness(item: item)
        harness.reorderFails = true
        harness.loadFails = true
        let viewModel = makeViewModel(harness: harness)
        viewModel.items = [item]
        let ids = materials.map(\.id)

        let moved = await viewModel.reorderMaterial(
            ids[0],
            relativeTo: ids[2],
            placement: .after,
            in: item.id
        )

        XCTAssertFalse(moved)
        XCTAssertEqual(viewModel.item(withID: item.id)?.materials.map(\.id), ids)
        XCTAssertEqual(viewModel.item(withID: item.id)?.materials.map(\.sequence), [0, 1, 2])
        XCTAssertNotNil(viewModel.notice, "a lost drag is never silent")
    }

    func testRefusedReorderPrefersTheLatestStoredOrderWhenItCanBeRead() async {
        let materials = makeMaterials(count: 3)
        let item = WorkboardItemSnapshot(title: "Launch", materials: materials, revision: 9)
        let harness = BoardHarness(item: item)
        harness.reorderFails = true
        // Another device already moved the last card to the front.
        let ids = materials.map(\.id)
        harness.item = WorkboardItemSnapshot(
            id: item.id,
            title: "Launch",
            materials: [materials[2], materials[0], materials[1]],
            revision: 12
        )
        let viewModel = makeViewModel(harness: harness)
        viewModel.items = [item]

        let moved = await viewModel.reorderMaterial(ids[0], toInsertionIndex: 3, in: item.id)

        XCTAssertFalse(moved)
        XCTAssertEqual(harness.loadCount, 1)
        XCTAssertEqual(
            viewModel.item(withID: item.id)?.materials.map(\.id),
            [ids[2], ids[0], ids[1]]
        )
    }

    func testUnknownItemAndUnchangedOrderNeverReachTheStore() async {
        let materials = makeMaterials(count: 2)
        let item = WorkboardItemSnapshot(title: "Launch", materials: materials, revision: 3)
        let harness = BoardHarness(item: item)
        let viewModel = makeViewModel(harness: harness)
        viewModel.items = [item]
        let ids = materials.map(\.id)

        let unchanged = await viewModel.reorderMaterial(ids[0], toInsertionIndex: 1, in: item.id)
        let unknownItem = await viewModel.reorderMaterial(ids[0], toInsertionIndex: 0, in: UUID())
        XCTAssertFalse(unchanged)
        XCTAssertFalse(unknownItem)
        XCTAssertTrue(harness.reorderedOrders.isEmpty)
        XCTAssertNil(viewModel.notice)
    }

    // MARK: - Card size

    func testCardSizeAppliesLocallyWithoutTouchingTheBriefOrTheRevision() async {
        let materials = makeMaterials(count: 2)
        let item = WorkboardItemSnapshot(
            title: "Launch",
            objective: "Compare the plans",
            materials: materials,
            revision: 9,
            lastSentRevision: 9
        )
        let harness = BoardHarness(item: item)
        let viewModel = makeViewModel(harness: harness)
        viewModel.items = [item]
        viewModel.showEditor(for: item)
        let fingerprintBeforeResize = viewModel.editingDraft.contentFingerprint

        let resized = await viewModel.setMaterialCardSize(
            .large,
            materialID: materials[1].id,
            in: item.id
        )

        XCTAssertTrue(resized)
        XCTAssertEqual(harness.cardSizeWrites.count, 1)
        XCTAssertEqual(harness.cardSizeWrites[0].materialID, materials[1].id)
        XCTAssertEqual(harness.cardSizeWrites[0].size, .large)
        XCTAssertEqual(
            viewModel.item(withID: item.id)?.materials.map(\.cardSize),
            [.standard, .large]
        )
        XCTAssertEqual(viewModel.item(withID: item.id)?.revision, 9)
        XCTAssertFalse(viewModel.item(withID: item.id)?.hasChangesSinceLastSend ?? true)
        XCTAssertEqual(viewModel.editingDraft.contentFingerprint, fingerprintBeforeResize)
        XCTAssertTrue(harness.reorderedOrders.isEmpty)
    }

    func testResizingToTheSameSizeIsANoOpAndAFailedResizeRollsBack() async {
        let materials = makeMaterials(count: 2)
        let item = WorkboardItemSnapshot(title: "Launch", materials: materials, revision: 2)
        let harness = BoardHarness(item: item)
        let viewModel = makeViewModel(harness: harness)
        viewModel.items = [item]

        let unchanged = await viewModel.setMaterialCardSize(
            .standard,
            materialID: materials[0].id,
            in: item.id
        )
        XCTAssertTrue(unchanged)
        XCTAssertTrue(harness.cardSizeWrites.isEmpty)

        harness.cardSizeFails = true
        let resized = await viewModel.setMaterialCardSize(
            .small,
            materialID: materials[0].id,
            in: item.id
        )

        XCTAssertFalse(resized)
        XCTAssertEqual(
            viewModel.item(withID: item.id)?.materials.map(\.cardSize),
            [.standard, .standard]
        )
        XCTAssertNotNil(viewModel.notice)
    }

    // MARK: - Board removal

    func testBoardRemovalCASesOnTheItemRevisionWithNoEditorOpen() async {
        let materials = makeMaterials(count: 3)
        let item = WorkboardItemSnapshot(title: "Launch", materials: materials, revision: 7)
        let harness = BoardHarness(item: item)
        let viewModel = makeViewModel(harness: harness)
        viewModel.items = [item]
        let ids = materials.map(\.id)

        // No brief is open: the editor-scoped form would be a silent no-op here.
        XCTAssertNotEqual(viewModel.editingDraft.id, item.id)

        let removed = await viewModel.removeMaterialFromBoard(ids[1], in: item.id)

        XCTAssertTrue(removed)
        XCTAssertEqual(harness.removedMaterialIDs, [ids[1]])
        XCTAssertEqual(harness.removeRevisions, [7], "the item's own revision is the CAS token")
        XCTAssertEqual(viewModel.item(withID: item.id)?.materials.map(\.id), [ids[0], ids[2]])
        XCTAssertNil(viewModel.notice)
    }

    func testBoardRemovalOfAnUnknownCardNeverReachesTheStoreAndAFailureIsReported() async {
        let materials = makeMaterials(count: 2)
        let item = WorkboardItemSnapshot(title: "Launch", materials: materials, revision: 2)
        let harness = BoardHarness(item: item)
        let viewModel = makeViewModel(harness: harness)
        viewModel.items = [item]

        let unknown = await viewModel.removeMaterialFromBoard(UUID(), in: item.id)
        XCTAssertFalse(unknown)
        XCTAssertTrue(harness.removedMaterialIDs.isEmpty)

        harness.removeFails = true
        let failed = await viewModel.removeMaterialFromBoard(materials[0].id, in: item.id)
        XCTAssertFalse(failed)
        XCTAssertEqual(
            viewModel.item(withID: item.id)?.materials.count,
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

    // MARK: - Shaping transcript

    func testShapingTranscriptCarriesCollectedThoughtsAndStaysBounded() {
        let draft = WorkboardEditDraft(item: WorkboardItemSnapshot(
            title: "Launch plan",
            objective: "",
            materials: [
                WorkboardMaterialSnapshot(
                    kind: .note,
                    name: "Pricing",
                    textContent: "Customer interviews favor the smaller launch.",
                    sequence: 0
                ),
                WorkboardMaterialSnapshot(
                    kind: .image,
                    name: "Whiteboard",
                    textContent: "never shaped",
                    sequence: 1
                ),
                WorkboardMaterialSnapshot(
                    kind: .note,
                    name: "Long",
                    textContent: String(repeating: "x", count: 5_000),
                    sequence: 2
                )
            ]
        ))

        let transcript = WorkBriefShapingSource.transcript(for: draft)

        XCTAssertTrue(transcript.contains("Launch plan"))
        XCTAssertTrue(transcript.contains("Customer interviews favor the smaller launch."))
        XCTAssertFalse(transcript.contains("never shaped"), "only thoughts are shaped")
        XCTAssertFalse(
            transcript.contains(String(repeating: "x", count: WorkBriefShapingSource.maximumNoteCharacters + 1))
        )
        XCTAssertLessThanOrEqual(transcript.count, WorkBriefShapingSource.maximumTranscriptCharacters)
    }

    /// Workboard retains no audio, so a voice capture is a transcript card.
    /// The `.note` filter the shaping source uses only covers it because the
    /// projection maps `.transcript` onto `.note` — hold both halves.
    func testAVoiceTranscriptIsANoteCardTheShapingSourceCanSee() {
        let spoken = WorkBriefFixtures.record(
            kind: .transcript,
            title: "Voice note",
            textContent: "Ask legal whether the smaller launch needs a new notice.",
            sequence: 0
        )

        XCTAssertEqual(WorkboardLiveRepository.presentationKind(spoken), .note)

        let draft = WorkboardEditDraft(item: WorkboardItemSnapshot(
            title: "Launch plan",
            objective: "",
            materials: [WorkboardMaterialSnapshot(
                kind: WorkboardLiveRepository.presentationKind(spoken),
                name: WorkboardLiveRepository.materialName(spoken),
                textContent: spoken.textContent,
                sequence: spoken.sequence
            )]
        ))

        XCTAssertTrue(
            WorkBriefShapingSource.transcript(for: draft)
                .contains("Ask legal whether the smaller launch needs a new notice.")
        )
    }

    func testShapingTranscriptOfAThoughtOnlyBriefIsNotEmpty() {
        let draft = WorkboardEditDraft(item: WorkboardItemSnapshot(
            title: "",
            objective: "",
            materials: [WorkboardMaterialSnapshot(
                kind: .note,
                name: "Thought",
                textContent: "Work out whether the smaller launch is defensible.",
                sequence: 0
            )]
        ))

        XCTAssertEqual(
            WorkBriefShapingSource.transcript(for: draft),
            "Collected thoughts:\n- Work out whether the smaller launch is defensible."
        )
    }

    // MARK: - Fixtures

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

    private func makeViewModel(harness: BoardHarness) -> WorkboardViewModel {
        WorkboardViewModel(dependencies: WorkboardViewModel.Dependencies(
            loadItems: { [harness] in
                harness.loadCount += 1
                if harness.loadFails { throw TestError.expectedFailure }
                return [harness.item]
            },
            loadGateways: { ([], []) },
            saveDraft: { _ in throw TestError.unexpectedCall },
            saveDraftAsCopy: { _ in throw TestError.unexpectedCall },
            importMaterial: { _, _, _, _ in throw TestError.unexpectedCall },
            removeMaterial: { [harness] itemID, expectedRevision, materialID in
                harness.removedMaterialIDs.append(materialID)
                harness.removeRevisions.append(expectedRevision)
                if harness.removeFails { throw TestError.expectedFailure }
                XCTAssertEqual(itemID, harness.item.id)
                harness.item = WorkboardItemSnapshot(
                    id: harness.item.id,
                    title: harness.item.title,
                    objective: harness.item.objective,
                    materials: harness.item.materials.filter { $0.id != materialID },
                    revision: harness.item.revision + 1
                )
                return harness.item
            },
            replaceMaterial: { _, _, _, _, _ in throw TestError.unexpectedCall },
            deleteItem: { _ in throw TestError.unexpectedCall },
            duplicateItem: { _ in throw TestError.unexpectedCall },
            reorderItems: { _ in throw TestError.unexpectedCall },
            setState: { _, _ in throw TestError.unexpectedCall },
            acknowledgeRun: { _, _, _ in throw TestError.unexpectedCall },
            dispatch: { _ in throw TestError.unexpectedCall },
            openConversation: { _ in },
            openMaterial: { _ in },
            openGatewaySettings: {},
            reorderMaterials: { [harness] itemID, orderedIDs, expectedRevision in
                harness.reorderedOrders.append(orderedIDs)
                harness.reorderRevisions.append(expectedRevision)
                if harness.reorderFails { throw TestError.expectedFailure }
                XCTAssertEqual(itemID, harness.item.id)
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
            },
            setMaterialCardSize: { [harness] itemID, materialID, size in
                if harness.cardSizeFails { throw TestError.expectedFailure }
                XCTAssertEqual(itemID, harness.item.id)
                harness.cardSizeWrites.append((materialID: materialID, size: size))
            }
        ))
    }
}
