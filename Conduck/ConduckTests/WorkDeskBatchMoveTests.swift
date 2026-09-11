// SPDX-License-Identifier: Apache-2.0

// A selected group is one spatial move, even when membership changes between
// pointer-down and persistence. These isolated-store tests require complete
// validation before any member moves, and keep captured bytes and pin state
// independent of the group's position. Raw rows model partial iCloud arrival.

import XCTest
import CoreData
@testable import Conduck

final class WorkDeskBatchMoveTests: XCTestCase {
    private let isolated = IsolatedWorkStores()

    override func tearDown() async throws {
        await isolated.cleanUp()
        try await super.tearDown()
    }

    func testSameProjectBatchPersistsBothBoundedPositions() async throws {
        let store = isolated.make()
        let one = try await capture("First", in: store)
        let two = try await capture("Second", in: store)
        let project = WorkDeskProjectRecord(title: "Together")
        try await store.applyWorkDeskMutation(.createProject(project, materialIDs: [one.id, two.id]))
        let positions = [
            one.id: WorkDeskPoint(x: -40, y: 900),
            two.id: WorkDeskPoint(x: 800, y: .greatestFiniteMagnitude)
        ]

        try await store.applyWorkDeskMutation(.moveMaterials(positions: positions, expectedProjectID: project.id))

        let saved = try await store.fetchWorkDeskOrganization()
        XCTAssertEqual(saved.placements[one.id]?.position, WorkDeskPoint(x: -40, y: 900))
        XCTAssertEqual(saved.placements[two.id]?.position, WorkDeskPoint(x: 800, y: WorkDeskPoint.coordinateLimit))
        XCTAssertEqual(saved.placements[one.id]?.projectID, project.id)
        XCTAssertEqual(saved.placements[two.id]?.projectID, project.id)
    }

    func testDeletedMemberRefusesTheWholeBatchWithoutMovingItsSurvivor() async throws {
        let store = isolated.make()
        let one = try await capture("Survivor", in: store)
        let two = try await capture("Removed while dragging", in: store)
        try await store.applyWorkDeskMutation(.moveMaterial(id: one.id, position: .init(x: 40, y: 80)))
        try await store.deleteWorkMaterial(id: two.id)
        let before = try await store.fetchWorkDeskOrganization()

        await assertRefused(.moveMaterials(positions: [one.id: .init(x: 500, y: 600), two.id: .init(x: 700, y: 800)],
                                          expectedProjectID: nil), with: .materialNotFound, in: store)

        let after = try await store.fetchWorkDeskOrganization()
        XCTAssertEqual(after, before)
    }

    func testMemberReassignedBeforeApplyRefusesEveryPosition() async throws {
        let store = isolated.make()
        let one = try await capture("Stays", in: store)
        let two = try await capture("Moves elsewhere", in: store)
        let original = WorkDeskProjectRecord(title: "Original")
        let destination = WorkDeskProjectRecord(title: "Elsewhere")
        try await store.applyWorkDeskMutation(.createProject(original, materialIDs: [one.id, two.id]))
        try await store.applyWorkDeskMutation(.createProject(destination, materialIDs: []))
        try await store.applyWorkDeskMutation(.moveMaterial(id: one.id, position: .init(x: 30, y: 60)))
        try await store.applyWorkDeskMutation(.assign(materialIDs: [two.id], projectID: destination.id))
        let before = try await store.fetchWorkDeskOrganization()

        await assertRefused(.moveMaterials(positions: [one.id: .init(x: 300, y: 400), two.id: .init(x: 600, y: 700)],
                                          expectedProjectID: original.id), with: .materialMoved, in: store)

        let after = try await store.fetchWorkDeskOrganization()
        XCTAssertEqual(after, before)
        XCTAssertEqual(after.placements[two.id]?.projectID, destination.id)
    }

