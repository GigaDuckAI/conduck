// SPDX-License-Identifier: Apache-2.0

// Exercise project filtering and selection with delayed/synced membership
// snapshots. Hidden or deleted cards must never enter a bulk organization
// action, and a missing project must not make its materials disappear.

import XCTest
@testable import Conduck

@MainActor
final class WorkDeskWorkspaceTests: XCTestCase {
    func testWideSidebarButtonCollapsesAndExpandsTheProjectRail() async {
        let workspace = await makeWorkspace(.init())
        workspace.updateSidebarLayout(isInline: true)
        workspace.toggleProjectNavigation()
        XCTAssertFalse(workspace.showsSidebar)
        XCTAssertFalse(workspace.showsProjectPicker)
        workspace.toggleProjectNavigation()
        XCTAssertTrue(workspace.showsSidebar)
    }

    func testCompactSidebarButtonOpensPickerWithoutChangingTheWidePreference() async {
        let workspace = await makeWorkspace(.init())
        workspace.showsSidebar = false
        workspace.updateSidebarLayout(isInline: false)
        workspace.toggleProjectNavigation()
        XCTAssertTrue(workspace.showsProjectPicker)
        XCTAssertFalse(workspace.showsSidebar)
        workspace.toggleProjectNavigation()
        XCTAssertFalse(workspace.showsProjectPicker)
        workspace.updateSidebarLayout(isInline: true)
        workspace.toggleProjectNavigation()
        XCTAssertTrue(workspace.showsSidebar)
    }

    func testWideningAWindowClosesTheCompactPicker() async {
        let workspace = await makeWorkspace(.init())
        workspace.updateSidebarLayout(isInline: false)
        workspace.toggleProjectNavigation()
        workspace.updateSidebarLayout(isInline: true)
        XCTAssertFalse(workspace.showsProjectPicker)
        XCTAssertTrue(workspace.presentsSidebarInline)
    }

    func testClosingAndReopeningRetainsTaskWhileRefreshingProjectContext() async {
        let workspace = await makeWorkspace(.init())
        let project = WorkDeskProjectRecord(title: "A project", brief: "Saved")
        let draft = workspace.briefDraft(for: project, resolver: .init())
        draft.brief = "Still thinking"
        workspace.isActive = true
        workspace.suspend()
        XCTAssertFalse(workspace.isActive)
        XCTAssertTrue(workspace.briefDraft(for: project, resolver: .init()) === draft)
        XCTAssertEqual(draft.brief, "Still thinking")

        workspace.endBriefEditing(projectID: project.id)
        var updated = project
        updated.brief = "Edited on another device"
        updated.updatedAt = project.updatedAt.addingTimeInterval(10)
        let reopened = workspace.briefDraft(for: updated, resolver: .init())
        XCTAssertTrue(reopened === draft)
        XCTAssertEqual(reopened.brief, "Still thinking")
        XCTAssertEqual(reopened.projectContext, updated.brief)
        XCTAssertEqual(workspace.briefRevisions[project.id], updated.updatedAt)
    }

    func testResultMaterialArrivingBeforeReceiptRemainsExcludedAcrossDraftResets() async {
        let project = WorkDeskProjectRecord(title: "A project")
        let workspace = await makeWorkspace(.init(projects: [project]))
        let result = WorkboardMaterialSnapshot(kind: .file, name: "Result.txt", projectResultKind: .file)
        workspace.reconcile(materials: [result])
        let draft = workspace.briefDraft(for: project, resolver: .init())
        XCTAssertTrue(draft.excludedIDs.contains(result.id))
        draft.excludedIDs.remove(result.id)
        draft.startAnotherConversation()
        XCTAssertTrue(draft.excludedIDs.contains(result.id))
        let arriving = WorkboardMaterialSnapshot(kind: .note, name: "Remote.pdf", projectResultKind: .reference)
        workspace.reconcile(materials: [result, arriving])
        XCTAssertTrue(draft.excludedIDs.contains(arriving.id))
        XCTAssertTrue(draft.remoteResultIDs.contains(arriving.id))
    }

    func testDifferentProjectsNeverShareDraftExclusionsOrHandoffOwner() async {
        let workspace = await makeWorkspace(.init())
        let a = workspace.briefDraft(for: .init(title: "A"), resolver: .init())
        let b = workspace.briefDraft(for: .init(title: "B"), resolver: .init())
        a.excludedIDs = [UUID()]
        a.brief = "Only A"
        XCTAssertTrue(b.excludedIDs.isEmpty)
        XCTAssertEqual(b.brief, "")
        XCTAssertFalse(a.handoff === b.handoff)
    }

