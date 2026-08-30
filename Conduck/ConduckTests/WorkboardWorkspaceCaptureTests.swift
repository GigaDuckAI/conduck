// SPDX-License-Identifier: Apache-2.0

// ConduckTests
// WorkboardWorkspaceCaptureTests.swift
//
// The Work canvas is deliberately a capture surface, not an execution surface.
// These tests hold that boundary while also covering ordered partial-success
// imports: a thought or drop can mutate only the selected private draft, and it
// must never invoke the gateway dispatch dependency.

import XCTest
@testable import Conduck

@MainActor
final class WorkboardWorkspaceCaptureTests: XCTestCase {
    private enum TestError: Error { case expectedFailure, unexpectedCall }

    private final class Harness {
        var item: WorkboardItemSnapshot
        var savedDrafts: [WorkboardEditDraft] = []
        var importedNames: [String] = []
        var importExpectedRevisions: [Int64] = []
        var failingImportNames: Set<String> = []
        var dispatchCount = 0

        init(item: WorkboardItemSnapshot) {
            self.item = item
        }
    }

    private final class SaveGate {
        struct PendingSave {
            let draft: WorkboardEditDraft
            let continuation: CheckedContinuation<WorkboardItemSnapshot, any Error>
        }

        var pending: [PendingSave] = []
        var submittedDrafts: [WorkboardEditDraft] = []
        private var revision: Int64 = 20

        func save(_ draft: WorkboardEditDraft) async throws -> WorkboardItemSnapshot {
            submittedDrafts.append(draft)
            return try await withCheckedThrowingContinuation { continuation in
                pending.append(PendingSave(draft: draft, continuation: continuation))
            }
        }

        func resolveNext() {
            let save = pending.removeFirst()
            revision += 1
            save.continuation.resume(returning: WorkboardItemSnapshot(
                id: save.draft.id,
                title: save.draft.title,
                objective: save.draft.objective,
                context: save.draft.context,
                desiredResult: save.draft.desiredResult,
                constraints: save.draft.constraints,
                reviewBy: save.draft.reviewBy,
                materials: save.draft.materials,
                isPinned: save.draft.isPinned,
                revision: revision
            ))
        }
    }

    func testCaptureLogicNormalizesAndInfersACompactFirstLineTitle() {
        let longFirstLine = String(repeating: "a", count: 90)
        let normalized = WorkboardWorkspaceCaptureLogic.normalizedThought(
            "  \r\n\(longFirstLine)\rsecond line  \n"
        )

        XCTAssertEqual(normalized, "\(longFirstLine)\nsecond line")
        XCTAssertEqual(WorkboardWorkspaceCaptureLogic.title(for: normalized).count, 72)
        XCTAssertEqual(
            WorkboardWorkspaceCaptureLogic.title(for: "\n  Useful idea\nMore"),
            "Useful idea"
        )
    }

    func testFirstThoughtBecomesObjectiveWithoutDispatching() async {
        let item = WorkboardItemSnapshot(title: "", objective: "", revision: 4)
        let harness = Harness(item: item)
        let viewModel = makeViewModel(harness: harness)
        viewModel.items = [item]

        let added = await viewModel.addWorkspaceThought(
            "  Compare the launch plans\nwith the latest notes.  ",
            to: item.id
        )

        XCTAssertTrue(added)
        XCTAssertEqual(harness.savedDrafts.count, 1)
        XCTAssertEqual(harness.savedDrafts[0].title, "Compare the launch plans")
        XCTAssertEqual(
            harness.savedDrafts[0].objective,
            "Compare the launch plans\nwith the latest notes."
        )
        XCTAssertTrue(harness.importedNames.isEmpty)
        XCTAssertEqual(harness.dispatchCount, 0)
    }

    func testNewWorkDoesNotPersistUntilFirstCapture() async {
        let harness = Harness(item: WorkboardItemSnapshot())
        let viewModel = makeViewModel(harness: harness)

        let provisionalID = viewModel.beginWorkspace()

        XCTAssertTrue(harness.savedDrafts.isEmpty)
        XCTAssertEqual(viewModel.provisionalWorkspaceID, provisionalID)
        XCTAssertNil(viewModel.selectedItemID)

        let added = await viewModel.addWorkspaceThought("A real first thought", to: provisionalID)

        XCTAssertTrue(added)
        XCTAssertEqual(harness.savedDrafts.map(\.id), [provisionalID])
        XCTAssertNil(viewModel.provisionalWorkspaceID)
        XCTAssertEqual(viewModel.selectedItemID, provisionalID)
        XCTAssertEqual(harness.dispatchCount, 0)
    }

