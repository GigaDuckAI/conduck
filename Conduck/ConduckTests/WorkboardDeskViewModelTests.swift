// SPDX-License-Identifier: Apache-2.0

// ConduckTests
// WorkboardDeskViewModelTests.swift
//
// Work is ONE desk, and these tests drive the real chain that makes that true:
// the view model, the live adapter and the private store. They hold what a
// person would notice if it broke — a board written by an older build showing
// up beside the desk, a first capture minting a second board, a capture landing
// on a card list nobody can see, or half the desk missing because CloudKit
// imported it as two physical rows.

import CoreData
import XCTest
@testable import Conduck

@MainActor
final class WorkboardDeskViewModelTests: XCTestCase {
    private var seededStoreURL: URL?

    override func tearDown() {
        if let seededStoreURL { removeStoreFiles(at: seededStoreURL) }
        seededStoreURL = nil
        super.tearDown()
    }

    // MARK: - Only the desk is loaded

    func testOnlyTheDeskIsLoadedWhenALegacyProjectRowStillExists() async throws {
        let store = ConversationStore(inMemory: true)
        let legacy = try await store.createWorkItem(
            WorkItemDraft(content: WorkItemContent(
                title: "A project from a build that had projects",
                objective: "Choose a courier"
            ))
        )
        _ = try await store.addWorkMaterial(
            WorkMaterialDraft(kind: .note, title: "Old note", textContent: "Old note"),
            to: legacy.id
        )
        let viewModel = makeViewModel(store: store)

        await viewModel.load()

        XCTAssertNil(viewModel.desk, "the desk row does not exist yet, and a project is not one")
        XCTAssertNil(viewModel.item(withID: legacy.id), "a project id resolves to no board")

        let added = await viewModel.addWorkspaceThought(
            "A thought that belongs on the desk",
            to: Constants.workboardDeskItemID
        )

        XCTAssertTrue(added)
        XCTAssertEqual(viewModel.desk?.id, Constants.workboardDeskItemID)
        XCTAssertNil(viewModel.item(withID: legacy.id))
        // Invisible, never deleted: the project row and its card stay exactly
        // as they were, so a build that brings projects back finds them whole.
        let preservedValue = try await store.fetchWorkItem(id: legacy.id)
        let preserved = try XCTUnwrap(preservedValue)
        XCTAssertEqual(preserved.content.title, "A project from a build that had projects")
        XCTAssertEqual(preserved.materials.map(\.title), ["Old note"])
    }

    // MARK: - Lazy creation

    func testFirstCaptureCreatesTheDeskLazilyAtTheFixedIdentity() async throws {
        let store = ConversationStore(inMemory: true)
        let viewModel = makeViewModel(store: store)

        await viewModel.load()
        XCTAssertNil(viewModel.desk)
        let beforeCapture = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        XCTAssertNil(beforeCapture, "an untouched desk owns no row")

        let added = await viewModel.addWorkspaceThought(
            "First thought",
            to: Constants.workboardDeskItemID
        )

        XCTAssertTrue(added)
        let desk = try XCTUnwrap(viewModel.desk)
        XCTAssertEqual(desk.id, Constants.workboardDeskItemID)
        XCTAssertEqual(desk.materials.map(\.name), ["First thought"])
        XCTAssertEqual(desk.title, "", "the desk carries no brief for anything to display")
        XCTAssertEqual(desk.objective, "")
        let storedValue = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        let stored = try XCTUnwrap(storedValue)
        XCTAssertEqual(stored.materials.map(\.textContent), ["First thought"])
        let everyBoard = try await store.fetchWorkItems()
        XCTAssertEqual(
            everyBoard.map(\.id),
            [Constants.workboardDeskItemID],
            "a capture creates the desk and nothing else"
        )
    }

    func testASecondCaptureAppendsToTheSameDeskInsteadOfMintingAnother() async throws {
        let store = ConversationStore(inMemory: true)
        let viewModel = makeViewModel(store: store)
        await viewModel.load()

        let addedFirst = await viewModel.addWorkspaceThought(
            "First thought",
            to: Constants.workboardDeskItemID
        )
        XCTAssertTrue(addedFirst)
        let firstRevision = try XCTUnwrap(viewModel.desk?.revision)
        let addedSecond = await viewModel.addWorkspaceThought(
            "Second thought",
            to: Constants.workboardDeskItemID
        )
        XCTAssertTrue(addedSecond)

        let desk = try XCTUnwrap(viewModel.desk)
        XCTAssertEqual(desk.id, Constants.workboardDeskItemID)
        XCTAssertEqual(desk.materials.map(\.name), ["First thought", "Second thought"])
        XCTAssertEqual(desk.materials.map(\.sequence), [0, 1], "the store ranks the append")
        XCTAssertNotEqual(
            desk.revision,
            firstRevision,
            "collecting a card is a change to the desk"
        )
        let everyBoard = try await store.fetchWorkItems()
        XCTAssertEqual(everyBoard.count, 1, "the second capture minted no second board")
        XCTAssertEqual(everyBoard.first?.materials.count, 2)
    }