    func testDeskBatchCannotSilentlyUngroupALiveProjectMember() async throws {
        let store = isolated.make()
        let one = try await capture("Unfiled", in: store)
        let two = try await capture("Grouped", in: store)
        let project = WorkDeskProjectRecord(title: "Existing project")
        try await store.applyWorkDeskMutation(.createProject(project, materialIDs: [two.id]))
        let before = try await store.fetchWorkDeskOrganization()

        await assertRefused(.moveMaterials(positions: [one.id: .init(x: 10, y: 20), two.id: .init(x: 30, y: 40)],
                                          expectedProjectID: nil), with: .materialMoved, in: store)

        let after = try await store.fetchWorkDeskOrganization()
        XCTAssertEqual(after, before, "No placement may be created for the unfiled member of a refused batch.")
    }

    func testADeletedExpectedProjectCannotAcceptAnOldDrag() async throws {
        let store = isolated.make()
        let material = try await capture("Kept after ungrouping", in: store)
        let project = WorkDeskProjectRecord(title: "Former project")
        try await store.applyWorkDeskMutation(.createProject(project, materialIDs: [material.id]))
        try await store.applyWorkDeskMutation(.deleteProject(id: project.id))
        let before = try await store.fetchWorkDeskOrganization()

        await assertRefused(.moveMaterials(positions: [material.id: .init(x: 300, y: 400)],
                                          expectedProjectID: project.id), with: .projectNotFound, in: store)

        let after = try await store.fetchWorkDeskOrganization()
        XCTAssertEqual(after, before)
    }

    func testBatchPreservesPinPayloadAndCaptureRecords() async throws {
        let store = isolated.make()
        let bytes = Data("These captured bytes must never change during arrangement.".utf8)
        let file = try await store.upsertDeskMaterial(WorkMaterialDraft(
            kind: .file, title: "Notes", filename: "notes.txt", mimeType: "text/plain", payload: bytes
        ))
        let note = try await capture("Related thought", in: store)
        let project = WorkDeskProjectRecord(title: "A brief", brief: "Keep this saved instruction")
        try await store.applyWorkDeskMutation(.createProject(project, materialIDs: [file.id, note.id]))
        try await store.applyWorkDeskMutation(.pinMaterial(id: file.id, isPinned: true))
        let before = try await store.fetchWorkDeskOrganization()

        try await store.applyWorkDeskMutation(.moveMaterials(
            positions: [file.id: .init(x: 80, y: 160), note.id: .init(x: 380, y: 160)], expectedProjectID: project.id
        ))

        let saved = try await store.fetchWorkDeskOrganization()
        XCTAssertEqual(saved.projects, before.projects)
        XCTAssertEqual(saved.placements[file.id]?.isPinned, true)
        XCTAssertEqual(saved.placements[note.id]?.isPinned, false)
        XCTAssertEqual(saved.placements[file.id]?.projectID, project.id)
        XCTAssertEqual(saved.placements[note.id]?.projectID, project.id)
        let preservedFile = try await store.fetchWorkMaterial(id: file.id)
        let preservedNote = try await store.fetchWorkMaterial(id: note.id)
        let preservedBytes = try await store.loadWorkMaterialPayload(id: file.id)
        XCTAssertEqual(preservedFile, file)
        XCTAssertEqual(preservedNote, note)
        XCTAssertEqual(preservedBytes, bytes)
    }

    func testForeignOwnerRefusesTheWholeBatch() async throws {
        let store = isolated.make()
        let one = try await capture("Desk material", in: store)
        let foreign = try await capture("Foreign material", in: store)
        let context = await store.newWriteContext()
        try await context.perform {
            let request = NSFetchRequest<NSManagedObject>(entityName: "WorkMaterial")
            request.predicate = NSPredicate(format: "id == %@", foreign.id as CVarArg)
            let row = try XCTUnwrap(context.fetch(request).first)
            row.setValue(UUID(), forKey: "workItemID")
            try context.save()
        }
        let before = try await store.fetchWorkDeskOrganization()

        await assertRefused(.moveMaterials(positions: [one.id: .init(x: 10, y: 20), foreign.id: .init(x: 30, y: 40)],
                                          expectedProjectID: nil), with: .materialNotFound, in: store)

        let after = try await store.fetchWorkDeskOrganization()
        XCTAssertEqual(after, before)
    }

