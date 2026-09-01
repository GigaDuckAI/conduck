// SPDX-License-Identifier: Apache-2.0

// ConduckTests
// WorkCaptureDrainerDurabilityTests.swift
//
// The two promises the drainer makes about a capture's only copy of its bytes.
// Acknowledgement destroys the queue directory, so it may not run until every
// card the capture wrote reads back WITH a readable payload — a complete blob
// row on the synced lane, a present leaf on the vault lane. And the claim's
// lease is renewed while that import runs, so a long one cannot age past the
// queue's stale horizon and be reclaimed by another process mid-write.
//
// Both are staged through the drainer's import hold, because both happen inside
// a window a bounded envelope otherwise crosses in milliseconds. Kept apart from
// `WorkCaptureDrainerTests` (which pins where captures land) since every case
// here needs the hold, an injected clock, or a payload sized to pick a lane.

import XCTest
@testable import Conduck

final class WorkCaptureDrainerDurabilityTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "conduck-work-drainer-durability-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
        root = nil
        try super.tearDownWithError()
    }

    // MARK: - The acknowledgement barrier proves bytes, not ids

    /// The synced lane commits the blob and the material in separate
    /// transactions, so a card can name bytes the payload store does not hold.
    /// Acknowledging such a card destroys the last copy of the payload, which is
    /// why presence of the row is not the barrier's question.
    func testAPendingSyncedCardBlocksAcknowledgementAndKeepsTheQueueCopy() async throws {
        let store = ConversationStore(inMemory: true)
        let payload = Data("bytes that must outlive a blob that never landed".utf8)
        let entryID = UUID()
        let envelope = WorkCaptureEnvelope(
            note: "With an attachment",
            source: .shareExtension,
            entries: [
                .init(
                    id: entryID,
                    kind: .file,
                    sequence: 0,
                    relativePath: "payload-000.bin",
                    displayName: "notes.bin",
                    mimeType: "application/octet-stream",
                    byteCount: Int64(payload.count)
                )
            ]
        )
        try publish(envelope, payloads: ["payload-000.bin": payload])

        let inbox = WorkCaptureInbox(baseURL: root)
        let drainer = WorkCaptureDrainer(inbox: inbox, store: store, sourceDevice: "test-device")
        // The blob disappears between publication and the barrier — the payload
        // store lost, or a merge that never carried the blob across.
        await drainer._setImportHoldForTesting {
            _ = await store._deleteWorkMaterialBlobRowsForTesting(materialID: entryID)
        }

        do {
            _ = try await drainer.drainAvailableCaptures()
            XCTFail("A card whose payload cannot be read must not consume the queue copy")
        } catch {
            XCTAssertEqual(error as? WorkboardStoreError, .materialPayloadUnavailable)
        }

        let desk = try await unwrapDesk(store)
        XCTAssertEqual(
            Set(desk.materials.map(\.id)), [envelope.id, entryID],
            "every id this capture wrote IS on the desk — presence is exactly what an id check would have accepted"
        )
        let card = try XCTUnwrap(desk.materials.first { $0.id == entryID })
        XCTAssertEqual(card.storageMode, .syncedPayload)
        XCTAssertEqual(card.availability, .syncedPending,
                       "the card survives and waits for its bytes rather than being deleted")
        XCTAssertFalse(card.hasPayload)
        let pending = try await inbox.pendingCount()
        XCTAssertEqual(pending, 1, "the claim goes back to the queue for a later replay")
        let queued = root
            .appendingPathComponent(envelope.id.uuidString, isDirectory: true)
            .appendingPathComponent("payload-000.bin", isDirectory: false)
        XCTAssertEqual(try Data(contentsOf: queued), payload,
                       "the queue still holds the only copy of the shared file")
    }

    /// The vault lane's failure is the mirror image: the row names a leaf this
    /// device no longer has. A payload above `workboardSyncCeilingBytes` is what
    /// takes that lane, so the fixture is sized rather than forced.
    func testAMissingVaultLeafBlocksAcknowledgementAndKeepsTheQueueCopy() async throws {
        let store = ConversationStore(inMemory: true)
        let payload = Data(
            repeating: 0x2A,
            count: Int(Constants.workboardSyncCeilingBytes) + 1
        )
        let entryID = UUID()
        let envelope = WorkCaptureEnvelope(
            note: "Too large to sync",
            source: .shareExtension,
            entries: [
                .init(
                    id: entryID,
                    kind: .file,
                    sequence: 0,
                    relativePath: "payload-000.bin",
                    displayName: "capture.bin",
                    mimeType: "application/octet-stream",
                    byteCount: Int64(payload.count)
                )
            ]
        )
        try publish(envelope, payloads: ["payload-000.bin": payload])

        let inbox = WorkCaptureInbox(baseURL: root)
        let drainer = WorkCaptureDrainer(inbox: inbox, store: store, sourceDevice: "test-device")
        await drainer._setImportHoldForTesting {
            let desk = try? await store.fetchWorkItem(id: Constants.workboardDeskItemID)
            guard let key = desk?.materials.first(where: { $0.id == entryID })?.localVaultKey
            else { return }
            try? await store.workAssetVault.remove(key)
        }

        do {
            _ = try await drainer.drainAvailableCaptures()
            XCTFail("A card whose vault leaf is gone must not consume the queue copy")
        } catch {
            XCTAssertEqual(error as? WorkboardStoreError, .materialPayloadUnavailable)
        }

        let desk = try await unwrapDesk(store)
        XCTAssertEqual(
            Set(desk.materials.map(\.id)), [envelope.id, entryID],
            "every id this capture wrote IS on the desk — presence is exactly what an id check would have accepted"
        )
        let card = try XCTUnwrap(desk.materials.first { $0.id == entryID })
        XCTAssertEqual(card.storageMode, .localVault,
                       "a payload above the ceiling takes the device-local vault")
        XCTAssertEqual(card.availability, .unavailableOnThisDevice)
        XCTAssertFalse(card.hasPayload)
        let pending = try await inbox.pendingCount()
        XCTAssertEqual(pending, 1)
        let queued = root
            .appendingPathComponent(envelope.id.uuidString, isDirectory: true)
            .appendingPathComponent("payload-000.bin", isDirectory: false)
        XCTAssertEqual(try Data(contentsOf: queued), payload)
    }

    /// The barrier must not over-reach in the other direction: a capture whose
    /// cards carry their whole content in the row has no payload to prove, and
    /// requiring one would refuse every note, shared text and link.
    func testACaptureWithoutBytesStillAcknowledges() async throws {
        let store = ConversationStore(inMemory: true)
        let envelope = WorkCaptureEnvelope(
            note: "No attachment at all",
            source: .app,
            entries: [
                .init(kind: .text, sequence: 0, text: "Source excerpt"),
                .init(kind: .url, sequence: 1, text: "https://example.com/source"),
            ]
        )
        try publish(envelope)

        let inbox = WorkCaptureInbox(baseURL: root)
        let drainer = WorkCaptureDrainer(inbox: inbox, store: store, sourceDevice: "test-device")
        let report = try await drainer.drainAvailableCaptures()

        XCTAssertEqual(report.importedCaptureCount, 1)
        XCTAssertEqual(report.importedMaterialCount, 3)
        let pending = try await inbox.pendingCount()
        XCTAssertEqual(pending, 0, "a metadata-only capture is durable the moment its rows are")
        let desk = try await unwrapDesk(store)
        XCTAssertEqual(desk.materials.count, 3)
        XCTAssertTrue(desk.materials.allSatisfy { $0.availability == .metadataOnly })
    }

    // MARK: - The lease outlives a long import

    /// A validated envelope may carry up to `maximumEnvelopeBytes`, and a
    /// suspended app can stretch any import further, so ownership has to be
    /// restated while the work runs. Without the renewal the marker keeps its
    /// claim-time stamp and a second process reconciling past the horizon
    /// requeues a directory this drainer is still reading.
    func testTheHeartbeatKeepsALongImportOwnedPastTheStaleHorizon() async throws {
        let store = ConversationStore(inMemory: true)
        let envelope = WorkCaptureEnvelope(
            note: "An import that outlives the horizon",
            source: .shareExtension,
            entries: []
        )
        try publish(envelope)

        // Anchored on the real clock, because `claimNext` stamps the first lease
        // with `Date()`: a virtual timeline that did not continue the real one
        // would let that first stamp satisfy the wait and prove nothing.
        let base = Date()
        let clock = AdvancingClock(base: base)
        let gate = ImportGate()
        let inbox = WorkCaptureInbox(baseURL: root)
        let drainer = WorkCaptureDrainer(
            inbox: inbox,
            store: store,
            sourceDevice: "test-device",
            leaseHeartbeatInterval: .milliseconds(10),
            now: { clock.now }
        )
        await drainer._setImportHoldForTesting { await gate.hold() }

        async let drained = drainer.drainAvailableCaptures()
        await gate.waitUntilHeld()

        // The import is now far older than the horizon in the only clock the
        // lease records.
        let wellPast = WorkCaptureInbox.staleClaimHorizon + 60
        let judgedAt = base.addingTimeInterval(wellPast + 1)
        clock.advance(to: wellPast)
        try await waitForLeaseCovering(judgedAt)

        // A second process — the app beside a headless intent process — deciding
        // whether this directory has been abandoned.
        let intruder = WorkCaptureInbox(baseURL: root)
        let report = await intruder.reconcile(now: judgedAt)
        XCTAssertEqual(report.respectedLeaseCount, 1,
                       "a renewed lease keeps a live import's directory out of reconciliation")
        XCTAssertEqual(report.releasedClaimCount, 0)
        XCTAssertEqual(
            try claimedDirectories().count, 1,
            "the claimed directory is never requeued underneath the drainer reading it"
        )
        let stolen = try await intruder.claimNext(now: judgedAt)
        XCTAssertNil(stolen, "and no second drainer can claim it")

        await gate.release()
        let finished = try await drained
        XCTAssertEqual(finished.importedCaptureCount, 1)
        let pending = try await inbox.pendingCount()
        XCTAssertEqual(pending, 0, "the owner still completes its own import")
        XCTAssertTrue(try claimedDirectories().isEmpty)
    }

    /// The renewal is only worth anything if it lands several times inside the
    /// window it defends. Raising the interval towards the horizon would leave a
    /// single late beat able to hand away a live claim, and nothing else in the
    /// suite would notice.
    func testTheHeartbeatIntervalLeavesRoomForMissedRenewals() {
        XCTAssertGreaterThan(WorkCaptureDrainer.defaultLeaseHeartbeatInterval, .zero)
        XCTAssertLessThan(
            WorkCaptureDrainer.defaultLeaseHeartbeatInterval * 4,
            .seconds(WorkCaptureInbox.staleClaimHorizon),
            "four consecutive renewals must still fit inside the stale horizon"
        )
    }

    // MARK: - Helpers

    private func unwrapDesk(_ store: ConversationStore) async throws -> WorkItemRecord {
        let deskValue = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        return try XCTUnwrap(deskValue, "every capture resolves the one desk")
    }

    /// The directories the inbox currently holds claimed, found rather than
    /// named: a claim path is generation-scoped and its shape belongs to
    /// `WorkCaptureInbox`, so reconstructing it here would pin a private
    /// convention instead of the ownership this file is about.
    private func claimedDirectories() throws -> [URL] {
        let processing = root.appendingPathComponent("processing", isDirectory: true)
        guard FileManager.default.fileExists(atPath: processing.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(
            at: processing,
            includingPropertiesForKeys: nil
        )
    }

    /// Wait until the marker on disk still covers `instant` — the same question
    /// reconciliation asks, rather than an equality on a timestamp that
    /// round-trips through JSON seconds. Only a renewal made after the clock
    /// moved can satisfy it; the lease the claim itself wrote cannot.
    ///
    /// Polling is what makes the OUTCOME deterministic rather than the timing:
    /// the assertion is that a renewal lands at all, and the bound only decides
    /// how long a build that never renews takes to say so.
    private func waitForLeaseCovering(
        _ instant: Date,
        timeout: TimeInterval = 10
    ) async throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let horizon = WorkCaptureInbox.staleClaimHorizon
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let claimed = try claimedDirectories().first,
               let data = try? Data(
                   contentsOf: claimed.appendingPathComponent(
                       WorkCaptureInbox.leaseFilename,
                       isDirectory: false
                   )
               ),
               let lease = try? decoder.decode(WorkCaptureInbox.ClaimLease.self, from: data),
               instant.timeIntervalSince(lease.refreshedAt) < horizon {
                return
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("The claim's lease was never renewed while its import was still running")
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
}

/// A clock the test moves by hand. The lease horizon is five minutes and no
/// suite can wait one, so the drainer takes its renewal timestamps from an
/// injected source and this stands in for `Date.init`.
private nonisolated final class AdvancingClock: @unchecked Sendable {
    private let lock = NSLock()
    private let base: Date
    private var offset: TimeInterval = 0

    init(base: Date) { self.base = base }

    var now: Date {
        lock.lock()
        defer { lock.unlock() }
        return base.addingTimeInterval(offset)
    }

    func advance(to offset: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        self.offset = offset
    }
}

/// A rendezvous that parks one import inside the region its lease covers, so a
/// test can inspect ownership — or remove the bytes a card names — at the exact
/// point between the write and the acknowledgement barrier.
private actor ImportGate {
    private var isHeld = false
    private var isReleased = false

    func hold() async {
        isHeld = true
        while !isReleased {
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
