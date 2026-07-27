// SPDX-License-Identifier: Apache-2.0

// Conduck
// ReplySanitizerTests.swift
//
// Strip-correctness coverage for the shared `ReplySanitizer.spoken(_:)`
// (Services/ReplySanitizer.swift). Agent replies arrive as Markdown; this
// proves the speakable-text strip keeps human-meaningful content while removing
// markup, so the TTS surfaces (Watch / CarPlay / macOS auto-speak) never read
// literal asterisks, backticks, URLs, or emoji aloud.
//
// Pure-Foundation type — no platform import — so it runs in the unsigned logic
// test pass. Dropped into the synchronized `ConduckTests` group → auto-
// included in the test target.

import XCTest
@testable import Conduck

final class ReplySanitizerTests: XCTestCase {

    // MARK: - Bold / italic

    func testStripsBoldDoubleAsterisk() {
        XCTAssertEqual(ReplySanitizer.spoken("This is **important** news."),
                       "This is important news.")
    }

    func testStripsBoldDoubleUnderscore() {
        XCTAssertEqual(ReplySanitizer.spoken("This is __important__ news."),
                       "This is important news.")
    }

    func testStripsItalicSingleAsterisk() {
        XCTAssertEqual(ReplySanitizer.spoken("A *subtle* hint."),
                       "A subtle hint.")
    }

    func testStripsItalicSingleUnderscore() {
        XCTAssertEqual(ReplySanitizer.spoken("A _subtle_ hint."),
                       "A subtle hint.")
    }

    func testBoldRunsBeforeItalicSoBoldNotHalfEaten() {
        // **x** must come out as "x", not "*x*" (italic eating one pair).
        XCTAssertEqual(ReplySanitizer.spoken("**x**"), "x")
    }

    // MARK: - Inline code / fenced blocks

    func testKeepsInlineCodeContent() {
        XCTAssertEqual(ReplySanitizer.spoken("Run `git status` now."),
                       "Run git status now.")
    }

    func testFencedCodeBlockBecomesPlaceholder() {
        let input = """
        Here you go:
        ```swift
        let x = 1
        print(x)
        ```
        Done.
        """
        let out = ReplySanitizer.spoken(input)
        XCTAssertTrue(out.contains("[code block]"), "expected placeholder, got: \(out)")
        XCTAssertFalse(out.contains("let x = 1"), "fenced body must not leak: \(out)")
        XCTAssertFalse(out.contains("```"), "fence markers must be gone: \(out)")
    }

    func testSingleLineFenceBecomesPlaceholder() {
        let out = ReplySanitizer.spoken("Inline fence ```code``` here.")
        XCTAssertTrue(out.contains("[code block]"))
        XCTAssertFalse(out.contains("```"))
    }

    // MARK: - Links

    func testLinkKeepsLabelDropsURL() {
        XCTAssertEqual(ReplySanitizer.spoken("See [the docs](https://example.com/page) for more."),
                       "See the docs for more.")
    }

    func testImageLinkKeepsAltText() {
        let out = ReplySanitizer.spoken("![a diagram](https://example.com/x.png)")
        XCTAssertEqual(out, "a diagram")
        XCTAssertFalse(out.contains("http"))
    }

    // MARK: - List markers / headings / blockquotes

    func testStripsUnorderedListMarkers() {
        let input = """
        - milk
        * eggs
        + bread
        """
        XCTAssertEqual(ReplySanitizer.spoken(input), "milk\neggs\nbread")
    }

    func testStripsOrderedListMarkers() {
        let input = """
        1. first
        2. second
        """
        XCTAssertEqual(ReplySanitizer.spoken(input), "first\nsecond")
    }

    func testStripsHeadingMarkers() {
        XCTAssertEqual(ReplySanitizer.spoken("## Summary"), "Summary")
        XCTAssertEqual(ReplySanitizer.spoken("###### Deep"), "Deep")
    }

    func testStripsBlockquoteMarkers() {
        XCTAssertEqual(ReplySanitizer.spoken("> quoted line"), "quoted line")
    }

