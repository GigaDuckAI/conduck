// SPDX-License-Identifier: Apache-2.0

// The container/sidebar/composer workflow and Pro admission share live state.
// These tests cross the new source-aware mutations and retained draft owner;
// a refused action keeps both material locations and the request intact.

import XCTest
@testable import Conduck

@MainActor
final class WorkDeskProMergeWorkflowTests: XCTestCase {
    private let isolated = IsolatedWorkStores()

    override func tearDown() async throws {
        await isolated.cleanUp()
        try await super.tearDown()
    }

    func testSourceAwareFourthProjectPreservesHomeMaterialUntilVerifiedPurchase() async throws {
        let access = MergeProjectAccess()
        let store = isolated.make(proAccessProvider: { access.snapshot })
        let material = try await store.upsertDeskMaterial(.init(kind: .note, title: "Selected idea"))
        for index in 0..<3 {
            try await store.applyWorkDeskMutation(.createProject(.init(title: "Project \(index)"), materialIDs: []))
        }
        let organization = WorkDeskOrganization(store: store, proAccessProvider: { access.snapshot })
        await organization.reload()
        let original = organization.locationTokens(for: [material.id])
        let refused = await organization.createProject(title: "Preserved name", materialIDs: [material.id],
            from: .home, expected: original)
        XCTAssertNil(refused)
        XCTAssertTrue(organization.projectLimitRequested)
        XCTAssertEqual(organization.projects.count, 3)
        XCTAssertEqual(organization.locationTokens(for: [material.id]), original)
        access.setPro(true)
        organization.projectLimitRequested = false
        let created = await organization.createProject(title: "Preserved name", materialIDs: [material.id],
            from: .home, expected: original)
        let projectID = try XCTUnwrap(created)
        XCTAssertEqual(organization.projects.count, 4)
        XCTAssertTrue(organization.contains(materialID: material.id, at: .project(projectID)))
        XCTAssertFalse(organization.contains(materialID: material.id, at: .home))
        let preserved = try await store.fetchWorkMaterial(id: material.id)
        XCTAssertEqual(preserved, material)
    }

    func testProjectAdmissionRejectsArchivedProjectAndPreservesRetainedRequestThroughRestore() async throws {
        let store = isolated.make()
        let project = WorkDeskProjectRecord(title: "Project")
        try await store.applyWorkDeskMutation(.createProject(project, materialIDs: []))
        let organization = WorkDeskOrganization(store: store)
        await organization.reload()
        let workspace = WorkDeskWorkspaceState(organization: organization, conversationStore: store,
            draftStore: .init(storage: InMemoryWorkDeskBriefDraftStorage()))
        workspace.setRefreshActive(true)
        workspace.selectScope(.project(project.id))
        XCTAssertTrue(workspace.beginConversation(resolver: .init()))
        let draft = try XCTUnwrap(workspace.briefDrafts[project.id])
        draft.brief = "Keep my unsent request"
        workspace.preparingProjectID = nil
        let archived = await organization.setProjectArchived(true, id: project.id)
        XCTAssertTrue(archived)
        XCTAssertFalse(workspace.beginConversation(resolver: .init()))
        XCTAssertNil(workspace.preparingProjectID)
        XCTAssertTrue(workspace.briefDrafts[project.id] === draft)
        XCTAssertEqual(draft.brief, "Keep my unsent request")
        XCTAssertEqual(workspace.displayedScope, .project(project.id), "Archiving must leave project browsing available")
        workspace.selectConversation(UUID(), projectID: project.id)
        XCTAssertTrue(workspace.isShowingConversation)
        XCTAssertTrue(workspace.showsProjectAccessRecovery, "An archived conversation keeps its restore affordance")
        workspace.selectScope(.project(project.id))
        workspace.search = "Find a material"
        XCTAssertEqual(workspace.displayedScope, .all)
        XCTAssertNil(WorkboardCaptureDestination(workspace: workspace).projectID, "Global search still captures into Home")
        XCTAssertFalse(workspace.showsProjectAccessRecovery, "Archived navigation must not block Home search")
        workspace.search = ""
        let restored = await organization.setProjectArchived(false, id: project.id)
        XCTAssertTrue(restored)
        XCTAssertTrue(workspace.beginConversation(resolver: .init()))
        XCTAssertTrue(workspace.briefDrafts[project.id] === draft)
        XCTAssertEqual(draft.brief, "Keep my unsent request")
    }

