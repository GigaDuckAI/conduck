// Conduck
// SettingsView.swift
//
// The iOS/iPadOS Settings screen. Deliberately excludes several sections:
//   - subscription (no Pro tier in Conduck)
//   - emoji / polish / vocabulary / custom-vocabulary (no per-tone
//     personalization layer in V1)
//   - notification-sound (deferred)
//   - Smart-Context (macOS only)
//   - keyboard-shortcut (macOS — re-enable when the MenuBar surface lands)
//   - data-deletion alerts (BYO-server architecture has no remote data)
//   - preview / upgrade / restore-purchases / mail-composer extras
//     (no StoreKit — Conduck ships free, no in-app purchase)
// Includes:
//   - STT API key section (paste / validate / clear / status)
//   - Language hint section (single picker, optional)
//
// User-facing literals are wrapped in `Text("...")` (SwiftUI auto-localizes)
// or `String(localized:)` and tagged `// xcstrings` for the localization sweep.

// macOS Settings now lives in `MacSettingsView` (a `.sheet` modal hung off the
// unified `MainWindowView`), so this flat-`Form` `SettingsView` is iOS/iPadOS
// only. The shared feedback helpers moved to
// `SettingsSharedComponents.swift`.
#if os(iOS)
import SwiftUI
#if canImport(MessageUI)
import MessageUI
#endif

/// Settings screen — Conduck BYO-key, no-subscription posture.
struct SettingsView: View {
    @Bindable var viewModel: SettingsViewModel
    @State private var showSetupGuide = false

    /// Hosts the guided gateway-setup full-screen cover at the NavigationStack
    /// ROOT. `PersonalAISettingsView` is a pushed `navigationDestination`, and a
    /// `.fullScreenCover` attached there silently fails to present on iOS 26 — so
    /// the cover lives here (alongside the working `showSetupGuide` cover) and the
    /// pushed view drives it through this shared state via a `Binding`. Same
    /// `GuidedGatewayHostState` mechanism macOS uses at its window root.
    @State private var guidedHost = GuidedGatewayHostState()

    /// Consume-once latch for the `autoOpenGuidedSetup` deep-link — flips true the
    /// first time the auto-open request is processed so a later `.onAppear`/remount
    /// can't re-fire it. Reset per presentation via the `.id(route.id)` on this view.
    @State private var didAutoOpenGuided = false
    /// Programmatic navigation path for the preferences destinations. Owned here
    /// so a deep-link (`initialCategory`) can push a sub-screen on appear.
    @State private var path: [Category] = []
    @Environment(\.dismiss) private var dismiss

    /// Optional starting category. Defaults to nil (land on the root list);
    /// callers that deep-link (e.g. the mic-gate redirect → `.voice`) pass the
    /// category to push on appear. Mirrors `MacSettingsView.Category`. Default
    /// nil keeps existing call sites unaffected.
    var initialCategory: Category? = nil

    /// When true (the "Connect Personal AI" empty-state/locked-composer deep-link),
    /// auto-open the guided-setup cover on appear — once, and only if still
    /// unconfigured (see the `.task` latch). Default false keeps every ordinary
    /// Settings entry unchanged.
    var autoOpenGuidedSetup: Bool = false

    /// The deep-linkable preferences destinations — the three rows in
    /// `preferencesSection`. Kept name-aligned with `MacSettingsView.Category`
    /// (sans `.about`, which iOS has no destination row for) so a single
    /// `.voice` token deep-links on every platform.
    enum Category: String, CaseIterable, Identifiable, Hashable {
        case general
        case personalAI
        case voice

        var id: String { rawValue }
    }

