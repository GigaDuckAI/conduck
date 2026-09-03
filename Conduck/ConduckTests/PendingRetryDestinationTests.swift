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

    // MARK: - The per-entry record beside the bytes

    /// The record's own wire shape. Its whole job is to describe a capture
    /// whose index row did not commit, so it has to carry every field the
    /// metadata does — and it is read on a launch that follows a crash, which
    /// is exactly when a decode failure costs a recording.
    func testTheRecordBesideTheBytesCarriesTheWholeMetadataAndItsReservation() throws {
        let metadata = PendingRetryMetadata(
            id: UUID(),
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            audioFileURL: URL(fileURLWithPath: "/tmp/work.m4a"),
            preferredLanguage: "et",
            attemptCount: 4,
            lastErrorCode: AppError.workDeskWriteFailed.errorCode,
            destination: .work,
            transcript: "the ferry leaves at seven",
            publicationState: .phaseOneFailed
        )
        let lease = PendingRetryLease(
            token: UUID(),
            expiresAt: Date(timeIntervalSince1970: 1_700_000_600)
        )

        let decoded = try JSONDecoder().decode(
            PendingRetrySidecar.self,
            from: JSONEncoder().encode(PendingRetrySidecar(metadata: metadata, lease: lease))
        )

        XCTAssertEqual(decoded.metadata.id, metadata.id)
        XCTAssertEqual(decoded.metadata.transcript, "the ferry leaves at seven")
        XCTAssertEqual(decoded.metadata.publicationState, .phaseOneFailed)
        XCTAssertEqual(decoded.metadata.preferredLanguage, "et")
        XCTAssertEqual(decoded.metadata.attemptCount, 4)
        XCTAssertEqual(decoded.lease?.token, lease.token)
        XCTAssertEqual(decoded.lease?.expiresAt, lease.expiresAt)
    }

    private struct UnreservedSidecar: Codable {
        let metadata: PendingRetryMetadata
    }

    /// The reservation is OPTIONAL on the wire for the same reason every other
    /// added field is: a record written before it existed, or written by a
    /// capture nobody is holding, has to decode — as "nobody holds this", which
    /// is the answer that lets the next surface take it.
    func testARecordWithNoReservationDecodesAsUnheld() throws {
        let metadata = PendingRetryMetadata(
            id: UUID(),
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            audioFileURL: URL(fileURLWithPath: "/tmp/chat.m4a"),
            preferredLanguage: nil,
            attemptCount: 1,
            lastErrorCode: nil
        )

        let decoded = try JSONDecoder().decode(
            PendingRetrySidecar.self,
            from: JSONEncoder().encode(UnreservedSidecar(metadata: metadata))
        )

        XCTAssertNil(decoded.lease)
        XCTAssertEqual(decoded.metadata.resolvedDestination, .chat)
    }

    func testAReservationIsLiveUntilItsInstantAndNotAfter() {
        let expiry = Date(timeIntervalSince1970: 1_700_000_600)
        let lease = PendingRetryLease(token: UUID(), expiresAt: expiry)

        XCTAssertTrue(lease.isLive(at: expiry.addingTimeInterval(-1)))
        XCTAssertFalse(lease.isLive(at: expiry))
        XCTAssertFalse(lease.isLive(at: expiry.addingTimeInterval(1)))
    }

    // MARK: - One capture's filenames name one capture

    func testEveryPayloadNameRoundTripsToTheCaptureItBelongsTo() {
        let id = UUID()

        XCTAssertEqual(PendingRetryFiles.sidecarID(PendingRetryFiles.sidecar(id)), id)
        XCTAssertEqual(PendingRetryFiles.tombstoneID(PendingRetryFiles.tombstone(id)), id)
        XCTAssertEqual(PendingRetryFiles.workImageID(PendingRetryFiles.workImage(id)), id)
        for destination in PendingRetryDestination.allCases {
            let parsed = PendingRetryFiles.audioID(PendingRetryFiles.audio(id, destination))
            XCTAssertEqual(parsed?.id, id)
            XCTAssertEqual(parsed?.destination, destination)
        }
        let transitional = PendingRetryFiles.audioID(PendingRetryFiles.transitionalAudio(id))
        XCTAssertEqual(transitional?.id, id)
        XCTAssertNil(
            transitional?.destination,
            "the transitional name declares none, so its capture resolves to Chat"
        )
    }

    /// The invariant behind a recording that was deleted by a capture that did
    /// not own it: the pre-id-scoped name matches NOTHING this store scans for,
    /// so no adoption, no reclamation and no per-capture deletion can reach it.
    /// Its bytes are copied under an id by the reconciliation instead.
    func testThePreIdScopedRecordingIsNamedByNoCapture() {
        let name = PendingRetryFiles.legacyAudioName

        XCTAssertNil(PendingRetryFiles.audioID(name))
        XCTAssertNil(PendingRetryFiles.sidecarID(name))
        XCTAssertNil(PendingRetryFiles.tombstoneID(name))
        XCTAssertNil(PendingRetryFiles.workImageID(name))
        XCTAssertFalse(
            PendingRetryFiles.isRetryFile(name),
            "a sweep that could reach it would delete a recording no entry can name"
        )
        XCTAssertFalse(
            PendingRetryFiles.isRetryFile(PendingRetryFiles.lockName),
            "and neither may a sweep reach the lock every process serializes on"
        )
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
