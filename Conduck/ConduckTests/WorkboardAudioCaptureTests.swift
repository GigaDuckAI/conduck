// SPDX-License-Identifier: Apache-2.0

// ConduckTests
// WorkboardAudioCaptureTests.swift
//
// The Work voice capture, end to end. Its whole claim is an ordering one — the
// recording is PARKED and the desk is left EMPTY until speech recognition
// answers — so what these cases hold is that the only card a capture produces
// is its words, that it lands under the capture's own id, and that a
// transcription which never succeeds leaves the desk untouched and the
// recording waiting in the device-local retry queue.
//
// The ordering is asserted from INSIDE the recorder: a stub speech hop stands
// where the provider does and reads the desk back before it answers, so nothing
// here depends on how the source is spelled. The same stub proves the other
// half — a capture the queue refused is a retryable error the person can
// finish, never a quiet fall back to typing the words into a composer.
//
// The SEAM's own rules — which of three candidate ids a publication takes, what
// happens to a legacy recording still standing at one of them, what a cancel
// arriving inside the write does — are held next door in
// `WorkVoiceTranscriptPublicationTests` and `WorkVoiceRecoveryTests`, against a
// real store. What is here is the lane around it.

import XCTest
@testable import Conduck

final class WorkboardAudioCaptureTests: XCTestCase {

    // MARK: - The only card a capture makes is its words

    func testACapturesWordsBecomeAMetadataOnlyCardUnderItsOwnId() async throws {
        let store = ConversationStore(inMemory: true)
        let captureID = UUID()
        let pictureID = UUID()

        let outcome = try await WorkVoiceCaptureCoordinator.publishTranscript(
            "  Ferry leaves at 07:30\nask about the bikes  ",
            forCapture: captureID,
            createdAt: Date(),
            sourceDevice: "carplay",
            attachedTo: pictureID,
            store: store
        )

        XCTAssertEqual(
            outcome, .wordsPublished(materialID: captureID),
            "the capture's id IS the card's id, which is what makes a replay idempotent"
        )
        let deskValue = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        let desk = try XCTUnwrap(deskValue)
        XCTAssertEqual(desk.materials.map(\.id), [captureID])
        let card = try XCTUnwrap(desk.materials.first)

        XCTAssertEqual(card.kind, .transcript, "a spoken Work note is its words, not its audio")
        XCTAssertEqual(card.workItemID, Constants.workboardDeskItemID)
        XCTAssertEqual(
            card.storageMode, .metadataOnly,
            "there are no bytes to lane: nothing about this card rides CloudKit as a blob"
        )
        XCTAssertFalse(
            card.hasPayload,
            """
            MEASURED: the capture published a payload. A compressed voice note is far below the \
            sync ceiling, so a card that owns one syncs the person's voice to their private \
            CloudKit and keeps it there for ever — which is the whole thing this lane exists to \
            stop.
            """
        )
        XCTAssertEqual(card.textContent, "Ferry leaves at 07:30\nask about the bikes")
        XCTAssertEqual(
            card.title, "Ferry leaves at 07:30",
            "the card takes the transcript's first line, the same shape a captured thought does"
        )
        XCTAssertEqual(
            card.sourceDevice, "carplay",
            "the surface the words were SPOKEN at, not the process that wrote them"
        )
        XCTAssertEqual(
            card.attachedToMaterialID, pictureID,
            "the words name the picture the same press produced, which is what folds the two"
        )
        XCTAssertNil(card.mimeType, "nothing here describes a file, because there is no file")
    }

    func testReplayingOneCaptureReturnsTheSameCardWithoutASecondRow() async throws {
        let store = ConversationStore(inMemory: true)
        let captureID = UUID()

        let first = try await Self.publish(captureID: captureID, in: store)
        let deskAfterFirstValue = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        let deskAfterFirst = try XCTUnwrap(deskAfterFirstValue)
        let second = try await Self.publish(captureID: captureID, in: store)

        XCTAssertEqual(first, second, "a replay answers with the card it already wrote")
        let rows = await store._workMaterialRowsForTesting(id: captureID)
        XCTAssertEqual(rows.count, 1, "one logical card, one physical row")
        let deskValue = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        let desk = try XCTUnwrap(deskValue)
        XCTAssertEqual(desk.materials.count, 1)
        XCTAssertEqual(
            desk.updatedAt, deskAfterFirst.updatedAt,
            """
            A replay that rewrote the card would spend a CloudKit round trip on identical bytes \
            and advance the desk's revision under whatever board mutation is in flight.
            """
        )
    }

    func testTheCardRemembersTheSurfaceTheWordsWereSpokenAtRatherThanTheOneThatWroteThem()
        async throws
    {
        let store = ConversationStore(inMemory: true)

        // A relayed capture: the wrist recorded it, the phone publishes it.
        // Reading the writer's own device here would file every watch note
        // under the iPhone that happened to be nearby.
        let relayedID = UUID()
        _ = try await WorkVoiceCaptureCoordinator.publishTranscript(
            "the ferry leaves at seven",
            forCapture: relayedID,
            createdAt: Date(),
            sourceDevice: "watch",
            store: store
        )

        // Every lane that DOES run where the person spoke keeps saying so
        // without spelling it, so the default cannot drift away from the value
        // the rest of the desk stamps.
        let localID = UUID()
        _ = try await Self.publish(captureID: localID, in: store)

        let deskValue = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        let desk = try XCTUnwrap(deskValue)
        XCTAssertEqual(
            desk.materials.first(where: { $0.id == relayedID })?.sourceDevice, "watch"
        )
        XCTAssertEqual(
            desk.materials.first(where: { $0.id == localID })?.sourceDevice,
            SourceDevice.current,
            "an omitted surface still names the device the capture ran on"
        )
        XCTAssertEqual(
            Set(desk.materials.compactMap(\.sourceDevice)),
            ["watch", SourceDevice.current],
            "the stamp survives the write; it is not a value the read path re-derives"
        )
    }

    // MARK: - A transcription that never arrives

