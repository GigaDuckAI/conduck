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
// The third observation is an id that is REFUSED rather than answered: a card
// of another kind already stands at the capture's own id, so the desk write
// throws and never stops throwing. The recording goes back under the capture's
// collision escape instead, the words follow it there, and a refusal of THAT id
// too is the one state where nothing can carry them.
//
// The second half is a queue ENTRY's lifetime, asserted through the recorder
// that owns it: a finished capture releases its own entry, a replaced one
// releases it only once the replacement microphone is actually live, and a
// second capture takes its place beside whatever is already waiting instead of
// deleting it. Two captures queued together each finish onto their own card.
//
// `recover` is handed a CLAIM, so what it records about a capture is durable
// and assertable. The cases that make a claim by hand carry a token no store
// issued — enough to drive the desk decision — while the cases about what
// `recover` WRITES take a real reservation from this case's own isolated queue.

import Speech
import XCTest
@testable import Conduck

final class WorkVoiceRecoveryTests: XCTestCase {

    /// Every case gets its OWN queue: the production singleton writes the
    /// process-global App-Group container every other capture test in this
    /// bundle shares, and `recover` now writes a publication verdict into
    /// whichever queue it is handed.
    private var queueContainer: URL!
    private var queueDefaults: InMemoryDefaultsStore!
    private var queue: PendingRetryStore!

    override func setUp() {
        super.setUp()
        queueContainer = FileManager.default.temporaryDirectory
            .appendingPathComponent("work-voice-recovery-\(UUID().uuidString)", isDirectory: true)
        queueDefaults = InMemoryDefaultsStore()
        queue = PendingRetryStore(containerURL: queueContainer, defaults: queueDefaults)
    }

    override func tearDown() {
        if let queueContainer { try? FileManager.default.removeItem(at: queueContainer) }
        queue = nil
        queueDefaults = nil
        queueContainer = nil
        super.tearDown()
    }

    // MARK: - recover: a recording that is standing

