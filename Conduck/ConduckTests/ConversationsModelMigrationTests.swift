// SPDX-License-Identifier: Apache-2.0

// Conduck
// ConversationsModelMigrationTests.swift
//
// REAL step-by-step lightweight-migration coverage for the Conversations Core
// Data model — one test per adjacent version pair. Every version is strictly
// ADDITIVE (new OPTIONAL attributes only, which is also what CloudKit requires),
// so automatic lightweight migration must open the older on-disk store unchanged
// and default each new column to nil on the rows already there. Each shipped
// version is installed on the founder's devices, so every pair is a live upgrade
// path, not a hypothetical.
//
// Each test loads BOTH model versions explicitly from the compiled `.momd` in
// the host app bundle (the `Conversations <N>.mom` layout, same as
// WSDDeclinedTurnTests), writes a real SQLite store under the older model, then
// reopens the SAME file under the newer one with inferred lightweight migration
// and reads the migrated row's new attributes back via KVC. On-disk SQLite in a
// temp dir; cleaned in tearDown.

import XCTest
import CoreData
@testable import Conduck

final class ConversationsModelMigrationTests: XCTestCase {

    private var storeURL: URL!

    override func setUp() {
        super.setUp()
        storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("conversations-v5v6-\(UUID().uuidString).sqlite")
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

    /// Load a specific compiled model version from the host app bundle's
    /// `Conversations.momd`. Falls back to `Bundle(for:)` if the momd is not in
    /// `Bundle.main` (test-host layout differences).
    private func model(named momName: String) throws -> NSManagedObjectModel {
        let candidates = [Bundle.main, Bundle(for: Self.self)]
        for bundle in candidates {
            if let momd = bundle.url(forResource: "Conversations", withExtension: "momd"),
               let model = NSManagedObjectModel(contentsOf: momd.appendingPathComponent(momName)) {
                return model
            }
        }
        throw XCTSkip("compiled \(momName) not found in the host app bundle momd")
    }

    private func loadStore(model: NSManagedObjectModel) async throws -> NSPersistentContainer {
        let container = NSPersistentContainer(name: "Conversations", managedObjectModel: model)
        let description = NSPersistentStoreDescription(url: storeURL)
        // Explicit lightweight migration (both default true; set for clarity).
        description.shouldMigrateStoreAutomatically = true
        description.shouldInferMappingModelAutomatically = true
        container.persistentStoreDescriptions = [description]
        let loaded = expectation(description: "store loads")
        var loadError: Error?
        container.loadPersistentStores { _, error in
            loadError = error
            loaded.fulfill()
        }
        await fulfillment(of: [loaded], timeout: 15)
        if let loadError { throw loadError }
        return container
    }

    func testV5StoreMigratesToV6WithNilPreviewFields() async throws {
        let v5 = try model(named: "Conversations 5.mom")
        let v6 = try model(named: "Conversations 6.mom")

        let conversationID = UUID()
        let messageID = UUID()
        let attachmentID = UUID()

        // 1. Write a Conversation + Message + server-ref Attachment under v5.
        do {
            let container = try await loadStore(model: v5)
            let context = container.newBackgroundContext()
            try await context.perform {
                let convo = NSEntityDescription.insertNewObject(forEntityName: "Conversation", into: context)
                convo.setValue(conversationID, forKey: "id")
                convo.setValue("openclaw", forKey: "backend")
                convo.setValue(Date(), forKey: "createdAt")
                convo.setValue(Date(), forKey: "lastActivityAt")
                convo.setValue(conversationID.uuidString, forKey: "sessionID")

                let message = NSEntityDescription.insertNewObject(forEntityName: "Message", into: context)
                message.setValue(messageID, forKey: "id")
                message.setValue("agent", forKey: "role")
                message.setValue("legacy reply", forKey: "text")
                message.setValue(Date(), forKey: "createdAt")
                message.setValue("phone", forKey: "sourceDevice")
                message.setValue(convo, forKey: "conversation")

                let attachment = NSEntityDescription.insertNewObject(forEntityName: "Attachment", into: context)
                attachment.setValue(attachmentID, forKey: "id")
                attachment.setValue("application/pdf", forKey: "mimeType")
                attachment.setValue("legacy.pdf", forKey: "filename")
                attachment.setValue(true, forKey: "isServerReference")
                attachment.setValue("k1__legacy.pdf", forKey: "storedKey")
                attachment.setValue(Date(), forKey: "createdAt")
                attachment.setValue(message, forKey: "message")

                try context.save()
            }
            // Drop the container so the file is closed before reopening.
            for store in container.persistentStoreCoordinator.persistentStores {
                try container.persistentStoreCoordinator.remove(store)
            }
        }

        // 2. Reopen the SAME file under v6 (lightweight migration).
        let container = try await loadStore(model: v6)
        let context = container.newBackgroundContext()
        try await context.perform {
            let request = NSFetchRequest<NSManagedObject>(entityName: "Attachment")
            request.predicate = NSPredicate(format: "id == %@", attachmentID as CVarArg)
            request.fetchLimit = 1
            let att = try XCTUnwrap(context.fetch(request).first, "the v5 attachment row must survive migration")

            // Old columns preserved.
            XCTAssertEqual(att.value(forKey: "storedKey") as? String, "k1__legacy.pdf")
            XCTAssertEqual(att.value(forKey: "isServerReference") as? Bool, true)
            XCTAssertEqual(att.value(forKey: "filename") as? String, "legacy.pdf")

            // New v6 columns default to nil on the migrated row.
            XCTAssertNil(att.value(forKey: "previewData") as? Data, "previewData is nil on a migrated legacy row")
            XCTAssertNil(att.value(forKey: "previewKind") as? String, "previewKind is nil on a migrated legacy row")

            // And the new columns are writable post-migration.
            att.setValue(Data("preview".utf8), forKey: "previewData")
            att.setValue("text", forKey: "previewKind")
            try context.save()
        }
    }

    func testV6StoreMigratesToV7WithNilFileTransferAndOutputScanLaneIDs() async throws {
        let v6 = try model(named: "Conversations 6.mom")
        let v7 = try model(named: "Conversations 7.mom")
        let conversationID = UUID()
        let messageID = UUID()

        do {
            let container = try await loadStore(model: v6)
            let context = container.newBackgroundContext()
            try await context.perform {
                let conversation = NSEntityDescription.insertNewObject(
                    forEntityName: "Conversation",
                    into: context
                )
                conversation.setValue(conversationID, forKey: "id")
                conversation.setValue("openclaw", forKey: "backend")
                conversation.setValue(Date(), forKey: "createdAt")
                conversation.setValue(Date(), forKey: "lastActivityAt")
                conversation.setValue(conversationID.uuidString, forKey: "sessionID")

                let message = NSEntityDescription.insertNewObject(
                    forEntityName: "Message",
                    into: context
                )
                message.setValue(messageID, forKey: "id")
                message.setValue("agent", forKey: "role")
                message.setValue("legacy output", forKey: "text")
                message.setValue(Date(), forKey: "createdAt")
                message.setValue("mac", forKey: "sourceDevice")
                message.setValue(false, forKey: "outputScanDone")
                message.setValue(conversation, forKey: "conversation")
                try context.save()
            }
            for store in container.persistentStoreCoordinator.persistentStores {
                try container.persistentStoreCoordinator.remove(store)
            }
        }

        let container = try await loadStore(model: v7)
        let context = container.newBackgroundContext()
        try await context.perform {
            let request = NSFetchRequest<NSManagedObject>(entityName: "Message")
            request.predicate = NSPredicate(format: "id == %@", messageID as CVarArg)
            request.fetchLimit = 1
            let message = try XCTUnwrap(
                context.fetch(request).first,
                "the v6 message row must survive migration"
            )
            XCTAssertEqual(message.value(forKey: "text") as? String, "legacy output")
            XCTAssertEqual(message.value(forKey: "outputScanDone") as? Bool, false)
            XCTAssertNil(message.value(forKey: "fileTransferLaneID") as? String)
            XCTAssertNil(message.value(forKey: "outputScanLaneID") as? String)

            message.setValue("input-lane-id", forKey: "fileTransferLaneID")
            message.setValue("lane-id", forKey: "outputScanLaneID")
            try context.save()

            XCTAssertEqual(message.value(forKey: "fileTransferLaneID") as? String, "input-lane-id")
            XCTAssertEqual(message.value(forKey: "outputScanLaneID") as? String, "lane-id")
        }
    }

    func testV7StoreMigratesToV8WithNilOutputBoxKey() async throws {
        let v7 = try model(named: "Conversations 7.mom")
        let v8 = try model(named: "Conversations 8.mom")
        let conversationID = UUID()
        let messageID = UUID()

        do {
            let container = try await loadStore(model: v7)
            let context = container.newBackgroundContext()
            try await context.perform {
                let conversation = NSEntityDescription.insertNewObject(
                    forEntityName: "Conversation",
                    into: context
                )
                conversation.setValue(conversationID, forKey: "id")
                conversation.setValue("openclaw", forKey: "backend")
                conversation.setValue(Date(), forKey: "createdAt")
                conversation.setValue(Date(), forKey: "lastActivityAt")
                conversation.setValue(conversationID.uuidString, forKey: "sessionID")

                let message = NSEntityDescription.insertNewObject(
                    forEntityName: "Message",
                    into: context
                )
                message.setValue(messageID, forKey: "id")
                message.setValue("agent", forKey: "role")
                message.setValue("pending output", forKey: "text")
                message.setValue(Date(), forKey: "createdAt")
                message.setValue("mac", forKey: "sourceDevice")
                message.setValue(false, forKey: "outputScanDone")
                message.setValue("lane-id", forKey: "outputScanLaneID")
                message.setValue(conversation, forKey: "conversation")
                try context.save()
            }
            for store in container.persistentStoreCoordinator.persistentStores {
                try container.persistentStoreCoordinator.remove(store)
            }
        }

        let container = try await loadStore(model: v8)
        let context = container.newBackgroundContext()
        try await context.perform {
            let request = NSFetchRequest<NSManagedObject>(entityName: "Message")
            request.predicate = NSPredicate(format: "id == %@", messageID as CVarArg)
            request.fetchLimit = 1
            let message = try XCTUnwrap(
                context.fetch(request).first,
                "the v7 message row must survive migration"
            )
            XCTAssertEqual(message.value(forKey: "text") as? String, "pending output")
            XCTAssertEqual(message.value(forKey: "outputScanDone") as? Bool, false)
            XCTAssertEqual(message.value(forKey: "outputScanLaneID") as? String, "lane-id")
            // A pending v7 row migrates to "lane known, folder UNKNOWN" — which
            // is exactly the state that must select the row OUT of the automatic
            // pass rather than closing it as "produced nothing".
            XCTAssertNil(message.value(forKey: "outputBoxKey") as? String)

            message.setValue("\(conversationID.uuidString)/out-0123456789abcdef", forKey: "outputBoxKey")
            try context.save()

            XCTAssertEqual(
                message.value(forKey: "outputBoxKey") as? String,
                "\(conversationID.uuidString)/out-0123456789abcdef"
            )
        }
    }
}
