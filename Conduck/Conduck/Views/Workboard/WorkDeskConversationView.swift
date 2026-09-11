// SPDX-License-Identifier: Apache-2.0

// Conduck
// WorkDeskConversationView.swift
//
// A project's conversation uses the same thread, composer, transport and retry
// surfaces as Chats. The workspace retains one session per conversation so a
// trip back to materials preserves the typed draft. Its VM comes from the host's
// existing registry; this view never creates a competing network owner.
// Navigation invalidates unfinished composer work before an asynchronous send
// can claim it. An explicitly accepted send continues under that retained VM.

#if !os(watchOS)
import SwiftUI
import Observation
#if os(macOS)
import UniformTypeIdentifiers
#endif

@Observable @MainActor
final class WorkDeskConversationSession {
    let conversationID: UUID
    var draft = ""
    let emptyMascot = MascotShuffleBag.next()
    let recorder = InAppAudioRecorder()
    var voiceRecovery: VoiceRecoveryOption?
    private(set) var presentationID: UUID?
    #if os(iOS)
    let attachments = ComposerAttachmentCoordinator()
    #elseif os(macOS)
    let drops = WorkDeskConversationDrop()
    #endif

    init(conversationID: UUID) {
        self.conversationID = conversationID
    }

    @discardableResult
    func resume() -> UUID {
        let token = UUID()
        presentationID = token
        return token
    }

    func isCurrentPresentation(_ token: UUID?) -> Bool {
        guard let token else { return false }
        return presentationID == token
    }

    /// The workspace calls this at navigation time, before disappearance. A
    /// disappeared view also calls it with its own token, so an older mount
    /// cannot cancel a newly reopened session for the same conversation.
    func suspend(ifCurrent token: UUID? = nil) {
        if let token, !isCurrentPresentation(token) { return }
        presentationID = nil
        recorder.onAutoStopResult = nil
        switch recorder.state {
        case .recording: recorder.cancelRecording()
        case .processing, .preparingVoice: recorder.cancelProcessing()
        case .idle, .error: break
        }
        #if os(iOS)
        attachments.showingPhotosPicker = false
        attachments.pickerSelection.removeAll()
        attachments.showingFileImporter = false
        attachments.showingCamera = false
        attachments.showingCameraDeniedAlert = false
        attachments.discardForNavigation(from: conversationID, to: nil)
        #elseif os(macOS)
        drops.cancel()
        #endif
    }

    func accepts(
        _ dispatch: ComposerTurnDispatch,
        conversation: ConversationRecord,
        viewModelID: UUID,
        presentation token: UUID?
    ) -> Bool {
        isCurrentPresentation(token)
            && conversation.id == conversationID
            && viewModelID == conversationID
            && dispatch.conversationID == conversationID
            && RemoteAgentRef(rawString: conversation.backend) == dispatch.ref
    }
}

struct WorkDeskConversationView: View {
    let conversation: ConversationRecord
    let viewModel: ConversationDetailViewModel
    @Bindable var session: WorkDeskConversationSession
    let settingsVM: SettingsViewModel
    /// The host can forward this to its window visibility registry. The ID is
    /// always supplied, including on hide, to permit a conditional clear.
    var onVisibilityChanged: (UUID, Bool) -> Void = { _, _ in }

    @Environment(\.workbenchDestinationIsActive) private var destinationIsActive
    @Environment(\.appearsActive) private var appearsActive
    @State private var presentationID: UUID?
    @State private var showingVoiceSettings = false

    private var ref: RemoteAgentRef? { RemoteAgentRef(rawString: conversation.backend) }
    private var isActive: Bool {
        destinationIsActive && session.isCurrentPresentation(presentationID)
    }
    #if os(macOS)
    private var canAcceptDrop: Bool {
        isActive && ref != nil && viewModel.boundGatewayAvailable
            && !viewModel.isAwaitingReply && !viewModel.showsGatewayWaitIndicator
            && session.drops.canAccept
    }
    #endif

