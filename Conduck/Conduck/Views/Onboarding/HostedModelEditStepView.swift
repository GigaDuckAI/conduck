// SPDX-License-Identifier: Apache-2.0

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
//   • `oauthHandle` addresses a key a "Sign in with OpenRouter" just minted. The
//     View holds only the handle and a masked rendering of the key; the key
//     itself stays in the view model and is resolved at Save/Test time.
//
// REPLACING A KEY HAS THE SAME TWO ROUTES AS SETTING ONE, and the same
// single-source rule: signing in clears the typed field, typing discards the
// signed-in key, and Save resolves them in that order (signed-in → typed →
// stored). Leaving the screen discards an unsaved signed-in key — which removes
// only Conduck's copy, since the exchange created a real key at OpenRouter, hence
// the "Manage on OpenRouter" link on the staged row AND the note that survives a
// discard (`discardedKeyURL`): dropping the handle destroys the digest that
// addresses the key, so it is snapshotted first and kept on screen. Replacing a
// key never revokes the old one either, which the field hint says out loud.
//
// `didUserValidate` GATES THE STATUS ROW, so anything that clears `pendingKey`
// programmatically must not be mistaken for the user editing it — starting a
// sign-in does exactly that, and the resulting `.onChange` would otherwise
// silence every message the sign-in goes on to produce, success and failure
// alike. `signingIn` is set before the update pass runs and is what the handler
// checks.
//
// On a successful save the screen calls `onSaved()` — the container pops back to
// the manage card, which remounts, re-hydrates, and re-runs its quiet probe so
// it reflects the new model / key.

