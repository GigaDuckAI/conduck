// SPDX-License-Identifier: Apache-2.0

//  Conduck
//  FileTransferSetupGuideView.swift
//
//  Agent File Transfer. The per-ref file-transfer SETUP, in two host shapes that
//  share ONE body (`FileTransferSetupContent`):
//    • As a PUSHED PAGE in Settings — `GatewayFileTransferPage`, reached from the
//      gateway editor's "File transfer" nav row (saved gateways only).
//    • As a SHEET (`FileTransferSetupGuideView`, below) — used ONLY by the composer's
//      `.needsSetup` tile mid-attach, where a modal is right (different screen).
//
//  The content is a buffered EDITOR (the gateway editor's interaction model,
//  via the shared `bufferedEditorChrome`): "Test Connection" probes the DRAFT
//  URL/pin without persisting anything, the trailing "Save" is the single
//  commit point, and Cancel/back with unsaved edits asks before discarding.
//  A staged verdict is signature-keyed (`FileTransferTestSignature`) — Save
//  carries a verdict that matches the committed tuple straight into
//  availability, so the flow "Test (pass) → Save" lands Ready without a
//  second probe.
//
//  The irreducible manual contract — the three facts Conduck needs:
//    1. a credential the server must accept (machine-minted `conduck` + 32-hex;
//       surfaced ONLY when freshly minted this session — never read back from
//       Keychain; dropped when the editor leaves the screen),
//    2. the `https://` URL the server is reachable at, and
//    3. a passing staged test of that exact tuple.
//
//  Privacy (docs/ai-context/spec.md): the client-minted credential plaintext
//  appears ONLY in (a) Keychain, (b) the deliberately-revealed, session-only,
//  masked-by-default credential row here, and (c) the system clipboard when the
//  user taps Copy — which is why that copy goes through
//  `Pasteboard.copySensitive` (bounded lifetime), never the plain unbounded
//  write. Never logged, never read back from Keychain. All chrome text is
//  localized with the `fileTransfer.` key prefix.

import SwiftUI

/// Where the setup is presented from — drives composer-only framing (escape hint
/// + dismiss-once-ready-and-clean so the staged `.needsSetup` tile can promote).
/// Default `.settings` keeps the calm Settings behavior.
enum FileTransferSetupContext {
    case settings
    case composer
}

/// Shared treatment for the secondary, bordered ACTION buttons across the gateway
/// editor + file-transfer surfaces (Generate credential / Test Connection): the
/// SF Symbol keeps the button's accent tint (system blue) for one calm pop, while
/// the title is pinned to the neutral text color so the label reads as ordinary
/// text — not an all-blue or all-amber CTA. Pair with `.buttonStyle(.bordered)`.
/// Internal (not private) so `RemoteAgentConfigBody` reuses it.
struct AccentGlyphActionLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon
                .foregroundStyle(.tint)
            configuration.title
                .foregroundStyle(AppColors.textPrimary)
        }
    }
}

// MARK: - Shared setup content (the pushed page AND the composer sheet)

/// The file-transfer editor: a `PlatformSettingsForm` of sections (status →
/// explanation → sign-in → connection → compact agent requirements → forget),
/// under the shared `bufferedEditorChrome` (Cancel · title · Save). That
/// container renders the one section tree as hand-drawn full-bleed
/// `SettingsCard`s on macOS and as the grouped `Form` everywhere else, and it
/// carries the macOS page chrome for BOTH hosts — so
/// neither the pushed page nor the composer sheet adds a rail of its own.
/// Owns the credential
/// reveal/copy state, the certificate-trust sheet, the Forget confirm
/// alert, and the URL/pin dirty detection against the VM's persisted mirrors. The
/// `.missing/.savedNeedsTest/.ready` machine drives only small touches (hide the
/// setup explanation once tested; change Test Connection to Test again; hide
/// Forget when there's nothing to forget) — NOT a branched visual structure.
struct FileTransferSetupContent: View {
    @Bindable var viewModel: SettingsViewModel

    /// The gateway ref this file-server config is bound to (per-ref, exactly like the
    /// gateway token/url). All reads/writes key through this ref.
    let ref: RemoteAgentRef

    /// Optional navigation/chrome-title override — the composer passes the gateway's
    /// display name so the user sees WHICH gateway they're configuring. Nil → "File
    /// transfer".
    var titleOverride: String? = nil

    /// Presentation context — `.composer` adds the escape hint + the
    /// ready-and-clean auto-dismiss.
    var context: FileTransferSetupContext = .settings

    /// Reveal the freshly-minted credential plaintext (masked by default).
    @State private var revealCredential: Bool = false
    /// Transient "Copied" confirmation for the credential Copy button.
    @State private var didCopyCredential: Bool = false
    /// Forget confirmation alert.
    @State private var showingForgetConfirm: Bool = false
    /// The certificate-trust sheet (the "Server certificate" row).
    @State private var showingCertSheet: Bool = false

    /// One-shot buffer hydration guard — `.onAppear` re-fires on the way back
    /// from a child presentation, and re-hydrating then would wipe live edits.
    @State private var didInitialize: Bool = false

    /// Set before a Save- or Forget-driven `dismiss()` so the chrome's
    /// `.onDisappear` discard net doesn't also revert the just-committed change.
    @State private var suppressCancelOnExit: Bool = false

    /// True from the Save tap until its commit chain completes — a SYNCHRONOUS
    /// re-entrancy gate (the VM save is multi-await, and a second tap in that
    /// window would race two commit chains), and the flag that keeps Save and
    /// Test Connection mutually exclusive while either runs.
    @State private var saving: Bool = false

    /// A Generate/Regenerate whose Keychain write failed — the one credential
    /// failure that must be SAID (the tap otherwise produces no visible change
    /// at all). Cleared on the next attempt.
    @State private var credentialWriteFailed: Bool = false

