// SPDX-License-Identifier: Apache-2.0

// Conduck
// WorkboardDetailView.swift
//
// The desk. The card board and the pinned composer, and nothing that competes
// with them: this surface collects material and never sends any of it.
//
// Work is ONE desk at a compile-time identity, so this view resolves no item
// and takes no id. It renders a `WorkboardDeskPresentation.Desk` its host has
// already resolved; the desk-before-its-first-card is one of that value's
// states, not a missing board.

import SwiftUI

struct WorkboardDetailView: View {
    @Bindable var viewModel: WorkboardViewModel

    /// The board to draw and the identity the composer, attach menu and
    /// pane-wide drop write into — the same value in both states, so capture on
    /// a desk with no row yet addresses the identity its first card lands on.
    let desk: WorkboardDeskPresentation.Desk

    @Environment(\.workbenchDestinationIsActive) private var workbenchDestinationIsActive

    /// The desk is titled by the workspace it is, never by the row behind it:
    /// the desk record carries no title or objective for anything to display.
    private static let deskTitle = LocalizedStringResource(
        "workboard.title",
        defaultValue: "Work"
    )

    var body: some View {
        ScrollView {
            Group {
                switch desk.board {
                case .invitation:
                    WorkboardEmptyState(
                        title: LocalizedStringResource(
                            "workboard.empty.title",
                            defaultValue: "Start with a thought, file or screenshot"
                        ),
                        message: LocalizedStringResource(
                            "workboard.desk.empty.message",
                            defaultValue: "Whatever you collect lands here as a card you can move and open."
                        )
                    )
                case .cards:
                    WorkboardCaptureCanvas(
                        viewModel: viewModel,
                        item: desk.item,
                        mode: .sources
                    )
                }
            }
            .padding(.horizontal, WorkboardMetrics.standardSpacing)
            .padding(.vertical, WorkboardMetrics.generousSpacing)
            .frame(maxWidth: WorkboardMetrics.contentMaxWidth)
            .frame(maxWidth: .infinity)
        }
        .dismissesKeyboardOnScrollOrTap()
        .safeAreaInset(edge: .bottom, spacing: 0) {
            WorkboardCaptureCanvas(
                viewModel: viewModel,
                item: desk.item,
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
