// SPDX-License-Identifier: Apache-2.0

// ConduckTests
// WorkboardAudioFileImportTests.swift
//
// The in-app doors' recording, all the way to the store. `WorkboardImportMapping`
// decides the SHAPE; this holds what that shape is worth once the desk write has
// had it: bytes that come back byte-for-byte, a name Share and Open can hand to
// the system, no transcript invented on the way, and the same size rule every
// other payload obeys — the private CloudKit lane below the ceiling, the
// device-local vault above it.
//
// Driven through `WorkboardLiveRepository`'s own import dependency rather than
// the store directly, because the seam under test is the whole path a picked or
// dropped file takes: the import prepares the draft, the store publishes it, and
// the board build is what says the card carries a transport.

#if !os(watchOS)

import Foundation
import XCTest
@testable import Conduck

@MainActor
final class WorkboardAudioFileImportTests: XCTestCase {

    /// Every store here mints a vault directory of its own that nothing else
    /// removes; the fixture empties them when the class is done.
    private let isolated = IsolatedWorkStores()
    private var scratchURLs: [URL] = []

    override func tearDown() async throws {
        for url in scratchURLs { try? FileManager.default.removeItem(at: url) }
        scratchURLs = []
        await isolated.cleanUp()
        try await super.tearDown()
    }

    // MARK: - Fixtures

    private func makeRepository(_ store: ConversationStore) -> WorkboardLiveRepository {
        let inboxURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("workboard-audio-import-\(UUID().uuidString)")
        scratchURLs.append(inboxURL)
        return WorkboardLiveRepository(
            store: store,
            captureInbox: WorkCaptureInbox(baseURL: inboxURL),
            openMaterial: { _ in }
        )
    }

    private func recordingFile(named name: String, byteCount: Int) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("workboard-audio-import-\(UUID().uuidString)-\(name)")
        // Not a decodable clip: the desk write copies and measures bytes, and
        // nothing on this path decodes them. A real clip of 30 MB would make
        // the ceiling case cost a minute for nothing.
        var bytes = Data(count: byteCount)
        bytes.replaceSubrange(0..<4, with: Data([0x00, 0x00, 0x00, 0x20]))
        try bytes.write(to: url, options: .atomic)
        scratchURLs.append(url)
        return url
    }

    private func importRecording(
        into repository: WorkboardLiveRepository,
        from url: URL,
        named name: String,
        byteCount: Int
    ) async throws -> WorkboardItemSnapshot {
        try await repository.makeDependencies().importMaterial(
            nil,
            WorkboardMaterialImport(
                kind: .audio,
                name: name,
                mimeType: "audio/mp4",
                fileURL: url,
                byteCount: Int64(byteCount)
            ),
            { _ in }
        )
    }

    // MARK: - Below the ceiling

    /// The founder's case: a voice memo added through the Work pane is a card
    /// that plays, keeps the name it arrived under, and rides the ordinary
    /// synced lane like any other small payload.
    ///
    /// Negative control: an import that dropped the audio kind publishes a
    /// `.file` — the kind and presentation assertions fail — and one that
    /// dropped the filename exports the clip as an unnamed blob, which the
    /// filename assertion catches.
    func testARecordingAddedInTheWorkPaneIsStoredAsAPlayableSyncedCard() async throws {
        let store = isolated.make()
        let repository = makeRepository(store)
        let byteCount = 64 * 1_024
        let source = try recordingFile(named: "memo.m4a", byteCount: byteCount)
        let original = try Data(contentsOf: source)

        let desk = try await importRecording(
            into: repository,
            from: source,
            named: "memo.m4a",
            byteCount: byteCount
        )

        let storedValue = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        let record = try XCTUnwrap(try XCTUnwrap(storedValue).materials.first)
        XCTAssertEqual(record.kind, .audio, "the desk holds a recording, not a document")
        XCTAssertEqual(record.mimeType, "audio/mp4")
        XCTAssertEqual(
            record.filename, "memo.m4a",
            "Share and Open hand this name to the system; a recording stripped of it exports unnamed"
        )
        XCTAssertEqual(record.storageMode, .syncedPayload, "well under the sync ceiling")
        XCTAssertNil(record.textContent, "the in-app doors keep bytes; nothing transcribes them")
        XCTAssertNil(
            record.attachedToMaterialID,
            "a file the person added names no picture: it is nobody's companion"
        )

        let payload = try await store.loadWorkMaterialPayload(id: record.id)
        XCTAssertEqual(payload, original, "the clip is kept byte for byte")

        let card = try XCTUnwrap(desk.materials.first)
        XCTAssertEqual(card.kind, .audio, "and the board draws it with a transport")
        XCTAssertEqual(card.availability, .available)
        XCTAssertEqual(card.name, "memo.m4a")
        XCTAssertNil(card.companion, "a standalone recording folds into nothing")
    }

    // MARK: - Above the ceiling

    /// A long recording obeys the same size rule every other payload does: past
    /// the sync ceiling the bytes stay on this device and only the card's
    /// metadata syncs.
    ///
    /// Negative control: a lane decision keyed on the kind rather than on the
    /// size would push a 30 MB clip through private CloudKit — the storage-mode
    /// assertion fails.
    func testARecordingAboveTheSyncCeilingStaysInTheDeviceVault() async throws {
        let store = isolated.make()
        let repository = makeRepository(store)
        let byteCount = Int(Constants.workboardSyncCeilingBytes) + 1_024
        let source = try recordingFile(named: "interview.m4a", byteCount: byteCount)

        let desk = try await importRecording(
            into: repository,
            from: source,
            named: "interview.m4a",
            byteCount: byteCount
        )

        let storedValue = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        let record = try XCTUnwrap(try XCTUnwrap(storedValue).materials.first)
        XCTAssertEqual(record.kind, .audio)
        XCTAssertEqual(record.storageMode, .localVault)
        XCTAssertEqual(record.filename, "interview.m4a")
        XCTAssertNil(record.textContent)
        XCTAssertEqual(record.byteSize, Int64(byteCount))

        let payload = try await store.loadWorkMaterialPayload(id: record.id)
        XCTAssertEqual(payload?.count, byteCount, "the vault holds the whole clip")

        let card = try XCTUnwrap(desk.materials.first)
        XCTAssertEqual(card.kind, .audio)
        XCTAssertEqual(
            card.availability, .localOnly,
            "readable here, and the card says the bytes went nowhere else"
        )
    }
}

#endif
