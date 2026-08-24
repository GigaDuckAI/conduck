// SPDX-License-Identifier: Apache-2.0

// Conduck
// GatewayUsageAggregatorTests.swift
//
// Locks the read half of the gateway-attempt ledger: every dashboard number,
// computed from fixtures against an injected `now`, an injected grace and a
// fixed UTC calendar, so nothing here depends on when or where the suite runs.
//
// The four things worth breaking a build over, and why:
//   1. THE DENOMINATORS. `resolvedAttemptSuccessRate` divides by succeeded +
//      failed ONLY; token coverage divides by attempts that reached a STORED
//      terminal outcome; turn rates divide by distinct `userMessageID`. Every
//      one of them can be made to look healthier by widening or narrowing it,
//      so each is asserted against a fixture built to punish the wrong choice.
//   2. NIL IS NOT ZERO. A rate with no denominator is nil, a token field
//      nobody reported is nil, and a field everybody reported as zero is 0.
//      Collapsing any pair of those claims a gateway said something it did not.
//   3. THE QUANTILE IS TYPE-7, checked against hand-computed golden values —
//      the estimator R, NumPy and spreadsheets agree on, so a user who exports
//      their own numbers gets the same median Conduck shows.
//   4. DERIVED OUTCOMES NEVER SETTLE WRONG. A live attempt reads `inFlight`, a
//      young one `pending`, an old one `unconfirmed`, and a FUTURE-DATED one
//      `unconfirmed` too — the clock-skew rule, without which a row stamped by
//      a device whose clock runs fast stays `pending` forever.
//
// Timing sanity is REJECTION, not clamping (a negative or absurd interval
// becomes no sample at all), and that is asserted directly: clamping would
// invent a boundary sample and drag the median toward it while leaving `n`
// looking honest.

import XCTest

@testable import Conduck

final class GatewayUsageAggregatorTests: XCTestCase {

    // MARK: - Fixture scaffolding

    /// Fixed instant, so `pending` / `unconfirmed` never depend on the clock.
    private let now = Date(timeIntervalSince1970: 1_760_000_000)

    private let grace = ConversationActivityResolver.staleSendingGrace

    /// UTC gregorian — day boundaries must not move with the runner's timezone.
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()

    private func attempt(
        id: UUID = UUID(),
        conversation: UUID = UUID(),
        turn: UUID? = UUID(),
        gateway: String? = "openclaw",
        startedAt: Date? = nil,
        elapsed: TimeInterval? = nil,
        outcome: GatewayAttemptOutcome = .succeeded,
        requestedModel: String? = nil,
        finishReason: String? = nil,
        input: Int64? = nil,
        output: Int64? = nil,
        total: Int64? = nil
    ) -> GatewayAttemptRecord {
        let started = startedAt ?? now.addingTimeInterval(-60)
        return GatewayAttemptRecord(
            id: id,
            conversationID: conversation,
            userMessageID: turn,
            gatewayRef: gateway,
            startedAt: started,
            completedAt: elapsed.map { started.addingTimeInterval($0) },
            outcome: outcome,
            requestedModel: requestedModel,
            finishReason: finishReason,
            reportedInputTokens: input,
            reportedOutputTokens: output,
            reportedTotalTokens: total
        )
    }

    /// `calendar:` and `now:` are overridable for the daylight-saving cases,
    /// which are the only ones whose answer depends on a zone or on where the
    /// clock sits relative to a transition.
    private func summarize(
        _ attempts: [GatewayAttemptRecord],
        live: Set<UUID> = [],
        range: ClosedRange<Date>? = nil,
        calendar: Calendar? = nil,
        now: Date? = nil
    ) -> GatewayUsageSummary {
        GatewayUsageAggregator.summarize(
            attempts: attempts,
            liveAttemptIDs: live,
            now: now ?? self.now,
            activityRange: range,
            calendar: calendar ?? self.calendar,
            grace: grace
        )
    }

    /// A gregorian calendar pinned to a named zone, for the transition cases.
    private func calendar(in identifier: String) -> Calendar {
        var zoned = Calendar(identifier: .gregorian)
        zoned.timeZone = TimeZone(identifier: identifier)!
        return zoned
    }

    // MARK: - 1. Type-7 quantile golden values

    func testQuantileIsEmptyForNoSamples() {
        XCTAssertNil(GatewayUsageAggregator.quantile(sorted: [], probability: 0.5))
    }

