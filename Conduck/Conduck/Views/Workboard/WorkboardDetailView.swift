// SPDX-License-Identifier: Apache-2.0

// Conduck
// WorkboardDetailView.swift
//
// Result-first Workboard detail. Replies and failures appear before the original
// brief, followed by human review actions and an immutable run timeline. A
// transport result can request attention but only the person can mark the
// objective Done.

import SwiftUI
import Textual

struct WorkboardDetailView: View {
    @Bindable var viewModel: WorkboardViewModel
    let itemID: UUID
    /// Parent-owned scratch identity survives detail reconstruction and section
    /// switches, so a half-written Done -> New Work thought never gets stranded.
    let newWorkspaceID: UUID

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.workbenchDestinationIsActive) private var workbenchDestinationIsActive

    var body: some View {
        Group {
            if let item = viewModel.item(withID: itemID) {
                let captureItem = item.state == .done
                    ? WorkboardItemSnapshot(id: newWorkspaceID)
                    : item
                let captureDestination: WorkboardCaptureDestination = item.state == .done
                    ? .newWork
                    : .existingWork(item.displayTitle)

                ScrollView {
                    VStack(alignment: .leading, spacing: WorkboardMetrics.generousSpacing) {
                        if horizontalSizeClass != .compact {
                            WorkboardRecentWorkStrip(
                                viewModel: viewModel,
                                selectedItemID: item.id
                            )
                        }
                        header(item)
                        if item.hasChangesSinceLastSend {
                            divergenceBanner
                        }
                        if let result = reviewResult(item) {
                            resultCard(result, item: item)
                        }
                        if item.state == .done {
                            completedCaptureLock(item)
                        } else {
                            WorkboardCaptureCanvas(
                                viewModel: viewModel,
                                item: item,
                                mode: .sources
                            )
                        }
                        actionDeck(item)
                        briefDocument(item)
                        if !item.runs.isEmpty {
                            runTimeline(item)
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 22)
                    .frame(maxWidth: WorkboardMetrics.contentMaxWidth)
                    .frame(maxWidth: .infinity)
                }
                .scrollDismissesKeyboard(.interactively)
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    WorkboardCaptureCanvas(
                        viewModel: viewModel,
                        item: captureItem,
                        mode: .composer,
                        destination: captureDestination
                    )
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial)
                }
                .workboardPaneDropDestination(
                    viewModel: viewModel,
                    itemID: captureItem.id,
                    destination: captureDestination
                )
                .background(AppColors.background.ignoresSafeArea())
                .workbenchNavigationTitle(
                    Text(verbatim: item.displayTitle),
                    isActive: workbenchDestinationIsActive
                )
                .workboardInlineNavigationTitle()
            } else {
                WorkboardEmptyState(
                    title: LocalizedStringResource(
                        "workboard.item.missing.title",
                        defaultValue: "This brief is no longer here"
                    ),
                    message: LocalizedStringResource(
                        "workboard.item.missing.message",
                        defaultValue: "It may have been deleted on another device."
                    )
                )
                .background(AppColors.background.ignoresSafeArea())
            }
        }
    }

    private func completedCaptureLock(_ item: WorkboardItemSnapshot) -> some View {
        WorkboardSurface {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 14) {
                    completedLockCopy
                    Spacer(minLength: 12)
                    reopenButton(item)
                }

                VStack(alignment: .leading, spacing: 14) {
                    completedLockCopy
                    reopenButton(item)
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }

    private var completedLockCopy: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "checkmark.seal.fill")
                .font(.title2)
                .foregroundStyle(AppColors.brandTeal)
            VStack(alignment: .leading, spacing: 4) {
                Text(LocalizedStringResource(
                    "workboard.done.locked.title",
                    defaultValue: "This work is complete"
                ))
                .font(.headline)
                .foregroundStyle(AppColors.textEmphasis)
                .accessibilityAddTraits(.isHeader)
                Text(LocalizedStringResource(
                    "workboard.done.locked.message",
                    defaultValue: "Reopen it before adding thoughts or materials so completed work never changes silently."
                ))
                .font(.subheadline)
                .foregroundStyle(AppColors.textSecondary)
            }
        }
    }

    private func reopenButton(_ item: WorkboardItemSnapshot) -> some View {
        Button {
            Task { await viewModel.transition(item, to: .draft) }
        } label: {
            Label(
                LocalizedStringResource("workboard.action.reopen", defaultValue: "Reopen"),
                systemImage: "arrow.uturn.backward.circle"
            )
            .frame(maxWidth: .infinity, minHeight: WorkboardMetrics.touchTarget)
        }
        .primaryCTAButton()
    }

    private func header(_ item: WorkboardItemSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 9) {
                    horizontalStatusLabels(item)
                    Spacer(minLength: 8)
                    modifiedLabel(item)
                    projectMenu(item)
                }

                VStack(alignment: .leading, spacing: 8) {
                    WorkboardStateBadge(state: item.state)
                    if item.wasCapturedExternally { capturedLabel }
                    if item.isPinned { pinnedLabel }
                    HStack(spacing: 8) {
                        modifiedLabel(item)
                        projectMenu(item)
                    }
                }
            }

            Text(verbatim: item.displayTitle)
                .font(.largeTitle.weight(.bold))
                .foregroundStyle(AppColors.textEmphasis)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)

            Text(item.objective)
                .font(.title3)
                .foregroundStyle(AppColors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func horizontalStatusLabels(_ item: WorkboardItemSnapshot) -> some View {
        WorkboardStateBadge(state: item.state)
        if item.wasCapturedExternally { capturedLabel }
        if item.isPinned { pinnedLabel }
    }

    private var capturedLabel: some View {
        Label(
            LocalizedStringResource("workboard.workspace.captured", defaultValue: "Captured"),
            systemImage: "square.and.arrow.down"
        )
        .font(.caption.weight(.semibold))
        .foregroundStyle(AppColors.brandTeal)
    }

    private var pinnedLabel: some View {
        Label(
            LocalizedStringResource("workboard.item.pinned", defaultValue: "Pinned"),
            systemImage: "pin.fill"
        )
        .font(.caption.weight(.semibold))
        .foregroundStyle(AppColors.brandAmber)
    }

    private func modifiedLabel(_ item: WorkboardItemSnapshot) -> some View {
        Text(item.modifiedAt, format: .relative(presentation: .named))
            .font(.caption)
            .foregroundStyle(AppColors.textTertiary)
    }

    private func projectMenu(_ item: WorkboardItemSnapshot) -> some View {
        Menu {
            if item.state != .done {
                Button {
                    viewModel.showEditor(for: item)
                } label: {
                    Label(
                        LocalizedStringResource("common.edit", defaultValue: "Edit"),
                        systemImage: "square.and.pencil"
                    )
                }
                Divider()
            }
            Button {
                viewModel.requestDuplicate(item)
            } label: {
                Label(
                    LocalizedStringResource("workboard.action.duplicate", defaultValue: "Duplicate Work"),
                    systemImage: "plus.square.on.square"
                )
            }
            Divider()
            Button(role: .destructive) {
                viewModel.requestDelete(item)
            } label: {
                Label(
                    LocalizedStringResource("workboard.action.delete", defaultValue: "Delete Work"),
                    systemImage: "trash"
                )
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.body.weight(.semibold))
                .foregroundStyle(AppColors.textSecondary)
                .frame(width: WorkboardMetrics.touchTarget, height: WorkboardMetrics.touchTarget)
                .contentShape(Circle())
        }
        .pointerIconButton(size: WorkboardMetrics.touchTarget, shape: .circle)
        .help(String(localized: LocalizedStringResource(
            "workboard.project.more.help",
            defaultValue: "More project actions"
        )))
        .accessibilityLabel(Text(LocalizedStringResource(
            "workboard.project.more",
            defaultValue: "More project actions"
        )))
    }

    private var divergenceBanner: some View {
        WorkboardSurface {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.title3)
                    .foregroundStyle(AppColors.warning)
                VStack(alignment: .leading, spacing: 4) {
                    Text(LocalizedStringResource(
                        "workboard.detail.divergence.title",
                        defaultValue: "This brief has a newer version"
                    ))
                    .font(.headline)
                    .foregroundStyle(AppColors.textPrimary)
                    Text(LocalizedStringResource(
                        "workboard.detail.divergence.message",
                        defaultValue: "The run timeline preserves exactly what was sent. Editing this brief only changes the next run."
                    ))
                    .font(.subheadline)
                    .foregroundStyle(AppColors.textSecondary)
                }
            }
        }
    }

    private func resultCard(_ run: WorkboardRunSnapshot, item: WorkboardItemSnapshot) -> some View {
        WorkboardSurface {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(resultTint(run.state).opacity(0.14))
                        Image(systemName: run.state.systemImage)
                            .foregroundStyle(resultTint(run.state))
                    }
                    .frame(width: 42, height: 42)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(run.state == .failed
                            ? LocalizedStringResource("workboard.detail.failure.title", defaultValue: "This run needs attention")
                            : LocalizedStringResource("workboard.detail.result.title", defaultValue: "Result ready for review"))
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(AppColors.textEmphasis)
                            .accessibilityAddTraits(.isHeader)
                        Text(String.localizedStringWithFormat(
                            String(localized: LocalizedStringResource(
                                "workboard.detail.result.from",
                                defaultValue: "From %@"
                            )),
                            run.gatewayName
                        ))
                        .font(.caption)
                        .foregroundStyle(AppColors.textTertiary)
                    }
                    Spacer(minLength: 8)
                    if let finishedAt = run.finishedAt {
                        Text(finishedAt, format: .relative(presentation: .named))
                            .font(.caption)
                            .foregroundStyle(AppColors.textTertiary)
                    }
                }

                Divider().overlay(AppColors.borderSubtle)

                if let markdown = run.resultMarkdown, !markdown.isEmpty {
                    // `.equatable()` is what makes the conformance load-bearing:
                    // an unrelated detail-body invalidation then cannot re-parse
                    // the reply or re-touch Textual's selection layer mid-drag.
                    // Mirrors Chat's `AgentMarkdownBody`.
                    WorkboardMarkdownBody(text: markdown)
                        .equatable()
                } else if let failure = run.failureMessage, !failure.isEmpty {
                    Text(verbatim: failure)
                        .font(.body)
                        .foregroundStyle(AppColors.textPrimary)
                        .textSelection(.enabled)
                } else {
                    Text(LocalizedStringResource(
                        "workboard.detail.result.syncing",
                        defaultValue: "The result is still syncing to this device."
                    ))
                    .font(.subheadline)
                    .foregroundStyle(AppColors.textTertiary)
                }

                if !run.resultAttachments.isEmpty {
                    Divider().overlay(AppColors.borderSubtle)
                    VStack(alignment: .leading, spacing: 8) {
                        Text(LocalizedStringResource(
                            "workboard.detail.result.outputs",
                            defaultValue: "Outputs"
                        ))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AppColors.textSecondary)

                        ForEach(run.resultAttachments) { attachment in
                            Button {
                                guard let conversationID = run.conversationID else { return }
                                viewModel.openConversation(
                                    for: itemWithRun(item, conversationID: conversationID)
                                )
                            } label: {
                                HStack(spacing: 10) {
                                    // `AttachmentChipStyle` maps text and code
                                    // types only, so an image routed through it
                                    // would come back as a document.
                                    Image(systemName: attachment.isImage
                                        ? "photo"
                                        : AttachmentChipStyle.symbol(
                                            forMimeType: attachment.mimeType,
                                            filename: attachment.filename
                                        ))
                                        .foregroundStyle(AppColors.brandTeal)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(verbatim: attachment.filename ?? String(
                                            localized: "workboard.detail.result.output",
                                            defaultValue: "Generated output"
                                        ))
                                        .font(.subheadline.weight(.medium))
                                        .foregroundStyle(AppColors.textPrimary)
                                        if attachment.byteSize > 0 {
                                            Text(ByteCountFormatter.string(
                                                fromByteCount: Int64(attachment.byteSize),
                                                countStyle: .file
                                            ))
                                            .font(.caption)
                                            .foregroundStyle(AppColors.textTertiary)
                                        }
                                    }
                                    Spacer(minLength: 8)
                                    Image(systemName: "arrow.up.right")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(AppColors.textTertiary)
                                }
                                .padding(10)
                                .background(AppColors.backgroundSecondary, in: RoundedRectangle(cornerRadius: 10))
                            }
                            .choiceCardButton(cornerRadius: 10)
                            .disabled(run.conversationID == nil)
                            .accessibilityHint(LocalizedStringResource(
                                "workboard.detail.result.output.hint",
                                defaultValue: "Opens this output in its conversation"
                            ))
                        }
                    }
                }
            }
        }
        .overlay(alignment: .leading) {
            Capsule()
                .fill(resultTint(run.state))
                .frame(width: 4)
                .padding(.vertical, 13)
        }
    }

    private func actionDeck(_ item: WorkboardItemSnapshot) -> some View {
        WorkboardSurface {
            VStack(alignment: .leading, spacing: 12) {
                Text(actionHeading(item.state))
                    .font(.headline)
                    .foregroundStyle(AppColors.textPrimary)
                    .accessibilityAddTraits(.isHeader)

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) { actionButtons(item) }
                    VStack(spacing: 10) { actionButtons(item) }
                }

                if item.state == .draft, !canReviewAndSend(item) {
                    Label(
                        LocalizedStringResource(
                            "workboard.detail.review.requirement",
                            defaultValue: "Add a thought that explains what you want the AI to do."
                        ),
                        systemImage: "text.bubble"
                    )
                    .font(.caption)
                    .foregroundStyle(AppColors.textTertiary)
                }
            }
        }
    }

    @ViewBuilder
    private func actionButtons(_ item: WorkboardItemSnapshot) -> some View {
        switch item.state {
        case .draft:
            detailAction(
                LocalizedStringResource("workboard.editor.reviewAndSend", defaultValue: "Review & Send…"),
                systemImage: "checkmark.shield",
                primary: true
            ) {
                Task { await viewModel.reviewWorkspaceAndSend(itemID: item.id) }
            }
            .disabled(!workbenchDestinationIsActive || !canReviewAndSend(item))
            .keyboardShortcut(.return, modifiers: [.command, .shift])
            detailAction(
                LocalizedStringResource("common.edit", defaultValue: "Edit"),
                systemImage: "square.and.pencil"
            ) {
                viewModel.showEditor(for: item)
            }
            .disabled(!workbenchDestinationIsActive)
            .keyboardShortcut("e", modifiers: .command)

        case .waiting:
            if item.latestRun?.conversationID != nil {
                detailAction(
                    LocalizedStringResource("workboard.action.openConversation", defaultValue: "Open Conversation"),
                    systemImage: "bubble.left.and.bubble.right",
                    primary: true
                ) {
                    viewModel.openConversation(for: item)
                }
            }
            detailAction(
                LocalizedStringResource("workboard.action.editNextVersion", defaultValue: "Edit Next Version"),
                systemImage: "square.and.pencil"
            ) {
                viewModel.showEditor(for: item)
            }

        case .review:
            if let reviewRun = reviewResult(item) {
                if reviewRun.state == .replied {
                    detailAction(
                        LocalizedStringResource("workboard.action.markDone", defaultValue: "Mark Done"),
                        systemImage: "checkmark.circle.fill",
                        primary: true
                    ) {
                        Task { await viewModel.completeWorkspace(itemID: item.id) }
                    }
                } else {
                    detailAction(
                        LocalizedStringResource("workboard.action.sendAgain", defaultValue: "Send Again"),
                        systemImage: "paperplane.fill",
                        primary: true
                    ) {
                        Task { await viewModel.reviewWorkspaceAndSend(itemID: item.id) }
                    }
                }
                if reviewRun.canAcknowledgeReview {
                    detailAction(
                        LocalizedStringResource("workboard.action.keepWorking", defaultValue: "Keep Working"),
                        systemImage: "arrow.uturn.backward.circle"
                    ) {
                        Task { await viewModel.acknowledge(reviewRun, in: item) }
                    }
                }
            }
            if reviewResult(item)?.conversationID != nil {
                detailAction(
                    LocalizedStringResource("workboard.action.openConversation", defaultValue: "Open Conversation"),
                    systemImage: "bubble.left.and.bubble.right"
                ) {
                    if let run = reviewResult(item), let conversationID = run.conversationID {
                        viewModel.openConversation(for: itemWithRun(item, conversationID: conversationID))
                    }
                }
            }

        case .done:
            if item.latestRun?.conversationID != nil {
                detailAction(
                    LocalizedStringResource("workboard.action.openConversation", defaultValue: "Open Conversation"),
                    systemImage: "bubble.left.and.bubble.right",
                    primary: true
                ) {
                    viewModel.openConversation(for: item)
                }
            }
        }
    }

    /// Reads the coarse per-project flag rather than the composer text itself:
    /// this runs in the detail body, and observing the draft dictionary would
    /// re-parse the result markdown and rebuild the run timeline on every
    /// keystroke in the pinned composer.
    private func canReviewAndSend(_ item: WorkboardItemSnapshot) -> Bool {
        item.isReadyToSend || viewModel.hasComposerDraft(for: item.id)
    }

    private func detailAction(
        _ title: LocalizedStringResource,
        systemImage: String,
        primary: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(primary ? AppColors.background : AppColors.textPrimary)
                .padding(.horizontal, 15)
                .frame(maxWidth: .infinity, minHeight: WorkboardMetrics.touchTarget)
                .background(
                    primary ? AppColors.brandAmber : AppColors.backgroundSecondary,
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                )
                .overlay {
                    if !primary {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(AppColors.borderSubtle, lineWidth: 1)
                    }
                }
                .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .modifier(WorkboardActionButtonModifier(primary: primary))
    }

    private func briefDocument(_ item: WorkboardItemSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(LocalizedStringResource(
                "workboard.detail.brief.title",
                defaultValue: "Current Brief"
            ))
            .font(.title3.weight(.semibold))
            .foregroundStyle(AppColors.textEmphasis)
            .accessibilityAddTraits(.isHeader)

            WorkboardSurface {
                VStack(alignment: .leading, spacing: 18) {
                    documentSection(
                        LocalizedStringResource("workboard.editor.objective.title", defaultValue: "What needs doing?"),
                        value: item.objective
                    )
                    if !item.context.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Divider().overlay(AppColors.borderSubtle)
                        documentSection(
                            LocalizedStringResource("workboard.editor.context.title", defaultValue: "Context and thoughts"),
                            value: item.context
                        )
                    }
                    if !item.desiredResult.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Divider().overlay(AppColors.borderSubtle)
                        documentSection(
                            LocalizedStringResource("workboard.editor.desiredResult.title", defaultValue: "A good result includes"),
                            value: item.desiredResult
                        )
                    }
                    if !item.constraints.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Divider().overlay(AppColors.borderSubtle)
                        documentSection(
                            LocalizedStringResource("workboard.editor.constraints.title", defaultValue: "Constraints and guardrails"),
                            value: item.constraints
                        )
                    }
                    if let reviewBy = item.reviewBy {
                        Divider().overlay(AppColors.borderSubtle)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(LocalizedStringResource(
                                "workboard.editor.reviewBy.date",
                                defaultValue: "Review by"
                            ))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(AppColors.brandAmber)
                            Label {
                                Text(reviewBy, format: .dateTime.weekday(.wide).month(.wide).day().hour().minute())
                            } icon: {
                                Image(systemName: "calendar")
                            }
                            .font(.body)
                            .foregroundStyle(reviewBy < Date() && item.state != .done ? AppColors.error : AppColors.textPrimary)
                        }
                    }
                }
            }
        }
    }

    private func documentSection(_ title: LocalizedStringResource, value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppColors.brandAmber)
            Text(verbatim: value)
                .font(.body)
                .foregroundStyle(AppColors.textPrimary)
                .textSelection(.enabled)
        }
    }

    private func runTimeline(_ item: WorkboardItemSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(LocalizedStringResource(
                "workboard.detail.timeline.title",
                defaultValue: "Run Timeline"
            ))
            .font(.title3.weight(.semibold))
            .foregroundStyle(AppColors.textEmphasis)
            .accessibilityAddTraits(.isHeader)

            VStack(spacing: 0) {
                ForEach(Array(item.runs.sorted { $0.startedAt > $1.startedAt }.enumerated()), id: \.element.id) { index, run in
                    WorkboardRunTimelineRow(
                        run: run,
                        customGateways: viewModel.customGateways,
                        isLast: index == item.runs.count - 1,
                        onOpenConversation: run.conversationID.map { conversationID in
                            { viewModel.openConversation(for: itemWithRun(item, conversationID: conversationID)) }
                        }
                    )
                }
            }
        }
    }

    private func itemWithRun(_ item: WorkboardItemSnapshot, conversationID: UUID) -> WorkboardItemSnapshot {
        // The view model's public open action follows `latestRun`; timeline rows
        // need their own historical conversation. Build a transient presentation
        // copy with that run latest without touching persistence.
        var copy = item
        if let run = item.runs.first(where: { $0.conversationID == conversationID }) {
            copy.runs = [run]
        }
        return copy
    }

    private func reviewResult(_ item: WorkboardItemSnapshot) -> WorkboardRunSnapshot? {
        let terminal = item.runs.filter {
            $0.state == .replied || $0.state == .failed || $0.state == .cancelled
        }
        let candidates = terminal.contains(where: \.needsReview)
            ? terminal.filter(\.needsReview)
            : terminal
        return candidates.max {
            ($0.finishedAt ?? $0.startedAt, $0.id.uuidString)
                < ($1.finishedAt ?? $1.startedAt, $1.id.uuidString)
        }
    }

    private func resultTint(_ state: WorkboardRunState) -> Color {
        state == .failed || state == .cancelled ? AppColors.error : AppColors.brandTeal
    }

    private func actionHeading(_ state: WorkItemState) -> LocalizedStringResource {
        switch state {
        case .draft:
            return LocalizedStringResource("workboard.detail.action.draft", defaultValue: "Ready when you are")
        case .waiting:
            return LocalizedStringResource("workboard.detail.action.waiting", defaultValue: "This run is still in progress")
        case .review:
            return LocalizedStringResource("workboard.detail.action.review", defaultValue: "You decide what happens next")
        case .done:
            return LocalizedStringResource("workboard.detail.action.done", defaultValue: "Closed by you")
        }
    }
}

