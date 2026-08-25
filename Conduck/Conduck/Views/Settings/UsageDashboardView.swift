// SPDX-License-Identifier: Apache-2.0

// Conduck
// UsageDashboardView.swift
//
// Settings ▸ Usage — the read surface over the gateway-attempt ledger. The
// overview: how much you used your gateway, how you gave it input, how often it
// answered, how long it took, what it reported about tokens, and which devices
// and threads the load came from. Nothing here is a score, a streak or a goal;
// the product intent is measurement, and a number that would push someone to
// use Conduck more does not belong on it.
//
// THE OVERVIEW ANSWERS "WHAT", THE DRILL-DOWNS ANSWER "WHICH". A gateway row, a
// device row and the thread list each push a detail screen through `UsageRoute`,
// and the overview deliberately keeps no nested breakdown of its own — a card
// that expands in place turns the one screen a user scans into a tree they have
// to navigate. The destinations are registered HERE, on the shared content root,
// so all three hosts inherit one registration rather than three copies.
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
// THE CHART IS `UsageActivityChart`, shared with both drill-downs — its own
// file owns the chart discipline and the metric picker. Status colour on THIS
// screen is reserved for the outcome rows, where it always travels with an icon
// AND a label so colour is never the only carrier of meaning.
//
// CONTENT-FREE, AND THAT IS RELEASE-BLOCKING. Nothing rendered here is prompt or
// reply text, a URL, a host, a token, a provider error string or an HTTP status.
// The gateway rows show a SLOT's display name resolved from the roster at render
// time — never a stored name, which would be a stale copy of a setting the user
// can edit, and never the endpoint behind it. The thread rows carry no title and
// no snippet: a date span, a gateway name and counts. A title is content, and the
// only place one may appear is the conversation itself, which the row navigates
// to rather than quoting.
//
// FAILURE REASONS REUSE THE APP'S OWN ERROR COPY. `DiagnosticsExplainer` is the
// single map from a stored `AppError` code to the sentence a user reads, and it
// is the map Diagnostics already renders. A second map written here would drift
// from it silently — the two would disagree about the same failure on two screens
// of the same app, and nothing would fail.

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

// MARK: - Navigation

/// The pushes the overview offers. A value route rather than a destination
/// closure per row: every host renders the SAME content view, so one
/// `navigationDestination(for:)` on that content covers the iPhone push, the
/// iPad detail stack and the macOS category alike.
///
/// `gateway` carries a `RemoteAgentRef.rawString` — the configured SLOT, resolved
/// to a display name at render time. Its nil arm names the attempts that
/// recorded no gateway at all — a FLOOR, not a push any list offers: those
/// attempts take no row in any by-gateway list, so nothing constructs the nil
/// route any more, and the destination merely remains able to render it.
enum UsageRoute: Hashable {
    case gateway(String?)
    case device(UsageDeviceBucket)
    case allThreads
    /// The turns behind a reliability figure, always range-scoped and carrying
    /// whatever narrowing the row that opened it already had. Reached from the
    /// failure-reason rows on the overview and on the gateway drill-down; it is
    /// never a top-level destination of its own.
    case incidents(UsageIncidentFilter)
}

// MARK: - Stat tiles

/// One figure in the Activity row, described rather than drawn so the row can
/// be laid out three different ways without the tiles being written three
/// times. `id` is a stable slug rather than the position: a conditional tile
/// changes the count, and index identity would then re-key every tile after it.
private struct UsageActivityStat: Identifiable {
    let id: String
    let value: String
    let label: LocalizedStringResource
    let accessibility: LocalizedStringResource
}

// MARK: - Shared content

struct UsageDashboardContent: View {
    @State private var model: UsageDashboardModel

    /// The display roster for gateway slots, read once when the screen opens.
    /// `gatewayBadgeRoster()` rather than the live roster on purpose: usage
    /// history outlives a gateway the user has since forgotten, and a retired
    /// slot still deserves its name rather than its raw token.
    @State private var gatewayRoster: [CustomGateway] = []

    /// Whether the Reliability card's detail is open. Collapsed by default and
    /// remembered per device: the headline answers the question most users
    /// came with, and the rows underneath are the follow-up only some of them
    /// have. Shared with the gateway drill-down's reliability block on purpose
    /// — a user who opened the detail once asked to see detail.
    @AppStorage("settings.usage.reliability.expanded")
    private var reliabilityDetailExpanded: Bool = false

    /// Whether the Tokens card's detail is open. Same rule and same posture as
    /// the reliability flag above, and shared with the gateway drill-down's
    /// Tokens card for the same reason — the choice is about how much the user
    /// wants to read, not about which screen they are on.
    @AppStorage("settings.usage.tokens.expanded")
    private var tokenDetailExpanded: Bool = false

    /// Gate for the destructive clear. Held here rather than in the model: it is
    /// presentation state, and a model that owned it would have to be reset by
    /// whichever host dismissed the dialog.
    @State private var showingClearConfirmation = false

