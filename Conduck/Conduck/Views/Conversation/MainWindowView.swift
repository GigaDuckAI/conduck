// SPDX-License-Identifier: Apache-2.0

#if os(macOS)
// Conduck
// MainWindowView.swift
//
// The unified macOS shell — a single `Window("Conduck", id: "main")` modeled on
// the Claude desktop app: a `NavigationSplitView` sidebar (New-conversation
// button + gateway picker + conversation list + bottom identity footer) and a
// detail column reusing the conversation thread + composer. Settings is a
// full-window MODE SWAP (`MacSettingsView`), NOT a sheet or a separate window:
// while `showingSettings` the window renders `MacSettingsView` INSTEAD OF
// `splitView`, giving the dense setup screens the whole resizable window. Evolved
// from the retired `ConversationsWindowView` — the VM-binding invariant below is
// copied VERBATIM and is load-bearing.
//
// VM binding (LOAD-BEARING): selecting a thread binds the coordinator's
// WINDOW lane (`bindWindowViewModel` — in-memory only, never the quick-capture
// pointer). The window is the EXPLICIT surface: browsing the sidebar AND
// sending typed turns here never retarget where the next hotkey capture lands
// — the popover's quick lane (`quickViewModel` + the per-device pointer) is
// untouched by anything done in this window. The detail thread AND the
// composer therefore always operate on `coordinator.windowViewModel`, so the
// composer's text field and its mic target the SAME conversation. The
// per-device quick-capture pointer is IMPLICIT-ONLY: window/in-app turns never
// stamp it (`ConversationDetailViewModel` stamps only when a turn rides
// `stampsQuickPointer: true` — the hotkey quick-capture lane). Same id across
// lanes shares ONE registry VM, so opening the quick thread here shows the
// popover's live spinner, not a duplicate dead one.

import KeyboardShortcuts
import SwiftUI

struct MainWindowView: View {
    let coordinator: MenuBarCoordinator

    @State private var selectedConversationID: UUID?
    /// Session-local gateway-picker selection for the NEXT new macOS
    /// conversation. Seeded from the persisted default; the picker drives it AND
    /// writes through to `coordinator.pendingNewConversationRef` so the next
    /// minted conversation actually binds to the chosen gateway.
    @State private var selectedRef: RemoteAgentRef = .builtin(Constants.remoteAgentDefaultBackendDefault)
    /// Raised by the VM-less composer while attachment staging/dispatch owns
    /// `selectedRef`; the title-bar pill becomes read-only for that interval.
    @State private var newChatGatewaySelectionLocked = false
    /// The fully-configured gateway refs (token + url): built-ins first, then
    /// customs. The gateway picker renders only when this has ≥2 entries AND no
    /// conversation is active (new/empty).
    @State private var configuredRefs: [RemoteAgentRef] = []
    /// Cached custom roster, for resolving picker labels without an actor hop.
    @State private var customGateways: [CustomGateway] = []
    /// New-chat empty-mascot pose. Drawn once at `@State` creation (NOT in
    /// `.onAppear`, which SwiftUI re-fires) so it stays stable across re-render.
    @State private var hostMascot = MascotShuffleBag.next()

    /// Sidebar search text. Owned here (NOT by `ConversationListView`'s native
    /// `.searchable`, which renders above the New Conversation button — the
    /// founder rejected that position) and passed down via `externalSearchText`
    /// so the custom `macSearchField` below the New Conversation button drives
    /// the list filter.
    @State private var sidebarSearch = ""

    /// The Settings modal. Triggered by the footer menu, ⌘,, the
    /// `.openSettingsWindow` bus, and the menu-bar "Settings…" item (via the
    /// coordinator's `pendingShowSettings` flag for the window-was-closed case).
    @State private var showingSettings = false
    /// Backing VM for the Settings sheet — one instance for the window's
    /// lifetime so its live edits/pills are coherent (NOT re-minted per open).
    @State private var settingsVM = SettingsViewModel()

