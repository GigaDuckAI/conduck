// SPDX-License-Identifier: Apache-2.0

// ConduckTests
// PendingRetryStoreNoRegressTests.swift
//
// The three promises the queue makes to a capture whose recording is the only
// copy of what somebody said, held against the real store over an isolated
// container.
//
// A SAVE NEVER WALKS AN ENTRY BACKWARDS. Re-parking an id already queued is not
// always the newest thing that happened to that capture: a wrist re-fires when
// the phone's reply is lost, minutes after the phone finished, and an in-app
// recorder's preserve can run after another surface took the capture over.
// Either would otherwise erase words the provider was already paid for, or
// downgrade a verdict that says the desk holds this capture.
//
// THE RECORDING LEAVES WHEN THE WORDS LAND, and the entry does not always leave
// with it: a capture that still owes a screenshot keeps the entry sheltering
// the only copy of that picture. `retireRecording` is the narrow write that
// says so — the audio alone, and a `.published` stamp — and what is left must
// survive every sweep that reads "no recording" as "nothing worth keeping".
//
// A COUNT IS NOT A QUEUE DEPTH. `waitingCount()` answers what a person is
// waiting on, so it skips the captures whose own lane is holding them; an
// ordinary successful recording would otherwise flash a retry row through every
// capture somebody makes.
//
// The fourth section is the wire: `sourceDevice` is optional on it, so a record
// written by the other build decodes rather than stranding a parked recording
// mid-upgrade.

import XCTest
@testable import Conduck

final class PendingRetryStoreNoRegressTests: XCTestCase {

    private var container: URL!
    private var defaults: InMemoryDefaultsStore!
    private var queue: PendingRetryStore!

    override func setUp() {
        super.setUp()
        container = FileManager.default.temporaryDirectory
            .appendingPathComponent("pending-retry-no-regress-\(UUID().uuidString)", isDirectory: true)
        defaults = InMemoryDefaultsStore()
        queue = PendingRetryStore(containerURL: container, defaults: defaults)
    }

    override func tearDown() {
        if let container { try? FileManager.default.removeItem(at: container) }
        queue = nil
        defaults = nil
        container = nil
        super.tearDown()
    }

    // MARK: - A save never regresses the entry it restates

    /// The wrist re-fire. The phone finished the capture and its reply was lost,
    /// so the watch sends the same clip again; the phone re-parks it with the
    /// nothing it knows. The entry keeps the words it already bought.
    func testARePARKKeepsWordsTheEntryAlreadyCarries() async throws {
        let captureID = UUID()
        try await queue.save(
            audioData: Self.recordingBytes,
            metadata: Self.metadata(
                id: captureID,
                transcript: "the ferry leaves at seven",
                publicationState: .phaseOneFailed
            )
        )

        try await queue.save(
            audioData: Self.recordingBytes,
            metadata: Self.metadata(id: captureID, transcript: nil, publicationState: .phaseOneFailed)
        )

        let queued = try XCTUnwrap(sidecarRecord(captureID))
        XCTAssertEqual(
            queued.transcript, "the ferry leaves at seven",
            """
            MEASURED: words the provider was already paid for. Erased here, the next retry buys \
            the identical answer a second time — and a device with no key never gets it at all.
            """
        )
    }

    /// The stale in-app preserve. Another surface took the capture over and
    /// published it; this recorder's own preserve then lands with an older
    /// verdict. A `.published` entry must not become exempt from every clock
    /// again.
    func testARePARKNeverDowngradesAPublishedVerdict() async throws {
        let captureID = UUID()
        try await queue.save(
            audioData: Self.recordingBytes,
            metadata: Self.metadata(id: captureID, publicationState: .published)
        )

        try await queue.save(
            audioData: Self.recordingBytes,
            metadata: Self.metadata(id: captureID, publicationState: .phaseOneFailed)
        )

        let queued = try XCTUnwrap(sidecarRecord(captureID))
        XCTAssertEqual(queued.publicationState, .published)
        XCTAssertFalse(
            queued.isExemptFromExpiry,
            "a downgrade here makes an entry the desk already holds immortal"
        )
    }

