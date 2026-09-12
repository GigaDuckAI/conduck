// SPDX-License-Identifier: Apache-2.0

// Project creation keeps the place where the action began, including a moved
// camera and selected cards. Global search recovers filed materials without
// changing the underlying scope; project counts follow the same membership.

import XCTest
@testable import Conduck

@MainActor
final class WorkDeskCreationSearchTests: XCTestCase {
    private let isolated = IsolatedWorkStores()

    override func tearDown() async throws {
        await isolated.cleanUp()
        try await super.tearDown()
    }

    func testSearchFindsFiledAndUnpinnedMaterialsFromEveryScope() async {
        let loose = material("Travel note"), filed = material("Travel plan"), other = material("Unrelated")
        let project = WorkDeskProjectRecord(title: "Holiday")
        let workspace = await makeWorkspace(.init(projects: [project], placements: [
            filed.id: .init(materialID: filed.id, projectID: project.id)
        ]))
        let scopes: [WorkDeskScope] = [.all, .project(project.id)]
        for scope in scopes {
            workspace.selectScope(scope)
            workspace.search = "  TRAVEL\n"
            XCTAssertEqual(workspace.visibleMaterials(in: [loose, filed, other]).map(\.id), [loose.id, filed.id])
            XCTAssertEqual(workspace.scope, scope, "a search must not replace the scope it will return to")
        }
    }

    func testProjectNameSearchFindsItsMaterialsWithoutMatchingTheirText() async {
        let member = material("Questions"), loose = material("Thought")
        let project = WorkDeskProjectRecord(title: "Packaging research")
        let workspace = await makeWorkspace(.init(projects: [project], placements: [
            member.id: .init(materialID: member.id, projectID: project.id)
        ]))
        workspace.search = "  packaging "
        XCTAssertEqual(workspace.visibleMaterials(in: [loose, member]).map(\.id), [member.id])
        XCTAssertEqual(workspace.organization.projectID(for: member.id), project.id)
        XCTAssertEqual(workspace.scope, .all)
    }

    func testClearingGlobalSearchRestoresProjectOrAllScope() async {
        let member = material("Related"), pinned = material("Pinned"), loose = material("Loose")
        let project = WorkDeskProjectRecord(title: "Project")
        let workspace = await makeWorkspace(.init(projects: [project], placements: [
            member.id: .init(materialID: member.id, projectID: project.id),
            pinned.id: .init(materialID: pinned.id, isPinned: true)
        ]))
        workspace.selectScope(.project(project.id))
        workspace.search = "Loose"
        XCTAssertEqual(workspace.visibleMaterials(in: [loose, member, pinned]).map(\.id), [loose.id])
        workspace.search = " \n "
        XCTAssertEqual(workspace.visibleMaterials(in: [loose, member, pinned]).map(\.id), [member.id])
        workspace.selectScope(.all)
        workspace.search = "Related"
        XCTAssertEqual(workspace.visibleMaterials(in: [loose, member, pinned]).map(\.id), [member.id])
        workspace.search = ""
        XCTAssertEqual(workspace.visibleMaterials(in: [loose, member, pinned]).map(\.id), [loose.id, member.id, pinned.id])
    }

    func testCountsIncludeLooseAndOrphanedCardsAndOnlyDisplayedCompanionGroups() async {
        let loose = material("Loose"), orphan = material("Orphan"), filed = material("Filed")
        var photo = WorkboardMaterialSnapshot(kind: .image, name: "Photo")
        photo.companion = WorkboardCompanionSnapshot(material("Voice words"))
        let project = WorkDeskProjectRecord(title: "Project")
        let emptyProject = WorkDeskProjectRecord(title: "Empty")
        let workspace = await makeWorkspace(.init(projects: [project, emptyProject], placements: [
            orphan.id: .init(materialID: orphan.id, projectID: UUID()),
            filed.id: .init(materialID: filed.id, projectID: project.id),
            photo.id: .init(materialID: photo.id, projectID: project.id)
        ]))
        let counts = workspace.organization.materialCounts(in: [loose, orphan, filed, photo])
        XCTAssertEqual(counts[nil], 2)
        XCTAssertEqual(counts[project.id], 2)
        XCTAssertNil(counts[emptyProject.id])
        XCTAssertEqual(counts.values.reduce(0, +), 4)
    }

