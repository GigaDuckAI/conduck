// SPDX-License-Identifier: Apache-2.0

// Project membership must survive storage without changing gateway binding or
// conversation history. Results are explicit persisted files, not prose or user
// inputs, and the receipt prevents resurrection after the person deletes one.

import XCTest
@testable import Conduck

final class WorkDeskProjectConversationTests: XCTestCase {
    private let isolated = IsolatedWorkStores()
    override func tearDown() async throws {
        await isolated.cleanUp()
        try await super.tearDown()
    }

    private func file(_ name: String = "result.txt", mime: String = "text/plain") -> AttachmentDraft {
        let bytes = Data("file contents".utf8)
        return AttachmentDraft(mimeType: mime, filename: name, data: bytes,
            thumbnailData: nil, width: 0, height: 0, byteSize: bytes.count, sequence: 0)
    }

    /// The existing append API returns optimistic attachment snapshots with
    /// synthetic IDs. Provenance and mutations must name the committed rows,
    /// exactly as the production reconciler does when it refetches a message.
    private func storedAttachmentID(
        for message: MessageRecord, conversationID: UUID, store: ConversationStore
    ) async throws -> UUID {
        let stored = try await store.fetchMessage(id: message.id, in: conversationID)
        return try XCTUnwrap(stored?.attachments.first?.id)
    }

    func testOrdinaryChatsNeverEnumerateProjectMessageHistory() async throws {
        let store = isolated.make()
        let project = WorkDeskProjectRecord(title: "Unrelated project")
        _ = try await store.applyWorkDeskMutation(.createProject(project, materialIDs: []))
        let projectConversation = try await store.createConversation(backend: "hermes", projectID: project.id)
        _ = try await store.appendMessage(role: "agent", text: "Output", conversationID: projectConversation.id,
            sourceDevice: "test", attachments: [file()])
        await store.reconcileProjectResults()
        let before = await store._projectResultMessageFetchCountForTesting()
        let ordinary = try await store.createConversation(backend: "hermes")
        for index in 0..<100 {
            _ = try await store.appendMessage(role: index.isMultiple(of: 2) ? "user" : "agent",
                text: "Ordinary chat", conversationID: ordinary.id, sourceDevice: "test",
                attachments: index.isMultiple(of: 9) ? [file()] : [])
        }
        let last = try await store.appendMessage(role: "agent", text: "Late attachment", conversationID: ordinary.id,
            sourceDevice: "test")
        try await store.addAttachments(messageID: last.id, attachments: [file()])
        let after = await store._projectResultMessageFetchCountForTesting()
        XCTAssertEqual(after, before,
            "Unfiled chat writes must not run a Message fetch, even beside an existing project with outputs")
    }

    func testSQLiteLocalRemoteChangeNotificationsDoNotRescanProjectHistory() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("project-scan-sqlite-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = isolated.make(storeURL: directory.appendingPathComponent("store.sqlite"))
        let project = WorkDeskProjectRecord(title: "Existing project")
        _ = try await store.applyWorkDeskMutation(.createProject(project, materialIDs: []))
        let projectConversation = try await store.createConversation(backend: "hermes", projectID: project.id)
        _ = try await store.appendMessage(role: "agent", text: "Output", conversationID: projectConversation.id,
            sourceDevice: "test", attachments: [file()])
        await store.reconcileProjectResults()
        // Let SQLite's own remote-change notification reach its UI debouncer.
        try await Task.sleep(for: .milliseconds(600))
        let before = await store._projectResultMessageFetchCountForTesting()
        let ordinary = try await store.createConversation(backend: "hermes")
        for _ in 0..<20 {
            _ = try await store.appendMessage(role: "agent", text: "Unrelated", conversationID: ordinary.id,
                sourceDevice: "test", attachments: [file()])
        }
        try await Task.sleep(for: .milliseconds(600))
        let after = await store._projectResultMessageFetchCountForTesting()
        XCTAssertEqual(after, before,
            "Local SQLite saves emit remote-change notifications but are not CloudKit imports")
        try await store._unloadForTesting()
    }

    func testRecoveryWithoutAnyProjectConversationDoesNotQueryMessages() async throws {
        let store = isolated.make()
        let conversation = try await store.createConversation(backend: "hermes")
        for _ in 0..<20 {
            _ = try await store.appendMessage(role: "agent", text: "Unfiled history", conversationID: conversation.id,
                sourceDevice: "test", attachments: [file()])
        }
        await store.reconcileProjectResults()
        let count = await store._projectResultMessageFetchCountForTesting()
        XCTAssertEqual(count, 0)
    }

