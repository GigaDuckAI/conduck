// SPDX-License-Identifier: Apache-2.0

// Conduck
// UsageActivityChartDomainTests.swift
//
// Locks the ONE calculation behind the usage chart's x axis:
// `UsageActivityChart.xDomain`, which pins the scale to the bucket range
// instead of letting Swift Charts derive it from the marks that happened to be
// drawn.
//
// WHY IT IS WORTH A TEST. Every metric skips a period it has nothing to say
// about — Results draws no bar where nothing resolved, Tokens none where
// nothing reported — so a range with one such period emits exactly one mark. A
// derived domain then collapses to that single period: one plot-filling bar,
// and an axis repeating the same date at every tick, while the Turns metric
// over the identical buckets looks fine — the failure is invisible from any
// code that only ever renders bars.
//
// THE SAME PICTURE ARRIVES FROM THE BUCKETS TOO, which is why the floor is
// locked here beside the pinning. All time over a day-old ledger holds one
// bucket, so a domain honouring it exactly is one day wide and hands that day
// the whole plot — the collapse again, this time with nothing skipped.
//
// THE FLOOR IS A DAY-UNIT RULE, and that is locked too: a weekly or monthly
// fold only happens above the fold threshold, so it is already wider than the
// floor, and applying the floor there would widen a calendar past the range the
// user asked for.
//
// Pure Foundation: the helper takes buckets and a unit and returns a date
// range, so nothing here renders a view.

import XCTest

@testable import Conduck

final class UsageActivityChartDomainTests: XCTestCase {

    /// `Calendar.current`, deliberately — the helper adds its trailing period in
    /// the user's own calendar, so a fixture built in any other one would
    /// disagree with it by an hour on every DST transition and pass or fail on
    /// where the runner happens to be.
    private var calendar: Calendar { Calendar.current }

    private func day(_ offset: Int) -> Date {
        let anchor = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_760_000_000))
        return calendar.date(byAdding: .day, value: offset, to: anchor)!
    }

    private func bucket(_ offset: Int, attempts: Int = 0) -> GatewayUsageActivityBucket {
        GatewayUsageActivityBucket(periodStart: day(offset), attempts: attempts, turns: attempts)
    }

    /// A span already WIDER than the floor is left exactly as the buckets
    /// describe it, ending a day past the last one so that day's bar has its
    /// full width to stand in. Ten days of buckets, so the floor has nothing to
    /// add.
    func testWideSpanKeepsEveryBucketPlusTheDayAfterTheLast() {
        let buckets = (0...9).map { bucket($0) }

        let domain = UsageActivityChart.xDomain(for: buckets, unit: .day)

        XCTAssertEqual(domain?.lowerBound, day(0))
        XCTAssertEqual(domain?.upperBound, day(10))
    }

    /// THE COLLAPSE CASE, stated directly. A single bucket describes one whole
    /// day, and one whole day is still the entire plot: one bar filling it, and
    /// four axis ticks all reading that date. The domain is therefore widened
    /// DOWNWARDS to the floor, the last day keeping its own full width.
    func testSingleBucketIsWidenedToTheMinimumSpan() {
        let domain = UsageActivityChart.xDomain(for: [bucket(4, attempts: 3)], unit: .day)

        // Upper bound day(5), floor 7 days → day(-2).
        XCTAssertEqual(domain?.lowerBound, day(-2))
        XCTAssertEqual(domain?.upperBound, day(5))
    }

    /// A handful of days is the same symptom in slower motion — three fat bars
    /// and a repeated tick — so anything under the floor is widened to it, not
    /// just the single-bucket case.
    func testShortMultiDaySpanIsWidenedToTheMinimumSpan() {
        let domain = UsageActivityChart.xDomain(
            for: [bucket(0), bucket(1), bucket(2)], unit: .day)

        // Upper bound day(3), floor 7 days → day(-4).
        XCTAssertEqual(domain?.lowerBound, day(-4))
        XCTAssertEqual(domain?.upperBound, day(3))
    }

    /// The floor is the picker's shortest window and nothing else — a chart
    /// narrower than a range the user can select is the thing being prevented.
    func testMinimumSpanIsTheShortestRangeThePickerOffers() {
        let domain = UsageActivityChart.xDomain(for: [bucket(4)], unit: .day)

        let span = calendar.dateComponents(
            [.day], from: domain!.lowerBound, to: domain!.upperBound).day
        XCTAssertEqual(span, UsageActivityChart.minimumSpanDays)
        XCTAssertEqual(UsageActivityChart.minimumSpanDays, UsageDashboardModel.Range.weekDays)
    }

    /// A WEEKLY FOLD GETS NO FLOOR. Two weekly buckets are already a fortnight
    /// wide; widening the calendar by another seven days would push the bars
    /// into a corner of a range the user never asked for.
    func testWeeklyBucketsAreNotWidenedByTheDayFloor() {
        let weeks = [bucket(0), bucket(7)]

        let domain = UsageActivityChart.xDomain(for: weeks, unit: .week)

        XCTAssertEqual(domain?.lowerBound, day(0))
        XCTAssertEqual(
            domain?.upperBound,
            calendar.date(byAdding: .weekOfYear, value: 1, to: day(7)),
            "the trailing bound is one WEEK past the last bucket, so its bar keeps its width")
    }

    /// The same rule one unit coarser, and the trailing bound is a month rather
    /// than a fixed thirty days — February's bar is as wide as its own month.
    func testMonthlyBucketsEndOneMonthPastTheLastBucket() {
        let domain = UsageActivityChart.xDomain(for: [bucket(0)], unit: .month)

        XCTAssertEqual(domain?.lowerBound, day(0))
        XCTAssertEqual(
            domain?.upperBound, calendar.date(byAdding: .month, value: 1, to: day(0)))
    }

    /// No buckets, no calendar to pin — the chart is not drawn at all there,
    /// and inventing a domain would be a claim about a range with no days in it.
    func testNoBucketsHaveNoDomain() {
        XCTAssertNil(UsageActivityChart.xDomain(for: [], unit: .day))
    }

    /// The aggregator emits buckets in ascending period order, but the helper is
    /// total over whatever it is handed: an out-of-order array must still
    /// produce a valid range rather than trapping on an inverted one.
    func testUnorderedBucketsStillProduceAnAscendingDomain() {
        let domain = UsageActivityChart.xDomain(
            for: [bucket(2), bucket(0), bucket(1)], unit: .day)

        XCTAssertEqual(domain?.lowerBound, day(-4))
        XCTAssertEqual(domain?.upperBound, day(3))
    }
}
