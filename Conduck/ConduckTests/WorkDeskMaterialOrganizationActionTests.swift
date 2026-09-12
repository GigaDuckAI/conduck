// SPDX-License-Identifier: Apache-2.0

// The menu retains a live workspace across cached preview refreshes. Exercise
// its move, selection and project-creation intents against isolated stores,
// including stale destinations and observed changes from another presentation.

import XCTest
import Observation
@testable import Conduck

@MainActor
final class WorkDeskMaterialOrganizationActionTests: XCTestCase {
    private let isolated = IsolatedWorkStores()

    override func tearDown() async throws {
        await isolated.cleanUp()
        try await super.tearDown()
    }

    func testMoveOffersOtherProjectsAndReturnToDeskUsesTheSameMaterial() async throws {
        let store = isolated.make()
        let material = try await capture(in: store)
        let source = WorkDeskProjectRecord(title: "Source")
        let destination = WorkDeskProjectRecord(title: "Destination")
        try await store.applyWorkDeskMutation(.createProject(source, materialIDs: [material.id]))
        try await store.applyWorkDeskMutation(.createProject(destination, materialIDs: []))
        let organization = WorkDeskOrganization(store: store)
        await organization.reload()
        let workspace = WorkDeskWorkspaceState(organization: organization)
        workspace.selectedIDs = [material.id]
        let actions = WorkDeskMaterialOrganizationActions(workspace: workspace, materialID: material.id, sourceLocation: .project(source.id))
        XCTAssertEqual(actions.destinations.map(\.id), [destination.id])
        let moved = await actions.move(to: destination.id)
        XCTAssertTrue(moved)
        XCTAssertEqual(actions.projectID, destination.id)
        XCTAssertFalse(actions.canMove, "The old source appearance no longer owns this action.")
        XCTAssertTrue(workspace.selectedIDs.isEmpty)
        let destinationActions = WorkDeskMaterialOrganizationActions(workspace: workspace, materialID: material.id,
                                                                    sourceLocation: .project(destination.id))
        let returned = await destinationActions.move(to: nil)
        XCTAssertTrue(returned)
        XCTAssertNil(actions.project)
        let homeActions = WorkDeskMaterialOrganizationActions(workspace: workspace, materialID: material.id, sourceLocation: .home)
        XCTAssertEqual(Set(homeActions.destinations.map(\.id)), [source.id, destination.id])
        let preserved = try await store.fetchWorkMaterial(id: material.id)
        XCTAssertEqual(preserved, material)
    }

    func testDeletedDestinationRefusesMoveAndPreservesSelectionAndMembership() async throws {
        let store = isolated.make()
        let material = try await capture(in: store)
        let source = WorkDeskProjectRecord(title: "Source")
        let destination = WorkDeskProjectRecord(title: "Destination")
        try await store.applyWorkDeskMutation(.createProject(source, materialIDs: [material.id]))
        try await store.applyWorkDeskMutation(.createProject(destination, materialIDs: []))
        let organization = WorkDeskOrganization(store: store)
        await organization.reload()
        let workspace = WorkDeskWorkspaceState(organization: organization)
        workspace.selectedIDs = [material.id]
        let actions = WorkDeskMaterialOrganizationActions(workspace: workspace, materialID: material.id, sourceLocation: .project(source.id))
        // Another presentation removed the target after this menu was opened.
        try await store.applyWorkDeskMutation(.deleteProject(id: destination.id))
        let moved = await actions.move(to: destination.id)
        XCTAssertFalse(moved)
        XCTAssertEqual(actions.projectID, source.id)
        XCTAssertEqual(workspace.selectedIDs, [material.id])
        XCTAssertNotNil(organization.errorMessage)
    }

    func testCreateProjectOnlyOpensTheEditorAtTheMaterialAndSelectUsesSelectionMode() async throws {
        let store = isolated.make()
        let material = try await capture(in: store)
        let point = WorkDeskPoint(x: 800, y: 450)
        try await store.applyWorkDeskMutation(.moveMaterial(id: material.id, position: point))
        let organization = WorkDeskOrganization(store: store)
        await organization.reload()
        let workspace = WorkDeskWorkspaceState(organization: organization)
        let actions = WorkDeskMaterialOrganizationActions(workspace: workspace, materialID: material.id)
        actions.createProject()
        XCTAssertEqual(workspace.projectEditor?.materialIDs, [material.id])
        let proposed = try XCTUnwrap(workspace.projectEditor?.position)
        let folder = WorkDeskCanvasGeometry.frame(at: proposed, bodySize: WorkDeskCanvasGeometry.projectBodySize, scale: 1)
        let card = WorkDeskCanvasGeometry.frame(at: point, bodySize: WorkDeskCanvasGeometry.cardBodySize, scale: 1)
        XCTAssertFalse(folder.intersects(card), "The editor's folder must not cover its source material")
        XCTAssertLessThanOrEqual(hypot(proposed.x - point.x, proposed.y - point.y),
            Double(max(WorkDeskCanvasGeometry.projectBodySize.width, WorkDeskCanvasGeometry.projectBodySize.height)),
            "Creating from a material must retain that material's part of the desk")
        XCTAssertTrue(organization.projects.isEmpty, "menu activation must not create an unnamed project")
        actions.select()
        XCTAssertTrue(workspace.isSelecting)
        XCTAssertEqual(workspace.selectedIDs, [material.id])
    }

