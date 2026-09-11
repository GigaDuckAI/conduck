// SPDX-License-Identifier: Apache-2.0

// ConduckTests
// WorkCaptureDrainerAudioKindTests.swift
//
// A capture's file entry carries no card kind — the envelope has one file kind
// for every payload — so the drainer decides what a file IS. For a recording the
// answer is nothing: Work keeps an audio file only when a person attaches it at
// the desk itself, and every capture in this queue was assembled by a process
// nobody was watching.
//
// So the cases here are about a refusal that is not a failure. The recording
// writes no card and no bytes anywhere; its siblings land; the claim is
// acknowledged the ordinary way, which is what takes the recording off the
// device. And nothing is copied into `refused/` — nothing sweeps that directory,
// so a copy there would be a permanent holder of what a person said, which is
// the exact thing the refusal exists to prevent.
//
// Everything that is not audio has to stay the card it was. Core Data is
// in-memory and no transport is touched.

import XCTest
@testable import Conduck

final class WorkCaptureDrainerAudioKindTests: XCTestCase {
    private var root: URL!

    /// Each store mints a vault of its own, and the cases here publish real
    /// payload leaves into it; the fixture empties them when the class is done.
    private let isolated = IsolatedWorkStores()

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("conduck-work-audio-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        await isolated.cleanUp()
        if let root { try? FileManager.default.removeItem(at: root) }
        root = nil
        try await super.tearDown()
    }

    // MARK: - A recording leaves no card, and leaves the device

    func testARecordingEntryLeavesNoCardAndItsBytesLeaveTheQueue() async throws {
        let store = isolated.make()
        let recordingID = UUID()
        let payload = Data("compressed recording".utf8)
        let envelope = WorkCaptureEnvelope(
            note: "",
            source: .shortcut,
            entries: [
                .init(
                    id: recordingID,
                    kind: .file,
                    sequence: 0,
                    relativePath: "payload-000.m4a",
                    displayName: "memo.m4a",
                    mimeType: "audio/mp4",
                    byteCount: Int64(payload.count)
                )
            ]
        )
        try publish(envelope, payloads: ["payload-000.m4a": payload])

        let report = try await makeDrainer(store: store).drainAvailableCaptures()

        let refusedCard = try await material(recordingID, in: store)
        XCTAssertNil(refusedCard, "a recording the desk refused is not a card of any kind")
        XCTAssertEqual(report.refusedEntryCount, 1)
        XCTAssertEqual(report.importedMaterialCount, 0)
        XCTAssertEqual(
            report.invalidCaptureCount, 0,
            "nothing malfunctioned: the capture was claimed, read and answered"
        )

        // THE POINT: the bytes are gone from this device, not parked somewhere
        // the desk cannot show and nothing sweeps.
        let pending = try await WorkCaptureInbox(baseURL: root).pendingCount()
        XCTAssertEqual(pending, 0, "the claim is acknowledged the ordinary way")
        XCTAssertEqual(try filesUnderRoot(), [], "no copy of the recording survives anywhere")
    }

    /// Sources that annotate with a UTI instead of a MIME type are the same
    /// recording. Conformance rather than equality, so any concrete audio type
    /// answers.
    func testATypeIdentifierConformingToAudioIsRefusedToo() async throws {
        let store = isolated.make()
        let recordingID = UUID()
        let payload = Data("mp3 bytes".utf8)
        let envelope = WorkCaptureEnvelope(
            note: "",
            source: .shareExtension,
            entries: [
                .init(
                    id: recordingID,
                    kind: .file,
                    sequence: 0,
                    relativePath: "payload-000.mp3",
                    displayName: "interview.mp3",
                    typeIdentifier: "public.mp3",
                    byteCount: Int64(payload.count)
                )
            ]
        )
        try publish(envelope, payloads: ["payload-000.mp3": payload])

        let report = try await makeDrainer(store: store).drainAvailableCaptures()

        let refusedCard = try await material(recordingID, in: store)
        XCTAssertNil(refusedCard)
        XCTAssertEqual(report.refusedEntryCount, 1)
        XCTAssertEqual(try filesUnderRoot(), [])
    }

    // MARK: - The rest of the capture is untouched

    /// The refusal takes the entry, never the capture around it. A screenshot
    /// shared together with a voice memo still becomes the card the person
    /// expects, and the note they typed with it still lands.
    func testAScreenshotBesideARefusedRecordingStillLands() async throws {
        let store = isolated.make()
        let screenshotID = UUID()
        let recordingID = UUID()
        let image = Data("png bytes".utf8)
        let recording = Data("compressed recording".utf8)
        let envelope = WorkCaptureEnvelope(
            note: "From the site visit",
            source: .shareExtension,
            entries: [
                .init(
                    id: screenshotID,
                    kind: .image,
                    sequence: 0,
                    relativePath: "payload-000.png",
                    displayName: "IMG.png",
                    mimeType: "image/png",
                    byteCount: Int64(image.count)
                ),
                .init(
                    id: recordingID,
                    kind: .file,
                    sequence: 1,
                    relativePath: "payload-001.m4a",
                    displayName: "memo.m4a",
                    mimeType: "audio/mp4",
                    byteCount: Int64(recording.count)
                ),
            ]
        )
        try publish(envelope, payloads: [
            "payload-000.png": image,
            "payload-001.m4a": recording,
        ])

        let report = try await makeDrainer(store: store).drainAvailableCaptures()

        let screenshot = try await material(screenshotID, in: store)
        let card = try XCTUnwrap(screenshot)
        XCTAssertEqual(card.kind, .image)
        let storedImage = try await store.loadWorkMaterialPayload(id: screenshotID)
        XCTAssertEqual(storedImage, image)
        let refusedCard = try await material(recordingID, in: store)
        XCTAssertNil(refusedCard)
        XCTAssertEqual(
            report.importedMaterialCount, 2,
            "the shared note and the screenshot are the cards this capture wrote"
        )
        XCTAssertEqual(report.refusedEntryCount, 1)
        XCTAssertEqual(report.importedCaptureCount, 1)
        XCTAssertEqual(try filesUnderRoot(), [], "and the recording still left with the claim")
    }

