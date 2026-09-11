// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import Conduck

@MainActor
final class WorkMaterialTextEditingTests: XCTestCase {
    func testAnnotationSaveDoesNotEditOriginalFileAndUsesMaterialRevision() async {
        let id = UUID()
        let material = WorkboardMaterialSnapshot(id: id, kind: .file, name: "Report.pdf", revision: 17)
        var captured: (UUID, String?, String?, Int64)?
        let dependencies = WorkMaterialTextEditingDependencies(
            load: { _ in .init(revision: 17, textContent: nil, annotation: nil) },
            save: { id, source, annotation, revision in
                captured = (id, source, annotation, revision)
                return .init(revision: 18, textContent: nil, annotation: annotation)
            })
        let session = WorkMaterialTextEditorSession(material: material, field: .annotation, dependencies: dependencies)
        session.text = "Focus on page three"
        let saved = await session.save()
        XCTAssertTrue(saved)
        XCTAssertEqual(captured?.0, id)
        XCTAssertNil(captured?.1)
        XCTAssertEqual(captured?.2, "Focus on page three")
        XCTAssertEqual(captured?.3, 17)
        XCTAssertEqual(session.saved.revision, 18)
        XCTAssertFalse(session.isDirty)
    }

    func testEditingTranscriptPreservesExistingAnnotation() async {
        var material = WorkboardMaterialSnapshot(kind: .transcript, name: "Spoken note", textContent: "Old words", revision: 4)
        material.annotation = "Ask about the deadline"
        var capturedAnnotation: String?
        var capturedSource: String?
        let dependencies = WorkMaterialTextEditingDependencies(
            load: { _ in .init(material: material) },
            save: { _, source, annotation, _ in
                capturedSource = source
                capturedAnnotation = annotation
                return .init(revision: 5, textContent: source, annotation: annotation)
            })
        let session = WorkMaterialTextEditorSession(material: material, field: .source, dependencies: dependencies)
        session.text = "Corrected words"
        let saved = await session.save()
        XCTAssertTrue(saved)
        XCTAssertEqual(capturedSource, "Corrected words")
        XCTAssertEqual(capturedAnnotation, "Ask about the deadline")
    }

    func testConflictKeepsDraftAndOriginalRevisionUntilExplicitReload() async {
        let material = WorkboardMaterialSnapshot(kind: .image, name: "Screenshot", revision: 3)
        let latest = WorkMaterialTextState(revision: 9, textContent: nil, annotation: "Changed on another device")
        var attemptedRevisions: [Int64] = []
        let dependencies = WorkMaterialTextEditingDependencies(
            load: { _ in latest },
            save: { _, _, _, revision in
                attemptedRevisions.append(revision)
                throw WorkboardStoreError.staleRevision
            })
        let session = WorkMaterialTextEditorSession(material: material, field: .annotation, dependencies: dependencies)
        session.text = "My unsaved comment"
        let saved = await session.save()
        XCTAssertFalse(saved)
        XCTAssertNotNil(session.errorMessage)
        XCTAssertEqual(session.text, "My unsaved comment")
        XCTAssertEqual(session.saved.revision, 3)
        await session.loadLatest()
        XCTAssertEqual(session.text, "My unsaved comment", "Opening a retained editor must not discard its draft")
        XCTAssertEqual(session.saved.revision, 3)
        XCTAssertEqual(attemptedRevisions, [3])
        await session.loadLatest(discardDraft: true)
        XCTAssertEqual(session.text, "Changed on another device")
        XCTAssertEqual(session.saved.revision, 9)
        XCTAssertFalse(session.isDirty)
    }

    func testDeletingMaterialWhileEditingRetainsTheDraft() async {
        let material = WorkboardMaterialSnapshot(kind: .note, name: "Idea", textContent: "Original", revision: 2)
        let dependencies = WorkMaterialTextEditingDependencies(
            load: { _ in throw WorkboardStoreError.materialNotFound },
            save: { _, _, _, _ in throw WorkboardStoreError.materialNotFound })
        let session = WorkMaterialTextEditorSession(material: material, field: .source, dependencies: dependencies)
        session.text = "Keep these words"
        let saved = await session.save()
        XCTAssertFalse(saved)
        XCTAssertEqual(session.text, "Keep these words")
        XCTAssertTrue(session.isDirty)
        await session.loadLatest(discardDraft: true)
        XCTAssertEqual(session.text, "Keep these words", "A failed reload must not discard the only surviving text")
    }

