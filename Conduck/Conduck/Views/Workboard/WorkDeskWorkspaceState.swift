// SPDX-License-Identifier: Apache-2.0

// Presentation of the personal desk. Filters never change material ownership:
// every capture stays on the canonical desk, and projects refer to its cards.
// Active selection is intersected with the visible snapshot before every
// operation. Search parks hidden selections until those cards are visible again.
// Composer sessions follow their destination, including Home during
// global search, so looking elsewhere never silently redirects unfinished work.

import SwiftUI

enum WorkDeskScope: Hashable, Sendable {
    case all, project(UUID)

    var location: WorkDeskLocation {
        switch self {
        case .all: .home
        case .project(let id): .project(id)
        }
    }

    init(location: WorkDeskLocation) {
        switch location {
        case .home: self = .all
        case .project(let id): self = .project(id)
        }
    }
}

@Observable @MainActor
final class WorkDeskWorkspaceState {
    let organization: WorkDeskOrganization
    let transferCoordinator = WorkDeskTransferCoordinator()
    let projectPreview = WorkDeskProjectPreviewState()
    let organizationUndo = WorkDeskOrganizationUndoController()
    var scope: WorkDeskScope = .all
    var isActive = false
    var search = "" {
        didSet {
            if search != oldValue { projectPreview.dismiss(force: true) }
            let searching = !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if isSearching != searching { isSearching = searching }
            if searching {
                transferCoordinator.cancel()
                suspendConversation()
                conversationSelectionRequest = nil
            }
        }
    }
    private(set) var isSearching = false
    var selectedIDs: Set<UUID> = []
    var isSelecting = false {
        didSet { if !isSelecting { hiddenSelectionIDs.removeAll() } }
    }
    var searchIsFocused = false
    var showsSidebar = true
    var presentsSidebarInline = true
    var showsProjectPicker = false
    var projectEditor: WorkDeskProjectEditorRequest?
    var pendingProjectEditor: WorkDeskProjectEditorRequest?
    private var limitedProjectEditor: WorkDeskProjectEditorRequest?
    private var managesProjectsAfterLimit = false
    private var pendingProjectAccessRequest: UUID?
    var editorTitle = ""
    var briefDrafts: [UUID: WorkDeskBriefDraft] = [:]
    var briefRevisions: [UUID: Date] = [:]
    var preparingProjectID: UUID?
    var conversationSelectionRequest: WorkDeskConversationSelectionRequest?
    var editingContextProjectID: UUID?
    var deletingProjectID: UUID?
    var projectDeletionReview: WorkDeskProjectDeletionReview?
    var materialUsePickerID: UUID?
    var materialRevealRequest: WorkDeskMaterialRevealRequest?
    private(set) var projectConversations: [ConversationRecord] = []
    private(set) var results: [UUID: WorkDeskResultRecord] = [:]
    private(set) var materialUses: [UUID: [WorkDeskMaterialUseRecord]] = [:]
    private var materialGroupIDs: [UUID: Set<UUID>] = [:]
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
    @ObservationIgnored private let draftStore: WorkDeskBriefDraftStore
    @ObservationIgnored private var canvasSessions: [WorkDeskScope: WorkDeskCanvasSession] = [:]
    @ObservationIgnored private var composerSessions: [WorkDeskScope: WorkDeskComposerSession] = [:]
    @ObservationIgnored private var layoutSessions: [WorkDeskScope: WorkDeskLayoutSession] = [:]
    @ObservationIgnored private var hiddenSelectionIDs: Set<UUID> = []
    @ObservationIgnored private var refreshCoordinator: WorkDeskWorkspaceRefreshCoordinator?
    @ObservationIgnored private var refreshMaterials: @MainActor () -> [WorkboardMaterialSnapshot] = { [] }
    private static var liveWorkspaces: [WeakWorkspace] = []

    private final class WeakWorkspace {
        weak var value: WorkDeskWorkspaceState?
        init(_ value: WorkDeskWorkspaceState) { self.value = value }
    }

