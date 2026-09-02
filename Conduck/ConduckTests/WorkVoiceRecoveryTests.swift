// SPDX-License-Identifier: Apache-2.0

// ConduckTests
// WorkVoiceRecoveryTests.swift
//
// What happens to a Work voice capture that was parked and picked up again —
// in another process, hours later, by a surface that cannot see what the
// capture saw.
//
// The whole difficulty is that ONE observation has two opposite causes: an id
// that names no card is either a publication the desk refused, in which case
// the parked bytes are the only copy of the recording and belong back on the
// desk, or a card a person deleted while recognition was in flight, in which
// case bringing it back resurrects what they threw away. Only the retry
// record's own publication verdict separates them, so these cases drive
// `recover` across all three verdicts — known-published, known-failed, and the
// legacy unknown — against a card that is standing, missing, or not a recording
// at all.
//
// The second half is the single retry slot's LIFETIME, asserted through the
// recorder that owns it: a finished capture releases its claim, a replaced one
// releases it only once the replacement microphone is actually live, and a
// capture whose recording is already safe on the desk never evicts a record
// holding the only copy of somebody else's.

import XCTest
@testable import Conduck

final class WorkVoiceRecoveryTests: XCTestCase {

    // MARK: - recover: a recording that is standing

    func testAKnownPublishedRecordingTakesTheRecoveredWords() async throws {
        let store = ConversationStore(inMemory: true)
        let captureID = UUID()
        _ = try await Self.publish(captureID: captureID, in: store)

        let outcome = try await WorkVoiceCaptureCoordinator.recover(
            Self.record(id: captureID, publicationState: .published),
            transcript: "  the ferry leaves at seven  ",
            store: store
        )

        XCTAssertEqual(outcome, .attached)
        XCTAssertTrue(outcome.isTerminal, "the words are on the desk; the record may be released")
        let deskValue = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        let desk = try XCTUnwrap(deskValue)
        XCTAssertEqual(desk.materials.count, 1, "a recovery never puts the same utterance up twice")
        let card = try XCTUnwrap(desk.materials.first)
        XCTAssertEqual(card.id, captureID)
        XCTAssertEqual(card.kind, .audio, "a recovered capture is still a recording")
        XCTAssertEqual(card.textContent, "the ferry leaves at seven")
        let payload = try await store.loadWorkMaterialPayload(id: captureID)
        XCTAssertEqual(payload, Self.recordingBytes, "the bytes are untouched by a text edit")
    }

    func testALegacyRecordWhosePublicationIsUnknownStillAttachesToAStandingRecording() async throws {
        let store = ConversationStore(inMemory: true)
        let captureID = UUID()
        _ = try await Self.publish(captureID: captureID, in: store)

        let outcome = try await WorkVoiceCaptureCoordinator.recover(
            Self.record(id: captureID, publicationState: nil),
            transcript: "recovered from a record that predates the verdict",
            store: store
        )

        XCTAssertEqual(
            outcome, .attached,
            """
            An unknown verdict is only a reason to be careful about ABSENCE. \
            A card that is standing takes its words like any other.
            """
        )
        let deskValue = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        let desk = try XCTUnwrap(deskValue)
        XCTAssertEqual(desk.materials.count, 1)
        XCTAssertEqual(
            desk.materials.first?.textContent,
            "recovered from a record that predates the verdict"
        )
    }

    // MARK: - recover: a recording that is not there

