// SPDX-License-Identifier: Apache-2.0

// Folder color is durable organization metadata. These real isolated-store
// cases cover independent edits, stale color menus, reviewed deletion and
// controller failure publication; they do not claim live iCloud delivery.

import XCTest
import CoreData
@testable import Conduck

final class WorkDeskProjectColorTests: XCTestCase {
    private let isolated = IsolatedWorkStores()

    override func tearDown() async throws {
        await isolated.cleanUp()
        try await super.tearDown()
    }

    func testDefaultAndUnknownStoredColorsRemainReadable() {
        XCTAssertEqual(WorkDeskProjectRecord(title: "Existing").color, .amber)
        XCTAssertEqual(WorkDeskProjectColor(storedID: nil), .amber)
        XCTAssertEqual(WorkDeskProjectColor(storedID: "future-color"), .amber)
        for color in WorkDeskProjectColor.allCases {
            XCTAssertEqual(WorkDeskProjectColor(storedID: color.rawValue), color)
        }
    }

    @MainActor
    func testNewProjectsUseUnusedColorsThenReuseLeastUsedWithoutChangingExistingChoices() async throws {
        let store = isolated.make()
        let explicit = WorkDeskProjectRecord(title: "Chosen", color: .sage)
        _ = try await store.applyWorkDeskMutation(.createProject(explicit, materialIDs: []))
        let organization = WorkDeskOrganization(store: store)
        await organization.reload()
        for index in 0..<5 {
            let id = await organization.createProject(title: "Automatic \(index)")
            XCTAssertNotNil(id)
        }
        XCTAssertEqual(Set(organization.projects.map(\.color)), Set(WorkDeskProjectColor.allCases))
        let colorsBefore = Dictionary(uniqueKeysWithValues: organization.projects.map { ($0.id, $0.color) })
        let createdID = await organization.createProject(title: "Next cycle")
        let extraID = try XCTUnwrap(createdID)
        XCTAssertEqual(organization.project(id: extraID)?.color, .amber)
        for (id, color) in colorsBefore { XCTAssertEqual(organization.project(id: id)?.color, color) }
        let reloaded = try await store.fetchWorkDeskOrganization()
        XCTAssertEqual(reloaded.projects, organization.projects)
    }

    func testEveryColorRoundTripsAndUnrelatedEditsPreserveColorAndCapture() async throws {
        let store = isolated.make()
        let material = try await store.upsertDeskMaterial(.init(kind: .note, title: "Original", textContent: "Private words"))
        for color in WorkDeskProjectColor.allCases {
            let project = WorkDeskProjectRecord(title: "Project", brief: "Context", preferredGatewayRef: "hermes", color: color)
            _ = try await store.applyWorkDeskMutation(.createProject(project, materialIDs: []))
            _ = try await store.applyWorkDeskMutation(.updateProject(id: project.id, title: "Renamed", brief: "Updated context",
                preferredGatewayRef: "openrouter"))
            _ = try await store.applyWorkDeskMutation(.moveProject(id: project.id, position: .init(x: 800, y: 400)))
            _ = try await store.applyWorkDeskMutation(.pinProject(id: project.id, isPinned: true))
            _ = try await store.applyWorkDeskMutation(.assign(materialIDs: [material.id], projectID: project.id))
            let snapshot = try await store.fetchWorkDeskOrganization()
            let saved = try XCTUnwrap(snapshot.projects.first { $0.id == project.id })
            XCTAssertEqual(saved.color, color)
            XCTAssertEqual(saved.title, "Renamed")
            XCTAssertEqual(saved.brief, "Updated context")
            XCTAssertEqual(saved.preferredGatewayRef, "openrouter")
            XCTAssertEqual(saved.position, .init(x: 800, y: 400))
            XCTAssertTrue(saved.isPinned)
        }
        let unchanged = try await store.fetchWorkMaterial(id: material.id)
        XCTAssertEqual(unchanged, material)
    }

