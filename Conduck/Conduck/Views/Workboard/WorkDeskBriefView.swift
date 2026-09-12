// SPDX-License-Identifier: Apache-2.0

// Conduck
// WorkDeskBriefView.swift
//
// A conversation task, its project's standing context, and an explicit AI handoff.
// Closing retains the task locally; only context and the preferred gateway save
// to the project. Materials can be left out
// for this send without moving or deleting the source cards. Review prepares
// local copies; the final named Send is the first operation allowed to upload.
// Dismissal saves through the caller's revision-aware organization boundary.

#if !os(watchOS)
import SwiftUI
import Observation

/// Unsaved project work survives Work being hidden or its macOS layer being
/// unmounted. The host creates this once per editing session and retains it;
/// reopening a sheet must not seed over the person's edits from synced rows.
@Observable @MainActor
final class WorkDeskBriefDraft {
    var projectContext: String
    /// The task for this conversation, never the project's standing context.
    var brief: String
    var selectedGateway: RemoteAgentRef?
    var excludedIDs: Set<UUID> = []
    /// A selected-material request is an explicit whitelist. Newly synced
    /// cards stay unchecked until the person includes them in this request.
    private(set) var selectedMaterialIDs: Set<UUID>?
    private var selectedCompanionIDs: [UUID: UUID] = [:]
    private(set) var additionalMaterialIDs: Set<UUID> = []
    var remoteResultIDs: Set<UUID> = []
    var projectResultIDs: Set<UUID> = []
    let handoff: WorkDeskHandoff
    var isSaving = false
    var saveError: String?
    private var savedProjectContext: String
    private var savedGateway: RemoteAgentRef?
    private var activePresentationID: UUID?

    init(brief: String, preferredGatewayRef: String?, task: String = "", conversationResolver: WorkDeskConversationResolver = .init(), handoff: WorkDeskHandoff? = nil) {
        let gateway = preferredGatewayRef.flatMap { RemoteAgentRef(rawString: $0) }
        self.projectContext = brief
        self.brief = task
        self.selectedGateway = gateway
        self.savedProjectContext = brief
        self.savedGateway = gateway
        self.handoff = handoff ?? WorkDeskHandoff(conversationResolver: conversationResolver)
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
        guard selectedGateway == nil, !isSaving, !handoff.isPreparing,
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
        guard !ids.isEmpty, !isSaving, !handoff.isPreparing, !handoff.isSending else { return false }
        handoff.beginAnotherHandoff()
        handoff.discardPreparation()
        selectedMaterialIDs = ids
        additionalMaterialIDs.formIntersection(ids)
        selectedCompanionIDs = Dictionary(uniqueKeysWithValues: materials.compactMap { material in
            guard ids.contains(material.id), let companion = material.companion else { return nil }
            return (material.id, companion.id)
        })
        excludedIDs.subtract(ids)
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
        guard let selectedMaterialIDs, !isSaving, !handoff.isPreparing, !handoff.isSending else { return }
        self.selectedMaterialIDs = selectedMaterialIDs.intersection(materials.map(\.id))
        selectedCompanionIDs = selectedCompanionIDs.filter { parentID, companionID in
            materials.contains { $0.id == parentID && $0.companion?.id == companionID }
        }
        handoff.discardPreparation()
    }

    func setMaterialIncluded(_ included: Bool, id: UUID, includingCompanionID: UUID? = nil) {
        guard !isSaving, !handoff.isPreparing, !handoff.isSending else { return }
        handoff.discardPreparation()
        if selectedMaterialIDs != nil {
            if included { selectedMaterialIDs?.insert(id) } else { selectedMaterialIDs?.remove(id) }
            selectedCompanionIDs[id] = included ? includingCompanionID : nil
        }
        if included { excludedIDs.remove(id) } else { excludedIDs.insert(id) }
    }

    func discardUnsavedChanges() {
        projectContext = savedProjectContext
        brief = ""
        selectedGateway = savedGateway
        excludedIDs = projectResultIDs
        selectedMaterialIDs = nil
        selectedCompanionIDs = [:]
        additionalMaterialIDs = []
        saveError = nil
        handoff.discardPreparation()
    }

    /// A new conversation starts with a new task while retaining project context.
    func startAnotherConversation() {
        guard !handoff.isSending, !handoff.isPreparing else { return }
        handoff.beginAnotherHandoff()
        brief = ""
        excludedIDs = projectResultIDs
        selectedMaterialIDs = nil
        selectedCompanionIDs = [:]
        additionalMaterialIDs = []
        saveError = nil
    }
}

