#if os(macOS)
// Conduck
// MacVoiceCategory.swift
//
// macOS Settings → Voice category. Pure speech CONFIG — engine/provider setup
// only (the "where/when it's used" toggles live with their surface). One section:
//   - "Voice Setup"  — the Speech-to-Text selector, the Text-to-Speech selector,
//     and a "Providers & Keys" row drilling into `MacVoiceProvidersList` (the
//     provider library: built-ins + custom endpoints + the Add row).
// The Mac quick-lane auto-speak toggle ("Speak replies") moved to General →
// Menu Bar, next to "Ask with" — its input/output sibling. (iOS keeps its own
// "Spoken Replies" toggle under Voice; macOS pairs output with the menu-bar
// surface instead.) The global Language hint lives in the STT chooser
// (`VoiceActiveProviderPicker`), not on this screen.
//
// Navigation: the category's `navigationDestination(item: $route)` handles the
// per-direction chooser (`.chooser`) and the providers drill-in (`.providers`).
// The per-vendor detail is reached via a SCOPED String destination in TWO
// sibling places that never coexist — inside the chooser (`chooserVendorRoute`,
// for "Set up…") and inside `MacVoiceProvidersList` (its own `vendorRoute`, for
// library rows) — so there is never a duplicate `String` destination on one
// stack. The detail itself is the shared `MacVoiceVendorDetail` (custom →
// `CustomSTTConfigBody`; built-in → the Provider Access + STT + TTS Form).

import SwiftUI

/// A typed navigation route for the macOS Voice category — a per-direction
/// chooser, the provider-library drill-in, or a direct vendor-detail push
/// (`.vendor`, the key-readiness banner's Add/Manage Key — a TYPED case so it
/// can't collide with the chooser's / library's scoped String destinations).
/// Mirrors the iOS `VoiceRoute`.
private enum MacVoiceRoute: Hashable {
    case chooser(VoiceDirection)
    case providers
    case vendor(String)
}

struct MacVoiceCategory: View {
    @Bindable var viewModel: SettingsViewModel

    @State private var route: MacVoiceRoute?

    /// Scoped vendor-detail push from the CHOOSER's "Set up…" deep-link only.
    @State private var chooserVendorRoute: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(LocalizedStringResource("settings.voice.detail.title", defaultValue: "Voice"))
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(AppColors.textEmphasis)
                        .padding(.horizontal, 28)
                        .padding(.top, 28)

