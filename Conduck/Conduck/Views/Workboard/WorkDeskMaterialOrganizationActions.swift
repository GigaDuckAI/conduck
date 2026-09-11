// SPDX-License-Identifier: Apache-2.0

// Organization lives in each material's existing actions, not a second strip
// around its card. The descriptor keeps the live workspace rather than copied
// project values: cached canvas previews must still see a renamed project,
// or changed membership from another presentation. Menu, row
// caption and VoiceOver each observe that workspace below the preview cache.

import SwiftUI

@MainActor
struct WorkDeskMaterialOrganizationActions {
    let workspace: WorkDeskWorkspaceState
    let materialID: UUID

    var projectID: UUID? { workspace.organization.projectID(for: materialID) }
    var project: WorkDeskProjectRecord? { projectID.flatMap { workspace.organization.project(id: $0) } }
    var destinations: [WorkDeskProjectRecord] {
        let current = projectID
        return workspace.organization.projects.filter { $0.id != current }
    }
    var showsLocation: Bool { workspace.isSearching || workspace.scope == .all }
    var result: WorkDeskResultRecord? { workspace.results[materialID] }
    var showsSource: Bool { result != nil }
    func openSource() {
        guard let result else { return }
        workspace.openResultSource(result)
    }
    func createProject() { workspace.beginProject(materialIDs: [materialID]) }
    func select() { workspace.toggleSelection(materialID) }

    @discardableResult
    func move(to projectID: UUID?) async -> Bool {
        let saved = await workspace.organization.assign(materialIDs: [materialID], to: projectID)
        if saved { workspace.selectedIDs.remove(materialID) }
        return saved
    }
}

struct WorkDeskMaterialMenuActions: View {
    @Bindable private var workspace: WorkDeskWorkspaceState
    private let materialID: UUID

    init(actions: WorkDeskMaterialOrganizationActions) {
        workspace = actions.workspace
        materialID = actions.materialID
    }

    private var actions: WorkDeskMaterialOrganizationActions {
        .init(workspace: workspace, materialID: materialID)
    }

    var body: some View {
        if actions.showsSource {
            Button { actions.openSource() } label: {
                Label(LocalizedStringResource("workdesk.result.openSource", defaultValue: "Open source conversation"), systemImage: "bubble.left")
            }
        }
        Button { actions.select() } label: {
            Label(LocalizedStringResource("workdesk.canvas.selectCard", defaultValue: "Select material"), systemImage: "checkmark.circle")
        }
        Button { actions.createProject() } label: {
            Label(LocalizedStringResource("workdesk.group", defaultValue: "Create project"), systemImage: "folder.badge.plus")
        }
        if actions.projectID != nil {
            Button { Task { await actions.move(to: nil) } } label: {
                Label(LocalizedStringResource("workdesk.removeFromProject", defaultValue: "Remove from project"), systemImage: "arrow.uturn.backward")
            }
        }
        if !actions.destinations.isEmpty {
            Menu {
                ForEach(actions.destinations) { project in
                    Button { Task { await actions.move(to: project.id) } } label: {
                        Text(verbatim: project.title)
                    }
                }
            } label: {
                Label(LocalizedStringResource("workdesk.move", defaultValue: "Move to"), systemImage: "folder")
            }
        }
    }
}

/// Accessibility exposes each destination directly: a nested menu is not an
/// action on an element whose children are deliberately hidden from VoiceOver.
struct WorkDeskMaterialAccessibilityActions: View {
    @Bindable private var workspace: WorkDeskWorkspaceState
    private let materialID: UUID

    init(actions: WorkDeskMaterialOrganizationActions) {
        workspace = actions.workspace
        materialID = actions.materialID
    }

    private var actions: WorkDeskMaterialOrganizationActions {
        .init(workspace: workspace, materialID: materialID)
    }

    var body: some View {
        if actions.showsSource {
            Button(LocalizedStringResource("workdesk.result.openSource", defaultValue: "Open source conversation")) { actions.openSource() }
        }
        Button(LocalizedStringResource("workdesk.canvas.selectCard", defaultValue: "Select material")) { actions.select() }
        Button(LocalizedStringResource("workdesk.group", defaultValue: "Create project")) { actions.createProject() }
        if actions.projectID != nil {
            Button(LocalizedStringResource("workdesk.removeFromProject", defaultValue: "Remove from project")) {
                Task { await actions.move(to: nil) }
            }
        }
        ForEach(actions.destinations) { project in
            Button { Task { await actions.move(to: project.id) } } label: {
                Text(LocalizedStringResource("workdesk.move", defaultValue: "Move to")) + Text(verbatim: ": " + project.title)
            }
        }
    }
}

struct WorkDeskMaterialLocation: View {
    @Bindable private var workspace: WorkDeskWorkspaceState
    private let materialID: UUID

    init(actions: WorkDeskMaterialOrganizationActions) {
        workspace = actions.workspace
        materialID = actions.materialID
    }

    var body: some View {
        let actions = WorkDeskMaterialOrganizationActions(workspace: workspace, materialID: materialID)
        if let result = actions.result {
            Button { actions.openSource() } label: {
                Label {
                    Text(LocalizedStringResource("workdesk.result.label", defaultValue: "Result"))
                    + Text(verbatim: " · " + sourceName(result))
                } icon: { Image(systemName: "bubble.left") }
                    .font(.caption2).lineLimit(1).padding(.vertical, 3)
            }.inlineLinkButton().foregroundStyle(AppColors.textSecondary)
            .accessibilityHint(Text(LocalizedStringResource("workdesk.result.openSource", defaultValue: "Open source conversation")))
        }
        if actions.showsLocation, let project = actions.project {
            Label { Text(verbatim: project.title) } icon: { Image(systemName: "folder") }
                .font(.caption2)
                .foregroundStyle(AppColors.textSecondary)
                .lineLimit(1)
        }
    }

    private func sourceName(_ result: WorkDeskResultRecord) -> String {
        let title = workspace.projectConversations.first { $0.id == result.conversationID }?.displayTitle
        let gateway = RemoteAgentRef(rawString: result.gatewayRef).map {
            RemoteAgentRefMetadata.displayName(for: $0, customs: workspace.conversationSettings.customGateways)
        }
        return [title, gateway].compactMap { $0 }.joined(separator: " · ")
    }
}
