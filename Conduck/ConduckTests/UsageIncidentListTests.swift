// SPDX-License-Identifier: Apache-2.0

// Conduck
// UsageIncidentListTests.swift
//
// Locks the pure half of the usage incident list — the screen a failure-reason
// row opens onto. Everything it claims is a grouping decision or a sentence, and
// none of it is observable from a rendered view, which is exactly why the logic
// lives in `UsageIncidentList` and this file drives it from fixtures.
//
// The rules worth breaking a build over:
//   1. ONE TURN IS ONE INCIDENT. Three retries of one question are one thing
//      that went wrong; listing them separately makes a single bad minute look
//      like a bad week. Attempts with no `userMessageID` cannot be joined to
//      anything and each stand alone.
//   2. "RECOVERED" IS DECIDED BY THE FINAL DATED ATTEMPT, in the aggregator's
//      own chronological order — start instant, then id, with an undated row
//      sorting LAST and taking no part in the decision. Get that order wrong,
//      or let an undated row cast the deciding vote, and a turn that failed
//      reads as recovered.
//   3. THE FILTER IS A FILTER, NOT A HINT. A push opened for one error code
//      shows only turns that failed with that code, and a gateway-scoped push
//      shows only that slot — including the "no slot recorded" slot, which is a
//      real group and not the absence of a filter.
//   4. NOTHING IS SILENTLY DROPPED OR SILENTLY TRUNCATED. A turn whose
//      conversation is gone still gets a row (it just cannot be opened), and the
//      builder returns every group so the screen's own count line can state how
//      many of how many it is showing.
//
// Pure Foundation: values in, groups and strings out, no view rendered.

import XCTest

@testable import Conduck

final class UsageIncidentListTests: XCTestCase {

    private let anchor = Date(timeIntervalSince1970: 1_760_000_000)

    /// Codes are Conduck's OWN `AppError.errorCode` values; the numbers here
    /// only have to be distinct, because nothing in the grouping reads them as
    /// anything but identity.
    private let timeoutCode = 4_101
    private let refusedCode = 4_102

    private func attempt(
        id: UUID = UUID(),
        conversation: UUID? = UUID(),
        turn: UUID? = UUID(),
        gateway: String? = "openclaw",
        startedAt: Date? = nil,
        outcome: GatewayAttemptOutcome = .failed,
        appErrorCode: Int? = nil,
        origin: GatewayAttemptOrigin = .app,
        deviceClass: String? = "iphone"
    ) -> GatewayAttemptRecord {
        GatewayAttemptRecord(
            id: id,
            conversationID: conversation,
            userMessageID: turn,
            gatewayRef: gateway,
            startedAt: startedAt,
            completedAt: startedAt?.addingTimeInterval(2),
            outcome: outcome,
            appErrorCode: appErrorCode,
            origin: origin,
            originDeviceClass: deviceClass
        )
    }

    private func groups(
        _ records: [GatewayAttemptRecord],
        gateway: UsageIncidentFilter.GatewayScope = .anyGateway,
        code: Int? = nil
    ) -> [UsageIncidentGroup] {
        UsageIncidentList.groups(
            from: records,
            filter: UsageIncidentFilter(gateway: gateway, appErrorCode: code))
    }

    // MARK: - 1. Grouping

    func testRetriesOfOneTurnCollapseIntoOneIncident() throws {
        let turn = UUID()
        let conversation = UUID()
        let result = groups([
            attempt(conversation: conversation, turn: turn,
                    startedAt: anchor, appErrorCode: timeoutCode),
            attempt(conversation: conversation, turn: turn,
                    startedAt: anchor.addingTimeInterval(60), appErrorCode: timeoutCode),
            attempt(conversation: conversation, turn: turn,
                    startedAt: anchor.addingTimeInterval(120), appErrorCode: refusedCode),
        ])

        let group = try XCTUnwrap(result.first)
        XCTAssertEqual(result.count, 1, "three retries of one question are one incident")
        XCTAssertEqual(group.attemptCount, 3)
        XCTAssertEqual(group.failureCount, 3)
        XCTAssertEqual(group.startedAt, anchor,
                       "the row dates the turn from when the user asked, not from the last retry")
        XCTAssertEqual(group.appErrorCode, refusedCode,
                       "a turn retried through two errors is named by the one it ended on")
        XCTAssertFalse(group.recovered)
    }

