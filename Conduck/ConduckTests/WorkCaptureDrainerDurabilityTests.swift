// SPDX-License-Identifier: Apache-2.0

// ConduckTests
// WorkCaptureDrainerDurabilityTests.swift
//
// The three promises the drainer makes about a capture's only copy of its
// bytes. Acknowledgement destroys the queue directory, so it may not run until
// every card the capture wrote reads back WITH a readable payload — a complete
// blob row on the synced lane, a present leaf on the vault lane. The claim's
// lease is renewed while the import runs, so a slow byte import cannot age past
// the queue's stale horizon and be reclaimed mid-write. And losing that
// ownership is terminal: a renewal that proves another acquisition holds the
// claim stops the import before its next material write, and the former owner
// then acknowledges nothing and requeues nothing.
//
// All three are staged through the drainer's two import holds, because all
// three happen inside windows a bounded envelope otherwise crosses in
// milliseconds — and the interval the lease exists for is the one INSIDE
// `persist`, where the bytes are read and stored. Kept apart from
// `WorkCaptureDrainerTests` (which pins where captures land) since every case
// here needs a hold, an injected clock, or a payload sized to pick a lane.

import XCTest
@testable import Conduck

final class WorkCaptureDrainerDurabilityTests: XCTestCase {
    private var root: URL!

