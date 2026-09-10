// SPDX-License-Identifier: Apache-2.0

// ConduckTests
// WorkDeskMigrationTests.swift
//
// The desk upgrade adds metadata entities to Core without touching capture or
// payload hashes. SQLite migration and independently arriving CloudKit-shaped
// rows are tested locally; these cases do not claim live iCloud delivery.

import XCTest
import CoreData
@testable import Conduck

final class WorkDeskMigrationTests: XCTestCase {
    private var directory: URL!
    private let isolated = IsolatedWorkStores()

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("work-desk-migration-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        await isolated.cleanUp()
        try? FileManager.default.removeItem(at: directory)
        try await super.tearDown()
    }

    func testV18AddsOnlyOptionalRelationshipFreeCoreMetadataEntities() throws {
        let before = try model(version: 17)
        let after = try model(version: 18)
        let additions: Set<String> = ["WorkDeskProject", "WorkDeskPlacement"]
        XCTAssertEqual(Set(after.entitiesByName.keys).subtracting(before.entitiesByName.keys), additions)
        for (name, entity) in before.entitiesByName {
            XCTAssertEqual(after.entitiesByName[name]?.versionHash, entity.versionHash,
                           "organization must not change a shipped \(name) row")
        }
        for name in additions {
            let entity = try XCTUnwrap(after.entitiesByName[name])
            XCTAssertTrue(entity.relationshipsByName.isEmpty)
            XCTAssertTrue(entity.uniquenessConstraints.isEmpty)
            for attribute in entity.attributesByName.values {
                XCTAssertTrue(attribute.isOptional)
                XCTAssertNil(attribute.defaultValue)
            }
        }
        XCTAssertEqual(
            Set(after.entities(forConfigurationName: "Core")!.compactMap(\.name)),
            Set(before.entities(forConfigurationName: "Core")!.compactMap(\.name)).union(additions)
        )
        XCTAssertEqual(after.entities(forConfigurationName: "Blobs")?.compactMap(\.name), ["WorkMaterialBlob"])
    }

    func testEveryShippedVersionCanInferAnUpgradeToV18() throws {
        let target = try model(version: 18)
        for version in 1...17 {
            let source = try model(version: version)
            XCTAssertNoThrow(try NSMappingModel.inferredMappingModel(forSourceModel: source, destinationModel: target),
                             "model \(version) must remain upgradeable")
        }
    }

    func testV17SQLiteMigratesWithoutMovingCaptureOrPayloadAndOrganizationReopens() async throws {
        let materialID = UUID()
        let bytes = Data("Bytes captured before projects".utf8)
        let capturedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let old = try await container(version: 17)
        let context = old.newBackgroundContext()
        try await context.perform {
            let item = NSEntityDescription.insertNewObject(forEntityName: "WorkItem", into: context)
            item.setValue(Constants.workboardDeskItemID, forKey: "id")
            item.setValue(capturedAt, forKey: "createdAt")
            item.setValue(capturedAt, forKey: "updatedAt")
            let material = NSEntityDescription.insertNewObject(forEntityName: "WorkMaterial", into: context)
            material.setValue(materialID, forKey: "id")
            material.setValue(Constants.workboardDeskItemID, forKey: "workItemID")
            material.setValue("file", forKey: "kind")
            material.setValue("Old capture", forKey: "title")
            material.setValue("old.txt", forKey: "filename")
            material.setValue("text/plain", forKey: "mimeType")
            material.setValue("syncedPayload", forKey: "storageMode")
            material.setValue("migration-fixture", forKey: "contentHash")
            material.setValue(Int64(bytes.count), forKey: "byteSize")
            material.setValue(capturedAt, forKey: "createdAt")
            material.setValue(capturedAt, forKey: "updatedAt")
            let blob = NSEntityDescription.insertNewObject(forEntityName: "WorkMaterialBlob", into: context)
            blob.setValue(materialID, forKey: "materialID")
            blob.setValue(bytes, forKey: "payload")
            blob.setValue(Int64(bytes.count), forKey: "byteSize")
            blob.setValue("migration-fixture", forKey: "contentHash")
            blob.setValue(capturedAt, forKey: "createdAt")
            blob.setValue(capturedAt, forKey: "updatedAt")
            try context.save()
        }
        try unload(old)

        let upgraded = try await container(version: 18)
        XCTAssertEqual(upgraded.persistentStoreCoordinator.persistentStores.count, 2)
        try unload(upgraded)
        let store = isolated.make(storeURL: coreURL)
        let before = try await store.fetchWorkDeskOrganization()
        XCTAssertEqual(before, .init())
        let captured = try await store.fetchWorkMaterial(id: materialID)
        XCTAssertEqual(captured?.updatedAt, capturedAt)
        let project = WorkDeskProjectRecord(title: "Keep working", brief: "Use what I collected")
        try await store.applyWorkDeskMutation(.createProject(project, materialIDs: [materialID]))
        try await store.applyWorkDeskMutation(.moveMaterial(id: materialID, position: .init(x: 98, y: 200)))
        try await store.applyWorkDeskMutation(.pinMaterial(id: materialID, isPinned: true))

        let reopened = isolated.make(storeURL: coreURL)
        let snapshot = try await reopened.fetchWorkDeskOrganization()
        XCTAssertEqual(snapshot.projects.first?.brief, project.brief)
        XCTAssertEqual(snapshot.placements[materialID]?.projectID, project.id)
        XCTAssertEqual(snapshot.placements[materialID]?.position, WorkDeskPoint(x: 98, y: 200))
        XCTAssertEqual(snapshot.placements[materialID]?.isPinned, true)
        let payload = try await reopened.loadWorkMaterialPayload(id: materialID)
        XCTAssertEqual(payload, bytes)
        let preserved = try await reopened.fetchWorkMaterial(id: materialID)
        XCTAssertEqual(preserved, captured)
    }

