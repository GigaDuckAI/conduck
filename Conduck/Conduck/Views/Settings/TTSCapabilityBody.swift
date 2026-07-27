// SPDX-License-Identifier: Apache-2.0

// Conduck
// TTSCapabilityBody.swift
//
// The shared Text-to-Speech configuration body, used by BOTH the iOS
// (`VoiceProviderDetailView`) and macOS (`MacVoiceCategory`) vendor details.
// Mirrors `ProviderConfigBody.capabilityBody` (the STT direction) over the same
// leaf sub-views — `RecommendedModelLine`, the `.bordered` primary button, and
// `AdvancedModelDisclosure` — so the STT + TTS sections read as the SAME
// component twice. The one intended difference vs STT: the primary button speaks
// a sample (not Test Connection), and the Advanced disclosure additionally holds
// the voice field.
//
// Stateless w.r.t. the view model (callbacks only, like `ProviderConfigBody`) —
// it owns ONLY the two transient text buffers (voice + model), seeded from the
// persisted values on appear/change (KVS-push sync). This single shared body
// replaces the former iOS `voiceOverrideControls` + macOS `MacTTSSection` clones.
//
// TTS success is SILENT: the audio IS the success signal. Only `.checking` (a
// spinner inside the button) and `.invalid` (an error line) render — there is NO
// "Connected" line, unlike STT's `retestStatusLine`.

import SwiftUI

/// Shared TTS config body (iOS + macOS). Recommended-model line → "Speak a
/// sample" → error line → Advanced[voice + model]. Apple (`bodyFactory == nil`)
/// collapses to just the button + error line — no model line, no disclosure,
/// no voice field (the override is inert; the system voice is chosen by locale).
struct TTSCapabilityBody: View {
    let provider: TTSProvider

    /// The provider's currently-stored voice override (nil = none → default).
    let currentVoice: String?
    /// Persist callback for the voice field.
    let onSaveVoice: (String) -> Void

    /// The provider's currently-stored model override (nil = none → default).
    let currentModel: String?
    /// Persist callback for the model field. nil → Apple (no model field, no
    /// Advanced disclosure).
    let onSaveModel: ((String) -> Void)?

    /// Single audition action — the call site persists the typed voice + model
    /// THEN auditions, so "Speak a sample" always plays exactly what's on screen.
    let onPreview: (_ voice: String, _ model: String) -> Void

    /// Live preview outcome. Only `.checking` (spinner in the button) +
    /// `.invalid` (error line) render; `.valid`/`nil` are silent.
    let previewState: KeyValidationState?

    /// Local buffer for the voice field. Seeded from `currentVoice` on
    /// appear/change; persisted via `onSaveVoice` / `onPreview`.
    @State private var pendingVoice: String = ""

    /// Local buffer for the model field. Seeded from `currentModel` on
    /// appear/change; persisted via `onSaveModel` / `onPreview`.
    @State private var pendingModel: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Recommended-model caption — cloud-only (Apple's sentinel model is
            // withheld, exactly like STT withholds it for the on-device provider).
            if provider.bodyFactory != nil {
                RecommendedModelLine(model: provider.model)
            }

            // Primary action — top-level, BEFORE Advanced, mirroring STT's Test
            // Connection position. The only intended difference: icon + label.
            previewButton

            // Status line — error-only. No "Connected" on success (the audio is
            // the success signal). `.checking` shows in the button, not here.
            previewStatusLine

            // Advanced — voice + model override (cloud-only; Apple has no wire
            // model to override and a confirmed-inert voice field).
            if provider.bodyFactory != nil {
                AdvancedModelDisclosure(
                    placeholder: provider.model,
                    pendingModel: $pendingModel,
                    onSave: { onSaveModel?($0) },
                    helper: LocalizedStringResource(
                        "settings.tts.provider.modelOverride.helper",
                        defaultValue: "Leave empty for the recommended default. A wrong value fails at the next spoken reply."
                    ),
                    voicePlaceholder: provider.defaultVoice,
                    pendingVoice: $pendingVoice,
                    onSaveVoice: onSaveVoice
                )
            }
        }
        .onAppear {
            pendingVoice = currentVoice ?? ""
            pendingModel = currentModel ?? ""
        }
        .onChange(of: currentVoice) { _, v in pendingVoice = v ?? "" }
        .onChange(of: currentModel) { _, m in pendingModel = m ?? "" }
    }

    // MARK: - Speak a sample (primary action)

    /// The section's single action — saves the typed voice AND model, then
    /// auditions. Quiet neutral `.bordered`; spinner + "Playing…" while checking.
    /// Mirrors STT's `testConnectionAction` treatment/position.
    @ViewBuilder
    private var previewButton: some View {
        let isChecking = (previewState == .checking)
        Button {
            onPreview(pendingVoice, pendingModel)
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

    // MARK: - Preview status (error-only; success stays silent)

    /// Renders ONLY the `.invalid` arm — matches `ProviderConfigBody`'s
    /// `retestStatusLine` error treatment. `.valid`/`.checking`/nil render
    /// nothing (success is the audio; checking shows in the button).
    @ViewBuilder
    private var previewStatusLine: some View {
        if case .invalid(let message) = previewState {
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
