// SPDX-License-Identifier: Apache-2.0

// Exercise project filtering and selection with delayed/synced membership
// snapshots. Hidden or deleted cards must never enter a bulk organization
// action, and a missing project must not make its materials disappear.

import XCTest
@testable import Conduck

@MainActor
final class WorkDeskWorkspaceTests: XCTestCase {
    func testModeSwitchRetainsTheSelectedConversationModelUntilActualNavigation() async throws {
        let workspace = await makeWorkspace(.init())
        let selected = UUID()
        let resolver = WorkDeskConversationResolver(resolve: { id in
            ConversationDetailViewModel(conversationID: id)
        })
        workspace.isActive = true
        workspace.selectConversation(selected, projectID: UUID())
        let model = try XCTUnwrap(workspace.conversationModel(for: selected, resolver: resolver))
        let session = workspace.conversationSession(for: selected)
        session.draft = "Keep these words"
        let presentation = session.resume()

        workspace.suspend()
        XCTAssertFalse(workspace.isActive)
        XCTAssertFalse(session.isCurrentPresentation(presentation))
        XCTAssertTrue(workspace.conversationModel(for: selected, resolver: resolver) === model)
        XCTAssertEqual(session.draft, "Keep these words")

        workspace.setRefreshActive(true)
        XCTAssertTrue(workspace.conversationModel(for: selected, resolver: resolver) === model)
        workspace.selectScope(.all)
        XCTAssertFalse(workspace.conversationModel(for: selected, resolver: resolver) === model,
                       "An idle model is released when its conversation is actually left")
    }

    func testSearchFindsNotesOnMaterialsAndTheirCompanions() async {
        let workspace = await makeWorkspace(.init())
        let words = WorkboardMaterialSnapshot(kind: .transcript, name: "Words", annotation: "remember the deadline")
        let image = WorkboardMaterialSnapshot(kind: .image, name: "Photo", companion: WorkboardCompanionSnapshot(words))
        let file = WorkboardMaterialSnapshot(kind: .file, name: "Document", annotation: "deadline is Friday")
        let unrelated = WorkboardMaterialSnapshot(kind: .note, name: "Unrelated")
        workspace.search = "deadline"
        XCTAssertEqual(workspace.visibleMaterials(in: [image, file, unrelated]).map(\.id), [image.id, file.id])
    }

    func testSearchRevealsNativeSidebarWithoutChangingProjectOrDraft() async {
        let workspace = await makeWorkspace(.init())
        let scope = WorkDeskScope.project(UUID())
        workspace.selectScope(scope)
        let session = workspace.composerSession(for: scope)
        session.setText("Keep this project draft")
        workspace.showsSidebar = false
        workspace.updateSidebarLayout(isInline: true)

        workspace.requestSearch()

        XCTAssertTrue(workspace.showsSidebar)
        XCTAssertTrue(workspace.searchIsFocused)
        XCTAssertFalse(workspace.showsProjectPicker)
        XCTAssertEqual(workspace.scope, scope)
        XCTAssertEqual(session.text, "Keep this project draft")
    }

    func testCompactSearchOpensPickerWithoutChangingNativeVisibilityPreference() async {
        let workspace = await makeWorkspace(.init())
        workspace.showsSidebar = false
        workspace.updateSidebarLayout(isInline: false)
        workspace.requestSearch()
        XCTAssertTrue(workspace.showsProjectPicker)
        XCTAssertTrue(workspace.searchIsFocused)
        XCTAssertFalse(workspace.showsSidebar)

        workspace.updateSidebarLayout(isInline: true)
        XCTAssertFalse(workspace.showsProjectPicker)
        XCTAssertFalse(workspace.showsSidebar)
    }

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

