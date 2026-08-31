// SPDX-License-Identifier: Apache-2.0

// Conduck
// WorkboardDetailView.swift
//
// The desk. One project's board and nothing that competes with it: the card
// board and the pinned composer. Naming, pinning, duplicating and deleting a
// project belong to its sidebar row, alongside moving between projects and
// starting a new one. Run state, results and dispatch live on the view model
// and its sheets; this surface neither reports nor triggers them.

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
                    WorkboardCaptureCanvas(
                        viewModel: viewModel,
                        item: item,
                        mode: .sources
                    )
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
                #if os(macOS)
                // The Mac main menu is the one project-action route no column
                // can hide, so the desk publishes what it is showing. Only while
                // Work is the on-screen destination: a mounted but hidden Work
                // layer must not leave the menu acting on a project nobody sees.
                .focusedSceneValue(
                    \.workboardProjectCommandTarget,
                    workbenchDestinationIsActive
                        ? WorkboardProjectCommandTarget(viewModel: viewModel, item: item)
                        : nil
                )
                #endif
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
}
