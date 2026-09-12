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
    /// The location that drew this card, which may differ from the project
    /// selected in the floating tray. A search result has no source location.
    let sourceLocation: WorkDeskLocation?

    init(workspace: WorkDeskWorkspaceState, materialID: UUID, sourceLocation: WorkDeskLocation?) {
        self.workspace = workspace
        self.materialID = materialID
        self.sourceLocation = sourceLocation
    }

    init(workspace: WorkDeskWorkspaceState, materialID: UUID) {
        self.init(workspace: workspace, materialID: materialID,
                  sourceLocation: workspace.isSearching ? nil : workspace.scope.location)
    }

    var projects: [WorkDeskProjectRecord] {
        workspace.organization.projects.filter {
            workspace.organization.contains(materialID: materialID, at: .project($0.id))
        }
    }
    var sourceProject: WorkDeskProjectRecord? {
        guard case .project(let id) = sourceLocation else { return nil }
        return workspace.organization.project(id: id)
    }
    var project: WorkDeskProjectRecord? {
        if let sourceProject, workspace.organization.contains(materialID: materialID, at: .project(sourceProject.id)) {
            return sourceProject
        }
        return projects.first
    }
    var projectID: UUID? { project?.id }
    var destinations: [WorkDeskProjectRecord] {
        workspace.organization.projects.filter { WorkDeskLocation.project($0.id) != sourceLocation }
    }
    var additionalDestinations: [WorkDeskProjectRecord] {
        workspace.organization.projects.filter {
            !workspace.organization.contains(materialID: materialID, at: .project($0.id))
        }
    }
    var isOnHome: Bool { workspace.organization.contains(materialID: materialID, at: .home) }
    var showsLocation: Bool { workspace.isSearching || sourceLocation == nil || sourceLocation == .home || projects.count > 1 }
    var canCreateProject: Bool { sourceLocation == .home && !workspace.isSearching }
    var canMove: Bool {
        guard let sourceLocation else { return false }
        return workspace.organization.contains(materialID: materialID, at: sourceLocation)
    }
    var canMoveHome: Bool { canMove && sourceLocation != .home }
    var canRemoveFromProject: Bool { canMove && sourceProject != nil }
    var conversationMaterialIDs: Set<UUID> {
        guard !workspace.isSearching, let current = workspace.currentProject,
              sourceLocation == .project(current.id), canMove else { return [] }
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
            var names = projects.map(\.title)
            if isOnHome { names.insert(String(localized: "workdesk.material.home", defaultValue: "Home"), at: 0) }
            if !names.isEmpty {
                parts.append(String(localized: "workdesk.material.locations", defaultValue: "In \(names.joined(separator: ", "))"))
            }
        }
        if showsSource {
            parts.append(String(localized: "workdesk.result.from", defaultValue: "From \(sourceName)"))
        }
        if !uses.isEmpty { parts.append(String(localized: WorkDeskCopy.conversationUses(uses.count))) }
        return parts
    }
    func showUses() { workspace.materialUsePickerID = materialID }
    func openProject(_ projectID: UUID? = nil) {
        guard let id = projectID ?? project?.id,
              workspace.organization.project(id: id) != nil else { return }
        workspace.selectScope(.project(id))
    }
    func openSource() {
        guard let result else { return }
        workspace.openResultSource(result)
    }
    func createProject() {
        guard canCreateProject else { return }
        if workspace.scope != .all { workspace.selectScope(.all) }
        workspace.beginProject(materialIDs: [materialID])
    }
    func startConversation() { workspace.requestConversation(materialIDs: conversationMaterialIDs) }
    func select() {
        if let sourceLocation, workspace.scope.location != sourceLocation {
            switch sourceLocation {
            case .home: workspace.selectScope(.all)
            case .project(let id): workspace.selectScope(.project(id))
            }
        }
        workspace.toggleSelection(materialID)
    }

    @discardableResult
    func move(to projectID: UUID?) async -> Bool {
        guard let sourceLocation else { return false }
        let destination = projectID.map(WorkDeskLocation.project) ?? .home
        let saved = await workspace.organization.move(materialIDs: [materialID], from: sourceLocation, to: destination,
            expected: workspace.organization.locationTokens(for: [materialID]))
        if saved { workspace.selectedIDs.remove(materialID) }
        return saved
    }

    @discardableResult
    func add(to projectID: UUID) async -> Bool {
        await workspace.organization.add(materialIDs: [materialID], to: .project(projectID),
            expected: workspace.organization.locationTokens(for: [materialID]))
    }

    @discardableResult
    func removeFromProject() async -> Bool {
        guard canRemoveFromProject, let sourceLocation else { return false }
        let saved = await workspace.organization.remove(materialIDs: [materialID], from: sourceLocation,
            expected: workspace.organization.locationTokens(for: [materialID]))
        if saved { workspace.selectedIDs.remove(materialID) }
        return saved
    }
}

struct WorkDeskMaterialMenuActions: View {
    @Bindable private var workspace: WorkDeskWorkspaceState
    private let materialID: UUID
    private let sourceLocation: WorkDeskLocation?

