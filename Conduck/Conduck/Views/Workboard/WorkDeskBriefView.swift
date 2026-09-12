// SPDX-License-Identifier: Apache-2.0

// Conduck
// WorkDeskBriefView.swift
//
// A conversation task, its project's standing context, and an explicit AI handoff.
// Closing retains the request locally; only context and the preferred gateway
// save to the project. An explicit header keeps the same Chat gateway picker
// visible on every surface. One footer owns both actions, above the keyboard.
// Materials can be left out
// for this send without moving or deleting the source cards. Review prepares
// local copies; the final named Send is the first operation allowed to upload.
// Dismissal saves through the caller's revision-aware organization boundary.

#if !os(watchOS)
import SwiftUI
import Observation

struct WorkDeskBriefView: View {
    let projectID: UUID
    let title: String
    let materials: [WorkboardMaterialSnapshot]
    let availableMaterials: [WorkboardMaterialSnapshot]
    let materialProjectNames: [UUID: String]
    let onSave: @MainActor (String, String?) async -> Bool
    let onOpenConversation: @MainActor (UUID) -> Void
    let onEndEditing: @MainActor () -> Void
    private let recoveryLookup: WorkDeskInterruptedHandoffLookup

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Bindable private var draft: WorkDeskBriefDraft
    @State private var presentationID: UUID?
    @State private var showingDiscardConfirmation = false
    @FocusState private var taskIsFocused: Bool
    @State private var contentHeight: CGFloat = 260
    @State private var headerHeight: CGFloat = 100
    @State private var footerHeight: CGFloat = 80
    @State private var showsMaterialPicker = false
    @State private var conflictConfirmation: ConflictConfirmation?
    @State private var showsConflictConfirmation = false
    @State private var interruptedConfirmationID: UUID?
    @State private var showsInterruptedConfirmation = false
    @State private var recoveryStatus: RecoveryStatus = .checking
    @State private var recoveryLookupID: UUID?

    private struct ConflictConfirmation {
        let conflict: WorkDeskBriefDraftStore.Conflict
        let replace: Bool
    }

    private enum RecoveryStatus: Equatable {
        case checking, recordedConversation(UUID), unresolved, failed
    }

    private struct RecoveryRequest: Hashable {
        let presentationID: UUID?
        let conversationID: UUID?
    }