    func testAKnownPublishedRecordingThatIsGoneIsADeletionAndIsNotResurrected() async throws {
        let store = ConversationStore(inMemory: true)
        let captureID = UUID()

        let outcome = try await WorkVoiceCaptureCoordinator.recover(
            Self.record(id: captureID, publicationState: .published),
            transcript: "the words outlive the card",
            store: store
        )

        XCTAssertEqual(outcome, .fallbackNotePublished)
        let deskValue = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        let desk = try XCTUnwrap(deskValue)
        XCTAssertEqual(desk.materials.count, 1, "exactly one card: the words, and no revived recording")
        let card = try XCTUnwrap(desk.materials.first)
        XCTAssertEqual(
            card.id, WorkVoiceCaptureCoordinator.fallbackNoteID(forCapture: captureID),
            "the note takes the derived id; at the capture's own it would be answered and write nothing"
        )
        XCTAssertEqual(card.kind, .note)
        XCTAssertEqual(card.textContent, "the words outlive the card")
        XCTAssertEqual(
            card.title, "the words outlive the card",
            "the note names itself the way the recording would have, once it had words"
        )
        XCTAssertFalse(
            desk.materials.contains { $0.kind == .audio },
            """
            Phase one is KNOWN to have landed, so a missing card is a deletion. \
            Republishing here brings back a recording the person threw away.
            """
        )
    }

    func testALegacyRecordWhoseCardIsGoneLandsBesideItRatherThanRepublishingIt() async throws {
        let store = ConversationStore(inMemory: true)
        let captureID = UUID()

        let outcome = try await WorkVoiceCaptureCoordinator.recover(
            Self.record(id: captureID, publicationState: nil),
            transcript: "an old record, and no card to be found",
            store: store
        )

        XCTAssertEqual(outcome, .fallbackNotePublished)
        let deskValue = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        let desk = try XCTUnwrap(deskValue)
        XCTAssertEqual(desk.materials.count, 1)
        XCTAssertFalse(
            desk.materials.contains { $0.kind == .audio },
            """
            Unknown is not permission. A record that never carried its verdict \
            takes the branch that cannot resurrect anything.
            """
        )
    }

    // MARK: - recover: a publication the desk refused

    func testAKnownFailedPublicationIsRepublishedFromTheParkedBytesAndTakesItsWords() async throws {
        let store = ConversationStore(inMemory: true)
        let captureID = UUID()

        let outcome = try await WorkVoiceCaptureCoordinator.recover(
            Self.record(id: captureID, publicationState: .phaseOneFailed),
            transcript: "Ferry leaves at 07:30\nask about the bikes",
            store: store
        )

        XCTAssertEqual(outcome, .republishedAndAttached)
        XCTAssertTrue(outcome.isTerminal)
        let deskValue = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        let desk = try XCTUnwrap(deskValue)
        XCTAssertEqual(desk.materials.count, 1, "one capture, one card — the one it was always going to have")
        let card = try XCTUnwrap(desk.materials.first)
        XCTAssertEqual(card.id, captureID, "the recording comes back under the capture's own id")
        XCTAssertEqual(
            card.kind, .audio,
            "a capture the desk refused must not be downgraded to a note on the way back"
        )
        XCTAssertTrue(card.hasPayload)
        let payload = try await store.loadWorkMaterialPayload(id: captureID)
        XCTAssertEqual(
            payload, Self.recordingBytes,
            "the parked bytes ARE the recording; nothing else has a copy"
        )
        XCTAssertEqual(card.textContent, "Ferry leaves at 07:30\nask about the bikes")
        XCTAssertEqual(card.title, "Ferry leaves at 07:30")
        XCTAssertEqual(
            card.mimeType, "audio/mp4",
            "the container is read off the bytes, not assumed from the parked file's name"
        )
    }

    /// The state a crash between the write and its confirmation leaves: the
    /// verdict says the publication failed, and the card is nonetheless there.
    /// The republication has to be a repair, not a second recording.
    func testAKnownFailedPublicationThatActuallyLandedRepairsTheSameCard() async throws {
        let store = ConversationStore(inMemory: true)
        let captureID = UUID()
        let standing = try await Self.publish(captureID: captureID, in: store)

        let outcome = try await WorkVoiceCaptureCoordinator.recover(
            Self.record(id: captureID, publicationState: .phaseOneFailed),
            transcript: "recovered after a crash between the write and its answer",
            store: store
        )

        XCTAssertEqual(outcome, .republishedAndAttached)
        let deskValue = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        let desk = try XCTUnwrap(deskValue)
        XCTAssertEqual(
            desk.materials.count, 1,
            "the desk write is idempotent by id; a replay is a repair, never a duplicate"
        )
        XCTAssertEqual(desk.materials.first?.id, standing.id)
        let payload = try await store.loadWorkMaterialPayload(id: captureID)
        XCTAssertEqual(payload, Self.recordingBytes)
        XCTAssertEqual(
            desk.materials.first?.textContent,
            "recovered after a crash between the write and its answer"
        )
    }

