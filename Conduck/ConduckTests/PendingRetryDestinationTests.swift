// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import Conduck

final class PendingRetryDestinationTests: XCTestCase {
    private struct LegacyMetadata: Codable {
        let id: UUID
        let createdAt: Date
        let audioFileURL: URL
        let preferredLanguage: String?
        let attemptCount: Int
        let lastErrorCode: Int?
    }

    func testLegacySixFieldRecordDefaultsToChat() throws {
        let legacy = LegacyMetadata(
            id: UUID(),
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            audioFileURL: URL(fileURLWithPath: "/tmp/legacy.m4a"),
            preferredLanguage: "en",
            attemptCount: 1,
            lastErrorCode: nil
        )

        let decoded = try JSONDecoder().decode(
            PendingRetryMetadata.self,
            from: JSONEncoder().encode(legacy)
        )

        XCTAssertNil(decoded.destination)
        XCTAssertEqual(decoded.resolvedDestination, .chat)
    }

    func testWorkDestinationRoundTripsWithStableCaptureIdentity() throws {
        let id = UUID()
        let metadata = PendingRetryMetadata(
            id: id,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            audioFileURL: URL(fileURLWithPath: "/tmp/work.m4a"),
            preferredLanguage: nil,
            attemptCount: 1,
            lastErrorCode: 75,
            destination: .work
        )

        let decoded = try JSONDecoder().decode(
            PendingRetryMetadata.self,
            from: JSONEncoder().encode(metadata)
        )

        XCTAssertEqual(decoded.id, id)
        XCTAssertEqual(decoded.resolvedDestination, .work)
    }

    @MainActor
    func testInAppRecorderDefaultsToChatAndWorkCaptureOptsIntoWork() {
        XCTAssertEqual(InAppAudioRecorder().retryDestination, .chat)
        XCTAssertEqual(
            InAppAudioRecorder(retryDestination: .work).retryDestination,
            .work
        )
    }
}
