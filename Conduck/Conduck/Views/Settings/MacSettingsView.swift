// SPDX-License-Identifier: Apache-2.0

#if os(macOS)
// Conduck
// MacSettingsView.swift
//
// The macOS Settings SCREEN — a full-window MODE SWAP off the unified
// `MainWindowView` (settings is neither its own `Window` nor a sheet: the shell
// renders this INSTEAD OF the conversation split view while `showingSettings`).
// A plain `HStack` (sidebar `List(selection:)` of a `Category` enum + `Divider`
// + detail), NOT a `NavigationSplitView` (the stable 4-item sidebar needs no
// column-collapse and each category nests its own `NavigationStack`; a split
// view would only add unwanted collapse/title-bar chrome — second-opinion
// confirmed, holds even now that it's no longer a fixed-size sheet). Fills the
// window (`.frame(maxWidth:.infinity, maxHeight:.infinity)`), gradient
// background, `.preferredColorScheme(.dark)`, Esc / Done returns via `onDone`.
//
// Dismissal is an `onDone` CALLBACK (the shell flips `showingSettings = false`),
// NOT `@Environment(\.dismiss)` — in a full-window root that would be the wrong
// abstraction (a fragile no-op; the window's own dismiss is the separate
// `dismissWindow` API). Nested per-category editors keep their own `dismiss()`.
//
// Takes ONE `@Bindable var viewModel: SettingsViewModel` passed in from the
// shell (NOT a fresh VM per presentation — the live edits/pills must reflect
// the same store the rest of the app reads).

import SwiftUI

struct MacSettingsView: View {
    @Bindable var viewModel: SettingsViewModel

    /// Optional starting category. Defaults to `.general`; callers that deep-link
    /// (e.g. the contextual voice-setup "use a cloud provider" escape → `.voice`)
    /// pass the category to land on. Nil keeps the default.
    ///
    /// A BINDING, and cleared the moment it is applied. This host is a full-window
    /// mode swap that does not remount, so a second deep-link arriving while
    /// Settings is open is delivered only by `.onChange` — and `.onChange` fires
    /// on CHANGE, so writing the same category twice in a row is silent. Consuming
    /// the value on delivery makes every repeat a change again: the request is
    /// one-shot, and the slot is empty once it has been served.
    @Binding var initialCategory: Category?

    /// Optional focused failure for a `.diagnostics` deep-link (the menu-bar
    /// popover's Troubleshoot hand-off). Applied to `diagnosticsRunner` on appear,
    /// BEFORE the category is selected, so the Diagnostics detail's first paint
    /// already carries the focused card.
    var initialFocus: DiagnosticsFocus? = nil

    /// Returns to the conversation view — the shell sets `showingSettings = false`
    /// (and resets the deep-link category). Invoked by Done, Esc, and the
    /// discard-confirm's Discard button.
    let onDone: () -> Void

    /// Guided-setup presentation state, OWNED by `MainWindowView` (which renders the
    /// full-window overlay at the window root). Threaded straight through to
    /// `MacPersonalAICategory`, the only category that triggers/reacts to it.
    @Binding var guidedHost: GuidedGatewayHostState

    @State private var selection: Category = .general

    /// Owned HERE (not in `MacDiagnosticsCategory`) so it survives sidebar
    /// switches: the `detail` `switch` rebuilds the category view on every change,
    /// and a self-owned runner would re-seed from empty each return — the amber
    /// Copy button flicker. This instance persists for the whole Settings session.
    @State private var diagnosticsRunner = DiagnosticsRunner()

    /// Owned HERE for the same reason as the runner above: the `detail` `switch`
    /// rebuilds the Usage category on every sidebar change, and a self-owned
    /// model would refetch and re-aggregate the whole attempt ledger each
    /// return. Constructing it is free — it fetches nothing until the Usage
    /// screen calls `start()` — so building one for a session that never opens
    /// Usage costs nothing either. Deliberately NOT pre-warmed the way
    /// Diagnostics is: Diagnostics pre-reads to kill a visible reflow, whereas
    /// this one would be a whole-ledger Core Data sweep for a screen nobody may
    /// open.
    @State private var usageModel = UsageDashboardModel()

