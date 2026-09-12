// SPDX-License-Identifier: Apache-2.0

// The management desk detail and its compact project picker. Wide hosts own
// navigation in a native sidebar; the composer stays within the detail column.
// Search stays in navigation so the canvas remains a desk;
// a compact picker submits its query back to the same global result surface.
// Home holds loose materials and projects. Opening a project replaces the
// detail surface; only the explicit brief sheet can create a
// conversation. Deletion reviews the exact materials and affected locations.
// Active and archived projects remain accessible in navigation. Archiving
// stops new project activity while retaining its materials and conversations.

import SwiftUI

struct WorkDeskWorkspaceView: View {
    @Bindable var viewModel: WorkboardViewModel
    let item: WorkboardItemSnapshot
    @Bindable var workspace: WorkDeskWorkspaceState
    @State private var opensSettingsAfterPicker = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.workDeskConversationResolver) private var conversationResolver
    @Environment(\.workDeskSidebarIsHosted) private var sidebarIsHosted
    @Environment(\.workDeskNavigationIsExternal) private var navigationIsExternal
    @Environment(\.workDeskOpenSettings) private var openSettings
    @Environment(\.workbenchDestinationIsActive) private var isActive

    private var workspaceLayout: some View {
        VStack(spacing: 0) {
            if !workspace.isShowingConversation || showsConversationBackNavigation || workspace.conversationLoadError != nil || workspace.showsProjectAccessRecovery {
                header()
            }
            workspaceContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: navigationIsExternal, initial: true) { _, external in
            guard isActive else { return }
            workspace.updateSidebarLayout(isInline: external)
        }
        .onChange(of: isActive) { _, active in
            guard active else { return }
            workspace.updateSidebarLayout(isInline: navigationIsExternal)
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
                    allowsNewTurns: workspace.currentProjectAllowsNewActivity,
                    newActivityMessage: workspace.currentProject?.isArchived == true
                        ? WorkDeskStoreError.projectArchived.localizedDescription
                        : WorkDeskStoreError.projectSelectionRequired.localizedDescription,
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
        .onAppear {
            workspace.startRefreshing(isActive: isActive, materials: { [weak viewModel] in
                viewModel?.desk?.materials ?? []
            })
        }
        .onDisappear { workspace.suspend() }
        .onChange(of: item.materials) { _, _ in workspace.reconcile(materials: item.materials) }
        .onChange(of: workspace.search) { _, _ in workspace.reconcile(materials: item.materials) }
        .onChange(of: workspace.conversationSelectionRequest?.id) { _, _ in
            guard let request = workspace.conversationSelectionRequest else { return }
            workspace.conversationSelectionRequest = nil
            guard request.projectID == workspace.currentProject?.id else { return }
            workspace.beginConversation(materialIDs: request.materialIDs, materials: item.materials,
                resolver: effectiveConversationResolver)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { workspace.requestRefresh(.all) }
        }
        .onChange(of: isActive) { _, active in
            if active { workspace.setRefreshActive(true) }
            else {
                workspace.searchIsFocused = false
                workspace.suspend()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .conversationsDidChange)) { _ in
            workspace.requestRefresh(.organization)
        }
        .onReceive(NotificationCenter.default.publisher(for: .settingsDidChangeRemotely)) { _ in
            workspace.requestRefresh(.settings)
        }
    }

    private var presentedWorkspace: some View {
        liveWorkspace
        .sheet(isPresented: Binding(
            get: { isActive && workspace.showsProjectPicker },
            set: { if isActive { workspace.showsProjectPicker = $0 } }
        ), onDismiss: {
            workspace.projectPickerDidDismiss()
            guard opensSettingsAfterPicker else { return }
            opensSettingsAfterPicker = false
            guard isActive else { return }
            openSettings?()
        }) {
            NavigationStack {
                WorkDeskSidebarView(viewModel: viewModel)
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        if openSettings != nil {
                            SidebarSettingsFooter {
                                // The picker must finish dismissing before its
                                // host presents Settings into the same scene.
                                opensSettingsAfterPicker = true
                                workspace.showsProjectPicker = false
                            }
                        }
                    }
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
            .sheet(isPresented: Binding(
                get: { isActive && workspace.showsProjectPicker && workspace.organization.projectLimitRequested },
                set: { workspace.organization.projectLimitRequested = $0 }
            ), onDismiss: workspace.projectLimitDidDismiss) {
                ProPaywallView(context: .projectLimit, onManage: workspace.manageProjectsFromLimit)
            }
            .sheet(isPresented: Binding(
                get: { isActive && workspace.projectSelectionPresenter == .picker },
                set: { workspace.organization.projectSelectionRequested = $0 }
            )) {
                WorkDeskFreeProjectSelectionView(organization: workspace.organization)
            }
            // The picker is its own presenter on iPhone/compact iPad. A limit
            // reached here must appear above this sheet, keeping it open so
            // the person can archive a project and retry without losing scope.
            .alert(Text(LocalizedStringResource("workdesk.update.failed", defaultValue: "Couldn’t update the desk")),
                   isPresented: Binding(
                    get: { isActive && workspace.showsProjectPicker && workspace.organization.errorMessage != nil },
                    set: { if !$0 { workspace.organization.errorMessage = nil } }
                   )) {
                Button(LocalizedStringResource("common.ok", defaultValue: "OK")) {
                    workspace.organization.errorMessage = nil
                }
            } message: {
                Text(verbatim: workspace.organization.errorMessage ?? "")
            }
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
            get: { isActive && !workspace.showsProjectPicker && workspace.projectEditor == nil && workspace.preparingProjectID == nil && workspace.organization.projectLimitRequested },
            set: { workspace.organization.projectLimitRequested = $0 }
        ), onDismiss: workspace.projectLimitDidDismiss) {
            ProPaywallView(context: .projectLimit, onManage: workspace.manageProjectsFromLimit)
        }
        .sheet(isPresented: Binding(
            get: { isActive && workspace.projectSelectionPresenter == .workspace },
            set: { workspace.organization.projectSelectionRequested = $0 }
        )) {
            WorkDeskFreeProjectSelectionView(organization: workspace.organization)
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
        .sheet(item: Binding(
            get: { isActive ? workspace.projectDeletionReview : nil },
            set: { if isActive { workspace.projectDeletionReview = $0 } }
        )) { review in
            WorkDeskProjectDeletionSheet(review: review, organization: workspace.organization) { kept in
                workspace.finishProjectDeletion(review, keptMaterials: kept, materials: item.materials)
            }
        }
        .sheet(isPresented: Binding(
            get: { isActive && workspace.materialUsePickerID != nil },
            set: { if !$0 { workspace.materialUsePickerID = nil } }
        )) {
            if let materialID = workspace.materialUsePickerID {
                WorkDeskMaterialUsesSheet(workspace: workspace, materialID: materialID,
                    materialName: item.materials.first(where: { $0.id == materialID })?.name ?? "")
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
                    materials: item.materials.filter { workspace.organization.contains(materialID: $0.id, at: .project(id)) },
                    availableMaterials: item.materials,
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
                    Text(LocalizedStringResource("workdesk.project.unavailable", defaultValue: "This project is no longer available."))
                    Button(LocalizedStringResource("common.done", defaultValue: "Done")) { workspace.preparingProjectID = nil }
                        .buttonStyle(.bordered)
                }.padding(24)
            }
        }
    }

    var body: some View {
        presentedWorkspace
        .modifier(WorkDeskOrganizationUndo(workspace: workspace))
        .simultaneousGesture(SpatialTapGesture(coordinateSpace: .global).onEnded { value in
            guard isActive, !workspace.transferCoordinator.isDragging else { return }
            workspace.projectPreview.dismissOutside(value.location)
        })
        .background {
            Button(LocalizedStringResource("workdesk.search", defaultValue: "Find an idea or file")) {
                workspace.requestSearch()
            }
            .keyboardShortcut("f", modifiers: .command)
            .disabled(!isActive)
            .hidden()
        }
        .alert(Text(LocalizedStringResource("workdesk.update.failed", defaultValue: "Couldn’t update the desk")),
               isPresented: Binding(
                get: { isActive && !workspace.showsProjectPicker && workspace.organization.errorMessage != nil && workspace.projectPreview.request == nil && workspace.projectEditor == nil && workspace.preparingProjectID == nil && workspace.projectDeletionReview == nil },
                set: { if !$0 { workspace.organization.errorMessage = nil } }
               )) {
            Button(LocalizedStringResource("common.ok", defaultValue: "OK")) {
                workspace.organization.errorMessage = nil
            }
        } message: {
            Text(verbatim: workspace.organization.errorMessage ?? "")
        }
    }

    /// The toolbar owns project identity, gateway, context and saved conversations.
    /// The active collection has one action row, wrapping only when needed.
    /// Selection offers organization and an explicitly counted conversation
    /// draft; the review sheet still owns what leaves the device. Compact
    /// windows retain a named primary action.
    private func header() -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if workspace.organization.canPresentFreeProjectSelection {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(workspace.organization.hasExpiredSubscription
                        ? LocalizedStringResource("workdesk.pro.expired.message", defaultValue: "Your Pro subscription ended. Choose which projects stay active on the free plan.")
                        : LocalizedStringResource("workdesk.pro.selection.message", defaultValue: "Choose which projects stay active on the free plan. All your materials and conversations remain available."))
                        .font(.caption).foregroundStyle(AppColors.textSecondary)
                    Spacer(minLength: 0)
                    Button(LocalizedStringResource("workdesk.pro.chooseProjects", defaultValue: "Choose projects")) {
                        workspace.organization.projectSelectionRequested = true
                    }.inlineLinkButton()
                }.padding(.vertical, 6)
            }
            if let project = workspace.currentProject, project.isArchived, !workspace.isSearching {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(LocalizedStringResource("workdesk.project.archived.message", defaultValue: "Archived. Restore this project to add materials or start a new conversation."))
                        .font(.caption).foregroundStyle(AppColors.textSecondary)
                    Spacer(minLength: 0)
                    WorkDeskProjectArchiveButton(project: project, organization: workspace.organization)
                        .inlineLinkButton()
                }
                .padding(.vertical, 6)
            }
            if workspace.isShowingConversation {
                if showsConversationBackNavigation {
                    HStack { projectIdentity; Spacer(minLength: 0) }
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
        workspace.currentProjectAllowsNewActivity && !workspace.isShowingConversation && !workspace.isSearching && !workspace.isSelecting
    }

    private var showsConversationBackNavigation: Bool {
        #if os(iOS)
        workspace.isShowingConversation && UIDevice.current.userInterfaceIdiom == .phone
        #else
        false
        #endif
    }

    private var showsHomeNavigation: Bool {
        workspace.currentProject != nil && !workspace.isShowingConversation && !workspace.isSearching
            && (!sidebarIsHosted || !navigationIsExternal || !workspace.showsSidebar)
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
            if showsConversationBackNavigation {
                Button { workspace.selectScope(workspace.scope) } label: {
                    Label { Text(LocalizedStringResource("workdesk.conversation.back", defaultValue: "Back to project")).lineLimit(1) } icon: { Image(systemName: "chevron.left") }
                        .font(.headline).padding(.vertical, 8)
                }.inlineLinkButton()
                .accessibilityHint(Text(LocalizedStringResource("workdesk.conversation.back", defaultValue: "Back to project")))
            } else if showsHomeNavigation {
                Button { workspace.selectScope(.all) } label: {
                    Label(LocalizedStringResource("workdesk.all", defaultValue: "Home"), systemImage: "chevron.left")
                        .font(.subheadline.weight(.medium))
                        .padding(.horizontal, 4).frame(minHeight: 44)
                }
                .inlineLinkButton()
                .accessibilityIdentifier("workdesk-back-home")
            }
            if workspace.isSearching {
                Button { workspace.search = ""; workspace.searchIsFocused = false } label: {
                    Image(systemName: "xmark").frame(width: 40, height: 40)
                }.pointerIconButton(size: 40)
                .accessibilityLabel(Text(LocalizedStringResource("workdesk.search.clear", defaultValue: "Clear search")))
            }
        }
    }

    private var newConversationButton: some View {
        Button {
            workspace.beginConversation(resolver: effectiveConversationResolver)
        } label: {
            Text(LocalizedStringResource("workdesk.conversation.new", defaultValue: "New conversation…"))
                .font(.subheadline.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.center)
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
                    projectIdentity
                    materialCount
                    Spacer(minLength: 8)
                    materialActions
                    if showsNewConversation { newConversationButton }
                }
                VStack(alignment: .leading, spacing: 4) {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 8) {
                            projectIdentity
                            materialCount
                            Spacer(minLength: 0)
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            projectIdentity
                            materialCount
                        }
                    }
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 8) {
                            materialActions
                            Spacer(minLength: 8)
                            if showsNewConversation { newConversationButton }
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            materialActions
                            if showsNewConversation { newConversationButton }
                        }
                    }
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
            WorkDeskLayoutControl(viewModel: viewModel,
                supportsSpatialLayout: workspace.supportsSpatialLayout,
                scope: workspace.isSearching ? .all : workspace.scope)
        }
        if workspace.isSelecting || !workspace.visibleMaterials(in: item.materials).isEmpty {
            selectionControls
        }
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

    private var selectionBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                Text(LocalizedStringResource("workdesk.selected.count", defaultValue: "\(workspace.selectedIDs.count) selected"))
                    .font(.caption.monospacedDigit())
                if workspace.currentProjectAllowsNewActivity && !workspace.isSearching {
                    Button(WorkDeskMaterialConversationCopy.title(count: workspace.selectedIDs.count),
                           systemImage: "bubble.left.and.bubble.right") {
                        workspace.beginConversation(materialIDs: workspace.selectedIDs, materials: item.materials,
                            resolver: effectiveConversationResolver)
                    }
                    .buttonStyle(.bordered)
                    .disabled(workspace.selectedIDs.isEmpty)
                    .accessibilityIdentifier("workdesk-selection-new-conversation")
                } else if workspace.scope == .all && !workspace.isSearching {
                    Button(LocalizedStringResource("workdesk.group", defaultValue: "Create project"), systemImage: "folder.badge.plus") {
                        workspace.beginProject(materialIDs: workspace.visibleMaterials(in: item.materials).map(\.id).filter { workspace.selectedIDs.contains($0) })
                    }.buttonStyle(.bordered).disabled(workspace.selectedIDs.isEmpty)
                }
                Menu {
                    if !workspace.isSearching, workspace.currentProject != nil {
                        Button(LocalizedStringResource("workdesk.moveToHome", defaultValue: "Move to Home")) {
                            Task { await workspace.assignSelection(to: nil, materials: item.materials) }
                        }
                    }
                    ForEach(workspace.organization.availableProjectDestinations.filter { workspace.isSearching || $0.id != workspace.currentProject?.id }) { project in
                        Button { Task { await workspace.assignSelection(to: project.id, materials: item.materials) } }
                        label: { Text(verbatim: project.title) }
                    }
                } label: {
                    Label(workspace.isSearching
                        ? LocalizedStringResource("workdesk.addToAnotherProject", defaultValue: "Add to another project…")
                        : LocalizedStringResource("workdesk.move", defaultValue: "Move to"), systemImage: "folder")
                }
                .buttonStyle(.bordered)
                .disabled(workspace.organization.activeProjects.isEmpty && !workspace.selectedIDs.contains(where: { workspace.organization.projectID(for: $0) != nil }))
                if !workspace.isSearching {
                    Menu {
                        ForEach(workspace.organization.availableProjectDestinations.filter { $0.id != workspace.currentProject?.id }) { project in
                            Button {
                                let ids = workspace.visibleMaterials(in: item.materials).map(\.id)
                                    .filter { workspace.selectedIDs.contains($0) }
                                Task {
                                    _ = await workspace.organization.add(materialIDs: ids,
                                        to: .project(project.id), positions: [:])
                                }
                            } label: { Text(verbatim: project.title) }
                        }
                    } label: {
                        Label(LocalizedStringResource("workdesk.addToAnotherProject", defaultValue: "Add to another project…"),
                              systemImage: "folder.badge.plus")
                    }
                    .buttonStyle(.bordered)
                    .disabled(!workspace.organization.availableProjectDestinations.contains { $0.id != workspace.currentProject?.id })
                }
            }
            .controlSize(.small)
            .padding(.vertical, 2)
        }
        .scrollDismissesKeyboard(.interactively)
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
    @State private var contentHeight: CGFloat = 180
    @FocusState private var titleFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text(request.project == nil
                        ? LocalizedStringResource("workdesk.project.new", defaultValue: "New project")
                        : LocalizedStringResource("workdesk.project.rename", defaultValue: "Rename project"))
                        .font(.title2.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                    VStack(alignment: .leading, spacing: 8) {
                        Text(LocalizedStringResource("workdesk.project.name", defaultValue: "Project name"))
                            .font(.subheadline.weight(.medium))
                        TextField(text: $title) {
                            Text(LocalizedStringResource("workdesk.project.name", defaultValue: "Project name"))
                        }
                        .textFieldStyle(.plain)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 11)
                        .frame(maxWidth: .infinity, minHeight: WorkboardMetrics.touchTarget)
                        .background(AppColors.cardBackgroundElevated, in: RoundedRectangle(cornerRadius: 10))
                        .overlay {
                            RoundedRectangle(cornerRadius: 10)
                                .strokeBorder(titleFocused ? AppColors.brandAmber : AppColors.textTertiary.opacity(0.35), lineWidth: 1)
                        }
                        .focused($titleFocused)
                        .submitLabel(.done)
                        .onSubmit { save() }
                        .disabled(isSaving)
                        .accessibilityIdentifier("workdesk-project-name")
                    }
                    if request.project == nil {
                        Text(LocalizedStringResource("workdesk.project.create.explanation", defaultValue: "A home for related ideas, files and the brief you’ll shape from them."))
                            .font(.callout)
                            .foregroundStyle(AppColors.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let error {
                        Label(error, systemImage: "exclamationmark.circle")
                            .font(.callout)
                            .foregroundStyle(AppColors.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("workdesk-project-save-error")
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
            }
            .scrollDismissesKeyboard(.interactively)
            .scrollBounceBehavior(.basedOnSize)
            .frame(idealHeight: contentHeight)

            Divider().opacity(0.45)
            HStack(spacing: 12) {
                Spacer(minLength: 0)
                Button { dismiss() } label: {
                    Text(LocalizedStringResource("common.cancel", defaultValue: "Cancel"))
                        .font(.body.weight(.medium))
                        .padding(.horizontal, 18)
                        .padding(.vertical, 10)
                        .frame(minHeight: WorkboardMetrics.touchTarget, maxHeight: .infinity)
                        .background(AppColors.cardBackgroundElevated, in: Capsule())
                }
                .primaryCTAButton()
                .keyboardShortcut(.cancelAction)
                .disabled(isSaving)
                Button { save() } label: {
                    Text(LocalizedStringResource("common.save", defaultValue: "Save"))
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 10)
                        .frame(minHeight: WorkboardMetrics.touchTarget, maxHeight: .infinity)
                        .background(AppColors.brandAmber, in: Capsule())
                }
                .primaryCTAButton()
                .keyboardShortcut(.defaultAction)
                .disabled(isSaving || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
        .foregroundStyle(AppColors.textPrimary)
        .background(AppColors.background)
        .workboardDesktopSheetFrame(minWidth: 340, minHeight: 0, idealWidth: 440, maxWidth: 520, maxHeight: 560)
        .presentationSizing(.form.fitted(horizontal: false, vertical: true))
        .interactiveDismissDisabled(isSaving)
        .onAppear { titleFocused = true }
        .sheet(isPresented: Binding(
            get: { organization.projectLimitRequested },
            set: { organization.projectLimitRequested = $0 }
        )) {
            // The editor remains underneath the purchase sheet with its name,
            // selection and insertion point intact. A verified purchase only
            // dismisses the paywall; Save is still the person's explicit write.
            ProPaywallView(context: .projectLimit)
        }
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
                savedID = await organization.createProject(title: title, materialIDs: request.materialIDs, position: request.position, from: .home)
            }
            isSaving = false
            if let savedID { onCreated(savedID); dismiss() }
            else { error = organization.projectLimitRequested ? nil : organization.errorMessage; organization.errorMessage = nil }
        }
    }
}

// A sheet holds its own edit revision across parent refreshes. An unrelated
// iCloud edit cannot silently become the new baseline for text already typed;
// only this sheet's successful save advances its optimistic-concurrency token.
private struct WorkDeskBriefHost: View {
    let project: WorkDeskProjectRecord
    let materials: [WorkboardMaterialSnapshot]
    let availableMaterials: [WorkboardMaterialSnapshot]
    let workspace: WorkDeskWorkspaceState
    let draft: WorkDeskBriefDraft
    let onOpenConversation: (UUID) -> Void

    var body: some View {
        WorkDeskBriefView(projectID: project.id, title: project.title,
            initialBrief: project.brief, preferredGatewayRef: project.preferredGatewayRef,
            materials: materials, availableMaterials: availableMaterials,
            materialProjectNames: Dictionary(uniqueKeysWithValues: availableMaterials.compactMap { material in
                let names = workspace.organization.projects.filter {
                    workspace.organization.contains(materialID: material.id, at: .project($0.id))
                }.map(\.title)
                guard !names.isEmpty else { return nil }
                return (material.id, names.joined(separator: ", "))
            }), draft: draft,
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
            .workDeskConversationSheetPresentation()
    }
}
