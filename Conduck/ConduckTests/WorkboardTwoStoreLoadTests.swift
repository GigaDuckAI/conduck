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

    override func setUp() {
        super.setUp()
        storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("conduck-two-store-\(UUID().uuidString).sqlite")
    }

    override func tearDown() {
        for url in [storeURL, expectedBlobStoreURL].compactMap({ $0 }) {
            removeStoreFiles(at: url)
        }
        storeURL = nil
        super.tearDown()
    }

    // MARK: - 1. The mount

    func testTheTestSeamMountsCoreAndThePayloadStoreWithTheExpectedPairing() async throws {
        let store = ConversationStore(storeURL: storeURL)
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
        let store = ConversationStore(storeURL: storeURL)
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

        let first = ConversationStore(storeURL: storeURL)
        _ = try await first._writeMaterialAndBlobForTesting(
            materialID: materialID,
            title: "Survives a relaunch",
            payload: payload
        )
        try await first._unloadForTesting()

        let second = ConversationStore(storeURL: storeURL)
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

        let first = ConversationStore(storeURL: storeURL)
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

        let second = ConversationStore(storeURL: storeURL)
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
        let first = ConversationStore(storeURL: storeURL)
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

    // MARK: - 6. Memory at the ceiling

    func testACeilingSizedPayloadStaysBoundedInPeakMemory() async throws {
        // The ceiling is the largest single payload byte sync will ever hand
        // Core Data. External binary storage is supposed to keep that a
        // bounded cost — one copy in flight, not a pile of them — and the
        // failure this guards against is a build where assigning the attribute
        // buffers the payload several times over and the app is killed for
        // memory on a device it was fine on before.
        let ceiling = Int(Constants.workboardSyncCeilingBytes)
        let sampler = FootprintSampler()
        let baseline = sampler.start()

        let store = ConversationStore(storeURL: storeURL)
        let materialID = UUID()
        let stores = try await store._writeMaterialAndBlobForTesting(
            materialID: materialID,
            title: "At the ceiling",
            payload: Data(repeating: 0xC7, count: ceiling)
        )
        let peak = sampler.finish()

        XCTAssertEqual(stores.blobStoreURL?.lastPathComponent,
                       expectedBlobStoreURL.lastPathComponent)

        // Peak includes the test's OWN copy of the payload, so one whole
        // ceiling is already spent before Core Data sees a byte — measured
        // growth is 1.01× the ceiling, i.e. external storage adds a few hundred
        // KB and not a second copy. The bound is deliberately loose: it exists
        // to catch a build that buffers the payload several times over, not to
        // pin an allocator's exact behaviour.
        let growth = peak - baseline
        XCTAssertLessThan(
            growth, Int64(ceiling) * 3,
            "peak footprint grew \(growth) bytes for a \(ceiling)-byte payload"
        )

        // The bytes are on disk and readable, so the bound above was not bought
        // by writing nothing.
        let snapshot = try await store._materialAndBlobForTesting(
            materialID: materialID, includingPayload: false
        )
        XCTAssertEqual(snapshot.blobByteSize, Int64(ceiling))
        XCTAssertEqual(snapshot.blobRowCount, 1)
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

/// Peak `phys_footprint` over a window, sampled from a background thread.
///
/// `task_vm_info.ledger_phys_footprint_peak` is a PROCESS-lifetime high-water
/// mark: in a suite that already peaked higher it reports no growth at all and
/// a bound written against it passes vacuously. Polling the CURRENT footprint
/// measures the window's own peak instead, which is the number the assertion
/// is about.
private final class FootprintSampler: @unchecked Sendable {
    private let lock = NSLock()
    private var peak: Int64 = 0
    private var stopped = false

    /// Begin sampling; returns the baseline the peak should be compared to.
    @discardableResult
    func start() -> Int64 {
        let baseline = Self.currentFootprintBytes()
        lock.withLock { peak = baseline }
        Thread.detachNewThread { [self] in
            while true {
                let keepGoing = lock.withLock { () -> Bool in
                    guard !stopped else { return false }
                    peak = max(peak, Self.currentFootprintBytes())
                    return true
                }
                guard keepGoing else { return }
                Thread.sleep(forTimeInterval: 0.002)
            }
        }
        return baseline
    }

    func finish() -> Int64 {
        lock.withLock {
            stopped = true
            peak = max(peak, Self.currentFootprintBytes())
            return peak
        }
    }

    static func currentFootprintBytes() -> Int64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Int64(info.phys_footprint)
    }
}