private struct WorkboardRecentWorkStrip: View {
    @Bindable var viewModel: WorkboardViewModel
    let selectedItemID: UUID

    private var visibleItems: [WorkboardItemSnapshot] {
        let selected = viewModel.item(withID: selectedItemID)
        let candidates = viewModel.items
            .filter { $0.state != .done && $0.id != selectedItemID }
            .sorted { lhs, rhs in
                if lhs.isPinned != rhs.isPinned { return lhs.isPinned }
                if lhs.modifiedAt != rhs.modifiedAt { return lhs.modifiedAt > rhs.modifiedAt }
                return lhs.id.uuidString < rhs.id.uuidString
            }
        return ([selected].compactMap { $0 } + Array(candidates.prefix(4)))
    }

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(visibleItems) { item in
                    Button {
                        viewModel.selectedItemID = item.id
                    } label: {
                        HStack(spacing: 7) {
                            Circle()
                                .fill(item.state.tint)
                                .frame(width: 7, height: 7)
                            Text(verbatim: item.displayTitle)
                                .lineLimit(1)
                            if item.isPinned {
                                Image(systemName: "pin.fill")
                                    .font(.caption2)
                            }
                        }
                        .font(.subheadline.weight(item.id == selectedItemID ? .semibold : .medium))
                        .foregroundStyle(item.id == selectedItemID ? AppColors.background : AppColors.textPrimary)
                        .padding(.horizontal, 13)
                        .frame(minHeight: WorkboardMetrics.touchTarget)
                        .background(
                            item.id == selectedItemID ? AppColors.textPrimary : AppColors.cardBackground,
                            in: Capsule()
                        )
                        .overlay { Capsule().stroke(AppColors.borderSubtle, lineWidth: 1) }
                        .contentShape(Capsule())
                    }
                    .choiceCardButton(cornerRadius: WorkboardMetrics.touchTarget / 2)
                    .accessibilityLabel(Text(verbatim: item.displayTitle))
                    .accessibilityValue(Text(item.state.title))
                    .accessibilityAddTraits(item.id == selectedItemID ? .isSelected : [])
                }

