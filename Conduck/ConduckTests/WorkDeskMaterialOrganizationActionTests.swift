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
        let actions = WorkDeskMaterialOrganizationActions(workspace: workspace, materialID: material.id)
        XCTAssertEqual(actions.destinations.map(\.id), [destination.id])
        let moved = await actions.move(to: destination.id)
        XCTAssertTrue(moved)
        XCTAssertEqual(actions.projectID, destination.id)
        XCTAssertEqual(actions.destinations.map(\.id), [source.id])
        XCTAssertTrue(workspace.selectedIDs.isEmpty)
        let returned = await actions.move(to: nil)
        XCTAssertTrue(returned)
        XCTAssertNil(actions.project)
        XCTAssertEqual(Set(actions.destinations.map(\.id)), [source.id, destination.id])
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
        let actions = WorkDeskMaterialOrganizationActions(workspace: workspace, materialID: material.id)
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
        XCTAssertEqual(workspace.projectEditor?.position, WorkDeskPoint(x: point.x, y: point.y - 188))
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
        XCTAssertTrue(actions.destinations.isEmpty)
        workspace.selectScope(.project(project.id))
        XCTAssertFalse(actions.showsLocation)
        workspace.search = "Renamed"
        XCTAssertTrue(actions.showsLocation)
    }

    private func capture(in store: ConversationStore) async throws -> WorkMaterialRecord {
        try await store.upsertDeskMaterial(.init(kind: .note, title: "Thought", textContent: "Words stay intact"))
    }

    @MainActor private final class ChangeFlag { var didChange = false }
}
