// SPDX-License-Identifier: Apache-2.0

// Conduck
// UsageIncidentListView.swift
//
// Settings ▸ Usage ▸ the turns behind a reliability figure. The reliability
// cards say HOW OFTEN something went wrong; this says WHICH turns, so a user
// who reads "3 requests timed out" can find out whether all three were one
// afternoon on one device or spread across a fortnight.
//
// READ-SIDE ONLY. Nothing here writes, retries, repairs or deletes anything —
// it is one more reading of the same range the overview already loaded, grouped
// a different way.
//
// GROUPED BY TURN, NOT BY ATTEMPT. Three retries of one question are one thing
// that went wrong, and listing them as three incidents would make a single bad
// minute look like a bad week. Attempts that recorded no `userMessageID` cannot
// be joined to anything and each stand alone, which is the honest reading
// rather than a bucket they were invented into.
//
// CONTENT-FREE, AND THAT IS RELEASE-BLOCKING. A row carries a date and time, the
// app's OWN sentence for a stored `AppError` code, a gateway SLOT's display name
// resolved from the roster at render time, a device-class word, and counts.
// There is no provider error string, no HTTP status, no URL and no host on this
// screen because the ledger holds none of them — and none of them may be
// invented to fill the gap. The conversation's title exists only where the user
// already is: tapping a row leaves Settings for the thread itself.
//
// "CONVERSATION UNAVAILABLE" IS NOT "DELETED", exactly as on the thread lists.
// The parent may be deleted, may not have imported from another device yet, or
// may be momentarily unreadable, and the row cannot tell those apart — so it
// says only that it cannot be opened, and grows its chevron back on its own if
// the thread arrives later.
//
// PAGING IS EXPLICIT, NEVER SILENT. A range can hold thousands of failed turns;
// the first page is `UsageIncidentList.pageSize` groups, and the count line says
// how many of how many are on screen so the cut is a fact the user can see
// rather than a list that quietly stops.
//
// THE PURE HALF IS `UsageIncidentList`, below: grouping, ordering, filtering,
// the retry narrative and the count line are all value-in/string-out, which is
// what makes every sentence on this screen unit-testable without rendering a
// view (the `UsageActivityChart` split).

import SwiftUI

// MARK: - Filter

/// What one push of this screen is narrowed to. Always range-scoped on top of
/// this — the range comes from the model, never from the route, so a drill-down
/// can never show a window the overview has left.
nonisolated struct UsageIncidentFilter: Hashable, Sendable {
    /// Which gateway slots count.
    ///
    /// A CASE RATHER THAN AN OPTIONAL, because `nil` is already a meaningful
    /// slot here: `.slot(nil)` is "the attempts that recorded no gateway at
    /// all", which is a real group the drill-down can be opened on, and
    /// `.anyGateway` is "do not narrow by gateway". A `String??` would collapse
    /// those two into a shape nobody reads correctly twice.
    enum GatewayScope: Hashable, Sendable {
        case anyGateway
        case slot(String?)
    }

    var gateway: GatewayScope = .anyGateway

    /// Conduck's own `AppError.errorCode`. Nil lists every failed turn in
    /// scope; a value keeps the turns that failed for THAT reason.
    var appErrorCode: Int?
}

// MARK: - One grouped turn

/// One turn that went wrong, and everything a row of it may say. Every field is
/// a count, an instant, a stable local error code or a configured SLOT's raw
/// string — nothing that describes what was asked or answered.
nonisolated struct UsageIncidentGroup: Identifiable, Sendable, Equatable {
    /// Stable across redraws and unique across both kinds of group — a turn's
    /// id and a lone attempt's id are namespaced apart so the two can never
    /// collide in a `ForEach`.
    let id: String
    /// Nil when the attempts recorded no conversation. Such a row still counts
    /// and still renders; it simply has nothing to navigate to.
    let conversationID: UUID?
    /// The turn's EARLIEST attempt start — when the user asked, not when the
    /// last retry gave up. Nil when no attempt in the group can say when it
    /// ran, which a half-materialised imported row genuinely cannot.
    let startedAt: Date?
    /// The code the row names. Nil only when the failure recorded none.
    let appErrorCode: Int?
    /// The slot the FIRST attempt used, resolved to a name at render time.
    let gatewayRef: String?
    let device: UsageDeviceBucket
    let attemptCount: Int
    /// Attempts in the group with a stored `failed` outcome.
    let failureCount: Int
    /// The group's final DATED attempt succeeded — the turn was delivered in
    /// the end. Undated rows never decide this; see `UsageIncidentList.group`.
    let recovered: Bool
}

