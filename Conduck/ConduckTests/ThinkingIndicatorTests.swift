// SPDX-License-Identifier: Apache-2.0

// Conduck
// ThinkingIndicatorTests.swift
//
// Pure label resolver for the agent-side "thinking" row on every surface —
// the Watch list, the phone/Mac thread, and the menu-bar popover. The function
// never touches WatchKit / the recording service — it maps a plain phase +
// backend name to a label, so each case is a single call. The load-bearing
// case is the EMPTY-name fallback (Codex pitfall): a window where the bound
// gateway's name isn't resolved must read "Answering…", NEVER " is answering…".

import XCTest
@testable import Conduck

final class ThinkingIndicatorTests: XCTestCase {

    func testTranscribingIgnoresBackendName() {
        let expected = String(localized: "Transcribing…")
        XCTAssertEqual(ThinkingIndicator.label(phase: .transcribing, backendName: "OpenClaw"), expected)
        XCTAssertEqual(ThinkingIndicator.label(phase: .transcribing, backendName: ""), expected)
    }

    func testAnsweringLeadsWithBackendName() {
        let result = ThinkingIndicator.label(phase: .answering, backendName: "OpenClaw")
        XCTAssertEqual(result, String(localized: "\("OpenClaw") is answering…"))
        XCTAssertTrue(result.hasPrefix("OpenClaw"))
    }

    func testAnsweringEmptyNameFallsBackToBareAnswering() {
        let expected = String(localized: "Answering…")
        XCTAssertEqual(ThinkingIndicator.label(phase: .answering, backendName: ""), expected)
    }

    func testAnsweringWhitespaceNameFallsBackToBareAnswering() {
        // A whitespace-only name (transient list-cache state) trims to empty and
        // must NEVER render a leading-space " is answering…".
        let result = ThinkingIndicator.label(phase: .answering, backendName: "   ")
        XCTAssertEqual(result, String(localized: "Answering…"))
        XCTAssertFalse(result.hasPrefix(" "))
        XCTAssertFalse(result.contains(" is answering…") && result.hasPrefix(" "))
    }

    func testAnsweringTrimsSurroundingWhitespace() {
        let result = ThinkingIndicator.label(phase: .answering, backendName: "  Hermes  ")
        XCTAssertEqual(result, String(localized: "\("Hermes") is answering…"))
    }

    /// The pre-dispatch phase never names the gateway — nothing has been sent to
    /// it yet, so the copy must not imply it is working.
    func testSendingIgnoresBackendNameAndNeverClaimsAnswering() {
        let expected = String(localized: "Sending…")
        XCTAssertEqual(ThinkingIndicator.label(phase: .sending, backendName: "OpenClaw"), expected)
        XCTAssertEqual(ThinkingIndicator.label(phase: .sending, backendName: ""), expected)
        XCTAssertEqual(ThinkingIndicator.label(phase: .sending, backendName: "   "), expected)
        XCTAssertFalse(
            ThinkingIndicator.label(phase: .sending, backendName: "OpenClaw").contains("OpenClaw")
        )
    }

    /// The three phases must be visibly distinct — a surface that crossfades
    /// between them (the popover) would otherwise show no change.
    func testPhaseLabelsAreDistinct() {
        let labels = [
            ThinkingIndicator.label(phase: .transcribing, backendName: "OpenClaw"),
            ThinkingIndicator.label(phase: .sending, backendName: "OpenClaw"),
            ThinkingIndicator.label(phase: .answering, backendName: "OpenClaw")
        ]
        XCTAssertEqual(Set(labels).count, 3)
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
