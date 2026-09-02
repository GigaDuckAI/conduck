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

    /// The shape a shipped build writes today. Every field after it is
    /// optional, so a recording parked by that build and picked up by a newer
    /// one still decodes — and decodes to the CONSERVATIVE answers: no words
    /// recovered, and no verdict about whether its recording ever reached the
    /// desk.
    private struct SevenFieldMetadata: Codable {
        let id: UUID
        let createdAt: Date
        let audioFileURL: URL
        let preferredLanguage: String?
        let attemptCount: Int
        let lastErrorCode: Int?
        let destination: PendingRetryDestination?
    }

    func testAShippedWorkRecordDecodesWithNoWordsAndNoPublicationVerdict() throws {
        let shipped = SevenFieldMetadata(
            id: UUID(),
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            audioFileURL: URL(fileURLWithPath: "/tmp/work.m4a"),
            preferredLanguage: nil,
            attemptCount: 1,
            lastErrorCode: 20,
            destination: .work
        )

        let decoded = try JSONDecoder().decode(
            PendingRetryMetadata.self,
            from: JSONEncoder().encode(shipped)
        )

        XCTAssertEqual(decoded.resolvedDestination, .work)
        XCTAssertNil(
            decoded.transcript,
            "no words were recorded, so a recovery must transcribe rather than attach nothing"
        )
        XCTAssertNil(
            decoded.publicationState,
            """
            Nil is UNKNOWN, and a recovery must not read it as either verdict: \
            republishing on an unknown would resurrect a card the person \
            deleted while recognition was in flight.
            """
        )
    }

    func testTheRecoveryFieldsSurviveTheirOwnRoundTrip() throws {
        let metadata = PendingRetryMetadata(
            id: UUID(),
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            audioFileURL: URL(fileURLWithPath: "/tmp/work.m4a"),
            preferredLanguage: nil,
            attemptCount: 1,
            lastErrorCode: AppError.workDeskWriteFailed.errorCode,
            destination: .work,
            transcript: "the ferry leaves at seven",
            publicationState: .phaseOneFailed
        )

        let decoded = try JSONDecoder().decode(
            PendingRetryMetadata.self,
            from: JSONEncoder().encode(metadata)
        )

        XCTAssertEqual(decoded.transcript, "the ferry leaves at seven")
        XCTAssertEqual(decoded.publicationState, .phaseOneFailed)
    }

    /// The extension is read off the BYTES. Both lanes park compressed audio
    /// and compression can return WAV, so a fixed `.m4a` name tells a stricter
    /// provider something untrue about its own input.
    func testTheParkedFileIsNamedAfterTheContainerTheBytesActuallyAre() {
        let wav = Data("RIFF".utf8) + Data([0, 0, 0, 0]) + Data("WAVE".utf8)
        let m4a = Data([0, 0, 0, 0x18]) + Data("ftypM4A ".utf8)

        XCTAssertEqual(PendingRetryAudioFile.extension(for: wav), "wav")
        XCTAssertEqual(PendingRetryAudioFile.extension(for: m4a), "m4a")
        XCTAssertEqual(
            PendingRetryAudioFile.extension(for: Data(repeating: 0x7F, count: 16)), "m4a",
            "unrecognised bytes keep the recorders' native container rather than guessing"
        )
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
