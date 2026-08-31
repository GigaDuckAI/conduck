// SPDX-License-Identifier: Apache-2.0

// ConduckTests
// WorkboardUploadJournalTests.swift
//
// `reconcile` is the only Workboard code that issues an irreversible DELETE
// against the user's own file server, so every refusal in front of it is pinned
// here: a key the durable conversation already owns, a lane the user repointed
// away from, a dispatch this process is still running, and a surviving upload
// task. The reclaim seam is injected, so none of it touches the network.

import XCTest
@testable import Conduck

/// Records what reconciliation asked to reclaim and answers the live-task
/// probe. NO network.
private final class MockUploadReclaimer: WorkboardUploadReclaiming, @unchecked Sendable {
    private let lock = NSLock()
    /// Sequences the live-task probe reports as still in flight.
    private let liveSequences: Set<Int>
    /// Keys whose DELETE the server refuses to confirm.
    private let failingKeys: Set<String>

    private(set) var deletedKeys: [String] = []

    init(liveSequences: Set<Int> = [], failingKeys: Set<String> = []) {
        self.liveSequences = liveSequences
        self.failingKeys = failingKeys
    }

    func hasLiveUploadTask(shareEnvelopeID: UUID, sequence: Int) async -> Bool {
        liveSequences.contains(sequence)
    }

    func deleteFileForRecovery(
        snapshot: SettingsManager.FileTransferSnapshot,
        storedKey: String
    ) async -> Bool {
        lock.lock()
        deletedKeys.append(storedKey)
        lock.unlock()
        return !failingKeys.contains(storedKey)
    }
}

