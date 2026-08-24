// SPDX-License-Identifier: Apache-2.0

// Conduck
// ConversationThreadLogicTests.swift
//
// Unit coverage for the pure logic introduced by the iPhone/iPad chat
// surface: the staged "thinking" selector (by elapsed seconds), the
// conversation title-fallback formatter, and the store-record → wire-message
// mapper (`ConverseRequest.priorTurns`, incl. the new-user-turn de-dup and
// the agent → assistant role mapping).

import XCTest
@testable import Conduck

final class ConversationThreadLogicTests: XCTestCase {

    // MARK: - In-flight elapsed clock
    //
    // The staged "thinking" selector (`.connecting` / `.sendingContext` /
    // `.thinking`) was retired with the borderless in-flight indicator
    // redesign — the indicator now shows "{Backend} is answering…" plus a
    // subtle elapsed clock. Only `ThinkingStage.clock(_:)` remains; its
    // coverage is below.

    func testThinkingStage_clockFormatting() {
        XCTAssertEqual(ThinkingStage.clock(0), "0:00")
        XCTAssertEqual(ThinkingStage.clock(9), "0:09")
        XCTAssertEqual(ThinkingStage.clock(65), "1:05")
        XCTAssertEqual(ThinkingStage.clock(125), "2:05")
        XCTAssertEqual(ThinkingStage.clock(600), "10:00")
    }

    // MARK: - Conversation title fallback

    func testConversationTitle_usesStoredTitleWhenPresent() {
        let title = MessageRowFormatters.conversationTitle(
            title: "Trip planning",
            titleSnippet: "snippet ignored",
            lastMessagePreview: "ignore me"
        )
        XCTAssertEqual(title, "Trip planning")
    }

    func testConversationTitle_usesTitleSnippetWhenTitleNil() {
        // titleSnippet outranks the lastMessagePreview fallback.
        let title = MessageRowFormatters.conversationTitle(
            title: nil,
            titleSnippet: "Buy oat milk",
            lastMessagePreview: "some later agent reply"
        )
        XCTAssertEqual(title, "Buy oat milk")
    }

    func testConversationTitle_blankSnippetFallsThroughToPreview() {
        let title = MessageRowFormatters.conversationTitle(
            title: nil,
            titleSnippet: "   ",
            lastMessagePreview: "First line\nsecond line"
        )
        XCTAssertEqual(title, "First line")
    }

    func testConversationTitle_fallsBackToFirstLineOfPreview() {
        let title = MessageRowFormatters.conversationTitle(
            title: nil,
            titleSnippet: nil,
            lastMessagePreview: "First line\nsecond line"
        )
        XCTAssertEqual(title, "First line")
    }

    func testConversationTitle_blankTitleFallsBackToPreview() {
        let title = MessageRowFormatters.conversationTitle(
            title: "   ",
            titleSnippet: nil,
            lastMessagePreview: "Hello there"
        )
        XCTAssertEqual(title, "Hello there")
    }

    func testConversationTitle_truncatesLongPreview() {
        let long = String(repeating: "a", count: 200)
        let title = MessageRowFormatters.conversationTitle(
            title: nil, titleSnippet: nil, lastMessagePreview: long
        )
        // 80-char head + ellipsis.
        XCTAssertTrue(title.hasSuffix("…"))
        XCTAssertEqual(title.count, 81)
    }

    func testConversationTitle_noTitleNoPreviewFallsBackToPlaceholder() {
        let title = MessageRowFormatters.conversationTitle(
            title: nil, titleSnippet: nil, lastMessagePreview: nil
        )
        XCTAssertEqual(title, String(localized: "New conversation"))
    }

    // MARK: - Source-device chip carplay case

    func testDeviceIcon_carplayCaseAdded() {
        XCTAssertEqual(MessageRowFormatters.icon(forDevice: "carplay"), "car")
        XCTAssertEqual(MessageRowFormatters.label(forDevice: "carplay"), String(localized: "CarPlay"))
    }

