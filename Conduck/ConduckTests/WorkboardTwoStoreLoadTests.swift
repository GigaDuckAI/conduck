// SPDX-License-Identifier: Apache-2.0

// ConduckTests
// WorkboardTwoStoreLoadTests.swift
//
// The two-store topology `ConversationStore` mounts: the shipped
// `Conversations.sqlite` under the `Core` configuration, and a sibling payload
// store under `Blobs`. What is being pinned here is not that the load succeeds
// — a mis-pointed configuration succeeds too, silently, presenting an empty
// table while every payload row goes into the wrong file — but that the stores
// mount WHERE they were pointed, that one save routes each row to its own
// physical file with no explicit assignment, and that the three states the
// design has to survive do survive: close and reopen, a deleted payload store,
// and the Watch's shape, which mounts `Core` alone.
//
// The last case is the whole point of splitting the model. The wrist compiles
// the same store, has no `WorkAssetVault` and no eviction path, so bytes it
// cannot use must never arrive — the store it never mounts is how.

import XCTest
import CoreData
@testable import Conduck

final class WorkboardTwoStoreLoadTests: XCTestCase {
    private var storeURL: URL!

    /// Every store here mints a vault directory of its own that nothing else
    /// removes; the fixture empties them when the class is done.
    private let isolated = IsolatedWorkStores()

    override func setUp() {
        super.setUp()
        storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("conduck-two-store-\(UUID().uuidString).sqlite")
    }

    override func tearDown() async throws {
        await isolated.cleanUp()
        for url in [storeURL, expectedBlobStoreURL].compactMap({ $0 }) {
            removeStoreFiles(at: url)
        }
        storeURL = nil
        try await super.tearDown()
    }

    // MARK: - 1. The mount

    func testTheTestSeamMountsCoreAndThePayloadStoreWithTheExpectedPairing() async throws {
        let store = isolated.make(storeURL: storeURL)
        let mounted = try await store._mountedStoresForTesting()

        XCTAssertEqual(mounted.count, 2,
                       "a mis-pointed configuration mounts silently; count the stores")
        let pairing = Dictionary(
            uniqueKeysWithValues: mounted.map { ($0.configuration, $0.url?.lastPathComponent) }
        )
        XCTAssertEqual(pairing["Core"], storeURL.lastPathComponent,
                       "Core must keep the file it was handed; a new URL strands every row")
        XCTAssertEqual(pairing["Blobs"], expectedBlobStoreURL.lastPathComponent,
                       "payload bytes belong in their own file, beside the Core store")
    }

    func testAMisPointedConfigurationCouldNotHaveMountedUnnoticed() async throws {
        // The load assertion's own reason, stated as a test: opening the Core
        // file under the `Blobs` configuration does NOT error. Core Data
        // validates only the entities the named configuration lists, so this
        // succeeds and presents an empty payload table — which is exactly why
        // `performLoad` compares the mount against the descriptions instead of
        // trusting a nil error.
        let container = NSPersistentContainer(name: "Conversations")
        let misPointed = NSPersistentStoreDescription(url: storeURL)
        misPointed.configuration = "Blobs"
        container.persistentStoreDescriptions = [misPointed]

        let loaded = expectation(description: "store loaded")
        var loadError: Error?
        container.loadPersistentStores { _, error in
            loadError = error
            loaded.fulfill()
        }
        await fulfillment(of: [loaded], timeout: 30)
        XCTAssertNil(loadError, "Core Data does not object; only the topology check can")

        let store = try XCTUnwrap(container.persistentStoreCoordinator.persistentStores.first)
        XCTAssertEqual(store.configurationName, "Blobs")
        XCTAssertEqual(store.url?.lastPathComponent, storeURL.lastPathComponent)
        for store in container.persistentStoreCoordinator.persistentStores {
            try container.persistentStoreCoordinator.remove(store)
        }
    }

    // MARK: - 2. Routing

