#if os(iOS)
// Conduck
// ConversationLibraryView.swift
//
// iPad library:
// `NavigationSplitView` with the conversation list as the sidebar + the
// thread as the detail. Used as the iPad root content; iPhone instead pushes
// `ConversationListView` from a ContentView toolbar affordance.
//
// The text/voice composer + Settings access live in the detail column so the
// iPad split keeps a single capture surface. The host (ContentView) owns the
// recorder + the send-turn forward + the selected conversation binding. This
// view is iOS-only (the `iOSMessageComposerBar` it mounts is `#if os(iOS)`).

import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
#if canImport(UIKit)
import UIKit
#endif

struct ConversationLibraryView: View {
    @Binding var selectedConversationID: UUID?
    var recorder: InAppAudioRecorder
    /// Forward a user turn (typed or spoken, with optional attachments) to the
    /// converse path (ContentView owns the conversation-minting + shared detail
    /// VM). The `modality` tags the turn (`.text` typed / `.voice` spoken) for
    /// the bubble footer chip.
    let onSendTurn: (ComposerTurnDispatch, TurnModality) async -> Bool
    let isRemoteAgentConfigured: Bool
    /// Active backend display name shown as the detail-column nav title
    /// (fallback "Personal AI"). Host-owned (`ContentView.backendTitle`).
    let backendTitle: String
    /// The fully-configured gateway refs (token + url): built-ins first, then
    /// customs. Host-owned. The detail-column gateway picker renders only when
    /// `canPickBackend` is true.
    let configuredRefs: [RemoteAgentRef]
    /// Cached custom roster, for resolving picker labels without an actor hop.
    /// Host-owned (`ContentView.customGateways`).
    let customGateways: [CustomGateway]
    /// Session-local gateway-picker selection for the NEXT new conversation.
    /// Bound through to the host (`ContentView.pickerSelectedRef`), whose
    /// `sendTurn` mint reads it. Writing the binding from the picker changes the
    /// gateway the next new conversation uses.
    @Binding var selectedRef: RemoteAgentRef
    /// Host-computed gate: ≥2 configured AND no conversation selected (new/empty).
    /// When true the detail toolbar shows the gateway dropdown instead of a
    /// static title.
    let canPickBackend: Bool
    /// Notify the host that the picker selection changed so it can refresh the
    /// title preview (the host owns `backendTitle`).
    let onPickBackend: () -> Void
    /// Open the host's Settings sheet, optionally deep-linked to a category. The
    /// host owns the sheet; passing `.voice` lands directly on Settings → Voice
    /// (the mic-gate redirect). `nil` opens the root list.
    let onOpenSettings: (SettingsView.Category?) -> Void
    /// Deep-link straight into guided setup (present Settings → Personal AI + arm
    /// the auto-open latch → the first-run primer). Dedicated closure, distinct
    /// from `onOpenSettings`, so the ordinary Settings deep-links (`.voice`/`nil`)
    /// never auto-open the guided cover. Used by the unconfigured empty state +
    /// locked composer.
    let onOpenGuidedSetup: () -> Void
    /// STABLE host-owned Settings VM (threaded from `ContentView`) — reused by the
    /// composer's file-transfer setup sheet so it isn't re-minted per open.
    let settingsVM: SettingsViewModel

