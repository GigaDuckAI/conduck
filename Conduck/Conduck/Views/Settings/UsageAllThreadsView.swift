// SPDX-License-Identifier: Apache-2.0

// Conduck
// UsageAllThreadsView.swift
//
// Settings ▸ Usage ▸ every ranked conversation. The overview shows the heaviest
// few; this is the whole ranked list, capped by the aggregator rather than by
// this screen.
//
// THE ROWS NAME NOTHING. No title, no snippet, no first line — a conversation is
// a date span, the gateway it ran on, and what it cost. The title exists only
// where the user already is: tapping a row leaves Settings for the conversation
// itself, and THAT screen is where a name may appear. A ledger read must never
// become a place where conversation content is reconstructed.
//
// "CONVERSATION UNAVAILABLE" IS NOT "DELETED". Usage rows outlive the
// conversation they measured, so a thread with no live conversation may have
// been deleted, may not have imported from another device yet, or may be
// temporarily unreadable. The row says only what is true — that it cannot be
// opened right now — and grows its chevron back on its own if the parent
// arrives later. There are no tombstones.
//
// THE RANKING BASIS IS STATED, ALWAYS. A list ranked by gateway-reported totals
// and a list ranked by summed components are different claims, and threads whose
// gateway reported neither are absent from both. The footer says which one is on
// screen and what is therefore missing from it.

import SwiftUI

struct UsageAllThreadsView: View {
    let model: UsageDashboardModel

    /// Display names for gateway slots, read once when the screen opens.
    @State private var gatewayRoster: [CustomGateway] = []

    private var ranking: ThreadRanking { model.summary.threadRanking }

    private var title: String {
        String(localized: "settings.usage.detail.threads.title",
               defaultValue: "Heaviest conversations")
    }

