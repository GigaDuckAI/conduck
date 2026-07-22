// Conduck
// HostedModelGatewayStepView.swift
//
// Guided gateway-setup — the HOSTED-MODEL branch (OpenRouter), reached when the
// user picks "Hosted cloud model" on `GatewayChooserStepView`. The no-server
// on-ramp: paste an OpenRouter API key + pick a model. ONLY used inside the
// guided-setup flow (`GuidedGatewaySetupView`); onboarding no longer mounts it.
//
// TWO ENTRY MODES, classified ONCE after `refreshRemoteAgentState()` hydrates the
// VM (classifying before hydration would misread a cold `configuredRemoteAgentRefSet`
// and treat a configured user as first-time):
//   • `.setup`  — OpenRouter NOT configured. First-time body: key + model +
//     Validate key + Connect. A successful Connect calls `onConnected` → the flow's
//     SHARED success screen (`GatewaySetupSuccessView`), the same confirmation every
//     self-hosted lane ends on. Partial-sync banner appears only when a synced model
//     is present with no stored key.
//   • `.manage` — OpenRouter already configured (second-time). A confirmation card
//     ("OpenRouter is set up" / "…is connected" once a probe passes) with the
//     current model + masked key, plus a "Change model or API key" button that
//     pushes the dedicated edit step (`HostedModelEditStepView`) — editing is NOT
//     inline here. Nothing connected THIS session, so there is nothing to confirm:
//     Done dismisses (`proceed`) rather than routing to success.
//
// ADVANCE IS KEYED ON THE SAVE, NEVER THE PROBE. `onConnected` fires only when
// `saveRemoteAgent` returned true — a passing `/v1/key` probe whose save then fails
// (e.g. the unsigned-sim Keychain) must never push the user onto a screen that says
// "Connected". The probe proves the KEY; only the save proves the CONFIG.
//
// The full manual gateway editor (`RemoteAgentConfigBody`, reached from the
// Settings list) is a SEPARATE surface — this screen never routes to it.
//
// Privacy: the raw key lives only in `pendingKey` + the SecureField; it flows out
// exactly once via `saveRemoteAgent` (→ Keychain), then cleared. The quiet probe
// validates the STORED key via `retestRemoteAgent` (raw key never enters the View).
// Never logged, printed, or echoed in error messages.

import SwiftUI

struct HostedModelGatewayStepView: View {
    @Bindable var viewModel: SettingsViewModel

    /// Leave the hosted step with nothing to confirm. In guided setup this is the
    /// container's `onDismiss` — it closes the whole flow. Called ONLY by manage
    /// mode's Done; a first-time connect goes to `onConnected` instead.
    let proceed: () -> Void

    /// Setup mode: the gateway is SAVED and connected — the container advances to
    /// the shared success screen. REQUIRED (non-optional) so a missing wiring is a
    /// compile error, not a silent "saved, but the user is left staring at the form
    /// with no confirmation."
    let onConnected: () -> Void

    /// Manage mode: the user tapped "Change model or API key" — the container
    /// pushes the dedicated `.hostedModelEdit` step. Unused in setup (defaults
    /// to a no-op so any setup-only mount compiles).
    let onEdit: () -> Void

    init(
        viewModel: SettingsViewModel,
        proceed: @escaping () -> Void,
        onConnected: @escaping () -> Void,
        onEdit: @escaping () -> Void = {}
    ) {
        self.viewModel = viewModel
        self.proceed = proceed
        self.onConnected = onConnected
        self.onEdit = onEdit
    }

    /// The OpenRouter built-in ref — this whole step configures exactly it.
    private let ref = RemoteAgentRef.builtin(.openrouter)

    /// First-time vs. returning. `nil` until `refreshRemoteAgentState()` lands;
    /// the body shows a placeholder until then so a cold VM can't misclassify.
    private enum EntryMode { case setup, manage }
    @State private var entryMode: EntryMode?

    /// Local SecureField buffer for the API key (setup mode). Flows out once via
    /// `saveRemoteAgent`, then cleared.
    @State private var pendingKey: String = ""

