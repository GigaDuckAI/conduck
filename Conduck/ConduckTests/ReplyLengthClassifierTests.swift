// Conduck
// ReplyLengthClassifierTests.swift
//
// Pure-logic coverage for the macOS popover's long-reply classifier. Drives the
// fenced-code detection + the combined `isLong` predicate (measured-height OR
// code-fence) directly — no view, no platform. Platform-neutral (the helper has
// no `#if`), so it runs on the iOS-sim ConduckTests target.

import XCTest
@testable import Conduck

final class ReplyLengthClassifierTests: XCTestCase {

    // MARK: - Fenced code detection

    func testDetectsBacktickFence() {
        let text = "Here you go:\n```swift\nlet x = 1\n```\nDone."
        XCTAssertTrue(ReplyLengthClassifier.containsFencedCode(text))
    }

    func testDetectsTildeFence() {
        let text = "~~~\ncode\n~~~"
        XCTAssertTrue(ReplyLengthClassifier.containsFencedCode(text))
    }

    func testDetectsIndentedFence() {
        // A fence indented under a list item still counts.
        let text = "- step:\n    ```\n    run()\n    ```"
        XCTAssertTrue(ReplyLengthClassifier.containsFencedCode(text))
    }

    func testPlainProseHasNoFence() {
        let text = "Just a normal sentence with no code at all."
        XCTAssertFalse(ReplyLengthClassifier.containsFencedCode(text))
    }

    func testInlineBacktickIsNotAFence() {
        // A single inline `code` span (one backtick run mid-line) is not a fenced
        // block — only a line-leading triple fence qualifies.
        let text = "Use the `map` function here."
        XCTAssertFalse(ReplyLengthClassifier.containsFencedCode(text))
    }

    // MARK: - Combined isLong

    func testShortProseUnderCapIsNotLong() {
        XCTAssertFalse(ReplyLengthClassifier.isLong(text: "short", measuredHeight: 120, cap: 300))
    }

    func testTallProseOverCapIsLong() {
        XCTAssertTrue(ReplyLengthClassifier.isLong(text: "lots of prose", measuredHeight: 420, cap: 300))
    }

    func testCodeHeavyShortReplyIsLong() {
        // Even when it fits the cap, fenced code routes to the window (it wraps
        // badly at 300pt).
        let text = "```\nfoo()\n```"
        XCTAssertTrue(ReplyLengthClassifier.isLong(text: text, measuredHeight: 80, cap: 300))
    }

    func testHeightExactlyAtCapIsNotLong() {
        XCTAssertFalse(ReplyLengthClassifier.isLong(text: "x", measuredHeight: 300, cap: 300),
                       "Content exactly at the cap fits without scrolling — not long.")
    }
}
