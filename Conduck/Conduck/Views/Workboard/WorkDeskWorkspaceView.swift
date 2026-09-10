// SPDX-License-Identifier: Apache-2.0

// The responsive management desk: a project rail on wide windows and a picker
// on phones, with equivalent selection actions beside the spatial canvas.
// Capturing remains independent of the selected project. Only the explicit
// brief sheet can create a conversation; deleting a project only ungroups it.

import SwiftUI

struct WorkDeskWorkspaceView: View {
    @Bindable var viewModel: WorkboardViewModel
    let item: WorkboardItemSnapshot
    @Bindable var workspace: WorkDeskWorkspaceState
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
                    header(isWide: geometry.size.width >= 850)
                    WorkboardCaptureCanvas(
                        viewModel: viewModel,
                        item: item,
                        mode: .sources,
                        deskWorkspace: workspace
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .onChange(of: geometry.size.width, initial: true) { _, width in
                workspace.updateSidebarLayout(isInline: width >= 850)
            }
        }
    }

    private var liveWorkspace: some View {
        workspaceLayout
        .task { workspace.isActive = isActive; await reloadOrganization() }
        .onAppear { workspace.isActive = isActive }
        .onDisappear { workspace.suspend() }
        .onChange(of: item.materials) { _, _ in workspace.reconcile(materials: item.materials) }
        .onChange(of: workspace.search) { _, _ in workspace.reconcile(materials: item.materials) }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active && isActive { Task { await reloadOrganization() } }
        }
        .onChange(of: isActive) { _, active in
            workspace.isActive = active
            if active { Task { await reloadOrganization() } }
            else { workspace.suspend() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .conversationsDidChange)) { _ in
            if isActive { Task { await reloadOrganization() } }
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
            WorkDeskProjectEditor(request: request, organization: workspace.organization, title: $workspace.editorTitle) { id in
                workspace.selectScope(.project(id))
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
                        NotificationCenter.default.post(
                            name: .openConversationDeepLink,
                            object: nil,
                            userInfo: [NotificationDeepLink.conversationIDKey: conversationID.uuidString]
                        )
                    }
                )
            } else {
                VStack(spacing: 16) {
                    Text(LocalizedStringResource("workdesk.project.unavailable", defaultValue: "This project is no longer available. Your materials are still on the desk."))
                    Button(LocalizedStringResource("common.done", defaultValue: "Done")) { workspace.preparingProjectID = nil }
                        .buttonStyle(.bordered)
                }.padding(24)
            }
        }
    }

    var body: some View {
        presentedWorkspace
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
                        workspace.selectScope(.desk)
                    }
                }
            }
        } message: {
            Text(LocalizedStringResource("workdesk.project.delete.message", defaultValue: "Its ideas and files will return to your desk. Nothing is deleted."))
        }
    }

    private func reloadOrganization() async {
        await workspace.organization.reload()
        workspace.reconcile(materials: item.materials)
    }

    private var title: String {
        switch workspace.scope {
        case .desk: String(localized: LocalizedStringResource("workdesk.desk", defaultValue: "Your desk"))
        case .all: String(localized: LocalizedStringResource("workdesk.all", defaultValue: "All materials"))
        case .pinned: String(localized: LocalizedStringResource("workdesk.pinned", defaultValue: "Pinned"))
        case .project: workspace.currentProject?.title ?? ""
        }
    }

    private func header(isWide: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                if !sidebarIsHosted {
                    Button {
                        withAnimation(reduceMotion ? nil : .snappy(duration: 0.22)) {
                            workspace.toggleProjectNavigation()
                        }
                    } label: {
                        Image(systemName: "sidebar.left")
                            .frame(width: 44, height: 44)
                    }
                    .pointerIconButton(size: 44)
                    .accessibilityLabel(Text(LocalizedStringResource("workdesk.projects.browse", defaultValue: "Browse projects")))
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: title).font(.title3.weight(.semibold)).lineLimit(1)
                    Text(WorkDeskCopy.materialCount(workspace.visibleMaterials(in: item.materials).count))
                        .font(.caption).foregroundStyle(AppColors.textSecondary)
                }
                Spacer(minLength: 0)
                if isWide {
                    WorkDeskLayoutControl(viewModel: viewModel,
                        supportsSpatialLayout: workspace.supportsSpatialLayout)
                }
                if workspace.currentProject != nil {
                    Button {
                        guard let project = workspace.currentProject else { return }
                        _ = workspace.briefDraft(for: project, resolver: conversationResolver)
                        workspace.preparingProjectID = project.id
                    } label: {
                        Label(LocalizedStringResource("workdesk.prepare", defaultValue: "Prepare"), systemImage: "arrow.up.forward")
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 12).frame(height: 40)
                            .background(AppColors.accent, in: Capsule())
                            .foregroundStyle(.black)
                    }
                    .primaryCTAButton()
                    .accessibilityIdentifier("workdesk-prepare")
                } else {
                    Button { workspace.beginProject() } label: {
                        Image(systemName: "folder.badge.plus").frame(width: 44, height: 44)
                    }
                    .pointerIconButton(size: 44)
                    .accessibilityLabel(Text(LocalizedStringResource("workdesk.project.new", defaultValue: "New project")))
                }
                if workspace.currentProject != nil { workspaceMenu }
            }
            HStack(spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(AppColors.textTertiary)
                    TextField(text: $workspace.search) {
                        Text(LocalizedStringResource("workdesk.search", defaultValue: "Find an idea or file"))
                    }
                    .textFieldStyle(.plain)
                    .submitLabel(.search)
                    .onSubmit {
                        #if os(iOS)
                        KeyboardDismissal.dismissKeyboard()
                        #endif
                    }
                }
                .font(.subheadline)
                .padding(.horizontal, 12).frame(height: 38)
                .background(AppColors.cardBackgroundElevated, in: RoundedRectangle(cornerRadius: 11))

                Button {
                    workspace.isSelecting.toggle()
                    if !workspace.isSelecting { workspace.selectedIDs = [] }
                } label: {
                    Text(workspace.isSelecting
                         ? LocalizedStringResource("common.done", defaultValue: "Done")
                         : LocalizedStringResource("workdesk.select", defaultValue: "Select"))
                        .font(.subheadline.weight(.medium)).frame(minHeight: 44)
                }
                .pointerIconButton(size: 44, horizontalPadding: 8)
                .foregroundStyle(AppColors.accent)
            }
            if !isWide {
                HStack {
                    WorkDeskLayoutControl(viewModel: viewModel,
                        supportsSpatialLayout: workspace.supportsSpatialLayout)
                    Spacer(minLength: 0)
                }
            }
            if workspace.isSelecting { selectionBar }
            if workspace.scope == .all || workspace.scope == .pinned {
                Text(LocalizedStringResource("workdesk.aggregate.hint", defaultValue: "A readable overview across projects. Open a project to arrange its cards."))
                    .font(.caption).foregroundStyle(AppColors.textTertiary)
            }
            if workspace.currentProject != nil {
                Text(LocalizedStringResource("workdesk.capture.destination", defaultValue: "New captures land on your desk. Move them into a project whenever you’re ready."))
                    .font(.caption).foregroundStyle(AppColors.textTertiary)
            }
        }
        .padding(.horizontal, 16).padding(.bottom, 12)
        .background(AppColors.background)
    }

    private var workspaceMenu: some View {
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
                Button(LocalizedStringResource("workdesk.select.all", defaultValue: "Select all")) {
                    workspace.selectedIDs = Set(workspace.visibleMaterials(in: item.materials).map(\.id))
                }.buttonStyle(.bordered)
                Button(LocalizedStringResource("workdesk.group", defaultValue: "Create project"), systemImage: "folder.badge.plus") {
                    workspace.beginProject(materialIDs: item.materials.map(\.id).filter { workspace.selectedIDs.contains($0) })
                }.buttonStyle(.bordered).disabled(workspace.selectedIDs.isEmpty)
                Menu {
                    Button(LocalizedStringResource("workdesk.return", defaultValue: "Return to desk")) {
                        Task { await workspace.assignSelection(to: nil, materials: item.materials) }
                    }
                    ForEach(workspace.organization.projects) { project in
                        Button { Task { await workspace.assignSelection(to: project.id, materials: item.materials) } }
                        label: { Text(verbatim: project.title) }
                    }
                } label: { Label(LocalizedStringResource("workdesk.move", defaultValue: "Move to"), systemImage: "folder") }
                .buttonStyle(.bordered).disabled(workspace.selectedIDs.isEmpty)
                Button(LocalizedStringResource("workdesk.pin.selection", defaultValue: "Pin selected"), systemImage: "pin") {
                    let ids = workspace.selectedIDs
                    Task { for id in ids { await workspace.organization.setPinned(true, materialID: id) } }
                }.buttonStyle(.bordered).disabled(workspace.selectedIDs.isEmpty)
            }
            .controlSize(.small)
            .padding(.vertical, 2)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private var projectRail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                railRow(title: String(localized: LocalizedStringResource("workdesk.desk", defaultValue: "Your desk")), symbol: "square.grid.2x2", scope: .desk,
                        count: item.materials.filter { workspace.organization.projectID(for: $0.id) == nil }.count)
                railRow(title: String(localized: LocalizedStringResource("workdesk.all", defaultValue: "All materials")), symbol: "tray.full", scope: .all, count: item.materials.count)
                railRow(title: String(localized: LocalizedStringResource("workdesk.pinned", defaultValue: "Pinned")), symbol: "pin", scope: .pinned,
                        count: item.materials.filter { workspace.organization.placements[$0.id]?.isPinned == true }.count)
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
                    railRow(title: project.title, symbol: project.isPinned ? "pin.fill" : "folder", scope: .project(project.id),
                            count: item.materials.filter { workspace.organization.projectID(for: $0.id) == project.id }.count)
                        .contextMenu {
                            Button(LocalizedStringResource("workdesk.project.rename", defaultValue: "Rename project")) {
                                workspace.editProject(project)
                            }
                            Button(LocalizedStringResource("workdesk.project.pin.toggle", defaultValue: "Toggle project pin")) {
                                Task { await workspace.organization.setProjectPinned(!project.isPinned, id: project.id) }
                            }
                            Button(LocalizedStringResource("workdesk.project.ungroup", defaultValue: "Ungroup Project")) {
                                workspace.deletingProjectID = project.id
                            }
                        }
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

    private func railRow(title: String, symbol: String, scope: WorkDeskScope, count: Int) -> some View {
        Button { workspace.selectScope(scope) } label: {
            HStack(spacing: 10) {
                Image(systemName: symbol).frame(width: 20).foregroundStyle(workspace.scope == scope ? AppColors.accent : AppColors.textSecondary)
                Text(verbatim: title).font(.subheadline.weight(.medium)).lineLimit(2)
                Spacer(minLength: 4)
                Text(verbatim: String(count)).font(.caption.monospacedDigit()).foregroundStyle(AppColors.textTertiary)
            }
            .padding(.horizontal, 12).frame(minHeight: 46)
            .background(workspace.scope == scope ? AppColors.accent.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 12))
        }
        .choiceCardButton(cornerRadius: 12)
        .accessibilityAddTraits(workspace.scope == scope ? .isSelected : [])
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
                savedID = await organization.createProject(title: title, materialIDs: request.materialIDs)
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
