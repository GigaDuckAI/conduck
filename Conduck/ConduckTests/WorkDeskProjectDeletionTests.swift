// SPDX-License-Identifier: Apache-2.0

// Reviewed deletion is all-or-nothing over the materials the person saw.
// These isolated-store cases exercise paired bytes, folded companions, late
// membership, imported duplicates and independent conversation history.

import XCTest
import CoreData
@testable import Conduck

final class WorkDeskProjectDeletionTests: XCTestCase {
    private let isolated = IsolatedWorkStores()
    override func tearDown() async throws {
        await isolated.cleanUp()
        try await super.tearDown()
    }

    private func material(_ title: String, store: ConversationStore) async throws -> WorkMaterialRecord {
        try await store.upsertDeskMaterial(.init(kind: .file, title: title, filename: "\(title).txt",
            mimeType: "text/plain", payload: Data(title.utf8)))
    }

    func testKeepReturnsOriginalCardsInCompactFreeGroupWithoutRepublishingBytes() async throws {
        let store = isolated.make()
        var members: [WorkMaterialRecord] = []
        for name in ["One", "Two", "Three", "Four"] { members.append(try await material(name, store: store)) }
        let obstacle = try await material("Other", store: store)
        let project = WorkDeskProjectRecord(title: "Research", position: .init(x: 100, y: 100))
        _ = try await store.applyWorkDeskMutation(.createProject(project, materialIDs: members.map(\.id)))
        _ = try await store.applyWorkDeskMutation(.moveMaterial(id: obstacle.id, position: .init(x: 100, y: 100)))
        let review = try await store.reviewWorkDeskProjectDeletion(id: project.id)
        XCTAssertEqual(review.materialCount, 4)
        let saved = try await store.applyWorkDeskMutation(.deleteReviewedProject(review, deleteMaterials: false))
        XCTAssertTrue(saved.projects.isEmpty)
        XCTAssertEqual(saved.deletedProjectIDs, [project.id])
        let obstacleFrame = WorkDeskCanvasGeometry.frame(at: .init(x: 100, y: 100),
            bodySize: WorkDeskCanvasGeometry.cardBodySize, scale: 1)
        var frames: [CGRect] = []
        for member in members {
            let placement = try XCTUnwrap(saved.placements[member.id])
            XCTAssertNil(placement.projectID)
            XCTAssertNil(placement.position)
            let point = try XCTUnwrap(placement.homePosition)
            let frame = WorkDeskCanvasGeometry.frame(at: point, bodySize: WorkDeskCanvasGeometry.cardBodySize, scale: 1)
            XCTAssertFalse(frame.intersects(obstacleFrame))
            XCTAssertFalse(frames.contains { $0.intersects(frame) })
            frames.append(frame)
            let unchanged = try await store.fetchWorkMaterial(id: member.id)
            let bytes = try await store.loadWorkMaterialPayload(id: member.id)
            let blobs = await store._workMaterialBlobRowsForTesting(materialID: member.id)
            XCTAssertEqual(unchanged, member)
            XCTAssertEqual(bytes, Data(member.title.utf8))
            XCTAssertEqual(blobs.count, 1)
        }
        let bounds = frames.dropFirst().reduce(frames[0]) { $0.union($1) }
        XCTAssertEqual(bounds.width, 488)
        XCTAssertEqual(bounds.height, 500)
    }

