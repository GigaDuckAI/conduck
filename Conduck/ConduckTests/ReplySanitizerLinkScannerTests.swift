// SPDX-License-Identifier: Apache-2.0

// Conduck
// ReplySanitizerLinkScannerTests.swift
//
// Two locks on `ReplySanitizer`, both about UNTRUSTED reply text:
//
//   1. EQUIVALENCE. `linkCollapsed` / the inline-span pass no longer run the
//      regex `!?\[([^\]]*)\]\([^)]*\)` — they run a one-pass scanner. That regex
//      is reproduced verbatim HERE as the reference oracle, and the scanner is
//      diffed against it over hand-picked adversarial shapes plus ~50 000
//      generated strings from delimiter-dense alphabets (including combining
//      marks and astral-plane scalars, which are exactly where a Character-based
//      scanner would diverge from ICU's UTF-16 view). This is the guard that
//      makes the rewrite safe: the pattern's job is to decide WHICH substring
//      becomes the displayed label, and a change in match EXTENT is a silent
//      content bug, not a performance detail.
//
//   2. COST. Each of the three shapes that were superlinear is fed its own
//      worst-case payload and must finish in well under a second. The bounds are
//      deliberately loose (seconds, on inputs that previously took 6–100 s) so
//      the tests pin the ALGORITHM rather than the speed of the machine running
//      them; a regression to any quadratic form blows them by orders of
//      magnitude, and nothing else can.
//
// Why this matters beyond speed: every one of these call sites is on the main
// actor, the input is agent reply text (a hostile gateway, or a prompt-injected
// agent on an honest one), and the reply is persisted + CloudKit-synced before it
// renders — so one poisoned reply froze the conversation list on every device,
// every launch, with the delete affordance behind the frozen surface.
//
// Pure-Foundation type — no platform import — so it runs in the unsigned logic
// test pass. Dropped into the synchronized `ConduckTests` group → auto-included.

import XCTest
@testable import Conduck

final class ReplySanitizerLinkScannerTests: XCTestCase {

    // MARK: - Reference oracle

    /// The EXACT pattern + template `ReplySanitizer` used before the scanner
    /// landed. Kept verbatim: if someone "fixes" the scanner in a way that
    /// changes which substring is captured, this oracle catches it.
    private static let referencePattern = "!?\\[([^\\]]*)\\]\\([^)]*\\)"

    /// Compiled once — the fuzz pass runs tens of thousands of comparisons, and a
    /// per-call compile would dominate the runtime.
    private static let referenceRegex = try? NSRegularExpression(pattern: referencePattern)

    private func referenceCollapse(_ text: String) -> String {
        guard let regex = Self.referenceRegex else {
            XCTFail("reference pattern must compile")
            return text
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: "$1")
    }

    private func assertMatchesReference(_ input: String, _ label: String = "") {
        let expected = referenceCollapse(input)
        let actual = ReplySanitizer.linkCollapsed(input)
        XCTAssertEqual(
            actual, expected,
            "link collapse diverged from the reference regex \(label) for input \(input.debugDescription)"
        )
    }

    // MARK: - 1. Equivalence — hand-picked adversarial shapes

    func testLinkCollapseMatchesReferenceRegexOnAdversarialShapes() {
        let cases = [
            "", "[", "]", "()", "[]()", "[a](b)", "![a](b)", "x![a](b)y",
            // Whitespace-bearing link target: valid Markdown that LLMs emit. A
            // bounded `[^)\s]` quantifier would stop matching this and leak the
            // raw markup into Watch bubbles and TTS.
            "[a](b \"title\")",
            "[the docs](https://example.com/a b)",
            // Unbalanced / nested brackets — the shapes that drive backtracking.
            "[[a]](b)", "[a]](b)", "[a](b", "[a](b) [c](d",
            "!![a](b)", "!!![x](y)", "[](())", "[a]()", "[]( )",
            "[a](b)[c](d)[e](f)", "[[[[a]]]](x)", "((([a](b))))",
            "[a](b))c", "[a]((b)c", "!", "!!", "![", "![]", "![](", "![]()",
            "nested [outer [inner](url) more](url2)",
            // Newlines inside label / target.
            "[a\nb](c)", "[a](b\nc)",
            // Grapheme-cluster traps: a combining mark fused to a delimiter, and
            // non-BMP scalars that are two UTF-16 units each.
            "[e\u{0301}](y)", "[\u{0301}a](b)", "[emoji 🎉](x)",
            "[𝔘𝔫𝔦](𝔠𝔬𝔡𝔢)", "[a](𝔠)b",
            // Field-observed shape (an agent file link carrying a host path).
            "Created [poem.mD](/Users/testuser/conduck-files/poem.mD).",
        ]
        for (index, input) in cases.enumerated() {
            assertMatchesReference(input, "case #\(index)")
        }
    }