    @Environment(\.dismiss) private var dismiss

    // MARK: Derived state

    private var state: FileTransferSetupState { viewModel.fileTransferSetupState(for: ref) }
    private var status: GatewayFileLaneStatus { viewModel.fileLaneStatus(for: ref) }
    private var testRunning: Bool { viewModel.fileTransferTestRunning.contains(ref) }
    private var hasCredential: Bool { viewModel.fileServerCredentialPresent[ref] == true }
    private var mintedSecret: String? { viewModel.mintedFileServerCredentials[ref] }

    /// The staged verdict, signature-gated by the VM: nil the moment the draft
    /// diverges from the tuple the test actually probed.
    private var displayedTest: FileTransferTestResult? {
        viewModel.displayedFileTransferTestResult(for: ref)
    }

    private var trimmedURL: String {
        (viewModel.fileServerURLStrings[ref] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Unsaved edits = URL or pin buffer diverged from the persisted mirrors.
    /// The credential is deliberately OUTSIDE dirty detection — Generate/
    /// Regenerate commits to Keychain instantly (the user must hand the password
    /// to their server before any test can pass; a Cancel that "un-generated" it
    /// would strand the server holding a password Conduck forgot).
    ///
    /// Pristine until seeded, ALWAYS — `body` evaluates before `.onAppear`, so
    /// until then the URL/pin buffers are still empty while the persisted
    /// mirrors already hold values, and both comparisons below report an edit
    /// the user never made. No edit can precede seeding, so the guard costs
    /// nothing and keeps Save from flashing enabled on a pristine open.
    private var isDirty: Bool {
        guard didInitialize else { return false }
        if trimmedURL != (viewModel.fileServerPersistedURLStrings[ref] ?? "") { return true }
        let bufferPin = Self.pinComparisonForm(viewModel.fileServerCertFingerprints[ref] ?? "")
        let persistedPin = Self.pinComparisonForm(viewModel.fileServerPersistedPins[ref] ?? "")
        return bufferPin != persistedPin
    }

    private var resolvedTitle: String {
        titleOverride ?? String(localized: "fileTransfer.connected.header", defaultValue: "File transfer")
    }

    /// Composer-only auto-dismiss eligibility: the lane is Ready AND the editor
    /// is clean. Observed as ONE combined value — `.ready` can arrive while
    /// dirty (an external device's test), and the later rebaseline would not
    /// re-fire an `onChange(of: state)`.
    private var autoDismissEligible: Bool {
        context == .composer && state == .ready && !isDirty
    }

    var body: some View {
        PlatformSettingsForm {
            if context == .composer && state != .ready {
                composerEscapeSection
            }
            statusSection
            // Guidance is for SETTING UP — once the lane is Ready the configured view
            // stays calm (just the status, URL, Test Connection and Forget).
            if state != .ready {
                explanationSection
            }
            // At .ready the password is saved and PROVEN by the passing test;
            // showing generation/rotation there invites a casual rotation that
            // instantly overwrites the working Keychain credential before the
            // server has the new one — rotation at .ready is Forget → set up
            // again (a deliberate act).
            if state != .ready {
                credentialSection
            }
            connectionSection
            // The WebDAV probe cannot verify these agent-side requirements. Keep
            // them visible, but as short labeled facts rather than troubleshooting
            // paragraphs that obscure the actual controls.
            agentRequirementsSection
            if state != .missing {
                forgetSection
            }
        }
        .scrollContentBackground(.hidden)
        .scrollDismissesKeyboard(.interactively)
        // No macOS content inset here, in either host: `PlatformSettingsForm`'s
        // macOS branch owns the page chrome — its own scroll surface, the 28pt
        // window gutter and the settings rail — so both the pushed Settings page
        // and the composer sheet inherit one identical column. A host- or
        // context-specific inset on top of it would double the gutter and give
        // the two presentations different rails.
        .onAppear {
            // One-shot: seed the URL/pin buffers (and drop any stale edits a
            // previous visit abandoned) from the persisted mirrors, so the
            // editor always opens pristine.
            if !didInitialize {
                didInitialize = true
                viewModel.cancelFileTransferEdit(for: ref)
            }
        }
        // Privacy hygiene: drop the in-memory minted credential when the editor
        // leaves the screen (host-agnostic — the content owns the Form, so this
        // fires on real exits, not on row scrolling).
        .onDisappear {
            viewModel.forgetMintedFileServerCredential(for: ref)
        }
        .onChange(of: autoDismissEligible) { _, eligible in
            // Composer sheet: dismiss once the lane is Ready AND clean, so the
            // host's `onDismiss` promotes the staged tile. Never fires on a
            // dirty editor (external readiness must not eat unsaved edits).
            if eligible { dismiss() }
        }
        .interactiveDismissDisabled(context == .composer && isDirty)
        // The ONE title site for both hosts (iOS nav bar; the macOS chrome
        // header reads the same `resolvedTitle` via the chrome param below).
        .navigationTitle(Text(verbatim: resolvedTitle))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .bufferedEditorChrome(
            isDirty: isDirty,
            viewModel: viewModel,
            onDiscard: {
                await viewModel.cancelFileTransferEdit(for: ref)
            },
            suppressCancelOnExit: $suppressCancelOnExit,
            title: resolvedTitle,
            saveTitle: LocalizedStringResource("settings.editor.save", defaultValue: "Save"),
            // The only editor whose exit control varies, because it is the only
            // one with two presentations. From SETTINGS it is pushed under the
            // gateway editor → a chevron back to it. From the COMPOSER it is the
            // ROOT of its own sheet, where there is no screen behind it to point
            // at and this control is the sole exit (the sheet also disables
            // interactive dismissal while dirty) → "Cancel".
            exit: context == .composer ? .cancel : .back,
            // Save and Test stay mutually exclusive: a Save while a probe runs
            // (or vice versa) would interleave the commit chain with the
            // probe's verdict landing over the same shared state.
            canSave: { isDirty && !trimmedURL.isEmpty && !saving && !testRunning },
            onSave: { saveTapped() }
        )
    }

    /// The single commit point: validate + persist the URL and staged pin. A
    /// staged verdict matching the committed tuple carries into availability
    /// (Test-then-Save lands Ready with no second probe); on success the editor
    /// dismisses, exactly like the gateway editor's Save.
    private func saveTapped() {
        // Synchronous re-entrancy gate — see `saving`.
        guard !saving else { return }
        saving = true
        Task {
            await viewModel.validateAndSaveFileTransferConfig(urlString: trimmedURL, for: ref)
            saving = false
            if case .valid = viewModel.fileServerValidationStates[ref] {
                suppressCancelOnExit = true
                dismiss()
            }
            // .invalid → stay put; the inline error row explains.
        }
    }

    /// Both groups here name a thing the reader has never run before (a second server;
    /// a password they never chose), so both carry an `InfoTipButton` — the tip is a
    /// plain sibling of the label, which is all the placement contract needs: these
    /// labels are inert `Text`, with none of the row-action overlap that made
    /// `secretRow` split its button in two.
    private func groupLabel(_ text: LocalizedStringResource, tip: GatewayFieldTip) -> some View {
        HStack(spacing: 0) {
            Text(text)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppColors.textPrimary)
            InfoTipButton(tip: tip)
            Spacer(minLength: 0)
        }
    }

    // MARK: - Status

    /// One compact, honest status block. A passing probe is deliberately called
    /// "File server tested", never the broader "Ready": it proves WebDAV byte
    /// transport, while the agent-side requirements below remain unverified.
    /// The status block's four display values, read WHOLE from
    /// `GatewayFileLaneStatus`.
    ///
    /// No local substitution for the upload-only lane, deliberately. That state
    /// is a case of the badge enum (`.readyUploadsOnly`), fed by the PERSISTED
    /// verdict, so this screen, the editor's nav-row badge and the setup-success
    /// screen cannot disagree about a lane — and none of them can go green again
    /// on the next launch just because the session-scoped test result is gone.
    /// The live staged result still drives the inline feedback line and the
    /// checklist below, which is where a DRAFT tuple's verdict belongs (a draft
    /// test is deliberately not persisted).
    private var statusDisplay: (
        title: LocalizedStringResource, glyph: String, tint: Color,
        meaning: LocalizedStringResource?
    )? {
        guard let title = status.pageTitle, let glyph = status.systemImage else { return nil }
        return (title, glyph, status.tint, status.meaning)
    }

    @ViewBuilder
    private var statusSection: some View {
        if let display = statusDisplay {
            Section {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: display.glyph)
                        .font(.title3)
                        .foregroundStyle(display.tint)
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(display.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(AppColors.textPrimary)
                        if let meaning = display.meaning {
                            Text(meaning)
                                .font(.caption)
                                .foregroundStyle(AppColors.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    Spacer(minLength: 0)
                }
                .padding(.vertical, 3)
                // Descriptive, not activatable: the row takes the card's inset
                // and height floor but no wash, because there is no click here
                // for a wash to promise. No-op off macOS, where the grouped
                // `Form` supplies the same inset itself.
                .settingsCardPassiveRow()
            }
        }
    }

    // MARK: - Composer escape hint

    /// Composer-only: the user may be away from their gateway host. Make the no-setup
    /// escape obvious so they aren't trapped mid-attach.
    private var composerEscapeSection: some View {
        Section {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "info.circle")
                    .foregroundStyle(AppColors.textTertiary)
                Text(LocalizedStringResource(
                    "fileTransfer.composer.escape",
                    defaultValue: "Not at your server right now? Close this and remove the file to send your message without it."
                ))
                    .font(.footnote)
                    .foregroundStyle(AppColors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 2)
            .settingsCardPassiveRow()
        }
    }

    // MARK: - Explanation

    /// Context-aware framing keyed on the gateway kind. Conduck is a WebDAV client
    /// (`FileServerClient`: PUT/GET/DELETE + basic-auth over HTTPS), so the real
    /// requirement is "a WebDAV server reachable over HTTPS" — NOT rclone
    /// specifically, and NOT "any file server". OpenClaw/Hermes have the
    /// `conduck-connect` Quick-connect path; a custom gateway is the user's own, so
    /// we say plainly that any WebDAV server works.
    private var explanationText: LocalizedStringResource {
        if ref.isBuiltin {
            return LocalizedStringResource(
                "fileTransfer.manual.explanation.managed",
                defaultValue: "Quick connect usually handles this. For manual setup, run an HTTPS WebDAV server on your gateway."
            )
        } else {
            return LocalizedStringResource(
                "fileTransfer.manual.explanation.custom.v2",
                defaultValue: "Manual setup needs an agent with file tools and an HTTPS WebDAV server."
            )
        }
    }

    /// What actually travels — the one mechanism sentence, shown for EVERY
    /// gateway kind. The reference block Conduck splices into a turn
    /// (`ConverseRequest.spliceServerFileRefs`) is the whole lane in one line:
    /// the bytes go to the user's own server, and the MESSAGE carries only the
    /// file's name and the path it was saved under. Two reasons to say it out
    /// loud rather than leave it to be inferred from the setup steps:
    ///
    ///   1. Privacy. "Where do my files go?" is the first question a BYO-key
    ///      user asks, and every other sentence on this screen presupposes the
    ///      answer without ever stating it.
    ///   2. The filename is content. A name the user never chose (a shared
    ///      file's name comes from whatever app presented the share sheet) is
    ///      shown to the agent as text. The wire boundary is what keeps a
    ///      hostile one inert (`ConverseRequest.wireDisplayName`), but a user
    ///      deciding what to attach deserves to know the name travels at all.
    private var mechanismText: LocalizedStringResource {
        LocalizedStringResource(
            "fileTransfer.manual.mechanism",
            defaultValue: "Files are uploaded here so the agent can open them with its tools."
        )
    }

    private var explanationSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Text(explanationText)
                    .font(.subheadline)
                    .foregroundStyle(AppColors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(mechanismText)
                    .font(.caption)
                    .foregroundStyle(AppColors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 2)
            .settingsCardPassiveRow()
        }
    }

