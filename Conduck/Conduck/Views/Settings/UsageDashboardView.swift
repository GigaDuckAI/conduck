// SPDX-License-Identifier: Apache-2.0

// Conduck
// UsageDashboardView.swift
//
// Settings ▸ Usage — the read surface over the gateway-attempt ledger. One
// screen: how much you used your gateway, how often it answered, how long it
// took, and what it reported about tokens. Nothing here is a score, a streak or
// a goal; the product intent is measurement, and a number that would push
// someone to use Conduck more does not belong on it.
//
// `UsageDashboardContent` owns BOTH the cards and their container — a
// `PlatformSettingsForm`, a grouped `Form` on iOS and a hand-drawn
// `SettingsCard` stack (scroll surface, window gutter and reading rail
// included) on macOS. The container lives inside this view rather than at its
// call sites so the lifecycle modifiers — the deferred first load, the roster
// read — hang off the container rather than off the section tree, which on
// macOS is decomposed section by section by `Group(sections:)`. Every
// conditional below therefore wraps a WHOLE `Section`: that helper counts
// declarations, so narrowing one to wrap content INSIDE a section would
// silently change how many cards macOS draws with nothing to catch it at
// compile time.
//
// Two entry shapes wrap it:
//   • `UsageDashboardView` adds the nav chrome — the iPhone Settings push and
//     the iPad split-view detail.
//   • `MacUsageCategory` mounts it bare as a macOS Settings category.
//
// THE MODEL IS INJECTED BY THE HOST, not owned here — the `DiagnosticsRunner`
// posture. The iPad and Mac hosts rebuild the detail view on every sidebar
// switch, so a self-owned model would refetch the whole ledger each time the
// user came back. The iPhone push has no such host, so it self-owns.
//
// EVERY FIGURE CARRIES ITS DENOMINATOR. A median with no sample count, a token
// sum with no coverage, a success rate with no statement of what resolved — each
// of those is a claim the ledger cannot support, because capture is fail-open
// (a dispatch that could not be recorded still happened) and a generic gateway
// promises no usage metadata at all. So `n` sits beside the median, per-field
// coverage sits beside every token sum, and the outcome mix is reported whole so
// a healthy-looking success rate can never be read as the whole story.
//
// CHART DISCIPLINE. One series, one measure, one y-scale, no legend — the card's
// header names the series. The grid is recessive, values appear on SELECTION
// rather than on every bar, and the bars carry the brand amber because they are
// one quantity, not a category. Status colour is reserved for the outcome rows,
// where it always travels with an icon AND a label so colour is never the only
// carrier of meaning.
//
// CONTENT-FREE, AND THAT IS RELEASE-BLOCKING. Nothing rendered here is prompt or
// reply text, a URL, a host, a token, a provider error string or an HTTP status.
// The gateway rows show a SLOT's display name resolved from the roster at render
// time — never a stored name, which would be a stale copy of a setting the user
// can edit, and never the endpoint behind it.

import Charts
import SwiftUI

// MARK: - Nav-chrome wrapper (iPhone push · iPad detail)

#if os(iOS)
/// The iOS entry shape. Nav chrome only — `UsageDashboardContent` brings its own
/// container.
struct UsageDashboardView: View {
    private let model: UsageDashboardModel?

    /// `model:` lets a longer-lived host (the iPad `IpadSettingsView`) inject a
    /// PERSISTENT model so a Settings tab-switch doesn't refetch the ledger. The
    /// iPhone push passes nothing and the content self-owns one.
    init(model: UsageDashboardModel? = nil) {
        self.model = model
    }

    var body: some View {
        UsageDashboardContent(model: model)
            .navigationTitle(Text(UsageDashboardIdentity.title))
            .navigationBarTitleDisplayMode(.inline)
    }
}
#endif

// MARK: - Shared strings

/// The screen's identity, declared once because THREE independent hosts render
/// it — the iPhone Settings row, the iPad sidebar and the macOS sidebar each
/// keep their own category enum, and a title or glyph copied into all three is a
/// drift waiting to happen.
enum UsageDashboardIdentity {
    static let title = LocalizedStringResource(
        "settings.usage.title", defaultValue: "Usage")

    static let systemImage = "chart.bar.xaxis"
}

// MARK: - Shared content

struct UsageDashboardContent: View {
    @State private var model: UsageDashboardModel

