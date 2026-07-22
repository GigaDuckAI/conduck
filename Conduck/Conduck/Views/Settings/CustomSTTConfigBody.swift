// Conduck
// CustomSTTConfigBody.swift
//
// Custom STT — Feature 2 — the BYO custom OpenAI-compatible STT endpoint's
// configuration surface. The STT analog of `RemoteAgentConfigBody` (gateway
// config), branched to from `STTProviderDetailView` (iOS) +
// `MacSpeechToTextCategory` (macOS) when `metadata.id == "custom-openai"`.
//
// Layout (cloned from `RemoteAgentConfigBody`, plus two STT-specific fields):
//   - Base-URL field (https-only; non-standard-port hint). The user types only
//     the BASE — the transcribe path is appended for them.
//   - Authentication toggle (Requires an API key / keyless local server). `.none`
//     makes the key optional + skips the missing-key guard, AND hides the key row.
//   - API-key summary row (`secretRow`, `.bearer` only): an ordinary (non-secure)
//     row showing "Entered" / a masked tail / "Set"; tapping opens
//     `SecretEntrySheet`, where the native `SecureField` lives. When keyless this
//     row is absent entirely. NO `SecureField` is ever inline in this Form
//     (out-of-process macOS `NSSecureTextField` layout-recursion — see
//     `SecretEntrySheet.swift`).
//   - Optional model field (default `whisper-1`).
//   - Test (runs the FULL staged suite — the custom endpoint's default Test
//     action) + Forget.
//   - The rich staged checklist (`STTTestSuiteResultView`) with per-stage
//     status + transcript + latency + iOS TOFU "Trust & Save".
//   - Advanced DisclosureGroup — manual cert-fingerprint pin.
//
// Privacy invariants (same as the gateway body):
//   - The API key never leaves the editor-local `pendingKey` buffer (seeded into /
//     committed from `SecretEntrySheet`'s transient `draft`); cleared after a save
//     attempt. Keychain is the only persistence.
//   - The masked tail is the only key surface once stored.
//
// Cross-platform (iOS + macOS): the body is shared. The TOFU "Trust & Save"
// affordance lives inside `STTTestSuiteResultView` (iOS-only). UIKit-only
// TextField modifiers are `#if os(iOS)`-gated.

import SwiftUI

struct CustomSTTConfigBody: View {
    @Bindable var viewModel: SettingsViewModel

    /// The named custom voice endpoint this editor configures (Phase B). All
    /// fields bind to the per-uuid dict entries on the view-model.
    let uuid: UUID

    /// Pops back to the provider list after the endpoint is deleted.
    @Environment(\.dismiss) private var dismiss

    /// Editor-local API-key buffer — entered via `SecretEntrySheet`, cleared after
    /// a save attempt. NEVER persisted past the validate-and-save call.
    @State private var pendingKey: String = ""

    /// Drives the tap-in `SecretEntrySheet` for API-key entry (the only place a
    /// `SecureField` exists — never inline in this Form).
    @State private var showingSecretSheet: Bool = false

    /// Confirmation alert for the destructive "Delete endpoint" action.
    @State private var showingDeleteConfirm: Bool = false

    /// Advanced (manual pinning) disclosure — collapsed by default.
    @State private var advancedExpanded: Bool = false

    /// Editable voice buffer for the TTS section. Seeded from the stored
    /// override on appear; persisted via Save (mirrors the built-in
    /// `VoiceProviderDetailView` voice field). Buffer-until-Save.
    @State private var pendingTTSVoice: String = ""

    /// Set true right before a Save- or Delete-driven `dismiss()` so the
    /// `.onAppear`/`.onDisappear` cancel safety-net DOESN'T also run (Save already
    /// committed; Delete already wiped). For every OTHER exit — the Cancel button,
    /// a swipe-back, the macOS native back chevron (which `navigationBarBackButtonHidden`
    /// can't hide), or the whole Settings sheet closing — `.onDisappear` runs the
    /// cancel cleanup, so unsaved buffers/drafts never linger. The VM's cancel
    /// uses the store as the sole authority, so this is robust on both platforms.
    @State private var suppressCancelOnExit: Bool = false