    func testExpiredProjectAndMaterialActionsWaitForChoiceButKeepHomeRemovalAvailable() async throws {
        let access = MergeProjectAccess(hasPro: true)
        let store = isolated.make(proAccessProvider: { access.snapshot })
        let material = try await store.upsertDeskMaterial(.init(kind: .note, title: "Preserved idea"))
        var projects: [WorkDeskProjectRecord] = []
        for index in 0..<4 {
            let project = WorkDeskProjectRecord(title: "Project \(index)")
            try await store.applyWorkDeskMutation(.createProject(project, materialIDs: index == 0 ? [material.id] : []))
            projects.append(project)
        }
        let organization = WorkDeskOrganization(store: store, proAccessProvider: { access.snapshot })
        await organization.reload()
        let workspace = WorkDeskWorkspaceState(organization: organization, conversationStore: store,
            draftStore: .init(storage: InMemoryWorkDeskBriefDraftStorage()))
        workspace.setRefreshActive(true)
        workspace.selectScope(.project(projects[0].id))
        let actions = WorkDeskMaterialOrganizationActions(workspace: workspace, materialID: material.id,
            sourceLocation: .project(projects[0].id))
        XCTAssertTrue(actions.canStartConversation)
        XCTAssertEqual(actions.destinations.count, 3)
        access.setPro(false)
        XCTAssertFalse(workspace.beginConversation(resolver: .init()))
        XCTAssertFalse(actions.canStartConversation)
        XCTAssertTrue(actions.destinations.isEmpty)
        XCTAssertTrue(actions.additionalDestinations.isEmpty)
        XCTAssertTrue(actions.canMoveHome)
        let moved = await actions.move(to: nil)
        XCTAssertTrue(moved)
        XCTAssertTrue(organization.contains(materialID: material.id, at: .home))
        XCTAssertEqual(organization.activeProjects.count, 4, "Reading or moving Home never chooses projects for the person")
    }

    func testLateLapseInContentsPreviewKeepsSelectionWithPreviewAndPreservesLocations() async throws {
        let access = MergeProjectAccess(hasPro: true)
        let store = isolated.make(proAccessProvider: { access.snapshot })
        let material = try await store.upsertDeskMaterial(.init(kind: .note, title: "Idea in preview"))
        let projects = (0..<4).map { WorkDeskProjectRecord(title: "Project \($0)") }
        for (index, project) in projects.enumerated() {
            try await store.applyWorkDeskMutation(.createProject(project, materialIDs: index == 0 ? [material.id] : []))
        }
        let organization = WorkDeskOrganization(store: store, proAccessProvider: { access.snapshot })
        await organization.reload()
        let workspace = WorkDeskWorkspaceState(organization: organization, conversationStore: store,
            draftStore: .init(storage: InMemoryWorkDeskBriefDraftStorage()))
        workspace.setRefreshActive(true)
        workspace.projectPreview.toggle(projectID: projects[0].id,
            anchor: CGRect(x: 20, y: 40, width: 180, height: 220), materialCount: 1)
        let preview = try XCTUnwrap(workspace.projectPreview.request)
        let actions = WorkDeskMaterialOrganizationActions(workspace: workspace, materialID: material.id,
            sourceLocation: .project(projects[0].id))
        XCTAssertTrue(actions.additionalDestinations.contains { $0.id == projects[1].id })
        let before = organization.locationTokens(for: [material.id])
        access.setPro(false)
        let added = await actions.add(to: projects[1].id)
        XCTAssertFalse(added)
        XCTAssertNil(organization.errorMessage, "The typed choice owns the remedy instead of a covered error")
        XCTAssertEqual(workspace.projectSelectionPresenter, .preview(preview.id))
        XCTAssertEqual(workspace.projectPreview.request, preview)
        XCTAssertEqual(organization.locationTokens(for: [material.id]), before)
        organization.projectSelectionRequested = false
        XCTAssertNil(workspace.projectSelectionPresenter)
        XCTAssertEqual(workspace.projectPreview.request, preview, "Cancel leaves the preview and all materials intact")
        organization.projectSelectionRequested = true
        let selected = await organization.selectFreeProjects(keeping: Set(projects.dropFirst().map(\.id)),
            expectedActiveProjectIDs: Set(projects.map(\.id)))
        XCTAssertTrue(selected)
        XCTAssertNil(workspace.projectSelectionPresenter)
        XCTAssertEqual(workspace.projectPreview.request, preview)
        XCTAssertTrue(organization.project(id: preview.projectID)?.isArchived == true)
        XCTAssertEqual(organization.locationTokens(for: [material.id]), before)
    }