    // MARK: - Agent requirements the server test cannot verify

    /// A passing WebDAV test does not prove that the agent can use the files.
    /// Keep the three remaining requirements visible, but make them independently
    /// scannable; remediation and protocol detail live in Setup help or appear
    /// with an actual failed test.
    private var agentRequirementsSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                Text(LocalizedStringResource(
                    "fileTransfer.requirements.caption",
                    defaultValue: "Conduck can't verify these from this device."
                ))
                    .font(.caption)
                    .foregroundStyle(AppColors.textTertiary)

                requirementRow(
                    title: LocalizedStringResource(
                        "fileTransfer.requirements.workspace.title",
                        defaultValue: "Workspace"
                    ),
                    detail: workingFolderRequirement
                )
                requirementRow(
                    title: LocalizedStringResource(
                        "fileTransfer.requirements.reachability.title",
                        defaultValue: "Reachability"
                    ),
                    detail: LocalizedStringResource(
                        "fileTransfer.requirements.reachability.detail",
                        defaultValue: "Reachable anywhere you use this gateway."
                    )
                )
                requirementRow(
                    title: LocalizedStringResource(
                        "fileTransfer.requirements.tools.title",
                        defaultValue: "Agent tools"
                    ),
                    detail: LocalizedStringResource(
                        "fileTransfer.requirements.tools.detail",
                        defaultValue: "Can read and write files."
                    )
                )