    var body: some View {
        NavigationStack(path: $path) {
            content
                .navigationDestination(for: Category.self) { category in
                    switch category {
                    case .general:    GeneralSettingsView(viewModel: viewModel)
                    case .personalAI: PersonalAISettingsView(viewModel: viewModel, guidedHost: $guidedHost)
                    case .voice:      VoiceProviderListView(viewModel: viewModel)
                    }
                }
        }
        // Guided gateway-setup cover — attached to the NavigationStack itself, NOT
        // chained onto `content` (which already owns the `showSetupGuide` cover):
        // SwiftUI honors only ONE `.fullScreenCover` per view, so a second one on
        // the same view is silently dropped. A separate host view sidesteps that
        // AND keeps the cover off the pushed `PersonalAISettingsView`. The pushed
        // view only calls `guidedHost.present(initialPath:)`. Item-based so the
        // content is built from the presentation VALUE (destination rides inside
        // it — no two-field commit race on the first present).
        .fullScreenCover(item: $guidedHost.presentation) { presentation in
            GuidedGatewaySetupView(
                viewModel: viewModel,
                initialPath: presentation.initialPath,
                onDismiss: { guidedHost.dismiss() },
                // Primer "Set up manually" → the Personal AI list is already pushed
                // underneath (via `initialCategory`/the connect row), so dismissing
                // the cover lands there. The guided lanes carry no manual escape.
                onPrimerManual: { guidedHost.dismiss() },
                // First-run primer only for an unconfigured first-timer. State is
                // authoritative here: the auto-open path presents only after
                // hydration (the `.task`), and the manual connect-row lives on the
                // load-gated Personal AI screen.
                showPrimer: !SettingsManager.hasSeenGatewayPrimer() && !viewModel.hasAnyConfiguredRemoteAgent,
                customLaneAvailable: viewModel.customGatewayCount < Constants.maxCustomGateways
            )
        }
        // Honor a deep-link (e.g. the mic-gate redirect → Voice) on first appear.
        .onAppear {
            if let initialCategory, path.isEmpty { path = [initialCategory] }
        }
        // "Connect Personal AI" deep-link: after the Personal AI destination has
        // mounted AND state has hydrated, auto-open the guided cover — once, and
        // only if still unconfigured. Runs in a `.task` (not `.onAppear`) so the
        // await defers the nested present past the sheet's own presentation and
        // never reads pre-load state (Codex review — misclassify-configured fix).
        .task {
            guard autoOpenGuidedSetup, !didAutoOpenGuided else { return }
            didAutoOpenGuided = true                       // consume regardless of outcome
            await viewModel.awaitRemoteAgentStateLoaded()
            guard !viewModel.hasAnyConfiguredRemoteAgent else { return }
            guidedHost.present()
        }
    }

