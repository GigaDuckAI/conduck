// SPDX-License-Identifier: Apache-2.0

// Conduck
// ConversationSearchFilterTests.swift
//
// Unit coverage for the pure Tier-1 search helper shared by every
// conversation-list surface (iPhone / iPad / Mac / Watch). Mirrors the
// `ConversationThreadLogicTests` / `CarPlayConversationLabelTests` style:
// no store, no SwiftUI — just the Foundation-only normalize + title/snippet
// match rules. (Tier-2 whole-history content matching is covered by
// `ConversationStoreContentSearchTests`.)

import XCTest
@testable import Conduck

final class ConversationSearchFilterTests: XCTestCase {

    // MARK: - normalizedQuery

    func testNormalizedQuery_emptyStringReturnsNil() {
        XCTAssertNil(ConversationSearchFilter.normalizedQuery(""))
    }

    func testNormalizedQuery_whitespaceOnlyReturnsNil() {
        XCTAssertNil(ConversationSearchFilter.normalizedQuery("   "))
        XCTAssertNil(ConversationSearchFilter.normalizedQuery("\n\t  \n"))
    }

    func testNormalizedQuery_trimsLeadingAndTrailingWhitespace() {
        XCTAssertEqual(ConversationSearchFilter.normalizedQuery("  trip  "), "trip")
        XCTAssertEqual(ConversationSearchFilter.normalizedQuery("\nhello\n"), "hello")
    }

    func testNormalizedQuery_preservesInternalContent() {
        XCTAssertEqual(ConversationSearchFilter.normalizedQuery("  trip to rome  "), "trip to rome")
    }

    // MARK: - titleMatches: title hits

    func testTitleMatches_titleOnlyHit() {
        XCTAssertTrue(ConversationSearchFilter.titleMatches(
            query: "rome", title: "Trip to Rome", titleSnippet: nil
        ))
    }

    func testTitleMatches_titleMissWhenNoSnippet() {
        XCTAssertFalse(ConversationSearchFilter.titleMatches(
            query: "berlin", title: "Trip to Rome", titleSnippet: nil
        ))
    }

    // MARK: - titleMatches: snippet hits (the closed gap)

    func testTitleMatches_snippetOnlyHit() {
        // A server-titled conversation must still be findable by its first-user
        // snippet, and vice-versa — the gap this helper closes.
        XCTAssertTrue(ConversationSearchFilter.titleMatches(
            query: "invoice", title: "Untitled chat", titleSnippet: "draft the invoice email"
        ))
    }

    func testTitleMatches_snippetHitWhenTitleNil() {
        XCTAssertTrue(ConversationSearchFilter.titleMatches(
            query: "invoice", title: nil, titleSnippet: "draft the invoice email"
        ))
    }

    // MARK: - titleMatches: case + diacritic folding

    func testTitleMatches_caseInsensitive() {
        XCTAssertTrue(ConversationSearchFilter.titleMatches(
            query: "ROME", title: "trip to rome", titleSnippet: nil
        ))
        XCTAssertTrue(ConversationSearchFilter.titleMatches(
            query: "rome", title: "TRIP TO ROME", titleSnippet: nil
        ))
    }

    func testTitleMatches_diacriticInsensitive() {
        // Tier-1 uses `[.caseInsensitive, .diacriticInsensitive]` (NOT
        // `localizedCaseInsensitiveContains`, which folds case but NOT
        // diacritics — verified). An ASCII query therefore matches an accented
        // stored value, identical to the Tier-2 `CONTAINS[cd]` predicate.
        XCTAssertTrue(ConversationSearchFilter.titleMatches(
            query: "cafe", title: "Café meeting notes", titleSnippet: nil
        ))
        XCTAssertTrue(ConversationSearchFilter.titleMatches(
            query: "munchen", title: nil, titleSnippet: "trip to München"
        ))
    }

    // MARK: - titleMatches: misses + blank guards

    func testTitleMatches_noHitReturnsFalse() {
        XCTAssertFalse(ConversationSearchFilter.titleMatches(
            query: "berlin", title: "Trip to Rome", titleSnippet: "book the rome hotel"
        ))
    }

    func testTitleMatches_nilTitleAndNilSnippetIsFalse() {
        XCTAssertFalse(ConversationSearchFilter.titleMatches(
            query: "anything", title: nil, titleSnippet: nil
        ))
    }

    func testTitleMatches_blankWhitespaceTitleDoesNotMatch() {
        // A whitespace-only stored title must never match (the trim-guard) —
        // otherwise a blank title would spuriously match any query whose
        // characters happen to be spaces, etc.
        XCTAssertFalse(ConversationSearchFilter.titleMatches(
            query: "rome", title: "   ", titleSnippet: nil
        ))
    }

    func testTitleMatches_blankWhitespaceSnippetDoesNotMatch() {
        XCTAssertFalse(ConversationSearchFilter.titleMatches(
            query: "rome", title: nil, titleSnippet: "   "
        ))
    }
}
