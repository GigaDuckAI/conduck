// SPDX-License-Identifier: Apache-2.0

// Projects replace the main workspace without losing their camera sessions.
// Global search must use the aggregate board even when navigation remembers a
// project; hidden board input must disappear rather than sit below new content.

import XCTest
@testable import Conduck

@MainActor
final class WorkDeskProjectNavigationTests: XCTestCase {
    func testOneScopeOwnsTheRenderedBoardAndItsInputLifetime() throws {
        let surface = try RefusalLaneSource.source(at: "Conduck/Views/Workboard/WorkDeskProjectSurface.swift")
        XCTAssertEqual(surface.components(separatedBy: "WorkDeskSourceBoard(").count - 1, 1,
            "A hidden Home board must not retain native focus, zoom controls or drop targets.")
        XCTAssertTrue(surface.contains("scopeOverride: workspace.displayedScope"))
        XCTAssertTrue(surface.contains(".id(workspace.displayedScope)"),
            "Changing location must tear down scope-local gesture and focus ownership.")
        let board = try RefusalLaneSource.source(at: "Conduck/Views/Workboard/WorkDeskSourceBoard.swift")
        XCTAssertTrue(board.contains("scopeOverride ?? workspace.displayedScope"))
        XCTAssertTrue(board.contains("workspace.selectMaterial(id, in: boardScope)"))
    }

    func testOpeningClosingAndSearchingKeepBothCameraSessions() async {
        let project = WorkDeskProjectRecord(title: "Research")
        let organization = WorkDeskOrganization(fetch: { .init(projects: [project]) }, apply: { _ in .init(projects: [project]) })
        await organization.reload()
        let workspace = WorkDeskWorkspaceState(organization: organization)
        let home = workspace.canvasSession(for: .all)
        let inside = workspace.canvasSession(for: .project(project.id))
        home.transform = WorkDeskCanvasTransform(scale: 0.48, offset: CGSize(width: 312, height: -90))
        inside.transform = WorkDeskCanvasTransform(scale: 0.9, offset: CGSize(width: -25, height: 76))
        let homeBefore = home.transform
        let insideBefore = inside.transform
        workspace.selectScope(.project(project.id))
        XCTAssertEqual(workspace.displayedScope, .project(project.id))
        workspace.search = "draft"
        XCTAssertEqual(workspace.displayedScope, .all)
        workspace.search = ""
        XCTAssertEqual(workspace.displayedScope, .project(project.id))
        workspace.selectScope(.all)
        XCTAssertEqual(workspace.displayedScope, .all)
        XCTAssertEqual(home.transform, homeBefore)
        XCTAssertEqual(inside.transform, insideBefore)
        XCTAssertTrue(workspace.canvasSession(for: .all) === home)
        XCTAssertTrue(workspace.canvasSession(for: .project(project.id)) === inside)
    }

    func testDisplayedScopeAndCaptureDestinationAgreeWithoutChangingMembership() async {
        let project = WorkDeskProjectRecord(title: "Research")
        let shared = WorkboardMaterialSnapshot(kind: .note, name: "Shared")
        let loose = WorkboardMaterialSnapshot(kind: .note, name: "Loose")
        let snapshot = WorkDeskOrganizationSnapshot(projects: [project], materialLocations: [shared.id: [
            WorkDeskLocationRecord(materialID: shared.id, location: .project(project.id)),
            WorkDeskLocationRecord(materialID: shared.id, location: .home)
        ]])
        let organization = WorkDeskOrganization(fetch: { snapshot }, apply: { _ in snapshot })
        await organization.reload()
        let workspace = WorkDeskWorkspaceState(organization: organization)
        workspace.selectScope(.project(project.id))
        XCTAssertEqual(workspace.visibleMaterials(in: [shared, loose], scope: .all).map(\.id), [shared.id, loose.id])
        XCTAssertEqual(workspace.visibleMaterials(in: [shared, loose]).map(\.id), [shared.id])
        XCTAssertEqual(workspace.composerScope, .project(project.id))
        XCTAssertEqual(WorkboardCaptureDestination(workspace: workspace), .project(project.id, title: project.title))
        workspace.search = "Shared"
        XCTAssertEqual(workspace.visibleMaterials(in: [shared, loose]).map(\.id), [shared.id])
        XCTAssertEqual(workspace.composerScope, .all)
    }