    func testUndoInPreviewAfterLapseRoutesChoiceWithoutMovingMaterialBackIntoPausedProject() async throws {
        let access = MergeProjectAccess(hasPro: true)
        let store = isolated.make(proAccessProvider: { access.snapshot })
        let material = try await store.upsertDeskMaterial(.init(kind: .note, title: "Keep on Home"))
        let projects = (0..<4).map { WorkDeskProjectRecord(title: "Project \($0)") }
        for (index, project) in projects.enumerated() {
            try await store.applyWorkDeskMutation(.createProject(project, materialIDs: index == 0 ? [material.id] : []))
        }
        let organization = WorkDeskOrganization(store: store, proAccessProvider: { access.snapshot })
        await organization.reload()
        let workspace = WorkDeskWorkspaceState(organization: organization, conversationStore: store,
            draftStore: .init(storage: InMemoryWorkDeskBriefDraftStorage()))
        workspace.setRefreshActive(true)
        workspace.projectPreview.toggle(projectID: projects[0].id,
            anchor: CGRect(x: 20, y: 40, width: 180, height: 220), materialCount: 1)
        let preview = try XCTUnwrap(workspace.projectPreview.request)
        let moved = await organization.move(materialIDs: [material.id], from: .project(projects[0].id), to: .home)
        XCTAssertTrue(moved)
        let receipt = try XCTUnwrap(organization.lastLocationUndo)
        workspace.organizationUndo.receive(receipt, organization: organization, manager: nil)
        access.setPro(false)
        await workspace.organizationUndo.undoLatest(organization: organization)
        XCTAssertEqual(workspace.projectSelectionPresenter, .preview(preview.id))
        XCTAssertEqual(workspace.projectPreview.request, preview)
        XCTAssertEqual(organization.locations(for: material.id).map(\.location), [.home])
        XCTAssertEqual(organization.activeProjects.count, 4)
        workspace.projectPreview.dismiss(force: true)
        XCTAssertEqual(workspace.projectSelectionPresenter, .workspace, "A closed preview cannot remain the presenter")
        workspace.showsProjectPicker = true
        XCTAssertEqual(workspace.projectSelectionPresenter, .picker)
    }

    func testArchivedDestinationsStayBrowsableButLeaveMoveAndAddMenus() async throws {
        let store = isolated.make()
        let material = try await store.upsertDeskMaterial(.init(kind: .note, title: "Idea"))
        let source = WorkDeskProjectRecord(title: "Source")
        let archived = WorkDeskProjectRecord(title: "Archived destination")
        let active = WorkDeskProjectRecord(title: "Active destination")
        for project in [source, archived, active] {
            try await store.applyWorkDeskMutation(.createProject(project, materialIDs: project.id == source.id ? [material.id] : []))
        }
        try await store.applyWorkDeskMutation(.archiveProject(id: archived.id, isArchived: true))
        let organization = WorkDeskOrganization(store: store)
        await organization.reload()
        let workspace = WorkDeskWorkspaceState(organization: organization, conversationStore: store,
            draftStore: .init(storage: InMemoryWorkDeskBriefDraftStorage()))
        workspace.setRefreshActive(true)
        let actions = WorkDeskMaterialOrganizationActions(workspace: workspace, materialID: material.id,
            sourceLocation: .project(source.id))
        XCTAssertEqual(actions.destinations.map(\.id), [active.id])
        XCTAssertEqual(actions.additionalDestinations.map(\.id), [active.id])
        XCTAssertEqual(organization.archivedProjects.map(\.id), [archived.id])
        workspace.selectScope(.project(archived.id))
        XCTAssertEqual(workspace.currentProject?.id, archived.id)
        XCTAssertEqual(workspace.displayedScope, .project(archived.id))
    }
}

private final class MergeProjectAccess: @unchecked Sendable {
    private let lock = NSLock()
    private var hasPro: Bool
    init(hasPro: Bool = false) { self.hasPro = hasPro }
    var snapshot: ProAccessSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return .init(hasProAccess: hasPro)
    }
    func setPro(_ value: Bool) {
        lock.lock()
        defer { lock.unlock() }
        hasPro = value
    }
}