    // MARK: - recover: an id that names something else

    func testACardThatIsNotARecordingTakesTheWordsBesideItRatherThanOntoIt() async throws {
        let store = ConversationStore(inMemory: true)
        let captureID = UUID()
        _ = try await store.upsertDeskMaterial(
            WorkMaterialDraft(
                id: captureID,
                kind: .image,
                title: "screenshot.jpg",
                filename: "screenshot.jpg",
                mimeType: "image/jpeg",
                payload: Data(repeating: 0x2A, count: 64)
            )
        )

        let outcome = try await WorkVoiceCaptureCoordinator.recover(
            Self.record(id: captureID, publicationState: .published),
            transcript: "spoken words that belong to a recording",
            store: store
        )

        XCTAssertEqual(outcome, .fallbackNotePublished)
        let deskValue = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        let desk = try XCTUnwrap(deskValue)
        XCTAssertEqual(desk.materials.count, 2, "the picture, and the words beside it")
        let picture = try XCTUnwrap(desk.materials.first { $0.id == captureID })
        XCTAssertEqual(picture.kind, .image, "the screenshot stays a screenshot")
        XCTAssertNil(picture.textContent, "…and never acquires somebody's spoken words")
        let note = try XCTUnwrap(
            desk.materials.first {
                $0.id == WorkVoiceCaptureCoordinator.fallbackNoteID(forCapture: captureID)
            }
        )
        XCTAssertEqual(note.textContent, "spoken words that belong to a recording")
    }

    // MARK: - recover: what must NOT be terminal

    func testAStoreThatRefusesTheAttachRethrowsSoTheCallerKeepsItsRetry() async throws {
        let broken = try Self.unusableStore()
        let refuses = await Self.refusesWrites(broken)
        XCTAssertTrue(refuses, "the fixture must actually refuse a desk write")

        do {
            _ = try await WorkVoiceCaptureCoordinator.recover(
                Self.record(id: UUID(), publicationState: .published),
                transcript: "words that reached nothing",
                store: broken
            )
            XCTFail("a write that failed must reach the caller as a throw, not as a terminal outcome")
        } catch {
            // The caller's `catch` is what keeps the durable record armed. An
            // outcome here would have it clear the only copy of the audio.
        }
    }

    func testAStoreThatRefusesTheRepublicationRethrowsBeforeAnythingIsAttached() async throws {
        let broken = try Self.unusableStore()
        let refuses = await Self.refusesWrites(broken)
        XCTAssertTrue(refuses)

        do {
            _ = try await WorkVoiceCaptureCoordinator.recover(
                Self.record(id: UUID(), publicationState: .phaseOneFailed),
                transcript: "words for a recording that could not be put back",
                store: broken
            )
            XCTFail("a refused republication must not be swallowed into a note-shaped fallback")
        } catch {
            // Same rule one phase earlier: the parked bytes are the only copy,
            // so the record has to survive this attempt.
        }
    }

    func testAChatRecordIsNotAWorkRecoveryAndTouchesNothing() async throws {
        let store = ConversationStore(inMemory: true)

        let outcome = try await WorkVoiceCaptureCoordinator.recover(
            Self.record(id: UUID(), destination: .chat, publicationState: nil),
            transcript: "a conversation turn, not a card",
            store: store
        )

        XCTAssertEqual(outcome, .retryKept(.notAWorkCapture))
        XCTAssertFalse(outcome.isTerminal, "the chat lane still owns this record")
        let desk = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        XCTAssertNil(desk, "a chat record must not so much as create the desk row")
    }