    /// Voice-key reuse is STAGED, not persisted: tapping the callout only sets
    /// this flag, and Connect commits key + model together via
    /// `StagedRemoteAgentToken.reuseVoiceKey` (the VM resolves the key from the
    /// Keychain at save/probe time — it never enters this View). Persisting on
    /// tap would store a key for a gateway that still lacks its required model.
    @State private var useVoiceKey = false

    /// Lets `.onSubmit` resign focus — Return is the dismiss/submit affordance.
    @FocusState private var keyFieldFocused: Bool

    /// Local filter for the (large) OpenRouter model catalog — buffer-only.
    @State private var modelFilter: String = ""

    /// True only while the primary save (validate→save) is in flight.
    @State private var connecting = false

    /// True only while a "Validate key" (validate-only) probe is in flight. Set
    /// SYNCHRONOUSLY at tap so a rapid double-tap can't launch two probes.
    @State private var validatingKey = false

    /// Quiet entry-probe (manage mode) outcome. `.ok` upgrades the tick + title to
    /// "connected"; `.failed` shows a non-blocking Retry. Editing/saving cancels
    /// it so a stale stored-key probe can't paint a fresh edit as verified.
    private enum ProbeState: Equatable { case idle, checking, ok, failed }
    @State private var probeState: ProbeState = .idle
    @State private var probeTask: Task<Void, Never>?

    /// The OpenRouter descriptor — supplies all policy (placeholder, required
    /// model, fixed URL). Looked up once.
    private var descriptor: RemoteAgentBackendMetadata {
        RemoteAgentBackendRegistry.lookup(id: .openrouter)
    }

    /// The configured row matching THIS ref, if any — drives the manage card name.
    private var connectedRow: PersonalAIRow? {
        viewModel.personalAIRows.first { $0.ref == ref && $0.configured }
    }

    /// Whether OpenRouter's connection probe PASSED this session (live `/v1/key`).
    private var isVerified: Bool { viewModel.remoteAgentLiveValidated.contains(ref) }

    /// True once a token is stored for this ref (masked tail present). Lets manage
    /// mode save a model-only change and lets setup mode Connect after key reuse.
    private var hasStoredKey: Bool { viewModel.remoteAgentMaskedTails[ref] != nil }