    func testLinkCollapseMatchesReferenceRegexOnInputsShorterThanTheShortestMatch() {
        // `[]()` is the shortest string the pattern can match, so anything shorter
        // is a guaranteed no-op. The scanner carries no length fast path — it
        // reaches that answer by failing to find `]`, `(` or `)` — so these are
        // the inputs where a bookkeeping slip (an index stepped past the end, a
        // resume position that never advances) would surface as a trap or a hang
        // rather than a wrong string.
        for input in ["", "[", "]", "(", ")", "!", "[]", "[(", "[)", "![", "[a", "a[", "[[", "]]", "[]("] {
            assertMatchesReference(input, "short")
        }
    }

    // MARK: - 1b. Equivalence — generated

    func testLinkCollapseMatchesReferenceRegexOnGeneratedInput() {
        // Fixed seed: a failure must be reproducible from the test name alone.
        var rng = SeededGenerator(seed: 0x5EED_C0DE)
        let alphabets: [[Character]] = [
            Array("[]()!"),
            Array("[]()! a"),
            Array("[]()!ab \n\"'"),
            Array("[]"),
            Array("[](){}!aA1. \t\n"),
            Array("[]()!\u{0301}\u{1F600}𝔘"),
        ]
        for alphabet in alphabets {
            for _ in 0..<8_000 {
                let length = Int.random(in: 0...24, using: &rng)
                var input = ""
                for _ in 0..<length {
                    input.append(alphabet[Int.random(in: 0..<alphabet.count, using: &rng)])
                }
                assertMatchesReference(input, "generated")
            }
        }
        // A few longer strings: structure over distance, where the scan/skip
        // bookkeeping (resume position after a failed `[`) actually gets exercised.
        let longAlphabet = Array("[]()! abc\n\"")
        for _ in 0..<500 {
            let length = Int.random(in: 40...400, using: &rng)
            var input = ""
            for _ in 0..<length {
                input.append(longAlphabet[Int.random(in: 0..<longAlphabet.count, using: &rng)])
            }
            assertMatchesReference(input, "generated-long")
        }
    }

    // MARK: - 2. Cost — the link pattern

    func testUnmatchedBracketFloodCollapsesFast() {
        // The launch-hang payload. With the old regex this input cost ~10 s
        // (32 KB) on a fast Mac and minutes at 200 KB, ON THE MAIN ACTOR, from
        // the conversation-list row that mounts as the iPad/macOS sidebar.
        let poison = String(repeating: "[", count: 200_000)
        let elapsed = timing { _ = ReplySanitizer.linkCollapsed(poison) }
        XCTAssertLessThan(
            elapsed, 2.0,
            "200 KB of unmatched `[` must collapse in one linear pass; \(elapsed)s means the quadratic regex is back"
        )
        XCTAssertEqual(
            ReplySanitizer.linkCollapsed(poison), poison,
            "no link means no rewrite"
        )
    }

    func testUnmatchedBracketFloodIsSpokenFast() {
        // Same payload through the FULL strip (the CarPlay / auto-speak path).
        let poison = String(repeating: "[", count: 200_000)
        let elapsed = timing { _ = ReplySanitizer.spoken(poison) }
        XCTAssertLessThan(elapsed, 2.0, "full strip on 200 KB of `[` took \(elapsed)s")
    }

    // MARK: - 2b. Cost — the trailing-whitespace shape