    func testCachedDescriptorObservesRenameAndMembershipFromOtherPresentations() async throws {
        let store = isolated.make()
        let material = try await capture(in: store)
        let project = WorkDeskProjectRecord(title: "Original")
        try await store.applyWorkDeskMutation(.createProject(project, materialIDs: []))
        let organization = WorkDeskOrganization(store: store)
        await organization.reload()
        let workspace = WorkDeskWorkspaceState(organization: organization)
        let actions = WorkDeskMaterialOrganizationActions(workspace: workspace, materialID: material.id)
        let flag = ChangeFlag()
        withObservationTracking {
            _ = actions.project
            _ = actions.destinations
        } onChange: { MainActor.assumeIsolated { flag.didChange = true } }
        try await store.applyWorkDeskMutation(.assign(materialIDs: [material.id], projectID: project.id))
        try await store.applyWorkDeskMutation(.updateProject(
            id: project.id, title: "Renamed elsewhere", brief: "", preferredGatewayRef: nil
        ))
        await organization.reload()
        XCTAssertTrue(flag.didChange, "the menu must invalidate below an unchanged cached material preview")
        XCTAssertEqual(actions.project?.title, "Renamed elsewhere")
        XCTAssertTrue(actions.additionalDestinations.isEmpty)
        actions.openProject()
        XCTAssertEqual(workspace.scope, .project(project.id))
        let openedActions = WorkDeskMaterialOrganizationActions(workspace: workspace, materialID: material.id,
                                                               sourceLocation: .project(project.id))
        XCTAssertFalse(openedActions.showsLocation)
        workspace.search = "Renamed"
        XCTAssertTrue(actions.showsLocation)
    }

    func testProjectMenuPreparesSelectedSetWithoutCreatingAnotherProject() async throws {
        let store = isolated.make()
        let first = try await capture(in: store)
        let second = try await capture(in: store)
        let project = WorkDeskProjectRecord(title: "Existing project")
        try await store.applyWorkDeskMutation(.createProject(project, materialIDs: [first.id, second.id]))
        let organization = WorkDeskOrganization(store: store)
        await organization.reload()
        let workspace = WorkDeskWorkspaceState(organization: organization)
        workspace.selectScope(.project(project.id))
        workspace.selectedIDs = [first.id, second.id]
        let actions = WorkDeskMaterialOrganizationActions(workspace: workspace, materialID: first.id)
        XCTAssertFalse(actions.canCreateProject)
        actions.createProject()
        XCTAssertNil(workspace.projectEditor)
        XCTAssertTrue(actions.canStartConversation)
        XCTAssertEqual(actions.conversationMaterialIDs, [first.id, second.id])
        actions.startConversation()
        XCTAssertEqual(workspace.conversationSelectionRequest?.materialIDs, [first.id, second.id])
        XCTAssertEqual(workspace.conversationSelectionRequest?.projectID, project.id)
        XCTAssertNil(workspace.preparingProjectID, "The host must validate the current snapshot first")
        XCTAssertEqual(organization.projects.map(\.id), [project.id])
        XCTAssertEqual(actions.projectID, project.id)
    }

    func testUnselectedCardUsesOnlyItselfAndSearchCannotBorrowProjectContext() async throws {
        let store = isolated.make()
        let material = try await capture(in: store)
        let project = WorkDeskProjectRecord(title: "Existing project")
        try await store.applyWorkDeskMutation(.createProject(project, materialIDs: [material.id]))
        let organization = WorkDeskOrganization(store: store)
        await organization.reload()
        let workspace = WorkDeskWorkspaceState(organization: organization)
        workspace.selectScope(.project(project.id))
        workspace.selectedIDs = [UUID()]
        let actions = WorkDeskMaterialOrganizationActions(workspace: workspace, materialID: material.id)
        XCTAssertEqual(actions.conversationMaterialIDs, [material.id])
        workspace.search = "Existing project"
        XCTAssertFalse(actions.canStartConversation)
        actions.startConversation()
        XCTAssertNil(workspace.conversationSelectionRequest)
        XCTAssertFalse(actions.canCreateProject)
        workspace.selectScope(.all)
        XCTAssertFalse(actions.canCreateProject, "A retained project card must not borrow a newly selected Home context.")
        XCTAssertFalse(actions.canStartConversation)
    }

