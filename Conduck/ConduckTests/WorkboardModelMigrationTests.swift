// SPDX-License-Identifier: Apache-2.0

// ConduckTests
// WorkboardModelMigrationTests.swift
//
// Schema and real SQLite migration contracts for the Workboard's model
// versions. The three Workboard entities are additive, CloudKit-compatible,
// relationship-free, and cannot alter any shipped conversation entity. Binary
// material/snapshot fields stay external assets so a rich card does not inflate
// every list fetch. v15 adds exactly one presentation column, so an account
// that never resized a card carries nothing new. v16 splits the model into two
// CloudKit configurations so payload blobs live in a store the Watch never
// mounts, and a shipped default-configuration store must open as `Core`
// untouched.

import XCTest
import CoreData
@testable import Conduck

final class WorkboardModelMigrationTests: XCTestCase {
    private var storeURL: URL!
    private var blobStoreURL: URL!

    override func setUp() {
        super.setUp()
        let root = FileManager.default.temporaryDirectory
        let stem = "conversations-workboard-\(UUID().uuidString)"
        storeURL = root.appendingPathComponent("\(stem).sqlite")
        blobStoreURL = root.appendingPathComponent("\(stem)-blobs.sqlite")
    }

    override func tearDown() {
        for url in [storeURL, blobStoreURL].compactMap({ $0 }) {
            removeStoreFiles(at: url)
        }
        storeURL = nil
        blobStoreURL = nil
        super.tearDown()
    }

    func testV14AddsOnlyThreeRelationshipFreeWorkboardEntities() throws {
        let v13 = try requiredModel(named: "Conversations 13.mom")
        let v14 = try requiredModel(named: "Conversations 14.mom")
        let existing = Set(v13.entitiesByName.keys)
        XCTAssertEqual(
            Set(v14.entitiesByName.keys).subtracting(existing),
            ["WorkItem", "WorkMaterial", "WorkDispatch"]
        )

        for entityName in existing {
            let before = try XCTUnwrap(v13.entitiesByName[entityName])
            let after = try XCTUnwrap(v14.entitiesByName[entityName])
            XCTAssertEqual(Set(after.attributesByName.keys), Set(before.attributesByName.keys),
                           "v14 must not mutate shipped \(entityName) columns")
            XCTAssertEqual(Set(after.relationshipsByName.keys), Set(before.relationshipsByName.keys),
                           "v14 must not mutate shipped \(entityName) relationships")
        }

        for entityName in ["WorkItem", "WorkMaterial", "WorkDispatch"] {
            let entity = try XCTUnwrap(v14.entitiesByName[entityName])
            XCTAssertTrue(entity.relationshipsByName.isEmpty,
                          "UUID foreign keys keep deletion independent across Workboard and Chat")
            XCTAssertTrue(entity.uniquenessConstraints.isEmpty,
                          "CloudKit mirrored models cannot carry unique constraints")
            XCTAssertFalse(entity.attributesByName.isEmpty)
            for attribute in entity.attributesByName.values {
                XCTAssertTrue(attribute.isOptional, "\(entityName).\(attribute.name) must be optional")
                XCTAssertNil(attribute.defaultValue,
                             "migrating an old account may not invent \(entityName).\(attribute.name)")
            }
        }

        let material = try XCTUnwrap(v14.entitiesByName["WorkMaterial"])
        XCTAssertTrue(try XCTUnwrap(material.attributesByName["payload"]).allowsExternalBinaryDataStorage)
        XCTAssertTrue(try XCTUnwrap(material.attributesByName["thumbnailData"]).allowsExternalBinaryDataStorage)
        let dispatch = try XCTUnwrap(v14.entitiesByName["WorkDispatch"])
        XCTAssertTrue(
            try XCTUnwrap(dispatch.attributesByName["briefSnapshotData"])
                .allowsExternalBinaryDataStorage
        )
        let item = try XCTUnwrap(v14.entitiesByName["WorkItem"])
        let boardOrder = try XCTUnwrap(item.attributesByName["boardOrder"])
        XCTAssertEqual(boardOrder.attributeType, .integer64AttributeType)
        XCTAssertTrue(boardOrder.isOptional)
        XCTAssertNil(boardOrder.defaultValue,
                     "existing and newly captured work stays unranked until a deliberate reorder")
    }