    /// A tombstone learned in any window releases sessions in every live window.
    /// Weak registration does not keep a closed window or its drafts alive.
    static func pruneProjectSessions(deletedProjectIDs: Set<UUID>) {
        guard !deletedProjectIDs.isEmpty else { return }
        liveWorkspaces.removeAll { $0.value == nil }
        // Include requests that have never been opened in this process.
        try? WorkDeskBriefDraftStore.shared.deleteProjects(deletedProjectIDs)
        for workspace in liveWorkspaces.compactMap(\.value) {
            do { try workspace.draftStore.deleteProjects(deletedProjectIDs) }
            catch {
                workspace.organization.errorMessage = String(localized: "workdesk.draft.clearFailed",
                    defaultValue: "This draft couldn’t be removed from this device. Try again.")
            }
            for id in deletedProjectIDs {
                workspace.briefDrafts.removeValue(forKey: id)
                workspace.briefRevisions.removeValue(forKey: id)
                if workspace.preparingProjectID == id { workspace.preparingProjectID = nil }
                let scope = WorkDeskScope.project(id)
                workspace.composerSessions.removeValue(forKey: scope)?.setText("")
                // Invalidate a view that still observes the old session while
                // its window waits to receive the organization refresh.
                workspace.layoutSessions.removeValue(forKey: scope)?.mode = .tiles
                workspace.canvasSessions.removeValue(forKey: scope)
            }
        }
    }

    /// Navigation remembers the selected project during global search. The
    /// visible board, layout controls and capture destination agree on Home
    /// for that temporary aggregate surface.
    var displayedScope: WorkDeskScope { isSearching ? .all : scope }
    var composerScope: WorkDeskScope { displayedScope }

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

    init(organization: WorkDeskOrganization? = nil, conversationStore: ConversationStore = .shared,
         draftStore: WorkDeskBriefDraftStore = .shared) {
        self.organization = organization ?? WorkDeskOrganization()
        self.conversationStore = conversationStore
        self.draftStore = draftStore
        Self.liveWorkspaces.removeAll { $0.value == nil }
        Self.liveWorkspaces.append(WeakWorkspace(self))
    }

    /// A real mount requests a complete snapshot. Mode changes only drain
    /// changes recorded while hidden, so a round trip through Chats neither
    /// reloads Settings nor scans all project results again.
    func startRefreshing(
        isActive: Bool,
        materials: @escaping @MainActor () -> [WorkboardMaterialSnapshot]
    ) {
        refreshMaterials = materials
        if refreshCoordinator == nil {
            refreshCoordinator = WorkDeskWorkspaceRefreshCoordinator { [weak self] request in
                guard let self else { return }
                if request.contains(.settings) { await conversationSettings.loadSettings() }
                if !request.intersection([.organization, .results]).isEmpty {
                    await organization.reload()
                    await reloadProjectActivity(reconcileResults: request.contains(.results))
                    // The desk can change while these reads suspend. Reconcile
                    // the current cards, never the mounting view's old value.
                    reconcile(materials: refreshMaterials())
                }
            }
        }
        requestRefresh(.all)
        setRefreshActive(isActive)
    }

    func requestRefresh(_ request: WorkDeskWorkspaceRefreshCoordinator.Request) {
        refreshCoordinator?.request(request)
    }

    func setRefreshActive(_ active: Bool) {
        isActive = active
        refreshCoordinator?.setActive(active)
    }

    var currentProject: WorkDeskProjectRecord? {
        guard case .project(let id) = scope else { return nil }
        return organization.project(id: id)
    }

    /// One native presenter owns a free-project choice, including a contents
    /// preview that is itself a sheet on compact devices. Closing a preview
    /// changes presentation ownership without changing the requested choice.
    enum ProjectSelectionPresenter: Equatable {
        case workspace, picker, preview(UUID)
    }

    var projectSelectionPresenter: ProjectSelectionPresenter? {
        guard isActive, organization.projectSelectionRequested,
              organization.canPresentFreeProjectSelection else { return nil }
        if let request = projectPreview.request { return .preview(request.id) }
        if showsProjectPicker { return .picker }
        guard projectEditor == nil, preparingProjectID == nil,
              editingContextProjectID == nil, projectDeletionReview == nil,
              materialUsePickerID == nil else { return nil }
        return .workspace
    }

