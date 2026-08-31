// SPDX-License-Identifier: Apache-2.0

// Conduck
// WorkboardDetailView.swift
//
// The desk. One project's board and nothing that competes with it: the project's
// name, the card board, and the pinned composer. Moving between projects and
// starting a new one belong to the sidebar. Run state, results and dispatch live
// on the view model and its sheets; this surface neither reports nor triggers them.

import SwiftUI

struct WorkboardDetailView: View {
    @Bindable var viewModel: WorkboardViewModel
    let itemID: UUID

    @Environment(\.workbenchDestinationIsActive) private var workbenchDestinationIsActive

    var body: some View {
        Group {
            if let item = viewModel.item(withID: itemID) {
                // Composer, attach menu and pane-wide drop all write into the
                // project whose board is on screen, finished included. Retargeting
                // a `.done` desk at a hidden new project would contradict the board
                // it is pinned under, and with no send on this surface there is
                // nothing a retarget would protect.
                let captureDestination = WorkboardCaptureDestination.existingWork(item.displayTitle)

                ScrollView {
                    VStack(alignment: .leading, spacing: WorkboardMetrics.generousSpacing) {
                        header(item)
                        WorkboardCaptureCanvas(
                            viewModel: viewModel,
                            item: item,
                            mode: .sources
                        )
                    }
                    .padding(.horizontal, WorkboardMetrics.standardSpacing)
                    .padding(.vertical, WorkboardMetrics.generousSpacing)
                    .frame(maxWidth: WorkboardMetrics.contentMaxWidth)
                    .frame(maxWidth: .infinity)
                }
                .scrollDismissesKeyboard(.interactively)
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    WorkboardCaptureCanvas(
                        viewModel: viewModel,
                        item: item,
                        mode: .composer,
                        destination: captureDestination
                    )
                    // The bar owns its own inset (Chat's 16/12). Only the
                    // full-bleed material belongs here: the board scrolls UNDER
                    // this inset, so the band has to reach both window edges
                    // even though the card inside it does not.
                    .background(.ultraThinMaterial)
                }
                .workboardPaneDropDestination(
                    viewModel: viewModel,
                    itemID: item.id,
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

    /// What the project is called, and the one control that still changes it.
    /// The pinned/captured chips stay because they describe the project itself,
    /// not a run.
    private func header(_ item: WorkboardItemSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                Text(verbatim: item.displayTitle)
                    .font(.largeTitle.weight(.bold))
                    .foregroundStyle(AppColors.textEmphasis)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                projectMenu(item)
            }

            if item.wasCapturedExternally || item.isPinned {
                HStack(spacing: 12) {
                    if item.wasCapturedExternally { capturedLabel }
                    if item.isPinned { pinnedLabel }
                }
            }
        }
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

    /// The desk's only project-level control. Edit is offered in EVERY state,
    /// `.done` included: the editor is now the sole route to the title, the
    /// objective, the pin and the rest of the brief, so gating it by state
    /// would leave a finished project unrenameable and its fields unreadable.
    private func projectMenu(_ item: WorkboardItemSnapshot) -> some View {
        Menu {
            Button {
                viewModel.showEditor(for: item)
            } label: {
                Label(
                    LocalizedStringResource("common.edit", defaultValue: "Edit"),
                    systemImage: "square.and.pencil"
                )
            }
            // The editor is the only route to the title, objective, brief fields
            // and pin, so it keeps a keyboard route on macOS.
            .keyboardShortcut("e", modifiers: .command)
            Divider()
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
}