    func testTrailingWhitespaceFloodIsSpokenFast() {
        // `[ \t]+$` was the most expensive pattern in the file: 8 KB of spaces
        // followed by ONE letter measured 5.9 s, 32 KB measured 101 s — and it
        // ran per line, so N such lines multiplied it.
        // Two lines keeps the payload (16 003 chars) inside
        // `maxSpokenInputCount`, so the test measures the trim and not the clamp.
        let line = String(repeating: " ", count: 8_000) + "a"
        let poison = Array(repeating: line, count: 2).joined(separator: "\n")
        XCTAssertLessThan(poison.count, ReplySanitizer.maxSpokenInputCount)
        let elapsed = timing { _ = ReplySanitizer.spoken(poison) }
        XCTAssertLessThan(
            elapsed, 2.0,
            "2 lines of 8 KB interior whitespace took \(elapsed)s — pre-fix this measured ~12 s"
        )
    }

    func testTrailingWhitespaceTrimStillMatchesRegexSemantics() {
        // The linear trim must behave exactly like `[ \t]+$` did.
        XCTAssertEqual(ReplySanitizer.spoken("alpha   \nbeta\t"), "alpha\nbeta")
        XCTAssertEqual(ReplySanitizer.spoken("a \t \t b   "), "a \t \t b")
        XCTAssertEqual(ReplySanitizer.spoken("   "), "")
        // Interior whitespace is untouched.
        XCTAssertEqual(ReplySanitizer.spoken("a   b"), "a   b")
    }

    // MARK: - 2c. Cost — the fenced-code shape

    func testFenceMarkerFloodIsSpokenFast() {
        // The two multi-line fence patterns re-scan the rest of the line from
        // every marker, so one long line of ` ``` ` is quadratic. Over
        // `maxFenceMarkerScalars` they are skipped.
        let poison = String(repeating: "```", count: 20_000)
        let elapsed = timing { _ = ReplySanitizer.spoken(poison) }
        XCTAssertLessThan(elapsed, 2.0, "fence-marker flood took \(elapsed)s")
    }

    func testFenceBudgetKeepsCollapsingRealisticCodeReplies() {
        // A reply well inside the budget must still collapse a multi-line fence —
        // the guard must not degrade normal code answers.
        let input = """
        Here you go:
        ```swift
        let x = 1
        ```
        Done.
        """
        let out = ReplySanitizer.spoken(input)
        XCTAssertTrue(out.contains("[code block]"))
        XCTAssertFalse(out.contains("```"))
    }

    func testOverBudgetFenceMarkersDegradeToUncollapsedNotToAFreeze() {
        // Documented degradation at the boundary: past the marker budget a
        // MULTI-LINE fenced body is read aloud instead of collapsing. Asserted so
        // the trade-off is visible rather than surprising.
        let filler = String(repeating: "`x` ", count: ReplySanitizer.maxFenceMarkerScalars)
        let input = filler + "\n```swift\nlet x = 1\n```\n"
        let out = ReplySanitizer.spoken(input)
        XCTAssertFalse(
            out.contains("[code block]"),
            "over the marker budget the multi-line fence pass is deliberately skipped"
        )
    }

    // MARK: - 2d. The `spoken` input ceiling

    func testSpokenClampsAbsurdlyLongInputAtAWordBoundary() {
        let word = "alpha "
        let long = String(repeating: word, count: ReplySanitizer.maxSpokenInputCount)  // ≫ ceiling
        let out = ReplySanitizer.spoken(long)
        XCTAssertLessThanOrEqual(out.count, ReplySanitizer.maxSpokenInputCount)
        XCTAssertGreaterThan(
            out.count, ReplySanitizer.maxSpokenInputCount - ReplySanitizer.spokenCutBackoffCount - 1,
            "the clamp must cut near the ceiling, not far short of it"
        )
        XCTAssertTrue(out.hasSuffix("alpha"), "the cut must land between words: \(out.suffix(20))")
    }