    func testARecoveryWithNoWordsKeepsTheRetryAndWritesNothing() async throws {
        let store = ConversationStore(inMemory: true)
        let captureID = UUID()
        let published = try await Self.publish(captureID: captureID, in: store)

        let outcome = try await WorkVoiceCaptureCoordinator.recover(
            Self.record(id: captureID, publicationState: .published),
            transcript: "   \n  ",
            store: store
        )

        XCTAssertEqual(outcome, .retryKept(.noTranscript))
        XCTAssertFalse(
            outcome.isTerminal,
            "recognition still owes this capture its words; releasing the record would lose the bytes"
        )
        let deskValue = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        let desk = try XCTUnwrap(deskValue)
        XCTAssertEqual(desk.materials.count, 1, "silence publishes nothing beside the recording")
        XCTAssertEqual(desk.materials.first?.updatedAt, published.updatedAt, "and writes nothing to it")
        XCTAssertNil(desk.materials.first?.textContent)
    }

    func testARepeatedRecoveryLandsOnTheNoteItAlreadyPublished() async throws {
        let store = ConversationStore(inMemory: true)
        let captureID = UUID()
        let record = Self.record(id: captureID, publicationState: .published)

        let first = try await WorkVoiceCaptureCoordinator.recover(
            record, transcript: "said once", store: store
        )
        let second = try await WorkVoiceCaptureCoordinator.recover(
            record, transcript: "said once", store: store
        )

        XCTAssertEqual(first, .fallbackNotePublished)
        XCTAssertEqual(second, .fallbackNotePublished)
        let deskValue = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        let desk = try XCTUnwrap(deskValue)
        XCTAssertEqual(
            desk.materials.count, 1,
            "the note id is derived, so a capture recovered twice still has one note"
        )
    }

    func testOnlyTheWrittenOutcomesReportThemselvesTerminal() {
        XCTAssertTrue(WorkVoiceRecoveryOutcome.attached.isTerminal)
        XCTAssertTrue(WorkVoiceRecoveryOutcome.republishedAndAttached.isTerminal)
        XCTAssertTrue(WorkVoiceRecoveryOutcome.fallbackNotePublished.isTerminal)
        XCTAssertFalse(WorkVoiceRecoveryOutcome.retryKept(.notAWorkCapture).isTerminal)
        XCTAssertFalse(
            WorkVoiceRecoveryOutcome.retryKept(.noTranscript).isTerminal,
            """
            `isTerminal` is the caller's whole duty. A surface that matched the \
            cases by hand is one edit away from clearing a record whose words \
            were never written anywhere.
            """
        )
    }

    // MARK: - The single retry slot's lifetime

    /// A capture that finishes releases its claim. A resolved claim left armed
    /// is one the home-screen card offers to re-transcribe, and one an
    /// unrelated capture will displace — deleting audio nobody is waiting for.
    @MainActor
    func testASuccessfulTryAgainReleasesTheDurableRetry() async throws {
        let store = ConversationStore(inMemory: true)
        let lane = RecordingRetryLane()
        let recorder = Self.workRecorder(store: store, lane: lane)

        var hops = 0
        recorder.transcriptionHopForTesting = { _ in
            hops += 1
            return hops == 1 ? .failure(.sttProviderUnreachable) : .success("recovered on the retry")
        }

        _ = await recorder._finishCaptureForTesting()
        let cardID = try XCTUnwrap(recorder.workRecordingMaterialID)
        let parked = await lane.armed
        let armed = try XCTUnwrap(parked, "a failed capture parks its bytes")
        XCTAssertEqual(armed.id, cardID, "one identity: the card, the capture and the record")

        let result = await recorder.retryWorkCapture()

        XCTAssertEqual(try result.get(), "recovered on the retry")
        let afterRetry = await lane.armed
        XCTAssertNil(
            afterRetry,
            """
            The words are on the card, so nothing is owed. Leaving the record \
            armed is what makes the retry card offer to buy the same transcript \
            again, and what lets an unrelated failure delete the audio behind it.
            """
        )
    }

