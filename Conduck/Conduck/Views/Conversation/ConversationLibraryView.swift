// SPDX-License-Identifier: Apache-2.0

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
    /// Active backend display name shown as the detail-column nav title.
    /// Host-derived (`ContentView.backendTitle`) — the bound thread's gateway
    /// inside a conversation, the picker selection in the empty/new state, and
    /// the app name when nothing is configured.
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
    /// Notify the host that the user picked a gateway BY HAND, so the host can
    /// stop a background roster refresh from reinstating the Settings default
    /// over that choice. Called after the `selectedRef` binding is written.
    let onPickBackend: () -> Void
    /// Notify the host that a NEW chat was started here, so it can retire the
    /// previous hand-pick and re-seed the picker.
    ///
    /// Must be an ACTION callback, not something the host derives from
    /// `selectedConversationID`: `startNewConversation()` only writes `nil`, so
    /// pressing New while already on the empty state is a nil → nil write that no
    /// `onChange` observes — and that is exactly the "pick a gateway, change your
    /// mind, press New again" gesture. All four iPad entry points (list callback,
    /// sidebar button, detail toolbar, ⌘N) funnel through that one function.
    let onStartNewConversation: () -> Void
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
    /// `.searchable`, which iOS forces into the nav-bar area above any pinned
    /// header) and threaded through `externalSearchText` so the custom
    /// `SidebarSearchField` in the header drives filtering — mirrors
    /// `MainWindowView.sidebarSearch`.
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
    /// Whether the user wants the sidebar column up in THIS window.
    ///
    /// Scene-scoped rather than view-scoped, for two reasons. A collapse outlives
    /// this view being rebuilt — a narrow multitasking window flips the
    /// horizontal size class, which tears the view down and puts it back, and a
    /// `@State` default would re-impose "sidebar up" every time and throw the
    /// user's answer away. And each iPad window keeps its OWN answer
    /// (`UIApplicationSupportsMultipleScenes` is true), the way each macOS window
    /// keeps its own sidebar, which a shared app-wide preference could not do.
    ///
    /// Defaults to `true`, so a window that has never been told otherwise opens
    /// with the history up, matching the macOS window. That is a product choice,
    /// not a measurement.
    ///
    /// MEASURED on an iPad Pro 12.9-inch (6th gen), iPadOS 26.5 simulator: a
    /// collapse survives backgrounding and re-foregrounding the process, and
    /// survives a rotation round-trip. A COLD launch (process terminated, then
    /// relaunched) opens with the sidebar up again — scene restoration does not
    /// carry the value across a kill, which is iOS's own policy for a scene the
    /// user or the tooling ended, and lands on the same sidebar-up default. The
    /// multitasking rebuild is NOT exercised: iPadOS Split View and Stage
    /// Manager cannot be driven from the probe harness.
    @SceneStorage("conversationLibrary.sidebarUp") private var sidebarUp: Bool = true
    /// Whether the sidebar column's own view tree is currently mounted, reported
    /// by that column's `.onAppear`/`.onDisappear`. A SECOND, independent signal
    /// from `sidebarUp`: the stored flag is a statement of INTENT, this one is a
    /// statement about the view tree. See `sidebarBarOnScreen` for why both are
    /// needed. Starts `true` because the column is mounted at first render
    /// whenever `sidebarUp` is.
    @State private var sidebarColumnMounted = true
    /// The binding `NavigationSplitView` reads and writes. Derived from
    /// `sidebarUp` rather than held as `@State` so the value the split view sees
    /// and the value that persists can never disagree.
    ///
    /// The getter emits only `.all` or `.detailOnly` — never `.automatic` — so
    /// the split view is never handed a value whose meaning depends on the
    /// device. The setter treats ONLY `.all` and `.doubleColumn` as "sidebar up";
    /// `.detailOnly`, `.automatic`, and anything a future OS adds record as down,
    /// which routes compose to the detail bar. That asymmetry is the fail-safe
    /// direction — see `sidebarBarOnScreen`.
    private var columnVisibility: Binding<NavigationSplitViewVisibility> {
        Binding(
            get: { sidebarUp ? .all : .detailOnly },
            set: { newValue in
                let up = (newValue == .all || newValue == .doubleColumn)
                sidebarUp = up
                // Trust the intent immediately on the way UP, so the detail copy
                // of compose is gone before the sidebar column's bar animates in
                // rather than overlapping it for the length of the transition.
                // The way DOWN needs no equivalent: the column unmounting is what
                // removes the sidebar copy, and `.onDisappear` reports it.
                if up { sidebarColumnMounted = true }
            }
        )
    }
    /// True exactly while the SIDEBAR column's own nav bar can host compose.
    /// Both signals must agree, and disagreement resolves toward "not on screen".
    ///
    /// The failure that matters here is ZERO compose buttons — a user with no way
    /// to start a chat. The detail bar is on screen in every column state, so
    /// ambiguity must send compose there; believing an `.all` binding while the
    /// column is actually gone is the one outcome that strands the user, and a
    /// transient duplicate is a far better failure than that.
    ///
    /// `sidebarUp` alone is not sufficient, because it is what the SYSTEM writes
    /// back through the binding. That write-back is reliable on the probed
    /// device (see `LeadingToolbarChrome`'s header), but it presents this sidebar
    /// as a DISPLACING column, so it cannot exercise an overlay-style dismissal —
    /// a route by which the column could leave the screen without the binding
    /// being written. `.onDisappear` is what covers that route.
    ///
    /// THE RESIDUAL, stated plainly: if such a route exists AND SwiftUI keeps the
    /// column mounted through it, both signals read "up" while no sidebar bar is
    /// on screen, and compose goes with the bar that is not there — zero reachable
    /// compose, the one failure this pair exists to prevent. Nothing measured here
    /// produces that route, and nothing measured here rules it out either.
    private var sidebarBarOnScreen: Bool { sidebarUp && sidebarColumnMounted }
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
        NavigationSplitView(columnVisibility: columnVisibility) {
            ConversationListView(
                onSelect: { id in
                    selectedConversationID = id
                },
                // The pinned header (safeAreaInset below) owns the custom search
                // field, so suppress the toolbar New item and drive the list's
                // filter via `externalSearchText` (no native `.searchable`). New
                // is toolbar chrome on whichever column's bar is on screen
                // (`LeadingToolbarChrome`, attached to BOTH columns below, one
                // per sidebar state) — which is why no `onNewConversation` is
                // passed: nothing here would call it, and
                // `newConversationInToolbar: false` keeps this list's own New
                // from ever doubling it. Delete-All renders as a bare trash
                // button like iPhone (`deleteAllInMenu: false`), docked at this
                // bar's LEADING edge (`deleteAllLeading: true`) — the far end
                // from the compose/toggle pair at the trailing edge, so the
                // destructive action is not adjacent to the controls the user
                // reaches for constantly. Its 4pt inset from the column is the
                // system's; the pinned header above matches it rather than the
                // reverse (see `ConversationListView.deleteAllPlacement` for the
                // levers probed, and the `.safeAreaInset` below for the match).
                // (Args in declaration order.)
                showsToolbarActions: true,
                externalSearchText: $sidebarSearch,
                customGateways: customGateways,
                configuredRefs: configuredRefs,
                // iPad sidebar is always-visible (not a sheet), so the footer
                // row flips Settings directly — no deferred-after-dismiss flag.
                // No deep-link: the footer row opens the Settings root list.
                onOpenSettings: { onOpenSettings(nil) },
                newConversationInToolbar: false,
                deleteAllInMenu: false,
                deleteAllLeading: true,
                // Persistent split-view sidebar: highlight the active thread's row.
                selectedConversationID: selectedConversationID
            )
            // Pinned header: the same `SidebarSearchField` component the macOS
            // window uses. The list's native `.searchable` is suppressed (we
            // pass `externalSearchText`), so this band — not the nav bar — owns
            // search, sitting tight under the slim Delete-All bar with no wasted
            // large-title band. The card background is what makes it read as
            // pinned against the scrolling list below.
            //
            // THE 4pt INSET IS THE SIDEBAR'S ONE LEADING EDGE, and it is 4 here
            // where the macOS window keeps 12, because only this column carries
            // a control at the leading edge of the bar directly above it —
            // Delete-All, which macOS suppresses entirely
            // (`showsToolbarActions: false`), so there is nothing there to align
            // to on that surface. iPadOS pins a `.topBarLeading` item 4pt inside
            // the column and holds it there; nothing this app declares insets it
            // further (`ConversationListView.deleteAllPlacement` carries the
            // levers built and probed). So the only edge under this file's
            // control is the capsule's, and matching it to the bar is what
            // removes the step. MEASURED on an iPad Pro 12.9-inch (6th gen),
            // iPadOS 26.5, portrait, sidebar column x 10–330 (`final-probe/`):
            //
            //   inset 12 (`E0-baseline`)   capsule edge 22.0   magnifier x 36.0
            //   inset  4 (`E6-capsule-inset4`)          14.0             28.0
            //
            // against a Delete-All button frame that stays at x=14.0 and a trash
            // GLYPH whose leftmost lit pixel column is 27.5 in both. At 4 the
            // capsule's edge lands on the button's, the magnifier lands on the
            // trash, and the column reads as one aligned edge instead of two.
            .safeAreaInset(edge: .top) {
                SidebarSearchField(text: $sidebarSearch)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 8)
                    .background(AppColors.cardBackground)
            }
            // Compose, immediately LEFT of the system toggle at the sidebar's
            // trailing edge, flush against the divider — the macOS window's
            // arrangement, and the reason Delete-All takes the leading edge
            // instead. This bar dies with its column, so the detail column
            // carries the same action while the sidebar is down; the two are
            // mutually exclusive by `sidebarBarOnScreen`, never both.
            // Deliberately UNCONDITIONAL here: the column's unmount is what
            // removes it, so this copy cannot outlive the bar it lives in — and
            // gating it on the same flag that gates the detail copy would make
            // both answers come from one signal, which is precisely what
            // `sidebarBarOnScreen` refuses to do. `LeadingToolbarChrome`'s
            // header carries the measurements behind both halves.
            .toolbar {
                LeadingToolbarChrome(column: .sidebar) { startNewConversation() }
            }
            // The view-tree half of `sidebarBarOnScreen`. Reports what is
            // actually mounted, so a sidebar that leaves the screen by a route
            // that does not write the binding still hands compose to the detail
            // bar instead of taking it off screen with the column.
            //
            // A COVER IS NOT A COLLAPSE, and iPadOS agrees: with an NSLog on
            // each callback, presenting AND dismissing the Settings
            // `.fullScreenCover` over this split view fired NEITHER callback,
            // while collapsing the sidebar in the same session fired
            // `.onDisappear` and re-expanding fired `.onAppear`
            // (`final-probe/F4-cover-vs-collapse.txt`). So the cover cannot flip
            // this flag under a sidebar that is genuinely up, and cannot mount a
            // second compose item across its present/dismiss animation.
            .onAppear { sidebarColumnMounted = true }
            .onDisappear { sidebarColumnMounted = false }
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
            // Compose, immediately right of the sidebar-reveal control that
            // iPadOS pins leading-most in this bar. THIS is the copy that
            // survives ambiguity: the detail bar is on screen in every column
            // state, so it carries compose whenever `sidebarBarOnScreen` is not
            // certain the sidebar's own bar does — including the values that
            // merely fail to say so. `.topBarLeading` rather than `.navigation`
            // is what keeps a conditionally-mounted item leading in a bar that
            // is already up; `LeadingToolbarChrome`'s header carries the frames.
            if !sidebarBarOnScreen {
                LeadingToolbarChrome(column: .detail) { startNewConversation() }
            }
            ToolbarItem(placement: .principal) {
                gatewayTitleControl
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
        // Stop any in-flight capture FIRST, mirroring the macOS window's
        // `cancelWindowCapture()`. Without this a mic held in the outgoing
        // thread keeps running, and `handleVoiceResult` lands the OLD thread's
        // transcript in the NEW chat's composer. Reachable from the toolbar
        // compose button and ⌘N alike.
        switch recorder.state {
        case .recording: recorder.cancelRecording()
        case .processing, .preparingVoice: recorder.cancelProcessing()
        case .idle, .error: break
        }
        composerDraft = ""
        // A fresh new-chat session gets a fresh pre-minted conversation
        // identifier, so its first attachment cannot land in the folder of the
        // chat that came before it. No-ops while staging is live (the tap
        // arrived on top of files already minted against the current one) — a
        // real conversation switch below rotates through teardown instead.
        attachmentCoordinator.beginNewChatSession()
        selectedConversationID = nil
        hostMascot = MascotShuffleBag.next()  // fresh shuffle-bag pose for the new empty state
        // Last: the host retires the previous hand-pick and re-seeds the picker.
        // Fires even when the selection was already nil, which `onChange` cannot.
        onStartNewConversation()
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
            ConversationThreadView(viewModel: vm, settingsVM: settingsVM, contentMaxWidth: Constants.Layout.chatContentWidth, emptyMascot: hostMascot)
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