    func testProjectSearchFindsOtherProjectsThenReturnsToTheSelectedLocation() async {
        let first = WorkDeskProjectRecord(title: "First")
        let second = WorkDeskProjectRecord(title: "Second")
        let material = WorkboardMaterialSnapshot(kind: .note, name: "Find this")
        let snapshot = WorkDeskOrganizationSnapshot(projects: [first, second], materialLocations: [material.id: [
            WorkDeskLocationRecord(materialID: material.id, location: .project(second.id))
        ]])
        let organization = WorkDeskOrganization(fetch: { snapshot }, apply: { _ in snapshot })
        await organization.reload()
        let workspace = WorkDeskWorkspaceState(organization: organization)
        workspace.selectScope(.project(first.id))
        XCTAssertTrue(workspace.visibleMaterials(in: [material], scope: workspace.displayedScope).isEmpty)
        workspace.search = "Find"
        XCTAssertEqual(workspace.scope, .project(first.id))
        XCTAssertEqual(workspace.displayedScope, .all)
        XCTAssertEqual(workspace.composerScope, workspace.displayedScope)
        XCTAssertEqual(workspace.visibleMaterials(in: [material], scope: workspace.displayedScope).map(\.id), [material.id])
        workspace.selectMaterial(material.id, in: workspace.displayedScope)
        XCTAssertEqual(workspace.search, "Find", "Selecting a result must not navigate away from global search.")
        XCTAssertEqual(workspace.scope, .project(first.id))
        XCTAssertEqual(workspace.selectedIDs, [material.id])
        XCTAssertTrue(workspace.isSelecting)
        workspace.search = ""
        XCTAssertEqual(workspace.displayedScope, .project(first.id))
        XCTAssertTrue(workspace.visibleMaterials(in: [material], scope: workspace.displayedScope).isEmpty)
    }

    func testNavigationCancelsTheOldSelectionDragAndPendingReveal() async {
        let project = WorkDeskProjectRecord(title: "Project")
        let organization = WorkDeskOrganization(fetch: { .init(projects: [project]) }, apply: { _ in .init(projects: [project]) })
        await organization.reload()
        let workspace = WorkDeskWorkspaceState(organization: organization)
        let material = WorkboardMaterialSnapshot(kind: .note, name: "Moving")
        let source = UUID()
        workspace.transferCoordinator.register(.init(id: source, location: .home, title: "Home",
            frame: CGRect(x: 0, y: 0, width: 900, height: 700)))
        workspace.transferCoordinator.update(sourceSurfaceID: source, source: .home,
            leadMaterial: material, origins: [material.id: .init(x: 0, y: 0)],
            pointer: CGPoint(x: 100, y: 100), leadFrame: CGRect(x: 50, y: 50, width: 240, height: 240))
        workspace.toggleSelection(material.id)
        workspace.materialRevealRequest = .init(materialID: material.id)
        workspace.selectedConversationID = UUID()
        workspace.conversationSelectionRequest = .init(projectID: project.id, materialIDs: [material.id])
        XCTAssertTrue(workspace.transferCoordinator.isDragging)
        workspace.selectScope(.project(project.id))
        XCTAssertFalse(workspace.transferCoordinator.isDragging)
        XCTAssertFalse(workspace.isSelecting)
        XCTAssertTrue(workspace.selectedIDs.isEmpty)
        XCTAssertNil(workspace.materialRevealRequest)
        XCTAssertNil(workspace.selectedConversationID)
        XCTAssertNil(workspace.conversationSelectionRequest)
        XCTAssertEqual(workspace.displayedScope, .project(project.id))
    }

}
