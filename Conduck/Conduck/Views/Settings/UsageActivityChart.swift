// SPDX-License-Identifier: Apache-2.0

// Conduck
// UsageActivityChart.swift
//
// The ONE daily chart on Settings ▸ Usage. The overview, the gateway
// drill-down and the device drill-down all render this view over their own
// `dailyActivity` buckets, so a user who learns to read the chart once has
// learned to read all three. A second implementation living beside this one is
// the defect this file exists to prevent — two charts of the same ledger drift
// in axis, colour and honesty until they disagree about the same day.
//
// THREE MEASURES, ONE CHART. Turns, tokens and success rate are three questions
// about the same days, and stacking three charts down the screen makes the user
// scroll to compare what a picker lets them flip between in place. The choice
// is persisted under ONE key, so it follows the user from the overview into a
// drill-down and back rather than resetting on every push.
//
// ABSENCE IS NOT ZERO — the rule the reliability bars turn on. A day nobody
// resolved anything on has no success rate to draw; a zero-height bar there
// would read as "everything failed", which is the opposite of what happened.
// Such a day gets NO bar at all. The same care governs tokens: zero tokens over
// zero measured attempts is silence, not a measurement, so the bars give way to
// a sentence saying so, and a partial measurement carries its coverage count
// underneath rather than letting the bars imply completeness.
//
// CHART DISCIPLINE (inherited from the overview it grew out of). One series,
// one measure, one y-scale, no legend — the picker above names the series. The
// grid is recessive, values appear on SELECTION rather than on every bar, and
// the bars carry the brand amber because they are one quantity, not a category.
// A selection dims the OTHER bars rather than repainting the chosen one, so the
// bar the user pointed at keeps the colour it already had.
//
// The card row treatment is the CALLER'S — every call site wraps this in
// `.settingsCardPassiveRow()` itself, because the three hosts differ in what
// else shares the row.

import Charts
import SwiftUI

/// What the bars measure. `String`-raw-valued because the selection persists in
/// `UserDefaults`; the raw values are therefore storage and must not be
/// renamed — a rename silently resets every user's chart to Turns.
enum UsageChartMetric: String, CaseIterable, Identifiable {
    case turns
    case tokens
    case reliability

    var id: String { rawValue }
}

/// Daily activity, drawn one measure at a time.
struct UsageActivityChart: View {
    private let buckets: [GatewayUsageDailyBucket]

    /// ONE key across every host. The overview and both drill-downs read and
    /// write this same preference on purpose: a user who switched to Tokens on
    /// the overview asked to see tokens, not to see tokens on one screen.
    ///
    /// `UserDefaults.standard` (device-local) rather than the App Group or KVS:
    /// this is a viewing preference, not a setting worth syncing, and the
    /// storage seam reserves the shared stores for state the app actually
    /// shares.
    @AppStorage("settings.usage.chart.metric")
    private var metric: UsageChartMetric = .turns

    /// The day under the pointer / finger. Raw, because a date scale reports
    /// where the gesture landed rather than which bar it hit; the bucket is
    /// resolved by calendar day below.
    @State private var rawSelectedDay: Date?

    init(buckets: [GatewayUsageDailyBucket]) {
        self.buckets = buckets
    }

