// SPDX-License-Identifier: Apache-2.0

// ConduckTests
// WorkCaptureDrainerAudioKindTests.swift
//
// A capture's file entry carries no card kind — the envelope has one file kind
// for every payload — so the drainer decides what a file IS. A recording that
// arrives through the share sheet or a Shortcut has to become the same playable
// card the app's own recorder writes, and everything that is not audio has to
// stay the file card it was. Core Data is in-memory and no transport is touched.

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

    func testAnAudioMIMETypeMakesAPlayableCard() async throws {
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

        _ = try await makeDrainer(store: store).drainAvailableCaptures()

        let card = try await unwrapMaterial(recordingID, in: store)
        XCTAssertEqual(card.kind, .audio, "a recording on the desk is a card that plays")
        XCTAssertEqual(card.mimeType, "audio/mp4")
        let bytes = try await store.loadWorkMaterialPayload(id: recordingID)
        XCTAssertEqual(bytes, payload, "recognising the kind must not cost the bytes")
    }

    /// Sources that annotate with a UTI instead of a MIME type are the same
    /// recording. Conformance rather than equality, so any concrete audio type
    /// answers.
    func testATypeIdentifierConformingToAudioMakesAPlayableCard() async throws {
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

        _ = try await makeDrainer(store: store).drainAvailableCaptures()

        let card = try await unwrapMaterial(recordingID, in: store)
        XCTAssertEqual(card.kind, .audio)
    }

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

        _ = try await makeDrainer(store: store).drainAvailableCaptures()

        let card = try await unwrapMaterial(documentID, in: store)
        XCTAssertEqual(card.kind, .file)
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

        let card = try await unwrapMaterial(imageID, in: store)
        XCTAssertEqual(card.kind, .image)
    }

    // MARK: - Fixtures

    private func unwrapMaterial(
        _ id: UUID,
        in store: ConversationStore
    ) async throws -> WorkMaterialRecord {
        let desk = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        let materials = try XCTUnwrap(desk?.materials, "every capture resolves the one desk")
        return try XCTUnwrap(materials.first { $0.id == id })
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