    func testSpokenLeavesInputInsideTheCeilingByteIdentical() {
        // The ceiling must be invisible to every real reply.
        let reply = "Here is the summary. " + String(repeating: "word ", count: 200)
        XCTAssertLessThan(reply.count, ReplySanitizer.maxSpokenInputCount)
        XCTAssertEqual(
            ReplySanitizer.spoken(reply),
            reply.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    func testLinkCollapsedHasNoCeiling() {
        // The DISPLAY variant must never truncate: the Watch bubble is the only
        // route to a long reply's text on the wrist.
        let long = String(repeating: "sentence ", count: 40_000)
        XCTAssertEqual(ReplySanitizer.linkCollapsed(long), long)
    }

    func testLinkCollapsedCollapsesEveryLinkInALongReplyWithoutLosingText() {
        // The other half of "no ceiling": a long reply that DOES match must have
        // every link collapsed and every surrounding word kept. A size-gated bail
        // would pass `testLinkCollapsedHasNoCeiling` (that input has no links)
        // while silently leaving raw `[label](target)` markup — including a
        // gateway-side filesystem path — on screen past the gate.
        let unit = "See [the report](/Users/testuser/conduck-files/report.md) for details. "
        let long = String(repeating: unit, count: 20_000)
        let out = ReplySanitizer.linkCollapsed(long)
        XCTAssertFalse(out.contains("]("), "a link survived uncollapsed in a long reply")
        XCTAssertFalse(out.contains("/Users/testuser"), "a raw link target survived in a long reply")
        XCTAssertEqual(
            out, String(repeating: "See the report for details. ", count: 20_000),
            "the collapse must keep every label and every word between the links"
        )
    }

    // MARK: - 3. Cost — neither display scan may materialize the reply
    //
    // `linkCollapsed` runs inside the Watch bubble's `body` and
    // `ReplyLengthClassifier.containsFencedCode` inside the macOS popover's, so
    // both re-run on EVERY view evaluation over an untrusted, length-unbounded
    // reply (the only ceiling left is the 16 MiB background-response cap). Both
    // once wrote `Array(text.unicodeScalars)`, which costs 4 bytes per scalar on
    // top of the string it was copied from — measured on a 4 MB bracket-bearing
    // reply that collapses to nothing: 16.4 MiB of peak growth for the array
    // form versus 48 KiB for the index walk that replaced it. On the wrist that
    // is the difference between a render and a jetsam.
    //
    // Nothing observable at runtime distinguishes "scanned the view's indices"
    // from "copied it into an array first" — the answers are identical and the
    // cost is memory, not time — so the shape is pinned against the sources, the
    // same way the temp-sweep call sites are.

    /// `.../Conduck/Conduck` — the project container holding every target's sources.
    private func projectContainerURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // .../ConduckTests
            .deletingLastPathComponent()   // .../Conduck/Conduck
    }

    /// Drops `//`-to-end-of-line so the prose explaining why the array is gone is
    /// never read as the array coming back.
    private func strippingComments(_ source: String) -> String {
        source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> Substring in
                guard let marker = line.range(of: "//") else { return line }
                return line[line.startIndex..<marker.lowerBound]
            }
            .joined(separator: "\n")
    }

    func testDisplayScansNeverMaterializeTheScalarView() throws {
        let container = projectContainerURL().appendingPathComponent("Conduck/Services")
        for file in ["ReplySanitizer.swift", "ReplyLengthClassifier.swift"] {
            let url = container.appendingPathComponent(file)
            guard let raw = try? String(contentsOf: url, encoding: .utf8) else {
                throw XCTSkip("\(file) unreadable at \(url.path) — this guard runs against a checkout only.")
            }
            let code = strippingComments(raw)

            var cursor = code.startIndex
            while let hit = code.range(of: ".unicodeScalars", range: cursor..<code.endIndex) {
                cursor = hit.upperBound
                // `Array(text.unicodeScalars)` puts the call 18 characters ahead of
                // the property; 40 covers any receiver name without reaching the
                // previous statement.
                let start = code.index(hit.lowerBound, offsetBy: -40, limitedBy: code.startIndex)
                    ?? code.startIndex
                guard code[start..<hit.lowerBound].contains("Array(") else { continue }
                let line = code[code.startIndex..<hit.lowerBound].lazy.filter { $0 == "\n" }.count + 1
                XCTFail("""
                \(file):\(line) materializes the scalar view into an Array. Both scans here run \
                inside a SwiftUI `body` over an untrusted, length-unbounded reply, so that is \
                4 bytes per scalar of peak memory on every view evaluation — 16.4 MiB for a 4 MB \
                reply, on surfaces that include the Watch. Walk `text.unicodeScalars` by index \
                instead; it answers identically and allocates nothing.
                """)
            }
        }
    }

    // MARK: - Helpers

    private func timing(_ body: () -> Void) -> TimeInterval {
        let start = Date()
        body()
        return Date().timeIntervalSince(start)
    }
}

/// Deterministic generator so a fuzz failure is reproducible. SplitMix64.
private struct SeededGenerator: RandomNumberGenerator {
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
