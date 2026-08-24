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

    /// The four attachment counts default to NIL, i.e. an unmeasured row —
    /// passing any of them opts the fixture into the v12 measurement, exactly
    /// as a real row written by a client that counts them does.
    private func attempt(
        id: UUID = UUID(),
        conversation: UUID? = UUID(),
        turn: UUID? = UUID(),
        gateway: String? = "openclaw",
        startedAt: Date? = nil,
        elapsed: TimeInterval? = nil,
        outcome: GatewayAttemptOutcome = .succeeded,
        appErrorCode: Int? = nil,
        origin: GatewayAttemptOrigin = .unknown,
        inputMode: GatewayInputMode = .unknown,
        requestedModel: String? = nil,
        finishReason: String? = nil,
        input: Int64? = nil,
        output: Int64? = nil,
        total: Int64? = nil,
        deviceClass: String? = nil,
        fallbackSourceDevice: String? = nil,
        currentImages: Int? = nil,
        priorImages: Int? = nil,
        currentFiles: Int? = nil,
        priorFiles: Int? = nil
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
            appErrorCode: appErrorCode,
            origin: origin,
            inputMode: inputMode,
            requestedModel: requestedModel,
            finishReason: finishReason,
            reportedInputTokens: input,
            reportedOutputTokens: output,
            reportedTotalTokens: total,
            originDeviceClass: deviceClass,
            currentTurnInlineImageCount: currentImages,
            priorTurnInlineImageCount: priorImages,
            currentTurnInlineTextFileCount: currentFiles,
            priorTurnInlineTextFileCount: priorFiles,
            fallbackSourceDevice: fallbackSourceDevice
        )
    }

    /// The device bucket one fixture row derives to — the derivation table below
    /// is the whole point of the helper.
    private func bucket(
        origin: GatewayAttemptOrigin,
        deviceClass: String? = nil,
        fallback: String? = nil
    ) -> UsageDeviceBucket {
        UsageDeviceBucket.from(
            record: attempt(
                origin: origin, deviceClass: deviceClass, fallbackSourceDevice: fallback))
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

    func testThreadsWithUsageCountsDistinctConversations() {
        let one = UUID(), two = UUID()
        let summary = summarize([
            attempt(conversation: one),
            attempt(conversation: one),
            attempt(conversation: two),
        ])

        XCTAssertEqual(summary.threadsWithUsage, 2)
    }

    /// USAGE OUTLIVES THE CONVERSATION IT DESCRIBES. The aggregator is never
    /// told which threads are still live — deleting a conversation leaves its
    /// rows behind, and they count here exactly as a live thread's do. A count
    /// named for live threads would become a lie the moment one was deleted,
    /// which is why the field is not called that.
    func testThreadsWithUsageIncludesAThreadTheUserHasDeleted() {
        let live = UUID(), deleted = UUID()
        let summary = summarize([
            attempt(conversation: live, outcome: .succeeded, total: 10),
            attempt(conversation: deleted, outcome: .succeeded, total: 90),
            attempt(conversation: deleted, outcome: .succeeded, total: 5),
        ])

        XCTAssertEqual(summary.threadsWithUsage, 2)
        XCTAssertEqual(
            summary.threadRanking.threads.map(\.conversationID), [deleted, live],
            "a deleted thread still ranks — the ledger is the only record of it left")
        XCTAssertEqual(summary.threadRanking.threads[0].rankedTokens, 95)
    }

    /// A row that recorded no conversation is a real attempt: it counts in the
    /// range totals and in every group, and belongs to no thread. Inventing a
    /// thread for it would put a row on screen nothing can navigate to.
    func testUnattributedRowsCountInTotalsAndGroupsButNeverInAThread() {
        let thread = UUID()
        let summary = summarize([
            attempt(
                conversation: nil, gateway: "hermes", outcome: .succeeded, origin: .app,
                total: 5_000, deviceClass: "mac"),
            attempt(conversation: thread, gateway: "openclaw", outcome: .succeeded, total: 10),
        ])

        XCTAssertEqual(summary.recordedAttempts, 2)
        XCTAssertEqual(summary.threadsWithUsage, 1)
        XCTAssertEqual(summary.tokens.reportedTotal.sum, 5_010)
        XCTAssertEqual(summary.byGateway.count, 2)
        XCTAssertEqual(summary.deviceGroups.map(\.key), ["mac", "unknown"])
        XCTAssertEqual(summary.threadRanking.threads.map(\.conversationID), [thread])
        XCTAssertEqual(
            summary.largestTurns.count, 1,
            "the heavier unattributed turn cannot be listed — it navigates nowhere")
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

    // MARK: - 7b. Per-day metrics behind the chart's metric picker

    /// HAND-COMPUTED. One day, three attempts: a gateway that reported a total,
    /// a gateway that reported only components, and one that reported nothing.
    /// 1000 + (300 + 200) + nothing = 1500, over two measuring attempts of
    /// three — the coverage figure the caption needs to keep 1500 honest.
    ///
    /// A day is allowed to mix the two token bases because it is a VOLUME, not
    /// a ranking: nothing here is ordered against anything, so preferring each
    /// attempt's own best evidence loses no comparability. The ranked lists
    /// keep their single pinned basis.
    func testDailyTokensTakeTheBestAvailableFigurePerAttempt() {
        let today = calendar.startOfDay(for: now)
        let summary = summarize(
            [
                attempt(startedAt: today.addingTimeInterval(3600), total: 1_000),
                attempt(startedAt: today.addingTimeInterval(7200), input: 300, output: 200),
                attempt(startedAt: today.addingTimeInterval(10_800)),
            ],
            range: today...now
        )

        XCTAssertEqual(summary.dailyActivity.count, 1)
        let day = summary.dailyActivity[0]
        XCTAssertEqual(day.attempts, 3)
        XCTAssertEqual(
            day.reportedTokens, 1_500,
            "a reported total, plus a calculated pair, plus nothing at all")
        XCTAssertEqual(
            day.tokenMeasuredAttempts, 2,
            "the attempt that reported nothing is not coverage for the two that did")
    }

    /// ONE COMPONENT IS NOT A FIGURE. An attempt reporting input but no output
    /// has not said what the turn cost, and adding its half to a day beside
    /// attempts that reported both would make a day look cheap in proportion to
    /// how chatty its gateways were about their own accounting.
    func testDailyTokensIgnoreAnAttemptThatReportedOnlyOneComponent() {
        let today = calendar.startOfDay(for: now)
        let summary = summarize(
            [
                attempt(startedAt: today.addingTimeInterval(3600), input: 400),
                attempt(startedAt: today.addingTimeInterval(7200), output: 50),
            ],
            range: today...now
        )

        let day = summary.dailyActivity[0]
        XCTAssertEqual(day.attempts, 2)
        XCTAssertEqual(day.reportedTokens, 0)
        XCTAssertEqual(
            day.tokenMeasuredAttempts, 0,
            "zero tokens over zero measuring attempts is 'nobody said', not 'it was free'")
    }

    /// A day whose gateways reported no usage at all reads zero over zero
    /// coverage — which is what stops the chart from drawing it as a free day
    /// beside a day that genuinely cost nothing.
    func testADayWithNoTokenEvidenceCarriesZeroCoverage() {
        let today = calendar.startOfDay(for: now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!
        let summary = summarize(
            [
                attempt(startedAt: yesterday.addingTimeInterval(3600), total: 800),
                attempt(startedAt: today.addingTimeInterval(3600)),
            ],
            range: yesterday...now
        )

        XCTAssertEqual(summary.dailyActivity.count, 2)
        XCTAssertEqual(summary.dailyActivity[0].reportedTokens, 800)
        XCTAssertEqual(summary.dailyActivity[0].tokenMeasuredAttempts, 1)
        XCTAssertEqual(summary.dailyActivity[1].attempts, 1, "the day still had activity")
        XCTAssertEqual(summary.dailyActivity[1].reportedTokens, 0)
        XCTAssertEqual(summary.dailyActivity[1].tokenMeasuredAttempts, 0)
    }

    /// THE DENOMINATOR THE CHART DIVIDES BY. Five attempts on one day: two
    /// succeeded, one failed, one cancelled, one unclassifiable. Only the first
    /// three are resolved — a cancellation is a turn the user stopped, and
    /// counting it as a loss would draw a 40% day where the real answer is 67%.
    func testDailyReliabilityExcludesCancelledAndUnknownFromTheDenominator() {
        let today = calendar.startOfDay(for: now)
        let summary = summarize(
            [
                attempt(startedAt: today.addingTimeInterval(3600), outcome: .succeeded),
                attempt(startedAt: today.addingTimeInterval(3660), outcome: .succeeded),
                attempt(startedAt: today.addingTimeInterval(3720), outcome: .failed),
                attempt(startedAt: today.addingTimeInterval(3780), outcome: .cancelled),
                attempt(startedAt: today.addingTimeInterval(3840), outcome: .unknown),
            ],
            range: today...now
        )

        let day = summary.dailyActivity[0]
        XCTAssertEqual(day.attempts, 5)
        XCTAssertEqual(day.resolvedAttempts, 3, "succeeded + failed only")
        XCTAssertEqual(day.succeededAttempts, 2)
        XCTAssertEqual(
            summary.resolvedAttemptSuccessRate!, 2.0 / 3.0, accuracy: 1e-9,
            "the day's bar and the range's headline divide by the same population")
    }

    /// A DAY OF NOTHING BUT CANCELLATIONS HAS NO BAR, not a bar at zero. The
    /// chart reads `resolvedAttempts == 0` as absence of evidence, and that is
    /// only true if a cancellation never reaches the denominator.
    func testADayOfOnlyCancellationsResolvesNothing() {
        let today = calendar.startOfDay(for: now)
        let summary = summarize(
            [attempt(startedAt: today.addingTimeInterval(3600), outcome: .cancelled)],
            range: today...now
        )

        let day = summary.dailyActivity[0]
        XCTAssertEqual(day.attempts, 1)
        XCTAssertEqual(day.resolvedAttempts, 0)
        XCTAssertEqual(day.succeededAttempts, 0)
    }

    /// An open row past the grace is `unconfirmed` — missing evidence about
    /// THIS device, not a verdict — so it is in neither the day's reliability
    /// denominator nor its token coverage, exactly as it is in neither range
    /// total. Its token columns are ignored along with it: a row that has not
    /// ended has not had its chance to report.
    func testDailyMetricsExcludeAnUnconfirmedAttemptEntirely() {
        let today = calendar.startOfDay(for: now)
        let summary = summarize(
            [
                attempt(startedAt: today.addingTimeInterval(3600), outcome: .succeeded, total: 100),
                attempt(
                    startedAt: now.addingTimeInterval(-(grace + 1)),
                    outcome: .inFlight,
                    total: 999
                ),
            ],
            range: today...now
        )

        XCTAssertEqual(summary.outcomeMix.unconfirmed, 1, "fixture precondition")
        let day = summary.dailyActivity[0]
        XCTAssertEqual(day.attempts, 2, "an unconfirmed attempt still happened")
        XCTAssertEqual(day.resolvedAttempts, 1)
        XCTAssertEqual(day.succeededAttempts, 1)
        XCTAssertEqual(day.reportedTokens, 100, "999 belongs to a row that has not landed")
        XCTAssertEqual(day.tokenMeasuredAttempts, 1)
    }

    /// Gap days are silent on every metric, which is what makes them safe to
    /// draw: no bar for turns, no bar for tokens, and — because
    /// `resolvedAttempts` is zero — no reliability bar either, rather than a
    /// 0% day the user never had.
    func testGapDaysCarryZeroInEveryMetric() {
        let today = calendar.startOfDay(for: now)
        let threeDaysAgo = calendar.date(byAdding: .day, value: -3, to: today)!
        let summary = summarize(
            [
                attempt(
                    startedAt: threeDaysAgo.addingTimeInterval(3600),
                    outcome: .succeeded,
                    total: 700
                )
            ],
            range: threeDaysAgo...now
        )

        XCTAssertEqual(summary.dailyActivity.count, 4)
        XCTAssertEqual(summary.dailyActivity[0].resolvedAttempts, 1)
        XCTAssertEqual(summary.dailyActivity[0].reportedTokens, 700)
        for index in 1...3 {
            let gap = summary.dailyActivity[index]
            XCTAssertEqual(gap.attempts, 0)
            XCTAssertEqual(gap.turns, 0)
            XCTAssertEqual(gap.resolvedAttempts, 0, "no bar, not a failing bar")
            XCTAssertEqual(gap.succeededAttempts, 0)
            XCTAssertEqual(gap.reportedTokens, 0)
            XCTAssertEqual(gap.tokenMeasuredAttempts, 0)
        }
    }

    /// THE MIDNIGHT TRANSITION, FOR THE NEW METRICS TOO. The re-anchoring bug
    /// this file already guards for attempts would move tokens and successes
    /// onto the wrong bars just as readily — and a reliability chart drawn one
    /// day out is harder to notice than a missing bar, because every bar is
    /// still full height.
    func testDailyMetricsLandOnTheirOwnDayAcrossAMidnightTransition() {
        let santiago = calendar(in: "America/Santiago")
        func noon(_ day: Int) -> Date {
            santiago.date(from: DateComponents(year: 2026, month: 9, day: day, hour: 12))!
        }

        let days = Array(4...10)
        let summary = summarize(
            days.map { attempt(startedAt: noon($0), outcome: .succeeded, total: Int64($0 * 100)) },
            range: santiago.startOfDay(for: noon(4))...noon(10),
            calendar: santiago,
            now: noon(10)
        )

        XCTAssertEqual(summary.dailyActivity.count, 7)
        XCTAssertEqual(
            summary.dailyActivity.map(\.reportedTokens), days.map { $0 * 100 },
            "each day's tokens stay on the day that spent them")
        XCTAssertEqual(
            summary.dailyActivity.map(\.resolvedAttempts), Array(repeating: 1, count: 7))
        XCTAssertEqual(
            summary.dailyActivity.map(\.succeededAttempts), Array(repeating: 1, count: 7),
            "a green day either side of the transition, and a green day on it")
        XCTAssertEqual(
            summary.dailyActivity.map(\.tokenMeasuredAttempts), Array(repeating: 1, count: 7))
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

    // MARK: - 9. Turn reliability

    /// Four turns, one of each shape, over the same seven attempts — every
    /// figure below is a different slice, and a formula that reached for the
    /// wrong denominator still produces a plausible number.
    func testReliabilityCountsOnlyTurnsWhoseFinalAttemptIsTerminal() {
        let base = now.addingTimeInterval(-3600)
        let turnA = UUID(), turnB = UUID(), turnC = UUID(), turnD = UUID()
        let liveID = UUID()

        let summary = summarize(
            [
                // A: delivered on the first try.
                attempt(turn: turnA, startedAt: base, outcome: .succeeded),
                // B: failed, retried, recovered.
                attempt(turn: turnB, startedAt: base, outcome: .failed),
                attempt(turn: turnB, startedAt: base.addingTimeInterval(60), outcome: .succeeded),
                // C: failed twice and stayed failed.
                attempt(turn: turnC, startedAt: base, outcome: .failed),
                attempt(turn: turnC, startedAt: base.addingTimeInterval(60), outcome: .failed),
                // D: retry still running on this device — no outcome yet.
                attempt(turn: turnD, startedAt: base, outcome: .failed),
                attempt(
                    id: liveID, turn: turnD, startedAt: base.addingTimeInterval(60),
                    outcome: .inFlight),
            ],
            live: [liveID]
        )

        XCTAssertEqual(summary.resolvedTurns, 3, "D is still being retried")
        XCTAssertEqual(summary.firstAttemptDeliveredTurns, 1)
        XCTAssertEqual(summary.resolvedRetriedTurns, 2, "B and C")
        XCTAssertEqual(summary.retriedTurnsRecovered, 1, "B only")
        XCTAssertEqual(
            summary.retriedTurns, 3,
            "the shipped retry count spans every attempted turn, D included")
        XCTAssertEqual(summary.attemptedTurns, 4)
    }

    /// A turn is resolved by its FINAL attempt, not its best one. A retry
    /// dispatched after a success — a duplicate send, a user who tapped again —
    /// leaves the turn unresolved until that retry lands.
    func testATurnIsResolvedByItsFinalAttemptNotItsBestOne() {
        let base = now.addingTimeInterval(-3600)
        let turn = UUID()
        let liveID = UUID()

        let summary = summarize(
            [
                attempt(turn: turn, startedAt: base, outcome: .succeeded),
                attempt(
                    id: liveID, turn: turn, startedAt: base.addingTimeInterval(30),
                    outcome: .inFlight),
            ],
            live: [liveID]
        )

        XCTAssertEqual(summary.resolvedTurns, 0)
        XCTAssertEqual(summary.firstAttemptDeliveredTurns, 0)
        XCTAssertEqual(summary.retriedTurnsRecovered, 0)
    }

    /// A row that cannot say when it ran sorts LAST within its turn. It can
    /// never be claimed as the first try, and treating it as the final one stops
    /// a turn being called resolved on the strength of an earlier row.
    func testAttemptWithNoStartInstantIsTreatedAsTheFinalTry() {
        let turn = UUID()
        let undated = GatewayAttemptRecord(
            id: UUID(),
            conversationID: UUID(),
            userMessageID: turn,
            gatewayRef: "openclaw",
            startedAt: nil,
            completedAt: nil,
            outcome: .inFlight
        )
        let summary = summarize([
            attempt(turn: turn, startedAt: now.addingTimeInterval(-600), outcome: .succeeded),
            undated,
        ])

        XCTAssertEqual(summary.resolvedTurns, 0)
        XCTAssertEqual(summary.outcomeMix.unconfirmed, 1)
    }

    /// Every reliability count is a plain zero on an empty range, and the rates
    /// built from them are the UI's problem, not a nil hidden in a count.
    func testReliabilityCountsAreZeroOnAnEmptyRange() {
        let summary = summarize([])

        XCTAssertEqual(summary.resolvedTurns, 0)
        XCTAssertEqual(summary.firstAttemptDeliveredTurns, 0)
        XCTAssertEqual(summary.resolvedRetriedTurns, 0)
        XCTAssertEqual(summary.retriedTurnsRecovered, 0)
    }

    // MARK: - 10. Failure reasons

    /// FAILED attempts only, commonest first, by Conduck's own error code —
    /// never a provider message or status, neither of which the ledger stores.
    func testFailureReasonsCountFailedAttemptsByCode() {
        let summary = summarize([
            attempt(outcome: .failed, appErrorCode: 42),
            attempt(outcome: .failed, appErrorCode: 42),
            attempt(outcome: .failed, appErrorCode: 7),
            attempt(outcome: .succeeded, appErrorCode: 99),
            attempt(outcome: .cancelled, appErrorCode: 99),
        ])

        XCTAssertEqual(summary.failureReasons.map(\.appErrorCode), [42, 7])
        XCTAssertEqual(summary.failureReasons.map(\.count), [2, 1])
    }

    /// A failure whose code was never recorded is left out rather than bucketed
    /// as a nameless reason, which would be the largest row on any older range
    /// while explaining nothing.
    func testFailureWithNoRecordedCodeIsNotListedAsAReason() {
        let summary = summarize([
            attempt(outcome: .failed, appErrorCode: nil),
            attempt(outcome: .failed, appErrorCode: 5),
        ])

        XCTAssertEqual(summary.failureReasons.map(\.appErrorCode), [5])
        XCTAssertEqual(summary.outcomeMix.failed, 2, "both still count as failures")
    }

    /// Equal counts order on the code, so a redraw never reshuffles two rows.
    func testFailureReasonTiesOrderOnTheCode() {
        let summary = summarize([
            attempt(outcome: .failed, appErrorCode: 900),
            attempt(outcome: .failed, appErrorCode: 100),
        ])

        XCTAssertEqual(summary.failureReasons.map(\.appErrorCode), [100, 900])
    }

    func testNoFailuresYieldsNoReasons() {
        XCTAssertTrue(summarize([attempt(outcome: .succeeded)]).failureReasons.isEmpty)
    }

    // MARK: - 11. Input modes

    func testInputModesSeparateAttemptsFromTurns() {
        let voiceTurn = UUID()
        let summary = summarize([
            attempt(turn: voiceTurn, outcome: .failed, inputMode: .voice),
            attempt(turn: voiceTurn, outcome: .succeeded, inputMode: .voice),
            attempt(inputMode: .text),
            attempt(inputMode: .shared),
        ])

        XCTAssertEqual(summary.inputModes.map(\.mode), [.voice, .shared, .text])
        XCTAssertEqual(summary.inputModes[0].attempts, 2)
        XCTAssertEqual(summary.inputModes[0].turns, 1, "two attempts on one turn is one turn")
        XCTAssertEqual(summary.inputModes[1].attempts, 1)
    }

    /// Turns that predate mode capture are their own bucket. Dropping them would
    /// make the known modes add up to a whole they are not.
    func testUnknownInputModeIsItsOwnBucket() {
        let summary = summarize([
            attempt(inputMode: .unknown),
            attempt(inputMode: .voice),
        ])

        XCTAssertEqual(Set(summary.inputModes.map(\.mode)), [.unknown, .voice])
    }

    // MARK: - 12. Device buckets

    /// THE DERIVATION TABLE. Dedicated surfaces first, then the class the
    /// dispatching device stamped, then the parent turn's tag, then honest
    /// ignorance.
    func testDeviceBucketDerivation() {
        // A CarPlay dispatch runs on the iPhone and stamps `iphone`; the surface
        // is what the user is asking about, so it wins.
        XCTAssertEqual(bucket(origin: .carPlay, deviceClass: "iphone"), .carPlay)
        XCTAssertEqual(bucket(origin: .watch, deviceClass: nil), .watch)
        XCTAssertEqual(bucket(origin: .watch, deviceClass: "iphone"), .watch)

        // Ordinary surfaces defer to the stamped class.
        XCTAssertEqual(bucket(origin: .app, deviceClass: "iphone"), .iphone)
        XCTAssertEqual(bucket(origin: .app, deviceClass: "ipad"), .ipad)
        XCTAssertEqual(bucket(origin: .menuBar, deviceClass: "mac"), .mac)
        XCTAssertEqual(bucket(origin: .quickCapture, deviceClass: "iphone"), .iphone)
        XCTAssertEqual(bucket(origin: .share, deviceClass: "mac"), .mac)

        // Rows written before the class existed fall back to the turn's tag.
        XCTAssertEqual(bucket(origin: .app, fallback: "iphone-voice"), .iphone)
        XCTAssertEqual(bucket(origin: .app, fallback: "mac"), .mac)
        XCTAssertEqual(bucket(origin: .app, fallback: "carplay-voice"), .carPlay)

        // The stamped class outranks the fallback — the retry device is the one
        // that ran this dispatch, whatever produced the original turn.
        XCTAssertEqual(bucket(origin: .app, deviceClass: "mac", fallback: "iphone-text"), .mac)

        // Anything unrecognised is its own bucket, never folded into the
        // commonest one.
        XCTAssertEqual(bucket(origin: .app, deviceClass: "vision"), .unknown)
        XCTAssertEqual(bucket(origin: .app, fallback: "toaster-voice"), .unknown)
        XCTAssertEqual(bucket(origin: .unknown), .unknown)
        XCTAssertEqual(bucket(origin: .app, deviceClass: "iPhone"), .iphone, "case tolerant")
    }

    func testDeviceGroupsAreKeyedByBucketAndCarryTheirOwnRates() {
        let summary = summarize([
            attempt(outcome: .succeeded, origin: .app, deviceClass: "iphone"),
            attempt(outcome: .failed, origin: .app, deviceClass: "iphone"),
            attempt(outcome: .succeeded, origin: .carPlay, deviceClass: "iphone"),
            attempt(outcome: .succeeded),
        ])

        XCTAssertEqual(summary.deviceGroups.map(\.key), ["iphone", "carPlay", "unknown"])
        let iphone = summary.deviceGroups[0]
        XCTAssertEqual(iphone.attempts, 2)
        XCTAssertEqual(iphone.successRate!, 0.5, accuracy: 1e-9)
        XCTAssertTrue(iphone.models.isEmpty, "device rows carry no nested model breakdown")
    }

    func testDeviceGroupsCarryTheirOwnResponseTimes() {
        let summary = summarize([
            attempt(elapsed: 2, outcome: .succeeded, origin: .app, deviceClass: "mac"),
            attempt(elapsed: 4, outcome: .succeeded, origin: .app, deviceClass: "mac"),
            attempt(elapsed: 60, outcome: .succeeded, origin: .watch),
        ])

        let mac = summary.deviceGroups.first { $0.key == "mac" }!
        XCTAssertEqual(mac.medianResponseTime!, 3.0, accuracy: 1e-9)
        XCTAssertEqual(mac.responseSampleCount, 2)
        let watch = summary.deviceGroups.first { $0.key == "watch" }!
        XCTAssertEqual(watch.medianResponseTime!, 60.0, accuracy: 1e-9)
    }

    // MARK: - 13. Ranking basis

    /// Gateway-reported totals win wherever ANY thread has one.
    func testThreadRankingPrefersReportedTotals() {
        let heavy = UUID(), light = UUID()
        let summary = summarize([
            attempt(conversation: heavy, outcome: .succeeded, input: 1, output: 1, total: 900),
            attempt(conversation: light, outcome: .succeeded, total: 100),
        ])

        XCTAssertEqual(summary.threadRanking.basis, .reportedTotals)
        XCTAssertEqual(summary.threadRanking.threads.map(\.conversationID), [heavy, light])
        XCTAssertEqual(summary.threadRanking.threads[0].rankedTokens, 900)
    }

    /// With no reported total anywhere in range, the whole list falls back to
    /// calculated components — the fallback is per RANGE, never per thread.
    func testThreadRankingFallsBackToCalculatedComponents() {
        let heavy = UUID(), light = UUID()
        let summary = summarize([
            attempt(conversation: heavy, outcome: .succeeded, input: 100, output: 25),
            attempt(conversation: light, outcome: .succeeded, input: 10, output: 5),
        ])

        XCTAssertEqual(summary.threadRanking.basis, .calculatedComponents)
        XCTAssertEqual(summary.threadRanking.threads.map(\.rankedTokens), [125, 15])
    }

    /// NEVER MIXED, AND THIS IS THE CASE THAT PROVES IT. One thread reported a
    /// small total, another reported large components. Ranking them together
    /// would put the second on top by comparing a client sum against a gateway
    /// figure; instead the basis is totals and the components-only thread is
    /// ABSENT, which is what the section footer tells the user.
    func testMixedReportingRanksOnlyTheThreadsThatAnswerTheChosenBasis() {
        let totalled = UUID(), componentsOnly = UUID()
        let summary = summarize([
            attempt(conversation: totalled, outcome: .succeeded, total: 30),
            attempt(
                conversation: componentsOnly, outcome: .succeeded, input: 5_000, output: 5_000),
        ])

        XCTAssertEqual(summary.threadRanking.basis, .reportedTotals)
        XCTAssertEqual(summary.threadRanking.threads.map(\.conversationID), [totalled])
        XCTAssertEqual(summary.threadRanking.threads[0].rankedTokens, 30)
    }

    /// Neither basis can be answered: no ranking, and no largest turns either.
    func testThreadRankingIsEmptyWhenNothingReportedUsage() {
        let summary = summarize([attempt(outcome: .succeeded), attempt(outcome: .failed)])

        XCTAssertTrue(summary.threadRanking.threads.isEmpty)
        XCTAssertTrue(summary.largestTurns.isEmpty)
    }

    /// One component alone does not qualify. Ranking an input-only sum against
    /// another thread's input+output would order threads by which gateway is
    /// chattier about its own accounting.
    func testCalculatedBasisNeedsBothComponents() {
        let summary = summarize([
            attempt(outcome: .succeeded, input: 400),
            attempt(outcome: .succeeded, output: 400),
        ])

        XCTAssertTrue(summary.threadRanking.threads.isEmpty)
    }

    /// An open attempt's tokens never rank anything — same terminal-only rule
    /// the token fields use, or a thread's rank would move with no new work.
    func testOpenAttemptTokensNeverRankAThread() {
        let liveID = UUID()
        let summary = summarize(
            [attempt(id: liveID, outcome: .inFlight, total: 5_000)], live: [liveID])

        XCTAssertTrue(summary.threadRanking.threads.isEmpty)
    }

    /// A cancelled attempt DID reach a terminal outcome and may have been
    /// billed, so it ranks like a failed one.
    func testTerminalNonSuccessAttemptsStillRank() {
        let summary = summarize([attempt(outcome: .cancelled, total: 70)])

        XCTAssertEqual(summary.threadRanking.threads.first?.rankedTokens, 70)
    }

    // MARK: - 14. Thread rows

    func testThreadUsageSummarisesSpanGatewaysCoverageAndAttachments() {
        let thread = UUID()
        let turnOne = UUID(), turnTwo = UUID()
        let base = now.addingTimeInterval(-7200)

        let summary = summarize([
            attempt(
                conversation: thread, turn: turnOne, gateway: "openclaw", startedAt: base,
                outcome: .failed, total: 10,
                currentImages: 1, priorImages: 0, currentFiles: 0, priorFiles: 0),
            attempt(
                conversation: thread, turn: turnOne, gateway: "openclaw",
                startedAt: base.addingTimeInterval(60), outcome: .succeeded, total: 40,
                currentImages: 1, priorImages: 0, currentFiles: 0, priorFiles: 0),
            // A second turn on a different slot that reported nothing and
            // measured nothing: it moves the spans and the counts, not the sums.
            attempt(
                conversation: thread, turn: turnTwo, gateway: "hermes",
                startedAt: base.addingTimeInterval(120), outcome: .succeeded),
        ])

        let usage = summary.threadRanking.threads[0]
        XCTAssertEqual(usage.conversationID, thread)
        XCTAssertEqual(usage.earliestStart, base)
        XCTAssertEqual(usage.latestStart, base.addingTimeInterval(120))
        XCTAssertEqual(usage.gatewayRefs.count, 2)
        XCTAssertEqual(usage.gatewayRefs[0], "openclaw", "first-seen order, chronologically")
        XCTAssertEqual(usage.gatewayRefs[1], "hermes")
        XCTAssertEqual(usage.attempts, 3)
        XCTAssertEqual(usage.turns, 2)
        XCTAssertEqual(usage.rankedTokens, 50)
        XCTAssertEqual(usage.tokenReportedTurns, 1, "one of two turns reported anything")
        XCTAssertEqual(usage.inlineImageCount, 2)
        XCTAssertEqual(
            usage.inlineTextFileCount, 0,
            "measured and zero is a different claim from unmeasured")
        XCTAssertEqual(usage.attachmentMeasuredAttempts, 2)
    }

    /// Nil, not zero, when no row in the thread measured attachments at all.
    func testThreadAttachmentSumsAreNilWhenNoRowMeasured() {
        let summary = summarize([attempt(outcome: .succeeded, total: 5)])

        let usage = summary.threadRanking.threads[0]
        XCTAssertNil(usage.inlineImageCount)
        XCTAssertNil(usage.inlineTextFileCount)
        XCTAssertEqual(usage.attachmentMeasuredAttempts, 0)
    }

    /// A thread whose rows cannot say when they ran draws no date span, so it is
    /// not ranked — the span would have to be invented.
    func testThreadWithNoStartInstantsIsNotRanked() {
        let undated = GatewayAttemptRecord(
            id: UUID(),
            conversationID: UUID(),
            userMessageID: UUID(),
            gatewayRef: "openclaw",
            startedAt: nil,
            completedAt: nil,
            outcome: .succeeded,
            reportedTotalTokens: 4_000
        )
        let summary = summarize([undated, attempt(outcome: .succeeded, total: 10)])

        XCTAssertEqual(summary.threadRanking.threads.count, 1)
        XCTAssertEqual(summary.threadRanking.threads[0].rankedTokens, 10)
    }

    func testRankedThreadsAreCappedHeaviestFirst() {
        let attempts = (1...60).map { index in
            attempt(conversation: UUID(), outcome: .succeeded, total: Int64(index))
        }
        let summary = summarize(attempts)

        XCTAssertEqual(
            summary.threadRanking.threads.count, GatewayUsageAggregator.maxRankedThreads)
        XCTAssertEqual(summary.threadRanking.threads.first?.rankedTokens, 60)
        XCTAssertEqual(summary.threadRanking.threads.last?.rankedTokens, 11)
    }

    // MARK: - 15. Largest turns

    func testLargestTurnsRankOnTheSameBasisAndSumEveryAttemptOnTheTurn() {
        let thread = UUID()
        let heavy = UUID(), light = UUID()
        let base = now.addingTimeInterval(-1800)

        let summary = summarize([
            attempt(
                conversation: thread, turn: heavy, gateway: "openclaw", startedAt: base,
                outcome: .failed, total: 400,
                currentImages: 2, priorImages: 3, currentFiles: 0, priorFiles: 1),
            attempt(
                conversation: thread, turn: heavy, gateway: "hermes",
                startedAt: base.addingTimeInterval(90), outcome: .succeeded, total: 600),
            attempt(
                conversation: thread, turn: light, startedAt: base.addingTimeInterval(180),
                outcome: .succeeded, total: 30),
        ])

        XCTAssertEqual(summary.largestTurns.map(\.userMessageID), [heavy, light])
        let top = summary.largestTurns[0]
        XCTAssertEqual(top.tokens, 1_000, "a retry that reached the gateway was paid for too")
        XCTAssertEqual(top.basis, .reportedTotals)
        XCTAssertEqual(
            top.startedAt, base, "dated when the user asked, not when the retry landed")
        XCTAssertEqual(top.gatewayRef, "openclaw")
        XCTAssertEqual(top.conversationID, thread)
        XCTAssertEqual(top.inlineImageCount, 5, "current and replayed prior images together")
        XCTAssertEqual(top.inlineTextFileCount, 1)
        XCTAssertNil(summary.largestTurns[1].inlineImageCount)
    }

    func testLargestTurnsAreCappedAtTen() {
        let thread = UUID()
        let attempts = (1...15).map { index in
            attempt(conversation: thread, turn: UUID(), outcome: .succeeded, total: Int64(index))
        }
        let summary = summarize(attempts)

        XCTAssertEqual(summary.largestTurns.count, GatewayUsageAggregator.maxLargestTurns)
        XCTAssertEqual(summary.largestTurns.first?.tokens, 15)
        XCTAssertEqual(summary.largestTurns.last?.tokens, 6)
    }

    /// A turn with no user-message id has no identity to navigate to, and a
    /// turn with no conversation has nowhere to navigate.
    func testTurnsWithoutIdentityAreNotListed() {
        let summary = summarize([
            attempt(turn: nil, outcome: .succeeded, total: 9_000),
            attempt(conversation: nil, outcome: .succeeded, total: 8_000),
            attempt(outcome: .succeeded, total: 5),
        ])

        XCTAssertEqual(summary.largestTurns.map(\.tokens), [5])
    }

    // MARK: - 16. Attachment coverage

    func testAttachmentContextCountsMeasuredRowsAndDistinctTurns() {
        let imageTurn = UUID(), fileTurn = UUID(), plainTurn = UUID()
        let summary = summarize([
            attempt(
                turn: imageTurn, outcome: .failed,
                currentImages: 1, priorImages: 0, currentFiles: 0, priorFiles: 0),
            attempt(
                turn: imageTurn, outcome: .succeeded,
                currentImages: 1, priorImages: 2, currentFiles: 0, priorFiles: 0),
            attempt(
                turn: fileTurn, outcome: .succeeded,
                currentImages: 0, priorImages: 0, currentFiles: 2, priorFiles: 1),
            attempt(
                turn: plainTurn, outcome: .succeeded,
                currentImages: 0, priorImages: 0, currentFiles: 0, priorFiles: 0),
            // Legacy row: measured nothing, and says so.
            attempt(outcome: .succeeded),
        ])

        XCTAssertEqual(summary.recordedAttempts, 5)
        XCTAssertEqual(
            summary.attachmentContext.measuredAttempts, 4,
            "coverage is 4 of 5 recorded attempts")
        XCTAssertEqual(summary.attachmentContext.turnsWithImages, 1, "two attempts, one turn")
        XCTAssertEqual(summary.attachmentContext.turnsWithTextFiles, 1)
        XCTAssertEqual(summary.attachmentContext.replayedImageTotal, 2)
    }

    /// The counts are stamped when the row OPENS, so an attempt that never
    /// landed still measured what it carried — unlike the token fields, which
    /// divide by terminal rows only.
    func testAttachmentsAreMeasuredEvenOnAnAttemptThatNeverLanded() {
        let liveID = UUID()
        let summary = summarize(
            [
                attempt(
                    id: liveID, outcome: .inFlight,
                    currentImages: 2, priorImages: 0, currentFiles: 0, priorFiles: 0)
            ],
            live: [liveID]
        )

        XCTAssertEqual(summary.attachmentContext.measuredAttempts, 1)
        XCTAssertEqual(summary.attachmentContext.turnsWithImages, 1)
        XCTAssertEqual(
            summary.tokens.input.coverageDenominator, 0,
            "tokens still divide by terminal rows only")
    }

    /// A half-materialised mirrored row answers with the columns it has. Partial
    /// evidence is not absent evidence.
    func testHalfMaterialisedAttachmentRowAnswersWithWhatItHas() {
        let summary = summarize([attempt(outcome: .succeeded, currentImages: 3)])

        XCTAssertEqual(summary.attachmentContext.measuredAttempts, 1)
        XCTAssertEqual(summary.attachmentContext.turnsWithImages, 1)
        XCTAssertEqual(summary.attachmentContext.replayedImageTotal, 0)
    }

    func testAttachmentContextIsEmptyWhenNothingMeasured() {
        let summary = summarize([attempt(outcome: .succeeded)])

        XCTAssertTrue(summary.attachmentContext.isEmpty)
        XCTAssertEqual(summary.attachmentContext.turnsWithImages, 0)
    }
}