    // MARK: - ConverseRequest.priorTurns

    private func record(role: String, text: String, at offset: TimeInterval = 0) -> MessageRecord {
        MessageRecord(
            id: UUID(),
            role: role,
            text: text,
            createdAt: Date().addingTimeInterval(offset),
            sourceDevice: "iphone"
        )
    }

    func testPriorTurns_mapsAgentRoleToAssistant() {
        let records = [
            record(role: "user", text: "hi", at: 0),
            record(role: "agent", text: "hello", at: 1),
        ]
        let turns = ConverseRequest.priorTurns(from: records).turns
        XCTAssertEqual(turns.count, 2)
        XCTAssertEqual(turns[0].role, "user")
        XCTAssertEqual(turns[1].role, "assistant")
        XCTAssertEqual(turns[1].content, "hello")
    }

    func testPriorTurns_dropsTrailingMatchingNewUserTurn() {
        let records = [
            record(role: "user", text: "old", at: 0),
            record(role: "agent", text: "reply", at: 1),
            record(role: "user", text: "new turn", at: 2),
        ]
        let turns = ConverseRequest.priorTurns(from: records, excludingNewUserText: "new turn").turns
        // The just-appended trailing user turn is removed (the assembler
        // re-appends it) — leaving the prior user + agent turns.
        XCTAssertEqual(turns.count, 2)
        XCTAssertEqual(turns.last?.role, "assistant")
    }

    func testPriorTurns_keepsTrailingUserWhenTextDiffers() {
        let records = [
            record(role: "user", text: "something else", at: 0),
        ]
        let turns = ConverseRequest.priorTurns(from: records, excludingNewUserText: "new turn").turns
        XCTAssertEqual(turns.count, 1)
        XCTAssertEqual(turns[0].content, "something else")
    }

    func testPriorTurns_noExclusionPreservesAll() {
        let records = [
            record(role: "user", text: "a", at: 0),
            record(role: "agent", text: "b", at: 1),
        ]
        let turns = ConverseRequest.priorTurns(from: records).turns
        XCTAssertEqual(turns.count, 2)
    }

    // MARK: - Modality tagging (sourceDevice suffix encode/decode)

    func testBaseDevice_stripsModalitySuffix() {
        XCTAssertEqual(MessageRowFormatters.baseDevice(from: "iphone-text"), "iphone")
        XCTAssertEqual(MessageRowFormatters.baseDevice(from: "ipad-voice"), "ipad")
        XCTAssertEqual(MessageRowFormatters.baseDevice(from: "mac-text"), "mac")
    }

    func testBaseDevice_passesThroughLegacyUnsuffixedTags() {
        // Pre-composer rows + voice-only surfaces (Watch/CarPlay) store a bare device.
        XCTAssertEqual(MessageRowFormatters.baseDevice(from: "iphone"), "iphone")
        XCTAssertEqual(MessageRowFormatters.baseDevice(from: "carplay"), "carplay")
        XCTAssertEqual(MessageRowFormatters.baseDevice(from: "watch"), "watch")
    }

    func testBaseDevice_edgeCases() {
        XCTAssertEqual(MessageRowFormatters.baseDevice(from: ""), "")
        XCTAssertEqual(MessageRowFormatters.baseDevice(from: "-text"), "")             // leading dash → empty base
        XCTAssertEqual(MessageRowFormatters.baseDevice(from: "iphone-text-x"), "iphone")  // split on FIRST dash only
    }

    func testModalityIcon_mapsKnownSuffixes() {
        XCTAssertEqual(MessageRowFormatters.modalityIcon(from: "iphone-voice"), "waveform")
        XCTAssertEqual(MessageRowFormatters.modalityIcon(from: "iphone-text"), "keyboard")
        XCTAssertEqual(MessageRowFormatters.modalityIcon(from: "carplay-voice"), "waveform")
    }