    /// Drives the stat-row layout: side by side at normal text sizes, stacked at
    /// accessibility sizes where three columns would crush every value.
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    #if os(iOS)
    /// The fourth stat tile is what makes this matter: four columns fit an iPad
    /// or a Mac card and crush an iPhone, where "Conversations" alone is wider
    /// than the column it would get.
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

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
                // Only worth a card when there is a MIX to describe: one mode
                // holding every turn is a row saying 100%, which tells the user
                // what they already knew from having used the app.
                if visibleInputModes.count > 1 {
                    inputSection
                }
                reliabilitySection
                responseTimeSection
                tokensSection
                if !model.summary.attributedDeviceGroups.isEmpty {
                    deviceSection
                }
                if !model.summary.attributedGatewayGroups.isEmpty {
                    gatewaySection
                }
                if !model.summary.threadRanking.threads.isEmpty {
                    threadsSection
                }
            }

            if model.hasLoaded {
                coverageSection
            }
        }
        .scrollContentBackground(.hidden)
        // ONE registration for three hosts. The iPhone push and the iPad detail
        // already sit inside a `NavigationStack`; the macOS category supplies its
        // own around this content.
        .navigationDestination(for: UsageRoute.self) { route in
            switch route {
            case .gateway(let ref):
                UsageGatewayDetailView(model: model, ref: ref)
            case .device(let bucket):
                UsageDeviceDetailView(model: model, bucket: bucket)
            case .allThreads:
                UsageAllThreadsView(model: model)
            case .incidents(let filter):
                UsageIncidentListView(model: model, filter: filter)
            }
        }
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
            SettingsSegmentedPicker(
                selection: selection,
                options: UsageDashboardModel.Range.allCases,
                label: Text(LocalizedStringResource(
                    "settings.usage.range.label", defaultValue: "Range")),
                title: { Text($0.title) }
            )
            .settingsCardPassiveRow()
            // THE CONTROL IS THE ROW. A grouped `Form` insets its row content
            // and paints a card behind it, so a segmented control left at the
            // defaults draws a pill inside a pill — two rounded rectangles of
            // almost the same size, with a band of section fill trapped between
            // them. Zeroing the insets lets the control span the section, and
            // clearing the row background leaves exactly one pill on screen.
            // Both are `List` traits: they reach nothing on macOS, where the
            // hand-drawn card gives this row its inset through
            // `.settingsCardPassiveRow()` above, the same as every other row in
            // the stack.
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
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
            if !model.summary.activity.isEmpty {
                // The chart is a SHARED component, identical here and on both
                // drill-downs — including which measure it is showing, which
                // follows the user across the push rather than resetting. The
                // overview withholds no measure and scopes nothing: it IS the
                // range.
                UsageActivityChart(
                    activity: model.summary.activity,
                    recordedAttempts: model.summary.recordedAttempts,
                    tokenMeasuredAttempts: model.summary.tokenMeasuredAttempts,
                    gatewayRoster: gatewayRoster
                )
                .settingsCardPassiveRow()
            }
        } header: {
            Text(LocalizedStringResource(
                "settings.usage.activity.header", defaultValue: "Activity"))
        } footer: {
            // The ONE word on this card a person cannot infer from the tiles.
            // Everything else the old footer carried — where retries are
            // counted, that they do not inflate this — answered a question
            // nobody asks until they already distrust the number.
            Text(LocalizedStringResource(
                "settings.usage.activity.footer.turn",
                defaultValue: "A turn is one thing you sent."))
        }
    }

    private var statRow: some View {
        statTileLayout(activityStats)
            .settingsCardPassiveRow()
    }

    /// Turns · Completed · Conversations · Tokens. The fourth tile is
    /// CONDITIONAL, matching how every other absent figure on this screen is
    /// handled: a gateway that reports no usage leaves the tile out rather than
    /// standing an em dash where a number belongs, which would read as a broken
    /// measurement rather than a gateway that never promised one.
    private var activityStats: [UsageActivityStat] {
        let summary = model.summary
        var tiles: [UsageActivityStat] = [
            UsageActivityStat(
                id: "turns",
                value: summary.attemptedTurns.formatted(.number),
                label: LocalizedStringResource(
                    "settings.usage.stat.turns", defaultValue: "Turns"),
                accessibility: LocalizedStringResource(
                    "settings.usage.stat.turns.a11y",
                    defaultValue: "\(summary.attemptedTurns) turns sent")
            ),
            UsageActivityStat(
                id: "completed",
                value: summary.completedTurns.formatted(.number),
                label: LocalizedStringResource(
                    "settings.usage.stat.completed", defaultValue: "Completed"),
                accessibility: LocalizedStringResource(
                    "settings.usage.stat.completed.a11y",
                    defaultValue: "\(summary.completedTurns) turns completed")
            ),
            // Threads WITH USAGE, which is not the same as threads the user
            // still has: the ledger outlives a deleted conversation, so this
            // counts history rather than what the list would show. The coverage
            // footer is where that is said in words.
            UsageActivityStat(
                id: "conversations",
                value: summary.threadsWithUsage.formatted(.number),
                label: LocalizedStringResource(
                    "settings.usage.stat.conversations", defaultValue: "Conversations"),
                accessibility: LocalizedStringResource(
                    "settings.usage.stat.conversations.a11y.withUsage",
                    defaultValue: "\(summary.threadsWithUsage) conversations with recorded usage")
            )
        ]
        if let tokens = activityTokenTotal {
            tiles.append(UsageActivityStat(
                id: "tokens",
                // COMPACT on the face, exact in the label a screen reader
                // speaks: four columns cannot hold "1,284,930", and a tile is
                // an at-a-glance figure — the Tokens card below carries the
                // full number and its coverage.
                value: tokens.value.formatted(.number.notation(.compactName)),
                label: LocalizedStringResource(
                    "settings.usage.stat.tokens", defaultValue: "Tokens"),
                accessibility: tokens.isReported
                    ? LocalizedStringResource(
                        "settings.usage.stat.tokens.a11y.reported",
                        defaultValue: "\(tokens.value.formatted(.number)) tokens, reported by your gateway")
                    : LocalizedStringResource(
                        "settings.usage.stat.tokens.a11y.components",
                        defaultValue: "\(tokens.value.formatted(.number)) tokens, input plus output added up")
            ))
        }
        return tiles
    }

    /// THE SAME RULE THE TOKENS CARD USES, because the tile and the card sit on
    /// one screen showing one range: a gateway-reported total wins, and only
    /// where there is none does the client's own sum of the components stand in
    /// — flagged as such in the accessibility label, never presented as the
    /// gateway's own number.
    private var activityTokenTotal: (value: Int64, isReported: Bool)? {
        let tokens = model.summary.tokens
        if let total = tokens.reportedTotal.sum { return (total, true) }
        if let components = tokens.calculatedKnownComponents { return (components, false) }
        return nil
    }

    /// Three layouts for one row of tiles: stacked at accessibility sizes, two
    /// by two where four columns would crush an iPhone, side by side otherwise.
    ///
    /// Explicit branches rather than the `AnyLayout` the two- and three-tile
    /// rows use: a 2×2 arrangement is a different container, not a different
    /// layout of the same children, so there is no single layout to swap.
    @ViewBuilder
    private func statTileLayout(_ stats: [UsageActivityStat]) -> some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(stats) { statTile($0) }
            }
        } else if wrapsStatTiles, stats.count > 3 {
            Grid(alignment: .topLeading, horizontalSpacing: 16, verticalSpacing: 12) {
                ForEach(Array(stride(from: 0, to: stats.count, by: 2)), id: \.self) { start in
                    GridRow {
                        statTile(stats[start])
                        if start + 1 < stats.count {
                            statTile(stats[start + 1])
                        }
                    }
                }
            }
        } else {
            HStack(alignment: .top, spacing: 16) {
                ForEach(stats) { statTile($0) }
            }
        }
    }

    /// Only a compact-width iPhone wraps. An iPad detail column and a macOS
    /// settings card are both wide enough for four columns, and wrapping them
    /// would waste the width they have.
    private var wrapsStatTiles: Bool {
        #if os(iOS)
        return horizontalSizeClass == .compact
        #else
        return false
        #endif
    }

    // MARK: - Input

    /// Modes that actually happened, busiest first. A mode with no turn behind
    /// it is not drawn as a zero: the card is about the mix, and a permanent
    /// "Shared 0" row would read as a feature that is failing rather than one
    /// this user does not use.
    private var visibleInputModes: [InputModeSlice] {
        model.summary.attributedInputModes
            .filter { $0.turns > 0 }
            .sorted { $0.turns > $1.turns }
    }

    /// How turns were GIVEN, never how they were retried — a retry creates no
    /// new input, which is why this counts turns and the Reliability card counts
    /// attempts.
    private var inputSection: some View {
        let slices = visibleInputModes
        let total = slices.reduce(0) { $0 + $1.turns }

        return Section {
            ForEach(slices, id: \.mode) { slice in
                inputModeRow(slice, total: total)
            }
        } header: {
            Text(LocalizedStringResource(
                "settings.usage.input.header", defaultValue: "Input"))
        }
        // NO FOOTER. "Typed 41 · Voice 12" under a header reading Input is
        // already the whole sentence a footer would have written out.
    }

    private func inputModeRow(
        _ slice: InputModeSlice,
        total: Int
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: inputModeIcon(slice.mode))
                .foregroundStyle(AppColors.usageIconBlue)
                .accessibilityHidden(true)
            Text(inputModeLabel(slice.mode))
                .foregroundStyle(AppColors.textPrimary)
            Spacer(minLength: 12)
            Text(inputModeValueText(slice, total: total))
                .monospacedDigit()
                .foregroundStyle(AppColors.textSecondary)
        }
        .settingsCardPassiveRow()
        .accessibilityElement(children: .combine)
    }

    private func inputModeValueText(
        _ slice: InputModeSlice,
        total: Int
    ) -> String {
        let share = GatewayUsageAggregator.ratio(slice.turns, total)
        return String(
            localized: "settings.usage.input.value",
            defaultValue: "\(slice.turns.formatted(.number)) · \(percentText(share))")
    }

    /// Modality glyphs, matching the ones a turn already wears in the thread.
    private func inputModeIcon(_ mode: GatewayInputMode) -> String {
        switch mode {
        case .voice: return "waveform"
        case .text: return "keyboard"
        case .shared: return "square.and.arrow.up"
        case .unknown: return "questionmark.circle"
        }
    }

    private func inputModeLabel(_ mode: GatewayInputMode) -> String {
        switch mode {
        case .voice:
            return String(localized: "settings.usage.input.voice", defaultValue: "Voice")
        case .text:
            return String(localized: "settings.usage.input.text", defaultValue: "Typed")
        case .shared:
            return String(localized: "settings.usage.input.shared", defaultValue: "Shared")
        case .unknown:
            return unattributedLabel
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
            reliabilityDetail
        } header: {
            Text(LocalizedStringResource(
                "settings.usage.reliability.header", defaultValue: "Reliability"))
        } footer: {
            reliabilityFooter
        }
    }

    /// THE HEADLINE IS THE ANSWER; the rest is the follow-up. Ten rows under a
    /// single percentage is the shape that made this the longest card on the
    /// screen, and most of what it holds is a question only a user already
    /// suspecting a problem asks. So the detail collapses by default and
    /// remembers being opened.
    ///
    /// Two implementations, one set of rows — the `VoiceReliabilityDisclosure`
    /// pattern. iOS keeps `DisclosureGroup`, where the whole row already
    /// toggles and hit-tests. macOS hand-rolls the expander and OWNS the
    /// chevron, because `DisclosureGroup` renders its chevron in a slot OUTSIDE
    /// the label: the label can therefore never span the row, and the row's
    /// gutter would not line up with the card rows above and below it. A real
    /// `Button` also carries keyboard activation, VoiceOver activation and a
    /// pressed state that a tap gesture on a label does not.
    ///
    /// The LABEL itself is `UsageDetailRows.detailDisclosureLabel`, the same one
    /// the Tokens card's disclosure renders. Both sit on THIS screen, so a
    /// second copy of that `Text` is exactly how the two would drift apart.
    @ViewBuilder
    private var reliabilityDetail: some View {
        #if os(macOS)
        Button {
            withAnimation { reliabilityDetailExpanded.toggle() }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppColors.textTertiary)
                    // Driven from inside the action's `withAnimation` so the
                    // turn rides the same transaction as the reveal below.
                    .rotationEffect(.degrees(reliabilityDetailExpanded ? 90 : 0))
                    .accessibilityHidden(true)
                UsageDetailRows.detailDisclosureLabel(
                    accessibility: UsageDetailRows.reliabilityDetailsAccessibility)
                Spacer()
            }
        }
        .settingsCardRowButton()
        .accessibilityHint(Text(reliabilityDetailExpanded
            ? LocalizedStringResource(
                "settings.usage.reliability.details.collapse", defaultValue: "Collapse")
            : LocalizedStringResource(
                "settings.usage.reliability.details.expand", defaultValue: "Expand")))

        if reliabilityDetailExpanded {
            reliabilityDetailRows
        }
        #else
        DisclosureGroup(isExpanded: $reliabilityDetailExpanded) {
            reliabilityDetailRows
        } label: {
            UsageDetailRows.detailDisclosureLabel(
                accessibility: UsageDetailRows.reliabilityDetailsAccessibility)
                .tappableDisclosureLabel($reliabilityDetailExpanded)
        }
        #endif
    }

    /// Everything the headline does not answer. Lifted out of the section for
    /// the same reason `outcomeRows` is: it keeps the section's own child count
    /// well clear of `ViewBuilder`'s ten, and macOS resolves card rows by SHAPE
    /// — a child that emits several views is several rows — so every row below
    /// is still its own card row, exactly as if it had been written in place.
    @ViewBuilder
    private var reliabilityDetailRows: some View {
        let summary = model.summary

        outcomeRows

        // RESOLVED turns, not attempted ones. A turn still running has not
        // yet failed to be delivered first try, and counting it as one would
        // make an active minute look like a reliability dip.
        valueRow(
            label: LocalizedStringResource(
                "settings.usage.reliability.firstTry",
                defaultValue: "Delivered first try"),
            value: percentText(GatewayUsageAggregator.ratio(
                summary.firstAttemptDeliveredTurns, summary.resolvedTurns)),
            caption: LocalizedStringResource(
                "settings.usage.reliability.firstTry.caption",
                defaultValue: """
                    \(summary.firstAttemptDeliveredTurns) of \
                    \(summary.resolvedTurns) finished turns
                    """)
        )
        // Only where there is something to recover FROM. With no retry in
        // range the row is a permanent em dash under a question nobody asked.
        //
        // RESOLVED retried turns, never the wider `retriedTurns`: a turn
        // still being retried has not failed to recover, and dividing by the
        // wider population would report it as one that did.
        if summary.resolvedRetriedTurns > 0 {
            valueRow(
                label: LocalizedStringResource(
                    "settings.usage.reliability.recovered",
                    defaultValue: "Recovered by retry"),
                value: percentText(GatewayUsageAggregator.ratio(
                    summary.retriedTurnsRecovered, summary.resolvedRetriedTurns)),
                caption: LocalizedStringResource(
                    "settings.usage.reliability.recovered.caption",
                    defaultValue: """
                        \(summary.retriedTurnsRecovered) of \
                        \(summary.resolvedRetriedTurns) retried turns landed
                        """)
            )
        }

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
        failureReasonRows
    }

    /// ITS OWN KEY for the first sentence: the outcome rows sit behind Details,
    /// so a footer saying they are "listed above" is false whenever the card is
    /// collapsed — which is its default state. A catalog value wins over
    /// `defaultValue:`, so rewording a shipped key in place would keep
    /// rendering the old sentence in every build that has the catalog.
    /// ONE sentence, and only because the headline is a bare percentage whose
    /// denominator is not the number above it. A reader who divides the two
    /// figures on this card gets a different answer unless this is said; the
    /// two footnotes that used to sit beneath it — what "cut short" means, that
    /// reasons are counted rather than listed — were answering their own rows'
    /// labels a second time.
    private var reliabilityFooter: some View {
        Text(LocalizedStringResource(
            "settings.usage.reliability.footer.rate",
            defaultValue: """
                Cancelled and unconfirmed attempts stay out of this rate.
                """))
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

    // MARK: - Failure reasons

    /// How many distinct reasons get a row of their own before the tail is
    /// collapsed. A long tail of one-offs is noise in an aggregate — and only a
    /// NAMED reason can be the way into the turns behind it, since the folded
    /// row stands for several codes and so has no single filter to push.
    private static let failureReasonRowLimit = 5

    /// WHY attempts failed, in aggregate — and each named reason is the way INTO
    /// the turns behind it: the row pushes `UsageIncidentListView`, filtered to
    /// that one error code and to the range already on screen. Copy
    /// comes through `UsageFailureReasonCopy`, which is a thin read on
    /// `DiagnosticsExplainer` — the app's own code-to-sentence map — so a reason
    /// reads identically here, on the gateway drill-down, and on Diagnostics.
    ///
    /// The stored code is the ONLY thing the ledger kept: no provider error
    /// string, no status code. That is why a reason can be named at all without
    /// breaking the content-free rule.
    @ViewBuilder
    private var failureReasonRows: some View {
        let reasons = model.summary.failureReasons
        if !reasons.isEmpty {
            let top = Array(reasons.prefix(Self.failureReasonRowLimit))
            let otherCount = reasons.dropFirst(Self.failureReasonRowLimit)
                .reduce(0) { $0 + $1.count }

            Text(LocalizedStringResource(
                "settings.usage.reliability.reasons.header",
                defaultValue: "Failure reasons"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppColors.textTertiary)
                .settingsCardPassiveRow()

            ForEach(top, id: \.appErrorCode) { reason in
                // THE ROW IS THE WAY IN. A named reason pushes the turns behind
                // it, filtered to that one error code and to the range already
                // on screen.
                failureReasonRow(
                    label: UsageFailureReasonCopy.label(forAppErrorCode: reason.appErrorCode),
                    count: reason.count,
                    route: .incidents(UsageIncidentFilter(
                        gateway: .anyGateway, appErrorCode: reason.appErrorCode))
                )
            }
            if otherCount > 0 {
                // NO PUSH. The folded row stands for several distinct codes, so
                // there is no single filter it could carry.
                failureReasonRow(
                    label: String(localized: "settings.usage.reliability.reasons.other",
                                  defaultValue: "Other reasons"),
                    count: otherCount
                )
            }
        }
    }

    /// A cause sentence, wrapped, with its count. The label is a resolved
    /// `String` rather than a `LocalizedStringResource` because it arrives from
    /// the shared explainer already localized — which is the point of reusing it.
    ///
    /// With a `route:` it becomes a push and inherits the screen's ONE
    /// navigation-row treatment — the platform's own accessory on iOS, the
    /// hand-drawn chevron on the macOS card.
    @ViewBuilder
    private func failureReasonRow(
        label: String,
        count: Int,
        route: UsageRoute? = nil
    ) -> some View {
        if let route {
            navigationRow(value: route) {
                failureReasonRowBody(label: label, count: count)
            }
        } else {
            failureReasonRowBody(label: label, count: count)
                .settingsCardPassiveRow()
                .accessibilityElement(children: .combine)
        }
    }

    private func failureReasonRowBody(label: String, count: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(AppColors.error)
                .accessibilityHidden(true)
            Text(label)
                .font(.subheadline)
                .foregroundStyle(AppColors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 12)
            Text(count.formatted(.number))
                .font(.subheadline)
                .monospacedDigit()
                .foregroundStyle(AppColors.textSecondary)
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
            // KEPT: without it a median is read as model speed, and a slow
            // agent looks like a slow app. The clause that earns the line is
            // the last one.
            Text(LocalizedStringResource(
                "settings.usage.response.footer.scope",
                defaultValue: """
                    Includes the network and any tools your agent ran — not \
                    model latency.
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
                // ONE implementation, shared with every drill-down's Tokens
                // card, and it hides itself when no gateway in range reported
                // any of the three. Inside this branch on purpose: the rows it
                // reveals are PARTS of the figures above them, and a part has
                // nothing to be a part of on a card that is telling the user
                // nothing was reported.
                UsageDetailRows.tokenDetail(tokens, expanded: $tokenDetailExpanded)
            }
        } header: {
            Text(LocalizedStringResource(
                "settings.usage.tokens.header", defaultValue: "Reported tokens"))
        } footer: {
            // The header already says "Reported" and each row carries its own
            // coverage caption. The ONE caveat neither can carry is that this
            // card — unlike the gateway drill-down — adds figures from gateways
            // that do not count alike, so the sums mix rulers. Rendered only
            // when more than one gateway is in range: with a single ruler
            // there is nothing mixed.
            if !tokens.isEmpty && model.summary.attributedGatewayGroups.count > 1 {
                Text(LocalizedStringResource(
                    "settings.usage.tokens.footer.rulers",
                    defaultValue: """
                        Each gateway counts tokens its own way, so these figures \
                        add up numbers that were not counted alike.
                        """))
            }
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

    // MARK: - By device

    /// Which of the user's devices did the sending. NO TOKENS HERE on purpose:
    /// a device does not have a token cost, the gateway does, and putting a sum
    /// beside a device invites reading one iPhone as more expensive than
    /// another. The drill-down carries the fuller picture.
    ///
    /// ONLY REAL DEVICES GET A ROW — `attributedDeviceGroups`. There are five
    /// devices, and a sixth row for the attempts whose device was never
    /// recorded reads as one of them. Those attempts leave this LIST and
    /// nothing else: they are inside every figure above, and the screen does
    /// not single them out, because a count of unmeasured things is a fact
    /// about the ledger rather than about the user's setup.
    private var deviceSection: some View {
        Section {
            ForEach(model.summary.attributedDeviceGroups) { group in
                deviceGroupRow(group)
            }
        } header: {
            Text(LocalizedStringResource(
                "settings.usage.byDevice.header", defaultValue: "By device"))
        } footer: {
            // ONLY where it explains something on screen. A list of device
            // names needs no gloss; CarPlay sitting BESIDE the very iPhone
            // driving it is the one row a person reads as a double-count, so
            // the note appears exactly when that row does.
            if showsCarPlayNote {
                Text(LocalizedStringResource(
                    "settings.usage.byDevice.footer.carPlay",
                    defaultValue: "CarPlay is listed separately from the phone driving it."))
            }
        }
    }

    private var showsCarPlayNote: Bool {
        model.summary.attributedDeviceGroups
            .contains { $0.key == UsageDeviceBucket.carPlay.rawValue }
    }

    /// TITLE AND CHEVRON ONLY on the top line. The row is read against its
    /// siblings on the rates underneath it, and a raw attempt count at the
    /// trailing edge is the one figure that answers nothing on its own — the
    /// caption already carries the sample those rates are taken over, and the
    /// drill-down carries the count itself.
    private func deviceGroupRow(_ group: GatewayUsageGroup) -> some View {
        let bucket = UsageDeviceBucket(rawValue: group.key ?? "") ?? .unknown
        return navigationRow(value: UsageRoute.device(bucket)) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: deviceIcon(bucket))
                        .foregroundStyle(AppColors.usageIconBlue)
                        .accessibilityHidden(true)
                    Text(deviceLabel(bucket))
                        .font(.body.weight(.semibold))
                        .foregroundStyle(AppColors.textPrimary)
                    Spacer(minLength: 8)
                }
                Text(deviceDetailText(group))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(AppColors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func deviceDetailText(_ group: GatewayUsageGroup) -> String {
        var parts: [String] = [
            String(localized: "settings.usage.byGateway.successRate",
                   defaultValue: "\(percentText(group.successRate)) succeeded")
        ]
        if let median = group.medianResponseTime {
            // PLAIN LANGUAGE, not "(n 12)". The sample size has to be here —
            // a median over three replies is not a claim — but `n` is a
            // statistician's abbreviation, and this row is read by someone
            // asking which gateway feels faster.
            parts.append(String(
                localized: "settings.usage.byGateway.median.plain",
                defaultValue: """
                    median \(durationText(median)) over \
                    \(repliesText(group.responseSampleCount))
                    """))
        }
        return parts.joined(separator: " · ")
    }

    /// Icons and words reused from the turn's own device chip, so one device is
    /// named the same way wherever the user meets it.
    ///
    /// The unattributed arm is a FLOOR, not a case the section reaches: the
    /// rows come from `attributedDeviceGroups`, so every key here names one of
    /// the five devices. It stays because the enum still carries the bucket,
    /// which the route and the drill-down both remain able to name.
    private func deviceIcon(_ bucket: UsageDeviceBucket) -> String {
        guard let device = Self.deviceFormatterKey(bucket) else { return "questionmark.circle" }
        return MessageRowFormatters.icon(forDevice: device)
    }

    private func deviceLabel(_ bucket: UsageDeviceBucket) -> String {
        guard let device = Self.deviceFormatterKey(bucket) else { return unattributedLabel }
        return MessageRowFormatters.label(forDevice: device)
    }

    /// The bucket's word in `sourceDevice` spelling. `carPlay` is camel-cased in
    /// the bucket and lower-cased on the wire tag, and mapping it here is what
    /// keeps the two vocabularies from being merged into one that then has to
    /// stay in sync with a stored string.
    private static func deviceFormatterKey(_ bucket: UsageDeviceBucket) -> String? {
        switch bucket {
        case .iphone: return "iphone"
        case .ipad: return "ipad"
        case .mac: return "mac"
        case .watch: return "watch"
        case .carPlay: return "carplay"
        case .unknown: return nil
        }
    }

    // MARK: - By gateway

    private var gatewaySection: some View {
        Section {
            ForEach(model.summary.attributedGatewayGroups) { group in
                gatewayGroupRow(group)
            }
        } header: {
            Text(LocalizedStringResource(
                "settings.usage.byGateway.header", defaultValue: "By gateway"))
        } footer: {
            // KEPT: a gateway the user deleted still having a row is the one
            // thing on this card that looks like a bug. Which gateway a
            // conversation was bound to needs no explaining.
            Text(LocalizedStringResource(
                "settings.usage.byGateway.footer.history",
                defaultValue: """
                    A gateway you have since edited or removed still appears for \
                    the history it made.
                    """))
        }
    }

    /// ONE row per gateway — a `VStack`, deliberately, because macOS resolves a
    /// child's row count from its SHAPE and two loose `Text`s here would become
    /// two separated card rows.
    ///
    /// The per-model breakdown lives in the drill-down, not here. Nesting it
    /// under a row made the overview's longest card grow with the user's model
    /// list, and the mix is a question about ONE gateway rather than about the
    /// range.
    ///
    /// Name and chevron only on the top line, matching the device rows: the
    /// figures a gateway is compared on are the rates in the caption, and the
    /// sample they are taken over is already stated there.
    private func gatewayGroupRow(_ group: GatewayUsageGroup) -> some View {
        navigationRow(value: UsageRoute.gateway(group.key)) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(gatewayLabel(for: group.key))
                        .font(.body.weight(.semibold))
                        .foregroundStyle(AppColors.textPrimary)
                    Spacer(minLength: 8)
                }

                Text(groupDetailText(group))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(AppColors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func groupDetailText(_ group: GatewayUsageGroup) -> String {
        var parts: [String] = [
            String(localized: "settings.usage.byGateway.successRate",
                   defaultValue: "\(percentText(group.successRate)) succeeded")
        ]
        if let median = group.medianResponseTime {
            // PLAIN LANGUAGE, not "(n 12)". The sample size has to be here —
            // a median over three replies is not a claim — but `n` is a
            // statistician's abbreviation, and this row is read by someone
            // asking which gateway feels faster.
            parts.append(String(
                localized: "settings.usage.byGateway.median.plain",
                defaultValue: """
                    median \(durationText(median)) over \
                    \(repliesText(group.responseSampleCount))
                    """))
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

    // MARK: - Heaviest threads

    /// Rows on the overview before the list moves to its own screen. THREE, and
    /// two lines each: the overview answers "what", and a fourth and fifth row
    /// of the same shape push the Coverage card — where the destructive clear
    /// lives — off the bottom of a phone screen. "See all" is one tap.
    private static let threadRowLimit = 3

    /// The threads that cost the most, ranked on ONE basis for the whole list —
    /// a list mixing gateway-reported totals with client-added components would
    /// order threads by which gateway happened to be chattier about usage.
    ///
    /// A row names no title and quotes nothing. The date span, the gateway and
    /// the counts are the whole of it; the conversation itself is one tap away
    /// for the threads that still exist.
    private var threadsSection: some View {
        let ranking = model.summary.threadRanking
        let top = Array(ranking.threads.prefix(Self.threadRowLimit))

        return Section {
            ForEach(top, id: \.conversationID) { thread in
                threadRow(thread, basis: ranking.basis)
            }
            if ranking.threads.count > top.count {
                navigationRow(value: UsageRoute.allThreads) {
                    Text(LocalizedStringResource(
                        "settings.usage.threads.seeAll", defaultValue: "See all"))
                        .foregroundStyle(AppColors.textPrimary)
                }
            }
        } header: {
            Text(LocalizedStringResource(
                "settings.usage.threads.header", defaultValue: "Heaviest threads"))
        } footer: {
            Text(threadBasisFooter(ranking.basis))
        }
    }

    /// The ranking basis, said plainly INCLUDING what it leaves out. A list that
    /// silently drops every thread whose gateway reported nothing looks like a
    /// list of the user's heaviest threads and is not one.
    private func threadBasisFooter(_ basis: ThreadRanking.Basis) -> LocalizedStringResource {
        switch basis {
        case .reportedTotals:
            return LocalizedStringResource(
                "settings.usage.threads.footer.reported",
                defaultValue: """
                    Ranked by the total tokens your gateway reported. Threads it \
                    reported no total for aren't ranked here.
                    """)
        case .calculatedComponents:
            return LocalizedStringResource(
                "settings.usage.threads.footer.components",
                defaultValue: """
                    Ranked by input plus output tokens, added up from what your \
                    gateway reported — it reported no totals of its own. Threads \
                    reporting neither aren't ranked here.
                    """)
        }
    }

    /// A live thread navigates; an absent one says so and does not. ABSENT IS
    /// NOT DELETED: the conversation may be deleted, not yet imported from
    /// another device, or temporarily unreadable, and the row cannot tell those
    /// apart. Naming it a deletion would accuse the user of something sync is
    /// still working on — and the chevron returns on its own if the thread
    /// arrives later.
    @ViewBuilder
    private func threadRow(_ thread: ThreadUsage, basis: ThreadRanking.Basis) -> some View {
        if model.liveConversationIDs.contains(thread.conversationID) {
            Button {
                model.openConversation(thread.conversationID)
            } label: {
                threadRowBody(thread, basis: basis, isLive: true)
                    .padding(.trailing, chevronGutter)
            }
            // `.settingsCardRowButton()` IS `.buttonStyle(.plain)` off macOS, so
            // this one modifier gives the card row its full-bleed live frame and
            // leaves the `Form` row untinted on iOS.
            .settingsCardRowButton()
            .overlay(alignment: .trailing) { rowChevron }
        } else {
            threadRowBody(thread, basis: basis, isLive: false)
                .settingsCardPassiveRow()
                .accessibilityElement(children: .combine)
        }
    }

    private func threadRowBody(
        _ thread: ThreadUsage,
        basis: ThreadRanking.Basis,
        isLive: Bool
    ) -> some View {
        // TWO LINES. The thing being ranked (the tokens) sits at the trailing
        // edge of the first line so three rows read as a column of figures
        // rather than three paragraphs; everything that qualifies it — which
        // gateway, how many attempts, what was attached, how complete the
        // measurement is — folds into ONE caption underneath.
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(threadDateSpan(thread))
                    .font(.subheadline)
                    .foregroundStyle(AppColors.textPrimary)
                Spacer(minLength: 8)
                Text(threadTokensBasisText(thread.rankedTokens, basis: basis))
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(AppColors.textEmphasis)
                    .multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text(threadCaptionText(thread))
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(AppColors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            if !isLive {
                Text(LocalizedStringResource(
                    "settings.usage.threads.unavailable",
                    defaultValue: "Conversation unavailable"))
                    .font(.caption)
                    .foregroundStyle(AppColors.textTertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// One date when the thread's measured life is a single day, a span when it
    /// is not. Dates only — a time of day is a fact about when someone was at
    /// their desk.
    private func threadDateSpan(_ thread: ThreadUsage) -> String {
        let start = thread.earliestStart.formatted(date: .abbreviated, time: .omitted)
        if Calendar.current.isDate(thread.earliestStart, inSameDayAs: thread.latestStart) {
            return start
        }
        let end = thread.latestStart.formatted(date: .abbreviated, time: .omitted)
        return String(localized: "settings.usage.threads.span",
                      defaultValue: "\(start) – \(end)")
    }

    /// Every gateway the thread actually sent through, resolved at render time.
    /// A thread cannot rebind, but a CarPlay override and a clone-and-switch
    /// both leave more than one ref behind, so the plural case is real.
    private func threadGatewayText(_ thread: ThreadUsage) -> String {
        let names = thread.gatewayRefs.map { gatewayLabel(for: $0) }
        guard !names.isEmpty else { return unattributedLabel }
        return names.joined(separator: " · ")
    }

    /// Everything qualifying the ranked figure, on one line. Attachment counts
    /// and the coverage fragment each appear only when they say something: a
    /// zero image count and a complete measurement are both silence, and a row
    /// that prints them anyway trains the eye to skip the caption entirely.
    private func threadCaptionText(_ thread: ThreadUsage) -> String {
        var parts: [String] = [
            threadGatewayText(thread),
            attemptsText(thread.attempts)
        ]
        if let images = thread.inlineImageCount, images > 0 {
            parts.append(String(localized: "settings.usage.threads.images",
                                defaultValue: "\(images) images"))
        }
        if let files = thread.inlineTextFileCount, files > 0 {
            parts.append(String(localized: "settings.usage.threads.files",
                                defaultValue: "\(files) files"))
        }
        if let coverage = threadCoverageCaption(thread) {
            parts.append(coverage)
        }
        return parts.joined(separator: " · ")
    }

    /// The basis rides the NUMBER, not just the footer. A user reading one row
    /// has to be able to tell a gateway's own total from a figure this client
    /// added up — the tokens card on this same screen holds the identical rule.
    private func threadTokensBasisText(
        _ tokens: Int,
        basis: ThreadRanking.Basis
    ) -> String {
        switch basis {
        case .reportedTotals:
            return String(localized: "settings.usage.threads.tokens.reported",
                          defaultValue: "\(tokens.formatted(.number)) tokens")
        case .calculatedComponents:
            return String(localized: "settings.usage.threads.tokens.components",
                          defaultValue: "\(tokens.formatted(.number)) tokens (input + output)")
        }
    }

    /// Shown only where coverage is PARTIAL. Full coverage needs no caption, and
    /// a caption on every row would train the eye to skip the one row where it
    /// changes the meaning of the number above it.
    private func threadCoverageCaption(_ thread: ThreadUsage) -> String? {
        var lines: [String] = []
        if thread.tokenReportedTurns < thread.turns {
            lines.append(String(
                localized: "settings.usage.threads.coverage.tokens",
                defaultValue: """
                    Tokens reported on \(thread.tokenReportedTurns) of \
                    \(thread.turns) turns
                    """))
        }
        let hasAttachmentCounts =
            thread.inlineImageCount != nil || thread.inlineTextFileCount != nil
        if hasAttachmentCounts, thread.attachmentMeasuredAttempts < thread.attempts {
            lines.append(String(
                localized: "settings.usage.threads.coverage.attachments",
                defaultValue: """
                    Attachments counted on \(thread.attachmentMeasuredAttempts) of \
                    \(thread.attempts) attempts
                    """))
        }
        return lines.isEmpty ? nil : lines.joined(separator: " · ")
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

            // A clear that failed says so. Silence here would leave records the
            // user believes are gone — and the cutoff has already advanced, so
            // what they see is right while what is on disk is not yet.
            if let clearError = model.clearUsageHistoryError {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(AppColors.warning)
                        .accessibilityHidden(true)
                    Text(clearError)
                        .font(.subheadline)
                        .foregroundStyle(AppColors.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 12)
                }
                .settingsCardPassiveRow()
                .accessibilityElement(children: .combine)
            }

            // A destructive control that would erase nothing is not offered.
            // `hasAnyRecordedAttempts` asks the ledger-wide question rather than
            // the range's, so switching to "7 days" never hides the control for
            // history that is still there.
            if model.isClearingUsageHistory {
                clearProgressRow
            } else if model.hasAnyRecordedAttempts {
                clearUsageHistoryRow
            }
        } header: {
            Text(LocalizedStringResource(
                "settings.usage.coverage.header", defaultValue: "Coverage"))
        } footer: {
            // ONE honest sentence about what these totals cover. Usage records
            // outlive the conversations they describe, so a footer promising the
            // numbers describe "conversations you've kept" would be false for
            // every user who has ever deleted a thread.
            //
            // ITS OWN KEY, not the one the earlier sentence used: a catalog value
            // wins over `defaultValue:`, so rewording in place would keep
            // rendering the old, now-false sentence in every shipped build.
            Text(LocalizedStringResource(
                "settings.usage.coverage.retention.footer",
                defaultValue: """
                    These totals include conversations you have since deleted — \
                    the records are content-free and stay until you clear usage \
                    history.
                    """))
        }
    }

    /// The quiet destructive row. Its own line, at the foot of the screen that
    /// explains what it erases, with the account-wide reach and the finality
    /// both stated in the dialog rather than in the row's label.
    private var clearUsageHistoryRow: some View {
        Button(role: .destructive) {
            showingClearConfirmation = true
        } label: {
            Label(
                LocalizedStringResource(
                    "settings.usage.clear.action", defaultValue: "Clear usage history"),
                systemImage: "trash"
            )
            .font(.subheadline)
        }
        .settingsCardRowButton()
        .foregroundStyle(AppColors.error)
        .confirmationDialog(
            LocalizedStringResource(
                "settings.usage.clear.title", defaultValue: "Clear usage history?"),
            isPresented: $showingClearConfirmation,
            titleVisibility: .visible
        ) {
            Button(
                LocalizedStringResource(
                    "settings.usage.clear.action", defaultValue: "Clear usage history"),
                role: .destructive
            ) {
                Task { await model.clearUsageHistory() }
            }
            Button(
                LocalizedStringResource(
                    "settings.usage.clear.cancel", defaultValue: "Cancel"),
                role: .cancel
            ) { }
        } message: {
            Text(LocalizedStringResource(
                "settings.usage.clear.message",
                defaultValue: """
                    This removes every usage record from this device and all your \
                    other devices. Your conversations are not affected. This \
                    cannot be undone.
                    """))
        }
    }

    /// Local progress only. The clear reaches the user's other devices when they
    /// next sync, and a bar here claiming to track that would be inventing a
    /// completion this device cannot observe.
    private var clearProgressRow: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text(LocalizedStringResource(
                "settings.usage.clear.progress", defaultValue: "Clearing usage history…"))
                .font(.subheadline)
                .foregroundStyle(AppColors.textSecondary)
        }
        .settingsCardPassiveRow()
        .accessibilityElement(children: .combine)
    }

    // MARK: - Row vocabulary

    /// A row that pushes a `UsageRoute`. `NavigationLink` IS a `Button`, so the
    /// card row STYLE reaches it on macOS and brings the full-bleed live frame,
    /// the row inset and the squared wash in one modifier — and off macOS the
    /// same modifier is `.buttonStyle(.plain)`, which is what a `Form` row wants.
    ///
    /// THE CHEVRON IS THE PLATFORM'S WHEREVER THE PLATFORM DRAWS ONE — the
    /// `LicensesView` treatment, which is the app's one idiom for a
    /// `NavigationLink` inside a `PlatformSettingsForm`. The iOS grouped `Form`
    /// IS a `List`, so it already gives a link the system disclosure accessory,
    /// laid out BESIDE the row content and mirrored for RTL for free; a second
    /// hand-drawn one would sit on top of the label as a stray offset arrow.
    /// macOS renders the same section as a hand-drawn `SettingsCard`, which is
    /// not a `List` and supplies no accessory, so that branch draws its own —
    /// trailing-inset to `rowInset` so it lines up with the label on the other
    /// side of the row, over a gutter the label keeps clear for it.
    private func navigationRow<Label: View>(
        value: UsageRoute,
        @ViewBuilder label: () -> Label
    ) -> some View {
        NavigationLink(value: value) {
            label()
                .frame(maxWidth: .infinity, alignment: .leading)
                #if os(macOS)
                .padding(.trailing, chevronGutter)
                #endif
        }
        .settingsCardRowButton()
        #if os(macOS)
        .overlay(alignment: .trailing) { rowChevron }
        #endif
    }

    /// Decoration, never an element: an overlay is a SIBLING of the link it sits
    /// on, so without `accessibilityHidden` it lands in the rotor as a stray
    /// item the row's own label already covers.
    private var rowChevron: some View {
        Image(systemName: "chevron.forward")
            .font(.caption)
            .foregroundStyle(AppColors.textTertiary)
            .padding(.trailing, rowChevronInset)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    /// Trailing inset for the overlaid chevron — `rowInset` on macOS so it lines
    /// up with the label on the other side of the card row, nothing elsewhere
    /// where the `Form` supplies its own.
    private var rowChevronInset: CGFloat {
        #if os(macOS)
        SettingsCardMetrics.rowInset
        #else
        0
        #endif
    }

    /// Space a navigating row keeps clear so a long value never runs under the
    /// chevron drawn on top of it.
    private var chevronGutter: CGFloat { 16 }

    /// The one word for "the ledger did not record this". Used for an
    /// unattributed gateway, an unrecorded device and an unrecorded input mode
    /// alike, because they are the same fact about capture rather than three
    /// different kinds of absence.
    private var unattributedLabel: String {
        String(localized: "settings.usage.gateway.unattributed",
               defaultValue: "Not recorded")
    }

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

    /// The described form, for the Activity row's variable tile set.
    private func statTile(_ tile: UsageActivityStat) -> some View {
        statTile(
            value: tile.value,
            label: tile.label,
            accessibility: tile.accessibility
        )
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

    /// Two keys rather than one plural rule, for the same reason
    /// `attemptsText` uses two — the headless catalog synthesis does not run
    /// Xcode's extraction phase, so a count-driven variation would have to be
    /// hand-written into the catalog.
    ///
    /// REPLIES, not attempts: the figures these captions qualify are measured
    /// on attempts that actually produced a reply, and "attempts" would name a
    /// wider population than the number was taken from.
    private func repliesText(_ count: Int) -> String {
        count == 1
            ? String(localized: "settings.usage.replies.one", defaultValue: "1 reply")
            : String(localized: "settings.usage.replies.other",
                     defaultValue: "\(count) replies")
    }

    /// The sample size and the window, always together and always visible: a
    /// median over three replies is not a claim, and the range is what makes it
    /// one. Said in words — "12 replies measured" — because "(n 12)" is
    /// notation, and nothing else on this screen asks the reader to know any.
    private func sampleCaption(count: Int) -> String {
        String(localized: "settings.usage.response.sampleCaption.plain",
               defaultValue: "\(repliesText(count)) measured · \(rangeCaption)")
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
        guard let key else { return unattributedLabel }
        guard let ref = RemoteAgentRef(rawString: key) else { return key }
        return RemoteAgentRefMetadata.displayName(for: ref, customs: gatewayRoster)
    }
}
