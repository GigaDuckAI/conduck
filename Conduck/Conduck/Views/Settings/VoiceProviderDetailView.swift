// SPDX-License-Identifier: Apache-2.0

// Conduck
// VoiceProviderDetailView.swift
//
// iOS Settings master-detail — 3rd level. Per-vendor configuration pushed from
// the merged "Voice" list (`VoiceProviderListView`). ONE key field (the shared
// `stt.apiKey.<sttPresetID>` slot) serves BOTH directions; below it, two
// independent sections:
//   - STT section — "Set as active for speech-to-text" + model override + Test
//     (all via the reused `ProviderConfigBody`, which already owns the cloud
//     SecureField / Validate & Save / Get-a-key / masked-tail / Clear / Apple
//     model lifecycle).
//   - TTS section — only when the vendor ships TTS (`.available`): "Set as
//     active for text-to-speech", a free-text voice override field (placeholder
//     = the provider's defaultVoice), and a "Speak a sample" preview. A
//     `.coming` vendor renders a disabled "coming soon" row; a `.none` vendor
//     (Custom) shows no TTS section at all.
//
// The custom OpenAI-compatible endpoint reuses `CustomSTTConfigBody` for its
// URL + cert + auth + key surface and has no TTS section.
//
// iOS-only (macOS mirrors this in `MacVoiceCategory`).

#if os(iOS)
import SwiftUI

struct VoiceProviderDetailView: View {
    @Bindable var viewModel: SettingsViewModel
    let vendor: VoiceVendor

