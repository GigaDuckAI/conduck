// SPDX-License-Identifier: Apache-2.0

// Conduck
// WorkboardBriefingView.swift
//
// A deterministic, private morning/return briefing. Counts and spoken text are
// frozen together by `WorkboardBriefingBuilder`; this view adds no generative
// summary and cannot infer that work is complete. It points the person directly
// at results, waiting runs and the next few prepared drafts.

import SwiftUI

struct WorkboardBriefingView: View {
    @Bindable var viewModel: WorkboardViewModel
    let briefing: WorkboardBriefingSnapshot
    let onOpenItem: (WorkboardItemSnapshot) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: WorkboardMetrics.generousSpacing) {
                    header

                    if briefing.isEmpty {
                        clearState
                    } else {
                        summary
                        briefingGroup(state: .review, items: briefing.needsYou)
                        briefingGroup(state: .waiting, items: briefing.waiting)
                        briefingGroup(state: .draft, items: briefing.drafts)
                    }

                    Label(
                        LocalizedStringResource(
                            "workboard.briefing.private",
                            defaultValue: "Built on device from your private board. No analytics and no AI-generated claims."
                        ),
                        systemImage: "lock.shield.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(AppColors.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 22)
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity)
            }
            .background(AppColors.background.ignoresSafeArea())
            .navigationTitle(LocalizedStringResource(
                "workboard.briefing.title",
                defaultValue: "Brief Me"
            ))
            .workboardInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(LocalizedStringResource("common.done", defaultValue: "Done")) {
                        if viewModel.isReadingBriefing {
                            Task { await viewModel.toggleBriefingSpeech() }
                        }
                        viewModel.briefing = nil
                        dismiss()
                    }
                    .keyboardShortcut(.cancelAction)
                }
                if viewModel.canReadBriefing {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            Task { await viewModel.toggleBriefingSpeech() }
                        } label: {
                            Label(
                                viewModel.isReadingBriefing
                                    ? LocalizedStringResource("workboard.briefing.stopReading", defaultValue: "Stop Reading")
                                    : LocalizedStringResource("workboard.briefing.readAloud", defaultValue: "Read Aloud"),
                                systemImage: viewModel.isReadingBriefing ? "stop.fill" : "speaker.wave.2.fill"
                            )
                        }
                    }
                }
            }
        }
        .workboardDesktopSheetFrame(minWidth: 400, minHeight: 520)
        .onDisappear {
            Task { @MainActor in
                guard viewModel.isReadingBriefing else { return }
                await viewModel.toggleBriefingSpeech()
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            ZStack {
                Circle()
                    .fill(AppColors.brandAmber.opacity(0.13))
                Image(systemName: "sun.max.fill")
                    .font(.system(size: 28, weight: .medium))
                    .foregroundStyle(AppColors.brandAmber)
            }
            .frame(width: 66, height: 66)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(LocalizedStringResource(
                    "workboard.briefing.heading",
                    defaultValue: "Here’s where your work stands"
                ))
                .font(.title2.weight(.bold))
                .foregroundStyle(AppColors.textEmphasis)
                .accessibilityAddTraits(.isHeader)
                Text(briefing.generatedAt, format: .dateTime.weekday(.wide).month(.wide).day().hour().minute())
                    .font(.caption)
                    .foregroundStyle(AppColors.textTertiary)
            }
        }
    }

    private var summary: some View {
        WorkboardSurface {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "quote.opening")
                    .foregroundStyle(AppColors.brandTeal)
                Text(verbatim: briefing.spokenText)
                    .font(.headline)
                    .foregroundStyle(AppColors.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var clearState: some View {
        WorkboardEmptyState(
            title: LocalizedStringResource(
                "workboard.briefing.clear.title",
                defaultValue: "Your Workboard is clear"
            ),
            message: LocalizedStringResource(
                "workboard.briefing.clear.message",
                defaultValue: "There are no drafts, waiting runs or results asking for review right now."
            ),
            actionTitle: LocalizedStringResource(
                "workboard.newBrief",
                defaultValue: "New Work"
            )
        ) {
            viewModel.briefing = nil
            dismiss()
            viewModel.beginWorkspace()
        }
    }

    @ViewBuilder
    private func briefingGroup(
        state: WorkItemState,
        items: [WorkboardItemSnapshot]
    ) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 11) {
                WorkboardSectionHeader(state: state, count: items.count)
                ForEach(items) { item in
                    Button {
                        viewModel.briefing = nil
                        dismiss()
                        onOpenItem(item)
                    } label: {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: item.latestRun?.state.systemImage ?? state.systemImage)
                                .font(.body.weight(.semibold))
                                .foregroundStyle(state.tint)
                                .frame(width: 24)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(verbatim: item.displayTitle)
                                    .font(.headline)
                                    .foregroundStyle(AppColors.textPrimary)
                                    .multilineTextAlignment(.leading)
                                Text(item.objective)
                                    .font(.subheadline)
                                    .foregroundStyle(AppColors.textSecondary)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.leading)
                                if let reviewBy = item.reviewBy, state != .done {
                                    Label {
                                        Text(reviewBy, format: .relative(presentation: .named))
                                    } icon: {
                                        Image(systemName: "calendar")
                                    }
                                    .font(.caption)
                                    .foregroundStyle(reviewBy < Date() ? AppColors.error : AppColors.textTertiary)
                                }
                            }
                            Spacer(minLength: 10)
                            Image(systemName: "chevron.forward")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(AppColors.textTertiary)
                                .accessibilityHidden(true)
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
                        .background(AppColors.cardBackground, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(state.tint.opacity(0.25), lineWidth: 1)
                        }
                        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .choiceCardButton(cornerRadius: 14)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text(String.localizedStringWithFormat(
                        String(localized: LocalizedStringResource(
                            "workboard.briefing.item.accessibility",
                            defaultValue: "%1$@. %2$@. %3$@"
                        )),
                        String(localized: state.title),
                        item.displayTitle,
                        item.objective
                    )))
                    .accessibilityHint(Text(LocalizedStringResource(
                        "workboard.briefing.item.hint",
                        defaultValue: "Opens this brief."
                    )))
                }
            }
        }
    }
}
