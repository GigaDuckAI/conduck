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

    func testV22AddsOptionalLocationMetadataAndEveryShippedModelCanUpgrade() throws {
        let before = try model(version: 21), after = try model(version: 22)
        XCTAssertEqual(Set(after.entitiesByName.keys).subtracting(before.entitiesByName.keys), ["WorkDeskLocation"])
        for (name, entity) in before.entitiesByName where name != "WorkDeskPlacement" {
            XCTAssertEqual(after.entitiesByName[name]?.versionHash, entity.versionHash,
                           "Adding references must not change captured content or payload models")
        }
        let old = try XCTUnwrap(before.entitiesByName["WorkDeskPlacement"])
        let legacy = try XCTUnwrap(after.entitiesByName["WorkDeskPlacement"])
        XCTAssertEqual(Set(legacy.attributesByName.keys).subtracting(old.attributesByName.keys),
                       ["locationsProjectedAt", "locationsProjectID"])
        let locations = try XCTUnwrap(after.entitiesByName["WorkDeskLocation"])
        XCTAssertTrue(locations.relationshipsByName.isEmpty)
        XCTAssertTrue(locations.uniquenessConstraints.isEmpty)
        for attribute in locations.attributesByName.values {
            XCTAssertTrue(attribute.isOptional)
            XCTAssertNil(attribute.defaultValue)
        }
        XCTAssertTrue(after.entities(forConfigurationName: "Core")!.contains { $0.name == "WorkDeskLocation" })
        XCTAssertEqual(after.entities(forConfigurationName: "Blobs")?.compactMap(\.name), ["WorkMaterialBlob"])
        for version in 1...21 {
            XCTAssertNoThrow(try NSMappingModel.inferredMappingModel(forSourceModel: model(version: version), destinationModel: after))
        }
    }

    func testV23AddsOnlyOptionalProjectColorAndEveryShippedModelCanUpgrade() throws {
        let before = try model(version: 22), after = try model(version: 23)
        XCTAssertEqual(Set(before.entitiesByName.keys), Set(after.entitiesByName.keys))
        for (name, entity) in before.entitiesByName where name != "WorkDeskProject" {
            XCTAssertEqual(after.entitiesByName[name]?.versionHash, entity.versionHash,
                           "Folder color must not change materials, payloads or their locations")
        }
        let old = try XCTUnwrap(before.entitiesByName["WorkDeskProject"])
        let project = try XCTUnwrap(after.entitiesByName["WorkDeskProject"])
        XCTAssertEqual(Set(project.attributesByName.keys).subtracting(old.attributesByName.keys), ["colorID"])
        for (name, attribute) in old.attributesByName {
            XCTAssertEqual(project.attributesByName[name]?.versionHash, attribute.versionHash)
        }
        let color = try XCTUnwrap(project.attributesByName["colorID"])
        XCTAssertEqual(color.attributeType, .stringAttributeType)
        XCTAssertTrue(color.isOptional)
        XCTAssertNil(color.defaultValue)
        XCTAssertTrue(project.relationshipsByName.isEmpty)
        XCTAssertTrue(project.uniquenessConstraints.isEmpty)
        XCTAssertTrue(after.entities(forConfigurationName: "Core")!.contains { $0.name == "WorkDeskProject" })
        XCTAssertEqual(after.entities(forConfigurationName: "Blobs")?.compactMap(\.name), ["WorkMaterialBlob"])
        for version in 1...22 {
            XCTAssertNoThrow(try NSMappingModel.inferredMappingModel(forSourceModel: model(version: version), destinationModel: after))
        }
    }

    func testV22SQLiteProjectsReceiveDistinctColorsAndChosenColorsSurviveReopening() async throws {
        let ids = WorkDeskProjectColor.allCases.map { _ in UUID() }
        let capturedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let old = try await container(version: 22)
        let context = old.newBackgroundContext()
        try await context.perform {
            for id in ids {
                let row = NSEntityDescription.insertNewObject(forEntityName: "WorkDeskProject", into: context)
                row.setValue(id, forKey: "id")
                row.setValue("Existing project", forKey: "title")
                row.setValue("Existing context", forKey: "brief")
                row.setValue("hermes", forKey: "preferredGatewayRef")
                row.setValue(80.0, forKey: "positionX")
                row.setValue(90.0, forKey: "positionY")
                row.setValue(capturedAt, forKey: "createdAt")
                row.setValue(capturedAt, forKey: "updatedAt")
            }
            try context.save()
        }
        try unload(old)
        let store = isolated.make(storeURL: coreURL)
        let migrated = try await store.fetchWorkDeskOrganization()
        XCTAssertEqual(migrated.projects.count, ids.count)
        XCTAssertEqual(Set(migrated.projects.map(\.color)).count, ids.count,
            "Legacy projects get distinct automatic colors without a data rewrite")
        for project in migrated.projects {
            XCTAssertEqual(project.title, "Existing project")
            XCTAssertEqual(project.brief, "Existing context")
            XCTAssertEqual(project.preferredGatewayRef, "hermes")
            XCTAssertEqual(project.position, .init(x: 80, y: 90))
            XCTAssertEqual(project.updatedAt, capturedAt, "Reading a migrated color must not edit the project")
        }
        for (id, color) in zip(ids, WorkDeskProjectColor.allCases) {
            _ = try await store.applyWorkDeskMutation(.setProjectColor(id: id, color: color))
        }
        try await store._unloadForTesting()
        let reopened = isolated.make(storeURL: coreURL)
        let saved = try await reopened.fetchWorkDeskOrganization()
        for (id, color) in zip(ids, WorkDeskProjectColor.allCases) {
            XCTAssertEqual(saved.projects.first { $0.id == id }?.color, color)
        }
    }

    func testUnknownSyncedColorDisplaysAmberAndUnrelatedEditsPreserveItsIdentifier() async throws {
        let id = UUID()
        let current = try await container(version: 23)
        let context = current.newBackgroundContext()
        try await context.perform {
            let row = NSEntityDescription.insertNewObject(forEntityName: "WorkDeskProject", into: context)
            row.setValue(id, forKey: "id")
            row.setValue("Imported project", forKey: "title")
            row.setValue("future-color", forKey: "colorID")
            try context.save()
        }
        try unload(current)
        let store = isolated.make(storeURL: coreURL)
        let imported = try await store.fetchWorkDeskOrganization()
        XCTAssertEqual(imported.projects.first?.color, .amber)
        _ = try await store.applyWorkDeskMutation(.updateProject(id: id, title: "Renamed", brief: "", preferredGatewayRef: nil))
        _ = try await store.applyWorkDeskMutation(.moveProject(id: id, position: .init(x: 100, y: 200)))
        let read = await store.newReadContext()
        try await read.perform {
            let row = try XCTUnwrap(read.fetch(NSFetchRequest<NSManagedObject>(entityName: "WorkDeskProject")).first)
            XCTAssertEqual(row.value(forKey: "colorID") as? String, "future-color")
        }
    }

    func testV21SQLiteAdoptsFiledMaterialOnlyInsideProjectAndKeepsLooseHome() async throws {
        let looseID = UUID(), filedID = UUID(), projectID = UUID()
        let old = try await container(version: 21)
        let context = old.newBackgroundContext()
        try await context.perform {
            let project = NSEntityDescription.insertNewObject(forEntityName: "WorkDeskProject", into: context)
            project.setValue(projectID, forKey: "id")
            project.setValue("Existing", forKey: "title")
            for id in [looseID, filedID] {
                let material = NSEntityDescription.insertNewObject(forEntityName: "WorkMaterial", into: context)
                material.setValue(id, forKey: "id")
                material.setValue(Constants.workboardDeskItemID, forKey: "workItemID")
                material.setValue("note", forKey: "kind")
                material.setValue("Original", forKey: "title")
                let placement = NSEntityDescription.insertNewObject(forEntityName: "WorkDeskPlacement", into: context)
                placement.setValue(id, forKey: "materialID")
                placement.setValue(id == filedID ? projectID : nil, forKey: "projectID")
                placement.setValue(80.0, forKey: "positionX")
                placement.setValue(90.0, forKey: "positionY")
                placement.setValue(700.0, forKey: "homePositionX")
                placement.setValue(800.0, forKey: "homePositionY")
            }
            try context.save()
        }
        try unload(old)
        let store = isolated.make(storeURL: coreURL)
        let migrated = try await store.fetchWorkDeskOrganization()
        XCTAssertEqual(migrated.locations(for: filedID).map(\.location), [.project(projectID)])
        XCTAssertEqual(migrated.locations(for: filedID).first?.position, .init(x: 80, y: 90))
        XCTAssertEqual(migrated.locations(for: looseID).map(\.location), [.home])
        XCTAssertEqual(migrated.locations(for: looseID).first?.position, .init(x: 700, y: 800))
        let added = try await store.applyWorkDeskMutation(.addLocations(materialIDs: [filedID], to: .home,
            positions: [filedID: .init(x: 100, y: 200)], expected: nil))
        XCTAssertEqual(Set(added.locations(for: filedID).map(\.location)), [.home, .project(projectID)])
        let reopened = isolated.make(storeURL: coreURL)
        let persisted = try await reopened.fetchWorkDeskOrganization()
        XCTAssertEqual(persisted.materialLocations, added.materialLocations)
    }

    func testEveryShippedVersionCanInferAnUpgradeToV18() throws {
        let target = try model(version: 18)
        for version in 1...17 {
            let source = try model(version: version)
            XCTAssertNoThrow(try NSMappingModel.inferredMappingModel(forSourceModel: source, destinationModel: target),
                             "model \(version) must remain upgradeable")
        }
    }

    func testV19AddsOnlyOptionalHomeCoordinatesAndEveryShippedModelCanUpgrade() throws {
        let before = try model(version: 18), after = try model(version: 19)
        XCTAssertEqual(Set(before.entitiesByName.keys), Set(after.entitiesByName.keys))
        for (name, entity) in before.entitiesByName where name != "WorkDeskPlacement" {
            XCTAssertEqual(after.entitiesByName[name]?.versionHash, entity.versionHash)
        }
        let placement = try XCTUnwrap(after.entitiesByName["WorkDeskPlacement"])
        let oldPlacement = try XCTUnwrap(before.entitiesByName["WorkDeskPlacement"])
        XCTAssertEqual(Set(placement.attributesByName.keys).subtracting(oldPlacement.attributesByName.keys),
                       ["homePositionX", "homePositionY"])
        for key in ["homePositionX", "homePositionY"] {
            let attribute = try XCTUnwrap(placement.attributesByName[key])
            XCTAssertTrue(attribute.isOptional)
            XCTAssertNil(attribute.defaultValue)
            XCTAssertEqual(attribute.attributeType, .doubleAttributeType)
        }
        for version in 1...18 {
            XCTAssertNoThrow(try NSMappingModel.inferredMappingModel(forSourceModel: model(version: version),
                                                                    destinationModel: after))
        }
    }

    func testV18SQLiteRetainsLooseAndProjectPositionsAndReopensIndependentHomeLayout() async throws {
        let looseID = UUID(), filedID = UUID(), projectID = UUID()
        let old = try await container(version: 18)
        let context = old.newBackgroundContext()
        try await context.perform {
            let project = NSEntityDescription.insertNewObject(forEntityName: "WorkDeskProject", into: context)
            project.setValue(projectID, forKey: "id")
            project.setValue("Existing", forKey: "title")
            project.setValue(true, forKey: "isPinned")
            for id in [looseID, filedID] {
                let material = NSEntityDescription.insertNewObject(forEntityName: "WorkMaterial", into: context)
                material.setValue(id, forKey: "id")
                material.setValue(Constants.workboardDeskItemID, forKey: "workItemID")
                material.setValue("note", forKey: "kind")
                material.setValue("Preserved", forKey: "title")
                let placement = NSEntityDescription.insertNewObject(forEntityName: "WorkDeskPlacement", into: context)
                placement.setValue(id, forKey: "materialID")
                if id == filedID { placement.setValue(projectID, forKey: "projectID") }
                placement.setValue(800, forKey: "positionX")
                placement.setValue(500, forKey: "positionY")
                placement.setValue(true, forKey: "isPinned")
            }
            try context.save()
        }
        try unload(old)
        let upgraded = try await container(version: 19)
        try unload(upgraded)
        let store = isolated.make(storeURL: coreURL)
        let migrated = try await store.fetchWorkDeskOrganization()
        XCTAssertEqual(migrated.placements[looseID]?.resolvedHomePosition, .init(x: 800, y: 500))
        XCTAssertNil(migrated.placements[filedID]?.resolvedHomePosition,
                     "Project coordinates must not overlap migrated loose home cards")
        XCTAssertEqual(migrated.placements[filedID]?.position, .init(x: 800, y: 500))
        try await store.applyWorkDeskMutation(.moveHomeMaterials([
            .init(materialID: filedID, projectID: projectID, position: .init(x: 1200, y: 500))
        ]))
        try await store.applyWorkDeskMutation(.assign(materialIDs: [looseID], projectID: projectID))
        let reopened = isolated.make(storeURL: coreURL)
        let saved = try await reopened.fetchWorkDeskOrganization()
        XCTAssertEqual(saved.placements[looseID]?.homePosition, .init(x: 800, y: 500))
        XCTAssertEqual(saved.placements[filedID]?.homePosition, .init(x: 1200, y: 500))
        XCTAssertEqual(saved.placements[filedID]?.position, .init(x: 800, y: 500))
        XCTAssertEqual(saved.placements[filedID]?.isPinned, true)
        XCTAssertEqual(saved.projects.first?.isPinned, true)
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