    @State private var detailVM: ConversationDetailViewModel?
    /// The conversation the haptic observer last saw, so a thread SWITCH (which
    /// swaps `detailVM` and thus changes the observed `isAwaitingReply`) can be
    /// told apart from a genuine send/receive on the current thread.
    @State private var lastHapticConversationID: UUID?
    /// Draft owned here so the `⌘Return` keyboard shortcut can read + send the
    /// current composer text without reaching into the composer's private state.
    @State private var composerDraft: String = ""
    /// Sidebar search text. Owned here (NOT by `ConversationListView`'s native
    /// `.searchable`, which iOS renders above the pinned New button) and threaded
    /// through `externalSearchText` so the custom `SidebarSearchField` in the
    /// header drives filtering — mirrors `MainWindowView.sidebarSearch`.
    @State private var sidebarSearch = ""
    /// Shared attachment staging for the iPad composer (pickers + camera + the
    /// staged collection + ⌘V paste).
    @State private var attachmentCoordinator = ComposerAttachmentCoordinator()
    /// Contextual recovery offered after a GENUINE voice hard failure (language
    /// unsupported on-device / model self-heal couldn't complete). nil = none on
    /// screen. The missing-model case self-heals upstream in `InAppAudioRecorder`,
    /// so this is the user-tapped forward path for residual hard failures.
    @State private var voiceRecovery: VoiceRecoveryOption? = nil
    /// Detail-column no-selection empty-mascot pose. Drawn once at `@State`
    /// creation (NOT in `.onAppear`, which SwiftUI re-fires) so it stays stable
    /// across re-render. This host state has no conversation VM of its own.
    @State private var hostMascot = MascotShuffleBag.next()
    /// Split-view column visibility. Drives the collapsed-sidebar safety net: a
    /// trailing compose item appears in the DETAIL toolbar only when the sidebar
    /// is hidden, so the prominent sidebar New button never becomes unreachable.
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic

    /// True while the in-app mic is capturing or transcribing (Part 1f). Gates
    /// the host `⌘Return` shortcut so a keyboard send can't race the
    /// voice-populates-the-field flow.
    private var isCaptureActive: Bool {
        switch recorder.state {
        case .recording, .processing, .preparingVoice: return true
        case .idle, .error: return false
        }
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            ConversationListView(
                onSelect: { id in
                    selectedConversationID = id
                },
                onNewConversation: { startNewConversation() },
                // The pinned header (safeAreaInset below) owns New + the custom
                // search field, so suppress the toolbar New item and drive the
                // list's filter via `externalSearchText` (no native `.searchable`).
                // Delete-All renders as a bare trash button like iPhone
                // (`deleteAllInMenu: false`) — the slim title-less bar has room
                // beside the system sidebar toggle. (Args in declaration order.)
                showsToolbarActions: true,
                externalSearchText: $sidebarSearch,
                customGateways: customGateways,
                showsGatewayBadge: configuredRefs.count >= 2,
                // iPad sidebar is always-visible (not a sheet), so the footer
                // row flips Settings directly — no deferred-after-dismiss flag.
                // No deep-link: the footer row opens the Settings root list.
                onOpenSettings: { onOpenSettings(nil) },
                newConversationInToolbar: false,
                deleteAllInMenu: false,
                // Persistent split-view sidebar: highlight the active thread's row.
                selectedConversationID: selectedConversationID
            )
            // Mac-mirroring pinned header: prominent New button on top, custom
            // search field directly below it (identical stack + styling to
            // `MainWindowView.sidebar`). The list's native `.searchable` is
            // suppressed (we pass `externalSearchText`), so this header — not the
            // nav bar — owns search, sitting tight under the slim Delete-All/toggle
            // bar with no wasted large-title band.
            .safeAreaInset(edge: .top) {
                VStack(spacing: 8) {
                    Button {
                        startNewConversation()
                    } label: {
                        Label(
                            LocalizedStringResource("conversations.newConversation", defaultValue: "New Conversation"),
                            systemImage: "square.and.pencil"
                        )
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(AppColors.brandAmber)
                    .accessibilityIdentifier("sidebar.newConversation")  // stable QA target (non-localized)

                    SidebarSearchField(text: $sidebarSearch)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(AppColors.cardBackground)
            }
        } detail: {
            detailColumn
        }
        .onChange(of: selectedConversationID) { oldID, newID in
            attachmentCoordinator.discardForNavigation(from: oldID, to: newID)
            composerDraft = ""   // don't carry a half-typed draft into another thread
            syncDetailVM()
        }
        .onChange(of: detailVM?.isAwaitingReply) { old, new in
            handleInFlightHaptic(from: old, to: new)
        }
        .onAppear { syncDetailVM() }
    }

    /// Send/receive haptics keyed off the in-flight transition: a light impact
    /// when a turn is committed (false→true) and a success notification when the
    /// reply lands (true→false). Optionals because `detailVM` is nil before the
    /// first conversation is minted.
    private func handleInFlightHaptic(from old: Bool?, to new: Bool?) {
        // A coinciding conversation switch = VM swap, not a real transition —
        // resync and skip so it doesn't fire a stray buzz. (nil → first-minted
        // id is NOT a switch, so the first send of a new thread still buzzes.)
        if let prev = lastHapticConversationID, prev != selectedConversationID {
            lastHapticConversationID = selectedConversationID
            return
        }
        lastHapticConversationID = selectedConversationID
        if old != true, new == true {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        } else if old == true, new == false {
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        }
    }

    @ViewBuilder
    private var detailColumn: some View {
        ZStack {
            LinearGradient(
                colors: [AppColors.gradientStart, AppColors.gradientEnd],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                threadContent
            }

            // Hardware keyboard shortcuts (iPad). Zero-size buttons so the
            // shortcuts register without occupying layout. ⌘Return sends the
            // current draft; ⌘N starts a new conversation (clears the selection
            // → next turn mints a fresh conversation via the host's send path).
            keyboardShortcuts
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 0) {
                if !isRemoteAgentConfigured {
                    // No gateway yet → the composer is a gated CTA, not a live
                    // field that errors on send. Deep-links straight into guided
                    // setup (same as the unconfigured empty-state hero).
                    LockedComposerBar {
                        onOpenGuidedSetup()
                    }
                } else {
                    // Contextual voice hard-failure recovery — sits just above the
                    // composer (whose inline `.error` banner names the failure), a
                    // single user-tapped button. Never an automatic teleport.
                    if let option = voiceRecovery {
                        VoiceRecoveryButton(option: option) {
                            applyVoiceRecovery(option)
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 8)
                        .transition(.opacity)
                    }
                    AttachmentComposerContainer(
                        viewModel: detailVM,
                        recorder: recorder,
                        draft: $composerDraft,
                        coordinator: attachmentCoordinator,
                        onSend: { dispatch in
                            await onSendTurn(dispatch, .text)
                        },
                        onVoiceResult: handleVoiceResult,
                        settingsVM: settingsVM,
                        pendingNewConversationRef: selectedRef
                    )
                }
            }
        }
        // The principal toolbar item always owns the centered title control
        // (`gatewayTitleControl`: picker / clone-tappable title / static title),
        // so the nav title stays empty to avoid double-titling. Clone is folded
        // into that control — no separate trailing button.
        .navigationTitle(Text(""))
        .toolbar {
            ToolbarItem(placement: .principal) {
                gatewayTitleControl
            }
            // Collapsed-sidebar safety net: when the sidebar is hidden, the
            // prominent sidebar New button is unreachable, so surface a trailing
            // compose item in the detail toolbar. Gated EXACTLY on `.detailOnly`
            // — for a two-column split, both-columns-visible resolves to
            // `.doubleColumn` (and the initial `.automatic` resolves to
            // detailOnly/doubleColumn/all), so a `!= .all` test would fire while
            // the sidebar is still shown → a DUPLICATE New affordance. The
            // sidebar (and its New button) is gone ONLY in `.detailOnly`, so
            // that's precisely when this fallback is needed.
            if columnVisibility == .detailOnly {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        startNewConversation()
                    } label: {
                        Image(systemName: "square.and.pencil")
                    }
                    .accessibilityLabel("New conversation")  // xcstrings: chat-ui
                    .accessibilityIdentifier("toolbar.newConversation.detail")  // stable QA target (non-localized)
                }
            }
        }
    }

    /// The principal-placement gateway `Menu` for the iPad detail column. Label
    /// is the selected backend's name + a chevron; content lists the configured
    /// backends with a checkmark on the active one. Self-hosted gateways render
    /// first; hosted-model services (OpenRouter) appear in a labelled "Hosted"
    /// section below. Picking writes the host's binding and notifies the host.
    @ViewBuilder
    private var gatewayPickerMenu: some View {
        // Partition configured refs by category so self-hosted renders first.
        let selfHostedRefs = configuredRefs.filter {
            guard case .builtin(let b) = $0 else { return true }
            return RemoteAgentBackendRegistry.lookup(id: b).category == .selfHostedAgent
        }
        let hostedRefs = configuredRefs.filter {
            guard case .builtin(let b) = $0 else { return false }
            return RemoteAgentBackendRegistry.lookup(id: b).category == .hostedModel
        }
        Menu {
            ForEach(selfHostedRefs, id: \.self) { ref in
                let name = RemoteAgentRefMetadata.displayName(for: ref, customs: customGateways)
                Button {
                    selectedRef = ref
                    onPickBackend()
                } label: {
                    if ref == selectedRef {
                        Label(name, systemImage: "checkmark")
                    } else {
                        Text(name)
                    }
                }
            }
            if !hostedRefs.isEmpty {
                Section(String(localized: LocalizedStringResource(
                    "settings.remoteAgent.hostedModels.header",
                    defaultValue: "Hosted models"
                ))) {
                    ForEach(hostedRefs, id: \.self) { ref in
                        let name = RemoteAgentRefMetadata.displayName(for: ref, customs: customGateways)
                        Button {
                            selectedRef = ref
                            onPickBackend()
                        } label: {
                            if ref == selectedRef {
                                Label(name, systemImage: "checkmark")
                            } else {
                                Text(name)
                            }
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(RemoteAgentRefMetadata.displayName(for: selectedRef, customs: customGateways))
                    .font(.headline)
                    .foregroundStyle(AppColors.textPrimary)
                Image(systemName: "chevron.down")
                    .font(.caption2)
                    .foregroundStyle(AppColors.textSecondary)
            }
        }
        .accessibilityLabel("Choose gateway")  // xcstrings: chat-ui
    }

    /// The centered principal-toolbar control. Three-way: the gateway picker
    /// when a new/empty chat with ≥2 backends can pick; else a tappable title
    /// that folds in "Clone & continue" when the bound thread is clone-eligible
    /// (has turns, gateway available, somewhere to switch to); else a plain
    /// static title.
    @ViewBuilder
    private var gatewayTitleControl: some View {
        if canPickBackend && !attachmentCoordinator.gatewaySelectionLocked {
            gatewayPickerMenu
        } else if let vm = detailVM, vm.canSwitchGateway, vm.hasTurns, vm.boundGatewayAvailable {
            Button { vm.showingGatewaySheet = true } label: {
                HStack(spacing: 4) {
                    Text(backendTitle)
                        .font(.headline)
                        .foregroundStyle(AppColors.textPrimary)
                    Image(systemName: "chevron.down")
                        .font(.caption2)
                        .foregroundStyle(AppColors.textSecondary)
                }
            }
            .accessibilityLabel(Text(LocalizedStringResource("conversations.switchGateway", defaultValue: "Clone & continue on another gateway")))
            .accessibilityIdentifier("toolbar.cloneGateway")
        } else {
            Text(backendTitle)
                .font(.headline)
                .foregroundStyle(AppColors.textPrimary)
        }
    }

    @ViewBuilder
    private var keyboardShortcuts: some View {
        Button {
            sendCurrentDraft()
        } label: { EmptyView() }
        .keyboardShortcut(.return, modifiers: .command)
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)

        Button {
            startNewConversation()
        } label: { EmptyView() }
        .keyboardShortcut("n", modifiers: .command)
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)

        // ⌘V — stage a pasteboard image or file (iPad polish, key UX decision #8).
        Button {
            pasteFromClipboard()
        } label: { EmptyView() }
        .keyboardShortcut("v", modifiers: .command)
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }

    /// Stage a pasteboard image (or file URL) on ⌘V. Images route through
    /// `stageImage` so a paste gets the SAME dual-route treatment as the
    /// picker / camera / drop entry points (inline vision + an editable
    /// file-server copy when `selectedRef`'s gateway has a file-server; inline-only
    /// otherwise — `stageImage` resolves that internally). A pasted FILE URL goes
    /// through the SAME unified classifier as the importer (`stageServerFiles`:
    /// image → inline; text → planner; binary → server upload or a `.needsSetup`
    /// tile) — never a raw `.file(url)` append, which doomed a pasted binary to a
    /// misleading "couldn't be read" failure at send. A plain-text paste is left
    /// to the TextField's own paste handling.
    private func pasteFromClipboard() {
        // No gateway → the composer is the locked CTA, not a live field. Don't let
        // a hardware ⌘V stage attachments into a composer the user can't send from.
        guard isRemoteAgentConfigured else { return }
        #if canImport(UIKit)
        let pb = UIPasteboard.general
        if pb.hasImages, let image = pb.image, let data = image.jpegData(compressionQuality: 0.95) {
            attachmentCoordinator.stagePastedImage(
                data,
                vm: detailVM,
                resolveRef: authoritativeComposerRef
            )
        } else if pb.hasURLs, let url = pb.urls?.first, url.isFileURL {
            attachmentCoordinator.stagePastedFiles(
                [url],
                vm: detailVM,
                resolveRef: authoritativeComposerRef
            )
        }
        #endif
    }

    /// Send the current composer draft (⌘Return). Mirrors the composer's own
    /// send: trim, guard non-empty + not in-flight, clear, forward to the host.
    /// A nil `detailVM` is allowed — the host mints a fresh conversation on the
    /// first send.
    private func sendCurrentDraft() {
        // No gateway → the composer is the locked CTA, not a live field. A
        // hardware ⌘Return must NOT hit the `remoteAgentNotConfigured` send path;
        // the user reaches setup via the locked bar / empty-state CTA instead.
        guard isRemoteAgentConfigured else { return }
        let text = composerDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        // An attachment-only turn is valid; block only when nothing is staged
        // and there's no text, or a turn/load is in flight. Also block while a
        // capture is active (recording/processing) — Part 1f: ⌘Return must not
        // race the voice-populates-the-field flow and send a stale/empty draft.
        // The attachment gates MUST mirror the composer bar's send-disabled chain
        // exactly — `pendingAttachments` silently OMITS a `.needsSetup` /
        // not-yet-uploaded `.serverFile` tile and `clear()` then deletes its
        // staging temp, so an ungated ⌘Return would silently destroy the file.
        guard (!text.isEmpty || !attachmentCoordinator.staged.isEmpty),
              !attachmentCoordinator.staged.hasLoadingItem,
              !attachmentCoordinator.staged.hasUploadingItem,
              !attachmentCoordinator.staged.hasFailedUpload,
              !attachmentCoordinator.staged.hasNeedsSetupItem,
              !isCaptureActive,
              detailVM?.isAwaitingReply != true,
              attachmentCoordinator.beginAttachmentDispatch() else { return }
        let submittedDraft = composerDraft
        Task {
            defer { attachmentCoordinator.endAttachmentDispatch() }
            guard let dispatchRoute = await authoritativeComposerRoute() else { return }
            // Bounded ~2s upload join (same as the composer's onSendText): give a
            // freshly-staged dual attachment's eager upload a brief window so its
            // storedKey rides this turn's "also on disk" ref.
            await attachmentCoordinator.awaitPreferredUploads()
            guard let dispatch = attachmentCoordinator.makeDispatch(
                text: text,
                route: dispatchRoute
            ) else {
                detailVM?.reportComposerDispatchRejection()
                return
            }
            let accepted = await onSendTurn(dispatch, .text)
            if accepted {
                attachmentCoordinator.clearAfterSuccessfulHandoff(dispatch)
                if composerDraft == submittedDraft {
                    composerDraft = ""
                }
            }
        }
    }

    /// Resolve the route from the persisted conversation backend when a thread
    /// exists; only a genuinely VM-less composer may use the new-chat picker.
    /// Rechecks selection after the store hop so a late result cannot stage/send
    /// onto a conversation the user has already left. The returned gateway +
    /// conversation pair is immutable and must be sealed unchanged after any
    /// later preferred-upload join.
    private func authoritativeComposerRoute() async -> ComposerDispatchRoute? {
        if let vm = detailVM {
            let conversationID = vm.conversationID
            guard selectedConversationID == conversationID else {
                return nil
            }
            guard let raw = try? await ConversationStore.shared
                .fetchConversation(id: conversationID)?.backend else {
                vm.reportComposerDispatchRejection()
                return nil
            }
            guard selectedConversationID == conversationID else { return nil }
            guard let ref = RemoteAgentRef(rawString: raw) else {
                vm.reportComposerDispatchRejection()
                return nil
            }
            return ComposerDispatchRoute(ref: ref, conversationID: conversationID)
        }
        guard selectedConversationID == nil else { return nil }
        return ComposerDispatchRoute(ref: selectedRef, conversationID: nil)
    }

    /// Staging needs only the gateway, but shares the same authoritative
    /// resolution and selection revalidation as dispatch capture.
    private func authoritativeComposerRef() async -> RemoteAgentRef? {
        (await authoritativeComposerRoute())?.ref
    }

    /// ⌘N — clear the selection so the detail column shows the start empty
    /// state; the next turn mints a fresh conversation (the same path the host
    /// uses on first send). Reuses the existing minting flow rather than adding
    /// a new store call.
    private func startNewConversation() {
        composerDraft = ""
        selectedConversationID = nil
        hostMascot = MascotShuffleBag.next()  // fresh shuffle-bag pose for the new empty state
    }

    /// Route a spoken turn's STT Result: on success POPULATE the composer draft
    /// for review/edit instead of auto-sending (Part 1b). Staged attachments are
    /// LEFT in place (no `attachmentCoordinator.clear()`, no `onSendTurn`) so the
    /// user can dictate over a staged photo and then tap Send once to ship text +
    /// photo together — the attachment-drop bug fix. Failure drops silently (the
    /// composer surfaces the recorder error banner from `recorder.state`).
    private func handleVoiceResult(_ result: Result<String, AppError>) async {
        switch result {
        case .success(let text):
            voiceRecovery = nil
            composerDraft = appendingTranscript(text, to: composerDraft)
            AccessibilityAnnouncer.announce(LocalizedStringResource(
                "voice.announce.transcriptAdded",
                defaultValue: "Transcript added"
            ))
        case .failure(let error):
            // Voice hard failure (Workstream A): the missing-model case self-heals
            // upstream in `InAppAudioRecorder`; what remains is a GENUINE hard
            // failure (unsupported language, or a model self-heal that couldn't
            // complete). Keep the composer's inline `.error` banner and add ONE
            // contextual, USER-TAPPED recovery — never an automatic teleport.
            switch error {
            case .appleSpeechModelNotInstalled, .appleSpeechLanguageUnsupported:
                if let cloudID = await SettingsManager.shared.firstConfiguredCloudSTTPresetID() {
                    voiceRecovery = .useCloud(presetID: cloudID)
                } else {
                    voiceRecovery = .openVoiceSettings
                }
            default:
                voiceRecovery = nil
            }
        }
    }

    /// Apply a user-tapped voice recovery: switch to the configured cloud preset,
    /// or open Settings → Voice (user-initiated). Clears the banner + affordance.
    private func applyVoiceRecovery(_ option: VoiceRecoveryOption) {
        recorder.dismissError()
        voiceRecovery = nil
        switch option {
        case .useCloud(let presetID):
            Task { await SettingsManager.shared.setActivePresetID(presetID) }
        case .openVoiceSettings:
            onOpenSettings(.voice)
        }
    }

    @ViewBuilder
    private var threadContent: some View {
        if !isRemoteAgentConfigured {
            unconfiguredEmptyState
        } else if let vm = detailVM {
            // Cap + center bubbles on the same 720pt axis as the composer card.
            ConversationThreadView(viewModel: vm, contentMaxWidth: Constants.Layout.chatContentWidth, emptyMascot: hostMascot)
                .id(vm.conversationID)
        } else {
            startEmptyState
        }
    }

    private func syncDetailVM() {
        if let id = selectedConversationID {
            if detailVM?.conversationID != id {
                detailVM = ConversationDetailViewModel(conversationID: id)
            }
        } else {
            detailVM = nil
        }
    }

    // MARK: - Empty states

    private var unconfiguredEmptyState: some View {
        UnconfiguredEmptyState(mascot: hostMascot, action: onOpenGuidedSetup)
    }

    private var startEmptyState: some View {
        VStack(spacing: 16) {
            EmptyStateMascot(pose: hostMascot, height: 150)
            Text("Type a message or tap the mic.")  // xcstrings: composer
                .font(.callout)
                .foregroundStyle(AppColors.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
#endif
