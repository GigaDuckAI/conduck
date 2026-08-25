// SPDX-License-Identifier: Apache-2.0

// Conduck
// UsageGatewayDetailView.swift
//
// Settings ▸ Usage ▸ one gateway. Everything the overview says about the whole
// range, said again about ONE configured slot — plus the two breakdowns the
// overview deliberately does not carry (the model mix, and what the requests
// were actually carrying).
//
// THE SUMMARY IS THE SAME AGGREGATOR, over a pre-filtered subset. There is no
// per-gateway aggregation path: the model filters the range's records by
// `gatewayRef` and calls the same pure `summarize`, so every denominator rule
// the overview obeys holds here for free and nothing can drift between the two
// screens.
//
// THE RANGE IS NOT RE-PICKABLE HERE. A second picker on a pushed screen invites
// two different windows to be on screen at once; the active one is stated as a
// caption instead, and changing it is a trip back to the overview.
//
// A REPORTED MODEL IS NEVER A MISMATCH. When a gateway names the model it
// actually served, that row is informational and carries its own coverage. A
// requested value that differs from a reported one is the ordinary case — an
// alias resolving, a router choosing — and drawing a warning around it would
// invent a fault the user cannot act on and the ledger cannot substantiate.
//
// CONTENT-FREE, AND THAT IS RELEASE-BLOCKING. Nothing rendered here is prompt
// or reply text, a URL, a host, a token, a provider error string or an HTTP
// status. The screen title is a SLOT's display name resolved from the roster at
// render time, and a failure reason is the app's OWN copy for a stable local
// error code — never a string the gateway sent.
//
// This file also owns the drill-down vocabulary the sibling screens share (the
// chart, the stat/value rows, `UsageDetailRows`, `UsageDetailFormat`). It
// mirrors `UsageDashboardView`'s private helpers rather than importing them —
// TODO: fold the two sets together once those helpers are visible outside that
// file; the shapes are deliberately identical so the fold is mechanical.
//
// MULTI-ROW HELPERS ARE `@ViewBuilder` FUNCTIONS, NOT VIEW STRUCTS. macOS draws
// each section as a hand-drawn card whose rows are resolved from the section's
// declared SHAPE, so a helper that emits three rows has to reach the card as
// three declarations. A custom `View` wrapping them would arrive as one, and the
// separators between them would vanish with nothing to catch it at compile time.
//
// THE RELIABILITY CARD LEADS WITH ONE NUMBER. The success headline is always on
// screen; everything that qualifies it sits behind a disclosure that is closed
// until asked for. A card that opens with nine rows is read as none of them.
// The expanded flag is the SAME `@AppStorage` key the overview's reliability
// card uses, so opening the detail once opens it everywhere — the choice is
// about how much the user wants to read, not about which screen they are on.

import SwiftUI

// MARK: - Gateway drill-down

struct UsageGatewayDetailView: View {
    let model: UsageDashboardModel

    /// A `RemoteAgentRef.rawString`, or nil for the group of attempts that
    /// recorded no slot at all.
    let ref: String?

    /// Display names for gateway slots, read once when the screen opens — the
    /// badge roster, so a slot the user has since removed still reads as itself.
    @State private var gatewayRoster: [CustomGateway] = []

    /// Shared with the overview's reliability card on purpose — see the file
    /// header. Closed by default: the headline is the answer, the rest is the
    /// argument for it.
    @AppStorage("settings.usage.reliability.expanded") private var reliabilityExpanded = false

    /// The Tokens card's own disclosure, shared with the overview's for the
    /// reason the reliability flag is: a user who asked to see token detail once
    /// asked to see it, not to see it on one screen.
    @AppStorage("settings.usage.tokens.expanded") private var tokenDetailExpanded = false

    private var summary: GatewayUsageSummary { model.summary(forGateway: ref) }

    /// The range's raw rows narrowed to this slot. Needed for the reported-model
    /// reading, which the aggregator does not carry: it is a distribution over a
    /// wire string rather than a number, and it exists only on this screen.
    private var scopedRecords: [GatewayAttemptRecord] {
        model.records.filter { $0.gatewayRef == ref }
    }

    private var title: String {
        UsageGatewayLabel.name(for: ref, roster: gatewayRoster)
    }

