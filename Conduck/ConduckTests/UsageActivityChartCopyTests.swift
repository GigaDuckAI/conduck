// SPDX-License-Identifier: Apache-2.0

// Conduck
// UsageActivityChartCopyTests.swift
//
// Locks the two pure pieces of the usage chart that decide what a user is told
// about ONE period: the stack's segment ranking, and the sentence the caption
// prints — which is the same sentence VoiceOver reads out of the audio graph.
//
// WHY THE SENTENCE IS WORTH A TEST AND A RENDERED CHART IS NOT. Every honesty
// rule on this chart is a wording rule: a period that measured no tokens must
// not print "0 tokens", a period that resolved nothing must not print "0 of 0
// succeeded", and a period nobody used must say so rather than reading as five
// different kinds of zero. None of that is observable from the bars, all of it
// is observable from these functions, and the caption and the descriptor share
// them precisely so the two readings cannot drift apart.
//
// WHY THE RANKING IS WORTH A TEST. The stack's colours are fixed from the
// RANGE's totals and held across every period; if that ordering were derived
// per period instead, two bars of the same height would mean different things
// and nothing would fail.
//
// Pure Foundation: everything here takes values and returns strings or
// segments, so nothing renders a view.

import XCTest

@testable import Conduck

final class UsageActivityChartCopyTests: XCTestCase {

    private let anchor = Date(timeIntervalSince1970: 1_760_000_000)

    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()

    private func bucket(
        attempts: Int = 0,
        turns: Int = 0,
        resolvedAttempts: Int = 0,
        succeededAttempts: Int = 0,
        reportedTokens: Int = 0,
        tokenMeasuredAttempts: Int = 0,
        startsMidPeriod: Bool = false,
        endsMidPeriod: Bool = false,
        periodDays: Int = 1,
        deviceAttempts: [String?: Int] = [:],
        gatewayAttempts: [String?: Int] = [:]
    ) -> GatewayUsageActivityBucket {
        let start = calendar.startOfDay(for: anchor)
        return GatewayUsageActivityBucket(
            periodStart: start,
            periodEnd: calendar.date(byAdding: .day, value: periodDays, to: start)!,
            startsMidPeriod: startsMidPeriod,
            endsMidPeriod: endsMidPeriod,
            attempts: attempts,
            turns: turns,
            resolvedAttempts: resolvedAttempts,
            succeededAttempts: succeededAttempts,
            reportedTokens: reportedTokens,
            tokenMeasuredAttempts: tokenMeasuredAttempts,
            deviceAttempts: deviceAttempts,
            gatewayAttempts: gatewayAttempts
        )
    }

    // MARK: - Segment ranking

    /// TOP THREE BY NAME, THE TAIL COMBINED, and the unattributed slot last. The
    /// order is the stack order bottom to top, so it is what decides which
    /// dimension value wears the brand amber.
    func testRankingNamesTheTopThreeAndFoldsTheRestIntoOther() {
        let segments = UsageChartSegments.build(
            totals: ["a": 10, "b": 7, "c": 5, "d": 3, "e": 1],
            label: { $0 ?? "" }
        )

        XCTAssertEqual(segments.map(\.label), ["a", "b", "c", "Other"])
        XCTAssertEqual(segments.map(\.order), [0, 1, 2, 3])
        XCTAssertEqual(segments.last?.role, .other)
        XCTAssertEqual(
            segments.last?.keys.compactMap { $0 }.sorted(), ["d", "e"],
            "the tail keeps both keys, so its height is their sum")
    }

    /// The unattributed bucket exists for MASS CONSERVATION: the stack has to
    /// reach the period's own attempt count, and a bar quietly short of its own
    /// total is a lie. It sorts last and is never a named peer.
    func testUnattributedAttemptsBecomeTheirOwnTopmostSegment() {
        let segments = UsageChartSegments.build(
            totals: ["a": 4, nil: 2],
            label: { $0 ?? "" }
        )

        XCTAssertEqual(segments.map(\.role), [.named, .notRecorded])
        XCTAssertEqual(segments.last?.keys, [nil])
    }

    /// Nothing unattributed, no segment for it — a ledger that records every
    /// device must not grow a permanent grey sliver reading zero.
    func testNoUnattributedAttemptsEmitNoUnattributedSegment() {
        let segments = UsageChartSegments.build(totals: ["a": 4, nil: 0], label: { $0 ?? "" })

        XCTAssertEqual(segments.map(\.role), [.named])
    }