    /// Snapshot of the editable buffers on appear, for dirty-detection (Cancel
    /// confirms only when something changed). A typed key also marks dirty.
    @State private var originalName: String = ""
    @State private var originalURL: String = ""
    @State private var originalSTTModel: String = ""
    @State private var originalTTSModel: String = ""
    @State private var originalTTSVoice: String = ""
    @State private var originalCertFingerprint: String = ""
    @State private var originalAuthKeyless: Bool = false

    /// Seed the dirty-detection snapshots exactly ONCE — `.onAppear` re-firing on a
    /// child-push round-trip would re-baseline `original*` to edited values and
    /// make unsaved edits read as pristine. Mirrors `RemoteAgentConfigBody`.
    @State private var didInitialize: Bool = false

    private var presetID: String { STTProvider.customEndpointID(for: uuid) }
    private var ttsProviderID: String { TTSProvider.customEndpointID(for: uuid) }

    private var rowState: KeyValidationState {
        viewModel.customSTTValidationStates[uuid] ?? .unset
    }

    private var isKeyless: Bool {
        (viewModel.customSTTAuthSchemes[uuid] ?? .bearer) == .none
    }

    /// The macOS editor-header title — the endpoint's name, or a placeholder for
    /// a fresh unnamed draft (iOS uses the host's `.navigationTitle` instead).
    private var editorTitle: String {
        let name = viewModel.customVoiceEndpointName(for: uuid)
        return name.isEmpty
            ? String(localized: LocalizedStringResource("settings.voice.custom.newEndpoint.title", defaultValue: "New endpoint"))
            : name
    }

