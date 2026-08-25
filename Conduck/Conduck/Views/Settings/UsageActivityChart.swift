// SPDX-License-Identifier: Apache-2.0

// Conduck
// UsageActivityChart.swift
//
// The ONE activity chart on Settings ▸ Usage. The overview, the gateway
// drill-down and the device drill-down all render this view over their own
// `activity` buckets, so a user who learns to read the chart once has learned to
// read all three. A second implementation living beside this one is the defect
// this file exists to prevent — two charts of the same ledger drift in axis,
// colour and honesty until they disagree about the same day.
//
// FIVE MEASURES, ONE CHART. Turns, tokens, results, devices and gateways are
// five questions about the same periods, and stacking five charts down the
// screen makes the user scroll to compare what a picker lets them flip between
// in place. The choice is persisted under ONE key, so it follows the user from
// the overview into a drill-down and back rather than resetting on every push.
// A host that cannot answer a question WITHHOLDS it — the device drill-down
// offers no Devices measure, because a split of one device restates the filter —
// and falls back to Turns for display WITHOUT writing the key, so the user's
// choice survives the round trip.
//
// COUNTS, NOT RATES, AND THAT IS WHAT MAKES THE BARS SAFE TO FOLD. Results draws
// succeeded and failed as a two-part stack rather than a success percentage: a
// rate has no honest height on a quiet period, and folding seven daily rates
// into a week would weight a one-attempt Sunday like a forty-attempt Monday.
// Every bar here is a sum, so a weekly bar is exactly its days added up and the
// share the user reads off it is pooled by construction.
//
// ABSENCE IS NOT ZERO, and every metric obeys it. A mark is emitted only when
// its own value is above zero, so a period that resolved nothing draws no
// Results bar rather than a flat bar reading "everything failed". Tokens go
// further: zero tokens over zero measured attempts is silence, not a
// measurement, so the bars give way to a sentence saying so, and a partial
// measurement carries its coverage count underneath. THE COVERAGE AND EMPTINESS
// CLAIMS COME FROM THE RANGE, not from summing buckets — an attempt with no
// start instant is in the range and on no bar, and a chart that decided
// "nothing was measured" from the bars alone would contradict the Tokens card
// directly below it.
//
// A STACK MUST SUM TO ITS OWN BAR. The Devices and Gateways measures split a
// period's attempts by dimension, and the attempts whose device or slot the
// ledger never captured get a segment of their own — not because an unmeasured
// bucket deserves a name, but because the alternative is a bar quietly shorter
// than the number it claims to draw. It is never a legend peer, and it does not
// reopen the by-device LIST rule, which governs rows rather than heights.
//
// AND AN ABSENT BAR MUST NOT COLLAPSE THE CALENDAR. Swift Charts derives a scale
// from the marks it was given, so a metric that skips periods would shrink the x
// axis to the periods that drew — one resolved day in a 30-day range becomes one
// plot-filling bar over an axis repeating that one date. The domain is therefore
// pinned to the BUCKET range (`xDomain`) for every measure. The BUCKETS can be
// narrow too — All time over a day-old ledger is a single day — so that domain
// also carries a floor, and no chart is ever drawn on a calendar narrower than
// the shortest range the picker offers. The floor is a DAY-unit rule only:
// weekly and monthly folds cannot occur below the fold thresholds, so a floor
// there would widen a calendar that is already wide.
//
// CHART DISCIPLINE (inherited from the overview it grew out of). One measure at
// a time, one y-scale, and a legend ONLY where the colours are categories rather
// than one quantity — the picker above names the series everywhere else. The
// grid is recessive, values appear on SELECTION rather than on every bar, and a
// selection dims the OTHER periods rather than repainting the chosen one, so the
// bar the user pointed at keeps the colour it already had.
//
// THE CAPTION IS TWO LINES, ALWAYS. Line one is the active measure's own
// sentence; line two is what the other measures say about the same period. Both
// lines are present at rest as well, because a caption region that grew when a
// scrub started would push the chart down under the user's own finger. The
// split measures give line one a second ROW to wrap into — their sentence names
// every segment of the stack, including the two that exist for mass
// conservation, and a row that truncated would drop precisely those.
//
// The card row treatment is the CALLER'S — every call site wraps this in
// `.settingsCardPassiveRow()` itself, because the three hosts differ in what
// else shares the row.

import Accessibility
import Charts
import SwiftUI

/// What the bars measure. `String`-raw-valued because the selection persists in
/// `UserDefaults`; the raw values are therefore storage and must not be
/// renamed — a rename silently resets every user's chart to Turns.
///
/// `reliability` keeps its raw value while its label reads "Results": the bars
/// stopped being a rate, but the stored string is what the user's preference is
/// written as.
enum UsageChartMetric: String, CaseIterable, Identifiable {
    case turns
    case tokens
    case reliability
    case devices
    case gateways

    var id: String { rawValue }

    /// Whether the metric splits a period's attempts by a dimension — the two
    /// measures that stack categories, need a legend, and are withheld by the
    /// drill-down that already filters on that dimension.
    var isDimensional: Bool {
        self == .devices || self == .gateways
    }
}

// MARK: - Stack segments

/// One segment of a dimension metric's stack, held FIXED across every period in
/// the chart. Identity and order come from the RANGE totals, not from each
/// period's own ranking: a stack whose colours reshuffled period by period would
/// make two bars of the same height mean different things.
struct UsageChartSegment: Identifiable, Equatable {
    enum Role: Equatable {
        /// One dimension value, named in the legend.
        case named
        /// Everything past the named few, combined.
        case other
        /// Attempts whose dimension the ledger never captured. Present for mass
        /// conservation only — never a legend peer.
        case notRecorded
    }