    /// The display roster for gateway slots, read once when the screen opens.
    /// `gatewayBadgeRoster()` rather than the live roster on purpose: usage
    /// history outlives a gateway the user has since forgotten, and a retired
    /// slot still deserves its name rather than its raw token.
    @State private var gatewayRoster: [CustomGateway] = []

    /// The day under the pointer / finger in the activity chart. Raw, because a
    /// date scale reports where the gesture landed rather than which bar it hit;
    /// the bucket is resolved by calendar day below.
    @State private var rawSelectedDay: Date?

    /// Drives the stat-row layout: side by side at normal text sizes, stacked at
    /// accessibility sizes where three columns would crush every value.
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// Two ownership modes, mirroring `DiagnosticsContent`:
    ///   • `model: nil` (default) — SELF-OWNS a fresh model (the iPhone push).
    ///   • `model:` injected — ADOPTS one owned by a longer-lived host
    ///     (`MacSettingsView` / `IpadSettingsView`) so it survives a category
    ///     switch with its already-loaded summary intact.
    init(model: UsageDashboardModel? = nil) {
        _model = State(initialValue: model ?? UsageDashboardModel())
    }

    var body: some View {
        @Bindable var boundModel = model

        PlatformSettingsForm {
            rangeSection(selection: $boundModel.range)

            if let loadError = model.loadError {
                errorSection(loadError)
            }

            if !model.hasLoaded {
                loadingSection
            } else if !model.hasAnyRecordedAttempts {
                // A LOAD THAT THREW MAY NOT MAKE THIS CLAIM. `hasAnyRecordedAttempts`
                // is assigned from the fetch, so it is still at its initial `false`
                // when the fetch never returned — "no usage recorded yet" would then
                // be an affirmative statement about the user's history made from no
                // evidence, sitting directly under a row saying the history could not
                // be read. The error section above stands alone instead, with its own
                // Try Again.
                if model.loadError == nil {
                    emptyStateSection
                }
            } else if model.summary.isEmpty {
                emptyRangeSection
            } else {
                activitySection
                reliabilitySection
                responseTimeSection
                tokensSection
                if !model.summary.byGateway.isEmpty {
                    gatewaySection
                }
            }

            if model.hasLoaded {
                coverageSection
            }
        }
        .scrollContentBackground(.hidden)
        // Deferred first load — the hosts build the model whether or not anyone
        // opens Usage, so the whole-ledger sweep waits until the screen is on
        // screen. Latched inside the model, so a re-fired `.task` costs nothing.
        .task { await model.start() }
        // Display names only. Read once: a roster change while the screen is
        // open renames a row, which is not worth an observer.
        .task { gatewayRoster = await SettingsManager.shared.gatewayBadgeRoster() }
    }

    // MARK: - Range

    private func rangeSection(selection: Binding<UsageDashboardModel.Range>) -> some View {
        Section {
            Picker(selection: selection) {
                ForEach(UsageDashboardModel.Range.allCases) { range in
                    Text(range.title).tag(range)
                }
            } label: {
                Text(LocalizedStringResource(
                    "settings.usage.range.label", defaultValue: "Range"))
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .tint(AppColors.brandAmber)
            .settingsCardPassiveRow()
        }
    }

    // MARK: - Transient states

    /// A fetch that threw. The previous summary stays on screen underneath: a
    /// transient Core Data failure is a worse reason to blank a chart than to
    /// leave one a few seconds stale.
    private func errorSection(_ message: String) -> some View {
        Section {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(AppColors.warning)
                Text(message)
                    .foregroundStyle(AppColors.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 12)
                Button {
                    model.refresh()
                } label: {
                    Text(LocalizedStringResource(
                        "settings.usage.error.retry", defaultValue: "Try Again"))
                }
                .buttonStyle(.bordered)
            }
            .settingsCardPassiveRow()
            .accessibilityElement(children: .combine)
        }
    }

