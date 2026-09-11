// SPDX-License-Identifier: Apache-2.0

// ConduckTests
// WorkCaptureDrainerTakeoverTests.swift
//
// One capture, two drainers, two stores, one App Group directory — the shape
// the app and the headless intent process present to each other.
//
// A capture's material ids are deterministic, so a stale drainer and the
// successor that takes its claim publish the SAME material id. The stale
// publication saves its payload first and its card second; in between, the
// payload is complete on disk and belongs to nobody. A successor that ran
// through that window would find the payload already there, adopt it without
// writing one of its own, prove the card durable, and delete the queue's only
// remaining copy of the shared file — and the predecessor could still take
// those bytes back afterwards, leaving a card waiting for iCloud with nothing
// to wait for.
//
// `WorkMaterialPublicationLock` is what closes the window, and the only
// observable difference it makes is WHEN the successor's publication runs. So
// the predecessor is parked inside the lock at exactly that point and the
// successor is asked to drain the same capture there. Two `ConversationStore`
// instances over one sqlite file contend on the lock exactly as two processes
// do, because `flock(2)` is scoped to the open file description rather than to
// the process.

import XCTest
import CoreData
@testable import Conduck

final class WorkCaptureDrainerTakeoverTests: XCTestCase {
    private var root: URL!
    private var storeURL: URL!

    /// Both stores mount real sqlite files — an in-memory store has no lock at
    /// all, because no second process can open one — and each mints a vault
    /// directory of its own. The fixture empties them when the class is done.
    private let isolated = IsolatedWorkStores()

