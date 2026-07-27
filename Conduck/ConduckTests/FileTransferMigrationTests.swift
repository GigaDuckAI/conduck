// SPDX-License-Identifier: Apache-2.0

//
//  FileTransferMigrationTests.swift
//  ConduckTests
//
//  Coverage for the Core Data v3 model + its additive Attachment attributes.
//  The model gains two new OPTIONAL attributes on
//  `Attachment`:  `isServerReference` (Bool, default NO) and `storedKey` (String?).
//  Because they are additive-optional, lightweight migration applies and existing
//  rows keep working.
//
//  This suite uses the in-memory store seam — `ConversationStore(inMemory: true)`
//  — so it runs unsigned with no on-disk store and no signing requirement. Each
//  test WRITES a draft then RE-FETCHES from the store, exercising the full
//  write → Core Data (v3 model) → `AttachmentRecord(managedObject:)` KVC read
//  cycle so the new attributes are proven to persist + decode (not just echoed
//  from the draft).
//
//  `ConversationStore` is an actor, so every CRUD call is async/throws.
//
//  Privacy: synthetic content only; nothing is logged.
//

import XCTest
@testable import Conduck

final class FileTransferMigrationTests: XCTestCase {

    private var store: ConversationStore!

    override func setUp() {
        super.setUp()
        // In-memory store backed by the CURRENT (v3) managed object model.
        store = ConversationStore(inMemory: true)
    }

    override func tearDown() {
        store = nil
        super.tearDown()
    }

    func testInMemoryStoreOpensWithV3Model() async throws {
        // If the v3 model failed to load, createConversation would throw; a
        // successful create + empty fetch proves the store + model loaded.
        let convo = try await store.createConversation(backend: "openclaw")
        let messages = try await store.fetchMessages(for: convo.id)
        XCTAssertTrue(messages.isEmpty, "a freshly created v3 conversation has no messages")
    }

    func testFreshAttachmentDefaultsToNonServerReferenceWithNilStoredKey() async throws {
        let convo = try await store.createConversation(backend: "openclaw")

        // A non-server (text-file) draft does NOT set the new fields, so they
        // must take their v3 defaults: isServerReference == false, storedKey == nil.
        let draft = AttachmentDraft(
            mimeType: "text/plain",
            filename: "notes.txt",
            data: Data("hello".utf8),
            thumbnailData: nil,
            width: 0,
            height: 0,
            byteSize: 5,
            sequence: 0
        )
        _ = try await store.appendMessage(
            role: "user",
            text: "see attached",
            conversationID: convo.id,
            sourceDevice: "phone",
            attachments: [draft]
        )

        // Re-fetch so the assertions run against a Core Data round-trip
        // (AttachmentRecord(managedObject:) reads the v3 attributes via KVC).
        let messages = try await store.fetchMessages(for: convo.id)
        let attachments = messages.first?.attachments ?? []
        XCTAssertEqual(attachments.count, 1, "the attachment must persist")
        guard let att = attachments.first else { return XCTFail("missing attachment") }
        XCTAssertFalse(att.isServerReference, "v3 default for isServerReference is false")
        XCTAssertNil(att.storedKey, "v3 default for storedKey is nil")
        XCTAssertFalse(att.isServerFile, "isServerFile mirrors isServerReference (false)")
        XCTAssertTrue(att.isText, "a text/plain attachment is still classified as text")
    }

    func testServerReferenceAttachmentRoundTripsTheNewFields() async throws {
        let convo = try await store.createConversation(backend: "openclaw")

        // A server-reference draft carries no local bytes (data is empty) and sets
        // the two new fields.
        var draft = AttachmentDraft(
            mimeType: "application/pdf",
            filename: "report.pdf",
            data: Data(),
            thumbnailData: nil,
            width: 0,
            height: 0,
            byteSize: 2048,
            sequence: 0
        )
        draft.isServerReference = true
        draft.storedKey = "a1b2c3d4__report.pdf"

        _ = try await store.appendMessage(
            role: "user",
            text: "use this file",
            conversationID: convo.id,
            sourceDevice: "phone",
            attachments: [draft]
        )

        let messages = try await store.fetchMessages(for: convo.id)
        guard let att = messages.first?.attachments.first else { return XCTFail("missing attachment") }
        XCTAssertTrue(att.isServerReference, "server-ref attachment persists isServerReference == true")
        XCTAssertEqual(att.storedKey, "a1b2c3d4__report.pdf", "storedKey must round-trip through the v3 model")
        XCTAssertTrue(att.isServerFile, "isServerFile mirrors isServerReference (true)")
        XCTAssertEqual(att.filename, "report.pdf", "the original filename is preserved")
        // Server refs are NOT classified as text (they carry no local extractedText).
        XCTAssertFalse(att.isText, "a server reference is not a text attachment")
    }
}