    /// Cross-device PARTIAL sync: the non-secret model arrived (iCloud KVS) but the
    /// secret key has NOT — only meaningful in `.setup` (manage means configured).
    private var isPartiallySynced: Bool {
        entryMode == .setup
            && !hasStoredKey
            && !(viewModel.remoteAgentModelStrings[ref] ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Validation state for this ref (read from the dict).
    private var validationState: KeyValidationState {
        viewModel.remoteAgentRowState(for: ref)
    }

    /// Two-way binding to the per-ref model buffer.
    private var modelBinding: Binding<String> {
        Binding<String>(
            get: { viewModel.remoteAgentModelStrings[ref] ?? "" },
            set: { viewModel.remoteAgentModelStrings[ref] = $0 }
        )
    }

    /// Honesty-aware title: "connected" ONLY once a probe passed this session;
    /// otherwise "set up" (a saved config + the `/v1/key` probe prove the KEY, not
    /// model validity or chat completion).
    private var titleText: LocalizedStringKey {
        switch entryMode {
        case .manage:
            return (probeState == .ok || isVerified)
                ? "OpenRouter is connected"   // xcstrings: hosted-model
                : "OpenRouter is set up"      // xcstrings: hosted-model
        default:
            return "Use a hosted model"       // xcstrings: hosted-model
        }
    }

    var body: some View {
        VStack(spacing: 24) {
            Image("conduck-scientist")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .onboardingMascot()

            Text(titleText)
                .onboardingScaledFont(.title, weight: .bold)
                .foregroundStyle(AppColors.textEmphasis)
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
                .padding(.horizontal, 32)

            switch entryMode {
            case .none:
                ProgressView()
                    .controlSize(.small)
                    .padding(.top, 8)
            case .setup:
                setupBody
            case .manage:
                manageBody
            }
        }
        .onboardingStepLayout {
            footer
        }
        .onChange(of: keyFieldFocused) { _, focused in
            // Freeze the pre-filled buffers once the user starts entering
            // credentials so a late iCloud-KVS reload can't revert them.
            if focused { viewModel.editorHasUnsavedChanges = true }
        }
        .onChange(of: pendingKey) { _, _ in
            // The verdict described the PREVIOUS key. The moment the USER edits, it
            // describes nothing on screen — so retract it rather than leave a red
            // line accusing a key that may now be correct. Mirrors the edit step.
            // `remoteAgentLiveValidated` is deliberately NOT cleared here (the edit
            // step doesn't either — one divergence, not two).
            //
            // `connecting` excludes the one write that is NOT a user edit: a
            // successful `connect()` blanks `pendingKey` after the save, and
            // without this guard that blanking would immediately stomp the `.valid`
            // the save just wrote back to `.unset`.
            guard !connecting else { return }
            viewModel.remoteAgentValidationStates[ref] = .unset
            // A typed character while voice-key reuse is staged switches the
            // credential source back to manual — the field is authoritative the
            // moment the user touches it.
            if useVoiceKey, !pendingKey.isEmpty { useVoiceKey = false }
        }
        .onChange(of: useVoiceKey) { _, _ in
            // Staging/unstaging swaps WHICH credential is in play: a verdict
            // earned by the other one describes nothing on screen. Mirrors the
            // typed-key retraction above (`connecting` excludes the post-save
            // teardown writes).
            guard !connecting else { return }
            viewModel.remoteAgentValidationStates[ref] = .unset
            viewModel.noteRemoteAgentSecretEdited(for: ref)
        }
        .onDisappear {
            probeTask?.cancel()
            // Only setup raises the dirty fence here (via `keyFieldFocused`).
            // Manage never sets it, so it must NOT clear it on disappear —
            // otherwise the manage→edit push could stomp the edit step's fence.
            if entryMode == .setup { viewModel.editorHasUnsavedChanges = false }
        }
        .task {
            // Hydrate FIRST, then classify — a cold `configuredRemoteAgentRefSet`
            // would otherwise misread a configured user as `.setup`.
            await viewModel.refreshRemoteAgentState()
            let configured = viewModel.isRemoteAgentConfigured(ref)
            entryMode = configured ? .manage : .setup
            if configured { runQuietProbe() }
        }
    }

    // MARK: - Setup body (.setup — first-time / partial-sync)

    @ViewBuilder
    private var setupBody: some View {
        if isPartiallySynced {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "arrow.triangle.2.circlepath.icloud")
                    .foregroundStyle(AppColors.textSecondary)
                // xcstrings: hosted-model
                Text("Synced from your other device — just add your OpenRouter key to finish.")
                    .onboardingScaledFont(.subheadline)
                    .foregroundStyle(AppColors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .glassCardBackground()
            .padding(.horizontal, 32)
        }

        VStack(alignment: .leading, spacing: 8) {
            // xcstrings: hosted-model
            Text("Paste your OpenRouter API key and pick a model — your messages go straight to OpenRouter, no middleman.")
                .onboardingScaledFont(.subheadline)
                .foregroundStyle(AppColors.textSecondary)

            // Quiet grey link (the primer's tertiary-docs treatment) — a passive
            // exit to the OpenRouter site, not a competing action: the screen's one
            // blue is the Connect fill in the footer.
            Link(destination: descriptor.docsURL) {
                HStack(spacing: 4) {
                    Text("Get an OpenRouter API key") // xcstrings: hosted-model
                    Image(systemName: "arrow.up.right")
                        .onboardingScaledFont(.caption)
                }
                .onboardingScaledFont(.subheadline, weight: .semibold)
                .foregroundStyle(AppColors.textSecondary)
            }
            .tint(AppColors.textSecondary)
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 32)

        // Offer to reuse a voice OpenRouter key when one exists and the gateway has
        // NO stored key yet. Tapping STAGES the reuse (flag only — nothing is
        // persisted): the callout hides, the key field flips to a "voice key
        // selected" row, and Connect commits key + model together.
        if entryMode == .setup,
           viewModel.openRouterVoiceKeyAvailable, !hasStoredKey, !useVoiceKey {
            OpenRouterKeyReuseCallout(
                title: LocalizedStringResource(
                    "settings.remoteAgent.openRouter.reuse.title",
                    defaultValue: "You've already set up OpenRouter for voice. Reuse that API key here?"
                ),
                buttonTitle: LocalizedStringResource(
                    "settings.remoteAgent.openRouter.reuse.button",
                    defaultValue: "Use my voice key"
                ),
                action: {
                    // No staging swap while a probe/save is mid-flight against
                    // the current credential intent.
                    guard !connecting, !validatingKey else { return }
                    useVoiceKey = true
                    // Freeze the pre-filled buffers (same fence the key field's
                    // focus raises) so a late iCloud-KVS reload can't revert the
                    // in-progress setup under the user.
                    viewModel.editorHasUnsavedChanges = true
                }
            )
            // Neutral tint: the callout's bordered button inherits it, so the pill
            // reads as a quiet secondary here instead of a second blue competing
            // with Connect. (Settings callsites keep their own default tint.)
            .tint(AppColors.textPrimary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .onboardingCardPadding()
            .glassCardBackground()
            .padding(.horizontal, 32)
        }

        VStack(spacing: 12) {
            // The staged row sits ABOVE the key field; the SecureField itself
            // stays PERMANENTLY mounted with an unchanged modifier chain. On
            // macOS a SecureField is an out-of-process NSSecureTextField, and
            // structurally mounting/unmounting it under a state toggle triggers
            // `_NSDetectedLayoutRecursion` / ViewBridge termination (see
            // SecretEntrySheet's header + the CustomSTTConfigBody history).
            // Typing in the field unstages the reuse (see `.onChange(of:
            // pendingKey)`), so the two credential sources can't disagree.
            if useVoiceKey {
                stagedVoiceKeyRow
            }
            keyField(placeholder: descriptor.tokenPlaceholder)
            OpenRouterModelPickerField(
                selection: modelBinding,
                filter: $modelFilter,
                suggestions: viewModel.remoteAgentModelSuggestions[ref] ?? []
            )
            validationStatusRow
        }
        // 32 — the CONTENT rail, matching the intro prose, the reuse callout and
        // the partial-sync banner above. At `Layout.horizontalPadding` (16 on
        // iOS) the fields rendered 16pt wider per side than the text explaining
        // them.
        .padding(.horizontal, 32)
    }

    // MARK: - Manage body (.manage — second-time, already configured)

    /// Card + a "Change model or API key" button that pushes the dedicated edit
    /// step. Editing is NOT inline — `onEdit()` is the container's `goTo`.
    @ViewBuilder
    private var manageBody: some View {
        manageCard

        Button {
            onEdit()
        } label: {
            // Neutral disclosure row (not blue): the screen's one blue is the
            // filled Done in the footer; the chevron carries the "this navigates".
            HStack {
                Text("Change model or API key") // xcstrings: hosted-model
                    .onboardingScaledFont(.subheadline, weight: .semibold)
                    .foregroundStyle(AppColors.textPrimary)
                Spacer()
                Image(systemName: "chevron.right")
                    .onboardingScaledFont(.caption)
                    .foregroundStyle(AppColors.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 32)
        .accessibilityIdentifier("settings.remoteAgent.hosted.change")
    }

    /// The connected confirmation: honesty-aware tick, current model + masked key,
    /// and the quiet-probe status line.
    private var manageCard: some View {
        let verified = probeState == .ok || isVerified
        let model = (viewModel.remoteAgentModelStrings[ref] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: verified ? "checkmark.seal.fill" : "checkmark.circle")
                    .foregroundStyle(verified ? AppColors.success : AppColors.textSecondary)
                Text(verbatim: connectedRow?.displayName ?? descriptor.displayName)
                    .onboardingScaledFont(.headline)
                    .foregroundStyle(AppColors.textPrimary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }

            if !model.isEmpty {
                summaryRow(label: "Model", value: model) // xcstrings: hosted-model
            }
            if let tail = viewModel.remoteAgentMaskedTails[ref] {
                summaryRow(label: "Key", value: tail) // xcstrings: hosted-model
            }

            // xcstrings: hosted-model
            Text("Messages go straight to OpenRouter, no middleman.")
                .onboardingScaledFont(.subheadline)
                .foregroundStyle(AppColors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            probeStatusRow
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onboardingCardPadding()
        .glassCardBackground()
        .padding(.horizontal, 32)
    }

    /// One "Label · value" line in the manage card. `value` is verbatim (a model
    /// ID or an already-masked key tail — never localized).
    private func summaryRow(label: LocalizedStringKey, value: String) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .onboardingScaledFont(.caption, weight: .semibold)
                .foregroundStyle(AppColors.textSecondary)
            Text(verbatim: "·")
                .onboardingScaledFont(.caption)
                .foregroundStyle(AppColors.textTertiary)
            Text(verbatim: value)
                .onboardingScaledFont(.caption, design: .monospaced)
                .foregroundStyle(AppColors.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
    }

    /// Quiet-probe feedback inside the manage card. Non-blocking: Done stays live.
    @ViewBuilder
    private var probeStatusRow: some View {
        switch probeState {
        case .idle, .ok:
            EmptyView()
        case .checking:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Checking…") // xcstrings: hosted-model
                    .onboardingScaledFont(.caption)
                    .foregroundStyle(AppColors.textSecondary)
            }
        case .failed:
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(AppColors.textSecondary)
                Text("Couldn't reach OpenRouter just now.") // xcstrings: hosted-model
                    .onboardingScaledFont(.caption)
                    .foregroundStyle(AppColors.textSecondary)
                Button("Retry") { runQuietProbe() } // xcstrings: hosted-model
                    .onboardingScaledFont(.caption, weight: .semibold)
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)
            }
        }
    }

    // MARK: - Shared fields

    /// Sits above the (always-mounted) key field while voice-key reuse is
    /// staged. "Change" backs out to manual entry — the staged flag is the ONLY
    /// thing to undo (nothing was persisted). Locked while a probe or the save
    /// is in flight: the captured intent must not mutate under an operation
    /// that is mid-commit against it.
    private var stagedVoiceKeyRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(AppColors.success)
            Text(LocalizedStringResource(
                "settings.remoteAgent.reuse.selected",
                defaultValue: "OpenRouter voice key selected"
            ))
                .onboardingScaledFont(.subheadline)
                .foregroundStyle(AppColors.textPrimary)
            Spacer(minLength: 0)
            Button {
                useVoiceKey = false
            } label: {
                Text(LocalizedStringResource(
                    "settings.remoteAgent.reuse.change",
                    defaultValue: "Change"
                ))
                    .onboardingScaledFont(.subheadline, weight: .semibold)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tint)
            .disabled(connecting || validatingKey)
        }
        .padding(14)
        .background(AppColors.cardBackground)
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(AppColors.borderSubtle, lineWidth: 1)
        )
        .frame(maxWidth: Constants.Layout.buttonMaxWidth)
        .accessibilityIdentifier("settings.remoteAgent.reuse.selectedRow")
    }