    private var content: some View {
        Group {
            Form {
                // iOS / iPadOS: master-detail root. Each area is a summary row
                // with trailing status that pushes its own sub-screen — first-
                // open clarity for the 90% configure-once user.
                preferencesSection
                diagnosticsSection
                setupSection
                communitySection
                aboutSection
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Settings") // xcstrings
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Close") { dismiss() } // xcstrings
                }
            }
            .fullScreenCover(isPresented: $showSetupGuide) {
                SetupGuideView()
            }
            // Feedback mail composer + copy-address fallback now live on the
            // `AboutDetailView` (Send Feedback moved one tap deeper, into About).
        }
    }

    #if os(iOS)
    // MARK: - iOS Master-Detail Root Sections
    //
    // Each row reads existing VM state for its trailing status and pushes a
    // dedicated sub-screen (`PersonalAISettingsView`, `VoiceProviderListView`).
    // The configure-once user sees a ~1-screen dashboard instead of the old
    // 7-screen flat Form. (The Apple Watch walkthrough is the exception — it
    // opens directly, no sub-screen — and now lives in the Setup section
    // alongside the Action Button guide.)

    /// Root preferences — the three configuration destinations (General ·
    /// Personal AI · Voice), each a summary row pushing its sub-screen. No
    /// header: General isn't "AI & Voice", and mirroring the macOS sidebar reads
    /// cleaner as a plain destination list. (The old `settings.root.aiSection.header`
    /// "AI & Voice" key is now unused — harmless orphan.)
    private var preferencesSection: some View {
        // Value-based rows so a deep-link (`initialCategory` → `path`) can push
        // any destination programmatically; the `.navigationDestination(for:)`
        // in `body` resolves each `Category` to its sub-screen.
        Section {
            NavigationLink(value: Category.general) {
                summaryRow(
                    title: LocalizedStringResource("settings.general.section.title", defaultValue: "General"),
                    systemImage: "gearshape",
                    status: Text(viewModel.generalSummaryShort)
                )
            }

            NavigationLink(value: Category.personalAI) {
                summaryRow(
                    title: LocalizedStringResource("settings.remoteAgent.section.title", defaultValue: "Personal AI"),
                    systemImage: "brain.head.profile",
                    status: personalAIStatus
                )
            }

            NavigationLink(value: Category.voice) {
                summaryRow(
                    title: LocalizedStringResource("settings.voice.detail.title", defaultValue: "Voice"),
                    systemImage: "waveform",
                    status: Text(viewModel.voiceSummaryShort)
                )
            }
        }
    }

    /// Personal AI trailing status — the multi-gateway summary, now sourced from
    /// the shared `viewModel.personalAISummaryShort` (the iPad Overview pane reads
    /// the same property, so the two summaries can't drift).
    private var personalAIStatus: Text {
        Text(viewModel.personalAISummaryShort)
    }

    /// Shared summary-row layout: leading icon + title, trailing status +
    /// chevron. The chevron is supplied by `NavigationLink` itself, so this
    /// renders only the icon + title + status.
    private func summaryRow(
        title: LocalizedStringResource,
        systemImage: String,
        status: Text
    ) -> some View {
        // At large Dynamic Type sizes the single-line HStack forces the title
        // to wrap mid-word and the trailing status to ellipsize. `ViewThatFits`
        // prefers the side-by-side layout while it fits at its IDEAL width
        // (`.fixedSize` stops the truncating HStack from masquerading as a fit),
        // then falls through to a stacked layout that gives both room to wrap.
        ViewThatFits(in: .horizontal) {
            HStack {
                Label(title, systemImage: systemImage)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                Spacer(minLength: 12)
                status
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            VStack(alignment: .leading, spacing: 4) {
                Label(title, systemImage: systemImage)
                    .foregroundStyle(.primary)
                status
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // Startup + Quick Captures moved to `GeneralSettingsView` (the new General
    // sub-screen) so iOS mirrors the macOS General category.
    #endif

    // MARK: - Community + About Sections

    /// Community — Discord only, under an honest header. Discord is the org-wide
    /// community invite, NOT a staffed support desk; the old "Support" header
    /// implied on-demand help we don't offer. Send Feedback + the legal links +
    /// app identity now live one tap deeper in `AboutDetailView`.
    private var communitySection: some View {
        Section {
            Link(destination: URL(string: Constants.discordInviteURL)!) {
                HStack {
                    Label {
                        Text(verbatim: "Discord") // brand name — not localized
                            .foregroundStyle(Color.primary)
                    } icon: {
                        Image("discord-logo")
                            .renderingMode(.original)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 24, height: 20)
                    }
                    Spacer()
                    Image(systemName: "arrow.up.right")
                        .font(.caption)
                        .foregroundStyle(Color.secondary)
                }
            }
        } header: {
            Text("Community") // xcstrings
        }
    }

    /// About — a standalone, header-less row pushing the identity + Send Feedback
    /// + legal links (`AboutDetailView`), mirroring the iPad About pane and macOS
    /// About category. Kept unlabeled so it reads as plain app-housekeeping,
    /// distinct from the "Community" group above. Internal push (chevron), not an
    /// external link.
    private var aboutSection: some View {
        Section {
            NavigationLink {
                AboutDetailView()
            } label: {
                Label("About", systemImage: "info.circle") // xcstrings
                    .foregroundStyle(Color.primary)
            }
        }
    }

    /// Diagnostics — a local, on-device health check for the configured gateways
    /// + voice setup. A header-less standalone row (mirrors About) placed by the
    /// config destinations, not the Setup walkthroughs: it's about what you
    /// configured. Passive — the row never probes; checks run inside the screen.
    private var diagnosticsSection: some View {
        Section {
            NavigationLink {
                DiagnosticsView()
            } label: {
                Label {
                    Text(LocalizedStringResource("diagnostics.title", defaultValue: "Diagnostics"))
                        .foregroundStyle(Color.primary)
                } icon: {
                    Image(systemName: "stethoscope")
                        .foregroundStyle(Color.primary)
                }
            }
        }
    }

    // MARK: - Setup Section (iOS / iPadOS only)
    //
    // Re-runnable device-trigger walkthroughs grouped under one "Setup"
    // header: the Action Button guide (installs the bundled Conduck shortcut +
    // binds it to a hardware trigger) and the Apple Watch guide. BOTH are
    // ALWAYS shown — Watch support is surfaced unconditionally so the user can
    // always see Conduck runs on the wrist, whether or not a Watch is currently
    // paired (no pairing-state second-guessing). The guide's welcome step
    // covers installing Conduck on the Watch first, so it never dead-ends for a
    // user who hasn't installed the watch app yet. The former standalone
    // "Devices" section was folded in here — a one-row section for the Watch
    // read as redundant next to the Action Button setup card. macOS has no
    // Action Button (its menu-bar step lives in onboarding), so no macOS Setup
    // section is offered here.

    #if os(iOS)
    private var setupSection: some View {
        Section {
            // Title + icon track the device's recommended trigger (iPad has no
            // Action Button → "Set up Control Center"; older iPhones → Back Tap),
            // matching what the guide actually teaches. The benefit subtitle is
            // trigger-agnostic, so it stays constant.
            let trigger = DeviceCapabilities.recommendedTriggerMethod
            setupCardRow(
                systemImage: trigger.setupCardIcon,
                title: Text(trigger.setupCardTitle),
                subtitle: Text("Talk to your AI from any app") // xcstrings: setup-guide
            ) {
                showSetupGuide = true
            }

            // Apple Watch — iPhone-only (a Watch pairs with an iPhone, not an
            // iPad). PUSHES `WatchSettingsView` (the iPhone-hosted Watch settings
            // host: a default-gateway control + the setup walkthrough), rather
            // than opening the walkthrough directly — the guide now opens from
            // inside that screen. Always shown on iPhone so Watch support stays
            // unconditionally discoverable (no pairing-state second-guessing).
            if UIDevice.current.userInterfaceIdiom == .phone {
                NavigationLink {
                    WatchSettingsView(viewModel: viewModel)
                } label: {
                    setupCardLabel(
                        systemImage: "applewatch",
                        title: Text(LocalizedStringResource("settings.watch.section.title", defaultValue: "Apple Watch")),
                        subtitle: Text("Talk to your AI from your wrist") // xcstrings: setup-guide
                    )
                }
            }
        } header: {
            Text("Setup") // xcstrings: setup-guide
        }
    }

    /// "Setup task" card row: leading tinted icon + title/subtitle stack +
    /// trailing chevron, wrapped in a Button. Used by the Action Button
    /// walkthrough (the Apple Watch entry is a NavigationLink that reuses
    /// `setupCardLabel` directly) so the Setup section reads as one coherent group.
    private func setupCardRow(
        systemImage: String,
        title: Text,
        subtitle: Text,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack {
                setupCardLabel(systemImage: systemImage, title: title, subtitle: subtitle)
                Spacer()
                // The Button row draws its OWN trailing chevron (a NavigationLink
                // would supply one itself — `setupCardLabel` omits it for that case).
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.tint)
            }
            .padding(.vertical, 4)
        }
    }

    /// The leading icon + title/subtitle stack of a setup card, WITHOUT a
    /// trailing chevron — shared by the Action Button Button row (which adds its
    /// own chevron) and the Apple Watch `NavigationLink` (which gets the system
    /// chevron). INTENTIONALLY accent-tinted (icon + title) so the Setup section
    /// reads as a distinct, actionable "do this" island between the neutral top
    /// card and the neutral Support list. Keep the explicit `.tint`; do NOT
    /// neutralize to Color.primary (that's Support's treatment). The subtitle uses
    /// the CONCRETE `Color.secondary` (not the hierarchical `.secondary`): inside
    /// the Action Button `Button` the automatic style tints its whole label, so a
    /// hierarchical `.secondary` would render as a hard-to-read faded blue —
    /// `Color.secondary` pins it to the same neutral gray the Apple Watch
    /// `NavigationLink` row already shows, so both subtitles match.
    private func setupCardLabel(
        systemImage: String,
        title: Text,
        subtitle: Text
    ) -> some View {
        HStack {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 2) {
                title
                    .font(.body)
                    .fontWeight(.medium)
                    .foregroundStyle(.tint)

                subtitle
                    .font(.caption)
                    .foregroundStyle(Color.secondary)
            }
        }
    }
    #endif

}

