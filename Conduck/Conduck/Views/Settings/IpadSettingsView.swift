// Conduck
// IpadSettingsView.swift
//
// iPad Settings — a FULL-SCREEN two-column `NavigationSplitView` (sidebar
// categories + detail), presented via `.fullScreenCover` from the regular-width
// branch of `ContentView`. Replaces the accidental centered ~540pt form sheet
// (SwiftUI's default for a `.sheet` at the regular size class) that wasted most
// of the iPad screen.
//
// CATEGORY PARITY with macOS `MacSettingsView`: the sidebar carries the SAME
// four categories in the same order — General (default + first) · Personal AI ·
// Voice · About — with Support folded INTO About (Discord / Feedback / Privacy /
// Terms), exactly as `MacAboutCategory` does. No invented categories (no
// Overview, no standalone Support).
//
// The three config-category detail panes REUSE the iOS detail screens
// (`GeneralSettingsView` / `PersonalAISettingsView` / `VoiceProviderListView`),
// each in its OWN `NavigationStack` so their multi-level `navigationDestination`
// pushes stay in the detail column (Apple's native iPad Settings idiom). The
// macOS `Mac*Category` views stay macOS-only, so iPad↔iPhone never fork. The
// Control Center setup-walkthrough card has no sidebar category — it rides the
// General pane (`GeneralSettingsView(showSetupCard:)`).
//
// Compact-width iPad (Slide Over / narrow split) is NOT handled here — the
// `horizontalSizeClass == .regular` gate in `ContentView` routes it to the
// iPhone push-Form `SettingsView`, sidestepping `NavigationSplitView` collapse.
//
// Width discipline: the reused grouped `Form`s already center to a readable
// column at regular width — DON'T cap them; the detail column's only job is to
// put the warm gradient behind them (they already set
// `.scrollContentBackground(.hidden)`).

#if os(iOS)
import SwiftUI
#if canImport(MessageUI)
import MessageUI
#endif

struct IpadSettingsView: View {
    @Bindable var viewModel: SettingsViewModel

    /// Optional deep-link target (e.g. the mic-gate redirect → `.voice`). Typed
    /// as the shared `SettingsView.Category` so `ContentView`'s existing
    /// `settingsInitialCategory` state flows through unchanged; mapped onto the
    /// matching sidebar `Category` on first appear.
    var initialCategory: SettingsView.Category? = nil

    /// When true (the "Connect Personal AI" deep-link), auto-open the guided cover
    /// on appear — once, only if still unconfigured (the `.task` latch). Default
    /// false keeps ordinary Settings entries unchanged.
    var autoOpenGuidedSetup: Bool = false

    /// Returns to the conversation — `ContentView` flips `showingSettings = false`
    /// (and resets the deep-link category). Invoked by Done and by Discard.
    let onDone: () -> Void

    @State private var selection: Category = .general
    /// Consume-once latch for `autoOpenGuidedSetup` (reset per presentation via the
    /// `.id(route.id)` in `ContentView`).
    @State private var didAutoOpenGuided = false

    /// Owned HERE (not in the detail `DiagnosticsView`) so it survives sidebar
    /// switches: the `detail` `switch` rebuilds the category on every change, and a
    /// self-owned runner would re-seed from empty each return — the amber Copy
    /// button flicker. Persists for the whole Settings session (mirrors macOS).
    @State private var diagnosticsRunner = DiagnosticsRunner()

    /// Hosts the guided gateway-setup full-screen cover at the split-view root.
    /// `PersonalAISettingsView` (in the detail column) drives it via a `Binding`
    /// rather than attaching the cover itself — keeping the presentation off a
    /// nested destination, consistent with iPhone `SettingsView` and macOS.
    @State private var guidedHost = GuidedGatewayHostState()

    /// Drives the unified "Discard changes?" confirm shared by every outer exit
    /// (Done, sidebar switch) when a buffered editor has unsaved edits — the
    /// same contract the macOS sidebar uses.
    @State private var showingDiscardConfirm = false

    /// The category the user tried to switch to while an editor was dirty.
    /// Non-nil ⇒ Discard applies it; nil ⇒ Discard dismisses the whole screen.
    @State private var pendingSelection: Category?

    /// Sidebar categories — name-aligned with `MacSettingsView.Category`.
    enum Category: String, CaseIterable, Identifiable, Hashable {
        case general
        case personalAI
        case voice
        case diagnostics
        case about