    var body: some View {
        PlatformSettingsForm {
            if summary.isEmpty {
                emptySection
            } else {
                activitySection
                reliabilitySection
                responseTimeSection
                tokensSection
                if !summary.byRequestedModel.isEmpty {
                    modelsSection
                }
                if !summary.attributedDeviceGroups.isEmpty {
                    deviceSection
                }
                if summary.attachmentContext.measuredAttempts > 0 {
                    attachmentSection
                }
            }
        }
        .scrollContentBackground(.hidden)
        #if os(iOS)
        .navigationTitle(Text(title))
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
                // NO Gateways MEASURE HERE. This screen is already filtered to
                // one slot, so splitting its attempts by gateway would draw one
                // segment restating the title. The scope line says what the
                // split would have: this slot, and how much of the range it is.
                UsageActivityChart(
                    activity: summary.activity,
                    recordedAttempts: summary.recordedAttempts,
                    tokenMeasuredAttempts: summary.tokenMeasuredAttempts,
                    gatewayRoster: gatewayRoster,
                    availableMetrics: UsageChartMetric.allCases.filter { $0 != .gateways },
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

            UsageDetailRows.detailDisclosure(
                expanded: $reliabilityExpanded,
                accessibility: UsageDetailRows.reliabilityDetailsAccessibility
            ) {
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

                // Scoped to THIS slot: a reason row pushed from a gateway
                // drill-down opens the turns that failed on that gateway, not
                // every turn in the range that failed the same way.
                UsageDetailRows.failureReasons(summary.failureReasons, gateway: .slot(ref))
            }
        } header: {
            Text(LocalizedStringResource(
                "settings.usage.reliability.header", defaultValue: "Reliability"))
        } footer: {
            // Same sentence, same key as the overview: the denominator behind
            // the headline is the one thing neither screen's figures reveal.
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
                        value: UsageDetailFormat.durationText(timing.median),
                        label: LocalizedStringResource(
                            "settings.usage.response.median", defaultValue: "Median"),
                        accessibility: LocalizedStringResource(
                            "settings.usage.response.median.a11y",
                            defaultValue: "Median full-response time \(UsageDetailFormat.durationText(timing.median))"),
                        prominent: true
                    )
                    // Withheld below the aggregator's minimum sample count: a
                    // p90 over a handful of attempts interpolates between the
                    // two slowest and would read as precision it lacks.
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

    // MARK: - Tokens + largest turns

    /// Beyond three, the heaviest single turns stop being a shape and start
    /// being a log. The overview's heaviest-THREADS list answers "where did the
    /// range go"; these answer "what did this gateway do the most work on".
    private static let largestTurnRowLimit = 3

    private var largestTurns: [TurnOutlier] {
        Array(summary.largestTurns.prefix(Self.largestTurnRowLimit))
    }

    private var tokensSection: some View {
        let tokens = summary.tokens

        return Section {
            if tokens.isEmpty {
                Text(LocalizedStringResource(
                    "settings.usage.tokens.none",
                    defaultValue: "Not reported by your gateway."))
                    .foregroundStyle(AppColors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .settingsCardPassiveRow()
            } else {
                UsageDetailRows.tokensHeadline(tokens)
                UsageDetailRows.tokenDetail(tokens, expanded: $tokenDetailExpanded)
            }

            // Named, because these rows answer a different question from the
            // token totals above them and sit inside the same card. An
            // unlabelled turn row under a "Reported tokens" header reads as a
            // continuation of the totals.
            if !largestTurns.isEmpty {
                Text(LocalizedStringResource(
                    "settings.usage.detail.largestTurns.header",
                    defaultValue: "Largest turns"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppColors.textTertiary)
                    .settingsCardPassiveRow()
            }

            ForEach(largestTurns, id: \.userMessageID) { turn in
                UsageTurnRow(turn: turn, model: model)
            }
        } header: {
            Text(LocalizedStringResource(
                "settings.usage.tokens.header", defaultValue: "Reported tokens"))
        } footer: {
            // The ranking basis ONLY. It says which number the "Largest turns"
            // rows were sorted on and which turns it silently leaves out —
            // neither is visible in the rows. The gateway-reported caveat that
            // used to sit above it is already carried by the header's own word
            // and by each row's coverage caption.
            if let first = largestTurns.first {
                Text(UsageDetailFormat.turnBasisFooter(first.basis))
            }
        }
    }

    // MARK: - Models

    private var modelsSection: some View {
        // Hoisted: `reportedModelReading` walks the gateway's whole scoped
        // ledger, and the row and the footer gate below would otherwise each
        // run that walk on every body evaluation.
        let reading = reportedModelReading

        return Section {
            ForEach(summary.byRequestedModel) { group in
                UsageValueRow(
                    verbatimLabel: UsageDetailFormat.modelLabel(for: group.key),
                    value: UsageDetailFormat.attemptsText(group.attempts),
                    caption: LocalizedStringResource(
                        "settings.usage.detail.model.caption",
                        defaultValue: "\(UsageDetailFormat.percentText(group.successRate)) succeeded")
                )
            }

            if let reading {
                UsageValueRow(
                    label: LocalizedStringResource(
                        "settings.usage.detail.model.reported",
                        defaultValue: "Reported model"),
                    value: reading.value,
                    caption: LocalizedStringResource(
                        "settings.usage.detail.model.reported.caption",
                        defaultValue: "Named by your gateway on \(UsageDetailFormat.percentText(reading.coverage)) of attempts")
                )
            }
        } header: {
            Text(LocalizedStringResource(
                "settings.usage.detail.models.header", defaultValue: "Models"))
        } footer: {
            // ONLY beside the reported-model row, because that row is the only
            // thing here that can alarm: an alias resolving or a router
            // choosing makes the served name differ from the asked-for one, and
            // two disagreeing model names read as a fault. With no such row the
            // list is just the models this gateway was asked for.
            if reading != nil {
                Text(LocalizedStringResource(
                    "settings.usage.detail.models.footer.reported",
                    defaultValue: """
                        A gateway naming a different model than the one asked for \
                        is ordinary, not a fault.
                        """))
            }
        }
    }

    /// The reported-model reading, present only when it ADDS something: at least
    /// one attempt named a served model, and that set is not simply the set the
    /// requests already asked for. Otherwise the row restates the rows directly
    /// above it.
    private var reportedModelReading: (value: String, coverage: Double?)? {
        let records = scopedRecords
        guard !records.isEmpty else { return nil }

        var counts: [String: Int] = [:]
        for record in records {
            guard let reported = record.reportedModel else { continue }
            counts[reported, default: 0] += 1
        }
        guard !counts.isEmpty else { return nil }
        guard Set(counts.keys) != Set(records.compactMap { $0.requestedModel }) else { return nil }

        let names = counts
            .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .map(\.key)
        let reporting = counts.values.reduce(0, +)
        let value = names.count == 1
            ? names[0]
            : String(localized: "settings.usage.detail.model.reported.many",
                     defaultValue: "\(names.count) models")
        // The same denominator the token-coverage rows on this card use —
        // attempts that reached a stored terminal outcome, so they had their
        // chance to report. A served model is only ever written beside that
        // outcome, so the numerator cannot exceed it. Dividing by every scoped
        // record instead would put two coverage captions on one card that
        // disagree about what "of attempts" counts.
        return (value, GatewayUsageAggregator.ratio(reporting, summary.outcomeMix.resolved))
    }

    // MARK: - By device

    /// ONLY REAL DEVICES GET A ROW, exactly as on the overview —
    /// `attributedDeviceGroups`. The attempts whose device was never recorded
    /// stay inside every figure on this screen and take no row of their own:
    /// there are five devices, and a sixth row reads as one of them.
    private var deviceSection: some View {
        Section {
            ForEach(summary.attributedDeviceGroups) { group in
                UsageGroupCompactRow(
                    label: UsageDeviceBucketDisplay.label(forKey: group.key),
                    icon: UsageDeviceBucketDisplay.icon(forKey: group.key),
                    group: group
                )
            }
        } header: {
            Text(LocalizedStringResource(
                "settings.usage.detail.byDevice.header", defaultValue: "By device"))
        }
        // NO FOOTER. This screen is only ever reached by pushing from the
        // overview, whose own by-device card already says whatever needed
        // saying — repeating it here is the second telling, not the first.
    }

    // MARK: - Attachment context

    /// What the requests were CARRYING — images and extracted text files. Every
    /// figure names its own coverage: the counts are measured per row, and a row
    /// recorded before the app measured them reads as unmeasured rather than as
    /// zero.
    private var attachmentSection: some View {
        let context = summary.attachmentContext
        let coverage = GatewayUsageAggregator.ratio(
            context.measuredAttempts, summary.recordedAttempts)

        return Section {
            UsageValueRow(
                label: LocalizedStringResource(
                    "settings.usage.detail.attachments.images",
                    defaultValue: "Turns with images"),
                value: context.turnsWithImages.formatted(.number),
                caption: UsageDetailFormat.measuredCaption(coverage),
                icon: "photo",
                iconTint: AppColors.usageIconBlue
            )
            UsageValueRow(
                label: LocalizedStringResource(
                    "settings.usage.detail.attachments.files",
                    defaultValue: "Turns with text files"),
                value: context.turnsWithTextFiles.formatted(.number),
                caption: UsageDetailFormat.measuredCaption(coverage),
                icon: "doc.text",
                iconTint: AppColors.usageIconBlue
            )
            UsageValueRow(
                label: LocalizedStringResource(
                    "settings.usage.detail.attachments.replayed",
                    defaultValue: "Images re-sent with later turns"),
                value: context.replayedImageTotal.formatted(.number),
                caption: UsageDetailFormat.measuredCaption(coverage),
                icon: "arrow.triangle.2.circlepath",
                iconTint: AppColors.usageIconBlue
            )
        } header: {
            Text(LocalizedStringResource(
                "settings.usage.detail.attachments.header",
                defaultValue: "What the requests carried"))
        } footer: {
            Text(LocalizedStringResource(
                "settings.usage.detail.attachments.footer",
                defaultValue: """
                    An image already sent goes out again with later turns so the \
                    agent can still see it. That is the single biggest thing you \
                    can change about how much work a long conversation takes.
                    """))
        }
    }
}

// MARK: - Multi-row helpers

/// Row GROUPS shared by the drill-downs. `@ViewBuilder` functions rather than
/// `View` structs on purpose — see the file header: macOS resolves a card's rows
/// from the section's declared shape, and a struct would arrive as one row.
enum UsageDetailRows {

    /// "Details" — the shared expander that hides everything qualifying a
    /// card's headline number until it is asked for.
    ///
    /// TWO IMPLEMENTATIONS, one flag, mirroring `VoiceReliabilityDisclosure`:
    /// iOS keeps `DisclosureGroup`, where the whole row already toggles and
    /// hit-tests. macOS hand-rolls the expander and OWNS the chevron, because a
    /// `DisclosureGroup` renders its chevron in a slot OUTSIDE the label — the
    /// label can then never span the row, and the chevron column takes over the
    /// leading gutter the surrounding card rows set. The macOS branch emits the
    /// revealed rows as SIBLINGS of the button rather than as its children, so
    /// each one still reaches the card as its own declaration and keeps its
    /// separators (see the file header).
    @ViewBuilder
    static func detailDisclosure<Content: View>(
        expanded: Binding<Bool>,
        accessibility: LocalizedStringResource,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        #if os(macOS)
        Button {
            withAnimation { expanded.wrappedValue.toggle() }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppColors.textTertiary)
                    // Driven from inside the action's `withAnimation` so the
                    // turn rides the same transaction as the reveal below.
                    .rotationEffect(.degrees(expanded.wrappedValue ? 90 : 0))
                    // Decoration: the label beside it already names the row.
                    .accessibilityHidden(true)
                detailDisclosureLabel(accessibility: accessibility)
                Spacer()
            }
        }
        .settingsCardRowButton()
        // The hint carries the one thing the label cannot: what activating does.
        .accessibilityHint(Text(expanded.wrappedValue ? "Collapse" : "Expand")) // xcstrings: usage-reliability
        if expanded.wrappedValue {
            content()
        }
        #else
        DisclosureGroup(isExpanded: expanded) {
            content()
        } label: {
            detailDisclosureLabel(accessibility: accessibility)
                .tappableDisclosureLabel(expanded)
        }
        #endif
    }

    /// The one "Details" label in the usage section. Not private, because the
    /// overview's Reliability card hand-rolls its own disclosure around its own
    /// stored flag and renders THIS label inside it — two disclosures sit on
    /// that screen at once, and a second copy of the label is how they would
    /// end up at two different type sizes.
    ///
    /// `accessibility` names WHICH details for VoiceOver — the Reliability and
    /// Tokens cards each put one of these on the same screen, and two rotor
    /// entries both announcing "Details" cannot be told apart. The visible text
    /// stays "Details": the card header above it already says which, sighted.
    static func detailDisclosureLabel(
        accessibility: LocalizedStringResource
    ) -> some View {
        Text(LocalizedStringResource(
            "settings.usage.reliability.details", defaultValue: "Details"))
            .font(.subheadline)
            .foregroundStyle(AppColors.textPrimary)
            .accessibilityLabel(Text(accessibility))
    }

    /// The two VoiceOver names, one per card that owns a disclosure.
    static let reliabilityDetailsAccessibility = LocalizedStringResource(
        "settings.usage.reliability.details.a11y", defaultValue: "Reliability details")
    static let tokenDetailsAccessibility = LocalizedStringResource(
        "settings.usage.tokens.details.a11y", defaultValue: "Token details")

    /// The reliability upgrades, in the order they answer "did it work": how
    /// often the first try landed, how often a retry rescued a turn that did
    /// not, and how many tries a working turn took.
    ///
    /// "Recovered by retry" appears only when something WAS retried — a rate
    /// over zero retries is not a fact about anyone's setup.
    @ViewBuilder
    static func reliability(_ summary: GatewayUsageSummary) -> some View {
        UsageValueRow(
            label: LocalizedStringResource(
                "settings.usage.detail.firstTry", defaultValue: "Delivered first try"),
            value: UsageDetailFormat.percentText(
                GatewayUsageAggregator.ratio(
                    summary.firstAttemptDeliveredTurns, summary.resolvedTurns)),
            caption: LocalizedStringResource(
                "settings.usage.detail.firstTry.caption",
                defaultValue: "\(summary.firstAttemptDeliveredTurns) of \(summary.resolvedTurns) finished turns")
        )
        // RESOLVED retried turns, never the wider `retriedTurns`: a turn still
        // being retried has not failed to recover, and the wider population
        // would report it as one that did.
        if summary.resolvedRetriedTurns > 0 {
            UsageValueRow(
                label: LocalizedStringResource(
                    "settings.usage.detail.recovered", defaultValue: "Recovered by retry"),
                value: UsageDetailFormat.percentText(
                    GatewayUsageAggregator.ratio(
                        summary.retriedTurnsRecovered, summary.resolvedRetriedTurns)),
                caption: LocalizedStringResource(
                    "settings.usage.detail.recovered.caption",
                    defaultValue: "\(summary.retriedTurnsRecovered) of \(summary.resolvedRetriedTurns) retried turns")
            )
        }
        UsageValueRow(
            label: LocalizedStringResource(
                "settings.usage.reliability.attemptsPerTurn",
                defaultValue: "Attempts per completed turn"),
            value: UsageDetailFormat.decimalText(summary.attemptsPerCompletedTurn)
        )
    }

    /// Aggregate failure reasons — the top few by count, the tail folded into
    /// one "Other" row. A COUNT PER REASON, and the row is the way INTO the
    /// turns behind it: passing `gateway:` makes each named reason push
    /// `UsageIncidentListView`, scoped to this screen's slot and filtered to
    /// that one error code.
    ///
    /// THE FOLDED "OTHER" ROW NEVER NAVIGATES. It stands for several distinct
    /// codes, so there is no single filter a push could carry, and a row that
    /// opened onto some unnamed subset would be worse than one that opens onto
    /// nothing.
    @ViewBuilder
    static func failureReasons(
        _ reasons: [FailureReasonCount],
        gateway: UsageIncidentFilter.GatewayScope? = nil
    ) -> some View {
        ForEach(reasons.prefix(failureReasonRowLimit), id: \.appErrorCode) { reason in
            UsageValueRow(
                verbatimLabel: UsageFailureReasonCopy.label(forAppErrorCode: reason.appErrorCode),
                value: reason.count.formatted(.number),
                icon: "exclamationmark.triangle",
                route: gateway.map {
                    .incidents(UsageIncidentFilter(
                        gateway: $0, appErrorCode: reason.appErrorCode))
                }
            )
        }
        if otherFailureCount(reasons) > 0 {
            UsageValueRow(
                label: LocalizedStringResource(
                    "settings.usage.detail.failureReason.other", defaultValue: "Other"),
                value: otherFailureCount(reasons).formatted(.number),
                icon: "exclamationmark.triangle"
            )
        }
    }

    /// Beyond this many rows the tail stops being a shape and starts being a
    /// log, so it folds into one honest total.
    static let failureReasonRowLimit = 5

    static func otherFailureCount(_ reasons: [FailureReasonCount]) -> Int {
        reasons.dropFirst(failureReasonRowLimit).reduce(0) { $0 + $1.count }
    }

    /// THE HEADLINE IS THE ANSWER, exactly as the Reliability card's: one
    /// total up top, everything it is made of behind Details. The
    /// gateway-reported total wears the row when it exists; otherwise input
    /// plus output as reported stands in, and its label says so in words —
    /// that sum is NOT a total, because whatever the gateway counted in its
    /// own total and reported in neither component is silently missing from
    /// it, which is exactly why it does not get to wear the word.
    @ViewBuilder
    static func tokensHeadline(_ tokens: GatewayUsageTokens) -> some View {
        if let total = tokens.reportedTotal.sum {
            UsageHeadlineRow(
                value: total.formatted(.number),
                label: LocalizedStringResource(
                    "settings.usage.tokens.coverage",
                    defaultValue: "Reported on \(UsageDetailFormat.percentText(tokens.reportedTotal.coverage)) of attempts"),
                accessibility: LocalizedStringResource(
                    "settings.usage.tokens.headline.total.a11y",
                    defaultValue: """
                        \(total.formatted(.number)) tokens, reported on \
                        \(UsageDetailFormat.percentText(tokens.reportedTotal.coverage)) of attempts
                        """)
            )
        } else if let components = tokens.calculatedKnownComponents {
            UsageHeadlineRow(
                value: components.formatted(.number),
                label: LocalizedStringResource(
                    "settings.usage.tokens.headline.components",
                    defaultValue: "Input + output added up — your gateway reported no total"),
                accessibility: LocalizedStringResource(
                    "settings.usage.tokens.headline.components.a11y",
                    defaultValue: """
                        \(components.formatted(.number)) tokens, input and output \
                        added up — your gateway reported no total
                        """)
            )
        }
    }

    /// The token-DETAIL disclosure — ONE implementation, rendered identically by
    /// the overview's Tokens card and by every drill-down's. It reuses
    /// `detailDisclosure` above rather than restating it, so the control, the
    /// chrome, the macOS pointer conventions and the accessibility behaviour are
    /// the Reliability card's by construction and cannot drift from it.
    ///
    /// INPUT AND OUTPUT LIVE IN HERE, not on the card face — the headline above
    /// answers the question most users came with, and the components are the
    /// follow-up, exactly the Reliability card's split. Each keeps its OWN
    /// coverage caption: a gateway that reports input but not output is common,
    /// and one figure for the pair would claim a completeness neither has.
    ///
    /// THE THREE ROWS BELOW THEM ARE SUBSETS, NOT SIBLINGS — cached and
    /// cache-write of the input, reasoning of the output — which is why the
    /// footer says so in words and why nothing here adds them into anything.
    /// NEVER a savings or a money framing: cached input is an efficiency fact,
    /// and a cache WRITE is billed at a premium by several providers.
    @ViewBuilder
    static func tokenDetail(
        _ tokens: GatewayUsageTokens,
        expanded: Binding<Bool>
    ) -> some View {
        if !tokens.isEmpty {
            detailDisclosure(expanded: expanded, accessibility: tokenDetailsAccessibility) {
                tokenRow(
                    label: LocalizedStringResource(
                        "settings.usage.tokens.input", defaultValue: "Input"),
                    field: tokens.input)
                tokenRow(
                    label: LocalizedStringResource(
                        "settings.usage.tokens.output", defaultValue: "Output"),
                    field: tokens.output)
                // Per field, exactly as the rows above: a field this range
                // never saw takes no row rather than standing an em dash where
                // a number belongs.
                if tokens.cachedInput.isReported {
                    tokenRow(
                        label: LocalizedStringResource(
                            "settings.usage.tokens.cachedInput", defaultValue: "Cached input"),
                        field: tokens.cachedInput)
                }
                if tokens.cacheWriteInput.isReported {
                    tokenRow(
                        label: LocalizedStringResource(
                            "settings.usage.tokens.cacheWrites", defaultValue: "Cache writes"),
                        field: tokens.cacheWriteInput)
                }
                if tokens.reasoningOutput.isReported {
                    tokenRow(
                        label: LocalizedStringResource(
                            "settings.usage.tokens.reasoningOutput",
                            defaultValue: "Reasoning output"),
                        field: tokens.reasoningOutput)
                }
                // Only where a subset row is actually on screen to be misread
                // as a sibling of the input and output rows above it.
                if tokens.hasReportedDetail {
                    Text(LocalizedStringResource(
                        "settings.usage.tokens.detail.footer",
                        defaultValue: """
                            These are parts of the input and output figures above, counted \
                            only where your gateway reported them.
                            """))
                        .font(.caption)
                        .foregroundStyle(AppColors.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .settingsCardPassiveRow()
                }
            }
        }
    }

    private static func tokenRow(
        label: LocalizedStringResource,
        field: GatewayUsageTokenField
    ) -> some View {
        UsageValueRow(
            label: label,
            value: field.sum.map { $0.formatted(.number) }
                ?? String(localized: "settings.usage.tokens.absent",
                          defaultValue: "Not reported"),
            caption: field.isReported && field.coverage != nil
                ? LocalizedStringResource(
                    "settings.usage.tokens.coverage",
                    defaultValue: "Reported on \(UsageDetailFormat.percentText(field.coverage)) of attempts")
                : nil
        )
    }
}

// MARK: - Single-row vocabulary

/// Side by side at normal text sizes, stacked at accessibility sizes. An
/// `AnyLayout` rather than two branches so the tiles keep their identity across
/// the switch and the values do not animate in from nothing.
struct UsageStatLayout<Content: View>: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
            : AnyLayout(HStackLayout(alignment: .top, spacing: 16))
        return layout { content }
    }
}