    func testV13SQLiteMigratesToV14WithoutChangingConversationHistory() async throws {
        let v13 = try requiredModel(named: "Conversations 13.mom")
        let v14 = try requiredModel(named: "Conversations 14.mom")
        let conversationID = UUID()
        let messageID = UUID()

        do {
            let container = try await loadStore(model: v13)
            let context = container.newBackgroundContext()
            try await context.perform {
                let conversation = NSEntityDescription.insertNewObject(
                    forEntityName: "Conversation", into: context
                )
                conversation.setValue(conversationID, forKey: "id")
                conversation.setValue("openrouter", forKey: "backend")
                conversation.setValue(Date(timeIntervalSince1970: 1_800_000_000), forKey: "createdAt")
                conversation.setValue(Date(timeIntervalSince1970: 1_800_000_001), forKey: "lastActivityAt")
                conversation.setValue(UUID().uuidString, forKey: "sessionID")

                let message = NSEntityDescription.insertNewObject(forEntityName: "Message", into: context)
                message.setValue(messageID, forKey: "id")
                message.setValue("user", forKey: "role")
                message.setValue("Keep this exact brief", forKey: "text")
                message.setValue(Date(timeIntervalSince1970: 1_800_000_001), forKey: "createdAt")
                message.setValue("phone", forKey: "sourceDevice")
                message.setValue("failed", forKey: "status")
                message.setValue(conversation, forKey: "conversation")
                try context.save()
            }
            for store in container.persistentStoreCoordinator.persistentStores {
                try container.persistentStoreCoordinator.remove(store)
            }
        }

        let container = try await loadStore(model: v14)
        let context = container.newBackgroundContext()
        try await context.perform {
            let conversationRequest = NSFetchRequest<NSManagedObject>(entityName: "Conversation")
            conversationRequest.predicate = NSPredicate(format: "id == %@", conversationID as CVarArg)
            let conversation = try XCTUnwrap(context.fetch(conversationRequest).first)
            XCTAssertEqual(conversation.value(forKey: "backend") as? String, "openrouter")

            let messageRequest = NSFetchRequest<NSManagedObject>(entityName: "Message")
            messageRequest.predicate = NSPredicate(format: "id == %@", messageID as CVarArg)
            let message = try XCTUnwrap(context.fetch(messageRequest).first)
            XCTAssertEqual(message.value(forKey: "text") as? String, "Keep this exact brief")
            XCTAssertEqual(message.value(forKey: "status") as? String, "failed")

            for entity in ["WorkItem", "WorkMaterial", "WorkDispatch"] {
                XCTAssertEqual(try context.count(for: NSFetchRequest(entityName: entity)), 0)
            }

            let workItem = NSEntityDescription.insertNewObject(forEntityName: "WorkItem", into: context)
            let workItemID = UUID()
            workItem.setValue(workItemID, forKey: "id")
            workItem.setValue("New brief", forKey: "title")
            workItem.setValue(Date(), forKey: "createdAt")
            try context.save()
            XCTAssertEqual(workItem.value(forKey: "id") as? UUID, workItemID)
        }
    }