    /// The drains a case has in flight. Teardown cancels and AWAITS them before
    /// the vaults and sqlite files go: an assertion that ends a case early
    /// leaves a drain parked inside a store, and removing its files underneath
    /// it is a race, not a cleanup.
    private var drains: [Task<WorkCaptureDrainer.Report, Error>] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "conduck-work-drainer-takeover-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("conduck-work-takeover-\(UUID().uuidString).sqlite")
    }

    override func tearDown() async throws {
        for drain in drains {
            drain.cancel()
            _ = await drain.result
        }
        drains.removeAll()
        await isolated.cleanUp()
        if let root { try? FileManager.default.removeItem(at: root) }
        if let storeURL {
            removeStoreFiles(at: storeURL)
            removeStoreFiles(at: blobStoreURL)
            try? FileManager.default.removeItem(at: publicationLockDirectory)
        }
        root = nil
        storeURL = nil
        try await super.tearDown()
    }

    // MARK: - The successor may not acknowledge bytes its predecessor still owns

    /// The whole race, staged: the stale publication holds its material's lock
    /// with the payload already durable and no card naming it, and the
    /// successor drains the same capture in that window. What is asserted is
    /// that the successor cannot get past its own publication — so it never
    /// reaches its durability barrier, never acknowledges, and the queue keeps
    /// the only copy of the shared file — and that once the predecessor's bytes
    /// are taken back, the card the successor finally acknowledges is one whose
    /// payload it wrote itself.
    func testASuccessorNeverAcknowledgesBytesItsPredecessorCanStillTakeBack() async throws {
        let payload = Data("the bytes two processes both believe they published".utf8)
        let entryID = UUID()
        let envelope = WorkCaptureEnvelope(
            note: "A capture two processes both hold",
            source: .shareExtension,
            entries: [
                .init(
                    id: entryID,
                    kind: .file,
                    sequence: 0,
                    relativePath: "payload-000.bin",
                    displayName: "contract.bin",
                    mimeType: "application/octet-stream",
                    byteCount: Int64(payload.count)
                )
            ]
        )
        try publish(envelope, payloads: ["payload-000.bin": payload])

        // Mounted one at a time so the two instances never race the creation of
        // the file they share; from here on they are two independent openers of
        // one store, which is the topology under test.
        let staleStore = isolated.make(storeURL: storeURL)
        try await staleStore.ensureLoaded()
        let successorStore = isolated.make(storeURL: storeURL)
        try await successorStore.ensureLoaded()

        let staleInbox = WorkCaptureInbox(baseURL: root)
        let successorInbox = WorkCaptureInbox(baseURL: root)
        // The default 60-second heartbeat never fires inside a test, so the
        // stale drainer is a process that has not yet noticed anything: it is
        // parked in its publication when its claim is taken from it.
        let staleDrainer = WorkCaptureDrainer(
            inbox: staleInbox,
            store: staleStore,
            sourceDevice: "stale-process"
        )
        let successorDrainer = WorkCaptureDrainer(
            inbox: successorInbox,
            store: successorStore,
            sourceDevice: "successor-process"
        )

        let gate = PublicationGate()
        await staleStore._setWorkMaterialPublicationLockHoldForTesting { id in
            guard id == entryID else { return }
            await gate.hold(deadline: 30)
        }

        let staleDrain = Task { try await staleDrainer.drainAvailableCaptures() }
        drains.append(staleDrain)
        await gate.waitUntilHeld()

        // The window the defect needs: the payload is complete and durable, and
        // no card names it yet.
        // Asked UNPAIRED — with no pairing supplied, any complete row answers —
        // because the point is exactly that no card names these bytes yet.
        let completeness = try await staleStore.workMaterialBlobCompleteness(
            materialIDs: [entryID],
            pairedWith: [:]
        )
        XCTAssertEqual(
            completeness[entryID]?.byteSize, Int64(payload.count),
            "the predecessor's payload is on disk for a successor to find"
        )
        let deskBeforeTheTakeover = try await successorStore.fetchWorkItem(
            id: Constants.workboardDeskItemID
        )
        XCTAssertFalse(
            (deskBeforeTheTakeover?.materials ?? []).contains { $0.id == entryID },
            "and no card names it — the bytes belong to nobody"
        )
        let originalClaim = try XCTUnwrap(try claimedDirectories().first).lastPathComponent

        // The claim ages out and the successor takes it, exactly as
        // reconciliation in another process would.
        let judgedAt = Date().addingTimeInterval(WorkCaptureInbox.staleClaimHorizon + 5)
        let reconciled = await successorInbox.reconcile(now: judgedAt)
        XCTAssertEqual(reconciled.releasedClaimCount, 1,
                       "a claim nobody renewed is fair game at the horizon")

        let successorFinished = CompletionFlag()
        let successor = Task { () -> WorkCaptureDrainer.Report in
            let report = try await successorDrainer.drainAvailableCaptures()
            await successorFinished.record()
            return report
        }
        drains.append(successor)
        try await waitUntil("the successor never claimed the requeued capture") {
            try self.claimedDirectories().contains {
                $0.lastPathComponent != originalClaim
            }
        }

        // With the predecessor still holding the lock the successor cannot
        // publish, so it cannot reach its barrier and cannot acknowledge. The
        // queue therefore still holds the only copy of the shared file.
        let successorClaim = try XCTUnwrap(
            try claimedDirectories().first { $0.lastPathComponent != originalClaim }
        )
        let queuedPayload = successorClaim.appendingPathComponent(
            "payload-000.bin",
            isDirectory: false
        )
        let observationDeadline = Date().addingTimeInterval(0.4)
        while Date() < observationDeadline {
            let finished = await successorFinished.didFinish
            XCTAssertFalse(
                finished,
                "no publication of this material may complete while its lock is held"
            )
            XCTAssertEqual(
                try Data(contentsOf: queuedPayload), payload,
                "the queue keeps the only copy until the desk provably holds one"
            )
            try await Task.sleep(for: .milliseconds(20))
        }

        // The predecessor takes its bytes back — the rollback the adjudication
        // describes, staged against the payload store the two instances share.
        let removedRows = try await deletePayloadRowsFromAnotherOpener(materialID: entryID)
        XCTAssertEqual(removedRows, 1, "the bytes a successor could have adopted are gone")

        await gate.release()
        switch await staleDrain.result {
        case .success:
            XCTFail("A drain whose claim was taken over must not report an import")
        case .failure(let error):
            // Either barrier refuses it: the card it wrote has no payload left,
            // or the successor repaired one first and the acknowledgement is
            // refused by the lease it no longer holds. Both end the same way —
            // this drainer consumes nothing.
            XCTAssertTrue(
                error is WorkboardStoreError || error is WorkCaptureInbox.InboxError,
                "got \(error)"
            )
        }

        let report = try await successor.value
        XCTAssertEqual(report.importedCaptureCount + report.replayedCaptureCount, 1)

        // The card the successor acknowledged holds bytes it wrote itself.
        let recovered = try await successorStore.loadWorkMaterialPayload(id: entryID)
        XCTAssertEqual(recovered, payload,
                       "the desk holds the shared file, not a card waiting for bytes nobody has")
        let desk = try await unwrapDesk(successorStore)
        XCTAssertEqual(Set(desk.materials.map(\.id)), [envelope.id, entryID])
        let card = try XCTUnwrap(desk.materials.first { $0.id == entryID })
        XCTAssertTrue(card.hasPayload)

        // And the queue was consumed exactly once, by the drainer that held it.
        XCTAssertTrue(try claimedDirectories().isEmpty)
        let pending = try await successorInbox.pendingCount()
        XCTAssertEqual(pending, 0)
    }

    // MARK: - Helpers

    private func unwrapDesk(_ store: ConversationStore) async throws -> WorkItemRecord {
        let deskValue = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        return try XCTUnwrap(deskValue, "every capture resolves the one desk")
    }

    private func claimedDirectories() throws -> [URL] {
        let processing = root.appendingPathComponent("processing", isDirectory: true)
        guard FileManager.default.fileExists(atPath: processing.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(
            at: processing,
            includingPropertiesForKeys: nil
        )
    }

    /// Poll for a condition another task produces. Polling is what makes the
    /// OUTCOME deterministic rather than the timing: the assertion is that the
    /// other task gets there at all, and the bound only decides how long a build
    /// that never does takes to say so.
    private func waitUntil(
        _ failureMessage: String,
        timeout: TimeInterval = 10,
        _ condition: () throws -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if try condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail(failureMessage)
    }

    private func publish(
        _ envelope: WorkCaptureEnvelope,
        payloads: [String: Data] = [:]
    ) throws {
        let directory = root.appendingPathComponent(envelope.id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        for (relativePath, bytes) in payloads {
            try bytes.write(
                to: directory.appendingPathComponent(relativePath, isDirectory: false),
                options: .atomic
            )
        }
        try envelope.encoded().write(
            to: directory.appendingPathComponent("manifest.json"),
            options: .atomic
        )
    }

    /// The payload store beside the Core file, and the lock directory beside
    /// both. Derived the same way `ConversationStore` derives them, because a
    /// test that opens the shared file has to name it exactly.
    private var blobStoreURL: URL {
        storeURL
            .deletingLastPathComponent()
            .appendingPathComponent("\(storeURL.deletingPathExtension().lastPathComponent)-Blobs")
            .appendingPathExtension("sqlite")
    }

    private var publicationLockDirectory: URL {
        storeURL
            .deletingLastPathComponent()
            .appendingPathComponent(
                "\(storeURL.deletingPathExtension().lastPathComponent)-Locks",
                isDirectory: true
            )
    }

    /// Delete every payload row for one material through a THIRD opener of the
    /// shared payload store — which is what a rollback running in another
    /// process does to bytes this process is looking at.
    ///
    /// Staged directly rather than forced through the predecessor's own
    /// rollback: on the synced lane that rollback is reachable only from a
    /// failure inside the store's write transaction, and the store's deletion
    /// seams answer for in-memory stores alone, while this case needs the real
    /// sqlite the two instances share.
    private func deletePayloadRowsFromAnotherOpener(materialID: UUID) async throws -> Int {
        let container = NSPersistentContainer(name: "Conversations")
        let blobs = NSPersistentStoreDescription(url: blobStoreURL)
        blobs.configuration = "Blobs"
        blobs.shouldAddStoreAsynchronously = false
        // History tracking is not optional here: a store previously opened WITH
        // it and reopened without is forced read-only, and a silently read-only
        // opener could not take anything back.
        blobs.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
        blobs.setOption(
            true as NSNumber,
            forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey
        )
        container.persistentStoreDescriptions = [blobs]
        var loadFailure: Error?
        container.loadPersistentStores { _, error in loadFailure = error }
        if let loadFailure { throw loadFailure }

        let context = container.newBackgroundContext()
        return try await context.perform { [context] () -> Int in
            let request = NSFetchRequest<NSManagedObject>(entityName: "WorkMaterialBlob")
            request.predicate = NSPredicate(format: "materialID == %@", materialID as CVarArg)
            let rows = try context.fetch(request)
            for row in rows { context.delete(row) }
            try context.save()
            return rows.count
        }
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

/// Parks one publication inside the cross-process lock it holds. The wait ends
/// on cancellation as well as on `release()`, because a drain abandoned by an
/// assertion further down must not leave the suite waiting on a lock nobody
/// will free; the deadline keeps a build that never releases failing an
/// assertion instead of hanging.
private actor PublicationGate {
    private var isHeld = false
    private var isReleased = false

    func hold(deadline: TimeInterval = 5) async {
        isHeld = true
        let expiry = Date().addingTimeInterval(deadline)
        while !isReleased {
            if Task.isCancelled { return }
            if Date() >= expiry { return }
            try? await Task.sleep(for: .milliseconds(2))
        }
    }

    func waitUntilHeld() async {
        while !isHeld {
            try? await Task.sleep(for: .milliseconds(2))
        }
    }

    func release() {
        isReleased = true
    }
}

/// Whether a drain has returned. A task that is merely slow and one that has
/// finished are the same thing to an observer holding its handle, so the drain
/// records its own completion.
private actor CompletionFlag {
    private(set) var didFinish = false

    func record() {
        didFinish = true
    }
}
