// SPDX-License-Identifier: Apache-2.0

// Conduck
// WorkboardView.swift
//
// Work is one desk, so this surface is one pane: the desk canvas plus the
// durable presentation chain that rides above it. The pane is wrapped in a
// navigation container here rather than by the caller, because iPad mounts two
// sibling workspaces in one ZStack and each needs its own navigation bar for
// the section control to render into.

import SwiftUI

struct WorkboardView: View {
    @Bindable var viewModel: WorkboardViewModel

    @Environment(\.workbenchDestinationIsActive) private var workbenchDestinationIsActive
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        WorkboardExperience(
            viewModel: viewModel,
            isActive: workbenchDestinationIsActive,
            reduceMotion: reduceMotion
        )
    }
}

/// The Work surface split into two reusable pieces: one column view and one
/// presentation modifier. macOS mounts them inside the app's one persistent
/// split-view shell, while iPad and iPhone use this type's standalone `body`.
/// Every sheet rides the presentation modifier, so the column itself holds
/// nothing that hiding or unmounting it would lose.
struct WorkboardExperience: View {
    @Bindable var viewModel: WorkboardViewModel

    let isActive: Bool
    let reduceMotion: Bool

    var body: some View {
        NavigationStack {
            detailColumn
        }
        .environment(\.workbenchDestinationIsActive, isActive)
        .modifier(presentationModifier)
    }

    /// Work's column and its presentation chain are handed to the host as
    /// VALUES, never inlined into the host's own body, so each gets its own
    /// Observation scope: a `workspaceStatus` toast invalidates only the node
    /// that read it. macOS mounts these two pieces inside the persistent window
    /// shell, where the host's body is the entire window and would otherwise
    /// rebuild Chat's sidebar and transcript on every Work state change.
    var detailColumn: WorkboardDetailColumn {
        WorkboardDetailColumn(viewModel: viewModel, isActive: isActive)
    }

    var presentationModifier: WorkboardPresentationModifier {
        WorkboardPresentationModifier(
            viewModel: viewModel,
            isActive: isActive,
            reduceMotion: reduceMotion
        )
    }
}

/// Work's durable presentation chain — the one-time tutorial, the capture toast
/// and the notice alert. It rides the host's persistent shell rather than the
/// desk column, so hiding or unmounting Work's pixels can never re-anchor a
/// sheet.
struct WorkboardPresentationModifier: ViewModifier {
    let viewModel: WorkboardViewModel

    let isActive: Bool
    let reduceMotion: Bool

    /// The one-time board tutorial. `hasEvaluatedTutorial` latches only once the
    /// gate has actually been READ, so a first activation that arrives while
    /// another Work sheet is up gets a later turn instead of being consumed.
    @State private var showsTutorial = false
    @State private var hasEvaluatedTutorial = false

    func body(content: Content) -> some View {
        content
            .task(id: tutorialGate) {
                await evaluateTutorialGate()
            }
            .sheet(isPresented: tutorialIsPresented) {
                WorkboardTutorialView(onDone: acknowledgeTutorial)
            }
            .onChange(of: isActive) { _, active in
                guard !active else { return }
                dismissTransientPresentations()
            }
            .overlay(alignment: .top) {
                if isActive, let status = viewModel.workspaceStatus {
                    // The glyph carries the register: a capture landed, or the
                    // desk kept an order this device tried to change. One
                    // checkmark for both would confirm something that did not
                    // happen.
                    Label(
                        status.message,
                        systemImage: status.kind == .conflict
                            ? "arrow.triangle.2.circlepath"
                            : "checkmark.circle.fill"
                    )
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AppColors.textPrimary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(.ultraThinMaterial, in: Capsule())
                        .overlay { Capsule().stroke(AppColors.borderSubtle, lineWidth: 1) }
                        .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
                        .padding(.top, 12)
                        .padding(.horizontal, 16)
                        .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
                        .accessibilityElement(children: .combine)
                        .allowsHitTesting(false)
                }
            }
            .task(id: viewModel.workspaceStatus?.id) {
                guard let statusID = viewModel.workspaceStatus?.id else { return }
                try? await Task.sleep(for: .seconds(2.6))
                guard !Task.isCancelled, viewModel.workspaceStatus?.id == statusID else { return }
                if reduceMotion {
                    viewModel.workspaceStatus = nil
                } else {
                    withAnimation(.easeOut(duration: 0.2)) { viewModel.workspaceStatus = nil }
                }
            }
            .alert(item: activeNoticePresentation) { notice in
                Alert(
                    title: Text(notice.title),
                    message: Text(verbatim: notice.message),
                    dismissButton: .default(Text(LocalizedStringResource(
                        "common.ok",
                        defaultValue: "OK"
                    )))
                )
            }
    }

    // MARK: - One-time board tutorial