                Button {
                    viewModel.beginWorkspace()
                } label: {
                    Label(
                        LocalizedStringResource(
                            "workboard.newBrief",
                            defaultValue: "New Work"
                        ),
                        systemImage: "plus"
                    )
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 13)
                    .frame(minHeight: WorkboardMetrics.touchTarget)
                    .background(AppColors.backgroundSecondary, in: Capsule())
                    .overlay { Capsule().stroke(AppColors.borderSubtle, lineWidth: 1) }
                }
                .choiceCardButton(cornerRadius: WorkboardMetrics.touchTarget / 2)
            }
        }
        .scrollIndicators(.hidden)
        .accessibilityLabel(Text(LocalizedStringResource(
            "workboard.workspace.recent",
            defaultValue: "Recent open work"
        )))
    }
}

private struct WorkboardActionButtonModifier: ViewModifier {
    let primary: Bool

    func body(content: Content) -> some View {
        if primary {
            content.primaryCTAButton()
        } else {
            content.choiceCardButton(cornerRadius: 12)
        }
    }
}

private struct WorkboardMarkdownBody: View, Equatable {
    let text: String

    var body: some View {
        StructuredText(markdown: text)
            .foregroundStyle(AppColors.textPrimary)
            .appliesUntrustedMarkdownPolicy()
            .textual.textSelection(.enabled)
    }
}

