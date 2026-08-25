// SPDX-License-Identifier: Apache-2.0

// Conduck
// UsageDeviceDetailView.swift
//
// Settings ▸ Usage ▸ one device. The same range, narrowed to the hardware that
// sent the requests — which is the question "is it my Watch that keeps failing,
// or my gateway?", and the one breakdown a per-gateway view cannot answer.
//
// THE BUCKET IS A DERIVED READING, not a stored field. A dispatch stamps the
// device that executed it; CarPlay runs on the iPhone and stamps `iphone`, so
// the CarPlay bucket comes from the attempt's SURFACE instead. The derivation
// lives once in the aggregator and this screen only reads it — see
// `UsageDeviceBucket`.
//
// NO TOKENS HERE, and that is deliberate rather than an omission. Tokens are a
// property of the conversation and the gateway that answered it, not of the
// keyboard it was typed on; a per-device token total invites a comparison
// ("the Mac costs more than the phone") that says nothing about either device.
//
// CONTENT-FREE, AND THAT IS RELEASE-BLOCKING. The device names on this screen
// are the app's own words for a hardware CLASS — never the name the user gave a
// device, which the ledger does not hold and this screen could not read.

import SwiftUI

struct UsageDeviceDetailView: View {
    let model: UsageDashboardModel
    let bucket: UsageDeviceBucket

    /// Display names for gateway slots, read once when the screen opens.
    @State private var gatewayRoster: [CustomGateway] = []

    private var summary: GatewayUsageSummary { model.summary(forDevice: bucket) }

    private var title: String { UsageDeviceBucketDisplay.label(bucket) }

    /// The input split is worth a card only when there is a split to show. One
    /// mode at 100% restates the attempt count above it.
    private var inputModes: [InputModeSlice] {
        summary.attributedInputModes.filter { $0.attempts > 0 }
    }

    var body: some View {
        PlatformSettingsForm {
            if summary.isEmpty {
                emptySection
            } else {
                activitySection
                reliabilitySection
                responseTimeSection
                if inputModes.count > 1 {
                    inputSection
                }
                if !summary.attributedGatewayGroups.isEmpty {
                    gatewaySection
                }
            }
        }
        .scrollContentBackground(.hidden)
        #if os(iOS)
        .navigationTitle(Text(verbatim: title))
        .navigationBarTitleDisplayMode(.inline)
        #else
        // macOS: own in-pane header, no native title-bar toolbar, so the
        // Settings sidebar never shifts on push. See `MacSettingsSubScreenChrome`.
        .macSettingsSubScreenChrome(title: title)
        #endif
        .task { gatewayRoster = await SettingsManager.shared.gatewayBadgeRoster() }
    }

    // MARK: - Empty