    /// Drives the unified "Discard changes?" confirm shared by every outer exit
    /// (Done, Esc, sidebar switch) when a buffered editor has unsaved edits.
    @State private var showingDiscardConfirm = false

    /// The category the user tried to switch to while an editor was dirty. Non-nil
    /// ⇒ Discard applies it; nil ⇒ Discard dismisses the whole sheet (Done/Esc).
    @State private var pendingSelection: Category?

    enum Category: String, CaseIterable, Identifiable {
        case general
        case personalAI
        case voice
        case usage
        case diagnostics
        case about

        var id: String { rawValue }

        var title: LocalizedStringResource {
            switch self {
            case .personalAI:   return LocalizedStringResource("settings.mac.personalAI.title", defaultValue: "Personal AI")
            case .voice:        return LocalizedStringResource("settings.voice.detail.title", defaultValue: "Voice")
            case .general:      return LocalizedStringResource("settings.mac.general.title", defaultValue: "General")
            case .usage:        return UsageDashboardIdentity.title
            case .diagnostics:  return LocalizedStringResource("diagnostics.title", defaultValue: "Diagnostics")
            case .about:        return LocalizedStringResource("settings.mac.about.title", defaultValue: "About")
            }
        }

        var systemImage: String {
            switch self {
            case .personalAI:   return "brain.head.profile"
            case .voice:        return "waveform"
            case .general:      return "gearshape"
            case .usage:        return UsageDashboardIdentity.systemImage
            case .diagnostics:  return "stethoscope"
            case .about:        return "info.circle"
            }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            LinearGradient(
                colors: [AppColors.gradientStart, AppColors.gradientEnd],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
        }
        .preferredColorScheme(.dark)
        // Pre-warm Diagnostics OFF-SCREEN. Settings always opens on General (or a
        // deep-link to Voice/Personal AI — never Diagnostics), so `MacDiagnosticsCategory`
        // isn't mounted yet and this mutation is invisible. It finishes the local
        // auto-reads before the user can reach the Diagnostics tab, so the first
        // Diagnostics paint IS the final layout — no section-insert reflow, no amber
        // Copy-button jump (the first-open flicker). Idempotent: the runner's
        // `autoReadStarted` latch makes the later `DiagnosticsContent.task` a no-op.
        // Local reads only (config shape · permission STATUS · NWPathMonitor · iCloud
        // account status) — zero prompts, zero user-server egress, zero cost.
        .task { await diagnosticsRunner.runAutoReads() }
        // Keep the PERSISTENT Diagnostics runner in sync with provider/permission
        // changes made in OTHER categories (e.g. switching STT in the Voice tab).
        // The runner outlives the category switch, so re-derive it HERE — while the
        // user is still off the Diagnostics tab — and the next visit paints fresh
        // config with no visible reflow. Cheap + local; no network re-probe.
        //
        // Gated to when Diagnostics is NOT the visible tab: when it IS, the mounted
        // `DiagnosticsContent` runs its OWN `.settingsDidChangeRemotely` observer on
        // this same runner, so firing here too would double the rebuild.
        .onReceive(NotificationCenter.default.publisher(for: .settingsDidChangeRemotely)) { _ in
            guard selection != .diagnostics else { return }
            Task { await diagnosticsRunner.refreshConfig() }
        }
        // Belt-and-braces: a fresh presentation starts with no open editor, so
        // clear any stale flag that could otherwise lock the exits. Honor a
        // deep-link `initialCategory` (e.g. voice-setup → Voice) on first appear.
        .onAppear {
            viewModel.editorHasUnsavedChanges = false
            // Apply a menu-bar Troubleshoot hand-off BEFORE selecting the category,
            // so the persistent runner already carries the focus when the
            // Diagnostics detail first paints (no card insert mid-layout). Setting
            // `focusedRef` here also lets the pre-warm `runAutoReads()` build the
            // gateway rows already focused-and-sorted.
            if let initialFocus {
                diagnosticsRunner.setFocus(ref: initialFocus.ref, code: initialFocus.errorCode)
            }
            if let initialCategory {
                selection = initialCategory
                // Served — empty the slot, so the next deep-link to this same
                // category still reads as a change to `.onChange` below.
                self.initialCategory = nil
            }
        }
        // Settings ALREADY OPEN when a menu-bar Troubleshoot fires: the host doesn't
        // remount, so `.onAppear` won't re-run and the hand-off would be a dead no-op.
        // React to the live `initialFocus` change (nil→focus) instead. Scoped to
        // diagnostics — `initialFocus` is non-nil ONLY for the Troubleshoot hand-off,
        // never the personalAI/voice category deep-links.
        .onChange(of: initialFocus) { _, focus in
            guard let focus else { return }
            diagnosticsRunner.setFocus(ref: focus.ref, code: focus.errorCode)
            selection = .diagnostics
        }
        // The same problem for the CATEGORY deep-link, and the same shape of
        // answer. The host is a full-window mode swap, so a deep-link arriving
        // while Settings is up re-renders this view without remounting it —
        // `.onAppear` never re-runs and the category would be a dead no-op.
        //
        // It goes through the SAME veto the sidebar's selection binding uses
        // rather than assigning `selection` outright: switching category tears a
        // buffered editor down, and a deep-link is not permission to discard a
        // half-typed token without asking.
        //
        // CONSUMED ON DELIVERY, on every branch. `.onChange` fires on change, and
        // the shell holds the deep-link slot until Settings exits — so a second
        // request for the category already sitting there would write the same
        // value, fire nothing, and be as inert as it was before this reaction
        // existed. Emptying the slot is what makes a repeat land.
        .onChange(of: initialCategory) { _, category in
            guard let category else { return }
            self.initialCategory = nil
            // The discard alert is up and its two branches are decided by
            // `pendingSelection`: nil closes Settings, non-nil switches category.
            // Writing a target underneath it would flip what the user's Discard
            // means between reading the alert and tapping it. The sidebar's path
            // to the same state is `.disabled(showingDiscardConfirm)` for exactly
            // this reason; a deep-link gets the same answer, and is dropped rather
            // than queued — a request that navigates after an unrelated decision
            // resolves is a surprise, and the route that raised it re-arms on the
            // next refusal.
            guard !showingDiscardConfirm else { return }
            guard category != selection else { return }
            if viewModel.editorHasUnsavedChanges {
                pendingSelection = category
                showingDiscardConfirm = true
            } else {
                selection = category
            }
        }
        // ONE confirm for every outer exit (Done / sidebar switch), with copy that
        // names the actual consequence — see `outerDiscardTitle`. The editor's
        // `.onDisappear` does the actual revert.
        .alert(
            outerDiscardTitle,
            isPresented: $showingDiscardConfirm
        ) {
            Button(outerDiscardConfirmTitle, role: .destructive) {
                // Pre-clear so the teardown's `.onDisappear` doesn't re-assert the
                // flag, then either switch category (sidebar) or close (Done).
                // The `false` setter is a hard reset across the whole editor stack,
                // which is what's wanted here — both branches tear the editors down.
                viewModel.editorHasUnsavedChanges = false
                if let target = pendingSelection {
                    selection = target
                } else {
                    onDone()
                }
                pendingSelection = nil
            }
            Button(
                LocalizedStringResource("settings.editor.discard.keepEditing", defaultValue: "Keep Editing"),
                role: .cancel
            ) { pendingSelection = nil }
        } message: {
            Text(outerDiscardMessage)
        }
    }