    var showsProjectAccessRecovery: Bool {
        organization.canPresentFreeProjectSelection || (currentProject?.isArchived == true && !isSearching)
    }

    var currentProjectAllowsNewActivity: Bool {
        currentProject?.isArchived == false && !organization.requiresFreeProjectSelection
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
        projectPreview.dismiss(force: true)
        suspendConversation()
        conversationSelectionRequest = nil
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
        openRelatedConversation(result.conversationID)
    }

    func openRelatedConversation(_ conversationID: UUID) {
        materialUsePickerID = nil
        if let projectID = projectConversations.first(where: { $0.id == conversationID })?.projectID,
           organization.project(id: projectID) != nil {
            selectConversation(conversationID, projectID: projectID)
        } else {
            NotificationCenter.default.post(name: .openConversationDeepLink, object: nil,
                userInfo: [NotificationDeepLink.conversationIDKey: conversationID.uuidString])
        }
    }

    /// A folded card can have sent its picture and words together. Count the
    /// actual conversations once, without treating a project's other chats as
    /// uses or making the historical receipt a second material owner.
    func uses(for materialID: UUID) -> [WorkDeskMaterialUseRecord] {
        let ids = materialGroupIDs[materialID] ?? [materialID]
        var byConversation: [UUID: WorkDeskMaterialUseRecord] = [:]
        for id in ids {
            for use in materialUses[id] ?? [] {
                if byConversation[use.conversationID].map({ $0.sentAt >= use.sentAt }) == true { continue }
                byConversation[use.conversationID] = use
            }
        }
        return byConversation.values.sorted {
            $0.sentAt != $1.sentAt ? $0.sentAt > $1.sentAt : $0.conversationID.uuidString < $1.conversationID.uuidString
        }
    }

    func suspendConversation() {
        if let id = selectedConversationID { conversationSessions[id]?.suspend() }
    }

