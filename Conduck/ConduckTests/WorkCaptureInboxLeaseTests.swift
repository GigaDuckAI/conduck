// SPDX-License-Identifier: Apache-2.0

// Conduck
// WorkCaptureInboxLeaseTests.swift
//
// Cross-process ownership of the inert capture queue: the app and a headless
// intent process drain the same App Group directory, so a claim's owner must be
// legible on disk. These tests drive two independent `WorkCaptureInbox`
// instances over one directory and pin the lease contract — a live claim is
// never requeued, an abandoned one always is, and a stolen claim can no longer
// be acknowledged. No Core Data, network, or notification permission is touched.

import XCTest
@testable import Conduck

/// Runs one hostile interleaving at the instant a claimant begins validating: the
/// closure receives the directory the claiming rename created, and the manifest
/// read then fails so the claimant takes its rollback path — the step that must
/// never touch bytes another acquisition owns.
private final class ClaimInterferenceFileManager: FileManager, @unchecked Sendable {
    private let lock = NSLock()
    private var interference: (@Sendable (URL) -> Void)?

    init(interference: @escaping @Sendable (URL) -> Void) {
        self.interference = interference
        super.init()
    }

    override func attributesOfItem(atPath path: String) throws -> [FileAttributeKey: Any] {
        lock.lock()
        var pending: (@Sendable (URL) -> Void)?
        if path.contains("/processing/"), path.hasSuffix("/manifest.json") {
            pending = interference
            interference = nil
        }
        lock.unlock()

        guard let pending else { return try super.attributesOfItem(atPath: path) }
        pending(URL(fileURLWithPath: path).deletingLastPathComponent())
        throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError)
    }
}

/// Requeues an acquisition the instant its claiming rename lands, so its lease
/// can never be written into it.
private final class RequeueDuringClaimFileManager: FileManager, @unchecked Sendable {
    private let lock = NSLock()
    private var requeue: (@Sendable (URL) -> Void)?

    init(requeue: @escaping @Sendable (URL) -> Void) {
        self.requeue = requeue
        super.init()
    }

    override func moveItem(at srcURL: URL, to dstURL: URL) throws {
        try super.moveItem(at: srcURL, to: dstURL)
        lock.lock()
        var pending: (@Sendable (URL) -> Void)?
        if dstURL.deletingLastPathComponent().lastPathComponent == "processing" {
            pending = requeue
            requeue = nil
        }
        lock.unlock()
        pending?(dstURL)
    }
}

/// Fails the next move OUT of a claimed directory, once. A release cannot be
/// made to fail on a healthy filesystem, and what the failure does to this
/// instance's own bookkeeping — not the fault itself — is the behaviour under
/// test. One-shot so that the reconciliation which has to recover the capture
/// afterwards runs against a working filesystem.
private final class ReleaseMoveFaultFileManager: FileManager, @unchecked Sendable {
    private let lock = NSLock()
    private var isArmed = false

    func armNextReleaseToFail() {
        lock.lock()
        isArmed = true
        lock.unlock()
    }

    override func moveItem(at srcURL: URL, to dstURL: URL) throws {
        lock.lock()
        let shouldFail = isArmed
            && srcURL.deletingLastPathComponent().lastPathComponent == "processing"
        if shouldFail { isArmed = false }
        lock.unlock()
        guard !shouldFail else {
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError)
        }
        try super.moveItem(at: srcURL, to: dstURL)
    }
}

/// Hands out a scripted sequence of claim generations, then reverts to fresh
/// ones. Production mints a fresh UUID per attempt, which can never name a path
/// that already exists, so aiming the claiming rename at an occupied
/// destination is the only way to reach that branch at all.
private nonisolated final class ScriptedGenerations: @unchecked Sendable {
    private let lock = NSLock()
    private var scripted: [UUID]

    init(_ scripted: [UUID]) {
        self.scripted = scripted
    }

    func next() -> UUID {
        lock.lock()
        defer { lock.unlock() }
        return scripted.isEmpty ? UUID() : scripted.removeFirst()
    }
}

