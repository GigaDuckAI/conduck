// SPDX-License-Identifier: Apache-2.0

// Authored text is a focused material edit: preserve original bytes, source
// metadata and filing; reject stale/deleted targets; retain canonical source
// precedence when CloudKit has produced heterogeneous physical duplicates.
import XCTest
@testable import Conduck

final class WorkMaterialTextPersistenceTests: XCTestCase {
    private let isolated = IsolatedWorkStores()
    override func tearDown() async throws {
        await isolated.cleanUp()
        try await super.tearDown()
    }

    private func edit(_ material: WorkMaterialRecord, in store: ConversationStore,
                      body: String? = nil, notes: String? = nil) async throws -> WorkMaterialRecord {
        try await store.updateWorkMaterialText(id: material.id, textContent: body, annotation: notes,
            expectedRevision: WorkboardRevision.value(for: material.updatedAt))
    }

    func testTextAndAnnotationRoundTripPreserveMetadataPlacementAndCompanion() async throws {
        let store = isolated.make()
        let project = WorkDeskProjectRecord(title: "Research")
        _ = try await store.applyWorkDeskMutation(.createProject(project, materialIDs: []))
        let parentID = UUID()
        let original = try await store.upsertDeskMaterial(WorkMaterialDraft(kind: .transcript,
            title: "Deliberate title", caption: "Provenance", textContent: "Original words",
            sourceDevice: "test", attachedToMaterialID: parentID), projectID: project.id)
        let organization = try await store.fetchWorkDeskOrganization()
        let result = try await edit(original, in: store, body: "Corrected words", notes: "Added notes\nSecond line")
        XCTAssertEqual(result.textContent, "Corrected words")
        XCTAssertEqual(result.annotation, "Added notes\nSecond line")
        XCTAssertEqual(result.title, original.title)
        XCTAssertEqual(result.caption, original.caption)
        XCTAssertEqual(result.sourceDevice, original.sourceDevice)
        XCTAssertEqual(result.attachedToMaterialID, parentID)
        XCTAssertEqual(result.sequence, original.sequence)
        XCTAssertGreaterThan(result.updatedAt, original.updatedAt)
        let after = try await store.fetchWorkDeskOrganization()
        XCTAssertEqual(after, organization)
        let snapshot = await WorkboardLiveRepository.presentationSnapshotForTesting(result)
        let companion = await MainActor.run { WorkboardCompanionSnapshot(snapshot).material }
        XCTAssertEqual(snapshot.annotation, result.annotation)
        XCTAssertEqual(companion.annotation, result.annotation)
    }

    func testFileNotesPreserveBytesAndBlobRows() async throws {
        let store = isolated.make()
        let bytes = Data("original source".utf8)
        let original = try await store.upsertDeskMaterial(WorkMaterialDraft(kind: .file, title: "Source",
            caption: "Original provenance", filename: "source.txt", mimeType: "text/plain", payload: bytes))
        let blobs = await store._workMaterialBlobRowsForTesting(materialID: original.id)
        let result = try await edit(original, in: store, notes: "Read paragraph two")
        XCTAssertEqual(result.annotation, "Read paragraph two")
        XCTAssertNil(result.textContent)
        XCTAssertEqual(result.contentHash, original.contentHash)
        XCTAssertEqual(result.storageMode, original.storageMode)
        XCTAssertEqual(result.caption, original.caption)
        let sourceBefore = await WorkboardLiveRepository.presentationSnapshotForTesting(original)
        let sourceAfter = await WorkboardLiveRepository.presentationSnapshotForTesting(result)
        XCTAssertNotNil(sourceBefore.sourceByteIdentity)
        XCTAssertEqual(sourceBefore.sourceByteIdentity, sourceAfter.sourceByteIdentity)
        let payload = try await store.loadWorkMaterialPayload(id: original.id)
        let afterBlobs = await store._workMaterialBlobRowsForTesting(materialID: original.id)
        XCTAssertEqual(payload, bytes)
        XCTAssertEqual(afterBlobs, blobs)
    }

