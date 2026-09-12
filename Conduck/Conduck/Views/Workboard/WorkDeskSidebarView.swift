// SPDX-License-Identifier: Apache-2.0

// Work navigation shared by the native Mac/iPad sidebar and compact Projects
// picker. It reads the retained desk model directly, so moving navigation out
// of the canvas does not create a second project/search state or refresh owner.
// Hosts pin the shared Settings footer outside this scrolling collection.

import SwiftUI

struct WorkDeskSidebarView: View {
    @Bindable var viewModel: WorkboardViewModel
    @Environment(\.workbenchDestinationIsActive) private var isActive
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var workspace: WorkDeskWorkspaceState { viewModel.deskWorkspace }
    private var materials: [WorkboardMaterialSnapshot] { viewModel.desk?.materials ?? [] }

    private var navigationIsAvailable: Bool {
        if case .desk = viewModel.deskPresentation { return true }
        return false
    }

    private var searchInset: CGFloat {
        #if os(macOS)
        12
        #else
        24
        #endif
    }

    private var searchTopInset: CGFloat {
        #if os(macOS)
        12
        #else
        8
        #endif
    }

    private var searchField: some View {
        @Bindable var workspace = workspace
        return SidebarSearchField(
            text: $workspace.search,
            prompt: LocalizedStringResource("workdesk.search", defaultValue: "Find an idea or file"),
            isFocused: $workspace.searchIsFocused,
            onSubmit: {
                workspace.searchIsFocused = false
                workspace.showsProjectPicker = false
            },
            accessibilityIdentifier: "workdesk-search"
        )
        .submitLabel(.search)
    }

    var body: some View {
        let counts = workspace.organization.materialCounts(in: materials)
        return VStack(spacing: 0) {
            searchField
                .padding(.horizontal, searchInset)
                .padding(.top, searchTopInset)
                .padding(.bottom, 8)
            if !workspace.presentsSidebarInline && workspace.isSearching {
                Button(LocalizedStringResource("workdesk.search.show", defaultValue: "Show results")) {
                    workspace.searchIsFocused = false
                    workspace.showsProjectPicker = false
                }
                .buttonStyle(.borderedProminent)
                .padding(.bottom, 8)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    railRow(title: String(localized: LocalizedStringResource("workdesk.all", defaultValue: "Home")), symbol: "tray.full", scope: .all,
                        count: workspace.visibleMaterials(in: materials, scope: .all, search: "").count)
                    HStack {
                        Text(LocalizedStringResource("workdesk.projects", defaultValue: "Projects"))
                            .font(.caption.weight(.semibold)).foregroundStyle(AppColors.textTertiary)
                        Spacer()
                        Button {
                            workspace.beginProject()
                        } label: { Image(systemName: "plus").frame(width: 44, height: 44) }
                        .pointerIconButton(size: 44)
                        .accessibilityLabel(Text(LocalizedStringResource("workdesk.project.new", defaultValue: "New project")))
                    }.padding(.leading, 12).padding(.top, 12)
                    ForEach(workspace.organization.activeProjects) { project in
                        projectNavigationRow(project, count: counts[project.id] ?? 0)
                    }
                    if workspace.organization.projects.isEmpty {
                        Text(LocalizedStringResource("workdesk.projects.empty", defaultValue: "Bring related ideas together. Select a few cards to create your first project."))
                            .font(.caption).foregroundStyle(AppColors.textSecondary)
                            .padding(12)
                    }
                    if !workspace.organization.archivedProjects.isEmpty {
                        Text(LocalizedStringResource("workdesk.projects.archived", defaultValue: "Archived"))
                            .font(.caption.weight(.semibold)).foregroundStyle(AppColors.textTertiary)
                            .padding(.leading, 12).padding(.top, 18)
                        ForEach(workspace.organization.archivedProjects) { project in
                            projectNavigationRow(project, count: counts[project.id] ?? 0)
                        }
                    }
                }
                .padding(.horizontal, searchInset)
                .padding(.bottom, 12)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .disabled(!isActive || !navigationIsAvailable)
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
                railRow(title: project.title, symbol: project.isArchived ? "archivebox" : "folder", scope: .project(project.id), count: count,
                        projectColor: project.color)
            }
            .contextMenu {
                Button(LocalizedStringResource("workdesk.project.rename", defaultValue: "Rename project")) { workspace.editProject(project) }
                WorkDeskProjectColorMenu(project: project, organization: workspace.organization)
                WorkDeskProjectArchiveButton(project: project, organization: workspace.organization)
                Button(LocalizedStringResource("workdesk.project.delete.action", defaultValue: "Delete project…")) {
                    workspace.requestProjectDeletion(project.id)
                }
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
                                Text(verbatim: workspace.gatewayName(for: conversation)).font(.caption2).foregroundStyle(AppColors.textTertiary)
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

    private func railRow(title: String, symbol: String, scope: WorkDeskScope, count: Int,
                         projectColor: WorkDeskProjectColor? = nil) -> some View {
        Button {
            withAnimation(reduceMotion ? nil : .snappy(duration: 0.28)) { workspace.selectScope(scope) }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: symbol).frame(width: 20)
                    .foregroundStyle(projectColor?.tint ?? (workspace.scope == scope && !workspace.isShowingConversation && !workspace.isSearching ? AppColors.accent : AppColors.textSecondary))
                Text(verbatim: title).font(.subheadline.weight(.medium)).lineLimit(2)
                Spacer(minLength: 4)
                Text(verbatim: String(count)).font(.caption.monospacedDigit()).foregroundStyle(AppColors.textTertiary)
            }
            .padding(.horizontal, 12).frame(minHeight: 46)
            .background(workspace.scope == scope && !workspace.isShowingConversation && !workspace.isSearching ? AppColors.accent.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 12))
        }
        .choiceCardButton(cornerRadius: 12)
        .accessibilityAddTraits(workspace.scope == scope && !workspace.isShowingConversation && !workspace.isSearching ? .isSelected : [])
        .modifier(WorkDeskRailDropTarget(workspace: workspace, scope: scope, title: title,
            isEnabled: isActive && navigationIsAvailable))
    }
}

/// The same archive/restore intent is available beside project identity in the
/// sidebar, tray and folder menus. A refused restore routes the retained host
/// to the shared Pro sheet without deleting content or dismissing the project.
struct WorkDeskProjectArchiveButton: View {
    let project: WorkDeskProjectRecord
    let organization: WorkDeskOrganization

    var body: some View {
        Button(project.isArchived
            ? LocalizedStringResource("workdesk.project.restore", defaultValue: "Restore project")
            : LocalizedStringResource("workdesk.project.archive", defaultValue: "Archive project"),
               systemImage: project.isArchived ? "arrow.uturn.backward" : "archivebox") {
            Task { await organization.setProjectArchived(!project.isArchived, id: project.id) }
        }
        .disabled(organization.isSaving)
    }
}