final class WorkCaptureInboxLeaseTests: XCTestCase {
    private var root: URL!
    private let anchor = Date(timeIntervalSince1970: 1_700_000_000)

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("conduck-work-capture-lease-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
        root = nil
        try super.tearDownWithError()
    }

    // MARK: - Fixtures

    @discardableResult
    private func writePublished(id: UUID = UUID()) throws -> UUID {
        let directory = root.appendingPathComponent(id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("test".utf8).write(to: directory.appendingPathComponent("payload-000.pdf"))
        let envelope = WorkCaptureEnvelope(
            id: id,
            createdAt: anchor,
            note: "Review this",
            source: .shareExtension,
            entries: [WorkCaptureEnvelope.Entry(
                kind: .file,
                sequence: 0,
                relativePath: "payload-000.pdf",
                displayName: "proposal.pdf",
                mimeType: "application/pdf",
                typeIdentifier: "com.adobe.pdf",
                byteCount: 4
            )]
        )
        try envelope.encoded().write(to: directory.appendingPathComponent("manifest.json"))
        return id
    }

    private var processingRoot: URL {
        root.appendingPathComponent("processing", isDirectory: true)
    }

    /// A claimed directory is named for the acquisition that took it, so a test
    /// cannot spell its path either — it reads the queue back the way
    /// reconciliation does.
    private func claimedURLs(for id: UUID) -> [URL] {
        let children = (try? FileManager.default.contentsOfDirectory(
            at: processingRoot,
            includingPropertiesForKeys: nil
        )) ?? []
        return children.filter { $0.lastPathComponent.hasPrefix(id.uuidString) }
    }

    private func claimedURL(for id: UUID) throws -> URL {
        let claimed = claimedURLs(for: id)
        XCTAssertEqual(claimed.count, 1, "Exactly one acquisition may hold \(id.uuidString)")
        return try XCTUnwrap(claimed.first)
    }

    private func leaseURL(for id: UUID) throws -> URL {
        try claimedURL(for: id)
            .appendingPathComponent(WorkCaptureInbox.leaseFilename, isDirectory: false)
    }

    private func readLease(for id: UUID) throws -> WorkCaptureInbox.ClaimLease {
        try readLease(at: try leaseURL(for: id))
    }

    private func readLease(at url: URL) throws -> WorkCaptureInbox.ClaimLease {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try decoder.decode(
            WorkCaptureInbox.ClaimLease.self,
            from: try Data(contentsOf: url)
        )
    }

    /// Stages exactly what the claiming rename produces: the capture sits in
    /// processing under an acquisition's own name, and no lease has landed yet.
    @discardableResult
    private func stageAcquisition(
        of id: UUID,
        claimedAt: Date,
        generation: UUID = UUID()
    ) throws -> URL {
        try FileManager.default.createDirectory(at: processingRoot, withIntermediateDirectories: true)
        let claimed = processingRoot.appendingPathComponent(
            WorkCaptureInbox.claimDirectoryName(
                envelopeID: id,
                claimedAt: claimedAt,
                generation: generation
            ),
            isDirectory: true
        )
        try FileManager.default.moveItem(
            at: root.appendingPathComponent(id.uuidString, isDirectory: true),
            to: claimed
        )
        return claimed
    }

    private func childNames(of directory: URL) throws -> Set<String> {
        Set(try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).map(\.lastPathComponent))
    }

    // MARK: - Lease identity

    func testClaimingWritesALeaseNamingTheClaimingInstance() async throws {
        let id = try writePublished()
        let inbox = WorkCaptureInbox(baseURL: root)
        let other = WorkCaptureInbox(baseURL: root)
        XCTAssertNotEqual(inbox.ownerID, other.ownerID,
                          "Two inboxes over one directory must be distinguishable on disk")

        let claimed = try await inbox.claimNext(now: anchor)
        _ = try XCTUnwrap(claimed)

        let lease = try readLease(for: id)
        XCTAssertEqual(lease.owner, inbox.ownerID)
        XCTAssertEqual(lease.refreshedAt, anchor)
        XCTAssertEqual(lease.generation, try XCTUnwrap(claimed).generation,
                       "The marker names the acquisition its directory is named for")
        XCTAssertEqual(
            try childNames(of: try claimedURL(for: id)),
            ["manifest.json", "payload-000.pdf", WorkCaptureInbox.leaseFilename],
            "The lease is the only file a claim adds to a validated capture"
        )
    }