    func testDestructiveChoiceDeletesDuplicatesAndBlobsButKeepsConversationAndResultReceipt() async throws {
        let store = isolated.make()
        let project = WorkDeskProjectRecord(title: "Output")
        _ = try await store.applyWorkDeskMutation(.createProject(project, materialIDs: []))
        let conversation = try await store.createConversation(backend: "hermes", projectID: project.id)
        let bytes = Data("saved reply".utf8)
        let attachment = AttachmentDraft(mimeType: "text/plain", filename: "reply.txt", data: bytes,
            thumbnailData: nil, width: 0, height: 0, byteSize: bytes.count, sequence: 0)
        let reply = try await store.appendMessage(role: "agent", text: "Done", conversationID: conversation.id,
            sourceDevice: "test", attachments: [attachment])
        await store.reconcileProjectResults()
        let review = try await store.reviewWorkDeskProjectDeletion(id: project.id)
        let id = try XCTUnwrap(review.materialIDs.first)
        XCTAssertEqual(review.conversationCount, 1)
        await store._duplicateWorkMaterialRowForTesting(id: id, updatedAt: .distantPast)
        let fresh = try await store.reviewWorkDeskProjectDeletion(id: project.id)
        _ = try await store.applyWorkDeskMutation(.deleteReviewedProject(fresh, deleteMaterials: true))
        let materialRows = await store._workMaterialRowsForTesting(id: id)
        let blobRows = await store._workMaterialBlobRowsForTesting(materialID: id)
        let source = try await store.fetchMessage(id: reply.id, in: conversation.id)
        let receipt = try await store.fetchWorkDeskResults()[id]
        XCTAssertTrue(materialRows.isEmpty)
        XCTAssertTrue(blobRows.isEmpty)
        XCTAssertEqual(source?.text, "Done")
        XCTAssertEqual(source?.attachments.count, 1)
        XCTAssertEqual(receipt?.conversationID, conversation.id)
        _ = try await store.appendMessage(role: "agent", text: "Late reply", conversationID: conversation.id,
            sourceDevice: "test", attachments: [attachment])
        await store.reconcileProjectResults()
        let desk = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        XCTAssertTrue(desk?.materials.isEmpty ?? true, "Deleting a project must not recreate it or its results")
    }

    func testNewMemberMovedMemberEditedMaterialAndEditedProjectRefuseBothChoices() async throws {
        for deleteMaterials in [false, true] {
            for change in 0..<4 {
                let store = isolated.make()
                let member = try await store.upsertDeskMaterial(.init(kind: .note, title: "Note", textContent: "Before"))
                let project = WorkDeskProjectRecord(title: "Before")
                _ = try await store.applyWorkDeskMutation(.createProject(project, materialIDs: [member.id]))
                let review = try await store.reviewWorkDeskProjectDeletion(id: project.id)
                switch change {
                case 0:
                    let arrival = try await material("Arrived", store: store)
                    _ = try await store.applyWorkDeskMutation(.assign(materialIDs: [arrival.id], projectID: project.id))
                case 1:
                    _ = try await store.applyWorkDeskMutation(.assign(materialIDs: [member.id], projectID: nil))
                case 2:
                    _ = try await store.updateWorkMaterialText(id: member.id, textContent: "After", annotation: nil,
                        expectedRevision: Int64(bitPattern: member.updatedAt.timeIntervalSinceReferenceDate.bitPattern))
                default:
                    _ = try await store.applyWorkDeskMutation(.updateProject(id: project.id, title: "After", brief: "", preferredGatewayRef: nil))
                }
                let before = try await store.fetchWorkDeskOrganization()
                do {
                    _ = try await store.applyWorkDeskMutation(.deleteReviewedProject(review, deleteMaterials: deleteMaterials))
                    XCTFail("A stale confirmation must not write any part of its deletion")
                } catch { XCTAssertEqual(error as? WorkDeskStoreError, .staleProjectDeletion) }
                let after = try await store.fetchWorkDeskOrganization()
                let retained = try await store.fetchWorkMaterial(id: member.id)
                XCTAssertEqual(after, before)
                XCTAssertNotNil(retained)
            }
        }
    }

    func testUnfiledDisplayedCompanionIsReviewedWithItsPicture() async throws {
        for deleteMaterials in [false, true] {
            let store = isolated.make()
            let image = try await store.upsertDeskMaterial(.init(kind: .image, title: "Picture", storageMode: .metadataOnly))
            let child = try await store.upsertDeskMaterial(.init(kind: .transcript, title: "Words", textContent: "Keep these words",
                attachedToMaterialID: image.id))
            let project = WorkDeskProjectRecord(title: "Pair")
            _ = try await store.applyWorkDeskMutation(.createProject(project, materialIDs: [image.id]))
            let review = try await store.reviewWorkDeskProjectDeletion(id: project.id)
            XCTAssertEqual(Set(review.materialIDs), [image.id, child.id])
            XCTAssertEqual(review.visibleMaterialIDs, [image.id])
            let saved = try await store.applyWorkDeskMutation(.deleteReviewedProject(review, deleteMaterials: deleteMaterials))
            let picture = try await store.fetchWorkMaterial(id: image.id)
            let words = try await store.fetchWorkMaterial(id: child.id)
            if deleteMaterials { XCTAssertNil(picture); XCTAssertNil(words) }
            else {
                XCTAssertEqual(picture, image)
                XCTAssertEqual(words, child)
                XCTAssertEqual(saved.placements[image.id]?.homePosition, saved.placements[child.id]?.homePosition)
            }
        }
    }

