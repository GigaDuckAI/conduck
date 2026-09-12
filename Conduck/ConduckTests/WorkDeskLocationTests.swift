// SPDX-License-Identifier: Apache-2.0

// A material is one payload with independent, equal locations. These isolated
// store tests exercise source-aware moves, shared-reference deletion, stale
// drags, folded companions and guarded undo. They do not assert live iCloud
// delivery or any physical drag-and-drop presentation.

import XCTest
import CoreData
@testable import Conduck

final class WorkDeskLocationTests: XCTestCase {
    private let isolated = IsolatedWorkStores()

    override func tearDown() async throws {
        await isolated.cleanUp()
        try await super.tearDown()
    }

    func testFileMoveAddAndMoveBackPreservesOtherReferenceAndOnePayload() async throws {
        let store = isolated.make()
        let bytes = Data("One underlying material".utf8)
        let material = try await store.upsertDeskMaterial(.init(kind: .file, title: "File", filename: "file.txt",
                                                               mimeType: "text/plain", payload: bytes))
        let a = try await project("A", store: store), b = try await project("B", store: store)
        let initial = try await store.fetchWorkDeskOrganization()
        XCTAssertEqual(locations(material.id, in: initial), [.home])
        let filed = try await store.applyWorkDeskMutation(.moveLocations(materialIDs: [material.id], from: .home,
            to: .project(a), positions: [material.id: .init(x: 80, y: 90)], expected: tokens([material.id], in: initial)))
        XCTAssertEqual(locations(material.id, in: filed), [.project(a)])
        let shared = try await store.applyWorkDeskMutation(.addLocations(materialIDs: [material.id], to: .project(b),
            positions: [material.id: .init(x: 500, y: 600)], expected: tokens([material.id], in: filed)))
        XCTAssertEqual(locations(material.id, in: shared), [.project(a), .project(b)])
        let returned = try await store.applyWorkDeskMutation(.moveLocations(materialIDs: [material.id], from: .project(a),
            to: .home, positions: [material.id: .init(x: -80, y: 120)], expected: tokens([material.id], in: shared)))
        XCTAssertEqual(locations(material.id, in: returned), [.home, .project(b)])
        XCTAssertEqual(returned.locations(for: material.id).first { $0.location == .project(b) }?.position,
                       .init(x: 500, y: 600))
        let unchanged = try await store.fetchWorkMaterial(id: material.id)
        let payload = try await store.loadWorkMaterialPayload(id: material.id)
        let blobRows = await store._workMaterialBlobRowsForTesting(materialID: material.id)
        let materialRows = await store._workMaterialRowsForTesting(id: material.id)
        XCTAssertEqual(unchanged, material)
        XCTAssertEqual(payload, bytes)
        XCTAssertEqual(blobRows.count, 1)
        XCTAssertEqual(materialRows.count, 1)
    }

    func testDuplicateAddIsNoOpAndMovingOntoExistingReferenceKeepsItsPosition() async throws {
        let store = isolated.make(), material = try await note(store: store)
        let a = try await project("A", store: store)
        let shared = try await store.applyWorkDeskMutation(.addLocations(materialIDs: [material.id], to: .project(a),
            positions: [material.id: .init(x: 30, y: 40)], expected: nil))
        let repeated = try await store.applyWorkDeskMutation(.addLocations(materialIDs: [material.id, material.id], to: .project(a),
            positions: [material.id: .init(x: 900, y: 900)], expected: nil))
        XCTAssertEqual(repeated, shared, "An existing reference must not move or acquire a fresh activity stamp")
        let moved = try await store.applyWorkDeskMutation(.moveLocations(materialIDs: [material.id], from: .home,
            to: .project(a), positions: [material.id: .init(x: 700, y: 700)], expected: nil))
        XCTAssertEqual(locations(material.id, in: moved), [.project(a)])
        XCTAssertEqual(moved.locations(for: material.id).first?.position, .init(x: 30, y: 40))
    }

