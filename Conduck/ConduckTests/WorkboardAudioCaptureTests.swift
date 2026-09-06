// SPDX-License-Identifier: Apache-2.0

// ConduckTests
// WorkboardAudioCaptureTests.swift
//
// The two-phase Work voice capture. Its whole claim is an ordering one — the
// recording reaches the desk BEFORE transcription is attempted — so what these
// cases hold is that the card exists and plays with no transcript at all, that
// the words later land on that same card rather than beside it, and that a
// transcription which never succeeds leaves the recording standing anyway.
//
// The ordering is asserted from INSIDE the recorder: a stub speech hop stands
// where the provider does and reads the desk back before it answers, so nothing
// here depends on how the source is spelled. The same stub proves the other
// half — a capture the desk refused is a retryable error the person can finish,
// never a quiet fall back to typing the words into a composer.

import XCTest
@testable import Conduck

final class WorkboardAudioCaptureTests: XCTestCase {

    // MARK: - Phase 1: the recording is a card before there are any words

    func testARecordingBecomesAPlayableCardBeforeAnyTranscriptExists() async throws {
        let store = ConversationStore(inMemory: true)
        let captureID = UUID()
        let recording = Self.recordingBytes

        let card = try await WorkVoiceCaptureCoordinator.publishRecording(
            captureID: captureID,
            audio: recording,
            fileExtension: "m4a",
            mimeType: "audio/mp4",
            store: store
        )

        XCTAssertEqual(card.id, captureID, "the capture's id IS the card's id")
        XCTAssertEqual(card.kind, .audio)
        XCTAssertEqual(card.workItemID, Constants.workboardDeskItemID)
        XCTAssertNil(card.textContent, "a card exists before any transcript does")
        XCTAssertEqual(
            card.storageMode, .syncedPayload,
            "a compressed voice note is far below the ceiling, so its bytes ride private CloudKit"
        )
        XCTAssertEqual(card.availability, .synced)
        XCTAssertTrue(card.hasPayload, "the card is playable the moment it appears")
        XCTAssertEqual(card.byteSize, Int64(recording.count))
        XCTAssertEqual(card.mimeType, "audio/mp4")
        XCTAssertEqual(
            card.title, WorkVoiceCaptureCoordinator.untranscribedTitle,
            "an untranscribed recording names itself rather than borrowing a thought's default"
        )

        let payload = try await store.loadWorkMaterialPayload(id: captureID)
        XCTAssertEqual(payload, recording, "the bytes read back exactly")

        let deskValue = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        let desk = try XCTUnwrap(deskValue)
        XCTAssertEqual(desk.materials.map(\.id), [captureID])
    }

    func testReplayingOneRecordingReturnsTheSameCardWithoutASecondRow() async throws {
        let store = ConversationStore(inMemory: true)
        let captureID = UUID()

        let first = try await Self.publish(captureID: captureID, in: store)
        let second = try await Self.publish(captureID: captureID, in: store)

        XCTAssertEqual(first.id, second.id)
        XCTAssertEqual(
            first.updatedAt, second.updatedAt,
            "a replay of one capture writes nothing; the card it finds is the answer"
        )
        let deskValue = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        let desk = try XCTUnwrap(deskValue)
        XCTAssertEqual(desk.materials.count, 1)
    }

    func testTheCardRemembersTheSurfaceTheWordsWereSpokenAtRatherThanTheOneThatWroteThem()
        async throws
    {
        let store = ConversationStore(inMemory: true)

        // A relayed capture: the wrist recorded it, the phone publishes it.
        // Reading the writer's own device here would file every watch note
        // under the iPhone that happened to be nearby.
        let relayed = try await WorkVoiceCaptureCoordinator.publishRecording(
            captureID: UUID(),
            audio: Self.recordingBytes,
            fileExtension: "m4a",
            mimeType: "audio/mp4",
            sourceDevice: "carplay",
            store: store
        )
        XCTAssertEqual(relayed.sourceDevice, "carplay")

        // Every lane that DOES run where the person spoke keeps saying so
        // without spelling it, so the default cannot drift away from the value
        // the rest of the desk stamps.
        let local = try await Self.publish(captureID: UUID(), in: store)
        XCTAssertEqual(
            local.sourceDevice, SourceDevice.current,
            "an omitted surface still names the device the capture ran on"
        )

        let deskValue = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        let desk = try XCTUnwrap(deskValue)
        XCTAssertEqual(
            Set(desk.materials.compactMap(\.sourceDevice)),
            ["carplay", SourceDevice.current],
            "the stamp survives the write; it is not a value the read path re-derives"
        )
    }

    // MARK: - Phase 2: the words join the recording they came from

