// SPDX-License-Identifier: Apache-2.0

// Conduck
// WorkDeskBriefView.swift
//
// A project's editable brief and explicit AI handoff. Materials can be left out
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
    var brief: String
    var selectedGateway: RemoteAgentRef?
    var excludedIDs: Set<UUID> = []
    let handoff: WorkDeskHandoff
    var isSaving = false
    var saveError: String?
    private var savedBrief: String
    private var savedGateway: RemoteAgentRef?
    private var activePresentationID: UUID?

    init(brief: String, preferredGatewayRef: String?, conversationResolver: WorkDeskConversationResolver = .init(), handoff: WorkDeskHandoff? = nil) {
        let gateway = preferredGatewayRef.flatMap { RemoteAgentRef(rawString: $0) }
        self.brief = brief
        self.selectedGateway = gateway
        self.savedBrief = brief
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

    func markSaved(brief: String, selectedGateway: RemoteAgentRef?) {
        savedBrief = brief
        savedGateway = selectedGateway
    }

    func discardUnsavedChanges() {
        brief = savedBrief
        selectedGateway = savedGateway
        excludedIDs = []
        saveError = nil
        handoff.discardPreparation()
    }
}

struct WorkDeskBriefView: View {
    let projectID: UUID
    let title: String
    let materials: [WorkboardMaterialSnapshot]
    let onSave: @MainActor (String, String?) async -> Bool
    let onOpenConversation: @MainActor (UUID) -> Void
    let onEndEditing: @MainActor () -> Void

    @Environment(\.dismiss) private var dismiss
    @Bindable private var draft: WorkDeskBriefDraft
    @State private var presentationID: UUID?
    @State private var showingDiscardConfirmation = false

    init(
        projectID: UUID,
        title: String,
        initialBrief: String,
        preferredGatewayRef: String?,
        materials: [WorkboardMaterialSnapshot],
        draft: WorkDeskBriefDraft? = nil,
        onSave: @escaping @MainActor (String, String?) async -> Bool,
        onOpenConversation: @escaping @MainActor (UUID) -> Void,
        onEndEditing: @escaping @MainActor () -> Void = {}
    ) {
        self.projectID = projectID
        self.title = title
        self.materials = materials
        self.onSave = onSave
        self.onOpenConversation = onOpenConversation
        self.onEndEditing = onEndEditing
        self.draft = draft ?? WorkDeskBriefDraft(brief: initialBrief, preferredGatewayRef: preferredGatewayRef)
    }

    private var handoff: WorkDeskHandoff { draft.handoff }