    func testRemovingOnlyReferenceReturnsHomeAndRemovingSharedReferencePreservesOther() async throws {
        let store = isolated.make(), material = try await note(store: store)
        let a = try await project("A", store: store), b = try await project("B", store: store)
        _ = try await store.applyWorkDeskMutation(.assign(materialIDs: [material.id], projectID: a))
        _ = try await store.applyWorkDeskMutation(.addLocations(materialIDs: [material.id], to: .project(b), positions: [:], expected: nil))
        let once = try await store.applyWorkDeskMutation(.removeLocations(materialIDs: [material.id], from: .project(a), expected: nil))
        XCTAssertEqual(locations(material.id, in: once), [.project(b)])
        let twice = try await store.applyWorkDeskMutation(.removeLocations(materialIDs: [material.id], from: .project(b), expected: nil))
        XCTAssertEqual(locations(material.id, in: twice), [.home])
        let preserved = try await store.fetchWorkMaterial(id: material.id)
        XCTAssertEqual(preserved, material)
    }

    func testStaleGroupDragAndDeletedDestinationRefuseWithoutPartialMembershipChanges() async throws {
        let store = isolated.make(), one = try await note(store: store), two = try await note(store: store)
        let a = try await project("A", store: store), b = try await project("B", store: store)
        let initial = try await store.fetchWorkDeskOrganization()
        let expected = tokens([one.id, two.id], in: initial)
        _ = try await store.applyWorkDeskMutation(.addLocations(materialIDs: [two.id], to: .project(b), positions: [:], expected: nil))
        let before = try await store.fetchWorkDeskOrganization()
        await assertRefused(.moveLocations(materialIDs: [one.id, two.id], from: .home, to: .project(a),
            positions: [:], expected: expected), error: .materialMoved, store: store)
        let after = try await store.fetchWorkDeskOrganization()
        XCTAssertEqual(after, before)
        _ = try await store.applyWorkDeskMutation(.deleteProject(id: a))
        let deleted = try await store.fetchWorkDeskOrganization()
        await assertRefused(.addLocations(materialIDs: [one.id], to: .project(a), positions: [:], expected: nil),
                            error: .projectNotFound, store: store)
        let refused = try await store.fetchWorkDeskOrganization()
        XCTAssertEqual(refused, deleted)
    }

    func testIndependentLocationCoordinatesAndStalePositionWrite() async throws {
        let store = isolated.make(), material = try await note(store: store)
        let a = try await project("A", store: store), b = try await project("B", store: store)
        _ = try await store.applyWorkDeskMutation(.assign(materialIDs: [material.id], projectID: a))
        let shared = try await store.applyWorkDeskMutation(.addLocations(materialIDs: [material.id], to: .project(b),
            positions: [material.id: .init(x: 400, y: 500)], expected: nil))
        let moved = try await store.applyWorkDeskMutation(.positionLocations(positions: [material.id: .init(x: -40, y: 80)],
            at: .project(a), expected: tokens([material.id], in: shared)))
        XCTAssertEqual(moved.locations(for: material.id).first { $0.location == .project(a) }?.position, .init(x: -40, y: 80))
        XCTAssertEqual(moved.locations(for: material.id).first { $0.location == .project(b) }?.position, .init(x: 400, y: 500))
        await assertRefused(.positionLocations(positions: [material.id: .init(x: 999, y: 999)], at: .project(a),
            expected: tokens([material.id], in: shared)), error: .materialMoved, store: store)
    }

