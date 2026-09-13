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
// The shared chart can show recorded tokens for this device's attempts; there
// is no separate token-detail card. Neither that volume nor the device split
// claims a monetary cost or a property of the hardware itself.
//
// CONTENT-FREE, AND THAT IS RELEASE-BLOCKING. The device names on this screen
// are the app's own words for a hardware CLASS — never the name the user gave a
// device, which the ledger does not hold and this screen could not read.

import SwiftUI

struct UsageDeviceDetailView: View {
    let model: UsageDashboardModel
    let bucket: UsageDeviceBucket

    /// Usage identities follow the model’s refreshed settings snapshot.
    private var gatewayRoster: [CustomGateway] { model.gatewayIdentity.roster }

    private var summary: GatewayUsageSummary { model.summary(forDevice: bucket) }

    private var title: String { UsageDeviceBucketDisplay.label(bucket) }

    /// The input split is worth a card only when there is a split to show. One
    /// mode at 100% restates the attempt count above it.
    private var inputModes: [InputModeSlice] {
        summary.attributedInputModes.filter { $0.attempts > 0 }
    }

    var body: some View {
        PlatformSettingsForm {
            // The SAME range control as the overview, bound to the SAME model —
            // one range for the whole Usage area, so changing it here changes
            // the screen behind this one too. Above the empty state on purpose:
            // an empty range is escaped in place, not by walking back.
            UsageRangeSection(model: model)

            if let loadError = model.loadError {
                UsageLoadSections.error(loadError, retry: model.refresh)
            }
            if !model.hasVisibleSummary {
                if model.loadError == nil { UsageLoadSections.loading }
            } else if summary.isEmpty {
                emptySection
            } else {
                activitySection
                reliabilitySection
                responseTimeSection
                if inputModes.count > 1 {
                    inputSection
                }
                if !summary.attributedGatewayGroups.isEmpty || summary.unattributedGatewayAttempts > 0 {
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
            Text(UsageDetailFormat.rangeCaption(for: model.displayedRange))
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
                    tokenCoverageDenominator: summary.outcomeMix.resolved,
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
        }
        // NO RANGE FOOTER: the picker at the top of this screen already names
        // the window, one card above.
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

                Text(UsageDetailFormat.sampleCaption(count: timing.sampleCount, range: model.displayedRange))
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
            if summary.attributedGatewayGroups.isEmpty {
                Text(UsageDetailFormat.unattributedGatewayFooter(
                    summary.unattributedGatewayAttempts, of: summary.recordedAttempts))
                    .foregroundStyle(AppColors.textSecondary)
                    .settingsCardPassiveRow()
            }
            ForEach(summary.attributedGatewayGroups) { group in
                UsageGroupCompactRow(
                    label: UsageGatewayLabel.name(for: group.key, roster: gatewayRoster),
                    gatewayIdentity: model.gatewayIdentity.display(for: group.key),
                    group: group,
                    share: UsageDetailFormat.shareText(
                        group.attempts, of: summary.recordedAttempts)
                )
            }
        } header: {
            Text(LocalizedStringResource(
                "settings.usage.byGateway.header", defaultValue: "By gateway"))
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Text(UsageDetailFormat.shareCaption)
                if summary.unattributedGatewayAttempts > 0 && !summary.attributedGatewayGroups.isEmpty {
                    Text(UsageDetailFormat.unattributedGatewayFooter(
                        summary.unattributedGatewayAttempts, of: summary.recordedAttempts))
                }
            }
        }
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