    /// The failure the whole ordering exists for. Nothing is on the desk, the
    /// recording is in the device-local queue, and the queue's own clock is
    /// waived for it — because those bytes are the only copy of what somebody
    /// said and no timer may decide to be rid of them.
    func testAFailedTranscriptionLeavesTheDeskEmptyAndTheRecordingParked() async throws {
        let store = ConversationStore(inMemory: true)
        let captureID = UUID()

        // Transcription failed, was refused or was abandoned: nothing calls the
        // seam at all, which is the whole of what a capture does to the desk.
        let deskValue = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        XCTAssertNil(
            deskValue,
            """
            MEASURED: a capture whose words never arrived left a card behind. Under the old \
            ordering that card was the recording itself, playable and syncing, and it stayed on \
            the board however many times the transcription failed.
            """
        )

        // The record that IS written is the parked one, and it says the desk
        // holds nothing — the reading every clock and every discard consults.
        let parked = PendingRetryMetadata(
            id: captureID,
            createdAt: Date(),
            audioFileURL: URL(fileURLWithPath: "/dev/null"),
            preferredLanguage: nil,
            attemptCount: 0,
            lastErrorCode: AppError.sttProviderUnreachable.errorCode,
            destination: .work,
            publicationState: .phaseOneFailed
        )
        XCTAssertTrue(
            parked.isExemptFromExpiry,
            "the only copy of what somebody said is not a thing a ten-minute clock may retire"
        )
        XCTAssertNil(parked.retryTTL, "exempt is not a longer clock; it is no clock")

        // …and the retry that succeeds an hour later publishes the words, once.
        let recovered = try await WorkVoiceCaptureCoordinator.publishTranscript(
            "the words that arrived late",
            forCapture: captureID,
            createdAt: parked.createdAt,
            store: store
        )
        XCTAssertEqual(recovered, .wordsPublished(materialID: captureID))
        let repairedValue = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        let repaired = try XCTUnwrap(repairedValue)
        XCTAssertEqual(repaired.materials.count, 1)
        XCTAssertEqual(repaired.materials.first?.kind, .transcript)
        XCTAssertEqual(repaired.materials.first?.textContent, "the words that arrived late")
    }

    /// CloudKit cannot enforce Core Data uniqueness, so two offline devices can
    /// import one logical card as several physical rows and the canonical read
    /// picks the newest. A writer that touched only the row it fetched first
    /// would look correct through that read and lose the words the moment the
    /// other row won.
    ///
    /// The path under test is the LEGACY one: a recording an earlier build put
    /// on the desk, which the seam writes the words onto rather than publishing
    /// a second card beside it.
    func testTheTranscriptReachesEveryPhysicalRowOfADuplicatedLegacyRecording() async throws {
        let store = ConversationStore(inMemory: true)
        let captureID = UUID()
        _ = try await Self.publishLegacyRecording(captureID: captureID, in: store)
        // NEWER than the row the seed wrote: with equal stamps the read would
        // pick the touched row anyway and prove nothing.
        await store._duplicateWorkMaterialRowForTesting(
            id: captureID,
            updatedAt: Date().addingTimeInterval(600)
        )
        let seededRows = await store._workMaterialRowsForTesting(id: captureID)
        XCTAssertEqual(seededRows.count, 2, "the fixture must actually be two physical rows")

        let outcome = try await WorkVoiceCaptureCoordinator.publishTranscript(
            "the ferry leaves at seven", forCapture: captureID, createdAt: Date(), store: store
        )
        XCTAssertEqual(outcome, .attachedToRecording(materialID: captureID))

        let rows = await store._workMaterialRowsForTesting(id: captureID)
        XCTAssertEqual(rows.count, 2, "a text edit adds no rows and removes none")
        for row in rows {
            XCTAssertEqual(
                row.textContent, "the ferry leaves at seven",
                "every physical row carries the words, whichever one the read picks"
            )
            XCTAssertEqual(row.title, "the ferry leaves at seven")
        }
        let deskValue = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        let desk = try XCTUnwrap(deskValue)
        XCTAssertEqual(desk.materials.count, 1, "still ONE logical card")
        XCTAssertEqual(desk.materials.first?.textContent, "the ferry leaves at seven")
    }

    /// The words arrive more than once by design — every retry surface
    /// republishes under the same id — so an identical second delivery onto a
    /// legacy recording must be a defined no-op: no save, no desk bump.
    func testAnIdenticalSecondDeliveryOntoALegacyRecordingWritesNothing() async throws {
        let store = ConversationStore(inMemory: true)
        let captureID = UUID()
        _ = try await Self.publishLegacyRecording(captureID: captureID, in: store)
        _ = try await WorkVoiceCaptureCoordinator.publishTranscript(
            "the ferry leaves at seven", forCapture: captureID, createdAt: Date(), store: store
        )
        let firstRows = await store._workMaterialRowsForTesting(id: captureID)
        let deskValueAfterFirst = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        let deskAfterFirst = try XCTUnwrap(deskValueAfterFirst)

        let outcome = try await WorkVoiceCaptureCoordinator.publishTranscript(
            "the ferry leaves at seven", forCapture: captureID, createdAt: Date(), store: store
        )

        XCTAssertEqual(
            outcome, .attachedToRecording(materialID: captureID),
            "the words are on the card; that is the answer"
        )
        let secondRows = await store._workMaterialRowsForTesting(id: captureID)
        XCTAssertEqual(
            secondRows.map(\.updatedAt), firstRows.map(\.updatedAt),
            "no row was rewritten, so no row's stamp moved"
        )
        let deskValueAfterSecond = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        let deskAfterSecond = try XCTUnwrap(deskValueAfterSecond)
        XCTAssertEqual(
            deskAfterSecond.updatedAt, deskAfterFirst.updatedAt,
            "the desk's own revision must not advance for a write that did not happen"
        )

        // …and a DIFFERENT transcript for the same recording still lands.
        let corrected = try await WorkVoiceCaptureCoordinator.publishTranscript(
            "the ferry leaves at seven thirty",
            forCapture: captureID,
            createdAt: Date(),
            store: store
        )
        XCTAssertEqual(corrected, .attachedToRecording(materialID: captureID))
        let deskValue = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        XCTAssertEqual(
            deskValue?.materials.first?.textContent, "the ferry leaves at seven thirty",
            "the no-op is about identical values, not about refusing a second write"
        )
    }

    /// The Shortcuts lane reuses its capture id as the id of the screenshot it
    /// imports, so a capture id CAN already name a card that is not this
    /// capture's. Those words must not be written onto the picture, and they
    /// must not be dropped either: they take the escape id.
    func testAScreenshotStandingAtTheCaptureIdSendsTheWordsToTheEscapeId() async throws {
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
        let seededDesk = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        let before = try XCTUnwrap(seededDesk?.materials.first)

        let outcome = try await WorkVoiceCaptureCoordinator.publishTranscript(
            "spoken words that belong to a different capture",
            forCapture: captureID,
            createdAt: Date(),
            store: store
        )

        let escapeID = WorkMaterialCollisionEscape.materialID(forCapture: captureID)
        XCTAssertEqual(outcome, .wordsPublished(materialID: escapeID))
        let deskValue = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        let desk = try XCTUnwrap(deskValue)
        let picture = try XCTUnwrap(desk.materials.first { $0.id == captureID })
        XCTAssertEqual(picture.kind, .image, "the screenshot stays a screenshot")
        XCTAssertNil(picture.textContent)
        XCTAssertEqual(picture.title, "screenshot.jpg")
        XCTAssertEqual(
            picture.updatedAt, before.updatedAt,
            "the card that was standing is not touched at all"
        )
        let words = try XCTUnwrap(desk.materials.first { $0.id == escapeID })
        XCTAssertEqual(words.kind, .transcript)
        XCTAssertEqual(words.textContent, "spoken words that belong to a different capture")
    }

    // MARK: - The capture id names the words