    var body: some View {
        threadAndComposer
            .environment(\.workbenchDestinationIsActive, isActive)
            .background(AppColors.background)
            .onAppear { updatePresentation() }
            .onChange(of: destinationIsActive) { _, _ in updatePresentation() }
            .onChange(of: appearsActive) { _, _ in reportVisibility() }
            .onReceive(NotificationCenter.default.publisher(for: .settingsDidChangeRemotely)) { _ in
                // The VM's general settings observer refreshes file lanes. A
                // visible project thread must also refresh gateway availability
                // after a connection is removed or restored in Settings.
                Task { await viewModel.reload() }
            }
            .onDisappear {
                if let presentationID { session.suspend(ifCurrent: presentationID) }
                onVisibilityChanged(conversation.id, false)
            }
            .sheet(isPresented: $showingVoiceSettings.gated(by: isActive)) {
                voiceSettings
            }
            .accessibilityIdentifier("workdesk-conversation")
    }

    private var threadAndComposer: some View {
        ConversationThreadView(
            viewModel: viewModel,
            settingsVM: settingsVM,
            contentMaxWidth: Constants.Layout.chatContentWidth,
            emptyMascot: session.emptyMascot
        )
        .id(conversation.id)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                if let option = session.voiceRecovery {
                    VoiceRecoveryButton(option: option) { applyVoiceRecovery(option) }
                        .padding(.horizontal, 16)
                        .padding(.top, 8)
                }
                if let ref {
                    composer(ref: ref)
                        .disabled(!viewModel.boundGatewayAvailable)
                } else {
                    Text(LocalizedStringResource(
                        "workdesk.conversation.connectionUnavailable",
                        defaultValue: "This conversation's connection is unavailable. Its messages remain here."
                    ))
                    .font(.callout)
                    .foregroundStyle(AppColors.textSecondary)
                    .padding(16)
                    .frame(maxWidth: .infinity)
                }
            }
            #if os(macOS)
            .composerReadableWidth()
            #endif
        }
        #if os(macOS)
        .overlay {
            if session.drops.isTargeted, canAcceptDrop {
                ZStack {
                    RoundedRectangle(cornerRadius: 16)
                        .strokeBorder(AppColors.brandAmber, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                        .background(AppColors.brandAmber.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
                    Text(LocalizedStringResource("composer.drop.prompt", defaultValue: "Drop files to attach"))
                        .font(.headline)
                        .foregroundStyle(AppColors.brandAmber)
                        .padding(16)
                        .background(AppColors.cardBackground, in: Capsule())
                }
                .padding(8)
                .allowsHitTesting(false)
            }
        }
        .onDrop(of: [.image, .fileURL], isTargeted: Binding(
            get: { session.drops.isTargeted }, set: { session.drops.isTargeted = $0 }
        )) { providers in
            guard canAcceptDrop else { return false }
            return session.drops.accept(providers, conversationID: conversation.id)
        }
        #endif
    }

    @ViewBuilder
    private func composer(ref: RemoteAgentRef) -> some View {
        let token = presentationID
        #if os(macOS)
        MessageComposerBar(
            viewModel: viewModel,
            onSendText: { dispatch in await send(dispatch, presentation: token) },
            recorder: session.recorder,
            draft: $session.draft,
            onVoiceResult: { result in await handleVoiceResult(result, presentation: token) },
            settingsVM: settingsVM,
            selectedRef: ref,
            mountIdentity: .conversation(conversation.id),
            pendingDropBatch: Binding(get: { session.drops.pendingBatch }, set: { session.drops.pendingBatch = $0 }),
            dispatchingIdentity: Binding(get: { session.drops.dispatchingIdentity }, set: { session.drops.dispatchingIdentity = $0 }),
            isDropResolving: session.drops.isResolving,
            resolvingDropCount: session.drops.resolvingCount,
            onComposerEngaged: { GatewayPresenceMonitor.shared.observe(ref) }
        )
        .id(ComposerMountIdentity.conversation(conversation.id))
        #elseif os(iOS)
        AttachmentComposerContainer(
            viewModel: viewModel,
            recorder: session.recorder,
            draft: $session.draft,
            coordinator: session.attachments,
            onSend: { dispatch in await send(dispatch, presentation: token) },
            onVoiceResult: { result in await handleVoiceResult(result, presentation: token) },
            settingsVM: settingsVM,
            pendingNewConversationRef: ref,
            onComposerEngaged: { GatewayPresenceMonitor.shared.observe(ref) }
        )
        #endif
    }

    private func send(_ dispatch: ComposerTurnDispatch, presentation token: UUID?) async -> Bool {
        guard destinationIsActive,
              session.accepts(dispatch, conversation: conversation,
                              viewModelID: viewModel.conversationID,
                              presentation: token) else {
            viewModel.reportComposerDispatchRejection()
            return false
        }
        // The shared VM verifies the persisted gateway and exact file lane
        // again at dispatch. Only durable local acceptance consumes the draft
        // and staged attachments; a failure leaves the existing Retry UI intact.
        return await viewModel.submitUserTurnAwaitingLocalAcceptance(
            dispatch.text,
            modality: .text,
            attachments: dispatch.attachments,
            expectedRef: dispatch.ref,
            expectedFileLaneID: dispatch.fileLaneID
        )
    }

    private func updatePresentation() {
        if destinationIsActive {
            if !session.isCurrentPresentation(presentationID) {
                let token = session.resume()
                presentationID = token
                session.recorder.onAutoStopResult = { result in
                    Task { await handleVoiceResult(result, presentation: token) }
                }
            }
            if let ref { GatewayPresenceMonitor.shared.observe(ref) }
        } else {
            if let presentationID { session.suspend(ifCurrent: presentationID) }
            showingVoiceSettings = false
        }
        reportVisibility()
    }

    private func reportVisibility() {
        onVisibilityChanged(conversation.id, isActive && appearsActive)
    }

    private func handleVoiceResult(_ result: Result<String, AppError>, presentation token: UUID?) async {
        guard session.isCurrentPresentation(token) else { return }
        switch result {
        case .success(let text):
            session.voiceRecovery = nil
            session.draft = appendingTranscript(text, to: session.draft)
            AccessibilityAnnouncer.announce(LocalizedStringResource(
                "voice.announce.transcriptAdded", defaultValue: "Transcript added"
            ))
        case .failure(let error):
            switch error {
            case .appleSpeechModelNotInstalled, .appleSpeechLanguageUnsupported:
                let cloudID = await SettingsManager.shared.firstConfiguredCloudSTTPresetID()
                guard session.isCurrentPresentation(token) else { return }
                session.voiceRecovery = cloudID.map { .useCloud(presetID: $0) } ?? .openVoiceSettings
            default:
                session.voiceRecovery = nil
            }
        }
    }

    private func applyVoiceRecovery(_ option: VoiceRecoveryOption) {
        guard isActive else { return }
        session.recorder.dismissError()
        session.voiceRecovery = nil
        switch option {
        case .useCloud(let presetID):
            Task { await SettingsManager.shared.setActivePresetID(presetID) }
        case .openVoiceSettings:
            showingVoiceSettings = true
        }
    }

    @ViewBuilder
    private var voiceSettings: some View {
        #if os(macOS)
        MacVoiceCategory(viewModel: settingsVM)
            .frame(minWidth: 500, idealWidth: 640, minHeight: 500, idealHeight: 700)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showingVoiceSettings = false }
                }
            }
        #elseif os(iOS)
        SettingsView(viewModel: settingsVM, initialCategory: .voice)
        #endif
    }
}
#endif
