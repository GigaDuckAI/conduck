// SPDX-License-Identifier: Apache-2.0

// ConduckTests
// WorkVoiceTranscriptPublicationTests.swift
//
// The seam every Work voice lane writes through, held against the real store.
//
// What it publishes is the founder's rule made physical: a card that is the
// WORDS — no payload, no blob, nothing to sync but text — under the capture's
// own id, naming the picture that same press produced. A recording never
// reaches the desk, so a person who never gets a working speech key never sees
// a half-finished card either.
//
// The hard part is that one capture's words can already be sitting under any of
// THREE ids. A card of another kind standing at an id makes the desk write
// refuse it, and that refusal never clears, so a publication escapes — once to
// `WorkMaterialCollisionEscape.materialID(forCapture:)` and once more to the
// last-resort id. Every later publication of that same capture therefore has to
// SEARCH all three before it inserts anything: the case that catches a
// look-free implementation is the one where the card that caused the escape is
// deleted afterwards, freeing the capture id and inviting a second copy of the
// same words.
//
// The cards earlier builds left behind are the other half. A recording still
// standing takes the words onto itself; a fallback note at the last-resort id
// is these same words under the kind that build had for them, and is answered
// rather than duplicated.
//
// Every case runs against `IsolatedWorkStores()` — a real Core Data store with
// a vault directory this class empties — because what is being asserted is what
// the WRITE does, and a double would only restate the code under test.

#if !os(watchOS)

import XCTest
@testable import Conduck

final class WorkVoiceTranscriptPublicationTests: XCTestCase {

    private let isolated = IsolatedWorkStores()

    override func tearDown() async throws {
        await isolated.cleanUp()
        try await super.tearDown()
    }

    // MARK: - What a words-only card is

    func testACapturesWordsBecomeAMetadataOnlyCardUnderItsOwnId() async throws {
        let store = isolated.make()
        let captureID = UUID()
        let pictureID = WorkVoiceScreenshotCoordinator.materialID(forCapture: captureID)
        let createdAt = Date(timeIntervalSince1970: 1_700_000_000)

        let outcome = try await WorkVoiceCaptureCoordinator.publishTranscript(
            "  Ferry leaves at 07:30\nask about the bikes  ",
            forCapture: captureID,
            createdAt: createdAt,
            sourceDevice: "carplay",
            attachedTo: pictureID,
            store: store
        )

        XCTAssertEqual(outcome, .wordsPublished(materialID: captureID))
        XCTAssertEqual(outcome.materialID, captureID)
        let deskValue = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        let desk = try XCTUnwrap(deskValue)
        XCTAssertEqual(desk.materials.count, 1)
        let card = try XCTUnwrap(desk.materials.first)
        XCTAssertEqual(card.id, captureID, "the capture id, so a replay repairs this card")
        XCTAssertEqual(card.kind, .transcript)
        XCTAssertEqual(card.storageMode, .metadataOnly)
        XCTAssertFalse(
            card.hasPayload,
            """
            MEASURED: no bytes. A compressed voice note is far below the sync ceiling, so a card \
            carrying one rides the person's private CloudKit for ever — which is the waste this \
            whole pipeline exists to end.
            """
        )
        XCTAssertEqual(card.byteSize, 0)
        XCTAssertEqual(card.textContent, "Ferry leaves at 07:30\nask about the bikes")
        XCTAssertEqual(card.title, "Ferry leaves at 07:30", "named from its first line")
        XCTAssertEqual(card.sourceDevice, "carplay", "the surface the words were SPOKEN at")
        XCTAssertEqual(card.attachedToMaterialID, pictureID, "the picture the same press produced")
        XCTAssertEqual(card.createdAt, createdAt)
        let payload = try await store.loadWorkMaterialPayload(id: captureID)
        XCTAssertNil(payload)
    }

    func testACaptureThatSaidNothingButItsFirstLineStillNamesItself() async throws {
        let store = isolated.make()
        let captureID = UUID()

        _ = try await WorkVoiceCaptureCoordinator.publishTranscript(
            "one line only",
            forCapture: captureID,
            createdAt: Date(),
            store: store
        )

        let deskValue = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        XCTAssertEqual(deskValue?.materials.first?.title, "one line only")
        XCTAssertEqual(deskValue?.materials.first?.textContent, "one line only")
    }

    func testACaptureThatStatesNoSurfaceIsStampedWithThisDevice() async throws {
        let store = isolated.make()

        _ = try await WorkVoiceCaptureCoordinator.publishTranscript(
            "said right here",
            forCapture: UUID(),
            createdAt: Date(),
            store: store
        )

        let deskValue = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        XCTAssertEqual(
            deskValue?.materials.first?.sourceDevice, SourceDevice.current,
            "the in-app and intent lanes run where the person spoke, so they state nothing"
        )
    }