private struct WorkboardRunTimelineRow: View {
    let run: WorkboardRunSnapshot
    let customGateways: [CustomGateway]
    let isLast: Bool
    let onOpenConversation: (() -> Void)?

    @State private var showsSentVersion = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 0) {
                ZStack {
                    Circle()
                        .fill(tint.opacity(0.16))
                    Image(systemName: run.state.systemImage)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(tint)
                }
                .frame(width: 32, height: 32)
                if !isLast {
                    Rectangle()
                        .fill(AppColors.borderSubtle)
                        .frame(width: 2)
                        .frame(minHeight: 98)
                }
            }

            WorkboardSurface {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .top, spacing: 10) {
                        GatewayBadge(ref: run.gatewayRef, customs: customGateways, diameter: 28)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(run.state.title)
                                .font(.headline)
                                .foregroundStyle(AppColors.textPrimary)
                            Text(verbatim: run.gatewayName)
                                .font(.caption)
                                .foregroundStyle(AppColors.textTertiary)
                        }
                        Spacer(minLength: 8)
                        Text(run.startedAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                            .font(.caption)
                            .foregroundStyle(AppColors.textTertiary)
                    }

                    if let failure = run.failureMessage, !failure.isEmpty {
                        Text(verbatim: failure)
                            .font(.subheadline)
                            .foregroundStyle(AppColors.error)
                    }

                    DisclosureGroup(
                        isExpanded: $showsSentVersion,
                        content: {
                            VStack(alignment: .leading, spacing: 10) {
                                Text(verbatim: run.sentPrompt)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(AppColors.textSecondary)
                                    .textSelection(.enabled)
                                if !run.includedMaterialNames.isEmpty {
                                    Divider().overlay(AppColors.borderSubtle)
                                    ForEach(run.includedMaterialNames, id: \.self) { name in
                                        Label {
                                            Text(verbatim: name)
                                        } icon: {
                                            Image(systemName: "paperclip")
                                        }
                                        .font(.caption)
                                        .foregroundStyle(AppColors.textTertiary)
                                    }
                                }
                            }
                            .padding(.top, 8)
                        },
                        label: {
                            Text(LocalizedStringResource(
                                "workboard.detail.timeline.sentVersion",
                                defaultValue: "Sent version"
                            ))
                            .font(.subheadline.weight(.semibold))
                        }
                    )
                    .tint(AppColors.brandAmber)

                    if let onOpenConversation {
                        Button(action: onOpenConversation) {
                            Label(
                                LocalizedStringResource(
                                    "workboard.action.openConversation",
                                    defaultValue: "Open Conversation"
                                ),
                                systemImage: "arrow.up.right"
                            )
                            .font(.subheadline.weight(.semibold))
                            .frame(minHeight: WorkboardMetrics.touchTarget)
                        }
                        .settingsRowButton()
                    }
                }
            }
            .padding(.bottom, isLast ? 0 : 12)
        }
        .accessibilityElement(children: .contain)
    }

    private var tint: Color {
        switch run.state {
        case .sending, .waiting: return AppColors.brandTeal
        case .replied: return AppColors.success
        case .failed: return AppColors.error
        case .cancelled: return AppColors.textTertiary
        }
    }
}