    var body: some View {
        Group {
            if let uuid = VoiceVendorRegistry.customVendorUUID(from: vendor.id) {
                // Named custom OpenAI-compatible endpoint — its own URL + cert +
                // auth + name body (STT + TTS in one screen, keyed by uuid).
                CustomSTTConfigBody(viewModel: viewModel, uuid: uuid)
            } else {
                builtInForm
            }
        }
        .navigationTitle(Text(vendor.displayName))
        .navigationBarTitleDisplayMode(.inline)
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
            // Leaving the screen mid-test drops the recording + any pending
            // transcription (and invalidates a late result via the generation
            // guard). Cloud also aborts the in-flight network upload, and resets
            // the shared tester to idle so the next provider's screen starts clean.
            if vendor.isOnDevice {
                viewModel.appleSpeechTester.cancel()
            } else {
                viewModel.cloudSTTTester.cancel()
            }
        }
    }

    // MARK: - Built-in vendor form (Provider Access + STT + TTS)

    private var builtInForm: some View {
        Form {
            openRouterReuseSection
            if let metadata = vendor.sttMetadata, metadata.isOnDevice {
                // On-device Apple — a bespoke layout (no cloud-style "Provider
                // Access" / "Test Connection"): the two-engine chooser with its
                // inline download, then a live record→transcribe test, then TTS,
                // closing with the Apple-specific activation footnote.
                AppleEngineModeSection(viewModel: viewModel)
                AppleSpeechTestSection(viewModel: viewModel)
                ttsSection
                appleFootnotes
            } else {
                if let metadata = vendor.sttMetadata {
                    providerAccessSection(metadata: metadata)
                    speechToTextSection(metadata: metadata)
                }
                // TTS half — only when the vendor ships a usable TTS direction.
                ttsSection
                detailFootnotes
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    // MARK: - OpenRouter key reuse (gateway → voice)

    /// Offer to reuse the OpenRouter hosted-GATEWAY key for voice — shown only on
    /// the OpenRouter vendor, only when the gateway has a saved key AND voice
    /// doesn't yet. See `OpenRouterKeyReuseCallout`.
    @ViewBuilder
    private var openRouterReuseSection: some View {
        if vendor.id == "openrouter",
           viewModel.openRouterGatewayKeyAvailable,
           !viewModel.openRouterVoiceKeyAvailable {
            Section {
                OpenRouterKeyReuseCallout(
                    title: LocalizedStringResource(
                        "settings.voice.openRouter.reuse.title.v2",
                        defaultValue: "You've already set up OpenRouter for chat. Reuse that API key for voice?"
                    ),
                    buttonTitle: LocalizedStringResource(
                        "settings.voice.openRouter.reuse.button.v2",
                        defaultValue: "Use my OpenRouter key"
                    ),
                    action: { await viewModel.reuseGatewayKeyForOpenRouterVoice() }
                )
            }
        }
    }

    // MARK: - Trailing footnotes (activation + cloud-only credit hint)

    /// A quiet trailing note: where to activate the provider (always shown — the
    /// only on-screen cue that configuring ≠ activating), plus a credit-spend
    /// caution for cloud providers only (Apple on-device spends nothing).
    /// Section-less so it reads as a closing footnote under the last section.
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

    /// Apple-specific closing footnote. "Provider" is meaningless for a single
    /// on-device engine, so this drops the generic "choose your providers" plural
    /// and makes configuring-≠-activating concrete. The old "Standard vs High
    /// quality" engine-scope hint is gone — the engine is no longer a primary
    /// choice the user must adjudicate (the section leads with one status line).
    private var appleFootnotes: some View {
        Section {
            EmptyView()
        } footer: {
            Text(LocalizedStringResource(
                "settings.voice.detail.activationHint.apple",
                defaultValue: "Apple is configured here only. Choose your active speech-to-text and text-to-speech providers on the Voice screen."
            ))
            .font(.caption)
        }
    }

    // MARK: - Provider Access (the shared key, stated once)

    @ViewBuilder
    private func providerAccessSection(metadata: STTProviderMetadata) -> some View {
        // Apple on standard dictation needs no key AND no download — the
        // Provider-Access lifecycle (which is the high-quality model download)
        // would be empty noise, so it's omitted entirely; the engine chooser
        // above carries the on-device story.
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
                    onSetActive: { },               // activation lives in the STT section
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
                Text(LocalizedStringResource(
                    "settings.voice.section.providerAccess",
                    defaultValue: "Provider Access"
                ))
            } footer: {
                Text(metadata.isOnDevice
                     ? LocalizedStringResource(
                        "settings.voice.access.footer.apple.v3",
                        defaultValue: "Runs on your device. Your voice stays on your device.")
                     : LocalizedStringResource(
                        "settings.voice.access.footer",
                        defaultValue: "One key for both Speech-to-Text and Text-to-Speech, stored in your Apple Keychain."))
            }
        }
    }

    // MARK: - Speech-to-Text (activation + Test + model override)

    @ViewBuilder
    private func speechToTextSection(metadata: STTProviderMetadata) -> some View {
        Section {
            ProviderConfigBody(
                mode: .capabilitySTT,
                metadata: metadata,
                state: viewModel.rowState(for: metadata.id),
                onPasteKey: { _ in },           // no key surface here
                onSetActive: { },               // inert — activation is the top STT selector, not here
                onClear: { },                   // clear lives in Provider Access
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
            Text(LocalizedStringResource(
                "settings.voice.section.speechToText",
                defaultValue: "Speech-to-Text"
            ))
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

    // MARK: - TTS section

    @ViewBuilder
    private var ttsSection: some View {
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
                Text(LocalizedStringResource(
                    "settings.voice.section.textToSpeech",
                    defaultValue: "Text-to-Speech"
                ))
            }
        case .none:
            EmptyView()
        }
    }

    @ViewBuilder
    private func availableTTSSection(ttsID: String) -> some View {
        let provider = TTSProvider.lookup(id: ttsID)
        // Pure config — NO activation here. Choosing the active voice lives only
        // in the top Text-to-Speech selector → chooser. Always mounted (no key
        // gate): the shared `TTSCapabilityBody` is symmetric with the STT section,
        // which also shows config before a key is stored.
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
            Text(LocalizedStringResource(
                "settings.voice.section.textToSpeech",
                defaultValue: "Text-to-Speech"
            ))
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
            // Suppressed on Apple's own TTS section — "Apple is the offline
            // fallback" is circular when you're configuring Apple itself.
            Text(LocalizedStringResource(
                "settings.voice.tts.footer",
                defaultValue: "If a reply can't reach this provider, it's spoken with Apple's on-device voice."
            ))
        }
    }
}
#endif