    func testColorEditChangesOnlyColorAndRevisionAndRepeatingItIsNotAWrite() async throws {
        let store = isolated.make()
        let project = WorkDeskProjectRecord(title: "Research", brief: "Standing context", preferredGatewayRef: "hermes",
            position: .init(x: 120, y: 240), isPinned: true)
        let created = try await store.applyWorkDeskMutation(.createProject(project, materialIDs: []))
        let before = try XCTUnwrap(created.projects.first)
        let updated = try await store.applyWorkDeskMutation(.setProjectColor(id: project.id, color: .sage,
            expectedUpdatedAt: before.updatedAt))
        let after = try XCTUnwrap(updated.projects.first)
        var expected = before
        expected.color = .sage
        expected.updatedAt = after.updatedAt
        XCTAssertEqual(after, expected)
        XCTAssertGreaterThan(after.updatedAt, before.updatedAt)
        let repeated = try await store.applyWorkDeskMutation(.setProjectColor(id: project.id, color: .sage,
            expectedUpdatedAt: after.updatedAt))
        let repeatedProject = try XCTUnwrap(repeated.projects.first)
        XCTAssertEqual(repeatedProject.updatedAt.timeIntervalSinceReferenceDate, after.updatedAt.timeIntervalSinceReferenceDate,
            "Choosing the current color must preserve the exact revision token")
        XCTAssertEqual(repeated, updated)
    }

    func testStaleColorAndTextEditorsCannotOverwriteCommittedProjectRevision() async throws {
        let store = isolated.make()
        let project = WorkDeskProjectRecord(title: "Research")
        let created = try await store.applyWorkDeskMutation(.createProject(project, materialIDs: []))
        let before = try XCTUnwrap(created.projects.first)
        let updated = try await store.applyWorkDeskMutation(.setProjectColor(id: project.id, color: .blue,
            expectedUpdatedAt: before.updatedAt))
        let staleMutations: [WorkDeskMutation] = [
            .setProjectColor(id: project.id, color: .coral, expectedUpdatedAt: before.updatedAt),
            .updateProject(id: project.id, title: "Stale rename", brief: "", preferredGatewayRef: nil,
                expectedUpdatedAt: before.updatedAt)
        ]
        for mutation in staleMutations {
            do {
                _ = try await store.applyWorkDeskMutation(mutation)
                XCTFail("A stale editor must not silently replace a newer project revision")
            } catch { XCTAssertEqual(error as? WorkDeskStoreError, .staleProject) }
        }
        let unchanged = try await store.fetchWorkDeskOrganization()
        XCTAssertEqual(unchanged, updated)
    }

    func testColorChangeInvalidatesReviewedDeletionAndDeletedProjectRejectsColor() async throws {
        let store = isolated.make()
        let project = WorkDeskProjectRecord(title: "Research", color: .lavender)
        _ = try await store.applyWorkDeskMutation(.createProject(project, materialIDs: []))
        let review = try await store.reviewWorkDeskProjectDeletion(id: project.id)
        _ = try await store.applyWorkDeskMutation(.setProjectColor(id: project.id, color: .slate))
        do {
            _ = try await store.applyWorkDeskMutation(.deleteReviewedProject(review, deleteMaterials: false))
            XCTFail("Reviewed deletion must notice a changed project")
        } catch { XCTAssertEqual(error as? WorkDeskStoreError, .staleProjectDeletion) }
        _ = try await store.applyWorkDeskMutation(.deleteProject(id: project.id))
        for id in [project.id, UUID()] {
            do {
                _ = try await store.applyWorkDeskMutation(.setProjectColor(id: id, color: .coral))
                XCTFail("A color menu cannot recreate a missing or deleted project")
            } catch { XCTAssertEqual(error as? WorkDeskStoreError, .projectNotFound) }
        }
        let context = await store.newReadContext()
        try await context.perform {
            let request = NSFetchRequest<NSManagedObject>(entityName: "WorkDeskProject")
            request.predicate = NSPredicate(format: "id == %@", project.id as CVarArg)
            let tombstone = try XCTUnwrap(context.fetch(request).first)
            XCTAssertNotNil(tombstone.value(forKey: "deletedAt"))
            XCTAssertNil(tombstone.value(forKey: "colorID"))
        }
    }

    @MainActor
    func testControllerPublishesOnlyCommittedColorAndReportsStaleSelection() async throws {
        let store = isolated.make()
        let project = WorkDeskProjectRecord(title: "Research")
        _ = try await store.applyWorkDeskMutation(.createProject(project, materialIDs: []))
        let organization = WorkDeskOrganization(store: store)
        await organization.reload()
        let before = try XCTUnwrap(organization.project(id: project.id))
        let saved = await organization.setProjectColor(id: project.id, color: .sage, expectedUpdatedAt: before.updatedAt)
        XCTAssertTrue(saved)
        XCTAssertEqual(organization.project(id: project.id)?.color, .sage)
        let stale = await organization.setProjectColor(id: project.id, color: .blue, expectedUpdatedAt: before.updatedAt)
        XCTAssertFalse(stale)
        XCTAssertEqual(organization.project(id: project.id)?.color, .sage)
        XCTAssertNotNil(organization.errorMessage)
        XCTAssertFalse(organization.isSaving)
    }
}
