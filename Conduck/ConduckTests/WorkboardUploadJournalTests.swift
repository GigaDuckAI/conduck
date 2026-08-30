// SPDX-License-Identifier: Apache-2.0

// ConduckTests
// WorkboardUploadJournalTests.swift

import XCTest
@testable import Conduck

final class WorkboardUploadJournalTests: XCTestCase {
    private var root: URL!

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
}
