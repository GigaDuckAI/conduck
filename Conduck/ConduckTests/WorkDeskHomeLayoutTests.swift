// SPDX-License-Identifier: Apache-2.0

// All materials and projects hold independent arrangements over the same
// captures. Mixed-project moves remain atomic under stale membership and
// layout seeds cannot overwrite a move or adopt a late project assignment.

import XCTest
@testable import Conduck

@MainActor
final class WorkDeskHomeLayoutTests: XCTestCase {
    private let isolated = IsolatedWorkStores()

    override func tearDown() async throws {
        await isolated.cleanUp()
        try await super.tearDown()
    }

    func testGroupingPreservesLegacyHomePositionAndProjectMovesStayIndependent() async throws {
        let store = isolated.make()
        let material = try await capture("Keep this card", in: store)
        let home = WorkDeskPoint(x: 800, y: 600)
        try await store.applyWorkDeskMutation(.moveMaterial(id: material.id, position: home))
        let project = WorkDeskProjectRecord(title: "Focus")
        let grouped = try await store.applyWorkDeskMutation(.createProject(project, materialIDs: [material.id]))
        XCTAssertEqual(grouped.placements[material.id]?.resolvedHomePosition, home)
        XCTAssertNil(grouped.placements[material.id]?.position)
        let local = WorkDeskPoint(x: 40, y: 80)
        try await store.applyWorkDeskMutation(.moveMaterials(positions: [material.id: local], expectedProjectID: project.id))
        let movedHome = WorkDeskPoint(x: 1000, y: 900)
        try await store.applyWorkDeskMutation(.moveHomeMaterials([
            .init(materialID: material.id, projectID: project.id, position: movedHome)
        ]))
        let organization = WorkDeskOrganization(store: store)
        await organization.reload()
        XCTAssertEqual(organization.placements[material.id]?.resolvedHomePosition, movedHome)
        XCTAssertEqual(organization.placements[material.id]?.position, local)
        let workspace = WorkDeskWorkspaceState(organization: organization)
        let visible = WorkboardMaterialSnapshot(id: material.id, kind: .note, name: material.title)
        XCTAssertEqual(workspace.visibleMaterials(in: [visible]).map(\.id), [material.id])
        let deleted = try await store.applyWorkDeskMutation(.deleteProject(id: project.id))
        XCTAssertEqual(deleted.placements[material.id]?.resolvedHomePosition, movedHome)
        XCTAssertNil(deleted.placements[material.id]?.projectID)
        let preserved = try await store.fetchWorkMaterial(id: material.id)
        XCTAssertEqual(preserved, material)
    }

    func testMixedProjectHomeMovePreservesEveryProjectLayoutAndLegacyPins() async throws {
        let store = isolated.make()
        let one = try await capture("One", in: store)
        let two = try await capture("Two", in: store)
        let bytes = Data("Home moves preserve captured payload bytes".utf8)
        let loose = try await store.upsertDeskMaterial(.init(kind: .file, title: "Loose", filename: "note.txt",
            mimeType: "text/plain", payload: bytes))
        let a = WorkDeskProjectRecord(title: "A"), b = WorkDeskProjectRecord(title: "B")
        try await store.applyWorkDeskMutation(.createProject(a, materialIDs: [one.id]))
        try await store.applyWorkDeskMutation(.createProject(b, materialIDs: [two.id]))
        let local = WorkDeskPoint(x: 28, y: 26)
        for id in [one.id, two.id] {
            try await store.applyWorkDeskMutation(.moveMaterial(id: id, position: local))
            try await store.applyWorkDeskMutation(.pinMaterial(id: id, isPinned: true))
        }
        let moves: [WorkDeskPositionSeed] = [
            .init(materialID: one.id, projectID: a.id, position: .init(x: 500, y: 600)),
            .init(materialID: two.id, projectID: b.id, position: .init(x: 800, y: 600)),
            .init(materialID: loose.id, projectID: nil, position: .init(x: 1100, y: 600))
        ]
        let saved = try await store.applyWorkDeskMutation(.moveHomeMaterials(moves))
        for move in moves {
            XCTAssertEqual(saved.placements[move.materialID]?.resolvedHomePosition, move.position)
            XCTAssertEqual(saved.placements[move.materialID]?.projectID, move.projectID)
        }
        for id in [one.id, two.id] {
            XCTAssertEqual(saved.placements[id]?.position, local)
            XCTAssertEqual(saved.placements[id]?.isPinned, true)
        }
        let preservedBytes = try await store.loadWorkMaterialPayload(id: loose.id)
        let preservedFile = try await store.fetchWorkMaterial(id: loose.id)
        XCTAssertEqual(preservedBytes, bytes)
        XCTAssertEqual(preservedFile, loose)
    }

