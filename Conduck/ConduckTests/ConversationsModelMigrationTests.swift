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

    /// The same lookup, but a MISS IS A FAILURE rather than a skip.
    ///
    /// WHY THE STRICTER FORM EXISTS. Two tests in this file are the only thing
    /// standing between a stray `defaultValueString` on a v9 census column and
    /// every reply in the user's history being stamped OBSERVED NONE — "the
    /// folder was read and nothing was withheld" — retroactively and
    /// irreversibly, on one migration pass. A skip reports GREEN. So the one
    /// failure mode those tests must never have is the one where they do not run
    /// and nobody is told, which is exactly what an unresolved momd produces: a
    /// bundle-layout change, a renamed resource, a model that stopped being
    /// compiled into the host at all.
    ///
    /// The version-pointer test beside them already fails this way, and the two
    /// guards are under the same obligation — the pointer being right is worth
    /// nothing if the model it points at was never checked.
    private func requiredModel(named momName: String) throws -> NSManagedObjectModel {
        let candidates = [Bundle.main, Bundle(for: Self.self)]
        return try XCTUnwrap(
            candidates.lazy.compactMap { bundle -> NSManagedObjectModel? in
                guard let momd = bundle.url(forResource: "Conversations", withExtension: "momd")
                else { return nil }
                return NSManagedObjectModel(contentsOf: momd.appendingPathComponent(momName))
            }.first,
            "compiled \(momName) not found in the host app bundle momd — this guard may not "
            + "report green without having run: it is the only check that a census column "
            + "carries no default, and a default rewrites the user's whole history")
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

    /// v9 adds the output-delivery census: three counts of what a listing did NOT
    /// hand over, the overlong SUBSET of the shape count, whether the remainder
    /// can still arrive, and the JSON offer of the type-refused names.
    ///
    /// THE ONE THING THIS TEST EXISTS TO CATCH is a `defaultValueString` on any
    /// of the six attributes. A default would stamp OBSERVED NONE — "the folder was
    /// read and nothing was withheld" — onto every reply the user has ever
    /// received, retroactively and irreversibly, on the single migration pass. The
    /// feature rests entirely on NIL MEANING UNKNOWN, so a nil read on a
    /// pre-existing row is not a nicety here; it is the whole contract, and it is
    /// unobservable from any other test because a defaulted column round-trips
    /// perfectly for every row written afterwards.
    ///
    /// The counts are non-scalar Integer 32 (`usesScalarValueType="NO"`) for the
    /// same reason `failureCode` is: only an `NSNumber?` can tell an explicit ZERO
    /// apart from ABSENT, and a scalar column would read both as 0.
    func testV8StoreMigratesToV9WithNilOutputDeliveryCensus() async throws {
        let v8 = try requiredModel(named: "Conversations 8.mom")
        let v9 = try requiredModel(named: "Conversations 9.mom")
        let conversationID = UUID()
        let messageID = UUID()
        let boxKey = "\(conversationID.uuidString)/out-0123456789abcdef"

        do {
            let container = try await loadStore(model: v8)
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
                message.setValue("wrote the profile", forKey: "text")
                message.setValue(Date(), forKey: "createdAt")
                message.setValue("phone", forKey: "sourceDevice")
                message.setValue(true, forKey: "outputScanDone")
                message.setValue("lane-id", forKey: "outputScanLaneID")
                message.setValue(boxKey, forKey: "outputBoxKey")
                message.setValue(conversation, forKey: "conversation")
                try context.save()
            }
            for store in container.persistentStoreCoordinator.persistentStores {
                try container.persistentStoreCoordinator.remove(store)
            }
        }

        let container = try await loadStore(model: v9)
        let context = container.newBackgroundContext()
        try await context.perform {
            let request = NSFetchRequest<NSManagedObject>(entityName: "Message")
            request.predicate = NSPredicate(format: "id == %@", messageID as CVarArg)
            request.fetchLimit = 1
            let message = try XCTUnwrap(
                context.fetch(request).first,
                "the v8 message row must survive migration"
            )

            // Old columns preserved, including the two the census is read
            // alongside — a census whose folder or lane was lost in migration
            // would describe files nothing could fetch.
            XCTAssertEqual(message.value(forKey: "text") as? String, "wrote the profile")
            XCTAssertEqual(message.value(forKey: "outputScanDone") as? Bool, true)
            XCTAssertEqual(message.value(forKey: "outputScanLaneID") as? String, "lane-id")
            XCTAssertEqual(message.value(forKey: "outputBoxKey") as? String, boxKey)

            // THE ASSERTION. Every new column reads nil on a pre-existing row:
            // this reply was never listed by a build that could take a census, so
            // the app knows nothing about what its folder held, and it must say
            // nothing rather than claim it was clean.
            for column in ["outputRefusedTypeCount", "outputRefusedShapeCount",
                           "outputRefusedShapeOverlongCount", "outputRefusedShapeWhitespaceCount",
                           "outputUndeliveredCount", "outputRemainderIsRecoverable"] {
                XCTAssertNil(
                    message.value(forKey: column) as? NSNumber,
                    "\(column) must be nil (UNKNOWN) on a migrated row — a defaultValueString here "
                    + "would silently claim every historical reply returned everything it produced")
            }
            XCTAssertNil(message.value(forKey: "outputRefusedTypeNames") as? String)

            // And each is writable post-migration, INCLUDING an explicit zero,
            // which is the value that must read back as 0 rather than as nil —
            // "read and clean" is a positive observation and the only thing that
            // retires a standing refusal row.
            message.setValue(NSNumber(value: Int32(2)), forKey: "outputRefusedTypeCount")
            message.setValue(NSNumber(value: Int32(3)), forKey: "outputRefusedShapeCount")
            message.setValue(NSNumber(value: Int32(1)), forKey: "outputRefusedShapeOverlongCount")
            message.setValue(NSNumber(value: Int32(1)), forKey: "outputRefusedShapeWhitespaceCount")
            message.setValue(NSNumber(value: Int32(1)), forKey: "outputUndeliveredCount")
            message.setValue(NSNumber(value: false), forKey: "outputRemainderIsRecoverable")
            message.setValue(#"{"e":[{"b":4096,"n":"profile.mobileconfig"}],"v":1}"#,
                             forKey: "outputRefusedTypeNames")
            try context.save()

            XCTAssertEqual((message.value(forKey: "outputRefusedTypeCount") as? NSNumber)?.intValue, 2)
            XCTAssertEqual((message.value(forKey: "outputRefusedShapeCount") as? NSNumber)?.intValue, 3)
            XCTAssertEqual(
                (message.value(forKey: "outputRefusedShapeOverlongCount") as? NSNumber)?.intValue, 1)
            XCTAssertEqual(
                (message.value(forKey: "outputRefusedShapeWhitespaceCount") as? NSNumber)?.intValue, 1)
            XCTAssertEqual((message.value(forKey: "outputUndeliveredCount") as? NSNumber)?.intValue, 1)
            XCTAssertEqual(
                (message.value(forKey: "outputRemainderIsRecoverable") as? NSNumber)?.boolValue, false,
                "an explicit FALSE survives as false — nil on this column means the cause was never "
                + "recorded, which may never be read as the promise that a later pass delivers")
            XCTAssertEqual(message.value(forKey: "outputRefusedTypeNames") as? String,
                           #"{"e":[{"b":4096,"n":"profile.mobileconfig"}],"v":1}"#)

            // The bridge the app actually reads through, exercised on the same
            // row: seven columns in, one value out.
            let record = MessageRecord(managedObject: message)
            XCTAssertEqual(record.outputDeliveryOutcome?.typeRefusedCount, 2)
            XCTAssertEqual(record.outputDeliveryOutcome?.shapeRefusedCount, 3)
            XCTAssertEqual(record.outputDeliveryOutcome?.shapeRefused,
                           ShapeRefusalCensus(overlongCount: 1, whitespaceBoundedCount: 1,
                                              unusableCount: 1),
                           "the total plus its two ACTIONABLE subsets, so the residual is a "
                           + "subtraction and the three arms can never sum to something the row's "
                           + "sentence does not count")
            XCTAssertEqual(record.outputDeliveryOutcome?.undeliveredCount, 1)
            XCTAssertEqual(record.outputDeliveryOutcome?.remainder, .ceilingCapped(count: 1))
            XCTAssertEqual(record.outputDeliveryOutcome?.typeRefusedEntries.map(\.name),
                           ["profile.mobileconfig"])

            // And an explicit zero on the shape total still reads back as the
            // POSITIVE observation, which is the value that retires a standing
            // row. Asserted after the non-zero case so both directions are
            // covered on the same migrated row.
            message.setValue(NSNumber(value: Int32(0)), forKey: "outputRefusedShapeCount")
            message.setValue(NSNumber(value: Int32(0)), forKey: "outputRefusedShapeOverlongCount")
            message.setValue(NSNumber(value: Int32(0)), forKey: "outputRefusedShapeWhitespaceCount")
            try context.save()
            XCTAssertEqual(MessageRecord(managedObject: message).outputDeliveryOutcome?.shapeRefused,
                           .nothingRefused,
                           "an explicit zero survives as zero — the distinction the whole feature "
                           + "rests on")
        }
    }

    /// The census columns are ADDITIVE ON `Message` AND NOWHERE ELSE, which is
    /// what keeps the migration lightweight (and therefore what keeps it
    /// CloudKit-compatible). Asserted against the compiled models rather than the
    /// XML, so an edit to v8 in place — the one genuine data-loss path in this
    /// change — shows up here as v8 already carrying attributes it never shipped.
    func testV9AddsSevenOptionalMessageAttributesAndNothingElse() throws {
        let v8 = try requiredModel(named: "Conversations 8.mom")
        let v9 = try requiredModel(named: "Conversations 9.mom")

        XCTAssertEqual(Set(v8.entitiesByName.keys), Set(v9.entitiesByName.keys),
                       "no entity appears or disappears — an entity change is not lightweight")

        for (name, newEntity) in v9.entitiesByName {
            let oldEntity = try XCTUnwrap(v8.entitiesByName[name])
            let added = Set(newEntity.attributesByName.keys)
                .subtracting(oldEntity.attributesByName.keys)
            let removed = Set(oldEntity.attributesByName.keys)
                .subtracting(newEntity.attributesByName.keys)
            XCTAssertTrue(removed.isEmpty,
                          "\(name) lost \(removed.sorted()) — a removal is data loss, not a migration")
            if name == "Message" {
                // Three POPULATION counts, the two ACTIONABLE subsets of the
                // shape population, the remainder's cause, and the retained
                // names. Each actionable class gets its own column because the
                // residual is derived by subtraction: a class folded into
                // another would come back out as a sentence asking the user for
                // the wrong change. The two attribute columns are separate
                // because neither can bring a census into being — see
                // `MessageRecord.init(managedObject:)`.
                XCTAssertEqual(added, ["outputRefusedTypeCount", "outputRefusedShapeCount",
                                       "outputRefusedShapeOverlongCount",
                                       "outputRefusedShapeWhitespaceCount", "outputUndeliveredCount",
                                       "outputRemainderIsRecoverable", "outputRefusedTypeNames"])
            } else {
                XCTAssertTrue(added.isEmpty, "\(name) must be untouched by this version")
            }
            for attribute in added.compactMap({ newEntity.attributesByName[$0] }) {
                XCTAssertTrue(attribute.isOptional,
                              "\(attribute.name) must be optional — CloudKit requires it, and a "
                              + "required column cannot be nil, which is how UNKNOWN is spelled")
                XCTAssertNil(attribute.defaultValue,
                             "\(attribute.name) must carry NO default: a default is applied to "
                             + "every pre-existing row at migration time, which converts UNKNOWN "
                             + "into a fabricated observation across the user's entire history")
            }
        }
    }

    /// The model the APP opens is v9. A pointer left on v8 would ship code that
    /// reads six columns from a store that has none — and, worse, would not fail
    /// loudly: KVC on a missing attribute is what the record's tolerant reads are
    /// built to survive, so the census would simply always be nil.
    func testTheCurrentModelVersionIsV9() throws {
        let bundles = [Bundle.main, Bundle(for: Self.self)]
        let momd = try XCTUnwrap(
            bundles.compactMap { $0.url(forResource: "Conversations", withExtension: "momd") }.first,
            "compiled Conversations.momd not found in the host app bundle")
        let plist = try XCTUnwrap(
            NSDictionary(contentsOf: momd.appendingPathComponent("VersionInfo.plist")),
            "a compiled momd always carries VersionInfo.plist")
        XCTAssertEqual(plist["NSManagedObjectModel_CurrentVersionName"] as? String, "Conversations 9")
    }
}
