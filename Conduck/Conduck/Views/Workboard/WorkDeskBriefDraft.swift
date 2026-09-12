// SPDX-License-Identifier: Apache-2.0

// A retained conversation request, separate from its project standing context.
// Selection and handoff state stay independent of any presented editor.

#if !os(watchOS)
import Foundation
import Observation

/// Unsaved project work survives Work being hidden or its macOS layer being
/// unmounted. The host creates this once per editing session and retains it;
/// reopening a sheet must not seed over the person's edits from synced rows.
@Observable @MainActor
final class WorkDeskBriefDraft {
    var projectContext: String
    /// The task for this conversation, never the project's standing context.
    var brief: String { didSet { autosave() } }
    var selectedGateway: RemoteAgentRef? { didSet { autosave() } }
    var excludedIDs: Set<UUID> = [] { didSet { autosave() } }
    /// A selected-material request is an explicit whitelist. Newly synced
    /// cards stay unchecked until the person includes them in this request.
    private(set) var selectedMaterialIDs: Set<UUID>?
    private var selectedCompanionIDs: [UUID: UUID] = [:]
    private(set) var additionalMaterialIDs: Set<UUID> = []
    var remoteResultIDs: Set<UUID> = []
    var projectResultIDs: Set<UUID> = [] { didSet { autosave() } }
    var materialsExpanded: Bool? { didSet { autosave() } }
    private(set) var persistenceError: String?
    private(set) var persistenceConflict: WorkDeskBriefDraftStore.Conflict?
    private(set) var interruptedHandoffID: UUID?
    @ObservationIgnored private var pendingConversationID: UUID?
    private(set) var isPersistenceUnavailable = false
    var persistedRequestWasRemoved: Bool {
        persistenceSession?.isInvalidated == true && handoff.acceptedConversationID == nil
    }
    let handoff: WorkDeskHandoff
    var isSaving = false
    var saveError: String?
    private var savedProjectContext: String
    private var savedGateway: RemoteAgentRef?
    private var activePresentationID: UUID?
    @ObservationIgnored private let persistence: WorkDeskBriefDraftStore?
    @ObservationIgnored private var persistenceSession: WorkDeskBriefDraftStore.Session?
    @ObservationIgnored private var suppressAutosave = false
    @ObservationIgnored private var isClearingPersistence = false
    @ObservationIgnored private var restorationFailed = false

    init(brief: String, preferredGatewayRef: String?, task: String = "", conversationResolver: WorkDeskConversationResolver = .init(), handoff: WorkDeskHandoff? = nil, projectID: UUID? = nil, persistence: WorkDeskBriefDraftStore? = nil) {
        let gateway = preferredGatewayRef.flatMap { RemoteAgentRef(rawString: $0) }
        self.projectContext = brief
        self.brief = task
        self.selectedGateway = gateway
        self.savedProjectContext = brief
        self.savedGateway = gateway
        self.handoff = handoff ?? WorkDeskHandoff(conversationResolver: conversationResolver)
        self.persistence = persistence
        if let projectID, let persistence {
            attachPersistenceSession(persistence.session(projectID: projectID))
            restorePersistedRequest()
        }
        self.handoff.onAccepted = { [weak self] in _ = self?.clearPersistedRequest() }
        self.handoff.onWillSend = { [weak self] id in self?.markHandoffStarting(conversationID: id) ?? false }
        self.handoff.onSendRefused = { [weak self] id in self?.markHandoffRefused(conversationID: id) }
    }

    func beginPresentation() -> UUID {
        let id = UUID()
        activePresentationID = id
        return id
    }

    func endPresentation(_ id: UUID) {
        guard activePresentationID == id else { return }
        suspendPresentation()
    }

    /// Called by the host at destination change, before the sheet's dismissal
    /// animation reaches onDisappear. Old asynchronous completions lose their
    /// navigation authority immediately while an explicitly started send lives.
    func suspendPresentation() {
        activePresentationID = nil
        _ = persistChanges()
        // The handoff invalidates unfinished preparation and releases local
        // review copies. Its own send claim keeps an explicit live send intact.
        handoff.discardPreparation()
    }

