// SPDX-License-Identifier: Apache-2.0

// ConduckTests
// WorkBriefAssistantTests.swift
//
// Fail-closed Workboard shaping contracts that do not invoke a language model.

import XCTest
@testable import Conduck

final class WorkBriefAssistantTests: XCTestCase {
    func testEmptyTranscriptIsRefusedBeforeAvailabilityOrGeneration() async {
        do {
            _ = try await WorkBriefAssistant.shared.shape(transcript: " \n ")
            XCTFail("Expected an empty-transcript refusal")
        } catch let error as WorkBriefAssistantError {
            XCTAssertEqual(error, .emptyTranscript)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    /// Shaping never silently replaces what the person actually said, so the
    /// suggestion carries the transcript verbatim while every generated field is
    /// normalized to one line-break spelling first.
    func testNormalizationCollapsesEveryLineBreakSpellingAndTrims() {
        XCTAssertEqual(
            WorkBriefAssistant.normalized("  Compare couriers\r\nby price\rand coverage \n "),
            "Compare couriers\nby price\nand coverage"
        )
        XCTAssertEqual(WorkBriefAssistant.normalized("\r\n \r "), "")
        XCTAssertEqual(WorkBriefAssistant.normalized("Already clean"), "Already clean")
    }

    func testShapingFailsClosedWhereTheSystemModelIsUnavailable() async throws {
        try XCTSkipIf(
            WorkBriefAssistant.availability == .available,
            "Shaping on a capable host would invoke the real on-device model"
        )
        do {
            _ = try await WorkBriefAssistant.shared.shape(transcript: "Compare courier pricing")
            XCTFail("Expected a fail-closed refusal with no system model")
        } catch let error as WorkBriefAssistantError {
            XCTAssertEqual(error, .unavailable,
                           "manual drafting stays the complete path when shaping cannot run")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    /// The only exhaustiveness tripwire over `WorkBriefAssistantAvailability`:
    /// the sole consumer compares `== .available`, so a third case would compile
    /// and silently route people to the manual path.
    func testAvailabilityIsAClosedTwoStateContract() {
        let availability = WorkBriefAssistant.availability
        let isAvailable: Bool
        switch availability {
        case .available: isAvailable = true
        case .unavailable: isAvailable = false
        }
        XCTAssertEqual(isAvailable, availability == .available)
    }
}
