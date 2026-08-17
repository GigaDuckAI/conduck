// SPDX-License-Identifier: Apache-2.0

// Conduck
// ConversationTitleProjectionTests.swift
//
// Locks the display projection on the PERSISTED conversation label — the one
// untrusted string that is stored, CloudKit-synced, and then drawn as a headline
// on four surfaces (the iOS/iPadOS/macOS list row, the Watch list + thread top
// bar, the CarPlay picker row, and the row's composed VoiceOver label).
//
// The label's source is the user's own first turn, which can arrive from a BYO
// speech-to-text endpoint, so it is content nobody in this app authored. Four
// properties are pinned here, and each is a real defect the moment it inverts:
//
//   1. THE PROJECTION HAPPENS AT THE READ, NOT ONLY AT THE WRITE. A title
//      already stored — synced in from another device, or written before the
//      projection existed — carries whatever it carries. Fixing only the write
//      path leaves that history spoofable on every device that renders it, which
//      is why the tests here drive stored records directly rather than only the
//      writer.
//   2. THE STORED VALUE IS NEVER REWRITTEN. This is a derived string for one
//      rendering. The canonical turn is what gets replayed to the agent, so
//      rewriting it would corrupt the conversation the user sends back.
//   3. TRUNCATION HAPPENS AFTER THE PROJECTION. Cutting first can land between a
//      bidi opener and its terminator and leave the opener governing everything
//      the row still shows — `testTheCapAppliesAfterTheProjectionNotBefore`
//      reproduces the wrong order beside the right one.
//   4. RIGHT-TO-LEFT SCRIPT IS UNTOUCHED. Arabic, Hebrew and Persian titles pass
//      through byte-for-byte. Confusing "explicit bidi FORMATTING control" with
//      "text that runs right to left" would render those languages as mojibake
//      on a surface no English-reading tester would look twice at.
//
// Pure functions plus one in-memory store — no signing, no platform import.
// Dropped into the synchronized `ConduckTests` group → auto-included.

import XCTest
import Foundation
@testable import Conduck

@MainActor
final class ConversationTitleProjectionTests: XCTestCase {

    // MARK: - Fixtures

    private let noon = Date(timeIntervalSince1970: 1_760_000_000)

    /// A stored snippet carrying an UNTERMINATED right-to-left override plus a
    /// bare C0 control — the classic label spoof: everything after the override
    /// renders in reverse, so the row reads as a sentence the user never sent.
    private let spoofedSnippet = "Order confirmed\u{202E}\u{0007} refund denied"

    /// What `spoofedSnippet` must look like once projected: the two hostile
    /// scalars gone, the words either side of them still separate.
    private let spoofedSnippetProjected = "Order confirmed refund denied"

