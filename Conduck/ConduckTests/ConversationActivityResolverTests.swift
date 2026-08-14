// SPDX-License-Identifier: Apache-2.0

// Conduck
// ConversationActivityResolverTests.swift
//
// Locks the conversation-row state machine:
//   • DELIVERY comes from the unresolved-turn aggregate, and the NEWEST
//     unresolved turn wins — a fresh send after an old failure is WORKING, not
//     red;
//   • a `failed` turn is terminal and nothing ever clears it, so it is bounded
//     TWICE — reported only while it is still the conversation's last activity
//     (otherwise one offline send paints a row red for the life of the install
//     AND blocks its amber disc forever), and marked only until the user has
//     seen it;
//   • acknowledgement comes from its OWN marker and never leaks onto a row that
//     is not reporting the failure;
//   • ATTENTION is orthogonal to delivery, so `failed + unseen` and
//     `working + unseen` both stay representable;
//   • a surface that did not project a tail role (`nil`) can never produce an
//     unseen dot, and neither can a surface with no read state.
//
// Pure value math — no store, no SwiftUI, no clock (every case injects `now`).

import XCTest
@testable import Conduck

@MainActor
final class ConversationActivityResolverTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    /// `sending` / `failed` are seconds AGO. `lastActivityAt` defaults to the
    /// NEWEST supplied unresolved stamp (falling back to `now` when there is
    /// none), because that is what the store actually holds: an append writes
    /// `Message.createdAt` and `Conversation.lastActivityAt` from one `now`, so
    /// an unresolved turn that is the conversation's tail carries the same
    /// stamp in both places. A case that wants a LATER message on top of the
    /// unresolved turn passes `lastActivityAt` explicitly.
    private func inputs(
        lastActivityAt: Date? = nil,
        sending: TimeInterval? = nil,
        failed: TimeInterval? = nil,
        tailRole: MessageRole? = nil
    ) -> ConversationActivityInputs {
        let sendingAt = sending.map { now.addingTimeInterval(-$0) }
        let failedAt = failed.map { now.addingTimeInterval(-$0) }
        let tailStamp = [sendingAt, failedAt].compactMap { $0 }.max()
        return ConversationActivityInputs(
            lastActivityAt: lastActivityAt ?? tailStamp ?? now,
            newestSendingAt: sendingAt,
            newestFailedAt: failedAt,
            tailRole: tailRole
        )
    }

    /// `failureSeenAt` defaults to nil — the pre-acknowledgement contract, and
    /// the one watchOS and CarPlay pass — so every case that is not ABOUT
    /// acknowledgement reads exactly as it did before it existed.
    private func resolve(
        _ inputs: ConversationActivityInputs,
        locallyLiveSince: Date? = nil,
        lastViewedAt: Date? = nil,
        failureSeenAt: Date? = nil
    ) -> ConversationRowState {
        ConversationActivityResolver.resolve(
            inputs,
            locallyLiveSince: locallyLiveSince,
            lastViewedAt: lastViewedAt,
            failureSeenAt: failureSeenAt,
            now: now
        )
    }

    /// Seconds AGO, matching `inputs`' convention for `sending` / `failed`.
    private func ago(_ seconds: TimeInterval) -> Date {
        now.addingTimeInterval(-seconds)
    }

    // MARK: - MessageRole

    func testMessageRoleParsesTheTwoStoredValues() {
        XCTAssertEqual(MessageRole(stored: "user"), .user)
        XCTAssertEqual(MessageRole(stored: "agent"), .agent)
    }

    func testMessageRoleIsNilForUnknownAndMissingValues() {
        XCTAssertNil(MessageRole(stored: nil))
        XCTAssertNil(MessageRole(stored: ""))
        XCTAssertNil(MessageRole(stored: "system"))
        XCTAssertNil(MessageRole(stored: "User"))
    }

    // MARK: - Delivery

    func testStoredSendingWithoutALocalClaimHedgesInsideTheGrace() {
        let state = resolve(inputs(sending: 29 * 60))
        XCTAssertEqual(
            state.activity,
            .working(.hedged, since: now.addingTimeInterval(-29 * 60))
        )
    }

    func testStoredSendingGoesStalePastTheGrace() {
        let state = resolve(inputs(sending: 31 * 60))
        XCTAssertEqual(
            state.activity,
            .working(.stale, since: now.addingTimeInterval(-31 * 60))
        )
    }

    func testGraceBoundaryIsInclusive() {
        let state = resolve(inputs(sending: ConversationActivityResolver.staleSendingGrace))
        guard case .working(let confidence, _) = state.activity else {
            return XCTFail("expected working, got \(state.activity)")
        }
        XCTAssertEqual(confidence, .hedged)
    }

    func testALocalClaimUpgradesSendingToLiveAndCountsFromTheClaim() {
        let claim = now.addingTimeInterval(-42)
        let state = resolve(inputs(sending: 29 * 60), locallyLiveSince: claim)
        XCTAssertEqual(state.activity, .working(.live, since: claim))
    }

    func testALocalClaimWithNoStoredSendingIsStillWorkingLive() {
        // The lanes that claim BEFORE the durable row is visible to a list
        // snapshot: the CarPlay upload, the share drainer, a raced reload.
        let claim = now.addingTimeInterval(-3)
        let state = resolve(inputs(), locallyLiveSince: claim)
        XCTAssertEqual(state.activity, .working(.live, since: claim))
    }

    func testFailedOnlyIsFailed() {
        XCTAssertEqual(resolve(inputs(failed: 120)).activity, .failed)
    }

    func testFailedPlusNewerSendingIsWorkingNotFailed() {
        // The re-send case. Rendering red here would be a lie the moment the
        // user re-sends.
        let state = resolve(inputs(sending: 30, failed: 600))
        XCTAssertEqual(
            state.activity,
            .working(.hedged, since: now.addingTimeInterval(-30))
        )
    }

    func testFailedPlusOlderSendingIsFailed() {
        XCTAssertEqual(resolve(inputs(sending: 600, failed: 30)).activity, .failed)
    }

    func testNoUnresolvedTurnAndNoClaimIsIdle() {
        XCTAssertEqual(resolve(inputs()).activity, .idle)
    }

    // MARK: - Attention

    func testAgentTailNewerThanTheMarkerIsUnseen() {
        let state = resolve(
            inputs(lastActivityAt: now, tailRole: .agent),
            lastViewedAt: now.addingTimeInterval(-60)
        )
        XCTAssertTrue(state.hasUnseenReply)
        XCTAssertEqual(state.activity, .answeredUnseen)
    }

    func testAnEqualMarkerIsNotUnseen() {
        let state = resolve(
            inputs(lastActivityAt: now, tailRole: .agent),
            lastViewedAt: now
        )
        XCTAssertFalse(state.hasUnseenReply)
        XCTAssertEqual(state.activity, .idle)
    }

    func testAnUnprojectedTailRoleCanNeverBeUnseen() {
        // watchOS / CarPlay: nil means NOT PROJECTED, never "unknown role".
        let state = resolve(
            inputs(lastActivityAt: now, tailRole: nil),
            lastViewedAt: now.addingTimeInterval(-86_400)
        )
        XCTAssertFalse(state.hasUnseenReply)
        XCTAssertEqual(state.activity, .idle)
    }

    func testASurfaceWithNoReadStateCanNeverBeUnseen() {
        let state = resolve(inputs(lastActivityAt: now, tailRole: .agent), lastViewedAt: nil)
        XCTAssertFalse(state.hasUnseenReply)
    }

    func testAHeadlessWristNoteIsIdleAndNotUnseen() {
        // `role == user, status == nil` contributes to no aggregate, so both
        // stamps are nil and the user tail suppresses the unseen branch.
        let state = resolve(
            inputs(lastActivityAt: now, tailRole: .user),
            lastViewedAt: now.addingTimeInterval(-86_400)
        )
        XCTAssertEqual(state.activity, .idle)
        XCTAssertFalse(state.hasUnseenReply)
    }

    // MARK: - Orthogonality (the cases a tail-only derivation got wrong)

    func testAgentTailWithALiveSiblingSendingIsWorkingANDUnseen() {
        // Device A's reply landed (tail = agent) while device B's turn is still
        // sending. Both facts are true; neither may be discarded.
        let state = resolve(
            inputs(lastActivityAt: now, sending: 15, tailRole: .agent),
            lastViewedAt: now.addingTimeInterval(-300)
        )
        XCTAssertEqual(
            state.activity,
            .working(.hedged, since: now.addingTimeInterval(-15))
        )
        XCTAssertTrue(state.hasUnseenReply)
    }

    func testFailedSiblingWithAnUnseenReplyKeepsBothFacts() {
        // Both facts survive only while the failure is still the conversation's
        // last activity. That is reachable with a sync-skewed row (the failed
        // Message imported, the Conversation's stamp not yet), which is exactly
        // when a device would otherwise have to choose between the two.
        let state = resolve(
            inputs(lastActivityAt: now.addingTimeInterval(-30), failed: 15, tailRole: .agent),
            lastViewedAt: now.addingTimeInterval(-300)
        )
        XCTAssertEqual(state.activity, .failed)
        XCTAssertTrue(state.hasUnseenReply)
    }

    // MARK: - A failure is bounded (nothing ever clears a `failed` row)

    func testAFailureThatIsStillTheTailIsFailed() {
        // Boundary: the append writes both stamps from one `now`, so the tail
        // case compares EQUAL and must still be red.
        let failedAt = now.addingTimeInterval(-120)
        let state = resolve(
            inputs(lastActivityAt: failedAt, failed: 120, tailRole: .user)
        )
        XCTAssertEqual(state.activity, .failed)
    }

    func testASupersededFailureStopsPaintingTheRowRed() {
        // The overwhelmingly common recovery: the user does not scroll back to
        // Retry, they just ask again and it works. Nothing ever clears the old
        // `failed` row, so without the bound this conversation is red forever.
        let state = resolve(
            inputs(lastActivityAt: now, failed: 7_776_000, tailRole: .user)
        )
        XCTAssertEqual(state.activity, .idle)
    }

    func testASupersededFailureCannotSuppressTheUnseenReplyDisc() {
        // The worst half of the unbounded arm: a non-idle delivery state blocks
        // the fold to `.answeredUnseen`, so one old failure would kill the amber
        // disc for that thread permanently.
        let state = resolve(
            inputs(lastActivityAt: now, failed: 7_776_000, tailRole: .agent),
            lastViewedAt: now.addingTimeInterval(-3_600)
        )
        XCTAssertEqual(state.activity, .answeredUnseen)
        XCTAssertTrue(state.hasUnseenReply)
    }

    func testASupersededFailureStillYieldsToAnUnresolvedSendingTurn() {
        // Superseding the failure must not lose a `sending` turn that is OLDER
        // than it: the row is still working, not idle.
        let state = resolve(
            inputs(lastActivityAt: now, sending: 600, failed: 300, tailRole: .user)
        )
        XCTAssertEqual(
            state.activity,
            .working(.hedged, since: now.addingTimeInterval(-600))
        )
    }

    // MARK: - A failure is bounded twice (seen, as well as superseded)

    func testAnUnseenFailureCarriesItsMark() {
        let state = resolve(
            inputs(lastActivityAt: ago(120), failed: 120, tailRole: .user),
            failureSeenAt: ago(600)   // last seen BEFORE this failure existed
        )
        XCTAssertEqual(state.activity, .failed)
        XCTAssertFalse(state.failureAcknowledged)
    }

    func testASeenFailureKeepsItsStateAndLosesItsMark() {
        // The whole feature: still `.failed`, so the row goes on saying the
        // message was not sent — but acknowledged, so it stops alerting.
        let state = resolve(
            inputs(lastActivityAt: ago(120), failed: 120, tailRole: .user),
            failureSeenAt: ago(60)
        )
        XCTAssertEqual(state.activity, .failed)
        XCTAssertTrue(state.failureAcknowledged)
    }

    func testSeeingAFailureAtItsOwnStampCountsAsSeeingIt() {
        // Boundary, and NOT an accident: the marker's clamp pulls it up to at
        // least the failed turn's stamp, so equality is exactly the case where
        // the user was looking at a turn mirrored from a clock-ahead sibling.
        let state = resolve(
            inputs(lastActivityAt: ago(120), failed: 120, tailRole: .user),
            failureSeenAt: ago(120)
        )
        XCTAssertTrue(state.failureAcknowledged)
    }

    func testAcknowledgingOneFailureDoesNotAcknowledgeTheNextOne() {
        // Each failure earns its own mark. An old acknowledgement must not
        // silence the row for a fresh failure.
        let state = resolve(
            inputs(lastActivityAt: ago(30), failed: 30, tailRole: .user),
            failureSeenAt: ago(600)
        )
        XCTAssertEqual(state.activity, .failed)
        XCTAssertFalse(state.failureAcknowledged)
    }

    func testASurfaceWithNoFailureMarkerNeverAcknowledges() {
        // The watchOS / CarPlay contract: `nil` leaves the mark exactly as it
        // behaved before acknowledgement existed.
        let state = resolve(
            inputs(lastActivityAt: ago(120), failed: 120, tailRole: .user),
            failureSeenAt: nil
        )
        XCTAssertEqual(state.activity, .failed)
        XCTAssertFalse(state.failureAcknowledged)
    }

    func testAcknowledgementNeverLeaksOntoAWorkingRow() {
        // A fresh `sending` turn outranks an older failure. A marker newer than
        // that failure must not report the WORKING row as acknowledged.
        //
        // `lastActivityAt` is pinned to the FAILURE's stamp on purpose. Left to
        // the helper's default it would follow the newer `sending` turn, the
        // last-activity bound would drop the failure to nil, and `acknowledged`
        // would short-circuit before the fold — leaving the `activity == .failed`
        // guard untested and this case green even with the guard deleted.
        let state = resolve(
            inputs(lastActivityAt: ago(600), sending: 30, failed: 600, tailRole: .user),
            failureSeenAt: now
        )
        XCTAssertEqual(state.activity, .working(.hedged, since: ago(30)))
        XCTAssertFalse(state.failureAcknowledged)
    }

    func testAcknowledgementNeverLeaksOntoASupersededFailure() {
        // Superseded, so the row is already not red. It must not additionally
        // claim to be an acknowledged failure.
        let state = resolve(
            inputs(lastActivityAt: now, failed: 7_776_000, tailRole: .user),
            failureSeenAt: now
        )
        XCTAssertEqual(state.activity, .idle)
        XCTAssertFalse(state.failureAcknowledged)
    }

    func testAcknowledgementIsIndependentOfTheUnseenReply() {
        // The two attention facts are orthogonal: acknowledging a failure says
        // nothing about whether a reply has been read, and vice versa.
        let seen = resolve(
            inputs(lastActivityAt: ago(120), failed: 120, tailRole: .user),
            lastViewedAt: ago(10_000),
            failureSeenAt: ago(60)
        )
        XCTAssertTrue(seen.failureAcknowledged)
        XCTAssertFalse(seen.hasUnseenReply, "a user tail can never be an unseen reply")
    }

    // MARK: - Record / picker bridges

    func testInputsFromARecordCarryTheProjectedStamps() {
        let record = ConversationRecord(
            id: UUID(),
            title: nil,
            createdAt: now,
            lastActivityAt: now,
            sessionID: "s",
            backend: "openclaw",
            titleSnippet: nil,
            newestSendingAt: now.addingTimeInterval(-10),
            newestFailedAt: now.addingTimeInterval(-99)
        )
        let built = ConversationActivityInputs(record: record, tailRole: .agent)
        XCTAssertEqual(built.newestSendingAt, now.addingTimeInterval(-10))
        XCTAssertEqual(built.newestFailedAt, now.addingTimeInterval(-99))
        XCTAssertEqual(built.lastActivityAt, now)
        XCTAssertEqual(built.tailRole, .agent)
    }

    func testAnUnprojectedRecordResolvesExactlyAsItRendersToday() {
        let record = ConversationRecord(
            id: UUID(),
            title: nil,
            createdAt: now,
            lastActivityAt: now,
            sessionID: "s",
            backend: "openclaw",
            titleSnippet: nil
        )
        let state = resolve(ConversationActivityInputs(record: record, tailRole: .agent))
        XCTAssertEqual(state.activity, .idle)
    }

    #if os(iOS) || os(macOS)
    func testInputsFromAPickerRowCarryTheProjectedStamps() {
        let recent = ConversationStore.RecentConversation(
            id: UUID(),
            label: "Kitchen",
            lastActivityAt: now,
            backend: "openclaw",
            newestSendingAt: now.addingTimeInterval(-5),
            newestFailedAt: nil
        )
        let built = ConversationActivityInputs(recent: recent, tailRole: nil)
        XCTAssertEqual(built.newestSendingAt, now.addingTimeInterval(-5))
        XCTAssertNil(built.newestFailedAt)
        XCTAssertNil(built.tailRole)
    }
    #endif

    // MARK: - Copy

    func testLiveWorkingCopyDelegatesToTheThreadIndicator() {
        XCTAssertEqual(
            ConversationActivityCopy.working(.live, gatewayName: "OpenClaw"),
            ThinkingIndicator.label(phase: .answering, backendName: "OpenClaw")
        )
    }

    func testLiveWorkingCopyFallsBackToABareVerbWithNoGatewayName() {
        let copy = ConversationActivityCopy.working(.live, gatewayName: "")
        XCTAssertFalse(copy.hasPrefix(" "))
        XCTAssertEqual(copy, ThinkingIndicator.label(phase: .answering, backendName: ""))
    }

    func testHedgedAndStaleNeverClaimTheAgentIsAnswering() {
        let hedged = ConversationActivityCopy.working(.hedged, gatewayName: "OpenClaw")
        let stale = ConversationActivityCopy.working(.stale, gatewayName: "OpenClaw")
        XCTAssertFalse(hedged.contains("OpenClaw"))
        XCTAssertFalse(stale.contains("OpenClaw"))
        XCTAssertNotEqual(hedged, stale)
    }

    func testNotSentIsNotTheNoReplyWording() {
        XCTAssertFalse(ConversationActivityCopy.notSent.isEmpty)
        XCTAssertNotEqual(
            ConversationActivityCopy.notSent,
            ConversationActivityCopy.working(.stale, gatewayName: "")
        )
    }

    // MARK: - Coarse elapsed

    func testCoarseElapsedIsNilBelowAMinute() {
        XCTAssertNil(ConversationActivityCopy.coarseElapsed(0))
        XCTAssertNil(ConversationActivityCopy.coarseElapsed(59.9))
    }

    func testCoarseElapsedFloorsToWholeMinutes() {
        let oneMinute = ConversationActivityCopy.coarseElapsed(60)
        let almostTwo = ConversationActivityCopy.coarseElapsed(119)
        XCTAssertNotNil(oneMinute)
        XCTAssertEqual(oneMinute, almostTwo, "119 s must still read as one minute, never two")
        XCTAssertNotEqual(oneMinute, ConversationActivityCopy.coarseElapsed(120))
    }

    func testCoarseElapsedGrowsPastAnHour() {
        let elapsed = ConversationActivityCopy.coarseElapsed(90 * 60)
        XCTAssertNotNil(elapsed)
        XCTAssertNotEqual(elapsed, ConversationActivityCopy.coarseElapsed(30 * 60))
    }
}