    private func pruneConversationModels() {
        let sending = Set(briefDrafts.values.filter { $0.handoff.isSending }
            .compactMap { $0.handoff.prepared?.id ?? $0.handoff.acceptedConversationID })
        for (id, model) in conversationModels {
            // A hidden Work thread is still mounted and still owns this VM.
            // Keep the selected lease until actual conversation navigation;
            // releasing it on a mode switch can mint a competing sender on return.
            guard selectedConversationID != id, !model.isAwaitingReply,
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
            let uses = try await conversationStore.fetchWorkDeskMaterialUses()
            guard generation == conversationReloadGeneration else { return }
            projectConversations = conversations.filter { $0.projectID != nil }
            let arrivingResults = Set(sources.keys).subtracting(results.keys)
            for draft in briefDrafts.values {
                draft.excludedIDs.formUnion(arrivingResults.subtracting(draft.projectResultIDs))
                draft.projectResultIDs.formUnion(Set(sources.keys).union(resultMaterialIDs))
                draft.remoteResultIDs = Set(sources.values.filter(\.isRemoteReference).map(\.materialID)).union(remoteResultMaterialIDs)
            }
            results = sources
            materialUses = uses
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

    func visibleMaterials(in materials: [WorkboardMaterialSnapshot], scope requestedScope: WorkDeskScope? = nil,
                          search requestedSearch: String? = nil) -> [WorkboardMaterialSnapshot] {
        let resolvedScope = requestedScope ?? scope
        let query = (requestedSearch ?? search).trimmingCharacters(in: .whitespacesAndNewlines)
        let matchingProjects = Set(organization.projects.lazy.filter {
            !query.isEmpty && $0.title.localizedStandardContains(query)
        }.map(\.id))
        let visible = materials.filter { material in
            // Search is a way back to anything on the desk, including a note
            // filed in a project. Clearing it restores the person's scope.
            if !query.isEmpty {
                if matchingProjects.contains(where: { organization.contains(materialID: material.id, at: .project($0)) }) { return true }
                return [material.name, material.textContent ?? "", material.detail ?? "",
                        material.annotation ?? "", material.companion?.textContent ?? "",
                        material.companion?.annotation ?? ""]
                    .contains { $0.localizedStandardContains(query) }
            }
            return organization.contains(materialID: material.id, at: resolvedScope.location)
        }
        guard query.isEmpty else { return visible }
        let indices = Dictionary(visible.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { first, _ in first })
        let ranks = Dictionary(uniqueKeysWithValues: visible.compactMap { material -> (UUID, Double)? in
            guard let rank = organization.locations(for: material.id).first(where: { $0.location == resolvedScope.location })?.sortRank,
                  rank.isFinite else { return nil }
            return (material.id, rank)
        })
        return visible.sorted {
            let lhs = ranks[$0.id] ?? .greatestFiniteMagnitude
            let rhs = ranks[$1.id] ?? .greatestFiniteMagnitude
            return lhs == rhs ? (indices[$0.id] ?? 0) < (indices[$1.id] ?? 0) : lhs < rhs
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

    /// Search may be requested while its native sidebar or compact picker is
    /// absent. The shared field consumes focus when that surface appears.
    func requestSearch() {
        if presentsSidebarInline { showsSidebar = true }
        else { showsProjectPicker = true }
        searchIsFocused = true
    }

    func gatewayName(for conversation: ConversationRecord) -> String {
        guard let ref = RemoteAgentRef(rawString: conversation.backend) else {
            return String(localized: "workdesk.conversation.connectionMissing", defaultValue: "Connection unavailable")
        }
        return RemoteAgentRefMetadata.displayName(for: ref, customs: conversationSettings.customGateways)
    }

    func updateSidebarLayout(isInline: Bool) {
        presentsSidebarInline = isInline
        if isInline { showsProjectPicker = false }
    }

    /// Compact project-navigation controls and native sidebar hosts share state.
    /// A compact window opens the project picker; it never toggles a hidden rail.
    func toggleProjectNavigation() {
        if presentsSidebarInline { showsSidebar.toggle() }
        else { showsProjectPicker.toggle() }
    }

    func selectScope(_ scope: WorkDeskScope) {
        projectPreview.dismiss(force: true)
        transferCoordinator.cancel()
        suspendConversation()
        selectedConversationID = nil
        conversationSelectionRequest = nil
        materialRevealRequest = nil
        pruneConversationModels()
        self.scope = scope
        search = ""
        selectedIDs = []
        isSelecting = false
        showsProjectPicker = false
    }

    /// Search results belong to an aggregate display, not a navigation change.
    /// Selecting one must preserve the query and the project to return to.
    func selectMaterial(_ id: UUID, in boardScope: WorkDeskScope) {
        if !isSearching, scope != boardScope { selectScope(boardScope) }
        toggleSelection(id)
    }

    func toggleSelection(_ id: UUID) {
        isSelecting = true
        if selectedIDs.contains(id) { selectedIDs.remove(id) }
        else { selectedIDs.insert(id) }
    }

    func reconcile(materials: [WorkboardMaterialSnapshot]) {
        if let request = projectPreview.request, organization.project(id: request.projectID) == nil {
            projectPreview.dismiss(force: true)
        }
        materialGroupIDs = Dictionary(uniqueKeysWithValues: materials.map {
            ($0.id, Set([$0.id] + ($0.companion.map { [$0.id] } ?? [])))
        })
        let materialResults = Set(materials.filter(\.isProjectResult).map(\.id))
        let newResults = materialResults.subtracting(resultMaterialIDs)
        resultMaterialIDs = materialResults
        remoteResultMaterialIDs = Set(materials.filter(\.isRemoteProjectResult).map(\.id))
        for draft in briefDrafts.values {
            draft.excludedIDs.formUnion(newResults.subtracting(draft.projectResultIDs))
            draft.projectResultIDs.formUnion(Set(results.keys).union(materialResults))
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
        guard organization.hasLoadedProAccess else {
            let token = UUID(), requestedScope = scope
            pendingProjectAccessRequest = token
            Task {
                await organization.awaitInitialProAccess()
                guard isActive, scope == requestedScope, pendingProjectAccessRequest == token else { return }
                pendingProjectAccessRequest = nil
                beginProject(materialIDs: materialIDs, position: position)
            }
            return
        }
        let request = WorkDeskProjectEditorRequest(project: nil, materialIDs: materialIDs,
            position: projectCreationPosition(materialIDs: materialIDs, requested: position))
        guard organization.canCreateProject else {
            limitedProjectEditor = request
            organization.requestProjectLimit()
            return
        }
        presentEditor(request)
    }

    func projectLimitDidDismiss() {
        defer { limitedProjectEditor = nil }
        if managesProjectsAfterLimit {
            managesProjectsAfterLimit = false
            if organization.requiresFreeProjectSelection { organization.projectSelectionRequested = true }
            else if presentsSidebarInline { showsSidebar = true }
            else { showsProjectPicker = true }
            return
        }
        guard organization.hasProAccess, let limitedProjectEditor else { return }
        presentEditor(limitedProjectEditor)
    }

    func manageProjectsFromLimit() {
        managesProjectsAfterLimit = true
        organization.projectLimitRequested = false
    }

    /// The project detail header uses this admission check.
    /// Opening never resets a retained request or starts a gateway operation.
    @discardableResult
    func beginConversation(resolver: WorkDeskConversationResolver) -> Bool {
        guard isActive, !isSearching, let project = currentProject,
              currentProjectAllowsNewActivity else { return false }
        _ = briefDraft(for: project, resolver: resolver)
        preparingProjectID = project.id
        return true
    }

    /// A card menu retains identifiers rather than a copied snapshot/resolver.
    /// The visible workspace checks them against its latest material snapshot
    /// before opening preparation, so a delayed menu action cannot change scope
    /// or quietly shrink the set the person asked to use.
    func requestConversation(materialIDs: Set<UUID>) {
        guard !isSearching, let project = currentProject, currentProjectAllowsNewActivity, !materialIDs.isEmpty else { return }
        conversationSelectionRequest = WorkDeskConversationSelectionRequest(projectID: project.id, materialIDs: materialIDs)
    }

    @discardableResult
    func beginConversation(materialIDs: Set<UUID>, materials: [WorkboardMaterialSnapshot],
                           resolver: WorkDeskConversationResolver) -> Bool {
        guard isActive, !isSearching, let project = currentProject, currentProjectAllowsNewActivity, !materialIDs.isEmpty else { return false }
        let available = Set(visibleMaterials(in: materials).map(\.id))
        guard materialIDs.isSubset(of: available) else {
            organization.errorMessage = String(localized: "workdesk.conversation.selectionChanged",
                defaultValue: "The selected materials changed. Choose them again.")
            return false
        }
        if let existing = briefDrafts[project.id],
           existing.isSaving || existing.handoff.isPreparing || existing.handoff.isSending {
            return false
        }
        let draft = briefDraft(for: project, resolver: resolver)
        guard draft.useOnlyMaterials(materialIDs, materials: materials) else { return false }
        preparingProjectID = project.id
        return true
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

    func requestProjectDeletion(_ id: UUID) {
        guard isActive, deletingProjectID == nil, projectDeletionReview == nil else { return }
        deletingProjectID = id
        if showsProjectPicker { showsProjectPicker = false }
        else { Task { await prepareProjectDeletion(id: id) } }
    }

    func prepareProjectDeletion(id: UUID) async {
        guard deletingProjectID == id, isActive else { return }
        let review = await organization.reviewProjectDeletion(id: id)
        guard deletingProjectID == id, isActive else { return }
        deletingProjectID = nil
        projectDeletionReview = review
    }

    /// Selecting All materials must not reset its saved layout. Retained cards
    /// are highlighted there, and their own cluster is revealed in Desk view.
    func finishProjectDeletion(_ review: WorkDeskProjectDeletionReview, keptMaterials: Bool,
                               materials: [WorkboardMaterialSnapshot]) {
        projectDeletionReview = nil
        deletingProjectID = nil
        selectScope(.all)
        guard keptMaterials else { return }
        selectedIDs = Set(review.visibleMaterialIDs).intersection(visibleMaterials(in: materials, scope: .all, search: "").map(\.id))
        isSelecting = !selectedIDs.isEmpty
        materialRevealRequest = review.visibleMaterialIDs.first(where: { selectedIDs.contains($0) })
            .map { WorkDeskMaterialRevealRequest(materialID: $0) }
        let frames = selectedIDs.compactMap { id -> CGRect? in
            guard let point = organization.placements[id]?.resolvedHomePosition else { return nil }
            return WorkDeskCanvasGeometry.frame(at: point, bodySize: WorkDeskCanvasGeometry.cardBodySize, scale: 1)
        }
        let session = canvasSession(for: .all)
        session.reveal(frames: frames)
        session.bringToFront(selectedIDs.map { .material($0) })
    }

    func suspend() {
        projectPreview.dismiss(force: true)
        transferCoordinator.cancel()
        setRefreshActive(false)
        deletingProjectID = nil
        projectDeletionReview = nil
        materialUsePickerID = nil
        conversationSelectionRequest = nil
        suspendConversation()
        for draft in briefDrafts.values { draft.suspendPresentation() }
        pruneConversationModels()
    }

    func endBriefEditing(projectID: UUID) {
        guard briefDrafts[projectID]?.handoff.isSending != true else { return }
        briefDrafts[projectID]?.suspendPresentation()
    }

    func briefDraft(for project: WorkDeskProjectRecord, resolver: WorkDeskConversationResolver) -> WorkDeskBriefDraft {
        if let existing = briefDrafts[project.id], !existing.persistedRequestWasRemoved {
            existing.refreshProjectContext(project.brief)
            briefRevisions[project.id] = project.updatedAt
            return existing
        }
        let draft = WorkDeskBriefDraft(brief: project.brief, preferredGatewayRef: project.preferredGatewayRef, conversationResolver: resolver,
                                      projectID: project.id, persistence: draftStore)
        // A result joining the project is not permission to send it elsewhere.
        let currentResults = Set(results.keys).union(resultMaterialIDs)
        draft.excludedIDs.formUnion(currentResults.subtracting(draft.projectResultIDs))
        draft.projectResultIDs.formUnion(currentResults)
        draft.remoteResultIDs = Set(results.values.filter(\.isRemoteReference).map(\.materialID)).union(remoteResultMaterialIDs)
        briefDrafts[project.id] = draft
        briefRevisions[project.id] = project.updatedAt
        return draft
    }

    func finishConversationDraft(projectID: UUID) {
        guard briefDrafts[projectID]?.clearPersistedRequest() != false else { return }
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
        } else if let deletingProjectID {
            Task { await prepareProjectDeletion(id: deletingProjectID) }
        }
    }

    func assignSelection(to projectID: UUID?, materials: [WorkboardMaterialSnapshot]) async {
        let ids = visibleMaterials(in: materials).map(\.id).filter { selectedIDs.contains($0) }
        guard !ids.isEmpty else { return }
        let target: WorkDeskLocation = projectID.map(WorkDeskLocation.project) ?? .home
        // Search is a complete collection, so it names no source location to
        // remove. Its organization action deliberately adds an appearance.
        let saved = isSearching
            ? await organization.add(materialIDs: ids, to: target, positions: [:])
            : await organization.move(materialIDs: ids, from: scope.location, to: target, positions: [:])
        if saved {
            selectedIDs = []
            isSelecting = false
        }
    }

    @discardableResult
    func transfer(_ request: WorkDeskTransferRequest, materials: [WorkboardMaterialSnapshot]) async -> Bool {
        guard isActive else { return false }
        let available = Set(materials.map(\.id))
        guard !request.materialIDs.isEmpty, Set(request.materialIDs).isSubset(of: available) else { return false }
        let saved = await organization.move(materialIDs: request.materialIDs, from: request.source,
            to: request.destination, positions: request.positions, expected: request.expected)
        if saved { reconcile(materials: materials) }
        return saved
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

struct WorkDeskConversationSelectionRequest: Identifiable {
    let id = UUID()
    let projectID: UUID
    let materialIDs: Set<UUID>
}

struct WorkDeskMaterialRevealRequest: Identifiable {
    let id = UUID()
    let materialID: UUID
}
