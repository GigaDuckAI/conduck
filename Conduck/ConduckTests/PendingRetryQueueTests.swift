// SPDX-License-Identifier: Apache-2.0

// ConduckTests
// PendingRetryQueueTests.swift
//
// The rules of the pending-retry QUEUE, driven directly rather than through the
// actor that owns the file.
//
// Everything that can destroy an irreplaceable recording lives here: an upsert
// that replaces the wrong entry, an expiry sweep that reaches a capture whose
// bytes are the only copy of what somebody said, a migration that reads the
// older release's single-slot pointer and drops it, a metadata write that
// touches a capture it was not asked about. None of that is reachable by a test
// that has to go through an App-Group container and a process-global
// `UserDefaults` domain first — and a test that did would be writing to the one
// slot every other capture test in this bundle shares.
//
// The honest limit, stated rather than implied: what is NOT covered here is the
// actor's file I/O and its advisory cross-process lock. `PendingRetryStore` is
// a thin shell over these functions; the shell is exercised by the recorder's
// injected lane in `WorkVoiceRecoveryTests` and, on a signed device, by the
// founder-QA items this round adds.

import XCTest
@testable import Conduck

final class PendingRetryQueueTests: XCTestCase {

    // MARK: - Arming displaces nothing

    /// The defect the queue exists for: on a single overwriting slot the second
    /// capture's arrival deleted the first capture's recording, and no policy
    /// about WHICH one to keep can be right — both recordings exist nowhere
    /// else.
    func testASecondCaptureIsAddedRatherThanReplacingTheFirst() {
        let first = Self.metadata(destination: .chat)
        let second = Self.metadata(destination: .work, publicationState: .phaseOneFailed)

        let queue = PendingRetryQueue.upserting(second, into: [first])

        XCTAssertEqual(
            Set(queue.map(\.id)), [first.id, second.id],
            "both captures are waiting; neither recording was spent to hold the other's words"
        )
    }

    /// The same capture arming again — a second failure on one recording — is a
    /// restatement, not a second entry.
    func testRearmingOneCaptureRestatesItsEntryInPlace() {
        let capture = Self.metadata(destination: .work, publicationState: .phaseOneFailed)
        let other = Self.metadata(destination: .chat)
        let restated = capture.recordingAttempt(lastErrorCode: 42)

        let queue = PendingRetryQueue.upserting(restated, into: [other, capture])

        XCTAssertEqual(queue.count, 2)
        XCTAssertEqual(queue.first { $0.id == capture.id }?.attemptCount, 2)
        XCTAssertEqual(queue.first { $0.id == capture.id }?.lastErrorCode, 42)
        XCTAssertEqual(
            queue.first { $0.id == other.id }?.attemptCount, other.attemptCount,
            "the capture nobody asked about is byte-identical afterwards"
        )
    }

    func testTheQueueIsOfferedNewestFirst() {
        let old = Self.metadata(at: Date(timeIntervalSince1970: 1_000))
        let newer = Self.metadata(at: Date(timeIntervalSince1970: 2_000))
        let newest = Self.metadata(at: Date(timeIntervalSince1970: 3_000))

        XCTAssertEqual(
            PendingRetryQueue.ordered([old, newest, newer]).map(\.id),
            [newest.id, newer.id, old.id],
            "a person watching the retry card is waiting on the capture they just made"
        )
    }

    // MARK: - Clearing reaches exactly one capture

    func testClearingOneCaptureLeavesEveryOtherQueued() {
        let a = Self.metadata()
        let b = Self.metadata()
        let c = Self.metadata()

        let split = PendingRetryQueue.removing(id: b.id, from: [a, b, c])

        XCTAssertEqual(split.removed?.id, b.id)
        XCTAssertEqual(Set(split.kept.map(\.id)), [a.id, c.id])
    }

    func testClearingACaptureThatIsNotQueuedRemovesNothing() {
        let a = Self.metadata()

        let split = PendingRetryQueue.removing(id: UUID(), from: [a])

        XCTAssertNil(split.removed, "a caller that finished elsewhere must not be told it removed one")
        XCTAssertEqual(split.kept.map(\.id), [a.id])
    }

    // MARK: - Expiry is a budget for a transcription, not for a recording