    func testLocalVaultFileNotesDoNotExportTheFileContent() async throws {
        let store = isolated.make()
        _ = try await store.upsertDeskMaterial(WorkMaterialDraft(kind: .note, textContent: "Seed"))
        let bytes = Data("device-local content".utf8)
        let original = try await store.addWorkMaterial(WorkMaterialDraft(kind: .file, title: "Local",
            filename: "source.bin", mimeType: "application/octet-stream", payload: bytes), to: Constants.workboardDeskItemID)
        let result = try await edit(original, in: store, notes: "My separate notes")
        XCTAssertEqual(result.annotation, "My separate notes")
        XCTAssertNil(result.textContent)
        XCTAssertEqual(result.storageMode, .localVault)
        XCTAssertEqual(result.localVaultKey, original.localVaultKey)
        let sourceBefore = await WorkboardLiveRepository.presentationSnapshotForTesting(original)
        let sourceAfter = await WorkboardLiveRepository.presentationSnapshotForTesting(result)
        XCTAssertNotNil(sourceBefore.sourceByteIdentity)
        XCTAssertEqual(sourceBefore.sourceByteIdentity, sourceAfter.sourceByteIdentity)
        let inline = await store._workMaterialPayloadColumnForTesting(id: original.id)
        let payload = try await store.loadWorkMaterialPayload(id: original.id)
        XCTAssertNil(inline)
        XCTAssertEqual(payload, bytes)
    }

    func testOnlyNotesAndTranscriptsAcceptSourceBodyChanges() async throws {
        let store = isolated.make()
        for kind: WorkMaterialKind in [.file, .image, .link, .audio] {
            let original = try await store.upsertDeskMaterial(WorkMaterialDraft(kind: kind, title: "Original",
                textContent: kind == .link ? "https://example.com" : nil,
                urlString: kind == .link ? "https://example.com" : nil))
            do {
                _ = try await edit(original, in: store, body: "Replacement", notes: "Also rejected")
                XCTFail("Source body must stay unchanged for \(kind)")
            } catch WorkboardStoreError.invalidMaterialOwner { }
            let unchanged = try await store.fetchWorkMaterial(id: original.id)
            XCTAssertEqual(unchanged?.textContent, original.textContent)
            XCTAssertEqual(unchanged?.urlString, original.urlString)
            XCTAssertNil(unchanged?.annotation)
            let annotated = try await edit(original, in: store, notes: "Permitted user notes")
            XCTAssertEqual(annotated.annotation, "Permitted user notes")
        }
    }

    func testStaleDraftIsRefusedAndUnrelatedCardDoesNotConflict() async throws {
        let store = isolated.make()
        let first = try await store.upsertDeskMaterial(WorkMaterialDraft(kind: .note, textContent: "First"))
        let second = try await store.upsertDeskMaterial(WorkMaterialDraft(kind: .note, textContent: "Second"))
        _ = try await edit(first, in: store, body: "New first")
        _ = try await edit(second, in: store, body: "New second")
        do {
            _ = try await edit(first, in: store, body: "Old draft", notes: "Stale")
            XCTFail("Stale draft must not overwrite current text")
        } catch WorkboardStoreError.staleRevision { }
        let latest = try await store.fetchWorkMaterial(id: first.id)
        XCTAssertEqual(latest?.textContent, "New first")
        XCTAssertNil(latest?.annotation)
    }

    func testDeletedMaterialIsNotRecreatedByEditorSave() async throws {
        let store = isolated.make()
        let original = try await store.upsertDeskMaterial(WorkMaterialDraft(kind: .note, textContent: "Original"))
        try await store.deleteWorkMaterial(id: original.id)
        do {
            _ = try await edit(original, in: store, body: "Open draft")
            XCTFail("Deleted card must stay deleted")
        } catch WorkboardStoreError.materialNotFound { }
        let latest = try await store.fetchWorkMaterial(id: original.id)
        XCTAssertNil(latest)
    }

