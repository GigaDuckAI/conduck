// SPDX-License-Identifier: Apache-2.0

// Accepted Work input history is metadata, independent of current project
// placement and source bytes. Exercise persistence, missing sync halves and
// clone lane filtering so a file name or a partial send never invents usage.

import XCTest
import CoreData
@testable import Conduck

final class WorkDeskMaterialUsageTests: XCTestCase {
    private let isolated = IsolatedWorkStores()

    override func tearDown() async throws {
        await isolated.cleanUp()
        try await super.tearDown()
    }

    func testOnlyExplicitAcceptedInputCountsAcrossProjectsAndGateways() async throws {
        let store = isolated.make()
        let materialID = UUID()
        let unused = try await store.createConversation(backend: "hermes", title: "Never submitted")
        _ = try await store.appendMessage(role: "user", text: "Later ordinary message",
            conversationID: unused.id, sourceDevice: "test")
        let initialUses = try await store.fetchWorkDeskMaterialUses()
        XCTAssertTrue(initialUses.isEmpty)
        var conversationIDs = Set<UUID>()
        for backend in ["hermes", "openclaw"] {
            let conversation = try await store.createConversation(backend: backend, title: "Reviewed task")
            conversationIDs.insert(conversation.id)
            _ = try await store.appendMessage(role: "user", text: "Immutable reviewed words and notes",
                conversationID: conversation.id, sourceDevice: "test", status: "sending",
                workMaterialInputs: [.init(materialID: materialID), .init(materialID: materialID)])
            _ = try await store.appendMessage(role: "user", text: "Follow up", conversationID: conversation.id, sourceDevice: "test")
        }
        let uses = try await store.fetchWorkDeskMaterialUses()
        XCTAssertEqual(Set(uses[materialID, default: []].map(\.conversationID)), conversationIDs)
        XCTAssertEqual(Set(uses[materialID, default: []].map(\.gatewayRef)), ["hermes", "openclaw"])
        XCTAssertEqual(uses[materialID]?.count, 2, "Repeated IDs and followups never multiply a conversation")
        let removedID = try XCTUnwrap(conversationIDs.first)
        try await store.deleteConversation(id: removedID)
        let remaining = try await store.fetchWorkDeskMaterialUses()
        XCTAssertEqual(remaining[materialID]?.count, 1)
        XCTAssertNotEqual(remaining[materialID]?.first?.conversationID, removedID)
    }

    func testMissingOrMismatchedAcceptedMessageFailsClosedAndRecoversAfterSync() async throws {
        let store = isolated.make()
        let materialID = UUID()
        let conversation = try await store.createConversation(backend: "hermes")
        let message = try await store.appendMessage(role: "user", text: "Review", conversationID: conversation.id,
            sourceDevice: "test", workMaterialInputs: [.init(materialID: materialID)])
        let missingMessageID = UUID()
        let context = await store.newWriteContext()
        try await context.perform {
            let request = NSFetchRequest<NSManagedObject>(entityName: "Conversation")
            request.predicate = NSPredicate(format: "id == %@", conversation.id as CVarArg)
            let row = try XCTUnwrap(context.fetch(request).first)
            let usage = WorkDeskMaterialUsage(messageID: missingMessageID, inputs: [.init(materialID: materialID)])
            row.setValue(try usage.encoded(), forKey: "workMaterialUsageJSON")
            try context.save()
        }
        let missingUses = try await store.fetchWorkDeskMaterialUses()
        XCTAssertTrue(missingUses.isEmpty)
        let other = try await store.createConversation(backend: "openclaw")
        _ = try await store.appendMessage(id: missingMessageID, role: "user", text: "Other owner", conversationID: other.id, sourceDevice: "test")
        let mismatchedUses = try await store.fetchWorkDeskMaterialUses()
        XCTAssertTrue(mismatchedUses.isEmpty, "A same-named message in another conversation is not acceptance")
        try await context.perform {
            let request = NSFetchRequest<NSManagedObject>(entityName: "Conversation")
            request.predicate = NSPredicate(format: "id == %@", conversation.id as CVarArg)
            let row = try XCTUnwrap(context.fetch(request).first)
            row.setValue(try WorkDeskMaterialUsage(messageID: message.id, inputs: [.init(materialID: materialID)]).encoded(), forKey: "workMaterialUsageJSON")
            try context.save()
        }
        let recoveredUses = try await store.fetchWorkDeskMaterialUses()
        XCTAssertEqual(recoveredUses[materialID]?.count, 1)
    }