                Link(destination: Constants.conduckConnectRepoURL) {
                    HStack(spacing: 4) {
                        Text(LocalizedStringResource(
                            "fileTransfer.guide.docsLink",
                            defaultValue: "Setup help"
                        ))
                        Image(systemName: "arrow.up.right")
                            .font(.caption)
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.tint)
                }
                .pointerLink()
            }
            .padding(.vertical, 2)
            // One passive block, not a row-level action: the "Setup help" link
            // inside it is the only live thing here and keeps its own inline
            // affordance, so a whole-row wash would point at the wrong target.
            .settingsCardPassiveRow()
        } header: {
            Text(LocalizedStringResource(
                "fileTransfer.requirements.header",
                defaultValue: "Also required"
            ))
        }
    }

    private func requirementRow(
        title: LocalizedStringResource,
        detail: LocalizedStringResource
    ) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Text(verbatim: "•")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(AppColors.brandAmber)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppColors.textPrimary)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(AppColors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// The only backend-specific requirement: the served directory must match
    /// the agent's own workspace. Preserve the actionable config name/path while
    /// dropping the repeated failure narrative.
    private var workingFolderRequirement: LocalizedStringResource {
        if case .builtin(let backend) = ref {
            switch backend {
            case .hermes:
                return LocalizedStringResource(
                    "fileTransfer.requirements.workspace.hermes",
                    defaultValue: "Serves the folder configured as terminal.cwd."
                )
            case .openclaw:
                return LocalizedStringResource(
                    "fileTransfer.requirements.workspace.openclaw",
                    defaultValue: "Serves ~/.openclaw/workspace, unless you changed it."
                )
            case .openrouter:
                break
            }
        }
        return LocalizedStringResource(
            "fileTransfer.requirements.workspace.generic",
            defaultValue: "Serves the agent's working folder."
        )
    }

    // MARK: - Server credential (intent-gated, session-only)

    private var credentialSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                groupLabel(
                    LocalizedStringResource("fileTransfer.credential.header", defaultValue: "Server password"),
                    tip: GatewayFieldTips.fileServerPassword
                )
                // The helper says what to DO; what the password IS (and that
                // Conduck signs in as `conduck`) lives in the field tip.
                Text(LocalizedStringResource(
                    "fileTransfer.credential.helper.v3",
                    defaultValue: "Generate the password here, then give it to your file server — Quick connect does that for you."
                ))
                    .font(.caption)
                    .foregroundStyle(AppColors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let secret = mintedSecret {
                    credentialValueRows(secret)
                    regenerateButton
                } else if hasCredential {
                    Text(LocalizedStringResource(
                        "fileTransfer.credential.savedHidden",
                        defaultValue: "Password saved. Generate a new one to view it."
                    ))
                        .font(.subheadline)
                        .foregroundStyle(AppColors.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                        // Breathing room so this status line doesn't crowd the helper
                        // sentence above it (text-on-text otherwise reads cramped).
                        .padding(.top, 8)
                    regenerateButton
                } else {
                    generateButton
                }
                // A failed Keychain write is otherwise fully invisible (the tap
                // produces no row change) — the one credential failure that
                // must be said out loud.
                if credentialWriteFailed {
                    HStack(spacing: 6) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(AppColors.error)
                        Text(LocalizedStringResource(
                            "fileTransfer.credential.writeFailed",
                            defaultValue: "Couldn't save the password to this device's Keychain. Try again."
                        ))
                            .font(.caption)
                            .foregroundStyle(AppColors.error)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.vertical, 2)
            // A label, a helper sentence, the credential values and one or two
            // bordered actions — several independent controls in one block, so
            // it takes the inset and the floor and no wash.
            .settingsCardPassiveRow()
        }
    }

    /// Shared Generate/Regenerate action: mint + Keychain-write via the VM,
    /// reveal ONLY when the write proved out (nil = failed, nothing stored —
    /// never reveal a password that exists nowhere), and surface the failure.
    /// One closure for both buttons so the nil-guard can't drift between them.
    private func mintCredential() {
        Task {
            credentialWriteFailed = false
            let minted = await viewModel.regenerateFileServerCredential(for: ref)
            if minted != nil {
                revealCredential = true
            } else {
                credentialWriteFailed = true
            }
        }
    }

    /// Username (fixed `conduck`) + the minted password, masked behind Reveal,
    /// with Copy. Monospaced so the hex reads cleanly.
    private func credentialValueRows(_ secret: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            labeledMono(
                label: LocalizedStringResource("fileTransfer.credential.userLabel", defaultValue: "Username"),
                value: "conduck"
            )
            HStack(spacing: 8) {
                Text(LocalizedStringResource("fileTransfer.credential.passwordLabel", defaultValue: "Password"))
                    .font(.subheadline)
                    .foregroundStyle(AppColors.textSecondary)
                Spacer(minLength: 8)
                Text(verbatim: revealCredential ? secret : String(repeating: "•", count: 12))
                    .font(.system(.subheadline, design: .monospaced))
                    .foregroundStyle(AppColors.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    // Parity with the pairing sheet's setup code + QR
                    // (`PairingExportSheet`): mark the credential as private so
                    // a privacy redaction pass blanks it. Applied to the whole
                    // ternary rather than the reveal branch only — a
                    // reveal-conditional modifier would re-identify the view and
                    // animate the transition oddly, and marking the dots costs
                    // nothing.
                    .privacySensitive()
            }
            HStack(spacing: 16) {
                Button {
                    withAnimation { revealCredential.toggle() }
                } label: {
                    Text(revealCredential
                        ? LocalizedStringResource("fileTransfer.credential.hide", defaultValue: "Hide")
                        : LocalizedStringResource("fileTransfer.credential.reveal", defaultValue: "Reveal"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AppColors.brandAmber)
                }
                .inlineLinkButton()
                Button {
                    // SENSITIVE copy — the 32-hex WebDAV Basic-auth password.
                    // `Pasteboard.copy` (and the plain open-coded write this
                    // replaced) leaves it in the general pasteboard with NO
                    // expiry: on iOS that outlives the setup session and rides
                    // Universal Clipboard to the user's other devices. Same
                    // helper the pairing sheet uses for the setup code, which
                    // embeds this very credential — one secret must not get two
                    // different clipboard lifetimes.
                    Pasteboard.copySensitive(secret, expiresAfter: Self.credentialClipboardLifetime)
                    withAnimation { didCopyCredential = true }
                    Task {
                        try? await Task.sleep(for: .seconds(2))
                        await MainActor.run { withAnimation { didCopyCredential = false } }
                    }
                } label: {
                    Label(
                        didCopyCredential
                            ? LocalizedStringResource("fileTransfer.credential.copied", defaultValue: "Copied")
                            : LocalizedStringResource("fileTransfer.credential.copy", defaultValue: "Copy password"),
                        systemImage: didCopyCredential ? "checkmark" : "doc.on.doc"
                    )
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppColors.brandAmber)
                }
                .inlineLinkButton()
                Spacer()
            }
        }
    }

    private func labeledMono(label: LocalizedStringResource, value: String) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(AppColors.textSecondary)
            Spacer(minLength: 8)
            Text(verbatim: value)
                .font(.system(.subheadline, design: .monospaced))
                .foregroundStyle(AppColors.textPrimary)
        }
    }

    private var generateButton: some View {
        Button {
            mintCredential()
        } label: {
            Label(
                LocalizedStringResource("fileTransfer.credential.generate", defaultValue: "Generate credential"),
                systemImage: "key.horizontal"
            )
            .font(.subheadline.weight(.semibold))
            .labelStyle(AccentGlyphActionLabelStyle())
        }
        .buttonStyle(.bordered)
    }

    private var regenerateButton: some View {
        Button {
            mintCredential()
        } label: {
            Label(
                LocalizedStringResource("fileTransfer.credential.regenerate", defaultValue: "Regenerate credential"),
                systemImage: "arrow.triangle.2.circlepath"
            )
            .font(.subheadline.weight(.semibold))
            .labelStyle(AccentGlyphActionLabelStyle())
        }
        .buttonStyle(.bordered)
    }

    // MARK: - File-server connection (URL + certificate + Test Connection)

    /// The certificate row is a flat sibling of the URL and the test action, not a
    /// disclosure: it is ONE plain-language row whose value ("Automatic") a
    /// collapsed label could only repeat, and the gateway editor one level up
    /// already places its identical row this way (`RemoteAgentConfigBody`'s flat
    /// Connection section).
    private var connectionSection: some View {
        Section {
            urlGroup
            actionGroup
            certificateRow
        }
    }

    private var urlGroup: some View {
        VStack(alignment: .leading, spacing: 8) {
            groupLabel(
                LocalizedStringResource("fileTransfer.url.header", defaultValue: "File-server URL"),
                tip: GatewayFieldTips.fileServerURL
            )
            urlField
            urlInvalidRow
            // The footer says what to DO; WHY the file server has its own address
            // (a second service beside the gateway) lives in the field tip.
            if state != .ready {
                Text(LocalizedStringResource(
                    "fileTransfer.url.footer.manual.v3",
                    defaultValue: "Paste the https:// address your file server is reachable at."
                ))
                    .font(.caption)
                    .foregroundStyle(AppColors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 2)
        // A field block, not an activation — inset and floor only. The
        // `TextField` owns its own click target inside.
        .settingsCardPassiveRow()
    }

    private var urlField: some View {
        let binding = Binding<String>(
            get: { viewModel.fileServerURLStrings[ref] ?? "" },
            set: { viewModel.fileServerURLStrings[ref] = $0 }
        )
        return TextField(
            "",
            text: binding,
            // NOT the gateway's address — the file server is a separate service on
            // its own port (loopback 5006, fronted by its own HTTPS port). The old
            // "your-gateway.example" placeholder taught the opposite.
            prompt: Text(LocalizedStringResource(
                "fileTransfer.url.placeholder.v2",
                defaultValue: "https://your-file-server.example:8444"
            ))
        )
            .labelsHidden()
            #if os(iOS)
            .textContentType(.URL)
            .keyboardType(.URL)
            .textInputAutocapitalization(.never)
            #endif
            .autocorrectionDisabled()
            .textFieldStyle(.roundedBorder)
            // No app tint on the host Form leaves the field on the system-blue accent
            // (blue value/cursor). Pin the text neutral + the cursor to the app's amber
            // (matching the gateway editor's fields) so nothing reads as a blue link.
            .foregroundStyle(AppColors.textPrimary)
            .tint(AppColors.brandAmber)
    }

    /// Only the URL-format error (e.g. missing https://). Connection success/failure
    /// is conveyed by the Test Connection feedback below, not here.
    @ViewBuilder
    private var urlInvalidRow: some View {
        if case .invalid(let message) = viewModel.fileServerValidationStates[ref] {
            HStack(spacing: 6) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(AppColors.error)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(AppColors.error)
                    .multilineTextAlignment(.leading)
            }
        }
    }

    // MARK: - Server certificate (the trust decision, quarantined in a sheet)

    /// The row's plain-language value against the PERSISTED mirror: a buffer
    /// that diverged (in either direction) owes a Save — the persisted pin
    /// still governs connections until then. Comparison uses the canonical
    /// manual-pin form (case/colon-insensitive) so cosmetic paste differences
    /// don't read as a pending change.
    private var certRowValue: LocalizedStringResource {
        let buffer = Self.pinComparisonForm(viewModel.fileServerCertFingerprints[ref] ?? "")
        let persisted = Self.pinComparisonForm(viewModel.fileServerPersistedPins[ref] ?? "")
        if buffer != persisted {
            return buffer.isEmpty
                ? LocalizedStringResource(
                    "fileTransfer.certificate.automaticSaveRequired",
                    defaultValue: "Automatic · Save required"
                )
                : LocalizedStringResource(
                    "fileTransfer.certificate.pinnedSaveRequired",
                    defaultValue: "Pinned · Save required"
                )
        }
        return buffer.isEmpty
            ? LocalizedStringResource("fileTransfer.certificate.automatic", defaultValue: "Automatic")
            : LocalizedStringResource("fileTransfer.certificate.pinned", defaultValue: "Pinned on this device")
    }

    static func pinComparisonForm(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: ":", with: "")
    }

    /// Write-through to the VM's change-guarded staged pin buffer — persisted
    /// (and normalized) by `validateAndSaveFileTransferConfig` on Save.
    private var certPinBinding: Binding<String> {
        Binding<String>(
            get: { viewModel.fileServerCertFingerprints[ref] ?? "" },
            set: { viewModel.setFileServerCertFingerprintBuffer($0, for: ref) }
        )
    }

    /// Plain-language trust row: "Automatic" (system trust) or "Pinned on this
    /// device". Everything jargon-bearing (the fingerprint, "SPKI SHA-256") lives
    /// in `CertificateTrustSheet`. The pin is optional and only ever narrows what
    /// is accepted — a certificate this device rejects fails the test outright.
    private var certificateRow: some View {
        // Split-action row (the gateway editor's `secretRow` pattern): the ⓘ is a
        // SIBLING of the row's action, never inside it — a label Button that hugs
        // its text, the tip, then a trailing Button covering the value + chevron
        // (same action, `.accessibilityHidden` — a redundant hit area, not a
        // second thing to announce).
        HStack(spacing: 0) {
            Button {
                showingCertSheet = true
            } label: {
                Text(LocalizedStringResource(
                    "fileTransfer.certificate.row",
                    defaultValue: "Server certificate"
                ))
                    .font(.subheadline)
                    .foregroundStyle(AppColors.textPrimary)
                    // The sibling ⓘ lays the row out at the 28pt pointer floor, so
                    // without this the label is live for its ~17pt line box only
                    // and the row washes over strips that don't click.
                    #if os(macOS)
                    .frame(minHeight: MacPointer.minTarget)
                    #endif
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(Text(certRowValue))

            InfoTipButton(tip: GatewayFieldTips.serverCertificate)

            Button {
                showingCertSheet = true
            } label: {
                HStack(spacing: 8) {
                    Spacer(minLength: 8)
                    Text(certRowValue)
                        .font(.subheadline)
                        .foregroundStyle(AppColors.textSecondary)
                    Image(systemName: "chevron.forward")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(AppColors.textTertiary)
                }
                // Same 28pt floor as the label half, so the whole washed band is
                // live rather than just the value + chevron glyph runs.
                #if os(macOS)
                .frame(minHeight: MacPointer.minTarget)
                #endif
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHidden(true)
        }
        // Matches the vertical rhythm of its section siblings `urlGroup` and
        // `actionGroup`.
        .padding(.vertical, 2)
        // The split-action shape `.settingsCardRowControl()` is written for: the
        // row's sibling Buttons all perform the SAME action, so one wash on the
        // container makes the push row react as a unit instead of lighting only
        // the half under the pointer, and the modifier carries the card's inset,
        // its 48pt floor and the squared wash that lets adjacent rows meet. It
        // does not reach inside, so the trailing value Button's `Spacer` is what
        // keeps the middle of the row live, and the row action below is what
        // makes the inset band it cannot reach open the sheet rather than wash
        // and do nothing. No-op off macOS.
        .settingsCardRowControl { showingCertSheet = true }
        .sheet(isPresented: $showingCertSheet) {
            CertificateTrustSheet(fingerprint: certPinBinding)
        }
    }

    // MARK: - Test Connection (draft probe; Save is the commit)

    /// The action button + feedback, plus the staged failure checklist after a
    /// failed test. The signature-gated verdict is derived ONCE here (it runs a
    /// URL parse + fingerprint normalization) and threaded down — the body
    /// re-evaluates on every URL keystroke, and each `displayedTest` read-site
    /// would otherwise re-derive the whole draft signature.
    private var actionGroup: some View {
        let test = displayedTest
        return VStack(alignment: .leading, spacing: 8) {
            actionRow(test: test)
            // A lane whose listing stage came back anything but a clean pass
            // gets the checklist too, unasked — whether the server refused the
            // method or the probe simply could not find out. It is the only
            // surface that says WHICH stage was the partial one, and a user who
            // has just been told their server is half-usable has an obvious next
            // question the single status line cannot answer.
            if test?.isUploadOnly == true || test?.listingUnverified != nil {
                FileTransferStageChecklist(result: test)
            }
            // The staged checklist is diagnostic detail — surfaced only after a FAILED
            // test (a fully passing lane stays a single "Server test passed" line).
            if test?.success == false {
                FileTransferStageChecklist(result: test)
                // "Get help" affordance under the failure — shown only when the
                // failing stage carries a code Diagnostics can help with (the
                // failable `DiagnosticsFocus` init is the single filter). This
                // setup body is never rendered inside Diagnostics itself (only the
                // bare checklist is), so the peek isn't circular. Pass this lane's
                // gateway `ref` so Diagnostics opens focused on it.
                if let focus = DiagnosticsFocus(errorCode: test?.failure?.errorCode, ref: ref) {
                    TroubleshootButton(focus: focus)
                }
            }
        }
        .padding(.vertical, 2)
        // The bordered "Test Connection" button draws and hit-tests itself, and
        // the feedback under it is prose — nothing here is one row-wide action,
        // so the row supplies the inset and the floor and no wash.
        .settingsCardPassiveRow()
    }

    /// One easy-to-find full-width secondary action. Feedback sits below it so a
    /// long localized failure cannot squeeze the button into a narrow pill.
    private func actionRow(test: FileTransferTestResult?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            testButton
            // `isUploadOnly` is listed EXPLICITLY rather than left to the
            // `success == true && state != .ready` clause: an upload-only lane
            // does reach `.ready` (uploads are genuinely available), so that
            // clause hides it — and hiding it is precisely the failure mode
            // being fixed, a lane whose limitation is never stated anywhere.
            if testRunning
                || test?.success == false
                || test?.isUploadOnly == true
                || test?.listingUnverified != nil
                || (test?.success == true && state != .ready) {
                statusFeedback(test: test)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !hasCredential {
                Text(LocalizedStringResource(
                    "fileTransfer.test.needCredential",
                    defaultValue: "Generate a server password first."
                ))
                    .font(.caption)
                    .foregroundStyle(AppColors.textTertiary)
            }
        }
    }

    /// "Test Connection" — probes the DRAFT URL + pin (with the stored
    /// credential) without persisting anything; Save commits. Same label as the
    /// gateway editor's probe — the two surfaces share one interaction model.
    private var testButton: some View {
        Button {
            Task { await viewModel.runFileTransferTest(for: ref) }
        } label: {
            Label(
                testButtonTitle,
                systemImage: "checkmark.shield"
            )
            .font(.subheadline.weight(.semibold))
            .labelStyle(AccentGlyphActionLabelStyle())
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        // `saving` keeps Test and Save mutually exclusive — see `canSave`.
        .disabled(testRunning || saving || trimmedURL.isEmpty || !hasCredential)
    }

    private var testButtonTitle: LocalizedStringResource {
        if state == .ready {
            return LocalizedStringResource(
                "fileTransfer.connected.retest",
                defaultValue: "Test again"
            )
        }
        return LocalizedStringResource(
            "settings.fileTransfer.testConnection.button",
            defaultValue: "Test file server"
        )
    }

    /// Spinner while running, green "Server test passed" on a full pass, or a red
    /// error summary on failure (the staged breakdown shows below on failure).
    /// Takes the already-derived signature-gated verdict — editing the URL or
    /// pin makes the feedback go dark instead of describing a config the probe
    /// never saw.
    @ViewBuilder
    private func statusFeedback(test: FileTransferTestResult?) -> some View {
        if testRunning {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(LocalizedStringResource("fileTransfer.inline.checking", defaultValue: "Checking…"))
                    .font(.subheadline)
                    .foregroundStyle(AppColors.textSecondary)
            }
        } else if let test {
            if test.listingUnverified != nil {
                // THE FOURTH ANSWER: uploads proven, the other direction not
                // measured. It must not borrow the green line (which would claim
                // a check that never completed) nor the amber upload-only one
                // (which would claim the server refused). It asks for a retry,
                // because unlike a structural refusal a retry can genuinely
                // change this one.
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(AppColors.warning)
                    Text(LocalizedStringResource(
                        "fileTransfer.inline.listingUnchecked",
                        defaultValue: "Sending files works. Conduck couldn't check whether files can come back — try the test again."))
                        .font(.subheadline)
                        .foregroundStyle(AppColors.textSecondary)
                        .multilineTextAlignment(.leading)
                }
            } else if test.isUploadOnly {
                // THE THIRD ANSWER, and it must not borrow either of the other
                // two. Green "Server test passed" would let the user go on
                // expecting files back from an agent; a red failure would send
                // them debugging a file server that works. So it states the two
                // halves separately, in the order they matter: what works, then
                // what does not.
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(AppColors.warning)
                    Text(LocalizedStringResource(
                        "fileTransfer.inline.uploadOnly",
                        defaultValue: "Sending files works. This server can't list folders, so files the agent creates won't come back on their own — you'll still find them on the server."))
                        .font(.subheadline)
                        .foregroundStyle(AppColors.textSecondary)
                        .multilineTextAlignment(.leading)
                }
            } else if test.success {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(AppColors.success)
                    Text(LocalizedStringResource("fileTransfer.inline.fileServerReady", defaultValue: "Server test passed"))
                        .font(.subheadline)
                        .foregroundStyle(AppColors.textSecondary)
                }
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(AppColors.error)
                    failureMessage(test: test)
                        .font(.subheadline)
                        .foregroundStyle(AppColors.error)
                        .multilineTextAlignment(.leading)
                }
            }
        }
    }

    /// Cause AND remedy: this inline line is the only place the guide reports a
    /// failed test, so dropping `recoverySuggestion` would strand a terminal
    /// refusal (a certificate this device won't accept) with no next step.
    private func failureMessage(test: FileTransferTestResult?) -> Text {
        if let failure = test?.failure {
            return Text(verbatim: failure.descriptionWithRecovery(for: ref))
        }
        return Text(LocalizedStringResource("fileTransfer.inline.failed", defaultValue: "Test failed"))
    }

    // MARK: - Forget

    /// Destructive "Forget", styled like the gateway editor's `destructiveSection`:
    /// the whole `Label` goes red via `.foregroundStyle(AppColors.error)` (a `.bordered`
    /// + `.tint` leaves the SF Symbol on the system accent). iOS: a full-width CENTERED
    /// red row. macOS: a quiet LEFT-aligned `.plain` red text button. Tapping arms the
    /// confirm alert — nothing is erased until the user confirms.
    private var forgetSection: some View {
        Section {
            forgetButton
        }
    }

    private var forgetButton: some View {
        Button(role: .destructive) {
            showingForgetConfirm = true
        } label: {
            #if os(macOS)
            Label(
                LocalizedStringResource("fileTransfer.forget.button", defaultValue: "Forget file transfer"),
                systemImage: "trash"
            )
            .font(.subheadline)
            #else
            HStack {
                Spacer()
                Label(
                    LocalizedStringResource("fileTransfer.forget.button", defaultValue: "Forget file transfer"),
                    systemImage: "trash"
                )
                .font(.subheadline)
                Spacer()
            }
            #endif
        }
        #if os(macOS)
        // The card's own row treatment: the inset moves inside the live frame
        // and the wash squares off, so this single-row card washes edge to edge.
        .settingsCardRowButton()
        #endif
        .foregroundStyle(AppColors.error)
        .alert(
            LocalizedStringResource("fileTransfer.forget.alert.title", defaultValue: "Forget file transfer?"),
            isPresented: $showingForgetConfirm
        ) {
            Button(
                LocalizedStringResource("fileTransfer.forget.alert.confirm", defaultValue: "Forget"),
                role: .destructive
            ) {
                Task { await viewModel.clearFileTransferConfig(for: ref) }
            }
            Button(
                LocalizedStringResource("fileTransfer.forget.alert.cancel", defaultValue: "Cancel"),
                role: .cancel
            ) { }
        } message: {
            Text(LocalizedStringResource(
                "fileTransfer.forget.alert.message",
                defaultValue: "Conduck will erase the file-server URL, the generated credential, and the pin for this gateway. The files already on your server stay where they are."
            ))
        }
    }

    // MARK: - Clipboard

    /// How long the copied file-server password may live in the system
    /// clipboard. DELIBERATELY far longer than `Pasteboard.copySensitive`'s
    /// 180 s default: that default is calibrated for the pairing code, whose
    /// destination is Conduck on the user's own Mac seconds away and which is
    /// re-derivable from Keychain at any time. This password's destination is a
    /// SERVER-side auth config (rclone.conf / Caddyfile / htpasswd, plausibly
    /// over SSH, plausibly after installing the WebDAV server), routinely more
    /// than three minutes — and it is NOT re-derivable: `mintedSecret` is
    /// session-only and dropped on dismiss, after which the only recovery is
    /// Regenerate, which revokes readiness and invalidates a password the user
    /// may already have installed server-side. Too short a window trades a
    /// clipboard-residue risk for a silent empty paste into an auth file, which
    /// is the invisible-failure class this screen otherwise works hard to make
    /// loud.
    private static let credentialClipboardLifetime: Double = 900   // seconds — 15 min
}

// MARK: - Composer sheet (the ONLY remaining sheet host)

/// Thin wrapper that presents `FileTransferSetupContent` as a SHEET for the composer's
/// `.needsSetup` tile mid-attach. (In Settings the same content is a PUSHED page —
/// `GatewayFileTransferPage`.) The content itself supplies the Cancel/Save chrome,
/// the away-from-server escape hint, and the ready-and-clean auto-dismiss (so the
/// host's `onDismiss` promotes the staged tile + uploads). We NEVER auto-dismiss on
/// `.savedNeedsTest` — a saved-but-untested URL+credential would kick a doomed upload.
struct FileTransferSetupGuideView: View {
    @Bindable var viewModel: SettingsViewModel
    let ref: RemoteAgentRef

    /// Optional navigation-title override — the composer passes the gateway's display
    /// name so the user sees WHICH gateway they're configuring. Nil → "File transfer".
    var titleOverride: String? = nil

    /// Presentation context — `.composer` adds the escape hint + dismiss-on-ready.
    var context: FileTransferSetupContext = .settings

    var body: some View {
        FileTransferSetupContent(
            viewModel: viewModel,
            ref: ref,
            titleOverride: titleOverride,
            context: context
        )
    }
}