import AuthenticationServices
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

    /// The handle of the OpenRouter sign-in whose key is STAGED right now, or
    /// nil when none is. Never the key — only the handle and a masked rendering.
    @State private var oauthHandle: UUID?

    /// True from the tap that opens the web-auth sheet until the exchange (and
    /// its auto-probe) settles. Disables every other credential control.
    @State private var signingIn = false

    /// The sign-in in flight, bound to THIS step. Cancelled on disappear and
    /// whenever a new one starts, so a late completion is dropped.
    @State private var signInTask: Task<Void, Never>?

    /// The OpenRouter page for a signed-in key this step DISCARDED without
    /// saving. Snapshotted at the moment of discard — the vault entry it is
    /// computed from is gone a line later, and the key it addresses is real.
    @State private var discardedKeyURL: URL?

    /// Presents the OpenRouter authorization page. SwiftUI's own session — no
    /// hand-rolled `ASWebAuthenticationSession`, no presentation anchor to keep
    /// correct across iPhone, iPad and Mac windows.
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession

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
                    // Branched on availability: a build with no callback scheme
                    // shows no sign-in button, so the hint must not name one.
                    // Both spellings say the same load-bearing thing — a
                    // replacement does not revoke what it replaces.
                    Group {
                        if viewModel.openRouterSignInAvailable {
                            // xcstrings: hosted-model
                            Text("Sign in again for a fresh key, paste a new one, or leave both alone to keep your current key. Your previous key stays in your OpenRouter account until you remove it there.")
                        } else {
                            // xcstrings: hosted-model
                            Text("Leave blank to keep your current key. A new key doesn't remove the old one from your OpenRouter account.")
                        }
                    }
                    .onboardingScaledFont(.caption)
                    .foregroundStyle(AppColors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    // The one-click route, above the field it replaces. Hidden
                    // once a key is staged (the staged row supersedes it) and on
                    // a build that claims no callback scheme.
                    if oauthHandle == nil, viewModel.openRouterSignInAvailable {
                        signInSection
                            .padding(.bottom, 4)
                    }
                    if let discardedKeyURL {
                        discardedKeyNote(url: discardedKeyURL)
                    }
                    // The staged row sits ABOVE the always-mounted SecureField —
                    // same structure as the setup step, and for the same macOS
                    // reason: the field's own mount must never toggle.
                    if let oauthHandle {
                        stagedSignInRow(handle: oauthHandle)
                    }
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
            // ONLY a user edit gets here. `startSignIn` also blanks `pendingKey`,
            // synchronously, so this handler runs on the very next update pass —
            // and unguarded it would set `didUserValidate` back to false and hide
            // every message that sign-in is about to produce, its failures
            // included. `signingIn` is already true by then; the field is
            // `.disabled(signingIn)`, so no genuine keystroke is swallowed.
            guard !signingIn else { return }
            // A probe may have left validation `.valid`; once the user starts a
            // replacement key, that verdict no longer describes the field — drop
            // it and hide the status row until they validate the new key.
            viewModel.remoteAgentValidationStates[ref] = .unset
            didUserValidate = false
            // A typed character while a signed-in key is staged switches the
            // credential source back to manual, atomically with the keystroke.
            if !pendingKey.isEmpty { discardStagedSignIn() }
        }
        .onDisappear {
            // The sign-in is bound to THIS step: cancel it and drop the key it
            // staged (unsaved by definition — a save consumes the handle).
            signInTask?.cancel()
            discardStagedSignIn()
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

    // MARK: - Sign in with OpenRouter

    /// The one-click replacement path. Same stroked-secondary vocabulary as
    /// "Validate key" below it, so the screen's one filled control stays Save.
    private var signInSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: startSignIn) {
                Label {
                    Text("Sign in with OpenRouter") // xcstrings: hosted-model
                } icon: {
                    if signingIn {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "person.badge.key")
                    }
                }
                .onboardingScaledFont(.subheadline, weight: .semibold)
                .labelStyle(AccentGlyphActionLabelStyle())
                .frame(maxWidth: Constants.Layout.buttonMaxWidth)
            }
            // Mirrors this screen's "Validate key": accent glyph + neutral title
            // on a grey `.bordered` pill — a calm secondary beside the filled Save.
            .buttonStyle(.bordered)
            .disabled(!signInEnabled)
            .frame(maxWidth: .infinity)
            .accessibilityIdentifier("settings.remoteAgent.openRouter.signIn")

            // xcstrings: hosted-model
            Text("Creates an API key for Conduck in your OpenRouter account — nothing to copy.")
                .onboardingScaledFont(.caption)
                .foregroundStyle(AppColors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Sits above the (always-mounted) key field while a signed-in key is staged.
    /// "Manage on OpenRouter" exists because the exchange created a REAL key even
    /// if this edit is never saved; "Use a different key" backs out to the field.
    private func stagedSignInRow(handle: UUID) -> some View {
        let masked = viewModel.openRouterIssuedMaskedKey(handle: handle) ?? ""
        let manageURL = viewModel.openRouterKeySettingsURL(handle: handle)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(AppColors.success)
                Text(LocalizedStringResource(
                    "settings.remoteAgent.openRouter.signIn.staged",
                    defaultValue: "Signed in with OpenRouter"
                ))
                    .onboardingScaledFont(.subheadline)
                    .foregroundStyle(AppColors.textPrimary)
                Spacer(minLength: 0)
                // Masked through the app's ONE masking helper, so this reads as
                // the same kind of credential as the "Currently · Key" row a few
                // points above it rather than a different format.
                Text(verbatim: masked)
                    .onboardingScaledFont(.caption, design: .monospaced)
                    .foregroundStyle(AppColors.textSecondary)
            }
            // Restated here because the sign-in caption that said it is
            // unmounted the moment this row appears — which is the moment the
            // key starts existing.
            Text(LocalizedStringResource(
                "settings.remoteAgent.openRouter.signIn.stagedDetail",
                defaultValue: "A new API key now sits in your OpenRouter account."
            ))
                .onboardingScaledFont(.caption)
                .foregroundStyle(AppColors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 16) {
                if let manageURL {
                    Link(destination: manageURL) {
                        HStack(spacing: 4) {
                            Text(LocalizedStringResource(
                                "settings.remoteAgent.openRouter.signIn.manage",
                                defaultValue: "Manage on OpenRouter"
                            ))
                            Image(systemName: "arrow.up.right")
                                .onboardingScaledFont(.caption)
                        }
                        .onboardingScaledFont(.subheadline, weight: .semibold)
                    }
                    .pointerLink()
                    .foregroundStyle(.tint)
                }
                Button {
                    unstageSignInForADifferentKey()
                } label: {
                    Text(LocalizedStringResource(
                        "settings.remoteAgent.openRouter.signIn.useDifferentKey",
                        defaultValue: "Use a different key"
                    ))
                        .onboardingScaledFont(.subheadline, weight: .semibold)
                }
                .inlineLinkButton()
                .foregroundStyle(.tint)
                .disabled(connecting || validatingKey || signingIn)
                Spacer(minLength: 0)
            }
        }
        .padding(14)
        .background(AppColors.cardBackground)
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(AppColors.borderSubtle, lineWidth: 1)
        )
        .frame(maxWidth: .infinity)
        .accessibilityIdentifier("settings.remoteAgent.openRouter.signIn.stagedRow")
    }

    /// Shown after a signed-in key is dropped WITHOUT being saved — the user
    /// typed instead, or tapped "Use a different key". The exchange created that
    /// key at OpenRouter for real, so dropping our copy would otherwise leave a
    /// live key spending the user's credit with nothing on screen naming it.
    /// `url` is snapshotted before the discard: the digest that addresses the key
    /// is computed from the key, which is gone a line later. A digest is not a
    /// credential, so it can outlive what it points at.
    private func discardedKeyNote(url: URL) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "info.circle")
                    .foregroundStyle(AppColors.textSecondary)
                Text(LocalizedStringResource(
                    "settings.remoteAgent.openRouter.signIn.discarded",
                    defaultValue: "The key you signed in with still exists in your OpenRouter account."
                ))
                    .onboardingScaledFont(.caption)
                    .foregroundStyle(AppColors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            HStack(spacing: 16) {
                Link(destination: url) {
                    HStack(spacing: 4) {
                        Text(LocalizedStringResource(
                            "settings.remoteAgent.openRouter.signIn.manage",
                            defaultValue: "Manage on OpenRouter"
                        ))
                        Image(systemName: "arrow.up.right")
                            .onboardingScaledFont(.caption)
                    }
                    .onboardingScaledFont(.subheadline, weight: .semibold)
                }
                .pointerLink()
                .foregroundStyle(.tint)
                Button {
                    discardedKeyURL = nil
                } label: {
                    Text(LocalizedStringResource(
                        "settings.remoteAgent.openRouter.signIn.discardedDismiss",
                        defaultValue: "Dismiss"
                    ))
                        .onboardingScaledFont(.subheadline, weight: .semibold)
                }
                .inlineLinkButton()
                .foregroundStyle(.tint)
                Spacer(minLength: 0)
            }
        }
        .padding(14)
        .background(AppColors.cardBackground)
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(AppColors.borderSubtle, lineWidth: 1)
        )
        .frame(maxWidth: .infinity)
        .accessibilityIdentifier("settings.remoteAgent.openRouter.signIn.discardedRow")
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
            // Inert while the web-auth sheet is up — typing would switch the
            // credential source under an operation already in flight. A MODIFIER,
            // never a structural change: the field stays permanently mounted
            // (an out-of-process `NSSecureTextField` mounted/unmounted under a
            // state toggle terminates ViewBridge on macOS).
            .disabled(signingIn)
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
        .primaryCTAButton()
        .disabled(!enabled)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Derived enablement

    /// "Save changes" requires a model (the stored key is kept); the replacement
    /// key is optional.
    private var saveEnabled: Bool {
        !modelDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && validationState != .checking
            && !connecting && !validatingKey && !signingIn
    }

    /// "Validate key" needs a key to probe — typed, staged (a sign-in), or the
    /// stored one. Not gated on the model.
    private var validateKeyEnabled: Bool {
        let haveSomethingToProbe =
            !pendingKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || hasStoredKey || oauthHandle != nil
        return haveSomethingToProbe
            && validationState != .checking
            && !connecting && !validatingKey && !signingIn
    }

    /// "Sign in with OpenRouter" is live whenever nothing else is mid-flight
    /// against the current credential. Not gated on the field being empty:
    /// starting a sign-in IS the act of choosing a different source, and it
    /// clears the field as part of staging.
    private var signInEnabled: Bool {
        validationState != .checking && !connecting && !validatingKey && !signingIn
    }

    // MARK: - Actions

    private var fixedURL: String {
        viewModel.remoteAgentURLStrings[ref] ?? Constants.openRouterBaseURLString
    }

    /// Open the system web-auth sheet and stage whatever comes back. Identical
    /// contract to the setup step's: staging is atomic with the tap (the typed
    /// field is cleared first), the task is bound to this step, a user cancel is
    /// silent, and every other failure lands on the paste field with a message.
    private func startSignIn() {
        guard signInEnabled else { return }
        guard let start = viewModel.beginOpenRouterSignIn() else {
            // The view model already surfaced the "can't start a secure sign-in"
            // message; show it in the status row rather than swallowing it.
            didUserValidate = true
            return
        }
        signInTask?.cancel()
        discardStagedSignIn()
        // `discardedKeyURL` is deliberately NOT cleared here: the note is the only
        // route left to the key just abandoned, and it carries its own Dismiss.
        pendingKey = ""
        signingIn = true
        // The verdict on screen was earned by whatever this sign-in replaces.
        // Retracted HERE rather than by `.onChange(of: pendingKey)`, which is
        // now guarded against this very mutation.
        viewModel.remoteAgentValidationStates[ref] = .unset
        // The probe the sign-in triggers writes a verdict for this ref, so the
        // status row must be allowed to show it — and so must every failure
        // message `completeOpenRouterSignIn` writes there.
        didUserValidate = true
        let handle = start.handle
        signInTask = Task { @MainActor in
            defer { signingIn = false }
            do {
                let callback = try await webAuthenticationSession.authenticate(
                    using: start.authorizationURL,
                    callback: .customScheme(start.callbackScheme),
                    // `.shared`: reusing the browser session the user is already
                    // signed into IS the one-click property.
                    preferredBrowserSession: .shared,
                    additionalHeaderFields: [:]
                )
                guard !Task.isCancelled else {
                    viewModel.discardOpenRouterSignIn(handle: handle)
                    return
                }
                let outcome = await viewModel.completeOpenRouterSignIn(
                    handle: handle, callbackURL: callback
                )
                guard !Task.isCancelled else {
                    viewModel.discardOpenRouterSignIn(handle: handle)
                    return
                }
                switch outcome {
                case .staged(let staged, _):
                    oauthHandle = staged
                case .cancelled, .failed:
                    viewModel.discardOpenRouterSignIn(handle: handle)
                }
            } catch is CancellationError {
                viewModel.discardOpenRouterSignIn(handle: handle)
            } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
                // The user closed the sheet. Silent — busy state resets via `defer`.
                viewModel.discardOpenRouterSignIn(handle: handle)
            } catch {
                // The session itself failed; nothing usable came back.
                viewModel.failOpenRouterSignIn(handle: handle)
            }
        }
    }

    /// Drop the staged sign-in, if any — the ONE place this View forgets a
    /// handle. Removes only Conduck's copy; the key at OpenRouter is real, so
    /// its settings URL is read BEFORE the discard destroys the key the digest
    /// is computed from, and kept as the note the user is left with.
    private func discardStagedSignIn() {
        guard let handle = oauthHandle else { return }
        discardedKeyURL = viewModel.openRouterKeySettingsURL(handle: handle)
        oauthHandle = nil
        viewModel.discardOpenRouterSignIn(handle: handle)
    }

    /// The USER-initiated unstage ("Use a different key"). Nothing else here
    /// retracts the verdict, and there always is one: a successful sign-in
    /// auto-probes. Left alone, "API key valid." would sit over a screen with
    /// nothing staged — and Save, which is gated only on the model, would then
    /// commit the model against the PREVIOUS stored key under a green tick.
    private func unstageSignInForADifferentKey() {
        discardStagedSignIn()
        viewModel.remoteAgentValidationStates[ref] = .unset
        viewModel.noteRemoteAgentSecretEdited(for: ref)
        didUserValidate = false
    }

    /// VALIDATE-ONLY: probe `/v1/key` (also discovering the catalog) without
    /// saving. Uses the staged sign-in, the typed key, or re-probes the stored
    /// key when both are absent.
    private func validateKey() {
        guard !validatingKey && !connecting && !signingIn && validationState != .checking else { return }
        let signedInHandle = oauthHandle
        let candidate = pendingKey
        let url = fixedURL
        // User-initiated → its result is allowed to surface in the status row.
        didUserValidate = true
        validatingKey = true
        Task {
            if let signedInHandle {
                // The VM resolves the signed-in key from its vault — never the
                // View — and a probe never consumes it.
                await viewModel.testRemoteAgent(
                    ref: ref, stagedToken: .oauthIssued(signedInHandle), name: nil
                )
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

    /// PRIMARY: validate (only if a replacement key was typed) → commit the model
    /// draft → save. On success, pop back to the manage card. Never auto-dismisses
    /// the whole flow.
    private func save() {
        guard !connecting && !validatingKey && !signingIn && validationState != .checking else { return }
        let candidate = pendingKey
        let signedInHandle = oauthHandle
        connecting = true
        Task {
            let ok = await performSave(replacementKey: candidate, signedInHandle: signedInHandle)
            if ok {
                pendingKey = ""
                // The save consumed the vault entry, so the handle now addresses
                // nothing — forget it locally too. Straight to `oauthHandle`, NOT
                // through `discardStagedSignIn()`: this key was committed, not
                // abandoned, so it must not raise the orphan note.
                oauthHandle = nil
                discardedKeyURL = nil
                viewModel.editorHasUnsavedChanges = false
                onSaved()
            }
            connecting = false
        }
    }

    /// Validate (only when a NEW key is in play), then commit the draft +
    /// persist. With neither a signed-in nor a typed key the stored one is kept
    /// (`.stored` leaves the persisted token untouched) — the model-only path.
    /// The model draft is written to the VM buffer ONLY here, just before the
    /// save, so a failed validation leaves the VM untouched.
    ///
    /// Precedence matches the setup step and the screen's reading order:
    /// signed-in key → typed key → stored key.
    private func performSave(replacementKey: String, signedInHandle: UUID?) async -> Bool {
        let url = fixedURL
        let trimmed = replacementKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let staged: StagedRemoteAgentToken
        if let signedInHandle {
            staged = .oauthIssued(signedInHandle)
            // Same prove-the-key-before-save contract as a typed key. The VM
            // resolves the credential internally and does NOT consume it, so a
            // failing probe leaves the key retryable.
            await viewModel.testRemoteAgent(ref: ref, stagedToken: staged, name: nil)
            guard viewModel.remoteAgentRowState(for: ref) == .valid else { return false }
        } else if !trimmed.isEmpty {
            staged = .typed(replacementKey)
            await viewModel.validateRemoteAgent(
                ref: ref, url: url, token: replacementKey, authScheme: .bearer, fingerprint: nil
            )
            guard viewModel.remoteAgentRowState(for: ref) == .valid else { return false }
        } else {
            staged = .stored
        }
        viewModel.remoteAgentModelStrings[ref] = modelDraft
        return await viewModel.saveRemoteAgent(ref: ref, name: nil, stagedToken: staged)
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