// MARK: - The pure half

/// Grouping, ordering, filtering and the two sentences a row can carry. Static
/// and side-effect free, so every claim this screen makes is checkable from a
/// fixture.
nonisolated enum UsageIncidentList {

    /// Groups on the first page. A ceiling on what is RENDERED, never on what is
    /// counted: the count line states the total, so the cut is visible.
    static let pageSize = 50

    /// The range's attempts, grouped into the turns that failed.
    ///
    /// ONLY GROUPS CONTAINING A STORED `failed` ATTEMPT APPEAR. This screen is
    /// reached from a reliability figure, and a turn that never failed is not
    /// something that went wrong; a cancelled or still-open turn has not failed
    /// either, and listing it here would count as a failure something no
    /// denominator on the dashboard does.
    static func groups(
        from records: [GatewayAttemptRecord],
        filter: UsageIncidentFilter
    ) -> [UsageIncidentGroup] {
        var byTurn: [UUID: [GatewayAttemptRecord]] = [:]
        var alone: [GatewayAttemptRecord] = []
        for record in records where matches(record, gateway: filter.gateway) {
            if let turn = record.userMessageID {
                byTurn[turn, default: []].append(record)
            } else {
                alone.append(record)
            }
        }

        var built: [UsageIncidentGroup] = []
        for (turn, rows) in byTurn {
            if let group = group(id: "turn:\(turn.uuidString)", rows: rows, filter: filter) {
                built.append(group)
            }
        }
        for record in alone {
            if let group = group(
                id: "attempt:\(record.id.uuidString)", rows: [record], filter: filter) {
                built.append(group)
            }
        }
        return built.sorted(by: newestFirst)
    }

    /// Whether a row is inside the push's gateway scope. `.slot(nil)` matches
    /// exactly the rows that recorded no slot — see `GatewayScope`.
    private static func matches(
        _ record: GatewayAttemptRecord,
        gateway: UsageIncidentFilter.GatewayScope
    ) -> Bool {
        switch gateway {
        case .anyGateway: return true
        case .slot(let ref): return record.gatewayRef == ref
        }
    }

    /// One group, or nil when these rows are not an incident under this filter.
    private static func group(
        id: String,
        rows: [GatewayAttemptRecord],
        filter: UsageIncidentFilter
    ) -> UsageIncidentGroup? {
        let ordered = rows.sorted(by: chronological)
        let failures = ordered.filter { $0.hasStoredOutcome && $0.outcome == .failed }
        guard !failures.isEmpty else { return nil }

        if let wanted = filter.appErrorCode {
            guard failures.contains(where: { $0.appErrorCode == wanted }) else { return nil }
        }

        // THE LAST FAILURE NAMES THE GROUP. A turn retried through two different
        // errors has two stories, and the one worth showing is the one it ended
        // on — that is the reason it is still on this list. A filtered push
        // names the code it was opened for, so the row and the row that opened
        // it can never disagree.
        let named = filter.appErrorCode
            ?? failures.last(where: { $0.appErrorCode != nil })?.appErrorCode

        // RECOVERY IS DECIDED BY THE LAST DATED ATTEMPT, never by the last row.
        // A row that cannot say when it ran cannot be shown to have come after
        // the failure it would be excusing, so it never turns a failed turn
        // into a recovered one; a group whose rows are all undated stays
        // failed, which is the only reading those rows support.
        let first = ordered.first
        let finalDated = ordered.last(where: { $0.startedAt != nil })
        return UsageIncidentGroup(
            id: id,
            conversationID: first?.conversationID,
            startedAt: ordered.compactMap { $0.startedAt }.first,
            appErrorCode: named,
            gatewayRef: first?.gatewayRef,
            device: first.map { UsageDeviceBucket.from(record: $0) } ?? .unknown,
            attemptCount: ordered.count,
            failureCount: failures.count,
            recovered: finalDated.map { $0.hasStoredOutcome && $0.outcome == .succeeded } ?? false
        )
    }

    /// Attempt order WITHIN one group, matching the aggregator's rule exactly:
    /// by start instant, then by id so two rows stamped in the same millisecond
    /// order the same way on every device. A row with no start instant sorts
    /// LAST — it cannot be claimed to have been the first try — and it is kept
    /// out of the recovery decision entirely: `group(id:rows:filter:)` reads the
    /// last DATED attempt, so an undated row is never the one that calls a
    /// failed turn recovered.
    private static func chronological(
        _ lhs: GatewayAttemptRecord,
        _ rhs: GatewayAttemptRecord
    ) -> Bool {
        let left = lhs.startedAt ?? .distantFuture
        let right = rhs.startedAt ?? .distantFuture
        if left != right { return left < right }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    /// NEWEST FIRST, with the undated groups last. A group that cannot say when
    /// it happened cannot be claimed to be the most recent one, and putting it
    /// at the top would push the turn the user is actually looking for down the
    /// screen.
    private static func newestFirst(
        _ lhs: UsageIncidentGroup,
        _ rhs: UsageIncidentGroup
    ) -> Bool {
        switch (lhs.startedAt, rhs.startedAt) {
        case (let left?, let right?):
            if left != right { return left > right }
        case (nil, .some): return false
        case (.some, nil): return true
        case (nil, nil): break
        }
        return lhs.id < rhs.id
    }

    /// What the retries did, or nil for a group with a single attempt — where
    /// there is no retry story and a sentence saying so would be noise on every
    /// row.
    static func retryNarrative(_ group: UsageIncidentGroup) -> String? {
        guard group.attemptCount > 1 else { return nil }
        if group.recovered {
            return String(localized: "settings.usage.incidents.recovered",
                          defaultValue: "Failed, then recovered")
        }
        // Two keys rather than one plural rule, for the reason the rest of the
        // usage screens use two: the headless build path that synthesizes the
        // string catalog does not run Xcode's extraction phase, so a
        // count-driven variation would have to be hand-written into it.
        return group.failureCount == 1
            ? String(localized: "settings.usage.incidents.failed.one",
                     defaultValue: "Failed once")
            : String(localized: "settings.usage.incidents.failed.other",
                     defaultValue: "Failed \(group.failureCount) times")
    }

    /// The paging line. ALWAYS rendered, including when the whole list fits:
    /// "Showing 6 of 6" is what makes "Showing 50 of 812" legible as a cut
    /// rather than as a total.
    static func showingText(shown: Int, total: Int) -> String {
        String(localized: "settings.usage.incidents.showing",
               defaultValue: "Showing \(shown) of \(total)")
    }
}

// MARK: - Screen

struct UsageIncidentListView: View {
    let model: UsageDashboardModel
    let filter: UsageIncidentFilter

    /// Display names for gateway slots, read once when the screen opens — the
    /// badge roster, so a slot the user has since removed still reads as itself.
    @State private var gatewayRoster: [CustomGateway] = []

    /// How many groups are rendered. Local to this push and reset by leaving it:
    /// "Show more" is a reading choice about one visit, not a preference.
    @State private var visibleCount = UsageIncidentList.pageSize

    /// Recomputed from the model's records, so the screen follows the range
    /// picker the overview owns rather than holding a window of its own.
    private var groups: [UsageIncidentGroup] {
        UsageIncidentList.groups(from: model.records, filter: filter)
    }

    private var title: String {
        String(localized: "settings.usage.incidents.title", defaultValue: "Failed turns")
    }

    var body: some View {
        PlatformSettingsForm {
            if groups.isEmpty {
                emptySection
            } else {
                listSection
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

    // MARK: - Sections

    /// Reachable in practice: the range can move under a pushed screen while it
    /// is open, and the turns it was opened for can leave it.
    private var emptySection: some View {
        Section {
            Text(LocalizedStringResource(
                "settings.usage.incidents.none",
                defaultValue: "No failed turns in this range."))
                .foregroundStyle(AppColors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .settingsCardPassiveRow()
        } footer: {
            Text(UsageDetailFormat.rangeCaption(for: model.range))
        }
    }

    private var listSection: some View {
        let all = groups
        let shown = Array(all.prefix(visibleCount))

        return Section {
            Text(verbatim: UsageIncidentList.showingText(shown: shown.count, total: all.count))
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(AppColors.textTertiary)
                .settingsCardPassiveRow()

            ForEach(shown) { group in
                incidentRow(group)
            }

            if shown.count < all.count {
                showMoreRow
            }
        } header: {
            sectionHeader
        } footer: {
            sectionFooter
        }
    }

    /// The reason the push was opened for, so the screen states its own filter
    /// rather than leaving the user to infer it from rows that all look alike.
    @ViewBuilder
    private var sectionHeader: some View {
        if let code = filter.appErrorCode {
            Text(verbatim: UsageFailureReasonCopy.label(forAppErrorCode: code))
        } else {
            Text(LocalizedStringResource(
                "settings.usage.incidents.header", defaultValue: "Failures"))
        }
    }

    private var sectionFooter: some View {
        VStack(alignment: .leading, spacing: 4) {
            if case .slot(let ref) = filter.gateway {
                Text(LocalizedStringResource(
                    "settings.usage.incidents.footer.gateway",
                    defaultValue: """
                        Only turns sent through \
                        \(UsageGatewayLabel.name(for: ref, roster: gatewayRoster)).
                        """))
            }
            Text(UsageDetailFormat.rangeCaption(for: model.range))
        }
    }

    private var showMoreRow: some View {
        Button {
            visibleCount += UsageIncidentList.pageSize
        } label: {
            Text(LocalizedStringResource(
                "settings.usage.incidents.showMore", defaultValue: "Show more"))
                .foregroundStyle(AppColors.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .settingsCardRowButton()
    }

    // MARK: - Row

    /// A live conversation navigates; an absent one says so and does not — the
    /// same nil-tolerance the thread lists use, and the same navigation: opening
    /// a conversation posts the app's own deep link, which closes Settings and
    /// lands on the thread. A `NavigationLink` would push the conversation
    /// INSIDE the settings stack, which is neither where it lives nor where the
    /// user can reply.
    @ViewBuilder
    private func incidentRow(_ group: UsageIncidentGroup) -> some View {
        if let conversation = group.conversationID,
           model.canOpenConversation(conversation) {
            Button {
                model.openConversation(conversation)
            } label: {
                rowContent(group, isOpenable: true)
            }
            .settingsCardRowButton()
            .accessibilityElement(children: .combine)
        } else {
            rowContent(group, isOpenable: false)
                .settingsCardPassiveRow()
                .accessibilityElement(children: .combine)
        }
    }

    private func rowContent(_ group: UsageIncidentGroup, isOpenable: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(verbatim: timestampText(group))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppColors.textPrimary)
                Spacer(minLength: 8)
                if let narrative = UsageIncidentList.retryNarrative(group) {
                    Text(verbatim: narrative)
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(AppColors.textSecondary)
                        .multilineTextAlignment(.trailing)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if isOpenable {
                    Image(systemName: "chevron.forward")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AppColors.textTertiary)
                        .accessibilityHidden(true)
                }
            }

            // The app's OWN sentence for a stable local code — the same
            // `DiagnosticsExplainer` reading the failure-reason rows use, so a
            // reason reads identically here, on the overview and on Diagnostics.
            Text(verbatim: reasonText(group))
                .font(.subheadline)
                .foregroundStyle(AppColors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            Text(verbatim: contextText(group))
                .font(.caption)
                .foregroundStyle(AppColors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            if !isOpenable {
                Text(LocalizedStringResource(
                    "settings.usage.detail.threads.unavailable",
                    defaultValue: "Conversation unavailable"))
                    .font(.caption)
                    .foregroundStyle(AppColors.textTertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    /// DATE AND TIME, unlike the thread rows' date-only span: a reliability
    /// incident is something the user is trying to place in their day, and two
    /// failures an hour apart are a different story from two on the same date.
    private func timestampText(_ group: UsageIncidentGroup) -> String {
        guard let startedAt = group.startedAt else {
            return String(localized: "settings.usage.incidents.undated",
                          defaultValue: "Time not recorded")
        }
        return startedAt.formatted(date: .abbreviated, time: .shortened)
    }

    private func reasonText(_ group: UsageIncidentGroup) -> String {
        guard let code = group.appErrorCode else {
            return String(localized: "settings.usage.incidents.reason.unrecorded",
                          defaultValue: "Reason not recorded")
        }
        return UsageFailureReasonCopy.label(forAppErrorCode: code)
    }

    /// Where it ran: the gateway SLOT's name and the device bucket, both the
    /// app's own words rather than anything the ledger stored about either.
    private func contextText(_ group: UsageIncidentGroup) -> String {
        [
            UsageGatewayLabel.name(for: group.gatewayRef, roster: gatewayRoster),
            UsageDeviceBucketDisplay.label(group.device)
        ].joined(separator: " · ")
    }
}
