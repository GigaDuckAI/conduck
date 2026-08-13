// SPDX-License-Identifier: Apache-2.0

// Conduck
// ConversationStoreCreateWithIDTests.swift
//
// Locks `ConversationStore.createConversation(id:backend:)`. The identifier
// parameter exists for one caller shape: something that committed to a
// conversation identifier BEFORE the row existed (the composer mints file-server
// storage keys under `<conversationID>/` while attachments are still staging).
// Pins:
//   • a supplied identifier is the row's identifier, and the row is fetchable by
//     it — otherwise the keys already minted point at a folder no conversation
//     owns;
//   • the default still mints a fresh identifier, and two defaulted calls never
//     collide;
//   • the parameter is additive — the call with `backend:` alone still compiles
//     and behaves identically.
//
// Isolated `inMemory` store per test (CloudKit OFF in the seam).

import XCTest
@testable import Conduck

final class ConversationStoreCreateWithIDTests: XCTestCase {

    private func makeStore() -> ConversationStore {
        ConversationStore(inMemory: true)
    }

    func testSuppliedIdentifierBecomesTheConversationIdentifier() async throws {
        let store = makeStore()
        let id = UUID()

        let created = try await store.createConversation(id: id, backend: "openclaw")

        XCTAssertEqual(created.id, id, "the caller's identifier is adopted verbatim")
        XCTAssertEqual(created.backend, "openclaw")
    }

    func testSuppliedIdentifierIsFetchableAndAcceptsMessages() async throws {
        let store = makeStore()
        let id = UUID()

        _ = try await store.createConversation(id: id, backend: "hermes")

        let fetched = try await store.fetchConversation(id: id)
        XCTAssertEqual(fetched?.id, id, "the row resolves by the identifier the caller already handed out")

        // `appendMessage` throws `conversationNotFound` on a mismatch, so a
        // successful append is the proof the pre-minted identifier is live.
        let message = try await store.appendMessage(
            role: "user",
            text: "staged before the row existed",
            conversationID: id,
            sourceDevice: "mac"
        )
        XCTAssertEqual(message.text, "staged before the row existed")
    }

    func testDefaultMintsAFreshIdentifierEveryCall() async throws {
        let store = makeStore()

        let first = try await store.createConversation(backend: "openclaw")
        let second = try await store.createConversation(backend: "openclaw")

        XCTAssertNotEqual(first.id, second.id, "the default still mints, and never repeats")
    }

    func testDefaultedCallKeepsItsPriorContract() async throws {
        let store = makeStore()

        let created = try await store.createConversation(backend: "openrouter")

        XCTAssertNil(created.title)
        XCTAssertFalse(created.sessionID.isEmpty, "a fresh local session id is still minted")
        XCTAssertEqual(created.backend, "openrouter")
    }
}