    func isCurrentPresentation(_ id: UUID?) -> Bool {
        guard let id else { return false }
        return activePresentationID == id
    }

    func markSaved(projectContext: String, selectedGateway: RemoteAgentRef?) {
        savedProjectContext = projectContext
        savedGateway = selectedGateway
    }

    /// Suggest a destination only while the draft has none. This never changes
    /// the device default or replaces a retained/project choice, even when that
    /// gateway disappears. Review and the named Send still authorize dispatch.
    func prefillGateway(availableRefs: [RemoteAgentRef], defaultRef: RemoteAgentRef?) {
        guard selectedGateway == nil, interruptedHandoffID == nil, !isPersistenceUnavailable,
              !isSaving, !handoff.isPreparing,
              !handoff.isSending, handoff.prepared == nil,
              handoff.acceptedConversationID == nil else { return }
        if let defaultRef, availableRefs.contains(defaultRef) {
            selectedGateway = defaultRef
        } else if availableRefs.count == 1 {
            selectedGateway = availableRefs.first
        }
    }

    /// Refresh only standing context after an explicit edit or a reopened
    /// sheet. Task text and the chosen destination remain this draft's own.
    func refreshProjectContext(_ context: String) {
        projectContext = context
        savedProjectContext = context
        handoff.discardPreparation()
    }

    @discardableResult
    func useOnlyMaterials(_ ids: Set<UUID>, materials: [WorkboardMaterialSnapshot] = []) -> Bool {
        guard !ids.isEmpty, interruptedHandoffID == nil, !isPersistenceUnavailable,
              !isSaving, !handoff.isPreparing, !handoff.isSending else { return false }
        handoff.beginAnotherHandoff()
        handoff.discardPreparation()
        selectedMaterialIDs = ids
        additionalMaterialIDs.formIntersection(ids)
        selectedCompanionIDs = Dictionary(uniqueKeysWithValues: materials.compactMap { material in
            guard ids.contains(material.id), let companion = material.companion else { return nil }
            return (material.id, companion.id)
        })
        excludedIDs.subtract(ids)
        persistChanges()
        return true
    }

    func isMaterialIncluded(_ id: UUID) -> Bool {
        if let selectedMaterialIDs { return selectedMaterialIDs.contains(id) }
        return !excludedIDs.contains(id)
    }

    /// Adding references never moves their project homes. It makes the whole
    /// request explicit, so future arrivals cannot broaden the selected set.
    @discardableResult
    func addMaterials(_ added: [WorkboardMaterialSnapshot], to current: [WorkboardMaterialSnapshot]) -> Bool {
        guard !added.isEmpty, !hasMissingSelectedMaterials(in: current) else { return false }
        let included = includedCards(from: current)
        var seen = Set<UUID>()
        let cards = (included + added).filter { seen.insert($0.id).inserted }
        guard useOnlyMaterials(Set(cards.map(\.id)), materials: cards) else { return false }
        additionalMaterialIDs.formUnion(added.map(\.id))
        persistChanges()
        return true
    }

    /// A new companion arriving on a chosen photo is also a new material.
    /// It enters an explicit selection only when that card is selected again.
    func includedCards(from materials: [WorkboardMaterialSnapshot]) -> [WorkboardMaterialSnapshot] {
        materials.filter { isMaterialIncluded($0.id) }.map { material in
            guard selectedMaterialIDs != nil,
                  material.companion?.id != selectedCompanionIDs[material.id] else { return material }
            var card = material
            card.companion = nil
            return card
        }
    }

    func hasMissingSelectedMaterials(in materials: [WorkboardMaterialSnapshot]) -> Bool {
        guard let selectedMaterialIDs else { return false }
        let currentIDs = Set(materials.map(\.id))
        if !selectedMaterialIDs.isSubset(of: currentIDs) { return true }
        return materials.contains { material in
            guard selectedMaterialIDs.contains(material.id), let selectedCompanion = selectedCompanionIDs[material.id] else { return false }
            return material.companion?.id != selectedCompanion
        }
    }