    var body: some View {
        let selected = selectedBucket

        VStack(alignment: .leading, spacing: 8) {
            metricPicker
            caption(selected: selected)

            if showsTokenEmptyState {
                tokenEmptyState
            } else {
                scaled(chart(selected: selected))
                    .frame(height: 150)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text(chartAccessibilityLabel))
            }

            if let coverage = tokenCoverageCaption {
                Text(coverage)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(AppColors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Picker

    /// A standard segmented control, so it inherits the platform's own
    /// VoiceOver treatment ("Turns, selected, 1 of 3") rather than a hand-rolled
    /// row that would have to reproduce it.
    private var metricPicker: some View {
        Picker(selection: $metric) {
            ForEach(UsageChartMetric.allCases) { option in
                Text(title(for: option)).tag(option)
            }
        } label: {
            Text(LocalizedStringResource(
                "settings.usage.chart.metric.label", defaultValue: "Measure"))
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .tint(AppColors.brandAmber)
        .accessibilityLabel(Text(LocalizedStringResource(
            "settings.usage.chart.metric.label", defaultValue: "Measure")))
    }

    private func title(for metric: UsageChartMetric) -> LocalizedStringResource {
        switch metric {
        case .turns:
            return LocalizedStringResource(
                "settings.usage.chart.metric.turns", defaultValue: "Turns")
        case .tokens:
            return LocalizedStringResource(
                "settings.usage.chart.metric.tokens", defaultValue: "Tokens")
        case .reliability:
            // "Success", not "Reliability": the bars are one rate, and the
            // Reliability card below is the whole story the word promises.
            return LocalizedStringResource(
                "settings.usage.chart.metric.reliability", defaultValue: "Success")
        }
    }

    // MARK: - Chart

    private func chart(selected: GatewayUsageDailyBucket?) -> some View {
        Chart {
            ForEach(buckets) { bucket in
                // A NIL VALUE DRAWS NOTHING. On the reliability metric that is
                // the whole point: a day with nothing resolved has no rate, and
                // a zero bar would report a failure that did not happen.
                if let value = barValue(for: bucket) {
                    BarMark(
                        x: .value(dayAxisName, bucket.day, unit: .day),
                        y: .value(valueAxisName, value)
                    )
                    .cornerRadius(2)
                    .foregroundStyle(
                        AppColors.brandAmber.opacity(
                            selected == nil || selected?.day == bucket.day ? 1 : 0.35
                        )
                    )
                }
            }
        }
        .chartXSelection(value: $rawSelectedDay)
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                AxisGridLine()
                    .foregroundStyle(AppColors.borderSubtle)
                AxisValueLabel {
                    if let raw = value.as(Double.self) {
                        Text(axisLabel(raw))
                            .foregroundStyle(AppColors.textTertiary)
                    }
                }
            }
        }
        // No x grid lines: the bars already stand on the day boundary, and a
        // second set of rules behind them is noise. `.aligned` keeps the edge
        // labels inside the plot area — a centered label on the last tick would
        // hang past the trailing edge and clip ("24. Aug" → "2").
        .chartXAxis {
            AxisMarks(preset: .aligned, values: .automatic(desiredCount: 4)) { _ in
                AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                    .foregroundStyle(AppColors.textTertiary)
            }
        }
    }

    /// The y scale, which is the one thing the three measures cannot share. A
    /// rate is pinned to 0–100 so a good week and a bad week are drawn on the
    /// same ruler; a count autoscales to whatever the range holds.
    ///
    /// Branched in a `ViewBuilder` rather than with a ternary because the two
    /// `chartYScale` overloads take different domain types.
    ///
    /// The rate domain is written in DOUBLES to match what the bars plot. An
    /// integer range type-checks and then hands the y axis integer values, at
    /// which point `value.as(Double.self)` below returns nil and the percentage
    /// labels quietly disappear — a formatting bug with no compiler warning.
    @ViewBuilder
    private func scaled<Content: View>(_ chart: Content) -> some View {
        switch metric {
        case .reliability:
            chart.chartYScale(domain: 0.0...100.0)
        case .turns, .tokens:
            chart.chartYScale(domain: .automatic(includesZero: true))
        }
    }

    /// The day's height, or nil where the day has nothing to say.
    private func barValue(for bucket: GatewayUsageDailyBucket) -> Double? {
        switch metric {
        case .turns:
            return Double(bucket.turns)
        case .tokens:
            return Double(bucket.reportedTokens)
        case .reliability:
            guard bucket.resolvedAttempts > 0 else { return nil }
            return Double(bucket.succeededAttempts) / Double(bucket.resolvedAttempts) * 100
        }
    }

    private func axisLabel(_ raw: Double) -> String {
        switch metric {
        case .turns:
            return Int(raw.rounded()).formatted(.number)
        case .tokens:
            // Compact, because a full token count on a leading axis eats a
            // third of the plot width at every tick.
            return Int(raw.rounded()).formatted(.number.notation(.compactName))
        case .reliability:
            return (raw / 100).formatted(.percent.precision(.fractionLength(0)))
        }
    }

    private var dayAxisName: String {
        String(localized: "settings.usage.chart.axis.day", defaultValue: "Day")
    }

    private var valueAxisName: String {
        switch metric {
        case .turns:
            return String(localized: "settings.usage.chart.axis.turns", defaultValue: "Turns")
        case .tokens:
            return String(localized: "settings.usage.chart.axis.tokens", defaultValue: "Tokens")
        case .reliability:
            return String(
                localized: "settings.usage.chart.axis.success", defaultValue: "Success rate")
        }
    }

    // MARK: - Captions

    /// The chart's one number line: the series name at rest, the selected day's
    /// figures while a bar is picked.
    private func caption(selected: GatewayUsageDailyBucket?) -> some View {
        Group {
            if let selected {
                Text(selectionCaption(selected))
                    .foregroundStyle(AppColors.textPrimary)
            } else {
                Text(restCaption)
                    .foregroundStyle(AppColors.textTertiary)
            }
        }
        .font(.caption)
        .monospacedDigit()
    }

    private var restCaption: LocalizedStringResource {
        switch metric {
        case .turns:
            return LocalizedStringResource(
                "settings.usage.chart.caption", defaultValue: "Turns per day")
        case .tokens:
            return LocalizedStringResource(
                "settings.usage.chart.caption.tokens", defaultValue: "Tokens per day")
        case .reliability:
            return LocalizedStringResource(
                "settings.usage.chart.caption.reliability",
                defaultValue: "Attempts that succeeded, per day")
        }
    }

    private func selectionCaption(
        _ bucket: GatewayUsageDailyBucket
    ) -> LocalizedStringResource {
        let day = bucket.day.formatted(date: .abbreviated, time: .omitted)
        switch metric {
        case .turns:
            return LocalizedStringResource(
                "settings.usage.chart.selection",
                defaultValue: "\(day) · \(bucket.turns) turns · \(bucket.attempts) attempts")
        case .tokens:
            return LocalizedStringResource(
                "settings.usage.chart.selection.tokens",
                defaultValue: "\(day) · \(bucket.reportedTokens.formatted(.number)) tokens")
        case .reliability:
            // A day that resolved nothing gets its own sentence. "0 of 0
            // succeeded" is arithmetic nobody asked for and reads as a failure.
            guard bucket.resolvedAttempts > 0 else {
                return LocalizedStringResource(
                    "settings.usage.chart.selection.reliability.none",
                    defaultValue: "\(day) · nothing finished this day")
            }
            return LocalizedStringResource(
                "settings.usage.chart.selection.reliability",
                defaultValue: """
                    \(day) · \(bucket.succeededAttempts) of \
                    \(bucket.resolvedAttempts) succeeded
                    """)
        }
    }

    /// Names the ACTIVE measure, because the picker's own announcement is the
    /// only other place it is said and a chart summarised as "chart" tells a
    /// VoiceOver user nothing about which of the three they are on.
    private var chartAccessibilityLabel: LocalizedStringResource {
        switch metric {
        case .turns:
            return LocalizedStringResource(
                "settings.usage.chart.a11y.turns", defaultValue: "Chart of turns per day")
        case .tokens:
            return LocalizedStringResource(
                "settings.usage.chart.a11y.tokens", defaultValue: "Chart of tokens per day")
        case .reliability:
            return LocalizedStringResource(
                "settings.usage.chart.a11y.reliability",
                defaultValue: "Chart of the share of attempts that succeeded, per day")
        }
    }

    // MARK: - Token honesty

    /// Attempts that reported a token figure, and attempts in total. Bucket
    /// attempts are stamped to one day each, so both sums are the range's own
    /// numbers rather than an over-count.
    private var tokenMeasuredAttempts: Int {
        buckets.reduce(0) { $0 + $1.tokenMeasuredAttempts }
    }

    private var totalAttempts: Int {
        buckets.reduce(0) { $0 + $1.attempts }
    }

    /// NOTHING WAS MEASURED, which is different from measuring zero. A gateway
    /// that reports no usage produces no token figure at all, and an empty plot
    /// with an autoscaled axis would dress that silence up as data.
    private var showsTokenEmptyState: Bool {
        metric == .tokens && tokenMeasuredAttempts == 0
    }

    /// WORDED ABOUT THE TOTAL, not about the gateway. A day's bar needs a
    /// reported total or BOTH components, so a gateway that reported input
    /// alone lands here having reported something — and the Tokens card on the
    /// same screen, which adds up whichever component it has, would be showing
    /// that very number. "Reported no tokens" would then be contradicted one
    /// card below. Phrased like the response-time card's own empty line, which
    /// answers the same shape of question.
    private var tokenEmptyState: some View {
        Text(LocalizedStringResource(
            "settings.usage.chart.tokens.none",
            defaultValue: "No attempt in this range reported a usable token total."))
            .font(.subheadline)
            .foregroundStyle(AppColors.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Shown only where coverage is PARTIAL — a caption under every chart would
    /// train the eye to skip the one that changes what the bars mean.
    private var tokenCoverageCaption: LocalizedStringResource? {
        guard metric == .tokens else { return nil }
        let measured = tokenMeasuredAttempts
        guard measured > 0, measured < totalAttempts else { return nil }
        return LocalizedStringResource(
            "settings.usage.chart.tokens.coverage",
            defaultValue: "Token data on \(measured) of \(totalAttempts) attempts")
    }

    // MARK: - Selection

    /// A date scale reports the instant under the gesture, not the bar beneath
    /// it, so the bucket is matched by calendar day.
    private var selectedBucket: GatewayUsageDailyBucket? {
        guard let rawSelectedDay else { return nil }
        return buckets.first {
            Calendar.current.isDate($0.day, inSameDayAs: rawSelectedDay)
        }
    }
}
