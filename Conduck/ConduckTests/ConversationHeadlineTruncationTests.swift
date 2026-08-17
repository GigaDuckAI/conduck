// SPDX-License-Identifier: Apache-2.0

// Conduck
// ConversationHeadlineTruncationTests.swift
//
// Pins the two ends of the conversation-headline projection that a row can get
// wrong without ever looking wrong: the FLOOR and the ELLIPSIS.
//
//   THE FLOOR. `MessageRowFormatters.conversationTitle` is a ladder — stored
//   title, then stored snippet, then the last-message preview, then a generic
//   placeholder. Every rung is projected, so every rung can come out EMPTY on the
//   exact input the projection exists for (a line of nothing but control and bidi
//   scalars). A rung that returns its empty projection instead of falling through
//   renders a BLANK headline, which reads as a broken row rather than as a bad
//   message, and a blank row is one the user cannot tap with confidence.
//
//   THE ELLIPSIS. Truncation is decided by projecting a fixed margin PAST the cap
//   and seeing whether more came back. The margin has to be wide enough to hold a
//   collapsed-whitespace separator AND the content character after it: the
//   projection spends a character of its budget on that separator and refuses to
//   end a line on one, so a one-character margin can be swallowed whole by a space
//   sitting exactly at the boundary. The capped line then comes back exactly at
//   the cap — indistinguishable from text that simply ended there — and the
//   ellipsis is dropped from a headline that really was cut. The failure is
//   silent and it lies: the row claims a complete sentence the user never sent.
//   A space at that boundary is ordinary text, and the projection COLLAPSES
//   whitespace runs into single spaces, which makes one there more likely.
//
// Both properties are checked on the render helper and on the stored-snippet
// writer, because they cap independently. Pure functions — no store, no signing,
// no platform import. Dropped into the synchronized `ConduckTests` group.

import XCTest
import Foundation
@testable import Conduck

@MainActor
final class ConversationHeadlineTruncationTests: XCTestCase {

    /// The ellipsis the truncating helpers append, resolved the same way they
    /// resolve it, so the assertions below pin the shape and not the glyph.
    private let ellipsis = "…"

    /// A line of nothing but formatting controls: an unterminated right-to-left
    /// override, a bare C0 control, and a left-to-right mark. It projects away to
    /// the empty string, which is the whole point — this is the input the
    /// projection was added for.
    private let allControlLine = "\u{202E}\u{0007}\u{200F}"

    // MARK: - The floor: no rung may render a blank headline

    func testAPreviewOfPureFormattingControlsFallsThroughToTheFloor() {
        let rendered = MessageRowFormatters.conversationTitle(
            title: nil,
            titleSnippet: nil,
            lastMessagePreview: allControlLine
        )

        XCTAssertEqual(rendered, String(localized: "New conversation"),
                       "A blank headline reads as a broken row, not as a bad message.")
    }

    func testAWhitespaceOnlyPreviewFallsThroughToTheFloor() {
        let rendered = MessageRowFormatters.conversationTitle(
            title: nil,
            titleSnippet: nil,
            lastMessagePreview: "   \u{00A0}\t  "
        )

        XCTAssertEqual(rendered, String(localized: "New conversation"))
    }

    /// The whole ladder collapsing at once: title, snippet AND preview each carry
    /// nothing renderable. Every rung falls through, none of them blank.
    func testEveryRungProjectingAwayStillLandsOnTheFloor() {
        let rendered = MessageRowFormatters.conversationTitle(
            title: allControlLine,
            titleSnippet: allControlLine,
            lastMessagePreview: allControlLine
        )

        XCTAssertEqual(rendered, String(localized: "New conversation"))
    }

    /// The floor must not swallow a preview that DOES carry content — the guard
    /// is a fall-through, not a replacement.
    func testARenderablePreviewStillWinsOverTheFloor() {
        let rendered = MessageRowFormatters.conversationTitle(
            title: nil,
            titleSnippet: nil,
            lastMessagePreview: "Kitchen renovation\nsecond line"
        )

        XCTAssertEqual(rendered, "Kitchen renovation")
    }

    // MARK: - The ellipsis: a cut at a whitespace boundary is still a cut

    /// The regression case. The character at the cap is a SPACE, so the old
    /// one-character probe came back exactly `maxHeadlineLength` long and the
    /// ellipsis went missing from a headline with a whole sentence still to go.
    func testAHeadlineCutAtAWhitespaceBoundaryKeepsItsEllipsis() {
        let cap = MessageRowFormatters.maxHeadlineLength
        let stored = String(repeating: "a", count: cap) + " and there is more after this"
        let rendered = MessageRowFormatters.conversationTitle(
            title: nil, titleSnippet: stored, lastMessagePreview: nil
        )

        XCTAssertTrue(rendered.hasSuffix(ellipsis),
                      "A space at the cap hides the cut from a one-character probe.")
        XCTAssertEqual(rendered.count, cap + 1, "Capped head plus the ellipsis, never more.")
        XCTAssertEqual(String(rendered.dropLast()), String(repeating: "a", count: cap))
    }