    /// The finding, exactly: ten minutes retired a `.phaseOneFailed` Work
    /// capture and deleted the audio — and for that state those bytes are the
    /// ONLY recording of what was said.
    func testAPublicationTheDeskRefusedNeverExpires() {
        let armed = Date(timeIntervalSince1970: 1_700_000_000)
        let capture = Self.metadata(
            at: armed, destination: .work, publicationState: .phaseOneFailed
        )

        XCTAssertFalse(capture.isExpired(at: armed.addingTimeInterval(601)))
        XCTAssertFalse(
            capture.isExpired(at: armed.addingTimeInterval(86_400 * 30)),
            """
            A clock is not a reason to delete the only copy of a recording. This \
            entry leaves when publication succeeds or the person discards it, \
            and at no other moment.
            """
        )
        XCTAssertTrue(capture.isExemptFromExpiry)
    }

    /// The UNKNOWN verdict an older record carries takes the same protection:
    /// nil cannot be read as "the desk has it".
    func testAWorkCaptureWithNoVerdictIsTreatedAsIrreplaceable() {
        let armed = Date(timeIntervalSince1970: 1_700_000_000)
        let capture = Self.metadata(at: armed, destination: .work, publicationState: nil)

        XCTAssertTrue(capture.isExemptFromExpiry)
        XCTAssertFalse(capture.isExpired(at: armed.addingTimeInterval(601)))
    }

    /// …and the records the TTL is actually about keep it. A Chat capture's
    /// words can be bought again, and a `.published` Work capture's recording is
    /// already a card on the desk.
    func testChatAndPublishedWorkCapturesStillExpireOnTheTenMinuteBudget() {
        let armed = Date(timeIntervalSince1970: 1_700_000_000)
        let chat = Self.metadata(at: armed, destination: .chat)
        let published = Self.metadata(
            at: armed, destination: .work, publicationState: .published
        )

        for capture in [chat, published] {
            XCTAssertFalse(capture.isExemptFromExpiry)
            XCTAssertFalse(capture.isExpired(at: armed.addingTimeInterval(599)))
            XCTAssertTrue(capture.isExpired(at: armed.addingTimeInterval(601)))
        }
        XCTAssertEqual(PendingRetryMetadata.transcriptionRetryTTL, 600)
    }

    /// A sweep splits the queue rather than emptying it: the capture the clock
    /// may retire goes, and the one beside it stays.
    func testTheExpirySweepReachesOnlyTheCapturesTheClockGoverns() {
        let armed = Date(timeIntervalSince1970: 1_700_000_000)
        let stale = Self.metadata(at: armed, destination: .chat)
        let irreplaceable = Self.metadata(
            at: armed, destination: .work, publicationState: .phaseOneFailed
        )

        let split = PendingRetryQueue.partitioningExpired(
            [stale, irreplaceable], at: armed.addingTimeInterval(3_600)
        )

        XCTAssertEqual(split.expired.map(\.id), [stale.id])
        XCTAssertEqual(split.kept.map(\.id), [irreplaceable.id])
    }

    // MARK: - A metadata write reaches one capture and rewrites nothing else

    /// The race the whole-slot re-commit lost: a capture armed between another
    /// capture's ownership check and its save was overwritten and its audio
    /// deleted. Restating one entry cannot express that — the other entries are
    /// carried through untouched, and there is no payload in the operation at
    /// all.
    func testRecordingOneCapturesVerdictLeavesEveryOtherEntryIdentical() throws {
        let subject = Self.metadata(destination: .work, publicationState: nil)
        let armedInBetween = Self.metadata(destination: .work, publicationState: .phaseOneFailed)

        let updated = try XCTUnwrap(
            PendingRetryQueue.updating(id: subject.id, in: [subject, armedInBetween]) {
                $0.recording(transcript: "the ferry leaves at seven", publicationState: .published)
            }
        )

        XCTAssertEqual(updated.count, 2)
        let written = try XCTUnwrap(updated.first { $0.id == subject.id })
        XCTAssertEqual(written.transcript, "the ferry leaves at seven")
        XCTAssertEqual(written.publicationState, .published)
        let bystander = try XCTUnwrap(updated.first { $0.id == armedInBetween.id })
        XCTAssertEqual(bystander.publicationState, .phaseOneFailed)
        XCTAssertNil(bystander.transcript)
        XCTAssertEqual(bystander.createdAt, armedInBetween.createdAt)
        XCTAssertEqual(bystander.attemptCount, armedInBetween.attemptCount)
    }

    func testRecordingAVerdictForACaptureThatIsGoneCreatesNothing() {
        XCTAssertNil(
            PendingRetryQueue.updating(id: UUID(), in: [Self.metadata()]) {
                $0.recording(transcript: nil, publicationState: .published)
            },
            """
            A verdict about a capture that has already been finished or \
            discarded must not bring it back — the audio it named is gone.
            """
        )
    }

