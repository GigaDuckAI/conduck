// SPDX-License-Identifier: Apache-2.0

// ConduckTests
// WorkVoiceRecoveryTests.swift
//
// What happens to a Work voice capture that was parked and picked up again —
// in another process, hours later, by a surface that cannot see what the
// capture saw.
//
// The rule these cases hold is the founder's: the words are the artifact, and
// the recording is kept only until they are written. So a recovery publishes
// WORDS, wherever it finds room for them, and a recovery with no words yet
// publishes nothing at all — the desk stays empty and the parked bytes stay
// exactly where the only copy of them was.
//
// The difficulty is an id that is REFUSED rather than answered: a card of
// another kind already stands at the capture's own id, so the desk write throws
// and never stops throwing. The words go under the capture's collision escape
// instead, and then under a last-resort id, and a card already standing at
// EITHER has to be found rather than duplicated — which is the case that fails
// if a publication only ever looks at the capture id.
//
// The cards earlier builds left on people's desks are the other half: a
// recording still standing takes the recovered words onto itself rather than
// acquiring a second card beside it, and one the person deleted is never
// brought back.
//
// The last section is a queue ENTRY's lifetime, asserted through the recorder
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

    // MARK: - recover: the ordinary capture

    /// The state every fresh Work capture is parked in: the desk holds nothing,
    /// and these bytes are the only copy of what was said. The recovery writes
    /// the WORDS and nothing else — no recording ever reaches the board.
    func testACaptureTheDeskHoldsNothingForBecomesAWordsOnlyCard() async throws {
        let store = ConversationStore(inMemory: true)
        let captureID = UUID()

        let outcome = try await WorkVoiceCaptureCoordinator.recover(
            Self.claim(id: captureID, publicationState: .phaseOneFailed),
            transcript: "  Ferry leaves at 07:30\nask about the bikes  ",
            store: store,
            queue: queue
        )

        XCTAssertEqual(outcome, .wordsPublished)
        XCTAssertTrue(outcome.isTerminal, "the words are on the desk; the record may be released")
        let deskValue = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        let desk = try XCTUnwrap(deskValue)
        XCTAssertEqual(desk.materials.count, 1, "one capture, one card")
        let card = try XCTUnwrap(desk.materials.first)
        XCTAssertEqual(card.id, captureID, "the words take the capture's own id, so a replay repairs them")
        XCTAssertEqual(card.kind, .transcript)
        XCTAssertEqual(card.storageMode, .metadataOnly)
        XCTAssertFalse(
            card.hasPayload,
            "the recording is waste the moment the words exist; a card carrying it would sync for ever"
        )
        XCTAssertEqual(card.textContent, "Ferry leaves at 07:30\nask about the bikes")
        XCTAssertEqual(card.title, "Ferry leaves at 07:30", "the card names itself from its first line")
        XCTAssertFalse(
            desk.materials.contains { $0.kind == .audio },
            "MEASURED: no recording reaches the desk, whatever the parked entry carries"
        )
    }

    /// The words were spoken somewhere other than the process publishing them,
    /// which is the whole reason the record carries the value rather than the
    /// writer deriving one.
    func testTheWordsAreStampedWithTheSurfaceTheyWereSpokenAt() async throws {
        let store = ConversationStore(inMemory: true)
        let captureID = UUID()

        _ = try await WorkVoiceCaptureCoordinator.recover(
            Self.claim(
                id: captureID, publicationState: .phaseOneFailed, sourceDevice: "watch"
            ),
            transcript: "said on the wrist",
            store: store,
            queue: queue
        )

        let deskValue = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        XCTAssertEqual(
            deskValue?.materials.first?.sourceDevice, "watch",
            """
            MEASURED: a wrist recording is relayed to the phone and published there, so \
            `SourceDevice.current` at the write would call it an iPhone note.
            """
        )
    }

    // MARK: - recover: a recording an earlier build published

    func testAStandingLegacyRecordingTakesTheRecoveredWordsRatherThanACardBesideIt() async throws {
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
        XCTAssertTrue(outcome.isTerminal)
        let deskValue = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        let desk = try XCTUnwrap(deskValue)
        XCTAssertEqual(
            desk.materials.count, 1,
            """
            One card. Publishing the words BESIDE a recording that is standing leaves a person \
            with something to play and something to read, for one thing they said once.
            """
        )
        let card = try XCTUnwrap(desk.materials.first)
        XCTAssertEqual(card.id, captureID)
        XCTAssertEqual(card.kind, .audio, "a card an earlier build published is left as it is")
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
            "the verdict decides nothing here; what is STANDING on the desk does"
        )
        let deskValue = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        let desk = try XCTUnwrap(deskValue)
        XCTAssertEqual(desk.materials.count, 1)
        XCTAssertEqual(
            desk.materials.first?.textContent,
            "recovered from a record that predates the verdict"
        )
    }

    /// A legacy card the person DELETED while recognition was in flight. The
    /// words still land, as their own card, and nothing brings the recording
    /// back — there is no code left that could.
    func testALegacyRecordingThePersonDeletedIsNotResurrectedByItsWords() async throws {
        let store = ConversationStore(inMemory: true)
        let captureID = UUID()

        let outcome = try await WorkVoiceCaptureCoordinator.recover(
            Self.claim(id: captureID, publicationState: .published),
            transcript: "the words outlive the card",
            store: store,
            queue: queue
        )

        XCTAssertEqual(outcome, .wordsPublished)
        let deskValue = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        let desk = try XCTUnwrap(deskValue)
        XCTAssertEqual(desk.materials.count, 1, "exactly one card: the words, and no revived recording")
        let card = try XCTUnwrap(desk.materials.first)
        XCTAssertEqual(card.id, captureID)
        XCTAssertEqual(card.kind, .transcript)
        XCTAssertFalse(desk.materials.contains { $0.kind == .audio })
    }

    // MARK: - recover: an id that is REFUSED rather than answered

    /// The desk does not ANSWER a colliding id, it throws — and the throw never
    /// stops, because the card of another kind standing there is not going
    /// anywhere. The words go under the capture's collision escape instead, and
    /// the card that was already there is not touched.
    func testACaptureWhoseIdIsTakenLandsItsWordsUnderTheEscape() async throws {
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

        XCTAssertEqual(outcome, .wordsPublished)
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

        let words = try XCTUnwrap(desk.materials.first { $0.id == escapeID })
        XCTAssertEqual(words.kind, .transcript)
        XCTAssertEqual(words.textContent, "Ferry leaves at 07:30\nask about the bikes")
        XCTAssertEqual(words.title, "Ferry leaves at 07:30")

        let untouched = try XCTUnwrap(desk.materials.first { $0.id == captureID })
        XCTAssertEqual(untouched.kind, .image, "the card that was already there is unchanged")
        XCTAssertEqual(untouched.title, picture.title)
        XCTAssertNil(untouched.textContent, "…and never acquires somebody's spoken words")
        let stillItsOwn = try await store.loadWorkMaterialPayload(id: captureID)
        XCTAssertEqual(stillItsOwn, pictureBytes, "…nor loses a byte of its own payload")
    }

    /// The escape is a pure function of the colliding id, so the second process
    /// to reach this capture — or the same one after a crash — answers with the
    /// card it already wrote instead of publishing the words twice.
    func testAReplayOfAnEscapedRecoveryAnswersWithTheSameCard() async throws {
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

        XCTAssertEqual(first, .wordsPublished)
        XCTAssertEqual(second, .wordsPublished)
        let deskValue = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        let desk = try XCTUnwrap(deskValue)
        XCTAssertEqual(
            Set(desk.materials.map(\.id)), [captureID, escapeID],
            "a derived id replayed is an answer; a fresh one each time is a second card"
        )
    }

    /// The end of the line: the capture id and its escape both name cards of
    /// another kind, so the words take the last-resort id. Neither foreign card
    /// is touched, and no fourth id is ever derived.
    func testACaptureRefusedUnderBothIdsTakesTheLastResortId() async throws {
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

        XCTAssertEqual(outcome, .wordsPublished)
        XCTAssertTrue(outcome.isTerminal, "the words are on the desk; nothing more can be done here")
        let lastResortID = WorkVoiceCaptureCoordinator.fallbackNoteID(forCapture: captureID)
        let deskValue = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        let desk = try XCTUnwrap(deskValue)
        XCTAssertEqual(Set(desk.materials.map(\.id)), [captureID, escapeID, lastResortID])
        let words = try XCTUnwrap(desk.materials.first { $0.id == lastResortID })
        XCTAssertEqual(words.kind, .transcript)
        XCTAssertEqual(words.textContent, "the ferry leaves at seven")
        let firstPayload = try await store.loadWorkMaterialPayload(id: captureID)
        let secondPayload = try await store.loadWorkMaterialPayload(id: escapeID)
        XCTAssertEqual(firstPayload, firstBytes, "both cards that were there keep their own bytes")
        XCTAssertEqual(secondPayload, secondBytes)
    }

    /// The state an escape leaves behind, recovered again in another process:
    /// this capture's words are standing under the ESCAPE id. A recovery that
    /// looked only at the capture id would find the foreign card, read it as
    /// "nothing of mine here", and write a SECOND copy of the same words.
    func testALaterRecoveryFindsTheWordsUnderTheEscapeItAlreadyTook() async throws {
        let store = ConversationStore(inMemory: true)
        let captureID = UUID()
        let escapeID = WorkMaterialCollisionEscape.materialID(forCapture: captureID)
        _ = try await Self.foreignCard(at: captureID, in: store)
        let claim = Self.claim(id: captureID, publicationState: .phaseOneFailed)
        _ = try await WorkVoiceCaptureCoordinator.recover(
            claim, transcript: "the ferry leaves at seven", store: store, queue: queue
        )
        // The card that caused the escape is deleted, freeing the capture id.
        try await store.deleteWorkMaterial(id: captureID)

        let outcome = try await WorkVoiceCaptureCoordinator.recover(
            claim, transcript: "the ferry leaves at seven", store: store, queue: queue
        )

        XCTAssertEqual(outcome, .wordsPublished)
        let deskValue = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        let desk = try XCTUnwrap(deskValue)
        XCTAssertEqual(
            Set(desk.materials.map(\.id)), [escapeID],
            """
            MEASURED: the escaped card is FOUND, not duplicated. Inserting at the first FREE id \
            publishes a second copy of the same words the moment the original blocker goes.
            """
        )
    }

    // MARK: - recover: the picture the words belong to

    /// The words name the picture of the ORIGINAL capture, and they say so even
    /// when they had to escape a colliding id.
    ///
    /// The two derivations take different namespaces over the same input. The
    /// words escape to `WorkMaterialCollisionEscape.materialID(forCapture:)` of
    /// the capture id; the picture's card is
    /// `WorkVoiceScreenshotCoordinator.materialID(forCapture:)` of that same
    /// capture id, and a collision on the words' side moves nothing about it.
    func testAnEscapedPublicationStillNamesThePictureOfTheOriginalCapture() async throws {
        let store = ConversationStore(inMemory: true)
        let captureID = UUID()
        _ = try await Self.foreignCard(at: captureID, in: store)
        let escapeID = WorkMaterialCollisionEscape.materialID(forCapture: captureID)
        let pictureID = WorkVoiceScreenshotCoordinator.materialID(forCapture: captureID)

        let outcome = try await WorkVoiceCaptureCoordinator.recover(
            Self.claim(
                id: captureID, publicationState: .phaseOneFailed, attachedTo: pictureID
            ),
            transcript: "the ferry leaves at seven",
            store: store,
            queue: queue
        )

        XCTAssertEqual(outcome, .wordsPublished)
        let deskValue = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        let desk = try XCTUnwrap(deskValue)
        let words = try XCTUnwrap(desk.materials.first { $0.id == escapeID })
        XCTAssertEqual(
            words.attachedToMaterialID, pictureID,
            """
            MEASURED: the card landed under its ESCAPE and still names the picture derived from \
            the capture id it started from. The escape is the words', not the picture's.
            """
        )
        XCTAssertNotEqual(
            words.attachedToMaterialID,
            WorkVoiceScreenshotCoordinator.materialID(forCapture: escapeID),
            """
            NEGATIVE CONTROL: the id a derivation taken from the ESCAPED id would produce. \
            Nothing publishes a card there, so a fold keyed to it would never find a parent.
            """
        )
        XCTAssertNil(
            desk.materials.first { $0.id == captureID }?.attachedToMaterialID,
            "the card that was already standing is not this capture's and gains no link"
        )
    }

    /// The same publication for a capture that carried no picture. Nothing names
    /// anything, which is what makes the case above about the link rather than
    /// about a value that is always written.
    func testAWordsCardWithNoPictureNamesNothing() async throws {
        let store = ConversationStore(inMemory: true)
        let captureID = UUID()

        _ = try await WorkVoiceCaptureCoordinator.recover(
            Self.claim(id: captureID, publicationState: .phaseOneFailed),
            transcript: "the ferry leaves at seven",
            store: store,
            queue: queue
        )

        let deskValue = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        let card = try XCTUnwrap(deskValue?.materials.first { $0.id == captureID })
        XCTAssertNil(
            card.attachedToMaterialID,
            "NEGATIVE CONTROL: no picture was ever taken, so there is nothing to belong to"
        )
    }

    /// The DURABLE record is the authority. A retry surface that states no link
    /// still publishes a linked card, because the link was written when the
    /// capture was parked and travels with the entry — not with the picture
    /// bytes, which the surface has already published and discarded.
    func testAPublicationTakesTheLinkFromTheRecordWhenTheCallerStatesNone() async throws {
        let store = ConversationStore(inMemory: true)
        let captureID = UUID()
        let pictureID = WorkVoiceScreenshotCoordinator.materialID(forCapture: captureID)

        _ = try await WorkVoiceCaptureCoordinator.recover(
            Self.claim(
                id: captureID, publicationState: .phaseOneFailed, attachedTo: pictureID
            ),
            transcript: "the ferry leaves at seven",
            store: store,
            queue: queue
        )

        let deskValue = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        XCTAssertEqual(
            deskValue?.materials.first { $0.id == captureID }?.attachedToMaterialID,
            pictureID,
            """
            MEASURED: no `attachedTo:` was passed and the card is linked anyway. A recovery that \
            could only read a caller's argument would silently unlink every capture recovered \
            from a queue after a relaunch.
            """
        )
    }

    // MARK: - recover: what it records about the capture it finished

    /// The verdict AND the words are stamped the moment the desk holds them. A
    /// crash between this and the caller's clear then costs nothing: the replay
    /// finds the card, buys no second transcription, and writes nothing twice.
    func testAPublicationStampsTheVerdictAndTheWordsOnTheEntry() async throws {
        let store = ConversationStore(inMemory: true)
        let captureID = UUID()
        let claim = try await armedClaim(id: captureID, publicationState: .phaseOneFailed)

        let outcome = try await WorkVoiceCaptureCoordinator.recover(
            claim, transcript: "the ferry leaves at seven", store: store, queue: queue
        )

        XCTAssertEqual(outcome, .wordsPublished)
        let stillWaiting = await queuedRecord(captureID)
        let queued = try XCTUnwrap(stillWaiting, "nothing here clears the entry; the caller does")
        XCTAssertEqual(
            queued.publicationState, .published,
            """
            The desk holds this capture now. Left at `.phaseOneFailed` the entry is exempt from \
            every clock for ever, over bytes that are no longer the only copy of anything.
            """
        )
        XCTAssertEqual(
            queued.transcript, "the ferry leaves at seven",
            "the words the provider was paid for, parked so a replay buys them once"
        )
        XCTAssertFalse(queued.isExemptFromExpiry)
        XCTAssertEqual(
            queued.retryTTL, PendingRetryMetadata.publishedWorkRetryTTL,
            """
            A published Work capture waits on the long budget. On the ten-minute one it is swept \
            before a driver can reach the phone the acknowledgement named.
            """
        )
    }

    /// The crash between the publication and the clear, replayed. Exactly one
    /// card, and the entry is not written into a second time.
    func testAReplayAfterACrashBetweenPublishAndClearWritesNothingTwice() async throws {
        let store = ConversationStore(inMemory: true)
        let captureID = UUID()
        let claim = try await armedClaim(id: captureID, publicationState: .phaseOneFailed)
        let first = try await WorkVoiceCaptureCoordinator.recover(
            claim, transcript: "said once", store: store, queue: queue
        )
        let deskValue = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        let published = try XCTUnwrap(deskValue?.materials.first)

        let second = try await WorkVoiceCaptureCoordinator.recover(
            claim, transcript: "said once", store: store, queue: queue
        )

        XCTAssertEqual(first, .wordsPublished)
        XCTAssertEqual(second, .wordsPublished)
        let replayedValue = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        let replayed = try XCTUnwrap(replayedValue)
        XCTAssertEqual(replayed.materials.count, 1, "the id is the capture's own, so a replay answers")
        XCTAssertEqual(
            replayed.materials.first?.updatedAt, published.updatedAt,
            "MEASURED: the second pass writes nothing at all, so no board revision moves under it"
        )
    }

    /// The words the entry already carries are the ones a surface with none of
    /// its own recovers with. Leaving them there buys the same answer from the
    /// provider a second time, and answers `.noTranscript` over a capture whose
    /// words were never missing.
    func testTheWordsAlreadyParkedFinishACaptureWhenTheSurfaceHasNone() async throws {
        let store = ConversationStore(inMemory: true)
        let captureID = UUID()

        let outcome = try await WorkVoiceCaptureCoordinator.recover(
            Self.claim(
                id: captureID,
                transcript: "the ferry leaves at seven",
                publicationState: .phaseOneFailed
            ),
            transcript: nil,
            store: store,
            queue: queue
        )

        XCTAssertEqual(outcome, .wordsPublished)
        let deskValue = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        let desk = try XCTUnwrap(deskValue)
        XCTAssertEqual(desk.materials.first?.textContent, "the ferry leaves at seven")
    }

    // MARK: - recover: what must NOT be terminal

    func testAStoreThatRefusesTheWriteRethrowsSoTheCallerKeepsItsRetry() async throws {
        let broken = try Self.unusableStore()
        let refuses = await Self.refusesWrites(broken)
        XCTAssertTrue(refuses, "the fixture must actually refuse a desk write")

        do {
            _ = try await WorkVoiceCaptureCoordinator.recover(
                Self.claim(id: UUID(), publicationState: .phaseOneFailed),
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

    /// The state a device with no working speech key stays in: the recording is
    /// parked, the desk is empty, and it STAYS empty. Nothing half-finished
    /// appears on the board, and the bytes are still where the only copy of them
    /// was.
    func testACaptureWithNoWordsKeepsItsRetryAndLeavesTheDeskEmpty() async throws {
        let store = ConversationStore(inMemory: true)
        let captureID = UUID()
        let claim = try await armedClaim(id: captureID, publicationState: .phaseOneFailed)

        let outcome = try await WorkVoiceCaptureCoordinator.recover(
            claim, transcript: "   \n  ", store: store, queue: queue
        )

        XCTAssertEqual(outcome, .retryKept(.noTranscript))
        XCTAssertFalse(
            outcome.isTerminal,
            "recognition still owes this capture its words; releasing the record would lose the bytes"
        )
        let desk = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        XCTAssertNil(
            desk,
            """
            MEASURED: not one card, and not even the desk row. Silence has nothing to publish, \
            and a wordless placeholder is exactly what this pipeline exists to stop showing.
            """
        )
        let stillWaiting = await queuedRecord(captureID)
        let queued = try XCTUnwrap(stillWaiting, "the capture is still waiting")
        XCTAssertEqual(
            queued.publicationState, .phaseOneFailed,
            "the desk holds nothing, so the verdict that protects these bytes is unchanged"
        )
        XCTAssertTrue(queued.isExemptFromExpiry, "…and a clock may not delete the only copy")
        let parked = await self.queue.load().first { $0.metadata.id == captureID }
        XCTAssertEqual(
            parked?.audioData, Self.recordingBytes,
            "MEASURED: the recording is still parked, byte for byte"
        )
    }

    func testOnlyTheWrittenOutcomesReportThemselvesTerminal() {
        XCTAssertTrue(WorkVoiceRecoveryOutcome.wordsPublished.isTerminal)
        XCTAssertTrue(WorkVoiceRecoveryOutcome.attached.isTerminal)
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
        let captureID = try XCTUnwrap(recorder.pendingWorkCapture?.id)
        XCTAssertNil(
            recorder.workRecordingMaterialID,
            "the desk holds nothing for a capture whose words never arrived"
        )
        let parked = await lane.armed
        let armed = try XCTUnwrap(parked, "a capture parks its bytes before the speech hop")
        XCTAssertEqual(armed.id, captureID, "one identity: the capture, the card and the record")

        let result = await recorder.retryWorkCapture()

        XCTAssertEqual(try result.get(), "recovered on the retry")
        XCTAssertEqual(
            recorder.workRecordingMaterialID, captureID,
            "the words are the card, and it stands at the capture's own id"
        )
        let afterRetry = await lane.armed
        XCTAssertNil(
            afterRetry,
            """
            The words are on the desk, so the recording is waste and the entry is \
            gone with it. Leaving the record armed is what makes the retry card \
            offer to buy the same transcript again — and it leaves audio parked \
            on a device after the words it produced have landed.
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
        let captureID = try XCTUnwrap(recorder.pendingWorkCapture?.id)
        let bytesBefore = await lane.audio(id: captureID)
        XCTAssertNotNil(bytesBefore, "the capture parked its bytes before the speech hop")

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
        let captureID = try XCTUnwrap(recorder.pendingWorkCapture?.id)
        XCTAssertEqual(
            reservedDuringHop, [true],
            """
            The FIRST run holds the capture too. Its recording is parked before a \
            single word is asked for — the bytes exist nowhere else — so from \
            that moment the retry card and the menu bar can see the entry, and \
            an unreserved entry is one either of them may start transcribing \
            while this run is doing exactly that.
            """
        )

        _ = await recorder.retryWorkCapture()

        XCTAssertEqual(
            reservedDuringHop, [true, true],
            """
            The retry has to hold the capture while it transcribes. Reserving \
            after the hop protects nothing: the window this closes is exactly \
            the minutes the provider is thinking.
            """
        )
        let reservationsTaken = await lane.reservations
        XCTAssertEqual(
            reservationsTaken, [captureID, captureID],
            "both runs reserved THIS capture, not the newest one"
        )
        let handedBack = await lane.releases
        XCTAssertEqual(
            handedBack, [captureID, captureID],
            """
            EVERY run that ends without finishing the capture gives the hold \
            back at once — the first one as much as the retry. Kept, it is \
            renewed for as long as this recorder lives: the entry stops counting \
            as waiting, the retry card stops drawing the row that offers it, and \
            the recording is unreachable to every other surface.
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
        let captureID = try XCTUnwrap(recorder.pendingWorkCapture?.id)
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
    /// exactly where they were. And when the microphone DOES come up, the
    /// replaced capture is handed back to the queue rather than deleted.
    @MainActor
    func testRecordAgainHandsTheReplacedCaptureBackToTheQueue() async throws {
        let store = ConversationStore(inMemory: true)
        let lane = RecordingRetryLane()
        let recorder = Self.workRecorder(store: store, lane: lane)
        recorder.transcriptionHopForTesting = { _ in .failure(.sttProviderUnreachable) }

        _ = await recorder._finishCaptureForTesting()
        let captureID = try XCTUnwrap(recorder.pendingWorkCapture?.id)
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
        XCTAssertEqual(recorder.pendingWorkCapture?.id, captureID)
        let stillArmed = await lane.armed
        XCTAssertEqual(
            stillArmed?.id, captureID,
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
        let afterReplacement = await lane.entry(id: captureID)
        XCTAssertNotNil(
            afterReplacement,
            """
            MEASURED: Record Again DELETED the recording. Nothing of that capture \
            is on the desk — this lane publishes the words and only the words, \
            and the words are what it never got — so the entry it clears is the \
            only copy of what somebody said. Record Again means "I am not \
            waiting for this one", never "throw it away".
            """
        )
        let bytesAfterReplacement = await lane.audio(id: captureID)
        XCTAssertEqual(
            bytesAfterReplacement, Self.recordingBytes,
            "byte for byte, and it is the retry card that offers it now"
        )
        let handedBack = await lane.isReserved(id: captureID)
        XCTAssertFalse(
            handedBack,
            """
            …and the hold went with it. An entry left reserved by a recorder that \
            has moved on is one no surface can take and none can finish.
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
            recorder.pendingWorkCapture?.id, "phase one still parked the recording"
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
            Set(saves.map(\.id)), [workID],
            "every write names the arriving capture — nothing touched the incumbent"
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
            "two captures, two cards — neither recovery landed on the other's"
        )
        XCTAssertTrue(desk.materials.allSatisfy { $0.kind == .transcript })
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
        // REACHED, and that is the order: the park is a file in the App-Group
        // container, not a desk write, so a store that refuses everything does
        // not stop this capture being transcribed. What it stops is the
        // publication that comes after.
        recorder.transcriptionHopForTesting = { _ in .success("the ferry leaves at seven") }

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
            The desk holds nothing for this capture, and the verdict says so — \
            which is what exempts these bytes from the ten-minute clock that \
            governs a capture the board already has.
            """
        )
        XCTAssertEqual(
            armed.transcript, "the ferry leaves at seven",
            """
            The words were bought and the publication refused them, so they are \
            parked with the bytes. Without this the retry pays a provider a \
            second time for the answer it already has.
            """
        )
    }

    /// The words are bought once. A capture whose publication the desk refused
    /// parks them with its bytes, so a recovery after a kill publishes instead
    /// of paying a provider for the answer it already has.
    @MainActor
    func testAPublicationFailureParksTheWordsAndTheVerdictWithTheCapture() async throws {
        let store = ConversationStore(inMemory: true)
        let broken = try Self.unusableStore()
        let refuses = await Self.refusesWrites(broken)
        XCTAssertTrue(refuses)
        let lane = RecordingRetryLane()
        let recorder = Self.workRecorder(store: store, lane: lane)
        recorder.transcriptionHopForTesting = { [weak recorder] _ in
            // The bytes are parked by now; break the store between the phases so
            // the publication — and only the publication — fails.
            recorder?.workStoreForTesting = broken
            return .success("the ferry leaves at seven")
        }

        _ = await recorder._finishCaptureForTesting()

        let parked = await lane.armed
        let armed = try XCTUnwrap(parked)
        XCTAssertEqual(armed.id, recorder.pendingWorkCapture?.id)
        XCTAssertNil(
            recorder.workRecordingMaterialID,
            "control: the desk refused the words, so no card names them"
        )
        XCTAssertEqual(
            armed.transcript, "the ferry leaves at seven",
            """
            Without this the words die with the process and the same bytes are \
            sent to the provider again for the answer it already gave.
            """
        )
        XCTAssertEqual(
            armed.publicationState, .phaseOneFailed,
            """
            The desk holds nothing for this capture, which is what the verdict has \
            to say: these bytes are still the only copy of what was said, and an \
            entry that claimed otherwise would be swept on the ten-minute clock.
            """
        )
        let stamps = await lane.stamps
        XCTAssertEqual(
            stamps.map(\.transcript), ["the ferry leaves at seven"],
            """
            MEASURED: the words reached the entry only through the failure path. \
            They are parked BEFORE the desk write, so a process death in that gap \
            costs a store round trip and not the transcription.
            """
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
        let captureID = try XCTUnwrap(recorder.pendingWorkCapture?.id)

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
        XCTAssertTrue(
            deskValue?.materials.isEmpty ?? true,
            """
            MEASURED: this run published words for a capture it no longer owned. The surface that \
            claimed it is transcribing the same recording, and whichever of the two finishes last \
            silently replaces the other's answer on one card.
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
        let captureID = try XCTUnwrap(recorder.pendingWorkCapture?.id)

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
        XCTAssertEqual(card.kind, .transcript, "and it is the words-only card, not a recording")
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
        let captureID = try XCTUnwrap(recorder.pendingWorkCapture?.id)
        let armed = await lane.entry(id: captureID)
        XCTAssertNotNil(armed, "control: the first run parked the capture")
        let savesBeforeTheRefusal = await lane.saves.filter { $0.id == captureID }.count
        let releasesBeforeTheRefusal = await lane.releases.filter { $0 == captureID }.count

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
            saveIDs.filter { $0 == captureID }.count, savesBeforeTheRefusal,
            "exactly the writes the first run made; the refusal writes nothing"
        )
        let released = await lane.releases.filter { $0 == captureID }.count
        XCTAssertEqual(
            released, releasesBeforeTheRefusal,
            "there is nothing to hand back — the lapsed claim was dropped before the refusal"
        )
    }

    /// A cancelled transcription leaves the desk EMPTY and the capture in hand.
    ///
    /// "Cancel Transcription" is a promise about the words, and in this lane the
    /// words are the only thing that ever reaches the desk — so a cancel lands
    /// on a capture with nothing published, and it must publish nothing after
    /// the press either. What survives is the parked recording and the Try Again
    /// that can still turn it into a card, which is what the sheet's stopped
    /// state describes.
    func testACancelledTranscriptionLeavesTheDeskEmptyAndKeepsTheCapture() async throws {
        let store = ConversationStore(inMemory: true)
        let lane = RecordingRetryLane()
        let recorder = Self.workRecorder(store: store, lane: lane)

        var deskAtTheHop: [WorkMaterialKind] = []
        recorder.transcriptionHopForTesting = { [weak recorder] _ in
            let desk = try? await store.fetchWorkItem(id: Constants.workboardDeskItemID)
            deskAtTheHop = desk?.materials.map(\.kind) ?? []
            // "Cancel transcription" pressed while the provider is thinking.
            recorder?.cancelProcessing()
            return .success("words nobody is waiting for any more")
        }

        let outcome = await recorder._finishCaptureForTesting()
        guard case .failure(.unknown(let underlying)) = outcome, underlying is CancellationError else {
            return XCTFail("a cancelled transcription answers as a cancellation, with no banner")
        }
        XCTAssertEqual(
            deskAtTheHop, [],
            "control: nothing of this capture was on the desk when the press landed"
        )
        XCTAssertTrue(
            recorder.canRetryWorkCapture,
            "the capture is retained, and its Try Again is what finishes it"
        )
        let deskValue = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        XCTAssertTrue(
            deskValue?.materials.isEmpty ?? true,
            """
            MEASURED: a withdrawn request put a card on the board anyway. The press is a promise \
            about the words, and the words are the whole of what this lane publishes.
            """
        )
        XCTAssertFalse(
            recorder.workCaptureFacts.wordsOnDesk,
            "and the receipt says so — nothing landed"
        )
        let stillParked = await lane.entry(id: try XCTUnwrap(recorder.pendingWorkCapture?.id))
        XCTAssertNotNil(
            stillParked,
            "…while the recording, which is the only copy of what was said, is waiting for it"
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
        publicationState: PendingRetryPublicationState?,
        attachedTo: UUID? = nil,
        sourceDevice: String? = nil
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
            publicationState: publicationState,
            workAttachedToMaterialID: attachedTo,
            sourceDevice: sourceDevice
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
        audio: Data = recordingBytes,
        attachedTo: UUID? = nil,
        sourceDevice: String? = nil
    ) -> PendingRetryClaim {
        PendingRetryClaim(
            entry: PendingRetryEntry(
                audioData: audio,
                metadata: metadata(
                    id: id,
                    destination: destination,
                    transcript: transcript,
                    publicationState: publicationState,
                    attachedTo: attachedTo,
                    sourceDevice: sourceDevice
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

    /// A recording on the desk, as an EARLIER BUILD published it. Nothing in
    /// the app writes one any more — the coordinator has no function that
    /// could — so the fixture goes through the desk's own door, exactly as an
    /// audio file a person attaches does. The cases that use it are about the
    /// cards those builds left behind on people's desks.
    @discardableResult
    private static func publish(
        captureID: UUID,
        in store: ConversationStore
    ) async throws -> WorkMaterialRecord {
        try await store.upsertDeskMaterial(
            WorkMaterialDraft(
                id: captureID,
                kind: .audio,
                title: "Voice note",
                filename: "voice-note.m4a",
                mimeType: "audio/mp4",
                payload: recordingBytes,
                byteSize: Int64(recordingBytes.count)
            )
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

    /// Every verdict written onto an entry through its reservation, newest
    /// last, so a case can tell words parked BEFORE a desk write from words
    /// that only reached the record after it failed.
    private(set) var stamps: [(id: UUID, transcript: String?, state: PendingRetryPublicationState)] = []

    /// Every capture whose RECORDING was retired while its entry stayed, so a
    /// case can prove the audio does not outlive the words it produced.
    private(set) var retiredRecordings: [UUID] = []

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

    /// Metadata only, and under the lease like every other write here: the
    /// recording is not touched and no other capture is read back. The real
    /// store's `recording(transcript:publicationState:)` keeps what a nil
    /// argument does not state, and so does this.
    @discardableResult
    func recordPublicationState(
        _ claim: PendingRetryClaim,
        transcript: String?,
        publicationState: PendingRetryPublicationState
    ) async -> Bool {
        guard leases[claim.id]?.token == claim.token else { return false }
        guard let index = entries.firstIndex(where: { $0.metadata.id == claim.id }) else {
            return false
        }
        entries[index].metadata = entries[index].metadata.recording(
            transcript: transcript, publicationState: publicationState
        )
        stamps.append((claim.id, transcript, publicationState))
        return true
    }

    /// The recording alone. The entry, its record and its parked picture stay —
    /// which is the whole point: the picture may be the only copy of itself,
    /// and the audio is waste the moment the words land.
    @discardableResult
    func retireRecording(_ claim: PendingRetryClaim) async -> Bool {
        guard leases[claim.id]?.token == claim.token else { return false }
        guard let index = entries.firstIndex(where: { $0.metadata.id == claim.id }) else {
            return false
        }
        entries[index].metadata = entries[index].metadata.recording(
            transcript: nil, publicationState: .published
        )
        entries[index].audio = Data()
        retiredRecordings.append(claim.id)
        return true
    }
}
