// SPDX-License-Identifier: Apache-2.0

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
//     row is absent entirely. NO `SecureField` is ever inline in this editor
//     (out-of-process macOS `NSSecureTextField` layout-recursion — see
//     `SecretEntrySheet.swift`).
//   - Optional model field (default `whisper-1`).
//   - Test (runs the FULL staged suite — the custom endpoint's default Test
//     action) + Forget.
//   - The rich staged checklist (`STTTestSuiteResultView`) with per-stage
//     status + transcript + latency. Read-only: every outcome is a pass or a
//     terminal explained failure.
//   - Advanced — the optional manual cert-fingerprint pin, a `DisclosureGroup`
//     on iOS and a hand-rolled expander on macOS (see `advancedSection`).
//
// The Speech-to-Text footer carries the transcription disclosure: a configured
// endpoint's output IS the user's instruction to an agent that may hold tools,
// and the hands-free surfaces (CarPlay, Watch, Shortcuts) dispatch that
// instruction unread. Auto-dispatch is the design, not a defect, so the honest
// place to say it is configuration time — which is why the line is plain footer
// copy: no icon, no colour, no confirmation step, nothing that reads as a
// warning about a behaviour the user is choosing.
//
// Privacy invariants (same as the gateway body):
//   - The API key never leaves the editor-local `pendingKey` buffer (seeded into /
//     committed from `SecretEntrySheet`'s transient `draft`); cleared after a save
//     attempt. Keychain is the only persistence.
//   - The masked tail is the only key surface once stored.
//
// Cross-platform (iOS + macOS): the body is shared. UIKit-only TextField
// modifiers are `#if os(iOS)`-gated.
//
// The container is `PlatformSettingsForm` — a grouped `Form` on iOS, hand-drawn
// `SettingsCard`s on macOS — so the section tree is written once. On macOS the
// card pads nothing, so every row supplies its own inset: an action row — the
// auth switch among them, wrapped in a `Button` so the whole row flips it —
// through `.settingsCardRowButton()`, and each field block through
// `.settingsCardPassiveRow()`, which withholds the hover wash a multi-control
// row has not earned. The three places that fork for macOS fork the CONTAINER
// or the row treatment only, never the copy: the auth row's label/switch split,
// the Advanced expander, and the destructive row's alignment.

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
    /// `SecureField` exists — never inline in this editor).
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
    /// committed; Delete already wiped). For every OTHER exit — the chrome's Back
    /// chevron, a swipe-back, the macOS native back chevron (which
    /// `navigationBarBackButtonHidden` can't hide), or the whole Settings sheet
    /// closing — `.onDisappear` runs the cancel cleanup, so unsaved buffers/drafts
    /// never linger. The VM's cancel uses the store as the sole authority, so this
    /// is robust on both platforms.
    @State private var suppressCancelOnExit: Bool = false

    /// Snapshot of the editable buffers on appear, for dirty-detection (the exit
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

    /// True while a Save commit is in flight — feeds `canSave` so the button
    /// greys for the duration of its own multi-await chain.
    @State private var saving: Bool = false

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
        // One section tree for both platforms: a grouped `Form` on iOS, a stack
        // of hand-drawn `SettingsCard`s on macOS. The macOS branch also carries
        // the page chrome the `Form` supplies on iOS — the scroll surface, the
        // 28pt window gutter every other settings surface uses, and the shared
        // `MacSettingsRail` reading column — so nothing here wraps or pads it.
        // The editor chrome's full-width header arrives AFTER this via
        // `.safeAreaInset(.top)`, so it stays edge to edge while the content
        // sits inside the gutter.
        //
        // Each `@ViewBuilder` section below emits a WHOLE `Section` or nothing.
        // That shape is load-bearing on macOS: `Group(sections:)` counts Section
        // declarations to decide how many cards to draw, and narrowing one of
        // these conditionals to wrap content INSIDE a Section would change that
        // count with nothing to catch it at compile time.
        PlatformSettingsForm {
            connectionSection
            speechToTextSection
            testSuiteSection
            ttsSection
            advancedSection
            destructiveSection
            creditHintFootnote
        }
        .scrollContentBackground(.hidden)
        .scrollDismissesKeyboard(.interactively)
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
            viewModel: viewModel,
            onDiscard: { await viewModel.cancelCustomVoiceEndpointEdit(for: uuid) },
            suppressCancelOnExit: $suppressCancelOnExit,
            title: editorTitle,
            saveTitle: LocalizedStringResource("settings.editor.save", defaultValue: "Save"),
            // Always a PUSH from the voice-provider list — never a modal root.
            exit: .back,
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
            // One composite row, not a single action — the field, the Test
            // button and the outcome line all live here — so it takes the inset
            // and pitch and no wash. The leading-aligned stack is what keeps the
            // bordered Test button at its compact intrinsic size inside it.
            .settingsCardPassiveRow()
        } header: {
            Text(LocalizedStringResource("settings.voice.section.speechToText", defaultValue: "Speech-to-Text"))
        } footer: {
            // Two footer lines, stacked explicitly rather than left as two loose
            // subviews: the macOS card lays its footer slot out with zero
            // spacing, so an own `VStack` is what gives the second line its
            // gap on both platforms.
            VStack(alignment: .leading, spacing: 6) {
                Text(LocalizedStringResource(
                    "settings.stt.custom.stt.footer",
                    defaultValue: "Test connection sends a one-second clip through your server."
                ))
                // The transcription disclosure — see the file header.
                Text(LocalizedStringResource(
                    "settings.stt.custom.stt.instructionNotice",
                    defaultValue: "What this endpoint transcribes becomes the instruction your AI acts on with its tools — and on CarPlay, Apple Watch, or a Shortcut it's sent without you reading it first."
                ))
            }
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
        // A field block, not a single action: inset and pitch, no wash.
        .settingsCardPassiveRow()
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
            if let plainHTTPHint {
                // Warning-tinted rather than tertiary: the hints above CONFIRM
                // what the user typed, this one states a consequence.
                Text(plainHTTPHint)
                    .font(.caption2)
                    .foregroundStyle(AppColors.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .settingsCardPassiveRow()
    }

    /// Warns that an accepted plain-http address is readable by anyone else on
    /// the network it rides. The SAME key and SAME string every other endpoint
    /// field uses (`EndpointURLPolicy` admits all three the same way), so one
    /// fact has one wording. Advisory only — the platform has already decided it
    /// will send to this address.
    private var plainHTTPHint: String? {
        let trimmed = (viewModel.customSTTURLStrings[uuid] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard EndpointURLPolicy.isAdmittedPlainHTTPURLString(trimmed) else { return nil }
        return String(localized: LocalizedStringResource(
            "settings.endpoint.plainHTTP.warning.v2",
            defaultValue: "Not encrypted — anyone on this network can read your messages and your key. Works only on this network — not in the car or out with the Watch."
        ))
    }

    /// Inline Toggle for the two auth schemes the BYO endpoint supports
    /// (`.bearer` when ON, `.none` when OFF — the only schemes valid here).
    ///
    /// This row carries the keyless affordance: its helper `Text` swaps its STRING
    /// on the toggle, and the flip drives `secretRow`'s presence (the API-key
    /// summary row shows ONLY under `.bearer`, disappears when keyless). The secret
    /// itself is entered in `SecretEntrySheet` — there is NO `SecureField` anywhere
    /// in this editor, so showing/hiding `secretRow` on `isKeyless` can't trip the
    /// out-of-process macOS `NSSecureTextField` layout recursion the old inline
    /// `keyField` had to dodge (see `SecretEntrySheet.swift`).
    @ViewBuilder
    private var authToggle: some View {
        let requiresKeyBinding = Binding<Bool>(
            get: { !isKeyless },
            set: { requiresKey in
                // BUFFER-ONLY (Save is the single commit point). Routes through
                // the buffer setter so Cancel can revert; Save persists it.
                viewModel.setCustomSTTAuthSchemeBuffer(requiresKey ? .bearer : .none, for: uuid)
                if !requiresKey { pendingKey = "" }   // drop a typed-but-unsaved key when going keyless
            }
        )
        #if os(macOS)
        // Outside a grouped `Form` a `Toggle` keeps its label glued to its
        // control instead of splitting the two across the row, and `.automatic`
        // resolves to a CHECKBOX rather than a switch — so the card row lays the
        // pair out by hand, exactly as `MacGeneralCategory.toggleRow` does, down
        // to wrapping the pair in the `Button` that gives the label back the
        // click a `Form`'s `Toggle` label has for free. The switch itself is
        // `.allowsHitTesting(false)` so a click on it reaches that one `Button`
        // rather than firing a second, cancelling flip, and
        // `.accessibilityRepresentation` collapses the pair back into the single
        // standard switch VoiceOver expects.
        Button {
            requiresKeyBinding.wrappedValue.toggle()
        } label: {
            HStack(alignment: .center, spacing: 12) {
                authToggleLabel
                Spacer(minLength: 8)
                Toggle(isOn: requiresKeyBinding) { EmptyView() }
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .tint(AppColors.brandAmber)
                    .allowsHitTesting(false)
            }
        }
        .settingsCardRowButton()
        .accessibilityRepresentation {
            Toggle(isOn: requiresKeyBinding) {
                Text(LocalizedStringResource(
                    "settings.stt.custom.auth.requiresKey.label",
                    defaultValue: "Requires an API key"
                ))
            }
        }
        #else
        // The helper caption lives INSIDE the Toggle's label (as a subtitle), not
        // in an outer VStack below it. That makes the switch vertically center
        // against the whole title+caption block — the native iOS Settings idiom —
        // instead of hugging the top of a tall cell next to the title alone.
        Toggle(isOn: requiresKeyBinding) { authToggleLabel }
            .tint(AppColors.brandAmber)
        #endif
    }

    /// The auth row's two-line label, identical on both platforms — only where
    /// it sits relative to the switch differs (see `authToggle`).
    private var authToggleLabel: some View {
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

    // MARK: - Secret row (tap-in entry; the SecureField lives in SecretEntrySheet,
    // never inline in this editor — see SecretEntrySheet.swift for why).

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
            // A whole-row action, so it takes the live full-bleed card row. Its
            // inset is the card's own `rowInset`, applied INSIDE the live frame —
            // the same inset the passive field rows above it supply for
            // themselves, so "API key" stays flush with the Name / URL / auth
            // labels stacked above it in the same Connection section.
            .settingsCardRowButton()
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
        .settingsCardPassiveRow()
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
        .settingsCardPassiveRow()
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
        // The compact bordered pill stays a pill on both platforms — it is the
        // Test-to-audition twin of the Speech-to-Text section's Test button, and
        // the two have to read the same. The row around it therefore claims no
        // wash it cannot honour.
        .settingsCardPassiveRow()
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

    /// Whether Save may fire: VALID *and* something changed, with no commit
    /// already in flight. Validity alone would leave Save armed on an untouched
    /// endpoint, inviting a pointless re-commit — see `RemoteAgentConfigBody`'s
    /// `canSave` for the full argument; the two editors gate identically.
    private var canSave: Bool { isValidForSave && isDirty && !saving }

    /// Name + URL both non-empty — the minimum to persist a usable endpoint.
    /// Validity ONLY; `canSave` adds the dirty + in-flight gates.
    private var isValidForSave: Bool {
        let nameOK = !viewModel.customVoiceEndpointName(for: uuid)
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let urlOK = !(viewModel.customSTTURLStrings[uuid] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return nameOK && urlOK
    }

    /// Persist all buffers; dismiss on success. Stashes the @State voice buffer
    /// first so the VM can persist it (the VM can't read the View's @State).
    private func saveTapped() {
        // Re-entrancy gate — the commit spans awaits with the button still on
        // screen; `canSave` reads `saving` so it greys rather than double-firing.
        guard !saving else { return }
        saving = true
        let key = pendingKey
        let voice = pendingTTSVoice
        Task {
            defer { saving = false }
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
    /// user typed a key). Drives the discard confirm (via `bufferedEditorChrome`).
    /// A draft with NOTHING typed is pristine → Back leaves without a prompt.
    ///
    /// Pristine until seeded, ALWAYS — `body` evaluates before `.onAppear`, so
    /// until then the `original*` baselines are `""` against already-populated
    /// buffers and every comparison below reports an edit the user never made.
    /// Safe by construction (no edit can precede seeding), and load-bearing:
    /// without it `canSave` flashes enabled on every pristine open.
    private var isDirty: Bool {
        guard didInitialize else { return false }
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
                LocalizedStringResource("settings.voice.testConnection.button", defaultValue: "Test voice"),
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
                // macOS only, deliberately: off macOS this row keeps the default
                // button style, which is what gives a `role: .destructive` row
                // its native grouped-list treatment. `.settingsCardRowButton()`
                // resolves to `.buttonStyle(.plain)` there and would take it away.
                #if os(macOS)
                .settingsCardRowButton()
                #endif
                .foregroundStyle(AppColors.error)
            }
        }
    }

    // MARK: - Credit hint (quiet trailing footnote)

    /// A quiet trailing note that the Test/Preview actions spend a little of the
    /// user's provider credits — parity with the built-in voice-provider screens
    /// (`VoiceProviderDetailView.creditHintFootnote`). Reuses the SAME catalog key.
    ///
    /// A footer with no content row: `EmptyView()` contributes no row, so on
    /// macOS the section's card has nothing to draw and collapses to nothing,
    /// leaving the caption alone under the last real card — the same result the
    /// grouped `Form` gives on iOS.
    private var creditHintFootnote: some View {
        Section {
            EmptyView()
        } footer: {
            Text(LocalizedStringResource(
                "settings.voice.detail.creditHint",
                defaultValue: "Tests and previews use a small amount of your provider's credits."
            ))
            .font(.caption)
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

    // MARK: - Rich staged checklist

    @ViewBuilder
    private var testSuiteSection: some View {
        if let result = viewModel.sttTestSuiteResults[presetID] {
            Section {
                STTTestSuiteResultView(result: result)
                    .padding(.vertical, 4)
                    // Read-only checklist — inset and pitch, never a wash.
                    .settingsCardPassiveRow()
            } header: {
                Text(LocalizedStringResource("settings.stt.custom.testResult.header", defaultValue: "Test result"))
            }
        }
    }

    // MARK: - Advanced (optional manual cert pinning)

    /// TWO IMPLEMENTATIONS, one set of strings — the `VoiceReliabilityDisclosure`
    /// shape. iOS keeps `DisclosureGroup`, where the whole row already toggles.
    /// macOS hand-rolls the expander and OWNS the chevron, because
    /// `DisclosureGroup` renders its chevron in a slot OUTSIDE the label: the
    /// label can therefore never span the row, so the row cannot be one uniform
    /// target while the DisclosureGroup owns the layout — and inside a card,
    /// where every sibling row is live edge to edge, a row whose live area stops
    /// short of the chevron is exactly the miss this screen exists to remove.
    /// Drawing the chevron inside a `Button` label makes the whole row that
    /// target, and unlike the tap gesture `tappableDisclosureLabel` installs, a
    /// real `Button` carries keyboard activation, VoiceOver activation and a
    /// pressed state.
    @ViewBuilder
    private var advancedSection: some View {
        let fingerprintBinding = Binding<String>(
            get: { viewModel.customSTTCertFingerprints[uuid] ?? "" },
            set: { viewModel.customSTTCertFingerprints[uuid] = $0 }
        )
        Section {
            #if os(macOS)
            // Row + expanded body stacked with ZERO spacing: the whole stack is
            // one card row, so the button's own frame supplies the live area and
            // the body hangs off it.
            VStack(alignment: .leading, spacing: 0) {
                Button {
                    withAnimation { advancedExpanded.toggle() }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(AppColors.textTertiary)
                            // Driven from inside the action's `withAnimation`, so
                            // the turn rides the same transaction as the reveal
                            // below — no second animation modifier to drift out
                            // of step with it.
                            .rotationEffect(.degrees(advancedExpanded ? 90 : 0))
                            // Decoration: `advancedLabel` already names the row.
                            .accessibilityHidden(true)
                        advancedLabel
                        Spacer()
                    }
                }
                .settingsCardRowButton()
                // A hand-rolled expander announces none of the disclosure state
                // a `DisclosureGroup` carries natively, so the hint says what
                // activating it does — same as the other two expanders.
                .accessibilityHint(Text(advancedExpanded ? "Collapse" : "Expand")) // xcstrings: advanced-model

                if advancedExpanded {
                    advancedBody(fingerprintBinding)
                        // A passive continuation of the row above rather than a
                        // row of its own, so it carries the card's inset itself
                        // to line up with the button label.
                        .padding(.horizontal, SettingsCardMetrics.rowInset)
                        .padding(.bottom, 12)
                }
            }
            #else
            DisclosureGroup(isExpanded: $advancedExpanded) {
                advancedBody(fingerprintBinding)
            } label: {
                advancedLabel
                    .tappableDisclosureLabel($advancedExpanded)
            }
            #endif
        } header: {
            Text(LocalizedStringResource("settings.remoteAgent.advanced.header", defaultValue: "Advanced"))
        }
    }

    /// The Advanced row's title — one string, both expander shapes.
    private var advancedLabel: some View {
        Text(LocalizedStringResource(
            "settings.remoteAgent.fingerprint.label",
            defaultValue: "Pinned cert fingerprint"
        ))
            .foregroundStyle(AppColors.textPrimary)
    }

    /// The expanded body — the fingerprint field plus its caveat. Shared by both
    /// expander shapes; platform-specific insets belong to the call site.
    private func advancedBody(_ fingerprintBinding: Binding<String>) -> some View {
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
                "settings.remoteAgent.fingerprint.helperShort.v2",
                defaultValue: "Optional. Conduck already refuses any certificate this device doesn't trust; a fingerprint narrows that to one exact certificate. Leave it empty unless you have a reason."
            ))
                .font(.caption2)
                .foregroundStyle(AppColors.textTertiary)
            if let pinOnPlainHTTPBlocker {
                Text(pinOnPlainHTTPBlocker)
                    .font(.caption2)
                    .foregroundStyle(AppColors.warning)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.top, 4)
    }

    /// The always-visible refusal for a saved fingerprint paired with a
    /// plain-http address — the twin of `RemoteAgentConfigBody`'s, reading the
    /// same two BUFFERS this screen edits so the pair announces itself the moment
    /// Advanced is opened rather than only after Save refuses. Same string as the
    /// VM's own save guard, so the pre-emptive blocker and the post-Save message
    /// cannot diverge.
    private var pinOnPlainHTTPBlocker: String? {
        let trimmedURL = (viewModel.customSTTURLStrings[uuid] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPin = (viewModel.customSTTCertFingerprints[uuid] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPin.isEmpty,
              let url = URL(string: trimmedURL),
              EndpointURLPolicy.pinCannotApply(to: url) else { return nil }
        return SettingsViewModel.pinOnPlainHTTPMessage
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