    func testQuantileOfASingleSampleIsThatSampleAtEveryProbability() {
        for probability in [0.0, 0.5, 0.9, 1.0] {
            XCTAssertEqual(
                GatewayUsageAggregator.quantile(sorted: [7.5], probability: probability), 7.5)
        }
    }

    /// n = 4, p = 0.5 → h = 1.5 → 2 + 0.5 × (3 − 2) = 2.5. The even-count case
    /// where a naive "middle element" implementation silently returns 2 or 3.
    func testMedianInterpolatesBetweenTheTwoMiddleSamples() {
        XCTAssertEqual(
            GatewayUsageAggregator.quantile(sorted: [1, 2, 3, 4], probability: 0.5)!,
            2.5,
            accuracy: 1e-9
        )
    }

    /// n = 5, p = 0.5 → h = 2.0 → exactly the third sample, no interpolation.
    func testMedianOfAnOddCountLandsOnASample() {
        XCTAssertEqual(
            GatewayUsageAggregator.quantile(sorted: [1, 2, 3, 4, 5], probability: 0.5)!,
            3.0,
            accuracy: 1e-9
        )
    }

    /// n = 10, p = 0.9 → h = 9 × 0.9 = 8.1 → 9 + 0.1 × (10 − 9) = 9.1.
    func testP90GoldenValueForTenSamples() {
        let samples = (1...10).map(Double.init)
        XCTAssertEqual(
            GatewayUsageAggregator.quantile(sorted: samples, probability: 0.9)!,
            9.1,
            accuracy: 1e-9
        )
    }

    /// n = 20, p = 0.9 → h = 19 × 0.9 = 17.1 → 18 + 0.1 × (19 − 18) = 18.1.
    func testP90GoldenValueAtTheMinimumSampleCount() {
        let samples = (1...20).map(Double.init)
        XCTAssertEqual(
            GatewayUsageAggregator.quantile(sorted: samples, probability: 0.9)!,
            18.1,
            accuracy: 1e-9
        )
    }

    func testQuantileEndpointsAreTheExtremes() {
        let samples = [2.0, 4.0, 8.0, 16.0]
        XCTAssertEqual(GatewayUsageAggregator.quantile(sorted: samples, probability: 0)!, 2.0)
        XCTAssertEqual(GatewayUsageAggregator.quantile(sorted: samples, probability: 1)!, 16.0)
        // Out-of-domain probabilities clamp rather than index out of bounds.
        XCTAssertEqual(GatewayUsageAggregator.quantile(sorted: samples, probability: -3)!, 2.0)
        XCTAssertEqual(GatewayUsageAggregator.quantile(sorted: samples, probability: 42)!, 16.0)
    }

    // MARK: - 2. §3.2 formulas

    /// Three turns: A retried once then succeeded, B succeeded first try, C
    /// failed three times. Every count below is a different slice of the same
    /// six attempts, which is the point — a formula that reached for the wrong
    /// one still produces a plausible number.
    func testTurnFormulasSeparateAttemptsFromTurns() {
        let turnA = UUID(), turnB = UUID(), turnC = UUID()
        let summary = summarize([
            attempt(turn: turnA, outcome: .failed),
            attempt(turn: turnA, outcome: .succeeded),
            attempt(turn: turnB, outcome: .succeeded),
            attempt(turn: turnC, outcome: .failed),
            attempt(turn: turnC, outcome: .failed),
            attempt(turn: turnC, outcome: .failed),
        ])

        XCTAssertEqual(summary.recordedAttempts, 6)
        XCTAssertEqual(summary.attemptedTurns, 3)
        XCTAssertEqual(summary.completedTurns, 2)
        XCTAssertEqual(summary.retriedTurns, 2, "A and C each have more than one attempt")
        XCTAssertEqual(summary.retryRate!, 2.0 / 3.0, accuracy: 1e-9)
        XCTAssertEqual(summary.completedTurnRate!, 2.0 / 3.0, accuracy: 1e-9)
        // 2 succeeded / (2 succeeded + 4 failed)
        XCTAssertEqual(summary.resolvedAttemptSuccessRate!, 1.0 / 3.0, accuracy: 1e-9)
        // A contributed 2 attempts, B contributed 1; C's three never completed.
        XCTAssertEqual(summary.attemptsPerCompletedTurn!, 1.5, accuracy: 1e-9)
    }