    /// Explicitly accept a smaller set after removal or reassignment. Newly
    /// attached companions still stay out until their parent is selected again.
    func leaveOutMissingMaterials(in materials: [WorkboardMaterialSnapshot]) {
        guard let selectedMaterialIDs, interruptedHandoffID == nil, !isPersistenceUnavailable,
              !isSaving, !handoff.isPreparing, !handoff.isSending else { return }
        self.selectedMaterialIDs = selectedMaterialIDs.intersection(materials.map(\.id))
        selectedCompanionIDs = selectedCompanionIDs.filter { parentID, companionID in
            materials.contains { $0.id == parentID && $0.companion?.id == companionID }
        }
        handoff.discardPreparation()
        persistChanges()
    }

    func setMaterialIncluded(_ included: Bool, id: UUID, includingCompanionID: UUID? = nil) {
        guard interruptedHandoffID == nil, !isPersistenceUnavailable,
              !isSaving, !handoff.isPreparing, !handoff.isSending else { return }
        handoff.discardPreparation()
        if selectedMaterialIDs != nil {
            if included { selectedMaterialIDs?.insert(id) } else { selectedMaterialIDs?.remove(id) }
            selectedCompanionIDs[id] = included ? includingCompanionID : nil
        }
        if included { excludedIDs.remove(id) } else { excludedIDs.insert(id) }
    }

    @discardableResult
    func discardUnsavedChanges() -> Bool {
        guard interruptedHandoffID == nil, clearPersistedRequest() else { return false }
        resetRequest(restoringGateway: true)
        return true
    }

    /// A new conversation starts with a new task while retaining project context.
    @discardableResult
    func startAnotherConversation() -> Bool {
        guard interruptedHandoffID == nil, !handoff.isSending, !handoff.isPreparing,
              clearPersistedRequest() else { return false }
        handoff.beginAnotherHandoff()
        resetRequest(restoringGateway: false)
        return true
    }

    /// Checked by Close and Review as well as by autosave. A failed initial read
    /// never overwrites the unknown request; Retry first restores that record.
    @discardableResult
    func persistChanges() -> Bool {
        guard !suppressAutosave else { return true }
        guard let persistence, let persistenceSession else { return true }
        if handoff.acceptedConversationID != nil { return clearPersistedRequest() }
        if restorationFailed { return restorePersistedRequest() }
        guard !isPersistenceUnavailable else { return false }
        do {
            try persistence.save(requestRecord, session: persistenceSession)
            persistenceError = nil
            persistenceConflict = nil
            return true
        } catch let conflict as WorkDeskBriefDraftStore.Conflict {
            reportConflict(conflict)
            return false
        } catch {
            persistenceError = String(localized: "workdesk.draft.saveFailed",
                defaultValue: "This draft couldn’t save on this device. Try again before closing.")
            return false
        }
    }

    /// An accepted send owns its conversation already. Failure to remove the
    /// local request is visible and retryable, without starting another send.
    @discardableResult
    func clearPersistedRequest() -> Bool {
        guard let persistence, let persistenceSession else { return true }
        isClearingPersistence = true
        defer { isClearingPersistence = false }
        do {
            try persistence.clear(persistenceSession, preservingNewerRequest: handoff.acceptedConversationID != nil)
            persistenceError = nil
            persistenceConflict = nil
            return true
        } catch let conflict as WorkDeskBriefDraftStore.Conflict {
            reportConflict(conflict)
            return false
        } catch {
            persistenceError = String(localized: "workdesk.draft.clearFailed",
                defaultValue: "This draft couldn’t be removed from this device. Try again.")
            return false
        }
    }