    func testProjectDeletionKeepsOtherReferencesAndOnlyOrphansReturnHome() async throws {
        let store = isolated.make(), shared = try await note(store: store), exclusive = try await note(store: store)
        let a = try await project("A", store: store), b = try await project("B", store: store)
        _ = try await store.applyWorkDeskMutation(.assign(materialIDs: [shared.id, exclusive.id], projectID: a))
        _ = try await store.applyWorkDeskMutation(.addLocations(materialIDs: [shared.id], to: .project(b), positions: [:], expected: nil))
        let review = try await store.reviewWorkDeskProjectDeletion(id: a)
        XCTAssertEqual(review.sharedMaterialIDs, [shared.id])
        let saved = try await store.applyWorkDeskMutation(.deleteReviewedProject(review, deleteMaterials: false))
        XCTAssertEqual(locations(shared.id, in: saved), [.project(b)])
        XCTAssertEqual(locations(exclusive.id, in: saved), [.home])
        let unchanged = try await store.fetchWorkMaterial(id: shared.id)
        XCTAssertEqual(unchanged, shared)
    }

    func testAddingReferenceInvalidatesDestructiveProjectReviewAndFreshReviewDeletesEverywhere() async throws {
        let store = isolated.make(), material = try await note(store: store)
        let a = try await project("A", store: store), b = try await project("B", store: store)
        _ = try await store.applyWorkDeskMutation(.assign(materialIDs: [material.id], projectID: a))
        let stale = try await store.reviewWorkDeskProjectDeletion(id: a)
        _ = try await store.applyWorkDeskMutation(.addLocations(materialIDs: [material.id], to: .project(b), positions: [:], expected: nil))
        await assertRefused(.deleteReviewedProject(stale, deleteMaterials: true), error: .staleProjectDeletion, store: store)
        let fresh = try await store.reviewWorkDeskProjectDeletion(id: a)
        XCTAssertEqual(fresh.sharedMaterialIDs, [material.id])
        let saved = try await store.applyWorkDeskMutation(.deleteReviewedProject(fresh, deleteMaterials: true))
        let removed = try await store.fetchWorkMaterial(id: material.id)
        XCTAssertNil(removed)
        XCTAssertNil(saved.materialLocations[material.id])
        XCTAssertTrue(saved.projects.contains { $0.id == b })
    }

    func testPictureAndFoldedWordsMoveAndAddAsOneOrganizationalUnit() async throws {
        let store = isolated.make()
        let picture = try await store.upsertDeskMaterial(.init(kind: .image, title: "Picture", storageMode: .metadataOnly))
        let words = try await store.upsertDeskMaterial(.init(kind: .transcript, title: "Words", textContent: "Together",
                                                            attachedToMaterialID: picture.id))
        let a = try await project("A", store: store), b = try await project("B", store: store)
        _ = try await store.applyWorkDeskMutation(.moveLocations(materialIDs: [picture.id], from: .home, to: .project(a), positions: [:], expected: nil))
        _ = try await store.applyWorkDeskMutation(.addLocations(materialIDs: [picture.id], to: .project(b), positions: [:], expected: nil))
        let returned = try await store.applyWorkDeskMutation(.moveLocations(materialIDs: [picture.id], from: .project(a),
            to: .home, positions: [picture.id: .init(x: 10, y: 20)], expected: nil))
        XCTAssertEqual(locations(picture.id, in: returned), [.home, .project(b)])
        XCTAssertEqual(locations(words.id, in: returned), [.home, .project(b)])
        XCTAssertEqual(returned.locations(for: picture.id).map(\.position), returned.locations(for: words.id).map(\.position))
    }

    @MainActor
    func testControllerUndoRestoresLocationsAndRefusesAChangedAfterState() async throws {
        let store = isolated.make(), material = try await note(store: store)
        let a = try await project("A", store: store), b = try await project("B", store: store)
        let organization = WorkDeskOrganization(store: store)
        await organization.reload()
        let moved = await organization.move(materialIDs: [material.id], from: .home, to: .project(a))
        XCTAssertTrue(moved)
        let receipt = try XCTUnwrap(organization.lastLocationUndo)
        let undone = await organization.undo(receipt)
        XCTAssertTrue(undone)
        XCTAssertTrue(organization.contains(materialID: material.id, at: .home))
        let redo = try XCTUnwrap(organization.lastLocationUndo)
        let redone = await organization.undo(redo)
        XCTAssertTrue(redone)
        XCTAssertTrue(organization.contains(materialID: material.id, at: .project(a)))
        let secondReceipt = try XCTUnwrap(organization.lastLocationUndo)
        _ = try await store.applyWorkDeskMutation(.addLocations(materialIDs: [material.id], to: .project(b), positions: [:], expected: nil))
        let refused = await organization.undo(secondReceipt)
        XCTAssertFalse(refused)
        let current = try await store.fetchWorkDeskOrganization()
        XCTAssertEqual(locations(material.id, in: current), [.project(a), .project(b)])
    }