    func testSmallTextFileCanUseTextOnlyGatewayWithoutSyncedExtract() {
        let gateway = WorkboardGatewayChoice(
            ref: .builtin(.openclaw),
            name: "Text only",
            detail: "",
            capabilities: [.text]
        )

        XCTAssertTrue(gateway.supports(WorkboardMaterialSnapshot(
            kind: .file,
            name: "brief.md",
            textContent: nil,
            mimeType: "text/markdown",
            byteCount: 1_024
        )))
        XCTAssertFalse(gateway.supports(WorkboardMaterialSnapshot(
            kind: .file,
            name: "brief.pdf",
            textContent: nil,
            mimeType: "application/pdf",
            byteCount: 1_024
        )))
        XCTAssertFalse(gateway.supports(WorkboardMaterialSnapshot(
            kind: .file,
            name: "huge.txt",
            textContent: nil,
            mimeType: "text/plain",
            byteCount: Int64(Constants.textProbeMaxBytes) + 1
        )))
    }

    func testLaterThoughtBecomesAChronologicalNoteWithoutDispatching() async {
        let item = WorkboardItemSnapshot(
            title: "Launch plan",
            objective: "Compare the plans",
            revision: 7
        )
        let harness = Harness(item: item)
        let viewModel = makeViewModel(harness: harness)
        viewModel.items = [item]

        let added = await viewModel.addWorkspaceThought(
            "Customer interviews favor the smaller launch.",
            to: item.id
        )

        XCTAssertTrue(added)
        XCTAssertEqual(harness.importedNames, ["Customer interviews favor the smaller launch."])
        XCTAssertEqual(harness.importExpectedRevisions, [7])
        XCTAssertEqual(viewModel.item(withID: item.id)?.materials.count, 1)
        XCTAssertEqual(harness.dispatchCount, 0)
    }

    func testBatchImportPreservesSuccessesAndAdvancesOnlySuccessfulRevisions() async {
        let item = WorkboardItemSnapshot(
            title: "Launch plan",
            objective: "Compare the plans",
            revision: 3
        )
        let harness = Harness(item: item)
        harness.failingImportNames = ["Unreadable"]
        let viewModel = makeViewModel(harness: harness)
        viewModel.items = [item]

        let report = await viewModel.importWorkspaceMaterials(
            [
                WorkboardMaterialImport(kind: .note, name: "First", textContent: "One"),
                WorkboardMaterialImport(kind: .file, name: "Unreadable"),
                WorkboardMaterialImport(kind: .link, name: "Third", urlString: "https://example.com")
            ],
            to: item.id
        )

        XCTAssertEqual(report, WorkboardWorkspaceImportReport(addedCount: 2, failedCount: 1))
        XCTAssertEqual(harness.importExpectedRevisions, [3, 4, 4])
        XCTAssertEqual(harness.importedNames, ["First", "Third"])
        XCTAssertEqual(viewModel.item(withID: item.id)?.materials.map(\.name), ["First", "Third"])
        XCTAssertNil(viewModel.workspaceImportState)
        XCTAssertEqual(harness.dispatchCount, 0)
    }

    func testFailedFirstMaterialKeepsNewWorkProvisionalAndLeavesNoDraft() async {
        let provisionalID = UUID()
        let harness = Harness(item: WorkboardItemSnapshot(id: provisionalID, revision: 0))
        harness.failingImportNames = ["Unreadable"]
        let viewModel = makeViewModel(harness: harness)
        viewModel.beginWorkspace(id: provisionalID)

        let report = await viewModel.importWorkspaceMaterials(
            [WorkboardMaterialImport(kind: .file, name: "Unreadable")],
            to: provisionalID
        )

        XCTAssertEqual(report, WorkboardWorkspaceImportReport(addedCount: 0, failedCount: 1))
        XCTAssertTrue(harness.savedDrafts.isEmpty)
        XCTAssertTrue(viewModel.items.isEmpty)
        XCTAssertEqual(viewModel.provisionalWorkspaceID, provisionalID)
        XCTAssertNil(viewModel.selectedItemID)
        XCTAssertEqual(harness.dispatchCount, 0)
    }