    /// Record Again replaces a capture. Until the replacement microphone is
    /// actually live there is nothing to replace it WITH, so a refused start
    /// must leave the first capture — and the record that can still finish it —
    /// exactly where they were.
    @MainActor
    func testRecordAgainKeepsTheCaptureUntilTheReplacementMicrophoneStarts() async throws {
        let store = ConversationStore(inMemory: true)
        let lane = RecordingRetryLane()
        let recorder = Self.workRecorder(store: store, lane: lane)
        recorder.transcriptionHopForTesting = { _ in .failure(.sttProviderUnreachable) }

        _ = await recorder._finishCaptureForTesting()
        let cardID = try XCTUnwrap(recorder.workRecordingMaterialID)
        let parked = await lane.armed
        XCTAssertNotNil(parked)

        // The microphone refuses. Nothing about the first capture may change.
        recorder.microphoneStartForTesting = { false }
        recorder.dismissError()
        await recorder.startRecording()

        XCTAssertEqual(recorder.state, .error(.audioMissingData))
        XCTAssertTrue(
            recorder.canRetryWorkCapture,
            "a refused microphone is not a reason to abandon a capture that is still finishable"
        )
        XCTAssertEqual(recorder.pendingWorkCapture?.id, cardID)
        XCTAssertEqual(recorder.workRecordingMaterialID, cardID, "the card it published is still its own")
        let stillArmed = await lane.armed
        XCTAssertEqual(
            stillArmed?.id, cardID,
            "and the only durable copy of its bytes is still there"
        )

        // The microphone comes up. NOW the first capture is genuinely replaced.
        recorder.microphoneStartForTesting = { true }
        recorder.dismissError()
        await recorder.startRecording()

        guard case .recording = recorder.state else {
            return XCTFail("the replacement capture must actually be recording")
        }
        XCTAssertFalse(
            recorder.canRetryWorkCapture,
            "the replaced capture is no longer this sheet's subject"
        )
        XCTAssertNil(recorder.workRecordingMaterialID, "a new capture can never claim the old one's card")
        let afterReplacement = await lane.armed
        XCTAssertNil(
            afterReplacement,
            """
            The single slot belongs to the capture in hand. A replaced capture \
            keeps its playable card on the desk and gives the slot up, rather \
            than waiting to be displaced by the recording that replaced it.
            """
        )
    }

    /// The slot is one slot for the whole app. A capture whose recording is
    /// already a card owes only its words, and the record it would evict may be
    /// the only copy of another lane's audio.
    @MainActor
    func testACaptureWhoseRecordingIsSafeNeverEvictsTheOnlyCopyOfAnother() async throws {
        let store = ConversationStore(inMemory: true)
        let chat = Self.record(id: UUID(), destination: .chat, publicationState: nil)
        let lane = RecordingRetryLane(seeded: chat.metadata, audio: Data(repeating: 0x11, count: 32))
        let recorder = Self.workRecorder(store: store, lane: lane)
        recorder.transcriptionHopForTesting = { _ in .failure(.sttProviderUnreachable) }

        _ = await recorder._finishCaptureForTesting()

        XCTAssertNotNil(recorder.workRecordingMaterialID, "phase one still published the recording")
        let armed = await lane.armed
        XCTAssertEqual(
            armed?.id, chat.metadata.id,
            """
            The chat capture's bytes exist nowhere else. This capture's exist on \
            the desk, so what it would spend to park its words is somebody \
            else's recording.
            """
        )
        let saves = await lane.saves
        XCTAssertTrue(
            saves.isEmpty,
            "nothing was written to the slot at all — the incumbent is untouched, not restored"
        )
        XCTAssertTrue(
            recorder.canRetryWorkCapture,
            "the capture is still finishable in this process; only a kill costs its words"
        )

        // Negative control: the identical capture, the identical failure, and
        // an EMPTY slot. Without it the assertions above would also pass if
        // this shape simply never armed anything.
        let freeLane = RecordingRetryLane()
        let second = Self.workRecorder(store: store, lane: freeLane)
        second.transcriptionHopForTesting = { _ in .failure(.sttProviderUnreachable) }
        _ = await second._finishCaptureForTesting()
        let armedOnAFreeSlot = await freeLane.armed
        XCTAssertNotNil(
            armedOnAFreeSlot,
            "with nothing to evict, the same failure parks its words exactly as it always did"
        )
    }