    func testCreatingProjectFromHomePreservesPreviouslyAddedReferencesAndRefusesStaleSource() async throws {
        let store = isolated.make(), material = try await note(store: store)
        let existing = try await project("Existing", store: store)
        _ = try await store.applyWorkDeskMutation(.addLocations(materialIDs: [material.id], to: .project(existing), positions: [:], expected: nil))
        let new = WorkDeskProjectRecord(title: "New")
        let saved = try await store.applyWorkDeskMutation(.createProjectFrom(new, materialIDs: [material.id], source: .home, expected: nil))
        XCTAssertEqual(locations(material.id, in: saved), [.project(existing), .project(new.id)])
        let refused = WorkDeskProjectRecord(title: "Must not remain")
        await assertRefused(.createProjectFrom(refused, materialIDs: [material.id], source: .home, expected: nil),
                            error: .materialMoved, store: store)
        let final = try await store.fetchWorkDeskOrganization()
        XCTAssertFalse(final.projects.contains { $0.id == refused.id })
    }

    func testLateDuplicateCannotResurrectRemovedLocationAndExplicitReaddCan() async throws {
        let store = isolated.make(), material = try await note(store: store)
        let a = try await project("A", store: store)
        _ = try await store.applyWorkDeskMutation(.moveLocations(materialIDs: [material.id], from: .home, to: .project(a), positions: [:], expected: nil))
        _ = try await store.applyWorkDeskMutation(.moveLocations(materialIDs: [material.id], from: .project(a), to: .home, positions: [:], expected: nil))
        let context = await store.newWriteContext()
        try await context.perform {
            let request = NSFetchRequest<NSManagedObject>(entityName: "WorkDeskLocation")
            request.predicate = NSPredicate(format: "materialID == %@ AND projectID == %@", material.id as CVarArg, a as CVarArg)
            let original = try XCTUnwrap(context.fetch(request).first)
            let stamp = try XCTUnwrap(original.value(forKey: "updatedAt") as? Date)
            for date in [stamp.addingTimeInterval(-1), stamp] {
                let duplicate = NSEntityDescription.insertNewObject(forEntityName: "WorkDeskLocation", into: context)
                duplicate.setValue(material.id, forKey: "materialID")
                duplicate.setValue(a, forKey: "projectID")
                duplicate.setValue(true, forKey: "isPresent")
                duplicate.setValue(date, forKey: "updatedAt")
                duplicate.setValue(UUID(), forKey: "revision")
            }
            try context.save()
        }
        let read = try await store.fetchWorkDeskOrganization()
        XCTAssertEqual(locations(material.id, in: read), [.home])
        let readded = try await store.applyWorkDeskMutation(.addLocations(materialIDs: [material.id], to: .project(a), positions: [:], expected: nil))
        XCTAssertEqual(locations(material.id, in: readded), [.home, .project(a)])
    }