    @MainActor init(
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
        onEndEditing: @escaping @MainActor () -> Void = {},
        recoveryLookup: WorkDeskInterruptedHandoffLookup? = nil
    ) {
        self.projectID = projectID
        self.title = title
        self.materials = materials
        self.availableMaterials = availableMaterials
        self.materialProjectNames = materialProjectNames
        self.onSave = onSave
        self.onOpenConversation = onOpenConversation
        self.onEndEditing = onEndEditing
        self.recoveryLookup = recoveryLookup ?? .live
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
    private var requestNeedsRecovery: Bool { draft.interruptedHandoffID != nil || draft.persistenceConflict != nil }
    private var blocked: Bool {
        draft.hasMissingSelectedMaterials(in: requestMaterials)
            || expanded.contains { draft.remoteResultIDs.contains($0.id) || WorkDeskHandoffPolicy.blockingReason($0, gateway: gateway) != nil }
    }

    private var showsMaterials: Binding<Bool> {
        Binding(
            get: { WorkDeskComposerPolicy.materialsExpanded(total: requestMaterials.count, preference: draft.materialsExpanded) },
            set: { draft.materialsExpanded = $0 }
        )
    }

    private var idealSheetHeight: CGFloat {
        WorkDeskComposerPolicy.sheetHeight(content: contentHeight, header: headerHeight, footer: footerHeight)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { headerHeight = $0 }
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if dynamicTypeSize.isAccessibilitySize { headerTitle }
                    if handoff.acceptedConversationID != nil {
                        acceptedHandoff
                    } else if draft.interruptedHandoffID != nil {
                        interruptedHandoffRecovery
                    } else if let packet = handoff.prepared {
                        review(packet)
                    } else {
                        instructionEditor.disabled(draft.isPersistenceUnavailable)
                        gatewayNotice
                        projectContextPreview
                        materialChecklist.disabled(draft.isPersistenceUnavailable)
                    }
                    saveAndHandoffErrors
                }
                .padding(.horizontal, 24)
                .padding(.top, 8)
                .padding(.bottom, 24)
                .frame(maxWidth: 740, alignment: .leading)
                .frame(maxWidth: .infinity)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
            }
            .disabled(busy)
            .scrollDismissesKeyboard(.interactively)
            .scrollBounceBehavior(.basedOnSize)
            footer
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { footerHeight = $0 }
        }
        .background(AppColors.background)
        .sheet(isPresented: $showsMaterialPicker) {
            WorkDeskMaterialPicker(
                materials: availableMaterials.filter { candidate in !requestMaterials.contains { $0.id == candidate.id } },
                projectNames: materialProjectNames
            ) { added in
                let success = draft.addMaterials(added, to: requestMaterials)
                if success { draft.materialsExpanded = true }
                return success
            }
        }
        .alert(Text(LocalizedStringResource("workdesk.brief.discardTitle", defaultValue: "Discard unsaved changes?")), isPresented: $showingDiscardConfirmation) {
            Button(role: .cancel) {} label: {
                Text(LocalizedStringResource("workdesk.brief.keepEditing", defaultValue: "Keep editing"))
            }
            Button(role: .destructive) {
                guard draft.discardUnsavedChanges() else { return }
                onEndEditing()
                dismiss()
            } label: {
                Text(LocalizedStringResource("workdesk.brief.discard", defaultValue: "Discard changes"))
            }
        } message: {
            Text(LocalizedStringResource("workdesk.brief.discardMessage", defaultValue: "The changes in this window will be lost. Your saved project and materials will stay in Work."))
        }
        .alert(
            conflictConfirmation?.replace == true
                ? Text(LocalizedStringResource("workdesk.draft.replaceTitle", defaultValue: "Use this request instead?"))
                : Text(LocalizedStringResource("workdesk.draft.reloadTitle", defaultValue: "Load the saved request?")),
            isPresented: $showsConflictConfirmation,
            presenting: conflictConfirmation
        ) { confirmation in
            Button(role: .cancel) {} label: {
                Text(LocalizedStringResource("workdesk.brief.keepEditing", defaultValue: "Keep editing"))
            }
            Button(role: .destructive) {
                guard draft.isCurrentPresentation(presentationID), !busy else { return }
                if confirmation.replace {
                    draft.replacePersistedRequest(resolving: confirmation.conflict)
                } else {
                    draft.reloadPersistedRequest(resolving: confirmation.conflict)
                }
            } label: {
                Text(confirmation.replace
                     ? LocalizedStringResource("workdesk.draft.useThis", defaultValue: "Use this request")
                     : LocalizedStringResource("workdesk.draft.loadSaved", defaultValue: "Load saved request"))
            }
        } message: { confirmation in
            Text(confirmation.replace
                 ? LocalizedStringResource("workdesk.draft.replaceMessage", defaultValue: "This replaces the saved request shown in the composer with the task and material choices in this window.")
                 : LocalizedStringResource("workdesk.draft.reloadMessage", defaultValue: "This discards the task and material changes in this window and loads the saved request shown in the composer."))
        }
        .alert(
            Text(LocalizedStringResource("workdesk.draft.anotherAfterInterruptionTitle", defaultValue: "Prepare another conversation?")),
            isPresented: $showsInterruptedConfirmation,
            presenting: interruptedConfirmationID
        ) { conversationID in
            Button(role: .cancel) {} label: {
                Text(LocalizedStringResource("common.cancel", defaultValue: "Cancel"))
            }
            Button {
                guard draft.isCurrentPresentation(presentationID),
                      draft.interruptedHandoffID == conversationID, !busy else { return }
                draft.reviewAfterInterruptedHandoff()
            } label: {
                Text(LocalizedStringResource("workdesk.draft.useTaskAgain", defaultValue: "Use this task for another conversation"))
            }
        } message: { _ in
            Text(LocalizedStringResource("workdesk.draft.anotherAfterInterruptionMessage", defaultValue: "The previous send may already have reached your gateway. This keeps your task for a separate conversation. You will still review it and choose Send."))
        }
        .interactiveDismissDisabled()
        .task(id: presentationID) {
            guard presentationID != nil else { return }
            await refreshGateways()
        }
        .task(id: RecoveryRequest(presentationID: presentationID, conversationID: draft.interruptedHandoffID)) {
            await refreshInterruptedHandoff()
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
        .frame(minWidth: 560, idealWidth: 640, maxWidth: 740,
               minHeight: 320, idealHeight: idealSheetHeight, maxHeight: WorkDeskComposerPolicy.maximumSheetHeight)
        #else
        .frame(idealHeight: idealSheetHeight)
        #endif
    }

    private var header: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                // Keep the destination reachable while the title scrolls away
                // at large text sizes, leaving room for the task and keyboard.
                WorkDeskGatewayHeader(draft: draft)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                adaptiveHeader
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, dynamicTypeSize.isAccessibilitySize ? 12 : 24)
        .accessibilityIdentifier("workdesk-conversation-header")
    }

    private var adaptiveHeader: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 24) {
                headerTitle.fixedSize(horizontal: true, vertical: false)
                Spacer(minLength: 0)
                WorkDeskGatewayHeader(draft: draft).fixedSize(horizontal: true, vertical: false)
            }
            VStack(alignment: .leading, spacing: 14) {
                headerTitle
                WorkDeskGatewayHeader(draft: draft)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var headerTitle: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(headerHeading)
                .font(.title2.weight(.semibold))
                .foregroundStyle(AppColors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Text(verbatim: title)
                .font(.subheadline)
                .foregroundStyle(AppColors.textSecondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var headerHeading: LocalizedStringResource {
        if handoff.acceptedConversationID != nil {
            return LocalizedStringResource("workdesk.conversation.accepted", defaultValue: "Conversation started")
        }
        return handoff.prepared == nil
            ? LocalizedStringResource("workdesk.conversation.title", defaultValue: "New conversation")
            : LocalizedStringResource("workdesk.conversation.reviewTitle", defaultValue: "Review conversation")
    }

    @ViewBuilder
    private var saveAndHandoffErrors: some View {
        if let error = draft.saveError ?? handoff.errorMessage {
            Label(error, systemImage: "exclamationmark.circle")
                .font(.callout)
                .foregroundStyle(AppColors.textSecondary)
                .accessibilityIdentifier("workdesk-handoff-error")
        }
        if let conflict = draft.persistenceConflict {
            conflictRecovery(conflict)
        } else if let error = draft.persistenceError {
            VStack(alignment: .leading, spacing: 8) {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.callout).foregroundStyle(AppColors.textSecondary)
                if !draft.persistedRequestWasRemoved, draft.interruptedHandoffID == nil {
                    Button(LocalizedStringResource("workdesk.conversation.retrySaving", defaultValue: "Retry saving draft")) {
                        draft.persistChanges()
                    }
                    .inlineLinkButton()
                }
            }
            .accessibilityIdentifier("workdesk-draft-save-error")
        }
        if !draft.persistedRequestWasRemoved, !requestNeedsRecovery,
           draft.saveError != nil || draft.persistenceError != nil {
            Button(role: .destructive) { showingDiscardConfirmation = true } label: {
                Text(LocalizedStringResource("workdesk.brief.discard", defaultValue: "Discard changes"))
            }
            .inlineLinkButton()
        }
    }

    private func conflictRecovery(_ conflict: WorkDeskBriefDraftStore.Conflict) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label {
                Text(LocalizedStringResource("workdesk.draft.conflict", defaultValue: "This project’s draft changed in another window. Your request is still here. Choose which draft to keep."))
            } icon: { Image(systemName: "exclamationmark.circle") }
            .font(.callout)
            if let saved = conflict.current {
                VStack(alignment: .leading, spacing: 8) {
                    Text(LocalizedStringResource("workdesk.draft.savedRequest", defaultValue: "Saved request"))
                        .font(.subheadline.weight(.semibold))
                    if saved.task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text(LocalizedStringResource("workdesk.draft.savedTaskEmpty", defaultValue: "No task entered."))
                            .font(.callout)
                    } else {
                        Text(verbatim: saved.task).font(.callout).textSelection(.enabled)
                    }
                    Label {
                        Text(verbatim: savedGatewayName(saved.gatewayRef))
                    } icon: { Image(systemName: "network") }
                    .font(.caption)
                    savedMaterialsPreview(saved)
                    if saved.pendingConversationID != nil {
                        Text(LocalizedStringResource("workdesk.draft.savedSendPending", defaultValue: "A send was started for this request. Load it to check the conversation before preparing another."))
                            .font(.caption)
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(AppColors.cardBackgroundElevated, in: RoundedRectangle(cornerRadius: 12))
            } else {
                Text(LocalizedStringResource("workdesk.draft.savedRequestRetired", defaultValue: "The saved request was completed or removed in another window."))
                    .font(.callout)
            }
            if conflict.canReplace {
                Button(LocalizedStringResource("workdesk.draft.useThis", defaultValue: "Use this request")) {
                    conflictConfirmation = .init(conflict: conflict, replace: true)
                    showsConflictConfirmation = true
                }
                .inlineLinkButton()
                .accessibilityIdentifier("workdesk-draft-use-this")
            }
            Button(LocalizedStringResource("workdesk.draft.loadSaved", defaultValue: "Load saved request")) {
                conflictConfirmation = .init(conflict: conflict, replace: false)
                showsConflictConfirmation = true
            }
            .inlineLinkButton()
            .accessibilityIdentifier("workdesk-draft-load-saved")
        }
        .foregroundStyle(AppColors.textSecondary)
        .accessibilityIdentifier("workdesk-draft-conflict")
    }

    private func savedMaterialsPreview(_ saved: WorkDeskBriefDraftRecord) -> some View {
        let lookup = (materials + availableMaterials).reduce(into: [UUID: WorkboardMaterialSnapshot]()) {
            $0[$1.id] = $1
        }
        let projectIDs = Set(materials.map(\.id)).union(saved.additionalMaterialIDs)
        let includedIDs = saved.selectedMaterialIDs ?? projectIDs.subtracting(saved.excludedIDs)
        let known = includedIDs.compactMap { lookup[$0] }.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        let missingCompanions = saved.selectedCompanionIDs.filter { parentID, companionID in
            includedIDs.contains(parentID) && lookup[parentID]?.companion?.id != companionID
        }.count
        let unavailableCount = includedIDs.count - known.count + missingCompanions
            + known.filter { WorkDeskHandoffPolicy.needsBytes($0) && !$0.availability.isAvailable }.count
        return DisclosureGroup {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(known) { material in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(verbatim: material.name)
                        if let companion = material.companion,
                           saved.selectedMaterialIDs == nil || saved.selectedCompanionIDs[material.id] == companion.id {
                            Text(verbatim: companion.name)
                                .foregroundStyle(AppColors.textSecondary)
                        }
                    }
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
                }
                if unavailableCount > 0 {
                    Text(LocalizedStringResource("workdesk.draft.savedMaterialsUnavailable", defaultValue: "\(unavailableCount) selected materials are unavailable here."))
                        .font(.caption)
                }
            }
            .padding(.top, 6)
        } label: {
            Text(LocalizedStringResource("workdesk.draft.savedMaterialsCount", defaultValue: "Materials selected: \(includedIDs.count)"))
                .font(.caption.weight(.medium))
        }
    }

    private func savedGatewayName(_ rawRef: String?) -> String {
        guard let rawRef else {
            return String(localized: "workdesk.draft.noSavedGateway", defaultValue: "No gateway selected")
        }
        return handoff.gateways.first { $0.ref.rawString == rawRef }?.name
            ?? String(localized: "workdesk.draft.unavailableSavedGateway", defaultValue: "Saved gateway unavailable on this device")
    }

    private var interruptedHandoffRecovery: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label {
                Text(LocalizedStringResource("workdesk.draft.interruptedTitle", defaultValue: "Check the previous conversation"))
            } icon: { Image(systemName: "clock.arrow.circlepath") }
            .font(.headline)
            Text(LocalizedStringResource("workdesk.draft.interruptedMessage", defaultValue: "A send started before this draft closed. Check the saved conversation before preparing another."))
                .font(.callout).foregroundStyle(AppColors.textSecondary)
            switch recoveryStatus {
            case .checking:
                ProgressView {
                    Text(LocalizedStringResource("workdesk.draft.checkingConversation", defaultValue: "Checking saved conversations…"))
                }
                .controlSize(.small)
            case .recordedConversation(let conversationID):
                Button {
                    guard draft.isCurrentPresentation(presentationID),
                          draft.interruptedHandoffID == conversationID,
                          draft.clearPersistedRequest() else { return }
                    onEndEditing()
                    dismiss()
                    onOpenConversation(conversationID)
                } label: {
                    Label {
                        Text(LocalizedStringResource("workdesk.draft.openExistingConversation", defaultValue: "Open existing conversation"))
                    } icon: { Image(systemName: "arrow.up.right") }
                }
                .inlineLinkButton()
                .accessibilityIdentifier("workdesk-draft-open-existing")
            case .unresolved:
                Text(LocalizedStringResource("workdesk.draft.conversationUnresolved", defaultValue: "No saved user message was found on this device. This does not confirm whether the gateway received the previous send."))
                    .font(.callout).foregroundStyle(AppColors.textSecondary)
                Button(LocalizedStringResource("workdesk.draft.useTaskAgain", defaultValue: "Use this task for another conversation")) {
                    interruptedConfirmationID = draft.interruptedHandoffID
                    showsInterruptedConfirmation = true
                }
                .inlineLinkButton()
                .accessibilityIdentifier("workdesk-draft-review-another")
                retryConversationLookup
            case .failed:
                Text(LocalizedStringResource("workdesk.draft.conversationLookupFailed", defaultValue: "Saved conversations couldn’t be checked. Try again before preparing another conversation."))
                    .font(.callout).foregroundStyle(AppColors.textSecondary)
                retryConversationLookup
            }
            DisclosureGroup {
                Text(verbatim: draft.brief)
                    .font(.callout).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } label: {
                Text(LocalizedStringResource("workdesk.conversation.reviewTask", defaultValue: "Your task"))
                    .font(.subheadline.weight(.medium))
            }
        }
        .accessibilityIdentifier("workdesk-draft-interrupted-handoff")
    }

    private var retryConversationLookup: some View {
        Button(LocalizedStringResource("workdesk.draft.checkConversationAgain", defaultValue: "Check again")) {
            Task { await refreshInterruptedHandoff() }
        }
        .inlineLinkButton()
    }

    private func refreshInterruptedHandoff() async {
        let token = presentationID
        guard draft.isCurrentPresentation(token), let conversationID = draft.interruptedHandoffID else { return }
        let lookupID = UUID()
        recoveryLookupID = lookupID
        recoveryStatus = .checking
        do {
            let existingID = try await recoveryLookup.existingConversationID(conversationID)
            guard !Task.isCancelled, draft.isCurrentPresentation(token),
                  draft.interruptedHandoffID == conversationID, recoveryLookupID == lookupID else { return }
            recoveryStatus = existingID.map(RecoveryStatus.recordedConversation) ?? .unresolved
        } catch {
            guard !Task.isCancelled, draft.isCurrentPresentation(token),
                  draft.interruptedHandoffID == conversationID, recoveryLookupID == lookupID else { return }
            recoveryStatus = .failed
        }
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
            .textFieldStyle(.plain)
            .font(.body)
            .lineLimit(3...10)
            .focused($taskIsFocused)
            .padding(16)
            .background(AppColors.cardBackgroundElevated, in: RoundedRectangle(cornerRadius: 16))
            .accessibilityIdentifier("workdesk-brief-instructions")
        }
    }

    @ViewBuilder
    private var projectContextPreview: some View {
        if !draft.projectContext.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            contextPreview(draft.projectContext)
        }
    }

    private func contextPreview(_ context: String) -> some View {
        DisclosureGroup {
            Text(verbatim: context)
                .font(.callout).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 6)
        } label: {
            Text(LocalizedStringResource("workdesk.conversation.context.included", defaultValue: "Project context included"))
                .font(.subheadline.weight(.medium))
        }
        .foregroundStyle(AppColors.textSecondary)
        .accessibilityIdentifier("workdesk-conversation-context")
    }

    private var materialChecklist: some View {
        VStack(alignment: .leading, spacing: 12) {
            DisclosureGroup(isExpanded: showsMaterials) {
                VStack(alignment: .leading, spacing: 8) {
                    if requestMaterials.isEmpty {
                        Text(LocalizedStringResource("workdesk.conversation.materials.empty", defaultValue: "No materials yet. You can start with a task alone."))
                            .font(.callout).foregroundStyle(AppColors.textSecondary)
                    }
                    ForEach(requestMaterials) { material in materialRow(material) }
                    materialsFromElsewhere
                    if included.count < requestMaterials.count {
                        Text(LocalizedStringResource("workdesk.brief.excluded", defaultValue: "Unchecked materials will not be sent. Their project locations stay the same."))
                            .font(.caption).foregroundStyle(AppColors.textSecondary)
                            .padding(.top, 4)
                    }
                }
                .padding(.top, 10)
            } label: {
                ViewThatFits(in: .horizontal) {
                    HStack {
                        materialsHeading
                        Spacer(minLength: 8)
                        materialsCount.fixedSize()
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        materialsHeading
                        materialsCount
                    }
                }
            }
            .accessibilityIdentifier("workdesk-conversation-materials")
            // Selection/capability failures remain visible with the list closed.
            ForEach(expanded) { material in
                if let reason = materialBlockingReason(material) {
                    Label {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(verbatim: material.name).font(.caption.weight(.semibold))
                            Text(verbatim: reason).font(.caption)
                        }
                    } icon: { Image(systemName: "exclamationmark.circle") }
                    .foregroundStyle(AppColors.textSecondary)
                    .accessibilityElement(children: .combine)
                }
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
        }
    }

    private var materialsHeading: some View {
        Text(LocalizedStringResource("workdesk.conversation.materials.heading", defaultValue: "Materials"))
            .font(.headline).foregroundStyle(AppColors.textPrimary)
    }

    private var materialsCount: some View {
        Group {
            if included.count == requestMaterials.count {
                Text(LocalizedStringResource("workdesk.conversation.materials.count", defaultValue: "\(included.count) included"))
            } else {
                Text(LocalizedStringResource("workdesk.conversation.materials.partialCount", defaultValue: "\(included.count) of \(requestMaterials.count) included"))
            }
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(AppColors.textSecondary)
    }

    @ViewBuilder
    private var materialsFromElsewhere: some View {
        if availableMaterials.contains(where: { candidate in !requestMaterials.contains { $0.id == candidate.id } }) {
            Button {
                taskIsFocused = false
                showsMaterialPicker = true
            } label: {
                Label {
                    Text(LocalizedStringResource("workdesk.conversation.useElsewhere", defaultValue: "Use materials from elsewhere…"))
                } icon: { Image(systemName: "plus") }
                .font(.callout)
                .padding(.vertical, 10)
            }
            .inlineLinkButton()
            .disabled(draft.hasMissingSelectedMaterials(in: requestMaterials))
            .accessibilityIdentifier("workdesk-conversation-use-elsewhere")
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
                Image(systemName: WorkboardMaterialIcon.symbol(for: material))
                    .foregroundStyle(AppColors.textTertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
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
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 8) {
                Text(LocalizedStringResource("workdesk.conversation.reviewTask", defaultValue: "Your task"))
                    .font(.headline)
                Text(verbatim: packet.task)
                    .font(.body).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !packet.projectContext.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                contextPreview(packet.projectContext)
            }
            if !packet.materials.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        materialsHeading
                        Spacer(minLength: 8)
                        Text(LocalizedStringResource("workdesk.conversation.materials.count", defaultValue: "\(packet.materials.count) included"))
                            .font(.caption.monospacedDigit()).foregroundStyle(AppColors.textSecondary)
                    }
                    ForEach(packet.materials) { material in
                        Label {
                            Text(verbatim: material.name)
                        } icon: {
                            Image(systemName: WorkboardMaterialIcon.symbol(for: material))
                        }
                        .font(.callout).foregroundStyle(AppColors.textSecondary)
                    }
                }
            }
            DisclosureGroup {
                Text(verbatim: packet.prompt)
                    .font(.callout).textSelection(.enabled)
                    .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                    .background(AppColors.cardBackgroundElevated, in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityIdentifier("workdesk-handoff-prompt")
                    .padding(.top, 8)
                ForEach(Array(packet.textAttachments.enumerated()), id: \.offset) { _, attachment in
                    DisclosureGroup(attachment.name) {
                        Text(verbatim: attachment.text)
                            .font(.callout).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                if !packet.attachmentNames.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(LocalizedStringResource("workdesk.brief.attachedFiles", defaultValue: "Attached files"))
                            .font(.subheadline.weight(.medium))
                        ForEach(Array(packet.attachmentNames.enumerated()), id: \.offset) { _, name in
                            Label(name, systemImage: "paperclip").font(.callout)
                        }
                    }
                    .padding(.top, 8)
                }
            } label: {
                Text(LocalizedStringResource("workdesk.conversation.exactMessage", defaultValue: "Full outgoing message"))
                    .font(.subheadline.weight(.medium))
            }
            .accessibilityIdentifier("workdesk-handoff-full-message")
            Text(LocalizedStringResource("workdesk.conversation.sendExplanation", defaultValue: "Send starts a new conversation with the gateway above."))
                .font(.caption).foregroundStyle(AppColors.textSecondary)
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
        HStack(spacing: 12) {
            Spacer(minLength: 0)
            if let acceptedID = handoff.acceptedConversationID {
                Button {
                    guard !busy else { return }
                    draft.startAnotherConversation()
                } label: {
                    footerLabel(primary: false) {
                        Text(LocalizedStringResource("workdesk.conversation.another", defaultValue: "New conversation"))
                    }
                }
                .choiceCardButton(cornerRadius: 22)
                .disabled(busy)
                .accessibilityIdentifier("workdesk-handoff-prepare-another")
                Button {
                    guard !busy, draft.clearPersistedRequest() else { return }
                    dismiss()
                    onOpenConversation(acceptedID)
                } label: {
                    footerLabel(primary: true) {
                        Label {
                            Text(LocalizedStringResource("workdesk.brief.openChat", defaultValue: "Open chat"))
                        } icon: { Image(systemName: "arrow.up.right") }
                    }
                }
                .primaryCTAButton()
                .disabled(busy)
                .accessibilityIdentifier("workdesk-handoff-open-chat")
            } else if let packet = handoff.prepared {
                Button {
                    handoff.discardPreparation()
                } label: {
                    footerLabel(primary: false) {
                        Text(LocalizedStringResource("workdesk.conversation.reviewBack", defaultValue: "Back"))
                    }
                }
                .choiceCardButton(cornerRadius: 22)
                .disabled(busy)
                .accessibilityIdentifier("workdesk-handoff-back")
                Button {
                    Task {
                        let token = presentationID
                        guard draft.isCurrentPresentation(token), !requestNeedsRecovery,
                              !draft.isPersistenceUnavailable, let id = await handoff.send() else { return }
                        // Preserve navigation if a deep link took over while
                        // local acceptance was in flight. Never send again.
                        guard draft.isCurrentPresentation(token), draft.clearPersistedRequest() else { return }
                        dismiss()
                        onOpenConversation(id)
                    }
                } label: {
                    footerLabel(primary: true) {
                        HStack(spacing: 8) {
                            if handoff.isSending { ProgressView().controlSize(.small) }
                            Text(String(localized: "workdesk.brief.sendTo", defaultValue: "Send to \(packet.gatewayName)"))
                                .fixedSize(horizontal: false, vertical: true)
                            Image(systemName: "arrow.up.right")
                        }
                    }
                }
                .primaryCTAButton()
                .disabled(busy || requestNeedsRecovery || draft.isPersistenceUnavailable)
                .accessibilityIdentifier("workdesk-handoff-send")
            } else {
                Button {
                    Task { await close() }
                } label: {
                    footerLabel(primary: false) {
                        Text(LocalizedStringResource("common.close", defaultValue: "Close"))
                    }
                }
                .choiceCardButton(cornerRadius: 22)
                .disabled(busy)
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("workdesk-handoff-close")
                Button {
                    taskIsFocused = false
                    Task {
                        let token = presentationID
                        guard !requestNeedsRecovery, await save(), draft.isCurrentPresentation(token),
                              !requestNeedsRecovery, !blocked else { return }
                        await handoff.prepare(title: title, brief: draft.brief, cards: included, ref: draft.selectedGateway,
                            projectID: projectID, projectContext: draft.projectContext, remoteResultIDs: draft.remoteResultIDs)
                    }
                } label: {
                    footerLabel(primary: true) {
                        HStack(spacing: 8) {
                            if busy { ProgressView().controlSize(.small) }
                            Text(LocalizedStringResource("workdesk.conversation.review", defaultValue: "Review"))
                            Image(systemName: "arrow.right")
                        }
                    }
                }
                .primaryCTAButton()
                .disabled(busy || requestNeedsRecovery || draft.isPersistenceUnavailable || gateway == nil || blocked || draft.brief.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("workdesk-handoff-review")
            }
        }
        // Both labels take the height of the taller action. Long gateway names
        // and larger text can grow the row without splitting its two actions.
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 24).padding(.vertical, 16)
        .background(.regularMaterial)
        .overlay(alignment: .top) { Divider() }
        .accessibilityIdentifier("workdesk-conversation-footer")
    }

    private func footerLabel<Content: View>(primary: Bool, @ViewBuilder content: () -> Content) -> some View {
        content()
            .font(.headline)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 18)
            .padding(.vertical, 11)
            .frame(minHeight: 44, maxHeight: .infinity)
            .foregroundStyle(primary ? Color.black : AppColors.textPrimary)
            .background(primary ? AppColors.brandAmber : AppColors.cardBackgroundElevated, in: Capsule())
    }

    private func close() async {
        guard !busy else { return }
        if draft.persistedRequestWasRemoved {
            onEndEditing()
            dismiss()
            return
        }
        let token = presentationID
        guard await save(), draft.isCurrentPresentation(token) else { return }
        handoff.discardPreparation()
        onEndEditing()
        dismiss()
    }

    private func save() async -> Bool {
        guard !draft.isSaving, draft.persistenceConflict == nil, draft.persistChanges() else { return false }
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
        return success && draft.persistChanges()
    }
}