    func testAllAndProjectScopesSupportCanvasWhileSearchUsesReadableResults() async {
        let workspace = await makeWorkspace(.init())
        XCTAssertTrue(workspace.supportsSpatialLayout)
        workspace.search = "offscreen material"
        XCTAssertFalse(workspace.supportsSpatialLayout)
        workspace.search = "  "
        XCTAssertTrue(workspace.supportsSpatialLayout)
        workspace.selectScope(.all)
        XCTAssertTrue(workspace.supportsSpatialLayout)
        workspace.selectScope(.project(UUID()))
        XCTAssertTrue(workspace.supportsSpatialLayout)
    }

    func testReadableMoveTargetsVisibleNeighborNotHiddenGlobalNeighbor() {
        let a = UUID(), b = UUID(), c = UUID()
        XCTAssertEqual(WorkDeskWorkspaceState.moveTarget(c, direction: .earlier, visibleIDs: [a, c]), a)
        XCTAssertEqual(WorkDeskWorkspaceState.moveTarget(a, direction: .later, visibleIDs: [a, c]), c)
        XCTAssertNil(WorkDeskWorkspaceState.moveTarget(b, direction: .later, visibleIDs: [a, c]))
        XCTAssertNil(WorkDeskWorkspaceState.moveTarget(a, direction: .earlier, visibleIDs: [a, c]))
        XCTAssertNil(WorkDeskWorkspaceState.moveTarget(c, direction: .later, visibleIDs: [a, c]))
    }

    func testNewProjectWaitsForPickerToDismiss() async {
        let workspace = await makeWorkspace(.init())
        workspace.showsProjectPicker = true
        workspace.beginProject(materialIDs: [UUID()])
        XCTAssertFalse(workspace.showsProjectPicker)
        XCTAssertNil(workspace.projectEditor)
        XCTAssertNotNil(workspace.pendingProjectEditor)
        workspace.projectPickerDidDismiss()
        XCTAssertNotNil(workspace.projectEditor)
        XCTAssertNil(workspace.pendingProjectEditor)
    }

    func testAllMaterialsKeepsFiledUnfiledAndDanglingMembersVisible() async {
        let a = material("A"), b = material("B"), c = material("C")
        let project = WorkDeskProjectRecord(title: "Project")
        let workspace = await makeWorkspace(.init(projects: [project], placements: [
            b.id: .init(materialID: b.id, projectID: project.id),
            c.id: .init(materialID: c.id, projectID: UUID())
        ]))
        XCTAssertEqual(workspace.visibleMaterials(in: [a, b, c]).map(\.id), [a.id, b.id, c.id])
        workspace.selectScope(.project(project.id))
        XCTAssertEqual(workspace.visibleMaterials(in: [a, b, c]).map(\.id), [b.id])
        workspace.selectScope(.all)
        XCTAssertEqual(workspace.visibleMaterials(in: [a, b, c]).map(\.id), [a.id, b.id, c.id])
    }

    func testHomeSearchIncludesVoiceWordsWithoutChangingMembership() async {
        let voice = material("Voice", text: "Remember the blue packaging")
        var photo = material("Image")
        photo.companion = WorkboardCompanionSnapshot(voice)
        let project = WorkDeskProjectRecord(title: "Packaging")
        let workspace = await makeWorkspace(.init(projects: [project], placements: [
            photo.id: .init(materialID: photo.id, projectID: project.id, isPinned: true)
        ]))
        workspace.selectScope(.all)
        workspace.search = "BLUE"
        XCTAssertEqual(workspace.visibleMaterials(in: [photo]).map(\.id), [photo.id])
        XCTAssertEqual(workspace.organization.projectID(for: photo.id), project.id)
        workspace.search = "absent"
        XCTAssertTrue(workspace.visibleMaterials(in: [photo]).isEmpty)
    }

    func testScopeChangesClearSelectionAndSearch() async {
        let workspace = await makeWorkspace(.init())
        workspace.toggleSelection(UUID())
        workspace.search = "old query"
        workspace.showsProjectPicker = true
        workspace.selectScope(.all)
        XCTAssertTrue(workspace.selectedIDs.isEmpty)
        XCTAssertFalse(workspace.isSelecting)
        XCTAssertFalse(workspace.showsProjectPicker)
        XCTAssertEqual(workspace.search, "")
    }