    func testRemovingTheLastCardLeavesTheDeskStandingAndReadyForTheNextCapture() async throws {
        let store = ConversationStore(inMemory: true)
        let viewModel = makeViewModel(store: store)
        await viewModel.load()
        let added = await viewModel.addWorkspaceThought(
            "Only thought",
            to: Constants.workboardDeskItemID
        )
        XCTAssertTrue(added)
        let materialID = try XCTUnwrap(viewModel.desk?.materials.first?.id)

        let removed = await viewModel.removeMaterialFromBoard(
            materialID,
            in: Constants.workboardDeskItemID
        )

        XCTAssertTrue(removed)
        XCTAssertEqual(viewModel.desk?.materials.count, 0)
        XCTAssertTrue(
            viewModel.desk?.materials.isEmpty == true,
            "an empty desk is the capture canvas, not a board with nothing on it"
        )
        let stored = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        XCTAssertNotNil(stored, "the desk row survives its last card")

        let addedAgain = await viewModel.addWorkspaceThought(
            "A later thought",
            to: Constants.workboardDeskItemID
        )
        XCTAssertTrue(addedAgain)
        XCTAssertEqual(viewModel.desk?.materials.map(\.name), ["A later thought"])
        let boardsAfterReuse = try await store.fetchWorkItems()
        XCTAssertEqual(boardsAfterReuse.count, 1)
    }

    // MARK: - Duplicate desk rows

    /// CloudKit cannot enforce a Core Data uniqueness constraint, so two
    /// devices capturing offline can each import a physical desk row under the
    /// one desk id. Neither row may be deleted — that would export the deletion
    /// of a valid record — so the board has to read as their union.
    func testTheBoardUnionsMaterialsFromEveryDuplicateDeskRow() async throws {
        let storeURL = try seedStoreWithTwoPhysicalDeskRows()
        let store = ConversationStore(storeURL: storeURL)
        let viewModel = makeViewModel(store: store)

        await viewModel.load()

        let desk = try XCTUnwrap(viewModel.desk)
        XCTAssertEqual(desk.id, Constants.workboardDeskItemID)
        XCTAssertEqual(
            desk.id,
            Constants.workboardDeskItemID,
            "duplicate physical rows project as one logical desk"
        )
        XCTAssertEqual(
            desk.materials.map(\.name).sorted(),
            ["Captured on A", "Captured on B"],
            "a card is never hidden by the row that imported it"
        )

        // A capture on top of the merge stays one desk and keeps both cards.
        let addedAfterMerge = await viewModel.addWorkspaceThought(
            "Captured after the merge",
            to: Constants.workboardDeskItemID
        )
        XCTAssertTrue(addedAfterMerge)
        XCTAssertEqual(
            viewModel.desk?.materials.map(\.name).sorted(),
            ["Captured after the merge", "Captured on A", "Captured on B"]
        )
        XCTAssertEqual(viewModel.desk?.id, Constants.workboardDeskItemID)
    }

    // MARK: - Helpers

    private func makeViewModel(store: ConversationStore) -> WorkboardViewModel {
        let repository = WorkboardLiveRepository(
            store: store,
            captureInbox: WorkCaptureInbox(baseURL: temporaryDirectory()),
            openConversation: { _ in },
            openMaterial: { _ in },
            openGatewaySettings: {}
        )
        return WorkboardViewModel(dependencies: repository.makeDependencies())
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "workboard-desk-tests-\(UUID().uuidString)",
            isDirectory: true
        )
    }

    /// Writes the state CloudKit can produce but no API on this device can:
    /// two WorkItem rows carrying the same desk id, each owning one card.
    private func seedStoreWithTwoPhysicalDeskRows() throws -> URL {
        let root = temporaryDirectory()
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        let storeURL = root.appendingPathComponent("Conversations.sqlite")
        seededStoreURL = storeURL

        let bundles = [Bundle.main, Bundle(for: Self.self)]
        let model = try XCTUnwrap(
            bundles.lazy.compactMap { bundle -> NSManagedObjectModel? in
                guard let momd = bundle.url(forResource: "Conversations", withExtension: "momd")
                else { return nil }
                return NSManagedObjectModel(contentsOf: momd)
            }.first,
            "the compiled Conversations model must be reachable from the test bundle"
        )
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
        _ = try coordinator.addPersistentStore(
            type: .sqlite,
            configuration: nil,
            at: storeURL,
            options: [
                NSMigratePersistentStoresAutomaticallyOption: true,
                NSInferMappingModelAutomaticallyOption: true,
            ]
        )
        let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        context.persistentStoreCoordinator = coordinator
        try context.performAndWait {
            for (index, name) in ["Captured on A", "Captured on B"].enumerated() {
                let stamp = Date(timeIntervalSince1970: 1_700_000_000 + Double(index))
                let item = NSEntityDescription.insertNewObject(
                    forEntityName: "WorkItem",
                    into: context
                )
                item.setValue(Constants.workboardDeskItemID, forKey: "id")
                item.setValue(stamp, forKey: "createdAt")
                item.setValue(stamp, forKey: "updatedAt")

                let material = NSEntityDescription.insertNewObject(
                    forEntityName: "WorkMaterial",
                    into: context
                )
                material.setValue(UUID(), forKey: "id")
                material.setValue(Constants.workboardDeskItemID, forKey: "workItemID")
                material.setValue(WorkMaterialKind.note.rawValue, forKey: "kind")
                material.setValue(name, forKey: "title")
                material.setValue(name, forKey: "textContent")
                material.setValue(NSNumber(value: 0), forKey: "sequence")
                material.setValue(stamp, forKey: "createdAt")
                material.setValue(stamp, forKey: "updatedAt")
            }
            try context.save()
        }
        for store in coordinator.persistentStores {
            try coordinator.remove(store)
        }
        return storeURL
    }

    /// A store is four paths — the file, its two journals and the `_SUPPORT`
    /// directory external binaries live in — and every one of them is inside
    /// this test's own directory, so the directory is what goes.
    private func removeStoreFiles(at url: URL) {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }
}
