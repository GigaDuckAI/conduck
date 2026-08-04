// SPDX-License-Identifier: Apache-2.0

// Conduck
// CloneUnansweredTrailingTurnTests.swift
//
// Locks `ConversationDetailViewModel.hasUnansweredTrailingTurn` — the predicate
// deciding whether the clone sheet asks "send the last message on <gateway>?"
// before cloning, or clones straight through.
//
// It exists as its own suite because it is a DUPLICATE of a rule that lives
// somewhere else: `ConversationStore.cloneConversation` independently decides
// whether to hand back a `continuationMessageID`, from the same two clauses
// against the same stored rows. Nothing at runtime forces the two to agree, and
// disagreement is silent in both directions:
//
//   - ask without a continuation  → "Send now" appears and does nothing
//   - continuation without an ask → the user is never offered a send that was
//     there for the taking, and the turn sits waiting with no explanation
//
// So the cases below are written against the STORE's rule, not the predicate's
// implementation: `role == "user"` and `status != "sent"`. The `sent` exclusion
// is the subtle one — that status is written only when a reply lands, so such a
// turn provably reached its gateway and a missing agent row means a lost or
// partially-synced reply, not an undelivered message.
//
// The companion end of the same contract is
// `ConversationStoreCloneTests.testCloneLeavesTrailingAgentTurnUnmarked` and
// `…NeverMarksADeliveredTrailingTurnFailed`.

import XCTest
@testable import Conduck

@MainActor
final class CloneUnansweredTrailingTurnTests: XCTestCase {

    private func vm(_ messages: [MessageRecord]) -> ConversationDetailViewModel {
        let model = ConversationDetailViewModel(conversationID: UUID())
        model.messages = messages
        return model
    }

    private func message(role: String, status: String?) -> MessageRecord {
        MessageRecord(
            id: UUID(),
            role: role,
            text: "please check those two files",
            createdAt: Date(timeIntervalSince1970: 1_000),
            sourceDevice: "mac",
            status: status,
            attachments: []
        )
    }

    func testAsksWhenTheThreadEndsOnAFailedUserTurn() {
        let model = vm([
            message(role: "user", status: "sent"),
            message(role: "agent", status: nil),
            message(role: "user", status: "failed")
        ])
        XCTAssertTrue(model.hasUnansweredTrailingTurn)
    }

    func testAsksWhenTheTrailingUserTurnIsStillSending() {
        // Not distinguished from `failed`: which of the two a person wants sent
        // on the new gateway depends on what they were doing, so both ask.
        XCTAssertTrue(vm([message(role: "user", status: "sending")]).hasUnansweredTrailingTurn)
    }

    func testAsksWhenTheTrailingUserTurnIsALegacyNilStatusRow() {
        // Pre-status-tracking rows carry nil. With no agent reply after one,
        // it is stranded — the same actionable state, and the store stamps it
        // `failed` in the clone for exactly that reason.
        XCTAssertTrue(vm([message(role: "user", status: nil)]).hasUnansweredTrailingTurn)
    }

    func testDoesNotAskWhenTheThreadEndsOnAnAgentReply() {
        let model = vm([
            message(role: "user", status: "sent"),
            message(role: "agent", status: nil)
        ])
        XCTAssertFalse(model.hasUnansweredTrailingTurn,
                       "Nothing is awaiting a send, so the question would have exactly one answer.")
    }

    func testDoesNotAskWhenTheTrailingUserTurnWasDelivered() {
        // `sent` is written only when a reply lands, so this turn reached its
        // gateway; a missing agent row is a lost reply. Offering to re-send it
        // would misdescribe what happened.
        XCTAssertFalse(vm([message(role: "user", status: "sent")]).hasUnansweredTrailingTurn)
    }

    func testDoesNotAskOnAnEmptyThread() {
        XCTAssertFalse(vm([]).hasUnansweredTrailingTurn)
    }
}