    private func keyField(placeholder: String) -> some View {
        SecureField(placeholder, text: $pendingKey)
            // No `.textContentType(.password)`: an API key is a secret, not a
            // website login — that content type wrongly summons the Passwords
            // autofill bar. `SecureField` masks regardless; paste is unaffected.
            #if os(iOS)
            .autocapitalization(.none)
            #endif
            .autocorrectionDisabled()
            .focused($keyFieldFocused)
            .submitLabel(.next)
            .onSubmit { keyFieldFocused = false }
            .padding(14)
            .background(AppColors.cardBackground)
            .cornerRadius(12)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(AppColors.borderSubtle, lineWidth: 1)
            )
            .frame(maxWidth: Constants.Layout.buttonMaxWidth)
    }

    @ViewBuilder
    private var validationStatusRow: some View {
        switch validationState {
        case .unset, .checking:
            EmptyView()
        case .valid:
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(AppColors.success)
                Text("API key valid.") // xcstrings: hosted-model
                    .foregroundStyle(AppColors.textSecondary)
                    .onboardingScaledFont(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .invalid(let message):
            // `.fixedSize(horizontal:vertical:)` + `Spacer` is load-bearing, not
            // cosmetic: without it the HStack sizes the Text to its IDEAL (single-
            // line) width and the message truncates mid-word — which is exactly how
            // a multi-sentence remedy renders as "…for yo…". Mirrors the
            // partial-sync row above.
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(AppColors.error)
                Text(message)
                    .foregroundStyle(AppColors.error)
                    .onboardingScaledFont(.subheadline)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Footer

    @ViewBuilder
    private var footer: some View {
        switch entryMode {
        case .none:
            EmptyView()
        case .manage:
            Button(action: proceed) {
                Text("Done") // xcstrings: hosted-model
                    .onboardingScaledFont(.headline)
                    .foregroundColor(AppColors.textEmphasis)
                    .frame(maxWidth: Constants.Layout.buttonMaxWidth)
                    .padding(.vertical, 16)
                    .background(Color.accentColor)
                    .cornerRadius(14)
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, Constants.Layout.horizontalPadding)
        case .setup:
            // TWO decoupled controls, breaking the old chicken-and-egg (the model
            // catalog only loads after a probe, but the single CTA was gated on a
            // model). "Validate key" needs only the key; "Connect" also needs the
            // model and runs the full validate→save.
            VStack(spacing: 12) {
                validateKeyButton
                primaryButton(
                    title: "Connect", // xcstrings: hosted-model
                    systemImage: "checkmark.shield",
                    enabled: connectButtonEnabled,
                    action: connect
                )
            }
            .padding(.horizontal, Constants.Layout.horizontalPadding)
        }
    }

    /// Secondary, validate-only: loads the model catalog. Validates the typed key,
    /// or (manage, blank field) re-probes the stored key. Bordered-stroke chrome
    /// (the flow's shared secondary vocabulary — primer's "Set up manually") with a
    /// neutral glyph, so the footer's one blue stays the Connect fill below.
    private var validateKeyButton: some View {
        Button(action: validateKey) {
            HStack(spacing: 8) {
                if validationState == .checking && !connecting {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "checkmark.shield")
                }
                Text("Validate key") // xcstrings: hosted-model
            }
            .onboardingScaledFont(.headline)
            .foregroundColor(AppColors.textPrimary)
            .frame(maxWidth: Constants.Layout.buttonMaxWidth)
            .padding(.vertical, 16)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(AppColors.border, lineWidth: 1)
            )
            .opacity(validateKeyEnabled ? 1 : 0.5)
        }
        .buttonStyle(.plain)
        .disabled(!validateKeyEnabled)
        .frame(maxWidth: .infinity)
    }

    private func primaryButton(
        title: LocalizedStringKey,
        systemImage: String,
        enabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack {
                if connecting {
                    ProgressView()
                        .controlSize(.small)
                        .tint(AppColors.textEmphasis)
                } else {
                    Image(systemName: systemImage)
                }
                Text(title)
            }
            .onboardingScaledFont(.headline)
            .foregroundColor(AppColors.textEmphasis)
            .frame(maxWidth: Constants.Layout.buttonMaxWidth)
            .padding(.vertical, 16)
            .background(enabled ? Color.accentColor : AppColors.disabled)
            .cornerRadius(14)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Derived enablement

    /// "Validate key" needs a key to probe — typed, staged (voice-key reuse), or
    /// (manage) the stored one. Not gated on the model (the catalog only appears
    /// after a probe).
    private var validateKeyEnabled: Bool {
        let haveSomethingToProbe =
            !pendingKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || hasStoredKey || useVoiceKey
        return haveSomethingToProbe
            && validationState != .checking
            && !connecting && !validatingKey
    }

    /// "Connect" requires the model and a key — typed, staged (voice-key reuse),
    /// or already stored.
    private var connectButtonEnabled: Bool {
        let keyOK = !pendingKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || hasStoredKey || useVoiceKey
        let modelOK = !modelBinding.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return keyOK && modelOK
            && validationState != .checking
            && !connecting && !validatingKey
    }

    // MARK: - Actions

    private var fixedURL: String {
        viewModel.remoteAgentURLStrings[ref] ?? Constants.openRouterBaseURLString
    }

    /// VALIDATE-ONLY: probe `/v1/key` (also discovering the model catalog) without
    /// saving. Uses the staged voice key, the typed key, or re-probes the stored
    /// key when the field is blank in manage mode.
    private func validateKey() {
        guard !validatingKey && !connecting && validationState != .checking else { return }
        probeTask?.cancel()
        // Snapshot the credential intent at TAP time — the probe must test what
        // the user launched it against, immune to a mid-flight toggle.
        let reuseVoiceKey = useVoiceKey
        let candidate = pendingKey
        let url = fixedURL
        validatingKey = true
        Task {
            if reuseVoiceKey {
                // The VM resolves the voice key from the Keychain — never the View.
                await viewModel.testRemoteAgent(ref: ref, stagedToken: .reuseVoiceKey, name: nil)
            } else if candidate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && hasStoredKey {
                await viewModel.retestRemoteAgent(ref: ref, url: url)
            } else {
                await viewModel.validateRemoteAgent(
                    ref: ref, url: url, token: candidate, authScheme: .bearer, fingerprint: nil
                )
            }
            validatingKey = false
        }
    }

    /// SETUP-mode primary: validate→save, then hand off to the success screen.
    /// Advancing is gated on the SAVE completing, never on the probe verdict — a
    /// valid key that fails to persist leaves the user unconfigured, and must leave
    /// them on this screen (with the error) rather than on a "Connected" one.
    private func connect() {
        guard !connecting && !validatingKey && validationState != .checking else { return }
        // Snapshot the credential intent at TAP time (see `validateKey`).
        let reuseVoiceKey = useVoiceKey
        let candidate = pendingKey
        connecting = true
        Task {
            let ok = await performSave(replacementKey: candidate, reuseVoiceKey: reuseVoiceKey)
            guard ok else {
                connecting = false
                return
            }
            pendingKey = ""
            viewModel.editorHasUnsavedChanges = false
            // `connecting` stays true through the outgoing slide: clearing it here
            // would flip the button out of its spinner mid-transition. The view is
            // being torn down, so the flag dies with it.
            onConnected()
        }
    }

    /// Validate (whenever a NEW key is in play — typed or staged voice-key reuse)
    /// then persist. `.stored` keeps the saved key untouched — the model-only
    /// path. `reuseVoiceKey` is the caller's TAP-time snapshot, not live state.
    private func performSave(replacementKey: String, reuseVoiceKey: Bool) async -> Bool {
        let staged: StagedRemoteAgentToken
        if reuseVoiceKey {
            staged = .reuseVoiceKey
        } else if replacementKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            staged = .stored
        } else {
            staged = .typed(replacementKey)
        }
        switch staged {
        case .typed(let key):
            await viewModel.validateRemoteAgent(
                ref: ref, url: fixedURL, token: key, authScheme: .bearer, fingerprint: nil
            )
            guard viewModel.remoteAgentRowState(for: ref) == .valid else { return false }
        case .reuseVoiceKey:
            // Same prove-the-key-before-save contract as a typed key; the VM
            // resolves the voice key internally.
            await viewModel.testRemoteAgent(ref: ref, stagedToken: .reuseVoiceKey, name: nil)
            guard viewModel.remoteAgentRowState(for: ref) == .valid else { return false }
        case .stored:
            break
        }
        return await viewModel.saveRemoteAgent(ref: ref, name: nil, stagedToken: staged)
    }

    /// Quiet manage-mode probe of the STORED key (`retestRemoteAgent` reads it from
    /// Keychain — raw key never enters the View). Non-blocking; editing now lives
    /// in a separate step that remounts this view (cancelling `probeTask` on
    /// disappear), so there's no inline-edit race to guard against here.
    private func runQuietProbe() {
        guard entryMode == .manage, hasStoredKey else { return }
        probeTask?.cancel()
        probeState = .checking
        let url = fixedURL
        probeTask = Task { @MainActor in
            await viewModel.retestRemoteAgent(ref: ref, url: url)
            guard !Task.isCancelled else { return }
            probeState = viewModel.remoteAgentLiveValidated.contains(ref) ? .ok : .failed
        }
    }

}

#Preview {
    ZStack {
        LinearGradient(
            colors: [AppColors.gradientStart, AppColors.gradientEnd],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()

        HostedModelGatewayStepView(
            viewModel: SettingsViewModel(),
            proceed: {},
            onConnected: {}
        )
    }
}