    /// Every store here mints a vault directory of its own that nothing else
    /// removes, and one case stages a payload above the sync ceiling precisely
    /// so that it takes the vault lane — so the leaves are large as well as
    /// numerous. The fixture empties them when the class is done.
    ///
    /// Teardown cannot race a vault operation: every case that spawns a drain
    /// awaits its outcome before returning, and an `async let` that a thrown
    /// assertion skips is cancelled and awaited at scope exit.
    private let isolated = IsolatedWorkStores()

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "conduck-work-drainer-durability-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        await isolated.cleanUp()
        if let root { try? FileManager.default.removeItem(at: root) }
        root = nil
        try await super.tearDown()
    }

    // MARK: - The acknowledgement barrier proves bytes, not ids

    /// The synced lane commits the blob and the material in separate
    /// transactions, so a card can name bytes the payload store does not hold.
    /// Acknowledging such a card destroys the last copy of the payload, which is
    /// why presence of the row is not the barrier's question.
    func testAPendingSyncedCardBlocksAcknowledgementAndKeepsTheQueueCopy() async throws {
        let store = isolated.make()
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
        let store = isolated.make()
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
        let store = isolated.make()
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

    // MARK: - The lease outlives a slow import

    /// The interval the lease exists for is the one in which a capture's bytes
    /// are read and stored, so the hold sits between two material writes —
    /// before the entry whose payload the store still has to copy. A validated
    /// envelope may carry up to `maximumEnvelopeBytes` and a suspended app can
    /// stretch any import further, so ownership has to be restated while that
    /// work runs. Without the renewal the marker keeps its claim-time stamp and
    /// a second process reconciling past the horizon requeues a directory this
    /// drainer is still importing.
    func testTheHeartbeatKeepsASlowByteImportOwnedPastTheStaleHorizon() async throws {
        let store = isolated.make()
        let payload = Data("bytes the store is still copying".utf8)
        let entryID = UUID()
        let envelope = WorkCaptureEnvelope(
            note: "An import that outlives the horizon",
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
        // One material — the note — is written; the entry carrying the bytes is
        // not. This is the window a large file spends inside the store.
        await drainer._setMaterialWriteHoldForTesting { boundary in
            guard boundary == 1 else { return }
            await gate.hold(deadline: 30)
        }

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
        XCTAssertEqual(finished.importedMaterialCount, 2)
        let pending = try await inbox.pendingCount()
        XCTAssertEqual(pending, 0, "the owner still completes its own import")
        XCTAssertTrue(try claimedDirectories().isEmpty)
        let storedBytes = try await store.loadWorkMaterialPayload(id: entryID)
        XCTAssertEqual(storedBytes, payload, "and the bytes it was copying reached the desk")
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

    // MARK: - Losing the claim is terminal

    /// The three clocks — the 60-second renewal, the 5-minute stale horizon, the
    /// vault's 15-minute grace — describe one owner only while ownership loss
    /// ENDS the import. A suspended app whose claim is legitimately taken at the
    /// horizon must not resume writing into it: the process that took it is
    /// importing the same bytes, and a former owner that kept going would write
    /// materials under a claim it cannot acknowledge and could requeue a
    /// directory another drainer is reading.
    func testAProvenTakeoverStopsTheImportBeforeItsNextMaterialWrite() async throws {
        let store = isolated.make()
        let firstEntry = UUID()
        let secondEntry = UUID()
        let envelope = WorkCaptureEnvelope(
            note: "A capture another process takes over",
            source: .shareExtension,
            entries: [
                .init(id: firstEntry, kind: .text, sequence: 0, text: "First source"),
                .init(id: secondEntry, kind: .text, sequence: 1, text: "Second source"),
            ]
        )
        try publish(envelope)

        // A clock that never moves is a suspended app: every renewal restates
        // the instant the claim was taken, so the claim ages out of the horizon
        // exactly as the queue's design intends.
        let base = Date()
        let gate = ImportGate()
        let inbox = WorkCaptureInbox(baseURL: root)
        let drainer = WorkCaptureDrainer(
            inbox: inbox,
            store: store,
            sourceDevice: "test-device",
            leaseHeartbeatInterval: .milliseconds(10),
            now: { base }
        )
        await drainer._setMaterialWriteHoldForTesting { boundary in
            guard boundary == 1 else { return }
            await gate.hold()
        }

        async let drained = drainer.drainAvailableCaptures()
        await gate.waitUntilHeld()
        let originalClaim = try XCTUnwrap(try claimedDirectories().first).lastPathComponent

        // Another process finds the suspended claim past the horizon and takes
        // it: reconciliation requeues it, and its own acquisition claims it.
        let judgedAt = base.addingTimeInterval(WorkCaptureInbox.staleClaimHorizon + 5)
        let intruder = WorkCaptureInbox(baseURL: root)
        let reconciled = await intruder.reconcile(now: judgedAt)
        XCTAssertEqual(reconciled.releasedClaimCount, 1,
                       "a claim nobody renewed is fair game at the horizon")
        let taken = try await intruder.claimNext(now: judgedAt)
        XCTAssertEqual(try XCTUnwrap(taken).id, envelope.id,
                       "the capture now belongs to the acquisition that took it")

        do {
            _ = try await drained
            XCTFail("An import whose claim was taken over must not run to completion")
        } catch {
            XCTAssertEqual(error as? WorkCaptureInbox.InboxError, .staleClaim)
        }

        let wasCancelled = await gate.wasCancelled
        XCTAssertTrue(wasCancelled, "a proven takeover cancels the import rather than being swallowed")
        let desk = try await unwrapDesk(store)
        XCTAssertEqual(
            desk.materials.map(\.id), [envelope.id],
            "the import stops before its next material write — only the note written before the takeover is on the desk"
        )
        let claims = try claimedDirectories()
        XCTAssertEqual(claims.count, 1, "the new owner's claim is the only one")
        let survivingClaim = try XCTUnwrap(claims.first)
        XCTAssertNotEqual(survivingClaim.lastPathComponent, originalClaim,
                          "and it is a different acquisition from the one that lost it")
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: survivingClaim
                    .appendingPathComponent("manifest.json", isDirectory: false).path
            ),
            "nothing was acknowledged: the capture the new owner holds is intact"
        )
        let pending = try await inbox.pendingCount()
        XCTAssertEqual(pending, 0,
                       "and nothing was requeued out from under the process now importing it")
    }

    /// Only a PROVEN takeover is terminal. A marker that cannot be written for a
    /// moment — a device under load, a directory briefly unwritable — must leave
    /// the beat running, because giving up on the first fault would disarm the
    /// protection for the rest of a long import.
    func testATransientRenewalFailureDoesNotStopTheImport() async throws {
        let store = isolated.make()
        let entryID = UUID()
        let envelope = WorkCaptureEnvelope(
            note: "A capture whose marker is briefly unwritable",
            source: .shareExtension,
            entries: [.init(id: entryID, kind: .text, sequence: 0, text: "Source excerpt")]
        )
        try publish(envelope)

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
        await drainer._setMaterialWriteHoldForTesting { boundary in
            guard boundary == 1 else { return }
            await gate.hold(deadline: 30)
        }

        async let drained = drainer.drainAvailableCaptures()
        await gate.waitUntilHeld()

        let claimed = try XCTUnwrap(try claimedDirectories().first)
        let stampBeforeTheFault = try leaseRefreshedAt(in: claimed)
        // A claimed directory the marker cannot be written into. The lease is
        // still READABLE, so ownership is never in doubt: the renewal fails on
        // its write, which is a filesystem fault and not a lost claim.
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o500],
            ofItemAtPath: claimed.path
        )
        let attemptsWhenFaulted = clock.renewalAttempts
        try await waitUntil("the heartbeat stopped attempting renewals after a write failure") {
            clock.renewalAttempts >= attemptsWhenFaulted + 3
        }
        XCTAssertEqual(try leaseRefreshedAt(in: claimed), stampBeforeTheFault,
                       "those attempts really did fail — the marker on disk never moved")
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: claimed.path
        )

        // With the fault gone a renewal lands again, and it is a renewal made
        // after the clock moved rather than the one the claim itself wrote.
        clock.advance(to: 120)
        try await waitUntil("the heartbeat never recovered from the transient failure") {
            try self.leaseRefreshedAt(in: claimed).timeIntervalSince(stampBeforeTheFault) >= 60
        }

        await gate.release()
        let report = try await drained
        XCTAssertEqual(report.importedCaptureCount, 1)
        XCTAssertEqual(report.importedMaterialCount, 2,
                       "the import ran to completion through the fault")
        let pending = try await inbox.pendingCount()
        XCTAssertEqual(pending, 0)
        let desk = try await unwrapDesk(store)
        XCTAssertEqual(Set(desk.materials.map(\.id)), [envelope.id, entryID])
    }

    /// Cancelling a drain mid-import is the other direction of the same rule.
    /// The capture must come back to the queue whole, and the renewal must not
    /// outlive the import it protects: a beat still restating ownership of a
    /// claim nobody is draining would hold a capture hostage until the horizon.
    func testCancellingADrainMidImportRequeuesTheClaimAndStopsTheHeartbeat() async throws {
        let store = isolated.make()
        let entryID = UUID()
        let envelope = WorkCaptureEnvelope(
            note: "A capture whose drain is cancelled",
            source: .shareExtension,
            entries: [.init(id: entryID, kind: .text, sequence: 0, text: "Source excerpt")]
        )
        try publish(envelope)

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
        await drainer._setMaterialWriteHoldForTesting { boundary in
            guard boundary == 1 else { return }
            await gate.hold(deadline: 10)
        }

        let drain = Task { try await drainer.drainAvailableCaptures() }
        await gate.waitUntilHeld()
        drain.cancel()

        switch await drain.result {
        case .success:
            XCTFail("A cancelled drain must not report an import it did not finish")
        case .failure(let error):
            XCTAssertTrue(error is CancellationError, "got \(error)")
        }

        let wasCancelled = await gate.wasCancelled
        XCTAssertTrue(wasCancelled, "cancellation reaches the import between material writes")
        let desk = try await unwrapDesk(store)
        XCTAssertEqual(desk.materials.map(\.id), [envelope.id],
                       "the import stopped at the boundary rather than finishing anyway")
        XCTAssertTrue(try claimedDirectories().isEmpty, "the claim is not left held")
        let pending = try await inbox.pendingCount()
        XCTAssertEqual(pending, 1, "the capture goes back to the queue")

        // No renewal survives the drain. Reading the clock is the first thing a
        // renewal attempt does, so a stable count is a beat that has stopped.
        let attemptsAtReturn = clock.renewalAttempts
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(clock.renewalAttempts, attemptsAtReturn,
                       "no lease renewal happens after the cancelled drain returns")

        // And the capture is recoverable rather than merely preserved.
        let recovery = try await WorkCaptureDrainer(
            inbox: inbox,
            store: store,
            sourceDevice: "test-device"
        ).drainAvailableCaptures()
        XCTAssertEqual(recovery.replayedCaptureCount, 1,
                       "the card the cancelled import wrote makes the retry a replay")
        let pendingAfterRecovery = try await inbox.pendingCount()
        XCTAssertEqual(pendingAfterRecovery, 0)
        let repaired = try await unwrapDesk(store)
        XCTAssertEqual(Set(repaired.materials.map(\.id)), [envelope.id, entryID])
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

    private func leaseRefreshedAt(in claimed: URL) throws -> Date {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let data = try Data(
            contentsOf: claimed.appendingPathComponent(
                WorkCaptureInbox.leaseFilename,
                isDirectory: false
            )
        )
        return try decoder.decode(WorkCaptureInbox.ClaimLease.self, from: data).refreshedAt
    }

    /// Poll for a condition a background beat produces. Polling is what makes
    /// the OUTCOME deterministic rather than the timing: the assertion is that
    /// the beat gets there at all, and the bound only decides how long a build
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

    /// Wait until the marker on disk still covers `instant` — the same question
    /// reconciliation asks, rather than an equality on a timestamp that
    /// round-trips through JSON seconds. Only a renewal made after the clock
    /// moved can satisfy it; the lease the claim itself wrote cannot.
    private func waitForLeaseCovering(
        _ instant: Date,
        timeout: TimeInterval = 10
    ) async throws {
        let horizon = WorkCaptureInbox.staleClaimHorizon
        try await waitUntil(
            "The claim's lease was never renewed while its import was still running",
            timeout: timeout
        ) {
            guard let claimed = try self.claimedDirectories().first,
                  let refreshedAt = try? self.leaseRefreshedAt(in: claimed) else { return false }
            return instant.timeIntervalSince(refreshedAt) < horizon
        }
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
    private var reads = 0

    init(base: Date) { self.base = base }

    var now: Date {
        lock.lock()
        defer { lock.unlock() }
        reads += 1
        return base.addingTimeInterval(offset)
    }

    /// Reading the clock is the first thing a renewal attempt does, and the
    /// drainer reads it nowhere else — so this counts attempts, which is the
    /// only observation a test has of a beat whose writes are failing, and of
    /// one that has stopped.
    var renewalAttempts: Int {
        lock.lock()
        defer { lock.unlock() }
        return reads
    }

    func advance(to offset: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        self.offset = offset
    }
}

/// A rendezvous that parks one import inside the region its lease covers, so a
/// test can inspect ownership — or remove the bytes a card names — at an exact
/// point between two writes.
///
/// The wait ends on cancellation as well as on `release()`, because cancelling
/// the import is precisely how a proven takeover is made terminal: a hold that
/// ignored cancellation would deadlock the case it exists to stage. The
/// deadline keeps a build that never cancels failing an assertion instead of
/// hanging the suite.
private actor ImportGate {
    private var isHeld = false
    private var isReleased = false
    private(set) var wasCancelled = false

    func hold(deadline: TimeInterval = 5) async {
        isHeld = true
        let expiry = Date().addingTimeInterval(deadline)
        while !isReleased {
            if Task.isCancelled {
                wasCancelled = true
                return
            }
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