struct WorkDeskBriefView: View {
    let projectID: UUID
    let title: String
    let materials: [WorkboardMaterialSnapshot]
    let availableMaterials: [WorkboardMaterialSnapshot]
    let materialProjectNames: [UUID: String]
    let onSave: @MainActor (String, String?) async -> Bool
    let onOpenConversation: @MainActor (UUID) -> Void
    let onEndEditing: @MainActor () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Bindable private var draft: WorkDeskBriefDraft
    @State private var presentationID: UUID?
    @State private var showingDiscardConfirmation = false
    @State private var showsMaterials = false
    @State private var showsMaterialPicker = false

    init(
        projectID: UUID,
        title: String,
        initialBrief: String,
        preferredGatewayRef: String?,
        materials: [WorkboardMaterialSnapshot],
        availableMaterials: [WorkboardMaterialSnapshot] = [],
        materialProjectNames: [UUID: String] = [:],
        draft: WorkDeskBriefDraft? = nil,
        onSave: @escaping @MainActor (String, String?) async -> Bool,
        onOpenConversation: @escaping @MainActor (UUID) -> Void,
        onEndEditing: @escaping @MainActor () -> Void = {}
    ) {
        self.projectID = projectID
        self.title = title
        self.materials = materials
        self.availableMaterials = availableMaterials
        self.materialProjectNames = materialProjectNames
        self.onSave = onSave
        self.onOpenConversation = onOpenConversation
        self.onEndEditing = onEndEditing
        self.draft = draft ?? WorkDeskBriefDraft(brief: initialBrief, preferredGatewayRef: preferredGatewayRef)
    }

    private var handoff: WorkDeskHandoff { draft.handoff }