    func testTheRetryPublishesTheWordsUnderTheCaptureIdTheRecordCarries() async throws {
        let store = ConversationStore(inMemory: true)
        // The pending-retry record carries the capture's id, which is the id the
        // words card takes — this is exactly what the retry surface passes.
        let pendingRetryID = UUID()

        let outcome = try await WorkVoiceCaptureCoordinator.publishTranscript(
            "recovered on the second attempt",
            forCapture: pendingRetryID,
            createdAt: Date(),
            store: store
        )
        XCTAssertEqual(outcome, .wordsPublished(materialID: pendingRetryID))

        let deskValue = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        let desk = try XCTUnwrap(deskValue)
        XCTAssertEqual(desk.materials.count, 1, "the retry never duplicates the capture")
        let card = try XCTUnwrap(desk.materials.first)
        XCTAssertEqual(card.id, pendingRetryID)
        XCTAssertEqual(card.kind, .transcript)
        XCTAssertEqual(card.textContent, "recovered on the second attempt")
        XCTAssertFalse(card.hasPayload, "a retry publishes words, never the bytes it recovered")
    }

    /// The LAST-RESORT id, and it cannot use the capture id: a material id names
    /// ONE card, so a card published at an id already naming another kind is
    /// refused as the collision it is, and the publication carrying those words
    /// would fail on every attempt with nowhere else to put them.
    func testTheFallbackNoteIdIsDerivedFromTheCaptureAndCannotCollideWithIt() async throws {
        let captureID = UUID(uuidString: "9F2C7A10-4B31-4E52-9A77-0C1D5E6F8A03")!
        let derived = WorkVoiceCaptureCoordinator.fallbackNoteID(forCapture: captureID)

        XCTAssertNotEqual(derived, captureID, "a last-resort card must not land on the first id")
        XCTAssertEqual(
            derived, WorkVoiceCaptureCoordinator.fallbackNoteID(forCapture: captureID),
            "derived, not random: a replayed retry has to reach the card it already published"
        )
        XCTAssertEqual(
            derived.uuidString, "D08E8FB3-6044-50B7-BCFD-3E88E0770438",
            """
            The derivation is a wire value in all but name — two devices \
            replaying one capture must reach the same id, so a change here \
            duplicates every offline retry.
            """
        )
        XCTAssertNotEqual(
            derived,
            WorkVoiceCaptureCoordinator.fallbackNoteID(forCapture: UUID()),
            "different captures, different last-resort ids"
        )

        // …and the collision it exists to avoid is real: a note published under
        // an id a recording already holds is REFUSED by the desk.
        let store = ConversationStore(inMemory: true)
        let recording = try await Self.publishLegacyRecording(captureID: captureID, in: store)
        do {
            _ = try await store.upsertDeskMaterial(
                WorkMaterialDraft(
                    id: captureID,
                    kind: .note,
                    title: "recovered on the second attempt",
                    textContent: "recovered on the second attempt",
                    storageMode: .metadataOnly
                )
            )
            XCTFail("a note at the recording's own id must not be written")
        } catch WorkboardStoreError.invalidMaterialOwner {
            // The desk refuses an id that already names a card of another kind.
        }
        let deskAfterCollision = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        let afterCollision = try XCTUnwrap(
            deskAfterCollision?.materials.first { $0.id == captureID }
        )
        XCTAssertEqual(afterCollision.kind, .audio, "the recording is untouched")
        XCTAssertNil(afterCollision.textContent, "and the words the note carried went nowhere")
        XCTAssertEqual(afterCollision.id, recording.id)

        let fallback = try await store.upsertDeskMaterial(
            WorkMaterialDraft(
                id: derived,
                kind: .note,
                title: "recovered on the second attempt",
                textContent: "recovered on the second attempt",
                storageMode: .metadataOnly
            )
        )
        XCTAssertEqual(fallback.kind, .note, "under the derived id the words reach the desk")
        XCTAssertEqual(fallback.textContent, "recovered on the second attempt")
        let deskValue = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        XCTAssertEqual(deskValue?.materials.count, 2)
    }

    // MARK: - The recorder's own orchestration

    /// The ordering claim, asserted from inside the recorder rather than from
    /// how its source is spelled: the stub speech hop stands exactly where the
    /// provider does, and when it is called the DESK IS EMPTY and the queue is
    /// holding the recording.
    ///
    /// Both halves matter. An empty desk alone would also describe a capture
    /// that lost its bytes; bytes in the queue alone would also describe the old
    /// order, where a playable card was already syncing beside them.
    @MainActor
    func testTranscriptionBeginsOnlyAfterTheRecordingIsParkedAndTheDeskIsEmpty() async throws {
        let store = ConversationStore(inMemory: true)
        let lane = ParkingRetryLane()
        let recorder = InAppAudioRecorder(retryDestination: .work)
        recorder.workStoreForTesting = store
        recorder.retryLaneForTesting = lane
        recorder.capturedAudioForTesting = Self.recordingBytes

        var hopRan = false
        var fileExistedAtTheHop = false
        var deskAtTheHop: Int?
        var parkedAtTheHop: [Data] = []
        recorder.transcriptionHopForTesting = { url in
            hopRan = true
            fileExistedAtTheHop = FileManager.default.fileExists(atPath: url.path)
            let desk = try? await store.fetchWorkItem(id: Constants.workboardDeskItemID)
            deskAtTheHop = desk?.materials.count ?? 0
            parkedAtTheHop = await lane.parkedAudio()
            return .success("the ferry leaves at seven")
        }

        let result = await recorder._finishCaptureForTesting()

        XCTAssertTrue(hopRan, "the stub must actually stand in the production path")
        XCTAssertTrue(fileExistedAtTheHop, "the provider is handed a file that exists")
        XCTAssertEqual(
            deskAtTheHop, 0,
            """
            MEASURED: the desk already held this capture when transcription began. That card was \
            the recording itself — playable, and riding the person's private CloudKit for ever — \
            and nothing about a transcription that had not happened yet justified it.
            """
        )
        XCTAssertEqual(
            parkedAtTheHop, [Self.recordingBytes],
            "…and the bytes are already in the device-local queue, not merely in memory"
        )

        XCTAssertEqual(try result.get(), "the ferry leaves at seven")
        let materialID = try XCTUnwrap(recorder.workRecordingMaterialID)
        let deskValue = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        let desk = try XCTUnwrap(deskValue)
        XCTAssertEqual(desk.materials.count, 1, "one capture, one card")
        let card = try XCTUnwrap(desk.materials.first)
        XCTAssertEqual(card.id, materialID)
        XCTAssertEqual(card.kind, .transcript, "and the card is the words")
        XCTAssertFalse(card.hasPayload)
        XCTAssertEqual(card.textContent, "the ferry leaves at seven")
        let parkedNow = await lane.parkedAudio()
        XCTAssertEqual(
            parkedNow, [],
            "the recording goes the moment the words are durable somewhere else"
        )
        XCTAssertFalse(
            recorder.canRetryWorkCapture,
            "a capture whose words are on the desk owes nothing and offers no retry"
        )
    }