    func testTheTranscriptLandsOnTheSameCardRatherThanASecondOne() async throws {
        let store = ConversationStore(inMemory: true)
        let captureID = UUID()
        let published = try await Self.publish(captureID: captureID, in: store)

        let outcome = try await WorkVoiceCaptureCoordinator.attachTranscript(
            "  Ferry leaves at 07:30\nask about the bikes  ",
            toRecording: captureID,
            store: store
        )
        XCTAssertEqual(outcome, .attached)

        let deskValue = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        let desk = try XCTUnwrap(deskValue)
        XCTAssertEqual(desk.materials.count, 1, "the words never make a second card")
        let card = try XCTUnwrap(desk.materials.first)
        XCTAssertEqual(card.id, published.id, "the same material, mutated in place")
        XCTAssertEqual(card.kind, .audio, "a transcribed recording is still a recording")
        XCTAssertEqual(card.textContent, "Ferry leaves at 07:30\nask about the bikes")
        XCTAssertEqual(
            card.title, "Ferry leaves at 07:30",
            "the card takes the transcript's first line, the same shape a captured thought does"
        )
        XCTAssertTrue(card.hasPayload, "the recording is still playable after it gains words")
        let payload = try await store.loadWorkMaterialPayload(id: captureID)
        XCTAssertEqual(payload, Self.recordingBytes, "the bytes are untouched by a text edit")

        let rows = await store._workMaterialRowsForTesting(id: captureID)
        XCTAssertEqual(rows.count, 1, "one logical card, one physical row")
    }