    func testOlderConflictingDuplicateCannotReplaceCanonicalFileAfterAnnotationEdit() async throws {
        let store = isolated.make()
        let bytes = Data("canonical file content".utf8)
        let original = try await store.upsertDeskMaterial(WorkMaterialDraft(kind: .file, title: "Canonical source",
            filename: "source.txt", mimeType: "text/plain", payload: bytes))
        let staleCompanion = UUID()
        await store._duplicateWorkMaterialRowForTesting(id: original.id,
            updatedAt: original.updatedAt.addingTimeInterval(-10), contentHash: "zzzz-stale-source-hash",
            sequence: 9, attachedToMaterialID: staleCompanion)
        let before = await store._workMaterialRowsForTesting(id: original.id)
        let result = try await edit(original, in: store, notes: "Notes on the canonical source")
        XCTAssertEqual(result.contentHash, original.contentHash)
        XCTAssertEqual(result.sequence, original.sequence)
        XCTAssertEqual(result.attachedToMaterialID, original.attachedToMaterialID)
        let payload = try await store.loadWorkMaterialPayload(id: original.id)
        XCTAssertEqual(payload, bytes)
        let after = await store._workMaterialRowsForTesting(id: original.id)
        XCTAssertEqual(after.count, 2)
        XCTAssertTrue(after.allSatisfy { $0.annotation == "Notes on the canonical source" })
        XCTAssertEqual(Set(after.map(\.contentHash)), Set(before.map(\.contentHash)))
        XCTAssertEqual(Set(after.map(\.sequence)), Set(before.map(\.sequence)))
        XCTAssertEqual(Set(after.map(\.attachedToMaterialID)), Set(before.map(\.attachedToMaterialID)))
        let selected = try XCTUnwrap(after.first { $0.contentHash == original.contentHash })
        let stale = try XCTUnwrap(after.first { $0.contentHash == "zzzz-stale-source-hash" })
        XCTAssertGreaterThan(try XCTUnwrap(selected.updatedAt), try XCTUnwrap(stale.updatedAt))
    }

    func testDuplicateRowsBothReceiveCorrectedText() async throws {
        let store = isolated.make()
        let original = try await store.upsertDeskMaterial(WorkMaterialDraft(kind: .note, textContent: "Original"))
        await store._duplicateWorkMaterialRowForTesting(id: original.id)
        _ = try await edit(original, in: store, body: "Corrected", notes: "Shared annotation")
        let rows = await store._workMaterialRowsForTesting(id: original.id)
        XCTAssertEqual(rows.count, 2)
        XCTAssertTrue(rows.allSatisfy { $0.textContent == "Corrected" && $0.annotation == "Shared annotation" })
    }

    func testNoOpKeepsRevisionAndWhitespaceNotesClearOnlyAnnotation() async throws {
        let store = isolated.make()
        let original = try await store.upsertDeskMaterial(WorkMaterialDraft(kind: .note,
            textContent: "Body", annotation: "Existing notes"))
        let noOp = try await edit(original, in: store, notes: "Existing notes")
        XCTAssertEqual(noOp.updatedAt, original.updatedAt)
        let cleared = try await edit(noOp, in: store, notes: " \n ")
        XCTAssertNil(cleared.annotation)
        XCTAssertEqual(cleared.textContent, "Body")
    }

    func testOverlongNotesRefuseWholeEditWithoutTruncation() async throws {
        let store = isolated.make()
        let original = try await store.upsertDeskMaterial(WorkMaterialDraft(kind: .note, textContent: "Original"))
        let text = String(repeating: "x", count: WorkItemContentLimits.maximumFieldCharacters + 1)
        do {
            _ = try await edit(original, in: store, body: "New body", notes: text)
            XCTFail("Overlong input must not partially save")
        } catch WorkboardStoreError.contentTooLong { }
        let latest = try await store.fetchWorkMaterial(id: original.id)
        XCTAssertEqual(latest?.textContent, original.textContent)
        XCTAssertNil(latest?.annotation)
    }