    /// SwiftUI drops the second of two concurrent presentations, so the tutorial
    /// waits until Work owns no other sheet, alert or confirmation. Both inputs
    /// key the `.task`, which is what gives it a later turn.
    private struct WorkboardTutorialGate: Hashable {
        let isActive: Bool
        let isBlocked: Bool
    }

    private var tutorialGate: WorkboardTutorialGate {
        WorkboardTutorialGate(
            isActive: isActive,
            isBlocked: viewModel.notice != nil
        )
    }

    private func evaluateTutorialGate() async {
        guard !hasEvaluatedTutorial else { return }
        let gate = tutorialGate
        guard gate.isActive, !gate.isBlocked else { return }
        hasEvaluatedTutorial = true
        let shouldShow = await SettingsManager.shared.shouldShowWorkboardTutorial()
        // A sheet or alert can open across the actor hop, which restarts the
        // `.task`. Release the latch when that happened so the tutorial gets a
        // later turn instead of presenting into an occupied slot.
        let resolved = tutorialGate
        guard !Task.isCancelled, resolved.isActive, !resolved.isBlocked else {
            hasEvaluatedTutorial = false
            return
        }
        guard shouldShow else { return }
        showsTutorial = true
    }

    /// "Seen" means acknowledged, so the write happens here and nowhere else:
    /// the CTA calls this directly, and a swipe-down or Escape reaches it
    /// through the binding's setter. Leaving Work parks the sheet instead —
    /// the flag is untouched and the tutorial returns on the next visit.
    private func acknowledgeTutorial() {
        guard showsTutorial else { return }
        showsTutorial = false
        Task { await SettingsManager.shared.markWorkboardTutorialSeen() }
    }

    private var tutorialIsPresented: Binding<Bool> {
        Binding(
            get: { isActive && showsTutorial },
            set: { isPresented in
                guard !isPresented, isActive else { return }
                acknowledgeTutorial()
            }
        )
    }

    private var activeNoticePresentation: Binding<WorkboardNotice?> {
        Binding(
            get: { isActive ? viewModel.notice : nil },
            set: { notice in
                // The getter is gated, so a hidden Work still echoes a dismissal
                // write from the alert it was showing when it left the screen.
                // Ignore those: they would clear a notice raised after the
                // switch, which the person has not read yet.
                guard isActive else { return }
                viewModel.notice = notice
            }
        )
    }

    /// Everything cleared here is transient: none of it holds text the person
    /// would lose.
    @MainActor
    private func dismissTransientPresentations() {
        if viewModel.notice != nil { viewModel.notice = nil }
    }
}

/// The desk as its own view node, so a Work state change invalidates this
/// column alone rather than whichever shell mounts it. The load state and the
/// desk's material are read HERE rather than in that shell.
struct WorkboardDetailColumn: View {
    @Bindable var viewModel: WorkboardViewModel

    let isActive: Bool

    /// The desk is titled by the workspace it is, never by the row behind it:
    /// the desk record carries no title or objective for anything to display.
    private static let deskTitle = LocalizedStringResource(
        "workboard.title",
        defaultValue: "Work"
    )

    @ViewBuilder
    var body: some View {
        switch WorkboardDeskPresentation.resolve(
            isLoading: viewModel.isLoading,
            loadError: viewModel.loadError,
            desk: viewModel.desk
        ) {
        case .loading:
            VStack(spacing: 14) {
                ProgressView()
                    .controlSize(.large)
                    .tint(AppColors.brandAmber)
                Text(LocalizedStringResource(
                    "workboard.loading",
                    defaultValue: "Opening your private work…"
                ))
                .font(.subheadline)
                .foregroundStyle(AppColors.textSecondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(AppColors.background.ignoresSafeArea())
            .workbenchNavigationTitle(Text(Self.deskTitle), isActive: isActive)
        case .loadFailed(let loadError):
            WorkboardEmptyState(
                title: LocalizedStringResource(
                    "workboard.load.failed.title",
                    defaultValue: "Work couldn’t open"
                ),
                message: LocalizedStringResource(
                    "workboard.load.failed.message",
                    defaultValue: "Your desk stays private and unchanged. Try opening it again."
                ),
                actionTitle: LocalizedStringResource(
                    "workboard.load.retry",
                    defaultValue: "Try Again"
                )
            ) {
                viewModel.loadError = nil
                Task { await viewModel.load() }
            }
            .accessibilityValue(Text(verbatim: loadError))
            .background(AppColors.background.ignoresSafeArea())
            .workbenchNavigationTitle(Text(Self.deskTitle), isActive: isActive)
        case .desk(let desk):
            // One desk, one surface: the detail view draws both the board and
            // the desk-before-its-first-material state, so there is no second
            // empty-desk arm here to drift out of step with it.
            WorkboardDetailView(viewModel: viewModel, desk: desk)
        }
    }
}
