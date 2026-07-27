// SPDX-License-Identifier: Apache-2.0

// Conduck
// CarPlayConversationLabelTests.swift
//
// Pure-function coverage for the CarPlay conversation-picker display
// helpers (`CarPlayConversationLabel`): row-label derivation (title /
// first-user-turn snippet / "New Conversation" floor), the single-line +
// length-capped snippet, the relative-date format, and the
// `maximumItemCount − 1` cap. These are platform-agnostic pure functions, so
// they run in the unsigned logic-test slice (no CarPlay framework, no signing).

import XCTest
@testable import Conduck

final class CarPlayConversationLabelTests: XCTestCase {

    // MARK: - derive

    func testDerive_usesTitleWhenPresent() {
        let label = CarPlayConversationLabel.derive(
            title: "Trip planning",
            firstUserTurnText: "ignore me"
        )
        XCTAssertEqual(label, "Trip planning")
    }

    func testDerive_trimsTitleWhitespace() {
        let label = CarPlayConversationLabel.derive(
            title: "  Trip planning  ",
            firstUserTurnText: nil
        )
        XCTAssertEqual(label, "Trip planning")
    }

    func testDerive_blankTitleFallsBackToSnippet() {
        let label = CarPlayConversationLabel.derive(
            title: "   ",
            firstUserTurnText: "What's the weather in Tallinn"
        )
        XCTAssertEqual(label, "What's the weather in Tallinn")
    }

    func testDerive_nilTitleUsesSnippet() {
        let label = CarPlayConversationLabel.derive(
            title: nil,
            firstUserTurnText: "Remind me to buy milk"
        )
        XCTAssertEqual(label, "Remind me to buy milk")
    }

    func testDerive_noTitleNoTurnFallsBackToNewConversation() {
        let label = CarPlayConversationLabel.derive(title: nil, firstUserTurnText: nil)
        XCTAssertEqual(label, String(localized: "New conversation"))
    }

    func testDerive_emptyTurnFallsBackToNewConversation() {
        let label = CarPlayConversationLabel.derive(title: nil, firstUserTurnText: "   \n  ")
        XCTAssertEqual(label, String(localized: "New conversation"))
    }

    // MARK: - snippet

    func testSnippet_nilForNil() {
        XCTAssertNil(CarPlayConversationLabel.snippet(from: nil))
    }

    func testSnippet_nilForBlank() {
        XCTAssertNil(CarPlayConversationLabel.snippet(from: "   \n\t "))
    }

    func testSnippet_firstLineOnly() {
        let snippet = CarPlayConversationLabel.snippet(from: "First line\nsecond line\nthird")
        XCTAssertEqual(snippet, "First line")
    }

    func testSnippet_collapsesInternalWhitespace() {
        let snippet = CarPlayConversationLabel.snippet(from: "hello     there\tworld")
        XCTAssertEqual(snippet, "hello there world")
    }

    func testSnippet_shortStringPassesThrough() {
        let snippet = CarPlayConversationLabel.snippet(from: "short")
        XCTAssertEqual(snippet, "short")
    }

    func testSnippet_truncatesLongStringWithEllipsis() {
        // 60-char input, cap 40 → truncated + "…".
        let long = String(repeating: "a", count: 60)
        let snippet = CarPlayConversationLabel.snippet(from: long)
        XCTAssertNotNil(snippet)
        XCTAssertTrue(snippet!.hasSuffix("…"))
        // The visible body (minus the ellipsis) is at most maxSnippetLength.
        let body = snippet!.dropLast()
        XCTAssertLessThanOrEqual(body.count, CarPlayConversationLabel.maxSnippetLength)
    }

    func testSnippet_truncationTrimsTrailingPartialWord() {
        // A sentence longer than the cap should not end on a dangling space.
        let input = "Please remind me to call the dentist tomorrow afternoon about the appointment"
        let snippet = CarPlayConversationLabel.snippet(from: input)
        XCTAssertNotNil(snippet)
        let body = String(snippet!.dropLast()) // drop the ellipsis
        XCTAssertFalse(body.hasSuffix(" "), "snippet body should not end on a space")
    }

    // MARK: - relativeDate

    func testRelativeDate_pastIsNonEmpty() {
        let now = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let twoHoursAgo = now.addingTimeInterval(-2 * 3600)
        let formatted = CarPlayConversationLabel.relativeDate(twoHoursAgo, now: now)
        XCTAssertFalse(formatted.isEmpty)
    }

    func testRelativeDate_distinctForDifferentSpans() {
        let now = Date(timeIntervalSinceReferenceDate: 5_000_000)
        let hourAgo = CarPlayConversationLabel.relativeDate(now.addingTimeInterval(-3600), now: now)
        let weekAgo = CarPlayConversationLabel.relativeDate(now.addingTimeInterval(-7 * 86400), now: now)
        XCTAssertNotEqual(hourAgo, weekAgo)
    }

    // MARK: - recentCap

    func testRecentCap_reservesOneRow() {
        XCTAssertEqual(CarPlayConversationLabel.recentCap(maximumItemCount: 12), 11)
        XCTAssertEqual(CarPlayConversationLabel.recentCap(maximumItemCount: 1), 0)
    }

    func testRecentCap_neverNegative() {
        XCTAssertEqual(CarPlayConversationLabel.recentCap(maximumItemCount: 0), 0)
    }
}