    /// Bottom-first stack position, and the identity the plot keys on.
    let order: Int
    /// The split keys folded into this segment. A nil key is the unattributed
    /// bucket, which both dimensions spell the same way.
    let keys: [String?]
    /// Already resolved for display — a device's own word, or a gateway slot's
    /// name read from the roster at render time.
    let label: String
    let role: Role

    var id: Int { order }

    /// The segment's height in one period.
    func attempts(in split: [String?: Int]) -> Int {
        keys.reduce(0) { $0 + (split[$1] ?? 0) }
    }
}

/// Builds the fixed segment list for one range. Pure, so the ranking rule can
/// be locked without rendering anything.
enum UsageChartSegments {
    /// Named segments before the tail folds into "Other". Three is what a
    /// caption line and a one-row legend can both carry at caption size.
    static let maxNamedSegments = 3

    /// Range totals in, stack order out: largest, second, third, "Other",
    /// "not recorded" — always in that order, bottom to top.
    ///
    /// Ties break on the KEY rather than on the label, so two dimension values
    /// with the same attempt count keep the same order across a redraw even if
    /// a gateway is renamed underneath them.
    static func build(
        totals: [String?: Int],
        label: (String?) -> String
    ) -> [UsageChartSegment] {
        let attributed = totals
            .compactMap { key, attempts -> (key: String, attempts: Int)? in
                guard let key, attempts > 0 else { return nil }
                return (key, attempts)
            }
            .sorted {
                $0.attempts != $1.attempts ? $0.attempts > $1.attempts : $0.key < $1.key
            }

        var segments: [UsageChartSegment] = attributed.prefix(maxNamedSegments)
            .enumerated()
            .map { index, entry in
                UsageChartSegment(
                    order: index, keys: [entry.key], label: label(entry.key), role: .named)
            }

        let tail = attributed.dropFirst(maxNamedSegments)
        if !tail.isEmpty {
            segments.append(UsageChartSegment(
                order: segments.count,
                keys: tail.map { Optional($0.key) },
                label: String(localized: "settings.usage.chart.segment.other.label",
                              defaultValue: "Other"),
                role: .other
            ))
        }

        // MASS CONSERVATION, and nothing else. Rendered only when it is
        // nonzero, so a ledger that records every device never shows it.
        if (totals[nil] ?? 0) > 0 {
            segments.append(UsageChartSegment(
                order: segments.count,
                keys: [nil],
                // The app's ONE word for "the ledger did not record this",
                // shared with the unattributed gateway row and the unrecorded
                // device row — they are the same fact about capture.
                label: String(localized: "settings.usage.gateway.unattributed",
                              defaultValue: "Not recorded"),
                role: .notRecorded
            ))
        }
        return segments
    }
}

// MARK: - Chart

/// Period activity, drawn one measure at a time.
struct UsageActivityChart: View {

    /// What a drill-down is filtered to, and how much of the range that is.
    /// A COUNT OF A COUNT, never a percentage: "3 of 412" says both how big the
    /// slice is and how big the range is, and a bare "1%" says neither.
    struct Scope: Equatable {
        let name: String
        let attempts: Int
        let rangeAttempts: Int
    }

    private let activity: GatewayUsageActivity

    /// The RANGE's own totals, passed by the host rather than summed from the
    /// buckets — see the file header. Attempts with no start instant are in
    /// these and on no bar.
    private let recordedAttempts: Int
    private let tokenMeasuredAttempts: Int

    /// Display names for gateway slots, resolved at render time. A stored name
    /// would be a stale copy of a setting the user can edit.
    private let gatewayRoster: [CustomGateway]

    /// What this host is willing to draw. A dimension the host already filters
    /// on is absent, because a split of one value restates the filter.
    private let availableMetrics: [UsageChartMetric]

    private let scope: Scope?

    /// ONE key across every host. The overview and both drill-downs read and
    /// write this same preference on purpose: a user who switched to Tokens on
    /// the overview asked to see tokens, not to see tokens on one screen.
    ///
    /// `UserDefaults.standard` (device-local) rather than the App Group or KVS:
    /// this is a viewing preference, not a setting worth syncing, and the
    /// storage seam reserves the shared stores for state the app actually
    /// shares.
    @AppStorage("settings.usage.chart.metric")
    private var storedMetric: UsageChartMetric = .turns

    /// The instant under the pointer / finger. Raw, because a date scale reports
    /// where the gesture landed rather than which bar it hit; the bucket is
    /// resolved by period containment below.
    @State private var rawSelectedDate: Date?

    init(
        activity: GatewayUsageActivity,
        recordedAttempts: Int,
        tokenMeasuredAttempts: Int,
        gatewayRoster: [CustomGateway] = [],
        availableMetrics: [UsageChartMetric] = UsageChartMetric.allCases,
        scope: Scope? = nil
    ) {
        self.activity = activity
        self.recordedAttempts = recordedAttempts
        self.tokenMeasuredAttempts = tokenMeasuredAttempts
        self.gatewayRoster = gatewayRoster
        self.availableMetrics = availableMetrics
        self.scope = scope
    }

    private var buckets: [GatewayUsageActivityBucket] { activity.buckets }
    private var unit: UsageActivityUnit { activity.unit }

    /// The measure actually on screen. A stored choice this host does not offer
    /// falls back to Turns for DISPLAY and is never written back — the user
    /// picked Gateways on the overview, and a trip through the gateway
    /// drill-down must not silently reset that.
    private var metric: UsageChartMetric {
        availableMetrics.contains(storedMetric) ? storedMetric : .turns
    }

