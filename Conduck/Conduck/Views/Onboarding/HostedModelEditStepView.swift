// Conduck
// HostedModelEditStepView.swift
//
// The dedicated EDIT step for an already-configured hosted-model gateway
// (OpenRouter). Reached from the manage card on `HostedModelGatewayStepView`
// ("Change model or API key") via the guided-setup step machine
// (`GuidedGatewaySetupView` → `.hostedModelEdit`). Editing used to be a cramped
// inline reveal below the manage card; it is now its own clean, well-spaced
// screen with a logical field order: API KEY FIRST, then MODEL.
//
// The full manual gateway editor (`RemoteAgentConfigBody`, reached from the
// Settings list) is a SEPARATE surface — this screen never routes to it.
//
// State ownership (deliberately LOCAL to avoid dirtying the manage card behind):
//   • `modelDraft` is a LOCAL copy of the current model, snapshotted at init and
//     written into the VM buffer ONLY immediately before `saveRemoteAgent`. So
//     Cancel / Back (container-owned, runs no edit-specific logic) leaves the VM
//     untouched — the manage card stays correct with no restore race.
//   • `pendingKey` is the OPTIONAL replacement API key (blank ⇒ keep the stored
//     key). It flows out exactly once via `saveRemoteAgent` (→ Keychain), then is
//     cleared. Never logged, printed, or echoed.
//
// On a successful save the screen calls `onSaved()` — the container pops back to
// the manage card, which remounts, re-hydrates, and re-runs its quiet probe so
// it reflects the new model / key.

import SwiftUI

struct HostedModelEditStepView: View {
    @Bindable var viewModel: SettingsViewModel

    /// Persisted successfully — the container pops back to the manage card.
    let onSaved: () -> Void

    /// The OpenRouter built-in ref — this whole step edits exactly it.
    private let ref = RemoteAgentRef.builtin(.openrouter)

    /// LOCAL model draft, snapshotted from the VM at init. Committed to the VM
    /// buffer only just before `saveRemoteAgent` — never on Cancel/Back.
    @State private var modelDraft: String

    /// Optional replacement API key (blank ⇒ keep the stored key). Local; flows
    /// out once via `saveRemoteAgent`, then cleared.
    @State private var pendingKey: String = ""

    /// Buffer-only filter for the model suggestion strip.
    @State private var modelFilter: String = ""

    /// Lets `.onSubmit` resign focus.
    @FocusState private var keyFieldFocused: Bool

    /// True only while the validate→save primary is in flight.
    @State private var connecting = false

    /// True only while a "Validate key" probe is in flight. Set SYNCHRONOUSLY at
    /// tap so a rapid double-tap can't launch two probes.
    @State private var validatingKey = false

    /// True once the user has TAPPED "Validate key" this edit. Gates the
    /// validation status row so the silent auto-preload probe (which validates the
    /// stored key on appear) never paints a result; only a user-initiated validate
    /// shows success/failure. Reset when the key field changes.
    @State private var didUserValidate = false

    init(viewModel: SettingsViewModel, onSaved: @escaping () -> Void) {
        self.viewModel = viewModel
        self.onSaved = onSaved
        // Snapshot the current model synchronously so the field never flashes
        // empty. The view remounts on each push (`.id(step)`), so this re-reads
        // the live value every time the edit step opens.
        let current = (viewModel.remoteAgentModelStrings[.builtin(.openrouter)] ?? "")
        _modelDraft = State(initialValue: current)
    }

    /// The OpenRouter descriptor — supplies the fixed URL / docs link.
    private var descriptor: RemoteAgentBackendMetadata {
        RemoteAgentBackendRegistry.lookup(id: .openrouter)
    }

    /// True once a token is stored for this ref. Lets a model-only save keep the
    /// stored key and lets "Validate key" re-probe it with a blank field.
    private var hasStoredKey: Bool { viewModel.remoteAgentMaskedTails[ref] != nil }

    /// Validation state for this ref (read from the dict).
    private var validationState: KeyValidationState {
        viewModel.remoteAgentRowState(for: ref)
    }