    func testAKnownPublishedRecordingTakesTheRecoveredWords() async throws {
        let store = ConversationStore(inMemory: true)
        let captureID = UUID()
        _ = try await Self.publish(captureID: captureID, in: store)

        let outcome = try await WorkVoiceCaptureCoordinator.recover(
            Self.claim(id: captureID, publicationState: .published),
            transcript: "  the ferry leaves at seven  ",
            store: store,
            queue: queue
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
            Self.claim(id: captureID, publicationState: nil),
            transcript: "recovered from a record that predates the verdict",
            store: store,
            queue: queue
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
            Self.claim(id: captureID, publicationState: .published),
            transcript: "the words outlive the card",
            store: store,
            queue: queue
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
            Self.claim(id: captureID, publicationState: nil),
            transcript: "an old record, and no card to be found",
            store: store,
            queue: queue
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
            Self.claim(id: captureID, publicationState: .phaseOneFailed),
            transcript: "Ferry leaves at 07:30\nask about the bikes",
            store: store,
            queue: queue
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
            Self.claim(id: captureID, publicationState: .phaseOneFailed),
            transcript: "recovered after a crash between the write and its answer",
            store: store,
            queue: queue
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
            Self.claim(id: captureID, publicationState: .published),
            transcript: "spoken words that belong to a recording",
            store: store,
            queue: queue
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

    // MARK: - recover: an id that is REFUSED rather than answered

    /// The desk does not ANSWER a colliding id, it throws — and the throw never
    /// stops, because the card of another kind standing there is not going
    /// anywhere. A recovery that rethrew it left the capture in the queue
    /// failing identically on every retry, for ever. The recording goes back
    /// under the capture's collision escape instead, and the words follow it
    /// there.
    func testACaptureWhoseIdIsTakenLandsUnderItsEscapeAndTakesItsWords() async throws {
        let store = ConversationStore(inMemory: true)
        let captureID = UUID()
        let pictureBytes = Data(repeating: 0x2A, count: 64)
        let picture = try await Self.foreignCard(at: captureID, in: store, bytes: pictureBytes)
        let escapeID = WorkMaterialCollisionEscape.materialID(forCapture: captureID)
        XCTAssertNotEqual(escapeID, captureID, "an escape that is the same id escapes nothing")

        let outcome = try await WorkVoiceCaptureCoordinator.recover(
            Self.claim(id: captureID, publicationState: .phaseOneFailed),
            transcript: "Ferry leaves at 07:30\nask about the bikes",
            store: store,
            queue: queue
        )

        XCTAssertEqual(outcome, .republishedAndAttached)
        XCTAssertTrue(
            outcome.isTerminal,
            """
            The capture is finished and its entry may go. A refusal that reached \
            the caller as a throw kept the entry armed over a state that never \
            resolves — which is the queue never emptying, not a retry.
            """
        )
        let deskValue = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        let desk = try XCTUnwrap(deskValue)
        XCTAssertEqual(Set(desk.materials.map(\.id)), [captureID, escapeID])

        let recording = try XCTUnwrap(desk.materials.first { $0.id == escapeID })
        XCTAssertEqual(recording.kind, .audio, "the recording is still a recording")
        XCTAssertEqual(recording.textContent, "Ferry leaves at 07:30\nask about the bikes")
        XCTAssertEqual(recording.title, "Ferry leaves at 07:30")
        let recovered = try await store.loadWorkMaterialPayload(id: escapeID)
        XCTAssertEqual(recovered, Self.recordingBytes, "the parked bytes are the only copy")

        let untouched = try XCTUnwrap(desk.materials.first { $0.id == captureID })
        XCTAssertEqual(untouched.kind, .image, "the card that was already there is unchanged")
        XCTAssertEqual(untouched.title, picture.title)
        XCTAssertNil(untouched.textContent, "…and never acquires somebody's spoken words")
        let stillItsOwn = try await store.loadWorkMaterialPayload(id: captureID)
        XCTAssertEqual(stillItsOwn, pictureBytes, "…nor loses a byte of its own payload")
    }

    /// The escape is a pure function of the colliding id, so the second process
    /// to reach this capture — or the same one after a crash — repairs the card
    /// it already wrote instead of publishing the recording twice.
    func testAReplayOfAnEscapedRecoveryRepairsTheSameCard() async throws {
        let store = ConversationStore(inMemory: true)
        let captureID = UUID()
        _ = try await Self.foreignCard(at: captureID, in: store)
        let claim = Self.claim(id: captureID, publicationState: .phaseOneFailed)
        let escapeID = WorkMaterialCollisionEscape.materialID(forCapture: captureID)

        let first = try await WorkVoiceCaptureCoordinator.recover(
            claim, transcript: "said once", store: store, queue: queue
        )
        let second = try await WorkVoiceCaptureCoordinator.recover(
            claim, transcript: "said once", store: store, queue: queue
        )

        XCTAssertEqual(first, .republishedAndAttached)
        XCTAssertEqual(second, .republishedAndAttached)
        let deskValue = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        let desk = try XCTUnwrap(deskValue)
        XCTAssertEqual(
            Set(desk.materials.map(\.id)), [captureID, escapeID],
            "a derived id replayed is a repair; a fresh one each time is a second card"
        )
        XCTAssertEqual(desk.materials.filter { $0.kind == .audio }.count, 1)
    }

    /// The end of the line, and the reason there is no third id: both the
    /// capture id and its escape name cards of another kind. The words go
    /// beside them, the capture finishes, and neither foreign card is touched.
    func testACaptureRefusedUnderBothIdsPutsItsWordsBesideThemAndFinishes() async throws {
        let store = ConversationStore(inMemory: true)
        let captureID = UUID()
        let escapeID = WorkMaterialCollisionEscape.materialID(forCapture: captureID)
        let firstBytes = Data(repeating: 0x2A, count: 64)
        let secondBytes = Data(repeating: 0x3B, count: 48)
        _ = try await Self.foreignCard(at: captureID, in: store, bytes: firstBytes)
        _ = try await Self.foreignCard(at: escapeID, in: store, bytes: secondBytes)

        let outcome = try await WorkVoiceCaptureCoordinator.recover(
            Self.claim(id: captureID, publicationState: .phaseOneFailed),
            transcript: "the ferry leaves at seven",
            store: store,
            queue: queue
        )

        XCTAssertEqual(outcome, .fallbackNotePublished)
        XCTAssertTrue(outcome.isTerminal, "the words are on the desk; nothing more can be done here")
        let noteID = WorkVoiceCaptureCoordinator.fallbackNoteID(forCapture: captureID)
        let deskValue = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        let desk = try XCTUnwrap(deskValue)
        XCTAssertEqual(Set(desk.materials.map(\.id)), [captureID, escapeID, noteID])
        XCTAssertFalse(
            desk.materials.contains { $0.kind == .audio },
            "a chain of derived ids has no end; the second refusal is the last one"
        )
        XCTAssertEqual(
            desk.materials.first { $0.id == noteID }?.textContent,
            "the ferry leaves at seven"
        )
        let firstPayload = try await store.loadWorkMaterialPayload(id: captureID)
        let secondPayload = try await store.loadWorkMaterialPayload(id: escapeID)
        XCTAssertEqual(firstPayload, firstBytes, "both cards that were there keep their own bytes")
        XCTAssertEqual(secondPayload, secondBytes)
    }

    /// The same double refusal with no words yet. Nothing can carry the
    /// recording and nothing can carry the words, so the capture stays queued
    /// with the verdict that says its bytes are the only copy — a `.published`
    /// written here would make it expirable and delete them.
    func testACaptureRefusedUnderBothIdsWithNoWordsKeepsItsRetryAndWritesNothing() async throws {
        let store = ConversationStore(inMemory: true)
        let captureID = UUID()
        let escapeID = WorkMaterialCollisionEscape.materialID(forCapture: captureID)
        _ = try await Self.foreignCard(at: captureID, in: store)
        _ = try await Self.foreignCard(at: escapeID, in: store)
        let claim = try await armedClaim(id: captureID, publicationState: .phaseOneFailed)

        let outcome = try await WorkVoiceCaptureCoordinator.recover(
            claim, transcript: nil, store: store, queue: queue
        )

        XCTAssertEqual(outcome, .retryKept(.noTranscript))
        XCTAssertFalse(outcome.isTerminal, "nothing was written, so nothing may be released")
        let deskValue = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        let desk = try XCTUnwrap(deskValue)
        XCTAssertEqual(
            Set(desk.materials.map(\.id)), [captureID, escapeID],
            "no recording, and no note of silence beside two cards that are not this capture's"
        )
        let stillWaiting = await queuedRecord(captureID)
        let queued = try XCTUnwrap(stillWaiting, "the capture is still waiting")
        XCTAssertEqual(
            queued.publicationState, .phaseOneFailed,
            "the desk never took the recording, so the verdict that protects it is unchanged"
        )
        XCTAssertTrue(queued.isExemptFromExpiry, "…and a clock may not delete the only copy")
    }

    /// The state an escape leaves behind, recovered again in another process:
    /// the recording is standing under the ESCAPE id and the verdict says the
    /// desk holds it. A recovery that looked only at the capture id would find
    /// the foreign card, read it as "no recording of mine", and write the words
    /// into a note beside a card that was there to carry them.
    func testALaterRecoveryFindsTheRecordingUnderTheEscapeItAlreadyTook() async throws {
        let store = ConversationStore(inMemory: true)
        let captureID = UUID()
        let escapeID = WorkMaterialCollisionEscape.materialID(forCapture: captureID)
        _ = try await Self.foreignCard(at: captureID, in: store)
        _ = try await Self.publish(captureID: escapeID, in: store)

        let outcome = try await WorkVoiceCaptureCoordinator.recover(
            Self.claim(id: captureID, publicationState: .published),
            transcript: "the ferry leaves at seven",
            store: store,
            queue: queue
        )

        XCTAssertEqual(outcome, .attached, "nothing was republished; the recording was already there")
        let deskValue = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        let desk = try XCTUnwrap(deskValue)
        XCTAssertEqual(
            Set(desk.materials.map(\.id)), [captureID, escapeID],
            "no note: the words found the recording they came from"
        )
        XCTAssertEqual(
            desk.materials.first { $0.id == escapeID }?.textContent,
            "the ferry leaves at seven"
        )
        XCTAssertNil(desk.materials.first { $0.id == captureID }?.textContent)
    }

    // MARK: - recover: what it records about the capture it finished

    /// r5a#6. A republication with no words yet answers `.retryKept`, so the
    /// entry stays armed — and an entry still saying the desk refused this
    /// recording is exempt from expiry for ever AND licenses the next retry to
    /// republish a card the person may have deleted in between. The verdict is
    /// recorded the moment it is true.
    func testARepublicationWithNoWordsRecordsThatTheDeskHoldsTheRecording() async throws {
        let store = ConversationStore(inMemory: true)
        let captureID = UUID()
        let claim = try await armedClaim(id: captureID, publicationState: .phaseOneFailed)

        let outcome = try await WorkVoiceCaptureCoordinator.recover(
            claim, transcript: nil, store: store, queue: queue
        )

        XCTAssertEqual(outcome, .retryKept(.noTranscript))
        XCTAssertFalse(outcome.isTerminal, "recognition still owes this capture its words")
        let deskValue = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        let desk = try XCTUnwrap(deskValue)
        let card = try XCTUnwrap(desk.materials.first)
        XCTAssertEqual(card.id, captureID)
        XCTAssertEqual(card.kind, .audio)
        XCTAssertNil(card.textContent, "the card is honestly wordless until they arrive")

        let stillWaiting = await queuedRecord(captureID)
        let queued = try XCTUnwrap(stillWaiting, "the capture is still waiting")
        XCTAssertEqual(
            queued.publicationState, .published,
            """
            The recording IS on the desk now. Left at `.phaseOneFailed`, a later \
            retry reads the absence of a card the person has since deleted as a \
            refused write and puts it back.
            """
        )
        XCTAssertNil(queued.transcript, "a nil transcript keeps what the record already carried")
        XCTAssertFalse(
            queued.isExemptFromExpiry,
            "…and the recording no longer exists only here, so the clock may govern it again"
        )
        // WHICH clock, though. The words are still owed and the person who owes
        // them may be driving, so the budget is a day rather than the ten
        // minutes a Chat transcription gets. The exemption above stays false on
        // purpose: a longer clock still ends, and these bytes are a second copy
        // of a card that is already on the desk.
        XCTAssertEqual(
            queued.retryTTL, PendingRetryMetadata.publishedWorkRetryTTL,
            """
            A published Work capture waits on the long budget. On the ten-minute one it \
            is swept before a driver can reach the phone the acknowledgement named.
            """
        )
    }

    /// The words the entry already carries are the ones a surface with none of
    /// its own recovers with. Leaving them in the entry buys the same answer
    /// from the provider a second time, and answers `.noTranscript` over a
    /// capture whose words were never missing.
    func testTheWordsAlreadyParkedFinishACaptureWhenTheSurfaceHasNone() async throws {
        let store = ConversationStore(inMemory: true)
        let captureID = UUID()
        _ = try await Self.publish(captureID: captureID, in: store)

        let outcome = try await WorkVoiceCaptureCoordinator.recover(
            Self.claim(
                id: captureID,
                transcript: "the ferry leaves at seven",
                publicationState: .published
            ),
            transcript: nil,
            store: store,
            queue: queue
        )

        XCTAssertEqual(outcome, .attached)
        let deskValue = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        let desk = try XCTUnwrap(deskValue)
        XCTAssertEqual(desk.materials.first?.textContent, "the ferry leaves at seven")
    }

    // MARK: - recover: what must NOT be terminal

    func testAStoreThatRefusesTheAttachRethrowsSoTheCallerKeepsItsRetry() async throws {
        let broken = try Self.unusableStore()
        let refuses = await Self.refusesWrites(broken)
        XCTAssertTrue(refuses, "the fixture must actually refuse a desk write")

        do {
            _ = try await WorkVoiceCaptureCoordinator.recover(
                Self.claim(id: UUID(), publicationState: .published),
                transcript: "words that reached nothing",
                store: broken,
                queue: queue
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
                Self.claim(id: UUID(), publicationState: .phaseOneFailed),
                transcript: "words for a recording that could not be put back",
                store: broken,
                queue: queue
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
            Self.claim(id: UUID(), destination: .chat, publicationState: nil),
            transcript: "a conversation turn, not a card",
            store: store,
            queue: queue
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
            Self.claim(id: captureID, publicationState: .published),
            transcript: "   \n  ",
            store: store,
            queue: queue
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

    /// The recording is not held hostage by the words. A capture the desk
    /// refused holds the only copy of what was said in its parked bytes, and
    /// that is true before recognition has produced anything — so the bytes go
    /// back on the desk and only the TRANSCRIPT is still owed.
    func testAPublicationTheDeskRefusedIsPutBackEvenWhenNoWordsExistYet() async throws {
        let store = ConversationStore(inMemory: true)
        let captureID = UUID()

        let outcome = try await WorkVoiceCaptureCoordinator.recover(
            Self.claim(id: captureID, publicationState: .phaseOneFailed),
            transcript: "   \n  ",
            store: store,
            queue: queue
        )

        XCTAssertEqual(
            outcome, .retryKept(.noTranscript),
            "recognition still owes this capture its words, so the record stays armed"
        )
        XCTAssertFalse(outcome.isTerminal)
        let deskValue = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        let desk = try XCTUnwrap(deskValue)
        let card = try XCTUnwrap(
            desk.materials.first,
            """
            Answering `.noTranscript` before the republication leaves the only \
            copy of this recording in a queue entry and nothing on the desk — \
            which is the state a device that never gets a working STT key stays \
            in forever.
            """
        )
        XCTAssertEqual(card.id, captureID)
        XCTAssertEqual(card.kind, .audio)
        XCTAssertNil(card.textContent, "…and the card is honestly wordless until they arrive")
        let payload = try await store.loadWorkMaterialPayload(id: captureID)
        XCTAssertEqual(payload, Self.recordingBytes)
    }

    func testARepeatedRecoveryLandsOnTheNoteItAlreadyPublished() async throws {
        let store = ConversationStore(inMemory: true)
        let captureID = UUID()
        let record = Self.claim(id: captureID, publicationState: .published)

        let first = try await WorkVoiceCaptureCoordinator.recover(
            record, transcript: "said once", store: store, queue: queue
        )
        let second = try await WorkVoiceCaptureCoordinator.recover(
            record, transcript: "said once", store: store, queue: queue
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

    /// r6a#1's in-app half. The desk's voice sheet and the app's retry card are
    /// reachable on one screen and read one queue, so Try Again has to RESERVE
    /// the parked recording before it touches it — and refuse when another
    /// surface is already finishing that same recording.
    ///
    /// Refusing is not a failure: nothing is deleted, no second transcription is
    /// bought for one recording, the capture stays finishable, and the sheet says
    /// so. On the shape this replaced, both surfaces transcribed the same bytes
    /// and whichever finished first deleted them from under the other.
    @MainActor
    func testTheSheetsRetryIsRefusedWhileAnotherSurfaceHoldsTheRecording() async throws {
        let store = ConversationStore(inMemory: true)
        let lane = RecordingRetryLane()
        let recorder = Self.workRecorder(store: store, lane: lane)

        var hops = 0
        recorder.transcriptionHopForTesting = { _ in
            hops += 1
            return hops == 1 ? .failure(.sttProviderUnreachable) : .success("recovered on the retry")
        }

        _ = await recorder._finishCaptureForTesting()
        let captureID = try XCTUnwrap(recorder.workRecordingMaterialID)
        let bytesBefore = await lane.audio(id: captureID)
        XCTAssertNotNil(bytesBefore, "the failed capture parked its bytes")

        // The menu bar — or a Shortcut host, or a second window — takes it over.
        await lane.reserveForAnotherSurface(id: captureID)

        let refused = await recorder.retryWorkCapture()

        guard case .failure = refused else {
            return XCTFail("a retry that never ran must not report a transcript")
        }
        XCTAssertTrue(
            recorder.retryRefusedBusy,
            """
            The sheet has nothing to say about this tap. It is the one state \
            where the honest sentence is that the recording is being finished \
            somewhere else, not that anything failed.
            """
        )
        XCTAssertEqual(
            hops, 1,
            """
            A second transcription of a recording another surface is already \
            transcribing is two provider round trips, two charges and two \
            answers for one thing said once.
            """
        )
        let entryAfter = await lane.entry(id: captureID)
        XCTAssertNotNil(entryAfter, "and NOTHING was deleted — the holder still has a capture to finish")
        let bytesAfter = await lane.audio(id: captureID)
        XCTAssertEqual(bytesAfter, bytesBefore, "byte for byte, the recording is untouched")
        XCTAssertTrue(
            recorder.canRetryWorkCapture,
            "the capture is exactly as finishable as it was a moment ago"
        )
        XCTAssertEqual(
            recorder.state, .error(.sttProviderUnreachable),
            "and the state the sheet is showing is the one it was already showing"
        )
    }

    /// The reservation is taken BEFORE the speech hop and given back the moment
    /// a retry ends without finishing the capture — so the next tap, here or on
    /// the retry card, takes it immediately instead of waiting out a lease.
    @MainActor
    func testARetryReservesBeforeItTranscribesAndHandsTheCaptureBackWhenItFails() async throws {
        let store = ConversationStore(inMemory: true)
        let lane = RecordingRetryLane()
        let recorder = Self.workRecorder(store: store, lane: lane)

        var reservedDuringHop: [Bool] = []
        recorder.transcriptionHopForTesting = { _ in
            reservedDuringHop.append(await lane.isReserved(id: recorder.pendingWorkCapture?.id ?? UUID()))
            return .failure(.sttProviderUnreachable)
        }

        _ = await recorder._finishCaptureForTesting()
        let captureID = try XCTUnwrap(recorder.workRecordingMaterialID)
        XCTAssertEqual(
            reservedDuringHop, [false],
            "the FIRST run reserves nothing — there is no queue entry until it fails"
        )

        _ = await recorder.retryWorkCapture()

        XCTAssertEqual(
            reservedDuringHop, [false, true],
            """
            The retry has to hold the capture while it transcribes. Reserving \
            after the hop protects nothing: the window this closes is exactly \
            the minutes the provider is thinking.
            """
        )
        let reservationsTaken = await lane.reservations
        XCTAssertEqual(reservationsTaken, [captureID], "and it reserved THIS capture, not the newest one")
        let handedBack = await lane.releases
        XCTAssertEqual(
            handedBack, [captureID],
            """
            A retry that failed leaves the capture waiting, so the hold goes \
            back at once. Keeping it would make the retry card refuse the person \
            their own recording for the length of the lease.
            """
        )
        let stillHeld = await lane.isReserved(id: captureID)
        XCTAssertFalse(stillHeld)
        let stillQueued = await lane.entry(id: captureID)
        XCTAssertNotNil(stillQueued, "the entry itself is untouched by the release")
    }

    /// A capture the recorder armed but no longer HOLDS is not its to delete.
    /// Record Again lets go of the first capture, and the lease-blind clear this
    /// replaced deleted the recording the retry card was mid-transcription on.
    @MainActor
    func testRecordAgainLeavesARecordingAnotherSurfaceIsFinishing() async throws {
        let store = ConversationStore(inMemory: true)
        let lane = RecordingRetryLane()
        let recorder = Self.workRecorder(store: store, lane: lane)
        recorder.transcriptionHopForTesting = { _ in .failure(.sttProviderUnreachable) }

        _ = await recorder._finishCaptureForTesting()
        let captureID = try XCTUnwrap(recorder.workRecordingMaterialID)
        let bytesBefore = await lane.audio(id: captureID)

        // Another surface is finishing it when the person taps Record Again.
        await lane.reserveForAnotherSurface(id: captureID)
        recorder.microphoneStartForTesting = { true }
        recorder.dismissError()
        await recorder.startRecording()

        guard case .recording = recorder.state else {
            return XCTFail("the replacement capture must actually be recording")
        }
        let survivor = await lane.entry(id: captureID)
        XCTAssertNotNil(
            survivor,
            """
            The recorder let go of a capture it armed — which is right — but it \
            does not own that recording any more, and the surface that does is \
            transcribing those exact bytes.
            """
        )
        let bytesAfter = await lane.audio(id: captureID)
        XCTAssertEqual(bytesAfter, bytesBefore)
        XCTAssertFalse(
            recorder.canRetryWorkCapture,
            "…and this sheet has still moved on: the replaced capture is no longer its subject"
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

    /// The queue is one queue for the whole app, and arming is not a claim on
    /// it. A Work capture that fails takes its place BESIDE a Chat capture
    /// already waiting; neither recording is spent to park the other's words.
    @MainActor
    func testASecondCaptureIsQueuedBesideTheFirstRatherThanReplacingIt() async throws {
        let store = ConversationStore(inMemory: true)
        let chatBytes = Data(repeating: 0x11, count: 32)
        let chat = Self.claim(id: UUID(), destination: .chat, publicationState: nil)
        let lane = RecordingRetryLane(seeded: chat.entry.metadata, audio: chatBytes)
        let recorder = Self.workRecorder(store: store, lane: lane)
        recorder.transcriptionHopForTesting = { _ in .failure(.sttProviderUnreachable) }

        _ = await recorder._finishCaptureForTesting()

        let workID = try XCTUnwrap(
            recorder.workRecordingMaterialID, "phase one still published the recording"
        )
        let queued = await lane.queued
        XCTAssertEqual(
            Set(queued.map(\.id)), [chat.id, workID],
            """
            BOTH captures are waiting. On a single overwriting slot the arriving \
            Work record deleted the Chat recording, whose bytes exist nowhere \
            else — and the reverse policy, declining to arm, spent this \
            capture's words instead. A queue owes neither.
            """
        )
        let survivingChatAudio = await lane.audio(id: chat.id)
        XCTAssertEqual(
            survivingChatAudio, chatBytes,
            "…and the incumbent's bytes are the ones it was armed with, not a rewrite"
        )
        let saves = await lane.saves
        XCTAssertEqual(
            saves.map(\.id), [workID],
            "exactly one write, and it names the arriving capture — nothing touched the incumbent"
        )
        XCTAssertTrue(
            recorder.canRetryWorkCapture,
            "the capture is still finishable in this process"
        )
    }

    /// Both queued captures finish, each onto its OWN card, one recovery at a
    /// time — and clearing the first leaves the second exactly where it was.
    @MainActor
    func testTwoQueuedCapturesEachFinishOntoTheirOwnCard() async throws {
        let store = ConversationStore(inMemory: true)
        let first = Self.claim(id: UUID(), publicationState: .phaseOneFailed)
        let second = Self.claim(id: UUID(), publicationState: .phaseOneFailed)
        let lane = RecordingRetryLane()
        try await lane.save(
            audioData: first.entry.audioData,
            metadata: first.entry.metadata,
            workImageData: nil
        )
        try await lane.save(
            audioData: second.entry.audioData,
            metadata: second.entry.metadata,
            workImageData: nil
        )

        let firstOutcome = try await WorkVoiceCaptureCoordinator.recover(
            first, transcript: "the ferry leaves at seven", store: store, queue: queue
        )
        XCTAssertTrue(firstOutcome.isTerminal)
        // Through the lane's OWN reservation, never the fabricated claim these
        // fixtures carry: the queue has no lease-blind clear left, so finishing
        // a capture means holding it first.
        let firstReservation = await lane.claim(id: first.id, duration: 600)
        let firstHold = try XCTUnwrap(firstReservation)
        let firstCleared = await lane.clear(firstHold)
        XCTAssertTrue(firstCleared)

        let stillQueued = await lane.queued
        XCTAssertEqual(
            stillQueued.map(\.id), [second.id],
            "clearing one completed capture removes exactly that one"
        )

        let secondOutcome = try await WorkVoiceCaptureCoordinator.recover(
            second, transcript: "ask about the bikes", store: store, queue: queue
        )
        XCTAssertTrue(secondOutcome.isTerminal)
        let secondReservation = await lane.claim(id: second.id, duration: 600)
        let secondHold = try XCTUnwrap(secondReservation)
        let secondCleared = await lane.clear(secondHold)
        XCTAssertTrue(secondCleared)

        let emptied = await lane.queued
        XCTAssertTrue(emptied.isEmpty)
        let deskValue = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        let desk = try XCTUnwrap(deskValue)
        XCTAssertEqual(
            Set(desk.materials.map(\.id)), [first.id, second.id],
            "two captures, two playable cards — neither recovery landed on the other's"
        )
        XCTAssertTrue(desk.materials.allSatisfy { $0.kind == .audio })
        XCTAssertEqual(
            Set(desk.materials.compactMap(\.textContent)),
            ["the ferry leaves at seven", "ask about the bikes"]
        )
    }

    /// A capture whose bytes are the only copy is queued whatever else is
    /// waiting, and it carries the verdict that lets a recovery put it back.
    @MainActor
    func testAPublicationTheDeskRefusedIsQueuedBesideWhateverElseIsWaiting() async throws {
        let broken = try Self.unusableStore()
        let refuses = await Self.refusesWrites(broken)
        XCTAssertTrue(refuses)
        let chat = Self.claim(id: UUID(), destination: .chat, publicationState: nil)
        let lane = RecordingRetryLane(seeded: chat.entry.metadata, audio: Data(repeating: 0x11, count: 32))
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
            armed.id, chat.id,
            "the newest capture is the one the retry card offers first"
        )
        let chatStillQueued = await lane.entry(id: chat.id)
        XCTAssertNotNil(
            chatStillQueued,
            "and the Chat capture, whose recording exists nowhere else, is still queued behind it"
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
    // MARK: - A reservation that lapses MID-RETRY

    /// The reservation is taken before the provider round trip and the round
    /// trip can outlast it: renewals are refused for a cross-process lock this
    /// process could not take exactly as they are for a hold somebody overtook,
    /// and the renewal loop deliberately never stops on a refusal. So this
    /// recorder can arrive at the write still believing it owns a capture the
    /// retry card, the menu bar or a Shortcut host has since claimed and is
    /// transcribing — and the write it would then make lands on THAT surface's
    /// card, over whichever words finished first.
    ///
    /// The last question before the words are written is therefore whether this
    /// reservation is still real. A refusal is not a failure of the capture: the
    /// recording stands on the desk, somebody is finishing it, and the sheet's
    /// busy sentence is what says so.
    func testWordsAreNotWrittenOnceThisRetrysReservationHasBeenOvertaken() async throws {
        let store = ConversationStore(inMemory: true)
        let lane = RecordingRetryLane()
        let recorder = Self.workRecorder(store: store, lane: lane)

        var hops = 0
        recorder.transcriptionHopForTesting = { _ in
            hops += 1
            return hops == 1
                ? .failure(.sttProviderUnreachable)
                : .success("the words this run bought")
        }
        _ = await recorder._finishCaptureForTesting()
        let captureID = try XCTUnwrap(recorder.workRecordingMaterialID)

        // The provider has answered and the write has not happened yet — the
        // exact gap a lapsed hold is discovered in. Another surface takes the
        // capture there.
        recorder.transcriptAttachPauseForTesting = {
            await lane.reserveForAnotherSurface(id: captureID)
        }

        let refused = await recorder.retryWorkCapture()

        guard case .failure = refused else {
            return XCTFail("a write this retry was not allowed to make must not report a transcript")
        }
        XCTAssertTrue(
            recorder.retryRefusedBusy,
            "the one honest sentence here is that the recording is being finished somewhere else"
        )
        let deskValue = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        let desk = try XCTUnwrap(deskValue)
        let card = try XCTUnwrap(desk.materials.first { $0.id == captureID })
        XCTAssertNil(
            card.textContent,
            """
            MEASURED: this run wrote its words onto a card it no longer owned. The surface that \
            claimed the capture is transcribing the same recording, and whichever of the two \
            finishes last silently replaces the other's answer.
            """
        )
        let stillQueued = await lane.entry(id: captureID)
        XCTAssertNotNil(stillQueued, "and nothing was deleted — the holder still has a capture to finish")
    }

    /// NEGATIVE CONTROL for the case above. With the reservation intact across
    /// the same gap, the identical retry writes its words onto the card — so
    /// what the case measures is the ownership check and not a write that never
    /// happens.
    func testTheSameRetryWritesItsWordsWhileItStillHoldsTheReservation() async throws {
        let store = ConversationStore(inMemory: true)
        let lane = RecordingRetryLane()
        let recorder = Self.workRecorder(store: store, lane: lane)

        var hops = 0
        recorder.transcriptionHopForTesting = { _ in
            hops += 1
            return hops == 1
                ? .failure(.sttProviderUnreachable)
                : .success("the words this run bought")
        }
        _ = await recorder._finishCaptureForTesting()
        let captureID = try XCTUnwrap(recorder.workRecordingMaterialID)

        var pausedAtTheWrite = false
        recorder.transcriptAttachPauseForTesting = { pausedAtTheWrite = true }

        let repaired = await recorder.retryWorkCapture()

        XCTAssertEqual(try repaired.get(), "the words this run bought")
        XCTAssertTrue(pausedAtTheWrite, "control: the run really did reach the write boundary")
        XCTAssertFalse(recorder.retryRefusedBusy, "control: nothing was refused")
        let deskValue = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        let desk = try XCTUnwrap(deskValue)
        let card = try XCTUnwrap(desk.materials.first { $0.id == captureID })
        XCTAssertEqual(card.textContent, "the words this run bought")
    }

    /// A refused claim may not PARK the capture it was refused.
    ///
    /// The surface that overtook this retry can have finished the recording and
    /// RETIRED its queue entry while this run's provider call was suspended —
    /// that is the ordinary shape of being overtaken, not an unlucky one. Routing
    /// the refusal through the same preservation a failed desk write uses wrote
    /// that entry back: same id, this run's stale words, a capture the person
    /// has already been told is done. It then offers a Try Again for a recording
    /// that is finished, and a recovery replays words the card already carries.
    ///
    /// The refusal keeps everything else it always did — the capture in hand,
    /// the retryable error, `retryRefusedBusy` — because none of that is a write.
    func testARefusedClaimDoesNotResurrectTheEntryTheOtherSurfaceRetired() async throws {
        let store = ConversationStore(inMemory: true)
        let lane = RecordingRetryLane()
        let recorder = Self.workRecorder(store: store, lane: lane)

        var hops = 0
        recorder.transcriptionHopForTesting = { _ in
            hops += 1
            return hops == 1
                ? .failure(.sttProviderUnreachable)
                : .success("the words this run bought")
        }
        _ = await recorder._finishCaptureForTesting()
        let captureID = try XCTUnwrap(recorder.workRecordingMaterialID)
        let armed = await lane.entry(id: captureID)
        XCTAssertNotNil(armed, "control: the first failure parked the capture")

        // The other surface does not merely hold the capture — it FINISHES it,
        // which retires the entry. That is what this run must not undo.
        recorder.transcriptAttachPauseForTesting = {
            await lane.finishFromAnotherSurface(id: captureID)
        }

        let refused = await recorder.retryWorkCapture()

        guard case .failure = refused else {
            return XCTFail("a write this retry was not allowed to make must not report a transcript")
        }
        XCTAssertTrue(recorder.retryRefusedBusy, "the sentence that says who has it")
        let resurrected = await lane.entry(id: captureID)
        XCTAssertNil(
            resurrected,
            """
            MEASURED: the refusal re-saved a capture another surface had already finished and \
            retired. The person is offered a Try Again for a recording that is done, and the \
            entry replays this run's stale words onto the card that already carries them.
            """
        )
        let saveIDs = await lane.saves.map(\.id)
        XCTAssertEqual(
            saveIDs.filter { $0 == captureID }.count, 1,
            "exactly the ONE save the first failure made; the refusal writes nothing"
        )
        let released = await lane.releases
        XCTAssertFalse(
            released.contains(captureID),
            "there is nothing to hand back — the lapsed claim was dropped before the refusal"
        )
    }

    /// A capture still in hand does not prove its card is standing.
    ///
    /// Cancelling the transcription keeps the capture — that is what its Try
    /// Again is for — while the card it published can have been deleted on
    /// another device in the same window. The recorder's own refresh answers
    /// that question, and this is the pair a receipt must be told from: retained
    /// AND confirmed gone. `WorkboardVoiceCaptureView`'s stopped state reads the
    /// fact, never the retention.
    func testACancelledTranscriptionKeepsACaptureWhoseCardTheDeskSaysIsGone() async throws {
        let store = ConversationStore(inMemory: true)
        let lane = RecordingRetryLane()
        let recorder = Self.workRecorder(store: store, lane: lane)

        recorder.transcriptionHopForTesting = { [weak recorder] _ in
            // Deleted while the words are being bought — the synced deletion the
            // person made on another device.
            let desk = try? await store.fetchWorkItem(id: Constants.workboardDeskItemID)
            if let card = desk?.materials.first {
                try? await store.deleteWorkMaterial(id: card.id)
            }
            // …and "Cancel transcription" pressed on this one.
            recorder?.cancelProcessing()
            return .success("words nobody is waiting for any more")
        }

        let outcome = await recorder._finishCaptureForTesting()
        guard case .failure(.unknown(let underlying)) = outcome, underlying is CancellationError else {
            return XCTFail("a cancelled transcription answers as a cancellation, with no banner")
        }
        XCTAssertTrue(
            recorder.canRetryWorkCapture,
            "control: the capture is retained, which is the only thing a receipt used to read"
        )
        XCTAssertFalse(
            recorder.workCaptureFacts.recordingOnDesk,
            """
            MEASURED: the desk's own answer and the capture's retention disagree, and only the \
            first is about the card. A stopped-state receipt told from the retention promises a \
            recording the person deleted.
            """
        )
    }

    private static func workRecorder(
        store: ConversationStore,
        lane: RecordingRetryLane
    ) -> InAppAudioRecorder {
        let recorder = InAppAudioRecorder(retryDestination: .work)
        recorder.workStoreForTesting = store
        recorder.retryLaneForTesting = lane
        recorder.capturedAudioForTesting = recordingBytes
        // The start path reads the machine's live Speech-Recognition TCC row,
        // which never prompts under XCTest — so on any device or CI image where
        // that row is `denied` these cases fail on the machine rather than on
        // the code. Pinned, so what they assert is what they are named for.
        recorder.speechAuthorizationForTesting = .authorized
        return recorder
    }

    private static func metadata(
        id: UUID,
        createdAt: Date = Date(timeIntervalSince1970: 1_700_000_000),
        destination: PendingRetryDestination = .work,
        transcript: String? = nil,
        publicationState: PendingRetryPublicationState?
    ) -> PendingRetryMetadata {
        PendingRetryMetadata(
            id: id,
            createdAt: createdAt,
            audioFileURL: URL(fileURLWithPath: "/dev/null"),
            preferredLanguage: nil,
            attemptCount: 1,
            lastErrorCode: AppError.workDeskWriteFailed.errorCode,
            destination: destination,
            transcript: transcript,
            publicationState: publicationState
        )
    }

    /// A claim made by hand, carrying a token no store issued.
    ///
    /// It is everything the desk decision needs — the record and the parked
    /// bytes — and nothing the QUEUE would honour, so a verdict written against
    /// it is refused and changes nothing. That is exactly right for the cases
    /// whose subject is what lands on the desk; the cases whose subject is what
    /// `recover` records take `armedClaim` instead.
    private static func claim(
        id: UUID,
        destination: PendingRetryDestination = .work,
        transcript: String? = nil,
        publicationState: PendingRetryPublicationState?,
        audio: Data = recordingBytes
    ) -> PendingRetryClaim {
        PendingRetryClaim(
            entry: PendingRetryEntry(
                audioData: audio,
                metadata: metadata(
                    id: id,
                    destination: destination,
                    transcript: transcript,
                    publicationState: publicationState
                ),
                workImageData: nil
            ),
            token: UUID()
        )
    }

    /// A capture armed in THIS case's own queue and reserved through the real
    /// claim API, so the lease token is live and what `recover` records is
    /// readable back off disk.
    private func armedClaim(
        id: UUID = UUID(),
        destination: PendingRetryDestination = .work,
        transcript: String? = nil,
        publicationState: PendingRetryPublicationState?
    ) async throws -> PendingRetryClaim {
        try await queue.save(
            audioData: Self.recordingBytes,
            // Armed NOW, not at the fixture's fixed instant: recording a
            // `.published` verdict makes a Work capture expirable again, and an
            // entry armed in 2023 would be swept before it could be read back.
            metadata: Self.metadata(
                id: id,
                createdAt: Date(),
                destination: destination,
                transcript: transcript,
                publicationState: publicationState
            ),
            workImageData: nil
        )
        let reserved = await queue.claimNext(surface: destination)
        return try XCTUnwrap(reserved, "the capture just armed must be claimable")
    }

    /// What the queue says about one capture now — the durable copy, read back
    /// through the store rather than from the claim the case is holding.
    private func queuedRecord(_ id: UUID) async -> PendingRetryMetadata? {
        await queue.load().first { $0.metadata.id == id }?.metadata
    }

    /// A card of another kind standing at `id`, which is what makes the desk
    /// write refuse a recording published there.
    @discardableResult
    private static func foreignCard(
        at id: UUID,
        in store: ConversationStore,
        bytes: Data = Data(repeating: 0x2A, count: 64)
    ) async throws -> WorkMaterialRecord {
        try await store.upsertDeskMaterial(
            WorkMaterialDraft(
                id: id,
                kind: .image,
                title: "screenshot.jpg",
                filename: "screenshot.jpg",
                mimeType: "image/jpeg",
                payload: bytes
            )
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

/// An in-memory stand-in for the App-Group retry QUEUE, with the same rules the
/// real one has: one entry per capture id, an arm that displaces nothing, a
/// reservation that names its holder, and a clear that removes exactly the
/// capture it names and only for the holder that reserved it.
///
/// The real store is a process-global singleton over one file every capture
/// test in this bundle shares, and what these cases assert is which capture the
/// recorder arms, RESERVES and releases — a property of the recorder, not of the
/// wire format `PendingRetryDestinationTests` and `PendingRetryQueueTests` pin.
///
/// The lease rules mirrored here are the ones the recorder's behaviour depends
/// on, and no others: an id already reserved is refused, a token that does not
/// match writes nothing, and an expiry is a *stealable* reservation rather than
/// a retired one (`PendingRetryLeaseTests` pins the real store's own version).
private actor RecordingRetryLane: PendingRetryLaneReserving {
    private var entries: [(metadata: PendingRetryMetadata, audio: Data)] = []
    private var leases: [UUID: (token: UUID, expiresAt: Date, duration: TimeInterval)] = [:]

    /// Every metadata this lane was ASKED to write, so a test can tell "the
    /// other capture survived untouched" from "it was rewritten in place".
    private(set) var saves: [PendingRetryMetadata] = []

    /// Every reservation this lane granted, newest last, so a case can assert
    /// that a retry reserved before it transcribed rather than after.
    private(set) var reservations: [UUID] = []

    /// Every reservation handed back unfinished, so a case can tell "released"
    /// from "cleared" — the difference between a capture the next tap can take
    /// and one that is gone.
    private(set) var releases: [UUID] = []

    /// Every renewal this lane was asked for, so a case can prove a live retry
    /// keeps extending the hold it took.
    private(set) var renewals: [UUID] = []

    init(seeded: PendingRetryMetadata? = nil, audio: Data = Data()) {
        if let seeded { entries = [(seeded, audio)] }
    }

    /// Pre-reserve a capture for SOMEBODY ELSE, so a case can put the recorder
    /// in front of an entry another surface is already finishing.
    @discardableResult
    func reserveForAnotherSurface(id: UUID, duration: TimeInterval = 600) -> UUID {
        let token = UUID()
        leases[id] = (token, Date().addingTimeInterval(duration), duration)
        return token
    }

    /// FINISH a capture on somebody else's behalf: the entry is retired and its
    /// reservation goes with it, which is what the queue looks like after
    /// another surface completed the recording this one is still working on.
    /// Distinct from `reserveForAnotherSurface` — a held capture is still
    /// queued, and a finished one is not there at all.
    func finishFromAnotherSurface(id: UUID) {
        entries.removeAll { $0.metadata.id == id }
        leases[id] = nil
    }

    /// Whether a reservation is live over this capture right now.
    func isReserved(id: UUID) -> Bool {
        guard let lease = leases[id] else { return false }
        return lease.expiresAt > Date()
    }

    /// Every capture still queued, newest first — the order the real store
    /// answers `load()` in.
    var queued: [PendingRetryMetadata] {
        entries.map(\.metadata).sorted { $0.createdAt > $1.createdAt }
    }

    /// The newest queued capture, for the cases whose subject is a single one.
    var armed: PendingRetryMetadata? { queued.first }

    func entry(id: UUID) -> PendingRetryMetadata? {
        entries.first { $0.metadata.id == id }?.metadata
    }

    func audio(id: UUID) -> Data? {
        entries.first { $0.metadata.id == id }?.audio
    }

    func save(
        audioData: Data,
        metadata: PendingRetryMetadata,
        workImageData: Data?
    ) async throws {
        saves.append(metadata)
        entries.removeAll { $0.metadata.id == metadata.id }
        entries.append((metadata, audioData))
        // A re-arm is a new failure on a capture somebody may still be holding,
        // never a reason to take it away from them — the real store carries the
        // live reservation through `save` for the same reason.
    }

    // MARK: - The reservation half

    func claim(id: UUID, duration: TimeInterval) async -> PendingRetryClaim? {
        guard case .claimed(let claim) = await reserve(id: id, duration: duration) else {
            return nil
        }
        return claim
    }

    /// The three-way answer, which is the one the recorder asks for: an entry
    /// this lane does not hold is ABSENT — the bytes in hand are the only copy —
    /// while one under somebody's live lease must refuse a second transcription.
    /// The default implementation cannot tell them apart, so a double that
    /// models a queue has to say so itself or every refusal reads as absence.
    func reserve(id: UUID, duration: TimeInterval) async -> PendingRetryReservation {
        guard let entry = entries.first(where: { $0.metadata.id == id }) else { return .absent }
        if let lease = leases[id], lease.expiresAt > Date() { return .heldElsewhere }
        let token = UUID()
        leases[id] = (token, Date().addingTimeInterval(duration), duration)
        reservations.append(id)
        return .claimed(PendingRetryClaim(
            entry: PendingRetryEntry(
                audioData: entry.audio,
                metadata: entry.metadata,
                workImageData: nil
            ),
            token: token
        ))
    }

    @discardableResult
    func renew(_ claim: PendingRetryClaim) async -> Bool {
        guard let lease = leases[claim.id], lease.token == claim.token else { return false }
        leases[claim.id] = (
            lease.token, Date().addingTimeInterval(lease.duration), lease.duration
        )
        renewals.append(claim.id)
        return true
    }

    func confirmOwnership(_ claim: PendingRetryClaim) async -> Bool {
        guard entries.contains(where: { $0.metadata.id == claim.id }) else { return false }
        return leases[claim.id]?.token == claim.token
    }

    func release(_ claim: PendingRetryClaim) async {
        guard leases[claim.id]?.token == claim.token else { return }
        leases[claim.id] = nil
        releases.append(claim.id)
    }

    @discardableResult
    func clear(_ claim: PendingRetryClaim) async -> Bool {
        guard leases[claim.id]?.token == claim.token else { return false }
        guard entries.contains(where: { $0.metadata.id == claim.id }) else { return false }
        entries.removeAll { $0.metadata.id == claim.id }
        leases[claim.id] = nil
        return true
    }
}
