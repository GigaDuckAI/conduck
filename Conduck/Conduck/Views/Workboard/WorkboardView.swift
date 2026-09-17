// SPDX-License-Identifier: Apache-2.0

// Conduck
// WorkboardView.swift
//
// Work's reusable desk column and durable presentation chain. macOS supplies
// the window's persistent native sidebar; regular-width iPad supplies its own
// split view here, with the same project navigation and Settings footer. Phone
// and compact iPad keep a navigation stack and the Projects picker. Each iPad
// workspace owns its navigation container so the retained Work/Chats layers
// keep their own bars and state.

import SwiftUI

/// A shell that supplies Work's project-navigation control sets this only on
/// its Work layer. The in-pane header then avoids drawing a second toggle.
private struct WorkDeskSidebarHostKey: EnvironmentKey {
    static let defaultValue = false
}

/// A native split column owns navigation outside the desk's capture inset.
private struct WorkDeskExternalNavigationKey: EnvironmentKey {
    static let defaultValue = false
}

/// Settings belongs to the platform host, shared by the sidebar and picker.
private struct WorkDeskOpenSettingsKey: EnvironmentKey {
    static let defaultValue: (() -> Void)? = nil
}

extension EnvironmentValues {
    var workDeskSidebarIsHosted: Bool {
        get { self[WorkDeskSidebarHostKey.self] }
        set { self[WorkDeskSidebarHostKey.self] = newValue }
    }

    var workDeskNavigationIsExternal: Bool {
        get { self[WorkDeskExternalNavigationKey.self] }
        set { self[WorkDeskExternalNavigationKey.self] = newValue }
    }

    var workDeskOpenSettings: (() -> Void)? {
        get { self[WorkDeskOpenSettingsKey.self] }
        set { self[WorkDeskOpenSettingsKey.self] = newValue }
    }
}

/// System-styled window toolbar control. Its observed workspace is the same
/// persistent state the desk reads, so a toolbar closure never captures a stale
/// visibility value. Compact windows open the project picker instead.
struct WorkDeskSidebarToolbarButton: View {
    @Bindable var workspace: WorkDeskWorkspaceState
    let isActive: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var label: LocalizedStringResource {
        if !workspace.presentsSidebarInline {
            return LocalizedStringResource("workdesk.projects", defaultValue: "Projects")
        }
        return workspace.showsSidebar
            ? LocalizedStringResource("workdesk.sidebar.hide", defaultValue: "Hide project sidebar")
            : LocalizedStringResource("workdesk.sidebar.show", defaultValue: "Show project sidebar")
    }