    func testReassignmentRefusesEntireMixedHomeMoveWithoutCreatingAnyPlacement() async throws {
        let store = isolated.make()
        let loose = try await capture("Loose", in: store)
        let filed = try await capture("Filed", in: store)
        let original = WorkDeskProjectRecord(title: "Original"), other = WorkDeskProjectRecord(title: "Other")
        try await store.applyWorkDeskMutation(.createProject(original, materialIDs: [filed.id]))
        try await store.applyWorkDeskMutation(.createProject(other, materialIDs: []))
        let moves: [WorkDeskPositionSeed] = [
            .init(materialID: loose.id, projectID: nil, position: .init(x: 20, y: 40)),
            .init(materialID: filed.id, projectID: original.id, position: .init(x: 400, y: 40))
        ]
        try await store.applyWorkDeskMutation(.assign(materialIDs: [filed.id], projectID: other.id))
        let before = try await store.fetchWorkDeskOrganization()
        do {
            try await store.applyWorkDeskMutation(.moveHomeMaterials(moves))
            XCTFail("Every membership must pass before any placement is inserted")
        } catch { XCTAssertEqual(error as? WorkDeskStoreError, .materialMoved) }
        let after = try await store.fetchWorkDeskOrganization()
        XCTAssertEqual(after, before)
        XCTAssertNil(after.placements[loose.id])
    }

    func testDeletedMaterialRefusesHomeBatchWithoutMovingSurvivor() async throws {
        let store = isolated.make()
        let one = try await capture("One", in: store), two = try await capture("Two", in: store)
        try await store.deleteWorkMaterial(id: two.id)
        let before = try await store.fetchWorkDeskOrganization()
        do {
            try await store.applyWorkDeskMutation(.moveHomeMaterials([
                .init(materialID: one.id, projectID: nil, position: .init(x: 200, y: 300)),
                .init(materialID: two.id, projectID: nil, position: .init(x: 500, y: 300))
            ]))
            XCTFail("A removed group member must refuse the batch")
        } catch { XCTAssertEqual(error as? WorkDeskStoreError, .materialNotFound) }
        let after = try await store.fetchWorkDeskOrganization()
        XCTAssertEqual(after, before)
    }

    func testHomeSeedsIgnoreProjectCoordinatesAndCannotOverwriteOrFollowReassignment() async throws {
        let store = isolated.make()
        let one = try await capture("Moved", in: store), two = try await capture("Reassigned", in: store)
        let unseeded = try await capture("Assigned before its first home seed", in: store)
        let project = WorkDeskProjectRecord(title: "Project")
        try await store.applyWorkDeskMutation(.createProject(project, materialIDs: [one.id]))
        let local = WorkDeskPoint(x: 28, y: 26)
        try await store.applyWorkDeskMutation(.moveMaterial(id: one.id, position: local))
        let seeds: [WorkDeskPositionSeed] = [
            .init(materialID: one.id, projectID: project.id, position: .init(x: 400, y: 500), isHome: true),
            .init(materialID: two.id, projectID: nil, position: .init(x: 700, y: 500), isHome: true)
        ]
        let seeded = try await store.applyWorkDeskMutation(.seedPositions(materials: seeds, projects: [:]))
        XCTAssertEqual(seeded.placements[one.id]?.homePosition, seeds[0].position)
        XCTAssertEqual(seeded.placements[one.id]?.position, local)
        let manual = WorkDeskPoint(x: 1600, y: 1700)
        try await store.applyWorkDeskMutation(.moveHomeMaterials([
            .init(materialID: one.id, projectID: project.id, position: manual)
        ]))
        try await store.applyWorkDeskMutation(.assign(materialIDs: [two.id], projectID: project.id))
        try await store.applyWorkDeskMutation(.assign(materialIDs: [unseeded.id], projectID: project.id))
        let staleSeed = WorkDeskPositionSeed(materialID: unseeded.id, projectID: nil,
            position: .init(x: 1000, y: 500), isHome: true)
        let late = try await store.applyWorkDeskMutation(.seedPositions(materials: seeds + [staleSeed], projects: [:]))
        XCTAssertNil(late.placements[unseeded.id]?.homePosition,
                     "A seed planned before assignment cannot populate the later membership")
        XCTAssertEqual(late.placements[one.id]?.homePosition, manual)
        XCTAssertEqual(late.placements[two.id]?.homePosition, seeds[1].position)
        XCTAssertEqual(late.placements[two.id]?.projectID, project.id)
    }

