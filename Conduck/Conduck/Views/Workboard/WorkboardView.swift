// SPDX-License-Identifier: Apache-2.0

// Conduck
// WorkboardView.swift
//
// Adaptive project workspace. WorkItem remains the one durable project/brief
// boundary; NavigationSplitView gives Mac and iPad the sketch's persistent
// project sidebar while naturally collapsing into list -> canvas on iPhone.

import SwiftUI

struct WorkboardView: View {
    @Bindable var viewModel: WorkboardViewModel

    @Environment(\.workbenchDestinationIsActive) private var workbenchDestinationIsActive
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @SceneStorage("workboard.showsOverview") private var showsOverview = true
    @State private var emptyWorkspaceID = UUID()
    @State private var preferredCompactColumn = NavigationSplitViewColumn.sidebar
    /// Keep the split view's actual state. Collapsing `.automatic` into a Bool
    /// made the toolbar toggle think a system-managed, visible sidebar was
    /// hidden, so its first click was a no-op.
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic

    var body: some View {
        WorkboardExperience(
            viewModel: viewModel,
            showsOverview: $showsOverview,
            emptyWorkspaceID: $emptyWorkspaceID,
            preferredCompactColumn: $preferredCompactColumn,
            columnVisibility: $columnVisibility,
            isActive: workbenchDestinationIsActive,
            showsSidebarToolbar: true,
            horizontalSizeClass: horizontalSizeClass,
            reduceMotion: reduceMotion
        )
    }
}

/// The Work surface split into three reusable pieces: two column views and one
/// presentation modifier. macOS mounts them inside the app's one persistent
/// split-view shell, while iPad and iPhone use this type's standalone `body`.
/// Everything durable — selected project, overview flag, provisional canvas id,
/// sidebar column preference — is a binding owned by the HOST and every sheet
/// rides the presentation modifier, so the columns themselves hold nothing that
/// hiding or unmounting them would lose.
struct WorkboardExperience: View {
    @Bindable var viewModel: WorkboardViewModel

    @Binding var showsOverview: Bool
    @Binding var emptyWorkspaceID: UUID
    @Binding var preferredCompactColumn: NavigationSplitViewColumn
    @Binding var columnVisibility: NavigationSplitViewVisibility

    let isActive: Bool
    let showsSidebarToolbar: Bool
    let horizontalSizeClass: UserInterfaceSizeClass?
    let reduceMotion: Bool

    var body: some View {
        NavigationSplitView(
            columnVisibility: $columnVisibility,
            preferredCompactColumn: $preferredCompactColumn
        ) {
            sidebarColumn
                .navigationSplitViewColumnWidth(min: 260, ideal: 280, max: 320)
        } detail: {
            detailColumn
        }
        .environment(\.workbenchDestinationIsActive, isActive)
        .modifier(presentationModifier)
    }

    /// Work's two columns and its presentation chain are handed to the host as
    /// VALUES, never inlined into the host's own body. Each therefore gets its
    /// own Observation scope: a `searchText` keystroke or a `workspaceStatus`
    /// toast invalidates only the node that read it. macOS mounts these three
    /// pieces inside the persistent window shell, where the host's body is the
    /// entire window and would otherwise rebuild Chat's sidebar and transcript
    /// on every Work state change.
    var sidebarColumn: WorkboardSidebarColumn {
        WorkboardSidebarColumn(
            viewModel: viewModel,
            showsOverview: $showsOverview,
            preferredCompactColumn: $preferredCompactColumn,
            isActive: isActive,
            showsSidebarToolbar: showsSidebarToolbar
        )
    }

    var detailColumn: WorkboardDetailColumn {
        WorkboardDetailColumn(
            viewModel: viewModel,
            showsOverview: $showsOverview,
            emptyWorkspaceID: $emptyWorkspaceID,
            preferredCompactColumn: $preferredCompactColumn,
            isActive: isActive
        )
    }

    var presentationModifier: WorkboardPresentationModifier {
        WorkboardPresentationModifier(
            viewModel: viewModel,
            showsOverview: $showsOverview,
            emptyWorkspaceID: $emptyWorkspaceID,
            preferredCompactColumn: $preferredCompactColumn,
            isActive: isActive,
            horizontalSizeClass: horizontalSizeClass,
            reduceMotion: reduceMotion
        )
    }
}

/// Work's durable presentation chain — the board load's follow-up selection, the
/// preflight/briefing sheets, the capture toast, the rename alert and both
/// confirmations. It rides the host's persistent shell rather than either
/// column, so hiding or unmounting Work's pixels can never re-anchor a sheet.
struct WorkboardPresentationModifier: ViewModifier {
    let viewModel: WorkboardViewModel