    func testOlderClientMoveReplacesOnlyProjectedReference() async throws {
        let store = isolated.make(), material = try await note(store: store)
        let a = try await project("A", store: store), b = try await project("B", store: store), c = try await project("C", store: store)
        _ = try await store.applyWorkDeskMutation(.assign(materialIDs: [material.id], projectID: a))
        let shared = try await store.applyWorkDeskMutation(.addLocations(materialIDs: [material.id], to: .project(b), positions: [:], expected: nil))
        let representative = try XCTUnwrap(shared.placements[material.id]?.projectID)
        let other = representative == a ? b : a
        let context = await store.newWriteContext()
        try await context.perform {
            let request = NSFetchRequest<NSManagedObject>(entityName: "WorkDeskPlacement")
            request.predicate = NSPredicate(format: "materialID == %@", material.id as CVarArg)
            for row in try context.fetch(request) {
                let stamp = try XCTUnwrap(row.value(forKey: "updatedAt") as? Date)
                row.setValue(c, forKey: "projectID")
                row.setValue(88.0, forKey: "positionX")
                row.setValue(99.0, forKey: "positionY")
                row.setValue(stamp.addingTimeInterval(1), forKey: "updatedAt")
            }
            try context.save()
        }
        let bridged = try await store.fetchWorkDeskOrganization()
        XCTAssertEqual(locations(material.id, in: bridged), [.project(other), .project(c)])
        XCTAssertEqual(bridged.locations(for: material.id).first { $0.location == .project(c) }?.position, .init(x: 88, y: 99))
        let adopted = try await store.applyWorkDeskMutation(.moveLocations(materialIDs: [material.id], from: .project(c),
            to: .home, positions: [:], expected: tokens([material.id], in: bridged)))
        XCTAssertEqual(locations(material.id, in: adopted), [.home, .project(other)])
    }

    func testMissingProjectFallsBackWithoutErasingAnInFlightMembership() async throws {
        let store = isolated.make(), material = try await note(store: store)
        let pendingProjectID = UUID()
        let context = await store.newWriteContext()
        try await context.perform {
            let row = NSEntityDescription.insertNewObject(forEntityName: "WorkDeskLocation", into: context)
            row.setValue(material.id, forKey: "materialID")
            row.setValue(pendingProjectID, forKey: "projectID")
            row.setValue(true, forKey: "isPresent")
            row.setValue(Date(), forKey: "updatedAt")
            try context.save()
        }
        let pending = try await store.fetchWorkDeskOrganization()
        XCTAssertEqual(locations(material.id, in: pending), [.home])
        let seeded = try await store.applyWorkDeskMutation(.seedPositions(materials: [
            .init(materialID: material.id, projectID: nil, position: .init(x: 30, y: 40), isHome: true)
        ], projects: [:]))
        XCTAssertEqual(seeded.locations(for: material.id).first?.position, .init(x: 30, y: 40))
        let moved = try await store.applyWorkDeskMutation(.positionLocations(positions: [material.id: .init(x: 50, y: 60)],
            at: .home, expected: tokens([material.id], in: seeded)))
        XCTAssertEqual(moved.locations(for: material.id).first?.position, .init(x: 50, y: 60))
        try await context.perform {
            let row = NSEntityDescription.insertNewObject(forEntityName: "WorkDeskProject", into: context)
            row.setValue(pendingProjectID, forKey: "id")
            row.setValue("Arrived", forKey: "title")
            try context.save()
        }
        let arrived = try await store.fetchWorkDeskOrganization()
        XCTAssertEqual(locations(material.id, in: arrived), [.project(pendingProjectID)])
    }

    func testReadableOrderIsIndependentPerLocationAndKeepsSpatialPositions() async throws {
        let store = isolated.make(), one = try await note(store: store), two = try await note(store: store)
        let a = try await project("A", store: store), b = try await project("B", store: store)
        _ = try await store.applyWorkDeskMutation(.assign(materialIDs: [one.id, two.id], projectID: a))
        _ = try await store.applyWorkDeskMutation(.addLocations(materialIDs: [one.id, two.id], to: .project(b),
            positions: [one.id: .init(x: 80, y: 90), two.id: .init(x: 100, y: 120)], expected: nil))
        let before = try await store.fetchWorkDeskOrganization()
        let after = try await store.applyWorkDeskMutation(.reorderLocations(materialID: one.id, relativeTo: two.id,
            placement: .after, at: .project(a), orderedMaterialIDs: [one.id, two.id], expected: tokens([one.id, two.id], in: before)))
        XCTAssertEqual(after.locations(for: two.id).first { $0.location == .project(a) }?.sortRank, 0)
        XCTAssertEqual(after.locations(for: one.id).first { $0.location == .project(a) }?.sortRank, 1)
        for id in [one.id, two.id] {
            XCTAssertEqual(after.locations(for: id).first { $0.location == .project(b) },
                           before.locations(for: id).first { $0.location == .project(b) })
            XCTAssertEqual(after.locations(for: id).first { $0.location == .project(a) }?.position,
                           before.locations(for: id).first { $0.location == .project(a) }?.position)
        }
    }

