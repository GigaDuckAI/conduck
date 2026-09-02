// SPDX-License-Identifier: Apache-2.0

// ConduckTests
// WorkboardVoiceLaneTests.swift
//
// The three surfaces that land a Work voice capture — the Shortcuts /
// Action-Button intent, and the two retry surfaces that recover one an app
// launch later — and the identities a capture needs beyond its own.
//
// One capture can produce three cards, and the whole subject here is that they
// are three IDENTITIES. The recording is named by the capture id; a screenshot
// and a note-shaped fallback are named by ids DERIVED from it. The desk answers
// a publication at an id it already holds with the card standing there, so an
// artifact published at the recording's id is not merely ignored — the
// counterfactuals below measure the recording's own bytes being replaced by the
// screenshot's, and the recovered words being written nowhere at all while the
// retry record that held the audio is cleared.
//
// The intent's own ordering cannot be driven from this suite: `perform()` takes
// an `IntentFile` the Shortcuts runtime supplies and drives a live `STTClient`
// upload, and the two retry surfaces are a SwiftUI view method and a menu-bar
// service around the same client. What is untestable there is WHERE a statement
// sits, so that is what the source guards assert — each with a negative control
// proving it bites on the shape it exists to refuse.

import XCTest
@testable import Conduck

final class WorkboardVoiceLaneTests: XCTestCase {

    private static let intentPath = "Conduck/Intents/ConverseIntent.swift"
    private static let contentViewPath = "Conduck/ContentView.swift"
    private static let dictationPath = "Conduck/MenuBar/DictationService.swift"

    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("conduck-voice-lane-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
        root = nil
        try super.tearDownWithError()
    }

    // MARK: - The Shortcuts lane publishes before it transcribes

    /// The lane the finding is about: a Shortcut or Action-Button capture bound
    /// to Work used to reach the desk only AFTER speech recognition returned, so
    /// every way that hop can fail took the recording with it. The card has to be
    /// published from bytes already in hand, above the key verdict and above the
    /// upload, and the transcript written onto it afterwards.
    func testTheShortcutsLanePublishesTheRecordingBeforeItSpendsTheTranscriptionHop() throws {
        let body = try Self.performBody()

        let armAt = try XCTUnwrap(body.range(of: "PendingRetryGuard.arm")?.lowerBound)
        let compressAt = try XCTUnwrap(
            body.range(of: "Self.compressForWork(")?.lowerBound,
            "The Work lane no longer compresses, so the card, the upload and the preserved retry copy "
            + "can drift apart into three different payloads."
        )
        let publishAt = try XCTUnwrap(
            body.range(of: "WorkVoiceCaptureCoordinator.publishRecording(")?.lowerBound,
            "The Shortcuts Work lane publishes no recording card at all — the shape the finding names, "
            + "in which the audio is discarded after STT and only a transcript reaches the desk."
        )
        let keyVerdictAt = try XCTUnwrap(body.range(of: "STTKeyReadiness.resolve")?.lowerBound)
        let transcribeAt = try XCTUnwrap(body.range(of: "STTClient.shared.transcribe")?.lowerBound)
        let attachAt = try XCTUnwrap(
            body.range(of: "WorkVoiceCaptureCoordinator.attachTranscript(")?.lowerBound,
            "The words no longer join the recording they came from."
        )

        XCTAssertLessThan(armAt, publishAt,
                          "The card is attempted with the recording ALREADY preserved, so a store that "
                          + "refuses costs the card and never the bytes.")
        XCTAssertLessThan(compressAt, publishAt,
                          "The card must hold the bytes the transcription was made from. Compressing "
                          + "afterwards would put a different payload on the desk than the one uploaded.")
        XCTAssertLessThan(publishAt, keyVerdictAt,
                          "A key that cannot be read is a transcription failure, and plan §D's whole claim "
                          + "is that such a failure leaves a playable card behind.")
        XCTAssertLessThan(publishAt, transcribeAt,
                          "Publishing after the upload is the defect: an OS kill, an outage or an "
                          + "abandoned request between the two loses the recording entirely.")
        XCTAssertLessThan(publishAt, attachAt,
                          "Phase 2 writes onto the card phase 1 made; reversed, it writes onto nothing.")
    }