    func testCloneRetainsOnlyInputSnapshotsThatSurviveItsFileLane() async throws {
        let store = isolated.make()
        let noteID = UUID(), imageID = UUID(), remoteFileID = UUID()
        let conversation = try await store.createConversation(backend: "hermes")
        let imageBytes = Data("inline snapshot".utf8)
        let inline = AttachmentDraft(mimeType: "text/plain", filename: "same-name.txt", data: imageBytes,
            thumbnailData: nil, width: 0, height: 0, byteSize: imageBytes.count, sequence: 0)
        var remote = AttachmentDraft(mimeType: "application/pdf", filename: "same-name.txt", data: Data(),
            thumbnailData: nil, width: 0, height: 0, byteSize: 42, sequence: 1)
        remote.isServerReference = true
        remote.storedKey = "a-file-key"
        _ = try await store.appendMessage(role: "user", text: "Reviewed input and notes", conversationID: conversation.id,
            sourceDevice: "test", fileTransferLaneID: "original-lane", attachments: [inline, remote],
            workMaterialInputs: [.init(materialID: noteID), .init(materialID: imageID, attachmentSequence: 0),
                                 .init(materialID: remoteFileID, attachmentSequence: 1)])
        let detached = try await store.cloneConversation(id: conversation.id, toBackend: "openclaw")
        let carried = try await store.cloneConversation(id: conversation.id, toBackend: "openclaw", targetFileLaneID: "original-lane")
        let uses = try await store.fetchWorkDeskMaterialUses()
        XCTAssertEqual(Set(uses[noteID, default: []].map(\.conversationID)), [conversation.id, detached.conversation.id, carried.conversation.id])
        XCTAssertEqual(uses[imageID]?.count, 3)
        XCTAssertEqual(Set(uses[remoteFileID, default: []].map(\.conversationID)), [conversation.id, carried.conversation.id])
        try await store.deleteConversation(id: conversation.id)
        let survivingUses = try await store.fetchWorkDeskMaterialUses()
        XCTAssertEqual(survivingUses[imageID]?.count, 2,
            "Cloned receipts name the copied user message, so the source conversation can disappear")
    }

    func testSQLiteUsageProjectionPersistsWithoutLoadingSourceMaterialBytes() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("material-use-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("store.sqlite")
        let store = isolated.make(storeURL: url)
        let materialID = UUID()
        let conversation = try await store.createConversation(backend: "hermes", title: "Recorded usage")
        _ = try await store.appendMessage(role: "user", text: "Reviewed words", conversationID: conversation.id,
            sourceDevice: "test", workMaterialInputs: [.init(materialID: materialID)])
        try await store._unloadForTesting()
        let reopened = isolated.make(storeURL: url)
        let uses = try await reopened.fetchWorkDeskMaterialUses()
        XCTAssertEqual(uses[materialID]?.first?.conversationTitle, "Recorded usage")
        XCTAssertEqual(uses[materialID]?.first?.conversationID, conversation.id)
        try await reopened._unloadForTesting()
    }

    func testUnknownReceiptFormatDoesNotInventUsage() throws {
        XCTAssertNil(WorkDeskMaterialUsage(json: "not JSON"))
        let valid = WorkDeskMaterialUsage(messageID: UUID(), inputs: [.init(materialID: UUID())])
        let future = try valid.encoded().replacingOccurrences(of: "\"version\":1", with: "\"version\":99")
        XCTAssertNil(WorkDeskMaterialUsage(json: future))
        let invalidSequence = WorkDeskMaterialUsage(messageID: UUID(), inputs: [.init(materialID: UUID(), attachmentSequence: -1)])
        XCTAssertNil(WorkDeskMaterialUsage(json: try invalidSequence.encoded()))
    }
}
