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
            if searching { suspendConversation() }
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
    var editingContextProjectID: UUID?
    var deletingProjectID: UUID?
    private(set) var projectConversations: [ConversationRecord] = []
    private(set) var results: [UUID: WorkDeskResultRecord] = [:]
    private var resultMaterialIDs: Set<UUID> = []
    private var remoteResultMaterialIDs: Set<UUID> = []
    var selectedConversationID: UUID?
    var expandedProjectIDs: Set<UUID> = []
    var conversationLoadError: String?
    let conversationSettings = SettingsViewModel()
    @ObservationIgnored private var conversationModels: [UUID: ConversationDetailViewModel] = [:]
    @ObservationIgnored private var conversationLeases: [UUID: WorkDeskConversationLease] = [:]
    @ObservationIgnored private var conversationSessions: [UUID: WorkDeskConversationSession] = [:]
    @ObservationIgnored private var conversationReloadGeneration = 0
    @ObservationIgnored private let conversationStore: ConversationStore
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

    init(organization: WorkDeskOrganization? = nil, conversationStore: ConversationStore = .shared) {
        self.organization = organization ?? WorkDeskOrganization()
        self.conversationStore = conversationStore
        Self.liveWorkspaces.removeAll { $0.value == nil }
        Self.liveWorkspaces.append(WeakWorkspace(self))
    }

    var currentProject: WorkDeskProjectRecord? {
        guard case .project(let id) = scope else { return nil }
        return organization.project(id: id)
    }

    var currentConversation: ConversationRecord? {
        guard !isSearching, let id = selectedConversationID else { return nil }
        return projectConversations.first { $0.id == id && $0.projectID == currentProject?.id }
    }

    var isShowingConversation: Bool { !isSearching && selectedConversationID != nil }

    func conversations(in projectID: UUID) -> [ConversationRecord] {
        projectConversations.filter { $0.projectID == projectID }
    }

    func conversationSession(for id: UUID) -> WorkDeskConversationSession {
        if let session = conversationSessions[id] { return session }
        let session = WorkDeskConversationSession(conversationID: id)
        conversationSessions[id] = session
        return session
    }

    /// The sender and visible thread share one owner. macOS supplies its
    /// coordinator registry; iOS retains the same model created at handoff.
    func conversationModel(for id: UUID, resolver: WorkDeskConversationResolver) -> ConversationDetailViewModel? {
        if let model = conversationModels[id] { return model }
        #if os(macOS)
        let owner = UUID()
        guard let model = resolver.retain?(id, owner) ?? resolver.resolve(id) else { return nil }
        conversationModels[id] = model
        conversationLeases[id] = WorkDeskConversationLease(ownerID: owner, release: resolver.release)
        return model
        #else
        let model = resolver.resolve(id) ?? ConversationDetailViewModel(conversationID: id)
        conversationModels[id] = model
        return model
        #endif
    }

    func selectConversation(_ id: UUID, projectID: UUID) {
        suspendConversation()
        scope = .project(projectID)
        search = ""
        selectedIDs = []
        isSelecting = false
        selectedConversationID = id
        pruneConversationModels()
        expandedProjectIDs.insert(projectID)
        showsProjectPicker = false
    }

    func openResultSource(_ result: WorkDeskResultRecord) {
        if organization.project(id: result.projectID) != nil {
            selectConversation(result.conversationID, projectID: result.projectID)
        } else {
            NotificationCenter.default.post(name: .openConversationDeepLink, object: nil,
                userInfo: [NotificationDeepLink.conversationIDKey: result.conversationID.uuidString])
        }
    }

    func suspendConversation() {
        if let id = selectedConversationID { conversationSessions[id]?.suspend() }
    }

    private func pruneConversationModels() {
        let sending = Set(briefDrafts.values.filter { $0.handoff.isSending }
            .compactMap { $0.handoff.prepared?.id ?? $0.handoff.acceptedConversationID })
        for (id, model) in conversationModels {
            guard !(isActive && selectedConversationID == id), !model.isAwaitingReply,
                  !sending.contains(id) else { continue }
            conversationModels.removeValue(forKey: id)
            conversationLeases.removeValue(forKey: id)
        }
    }

    func reloadProjectActivity(reconcileResults: Bool = false) async {
        conversationReloadGeneration += 1
        let generation = conversationReloadGeneration
        if reconcileResults { await conversationStore.reconcileProjectResults() }
        do {
            let conversations = try await conversationStore.fetchConversations(activity: .turnStates)
            let sources = try await conversationStore.fetchWorkDeskResults()
            guard generation == conversationReloadGeneration else { return }
            projectConversations = conversations.filter { $0.projectID != nil }
            let arrivingResults = Set(sources.keys).subtracting(results.keys)
            for draft in briefDrafts.values {
                draft.excludedIDs.formUnion(arrivingResults)
                draft.projectResultIDs = Set(sources.keys).union(resultMaterialIDs)
                draft.remoteResultIDs = Set(sources.values.filter(\.isRemoteReference).map(\.materialID)).union(remoteResultMaterialIDs)
            }
            results = sources
            conversationLoadError = nil
            if let id = selectedConversationID, !projectConversations.contains(where: { $0.id == id }) {
                suspendConversation()
                selectedConversationID = nil
            }
            pruneConversationModels()
        } catch {
            guard generation == conversationReloadGeneration else { return }
            conversationLoadError = String(localized: "workdesk.conversations.loadFailed", defaultValue: "Conversations couldn’t refresh. Try again.")
        }
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
        suspendConversation()
        selectedConversationID = nil
        pruneConversationModels()
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
        let materialResults = Set(materials.filter(\.isProjectResult).map(\.id))
        let newResults = materialResults.subtracting(resultMaterialIDs)
        resultMaterialIDs = materialResults
        remoteResultMaterialIDs = Set(materials.filter(\.isRemoteProjectResult).map(\.id))
        for draft in briefDrafts.values {
            draft.excludedIDs.formUnion(newResults)
            draft.projectResultIDs = Set(results.keys).union(materialResults)
            draft.remoteResultIDs.formUnion(remoteResultMaterialIDs)
        }
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
        suspendConversation()
        for draft in briefDrafts.values { draft.suspendPresentation() }
        pruneConversationModels()
    }

    func endBriefEditing(projectID: UUID) {
        guard briefDrafts[projectID]?.handoff.isSending != true else { return }
        briefDrafts[projectID]?.suspendPresentation()
    }

    func briefDraft(for project: WorkDeskProjectRecord, resolver: WorkDeskConversationResolver) -> WorkDeskBriefDraft {
        if let existing = briefDrafts[project.id] {
            existing.refreshProjectContext(project.brief)
            briefRevisions[project.id] = project.updatedAt
            return existing
        }
        let draft = WorkDeskBriefDraft(brief: project.brief, preferredGatewayRef: project.preferredGatewayRef, conversationResolver: resolver)
        // A result joining the project is not permission to send it elsewhere.
        draft.excludedIDs = Set(results.keys).union(resultMaterialIDs)
        draft.projectResultIDs = draft.excludedIDs
        draft.remoteResultIDs = Set(results.values.filter(\.isRemoteReference).map(\.materialID)).union(remoteResultMaterialIDs)
        briefDrafts[project.id] = draft
        briefRevisions[project.id] = project.updatedAt
        return draft
    }

    func finishConversationDraft(projectID: UUID) {
        briefDrafts.removeValue(forKey: projectID)
        briefRevisions.removeValue(forKey: projectID)
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