    func testHomeKeepsLooseAndDanglingMaterialsWhileProjectHoldsFiledMaterials() async {
        let a = material("A"), b = material("B"), c = material("C")
        let project = WorkDeskProjectRecord(title: "Project")
        let workspace = await makeWorkspace(.init(projects: [project], placements: [
            b.id: .init(materialID: b.id, projectID: project.id),
            c.id: .init(materialID: c.id, projectID: UUID())
        ]))
        XCTAssertEqual(workspace.visibleMaterials(in: [a, b, c]).map(\.id), [a.id, c.id])
        workspace.selectScope(.project(project.id))
        XCTAssertEqual(workspace.visibleMaterials(in: [a, b, c]).map(\.id), [b.id])
        workspace.selectScope(.all)
        XCTAssertEqual(workspace.visibleMaterials(in: [a, b, c]).map(\.id), [a.id, c.id])
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

    func testSelectionOpensPreparationWithExactlyChosenMaterialsAndRetainsTaskAndGateway() async throws {
        let chosen = material("Chosen"), other = material("Other"), outside = material("Outside")
        let project = WorkDeskProjectRecord(title: "Project", brief: "Standing context", preferredGatewayRef: "openclaw")
        let workspace = await makeWorkspace(.init(projects: [project], placements: [
            chosen.id: .init(materialID: chosen.id, projectID: project.id),
            other.id: .init(materialID: other.id, projectID: project.id)
        ]))
        workspace.selectScope(.project(project.id))
        workspace.isActive = true
        let draft = workspace.briefDraft(for: project, resolver: .init())
        draft.brief = "Keep my unfinished task"
        draft.selectedGateway = .builtin(.hermes)

        XCTAssertTrue(workspace.beginConversation(materialIDs: [chosen.id], materials: [chosen, other, outside], resolver: .init()))
        XCTAssertEqual(workspace.preparingProjectID, project.id)
        XCTAssertTrue(workspace.briefDrafts[project.id] === draft)
        XCTAssertTrue(draft.isMaterialIncluded(chosen.id))
        XCTAssertFalse(draft.isMaterialIncluded(other.id))
        XCTAssertFalse(draft.isMaterialIncluded(outside.id))
        XCTAssertFalse(draft.isMaterialIncluded(UUID()), "A later arrival must not silently expand the requested set")
        XCTAssertEqual(draft.projectContext, "Standing context")
        XCTAssertEqual(draft.brief, "Keep my unfinished task")
        XCTAssertEqual(draft.selectedGateway, .builtin(.hermes))
        XCTAssertNil(draft.handoff.prepared, "Selection opens editable preparation, never review or send")
        XCTAssertNil(draft.handoff.acceptedConversationID)
        XCTAssertFalse(draft.handoff.isSending)
        XCTAssertEqual(workspace.organization.projectID(for: chosen.id), project.id)
        XCTAssertNil(workspace.projectEditor)
    }

    func testMissingOrForeignSelectionIsRefusedWithoutShrinkingIt() async {
        let chosen = material("Chosen"), foreign = material("Foreign")
        let project = WorkDeskProjectRecord(title: "Project"), other = WorkDeskProjectRecord(title: "Other")
        let workspace = await makeWorkspace(.init(projects: [project, other], placements: [
            chosen.id: .init(materialID: chosen.id, projectID: project.id),
            foreign.id: .init(materialID: foreign.id, projectID: other.id)
        ]))
        workspace.selectScope(.project(project.id))
        workspace.isActive = true
        for invalidID in [foreign.id, UUID()] {
            XCTAssertFalse(workspace.beginConversation(materialIDs: [chosen.id, invalidID], materials: [chosen, foreign], resolver: .init()))
            XCTAssertNil(workspace.preparingProjectID)
            XCTAssertNil(workspace.briefDrafts[project.id])
            XCTAssertNotNil(workspace.organization.errorMessage)
        }
    }

    func testEmptyHiddenAndGlobalSearchSelectionsNeverOpenProjectPreparation() async {
        let chosen = material("Chosen")
        let project = WorkDeskProjectRecord(title: "Project")
        let workspace = await makeWorkspace(.init(projects: [project], placements: [
            chosen.id: .init(materialID: chosen.id, projectID: project.id)
        ]))
        workspace.selectScope(.project(project.id))
        XCTAssertFalse(workspace.beginConversation(materialIDs: [chosen.id], materials: [chosen], resolver: .init()))
        workspace.isActive = true
        XCTAssertFalse(workspace.beginConversation(materialIDs: [], materials: [chosen], resolver: .init()))
        workspace.search = "Chosen"
        XCTAssertFalse(workspace.beginConversation(materialIDs: [chosen.id], materials: [chosen], resolver: .init()))
        workspace.selectScope(.all)
        XCTAssertFalse(workspace.beginConversation(materialIDs: [chosen.id], materials: [chosen], resolver: .init()))
        XCTAssertNil(workspace.preparingProjectID)
    }

    func testSelectionDoesNotDisturbADraftWhileItsSaveIsInProgress() async {
        let chosen = material("Chosen")
        let project = WorkDeskProjectRecord(title: "Project", brief: "Stored context")
        let workspace = await makeWorkspace(.init(projects: [project], placements: [
            chosen.id: .init(materialID: chosen.id, projectID: project.id)
        ]))
        workspace.selectScope(.project(project.id))
        workspace.isActive = true
        let draft = workspace.briefDraft(for: project, resolver: .init())
        draft.projectContext = "Context being saved"
        draft.isSaving = true
        XCTAssertFalse(workspace.beginConversation(materialIDs: [chosen.id], materials: [chosen], resolver: .init()))
        XCTAssertEqual(draft.projectContext, "Context being saved")
        XCTAssertNil(draft.selectedMaterialIDs)
        XCTAssertNil(workspace.preparingProjectID)
    }

    func testMaterialMenuRequestIsFrozenAndNavigationCancelsIt() async throws {
        let project = WorkDeskProjectRecord(title: "First"), second = WorkDeskProjectRecord(title: "Second")
        let workspace = await makeWorkspace(.init(projects: [project, second]))
        workspace.selectScope(.project(project.id))
        let id = UUID()
        workspace.requestConversation(materialIDs: [id])
        let request = try XCTUnwrap(workspace.conversationSelectionRequest)
        workspace.selectedIDs = [UUID()]
        XCTAssertEqual(request.projectID, project.id)
        XCTAssertEqual(request.materialIDs, [id])
        workspace.selectScope(.project(second.id))
        XCTAssertNil(workspace.conversationSelectionRequest)
        workspace.requestConversation(materialIDs: [id])
        workspace.search = "Global search"
        XCTAssertNil(workspace.conversationSelectionRequest)
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
            switch mutation {
            case .assign(let ids, _), .addLocations(let ids, _, _, _), .moveLocations(let ids, _, _, _, _): assignedIDs = ids
            default: break
            }
        }
    }
}
