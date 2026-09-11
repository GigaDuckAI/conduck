// SPDX-License-Identifier: Apache-2.0

// A capture's destination belongs to its first publication. These store cases
// protect the atomic material/placement save and prove a stale replay cannot
// undo a person's later filing, even when its original project is gone.

import XCTest
@testable import Conduck

final class ConversationStoreContextualPlacementTests: XCTestCase {
    private let isolated = IsolatedWorkStores()

    override func tearDown() async throws {
        await isolated.cleanUp()
        try await super.tearDown()
    }

    func testNewCapturePublishesMaterialAndProjectPlacementTogether() async throws {
        let store = isolated.make()
        let project = WorkDeskProjectRecord(title: "Research")
        _ = try await store.applyWorkDeskMutation(.createProject(project, materialIDs: []))
        let draft = WorkMaterialDraft(kind: .note, title: "Idea", textContent: "Keep this")

        let material = try await store.upsertDeskMaterial(draft, projectID: project.id)
        let organization = try await store.fetchWorkDeskOrganization()
        let desk = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)

        XCTAssertEqual(material.workItemID, Constants.workboardDeskItemID)
        XCTAssertEqual(desk?.materials.map(\.id), [draft.id])
        XCTAssertEqual(organization.placements[draft.id]?.projectID, project.id)
    }

    func testMissingDestinationRefusesInsertionAndAllowsExplicitUnfiledRecovery() async throws {
        let store = isolated.make()
        let draft = WorkMaterialDraft(kind: .transcript, title: "Voice note", textContent: "Keep my words")

        do {
            _ = try await store.upsertDeskMaterial(draft, projectID: UUID())
            XCTFail("a missing destination must produce an explicit recovery outcome")
        } catch WorkDeskStoreError.projectNotFound {
            // The caller still owns this exact draft and can publish it unfiled.
        }
        let refused = try await store.fetchWorkMaterial(id: draft.id)
        let desk = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        let organization = try await store.fetchWorkDeskOrganization()
        XCTAssertNil(refused)
        XCTAssertNil(desk, "the failed first capture does not publish its owner either")
        XCTAssertNil(organization.placements[draft.id])

        let recovered = try await store.upsertDeskMaterial(draft)
        let recoveredOrganization = try await store.fetchWorkDeskOrganization()
        XCTAssertEqual(recovered.textContent, draft.textContent)
        XCTAssertNil(recoveredOrganization.placements[draft.id]?.projectID)
    }

    func testRetryPreservesLaterFilingEvenWhenOriginalDestinationIsDeleted() async throws {
        let store = isolated.make()
        let original = WorkDeskProjectRecord(title: "Original")
        let later = WorkDeskProjectRecord(title: "Later")
        _ = try await store.applyWorkDeskMutation(.createProject(original, materialIDs: []))
        _ = try await store.applyWorkDeskMutation(.createProject(later, materialIDs: []))
        let draft = WorkMaterialDraft(kind: .transcript, title: "Voice note", textContent: "Remember this")
        _ = try await store.upsertDeskMaterial(draft, projectID: original.id)
        _ = try await store.applyWorkDeskMutation(.assign(materialIDs: [draft.id], projectID: later.id))
        _ = try await store.applyWorkDeskMutation(.deleteProject(id: original.id))

        _ = try await store.upsertDeskMaterial(draft, projectID: original.id)

        let organization = try await store.fetchWorkDeskOrganization()
        XCTAssertEqual(organization.placements[draft.id]?.projectID, later.id)

        _ = try await store.applyWorkDeskMutation(.assign(materialIDs: [draft.id], projectID: nil))
        _ = try await store.upsertDeskMaterial(draft, projectID: original.id)
        let unfiled = try await store.fetchWorkDeskOrganization()
        XCTAssertNil(unfiled.placements[draft.id]?.projectID,
                     "moving to All materials is also a later filing decision")
    }

    func testLaterBatchFailureLeavesEarlierCapturesFiled() async throws {
        let store = isolated.make()
        let project = WorkDeskProjectRecord(title: "Batch")
        _ = try await store.applyWorkDeskMutation(.createProject(project, materialIDs: []))
        let first = WorkMaterialDraft(kind: .note, title: "First", textContent: "First")
        let second = WorkMaterialDraft(kind: .note, title: "Second", textContent: "Second")
        for draft in [first, second] {
            _ = try await store.upsertDeskMaterial(draft, projectID: project.id)
        }
        let missingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("absent-contextual-capture-\(UUID().uuidString).pdf")
        let third = WorkMaterialDraft(kind: .file, title: "Third", filename: "absent.pdf", byteSize: -1)
        do {
            _ = try await store.upsertDeskMaterial(third, sourceFileURL: missingURL,
                sourceFileByteSize: -1, projectID: project.id)
            XCTFail("an unreadable later item must fail")
        } catch {
            // Each earlier capture already committed its own placement.
        }

        let organization = try await store.fetchWorkDeskOrganization()
        let desk = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        XCTAssertEqual(Set(desk?.materials.map(\.id) ?? []), Set([first.id, second.id]))
        XCTAssertEqual(organization.placements[first.id]?.projectID, project.id)
        XCTAssertEqual(organization.placements[second.id]?.projectID, project.id)
        XCTAssertNil(organization.placements[third.id])
    }

    func testCaptureWithoutExplicitDestinationStaysUnfiledAlongsideAProject() async throws {
        let store = isolated.make()
        let project = WorkDeskProjectRecord(title: "Visible elsewhere")
        _ = try await store.applyWorkDeskMutation(.createProject(project, materialIDs: []))
        let material = try await store.upsertDeskMaterial(
            WorkMaterialDraft(kind: .note, title: "Headless capture", textContent: "No visible context")
        )

        let organization = try await store.fetchWorkDeskOrganization()
        XCTAssertNil(organization.placements[material.id])
    }

    func testTargetedFallbackLookupDistinguishesDeletedFilingFromUnfiledFallback() async throws {
        let store = isolated.make()
        let project = WorkDeskProjectRecord(title: "Original destination")
        _ = try await store.applyWorkDeskMutation(.createProject(project, materialIDs: []))
        let filed = try await store.upsertDeskMaterial(
            WorkMaterialDraft(kind: .transcript, title: "Filed", textContent: "Filed successfully"),
            projectID: project.id
        )
        let unfiled = try await store.upsertDeskMaterial(
            WorkMaterialDraft(kind: .transcript, title: "Unfiled", textContent: "Unfiled words")
        )
        let whileLive = try await store.isUnfiledWorkCaptureFallback(materialID: unfiled.id, projectID: project.id)
        XCTAssertFalse(whileLive)
        _ = try await store.applyWorkDeskMutation(.deleteProject(id: project.id))

        let deletedFiling = try await store.isUnfiledWorkCaptureFallback(materialID: filed.id, projectID: project.id)
        let deletedFallback = try await store.isUnfiledWorkCaptureFallback(materialID: unfiled.id, projectID: project.id)
        let missingFallback = try await store.isUnfiledWorkCaptureFallback(materialID: unfiled.id, projectID: UUID())

        XCTAssertFalse(deletedFiling, "a tombstone and retained placement are a later project deletion")
        XCTAssertTrue(deletedFallback, "the same tombstone without placement still allows a genuine fallback")
        XCTAssertTrue(missingFallback)
    }
}
