// SPDX-License-Identifier: Apache-2.0

// ConduckTests
// PendingRetryDiagnosticFactsTests.swift
//
// Support reports reduce the queue to anonymous counts. These deterministic
// cases preserve the real expiry, lease and publication policies while proving
// that capture content, identity and timestamps never enter the report.

import XCTest
@testable import Conduck

final class PendingRetryDiagnosticFactsTests: XCTestCase {
    private typealias Capture = PendingRetryDiagnosticSnapshot.Capture
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testChatWithinItsTenMinuteBudgetCountsAsExpiring() {
        let created = now.addingTimeInterval(-120)
        let snapshot = PendingRetryDiagnosticSnapshot(
            captures: [Capture(metadata: metadata(at: created))], now: now
        )

        XCTAssertEqual(snapshot.availableCount, 1)
        XCTAssertEqual(snapshot.transcriptionCount, 1)
        XCTAssertEqual(snapshot.expiringCount, 1)
    }

    func testPublishedWorkOlderThanTenMinutesRemainsAvailable() {
        let created = now.addingTimeInterval(-3_600)
        let snapshot = PendingRetryDiagnosticSnapshot(captures: [Capture(metadata: metadata(
            at: created, destination: .work, publicationState: .published
        ))], now: now)

        XCTAssertEqual(snapshot.availableCount, 1)
    }

    func testUnpublishedAndUnknownWorkCapturesHaveNoExpiry() {
        let created = now.addingTimeInterval(-86_400 * 30)
        let snapshot = PendingRetryDiagnosticSnapshot(captures: [
            Capture(metadata: metadata(at: created, destination: .work, publicationState: .phaseOneFailed)),
            Capture(metadata: metadata(at: created, destination: .work))
        ], now: now)

        XCTAssertEqual(snapshot.totalCount, 2)
        XCTAssertEqual(snapshot.availableCount, 2)
        XCTAssertEqual(snapshot.expiringCount, 0)
    }

    func testAnActiveLeaseIsProcessingAndExemptFromExpiry() {
        let expiredChat = metadata(at: now.addingTimeInterval(-700))
        let snapshot = PendingRetryDiagnosticSnapshot(captures: [
            Capture(metadata: expiredChat, isActivelyLeased: true)
        ], now: now)

        XCTAssertEqual(snapshot.totalCount, 1)
        XCTAssertEqual(snapshot.processingCount, 1)
        XCTAssertEqual(snapshot.availableCount, 0)

        let afterRelease = PendingRetryDiagnosticSnapshot(captures: [
            Capture(metadata: expiredChat)
        ], now: now)
        XCTAssertEqual(afterRelease.totalCount, 0, "the same expired capture is no longer protected after its lease ends")
    }

    func testParkedWorkImageProtectsAnOtherwiseExpiredPublishedCapture() {
        let snapshot = PendingRetryDiagnosticSnapshot(captures: [Capture(
            metadata: metadata(at: now.addingTimeInterval(-86_500), destination: .work, publicationState: .published),
            holdsWorkImage: true
        )], now: now)

        XCTAssertEqual(snapshot.availableCount, 1)
        XCTAssertEqual(snapshot.expiringCount, 0)
    }

    func testSavedTranscriptNeedsOnlyFinishingTheWorkWrite() {
        let snapshot = PendingRetryDiagnosticSnapshot(captures: [Capture(metadata: metadata(
            at: now, destination: .work, transcript: "Already transcribed", publicationState: .phaseOneFailed
        ))], now: now)

        XCTAssertEqual(snapshot.finishSavingCount, 1)
        XCTAssertEqual(snapshot.transcriptionCount, 0)
    }

    func testBlankWorkTranscriptStillNeedsTranscription() {
        let snapshot = PendingRetryDiagnosticSnapshot(captures: [Capture(metadata: metadata(
            at: now, destination: .work, transcript: " \n ", publicationState: .published
        ))], now: now)

        XCTAssertEqual(snapshot.transcriptionCount, 1)
        XCTAssertEqual(snapshot.finishSavingCount, 0)
    }

    func testBacklogCountsOnlyAvailableCapturesWithDeadlines() {
        let chat = metadata(at: now.addingTimeInterval(-300))
        let snapshot = PendingRetryDiagnosticSnapshot(captures: [
            Capture(metadata: metadata(at: now, destination: .work, publicationState: .published)),
            Capture(metadata: metadata(at: now, destination: .work, transcript: "Saved words")),
            Capture(metadata: chat),
            Capture(metadata: metadata(at: now.addingTimeInterval(-500)), isActivelyLeased: true)
        ], now: now)

        XCTAssertEqual(snapshot.totalCount, 4)
        XCTAssertEqual(snapshot.availableCount, 3)
        XCTAssertEqual(snapshot.processingCount, 1)
        XCTAssertEqual(snapshot.transcriptionCount, 2)
        XCTAssertEqual(snapshot.finishSavingCount, 1)
        XCTAssertEqual(snapshot.expiringCount, 2)
    }

    func testMissingAudioAndUnreadableMetadataAreNeverOfferedAsAvailable() {
        let snapshot = PendingRetryDiagnosticSnapshot(captures: [
            Capture(metadata: metadata(at: now), audioFileExists: false),
            Capture(metadata: metadata(at: now), leaseStateKnown: false)
        ], now: now)

        XCTAssertEqual(snapshot.totalCount, 2)
        XCTAssertEqual(snapshot.missingAudioCount, 1)
        XCTAssertEqual(snapshot.accessUnavailableCount, 1)
        XCTAssertEqual(snapshot.processingCount, 0, "unreadable metadata is not evidence somebody is working")
        XCTAssertEqual(snapshot.availableCount, 0)
    }

    func testReportContainsOnlyReducedQueueFacts() {
        let capture = PendingRetryMetadata(
            id: UUID(), createdAt: now,
            audioFileURL: URL(fileURLWithPath: "/private/sensitive-recording.m4a"),
            preferredLanguage: "private-language", attemptCount: 1, lastErrorCode: 12345,
            destination: .work, transcript: "private transcript https://private.example secret-token",
            publicationState: .phaseOneFailed
        )
        let snapshot = PendingRetryDiagnosticSnapshot(
            captures: [Capture(metadata: capture)], now: now
        )

        XCTAssertEqual(snapshot.reportFact, "queued(total 1, available 1, processing 0, transcription 0, finish-saving 1, missing-audio 0, unreadable 0, with-deadline 0)")
        for secret in [capture.id.uuidString, "private", "12345", "secret-token", String(now.timeIntervalSince1970)] {
            XCTAssertFalse(snapshot.reportFact.contains(secret))
        }
    }

    private func metadata(
        at createdAt: Date,
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
}