    func testV15AddsOnlyTheMaterialCardSizeColumn() throws {
        let v14 = try requiredModel(named: "Conversations 14.mom")
        let v15 = try requiredModel(named: "Conversations 15.mom")
        XCTAssertEqual(Set(v15.entitiesByName.keys), Set(v14.entitiesByName.keys),
                       "a card-size column is not a reason to add an entity")

        for entityName in v14.entitiesByName.keys {
            let before = try XCTUnwrap(v14.entitiesByName[entityName])
            let after = try XCTUnwrap(v15.entitiesByName[entityName])
            XCTAssertEqual(Set(after.relationshipsByName.keys), Set(before.relationshipsByName.keys),
                           "v15 must not mutate \(entityName) relationships")
            let added = Set(after.attributesByName.keys)
                .subtracting(Set(before.attributesByName.keys))
            XCTAssertEqual(added, entityName == "WorkMaterial" ? ["cardSize"] : [],
                           "v15 must not add columns to \(entityName)")
            XCTAssertTrue(
                Set(before.attributesByName.keys).isSubset(of: Set(after.attributesByName.keys)),
                "v15 must not drop a shipped \(entityName) column"
            )
        }

        let cardSize = try XCTUnwrap(
            v15.entitiesByName["WorkMaterial"]?.attributesByName["cardSize"]
        )
        XCTAssertEqual(cardSize.attributeType, .stringAttributeType)
        XCTAssertTrue(cardSize.isOptional)
        XCTAssertNil(cardSize.defaultValue,
                     "an unresized card stores nothing; absence is the standard size")
        XCTAssertTrue(
            try XCTUnwrap(v15.entitiesByName["WorkMaterial"]).uniquenessConstraints.isEmpty,
            "CloudKit mirrored models cannot carry unique constraints"
        )
    }

    func testV14SQLiteMigratesToV15LeavingExistingMaterialsUnsized() async throws {
        let v14 = try requiredModel(named: "Conversations 14.mom")
        let v15 = try requiredModel(named: "Conversations 15.mom")
        let itemID = UUID()
        let materialID = UUID()

        do {
            let container = try await loadStore(model: v14)
            let context = container.newBackgroundContext()
            try await context.perform {
                let item = NSEntityDescription.insertNewObject(forEntityName: "WorkItem", into: context)
                item.setValue(itemID, forKey: "id")
                item.setValue("Existing brief", forKey: "title")
                item.setValue(Date(timeIntervalSince1970: 1_800_000_000), forKey: "createdAt")
                item.setValue(Date(timeIntervalSince1970: 1_800_000_000), forKey: "updatedAt")

                let material = NSEntityDescription.insertNewObject(
                    forEntityName: "WorkMaterial", into: context
                )
                material.setValue(materialID, forKey: "id")
                material.setValue(itemID, forKey: "workItemID")
                material.setValue("note", forKey: "kind")
                material.setValue("Captured before v15", forKey: "title")
                material.setValue(NSNumber(value: Int32(3)), forKey: "sequence")
                material.setValue(Date(timeIntervalSince1970: 1_800_000_001), forKey: "createdAt")
                material.setValue(Date(timeIntervalSince1970: 1_800_000_001), forKey: "updatedAt")
                try context.save()
            }
            for store in container.persistentStoreCoordinator.persistentStores {
                try container.persistentStoreCoordinator.remove(store)
            }
        }

        let container = try await loadStore(model: v15)
        let context = container.newBackgroundContext()
        try await context.perform {
            let request = NSFetchRequest<NSManagedObject>(entityName: "WorkMaterial")
            request.predicate = NSPredicate(format: "id == %@", materialID as CVarArg)
            let material = try XCTUnwrap(context.fetch(request).first)
            XCTAssertEqual(material.value(forKey: "title") as? String, "Captured before v15")
            XCTAssertEqual((material.value(forKey: "sequence") as? NSNumber)?.int32Value, 3)
            XCTAssertNil(material.value(forKey: "cardSize"),
                         "a migrated card must not be invented into a deliberate size")
            XCTAssertEqual(
                material.value(forKey: "updatedAt") as? Date,
                Date(timeIntervalSince1970: 1_800_000_001),
                "migration may not move a revision-bearing timestamp"
            )

            material.setValue("large", forKey: "cardSize")
            try context.save()
            XCTAssertEqual(material.value(forKey: "cardSize") as? String, "large")
        }
    }