    func testMultipleGatewaysShareProjectOrganizationWithoutSharingHistory() async throws {
        let store = isolated.make()
        let project = WorkDeskProjectRecord(title: "Launch", brief: "Private standing context")
        _ = try await store.applyWorkDeskMutation(.createProject(project, materialIDs: []))
        let first = try await store.createConversation(backend: "hermes", projectID: project.id, title: "Research")
        let second = try await store.createConversation(backend: "openclaw", projectID: project.id, title: "Design")
        _ = try await store.appendMessage(role: "user", text: "Only the first sees this", conversationID: first.id, sourceDevice: "test")
        let conversations = try await store.fetchProjectConversations(projectID: project.id)
        XCTAssertEqual(Set(conversations.map(\.backend)), ["hermes", "openclaw"])
        XCTAssertEqual(Set(conversations.map(\.projectID)), [project.id])
        XCTAssertEqual(Set(conversations.compactMap(\.title)), ["Research", "Design"])
        let secondMessages = try await store.fetchMessages(for: second.id)
        XCTAssertTrue(secondMessages.isEmpty)
        let firstMessages = try await store.fetchMessages(for: first.id)
        XCTAssertEqual(firstMessages.map(\.text), ["Only the first sees this"])
    }

    func testMissingAndDeletedProjectsRefuseNewConversationWithoutPartialInsert() async throws {
        let store = isolated.make()
        let project = WorkDeskProjectRecord(title: "Gone")
        _ = try await store.applyWorkDeskMutation(.createProject(project, materialIDs: []))
        _ = try await store.applyWorkDeskMutation(.deleteProject(id: project.id))
        for projectID in [project.id, UUID()] {
            do {
                _ = try await store.createConversation(backend: "hermes", projectID: projectID)
                XCTFail("A missing destination must not create an unowned chat")
            } catch WorkDeskStoreError.projectNotFound { }
        }
        let all = try await store.fetchConversations()
        XCTAssertTrue(all.isEmpty)
    }

    func testOnlyReturnedNonAudioFilesBecomeProjectMaterialsWithProvenance() async throws {
        let store = isolated.make()
        let project = WorkDeskProjectRecord(title: "Research")
        _ = try await store.applyWorkDeskMutation(.createProject(project, materialIDs: []))
        let conversation = try await store.createConversation(backend: "hermes", projectID: project.id)
        _ = try await store.appendMessage(role: "user", text: "Input", conversationID: conversation.id,
            sourceDevice: "test", attachments: [file("input.txt")])
        let reply = try await store.appendMessage(role: "agent", text: "Prose stays in chat https://example.invalid/report.pdf",
            conversationID: conversation.id, sourceDevice: "test", attachments: [file(), file("voice.mp3", mime: "audio/mpeg")])
        await store.reconcileProjectResults()
        let desk = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        XCTAssertEqual(desk?.materials.count, 1)
        let result = try XCTUnwrap(desk?.materials.first)
        XCTAssertEqual(result.filename, "result.txt")
        XCTAssertTrue(result.isProjectResult)
        XCTAssertFalse(result.isRemoteProjectResult)
        let projected = await WorkboardLiveRepository.presentationSnapshotForTesting(result)
        XCTAssertTrue(projected.isProjectResult)
        let payload = try await store.loadWorkMaterialPayload(id: result.id)
        XCTAssertEqual(payload, Data("file contents".utf8))
        let sources = try await store.fetchWorkDeskResults()
        XCTAssertEqual(sources[result.id]?.conversationID, conversation.id)
        XCTAssertEqual(sources[result.id]?.messageID, reply.id)
        XCTAssertEqual(sources[result.id]?.gatewayRef, "hermes")
        let placement = try await store.fetchWorkDeskOrganization()
        XCTAssertEqual(placement.placements[result.id]?.projectID, project.id)
    }

    func testReplayPreservesMovedCardAndDeletedCardNeverResurrects() async throws {
        let store = isolated.make()
        let project = WorkDeskProjectRecord(title: "Origin")
        let other = WorkDeskProjectRecord(title: "Keep here")
        _ = try await store.applyWorkDeskMutation(.createProject(project, materialIDs: []))
        _ = try await store.applyWorkDeskMutation(.createProject(other, materialIDs: []))
        let conversation = try await store.createConversation(backend: "hermes", projectID: project.id)
        let reply = try await store.appendMessage(role: "agent", text: "Done", conversationID: conversation.id,
            sourceDevice: "test", attachments: [file()])
        await store.reconcileProjectResults()
        let id = try await storedAttachmentID(for: reply, conversationID: conversation.id, store: store)
        _ = try await store.applyWorkDeskMutation(.assign(materialIDs: [id], projectID: other.id))
        await store.reconcileProjectResults()
        let placement = try await store.fetchWorkDeskOrganization()
        XCTAssertEqual(placement.placements[id]?.projectID, other.id)
        try await store.deleteWorkMaterial(id: id)
        await store.reconcileProjectResults()
        let deleted = try await store.fetchWorkMaterial(id: id)
        XCTAssertNil(deleted)
        let receipts = try await store.fetchWorkDeskResults()
        XCTAssertNotNil(receipts[id])
    }

