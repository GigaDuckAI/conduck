// SPDX-License-Identifier: Apache-2.0

// Conduck
// ConversationStoreWriteReadBackTests.swift
//
// Read-your-own-write coverage for the background-context WRITE posture:
// every store write commits on a fresh `newBackgroundContext()` inside
// `perform` BEFORE the call returns, and every read materializes committed
// store state on its own fresh context — so a write followed IMMEDIATELY by a
// refetch must observe the write, with no `viewContext` merge timing involved
// (the main-queue `viewContext` is deliberately unconfigured + unused). These
// tests pin that ordering contract: if a write ever becomes fire-and-forget
// (save detached from the awaited `perform`), they fail deterministically.
//
// Each test builds its OWN isolated `inMemory` store (mirrors
// `ConversationStoreTests`) — no `.shared` singleton, no App Group sqlite.

import XCTest
@testable import Conduck

final class ConversationStoreWriteReadBackTests: XCTestCase {

    private func makeStore() -> ConversationStore {
        ConversationStore(inMemory: true)
    }

    func testCreateIsVisibleToImmediateRefetch() async throws {
        let store = makeStore()

        let created = try await store.createConversation(backend: "openclaw")
        let fetched = try await store.fetchConversations()

        XCTAssertEqual(fetched.map(\.id), [created.id],
                       "A createConversation must be committed before it returns — an immediate fetch sees the row.")
        XCTAssertEqual(fetched.first?.backend, "openclaw")
    }

    func testDeleteIsVisibleToImmediateRefetch() async throws {
        let store = makeStore()
        let keep = try await store.createConversation(backend: "openclaw")
        let doomed = try await store.createConversation(backend: "hermes")

        try await store.deleteConversation(id: doomed.id)
        let fetched = try await store.fetchConversations()

        XCTAssertEqual(fetched.map(\.id), [keep.id],
                       "deleteConversation must be committed before it returns — an immediate fetch no longer sees the row.")
    }

    func testDeleteAllLeavesStoreEmptyOnImmediateRefetch() async throws {
        let store = makeStore()
        _ = try await store.createConversation(backend: "openclaw")
        _ = try await store.createConversation(backend: "hermes")

        try await store.deleteAll()
        let fetched = try await store.fetchConversations()

        XCTAssertTrue(fetched.isEmpty,
                      "deleteAll must be committed before it returns — an immediate fetch sees an empty store.")
    }

    func testStatusFlipIsVisibleToImmediateRefetch() async throws {
        let store = makeStore()
        let convo = try await store.createConversation(backend: "openclaw")
        let msg = try await store.appendMessage(
            role: "user",
            text: "in flight",
            conversationID: convo.id,
            sourceDevice: "phone",
            status: "sending"
        )

        await store.markPendingUserTurn(messageID: msg.id, to: "failed")
        let messages = try await store.fetchMessages(for: convo.id)

        XCTAssertEqual(messages.first(where: { $0.id == msg.id })?.status, "failed",
                       "markPendingUserTurn must be committed before it returns — an immediate fetch sees the flip.")
    }
}