    /// The model currently persisted (read live — the VM buffer is NOT mutated
    /// during editing, so this stays the "from" value for the context line).
    private var currentModel: String {
        (viewModel.remoteAgentModelStrings[ref] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(spacing: 24) {
            Text("Change your OpenRouter setup") // xcstrings: hosted-model
                .onboardingScaledFont(.title, weight: .bold)
                .foregroundStyle(AppColors.textEmphasis)
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
                .padding(.horizontal, 32)

            // One centered form rail (card + key + model) sharing the same width
            // and center line as the Save CTA. On macOS/iPad the Layout tokens
            // diverge; the rail keeps every control aligned (on iPhone it's just
            // full width). Lightweight field labels replace heavy section headers —
            // the model picker already labels itself, so no duplicate "Model".
            VStack(alignment: .leading, spacing: 20) {
                currentStateCard

                // API key (first). "Validate key" sits under the field it acts on.
                VStack(alignment: .leading, spacing: 8) {
                    fieldLabel("API key") // xcstrings: hosted-model
                    // xcstrings: hosted-model
                    Text("Leave blank to keep your current key.")
                        .onboardingScaledFont(.caption)
                        .foregroundStyle(AppColors.textSecondary)
                    keyField
                    validateKeyButton
                        .padding(.top, 4)
                    if didUserValidate {
                        validationStatusRow
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                // Model — the picker carries its own "Model (required)" label.
                OpenRouterModelPickerField(
                    selection: $modelDraft,
                    filter: $modelFilter,
                    suggestions: viewModel.remoteAgentModelSuggestions[ref] ?? []
                )
            }
            .guidedFormRail()
        }
        .onboardingStepLayout {
            footer
        }
        .onChange(of: pendingKey) { _, _ in
            // A probe may have left validation `.valid`; once the user starts a
            // replacement key, that verdict no longer describes the field — drop
            // it and hide the status row until they validate the new key.
            viewModel.remoteAgentValidationStates[ref] = .unset
            didUserValidate = false
        }
        .onDisappear {
            // This screen owns the dirty fence in edit; always clear on leave
            // (Save and Cancel/Back both pass through here).
            viewModel.editorHasUnsavedChanges = false
        }
        .task {
            // Fence late iCloud-KVS reloads from clobbering an in-progress edit.
            viewModel.editorHasUnsavedChanges = true
            // Pre-load the model catalog if it's empty and a key is stored, so
            // the picker is populated without the user tapping Validate. The
            // probe reads the STORED token internally (raw key never enters the
            // view). Status stays hidden because `pendingKey` is empty.
            if (viewModel.remoteAgentModelSuggestions[ref] ?? []).isEmpty, hasStoredKey {
                await viewModel.retestRemoteAgent(ref: ref, url: fixedURL)
            }
        }
    }

    // MARK: - Current-state context

    /// A compact, read-only summary of what's configured now (the "from" state),
    /// so the user has context for what they're changing.
    @ViewBuilder
    private var currentStateCard: some View {
        let tail = viewModel.remoteAgentMaskedTails[ref]
        if !currentModel.isEmpty || tail != nil {
            VStack(alignment: .leading, spacing: 6) {
                Text("Currently") // xcstrings: hosted-model
                    .onboardingScaledFont(.caption, weight: .semibold)
                    .foregroundStyle(AppColors.textSecondary)
                if !currentModel.isEmpty {
                    summaryRow(label: "Model", value: currentModel) // xcstrings: hosted-model
                }
                if let tail {
                    summaryRow(label: "Key", value: tail) // xcstrings: hosted-model
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .glassCardBackground()
        }
    }

    /// One "Label · value" line. `value` is verbatim (a model ID or an
    /// already-masked key tail — never localized).
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

    // MARK: - Fields

    /// A lightweight field label in the same style the model picker uses for its
    /// "Model" label — keeps the API key and Model fields visually consistent
    /// without heavy section headers.
    private func fieldLabel(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .onboardingScaledFont(.subheadline)
            .foregroundStyle(AppColors.textPrimary)
    }

    private var keyField: some View {
        SecureField(
            String(localized: LocalizedStringResource(
                "settings.remoteAgent.hosted.edit.replaceKey.placeholder",
                defaultValue: "Replace API key"
            )),
            text: $pendingKey
        )
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
            // Fill the form rail; the rail owns the width cap + centering.
            .frame(maxWidth: .infinity)
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
            // See `HostedModelGatewayStepView.validationStatusRow` — without
            // `.fixedSize` the Text takes its ideal single-line width and a
            // multi-sentence remedy truncates mid-word.
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

    private var footer: some View {
        // "Validate key" now lives under the API key field (Section 1); the
        // footer carries only the primary Save action.
        primaryButton(
            title: "Save changes", // xcstrings: hosted-model
            systemImage: "checkmark",
            enabled: saveEnabled,
            action: save
        )
        .padding(.horizontal, Constants.Layout.horizontalPadding)
    }

    /// Secondary, validate-only: loads the model catalog. Validates the typed
    /// key, or (blank field) re-probes the stored key.
    private var validateKeyButton: some View {
        Button(action: validateKey) {
            Label {
                Text("Validate key") // xcstrings: hosted-model
            } icon: {
                if validationState == .checking && !connecting {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "checkmark.shield")
                }
            }
            .onboardingScaledFont(.subheadline, weight: .semibold)
            .labelStyle(AccentGlyphActionLabelStyle())
            .frame(maxWidth: Constants.Layout.buttonMaxWidth)
        }
        // Mirrors the editor's "Test Connection": blue glyph (the button's accent
        // tint) + neutral-white title (the label style) on a grey `.bordered` pill —
        // a calm secondary action, distinct from the filled primary below.
        .buttonStyle(.bordered)
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

    /// "Save changes" requires a model (the stored key is kept); the replacement
    /// key is optional.
    private var saveEnabled: Bool {
        !modelDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && validationState != .checking
            && !connecting && !validatingKey
    }

    /// "Validate key" needs a key to probe — typed, or the stored one. Not gated
    /// on the model.
    private var validateKeyEnabled: Bool {
        let haveSomethingToProbe =
            !pendingKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || hasStoredKey
        return haveSomethingToProbe
            && validationState != .checking
            && !connecting && !validatingKey
    }

    // MARK: - Actions

    private var fixedURL: String {
        viewModel.remoteAgentURLStrings[ref] ?? Constants.openRouterBaseURLString
    }

    /// VALIDATE-ONLY: probe `/v1/key` (also discovering the catalog) without
    /// saving. Uses the typed key, or re-probes the stored key when blank.
    private func validateKey() {
        guard !validatingKey && !connecting && validationState != .checking else { return }
        let candidate = pendingKey
        let url = fixedURL
        // User-initiated → its result is allowed to surface in the status row.
        didUserValidate = true
        validatingKey = true
        Task {
            if candidate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && hasStoredKey {
                await viewModel.retestRemoteAgent(ref: ref, url: url)
            } else {
                await viewModel.validateRemoteAgent(
                    ref: ref, url: url, token: candidate, authScheme: .bearer, fingerprint: nil
                )
            }
            validatingKey = false
        }
    }

    /// PRIMARY: validate (only if a replacement key was typed) → commit the model
    /// draft → save. On success, pop back to the manage card. Never auto-dismisses
    /// the whole flow.
    private func save() {
        guard !connecting && !validatingKey && validationState != .checking else { return }
        let candidate = pendingKey
        connecting = true
        Task {
            let ok = await performSave(replacementKey: candidate)
            if ok {
                pendingKey = ""
                viewModel.editorHasUnsavedChanges = false
                onSaved()
            }
            connecting = false
        }
    }

    /// Validate (only when a key is supplied), then commit the draft + persist.
    /// An empty `replacementKey` keeps the stored key (`.stored` leaves the
    /// persisted token untouched) — the model-only path. The model draft is
    /// written to the VM buffer ONLY here, just before the save, so a failed
    /// validation leaves the VM untouched.
    private func performSave(replacementKey: String) async -> Bool {
        let url = fixedURL
        let trimmed = replacementKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            await viewModel.validateRemoteAgent(
                ref: ref, url: url, token: replacementKey, authScheme: .bearer, fingerprint: nil
            )
            guard viewModel.remoteAgentRowState(for: ref) == .valid else { return false }
        }
        viewModel.remoteAgentModelStrings[ref] = modelDraft
        return await viewModel.saveRemoteAgent(
            ref: ref,
            name: nil,
            stagedToken: trimmed.isEmpty ? .stored : .typed(replacementKey)
        )
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

        HostedModelEditStepView(viewModel: SettingsViewModel(), onSaved: {})
    }
}