    func testAPublishedEnvelopeCannotDeclareTheLeaseFilenameAsItsPayload() async throws {
        let id = UUID()
        let directory = root.appendingPathComponent(id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("smuggled".utf8).write(
            to: directory.appendingPathComponent(WorkCaptureInbox.leaseFilename)
        )
        let envelope = WorkCaptureEnvelope(
            id: id,
            createdAt: anchor,
            note: "Review this",
            source: .shareExtension,
            entries: [WorkCaptureEnvelope.Entry(
                kind: .file,
                sequence: 0,
                relativePath: WorkCaptureInbox.leaseFilename,
                displayName: "proposal.pdf",
                byteCount: 8
            )]
        )
        try envelope.encoded().write(to: directory.appendingPathComponent("manifest.json"))
        let inbox = WorkCaptureInbox(baseURL: root)

        do {
            _ = try await inbox.claimNext(now: anchor)
            XCTFail("A payload must not be able to impersonate the ownership marker")
        } catch let error as WorkCaptureInbox.InboxError {
            XCTAssertEqual(error, .invalidEnvelope(id, .unsafeRelativePath))
        }
    }

    // MARK: - Two instances, one directory

    func testASecondInstanceDoesNotRequeueALiveClaimInsideTheHorizon() async throws {
        let id = try writePublished()
        let owner = WorkCaptureInbox(baseURL: root)
        let intruder = WorkCaptureInbox(baseURL: root)

        let claimed = try await owner.claimNext(now: anchor)
        let claim = try XCTUnwrap(claimed)

        let report = await intruder.reconcile(
            now: anchor.addingTimeInterval(WorkCaptureInbox.staleClaimHorizon - 1)
        )
        XCTAssertEqual(report.releasedClaimCount, 0)
        XCTAssertEqual(report.respectedLeaseCount, 1)
        XCTAssertFalse(report.encounteredFilesystemFailure)
        let pendingForIntruder = try await intruder.pendingCount()
        XCTAssertEqual(pendingForIntruder, 0)
        let stolen = try await intruder.claimNext(now: anchor)
        XCTAssertNil(stolen, "A draining process must not be interrupted by a second one")

        // The original drain still owns its bytes and can complete.
        let payloadURL = try XCTUnwrap(claim.payloadURL(for: claim.envelope.entries[0]))
        XCTAssertEqual(try Data(contentsOf: payloadURL), Data("test".utf8))
        try await owner.acknowledge(claim)
        XCTAssertTrue(claimedURLs(for: id).isEmpty)
    }

    func testARefreshedLeaseSurvivesAHorizonThatWouldHaveExpiredIt() async throws {
        let id = try writePublished()
        let owner = WorkCaptureInbox(baseURL: root)
        let intruder = WorkCaptureInbox(baseURL: root)

        let claimed = try await owner.claimNext(now: anchor)
        let claim = try XCTUnwrap(claimed)
        let refreshedAt = anchor.addingTimeInterval(WorkCaptureInbox.staleClaimHorizon - 1)
        try await owner.refreshLease(claim, now: refreshedAt)
        XCTAssertEqual(try readLease(for: id).refreshedAt, refreshedAt)

        let report = await intruder.reconcile(
            now: anchor.addingTimeInterval(WorkCaptureInbox.staleClaimHorizon + 1)
        )
        XCTAssertEqual(report.releasedClaimCount, 0)
        XCTAssertEqual(report.respectedLeaseCount, 1)
    }

    func testALeaseOlderThanTheHorizonIsRequeuedWithoutItsMarker() async throws {
        let id = try writePublished()
        let owner = WorkCaptureInbox(baseURL: root)
        let intruder = WorkCaptureInbox(baseURL: root)

        let claimed = try await owner.claimNext(now: anchor)
        _ = try XCTUnwrap(claimed)

        let report = await intruder.reconcile(
            now: anchor.addingTimeInterval(WorkCaptureInbox.staleClaimHorizon)
        )
        XCTAssertEqual(report.releasedClaimCount, 1)
        XCTAssertEqual(report.respectedLeaseCount, 0)
        XCTAssertEqual(
            try childNames(of: root.appendingPathComponent(id.uuidString, isDirectory: true)),
            ["manifest.json", "payload-000.pdf"],
            "A requeued capture returns to the exact shape its publisher wrote"
        )

        let recoveredClaim = try await intruder.claimNext(
            now: anchor.addingTimeInterval(WorkCaptureInbox.staleClaimHorizon)
        )
        let recovered = try XCTUnwrap(recoveredClaim)
        XCTAssertEqual(recovered.id, id)
        XCTAssertEqual(try readLease(for: id).owner, intruder.ownerID)
    }

    func testTheOriginalOwnerCanNeitherAcknowledgeNorReleaseAStolenClaim() async throws {
        let id = try writePublished()
        let owner = WorkCaptureInbox(baseURL: root)
        let intruder = WorkCaptureInbox(baseURL: root)

        let ownerClaim = try await owner.claimNext(now: anchor)
        let abandoned = try XCTUnwrap(ownerClaim)
        let expiry = anchor.addingTimeInterval(WorkCaptureInbox.staleClaimHorizon)
        _ = await intruder.reconcile(now: expiry)
        let recoveredClaim = try await intruder.claimNext(now: expiry)
        let recovered = try XCTUnwrap(recoveredClaim)

        do {
            try await owner.acknowledge(abandoned)
            XCTFail("A stale owner must not delete a capture another process is draining")
        } catch let error as WorkCaptureInbox.InboxError {
            XCTAssertEqual(error, .staleClaim)
        }
        do {
            try await owner.release(abandoned)
            XCTFail("A stale owner must not requeue a capture another process is draining")
        } catch let error as WorkCaptureInbox.InboxError {
            XCTAssertEqual(error, .staleClaim)
        }
        XCTAssertEqual(claimedURLs(for: id).count, 1)
        XCTAssertEqual(try readLease(for: id).owner, intruder.ownerID)

        try await intruder.acknowledge(recovered)
        XCTAssertTrue(claimedURLs(for: id).isEmpty)
    }

    // MARK: - Crash recovery

    func testACrashedClaimIsRecoveredByALaterInstanceOnlyPastTheHorizon() async throws {
        let id = try writePublished()
        do {
            // The claiming instance is dropped without acknowledging, exactly as a
            // killed process leaves the queue: its lease is the only trace left.
            let doomed = WorkCaptureInbox(baseURL: root)
            let doomedClaim = try await doomed.claimNext(now: anchor)
            _ = try XCTUnwrap(doomedClaim)
        }

        let relaunched = WorkCaptureInbox(baseURL: root)
        let tooEarly = await relaunched.reconcile(
            now: anchor.addingTimeInterval(WorkCaptureInbox.staleClaimHorizon - 1)
        )
        XCTAssertEqual(tooEarly.releasedClaimCount, 0)
        XCTAssertEqual(tooEarly.respectedLeaseCount, 1,
                       "A relaunched process cannot tell a dead owner from a live one before the horizon")

        let expiry = anchor.addingTimeInterval(WorkCaptureInbox.staleClaimHorizon)
        let recoveredReport = await relaunched.reconcile(now: expiry)
        XCTAssertEqual(recoveredReport.releasedClaimCount, 1)

        let recoveredClaim = try await relaunched.claimNext(now: expiry)
        let claim = try XCTUnwrap(recoveredClaim)
        XCTAssertEqual(claim.id, id)
        let payloadURL = try XCTUnwrap(claim.payloadURL(for: claim.envelope.entries[0]))
        XCTAssertEqual(
            try Data(contentsOf: payloadURL),
            Data("test".utf8),
            "Recovery must hand back the published bytes, not a repaired shell"
        )
        try await relaunched.acknowledge(claim)
        let pending = try await relaunched.pendingCount()
        XCTAssertEqual(pending, 0)
    }

    func testABareIdStrandedDirectoryIsRequeuedImmediately() async throws {
        // A processing directory named for the capture rather than for an
        // acquisition predates any claim this build can make: it is stranded by
        // definition, so no horizon should hide it.
        let id = try writePublished()
        let processing = root.appendingPathComponent("processing", isDirectory: true)
        try FileManager.default.createDirectory(at: processing, withIntermediateDirectories: true)
        try FileManager.default.moveItem(
            at: root.appendingPathComponent(id.uuidString, isDirectory: true),
            to: processing.appendingPathComponent(id.uuidString, isDirectory: true)
        )
        let inbox = WorkCaptureInbox(baseURL: root)

        let report = await inbox.reconcile(now: anchor)
        XCTAssertEqual(report.releasedClaimCount, 1)
        XCTAssertEqual(report.respectedLeaseCount, 0)
        let pending = try await inbox.pendingCount()
        XCTAssertEqual(pending, 1)
    }

    func testReleaseReturnsACaptureWithoutLeavingItsMarkerBehind() async throws {
        let id = try writePublished()
        let inbox = WorkCaptureInbox(baseURL: root)

        let firstClaim = try await inbox.claimNext(now: anchor)
        let claim = try XCTUnwrap(firstClaim)
        try await inbox.release(claim)
        XCTAssertEqual(
            try childNames(of: root.appendingPathComponent(id.uuidString, isDirectory: true)),
            ["manifest.json", "payload-000.pdf"]
        )

        // Containment is exact, so a surviving marker would fail the next claim.
        let secondClaim = try await inbox.claimNext(now: anchor)
        let second = try XCTUnwrap(secondClaim)
        XCTAssertEqual(second.id, id)
        XCTAssertNotEqual(second.token, claim.token)
    }

    // MARK: - Acquisition

    func testAnAcquisitionIsNotRequeuedBeforeItsLeaseLands() async throws {
        // The exact interleaving the claim path has to survive: the capture has
        // moved into processing and the marker naming its owner has not been
        // written yet, while another process reconciles the same directory.
        let id = try writePublished()
        let claimed = try stageAcquisition(of: id, claimedAt: anchor)
        let intruder = WorkCaptureInbox(baseURL: root)

        let report = await intruder.reconcile(now: anchor.addingTimeInterval(1))
        XCTAssertEqual(report.releasedClaimCount, 0)
        XCTAssertEqual(report.respectedLeaseCount, 1)
        XCTAssertFalse(report.encounteredFilesystemFailure)
        let pendingForIntruder = try await intruder.pendingCount()
        XCTAssertEqual(pendingForIntruder, 0)
        let stolen = try await intruder.claimNext(now: anchor.addingTimeInterval(1))
        XCTAssertNil(stolen, "An acquisition must not be interruptible between its move and its lease")
        XCTAssertEqual(
            try childNames(of: claimed),
            ["manifest.json", "payload-000.pdf"],
            "The staged acquisition is left exactly where its claiming rename put it"
        )
    }

    func testAnAcquisitionThatNeverLeasesIsRecoveredAtTheHorizon() async throws {
        // The grace an acquisition gets is bounded by the same horizon a lease
        // gets, so a process killed between the two can strand nothing.
        let id = try writePublished()
        try stageAcquisition(of: id, claimedAt: anchor)
        let inbox = WorkCaptureInbox(baseURL: root)
        let expiry = anchor.addingTimeInterval(WorkCaptureInbox.staleClaimHorizon)

        let report = await inbox.reconcile(now: expiry)
        XCTAssertEqual(report.releasedClaimCount, 1)
        XCTAssertEqual(report.respectedLeaseCount, 0)
        XCTAssertEqual(
            try childNames(of: root.appendingPathComponent(id.uuidString, isDirectory: true)),
            ["manifest.json", "payload-000.pdf"]
        )

        let recoveredClaim = try await inbox.claimNext(now: expiry)
        let recovered = try XCTUnwrap(recoveredClaim)
        XCTAssertEqual(recovered.id, id)
        XCTAssertEqual(try readLease(for: id).owner, inbox.ownerID)
    }

    func testARollbackCannotTouchACaptureAnotherAcquisitionTookOver() async throws {
        let id = try writePublished()
        let root = try XCTUnwrap(self.root)
        let anchor = self.anchor
        let thiefOwner = UUID()
        let thiefGeneration = UUID()
        let fileManager = ClaimInterferenceFileManager { claimed in
            // Another process requeues what it reads as an unowned claim and
            // retakes it under its own acquisition, all while the first claimant
            // is inside validation.
            let published = root.appendingPathComponent(id.uuidString, isDirectory: true)
            let retaken = claimed
                .deletingLastPathComponent()
                .appendingPathComponent(
                    WorkCaptureInbox.claimDirectoryName(
                        envelopeID: id,
                        claimedAt: anchor,
                        generation: thiefGeneration
                    ),
                    isDirectory: true
                )
            try? FileManager.default.moveItem(at: claimed, to: published)
            try? FileManager.default.moveItem(at: published, to: retaken)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .secondsSince1970
            let lease = WorkCaptureInbox.ClaimLease(
                owner: thiefOwner,
                generation: thiefGeneration,
                refreshedAt: anchor
            )
            try? encoder.encode(lease).write(
                to: retaken.appendingPathComponent(
                    WorkCaptureInbox.leaseFilename,
                    isDirectory: false
                ),
                options: .atomic
            )
        }
        let inbox = WorkCaptureInbox(baseURL: root, fileManager: fileManager)

        do {
            _ = try await inbox.claimNext(now: anchor)
            XCTFail("A transient validation failure must surface")
        } catch let error as WorkCaptureInbox.InboxError {
            XCTAssertEqual(error, .filesystemFailure)
        }

        let claimed = try claimedURL(for: id)
        XCTAssertEqual(
            try childNames(of: claimed),
            ["manifest.json", "payload-000.pdf", WorkCaptureInbox.leaseFilename],
            "The rolled-back claimant must not strip the new owner's directory"
        )
        let lease = try readLease(
            at: claimed.appendingPathComponent(WorkCaptureInbox.leaseFilename, isDirectory: false)
        )
        XCTAssertEqual(lease.owner, thiefOwner)
        XCTAssertEqual(lease.generation, thiefGeneration)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent(id.uuidString, isDirectory: true).path
            ),
            "A rollback must not requeue a capture it no longer owns"
        )
    }

    func testARollbackRefusesADirectoryAForeignLeaseCovers() async throws {
        let id = try writePublished()
        let anchor = self.anchor
        let foreignOwner = UUID()
        let foreignGeneration = UUID()
        let fileManager = ClaimInterferenceFileManager { claimed in
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .secondsSince1970
            let lease = WorkCaptureInbox.ClaimLease(
                owner: foreignOwner,
                generation: foreignGeneration,
                refreshedAt: anchor
            )
            try? encoder.encode(lease).write(
                to: claimed.appendingPathComponent(
                    WorkCaptureInbox.leaseFilename,
                    isDirectory: false
                ),
                options: .atomic
            )
        }
        let inbox = WorkCaptureInbox(baseURL: root, fileManager: fileManager)

        do {
            _ = try await inbox.claimNext(now: anchor)
            XCTFail("A transient validation failure must surface")
        } catch let error as WorkCaptureInbox.InboxError {
            XCTAssertEqual(error, .filesystemFailure)
        }

        XCTAssertEqual(claimedURLs(for: id).count, 1)
        XCTAssertEqual(try readLease(for: id).owner, foreignOwner,
                       "Rollback verifies the marker before moving anything")
        let pending = try await inbox.pendingCount()
        XCTAssertEqual(pending, 0)

        // Refusing to roll back cannot strand the capture: the horizon still
        // returns it, because a foreign marker is exactly what reconciliation
        // already knows how to age.
        let report = await inbox.reconcile(
            now: anchor.addingTimeInterval(WorkCaptureInbox.staleClaimHorizon)
        )
        XCTAssertEqual(report.releasedClaimCount, 1)
    }

    func testAClaimWhoseLeaseCannotLandIsRefusedWithoutClobberingTheRequeuedCapture() async throws {
        let id = try writePublished()
        let root = try XCTUnwrap(self.root)
        let fileManager = RequeueDuringClaimFileManager { claimed in
            try? FileManager.default.moveItem(
                at: claimed,
                to: root.appendingPathComponent(id.uuidString, isDirectory: true)
            )
        }
        let inbox = WorkCaptureInbox(baseURL: root, fileManager: fileManager)

        do {
            _ = try await inbox.claimNext(now: anchor)
            XCTFail("A claim that cannot be leased must not be drained")
        } catch let error as WorkCaptureInbox.InboxError {
            XCTAssertEqual(error, .filesystemFailure)
        }
        XCTAssertTrue(claimedURLs(for: id).isEmpty)
        XCTAssertEqual(
            try childNames(of: root.appendingPathComponent(id.uuidString, isDirectory: true)),
            ["manifest.json", "payload-000.pdf"],
            "The requeued capture keeps the exact shape its publisher wrote"
        )

        let retried = try await inbox.claimNext(now: anchor)
        XCTAssertEqual(try XCTUnwrap(retried).id, id)
        XCTAssertEqual(try readLease(for: id).owner, inbox.ownerID)
    }

    func testAnOccupiedAcquisitionPathRefusesTheClaimAndTouchesNeitherDirectory() async throws {
        // The claiming rename is the acquisition, so a destination that already
        // exists must read as an ordinary claim race: nothing merged, nothing
        // overwritten, and the capture still pending for the next generation.
        let id = try writePublished()
        let occupiedGeneration = UUID()
        let generations = ScriptedGenerations([occupiedGeneration])
        let inbox = WorkCaptureInbox(baseURL: root, makeGeneration: { generations.next() })

        try FileManager.default.createDirectory(at: processingRoot, withIntermediateDirectories: true)
        let occupied = processingRoot.appendingPathComponent(
            WorkCaptureInbox.claimDirectoryName(
                envelopeID: id,
                claimedAt: anchor,
                generation: occupiedGeneration
            ),
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: occupied, withIntermediateDirectories: true)
        try Data("another acquisition".utf8).write(
            to: occupied.appendingPathComponent("manifest.json", isDirectory: false)
        )

        let refused = try await inbox.claimNext(now: anchor)
        XCTAssertNil(refused, "A destination already taken is a claim race, not a claim")
        XCTAssertEqual(
            try childNames(of: occupied),
            ["manifest.json"],
            "The occupied acquisition keeps its own contents"
        )
        XCTAssertEqual(
            try Data(contentsOf: occupied.appendingPathComponent("manifest.json")),
            Data("another acquisition".utf8)
        )
        XCTAssertEqual(
            try childNames(of: root.appendingPathComponent(id.uuidString, isDirectory: true)),
            ["manifest.json", "payload-000.pdf"],
            "The refused capture stays exactly as its publisher wrote it"
        )
        let pending = try await inbox.pendingCount()
        XCTAssertEqual(pending, 1)

        // The next attempt mints a different generation, so the capture is
        // claimable without any recovery pass.
        let retried = try await inbox.claimNext(now: anchor)
        let claim = try XCTUnwrap(retried)
        XCTAssertEqual(claim.id, id)
        XCTAssertNotEqual(claim.generation, occupiedGeneration)
        XCTAssertEqual(
            claimedURLs(for: id).count,
            2,
            "The occupied directory is still there beside the acquisition that succeeded"
        )
        let lease = try readLease(
            at: claim.directoryURL.appendingPathComponent(
                WorkCaptureInbox.leaseFilename,
                isDirectory: false
            )
        )
        XCTAssertEqual(lease.owner, inbox.ownerID)
        XCTAssertEqual(lease.generation, claim.generation)
    }

    // MARK: - A release that cannot land

    /// Reconciliation skips every directory the local bookkeeping still names,
    /// because a live import must never have its bytes requeued underneath it.
    /// A token kept past the end of that import inverts the protection: the
    /// capture becomes invisible to this process for the life of the process,
    /// and no foreground retry can reach it. So a refused release ends this
    /// instance's interest in the claim while leaving the directory alone.
    func testAReleaseRefusedByACollisionStopsHidingTheClaimFromReconciliation() async throws {
        let id = try writePublished()
        let inbox = WorkCaptureInbox(baseURL: root)
        let claimResult = try await inbox.claimNext(now: anchor)
        let claim = try XCTUnwrap(claimResult)

        // The same capture id is pending again while this one is claimed, so
        // the release has nowhere to put its directory back.
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(id.uuidString, isDirectory: true),
            withIntermediateDirectories: false
        )
        do {
            try await inbox.release(claim)
            XCTFail("A release must not overwrite a capture already sitting at its destination")
        } catch {
            XCTAssertEqual(error as? WorkCaptureInbox.InboxError, .filesystemFailure)
        }

        XCTAssertEqual(
            try childNames(of: try claimedURL(for: id)),
            ["manifest.json", "payload-000.pdf", WorkCaptureInbox.leaseFilename],
            "the refusal moves nothing and strips nothing"
        )

        let judgedAt = anchor.addingTimeInterval(WorkCaptureInbox.staleClaimHorizon + 5)
        let blocked = await inbox.reconcile(now: judgedAt)
        XCTAssertEqual(
            blocked.collisionCount, 1,
            "a directory this instance still counted as its own would never be looked at"
        )
        XCTAssertEqual(blocked.releasedClaimCount, 0, "and it still may not overwrite the collision")

        // Once the colliding publication is gone the SAME process recovers the
        // capture, rather than it waiting for a relaunch.
        try FileManager.default.removeItem(
            at: root.appendingPathComponent(id.uuidString, isDirectory: true)
        )
        let recovered = await inbox.reconcile(now: judgedAt)
        XCTAssertEqual(recovered.releasedClaimCount, 1)
        let pending = try await inbox.pendingCount()
        XCTAssertEqual(pending, 1)
        let retakenResult = try await inbox.claimNext(now: judgedAt)
        let retaken = try XCTUnwrap(retakenResult)
        XCTAssertEqual(retaken.id, id, "and the bytes come back to a drainer intact")
        XCTAssertNotEqual(retaken.generation, claim.generation)
    }

    /// The same rule for a transient I/O fault: the marker has already gone with
    /// the release attempt, so the directory is markerless in processing and the
    /// stale horizon is what decides. It has to be reachable to decide at all.
    func testAReleaseWhoseMoveFailsLeavesTheBytesRecoverableByReconciliation() async throws {
        let id = try writePublished()
        let faults = ReleaseMoveFaultFileManager()
        let inbox = WorkCaptureInbox(baseURL: root, fileManager: faults)
        let claimResult = try await inbox.claimNext(now: anchor)
        let claim = try XCTUnwrap(claimResult)

        faults.armNextReleaseToFail()
        do {
            try await inbox.release(claim)
            XCTFail("A release whose move cannot land must surface the fault")
        } catch {
            XCTAssertEqual(error as? WorkCaptureInbox.InboxError, .filesystemFailure)
        }

        let stranded = try claimedURL(for: id)
        XCTAssertEqual(
            try childNames(of: stranded),
            ["manifest.json", "payload-000.pdf"],
            "the marker went with the release attempt; the capture did not"
        )
        XCTAssertEqual(
            try Data(
                contentsOf: stranded.appendingPathComponent("payload-000.pdf", isDirectory: false)
            ),
            Data("test".utf8),
            "the queue still holds the only copy of the shared file"
        )
        let pendingAfterFailure = try await inbox.pendingCount()
        XCTAssertEqual(pendingAfterFailure, 0, "the release really did not land")

        let judgedAt = anchor.addingTimeInterval(WorkCaptureInbox.staleClaimHorizon + 5)
        let report = await inbox.reconcile(now: judgedAt)
        XCTAssertEqual(report.releasedClaimCount, 1)
        XCTAssertFalse(report.encounteredFilesystemFailure)
        let pending = try await inbox.pendingCount()
        XCTAssertEqual(pending, 1)
        let retakenResult = try await inbox.claimNext(now: judgedAt)
        let retaken = try XCTUnwrap(retakenResult)
        XCTAssertEqual(retaken.id, id)
        XCTAssertNotEqual(retaken.generation, claim.generation)
    }
}
