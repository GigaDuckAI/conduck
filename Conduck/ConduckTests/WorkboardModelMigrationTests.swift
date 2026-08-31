// SPDX-License-Identifier: Apache-2.0

// ConduckTests
// WorkboardModelMigrationTests.swift
//
// Schema and real SQLite migration contracts for the Workboard's model
// versions. The three Workboard entities are additive, CloudKit-compatible,
// relationship-free, and cannot alter any shipped conversation entity. Binary
// material/snapshot fields stay external assets so a rich card does not inflate
// every list fetch. v15 adds exactly one presentation column, so an account
// that never resized a card carries nothing new.

import XCTest
import CoreData
@testable import Conduck

final class WorkboardModelMigrationTests: XCTestCase {
    private var storeURL: URL!

    override func setUp() {
        super.setUp()
        storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("conversations-workboard-\(UUID().uuidString).sqlite")
    }

    override func tearDown() {
        if let storeURL {
            let fm = FileManager.default
            try? fm.removeItem(at: storeURL)
            try? fm.removeItem(at: storeURL.deletingPathExtension().appendingPathExtension("sqlite-wal"))
            try? fm.removeItem(at: storeURL.deletingPathExtension().appendingPathExtension("sqlite-shm"))
        }
        storeURL = nil
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
}
