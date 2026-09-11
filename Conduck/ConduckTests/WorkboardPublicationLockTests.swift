// SPDX-License-Identifier: Apache-2.0

// ConduckTests
// WorkboardPublicationLockTests.swift
//
// The cross-process half of "one publication of a material's payload at a
// time". `ConversationStore`'s claim sets are in-memory, so they say nothing
// about the app and the headless intent process, which share one App Group
// sqlite and mint the same deterministic capture ids. Everything here is about
// what `WorkMaterialPublicationLock` adds on top of them.
//
// Two `ConversationStore` instances over ONE store file stand in for the two
// processes. That is a faithful stand-in and not a convenience: `flock` is
// scoped to the open file description rather than to the process, so two
// descriptors inside one process contend exactly as two processes do — which is
// also why the production lock cannot be replaced by a process-wide table.
//
// The defect being held shut, in order: a drainer whose lease is taken while its
// upsert is already running saves a blob, a successor using the same
// deterministic id adopts that complete blob without writing one, the successor
// passes its own durability barrier, and the predecessor's rollback then deletes
// the row — leaving a `.syncedPending` card, an acknowledged queue directory,
// and no copy of the payload anywhere.

import XCTest
import CryptoKit
@testable import Conduck

final class WorkboardPublicationLockTests: XCTestCase {

    private var storeURL: URL!

    /// Both stores here mint a vault directory and a lock directory of their
    /// own that nothing else removes; the fixture empties them when the class
    /// is done.
    private let isolated = IsolatedWorkStores()

    override func setUp() {
        super.setUp()
        storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("conduck-publication-lock-\(UUID().uuidString).sqlite")
    }

    override func tearDown() async throws {
        await isolated.cleanUp()
        removeStoreFiles(at: storeURL)
        removeStoreFiles(at: blobStoreURL)
        storeURL = nil
        try await super.tearDown()
    }

    // MARK: - The lock itself

    /// What the lock has to be before anything is built on it: exclusive per
    /// material, indifferent between materials, released by the holder, and
    /// escapable by a cancelled waiter.
    ///
    /// The last one is not a nicety. A capture that is cancelled while queued
    /// behind a several-hundred-megabyte reattach must stop waiting; a
    /// kernel-blocking `flock` could not be woken, which is why the production
    /// lock polls the non-blocking form instead.
    func testOneMaterialIsHeldExclusivelyWhileOthersAreFreeAndAWaiterCanBeCancelled() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("conduck-publication-lock-unit-\(UUID().uuidString)",
                                    isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        // Two lock values over one directory: what the app and the headless
        // intent process each hold.
        let mine = WorkMaterialPublicationLock(directoryURL: directory)
        let theirs = WorkMaterialPublicationLock(directoryURL: directory)
        let contended = UUID()
        let other = UUID()

        let held = try await mine.acquire(materialID: contended)

        // A different material is not queued behind this one: Work is a single
        // desk, so an owner-wide lock would put every capture behind the
        // largest reattach in flight.
        let unrelated = try await theirs.acquire(materialID: other)
        unrelated.release()

        let waiter = Task { try await theirs.acquire(materialID: contended) }
        // Long enough for the waiter to have polled and failed at least twice.
        try await Task.sleep(for: .milliseconds(80))
        waiter.cancel()
        do {
            _ = try await waiter.value
            XCTFail("a cancelled waiter must stop waiting rather than acquire")
        } catch is CancellationError {
            // Expected.
        }

        held.release()
        let afterRelease = try await theirs.acquire(materialID: contended)
        afterRelease.release()
    }

    // MARK: - The takeover