    /// A row that recorded no turn cannot be joined to anything, so it is its
    /// own incident rather than being folded into whichever group sorted first.
    func testAttemptsWithNoTurnEachStandAlone() {
        let result = groups([
            attempt(turn: nil, startedAt: anchor, appErrorCode: timeoutCode),
            attempt(turn: nil, startedAt: anchor.addingTimeInterval(5), appErrorCode: timeoutCode),
        ])
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result.map(\.attemptCount), [1, 1])
    }

    /// The list is reached from a reliability figure. A turn that succeeded, was
    /// cancelled, or is still open has not failed, and putting it here would
    /// count as a failure something no denominator on the dashboard does.
    func testOnlyTurnsWithAStoredFailureAppear() {
        let result = groups([
            attempt(startedAt: anchor, outcome: .succeeded),
            attempt(startedAt: anchor, outcome: .cancelled),
            attempt(startedAt: anchor, outcome: .inFlight),
            attempt(startedAt: anchor, outcome: .unknown),
            attempt(startedAt: anchor, outcome: .failed, appErrorCode: timeoutCode),
        ])
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.appErrorCode, timeoutCode)
    }

    // MARK: - 2. Recovery and ordering

    func testARetryThatLandedReadsAsRecovered() throws {
        let turn = UUID()
        let group = try XCTUnwrap(groups([
            attempt(turn: turn, startedAt: anchor, appErrorCode: timeoutCode),
            attempt(turn: turn, startedAt: anchor.addingTimeInterval(30), outcome: .succeeded),
        ]).first)

        XCTAssertTrue(group.recovered)
        XCTAssertEqual(group.failureCount, 1)
        XCTAssertEqual(group.attemptCount, 2)
        XCTAssertEqual(UsageIncidentList.retryNarrative(group), "Failed, then recovered")
    }

    /// The FINAL attempt decides, and "final" is the aggregator's chronological
    /// order rather than the order the rows arrived in. A success that happened
    /// FIRST does not recover a turn that failed after it.
    func testRecoveryReadsTheChronologicallyFinalAttemptNotTheInputOrder() throws {
        let turn = UUID()
        let group = try XCTUnwrap(groups([
            // Deliberately out of order: the failure is last in time, first in
            // neither list.
            attempt(turn: turn, startedAt: anchor.addingTimeInterval(90),
                    outcome: .failed, appErrorCode: refusedCode),
            attempt(turn: turn, startedAt: anchor, outcome: .succeeded),
        ]).first)

        XCTAssertFalse(group.recovered, "a later failure is not undone by an earlier success")
        XCTAssertEqual(group.startedAt, anchor)
        XCTAssertEqual(UsageIncidentList.retryNarrative(group), "Failed once")
    }

    /// An undated row sorts LAST inside its group, so it can never be mistaken
    /// for the first try — and it is kept out of the recovery decision, so it
    /// can never make a failed turn read as recovered either. Nothing in the
    /// record says the success came after the failure, and a half-materialised
    /// import genuinely produces this shape.
    func testAnUndatedAttemptNeverDecidesRecovery() throws {
        let turn = UUID()
        let group = try XCTUnwrap(groups([
            attempt(turn: turn, startedAt: nil, outcome: .succeeded),
            attempt(turn: turn, startedAt: anchor, outcome: .failed, appErrorCode: timeoutCode),
        ]).first)

        XCTAssertFalse(group.recovered,
                       "a row that cannot say when it ran cannot be shown to have run last")
        XCTAssertEqual(group.startedAt, anchor,
                       "the group's instant comes from the rows that can say when they ran")
        XCTAssertEqual(UsageIncidentList.retryNarrative(group), "Failed once")
    }

    /// With every row undated there is no order to read, so the group keeps the
    /// only reading its rows support: it failed.
    func testAnAllUndatedGroupIsNeverRecovered() throws {
        let turn = UUID()
        let group = try XCTUnwrap(groups([
            attempt(turn: turn, startedAt: nil, outcome: .succeeded),
            attempt(turn: turn, startedAt: nil, outcome: .failed, appErrorCode: timeoutCode),
        ]).first)

        XCTAssertFalse(group.recovered)
        XCTAssertNil(group.startedAt)
        XCTAssertEqual(group.attemptCount, 2)
    }

    func testGroupsAreNewestFirstWithUndatedOnesLast() {
        let older = UUID(), newer = UUID(), undated = UUID()
        let result = groups([
            attempt(turn: older, startedAt: anchor, appErrorCode: timeoutCode),
            attempt(turn: undated, startedAt: nil, appErrorCode: timeoutCode),
            attempt(turn: newer, startedAt: anchor.addingTimeInterval(3_600),
                    appErrorCode: timeoutCode),
        ])
        XCTAssertEqual(result.map(\.id), [
            "turn:\(newer.uuidString)", "turn:\(older.uuidString)", "turn:\(undated.uuidString)"
        ])
    }

    /// A single-attempt incident has no retry story, and a sentence saying so on
    /// every row would be noise.
    func testASingleAttemptCarriesNoRetryNarrative() throws {
        let group = try XCTUnwrap(
            groups([attempt(startedAt: anchor, appErrorCode: timeoutCode)]).first)
        XCTAssertEqual(group.attemptCount, 1)
        XCTAssertNil(UsageIncidentList.retryNarrative(group))
    }

    func testRepeatedFailuresCountTheFailuresNotTheAttempts() throws {
        let turn = UUID()
        let group = try XCTUnwrap(groups([
            attempt(turn: turn, startedAt: anchor, appErrorCode: timeoutCode),
            attempt(turn: turn, startedAt: anchor.addingTimeInterval(10), appErrorCode: timeoutCode),
            attempt(turn: turn, startedAt: anchor.addingTimeInterval(20), appErrorCode: timeoutCode),
        ]).first)
        XCTAssertEqual(UsageIncidentList.retryNarrative(group), "Failed 3 times")
    }

    // MARK: - 3. Filters

    func testTheErrorCodeFilterKeepsOnlyTurnsThatFailedThatWay() {
        let records = [
            attempt(startedAt: anchor, appErrorCode: timeoutCode),
            attempt(startedAt: anchor, appErrorCode: refusedCode),
            attempt(startedAt: anchor, appErrorCode: nil),
        ]
        XCTAssertEqual(groups(records, code: timeoutCode).map(\.appErrorCode), [timeoutCode])
        XCTAssertEqual(groups(records, code: refusedCode).map(\.appErrorCode), [refusedCode])
        XCTAssertEqual(groups(records).count, 3, "unfiltered, every failed turn is an incident")
    }

    /// A filtered push names the code it was opened for, so a turn that failed
    /// twice different ways cannot show a reason the row that opened it did not
    /// mention.
    func testAFilteredGroupIsNamedByTheCodeItWasOpenedFor() throws {
        let turn = UUID()
        let group = try XCTUnwrap(groups([
            attempt(turn: turn, startedAt: anchor, appErrorCode: timeoutCode),
            attempt(turn: turn, startedAt: anchor.addingTimeInterval(30),
                    appErrorCode: refusedCode),
        ], code: timeoutCode).first)
        XCTAssertEqual(group.appErrorCode, timeoutCode)
    }

    func testTheGatewayScopeNarrowsToOneSlot() {
        let records = [
            attempt(gateway: "openclaw", startedAt: anchor, appErrorCode: timeoutCode),
            attempt(gateway: "hermes", startedAt: anchor, appErrorCode: timeoutCode),
            attempt(gateway: nil, startedAt: anchor, appErrorCode: timeoutCode),
        ]
        XCTAssertEqual(groups(records, gateway: .slot("openclaw")).map(\.gatewayRef), ["openclaw"])
        XCTAssertEqual(groups(records, gateway: .slot(nil)).map(\.gatewayRef), [nil],
                       "`.slot(nil)` is the attempts that recorded no slot — a real group, not "
                       + "the absence of a filter")
        XCTAssertEqual(groups(records, gateway: .anyGateway).count, 3)
    }

    // MARK: - 4. Tolerance and paging

    /// Usage outlives the conversations it describes. A turn whose thread is
    /// gone still gets a row; it simply carries no conversation to open.
    func testAGroupWithNoConversationIsStillListed() throws {
        let group = try XCTUnwrap(groups([
            attempt(conversation: nil, startedAt: anchor, appErrorCode: timeoutCode)
        ]).first)
        XCTAssertNil(group.conversationID)
        XCTAssertEqual(group.appErrorCode, timeoutCode)
    }

    /// The derived bucket, not a stored field: a CarPlay dispatch runs on the
    /// iPhone and stamps `iphone`, so the surface is what puts it in the bucket
    /// the user reads.
    func testTheDeviceBucketIsDerivedTheSameWayTheDashboardDerivesIt() throws {
        let carPlay = try XCTUnwrap(groups([
            attempt(startedAt: anchor, appErrorCode: timeoutCode,
                    origin: .carPlay, deviceClass: "iphone")
        ]).first)
        XCTAssertEqual(carPlay.device, .carPlay)

        let unmeasured = try XCTUnwrap(groups([
            attempt(startedAt: anchor, appErrorCode: timeoutCode,
                    origin: .unknown, deviceClass: nil)
        ]).first)
        XCTAssertEqual(unmeasured.device, .unknown)
    }

    /// THE BUILDER NEVER TRUNCATES. Paging is the screen's, and it can only be
    /// honest about "N of M" if M is the whole list.
    func testTheBuilderReturnsEveryGroupSoThePagingLineCanStateTheTotal() {
        let records = (0..<(UsageIncidentList.pageSize + 7)).map { index in
            attempt(startedAt: anchor.addingTimeInterval(Double(index) * 60),
                    appErrorCode: timeoutCode)
        }
        let all = groups(records)
        XCTAssertEqual(all.count, UsageIncidentList.pageSize + 7)

        let firstPage = all.prefix(UsageIncidentList.pageSize)
        XCTAssertEqual(
            UsageIncidentList.showingText(shown: firstPage.count, total: all.count),
            "Showing \(UsageIncidentList.pageSize) of \(UsageIncidentList.pageSize + 7)")
    }

    /// The count line is rendered even when nothing was cut — "Showing 6 of 6"
    /// is what makes "Showing 50 of 812" legible as a cut rather than a total.
    func testTheCountLineStatesBothNumbersEvenWhenTheListFits() {
        XCTAssertEqual(UsageIncidentList.showingText(shown: 6, total: 6), "Showing 6 of 6")
    }

    func testAnEmptyLedgerYieldsNoGroups() {
        XCTAssertTrue(groups([]).isEmpty)
    }
}