    /// Independent restatement of the scalars that must never reach a rendered
    /// label — deliberately NOT a call into `ReplySanitizer`, since a denylist
    /// that tests itself proves nothing. C0 (minus TAB / LF / CR, which the
    /// projection maps to a space rather than deleting), DEL, C1, and the bidi
    /// mark / embedding / override / isolate families.
    private func isHostileScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x00...0x08, 0x0B, 0x0C, 0x0E...0x1F, 0x7F, 0x80...0x9F:
            return true
        case 0x200E, 0x200F, 0x202A...0x202E, 0x2066...0x2069:
            return true
        default:
            return false
        }
    }

    private func assertNoHostileScalar(
        in text: String,
        _ message: String = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let offender = text.unicodeScalars.first(where: isHostileScalar)
        XCTAssertNil(
            offender.map { String(format: "U+%04X", $0.value) },
            message.isEmpty ? "A rendered label must carry no formatting control." : message,
            file: file, line: line
        )
    }

    /// A conversation as it materializes out of the store — the shape a row
    /// already synced from another device arrives in.
    private func storedRecord(titleSnippet: String?, title: String? = nil) -> ConversationRecord {
        ConversationRecord(
            id: UUID(),
            title: title,
            createdAt: noon,
            lastActivityAt: noon,
            sessionID: UUID().uuidString,
            backend: "openclaw",
            titleSnippet: titleSnippet
        )
    }

    private func headline(for record: ConversationRecord) -> String {
        MessageRowFormatters.conversationTitle(
            title: record.title,
            titleSnippet: record.titleSnippet,
            lastMessagePreview: nil
        )
    }

    // MARK: - Property 1 — the read boundary answers already-stored titles

    func testStoredSnippetWithBidiOverridesRendersACleanListHeadline() {
        let record = storedRecord(titleSnippet: spoofedSnippet)
        let rendered = headline(for: record)

        XCTAssertEqual(rendered, spoofedSnippetProjected)
        assertNoHostileScalar(in: rendered)
    }

    func testStoredSnippetWithBidiOverridesRendersACleanWatchTitle() {
        let record = storedRecord(titleSnippet: spoofedSnippet)

        XCTAssertEqual(record.displayTitle, spoofedSnippetProjected)
        assertNoHostileScalar(in: record.displayTitle)
    }

    /// The gateway-supplied `title` rung takes the same projection, and a rung
    /// that projects away to nothing must fall THROUGH rather than short-circuit
    /// the ladder at the generic placeholder.
    func testATitleOfPureFormattingControlsFallsThroughToTheSnippet() {
        let record = storedRecord(titleSnippet: "Kitchen renovation", title: "\u{202E}\u{2066}\u{0007}")

        XCTAssertEqual(headline(for: record), "Kitchen renovation")
        XCTAssertEqual(record.displayTitle, "Kitchen renovation")
    }

    func testASnippetOfPureFormattingControlsFallsThroughToThePreview() {
        let record = storedRecord(titleSnippet: "\u{202E}\u{200F}")
        let rendered = MessageRowFormatters.conversationTitle(
            title: record.title,
            titleSnippet: record.titleSnippet,
            lastMessagePreview: "First line\nsecond line"
        )

        XCTAssertEqual(rendered, "First line")
        XCTAssertEqual(record.displayTitle, String(localized: "New conversation"),
                       "With no preview to fall through to, the Watch ladder lands on its floor.")
    }

    // MARK: - Property 2 — storage stays canonical

    func testRenderingDoesNotRewriteTheStoredSnippet() {
        let record = storedRecord(titleSnippet: spoofedSnippet)
        _ = headline(for: record)
        _ = record.displayTitle

        XCTAssertEqual(record.titleSnippet, spoofedSnippet,
                       "The projection is derived for ONE rendering; storage is left byte-exact.")
        XCTAssertTrue(
            (record.titleSnippet ?? "").unicodeScalars.contains(where: isHostileScalar),
            "If the fixture stopped carrying a hostile scalar this whole suite would pass vacuously."
        )
    }

    /// The canonical turn is what gets replayed to the agent, so only the DERIVED
    /// label may be projected. Drives the real writer end to end.
    func testAppendingAHostileTurnLeavesTheMessageTextByteExact() async throws {
        let store = ConversationStore(inMemory: true)
        let convo = try await store.createConversation(backend: "openclaw")
        _ = try await store.appendMessage(
            role: "user",
            text: spoofedSnippet,
            conversationID: convo.id,
            sourceDevice: "phone"
        )

        let messages = try await store.fetchMessages(for: convo.id)
        XCTAssertEqual(messages.first?.text, spoofedSnippet,
                       "The stored turn is replayed to the agent verbatim; only the label is projected.")

        let fetched = try await store.fetchConversation(id: convo.id)
        let refreshed = try XCTUnwrap(fetched)
        XCTAssertEqual(headline(for: refreshed), spoofedSnippetProjected)
        assertNoHostileScalar(in: headline(for: refreshed))
    }

    // MARK: - Property 3 — cap after projection

    /// 100 overrides in FRONT of the words: a naive `prefix(cap)` spends the
    /// whole budget on scalars that render as nothing and shows a blank row still
    /// governed by an override. The projection spends it on characters.
    func testTheCapAppliesAfterTheProjectionNotBefore() {
        let stored = String(repeating: "\u{202E}", count: 100) + "Kitchen renovation"
        let record = storedRecord(titleSnippet: stored)

        XCTAssertEqual(headline(for: record), "Kitchen renovation")

        let naive = String(stored.prefix(MessageRowFormatters.maxHeadlineLength))
        XCTAssertTrue(naive.unicodeScalars.contains(where: isHostileScalar),
                      "The WRONG order, shown for contrast: cutting first keeps the opener.")
    }

    func testALongHostileSnippetIsProjectedThenCappedWithAnEllipsis() {
        let stored = String(repeating: "a\u{202E}", count: 200)
        let rendered = headline(for: storedRecord(titleSnippet: stored))

        assertNoHostileScalar(in: rendered)
        XCTAssertTrue(rendered.hasSuffix("…"))
        XCTAssertEqual(rendered.count, MessageRowFormatters.maxHeadlineLength + 1,
                       "Capped head plus the ellipsis, never more.")
    }

    func testTheStoredSnippetWriterProjectsBeforeItTruncates() throws {
        let snippet = try XCTUnwrap(ConversationStore.snippet(from: spoofedSnippet))
        XCTAssertEqual(snippet, spoofedSnippetProjected)
        assertNoHostileScalar(in: snippet)

        let padded = String(repeating: "\u{202E}", count: 200)
            + String(repeating: "c", count: 100)
        let capped = try XCTUnwrap(ConversationStore.snippet(from: padded))
        assertNoHostileScalar(in: capped)
        XCTAssertTrue(capped.hasSuffix("…"))
        XCTAssertEqual(capped.count, ConversationStore.titleSnippetMaxLength + 1)
    }

    /// A turn that is nothing but formatting controls writes NO snippet, so a
    /// later text turn can still fill it — the same contract an attachment-only
    /// turn already has.
    func testATurnOfPureFormattingControlsWritesNoSnippet() {
        XCTAssertNil(ConversationStore.snippet(from: "\u{202E}\u{0007}\u{200F}"))
    }

    // MARK: - Property 4 — RTL script is not a formatting control

    func testRightToLeftTitlesSurviveIntact() {
        for stored in ["مرحبا بالعالم", "שלום עולם", "سلام دنیا"] {
            let record = storedRecord(titleSnippet: stored)
            XCTAssertEqual(headline(for: record), stored, "Arabic/Hebrew/Persian content is not a control.")
            XCTAssertEqual(record.displayTitle, stored)
            XCTAssertEqual(
                CarPlayConversationLabel.derive(title: nil, firstUserTurnText: stored),
                stored
            )
            XCTAssertEqual(ConversationStore.snippet(from: stored), stored)
        }
    }

    // MARK: - The composed VoiceOver label

    /// The JOIN is the risk: untrusted title, gateway name and subtitle end up in
    /// ONE string beside trusted status copy, and after the join there is no
    /// boundary left at which a spoofed reordering could be separated out.
    func testComposedAccessibilityLabelProjectsEveryUntrustedComponent() {
        let label = MessageRowFormatters.rowAccessibilityLabel(
            state: ConversationRowState(activity: .answeredUnseen, hasUnseenReply: true),
            title: spoofedSnippet,
            subtitle: "You: \u{202E}cancel the order",
            gatewayName: "Open\u{200F}Claw",
            lastActivityAt: noon,
            showsGateway: true,
            now: noon
        )

        assertNoHostileScalar(in: label)
        XCTAssertTrue(
            label.hasPrefix(String(localized: "activity.a11y.newReply", defaultValue: "New reply")),
            "State still leads — projecting a component must not reorder the label."
        )
        XCTAssertTrue(label.contains(spoofedSnippetProjected))
        XCTAssertTrue(label.contains("OpenClaw"),
                      "A deletion must not invent a word boundary the sender never sent.")
        XCTAssertTrue(label.contains("You: cancel the order"))
    }

    func testTheSubtitleItselfIsProjected() throws {
        let subtitle = try XCTUnwrap(MessageRowFormatters.conversationSubtitle(
            text: "The permit\u{202E}\u{0007} is approved.", role: .agent
        ))

        XCTAssertEqual(subtitle, "The permit is approved.")
        assertNoHostileScalar(in: subtitle)
    }

    func testASubtitleOfPureFormattingControlsShowsNoLine() {
        XCTAssertNil(MessageRowFormatters.conversationSubtitle(text: "\u{202E}\u{0007}", role: .user),
                     "A bare 'You:' with nothing after it is worse than no line.")
    }

    // MARK: - CarPlay picker row

    func testCarPlayRowTitleIsProjected() {
        let label = CarPlayConversationLabel.derive(
            title: nil, firstUserTurnText: spoofedSnippet
        )

        XCTAssertEqual(label, spoofedSnippetProjected)
        assertNoHostileScalar(in: label)
    }

    func testCarPlayRowTitleCapsAfterProjecting() {
        let raw = String(repeating: "\u{202E}", count: 200)
            + String(repeating: "b", count: 100)
        let label = CarPlayConversationLabel.derive(title: nil, firstUserTurnText: raw)

        assertNoHostileScalar(in: label)
        XCTAssertTrue(label.hasSuffix("…"))
        XCTAssertEqual(label.count, CarPlayConversationLabel.maxSnippetLength + 1)
    }

    func testCarPlayRowOfPureFormattingControlsFallsBackToTheFloor() {
        let label = CarPlayConversationLabel.derive(
            title: nil, firstUserTurnText: "\u{202E}\u{0007}\u{200F}"
        )

        XCTAssertEqual(label, String(localized: "New conversation"),
                       "A blank CarPlay row is a row the driver cannot tap with confidence.")
    }
}