    /// The WINDOW's OWN in-app recorder — independent of the popover's
    /// `coordinator.dictationService`. Host-owned exactly like iOS `ContentView`'s
    /// `InAppAudioRecorder`: isolating it keeps the composer mic from tripping
    /// `MenuBarController`'s state observer (which auto-opens the headless
    /// popover) and from sharing the menu-bar's recording timer. Driving the
    /// composer off THIS (not a shared `DictationService` transcript closure)
    /// is the fix for the dropped-transcript race — the transcript now lands in
    /// `composerDraft`, which both composer mounts bind to.
    @State private var windowRecorder = InAppAudioRecorder()
    /// Host-owned composer draft — the SINGLE source of truth both
    /// `MessageComposerBar` mounts (new-chat + active-chat) bind to, so a spoken
    /// transcript appended here lands in the visible field no matter which mount
    /// is on screen (mirrors `ContentView.composerDraft`).
    @State private var composerDraft = ""
    /// Contextual recovery offered after a GENUINE voice hard failure (language
    /// unsupported on-device / model self-heal couldn't complete). nil = none on
    /// screen. The missing-model case self-heals upstream in `InAppAudioRecorder`,
    /// so this is the user-tapped forward path for residual hard failures (never
    /// an automatic teleport). Bound by BOTH composer mounts (new-chat + active).
    @State private var voiceRecovery: VoiceRecoveryOption? = nil
    /// When non-nil the Settings sheet opens directly on this category — used by
    /// the mic-gate redirect to land on Voice. Reset to nil on dismiss so a
    /// normal ⌘, open still starts on General.
    @State private var settingsInitialCategory: MacSettingsView.Category?

    /// When non-nil, the Diagnostics category opens focused on this failure — set
    /// by the menu-bar popover's Troubleshoot hand-off (consumed alongside
    /// `settingsInitialCategory`). Reset to nil on every Settings exit so a stale
    /// focus can't leak into an unrelated Diagnostics open.
    @State private var settingsInitialFocus: DiagnosticsFocus?

    /// Guided gateway-setup presentation, owned HERE at the window root so it can be
    /// a TRUE full-window overlay (a macOS `.sheet` is always an inset panel — the
    /// founder's "still not full screen" complaint). Threaded into `MacSettingsView`
    /// → `MacPersonalAICategory`, which triggers it.
    @State private var guidedHost = GuidedGatewayHostState()

