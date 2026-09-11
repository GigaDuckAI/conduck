// SPDX-License-Identifier: Apache-2.0

// Presentation of the personal desk. Filters never change material ownership:
// every capture stays on the canonical desk, and projects refer to its cards.
// Active selection is intersected with the visible snapshot before every
// operation. Search parks hidden selections until those cards are visible again.
// Composer sessions follow their destination, including All materials during
// global search, so looking elsewhere never silently redirects unfinished work.

import SwiftUI

enum WorkDeskScope: Hashable {
    case all, project(UUID)
}

@Observable @MainActor
final class WorkDeskWorkspaceState {
    let organization: WorkDeskOrganization
    var scope: WorkDeskScope = .all
    var isActive = false
    var search = "" {
        didSet {
            let searching = !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if isSearching != searching { isSearching = searching }
        }
    }
    private(set) var isSearching = false
    var selectedIDs: Set<UUID> = []
    var isSelecting = false {
        didSet { if !isSelecting { hiddenSelectionIDs.removeAll() } }
    }
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
    @ObservationIgnored private var composerSessions: [WorkDeskScope: WorkDeskComposerSession] = [:]
    @ObservationIgnored private var layoutSessions: [WorkDeskScope: WorkDeskLayoutSession] = [:]
    @ObservationIgnored private var hiddenSelectionIDs: Set<UUID> = []
    private static var liveWorkspaces: [WeakWorkspace] = []

    private final class WeakWorkspace {
        weak var value: WorkDeskWorkspaceState?
        init(_ value: WorkDeskWorkspaceState) { self.value = value }
    }

    /// A tombstone learned in any window releases sessions in every live window.
    /// Weak registration does not keep a closed window or its drafts alive.
    static func pruneProjectSessions(deletedProjectIDs: Set<UUID>) {
        liveWorkspaces.removeAll { $0.value == nil }
        for workspace in liveWorkspaces.compactMap(\.value) {
            for id in deletedProjectIDs {
                let scope = WorkDeskScope.project(id)
                workspace.composerSessions.removeValue(forKey: scope)?.setText("")
                // Invalidate a view that still observes the old session while
                // its window waits to receive the organization refresh.
                workspace.layoutSessions.removeValue(forKey: scope)?.mode = .tiles
                workspace.canvasSessions.removeValue(forKey: scope)
            }
        }
    }

    var composerScope: WorkDeskScope { isSearching ? .all : scope }

    func composerSession(for scope: WorkDeskScope) -> WorkDeskComposerSession {
        if WorkboardLayoutMode.isDeleted(scope) { return WorkDeskComposerSession() }
        if let existing = composerSessions[scope] { return existing }
        let session = WorkDeskComposerSession()
        composerSessions[scope] = session
        return session
    }

    func layoutSession(for scope: WorkDeskScope) -> WorkDeskLayoutSession {
        if WorkboardLayoutMode.isDeleted(scope) { return WorkDeskLayoutSession(scope: scope) }
        if let existing = layoutSessions[scope] { return existing }
        let session = WorkDeskLayoutSession(scope: scope)
        layoutSessions[scope] = session
        return session
    }

    func canvasSession(for scope: WorkDeskScope) -> WorkDeskCanvasSession {
        if let existing = canvasSessions[scope] { return existing }
        let session = WorkDeskCanvasSession()
        canvasSessions[scope] = session
        return session
    }

    init(organization: WorkDeskOrganization? = nil) {
        self.organization = organization ?? WorkDeskOrganization()
        Self.liveWorkspaces.removeAll { $0.value == nil }
        Self.liveWorkspaces.append(WeakWorkspace(self))
    }

    var currentProject: WorkDeskProjectRecord? {
        guard case .project(let id) = scope else { return nil }
        return organization.project(id: id)
    }

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
            case .all: return true
            case .project(let id): return projectID == id
            }
        }
    }

    var supportsSpatialLayout: Bool {
        !isSearching
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
            selectScope(.all)
        }
        let visibleIDs = Set(visibleMaterials(in: materials).map(\.id))
        let survivingIDs = Set(materials.map(\.id))
        let retainedSelection = selectedIDs.union(hiddenSelectionIDs).intersection(survivingIDs)
        selectedIDs = retainedSelection.intersection(visibleIDs)
        hiddenSelectionIDs = isSearching ? retainedSelection.subtracting(visibleIDs) : []
        if materials.isEmpty { isSelecting = false }
    }

    func beginProject(materialIDs: [UUID] = [], position: WorkDeskPoint? = nil) {
        presentEditor(WorkDeskProjectEditorRequest(project: nil, materialIDs: materialIDs,
            position: projectCreationPosition(materialIDs: materialIDs, requested: position)))
    }

    /// Freeze the intended spot before presenting the editor. A delayed save
    /// or a later camera movement must not relocate the project being named.
    private func projectCreationPosition(materialIDs: [UUID], requested: WorkDeskPoint?) -> WorkDeskPoint {
        let selectedPoints = Set(materialIDs).compactMap { organization.placements[$0]?.resolvedHomePosition }
        let centroid: WorkDeskPoint? = selectedPoints.isEmpty ? nil : WorkDeskPoint(
            x: selectedPoints.reduce(0) { $0 + $1.x } / Double(selectedPoints.count),
            y: selectedPoints.reduce(0) { $0 + $1.y } / Double(selectedPoints.count)
        )
        let desired = requested ?? centroid ?? canvasSession(for: .all).projectInsertionPoint
        let materialFrames = organization.placements.values.compactMap { placement -> CGRect? in
            guard let point = placement.resolvedHomePosition else { return nil }
            return WorkDeskCanvasGeometry.frame(at: point,
                bodySize: WorkDeskCanvasGeometry.cardBodySize, scale: 1)
        }
        let projectFrames = organization.projects.compactMap { project -> CGRect? in
            guard let point = project.position else { return nil }
            return WorkDeskCanvasGeometry.frame(at: point,
                bodySize: WorkDeskCanvasGeometry.projectBodySize, scale: 1)
        }
        let occupied = materialFrames + projectFrames
        if let desired, let nearby = WorkDeskCanvasGeometry.availablePoint(near: desired,
            occupied: occupied, bodySize: WorkDeskCanvasGeometry.projectBodySize) { return nearby }
        return WorkDeskCanvasGeometry.availablePoint(occupied: occupied,
            columns: canvasSession(for: .all).columns,
            bodySize: WorkDeskCanvasGeometry.projectBodySize, scale: 1)
            ?? desired ?? WorkDeskCanvasGeometry.defaultPoint(index: 0, columns: 1)
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

/// Emptiness remains a stored coarse observation seam. Reading it must not
/// subscribe a whole board to text changes that leave the draft nonempty.
@Observable @MainActor
final class WorkDeskComposerSession {
    private(set) var text = ""
    private(set) var hasDraft = false

    func setText(_ value: String) {
        text = value
        let hasThought = !WorkboardWorkspaceCaptureLogic.normalizedThought(value).isEmpty
        if hasDraft != hasThought { hasDraft = hasThought }
    }
}

/// Initial reads never persist. The model's explicit layout setter is the
/// only writer, keeping readable search/accessibility fallbacks temporary.
@Observable @MainActor
final class WorkDeskLayoutSession {
    var mode: WorkboardLayoutMode

    init(scope: WorkDeskScope) {
        mode = WorkboardLayoutMode.load(for: scope)
    }
}

struct WorkDeskProjectEditorRequest: Identifiable {
    let id = UUID()
    let project: WorkDeskProjectRecord?
    let materialIDs: [UUID]
    var position: WorkDeskPoint? = nil
}
