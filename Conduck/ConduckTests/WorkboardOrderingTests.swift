// SPDX-License-Identifier: Apache-2.0

// ConduckTests
// WorkboardOrderingTests.swift
//
// Drag order must survive a fresh desk load and the next capture. A refused
// drag must also preserve cards and edits that arrived while it was saving:
// restoring its old array would silently hide another device's newer work.
// The platform drag provider carries card identity without advertising any
// representation that the desk's external-material importer could claim.

import XCTest
import UniformTypeIdentifiers
@testable import Conduck

@MainActor
final class WorkboardOrderingTests: XCTestCase {
    private enum TestError: Error { case refused, unexpectedCall }
    private let isolated = IsolatedWorkStores()

    override func tearDown() async throws {
        await isolated.cleanUp()
        try await super.tearDown()
    }

    private final class SnapshotGate {
        let entered = XCTestExpectation(description: "Snapshot operation started")
        private var continuation: CheckedContinuation<WorkboardItemSnapshot, any Error>?

        func suspend() async throws -> WorkboardItemSnapshot {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                entered.fulfill()
            }
        }

        func finish(_ result: Result<WorkboardItemSnapshot, any Error>) {
            let pending = continuation
            continuation = nil
            pending?.resume(with: result)
        }
    }

    private final class DeskHarness {
        var desk: WorkboardItemSnapshot
        var loadFails = false
        var recovery: SnapshotGate?
        var reorderedIDs: [[UUID]] = []
        var reorderRevisions: [Int64] = []

        init(desk: WorkboardItemSnapshot) {
            self.desk = desk
        }
    }

    func testPlatformDragProviderRoundTripsIdentityWithoutAdvertisingImportTypes() async {
        let payload = WorkMaterialDragPayload(
            itemID: Constants.workboardDeskItemID,
            materialID: UUID()
        )
        let provider = payload.itemProvider()
        let identifier = UTType.conduckWorkboardMaterial.identifier
        XCTAssertTrue(provider.registeredTypeIdentifiers.contains(identifier))
        XCTAssertTrue(provider.hasItemConformingToTypeIdentifier(identifier))
        let importTypes: [UTType] = [.fileURL, .image, .url, .text, .utf8PlainText]
        for importType in importTypes {
            XCTAssertFalse(
                provider.hasItemConformingToTypeIdentifier(importType.identifier),
                "a card rearrangement must not enter the external \(importType.identifier) import lane"
            )
        }

        let loaded = expectation(description: "Platform loads the card drag representation")
        provider.loadDataRepresentation(forTypeIdentifier: identifier) { data, error in
            defer { loaded.fulfill() }
            XCTAssertNil(error)
            guard let data else {
                XCTFail("The advertised card representation must return its encoded identity")
                return
            }
            do {
                let decoded = try JSONDecoder().decode(WorkMaterialDragPayload.self, from: data)
                XCTAssertEqual(decoded.itemID, payload.itemID)
                XCTAssertEqual(decoded.materialID, payload.materialID)
            } catch {
                XCTFail("The drop destination cannot decode the platform representation: \(error)")
            }
        }
        await fulfillment(of: [loaded], timeout: 2)
    }

    func testDragOrderSurvivesANewViewModelAndANewCaptureAppendsToIt() async throws {
        let store = isolated.make()
        let inboxURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("workboard-ordering-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: inboxURL) }

        func makeViewModel() -> WorkboardViewModel {
            let repository = WorkboardLiveRepository(
                store: store,
                captureInbox: WorkCaptureInbox(baseURL: inboxURL),
                openMaterial: { _ in }
            )
            return WorkboardViewModel(dependencies: repository.makeDependencies())
        }

        let firstViewModel = makeViewModel()
        await firstViewModel.load()
        for thought in ["First thought", "Second thought", "Third thought"] {
            let added = await firstViewModel.addThought(thought)
            XCTAssertTrue(added)
        }
        let original = try XCTUnwrap(firstViewModel.desk)
        let ids = original.materials.map(\.id)
        let moved = await firstViewModel.reorderMaterial(ids[2], toInsertionIndex: 0)
        XCTAssertTrue(moved)

        // Recreating the presentation and live adapter discards every local
        // optimistic array. This read must recover the stored arrangement.
        let reloadedViewModel = makeViewModel()
        await reloadedViewModel.load()
        XCTAssertEqual(reloadedViewModel.desk?.materials.map(\.id), [ids[2], ids[0], ids[1]])
        XCTAssertEqual(reloadedViewModel.desk?.materials.map(\.sequence), [0, 1, 2])

        let appended = await reloadedViewModel.addThought("Fourth thought")
        XCTAssertTrue(appended)
        let finalViewModel = makeViewModel()
        await finalViewModel.load()
        XCTAssertEqual(
            finalViewModel.desk?.materials.map(\.textContent),
            ["Third thought", "First thought", "Second thought", "Fourth thought"],
            "a capture appends without resetting the person's arrangement"
        )
        XCTAssertEqual(finalViewModel.desk?.materials.map(\.sequence), [0, 1, 2, 3])
    }

    func testDragQueuedBehindACaptureKeepsTheArrivingCardAndUsesItsRevision() async {
        let original = makeDesk(names: ["First", "Second", "Third"], revision: 4)
        let harness = DeskHarness(desk: original)
        let capture = SnapshotGate()
        let reorder = SnapshotGate()
        let viewModel = makeViewModel(harness: harness, reorder: reorder, capture: capture)
        await viewModel.load()

        let addThought = Task { @MainActor in await viewModel.addThought("Arriving thought") }
        await fulfillment(of: [capture.entered], timeout: 2)
        let ids = original.materials.map(\.id)
        let dragStarted = expectation(description: "Drag queued during capture")
        let drag = Task { @MainActor in
            dragStarted.fulfill()
            return await viewModel.reorderMaterial(ids[0], relativeTo: ids[2], placement: .after)
        }
        await fulfillment(of: [dragStarted], timeout: 2)
        XCTAssertTrue(harness.reorderedIDs.isEmpty, "a drag waits until the capture finishes")

        var captured = original
        captured.revision = 5
        let arriving = makeMaterial(name: "Arriving thought", sequence: 3)
        captured.materials.append(arriving)
        capture.finish(.success(captured))
        let added = await addThought.value
        XCTAssertTrue(added)
        await fulfillment(of: [reorder.entered], timeout: 2)

        let expectedIDs = [ids[1], ids[2], ids[0], arriving.id]
        XCTAssertEqual(harness.reorderedIDs, [expectedIDs], "the drag retains the completed capture")
        XCTAssertEqual(harness.reorderRevisions, [5], "a queued drag uses the captured desk's revision")
        var reordered = captured
        reordered.revision = 6
        reordered.materials = [original.materials[1], original.materials[2], original.materials[0], arriving]
        for index in reordered.materials.indices { reordered.materials[index].sequence = index }
        reorder.finish(.success(reordered))
        let moved = await drag.value

        XCTAssertTrue(moved)
        XCTAssertEqual(viewModel.desk?.materials.map(\.id), expectedIDs)
        XCTAssertFalse(viewModel.isMutatingDesk)
    }

    func testFailedDragAndFailedRecoveryReadPreserveANewerLoadedDesk() async {
        let original = makeDesk(names: ["First", "Second"], revision: 4)
        let harness = DeskHarness(desk: original)
        let reorder = SnapshotGate()
        let viewModel = makeViewModel(harness: harness, reorder: reorder)
        await viewModel.load()

        let drag = Task { @MainActor in
            await viewModel.reorderMaterial(original.materials[1].id, toInsertionIndex: 0)
        }
        await fulfillment(of: [reorder.entered], timeout: 2)

        // The existing card was edited as well as a new card arriving. A
        // rollback must preserve both, not just union the old and new IDs.
        var newer = original
        newer.revision = 11
        newer.materials[0].textContent = "Edited on another device"
        newer.materials.append(makeMaterial(name: "Arrived", sequence: 2))
        harness.desk = newer
        await viewModel.load()
        harness.loadFails = true
        reorder.finish(.failure(TestError.refused))
        let moved = await drag.value

        XCTAssertFalse(moved)
        XCTAssertEqual(viewModel.desk?.revision, 11)
        XCTAssertEqual(viewModel.desk?.materials.map(\.id), newer.materials.map(\.id))
        XCTAssertEqual(viewModel.desk?.materials.first?.textContent, "Edited on another device")
        XCTAssertNotNil(viewModel.notice, "the refused drag still needs an explanation")
        XCTAssertFalse(viewModel.isMutatingDesk, "a refused drag releases the capture lane")
    }

    func testFailedDragRecoveryCannotReplaceADeskLoadedWhileItsReadWasPending() async {
        let original = makeDesk(names: ["First", "Second"], revision: 4)
        let harness = DeskHarness(desk: original)
        let reorder = SnapshotGate()
        let recovery = SnapshotGate()
        let viewModel = makeViewModel(harness: harness, reorder: reorder)
        await viewModel.load()

        let drag = Task { @MainActor in
            await viewModel.reorderMaterial(original.materials[1].id, toInsertionIndex: 0)
        }
        await fulfillment(of: [reorder.entered], timeout: 2)
        harness.recovery = recovery
        reorder.finish(.failure(TestError.refused))
        await fulfillment(of: [recovery.entered], timeout: 2)

        // A CloudKit refresh completes while the drag's corrective read still
        // carries the older snapshot it fetched before that import.
        var newer = original
        newer.revision = 11
        newer.materials.append(makeMaterial(name: "Arrived", sequence: 2))
        harness.desk = newer
        await viewModel.load()
        recovery.finish(.success(original))
        let moved = await drag.value

        XCTAssertFalse(moved)
        XCTAssertEqual(viewModel.desk?.revision, 11)
        XCTAssertEqual(viewModel.desk?.materials.map(\.id), newer.materials.map(\.id))
        XCTAssertNotNil(viewModel.notice)
        XCTAssertFalse(viewModel.isMutatingDesk)
    }

    private func makeViewModel(
        harness: DeskHarness,
        reorder: SnapshotGate,
        capture: SnapshotGate? = nil
    ) -> WorkboardViewModel {
        WorkboardViewModel(dependencies: WorkboardViewModel.Dependencies(
            loadDesk: { [harness] in
                if let recovery = harness.recovery {
                    harness.recovery = nil
                    return try await recovery.suspend()
                }
                if harness.loadFails { throw TestError.refused }
                return harness.desk
            },
            importMaterial: { _, _, _ in
                guard let capture else { throw TestError.unexpectedCall }
                return try await capture.suspend()
            },
            removeMaterial: { _, _ in throw TestError.unexpectedCall },
            replaceMaterial: { _, _, _, _ in throw TestError.unexpectedCall },
            openMaterial: { _ in },
            reorderMaterials: { [harness] ids, revision in
                harness.reorderedIDs.append(ids)
                harness.reorderRevisions.append(revision)
                return try await reorder.suspend()
            }
        ))
    }

    private func makeDesk(names: [String], revision: Int64) -> WorkboardItemSnapshot {
        WorkboardItemSnapshot(
            id: Constants.workboardDeskItemID,
            materials: names.enumerated().map { makeMaterial(name: $0.element, sequence: $0.offset) },
            revision: revision
        )
    }

    private func makeMaterial(name: String, sequence: Int) -> WorkboardMaterialSnapshot {
        WorkboardMaterialSnapshot(
            kind: .note,
            name: name,
            textContent: name,
            sequence: sequence
        )
    }
}