    /// Cancellations and unclassifiable landings are shown, never buried in the
    /// success-rate denominator — the single easiest way to make reliability
    /// look worse (or, with the opposite mistake, better) than it was.
    func testCancelledAndUnknownStayOutOfTheResolvedSuccessDenominator() {
        let summary = summarize([
            attempt(outcome: .succeeded),
            attempt(outcome: .succeeded),
            attempt(outcome: .succeeded),
            attempt(outcome: .failed),
            attempt(outcome: .cancelled),
            attempt(outcome: .cancelled),
            attempt(outcome: .unknown),
        ])

        XCTAssertEqual(summary.resolvedAttemptSuccessRate!, 0.75, accuracy: 1e-9)
        XCTAssertEqual(summary.outcomeMix.succeeded, 3)
        XCTAssertEqual(summary.outcomeMix.failed, 1)
        XCTAssertEqual(summary.outcomeMix.cancelled, 2)
        XCTAssertEqual(summary.outcomeMix.unknown, 1)
        XCTAssertEqual(summary.outcomeMix.resolved, 7)
        XCTAssertEqual(summary.outcomeMix.open, 0)
    }

    /// Every rate is nil, never zero, when its denominator is empty. "Nothing
    /// succeeded" and "nothing has resolved yet" are opposite claims.
    func testEmptyInputYieldsNilRatesNotZeroes() {
        let summary = summarize([])

        XCTAssertTrue(summary.isEmpty)
        XCTAssertEqual(summary.recordedAttempts, 0)
        XCTAssertNil(summary.retryRate)
        XCTAssertNil(summary.completedTurnRate)
        XCTAssertNil(summary.resolvedAttemptSuccessRate)
        XCTAssertNil(summary.attemptsPerCompletedTurn)
        XCTAssertNil(summary.responseTime.median)
        XCTAssertTrue(summary.tokens.isEmpty)
        XCTAssertEqual(summary, .empty)
    }

    /// A row with no `userMessageID` is still an attempt and belongs to no
    /// turn. Inventing a turn for it would inflate exactly the number retries
    /// are kept out of.
    func testUnattributedAttemptCountsAsAnAttemptButNotATurn() {
        let summary = summarize([
            attempt(turn: nil, outcome: .succeeded),
            attempt(outcome: .succeeded),
        ])

        XCTAssertEqual(summary.recordedAttempts, 2)
        XCTAssertEqual(summary.attemptedTurns, 1)
        XCTAssertEqual(summary.completedTurns, 1)
    }

    func testActiveConversationsCountsDistinctConversations() {
        let one = UUID(), two = UUID()
        let summary = summarize([
            attempt(conversation: one),
            attempt(conversation: one),
            attempt(conversation: two),
        ])

        XCTAssertEqual(summary.activeConversations, 2)
    }

    // MARK: - 3. Token sums and coverage denominators

    /// The denominator is TERMINAL attempts. A live attempt has not had its
    /// chance to report usage, and an unconfirmed one is missing evidence
    /// rather than a gateway that declined — counting either would understate
    /// coverage and, worse, imply the gateway is quieter than it is.
    func testTokenCoverageDenominatorIsTerminalAttemptsOnly() {
        let liveID = UUID()
        let summary = summarize(
            [
                attempt(outcome: .succeeded, input: 100, output: 20, total: 120),
                attempt(outcome: .failed, input: 50),
                attempt(outcome: .cancelled),
                // Live here and now: excluded from numerator AND denominator.
                attempt(id: liveID, outcome: .inFlight, input: 999, output: 999, total: 999),
                // Open, past the grace, no local task: unconfirmed, also excluded.
                attempt(
                    startedAt: now.addingTimeInterval(-(grace + 60)),
                    outcome: .inFlight,
                    input: 777
                ),
            ],
            live: [liveID]
        )

        XCTAssertEqual(summary.tokens.input.coverageDenominator, 3)
        XCTAssertEqual(summary.tokens.input.reportingAttempts, 2)
        XCTAssertEqual(summary.tokens.input.coverage!, 2.0 / 3.0, accuracy: 1e-9)
        XCTAssertEqual(summary.tokens.input.sum, 150, "the live and unconfirmed rows never sum in")

        XCTAssertEqual(summary.tokens.output.reportingAttempts, 1)
        XCTAssertEqual(summary.tokens.output.coverage!, 1.0 / 3.0, accuracy: 1e-9)
        XCTAssertEqual(summary.tokens.output.sum, 20)

        XCTAssertEqual(summary.tokens.reportedTotal.sum, 120)
        XCTAssertEqual(summary.tokens.reportedTotal.coverage!, 1.0 / 3.0, accuracy: 1e-9)
    }

