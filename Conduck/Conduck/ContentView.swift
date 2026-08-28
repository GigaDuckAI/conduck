// SPDX-License-Identifier: Apache-2.0

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
    /// Whether the failure the retry card is currently reporting can be retried
    /// at all (`AppError.isRetryable`). Seeded from the store's arming code and
    /// re-keyed by every failed Retry, so a terminal verdict — a certificate
    /// this device refuses, a rejected key — withdraws the button instead of
    /// leaving one that can only reach the same refusal again. Reset on every
    /// `refreshPendingRetryState()`, so a server-side fix restores it.
    @State private var pendingRetryIsRetryable: Bool = true

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

    /// Set for exactly ONE Settings dismissal: the one `handleDeepLink` causes
    /// when a tapped reply notification tears the surface down to show a thread.
    ///
    /// `handleSettingsDismiss()` collects a deferred gateway fix route on every
    /// dismissal, which is what makes that collection total. But a route describes
    /// a STATE ("your default needs setup"), not an appointment, while the deep
    /// link is a fresh, explicit request for specific content — so on that one
    /// dismissal the route must not be cashed in, or Settings re-presents on top
    /// of the thread the user just asked for. The route is SKIPPED, never spent,
    /// and lands on the next ordinary Done or the next `.openGatewayFixRoute` post.
    ///
    /// A one-shot marker rather than a second collection site, so totality
    /// survives: any dismissal that does not set it still collects by default.
    /// `MainWindowView.settingsClosedForConversationAction` is the macOS twin.
    /// Declared outside the iOS-only block so `handleSettingsDismiss` needs no
    /// platform fork; nothing sets it on macOS, where this view is not the root.
    @State private var settingsClosedForConversationAction = false

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
    /// Session-local (NOT persisted) gateway-picker selection for the NEXT new
    /// conversation. The persisted preference is the Settings *default*;
    /// this is purely the title-dropdown's transient choice. Seeded from the
    /// default whenever we enter an empty/new state; the picker then drives it,
    /// and `sendTurn`'s mint reads it. Falls back harmlessly to the default
    /// backend before the first seed.
    @State private var pickerSelectedRef: RemoteAgentRef = .builtin(Constants.remoteAgentDefaultBackendDefault)
    /// True once the user has picked a gateway BY HAND for the chat currently
    /// being composed. It makes that choice outrank the persisted Settings
    /// default in `refreshGatewayRoster()` until the chat is minted or the user
    /// starts another one — without it, a refresh still suspended from
    /// `startNewConversation()` resumes and silently reinstates the default,
    /// which is both a title flicker and a re-aim of the ref the next send seals.
    @State private var userPickedRefForNewChat = false
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
    /// The default-gateway statement for THIS device, recomputed from the same
    /// `newChatPickerSnapshot` turn the picker seed already takes — one actor turn,
    /// one answer, so the banner and the picker can never describe different
    /// rosters. nil = nothing honest to say.
    @State private var defaultGatewayNotice: DefaultGatewayNotice?
    /// The notice the user waved off THIS SESSION, keyed to what it was ABOUT
    /// (`.noDefaultChosen`) rather than to a bare Bool, so a later notice of a
    /// different kind still speaks up. Session-scoped on purpose: persisting a
    /// dismissal would need a storage key for a state that fixes itself the moment
    /// the user acts.
    @State private var dismissedGatewayNoticeKey: DefaultGatewayNotice.DismissalKey?
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        #if os(iOS)
        // BOTH conditions, because `.regular` alone is not the same question. A
        // large iPhone (Plus/Max) reports a REGULAR horizontal size class in
        // landscape, and `ConversationLibraryView` is built for a genuine
        // two-column canvas: it opens a ~320pt conversation sidebar and hosts
        // compose in whichever COLUMN's bar is on screen. On a 956x440 phone
        // canvas the sidebar takes a third of the width, and the compose item
        // becomes conditional on the split view's column state — where
        // `phoneLayout` carries an unconditional one in its own nav bar. So the
        // split view is gated to the iPad idiom and every phone geometry,
        // portrait and landscape, stays on `phoneLayout`.
        if horizontalSizeClass == .regular && DeviceCapabilities.isiPad {
            // iPad — split layout as the root content.
            ConversationLibraryView(
                selectedConversationID: $currentConversationID,
                recorder: recorder,
                onSendTurn: { dispatch, modality in
                    await sendTurn(
                        dispatch.text,
                        modality: modality,
                        attachments: dispatch.attachments,
                        expectedRef: dispatch.ref,
                        expectedFileLaneID: dispatch.fileLaneID,
                        expectedConversationID: dispatch.conversationID,
                        mintConversationID: dispatch.pendingConversationID
                    )
                },
                isRemoteAgentConfigured: isRemoteAgentConfigured,
                backendTitle: backendTitle,
                configuredRefs: configuredRefs,
                customGateways: customGateways,
                defaultGatewayNotice: visibleDefaultGatewayNotice,
                onOpenPersonalAIFromNotice: { openPersonalAIFromNotice() },
                onDismissDefaultGatewayNotice: { dismissDefaultGatewayNotice() },
                selectedRef: $pickerSelectedRef,
                canPickBackend: canPickBackend,
                onPickBackend: { userPickedRefForNewChat = true },
                onStartNewConversation: {
                    // Same pair, same order, as this view's own
                    // `startNewConversation()`: the synchronous reset must land
                    // before the refresh task can observe the flag, or the re-seed
                    // takes its skip branch and the picker keeps the old pick.
                    userPickedRefForNewChat = false
                    Task { await refreshGatewayRoster() }
                },
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
                if newPhase == .active {
                    Task { await refreshOnForeground() }
                    // Foreground is one of the moments the toolbar should
                    // re-state what it is showing (see the phone twin below). The `.task(id:)`
                    // that covers "surface appears / ref changed" for this branch
                    // lives in `ConversationLibraryView`, which owns the iPad
                    // title control — but the scene belongs to this host, so the
                    // foreground arm stays here. The monitor answers from the
                    // verdict it already has when that verdict is fresh AND was
                    // built from the same gateway config; a real absence, or a
                    // gateway the user edited, re-probes.
                    if let ref = presenceRef { GatewayPresenceMonitor.shared.observe(ref) }
                }
            }
            .onChange(of: currentConversationID) { _, newID in
                composerDraft = ""   // don't carry a half-typed draft into another thread
                clearComposerFeedback()   // stale voice error/recovery shouldn't follow a thread switch
                // Entering a new-chat state retires the previous chat's hand-pick,
                // whichever surface got us here. iPad's New button lives in
                // `ConversationLibraryView` and never reaches this view's
                // `startNewConversation()`, so gating the reset on that call alone
                // left an iPad pick sticky for the rest of the session — a later
                // Settings default change would never take effect.
                //
                // BACKSTOP, not the primary hook. iPad's New button now reports
                // through `onStartNewConversation`, because this observer cannot
                // see it: pressing New while already on the empty state writes nil
                // over nil and fires nothing. What still arrives here is the routes
                // that genuinely change the selection — deleting the open thread, a
                // deep link. The duplicate reset on the paths that do both is
                // harmless (no refresh is scheduled here).
                if newID == nil { userPickedRefForNewChat = false }
                // The nav title follows the VM this rebuilds — it is derived, so
                // no separate refresh hop can go stale or land out of order.
                syncDetailVM()
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
            .onReceive(NotificationCenter.default.publisher(for: .openGatewayFixRoute)) { _ in
                consumeGatewayFixRoute()
            }
            .onAppear { consumeGatewayFixRoute() }
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
        configuredRefs.count >= 2
            && currentConversationID == nil
            && !attachmentGatewaySelectionLocked
    }

    /// macOS owns its composer in `MainWindowView`; only the iPhone shell has
    /// this local coordinator. Keep the shared picker predicate buildable on
    /// both platforms while still locking iPhone gateway changes during staging.
    private var attachmentGatewaySelectionLocked: Bool {
        #if os(iOS)
        attachmentCoordinator.gatewaySelectionLocked
        #else
        false
        #endif
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
                    userPickedRefForNewChat = true
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
                            userPickedRefForNewChat = true
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
            // Presence dot LEADING of the name — here and in both branches of
            // `gatewayTitleControl`, so the mark keeps its position as the title
            // control changes shape. Nested stacks on purpose: 6pt separates the
            // dot (a statement about the gateway) from the name, while the inner
            // 4pt stays the existing name-to-chevron affordance gap.
            HStack(spacing: 6) {
                // MUTE inside the control, spoken as the Menu's a11y VALUE
                // below. SwiftUI folds a Menu's label subtree into ONE element
                // and the explicit `.accessibilityLabel` overwrites it, so a dot
                // that declared its own element here would simply never be heard.
                GatewayPresenceDot(ref: presenceRef, standaloneAccessibility: false)
                HStack(spacing: 4) {
                    Text(RemoteAgentRefMetadata.displayName(for: pickerSelectedRef, customs: customGateways))
                        .font(.headline)
                        .foregroundStyle(AppColors.textPrimary)
                    Image(systemName: "chevron.down")
                        .font(.caption2)
                        .foregroundStyle(AppColors.textSecondary)
                }
            }
        }
.accessibilityLabel(Text(LocalizedStringResource(
            "chat.chooseAI.label",
            defaultValue: "Choose AI"
        )))  // VoiceOver reads the taxonomy no visual review ever sees.
        .accessibilityIdentifier("toolbar.gatewayPicker")  // stable QA target (non-localized)
        // …and the state the muted dot draws, as this element's VALUE:
        // "Choose AI, Connected". No-op when there is no verdict to report.
        .gatewayPresenceAccessibilityValue(for: presenceRef)
    }

    /// The nav-title display name, derived — never snapshotted. Inside a thread:
    /// the bound backend, via the VM (whose header is memo-seeded at mint and on
    /// warm, so it is right on frame one). Empty/new state: the picker selection,
    /// which is what the next send will bind to. No gateway configured at all:
    /// the app name, because there is no responder to name — "Personal AI" here
    /// was a placeholder backend name wearing a title's clothes.
    ///
    /// The `conversationID` guard matters twice: it keeps a thread switch from
    /// briefly rendering the OUTGOING VM's name, and during a first-turn mint —
    /// between `currentConversationID` moving and `syncDetailVM()` catching up —
    /// it falls through to the picked ref, which is the correct answer for that
    /// window rather than a stale one.
    private var backendTitle: String {
        if let vm = detailVM, vm.conversationID == currentConversationID {
            return vm.backendDisplayName
        }
        if !configuredRefs.isEmpty {
            return RemoteAgentRefMetadata.displayName(for: pickerSelectedRef, customs: customGateways)
        }
        return String(localized: LocalizedStringResource(
            "chat.title.unconfigured",
            defaultValue: "Conduck"
        ))
    }

    /// The ref whose presence the toolbar dot reports: inside a thread the bound
    /// gateway (ONLY while this device can still send on it), on the empty/new
    /// state the picker selection (ONLY while it is configured here). Everything
    /// else answers nil — and nil is what makes the dot DISAPPEAR rather than go
    /// red. A gateway the user has not connected is an offer, not an unfinished
    /// task (`docs/ai-context/spec.md`), so red may only ever mean "configured,
    /// and the probe failed" — never "not set up". A thread bound to a forgotten
    /// gateway therefore shows no dot at all; its recovery banner is the surface
    /// that speaks about it.
    ///
    /// Same `conversationID` guard as `backendTitle`, for the same two reasons: a
    /// thread switch must not briefly report the OUTGOING VM's gateway, and
    /// during a first-turn mint the picked ref is the right answer for the window.
    ///
    /// TWIN of `ConversationLibraryView.presenceRef` and
    /// `MainWindowView.presenceRef`. The three must not drift, the same way
    /// `refreshGatewayRoster()` and `refreshConfiguredBackends()` must not.
    private var presenceRef: RemoteAgentRef? {
        if let vm = detailVM, vm.conversationID == currentConversationID {
            return vm.boundGatewayAvailable ? vm.boundRef : nil
        }
        return configuredRefs.contains(pickerSelectedRef) ? pickerSelectedRef : nil
    }

    /// The centered principal-toolbar control. Three-way: the gateway picker
    /// when a new/empty chat with ≥2 backends can pick; else a tappable title
    /// that folds in "Clone & continue" when the bound thread is clone-eligible
    /// (has turns, gateway available, somewhere to switch to); else a plain
    /// static title.
    ///
    /// `hasTurns`, not `!messages.isEmpty` — a freshly minted VM has no messages
    /// for a beat, which popped the chevron affordance in a frame late (iPad and
    /// macOS already gate on the memo-seeded form).
    @ViewBuilder
    private var gatewayTitleControl: some View {
        if canPickBackend {
            gatewayPickerMenu
        } else if let vm = detailVM, vm.canSwitchGateway, vm.hasTurns, vm.boundGatewayAvailable {
            Button { vm.showingGatewaySheet = true } label: {
                HStack(spacing: 6) {
                    // Muted here for the same reason as the picker Menu above —
                    // the Button's own label would discard it.
                    GatewayPresenceDot(ref: presenceRef, standaloneAccessibility: false)
                    HStack(spacing: 4) {
                        Text(backendTitle)
                            .font(.headline)
                            .foregroundStyle(AppColors.textPrimary)
                        Image(systemName: "chevron.down")
                            .font(.caption2)
                            .foregroundStyle(AppColors.textSecondary)
                    }
                }
            }
            .accessibilityLabel(Text(LocalizedStringResource("conversations.switchGateway", defaultValue: "Clone & continue on another gateway")))
            .accessibilityIdentifier("toolbar.cloneGateway")
            .gatewayPresenceAccessibilityValue(for: presenceRef)   // the muted dot's state, as this element's value
        } else {
            // Wrapped so the static branch carries the dot too: the read-only
            // title is where a bound thread spends most of its life, and it is
            // the branch a single-gateway setup never leaves.
            HStack(spacing: 6) {
                GatewayPresenceDot(ref: presenceRef)
                Text(backendTitle)
                    .font(.headline)
                    .foregroundStyle(AppColors.textPrimary)
            }
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
                            errorIsRetryable: pendingRetryIsRetryable,
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

                    // Third of three, and the order is the argument: the retry
                    // card is about a recording that already exists and outranks
                    // everything, and the synced banner auto-dismisses after ~3s
                    // (`presentSyncedBanner()`), so it belongs above a notice that
                    // stays on screen until the user acts on it or waves it off.
                    if let notice = visibleDefaultGatewayNotice {
                        DefaultGatewayNoticeBanner(
                            notice: notice,
                            onOpenPersonalAI: { openPersonalAIFromNotice() },
                            onDismiss: { dismissDefaultGatewayNotice() }
                        )
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
                            onSend: { dispatch in
                                await sendTurn(
                                    dispatch.text,
                                    modality: .text,
                                    attachments: dispatch.attachments,
                                    expectedRef: dispatch.ref,
                                    expectedFileLaneID: dispatch.fileLaneID,
                                    expectedConversationID: dispatch.conversationID,
                                    mintConversationID: dispatch.pendingConversationID
                                )
                            },
                            onVoiceResult: handleTranscriptionResult,
                            settingsVM: settingsVM,
                            pendingNewConversationRef: pickerSelectedRef,
                            onComposerEngaged: {
                                // Resolve the ref WHEN IT RUNS, never captured:
                                // the composer outlives thread switches, and a
                                // captured ref would re-check the gateway of the
                                // conversation the user just left.
                                guard let ref = presenceRef else { return }
                                GatewayPresenceMonitor.shared.observe(ref)
                            }
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
                        configuredRefs: configuredRefs,
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
            // Presence dot lifecycle. On the host body, NOT inside the
            // `ToolbarItem` — a `.task` attached to toolbar content is not
            // reliably run. `id:` re-fires whenever the reported ref changes
            // (thread switch, picker move); the monitor's own reuse rule — a
            // verdict that is still fresh AND was built from the same gateway
            // config — is what keeps rapid switching from hammering the user's
            // server, so this side stays a plain "tell it what is on screen".
            .task(id: presenceRef) {
                if let ref = presenceRef { GatewayPresenceMonitor.shared.observe(ref) }
            }
            .onChange(of: scenePhase) { _, newPhase in
                if newPhase == .active {
                    Task { await refreshOnForeground() }
                    // Returning to the foreground is worth ASKING again: the
                    // Mac or the network may have moved while we were suspended.
                    // Asking is not probing — the monitor reuses the verdict it
                    // has when that verdict is fresh AND the gateway's config is
                    // unchanged, so a quick app-switch back does not flicker the
                    // dot. A real absence, or a gateway the user edited, does
                    // re-probe.
                    if let ref = presenceRef { GatewayPresenceMonitor.shared.observe(ref) }
                }
            }
            .onChange(of: currentConversationID) { oldID, newID in
                #if os(iOS)
                attachmentCoordinator.discardForNavigation(from: oldID, to: newID)
                #endif
                composerDraft = ""   // don't carry a half-typed draft into another thread
                clearComposerFeedback()   // stale voice error/recovery shouldn't follow a thread switch
                // Entering a new-chat state retires the previous chat's hand-pick,
                // whichever surface got us here (see the iPad twin above).
                if newID == nil { userPickedRefForNewChat = false }
                // The nav title follows the VM this rebuilds — it is derived, so
                // no separate refresh hop can go stale or land out of order.
                syncDetailVM()
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
            .onReceive(NotificationCenter.default.publisher(for: .openGatewayFixRoute)) { _ in
                consumeGatewayFixRoute()
            }
            .onAppear { consumeGatewayFixRoute() }
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
        #if os(iOS)
        // A fresh new-chat session gets a fresh pre-minted conversation
        // identifier, so its first attachment cannot land in the folder of the
        // chat that came before it. No-ops while staging is live (the tap
        // arrived on top of files already minted against the current one) — a
        // real conversation switch below rotates through teardown instead.
        attachmentCoordinator.beginNewChatSession()
        #endif
        currentConversationID = nil
        hostMascot = MascotShuffleBag.next()  // fresh shuffle-bag pose for the new empty state
        // Drop the PREVIOUS chat's hand-pick synchronously, before the refresh
        // below can observe it — a genuinely fresh chat starts from the seed
        // ladder, not from whatever the last chat was hand-picked onto.
        userPickedRefForNewChat = false
        // Re-seed the gateway picker (`NewChatGatewaySeed`: last-used, else the
        // default) + refresh the configured list so the dropdown reappears (when
        // ≥2 are configured) pre-selected for this fresh conversation.
        Task { await refreshGatewayRoster() }
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
            ConversationThreadView(viewModel: vm, settingsVM: settingsVM, emptyMascot: hostMascot)
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

    // MARK: - Default-gateway notice

    /// The resolved notice minus anything the user waved off this session.
    private var visibleDefaultGatewayNotice: DefaultGatewayNotice? {
        guard let notice = defaultGatewayNotice else { return nil }
        if let key = notice.dismissalKey, key == dismissedGatewayNoticeKey { return nil }
        return notice
    }

    /// Wave the notice off. The two SESSION states park their identity in
    /// `dismissedGatewayNoticeKey`; `.adopted` has no key because acknowledging
    /// the STORED record is what dismisses it — that acknowledgment survives a
    /// relaunch, and clearing it lets the slot fall through to a broken-default or
    /// no-default notice when the pointer is unhappy again.
    private func dismissDefaultGatewayNotice() {
        guard let notice = defaultGatewayNotice else { return }
        if let key = notice.dismissalKey {
            withAnimation { dismissedGatewayNoticeKey = key }
        } else {
            Task {
                await SettingsManager.shared.acknowledgeDefaultAdoptionNotice()
                await refreshGatewayRoster()
            }
        }
    }

    /// Land on Settings → Personal AI, which shows BOTH doors: pick a different
    /// gateway, or finish setting up the named one. Same `settingsRoute == nil`
    /// double-tap guard as `openGuidedSetupFromEmptyState()` — a second tap would
    /// mint a fresh route UUID mid-presentation.
    ///
    /// The guard is INSIDE the body rather than around the declaration (the shape
    /// `openGuidedSetupFromEmptyState` takes) because the banner that calls this
    /// renders in the cross-platform `phoneLayout` stack; `settingsRoute` is the
    /// iOS-only presentation state.
    private func openPersonalAIFromNotice() {
        #if os(iOS)
        guard settingsRoute == nil else { return }
        settingsRoute = SettingsRoute(category: .personalAI)
        #endif
    }

    /// Land a headless fix request (`GatewayFixRoute.request()`) on
    /// Settings → Personal AI.
    ///
    /// `consumeIfStillBroken()` is one-shot read-and-clear, so this is called from
    /// BOTH an `.onReceive` of `.openGatewayFixRoute` and an `.onAppear`: a warm
    /// app hears the post, and a cold launch is asked BEFORE this view mounts and
    /// misses the post entirely. Both of this file's layout branches carry the
    /// pair, because only one of the two is ever mounted at a time.
    ///
    /// It re-reads the default before navigating and drops a request whose
    /// problem is already solved — gateway definitions sync and a Keychain that
    /// has become readable can make the same pointer sendable with no pointer
    /// write at all. `MainWindowView` lands the same request through the same
    /// call, so the two roots cannot disagree about when the route still stands.
    ///
    /// THE GUARD COMES BEFORE THE CLAIM. `settingsRoute` drives `.sheet(item:)` /
    /// `.fullScreenCover(item:)` keyed on `route.id`, so assigning a fresh route
    /// over a presented one tears the surface down and takes any half-typed
    /// bearer token with it — the same reason `openPersonalAIFromNotice()` and
    /// `openGuidedSetupFromEmptyState()` guard. And `consumeIfStillBroken()` is a
    /// one-shot read-and-clear, so claiming first and guarding second would SPEND
    /// the route and navigate nowhere. A route left unclaimed here is DEFERRED,
    /// not dropped: Settings is already on screen, which is where it wanted to
    /// send the user, and `handleSettingsDismiss()` runs this again when that
    /// surface goes away — so a user who accepts a refusal's offer from inside
    /// Settings → Voice still lands on Personal AI when they tap Done.
    private func consumeGatewayFixRoute() {
        Task {
            #if os(iOS)
            guard settingsRoute == nil else { return }
            #endif
            guard await GatewayFixRoute.consumeIfStillBroken() else { return }
            #if os(iOS)
            // Re-checked after the suspension: a sibling may have presented
            // Settings while the default was being re-read, and it presents the
            // same category, so dropping the spent route disturbs nothing.
            guard settingsRoute == nil else { return }
            settingsRoute = SettingsRoute(category: .personalAI)
            #endif
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
        // Warm the header memo BEFORE any VM is built (the first one is minted by
        // `syncDetailVM()` at the end of this function), so the first thread opened
        // this session draws its gateway on frame one instead of the generic
        // "Personal AI" placeholder while its resolve walks the store. macOS warms
        // from `MenuBarCoordinator`; this is the iOS/iPadOS half, and it became
        // load-bearing when the nav title started deriving from the VM.
        //
        // Ordered AFTER the configured flag on purpose: the warm forces the
        // persistent-store load plus a full conversation fetch, and
        // `isRemoteAgentConfigured` starts false — putting it first held a
        // configured user on the "connect a gateway" empty state for the length of
        // that fetch on every cold launch.
        await ConversationDetailViewModel.warmHeaderMemo()
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
        // Synced-roster catch-up FIRST (custom gateways + custom voice
        // endpoints): a peer's Forget or endpoint delete can land in the KVS
        // cache with no change notification (applied while suspended) — adopt
        // it before `refreshConfiguredFlag` re-reads gateway state, so the
        // stale row leaves the Personal AI / Voice list this foreground, not
        // the next.
        await SettingsManager.shared.catchUpSyncedRostersOnActivate()
        await refreshConfiguredFlag()
        await refreshPendingRetryState()
        // Share Extension drain hook. On every foreground, drain any envelopes
        // the share extension queued into the App-Group inbox — claim, classify,
        // (upload), append, assemble, dispatch. The actor serializes concurrent
        // drains (this + a notification tap firing near-simultaneously); an empty
        // inbox is a cheap no-op.
        await SharedInboxDrainer.shared.drain()
        // Fill header-memo entries for rows this foreground introduced — a
        // CloudKit import that landed while suspended, or a share-extension turn
        // the drain above just minted — so opening one draws its gateway on frame
        // one. Deliberately here and NOT on `.conversationsDidChange` (which
        // macOS uses): that notification also fires on every message append, and
        // a full-table warm per append is a cost a phone should not pay. Locally
        // minted and cloned rows are seeded at mint by `seedHeaderIdentity`.
        await ConversationDetailViewModel.warmHeaderMemo()
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
        // A fix route that arrived while a Settings surface was up was left ARMED
        // rather than spent — the presentation guard refuses to assign a fresh
        // route over a presented sheet. Nothing else re-runs the claim, so a user
        // who accepted a refusal's offer to continue in the app while sitting in
        // Settings → Voice would tap Done and land nowhere. Re-consume here; the
        // claim is one-shot, so an unarmed route is a no-op.
        // `MainWindowView`'s `.onChange(of: showingSettings)` is the macOS twin.
        //
        // ONE dismissal collects nothing: the one a NEWER conversation action
        // caused — `handleDeepLink` tearing this surface down to show a tapped
        // reply. A route describes a STATE, not an appointment, so it must not
        // outrank an explicit request for specific content. Skipping SPENDS
        // nothing: the route stays armed for the next ordinary Done.
        if settingsClosedForConversationAction {
            settingsClosedForConversationAction = false
        } else {
            consumeGatewayFixRoute()
        }
    }

    /// Refresh the pending-retry card's presence AND its arming error code
    /// together, so the card and its Troubleshoot affordance stay in sync across
    /// every lifecycle / foreground / dictation-result path. Both are cheap
    /// metadata-only reads (no audio load).
    ///
    /// The retryability flag is DERIVED from the same code rather than assumed
    /// true: it is the store's arming verdict, and re-deriving it here is what
    /// lets a terminal Retry failure withdraw the button for this session and
    /// hand it back on the next foreground, once the user has had a chance to
    /// act on the remedy.
    private func refreshPendingRetryState() async {
        hasPendingRetry = await PendingRetryStore.shared.hasPending()
        pendingRetryErrorCode = await PendingRetryStore.shared.pendingErrorCode()
        pendingRetryIsRetryable = pendingRetryErrorCode
            .map { AppError.from(errorCode: $0, message: nil).isRetryable } ?? true
        // A sticky terminal line belongs to the verdict that produced it, and
        // that verdict is what just got re-read. Dropping it with the flag keeps
        // the card from showing "trying again would reach the same answer" beside
        // a Retry button this refresh has restored.
        retryErrorMessage = nil
    }

    private func refreshConfiguredFlag() async {
        let hadConfiguredGateway = !configuredRefs.isEmpty
        let refs = await refreshGatewayRoster()
        // Strict configured flag: a usable gateway needs a URL AND (for `.bearer`)
        // a token — never URL alone. The old `remoteAgentSnapshot() != nil` was
        // URL-gated and could read "ready" with no key, showing the composer when
        // a send would fail closed. Align with the strict predicate used
        // everywhere else (`configuredRemoteAgentRefs()`).
        //
        // Through `GatewayGate` rather than inline, so this and the macOS window
        // are provably the same question — they drifted once, and the macOS half
        // is in a file the suite never compiles.
        isRemoteAgentConfigured = GatewayGate.canSendAnywhere(configured: refs)

        // Cross-device "set up later, then it synced" path: a gateway just
        // appeared where there was none. Gate on the FIRST load (an
        // already-configured gateway at launch is not a sync event) and on the
        // empty → non-empty transition (never an ordinary edit), so the transient
        // banner reads as sync magic, not a glitch.
        if didCompleteInitialConfiguredLoad, !hadConfiguredGateway, !refs.isEmpty {
            presentSyncedBanner()
        }
        didCompleteInitialConfiguredLoad = true
    }

    /// Re-read the configured roster and re-seed the new-chat picker selection.
    /// Returns the configured refs so the caller drives its own derived state
    /// from the SAME snapshot rather than re-reading a moved one.
    ///
    /// Every awaited value is gathered BEFORE anything is published, and both the
    /// staging lock and the user's hand-pick are read AFTER the last suspension.
    /// Reading them before it was the bug: `startNewConversation()` fires this
    /// task and returns immediately, so the picker is live while this is still
    /// suspended — the resumed task then overwrote a gateway the user had since
    /// chosen, visibly in the title and in the ref the next send seals.
    @discardableResult
    private func refreshGatewayRoster() async -> [RemoteAgentRef] {
        // ONE actor turn for all four values. Do NOT split this back into separate
        // awaits, and do NOT move any read below the guards: every suspension here
        // is a window in which the picker can move under a resumed refresh, which
        // is the exact bug the hand-pick flag was introduced to close. A read
        // placed inside the `if` below would look like careful defensive code and
        // would reopen it.
        let snapshot = await SettingsManager.shared.newChatPickerSnapshot()
        let refs = snapshot.configuredRefs

        // A roster refresh re-seeds the picker, so the ref the toolbar is
        // reporting on may have just changed underneath it — re-stating what is
        // on screen is this host's entire contribution. Whether that ref needs a
        // PROBE is the monitor's call, not ours: it reuses a verdict that is
        // still fresh and was built from the same URL / token / auth scheme /
        // pin, and re-probes when any of those moved. So a settings-close that
        // touched nothing costs no request, while an edited gateway cannot keep
        // greening on a verdict about its old config.
        //
        // `defer`, not a line before each `return`: this function has two exits and
        // both have to re-state, and it must run AFTER the re-seed below or it would
        // observe the OUTGOING pick. Twin of `MainWindowView.refreshConfiguredBackends()`.
        defer {
            if let ref = presenceRef { GatewayPresenceMonitor.shared.observe(ref) }
        }

        configuredRefs = refs
        customGateways = snapshot.badgeRoster
        // ABOVE the guard, deliberately: the default pointer is a property of the
        // DEVICE, not of the chat on screen. Below the guard this would freeze at
        // whatever it said the last time the user stood on the empty state, so a
        // default that broke while a thread was open would never be mentioned.
        defaultGatewayNotice = DefaultGatewayNotice.resolve(
            resolution: snapshot.resolution,
            roster: snapshot.badgeRoster,
            pendingAdoption: snapshot.pendingAdoptionNotice
        )
        // Inside a thread the picker is hidden, so the selection is irrelevant.
        guard currentConversationID == nil, !attachmentGatewaySelectionLocked else { return refs }
        // A hand-pick outranks the seed until this chat is minted or the user
        // starts another one. It yields only when the picked gateway is no longer
        // configured at all — and then to the seed ladder, never to another
        // invalid selection.
        if !userPickedRefForNewChat || !refs.contains(pickerSelectedRef) {
            pickerSelectedRef = NewChatGatewaySeed.resolve(
                configured: refs,
                lastUsed: snapshot.lastUsedRef,
                persistedDefault: snapshot.defaultRef
            )
            userPickedRefForNewChat = false
        }
        return refs
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
        // A newer, EXPLICIT request for content. Tearing the Settings surface down
        // fires its `onDismiss`, which is where a deferred gateway fix route gets
        // collected — and collecting it there would re-present Settings on top of
        // the very thread the user tapped a notification to reach. Mark the close
        // so `handleSettingsDismiss()` skips that one collection; the route is
        // skipped, never spent, so the next ordinary Done still lands it.
        //
        // Only when a surface is actually up: set unconditionally, the marker
        // survives a deep link that dismissed nothing and then swallows an
        // unrelated later close. `MainWindowView` is the macOS twin, where
        // `leaveSettingsForConversationAction`'s `guard showingSettings` does the
        // same job.
        if settingsRoute != nil { settingsClosedForConversationAction = true }
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
    ///
    /// `mintConversationID` is the identifier a composer dispatch already minted
    /// its file-server keys under, so the row this creates adopts the folder
    /// those files are in. It is deliberately SEPARATE from
    /// `expectedConversationID`, the nil-means-new-chat ownership sentinel — one
    /// says "create this identifier", the other says "the composer sealed against
    /// this visible conversation", and conflating them turns every new-chat send
    /// into a rejected dispatch. The voice path has no dispatch and passes
    /// neither, so its mint takes a fresh identifier.
    private func sendTurn(
        _ text: String,
        modality: TurnModality = .voice,
        attachments: [PendingAttachment] = [],
        expectedRef: RemoteAgentRef? = nil,
        expectedFileLaneID: String? = nil,
        expectedConversationID: UUID? = nil,
        mintConversationID: UUID? = nil
    ) async -> Bool {
        // A sealed composer dispatch may target either one established
        // conversation or a genuine new-chat mint. Never reinterpret nil as
        // "whatever thread happens to be visible now".
        if expectedRef != nil {
            guard ComposerDispatchOwnership.matches(
                sealedConversationID: expectedConversationID,
                activeConversationID: currentConversationID
            ) else {
                detailVM?.reportComposerDispatchRejection()
                return false
            }
        }
        // Ensure we have a visible conversation + VM; mint one bound to the
        // gateway-picker selection on first turn. The selection is seeded in the
        // empty state by `NewChatGatewaySeed` (last-used, else the default), then
        // driven by the title dropdown when ≥2 gateways are configured. Once
        // minted, `currentConversationID` is non-nil → the picker is gated off and
        // the thread is locked to this backend.
        //
        // `mintedRef` outlives this block so the last-used pointer can be recorded
        // AFTER the turn is locally accepted, far below — a row can be adopted and
        // still have its first dispatch rejected, and that must not count as
        // "started a conversation here".
        var mintedRef: RemoteAgentRef?
        if currentConversationID == nil {
            let mintRef = expectedRef ?? pickerSelectedRef
            if let fresh = try? await ConversationStore.shared.createConversation(
                id: mintConversationID ?? UUID(),
                backend: mintRef.rawString
            ) {
                // Hand the row's identity to the header memo BEFORE the selection
                // moves: `currentConversationID` going non-nil gates the picker
                // off and hands the title to `detailVM`, whose fresh VM would
                // otherwise open on the generic "Personal AI" placeholder while
                // its resolve walks the store.
                //
                // Deliberately ABOVE the ownership guard, not between it and the
                // commit it protects — that guard must be the last thing before
                // the selection moves, with no suspension in between. The cost is
                // that an abandoned mint leaves one stale memo entry keyed by a
                // deleted UUID: bounded, never looked up again, and cheaper than
                // reopening the race this guard exists to close.
                await ConversationDetailViewModel.seedHeaderIdentity(
                    for: fresh,
                    ref: mintRef,
                    hasTurns: false
                )
                guard ComposerMintOwnership.resolve(
                    sealedConversationID: expectedConversationID,
                    activeConversationIDAfterMint: currentConversationID
                ) == .adoptFreshConversation else {
                    // `createConversation` suspends. If the user selected an
                    // existing conversation while the empty row was being
                    // minted, never steal the selection back to the mint.
                    // Delete only our unused empty row through the store's
                    // normal single-conversation path.
                    try? await ConversationStore.shared.deleteConversation(id: fresh.id)
                    if expectedRef != nil {
                        detailVM?.reportComposerDispatchRejection()
                    } else {
                        composerDraft = appendingTranscript(text, to: composerDraft)
                        showSendFailedAlert = true
                    }
                    return false
                }
                currentConversationID = fresh.id
                // AFTER the adopt-guard and the commit, mirroring the macOS twin in
                // `MenuBarCoordinator.handleTypedText`: this records that a row was
                // actually minted and adopted, not merely that one was attempted.
                mintedRef = mintRef
            } else {
                // Mint failure (rare Core Data write error, e.g. disk-full).
                // Sealed composer sends retain their own draft/tiles until this
                // returns true. Legacy voice paths still need the historical
                // host-side text restoration below.
                if expectedRef == nil {
                    composerDraft = appendingTranscript(text, to: composerDraft)
                }
                showSendFailedAlert = true
                return false
            }
        }
        guard let conversationID = currentConversationID else { return false }
        if let expectedConversationID,
           conversationID != expectedConversationID {
            detailVM?.reportComposerDispatchRejection()
            return false
        }
        if let expectedRef {
            guard let raw = try? await ConversationStore.shared
                .fetchConversation(id: conversationID)?.backend,
                  RemoteAgentRef(rawString: raw) == expectedRef else {
                detailVM?.reportComposerDispatchRejection()
                return false
            }
        }
        if detailVM?.conversationID != currentConversationID { syncDetailVM() }
        guard currentConversationID == conversationID,
              let vm = detailVM,
              vm.conversationID == conversationID else { return false }
        if let expectedRef {
            let accepted = await vm.submitUserTurnAwaitingLocalAcceptance(
                text,
                modality: modality,
                attachments: attachments,
                expectedRef: expectedRef,
                expectedFileLaneID: expectedFileLaneID
            )
            // Record the gateway ONLY once the turn is durably appended. Everything
            // above this line can still reject — the VM going busy, the route or
            // file lane moving, the append failing — and a rejected turn is not a
            // conversation the user started.
            //
            // Inline, never a detached `Task`: the pointer is cleared whenever the
            // user states fresh gateway intent (choosing a default, forgetting a
            // gateway), and an unordered write could land after such a clear and
            // resurrect the value it was meant to retire.
            if accepted, let mintedRef {
                await SettingsManager.shared.setLastUsedRemoteAgentRef(mintedRef)
            }
            return accepted
        }
        // Legacy voice/retry path: `sendUserTurn` is `Void` and this branch returns
        // `true` unconditionally, so there is no acceptance signal to hang a
        // last-used write on. Deliberately NOT recorded — this lane is a retry of
        // something already sent, not a fresh statement of which gateway to use.
        await vm.sendUserTurn(text, modality: modality, attachments: attachments)
        return true
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
            pendingRetryIsRetryable = true
            withAnimation { hasPendingRetry = false }
            return
        }

        // ATOMIC snapshot — (presetID, apiKey, provider, customModel,
        // customConfig) in one actor hop, mirroring `DictationService.retryLast`.
        // The old `getAPIKey()` + bare `lookup` pair both raced a concurrent
        // preset switch AND dead-ended Apple on-device / keyless custom
        // endpoints on "No STT API key set" (no key is needed for either).
        let snapshot = await SettingsManager.shared.activeSTTSnapshot()
        // The key question through `STTKeyReadiness`, which keeps the two
        // readings of a nil key apart — the Apple / keyless-endpoint arms live
        // inside its `requiresKey`, so this is one call and not three branches.
        // A nil `snapshot.apiKey` means an empty slot OR a Keychain that could
        // not answer, and this card is exactly where the difference bites: the
        // "no key set" sentence sends a user whose key is merely unreadable to a
        // settings screen where they will find it already there, while their
        // preserved recording sits behind a card that says the wrong thing about
        // why it hasn't sent. Neither arm clears `PendingRetryStore`, so the
        // words survive either way (I3, I6).
        let apiKey: String
        switch await STTKeyReadiness.resolve(
            presetID: snapshot.presetID,
            snapshotKey: snapshot.apiKey,
            provider: snapshot.provider,
            customConfig: snapshot.customConfig
        ) {
        case .ready(let key):
            apiKey = key
        case .notConfigured:
            presentRetryError(String(localized: "No STT API key set. Open Settings to add one."))  // xcstrings
            return
        case .unreadable:
            // Re-keyed and surfaced exactly as the STT `catch` below does it, so
            // the card explains the failure the user is looking at NOW and its
            // Troubleshoot chip points at the right code. 75 is retryable, so the
            // banner is not sticky and the Retry affordance stays live — which is
            // the honest affordance here, because an unlock makes the identical
            // bytes succeed.
            pendingRetryErrorCode = AppError.sttKeyUnreadable.errorCode
            pendingRetryIsRetryable = AppError.sttKeyUnreadable.isRetryable
            // The CAUSE LINE ONLY, not `descriptionWithRecovery`. 75's cause
            // line already carries its own remedy ("unlock it and try again") —
            // written that way for the Shortcut lane, which renders
            // `errorDescription` alone and has no second slot; `.sttMissingAPIKey`
            // (23) reads the same way. So appending `recoverySuggestion` tells
            // this user to unlock twice — and its second half ("open Conduck and
            // retry") is addressed to someone who is NOT in the app, while this
            // card is rendered inside it, beside a live Retry button. The same
            // choice the wrist makes for the same sentence, and the same one
            // `DictationService` makes on macOS.
            presentRetryError(
                AppError.sttKeyUnreadable.errorDescription ?? "",
                sticky: !AppError.sttKeyUnreadable.isRetryable
            )
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
            pendingRetryIsRetryable = true
            withAnimation { hasPendingRetry = false }
            // The recovered transcript continues into the converse path.
            await sendTurn(response.text)

        } catch let error as AppError {
            // Re-key the card to the failure the user is looking at NOW, not the
            // one that armed the store: the Troubleshoot chip pointed at the
            // arming code, so a retry that died on a certificate opened
            // Diagnostics on the transcription outage instead. The message
            // carries cause AND remedy — this card has no second slot, and the
            // certificate verdicts keep their whole actionable half there.
            pendingRetryErrorCode = error.errorCode
            pendingRetryIsRetryable = error.isRetryable
            let message = error.descriptionWithRecovery(for: detailVM?.boundRef ?? pickerSelectedRef)
            presentRetryError(
                message.isEmpty ? String(localized: "Couldn't send — try again in a minute.") : message,  // xcstrings
                sticky: !error.isRetryable
            )
        } catch {
            presentRetryError(String(localized: "Couldn't send — try again in a minute."))  // xcstrings
        }
    }

    /// Show the retry card's secondary error line.
    ///
    /// `sticky` keeps it up: on a terminal verdict this line IS the remedy, and
    /// the Retry button is gone, so auto-dismissing after 3.5 s would clear the
    /// only instruction on screen and leave a card that explains nothing. It
    /// clears on the next refresh, alongside the retryability flag it belongs to.
    @MainActor
    private func presentRetryError(_ message: String, sticky: Bool = false) {
        withAnimation { retryErrorMessage = message }
        guard !sticky else { return }
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