    func testClearingGlobalSearchRemovesForeignSelectionBeforeCreatingProject() async {
        let local = material("Local"), foreign = material("Find me")
        let project = WorkDeskProjectRecord(title: "Other project")
        let localProject = WorkDeskProjectRecord(title: "Local project")
        let workspace = await makeWorkspace(.init(projects: [project, localProject], placements: [
            local.id: .init(materialID: local.id, projectID: localProject.id),
            foreign.id: .init(materialID: foreign.id, projectID: project.id)
        ]))
        workspace.selectScope(.project(localProject.id))
        workspace.search = "Find me"
        XCTAssertEqual(workspace.visibleMaterials(in: [local, foreign]).map(\.id), [foreign.id])
        workspace.toggleSelection(foreign.id)
        workspace.search = ""
        workspace.reconcile(materials: [local, foreign])
        XCTAssertTrue(workspace.selectedIDs.isEmpty)
        workspace.beginProject(materialIDs: Array(workspace.selectedIDs))
        XCTAssertEqual(workspace.projectEditor?.materialIDs, [])
        XCTAssertEqual(workspace.organization.projectID(for: foreign.id), project.id)
    }

    func testAssignSelectionFiltersForeignSearchResultsBeforeReconciliation() async {
        let local = material("Shared local"), foreign = material("Shared foreign")
        let source = WorkDeskProjectRecord(title: "Other project")
        let destination = WorkDeskProjectRecord(title: "Destination")
        let snapshot = WorkDeskOrganizationSnapshot(projects: [source, destination], placements: [
            local.id: .init(materialID: local.id, projectID: destination.id),
            foreign.id: .init(materialID: foreign.id, projectID: source.id)
        ])
        let recorder = AssignmentRecorder()
        let organization = WorkDeskOrganization(fetch: { snapshot }, apply: { mutation in
            await recorder.record(mutation)
            return snapshot
        })
        await organization.reload()
        let workspace = WorkDeskWorkspaceState(organization: organization)
        workspace.selectScope(.project(destination.id))
        workspace.search = "Shared"
        workspace.toggleSelection(local.id)
        workspace.toggleSelection(foreign.id)
        workspace.search = ""
        // No reconcile call: the action itself must exclude the hidden result.
        await workspace.assignSelection(to: destination.id, materials: [local, foreign])
        let assignments = await recorder.assignments
        XCTAssertEqual(assignments, [[local.id]])
        XCTAssertTrue(workspace.selectedIDs.isEmpty)
    }

    func testForeignOnlySelectionCannotMoveAfterSearchClearsWithoutReconciliation() async {
        let foreign = material("Find me")
        let project = WorkDeskProjectRecord(title: "Other project")
        let localProject = WorkDeskProjectRecord(title: "Local project")
        let snapshot = WorkDeskOrganizationSnapshot(projects: [project, localProject], placements: [
            foreign.id: .init(materialID: foreign.id, projectID: project.id)
        ])
        let recorder = AssignmentRecorder()
        let organization = WorkDeskOrganization(fetch: { snapshot }, apply: { mutation in
            await recorder.record(mutation)
            return snapshot
        })
        await organization.reload()
        let workspace = WorkDeskWorkspaceState(organization: organization)
        workspace.selectScope(.project(localProject.id))
        workspace.search = "Find me"
        workspace.toggleSelection(foreign.id)
        workspace.search = ""
        await workspace.assignSelection(to: nil, materials: [foreign])
        let assignments = await recorder.assignments
        XCTAssertTrue(assignments.isEmpty, "clearing search cannot silently remove a hidden card from its project")
        XCTAssertEqual(organization.projectID(for: foreign.id), project.id)
    }

    func testMembershipIndexTracksProjectDeletionAndRename() async {
        let member = material("Member")
        let project = WorkDeskProjectRecord(title: "Original")
        var renamed = project
        renamed.title = "Renamed"
        let placements = [member.id: WorkDeskPlacementRecord(materialID: member.id, projectID: project.id)]
        let snapshots = SnapshotSequence([
            .init(projects: [project], placements: placements),
            .init(projects: [renamed], placements: placements),
            .init(projects: [], placements: placements)
        ])
        let organization = WorkDeskOrganization(fetch: { await snapshots.next() }, apply: { _ in .init() })
        await organization.reload()
        XCTAssertEqual(organization.projectID(for: member.id), project.id)
        await organization.reload()
        XCTAssertEqual(organization.project(id: project.id)?.title, "Renamed")
        await organization.reload()
        XCTAssertNil(organization.projectID(for: member.id))
        XCTAssertNil(organization.project(id: project.id))
        XCTAssertEqual(organization.materialCounts(in: [member])[nil], 1)
    }