    /// The upgrade still travels. Only the two facts that can be LOST are
    /// pinned; everything a newer observation knows is written.
    func testARePARKStillRecordsAVerdictTheEntryDidNotHave() async throws {
        let captureID = UUID()
        try await queue.save(
            audioData: Self.recordingBytes,
            metadata: Self.metadata(id: captureID, publicationState: .phaseOneFailed)
        )

        try await queue.save(
            audioData: Self.recordingBytes,
            metadata: Self.metadata(
                id: captureID, transcript: "said later", publicationState: .published
            )
        )

        let queued = try XCTUnwrap(sidecarRecord(captureID))
        XCTAssertEqual(queued.publicationState, .published)
        XCTAssertEqual(queued.transcript, "said later")
    }

    func testAFreshCaptureIsNotAffectedByTheNoRegressRule() async throws {
        let captureID = UUID()

        try await queue.save(
            audioData: Self.recordingBytes,
            metadata: Self.metadata(id: captureID, publicationState: .phaseOneFailed)
        )

        let queued = try XCTUnwrap(sidecarRecord(captureID))
        XCTAssertEqual(queued.publicationState, .phaseOneFailed)
        XCTAssertNil(queued.transcript)
    }

    // MARK: - Retiring the recording alone

    func testRetiringTheRecordingKeepsTheEntryItsVerdictAndItsPicture() async throws {
        let captureID = UUID()
        try await queue.save(
            audioData: Self.recordingBytes,
            metadata: Self.metadata(
                id: captureID, transcript: "the ferry leaves at seven",
                publicationState: .phaseOneFailed
            ),
            workImageData: Self.pictureBytes
        )
        let claimed = await queue.claimNext(surface: .work)
        let claim = try XCTUnwrap(claimed)

        let retired = await queue.retireRecording(claim)

        XCTAssertTrue(retired)
        XCTAssertFalse(audioExists(captureID), "the recording is waste the moment the words land")
        XCTAssertEqual(
            parkedPicture(captureID), Self.pictureBytes,
            """
            MEASURED: the picture stays, byte for byte. The entry is the only thing sheltering \
            it, so clearing the whole entry to be rid of the audio takes the screenshot with it.
            """
        )
        let record = try XCTUnwrap(sidecarRecord(captureID), "the durable record survives too")
        XCTAssertEqual(record.publicationState, .published)
        XCTAssertEqual(
            record.transcript, "the ferry leaves at seven",
            "the words are not touched by a payload retirement"
        )
        XCTAssertTrue(indexedIDs().contains(captureID), "and so does its index row")
    }

