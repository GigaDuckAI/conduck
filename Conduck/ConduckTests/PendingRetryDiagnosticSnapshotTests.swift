// SPDX-License-Identifier: Apache-2.0

// ConduckTests
// PendingRetryDiagnosticSnapshotTests.swift
//
// The Diagnostics reduction is read through an isolated real file store. This
// catches disagreement between the pure expiry/availability rules and the
// queue's reconciliation, leases, and file inventory. Every test uses its own
// temporary directory and in-memory defaults; the App-Group singleton is never
// reached. The current-format cases assert that the inspection does not load
// recordings through readAudio. Snapshots still run inherited reconciliation
// and expiry maintenance; legacy migration may copy or compare audio bytes.

import XCTest
@testable import Conduck

final class PendingRetryDiagnosticSnapshotTests: XCTestCase {
    private var container: URL!
    private var defaults: InMemoryDefaultsStore!
    private var store: PendingRetryStore!

    override func setUp() {
        super.setUp()
        container = FileManager.default.temporaryDirectory
            .appendingPathComponent("pending-retry-diagnostics-\(UUID().uuidString)", isDirectory: true)
        defaults = InMemoryDefaultsStore()
        store = PendingRetryStore(containerURL: container, defaults: defaults)
    }

    override func tearDown() {
        if let container { try? FileManager.default.removeItem(at: container) }
        store = nil
        defaults = nil
        container = nil
        super.tearDown()
    }

    func testEmptyQueueHasNoReportEntries() async {
        let snapshot = await store.diagnosticSnapshot()
        XCTAssertNil(snapshot)
    }