/// The shared Chat picker lives in the sheet header, never a toolbar principal
/// slot that a native sheet may omit. Review always names its frozen route;
/// returning Back is required before choosing another destination.
private struct WorkDeskGatewayHeader: View {
    @Bindable var draft: WorkDeskBriefDraft

    var body: some View {
        let handoff = draft.handoff
        let packet = handoff.prepared
        GatewayPicker(
            options: handoff.gateways.map { .init(ref: $0.ref, name: $0.name) },
            selectedRef: packet?.connection.option.ref ?? draft.selectedGateway,
            selectedName: packet?.gatewayName,
            allowsSelection: draft.interruptedHandoffID == nil && !draft.isPersistenceUnavailable && !draft.isSaving && !handoff.isPreparing && !handoff.isSending
                && packet == nil && handoff.acceptedConversationID == nil,
            usesStandaloneTouchTarget: true,
            optionAccessibilityPrefix: "workdesk-gateway-"
        ) { ref in
            guard draft.interruptedHandoffID == nil, !draft.isPersistenceUnavailable, !draft.isSaving, !handoff.isPreparing, !handoff.isSending,
                  handoff.prepared == nil, handoff.acceptedConversationID == nil,
                  handoff.gateways.contains(where: { $0.ref == ref }) else { return }
            draft.selectedGateway = ref
        }
        .accessibilityIdentifier("workdesk-gateway-picker")
    }
}
#endif