    func testUsageCountsActualConversationsOnceForAFoldedCard() async throws {
        let store = isolated.make()
        let project = WorkDeskProjectRecord(title: "Current home")
        _ = try await store.applyWorkDeskMutation(.createProject(project, materialIDs: []))
        let words = WorkboardMaterialSnapshot(kind: .transcript, name: "Words")
        let picture = WorkboardMaterialSnapshot(kind: .image, name: "Picture", companion: WorkboardCompanionSnapshot(words))
        let first = try await store.createConversation(backend: "hermes", projectID: project.id, title: "Used both")
        _ = try await store.appendMessage(role: "user", text: "Sent together", conversationID: first.id,
            sourceDevice: "test", workMaterialInputs: [.init(materialID: picture.id), .init(materialID: words.id)])
        let second = try await store.createConversation(backend: "openclaw", projectID: project.id, title: "Used words")
        _ = try await store.appendMessage(role: "user", text: "Sent words", conversationID: second.id,
            sourceDevice: "test", workMaterialInputs: [.init(materialID: words.id)])
        _ = try await store.createConversation(backend: "hermes", projectID: project.id, title: "Did not use this card")
        let workspace = WorkDeskWorkspaceState(organization: WorkDeskOrganization(store: store), conversationStore: store)
        await workspace.organization.reload()
        workspace.reconcile(materials: [picture])
        await workspace.reloadProjectActivity()
        let actions = WorkDeskMaterialOrganizationActions(workspace: workspace, materialID: picture.id)
        XCTAssertEqual(Set(actions.uses.map(\.conversationID)), [first.id, second.id])
        XCTAssertEqual(actions.uses.count, 2, "Picture and companion sent together describe one conversation")
        actions.showUses()
        XCTAssertEqual(workspace.materialUsePickerID, picture.id)
        workspace.openRelatedConversation(first.id)
        XCTAssertNil(workspace.materialUsePickerID)
        XCTAssertEqual(workspace.scope, .project(project.id))
        XCTAssertEqual(workspace.selectedConversationID, first.id)
        try await store.deleteConversation(id: second.id)
        await workspace.reloadProjectActivity()
        XCTAssertEqual(actions.uses.map(\.conversationID), [first.id])
    }

    func testSharedMaterialMoveAndRemovalChangeOnlyTheVisibleLocation() async throws {
        let store = isolated.make()
        let material = try await capture(in: store)
        let first = WorkDeskProjectRecord(title: "First")
        let second = WorkDeskProjectRecord(title: "Second")
        let third = WorkDeskProjectRecord(title: "Third")
        try await store.applyWorkDeskMutation(.createProject(first, materialIDs: [material.id]))
        try await store.applyWorkDeskMutation(.createProject(second, materialIDs: []))
        try await store.applyWorkDeskMutation(.createProject(third, materialIDs: []))
        let organization = WorkDeskOrganization(store: store)
        await organization.reload()
        let workspace = WorkDeskWorkspaceState(organization: organization)
        let firstActions = WorkDeskMaterialOrganizationActions(workspace: workspace, materialID: material.id,
                                                              sourceLocation: .project(first.id))
        let added = await firstActions.add(to: second.id)
        XCTAssertTrue(added)
        XCTAssertEqual(Set(firstActions.projects.map(\.id)), [first.id, second.id])
        XCTAssertEqual(firstActions.additionalDestinations.map(\.id), [third.id])
        let moved = await firstActions.move(to: third.id)
        XCTAssertTrue(moved)
        XCTAssertFalse(organization.contains(materialID: material.id, at: .project(first.id)))
        XCTAssertTrue(organization.contains(materialID: material.id, at: .project(second.id)))
        XCTAssertTrue(organization.contains(materialID: material.id, at: .project(third.id)))
        let thirdActions = WorkDeskMaterialOrganizationActions(workspace: workspace, materialID: material.id,
                                                              sourceLocation: .project(third.id))
        let returned = await thirdActions.move(to: nil)
        XCTAssertTrue(returned)
        XCTAssertTrue(organization.contains(materialID: material.id, at: .home))
        XCTAssertTrue(organization.contains(materialID: material.id, at: .project(second.id)))
        XCTAssertFalse(organization.contains(materialID: material.id, at: .project(third.id)))
        let secondActions = WorkDeskMaterialOrganizationActions(workspace: workspace, materialID: material.id,
                                                               sourceLocation: .project(second.id))
        let removed = await secondActions.removeFromProject()
        XCTAssertTrue(removed)
        XCTAssertTrue(organization.contains(materialID: material.id, at: .home))
        XCTAssertTrue(secondActions.projects.isEmpty)
        let preserved = try await store.fetchWorkMaterial(id: material.id)
        XCTAssertEqual(preserved, material, "Filing never creates or edits another payload.")
    }

