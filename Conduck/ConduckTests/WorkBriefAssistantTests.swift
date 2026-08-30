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

    func testAvailabilityIsAClosedTwoStateContract() {
        switch WorkBriefAssistant.availability {
        case .available, .unavailable:
            break
        }
    }
}