    /// A stale publisher and its successor, over one store, with the same
    /// deterministic material id and the same bytes.
    ///
    /// The predecessor is stopped inside its lock at the ONE point that matters
    /// — its blob is durable, no material row names it yet — and is then refused
    /// by a compare-and-swap, so its rollback deletes that blob. Unlocked, the
    /// successor reaches the blob store in that window, finds a complete row,
    /// adopts it, commits a card, and is left holding nothing when the rollback
    /// lands. Locked, the successor cannot look at the blob store until the
    /// predecessor has finished failing, so it writes its own bytes and the card
    /// is readable.
    ///
    /// Both halves are asserted: the ORDER (the successor's own hold fires only
    /// after the predecessor has left its own) and the OUTCOME (the card serves
    /// its payload).
    func testASuccessorNeverAdoptsABlobThePredecessorCanStillRollBack() async throws {
        let predecessor = isolated.make(storeURL: storeURL)
        let successor = isolated.make(storeURL: storeURL)

        // The desk has to exist before a compare-and-swap can refuse anything.
        _ = try await predecessor.upsertDeskMaterial(
            WorkMaterialDraft(kind: .note, title: "desk", textContent: "desk")
        )
        let deskValue = try await predecessor.fetchWorkItem(id: Constants.workboardDeskItemID)
        let desk = try XCTUnwrap(deskValue)
        let staleRevision = WorkboardRevision.value(for: desk.updatedAt) - 1

        let materialID = UUID()
        let payload = Data("the only copy outside the share queue".utf8)
        func capture() -> WorkMaterialDraft {
            WorkMaterialDraft(
                id: materialID,
                kind: .file,
                title: "receipt.txt",
                filename: "receipt.txt",
                mimeType: "text/plain",
                payload: payload,
                byteSize: Int64(payload.count)
            )
        }

        let timeline = LockTimeline()
        let predecessorIsInside = LockGate()

        await predecessor._setWorkMaterialPublicationLockHoldForTesting { [timeline, predecessorIsInside] id in
            guard id == materialID else { return }
            await timeline.append("predecessor-inside")
            await predecessorIsInside.open()
            // Long enough that an unlocked successor finishes its whole
            // publication inside this window.
            try? await Task.sleep(for: .milliseconds(700))
            await timeline.append("predecessor-leaving")
        }
        await successor._setWorkMaterialPublicationLockHoldForTesting { [timeline] id in
            guard id == materialID else { return }
            await timeline.append("successor-inside")
        }

        let stale = Task {
            try await predecessor.upsertDeskMaterial(
                capture(),
                expectedOwnerRevision: staleRevision
            )
        }
        // The predecessor's blob is durable and nothing names it yet: exactly
        // the window the successor must not be allowed into.
        await predecessorIsInside.wait()
        let takeover = Task { try await successor.upsertDeskMaterial(capture()) }

        do {
            _ = try await stale.value
            XCTFail("a publication against a revision the desk has moved past must be refused")
        } catch WorkboardStoreError.staleRevision {
            // Expected: and its rollback deletes the blob it inserted.
        }
        let adopted = try await takeover.value

        let events = await timeline.events
        XCTAssertEqual(
            events,
            ["predecessor-inside", "predecessor-leaving", "successor-inside"],
            """
            The successor reached the blob store while the predecessor was still inside its own \
            publication. That is the window in which it adopts a complete blob the predecessor's \
            rollback then deletes, leaving a card with no payload and a queue that has already \
            been acknowledged.
            """
        )

        XCTAssertEqual(adopted.storageMode, .syncedPayload)
        // What the drainer's durability barrier samples, and deliberately NOT
        // the discriminating assertion: unlocked, this reads true as well — the
        // adopted blob is still there when the successor looks, and only the
        // predecessor's later rollback takes it. A barrier cannot save a
        // capture from a deletion that has not happened yet, which is why the
        // exclusion has to be upstream of it.
        XCTAssertTrue(adopted.hasPayload)
        // The one that tells the two worlds apart: bytes that are still there
        // after the predecessor has finished failing.
        let loaded = try await successor.loadWorkMaterialPayload(id: materialID)
        XCTAssertEqual(loaded, payload)

        // The on-disk probe, not the in-memory row walk: these stores are real
        // sqlite files, which is what makes them two processes.
        let blob = try await successor._materialAndBlobForTesting(
            materialID: materialID, includingPayload: false
        )
        XCTAssertEqual(blob.blobRowCount, 1,
                       "one publication survived, and it is the one that committed")
        XCTAssertEqual(blob.blobContentHash, hex(payload))
        XCTAssertEqual(blob.blobByteSize, Int64(payload.count))

        // And the card the person sees, through the same projection the desk
        // reads: one card, available.
        let refreshedValue = try await successor.fetchWorkItem(id: Constants.workboardDeskItemID)
        let refreshed = try XCTUnwrap(refreshedValue)
        let card = try XCTUnwrap(refreshed.materials.first { $0.id == materialID })
        XCTAssertEqual(card.availability, .synced)
        XCTAssertEqual(refreshed.materials.filter { $0.id == materialID }.count, 1)
    }

    // MARK: - Helpers

    private func hex(_ payload: Data) -> String {
        SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
    }

    /// The payload store `ConversationStore` derives for a non-App-Group store.
    private var blobStoreURL: URL {
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

/// Ordered events from inside two publications, so mutual exclusion is observed
/// rather than argued for.
private actor LockTimeline {
    private(set) var events: [String] = []

    func append(_ event: String) {
        events.append(event)
    }
}

/// A one-shot gate: the successor is launched only once the predecessor is
/// provably inside its lock, so the race is staged rather than hoped for.
private actor LockGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func open() {
        isOpen = true
        let resuming = waiters
        waiters.removeAll()
        resuming.forEach { $0.resume() }
    }

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}