    func testV16AddsOnlyTheBlobEntityAndTwoCloudKitConfigurations() throws {
        let v15 = try requiredModel(named: "Conversations 15.mom")
        let v16 = try requiredModel(named: "Conversations 16.mom")
        let existing = Set(v15.entitiesByName.keys)
        XCTAssertEqual(
            Set(v16.entitiesByName.keys).subtracting(existing),
            ["WorkMaterialBlob"],
            "byte sync adds the blob entity and nothing else"
        )
        XCTAssertTrue(
            existing.isSubset(of: Set(v16.entitiesByName.keys)),
            "v16 must not drop a shipped entity"
        )

        for entityName in existing {
            let before = try XCTUnwrap(v15.entitiesByName[entityName])
            let after = try XCTUnwrap(v16.entitiesByName[entityName])
            XCTAssertEqual(Set(after.attributesByName.keys), Set(before.attributesByName.keys),
                           "v16 must not mutate shipped \(entityName) columns")
            XCTAssertEqual(Set(after.relationshipsByName.keys), Set(before.relationshipsByName.keys),
                           "v16 must not mutate shipped \(entityName) relationships")
            XCTAssertEqual(
                after.versionHash, before.versionHash,
                "adding an entity and configurations must leave \(entityName) migration-free"
            )
        }

        XCTAssertTrue(
            v15.configurations.filter { $0 != "PF_DEFAULT_CONFIGURATION_NAME" }.isEmpty,
            "the shipped store is a default-configuration store"
        )
        XCTAssertEqual(
            Set(v16.configurations).subtracting(["PF_DEFAULT_CONFIGURATION_NAME"]),
            ["Core", "Blobs"]
        )
        XCTAssertEqual(
            Set((v16.entities(forConfigurationName: "Core") ?? []).compactMap(\.name)),
            existing,
            "Core carries exactly the entities the shipped store already holds"
        )
        XCTAssertEqual(
            Set((v16.entities(forConfigurationName: "Blobs") ?? []).compactMap(\.name)),
            ["WorkMaterialBlob"],
            "the Watch excludes payloads by never mounting this store"
        )

        let blob = try XCTUnwrap(v16.entitiesByName["WorkMaterialBlob"])
        XCTAssertTrue(blob.relationshipsByName.isEmpty,
                      "Core Data forbids a relationship across configurations; the key is a UUID")
        XCTAssertTrue(blob.uniquenessConstraints.isEmpty,
                      "CloudKit mirrored models cannot carry unique constraints")
        XCTAssertEqual(
            Set(blob.attributesByName.keys),
            ["materialID", "payload", "byteSize", "contentHash", "createdAt", "updatedAt"]
        )
        for attribute in blob.attributesByName.values {
            XCTAssertTrue(attribute.isOptional, "WorkMaterialBlob.\(attribute.name) must be optional")
            XCTAssertNil(attribute.defaultValue,
                         "an imported blob may not have WorkMaterialBlob.\(attribute.name) invented")
        }
        let payload = try XCTUnwrap(blob.attributesByName["payload"])
        XCTAssertEqual(payload.attributeType, .binaryDataAttributeType)
        XCTAssertTrue(payload.allowsExternalBinaryDataStorage,
                      "payload bytes ride CloudKit as an asset, not inside the record")
        XCTAssertEqual(
            try XCTUnwrap(blob.attributesByName["byteSize"]).attributeType,
            .integer64AttributeType
        )
        XCTAssertEqual(
            try XCTUnwrap(blob.attributesByName["materialID"]).attributeType,
            .UUIDAttributeType
        )
    }