    func testAMaterialAndItsBlobCommitInOneSaveIntoDifferentPhysicalStores() async throws {
        let store = isolated.make(storeURL: storeURL)
        let materialID = UUID()

        // The seam performs ONE `context.save()` and no `context.assign(_:to:)`
        // — the return value is where each row physically landed.
        let stores = try await store._writeMaterialAndBlobForTesting(
            materialID: materialID,
            title: "Routed by configuration",
            payload: Data(repeating: 0x5A, count: 512 * 1024)
        )

        XCTAssertEqual(stores.materialStoreURL?.lastPathComponent, storeURL.lastPathComponent,
                       "the material row stays in the shipped conversations file")
        XCTAssertEqual(stores.blobStoreURL?.lastPathComponent,
                       expectedBlobStoreURL.lastPathComponent,
                       "the payload row belongs to the store the Watch never mounts")
        XCTAssertNotEqual(stores.materialStoreURL, stores.blobStoreURL)
    }

    // MARK: - 3. Close and reopen

    func testBothStoresSurviveCloseAndReopen() async throws {
        let materialID = UUID()
        let payload = Data((0..<(256 * 1024)).map { UInt8($0 % 251) })

        let first = isolated.make(storeURL: storeURL)
        _ = try await first._writeMaterialAndBlobForTesting(
            materialID: materialID,
            title: "Survives a relaunch",
            payload: payload
        )
        try await first._unloadForTesting()

        let second = isolated.make(storeURL: storeURL)
        let remounted = try await second._mountedStoresForTesting()
        XCTAssertEqual(remounted.count, 2)
        let snapshot = try await second._materialAndBlobForTesting(materialID: materialID)
        XCTAssertEqual(snapshot.materialTitle, "Survives a relaunch")
        XCTAssertEqual(snapshot.materialStorageMode, "syncedPayload")
        XCTAssertEqual(snapshot.blobRowCount, 1)
        XCTAssertEqual(snapshot.blobByteSize, Int64(payload.count))
        XCTAssertEqual(snapshot.blobPayload, payload,
                       "an external payload must come back whole, not truncated")
    }

    // MARK: - 4. Losing the payload store

    func testDeletingThePayloadStoreLeavesCoreIntactAndRecreatesBlobsEmpty() async throws {
        let materialID = UUID()

        let first = isolated.make(storeURL: storeURL)
        _ = try await first._writeMaterialAndBlobForTesting(
            materialID: materialID,
            title: "Metadata outlives its bytes",
            payload: Data(repeating: 0x11, count: 300 * 1024)
        )
        let mounted = try await first._mountedStoresForTesting()
        let blobStoreURL = try XCTUnwrap(
            mounted.first(where: { $0.configuration == "Blobs" })?.url
        )
        try await first._unloadForTesting()

        // The partial-loss drill: the payload sqlite and its external-data
        // directory are gone; the conversations file is not.
        removeStoreFiles(at: blobStoreURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: blobStoreURL.path))