    func testLiveInvalidFirstMaterialDoesNotCreateAStoredOwner() async throws {
        let store = ConversationStore(inMemory: true)
        let repository = WorkboardLiveRepository(
            store: store,
            dispatch: { _, _ in throw TestError.unexpectedCall },
            openConversation: { _ in },
            openMaterial: { _ in },
            openGatewaySettings: {}
        )
        let viewModel = WorkboardViewModel(dependencies: repository.makeDependencies())
        let provisionalID = viewModel.beginWorkspace()

        let report = await viewModel.importWorkspaceMaterials(
            [WorkboardMaterialImport(kind: .file, name: "Missing payload")],
            to: provisionalID
        )

        XCTAssertEqual(report, WorkboardWorkspaceImportReport(addedCount: 0, failedCount: 1))
        let storedItem = try await store.fetchWorkItem(id: provisionalID)
        XCTAssertNil(storedItem)
        XCTAssertEqual(viewModel.provisionalWorkspaceID, provisionalID)
        XCTAssertNil(viewModel.selectedItemID)
    }

    func testFirstThoughtAndDropShareOneSerializedMutationLane() async {
        let itemID = UUID()
        let saveGate = SaveGate()
        var importCalled = false
        let viewModel = WorkboardViewModel(dependencies: WorkboardViewModel.Dependencies(
            loadItems: { [] },
            loadGateways: { ([], []) },
            saveDraft: { [saveGate] draft in try await saveGate.save(draft) },
            saveDraftAsCopy: { _ in throw TestError.unexpectedCall },
            importMaterial: { id, expectedRevision, materialImport, onProgress in
                importCalled = true
                XCTAssertEqual(id, itemID)
                XCTAssertEqual(expectedRevision, 21)
                onProgress(1)
                return WorkboardItemSnapshot(
                    id: itemID,
                    title: "First thought",
                    objective: "First thought",
                    materials: [WorkboardMaterialSnapshot(
                        id: materialImport.id,
                        kind: materialImport.kind,
                        name: materialImport.name,
                        textContent: materialImport.textContent,
                        sequence: 0,
                        revision: 1
                    )],
                    revision: 22
                )
            },
            removeMaterial: { _, _, _ in throw TestError.unexpectedCall },
            replaceMaterial: { _, _, _, _, _ in throw TestError.unexpectedCall },
            deleteItem: { _ in throw TestError.unexpectedCall },
            duplicateItem: { _ in throw TestError.unexpectedCall },
            setState: { _, _ in throw TestError.unexpectedCall },
            acknowledgeRun: { _, _, _ in throw TestError.unexpectedCall },
            dispatch: { _ in throw TestError.unexpectedCall },
            openConversation: { _ in },
            openMaterial: { _ in },
            openGatewaySettings: {}
        ))
        viewModel.beginWorkspace(id: itemID)

        let thoughtTask = Task { @MainActor in
            await viewModel.addWorkspaceThought("First thought", to: itemID)
        }
        await waitUntil { saveGate.pending.count == 1 }
        let dropTask = Task { @MainActor in
            await viewModel.importWorkspaceMaterials(
                [WorkboardMaterialImport(kind: .note, name: "Second", textContent: "Second")],
                to: itemID
            )
        }
        for _ in 0..<10 { await Task.yield() }

        XCTAssertFalse(importCalled, "the drop must wait for the first thought revision")
        saveGate.resolveNext()

        let thoughtAdded = await thoughtTask.value
        let dropReport = await dropTask.value
        XCTAssertTrue(thoughtAdded)
        XCTAssertEqual(dropReport, WorkboardWorkspaceImportReport(addedCount: 1, failedCount: 0))
        XCTAssertTrue(importCalled)
    }