    /// The two-column shell, split from `body`'s event-modifier chain so the
    /// column builders type-check independently (keeps SourceKit within budget).
    private var splitView: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 260, ideal: 280, max: 320)
        } detail: {
            detailColumn
        }
        .toolbar {
            // Gateway identity, centered in the title bar — fills the otherwise
            // empty top strip and stays visible across new + existing chats.
            ToolbarItem(placement: .principal) {
                gatewayToolbarContent
            }
            // macOS 26 wraps a toolbar item's content in ONE shared Liquid Glass
            // capsule. Clone is now folded into the single gateway pill (the name
            // pill itself becomes the tappable Clone control when eligible), so
            // there's exactly one control here — but it already draws its own pill
            // via `gatewayPillBackground`. Suppress the system glass so that pill
            // isn't double-wrapped.
            .sharedBackgroundVisibility(.hidden)
        }
    }

    var body: some View {
        Group {
            if showingSettings {
                // Full-window mode swap: Settings REPLACES the conversation split
                // view (not a sheet), so the dense setup screens get the whole
                // resizable window. `onDone` returns + clears the deep-link slot
                // (replaces the old `.sheet(onDismiss:)` reset).
                MacSettingsView(
                    viewModel: settingsVM,
                    initialCategory: settingsInitialCategory,
                    initialFocus: settingsInitialFocus,
                    onDone: {
                        showingSettings = false
                        settingsInitialCategory = nil
                        settingsInitialFocus = nil
                    },
                    guidedHost: $guidedHost
                )
            } else {
                splitView
            }
        }
        // Drop the "Conduck" window title in BOTH modes (was scoped to splitView,
        // which is absent in settings mode → title would otherwise reappear).
        // Window menu name stays. macOS 15+.
        .toolbar(removing: .title)
        .background {
            LinearGradient(
                colors: [AppColors.gradientStart, AppColors.gradientEnd],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
        }
        // TRUE full-window guided gateway-setup overlay (replaces the old inset
        // macOS `.sheet`): covers the entire window content — sidebar, Done, the
        // lot — since `GuidedGatewaySetupView` paints its own gradient + ignores
        // safe areas. iOS/iPad keep `.fullScreenCover`; this is the macOS path.
        .overlay {
            if let presentation = guidedHost.presentation {
                GuidedGatewaySetupView(
                    viewModel: settingsVM,
                    initialPath: presentation.initialPath,
                    onDismiss: { guidedHost.dismiss() },
                    // Primer "Set up manually" → the Personal AI list. Ensure
                    // Settings is open (so `MacPersonalAICategory` is mounted), then
                    // dismiss the overlay onto it. The guided lanes carry no manual escape.
                    onPrimerManual: {
                        if !showingSettings {
                            settingsInitialCategory = .personalAI
                            showingSettings = true
                        }
                        guidedHost.dismiss()
                    },
                    showPrimer: !SettingsManager.hasSeenGatewayPrimer() && !settingsVM.hasAnyConfiguredRemoteAgent,
                    customLaneAvailable: settingsVM.customGatewayCount < Constants.maxCustomGateways
                )
                .transition(.opacity)
                .zIndex(1)
            }
        }
        #if DEBUG
        // DEBUG-only so a clean Release build omits the modifier entirely; the
        // inset is empty (layout-neutral) until `-ConduckQAMode` flips `isActive`.
        .safeAreaInset(edge: .top) {
            if QAMode.showsBanner {
                QABanner()
            }
        }
        #endif
        .preferredColorScheme(.dark)
        .onChange(of: selectedConversationID) { _, newID in
            // Explicit thread switch (sidebar tap / New / deep-link): cancel any
            // in-flight window capture so a late transcript can't append to the
            // WRONG thread, and drop a half-entered draft. Mirrors iOS's
            // `currentConversationID` clear, plus the macOS-only capture cancel
            // (the natural new→active mint does NOT change `selectedConversationID`,
            // so it's exempt — the draft Send already cleared survives the swap).
            cancelWindowCapture()
            // Stale voice error/recovery shouldn't follow a thread switch.
            // `cancelWindowCapture` only handles `.recording`/`.processing`, so the
            // `.error` banner needs an explicit clear.
            windowRecorder.dismissError()
            voiceRecovery = nil
            composerDraft = ""
            if let id = newID { coordinator.openConversation(id) }
        }
        // Opening the full-window settings overlay leaves the chat — clear the
        // transient composer feedback so a stale banner isn't waiting on return.
        .onChange(of: showingSettings) { _, shown in
            if shown {
                windowRecorder.dismissError()
                voiceRecovery = nil
            }
        }
        .onAppear { onAppear() }
        .onDisappear {
            // Window closing — stop any in-flight capture so it can't outlive the
            // UI that owns it.
            cancelWindowCapture()
        }
        .onReceive(NotificationCenter.default.publisher(for: .openConversationDeepLink)) { note in
            leaveSettingsForConversationAction()
            handleDeepLink(note)
        }
        .onReceive(NotificationCenter.default.publisher(for: .openSettingsWindow)) { _ in
            // Clear the deferred-present flag too: it's otherwise only consumed in
            // `onAppear` (the window-was-closed case), so an already-open window
            // would leave it stale. Consume any deep-link category at the same time.
            settingsInitialCategory = coordinator.pendingSettingsCategory
            settingsInitialFocus = coordinator.pendingDiagnosticsFocus
            coordinator.pendingSettingsCategory = nil
            coordinator.pendingDiagnosticsFocus = nil
            coordinator.pendingShowSettings = false
            showingSettings = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .newConversation)) { _ in
            leaveSettingsForConversationAction()
            startNewConversation()
        }
        .onReceive(NotificationCenter.default.publisher(for: .settingsDidChangeRemotely)) { _ in
            Task { await refreshConfiguredBackends() }
        }
    }

    /// An external conversation action (deep-link / New) arrived while Settings
    /// might be showing. Leave the full-window Settings mode so the user lands on
    /// the conversation — but ONLY when no buffered editor is dirty, so the action
    /// can't silently discard unsaved edits. In the dirty case Settings stays up
    /// (the conversation change still applies underneath, visible on Done).
    private func leaveSettingsForConversationAction() {
        guard showingSettings else { return }
        if !settingsVM.editorHasUnsavedChanges {
            showingSettings = false
            settingsInitialCategory = nil
            settingsInitialFocus = nil
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            // 1. Prominent New-conversation button.
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
            .padding(.horizontal, 12)
            .padding(.top, 12)

            // 2. Custom search field — BELOW New Conversation (founder rejected
            // the native `.searchable(placement:.sidebar)` position above it).
            // Shared `SidebarSearchField` (same component the iPad sidebar uses).
            SidebarSearchField(text: $sidebarSearch)
                .padding(.horizontal, 12)
                .padding(.top, 8)

            // 3. Conversation list (toolbar New/Delete suppressed; header owns New).
            ConversationListView(
                onSelect: { id in selectedConversationID = id },
                showsToolbarActions: false,
                externalSearchText: $sidebarSearch,
                customGateways: customGateways,
                showsGatewayBadge: configuredRefs.count >= 2,
                // Persistent window sidebar: highlight the active thread's row.
                selectedConversationID: selectedConversationID
            )
            .padding(.top, 8)

            Spacer(minLength: 0)

            // 5. Identity footer menu.
            identityFooter
        }
    }

    // MARK: - Gateway picker

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
                    coordinator.pendingNewConversationRef = ref
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
                            coordinator.pendingNewConversationRef = ref
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
            gatewayPillBackground(
                HStack(spacing: 4) {
                    Text(RemoteAgentRefMetadata.displayName(for: selectedRef, customs: customGateways))
                    Image(systemName: "chevron.down")
                        .font(.caption2)
                }
                .foregroundStyle(AppColors.textSecondary)
            )
        }
        .help(String(localized: LocalizedStringResource(
            "conversations.chooseGateway",
            defaultValue: "Choose gateway"
        )))
    }

    /// Centered principal-toolbar content showing the gateway identity. Always
    /// present once a gateway is configured. INTERACTIVE picker only on a NEW
    /// chat with ≥2 configured backends (a conversation is permanently bound to
    /// its gateway once it has a turn); a READ-ONLY label everywhere else —
    /// existing chat (its bound backend) or a single-gateway setup.
    @ViewBuilder
    private var gatewayToolbarContent: some View {
        if coordinator.isRemoteAgentConfigured {
            if let vm = coordinator.windowViewModel {
                // Clone is now FOLDED into the centered gateway pill: when the
                // thread is clone-eligible (bound, has turns, gateway available,
                // somewhere to switch to) the name pill itself becomes the
                // tappable "Clone & continue" control (chevron-down affordance);
                // otherwise it's a read-only identity label.
                // `hasTurns`, not `!messages.isEmpty` — a freshly minted VM has
                // no messages for a beat after a sidebar switch, which popped
                // the chevron affordance in a frame late.
                if vm.canSwitchGateway, vm.hasTurns, vm.boundGatewayAvailable {
                    Button { vm.showingGatewaySheet = true } label: {
                        gatewayPillBackground(
                            HStack(spacing: 4) {
                                Text(vm.backendDisplayName)
                                    .font(.subheadline.weight(.semibold))
                                Image(systemName: "chevron.down")
                                    .font(.caption2)
                            }
                            .foregroundStyle(AppColors.textSecondary)
                        )
                    }
                    // The clone-eligible pill is the one INTERACTIVE thing in the
                    // title bar and looks identical to the read-only label next to
                    // it — so it needs the hover wash to tell them apart. Capsule,
                    // because `gatewayPillBackground` draws one; no
                    // `horizontalPadding`, its 10pt inset is inside that pill.
                    .pointerIconButton(shape: .capsule)
                    .help(String(localized: LocalizedStringResource("conversations.switchGateway", defaultValue: "Clone & continue on another gateway")))
                    .accessibilityIdentifier("toolbar.cloneGateway")
                    .fixedSize()
                } else {
                    gatewayReadOnlyLabel(vm.backendDisplayName)
                }
            } else if configuredRefs.count >= 2 && !newChatGatewaySelectionLocked {
                gatewayPickerMenu
                    .font(.subheadline.weight(.semibold))
                    .fixedSize()
            } else {
                gatewayReadOnlyLabel(
                    RemoteAgentRefMetadata.displayName(for: selectedRef, customs: customGateways)
                )
            }
        }
    }

    /// Shared pill chrome for the title-bar gateway controls (read-only label +
    /// interactive picker) so padding + shape match across both states.
    private func gatewayPillBackground(_ content: some View) -> some View {
        content
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(AppColors.cardBackgroundElevated, in: Capsule())
            .contentShape(Capsule())
    }

    /// Read-only gateway indicator (existing chat / single gateway): the backend
    /// name in a pill, no chevron, no tap — so the title bar natively reads
    /// "info" here vs the interactive picker on a new chat.
    private func gatewayReadOnlyLabel(_ name: String) -> some View {
        gatewayPillBackground(
            Text(name)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppColors.textSecondary)
        )
        .fixedSize()
    }

    // MARK: - Identity footer

    /// Footer = a single button that opens Settings directly (no menu). The
    /// secondary links (Feedback / Privacy / Terms / About) live in Settings →
    /// About, so the old popup was redundant. Shows the real app icon, not the
    /// line-art menu-bar glyph.
    private var identityFooter: some View {
        VStack(spacing: 0) {
            Divider().overlay(AppColors.border)
            Button {
                showingSettings = true
            } label: {
                HStack(spacing: 10) {
                    Image(nsImage: highResAppIcon(size: 32))
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 32, height: 32)
                    Text(LocalizedStringResource("menu.settings.short", defaultValue: "Settings"))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AppColors.textPrimary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(AppColors.textTertiary)
                }
            }
            // The row's 12pt inset lives INSIDE its live frame, and the height
            // floor carries the rest of it (32pt icon + 12pt above and below),
            // so the wash and the click target span the footer edge to edge.
            // Padding applied from outside lands beyond the frame, where it
            // reads as a dead, unlit border.
            .settingsRowButton(minHeight: 56, horizontalPadding: 12, washCornerRadius: 0)
            .keyboardShortcut(",", modifiers: .command)
        }
        .background(AppColors.cardBackground)
    }

    // MARK: - Sidebar helpers

    /// Start a fresh conversation: clear the WINDOW lane (window returns to the
    /// greeting empty state → picker reappears) and seed the pending backend to
    /// the current picker selection so the next mint binds to it. Window-lane
    /// only — the quick-capture pointer and the popover's quick lane are not
    /// touched by this explicit window action.
    private func startNewConversation() {
        // Belt-and-braces: setting `selectedConversationID = nil` below fires the
        // onChange cancel+clear only when it was non-nil; do it explicitly so a
        // new-chat→new-chat tap also stops any capture and drops the draft.
        cancelWindowCapture()
        composerDraft = ""
        coordinator.startNewWindowConversation()
        selectedConversationID = nil
        hostMascot = MascotShuffleBag.next()  // fresh shuffle-bag pose for the new empty state
        coordinator.pendingNewConversationRef = selectedRef
        Task { await refreshConfiguredBackends() }
    }

    private func refreshConfiguredBackends() async {
        configuredRefs = await SettingsManager.shared.configuredRemoteAgentRefs()
        customGateways = await SettingsManager.shared.customGateways()
        if !newChatGatewaySelectionLocked {
            selectedRef = await SettingsManager.shared.defaultRemoteAgentRef()
        }
        // Keep the pending mint-ref in sync with the visible picker label so a
        // first typed turn binds to the gateway the user sees selected. Gated
        // on the WINDOW lane — `pendingNewConversationRef` is window-mint state.
        if coordinator.windowViewModel == nil, !newChatGatewaySelectionLocked {
            coordinator.pendingNewConversationRef = selectedRef
        }
    }

    // MARK: - Detail column (reused verbatim from ConversationsWindowView)

    // Always drives the SINGLE active VM (selecting binds it). Text + mic in the
    // composer therefore target the same conversation on screen.
    /// Shared mint-on-first-turn send path. Both composer instances (active +
    /// new-chat branch) use the SAME closure so behavior is identical.
    private func sendTypedText(_ dispatch: ComposerTurnDispatch) async -> Bool {
        await coordinator.handleTypedText(dispatch)
    }

    /// Route an STT result from the window mic — the mic-tap path (via the
    /// composer's `onVoiceResult`) AND the duration-cap auto-stop path (via
    /// `windowRecorder.onAutoStopResult`). On success the transcript POPULATES the
    /// shared `composerDraft` for review-then-send (mirrors iOS
    /// `handleTranscriptionResult`), and a successful capture clears any stale
    /// pending-retry slot — parity with the old `DictationService` window path,
    /// scoped here to macOS so iOS behavior is unchanged. On failure the recorder's
    /// own `.error` state drives the composer's banner, so there's nothing to do.
    private func handleWindowVoiceResult(_ result: Result<String, AppError>) async {
        switch result {
        case .success(let text):
            voiceRecovery = nil
            composerDraft = appendingTranscript(text, to: composerDraft)
            AccessibilityAnnouncer.announce(LocalizedStringResource(
                "voice.announce.transcriptAdded",
                defaultValue: "Transcript added"
            ))
            await PendingRetryStore.shared.clear()
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
        windowRecorder.dismissError()
        voiceRecovery = nil
        switch option {
        case .useCloud(let presetID):
            Task { await SettingsManager.shared.setActivePresetID(presetID) }
        case .openVoiceSettings:
            settingsInitialCategory = .voice
            showingSettings = true
        }
    }

    /// Shared contextual voice-recovery button — rendered above BOTH composer
    /// mounts (active + new-chat) so the macOS window matches the iOS hosts.
    @ViewBuilder
    private var voiceRecoveryRow: some View {
        if let option = voiceRecovery {
            VoiceRecoveryButton(option: option) {
                applyVoiceRecovery(option)
            }
            .padding(.horizontal, 16)
            .transition(.opacity)
        }
    }

    /// Stop any in-flight window capture on an explicit context change (thread
    /// switch / New / deep-link / window-close). State-guarded so it's a no-op
    /// when idle. iOS keeps the recorder running across a thread swap (no
    /// cross-thread risk there); the macOS window cancels so a late transcript
    /// can't land in the wrong conversation.
    private func cancelWindowCapture() {
        switch windowRecorder.state {
        case .recording: windowRecorder.cancelRecording()
        case .processing, .preparingVoice: windowRecorder.cancelProcessing()
        case .idle, .error: break
        }
    }

    /// "Type Instead" bridge binding into `coordinator.pendingComposerImage` (the
    /// ⌘⇧2 Screenshot & Ask → typed-composer seam, mirroring `pendingShowSettings`).
    /// Passed to the mounted `MessageComposerBar`, which drains it into staging
    /// for review on appear / on change, then writes nil back through this binding.
    /// The `.openConversationsWindow` post (fired by `typeInsteadFromCapture`)
    /// brings the window forward so the composer is mounted to drain it.
    private var composerImageBridge: Binding<Data?> {
        Binding(
            get: { coordinator.pendingComposerImage },
            set: { coordinator.pendingComposerImage = $0 }
        )
    }

    @ViewBuilder
    private var detailColumn: some View {
        Group {
            if !coordinator.isRemoteAgentConfigured {
                // No composer mounts here, so a "Type Instead" screenshot parked on
                // the bridge has nowhere to drain — discard it rather than let it
                // strand and surface in a future unrelated composer.
                unconfiguredEmptyState
                    .onAppear { coordinator.pendingComposerImage = nil }
            } else if let vm = coordinator.windowViewModel {
                activeChat(vm: vm)
            } else {
                newChat
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Edge-to-edge conversation surface (no floating card). The flat
        // cardBackground reads distinct from the gradient sidebar and runs the
        // full height/width of the detail pane.
        .background(AppColors.cardBackground)
    }

    /// ACTIVE thread: messages fill, composer pinned to the bottom.
    private func activeChat(vm: ConversationDetailViewModel) -> some View {
        VStack(spacing: 0) {
            // Thread fills the pane width (scrollbar at the window edge); its
            // message column is capped + centered internally via contentMaxWidth.
            ConversationThreadView(viewModel: vm, settingsVM: settingsVM, contentMaxWidth: Constants.Layout.chatContentWidth, emptyMascot: hostMascot)
                // INSIDE the `.id` boundary so a sidebar switch tears the
                // reporter down/re-mounts it with the thread (clean
                // appear/disappear per conversation, no onChange plumbing).
                .modifier(WindowThreadVisibilityReporter(
                    coordinator: coordinator,
                    conversationID: vm.conversationID
                ))
                .id(vm.conversationID)
                .frame(maxHeight: .infinity)
            // Contextual voice hard-failure recovery — above the composer (whose
            // inline `.error` banner names the failure). One user-tapped button.
            voiceRecoveryRow
                .frame(maxWidth: Constants.Layout.chatContentWidth)
                .frame(maxWidth: .infinity)
            // Composer caps itself to the same readable column, centered.
            MessageComposerBar(
                viewModel: vm,
                onSendText: sendTypedText,
                recorder: windowRecorder,
                draft: $composerDraft,
                onVoiceResult: handleWindowVoiceResult,
                settingsVM: settingsVM,
                selectedRef: selectedRef,
                pendingStagedImage: composerImageBridge
            )
            // Attachment staging is view-local @State. Give each active
            // conversation its own mount so A → B runs A's onDisappear/deferred
            // teardown instead of carrying A's tiles into B.
            .id(ComposerMountIdentity.conversation(vm.conversationID))
            .frame(maxWidth: Constants.Layout.chatContentWidth)
            .frame(maxWidth: .infinity)
        }
    }

    /// NEW CHAT: gateway capsule on top (new-chat only), mascot + composer
    /// centered as one group (no big void) via the bracketing `Spacer`s.
    @ViewBuilder
    private var newChat: some View {
        // GeometryReader at this level reads the ACTUAL available window height
        // (not a fixed inner frame), so the mascot can shrink when the window is
        // short. The proxy is read here and the resolved height passed down — a
        // GeometryReader inside `newChatEmptyState` would only ever see its own
        // fixed frame, making the compact branch dead code.
        GeometryReader { proxy in
            let mascotHeight: CGFloat = proxy.size.height < 360 ? 120 : 160
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                VStack(spacing: 20) {
                    newChatEmptyState(mascotHeight: mascotHeight)
                    VStack(spacing: 8) {
                        voiceRecoveryRow
                        MessageComposerBar(
                            viewModel: nil,
                            onSendText: sendTypedText,
                            recorder: windowRecorder,
                            draft: $composerDraft,
                            onVoiceResult: handleWindowVoiceResult,
                            settingsVM: settingsVM,
                            selectedRef: selectedRef,
                            newChatGatewaySelectionLocked: $newChatGatewaySelectionLocked,
                            pendingStagedImage: composerImageBridge
                        )
                        // Keep the VM-less minting composer explicitly distinct
                        // from every established-conversation mount.
                        .id(ComposerMountIdentity.newChat)
                    }
                }
                .frame(maxWidth: Constants.Layout.chatContentWidth)
                .frame(maxWidth: .infinity)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Selection sync (copied verbatim)

    private func onAppear() {
        // Route a duration-cap auto-stop (300 s) through the SAME success handler
        // as a mic-tap stop — a capped recording must POPULATE the field, not
        // vanish (Part 1e parity with iOS). Idempotent re-assignment is safe.
        windowRecorder.onAutoStopResult = { result in
            Task { await handleWindowVoiceResult(result) }
        }
        // Off-screen drift guard: re-center if the restored frame isn't inside
        // any visible screen.
        recenterIfOffscreen()

        // Open on the live thread: prefer the window's own lane (reopen lands
        // where the user left off), else fall back to the QUICK lane — first
        // open shows the hotkey conversation (continuity from popover to
        // window), and it also covers the "Open window…" hand-off race where
        // the deep-link bound the window lane before this view existed.
        if selectedConversationID == nil {
            selectedConversationID = coordinator.windowViewModel?.conversationID
                ?? coordinator.quickViewModel?.conversationID
        }
        if let id = selectedConversationID { coordinator.openConversation(id) }
        // Deferred settings present (menu-bar "Settings…" opened the window).
        if coordinator.pendingShowSettings {
            settingsInitialCategory = coordinator.pendingSettingsCategory
            settingsInitialFocus = coordinator.pendingDiagnosticsFocus
            coordinator.pendingSettingsCategory = nil
            coordinator.pendingDiagnosticsFocus = nil
            coordinator.pendingShowSettings = false
            showingSettings = true
        }
        // Seed the gateway-picker list + selection.
        Task { await refreshConfiguredBackends() }
        // Warm the Apple on-device model state so the pre-mic gate has a
        // ready cache (no hot-path latency). Cheap no-op for a cloud STT; the
        // gate re-checks the active provider itself before presenting anything.
        Task { await settingsVM.checkAppleModelStatus() }
    }

    private func handleDeepLink(_ note: Notification) {
        guard let idString = note.userInfo?[NotificationDeepLink.conversationIDKey] as? String,
              let id = UUID(uuidString: idString) else { return }
        coordinator.openConversation(id)
        selectedConversationID = id
    }

    /// If the key window's frame doesn't intersect any screen's visible frame
    /// (e.g. a disconnected external display), re-center it on the main screen.
    private func recenterIfOffscreen() {
        DispatchQueue.main.async {
            guard let window = NSApp.keyWindow ?? NSApp.windows.first(where: { $0.isVisible }) else { return }
            let frame = window.frame
            let onScreen = NSScreen.screens.contains { $0.visibleFrame.intersects(frame) }
            if !onScreen { window.center() }
        }
    }

    // MARK: - Empty states

    private var unconfiguredEmptyState: some View {
        UnconfiguredEmptyState(mascot: hostMascot, mascotHeight: 140) {
            // Deep-link straight into guided setup. Open Settings on Personal AI
            // too (so the primer's "Set up manually" has the list to land on),
            // then present the overlay — same view owns `guidedHost`, no latch.
            settingsInitialCategory = .personalAI
            showingSettings = true
            guidedHost.present()
        }
    }

    /// New-chat empty state — mirrors the iOS `ConversationThreadView.emptyThreadHint`
    /// (mascot + the same "Type a message or tap the mic." hint). Shown when the
    /// composer is mounted but no conversation is active yet.
    private func newChatEmptyState(mascotHeight: CGFloat) -> some View {
        VStack(spacing: 16) {
            EmptyStateMascot(pose: hostMascot, height: mascotHeight)
            Text("Type a message or tap the mic.")  // xcstrings: composer
                .font(.callout)
                .foregroundStyle(AppColors.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity)
    }
}

/// Feeds `MenuBarCoordinator.windowVisibleConversationID` — the "user is
/// looking at this thread in the main window" pin that suppresses AND clears
/// the menu-bar dots (yellow unread / red failure) for the visible thread.
/// `\.appearsActive` gates every report: a thread mounted in a
/// backgrounded/miniaturized window reports nothing, so a reply landing there
/// still raises the dot — the cue exists precisely for replies the user isn't
/// watching. Deactivation drops the pin (guarded `ifCurrent:`); re-activation
/// re-reports, which clears any dot that arrival raised while the user was
/// away (they're now looking at the reply).
private struct WindowThreadVisibilityReporter: ViewModifier {
    let coordinator: MenuBarCoordinator
    let conversationID: UUID
    @Environment(\.appearsActive) private var appearsActive

    func body(content: Content) -> some View {
        content
            .onAppear {
                // Inactive at mount → no-op (never report nil here: the OLD
                // thread's guarded `.onDisappear` clear owns that hand-off).
                if appearsActive {
                    coordinator.setWindowVisibleConversation(conversationID)
                }
            }
            .onChange(of: appearsActive) { _, isActive in
                if isActive {
                    coordinator.setWindowVisibleConversation(conversationID)
                } else {
                    coordinator.clearWindowVisibleConversation(ifCurrent: conversationID)
                }
            }
            .onDisappear {
                coordinator.clearWindowVisibleConversation(ifCurrent: conversationID)
            }
    }
}
#endif