    /// The person has chosen to replace the saved request after seeing its
    /// conflict preview. A newer edit in the other window requires a new choice.
    @discardableResult
    func replacePersistedRequest(resolving conflict: WorkDeskBriefDraftStore.Conflict) -> Bool {
        guard let persistence, let persistenceSession, persistenceConflict != nil,
              !isPersistenceUnavailable, !handoff.isSending, !handoff.isPreparing else { return false }
        do {
            try persistence.replace(requestRecord, session: persistenceSession, conflict: conflict)
            persistenceConflict = nil
            persistenceError = nil
            return true
        } catch let conflict as WorkDeskBriefDraftStore.Conflict {
            reportConflict(conflict)
            return false
        } catch {
            persistenceError = String(localized: "workdesk.draft.saveFailed",
                defaultValue: "This draft couldn’t save on this device. Try again before closing.")
            return false
        }
    }

    /// An explicitly confirmed reload discards this editor's conflicting text,
    /// never an implicit consequence of another window being sent or closed.
    @discardableResult
    func reloadPersistedRequest(resolving conflict: WorkDeskBriefDraftStore.Conflict) -> Bool {
        guard !handoff.isSending, !handoff.isPreparing else { return false }
        // Read first. A refusal must retain every local field for another retry.
        guard let persistence, let persistenceSession else { return true }
        do {
            let saved = try persistence.load(persistenceSession, resolving: conflict)
            suppressAutosave = true
            brief = saved?.task ?? ""
            selectedGateway = saved.map { $0.gatewayRef.flatMap(RemoteAgentRef.init(rawString:)) } ?? savedGateway
            let previouslyKnownResults = projectResultIDs
            excludedIDs = (saved?.excludedIDs ?? []).union(
                previouslyKnownResults.subtracting(saved?.knownProjectResultIDs ?? []))
            selectedMaterialIDs = saved?.selectedMaterialIDs
            selectedCompanionIDs = saved?.selectedCompanionIDs ?? [:]
            additionalMaterialIDs = saved?.additionalMaterialIDs ?? []
            projectResultIDs.formUnion(saved?.knownProjectResultIDs ?? [])
            materialsExpanded = saved?.materialsExpanded
            pendingConversationID = saved?.pendingConversationID
            interruptedHandoffID = saved?.pendingConversationID
            suppressAutosave = false
            persistenceConflict = nil
            persistenceError = nil
            isPersistenceUnavailable = false
            restorationFailed = false
            handoff.discardPreparation()
            return true
        } catch let conflict as WorkDeskBriefDraftStore.Conflict {
            reportConflict(conflict)
            return false
        } catch {
            persistenceError = String(localized: "workdesk.draft.loadFailed",
                defaultValue: "The saved draft couldn’t open. Try again to keep your previous request.")
            return false
        }
    }

    /// Called before a send claims a packet or creates/uploads anything. If the
    /// marker cannot be committed, dispatch has no authority to begin.
    @discardableResult
    func markHandoffStarting(conversationID: UUID) -> Bool {
        guard interruptedHandoffID == nil, !isPersistenceUnavailable else { return false }
        let previous = pendingConversationID
        pendingConversationID = conversationID
        if persistChanges() { return true }
        pendingConversationID = previous
        return false
    }

    /// The handoff proved submission was refused and cleaned its temporary
    /// conversation. If marker cleanup fails, recovery remains explicit.
    func markHandoffRefused(conversationID: UUID) {
        guard pendingConversationID == conversationID else { return }
        pendingConversationID = nil
        if persistChanges() { interruptedHandoffID = nil }
        else {
            pendingConversationID = conversationID
            interruptedHandoffID = conversationID
        }
    }

    /// The host has checked the interrupted conversation and the person has
    /// explicitly chosen a fresh review. A failed marker removal keeps recovery
    /// active and cannot silently authorize another send.
    @discardableResult
    func reviewAfterInterruptedHandoff() -> Bool {
        guard !handoff.isSending, !handoff.isPreparing, handoff.acceptedConversationID == nil else { return false }
        let previous = pendingConversationID
        pendingConversationID = nil
        guard persistChanges() else {
            pendingConversationID = previous
            return false
        }
        interruptedHandoffID = nil
        handoff.beginAnotherHandoff()
        handoff.discardPreparation()
        return true
    }