    @Binding var showsOverview: Bool
    @Binding var emptyWorkspaceID: UUID
    @Binding var preferredCompactColumn: NavigationSplitViewColumn

    let isActive: Bool
    let horizontalSizeClass: UserInterfaceSizeClass?
    let reduceMotion: Bool

    /// The board's first load is owned by `WorkCaptureRefreshCoordinator`, which
    /// may run long after this modifier mounts (Work defers its load while it is
    /// hidden). Landing the initial wide selection on the load's completion keeps
    /// the old `.task` behaviour without a second load owner.
    @State private var hasAppliedInitialSelection = false

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
            .onChange(of: viewModel.isLoading) { _, isLoading in
                guard !isLoading, !hasAppliedInitialSelection, viewModel.loadError == nil else { return }
                hasAppliedInitialSelection = true
                selectInitialWideItemIfNeeded()
            }
            .onChange(of: horizontalSizeClass) { _, _ in
                selectInitialWideItemIfNeeded()
            }
            .onChange(of: viewModel.selectedItemID) { _, selectedID in
                guard selectedID != nil else {
                    if viewModel.provisionalWorkspaceID == nil { showsOverview = true }
                    return
                }
                if selectedID == emptyWorkspaceID { emptyWorkspaceID = UUID() }
                showsOverview = false
                // Importing the first attachment persists the provisional item and
                // selects it. Keep any half-written composer text under that same ID;
                // only abandon a genuinely different provisional canvas.
                if selectedID == viewModel.provisionalWorkspaceID {
                    viewModel.provisionalWorkspaceID = nil
                } else {
                    viewModel.cancelProvisionalWorkspace()
                }
                preferredCompactColumn = .detail
            }
            .onChange(of: isActive) { _, active in
                guard !active else { return }
                dismissTransientPresentations()
            }
            .sheet(isPresented: preflightIsPresented) {
                if let itemID = viewModel.preflightItemID {
                    WorkboardDispatchSheet(viewModel: viewModel, itemID: itemID)
                }
            }
            .sheet(item: activeBriefingPresentation) { briefing in
                WorkboardBriefingView(
                    viewModel: viewModel,
                    briefing: briefing,
                    onOpenItem: openItem
                )
            }
            .overlay(alignment: .top) {
                if isActive, let status = viewModel.workspaceStatus {
                    Label(status.message, systemImage: "checkmark.circle.fill")
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
            .confirmationDialog(
                confirmationTitle,
                isPresented: confirmationIsPresented,
                titleVisibility: .visible,
                presenting: viewModel.confirmation
            ) { confirmation in
                switch confirmation.kind {
                case .duplicate:
                    Button(LocalizedStringResource(
                        "workboard.confirm.duplicate.action",
                        defaultValue: "Make a Copy"
                    )) {
                        Task { await viewModel.performConfirmation() }
                    }
                case .delete:
                    Button(
                        LocalizedStringResource(
                            "workboard.confirm.delete.action",
                            defaultValue: "Delete Brief"
                        ),
                        role: .destructive
                    ) {
                        Task { await viewModel.performConfirmation() }
                    }
                }
                Button(
                    LocalizedStringResource("common.cancel", defaultValue: "Cancel"),
                    role: .cancel
                ) {
                    viewModel.confirmation = nil
                }
            } message: { confirmation in
                Text(verbatim: confirmationMessage(confirmation))
            }
            .alert(
                String(localized: LocalizedStringResource(
                    "workboard.rename.title",
                    defaultValue: "Rename Work"
                )),
                isPresented: renameIsPresented
            ) {
                TextField(
                    String(localized: LocalizedStringResource(
                        "workboard.rename.prompt",
                        defaultValue: "Name"
                    )),
                    text: renameFieldText
                )
                Button(LocalizedStringResource("workboard.action.rename", defaultValue: "Rename")) {
                    Task { await viewModel.commitRename() }
                }
                Button(
                    LocalizedStringResource("common.cancel", defaultValue: "Cancel"),
                    role: .cancel
                ) {
                    viewModel.renameRequest = nil
                }
            } message: {
                Text(LocalizedStringResource(
                    "workboard.rename.message",
                    defaultValue: "Only the name changes. Cards, sources and replies stay where they are."
                ))
            }
    }

    private func openItem(_ item: WorkboardItemSnapshot) {
        openWorkboardItem(
            item,
            viewModel: viewModel,
            showsOverview: $showsOverview,
            preferredCompactColumn: $preferredCompactColumn
        )
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
            isBlocked: viewModel.preflightItemID != nil
                || viewModel.briefing != nil
                || viewModel.notice != nil
                || viewModel.confirmation != nil
                || viewModel.renameRequest != nil
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

    private func selectInitialWideItemIfNeeded() {
        guard horizontalSizeClass != .compact,
              !showsOverview,
              viewModel.provisionalWorkspaceID == nil,
              viewModel.selectedItemID == nil else { return }
        viewModel.selectedItemID = viewModel.items
            .filter { $0.state != .done }
            .sorted(by: WorkboardPresentationLogic.attentionSort)
            .first?.id
    }

    /// Gated like every other Work presentation, but written out rather than
    /// `.gated(by:)`: that wrapper lets a dismissal through while inactive, and
    /// SwiftUI writes one as it tears this alert down on deactivation. This
    /// alert holds a half-typed name, so ignoring that write is what brings the
    /// typed text back with it when Work returns.
    private var renameIsPresented: Binding<Bool> {
        Binding(
            get: { isActive && viewModel.renameRequest != nil },
            set: { isPresented in
                guard isActive else { return }
                if !isPresented { viewModel.renameRequest = nil }
            }
        )
    }

    /// The field writes straight into the view model, so the half-typed name
    /// survives the alert being torn down by a destination change.
    private var renameFieldText: Binding<String> {
        Binding(
            get: { viewModel.renameDraftTitle },
            set: { viewModel.renameDraftTitle = $0 }
        )
    }

    private var confirmationIsPresented: Binding<Bool> {
        Binding(
            get: { viewModel.confirmation != nil },
            set: { isPresented in
                if !isPresented { viewModel.confirmation = nil }
            }
        )
        .gated(by: isActive)
    }

    private var activeBriefingPresentation: Binding<WorkboardBriefingSnapshot?> {
        @Bindable var viewModel = viewModel
        return $viewModel.briefing.gated(by: isActive)
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

    private var preflightIsPresented: Binding<Bool> {
        Binding(
            get: { viewModel.preflightItemID != nil },
            set: { isPresented in
                guard !isPresented else { return }
                viewModel.preflightItemID = nil
                viewModel.selectedGatewayID = nil
                viewModel.excludedMaterialIDs = []
            }
        )
        .gated(by: isActive)
    }

    /// Everything cleared here is transient: none of it holds text the person
    /// would lose. The rename request is deliberately NOT cleared — it carries a
    /// half-typed name, and `renameIsPresented` is gated on `isActive`, so the
    /// alert hides while Work is off screen and comes back with the typed text.
    @MainActor
    private func dismissTransientPresentations() {
        if viewModel.confirmation != nil { viewModel.confirmation = nil }
        if viewModel.briefing != nil { viewModel.briefing = nil }
        if viewModel.notice != nil { viewModel.notice = nil }
        if viewModel.preflightItemID != nil { viewModel.preflightItemID = nil }
        if viewModel.selectedGatewayID != nil { viewModel.selectedGatewayID = nil }
        if !viewModel.excludedMaterialIDs.isEmpty { viewModel.excludedMaterialIDs = [] }
    }

    private var confirmationTitle: String {
        guard let confirmation = viewModel.confirmation else { return "" }
        switch confirmation.kind {
        case .duplicate:
            return String(localized: LocalizedStringResource(
                "workboard.confirm.duplicate.title",
                defaultValue: "Duplicate this brief?"
            ))
        case .delete:
            return String(localized: LocalizedStringResource(
                "workboard.confirm.delete.title",
                defaultValue: "Delete this brief?"
            ))
        }
    }

    private func confirmationMessage(_ confirmation: WorkboardConfirmation) -> String {
        switch confirmation.kind {
        case .duplicate:
            return String.localizedStringWithFormat(
                String(localized: LocalizedStringResource(
                    "workboard.confirm.duplicate.message",
                    defaultValue: "A new private draft will be created from “%@”. Sent runs are not copied."
                )),
                confirmation.itemTitle
            )
        case .delete:
            return String.localizedStringWithFormat(
                String(localized: LocalizedStringResource(
                    "workboard.confirm.delete.message",
                    defaultValue: "“%@” will be removed from your private iCloud board. Its existing conversations stay in Chat."
                )),
                confirmation.itemTitle
            )
        }
    }
}

/// The three writes every "open this project" affordance performs — sidebar row,
/// canvas card and briefing sheet — in one place so they cannot drift apart.
@MainActor
private func openWorkboardItem(
    _ item: WorkboardItemSnapshot,
    viewModel: WorkboardViewModel,
    showsOverview: Binding<Bool>,
    preferredCompactColumn: Binding<NavigationSplitViewColumn>
) {
    viewModel.briefing = nil
    viewModel.cancelProvisionalWorkspace()
    showsOverview.wrappedValue = false
    viewModel.selectedItemID = item.id
    preferredCompactColumn.wrappedValue = .detail
}

/// Work's project sidebar as its own view node: search text, filter and the
/// item list are read HERE, so a keystroke invalidates this column alone.
struct WorkboardSidebarColumn: View {
    @Bindable var viewModel: WorkboardViewModel

    @Binding var showsOverview: Bool
    @Binding var preferredCompactColumn: NavigationSplitViewColumn

    let isActive: Bool
    let showsSidebarToolbar: Bool

    var body: some View {
        let visibleItems = viewModel.visibleItems
        let activeItemCount = viewModel.items.lazy.filter { $0.state != .done }.count
        return VStack(spacing: 0) {
            SidebarSearchField(
                text: Binding(
                    get: { viewModel.searchText },
                    set: { viewModel.updateSearchText($0) }
                ),
                prompt: LocalizedStringResource(
                    "workboard.search.prompt",
                    defaultValue: "Search work, sources and replies"
                )
            )
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 8)

            sidebarFilterControl
                .padding(.horizontal, 12)
                .padding(.bottom, 8)

            List(selection: $viewModel.selectedItemID) {
            // macOS mounts Work inside the persistent window shell, which keeps
            // Chat's toolbar and suppresses Work's own sidebar toolbar. Without
            // this row that platform would have no VISIBLE New Work control while
            // a project is open — only ⌘⇧N and the All Work canvas.
            if !showsSidebarToolbar {
                Button {
                    showsOverview = false
                    viewModel.beginWorkspace()
                    preferredCompactColumn = .detail
                } label: {
                    Label(
                        LocalizedStringResource("workboard.newBrief", defaultValue: "New Work"),
                        systemImage: "plus.circle.fill"
                    )
                }
                .settingsRowButton()
                .listRowBackground(Color.clear)
            }

            Button {
                viewModel.cancelProvisionalWorkspace()
                showsOverview = true
                viewModel.selectedItemID = nil
                preferredCompactColumn = .detail
            } label: {
                Label {
                    HStack {
                        Text(LocalizedStringResource(
                            "workboard.overview.title",
                            defaultValue: "All Work"
                        ))
                        Spacer(minLength: 6)
                        Text(activeItemCount, format: .number)
                            .font(.caption.weight(.bold))
                            .foregroundStyle(AppColors.textTertiary)
                    }
                } icon: {
                    Image(systemName: "rectangle.stack")
                        .foregroundStyle(AppColors.brandAmber)
                }
            }
            .settingsRowButton()
            .listRowBackground(
                showsOverview && viewModel.selectedItemID == nil
                    ? AppColors.brandAmber.opacity(0.12)
                    : Color.clear
            )
            .accessibilityAddTraits(
                showsOverview && viewModel.selectedItemID == nil ? .isSelected : []
            )
            .accessibilityHint(Text(LocalizedStringResource(
                "workboard.overview.hint",
                defaultValue: "Shows the attention overview for every project"
            )))

            ForEach(WorkItemState.attentionOrder, id: \.self) { state in
                let stateItems = WorkboardPresentationLogic.items(
                    in: state,
                    from: visibleItems
                )
                if !stateItems.isEmpty {
                    Section {
                        ForEach(stateItems) { item in
                            NavigationLink(value: item.id) {
                                WorkboardSidebarRow(item: item)
                            }
                            .tag(item.id)
                            .contextMenu { projectActions(for: item) }
                            #if os(iOS)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) {
                                    viewModel.requestDelete(item)
                                } label: {
                                    Label(WorkboardProjectActionTitle.delete, systemImage: "trash")
                                }
                                Button {
                                    viewModel.requestRename(item)
                                } label: {
                                    Label(WorkboardProjectActionTitle.rename, systemImage: "pencil")
                                }
                            }
                            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                                Button {
                                    Task { await viewModel.setPinned(!item.isPinned, for: item.id) }
                                } label: {
                                    Label(
                                        WorkboardProjectActionTitle.pinToggle(isPinned: item.isPinned),
                                        systemImage: item.isPinned ? "pin.slash" : "pin"
                                    )
                                }
                                .tint(AppColors.brandAmber)
                            }
                            #endif
                        }
                    } header: {
                        WorkboardSidebarSectionHeader(state: state, count: stateItems.count)
                    }
                }
            }

            if !viewModel.items.isEmpty, visibleItems.isEmpty {
                ContentUnavailableView(
                    LocalizedStringResource(
                        "workboard.empty.filtered.title",
                        defaultValue: "No work matches"
                    ),
                    systemImage: "magnifyingglass",
                    description: Text(LocalizedStringResource(
                        "workboard.empty.filtered.message",
                        defaultValue: "Try a different search or show all work. Search stays inside your private board."
                    ))
                )
                .listRowBackground(Color.clear)
            }
            }
            .listStyle(.sidebar)
        }
        .workbenchNavigationTitle(
            Text(LocalizedStringResource("workboard.title", defaultValue: "Work")),
            isActive: isActive
        )
        .toolbar {
            if isActive, showsSidebarToolbar {
                sidebarToolbar
            }
        }
        .safeAreaInset(edge: .bottom) { sidebarFooter }
        .background(AppColors.background)
    }

    /// Project-level actions on the project's own row: right-click on macOS,
    /// long-press on iOS, and the trailing/leading swipes above. The desk itself
    /// carries no project chrome, so on iOS this menu is the only route to a
    /// project's name and pin; on macOS the Work main menu carries the same list
    /// for a window whose sidebar is collapsed.
    @ViewBuilder
    private func projectActions(for item: WorkboardItemSnapshot) -> some View {
        workboardProjectActions(
            isPinned: item.isPinned,
            onRename: { viewModel.requestRename(item) },
            onTogglePin: { Task { await viewModel.setPinned(!item.isPinned, for: item.id) } },
            onDuplicate: { viewModel.requestDuplicate(item) },
            onDelete: { viewModel.requestDelete(item) }
        )
    }

    @ToolbarContentBuilder
    private var sidebarToolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button {
                showsOverview = false
                viewModel.beginWorkspace()
                preferredCompactColumn = .detail
            } label: {
                Label(
                    LocalizedStringResource("workboard.newBrief", defaultValue: "New Work"),
                    systemImage: "plus"
                )
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
        }
    }

    private var sidebarFilterControl: some View {
        Menu {
            Picker(
                LocalizedStringResource("workboard.filter.title", defaultValue: "Show"),
                selection: $viewModel.filter
            ) {
                ForEach(WorkboardFilter.allCases) { filter in
                    Text(filter.title).tag(filter)
                }
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: viewModel.filter == .open
                    ? "line.3.horizontal.decrease"
                    : "line.3.horizontal.decrease.circle.fill")
                    .foregroundStyle(AppColors.brandAmber)
                Text(viewModel.filter.title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(AppColors.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 6)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(AppColors.textTertiary)
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 34)
            .background(AppColors.backgroundSecondary, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(AppColors.borderSubtle, lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .choiceCardButton(cornerRadius: 9)
        .help(String(localized: LocalizedStringResource(
            "workboard.filter.help",
            defaultValue: "Choose which work appears on the board"
        )))
    }

    private var sidebarFooter: some View {
        VStack(spacing: 4) {
            Divider().overlay(AppColors.borderSubtle)
            Button {
                viewModel.presentBriefing()
            } label: {
                Label(
                    LocalizedStringResource("workboard.briefMe", defaultValue: "Brief My Work"),
                    systemImage: "sun.max.fill"
                )
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .settingsRowButton()
            .disabled(!isActive)
            .keyboardShortcut("b", modifiers: [.command, .shift])

            Button {
                viewModel.openGatewaySettings()
            } label: {
                Label(
                    LocalizedStringResource("common.settings", defaultValue: "Settings"),
                    systemImage: "gearshape"
                )
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .settingsRowButton()

            Text(LocalizedStringResource(
                "workboard.workspace.sidebar.privacy",
                defaultValue: "Briefs sync privately · source files and screenshots stay on this device"
            ))
            .font(.caption2)
            .foregroundStyle(AppColors.textTertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.top, 2)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

/// Work's canvas column as its own view node, for the same reason as the
/// sidebar: the selected project, the overview's filtered strip and the load
/// state are read HERE rather than in whichever shell mounts the column.
struct WorkboardDetailColumn: View {
    @Bindable var viewModel: WorkboardViewModel

    @Binding var showsOverview: Bool
    @Binding var emptyWorkspaceID: UUID
    @Binding var preferredCompactColumn: NavigationSplitViewColumn

    let isActive: Bool

    @ViewBuilder
    var body: some View {
        if viewModel.isLoading, viewModel.items.isEmpty {
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
        } else if let loadError = viewModel.loadError, viewModel.items.isEmpty {
            WorkboardEmptyState(
                title: LocalizedStringResource(
                    "workboard.load.failed.title",
                    defaultValue: "Work couldn’t open"
                ),
                message: LocalizedStringResource(
                    "workboard.load.failed.message",
                    defaultValue: "Your projects stay private and unchanged. Try opening them again."
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
        } else if let item = viewModel.selectedItem {
            WorkboardDetailView(viewModel: viewModel, itemID: item.id)
                .id(item.id)
        } else if let provisionalID = viewModel.provisionalWorkspaceID {
            captureWorkspace(
                id: provisionalID,
                title: LocalizedStringResource(
                    "workboard.workspace.new.title",
                    defaultValue: "New Work"
                )
            )
            .safeAreaInset(edge: .bottom, spacing: 0) {
                captureBar(itemID: provisionalID, destination: .newWork)
            }
            .workboardPaneDropDestination(
                viewModel: viewModel,
                itemID: provisionalID,
                destination: .newWork
            )
        } else {
            overview
        }
    }

    @ViewBuilder
    private var overview: some View {
        Group {
            if !viewModel.hasVisibleItems {
                emptyBoard
            } else {
                WorkboardProjectCanvas(
                    viewModel: viewModel,
                    onOpen: openItem,
                    onNew: beginNewWorkspace
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppColors.background.ignoresSafeArea())
        .workbenchNavigationTitle(
            Text(LocalizedStringResource(
                "workboard.overview.title",
                defaultValue: "All Work"
            )),
            isActive: isActive
        )
        .safeAreaInset(edge: .bottom, spacing: 0) {
            captureBar(itemID: emptyWorkspaceID, destination: .newWork)
        }
        .workboardPaneDropDestination(
            viewModel: viewModel,
            itemID: emptyWorkspaceID,
            destination: .newWork
        )
    }

    private var emptyBoard: some View {
        Group {
            if viewModel.items.isEmpty {
                captureWorkspace(
                    id: emptyWorkspaceID,
                    title: LocalizedStringResource(
                        "workboard.empty.title",
                        defaultValue: "Start with a thought, file or screenshot"
                    )
                )
            } else {
                WorkboardEmptyState(
                    title: LocalizedStringResource(
                        "workboard.empty.filtered.title",
                        defaultValue: "No work matches"
                    ),
                    message: LocalizedStringResource(
                        "workboard.empty.filtered.message",
                        defaultValue: "Try a different search or show all work. Search stays inside your private board."
                    ),
                    actionTitle: LocalizedStringResource(
                        "workboard.empty.filtered.action",
                        defaultValue: "Clear Search and Filters"
                    )
                ) {
                    viewModel.updateSearchText("")
                    viewModel.filter = .all
                }
            }
        }
    }

    private func openItem(_ item: WorkboardItemSnapshot) {
        openWorkboardItem(
            item,
            viewModel: viewModel,
            showsOverview: $showsOverview,
            preferredCompactColumn: $preferredCompactColumn
        )
    }

    private func beginNewWorkspace() {
        showsOverview = false
        viewModel.beginWorkspace()
        preferredCompactColumn = .detail
    }

    /// Title and board only. The standing "drop something in" line is gone from
    /// every Work canvas: the one-time tutorial teaches capture once, and the
    /// pane-wide drop target is the whole window surface, not a labelled box.
    private func captureWorkspace(
        id: UUID,
        title: LocalizedStringResource
    ) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(title)
                    .font(.largeTitle.bold())
                    .foregroundStyle(AppColors.textEmphasis)
                WorkboardCaptureCanvas(
                    viewModel: viewModel,
                    item: WorkboardItemSnapshot(id: id),
                    mode: .sources
                )
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 24)
            .frame(maxWidth: WorkboardMetrics.contentMaxWidth)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(AppColors.background.ignoresSafeArea())
        .workbenchNavigationTitle(Text(title), isActive: isActive)
    }

    private func captureBar(
        itemID: UUID,
        destination: WorkboardCaptureDestination
    ) -> some View {
        WorkboardCaptureCanvas(
            viewModel: viewModel,
            item: viewModel.item(withID: itemID) ?? WorkboardItemSnapshot(id: itemID),
            mode: .composer,
            destination: destination
        )
        // The bar owns its own inset (Chat's 16/12). Only the full-bleed
        // material belongs to the host: the board scrolls UNDER this inset, so
        // the band has to reach both window edges even though the card does not.
        .background(.ultraThinMaterial)
    }
}

private struct WorkboardSidebarSectionHeader: View {
    let state: WorkItemState
    let count: Int

    var body: some View {
        HStack(spacing: 6) {
            Text(state.attentionTitle)
            Spacer(minLength: 4)
            Text(count, format: .number)
                .font(.caption2.weight(.bold))
        }
        .foregroundStyle(state.tint)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

private struct WorkboardSidebarRow: View {
    let item: WorkboardItemSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(verbatim: item.displayTitle)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                Spacer(minLength: 4)
                if item.isPinned {
                    Image(systemName: "pin.fill")
                        .font(.caption2)
                        .foregroundStyle(AppColors.brandAmber)
                }
            }
            HStack(spacing: 7) {
                Label(item.state.title, systemImage: item.state.systemImage)
                    .foregroundStyle(item.state.tint)
                if item.wasCapturedExternally {
                    Label(
                        LocalizedStringResource(
                            "workboard.workspace.captured",
                            defaultValue: "Captured"
                        ),
                        systemImage: "square.and.arrow.down"
                    )
                    .foregroundStyle(AppColors.brandTeal)
                }
                if !item.materials.isEmpty {
                    Label {
                        Text(item.materials.count, format: .number)
                    } icon: {
                        Image(systemName: "paperclip")
                    }
                }
                Spacer(minLength: 2)
                Text(item.modifiedAt, format: .relative(presentation: .named))
            }
            .font(.caption2)
            .foregroundStyle(AppColors.textTertiary)
            .lineLimit(1)
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }
}

/// The central Work surface follows the sketch literally: projects stay in a
/// movable shelf at the top, while the open space below remains an obvious
/// capture target. Lifecycle is a badge on a project, never a lane the person
/// can accidentally drag the project into.
private struct WorkboardProjectCanvas: View {
    @Bindable var viewModel: WorkboardViewModel
    let onOpen: (WorkboardItemSnapshot) -> Void
    let onNew: () -> Void

    var body: some View {
        let stripItems = viewModel.projectStripItems
        let pinnedItems = stripItems.filter(\.isPinned)
        let projectItems = stripItems.filter { !$0.isPinned }
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 26) {
                if !pinnedItems.isEmpty {
                    projectShelf(
                        title: LocalizedStringResource(
                            "workboard.projectShelf.pinned.title",
                            defaultValue: "Pinned"
                        ),
                        subtitle: LocalizedStringResource(
                            "workboard.projectShelf.pinned.subtitle",
                            defaultValue: "Pinned work keeps its own order"
                        ),
                        items: pinnedItems,
                        includesNewWork: false
                    )
                }

                projectShelf(
                    title: LocalizedStringResource(
                        "workboard.projectShelf.title",
                        defaultValue: "Projects"
                    ),
                    subtitle: LocalizedStringResource(
                        "workboard.projectShelf.subtitle",
                        defaultValue: "Drag projects to arrange them"
                    ),
                    items: projectItems,
                    includesNewWork: true
                )

                // Reads the APPLIED needle, not the field: the canvas body must
                // not rebuild the strip on every character.
                if !viewModel.appliedSearchText.isEmpty {
                    Label(
                        LocalizedStringResource(
                            "workboard.search.private",
                            defaultValue: "Search runs only across your private Workboard"
                        ),
                        systemImage: "lock.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(AppColors.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 22)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private func projectShelf(
        title: LocalizedStringResource,
        subtitle: LocalizedStringResource,
        items: [WorkboardItemSnapshot],
        includesNewWork: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(AppColors.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                Text(items.count, format: .number)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(AppColors.textTertiary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(AppColors.backgroundSecondary, in: Capsule())
                Spacer(minLength: 8)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(AppColors.textTertiary)
            }

            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 0) {
                    if let firstItem = items.first {
                        WorkboardProjectDropRail(
                            viewModel: viewModel,
                            target: firstItem,
                            placement: .before
                        )
                    }

                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        // This shelf IS the move planner's cohort — same pin
                        // group, same `projectStripSort` order — so a neighbour
                        // index test answers exactly what planning a move would.
                        WorkboardReorderCard(
                            viewModel: viewModel,
                            item: item,
                            canMoveEarlier: index > 0,
                            canMoveLater: index + 1 < items.count,
                            onOpen: { onOpen(item) }
                        )

                        WorkboardProjectDropRail(
                            viewModel: viewModel,
                            target: index + 1 < items.count ? items[index + 1] : item,
                            placement: index + 1 < items.count ? .before : .after
                        )
                    }

                    if includesNewWork {
                        newWorkCard
                    }
                }
                .padding(.vertical, 3)
                .padding(.horizontal, 1)
            }
            .scrollIndicators(.hidden)
        }
    }

    private var newWorkCard: some View {
        Button(action: onNew) {
            VStack(spacing: 12) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 32, weight: .semibold))
                    .foregroundStyle(AppColors.brandAmber)
                Text(LocalizedStringResource(
                    "workboard.newBrief",
                    defaultValue: "New Work"
                ))
                .font(.headline)
                .foregroundStyle(AppColors.textPrimary)
                Text(LocalizedStringResource(
                    "workboard.projectShelf.new.caption",
                    defaultValue: "Start with a thought or source"
                ))
                .font(.caption)
                .foregroundStyle(AppColors.textTertiary)
                .multilineTextAlignment(.center)
            }
            .frame(width: 210)
            .frame(minHeight: 142)
            .padding(10)
            .background(AppColors.cardBackground, in: RoundedRectangle(
                cornerRadius: WorkboardMetrics.cardCornerRadius,
                style: .continuous
            ))
            .overlay {
                RoundedRectangle(cornerRadius: WorkboardMetrics.cardCornerRadius, style: .continuous)
                    .stroke(AppColors.brandAmber.opacity(0.38), style: StrokeStyle(lineWidth: 1, dash: [6, 5]))
            }
            .contentShape(RoundedRectangle(cornerRadius: WorkboardMetrics.cardCornerRadius, style: .continuous))
        }
        .choiceCardButton(cornerRadius: WorkboardMetrics.cardCornerRadius)
        .accessibilityHint(Text(LocalizedStringResource(
            "workboard.projectShelf.new.hint",
            defaultValue: "Opens an empty private project canvas"
        )))
    }

}

/// A real gap target makes the resulting position visible before release and
/// gives every shelf explicit leading and trailing destinations. The project
/// card remains a forgiving large drop target; this rail is the precise path.
private struct WorkboardProjectDropRail: View {
    @Bindable var viewModel: WorkboardViewModel
    let target: WorkboardItemSnapshot
    let placement: WorkboardReorderPlacement

    @State private var isTargeted = false

    var body: some View {
        ZStack {
            Capsule()
                .fill(AppColors.brandAmber)
                .frame(width: 3, height: 144)
                .opacity(isTargeted ? 1 : 0)
                .shadow(color: AppColors.brandAmber.opacity(0.45), radius: 5)
        }
        .frame(width: 18)
        .frame(minHeight: 162)
        .contentShape(Rectangle())
        .dropDestination(for: WorkboardCardDragPayload.self) { payloads, _ in
            guard let moving = payloads.first,
                  moving.itemID != target.id,
                  let movingItem = viewModel.item(withID: moving.itemID),
                  movingItem.isPinned == target.isPinned else { return false }
            Task {
                await viewModel.reorderItem(
                    moving.itemID,
                    relativeTo: target.id,
                    placement: placement
                )
            }
            return true
        } isTargeted: { targeted in
            isTargeted = targeted
        }
        .animation(.easeOut(duration: 0.12), value: isTargeted)
        .accessibilityHidden(true)
    }
}

private struct WorkboardReorderCard: View {
    @Bindable var viewModel: WorkboardViewModel
    let item: WorkboardItemSnapshot
    let canMoveEarlier: Bool
    let canMoveLater: Bool
    let onOpen: () -> Void

    @State private var isDropTargeted = false

    var body: some View {
        WorkboardCard(
            item: item,
            onOpen: onOpen,
            onRename: { viewModel.requestRename(item) },
            onTogglePin: { Task { await viewModel.setPinned(!item.isPinned, for: item.id) } },
            onDuplicate: { viewModel.requestDuplicate(item) },
            onDelete: { viewModel.requestDelete(item) },
            onMoveEarlier: moveEarlierAction,
            onMoveLater: moveLaterAction
        )
        .frame(width: 264)
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: WorkboardMetrics.cardCornerRadius, style: .continuous)
                    .strokeBorder(AppColors.brandAmber, lineWidth: 2.5)
                    .allowsHitTesting(false)
            }
        }
        .dropDestination(for: WorkboardCardDragPayload.self) { payloads, location in
            guard let moving = payloads.first,
                  moving.itemID != item.id,
                  let movingItem = viewModel.item(withID: moving.itemID),
                  movingItem.isPinned == item.isPinned else { return false }
            let placement: WorkboardReorderPlacement = location.x < 132 ? .before : .after
            Task {
                await viewModel.reorderItem(
                    moving.itemID,
                    relativeTo: item.id,
                    placement: placement
                )
            }
            return true
        } isTargeted: { targeted in
            isDropTargeted = targeted
        }
        .opacity(viewModel.isReorderingBoard ? 0.78 : 1)
    }

    private var moveEarlierAction: (() -> Void)? {
        guard canMoveEarlier else { return nil }
        return { Task { await viewModel.moveItem(item.id, direction: .earlier) } }
    }

    private var moveLaterAction: (() -> Void)? {
        guard canMoveLater else { return nil }
        return { Task { await viewModel.moveItem(item.id, direction: .later) } }
    }
}