                    Form {
                        keyReadinessSection
                        voiceSetupSection
                    }
                    .formStyle(.grouped)
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 28)
                    .padding(.bottom, 28)
                }
            }
            .navigationDestination(item: $route) { route in
                switch route {
                case .chooser(let direction):
                    chooser(for: direction)
                case .providers:
                    MacVoiceProvidersList(viewModel: viewModel)
                case .vendor(let id):
                    if let vendor = VoiceVendorRegistry.lookup(id: id, customEndpoints: viewModel.customVoiceEndpoints) {
                        MacVoiceVendorDetail(viewModel: viewModel, vendor: vendor)
                    }
                }
            }
        }
        .task {
            // Resolve the Apple on-device install status so the STT chooser
            // (reached directly from Speech Input, NOT via the providers
            // sub-screen) renders Apple as activate-on-tap, not "Set up…", and
            // the Providers & Keys count includes it. Mirrors iOS.
            await viewModel.checkAppleModelStatus()
            // Fresh device-local key probe on every visit — landing here is
            // the moment the readiness banner must reflect reality. Mirrors iOS.
            await viewModel.refreshActiveTTSKeyProbe()
        }
    }

    // MARK: - Key readiness (device-local, active TTS provider)

    /// The convergence-UX banner — present ONLY while the active TTS
    /// provider's key probes `.missing`/`.unreadable` on THIS Mac. Mirrors the
    /// iOS `VoiceProviderListView.keyReadinessSection`.
    @ViewBuilder
    private var keyReadinessSection: some View {
        if let banner = viewModel.ttsKeyReadinessBanner {
            Section {
                TTSKeyReadinessBanner(
                    model: banner,
                    isRechecking: viewModel.isRecheckingTTSKey,
                    onCheckAgain: {
                        Task { await viewModel.recheckActiveTTSKey() }
                    },
                    onOpenVendor: banner.vendorID.map { id in
                        { route = .vendor(id) }
                    }
                )
            }
        }
    }

    // MARK: - Voice Setup (STT + TTS selectors + Providers & Keys)

    /// ONE unified card mirroring iOS: the Speech-to-Text selector, the
    /// Text-to-Speech selector, and the Providers & Keys drill-in (top-level
    /// instead of buried last). The global Language hint lives in the STT
    /// chooser; the old TTS "Apple fallback" footer is dropped — the TTS
    /// chooser's own footer already restates it.
    private var voiceSetupSection: some View {
        Section {
            Button {
                route = .chooser(.stt)
            } label: {
                VoiceDirectionSelectorRow(direction: .stt, activeVendorName: viewModel.activeSTTVendorShortName)
            }
            .buttonStyle(.plain)

            Button {
                route = .chooser(.tts)
            } label: {
                VoiceDirectionSelectorRow(direction: .tts, activeVendorName: viewModel.activeTTSVendorShortName)
            }
            .buttonStyle(.plain)

            Button {
                route = .providers
            } label: {
                HStack(spacing: 12) {
                    Label(
                        LocalizedStringResource("settings.voice.providersKeys.label", defaultValue: "Providers & Keys"),
                        systemImage: "key.horizontal"
                    )
                    .foregroundStyle(AppColors.textPrimary)
                    Spacer()
                    providersKeysSummary
                        .foregroundStyle(AppColors.textSecondary)
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(AppColors.textTertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } header: {
            Text(LocalizedStringResource("settings.voice.setup.header", defaultValue: "Voice Setup"))
        }
    }

    private var providersKeysSummary: Text {
        let count = viewModel.configuredVoiceVendorCount
        if count == 0 {
            return Text(LocalizedStringResource("settings.voice.providersKeys.summary.none", defaultValue: "None configured"))
        }
        return Text(LocalizedStringResource("settings.voice.providersKeys.summary.count", defaultValue: "\(count) configured"))
    }

    /// The native display name for the active language hint — `LanguageList`'s
    /// native name, or the localized "Auto-detect" when unset. Passed to the
    /// STT chooser's `VoiceLanguageHint`.
    private var languageDisplayName: String {
        guard let code = viewModel.preferredLanguage, !code.isEmpty else {
            return String(localized: "Auto-detect") // xcstrings
        }
        return LanguageList.nativeName(for: code)
    }

    // MARK: - Per-direction chooser

    @ViewBuilder
    private func chooser(for direction: VoiceDirection) -> some View {
        VoiceActiveProviderPicker(
            direction: direction,
            options: viewModel.directionOptions(for: direction),
            onActivate: { vendorID in
                guard let vendor = VoiceVendorRegistry.lookup(id: vendorID, customEndpoints: viewModel.customVoiceEndpoints) else { return }
                Task {
                    switch direction {
                    case .stt:
                        if vendor.isOnDevice {
                            if let presetID = vendor.sttPresetID {
                                await viewModel.validateAndSave(key: "", for: presetID)
                            }
                        } else if let presetID = vendor.sttPresetID {
                            await viewModel.setActive(presetID)
                        }
                    case .tts:
                        if let ttsID = vendor.ttsProviderID {
                            await viewModel.setActiveTTS(providerID: ttsID)
                        }
                    }
                    route = nil
                }
            },
            onSetUp: { vendorID in
                chooserVendorRoute = vendorID
            },
            // Global Language hint — STT only; TTS passes nil (double-guarded).
            // The chooser owns the sheet (keeps the macOS sizing internally).
            languageHint: direction == .stt
                ? VoiceLanguageHint(
                    displayName: languageDisplayName,
                    code: Binding(
                        get: { viewModel.preferredLanguage ?? "" },
                        set: { newValue in
                            Task {
                                await viewModel.savePreferredLanguage(newValue.isEmpty ? nil : newValue)
                            }
                        }
                    )
                )
                : nil
        )
        .navigationDestination(item: $chooserVendorRoute) { id in
            if let vendor = VoiceVendorRegistry.lookup(id: id, customEndpoints: viewModel.customVoiceEndpoints) {
                MacVoiceVendorDetail(viewModel: viewModel, vendor: vendor)
            }
        }
    }
}

// MARK: - Providers & Keys library (drill-in sub-screen)

/// The provider library — built-in vendors + custom endpoints + the Add row —
/// pushed from the Voice category's "Providers & Keys" row. Owns its OWN vendor-
/// detail destination (scoped here, never on the parent category) so the
/// parent chooser keeps its own; the two are sibling pushes that never coexist.
private struct MacVoiceProvidersList: View {
    @Bindable var viewModel: SettingsViewModel

    @State private var vendorRoute: String?

    var body: some View {
        ScrollView {
            Form {
                providerSection
                customEndpointSection
                reliabilitySection
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .padding(28)
        }
        .macSettingsSubScreenChrome(title: String(localized: LocalizedStringResource("settings.voice.providersKeys.label", defaultValue: "Providers & Keys")))
        .navigationDestination(item: $vendorRoute) { id in
            if let vendor = VoiceVendorRegistry.lookup(id: id, customEndpoints: viewModel.customVoiceEndpoints) {
                MacVoiceVendorDetail(viewModel: viewModel, vendor: vendor)
            }
        }
        .task {
            await viewModel.checkAppleModelStatus()
        }
    }

    /// "Providers" group — the frozen built-in vendors. Mirrors the iOS
    /// `VoiceProvidersListView.providerSection` (same header).
    private var providerSection: some View {
        Section {
            ForEach(viewModel.voiceProviderRows.filter { !$0.isCustom }) { row in
                vendorRow(row)
            }
        } header: {
            Text(LocalizedStringResource("settings.voice.section.header", defaultValue: "Providers"))
        } footer: {
            Text(LocalizedStringResource(
                "settings.voice.list.footer",
                defaultValue: "One key per provider unlocks both speech-to-text and text-to-speech. Tap a provider to add a key or manage it."
            ))
        }
    }

    /// "Custom endpoints" group — the user-added per-uuid endpoints + the Add
    /// row. Shows even with zero customs so the Add row always has context.
    private var customEndpointSection: some View {
        Section {
            ForEach(viewModel.voiceProviderRows.filter { $0.isCustom }) { row in
                vendorRow(row)
            }
            addCustomEndpointRow
        } header: {
            Text(LocalizedStringResource("settings.voice.section.customHeader", defaultValue: "Custom endpoints"))
        }
    }

    /// The shared collapsed "About reliability" disclosure — last section, no
    /// header. Same subview as iOS (`VoiceReliabilityDisclosure`) so the copy
    /// can't drift between platforms.
    private var reliabilitySection: some View {
        Section {
            VoiceReliabilityDisclosure()
        }
    }

    /// "+ Add custom endpoint" — VISIBLE-but-disabled at the cap. Tap → mint a
    /// draft → push the editor bound to its uuid (`custom_<uuid>` route).
    @ViewBuilder
    private var addCustomEndpointRow: some View {
        let canAdd = viewModel.customVoiceEndpointCount < Constants.maxCustomVoiceEndpoints
        VStack(alignment: .leading, spacing: 4) {
            Button {
                if let id = viewModel.newCustomVoiceEndpointDraftID() {
                    vendorRoute = VoiceVendorRegistry.customVendorPrefix + id.uuidString.lowercased()
                }
            } label: {
                Label {
                    Text(canAdd
                        ? LocalizedStringResource("settings.voice.custom.add", defaultValue: "Add custom endpoint")
                        : LocalizedStringResource("settings.voice.custom.addAtCap", defaultValue: "Add custom endpoint (limit reached)"))
                } icon: {
                    Image(systemName: "plus.circle.fill")
                        .foregroundStyle(canAdd ? AppColors.brandAmber : AppColors.textTertiary)
                }
                .font(.body)
                .foregroundStyle(canAdd ? AppColors.textPrimary : AppColors.textTertiary)
            }
            .buttonStyle(.plain)
            .disabled(!canAdd)
            .accessibilityIdentifier("settings.voice.addCustomEndpoint")
            if !canAdd {
                Text(LocalizedStringResource(
                    "settings.voice.custom.capHint",
                    defaultValue: "Delete an endpoint above to add another."
                ))
                    .font(.caption2)
                    .foregroundStyle(AppColors.textTertiary)
            }
        }
    }

    @ViewBuilder
    private func vendorRow(_ row: VoiceProviderRow) -> some View {
        // Discrete status — quiet green check + full-weight name when configured,
        // nothing + dimmed name when not. No leading radio, no colored capsule,
        // no active tint. Active state lives only in the top selectors.
        let configured = [.ready, .keySaved].contains(viewModel.credentialState(for: row.vendorID))
        Button {
            vendorRoute = row.vendorID
        } label: {
            HStack(spacing: 12) {
                Text(row.displayName)
                    .font(.body)
                    .foregroundStyle(configured ? AppColors.textPrimary : AppColors.textSecondary)
                Spacer()
                SettingsStatusMark(configured: configured)
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(AppColors.textTertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Per-vendor detail (shared key + STT + TTS)

/// The per-vendor config detail (macOS) — shared by the providers-library rows
/// and the chooser's "Set up…" deep-link. Custom endpoint → `CustomSTTConfigBody`;
/// built-in → a grouped Form mirroring the iOS `VoiceProviderDetailView`
/// (Provider Access + STT + TTS, closing with the quiet credit-hint footnote).
private struct MacVoiceVendorDetail: View {
    @Bindable var viewModel: SettingsViewModel
    let vendor: VoiceVendor

    var body: some View {
        if let uuid = VoiceVendorRegistry.customVendorUUID(from: vendor.id) {
            // The editor supplies its own `bufferedEditorChrome` macOS header
            // (toolbar hidden), so no `.navigationTitle` / sub-screen chrome here.
            CustomSTTConfigBody(viewModel: viewModel, uuid: uuid)
        } else {
            builtInVendorDetail(vendor)
        }
    }

    private func builtInVendorDetail(_ vendor: VoiceVendor) -> some View {
        ScrollView {
            Form {
                openRouterReuseSection(vendor)
                if let metadata = vendor.sttMetadata, metadata.isOnDevice {
                    // On-device Apple — bespoke layout (no cloud-style "Provider
                    // Access" / "Test Connection"): the two-engine chooser with its
                    // inline download, a live record→transcribe test, then TTS, and
                    // the Apple-specific activation footnote.
                    AppleEngineModeSection(viewModel: viewModel)
                    AppleSpeechTestSection(viewModel: viewModel)
                    ttsSection(vendor)
                    appleFootnotes
                } else {
                    if let metadata = vendor.sttMetadata {
                        providerAccessSection(metadata: metadata)
                        speechToTextSection(metadata: metadata)
                    }
                    ttsSection(vendor)
                    detailFootnotes
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .padding(28)
        }
        .macSettingsSubScreenChrome(title: vendor.displayName)
        .task {
            if vendor.isOnDevice {
                await viewModel.refreshAppleOnDeviceEngineMode()
                await viewModel.checkAppleModelStatus()
                // Probe Standard first (sets Ready without a spinner flash if it's
                // already on disk), then warm it — landing on the Apple detail is
                // consent to prepare the default on-device engine.
                await viewModel.refreshAppleStandardModelStatus()
                await viewModel.prepareStandardEngine()
            }
        }
        .onDisappear {
            // Cloud also aborts the in-flight upload + resets the shared tester
            // to idle so the next provider's screen starts clean.
            if vendor.isOnDevice {
                viewModel.appleSpeechTester.cancel()
            } else {
                viewModel.cloudSTTTester.cancel()
            }
        }
    }

    /// OpenRouter key reuse (gateway → voice) — shown only on the OpenRouter
    /// vendor, only when the gateway has a saved key AND voice doesn't yet.
    @ViewBuilder
    private func openRouterReuseSection(_ vendor: VoiceVendor) -> some View {
        if vendor.id == "openrouter",
           viewModel.openRouterGatewayKeyAvailable,
           !viewModel.openRouterVoiceKeyAvailable {
            Section {
                OpenRouterKeyReuseCallout(
                    title: LocalizedStringResource(
                        "settings.voice.openRouter.reuse.title",
                        defaultValue: "You've already set up OpenRouter as a personal-AI gateway. Reuse that API key for voice?"
                    ),
                    buttonTitle: LocalizedStringResource(
                        "settings.voice.openRouter.reuse.button",
                        defaultValue: "Use my gateway key"
                    ),
                    action: { await viewModel.reuseGatewayKeyForOpenRouterVoice() }
                )
            }
        }
    }

    /// PROVIDER ACCESS section — the shared key, stated once.
    @ViewBuilder
    private func providerAccessSection(metadata: STTProviderMetadata) -> some View {
        // Apple on standard dictation needs no key AND no download — omit the
        // (high-quality model-download) lifecycle; the engine chooser above
        // carries the on-device story.
        if metadata.isOnDevice && viewModel.appleOnDeviceEngineMode == .dictation {
            EmptyView()
        } else {
            Section {
                ProviderConfigBody(
                    mode: .access,
                    metadata: metadata,
                    state: viewModel.rowState(for: metadata.id),
                    onPasteKey: { key in
                        Task { await viewModel.validateAndSave(key: key, for: metadata.id) }
                    },
                    onSetActive: { },
                    onClear: {
                        Task { try? await viewModel.clearKey(for: metadata.id) }
                    },
                    clearAlsoResetsTTS: viewModel.clearingKeyResetsActiveTTS(for: metadata.id),
                    appleModelState: metadata.isOnDevice
                        ? (viewModel.appleModelStates[viewModel.appleTargetKey] ?? .notDownloaded)
                        : nil,
                    onDownloadAppleModel: metadata.isOnDevice
                        ? { Task { await viewModel.downloadAppleModel() } }
                        : nil,
                    onDeleteAppleModel: metadata.isOnDevice
                        ? { viewModel.clearAppleModelState() }
                        : nil,
                    defaultModelPlaceholder: STTProvider.lookup(id: metadata.id).model
                )
            } header: {
                Text(LocalizedStringResource("settings.voice.section.providerAccess", defaultValue: "Provider Access"))
            } footer: {
                Text(metadata.isOnDevice
                     ? LocalizedStringResource("settings.voice.access.footer.apple.v3", defaultValue: "Runs on your device. Your voice stays on your device.")
                     : LocalizedStringResource("settings.voice.access.footer", defaultValue: "One key for both Speech-to-Text and Text-to-Speech, stored in your Apple Keychain."))
            }
        }
    }

    /// SPEECH-TO-TEXT section — Test + model override (activation lives in the top
    /// selector, not here).
    @ViewBuilder
    private func speechToTextSection(metadata: STTProviderMetadata) -> some View {
        Section {
            ProviderConfigBody(
                mode: .capabilitySTT,
                metadata: metadata,
                state: viewModel.rowState(for: metadata.id),
                onPasteKey: { _ in },
                onSetActive: { },               // inert — activation is the top STT selector, not here
                onClear: { },
                appleModelState: metadata.isOnDevice
                    ? (viewModel.appleModelStates[viewModel.appleTargetKey] ?? .notDownloaded)
                    : nil,
                currentCustomModel: viewModel.customModels[metadata.id],
                defaultModelPlaceholder: STTProvider.lookup(id: metadata.id).model,
                onSaveCustomModel: metadata.isOnDevice
                    ? nil
                    : { model in Task { await viewModel.saveCustomModel(model, for: metadata.id) } },
                // Replace the cheap "Test Connection" with a real record→transcribe
                // audition (the key check still lives in Provider Access).
                sttRecordTest: AnyView(CloudSTTTestSection(
                    viewModel: viewModel,
                    presetID: metadata.id,
                    providerName: metadata.displayName
                ))
            )
        } header: {
            Text(LocalizedStringResource("settings.voice.section.speechToText", defaultValue: "Speech-to-Text"))
        } footer: {
            // Short privacy hint right under the record test; the per-test credit
            // cost is covered once in the trailing `detailFootnotes`.
            Text(LocalizedStringResource(
                "settings.voice.cloudTest.footer",
                defaultValue: "Your clip is sent to \(metadata.displayName) to transcribe, and isn't kept by Conduck."
            ))
            .font(.caption)
            .foregroundStyle(AppColors.textSecondary)
        }
    }

    // MARK: - TTS section (macOS)

    @ViewBuilder
    private func ttsSection(_ vendor: VoiceVendor) -> some View {
        switch vendor.ttsStatus {
        case .available:
            if let ttsID = vendor.ttsProviderID {
                availableTTSSection(ttsID: ttsID)
            }
        case .coming:
            Section {
                HStack(spacing: 8) {
                    Image(systemName: "clock")
                        .foregroundStyle(AppColors.textTertiary)
                    Text(LocalizedStringResource(
                        "settings.voice.tts.coming",
                        defaultValue: "Text-to-speech coming soon"
                    ))
                        .font(.subheadline)
                        .foregroundStyle(AppColors.textTertiary)
                }
            } header: {
                Text(LocalizedStringResource("settings.voice.section.textToSpeech", defaultValue: "Text-to-Speech"))
            }
        case .none:
            EmptyView()
        }
    }

    /// TEXT-TO-SPEECH section — the shared `TTSCapabilityBody` (same wiring as
    /// iOS), with the iOS preview-status footer for parity.
    @ViewBuilder
    private func availableTTSSection(ttsID: String) -> some View {
        let provider = TTSProvider.lookup(id: ttsID)
        Section {
            TTSCapabilityBody(
                provider: provider,
                currentVoice: viewModel.ttsVoices[ttsID],
                onSaveVoice: { v in Task { await viewModel.saveTTSVoice(v, for: ttsID) } },
                currentModel: viewModel.ttsCustomModels[ttsID],
                onSaveModel: provider.bodyFactory != nil
                    ? { m in Task { await viewModel.saveTTSCustomModel(m, for: ttsID) } }
                    : nil,
                onPreview: { v, m in
                    Task {
                        await viewModel.saveTTSVoice(v, for: ttsID)
                        await viewModel.saveTTSCustomModel(m, for: ttsID)
                        await viewModel.previewTTS(for: ttsID)
                    }
                },
                previewState: viewModel.ttsPreviewStates[ttsID]
            )
        } header: {
            Text(LocalizedStringResource("settings.voice.section.textToSpeech", defaultValue: "Text-to-Speech"))
        } footer: {
            ttsPreviewStatusFooter(ttsID: ttsID)
        }
    }

    @ViewBuilder
    private func ttsPreviewStatusFooter(ttsID: String) -> some View {
        if case .invalid(let message) = viewModel.ttsPreviewStates[ttsID] {
            Text(message)
                .font(.caption)
                .foregroundStyle(AppColors.error)
        } else if !vendor.isOnDevice {
            // Suppressed on Apple's own TTS section — circular there.
            Text(LocalizedStringResource(
                "settings.voice.tts.footer",
                defaultValue: "If a reply can't reach this provider, it's spoken with Apple's on-device voice."
            ))
        }
    }

    // MARK: - Trailing footnotes (activation + cloud-only credit hint)

    private var detailFootnotes: some View {
        Section {
            EmptyView()
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Text(LocalizedStringResource(
                    "settings.voice.detail.activationHint",
                    defaultValue: "Choose your active providers on the Voice screen."
                ))
                if !vendor.isOnDevice {
                    Text(LocalizedStringResource(
                        "settings.voice.detail.creditHint",
                        defaultValue: "Tests and previews use a small amount of your provider's credits."
                    ))
                }
            }
            .font(.caption)
            .foregroundStyle(AppColors.textSecondary)
        }
    }

    /// Apple-specific closing footnote — drops the generic "choose your providers"
    /// plural (meaningless for a single on-device engine) and makes configuring-≠-
    /// activating concrete. The old "Standard vs High quality" engine-scope hint
    /// is gone — the engine is no longer a primary choice the user must adjudicate.
    private var appleFootnotes: some View {
        Section {
            EmptyView()
        } footer: {
            Text(LocalizedStringResource(
                "settings.voice.detail.activationHint.apple",
                defaultValue: "Apple is configured here only. Choose your active speech-to-text and text-to-speech providers on the Voice screen."
            ))
            .font(.caption)
            .foregroundStyle(AppColors.textSecondary)
        }
    }
}
#endif