    func testV15SQLiteReopensAsCoreInV16BesideAWritableBlobStore() async throws {
        let v15 = try requiredModel(named: "Conversations 15.mom")
        let v16 = try requiredModel(named: "Conversations 16.mom")
        let itemID = UUID()
        let materialID = UUID()
        let thumbnail = Data(repeating: 0xA5, count: 400_000)

        do {
            let container = try await loadStore(model: v15)
            let context = container.newBackgroundContext()
            try await context.perform {
                let item = NSEntityDescription.insertNewObject(forEntityName: "WorkItem", into: context)
                item.setValue(itemID, forKey: "id")
                item.setValue("Captured before byte sync", forKey: "title")
                item.setValue(Date(timeIntervalSince1970: 1_800_000_000), forKey: "createdAt")
                item.setValue(Date(timeIntervalSince1970: 1_800_000_000), forKey: "updatedAt")

                let material = NSEntityDescription.insertNewObject(
                    forEntityName: "WorkMaterial", into: context
                )
                material.setValue(materialID, forKey: "id")
                material.setValue(itemID, forKey: "workItemID")
                material.setValue("image", forKey: "kind")
                material.setValue("Screenshot", forKey: "title")
                material.setValue("localVault", forKey: "storageMode")
                material.setValue("large", forKey: "cardSize")
                material.setValue(thumbnail, forKey: "thumbnailData")
                material.setValue(NSNumber(value: Int64(2_048)), forKey: "byteSize")
                material.setValue(Date(timeIntervalSince1970: 1_800_000_001), forKey: "createdAt")
                material.setValue(Date(timeIntervalSince1970: 1_800_000_001), forKey: "updatedAt")
                try context.save()
            }
            try unload(container)
        }

        let payload = Data(repeating: 0x5A, count: 5 * 1024 * 1024)
        do {
            let container = try await loadCoreAndBlobStores(model: v16)
            let coordinator = container.persistentStoreCoordinator
            XCTAssertEqual(coordinator.persistentStores.count, 2,
                           "a mis-pointed configuration mounts silently; count the stores")
            let mounted = Dictionary(
                uniqueKeysWithValues: coordinator.persistentStores.map {
                    ($0.configurationName, $0.url?.lastPathComponent)
                }
            )
            XCTAssertEqual(mounted["Core"], storeURL.lastPathComponent,
                           "Core must keep the shipped file; a new URL would strand every row")
            XCTAssertEqual(mounted["Blobs"], blobStoreURL.lastPathComponent)

            let context = container.newBackgroundContext()
            try await context.perform {
                let request = NSFetchRequest<NSManagedObject>(entityName: "WorkMaterial")
                request.predicate = NSPredicate(format: "id == %@", materialID as CVarArg)
                let material = try XCTUnwrap(context.fetch(request).first)
                XCTAssertEqual(material.value(forKey: "title") as? String, "Screenshot")
                XCTAssertEqual(material.value(forKey: "cardSize") as? String, "large")
                XCTAssertEqual(material.value(forKey: "thumbnailData") as? Data, thumbnail)
                XCTAssertEqual(
                    material.value(forKey: "updatedAt") as? Date,
                    Date(timeIntervalSince1970: 1_800_000_001),
                    "opening under a named configuration may not move a revision-bearing timestamp"
                )
                XCTAssertEqual(
                    try context.count(for: NSFetchRequest(entityName: "WorkMaterialBlob")), 0
                )

                let blob = NSEntityDescription.insertNewObject(
                    forEntityName: "WorkMaterialBlob", into: context
                )
                blob.setValue(materialID, forKey: "materialID")
                blob.setValue(payload, forKey: "payload")
                blob.setValue(NSNumber(value: Int64(payload.count)), forKey: "byteSize")
                blob.setValue("sha256-fixture", forKey: "contentHash")
                blob.setValue(Date(timeIntervalSince1970: 1_800_000_002), forKey: "createdAt")
                blob.setValue(Date(timeIntervalSince1970: 1_800_000_002), forKey: "updatedAt")
                material.setValue("syncedPayload", forKey: "storageMode")
                // Both stores commit from one save; Core Data routes each row by
                // configuration membership, so no explicit store assignment.
                try context.save()

                XCTAssertEqual(blob.objectID.persistentStore?.url, self.blobStoreURL)
                XCTAssertEqual(material.objectID.persistentStore?.url, self.storeURL)
            }
            try unload(container)
        }

        let container = try await loadCoreAndBlobStores(model: v16)
        let context = container.newBackgroundContext()
        try await context.perform {
            let request = NSFetchRequest<NSManagedObject>(entityName: "WorkMaterialBlob")
            request.predicate = NSPredicate(format: "materialID == %@", materialID as CVarArg)
            let blob = try XCTUnwrap(context.fetch(request).first)
            XCTAssertEqual(blob.value(forKey: "payload") as? Data, payload,
                           "an external payload must survive close and reopen whole")
            XCTAssertEqual((blob.value(forKey: "byteSize") as? NSNumber)?.int64Value,
                           Int64(payload.count))

            let materialRequest = NSFetchRequest<NSManagedObject>(entityName: "WorkMaterial")
            materialRequest.predicate = NSPredicate(format: "id == %@", materialID as CVarArg)
            let material = try XCTUnwrap(context.fetch(materialRequest).first)
            XCTAssertEqual(material.value(forKey: "storageMode") as? String, "syncedPayload")
            XCTAssertNil(material.value(forKey: "payload"),
                         "synced bytes live in the blob row; the material column stays unwritten")

            // Availability resolves from metadata alone — projecting payload here
            // would load every byte on every board refresh.
            let projection = NSFetchRequest<NSDictionary>(entityName: "WorkMaterialBlob")
            projection.resultType = .dictionaryResultType
            projection.propertiesToFetch = ["materialID", "byteSize", "contentHash", "updatedAt"]
            let rows = try context.fetch(projection)
            XCTAssertEqual(rows.count, 1)
            let row = try XCTUnwrap(rows.first)
            XCTAssertEqual(row["contentHash"] as? String, "sha256-fixture")
            XCTAssertNil(row["payload"])
        }
        try unload(container)
    }