        var id: String { rawValue }

        var title: LocalizedStringResource {
            switch self {
            case .general:    return LocalizedStringResource("settings.general.section.title", defaultValue: "General")
            case .personalAI: return LocalizedStringResource("settings.remoteAgent.section.title", defaultValue: "Personal AI")
            case .voice:      return LocalizedStringResource("settings.voice.detail.title", defaultValue: "Voice")
            case .diagnostics: return LocalizedStringResource("diagnostics.title", defaultValue: "Diagnostics")
            case .about:      return LocalizedStringResource("settings.mac.about.title", defaultValue: "About")
            }
        }

        var systemImage: String {
            switch self {
            case .general:    return "gearshape"
            case .personalAI: return "brain.head.profile"
            case .voice:      return "waveform"
            case .diagnostics: return "stethoscope"
            case .about:      return "info.circle"
            }
        }

        /// Map a deep-link `SettingsView.Category` onto a sidebar category.
        init(_ deepLink: SettingsView.Category) {
            switch deepLink {
            case .general:    self = .general
            case .personalAI: self = .personalAI
            case .voice:      self = .voice
            }
        }
    }

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background { gradient }
        }
        .preferredColorScheme(.dark)
        // Pre-warm Diagnostics OFF-SCREEN (mirrors macOS). Settings opens on General
        // (or a deep-link to Voice/Personal AI — never Diagnostics), so the detail
        // `DiagnosticsView` isn't mounted and this mutation is invisible. It finishes
        // the local auto-reads before the user reaches the Diagnostics tab, so the
        // first Diagnostics paint IS the final layout — no section-insert reflow, no
        // amber Copy-button jump. Idempotent via the runner's `autoReadStarted` latch;
        // local reads only (no prompts, no user-server egress, no cost).
        .task { await diagnosticsRunner.runAutoReads() }
        // Guided gateway-setup cover at the split-view root (see `guidedHost`).
        // Kept off the detail-column destination so iOS reliably presents it.
        // Item-based so the content is built from the presentation VALUE (no
        // two-field commit race on the first present).
        .fullScreenCover(item: $guidedHost.presentation) { presentation in
            GuidedGatewaySetupView(
                viewModel: viewModel,
                initialPath: presentation.initialPath,
                onDismiss: { guidedHost.dismiss() },
                // Primer "Set up manually" → dismiss to the Personal AI detail
                // (already selected underneath). The guided lanes carry no manual escape.
                onPrimerManual: { guidedHost.dismiss() },
                showPrimer: !SettingsManager.hasSeenGatewayPrimer() && !viewModel.hasAnyConfiguredRemoteAgent,
                customLaneAvailable: viewModel.customGatewayCount < Constants.maxCustomGateways
            )
        }
        // A fresh presentation starts with no open editor — clear any stale flag
        // that could otherwise lock the exits. Honor a deep-link on first appear.
        .onAppear {
            viewModel.editorHasUnsavedChanges = false
            if let initialCategory { selection = Category(initialCategory) }
        }
        // "Connect Personal AI" deep-link — auto-open the guided cover after the
        // Personal AI detail mounts + state hydrates, once, only if unconfigured.
        // `.task` (not `.onAppear`) so the nested present is deferred past the
        // sheet's own presentation and never reads pre-load state.
        .task {
            guard autoOpenGuidedSetup, !didAutoOpenGuided else { return }
            didAutoOpenGuided = true
            await viewModel.awaitRemoteAgentStateLoaded()
            guard !viewModel.hasAnyConfiguredRemoteAgent else { return }
            guidedHost.present()
        }
        // ONE confirm for every outer exit (Done / sidebar switch). Reuses the
        // editor's own discard strings so the wording is identical wherever the
        // user leaves from; the editor's `.onDisappear` does the actual revert.
        .alert(
            LocalizedStringResource("settings.editor.discard.title", defaultValue: "Discard changes?"),
            isPresented: $showingDiscardConfirm
        ) {
            Button(
                LocalizedStringResource("settings.editor.discard.confirm", defaultValue: "Discard"),
                role: .destructive
            ) {
                // Pre-clear so the teardown's `.onDisappear` doesn't re-assert the
                // flag, then either switch category (sidebar) or close (Done).
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
            Text(LocalizedStringResource(
                "settings.editor.discard.message",
                defaultValue: "Your unsaved changes will be lost."
            ))
        }
    }

    /// Done: confirm first when an editor is dirty, else close immediately.
    private func attemptDismiss() {
        if viewModel.editorHasUnsavedChanges {
            pendingSelection = nil   // nil ⇒ Discard returns to the conversation
            showingDiscardConfirm = true
        } else {
            onDone()
        }
    }

    /// Switch sidebar category through the dirty-editor veto.
    private func select(_ category: Category) {
        guard category != selection else { return }
        if viewModel.editorHasUnsavedChanges {
            pendingSelection = category
            showingDiscardConfirm = true
        } else {
            selection = category
        }
    }

    private var gradient: some View {
        LinearGradient(
            colors: [AppColors.gradientStart, AppColors.gradientEnd],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        // macOS-style **Done** docked at the sidebar bottom. The Close affordance
        // lives in the detail column's top-trailing nav bar (iPhone parity) — see
        // `closeToolbar` — NOT here, so it never crowds the sidebar title/toggle.
        // The List is wrapped in a VStack so the bottom bar can sit beneath it.
        VStack(spacing: 0) {
            // iOS `List(selection:)` requires an OPTIONAL selection binding (unlike
            // macOS's non-optional form). Vetoing binding (mirrors `MacSettingsView`):
            // switching while an editor is dirty would tear it down and silently
            // discard — intercept, stash the target, confirm. `get` stays
            // authoritative on `selection`, so the row snaps back on "Keep Editing".
            List(selection: Binding<Category?>(
                get: { selection },
                set: { newValue in
                    if let newValue { select(newValue) }
                }
            )) {
                ForEach(Category.allCases) { category in
                    Label(category.title, systemImage: category.systemImage)
                        .tag(category)
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            // On-brand amber selection instead of the off-theme system blue.
            .tint(AppColors.brandAmber)
            // Inert while the confirm is up — forces the row highlight to reconcile
            // back to `selection` on a "Keep Editing".
            .disabled(showingDiscardConfirm)

            Divider().overlay(AppColors.border)

            // macOS-style bottom Done bar (mirrors `MacSettingsView`).
            HStack {
                Spacer()
                Button {
                    attemptDismiss()
                } label: {
                    Text(LocalizedStringResource("settings.mac.done", defaultValue: "Done"))
                        .foregroundStyle(AppColors.textPrimary)
                }
                // Quiet grey bordered Done — mirrors MacSettingsView (was amber-
                // tinted, which read as too attention-catching). On iOS bare
                // `.bordered` would tint the label blue, so pin it neutral.
                .buttonStyle(.bordered)
                .disabled(showingDiscardConfirm)
            }
            .padding(12)
        }
        .background { gradient }
        .navigationTitle(Text(LocalizedStringResource("settings.title", defaultValue: "Settings")))
    }

    /// Top-trailing **Close** for the detail column — same spot iPhone uses,
    /// always visible regardless of sidebar state. `.confirmationAction` renders
    /// it as the iOS 26 liquid-glass capsule. Attached to each detail
    /// `NavigationStack` root (only the root, so drill-ins keep their back
    /// button). "Close" reuses the iPhone Settings catalog string.
    @ToolbarContentBuilder
    private var closeToolbar: some ToolbarContent {
        ToolbarItem(placement: .confirmationAction) {
            Button("Close") {
                attemptDismiss()
            }
        }
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .general:
            // The iPad General pane also carries the Control Center setup card
            // (no sidebar Setup category — see file header).
            NavigationStack {
                GeneralSettingsView(viewModel: viewModel, showSetupCard: true)
                    .toolbar { closeToolbar }
            }
        case .personalAI:
            NavigationStack {
                PersonalAISettingsView(viewModel: viewModel, guidedHost: $guidedHost)
                    .toolbar { closeToolbar }
            }
        case .voice:
            NavigationStack {
                VoiceProviderListView(viewModel: viewModel)
                    .toolbar { closeToolbar }
            }
        case .diagnostics:
            NavigationStack {
                DiagnosticsView(runner: diagnosticsRunner)
                    .toolbar { closeToolbar }
            }
        case .about:
            NavigationStack {
                aboutPane
                    .toolbar { closeToolbar }
            }
        }
    }

    // MARK: - About pane (identity + Support links)

    /// Mirrors `MacAboutCategory`: a version row + the Support links (Discord /
    /// Send Feedback / Privacy / Terms). Self-contained — owns the feedback-email
    /// flow via the shared `feedbackMailtoURL()` / `feedbackEmailBody()` helpers.
    private var aboutPane: some View {
        AboutPane()
            .navigationTitle(Text(Category.about.title))
            .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - About pane content (identity + Support, shared-helper-backed)

/// The iPad About screen: identity (Conduck + version) + the Support links,
/// folded together exactly like the macOS `MacAboutCategory`. Owns its own
/// feedback-email state so it carries no coupling to the iPhone `SettingsView`.
private struct AboutPane: View {
    @State private var showingFeedbackEmailCopied = false
    #if canImport(MessageUI)
    @State private var showingMailComposer = false
    #endif

    var body: some View {
        Form {
            Section {
                AppIdentityHeader()
                    .padding(.vertical, 4)
            }

            // Unlabeled housekeeping: Send Feedback + the legal links. Discord
            // moves to its own honestly-labeled "Community" section below — it's
            // the community invite, not a support desk.
            Section {
                Button {
                    openFeedbackEmail()
                } label: {
                    supportRow("Send Feedback", systemImage: "envelope") // xcstrings
                }
                .buttonStyle(.plain)

                Link(destination: URL(string: Constants.websiteURL)!) {
                    supportRow("Visit conduck.com", systemImage: "globe") // xcstrings
                }
                .buttonStyle(.plain)

                Link(destination: URL(string: Constants.privacyPolicyURL)!) {
                    supportRow("Privacy Policy", systemImage: "hand.raised") // xcstrings
                }
                .buttonStyle(.plain)

                Link(destination: URL(string: Constants.termsOfServiceURL)!) {
                    supportRow("Terms of Service", systemImage: "doc.text") // xcstrings
                }
                .buttonStyle(.plain)

                // Internal push (not an external link) — Apache-2.0 §4 / MIT
                // notice preservation for the bundled packages + Silero model.
                NavigationLink {
                    LicensesView()
                } label: {
                    Label(
                        LocalizedStringResource("settings.about.licenses.title",
                                                defaultValue: "Open Source Licenses"),
                        systemImage: "doc.plaintext"
                    )
                    .foregroundStyle(AppColors.textPrimary)
                }
            }

            Section {
                Link(destination: URL(string: Constants.discordInviteURL)!) {
                    HStack {
                        Label {
                            Text(verbatim: "Discord") // brand name — not localized
                                .foregroundStyle(AppColors.textPrimary)
                        } icon: {
                            Image("discord-logo")
                                .renderingMode(.original)
                                .resizable()
                                .scaledToFit()
                                .frame(width: 24, height: 20)
                        }
                        Spacer()
                        externalGlyph
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } header: {
                Text("Community") // xcstrings
            }

            Section {
                AboutThankYouFooter()
                    .padding(.top, 44)
                    .padding(.bottom, 8)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        #if canImport(MessageUI)
        .sheet(isPresented: $showingMailComposer) {
            MailComposerView(
                recipient: Constants.feedbackEmail,
                subject: String(localized: "Conduck Feedback"), // xcstrings
                body: feedbackEmailBody()
            )
        }
        #endif
        .alert("Feedback Email", isPresented: $showingFeedbackEmailCopied) { // xcstrings
            Button("OK") { } // xcstrings
        } message: {
            Text("Send your feedback to \(Constants.feedbackEmail)") // xcstrings
        }
    }

    private var externalGlyph: some View {
        Image(systemName: "arrow.up.right")
            .font(.caption)
            .foregroundStyle(AppColors.textSecondary)
    }

    private func supportRow(_ title: LocalizedStringResource, systemImage: String) -> some View {
        HStack {
            Label(title, systemImage: systemImage)
                .foregroundStyle(AppColors.textPrimary)
            Spacer()
            externalGlyph
        }
    }

    private func openFeedbackEmail() {
        #if canImport(MessageUI)
        if MFMailComposeViewController.canSendMail() {
            showingMailComposer = true
            return
        }
        #endif
        if let mailtoURL = feedbackMailtoURL() {
            UIApplication.shared.open(mailtoURL) { success in
                if !success { showingFeedbackEmailCopied = true }
            }
        } else {
            showingFeedbackEmailCopied = true
        }
    }
}
#endif