    private var requestMaterials: [WorkboardMaterialSnapshot] {
        let projectIDs = Set(materials.map(\.id))
        return materials + availableMaterials.filter { !projectIDs.contains($0.id) && draft.additionalMaterialIDs.contains($0.id) }
    }
    private var included: [WorkboardMaterialSnapshot] {
        draft.includedCards(from: requestMaterials)
    }
    private var expanded: [WorkboardMaterialSnapshot] { WorkDeskHandoffPolicy.expanded(included) }
    private var gateway: WorkDeskGatewayOption? { handoff.gateways.first { $0.ref == draft.selectedGateway } }
    private var busy: Bool { draft.isSaving || handoff.isPreparing || handoff.isSending }
    private var blocked: Bool {
        draft.hasMissingSelectedMaterials(in: requestMaterials)
            || expanded.contains { draft.remoteResultIDs.contains($0.id) || WorkDeskHandoffPolicy.blockingReason($0, gateway: gateway) != nil }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if handoff.acceptedConversationID != nil {
                        acceptedHandoff
                    } else if let packet = handoff.prepared {
                        review(packet)
                    } else {
                        Text(title).font(.title2.weight(.semibold)).foregroundStyle(AppColors.textPrimary)
                        instructionEditor
                        gatewayNotice
                        projectContextPreview
                        materialChecklist
                    }
                    if let error = draft.saveError ?? handoff.errorMessage {
                        Label(error, systemImage: "exclamationmark.circle")
                            .font(.callout)
                            .foregroundStyle(AppColors.textSecondary)
                            .accessibilityIdentifier("workdesk-handoff-error")
                    }
                }
                .padding(24)
                .frame(maxWidth: 740, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .disabled(busy)
            .scrollDismissesKeyboard(.interactively)
            .background(AppColors.background)
            .toolbarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom, spacing: 0) { footer }
            .toolbar {
                ToolbarItem(placement: .principal) {
                    WorkDeskGatewayHeader(draft: draft)
                }
                .sharedBackgroundVisibility(.hidden)
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        Task {
                            let token = presentationID
                            guard await save(), draft.isCurrentPresentation(token) else { return }
                            handoff.discardPreparation()
                            onEndEditing()
                            dismiss()
                        }
                    } label: {
                        Text(LocalizedStringResource("common.close", defaultValue: "Close"))
                    }
                    .disabled(busy)
                }
                if draft.saveError != nil {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(role: .destructive) { showingDiscardConfirmation = true } label: {
                            Text(LocalizedStringResource("workdesk.brief.discard", defaultValue: "Discard changes"))
                        }
                        .disabled(busy)
                    }
                }
            }
        }
        .sheet(isPresented: $showsMaterialPicker) {
            WorkDeskMaterialPicker(
                materials: availableMaterials.filter { candidate in !requestMaterials.contains { $0.id == candidate.id } },
                projectNames: materialProjectNames
            ) { added in
                let success = draft.addMaterials(added, to: requestMaterials)
                if success { showsMaterials = true }
                return success
            }
        }
        .alert(Text(LocalizedStringResource("workdesk.brief.discardTitle", defaultValue: "Discard unsaved changes?")), isPresented: $showingDiscardConfirmation) {
            Button(role: .cancel) {} label: {
                Text(LocalizedStringResource("workdesk.brief.keepEditing", defaultValue: "Keep editing"))
            }
            Button(role: .destructive) {
                draft.discardUnsavedChanges()
                onEndEditing()
                dismiss()
            } label: {
                Text(LocalizedStringResource("workdesk.brief.discard", defaultValue: "Discard changes"))
            }
        } message: {
            Text(LocalizedStringResource("workdesk.brief.discardMessage", defaultValue: "The changes in this window will be lost. Your saved project and materials will stay in Work."))
        }
        .interactiveDismissDisabled()
        .task(id: presentationID) {
            guard presentationID != nil else { return }
            await refreshGateways()
        }
        .onReceive(NotificationCenter.default.publisher(for: .settingsDidChangeRemotely)) { _ in
            Task { await refreshGateways() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await refreshGateways() } }
        }
        .onChange(of: draft.selectedGateway) { _, _ in
            observeGatewayPresence()
        }
        .onAppear {
            presentationID = draft.beginPresentation()
            observeGatewayPresence()
        }
        .onDisappear {
            if let presentationID { draft.endPresentation(presentationID) }
        }
        #if os(macOS)
        .frame(minWidth: 580, idealWidth: 700, minHeight: 520, idealHeight: 640)
        #endif
    }

    private func refreshGateways() async {
        let token = presentationID
        await handoff.loadGateways()
        guard !Task.isCancelled, draft.isCurrentPresentation(token) else { return }
        draft.prefillGateway(availableRefs: handoff.gateways.map(\.ref), defaultRef: handoff.defaultGatewayRef)
        observeGatewayPresence()
    }

    private func observeGatewayPresence() {
        guard scenePhase == .active, draft.isCurrentPresentation(presentationID), let gateway else { return }
        GatewayPresenceMonitor.shared.observe(gateway.ref)
    }

    private var instructionEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(LocalizedStringResource("workdesk.conversation.task", defaultValue: "What would you like to do?"))
                .font(.headline)
            TextField(
                text: $draft.brief,
                axis: .vertical,
                label: {
                    Text(LocalizedStringResource("workdesk.conversation.task.placeholder", defaultValue: "Describe the task and the result you want from this conversation…"))
                }
            )
            .lineLimit(3...10)
            .padding(16)
            .background(AppColors.cardBackgroundElevated, in: RoundedRectangle(cornerRadius: 16))
            .accessibilityIdentifier("workdesk-brief-instructions")
        }
    }

    private var projectContextPreview: some View {
        VStack(alignment: .leading, spacing: 8) {
            if draft.projectContext.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(LocalizedStringResource("workdesk.conversation.context.empty", defaultValue: "No project context. You can add it from the project header."))
                    .font(.caption).foregroundStyle(AppColors.textSecondary)
            } else {
                DisclosureGroup {
                    Text(verbatim: draft.projectContext)
                        .font(.callout).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 6)
                } label: {
                    Text(LocalizedStringResource("workdesk.conversation.context.included", defaultValue: "Project context included"))
                        .font(.subheadline.weight(.medium))
                }
                .accessibilityIdentifier("workdesk-conversation-context")
            }
        }
    }

    private var materialChecklist: some View {
        VStack(alignment: .leading, spacing: 12) {
            if requestMaterials.isEmpty {
                Text(LocalizedStringResource("workdesk.conversation.materials.empty", defaultValue: "No materials yet. You can start with a task alone."))
                    .font(.callout).foregroundStyle(AppColors.textSecondary)
            } else {
                DisclosureGroup(isExpanded: $showsMaterials) {
                    VStack(spacing: 8) {
                        ForEach(requestMaterials) { material in materialRow(material) }
                    }
                    .padding(.top, 8)
                } label: {
                    HStack {
                        Text(LocalizedStringResource("workdesk.conversation.materials.included", defaultValue: "Materials included"))
                            .font(.headline)
                        Spacer()
                        Text(included.count.formatted())
                            .font(.caption.monospacedDigit()).foregroundStyle(AppColors.textSecondary)
                    }
                }
                .accessibilityIdentifier("workdesk-conversation-materials")
                // Capability failures remain visible even with the checklist closed.
                ForEach(expanded) { material in
                    if let reason = materialBlockingReason(material) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(verbatim: material.name).font(.caption.weight(.semibold))
                            Text(verbatim: reason).font(.caption)
                        }
                        .foregroundStyle(AppColors.textSecondary)
                        .accessibilityElement(children: .combine)
                    }
                }
            }
            if availableMaterials.contains(where: { candidate in !requestMaterials.contains { $0.id == candidate.id } }) {
                Button(LocalizedStringResource("workdesk.conversation.addMaterials", defaultValue: "Add materials…"), systemImage: "plus") {
                    showsMaterialPicker = true
                }.inlineLinkButton().disabled(draft.hasMissingSelectedMaterials(in: requestMaterials))
            }
            if draft.hasMissingSelectedMaterials(in: requestMaterials) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(LocalizedStringResource("workdesk.conversation.missingSelection", defaultValue: "Some selected materials were removed or moved. Leave them out to continue."))
                        .font(.callout).foregroundStyle(AppColors.textSecondary)
                    Button(LocalizedStringResource("workdesk.conversation.leaveOutMissing", defaultValue: "Leave out missing materials")) {
                        draft.leaveOutMissingMaterials(in: requestMaterials)
                    }.inlineLinkButton()
                }
            }
            if !draft.excludedIDs.isEmpty || draft.selectedMaterialIDs != nil {
                Text(LocalizedStringResource("workdesk.brief.excluded", defaultValue: "Unchecked materials will not be sent. Their project locations stay the same."))
                    .font(.caption).foregroundStyle(AppColors.textSecondary)
            }
        }
    }

    private func materialRow(_ material: WorkboardMaterialSnapshot) -> some View {
        let selected = draft.isMaterialIncluded(material.id)
        let includedCard = draft.includedCards(from: [material]).first
        return Button {
            draft.setMaterialIncluded(!selected, id: material.id, includingCompanionID: material.companion?.id)
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? AppColors.brandAmber : AppColors.textTertiary)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 5) {
                    Text(material.name).font(.callout.weight(.medium)).foregroundStyle(AppColors.textPrimary).lineLimit(2)
                    if !materials.contains(where: { $0.id == material.id }) {
                        Label {
                            Text(verbatim: materialProjectNames[material.id] ?? String(localized: "workdesk.material.unfiled", defaultValue: "No project"))
                        } icon: { Image(systemName: "folder") }
                            .font(.caption).foregroundStyle(AppColors.textSecondary)
                    }
                    if let companion = material.companion, !selected || includedCard?.companion?.id == companion.id {
                        Text(companion.material.textContent ?? companion.name)
                            .font(.caption).foregroundStyle(AppColors.textSecondary).lineLimit(2)
                    }
                    if selected, material.companion != nil, includedCard?.companion == nil {
                        Text(LocalizedStringResource("workdesk.conversation.newCompanionExcluded", defaultValue: "New attached material left out. Uncheck and select this card again to include it."))
                            .font(.caption).foregroundStyle(AppColors.textSecondary)
                    }
                    ForEach(WorkDeskHandoffPolicy.expanded([includedCard ?? material])) { part in
                        if let notes = part.annotation, !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(LocalizedStringResource("workdesk.material.notes.title", defaultValue: "Your notes"))
                                    .font(.caption.weight(.semibold))
                                Text(verbatim: notes).font(.caption).lineLimit(3)
                            }
                            .foregroundStyle(AppColors.textSecondary)
                        }
                    }
                    if material.isRemoteProjectResult || draft.remoteResultIDs.contains(material.id) {
                        Text(verbatim: WorkDeskHandoffError.remoteResult.localizedDescription)
                            .font(.caption).foregroundStyle(AppColors.textSecondary)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: material.kind == .image ? "photo" : material.kind == .link ? "link" : "doc.text")
                    .foregroundStyle(AppColors.textTertiary)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppColors.cardBackgroundElevated, in: RoundedRectangle(cornerRadius: 12))
        }
        .choiceCardButton(cornerRadius: 12)
        .accessibilityValue(Text(selected ? LocalizedStringResource("workdesk.brief.included", defaultValue: "Included") : LocalizedStringResource("workdesk.brief.leftOut", defaultValue: "Left out")))
    }

    private func materialBlockingReason(_ material: WorkboardMaterialSnapshot) -> String? {
        if draft.remoteResultIDs.contains(material.id) { return WorkDeskHandoffError.remoteResult.localizedDescription }
        return WorkDeskHandoffPolicy.blockingReason(material, gateway: gateway)
    }

    @ViewBuilder
    private var gatewayNotice: some View {
        if handoff.hasLoadedGateways, handoff.gateways.isEmpty {
            Text(LocalizedStringResource("workdesk.conversation.gateway.none", defaultValue: "No gateway is available on this device. Your task will stay here when you close. Connect a gateway in Settings → Personal AI."))
                .font(.callout).foregroundStyle(AppColors.textSecondary)
        } else if handoff.hasLoadedGateways, draft.selectedGateway != nil, gateway == nil {
            Text(LocalizedStringResource("workdesk.brief.savedUnavailable", defaultValue: "This gateway is unavailable on this device. Choose another to continue."))
                .font(.callout).foregroundStyle(AppColors.textSecondary)
        }
    }

    private func review(_ packet: WorkDeskPreparedHandoff) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            Label {
                Text(LocalizedStringResource("workdesk.brief.ready", defaultValue: "Ready for your AI"))
            } icon: { Image(systemName: "paperplane") }
            .font(.title2.weight(.bold)).foregroundStyle(AppColors.brandAmber)
            Text(packet.gatewayName).font(.title.weight(.bold))
            Text(LocalizedStringResource("workdesk.brief.reviewIntro", defaultValue: "Read the prompt below. Sending starts a new chat with this connection and includes only the materials you selected."))
                .font(.callout).foregroundStyle(AppColors.textSecondary)
            Text(packet.prompt)
                .font(.body).textSelection(.enabled)
                .padding(18).frame(maxWidth: .infinity, alignment: .leading)
                .background(AppColors.cardBackgroundElevated, in: RoundedRectangle(cornerRadius: 16))
                .accessibilityIdentifier("workdesk-handoff-prompt")
            if !packet.attachmentNames.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text(LocalizedStringResource("workdesk.brief.attachedFiles", defaultValue: "Attached files"))
                        .font(.headline)
                    ForEach(Array(packet.attachmentNames.enumerated()), id: \.offset) { _, name in
                        Label(name, systemImage: "paperclip").font(.callout)
                    }
                    Text(LocalizedStringResource("workdesk.brief.visionNote", defaultValue: "Image understanding depends on the model configured for this connection."))
                        .font(.caption).foregroundStyle(AppColors.textSecondary)
                }
            }
            ForEach(Array(packet.textAttachments.enumerated()), id: \.offset) { _, attachment in
                DisclosureGroup(attachment.name) {
                    Text(attachment.text).font(.callout).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if !draft.excludedIDs.isEmpty {
                Text(LocalizedStringResource("workdesk.brief.excluded", defaultValue: "Unchecked materials will not be sent. Their project locations stay the same."))
                    .font(.caption).foregroundStyle(AppColors.textSecondary)
            }
        }
    }

    private var acceptedHandoff: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label {
                Text(LocalizedStringResource("workdesk.conversation.accepted", defaultValue: "Conversation started"))
            } icon: { Image(systemName: "checkmark.circle") }
            .font(.title2.weight(.bold)).foregroundStyle(AppColors.brandAmber)
            Text(title).font(.title.weight(.bold))
            Text(LocalizedStringResource("workdesk.brief.acceptedMessage", defaultValue: "Open the conversation to follow its progress or continue working with your AI. Your project and materials are still here."))
                .font(.callout).foregroundStyle(AppColors.textSecondary)
        }
    }

    private var footer: some View {
        HStack(spacing: 16) {
            if let acceptedID = handoff.acceptedConversationID {
                Button {
                    guard !busy else { return }
                    draft.startAnotherConversation()
                } label: {
                    Text(LocalizedStringResource("workdesk.conversation.another", defaultValue: "New conversation"))
                        .padding(.vertical, 12)
                }
                .inlineLinkButton()
                .disabled(busy)
                .accessibilityIdentifier("workdesk-handoff-prepare-another")
                Spacer(minLength: 0)
                Button {
                    guard !busy else { return }
                    dismiss()
                    onOpenConversation(acceptedID)
                } label: {
                    Label {
                        Text(LocalizedStringResource("workdesk.brief.openChat", defaultValue: "Open chat"))
                    } icon: { Image(systemName: "arrow.up.right") }
                    .font(.headline).padding(.horizontal, 20).padding(.vertical, 13)
                    .foregroundStyle(.black)
                    .background(AppColors.brandAmber, in: Capsule())
                }
                .primaryCTAButton()
                .disabled(busy)
                .accessibilityIdentifier("workdesk-handoff-open-chat")
            } else if let packet = handoff.prepared {
                Button {
                    handoff.discardPreparation()
                } label: {
                    Text(LocalizedStringResource("workdesk.conversation.edit", defaultValue: "Edit request"))
                        .padding(.vertical, 12)
                }
                .inlineLinkButton()
                .disabled(busy)
                Spacer(minLength: 0)
                Button {
                    Task {
                        let token = presentationID
                        guard draft.isCurrentPresentation(token), let id = await handoff.send() else { return }
                        // A deep link may have opened another chat while the
                        // local send was accepting. Keep that navigation; the
                        // retained draft can reopen this accepted chat later.
                        guard draft.isCurrentPresentation(token) else { return }
                        dismiss()
                        onOpenConversation(id)
                    }
                } label: {
                    HStack(spacing: 8) {
                        if handoff.isSending { ProgressView().controlSize(.small) }
                        Text(String(localized: "workdesk.brief.sendTo", defaultValue: "Send to \(packet.gatewayName)"))
                        Image(systemName: "arrow.up.right")
                    }
                    .font(.headline).padding(.horizontal, 18).padding(.vertical, 13)
                    .foregroundStyle(.black)
                    .background(AppColors.brandAmber, in: Capsule())
                }
                .primaryCTAButton()
                .disabled(busy)
                .accessibilityIdentifier("workdesk-handoff-send")
            } else {
                Spacer(minLength: 0)
                Button {
                    Task {
                        let token = presentationID
                        guard await save(), draft.isCurrentPresentation(token), !blocked else { return }
                        await handoff.prepare(title: title, brief: draft.brief, cards: included, ref: draft.selectedGateway,
                            projectID: projectID, projectContext: draft.projectContext, remoteResultIDs: draft.remoteResultIDs)
                    }
                } label: {
                    HStack(spacing: 8) {
                        if busy { ProgressView().controlSize(.small) }
                        Text(LocalizedStringResource("workdesk.conversation.review", defaultValue: "Review"))
                        Image(systemName: "arrow.right")
                    }
                    .font(.headline).padding(.horizontal, 20).padding(.vertical, 13)
                    .foregroundStyle(.black)
                    .background(AppColors.brandAmber, in: Capsule())
                }
                .primaryCTAButton()
                .disabled(busy || gateway == nil || blocked || draft.brief.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("workdesk-handoff-review")
            }
        }
        .padding(.horizontal, 24).padding(.vertical, 16)
        .background(.regularMaterial)
    }

    private func save() async -> Bool {
        guard !draft.isSaving else { return false }
        draft.isSaving = true
        draft.saveError = nil
        defer { draft.isSaving = false }
        let savedContext = draft.projectContext
        let savedGateway = draft.selectedGateway
        let success = await onSave(savedContext, savedGateway?.rawString)
        if success {
            draft.markSaved(projectContext: savedContext, selectedGateway: savedGateway)
        } else {
            draft.saveError = String(localized: "workdesk.conversation.saveFailed", defaultValue: "Your project settings could not be saved. Your task is still here. Keep this window open and try again.")
        }
        return success
    }
}

/// Reads the retained draft from its own body so toolbar observations update
/// when a gateway arrives or changes. A review always names its frozen route;
/// returning to Edit request is required before choosing another destination.
private struct WorkDeskGatewayHeader: View {
    @Bindable var draft: WorkDeskBriefDraft

    var body: some View {
        let handoff = draft.handoff
        let packet = handoff.prepared
        GatewayPicker(
            options: handoff.gateways.map { .init(ref: $0.ref, name: $0.name) },
            selectedRef: packet?.connection.option.ref ?? draft.selectedGateway,
            selectedName: packet?.gatewayName,
            allowsSelection: !draft.isSaving && !handoff.isPreparing && !handoff.isSending
                && packet == nil && handoff.acceptedConversationID == nil,
            optionAccessibilityPrefix: "workdesk-gateway-"
        ) { ref in
            guard !draft.isSaving, !handoff.isPreparing, !handoff.isSending,
                  handoff.prepared == nil, handoff.acceptedConversationID == nil,
                  handoff.gateways.contains(where: { $0.ref == ref }) else { return }
            draft.selectedGateway = ref
        }
        .accessibilityIdentifier("workdesk-gateway-picker")
    }
}
#endif
