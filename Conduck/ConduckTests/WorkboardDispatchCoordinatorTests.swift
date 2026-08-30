// SPDX-License-Identifier: Apache-2.0

// ConduckTests
// WorkboardDispatchCoordinatorTests.swift
//
// Pure contracts at the Workboard's final send boundary. Network dispatch is
// exercised by the existing conversation transport suites; these tests lock
// the optimistic token and safe, content-free refusal copy.

import XCTest
@testable import Conduck

final class WorkboardDispatchCoordinatorTests: XCTestCase {
    func testReplyCorrelationUsesCanonicalIDTieBreakAndNextUserBoundary() throws {
        let timestamp = Date(timeIntervalSinceReferenceDate: 123)
        let workUserID = try XCTUnwrap(UUID(uuidString: "80000000-0000-0000-0000-000000000000"))
        let earlierAgentID = try XCTUnwrap(UUID(uuidString: "70000000-0000-0000-0000-000000000000"))
        let replyID = try XCTUnwrap(UUID(uuidString: "90000000-0000-0000-0000-000000000000"))
        let nextUserID = try XCTUnwrap(UUID(uuidString: "A0000000-0000-0000-0000-000000000000"))
        let laterAgentID = try XCTUnwrap(UUID(uuidString: "B0000000-0000-0000-0000-000000000000"))

        let messages = [
            WorkDispatchMessageFact(id: laterAgentID, role: "agent", createdAt: timestamp),
            WorkDispatchMessageFact(id: nextUserID, role: "user", createdAt: timestamp),
            WorkDispatchMessageFact(id: replyID, role: "agent", createdAt: timestamp),
            WorkDispatchMessageFact(id: earlierAgentID, role: "agent", createdAt: timestamp),
            WorkDispatchMessageFact(id: workUserID, role: "user", createdAt: timestamp),
        ]

        XCTAssertEqual(
            WorkDispatchReplyCorrelation.firstReplyID(
                workUserMessageID: workUserID,
                dispatchedAt: timestamp,
                messages: messages
            ),
            replyID,
            "an agent ordered before Work is ignored and the next user closes the reply window"
        )
    }

    func testRevisionDetectsSubMillisecondChanges() {
        let date = Date(timeIntervalSinceReferenceDate: 123.456_789)
        XCTAssertEqual(
            WorkboardRevision.value(for: date),
            Int64(bitPattern: date.timeIntervalSinceReferenceDate.bitPattern)
        )
        XCTAssertNotEqual(
            WorkboardRevision.value(for: date.addingTimeInterval(0.000_1)),
            WorkboardRevision.value(for: date)
        )
    }

    func testDispatchRefusalsDoNotEchoContentOrDestinations() {
        let errors: [WorkboardDispatchError] = [
            .itemChanged,
            .gatewayUnavailable,
            .materialChanged,
            .materialUnavailable,
            .fileServerRequired,
            .fileTransferFailed,
            .unsupportedMaterial,
            .previewMismatch,
            .alreadyStarted,
        ]
        for error in errors {
            let copy = error.localizedDescription
            XCTAssertFalse(copy.isEmpty)
            XCTAssertFalse(copy.contains("https://"))
            XCTAssertFalse(copy.contains("token"))
        }
    }
}