    var body: some View {
        PlatformSettingsForm {
            if ranking.threads.isEmpty {
                emptySection
            } else {
                threadsSection
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

    private var emptySection: some View {
        Section {
            Text(LocalizedStringResource(
                "settings.usage.detail.threads.none",
                defaultValue: """
                    No conversation in this range can be ranked — your gateway \
                    reported no token usage for any of them.
                    """))
                .foregroundStyle(AppColors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .settingsCardPassiveRow()
        } footer: {
            Text(UsageDetailFormat.rangeCaption(for: model.range))
        }
    }

    private var threadsSection: some View {
        Section {
            ForEach(ranking.threads, id: \.conversationID) { thread in
                UsageThreadRow(thread: thread, model: model, roster: gatewayRoster)
            }
        } header: {
            Text(LocalizedStringResource(
                "settings.usage.detail.threads.header", defaultValue: "Conversations"))
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text(UsageDetailFormat.threadBasisFooter(ranking.basis))
                Text(UsageDetailFormat.rangeCaption(for: model.range))
            }
        }
    }
}

// MARK: - Thread row

/// ONE ranked conversation, content-free. Shared with the overview's shortened
/// list so the two can never describe the same thread two different ways.
///
/// Navigation is an ACTION, not a link: opening a conversation posts the
/// app's own deep link, which closes Settings and lands on the thread. A
/// `NavigationLink` would have to push the conversation INSIDE the settings
/// stack, which is neither where it lives nor where the user can reply.
struct UsageThreadRow: View {
    let thread: ThreadUsage
    let model: UsageDashboardModel
    let roster: [CustomGateway]

    private var isOpenable: Bool {
        model.liveConversationIDs.contains(thread.conversationID)
    }

    var body: some View {
        Group {
            if isOpenable {
                Button {
                    model.openConversation(thread.conversationID)
                } label: {
                    content(chevron: true)
                }
                .settingsCardRowButton()
            } else {
                content(chevron: false)
                    .settingsCardPassiveRow()
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func content(chevron: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(verbatim: UsageThreadFormat.dateSpan(
                    from: thread.earliestStart, to: thread.latestStart))
                    .font(.body.weight(.semibold))
                    .foregroundStyle(AppColors.textPrimary)
                Spacer(minLength: 8)
                Text(verbatim: UsageThreadFormat.tokensText(thread.rankedTokens))
                    .monospacedDigit()
                    .foregroundStyle(AppColors.textSecondary)
                if chevron {
                    Image(systemName: "chevron.forward")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AppColors.textTertiary)
                        .accessibilityHidden(true)
                }
            }

            Text(verbatim: UsageThreadFormat.gatewaysText(thread.gatewayRefs, roster: roster))
                .font(.caption)
                .foregroundStyle(AppColors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            Text(verbatim: UsageThreadFormat.detailText(thread))
                .font(.caption)
                .monospacedDigit()
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
}

// MARK: - Turn row

/// ONE heavy turn inside a gateway drill-down. Same content-free contract as a
/// thread row, and the same navigation: it opens the CONVERSATION, because a
/// single turn is not a destination the app has.
struct UsageTurnRow: View {
    let turn: TurnOutlier
    let model: UsageDashboardModel

    private var isOpenable: Bool {
        model.liveConversationIDs.contains(turn.conversationID)
    }

    var body: some View {
        Group {
            if isOpenable {
                Button {
                    model.openConversation(turn.conversationID)
                } label: {
                    content(chevron: true)
                }
                .settingsCardRowButton()
            } else {
                content(chevron: false)
                    .settingsCardPassiveRow()
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func content(chevron: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(verbatim: turn.startedAt.formatted(date: .abbreviated, time: .shortened))
                    .foregroundStyle(AppColors.textPrimary)
                Spacer(minLength: 8)
                Text(verbatim: UsageThreadFormat.tokensText(turn.tokens))
                    .monospacedDigit()
                    .foregroundStyle(AppColors.textSecondary)
                if chevron {
                    Image(systemName: "chevron.forward")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AppColors.textTertiary)
                        .accessibilityHidden(true)
                }
            }
            if let carried = UsageThreadFormat.carriedText(
                images: turn.inlineImageCount, files: turn.inlineTextFileCount) {
                Text(verbatim: carried)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(AppColors.textTertiary)
            }
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
}

// MARK: - Row formatting

/// The strings a ranked row is made of. Every one of them is a NUMBER or a
/// DATE, or a gateway slot's name resolved at render time — never anything the
/// ledger stored about what was said.
enum UsageThreadFormat {
    /// A span, collapsed to one date when a conversation lived inside a single
    /// day. Two identical dates joined by a dash reads as a bug.
    static func dateSpan(from first: Date, to last: Date) -> String {
        let firstText = first.formatted(date: .abbreviated, time: .omitted)
        guard !Calendar.current.isDate(first, inSameDayAs: last) else { return firstText }
        return String(
            localized: "settings.usage.detail.threads.span",
            defaultValue: "\(firstText) – \(last.formatted(date: .abbreviated, time: .omitted))")
    }

    static func tokensText(_ tokens: Int) -> String {
        String(localized: "settings.usage.detail.threads.tokens",
               defaultValue: "\(tokens.formatted(.number)) tokens")
    }

    /// Every distinct slot the thread ran on, in the order it first used them —
    /// a conversation is bound to one gateway, but a clone-and-switch shows up
    /// here as two, and hiding that would make the row's numbers unattributable.
    static func gatewaysText(_ refs: [String?], roster: [CustomGateway]) -> String {
        let names = refs.map { UsageGatewayLabel.name(for: $0, roster: roster) }
        guard !names.isEmpty else {
            return String(localized: "settings.usage.gateway.unattributed",
                          defaultValue: "Not recorded")
        }
        return names.joined(separator: " · ")
    }

    /// Attempts · token coverage · what the turns carried. Coverage is stated
    /// whenever it is partial: a thread ranked on two reported turns out of
    /// twenty is ranked on a fraction of itself, and the row has to say so.
    static func detailText(_ thread: ThreadUsage) -> String {
        var parts: [String] = [UsageDetailFormat.attemptsText(thread.attempts)]
        parts.append(String(
            localized: "settings.usage.detail.threads.coverage",
            defaultValue: "\(thread.tokenReportedTurns) of \(thread.turns) turns reported"))
        if let carried = carriedText(
            images: thread.inlineImageCount, files: thread.inlineTextFileCount) {
            parts.append(carried)
        }
        if thread.attachmentMeasuredAttempts > 0,
           thread.attachmentMeasuredAttempts < thread.attempts {
            parts.append(String(
                localized: "settings.usage.detail.threads.measured",
                defaultValue: "measured on \(thread.attachmentMeasuredAttempts)"))
        }
        return parts.joined(separator: " · ")
    }

    /// Images and files, omitted entirely when nothing measured them. A zero
    /// here would claim the turns carried nothing, which is a different fact
    /// from nobody having counted.
    static func carriedText(images: Int?, files: Int?) -> String? {
        var parts: [String] = []
        if let images, images > 0 {
            parts.append(String(
                localized: "settings.usage.detail.threads.images",
                defaultValue: "\(images) images"))
        }
        if let files, files > 0 {
            parts.append(String(
                localized: "settings.usage.detail.threads.files",
                defaultValue: "\(files) files"))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