    func testModalityIcon_nilForLegacyAndUnknown() {
        XCTAssertNil(MessageRowFormatters.modalityIcon(from: "iphone"))        // legacy unsuffixed
        XCTAssertNil(MessageRowFormatters.modalityIcon(from: "iphone-photo"))  // unknown suffix
        XCTAssertNil(MessageRowFormatters.modalityIcon(from: ""))
        XCTAssertNil(MessageRowFormatters.modalityIcon(from: "iphone-"))       // empty suffix
    }

    func testModality_encodeDecodeCoherence() {
        // LOAD-BEARING: TurnModality.rawValue IS the wire suffix that modalityIcon
        // switches on + that baseDevice strips. Renaming a case silently breaks the
        // glyph and legacy back-compat. Pin the encode↔decode contract.
        XCTAssertEqual(TurnModality.voice.rawValue, "voice")
        XCTAssertEqual(TurnModality.text.rawValue, "text")

        for (modality, expectedGlyph) in [(TurnModality.voice, "waveform"), (TurnModality.text, "keyboard")] {
            // Mirrors ConversationDetailViewModel.sendUserTurn: "<device>-<modality>".
            let stamped = "iphone-\(modality.rawValue)"
            XCTAssertEqual(MessageRowFormatters.baseDevice(from: stamped), "iphone")
            XCTAssertEqual(MessageRowFormatters.modalityIcon(from: stamped), expectedGlyph)
        }
    }

    // MARK: - conversationListDate (calendar-bucketed sidebar timestamp)
    //
    // Routing is the logic under test (today → time, yesterday → "Yesterday",
    // older → absolute date with/without year); the formatting itself is
    // Foundation's. `now` is injected so the buckets are deterministic, and the
    // expected outputs are built from formatters identical to the
    // implementation's so the assertions stay locale-robust.

    private func fixedDate(_ y: Int, _ mo: Int, _ d: Int, _ h: Int = 12, _ mi: Int = 0) -> Date {
        var c = DateComponents()
        c.year = y; c.month = mo; c.day = d; c.hour = h; c.minute = mi
        return Calendar.current.date(from: c)!
    }

    private func template(_ t: String) -> DateFormatter {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate(t)
        return f
    }

    func testConversationListDate_todayShowsTimeOfDay() {
        let now = fixedDate(2026, 5, 30, 15, 0)
        let today = fixedDate(2026, 5, 30, 10, 14)
        XCTAssertEqual(
            MessageRowFormatters.conversationListDate(from: today, now: now),
            template("jmm").string(from: today)
        )
    }

    func testConversationListDate_yesterdayShowsLabel() {
        let now = fixedDate(2026, 5, 30, 15, 0)
        let yesterday = fixedDate(2026, 5, 29, 9, 0)
        XCTAssertEqual(
            MessageRowFormatters.conversationListDate(from: yesterday, now: now),
            String(localized: "Yesterday")
        )
    }

    func testConversationListDate_twoDaysAgoIsNotYesterday() {
        let now = fixedDate(2026, 5, 30, 15, 0)
        let twoDaysAgo = fixedDate(2026, 5, 28, 9, 0)
        XCTAssertNotEqual(
            MessageRowFormatters.conversationListDate(from: twoDaysAgo, now: now),
            String(localized: "Yesterday")
        )
    }

    func testConversationListDate_olderSameYearShowsDayMonth() {
        let now = fixedDate(2026, 5, 30, 15, 0)
        let older = fixedDate(2026, 4, 12, 9, 0)
        XCTAssertEqual(
            MessageRowFormatters.conversationListDate(from: older, now: now),
            template("MMMd").string(from: older)
        )
    }

    func testConversationListDate_olderDifferentYearIncludesYear() {
        let now = fixedDate(2026, 5, 30, 15, 0)
        let older = fixedDate(2025, 4, 12, 9, 0)
        let result = MessageRowFormatters.conversationListDate(from: older, now: now)
        XCTAssertEqual(result, template("MMMdyyyy").string(from: older))
        XCTAssertTrue(result.contains("2025"))
    }
}
