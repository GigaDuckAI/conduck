// SPDX-License-Identifier: Apache-2.0

// The responsive management desk: a project rail on wide windows and a picker
// on phones. Search stays in that navigation rail so the canvas remains a desk;
// a compact picker submits its query back to the same global result surface.
// All materials is home; projects focus the same collection. Only the explicit
// brief sheet can create a conversation; deleting a project only ungroups it.

import SwiftUI

struct WorkDeskWorkspaceView: View {
    @Bindable var viewModel: WorkboardViewModel
    let item: WorkboardItemSnapshot
    @Bindable var workspace: WorkDeskWorkspaceState
    @FocusState private var searchFocused: Bool
    @State private var requestsSearchFocus = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.workDeskConversationResolver) private var conversationResolver
    @Environment(\.workDeskSidebarIsHosted) private var sidebarIsHosted
    @Environment(\.workbenchDestinationIsActive) private var isActive

    private var workspaceLayout: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                if geometry.size.width >= 850 && workspace.showsSidebar {
                    projectRail
                        .frame(width: 222)
                        .background(AppColors.cardBackgroundElevated.opacity(0.55))
                        .transition(.move(edge: .leading).combined(with: .opacity))
                    Divider().opacity(0.35)
                }
                VStack(spacing: 0) {
                    header(isCompact: geometry.size.width < 600)
                    workspaceContent
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .onChange(of: geometry.size.width, initial: true) { _, width in
                workspace.updateSidebarLayout(isInline: width >= 850)
            }
        }
    }

    private var effectiveConversationResolver: WorkDeskConversationResolver {
        WorkDeskConversationResolver(resolve: { [weak workspace, resolver = conversationResolver] id in
            workspace?.conversationModel(for: id, resolver: resolver)
        }, reportVisible: conversationResolver.reportVisible)
    }

    @ViewBuilder
    private var workspaceContent: some View {
        if workspace.isShowingConversation {
            if let conversation = workspace.currentConversation,
               let model = workspace.conversationModel(for: conversation.id, resolver: conversationResolver) {
                WorkDeskConversationView(conversation: conversation, viewModel: model,
                    session: workspace.conversationSession(for: conversation.id),
                    settingsVM: workspace.conversationSettings,
                    onVisibilityChanged: conversationResolver.reportVisible)
                    .environment(\.workDeskOpenConversation, { [weak workspace, sourceID = conversation.id] id in
                        guard let workspace, workspace.isActive,
                              workspace.selectedConversationID == sourceID else { return }
                        Task {
                            await workspace.reloadProjectActivity()
                            guard workspace.isActive, workspace.selectedConversationID == sourceID else { return }
                            if let projectID = workspace.projectConversations.first(where: { $0.id == id })?.projectID,
                               workspace.organization.project(id: projectID) != nil {
                                workspace.selectConversation(id, projectID: projectID)
                            }
                        }
                    })
                    .id(conversation.id)
            } else {
                VStack(spacing: 12) {
                    Text(LocalizedStringResource("workdesk.conversation.unavailable", defaultValue: "This conversation couldn’t open."))
                    Button(LocalizedStringResource("workdesk.conversation.back", defaultValue: "Back to project")) {
                        workspace.selectScope(workspace.scope)
                    }.buttonStyle(.bordered)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            WorkboardCaptureCanvas(viewModel: viewModel, item: item,
                mode: .sources, deskWorkspace: workspace)
        }
    }

    private var liveWorkspace: some View {
        workspaceLayout
        .task {
            workspace.isActive = isActive
            await workspace.conversationSettings.loadSettings()
            await reloadOrganization(reconcileResults: true)
        }
        .onAppear { workspace.isActive = isActive }
        .onDisappear { workspace.suspend() }
        .onChange(of: item.materials) { _, _ in workspace.reconcile(materials: item.materials) }
        .onChange(of: workspace.search) { _, _ in workspace.reconcile(materials: item.materials) }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active && isActive { Task { await reloadOrganization(reconcileResults: true) } }
        }
        .onChange(of: isActive) { _, active in
            workspace.isActive = active
            if active { Task { await reloadOrganization(reconcileResults: true) } }
            else {
                searchFocused = false
                requestsSearchFocus = false
                workspace.suspend()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .conversationsDidChange)) { _ in
            if isActive { Task { await reloadOrganization() } }
        }
        .onReceive(NotificationCenter.default.publisher(for: .settingsDidChangeRemotely)) { _ in
            if isActive { Task { await workspace.conversationSettings.loadSettings() } }
        }
    }

    private var presentedWorkspace: some View {
        liveWorkspace
        .sheet(isPresented: Binding(
            get: { isActive && workspace.showsProjectPicker },
            set: { if isActive { workspace.showsProjectPicker = $0 } }
        ), onDismiss: workspace.projectPickerDidDismiss) {
            NavigationStack {
                projectRail
                    .navigationTitle(Text(LocalizedStringResource("workdesk.projects", defaultValue: "Projects")))
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button(LocalizedStringResource("common.done", defaultValue: "Done")) {
                                workspace.showsProjectPicker = false
                            }
                        }
                    }
            }
            .presentationDetents([.medium, .large])
        }
        .sheet(item: Binding(
            get: { isActive ? workspace.projectEditor : nil },
            set: { if isActive { workspace.projectEditor = $0 } }
        )) { request in
            WorkDeskProjectEditor(request: request, organization: workspace.organization, title: $workspace.editorTitle) { _ in
                if request.project == nil { workspace.selectScope(.all) }
            }
        }
        .sheet(isPresented: Binding(
            get: { isActive && workspace.editingContextProjectID != nil },
            set: { if !$0 { workspace.editingContextProjectID = nil } }
        )) {
            if let id = workspace.editingContextProjectID,
               let project = workspace.organization.project(id: id) {
                WorkDeskProjectContextEditor(project: project, organization: workspace.organization) { updated in
                    workspace.briefDrafts[id]?.refreshProjectContext(updated.brief)
                    workspace.briefRevisions[id] = updated.updatedAt
                }
            }
        }
        .sheet(isPresented: Binding(
            get: { isActive && workspace.preparingProjectID != nil },
            set: { if isActive && !$0 { workspace.preparingProjectID = nil } }
        )) {
            if let id = workspace.preparingProjectID,
               let project = workspace.organization.projects.first(where: { $0.id == id }),
               let draft = workspace.briefDrafts[id] {
                WorkDeskBriefHost(project: project,
                    materials: item.materials.filter { workspace.organization.projectID(for: $0.id) == id },
                    workspace: workspace,
                    draft: draft,
                    onOpenConversation: { conversationID in
                        guard workspace.isActive else { return }
                        workspace.preparingProjectID = nil
                        workspace.finishConversationDraft(projectID: id)
                        workspace.selectConversation(conversationID, projectID: id)
                        Task { await workspace.reloadProjectActivity() }
                    }
                )
            } else {
                VStack(spacing: 16) {
                    Text(LocalizedStringResource("workdesk.project.unavailable", defaultValue: "This project is no longer available. Your materials are still in All materials."))
                    Button(LocalizedStringResource("common.done", defaultValue: "Done")) { workspace.preparingProjectID = nil }
                        .buttonStyle(.bordered)
                }.padding(24)
            }
        }
    }

    var body: some View {
        presentedWorkspace
        .background {
            Button(LocalizedStringResource("workdesk.search", defaultValue: "Find an idea or file")) {
                requestsSearchFocus = true
                if workspace.presentsSidebarInline { workspace.showsSidebar = true }
                else { workspace.showsProjectPicker = true }
                searchFocused = true
            }
            .keyboardShortcut("f", modifiers: .command)
            .disabled(!isActive)
            .hidden()
        }
        .alert(Text(LocalizedStringResource("workdesk.update.failed", defaultValue: "Couldn’t update the desk")),
               isPresented: Binding(
                get: { isActive && workspace.organization.errorMessage != nil && workspace.projectEditor == nil && workspace.preparingProjectID == nil },
                set: { if !$0 { workspace.organization.errorMessage = nil } }
               )) {
            Button(LocalizedStringResource("common.ok", defaultValue: "OK")) {
                workspace.organization.errorMessage = nil
            }
        } message: {
            Text(verbatim: workspace.organization.errorMessage ?? "")
        }
        .confirmationDialog(
            Text(LocalizedStringResource("workdesk.project.delete.title", defaultValue: "Ungroup this project?")),
            isPresented: Binding(
                get: { isActive && workspace.deletingProjectID != nil },
                set: { if !$0 { workspace.deletingProjectID = nil } }
            ), titleVisibility: .visible
        ) {
            Button(LocalizedStringResource("workdesk.project.ungroup", defaultValue: "Ungroup Project"), role: .destructive) {
                guard let id = workspace.deletingProjectID else { return }
                workspace.deletingProjectID = nil
                Task {
                    if await workspace.organization.deleteProject(id: id) {
                        workspace.selectScope(.all)
                    }
                }
            }
        } message: {
            Text(LocalizedStringResource("workdesk.project.delete.message", defaultValue: "Its ideas and files will stay in All materials. Nothing is deleted."))
        }
    }

    private func reloadOrganization(reconcileResults: Bool = false) async {
        await workspace.organization.reload()
        await workspace.reloadProjectActivity(reconcileResults: reconcileResults)
        workspace.reconcile(materials: item.materials)
    }

    private var title: String {
        if workspace.isSearching {
            return String(localized: LocalizedStringResource("workdesk.search.results", defaultValue: "Search results"))
        }
        return switch workspace.scope {
        case .all: String(localized: LocalizedStringResource("workdesk.all", defaultValue: "All materials"))
        case .project: workspace.currentProject?.title ?? ""
        }
    }

    /// Project actions and collection tools occupy separate, quiet rows.
    /// Selecting materials organizes them; only the conversation sheet chooses
    /// what leaves the device. Compact windows retain a named primary action.
    private func header(isCompact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    projectIdentity
                    Spacer(minLength: 8)
                    if showsNewConversation { newConversationButton }
                }
                VStack(alignment: .leading, spacing: 4) {
                    projectIdentity
                    if showsNewConversation {
                        HStack { Spacer(); newConversationButton }
                    }
                }
            }
            if let project = workspace.currentProject, !workspace.isSearching, !workspace.isShowingConversation {
                Button { workspace.editingContextProjectID = project.id } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "text.alignleft")
                        Text(WorkDeskCopy.projectBriefState(hasBrief: !project.brief.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
                        if !project.brief.isEmpty {
                            Text(verbatim: project.brief).lineLimit(1).foregroundStyle(AppColors.textTertiary)
                        }
                    }.font(.caption).padding(.vertical, 6)
                }
                .inlineLinkButton()
                .foregroundStyle(AppColors.textSecondary)
                .accessibilityIdentifier("workdesk-project-context")
            }
            if workspace.isShowingConversation {
                if let conversation = workspace.currentConversation {
                    HStack {
                        Text(verbatim: conversation.displayTitle).font(.headline).lineLimit(1)
                        Spacer()
                        Text(verbatim: gatewayName(for: conversation)).font(.caption).foregroundStyle(AppColors.textSecondary)
                    }.padding(.vertical, 6)
                }
            } else {
                materialControls
            }
            if let error = workspace.conversationLoadError {
                HStack {
                    Text(verbatim: error).font(.caption)
                    Button(LocalizedStringResource("common.retry", defaultValue: "Try again")) {
                        Task { await workspace.reloadProjectActivity() }
                    }.inlineLinkButton()
                }.foregroundStyle(AppColors.textSecondary)
            }
        }
        .padding(.horizontal, 16).padding(.bottom, 8)
        .background(AppColors.background)
    }

    private var showsNewConversation: Bool {
        workspace.currentProject != nil && !workspace.isSearching && !workspace.isSelecting
    }

    private var projectIdentity: some View {
        HStack(spacing: 6) {
            if !sidebarIsHosted {
                Button {
                    withAnimation(reduceMotion ? nil : .snappy(duration: 0.22)) { workspace.toggleProjectNavigation() }
                } label: { Image(systemName: "sidebar.left").frame(width: 40, height: 40) }
                .pointerIconButton(size: 40)
                .accessibilityLabel(Text(LocalizedStringResource("workdesk.projects.browse", defaultValue: "Browse projects")))
            }
            if workspace.isShowingConversation {
                Button { workspace.selectScope(workspace.scope) } label: {
                    Label { Text(verbatim: title).lineLimit(1) } icon: { Image(systemName: "chevron.left") }
                        .font(.headline).padding(.vertical, 8)
                }.inlineLinkButton()
                .accessibilityHint(Text(LocalizedStringResource("workdesk.conversation.back", defaultValue: "Back to project")))
            } else {
                Text(verbatim: title).font(.headline).lineLimit(1)
            }
            if workspace.currentProject != nil && !workspace.isSearching { workspaceMenu() }
            if workspace.isSearching {
                Button { workspace.search = ""; searchFocused = false } label: {
                    Image(systemName: "xmark").frame(width: 40, height: 40)
                }.pointerIconButton(size: 40)
                .accessibilityLabel(Text(LocalizedStringResource("workdesk.search.clear", defaultValue: "Clear search")))
            }
        }
    }

    private var newConversationButton: some View {
        Button {
            guard let project = workspace.currentProject else { return }
            _ = workspace.briefDraft(for: project, resolver: effectiveConversationResolver)
            workspace.preparingProjectID = project.id
        } label: {
            Text(LocalizedStringResource("workdesk.conversation.new", defaultValue: "New conversation…"))
                .font(.subheadline.weight(.semibold)).fixedSize()
                .padding(.horizontal, 14).frame(minHeight: 40)
                .background(AppColors.accent, in: Capsule()).foregroundStyle(.black)
        }
        .primaryCTAButton()
        .accessibilityIdentifier("workdesk-prepare")
    }

    private var materialControls: some View {
        VStack(alignment: .leading, spacing: 4) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    materialCount
                    Spacer(minLength: 8)
                    materialActions
                }
                VStack(alignment: .leading, spacing: 0) {
                    materialCount
                    HStack { Spacer(minLength: 0); materialActions }
                }
            }
            if workspace.isSelecting && !workspace.selectedIDs.isEmpty { selectionBar }
        }
    }

    private var materialCount: some View {
        Text(WorkDeskCopy.materialCount(workspace.visibleMaterials(in: item.materials).count))
            .font(.caption).foregroundStyle(AppColors.textSecondary).fixedSize()
    }

    @ViewBuilder
    private var materialActions: some View {
        if !workspace.isSelecting {
            WorkDeskLayoutControl(viewModel: viewModel, supportsSpatialLayout: workspace.supportsSpatialLayout)
        }
        if !workspace.visibleMaterials(in: item.materials).isEmpty { selectionControls }
    }

    private var selectionControls: some View {
        HStack(spacing: 8) {
            if workspace.isSelecting {
                Button(LocalizedStringResource("workdesk.select.all", defaultValue: "Select all")) {
                    workspace.selectedIDs = Set(workspace.visibleMaterials(in: item.materials).map(\.id))
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("workdesk-select-all")
            }
            Button {
                workspace.isSelecting.toggle()
                if !workspace.isSelecting { workspace.selectedIDs = [] }
            } label: {
                Text(workspace.isSelecting
                    ? LocalizedStringResource("common.done", defaultValue: "Done")
                    : LocalizedStringResource("workdesk.select", defaultValue: "Select"))
                    .font(.subheadline)
                    .fixedSize()
                    .padding(.horizontal, 10)
                    .frame(minHeight: 40)
            }
            .inlineLinkButton()
            .foregroundStyle(workspace.isSelecting ? AppColors.accent : AppColors.textSecondary)
            .accessibilityIdentifier("workdesk-select")
        }
    }

    // This is an explicit rail, not a NavigationSplitView column. SwiftUI's
    // searchable(.sidebar) would fall back into the window toolbar here.
    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(AppColors.textTertiary)
            TextField(text: $workspace.search) {
                Text(LocalizedStringResource("workdesk.search", defaultValue: "Find an idea or file"))
            }
            .textFieldStyle(.plain)
            .focused($searchFocused)
            .submitLabel(.search)
            .onSubmit {
                searchFocused = false
                workspace.showsProjectPicker = false
            }
            .accessibilityIdentifier("workdesk-search")
            if !workspace.search.isEmpty {
                Button { workspace.search = ""; searchFocused = true } label: {
                    Image(systemName: "xmark.circle.fill").frame(width: 32, height: 36)
                }
                .pointerIconButton(size: 32)
                .accessibilityLabel(Text(LocalizedStringResource("workdesk.search.clear", defaultValue: "Clear search")))
            }
        }
        .font(.subheadline)
        .padding(.leading, 12).padding(.trailing, 4).frame(minHeight: 40)
        .background(AppColors.cardBackgroundElevated, in: RoundedRectangle(cornerRadius: 10))
        .onAppear {
            if requestsSearchFocus { searchFocused = true; requestsSearchFocus = false }
        }
    }

    /// Infrequent project actions stay beside the project name. Layout belongs
    /// exclusively to the responsive material row at every window width.
    private func workspaceMenu() -> some View {
        Menu {
            if let project = workspace.currentProject {
                Button(LocalizedStringResource("workdesk.project.rename", defaultValue: "Rename project"), systemImage: "pencil") {
                    workspace.editProject(project)
                }
                Button(LocalizedStringResource("workdesk.project.ungroup", defaultValue: "Ungroup Project"), systemImage: "rectangle.stack.badge.minus") {
                    workspace.deletingProjectID = project.id
                }
            }
        } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }
        .pointerIconButton(size: 44)
        .accessibilityLabel(Text(LocalizedStringResource("workdesk.options", defaultValue: "Desk options")))
    }

    private var selectionBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                Text(LocalizedStringResource("workdesk.selected.count", defaultValue: "\(workspace.selectedIDs.count) selected"))
                    .font(.caption.monospacedDigit())
                Button(LocalizedStringResource("workdesk.group", defaultValue: "Create project"), systemImage: "folder.badge.plus") {
                    workspace.beginProject(materialIDs: item.materials.map(\.id).filter { workspace.selectedIDs.contains($0) })
                }.buttonStyle(.bordered).disabled(workspace.selectedIDs.isEmpty)
                Menu {
                    if workspace.selectedIDs.contains(where: { workspace.organization.projectID(for: $0) != nil }) {
                        Button(LocalizedStringResource("workdesk.removeFromProject", defaultValue: "Remove from project")) {
                            Task { await workspace.assignSelection(to: nil, materials: item.materials) }
                        }
                    }
                    ForEach(workspace.organization.projects) { project in
                        Button { Task { await workspace.assignSelection(to: project.id, materials: item.materials) } }
                        label: { Text(verbatim: project.title) }
                    }
                } label: { Label(LocalizedStringResource("workdesk.move", defaultValue: "Move to"), systemImage: "folder") }
                .buttonStyle(.bordered)
                .disabled(workspace.organization.projects.isEmpty)
            }
            .controlSize(.small)
            .padding(.vertical, 2)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private var projectRail: some View {
        let counts = workspace.organization.materialCounts(in: item.materials)
        return VStack(spacing: 0) {
            searchField.padding(12)
            if !workspace.presentsSidebarInline && workspace.isSearching {
                Button(LocalizedStringResource("workdesk.search.show", defaultValue: "Show results")) {
                    searchFocused = false
                    workspace.showsProjectPicker = false
                }
                .buttonStyle(.borderedProminent)
                .padding(.bottom, 8)
            }
            ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                railRow(title: String(localized: LocalizedStringResource("workdesk.all", defaultValue: "All materials")), symbol: "tray.full", scope: .all, count: item.materials.count)
                HStack {
                    Text(LocalizedStringResource("workdesk.projects", defaultValue: "Projects"))
                        .font(.caption.weight(.semibold)).foregroundStyle(AppColors.textTertiary)
                    Spacer()
                    Button {
                        workspace.beginProject()
                    } label: { Image(systemName: "plus").frame(width: 44, height: 44) }
                    .pointerIconButton(size: 44)
                    .accessibilityLabel(Text(LocalizedStringResource("workdesk.project.new", defaultValue: "New project")))
                }.padding(.leading, 12).padding(.top, 18)
                ForEach(workspace.organization.projects) { project in
                    projectNavigationRow(project, count: counts[project.id] ?? 0)
                }
                if workspace.organization.projects.isEmpty {
                    Text(LocalizedStringResource("workdesk.projects.empty", defaultValue: "Bring related ideas together. Select a few cards to create your first project."))
                        .font(.caption).foregroundStyle(AppColors.textSecondary)
                        .padding(12)
                }
            }
            .padding(12)
        }
            .scrollDismissesKeyboard(.interactively)
        }
    }

    private func gatewayName(for conversation: ConversationRecord) -> String {
        guard let ref = RemoteAgentRef(rawString: conversation.backend) else {
            return String(localized: "workdesk.conversation.connectionMissing", defaultValue: "Connection unavailable")
        }
        return RemoteAgentRefMetadata.displayName(for: ref, customs: workspace.conversationSettings.customGateways)
    }

    private func projectNavigationRow(_ project: WorkDeskProjectRecord, count: Int) -> some View {
        let conversations = workspace.conversations(in: project.id)
        let expanded = workspace.expandedProjectIDs.contains(project.id)
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 0) {
                if !conversations.isEmpty {
                    Button {
                        if expanded { workspace.expandedProjectIDs.remove(project.id) }
                        else { workspace.expandedProjectIDs.insert(project.id) }
                    } label: {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.caption).frame(width: 28, height: 40)
                    }.pointerIconButton(size: 28)
                    .accessibilityLabel(Text(LocalizedStringResource("workdesk.conversations.toggle", defaultValue: "Show or hide project conversations")))
                    .accessibilityValue(Text(expanded ? LocalizedStringResource("workdesk.expanded", defaultValue: "Expanded") : LocalizedStringResource("workdesk.collapsed", defaultValue: "Collapsed")))
                }
                railRow(title: project.title, symbol: "folder", scope: .project(project.id), count: count)
            }
            .contextMenu {
                Button(LocalizedStringResource("workdesk.project.rename", defaultValue: "Rename project")) { workspace.editProject(project) }
                Button(LocalizedStringResource("workdesk.project.ungroup", defaultValue: "Ungroup Project")) { workspace.deletingProjectID = project.id }
            }
            if expanded {
                ForEach(conversations) { conversation in
                    let tail = TailProjection.read(conversation.tailProjection, lastActivityAt: conversation.lastActivityAt)
                    let state = ConversationRowActivity.state(inputs: ConversationActivityInputs(record: conversation, tailRole: tail.role), conversationID: conversation.id)
                    Button { workspace.selectConversation(conversation.id, projectID: project.id) } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "bubble.left").font(.caption)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(verbatim: conversation.displayTitle).font(.subheadline).lineLimit(2)
                                Text(verbatim: gatewayName(for: conversation)).font(.caption2).foregroundStyle(AppColors.textTertiary)
                            }
                            Spacer(minLength: 0)
                            ConversationActivityMark(state: state, conversationID: conversation.id, now: Date())
                        }
                        .padding(.leading, 28).padding(.trailing, 8).padding(.vertical, 8)
                        .background(workspace.selectedConversationID == conversation.id ? AppColors.accent.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 10))
                    }.choiceCardButton(cornerRadius: 10)
                    .accessibilityAddTraits(workspace.selectedConversationID == conversation.id ? .isSelected : [])
                }
            }
        }
    }

    private func railRow(title: String, symbol: String, scope: WorkDeskScope, count: Int) -> some View {
        Button { workspace.selectScope(scope) } label: {
            HStack(spacing: 10) {
                Image(systemName: symbol).frame(width: 20).foregroundStyle(workspace.scope == scope && !workspace.isShowingConversation ? AppColors.accent : AppColors.textSecondary)
                Text(verbatim: title).font(.subheadline.weight(.medium)).lineLimit(2)
                Spacer(minLength: 4)
                Text(verbatim: String(count)).font(.caption.monospacedDigit()).foregroundStyle(AppColors.textTertiary)
            }
            .padding(.horizontal, 12).frame(minHeight: 46)
            .background(workspace.scope == scope && !workspace.isShowingConversation ? AppColors.accent.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 12))
        }
        .choiceCardButton(cornerRadius: 12)
        .accessibilityAddTraits(workspace.scope == scope && !workspace.isShowingConversation ? .isSelected : [])
    }
}