    func testRemoteReferenceCannotBeRewrittenAsSourceText() async {
        let material = WorkboardMaterialSnapshot(kind: .note, name: "Remote file", textContent: "Reference",
                                                 projectResultKind: .reference)
        var saves = 0
        let dependencies = WorkMaterialTextEditingDependencies(
            load: { _ in .init(material: material) },
            save: { _, _, _, _ in saves += 1; return .init(material: material) })
        let session = WorkMaterialTextEditorSession(material: material, field: .source, dependencies: dependencies)
        session.text = "Overwrite source"
        let saved = await session.save()
        XCTAssertFalse(saved)
        XCTAssertEqual(saves, 0)
        XCTAssertEqual(session.text, "Overwrite source")
    }

    func testSuccessDoesNotOverwriteTypingThatContinuedDuringSave() async {
        let material = WorkboardMaterialSnapshot(kind: .note, name: "Idea", revision: 10)
        var continuation: CheckedContinuation<WorkMaterialTextState, Never>?
        let dependencies = WorkMaterialTextEditingDependencies(
            load: { _ in .init(material: material) },
            save: { _, _, _, _ in await withCheckedContinuation { continuation = $0 } })
        let session = WorkMaterialTextEditorSession(material: material, field: .annotation, dependencies: dependencies)
        session.text = "Submitted"
        let saving = Task { await session.save() }
        while continuation == nil { await Task.yield() }
        session.text = "More recent typing"
        continuation?.resume(returning: .init(revision: 11, textContent: nil, annotation: "Submitted"))
        let succeeded = await saving.value
        XCTAssertTrue(succeeded)
        XCTAssertEqual(session.text, "More recent typing")
        XCTAssertEqual(session.saved.annotation, "Submitted")
        XCTAssertTrue(session.isDirty)
        session.cancel()
        XCTAssertEqual(session.text, "Submitted")
    }

    func testMetadataPreviewExistsForEveryUnavailableMaterialWithoutOpeningItsSource() async {
        let router = PersonalWorkbenchRouter()
        router.destination = .work
        var openedURLs: [URL] = []
        router.openExternalURL = { openedURLs.append($0) }
        for kind in [WorkboardMaterialKind.note, .transcript, .image, .file, .audio, .link] {
            let material = WorkboardMaterialSnapshot(kind: kind, name: "Material", urlString: "https://example.com/source",
                                                     availability: .unavailableOnThisDevice)
            router.deskMaterials = { [material] }
            await router.present(material)
            guard case .details(let shown) = router.materialPresentation?.content else {
                XCTFail("Missing metadata preview for \(kind)")
                continue
            }
            XCTAssertEqual(shown.id, material.id)
            XCTAssertNil(router.filePreview.previewURL)
        }
        XCTAssertTrue(openedURLs.isEmpty)
    }

    func testGalleryPageChangesAndDismissalKeepDraftBoundToOriginalMaterial() async {
        let first = WorkboardMaterialSnapshot(kind: .image, name: "First image")
        let second = WorkboardMaterialSnapshot(kind: .image, name: "Second image")
        let router = PersonalWorkbenchRouter()
        router.destination = .work
        router.deskMaterials = { [first, second] }
        let firstEditor = router.textEditor(for: first, field: .annotation)
        firstEditor.text = "Only for the first image"
        await router.present(second)
        let secondEditor = router.textEditor(for: second, field: .annotation)
        XCTAssertTrue(secondEditor.text.isEmpty)
        router.closeMaterial()
        await router.present(first)
        let reopened = router.textEditor(for: first, field: .annotation)
        XCTAssertTrue(reopened === firstEditor)
        XCTAssertEqual(reopened.id.materialID, first.id)
        XCTAssertEqual(reopened.text, "Only for the first image")
    }
}