    /// The sweep that would undo it, and the offer that finishes it.
    ///
    /// Every path that reaps a capture reads "no recording" as "finished", and
    /// finishing this entry deletes the picture it is sheltering. But an entry
    /// no surface can TAKE is one no surface can finish either: after a process
    /// death nothing would ever publish that picture, and the expiry clock
    /// deliberately will not take it. So it is offered — with empty bytes and
    /// the words already parked on it, which is exactly what its remaining debt
    /// needs and is no reason to buy a transcription.
    func testAnEntryWhosePictureIsStillOwedIsOfferedWithNoBytesAndSurvivesTheSweep() async throws {
        let captureID = UUID()
        try await queue.save(
            audioData: Self.recordingBytes,
            metadata: Self.metadata(
                id: captureID, transcript: "said once", publicationState: .phaseOneFailed
            ),
            workImageData: Self.pictureBytes
        )
        let claimed = await queue.claimNext(surface: .work)
        let claim = try XCTUnwrap(claimed)
        _ = await queue.retireRecording(claim)
        await queue.release(claim)

        let offered = await queue.claimNext(surface: .work)

        let second = try XCTUnwrap(
            offered,
            """
            MEASURED: the entry is unclaimable. Its picture is the only copy of itself, nothing \
            else reaps a parked picture, and the clock will not take an entry that shelters one \
            — so a capture nobody can claim is a screenshot stranded on the device for ever.
            """
        )
        XCTAssertEqual(second.id, captureID)
        XCTAssertEqual(
            second.entry.audioData, Data(),
            "there is nothing to transcribe, and the claim says so rather than inventing bytes"
        )
        XCTAssertEqual(
            second.entry.metadata.transcript, "said once",
            """
            …and the words come with it, so the surface that takes this entry publishes the \
            picture and finds the card already standing instead of paying a provider again.
            """
        )
        XCTAssertEqual(second.entry.workImageData, Self.pictureBytes, "with the bytes it owes")
        XCTAssertEqual(second.entry.metadata.publicationState, .published)
        XCTAssertTrue(
            indexedIDs().contains(captureID),
            """
            MEASURED: the entry is still there. Reaped as an ordinary recording-less capture, \
            the only copy of the picture goes with it.
            """
        )
        XCTAssertNotNil(sidecarRecord(captureID))
        XCTAssertEqual(parkedPicture(captureID), Self.pictureBytes)

        // …and taking it is what ENDS it: the picture published, the entry
        // cleared, and the container empty of both.
        let finished = await queue.clear(second)
        XCTAssertTrue(finished)
        XCTAssertFalse(indexedIDs().contains(captureID))
        XCTAssertNil(parkedPicture(captureID))
    }

    /// The same entry, addressed by id rather than selected — the way the
    /// surface that armed it asks — and read by the queue-wide load. All three
    /// readers answer alike, or the entry is finishable from one surface and
    /// invisible from the next.
    func testTheRecordinglessEntryIsAddressableAndLoadableToo() async throws {
        let captureID = UUID()
        try await queue.save(
            audioData: Self.recordingBytes,
            metadata: Self.metadata(
                id: captureID, transcript: "said once", publicationState: .phaseOneFailed
            ),
            workImageData: Self.pictureBytes
        )
        let firstClaim = await queue.claimNext(surface: .work)
        let first = try XCTUnwrap(firstClaim)
        _ = await queue.retireRecording(first)
        await queue.release(first)

        let loaded = await queue.load()
        XCTAssertEqual(
            loaded.map(\.metadata.id), [captureID],
            "the queue-wide read must not drop an entry the claim API offers"
        )
        XCTAssertEqual(loaded.first?.audioData, Data())
        XCTAssertEqual(loaded.first?.workImageData, Self.pictureBytes)

        let addressed = await queue.claim(id: captureID, duration: 60)
        let byID = try XCTUnwrap(
            addressed,
            """
            The lane that armed this capture addresses it by id and never selects. Refused \
            there, the surface holding the picture's own retry can never settle it.
            """
        )
        XCTAssertEqual(byID.entry.audioData, Data())
        await queue.release(byID)

        let reserved = await queue.reserve(id: captureID, duration: 60)
        guard case .claimed(let reservation) = reserved else {
            return XCTFail("the three-way answer must be `claimed`, not `absent`: \(reserved)")
        }
        XCTAssertEqual(reservation.entry.metadata.transcript, "said once")
    }

    /// The narrow opposite: an entry with no recording and no picture is residue
    /// a retry can never finish, and is finished by the sweep as it always was.
    func testAnEntryWithNothingLeftIsStillReaped() async throws {
        let captureID = UUID()
        try await queue.save(
            audioData: Self.recordingBytes,
            metadata: Self.metadata(id: captureID, publicationState: .phaseOneFailed)
        )
        let claimed = await queue.claimNext(surface: .work)
        let claim = try XCTUnwrap(claimed)
        _ = await queue.retireRecording(claim)
        await queue.release(claim)

        _ = await queue.claimNext(surface: .work)

        XCTAssertFalse(
            indexedIDs().contains(captureID),
            "NEGATIVE CONTROL: nothing is sheltered here, so the exemption does not apply"
        )
        XCTAssertNil(sidecarRecord(captureID))
    }