    func testMovingOrGroupingDisplayedPictureMovesCompanionAndBothProjectsRemainDeletable() async throws {
        for createsProject in [false, true] {
            let store = isolated.make()
            let image = try await store.upsertDeskMaterial(.init(kind: .image, title: "Picture", storageMode: .metadataOnly))
            let child = try await store.upsertDeskMaterial(.init(kind: .transcript, title: "Words", textContent: "Words", attachedToMaterialID: image.id))
            let first = WorkDeskProjectRecord(title: "First"), second = WorkDeskProjectRecord(title: "Second")
            _ = try await store.applyWorkDeskMutation(.createProject(first, materialIDs: [image.id]))
            _ = try await store.applyWorkDeskMutation(.createProject(second, materialIDs: createsProject ? [image.id] : []))
            if !createsProject {
                _ = try await store.applyWorkDeskMutation(.assign(materialIDs: [image.id], projectID: second.id))
            }
            let moved = try await store.fetchWorkDeskOrganization()
            XCTAssertEqual(moved.placements[image.id]?.projectID, second.id)
            XCTAssertEqual(moved.placements[child.id]?.projectID, second.id)
            let oldProject = try await store.reviewWorkDeskProjectDeletion(id: first.id)
            XCTAssertEqual(oldProject.materialCount, 0)
            _ = try await store.applyWorkDeskMutation(.deleteReviewedProject(oldProject, deleteMaterials: true))
            let newProject = try await store.reviewWorkDeskProjectDeletion(id: second.id)
            XCTAssertEqual(Set(newProject.materialIDs), [image.id, child.id])
            _ = try await store.applyWorkDeskMutation(.deleteReviewedProject(newProject, deleteMaterials: true))
            let picture = try await store.fetchWorkMaterial(id: image.id), words = try await store.fetchWorkMaterial(id: child.id)
            XCTAssertNil(picture)
            XCTAssertNil(words)
        }
    }

    func testLegacySplitUsesVisibleParentHomeAndNeverDeletesWordsFromOldProject() async throws {
        for deleteSourceFirst in [false, true] {
            let store = isolated.make()
            let image = try await store.upsertDeskMaterial(.init(kind: .image, title: "Picture", storageMode: .metadataOnly))
            let child = try await store.upsertDeskMaterial(.init(kind: .transcript, title: "Words", textContent: "Words", attachedToMaterialID: image.id))
            let first = WorkDeskProjectRecord(title: "Old home"), second = WorkDeskProjectRecord(title: "Visible home")
            _ = try await store.applyWorkDeskMutation(.createProject(first, materialIDs: [image.id]))
            _ = try await store.applyWorkDeskMutation(.createProject(second, materialIDs: [image.id]))
            // Simulate an older app that moved only the visible parent.
            let context = await store.newWriteContext()
            try await context.perform {
                let request = NSFetchRequest<NSManagedObject>(entityName: "WorkDeskPlacement")
                request.predicate = NSPredicate(format: "materialID == %@", child.id as CVarArg)
                for row in try context.fetch(request) { row.setValue(first.id, forKey: "projectID") }
                try context.save()
            }
            let oldProject = try await store.reviewWorkDeskProjectDeletion(id: first.id)
            XCTAssertEqual(oldProject.materialCount, 0)
            XCTAssertTrue(oldProject.materialIDs.isEmpty)
            if deleteSourceFirst {
                _ = try await store.applyWorkDeskMutation(.deleteReviewedProject(oldProject, deleteMaterials: true))
                let preserved = try await store.fetchWorkMaterial(id: child.id)
                XCTAssertEqual(preserved?.textContent, "Words")
            }
            let visibleProject = try await store.reviewWorkDeskProjectDeletion(id: second.id)
            XCTAssertEqual(Set(visibleProject.materialIDs), [image.id, child.id])
            _ = try await store.applyWorkDeskMutation(.deleteReviewedProject(visibleProject, deleteMaterials: true))
            let picture = try await store.fetchWorkMaterial(id: image.id), words = try await store.fetchWorkMaterial(id: child.id)
            XCTAssertNil(picture)
            XCTAssertNil(words)
        }
    }