    /// A caller that knows one of the two facts must not erase the other.
    func testANilFieldKeepsWhatTheRecordAlreadyCarries() {
        let capture = Self.metadata(destination: .work, publicationState: .phaseOneFailed)
            .recording(transcript: "already recognised", publicationState: nil)

        let verdictOnly = capture.recording(transcript: nil, publicationState: .published)
        XCTAssertEqual(verdictOnly.transcript, "already recognised")
        XCTAssertEqual(verdictOnly.publicationState, .published)

        let wordsOnly = capture.recording(transcript: "corrected", publicationState: nil)
        XCTAssertEqual(wordsOnly.publicationState, .phaseOneFailed)
        XCTAssertEqual(wordsOnly.transcript, "corrected")
    }

    // MARK: - The single slot an older release wrote

    /// A device that upgrades mid-capture has exactly one parked recording and
    /// the old pointer is its only description. It is READ and folded in.
    func testTheLegacySingleSlotBecomesTheFirstQueueEntry() throws {
        let parked = Self.metadata(destination: .work, publicationState: .phaseOneFailed)

        let decoded = PendingRetryQueue.decoding(
            queue: nil,
            legacy: try JSONEncoder().encode(parked)
        )

        XCTAssertTrue(decoded.migratedLegacy)
        XCTAssertEqual(decoded.entries.map(\.id), [parked.id])
        let migrated = try XCTUnwrap(decoded.entries.first)
        XCTAssertEqual(migrated.publicationState, .phaseOneFailed)
        XCTAssertEqual(migrated.createdAt, parked.createdAt)
        XCTAssertEqual(migrated.resolvedDestination, .work)
    }

    /// The pointer and a queue can both exist — a launch that migrated but
    /// could not commit the removal. Folding it in twice must not duplicate the
    /// capture.
    func testAMigrationThatRunsTwiceAddsNothing() throws {
        let parked = Self.metadata(destination: .chat)
        let alreadyQueued = try JSONEncoder().encode([parked])

        let decoded = PendingRetryQueue.decoding(
            queue: alreadyQueued,
            legacy: try JSONEncoder().encode(parked)
        )

        XCTAssertEqual(decoded.entries.map(\.id), [parked.id])
        XCTAssertTrue(decoded.migratedLegacy, "the pointer is still there to be retired")
    }

    /// A pointer describing a DIFFERENT capture from the queued ones is a
    /// second recording, and it survives.
    func testALegacySlotNamingAnUnqueuedCaptureIsKeptBesideTheQueue() throws {
        let queued = Self.metadata(at: Date(timeIntervalSince1970: 2_000))
        let parked = Self.metadata(at: Date(timeIntervalSince1970: 1_000))

        let decoded = PendingRetryQueue.decoding(
            queue: try JSONEncoder().encode([queued]),
            legacy: try JSONEncoder().encode(parked)
        )

        XCTAssertEqual(decoded.entries.map(\.id), [queued.id, parked.id], "newest first")
    }

    func testNoQueueAndNoLegacyPointerIsSimplyEmpty() {
        let decoded = PendingRetryQueue.decoding(queue: nil, legacy: nil)

        XCTAssertTrue(decoded.entries.isEmpty)
        XCTAssertFalse(decoded.migratedLegacy)
    }

    /// Unreadable bytes under either key are not a reason to claim there is
    /// nothing parked — the audio files are still on disk and the store adopts
    /// them back.
    func testUndecodableStateReadsAsAnEmptyQueueRatherThanThrowing() {
        let decoded = PendingRetryQueue.decoding(
            queue: Data("not json".utf8),
            legacy: Data("not json either".utf8)
        )

        XCTAssertTrue(decoded.entries.isEmpty)
        XCTAssertFalse(decoded.migratedLegacy, "there is no pointer to retire, so none is claimed")
    }

    // MARK: - Fixtures

    private static func metadata(
        at createdAt: Date = Date(timeIntervalSince1970: 1_700_000_000),
        destination: PendingRetryDestination = .chat,
        publicationState: PendingRetryPublicationState? = nil
    ) -> PendingRetryMetadata {
        PendingRetryMetadata(
            id: UUID(),
            createdAt: createdAt,
            audioFileURL: URL(fileURLWithPath: "/dev/null"),
            preferredLanguage: nil,
            attemptCount: 1,
            lastErrorCode: nil,
            destination: destination,
            transcript: nil,
            publicationState: publicationState
        )
    }
}