final class WorkboardUploadJournalTests: XCTestCase {
    private var root: URL!
    private let gatewayRef = RemoteAgentRef.builtin(.hermes)
    private let fileServerURL = URL(string: "https://files.example.test")!

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "conduck-work-upload-journal-tests-\(UUID().uuidString)",
            isDirectory: true
        )
    }

    override func tearDown() {
        if let root { try? FileManager.default.removeItem(at: root) }
        root = nil
        super.tearDown()
    }

    func testRegisterIsDurableIdempotentAndAcknowledgedPerKey() async throws {
        let journal = WorkboardUploadJournal(baseURL: root)
        let dispatchID = UUID()
        let conversationID = UUID()
        let first = FileServerClient.makeStoredKey(
            originalName: "brief.pdf",
            uuid: UUID(),
            folder: conversationID.uuidString
        )
        let second = FileServerClient.makeStoredKey(
            originalName: "notes.txt",
            uuid: UUID()
        )

        try await journal.register(
            dispatchID: dispatchID,
            conversationID: conversationID,
            gatewayRef: "hermes",
            durableLaneID: "lane-one",
            storedKey: first,
            sequence: 0
        )
        try await journal.register(
            dispatchID: dispatchID,
            conversationID: conversationID,
            gatewayRef: "hermes",
            durableLaneID: "lane-one",
            storedKey: first,
            sequence: 0
        )
        try await journal.register(
            dispatchID: dispatchID,
            conversationID: conversationID,
            gatewayRef: "hermes",
            durableLaneID: "lane-one",
            storedKey: second,
            sequence: 1
        )

        var entries = await journal.pendingEntries()
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.uploads.map(\.storedKey), [first, second])

        await journal.acknowledgeReclaimed(dispatchID: dispatchID, storedKey: first)
        entries = await journal.pendingEntries()
        XCTAssertEqual(entries.first?.uploads.map(\.storedKey), [second])

        await journal.finish(dispatchID: dispatchID)
        let afterFinish = await journal.pendingEntries()
        XCTAssertTrue(afterFinish.isEmpty)
    }

    func testJournalRejectsKeysOutsideTheDispatchNamespaceAndIdentityCollisions() async throws {
        let journal = WorkboardUploadJournal(baseURL: root)
        let dispatchID = UUID()
        let conversationID = UUID()
        let safe = FileServerClient.makeStoredKey(
            originalName: "safe.txt",
            uuid: UUID(),
            folder: conversationID.uuidString
        )

        XCTAssertTrue(WorkboardUploadJournal.isOwnedStoredKey(safe, conversationID: conversationID))
        XCTAssertFalse(WorkboardUploadJournal.isOwnedStoredKey("../erase", conversationID: conversationID))
        XCTAssertFalse(WorkboardUploadJournal.isOwnedStoredKey(
            "\(UUID().uuidString)/deadbeef__safe.txt",
            conversationID: conversationID
        ))

        do {
            try await journal.register(
                dispatchID: dispatchID,
                conversationID: conversationID,
                gatewayRef: "hermes",
                durableLaneID: "lane-one",
                storedKey: "../erase",
                sequence: 0
            )
            XCTFail("A journal entry may never authorize an arbitrary DELETE path")
        } catch WorkboardUploadJournal.JournalError.invalidEntry {
            // Expected.
        }

        try await journal.register(
            dispatchID: dispatchID,
            conversationID: conversationID,
            gatewayRef: "hermes",
            durableLaneID: "lane-one",
            storedKey: safe,
            sequence: 0
        )
        do {
            try await journal.register(
                dispatchID: dispatchID,
                conversationID: conversationID,
                gatewayRef: "openclaw",
                durableLaneID: "lane-two",
                storedKey: safe,
                sequence: 0
            )
            XCTFail("A dispatch id cannot be repointed to another lane")
        } catch WorkboardUploadJournal.JournalError.identityCollision {
            // Expected.
        }
    }

    // MARK: - Launch-time reconciliation

    func testAKeyTheConversationOwnsIsAcknowledgedAndNeverDeleted() async throws {
        let store = ConversationStore(inMemory: true)
        let conversation = try await store.createConversation(backend: "hermes")
        let bound = storedKey(named: "brief.pdf", conversationID: conversation.id)
        let orphan = storedKey(named: "notes.txt", conversationID: conversation.id)
        _ = try await store.appendMessage(
            role: "user",
            text: "the turn that bound the upload",
            conversationID: conversation.id,
            sourceDevice: "phone",
            attachments: [serverReference(storedKey: bound)]
        )

        let reclaimer = MockUploadReclaimer()
        let journal = WorkboardUploadJournal(baseURL: root, reclaimer: reclaimer)
        let dispatchID = UUID()
        try await register(
            in: journal,
            dispatchID: dispatchID,
            conversationID: conversation.id,
            durableLaneID: "lane-one",
            keys: [bound, orphan]
        )

        // No file lane is configured, so the exact-lane gate stops the pass
        // before any transport could be reached.
        await journal.reconcile(store: store, settings: SettingsManager(dependencies: .inMemory()))

        let entries = await journal.pendingEntries()
        XCTAssertEqual(entries.first?.uploads.map(\.storedKey), [orphan],
                       "a key the durable conversation owns is reclaimed by acknowledgement, never by DELETE")
        XCTAssertTrue(reclaimer.deletedKeys.isEmpty,
                      "an unavailable lane must never authorize a DELETE")
    }

    func testAnEntryWhoseLaneMovedIsLeftFullyIntact() async throws {
        let store = ConversationStore(inMemory: true)
        let conversationID = UUID()
        let first = storedKey(named: "one.pdf", conversationID: conversationID)
        let second = storedKey(named: "two.pdf", conversationID: conversationID)

        let settings = await makeConfiguredSettings()
        let snapshot = await settings.fileTransferSnapshot(for: gatewayRef)
        let lane = try XCTUnwrap(snapshot).durableLaneID
        let reclaimer = MockUploadReclaimer()
        let journal = WorkboardUploadJournal(baseURL: root, reclaimer: reclaimer)
        try await register(
            in: journal,
            dispatchID: UUID(),
            conversationID: conversationID,
            durableLaneID: "lane-the-user-left",
            keys: [first, second]
        )
        XCTAssertNotEqual(lane, "lane-the-user-left")

        await journal.reconcile(store: store, settings: settings)

        let entries = await journal.pendingEntries()
        XCTAssertEqual(entries.first?.uploads.map(\.storedKey), [first, second],
                       "a repointed gateway keeps its metadata record until the exact lane returns")
        XCTAssertTrue(reclaimer.deletedKeys.isEmpty,
                      "reclaiming on a different server would erase somebody else's files")
    }

    func testADispatchStillRunningInThisProcessIsSkipped() async throws {
        let store = ConversationStore(inMemory: true)
        let conversationID = UUID()
        let key = storedKey(named: "in-flight.pdf", conversationID: conversationID)

        let settings = await makeConfiguredSettings()
        let snapshot = await settings.fileTransferSnapshot(for: gatewayRef)
        let lane = try XCTUnwrap(snapshot).durableLaneID
        let reclaimer = MockUploadReclaimer()
        let journal = WorkboardUploadJournal(baseURL: root, reclaimer: reclaimer)
        let dispatchID = UUID()
        try await register(
            in: journal,
            dispatchID: dispatchID,
            conversationID: conversationID,
            durableLaneID: lane,
            keys: [key]
        )

        // Everything else about this entry is reclaimable — only the live
        // dispatch stands between the key and a DELETE.
        await journal.beginActivity(dispatchID: dispatchID)
        await journal.reconcile(store: store, settings: settings)

        var entries = await journal.pendingEntries()
        XCTAssertEqual(entries.first?.uploads.map(\.storedKey), [key],
                       "a launch reconcile overlapping Send must not reclaim the bytes being sent")
        XCTAssertTrue(reclaimer.deletedKeys.isEmpty)

        await journal.endActivity(dispatchID: dispatchID)
        await journal.reconcile(store: store, settings: settings)

        entries = await journal.pendingEntries()
        XCTAssertEqual(reclaimer.deletedKeys, [key],
                       "once the dispatch ends the same unbound key is reclaimable")
        XCTAssertTrue(entries.isEmpty)
    }

    func testOnlyAnUnboundKeyWithAConfirmedDeleteIsAcknowledged() async throws {
        let store = ConversationStore(inMemory: true)
        let conversationID = UUID()
        let reclaimed = storedKey(named: "reclaimed.pdf", conversationID: conversationID)
        let stillUploading = storedKey(named: "in-flight.pdf", conversationID: conversationID)
        let refused = storedKey(named: "refused.pdf", conversationID: conversationID)

        let settings = await makeConfiguredSettings()
        let snapshot = await settings.fileTransferSnapshot(for: gatewayRef)
        let lane = try XCTUnwrap(snapshot).durableLaneID
        let reclaimer = MockUploadReclaimer(liveSequences: [1], failingKeys: [refused])
        let journal = WorkboardUploadJournal(baseURL: root, reclaimer: reclaimer)
        try await register(
            in: journal,
            dispatchID: UUID(),
            conversationID: conversationID,
            durableLaneID: lane,
            keys: [reclaimed, stillUploading, refused]
        )

        await journal.reconcile(store: store, settings: settings)

        let entries = await journal.pendingEntries()
        XCTAssertEqual(reclaimer.deletedKeys, [reclaimed, refused],
                       "a surviving background PUT still owns its key, so it is never deleted")
        XCTAssertEqual(entries.first?.uploads.map(\.storedKey), [stillUploading, refused],
                       "only a server-confirmed cleanup may drop a key from the journal")
    }

    // MARK: - Helpers

    private func storedKey(named name: String, conversationID: UUID) -> String {
        FileServerClient.makeStoredKey(
            originalName: name,
            uuid: UUID(),
            folder: conversationID.uuidString
        )
    }

    private func register(
        in journal: WorkboardUploadJournal,
        dispatchID: UUID,
        conversationID: UUID,
        durableLaneID: String,
        keys: [String]
    ) async throws {
        for (sequence, key) in keys.enumerated() {
            try await journal.register(
                dispatchID: dispatchID,
                conversationID: conversationID,
                gatewayRef: gatewayRef.rawString,
                durableLaneID: durableLaneID,
                storedKey: key,
                sequence: sequence
            )
        }
    }

    /// A URL + credential pair is exactly what makes a lane resolvable, and the
    /// credential half is what the durable lane identity is derived from.
    private func makeConfiguredSettings() async -> SettingsManager {
        let settings = SettingsManager(dependencies: .inMemory())
        try? await settings.setFileServerCredential(String(repeating: "a", count: 32), for: gatewayRef)
        await settings.setFileServerURL(fileServerURL, for: gatewayRef)
        return settings
    }

    private func serverReference(storedKey: String) -> AttachmentDraft {
        var draft = AttachmentDraft(
            mimeType: "application/pdf",
            filename: "brief.pdf",
            data: Data(),
            thumbnailData: nil,
            width: 0,
            height: 0,
            byteSize: 0,
            sequence: 0
        )
        draft.isServerReference = true
        draft.storedKey = storedKey
        return draft
    }
}