    func testSearchCanAddWithoutInventingAMoveSource() async throws {
        let store = isolated.make()
        let material = try await capture(in: store)
        let project = WorkDeskProjectRecord(title: "Project")
        try await store.applyWorkDeskMutation(.createProject(project, materialIDs: []))
        let organization = WorkDeskOrganization(store: store)
        await organization.reload()
        let workspace = WorkDeskWorkspaceState(organization: organization)
        workspace.search = "Thought"
        let actions = WorkDeskMaterialOrganizationActions(workspace: workspace, materialID: material.id, sourceLocation: nil)
        XCTAssertFalse(actions.canMove)
        XCTAssertFalse(actions.canCreateProject)
        let moved = await actions.move(to: project.id)
        XCTAssertFalse(moved)
        let added = await actions.add(to: project.id)
        XCTAssertTrue(added)
        XCTAssertTrue(organization.contains(materialID: material.id, at: .home))
        XCTAssertTrue(organization.contains(materialID: material.id, at: .project(project.id)))
        let addedAgain = await actions.add(to: project.id)
        XCTAssertTrue(addedAgain)
        XCTAssertEqual(actions.projects.count, 1)
    }

    func testBackgroundHomeCardCannotBorrowTrayProjectForSelectionOrConversation() async throws {
        let store = isolated.make()
        let material = try await capture(in: store)
        let project = WorkDeskProjectRecord(title: "Open tray")
        try await store.applyWorkDeskMutation(.createProject(project, materialIDs: []))
        let organization = WorkDeskOrganization(store: store)
        await organization.reload()
        let added = await organization.add(materialIDs: [material.id], to: .project(project.id))
        XCTAssertTrue(added)
        let workspace = WorkDeskWorkspaceState(organization: organization)
        workspace.selectScope(.project(project.id))
        let actions = WorkDeskMaterialOrganizationActions(workspace: workspace, materialID: material.id, sourceLocation: .home)
        XCTAssertFalse(actions.canStartConversation)
        actions.startConversation()
        XCTAssertNil(workspace.conversationSelectionRequest)
        actions.select()
        XCTAssertEqual(workspace.scope, .all)
        XCTAssertEqual(workspace.selectedIDs, [material.id])
    }

    func testSelectingAnotherCardInSameLocationPreservesTheExistingSelection() async throws {
        let store = isolated.make()
        let first = try await capture(in: store)
        let second = try await capture(in: store)
        let organization = WorkDeskOrganization(store: store)
        await organization.reload()
        let workspace = WorkDeskWorkspaceState(organization: organization)
        workspace.selectedIDs = [first.id]
        workspace.isSelecting = true
        let actions = WorkDeskMaterialOrganizationActions(workspace: workspace, materialID: second.id, sourceLocation: .home)
        actions.select()
        XCTAssertEqual(workspace.selectedIDs, [first.id, second.id])
        actions.select()
        XCTAssertEqual(workspace.selectedIDs, [first.id])
    }

    func testAStaleMenuNeverMovesANewerAppearance() async throws {
        let store = isolated.make()
        let material = try await capture(in: store)
        let first = WorkDeskProjectRecord(title: "First")
        let second = WorkDeskProjectRecord(title: "Second")
        try await store.applyWorkDeskMutation(.createProject(first, materialIDs: [material.id]))
        try await store.applyWorkDeskMutation(.createProject(second, materialIDs: []))
        let organization = WorkDeskOrganization(store: store)
        await organization.reload()
        let workspace = WorkDeskWorkspaceState(organization: organization)
        workspace.selectedIDs = [material.id]
        let stale = WorkDeskMaterialOrganizationActions(workspace: workspace, materialID: material.id, sourceLocation: .project(first.id))
        let movedElsewhere = await organization.move(materialIDs: [material.id], from: .project(first.id), to: .project(second.id))
        XCTAssertTrue(movedElsewhere)
        let staleMove = await stale.move(to: nil)
        XCTAssertFalse(staleMove)
        XCTAssertTrue(organization.contains(materialID: material.id, at: .project(second.id)))
        XCTAssertFalse(organization.contains(materialID: material.id, at: .home))
        XCTAssertEqual(workspace.selectedIDs, [material.id])
    }

    private func capture(in store: ConversationStore) async throws -> WorkMaterialRecord {
        try await store.upsertDeskMaterial(.init(kind: .note, title: "Thought", textContent: "Words stay intact"))
    }

    @MainActor private final class ChangeFlag { var didChange = false }
}