    /// Per-field coverage, not one generic percentage — the fields genuinely
    /// differ, and a gateway that reports `prompt_tokens` and nothing else is
    /// common.
    func testEachTokenFieldCarriesItsOwnCoverage() {
        let summary = summarize([
            attempt(outcome: .succeeded, input: 10, output: 1, total: 11),
            attempt(outcome: .succeeded, input: 10),
            attempt(outcome: .succeeded, input: 10),
            attempt(outcome: .succeeded),
        ])

        XCTAssertEqual(summary.tokens.input.coverage!, 0.75, accuracy: 1e-9)
        XCTAssertEqual(summary.tokens.output.coverage!, 0.25, accuracy: 1e-9)
        XCTAssertEqual(summary.tokens.reportedTotal.coverage!, 0.25, accuracy: 1e-9)
    }

    /// A field nobody reported sums to NIL. Summing absence to zero is how a
    /// dashboard ends up claiming a gateway reports usage when it reports
    /// nothing at all.
    func testUnreportedFieldSumsToNilAndReportedZeroSumsToZero() {
        let unreported = summarize([attempt(outcome: .succeeded)])
        XCTAssertNil(unreported.tokens.input.sum)
        XCTAssertFalse(unreported.tokens.input.isReported)
        XCTAssertEqual(unreported.tokens.input.coverage!, 0.0, accuracy: 1e-9)

        let reportedZero = summarize([attempt(outcome: .succeeded, input: 0)])
        XCTAssertEqual(reportedZero.tokens.input.sum, 0)
        XCTAssertTrue(reportedZero.tokens.input.isReported)
        XCTAssertEqual(reportedZero.tokens.input.coverage!, 1.0, accuracy: 1e-9)
    }

    /// Coverage is nil — not zero — when nothing terminal is in range to have
    /// reported anything.
    func testCoverageIsNilWhenNothingHasResolved() {
        let summary = summarize([attempt(outcome: .inFlight)], live: [])
        XCTAssertNil(summary.tokens.input.coverage)
        XCTAssertEqual(summary.tokens.input.coverageDenominator, 0)
    }

    /// A failed attempt's tokens count: the gateway may have performed billable
    /// work before it failed the turn.
    func testTokenBearingFailuresAreIncluded() {
        let summary = summarize([attempt(outcome: .failed, input: 300, output: 5)])
        XCTAssertEqual(summary.tokens.input.sum, 300)
        XCTAssertEqual(summary.tokens.output.sum, 5)
    }

    /// The calculated fallback exists ONLY where there is no gateway-reported
    /// total, and it is never confused with one.
    func testCalculatedKnownComponentsOnlyFillInForAMissingReportedTotal() {
        let withoutTotal = summarize([attempt(outcome: .succeeded, input: 100, output: 25)])
        XCTAssertNil(withoutTotal.tokens.reportedTotal.sum)
        XCTAssertEqual(withoutTotal.tokens.calculatedKnownComponents, 125)

        let withTotal = summarize([attempt(outcome: .succeeded, input: 100, output: 25, total: 140)])
        XCTAssertEqual(withTotal.tokens.reportedTotal.sum, 140, "reported totals are preserved verbatim")
        XCTAssertNil(
            withTotal.tokens.calculatedKnownComponents,
            "a gateway-reported total is never second-guessed by a client sum")

        let nothing = summarize([attempt(outcome: .succeeded)])
        XCTAssertNil(nothing.tokens.calculatedKnownComponents)
    }

    /// An inconsistent total survives as reported. Repairing it here would swap
    /// a gateway fact for a client guess no later reader could tell apart.
    func testInconsistentReportedTotalIsPreserved() {
        let summary = summarize([attempt(outcome: .succeeded, input: 10, output: 10, total: 999)])
        XCTAssertEqual(summary.tokens.reportedTotal.sum, 999)
    }

    // MARK: - 4. Effective-outcome integration

