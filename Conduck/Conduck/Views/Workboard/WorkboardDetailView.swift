// SPDX-License-Identifier: Apache-2.0

// Conduck
// WorkboardDetailView.swift
//
// The desk. The card board and the pinned composer, and nothing that competes
// with them: this surface collects material and never sends any of it.
//
// Work is ONE desk at a compile-time identity, so this view resolves no item
// and takes no id. It reads the view model's desk directly; a nil desk is the
// state before the first capture created the row, not a missing board.

import SwiftUI

struct WorkboardDetailView: View {
    @Bindable var viewModel: WorkboardViewModel

    @Environment(\.workbenchDestinationIsActive) private var workbenchDestinationIsActive

    /// The desk is titled by the workspace it is, never by the row behind it:
    /// the desk record carries no title or objective for anything to display.
    private static let deskTitle = LocalizedStringResource(
        "workboard.title",
        defaultValue: "Work"
    )

    /// The board the composer, attach menu and pane-wide drop write into. It is
    /// the desk whether or not its row exists yet, so capture on an empty desk
    /// addresses the same identity the first card lands on.
    private var desk: WorkboardItemSnapshot {
        viewModel.desk ?? WorkboardItemSnapshot(id: Constants.workboardDeskItemID)
    }

    var body: some View {
        ScrollView {
            Group {
                if desk.materials.isEmpty {
                    WorkboardEmptyState(
                        title: LocalizedStringResource(
                            "workboard.empty.title",
                            defaultValue: "Start with a thought, file or screenshot"
                        ),
                        message: LocalizedStringResource(
                            "workboard.desk.empty.message",
                            defaultValue: "Whatever you collect lands here as a card you can move and resize."
                        )
                    )
                } else {
                    WorkboardCaptureCanvas(
                        viewModel: viewModel,
                        item: desk,
                        mode: .sources
                    )
                }
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
                item: desk,
                mode: .composer
            )
            // The bar owns its own inset (Chat's 16/12). Only the full-bleed
            // material belongs here: the board scrolls UNDER this inset, so
            // the band has to reach both window edges even though the card
            // inside it does not.
            .background(.ultraThinMaterial)
        }
        .workboardPaneDropDestination(viewModel: viewModel)
        .background(AppColors.background.ignoresSafeArea())
        .workbenchNavigationTitle(
            Text(Self.deskTitle),
            isActive: workbenchDestinationIsActive
        )
        .workboardInlineNavigationTitle()
    }
}
