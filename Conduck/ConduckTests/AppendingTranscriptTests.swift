// Conduck
// AppendingTranscriptTests.swift
//
// Pure tests for the `appendingTranscript(_:to:)` free function (Part 1 of the
// voice-populates-the-field plan). The function merges a fresh STT transcript
// into the composer draft: it APPENDS (never replaces), trims the transcript,
// and inserts exactly one separating space — never doubling whitespace. No
// SwiftUI, no actors, no I/O — a deterministic string-shaping contract.

#if !os(watchOS)
import XCTest
@testable import Conduck

final class AppendingTranscriptTests: XCTestCase {

    // MARK: - Empty existing → trimmed transcript verbatim

    func testEmptyExistingReturnsTrimmedTranscript() {
        XCTAssertEqual(appendingTranscript("hello world", to: ""),
                       "hello world",
                       "An empty draft must become the trimmed transcript verbatim.")
    }

    func testEmptyExistingTrimsSurroundingWhitespace() {
        XCTAssertEqual(appendingTranscript("  hello world  ", to: ""),
                       "hello world",
                       "Surrounding whitespace on the transcript must be trimmed before it lands.")
    }

    func testEmptyExistingTrimsSurroundingNewlines() {
        XCTAssertEqual(appendingTranscript("\nhello\n", to: ""),
                       "hello",
                       "Leading/trailing newlines on the transcript must be trimmed.")
    }

    // MARK: - Non-empty existing, no trailing whitespace → single space join

    func testAppendsWithSingleSpaceWhenExistingHasNoTrailingWhitespace() {
        XCTAssertEqual(appendingTranscript("there", to: "hello"),
                       "hello there",
                       "A draft not ending in whitespace must gain exactly one separating space.")
    }

    func testAppendedTranscriptIsTrimmedBeforeJoin() {
        XCTAssertEqual(appendingTranscript("  there  ", to: "hello"),
                       "hello there",
                       "The transcript is trimmed, then joined with a single space — no doubled spaces.")
    }

    // MARK: - Existing already ends in whitespace/newline → no double space

    func testExistingEndingInSpaceDoesNotDoubleTheSpace() {
        XCTAssertEqual(appendingTranscript("there", to: "hello "),
                       "hello there",
                       "A draft already ending in a space must NOT gain a second space.")
    }

    func testExistingEndingInNewlineDoesNotAddSpace() {
        XCTAssertEqual(appendingTranscript("there", to: "hello\n"),
                       "hello\nthere",
                       "A draft ending in a newline must not stack a space after the newline.")
    }

    func testExistingEndingInTabDoesNotAddSpace() {
        XCTAssertEqual(appendingTranscript("there", to: "hello\t"),
                       "hello\tthere",
                       "A draft ending in any whitespace must not gain an extra separating space.")
    }

    // MARK: - Never replaces an existing draft

    func testNeverReplacesExistingWithEmptyTranscript() {
        XCTAssertEqual(appendingTranscript("", to: "hello"),
                       "hello",
                       "An empty transcript must leave the existing draft untouched (never blank it).")
    }

    func testWhitespaceOnlyTranscriptLeavesExistingUntouched() {
        XCTAssertEqual(appendingTranscript("   \n  ", to: "hello"),
                       "hello",
                       "A whitespace-only transcript trims to empty and must NOT mutate the draft.")
    }

    func testExistingContentIsAlwaysPreservedAsAPrefix() {
        let existing = "user typed this first"
        let result = appendingTranscript("then dictated", to: existing)
        XCTAssertTrue(result.hasPrefix(existing),
                      "The existing draft must always remain a prefix — appended, never replaced.")
        XCTAssertTrue(result.hasSuffix("then dictated"),
                      "The new transcript must land at the end of the merged draft.")
    }

    // MARK: - Both empty

    func testBothEmptyReturnsEmpty() {
        XCTAssertEqual(appendingTranscript("", to: ""),
                       "",
                       "Empty transcript into empty draft stays empty.")
    }
}
#endif
