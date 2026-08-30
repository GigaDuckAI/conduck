// SPDX-License-Identifier: Apache-2.0

// ConduckTests
// WorkItemStateResolverTests.swift
//
// Pure lane contracts for the Workboard. These tests pin the honesty boundary:
// transport can produce Waiting or Review, while Done belongs only to a human.

import XCTest
@testable import Conduck

final class WorkItemStateResolverTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testNoDispatchAndPreparedSnapshotAreDraft() {
        XCTAssertEqual(WorkItemStateResolver.resolve(completedAt: nil, dispatches: []), .draft)
        XCTAssertEqual(
            WorkItemStateResolver.resolve(
                completedAt: nil,
                dispatches: [.init(occurredAt: now, activity: .prepared)]
            ),
            .draft
        )
    }

    func testOnlySendingIsWaiting() {
        XCTAssertEqual(
            WorkItemStateResolver.resolve(
                completedAt: nil,
                dispatches: [.init(occurredAt: now, activity: .waiting)]
            ),
            .waiting
        )
    }

    func testReplyAndSentBeforeReplySyncBothRequireReview() {
        let replyID = UUID()
        let userID = UUID()
        XCTAssertEqual(
            WorkItemStateResolver.resolve(
                completedAt: nil,
                dispatches: [.init(occurredAt: now, activity: .replied(messageID: replyID))]
            ),
            .review
        )
        XCTAssertEqual(
            WorkItemStateResolver.resolve(
                completedAt: nil,
                dispatches: [.init(
                    occurredAt: now,
                    activity: .replyPendingSync(userMessageID: userID)
                )]
            ),
            .review,
            "Message.status=sent is written only when a reply lands; a temporarily missing reply row must not read Waiting"
        )
    }

    func testAcknowledgedReplyReturnsOpenObjectiveToDraft() {
        let activity = WorkDispatchActivity.replied(messageID: UUID())
        XCTAssertEqual(
            WorkItemStateResolver.resolve(
                completedAt: nil,
                dispatches: [.init(
                    occurredAt: now,
                    activity: activity,
                    acknowledgedResultKey: activity.resultKey
                )]
            ),
            .draft
        )
    }

    func testFailureAcknowledgementIsAttemptScopedAndNewAttemptRearmsReview() {
        let messageID = UUID()
        let first = WorkDispatchActivity.failed(messageID: messageID, attemptID: UUID())
        let second = WorkDispatchActivity.failed(messageID: messageID, attemptID: UUID())
        XCTAssertEqual(
            WorkItemStateResolver.resolve(
                completedAt: nil,
                dispatches: [.init(
                    occurredAt: now,
                    activity: first,
                    acknowledgedResultKey: first.resultKey
                )]
            ),
            .draft
        )
        XCTAssertEqual(
            WorkItemStateResolver.resolve(
                completedAt: nil,
                dispatches: [.init(
                    occurredAt: now,
                    activity: second,
                    acknowledgedResultKey: first.resultKey
                )]
            ),
            .review
        )
    }

    func testUnidentifiedFailureFailsClosedInReview() {
        let activity = WorkDispatchActivity.failed(messageID: UUID(), attemptID: nil)
        XCTAssertNil(activity.resultKey)
        XCTAssertEqual(
            WorkItemStateResolver.resolve(
                completedAt: nil,
                dispatches: [.init(occurredAt: now, activity: activity)]
            ),
            .review
        )
    }

    func testOlderUnreviewedResultOutranksNewerWaitingRun() {
        XCTAssertEqual(
            WorkItemStateResolver.resolve(
                completedAt: nil,
                dispatches: [
                    .init(occurredAt: now, activity: .replied(messageID: UUID())),
                    .init(occurredAt: now.addingTimeInterval(5), activity: .waiting),
                ]
            ),
            .review
        )
    }

    func testHumanCompletionAlwaysOwnsDone() {
        XCTAssertEqual(
            WorkItemStateResolver.resolve(
                completedAt: now,
                dispatches: [.init(
                    occurredAt: now.addingTimeInterval(5),
                    activity: .replied(messageID: UUID())
                )]
            ),
            .done
        )
    }
}
