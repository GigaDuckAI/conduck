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

    // MARK: - Folded cards

    /// A drag is planned over the cards the person can SEE, and the store is
    /// handed the cards the desk actually HOLDS. A folded card is one card and
    /// two materials, so the request grows a step before it is sent.
    ///
    /// Negative control: sending the displayed ids unchanged omits the
    /// recording, which `reorderWorkMaterials` refuses as an incomplete set —
    /// here, the first assertion fails.
    func testAReorderRequestExpandsAFoldedCardIntoItsTwoStoredMaterials() async {
        let first = makeMaterial(name: "First", sequence: 0)
        let pair = makeFoldedPicture(name: "screenshot.jpg", recordingName: "Ship the review", sequence: 1)
        let last = makeMaterial(name: "Last", sequence: 3)
        let board = WorkboardItemSnapshot(
            id: Constants.workboardDeskItemID,
            materials: [first, pair.card, last],
            revision: 4
        )
        let harness = DeskHarness(desk: board)
        let reorder = SnapshotGate()
        let viewModel = makeViewModel(harness: harness, reorder: reorder)
        await viewModel.load()

        let drag = Task { @MainActor in
            await viewModel.reorderMaterial(last.id, toInsertionIndex: 0)
        }
        await fulfillment(of: [reorder.entered], timeout: 2)

        XCTAssertEqual(
            harness.reorderedIDs,
            [[last.id, first.id, pair.card.id, pair.recordingID]],
            "the picture and the recording inside it travel adjacent, in that order"
        )
        XCTAssertEqual(
            Set(harness.reorderedIDs[0]).count, harness.reorderedIDs[0].count,
            "every stored material appears exactly once"
        )
        XCTAssertEqual(
            viewModel.desk?.materials.map(\.id), [last.id, first.id, pair.card.id],
            "the hidden recording never enters the rendered board"
        )
        XCTAssertEqual(viewModel.desk?.materials.map(\.sequence), [0, 1, 2])
        XCTAssertEqual(
            viewModel.desk?.materials.last?.companion?.sequence, 3,
            "the optimistic ranks are the dense ranks the store is about to write"
        )

        var refreshed = board
        refreshed.revision = 5
        refreshed.materials = [last, first, pair.card]
        reorder.finish(.success(refreshed))
        let moved = await drag.value
        XCTAssertTrue(moved)
    }

    /// Codex's counterexample, end to end against the real store: two recordings
    /// name one picture, the lower id folds, and moving an UNRELATED card must
    /// not hand the screenshot the other recording.
    ///
    /// The expansion writes dense ranks over the whole desk, so after this drag
    /// the folded recording has the HIGHEST rank of the four. Choosing the
    /// companion by rank would therefore swap it; choosing by lowest id — which
    /// no arrangement can change — keeps it.
    ///
    /// Negative control: with lowest-sequence selection the reload answers
    /// `[X, P[B], A]` and both assertions after the reload fail.
    func testMovingAnUnrelatedCardCannotChangeWhichRecordingIsFolded() async throws {
        let store = isolated.make()
        let inboxURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("workboard-ordering-fold-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: inboxURL) }

        let pictureID = UUID()
        let recordingIDs = [UUID(), UUID()].sorted { $0.uuidString < $1.uuidString }
        let lower = recordingIDs[0]
        let higher = recordingIDs[1]

        // Stored A, B, P, X — A and B both name P, and A is the lower id.
        for (id, title) in [(lower, "A"), (higher, "B")] {
            _ = try await store.upsertDeskMaterial(WorkMaterialDraft(
                id: id,
                kind: .audio,
                title: title,
                filename: "\(title).m4a",
                mimeType: "audio/m4a",
                payload: Data(title.utf8),
                attachedToMaterialID: pictureID
            ))
        }
        _ = try await store.upsertDeskMaterial(WorkMaterialDraft(
            id: pictureID,
            kind: .image,
            title: "screenshot.jpg",
            filename: "screenshot.jpg",
            mimeType: "image/jpeg",
            payload: Data("picture".utf8)
        ))
        let unrelated = try await store.upsertDeskMaterial(
            WorkMaterialDraft(kind: .note, title: "X", textContent: "X")
        )

        func makeBoard() -> WorkboardViewModel {
            let repository = WorkboardLiveRepository(
                store: store,
                captureInbox: WorkCaptureInbox(baseURL: inboxURL),
                openMaterial: { _ in }
            )
            return WorkboardViewModel(dependencies: repository.makeDependencies())
        }

        let viewModel = makeBoard()
        await viewModel.load()
        XCTAssertEqual(
            viewModel.desk?.materials.map(\.id), [higher, pictureID, unrelated.id],
            "the premise: B, then the pair at the picture's rank, then X"
        )
        XCTAssertEqual(viewModel.desk?.materials[1].companion?.id, lower)

        let moved = await viewModel.reorderMaterial(unrelated.id, toInsertionIndex: 0)
        XCTAssertTrue(moved, "an expanded request names every material and is accepted")

        let reloaded = makeBoard()
        await reloaded.load()
        XCTAssertEqual(reloaded.desk?.materials.map(\.id), [unrelated.id, higher, pictureID])
        XCTAssertEqual(
            reloaded.desk?.materials.last?.companion?.id, lower,
            "the screenshot kept the recording it had before an unrelated card moved"
        )
    }

    /// A refused drag restores the board it was planned on — pair intact. The
    /// rollback is what the person sees, so it must put the recording back
    /// inside its picture rather than leaving a half-applied arrangement.
    ///
    /// The corrective read is made to fail here, so only the rollback can
    /// restore the order.
    func testARefusedReorderRestoresTheFoldedBoardAndItsCompanion() async {
        let first = makeMaterial(name: "First", sequence: 0)
        let pair = makeFoldedPicture(name: "screenshot.jpg", recordingName: "Ship the review", sequence: 1)
        let board = WorkboardItemSnapshot(
            id: Constants.workboardDeskItemID,
            materials: [first, pair.card],
            revision: 4
        )
        let harness = DeskHarness(desk: board)
        let reorder = SnapshotGate()
        let viewModel = makeViewModel(harness: harness, reorder: reorder)
        await viewModel.load()

        let drag = Task { @MainActor in
            await viewModel.reorderMaterial(pair.card.id, toInsertionIndex: 0)
        }
        await fulfillment(of: [reorder.entered], timeout: 2)
        XCTAssertEqual(harness.reorderedIDs, [[pair.card.id, pair.recordingID, first.id]])
        harness.loadFails = true
        // The refusal the store actually makes: another device wrote the desk
        // while this drag was in flight.
        reorder.finish(.failure(WorkboardLiveRepositoryError.staleDraft))
        let moved = await drag.value

        XCTAssertFalse(moved)
        XCTAssertEqual(viewModel.desk?.materials.map(\.id), [first.id, pair.card.id])
        XCTAssertEqual(
            viewModel.desk?.materials.last?.companion?.id, pair.recordingID,
            "a refused drag leaves the pair folded"
        )
        XCTAssertEqual(viewModel.desk?.materials.map(\.sequence), [0, 1])
        XCTAssertEqual(viewModel.desk?.materials.last?.companion?.sequence, 2)
        XCTAssertNotNil(viewModel.notice)
        XCTAssertFalse(viewModel.isMutatingDesk)
    }

    /// A recording published before its picture holds the LOWER rank, and a
    /// card captured between the two sits in the gap — the shape the Mac lane
    /// leaves whenever a screenshot lands on a retry. A refused drag hands that
    /// board back with the ranks it was planned on: the rollback writes nothing
    /// to the store, so a board that reindexed itself would claim an
    /// arrangement no row on disk holds.
    ///
    /// Negative control: recomputing dense ranks from the displayed cards
    /// answers `[0, 1]` with the recording at 2, so both rank assertions fail.
    func testARefusedReorderRestoresTheSavedRanksRatherThanReindexingThem() async {
        let pair = makeFoldedPicture(
            name: "screenshot.jpg",
            recordingName: "Ship the review",
            sequence: 2,
            recordingSequence: 0
        )
        let between = makeMaterial(name: "Between", sequence: 1)
        let board = WorkboardItemSnapshot(
            id: Constants.workboardDeskItemID,
            materials: [between, pair.card],
            revision: 4
        )
        let harness = DeskHarness(desk: board)
        let reorder = SnapshotGate()
        let viewModel = makeViewModel(harness: harness, reorder: reorder)
        await viewModel.load()

        let drag = Task { @MainActor in
            await viewModel.reorderMaterial(pair.card.id, toInsertionIndex: 0)
        }
        await fulfillment(of: [reorder.entered], timeout: 2)
        XCTAssertEqual(harness.reorderedIDs, [[pair.card.id, pair.recordingID, between.id]])
        harness.loadFails = true
        reorder.finish(.failure(WorkboardLiveRepositoryError.staleDraft))
        let moved = await drag.value

        XCTAssertFalse(moved)
        XCTAssertEqual(viewModel.desk?.materials.map(\.id), [between.id, pair.card.id])
        XCTAssertEqual(
            viewModel.desk?.materials.map(\.sequence), [1, 2],
            "the cards carry the ranks the rows still hold, not fresh dense ones"
        )
        XCTAssertEqual(
            viewModel.desk?.materials.last?.companion?.sequence, 0,
            "the recording keeps the rank it was published with, ahead of its picture"
        )
        XCTAssertEqual(viewModel.desk?.materials.last?.companion?.id, pair.recordingID)
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

    /// A picture as the fold hands it to the board: the recording that named it
    /// drawn inside it, and that recording absent from the desk's own cards.
    ///
    /// `recordingSequence` defaults to the rank right after the picture's; pass
    /// it to model a recording that was published BEFORE its picture and so
    /// holds the lower rank.
    private func makeFoldedPicture(
        name: String,
        recordingName: String,
        sequence: Int,
        recordingSequence: Int? = nil
    ) -> (card: WorkboardMaterialSnapshot, recordingID: UUID) {
        let picture = WorkboardMaterialSnapshot(kind: .image, name: name, sequence: sequence)
        var recording = WorkboardMaterialSnapshot(
            kind: .audio,
            name: recordingName,
            sequence: recordingSequence ?? sequence + 1
        )
        recording.attachedToMaterialID = picture.id
        var parent = picture
        parent.companion = WorkboardCompanionSnapshot(recording)
        return (parent, recording.id)
    }
}