    /// `refused/` is the drainer's one durable copy outside the desk, and
    /// nothing sweeps it. A recording may never reach it — a refusal that
    /// filed the bytes away would be a third permanent holder of what a person
    /// said rather than a refusal at all.
    func testNoRefusedDirectoryAppears() async throws {
        let store = isolated.make()
        let payload = Data("compressed recording".utf8)
        let envelope = WorkCaptureEnvelope(
            note: "",
            source: .shortcut,
            entries: [
                .init(
                    id: UUID(),
                    kind: .file,
                    sequence: 0,
                    relativePath: "payload-000.m4a",
                    displayName: "memo.m4a",
                    mimeType: "audio/mp4",
                    byteCount: Int64(payload.count)
                )
            ]
        )
        try publish(envelope, payloads: ["payload-000.m4a": payload])

        _ = try await makeDrainer(store: store).drainAvailableCaptures()

        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent("refused", isDirectory: true).path
            ),
            "a refused recording is not filed away; it is not kept"
        )
    }

    // MARK: - Everything that is not a recording is unaffected

    func testANonAudioFileStaysAFileCard() async throws {
        let store = isolated.make()
        let documentID = UUID()
        let payload = Data("%PDF-1.7".utf8)
        let envelope = WorkCaptureEnvelope(
            note: "",
            source: .shortcut,
            entries: [
                .init(
                    id: documentID,
                    kind: .file,
                    sequence: 0,
                    relativePath: "payload-000.pdf",
                    displayName: "proposal.pdf",
                    mimeType: "application/pdf",
                    typeIdentifier: "com.adobe.pdf",
                    byteCount: Int64(payload.count)
                )
            ]
        )
        try publish(envelope, payloads: ["payload-000.pdf": payload])

        let report = try await makeDrainer(store: store).drainAvailableCaptures()

        let document = try await material(documentID, in: store)
        let card = try XCTUnwrap(document)
        XCTAssertEqual(card.kind, .file)
        XCTAssertEqual(report.refusedEntryCount, 0)
    }

    /// The mapping reads the file, not the annotation alone: an image entry is
    /// still an image however its source labelled it.
    func testAnImageEntryIsUnaffected() async throws {
        let store = isolated.make()
        let imageID = UUID()
        let payload = Data("png bytes".utf8)
        let envelope = WorkCaptureEnvelope(
            note: "",
            source: .shareExtension,
            entries: [
                .init(
                    id: imageID,
                    kind: .image,
                    sequence: 0,
                    relativePath: "payload-000.png",
                    displayName: "IMG.png",
                    mimeType: "image/png",
                    byteCount: Int64(payload.count)
                )
            ]
        )
        try publish(envelope, payloads: ["payload-000.png": payload])

        _ = try await makeDrainer(store: store).drainAvailableCaptures()

        let imported = try await material(imageID, in: store)
        let card = try XCTUnwrap(imported)
        XCTAssertEqual(card.kind, .image)
    }

    // MARK: - Fixtures

    private func material(
        _ id: UUID,
        in store: ConversationStore
    ) async throws -> WorkMaterialRecord? {
        let desk = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        return desk?.materials.first { $0.id == id }
    }

    /// Every regular file left anywhere under the inbox root, by name. The queue
    /// scaffolds empty `processing/` and `tmp/` directories it never fills on
    /// its own, so an empty answer here means every byte a capture carried is
    /// off this device.
    private func filesUnderRoot() throws -> [String] {
        guard let walker = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey]
        ) else { return [] }
        var names: [String] = []
        for case let url as URL in walker {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            if values.isRegularFile == true { names.append(url.lastPathComponent) }
        }
        return names.sorted()
    }

    private func makeDrainer(store: ConversationStore) -> WorkCaptureDrainer {
        WorkCaptureDrainer(
            inbox: WorkCaptureInbox(baseURL: root),
            store: store,
            sourceDevice: "test-device"
        )
    }

    private func publish(
        _ envelope: WorkCaptureEnvelope,
        payloads: [String: Data] = [:]
    ) throws {
        let directory = root.appendingPathComponent(envelope.id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        for (relativePath, bytes) in payloads {
            try bytes.write(
                to: directory.appendingPathComponent(relativePath, isDirectory: false),
                options: .atomic
            )
        }
        try envelope.encoded().write(
            to: directory.appendingPathComponent("manifest.json"),
            options: .atomic
        )
    }
}