    func testEmptyProjectSupportsBothChoices() async throws {
        for deleteMaterials in [false, true] {
            let store = isolated.make()
            let project = WorkDeskProjectRecord(title: "Empty")
            _ = try await store.applyWorkDeskMutation(.createProject(project, materialIDs: []))
            let review = try await store.reviewWorkDeskProjectDeletion(id: project.id)
            XCTAssertEqual(review.materialCount, 0)
            let saved = try await store.applyWorkDeskMutation(.deleteReviewedProject(review, deleteMaterials: deleteMaterials))
            XCTAssertTrue(saved.projects.isEmpty)
        }
    }

    func testPendingMembershipMaterialArrivingAfterReviewRefusesDestruction() async throws {
        let store = isolated.make()
        let project = WorkDeskProjectRecord(title: "Import")
        _ = try await store.applyWorkDeskMutation(.createProject(project, materialIDs: []))
        let pendingID = UUID()
        let context = await store.newWriteContext()
        try await context.perform {
            let placement = NSEntityDescription.insertNewObject(forEntityName: "WorkDeskPlacement", into: context)
            placement.setValue(pendingID, forKey: "materialID")
            placement.setValue(project.id, forKey: "projectID")
            placement.setValue(Date(), forKey: "updatedAt")
            try context.save()
        }
        let review = try await store.reviewWorkDeskProjectDeletion(id: project.id)
        XCTAssertEqual(review.materialCount, 0)
        _ = try await store.upsertDeskMaterial(.init(id: pendingID, kind: .note, title: "Arrived", textContent: "Imported later"))
        do { _ = try await store.applyWorkDeskMutation(.deleteReviewedProject(review, deleteMaterials: true)); XCTFail("Unseen material must survive") }
        catch { XCTAssertEqual(error as? WorkDeskStoreError, .staleProjectDeletion) }
        let material = try await store.fetchWorkMaterial(id: pendingID)
        XCTAssertNotNil(material)
    }

    func testKeptGroupDoesNotCollapseAtCoordinateBoundary() async throws {
        let store = isolated.make()
        let first = try await material("First", store: store), second = try await material("Second", store: store)
        let project = WorkDeskProjectRecord(title: "Far away", position: .init(x: 20_000, y: 20_000))
        _ = try await store.applyWorkDeskMutation(.createProject(project, materialIDs: [first.id, second.id]))
        let review = try await store.reviewWorkDeskProjectDeletion(id: project.id)
        let saved = try await store.applyWorkDeskMutation(.deleteReviewedProject(review, deleteMaterials: false))
        let firstPoint = try XCTUnwrap(saved.placements[first.id]?.homePosition)
        let secondPoint = try XCTUnwrap(saved.placements[second.id]?.homePosition)
        XCTAssertGreaterThanOrEqual(abs(firstPoint.x - secondPoint.x), 232)
        XCTAssertLessThanOrEqual(max(firstPoint.x, secondPoint.x), WorkDeskPoint.coordinateLimit)
    }

    func testSQLiteCaptureAlreadyStagingCannotFileIntoDeletedProject() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("reviewed-deletion-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = isolated.make(storeURL: directory.appendingPathComponent("store.sqlite"))
        let second = isolated.make(storeURL: directory.appendingPathComponent("store.sqlite"))
        let project = WorkDeskProjectRecord(title: "Pending capture")
        _ = try await first.applyWorkDeskMutation(.createProject(project, materialIDs: []))
        let reachedBlob = ProjectDeletionGate(), continueCapture = ProjectDeletionGate()
        let materialID = UUID()
        await second._setWorkMaterialPublicationLockHoldForTesting { id in
            guard id == materialID else { return }
            await reachedBlob.open()
            await continueCapture.wait()
        }
        let capture = Task {
            try await second.upsertDeskMaterial(.init(id: materialID, kind: .file, title: "Arriving",
                filename: "arriving.txt", mimeType: "text/plain", payload: Data("Bytes".utf8)), projectID: project.id)
        }
        await reachedBlob.wait()
        let review = try await first.reviewWorkDeskProjectDeletion(id: project.id)
        _ = try await first.applyWorkDeskMutation(.deleteReviewedProject(review, deleteMaterials: true))
        await continueCapture.open()
        do { _ = try await capture.value; XCTFail("A deleted project cannot accept a staged capture") }
        catch { XCTAssertEqual(error as? WorkDeskStoreError, .projectNotFound) }
        let material = try await first.fetchWorkMaterial(id: materialID)
        let blobs = await second._workMaterialBlobRowsForTesting(materialID: materialID)
        XCTAssertNil(material)
        XCTAssertTrue(blobs.isEmpty, "The failed publisher reclaims only the blob it staged")
        try await first._unloadForTesting()
        try await second._unloadForTesting()
    }