    private var included: [WorkboardMaterialSnapshot] {
        materials.filter { !draft.excludedIDs.contains($0.id) }
    }
    private var expanded: [WorkboardMaterialSnapshot] { WorkDeskHandoffPolicy.expanded(included) }
    private var gateway: WorkDeskGatewayOption? { handoff.gateways.first { $0.ref == draft.selectedGateway } }
    private var busy: Bool { draft.isSaving || handoff.isPreparing || handoff.isSending }
    private var blocked: Bool {
        expanded.contains { WorkDeskHandoffPolicy.blockingReason($0, gateway: gateway) != nil }
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
                        introduction
                        instructionEditor
                        materialChecklist
                        gatewayPicker
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
            .navigationTitle(Text(LocalizedStringResource("workdesk.brief.title", defaultValue: "Project brief")))
            .safeAreaInset(edge: .bottom, spacing: 0) { footer }
            .toolbar {
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
                        Text(LocalizedStringResource("workdesk.brief.saveClose", defaultValue: "Save & close"))
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
        .task { await handoff.loadGateways() }
        .onReceive(NotificationCenter.default.publisher(for: .settingsDidChangeRemotely)) { _ in
            Task { await handoff.loadGateways() }
        }
        .onAppear { presentationID = draft.beginPresentation() }
        .onDisappear {
            if let presentationID { draft.endPresentation(presentationID) }
        }
        #if os(macOS)
        .frame(minWidth: 580, idealWidth: 740, minHeight: 640, idealHeight: 800)
        #endif
    }

    private var introduction: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text(LocalizedStringResource("workdesk.brief.eyebrow", defaultValue: "FROM IDEAS TO A FIRST PROMPT"))
                    .font(.caption.weight(.semibold))
                    .tracking(1.1)
            } icon: {
                Image(systemName: "sparkle")
            }
            .foregroundStyle(AppColors.brandAmber)
            Text(title).font(.largeTitle.weight(.bold)).foregroundStyle(AppColors.textPrimary)
            Text(LocalizedStringResource("workdesk.brief.intro", defaultValue: "Give your AI a clear starting point. Your project stays here as the conversation moves forward."))
                .font(.callout)
                .foregroundStyle(AppColors.textSecondary)
        }
    }

    private var instructionEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(LocalizedStringResource("workdesk.brief.instructions", defaultValue: "What would you like to achieve?"))
                .font(.headline)
            TextField(
                text: $draft.brief,
                axis: .vertical,
                label: {
                    Text(LocalizedStringResource("workdesk.brief.placeholder", defaultValue: "Describe the task, the result you want, and anything your AI should keep in mind…"))
                }
            )
            .lineLimit(6...18)
            .padding(16)
            .background(AppColors.cardBackgroundElevated, in: RoundedRectangle(cornerRadius: 16))
            .accessibilityIdentifier("workdesk-brief-instructions")
        }
    }

    private var materialChecklist: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(LocalizedStringResource("workdesk.brief.materials", defaultValue: "Bring into the conversation"))
                    .font(.headline)
                Spacer()
                Text(included.count.formatted()).font(.caption.monospacedDigit()).foregroundStyle(AppColors.textSecondary)
            }
            if materials.isEmpty {
                Text(LocalizedStringResource("workdesk.brief.noMaterials", defaultValue: "A clear brief is enough to begin. You can add materials to this project later."))
                    .font(.callout).foregroundStyle(AppColors.textSecondary)
            }
            ForEach(materials) { material in materialRow(material) }
            if !draft.excludedIDs.isEmpty {
                Text(LocalizedStringResource("workdesk.brief.excluded", defaultValue: "Unchecked materials stay in your project and will not be sent."))
                    .font(.caption).foregroundStyle(AppColors.textSecondary)
            }
        }
    }

    private func materialRow(_ material: WorkboardMaterialSnapshot) -> some View {
        let selected = !draft.excludedIDs.contains(material.id)
        let reasons = WorkDeskHandoffPolicy.expanded([material]).compactMap {
            WorkDeskHandoffPolicy.blockingReason($0, gateway: gateway)
        }
        return Button {
            if selected { draft.excludedIDs.insert(material.id) } else { draft.excludedIDs.remove(material.id) }
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? AppColors.brandAmber : AppColors.textTertiary)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 5) {
                    Text(material.name).font(.callout.weight(.medium)).foregroundStyle(AppColors.textPrimary).lineLimit(2)
                    if let companion = material.companion {
                        Text(companion.material.textContent ?? companion.name)
                            .font(.caption).foregroundStyle(AppColors.textSecondary).lineLimit(2)
                    }
                    if selected, let reason = reasons.first {
                        Text(reason).font(.caption).foregroundStyle(AppColors.textSecondary).fixedSize(horizontal: false, vertical: true)
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

    private var gatewayPicker: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(LocalizedStringResource("workdesk.brief.chooseAI", defaultValue: "Choose your AI"))
                .font(.headline)
            if handoff.gateways.isEmpty {
                Text(LocalizedStringResource("workdesk.brief.noConnections", defaultValue: "No AI connection is available on this device. Save this brief, then connect one in Settings → Personal AI."))
                    .font(.callout).foregroundStyle(AppColors.textSecondary)
            }
            if draft.selectedGateway != nil, gateway == nil {
                Text(LocalizedStringResource("workdesk.brief.savedUnavailable", defaultValue: "This project's saved connection is unavailable here. Choose another connection to continue."))
                    .font(.callout).foregroundStyle(AppColors.textSecondary)
            }
            ForEach(handoff.gateways) { option in
                Button { draft.selectedGateway = option.ref } label: {
                    HStack(spacing: 12) {
                        Image(systemName: option.isHosted ? "sparkles" : "server.rack")
                            .foregroundStyle(AppColors.brandAmber).font(.title3)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(option.name).font(.headline).foregroundStyle(AppColors.textPrimary)
                            Text(connectionDescription(option))
                                .font(.caption).foregroundStyle(AppColors.textSecondary)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: draft.selectedGateway == option.ref ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(draft.selectedGateway == option.ref ? AppColors.brandAmber : AppColors.textTertiary)
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(AppColors.cardBackgroundElevated, in: RoundedRectangle(cornerRadius: 14))
                    .overlay {
                        RoundedRectangle(cornerRadius: 14).stroke(draft.selectedGateway == option.ref ? AppColors.brandAmber.opacity(0.6) : .clear, lineWidth: 1)
                    }
                }
                .choiceCardButton(cornerRadius: 14)
                .accessibilityIdentifier("workdesk-gateway-\(option.id)")
            }
        }
    }

    private func connectionDescription(_ option: WorkDeskGatewayOption) -> LocalizedStringResource {
        if option.isHosted {
            return LocalizedStringResource("workdesk.brief.hostedCapability", defaultValue: "Hosted model · text and images · no file workspace")
        }
        if option.hasFileTransfer {
            return LocalizedStringResource("workdesk.brief.fileCapability", defaultValue: "Your gateway · text, images and attached files")
        }
        return LocalizedStringResource("workdesk.brief.textCapability", defaultValue: "Your gateway · text and images · file transfer not connected")
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
                Text(LocalizedStringResource("workdesk.brief.excluded", defaultValue: "Unchecked materials stay in your project and will not be sent."))
                    .font(.caption).foregroundStyle(AppColors.textSecondary)
            }
        }
    }

    private var acceptedHandoff: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label {
                Text(LocalizedStringResource("workdesk.brief.accepted", defaultValue: "Your handoff is in Chat"))
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
                    handoff.beginAnotherHandoff()
                    draft.excludedIDs = []
                } label: {
                    Text(LocalizedStringResource("workdesk.brief.prepareAnother", defaultValue: "Prepare another handoff"))
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
                    Text(LocalizedStringResource("workdesk.brief.edit", defaultValue: "Edit brief"))
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
                        guard await save(), draft.isCurrentPresentation(token) else { return }
                        await handoff.prepare(title: title, brief: draft.brief, cards: included, ref: draft.selectedGateway)
                    }
                } label: {
                    HStack(spacing: 8) {
                        if busy { ProgressView().controlSize(.small) }
                        Text(LocalizedStringResource("workdesk.brief.reviewButton", defaultValue: "Review handoff"))
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
        let savedBrief = draft.brief
        let savedGateway = draft.selectedGateway
        let success = await onSave(savedBrief, savedGateway?.rawString)
        if success {
            draft.markSaved(brief: savedBrief, selectedGateway: savedGateway)
        } else {
            draft.saveError = String(localized: "workdesk.brief.saveFailed", defaultValue: "Your brief could not be saved. Keep this window open and try again.")
        }
        return success
    }
}
#endif
