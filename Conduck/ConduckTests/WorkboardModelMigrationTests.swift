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
// mounts — a shipped default-configuration store must open as `Core` untouched
// — and gives a material the hash of the blob it was published with, so a card
// names its own payload rather than whatever blob carries its id. v17 adds one
// more optional column to the same entity: a recording published beside a
// screenshot names that picture, so one press shows as one card without either
// artifact losing its own id, kind or payload.

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

    func testV16AddsTheBlobEntityTheMaterialPairingAndTwoCloudKitConfigurations() throws {
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
            // One added column on one entity: the material names the blob it
            // was published with, because a blob carrying its id may be another
            // device's and may still be rolled back.
            let added = Set(after.attributesByName.keys)
                .subtracting(before.attributesByName.keys)
            XCTAssertEqual(added, entityName == "WorkMaterial" ? ["contentHash"] : [],
                           "v16 must not add columns to \(entityName)")
            XCTAssertTrue(
                Set(before.attributesByName.keys).isSubset(of: Set(after.attributesByName.keys)),
                "v16 must not drop a shipped \(entityName) column"
            )
            XCTAssertEqual(Set(after.relationshipsByName.keys), Set(before.relationshipsByName.keys),
                           "v16 must not mutate shipped \(entityName) relationships")
            if entityName == "WorkMaterial" {
                XCTAssertNotEqual(
                    after.versionHash, before.versionHash,
                    "an added column is a migration; a matching hash would mean it is not there"
                )
            } else {
                XCTAssertEqual(
                    after.versionHash, before.versionHash,
                    "adding an entity and configurations must leave \(entityName) migration-free"
                )
            }
        }

        let pairing = try XCTUnwrap(
            v16.entitiesByName["WorkMaterial"]?.attributesByName["contentHash"]
        )
        XCTAssertEqual(pairing.attributeType, .stringAttributeType)
        XCTAssertTrue(pairing.isOptional)
        XCTAssertNil(
            pairing.defaultValue,
            "a migrated card names no blob until a publication writes one; nil is that state"
        )

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
                XCTAssertNil(
                    material.value(forKey: "contentHash"),
                    "lightweight migration may not invent a blob for a card that names none"
                )
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
                // The pairing, written in the same save as the lane: the card
                // names the blob it was published with.
                material.setValue("sha256-fixture", forKey: "contentHash")
                material.setValue(NSNumber(value: Int64(payload.count)), forKey: "byteSize")
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
            XCTAssertEqual(
                material.value(forKey: "contentHash") as? String, "sha256-fixture",
                "the pairing survives close and reopen with the lane it belongs to"
            )
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

    func testV17AddsOnlyTheMaterialCompanionLinkColumn() throws {
        let v16 = try requiredModel(named: "Conversations 16.mom")
        let v17 = try requiredModel(named: "Conversations 17.mom")
        XCTAssertEqual(
            Set(v17.entitiesByName.keys), Set(v16.entitiesByName.keys),
            "one card for two artifacts is a link between existing rows, not a new entity"
        )

        for entityName in v16.entitiesByName.keys {
            let before = try XCTUnwrap(v16.entitiesByName[entityName])
            let after = try XCTUnwrap(v17.entitiesByName[entityName])
            let added = Set(after.attributesByName.keys)
                .subtracting(before.attributesByName.keys)
            XCTAssertEqual(
                added, entityName == "WorkMaterial" ? ["attachedToMaterialID"] : [],
                "v17 must not add columns to \(entityName)"
            )
            XCTAssertTrue(
                Set(before.attributesByName.keys).isSubset(of: Set(after.attributesByName.keys)),
                "v17 must not drop a shipped \(entityName) column"
            )
            XCTAssertEqual(
                Set(after.relationshipsByName.keys), Set(before.relationshipsByName.keys),
                "the link is a UUID column; a relationship would tie the two rows' deletion together"
            )
            if entityName == "WorkMaterial" {
                XCTAssertNotEqual(
                    after.versionHash, before.versionHash,
                    "an added column is a migration; a matching hash would mean it is not there"
                )
            } else {
                XCTAssertEqual(
                    after.versionHash, before.versionHash,
                    "\(entityName) is untouched by v17 and must stay migration-free"
                )
            }
        }

        let material = try XCTUnwrap(v17.entitiesByName["WorkMaterial"])
        let link = try XCTUnwrap(material.attributesByName["attachedToMaterialID"])
        XCTAssertEqual(link.attributeType, .UUIDAttributeType)
        XCTAssertTrue(
            link.isOptional,
            "every card but a companion recording names no picture; that is the ordinary state"
        )
        XCTAssertNil(
            link.defaultValue,
            "a migrated recording belongs to no picture until a publication says so; nil is that state"
        )
        XCTAssertTrue(material.uniquenessConstraints.isEmpty,
                      "CloudKit mirrored models cannot carry unique constraints")

        // Both configurations survive verbatim: the Watch still excludes
        // payloads by never mounting `Blobs`, and the link is Core-side
        // metadata that mirrors with the card it belongs to.
        XCTAssertEqual(
            Set(v17.configurations).subtracting(["PF_DEFAULT_CONFIGURATION_NAME"]),
            ["Core", "Blobs"]
        )
        XCTAssertEqual(
            Set((v17.entities(forConfigurationName: "Core") ?? []).compactMap(\.name)),
            Set((v16.entities(forConfigurationName: "Core") ?? []).compactMap(\.name))
        )
        XCTAssertEqual(
            Set((v17.entities(forConfigurationName: "Blobs") ?? []).compactMap(\.name)),
            ["WorkMaterialBlob"]
        )
        let blob16 = try XCTUnwrap(v16.entitiesByName["WorkMaterialBlob"])
        let blob17 = try XCTUnwrap(v17.entitiesByName["WorkMaterialBlob"])
        XCTAssertEqual(
            blob17.versionHash, blob16.versionHash,
            "the payload store is untouched: a link between cards is not a fact about bytes"
        )
    }

    /// The real upgrade, on SQLite, in the production two-store topology: a
    /// desk captured on model 16 opens on model 17 with its cards intact and
    /// their links empty, and a link written afterwards survives a reopen.
    func testV16SQLiteMigratesToV17LeavingExistingRecordingsUnattached() async throws {
        let v16 = try requiredModel(named: "Conversations 16.mom")
        let v17 = try requiredModel(named: "Conversations 17.mom")
        let itemID = UUID()
        let recordingID = UUID()
        let pictureID = UUID()

        do {
            let container = try await loadCoreAndBlobStores(model: v16)
            let context = container.newBackgroundContext()
            try await context.perform {
                let item = NSEntityDescription.insertNewObject(forEntityName: "WorkItem", into: context)
                item.setValue(itemID, forKey: "id")
                item.setValue("Captured before the companion link", forKey: "title")
                item.setValue(Date(timeIntervalSince1970: 1_800_000_000), forKey: "createdAt")
                item.setValue(Date(timeIntervalSince1970: 1_800_000_000), forKey: "updatedAt")

                let recording = NSEntityDescription.insertNewObject(
                    forEntityName: "WorkMaterial", into: context
                )
                recording.setValue(recordingID, forKey: "id")
                recording.setValue(itemID, forKey: "workItemID")
                recording.setValue("audio", forKey: "kind")
                recording.setValue("Ship the carrier review", forKey: "title")
                recording.setValue("Ship the carrier review by Friday", forKey: "textContent")
                recording.setValue("syncedPayload", forKey: "storageMode")
                recording.setValue("sha256-recording", forKey: "contentHash")
                recording.setValue(NSNumber(value: Int64(9_001)), forKey: "byteSize")
                recording.setValue(NSNumber(value: Int32(1)), forKey: "sequence")
                recording.setValue(Date(timeIntervalSince1970: 1_800_000_001), forKey: "createdAt")
                recording.setValue(Date(timeIntervalSince1970: 1_800_000_001), forKey: "updatedAt")
                try context.save()
            }
            try unload(container)
        }

        do {
            let container = try await loadCoreAndBlobStores(model: v17)
            XCTAssertEqual(
                container.persistentStoreCoordinator.persistentStores.count, 2,
                "a migration that mounted one store would strand every payload silently"
            )
            let context = container.newBackgroundContext()
            try await context.perform {
                let request = NSFetchRequest<NSManagedObject>(entityName: "WorkMaterial")
                request.predicate = NSPredicate(format: "id == %@", recordingID as CVarArg)
                let recording = try XCTUnwrap(context.fetch(request).first)
                XCTAssertEqual(recording.value(forKey: "title") as? String,
                               "Ship the carrier review")
                XCTAssertEqual(recording.value(forKey: "textContent") as? String,
                               "Ship the carrier review by Friday",
                               "the transcript stays on the recording it was spoken into")
                XCTAssertEqual(recording.value(forKey: "contentHash") as? String,
                               "sha256-recording")
                XCTAssertNil(
                    recording.value(forKey: "attachedToMaterialID"),
                    "no backfill: a capture made before the link belongs to no picture"
                )
                XCTAssertEqual(
                    recording.value(forKey: "updatedAt") as? Date,
                    Date(timeIntervalSince1970: 1_800_000_001),
                    "migration may not move a revision-bearing timestamp"
                )

                recording.setValue(pictureID, forKey: "attachedToMaterialID")
                try context.save()
            }
            try unload(container)
        }

        let container = try await loadCoreAndBlobStores(model: v17)
        let context = container.newBackgroundContext()
        try await context.perform {
            let request = NSFetchRequest<NSManagedObject>(entityName: "WorkMaterial")
            request.predicate = NSPredicate(format: "id == %@", recordingID as CVarArg)
            let recording = try XCTUnwrap(context.fetch(request).first)
            XCTAssertEqual(
                recording.value(forKey: "attachedToMaterialID") as? UUID, pictureID,
                "the link survives close and reopen; the fold is not rebuilt each launch"
            )
            // The link names an id, not a row. Nothing was inserted for the
            // picture, and the store neither invents it nor refuses the link.
            let pictureRequest = NSFetchRequest<NSManagedObject>(entityName: "WorkMaterial")
            pictureRequest.predicate = NSPredicate(format: "id == %@", pictureID as CVarArg)
            XCTAssertEqual(
                try context.count(for: pictureRequest), 0,
                "a link is a promise about identity; the picture may not have landed yet"
            )
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
