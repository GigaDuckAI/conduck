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
// The retry lane is the same property one app launch later: it names the card
// by the capture's own id, so the recovered words repair the recording instead
// of arriving as a second, note-shaped capture. The two source guards at the
// end pin the ordering and the single capture identity, because no assertion
// that can be written without a microphone can reach either one.

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

    func testTheRecordingIsCopiedRatherThanMovedFromTheCapturesTemporaryFile() async throws {
        let store = ConversationStore(inMemory: true)
        let captureID = UUID()
        let recording = Self.recordingBytes
        // The recorder writes the same compressed bytes to a temporary file for
        // the transcription hop and removes that file itself. Publication must
        // therefore leave the file alone AND survive its removal.
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("conduck-inapp-\(UUID().uuidString).m4a")
        try recording.write(to: temporary)
        defer { try? FileManager.default.removeItem(at: temporary) }

        _ = try await WorkVoiceCaptureCoordinator.publishRecording(
            captureID: captureID,
            audio: recording,
            fileExtension: "m4a",
            mimeType: "audio/mp4",
            store: store
        )

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: temporary.path),
            "the capture's own temporary file is not moved, consumed or deleted by publication"
        )
        try FileManager.default.removeItem(at: temporary)
        let payload = try await store.loadWorkMaterialPayload(id: captureID)
        XCTAssertEqual(
            payload, recording,
            "the desk holds its own durable copy, so the temp file's removal costs nothing"
        )
    }

    // MARK: - Phase 2: the words join the recording they came from

    func testTheTranscriptLandsOnTheSameCardRatherThanASecondOne() async throws {
        let store = ConversationStore(inMemory: true)
        let captureID = UUID()
        let published = try await Self.publish(captureID: captureID, in: store)

        let attached = try await WorkVoiceCaptureCoordinator.attachTranscript(
            "  Ferry leaves at 07:30\nask about the bikes  ",
            toRecording: captureID,
            store: store
        )
        XCTAssertTrue(attached)

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
        let attached = try await WorkVoiceCaptureCoordinator.attachTranscript(
            "the words that arrived late",
            toRecording: captureID,
            store: store
        )
        XCTAssertTrue(attached)
        let repairedValue = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        let repaired = try XCTUnwrap(repairedValue)
        XCTAssertEqual(repaired.materials.count, 1)
        XCTAssertEqual(repaired.materials.first?.textContent, "the words that arrived late")
    }

    func testATranscriptIsRefusedForACaptureThatOwnsNoRecording() async throws {
        let store = ConversationStore(inMemory: true)

        let attached = try await WorkVoiceCaptureCoordinator.attachTranscript(
            "words with nowhere to land",
            toRecording: UUID(),
            store: store
        )

        XCTAssertFalse(
            attached,
            """
            The Shortcuts route publishes no recording; a false answer is what \
            sends its words down the ordinary path.
            """
        )
        let desk = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        XCTAssertNil(desk, "a refused transcript creates no desk row and no card")
    }

    func testAnEmptyTranscriptIsRefusedAndLeavesTheCardUntouched() async throws {
        let store = ConversationStore(inMemory: true)
        let captureID = UUID()
        _ = try await Self.publish(captureID: captureID, in: store)

        let attached = try await WorkVoiceCaptureCoordinator.attachTranscript(
            "   \n  ",
            toRecording: captureID,
            store: store
        )

        XCTAssertFalse(attached)
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

        let attached = try await WorkVoiceCaptureCoordinator.attachTranscript(
            "spoken words that belong to a different capture",
            toRecording: captureID,
            store: store
        )

        XCTAssertFalse(attached)
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

        let attached = try await WorkVoiceCaptureCoordinator.attachTranscript(
            "recovered on the second attempt",
            toRecording: pendingRetryID,
            store: store
        )
        XCTAssertTrue(attached)

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

    func testTheFallbackPublicationCannotPutTheSameUtteranceOnTheBoardTwice() async throws {
        let store = ConversationStore(inMemory: true)
        let pendingRetryID = UUID()
        _ = try await Self.publish(captureID: pendingRetryID, in: store)
        _ = try await WorkVoiceCaptureCoordinator.attachTranscript(
            "recovered on the second attempt",
            toRecording: pendingRetryID,
            store: store
        )

        // The retry's fallback publishes an envelope whose note takes the
        // capture id as its material id. Should it ever run beside a surviving
        // recording — a partially replayed retry, a future caller that forgets
        // the check — the desk write answers with the card that is already
        // there rather than adding a note beside it.
        let fallback = try await store.upsertDeskMaterial(
            WorkMaterialDraft(
                id: pendingRetryID,
                kind: .note,
                title: "recovered on the second attempt",
                textContent: "recovered on the second attempt",
                storageMode: .metadataOnly
            )
        )

        XCTAssertEqual(fallback.kind, .audio, "the recording wins; the note is never inserted")
        XCTAssertEqual(fallback.textContent, "recovered on the second attempt")
        let deskValue = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        let desk = try XCTUnwrap(deskValue)
        XCTAssertEqual(desk.materials.count, 1)
    }

    // MARK: - Source guards: the ordering, and the one capture identity

    func testTheRecordingIsPublishedBeforeTheTranscriptionHop() throws {
        // The file's own header names several of these calls in prose, and an
        // ordering guard that reads a comment proves nothing about the code, so
        // the search starts at the declaration.
        let recorder = try Self.recorderBody()

        let publish = try XCTUnwrap(
            recorder.range(of: "WorkVoiceCaptureCoordinator.publishRecording("),
            "the Work lane must publish its recording inside the recorder"
        )
        for hop in [
            "AudioCompressor.compress(",
            "STTClient.shared.transcribe(",
            "AppleSpeechRunner.transcribe(",
            "WorkVoiceCaptureCoordinator.attachTranscript("
        ] {
            let range = try XCTUnwrap(recorder.range(of: hop), "\(hop) no longer exists")
            if hop == "AudioCompressor.compress(" {
                XCTAssertLessThan(
                    range.lowerBound, publish.lowerBound,
                    "the card carries the COMPRESSED artifact, which must already exist"
                )
            } else {
                XCTAssertLessThan(
                    publish.lowerBound, range.lowerBound,
                    """
                    Publication moved after \(hop). The whole point of the two \
                    phases is that transcription is the step that fails, so a \
                    recording published after it is a recording lost to it.
                    """
                )
            }
        }

        XCTAssertEqual(
            recorder.components(separatedBy: "if retryDestination == .work {").count - 1, 1,
            "exactly one gate: Chat captures publish no card, and their lane is untouched"
        )
        XCTAssertTrue(
            recorder.contains("audio: uploadData"),
            """
            The card is published from the compressed bytes already in hand. \
            Handing it the temporary file's URL instead would tie the desk's copy \
            to a file three separate paths delete out from under it.
            """
        )
        XCTAssertEqual(
            recorder.components(separatedBy: "removeItem(at: audioFileURL)").count - 1, 4,
            "the four paths that own the transcription temp file still remove it"
        )
    }

    func testOneCaptureIdentityNamesBothTheCardAndThePendingRetryRecord() throws {
        let recorder = try Self.recorderBody()

        XCTAssertEqual(
            recorder.components(separatedBy: "let captureID = UUID()").count - 1, 1,
            "one capture, one identity — minted once, before anything durable is written"
        )
        XCTAssertTrue(
            recorder.contains("captureID: captureID"),
            "the card is named by it"
        )
        XCTAssertTrue(
            recorder.contains("id: captureID,"),
            """
            The pending-retry record is named by it too. A second UUID here is \
            what would make a recovered transcript unable to find the recording \
            it came from, and publish a note beside it instead.
            """
        )
    }

    /// Both surfaces that recover a parked transcript repair the recording
    /// card first and publish only when there is none. A Work voice capture can
    /// be recovered on either — the sheet exists on iOS and on macOS, and the
    /// pending-retry record is one store — so a surface that publishes
    /// unconditionally leaves its recovered words beside an untranscribed
    /// recording that is still waiting for them.
    func testEveryRetrySurfaceRepairsTheRecordingBeforeItPublishes() throws {
        for path in [
            "Conduck/ContentView.swift",
            "Conduck/MenuBar/DictationService.swift",
        ] {
            let text = try Self.source(path)
            let attach = try XCTUnwrap(
                text.range(of: "WorkVoiceCaptureCoordinator.attachTranscript("),
                "\(path) recovers a Work transcript without offering it to the recording card"
            )
            let publish = try XCTUnwrap(
                text.range(of: "WorkCaptureRetryCoordinator.publish("),
                "\(path) no longer carries the fallback publication this guard orders"
            )
            XCTAssertLessThan(
                attach.lowerBound, publish.lowerBound,
                "\(path) publishes before it tries to repair, which duplicates the utterance"
            )
        }
    }

    // MARK: - Fixtures

    /// Stands in for a compressed 16 kHz mono AAC voice note: small, so the
    /// storage policy picks the synced lane exactly as it does in the app.
    private static let recordingBytes = Data(repeating: 0x7F, count: 4_096)

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

    /// The recorder's source from its declaration onward, with the file header
    /// dropped: the header names several of the calls the ordering guard
    /// compares, and a guard satisfied by a comment holds nothing.
    private static func recorderBody() throws -> String {
        let whole = try source("Conduck/Services/InAppAudioRecorder.swift")
        let declaration = try XCTUnwrap(
            whole.range(of: "final class InAppAudioRecorder {"),
            "the recorder's declaration moved; this guard reads the wrong region"
        )
        return String(whole[declaration.lowerBound...])
    }

    /// `.../Conduck/Conduck` — the project container holding the app sources.
    /// Derived from this file's compile-time path so the source guards do not
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
