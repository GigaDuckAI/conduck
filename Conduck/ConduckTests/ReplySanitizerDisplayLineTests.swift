// SPDX-License-Identifier: Apache-2.0

// Conduck
// ReplySanitizerDisplayLineTests.swift
//
// Locks on `ReplySanitizer.displayLine(_:maxLength:fallback:)` — the display
// projection every LABEL surface runs untrusted remote text through
// (notification bodies, persisted conversation titles, list rows, CarPlay rows,
// VoiceOver labels). The text is an agent reply from the user's gateway or a
// transcript from a BYO speech-to-text endpoint: adversary-controlled, and
// persisted before it is ever rendered.
//
// Four properties are pinned here, and each of them is a bug the moment it
// stops holding:
//
//   1. THE CAP APPLIES AFTER THE PROJECTION. Truncating first can cut between a
//      bidi opener and its terminator, leaving the opener governing everything
//      the label still shows. The cap is a parameter for exactly this reason, so
//      the oracle in `testNaiveTruncateFirstWouldHaveLeftTheOpenerBehind`
//      reproduces the WRONG order and shows the two answers differ.
//   2. THE HOSTILE CLASS IS GONE. C0 · DEL · C1 · the bidi mark / embedding /
//      override / isolate families. The local `isHostileScalar` oracle is an
//      independent restatement of the denylist, not a call into the code under
//      test.
//   3. RIGHT-TO-LEFT SCRIPT IS NOT. Arabic, Hebrew and Persian pass through
//      byte-for-byte. Confusing "explicit bidi FORMATTING control" with "text
//      that happens to run right to left" would silently render those languages
//      as mojibake, on a surface no English-reading tester would look twice at.
//   4. THE PROJECTION IS LINEAR, and a capped call stops at the cap. Every
//      caller is on the main actor with an untrusted, length-unbounded input —
//      the cost rule the whole of `ReplySanitizer.swift` is written to.
//
// Plus the speech strip's half of the same fix: `spoken` must not hand control
// or bidi scalars to the synthesizer, while still keeping the tabs and line
// feeds `SpeechSegmenter` paces sentences by.
//
// Pure-Foundation type — no platform import — so it runs in the unsigned logic
// test pass. Dropped into the synchronized `ConduckTests` group → auto-included.

import XCTest
@testable import Conduck

final class ReplySanitizerDisplayLineTests: XCTestCase {

    /// Stand-in for the caller's localized "something arrived" string. Distinct
    /// from any projection output so a test can never confuse the two.
    private let fallback = "FALLBACK"

    // MARK: - Oracles