    private var emptySection: some View {
        Section {
            Text(LocalizedStringResource(
                "settings.usage.detail.empty",
                defaultValue: "Nothing recorded for this in the selected range."))
                .foregroundStyle(AppColors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .settingsCardPassiveRow()
        } footer: {
            Text(UsageDetailFormat.rangeCaption(for: model.range))
        }
    }

    // MARK: - Activity

    private var activitySection: some View {
        Section {
            UsageStatLayout {
                UsageStatTile(
                    value: summary.attemptedTurns.formatted(.number),
                    label: LocalizedStringResource(
                        "settings.usage.stat.turns", defaultValue: "Turns"),
                    accessibility: LocalizedStringResource(
                        "settings.usage.stat.turns.a11y",
                        defaultValue: "\(summary.attemptedTurns) turns sent")
                )
                UsageStatTile(
                    value: summary.recordedAttempts.formatted(.number),
                    label: LocalizedStringResource(
                        "settings.usage.detail.stat.attempts", defaultValue: "Attempts"),
                    accessibility: LocalizedStringResource(
                        "settings.usage.detail.stat.attempts.a11y",
                        defaultValue: "\(summary.recordedAttempts) recorded attempts")
                )
                UsageStatTile(
                    value: summary.completedTurns.formatted(.number),
                    label: LocalizedStringResource(
                        "settings.usage.stat.completed", defaultValue: "Completed"),
                    accessibility: LocalizedStringResource(
                        "settings.usage.stat.completed.a11y",
                        defaultValue: "\(summary.completedTurns) turns completed")
                )
            }
            .settingsCardPassiveRow()

            if !summary.activity.isEmpty {
                // NO Devices MEASURE HERE — this screen is already one device,
                // so the split would draw one segment restating the title. The
                // scope line carries what it would have said.
                UsageActivityChart(
                    activity: summary.activity,
                    recordedAttempts: summary.recordedAttempts,
                    tokenMeasuredAttempts: summary.tokenMeasuredAttempts,
                    gatewayRoster: gatewayRoster,
                    availableMetrics: UsageChartMetric.allCases.filter { $0 != .devices },
                    scope: UsageActivityChart.Scope(
                        name: title,
                        attempts: summary.recordedAttempts,
                        rangeAttempts: model.summary.recordedAttempts
                    )
                )
                .settingsCardPassiveRow()
            }
        } header: {
            Text(LocalizedStringResource(
                "settings.usage.activity.header", defaultValue: "Activity"))
        } footer: {
            Text(UsageDetailFormat.rangeCaption(for: model.range))
        }
    }

    // MARK: - Reliability

    /// Compact: the headline rate, the two delivery rows and whatever was cut
    /// short. The full outcome mix stays on the overview — this card answers
    /// "does this device get answers", not "what is every state an attempt can
    /// be in".
    private var reliabilitySection: some View {
        Section {
            UsageHeadlineRow(
                value: UsageDetailFormat.percentText(summary.resolvedAttemptSuccessRate),
                label: LocalizedStringResource(
                    "settings.usage.reliability.headline",
                    defaultValue: "of resolved attempts succeeded"),
                accessibility: LocalizedStringResource(
                    "settings.usage.reliability.headline.a11y",
                    defaultValue: """
                        \(UsageDetailFormat.percentText(summary.resolvedAttemptSuccessRate)) of \
                        resolved attempts succeeded
                        """)
            )

            UsageDetailRows.reliability(summary)

            if summary.truncatedReplies > 0 {
                UsageValueRow(
                    label: LocalizedStringResource(
                        "settings.usage.reliability.truncated",
                        defaultValue: "Replies cut short"),
                    value: summary.truncatedReplies.formatted(.number),
                    icon: "scissors"
                )
            }
        } header: {
            Text(LocalizedStringResource(
                "settings.usage.reliability.header", defaultValue: "Reliability"))
        } footer: {
            Text(LocalizedStringResource(
                "settings.usage.reliability.footer.rate",
                defaultValue: """
                    Cancelled and unconfirmed attempts stay out of this rate.
                    """))
        }
    }

    // MARK: - Response time

    private var responseTimeSection: some View {
        let timing = summary.responseTime

        return Section {
            if timing.sampleCount == 0 {
                Text(LocalizedStringResource(
                    "settings.usage.response.none",
                    defaultValue: "No attempt in this range finished with usable timing."))
                    .foregroundStyle(AppColors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .settingsCardPassiveRow()
            } else {
                UsageStatLayout {
                    UsageStatTile(
                        value: UsageDetailFormat.durationText(timing.mean),
                        label: LocalizedStringResource(
                            "settings.usage.response.average", defaultValue: "Average"),
                        accessibility: LocalizedStringResource(
                            "settings.usage.response.average.a11y",
                            defaultValue: "Average full-response time \(UsageDetailFormat.durationText(timing.mean))"),
                        prominent: true
                    )
                    // Withheld below the aggregator's minimum sample count,
                    // where a p90 interpolates between the two slowest samples.
                    if let p90 = timing.p90 {
                        UsageStatTile(
                            value: UsageDetailFormat.durationText(p90),
                            label: LocalizedStringResource(
                                "settings.usage.response.p90",
                                defaultValue: "90th percentile"),
                            accessibility: LocalizedStringResource(
                                "settings.usage.response.p90.a11y",
                                defaultValue: "90th percentile full-response time \(UsageDetailFormat.durationText(p90))"),
                            prominent: true
                        )
                    }
                }
                .settingsCardPassiveRow()

                Text(UsageDetailFormat.sampleCaption(count: timing.sampleCount, range: model.range))
                    .font(.caption)
                    .foregroundStyle(AppColors.textTertiary)
                    .settingsCardPassiveRow()
            }
        } header: {
            Text(LocalizedStringResource(
                "settings.usage.response.header", defaultValue: "Full-response time"))
        } footer: {
            Text(LocalizedStringResource(
                "settings.usage.response.footer.scope",
                defaultValue: """
                    Includes the network and any tools your agent ran — not \
                    model latency.
                    """))
        }
    }

    // MARK: - Input split

    /// How the turns from this device were ACQUIRED. The share is of attempts,
    /// stated beside the count rather than instead of it — a percentage alone
    /// hides how small a slice can be.
    private var inputSection: some View {
        let total = inputModes.reduce(0) { $0 + $1.attempts }

        return Section {
            ForEach(inputModes, id: \.mode) { slice in
                UsageValueRow(
                    label: UsageInputModeDisplay.label(slice.mode),
                    value: slice.attempts.formatted(.number),
                    caption: LocalizedStringResource(
                        "settings.usage.detail.input.caption",
                        defaultValue: """
                            \(UsageDetailFormat.percentText(GatewayUsageAggregator.ratio(slice.attempts, total))) \
                            of attempts · \(slice.turns) turns
                            """),
                    icon: UsageInputModeDisplay.icon(slice.mode),
                    iconTint: AppColors.usageIconBlue
                )
            }
        } header: {
            Text(LocalizedStringResource(
                "settings.usage.detail.input.header", defaultValue: "Input"))
        }
        // NO FOOTER — each row already carries its own share and turn count,
        // and the overview's Input card is where a reader arrived from.
    }

    // MARK: - By gateway

    private var gatewaySection: some View {
        Section {
            ForEach(summary.attributedGatewayGroups) { group in
                UsageGroupCompactRow(
                    label: UsageGatewayLabel.name(for: group.key, roster: gatewayRoster),
                    group: group
                )
            }
        } header: {
            Text(LocalizedStringResource(
                "settings.usage.byGateway.header", defaultValue: "By gateway"))
        }
        // NO FOOTER. The overview's own by-gateway card carries the one thing
        // worth saying — that an edited or removed gateway keeps its history —
        // and this screen is only reached from there.
    }
}

// MARK: - Input-mode labels

/// How a turn arrived, as a person reads it. `unknown` is "Not recorded" and
/// never "Other": nothing observed how that turn was given, which is a gap in
/// measurement rather than a fourth way to talk to the app.
enum UsageInputModeDisplay {
    static func label(_ mode: GatewayInputMode) -> LocalizedStringResource {
        switch mode {
        case .text:
            return LocalizedStringResource(
                "settings.usage.detail.input.text", defaultValue: "Typed")
        case .voice:
            return LocalizedStringResource(
                "settings.usage.detail.input.voice", defaultValue: "Voice")
        case .shared:
            return LocalizedStringResource(
                "settings.usage.detail.input.shared", defaultValue: "Shared in")
        case .unknown:
            return LocalizedStringResource(
                "settings.usage.detail.input.unknown", defaultValue: "Not recorded")
        }
    }

    static func icon(_ mode: GatewayInputMode) -> String {
        switch mode {
        case .text: return "keyboard"
        case .voice: return "waveform"
        case .shared: return "square.and.arrow.up"
        case .unknown: return "questionmark.circle"
        }
    }
}
