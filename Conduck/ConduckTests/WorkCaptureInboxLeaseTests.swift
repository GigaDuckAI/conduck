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

    private func processingURL(for id: UUID) -> URL {
        root.appendingPathComponent("processing", isDirectory: true)
            .appendingPathComponent(id.uuidString, isDirectory: true)
    }

    private func leaseURL(for id: UUID) -> URL {
        processingURL(for: id)
            .appendingPathComponent(WorkCaptureInbox.leaseFilename, isDirectory: false)
    }

    private func readLease(for id: UUID) throws -> WorkCaptureInbox.ClaimLease {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try decoder.decode(
            WorkCaptureInbox.ClaimLease.self,
            from: try Data(contentsOf: leaseURL(for: id))
        )
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
        XCTAssertEqual(
            try childNames(of: processingURL(for: id)),
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
        XCTAssertFalse(FileManager.default.fileExists(atPath: processingURL(for: id).path))
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
        XCTAssertTrue(FileManager.default.fileExists(atPath: processingURL(for: id).path))
        XCTAssertEqual(try readLease(for: id).owner, intruder.ownerID)

        try await intruder.acknowledge(recovered)
        XCTAssertFalse(FileManager.default.fileExists(atPath: processingURL(for: id).path))
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

    func testAMarkerlessStrandedClaimIsRequeuedImmediately() async throws {
        // A directory in processing with no lease predates any claim this build
        // can make and is stranded by definition; no horizon should hide it.
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
}