    /// Same boundary, reached through the PREVIEW rung, which caps by a different
    /// route (`firstLineFallback`) than the snippet rung above.
    func testAPreviewCutAtAWhitespaceBoundaryKeepsItsEllipsis() {
        let cap = MessageRowFormatters.maxHeadlineLength
        let preview = String(repeating: "b", count: cap) + " and the rest of the sentence"
        let rendered = MessageRowFormatters.firstLineFallback(from: preview)

        XCTAssertTrue(rendered.hasSuffix(ellipsis))
        XCTAssertEqual(rendered.count, cap + 1)
        XCTAssertFalse(String(rendered.dropLast()).hasSuffix(" "),
                       "The head never ends on a dangling separator.")
    }

    /// A cut at a non-whitespace boundary was always caught; it stays caught.
    func testAHeadlineCutMidWordKeepsItsEllipsis() {
        let cap = MessageRowFormatters.maxHeadlineLength
        let rendered = MessageRowFormatters.conversationTitle(
            title: nil,
            titleSnippet: String(repeating: "c", count: cap + 40),
            lastMessagePreview: nil
        )

        XCTAssertTrue(rendered.hasSuffix(ellipsis))
        XCTAssertEqual(rendered.count, cap + 1)
    }

    // MARK: - The ellipsis: nothing below the cap ever gets one

    func testAShortHeadlineGetsNoEllipsis() {
        let rendered = MessageRowFormatters.conversationTitle(
            title: nil, titleSnippet: "Kitchen renovation", lastMessagePreview: nil
        )

        XCTAssertEqual(rendered, "Kitchen renovation")
    }

    /// Exactly at the cap: nothing was dropped, so nothing may claim it was. The
    /// wider probe must not invent an ellipsis here.
    func testAHeadlineExactlyAtTheCapGetsNoEllipsis() {
        let cap = MessageRowFormatters.maxHeadlineLength
        let stored = String(repeating: "d", count: cap)
        let rendered = MessageRowFormatters.conversationTitle(
            title: nil, titleSnippet: stored, lastMessagePreview: nil
        )

        XCTAssertEqual(rendered, stored)
    }

    /// At the cap plus trailing whitespace only. The projection trims both ends,
    /// so nothing renderable was lost and the row must not suggest otherwise.
    func testAHeadlineAtTheCapWithTrailingWhitespaceGetsNoEllipsis() {
        let cap = MessageRowFormatters.maxHeadlineLength
        let stored = String(repeating: "e", count: cap) + "   \t "
        let rendered = MessageRowFormatters.conversationTitle(
            title: nil, titleSnippet: stored, lastMessagePreview: nil
        )

        XCTAssertEqual(rendered, String(repeating: "e", count: cap),
                       "Trimmed whitespace is not lost content.")
    }

    /// Trailing formatting controls are not lost content either — they project
    /// away to nothing on every surface, so the line ended at the cap.
    func testAHeadlineAtTheCapWithTrailingControlsGetsNoEllipsis() {
        let cap = MessageRowFormatters.maxHeadlineLength
        let stored = String(repeating: "f", count: cap) + allControlLine
        let rendered = MessageRowFormatters.conversationTitle(
            title: nil, titleSnippet: stored, lastMessagePreview: nil
        )

        XCTAssertEqual(rendered, String(repeating: "f", count: cap))
    }

    // MARK: - The stored snippet caps on its own budget

    func testAStoredSnippetCutAtAWhitespaceBoundaryKeepsItsEllipsis() throws {
        let cap = ConversationStore.titleSnippetMaxLength
        let text = String(repeating: "g", count: cap) + " and there is more after this"
        let snippet = try XCTUnwrap(ConversationStore.snippet(from: text))

        XCTAssertTrue(snippet.hasSuffix(ellipsis),
                      "A space at the cap hides the cut from a one-character probe.")
        XCTAssertEqual(snippet.count, cap + 1)
        XCTAssertEqual(String(snippet.dropLast()), String(repeating: "g", count: cap))
    }

    func testAStoredSnippetExactlyAtTheCapGetsNoEllipsis() throws {
        let cap = ConversationStore.titleSnippetMaxLength
        let text = String(repeating: "h", count: cap)
        let snippet = try XCTUnwrap(ConversationStore.snippet(from: text))

        XCTAssertEqual(snippet, text)
    }

    func testAStoredSnippetAtTheCapWithTrailingWhitespaceGetsNoEllipsis() throws {
        let cap = ConversationStore.titleSnippetMaxLength
        let text = String(repeating: "i", count: cap) + "    "
        let snippet = try XCTUnwrap(ConversationStore.snippet(from: text))

        XCTAssertEqual(snippet, String(repeating: "i", count: cap))
    }

    func testAShortStoredSnippetGetsNoEllipsis() throws {
        let snippet = try XCTUnwrap(ConversationStore.snippet(from: "Kitchen renovation"))

        XCTAssertEqual(snippet, "Kitchen renovation")
    }
}
