//
//  ContentView.swift
//  Conduck
//
//  The iOS home IS the conversation thread (entry 2). Backed by
//  the persistent `ConversationStore` via `ConversationDetailViewModel` over
//  the active/visible conversation. The transient `TransientMessageRecord`
//  stub is removed; rows are persistent `MessageRecord` snapshots.
//
//  In-flight UX (the priority polish):
//    - optimistic user bubble inserted the instant STT completes
//    - borderless "{Backend} is answering…" indicator + subtle elapsed timer
//      (TimelineView) that appears after ~3s
//    - cancellation via the composer's neutral Stop morph (no inline Cancel)
//    - smart scroll: auto-scroll only when pinned to the bottom, else a
//      floating "↓ New reply below" badge that snaps to bottom on tap
//
//  In-app mic (entry 2): `InAppAudioRecorder` capture → on STT success, the
//  user turn is appended to the VISIBLE conversation (bypassing the headless
//  TTL pointer) and the converse hop fires on the background session.
//
//  Notification deep-link: a reply notification tap foregrounds the app and
//  opens the target conversation thread (local fetch by conversationID).
//
//  Pending-retry surface: `PendingRetryCard` lives above the thread.
//

import SwiftUI
import UserNotifications
import AVFoundation
import PhotosUI
import UniformTypeIdentifiers
#if canImport(UIKit)
import UIKit
#endif

// MARK: - ContentView (conversation thread shell)

struct ContentView: View {
    @State private var currentConversationID: UUID?
    /// The detail VM bound to the visible conversation. Owned here so the mic
    /// footer and the on-screen thread share ONE in-flight state machine
    /// (otherwise the thinking indicator + Cancel wouldn't reflect the turn
    /// the mic just fired). Recreated whenever `currentConversationID` changes.
    @State private var detailVM: ConversationDetailViewModel?
    @State private var hasPendingRetry: Bool = false
    /// The `AppError.errorCode` that armed the pending retry, mirrored from the
    /// store alongside `hasPendingRetry` so the retry card's Troubleshoot
    /// affordance can build its `DiagnosticsFocus`. nil = no code (a plain notice
    /// or nothing pending) → no button.
    @State private var pendingRetryErrorCode: Int? = nil

