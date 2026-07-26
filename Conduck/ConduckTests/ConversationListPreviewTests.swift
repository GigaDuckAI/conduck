// Conduck
// ConversationListPreviewTests.swift
//
// Covers `ConversationListView.previewText(forReply:)` — the sidebar subtitle
// derivation. One property is under test and it is an ORDERING property:
// Markdown links collapse BEFORE the string is cut to length.
//
// Why it is worth a test. The reply text is UNTRUSTED (a hostile gateway, or an
// honest agent that read a prompt-injecting web page), and the collapse exists
// because a link TARGET is the one construct that must not reach a glance
// surface: an agent's file link carries its host-side filesystem path, a web
// link carries a host the user never chose to see. Cut-then-collapse leaves a
// half-link — no closing `)`, so nothing collapses it — and the raw target
// lands in the sidebar. The defect is invisible to any fixture shorter than the
// cut, which is every hand-written example, so it is pinned here with fixtures
// built AROUND the boundary.
//
// Fixture URLs/paths are synthetic.

import XCTest
@testable import Conduck

@MainActor
final class ConversationListPreviewTests: XCTestCase {

    /// Long enough to push the link across the 500-character cut.
    private func padding(_ count: Int) -> String {
        String(repeating: "a", count: count)
    }

    // MARK: - The ordering property

    /// Assert the fixture actually reproduces the defect under the WRONG order,
    /// so a test that passes proves the ordering rather than the arithmetic. If
    /// a cut-first pass would not have exposed `leaked`, the fixture is padded
    /// wrong and the test below would pass vacuously.
    private func assertCutFirstWouldLeak(_ leaked: String, from reply: String,
                                         file: StaticString = #filePath, line: UInt = #line) {
        let cutFirst = ReplySanitizer.linkCollapsed(
            String(reply.prefix(ConversationListView.previewCharacterCount)))
        XCTAssertTrue(cutFirst.contains(leaked),
                      "Fixture is mis-padded: cut-then-collapse must strand \(leaked) for this test to mean anything.",
                      file: file, line: line)
    }

    /// A link that STRADDLES the cut must still collapse. Cut-first slices it
    /// mid-target — and a half-link has no closing `)`, so nothing collapses it
    /// afterwards — stranding the path in the sidebar.
    func testLinkStraddlingTheCutStillCollapses() {
        // Padded so the target is INSIDE the 500-character window while its
        // closing `)` falls outside it.
        let reply = padding(460) + " [poem.md](/Users/founder/Documents/poem.md) and more text after it."
        assertCutFirstWouldLeak("/Users/founder", from: reply)

        let preview = ConversationListView.previewText(forReply: reply)
        XCTAssertFalse(preview.contains("/Users/founder"),
                       "A truncation that splits a Markdown link leaks the host-side filesystem path into the always-visible sidebar.")
        XCTAssertFalse(preview.contains("]("),
                       "Raw Markdown link syntax must never survive into the preview.")
        XCTAssertTrue(preview.contains("poem.md"),
                      "The LABEL is what the preview is supposed to show.")
    }

    /// Same shape with a web link — the leaked token is a host rather than a
    /// path, and the collapse is the only thing keeping it out of the sidebar.
    func testWebLinkStraddlingTheCutStillCollapses() {
        let reply = padding(450) + " [the report](https://tracker.example.invalid/u/9f3ac1)"
        assertCutFirstWouldLeak("tracker.example.invalid", from: reply)

        let preview = ConversationListView.previewText(forReply: reply)
        XCTAssertFalse(preview.contains("tracker.example.invalid"),
                       "An untrusted host must not be rendered from a split link.")
        XCTAssertFalse(preview.contains("https://"),
                       "No raw target survives the collapse.")
    }

    /// A link WHOLLY past the cut contributes nothing either way — the cut is
    /// still applied, so the preview stays bounded.
    func testPreviewIsBoundedRegardlessOfReplyLength() {
        let reply = padding(50_000) + " [x](https://elsewhere.example.invalid)"
        let preview = ConversationListView.previewText(forReply: reply)

        XCTAssertEqual(preview.count, ConversationListView.previewCharacterCount,
                       "The cut bounds what `Text` lays out on the main actor, however long the reply is.")
        XCTAssertFalse(preview.contains("elsewhere.example.invalid"))
    }

    // MARK: - Ordinary replies are untouched

    func testShortPlainReplyPassesThroughVerbatim() {
        let reply = "Done — I renamed the file and re-ran the tests."
        XCTAssertEqual(ConversationListView.previewText(forReply: reply), reply)
    }

    func testEmptyReplyIsEmpty() {
        XCTAssertEqual(ConversationListView.previewText(forReply: ""), "")
    }

    /// Non-link Markdown is DELIBERATELY left verbatim — the preview collapses
    /// links only (the full strip is TTS-only), so this pins that the display
    /// variant did not quietly acquire the rest of the sanitizer.
    func testEmphasisAndCodeSpansSurvive() {
        let reply = "**bold** and `code` and _italics_"
        XCTAssertEqual(ConversationListView.previewText(forReply: reply), reply)
    }
}