private struct WorkDeskProjectEditor: View {
    let request: WorkDeskProjectEditorRequest
    let organization: WorkDeskOrganization
    @Binding var title: String
    let onCreated: (UUID) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var isSaving = false
    @State private var error: String?
    @FocusState private var titleFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(text: $title) {
                        Text(LocalizedStringResource("workdesk.project.name", defaultValue: "Project name"))
                    }
                    .focused($titleFocused)
                    .submitLabel(.done)
                    .onSubmit { save() }
                } footer: {
                    Text(LocalizedStringResource("workdesk.project.create.explanation", defaultValue: "A home for related ideas, files and the brief you’ll shape from them."))
                }
                if let error { Text(verbatim: error).foregroundStyle(.red) }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(Text(request.project == nil
                ? LocalizedStringResource("workdesk.project.new", defaultValue: "New project")
                : LocalizedStringResource("workdesk.project.rename", defaultValue: "Rename project")))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(LocalizedStringResource("common.cancel", defaultValue: "Cancel")) { dismiss() }
                        .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(LocalizedStringResource("common.save", defaultValue: "Save")) { save() }
                        .disabled(isSaving || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .frame(minWidth: 300, idealWidth: 420, minHeight: 240)
        .presentationDetents([.medium])
        .interactiveDismissDisabled(isSaving)
        .onAppear { titleFocused = true }
    }

    private func save() {
        guard !isSaving, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        isSaving = true
        titleFocused = false
        Task {
            let savedID: UUID?
            if let project = request.project {
                let saved = await organization.updateProject(id: project.id, title: title,
                    brief: project.brief, preferredGatewayRef: project.preferredGatewayRef, expectedUpdatedAt: project.updatedAt)
                savedID = saved ? project.id : nil
            } else {
                savedID = await organization.createProject(title: title, materialIDs: request.materialIDs, position: request.position)
            }
            isSaving = false
            if let savedID { onCreated(savedID); dismiss() }
            else { error = organization.errorMessage; organization.errorMessage = nil }
        }
    }
}

// A sheet holds its own edit revision across parent refreshes. An unrelated
// iCloud edit cannot silently become the new baseline for text already typed;
// only this sheet's successful save advances its optimistic-concurrency token.
private struct WorkDeskBriefHost: View {
    let project: WorkDeskProjectRecord
    let materials: [WorkboardMaterialSnapshot]
    let workspace: WorkDeskWorkspaceState
    let draft: WorkDeskBriefDraft
    let onOpenConversation: (UUID) -> Void

    var body: some View {
        WorkDeskBriefView(projectID: project.id, title: project.title,
            initialBrief: project.brief, preferredGatewayRef: project.preferredGatewayRef,
            materials: materials, draft: draft,
            onSave: { brief, gateway in
                let saved = await workspace.organization.updateProject(id: project.id, title: project.title,
                    brief: brief, preferredGatewayRef: gateway,
                    expectedUpdatedAt: workspace.briefRevisions[project.id] ?? project.updatedAt)
                if saved, let updated = workspace.organization.projects.first(where: { $0.id == project.id }) {
                    workspace.briefRevisions[project.id] = updated.updatedAt
                }
                return saved
            }, onOpenConversation: onOpenConversation,
            onEndEditing: { workspace.endBriefEditing(projectID: project.id) })
    }
}
