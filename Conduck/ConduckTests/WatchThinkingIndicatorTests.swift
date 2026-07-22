// Conduck
// WatchThinkingIndicatorTests.swift
//
// Pure label resolver for the Watch agent-side "thinking" row. The function
// never touches WatchKit / the recording service — it maps a plain phase +
// backend name to a label, so each case is a single call. The load-bearing
// case is the EMPTY-name fallback (Codex pitfall): a draft-adoption window
// where `threadBackendName` isn't resolved must read "Answering…", NEVER
// " is answering…".

import XCTest
@testable import Conduck

final class WatchThinkingIndicatorTests: XCTestCase {

    func testTranscribingIgnoresBackendName() {
        let expected = String(localized: "Transcribing…")
        XCTAssertEqual(WatchThinkingIndicator.label(phase: .transcribing, backendName: "OpenClaw"), expected)
        XCTAssertEqual(WatchThinkingIndicator.label(phase: .transcribing, backendName: ""), expected)
    }

    func testAnsweringLeadsWithBackendName() {
        let result = WatchThinkingIndicator.label(phase: .answering, backendName: "OpenClaw")
        XCTAssertEqual(result, String(localized: "\("OpenClaw") is answering…"))
        XCTAssertTrue(result.hasPrefix("OpenClaw"))
    }

    func testAnsweringEmptyNameFallsBackToBareAnswering() {
        let expected = String(localized: "Answering…")
        XCTAssertEqual(WatchThinkingIndicator.label(phase: .answering, backendName: ""), expected)
    }

    func testAnsweringWhitespaceNameFallsBackToBareAnswering() {
        // A whitespace-only name (transient list-cache state) trims to empty and
        // must NEVER render a leading-space " is answering…".
        let result = WatchThinkingIndicator.label(phase: .answering, backendName: "   ")
        XCTAssertEqual(result, String(localized: "Answering…"))
        XCTAssertFalse(result.hasPrefix(" "))
        XCTAssertFalse(result.contains(" is answering…") && result.hasPrefix(" "))
    }

    func testAnsweringTrimsSurroundingWhitespace() {
        let result = WatchThinkingIndicator.label(phase: .answering, backendName: "  Hermes  ")
        XCTAssertEqual(result, String(localized: "\("Hermes") is answering…"))
    }

    // ThinkingStage.clock (shared, also covered by ConversationThreadLogicTests)
    // — re-asserted here for the m:ss boundaries the indicator depends on.
    func testClockFormatting() {
        XCTAssertEqual(ThinkingStage.clock(0), "0:00")
        XCTAssertEqual(ThinkingStage.clock(9), "0:09")
        XCTAssertEqual(ThinkingStage.clock(65), "1:05")
        XCTAssertEqual(ThinkingStage.clock(600), "10:00")
    }
}