    func testRetiringIsRefusedForASurfaceThatNoLongerHoldsTheCapture() async throws {
        let captureID = UUID()
        try await queue.save(
            audioData: Self.recordingBytes,
            metadata: Self.metadata(id: captureID, publicationState: .phaseOneFailed)
        )
        let claimed = await queue.claimNext(surface: .work)
        let claim = try XCTUnwrap(claimed)
        await queue.release(claim)
        let retaken = await queue.claimNext(surface: .work)
        let overtaken = try XCTUnwrap(retaken)
        XCTAssertNotEqual(overtaken.token, claim.token, "the fixture must actually hand over")

        let retired = await queue.retireRecording(claim)

        XCTAssertFalse(retired, "a capture another surface took over is that surface's to finish")
        XCTAssertTrue(audioExists(captureID), "…and its recording is not this surface's to delete")
    }

    // MARK: - What a person is waiting on

    func testWaitingCountSkipsACaptureItsOwnLaneIsHolding() async throws {
        try await queue.save(
            audioData: Self.recordingBytes,
            metadata: Self.metadata(id: UUID(), publicationState: .phaseOneFailed)
        )
        let claimed = await queue.claimNext(surface: .work)
        let claim = try XCTUnwrap(claimed)

        let waiting = await queue.waitingCount()
        let pending = await queue.pendingCount()

        XCTAssertEqual(
            waiting, 0,
            """
            MEASURED: nothing is waiting for a person while its own lane is transcribing it. \
            On `pendingCount()` the retry row flashes through every successful recording.
            """
        )
        XCTAssertEqual(pending, 1, "the capture IS queued; the two questions are different")
        let hasWaitingWhileHeld = await queue.hasWaiting()
        XCTAssertFalse(hasWaitingWhileHeld)
        await queue.release(claim)
        let afterHandBack = await queue.waitingCount()
        XCTAssertEqual(
            afterHandBack, 1,
            "a lane that gives the capture back has made it somebody's to finish again"
        )
        let hasWaitingAfterHandBack = await queue.hasWaiting()
        XCTAssertTrue(hasWaitingAfterHandBack)
    }

    func testWaitingCountReturnsEveryCaptureNobodyIsHolding() async throws {
        for _ in 0..<3 {
            try await queue.save(
                audioData: Self.recordingBytes,
                metadata: Self.metadata(id: UUID(), publicationState: .phaseOneFailed)
            )
        }
        let held = await queue.claimNext(surface: .work)
        XCTAssertNotNil(held, "the fixture must actually reserve one")

        let waiting = await queue.waitingCount()

        XCTAssertEqual(waiting, 2, "one is held; the two behind it are waiting")
    }

    // MARK: - The wire

    /// The shape a shipped build writes: every field this one added is absent,
    /// and a record parked by that build must decode rather than strand a
    /// recording on a device mid-upgrade.
    private struct RecordWithoutSourceDevice: Codable {
        let id: UUID
        let createdAt: Date
        let audioFileURL: URL
        let preferredLanguage: String?
        let attemptCount: Int
        let lastErrorCode: Int?
        let destination: PendingRetryDestination?
        let transcript: String?
        let publicationState: PendingRetryPublicationState?
        let workAttachedToMaterialID: UUID?
    }

    func testARecordWithNoSourceDeviceDecodesAsTheCurrentDevice() throws {
        let parked = RecordWithoutSourceDevice(
            id: UUID(),
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            audioFileURL: URL(fileURLWithPath: "/tmp/work.m4a"),
            preferredLanguage: nil,
            attemptCount: 1,
            lastErrorCode: 20,
            destination: .work,
            transcript: nil,
            publicationState: .phaseOneFailed,
            workAttachedToMaterialID: nil
        )

        let decoded = try JSONDecoder().decode(
            PendingRetryMetadata.self,
            from: JSONEncoder().encode(parked)
        )

        XCTAssertNil(
            decoded.sourceDevice,
            "nil is the current device, which is the truthful answer for a record that names none"
        )
        XCTAssertEqual(decoded.resolvedDestination, .work)
    }