    /// One dimension value is one segment — the chart degenerates to the single
    /// amber series it always was, which is why the legend is withheld there.
    func testSingleValueRangeYieldsOneSegment() {
        let segments = UsageChartSegments.build(totals: ["a": 9], label: { $0 ?? "" })

        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0].role, .named)
    }

    /// TIES BREAK ON THE KEY, not on the label: two equal gateways must keep
    /// their order across a redraw even if the user renames one of them, or the
    /// colours would swap under the reader's eyes for no reason they can see.
    func testEqualCountsBreakTheTieOnTheStableKey() {
        let segments = UsageChartSegments.build(
            totals: ["zeta": 5, "alpha": 5],
            label: { $0 == "alpha" ? "Zebra" : "Aardvark" }
        )

        XCTAssertEqual(segments.map(\.keys), [["alpha"], ["zeta"]])
    }

    /// The ranking comes from the RANGE and is then read per period, so a
    /// segment simply measures zero in a period that value never appeared in —
    /// it does not disappear and let the one below it change colour.
    func testSegmentHeightIsZeroInAPeriodItsValueMissed() {
        let segments = UsageChartSegments.build(
            totals: ["a": 10, "b": 2], label: { $0 ?? "" })

        XCTAssertEqual(segments[1].attempts(in: ["a": 4]), 0)
        XCTAssertEqual(segments[0].attempts(in: ["a": 4]), 4)
    }

    // MARK: - Line one, per metric

    /// A PERIOD NOBODY USED SAYS SO, whichever measure is on screen. Five
    /// different spellings of zero would each be a fact about the measure
    /// rather than about the period.
    func testAPeriodWithNoAttemptsReadsTheSameOnEveryMeasure() {
        let empty = bucket()

        for metric in UsageChartMetric.allCases {
            let sentence = UsageActivitySentence.line1(
                metric: metric, bucket: empty, unit: .day, calendar: calendar)
            XCTAssertTrue(
                sentence.hasSuffix("· no attempts"),
                "\(metric.rawValue) said: \(sentence)")
        }
    }

    /// THE ZERO-TOKEN LIE. A period whose gateways reported nothing has zero
    /// tokens over zero measuring attempts, and "0 tokens" claims a free period
    /// rather than an unmeasured one.
    func testTokensLineSaysNothingWasRecordedRatherThanZero() {
        let unmeasured = bucket(attempts: 4, turns: 3)

        let sentence = UsageActivitySentence.line1(
            metric: .tokens, bucket: unmeasured, unit: .day, calendar: calendar)

        XCTAssertTrue(sentence.hasSuffix("· no token data recorded"), sentence)
        XCTAssertFalse(sentence.contains("0 tokens"))
    }

    /// A MEASURED ZERO IS STILL A MEASUREMENT. A gateway that reported a total
    /// of zero said something, and the sentence has to print it rather than
    /// disclaiming a figure it actually has.
    func testAMeasuredZeroStillPrintsAsTokens() {
        let measured = bucket(attempts: 2, turns: 2, tokenMeasuredAttempts: 2)

        let sentence = UsageActivitySentence.line1(
            metric: .tokens, bucket: measured, unit: .day, calendar: calendar)

        XCTAssertTrue(sentence.hasSuffix("· 0 tokens"), sentence)
    }

    /// Two counts, never a rate — and the third population is NAMED rather than
    /// painted into the stack, because a cancellation is not a failure.
    func testResultsLineCountsBothOutcomesAndNamesTheRest() {
        let mixed = bucket(
            attempts: 14, turns: 12, resolvedAttempts: 12, succeededAttempts: 9)

        let sentence = UsageActivitySentence.line1(
            metric: .reliability, bucket: mixed, unit: .day, calendar: calendar)

        XCTAssertTrue(sentence.contains("· 9 succeeded · 3 failed"), sentence)
        XCTAssertTrue(sentence.hasSuffix("· 2 with another outcome"), sentence)
    }

    /// A period that resolved nothing has no rate to draw and no rate to speak.
    /// "0 of 0 succeeded" is arithmetic nobody asked for and reads as a failure
    /// that did not happen.
    func testResultsLineWithNothingResolvedNamesTheOtherOutcomesInstead() {
        let unresolved = bucket(attempts: 3, turns: 3)

        let sentence = UsageActivitySentence.line1(
            metric: .reliability, bucket: unresolved, unit: .day, calendar: calendar)

        XCTAssertTrue(
            sentence.hasSuffix("· nothing succeeded or failed — 3 with another outcome"),
            sentence)
        XCTAssertFalse(sentence.contains("0 of 0"))
    }

    /// The dimension line opens with the bar's own height and then spends it,
    /// so a reader can check the split adds up without doing the arithmetic
    /// twice. Zero-height segments are omitted; the unattributed one is named
    /// in plain words.
    func testDimensionLineSpendsTheAttemptTotalAcrossItsSegments() {
        let split: [String?: Int] = ["iphone": 9, "mac": 3, nil: 2]
        let segments = UsageChartSegments.build(totals: split) {
            UsageDeviceBucketDisplay.label(forKey: $0)
        }
        let period = bucket(attempts: 14, turns: 12, deviceAttempts: split)

        let sentence = UsageActivitySentence.line1(
            metric: .devices, bucket: period, unit: .day,
            split: split, segments: segments, calendar: calendar)

        XCTAssertTrue(sentence.contains("· 14 attempts · 9 iPhone · 3 Mac"), sentence)
        XCTAssertTrue(sentence.hasSuffix("· 2 not recorded"), sentence)
    }

    // MARK: - Period naming

    /// A LEADING PARTIAL NAMES THE DAYS IT HOLDS. The 90-day range stays 90
    /// days, so its first weekly bar may be three days long — calling it "Week
    /// of Jun 1" would claim four days it never covered.
    func testAClippedLeadingWeekNamesItsCoveredSpan() {
        let clipped = bucket(attempts: 2, turns: 2, startsMidPeriod: true, periodDays: 3)

        let label = UsageActivitySentence.periodLabel(clipped, unit: .week, calendar: calendar)

        let start = clipped.periodStart.formatted(date: .abbreviated, time: .omitted)
        let end = calendar.date(byAdding: .day, value: 2, to: clipped.periodStart)!
            .formatted(date: .abbreviated, time: .omitted)
        XCTAssertEqual(label, "\(start) – \(end)")
    }

    /// A whole week is named by the day it starts on, which is also what its
    /// axis tick reads — one vocabulary for the same bar.
    func testAWholeWeekIsNamedByItsFirstDay() {
        let whole = bucket(attempts: 5, turns: 4, periodDays: 7)

        let label = UsageActivitySentence.periodLabel(whole, unit: .week, calendar: calendar)

        XCTAssertTrue(label.hasPrefix("Week of "), label)
    }

    /// THE TRAILING PERIOD IS STILL RUNNING, and saying so is what stops a
    /// half-height final bar from reading as a collapse in activity.
    func testTheInProgressPeriodCarriesItsOwnClause() {
        let running = bucket(attempts: 4, turns: 4, endsMidPeriod: true)

        XCTAssertTrue(
            UsageActivitySentence.line1(
                metric: .turns, bucket: running, unit: .day, calendar: calendar
            ).hasSuffix("· so far today"))
        XCTAssertTrue(
            UsageActivitySentence.line1(
                metric: .turns, bucket: running, unit: .week, calendar: calendar
            ).hasSuffix("· this week so far"))
        XCTAssertTrue(
            UsageActivitySentence.line1(
                metric: .turns, bucket: running, unit: .month, calendar: calendar
            ).hasSuffix("· this month so far"))
    }

    // MARK: - Line two, the other measures

    /// The active measure's own clause is OMITTED — repeating line one
    /// underneath itself is noise — and the remaining two keep a fixed order so
    /// the eye lands in the same place on every scrub.
    func testLineTwoOmitsTheActiveMeasureAndKeepsTheOthersInOrder() {
        let period = bucket(
            attempts: 14, turns: 12, resolvedAttempts: 14, succeededAttempts: 11,
            reportedTokens: 18_200, tokenMeasuredAttempts: 14)

        // The token figure is built through the SAME formatter the sentence
        // uses: compact notation localises its own suffix and separator, and a
        // hard-coded "18.2K" would make this suite pass or fail on where it ran.
        let tokens = 18_200.formatted(.number.notation(.compactName))
        XCTAssertEqual(
            UsageActivitySentence.line2(metric: .turns, bucket: period),
            "11 of 14 succeeded · \(tokens) tokens")
        XCTAssertEqual(
            UsageActivitySentence.line2(metric: .reliability, bucket: period),
            "12 turns · 14 attempts · \(tokens) tokens")
        XCTAssertEqual(
            UsageActivitySentence.line2(metric: .tokens, bucket: period),
            "12 turns · 14 attempts · 11 of 14 succeeded")
    }

    /// The dimension measures own none of the three clauses — their line one is
    /// the split — so all three appear underneath.
    func testDimensionMeasuresShowAllThreeClauses() {
        let period = bucket(
            attempts: 6, turns: 5, resolvedAttempts: 6, succeededAttempts: 6,
            reportedTokens: 900, tokenMeasuredAttempts: 6)

        for metric in [UsageChartMetric.devices, .gateways] {
            XCTAssertEqual(
                UsageActivitySentence.line2(metric: metric, bucket: period),
                "5 turns · 6 attempts · 6 of 6 succeeded · \(900.formatted(.number.notation(.compactName))) tokens")
        }
    }

    /// Line two obeys the same two absences line one does, in its shorter
    /// register: a rate with no denominator and a token sum with no measurement
    /// are both said in words rather than printed as zero.
    func testLineTwoSpeaksBothAbsences() {
        let period = bucket(attempts: 3, turns: 3)

        XCTAssertEqual(
            UsageActivitySentence.line2(metric: .turns, bucket: period),
            "nothing succeeded or failed · no token data")
    }

    /// Nothing happened, so there is nothing for the other measures to add —
    /// line one already said "no attempts", and three clauses of zero
    /// underneath it would be the same silence stated three more times.
    func testLineTwoIsEmptyForAPeriodWithNoAttempts() {
        XCTAssertEqual(UsageActivitySentence.line2(metric: .turns, bucket: bucket()), "")
    }
}