    func testUnfiledMoveAdoptsMissingDeletedAndPartiallyArrivedProjects() async throws {
        let store = isolated.make()
        var positions: [UUID: WorkDeskPoint] = [:]
        for state in ["missing", "deleted", "untitled"] {
            let material = try await capture(state, in: store)
            positions[material.id] = .init(x: 120, y: 240)
            let projectID = UUID()
            let context = await store.newWriteContext()
            try await context.perform {
                if state != "missing" {
                    let row = NSEntityDescription.insertNewObject(forEntityName: "WorkDeskProject", into: context)
                    row.setValue(projectID, forKey: "id")
                    if state == "deleted" {
                        row.setValue("Deleted project", forKey: "title")
                        row.setValue(Date(), forKey: "deletedAt")
                    }
                }
                let placement = NSEntityDescription.insertNewObject(forEntityName: "WorkDeskPlacement", into: context)
                placement.setValue(material.id, forKey: "materialID")
                placement.setValue(projectID, forKey: "projectID")
                placement.setValue(600, forKey: "positionX")
                placement.setValue(900, forKey: "positionY")
                placement.setValue(true, forKey: "isPinned")
                try context.save()
            }
        }

        try await store.applyWorkDeskMutation(.moveMaterials(positions: positions, expectedProjectID: nil))

        let saved = try await store.fetchWorkDeskOrganization()
        for (id, position) in positions {
            XCTAssertEqual(saved.placements[id]?.position, position)
            XCTAssertNil(saved.placements[id]?.projectID)
            XCTAssertEqual(saved.placements[id]?.isPinned, true)
        }
        let context = await store.newReadContext()
        let storedProjectIDs = try await context.perform {
            try context.fetch(NSFetchRequest<NSManagedObject>(entityName: "WorkDeskPlacement"))
                .compactMap { $0.value(forKey: "projectID") as? UUID }
        }
        XCTAssertTrue(storedProjectIDs.isEmpty, "Adoption clears unresolved membership in storage, not just presentation.")
    }

    @MainActor
    func testOrganizationPublishesOneCompleteBatchAndTreatsEmptyAsNoOp() async throws {
        let store = isolated.make()
        let one = try await capture("First", in: store)
        let two = try await capture("Second", in: store)
        let organization = WorkDeskOrganization(store: store)
        let positions = [one.id: WorkDeskPoint(x: 20, y: 40), two.id: WorkDeskPoint(x: 220, y: 40)]
        let moved = await organization.moveMaterials(positions: positions, expectedProjectID: nil)
        XCTAssertTrue(moved)
        for (id, position) in positions { XCTAssertEqual(organization.placements[id]?.position, position) }
        let before = try await store.fetchWorkDeskOrganization()
        let empty = await organization.moveMaterials(positions: [:], expectedProjectID: UUID())
        XCTAssertTrue(empty, "An empty movement must not even validate an unrelated project.")
        let after = try await store.applyWorkDeskMutation(.moveMaterials(positions: [:], expectedProjectID: UUID()))
        XCTAssertEqual(after, before)
        XCTAssertFalse(organization.isSaving)
        XCTAssertNil(organization.errorMessage)
    }

    private func capture(_ text: String, in store: ConversationStore) async throws -> WorkMaterialRecord {
        try await store.upsertDeskMaterial(WorkMaterialDraft(kind: .note, title: text, textContent: text))
    }

    private func assertRefused(
        _ mutation: WorkDeskMutation, with expected: WorkDeskStoreError, in store: ConversationStore,
        file: StaticString = #filePath, line: UInt = #line
    ) async {
        do {
            try await store.applyWorkDeskMutation(mutation)
            XCTFail("The whole spatial batch must be refused.", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? WorkDeskStoreError, expected, file: file, line: line)
        }
    }
}
