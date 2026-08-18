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
//   • acknowledgement is an IDENTITY match against one delivery attempt — never
//     a timestamp, never `nil == nil` — and never leaks onto a row that is not
//     reporting the failure;
//   • the failed-turn total order breaks an equal-`createdAt` tie on the
//     message id, so the reported attempt identity cannot depend on fetch
//     order;
//   • the failed arm's bound compares WHOLE MILLISECONDS, never `Date`s: the
//     stamp and the bound are separate CKRecords and the mirror imports them in
//     separate batches, so a sub-millisecond difference between the two is a
//     transport artefact, not a fact about the conversation;
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
    ///
    /// `failedAttemptID` is the identity of the failed turn being described,
    /// and it defaults to nil ON PURPOSE: nil is the legacy row, and the
    /// contract is that it can never be acknowledged. Every case that is not
    /// ABOUT acknowledgement therefore reads exactly as it did before identity
    /// existed.
    private func inputs(
        lastActivityAt: Date? = nil,
        sending: TimeInterval? = nil,
        failed: TimeInterval? = nil,
        failedMessageID: UUID? = nil,
        failedAttemptID: UUID? = nil,
        storedLastViewedAt: Date? = nil,
        storedFailureSeenAttemptID: UUID? = nil,
        tailRole: MessageRole? = nil
    ) -> ConversationActivityInputs {
        let sendingAt = sending.map { now.addingTimeInterval(-$0) }
        let failedAt = failed.map { now.addingTimeInterval(-$0) }
        let tailStamp = [sendingAt, failedAt].compactMap { $0 }.max()
        return ConversationActivityInputs(
            lastActivityAt: lastActivityAt ?? tailStamp ?? now,
            newestSendingAt: sendingAt,
            newestFailed: failedAt.map {
                FailedTurnProjection(
                    messageID: failedMessageID ?? UUID(),
                    createdAt: $0,
                    deliveryAttemptID: failedAttemptID
                )
            },
            storedLastViewedAt: storedLastViewedAt,
            storedFailureSeenAttemptID: storedFailureSeenAttemptID,
            tailRole: tailRole
        )
    }

    /// There is no acknowledgement parameter here, and its absence is the
    /// contract: acknowledgement is answered from `inputs` alone, because no
    /// device-local value can say WHICH attempt was seen.
    private func resolve(
        _ inputs: ConversationActivityInputs,
        locallyLiveSince: Date? = nil,
        lastViewedAt: Date? = nil
    ) -> ConversationRowState {
        ConversationActivityResolver.resolve(
            inputs,
            locallyLiveSince: locallyLiveSince,
            lastViewedAt: lastViewedAt,
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

    func testTheFailedBoundIsJudgedInWholeMilliseconds() {
        // `Message.createdAt` and `Conversation.lastActivityAt` are separate
        // CKRecords. `ConversationStore.repairTailProjection` snaps both onto one
        // canonical `Date` in one local save, and roughly half the legacy rows it
        // touches round UPWARD — but the two records leave as two, and another
        // device can import the conversation before the message. A bit-exact
        // comparison reads that window as "the failure is older than the
        // conversation's last activity" and drops the red mark from the list, the
        // menu bar and the wrist, for a message that never sent. Quantising both
        // sides to the millisecond the mirror itself carries makes the window
        // invisible.
        let millisecond = Date(timeIntervalSince1970: 1_700_000_000.001)
        let state = resolve(
            inputs(
                lastActivityAt: millisecond,
                failed: now.timeIntervalSince(millisecond.addingTimeInterval(-0.0004)),
                tailRole: .user
            )
        )
        XCTAssertEqual(state.activity, .failed)
    }

    func testAGenuinelyOlderFailureIsStillSupersededAtMillisecondResolution() {
        // The other half of the same rule: quantising must not widen the bound
        // into a tolerance window. One WHOLE millisecond later is a different
        // millisecond, so the failure is superseded exactly as before.
        let failedAt = Date(timeIntervalSince1970: 1_700_000_000.000)
        let state = resolve(
            inputs(
                lastActivityAt: failedAt.addingTimeInterval(0.001),
                failed: now.timeIntervalSince(failedAt),
                tailRole: .user
            )
        )
        XCTAssertEqual(state.activity, .idle)
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

    // MARK: - A failure is bounded twice (acknowledged, as well as superseded)

    func testAnUnacknowledgedFailureCarriesItsMark() {
        let state = resolve(
            inputs(
                lastActivityAt: ago(120), failed: 120,
                failedAttemptID: UUID(),
                storedFailureSeenAttemptID: UUID(),   // some OTHER attempt
                tailRole: .user
            )
        )
        XCTAssertEqual(state.activity, .failed)
        XCTAssertFalse(state.failureAcknowledged)
    }

    func testAnAcknowledgedFailureKeepsItsStateAndLosesItsMark() {
        // The whole feature: still `.failed`, so the row goes on saying the
        // message was not sent — but acknowledged, so it stops alerting.
        let attemptID = UUID()
        let state = resolve(
            inputs(
                lastActivityAt: ago(120), failed: 120,
                failedAttemptID: attemptID,
                storedFailureSeenAttemptID: attemptID,
                tailRole: .user
            )
        )
        XCTAssertEqual(state.activity, .failed)
        XCTAssertTrue(state.failureAcknowledged)
    }

    func testNeitherSideBeingNamedDoesNotAcknowledge() {
        // `nil == nil` must NOT acknowledge. A legacy row carries no attempt id
        // and no acknowledgement can name one, so it stays red — an
        // unacknowledged failure costs one tap, a silenced one is a message the
        // user never learns did not send.
        let state = resolve(
            inputs(lastActivityAt: ago(120), failed: 120, tailRole: .user)
        )
        XCTAssertEqual(state.activity, .failed)
        XCTAssertFalse(state.failureAcknowledged)
    }

    func testAFailureWithNoAttemptIDIsNeverAcknowledged() {
        // The mixed-version-fleet case: an old build can retry a turn without
        // minting an id. The stored acknowledgement is real, and still must not
        // match a failure that cannot be named.
        let state = resolve(
            inputs(
                lastActivityAt: ago(120), failed: 120,
                failedAttemptID: nil,
                storedFailureSeenAttemptID: UUID(),
                tailRole: .user
            )
        )
        XCTAssertFalse(state.failureAcknowledged)
    }

    func testAcknowledgingOneAttemptDoesNotAcknowledgeTheRetry() {
        // THE reason acknowledgement is identity and not time: asking again
        // does not advance the failed turn's `createdAt`, so only a new attempt
        // id can distinguish "acknowledged" from "acknowledged the PREVIOUS
        // attempt". A retry mints one, and the stored acknowledgement simply
        // stops matching — nothing has to clear a marker.
        let state = resolve(
            inputs(
                lastActivityAt: ago(30), failed: 30,
                failedAttemptID: UUID(),                 // the retry's attempt
                storedFailureSeenAttemptID: UUID(),      // the one already seen
                tailRole: .user
            )
        )
        XCTAssertEqual(state.activity, .failed)
        XCTAssertFalse(state.failureAcknowledged)
    }

    func testASurfaceWithNoStoredAcknowledgementNeverAcknowledges() {
        let state = resolve(
            inputs(
                lastActivityAt: ago(120), failed: 120,
                failedAttemptID: UUID(),
                storedFailureSeenAttemptID: nil,
                tailRole: .user
            )
        )
        XCTAssertEqual(state.activity, .failed)
        XCTAssertFalse(state.failureAcknowledged)
    }

    func testAcknowledgementNeverLeaksOntoAWorkingRow() {
        // A fresh `sending` turn outranks an older failure. A stored
        // acknowledgement naming that failure must not report the WORKING row
        // as acknowledged.
        //
        // `lastActivityAt` is pinned to the FAILURE's stamp on purpose. Left to
        // the helper's default it would follow the newer `sending` turn, the
        // last-activity bound would drop the failure to nil, and `acknowledged`
        // would short-circuit before the fold — leaving the `activity == .failed`
        // guard untested and this case green even with the guard deleted.
        let attemptID = UUID()
        let state = resolve(
            inputs(
                lastActivityAt: ago(600), sending: 30, failed: 600,
                failedAttemptID: attemptID,
                storedFailureSeenAttemptID: attemptID,
                tailRole: .user
            )
        )
        XCTAssertEqual(state.activity, .working(.hedged, since: ago(30)))
        XCTAssertFalse(state.failureAcknowledged)
    }

    func testAcknowledgementNeverLeaksOntoASupersededFailure() {
        // Superseded, so the row is already not red. It must not additionally
        // claim to be an acknowledged failure.
        let attemptID = UUID()
        let state = resolve(
            inputs(
                lastActivityAt: now, failed: 7_776_000,
                failedAttemptID: attemptID,
                storedFailureSeenAttemptID: attemptID,
                tailRole: .user
            )
        )
        XCTAssertEqual(state.activity, .idle)
        XCTAssertFalse(state.failureAcknowledged)
    }

    func testAcknowledgementIsIndependentOfTheUnseenReply() {
        // The two attention facts are orthogonal: acknowledging a failure says
        // nothing about whether a reply has been read, and vice versa.
        let attemptID = UUID()
        let seen = resolve(
            inputs(
                lastActivityAt: ago(120), failed: 120,
                failedAttemptID: attemptID,
                storedFailureSeenAttemptID: attemptID,
                tailRole: .user
            ),
            lastViewedAt: ago(10_000)
        )
        XCTAssertTrue(seen.failureAcknowledged)
        XCTAssertFalse(seen.hasUnseenReply, "a user tail can never be an unseen reply")
    }

    // MARK: - The failed-turn total order

    func testTheNewerStampWinsOutright() {
        let older = FailedTurnProjection(
            messageID: UUID(), createdAt: ago(60), deliveryAttemptID: UUID()
        )
        let newer = FailedTurnProjection(
            messageID: UUID(), createdAt: ago(30), deliveryAttemptID: UUID()
        )
        XCTAssertTrue(newer.isNewer(than: older))
        XCTAssertFalse(older.isNewer(than: newer))
    }

    func testAnEqualStampIsBrokenOnTheMessageIDRatherThanOnArrivalOrder() {
        // The case fetch order used to decide. Two failures at one instant must
        // resolve to the SAME winner on every device and on every fetch — the
        // winner names the attempt id an acknowledgement is matched against, so
        // disagreement means an acknowledgement made on one device never
        // matches on another, and a device that selects differently between the
        // fetch that fed the acknowledgement and the fetch that resolves the
        // row leaves the conversation red with no way to retire it.
        let stamp = ago(120)
        let low = FailedTurnProjection(
            messageID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            createdAt: stamp,
            deliveryAttemptID: UUID()
        )
        let high = FailedTurnProjection(
            messageID: UUID(uuidString: "FFFFFFFF-0000-0000-0000-000000000000")!,
            createdAt: stamp,
            deliveryAttemptID: UUID()
        )
        XCTAssertTrue(high.isNewer(than: low))
        XCTAssertFalse(low.isNewer(than: high))
    }

    func testTheOrderIsIrreflexive() {
        let turn = FailedTurnProjection(
            messageID: UUID(), createdAt: ago(10), deliveryAttemptID: UUID()
        )
        XCTAssertFalse(
            turn.isNewer(than: turn),
            "re-encountering the same row must never flip the winner"
        )
    }

    func testAnIDLessFailureIsStillCarriedAndSimplyLosesTheTie() {
        // Dropping it from the aggregate would silently retire its red mark,
        // which is the one direction this design forbids.
        let stamp = ago(10)
        let identified = FailedTurnProjection(
            messageID: UUID(), createdAt: stamp, deliveryAttemptID: UUID()
        )
        let anonymous = FailedTurnProjection(
            messageID: nil, createdAt: stamp, deliveryAttemptID: nil
        )
        XCTAssertTrue(identified.isNewer(than: anonymous))
        XCTAssertFalse(anonymous.isNewer(than: identified))
    }

    // MARK: - Record / picker bridges

    func testInputsFromARecordCarryTheProjectedStamps() {
        let failedTurnID = UUID()
        let attemptID = UUID()
        let record = ConversationRecord(
            id: UUID(),
            title: nil,
            createdAt: now,
            lastActivityAt: now,
            sessionID: "s",
            backend: "openclaw",
            titleSnippet: nil,
            newestSendingAt: now.addingTimeInterval(-10),
            newestFailed: FailedTurnProjection(
                messageID: failedTurnID,
                createdAt: now.addingTimeInterval(-99),
                deliveryAttemptID: attemptID
            )
        )
        let built = ConversationActivityInputs(record: record, tailRole: .agent)
        XCTAssertEqual(built.newestSendingAt, now.addingTimeInterval(-10))
        XCTAssertEqual(built.newestFailed?.createdAt, now.addingTimeInterval(-99))
        XCTAssertEqual(built.newestFailed?.messageID, failedTurnID)
        XCTAssertEqual(
            built.newestFailed?.deliveryAttemptID, attemptID,
            "the attempt identity must ride in with the stamp it belongs to — a "
                + "surface that has to source it separately can pair one turn's "
                + "stamp with another turn's identity"
        )
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
            newestFailed: nil
        )
        let built = ConversationActivityInputs(recent: recent, tailRole: nil)
        XCTAssertEqual(built.newestSendingAt, now.addingTimeInterval(-5))
        XCTAssertNil(built.newestFailed)
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