    func testLiveAttemptReadsAsInFlight() {
        let liveID = UUID()
        let summary = summarize([attempt(id: liveID, outcome: .inFlight)], live: [liveID])

        XCTAssertEqual(summary.outcomeMix.inFlight, 1)
        XCTAssertEqual(summary.outcomeMix.pending, 0)
        XCTAssertEqual(summary.outcomeMix.unconfirmed, 0)
        XCTAssertEqual(summary.outcomeMix.resolved, 0)
    }

    func testYoungOpenAttemptWithNoLocalTaskReadsAsPending() {
        let summary = summarize([
            attempt(startedAt: now.addingTimeInterval(-60), outcome: .inFlight)
        ])

        XCTAssertEqual(summary.outcomeMix.pending, 1)
        XCTAssertEqual(summary.outcomeMix.unconfirmed, 0)
    }

    func testOpenAttemptPastTheGraceReadsAsUnconfirmed() {
        let summary = summarize([
            attempt(startedAt: now.addingTimeInterval(-(grace + 1)), outcome: .inFlight)
        ])

        XCTAssertEqual(summary.outcomeMix.unconfirmed, 1)
        XCTAssertEqual(summary.outcomeMix.pending, 0)
    }

    /// CLOCK SKEW. A row stamped by a device whose clock runs fast is
    /// future-dated here; an elapsed-only window would leave it `pending`
    /// forever because the interval only grows more negative.
    func testFutureDatedAttemptBeyondTheGraceIsUnconfirmedNotPending() {
        let summary = summarize([
            attempt(startedAt: now.addingTimeInterval(grace + 600), outcome: .inFlight)
        ])

        XCTAssertEqual(summary.outcomeMix.unconfirmed, 1)
        XCTAssertEqual(summary.outcomeMix.pending, 0)
        XCTAssertEqual(summary.outcomeMix.inFlight, 0)
    }

    /// A mildly future-dated row is still inside the symmetric window.
    func testSlightlyFutureDatedAttemptIsStillPending() {
        let summary = summarize([
            attempt(startedAt: now.addingTimeInterval(60), outcome: .inFlight)
        ])

        XCTAssertEqual(summary.outcomeMix.pending, 1)
    }

    /// No start instant means no window to be inside.
    func testOpenAttemptWithNoStartInstantIsUnconfirmed() {
        let record = GatewayAttemptRecord(
            id: UUID(),
            conversationID: UUID(),
            userMessageID: UUID(),
            gatewayRef: "openclaw",
            startedAt: nil,
            completedAt: nil,
            outcome: .inFlight
        )
        let summary = summarize([record])

        XCTAssertEqual(summary.outcomeMix.unconfirmed, 1)
    }

    /// A stored terminal outcome ignores the live set entirely — a device
    /// holding a stale task handle cannot un-resolve a landed attempt.
    func testStoredTerminalOutcomeWinsOverALiveTaskHandle() {
        let id = UUID()
        let summary = summarize([attempt(id: id, outcome: .succeeded)], live: [id])

        XCTAssertEqual(summary.outcomeMix.succeeded, 1)
        XCTAssertEqual(summary.outcomeMix.inFlight, 0)
    }

    /// Derived states stay out of every rate: with one succeeded attempt and
    /// three unresolved ones, the success rate is still 1.0 and the honest
    /// counterweight is the visible mix.
    func testDerivedStatesNeverEnterTheResolvedRate() {
        let liveID = UUID()
        let summary = summarize(
            [
                attempt(outcome: .succeeded),
                attempt(id: liveID, outcome: .inFlight),
                attempt(startedAt: now.addingTimeInterval(-30), outcome: .inFlight),
                attempt(startedAt: now.addingTimeInterval(-(grace * 4)), outcome: .inFlight),
            ],
            live: [liveID]
        )

        XCTAssertEqual(summary.resolvedAttemptSuccessRate!, 1.0, accuracy: 1e-9)
        XCTAssertEqual(summary.outcomeMix.open, 3)
        XCTAssertEqual(summary.outcomeMix.total, 4)
    }

    // MARK: - 5. Response time

    func testResponseTimeUsesSuccessfulAttemptsOnly() {
        let summary = summarize([
            attempt(elapsed: 2, outcome: .succeeded),
            attempt(elapsed: 4, outcome: .succeeded),
            attempt(elapsed: 600, outcome: .failed),
            attempt(elapsed: 900, outcome: .cancelled),
        ])

        XCTAssertEqual(summary.responseTime.sampleCount, 2)
        XCTAssertEqual(summary.responseTime.median!, 3.0, accuracy: 1e-9)
        XCTAssertEqual(summary.responseTime.mean!, 3.0, accuracy: 1e-9)
    }

