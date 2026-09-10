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
        return organization.project(id: id)
    }

    var isSearching: Bool { !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    func visibleMaterials(in materials: [WorkboardMaterialSnapshot]) -> [WorkboardMaterialSnapshot] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let matchingProjects = Set(organization.projects.lazy.filter {
            !query.isEmpty && $0.title.localizedStandardContains(query)
        }.map(\.id))
        return materials.filter { material in
            let projectID = organization.projectID(for: material.id)
            // Search is a way back to anything on the desk, including a note
            // filed in a project. Clearing it restores the person's scope.
            if !query.isEmpty {
                if let projectID, matchingProjects.contains(projectID) { return true }
                return [material.name, material.textContent ?? "", material.detail ?? "",
                        material.companion?.textContent ?? ""]
                    .contains { $0.localizedStandardContains(query) }
            }
            switch scope {
            case .desk: return projectID == nil
            case .all: return true
            case .pinned: return organization.placements[material.id]?.isPinned == true
            case .project(let id): return projectID == id
            }
        }
    }

    var supportsSpatialLayout: Bool {
        guard !isSearching else { return false }
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
        presentEditor(WorkDeskProjectEditorRequest(project: nil, materialIDs: materialIDs,
            position: position ?? projectCreationPosition(materialIDs: materialIDs)))
    }

    /// Freeze the intended spot before presenting the editor. A delayed save
    /// or a later camera movement must not relocate the project being named.
    private func projectCreationPosition(materialIDs: [UUID]) -> WorkDeskPoint {
        let selectedPoints = Set(materialIDs).compactMap { id -> WorkDeskPoint? in
            guard organization.projectID(for: id) == nil else { return nil }
            return organization.placements[id]?.position
        }
        if !selectedPoints.isEmpty {
            return WorkDeskPoint(
                x: selectedPoints.reduce(0) { $0 + $1.x } / Double(selectedPoints.count),
                y: selectedPoints.reduce(0) { $0 + $1.y } / Double(selectedPoints.count)
            )
        }
        if let point = canvasSession(for: .desk).projectInsertionPoint { return point }

        let materialFrames = organization.placements.values.compactMap { placement -> CGRect? in
            guard organization.projectID(for: placement.materialID) == nil,
                  let point = placement.position else { return nil }
            return WorkDeskCanvasGeometry.frame(at: point,
                bodySize: WorkDeskCanvasGeometry.cardBodySize, scale: 1)
        }
        let projectFrames = organization.projects.compactMap { project -> CGRect? in
            guard let point = project.position else { return nil }
            return WorkDeskCanvasGeometry.frame(at: point,
                bodySize: WorkDeskCanvasGeometry.projectBodySize, scale: 1)
        }
        return WorkDeskCanvasGeometry.availablePoint(occupied: materialFrames + projectFrames,
            columns: canvasSession(for: .desk).columns,
            bodySize: WorkDeskCanvasGeometry.projectBodySize, scale: 1)
            ?? WorkDeskCanvasGeometry.defaultPoint(index: 0, columns: 1)
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