    /// Independent restatement of the scalars that must never reach a rendered
    /// label. Deliberately NOT a call into `ReplySanitizer` — a denylist that
    /// tests itself proves nothing. TAB / LF / CR are excluded because `spoken`
    /// keeps them on purpose; `displayLine` turns them into spaces, which its
    /// own tests assert separately.
    private func isHostileScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x00...0x08, 0x0B, 0x0C, 0x0E...0x1F, 0x7F, 0x80...0x9F:
            return true
        case 0x200E, 0x200F, 0x202A...0x202E, 0x2066...0x2069:
            return true
        case 0x2028, 0x2029:
            return true
        default:
            return false
        }
    }

    private func assertNoHostileScalars(_ text: String, _ label: String) {
        for scalar in text.unicodeScalars where isHostileScalar(scalar) {
            XCTFail("\(label): U+\(String(scalar.value, radix: 16, uppercase: true)) survived")
        }
    }

    // MARK: - 1. The cap applies AFTER the projection

    func testCapAppliesAfterProjectionSoNoBidiOpenerSurvivesTheCut() {
        // The override opens inside the capped region and its terminator sits
        // beyond it — the exact shape that makes truncate-first dangerous.
        let head = String(repeating: "a", count: 18)
        let input = head + "\u{202E}" + "spoof" + "\u{202C}" + " tail"

        let out = ReplySanitizer.displayLine(input, maxLength: 20, fallback: fallback)

        // The controls never occupy budget, so the cap lands two characters into
        // the word that followed the opener.
        XCTAssertEqual(out, head + "sp")
        XCTAssertEqual(out.count, 20)
        assertNoHostileScalars(out, "capped projection")
    }

    func testNaiveTruncateFirstWouldHaveLeftTheOpenerBehind() {
        // The mistake the parameter exists to make impossible, reproduced here
        // so the reason survives a refactor: cut the raw string first and the
        // opener is inside the cut while its terminator is not.
        let head = String(repeating: "a", count: 18)
        let input = head + "\u{202E}" + "spoof" + "\u{202C}" + " tail"

        let truncatedFirst = String(input.prefix(20))
        XCTAssertTrue(
            truncatedFirst.unicodeScalars.contains { $0.value == 0x202E },
            "precondition: the wrong order keeps the override"
        )
        XCTAssertFalse(
            truncatedFirst.unicodeScalars.contains { $0.value == 0x202C },
            "precondition: the wrong order drops its terminator"
        )
        XCTAssertNotEqual(
            ReplySanitizer.displayLine(input, maxLength: 20, fallback: fallback),
            truncatedFirst,
            "projecting after the cut must not be what displayLine does"
        )
    }

    func testResultNeverExceedsTheCapAndNeverEndsInWhitespace() {
        let input = "alpha \u{202E}beta\tgamma\ndelta \u{0000}epsilon"
        for cap in 1...40 {
            let out = ReplySanitizer.displayLine(input, maxLength: cap, fallback: fallback)
            XCTAssertLessThanOrEqual(out.count, cap, "cap \(cap) overflowed: \(out)")
            XCTAssertFalse(out.hasPrefix(" "), "cap \(cap) kept a leading space")
            XCTAssertFalse(out.hasSuffix(" "), "cap \(cap) left a trailing space")
            assertNoHostileScalars(out, "cap \(cap)")
        }
    }

    func testCapNeverSplitsAGraphemeCluster() {
        // A ZWJ family sequence is ONE user-perceived character; half of one is
        // a rendering artifact on a notification the user cannot dismiss into
        // anything more legible.
        XCTAssertEqual(
            ReplySanitizer.displayLine("👨‍👩‍👧 hello", maxLength: 2, fallback: fallback),
            "👨‍👩‍👧"
        )
        // Same for a base character carrying a combining mark.
        XCTAssertEqual(
            ReplySanitizer.displayLine("e\u{0301}xtra", maxLength: 1, fallback: fallback),
            "e\u{0301}"
        )
    }

    func testCapSpendsNoBudgetOnASeparatorItCannotFollow() {
        // Room for "a" and the space but not the word after it → stop at "a"
        // rather than end the line on whitespace.
        XCTAssertEqual(ReplySanitizer.displayLine("a b", maxLength: 2, fallback: fallback), "a")
        XCTAssertEqual(ReplySanitizer.displayLine("a b", maxLength: 3, fallback: fallback), "a b")
    }

    func testCapOfZeroOrLessYieldsTheFallback() {
        XCTAssertEqual(ReplySanitizer.displayLine("hello", maxLength: 0, fallback: fallback), fallback)
        XCTAssertEqual(ReplySanitizer.displayLine("hello", maxLength: -1, fallback: fallback), fallback)
    }

    func testMaxCapProjectsTheWholeInput() {
        XCTAssertEqual(
            ReplySanitizer.displayLine("one\ntwo\nthree", maxLength: .max, fallback: fallback),
            "one two three"
        )
    }

    // MARK: - 2. Breaks become spaces, the rest of the class is removed

    func testLineBreaksTabsAndSeparatorsBecomeSingleSpaces() {
        for (name, breakScalar) in [
            ("LF", "\n"), ("CR", "\r"), ("CRLF", "\r\n"), ("TAB", "\t"),
            ("LINE SEPARATOR", "\u{2028}"), ("PARAGRAPH SEPARATOR", "\u{2029}")
        ] {
            XCTAssertEqual(
                ReplySanitizer.displayLine("one" + breakScalar + "two", maxLength: .max, fallback: fallback),
                "one two",
                "\(name) must separate, not vanish — deleting it would fuse the two words"
            )
        }
    }

    func testC0DeleteAndC1ScalarsAreRemovedOutright() {
        XCTAssertEqual(ReplySanitizer.displayLine("a\u{0000}b", maxLength: .max, fallback: fallback), "ab")
        XCTAssertEqual(ReplySanitizer.displayLine("a\u{0007}b", maxLength: .max, fallback: fallback), "ab")
        XCTAssertEqual(ReplySanitizer.displayLine("a\u{000B}b\u{000C}c", maxLength: .max, fallback: fallback), "abc")
        XCTAssertEqual(ReplySanitizer.displayLine("a\u{007F}b", maxLength: .max, fallback: fallback), "ab")
        XCTAssertEqual(ReplySanitizer.displayLine("a\u{0085}b\u{009F}c", maxLength: .max, fallback: fallback), "abc")
    }

    func testAnsiEscapeIntroducerIsRemoved() {
        // ESC is what turns a reply into terminal-actionable output wherever the
        // label is copied out; only its printable tail may remain.
        let out = ReplySanitizer.displayLine("done\u{001B}[31m", maxLength: .max, fallback: fallback)
        XCTAssertEqual(out, "done[31m")
        assertNoHostileScalars(out, "ansi")
    }

    func testBidiOverridesEmbeddingsIsolatesAndMarksAreRemoved() {
        // The whole family, one scalar at a time, so a partial denylist fails
        // loudly instead of leaving one spoof primitive live.
        let family: [UInt32] = [0x200E, 0x200F, 0x202A, 0x202B, 0x202C, 0x202D, 0x202E,
                                0x2066, 0x2067, 0x2068, 0x2069]
        for value in family {
            guard let scalar = Unicode.Scalar(value) else {
                XCTFail("U+\(String(value, radix: 16)) is not a scalar")
                continue
            }
            let input = "safe" + String(scalar) + "name"
            XCTAssertEqual(
                ReplySanitizer.displayLine(input, maxLength: .max, fallback: fallback),
                "safename",
                "U+\(String(value, radix: 16, uppercase: true)) survived the projection"
            )
        }
    }

    func testWhitespaceRunsCollapseAndBothEndsAreTrimmed() {
        XCTAssertEqual(ReplySanitizer.displayLine("  a   b  ", maxLength: .max, fallback: fallback), "a b")
        XCTAssertEqual(
            ReplySanitizer.displayLine("one \r\n\t \u{2028} two", maxLength: .max, fallback: fallback),
            "one two"
        )
        // A no-break space renders as a space but resists line breaking, which
        // is how a label gets padded into a false layout; it collapses too.
        XCTAssertEqual(ReplySanitizer.displayLine("a\u{00A0}\u{00A0}b", maxLength: .max, fallback: fallback), "a b")
    }

    // MARK: - 3. Right-to-left script survives

    func testArabicPassesThroughUnharmed() {
        let arabic = "مرحبا بالعالم"
        XCTAssertEqual(ReplySanitizer.displayLine(arabic, maxLength: .max, fallback: fallback), arabic)
    }

    func testHebrewPassesThroughUnharmed() {
        let hebrew = "שלום עולם"
        XCTAssertEqual(ReplySanitizer.displayLine(hebrew, maxLength: .max, fallback: fallback), hebrew)
    }

    func testPersianPassesThroughUnharmed() {
        let persian = "سلام دنیا"
        XCTAssertEqual(ReplySanitizer.displayLine(persian, maxLength: .max, fallback: fallback), persian)
    }

    func testRTLScriptSurvivesWhileTheOverrideAroundItGoes() {
        // The distinction the projection has to get right: the RIGHT-TO-LEFT
        // OVERRIDE is removed, the right-to-left LETTERS are not. Getting this
        // backwards breaks Arabic and Hebrew replies silently.
        let arabic = "مرحبا بالعالم"
        XCTAssertEqual(
            ReplySanitizer.displayLine("مرحبا\u{202E} بالعالم", maxLength: .max, fallback: fallback),
            arabic
        )
        // Mixed direction keeps both scripts and only loses the isolate.
        XCTAssertEqual(
            ReplySanitizer.displayLine("Reply: \u{2067}שלום\u{2069} sent", maxLength: .max, fallback: fallback),
            "Reply: שלום sent"
        )
    }

    // MARK: - 4. Fallback

    func testInputOfNothingButControlScalarsYieldsTheFallback() {
        // Without this a hostile gateway posts a BLANK notification, which reads
        // to the user as a bug in Conduck rather than as a bad reply.
        XCTAssertEqual(
            ReplySanitizer.displayLine("\u{0000}\u{202E}\u{007F}\u{0085}\u{2066}", maxLength: 40, fallback: fallback),
            fallback
        )
    }

    func testEmptyAndWhitespaceOnlyInputYieldTheFallback() {
        XCTAssertEqual(ReplySanitizer.displayLine("", maxLength: 40, fallback: fallback), fallback)
        XCTAssertEqual(
            ReplySanitizer.displayLine("  \n\t \u{2029} ", maxLength: 40, fallback: fallback),
            fallback
        )
    }

    func testFallbackIsReturnedVerbatim() {
        // App-owned text: neither projected nor capped, so a caller's localized
        // string is never mangled by a cap meant for the reply.
        let longFallback = "A reply arrived, but it contained nothing displayable."
        XCTAssertEqual(
            ReplySanitizer.displayLine("\u{0000}", maxLength: 5, fallback: longFallback),
            longFallback
        )
    }

    // MARK: - 5. The canonical text is never rewritten

    func testProjectionLeavesTheCanonicalTextUntouched() {
        // The reply persisted for history and outbound replay must stay
        // byte-exact — the projection is derived, for one rendering.
        let canonical = "plan\u{202E}: ship\nit"
        let projected = ReplySanitizer.displayLine(canonical, maxLength: .max, fallback: fallback)

        XCTAssertEqual(canonical, "plan\u{202E}: ship\nit")
        XCTAssertEqual(projected, "plan: ship it")
        XCTAssertNotEqual(projected, canonical)
    }

    // MARK: - 6. Cost

    func testProjectionIsLinearOverAHostileReply() {
        // 250 000 clusters of the worst mix the projection has to classify: an
        // override, content, a whitespace run, a break, a deleted control. A
        // quadratic scan blows this bound by orders of magnitude; nothing else
        // can, which is why the bound is deliberately loose enough to survive a
        // slow machine.
        let poison = String(repeating: "\u{202E}a \n\u{0000}", count: 50_000)
        let elapsed = timing { _ = ReplySanitizer.displayLine(poison, maxLength: .max, fallback: fallback) }
        XCTAssertLessThan(
            elapsed, 2.0,
            "250 000 hostile clusters took \(elapsed)s — the projection is no longer one linear pass"
        )
    }

    func testLeadingControlFloodDoesNotStarveTheCap() {
        // Half a megabyte of removed scalars ahead of the only content there is:
        // the scan has to walk all of it (no input-position shortcut is correct)
        // and still return the text.
        let poison = String(repeating: "\u{0000}", count: 500_000) + "tail"
        let elapsed = timing {
            XCTAssertEqual(ReplySanitizer.displayLine(poison, maxLength: 10, fallback: fallback), "tail")
        }
        XCTAssertLessThan(elapsed, 2.0, "500 000 leading NULs took \(elapsed)s")
    }

    func testCappedCallStopsAtTheCapInsteadOfProjectingTheWholeReply() {
        // 4 MB of ordinary text with an 80-character cap. Projecting the whole
        // reply first and cutting afterwards costs a full pass plus a 4 MB
        // allocation — on the main actor, per view evaluation. Stopping at the
        // cap makes this microseconds; the bound is 3 orders of magnitude above
        // that and still far below the full pass.
        let long = String(repeating: "word ", count: 800_000)
        let elapsed = timing { _ = ReplySanitizer.displayLine(long, maxLength: 80, fallback: fallback) }
        XCTAssertLessThan(
            elapsed, 0.5,
            "a capped call over 4 MB took \(elapsed)s — it is projecting past the cap"
        )
    }

    // MARK: - 7. The speech strip drops the same class

    func testSpokenNoLongerEmitsControlOrBidiScalars() {
        let hostile = "Ship\u{0000} it\u{202E} now\u{009F}\u{2066} please\u{007F}"
        let out = ReplySanitizer.spoken(hostile)
        assertNoHostileScalars(out, "spoken")
        XCTAssertEqual(out, "Ship it now please")
    }

    func testSpokenStripsBidiHiddenInsideMarkdown() {
        // The strip runs BEFORE the Markdown passes, so a control scalar cannot
        // sit inside a construct and stop it from matching.
        XCTAssertEqual(ReplySanitizer.spoken("**bo\u{202E}ld**"), "bold")
        XCTAssertEqual(ReplySanitizer.spoken("`co\u{0000}de`"), "code")
    }

    func testSpokenKeepsTabsAndLineFeedsForPacing() {
        // `SpeechSegmenter` reads this line structure for sentence pacing, so
        // the speech strip must NOT flatten it the way `displayLine` does.
        XCTAssertEqual(ReplySanitizer.spoken("line one\nline two"), "line one\nline two")
        XCTAssertEqual(ReplySanitizer.spoken("a \t \t b"), "a \t \t b")
    }

    func testSpokenMapsParagraphSeparatorsToALineFeed() {
        // Deleting them would run two paragraphs together in the synthesizer.
        XCTAssertEqual(ReplySanitizer.spoken("first\u{2028}second"), "first\nsecond")
        XCTAssertEqual(ReplySanitizer.spoken("first\u{2029}second"), "first\nsecond")
    }

    func testSpokenLeavesRightToLeftScriptAlone() {
        let arabic = "مرحبا بالعالم"
        XCTAssertEqual(ReplySanitizer.spoken(arabic), arabic)
    }

    // MARK: - Helpers

    /// The house timing idiom (`ReplySanitizerLinkScannerTests`): wall clock
    /// around one call, compared against a bound loose enough to pin the
    /// ALGORITHM rather than the speed of the machine running it.
    private func timing(_ body: () -> Void) -> TimeInterval {
        let start = Date()
        body()
        return Date().timeIntervalSince(start)
    }
}