    func testMissingAndDeletedProjectsNeverHideAnArrivingMaterial() async throws {
        let materialID = UUID()
        let deletedProjectID = UUID()
        let notYetArrivedMaterialID = UUID()
        let current = try await container(version: 18)
        let context = current.newBackgroundContext()
        try await context.perform {
            let material = NSEntityDescription.insertNewObject(forEntityName: "WorkMaterial", into: context)
            material.setValue(materialID, forKey: "id")
            material.setValue(Constants.workboardDeskItemID, forKey: "workItemID")
            material.setValue("note", forKey: "kind")
            material.setValue("Still visible", forKey: "title")
            // A tombstone wins even if a duplicate live project has a later
            // clock. User deletion must not become an accidental resurrection.
            for deleted in [false, true] {
                let project = NSEntityDescription.insertNewObject(forEntityName: "WorkDeskProject", into: context)
                project.setValue(deletedProjectID, forKey: "id")
                project.setValue(deleted ? nil : "Offline duplicate", forKey: "title")
                project.setValue(deleted ? Date.distantPast : Date(), forKey: "updatedAt")
                if deleted { project.setValue(Date.distantPast, forKey: "deletedAt") }
            }
            for id in [materialID, notYetArrivedMaterialID] {
                let placement = NSEntityDescription.insertNewObject(forEntityName: "WorkDeskPlacement", into: context)
                placement.setValue(id, forKey: "materialID")
                placement.setValue(deletedProjectID, forKey: "projectID")
                placement.setValue(700, forKey: "positionX")
                placement.setValue(300, forKey: "positionY")
                placement.setValue(true, forKey: "isPinned")
                placement.setValue(Date(), forKey: "updatedAt")
            }
            try context.save()
        }
        try unload(current)
        let store = isolated.make(storeURL: coreURL)
        let snapshot = try await store.fetchWorkDeskOrganization()
        XCTAssertTrue(snapshot.projects.isEmpty)
        XCTAssertNil(snapshot.placements[materialID]?.projectID)
        XCTAssertNil(snapshot.placements[materialID]?.position)
        XCTAssertEqual(snapshot.placements[materialID]?.isPinned, true)
        XCTAssertNil(snapshot.placements[notYetArrivedMaterialID], "a placement is not itself a material")
        let moved = try await store.applyWorkDeskMutation(.moveMaterial(id: materialID, position: .init(x: 44, y: 88)))
        XCTAssertNil(moved.placements[materialID]?.projectID)
        XCTAssertEqual(moved.placements[materialID]?.position, WorkDeskPoint(x: 44, y: 88),
                       "an orphan displayed on the desk remains freely movable")
        do {
            try await store.applyWorkDeskMutation(.assign(materialIDs: [materialID], projectID: deletedProjectID))
            XCTFail("a duplicate row does not make a deleted project available")
        } catch { XCTAssertEqual(error as? WorkDeskStoreError, .projectNotFound) }
        do {
            try await store.applyWorkDeskMutation(.assign(materialIDs: [materialID], projectID: UUID()))
            XCTFail("an unknown project must be refused")
        } catch { XCTAssertEqual(error as? WorkDeskStoreError, .projectNotFound) }
    }

    private var coreURL: URL { directory.appendingPathComponent("Conversations.sqlite") }

    private func model(version: Int) throws -> NSManagedObjectModel {
        let filename = version == 1 ? "Conversations.mom" : "Conversations \(version).mom"
        let bundles = [Bundle.main, Bundle(for: Self.self)]
        return try XCTUnwrap(bundles.lazy.compactMap { bundle in
            bundle.url(forResource: "Conversations", withExtension: "momd")
                .flatMap { NSManagedObjectModel(contentsOf: $0.appendingPathComponent(filename)) }
        }.first)
    }

    private func container(version: Int) async throws -> NSPersistentContainer {
        let container = NSPersistentContainer(name: "Conversations", managedObjectModel: try model(version: version))
        let core = NSPersistentStoreDescription(url: coreURL)
        core.configuration = "Core"
        let blobs = NSPersistentStoreDescription(url: directory.appendingPathComponent("Conversations-Blobs.sqlite"))
        blobs.configuration = "Blobs"
        for description in [core, blobs] {
            description.shouldMigrateStoreAutomatically = true
            description.shouldInferMappingModelAutomatically = true
        }
        container.persistentStoreDescriptions = [core, blobs]
        let loaded = expectation(description: "both organization migration stores loaded")
        loaded.expectedFulfillmentCount = 2
        var failure: Error?
        container.loadPersistentStores { _, error in
            if let error { failure = error }
            loaded.fulfill()
        }
        await fulfillment(of: [loaded], timeout: 30)
        if let failure { throw failure }
        return container
    }

    private func unload(_ container: NSPersistentContainer) throws {
        for store in container.persistentStoreCoordinator.persistentStores {
            try container.persistentStoreCoordinator.remove(store)
        }
    }
}