    /// The failure the ordering exists for. The recorder's own temporary copy is
    /// cleaned on the way out — a partial or abandoned one would sit in the
    /// scratch directory for a day — while the QUEUE's copy, parked before the
    /// hop, survives it. The desk is left exactly as it was: empty.
    @MainActor
    func testAFailedTranscriptionCleansTheTemporaryFileAndLeavesTheRecordingParked() async throws {
        let store = ConversationStore(inMemory: true)
        let lane = ParkingRetryLane()
        let recorder = InAppAudioRecorder(retryDestination: .work)
        recorder.workStoreForTesting = store
        recorder.retryLaneForTesting = lane
        recorder.capturedAudioForTesting = Self.recordingBytes

        var temporaryURL: URL?
        var fileExistedAtTheHop = false
        recorder.transcriptionHopForTesting = { url in
            temporaryURL = url
            fileExistedAtTheHop = FileManager.default.fileExists(atPath: url.path)
            return .failure(.sttProviderUnreachable)
        }

        let result = await recorder._finishCaptureForTesting()

        XCTAssertTrue(fileExistedAtTheHop, "the provider is handed a file that exists")
        guard case .failure(let error) = result else {
            return XCTFail("a refused transcription is a failure, not a transcript")
        }
        XCTAssertEqual(error.errorCode, AppError.sttProviderUnreachable.errorCode)
        let temporary = try XCTUnwrap(temporaryURL)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: temporary.path),
            "the recorder's own copy is removed on the way out, on every path"
        )

        let deskValue = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        XCTAssertNil(
            deskValue,
            "a capture whose words never arrived leaves NOTHING on the desk — not even a row"
        )
        XCTAssertNil(recorder.workRecordingMaterialID, "no card, so no id to report")
        let parkedNow = await lane.parkedAudio()
        XCTAssertEqual(
            parkedNow, [Self.recordingBytes],
            "the queue's copy is its own, and outlives the file the hop was given"
        )
        XCTAssertTrue(
            recorder.canRetryWorkCapture,
            "the capture still owes its words, so it is the retry's subject"
        )
        let capture = try XCTUnwrap(recorder.pendingWorkCapture)
        let parkedIDsNow = await lane.parkedIDs()
        XCTAssertEqual(
            parkedIDsNow, [capture.id],
            """
            ONE identity for the capture: the pending capture's id is the id the retry lane \
            carries, which is the id the words card will take. A second UUID anywhere in that \
            chain is what makes recovered words unable to find the capture they came from.
            """
        )
    }

    /// "Cancel transcription" is a promise about the WRITE, not about the
    /// provider. The request is already out and cannot be recalled, so what the
    /// press cancels is the RESULT — and a result that happens to be a success
    /// is the one the promise is hardest to keep and easiest to break: it used
    /// to walk past every check into the desk write and publish words the person
    /// had already stopped waiting for.
    ///
    /// The recording stays PARKED, because the press was aimed at the words and
    /// those bytes are the only copy of them.
    ///
    /// The uncancelled control at the end is what stops this passing on a
    /// pipeline that simply writes nothing.
    @MainActor
    func testCancellingTheTranscriptionKeepsTheRecordingAndRefusesTheWords() async throws {
        let store = ConversationStore(inMemory: true)
        let lane = ParkingRetryLane()
        let recorder = InAppAudioRecorder(retryDestination: .work)
        recorder.workStoreForTesting = store
        recorder.retryLaneForTesting = lane
        recorder.capturedAudioForTesting = Self.recordingBytes

        var parkedAtThePress: [Data] = []
        recorder.transcriptionHopForTesting = { [weak recorder] _ in
            // The press lands while the provider is working — which is the only
            // window this control exists for. The recording is parked by then;
            // the words are the one thing still owed.
            parkedAtThePress = await lane.parkedAudio()
            recorder?.cancelProcessing()
            return .success("the words nobody waited for")
        }

        let result = await recorder._finishCaptureForTesting()

        XCTAssertEqual(
            parkedAtThePress, [Self.recordingBytes],
            "control: the press really did land mid-hop, with the recording already parked"
        )
        guard case .failure(let surfaced) = result else {
            return XCTFail("a cancelled transcription must not report the words settled")
        }
        guard case .unknown(let underlying) = surfaced, underlying is CancellationError else {
            return XCTFail("the answer is a cancellation, not an error about the desk")
        }

        let deskValue = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        XCTAssertNil(
            deskValue,
            """
            MEASURED: the transcript of a CANCELLED run reached the desk anyway. The success arm \
            asked nothing about cancellation, so the only check that ran was the one after the \
            write — which changes what the person is told and not what the desk holds.
            """
        )
        let parkedNow = await lane.parkedAudio()
        XCTAssertEqual(
            parkedNow, [Self.recordingBytes],
            "…and the recording is untouched: the press was aimed at the words"
        )

        // CONTROL: the identical run with nobody pressing anything finishes and
        // publishes, so the assertion above is about the cancel and not about a
        // desk write that never runs.
        let controlStore = ConversationStore(inMemory: true)
        let control = InAppAudioRecorder(retryDestination: .work)
        control.workStoreForTesting = controlStore
        control.retryLaneForTesting = ParkingRetryLane()
        control.capturedAudioForTesting = Self.recordingBytes
        control.transcriptionHopForTesting = { _ in .success("the words somebody waited for") }
        let controlResult = await control._finishCaptureForTesting()
        XCTAssertEqual(try controlResult.get(), "the words somebody waited for")
        let controlDesk = try await controlStore.fetchWorkItem(id: Constants.workboardDeskItemID)
        XCTAssertEqual(
            controlDesk?.materials.first?.textContent, "the words somebody waited for",
            "control: an uncancelled success does reach the desk"
        )
    }

    /// The same promise, one step later: the press lands AFTER the words are
    /// bought and BEFORE they are written.
    ///
    /// The check `settle` takes cannot see this one — it has already run. The
    /// publication then suspends twice (the store's first-use load, and its own
    /// queued write), and a card written under a cancel that landed in there is
    /// words arriving on a capture the person let go of. "Cancel transcription"
    /// is a promise about the WRITE, so the authorization has to reach the write
    /// boundary itself.
    @MainActor
    func testCancellingAfterTheWordsArriveStillKeepsThemOffTheDesk() async throws {
        let store = ConversationStore(inMemory: true)
        let lane = ParkingRetryLane()
        let recorder = InAppAudioRecorder(retryDestination: .work)
        recorder.workStoreForTesting = store
        recorder.retryLaneForTesting = lane
        recorder.capturedAudioForTesting = Self.recordingBytes
        recorder.transcriptionHopForTesting = { _ in .success("the words nobody waited for") }

        var deskAtThePress: Int?
        recorder.transcriptAttachPauseForTesting = { [weak recorder] in
            // The recognition SUCCEEDED and the recorder is holding its answer;
            // the recording is parked and only the words are owed.
            let desk = try? await store.fetchWorkItem(id: Constants.workboardDeskItemID)
            deskAtThePress = desk?.materials.count ?? 0
            recorder?.cancelProcessing()
        }

        let result = await recorder._finishCaptureForTesting()

        XCTAssertEqual(
            deskAtThePress, 0,
            "control: the press really did land before the desk write, with nothing published"
        )
        guard case .failure(let surfaced) = result else {
            return XCTFail("a cancelled publication must not report the words settled")
        }
        guard case .unknown(let underlying) = surfaced, underlying is CancellationError else {
            return XCTFail("the answer is a cancellation, not an error about the desk")
        }

        let deskValue = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        XCTAssertNil(
            deskValue,
            """
            MEASURED: a transcript reached the desk after the cancel. The publication wrote \
            without asking, so the only reading that ran was the one AFTER the words had landed \
            — which changes what the person is told and not what the desk holds.
            """
        )
        let parkedNow = await lane.parkedAudio()
        XCTAssertEqual(
            parkedNow, [Self.recordingBytes],
            "…and the recording is untouched: the press was aimed at the words"
        )
        XCTAssertTrue(
            recorder.canRetryWorkCapture,
            "the capture keeps its debt and its Try Again — nothing failed, the person let go"
        )

        // CONTROL: the identical run whose pause presses nothing publishes, so
        // the assertion above is about the cancel and not about a desk write
        // that never runs.
        let controlStore = ConversationStore(inMemory: true)
        let control = InAppAudioRecorder(retryDestination: .work)
        control.workStoreForTesting = controlStore
        control.retryLaneForTesting = ParkingRetryLane()
        control.capturedAudioForTesting = Self.recordingBytes
        control.transcriptionHopForTesting = { _ in .success("the words somebody waited for") }
        control.transcriptAttachPauseForTesting = { }
        let controlResult = await control._finishCaptureForTesting()
        XCTAssertEqual(try controlResult.get(), "the words somebody waited for")
        let controlDesk = try await controlStore.fetchWorkItem(id: Constants.workboardDeskItemID)
        XCTAssertEqual(
            controlDesk?.materials.first?.textContent, "the words somebody waited for",
            "control: an uncancelled publication does reach the desk"
        )
    }

    /// Try Again finishes the capture that stopped, on the id it already owns —
    /// it does not record a second time, and no second card appears.
    @MainActor
    func testRetryingAFailedTranscriptionFinishesTheSameCapture() async throws {
        let store = ConversationStore(inMemory: true)
        let lane = ParkingRetryLane()
        let recorder = InAppAudioRecorder(retryDestination: .work)
        recorder.workStoreForTesting = store
        recorder.retryLaneForTesting = lane
        recorder.capturedAudioForTesting = Self.recordingBytes

        var hops = 0
        recorder.transcriptionHopForTesting = { _ in
            hops += 1
            return hops == 1 ? .failure(.sttProviderUnreachable) : .success("recovered on the retry")
        }

        _ = await recorder._finishCaptureForTesting()
        let captureID = try XCTUnwrap(recorder.pendingWorkCapture?.id)
        let deskAfterFailure = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        XCTAssertNil(deskAfterFailure, "the first attempt published nothing at all")

        let result = await recorder.retryWorkCapture()

        XCTAssertEqual(try result.get(), "recovered on the retry")
        XCTAssertEqual(hops, 2, "the retry re-transcribes the SAME parked bytes")
        XCTAssertEqual(
            recorder.workRecordingMaterialID, captureID,
            "the words land under the id the capture has carried since it was minted"
        )
        let deskValue = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        let desk = try XCTUnwrap(deskValue)
        XCTAssertEqual(desk.materials.count, 1, "no second card, and never a recording")
        XCTAssertEqual(desk.materials.first?.kind, .transcript)
        XCTAssertEqual(desk.materials.first?.textContent, "recovered on the retry")
        XCTAssertFalse(recorder.canRetryWorkCapture, "the capture is finished")
    }

    /// The transcription copy has ONE owner, and it runs on the path that
    /// creates the mess: a write that fails part way. Nothing is left at that
    /// path afterwards — the generic scratch sweeper would not reclaim a
    /// stranded partial for a day — and the parked recording is untouched.
    @MainActor
    func testARefusedTranscriptionCopyStrandsNothingAndKeepsTheRecording() async throws {
        let store = ConversationStore(inMemory: true)
        let lane = ParkingRetryLane()
        let recorder = InAppAudioRecorder(retryDestination: .work)
        recorder.workStoreForTesting = store
        recorder.retryLaneForTesting = lane
        recorder.capturedAudioForTesting = Self.recordingBytes
        recorder.transcriptionHopForTesting = { _ in .failure(.sttProviderUnreachable) }

        _ = await recorder._finishCaptureForTesting()
        let capture = try XCTUnwrap(recorder.pendingWorkCapture)
        // A directory where the copy goes: the write cannot succeed, and only
        // an owner that runs on the failing path clears what it leaves.
        try FileManager.default.createDirectory(
            at: capture.transcriptionFileURL, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: capture.transcriptionFileURL) }

        let result = await recorder.retryWorkCapture()

        guard case .failure(let error) = result else {
            return XCTFail("a capture whose bytes cannot be written out is not a transcript")
        }
        XCTAssertEqual(error.errorCode, AppError.audioMissingData.errorCode)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: capture.transcriptionFileURL.path),
            "the refused copy leaves nothing at its path"
        )
        let parkedNow = await lane.parkedAudio()
        XCTAssertEqual(
            parkedNow, [Self.recordingBytes],
            "the recording is untouched by any of it"
        )
        let deskValue = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        XCTAssertNil(deskValue, "and nothing reached the desk")
    }

    /// A desk that refuses the WORDS is a retryable error, never a silent
    /// hand-off to a composer: the sheet's success path reads
    /// `workRecordingMaterialID`, and a nil there with a `.success` result is
    /// exactly how a spoken note becomes typed text with no card behind it.
    @MainActor
    func testAPublicationFailureIsARetryableErrorRatherThanATextFallback() async throws {
        let broken = try Self.unusableStore()
        let brokenRefuses = await Self.refusesWrites(broken)
        XCTAssertTrue(brokenRefuses, "the fixture must actually refuse a desk write")
        let lane = ParkingRetryLane()
        let recorder = InAppAudioRecorder(retryDestination: .work)
        recorder.workStoreForTesting = broken
        recorder.retryLaneForTesting = lane
        recorder.capturedAudioForTesting = Self.recordingBytes

        recorder.transcriptionHopForTesting = { _ in
            .success("the words that must not be handed over")
        }

        let result = await recorder._finishCaptureForTesting()

        guard case .failure(let error) = result else {
            return XCTFail("a capture with no card must not report success")
        }
        XCTAssertTrue(error.isRetryable, "the same words, written again, normally land")
        XCTAssertNil(recorder.workRecordingMaterialID)
        let parkedNow = await lane.parkedAudio()
        XCTAssertEqual(
            parkedNow, [Self.recordingBytes],
            "the recording waits: it is what a second attempt is made of"
        )
        XCTAssertTrue(
            recorder.canRetryWorkCapture,
            "the bytes are still parked, so the person can finish this capture"
        )
        if case .error(let surfaced) = recorder.state {
            XCTAssertTrue(surfaced.isRetryable)
        } else {
            XCTFail("the sheet must show a retryable error, not an idle sheet")
        }
    }

    /// The other half of the same rule: the words were bought and the store
    /// refused to write them. The transcript is HELD — the retry publishes it
    /// without a second round trip — instead of being reported successful beside
    /// a desk that holds nothing.
    @MainActor
    func testAPublicationFailureHoldsTheWordsAndTheRetryFinishesTheSameCapture() async throws {
        let store = ConversationStore(inMemory: true)
        let broken = try Self.unusableStore()
        let brokenRefuses = await Self.refusesWrites(broken)
        XCTAssertTrue(brokenRefuses, "the fixture must actually refuse a desk write")
        let lane = ParkingRetryLane()
        let recorder = InAppAudioRecorder(retryDestination: .work)
        recorder.workStoreForTesting = store
        recorder.retryLaneForTesting = lane
        recorder.capturedAudioForTesting = Self.recordingBytes

        var hops = 0
        recorder.transcriptionHopForTesting = { [weak recorder] _ in
            hops += 1
            // The words are bought by now; break the store before the
            // publication so that — and only that — fails.
            recorder?.workStoreForTesting = broken
            return .success("the ferry leaves at seven")
        }

        let failed = await recorder._finishCaptureForTesting()

        guard case .failure(let error) = failed else {
            return XCTFail("words that never reached a card must not report success")
        }
        XCTAssertTrue(error.isRetryable)
        let captureID = try XCTUnwrap(recorder.pendingWorkCapture?.id)
        XCTAssertEqual(
            recorder.pendingWorkCapture?.transcript, "the ferry leaves at seven",
            "the words are held with the capture, not dropped and not published elsewhere"
        )
        let strandedValue = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        XCTAssertNil(strandedValue, "the desk write really did not happen")

        recorder.workStoreForTesting = store
        let repaired = await recorder.retryWorkCapture()

        XCTAssertEqual(try repaired.get(), "the ferry leaves at seven")
        XCTAssertEqual(hops, 1, "the held words need no second transcription")
        XCTAssertEqual(recorder.workRecordingMaterialID, captureID)
        let deskValue = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        let desk = try XCTUnwrap(deskValue)
        XCTAssertEqual(desk.materials.count, 1)
        XCTAssertEqual(desk.materials.first?.kind, .transcript)
        XCTAssertEqual(desk.materials.first?.textContent, "the ferry leaves at seven")
        XCTAssertFalse(recorder.canRetryWorkCapture)
    }

    // MARK: - Call-site policy: the two retry surfaces decide nothing themselves

    /// Neither surface that recovers a parked Work capture owns the desk
    /// decision. Both hand the record to `WorkVoiceCaptureCoordinator.recover`
    /// — ONCE — and act on the outcome it answers.
    ///
    /// What the decision actually is (which of three candidate ids the words
    /// take, and whether a legacy recording standing at one of them carries
    /// them) is asserted behaviourally against a real store in
    /// `WorkVoiceTranscriptPublicationTests` and `WorkVoiceRecoveryTests`; there
    /// is nothing left here for a source guard to say about it, and saying it
    /// again in token order was how a rule two files must share came to be
    /// spelled twice. What remains is a CALL-SITE policy, and it is the half a
    /// behavioural test cannot reach: both call sites live inside a SwiftUI
    /// view's action and a menu-bar service, neither of which this suite can
    /// mount.
    ///
    /// The second and third halves are the load-bearing ones. A surface keeping
    /// its own publication beside the shared entry point is a second answer to
    /// the same question — and the one it gives writes the card without the
    /// `.published` stamp `recover` puts on the entry, so the next retry buys
    /// the same transcription over again.
    func testEveryRetrySurfaceMakesItsDeskDecisionThroughTheOneRecovery() throws {
        for path in [
            "Conduck/ContentView.swift",
            "Conduck/MenuBar/DictationService.swift",
        ] {
            let text = RefusalLaneSource.stripComments(try Self.source(path))

            XCTAssertEqual(
                text.components(separatedBy: "WorkVoiceCaptureCoordinator.recover(").count - 1, 1,
                "\(path) must reach the shared recovery exactly once: none means it decides for "
                + "itself again, and a second call site is the same decision spelled twice in one "
                + "file, which is how the two surfaces drifted apart in the first place."
            )
            XCTAssertNil(
                text.range(of: "WorkCaptureRetryCoordinator.publish("),
                "\(path) keeps a fallback publication of its own beside the shared recovery. That "
                + "is a second answer to the question `recover` exists to answer, and it publishes "
                + "the words under an id the caller chose — the shape that let a note be swallowed "
                + "by the recording's own card while the retry record was cleared."
            )
            XCTAssertNil(
                text.range(of: "WorkVoiceCaptureCoordinator.publishTranscript("),
                "\(path) writes the words to the desk itself, past the recovery. The seam takes a "
                + "capture id and answers where the words landed; a surface calling it directly "
                + "skips the `.published` stamp `recover` writes onto the entry it is holding, and "
                + "the next retry pays for the same transcription again."
            )
        }
    }

    /// The press that lands INSIDE the write's own suspensions — after the
    /// store is open, after the last `Task` check, and before the row is
    /// touched.
    ///
    /// `Task.isCancelled` cannot answer here: the mutation runs in a closure the
    /// Core Data queue schedules, and inside it that flag describes the queue's
    /// task rather than the capture's, so it reads `false` however hard the
    /// person pressed. The authorization the write reads has to be a value
    /// carried in, checked at the mutation boundary — which is the whole reason
    /// `publishTranscript` takes an `authorization:` and threads it into
    /// `upsertDeskMaterial` rather than checking cancellation above the call.
    ///
    /// END TO END through the recorder, which is the half the seam's own case
    /// cannot reach: it proves the recorder actually HANDS its authorization to
    /// the seam. A recorder that built one and dropped it would leave the store
    /// deriving a box from the ambient task, and the press would be answered
    /// only after the card was on the desk.
    @MainActor
    func testCancellingInsideTheQueuedWriteStillKeepsTheWordsOffTheDesk() async throws {
        let store = ConversationStore(inMemory: true)
        let lane = ParkingRetryLane()
        let recorder = InAppAudioRecorder(retryDestination: .work)
        recorder.workStoreForTesting = store
        recorder.retryLaneForTesting = lane
        recorder.capturedAudioForTesting = Self.recordingBytes
        recorder.transcriptionHopForTesting = { _ in .success("the words nobody waited for") }

        // Inside the publication lock: the bytes of this write are staged, the
        // caller's own check has long since passed, and the desk row has not
        // been touched. Nothing observable to a surface stands in this window;
        // the store's own seam is what puts a press in it.
        let pressed = Pressed()
        await store._setWorkMaterialPublicationLockHoldForTesting { [weak recorder] _ in
            pressed.record()
            await recorder?.cancelProcessing()
        }

        let result = await recorder._finishCaptureForTesting()
        await store._setWorkMaterialPublicationLockHoldForTesting(nil)

        XCTAssertTrue(
            pressed.happened,
            "control: the press really did land inside the write, past the store's load"
        )
        guard case .failure(let surfaced) = result else {
            return XCTFail("a cancelled write must not report the words settled")
        }
        guard case .unknown(let underlying) = surfaced, underlying is CancellationError else {
            return XCTFail("the answer is a cancellation, not an error about the desk")
        }

        let deskValue = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        XCTAssertNil(
            deskValue,
            """
            MEASURED: the transcript reached the desk from inside the queued write. The check \
            above the `perform` had already passed, so the only thing between the press and the \
            row was an authorization the closure could read — and it did not.
            """
        )
        let parkedNow = await lane.parkedAudio()
        XCTAssertEqual(
            parkedNow, [Self.recordingBytes],
            "…and the recording is untouched: the press was aimed at the words"
        )
        XCTAssertTrue(
            recorder.canRetryWorkCapture,
            "the capture keeps its debt and its Try Again — nothing failed, the person let go"
        )

        // CONTROL: the identical run whose pause presses nothing writes the
        // words, so the assertion above is about the cancel and not about a
        // write that never runs.
        let controlStore = ConversationStore(inMemory: true)
        let control = InAppAudioRecorder(retryDestination: .work)
        control.workStoreForTesting = controlStore
        control.retryLaneForTesting = ParkingRetryLane()
        control.capturedAudioForTesting = Self.recordingBytes
        control.transcriptionHopForTesting = { _ in .success("the words somebody waited for") }
        await controlStore._setWorkMaterialPublicationLockHoldForTesting { _ in }
        let controlResult = await control._finishCaptureForTesting()
        await controlStore._setWorkMaterialPublicationLockHoldForTesting(nil)
        XCTAssertEqual(try controlResult.get(), "the words somebody waited for")
        let controlDesk = try await controlStore.fetchWorkItem(id: Constants.workboardDeskItemID)
        XCTAssertEqual(
            controlDesk?.materials.first?.textContent, "the words somebody waited for",
            "control: an uncancelled write does land the words on the desk"
        )
    }

    #if os(macOS)

    /// The quit question, COUNTED rather than called.
    ///
    /// Its guard asserted the shape of the declaration and never its effect, so
    /// `+= 1` written as `+= 0` left every assertion green while ⌘Q terminated
    /// silently with the only copy of a recording. What the count has to be is
    /// one per RECORDER still holding bytes nothing durable would take — and
    /// nothing once that recorder is gone, because a declaration is a claim
    /// about memory that dies with the object making it.
    @MainActor
    func testTheQuitQuestionCountsEveryRecorderHoldingBytesNothingWouldTake() async throws {
        let baseline = InAppAudioRecorder.unsavedWorkCaptureCount
        let broken = try Self.unusableStore()
        let brokenRefuses = await Self.refusesWrites(broken)
        XCTAssertTrue(brokenRefuses, "the fixture must actually refuse a desk write")

        // ONE capture whose desk write and whose preservation both failed. The
        // bytes are in this recorder's memory and nowhere else.
        let first = InAppAudioRecorder(retryDestination: .work)
        first.workStoreForTesting = broken
        first.retryLaneForTesting = RefusingRetryLane()
        first.capturedAudioForTesting = Self.recordingBytes
        _ = await first._finishCaptureForTesting()

        XCTAssertEqual(
            InAppAudioRecorder.unsavedWorkCaptureCount - baseline, 1,
            """
            MEASURED: a capture the desk refused AND the queue refused is not being counted, so \
            Cmd-Q reads a clear registry and quits with the only copy of a recording.
            """
        )
        XCTAssertEqual(
            QuitGuard.unsavedCaptureVerdict(
                unsavedCount: InAppAudioRecorder.unsavedWorkCaptureCount,
                powerOffInProgress: false
            ),
            .ask(QuitGuard.UnsavedCapturePrompt(count: baseline + 1)),
            "…and the verdict that reads it still asks rather than terminating"
        )

        // A SECOND recorder — the menu bar's and the desk sheet's are different
        // instances, and either may be holding.
        let second = InAppAudioRecorder(retryDestination: .work)
        second.workStoreForTesting = broken
        second.retryLaneForTesting = RefusingRetryLane()
        second.capturedAudioForTesting = Self.recordingBytes
        _ = await second._finishCaptureForTesting()
        XCTAssertEqual(
            InAppAudioRecorder.unsavedWorkCaptureCount - baseline, 2,
            "one declaration per recorder holding bytes, not one for the process"
        )

        // The person lets one go: the ✕ on the capture.
        first.discardPendingWorkCapture()
        XCTAssertEqual(
            InAppAudioRecorder.unsavedWorkCaptureCount - baseline, 1,
            "an explicit discard ends the question it raised"
        )

        // …and a capture whose preservation LANDS is not unsaved at all.
        let durable = InAppAudioRecorder(retryDestination: .work)
        durable.workStoreForTesting = broken
        durable.retryLaneForTesting = RecordingOnlyRetryLane()
        durable.capturedAudioForTesting = Self.recordingBytes
        _ = await durable._finishCaptureForTesting()
        XCTAssertEqual(
            InAppAudioRecorder.unsavedWorkCaptureCount - baseline, 1,
            "the queue took the bytes, so nothing about this capture is a question for the person"
        )

        // THE LIFETIME. A surface dismissed over a standing error releases
        // nothing — its ✕ does nothing in `.error`, and so does its
        // disappearance — so a count that had to be decremented by somebody
        // stayed raised for the life of the app, and every later Cmd-Q asked
        // about a recording whose Try Again had gone with the sheet.
        var dismissed: InAppAudioRecorder? = InAppAudioRecorder(retryDestination: .work)
        dismissed?.workStoreForTesting = broken
        dismissed?.retryLaneForTesting = RefusingRetryLane()
        dismissed?.capturedAudioForTesting = Self.recordingBytes
        _ = await dismissed?._finishCaptureForTesting()
        XCTAssertEqual(
            InAppAudioRecorder.unsavedWorkCaptureCount - baseline, 2,
            "control: the dismissed sheet's recorder really was holding one"
        )
        dismissed = nil
        XCTAssertEqual(
            InAppAudioRecorder.unsavedWorkCaptureCount - baseline, 1,
            """
            MEASURED: a recorder that no longer exists is still holding a quit window open. Its \
            capture cannot be retried or discarded from anywhere, so the question is permanent \
            and unanswerable.
            """
        )

        second.discardPendingWorkCapture()
        durable.discardPendingWorkCapture()
        XCTAssertEqual(
            InAppAudioRecorder.unsavedWorkCaptureCount, baseline,
            "the suite leaves the process's registry as it found it"
        )
    }

    #endif

    // MARK: - Fixtures

    /// Stands in for a compressed 16 kHz mono AAC voice note: small, so the
    /// storage policy picks the synced lane exactly as it does in the app, and
    /// not decodable as audio, so `AudioCompressor` returns it untouched.
    private static let recordingBytes = Data(repeating: 0x7F, count: 4_096)

    /// A store that cannot mount, so every operation on it throws. It stands
    /// for the transient desk failure — a full disk, a protected-data blackout
    /// — that must never be mistaken for "this capture has no card". The URL
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

    /// One capture's words, published the way every lane publishes them.
    @discardableResult
    private static func publish(
        captureID: UUID,
        in store: ConversationStore
    ) async throws -> WorkVoiceTranscriptOutcome {
        try await WorkVoiceCaptureCoordinator.publishTranscript(
            "the ferry leaves at seven",
            forCapture: captureID,
            createdAt: Date(),
            store: store
        )
    }

    /// A recording on the desk, as an EARLIER BUILD published it. Nothing in
    /// the app writes one any more — the coordinator has no function that
    /// could — so the fixture goes through the desk's own door, exactly as an
    /// audio file a person attaches does. The cases that use it are about the
    /// cards those builds left behind on people's desks.
    @discardableResult
    private static func publishLegacyRecording(
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

    /// `.../Conduck/Conduck` — the project container holding the app sources.
    /// Derived from this file's compile-time path so the source guard does not
    /// depend on the test runner's working directory.
    private static func source(_ relativePath: String) throws -> String {
        let container = URL(fileURLWithPath: #filePath)  // .../ConduckTests/<this>
            .deletingLastPathComponent()                 // .../ConduckTests
            .deletingLastPathComponent()                 // .../Conduck/Conduck
        return try String(
            contentsOf: container.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }
}

/// Recorded once, from a `@Sendable` seam that may not capture a mutable local.
private final class Pressed: @unchecked Sendable {
    private let lock = NSLock()
    private var pressed = false
    var happened: Bool { lock.lock(); defer { lock.unlock() }; return pressed }
    func record() { lock.lock(); pressed = true; lock.unlock() }
}

/// A retry queue that takes nothing. It stands for the second half of the one
/// state the quit question exists for: the desk refused these bytes and so did
/// the queue, so they are in one recorder's memory and nowhere else.
private actor RefusingRetryLane: PendingRetryLaneReserving {
    func save(audioData: Data, metadata: PendingRetryMetadata, workImageData: Data?) async throws {
        throw AppError.settingsLoadFailed
    }
    func claim(id: UUID, duration: TimeInterval) async -> PendingRetryClaim? { nil }
    func reserve(id: UUID, duration: TimeInterval) async -> PendingRetryReservation { .absent }
    @discardableResult func renew(_ claim: PendingRetryClaim) async -> Bool { false }
    func confirmOwnership(_ claim: PendingRetryClaim) async -> Bool { false }
    func release(_ claim: PendingRetryClaim) async {}
    @discardableResult func clear(_ claim: PendingRetryClaim) async -> Bool { false }
}

/// A queue that behaves like the real one: it takes the bytes, hands out a
/// lease over exactly what it holds, and lets go only under that lease.
///
/// Every case in this file that drives the recorder end to end uses it, because
/// the ordering under test is now about the QUEUE and not about the desk — and
/// because a recorder left on `PendingRetryStore.shared` would park a fixture
/// recording into the simulator's real App Group container and leave it there.
private actor ParkingRetryLane: PendingRetryLaneReserving {
    private var parked: [(metadata: PendingRetryMetadata, audio: Data)] = []
    private var leases: [UUID: UUID] = [:]

    /// The recordings this queue is holding, in the order they were parked.
    func parkedAudio() -> [Data] { parked.map(\.audio) }

    /// The captures this queue is holding.
    func parkedIDs() -> [UUID] { parked.map(\.metadata.id) }

    func save(audioData: Data, metadata: PendingRetryMetadata, workImageData: Data?) async throws {
        parked.removeAll { $0.metadata.id == metadata.id }
        parked.append((metadata, audioData))
    }

    func claim(id: UUID, duration: TimeInterval) async -> PendingRetryClaim? {
        guard let entry = parked.last(where: { $0.metadata.id == id }) else { return nil }
        let token = UUID()
        leases[id] = token
        return PendingRetryClaim(
            entry: PendingRetryEntry(
                audioData: entry.audio, metadata: entry.metadata, workImageData: nil
            ),
            token: token
        )
    }

    @discardableResult
    func renew(_ claim: PendingRetryClaim) async -> Bool { leases[claim.id] == claim.token }

    func confirmOwnership(_ claim: PendingRetryClaim) async -> Bool {
        guard parked.contains(where: { $0.metadata.id == claim.id }) else { return false }
        return leases[claim.id] == claim.token
    }

    func release(_ claim: PendingRetryClaim) async {
        guard leases[claim.id] == claim.token else { return }
        leases[claim.id] = nil
    }

    @discardableResult
    func clear(_ claim: PendingRetryClaim) async -> Bool {
        guard leases[claim.id] == claim.token else { return false }
        guard parked.contains(where: { $0.metadata.id == claim.id }) else { return false }
        parked.removeAll { $0.metadata.id == claim.id }
        leases[claim.id] = nil
        return true
    }

    @discardableResult
    func recordPublicationState(
        _ claim: PendingRetryClaim,
        transcript: String?,
        publicationState: PendingRetryPublicationState
    ) async -> Bool {
        guard leases[claim.id] == claim.token else { return false }
        guard let index = parked.firstIndex(where: { $0.metadata.id == claim.id }) else {
            return false
        }
        parked[index].metadata = parked[index].metadata.recording(
            transcript: transcript, publicationState: publicationState
        )
        return true
    }

    @discardableResult
    func retireRecording(_ claim: PendingRetryClaim) async -> Bool {
        guard leases[claim.id] == claim.token else { return false }
        guard let index = parked.firstIndex(where: { $0.metadata.id == claim.id }) else {
            return false
        }
        parked[index].audio = Data()
        return true
    }
}

/// A retry queue that TAKES what it is given — the control for the refusing
/// lane, so "unsaved" is measured against a capture the queue actually
/// sheltered.
private actor RecordingOnlyRetryLane: PendingRetryLaneReserving {
    private(set) var saved: [UUID] = []
    func save(audioData: Data, metadata: PendingRetryMetadata, workImageData: Data?) async throws {
        saved.append(metadata.id)
    }
    func claim(id: UUID, duration: TimeInterval) async -> PendingRetryClaim? { nil }
    func reserve(id: UUID, duration: TimeInterval) async -> PendingRetryReservation { .absent }
    @discardableResult func renew(_ claim: PendingRetryClaim) async -> Bool { false }
    func confirmOwnership(_ claim: PendingRetryClaim) async -> Bool { false }
    func release(_ claim: PendingRetryClaim) async {}
    @discardableResult func clear(_ claim: PendingRetryClaim) async -> Bool { false }
}
