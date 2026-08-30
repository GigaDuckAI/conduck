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

/// The Work surface split into reusable column content. macOS mounts these two
/// columns inside the app's one persistent split-view shell, while iPad and
/// iPhone continue to use this type's standalone `body`. Keeping the bindings
/// outside the columns means switching Work / Chats never destroys the selected
/// project, provisional canvas, or sidebar state.
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
        presentationHost {
            NavigationSplitView(
                columnVisibility: $columnVisibility,
                preferredCompactColumn: $preferredCompactColumn
            ) {
                sidebarContent
                    .navigationSplitViewColumnWidth(min: 260, ideal: 280, max: 320)
            } detail: {
                detailContent
            }
            .environment(\.workbenchDestinationIsActive, isActive)
        }
    }

    func presentationHost<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .task {
                await viewModel.load()
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
                Task { @MainActor in
                    await dismissTransientPresentations()
                }
            }
            .sheet(isPresented: activeEditorIsPresented) {
                WorkboardEditorView(viewModel: viewModel)
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
    }

    var sidebarContent: some View {
        let visibleItems = viewModel.visibleItems
        let activeItemCount = viewModel.items.lazy.filter { $0.state != .done }.count
        return VStack(spacing: 0) {
            SidebarSearchField(
                text: $viewModel.searchText,
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

            ForEach(sidebarStates, id: \.self) { state in
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
                            .contextMenu {
                                Button {
                                    viewModel.requestDuplicate(item)
                                } label: {
                                    Label(
                                        LocalizedStringResource(
                                            "workboard.action.duplicate",
                                            defaultValue: "Duplicate Work"
                                        ),
                                        systemImage: "plus.square.on.square"
                                    )
                                }
                                Button(role: .destructive) {
                                    viewModel.requestDelete(item)
                                } label: {
                                    Label(
                                        LocalizedStringResource(
                                            "workboard.action.delete",
                                            defaultValue: "Delete Work"
                                        ),
                                        systemImage: "trash"
                                    )
                                }
                            }
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

    @ViewBuilder
    var detailContent: some View {
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
            WorkboardDetailView(
                viewModel: viewModel,
                itemID: item.id,
                newWorkspaceID: emptyWorkspaceID
            )
                .id(item.id)
        } else if let provisionalID = viewModel.provisionalWorkspaceID {
            captureWorkspace(
                id: provisionalID,
                title: LocalizedStringResource(
                    "workboard.workspace.new.title",
                    defaultValue: "New Work"
                ),
                message: LocalizedStringResource(
                    "workboard.workspace.new.message",
                    defaultValue: "Start loosely. Add a thought or drop source material; the project is created only when there is something to keep."
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
            if viewModel.items.isEmpty || viewModel.visibleItems.isEmpty {
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
                    ),
                    message: LocalizedStringResource(
                        "workboard.empty.message",
                        defaultValue: "Collect thoughts, screenshots, files and links here. Nothing leaves Conduck until you review the exact brief and choose a gateway."
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
                    viewModel.searchText = ""
                    viewModel.filter = .all
                }
            }
        }
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

    private func openItem(_ item: WorkboardItemSnapshot) {
        viewModel.briefing = nil
        viewModel.cancelProvisionalWorkspace()
        showsOverview = false
        viewModel.selectedItemID = item.id
        preferredCompactColumn = .detail
    }

    private func beginNewWorkspace() {
        showsOverview = false
        viewModel.beginWorkspace()
        preferredCompactColumn = .detail
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

    private func captureWorkspace(
        id: UUID,
        title: LocalizedStringResource,
        message: LocalizedStringResource
    ) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 7) {
                    Text(title)
                        .font(.largeTitle.bold())
                        .foregroundStyle(AppColors.textEmphasis)
                    Text(message)
                        .font(.body)
                        .foregroundStyle(AppColors.textSecondary)
                }
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
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
    }

    private var sidebarStates: [WorkboardItemState] {
        [.review, .waiting, .draft, .done]
    }

    private var confirmationIsPresented: Binding<Bool> {
        Binding(
            get: { isActive && viewModel.confirmation != nil },
            set: { isPresented in
                if !isPresented || isActive {
                    viewModel.confirmation = isPresented ? viewModel.confirmation : nil
                }
            }
        )
    }

    private var activeEditorIsPresented: Binding<Bool> {
        Binding(
            get: { isActive && viewModel.editorPresented },
            set: { isPresented in
                // A destination change makes the gated getter false. SwiftUI
                // may echo that false back through the binding before the last
                // editor change notification is delivered. Keep the durable
                // presentation bit until `dismissTransientPresentations()` has
                // flushed the draft; ordinary user dismissals still write while
                // Work is active.
                guard isActive else { return }
                viewModel.editorPresented = isPresented
            }
        )
    }

    private var activeBriefingPresentation: Binding<WorkboardBriefingSnapshot?> {
        Binding(
            get: { isActive ? viewModel.briefing : nil },
            set: { briefing in
                if briefing == nil || isActive {
                    viewModel.briefing = briefing
                }
            }
        )
    }

    private var activeNoticePresentation: Binding<WorkboardNotice?> {
        Binding(
            get: { isActive ? viewModel.notice : nil },
            set: { notice in
                // The deactivation helper clears the old alert itself before
                // awaiting the editor flush. Ignore a delayed dismissal write
                // from that old alert while hidden, or it can erase the newer
                // "Draft not saved" notice produced by the flush.
                guard isActive else { return }
                viewModel.notice = notice
            }
        )
    }

    private var preflightIsPresented: Binding<Bool> {
        Binding(
            get: { isActive && viewModel.preflightItemID != nil },
            set: { isPresented in
                if !isPresented || isActive {
                    guard !isPresented else { return }
                    viewModel.preflightItemID = nil
                    viewModel.selectedGatewayID = nil
                    viewModel.excludedMaterialIDs = []
                }
            }
        )
    }

    @MainActor
    private func dismissTransientPresentations() async {
        if viewModel.confirmation != nil { viewModel.confirmation = nil }
        if viewModel.briefing != nil { viewModel.briefing = nil }
        // Clear an older notice before saving, but never clear a failure raised
        // by this final flush: if a route hides Work while the editor is dirty,
        // the editor and its error must both be waiting when the person returns.
        if viewModel.notice != nil { viewModel.notice = nil }
        if viewModel.preflightItemID != nil { viewModel.preflightItemID = nil }
        if viewModel.selectedGatewayID != nil { viewModel.selectedGatewayID = nil }
        if !viewModel.excludedMaterialIDs.isEmpty { viewModel.excludedMaterialIDs = [] }

        guard viewModel.editorPresented else { return }
        // The editor is durable context, unlike the confirmations and dispatch
        // sheets above. Flush it while hidden, then leave the presentation bit
        // intact so a quick Chat -> Work round trip cannot be closed by this
        // older async task after the person has resumed editing.
        _ = await viewModel.saveEditorNow(showFailure: true)
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

private struct WorkboardSidebarSectionHeader: View {
    let state: WorkboardItemState
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

                captureLanding

                if !viewModel.searchText.isEmpty {
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
                        WorkboardReorderCard(
                            viewModel: viewModel,
                            item: item,
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

    private var captureLanding: some View {
        VStack(spacing: 15) {
            ZStack {
                Circle()
                    .fill(AppColors.brandAmber.opacity(0.12))
                    .frame(width: 68, height: 68)
                Image(systemName: "square.and.arrow.down.on.square.fill")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(AppColors.brandAmber)
            }

            VStack(spacing: 5) {
                Text(LocalizedStringResource(
                    "workboard.captureLanding.title",
                    defaultValue: "Drop anything into Work"
                ))
                .font(.title3.weight(.semibold))
                .foregroundStyle(AppColors.textEmphasis)
                Text(LocalizedStringResource(
                    "workboard.captureLanding.caption",
                    defaultValue: "Files, screenshots, photos, links and text become a private new project. Nothing is sent automatically."
                ))
                .font(.subheadline)
                .foregroundStyle(AppColors.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 560)
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { captureKinds }
                VStack(spacing: 8) { captureKinds }
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 28)
        .frame(maxWidth: .infinity, minHeight: 230)
        .background(AppColors.backgroundSecondary.opacity(0.48), in: RoundedRectangle(
            cornerRadius: 20,
            style: .continuous
        ))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(
                    AppColors.borderSubtle,
                    style: StrokeStyle(lineWidth: 1, dash: [8, 6])
                )
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var captureKinds: some View {
        captureKind("doc", LocalizedStringResource(
            "workboard.captureLanding.files",
            defaultValue: "Files"
        ))
        captureKind("photo", LocalizedStringResource(
            "workboard.captureLanding.photos",
            defaultValue: "Photos"
        ))
        captureKind("text.alignleft", LocalizedStringResource(
            "workboard.captureLanding.text",
            defaultValue: "Text"
        ))
        captureKind("link", LocalizedStringResource(
            "workboard.captureLanding.links",
            defaultValue: "Links"
        ))
    }

    private func captureKind(_ systemImage: String, _ title: LocalizedStringResource) -> some View {
        Label(title, systemImage: systemImage)
            .font(.caption.weight(.medium))
            .foregroundStyle(AppColors.textTertiary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(AppColors.cardBackground, in: Capsule())
            .overlay { Capsule().stroke(AppColors.borderSubtle, lineWidth: 1) }
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
    let onOpen: () -> Void

    @State private var isDropTargeted = false

    var body: some View {
        WorkboardCard(
            item: item,
            compact: true,
            onOpen: onOpen,
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
        guard viewModel.canMoveItem(item.id, direction: .earlier) else { return nil }
        return { Task { await viewModel.moveItem(item.id, direction: .earlier) } }
    }

    private var moveLaterAction: (() -> Void)? {
        guard viewModel.canMoveItem(item.id, direction: .later) else { return nil }
        return { Task { await viewModel.moveItem(item.id, direction: .later) } }
    }
}

private struct WorkboardAttentionList: View {
    @Bindable var viewModel: WorkboardViewModel
    let onOpen: (WorkboardItemSnapshot) -> Void

    private let attentionOrder: [WorkboardItemState] = [.review, .waiting, .draft, .done]

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: WorkboardMetrics.generousSpacing) {
                WorkboardFocusStrip(viewModel: viewModel)

                ForEach(attentionOrder, id: \.self) { state in
                    let items = WorkboardPresentationLogic.items(
                        in: state,
                        from: viewModel.visibleItems
                    )
                    if !items.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            WorkboardSectionHeader(
                                state: state,
                                count: items.count,
                                subtitle: sectionSubtitle(state)
                            )
                            ForEach(items) { item in
                                WorkboardCard(
                                    item: item,
                                    compact: true,
                                    onOpen: { onOpen(item) },
                                    onDuplicate: { viewModel.requestDuplicate(item) },
                                    onDelete: { viewModel.requestDelete(item) }
                                )
                            }
                        }
                    }
                }

                if !viewModel.searchText.isEmpty {
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
                    .padding(.top, 8)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 18)
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private func sectionSubtitle(_ state: WorkboardItemState) -> LocalizedStringResource? {
        switch state {
        case .review:
            return LocalizedStringResource("workboard.group.needsYou.subtitle", defaultValue: "Results and send issues")
        case .waiting:
            return LocalizedStringResource("workboard.group.waiting.subtitle", defaultValue: "Requests in progress")
        case .draft:
            return LocalizedStringResource("workboard.group.drafts.subtitle", defaultValue: "Not sent")
        case .done:
            return LocalizedStringResource("workboard.group.done.subtitle", defaultValue: "Closed by you")
        }
    }
}

private struct WorkboardColumnCanvas: View {
    @Bindable var viewModel: WorkboardViewModel
    let onOpen: (WorkboardItemSnapshot) -> Void

    private let laneOrder: [WorkboardItemState] = [.review, .waiting, .draft, .done]

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            VStack(alignment: .leading, spacing: 18) {
                WorkboardFocusStrip(viewModel: viewModel)
                    .frame(maxWidth: 760)

                HStack(alignment: .top, spacing: 16) {
                    ForEach(visibleLanes, id: \.self) { state in
                        column(state)
                    }
                }
            }
            .padding(22)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private var visibleLanes: [WorkboardItemState] {
        let lanes = laneOrder.filter { state in
            viewModel.visibleItems.contains { $0.state == state }
        }
        return lanes.isEmpty ? laneOrder : lanes
    }

    private func column(_ state: WorkboardItemState) -> some View {
        let items = WorkboardPresentationLogic.items(in: state, from: viewModel.visibleItems)
        return VStack(alignment: .leading, spacing: 12) {
            WorkboardSectionHeader(state: state, count: items.count)
                .padding(.horizontal, 4)
            LazyVStack(spacing: 12) {
                ForEach(items) { item in
                    WorkboardCard(
                        item: item,
                        compact: false,
                        onOpen: { onOpen(item) },
                        onDuplicate: { viewModel.requestDuplicate(item) },
                        onDelete: { viewModel.requestDelete(item) }
                    )
                }
                if items.isEmpty {
                    Text(LocalizedStringResource(
                        "workboard.column.empty",
                        defaultValue: "Nothing here"
                    ))
                    .font(.subheadline)
                    .foregroundStyle(AppColors.textTertiary)
                    .frame(maxWidth: .infinity, minHeight: 96)
                    .background(AppColors.cardBackground.opacity(0.55), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
            }
        }
        .padding(12)
        .frame(width: WorkboardMetrics.boardColumnWidth, alignment: .top)
        .background(state.tint.opacity(0.045), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(state.tint.opacity(0.12), lineWidth: 1)
        }
    }
}

private struct WorkboardFocusStrip: View {
    @Bindable var viewModel: WorkboardViewModel

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 10) {
                focusButton(
                    state: .review,
                    filter: .needsYou,
                    count: viewModel.items.filter { $0.state == .review }.count
                )
                focusButton(
                    state: .waiting,
                    filter: .waiting,
                    count: viewModel.items.filter { $0.state == .waiting }.count
                )
                focusButton(
                    state: .draft,
                    filter: .drafts,
                    count: viewModel.items.filter { $0.state == .draft }.count
                )
                Button {
                    viewModel.filter = .open
                } label: {
                    Label(
                        LocalizedStringResource("workboard.focus.allOpen", defaultValue: "All Open"),
                        systemImage: "rectangle.stack"
                    )
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(viewModel.filter == .open ? AppColors.background : AppColors.textSecondary)
                    .padding(.horizontal, 14)
                    .frame(minHeight: WorkboardMetrics.touchTarget)
                    .background(
                        viewModel.filter == .open ? AppColors.textPrimary : AppColors.cardBackground,
                        in: Capsule()
                    )
                    .overlay { Capsule().stroke(AppColors.borderSubtle, lineWidth: 1) }
                }
                .choiceCardButton(cornerRadius: 22)
                .accessibilityAddTraits(viewModel.filter == .open ? .isSelected : [])
            }
        }
        .scrollIndicators(.hidden)
        .accessibilityLabel(Text(LocalizedStringResource(
            "workboard.focus.accessibility",
            defaultValue: "Workboard focus filters"
        )))
    }

    private func focusButton(
        state: WorkboardItemState,
        filter: WorkboardFilter,
        count: Int
    ) -> some View {
        Button {
            viewModel.filter = filter
        } label: {
            HStack(spacing: 8) {
                Image(systemName: state.systemImage)
                    .accessibilityHidden(true)
                Text(state.attentionTitle)
                Text(count, format: .number)
                    .font(.caption.weight(.bold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(state.tint.opacity(viewModel.filter == filter ? 0.22 : 0.12), in: Capsule())
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(viewModel.filter == filter ? AppColors.background : state.tint)
            .padding(.horizontal, 14)
            .frame(minHeight: WorkboardMetrics.touchTarget)
            .background(viewModel.filter == filter ? state.tint : AppColors.cardBackground, in: Capsule())
            .overlay { Capsule().stroke(state.tint.opacity(0.32), lineWidth: 1) }
        }
        .choiceCardButton(cornerRadius: 22)
        .accessibilityAddTraits(viewModel.filter == filter ? .isSelected : [])
        .accessibilityLabel(Text(String.localizedStringWithFormat(
            String(localized: LocalizedStringResource(
                "workboard.focus.accessibility.count",
                defaultValue: "%1$@, %2$lld"
            )),
            String(localized: state.attentionTitle),
            Int64(count)
        )))
    }
}