    func testNewProjectUsesHomeCoordinatesOfAlreadyFiledSelection() async throws {
        let store = isolated.make()
        let one = try await capture("One", in: store), two = try await capture("Two", in: store)
        let project = WorkDeskProjectRecord(title: "Existing")
        try await store.applyWorkDeskMutation(.createProject(project, materialIDs: [one.id, two.id]))
        try await store.applyWorkDeskMutation(.moveHomeMaterials([
            .init(materialID: one.id, projectID: project.id, position: .init(x: 1200, y: 800)),
            .init(materialID: two.id, projectID: project.id, position: .init(x: 1800, y: 1200))
        ]))
        let organization = WorkDeskOrganization(store: store)
        await organization.reload()
        let workspace = WorkDeskWorkspaceState(organization: organization)
        workspace.beginProject(materialIDs: [one.id, two.id])
        XCTAssertEqual(workspace.projectEditor?.position, .init(x: 1500, y: 1000))
    }

    func testSingleCardProjectAndGroupingDropPersistNearbyWithoutCoveringRetainedCards() async throws {
        let store = isolated.make()
        let one = try await capture("One", in: store), two = try await capture("Two", in: store)
        let points = [one.id: WorkDeskPoint(x: 8000, y: 6000), two.id: WorkDeskPoint(x: 8300, y: 6000)]
        try await store.applyWorkDeskMutation(.moveHomeMaterials(points.map {
            .init(materialID: $0.key, projectID: nil, position: $0.value)
        }))
        let organization = WorkDeskOrganization(store: store)
        await organization.reload()
        let workspace = WorkDeskWorkspaceState(organization: organization)
        workspace.beginProject(materialIDs: [one.id])
        XCTAssertEqual(workspace.projectEditor?.position, .init(x: 8000, y: 5812))
        // Dropping a group on the second card requests that card's point.
        workspace.beginProject(materialIDs: [one.id, two.id], position: points[two.id])
        let proposed = try XCTUnwrap(workspace.projectEditor?.position)
        XCTAssertEqual(proposed, .init(x: 8300, y: 5812))
        let newID = await organization.createProject(title: "Together", materialIDs: [one.id, two.id], position: proposed)
        let projectID = try XCTUnwrap(newID)
        let reopened = WorkDeskOrganization(store: store)
        await reopened.reload()
        let saved = try XCTUnwrap(reopened.project(id: projectID)?.position)
        let folderFrame = WorkDeskCanvasGeometry.frame(at: saved,
            bodySize: WorkDeskCanvasGeometry.projectBodySize, scale: 1)
        for (id, original) in points {
            let home = try XCTUnwrap(reopened.placements[id]?.resolvedHomePosition)
            XCTAssertEqual(home, original)
            XCTAssertFalse(folderFrame.intersects(WorkDeskCanvasGeometry.frame(at: home,
                bodySize: WorkDeskCanvasGeometry.cardBodySize, scale: 1)))
        }
    }

    func testLegacyProjectPinDoesNotAffectNavigationOrder() async throws {
        let store = isolated.make()
        let first = WorkDeskProjectRecord(title: "First", createdAt: .distantPast)
        let second = WorkDeskProjectRecord(title: "Second", isPinned: true)
        try await store.applyWorkDeskMutation(.createProject(first, materialIDs: []))
        let saved = try await store.applyWorkDeskMutation(.createProject(second, materialIDs: []))
        XCTAssertEqual(saved.projects.map(\.id), [first.id, second.id])
        XCTAssertEqual(saved.projects.last?.isPinned, true)
    }

    private func capture(_ text: String, in store: ConversationStore) async throws -> WorkMaterialRecord {
        try await store.upsertDeskMaterial(.init(kind: .note, title: text, textContent: text))
    }
}
