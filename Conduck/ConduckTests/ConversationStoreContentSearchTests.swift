// Conduck
// ConversationStoreContentSearchTests.swift
//
// Integration coverage for `ConversationStore.searchConversationIDs(containing:)`
// — the Tier-2 whole-history content search backing every surface's
// conversation list. Exercises the risky bit: the
// `ANY messages.text CONTAINS[cd] %@` predicate against a real (in-memory)
// Core Data store, including mid-thread + agent-turn matches and the
// case/diacritic-insensitive folding.
//
// Each test builds its OWN isolated `inMemory` store (mirrors
// `ConversationStoreTests` / `ConversationStoreDedupeTests`) — no `.shared`
// singleton, no App Group sqlite, no Keychain (unsigned-safe).

import XCTest
import CoreData
@testable import Conduck

final class ConversationStoreContentSearchTests: XCTestCase {

    private func makeStore() -> ConversationStore {
        ConversationStore(inMemory: true)
    }

    /// Seed a conversation with an ordered list of (role, text) turns.
    @discardableResult
    private func seedConversation(
        in store: ConversationStore,
        backend: String = "openclaw",
        turns: [(role: String, text: String)]
    ) async throws -> UUID {
        let convo = try await store.createConversation(backend: backend)
        for turn in turns {
            _ = try await store.appendMessage(
                role: turn.role,
                text: turn.text,
                conversationID: convo.id,
                sourceDevice: "phone"
            )
        }
        return convo.id
    }

    // MARK: - Basic matching across two conversations

    func testReturnsOnlyMatchingConversationIDs() async throws {
        let store = makeStore()
        let rome = try await seedConversation(in: store, turns: [
            (role: "user", text: "Plan a trip to Rome"),
            (role: "agent", text: "Rome is wonderful in spring."),
        ])
        let berlin = try await seedConversation(in: store, turns: [
            (role: "user", text: "Find a flight to Berlin"),
            (role: "agent", text: "Several airlines fly there daily."),
        ])

        let matches = try await store.searchConversationIDs(containing: "rome")
        XCTAssertEqual(matches, [rome],
                       "Only the conversation whose message text contains the query should match.")
        XCTAssertFalse(matches.contains(berlin))
    }

    // MARK: - Mid-thread turn (not first / not last)

    func testMatchesMidThreadTurn() async throws {
        let store = makeStore()
        let convo = try await seedConversation(in: store, turns: [
            (role: "user", text: "Hello there"),
            (role: "agent", text: "Hi! How can I help?"),
            (role: "user", text: "I need a pelican costume pattern"),   // mid-thread
            (role: "agent", text: "Sure, here are some options."),
        ])

        let matches = try await store.searchConversationIDs(containing: "pelican")
        XCTAssertEqual(matches, [convo],
                       "A query that appears only in a MID-thread turn must still surface the conversation.")
    }

    // MARK: - Agent-turn content is findable

    func testMatchesAgentTurnText() async throws {
        let store = makeStore()
        let convo = try await seedConversation(in: store, turns: [
            (role: "user", text: "What's the capital?"),
            (role: "agent", text: "The capital of Estonia is Tallinn."),   // only the AGENT says it
        ])

        let matches = try await store.searchConversationIDs(containing: "tallinn")
        XCTAssertEqual(matches, [convo],
                       "Content search must match AGENT-turn text, not just user turns.")
    }

    // MARK: - Case + diacritic insensitivity ([cd])

    func testCaseInsensitiveMatch() async throws {
        let store = makeStore()
        let convo = try await seedConversation(in: store, turns: [
            (role: "user", text: "Book the HOTEL near the station"),
        ])

        let matches = try await store.searchConversationIDs(containing: "hotel")
        XCTAssertEqual(matches, [convo])
    }

    func testDiacriticInsensitiveMatch() async throws {
        let store = makeStore()
        let convo = try await seedConversation(in: store, turns: [
            (role: "user", text: "Meet at the café on Müller street"),
        ])

        // `[cd]` folds diacritics — an ASCII query matches the accented text.
        let cafeMatches = try await store.searchConversationIDs(containing: "cafe")
        XCTAssertEqual(cafeMatches, [convo], "[cd] predicate must fold café → cafe.")

        let muellerMatches = try await store.searchConversationIDs(containing: "muller")
        XCTAssertEqual(muellerMatches, [convo], "[cd] predicate must fold Müller → Muller.")
    }

    // MARK: - Whitespace / empty query short-circuits

    func testWhitespaceQueryReturnsEmptySet() async throws {
        let store = makeStore()
        _ = try await seedConversation(in: store, turns: [
            (role: "user", text: "anything at all"),
        ])

        let blank = try await store.searchConversationIDs(containing: "   ")
        XCTAssertEqual(blank, [], "A whitespace-only query must return an empty set without fetching.")

        let empty = try await store.searchConversationIDs(containing: "")
        XCTAssertEqual(empty, [], "An empty query must return an empty set.")
    }

    // MARK: - No match → empty set (not an error)

    func testNoMatchReturnsEmptySet() async throws {
        let store = makeStore()
        _ = try await seedConversation(in: store, turns: [
            (role: "user", text: "Plan a trip to Rome"),
        ])

        let matches = try await store.searchConversationIDs(containing: "submarine")
        XCTAssertEqual(matches, [], "A query that matches nothing returns an empty set, not an error.")
    }
}