    init(actions: WorkDeskMaterialOrganizationActions) {
        workspace = actions.workspace
        materialID = actions.materialID
        sourceLocation = actions.sourceLocation
    }

    private var actions: WorkDeskMaterialOrganizationActions {
        .init(workspace: workspace, materialID: materialID, sourceLocation: sourceLocation)
    }

    var body: some View {
        if !actions.uses.isEmpty {
            Button(WorkDeskCopy.conversationUses(actions.uses.count), systemImage: "bubble.left.and.bubble.right") {
                actions.showUses()
            }
        }
        if actions.showsLocation, !actions.projects.isEmpty {
            Menu {
                ForEach(actions.projects) { project in
                    Button { actions.openProject(project.id) } label: { Text(verbatim: project.title) }
                }
            } label: {
                Label(LocalizedStringResource("workdesk.material.openProject", defaultValue: "Open project"), systemImage: "folder")
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
        if actions.canMoveHome {
            Button { Task { await actions.move(to: nil) } } label: {
                Label(LocalizedStringResource("workdesk.moveToHome", defaultValue: "Move to Home"), systemImage: "tray.and.arrow.up")
            }
        }
        if actions.canRemoveFromProject {
            Button { Task { await actions.removeFromProject() } } label: {
                Label(LocalizedStringResource("workdesk.removeFromThisProject", defaultValue: "Remove from this project"), systemImage: "folder.badge.minus")
            }
        }
        if actions.canMove, !actions.destinations.isEmpty {
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
        if !actions.additionalDestinations.isEmpty {
            Menu {
                ForEach(actions.additionalDestinations) { project in
                    Button { Task { await actions.add(to: project.id) } } label: { Text(verbatim: project.title) }
                }
            } label: {
                Label(LocalizedStringResource("workdesk.addToAnotherProject", defaultValue: "Add to another project…"), systemImage: "folder.badge.plus")
            }
        }

    }
}

/// Accessibility exposes each destination directly: a nested menu is not an
/// action on an element whose children are deliberately hidden from VoiceOver.
struct WorkDeskMaterialAccessibilityActions: View {
    @Bindable private var workspace: WorkDeskWorkspaceState
    private let materialID: UUID
    private let sourceLocation: WorkDeskLocation?

    init(actions: WorkDeskMaterialOrganizationActions) {
        workspace = actions.workspace
        materialID = actions.materialID
        sourceLocation = actions.sourceLocation
    }

    private var actions: WorkDeskMaterialOrganizationActions {
        .init(workspace: workspace, materialID: materialID, sourceLocation: sourceLocation)
    }

    var body: some View {
        if !actions.uses.isEmpty {
            Button(WorkDeskCopy.conversationUses(actions.uses.count)) { actions.showUses() }
        }
        if actions.showsLocation {
            ForEach(actions.projects) { project in
                Button { actions.openProject(project.id) } label: {
                    Text(LocalizedStringResource("workdesk.material.openNamedProject", defaultValue: "Open \(project.title)"))
                }
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
        if actions.canMoveHome {
            Button(LocalizedStringResource("workdesk.moveToHome", defaultValue: "Move to Home")) {
                Task { await actions.move(to: nil) }
            }
        }
        if actions.canRemoveFromProject {
            Button(LocalizedStringResource("workdesk.removeFromThisProject", defaultValue: "Remove from this project")) {
                Task { await actions.removeFromProject() }
            }
        }
        if actions.canMove {
            ForEach(actions.destinations) { project in
                Button { Task { await actions.move(to: project.id) } } label: {
                    Text(LocalizedStringResource("workdesk.material.moveToNamedProject", defaultValue: "Move to \(project.title)"))
                }
            }
        }
        ForEach(actions.additionalDestinations) { project in
            Button { Task { await actions.add(to: project.id) } } label: {
                Text(LocalizedStringResource("workdesk.material.addToNamedProject", defaultValue: "Add to \(project.title)"))
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
    private let sourceLocation: WorkDeskLocation?

    init(actions: WorkDeskMaterialOrganizationActions) {
        workspace = actions.workspace
        materialID = actions.materialID
        sourceLocation = actions.sourceLocation
    }

    var body: some View {
        let actions = WorkDeskMaterialOrganizationActions(workspace: workspace, materialID: materialID, sourceLocation: sourceLocation)
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
                if actions.projects.count > 1 {
                    Label(LocalizedStringResource("workdesk.material.projectCount", defaultValue: "In \(actions.projects.count) projects"), systemImage: "folder.on.folder")
                        .font(.caption2).lineLimit(1).padding(.vertical, 3)
                        .foregroundStyle(AppColors.textSecondary)
                } else if let project = actions.projects.first {
                    Label { Text(verbatim: project.title) } icon: { Image(systemName: "folder") }
                        .font(.caption2).lineLimit(1).padding(.vertical, 3)
                        .foregroundStyle(AppColors.textSecondary)
                        .anchorPreference(key: WorkDeskMetadataBounds.self, value: .bounds) { [.project: $0] }
                } else {
                    Label(LocalizedStringResource("workdesk.material.home", defaultValue: "Home"), systemImage: "tray")
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