    private func requiredModel(named name: String) throws -> NSManagedObjectModel {
        let bundles = [Bundle.main, Bundle(for: Self.self)]
        return try XCTUnwrap(
            bundles.lazy.compactMap { bundle -> NSManagedObjectModel? in
                guard let momd = bundle.url(forResource: "Conversations", withExtension: "momd")
                else { return nil }
                return NSManagedObjectModel(contentsOf: momd.appendingPathComponent(name))
            }.first,
            "compiled \(name) must remain in Conversations.momd"
        )
    }

    private func loadStore(model: NSManagedObjectModel) async throws -> NSPersistentContainer {
        let container = NSPersistentContainer(name: "Conversations", managedObjectModel: model)
        let description = NSPersistentStoreDescription(url: storeURL)
        description.shouldMigrateStoreAutomatically = true
        description.shouldInferMappingModelAutomatically = true
        container.persistentStoreDescriptions = [description]
        let loaded = expectation(description: "store loaded")
        var loadError: Error?
        container.loadPersistentStores { _, error in
            loadError = error
            loaded.fulfill()
        }
        await fulfillment(of: [loaded], timeout: 15)
        if let loadError { throw loadError }
        return container
    }

    /// The production topology: one coordinator, the shipped file mounted as
    /// `Core` and a sibling file mounted as `Blobs`.
    private func loadCoreAndBlobStores(
        model: NSManagedObjectModel
    ) async throws -> NSPersistentContainer {
        let container = NSPersistentContainer(name: "Conversations", managedObjectModel: model)
        let core = NSPersistentStoreDescription(url: storeURL)
        core.configuration = "Core"
        let blobs = NSPersistentStoreDescription(url: blobStoreURL)
        blobs.configuration = "Blobs"
        for description in [core, blobs] {
            description.shouldMigrateStoreAutomatically = true
            description.shouldInferMappingModelAutomatically = true
        }
        container.persistentStoreDescriptions = [core, blobs]
        let loaded = expectation(description: "stores loaded")
        loaded.expectedFulfillmentCount = 2
        var loadErrors: [Error] = []
        container.loadPersistentStores { _, error in
            if let error { loadErrors.append(error) }
            loaded.fulfill()
        }
        await fulfillment(of: [loaded], timeout: 30)
        if let first = loadErrors.first { throw first }
        return container
    }

    private func unload(_ container: NSPersistentContainer) throws {
        for store in container.persistentStoreCoordinator.persistentStores {
            try container.persistentStoreCoordinator.remove(store)
        }
    }

    /// External binary payloads live in a `_SUPPORT` directory beside each
    /// store, so a per-store cleanup has to take four paths, not one.
    private func removeStoreFiles(at url: URL) {
        let fm = FileManager.default
        let stem = url.deletingPathExtension()
        try? fm.removeItem(at: url)
        try? fm.removeItem(at: stem.appendingPathExtension("sqlite-wal"))
        try? fm.removeItem(at: stem.appendingPathExtension("sqlite-shm"))
        try? fm.removeItem(
            at: url.deletingLastPathComponent()
                .appendingPathComponent(".\(stem.lastPathComponent)_SUPPORT")
        )
    }
}