struct UsageStatTile: View {
    let value: String
    let label: LocalizedStringResource
    let accessibility: LocalizedStringResource
    var prominent: Bool = false

    var body: some View {
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
}

struct UsageHeadlineRow: View {
    let value: String
    let label: LocalizedStringResource
    let accessibility: LocalizedStringResource

    var body: some View {
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
}

/// Label · value, with an optional caption beneath and an optional leading
/// glyph. The `verbatimLabel:` init exists for the two labels that are DATA — a
/// requested model string, an error taxonomy's own copy — which must not be run
/// through the string catalog: a key whose whole value is a substitution is
/// rejected by the catalog tooling, and there is nothing to translate anyway.
///
/// `iconTint` is the row's ONE colour decision, and it is the call site's:
/// a DECORATIVE glyph naming a thing (an input mode, an attachment kind) takes
/// `AppColors.usageIconBlue`, while a glyph carrying a verdict — the scissors on
/// a cut-short reply, the triangle on a failure reason — keeps the recessive
/// default. Tinting the whole row type either way would make the two say the
/// same thing.
///
/// `route:` turns the SAME row into a push without a second row type. The
/// affordance follows the platform exactly as `UsageDashboardView`'s own
/// navigation rows do: the iOS grouped `Form` IS a `List` and supplies the
/// system disclosure accessory for free, while the hand-drawn macOS card is not
/// and gets a trailing-inset chevron drawn here, over a gutter the label keeps
/// clear for it.
struct UsageValueRow: View {
    private let labelText: Text
    private let value: String
    private let caption: LocalizedStringResource?
    private let icon: String?
    private let iconTint: Color
    private let route: UsageRoute?