    var body: some View {
        let selected = selectedBucket
        // HOISTED ONCE PER RENDER. The ranking walks every bucket, and the
        // marks, the caption and the descriptor all read it — recomputing it
        // inside the mark loop would make one redraw quadratic in the number of
        // bars.
        let stack = segments

        VStack(alignment: .leading, spacing: 8) {
            metricPicker
            if let scope {
                scopeLine(scope)
            }
            captionBlock(selected: selected, stack: stack)

            if showsTokenEmptyState {
                tokenEmptyState
            } else {
                chart(selected: selected, stack: stack)
                    .frame(height: 150)
                    // `.contain` rather than `.ignore`: the chart is a GROUP
                    // now, named by its label and read period by period through
                    // the descriptor. Ignoring the children would collapse it
                    // back to the one opaque element the descriptor exists to
                    // replace.
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel(Text(chartAccessibilityLabel))
                    .accessibilityChartDescriptor(descriptor(stack: stack))

                if legendSegments(stack).count > 1 {
                    legendRow(stack)
                }
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

    /// `SettingsSegmentedPicker`, which IS the standard segmented control on
    /// iOS — VoiceOver's own "Turns, selected, 1 of 5" included — and reproduces
    /// those semantics by hand on macOS, where the system control's grey chrome
    /// does not belong beside the hand-drawn cards. See that file's header.
    ///
    /// The binding READS the resolved metric and WRITES the stored one, which is
    /// what lets a host withhold a measure without clobbering the preference.
    private var metricPicker: some View {
        SettingsSegmentedPicker(
            selection: Binding(get: { metric }, set: { storedMetric = $0 }),
            options: availableMetrics,
            label: Text(LocalizedStringResource(
                "settings.usage.chart.metric.label", defaultValue: "Measure")),
            title: { Text(title(for: $0)) }
        )
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
            // "Results", not "Success": the bars are two counts, and a segment
            // labelled Success beside a failure segment would name the stack
            // after one half of itself.
            return LocalizedStringResource(
                "settings.usage.chart.metric.results", defaultValue: "Results")
        case .devices:
            return LocalizedStringResource(
                "settings.usage.chart.metric.devices", defaultValue: "Devices")
        case .gateways:
            return LocalizedStringResource(
                "settings.usage.chart.metric.gateways", defaultValue: "Gateways")
        }
    }

    /// What the drill-down is showing, and how much of the range that is. Both
    /// counts come from the SAME range by construction — the model computes the
    /// filtered summary and the whole one for one window — so nothing here
    /// approximates.
    private func scopeLine(_ scope: Scope) -> some View {
        Text(String(
            localized: "settings.usage.chart.scope",
            defaultValue: """
                \(scope.name) · \(scope.attempts) of \(scope.rangeAttempts) \
                attempts in this range
                """))
            .font(.caption)
            .monospacedDigit()
            .foregroundStyle(AppColors.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Chart

    private func chart(
        selected: GatewayUsageActivityBucket?,
        stack: [UsageChartSegment]
    ) -> some View {
        Chart {
            ForEach(buckets) { bucket in
                marks(for: bucket, selected: selected, stack: stack)
            }
        }
        .chartXSelection(value: $rawSelectedDate)
        .chartXScale(domain: xScaleDomain)
        // ONE Y RULE FOR EVERY MEASURE, now that no metric plots a rate. The
        // 0–100 pin died with the success percentage, and a count that
        // autoscales without including zero would draw a period's whole bar as
        // the difference from its neighbours.
        .chartYScale(domain: .automatic(includesZero: true))
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
        // No x grid lines: the bars already stand on the period boundary, and a
        // second set of rules behind them is noise. `.aligned` keeps the edge
        // labels inside the plot area — a centered label on the last tick would
        // hang past the trailing edge and clip ("24. Aug" → "2").
        .chartXAxis {
            AxisMarks(preset: .aligned, values: .automatic(desiredCount: 4)) { value in
                AxisValueLabel {
                    if let date = value.as(Date.self) {
                        Text(xAxisLabel(date))
                            .foregroundStyle(AppColors.textTertiary)
                    }
                }
            }
        }
    }

    /// One period's marks. Every arm emits a mark only for a value ABOVE zero,
    /// so a zero-height artifact can never be drawn — under counts a zero is a
    /// true zero, not a hidden rate.
    @ChartContentBuilder
    private func marks(
        for bucket: GatewayUsageActivityBucket,
        selected: GatewayUsageActivityBucket?,
        stack: [UsageChartSegment]
    ) -> some ChartContent {
        // THE WHOLE STACK OF THE PICKED PERIOD KEEPS FULL STRENGTH and every
        // other period's segments dim together, so a selection reads as "this
        // one" rather than as a recolouring.
        let strength = selected == nil || selected?.periodStart == bucket.periodStart ? 1.0 : 0.35

        switch metric {
        case .turns:
            bar(bucket, value: bucket.turns, color: AppColors.brandAmber.opacity(strength))
        case .tokens:
            bar(bucket, value: bucket.reportedTokens, color: AppColors.brandAmber.opacity(strength))
        case .reliability:
            // Succeeded at the bottom, failed on top. The order is the emission
            // order — Swift Charts stacks same-x bars as they are declared.
            bar(bucket, value: bucket.succeededAttempts,
                color: AppColors.brandAmber.opacity(strength),
                radius: bucket.failedAttempts > 0 ? 0 : 2)
            bar(bucket, value: bucket.failedAttempts, color: AppColors.error.opacity(strength))
        case .devices, .gateways:
            let split = dimensionSplit(bucket)
            // The capsule's rounding belongs to the TOPMOST drawn segment
            // alone — `cornerRadius` is per mark, so rounding every segment
            // would pinch the stack at each interior join.
            let topID = stack.last { $0.attempts(in: split) > 0 }?.id
            ForEach(stack) { segment in
                bar(bucket, value: segment.attempts(in: split),
                    color: color(for: segment).opacity(strength),
                    radius: segment.id == topID ? 2 : 0)
            }
        }
    }

    @ChartContentBuilder
    private func bar(
        _ bucket: GatewayUsageActivityBucket,
        value: Int,
        color: Color,
        radius: CGFloat = 2
    ) -> some ChartContent {
        if value > 0 {
            BarMark(
                x: .value(periodAxisName, bucket.periodStart, unit: unit.component),
                y: .value(valueAxisName, value)
            )
            .cornerRadius(radius)
            .foregroundStyle(color)
        }
    }

    /// The x range the bars stand on, taken from the BUCKETS rather than from
    /// the marks — see the header. Nil for no buckets, where there is no
    /// calendar to pin and the chart is not drawn anyway.
    ///
    /// The upper bound is one PERIOD after the last bucket because a `BarMark`
    /// occupies the whole period it starts on: a domain ending on the last
    /// period's start would clip that bar in half.
    ///
    /// A FLOOR OF `minimumSpanDays` — DAY UNITS ONLY — taken off the upper bound
    /// so the last period keeps its full width and only the start of the
    /// calendar moves. The 7/30/90 windows arrive gap-filled and already span
    /// their own width, but All time over a ledger a day old holds ONE bucket,
    /// and a one-day domain gives that day the entire plot under four axis ticks
    /// all reading the same date — the collapse the pinning exists to prevent,
    /// reached from the other side. Seven is the shortest window the picker
    /// offers, so the narrowest chart drawn is the narrowest one a user could
    /// have asked for. A weekly or monthly fold only happens ABOVE the fold
    /// threshold, so it is already wider than the floor and gets none.
    ///
    /// `min`/`max` rather than `first`/`last`: the aggregator emits buckets in
    /// ascending order, but this is a total function over whatever it is handed,
    /// and an inverted range is a crash rather than a wrong picture.
    static func xDomain(
        for buckets: [GatewayUsageActivityBucket],
        unit: UsageActivityUnit
    ) -> ClosedRange<Date>? {
        let calendar = Calendar.current
        let starts = buckets.map(\.periodStart)
        guard let first = starts.min(), let last = starts.max(),
              let end = calendar.date(byAdding: unit.component, value: 1, to: last)
        else { return nil }
        guard unit == .day,
              let floor = calendar.date(byAdding: .day, value: -minimumSpanDays, to: end)
        else { return min(first, end)...end }
        return min(first, floor)...end
    }

    /// The narrowest calendar the chart will draw, in days. Named off the range
    /// picker's shortest window rather than written out, so the two cannot
    /// drift into a chart narrower than any range on offer.
    static var minimumSpanDays: Int { UsageDashboardModel.Range.weekDays }

    /// The pinned scale, or a degenerate one-instant range for the bucketless
    /// case the body never reaches — `chartXScale` takes no optional, and a
    /// branch here would fork every axis modifier below it.
    private var xScaleDomain: ClosedRange<Date> {
        Self.xDomain(for: buckets, unit: unit)
            ?? (buckets.first?.periodStart ?? Date())...(buckets.first?.periodStart ?? Date())
    }

    private func axisLabel(_ raw: Double) -> String {
        switch metric {
        case .tokens:
            // Compact, because a full token count on a leading axis eats a
            // third of the plot width at every tick.
            return Int(raw.rounded()).formatted(.number.notation(.compactName))
        case .turns, .reliability, .devices, .gateways:
            return Int(raw.rounded()).formatted(.number)
        }
    }

    /// Day and week ticks both name a DATE — a week's tick is the day it starts
    /// on, which is what the caption calls it too. Month ticks carry the year
    /// only when the calendar on screen spans more than one, where "Jan" alone
    /// would be two different months.
    private func xAxisLabel(_ date: Date) -> String {
        switch unit {
        case .day, .week:
            return date.formatted(.dateTime.month(.abbreviated).day())
        case .month:
            return spansMultipleYears
                ? date.formatted(.dateTime.month(.abbreviated).year())
                : date.formatted(.dateTime.month(.abbreviated))
        }
    }

    private var spansMultipleYears: Bool {
        let calendar = Calendar.current
        let years = Set(buckets.map { calendar.component(.year, from: $0.periodStart) })
        return years.count > 1
    }

    private var periodAxisName: String {
        String(localized: "settings.usage.chart.axis.period", defaultValue: "Period")
    }

    private var valueAxisName: String {
        switch metric {
        case .turns:
            return String(localized: "settings.usage.chart.axis.turns", defaultValue: "Turns")
        case .tokens:
            return String(localized: "settings.usage.chart.axis.tokens", defaultValue: "Tokens")
        case .reliability, .devices, .gateways:
            return String(
                localized: "settings.usage.chart.axis.attempts", defaultValue: "Attempts")
        }
    }

    // MARK: - Dimension segments

    /// Which of the bucket's two splits a dimension measure reads. `static` and
    /// file-visible so the audio graph builds its sentences from the same rule
    /// the bars are drawn from rather than a second copy of it.
    fileprivate static func dimensionSplit(
        _ bucket: GatewayUsageActivityBucket,
        metric: UsageChartMetric
    ) -> [String?: Int] {
        metric == .gateways ? bucket.gatewayAttempts : bucket.deviceAttempts
    }

    private func dimensionSplit(_ bucket: GatewayUsageActivityBucket) -> [String?: Int] {
        Self.dimensionSplit(bucket, metric: metric)
    }

    /// The fixed stack, computed ONCE per range from the range's own totals.
    private var segments: [UsageChartSegment] {
        guard metric.isDimensional else { return [] }
        var totals: [String?: Int] = [:]
        for bucket in buckets {
            for (key, attempts) in dimensionSplit(bucket) {
                totals[key, default: 0] += attempts
            }
        }
        let isGateway = metric == .gateways
        return UsageChartSegments.build(totals: totals) { key in
            isGateway
                ? UsageGatewayLabel.name(for: key, roster: gatewayRoster)
                : UsageDeviceBucketDisplay.label(forKey: key)
        }
    }

    /// Amber, blue, violet — three categorical hues in rank order — then two
    /// weights of the recessive text tone for the two segments that name no
    /// single thing. RED IS NEVER USED HERE: on this very chart it means a
    /// failed attempt, and a device wearing it would read as a verdict.
    private func color(for segment: UsageChartSegment) -> Color {
        switch segment.role {
        case .named:
            switch segment.order {
            case 0: return AppColors.brandAmber
            case 1: return AppColors.usageIconBlue
            default: return AppColors.usageChartViolet
            }
        case .other:
            return AppColors.textTertiary.opacity(0.45)
        case .notRecorded:
            return AppColors.textTertiary.opacity(0.2)
        }
    }

    /// The named segments plus "Other" — never "not recorded", which is a fact
    /// about measurement rather than a category the user can act on.
    ///
    /// The row is drawn only where there is something to TELL APART: a range
    /// with one dimension value degenerates to a single amber series, which is
    /// what the picker above already named. A non-dimensional measure has no
    /// stack at all, so this is empty there.
    private func legendSegments(_ stack: [UsageChartSegment]) -> [UsageChartSegment] {
        stack.filter { $0.role != .notRecorded }
    }

    private func legendRow(_ stack: [UsageChartSegment]) -> some View {
        HStack(spacing: 12) {
            ForEach(legendSegments(stack)) { segment in
                HStack(spacing: 5) {
                    Circle()
                        .fill(color(for: segment))
                        .frame(width: 7, height: 7)
                    Text(verbatim: segment.label)
                        .font(.caption2)
                        .foregroundStyle(AppColors.textTertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        // One element rather than a rotor entry per dot: the descriptor already
        // speaks each period's split, so the legend is orientation, not data.
        .accessibilityElement(children: .combine)
    }

    // MARK: - Captions

    /// TWO LINES, HELD AT REST. Line one is the active measure's own sentence,
    /// line two is what the other measures say about the same period — and both
    /// are present with nothing selected, because a caption region that grew on
    /// scrub would push the chart down under the user's own finger.
    ///
    /// `lineLimit(_:reservesSpace: true)` rather than a hard-coded height: it
    /// reserves whole rows at whatever Dynamic Type size is in force, and
    /// `minimumScaleFactor` lets a long sentence shrink before it wraps.
    ///
    /// LINE ONE GETS A SECOND ROW WHERE ITS SENTENCE NEEDS ONE, AND THE SPACE IS
    /// RESERVED EITHER WAY. A dimension split is the longest sentence this chart
    /// prints — a period name, an attempt total, three named segments, "other"
    /// and "not recorded" — and it does not fit one caption row at phone width
    /// even fully shrunk. The clauses a single row would cut are the last two,
    /// which are exactly the mass-conservation clauses the stack exists to be
    /// honest about: a bar capped with a grey "not recorded" segment whose
    /// caption never names it is the lie in words instead of in pixels.
    ///
    /// The reservation is keyed on the METRIC, which cannot change while a
    /// finger is down, so the region still holds one height across a whole
    /// scrub — the property the reservation exists for. It changes only when the
    /// user picks a different measure, which redraws the chart anyway.
    private func captionBlock(
        selected: GatewayUsageActivityBucket?,
        stack: [UsageChartSegment]
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(selected.map { selectionLine1($0, stack: stack) } ?? restCaption)
                .foregroundStyle(selected == nil ? AppColors.textTertiary : AppColors.textPrimary)
                .lineLimit(metric.isDimensional ? 2 : 1, reservesSpace: true)
            Text(selected.map { selectionLine2($0) } ?? "")
                .foregroundStyle(AppColors.textTertiary)
                .lineLimit(1, reservesSpace: true)
        }
        .font(.caption)
        .monospacedDigit()
        .minimumScaleFactor(0.8)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var restCaption: String {
        let noun = UsageActivitySentence.unitNoun(unit)
        switch metric {
        case .turns:
            return String(localized: "settings.usage.chart.rest.turns",
                          defaultValue: "Turns per \(noun)")
        case .tokens:
            return String(localized: "settings.usage.chart.rest.tokens",
                          defaultValue: "Tokens per \(noun)")
        case .reliability:
            return String(localized: "settings.usage.chart.rest.results",
                          defaultValue: "Succeeded and failed attempts, per \(noun)")
        case .devices:
            return String(localized: "settings.usage.chart.rest.devices",
                          defaultValue: "Attempts by device, per \(noun)")
        case .gateways:
            return String(localized: "settings.usage.chart.rest.gateways",
                          defaultValue: "Attempts by gateway, per \(noun)")
        }
    }

    private func selectionLine1(
        _ bucket: GatewayUsageActivityBucket,
        stack: [UsageChartSegment]
    ) -> String {
        UsageActivitySentence.line1(
            metric: metric,
            bucket: bucket,
            unit: unit,
            split: metric.isDimensional ? dimensionSplit(bucket) : [:],
            segments: stack
        )
    }

    private func selectionLine2(_ bucket: GatewayUsageActivityBucket) -> String {
        UsageActivitySentence.line2(metric: metric, bucket: bucket)
    }

    /// Names the ACTIVE measure, because the picker's own announcement is the
    /// only other place it is said and a chart summarised as "chart" tells a
    /// VoiceOver user nothing about which of the five they are on.
    private var chartAccessibilityLabel: String {
        let noun = UsageActivitySentence.unitNoun(unit)
        switch metric {
        case .turns:
            return String(localized: "settings.usage.chart.a11y.turns.v2",
                          defaultValue: "Chart of turns per \(noun)")
        case .tokens:
            return String(localized: "settings.usage.chart.a11y.tokens.v2",
                          defaultValue: "Chart of tokens per \(noun)")
        case .reliability:
            return String(localized: "settings.usage.chart.a11y.results",
                          defaultValue: "Chart of succeeded and failed attempts per \(noun)")
        case .devices:
            return String(localized: "settings.usage.chart.a11y.devices",
                          defaultValue: "Chart of attempts by device per \(noun)")
        case .gateways:
            return String(localized: "settings.usage.chart.a11y.gateways",
                          defaultValue: "Chart of attempts by gateway per \(noun)")
        }
    }

    // MARK: - VoiceOver

    /// PER-PERIOD AUDIO GRAPH, not one opaque element. A chart summarised by a
    /// single label can be found but never read: the shape, the quiet weeks and
    /// the one bad day are all invisible. The descriptor hands VoiceOver every
    /// period in the domain — INCLUDING the empty ones, whose sentence says so
    /// in words rather than leaving a silent gap.
    ///
    /// The per-point label is the SAME sentence the selection caption prints,
    /// through the same pure helper, so absence is worded once and cannot drift
    /// between the two readings of it.
    ///
    /// The descriptor is handed the BUCKETS, not a built list of sentences: this
    /// value is constructed on every body pass, and a scrub runs body on every
    /// tick, so formatting one date and half a dozen catalog lookups per period
    /// here would put the whole chart's worth of string building under the
    /// user's moving finger. The period count is not bounded by the fold —
    /// months are the coarsest unit there is, so a long-retained ledger keeps
    /// making bars past `maxActivityBars`. Building the sentences inside
    /// `makeChartDescriptor` costs them once, when VoiceOver actually asks.
    private func descriptor(stack: [UsageChartSegment]) -> UsageActivityChartDescriptor {
        UsageActivityChartDescriptor(
            title: chartAccessibilityLabel,
            seriesName: valueAxisName,
            axisName: periodAxisName,
            valueName: valueAxisName,
            metric: metric,
            unit: unit,
            buckets: buckets,
            segments: stack
        )
    }

    /// The height a period reports — the same quantity the bars draw, totalled
    /// where the bars are stacked. Shared with the audio graph, which must
    /// report the height the sighted reader sees.
    fileprivate static func plottedTotal(
        _ bucket: GatewayUsageActivityBucket,
        metric: UsageChartMetric
    ) -> Int {
        switch metric {
        case .turns: return bucket.turns
        case .tokens: return bucket.reportedTokens
        case .reliability: return bucket.resolvedAttempts
        case .devices, .gateways: return bucket.attempts
        }
    }

    // MARK: - Empty states and coverage

    // An all-empty RANGE never reaches this view: every host branches to its
    // own empty section on `summary.isEmpty` before rendering the chart, and
    // those sections carry remedies ("Try a longer one.") a chart caption
    // cannot. The one empty state owned here is the token silence below, which
    // is metric-local and can occur inside a range that has plenty to draw.

    /// NOTHING WAS MEASURED, which is different from measuring zero. A gateway
    /// that reports no usage produces no token figure at all, and an empty plot
    /// with an autoscaled axis would dress that silence up as data.
    private var showsTokenEmptyState: Bool {
        metric == .tokens && tokenMeasuredAttempts == 0
    }

    /// WORDED ABOUT THE TOTAL, not about the gateway. An attempt needs a
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
    /// train the eye to skip the one that changes what the bars mean. Both
    /// figures are the RANGE's, so this never contradicts the Tokens card by
    /// counting a different population from it.
    private var tokenCoverageCaption: LocalizedStringResource? {
        guard metric == .tokens, recordedAttempts > 0 else { return nil }
        guard tokenMeasuredAttempts > 0, tokenMeasuredAttempts < recordedAttempts else {
            return nil
        }
        return LocalizedStringResource(
            "settings.usage.chart.tokens.coverage",
            defaultValue: "Token data on \(tokenMeasuredAttempts) of \(recordedAttempts) attempts")
    }

    // MARK: - Selection

    /// A date scale reports the instant under the gesture, not the bar beneath
    /// it, so the bucket is matched by PERIOD CONTAINMENT — the latest period
    /// that has already started. `isDate(_:inSameDayAs:)` would match nothing on
    /// a weekly or monthly fold.
    ///
    /// A gesture in the widened floor, before the first bucket, matches nothing
    /// and selects nothing, which is what an empty stretch of calendar deserves.
    private var selectedBucket: GatewayUsageActivityBucket? {
        guard let rawSelectedDate else { return nil }
        return buckets
            .filter { $0.periodStart <= rawSelectedDate }
            .max { $0.periodStart < $1.periodStart }
    }
}

// MARK: - Per-period sentences

/// The chart's words about ONE period, as pure functions. Shared by the
/// selection caption and the VoiceOver descriptor on purpose: they are two
/// readings of the same fact, and two copies of the wording would drift the
/// moment one of them learned about a new kind of absence.
///
/// EVERY ABSENCE IS SAID IN WORDS. "0 tokens" is a measurement nobody took, "0
/// of 0 succeeded" is arithmetic nobody asked for, and both read as bad news
/// that did not happen — so a period with nothing measured says so instead.
enum UsageActivitySentence {

    // MARK: Period naming

    static func unitNoun(_ unit: UsageActivityUnit) -> String {
        switch unit {
        case .day:
            return String(localized: "settings.usage.chart.unit.day", defaultValue: "day")
        case .week:
            return String(localized: "settings.usage.chart.unit.week", defaultValue: "week")
        case .month:
            return String(localized: "settings.usage.chart.unit.month", defaultValue: "month")
        }
    }

    /// What the period is CALLED. A bucket clipped at the range's start names
    /// the span it actually covers — a 90-day range stays 90 days, so its first
    /// weekly bar may be three days long, and calling it "Week of Jun 1" would
    /// claim four days it does not hold.
    static func periodLabel(
        _ bucket: GatewayUsageActivityBucket,
        unit: UsageActivityUnit,
        calendar: Calendar
    ) -> String {
        let start = bucket.periodStart.formatted(date: .abbreviated, time: .omitted)
        if bucket.startsMidPeriod, unit != .day {
            // The last day with any coverage, taken an instant inside the
            // exclusive end so a period ending at midnight names the day before
            // rather than a day it never reached.
            let lastCovered = calendar.startOfDay(
                for: bucket.periodEnd.addingTimeInterval(-1))
            let end = max(lastCovered, bucket.periodStart)
                .formatted(date: .abbreviated, time: .omitted)
            return String(localized: "settings.usage.chart.period.span",
                          defaultValue: "\(start) – \(end)")
        }
        switch unit {
        case .day:
            return start
        case .week:
            return String(localized: "settings.usage.chart.period.week",
                          defaultValue: "Week of \(start)")
        case .month:
            return bucket.periodStart.formatted(.dateTime.month(.wide).year())
        }
    }

    /// The clause a still-running period earns. Only the trailing bucket carries
    /// `endsMidPeriod`, so nothing else can claim to be in progress.
    static func soFarClause(_ unit: UsageActivityUnit) -> String {
        switch unit {
        case .day:
            return String(localized: "settings.usage.chart.soFar.day",
                          defaultValue: "so far today")
        case .week:
            return String(localized: "settings.usage.chart.soFar.week",
                          defaultValue: "this week so far")
        case .month:
            return String(localized: "settings.usage.chart.soFar.month",
                          defaultValue: "this month so far")
        }
    }

    // MARK: Line one — the active measure

    /// The active measure's own sentence for one period, opening with the
    /// period's name and closing with the "so far" clause where one is due.
    static func line1(
        metric: UsageChartMetric,
        bucket: GatewayUsageActivityBucket,
        unit: UsageActivityUnit,
        split: [String?: Int] = [:],
        segments: [UsageChartSegment] = [],
        calendar: Calendar = .current
    ) -> String {
        var parts = [periodLabel(bucket, unit: unit, calendar: calendar)]
        parts.append(contentsOf: body(metric: metric, bucket: bucket, split: split,
                                      segments: segments))
        if bucket.endsMidPeriod {
            parts.append(soFarClause(unit))
        }
        return parts.joined(separator: " · ")
    }

    /// Everything between the period's name and the "so far" clause. Empty for
    /// the sentences that already say the whole thing in one clause.
    private static func body(
        metric: UsageChartMetric,
        bucket: GatewayUsageActivityBucket,
        split: [String?: Int],
        segments: [UsageChartSegment]
    ) -> [String] {
        // NO ATTEMPTS IS ONE SENTENCE FOR EVERY MEASURE. A period nobody used
        // has no turns, no tokens and no outcomes, and five different ways of
        // saying that would each be a fact about the measure rather than about
        // the period.
        guard bucket.attempts > 0 else {
            return [String(localized: "settings.usage.chart.selection.none",
                           defaultValue: "no attempts")]
        }

        switch metric {
        case .turns:
            return [String(
                localized: "settings.usage.chart.clause.turns",
                defaultValue: "\(bucket.turns) turns · \(bucket.attempts) attempts")]
        case .tokens:
            // ITS OWN SENTENCE, longer than line two's clause: this line IS the
            // Tokens measure's answer, and "no token data" alone reads as a
            // fragment where a headline belongs.
            guard bucket.tokenMeasuredAttempts > 0 else {
                return [String(localized: "settings.usage.chart.selection.tokens.none",
                               defaultValue: "no token data recorded")]
            }
            return [String(
                localized: "settings.usage.chart.selection.tokens.v2",
                defaultValue: "\(bucket.reportedTokens.formatted(.number)) tokens")]
        case .reliability:
            return resultsBody(bucket)
        case .devices, .gateways:
            var parts = [String(
                localized: "settings.usage.chart.clause.attempts",
                defaultValue: "\(bucket.attempts) attempts")]
            for segment in segments {
                let count = segment.attempts(in: split)
                guard count > 0 else { continue }
                parts.append(segmentClause(count: count, segment: segment))
            }
            return parts
        }
    }

    /// One segment's share of a period. The two unnamed roles read as ordinary
    /// English rather than as the legend's capitalised labels — "· 2 other"
    /// belongs in a sentence, "Other" belongs beside a colour dot.
    private static func segmentClause(count: Int, segment: UsageChartSegment) -> String {
        switch segment.role {
        case .named:
            return String(localized: "settings.usage.chart.segment.count",
                          defaultValue: "\(count) \(segment.label)")
        case .other:
            return String(localized: "settings.usage.chart.segment.other.count",
                          defaultValue: "\(count) other")
        case .notRecorded:
            return String(localized: "settings.usage.chart.segment.notRecorded.count",
                          defaultValue: "\(count) not recorded")
        }
    }

    /// The Results sentence. `otherOutcomeAttempts` covers cancellations,
    /// unclassifiable landings and rows still open — it is NEVER called "not
    /// finished" (a cancellation finished) and never painted into the stack (it
    /// is not a failure).
    private static func resultsBody(_ bucket: GatewayUsageActivityBucket) -> [String] {
        guard bucket.resolvedAttempts > 0 else {
            return [String(
                localized: "settings.usage.chart.selection.results.none",
                defaultValue: """
                    nothing succeeded or failed — \(bucket.otherOutcomeAttempts) \
                    with another outcome
                    """)]
        }
        var parts = [
            String(localized: "settings.usage.chart.selection.results.succeeded",
                   defaultValue: "\(bucket.succeededAttempts) succeeded"),
            String(localized: "settings.usage.chart.selection.results.failed",
                   defaultValue: "\(bucket.failedAttempts) failed")
        ]
        if bucket.otherOutcomeAttempts > 0 {
            parts.append(String(
                localized: "settings.usage.chart.selection.results.other",
                defaultValue: "\(bucket.otherOutcomeAttempts) with another outcome"))
        }
        return parts
    }

    // MARK: Line two — the other measures

    /// What the OTHER measures say about the same period, in a fixed order so
    /// the eye lands in the same place on every scrub. The active measure's own
    /// clause is omitted — repeating line one underneath itself is noise — and
    /// the two dimension measures, whose line one is the split, show all three.
    ///
    /// COUNTS OF COUNTS, NEVER BARE PERCENTAGES: "11 of 14 succeeded" carries
    /// its own denominator, and "79%" over fourteen attempts does not.
    static func line2(
        metric: UsageChartMetric,
        bucket: GatewayUsageActivityBucket
    ) -> String {
        guard bucket.attempts > 0 else { return "" }
        var parts: [String] = []
        if metric != .turns {
            parts.append(String(
                localized: "settings.usage.chart.clause.turns",
                defaultValue: "\(bucket.turns) turns · \(bucket.attempts) attempts"))
        }
        if metric != .reliability {
            parts.append(resultsClause(bucket))
        }
        if metric != .tokens {
            parts.append(tokensClause(bucket))
        }
        return parts.joined(separator: " · ")
    }

    private static func resultsClause(_ bucket: GatewayUsageActivityBucket) -> String {
        guard bucket.resolvedAttempts > 0 else {
            return String(localized: "settings.usage.chart.clause.results.none",
                          defaultValue: "nothing succeeded or failed")
        }
        return String(
            localized: "settings.usage.chart.clause.results",
            defaultValue: """
                \(bucket.succeededAttempts) of \(bucket.resolvedAttempts) succeeded
                """)
    }

    /// THE ZERO-TOKEN LIE, FIXED. A period whose attempts reported nothing has
    /// `reportedTokens == 0` and `tokenMeasuredAttempts == 0`, and printing "0
    /// tokens" for it claims a free period rather than an unmeasured one.
    ///
    /// COMPACT, unlike the Tokens measure's own line above: this is the third
    /// clause on a context line, and a seven-digit figure there crowds out the
    /// two clauses beside it. Same notation as the Tokens stat tile and the
    /// chart's own y axis, so one period reads the same way wherever it is
    /// glanced at rather than stated.
    static func tokensClause(_ bucket: GatewayUsageActivityBucket) -> String {
        guard bucket.tokenMeasuredAttempts > 0 else {
            return String(localized: "settings.usage.chart.clause.tokens.none",
                          defaultValue: "no token data")
        }
        return String(
            localized: "settings.usage.chart.clause.tokens",
            defaultValue: """
                \(bucket.reportedTokens.formatted(.number.notation(.compactName))) tokens
                """)
    }
}

// MARK: - Audio graph descriptor

/// The chart as an audio graph. A plain value type holding the same buckets the
/// bars are drawn from, wording each period through the same pure helper the
/// caption uses — so nothing the descriptor says can disagree with what a
/// sighted reader is shown.
///
/// The sentences are built INSIDE the two protocol methods rather than at
/// construction: this value is rebuilt on every body pass, VoiceOver asks for
/// the descriptor rarely, and the work is a date format plus a handful of
/// string-catalog lookups per period. See `descriptor(stack:)`.
///
/// The x axis is CATEGORICAL over period names rather than numeric over dates:
/// the periods are discrete bars, and a continuous date axis would invite
/// VoiceOver to interpolate between two weeks that have nothing between them.
private struct UsageActivityChartDescriptor: AXChartDescriptorRepresentable {
    struct Point {
        let category: String
        let value: Double
        let label: String
    }

    let title: String
    let seriesName: String
    let axisName: String
    let valueName: String
    let metric: UsageChartMetric
    let unit: UsageActivityUnit
    let buckets: [GatewayUsageActivityBucket]
    let segments: [UsageChartSegment]

    private func makePoints() -> [Point] {
        let calendar = Calendar.current
        let isDimensional = metric.isDimensional
        return buckets.map { bucket in
            Point(
                category: UsageActivitySentence.periodLabel(
                    bucket, unit: unit, calendar: calendar),
                value: Double(UsageActivityChart.plottedTotal(bucket, metric: metric)),
                label: UsageActivitySentence.line1(
                    metric: metric,
                    bucket: bucket,
                    unit: unit,
                    split: isDimensional
                        ? UsageActivityChart.dimensionSplit(bucket, metric: metric) : [:],
                    segments: segments,
                    calendar: calendar
                )
            )
        }
    }

    func makeChartDescriptor() -> AXChartDescriptor {
        let points = makePoints()
        let xAxis = AXCategoricalDataAxisDescriptor(
            title: axisName,
            categoryOrder: points.map(\.category)
        )
        // A zero-height upper bound would make every point sit on the floor of
        // an axis with no extent; one keeps the range non-degenerate for a
        // metric that measured nothing.
        let upper = max(points.map(\.value).max() ?? 0, 1)
        let yAxis = AXNumericDataAxisDescriptor(
            title: valueName,
            range: 0...upper,
            gridlinePositions: [],
            valueDescriptionProvider: { $0.formatted(.number.precision(.fractionLength(0))) }
        )
        let series = AXDataSeriesDescriptor(
            name: seriesName,
            isContinuous: false,
            dataPoints: points.map {
                AXDataPoint(x: $0.category, y: $0.value, additionalValues: [], label: $0.label)
            }
        )
        return AXChartDescriptor(
            title: title,
            summary: nil,
            xAxis: xAxis,
            yAxis: yAxis,
            additionalAxes: [],
            series: [series]
        )
    }

    func updateChartDescriptor(_ descriptor: AXChartDescriptor) {
        let points = makePoints()
        descriptor.title = title
        descriptor.xAxis = AXCategoricalDataAxisDescriptor(
            title: axisName,
            categoryOrder: points.map(\.category)
        )
        descriptor.series = [
            AXDataSeriesDescriptor(
                name: seriesName,
                isContinuous: false,
                dataPoints: points.map {
                    AXDataPoint(x: $0.category, y: $0.value, additionalValues: [], label: $0.label)
                }
            )
        ]
    }
}