    var body: some View {
        Button {
            guard isActive else { return }
            withAnimation(reduceMotion ? nil : .snappy(duration: 0.22)) {
                workspace.toggleProjectNavigation()
            }
        } label: {
            Image(systemName: "sidebar.leading")
        }
        // The native toolbar supplies its hit area, hover and glass style.
        .disabled(!isActive)
        .accessibilityLabel(Text(label))
        .help(String(localized: label))
        .accessibilityIdentifier("workdesk-sidebar-toggle")
    }
}

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

    /// The wide shell supplies its shared section control through this model.
    /// iPhone supplies a separate router for its Open Chats flip button;
    /// compact iPad supplies neither because it uses the native tab bar.
    @Environment(\.personalWorkbenchModel) private var personalWorkbenchModel
    #if os(iOS)
    @Environment(\.phoneWorkbenchRouter) private var phoneWorkbenchRouter
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.workDeskOpenSettings) private var workDeskOpenSettings
    #endif

    var body: some View {
        #if os(iOS)
        iosNavigation
            // Navigation exists before the desk finishes loading. Keep the
            // toggle's mode accurate even when no workspace detail is mounted.
            .onChange(of: usesNativeSidebar, initial: true) { _, usesSidebar in
                guard isActive else { return }
                viewModel.deskWorkspace.updateSidebarLayout(isInline: usesSidebar)
            }
            .onChange(of: isActive) { _, active in
                guard active else { return }
                viewModel.deskWorkspace.updateSidebarLayout(isInline: usesNativeSidebar)
            }
            .environment(\.workbenchDestinationIsActive, isActive)
            .modifier(presentationModifier)
        #else
        NavigationStack { detailColumn }
            .environment(\.workbenchDestinationIsActive, isActive)
            .modifier(presentationModifier)
        #endif
    }

    #if os(iOS)
    /// Match the app shell's idiom gate: a landscape iPhone can report regular
    /// width while still requiring its compact project picker.
    private var usesNativeSidebar: Bool {
        horizontalSizeClass == .regular && DeviceCapabilities.isiPad
    }

    @ViewBuilder
    private var iosNavigation: some View {
        if usesNativeSidebar {
            wideNavigation
        } else {
            compactNavigation
        }
    }

    /// In retained sibling Work/Chats split views, the iPad system toggle drew
    /// but tapping it delivered no visibility-binding write. Reuse the explicit
    /// workspace button in the visible column's native bar; the split itself
    /// still owns the full-height sidebar and column layout.
    private var wideNavigation: some View {
        // Read visibility in the host's observation scope. A nested toolbar
        // closure alone can outlive the update that should replace its items.
        let showsSidebar = viewModel.deskWorkspace.showsSidebar
        return NavigationSplitView(columnVisibility: sidebarColumnVisibility) {
            VStack(spacing: 0) {
                WorkDeskSidebarView(viewModel: viewModel)
                SidebarSettingsFooter(onOpenSettings: openSettings)
                    .disabled(!isActive)
            }
            .frame(minWidth: 260, maxHeight: .infinity)
            .navigationSplitViewColumnWidth(min: 260, ideal: 320, max: 320)
            .workbenchNavigationTitle(Text(""), isActive: isActive)
            .toolbar(removing: isActive ? .sidebarToggle : nil)
            .toolbar {
                // The sidebar column's own lifetime removes this bar while
                // collapsed. Gating it on visibility as well loses the bar on
                // reopening, so only the destination may silence its content.
                if isActive {
                    ToolbarItem(placement: .topBarTrailing) {
                        WorkDeskSidebarToolbarButton(workspace: viewModel.deskWorkspace, isActive: isActive)
                    }
                }
            }
        } detail: {
            detailColumn
                .toolbar(removing: isActive ? .sidebarToggle : nil)
                .toolbar { workbenchToolbar(showsProjectNavigation: !showsSidebar) }
        }
        .environment(\.workDeskNavigationIsExternal, true)
        .environment(\.workDeskSidebarIsHosted, true)
    }

    /// The workspace owns Work's remembered visibility across section changes
    /// and compact-width rebuilds. Native visibility write-backs use the current
    /// router state so hidden layers cannot overwrite that remembered choice.
    private var sidebarColumnVisibility: Binding<NavigationSplitViewVisibility> {
        Self.sidebarVisibilityBinding(
            workspace: viewModel.deskWorkspace,
            router: personalWorkbenchModel?.router,
            standaloneIsActive: isActive
        )
    }

    /// A retained binding must both activate and become inert again as the
    /// router changes. Standalone hosts without a workbench keep their own gate.
    static func sidebarVisibilityBinding(
        workspace: WorkDeskWorkspaceState,
        router: PersonalWorkbenchRouter?,
        standaloneIsActive: Bool
    ) -> Binding<NavigationSplitViewVisibility> {
        Binding(
            get: { workspace.showsSidebar ? .all : .detailOnly },
            set: { visibility in
                let isActive = router.map { $0.destination == .work } ?? standaloneIsActive
                guard isActive else { return }
                workspace.showsSidebar = visibility != .detailOnly
            }
        )
    }

    private var compactNavigation: some View {
        NavigationStack {
            detailColumn
                .environment(\.workDeskSidebarIsHosted, true)
                .toolbar { workbenchToolbar(showsProjectNavigation: true) }
        }
        .environment(\.workDeskNavigationIsExternal, false)
    }

    private func openSettings() {
        guard isActive else { return }
        workDeskOpenSettings?()
    }

    /// Work's bar, declared INSIDE this view's navigation container. Toolbar
    /// items are collected in view-tree order, so an item declared ABOVE a
    /// navigation container reaches no bar at all — which is why this belongs
    /// here rather than on whichever host mounts the surface.
    ///
    /// Project navigation leads on compact layouts and when the native iPad
    /// sidebar is hidden. With the sidebar up its own bar carries that button.
    /// The section control stays last; layout selection belongs to the named
    /// workspace header control.
    ///
    /// No `ToolbarSpacer` between the two. A fixed spacer exists to break the
    /// ONE shared glass capsule the system wraps around adjacent items of a
    /// placement, and the section control already leaves that group:
    /// `WorkbenchSectionToolbarItem` hides its shared background because the
    /// control draws its own filled container.
    ///
    /// The whole bar is gated on `isActive` — the silence every
    /// destination-aware host keeps, so a hidden layer contributes no toolbar
    /// preference to the window it shares with its sibling.
    @ToolbarContentBuilder
    private func workbenchToolbar(showsProjectNavigation: Bool) -> some ToolbarContent {
        if isActive {
            ToolbarItem(placement: .principal) {
                WorkDeskToolbarTitle(workspace: viewModel.deskWorkspace)
            }
            .sharedBackgroundVisibility(.hidden)

            if showsProjectNavigation {
                ToolbarItem(placement: .topBarLeading) {
                    WorkDeskSidebarToolbarButton(workspace: viewModel.deskWorkspace, isActive: isActive)
                }
            }

            if let personalWorkbenchModel {
                WorkbenchSectionToolbarItem(model: personalWorkbenchModel)
            }

            // Open Chats — the phone's one-tap way back, trailing-most, icon only.
            if let router = phoneWorkbenchRouter {
                ToolbarItem(placement: .primaryAction) {
                    PhoneWorkbenchFlipButton(router: router, from: .work)
                }
            }
        }
    }
    #endif

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

    @Environment(\.scenePhase) private var scenePhase

    private var tutorial: WorkboardTutorialSession { viewModel.tutorialSession }

    func body(content: Content) -> some View {
        content
            .appReviewBusy(tutorial.isPresented(tutorialAvailability))
            .sheet(isPresented: tutorialIsPresented) {
                WorkboardTutorialView(session: tutorial, onDone: acknowledgeTutorial)
                    .onAppear { tutorial.didPresent() }
            }
            .onChange(of: isActive, initial: true) { _, active in
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

    // MARK: - Retained tour presentation

    private var tutorialAvailability: WorkboardTutorialAvailability {
        let workspace = viewModel.deskWorkspace
        return WorkboardTutorialAvailability(
            isActive: isActive,
            isReady: viewModel.hasLoadedDesk && !viewModel.isLoading && scenePhase == .active,
            isBlocked: (!viewModel.hasLoadedDesk && viewModel.isLoading) || viewModel.isCapturingIntoDesk
                || viewModel.notice != nil || workspace.blocksWorkTourPresentation
                || WorkVoiceCaptureLaunchRoute.shared.isPending,
            blocksAutomatic: workspace.isShowingConversation || workspace.isSearching
                || workspace.isSelecting || workspace.scope != .all
                || viewModel.hasComposerDraft || workspace.materialRevealRequest != nil
        )
    }

    /// Go to Work and Skip close only the tour. They never navigate, focus the
    /// composer, record or create sample data. The device flag was consumed
    /// before presentation, so leaving halfway through never repeats the tour.
    private func acknowledgeTutorial() {
        guard tutorial.acknowledge(tutorialAvailability) else { return }
    }

    private var tutorialIsPresented: Binding<Bool> {
        Binding(
            get: { tutorial.isPresented(tutorialAvailability) },
            set: { isPresented in
                guard !isPresented else { return }
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
        switch viewModel.deskPresentation {
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