// MARK: - About detail (iPhone)

/// The iPhone About screen, pushed from the About row. Mirrors the iPad
/// `AboutPane` / macOS `MacAboutCategory` layout — identity header (icon +
/// Conduck + version) on top, then the unlabeled housekeeping group (Send
/// Feedback + Privacy + Terms) — via the shared `AppIdentityHeader`. Discord
/// stays on the Settings root (its own "Community" section); everything else
/// lives here, keeping the compact root scroll-free. Owns its own feedback-email
/// state so it carries no coupling to the parent `SettingsView`.
private struct AboutDetailView: View {
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

            Section {
                Button {
                    openFeedbackEmail()
                } label: {
                    aboutRow("Send Feedback", systemImage: "envelope") // xcstrings
                }
                .buttonStyle(.plain)

                Link(destination: URL(string: Constants.websiteURL)!) {
                    aboutRow("Visit conduck.com", systemImage: "globe") // xcstrings
                }
                .buttonStyle(.plain)

                Link(destination: URL(string: Constants.privacyPolicyURL)!) {
                    aboutRow("Privacy Policy", systemImage: "hand.raised") // xcstrings
                }
                .buttonStyle(.plain)

                Link(destination: URL(string: Constants.termsOfServiceURL)!) {
                    aboutRow("Terms of Service", systemImage: "doc.text") // xcstrings
                }
                .buttonStyle(.plain)
            }

            Section {
                AboutThankYouFooter()
                    .padding(.top, 24)
                    .padding(.bottom, 8)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .navigationTitle("About") // xcstrings
        .navigationBarTitleDisplayMode(.inline)
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

    /// Shared row: leading icon + title, trailing external glyph (each row
    /// leaves the app — mailto or web link).
    private func aboutRow(_ title: LocalizedStringResource, systemImage: String) -> some View {
        HStack {
            Label(title, systemImage: systemImage)
                .foregroundStyle(Color.primary)
            Spacer()
            Image(systemName: "arrow.up.right")
                .font(.caption)
                .foregroundStyle(Color.secondary)
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

#Preview {
    SettingsView(viewModel: SettingsViewModel())
}
#endif
