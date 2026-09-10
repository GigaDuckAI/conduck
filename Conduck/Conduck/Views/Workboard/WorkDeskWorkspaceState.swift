// SPDX-License-Identifier: Apache-2.0

// Presentation of the personal desk. Filters never change material ownership:
// every capture stays on the canonical desk, and projects refer to its cards.
// Selection is intersected with the visible snapshot before every operation so
// a sync, search or project switch cannot silently include a hidden source.

import SwiftUI

enum WorkDeskScope: Hashable {
    case desk, all, pinned, project(UUID)
}

@Observable @MainActor
final class WorkDeskWorkspaceState {
    let organization: WorkDeskOrganization
    var scope: WorkDeskScope = .desk
    var isActive = false
    var search = ""
    var selectedIDs: Set<UUID> = []
    var isSelecting = false
    var showsSidebar = true
    var presentsSidebarInline = true
    var showsProjectPicker = false
    var projectEditor: WorkDeskProjectEditorRequest?
    var pendingProjectEditor: WorkDeskProjectEditorRequest?
    var editorTitle = ""
    var briefDrafts: [UUID: WorkDeskBriefDraft] = [:]
    var briefRevisions: [UUID: Date] = [:]
    var preparingProjectID: UUID?
    var deletingProjectID: UUID?
    @ObservationIgnored private var canvasSessions: [WorkDeskScope: WorkDeskCanvasSession] = [:]

    func canvasSession(for scope: WorkDeskScope) -> WorkDeskCanvasSession {
        if let existing = canvasSessions[scope] { return existing }
        let session = WorkDeskCanvasSession()
        canvasSessions[scope] = session
        return session
    }

    init(organization: WorkDeskOrganization? = nil) {
        self.organization = organization ?? WorkDeskOrganization()
    }

    var currentProject: WorkDeskProjectRecord? {
        guard case .project(let id) = scope else { return nil }
        return organization.projects.first { $0.id == id }
    }

    func visibleMaterials(in materials: [WorkboardMaterialSnapshot]) -> [WorkboardMaterialSnapshot] {
        materials.filter { material in
            let belongs: Bool
            switch scope {
            case .desk: belongs = organization.projectID(for: material.id) == nil
            case .all: belongs = true
            case .pinned: belongs = organization.placements[material.id]?.isPinned == true
            case .project(let id): belongs = organization.projectID(for: material.id) == id
            }
            guard belongs else { return false }
            let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
            return query.isEmpty || [material.name, material.textContent ?? "", material.detail ?? "",
                                     material.companion?.textContent ?? ""]
                .contains { $0.localizedStandardContains(query) }
        }
    }

    var supportsSpatialLayout: Bool {
        guard search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return switch scope {
        case .desk, .project: true
        case .all, .pinned: false
        }
    }

    static func moveTarget(_ materialID: UUID, direction: WorkboardMoveDirection, visibleIDs: [UUID]) -> UUID? {
        guard let index = visibleIDs.firstIndex(of: materialID) else { return nil }
        let target = direction == .earlier ? index - 1 : index + 1
        return visibleIDs.indices.contains(target) ? visibleIDs[target] : nil
    }

    func updateSidebarLayout(isInline: Bool) {
        presentsSidebarInline = isInline
        if isInline { showsProjectPicker = false }
    }

    /// Both the native Mac toolbar and the in-pane mobile button route here.
    /// A compact window opens the project picker; it never toggles a hidden rail.
    func toggleProjectNavigation() {
        if presentsSidebarInline { showsSidebar.toggle() }
        else { showsProjectPicker.toggle() }
    }

    func selectScope(_ scope: WorkDeskScope) {
        self.scope = scope
        search = ""
        selectedIDs = []
        isSelecting = false
        showsProjectPicker = false
    }

    func toggleSelection(_ id: UUID) {
        isSelecting = true
        if selectedIDs.contains(id) { selectedIDs.remove(id) }
        else { selectedIDs.insert(id) }
    }

    func reconcile(materials: [WorkboardMaterialSnapshot]) {
        if case .project(let id) = scope,
           !organization.projects.contains(where: { $0.id == id }) {
            selectScope(.desk)
        }
        selectedIDs.formIntersection(Set(visibleMaterials(in: materials).map(\.id)))
    }

    func beginProject(materialIDs: [UUID] = [], position: WorkDeskPoint? = nil) {
        presentEditor(WorkDeskProjectEditorRequest(project: nil, materialIDs: materialIDs, position: position))
    }

    func editProject(_ project: WorkDeskProjectRecord) {
        presentEditor(WorkDeskProjectEditorRequest(project: project, materialIDs: []))
    }

    func suspend() {
        isActive = false
        for draft in briefDrafts.values { draft.suspendPresentation() }
    }

    func endBriefEditing(projectID: UUID) {
        guard briefDrafts[projectID]?.handoff.isSending != true else { return }
        briefDrafts.removeValue(forKey: projectID)
        briefRevisions.removeValue(forKey: projectID)
    }

    func briefDraft(for project: WorkDeskProjectRecord, resolver: WorkDeskConversationResolver) -> WorkDeskBriefDraft {
        if let existing = briefDrafts[project.id] { return existing }
        let draft = WorkDeskBriefDraft(brief: project.brief, preferredGatewayRef: project.preferredGatewayRef, conversationResolver: resolver)
        briefDrafts[project.id] = draft
        briefRevisions[project.id] = project.updatedAt
        return draft
    }

    private func presentEditor(_ request: WorkDeskProjectEditorRequest) {
        editorTitle = request.project?.title ?? ""

        if showsProjectPicker {
            pendingProjectEditor = request
            showsProjectPicker = false
        } else { projectEditor = request }
    }

    func projectPickerDidDismiss() {
        if let pendingProjectEditor {
            projectEditor = pendingProjectEditor
            self.pendingProjectEditor = nil
        }
    }

    func assignSelection(to projectID: UUID?, materials: [WorkboardMaterialSnapshot]) async {
        let ids = visibleMaterials(in: materials).map(\.id).filter { selectedIDs.contains($0) }
        guard !ids.isEmpty else { return }
        if await organization.assign(materialIDs: ids, to: projectID) {
            selectedIDs = []
            isSelecting = false
        }
    }
}

struct WorkDeskProjectEditorRequest: Identifiable {
    let id = UUID()
    let project: WorkDeskProjectRecord?
    let materialIDs: [UUID]
    var position: WorkDeskPoint? = nil
}