    /// One capture, one payload, one identity. The bytes the card holds are the
    /// bytes STT read and the bytes the retry record preserves, and the id that
    /// names the card is the id the retry record carries — otherwise a recovered
    /// transcript cannot find the recording it came from.
    func testOneCaptureIdentityNamesTheCardTheRetryRecordAndTheTranscript() throws {
        let body = try Self.performBody()

        XCTAssertEqual(
            body.components(separatedBy: "let captureID = UUID()").count - 1, 1,
            "one capture, one identity — minted once, before anything durable is written"
        )
        XCTAssertEqual(
            body.components(separatedBy: "Self.compressForWork(").count - 1, 1,
            "compressed once: a second pass is a second payload, and only one of them can be on the card"
        )
        XCTAssertEqual(
            RefusalLaneSource.stripComments(try Self.source(Self.intentPath))
                .components(separatedBy: "AudioCompressor.compress").count - 1, 1,
            "…and exactly one site in the whole intent reaches the compressor"
        )
        XCTAssertEqual(
            body.components(separatedBy: "audio: uploadData").count - 1, 2,
            """
            The preserved retry copy and the desk card are both the bytes that were uploaded. \
            Preserving the Shortcut's original while carding the compressed one gives a retry \
            that transcribes a payload the card does not hold.
            """
        )
        XCTAssertTrue(body.contains("id: captureID,"), "the pending-retry record is named by it")
        XCTAssertTrue(body.contains("captureID: captureID,"), "the card is named by it")
        XCTAssertTrue(body.contains("toRecording: captureID"), "and the transcript is aimed at it")
    }

    /// Chat retains no audio, so it earns none of this: its upload stays the
    /// Shortcut's own recording, byte for byte, and nothing on that branch
    /// touches Workboard persistence.
    func testTheChatBranchKeepsTheShortcutsOwnRecordingBytes() throws {
        let body = try Self.performBody()
        let branches = try XCTUnwrap(
            RefusalLaneSource.branches(ofIf: "if destination == .work {", in: body),
            "The payload choice is no longer a plain if/else on the destination; update this guard."
        )

        XCTAssertTrue(branches.then.contains("Self.compressForWork("),
                      "Only the destination that KEEPS the recording pays for compressing it.")
        XCTAssertTrue(branches.else.contains("uploadData = originalAudioData"),
                      """
                      Chat must upload the bytes Shortcuts recorded, untouched. Compressing them too \
                      would change what every existing voice-only shortcut sends, for a lane that \
                      stores no audio and therefore gains nothing by it.
                      """)
        XCTAssertFalse(branches.else.contains("compressForWork"),
                       "…and it must not reach the compressor by another route.")
        XCTAssertTrue(branches.else.contains("audioFileExtension = \"m4a\""),
                      "Chat's temporary file keeps the extension the Record Audio action produces.")
    }

    /// Rule 0 for the ordering check: the shape the lane actually had — publish
    /// once STT has returned — must fail it, driven through the same comparison.
    func testTheOrderingCheckDistinguishesPublishAfterTranscriptionFromPublishBefore() throws {
        let publishesAfter = """
        let response = try await STTClient.shared.transcribe(audioFileURL: url)
        _ = try await WorkCaptureRetryCoordinator.publish(transcript: response.text)
        """
        let publishesBefore = """
        _ = try await WorkVoiceCaptureCoordinator.publishRecording(captureID: captureID)
        let response = try await STTClient.shared.transcribe(audioFileURL: url)
        """

        XCTAssertNil(publishesAfter.range(of: "WorkVoiceCaptureCoordinator.publishRecording("),
                     "Control: the shipped shape published no recording at all, so the check's "
                     + "`XCTUnwrap` is what catches it — not the ordering comparison.")
        let beforePublish = try XCTUnwrap(
            publishesBefore.range(of: "WorkVoiceCaptureCoordinator.publishRecording(")?.lowerBound
        )
        let beforeTranscribe = try XCTUnwrap(
            publishesBefore.range(of: "STTClient.shared.transcribe")?.lowerBound
        )
        XCTAssertLessThan(beforePublish, beforeTranscribe,
                          "Control: the compliant shape must pass, or the check is unsatisfiable.")
    }

    // MARK: - The screenshot's own identity

    /// The capture id names the recording, so the screenshot cannot have it. The
    /// derivation is deterministic (a replay repairs one card rather than adding
    /// a second), differs per capture, and lands in neither of the other two
    /// identities this capture can need.
    func testTheScreenshotTakesAnIdentityOfItsOwn() {
        let captureID = UUID()
        let screenshotID = WorkVoiceScreenshotCoordinator.materialID(forCapture: captureID)

        XCTAssertNotEqual(screenshotID, captureID,
                          "the recording already stands at the capture id")
        XCTAssertNotEqual(screenshotID,
                          WorkVoiceCaptureCoordinator.fallbackNoteID(forCapture: captureID),
                          "…and the note-shaped fallback of the same capture stands at its own")
        XCTAssertEqual(screenshotID,
                       WorkVoiceScreenshotCoordinator.materialID(forCapture: captureID),
                       "deterministic, so a replayed capture repairs the same card")
        XCTAssertNotEqual(screenshotID,
                          WorkVoiceScreenshotCoordinator.materialID(forCapture: UUID()),
                          "…and two captures do not share one screenshot card")
    }