        let second = isolated.make(storeURL: storeURL)
        let remounted = try await second._mountedStoresForTesting()
        XCTAssertEqual(remounted.count, 2,
                       "a missing payload store is recreated, not fatal")
        let snapshot = try await second._materialAndBlobForTesting(materialID: materialID)
        XCTAssertEqual(snapshot.materialTitle, "Metadata outlives its bytes",
                       "Core rows are untouched by the loss")
        XCTAssertEqual(snapshot.materialStorageMode, "syncedPayload",
                       "the row keeps claiming synced bytes; availability, not the store, resolves that")
        XCTAssertEqual(snapshot.blobRowCount, 0, "the payload store comes back empty")
    }

    // MARK: - 5. The Watch shape

    func testTheWatchShapeOpensTheSameCoreFileCleanlyWithNoPayloadStore() async throws {
        let materialID = UUID()
        let first = isolated.make(storeURL: storeURL)
        _ = try await first._writeMaterialAndBlobForTesting(
            materialID: materialID,
            title: "Readable on the wrist",
            payload: Data(repeating: 0x2C, count: 128 * 1024)
        )
        try await first._unloadForTesting()

        // What watchOS compiles: the Core description alone. Same file, same
        // current model, no payload store — the omission IS the exclusion.
        let container = NSPersistentContainer(name: "Conversations")
        let core = NSPersistentStoreDescription(url: storeURL)
        core.configuration = "Core"
        container.persistentStoreDescriptions = [core]
        let loaded = expectation(description: "core store loaded")
        var loadError: Error?
        container.loadPersistentStores { _, error in
            loadError = error
            loaded.fulfill()
        }
        await fulfillment(of: [loaded], timeout: 30)
        XCTAssertNil(loadError)

        let coordinator = container.persistentStoreCoordinator
        XCTAssertEqual(coordinator.persistentStores.count, 1)
        XCTAssertEqual(coordinator.persistentStores.first?.configurationName, "Core")

        let context = container.newBackgroundContext()
        try await context.perform {
            let request = NSFetchRequest<NSManagedObject>(entityName: "WorkMaterial")
            request.predicate = NSPredicate(format: "id == %@", materialID as CVarArg)
            let material = try XCTUnwrap(context.fetch(request).first)
            XCTAssertEqual(material.value(forKey: "title") as? String, "Readable on the wrist",
                           "the wrist reads every material the desk holds")
            XCTAssertEqual(
                try context.count(for: NSFetchRequest(entityName: "WorkMaterialBlob")), 0,
                "no payload store is mounted, so no payload row is reachable"
            )
        }
        for store in coordinator.persistentStores {
            try coordinator.remove(store)
        }
    }

    // MARK: - 6. A payload at the ceiling

    /// The largest single payload byte sync will ever hand Core Data goes
    /// through the external-storage attribute whole, and comes back whole.
    ///
    /// WHAT THIS DELIBERATELY DOES NOT CLAIM. The property one would rather pin
    /// here is the PEAK memory the write costs — a build that buffers the
    /// payload several times over is killed on a device it was fine on before.
    /// That is not measurable from inside this process: the write's transient
    /// allocations can be made and released between any two samples of
    /// `phys_footprint`, and unrelated allocations in the same window inflate
    /// whatever a sampler does catch, so a bound written against it passes or
    /// fails for reasons that have nothing to do with the subject. Measuring it
    /// honestly needs a high-water mark from a dedicated helper process or an
    /// allocator instrument, and this bundle has neither. An assertion that can
    /// pass while the defect is present is worse than no assertion: it reads as
    /// coverage. So the peak is UNCOVERED and recorded as such, and what is left
    /// here is the part that is true — the ceiling-sized payload is durable and
    /// reads back byte for byte.
    func testACeilingSizedPayloadIsWrittenWholeAndReadBackWhole() async throws {
        let ceiling = Int(Constants.workboardSyncCeilingBytes)
        let store = isolated.make(storeURL: storeURL)
        let materialID = UUID()
        let payload = Data(repeating: 0xC7, count: ceiling)
        let stores = try await store._writeMaterialAndBlobForTesting(
            materialID: materialID,
            title: "At the ceiling",
            payload: payload
        )

        XCTAssertEqual(stores.blobStoreURL?.lastPathComponent,
                       expectedBlobStoreURL.lastPathComponent,
                       "a ceiling-sized payload belongs in the store the Watch never mounts")

        let snapshot = try await store._materialAndBlobForTesting(
            materialID: materialID, includingPayload: true
        )
        XCTAssertEqual(snapshot.blobRowCount, 1)
        XCTAssertEqual(snapshot.blobByteSize, Int64(ceiling))
        XCTAssertEqual(snapshot.blobPayload?.count, ceiling,
                       "external storage must return the payload whole, not truncated")
        XCTAssertEqual(snapshot.blobPayload, payload)
    }

    // MARK: - Helpers

    /// The payload store `ConversationStore` derives for a non-App-Group store:
    /// the Core file's own name with `-Blobs` appended, beside it.
    private var expectedBlobStoreURL: URL {
        storeURL
            .deletingLastPathComponent()
            .appendingPathComponent("\(storeURL.deletingPathExtension().lastPathComponent)-Blobs")
            .appendingPathExtension("sqlite")
    }

    /// External binary payloads live in a `_SUPPORT` directory beside each
    /// store, so a per-store cleanup has to take four paths, not one.
    private func removeStoreFiles(at url: URL) {
        let fileManager = FileManager.default
        let stem = url.deletingPathExtension()
        try? fileManager.removeItem(at: url)
        try? fileManager.removeItem(at: stem.appendingPathExtension("sqlite-wal"))
        try? fileManager.removeItem(at: stem.appendingPathExtension("sqlite-shm"))
        try? fileManager.removeItem(
            at: url.deletingLastPathComponent()
                .appendingPathComponent(".\(stem.lastPathComponent)_SUPPORT")
        )
    }
}