    func testASourceDeviceSurvivesTheRoundTripAndEveryRestatement() throws {
        let original = Self.metadata(id: UUID(), publicationState: .phaseOneFailed, sourceDevice: "watch")

        let decoded = try JSONDecoder().decode(
            PendingRetryMetadata.self,
            from: JSONEncoder().encode(original)
        )

        XCTAssertEqual(decoded.sourceDevice, "watch")
        XCTAssertEqual(
            decoded.recording(transcript: "said on the wrist", publicationState: .published)
                .sourceDevice,
            "watch",
            "a process that observed a PUBLICATION learns nothing about where the words were said"
        )
        XCTAssertEqual(
            decoded.recordingAttempt(lastErrorCode: 20).sourceDevice, "watch",
            "…and neither does one that counted an attempt"
        )
    }

    func testASourceDeviceSurvivesAParkAndAClaim() async throws {
        let captureID = UUID()
        try await queue.save(
            audioData: Self.recordingBytes,
            metadata: Self.metadata(
                id: captureID, publicationState: .phaseOneFailed, sourceDevice: "carplay"
            )
        )

        let claimed = await queue.claimNext(surface: .work)
        let claim = try XCTUnwrap(claimed)

        XCTAssertEqual(claim.entry.metadata.sourceDevice, "carplay")
    }

    // MARK: - Fixtures

    private static let recordingBytes = Data(repeating: 0x7F, count: 4_096)
    private static let pictureBytes = Data(repeating: 0x2A, count: 512)

    private static func metadata(
        id: UUID,
        transcript: String? = nil,
        publicationState: PendingRetryPublicationState?,
        sourceDevice: String? = nil
    ) -> PendingRetryMetadata {
        PendingRetryMetadata(
            id: id,
            // Armed NOW: a `.published` verdict makes a Work capture expirable
            // again, and an entry armed in 2023 is swept before it can be read
            // back.
            createdAt: Date(),
            audioFileURL: URL(fileURLWithPath: "/dev/null"),
            preferredLanguage: nil,
            attemptCount: 1,
            lastErrorCode: AppError.workDeskWriteFailed.errorCode,
            destination: .work,
            transcript: transcript,
            publicationState: publicationState,
            workAttachedToMaterialID: nil,
            sourceDevice: sourceDevice
        )
    }

    /// The DURABLE record of one capture, read straight off the sidecar the
    /// store writes first. It is the authority over the index row, and reading
    /// it directly asserts what a crash would leave rather than what a
    /// reconciliation would rebuild.
    private func sidecarRecord(_ id: UUID) -> PendingRetryMetadata? {
        let url = container.appendingPathComponent(PendingRetryFiles.sidecar(id))
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? JSONDecoder().decode(PendingRetrySidecar.self, from: data))?.metadata
    }

    /// The captures the INDEX row names, which is what a surface counting the
    /// queue reads.
    private func indexedIDs() -> Set<UUID> {
        guard let data = defaults.data(forKey: PendingRetryDefaultsKeys.queue),
              let rows = try? JSONDecoder().decode([PendingRetryMetadata].self, from: data)
        else { return [] }
        return Set(rows.map(\.id))
    }

    private func audioExists(_ id: UUID) -> Bool {
        FileManager.default.fileExists(
            atPath: container.appendingPathComponent(
                PendingRetryFiles.audio(id, .work)
            ).path
        )
    }

    private func parkedPicture(_ id: UUID) -> Data? {
        try? Data(
            contentsOf: container.appendingPathComponent(PendingRetryFiles.workImage(id))
        )
    }
}