    func testAutosavePersistsKeystrokesMadeWhilePreviousSaveIsSuspended() async {
        let item = WorkboardItemSnapshot(
            title: "Launch",
            objective: "Original",
            revision: 20
        )
        let gate = SaveGate()
        let viewModel = WorkboardViewModel(dependencies: WorkboardViewModel.Dependencies(
            loadItems: { [item] in [item] },
            loadGateways: { ([], []) },
            saveDraft: { [gate] draft in try await gate.save(draft) },
            saveDraftAsCopy: { _ in throw TestError.unexpectedCall },
            importMaterial: { _, _, _, _ in throw TestError.unexpectedCall },
            removeMaterial: { _, _, _ in throw TestError.unexpectedCall },
            replaceMaterial: { _, _, _, _, _ in throw TestError.unexpectedCall },
            deleteItem: { _ in throw TestError.unexpectedCall },
            duplicateItem: { _ in throw TestError.unexpectedCall },
            setState: { _, _ in throw TestError.unexpectedCall },
            acknowledgeRun: { _, _, _ in throw TestError.unexpectedCall },
            dispatch: { _ in throw TestError.unexpectedCall },
            openConversation: { _ in },
            openMaterial: { _ in },
            openGatewaySettings: {}
        ))
        viewModel.items = [item]
        viewModel.showEditor(for: item)
        viewModel.editingDraft.objective = "First edit"

        let saveTask = Task { @MainActor in
            await viewModel.saveEditorNow(showFailure: true)
        }
        await waitUntil { gate.pending.count == 1 }

        viewModel.editingDraft.objective = "Second edit while saving"
        gate.resolveNext()
        await waitUntil { gate.pending.count == 1 && gate.submittedDrafts.count == 2 }
        gate.resolveNext()

        let saveSucceeded = await saveTask.value
        XCTAssertTrue(saveSucceeded)
        XCTAssertEqual(gate.submittedDrafts.map(\.objective), [
            "First edit",
            "Second edit while saving"
        ])
        XCTAssertEqual(viewModel.editingDraft.objective, "Second edit while saving")
        XCTAssertFalse(viewModel.editorHasUnsavedChanges)
        XCTAssertEqual(viewModel.item(withID: item.id)?.objective, "Second edit while saving")
    }

    private func waitUntil(
        _ predicate: @escaping @MainActor () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<200 {
            if predicate() { return }
            await Task.yield()
        }
        XCTFail("Timed out waiting for asynchronous test state", file: file, line: line)
    }

    private func makeViewModel(harness: Harness) -> WorkboardViewModel {
        WorkboardViewModel(dependencies: WorkboardViewModel.Dependencies(
            loadItems: { [harness] in [harness.item] },
            loadGateways: { ([], []) },
            saveDraft: { [harness] draft in
                harness.savedDrafts.append(draft)
                harness.item = WorkboardItemSnapshot(
                    id: draft.id,
                    title: draft.title,
                    objective: draft.objective,
                    context: draft.context,
                    desiredResult: draft.desiredResult,
                    constraints: draft.constraints,
                    reviewBy: draft.reviewBy,
                    state: harness.item.state,
                    materials: draft.materials,
                    runs: harness.item.runs,
                    isPinned: draft.isPinned,
                    createdAt: harness.item.createdAt,
                    modifiedAt: Date(),
                    revision: harness.item.revision + 1,
                    lastSentRevision: harness.item.lastSentRevision
                )
                return harness.item
            },
            saveDraftAsCopy: { _ in throw TestError.unexpectedCall },
            importMaterial: { [harness] itemID, expectedRevision, materialImport, onProgress in
                XCTAssertEqual(itemID, harness.item.id)
                harness.importExpectedRevisions.append(expectedRevision)
                if harness.failingImportNames.contains(materialImport.name) {
                    throw TestError.expectedFailure
                }
                XCTAssertEqual(expectedRevision, harness.item.revision)
                let material = WorkboardMaterialSnapshot(
                    id: materialImport.id,
                    kind: materialImport.kind,
                    name: materialImport.name,
                    detail: materialImport.detail,
                    textContent: materialImport.textContent,
                    urlString: materialImport.urlString,
                    mimeType: materialImport.mimeType,
                    byteCount: materialImport.byteCount,
                    sequence: harness.item.materials.count,
                    revision: 1
                )
                harness.item.materials.append(material)
                harness.item.revision += 1
                harness.importedNames.append(materialImport.name)
                onProgress(1)
                return harness.item
            },
            removeMaterial: { _, _, _ in throw TestError.unexpectedCall },
            replaceMaterial: { _, _, _, _, _ in throw TestError.unexpectedCall },
            deleteItem: { _ in throw TestError.unexpectedCall },
            duplicateItem: { _ in throw TestError.unexpectedCall },
            setState: { _, _ in throw TestError.unexpectedCall },
            acknowledgeRun: { _, _, _ in throw TestError.unexpectedCall },
            dispatch: { [harness] _ in
                harness.dispatchCount += 1
                throw TestError.unexpectedCall
            },
            openConversation: { _ in },
            openMaterial: { _ in },
            openGatewaySettings: {}
        ))
    }
}