    func testReconciliationParksHiddenSelectionAndDropsDeletedSelection() async {
        let a = material("Needle"), b = material("Other")
        let workspace = await makeWorkspace(.init())
        workspace.isSelecting = true
        workspace.selectedIDs = [a.id, b.id, UUID()]
        workspace.search = "Needle"
        workspace.reconcile(materials: [a, b])
        XCTAssertEqual(workspace.selectedIDs, [a.id])
        workspace.reconcile(materials: [b])
        XCTAssertTrue(workspace.selectedIDs.isEmpty)
        XCTAssertTrue(workspace.isSelecting, "empty search results preserve Select mode")
        workspace.search = ""
        workspace.reconcile(materials: [b])
        XCTAssertEqual(workspace.selectedIDs, [b.id], "the hidden surviving selection returns")
    }

    func testEmptySearchPreservesSelectModeAndRestoresSelectionWhenCleared() async {
        let a = material("Thought"), b = material("Another thought")
        let workspace = await makeWorkspace(.init())
        workspace.toggleSelection(a.id)
        workspace.search = "no matching card"
        workspace.reconcile(materials: [a, b])
        XCTAssertTrue(workspace.isSelecting)
        XCTAssertTrue(workspace.selectedIDs.isEmpty, "hidden cards are excluded from bulk actions")

        workspace.search = ""
        workspace.reconcile(materials: [a, b])
        XCTAssertTrue(workspace.isSelecting)
        XCTAssertEqual(workspace.selectedIDs, [a.id])
    }

    func testLeavingSelectModeWhileSearchIsEmptyDiscardsParkedSelection() async {
        let a = material("Thought")
        let workspace = await makeWorkspace(.init())
        workspace.toggleSelection(a.id)
        workspace.search = "no match"
        workspace.reconcile(materials: [a])
        workspace.isSelecting = false
        workspace.search = ""
        workspace.reconcile(materials: [a])
        XCTAssertFalse(workspace.isSelecting)
        XCTAssertTrue(workspace.selectedIDs.isEmpty)
    }

    func testGenuinelyEmptyDeskResetsSelectModeAndSelection() async {
        let a = material("Thought")
        let workspace = await makeWorkspace(.init())
        workspace.toggleSelection(a.id)
        workspace.search = "no match"
        workspace.reconcile(materials: [a])
        workspace.reconcile(materials: [])
        XCTAssertFalse(workspace.isSelecting)
        workspace.search = ""
        workspace.reconcile(materials: [a])
        XCTAssertTrue(workspace.selectedIDs.isEmpty, "deleted selections cannot return with later content")
    }

    func testMissingProjectReturnsToAllMaterialsAndClearsSelection() async {
        let a = material("Thought")
        let workspace = await makeWorkspace(.init())
        workspace.scope = .project(UUID())
        workspace.selectedIDs = [a.id]
        workspace.reconcile(materials: [a])
        XCTAssertEqual(workspace.scope, .all)
        XCTAssertEqual(workspace.visibleMaterials(in: [a]).map(\.id), [a.id])
        XCTAssertTrue(workspace.selectedIDs.isEmpty)
    }

    func testBulkMoveCannotIncludeSelectedSourcesHiddenBySearch() async {
        let a = material("Keep"), b = material("Hidden")
        let recorder = MutationRecorder()
        let organization = WorkDeskOrganization(fetch: { .init() }, apply: { mutation in
            await recorder.record(mutation)
            return .init()
        })
        let workspace = WorkDeskWorkspaceState(organization: organization)
        workspace.selectedIDs = [a.id, b.id, UUID()]
        workspace.search = "Keep"
        await workspace.assignSelection(to: nil, materials: [a, b])
        let ids = await recorder.assignedIDs
        XCTAssertEqual(ids, [a.id])
        XCTAssertTrue(workspace.selectedIDs.isEmpty)
    }

    private func makeWorkspace(_ snapshot: WorkDeskOrganizationSnapshot) async -> WorkDeskWorkspaceState {
        let organization = WorkDeskOrganization(fetch: { snapshot }, apply: { _ in snapshot })
        await organization.reload()
        return WorkDeskWorkspaceState(organization: organization)
    }

    private func material(_ name: String, text: String? = nil) -> WorkboardMaterialSnapshot {
        .init(kind: .note, name: name, textContent: text)
    }

    private actor MutationRecorder {
        var assignedIDs: [UUID] = []
        func record(_ mutation: WorkDeskMutation) {
            if case .assign(let ids, _) = mutation { assignedIDs = ids }
        }
    }
}
