// SPDX-License-Identifier: Apache-2.0

// Conduck
// ConversationStoreDistinctBackendsTests.swift
//
// Coverage for `ConversationStore.distinctBackends()` — the one-attribute
// DISTINCT fetch CarPlay uses to decide whether its Recent rows carry gateway
// badges. CarPlay's own picker list is capped, so it cannot derive that from
// what it displays; this query answers over the whole store.
//
// The property under test is that DISTINCT actually deduplicates
// (`returnsDistinctResults` is silently ignored unless the fetch is
// `.dictionaryResultType` — the trap this pins) and that unusable values never
// reach the caller as identities.
//
// Each test builds its OWN isolated `inMemory` store (mirrors
// `ConversationStoreWriteReadBackTests`) — no `.shared` singleton, no App Group
// sqlite.

import XCTest
@testable import Conduck

final class ConversationStoreDistinctBackendsTests: XCTestCase {

    private func makeStore() -> ConversationStore {
        ConversationStore(inMemory: true)
    }

    func testEmptyStoreHasNoBackends() async throws {
        let store = makeStore()
        let backends = try await store.distinctBackends()
        XCTAssertTrue(backends.isEmpty)
    }

    func testRepeatedBackendCollapsesToOne() async throws {
        let store = makeStore()
        for _ in 0..<5 {
            _ = try await store.createConversation(backend: "openclaw")
        }

        let backends = try await store.distinctBackends()

        XCTAssertEqual(backends, ["openclaw"],
                       "Five conversations on one gateway are still ONE identity — a non-distinct fetch would return five rows.")
    }

    func testDistinctBackendsSpanEveryGatewayInTheStore() async throws {
        let store = makeStore()
        let customRef = RemoteAgentRef.custom(UUID()).rawString
        _ = try await store.createConversation(backend: "openclaw")
        _ = try await store.createConversation(backend: "openclaw")
        _ = try await store.createConversation(backend: "hermes")
        _ = try await store.createConversation(backend: "openrouter")
        _ = try await store.createConversation(backend: customRef)

        let backends = try await store.distinctBackends()

        XCTAssertEqual(backends, ["openclaw", "hermes", "openrouter", customRef],
                       "Built-ins and customs alike come back verbatim, one entry each.")
    }

    func testEmptyBackendValueIsNotAnIdentity() async throws {
        let store = makeStore()
        _ = try await store.createConversation(backend: "openclaw")
        _ = try await store.createConversation(backend: "")

        let backends = try await store.distinctBackends()

        XCTAssertEqual(backends, ["openclaw"],
                       "An empty `backend` (a partially-synced CloudKit row) is not a gateway the list can badge.")
    }

    func testDeletingAConversationDropsItsBackend() async throws {
        let store = makeStore()
        _ = try await store.createConversation(backend: "openclaw")
        let doomed = try await store.createConversation(backend: "hermes")

        try await store.deleteConversation(id: doomed.id)
        let backends = try await store.distinctBackends()

        XCTAssertEqual(backends, ["openclaw"],
                       "The query reads committed store state — the last chat on a gateway takes its identity with it.")
    }
}