    var body: some View {
        Form {
            connectionSection
            speechToTextSection
            testSuiteSection
            ttsSection
            advancedSection
            destructiveSection
            creditHintFootnote
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .scrollDismissesKeyboard(.interactively)
        // macOS: inset the grouped form to match every other settings surface
        // (General, the list pages, the built-in vendor detail all pad 28). The
        // editor chrome's full-width header is added AFTER this via
        // `.safeAreaInset(.top)`, so it stays edge-to-edge while the form sits in.
        // iOS keeps the native full-bleed Form (verified premium look).
        #if os(macOS)
        .padding(.horizontal, 28)
        .padding(.top, 8)
        .padding(.bottom, 28)
        #endif
        .sheet(isPresented: $showingSecretSheet) {
            SecretEntrySheet(
                title: LocalizedStringResource("settings.stt.custom.key.sheet.title", defaultValue: "Enter API key"),
                prompt: String(localized: LocalizedStringResource("settings.stt.custom.key.placeholder", defaultValue: "Paste your endpoint's API key")),
                initialValue: pendingKey,
                onCommit: { pendingKey = $0 }
            )
        }
        .onAppear {
            // Seed once — see `didInitialize`. Re-seeding on a child round-trip
            // would corrupt dirty detection (and lose the voice buffer edit).
            guard !didInitialize else { return }
            didInitialize = true
            // Seed the voice buffer from the stored override (mirrors the
            // built-in detail view). The model binds directly to the VM.
            pendingTTSVoice = viewModel.ttsVoices[ttsProviderID] ?? ""
            // Snapshot the original buffer values for Cancel's dirty detection.
            originalName = viewModel.customVoiceEndpointName(for: uuid)
            originalURL = viewModel.customSTTURLStrings[uuid] ?? ""
            originalSTTModel = viewModel.customSTTModels[uuid] ?? ""
            originalTTSModel = viewModel.customTTSModels[uuid] ?? ""
            originalTTSVoice = pendingTTSVoice
            originalCertFingerprint = viewModel.customSTTCertFingerprints[uuid] ?? ""
            originalAuthKeyless = isKeyless
        }
        .bufferedEditorChrome(
            isDirty: isDirty,
            editorHasUnsavedChanges: $viewModel.editorHasUnsavedChanges,
            onDiscard: { await viewModel.cancelCustomVoiceEndpointEdit(for: uuid) },
            suppressCancelOnExit: $suppressCancelOnExit,
            title: editorTitle,
            saveTitle: LocalizedStringResource("settings.editor.save", defaultValue: "Save"),
            canSave: { canSave },
            onSave: { saveTapped() }
        )
        .alert(
            LocalizedStringResource("settings.voice.custom.deleteAlert.title", defaultValue: "Delete endpoint?"),
            isPresented: $showingDeleteConfirm
        ) {
            Button(
                LocalizedStringResource("settings.voice.custom.deleteAlert.confirm", defaultValue: "Delete"),
                role: .destructive
            ) {
                Task {
                    await viewModel.clearCustomSTT(for: uuid)
                    // Delete already wiped everything — skip the onDisappear cancel.
                    suppressCancelOnExit = true
                    pendingKey = ""
                    dismiss()
                }
            }
            Button(
                LocalizedStringResource("settings.stt.custom.forgetAlert.cancel", defaultValue: "Cancel"),
                role: .cancel
            ) { }
        } message: {
            Text(LocalizedStringResource(
                "settings.voice.custom.deleteAlert.message",
                defaultValue: "Conduck removes this endpoint and erases its saved URL, key, model, and pin. If it's your active voice, playback falls back to Apple."
            ))
        }
    }

    // MARK: - Connection Section (the shared server — capability-neutral)
    //
    // ONE server reachable at one base URL, serving STT (`/v1/audio/transcriptions`)
    // and/or TTS (`/v1/audio/speech`). This top section is purely how to REACH it —
    // name + URL + auth + key — with the destructive Forget on its own line. What
    // the server DOES (transcribe / speak) is set up independently in the
    // Speech-to-Text + Text-to-Speech sections below; the per-direction model
    // lives there, not here.

    private var connectionSection: some View {
        Section {
            nameField
            urlField
            authToggle
            secretRow           // ordinary row; SecureField lives in SecretEntrySheet
        } header: {
            Text(LocalizedStringResource("settings.voice.section.connection", defaultValue: "Connection"))
        } footer: {
            Text(LocalizedStringResource(
                "settings.stt.custom.connection.footer",
                defaultValue: "Your own OpenAI-compatible server — it can do speech-to-text, text-to-speech, or both."
            ))
        }
    }

    // MARK: - Speech-to-Text Section (activation + Test)

    private var speechToTextSection: some View {
        Section {
            // ONE row holding a leading-aligned VStack — mirrors the built-in
            // `ProviderConfigBody` (which is itself one Section row wrapping a
            // `VStack(alignment: .leading)`). This is what keeps the bordered
            // Test button at its compact intrinsic size; a bordered Button placed
            // as its OWN Section row stretches to fill the full row width.
            VStack(alignment: .leading, spacing: 12) {
                modelField
                actionRow
                statusRow
            }
        } header: {
            Text(LocalizedStringResource("settings.voice.section.speechToText", defaultValue: "Speech-to-Text"))
        } footer: {
            Text(LocalizedStringResource(
                "settings.stt.custom.stt.footer",
                defaultValue: "Test connection sends a one-second clip through your server."
            ))
        }
    }

    // MARK: - Name field (custom endpoint — Phase B)

    @ViewBuilder
    private var nameField: some View {
        let nameBinding = Binding<String>(
            get: { viewModel.customVoiceEndpointName(for: uuid) },
            set: { viewModel.setCustomVoiceEndpointName($0, for: uuid) }
        )
        VStack(alignment: .leading, spacing: 4) {
            Text(LocalizedStringResource("settings.voice.custom.name.label", defaultValue: "Name"))
                .font(.subheadline)
                .foregroundStyle(AppColors.textPrimary)
            TextField(
                "",
                text: nameBinding,
                prompt: Text(LocalizedStringResource(
                    "settings.voice.custom.name.placeholder",
                    defaultValue: "My endpoint"
                ))
            )
                .labelsHidden()
                #if os(iOS)
                .textInputAutocapitalization(.words)
                #endif
                .autocorrectionDisabled()
                .textFieldStyle(.roundedBorder)
            if viewModel.customVoiceEndpointNameClashes(nameBinding.wrappedValue, excludingID: uuid) {
                Label(
                    LocalizedStringResource(
                        "settings.voice.custom.name.duplicate",
                        defaultValue: "Another endpoint already uses this name."
                    ),
                    systemImage: "exclamationmark.triangle"
                )
                .font(.caption2)
                .foregroundStyle(AppColors.warning)
            }
        }
    }

    @ViewBuilder
    private var urlField: some View {
        let urlBinding = Binding<String>(
            get: { viewModel.customSTTURLStrings[uuid] ?? "" },
            set: { viewModel.customSTTURLStrings[uuid] = $0 }
        )
        VStack(alignment: .leading, spacing: 4) {
            Text(LocalizedStringResource("settings.stt.custom.url.label", defaultValue: "Endpoint base URL"))
                .font(.subheadline)
                .foregroundStyle(AppColors.textPrimary)
            TextField(
                "",
                text: urlBinding,
                prompt: Text(LocalizedStringResource(
                    "settings.stt.custom.url.placeholder",
                    defaultValue: "https://whisper.example.com"
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
            Text(LocalizedStringResource(
                "settings.stt.custom.url.hint.both",
                defaultValue: "Just the base — Conduck adds /v1/audio/transcriptions or /v1/audio/speech."
            ))
                .font(.caption2)
                .foregroundStyle(AppColors.textTertiary)
            if let portHint = nonStandardPortHint {
                Text(portHint)
                    .font(.caption2)
                    .foregroundStyle(AppColors.textTertiary)
            }
        }
    }

    /// Inline Toggle for the two auth schemes the BYO endpoint supports
    /// (`.bearer` when ON, `.none` when OFF — the only schemes valid here).
    ///
    /// This row carries the keyless affordance: its helper `Text` swaps its STRING
    /// on the toggle, and the flip drives `secretRow`'s presence (the API-key
    /// summary row shows ONLY under `.bearer`, disappears when keyless). The secret
    /// itself is entered in `SecretEntrySheet` — there is NO `SecureField` anywhere
    /// in this Form, so showing/hiding `secretRow` on `isKeyless` can't trip the
    /// out-of-process macOS `NSSecureTextField` layout recursion the old inline
    /// `keyField` had to dodge (see `SecretEntrySheet.swift`).
    @ViewBuilder
    private var authToggle: some View {
        // The helper caption lives INSIDE the Toggle's label (as a subtitle), not
        // in an outer VStack below it. That makes the switch vertically center
        // against the whole title+caption block — the native iOS Settings idiom —
        // instead of hugging the top of a tall cell next to the title alone.
        Toggle(isOn: Binding<Bool>(
            get: { !isKeyless },
            set: { requiresKey in
                // BUFFER-ONLY (Save is the single commit point). Routes through
                // the buffer setter so Cancel can revert; Save persists it.
                viewModel.setCustomSTTAuthSchemeBuffer(requiresKey ? .bearer : .none, for: uuid)
                if !requiresKey { pendingKey = "" }   // drop a typed-but-unsaved key when going keyless
            }
        )) {
            VStack(alignment: .leading, spacing: 3) {
                Text(LocalizedStringResource("settings.stt.custom.auth.requiresKey.label", defaultValue: "Requires an API key"))
                    .font(.subheadline)
                    .foregroundStyle(AppColors.textPrimary)
                // String-swap (NOT an if/else producing two Texts) so the view
                // identity is stable — only the localized content differs.
                Text(isKeyless
                    ? LocalizedStringResource(
                        "settings.stt.custom.auth.keyless.helper",
                        defaultValue: "Keyless local server — Conduck sends no Authorization header and the API key below is ignored."
                    )
                    : LocalizedStringResource(
                        "settings.stt.custom.auth.requiresKey.helper",
                        defaultValue: "Turn off for a keyless local server — Conduck sends no Authorization header."
                    ))
                    .font(.caption2)
                    .foregroundStyle(AppColors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .tint(AppColors.brandAmber)
    }

    // MARK: - Secret row (tap-in entry; the SecureField lives in SecretEntrySheet,
    // never inline in this Form — see SecretEntrySheet.swift for why).

    @ViewBuilder
    private var secretRow: some View {
        if !isKeyless {
            Button {
                showingSecretSheet = true
            } label: {
                HStack {
                    Text(LocalizedStringResource("settings.stt.custom.key.label", defaultValue: "API key"))
                        .font(.subheadline)
                        .foregroundStyle(AppColors.textPrimary)
                    Spacer()
                    secretStatusLabel
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AppColors.textTertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private var secretStatusLabel: some View {
        if !pendingKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Text(LocalizedStringResource("settings.secret.entered", defaultValue: "Entered"))
                .font(.caption)
                .foregroundStyle(AppColors.success)
        } else if let masked = viewModel.customSTTMaskedTails[uuid], case .valid = rowState {
            Text(masked)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(AppColors.textTertiary)
        } else {
            Text(LocalizedStringResource("settings.secret.notSet", defaultValue: "Set"))
                .font(.caption)
                .foregroundStyle(AppColors.textTertiary)
        }
    }

    @ViewBuilder
    private var modelField: some View {
        let modelBinding = Binding<String>(
            get: { viewModel.customSTTModels[uuid] ?? "" },
            set: { viewModel.customSTTModels[uuid] = $0 }
        )
        VStack(alignment: .leading, spacing: 4) {
            Text(LocalizedStringResource("settings.stt.custom.model.label", defaultValue: "Model"))
                .font(.subheadline)
                .foregroundStyle(AppColors.textPrimary)
            TextField("", text: modelBinding, prompt: Text(verbatim: "whisper-1"))
                .labelsHidden()
                .font(.system(.body, design: .monospaced))
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .keyboardType(.asciiCapable)
                #endif
                .autocorrectionDisabled()
                .textFieldStyle(.roundedBorder)
            Text(LocalizedStringResource(
                "settings.stt.custom.model.helper",
                defaultValue: "Default whisper-1. Set the tag your server expects."
            ))
                .font(.caption2)
                .foregroundStyle(AppColors.textTertiary)
        }
    }

    // MARK: - Text-to-Speech Section
    //
    // The custom endpoint serves BOTH directions: TTS hits `/v1/audio/speech` on
    // the SAME base URL, key, cert pin, and auth scheme configured above — only
    // the voice + model are TTS-specific. The section renders UNCONDITIONALLY (a
    // peer of Speech-to-Text, matching the built-in providers); an incomplete
    // connection fails LOUD via "Speak a sample" with a friendly, specific
    // message rather than a disabled/greyed gate.

    @ViewBuilder
    private var ttsSection: some View {
        Section {
            ttsVoiceField
            ttsModelField
            ttsActionRow
        } header: {
            Text(LocalizedStringResource("settings.tts.custom.header", defaultValue: "Text-to-Speech"))
        } footer: {
            ttsFooter
        }
    }

    @ViewBuilder
    private var ttsVoiceField: some View {
        let provider = TTSProvider.lookup(id: ttsProviderID)
        VStack(alignment: .leading, spacing: 4) {
            Text(LocalizedStringResource("settings.tts.custom.voice.label", defaultValue: "Voice"))
                .font(.subheadline)
                .foregroundStyle(AppColors.textPrimary)
            TextField("", text: $pendingTTSVoice, prompt: Text(verbatim: provider.defaultVoice))
                .labelsHidden()
                .font(.system(.body, design: .monospaced))
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .keyboardType(.asciiCapable)
                #endif
                .autocorrectionDisabled()
                .textFieldStyle(.roundedBorder)
                // Buffer-until-Save: the @State voice persists only on "Save
                // endpoint". No submit-persist (would commit mid-edit, defeating
                // Cancel). The buffer is auditioned live by "Speak a sample".
            Text(LocalizedStringResource(
                "settings.tts.custom.voice.helper",
                defaultValue: "Default alloy. Voice names are server-specific (e.g. alloy, af_bella)."
            ))
                .font(.caption2)
                .foregroundStyle(AppColors.textTertiary)
        }
    }

    @ViewBuilder
    private var ttsModelField: some View {
        let modelBinding = Binding<String>(
            get: { viewModel.customTTSModels[uuid] ?? "" },
            set: { viewModel.customTTSModels[uuid] = $0 }
        )
        VStack(alignment: .leading, spacing: 4) {
            Text(LocalizedStringResource("settings.tts.custom.model.label", defaultValue: "Speech model"))
                .font(.subheadline)
                .foregroundStyle(AppColors.textPrimary)
            TextField("", text: modelBinding, prompt: Text(verbatim: "tts-1"))
                .labelsHidden()
                .font(.system(.body, design: .monospaced))
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .keyboardType(.asciiCapable)
                #endif
                .autocorrectionDisabled()
                .textFieldStyle(.roundedBorder)
                // Buffer-until-Save: `customTTSModels[uuid]` is a buffer; it
                // persists only on "Save endpoint". No submit-persist.
            Text(LocalizedStringResource(
                "settings.tts.custom.model.helper",
                defaultValue: "Default tts-1. /v1/audio/speech needs a model — set the tag your server expects (e.g. tts-1, kokoro)."
            ))
                .font(.caption2)
                .foregroundStyle(AppColors.textTertiary)
        }
    }

    /// Audition the voice/model BUFFERS directly — so "Speak a sample" plays
    /// exactly what's on screen WITHOUT persisting first (buffer-until-Save).
    /// The previewer reads the editor's `pendingTTSVoice` @State + the per-uuid
    /// URL/model/auth/cert buffers + the typed key; Save is the only commit.
    @ViewBuilder
    private var ttsActionRow: some View {
        let isChecking = (viewModel.ttsPreviewStates[ttsProviderID] == .checking)
        HStack {
            Button {
                Task {
                    await viewModel.previewCustomTTSFromBuffers(
                        for: uuid,
                        voice: pendingTTSVoice,
                        typedKey: pendingKey
                    )
                }
            } label: {
                if isChecking {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(LocalizedStringResource("settings.voice.tts.previewPlaying", defaultValue: "Playing…"))
                            .font(.subheadline)
                    }
                } else {
                    Label(
                        LocalizedStringResource("settings.voice.tts.preview", defaultValue: "Speak a sample"),
                        systemImage: "speaker.wave.2"
                    )
                    .font(.subheadline.weight(.semibold))
                    .labelStyle(AccentGlyphActionLabelStyle())
                }
            }
            .buttonStyle(.bordered)
            .disabled(isChecking)
        }
    }

    @ViewBuilder
    private var ttsFooter: some View {
        if case .invalid(let message) = viewModel.ttsPreviewStates[ttsProviderID] {
            Text(message)
                .font(.caption)
                .foregroundStyle(AppColors.error)
        } else {
            Text(LocalizedStringResource(
                "settings.tts.custom.footer",
                defaultValue: "If a reply can't reach this provider, it's spoken with Apple's on-device voice. Apple Watch always uses the Apple voice."
            ))
        }
    }

    // MARK: - Save endpoint (the single commit point — surfaced in the chrome)

    /// Name + URL both non-empty — the minimum to persist a usable endpoint.
    /// Drives the chrome's top-trailing Save button enablement.
    private var canSave: Bool {
        let nameOK = !viewModel.customVoiceEndpointName(for: uuid)
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let urlOK = !(viewModel.customSTTURLStrings[uuid] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return nameOK && urlOK
    }

    /// Persist all buffers; dismiss on success. Stashes the @State voice buffer
    /// first so the VM can persist it (the VM can't read the View's @State).
    private func saveTapped() {
        let key = pendingKey
        let voice = pendingTTSVoice
        Task {
            viewModel.stagePendingTTSVoice(voice, for: uuid)
            let ok = await viewModel.saveCustomVoiceEndpoint(for: uuid, pendingKey: key)
            viewModel.clearStagedCustomTTSVoice(for: uuid)
            if ok {
                // Committed — skip the onDisappear cancel safety-net.
                suppressCancelOnExit = true
                pendingKey = ""
                dismiss()
            }
        }
    }

    // MARK: - Cancel (discard draft / revert edits)

    /// Whether any editable buffer diverged from its appear-time snapshot (or the
    /// user typed a key). Drives the Cancel confirm (via `bufferedEditorChrome`).
    /// A draft with NOTHING typed is pristine → Cancel dismisses without a prompt.
    private var isDirty: Bool {
        if !pendingKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
        if viewModel.customVoiceEndpointName(for: uuid) != originalName { return true }
        if (viewModel.customSTTURLStrings[uuid] ?? "") != originalURL { return true }
        if (viewModel.customSTTModels[uuid] ?? "") != originalSTTModel { return true }
        if (viewModel.customTTSModels[uuid] ?? "") != originalTTSModel { return true }
        if pendingTTSVoice != originalTTSVoice { return true }
        if (viewModel.customSTTCertFingerprints[uuid] ?? "") != originalCertFingerprint { return true }
        if isKeyless != originalAuthKeyless { return true }
        return false
    }

    /// "Test connection" — the Speech-to-Text section's single action (runs the
    /// full staged suite for the custom endpoint). Quiet `.bordered`, matching
    /// every other provider's Test affordance. NOT `.borderedProminent`: a
    /// prominent button gets the Form's full-width treatment and renders as a
    /// giant pill (worse when disabled → grey blob); `.bordered` stays a compact
    /// left-aligned pill.
    private var actionRow: some View {
        // ALWAYS tappable (matching the built-in voice-provider screens) except
        // while a test is in flight. An incomplete connection fails LOUD with a
        // friendly message rather than greying the button. The leading-aligned
        // VStack (see `speechToTextSection`) keeps the bordered capsule left.
        Button {
            runTest()
        } label: {
            Label(
                LocalizedStringResource("settings.remoteAgent.testConnection.button", defaultValue: "Test Connection"),
                systemImage: "checkmark.shield"
            )
            .font(.subheadline.weight(.semibold))
            .labelStyle(AccentGlyphActionLabelStyle())
        }
        .buttonStyle(.bordered)
        .disabled(rowState == .checking)
    }

    /// The destructive "Delete endpoint" action in its OWN bottom Section —
    /// plain red, isolated from the config fields (iOS HIG). ALWAYS shown once
    /// the endpoint exists in the roster (a name-only endpoint must be removable).
    /// `clearCustomSTT` removes the roster entry + every per-uuid slot and
    /// repoints the active STT/TTS pointer to Apple; we then dismiss to the list.
    @ViewBuilder
    private var destructiveSection: some View {
        if viewModel.customVoiceEndpoints.contains(where: { $0.id == uuid }) {
            Section {
                Button(role: .destructive) {
                    showingDeleteConfirm = true
                } label: {
                    // iOS: centered red row (grouped-list HIG). macOS: a quiet
                    // left-aligned red text button — the centered+Spacer row renders
                    // as a heavy filled red slab in a macOS grouped Form.
                    #if os(macOS)
                    Label(
                        LocalizedStringResource("settings.voice.custom.delete.button", defaultValue: "Delete endpoint"),
                        systemImage: "trash"
                    )
                    .font(.subheadline)
                    #else
                    HStack {
                        Spacer()
                        Label(
                            LocalizedStringResource("settings.voice.custom.delete.button", defaultValue: "Delete endpoint"),
                            systemImage: "trash"
                        )
                        .font(.subheadline)
                        Spacer()
                    }
                    #endif
                }
                #if os(macOS)
                .buttonStyle(.plain)
                #endif
                .foregroundStyle(AppColors.error)
            }
        }
    }

    // MARK: - Credit hint (quiet trailing footnote)

    /// A quiet trailing note that the Test/Preview actions spend a little of the
    /// user's provider credits — parity with the built-in voice-provider screens
    /// (`VoiceProviderDetailView.creditHintFootnote`). Reuses the SAME catalog key.
    private var creditHintFootnote: some View {
        Section {
            EmptyView()
        } footer: {
            Text(LocalizedStringResource(
                "settings.voice.detail.creditHint",
                defaultValue: "Tests and previews use a small amount of your provider's credits."
            ))
            .font(.caption)
            .foregroundStyle(AppColors.textSecondary)
        }
    }

    /// Run the FULL staged Test — VALIDATE-ONLY now (Save is the single commit
    /// point; Test never persists). Two paths: a freshly-typed key → validate
    /// with it; the key field empty BUT a key already stored (or `.none` auth) →
    /// re-validate the saved config (the key is read from Keychain in-actor,
    /// never re-displayed). NOTE: unlike before, the SecureField buffer is NOT
    /// cleared here — Save still needs the typed key to persist it.
    private func runTest() {
        let key = pendingKey
        let url = viewModel.customSTTURLStrings[uuid] ?? ""
        let model = viewModel.customSTTModels[uuid] ?? ""
        Task {
            if key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                await viewModel.retestCustomSTT(for: uuid, url: url, model: model)
            } else {
                await viewModel.validateCustomSTT(for: uuid, url: url, key: key, model: model)
            }
        }
    }

    @ViewBuilder
    private var statusRow: some View {
        switch rowState {
        case .unset:
            EmptyView()
        case .checking:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(LocalizedStringResource("settings.remoteAgent.testConnection.checking", defaultValue: "Checking…"))
                    .font(.subheadline)
                    .foregroundStyle(AppColors.textSecondary)
            }
        case .valid:
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(AppColors.success)
                Text(LocalizedStringResource("settings.remoteAgent.testConnection.success", defaultValue: "Connected"))
                    .font(.subheadline)
                    .foregroundStyle(AppColors.textSecondary)
            }
        case .invalid(let message):
            // While the iOS TOFU affordance is up (untrusted cert, no pin), the
            // checklist's banner is the richer prompt — suppress this red row.
            if viewModel.customSTTPendingUntrustedCerts[uuid] == nil {
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
    }

    // MARK: - Rich staged checklist

    @ViewBuilder
    private var testSuiteSection: some View {
        if let result = viewModel.sttTestSuiteResults[presetID] {
            Section {
                STTTestSuiteResultView(
                    result: result,
                    onTrustAndSave: { trustAndSave() }
                )
                .padding(.vertical, 4)
            } header: {
                Text(LocalizedStringResource("settings.stt.custom.testResult.header", defaultValue: "Test result"))
            }
        }
    }

    /// Pin the presented fingerprint into the buffer + re-VALIDATE (Trust-only —
    /// no persist; Save commits). Requires the key again (privacy: never read
    /// back from Keychain) — the user re-pastes before Trust. For `.none` auth no
    /// key is needed. The SecureField buffer is NOT cleared (Save still needs it).
    private func trustAndSave() {
        let key = pendingKey
        let url = viewModel.customSTTURLStrings[uuid] ?? ""
        let model = viewModel.customSTTModels[uuid] ?? ""
        Task {
            await viewModel.trustPresentedCustomCert(for: uuid, url: url, key: key, model: model)
        }
    }

    // MARK: - Advanced (manual cert pinning)

    private var advancedSection: some View {
        let fingerprintBinding = Binding<String>(
            get: { viewModel.customSTTCertFingerprints[uuid] ?? "" },
            set: { viewModel.customSTTCertFingerprints[uuid] = $0 }
        )
        return Section {
            DisclosureGroup(isExpanded: $advancedExpanded) {
                VStack(alignment: .leading, spacing: 4) {
                    TextField(
                        "",
                        text: fingerprintBinding,
                        prompt: Text(LocalizedStringResource(
                            "settings.remoteAgent.fingerprint.placeholder",
                            defaultValue: "SHA-256 hex (optional)"
                        ))
                    )
                        .labelsHidden()
                        .font(.system(.body, design: .monospaced))
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.asciiCapable)
                        #endif
                        .autocorrectionDisabled()
                        .textFieldStyle(.roundedBorder)
                    Text(LocalizedStringResource(
                        "settings.remoteAgent.fingerprint.helperShort",
                        defaultValue: "Leave empty for system trust. Self-signed certs are pinned automatically via Trust & Save above."
                    ))
                        .font(.caption2)
                        .foregroundStyle(AppColors.textTertiary)
                }
                .padding(.top, 4)
            } label: {
                Text(LocalizedStringResource(
                    "settings.remoteAgent.fingerprint.label",
                    defaultValue: "Pinned cert fingerprint"
                ))
                    .foregroundStyle(AppColors.textPrimary)
                    .tappableDisclosureLabel($advancedExpanded)
            }
        } header: {
            Text(LocalizedStringResource("settings.remoteAgent.advanced.header", defaultValue: "Advanced"))
        }
    }

    // MARK: - Port-hint logic

    /// A confirming "port N" hint, surfaced ONLY when the user typed a
    /// non-standard explicit port. Returns nil for 443 / no explicit port /
    /// an unparseable URL. Mirrors `RemoteAgentConfigBody.nonStandardPortHint`.
    private var nonStandardPortHint: String? {
        let trimmed = (viewModel.customSTTURLStrings[uuid] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let components = URLComponents(string: trimmed),
              let port = components.port,
              port != 443
        else {
            return nil
        }
        return String(
            format: String(localized: LocalizedStringResource(
                "settings.remoteAgent.url.portHint",
                defaultValue: "Using port %lld"
            )),
            port
        )
    }
}