    /// End to end: a capture that carries both artifacts leaves TWO cards, and
    /// the recording's bytes are untouched by the picture's arrival.
    func testTheScreenshotBecomesASecondCardBesideTheRecording() async throws {
        let store = ConversationStore(inMemory: true)
        let inbox = WorkCaptureInbox(baseURL: root)
        let captureID = UUID()
        let recording = Self.recordingBytes
        _ = try await Self.publishRecording(captureID: captureID, audio: recording, in: store)

        let picture = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46])
        let published = try await WorkVoiceScreenshotCoordinator.publish(
            Data("the shortcut's raw screenshot".utf8),
            forCapture: captureID,
            createdAt: Date(),
            inbox: inbox,
            store: store,
            sourceDevice: "test-device",
            normalize: { _ in picture }
        )
        let screenshotID = try XCTUnwrap(published, "the screenshot published nothing")

        XCTAssertEqual(screenshotID, WorkVoiceScreenshotCoordinator.materialID(forCapture: captureID))
        let deskValue = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        let desk = try XCTUnwrap(deskValue)
        XCTAssertEqual(Set(desk.materials.map(\.id)), [captureID, screenshotID],
                       "one capture, two cards")

        let card = try XCTUnwrap(desk.materials.first { $0.id == captureID })
        XCTAssertEqual(card.kind, .audio, "the recording is still a recording")
        let recordingPayload = try await store.loadWorkMaterialPayload(id: captureID)
        XCTAssertEqual(recordingPayload, recording, "and still holds the bytes that were spoken")

        let image = try XCTUnwrap(desk.materials.first { $0.id == screenshotID })
        XCTAssertEqual(image.kind, .image)
        let imagePayload = try await store.loadWorkMaterialPayload(id: screenshotID)
        XCTAssertEqual(imagePayload, picture)
    }

    /// Every surface that can recover this capture publishes the screenshot, so
    /// publishing it twice has to repair rather than duplicate.
    func testAScreenshotPublishedTwiceRepairsTheSameCard() async throws {
        let store = ConversationStore(inMemory: true)
        let inbox = WorkCaptureInbox(baseURL: root)
        let captureID = UUID()
        let picture = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46])

        let first = try await Self.publishScreenshot(picture, for: captureID, inbox: inbox, store: store)
        let second = try await Self.publishScreenshot(picture, for: captureID, inbox: inbox, store: store)

        XCTAssertEqual(first, second)
        let deskValue = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        let desk = try XCTUnwrap(deskValue)
        XCTAssertEqual(desk.materials.count, 1, "one picture, however many surfaces recovered it")
    }

    /// The counterfactual the derived id exists for, MEASURED rather than
    /// argued. Publishing the screenshot at the capture's own id does not merely
    /// fail to add a card: the desk treats the arriving bytes as a repair of the
    /// material already standing there and the recording's payload becomes the
    /// picture.
    func testAScreenshotPublishedAtTheCaptureIdWouldReplaceTheRecordingsBytes() async throws {
        let store = ConversationStore(inMemory: true)
        let captureID = UUID()
        let recording = Self.recordingBytes
        _ = try await Self.publishRecording(captureID: captureID, audio: recording, in: store)

        let picture = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46])
        _ = try await store.upsertDeskMaterial(
            WorkMaterialDraft(
                id: captureID,
                kind: .image,
                title: "screenshot.jpg",
                filename: "screenshot.jpg",
                mimeType: "image/jpeg",
                payload: picture,
                byteSize: Int64(picture.count)
            )
        )

        let deskValue = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        let desk = try XCTUnwrap(deskValue)
        XCTAssertEqual(desk.materials.count, 1, "no second card — the id was already taken")
        let collided = try await store.loadWorkMaterialPayload(id: captureID)
        XCTAssertEqual(
            collided, picture,
            """
            MEASURED: the recording's own bytes are gone, replaced by the picture, because a payload \
            arriving at an id already on the synced lane is a repair of that material. This is the \
            state `WorkVoiceScreenshotCoordinator.materialID(forCapture:)` exists to make unreachable.
            """
        )
        XCTAssertNotEqual(collided, recording)
    }

    // MARK: - The fallback note's own identity

    /// The other half of the same defect. When a capture owns no recording card
    /// the recovered words are published note-shaped — and at the capture's own
    /// id that publication is answered by whatever already stands there, writing
    /// the words nowhere while every surface goes on to clear the retry record
    /// that held the only audio.
    func testTheFallbackNoteLandsBesideTheRecordingRatherThanVanishingIntoIt() async throws {
        let store = ConversationStore(inMemory: true)
        let captureID = UUID()
        _ = try await Self.publishRecording(captureID: captureID, audio: Self.recordingBytes, in: store)
        let words = "Ferry leaves at 07:30"

        // The shape the finding names: the fallback minted at the capture id.
        let collided = try await store.upsertDeskMaterial(
            WorkMaterialDraft(
                id: captureID,
                kind: .note,
                title: "Voice capture",
                textContent: words,
                storageMode: .metadataOnly
            )
        )
        XCTAssertEqual(collided.kind, .audio,
                       "MEASURED: the desk answers with the recording already standing there")
        XCTAssertNil(collided.textContent, "…and the recovered words are written nowhere at all")

        // The shape it takes now.
        let noteID = WorkVoiceCaptureCoordinator.fallbackNoteID(forCapture: captureID)
        XCTAssertNotEqual(noteID, captureID)
        let note = try await store.upsertDeskMaterial(
            WorkMaterialDraft(
                id: noteID,
                kind: .note,
                title: "Voice capture",
                textContent: words,
                storageMode: .metadataOnly
            )
        )
        XCTAssertEqual(note.kind, .note)
        XCTAssertEqual(note.textContent, words)

        let deskValue = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        let desk = try XCTUnwrap(deskValue)
        XCTAssertEqual(Set(desk.materials.map(\.id)), [captureID, noteID],
                       "the words stand beside the recording instead of inside it")
        let recordingPayload = try await store.loadWorkMaterialPayload(id: captureID)
        XCTAssertEqual(recordingPayload, Self.recordingBytes,
                       "and a metadata-only note carries no bytes that could disturb the recording")
    }

    // MARK: - Both retry surfaces keep the retry when the store refuses

    /// A thrown attach and a missing recording are different facts, and every
    /// surface that recovers a parked transcript has to keep them apart. Collapse
    /// the throw into "there was no recording" and the surface publishes a
    /// fallback the desk answers with the recording, then clears the retry record
    /// — deleting the only audio those words were ever made from.
    ///
    /// Kept as a source guard rather than converted: both surfaces are UI —
    /// a SwiftUI view method and a menu-bar service — around a live `STTClient`,
    /// and neither can be reached without mounting one.
    func testNeitherRetrySurfaceCollapsesAThrownAttachIntoAMissingRecording() throws {
        for (path, function) in Self.retrySurfaces {
            let body = try Self.functionBody(function, in: path)

            XCTAssertFalse(
                body.contains("try? await WorkVoiceCaptureCoordinator.attachTranscript"),
                "\(path): `try?` turns a store that refused the write into a store that found no "
                + "recording, and the fallback below then publishes into the recording's own id."
            )
            let attachAt = try XCTUnwrap(
                body.range(of: "WorkVoiceCaptureCoordinator.attachTranscript(")?.lowerBound,
                "\(path) recovers a Work transcript without offering it to the recording card"
            )
            let clearAt = try XCTUnwrap(
                body.range(of: "PendingRetryStore.shared.clear(ifCurrentID:")?.lowerBound,
                "\(path) no longer clears the retry it consumed; update this guard"
            )
            XCTAssertLessThan(
                attachAt, clearAt,
                "\(path): the clear has to sit BELOW the attach and inside the same `do`, so a throw "
                + "skips it and the recording survives to be recovered again."
            )
        }
    }

    /// …and the fallback they publish may not be minted at the capture id, for
    /// the reason the counterfactual above measures.
    func testNeitherRetrySurfacePublishesItsFallbackUnderTheCaptureId() throws {
        for (path, function) in Self.retrySurfaces {
            let body = try Self.functionBody(function, in: path)
            let publishAt = try XCTUnwrap(
                body.range(of: "WorkCaptureRetryCoordinator.publish(")?.lowerBound,
                "\(path) no longer carries the fallback publication this guard orders"
            )
            let attachAt = try XCTUnwrap(
                body.range(of: "WorkVoiceCaptureCoordinator.attachTranscript(")?.lowerBound
            )
            XCTAssertLessThan(attachAt, publishAt,
                              "\(path) publishes before it tries to repair, which duplicates the utterance")
            XCTAssertTrue(
                body.contains("WorkVoiceCaptureCoordinator.fallbackNoteID("),
                "\(path): the fallback must take a derived id, or it is answered by the card already "
                + "standing at the capture's own."
            )
            XCTAssertFalse(
                body.contains("captureID: pending.metadata.id"),
                "\(path): the capture id names the RECORDING. A publication under it is returned "
                + "unchanged, the drainer acknowledges an envelope that wrote nothing, and the clear "
                + "below destroys the retry audio."
            )
        }
    }

    /// Rule 0 for the two guards above — the shipped shape must fail both halves.
    func testTheRetrySurfaceGuardsDistinguishTheCollapsingShape() throws {
        let collapsing = """
        let attached = (try? await WorkVoiceCaptureCoordinator.attachTranscript(
            trimmed, toRecording: pending.metadata.id)) ?? false
        if !attached {
            _ = try await WorkCaptureRetryCoordinator.publish(
                transcript: trimmed, captureID: pending.metadata.id)
        }
        _ = await PendingRetryStore.shared.clear(ifCurrentID: pending.metadata.id)
        """
        let compliant = """
        switch try await WorkVoiceCaptureCoordinator.attachTranscript(
            trimmed, toRecording: pending.metadata.id) {
        case .attached:
            break
        case .recordingMissing, .notAudio:
            _ = try await WorkCaptureRetryCoordinator.publish(
                transcript: trimmed,
                captureID: WorkVoiceCaptureCoordinator.fallbackNoteID(
                    forCapture: pending.metadata.id))
        }
        _ = await PendingRetryStore.shared.clear(ifCurrentID: pending.metadata.id)
        """

        XCTAssertTrue(collapsing.contains("try? await WorkVoiceCaptureCoordinator.attachTranscript"),
                      "Control: the shipped shape really did swallow the throw.")
        XCTAssertTrue(collapsing.contains("captureID: pending.metadata.id"),
                      "Control: …and really did mint its fallback at the recording's id.")
        XCTAssertFalse(compliant.contains("try? await WorkVoiceCaptureCoordinator.attachTranscript"),
                       "Control: the compliant shape must pass both halves, or the guards are "
                       + "unsatisfiable.")
        XCTAssertFalse(compliant.contains("captureID: pending.metadata.id"))
        XCTAssertTrue(compliant.contains("WorkVoiceCaptureCoordinator.fallbackNoteID("))
    }

    // MARK: - Fixtures

    /// The two surfaces that recover a parked Work transcript, and the function
    /// on each that owns the decision. A third one must be added here rather
    /// than merely copying the publish call.
    private static let retrySurfaces: [(path: String, function: String)] = [
        (contentViewPath, "runPendingRetry"),
        (dictationPath, "retryLast"),
    ]

    /// Stands in for a compressed 16 kHz mono AAC voice note: small, so the
    /// storage policy picks the synced lane exactly as it does in the app.
    private static let recordingBytes = Data(repeating: 0x5A, count: 4_096)

    @discardableResult
    private static func publishRecording(
        captureID: UUID,
        audio: Data,
        in store: ConversationStore
    ) async throws -> WorkMaterialRecord {
        try await WorkVoiceCaptureCoordinator.publishRecording(
            captureID: captureID,
            audio: audio,
            fileExtension: "m4a",
            mimeType: "audio/mp4",
            store: store
        )
    }

    private static func publishScreenshot(
        _ jpeg: Data,
        for captureID: UUID,
        inbox: WorkCaptureInbox,
        store: ConversationStore
    ) async throws -> UUID? {
        try await WorkVoiceScreenshotCoordinator.publish(
            Data("the shortcut's raw screenshot".utf8),
            forCapture: captureID,
            createdAt: Date(),
            inbox: inbox,
            store: store,
            sourceDevice: "test-device",
            normalize: { _ in jpeg }
        )
    }

    private static func performBody() throws -> String {
        try functionBody("perform", in: intentPath)
    }

    /// One function's body, comment-stripped. Both halves matter: scoping to the
    /// function keeps an unrelated statement elsewhere in a 1,600-line view from
    /// satisfying an ordering check, and stripping comments keeps a header that
    /// DESCRIBES the rule from standing in for code that does it.
    private static func functionBody(_ name: String, in path: String) throws -> String {
        let source = RefusalLaneSource.stripComments(try self.source(path))
        return try RefusalLaneSource.body(ofFunction: name, in: source, path: path)
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