    /// REJECTED, NOT CLAMPED. A clamped outlier would show up as a boundary
    /// sample and drag the median toward it while `n` still looked honest.
    func testOutOfRangeTimingIsRejectedRatherThanClamped() {
        let summary = summarize([
            attempt(elapsed: 10, outcome: .succeeded),
            attempt(elapsed: grace + 1, outcome: .succeeded),
            attempt(elapsed: -5, outcome: .succeeded),
        ])

        XCTAssertEqual(summary.responseTime.sampleCount, 1)
        XCTAssertEqual(summary.responseTime.median!, 10.0, accuracy: 1e-9)
    }

    func testTimingExactlyAtTheGraceIsAccepted() {
        let summary = summarize([attempt(elapsed: grace, outcome: .succeeded)])

        XCTAssertEqual(summary.responseTime.sampleCount, 1)
        XCTAssertEqual(summary.responseTime.median!, grace, accuracy: 1e-9)
    }

    func testAttemptWithNoCompletionStampContributesNoSample() {
        let summary = summarize([attempt(elapsed: nil, outcome: .succeeded)])

        XCTAssertEqual(summary.responseTime.sampleCount, 0)
        XCTAssertNil(summary.responseTime.median)
    }

    /// p90 is withheld below the minimum sample count, where it is
    /// interpolating between the two slowest observations and would read as
    /// precision it does not have. The median is still shown.
    func testP90IsWithheldBelowTheMinimumSampleCount() {
        let below = (1...(GatewayUsageAggregator.p90MinimumSamples - 1)).map {
            attempt(elapsed: TimeInterval($0), outcome: .succeeded)
        }
        let belowSummary = summarize(below)
        XCTAssertEqual(belowSummary.responseTime.sampleCount, 19)
        XCTAssertNil(belowSummary.responseTime.p90)
        XCTAssertNotNil(belowSummary.responseTime.median)

        let at = (1...GatewayUsageAggregator.p90MinimumSamples).map {
            attempt(elapsed: TimeInterval($0), outcome: .succeeded)
        }
        let atSummary = summarize(at)
        XCTAssertEqual(atSummary.responseTime.sampleCount, 20)
        XCTAssertEqual(atSummary.responseTime.p90!, 18.1, accuracy: 1e-9)
        XCTAssertEqual(atSummary.responseTime.median!, 10.5, accuracy: 1e-9)
    }

    // MARK: - 6. Truncation

    func testTruncationCountsTheLengthFinishReasonCaseInsensitively() {
        let summary = summarize([
            attempt(outcome: .succeeded, finishReason: "length"),
            attempt(outcome: .succeeded, finishReason: "LENGTH"),
            attempt(outcome: .succeeded, finishReason: "stop"),
            attempt(outcome: .succeeded, finishReason: nil),
        ])

        XCTAssertEqual(summary.truncatedReplies, 2)
    }

    func testNoTruncationIsZeroNotUnavailable() {
        let summary = summarize([attempt(outcome: .succeeded, finishReason: "stop")])
        XCTAssertEqual(summary.truncatedReplies, 0)
    }

    // MARK: - 7. Daily activity buckets

    func testDailyBucketsSpanTheRequestedWindowWithGapsFilled() {
        let today = calendar.startOfDay(for: now)
        let threeDaysAgo = calendar.date(byAdding: .day, value: -3, to: today)!
        let turn = UUID()

        let summary = summarize(
            [
                attempt(turn: turn, startedAt: threeDaysAgo.addingTimeInterval(3600)),
                attempt(turn: turn, startedAt: threeDaysAgo.addingTimeInterval(7200)),
                attempt(startedAt: today.addingTimeInterval(60)),
            ],
            range: threeDaysAgo...now
        )

        XCTAssertEqual(summary.dailyActivity.count, 4, "four whole days, gaps included")
        XCTAssertEqual(summary.dailyActivity[0].day, threeDaysAgo)
        XCTAssertEqual(summary.dailyActivity[0].attempts, 2)
        XCTAssertEqual(summary.dailyActivity[0].turns, 1, "two attempts on one turn is one turn")
        XCTAssertEqual(summary.dailyActivity[1].attempts, 0)
        XCTAssertEqual(summary.dailyActivity[2].attempts, 0)
        XCTAssertEqual(summary.dailyActivity[3].attempts, 1)
    }

