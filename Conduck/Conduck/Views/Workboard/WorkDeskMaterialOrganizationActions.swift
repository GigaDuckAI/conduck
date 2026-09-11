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
    var canCreateProject: Bool { workspace.scope == .all }
    var conversationMaterialIDs: Set<UUID> {
        guard !workspace.isSearching, let current = workspace.currentProject,
              current.id == projectID else { return [] }
        return workspace.selectedIDs.contains(materialID) ? workspace.selectedIDs : [materialID]
    }
    var canStartConversation: Bool { !conversationMaterialIDs.isEmpty }
    var conversationTitle: LocalizedStringResource {
        WorkDeskMaterialConversationCopy.title(count: conversationMaterialIDs.count)
    }
    var result: WorkDeskResultRecord? { workspace.results[materialID] }
    var showsSource: Bool { result != nil }
    var uses: [WorkDeskMaterialUseRecord] { workspace.uses(for: materialID) }
    var showsMetadata: Bool { showsLocation || showsSource || !uses.isEmpty }
    var sourceName: String {
        guard let result else { return "" }
        let title = workspace.projectConversations.first { $0.id == result.conversationID }?.displayTitle
        let gateway = RemoteAgentRef(rawString: result.gatewayRef).map {
            RemoteAgentRefMetadata.displayName(for: $0, customs: workspace.conversationSettings.customGateways)
        }
        let source = [title, gateway].compactMap { $0 }.joined(separator: " · ")
        return source.isEmpty
            ? String(localized: "workdesk.result.sourceConversation", defaultValue: "project conversation")
            : source
    }
    var accessibilityMetadata: [String] {
        var parts: [String] = []
        if showsLocation {
            parts.append(project?.title ?? String(localized: "workdesk.material.unfiled", defaultValue: "No project"))
        }
        if showsSource {
            parts.append(String(localized: "workdesk.result.from", defaultValue: "From \(sourceName)"))
        }
        if !uses.isEmpty { parts.append(String(localized: WorkDeskCopy.conversationUses(uses.count))) }
        return parts
    }
    func showUses() { workspace.materialUsePickerID = materialID }
    func openProject() {
        guard let project else { return }
        workspace.selectScope(.project(project.id))
    }
    func openSource() {
        guard let result else { return }
        workspace.openResultSource(result)
    }
    func createProject() {
        guard canCreateProject else { return }
        workspace.beginProject(materialIDs: [materialID])
    }
    func startConversation() { workspace.requestConversation(materialIDs: conversationMaterialIDs) }
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
        if !actions.uses.isEmpty {
            Button(WorkDeskCopy.conversationUses(actions.uses.count), systemImage: "bubble.left.and.bubble.right") {
                actions.showUses()
            }
        }
        if actions.showsLocation, actions.project != nil {
            Button(LocalizedStringResource("workdesk.material.openProject", defaultValue: "Open project"), systemImage: "folder") {
                actions.openProject()
            }
        }
        if actions.showsSource {
            Button { actions.openSource() } label: {
                Label(LocalizedStringResource("workdesk.result.openSource", defaultValue: "Open source conversation"), systemImage: "bubble.left")
            }
        }
        Button { actions.select() } label: {
            Label(LocalizedStringResource("workdesk.canvas.selectCard", defaultValue: "Select material"), systemImage: "checkmark.circle")
        }
        if actions.canStartConversation {
            Button { actions.startConversation() } label: {
                Label(actions.conversationTitle, systemImage: "bubble.left.and.bubble.right")
            }
        }
        if actions.canCreateProject {
            Button { actions.createProject() } label: {
                Label(LocalizedStringResource("workdesk.group", defaultValue: "Create project"), systemImage: "folder.badge.plus")
            }
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
        if !actions.uses.isEmpty {
            Button(WorkDeskCopy.conversationUses(actions.uses.count)) { actions.showUses() }
        }
        if actions.showsLocation, actions.project != nil {
            Button(LocalizedStringResource("workdesk.material.openProject", defaultValue: "Open project")) {
                actions.openProject()
            }
        }
        if actions.showsSource {
            Button(LocalizedStringResource("workdesk.result.openSource", defaultValue: "Open source conversation")) { actions.openSource() }
        }
        Button(LocalizedStringResource("workdesk.canvas.selectCard", defaultValue: "Select material")) { actions.select() }
        if actions.canStartConversation {
            Button(actions.conversationTitle) { actions.startConversation() }
        }
        if actions.canCreateProject {
            Button(LocalizedStringResource("workdesk.group", defaultValue: "Create project")) { actions.createProject() }
        }
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

enum WorkDeskMaterialConversationCopy {
    static func title(count: Int) -> LocalizedStringResource {
        if count == 1 {
            return LocalizedStringResource("workdesk.conversation.withOneMaterial", defaultValue: "New conversation with 1 material…")
        }
        return LocalizedStringResource("workdesk.conversation.withMaterials", defaultValue: "New conversation with \(count) materials…")
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
        VStack(alignment: .leading, spacing: 2) {
            if actions.showsSource {
                Label {
                    Text(LocalizedStringResource("workdesk.result.from", defaultValue: "From \(actions.sourceName)"))
                } icon: { Image(systemName: "bubble.left") }
                    .font(.caption2).lineLimit(1).padding(.vertical, 3)
                    .foregroundStyle(AppColors.textSecondary)
                    .anchorPreference(key: WorkDeskMetadataBounds.self, value: .bounds) { [.source: $0] }
            }
            if !actions.uses.isEmpty {
                Label(WorkDeskCopy.conversationUses(actions.uses.count), systemImage: "bubble.left.and.bubble.right")
                    .font(.caption2).lineLimit(1).padding(.vertical, 3)
                    .foregroundStyle(AppColors.textSecondary)
                    .anchorPreference(key: WorkDeskMetadataBounds.self, value: .bounds) { [.uses: $0] }
            }
            if actions.showsLocation {
                if let project = actions.project {
                    Label { Text(verbatim: project.title) } icon: { Image(systemName: "folder") }
                        .font(.caption2).lineLimit(1).padding(.vertical, 3)
                        .foregroundStyle(AppColors.textSecondary)
                        .anchorPreference(key: WorkDeskMetadataBounds.self, value: .bounds) { [.project: $0] }
                } else {
                    Label(LocalizedStringResource("workdesk.material.unfiled", defaultValue: "No project"), systemImage: "tray")
                        .font(.caption2).foregroundStyle(AppColors.textTertiary).lineLimit(1)
                }
            }
        }
    }
}

private enum WorkDeskMetadataAction: CaseIterable, Hashable { case source, uses, project }

private struct WorkDeskMetadataBounds: PreferenceKey {
    static let defaultValue: [WorkDeskMetadataAction: Anchor<CGRect>] = [:]
    static func reduce(value: inout [WorkDeskMetadataAction: Anchor<CGRect>],
                       nextValue: () -> [WorkDeskMetadataAction: Anchor<CGRect>]) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}

/// Metadata is drawn inside a card's primary Button label, but its controls
/// must be siblings of that Button. Bounds anchors preserve the actual label
/// geometry in images, text cards and rows without nesting a Button in a Button
/// or reserving another strip of permanent chrome around every material.
private struct WorkDeskMetadataControls: ViewModifier {
    let actions: WorkDeskMaterialOrganizationActions?

    func body(content: Content) -> some View {
        content.overlayPreferenceValue(WorkDeskMetadataBounds.self) { bounds in
            if let actions {
                GeometryReader { geometry in
                    ForEach(WorkDeskMetadataAction.allCases, id: \.self) { action in
                        if let anchor = bounds[action] {
                            let frame = geometry[anchor]
                            Button {
                                switch action {
                                case .source: actions.openSource()
                                case .uses: actions.showUses()
                                case .project: actions.openProject()
                                }
                            } label: {
                                Color.clear.contentShape(Rectangle())
                            }
                            .choiceCardButton(cornerRadius: 4)
                            .frame(width: frame.width, height: frame.height)
                            .position(x: frame.midX, y: frame.midY)
                            // The parent card supplies these named actions to
                            // VoiceOver; avoid repeating invisible overlay rows.
                            .accessibilityHidden(true)
                        }
                    }
                }
            }
        }
    }
}

extension View {
    func workDeskMetadataControls(_ actions: WorkDeskMaterialOrganizationActions?) -> some View {
        modifier(WorkDeskMetadataControls(actions: actions))
    }
}