    @MainActor
    func testUndoUsesAtomicStoreBeforeStateAndCannotCaptureUnpublishedOtherWindowChanges() async throws {
        let store = isolated.make(), own = try await note(store: store), other = try await note(store: store)
        let a = try await project("A", store: store), b = try await project("B", store: store)
        let organization = WorkDeskOrganization(store: store)
        await organization.reload()
        // Neither change has been reloaded into the initiating window. Its
        // eventual undo must preserve both the other item and its own new ref.
        _ = try await store.applyWorkDeskMutation(.addLocations(materialIDs: [own.id, other.id], to: .project(b), positions: [:], expected: nil))
        let moved = await organization.move(materialIDs: [own.id], from: .home, to: .project(a))
        XCTAssertTrue(moved)
        let receipt = try XCTUnwrap(organization.lastLocationUndo)
        XCTAssertEqual(Set(receipt.before.keys), [own.id])
        XCTAssertEqual(Set(receipt.before[own.id]!.map(\.location)), [.home, .project(b)])
        let undone = await organization.undo(receipt)
        XCTAssertTrue(undone)
        let current = try await store.fetchWorkDeskOrganization()
        XCTAssertEqual(locations(own.id, in: current), [.home, .project(b)])
        XCTAssertEqual(locations(other.id, in: current), [.home, .project(b)])
    }

    @MainActor
    func testAutomaticDestinationSeedPreservesOtherCoordinatesAndUndoButManualMoveRefuses() async throws {
        let store = isolated.make(), material = try await note(store: store)
        let a = try await project("A", store: store)
        _ = try await store.applyWorkDeskMutation(.moveHomeMaterials([
            .init(materialID: material.id, projectID: nil, position: .init(x: 500, y: 600))
        ]))
        let organization = WorkDeskOrganization(store: store)
        await organization.reload()
        let added = await organization.add(materialIDs: [material.id], to: .project(a))
        XCTAssertTrue(added)
        let receipt = try XCTUnwrap(organization.lastLocationUndo)
        let homeBefore = try XCTUnwrap(receipt.after[material.id]?.first { $0.location == .home })
        let seeded = try await store.applyWorkDeskMutation(.seedPositions(materials: [
            .init(materialID: material.id, projectID: a, position: .init(x: 28, y: 26))
        ], projects: [:]))
        XCTAssertEqual(seeded.locations(for: material.id).first { $0.location == .home }, homeBefore)
        let undone = await organization.undo(receipt)
        XCTAssertTrue(undone, "Automatic first layout is not an intervening user edit")
        let addedAgain = await organization.add(materialIDs: [material.id], to: .project(a))
        XCTAssertTrue(addedAgain)
        let second = try XCTUnwrap(organization.lastLocationUndo)
        _ = try await store.applyWorkDeskMutation(.seedPositions(materials: [
            .init(materialID: material.id, projectID: a, position: .init(x: 28, y: 26))
        ], projects: [:]))
        _ = try await store.applyWorkDeskMutation(.positionLocations(positions: [material.id: .init(x: 40, y: 70)],
            at: .project(a), expected: nil))
        let refused = await organization.undo(second)
        XCTAssertFalse(refused, "Manual positioning must never qualify for the seed exception")
    }

