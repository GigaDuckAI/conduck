// SPDX-License-Identifier: Apache-2.0

// Conduck
// ConversationsModelMigrationTests.swift
//
// REAL step-by-step lightweight-migration coverage for the Conversations Core
// Data model — one test per adjacent version pair. Every version is strictly
// ADDITIVE (new OPTIONAL attributes, and from v11 a new entity with its optional
// relationship — all of which CloudKit likewise requires to be optional), so
// automatic lightweight migration must open the older on-disk store unchanged
// and default each new column to nil on the rows already there. Each shipped
// version is installed on the founder's devices, so every pair is a live upgrade
// path, not a hypothetical.
//
// From v11 the file also covers DELETION, which is not a migration question but
// belongs beside the relationship that answers it. Under v11 an attempt row dies
// with the message it measured, and an attempt row that arrived without its
// relationship is reachable only by its scalar conversation id, because the
// cascade cannot see it. v12 decouples the two lifetimes — the link nullifies
// instead of cascading, so a content-free measurement outlives the content it
// measured — and each version's tests assert that version's own rule: a shipped
// model is frozen history and the v11 assertions describe the artifact users
// still have on disk, not the behaviour the app has today.
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
        let current = try requiredModel(named: "Conversations 12.mom")
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

        let v9Container = try await loadStore(model: v9)
        let v9Context = v9Container.newBackgroundContext()
        try await v9Context.perform {
            let request = NSFetchRequest<NSManagedObject>(entityName: "Message")
            request.predicate = NSPredicate(format: "id == %@", messageID as CVarArg)
            request.fetchLimit = 1
            let message = try XCTUnwrap(
                v9Context.fetch(request).first,
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
            try v9Context.save()

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
        }
        for store in v9Container.persistentStoreCoordinator.persistentStores {
            try v9Container.persistentStoreCoordinator.remove(store)
        }

        // THE BRIDGE RUNS AT THE CURRENT MODEL VERSION, never at the version
        // this test migrates TO, and the same store file is simply carried one
        // more hop to get there. `MessageRecord(managedObject:)` reads every
        // column the app ships with, so opening it against an older model
        // raises `NSUnknownKeyException` on the first attribute a later version
        // added — a failure about the test's staging, not about the migration
        // it is meant to pin. Each new model version therefore moves this half
        // forward while the assertions above stay exactly where they were, and
        // the chained v8 → v9 → v11 load is a free extra: it proves the census
        // columns survive every LATER lightweight migration too.
        let currentContainer = try await loadStore(model: current)
        let currentContext = currentContainer.newBackgroundContext()
        try await currentContext.perform {
            let request = NSFetchRequest<NSManagedObject>(entityName: "Message")
            request.predicate = NSPredicate(format: "id == %@", messageID as CVarArg)
            request.fetchLimit = 1
            let message = try XCTUnwrap(
                currentContext.fetch(request).first,
                "the row must survive the second lightweight migration too"
            )

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
            try currentContext.save()
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

    /// v10 makes "what the user has already seen" an account fact instead of a
    /// device fact: three markers on `Conversation`, and one delivery identity on
    /// `Message` so a retry's failure is distinguishable from the failure it
    /// replaced. All four are PERMANENT — the production CloudKit schema is
    /// additive-only, so nothing added here can ever be renamed or withdrawn — and
    /// that is exactly why their shape is pinned by a test rather than left to
    /// whatever the model editor last wrote.
    ///
    /// THE ONE THING THIS TEST EXISTS TO CATCH is a value arriving on a row that
    /// nobody ever observed. A migrated row must read nil on all four, because nil
    /// is how "this account has not looked at this yet" is spelled, and the single
    /// migration pass is the only moment at which that can be silently falsified
    /// for the user's entire history at once.
    func testV9StoreMigratesToV10WithNilAccountSeenMarkers() async throws {
        let v9 = try requiredModel(named: "Conversations 9.mom")
        let v10 = try requiredModel(named: "Conversations 10.mom")
        let conversationID = UUID()
        let messageID = UUID()
        let lastActivityAt = Date(timeIntervalSince1970: 1_700_000_000)

        do {
            let container = try await loadStore(model: v9)
            let context = container.newBackgroundContext()
            try await context.perform {
                let conversation = NSEntityDescription.insertNewObject(
                    forEntityName: "Conversation",
                    into: context
                )
                conversation.setValue(conversationID, forKey: "id")
                conversation.setValue("openclaw", forKey: "backend")
                conversation.setValue(Date(timeIntervalSince1970: 1_699_000_000), forKey: "createdAt")
                conversation.setValue(lastActivityAt, forKey: "lastActivityAt")
                conversation.setValue(conversationID.uuidString, forKey: "sessionID")
                conversation.setValue("an old thread", forKey: "title")

                let message = NSEntityDescription.insertNewObject(
                    forEntityName: "Message",
                    into: context
                )
                message.setValue(messageID, forKey: "id")
                message.setValue("user", forKey: "role")
                message.setValue("never sent", forKey: "text")
                message.setValue(lastActivityAt, forKey: "createdAt")
                message.setValue("phone", forKey: "sourceDevice")
                // A row already sitting in the state the new identity is about:
                // failed, minted by a build that had no attempt identity to mint.
                message.setValue("failed", forKey: "status")
                message.setValue(conversation, forKey: "conversation")
                try context.save()
            }
            for store in container.persistentStoreCoordinator.persistentStores {
                try container.persistentStoreCoordinator.remove(store)
            }
        }

        let container = try await loadStore(model: v10)
        let context = container.newBackgroundContext()
        try await context.perform {
            let conversationRequest = NSFetchRequest<NSManagedObject>(entityName: "Conversation")
            conversationRequest.predicate = NSPredicate(format: "id == %@", conversationID as CVarArg)
            conversationRequest.fetchLimit = 1
            let conversation = try XCTUnwrap(
                context.fetch(conversationRequest).first,
                "the v9 conversation row must survive migration"
            )
            let messageRequest = NSFetchRequest<NSManagedObject>(entityName: "Message")
            messageRequest.predicate = NSPredicate(format: "id == %@", messageID as CVarArg)
            messageRequest.fetchLimit = 1
            let message = try XCTUnwrap(
                context.fetch(messageRequest).first,
                "the v9 message row must survive migration"
            )

            // Old columns preserved. `lastActivityAt` in particular: it is the
            // other half of the unseen test, so a conversation that lost it would
            // read as unseen or seen at random rather than by comparison.
            XCTAssertEqual(conversation.value(forKey: "title") as? String, "an old thread")
            XCTAssertEqual(conversation.value(forKey: "lastActivityAt") as? Date, lastActivityAt)
            XCTAssertEqual(message.value(forKey: "text") as? String, "never sent")
            XCTAssertEqual(message.value(forKey: "status") as? String, "failed")

            // THE ASSERTION. Every new column reads nil on a pre-existing row.
            for column in ["lastViewedAt", "failureSeenAttemptID", "tailProjection"] {
                XCTAssertNil(
                    conversation.value(forKey: column),
                    "Conversation.\(column) must be nil on a migrated row — a defaultValueString "
                    + "here is written to every conversation the user has ever had, in one "
                    + "irreversible pass")
            }
            XCTAssertNil(
                message.value(forKey: "deliveryAttemptID"),
                "Message.deliveryAttemptID must be nil on a migrated row — a legacy failure has no "
                + "attempt identity, and an acknowledgement is accepted only on exact equality, so "
                + "nil is what keeps an old failure red instead of silently acknowledged")

            // And each is writable post-migration, at its NATIVE type. The two
            // identities are `UUID` columns, not UUID strings: equality between
            // them is the entire acknowledgement rule, and a string column would
            // add a malformed-value parsing path that has to fail somewhere.
            let viewedAt = Date(timeIntervalSince1970: 1_700_000_500)
            let attemptID = UUID()
            let projection = "1|\(messageID.uuidString)|1700000000.0|user"
            conversation.setValue(viewedAt, forKey: "lastViewedAt")
            conversation.setValue(attemptID, forKey: "failureSeenAttemptID")
            conversation.setValue(projection, forKey: "tailProjection")
            message.setValue(attemptID, forKey: "deliveryAttemptID")
            try context.save()

            XCTAssertEqual(conversation.value(forKey: "lastViewedAt") as? Date, viewedAt)
            XCTAssertEqual(conversation.value(forKey: "failureSeenAttemptID") as? UUID, attemptID)
            XCTAssertEqual(conversation.value(forKey: "tailProjection") as? String, projection)
            XCTAssertEqual(
                message.value(forKey: "deliveryAttemptID") as? UUID, attemptID,
                "the attempt identity round-trips as a UUID value, which is what lets the resolver "
                + "compare it for equality rather than parse it")
        }
    }

    /// v10 is ADDITIVE and adds exactly four columns: three on `Conversation` and
    /// one on `Message`, with `Attachment` untouched. Asserted against the compiled
    /// models rather than the XML, so an edit to v9 in place — the one genuine
    /// data-loss path in this change — shows up here as v9 already carrying
    /// attributes it never shipped.
    ///
    /// The type assertions are not decoration. Both identity columns are settled
    /// as native `UUID` before the production CloudKit deploy, and a production
    /// schema is additive-only: a column that ships as `String` can never become a
    /// `UUID` afterwards.
    func testV10AddsFourOptionalMarkerAttributesAndNothingElse() throws {
        let v9 = try requiredModel(named: "Conversations 9.mom")
        let v10 = try requiredModel(named: "Conversations 10.mom")

        XCTAssertEqual(Set(v9.entitiesByName.keys), Set(v10.entitiesByName.keys),
                       "no entity appears or disappears — an entity change is not lightweight")

        let expectedAdditions: [String: Set<String>] = [
            "Conversation": ["lastViewedAt", "failureSeenAttemptID", "tailProjection"],
            "Message": ["deliveryAttemptID"],
            "Attachment": [],
        ]
        let expectedTypes: [String: NSAttributeType] = [
            "lastViewedAt": .dateAttributeType,
            "failureSeenAttemptID": .UUIDAttributeType,
            "tailProjection": .stringAttributeType,
            "deliveryAttemptID": .UUIDAttributeType,
        ]

        for (name, newEntity) in v10.entitiesByName {
            let oldEntity = try XCTUnwrap(v9.entitiesByName[name])
            let added = Set(newEntity.attributesByName.keys)
                .subtracting(oldEntity.attributesByName.keys)
            let removed = Set(oldEntity.attributesByName.keys)
                .subtracting(newEntity.attributesByName.keys)
            XCTAssertTrue(removed.isEmpty,
                          "\(name) lost \(removed.sorted()) — a removal is data loss, not a migration")
            let expectedForEntity = try XCTUnwrap(expectedAdditions[name])
            XCTAssertEqual(added, expectedForEntity,
                           "\(name) gains exactly the columns settled before the production CloudKit "
                           + "deploy — an extra one is permanent, and a missing one is a marker the "
                           + "account can never carry")
            XCTAssertEqual(
                Set(newEntity.relationshipsByName.keys), Set(oldEntity.relationshipsByName.keys),
                "\(name) keeps its relationships — a relationship change is not lightweight")

            for attribute in added.compactMap({ newEntity.attributesByName[$0] }) {
                XCTAssertEqual(attribute.attributeType, expectedTypes[attribute.name],
                               "\(attribute.name) ships at its settled type: a production CloudKit "
                               + "schema is additive-only, so the type it deploys with is the type "
                               + "it keeps forever")
                XCTAssertTrue(attribute.isOptional,
                              "\(attribute.name) must be optional — CloudKit requires it, and a "
                              + "required column cannot be nil, which is how NEVER SEEN is spelled")
                XCTAssertNil(
                    attribute.defaultValue,
                    "\(attribute.name) must carry NO default: a default is written to every "
                    + "pre-existing row at migration time, so a default on lastViewedAt stamps the "
                    + "user's ENTIRE history 'already read' in one irreversible pass — every unread "
                    + "reply on every device loses its mark, and nothing afterwards can tell a "
                    + "defaulted row from one the user genuinely looked at. The same pass would "
                    + "acknowledge failures nobody has seen via failureSeenAttemptID, assert a tail "
                    + "shape nothing observed via tailProjection, and hand every historical message "
                    + "one shared deliveryAttemptID — under which a single acknowledgement retires "
                    + "every red mark in the store")
            }
        }
    }

    /// v11 opens the gateway-attempt ledger: a store of what each dispatch to a
    /// gateway did, kept beside the conversation it belongs to rather than sent
    /// anywhere. This is the first version that adds an ENTITY rather than a
    /// column, which lightweight migration handles the same way — the new table
    /// simply starts empty.
    ///
    /// THE THING THIS TEST EXISTS TO CATCH is a v10 store arriving with anything
    /// in the ledger at all. Nothing may be back-filled: the ledger's whole claim
    /// is that it measures dispatches it actually observed, and a migration that
    /// invented a row per historical message would make every coverage figure and
    /// every reliability rate a fiction from the first launch. An empty ledger on
    /// a full history is the correct, and the only honest, migration result.
    func testV10StoreMigratesToV11WithAnEmptyGatewayAttemptLedger() async throws {
        let v10 = try requiredModel(named: "Conversations 10.mom")
        let v11 = try requiredModel(named: "Conversations 11.mom")
        let conversationID = UUID()
        let messageID = UUID()
        let attemptID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_800_000_000)

        do {
            let container = try await loadStore(model: v10)
            let context = container.newBackgroundContext()
            try await context.perform {
                let conversation = NSEntityDescription.insertNewObject(
                    forEntityName: "Conversation",
                    into: context
                )
                conversation.setValue(conversationID, forKey: "id")
                conversation.setValue("openclaw", forKey: "backend")
                conversation.setValue(Date(timeIntervalSince1970: 1_799_000_000), forKey: "createdAt")
                conversation.setValue(startedAt, forKey: "lastActivityAt")
                conversation.setValue(conversationID.uuidString, forKey: "sessionID")

                let message = NSEntityDescription.insertNewObject(
                    forEntityName: "Message",
                    into: context
                )
                message.setValue(messageID, forKey: "id")
                message.setValue("user", forKey: "role")
                message.setValue("an unmeasured turn", forKey: "text")
                message.setValue(startedAt, forKey: "createdAt")
                message.setValue("iphone-voice", forKey: "sourceDevice")
                message.setValue("sent", forKey: "status")
                message.setValue(conversation, forKey: "conversation")
                try context.save()
            }
            for store in container.persistentStoreCoordinator.persistentStores {
                try container.persistentStoreCoordinator.remove(store)
            }
        }

        let container = try await loadStore(model: v11)
        let context = container.newBackgroundContext()
        try await context.perform {
            let messageRequest = NSFetchRequest<NSManagedObject>(entityName: "Message")
            messageRequest.predicate = NSPredicate(format: "id == %@", messageID as CVarArg)
            messageRequest.fetchLimit = 1
            let message = try XCTUnwrap(
                context.fetch(messageRequest).first,
                "the v10 message row must survive migration"
            )

            // Old columns preserved.
            XCTAssertEqual(message.value(forKey: "text") as? String, "an unmeasured turn")
            XCTAssertEqual(message.value(forKey: "sourceDevice") as? String, "iphone-voice")
            XCTAssertEqual(message.value(forKey: "status") as? String, "sent")

            // THE ASSERTION. The ledger is empty, and the message that predates
            // it is linked to nothing.
            let attemptRequest = NSFetchRequest<NSManagedObject>(entityName: "GatewayAttempt")
            XCTAssertEqual(
                try context.count(for: attemptRequest), 0,
                "migration back-fills NOTHING — a fabricated attempt per historical message would "
                + "make every rate and every coverage figure a fiction before the first dispatch")
            XCTAssertEqual((message.value(forKey: "gatewayAttempts") as? NSSet)?.count, 0)

            // And the ledger is writable post-migration, at its NATIVE types.
            // The three identities are `UUID` columns, not UUID strings: a
            // production CloudKit schema is additive-only, so what deploys here
            // can never be re-typed, and a string column would add a
            // malformed-value parsing path with nowhere honest to fail.
            let attempt = NSEntityDescription.insertNewObject(
                forEntityName: "GatewayAttempt", into: context)
            attempt.setValue(attemptID, forKey: "id")
            attempt.setValue(conversationID, forKey: "conversationID")
            attempt.setValue(messageID, forKey: "userMessageID")
            attempt.setValue("openclaw", forKey: "gatewayRef")
            attempt.setValue(startedAt, forKey: "startedAt")
            attempt.setValue("inFlight", forKey: "outcome")
            attempt.setValue("app", forKey: "originSurface")
            attempt.setValue("voice", forKey: "inputMode")
            attempt.setValue(NSNumber(value: Int16(1)), forKey: "recordVersion")
            attempt.setValue(message, forKey: "userMessage")
            try context.save()

            XCTAssertEqual(attempt.value(forKey: "id") as? UUID, attemptID)
            XCTAssertEqual(attempt.value(forKey: "conversationID") as? UUID, conversationID)
            XCTAssertEqual(attempt.value(forKey: "userMessageID") as? UUID, messageID)
            XCTAssertEqual(attempt.value(forKey: "startedAt") as? Date, startedAt)
            XCTAssertEqual((message.value(forKey: "gatewayAttempts") as? NSSet)?.count, 1,
                           "the inverse is maintained, so the cascade has something to follow")

            // An OPEN row reports nothing about its ending, and says so with nil
            // rather than with a zero. Everything the dashboard divides by rests
            // on that: a scalar column would report every unfinished attempt as
            // having completed instantly, reported zero tokens, and failed with
            // error code 0.
            for column in ["completedAt", "appErrorCode", "reportedInputTokens",
                           "reportedOutputTokens", "reportedTotalTokens", "reportedModel",
                           "reportedResponseID", "finishReason", "requestedModel"] {
                XCTAssertNil(
                    attempt.value(forKey: column),
                    "GatewayAttempt.\(column) must be nil on an open row — a default here is a "
                    + "measurement nobody took")
            }
        }
    }

    /// v11 is ADDITIVE: it adds exactly one entity, exactly one relationship on
    /// `Message`, and NOTHING else — no new column on any pre-existing entity, no
    /// removal anywhere. Asserted against the compiled models rather than the XML,
    /// so an edit to v10 in place — the one genuine data-loss path in this change
    /// — shows up here as v10 already carrying an entity it never shipped.
    ///
    /// The per-attribute assertions are the permanent half. The production
    /// CloudKit schema is additive-only: the types, the optionality and the
    /// absence of defaults that deploy with this entity are what it keeps
    /// forever, and a `defaultValueString` on any counter would make "the gateway
    /// reported nothing" indistinguishable from "the gateway reported zero" for
    /// every row ever written.
    func testV11AddsTheGatewayAttemptEntityAndNothingElse() throws {
        let v10 = try requiredModel(named: "Conversations 10.mom")
        let v11 = try requiredModel(named: "Conversations 11.mom")

        XCTAssertEqual(Set(v11.entitiesByName.keys).subtracting(v10.entitiesByName.keys),
                       ["GatewayAttempt"],
                       "exactly one new entity — anything else is a schema this release never "
                       + "reviewed")
        XCTAssertTrue(Set(v10.entitiesByName.keys).subtracting(v11.entitiesByName.keys).isEmpty,
                      "an entity removal is data loss, not a migration")

        // Pre-existing entities gain no columns, and only `Message` gains a
        // relationship.
        for (name, oldEntity) in v10.entitiesByName {
            let newEntity = try XCTUnwrap(v11.entitiesByName[name])
            XCTAssertEqual(Set(newEntity.attributesByName.keys),
                           Set(oldEntity.attributesByName.keys),
                           "\(name) keeps exactly its v10 columns — the ledger lives in its own "
                           + "entity precisely so no existing row grows")
            let addedRelationships = Set(newEntity.relationshipsByName.keys)
                .subtracting(oldEntity.relationshipsByName.keys)
            let expectedRelationships: Set<String> = name == "Message" ? ["gatewayAttempts"] : []
            XCTAssertEqual(addedRelationships, expectedRelationships,
                           "only `Message` gains a link to the ledger — an attempt is measured "
                           + "against a turn, and `conversationID` covers the rest")
        }

        let attempt = try XCTUnwrap(v11.entitiesByName["GatewayAttempt"])
        let expectedTypes: [String: NSAttributeType] = [
            "id": .UUIDAttributeType,
            "conversationID": .UUIDAttributeType,
            "userMessageID": .UUIDAttributeType,
            "gatewayRef": .stringAttributeType,
            "startedAt": .dateAttributeType,
            "completedAt": .dateAttributeType,
            "outcome": .stringAttributeType,
            "appErrorCode": .integer32AttributeType,
            "originSurface": .stringAttributeType,
            "inputMode": .stringAttributeType,
            "requestedModel": .stringAttributeType,
            "reportedModel": .stringAttributeType,
            "reportedResponseID": .stringAttributeType,
            "finishReason": .stringAttributeType,
            "reportedInputTokens": .integer64AttributeType,
            "reportedOutputTokens": .integer64AttributeType,
            "reportedTotalTokens": .integer64AttributeType,
            "recordVersion": .integer16AttributeType,
        ]
        XCTAssertEqual(Set(attempt.attributesByName.keys), Set(expectedTypes.keys),
                       "the entity ships exactly these columns; an extra one is permanent and a "
                       + "missing one is a fact the account can never carry")
        for (name, attribute) in attempt.attributesByName {
            XCTAssertEqual(attribute.attributeType, expectedTypes[name],
                           "\(name) ships at its settled type: a production CloudKit schema is "
                           + "additive-only, so the type it deploys with is the type it keeps")
            XCTAssertTrue(attribute.isOptional,
                          "\(name) must be optional — CloudKit requires it, and the domain rules "
                          + "that make a field mandatory on a NEW write are enforced in the store")
            XCTAssertNil(attribute.defaultValue,
                         "\(name) must carry NO default: a defaulted counter reports zero tokens "
                         + "for a gateway that reported none, and a defaulted date closes an "
                         + "attempt nobody saw end")
        }

        // The relationship pair, in both directions. The cascade is what makes
        // the deletion promise true — an attempt cannot outlive the turn it
        // measured — and the nullify keeps a surviving attempt from taking a
        // message with it.
        let cascade = try XCTUnwrap(
            v11.entitiesByName["Message"]?.relationshipsByName["gatewayAttempts"])
        XCTAssertTrue(cascade.isToMany)
        XCTAssertTrue(cascade.isOptional)
        XCTAssertEqual(cascade.deleteRule, .cascadeDeleteRule)
        XCTAssertEqual(cascade.destinationEntity?.name, "GatewayAttempt")
        XCTAssertEqual(cascade.inverseRelationship?.name, "userMessage")
        XCTAssertFalse(cascade.isOrdered,
                       "CloudKit rejects an ordered relationship; attempts are ordered in code by "
                       + "startedAt")

        let inverse = try XCTUnwrap(attempt.relationshipsByName["userMessage"])
        XCTAssertFalse(inverse.isToMany)
        XCTAssertEqual(inverse.maxCount, 1)
        XCTAssertTrue(inverse.isOptional)
        XCTAssertEqual(inverse.deleteRule, .nullifyDeleteRule)
        XCTAssertEqual(inverse.inverseRelationship?.name, "gatewayAttempts")
        XCTAssertEqual(Set(attempt.relationshipsByName.keys), ["userMessage"],
                       "no direct Conversation relationship — `conversationID` supplies deletion "
                       + "and query identity without a second merge surface")
    }

    /// DELETING A CONVERSATION DELETES ITS MEASUREMENTS. The dashboard's promise
    /// is that it describes conversations the user has kept, so the graph has to
    /// carry the deletion the whole way down: conversation → messages → attempts,
    /// in one pass, with nothing left addressable afterwards.
    func testDeletingAConversationCascadesThroughMessagesToAttempts() async throws {
        let v11 = try requiredModel(named: "Conversations 11.mom")
        let container = try await loadStore(model: v11)
        let context = container.newBackgroundContext()

        try await context.perform {
            let conversation = NSEntityDescription.insertNewObject(
                forEntityName: "Conversation", into: context)
            conversation.setValue(UUID(), forKey: "id")
            conversation.setValue("openclaw", forKey: "backend")
            conversation.setValue(Date(), forKey: "createdAt")

            let message = NSEntityDescription.insertNewObject(
                forEntityName: "Message", into: context)
            message.setValue(UUID(), forKey: "id")
            message.setValue("user", forKey: "role")
            message.setValue("ask", forKey: "text")
            message.setValue(Date(), forKey: "createdAt")
            message.setValue("iphone-text", forKey: "sourceDevice")
            message.setValue(conversation, forKey: "conversation")

            // Two attempts on one turn: the retry shape, which is exactly the
            // case a per-message delete has to get right.
            for outcome in ["failed", "succeeded"] {
                let attempt = NSEntityDescription.insertNewObject(
                    forEntityName: "GatewayAttempt", into: context)
                attempt.setValue(UUID(), forKey: "id")
                attempt.setValue(outcome, forKey: "outcome")
                attempt.setValue(Date(), forKey: "startedAt")
                attempt.setValue(message, forKey: "userMessage")
            }
            try context.save()

            let attemptRequest = NSFetchRequest<NSManagedObject>(entityName: "GatewayAttempt")
            XCTAssertEqual(try context.count(for: attemptRequest), 2)

            context.delete(conversation)
            try context.save()

            XCTAssertEqual(try context.count(for: attemptRequest), 0,
                           "the cascade runs the whole depth of the graph in one save")
            XCTAssertEqual(
                try context.count(for: NSFetchRequest<NSManagedObject>(entityName: "Message")), 0)
        }
    }

    /// AND THE CASCADE IS NOT ENOUGH ON ITS OWN, which is why the scalar
    /// `conversationID` is stored beside the relationship rather than derived
    /// from it.
    ///
    /// A row can genuinely arrive with no `userMessage`: CloudKit imports records
    /// and relationships out of order, and a client old enough not to know the
    /// entity cannot run the cascade at all. Such a row is invisible to
    /// `Conversation → Message → GatewayAttempt` and would survive the deletion
    /// of everything it describes. The scalar is what a delete-by-conversation
    /// can still reach, and this test pins both halves of that: the cascade
    /// misses the detached row, and the scalar predicate finds it.
    func testADetachedAttemptSurvivesTheCascadeAndIsReachableByItsScalarConversationID()
        async throws {
        let v11 = try requiredModel(named: "Conversations 11.mom")
        let container = try await loadStore(model: v11)
        let context = container.newBackgroundContext()
        let conversationID = UUID()

        try await context.perform {
            let conversation = NSEntityDescription.insertNewObject(
                forEntityName: "Conversation", into: context)
            conversation.setValue(conversationID, forKey: "id")
            conversation.setValue("hermes", forKey: "backend")
            conversation.setValue(Date(), forKey: "createdAt")

            let message = NSEntityDescription.insertNewObject(
                forEntityName: "Message", into: context)
            message.setValue(UUID(), forKey: "id")
            message.setValue("user", forKey: "role")
            message.setValue("ask", forKey: "text")
            message.setValue(Date(), forKey: "createdAt")
            message.setValue("mac-text", forKey: "sourceDevice")
            message.setValue(conversation, forKey: "conversation")

            // Attached: the cascade will take this one.
            let attached = NSEntityDescription.insertNewObject(
                forEntityName: "GatewayAttempt", into: context)
            attached.setValue(UUID(), forKey: "id")
            attached.setValue(conversationID, forKey: "conversationID")
            attached.setValue("succeeded", forKey: "outcome")
            attached.setValue(message, forKey: "userMessage")

            // Detached: same conversation by scalar, no relationship at all.
            let detachedID = UUID()
            let detached = NSEntityDescription.insertNewObject(
                forEntityName: "GatewayAttempt", into: context)
            detached.setValue(detachedID, forKey: "id")
            detached.setValue(conversationID, forKey: "conversationID")
            detached.setValue("succeeded", forKey: "outcome")
            try context.save()

            context.delete(conversation)
            try context.save()

            let request = NSFetchRequest<NSManagedObject>(entityName: "GatewayAttempt")
            let survivors = try context.fetch(request)
            XCTAssertEqual(survivors.count, 1,
                           "the cascade cannot see a row that never had the relationship — which is "
                           + "precisely the row an out-of-order CloudKit import produces")
            XCTAssertEqual(survivors.first?.value(forKey: "id") as? UUID, detachedID)

            // The scalar is the handle that still reaches it.
            let byScalar = NSFetchRequest<NSManagedObject>(entityName: "GatewayAttempt")
            byScalar.predicate = NSPredicate(
                format: "conversationID == %@", conversationID as CVarArg)
            let reachable = try context.fetch(byScalar)
            XCTAssertEqual(reachable.count, 1)
            for row in reachable { context.delete(row) }
            try context.save()

            XCTAssertEqual(try context.count(for: request), 0,
                           "an explicit scalar-keyed delete completes what the cascade started — "
                           + "this is the sweep `deleteConversation` owes the ledger")
        }
    }

    /// v12 is ADDITIVE in its columns and changes exactly ONE rule: it adds five
    /// optional attributes to `GatewayAttempt` and flips `Message.gatewayAttempts`
    /// from cascade to nullify. Nothing else may differ from v11 — a second change
    /// slipped into the same version deploys to a production CloudKit schema that
    /// is additive-only and can never take it back.
    ///
    /// THE DELETE RULE IS THE POINT OF THE VERSION. Usage history is content-free
    /// by construction, so it has no reason to share the lifetime of the content:
    /// deleting a conversation removes what was said, and the measurement of the
    /// dispatch survives so trends do not collapse every time the user tidies up.
    /// The user clears usage history explicitly, through its own control. v11
    /// keeps its cascade in its own test above — a shipped model is history, and
    /// only the version the app opens is asserted to nullify.
    func testV12AddsFiveAttemptAttributesAndNothingElse() throws {
        let v11 = try requiredModel(named: "Conversations 11.mom")
        let v12 = try requiredModel(named: "Conversations 12.mom")

        XCTAssertEqual(Set(v11.entitiesByName.keys), Set(v12.entitiesByName.keys),
                       "no entity appears or disappears — an entity change is not lightweight")

        let expectedAdditions: [String: Set<String>] = [
            "Attachment": [],
            "Conversation": [],
            "Message": [],
            "GatewayAttempt": [
                "originDeviceClass",
                "currentTurnInlineImageCount",
                "priorTurnInlineImageCount",
                "currentTurnInlineTextFileCount",
                "priorTurnInlineTextFileCount",
            ],
        ]
        let expectedTypes: [String: NSAttributeType] = [
            "originDeviceClass": .stringAttributeType,
            "currentTurnInlineImageCount": .integer32AttributeType,
            "priorTurnInlineImageCount": .integer32AttributeType,
            "currentTurnInlineTextFileCount": .integer32AttributeType,
            "priorTurnInlineTextFileCount": .integer32AttributeType,
        ]

        for (name, newEntity) in v12.entitiesByName {
            let oldEntity = try XCTUnwrap(v11.entitiesByName[name])
            let added = Set(newEntity.attributesByName.keys)
                .subtracting(oldEntity.attributesByName.keys)
            let removed = Set(oldEntity.attributesByName.keys)
                .subtracting(newEntity.attributesByName.keys)
            XCTAssertTrue(removed.isEmpty,
                          "\(name) lost \(removed.sorted()) — a removal is data loss, not a migration")
            let expectedForEntity = try XCTUnwrap(expectedAdditions[name])
            XCTAssertEqual(added, expectedForEntity,
                           "\(name) gains exactly the columns this version reviewed — an extra one "
                           + "is permanent, and a missing one is a fact the account can never carry")
            XCTAssertEqual(
                Set(newEntity.relationshipsByName.keys), Set(oldEntity.relationshipsByName.keys),
                "\(name) keeps its relationships — a relationship change is not lightweight")

            for attribute in added.compactMap({ newEntity.attributesByName[$0] }) {
                XCTAssertEqual(attribute.attributeType, expectedTypes[attribute.name],
                               "\(attribute.name) ships at its settled type: a production CloudKit "
                               + "schema is additive-only, so the type it deploys with is the type "
                               + "it keeps forever")
                XCTAssertTrue(attribute.isOptional,
                              "\(attribute.name) must be optional — CloudKit requires it, and every "
                              + "row written before this version is genuinely UNMEASURED")
                XCTAssertNil(
                    attribute.defaultValue,
                    "\(attribute.name) must carry NO default: a default is written to every "
                    + "pre-existing row at migration time, so a zero here would claim the whole "
                    + "history was inspected and found to carry no images and no files — a "
                    + "measurement nobody took, indistinguishable afterwards from one that was")
            }
        }

        // The one rule change, in both directions. Nullify is what lets a
        // content-free row outlive the turn it measured; the inverse stays
        // nullify so a surviving attempt never takes a message with it.
        let link = try XCTUnwrap(
            v12.entitiesByName["Message"]?.relationshipsByName["gatewayAttempts"])
        XCTAssertEqual(link.deleteRule, .nullifyDeleteRule,
                       "deleting a conversation must leave its measurements standing — usage "
                       + "history is cleared through its own control, never as a side effect")
        XCTAssertTrue(link.isToMany)
        XCTAssertTrue(link.isOptional)
        XCTAssertFalse(link.isOrdered,
                       "CloudKit rejects an ordered relationship; attempts are ordered in code by "
                       + "startedAt")
        XCTAssertEqual(link.destinationEntity?.name, "GatewayAttempt")
        XCTAssertEqual(link.inverseRelationship?.name, "userMessage")

        let inverse = try XCTUnwrap(
            v12.entitiesByName["GatewayAttempt"]?.relationshipsByName["userMessage"])
        XCTAssertEqual(inverse.deleteRule, .nullifyDeleteRule)
        XCTAssertEqual(inverse.maxCount, 1)
        XCTAssertTrue(inverse.isOptional)
    }

    /// A v11 store — the one the previous release installed — opens under v12 with
    /// every ledger row intact and the five new columns reading nil. Nil is the
    /// load-bearing part: a legacy row was written before anything counted
    /// attachments, so it is UNMEASURED, and the dashboard's coverage figures rest
    /// on being able to tell that apart from a turn that carried none.
    func testV11StoreMigratesToV12WithNilAttachmentShapeColumns() async throws {
        let v11 = try requiredModel(named: "Conversations 11.mom")
        let v12 = try requiredModel(named: "Conversations 12.mom")
        let conversationID = UUID()
        let messageID = UUID()
        let attemptID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let completedAt = Date(timeIntervalSince1970: 1_800_000_007)

        do {
            let container = try await loadStore(model: v11)
            let context = container.newBackgroundContext()
            try await context.perform {
                let conversation = NSEntityDescription.insertNewObject(
                    forEntityName: "Conversation", into: context)
                conversation.setValue(conversationID, forKey: "id")
                conversation.setValue("hermes", forKey: "backend")
                conversation.setValue(startedAt, forKey: "createdAt")

                let message = NSEntityDescription.insertNewObject(
                    forEntityName: "Message", into: context)
                message.setValue(messageID, forKey: "id")
                message.setValue("user", forKey: "role")
                message.setValue("a measured turn", forKey: "text")
                message.setValue(startedAt, forKey: "createdAt")
                message.setValue("ipad-voice", forKey: "sourceDevice")
                message.setValue(conversation, forKey: "conversation")

                let attempt = NSEntityDescription.insertNewObject(
                    forEntityName: "GatewayAttempt", into: context)
                attempt.setValue(attemptID, forKey: "id")
                attempt.setValue(conversationID, forKey: "conversationID")
                attempt.setValue(messageID, forKey: "userMessageID")
                attempt.setValue("hermes", forKey: "gatewayRef")
                attempt.setValue(startedAt, forKey: "startedAt")
                attempt.setValue(completedAt, forKey: "completedAt")
                attempt.setValue("succeeded", forKey: "outcome")
                attempt.setValue("app", forKey: "originSurface")
                attempt.setValue("voice", forKey: "inputMode")
                attempt.setValue(NSNumber(value: Int64(1_234)), forKey: "reportedTotalTokens")
                attempt.setValue(NSNumber(value: Int16(1)), forKey: "recordVersion")
                attempt.setValue(message, forKey: "userMessage")
                try context.save()
            }
            for store in container.persistentStoreCoordinator.persistentStores {
                try container.persistentStoreCoordinator.remove(store)
            }
        }

        let container = try await loadStore(model: v12)
        let context = container.newBackgroundContext()
        try await context.perform {
            let request = NSFetchRequest<NSManagedObject>(entityName: "GatewayAttempt")
            request.predicate = NSPredicate(format: "id == %@", attemptID as CVarArg)
            request.fetchLimit = 1
            let attempt = try XCTUnwrap(context.fetch(request).first,
                                        "the v11 ledger row must survive migration")

            XCTAssertEqual(attempt.value(forKey: "conversationID") as? UUID, conversationID)
            XCTAssertEqual(attempt.value(forKey: "userMessageID") as? UUID, messageID)
            XCTAssertEqual(attempt.value(forKey: "gatewayRef") as? String, "hermes")
            XCTAssertEqual(attempt.value(forKey: "startedAt") as? Date, startedAt)
            XCTAssertEqual(attempt.value(forKey: "completedAt") as? Date, completedAt)
            XCTAssertEqual(attempt.value(forKey: "outcome") as? String, "succeeded")
            XCTAssertEqual(attempt.value(forKey: "reportedTotalTokens") as? NSNumber,
                           NSNumber(value: Int64(1_234)))
            XCTAssertEqual((attempt.value(forKey: "userMessage") as? NSManagedObject)?
                .value(forKey: "id") as? UUID, messageID,
                "the relationship survives the rule change — only what DELETION does to it changed")

            for column in ["originDeviceClass", "currentTurnInlineImageCount",
                           "priorTurnInlineImageCount", "currentTurnInlineTextFileCount",
                           "priorTurnInlineTextFileCount"] {
                XCTAssertNil(
                    attempt.value(forKey: column),
                    "GatewayAttempt.\(column) must be nil on a pre-v12 row — it was written before "
                    + "anything counted, and a zero would report an inspection that never happened")
            }

            // And a NEW row records an explicit zero, which is what makes the nil
            // above mean UNMEASURED rather than NONE.
            let fresh = NSEntityDescription.insertNewObject(
                forEntityName: "GatewayAttempt", into: context)
            fresh.setValue(UUID(), forKey: "id")
            fresh.setValue(conversationID, forKey: "conversationID")
            fresh.setValue(Date(timeIntervalSince1970: 1_800_000_100), forKey: "startedAt")
            fresh.setValue("iphone", forKey: "originDeviceClass")
            fresh.setValue(NSNumber(value: Int32(2)), forKey: "currentTurnInlineImageCount")
            fresh.setValue(NSNumber(value: Int32(0)), forKey: "priorTurnInlineImageCount")
            fresh.setValue(NSNumber(value: Int32(1)), forKey: "currentTurnInlineTextFileCount")
            fresh.setValue(NSNumber(value: Int32(0)), forKey: "priorTurnInlineTextFileCount")
            try context.save()

            XCTAssertEqual(fresh.value(forKey: "originDeviceClass") as? String, "iphone")
            XCTAssertEqual(fresh.value(forKey: "currentTurnInlineImageCount") as? NSNumber,
                           NSNumber(value: Int32(2)))
            XCTAssertEqual(fresh.value(forKey: "priorTurnInlineImageCount") as? NSNumber,
                           NSNumber(value: Int32(0)))
            XCTAssertEqual(fresh.value(forKey: "currentTurnInlineTextFileCount") as? NSNumber,
                           NSNumber(value: Int32(1)))
            XCTAssertEqual(fresh.value(forKey: "priorTurnInlineTextFileCount") as? NSNumber,
                           NSNumber(value: Int32(0)))
        }
    }

    /// THE SKIPPED-VERSION PATH. A device that never launched the v11 release
    /// migrates v10 → v12 in one hop, which Core Data infers as a single mapping
    /// rather than a replay of each step. It has to land in the same place: the
    /// history intact, the ledger EMPTY, and nothing back-filled — a fabricated
    /// row per historical message would make every rate a fiction, and a fresh
    /// attachment count on it would compound the fiction with a measurement.
    func testV10StoreMigratesToV12SkippingV11() async throws {
        let v10 = try requiredModel(named: "Conversations 10.mom")
        let v12 = try requiredModel(named: "Conversations 12.mom")
        let messageID = UUID()
        let createdAt = Date(timeIntervalSince1970: 1_799_000_000)

        do {
            let container = try await loadStore(model: v10)
            let context = container.newBackgroundContext()
            try await context.perform {
                let conversation = NSEntityDescription.insertNewObject(
                    forEntityName: "Conversation", into: context)
                conversation.setValue(UUID(), forKey: "id")
                conversation.setValue("openclaw", forKey: "backend")
                conversation.setValue(createdAt, forKey: "createdAt")

                let message = NSEntityDescription.insertNewObject(
                    forEntityName: "Message", into: context)
                message.setValue(messageID, forKey: "id")
                message.setValue("user", forKey: "role")
                message.setValue("a turn from before the ledger", forKey: "text")
                message.setValue(createdAt, forKey: "createdAt")
                message.setValue("mac-text", forKey: "sourceDevice")
                message.setValue("sent", forKey: "status")
                message.setValue(conversation, forKey: "conversation")
                try context.save()
            }
            for store in container.persistentStoreCoordinator.persistentStores {
                try container.persistentStoreCoordinator.remove(store)
            }
        }

        let container = try await loadStore(model: v12)
        let context = container.newBackgroundContext()
        try await context.perform {
            let messageRequest = NSFetchRequest<NSManagedObject>(entityName: "Message")
            messageRequest.predicate = NSPredicate(format: "id == %@", messageID as CVarArg)
            messageRequest.fetchLimit = 1
            let message = try XCTUnwrap(context.fetch(messageRequest).first,
                                        "the v10 message row must survive the two-version hop")
            XCTAssertEqual(message.value(forKey: "text") as? String,
                           "a turn from before the ledger")
            XCTAssertEqual(message.value(forKey: "sourceDevice") as? String, "mac-text")
            XCTAssertEqual(message.value(forKey: "createdAt") as? Date, createdAt)

            XCTAssertEqual(
                try context.count(for: NSFetchRequest<NSManagedObject>(entityName: "GatewayAttempt")),
                0,
                "migration back-fills NOTHING across any number of versions at once")
            XCTAssertEqual((message.value(forKey: "gatewayAttempts") as? NSSet)?.count, 0)
        }
    }

    /// THE PROMISE THE VERSION EXISTS FOR, proved on a store that actually
    /// migrated rather than one born under v12 — the delete rule that governs a
    /// migrated store is the one baked into the destination model, and this is the
    /// only test that demonstrates it on the path a real device takes.
    ///
    /// Deleting the conversation still removes the content: the conversation and
    /// its messages go. The attempt row stays, its link nulled, its scalar
    /// snapshots — conversation id, gateway, timings, tokens — intact, because
    /// they are what the dashboard reads and none of them says anything about what
    /// was typed or answered.
    func testAMigratedV11AttemptSurvivesConversationDeletionUnderV12() async throws {
        let v11 = try requiredModel(named: "Conversations 11.mom")
        let v12 = try requiredModel(named: "Conversations 12.mom")
        let conversationID = UUID()
        let messageID = UUID()
        let attemptID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_800_500_000)

        do {
            let container = try await loadStore(model: v11)
            let context = container.newBackgroundContext()
            try await context.perform {
                let conversation = NSEntityDescription.insertNewObject(
                    forEntityName: "Conversation", into: context)
                conversation.setValue(conversationID, forKey: "id")
                conversation.setValue("openclaw", forKey: "backend")
                conversation.setValue(startedAt, forKey: "createdAt")

                let message = NSEntityDescription.insertNewObject(
                    forEntityName: "Message", into: context)
                message.setValue(messageID, forKey: "id")
                message.setValue("user", forKey: "role")
                message.setValue("something the user later deletes", forKey: "text")
                message.setValue(startedAt, forKey: "createdAt")
                message.setValue("iphone-voice", forKey: "sourceDevice")
                message.setValue(conversation, forKey: "conversation")

                let attempt = NSEntityDescription.insertNewObject(
                    forEntityName: "GatewayAttempt", into: context)
                attempt.setValue(attemptID, forKey: "id")
                attempt.setValue(conversationID, forKey: "conversationID")
                attempt.setValue(messageID, forKey: "userMessageID")
                attempt.setValue("openclaw", forKey: "gatewayRef")
                attempt.setValue(startedAt, forKey: "startedAt")
                attempt.setValue("succeeded", forKey: "outcome")
                attempt.setValue(NSNumber(value: Int64(4_096)), forKey: "reportedTotalTokens")
                attempt.setValue(NSNumber(value: Int16(1)), forKey: "recordVersion")
                attempt.setValue(message, forKey: "userMessage")
                try context.save()
            }
            for store in container.persistentStoreCoordinator.persistentStores {
                try container.persistentStoreCoordinator.remove(store)
            }
        }

        let container = try await loadStore(model: v12)
        let context = container.newBackgroundContext()
        try await context.perform {
            let conversationRequest = NSFetchRequest<NSManagedObject>(entityName: "Conversation")
            conversationRequest.predicate = NSPredicate(
                format: "id == %@", conversationID as CVarArg)
            let conversation = try XCTUnwrap(context.fetch(conversationRequest).first)

            context.delete(conversation)
            try context.save()

            XCTAssertEqual(
                try context.count(for: NSFetchRequest<NSManagedObject>(entityName: "Conversation")),
                0)
            XCTAssertEqual(
                try context.count(for: NSFetchRequest<NSManagedObject>(entityName: "Message")), 0,
                "the content goes — the conversation still cascades to its messages")

            let attemptRequest = NSFetchRequest<NSManagedObject>(entityName: "GatewayAttempt")
            attemptRequest.predicate = NSPredicate(format: "id == %@", attemptID as CVarArg)
            let attempt = try XCTUnwrap(
                context.fetch(attemptRequest).first,
                "the measurement outlives the content it measured — that is the whole of v12, and "
                + "without it every trend resets each time the user deletes a conversation")

            XCTAssertNil(attempt.value(forKey: "userMessage"),
                         "the link nullifies rather than cascading; the row keeps no handle on a "
                         + "message that no longer exists")
            XCTAssertEqual(attempt.value(forKey: "conversationID") as? UUID, conversationID,
                           "the scalar snapshots survive — they are what the dashboard groups by, "
                           + "and none of them carries content")
            XCTAssertEqual(attempt.value(forKey: "userMessageID") as? UUID, messageID)
            XCTAssertEqual(attempt.value(forKey: "gatewayRef") as? String, "openclaw")
            XCTAssertEqual(attempt.value(forKey: "startedAt") as? Date, startedAt)
            XCTAssertEqual(attempt.value(forKey: "outcome") as? String, "succeeded")
            XCTAssertEqual(attempt.value(forKey: "reportedTotalTokens") as? NSNumber,
                           NSNumber(value: Int64(4_096)))
        }
    }

    /// The model the APP opens is v12. A pointer left on an older version would
    /// ship code that reads columns a store does not have — and, worse, would not
    /// fail loudly at the ledger's edges: KVC on a missing attribute is what the
    /// record's tolerant reads are built to survive, so the dashboard would simply
    /// report an account that measured nothing. A stale pointer would also leave
    /// the cascade in force, quietly deleting usage history the app now promises
    /// to keep.
    func testTheCurrentModelVersionIsV12() throws {
        let bundles = [Bundle.main, Bundle(for: Self.self)]
        let momd = try XCTUnwrap(
            bundles.compactMap { $0.url(forResource: "Conversations", withExtension: "momd") }.first,
            "compiled Conversations.momd not found in the host app bundle")
        let plist = try XCTUnwrap(
            NSDictionary(contentsOf: momd.appendingPathComponent("VersionInfo.plist")),
            "a compiled momd always carries VersionInfo.plist")
        XCTAssertEqual(plist["NSManagedObjectModel_CurrentVersionName"] as? String, "Conversations 12")
    }
}