    func testSnapshotUsesActualExpiryAndCountsTheWholeBacklogWithoutReadingAudio() async throws {
        let now = Date()
        let expiredChat = metadata(at: now.addingTimeInterval(-700))
        let publishedWork = metadata(
            at: now.addingTimeInterval(-3_600), destination: .work, publicationState: .published
        )
        let unpublishedWork = metadata(
            at: now.addingTimeInterval(-86_400 * 2), destination: .work,
            transcript: "Words already recognized", publicationState: .phaseOneFailed
        )
        for capture in [expiredChat, publishedWork, unpublishedWork] {
            try await store.save(audioData: Data("recording".utf8), metadata: capture, workImageData: nil)
        }
        await store.resetAudioReadsForTesting()

        let result = await store.diagnosticSnapshot()
        let snapshot = try XCTUnwrap(result)
        XCTAssertEqual(snapshot.totalCount, 2)
        XCTAssertEqual(snapshot.availableCount, 2)
        XCTAssertEqual(snapshot.transcriptionCount, 1)
        XCTAssertEqual(snapshot.finishSavingCount, 1)
        let reads = await store.audioReadsForTesting
        XCTAssertEqual(reads, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: audioURL(expiredChat).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: audioURL(unpublishedWork).path))
    }

    func testLiveLeaseIsProcessingUntilReleasedAndThenOriginalExpiryApplies() async throws {
        let capture = metadata()
        try await store.save(audioData: Data("recording".utf8), metadata: capture, workImageData: nil)
        let offered = await store.claim(id: capture.id)
        let claim = try XCTUnwrap(offered)
        try backdate(capture.id, to: Date().addingTimeInterval(-700))
        await store.resetAudioReadsForTesting()

        let during = await store.diagnosticSnapshot()
        XCTAssertEqual(during?.totalCount, 1)
        XCTAssertEqual(during?.processingCount, 1)
        XCTAssertEqual(during?.availableCount, 0)
        let reads = await store.audioReadsForTesting
        XCTAssertEqual(reads, 0)

        await store.release(claim)
        let after = await store.diagnosticSnapshot()
        XCTAssertNil(after, "release restores the original Chat expiry; it does not restart its clock")
    }

    func testReleaseMakesAStillValidCaptureAvailableWithoutChangingItsDeadline() async throws {
        let capture = metadata()
        try await store.save(audioData: Data("recording".utf8), metadata: capture, workImageData: nil)
        let offered = await store.claim(id: capture.id)
        let claim = try XCTUnwrap(offered)

        let before = await store.diagnosticSnapshot()
        XCTAssertEqual(before?.processingCount, 1)
        await store.release(claim)
        let after = await store.diagnosticSnapshot()
        XCTAssertEqual(after?.processingCount, 0)
        XCTAssertEqual(after?.availableCount, 1)
    }

    func testParkedPictureProtectsPublishedWorkWithoutInventingADeadline() async throws {
        let capture = metadata(
            at: Date().addingTimeInterval(-86_500), destination: .work, publicationState: .published
        )
        try await store.save(
            audioData: Data("recording".utf8), metadata: capture, workImageData: Data("picture".utf8)
        )

        let snapshot = await store.diagnosticSnapshot()
        XCTAssertEqual(snapshot?.availableCount, 1)
        XCTAssertEqual(snapshot?.expiringCount, 0)
        let reads = await store.audioReadsForTesting
        XCTAssertEqual(reads, 0)
    }

    func testARecordingFileThatWentMissingIsNotOfferedForRecovery() async throws {
        let capture = metadata(destination: .work, publicationState: .phaseOneFailed)
        try await store.save(audioData: Data("recording".utf8), metadata: capture, workImageData: nil)
        try FileManager.default.removeItem(at: audioURL(capture))

        let snapshot = await store.diagnosticSnapshot()
        XCTAssertEqual(snapshot?.totalCount, 1)
        XCTAssertEqual(snapshot?.missingAudioCount, 1)
        XCTAssertEqual(snapshot?.availableCount, 0)
    }

    func testUnreadableSidecarDefersRatherThanClaimingTheCaptureIsProcessing() async throws {
        let capture = metadata(destination: .work, publicationState: .phaseOneFailed)
        try await store.save(audioData: Data("recording".utf8), metadata: capture, workImageData: nil)
        try Data("unreadable recovery metadata".utf8).write(to: sidecarURL(capture.id), options: [.atomic])

        let snapshot = await store.diagnosticSnapshot()
        XCTAssertEqual(snapshot?.totalCount, 1)
        XCTAssertEqual(snapshot?.accessUnavailableCount, 1)
        XCTAssertEqual(snapshot?.processingCount, 0)
        XCTAssertEqual(snapshot?.availableCount, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: audioURL(capture).path))
    }

    func testUnreadableSidecarWithoutCommittedIndexStillReportsPreservedCapture() async throws {
        let capture = metadata(destination: .work, publicationState: .phaseOneFailed)
        try await store.save(audioData: Data("recording".utf8), metadata: capture, workImageData: nil)
        // The arm writes sidecar and bytes before the index. Simulate death
        // before that final commit, with metadata that cannot currently decode.
        defaults.removeObject(forKey: PendingRetryDefaultsKeys.queue)
        try Data("unreadable recovery metadata".utf8).write(to: sidecarURL(capture.id), options: [.atomic])
        await store.resetAudioReadsForTesting()

        let result = await store.diagnosticSnapshot()
        let snapshot = try XCTUnwrap(result)
        XCTAssertEqual(snapshot.totalCount, 1)
        XCTAssertEqual(snapshot.accessUnavailableCount, 1)
        XCTAssertEqual(snapshot.availableCount, 0)
        XCTAssertEqual(snapshot.processingCount, 0)
        XCTAssertEqual(snapshot.transcriptionCount, 0)
        XCTAssertEqual(snapshot.finishSavingCount, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: audioURL(capture).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sidecarURL(capture.id).path))
        XCTAssertNil(defaults.data(forKey: PendingRetryDefaultsKeys.queue),
                     "Diagnostics must not invent metadata or commit a replacement index")
        let reads = await store.audioReadsForTesting
        XCTAssertEqual(reads, 0)
    }

    func testFinishingCapturesUpdatesAndEventuallyClearsReportCounts() async throws {
        for age in [60.0, 30.0] {
            let capture = metadata(at: Date().addingTimeInterval(-age))
            try await store.save(audioData: Data("recording".utf8), metadata: capture, workImageData: nil)
        }
        let initial = await store.diagnosticSnapshot()
        XCTAssertEqual(initial?.totalCount, 2)

        let firstOffered = await store.claimNext()
        let first = try XCTUnwrap(firstOffered)
        let firstCleared = await store.clear(first)
        XCTAssertTrue(firstCleared)
        let afterFirst = await store.diagnosticSnapshot()
        XCTAssertEqual(afterFirst?.totalCount, 1)
        XCTAssertEqual(afterFirst?.availableCount, 1)

        let lastOffered = await store.claimNext()
        let last = try XCTUnwrap(lastOffered)
        let lastCleared = await store.clear(last)
        XCTAssertTrue(lastCleared)
        let afterLast = await store.diagnosticSnapshot()
        XCTAssertNil(afterLast)
    }

    private func metadata(
        at createdAt: Date = Date(),
        destination: PendingRetryDestination = .chat,
        transcript: String? = nil,
        publicationState: PendingRetryPublicationState? = nil
    ) -> PendingRetryMetadata {
        PendingRetryMetadata(
            id: UUID(), createdAt: createdAt, audioFileURL: URL(fileURLWithPath: "/dev/null"),
            preferredLanguage: nil, attemptCount: 1, lastErrorCode: nil,
            destination: destination, transcript: transcript, publicationState: publicationState
        )
    }

    private func audioURL(_ metadata: PendingRetryMetadata) -> URL {
        container.appendingPathComponent(PendingRetryFiles.audio(metadata.id, metadata.resolvedDestination))
    }

    private func sidecarURL(_ id: UUID) -> URL {
        container.appendingPathComponent(PendingRetryFiles.sidecar(id))
    }

    private func backdate(_ id: UUID, to createdAt: Date) throws {
        let sidecar = try JSONDecoder().decode(PendingRetrySidecar.self, from: Data(contentsOf: sidecarURL(id)))
        let previous = sidecar.metadata
        let aged = PendingRetryMetadata(
            id: previous.id, createdAt: createdAt, audioFileURL: previous.audioFileURL,
            preferredLanguage: previous.preferredLanguage, attemptCount: previous.attemptCount,
            lastErrorCode: previous.lastErrorCode, destination: previous.destination,
            transcript: previous.transcript, publicationState: previous.publicationState,
            workAttachedToMaterialID: previous.workAttachedToMaterialID
        )
        try JSONEncoder().encode(PendingRetrySidecar(metadata: aged, lease: sidecar.lease))
            .write(to: sidecarURL(id), options: [.atomic])
    }
}