    // MARK: - Replay

    func testAReplayAnswersWithTheSameCardAndWritesNothing() async throws {
        let store = isolated.make()
        let captureID = UUID()
        let first = try await WorkVoiceCaptureCoordinator.publishTranscript(
            "said once", forCapture: captureID, createdAt: Date(), store: store
        )
        let firstDesk = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        let published = try XCTUnwrap(firstDesk?.materials.first)

        let second = try await WorkVoiceCaptureCoordinator.publishTranscript(
            "said once", forCapture: captureID, createdAt: Date(), store: store
        )

        XCTAssertEqual(first, second)
        let deskValue = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        let desk = try XCTUnwrap(deskValue)
        XCTAssertEqual(desk.materials.count, 1)
        XCTAssertEqual(
            desk.materials.first?.updatedAt, published.updatedAt,
            """
            MEASURED: nothing was written the second time. The words arrive more than once by \
            design — a retry surface republishes after an interrupted launch — and a rewrite \
            spends a CloudKit round trip advancing the desk's revision under whatever board \
            mutation is in flight.
            """
        )
    }

    /// The case a look-free implementation fails. An earlier publication escaped
    /// a colliding id; the card that blocked it is then deleted, so the capture
    /// id is free again. Inserting at the first free id publishes the same words
    /// twice.
    func testAnEarlierEscapedPublicationIsFoundBeforeAnyInsert() async throws {
        let store = isolated.make()
        let captureID = UUID()
        let escapeID = WorkMaterialCollisionEscape.materialID(forCapture: captureID)
        try await Self.foreignCard(at: captureID, in: store)
        let escaped = try await WorkVoiceCaptureCoordinator.publishTranscript(
            "the ferry leaves at seven", forCapture: captureID, createdAt: Date(), store: store
        )
        XCTAssertEqual(escaped, .wordsPublished(materialID: escapeID), "the fixture must escape")
        try await store.deleteWorkMaterial(id: captureID)

        let replayed = try await WorkVoiceCaptureCoordinator.publishTranscript(
            "the ferry leaves at seven", forCapture: captureID, createdAt: Date(), store: store
        )

        XCTAssertEqual(replayed, .wordsPublished(materialID: escapeID))
        let deskValue = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        let desk = try XCTUnwrap(deskValue)
        XCTAssertEqual(
            Set(desk.materials.map(\.id)), [escapeID],
            "MEASURED: one card. The capture id is free and is deliberately not taken."
        )
    }

    /// The same rule for the id an EARLIER BUILD's fallback note took. It is a
    /// `.note` rather than a `.transcript`, and it is these same words.
    func testAnEarlierFallbackNoteIsFoundBeforeAnyInsert() async throws {
        let store = isolated.make()
        let captureID = UUID()
        let lastResortID = WorkVoiceCaptureCoordinator.fallbackNoteID(forCapture: captureID)
        _ = try await store.upsertDeskMaterial(
            WorkMaterialDraft(
                id: lastResortID,
                kind: .note,
                title: "the ferry leaves at seven",
                textContent: "the ferry leaves at seven",
                storageMode: .metadataOnly
            )
        )

        let outcome = try await WorkVoiceCaptureCoordinator.publishTranscript(
            "the ferry leaves at seven", forCapture: captureID, createdAt: Date(), store: store
        )

        XCTAssertEqual(outcome, .wordsPublished(materialID: lastResortID))
        let deskValue = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        let desk = try XCTUnwrap(deskValue)
        XCTAssertEqual(
            Set(desk.materials.map(\.id)), [lastResortID],
            "MEASURED: the note is answered, not duplicated under the capture id beside it"
        )
        XCTAssertEqual(desk.materials.first?.kind, .note, "…and it is left exactly as it was")
    }

    /// A `.note` anywhere but the last-resort id is SOMEBODY ELSE'S card, and it
    /// has to be escaped rather than adopted — a typed thought sharing an id
    /// with a capture must never silently become that capture's words.
    func testANoteAtTheCaptureIdIsEscapedRatherThanAdopted() async throws {
        let store = isolated.make()
        let captureID = UUID()
        let escapeID = WorkMaterialCollisionEscape.materialID(forCapture: captureID)
        _ = try await store.upsertDeskMaterial(
            WorkMaterialDraft(
                id: captureID,
                kind: .note,
                title: "a thought somebody typed",
                textContent: "a thought somebody typed",
                storageMode: .metadataOnly
            )
        )

        let outcome = try await WorkVoiceCaptureCoordinator.publishTranscript(
            "spoken words that are not that thought",
            forCapture: captureID,
            createdAt: Date(),
            store: store
        )

        XCTAssertEqual(outcome, .wordsPublished(materialID: escapeID))
        let deskValue = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        let desk = try XCTUnwrap(deskValue)
        XCTAssertEqual(Set(desk.materials.map(\.id)), [captureID, escapeID])
        XCTAssertEqual(
            desk.materials.first { $0.id == captureID }?.textContent,
            "a thought somebody typed",
            "the typed note keeps every word of its own"
        )
    }