    /// With no window supplied the buckets span only the observed days.
    func testDailyBucketsWithoutARangeSpanTheObservedDays() {
        let today = calendar.startOfDay(for: now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!

        let summary = summarize([
            attempt(startedAt: yesterday.addingTimeInterval(120)),
            attempt(startedAt: today.addingTimeInterval(120)),
        ])

        XCTAssertEqual(summary.dailyActivity.count, 2)
        XCTAssertEqual(summary.dailyActivity.first?.day, yesterday)
        XCTAssertEqual(summary.dailyActivity.last?.day, today)
    }

    /// An attempt that cannot say when it began is counted in the range totals
    /// and drawn on no day. Assigning it to "today" would move a bar that
    /// describes a day it has nothing to do with.
    func testAttemptWithoutAStartInstantLandsInNoBucket() {
        let record = GatewayAttemptRecord(
            id: UUID(),
            conversationID: UUID(),
            userMessageID: UUID(),
            gatewayRef: "openclaw",
            startedAt: nil,
            completedAt: nil,
            outcome: .succeeded
        )
        let summary = summarize([record], range: now...now)

        XCTAssertEqual(summary.recordedAttempts, 1)
        XCTAssertEqual(summary.dailyActivity.count, 1)
        XCTAssertEqual(summary.dailyActivity[0].attempts, 0)
    }

    /// GOLDEN, MIDNIGHT TRANSITION. Santiago springs forward at 00:00 on
    /// 2026-09-06, so local midnight does not exist that day and `startOfDay`
    /// returns 01:00. A bucket walk that adds a day without re-anchoring keeps
    /// that 01:00 for every later day, matches none of the 00:00 lookup keys,
    /// and stops short of a `lastDay` that is 00:00 — three real days of
    /// activity drawn empty and today's bar missing, while the Turns tile
    /// beside the chart still says seven.
    func testDailyBucketsSurviveAMidnightDaylightSavingTransition() {
        let santiago = calendar(in: "America/Santiago")
        func noon(_ day: Int) -> Date {
            santiago.date(from: DateComponents(year: 2026, month: 9, day: day, hour: 12))!
        }

        let days = Array(4...10)
        let summary = summarize(
            days.map { attempt(startedAt: noon($0)) },
            range: santiago.startOfDay(for: noon(4))...noon(10),
            calendar: santiago,
            now: noon(10)
        )

        XCTAssertEqual(summary.dailyActivity.count, 7, "one bucket per local day, transition included")
        XCTAssertEqual(
            summary.dailyActivity.map(\.attempts), Array(repeating: 1, count: 7),
            "every day's attempt lands in its own bucket")
        XCTAssertEqual(
            summary.dailyActivity.map(\.day), days.map { santiago.startOfDay(for: noon($0)) },
            "each bucket is anchored on its own day's start, not on a drifting wall clock")
    }

    /// The ordinary 02:00 transition, which fixed 86400-second arithmetic gets
    /// wrong even though `startOfDay` stays at midnight either side of it.
    func testDailyBucketsSurviveAnOrdinaryDaylightSavingTransition() {
        let berlin = calendar(in: "Europe/Berlin")
        func noon(_ day: Int) -> Date {
            berlin.date(from: DateComponents(year: 2026, month: 3, day: day, hour: 12))!
        }

        let days = Array(27...31)
        let summary = summarize(
            days.map { attempt(startedAt: noon($0)) },
            range: berlin.startOfDay(for: noon(27))...noon(31),
            calendar: berlin,
            now: noon(31)
        )

        XCTAssertEqual(summary.dailyActivity.count, 5)
        XCTAssertEqual(summary.dailyActivity.map(\.attempts), Array(repeating: 1, count: 5))
        XCTAssertEqual(
            summary.dailyActivity.map(\.day), days.map { berlin.startOfDay(for: noon($0)) },
            "the short day is still one bucket, and the days after it do not shift")
    }

    /// A nonsense window — a corrupt stored date, a device with a wildly wrong
    /// clock — costs a bounded array rather than a hang.
    func testDailyBucketGenerationIsBounded() {
        let farPast = calendar.date(byAdding: .year, value: -200, to: now)!
        let summary = summarize([attempt(outcome: .succeeded)], range: farPast...now)

        XCTAssertEqual(summary.dailyActivity.count, GatewayUsageAggregator.maxDailyBuckets)
    }

    // MARK: - 8. Grouping

    func testGatewayGroupsAreOrderedByAttemptsAndCarryTheirOwnRates() {
        let summary = summarize([
            attempt(gateway: "openclaw", outcome: .succeeded, requestedModel: "m1"),
            attempt(gateway: "openclaw", outcome: .failed, requestedModel: "m1"),
            attempt(gateway: "openclaw", outcome: .succeeded, requestedModel: "m1"),
            attempt(gateway: "hermes", outcome: .succeeded, requestedModel: "m2"),
        ])

        XCTAssertEqual(summary.byGateway.map(\.key), ["openclaw", "hermes"])
        let openclaw = summary.byGateway[0]
        XCTAssertEqual(openclaw.attempts, 3)
        XCTAssertEqual(openclaw.succeeded, 2)
        XCTAssertEqual(openclaw.failed, 1)
        XCTAssertEqual(openclaw.successRate!, 2.0 / 3.0, accuracy: 1e-9)
        XCTAssertTrue(openclaw.models.isEmpty, "one model needs no breakdown")
    }

    func testGatewayGroupBreaksOutModelsOnlyWhenMoreThanOneWasRequested() {
        let summary = summarize([
            attempt(gateway: "openclaw", outcome: .succeeded, requestedModel: "fast"),
            attempt(gateway: "openclaw", outcome: .succeeded, requestedModel: "fast"),
            attempt(gateway: "openclaw", outcome: .failed, requestedModel: "slow"),
        ])

        let openclaw = summary.byGateway[0]
        XCTAssertEqual(openclaw.models.map(\.key), ["fast", "slow"])
        XCTAssertEqual(openclaw.models[0].attempts, 2)
        XCTAssertEqual(openclaw.models[1].attempts, 1)
    }

    /// A request that carried no model — the gateway's own default answered —
    /// is its own honest group, never merged into whichever key sorts first.
    func testUnrecordedGatewayAndModelKeepTheirOwnGroup() {
        let summary = summarize([
            attempt(gateway: nil, outcome: .succeeded),
            attempt(gateway: "openclaw", outcome: .succeeded),
            attempt(gateway: "openclaw", outcome: .succeeded),
        ])

        XCTAssertEqual(summary.byGateway.count, 2)
        XCTAssertEqual(summary.byGateway[0].key, "openclaw")
        XCTAssertNil(summary.byGateway[1].key)
        XCTAssertEqual(summary.byRequestedModel.count, 1)
        XCTAssertNil(summary.byRequestedModel[0].key)
        XCTAssertEqual(summary.byRequestedModel[0].attempts, 3)
    }

    /// Group identity is stable and the unattributed group cannot collide with
    /// a real ref — a `RemoteAgentRef` raw string carries no control scalar.
    func testUnattributedGroupHasAStableNonCollidingIdentity() {
        let summary = summarize([attempt(gateway: nil, outcome: .succeeded)])
        XCTAssertEqual(summary.byGateway[0].id, "\u{1}unattributed")
    }

    func testModelGroupsSpanEveryGateway() {
        let summary = summarize([
            attempt(gateway: "openclaw", outcome: .succeeded, requestedModel: "shared"),
            attempt(gateway: "hermes", outcome: .succeeded, requestedModel: "shared"),
            attempt(gateway: "hermes", outcome: .failed, requestedModel: "other"),
        ])

        XCTAssertEqual(summary.byRequestedModel.map(\.key), ["shared", "other"])
        XCTAssertEqual(summary.byRequestedModel[0].attempts, 2)
    }

    /// Group token sums use the same terminal denominator as the range total.
    func testGroupTokensUseTheSameCoverageRule() {
        let liveID = UUID()
        let summary = summarize(
            [
                attempt(gateway: "openclaw", outcome: .succeeded, input: 10),
                attempt(gateway: "openclaw", outcome: .failed),
                attempt(id: liveID, gateway: "openclaw", outcome: .inFlight, input: 500),
            ],
            live: [liveID]
        )

        let openclaw = summary.byGateway[0]
        XCTAssertEqual(openclaw.attempts, 3)
        XCTAssertEqual(openclaw.tokens.input.sum, 10)
        XCTAssertEqual(openclaw.tokens.input.coverageDenominator, 2)
        XCTAssertEqual(openclaw.tokens.input.coverage!, 0.5, accuracy: 1e-9)
    }
}