    // MARK: - Outer discard copy
    //
    // The two branches of this confirm do very different things, so they say
    // different things. `pendingSelection == nil` means Done — Settings CLOSES and
    // the user lands back in the conversation; non-nil means a sidebar switch,
    // which stays inside Settings. The editor's own discard confirm
    // (`BufferedEditorChrome`) owns the plain "Discard changes?" wording, and this
    // one must never borrow it: an outer alert wearing the inner alert's strings is
    // indistinguishable from "discard this screen's edits", so a Discard tapped
    // three levels deep would read as a one-level undo while actually leaving
    // Settings for the chat UI.

    private var outerDiscardTitle: LocalizedStringResource {
        pendingSelection == nil
            ? LocalizedStringResource(
                "settings.editor.discard.close.title",
                defaultValue: "Discard changes and close Settings?"
            )
            : LocalizedStringResource("settings.editor.discard.title", defaultValue: "Discard changes?")
    }

    private var outerDiscardConfirmTitle: LocalizedStringResource {
        pendingSelection == nil
            ? LocalizedStringResource(
                "settings.editor.discard.close.confirm",
                defaultValue: "Discard & Close"
            )
            : LocalizedStringResource("settings.editor.discard.confirm", defaultValue: "Discard")
    }

    private var outerDiscardMessage: LocalizedStringResource {
        pendingSelection == nil
            ? LocalizedStringResource(
                "settings.editor.discard.close.message",
                defaultValue: "Your unsaved changes will be lost and Settings will close."
            )
            : LocalizedStringResource(
                "settings.editor.discard.switch.message",
                defaultValue: "Switching sections will discard your unsaved changes."
            )
    }