    func testReplayRepairAndReplacementPreserveUserNotes() async throws {
        let store = isolated.make()
        let bytes = Data("first source".utf8)
        let draft = WorkMaterialDraft(kind: .file, title: "Source", filename: "source.txt", mimeType: "text/plain", payload: bytes)
        let original = try await store.upsertDeskMaterial(draft)
        _ = try await edit(original, in: store, notes: "Keep my notes")
        let replay = try await store.upsertDeskMaterial(draft)
        XCTAssertEqual(replay.annotation, "Keep my notes")
        _ = await store._deleteWorkMaterialBlobRowsForTesting(materialID: original.id)
        let repaired = try await store.upsertDeskMaterial(draft)
        XCTAssertEqual(repaired.annotation, "Keep my notes")
        let repairedBytes = try await store.loadWorkMaterialPayload(id: original.id)
        XCTAssertEqual(repairedBytes, bytes)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("notes-replacement-\(UUID()).txt")
        let replacement = Data("replacement source".utf8)
        try replacement.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let deskValue = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        let desk = try XCTUnwrap(deskValue)
        let replaced = try await store.replaceWorkMaterialPayloadFile(id: original.id, from: url,
            byteSize: Int64(replacement.count), filename: "replacement.txt", mimeType: "text/plain", sourceDevice: "test",
            expectedOwnerRevision: WorkboardRevision.value(for: desk.updatedAt))
        XCTAssertEqual(replaced?.annotation, "Keep my notes")
        let final = try XCTUnwrap(replaced)
        let beforeIdentity = await WorkboardLiveRepository.presentationSnapshotForTesting(original).sourceByteIdentity
        let afterIdentity = await WorkboardLiveRepository.presentationSnapshotForTesting(final).sourceByteIdentity
        XCTAssertNotEqual(afterIdentity, beforeIdentity)
        let replacedBytes = try await store.loadWorkMaterialPayload(id: original.id)
        XCTAssertEqual(replacedBytes, replacement)
    }

    func testGeneratedTitleFollowsBodyWhileDeliberateTitleSurvives() async throws {
        let store = isolated.make()
        let generated = try await store.upsertDeskMaterial(WorkMaterialDraft(kind: .note, title: "Old first line", textContent: "Old first line\nDetails"))
        let custom = try await store.upsertDeskMaterial(WorkMaterialDraft(kind: .note, title: "My deliberate title", textContent: "Old first line\nDetails"))
        let edited = try await edit(generated, in: store, body: "New first line\nDetails")
        let preserved = try await edit(custom, in: store, body: "New first line\nDetails")
        XCTAssertEqual(edited.title, "New first line")
        XCTAssertEqual(preserved.title, "My deliberate title")
    }

    func testConcurrentEditsFromSameRevisionHaveOneWinner() async throws {
        let store = isolated.make()
        let original = try await store.upsertDeskMaterial(WorkMaterialDraft(kind: .note, textContent: "Original"))
        let revision = WorkboardRevision.value(for: original.updatedAt)
        let outcomes = await withTaskGroup(of: String.self) { group in
            for text in ["First editor", "Second editor"] {
                group.addTask {
                    do {
                        _ = try await store.updateWorkMaterialText(id: original.id, textContent: text, annotation: nil, expectedRevision: revision)
                        return "saved"
                    } catch WorkboardStoreError.staleRevision { return "stale" }
                    catch { return "unexpected error" }
                }
            }
            var values: [String] = []
            for await value in group { values.append(value) }
            return values
        }
        XCTAssertEqual(outcomes.sorted(), ["saved", "stale"])
    }

    func testTextAndAnnotationSurviveSQLiteReopen() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("notes-reopen-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("store.sqlite")
        let store = isolated.make(storeURL: url)
        let original = try await store.upsertDeskMaterial(WorkMaterialDraft(kind: .note, textContent: "Original"))
        _ = try await edit(original, in: store, body: "Edited", notes: "Persistent notes")
        try await store._unloadForTesting()
        let reopened = isolated.make(storeURL: url)
        let restored = try await reopened.fetchWorkMaterial(id: original.id)
        XCTAssertEqual(restored?.textContent, "Edited")
        XCTAssertEqual(restored?.annotation, "Persistent notes")
        try await reopened._unloadForTesting()
    }
}