    // MARK: - Cards an earlier build published

    func testALegacyRecordingAtTheCaptureIdTakesTheWordsOntoItself() async throws {
        let store = isolated.make()
        let captureID = UUID()
        let bytes = Data(repeating: 0x7F, count: 4_096)
        // Written through the desk's own door: nothing in the app publishes a
        // recording any more, so the only way to stand one up is the way an
        // audio file a person attaches gets there.
        _ = try await store.upsertDeskMaterial(
            WorkMaterialDraft(
                id: captureID,
                kind: .audio,
                title: "Voice note",
                filename: "voice-note.m4a",
                mimeType: "audio/mp4",
                payload: bytes,
                byteSize: Int64(bytes.count)
            )
        )

        let outcome = try await WorkVoiceCaptureCoordinator.publishTranscript(
            "the ferry leaves at seven", forCapture: captureID, createdAt: Date(), store: store
        )

        XCTAssertEqual(outcome, .attachedToRecording(materialID: captureID))
        let deskValue = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        let desk = try XCTUnwrap(deskValue)
        XCTAssertEqual(desk.materials.count, 1, "the words go ON the recording, never beside it")
        XCTAssertEqual(desk.materials.first?.kind, .audio)
        XCTAssertEqual(desk.materials.first?.textContent, "the ferry leaves at seven")
        let payload = try await store.loadWorkMaterialPayload(id: captureID)
        XCTAssertEqual(payload, bytes, "a text edit touches no bytes")
    }

    // MARK: - Refusals

    func testATranscriptThatNormalizesToNothingPublishesNothing() async throws {
        let store = isolated.make()

        do {
            _ = try await WorkVoiceCaptureCoordinator.publishTranscript(
                "   \n  ", forCapture: UUID(), createdAt: Date(), store: store
            )
            XCTFail("silence must not become a card")
        } catch let refusal as WorkVoiceCaptureCoordinator.WorkVoiceTranscriptRefusal {
            XCTAssertEqual(refusal, .noWords)
        }
        let desk = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        XCTAssertNil(desk, "not one card, and not even the desk row")
    }

    /// "Cancel transcription" is a promise about the WORDS, and the press can
    /// land AFTER the caller's own check — the claims, the publication lock and
    /// the staging all suspend before the transaction opens. The box the
    /// mutation boundary itself reads is what keeps the promise.
    func testACancelArrivingInsideTheDeskWritePublishesNothing() async throws {
        let store = isolated.make()
        let captureID = UUID()
        let authorization = WorkVoiceWriteAuthorization()
        // Cancelled INSIDE the publication, after its bytes are staged and
        // before any row names them. Nothing observable to a caller stands in
        // this window; the seam is what puts a press in it.
        await store._setWorkMaterialPublicationLockHoldForTesting { _ in
            authorization.cancel()
        }

        do {
            _ = try await WorkVoiceCaptureCoordinator.publishTranscript(
                "words the person took back",
                forCapture: captureID,
                createdAt: Date(),
                authorization: authorization,
                store: store
            )
            XCTFail("a cancel that landed inside the write must not publish a card")
        } catch is CancellationError {
            // Nothing was attempted, so there is no publication to report.
        }

        await store._setWorkMaterialPublicationLockHoldForTesting(nil)
        let desk = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        XCTAssertNil(
            desk,
            """
            MEASURED: the check is INSIDE the transaction. At the entry instead, a press landing \
            in the suspension below it publishes the card anyway and the sentence on screen is \
            the only thing the cancel changed.
            """
        )
    }

    func testACancelAlreadyStandingBeforeTheCallPublishesNothing() async throws {
        let store = isolated.make()
        let authorization = WorkVoiceWriteAuthorization()
        authorization.cancel()

        do {
            _ = try await WorkVoiceCaptureCoordinator.publishTranscript(
                "words the person took back",
                forCapture: UUID(),
                createdAt: Date(),
                authorization: authorization,
                store: store
            )
            XCTFail("a cancelled authorization must not publish a card")
        } catch is CancellationError {
        }
        let desk = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        XCTAssertNil(desk)
    }

    // MARK: - Fixtures

    /// A card of another kind standing at `id`, which is what makes the desk
    /// write refuse a publication there.
    private static func foreignCard(
        at id: UUID,
        in store: ConversationStore,
        bytes: Data = Data(repeating: 0x2A, count: 64)
    ) async throws {
        _ = try await store.upsertDeskMaterial(
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
}

#endif