    init(
        label: LocalizedStringResource,
        value: String,
        caption: LocalizedStringResource? = nil,
        icon: String? = nil,
        iconTint: Color = AppColors.textTertiary,
        route: UsageRoute? = nil
    ) {
        self.labelText = Text(label)
        self.value = value
        self.caption = caption
        self.icon = icon
        self.iconTint = iconTint
        self.route = route
    }

    init(
        verbatimLabel: String,
        value: String,
        caption: LocalizedStringResource? = nil,
        icon: String? = nil,
        iconTint: Color = AppColors.textTertiary,
        route: UsageRoute? = nil
    ) {
        self.labelText = Text(verbatim: verbatimLabel)
        self.value = value
        self.caption = caption
        self.icon = icon
        self.iconTint = iconTint
        self.route = route
    }

    @ViewBuilder
    var body: some View {
        if let route {
            NavigationLink(value: route) {
                content
                    .frame(maxWidth: .infinity, alignment: .leading)
                    #if os(macOS)
                    .padding(.trailing, Self.chevronGutter)
                    #endif
            }
            // `.settingsCardRowButton()` IS `.buttonStyle(.plain)` off macOS, so
            // this one modifier gives the card row its full-bleed live frame and
            // leaves the `Form` row untinted on iOS.
            .settingsCardRowButton()
            #if os(macOS)
            .overlay(alignment: .trailing) { Self.rowChevron }
            #endif
        } else {
            content
                .settingsCardPassiveRow()
                .accessibilityElement(children: .combine)
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 10) {
                if let icon {
                    Image(systemName: icon)
                        .foregroundStyle(iconTint)
                        .accessibilityHidden(true)
                }
                labelText
                    .foregroundStyle(AppColors.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
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
    }

    /// Space a navigating row keeps clear so a long value never runs under the
    /// chevron drawn on top of it.
    static let chevronGutter: CGFloat = 16

    /// Decoration, never an element: an overlay is a SIBLING of the link it sits
    /// on, so without `accessibilityHidden` it lands in the rotor as a stray
    /// item the row's own label already covers.
    static var rowChevron: some View {
        Image(systemName: "chevron.forward")
            .font(.caption)
            .foregroundStyle(AppColors.textTertiary)
            #if os(macOS)
            .padding(.trailing, SettingsCardMetrics.rowInset)
            #endif
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// One slice of a range — a gateway inside a device, or a device inside a
/// gateway. No chevron: a drill-down inside a drill-down would be the same
/// numbers a third time, reached two different ways.
///
/// NAME ON THE TOP LINE, RATES UNDERNEATH, and no count at the trailing edge:
/// the slice is read against its siblings on how well and how fast it went, and
/// the caption already states the sample those rates come from. The screen's own
/// Activity card holds the attempt total for the whole scope.
struct UsageGroupCompactRow: View {
    let label: String
    var icon: String? = nil
    let group: GatewayUsageGroup

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                if let icon {
                    // Decorative and never a verdict — the only glyph this row
                    // ever carries is the device it names.
                    Image(systemName: icon)
                        .foregroundStyle(AppColors.usageIconBlue)
                        .accessibilityHidden(true)
                }
                Text(verbatim: label)
                    .foregroundStyle(AppColors.textPrimary)
                Spacer(minLength: 12)
            }
            Text(UsageDetailFormat.groupDetailText(group))
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(AppColors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .settingsCardPassiveRow()
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Shared labels

/// Slot display names, resolved at RENDER time from the badge roster. A stored
/// name would be a stale copy of a setting the user can edit; the raw token is
/// the fallback only when the string is not a ref this build understands.
enum UsageGatewayLabel {
    static func name(for key: String?, roster: [CustomGateway]) -> String {
        guard let key else {
            return String(localized: "settings.usage.gateway.unattributed",
                          defaultValue: "Not recorded")
        }
        guard let ref = RemoteAgentRef(rawString: key) else { return key }
        return RemoteAgentRefMetadata.displayName(for: ref, customs: roster)
    }
}

/// The device buckets as a person reads them. `unknown` is "Not recorded" and
/// never "Other": it is an absence of measurement, not a device — which is why
/// it can title a drill-down reached by route but never takes a row in a
/// by-device list.
enum UsageDeviceBucketDisplay {
    static func label(_ bucket: UsageDeviceBucket) -> String {
        switch bucket {
        case .iphone:
            return String(localized: "settings.usage.device.iphone", defaultValue: "iPhone")
        case .ipad:
            return String(localized: "settings.usage.device.ipad", defaultValue: "iPad")
        case .mac:
            return String(localized: "settings.usage.device.mac", defaultValue: "Mac")
        case .watch:
            return String(localized: "settings.usage.device.watch", defaultValue: "Apple Watch")
        case .carPlay:
            return String(localized: "settings.usage.device.carPlay", defaultValue: "CarPlay")
        case .unknown:
            return String(localized: "settings.usage.device.unknown", defaultValue: "Not recorded")
        }
    }

    static func icon(_ bucket: UsageDeviceBucket) -> String {
        switch bucket {
        case .iphone: return "iphone"
        case .ipad: return "ipad"
        case .mac: return "laptopcomputer"
        case .watch: return "applewatch"
        case .carPlay: return "car"
        case .unknown: return "questionmark.circle"
        }
    }

    /// For a `GatewayUsageGroup` whose key is a bucket's raw value. A key that
    /// parses to nothing reads as unrecorded rather than as a device.
    static func bucket(forKey key: String?) -> UsageDeviceBucket {
        guard let key, let bucket = UsageDeviceBucket(rawValue: key) else { return .unknown }
        return bucket
    }

    static func label(forKey key: String?) -> String { label(bucket(forKey: key)) }

    static func icon(forKey key: String?) -> String { icon(bucket(forKey: key)) }
}

/// The app's OWN copy for a stable local error code. Never a provider string:
/// the ledger stores a code precisely so no text from someone else's server can
/// reach a screen.
enum UsageFailureReasonCopy {
    /// Delegates to `DiagnosticsExplainer`, the app's SINGLE map from a stored
    /// `AppError` code to the sentence a user reads. A second map written here
    /// would drift from it silently: the same failure would read one way on this
    /// screen, another on the overview, and another on Diagnostics, with nothing
    /// failing. The explainer also owns the opaque-code substitution, so a row
    /// can never render an empty or provider-shaped line.
    ///
    /// Cause only, matching the overview row it mirrors. The explainer's `fix`
    /// half belongs to Diagnostics, where a row is about one failure and the
    /// remedy has something to act on; here the rows are counts.
    static func label(forAppErrorCode code: Int) -> String {
        DiagnosticsExplainer.explain(code: code).cause
    }
}

// MARK: - Formatting

/// Formatting shared by the drill-downs, mirroring the overview's private
/// helpers so two screens cannot state the same number two different ways.
enum UsageDetailFormat {
    /// Nil is UNAVAILABLE, never zero. An em dash says "we cannot tell you",
    /// which is a different claim from "none succeeded".
    static func percentText(_ value: Double?) -> String {
        guard let value else { return unavailable }
        return value.formatted(.percent.precision(.fractionLength(0)))
    }

    static func decimalText(_ value: Double?) -> String {
        guard let value else { return unavailable }
        return value.formatted(.number.precision(.fractionLength(1)))
    }

    static func durationText(_ seconds: TimeInterval?) -> String {
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

    static var unavailable: String {
        String(localized: "settings.usage.unavailable", defaultValue: "—")
    }

    /// Two keys rather than one plural rule: the headless build path that
    /// synthesizes the catalog does not run Xcode's extraction phase, so a
    /// count-driven variation would have to be hand-written into it.
    static func attemptsText(_ count: Int) -> String {
        count == 1
            ? String(localized: "settings.usage.attempts.one", defaultValue: "1 attempt")
            : String(localized: "settings.usage.attempts.other",
                     defaultValue: "\(count) attempts")
    }

    /// How many replies are behind the figures, and the window they fall in —
    /// always together and always visible: a median over three replies is not a
    /// claim, and the window is what makes it one.
    ///
    /// SAID IN WORDS, never as `(n 12)`. The sample size is the single most
    /// load-bearing caveat on this card, and a statistician's shorthand for it
    /// is read by most people as a typo rather than as a caveat.
    static func sampleCaption(count: Int, range: UsageDashboardModel.Range) -> String {
        String(localized: "settings.usage.detail.sampleCaption",
               defaultValue: "\(repliesMeasuredText(count)) · \(rangeWindowText(range))")
    }

    /// Two keys rather than one plural rule, for the reason `attemptsText`
    /// gives: the headless catalog synthesis does not run Xcode's extraction
    /// phase, so a count-driven variation would have to be hand-written into it.
    static func repliesMeasuredText(_ count: Int) -> String {
        count == 1
            ? String(localized: "settings.usage.detail.repliesMeasured.one",
                     defaultValue: "1 reply measured")
            : String(localized: "settings.usage.detail.repliesMeasured.other",
                     defaultValue: "\(count) replies measured")
    }

    /// The same sample size as a TRAILING fragment, for a figure that has just
    /// been stated — "median 4.2s over 12 replies".
    static func overRepliesText(_ count: Int) -> String {
        count == 1
            ? String(localized: "settings.usage.detail.overReplies.one",
                     defaultValue: "over 1 reply")
            : String(localized: "settings.usage.detail.overReplies.other",
                     defaultValue: "over \(count) replies")
    }

    /// The window a drill-down describes, STATED rather than re-pickable.
    static func rangeCaption(for range: UsageDashboardModel.Range) -> String {
        String(localized: "settings.usage.detail.rangeCaption",
               defaultValue: "Showing \(rangeWindowText(range))")
    }

    static func rangeWindowText(_ range: UsageDashboardModel.Range) -> String {
        switch range {
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

    /// A requested model is DATA, not copy — it renders verbatim. Only its
    /// absence has a translation, and that absence means the request carried no
    /// model and the gateway's own default answered.
    static func modelLabel(for key: String?) -> String {
        key ?? String(localized: "settings.usage.model.default",
                      defaultValue: "Gateway default")
    }

    /// SAME RULE AS THE TOKENS CARD: a gateway-reported total renders bare, a
    /// client sum of the components never does — so a compact row never presents
    /// a Conduck-computed figure as the gateway's own number.
    static func groupDetailText(_ group: GatewayUsageGroup) -> String {
        var parts: [String] = [
            String(localized: "settings.usage.byGateway.successRate",
                   defaultValue: "\(percentText(group.successRate)) succeeded")
        ]
        if let median = group.medianResponseTime {
            parts.append(String(
                localized: "settings.usage.detail.groupMedian",
                defaultValue: "median \(durationText(median)) \(overRepliesText(group.responseSampleCount))"))
        }
        return parts.joined(separator: " · ")
    }

    /// Coverage for a figure derived from rows that carry a measurement. Absent
    /// when everything in range was measured — a caption saying "100%" adds
    /// nothing but doubt.
    static func measuredCaption(_ coverage: Double?) -> LocalizedStringResource? {
        guard let coverage, coverage < 1 else { return nil }
        return LocalizedStringResource(
            "settings.usage.detail.measuredCoverage",
            defaultValue: "Measured on \(percentText(coverage)) of attempts")
    }

    /// The ranking basis, named honestly. ONE basis per list: a list mixing
    /// gateway-reported totals with client-summed components would rank things
    /// against numbers that do not mean the same thing.
    static func turnBasisFooter(_ basis: ThreadRanking.Basis) -> LocalizedStringResource {
        switch basis {
        case .reportedTotals:
            return LocalizedStringResource(
                "settings.usage.detail.turnBasis.reported",
                defaultValue: """
                    Largest turns are ranked by the total your gateway reported. \
                    Turns it reported no total for aren't ranked.
                    """)
        case .calculatedComponents:
            return LocalizedStringResource(
                "settings.usage.detail.turnBasis.components",
                defaultValue: """
                    Largest turns are ranked by input plus output, added up from \
                    what your gateway reported — it reported no totals of its own.
                    """)
        }
    }

    /// The same rule for the thread lists, which rank whole conversations.
    static func threadBasisFooter(_ basis: ThreadRanking.Basis) -> LocalizedStringResource {
        switch basis {
        case .reportedTotals:
            return LocalizedStringResource(
                "settings.usage.detail.threadBasis.reported",
                defaultValue: """
                    Ranked by gateway-reported total tokens. Conversations without \
                    reported totals aren't ranked.
                    """)
        case .calculatedComponents:
            return LocalizedStringResource(
                "settings.usage.detail.threadBasis.components",
                defaultValue: """
                    Ranked by input plus output, added up from what your gateway \
                    reported — it reported no totals of its own.
                    """)
        }
    }
}