    @MainActor
    func testCrossLocationReadableDropMovesAndRanksWithOneAtomicUndo() async throws {
        let store = isolated.make(), incoming = try await note(store: store)
        let first = try await note(store: store), second = try await note(store: store)
        let a = try await project("A", store: store), b = try await project("B", store: store)
        _ = try await store.applyWorkDeskMutation(.assign(materialIDs: [first.id, second.id], projectID: a))
        _ = try await store.applyWorkDeskMutation(.addLocations(materialIDs: [incoming.id], to: .project(b), positions: [:], expected: nil))
        let organization = WorkDeskOrganization(store: store)
        await organization.reload()
        let moved = await organization.moveAndReorder(materialIDs: [incoming.id], from: .home, to: .project(a),
            relativeTo: second.id, placement: .before, orderedMaterialIDs: [first.id, second.id])
        XCTAssertTrue(moved)
        let receipt = try XCTUnwrap(organization.lastLocationUndo)
        XCTAssertEqual(Set(receipt.after.keys), [incoming.id, first.id, second.id])
        XCTAssertEqual(organization.locations(for: incoming.id).first { $0.location == .project(a) }?.sortRank, 1)
        XCTAssertEqual(organization.locations(for: second.id).first { $0.location == .project(a) }?.sortRank, 2)
        let undone = await organization.undo(receipt)
        XCTAssertTrue(undone)
        let current = try await store.fetchWorkDeskOrganization()
        XCTAssertEqual(locations(incoming.id, in: current), [.home, .project(b)])
        XCTAssertNil(current.locations(for: first.id).first { $0.location == .project(a) }?.sortRank)
        XCTAssertNil(current.locations(for: second.id).first { $0.location == .project(a) }?.sortRank)
    }

    func testCrossLocationReadableDropRefusesStaleTargetListBeforeFiling() async throws {
        let store = isolated.make(), incoming = try await note(store: store)
        let target = try await note(store: store), arrived = try await note(store: store)
        let a = try await project("A", store: store)
        _ = try await store.applyWorkDeskMutation(.assign(materialIDs: [target.id, arrived.id], projectID: a))
        let before = try await store.fetchWorkDeskOrganization()
        await assertRefused(.moveAndReorderLocations(materialIDs: [incoming.id], from: .home, to: .project(a),
            relativeTo: target.id, placement: .before, orderedMaterialIDs: [target.id], expected: nil),
            error: .materialMoved, store: store)
        let after = try await store.fetchWorkDeskOrganization()
        XCTAssertEqual(after, before)
        XCTAssertEqual(locations(incoming.id, in: after), [.home])
    }

    private func note(store: ConversationStore) async throws -> WorkMaterialRecord {
        try await store.upsertDeskMaterial(.init(kind: .note, title: "Thought", textContent: "One thought"))
    }

    private func project(_ title: String, store: ConversationStore) async throws -> UUID {
        let project = WorkDeskProjectRecord(title: title)
        _ = try await store.applyWorkDeskMutation(.createProject(project, materialIDs: []))
        return project.id
    }

    private func locations(_ materialID: UUID, in snapshot: WorkDeskOrganizationSnapshot) -> Set<WorkDeskLocation> {
        Set(snapshot.locations(for: materialID).map(\.location))
    }

    private func tokens(_ ids: [UUID], in snapshot: WorkDeskOrganizationSnapshot) -> WorkDeskLocationTokens {
        Dictionary(uniqueKeysWithValues: ids.map { ($0, snapshot.locations(for: $0)) })
    }

    private func assertRefused(_ mutation: WorkDeskMutation, error expected: WorkDeskStoreError, store: ConversationStore,
                               file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await store.applyWorkDeskMutation(mutation)
            XCTFail("The stale operation must be refused", file: file, line: line)
        } catch { XCTAssertEqual(error as? WorkDeskStoreError, expected, file: file, line: line) }
    }
}