    /// The other side of the same rule: when THIS capture's bytes are the only
    /// copy, they are parked whatever else is in the slot.
    @MainActor
    func testAPublicationTheDeskRefusedArmsTheSlotWhateverElseHoldsIt() async throws {
        let broken = try Self.unusableStore()
        let refuses = await Self.refusesWrites(broken)
        XCTAssertTrue(refuses)
        let chat = Self.record(id: UUID(), destination: .chat, publicationState: nil)
        let lane = RecordingRetryLane(seeded: chat.metadata, audio: Data(repeating: 0x11, count: 32))
        let recorder = Self.workRecorder(store: broken, lane: lane)
        recorder.transcriptionHopForTesting = { _ in .success("never reached") }

        let result = await recorder._finishCaptureForTesting()

        guard case .failure(let error) = result else {
            return XCTFail("a capture with no card must not report success")
        }
        XCTAssertEqual(error.errorCode, AppError.workDeskWriteFailed.errorCode)
        XCTAssertTrue(error.isRetryable, "the same bytes, written again, normally land")
        let parked = await lane.armed
        let armed = try XCTUnwrap(parked)
        XCTAssertNotEqual(
            armed.id, chat.metadata.id,
            "a recording that reached nothing at all is the one thing worth the slot"
        )
        XCTAssertEqual(
            armed.publicationState, .phaseOneFailed,
            """
            The verdict is what lets a later recovery put this recording back \
            instead of reading its absence as a deletion.
            """
        )
        XCTAssertNil(armed.transcript, "recognition was never attempted, so there are no words to park")
    }

    /// The words are bought once. A capture whose card refused them parks them
    /// with its bytes, so a recovery after a kill attaches instead of paying a
    /// provider for the answer it already has.
    @MainActor
    func testAnAttachFailureParksTheWordsAndTheVerdictWithTheCapture() async throws {
        let store = ConversationStore(inMemory: true)
        let broken = try Self.unusableStore()
        let refuses = await Self.refusesWrites(broken)
        XCTAssertTrue(refuses)
        let lane = RecordingRetryLane()
        let recorder = Self.workRecorder(store: store, lane: lane)
        recorder.transcriptionHopForTesting = { [weak recorder] _ in
            // The card is published by now; break the store between the phases
            // so the attachment — and only the attachment — fails.
            recorder?.workStoreForTesting = broken
            return .success("the ferry leaves at seven")
        }

        _ = await recorder._finishCaptureForTesting()

        let parked = await lane.armed
        let armed = try XCTUnwrap(parked)
        XCTAssertEqual(armed.id, recorder.workRecordingMaterialID)
        XCTAssertEqual(
            armed.transcript, "the ferry leaves at seven",
            """
            Without this the words die with the process and the same bytes are \
            sent to the provider again for the answer it already gave.
            """
        )
        XCTAssertEqual(
            armed.publicationState, .published,
            "the card is standing, so a later absence is a deletion and not a refused write"
        )
    }

    // MARK: - Fixtures