    /// CloudKit cannot enforce Core Data uniqueness, so two offline devices can
    /// import one logical card as several physical rows and the canonical read
    /// picks the newest. A writer that touched only the row it fetched first
    /// would look correct through that read and lose the words the moment the
    /// other row won.
    func testTheTranscriptReachesEveryPhysicalRowOfADuplicatedCard() async throws {
        let store = ConversationStore(inMemory: true)
        let captureID = UUID()
        _ = try await Self.publish(captureID: captureID, in: store)
        // NEWER than the row publication wrote: with equal stamps the read would
        // pick the touched row anyway and prove nothing.
        await store._duplicateWorkMaterialRowForTesting(
            id: captureID,
            updatedAt: Date().addingTimeInterval(600)
        )
        let seededRows = await store._workMaterialRowsForTesting(id: captureID)
        XCTAssertEqual(seededRows.count, 2, "the fixture must actually be two physical rows")

        let outcome = try await WorkVoiceCaptureCoordinator.attachTranscript(
            "the ferry leaves at seven",
            toRecording: captureID,
            store: store
        )
        XCTAssertEqual(outcome, .attached)

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
    /// re-attaches under the same id — so an identical second delivery must be
    /// a defined no-op: no save, no desk bump. A rewrite would spend a CloudKit
    /// round trip on identical bytes and advance the desk's revision under
    /// whatever board mutation is in flight.
    func testAnIdenticalSecondDeliveryOfTheTranscriptWritesNothing() async throws {
        let store = ConversationStore(inMemory: true)
        let captureID = UUID()
        _ = try await Self.publish(captureID: captureID, in: store)
        _ = try await WorkVoiceCaptureCoordinator.attachTranscript(
            "the ferry leaves at seven",
            toRecording: captureID,
            store: store
        )
        let firstRows = await store._workMaterialRowsForTesting(id: captureID)
        let deskValueAfterFirst = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        let deskAfterFirst = try XCTUnwrap(deskValueAfterFirst)

        let outcome = try await WorkVoiceCaptureCoordinator.attachTranscript(
            "the ferry leaves at seven",
            toRecording: captureID,
            store: store
        )

        XCTAssertEqual(outcome, .attached, "the words are on the card; that is the answer")
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
        let corrected = try await WorkVoiceCaptureCoordinator.attachTranscript(
            "the ferry leaves at seven thirty",
            toRecording: captureID,
            store: store
        )
        XCTAssertEqual(corrected, .attached)
        let deskValue = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        XCTAssertEqual(
            deskValue?.materials.first?.textContent, "the ferry leaves at seven thirty",
            "the no-op is about identical values, not about refusing a second write"
        )
    }

    func testAFailedTranscriptionLeavesThePlayableRecordingStanding() async throws {
        let store = ConversationStore(inMemory: true)
        let captureID = UUID()
        _ = try await Self.publish(captureID: captureID, in: store)

        // Transcription failed, was refused or was abandoned: nothing calls
        // phase 2 at all. Every other capture lane would have lost the audio
        // with the words, because the words were the only artifact.
        let deskValue = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        let desk = try XCTUnwrap(deskValue)
        let card = try XCTUnwrap(desk.materials.first)
        XCTAssertEqual(card.kind, .audio)
        XCTAssertNil(card.textContent, "an untranscribed card carries no words, and says so")
        XCTAssertTrue(card.hasPayload)
        let payload = try await store.loadWorkMaterialPayload(id: captureID)
        XCTAssertEqual(payload, Self.recordingBytes)

        // …and the retry that succeeds an hour later still finds it.
        let outcome = try await WorkVoiceCaptureCoordinator.attachTranscript(
            "the words that arrived late",
            toRecording: captureID,
            store: store
        )
        XCTAssertEqual(outcome, .attached)
        let repairedValue = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        let repaired = try XCTUnwrap(repairedValue)
        XCTAssertEqual(repaired.materials.count, 1)
        XCTAssertEqual(repaired.materials.first?.textContent, "the words that arrived late")
    }

    func testATranscriptIsRefusedForACaptureThatOwnsNoRecording() async throws {
        let store = ConversationStore(inMemory: true)

        let outcome = try await WorkVoiceCaptureCoordinator.attachTranscript(
            "words with nowhere to land",
            toRecording: UUID(),
            store: store
        )

        XCTAssertEqual(
            outcome, .recordingMissing,
            """
            The Shortcuts route publishes no recording; this answer — and only \
            this answer — is what sends its words down the ordinary path.
            """
        )
        let desk = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        XCTAssertNil(desk, "a refused transcript creates no desk row and no card")
    }

    func testAnEmptyTranscriptWritesNothingAndStillNamesTheRecording() async throws {
        let store = ConversationStore(inMemory: true)
        let captureID = UUID()
        _ = try await Self.publish(captureID: captureID, in: store)

        let outcome = try await WorkVoiceCaptureCoordinator.attachTranscript(
            "   \n  ",
            toRecording: captureID,
            store: store
        )

        XCTAssertEqual(
            outcome, .attached,
            """
            Silence asks for nothing, and the recording is standing fine. \
            Reporting it missing would invite a fallback publication of silence \
            beside the card it belongs to.
            """
        )
        let deskValue = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        let desk = try XCTUnwrap(deskValue)
        let card = try XCTUnwrap(desk.materials.first)
        XCTAssertNil(card.textContent)
        XCTAssertEqual(
            card.title, WorkVoiceCaptureCoordinator.untranscribedTitle,
            "silence must not rename a recording to nothing"
        )
    }

    func testATranscriptIsRefusedForACardThatIsNotARecording() async throws {
        let store = ConversationStore(inMemory: true)
        // The Shortcuts lane reuses its capture id as the id of the screenshot
        // it imports, so a pending-retry id CAN already name a card — just not
        // a recording. Writing spoken words onto that card is the exact mistake
        // the kind check exists to refuse.
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

        let outcome = try await WorkVoiceCaptureCoordinator.attachTranscript(
            "spoken words that belong to a different capture",
            toRecording: captureID,
            store: store
        )

        XCTAssertEqual(outcome, .notAudio)
        let deskValue = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        let desk = try XCTUnwrap(deskValue)
        let card = try XCTUnwrap(desk.materials.first)
        XCTAssertEqual(card.kind, .image, "the screenshot stays a screenshot")
        XCTAssertNil(card.textContent)
        XCTAssertEqual(card.title, "screenshot.jpg")
        XCTAssertEqual(card.updatedAt, before.updatedAt, "a refusal writes nothing at all")
    }

    // MARK: - The retry lane repairs the same card

    func testTheRetryRepairsTheSameRecordingInsteadOfPublishingItAsANote() async throws {
        let store = ConversationStore(inMemory: true)
        // The pending-retry record carries the capture's id, which is the card's
        // id — this is exactly what the retry surface passes.
        let pendingRetryID = UUID()
        let published = try await Self.publish(captureID: pendingRetryID, in: store)
        XCTAssertNil(published.textContent)

        let outcome = try await WorkVoiceCaptureCoordinator.attachTranscript(
            "recovered on the second attempt",
            toRecording: pendingRetryID,
            store: store
        )
        XCTAssertEqual(outcome, .attached)

        let deskValue = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        let desk = try XCTUnwrap(deskValue)
        XCTAssertEqual(desk.materials.count, 1, "the retry never duplicates the capture")
        let card = try XCTUnwrap(desk.materials.first)
        XCTAssertEqual(card.id, pendingRetryID)
        XCTAssertEqual(card.kind, .audio, "the retry never degrades the recording to a note")
        XCTAssertEqual(card.textContent, "recovered on the second attempt")
        let payload = try await store.loadWorkMaterialPayload(id: pendingRetryID)
        XCTAssertEqual(payload, Self.recordingBytes)
    }

    /// A fallback publication is the answer to `.recordingMissing` /
    /// `.notAudio`, and it cannot use the capture id: a material id names ONE
    /// card, so a note published at an id already naming a recording is refused
    /// as the collision it is, and the recovery carrying those words would fail
    /// on every attempt with nowhere else to put them.
    func testTheFallbackNoteIdIsDerivedFromTheCaptureAndCannotCollideWithIt() async throws {
        let captureID = UUID(uuidString: "9F2C7A10-4B31-4E52-9A77-0C1D5E6F8A03")!
        let derived = WorkVoiceCaptureCoordinator.fallbackNoteID(forCapture: captureID)

        XCTAssertNotEqual(derived, captureID, "a fallback note must not land on the recording")
        XCTAssertEqual(
            derived, WorkVoiceCaptureCoordinator.fallbackNoteID(forCapture: captureID),
            "derived, not random: a replayed retry has to reach the note it already published"
        )
        XCTAssertEqual(
            derived.uuidString, "D08E8FB3-6044-50B7-BCFD-3E88E0770438",
            """
            The derivation is a wire value in all but name — two devices \
            replaying one capture must reach the same note id, so a change here \
            duplicates every offline retry.
            """
        )
        XCTAssertNotEqual(
            derived,
            WorkVoiceCaptureCoordinator.fallbackNoteID(forCapture: UUID()),
            "different captures, different notes"
        )

        // …and the collision it exists to avoid is real: a note published under
        // the capture id is REFUSED by the desk, so a recovery that used it
        // would report a failure it can never retry past while the words it
        // carried reached nothing.
        let store = ConversationStore(inMemory: true)
        let recording = try await Self.publish(captureID: captureID, in: store)
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
    /// provider does, and the card is already on the desk WITH READABLE BYTES
    /// when it is called.
    @MainActor
    func testTranscriptionBeginsOnlyAfterTheRecordingIsADurableReadableCard() async throws {
        let store = ConversationStore(inMemory: true)
        let recorder = InAppAudioRecorder(retryDestination: .work)
        recorder.workStoreForTesting = store
        recorder.capturedAudioForTesting = Self.recordingBytes

        var hopRan = false
        var fileExistedAtTheHop = false
        var cardKindAtTheHop: WorkMaterialKind?
        var payloadAtTheHop: Data?
        recorder.transcriptionHopForTesting = { url in
            hopRan = true
            fileExistedAtTheHop = FileManager.default.fileExists(atPath: url.path)
            let desk = try? await store.fetchWorkItem(id: Constants.workboardDeskItemID)
            if let card = desk?.materials.first {
                cardKindAtTheHop = card.kind
                payloadAtTheHop = try? await store.loadWorkMaterialPayload(id: card.id)
            }
            return .success("the ferry leaves at seven")
        }

        let result = await recorder._finishCaptureForTesting()

        XCTAssertTrue(hopRan, "the stub must actually stand in the production path")
        XCTAssertTrue(
            fileExistedAtTheHop,
            "the provider is handed a file that exists"
        )
        XCTAssertEqual(
            cardKindAtTheHop, .audio,
            "the recording is ALREADY a card when transcription begins"
        )
        XCTAssertEqual(
            payloadAtTheHop, Self.recordingBytes,
            "…and its bytes are already readable, not merely promised"
        )
        XCTAssertEqual(try result.get(), "the ferry leaves at seven")
        let materialID = try XCTUnwrap(recorder.workRecordingMaterialID)
        let deskValue = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        let desk = try XCTUnwrap(deskValue)
        XCTAssertEqual(desk.materials.count, 1, "one capture, one card")
        XCTAssertEqual(desk.materials.first?.id, materialID)
        XCTAssertEqual(desk.materials.first?.textContent, "the ferry leaves at seven")
        XCTAssertFalse(
            recorder.canRetryWorkCapture,
            "a capture whose card owns the words owes nothing and offers no retry"
        )
    }

    /// The failure the ordering exists for. The recorder's own temporary copy
    /// is cleaned on the way out — a partial or abandoned one would sit in the
    /// scratch directory for a day — while the desk's copy, taken before the
    /// hop, survives it.
    @MainActor
    func testAFailedTranscriptionCleansTheTemporaryFileAndLeavesTheCardStanding() async throws {
        let store = ConversationStore(inMemory: true)
        let recorder = InAppAudioRecorder(retryDestination: .work)
        recorder.workStoreForTesting = store
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

        let materialID = try XCTUnwrap(
            recorder.workRecordingMaterialID,
            "the recording is on the desk even though the words never arrived"
        )
        let deskValue = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        let card = try XCTUnwrap(deskValue?.materials.first)
        XCTAssertEqual(card.id, materialID)
        XCTAssertEqual(card.kind, .audio)
        XCTAssertNil(card.textContent)
        let survivingPayload = try await store.loadWorkMaterialPayload(id: materialID)
        XCTAssertEqual(
            survivingPayload, Self.recordingBytes,
            "the desk's copy is its own, and outlives the file the hop was given"
        )
        XCTAssertTrue(
            recorder.canRetryWorkCapture,
            "the capture still owes its words, so it is the retry's subject"
        )
        XCTAssertEqual(
            recorder.pendingWorkCapture?.id, materialID,
            """
            ONE identity for the capture: the card's id is the pending capture's \
            id, which is the id the retry lane carries. A second UUID anywhere \
            in that chain is what makes recovered words unable to find the \
            recording they came from.
            """
        )
    }

    /// "Cancel transcription" is a promise about the WRITE, not about the
    /// provider. The request is already out and cannot be recalled, so what the
    /// press cancels is the RESULT — and a result that happens to be a success
    /// is the one the promise is hardest to keep and easiest to break: it used
    /// to walk past every check into phase two and attach its words to the card
    /// the person had already stopped waiting for.
    ///
    /// The recording stays, because the press was aimed at the words. What may
    /// not stay is the transcript, and the answer the caller gets is a
    /// cancellation rather than "Added to Work".
    ///
    /// The uncancelled control at the end is what stops this passing on a
    /// pipeline that simply attaches nothing.
    @MainActor
    func testCancellingTheTranscriptionKeepsTheRecordingAndRefusesTheWords() async throws {
        let store = ConversationStore(inMemory: true)
        let recorder = InAppAudioRecorder(retryDestination: .work)
        recorder.workStoreForTesting = store
        recorder.capturedAudioForTesting = Self.recordingBytes

        var cardKindAtThePress: WorkMaterialKind?
        recorder.transcriptionHopForTesting = { [weak recorder] _ in
            // The press lands while the provider is working — which is the only
            // window this control exists for. The recording is already a card
            // by then; the words are the one thing still owed.
            let desk = try? await store.fetchWorkItem(id: Constants.workboardDeskItemID)
            cardKindAtThePress = desk?.materials.first?.kind
            recorder?.cancelProcessing()
            return .success("the words nobody waited for")
        }

        let result = await recorder._finishCaptureForTesting()

        XCTAssertEqual(
            cardKindAtThePress, .audio,
            "control: the press really did land mid-hop, with the recording already on the desk"
        )
        guard case .failure(let surfaced) = result else {
            return XCTFail("a cancelled transcription must not report the words settled")
        }
        guard case .unknown(let underlying) = surfaced, underlying is CancellationError else {
            return XCTFail("the answer is a cancellation, not an error about the desk")
        }

        let deskValue = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        let card = try XCTUnwrap(deskValue?.materials.first)
        XCTAssertEqual(deskValue?.materials.count, 1, "one capture, one card, cancelled or not")
        XCTAssertEqual(card.kind, .audio)
        XCTAssertNil(
            card.textContent,
            """
            MEASURED: the transcript of a CANCELLED run reached the card anyway. The success arm \
            asked nothing about cancellation, so the only check that ran was the one after the \
            write — which changes what the person is told and not what the desk holds.
            """
        )
        let survivingPayload = try await store.loadWorkMaterialPayload(id: card.id)
        XCTAssertEqual(
            survivingPayload, Self.recordingBytes,
            "…and the recording is untouched: the press was aimed at the words"
        )

        // CONTROL: the identical run with nobody pressing anything finishes and
        // attaches, so the assertion above is about the cancel and not about a
        // phase two that never runs.
        let controlStore = ConversationStore(inMemory: true)
        let control = InAppAudioRecorder(retryDestination: .work)
        control.workStoreForTesting = controlStore
        control.capturedAudioForTesting = Self.recordingBytes
        control.transcriptionHopForTesting = { _ in .success("the words somebody waited for") }
        let controlResult = await control._finishCaptureForTesting()
        XCTAssertEqual(try controlResult.get(), "the words somebody waited for")
        let controlDesk = try await controlStore.fetchWorkItem(id: Constants.workboardDeskItemID)
        XCTAssertEqual(
            controlDesk?.materials.first?.textContent, "the words somebody waited for",
            "control: an uncancelled success does land on the card"
        )
    }

    /// The same promise, one step later: the press lands AFTER the words are
    /// bought and BEFORE they are written.
    ///
    /// The check `settle` takes cannot see this one — it has already run. The
    /// attachment then suspends twice (the store's first-use load, and its own
    /// queued write), and a transcript written under a cancel that landed in
    /// there is words arriving on a capture the person let go of. "Cancel
    /// transcription" is a promise about the WRITE, so the authorization has to
    /// reach the write boundary itself.
    @MainActor
    func testCancellingAfterTheWordsArriveStillKeepsThemOffTheCard() async throws {
        let store = ConversationStore(inMemory: true)
        let recorder = InAppAudioRecorder(retryDestination: .work)
        recorder.workStoreForTesting = store
        recorder.capturedAudioForTesting = Self.recordingBytes
        recorder.transcriptionHopForTesting = { _ in .success("the words nobody waited for") }

        var cardKindAtThePress: WorkMaterialKind?
        recorder.transcriptAttachPauseForTesting = { [weak recorder] in
            // The recognition SUCCEEDED and the recorder is holding its answer;
            // the card is already on the desk and only the words are owed.
            let desk = try? await store.fetchWorkItem(id: Constants.workboardDeskItemID)
            cardKindAtThePress = desk?.materials.first?.kind
            recorder?.cancelProcessing()
        }

        let result = await recorder._finishCaptureForTesting()

        XCTAssertEqual(
            cardKindAtThePress, .audio,
            "control: the press really did land after phase one, with the recording on the desk"
        )
        guard case .failure(let surfaced) = result else {
            return XCTFail("a cancelled attachment must not report the words settled")
        }
        guard case .unknown(let underlying) = surfaced, underlying is CancellationError else {
            return XCTFail("the answer is a cancellation, not an error about the desk")
        }

        let deskValue = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        let card = try XCTUnwrap(deskValue?.materials.first)
        XCTAssertEqual(deskValue?.materials.count, 1, "one capture, one card, cancelled or not")
        XCTAssertNil(
            card.textContent,
            """
            MEASURED: a transcript reached the card after the cancel. The attachment wrote without \
            asking, so the only reading that ran was the one AFTER the words had landed — which \
            changes what the person is told and not what the desk holds.
            """
        )
        let survivingPayload = try await store.loadWorkMaterialPayload(id: card.id)
        XCTAssertEqual(
            survivingPayload, Self.recordingBytes,
            "…and the recording is untouched: the press was aimed at the words"
        )
        XCTAssertTrue(
            recorder.canRetryWorkCapture,
            "the capture keeps its debt and its Try Again — nothing failed, the person let go"
        )

        // CONTROL: the identical run whose pause presses nothing attaches, so
        // the assertion above is about the cancel and not about a phase two that
        // never runs.
        let controlStore = ConversationStore(inMemory: true)
        let control = InAppAudioRecorder(retryDestination: .work)
        control.workStoreForTesting = controlStore
        control.capturedAudioForTesting = Self.recordingBytes
        control.transcriptionHopForTesting = { _ in .success("the words somebody waited for") }
        control.transcriptAttachPauseForTesting = { }
        let controlResult = await control._finishCaptureForTesting()
        XCTAssertEqual(try controlResult.get(), "the words somebody waited for")
        let controlDesk = try await controlStore.fetchWorkItem(id: Constants.workboardDeskItemID)
        XCTAssertEqual(
            controlDesk?.materials.first?.textContent, "the words somebody waited for",
            "control: an uncancelled attachment does land on the card"
        )
    }

    /// Try Again finishes the capture that stopped, on the card it already
    /// published — it does not record a second time, and no second card appears.
    @MainActor
    func testRetryingAFailedTranscriptionFinishesTheSameCard() async throws {
        let store = ConversationStore(inMemory: true)
        let recorder = InAppAudioRecorder(retryDestination: .work)
        recorder.workStoreForTesting = store
        recorder.capturedAudioForTesting = Self.recordingBytes

        var hops = 0
        recorder.transcriptionHopForTesting = { _ in
            hops += 1
            return hops == 1 ? .failure(.sttProviderUnreachable) : .success("recovered on the retry")
        }

        _ = await recorder._finishCaptureForTesting()
        let firstCardID = try XCTUnwrap(recorder.workRecordingMaterialID)

        let result = await recorder.retryWorkCapture()

        XCTAssertEqual(try result.get(), "recovered on the retry")
        XCTAssertEqual(hops, 2, "the retry re-transcribes the SAME pending bytes")
        XCTAssertEqual(
            recorder.workRecordingMaterialID, firstCardID,
            "the words land on the card the first attempt published"
        )
        let deskValue = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        let desk = try XCTUnwrap(deskValue)
        XCTAssertEqual(desk.materials.count, 1, "no second card, no second recording")
        XCTAssertEqual(desk.materials.first?.textContent, "recovered on the retry")
        XCTAssertFalse(recorder.canRetryWorkCapture, "the capture is finished")
    }

    /// The transcription copy has ONE owner, and it runs on the path that
    /// creates the mess: a write that fails part way. Nothing is left at that
    /// path afterwards — the generic scratch sweeper would not reclaim a
    /// stranded partial for a day.
    @MainActor
    func testARefusedTranscriptionCopyStrandsNothingAndKeepsTheCard() async throws {
        let store = ConversationStore(inMemory: true)
        let recorder = InAppAudioRecorder(retryDestination: .work)
        recorder.workStoreForTesting = store
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
        let deskValue = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        let card = try XCTUnwrap(deskValue?.materials.first)
        XCTAssertEqual(card.id, capture.id, "the recording is untouched by any of it")
        XCTAssertTrue(card.hasPayload)
    }

    /// A desk that refuses the recording is a retryable error, never a silent
    /// hand-off of the words to a composer: the sheet's success path reads
    /// `workRecordingMaterialID`, and a nil there with a `.success` result is
    /// exactly how a recording becomes typed text with no card behind it.
    @MainActor
    func testAPublicationFailureIsARetryableErrorRatherThanATextFallback() async throws {
        let broken = try Self.unusableStore()
        let brokenRefuses = await Self.refusesWrites(broken)
        XCTAssertTrue(brokenRefuses, "the fixture must actually refuse a desk write")
        let recorder = InAppAudioRecorder(retryDestination: .work)
        recorder.workStoreForTesting = broken
        recorder.capturedAudioForTesting = Self.recordingBytes

        var hops = 0
        recorder.transcriptionHopForTesting = { _ in
            hops += 1
            return .success("the words that must not be handed over")
        }

        let result = await recorder._finishCaptureForTesting()

        guard case .failure(let error) = result else {
            return XCTFail("a capture with no card must not report success")
        }
        XCTAssertTrue(error.isRetryable, "the same bytes, written again, normally land")
        XCTAssertEqual(hops, 0, "a recording that never reached the desk is not transcribed on")
        XCTAssertNil(recorder.workRecordingMaterialID)
        XCTAssertTrue(
            recorder.canRetryWorkCapture,
            "the bytes are still held, so the person can finish this capture"
        )
        if case .error(let surfaced) = recorder.state {
            XCTAssertTrue(surfaced.isRetryable)
        } else {
            XCTFail("the sheet must show a retryable error, not an idle sheet")
        }
    }

    /// The other half of the same rule: the card landed, the words did not, and
    /// the store refused the write. The transcript is HELD — the retry attaches
    /// it without a second round trip — instead of being reported successful
    /// beside a recording still waiting for it.
    @MainActor
    func testAnAttachFailureHoldsTheWordsAndTheRetryFinishesTheSameCard() async throws {
        let store = ConversationStore(inMemory: true)
        let broken = try Self.unusableStore()
        let brokenRefuses = await Self.refusesWrites(broken)
        XCTAssertTrue(brokenRefuses, "the fixture must actually refuse a desk write")
        let recorder = InAppAudioRecorder(retryDestination: .work)
        recorder.workStoreForTesting = store
        recorder.capturedAudioForTesting = Self.recordingBytes

        var hops = 0
        recorder.transcriptionHopForTesting = { [weak recorder] _ in
            hops += 1
            // The card is published by now; break the store between the two
            // phases so the attachment — and only the attachment — fails.
            recorder?.workStoreForTesting = broken
            return .success("the ferry leaves at seven")
        }

        let failed = await recorder._finishCaptureForTesting()

        guard case .failure(let error) = failed else {
            return XCTFail("a card that never got its words must not report success")
        }
        XCTAssertTrue(error.isRetryable)
        let cardID = try XCTUnwrap(recorder.workRecordingMaterialID)
        XCTAssertEqual(
            recorder.pendingWorkCapture?.transcript, "the ferry leaves at seven",
            "the words are held with the capture, not dropped and not published elsewhere"
        )
        let strandedValue = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        XCTAssertNil(
            strandedValue?.materials.first?.textContent,
            "the desk write really did not happen"
        )

        recorder.workStoreForTesting = store
        let repaired = await recorder.retryWorkCapture()

        XCTAssertEqual(try repaired.get(), "the ferry leaves at seven")
        XCTAssertEqual(hops, 1, "the held words need no second transcription")
        XCTAssertEqual(recorder.workRecordingMaterialID, cardID)
        let deskValue = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        let desk = try XCTUnwrap(deskValue)
        XCTAssertEqual(desk.materials.count, 1)
        XCTAssertEqual(desk.materials.first?.textContent, "the ferry leaves at seven")
        XCTAssertFalse(recorder.canRetryWorkCapture)
    }

    /// The one path that may still hand the words to a composer: the capture
    /// owns no recording at all. Deleting the card mid-flight is the reachable
    /// way there, and it must not become a retry the person can never satisfy.
    @MainActor
    func testACardDeletedDuringTranscriptionReleasesTheWordsToTheComposer() async throws {
        let store = ConversationStore(inMemory: true)
        let recorder = InAppAudioRecorder(retryDestination: .work)
        recorder.workStoreForTesting = store
        recorder.capturedAudioForTesting = Self.recordingBytes

        recorder.transcriptionHopForTesting = { _ in
            let desk = try? await store.fetchWorkItem(id: Constants.workboardDeskItemID)
            if let card = desk?.materials.first {
                try? await store.deleteWorkMaterial(id: card.id)
            }
            return .success("the words outlive the card")
        }

        let result = await recorder._finishCaptureForTesting()

        XCTAssertEqual(try result.get(), "the words outlive the card")
        XCTAssertNil(
            recorder.workRecordingMaterialID,
            "no card owns these words, which is what sends them to the composer"
        )
        XCTAssertFalse(
            recorder.canRetryWorkCapture,
            "there is nothing left to retry — a deleted card does not come back"
        )
    }

    // MARK: - Call-site policy: the two retry surfaces decide nothing themselves

    /// Neither surface that recovers a parked Work capture owns the desk
    /// decision. Both hand the record to `WorkVoiceCaptureCoordinator.recover`
    /// — ONCE — and act on the outcome it answers.
    ///
    /// What the decision actually is (attach, republish then attach, or write
    /// the words beside a card that is gone) is asserted behaviourally against
    /// a real store in `WorkVoiceRecoveryTests`; there is nothing left here for
    /// a source guard to say about it, and saying it again in token order was
    /// how a rule two files must share came to be spelled twice. What remains
    /// is a CALL-SITE policy, and it is the half a behavioural test cannot
    /// reach: both call sites live inside a SwiftUI view's action and a
    /// menu-bar service, neither of which this suite can mount.
    ///
    /// The second half is the load-bearing one. A surface keeping its own
    /// fallback publication beside the shared entry point is a second answer to
    /// the same question — and the one it gives (publish the words, then clear
    /// the record) is precisely what deleted the audio a deleted-card verdict
    /// was never meant to license.
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
                text.range(of: "WorkVoiceCaptureCoordinator.attachTranscript("),
                "\(path) attaches the transcript itself, so it is back to reading an absent card as "
                + "one fact when it has two opposite causes — a publication the desk refused, and a "
                + "card a person deleted while recognition was in flight."
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
    /// carried in, checked at the mutation boundary.
    @MainActor
    func testCancellingInsideTheQueuedWriteStillKeepsTheWordsOffTheCard() async throws {
        let store = ConversationStore(inMemory: true)
        let recorder = InAppAudioRecorder(retryDestination: .work)
        recorder.workStoreForTesting = store
        recorder.capturedAudioForTesting = Self.recordingBytes
        recorder.transcriptionHopForTesting = { _ in .success("the words nobody waited for") }

        let pressed = Pressed()
        WorkVoiceCaptureCoordinator.transcriptWritePauseForTesting = { [weak recorder] in
            pressed.record()
            recorder?.cancelProcessing()
        }
        defer { WorkVoiceCaptureCoordinator.transcriptWritePauseForTesting = nil }

        let result = await recorder._finishCaptureForTesting()

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
        let card = try XCTUnwrap(deskValue?.materials.first)
        XCTAssertEqual(deskValue?.materials.count, 1, "one capture, one card, cancelled or not")
        XCTAssertNil(
            card.textContent,
            """
            MEASURED: the transcript reached the card from inside the queued write. The check \
            above the `perform` had already passed, so the only thing between the press and the \
            row was an authorization the closure could read — and it did not.
            """
        )
        let survivingPayload = try await store.loadWorkMaterialPayload(id: card.id)
        XCTAssertEqual(
            survivingPayload, Self.recordingBytes,
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
        control.capturedAudioForTesting = Self.recordingBytes
        control.transcriptionHopForTesting = { _ in .success("the words somebody waited for") }
        WorkVoiceCaptureCoordinator.transcriptWritePauseForTesting = { }
        let controlResult = await control._finishCaptureForTesting()
        XCTAssertEqual(try controlResult.get(), "the words somebody waited for")
        let controlDesk = try await controlStore.fetchWorkItem(id: Constants.workboardDeskItemID)
        XCTAssertEqual(
            controlDesk?.materials.first?.textContent, "the words somebody waited for",
            "control: an uncancelled write does land on the card"
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

/// A retry queue that TAKES what it is given — the control for the lane above,
/// so "unsaved" is measured against a capture the queue actually sheltered.
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