    private var requestRecord: WorkDeskBriefDraftRecord {
        WorkDeskBriefDraftRecord(pendingConversationID: pendingConversationID,
            task: brief, gatewayRef: selectedGateway?.rawString,
            excludedIDs: excludedIDs, selectedMaterialIDs: selectedMaterialIDs,
            selectedCompanionIDs: selectedCompanionIDs, additionalMaterialIDs: additionalMaterialIDs,
            knownProjectResultIDs: projectResultIDs, materialsExpanded: materialsExpanded)
    }

    private func reportConflict(_ conflict: WorkDeskBriefDraftStore.Conflict) {
        persistenceConflict = conflict
        persistenceError = String(localized: "workdesk.draft.conflict",
            defaultValue: "This project’s draft changed in another window. Your request is still here. Choose which draft to keep.")
    }

    private func autosave() {
        guard !suppressAutosave else { return }
        _ = persistChanges()
    }

    @discardableResult
    private func restorePersistedRequest() -> Bool {
        guard let persistence, let persistenceSession else { return true }
        suppressAutosave = true
        defer { suppressAutosave = false }
        do {
            if let saved = try persistence.load(persistenceSession) {
                brief = saved.task
                selectedGateway = saved.gatewayRef.flatMap(RemoteAgentRef.init(rawString:))
                excludedIDs = saved.excludedIDs.union(projectResultIDs.subtracting(saved.knownProjectResultIDs))
                selectedMaterialIDs = saved.selectedMaterialIDs
                selectedCompanionIDs = saved.selectedCompanionIDs
                additionalMaterialIDs = saved.additionalMaterialIDs
                projectResultIDs.formUnion(saved.knownProjectResultIDs)
                materialsExpanded = saved.materialsExpanded
                pendingConversationID = saved.pendingConversationID
                interruptedHandoffID = saved.pendingConversationID
            }
            persistenceConflict = nil
            restorationFailed = false
            isPersistenceUnavailable = false
            persistenceError = nil
            return true
        } catch {
            restorationFailed = true
            isPersistenceUnavailable = true
            persistenceError = String(localized: "workdesk.draft.loadFailed",
                defaultValue: "The saved draft couldn’t open. Try again to keep your previous request.")
            return false
        }
    }

    private func attachPersistenceSession(_ session: WorkDeskBriefDraftStore.Session) {
        persistenceSession = session
        session.onInvalidated = { [weak self] in
            guard let self, !isClearingPersistence else { return }
            suppressAutosave = true
            brief = ""
            selectedMaterialIDs = nil
            selectedCompanionIDs = [:]
            additionalMaterialIDs = []
            excludedIDs = []
            materialsExpanded = nil
            pendingConversationID = nil
            interruptedHandoffID = nil
            persistenceConflict = nil
            suppressAutosave = false
            isPersistenceUnavailable = true
            restorationFailed = false
            handoff.discardPreparation()
            persistenceError = String(localized: "workdesk.draft.removed",
                defaultValue: "This draft was removed. Close it to start a new conversation.")
        }
    }

    private func resetRequest(restoringGateway: Bool) {
        suppressAutosave = true
        projectContext = savedProjectContext
        brief = ""
        if restoringGateway { selectedGateway = savedGateway }
        excludedIDs = projectResultIDs
        selectedMaterialIDs = nil
        selectedCompanionIDs = [:]
        additionalMaterialIDs = []
        materialsExpanded = nil
        saveError = nil
        persistenceError = nil
        persistenceConflict = nil
        interruptedHandoffID = nil
        pendingConversationID = nil
        isPersistenceUnavailable = false
        restorationFailed = false
        handoff.discardPreparation()
        if let persistence, let projectID = persistenceSession?.projectID {
            attachPersistenceSession(persistence.session(projectID: projectID))
        }
        suppressAutosave = false
    }
}

#endif
