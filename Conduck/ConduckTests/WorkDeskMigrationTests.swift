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

    func testProV22AddsOnlyOptionalArchiveDateAndEveryShippedModelCanUpgrade() throws {
        let before = try model(version: 21), after = try model(named: "Conversations 22 Pro")
        XCTAssertEqual(Set(before.entitiesByName.keys), Set(after.entitiesByName.keys))
        for (name, entity) in before.entitiesByName where name != "WorkDeskProject" {
            XCTAssertEqual(after.entitiesByName[name]?.versionHash, entity.versionHash)
        }
        let project = try XCTUnwrap(after.entitiesByName["WorkDeskProject"])
        let oldProject = try XCTUnwrap(before.entitiesByName["WorkDeskProject"])
        XCTAssertEqual(Set(project.attributesByName.keys).subtracting(oldProject.attributesByName.keys), ["archivedAt"])
        let attribute = try XCTUnwrap(project.attributesByName["archivedAt"])
        XCTAssertTrue(attribute.isOptional)
        XCTAssertNil(attribute.defaultValue)
        XCTAssertEqual(attribute.attributeType, .dateAttributeType)
        for version in 1...21 {
            XCTAssertNoThrow(try NSMappingModel.inferredMappingModel(forSourceModel: model(version: version), destinationModel: after))
        }
    }

    func testProV23CombinesBothV22HistoriesWithoutChangingOtherEntityHashes() throws {
        let locations = try model(version: 22)
        let archive = try model(named: "Conversations 22 Pro")
        let current = try model(named: "Conversations 23 Pro")
        XCTAssertEqual(Set(current.entitiesByName.keys), Set(locations.entitiesByName.keys))
        XCTAssertEqual(Set(current.entitiesByName.keys).subtracting(archive.entitiesByName.keys), ["WorkDeskLocation"])
        for (name, entity) in locations.entitiesByName where name != "WorkDeskProject" {
            XCTAssertEqual(current.entitiesByName[name]?.versionHash, entity.versionHash,
                           "The merge must preserve main's existing \(name) fields")
        }
        for (name, entity) in archive.entitiesByName where name != "WorkDeskPlacement" {
            XCTAssertEqual(current.entitiesByName[name]?.versionHash, entity.versionHash,
                           "The merge must preserve Pro's existing \(name) fields")
        }
        let project = try XCTUnwrap(current.entitiesByName["WorkDeskProject"])
        let mainProject = try XCTUnwrap(locations.entitiesByName["WorkDeskProject"])
        XCTAssertEqual(Set(project.attributesByName.keys).subtracting(mainProject.attributesByName.keys), ["archivedAt"])
        XCTAssertNotEqual(mainProject.versionHash, archive.entitiesByName["WorkDeskProject"]?.versionHash)
        let archiveDate = try XCTUnwrap(project.attributesByName["archivedAt"])
        XCTAssertEqual(archiveDate.attributeType, .dateAttributeType)
        XCTAssertTrue(archiveDate.isOptional)
        XCTAssertNil(archiveDate.defaultValue)
        for name in ["Core", "Blobs"] {
            XCTAssertEqual(Set(current.entities(forConfigurationName: name)!.compactMap(\.name)),
                           Set(locations.entities(forConfigurationName: name)!.compactMap(\.name)))
        }
        for version in 1...22 {
            XCTAssertNoThrow(try NSMappingModel.inferredMappingModel(forSourceModel: model(version: version),
                                                                    destinationModel: current))
        }
        XCTAssertNoThrow(try NSMappingModel.inferredMappingModel(forSourceModel: archive, destinationModel: current))
    }

    func testMainV22SQLiteRetainsLocationsPositionsAndPayloadWhenOpeningV24() async throws {
        try await assertHistoricalSQLiteRetained(modelName: "Conversations 22", hasLocations: true, hasArchive: false)
    }

    func testProV22SQLiteRetainsArchiveHistoryAndPayloadWhenOpeningV24() async throws {
        try await assertHistoricalSQLiteRetained(modelName: "Conversations 22 Pro", hasLocations: false, hasArchive: true)
    }

    func testV24CombinesBothV23HistoriesWithoutChangingStoredProperties() throws {
        let colors = try model(version: 23)
        let archives = try model(named: "Conversations 23 Pro")
        let current = try model(version: 24)
        for previous in [colors, archives] {
            XCTAssertEqual(Set(current.entitiesByName.keys), Set(previous.entitiesByName.keys))
            for (name, entity) in previous.entitiesByName where name != "WorkDeskProject" {
                XCTAssertEqual(current.entitiesByName[name]?.versionHash, entity.versionHash,
                               "Adding project metadata must preserve every existing \(name) hash")
            }
            let oldProject = try XCTUnwrap(previous.entitiesByName["WorkDeskProject"])
            let newProject = try XCTUnwrap(current.entitiesByName["WorkDeskProject"])
            for (name, attribute) in oldProject.attributesByName {
                XCTAssertEqual(newProject.attributesByName[name]?.versionHash, attribute.versionHash,
                               "The merge must preserve the exact stored \(name) definition")
            }
            for configuration in ["Core", "Blobs"] {
                XCTAssertEqual(Set(current.entities(forConfigurationName: configuration)!.compactMap(\.name)),
                               Set(previous.entities(forConfigurationName: configuration)!.compactMap(\.name)))
            }
        }
        let project = try XCTUnwrap(current.entitiesByName["WorkDeskProject"])
        let colorProject = try XCTUnwrap(colors.entitiesByName["WorkDeskProject"])
        let archiveProject = try XCTUnwrap(archives.entitiesByName["WorkDeskProject"])
        XCTAssertEqual(Set(project.attributesByName.keys).subtracting(colorProject.attributesByName.keys), ["archivedAt"])
        XCTAssertEqual(Set(project.attributesByName.keys).subtracting(archiveProject.attributesByName.keys), ["colorID"])
        for (name, type) in [("archivedAt", NSAttributeType.dateAttributeType), ("colorID", .stringAttributeType)] {
            let attribute = try XCTUnwrap(project.attributesByName[name])
            XCTAssertTrue(attribute.isOptional)
            XCTAssertNil(attribute.defaultValue)
            XCTAssertEqual(attribute.attributeType, type)
        }
        for version in 1...23 {
            XCTAssertNoThrow(try NSMappingModel.inferredMappingModel(forSourceModel: model(version: version),
                                                                    destinationModel: current))
        }
        for name in ["Conversations 22 Pro", "Conversations 23 Pro"] {
            XCTAssertNoThrow(try NSMappingModel.inferredMappingModel(forSourceModel: model(named: name),
                                                                    destinationModel: current))
        }
    }

    func testMainV23SQLiteRetainsColorsLocationsAndPayloadWhenOpeningV24() async throws {
        try await assertHistoricalSQLiteRetained(modelName: "Conversations 23", hasLocations: true,
                                                 hasArchive: false, hasColor: true)
    }

    func testProV23SQLiteRetainsArchivesLocationsAndPayloadWhenOpeningV24() async throws {
        try await assertHistoricalSQLiteRetained(modelName: "Conversations 23 Pro", hasLocations: true, hasArchive: true)
    }

    private func assertHistoricalSQLiteRetained(
        modelName: String, hasLocations: Bool, hasArchive: Bool, hasColor: Bool = false
    ) async throws {
        let projectID = UUID(), secondProjectID = UUID(), materialID = UUID(), conversationID = UUID()
        let stamp = Date(timeIntervalSince1970: 1_800_000_000)
        let bytes = Data("Captured before the model histories merged".utf8)
        let old = try await container(model: model(named: modelName))
        let context = old.newBackgroundContext()
        try await context.perform {
            let item = NSEntityDescription.insertNewObject(forEntityName: "WorkItem", into: context)
            item.setValue(Constants.workboardDeskItemID, forKey: "id")
            item.setValue(stamp, forKey: "createdAt")
            item.setValue(stamp, forKey: "updatedAt")
            for id in [projectID, secondProjectID] {
                let project = NSEntityDescription.insertNewObject(forEntityName: "WorkDeskProject", into: context)
                project.setValue(id, forKey: "id")
                project.setValue(id == projectID ? "Historical project" : "Second project", forKey: "title")
                project.setValue("Keep this brief", forKey: "brief")
                project.setValue(stamp, forKey: "updatedAt")
                if hasArchive, id == projectID { project.setValue(stamp, forKey: "archivedAt") }
                if hasColor { project.setValue(id == projectID ? "lavender" : "slate", forKey: "colorID") }
            }
            let material = NSEntityDescription.insertNewObject(forEntityName: "WorkMaterial", into: context)
            material.setValue(materialID, forKey: "id")
            material.setValue(Constants.workboardDeskItemID, forKey: "workItemID")
            material.setValue("file", forKey: "kind")
            material.setValue("Historical capture", forKey: "title")
            material.setValue("old.txt", forKey: "filename")
            material.setValue("text/plain", forKey: "mimeType")
            material.setValue("syncedPayload", forKey: "storageMode")
            material.setValue("migration-fixture", forKey: "contentHash")
            material.setValue(Int64(bytes.count), forKey: "byteSize")
            material.setValue(stamp, forKey: "createdAt")
            material.setValue(stamp, forKey: "updatedAt")
            let blob = NSEntityDescription.insertNewObject(forEntityName: "WorkMaterialBlob", into: context)
            blob.setValue(materialID, forKey: "materialID")
            blob.setValue(bytes, forKey: "payload")
            blob.setValue(Int64(bytes.count), forKey: "byteSize")
            blob.setValue("migration-fixture", forKey: "contentHash")
            blob.setValue(stamp, forKey: "createdAt")
            blob.setValue(stamp, forKey: "updatedAt")
            let placement = NSEntityDescription.insertNewObject(forEntityName: "WorkDeskPlacement", into: context)
            placement.setValue(materialID, forKey: "materialID")
            placement.setValue(projectID, forKey: "projectID")
            placement.setValue(80.0, forKey: "positionX")
            placement.setValue(90.0, forKey: "positionY")
            placement.setValue(stamp, forKey: "updatedAt")
            if hasLocations {
                placement.setValue(stamp, forKey: "locationsProjectedAt")
                placement.setValue(projectID, forKey: "locationsProjectID")
                for (rank, id) in [nil, projectID, secondProjectID].enumerated() {
                    let location = NSEntityDescription.insertNewObject(forEntityName: "WorkDeskLocation", into: context)
                    location.setValue(materialID, forKey: "materialID")
                    location.setValue(id, forKey: "projectID")
                    location.setValue(true, forKey: "isPresent")
                    location.setValue(Double(rank + 100), forKey: "positionX")
                    location.setValue(Double(rank + 200), forKey: "positionY")
                    location.setValue(Double(rank), forKey: "sortRank")
                    location.setValue(true, forKey: "positionWasSeeded")
                    location.setValue(stamp, forKey: "updatedAt")
                    location.setValue(UUID(), forKey: "revision")
                }
            }
            let conversation = NSEntityDescription.insertNewObject(forEntityName: "Conversation", into: context)
            conversation.setValue(conversationID, forKey: "id")
            conversation.setValue(projectID, forKey: "projectID")
            conversation.setValue("openrouter", forKey: "backend")
            try context.save()
        }
        try unload(old)

        // Open the actual current app store rather than supplying a destination model:
        // this also proves the bundle can discover either historical source.
        let store = isolated.make(storeURL: coreURL)
        let migrated = try await store.fetchWorkDeskOrganization()
        XCTAssertEqual(Set(migrated.projects.map(\.id)), [projectID, secondProjectID])
        XCTAssertEqual(migrated.projects.first { $0.id == projectID }?.archivedAt, hasArchive ? stamp : nil)
        XCTAssertEqual(migrated.projects.first { $0.id == projectID }?.brief, "Keep this brief")
        if hasColor {
            XCTAssertEqual(migrated.projects.first { $0.id == projectID }?.color, .lavender)
            XCTAssertEqual(migrated.projects.first { $0.id == secondProjectID }?.color, .slate)
        }
        let memberships = migrated.locations(for: materialID)
        if hasLocations {
            XCTAssertEqual(Set(memberships.map(\.location)), [.home, .project(projectID), .project(secondProjectID)])
            for (rank, location) in [WorkDeskLocation.home, .project(projectID), .project(secondProjectID)].enumerated() {
                let saved = try XCTUnwrap(memberships.first { $0.location == location })
                XCTAssertEqual(saved.position, .init(x: Double(rank + 100), y: Double(rank + 200)))
                XCTAssertEqual(saved.sortRank, Double(rank))
                XCTAssertTrue(saved.positionWasSeeded)
            }
        } else {
            XCTAssertEqual(memberships.map(\.location), [.project(projectID)])
            XCTAssertEqual(memberships.first?.position, .init(x: 80, y: 90))
        }
        let payload = try await store.loadWorkMaterialPayload(id: materialID)
        let material = try await store.fetchWorkMaterial(id: materialID)
        let history = try await store.fetchProjectConversations(projectID: projectID)
        XCTAssertEqual(payload, bytes)
        XCTAssertEqual(material?.title, "Historical capture")
        XCTAssertEqual(material?.updatedAt, stamp)
        XCTAssertEqual(history.map(\.id), [conversationID])
        try await store._unloadForTesting()
        let reopened = isolated.make(storeURL: coreURL)
        let preserved = try await reopened.fetchWorkDeskOrganization()
        XCTAssertEqual(preserved.projects, migrated.projects)
        XCTAssertEqual(preserved.materialLocations, migrated.materialLocations)
        try await reopened._unloadForTesting()
    }

    func testV21OverLimitProjectsMigrateRemainEditableAndArchiveReopens() async throws {
        let ids = (0..<(Constants.maxActiveWorkProjects + 1)).map { _ in UUID() }
        let materialID = UUID(), conversationID = UUID()
        let old = try await container(version: 21)
        let context = old.newBackgroundContext()
        try await context.perform {
            for (index, id) in ids.enumerated() {
                let row = NSEntityDescription.insertNewObject(forEntityName: "WorkDeskProject", into: context)
                row.setValue(id, forKey: "id")
                row.setValue("Existing \(index)", forKey: "title")
                row.setValue("Preserved brief", forKey: "brief")
                row.setValue(Date(), forKey: "updatedAt")
            }
            let material = NSEntityDescription.insertNewObject(forEntityName: "WorkMaterial", into: context)
            material.setValue(materialID, forKey: "id")
            material.setValue(Constants.workboardDeskItemID, forKey: "workItemID")
            material.setValue("note", forKey: "kind")
            material.setValue("Preserved words", forKey: "textContent")
            let placement = NSEntityDescription.insertNewObject(forEntityName: "WorkDeskPlacement", into: context)
            placement.setValue(materialID, forKey: "materialID")
            placement.setValue(ids[0], forKey: "projectID")
            let conversation = NSEntityDescription.insertNewObject(forEntityName: "Conversation", into: context)
            conversation.setValue(conversationID, forKey: "id")
            conversation.setValue(ids[0], forKey: "projectID")
            conversation.setValue("openrouter", forKey: "backend")
            try context.save()
        }
        try unload(old)
        let store = isolated.make(storeURL: coreURL)
        let migrated = try await store.fetchWorkDeskOrganization()
        XCTAssertEqual(Set(migrated.projects.map(\.id)), Set(ids))
        XCTAssertTrue(migrated.projects.allSatisfy { !$0.isArchived }, "Old rows remain active without truncation")
        XCTAssertEqual(migrated.placements[materialID]?.projectID, ids[0])
        let changed = try await store.applyWorkDeskMutation(.updateProject(id: ids[0], title: "Still editable",
            brief: "Preserved brief", preferredGatewayRef: nil))
        XCTAssertEqual(changed.projects.first { $0.id == ids[0] }?.title, "Still editable")
        do {
            try await store.applyWorkDeskMutation(.createProject(.init(title: "Extra"), materialIDs: []))
            XCTFail("An old or imported over-limit collection cannot claim another slot")
        } catch { XCTAssertEqual(error as? WorkDeskStoreError, .activeProjectLimitReached) }
        try await store.applyWorkDeskMutation(.archiveProject(id: ids[0], isArchived: true))
        try await store._unloadForTesting()
        let reopened = isolated.make(storeURL: coreURL)
        let preserved = try await reopened.fetchWorkDeskOrganization()
        XCTAssertEqual(preserved.projects.count, ids.count)
        XCTAssertEqual(preserved.projects.first { $0.id == ids[0] }?.isArchived, true)
        XCTAssertEqual(preserved.placements, changed.placements)
        let material = try await reopened.fetchWorkMaterial(id: materialID)
        let history = try await reopened.fetchProjectConversations(projectID: ids[0])
        XCTAssertEqual(material?.textContent, "Preserved words")
        XCTAssertEqual(history.map(\.id), [conversationID])
        try await reopened._unloadForTesting()
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
        try model(named: version == 1 ? "Conversations" : "Conversations \(version)")
    }

    private func model(named name: String) throws -> NSManagedObjectModel {
        let filename = "\(name).mom"
        let bundles = [Bundle.main, Bundle(for: Self.self)]
        return try XCTUnwrap(bundles.lazy.compactMap { bundle in
            bundle.url(forResource: "Conversations", withExtension: "momd")
                .flatMap { NSManagedObjectModel(contentsOf: $0.appendingPathComponent(filename)) }
        }.first)
    }

    private func container(version: Int) async throws -> NSPersistentContainer {
        try await container(model: model(version: version))
    }

    private func container(model: NSManagedObjectModel) async throws -> NSPersistentContainer {
        let container = NSPersistentContainer(name: "Conversations", managedObjectModel: model)
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