    func testProjectDeletionPreservesChatAndExistingResultsAndDoesNotFileLateOutputs() async throws {
        let store = isolated.make()
        let project = WorkDeskProjectRecord(title: "Ungroup")
        _ = try await store.applyWorkDeskMutation(.createProject(project, materialIDs: []))
        let conversation = try await store.createConversation(backend: "hermes", projectID: project.id)
        _ = try await store.appendMessage(role: "agent", text: "First", conversationID: conversation.id,
            sourceDevice: "test", attachments: [file()])
        await store.reconcileProjectResults()
        _ = try await store.applyWorkDeskMutation(.deleteProject(id: project.id))
        _ = try await store.appendMessage(role: "agent", text: "Later", conversationID: conversation.id,
            sourceDevice: "test", attachments: [file("late.txt")])
        await store.reconcileProjectResults()
        let retained = try await store.fetchConversation(id: conversation.id)
        XCTAssertEqual(retained?.backend, "hermes")
        let desk = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        XCTAssertEqual(desk?.materials.count, 1)
        let organization = try await store.fetchWorkDeskOrganization()
        XCTAssertTrue(organization.placements.values.allSatisfy { $0.projectID == nil })
    }

    func testCloneKeepsProjectButOnlyNewRepliesBecomeNewResults() async throws {
        let store = isolated.make()
        let project = WorkDeskProjectRecord(title: "Compare gateways")
        _ = try await store.applyWorkDeskMutation(.createProject(project, materialIDs: []))
        let original = try await store.createConversation(backend: "hermes", projectID: project.id)
        _ = try await store.appendMessage(role: "agent", text: "Original result", conversationID: original.id,
            sourceDevice: "test", attachments: [file("original.txt")])
        await store.reconcileProjectResults()
        let cloned = try await store.cloneConversation(id: original.id, toBackend: "openclaw")
        XCTAssertEqual(cloned.conversation.projectID, project.id)
        await store.reconcileProjectResults()
        let afterClone = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        XCTAssertEqual(afterClone?.materials.count, 1, "Copied history is not output by the second gateway")
        let reply = try await store.appendMessage(role: "agent", text: "New result", conversationID: cloned.conversation.id,
            sourceDevice: "test", attachments: [file("new.txt")])
        await store.reconcileProjectResults()
        let afterReply = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        XCTAssertEqual(afterReply?.materials.count, 2)
        let receipts = try await store.fetchWorkDeskResults()
        let attachmentID = try await storedAttachmentID(for: reply, conversationID: cloned.conversation.id, store: store)
        let source = receipts[attachmentID]
        XCTAssertEqual(source?.gatewayRef, "openclaw")
        XCTAssertEqual(source?.conversationID, cloned.conversation.id)
    }

    func testProjectAssociationAndDeletionReceiptSurviveStoreReopen() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("project-result-reopen-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("store.sqlite")
        let first = isolated.make(storeURL: url)
        let project = WorkDeskProjectRecord(title: "Durable")
        _ = try await first.applyWorkDeskMutation(.createProject(project, materialIDs: []))
        let conversation = try await first.createConversation(backend: "hermes", projectID: project.id)
        let reply = try await first.appendMessage(role: "agent", text: "Returned", conversationID: conversation.id,
            sourceDevice: "test", attachments: [file()])
        await first.reconcileProjectResults()
        let id = try await storedAttachmentID(for: reply, conversationID: conversation.id, store: first)
        try await first.deleteWorkMaterial(id: id)
        try await first._unloadForTesting()

        let reopened = isolated.make(storeURL: url)
        await reopened.reconcileProjectResults()
        let storedConversation = try await reopened.fetchConversation(id: conversation.id)
        XCTAssertEqual(storedConversation?.projectID, project.id)
        let deleted = try await reopened.fetchWorkMaterial(id: id)
        XCTAssertNil(deleted)
        let receipts = try await reopened.fetchWorkDeskResults()
        XCTAssertEqual(receipts[id]?.conversationID, conversation.id)
        try await reopened._unloadForTesting()
    }