    func testSQLiteImportBetweenValidationAndDeletionCannotAddUnreviewedPhysicalRows() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("deletion-import-generation-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let deletingStore = isolated.make(storeURL: directory.appendingPathComponent("store.sqlite"))
        let importingStore = isolated.make(storeURL: directory.appendingPathComponent("store.sqlite"))
        let original = try await material("Reviewed", store: deletingStore)
        let project = WorkDeskProjectRecord(title: "Reviewed project")
        _ = try await deletingStore.applyWorkDeskMutation(.createProject(project, materialIDs: [original.id]))
        let review = try await deletingStore.reviewWorkDeskProjectDeletion(id: project.id)
        _ = try await importingStore.fetchWorkDeskOrganization()
        let validated = expectation(description: "The real deletion has validated its material rows")
        let resume = DispatchSemaphore(value: 0)
        await deletingStore._setWorkDeskDeletionValidationHookForTesting {
            validated.fulfill()
            _ = resume.wait(timeout: .now() + 10)
        }
        let deletion = Task {
            try await deletingStore.applyWorkDeskMutation(.deleteReviewedProject(review, deleteMaterials: true))
        }
        await fulfillment(of: [validated], timeout: 5)
        let importingContext = await importingStore.newWriteContext()
        do {
            try await importingContext.perform {
                // A new physical row of the same logical identity can arrive
                // from CloudKit without touching the original reviewed row or
                // taking either application advisory lock. Its paired payload
                // is in a second store, which must use the same frozen read.
                for entity in ["WorkMaterial", "WorkMaterialBlob"] {
                    let request = NSFetchRequest<NSManagedObject>(entityName: entity)
                    request.predicate = NSPredicate(format: "%K == %@", entity == "WorkMaterial" ? "id" : "materialID", original.id as CVarArg)
                    let source = try XCTUnwrap(importingContext.fetch(request).first)
                    let duplicate = NSEntityDescription.insertNewObject(forEntityName: entity, into: importingContext)
                    for name in source.entity.attributesByName.keys { duplicate.setValue(source.value(forKey: name), forKey: name) }
                    duplicate.setValue(original.updatedAt.addingTimeInterval(3600), forKey: "updatedAt")
                    if entity == "WorkMaterial" {
                        duplicate.setValue("Imported after review", forKey: "title")
                        duplicate.setValue("Unreviewed notes must survive", forKey: "annotation")
                    }
                }
                try importingContext.save()
            }
        } catch {
            resume.signal()
            _ = try? await deletion.value
            throw error
        }
        resume.signal()
        _ = try await deletion.value
        await deletingStore._setWorkDeskDeletionValidationHookForTesting(nil)
        let surviving = try await deletingStore.fetchWorkMaterial(id: original.id)
        XCTAssertEqual(surviving?.title, "Imported after review")
        XCTAssertEqual(surviving?.annotation, "Unreviewed notes must survive")
        let context = await deletingStore.newReadContext()
        let counts = try await context.perform { () throws -> [Int] in
            try ["WorkMaterial", "WorkMaterialBlob"].map { entity in
                let request = NSFetchRequest<NSManagedObject>(entityName: entity)
                request.predicate = NSPredicate(format: "%K == %@", entity == "WorkMaterial" ? "id" : "materialID", original.id as CVarArg)
                return try context.count(for: request)
            }
        }
        XCTAssertEqual(counts, [1, 1], "Only reviewed physical rows may be deleted across both stores")
        let organization = try await deletingStore.fetchWorkDeskOrganization()
        XCTAssertTrue(organization.projects.isEmpty)
        XCTAssertNil(organization.placements[original.id]?.projectID, "The late imported material survives unfiled")
        try await deletingStore._unloadForTesting()
        try await importingStore._unloadForTesting()
    }
}

private actor ProjectDeletionGate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func open() {
        opened = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
    func wait() async {
        guard !opened else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}