    /// Stands in for a compressed 16 kHz mono AAC voice note: small, so the
    /// storage policy picks the synced lane exactly as it does in the app, and
    /// not decodable as audio, so `AudioCompressor` returns it untouched.
    private static let recordingBytes = Data(repeating: 0x7F, count: 4_096)

    @MainActor
    private static func workRecorder(
        store: ConversationStore,
        lane: RecordingRetryLane
    ) -> InAppAudioRecorder {
        let recorder = InAppAudioRecorder(retryDestination: .work)
        recorder.workStoreForTesting = store
        recorder.retryLaneForTesting = lane
        recorder.capturedAudioForTesting = recordingBytes
        return recorder
    }

    private static func record(
        id: UUID,
        destination: PendingRetryDestination = .work,
        transcript: String? = nil,
        publicationState: PendingRetryPublicationState?
    ) -> PendingRetryRecord {
        PendingRetryRecord(
            metadata: PendingRetryMetadata(
                id: id,
                createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                audioFileURL: URL(fileURLWithPath: "/dev/null"),
                preferredLanguage: nil,
                attemptCount: 1,
                lastErrorCode: AppError.workDeskWriteFailed.errorCode,
                destination: destination,
                transcript: transcript,
                publicationState: publicationState
            ),
            audio: recordingBytes
        )
    }

    @discardableResult
    private static func publish(
        captureID: UUID,
        in store: ConversationStore
    ) async throws -> WorkMaterialRecord {
        try await WorkVoiceCaptureCoordinator.publishRecording(
            captureID: captureID,
            audio: recordingBytes,
            fileExtension: "m4a",
            mimeType: "audio/mp4",
            store: store
        )
    }

    /// A store that cannot mount, so every operation on it throws. The URL
    /// names a DIRECTORY, which SQLite cannot open as a database file.
    private static func unusableStore() throws -> ConversationStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "conduck-unusable-\(UUID().uuidString).sqlite",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        return ConversationStore(inMemory: false, storeURL: directory)
    }

    /// Proves the broken fixture is really broken: a test that passed because
    /// the store quietly worked would assert nothing at all.
    private static func refusesWrites(_ store: ConversationStore) async -> Bool {
        do {
            _ = try await store.upsertDeskMaterial(
                WorkMaterialDraft(
                    id: UUID(),
                    kind: .note,
                    title: "probe",
                    textContent: "probe",
                    storageMode: .metadataOnly
                )
            )
            return false
        } catch {
            return true
        }
    }
}

/// An in-memory stand-in for the single App-Group retry slot, with the same
/// overwriting semantics: one record at a time, and a clear that fires only for
/// the capture still holding it.
///
/// The real store is a process-global singleton over one file every capture
/// test in this bundle shares, and what these cases assert is which capture the
/// recorder arms, releases and refuses to evict — a property of the recorder,
/// not of the wire format `PendingRetryDestinationTests` pins.
private actor RecordingRetryLane: PendingRetrySlotWriting {
    private var current: (metadata: PendingRetryMetadata, audio: Data)?

    /// Every metadata this lane was ASKED to write, so a test can tell "the
    /// incumbent survived" from "the incumbent was overwritten and put back".
    private(set) var saves: [PendingRetryMetadata] = []

    init(seeded: PendingRetryMetadata? = nil, audio: Data = Data()) {
        if let seeded { current = (seeded, audio) }
    }

    var armed: PendingRetryMetadata? { current?.metadata }

    func save(
        audioData: Data,
        metadata: PendingRetryMetadata,
        workImageData: Data?
    ) async throws {
        saves.append(metadata)
        current = (metadata, audioData)
    }

    @discardableResult
    func clear(ifCurrentID id: UUID) async -> Bool {
        guard current?.metadata.id == id else { return false }
        current = nil
        return true
    }

    func currentSlot() async -> PendingRetrySlot? {
        guard let current else { return nil }
        return PendingRetrySlot(
            id: current.metadata.id,
            destination: current.metadata.resolvedDestination,
            publicationState: current.metadata.publicationState
        )
    }
}
