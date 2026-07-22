// Conduck
// ConversationStoreDedupeTests.swift
//
// Share Extension — coverage for `ConversationStore.appendMessage(id:)`
// dedupe-on-id. The Share-Extension drainer passes the share envelope's UUID as
// the message id so a re-drain after a crash (or a duplicate drain trigger) is
// idempotent: the same id twice yields ONE message, and the second call returns
// the EXISTING record WITHOUT a duplicate insert or a `lastActivityAt` re-bump.
//
// Each test builds its OWN isolated `inMemory` store (mirrors
// `ConversationStoreTests`) — no `.shared` singleton, no App Group sqlite.

import XCTest
import CoreData
@testable import Conduck

final class ConversationStoreDedupeTests: XCTestCase {

    private func makeStore() -> ConversationStore {
        ConversationStore(inMemory: true)
    }

    // MARK: - Text-only fast path

    func testProvidedIDIsUsedAsMessageID() async throws {
        let store = makeStore()
        let convo = try await store.createConversation(backend: "openclaw")
        let envelopeID = UUID()

        let msg = try await store.appendMessage(
            id: envelopeID,
            role: "user",
            text: "shared text",
            conversationID: convo.id,
            sourceDevice: "phone"
        )

        XCTAssertEqual(msg.id, envelopeID,
                       "A provided id must become the new Message.id (not a fresh UUID()).")
    }

    func testSameIDTwiceYieldsOneMessageAndReturnsExisting() async throws {
        let store = makeStore()
        let convo = try await store.createConversation(backend: "openclaw")
        let envelopeID = UUID()

        let first = try await store.appendMessage(
            id: envelopeID,
            role: "user",
            text: "first append",
            conversationID: convo.id,
            sourceDevice: "phone"
        )

        // Re-append the SAME id (simulating a re-drain) with DIFFERENT text — the
        // second call must be a no-op returning the EXISTING record (original
        // text), never a second insert.
        let second = try await store.appendMessage(
            id: envelopeID,
            role: "user",
            text: "re-drain text (must be ignored)",
            conversationID: convo.id,
            sourceDevice: "phone"
        )

        XCTAssertEqual(second.id, first.id)
        XCTAssertEqual(second.text, "first append",
                       "Re-append must return the EXISTING message, not the re-drain's text.")

        let messages = try await store.fetchMessages(for: convo.id)
        XCTAssertEqual(messages.count, 1, "Dedupe-on-id must leave exactly one message.")
        XCTAssertEqual(messages.first?.id, envelopeID)
    }

    func testReAppendDoesNotReBumpLastActivityAt() async throws {
        let store = makeStore()
        let convo = try await store.createConversation(backend: "openclaw")
        let envelopeID = UUID()

        _ = try await store.appendMessage(
            id: envelopeID,
            role: "user",
            text: "first",
            conversationID: convo.id,
            sourceDevice: "phone"
        )
        let afterFirst = try await store.fetchConversation(id: convo.id)
        let activityAfterFirst = try XCTUnwrap(afterFirst?.lastActivityAt)

        // Real delay so a (wrong) re-bump would be detectable.
        try await Task.sleep(nanoseconds: 30_000_000) // 30ms

        _ = try await store.appendMessage(
            id: envelopeID,
            role: "user",
            text: "re-drain",
            conversationID: convo.id,
            sourceDevice: "phone"
        )
        let afterSecond = try await store.fetchConversation(id: convo.id)
        let activityAfterSecond = try XCTUnwrap(afterSecond?.lastActivityAt)

        XCTAssertEqual(activityAfterSecond, activityAfterFirst,
                       "A benign re-drain must NOT re-bump lastActivityAt (it would float a stale thread).")
    }

    // MARK: - Attachments background-context path

    func testDedupeAppliesToAttachmentsPath() async throws {
        let store = makeStore()
        let convo = try await store.createConversation(backend: "openclaw")
        let envelopeID = UUID()

        let draft = AttachmentDraft(
            mimeType: "image/jpeg",
            data: Data([0xFF, 0xD8, 0xFF]),
            thumbnailData: Data([0x01]),
            width: 10,
            height: 10,
            byteSize: 3,
            sequence: 0
        )

        let first = try await store.appendMessage(
            id: envelopeID,
            role: "user",
            text: "with image",
            conversationID: convo.id,
            sourceDevice: "phone",
            attachments: [draft]
        )

        let second = try await store.appendMessage(
            id: envelopeID,
            role: "user",
            text: "with image again",
            conversationID: convo.id,
            sourceDevice: "phone",
            attachments: [draft]
        )

        XCTAssertEqual(second.id, first.id)
        let messages = try await store.fetchMessages(for: convo.id)
        XCTAssertEqual(messages.count, 1,
                       "Dedupe must apply on the attachments (background-context) path too.")
    }

    // MARK: - nil id preserves legacy behavior

    func testNilIDMintsFreshUUIDEachCall() async throws {
        let store = makeStore()
        let convo = try await store.createConversation(backend: "openclaw")

        let a = try await store.appendMessage(
            role: "user", text: "one", conversationID: convo.id, sourceDevice: "phone"
        )
        let b = try await store.appendMessage(
            role: "user", text: "two", conversationID: convo.id, sourceDevice: "phone"
        )

        XCTAssertNotEqual(a.id, b.id, "nil id must mint a distinct UUID per call (legacy behavior).")
        let messages = try await store.fetchMessages(for: convo.id)
        XCTAssertEqual(messages.count, 2)
    }
}