    /// True when minting the first conversation failed at send time (rare
    /// Core Data write error) — drives the explanatory alert; the draft text
    /// is restored by `sendTurn` before this flips.
    @State private var showSendFailedAlert = false
    @State private var isRetrying: Bool = false
    @State private var retryErrorMessage: String? = nil
    @State private var recorder = InAppAudioRecorder()
    @State private var composerDraft: String = ""
    /// Contextual recovery offered after a GENUINE voice hard failure (language
    /// unsupported on-device / model self-heal couldn't complete). nil = no
    /// recovery on screen. The missing-model case no longer reaches here — it
    /// self-heals upstream in `InAppAudioRecorder` — so this is the user-tapped
    /// forward path for the residual hard failures (never an automatic teleport).
    @State private var voiceRecovery: VoiceRecoveryOption? = nil
    #if os(iOS)
    /// Shared attachment staging for the iPhone composer (pickers + camera +
    /// the staged collection). iPad uses its own instance in the library view.
    @State private var attachmentCoordinator = ComposerAttachmentCoordinator()
    #endif
    /// STABLE Settings VM owned for the host's lifetime — reused by the Settings
    /// sheet AND the composer's file-transfer setup sheet, so a sheet open doesn't
    /// re-trigger a full settings load + leak an un-retained observer each time.
    @State private var settingsVM = SettingsViewModel()
    /// Single source of truth for the iOS Settings presentation: when non-nil the
    /// sheet (iPhone) / full-screen cover (iPad) is open, on the optional category.
    /// Driven via `.sheet(item:)` / `.fullScreenCover(item:)` so the category is
    /// delivered to the destination AT PRESENT TIME.
    ///
    /// Was a `showingSettings: Bool` + `settingsInitialCategory` pair, which RACED:
    /// setting both in one tick, `.sheet(isPresented:)` read the category from the
    /// pre-update view snapshot, so the FIRST open after launch ignored the
    /// deep-link and landed on the root list (it only honored the category on the
    /// SECOND open, once the body had re-rendered). `item`-based presentation
    /// passes the value at present time, removing the race. iOS-only: `SettingsView`
    /// (and its `.Category`) is `#if os(iOS)`; macOS uses `MainWindowView`.
    #if os(iOS)
    struct SettingsRoute: Identifiable {
        let id = UUID()
        let category: SettingsView.Category?
        /// When true, the Settings container auto-opens the guided-setup cover on
        /// appear (once state has hydrated + only if unconfigured) — the "Connect
        /// Personal AI" empty-state/locked-composer deep-link. Ordinary Settings
        /// deep-links leave this false.
        var autoOpenGuidedSetup: Bool = false
    }
    @State private var settingsRoute: SettingsRoute? = nil
    #endif
    @State private var showingList: Bool = false
    /// Set by the conversation-list's bottom "Settings" row: the list sheet
    /// dismisses first, then its `onDismiss` presents Settings (two sheets can't
    /// be stacked from one presenter, so defer rather than open inline).
    @State private var pendingShowSettingsFromList = false
    @State private var isRemoteAgentConfigured: Bool = false
    /// Host-state empty-mascot pose. Drawn once at `@State` creation (NOT in
    /// `.onAppear`, which SwiftUI re-fires) so it stays stable while typing /
    /// on navigation re-appear. This is a host view with no conversation VM.
    @State private var hostMascot = MascotShuffleBag.next()
    /// The nav-title display name: the visible conversation's bound backend
    /// (per-conversation routing), or the default backend in the empty/new
    /// state. Non-reactive snapshot read — refreshed at the same hooks as
    /// `isRemoteAgentConfigured` (launch / scenePhase / settings dismiss /
    /// `.settingsDidChangeRemotely`) PLUS on a thread switch
    /// (`onChange(of: currentConversationID)`).
    /// Nav-title snapshot: the RESPONDING gateway's display name once one is
    /// configured. With no gateway at all there is no responder to name, so it
    /// falls back to the app name — "Personal AI" here was a placeholder backend
    /// name wearing a title's clothes, and it made the unconfigured screen say
    /// the same six words four times over.
    @State private var backendTitle: String = String(localized: LocalizedStringResource(
        "chat.title.unconfigured",
        defaultValue: "Conduck"
    ))
    /// Session-local (NOT persisted) gateway-picker selection for the NEXT new
    /// conversation. The persisted preference is the Settings *default*;
    /// this is purely the title-dropdown's transient choice. Seeded from the
    /// default whenever we enter an empty/new state; the picker then drives it,
    /// and `sendTurn`'s mint reads it. Falls back harmlessly to the default
    /// backend before the first seed.
    @State private var pickerSelectedRef: RemoteAgentRef = .builtin(Constants.remoteAgentDefaultBackendDefault)
    /// The fully-configured gateway refs (token + url): built-ins first, then
    /// customs. The gateway picker renders IFF this has ≥2 entries AND the
    /// conversation is new/empty (`currentConversationID == nil`). Refreshed
    /// alongside `isRemoteAgentConfigured` / `backendTitle`.
    @State private var configuredRefs: [RemoteAgentRef] = []
    /// Cached custom roster, for resolving picker/ title labels without an
    /// actor hop inside `body`. Refreshed alongside `configuredRefs`.
    @State private var customGateways: [CustomGateway] = []
    @State private var didResolveInitialConversation = false
    /// True once the FIRST `refreshConfiguredFlag` has run. Gates the
    /// "synced from your other device" banner so it never fires on the launch
    /// load (an already-configured gateway is not a sync event) — only a later
    /// empty → non-empty transition (the skip-then-sync-arrives path) does.
    @State private var didCompleteInitialConfiguredLoad = false
    /// Drives the transient "synced from your other device" banner.
    @State private var showSyncedBanner = false
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        #if os(iOS)
        if horizontalSizeClass == .regular {
            // iPad — split layout as the root content.
            ConversationLibraryView(
                selectedConversationID: $currentConversationID,
                recorder: recorder,
                onSendTurn: { text, modality, attachments in
                    await sendTurn(text, modality: modality, attachments: attachments)
                },
                isRemoteAgentConfigured: isRemoteAgentConfigured,
                backendTitle: backendTitle,
                configuredRefs: configuredRefs,
                customGateways: customGateways,
                selectedRef: $pickerSelectedRef,
                canPickBackend: canPickBackend,
                onPickBackend: { Task { await refreshBackendTitle() } },
                onOpenSettings: { category in
                    settingsRoute = SettingsRoute(category: category)
                },
                onOpenGuidedSetup: { openGuidedSetupFromEmptyState() },
                settingsVM: settingsVM
            )
            // iPad — full-screen two-column Settings (sidebar + detail) instead
            // of the accidental centered form sheet `.sheet` renders at the
            // regular size class. `.fullScreenCover` has no swipe-to-dismiss, so
            // the only exit is Done, which routes through IpadSettingsView's
            // dirty-editor discard guard (no `interactiveDismissDisabled` needed).
            .fullScreenCover(item: $settingsRoute, onDismiss: {
                Task { await handleSettingsDismiss() }
            }) { route in
                IpadSettingsView(
                    viewModel: settingsVM,
                    initialCategory: route.category,
                    autoOpenGuidedSetup: route.autoOpenGuidedSetup,
                    onDone: { settingsRoute = nil }
                )
                .id(route.id)   // fresh auto-open latch per presentation
            }
            .task { await initialLoad() }
            .onChange(of: scenePhase) { _, newPhase in
                if newPhase == .active { Task { await refreshOnForeground() } }
            }
            .onChange(of: currentConversationID) { _, _ in
                composerDraft = ""   // don't carry a half-typed draft into another thread
                clearComposerFeedback()   // stale voice error/recovery shouldn't follow a thread switch
                syncDetailVM()
                // Refresh the nav title to the newly-selected thread's bound
                // backend (per-conversation routing) — else it stays stale when
                // switching between threads on different gateways.
                Task { await refreshBackendTitle() }
            }
            // iPad settings is a full-window cover — presenting it leaves the chat,
            // so clear the transient composer feedback before the cover dismisses.
            // (Bool watcher: SettingsRoute isn't Equatable.)
            .onChange(of: settingsRoute != nil) { _, presented in
                if presented { clearComposerFeedback() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .openConversationDeepLink)) { note in
                handleDeepLink(note)
            }
            .onReceive(NotificationCenter.default.publisher(for: .settingsDidChangeRemotely)) { _ in
                Task { await refreshConfiguredFlag() }
            }
        } else {
            phoneLayout
        }
        #else
        phoneLayout
        #endif
    }

    // MARK: - Gateway picker (title dropdown)

    /// Render the gateway picker IFF ≥2 backends are configured AND the
    /// conversation is new/empty (before the first turn). This UI gate is what
    /// enforces "locked once the thread starts" — after a send mints the
    /// conversation, `currentConversationID` is non-nil and the picker falls
    /// away to a static title.
    private var canPickBackend: Bool {
        configuredRefs.count >= 2 && currentConversationID == nil
    }

    /// The principal-placement gateway `Menu` shared by the iPhone toolbar. Label
    /// is the selected ref's name + a chevron; content lists the configured
    /// refs with a checkmark on the active one. Self-hosted gateways render first;
    /// hosted-model services (OpenRouter) appear in a labelled "Hosted" section below.
    /// Picking updates the session-local selection and refreshes the title preview.
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
                    pickerSelectedRef = ref
                    Task { await refreshBackendTitle() }
                } label: {
                    if ref == pickerSelectedRef {
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
                            pickerSelectedRef = ref
                            Task { await refreshBackendTitle() }
                        } label: {
                            if ref == pickerSelectedRef {
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
                Text(RemoteAgentRefMetadata.displayName(for: pickerSelectedRef, customs: customGateways))
                    .font(.headline)
                    .foregroundStyle(AppColors.textPrimary)
                Image(systemName: "chevron.down")
                    .font(.caption2)
                    .foregroundStyle(AppColors.textSecondary)
            }
        }
        .accessibilityLabel("Choose gateway")  // xcstrings: chat-ui
        .accessibilityIdentifier("toolbar.gatewayPicker")  // stable QA target (non-localized)
    }

    /// The centered principal-toolbar control. Three-way: the gateway picker
    /// when a new/empty chat with ≥2 backends can pick; else a tappable title
    /// that folds in "Clone & continue" when the bound thread is clone-eligible
    /// (has turns, gateway available, somewhere to switch to); else a plain
    /// static title.
    @ViewBuilder
    private var gatewayTitleControl: some View {
        if canPickBackend {
            gatewayPickerMenu
        } else if let vm = detailVM, vm.canSwitchGateway, !vm.messages.isEmpty, vm.boundGatewayAvailable {
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

    // MARK: - iPhone layout

    private var phoneLayout: some View {
        NavigationStack {
            ZStack {
                backgroundGradient.ignoresSafeArea()

                VStack(spacing: 0) {
                    if hasPendingRetry {
                        PendingRetryCard(
                            isRetrying: isRetrying,
                            retryErrorMessage: retryErrorMessage,
                            onRetry: retryButtonTapped,
                            troubleshootFocus: DiagnosticsFocus(errorCode: pendingRetryErrorCode, ref: nil)
                        )
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }

                    if showSyncedBanner {
                        syncedBanner
                            .padding(.horizontal, 16)
                            .padding(.top, 12)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }

                    threadContent
                }
            }
            #if os(iOS)
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 0) {
                    if !isRemoteAgentConfigured {
                        // No gateway yet → the composer is a gated CTA, not a live
                        // field that errors on send. Deep-links straight into guided
                        // setup (same as the unconfigured empty-state hero).
                        LockedComposerBar {
                            openGuidedSetupFromEmptyState()
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
                            onSend: { text, attachments in
                                await sendTurn(text, modality: .text, attachments: attachments)
                            },
                            onVoiceResult: handleTranscriptionResult,
                            settingsVM: settingsVM,
                            pendingNewConversationRef: pickerSelectedRef
                        )
                    }
                }
            }
            #endif
            .alert(
                Text(String(localized: LocalizedStringResource(
                    "send.error.mintFailed.title",
                    defaultValue: "Couldn't start the conversation"
                ))),  // xcstrings: hardening
                isPresented: $showSendFailedAlert
            ) {
                Button(String(localized: LocalizedStringResource(
                    "send.error.mintFailed.ok",
                    defaultValue: "OK"
                )), role: .cancel) {}  // xcstrings: hardening
            } message: {
                Text(String(localized: LocalizedStringResource(
                    "send.error.mintFailed.message",
                    defaultValue: "Your message is back in the composer — try sending again."
                )))  // xcstrings: hardening
            }
            // The principal toolbar item below always owns the centered title
            // control (`gatewayTitleControl`: picker / clone-tappable title /
            // static title), so the nav title stays empty to avoid double-titling.
            .navigationTitle(Text(""))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    gatewayTitleControl
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showingList = true
                    } label: {
                        Image(systemName: "bubble.left.and.bubble.right")
                    }
                    .accessibilityLabel("Conversations")  // xcstrings
                    .accessibilityIdentifier("toolbar.conversations")  // stable QA target (non-localized)
                }
                // New conversation. Settings moved to the conversation-list
                // footer row (Clone folded into the centered gateway title), so
                // this is the only trailing action.
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        startNewConversation()
                    } label: {
                        Image(systemName: "square.and.pencil")
                    }
                    .accessibilityLabel("New conversation")  // xcstrings: chat-ui
                    .accessibilityIdentifier("toolbar.newConversation")  // stable QA target (non-localized)
                }
            }
            .sheet(item: $settingsRoute, onDismiss: {
                Task { await handleSettingsDismiss() }
            }) { route in
                SettingsView(
                    viewModel: settingsVM,
                    initialCategory: route.category,
                    autoOpenGuidedSetup: route.autoOpenGuidedSetup
                )
                    // Force fresh `@State` (incl. the auto-open consume latch) per
                    // presentation — item-identity change doesn't contractually
                    // rebuild destination state, so pin it explicitly.
                    .id(route.id)
                    // Block swipe-to-dismiss while a buffered editor (gateway /
                    // custom voice endpoint) has unsaved edits — otherwise a
                    // swipe-down tears the pushed editor down and silently
                    // discards. The editor's Cancel/Save remain the exits.
                    .interactiveDismissDisabled(settingsVM.editorHasUnsavedChanges)
            }
            .sheet(isPresented: $showingList, onDismiss: {
                if pendingShowSettingsFromList {
                    pendingShowSettingsFromList = false
                    settingsRoute = SettingsRoute(category: nil)
                }
            }) {
                NavigationStack {
                    ConversationListView(
                        onSelect: { id in
                            currentConversationID = id
                            showingList = false
                        },
                        onNewConversation: {
                            showingList = false
                            startNewConversation()
                        },
                        customGateways: customGateways,
                        showsGatewayBadge: configuredRefs.count >= 2,
                        onOpenSettings: {
                            showingList = false
                            pendingShowSettingsFromList = true
                        },
                        settingsInToolbar: true
                    )
                }
            }
            #endif
            .task { await initialLoad() }
            .onChange(of: scenePhase) { _, newPhase in
                if newPhase == .active { Task { await refreshOnForeground() } }
            }
            .onChange(of: currentConversationID) { _, _ in
                composerDraft = ""   // don't carry a half-typed draft into another thread
                clearComposerFeedback()   // stale voice error/recovery shouldn't follow a thread switch
                syncDetailVM()
                // Refresh the nav title to the newly-selected thread's bound
                // backend (per-conversation routing) — else it stays stale when
                // switching between threads on different gateways.
                Task { await refreshBackendTitle() }
            }
            // Leaving the chat for the list / settings sheet clears the transient
            // composer feedback ON PRESENTATION, so the banner is already gone when
            // the composer is revealed again (no slide-away flash). One combined
            // Bool watcher (SettingsRoute isn't Equatable; this also keeps the big
            // body's type-check cost down vs. two separate modifiers).
            .onChange(of: showingList || isSettingsPresented) { _, leaving in
                if leaving { clearComposerFeedback() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .openConversationDeepLink)) { note in
                handleDeepLink(note)
            }
            .onReceive(NotificationCenter.default.publisher(for: .settingsDidChangeRemotely)) { _ in
                Task { await refreshConfiguredFlag() }
            }
            #if os(iOS)
            .onChange(of: detailVM?.isAwaitingReply) { old, new in
                handleInFlightHaptic(from: old, to: new)
            }
            #endif
        }
    }

    #if os(iOS)
    /// The conversation the haptic observer last saw, so a thread SWITCH (which
    /// swaps `detailVM` and thus changes the observed `isAwaitingReply`) can be
    /// told apart from a genuine send/receive on the current thread.
    @State private var lastHapticConversationID: UUID?

    /// Send/receive haptics keyed off the in-flight transition: a light impact
    /// when a turn is committed (false→true) and a success notification when the
    /// reply lands (true→false). `old`/`new` are optionals because `detailVM` is
    /// nil before the first conversation is minted.
    private func handleInFlightHaptic(from old: Bool?, to new: Bool?) {
        // A coinciding conversation switch = VM swap, not a real transition —
        // resync and skip so it doesn't fire a stray buzz. (nil → first-minted
        // id is NOT a switch, so the first send of a new thread still buzzes.)
        if let prev = lastHapticConversationID, prev != currentConversationID {
            lastHapticConversationID = currentConversationID
            return
        }
        lastHapticConversationID = currentConversationID
        if old != true, new == true {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        } else if old == true, new == false {
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        }
    }
    #endif

    /// Clear the transient above-composer feedback (the inline voice-error banner
    /// driven by `recorder.state == .error`, plus the `voiceRecovery` action row).
    /// `dismissError()` is a no-op unless the recorder is in `.error`, so this is
    /// safe to call on any navigation-away event. Called when the user leaves the
    /// chat (switches thread, opens the list, opens settings) so a stale banner
    /// doesn't survive the round trip.
    private func clearComposerFeedback() {
        recorder.dismissError()
        voiceRecovery = nil
    }

    /// Whether an in-app settings surface is presented. `settingsRoute` is
    /// iOS-only (macOS routes settings through `MainWindowView`'s own window), so
    /// this abstracts it to keep the shared `clearComposerFeedback` watcher
    /// compiling on both platforms.
    private var isSettingsPresented: Bool {
        #if os(iOS)
        settingsRoute != nil
        #else
        false
        #endif
    }

    /// Start a fresh conversation: clear the active selection so the start
    /// empty state shows; the next send mints a fresh conversation via the
    /// existing implicit path in `sendTurn`. Mirrors the iPad library's
    /// `ConversationLibraryView.startNewConversation()`. The
    /// `onChange(of: currentConversationID)` hook clears the draft + resets the
    /// detail VM (`syncDetailVM` → nil).
    private func startNewConversation() {
        composerDraft = ""
        currentConversationID = nil
        hostMascot = MascotShuffleBag.next()  // fresh shuffle-bag pose for the new empty state
        // Re-seed the gateway picker from the persisted default + refresh the
        // configured list so the dropdown reappears (when ≥2 are configured)
        // with the default pre-selected for this fresh conversation.
        Task {
            configuredRefs = await SettingsManager.shared.configuredRemoteAgentRefs()
            customGateways = await SettingsManager.shared.customGateways()
            pickerSelectedRef = await SettingsManager.shared.defaultRemoteAgentRef()
            await refreshBackendTitle()
        }
    }

    /// Rebuild the shared detail VM when the visible conversation changes.
    private func syncDetailVM() {
        if let id = currentConversationID {
            if detailVM?.conversationID != id {
                detailVM = ConversationDetailViewModel(conversationID: id)
            }
        } else {
            detailVM = nil
        }
    }

    // MARK: - Thread content

    @ViewBuilder
    private var threadContent: some View {
        if !isRemoteAgentConfigured {
            unconfiguredEmptyState
        } else if let vm = detailVM {
            ConversationThreadView(viewModel: vm, emptyMascot: hostMascot)
                .id(vm.conversationID)
        } else {
            startEmptyState
        }
    }

    private var unconfiguredEmptyState: some View {
        UnconfiguredEmptyState(mascot: hostMascot) {
            #if os(iOS)
            openGuidedSetupFromEmptyState()
            #endif
        }
    }

    #if os(iOS)
    /// Deep-link the unconfigured empty-state / locked-composer CTA STRAIGHT into
    /// guided setup: present Settings on Personal AI + arm the auto-open latch, so
    /// the user lands on the primer without hunting for the "Guided Setup" row. The
    /// `settingsRoute == nil` guard drops a rapid double-tap (a 2nd tap would mint a
    /// fresh route UUID mid-presentation and confuse the latch).
    private func openGuidedSetupFromEmptyState() {
        guard settingsRoute == nil else { return }
        settingsRoute = SettingsRoute(category: .personalAI, autoOpenGuidedSetup: true)
    }
    #endif

    private var startEmptyState: some View {
        VStack(spacing: 16) {
            EmptyStateMascot(pose: hostMascot, height: 150)
            Text("Type a message or tap the mic.")  // xcstrings: composer
                .font(.callout)
                .foregroundStyle(AppColors.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var backgroundGradient: some View {
        LinearGradient(
            colors: [AppColors.gradientStart, AppColors.gradientEnd],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    /// Transient confirmation that a gateway just arrived via iCloud sync — the
    /// "set up later on this device, then it synced over from your Mac" path.
    /// Auto-dismisses; rendered inline atop `phoneLayout` (iOS compact + macOS).
    /// Cross-platform (NOT inside the iOS-only block above).
    private var syncedBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.icloud")
                .font(.title3)
                .foregroundStyle(AppColors.brandAmber)
            Text("Synced from your other device")  // xcstrings: cross-device-sync
                .font(.subheadline.weight(.medium))
                .foregroundStyle(AppColors.textPrimary)
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.ultraThinMaterial)
        )
    }

    /// Show the synced banner, then auto-dismiss after ~3s. Idempotent enough:
    /// a second sync event just restarts the visible window.
    private func presentSyncedBanner() {
        withAnimation { showSyncedBanner = true }
        Task {
            try? await Task.sleep(for: .seconds(3))
            await MainActor.run { withAnimation { showSyncedBanner = false } }
        }
    }

    // MARK: - Lifecycle

    private func initialLoad() async {
        // Route a duration-cap auto-stop through the SAME success handler as a
        // mic-tap stop (Part 1e): a capped recording must POPULATE the field, not
        // vanish. Idempotent — re-assigning the closure on every `.task` is safe.
        recorder.onAutoStopResult = { result in
            Task { await handleTranscriptionResult(result) }
        }
        await refreshConfiguredFlag()
        await refreshPendingRetryState()
        // Proactively hydrate the Apple on-device model state so the pre-mic
        // gate has a warm cache (no hot-path latency on the first mic tap). Cheap
        // no-op when the active STT is a cloud provider; the gate re-checks the
        // active provider itself before presenting anything.
        await settingsVM.checkAppleModelStatus()
        #if !os(watchOS)
        // Cold-launch top-up: ensure the Standard on-device model is installed
        // before any headless trigger (Shortcut / CarPlay / Watch relay) fires.
        // Self-gates on Apple active + Speech Recognition authorized; a no-op when
        // the model is already on disk.
        await AppleSpeechPreparer.prepareStandardIfAuthorized()
        #endif
        guard !didResolveInitialConversation else { return }
        didResolveInitialConversation = true
        if currentConversationID == nil {
            currentConversationID = await resolveInitialConversationID()
        }
        syncDetailVM()
    }

    private func refreshOnForeground() async {
        await refreshConfiguredFlag()
        await refreshPendingRetryState()
        // Share Extension drain hook. On every foreground, drain any envelopes
        // the share extension queued into the App-Group inbox — claim, classify,
        // (upload), append, assemble, dispatch. The actor serializes concurrent
        // drains (this + a notification tap firing near-simultaneously); an empty
        // inbox is a cheap no-op.
        await SharedInboxDrainer.shared.drain()
        // Silent foreground catch-up. Re-read the local store into the on-screen
        // list + open thread (covers a CloudKit import that landed while the app
        // was suspended and whose remote-change post fired before/without a live
        // observer), and re-check iCloud account/event health. The dedicated
        // `.conversationsNeedLocalRefresh` (NOT `.conversationsDidChange`) skips the
        // heavier share-target/menu-bar/CarPlay side effects on every foreground.
        NotificationCenter.default.post(name: .conversationsNeedLocalRefresh, object: nil)
        await CloudSyncMonitor.shared.refresh()
        #if !os(watchOS)
        // Foreground top-up: re-warm the Standard on-device model if it got
        // evicted under disk pressure, so a headless trigger after a long
        // background isn't a cold race. Self-gates + no-ops when already installed.
        await AppleSpeechPreparer.prepareStandardIfAuthorized()
        #endif
    }

    /// Re-evaluate configured state after the Settings sheet closes. Dismissing
    /// a sheet is NOT a scenePhase transition, so `refreshOnForeground` never
    /// fires — without this the home screen stays on the unconfigured empty
    /// state (and conversation-row taps appear to do nothing) right after the
    /// user adds a gateway. The post-dismiss `resolveInitialConversationID()`
    /// honors `OnLaunchMode` — under `.startNewConversation` it returns nil
    /// even if conversations exist, which is the intended landing.
    private func handleSettingsDismiss() async {
        // Belt-and-braces: the sheet is gone, so no editor is open — clear the
        // flag so a stale `true` can't keep the next presentation's swipe blocked.
        settingsVM.editorHasUnsavedChanges = false
        await refreshConfiguredFlag()
        await refreshPendingRetryState()
        if currentConversationID == nil {
            currentConversationID = await resolveInitialConversationID()
            syncDetailVM()
        }
    }

    /// Refresh the pending-retry card's presence AND its arming error code
    /// together, so the card and its Troubleshoot affordance stay in sync across
    /// every lifecycle / foreground / dictation-result path. Both are cheap
    /// metadata-only reads (no audio load).
    private func refreshPendingRetryState() async {
        hasPendingRetry = await PendingRetryStore.shared.hasPending()
        pendingRetryErrorCode = await PendingRetryStore.shared.pendingErrorCode()
    }

    private func refreshConfiguredFlag() async {
        let hadConfiguredGateway = !configuredRefs.isEmpty
        configuredRefs = await SettingsManager.shared.configuredRemoteAgentRefs()
        // Strict configured flag: a usable gateway needs a URL AND (for `.bearer`)
        // a token — never URL alone. The old `remoteAgentSnapshot() != nil` was
        // URL-gated and could read "ready" with no key, showing the composer when
        // a send would fail closed. Align with the strict predicate used
        // everywhere else (`configuredRemoteAgentRefs()`).
        isRemoteAgentConfigured = !configuredRefs.isEmpty
        customGateways = await SettingsManager.shared.customGateways()

        // Cross-device "set up later, then it synced" path: a gateway just
        // appeared where there was none. Gate on the FIRST load (an
        // already-configured gateway at launch is not a sync event) and on the
        // empty → non-empty transition (never an ordinary edit), so the transient
        // banner reads as sync magic, not a glitch.
        if didCompleteInitialConfiguredLoad, !hadConfiguredGateway, !configuredRefs.isEmpty {
            presentSyncedBanner()
        }
        didCompleteInitialConfiguredLoad = true
        // Seed the session-local picker selection from the persisted default
        // whenever we're in an empty/new state (no bound thread yet). Inside a
        // thread the picker is hidden, so the selection is irrelevant.
        if currentConversationID == nil {
            pickerSelectedRef = await SettingsManager.shared.defaultRemoteAgentRef()
        }
        await refreshBackendTitle()
    }

    /// Refresh the nav-title snapshot (non-reactive `@State`). Inside a thread:
    /// the conversation's bound backend display name. Empty/new state: the
    /// default backend's display name (a future release swaps this for the picker
    /// selection). Falls back to the app name when no backend is configured at
    /// all. Refreshed at the same hooks as `isRemoteAgentConfigured` (launch /
    /// scenePhase / settings dismiss / remote change) PLUS on a thread switch
    /// — otherwise the title goes stale when moving between threads bound to
    /// different gateways.
    private func refreshBackendTitle() async {
        if let id = currentConversationID,
           let raw = try? await ConversationStore.shared.fetchConversation(id: id)?.backend,
           let ref = RemoteAgentRef(rawString: raw) {
            backendTitle = RemoteAgentRefMetadata.displayName(for: ref, customs: customGateways)
        } else if !(await SettingsManager.shared.configuredRemoteAgentRefs().isEmpty) {
            // Empty/new state, or a thread with an unknown stored backend →
            // preview the session-local picker selection (what the next send
            // will mint). The selection is seeded from the default in
            // `refreshConfiguredFlag`, then driven by the picker. This keeps the
            // static title (1 gateway configured) and the dropdown label in sync.
            // Gate on per-ref CONFIGURED state, NOT the legacy single-slot
            // `getRemoteAgentBackend()` (frozen after migration → nil on a fresh
            // multi-gateway install, which would wrongly fall through to
            // "Personal AI").
            backendTitle = RemoteAgentRefMetadata.displayName(for: pickerSelectedRef, customs: customGateways)
        } else {
            // No gateway configured → nothing to name. Show the app, not a
            // stand-in gateway called "Personal AI".
            backendTitle = String(localized: LocalizedStringResource(
                "chat.title.unconfigured",
                defaultValue: "Conduck"
            ))
        }
    }

    /// Pick the conversation to show on launch. Gated by the user's
    /// `OnLaunchMode`: the default `.startNewConversation` lands on empty state
    /// (a fresh conversation is minted on first send); `.resumeLastConversation`
    /// resumes the TTL-active conversation if fresh, else the most-recently-
    /// active one, else nil. The preference fires on cold launch only;
    /// notification deep-links bypass this resolver and open the linked thread
    /// directly.
    private func resolveInitialConversationID() async -> UUID? {
        let mode = await SettingsManager.shared.getOnLaunchMode()
        guard mode == .resumeLastConversation else { return nil }
        if let active = await SettingsManager.shared.resolveActiveConversationID() {
            return active
        }
        let conversations = (try? await ConversationStore.shared.fetchConversations()) ?? []
        return conversations.first?.id
    }

    // MARK: - Notification deep-link

    private func handleDeepLink(_ note: Notification) {
        guard let idString = note.userInfo?[NotificationDeepLink.conversationIDKey] as? String,
              let id = UUID(uuidString: idString) else { return }
        showingList = false
        #if os(iOS)
        settingsRoute = nil
        #endif
        currentConversationID = id
    }

    // MARK: - Turn handling

    /// Route an STT result from the in-app mic (the mic-tap path AND the
    /// duration-cap auto-stop path, which `recorder.onAutoStopResult` forwards
    /// here too — Part 1e). On success the transcript POPULATES the composer
    /// draft for review/edit instead of auto-sending (Part 1a): the user then
    /// taps Send once to ship text + staged attachments together. We do NOT
    /// touch `attachmentCoordinator` here — staged tiles must survive a dictation
    /// so the photo isn't silently dropped (the attachment-drop bug fix). The
    /// `hasPendingRetry` refresh stays on both branches.
    private func handleTranscriptionResult(_ result: Result<String, AppError>) async {
        switch result {
        case .success(let text):
            voiceRecovery = nil
            composerDraft = appendingTranscript(text, to: composerDraft)
            AccessibilityAnnouncer.announce(LocalizedStringResource(
                "voice.announce.transcriptAdded",
                defaultValue: "Transcript added"
            ))
            await refreshPendingRetryState()
        case .failure(let error):
            await refreshPendingRetryState()
            // Voice hard failure (Workstream A): the missing-model case no longer
            // reaches here — it self-heals upstream in `InAppAudioRecorder`. What
            // remains is a GENUINE hard failure (unsupported language, or a model
            // self-heal that couldn't complete and surfaced as
            // `appleSpeechModelNotInstalled`). Keep the composer's inline `.error`
            // banner and add ONE contextual, USER-TAPPED recovery — never an
            // automatic teleport. If a cloud STT key is configured → "Use cloud
            // voice"; else → "Open Voice Settings".
            if isVoiceHardFailure(error) {
                voiceRecovery = await resolveVoiceRecovery()
                return
            }
            voiceRecovery = nil
            // De-duplicate error surfaces: a retryable failure that armed the
            // pending-retry card would otherwise ALSO leave the composer's red
            // error banner up — two surfaces for one failure. The card carries
            // the actionable Retry, so it wins; the composer banner remains the
            // sole surface for non-retryable errors (no card arms for those),
            // and for the rare retryable error whose card save failed.
            if error.shouldPreserveForRetry, hasPendingRetry {
                recorder.dismissError()
            }
        }
    }

    /// A GENUINE voice hard failure that warrants the contextual recovery button
    /// (NOT a transient / retryable error). With self-heal upstream, the missing-
    /// model case (`appleSpeechModelNotInstalled`) only reaches here when the
    /// download itself failed; `appleSpeechLanguageUnsupported` is always a hard
    /// failure.
    private func isVoiceHardFailure(_ error: AppError) -> Bool {
        switch error {
        case .appleSpeechModelNotInstalled, .appleSpeechLanguageUnsupported:
            return true
        default:
            return false
        }
    }

    /// Resolve the ONE contextual recovery arm: "Use cloud voice" when a cloud
    /// STT key is already configured, else "Open Voice Settings".
    private func resolveVoiceRecovery() async -> VoiceRecoveryOption {
        if let cloudID = await SettingsManager.shared.firstConfiguredCloudSTTPresetID() {
            return .useCloud(presetID: cloudID)
        }
        return .openVoiceSettings
    }

    /// Apply a user-tapped voice recovery: switch to the configured cloud preset,
    /// or open Settings → Voice (user-initiated). Clears the error banner + the
    /// recovery affordance either way.
    private func applyVoiceRecovery(_ option: VoiceRecoveryOption) {
        recorder.dismissError()
        voiceRecovery = nil
        switch option {
        case .useCloud(let presetID):
            Task { await SettingsManager.shared.setActivePresetID(presetID) }
        case .openVoiceSettings:
            #if os(iOS)
            settingsRoute = SettingsRoute(category: .voice)
            #else
            break
            #endif
        }
    }

    /// Forward an STT transcript to the converse path on the visible
    /// conversation. Mints a fresh conversation if none is selected (first
    /// turn in an empty state). The SHARED detail VM owns the in-flight UX,
    /// so the on-screen thread renders the optimistic bubble, the thinking
    /// indicator, and the Cancel affordance for the same turn.
    private func sendTurn(
        _ text: String,
        modality: TurnModality = .voice,
        attachments: [PendingAttachment] = []
    ) async {
        // Ensure we have a visible conversation + VM; mint one bound to the
        // gateway-picker selection on first turn. The selection is
        // seeded from the default in the empty state, then driven by the title
        // dropdown when ≥2 gateways are configured. Once minted,
        // `currentConversationID` is non-nil → the picker is gated off and the
        // thread is locked to this backend.
        if currentConversationID == nil {
            if let fresh = try? await ConversationStore.shared.createConversation(backend: pickerSelectedRef.rawString) {
                currentConversationID = fresh.id
            } else {
                // Mint failure (rare Core Data write error, e.g. disk-full).
                // The composer already cleared the draft before calling us, so
                // a bare return would silently swallow the user's message —
                // restore the text and say so. (Staged attachments were also
                // cleared; the text is the recoverable part.)
                composerDraft = appendingTranscript(text, to: composerDraft)
                showSendFailedAlert = true
                return
            }
        }
        guard currentConversationID != nil else { return }
        if detailVM?.conversationID != currentConversationID { syncDetailVM() }
        guard let vm = detailVM else { return }
        await vm.sendUserTurn(text, modality: modality, attachments: attachments)
    }

    // MARK: - Pending retry

    private func retryButtonTapped() {
        guard !isRetrying else { return }
        #if os(iOS)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        #endif
        Task { await runPendingRetry() }
    }

    @MainActor
    private func runPendingRetry() async {
        isRetrying = true
        retryErrorMessage = nil
        defer { isRetrying = false }

        guard let pending = await PendingRetryStore.shared.load() else {
            pendingRetryErrorCode = nil
            withAnimation { hasPendingRetry = false }
            return
        }

        // ATOMIC snapshot — (presetID, apiKey, provider, customModel,
        // customConfig) in one actor hop, mirroring `DictationService.retryLast`.
        // The old `getAPIKey()` + bare `lookup` pair both raced a concurrent
        // preset switch AND dead-ended Apple on-device / keyless custom
        // endpoints on "No STT API key set" (no key is needed for either).
        let snapshot = await SettingsManager.shared.activeSTTSnapshot()
        let apiKey: String
        if snapshot.provider.transport == .inProcess || snapshot.customConfig?.auth == STTAuthScheme.none {
            apiKey = ""
        } else if let key = snapshot.apiKey, !key.isEmpty {
            apiKey = key
        } else {
            presentRetryError(String(localized: "No STT API key set. Open Settings to add one."))  // xcstrings
            return
        }

        // Re-materialize the preserved audio to a fresh temp URL —
        // `metadata.audioFileURL` was defer-deleted by the ORIGINAL transcribe
        // (STTClient owns that file's lifecycle), so transcribing from that
        // path again failed on EVERY Retry tap. The App-Group copy in
        // `pending.audioData` is the real payload (mirrors retryLast).
        let retryAudioURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("conduck_retry_\(UUID().uuidString).m4a")
        do {
            try pending.audioData.write(to: retryAudioURL, options: [.atomic])
        } catch {
            presentRetryError(String(localized: "Couldn't send — try again in a minute."))  // xcstrings
            return
        }

        do {
            let response = try await STTClient.shared.transcribe(
                audioFileURL: retryAudioURL,
                apiKey: apiKey,
                language: pending.metadata.preferredLanguage,
                provider: snapshot.provider,
                customModel: snapshot.customModel,
                customConfig: snapshot.customConfig
            )

            guard !response.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                presentRetryError(String(localized: "Transcription returned empty text. Try again."))  // xcstrings
                return
            }

            await PendingRetryStore.shared.clear()
            await PendingRetryGuard.cancelAllDeferredNotifications()

            pendingRetryErrorCode = nil
            withAnimation { hasPendingRetry = false }
            // The recovered transcript continues into the converse path.
            await sendTurn(response.text)

        } catch let error as AppError {
            presentRetryError(error.errorDescription ?? String(localized: "Couldn't send — try again in a minute."))  // xcstrings
        } catch {
            presentRetryError(String(localized: "Couldn't send — try again in a minute."))  // xcstrings
        }
    }

    @MainActor
    private func presentRetryError(_ message: String) {
        withAnimation { retryErrorMessage = message }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            if retryErrorMessage == message && !isRetrying {
                withAnimation { retryErrorMessage = nil }
            }
        }
    }
}

#Preview {
    ContentView()
}