    /// Done: confirm first when an editor is dirty, else close immediately. Esc
    /// reaches this ONLY when no buffered editor is mounted — see the Done button's
    /// gated `.keyboardShortcut`.
    private func attemptDismiss() {
        if viewModel.editorHasUnsavedChanges {
            pendingSelection = nil   // nil ⇒ Discard returns to the conversation
            showingDiscardConfirm = true
        } else {
            onDone()
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            // Vetoing binding: switching category while an editor is dirty would
            // tear it down and silently discard — so intercept, stash the target,
            // and confirm. `get` stays authoritative on `selection`, so the row
            // snaps back if the user picks "Keep Editing".
            List(selection: Binding<Category>(
                get: { selection },
                set: { newValue in
                    guard newValue != selection else { return }
                    if viewModel.editorHasUnsavedChanges {
                        pendingSelection = newValue
                        showingDiscardConfirm = true
                    } else {
                        selection = newValue
                    }
                }
            )) {
                ForEach(Category.allCases) { category in
                    Label(category.title, systemImage: category.systemImage)
                        .tag(category)
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            // On-brand amber selection instead of the off-theme system blue, so
            // the sidebar reads as part of the warm-dark palette.
            .tint(AppColors.brandAmber)
            // Inert while the confirm is up — forces AppKit to reconcile the row
            // highlight back to `selection` on a "Keep Editing".
            .disabled(showingDiscardConfirm)

            Divider().overlay(AppColors.border)

            HStack {
                Spacer()
                Button {
                    attemptDismiss()
                } label: {
                    Text(LocalizedStringResource("settings.mac.done", defaultValue: "Done"))
                }
                // De-emphasized (was `.borderedProminent` amber): it was visually
                // out-competing the editor's plain-text Save, baiting accidental
                // discard. A quiet bordered Done lets Save win the eye; the
                // discard confirm backstops it either way.
                .buttonStyle(.bordered)
                // Inert while the confirm is up (parity with `IpadSettingsView`) —
                // Done is the button the alert is ABOUT, so it must not re-arm the
                // alert underneath it.
                .disabled(showingDiscardConfirm)
                // Esc → attemptDismiss, but ONLY on the bare category screens.
                // While a buffered editor is open, Esc belongs to that editor's
                // Cancel (`BufferedEditorChrome.macHeader`). Esc means "back out of
                // THIS screen", and Done means "leave Settings" — binding both to
                // one key makes Esc three levels deep (Personal AI → gateway editor
                // → file transfer) exit to the chat UI, which reads as a runaway
                // Discard. Depth, not dirtiness, is the right gate: a clean editor
                // shows no confirm at all, so an ungated Esc would leave Settings
                // with nothing on screen to explain it.
                .keyboardShortcut(
                    viewModel.hasMountedBufferedEditor ? nil : KeyboardShortcut.cancelAction
                )
            }
            .padding(12)
        }
        .frame(width: 200)
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .personalAI:
            MacPersonalAICategory(viewModel: viewModel, guidedHost: $guidedHost)
        case .voice:
            MacVoiceCategory(viewModel: viewModel)
        case .general:
            MacGeneralCategory(viewModel: viewModel)
        case .usage:
            MacUsageCategory(model: usageModel)
        case .diagnostics:
            MacDiagnosticsCategory(runner: diagnosticsRunner)
        case .about:
            MacAboutCategory()
        }
    }
}
#endif