    private var loadingSection: some View {
        Section {
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text(LocalizedStringResource(
                    "settings.usage.loading", defaultValue: "Reading your history…"))
                    .foregroundStyle(AppColors.textSecondary)
            }
            .settingsCardPassiveRow()
        }
    }

    /// Nothing has EVER been recorded. Distinct from an empty range, and the
    /// distinction matters: this user has no measurement to look at yet, rather
    /// than none in the last 90 days.
    private var emptyStateSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Text(LocalizedStringResource(
                    "settings.usage.empty.title",
                    defaultValue: "No usage recorded yet"))
                    .font(.headline)
                    .foregroundStyle(AppColors.textPrimary)
                Text(LocalizedStringResource(
                    "settings.usage.empty.body",
                    defaultValue: """
                        Usage appears here after your next conversation. Conduck \
                        measures the requests it sends to your gateway, and keeps \
                        the measurements on your own devices.
                        """))
                    .font(.subheadline)
                    .foregroundStyle(AppColors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .settingsCardPassiveRow()
            .accessibilityElement(children: .combine)
        }
    }

    /// History exists, but none of it lands in the selected window.
    private var emptyRangeSection: some View {
        Section {
            Text(LocalizedStringResource(
                "settings.usage.emptyRange",
                defaultValue: "No activity in this range. Try a longer one."))
                .foregroundStyle(AppColors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .settingsCardPassiveRow()
        } header: {
            Text(LocalizedStringResource(
                "settings.usage.activity.header", defaultValue: "Activity"))
        }
    }

    // MARK: - Activity

    private var activitySection: some View {
        Section {
            statRow
            if !model.summary.dailyActivity.isEmpty {
                activityChart
            }
        } header: {
            Text(LocalizedStringResource(
                "settings.usage.activity.header", defaultValue: "Activity"))
        } footer: {
            Text(LocalizedStringResource(
                "settings.usage.activity.footer",
                defaultValue: """
                    A turn is one thing you sent. Retries are counted separately, \
                    under Reliability, so trying again never inflates your activity.
                    """))
        }
    }

    private var statRow: some View {
        let summary = model.summary
        return statLayout {
            statTile(
                value: summary.attemptedTurns.formatted(.number),
                label: LocalizedStringResource(
                    "settings.usage.stat.turns", defaultValue: "Turns"),
                accessibility: LocalizedStringResource(
                    "settings.usage.stat.turns.a11y",
                    defaultValue: "\(summary.attemptedTurns) turns sent")
            )
            statTile(
                value: summary.completedTurns.formatted(.number),
                label: LocalizedStringResource(
                    "settings.usage.stat.completed", defaultValue: "Completed"),
                accessibility: LocalizedStringResource(
                    "settings.usage.stat.completed.a11y",
                    defaultValue: "\(summary.completedTurns) turns completed")
            )
            statTile(
                value: summary.activeConversations.formatted(.number),
                label: LocalizedStringResource(
                    "settings.usage.stat.conversations", defaultValue: "Conversations"),
                accessibility: LocalizedStringResource(
                    "settings.usage.stat.conversations.a11y",
                    defaultValue: "\(summary.activeConversations) conversations active")
            )
        }
        .settingsCardPassiveRow()
    }

    /// Turns per day. ONE series, so no legend — the header names it — and no
    /// value on any bar; the caption above swaps to the selected day's numbers
    /// instead, which is the only place a number appears.
    private var activityChart: some View {
        let buckets = model.summary.dailyActivity
        let selected = selectedBucket(in: buckets)

        return VStack(alignment: .leading, spacing: 8) {
            chartCaption(selected: selected)

            Chart(buckets) { bucket in
                BarMark(
                    x: .value(
                        String(localized: "settings.usage.chart.axis.day", defaultValue: "Day"),
                        bucket.day,
                        unit: .day
                    ),
                    y: .value(
                        String(localized: "settings.usage.chart.axis.turns", defaultValue: "Turns"),
                        bucket.turns
                    )
                )
                .cornerRadius(2)
                // The whole series is one colour. A selection dims the rest
                // rather than repainting the chosen bar, so the bar the user
                // pointed at keeps the colour it already had.
                .foregroundStyle(
                    AppColors.brandAmber.opacity(
                        selected == nil || selected?.day == bucket.day ? 1 : 0.35
                    )
                )
            }
            .chartXSelection(value: $rawSelectedDay)
            .chartYScale(domain: .automatic(includesZero: true))
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                    AxisGridLine()
                        .foregroundStyle(AppColors.borderSubtle)
                    AxisValueLabel {
                        if let count = value.as(Int.self) {
                            Text(count.formatted(.number))
                                .foregroundStyle(AppColors.textTertiary)
                        }
                    }
                }
            }
            // No x grid lines: the bars already stand on the day boundary, and a
            // second set of rules behind them is noise. `.aligned` keeps the
            // edge labels inside the plot area — a centered label on the last
            // tick would hang past the trailing edge and clip ("24. Aug" → "2").
            .chartXAxis {
                AxisMarks(preset: .aligned, values: .automatic(desiredCount: 4)) { _ in
                    AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                        .foregroundStyle(AppColors.textTertiary)
                }
            }
            .frame(height: 150)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(LocalizedStringResource(
                "settings.usage.chart.a11y",
                defaultValue: "Turns per day, \(model.summary.attemptedTurns) in total")))
        }
        .settingsCardPassiveRow()
    }

    /// The chart's one number line: the series name at rest, the selected day's
    /// turns and attempts while a bar is picked.
    private func chartCaption(selected: GatewayUsageDailyBucket?) -> some View {
        Group {
            if let selected {
                Text(LocalizedStringResource(
                    "settings.usage.chart.selection",
                    defaultValue: """
                        \(selected.day.formatted(date: .abbreviated, time: .omitted)) · \
                        \(selected.turns) turns · \(selected.attempts) attempts
                        """))
                    .foregroundStyle(AppColors.textPrimary)
            } else {
                Text(LocalizedStringResource(
                    "settings.usage.chart.caption", defaultValue: "Turns per day"))
                    .foregroundStyle(AppColors.textTertiary)
            }
        }
        .font(.caption)
        .monospacedDigit()
    }

    /// A date scale reports the instant under the gesture, not the bar beneath
    /// it, so the bucket is matched by calendar day.
    private func selectedBucket(
        in buckets: [GatewayUsageDailyBucket]
    ) -> GatewayUsageDailyBucket? {
        guard let rawSelectedDay else { return nil }
        return buckets.first {
            Calendar.current.isDate($0.day, inSameDayAs: rawSelectedDay)
        }
    }

    // MARK: - Reliability

    private var reliabilitySection: some View {
        let summary = model.summary

        return Section {
            headlineRow(
                value: percentText(summary.resolvedAttemptSuccessRate),
                label: LocalizedStringResource(
                    "settings.usage.reliability.headline",
                    defaultValue: "of resolved attempts succeeded"),
                accessibility: LocalizedStringResource(
                    "settings.usage.reliability.headline.a11y",
                    defaultValue: """
                        \(percentText(summary.resolvedAttemptSuccessRate)) of \
                        resolved attempts succeeded
                        """)
            )

            outcomeRows

            valueRow(
                label: LocalizedStringResource(
                    "settings.usage.reliability.retryRate", defaultValue: "Retry rate"),
                value: percentText(summary.retryRate),
                caption: LocalizedStringResource(
                    "settings.usage.reliability.retryRate.caption",
                    defaultValue: "\(summary.retriedTurns) of \(summary.attemptedTurns) turns retried")
            )
            valueRow(
                label: LocalizedStringResource(
                    "settings.usage.reliability.attemptsPerTurn",
                    defaultValue: "Attempts per completed turn"),
                value: decimalText(summary.attemptsPerCompletedTurn),
                caption: nil
            )
            if summary.truncatedReplies > 0 {
                valueRow(
                    label: LocalizedStringResource(
                        "settings.usage.reliability.truncated",
                        defaultValue: "Replies cut short"),
                    value: summary.truncatedReplies.formatted(.number),
                    caption: nil,
                    icon: "scissors"
                )
            }
        } header: {
            Text(LocalizedStringResource(
                "settings.usage.reliability.header", defaultValue: "Reliability"))
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text(LocalizedStringResource(
                    "settings.usage.reliability.footer",
                    defaultValue: """
                        The success rate counts only attempts that finished as a \
                        success or a failure. Cancelled and unconfirmed attempts \
                        are listed above but stay out of it.
                        """))
                if summary.truncatedReplies > 0 {
                    Text(LocalizedStringResource(
                        "settings.usage.reliability.truncated.footer",
                        defaultValue: """
                            Cut short means the gateway reported it stopped at the \
                            reply-length limit, not that anything went wrong.
                            """))
                }
            }
        }
    }

    /// The outcome mix, reported WHOLE — a high unconfirmed count is exactly
    /// what stops the success rate above from being read as the whole story.
    ///
    /// Lifted out of the section rather than declared inline: it keeps the
    /// section's own child count well clear of `ViewBuilder`'s ten. Lifting is
    /// safe because macOS resolves card rows by SHAPE — a child that emits
    /// several views is several rows — so every row below is still its own card
    /// row, exactly as if it had been written in place.
    ///
    /// Succeeded and failed are always shown; the rest appear only when they
    /// happened. A row of zeros for states most users never hit would bury the
    /// two numbers that matter under noise.
    @ViewBuilder
    private var outcomeRows: some View {
        let mix = model.summary.outcomeMix
        let inProgress = mix.inFlight + mix.pending

        outcomeRow(
            icon: "checkmark.circle.fill",
            tint: AppColors.success,
            label: LocalizedStringResource(
                "settings.usage.outcome.succeeded", defaultValue: "Succeeded"),
            count: mix.succeeded
        )
        outcomeRow(
            icon: "xmark.circle.fill",
            tint: AppColors.error,
            label: LocalizedStringResource(
                "settings.usage.outcome.failed", defaultValue: "Failed"),
            count: mix.failed
        )
        if mix.cancelled > 0 {
            outcomeRow(
                icon: "stop.circle",
                tint: AppColors.textSecondary,
                label: LocalizedStringResource(
                    "settings.usage.outcome.cancelled", defaultValue: "Cancelled"),
                count: mix.cancelled
            )
        }
        // Stored `unknown` — a landing this device saw but could not classify.
        // Kept apart from `unconfirmed` below, which is the opposite situation:
        // no landing reached this device at all.
        if mix.unknown > 0 {
            outcomeRow(
                icon: "questionmark.diamond",
                tint: AppColors.warning,
                label: LocalizedStringResource(
                    "settings.usage.outcome.unknown", defaultValue: "Unclassified"),
                count: mix.unknown
            )
        }
        if mix.unconfirmed > 0 {
            outcomeRow(
                icon: "questionmark.circle",
                tint: AppColors.warning,
                label: LocalizedStringResource(
                    "settings.usage.outcome.unconfirmed", defaultValue: "Unconfirmed"),
                count: mix.unconfirmed
            )
        }
        // Outside every rate on purpose: an attempt still running has no outcome
        // to be counted for or against.
        if inProgress > 0 {
            outcomeRow(
                icon: "ellipsis.circle",
                tint: AppColors.textTertiary,
                label: LocalizedStringResource(
                    "settings.usage.outcome.inProgress", defaultValue: "In progress"),
                count: inProgress
            )
        }
    }

    // MARK: - Response time

    private var responseTimeSection: some View {
        let timing = model.summary.responseTime

        return Section {
            if timing.sampleCount == 0 {
                Text(LocalizedStringResource(
                    "settings.usage.response.none",
                    defaultValue: "No attempt in this range finished with usable timing."))
                    .foregroundStyle(AppColors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .settingsCardPassiveRow()
            } else {
                statLayout {
                    statTile(
                        value: durationText(timing.median),
                        label: LocalizedStringResource(
                            "settings.usage.response.median", defaultValue: "Median"),
                        accessibility: LocalizedStringResource(
                            "settings.usage.response.median.a11y",
                            defaultValue: "Median full-response time \(durationText(timing.median))"),
                        prominent: true
                    )
                    // Withheld below the aggregator's minimum sample count: a
                    // p90 over a handful of attempts is interpolating between
                    // the two slowest and would read as precision it lacks.
                    if let p90 = timing.p90 {
                        statTile(
                            value: durationText(p90),
                            label: LocalizedStringResource(
                                "settings.usage.response.p90",
                                defaultValue: "90th percentile"),
                            accessibility: LocalizedStringResource(
                                "settings.usage.response.p90.a11y",
                                defaultValue: "90th percentile full-response time \(durationText(p90))"),
                            prominent: true
                        )
                    }
                }
                .settingsCardPassiveRow()

                Text(sampleCaption(count: timing.sampleCount))
                    .font(.caption)
                    .foregroundStyle(AppColors.textTertiary)
                    .settingsCardPassiveRow()
            }
        } header: {
            Text(LocalizedStringResource(
                "settings.usage.response.header", defaultValue: "Full-response time"))
        } footer: {
            Text(LocalizedStringResource(
                "settings.usage.response.footer",
                defaultValue: """
                    Measured from sending to the reply landing, so it includes the \
                    network, any tools your agent ran, and the agent's own work — \
                    it is not model latency.
                    """))
        }
    }

    // MARK: - Tokens

    private var tokensSection: some View {
        let tokens = model.summary.tokens

        return Section {
            if tokens.isEmpty {
                Text(LocalizedStringResource(
                    "settings.usage.tokens.none",
                    defaultValue: "Not reported by your gateway."))
                    .foregroundStyle(AppColors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .settingsCardPassiveRow()
            } else {
                tokenRow(
                    label: LocalizedStringResource(
                        "settings.usage.tokens.input", defaultValue: "Input"),
                    field: tokens.input
                )
                tokenRow(
                    label: LocalizedStringResource(
                        "settings.usage.tokens.output", defaultValue: "Output"),
                    field: tokens.output
                )
                if tokens.reportedTotal.isReported {
                    tokenRow(
                        label: LocalizedStringResource(
                            "settings.usage.tokens.total", defaultValue: "Total"),
                        field: tokens.reportedTotal
                    )
                } else if let components = tokens.calculatedKnownComponents {
                    // NOT labelled "Total". This is input plus output as
                    // reported; whatever the gateway counted in its own total
                    // and reported in neither component is silently missing from
                    // it, which is exactly why it does not get to wear the word.
                    valueRow(
                        label: LocalizedStringResource(
                            "settings.usage.tokens.components",
                            defaultValue: "Input + output"),
                        value: components.formatted(.number),
                        caption: LocalizedStringResource(
                            "settings.usage.tokens.components.caption",
                            defaultValue: "Added up from the fields above — your gateway reported no total")
                    )
                }
            }
        } header: {
            Text(LocalizedStringResource(
                "settings.usage.tokens.header", defaultValue: "Reported tokens"))
        } footer: {
            Text(LocalizedStringResource(
                "settings.usage.tokens.footer",
                defaultValue: """
                    These are your gateway's own numbers, for the attempts it \
                    reported them on. Gateways are not required to report usage, \
                    and what one counts in a turn may differ from another.
                    """))
        }
    }

    private func tokenRow(
        label: LocalizedStringResource,
        field: GatewayUsageTokenField
    ) -> some View {
        valueRow(
            label: label,
            value: field.sum.map { $0.formatted(.number) }
                ?? String(localized: "settings.usage.tokens.absent",
                          defaultValue: "Not reported"),
            caption: coverageCaption(field)
        )
    }

    /// Per FIELD, never one number for the card: a gateway that reports input
    /// but not output is common, and a single coverage figure would claim a
    /// completeness neither field has.
    private func coverageCaption(_ field: GatewayUsageTokenField) -> LocalizedStringResource? {
        guard field.isReported, let coverage = field.coverage else { return nil }
        return LocalizedStringResource(
            "settings.usage.tokens.coverage",
            defaultValue: "Reported on \(percentText(coverage)) of attempts")
    }

    // MARK: - By gateway

    private var gatewaySection: some View {
        Section {
            ForEach(model.summary.byGateway) { group in
                gatewayGroupRow(group)
            }
        } header: {
            Text(LocalizedStringResource(
                "settings.usage.byGateway.header", defaultValue: "By gateway"))
        } footer: {
            Text(LocalizedStringResource(
                "settings.usage.byGateway.footer",
                defaultValue: """
                    Grouped by the gateway a conversation was bound to when it \
                    sent. A gateway you have since edited or removed still \
                    appears for the history it made.
                    """))
        }
    }

    /// ONE row per gateway — a `VStack`, deliberately, because macOS resolves a
    /// child's row count from its SHAPE and two loose `Text`s here would become
    /// two separated card rows.
    private func gatewayGroupRow(_ group: GatewayUsageGroup) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(gatewayLabel(for: group.key))
                    .font(.body.weight(.semibold))
                    .foregroundStyle(AppColors.textPrimary)
                Spacer(minLength: 8)
                Text(attemptsText(group.attempts))
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(AppColors.textSecondary)
            }

            Text(groupDetailText(group))
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(AppColors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            // Only when the slot actually saw more than one model — a
            // single-model breakdown would just restate the line above it.
            ForEach(group.models) { modelGroup in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(modelLabel(for: modelGroup.key))
                        .font(.caption)
                        .foregroundStyle(AppColors.textSecondary)
                    Spacer(minLength: 8)
                    Text(modelDetailText(modelGroup))
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(AppColors.textTertiary)
                }
                .padding(.leading, 12)
            }
        }
        .settingsCardPassiveRow()
        .accessibilityElement(children: .combine)
    }

    private func groupDetailText(_ group: GatewayUsageGroup) -> String {
        var parts: [String] = [
            String(localized: "settings.usage.byGateway.successRate",
                   defaultValue: "\(percentText(group.successRate)) succeeded")
        ]
        if let median = group.medianResponseTime {
            parts.append(String(
                localized: "settings.usage.byGateway.median",
                defaultValue: "median \(durationText(median)) (n \(group.responseSampleCount))"))
        }
        // SAME RULE AS THE TOKENS CARD, which sits on this very screen showing the
        // same underlying numbers: a gateway-reported total renders bare, a client
        // sum of the components never does. Dropping the qualifier here would
        // present a Conduck-computed figure as the gateway's own number in the one
        // place gateways are compared against each other.
        if let total = group.tokens.reportedTotal.sum {
            parts.append(String(
                localized: "settings.usage.byGateway.tokens",
                defaultValue: "\(total.formatted(.number)) tokens"))
        } else if let components = group.tokens.calculatedKnownComponents {
            parts.append(String(
                localized: "settings.usage.byGateway.tokens.components",
                defaultValue: "\(components.formatted(.number)) tokens (input + output)"))
        }
        return parts.joined(separator: " · ")
    }

    private func modelDetailText(_ group: GatewayUsageGroup) -> String {
        let rate = String(
            localized: "settings.usage.byGateway.successRate",
            defaultValue: "\(percentText(group.successRate)) succeeded")
        return attemptsText(group.attempts) + " · " + rate
    }

    // MARK: - Coverage

    private var coverageSection: some View {
        Section {
            if let measurementStart = model.measurementStart {
                valueRow(
                    label: LocalizedStringResource(
                        "settings.usage.coverage.measuring", defaultValue: "Measuring since"),
                    value: measurementStart.formatted(date: .abbreviated, time: .omitted),
                    caption: nil
                )
            } else {
                Text(LocalizedStringResource(
                    "settings.usage.coverage.notYet",
                    defaultValue: "Measurement starts with your next conversation."))
                    .foregroundStyle(AppColors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .settingsCardPassiveRow()
            }

            // Shown only when retained history reaches back FURTHER than
            // measurement does — where it is the whole point: those turns are
            // real usage with no measurement behind them, and one "data since"
            // date would be false for every user who upgraded into this screen.
            if model.hasUnmeasuredHistory, let historyStart = model.activityHistoryStart {
                valueRow(
                    label: LocalizedStringResource(
                        "settings.usage.coverage.history",
                        defaultValue: "Conversations kept since"),
                    value: historyStart.formatted(date: .abbreviated, time: .omitted),
                    caption: LocalizedStringResource(
                        "settings.usage.coverage.history.caption",
                        defaultValue: "Conversations older than the date above are not measured here")
                )
            }
        } header: {
            Text(LocalizedStringResource(
                "settings.usage.coverage.header", defaultValue: "Coverage"))
        } footer: {
            Text(LocalizedStringResource(
                "settings.usage.coverage.footer",
                defaultValue: """
                    Totals describe conversations you've kept — deleting a \
                    conversation removes its history here.
                    """))
        }
    }

    // MARK: - Row vocabulary

    /// Side by side at normal text sizes, stacked at accessibility sizes. An
    /// `AnyLayout` rather than two branches so the tiles keep their identity
    /// across the switch and the values do not animate in from nothing.
    private func statLayout<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
            : AnyLayout(HStackLayout(alignment: .top, spacing: 16))
        return layout { content() }
    }

    private func statTile(
        value: String,
        label: LocalizedStringResource,
        accessibility: LocalizedStringResource,
        prominent: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(prominent ? .title2.weight(.semibold) : .title3.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(AppColors.textEmphasis)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label)
                .font(.caption)
                .foregroundStyle(AppColors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(accessibility))
    }

    private func headlineRow(
        value: String,
        label: LocalizedStringResource,
        accessibility: LocalizedStringResource
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.title.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(AppColors.textEmphasis)
            Text(label)
                .font(.caption)
                .foregroundStyle(AppColors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .settingsCardPassiveRow()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(accessibility))
    }

    /// Icon + label + count. The colour rides the ICON only, and the label is
    /// always present, so the row still reads on a monochrome display and for a
    /// reader who cannot separate the two status hues.
    private func outcomeRow(
        icon: String,
        tint: Color,
        label: LocalizedStringResource,
        count: Int
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            Text(label)
                .foregroundStyle(AppColors.textPrimary)
            Spacer(minLength: 12)
            Text(count.formatted(.number))
                .monospacedDigit()
                .foregroundStyle(AppColors.textSecondary)
        }
        .settingsCardPassiveRow()
        .accessibilityElement(children: .combine)
    }

    private func valueRow(
        label: LocalizedStringResource,
        value: String,
        caption: LocalizedStringResource?,
        icon: String? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 10) {
                if let icon {
                    Image(systemName: icon)
                        .foregroundStyle(AppColors.textTertiary)
                        .accessibilityHidden(true)
                }
                Text(label)
                    .foregroundStyle(AppColors.textPrimary)
                Spacer(minLength: 12)
                Text(value)
                    .monospacedDigit()
                    .foregroundStyle(AppColors.textSecondary)
            }
            if let caption {
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(AppColors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .settingsCardPassiveRow()
        .accessibilityElement(children: .combine)
    }

    // MARK: - Formatting

    /// Nil is UNAVAILABLE, never zero. An em dash says "we cannot tell you",
    /// which is a different claim from "none succeeded".
    private func percentText(_ value: Double?) -> String {
        guard let value else { return unavailable }
        return value.formatted(.percent.precision(.fractionLength(0)))
    }

    private func decimalText(_ value: Double?) -> String {
        guard let value else { return unavailable }
        return value.formatted(.number.precision(.fractionLength(1)))
    }

    private func durationText(_ seconds: TimeInterval?) -> String {
        guard let seconds else { return unavailable }
        // Under a minute the tenth matters (4.2s reads differently from 4s);
        // past it, minutes and whole seconds are all anyone reads.
        if seconds < 60 {
            return Duration.seconds(seconds).formatted(
                .units(allowed: [.seconds], width: .narrow, fractionalPart: .show(length: 1))
            )
        }
        return Duration.seconds(seconds).formatted(
            .units(allowed: [.hours, .minutes, .seconds], width: .narrow, maximumUnitCount: 2)
        )
    }

    private var unavailable: String {
        String(localized: "settings.usage.unavailable", defaultValue: "—")
    }

    /// Two keys rather than one plural rule: the headless build path that
    /// synthesizes this catalog does not run Xcode's extraction phase, so a
    /// count-driven variation would have to be hand-written into the catalog.
    /// Two flat keys stay correct with no post-processing.
    private func attemptsText(_ count: Int) -> String {
        count == 1
            ? String(localized: "settings.usage.attempts.one", defaultValue: "1 attempt")
            : String(localized: "settings.usage.attempts.other",
                     defaultValue: "\(count) attempts")
    }

    /// `n` and the window, always together and always visible: a median over
    /// three samples is not a claim, and the range is what makes it one.
    private func sampleCaption(count: Int) -> String {
        String(localized: "settings.usage.response.sampleCaption",
               defaultValue: "\(attemptsText(count)) · \(rangeCaption)")
    }

    private var rangeCaption: String {
        switch model.range {
        case .week:
            return String(localized: "settings.usage.rangeCaption.week",
                          defaultValue: "last \(UsageDashboardModel.Range.weekDays) days")
        case .month:
            return String(localized: "settings.usage.rangeCaption.month",
                          defaultValue: "last \(UsageDashboardModel.Range.monthDays) days")
        case .quarter:
            return String(localized: "settings.usage.rangeCaption.quarter",
                          defaultValue: "last \(UsageDashboardModel.Range.quarterDays) days")
        case .all:
            return String(localized: "settings.usage.rangeCaption.all",
                          defaultValue: "all time")
        }
    }

    // MARK: - Slot + model labels

    /// Resolved at RENDER time from the badge roster. A stored name would be a
    /// stale copy of a setting the user can edit; the raw token is the fallback
    /// only when the string is not a ref this build understands.
    private func gatewayLabel(for key: String?) -> String {
        guard let key else {
            return String(localized: "settings.usage.gateway.unattributed",
                          defaultValue: "Not recorded")
        }
        guard let ref = RemoteAgentRef(rawString: key) else { return key }
        return RemoteAgentRefMetadata.displayName(for: ref, customs: gatewayRoster)
    }

    private func modelLabel(for key: String?) -> String {
        key ?? String(localized: "settings.usage.model.default",
                      defaultValue: "Gateway default")
    }
}
