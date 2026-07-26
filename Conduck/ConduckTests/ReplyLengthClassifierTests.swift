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

    // MARK: - Fence detection is linear (untrusted reply text, main actor)

    /// The patterns `containsFencedCode` used before it became a scalar walk. `\s`
    /// matches `\n`, so ICU expanded `\s*` across the whole remaining whitespace run
    /// from EVERY line start and backtracked — O(n²) on fence-free reply text
    /// (measured: 8 000 newlines = 2.1 s, 16 000 = 8.3 s), on the main actor, in the
    /// macOS popover. Kept verbatim as the equivalence oracle.
    private static let referencePatterns = ["(?m)^\\s*```", "(?m)^\\s*~~~"]

    private func referenceContainsFencedCode(_ text: String) -> Bool {
        for pattern in Self.referencePatterns {
            if text.range(of: pattern, options: .regularExpression) != nil { return true }
        }
        return false
    }

    func testFenceDetectionMatchesTheOriginalPatternOnTerminatorAndSpaceEdgeCases() {
        // Every scalar ICU treats as starting a new line, and every Unicode space
        // that is or is not in ICU's `\s` — the exact places a line-splitting
        // implementation diverges from the regex.
        let cases = [
            "", "```", "~~~", " ```", "\t```", "\n```", "x```", "a\n  ```b", "`` `", "``",
            "Here you go:\n```swift\nlet x = 1\n```\nDone.", "~~~\ncode\n~~~",
            "- step:\n    ```\n    run()\n    ```", "Just a normal sentence.",
            "Use the `map` function here.",
            // CR alone starts a line for ICU's `^`, so this DOES contain a fence.
            "\r```", "a\r  ```", "```\r\n",
            // NEL / LS / PS / VT / FF likewise.
            "a\u{0085}```", "a\u{2028}```", "a\u{2029}~~~", "a\u{000B}```", "a\u{000C}```",
            // Unicode spaces that are NOT line starts: the fence stays inline.
            "a\u{00A0}```", "a\u{3000}```", "a\u{2000}```", "x\u{1680}```",
            // Zero-width space is not whitespace at all.
            "\u{200B}```",
            "  \n\n   ```", "x \n y ```", "\n\n\n", "   ", "~~", "~~~~", "a~~~", "\t\t~~~x",
        ]
        for input in cases {
            XCTAssertEqual(
                ReplyLengthClassifier.containsFencedCode(input),
                referenceContainsFencedCode(input),
                "fence detection diverged from the reference pattern for \(input.debugDescription)"
            )
        }
    }

    func testFenceDetectionMatchesTheOriginalPatternOnGeneratedInput() {
        var rng = SplitMix64(seed: 0xFACE_0001)
        let alphabet: [Character] = Array("`~ \t\nxa\r")
            + ["\u{000B}", "\u{000C}", "\u{0085}", "\u{2028}", "\u{2029}", "\u{00A0}", "\u{3000}", "\u{200B}"]
        for _ in 0..<20_000 {
            let length = Int.random(in: 0...14, using: &rng)
            var input = ""
            for _ in 0..<length {
                input.append(alphabet[Int.random(in: 0..<alphabet.count, using: &rng)])
            }
            XCTAssertEqual(
                ReplyLengthClassifier.containsFencedCode(input),
                referenceContainsFencedCode(input),
                "fence detection diverged for \(input.debugDescription)"
            )
        }
    }

    func testFenceDetectionHandlesTruncatedFencesAtTheEndOfTheReply() {
        // The walk needs two scalars of lookahead past the one it is standing on,
        // and the reply can end anywhere — including one or two scalars into what
        // would have been a fence. These are the inputs where an off-by-one in the
        // lookahead traps instead of returning false, and they are invisible to
        // the fuzz above only if it never generates a fence at the very end.
        let cases = [
            "```", "~~~", "``", "~~", "`", "~", "a\n```", "a\n``", "a\n`", "a\n~~",
            "  ```", "  ``", "\n\n```", "\n\n``", "x\r```", "x\r``",
        ]
        for input in cases {
            XCTAssertEqual(
                ReplyLengthClassifier.containsFencedCode(input),
                referenceContainsFencedCode(input),
                "fence detection diverged at a reply boundary for \(input.debugDescription)"
            )
        }
    }

    // The memory half of the same contract lives in
    // `ReplySanitizerLinkScannerTests.testDisplayScansNeverMaterializeTheScalarView`,
    // whose source guard covers this file too: `containsFencedCode` walks
    // `text.unicodeScalars` by index and must never copy it into an `Array`. It
    // runs inside the macOS popover's `body` over an untrusted, length-unbounded
    // reply, where that copy costs 4 bytes per scalar on every view evaluation.
    // One guard, both scans — a second copy here would only rot.

    func testFenceFreeWhitespaceFloodClassifiesFast() {
        // The payload: a reply of blank lines with no fence, which forced the old
        // pattern through every line start.
        let poison = String(repeating: "\n", count: 200_000)
        let start = Date()
        let result = ReplyLengthClassifier.containsFencedCode(poison)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertFalse(result)
        XCTAssertLessThan(
            elapsed, 2.0,
            "200 000 newlines took \(elapsed)s — pre-fix, 16 000 alone measured 8.3 s"
        )
    }
}

/// Deterministic generator so a fuzz failure is reproducible. SplitMix64.
private struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { self.state = seed }

    mutating func next() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