    func testSelectionCreatesProjectWhereItsDeskCardsWereArranged() async {
        let one = UUID(), two = UUID()
        let workspace = await makeWorkspace(.init(placements: [
            one: .init(materialID: one, position: .init(x: 1200, y: 900)),
            two: .init(materialID: two, position: .init(x: 1500, y: 1100))
        ]))
        workspace.beginProject(materialIDs: [one, two, one])
        XCTAssertEqual(workspace.projectEditor?.position, WorkDeskPoint(x: 1350, y: 712))
    }

    func testExplicitCreationPointWinsOverSelectionAndCamera() async {
        let id = UUID()
        let workspace = await makeWorkspace(.init(placements: [
            id: .init(materialID: id, position: .init(x: 100, y: 100))
        ]))
        let point = WorkDeskPoint(x: 1400, y: 2200)
        workspace.beginProject(materialIDs: [id], position: point)
        XCTAssertEqual(workspace.projectEditor?.position, point)
    }

    func testToolbarCreationUsesTheVisibleDeskAndFreezesItBeforeEditing() async throws {
        let workspace = await makeWorkspace(.init())
        let session = workspace.canvasSession(for: .all)
        session.receiveViewport(CGSize(width: 900, height: 700), owner: UUID(), isActive: true)
        session.transform = .init(scale: 0.75, offset: CGSize(width: -1600, height: -800))
        let insertion = try XCTUnwrap(session.projectInsertionPoint)
        workspace.beginProject()
        XCTAssertEqual(workspace.projectEditor?.position, insertion)
        session.transform = .init()
        XCTAssertEqual(workspace.projectEditor?.position, insertion, "the editor must retain the original camera position")
    }

    func testUnopenedDeskCreationAvoidsSavedCardsAndDoesNotUseProjectLocalCoordinates() async {
        let child = UUID(), loose = UUID()
        let project = WorkDeskProjectRecord(title: "Existing", position: .init(x: 292, y: 26))
        let workspace = await makeWorkspace(.init(projects: [project], placements: [
            loose: .init(materialID: loose, position: .init(x: 28, y: 26)),
            child: .init(materialID: child, projectID: project.id, position: .init(x: 9000, y: 9000))
        ]))
        workspace.selectScope(.project(project.id))
        workspace.beginProject(materialIDs: [child])
        XCTAssertEqual(workspace.projectEditor?.position, WorkDeskPoint(x: 556, y: 26))
    }

    func testCreationSpotRoundTripsAndLateLayoutSeedCannotRelocateIt() async throws {
        let store = isolated.make()
        let organization = WorkDeskOrganization(store: store)
        let point = WorkDeskPoint(x: 1400, y: 2300)
        let createdID = await organization.createProject(title: "Here", position: point)
        let id = try XCTUnwrap(createdID)
        let saved = try await store.applyWorkDeskMutation(.seedPositions(
            materials: [], projects: [id: .init(x: 28, y: 26)]
        ))
        XCTAssertEqual(saved.projects.first?.position, point)
        let reopened = WorkDeskOrganization(store: store)
        await reopened.reload()
        XCTAssertEqual(reopened.project(id: id)?.position, point)
    }

    private func makeWorkspace(_ snapshot: WorkDeskOrganizationSnapshot) async -> WorkDeskWorkspaceState {
        let organization = WorkDeskOrganization(fetch: { snapshot }, apply: { _ in snapshot })
        await organization.reload()
        return WorkDeskWorkspaceState(organization: organization)
    }

    private func material(_ name: String) -> WorkboardMaterialSnapshot {
        .init(kind: .note, name: name)
    }

    private actor SnapshotSequence {
        var snapshots: [WorkDeskOrganizationSnapshot]
        init(_ snapshots: [WorkDeskOrganizationSnapshot]) { self.snapshots = snapshots }
        func next() -> WorkDeskOrganizationSnapshot { snapshots.removeFirst() }
    }

    private actor AssignmentRecorder {
        var assignments: [[UUID]] = []
        func record(_ mutation: WorkDeskMutation) {
            if case .assign(let ids, _) = mutation { assignments.append(ids) }
        }
    }
}