    func testStripsNestedBlockquoteMarkers() {
        XCTAssertEqual(ReplySanitizer.spoken("> > deep quote"), "deep quote")
    }

    func testMidSentenceHashNotTouched() {
        // A `#` that isn't a leading heading marker must survive.
        XCTAssertEqual(ReplySanitizer.spoken("Issue #42 is fixed."),
                       "Issue #42 is fixed.")
    }

    // MARK: - Emoji

    func testStripsEmoji() {
        let out = ReplySanitizer.spoken("All done 🎉 great work 👍")
        XCTAssertFalse(out.contains("🎉"))
        XCTAssertFalse(out.contains("👍"))
        XCTAssertTrue(out.contains("All done"))
        XCTAssertTrue(out.contains("great work"))
    }

    func testStripsZWJEmojiSequence() {
        // Family / profession ZWJ sequences should fully disappear.
        let out = ReplySanitizer.spoken("Team 👨‍👩‍👧 update")
        XCTAssertTrue(out.contains("Team"))
        XCTAssertTrue(out.contains("update"))
        XCTAssertFalse(out.unicodeScalars.contains { $0.properties.isEmojiPresentation })
    }

    // MARK: - Whitespace collapse

    func testCollapsesBlankLineRuns() {
        let input = "Line one\n\n\n\nLine two"
        XCTAssertEqual(ReplySanitizer.spoken(input), "Line one\n\nLine two")
    }

    func testTrimsTrailingWhitespacePerLine() {
        let input = "alpha   \nbeta\t"
        XCTAssertEqual(ReplySanitizer.spoken(input), "alpha\nbeta")
    }

    func testTrimsOuterWhitespace() {
        XCTAssertEqual(ReplySanitizer.spoken("\n\n  hello  \n\n"), "hello")
    }

    // MARK: - Combined / passthrough

    func testCombinedMarkdownStrip() {
        let input = """
        # Plan

        Here's the **plan**:

        1. Read the [spec](https://x.com)
        2. Run `make build`

        Done ✅
        """
        let out = ReplySanitizer.spoken(input)
        XCTAssertTrue(out.contains("Plan"))
        XCTAssertTrue(out.contains("Here's the plan:"))
        XCTAssertTrue(out.contains("Read the spec"))
        XCTAssertTrue(out.contains("Run make build"))
        XCTAssertFalse(out.contains("#"))
        XCTAssertFalse(out.contains("**"))
        XCTAssertFalse(out.contains("http"))
        XCTAssertFalse(out.contains("✅"))
        XCTAssertFalse(out.contains("`"))
    }

    func testPlainTextPassesThroughUnchanged() {
        let plain = "Just a normal sentence with no markup at all."
        XCTAssertEqual(ReplySanitizer.spoken(plain), plain)
    }

    func testEmptyStringIsEmpty() {
        XCTAssertEqual(ReplySanitizer.spoken(""), "")
    }

    // MARK: - linkCollapsed (display variant)

    func testLinkCollapsedKeepsLabelDropsTarget() {
        // Field-observed shape: an agent file link carrying the gateway
        // host's filesystem path must display as just the filename.
        XCTAssertEqual(
            ReplySanitizer.linkCollapsed("Created [poem.mD](/Users/testuser/conduck-files/poem.mD)."),
            "Created poem.mD.")
    }

    func testLinkCollapsedHandlesImageLinks() {
        XCTAssertEqual(
            ReplySanitizer.linkCollapsed("See ![chart](https://example.com/chart.png) above."),
            "See chart above.")
    }

    func testLinkCollapsedLeavesOtherMarkupVerbatim() {
        // Display variant collapses LINKS ONLY — emphasis, inline code, and
        // structure stay untouched (the full strip is TTS-only).
        let text = "**Bold** and `code` and\n- a list item"
        XCTAssertEqual(ReplySanitizer.linkCollapsed(text), text)
    }

    func testLinkCollapsedPlainTextUnchanged() {
        let plain = "Just a normal sentence with no markup at all."
        XCTAssertEqual(ReplySanitizer.linkCollapsed(plain), plain)
    }
}