    func testExistingResultRepairsMissingPayloadWithoutOverwritingPlacement() async throws {
        let store = isolated.make()
        let project = WorkDeskProjectRecord(title: "Result repair")
        _ = try await store.applyWorkDeskMutation(.createProject(project, materialIDs: []))
        let conversation = try await store.createConversation(backend: "hermes", projectID: project.id)
        let reply = try await store.appendMessage(role: "agent", text: "File", conversationID: conversation.id,
            sourceDevice: "test", attachments: [file()])
        await store.reconcileProjectResults()
        let id = try await storedAttachmentID(for: reply, conversationID: conversation.id, store: store)
        _ = try await store.applyWorkDeskMutation(.assign(materialIDs: [id], projectID: nil))
        _ = await store._deleteWorkMaterialBlobRowsForTesting(materialID: id)
        let missing = try await store.loadWorkMaterialPayload(id: id)
        XCTAssertNil(missing)
        await store.reconcileProjectResults()
        let restored = try await store.loadWorkMaterialPayload(id: id)
        XCTAssertEqual(restored, Data("file contents".utf8))
        let organization = try await store.fetchWorkDeskOrganization()
        XCTAssertNil(organization.placements[id]?.projectID)
        let receipts = try await store.fetchWorkDeskResults()
        XCTAssertEqual(receipts.count, 1)
    }

    func testLateConfirmedOutputsAppearOnceEvenWithDuplicateRemoteRows() async throws {
        let store = isolated.make()
        let project = WorkDeskProjectRecord(title: "Late discovery")
        _ = try await store.applyWorkDeskMutation(.createProject(project, materialIDs: []))
        let conversation = try await store.createConversation(backend: "hermes", projectID: project.id)
        let reply = try await store.appendMessage(role: "agent", text: "Writing files", conversationID: conversation.id,
            sourceDevice: "test", outputScanLaneID: "original-lane")
        await store.reconcileProjectResults()
        var attachment = file("late.pdf", mime: "application/pdf")
        attachment.isServerReference = true
        attachment.storedKey = "outbox/late.pdf"
        try await store.addAttachments(messageID: reply.id, attachments: [attachment, attachment])
        await store.reconcileProjectResults()
        let desk = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        XCTAssertEqual(desk?.materials.count, 1)
        let receipts = try await store.fetchWorkDeskResults()
        XCTAssertEqual(receipts.count, 1)
        try await store.deleteWorkMaterial(id: try XCTUnwrap(desk?.materials.first?.id))
        try await store.addAttachments(messageID: reply.id, attachments: [attachment])
        await store.reconcileProjectResults()
        let afterAnotherDuplicate = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        XCTAssertTrue(afterAnotherDuplicate?.materials.isEmpty ?? true)
    }

    func testRemoteFilesStayReferencesBoundToOriginalLane() async throws {
        let store = isolated.make()
        let project = WorkDeskProjectRecord(title: "Remote")
        _ = try await store.applyWorkDeskMutation(.createProject(project, materialIDs: []))
        let conversation = try await store.createConversation(backend: "hermes", projectID: project.id)
        var attachment = file("report.pdf", mime: "application/pdf")
        attachment.isServerReference = true
        attachment.storedKey = "outbox/report.pdf"
        let reply = try await store.appendMessage(role: "agent", text: "Returned", conversationID: conversation.id,
            sourceDevice: "test", outputScanLaneID: "original-lane", attachments: [attachment])
        await store.reconcileProjectResults()
        let desk = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        let result = try XCTUnwrap(desk?.materials.first)
        XCTAssertEqual(result.kind, .note)
        XCTAssertTrue(result.isProjectResult)
        XCTAssertTrue(result.isRemoteProjectResult)
        XCTAssertEqual(result.storageMode, .metadataOnly)
        let payload = try await store.loadWorkMaterialPayload(id: result.id)
        XCTAssertNil(payload)
        let sources = try await store.fetchWorkDeskResults()
        let attachmentID = try await storedAttachmentID(for: reply, conversationID: conversation.id, store: store)
        XCTAssertEqual(sources[result.id]?.attachmentID, attachmentID)
        XCTAssertEqual(sources[result.id]?.fileLaneID, "original-lane")
        XCTAssertEqual(sources[result.id]?.isRemoteReference, true)
        await store.reconcileProjectResults()
        let replay = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        XCTAssertEqual(replay?.materials.count, 1)
    }
}
