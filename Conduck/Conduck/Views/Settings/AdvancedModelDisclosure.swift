// Conduck
// AdvancedModelDisclosure.swift
//
// Voice Settings — the shared "Advanced › Use a different model" disclosure. A
// small reusable subview = a collapsed `DisclosureGroup` + a monospaced model
// `TextField` (placeholder = the provider's default model) + a "Save model"
// button. Extracted so the STT `ProviderConfigBody.advancedModelSection` and the
// TTS detail sections (`VoiceProviderDetailView` iOS / `MacVoiceCategory` macOS)
// read IDENTICALLY — the model-override field looks the same in both directions
// instead of one being a bespoke clone of the other.
//
// Stateless w.r.t. persistence — owns only the transient text buffer + the
// expanded flag (both UI-local). The persisted value flows in via `currentModel`
// and out via `onSave`. Mirrors the STT field's label/styling/copy verbatim so
// the two directions are visually indistinguishable.
//
// The caller decides whether to render this at all: it is WITHHELD for Apple
// (no wire model to override) by simply not placing it (mirroring STT's
// `onSaveCustomModel == nil` gate). The pending text buffer is OWNED BY THE
// CALLER (a `Binding`) so a sibling "Speak a sample" button can persist the
// typed value BEFORE auditioning — exactly how the sibling Voice field is driven.

import SwiftUI

/// A collapsed model-override disclosure shared by the STT + TTS Voice sections.
struct AdvancedModelDisclosure: View {
    /// The provider's pinned default model — the `TextField` placeholder so the
    /// view never imports the wire registry directly.
    let placeholder: String
    /// The live text buffer, owned by the caller so a sibling control (the TTS
    /// "Speak a sample" button) can read + persist the typed value before it
    /// auditions. Seeded by the caller from the persisted override on appear.
    @Binding var pendingModel: String
    /// Persist callback — the trimmed/sanitized save happens in the view-model.
    /// Fired on submit AND on the explicit "Save model" tap.
    let onSave: (String) -> Void
    /// Direction-specific helper caption under the field. Caller-supplied so the
    /// failure-domain word is correct ("…fails at the next transcription" for STT
    /// vs "…fails at the next spoken reply" for TTS) — only the label/save copy is
    /// shared (it's domain-neutral). Defaults to the STT string for legacy callers.
    var helper: LocalizedStringResource = LocalizedStringResource(
        "settings.stt.provider.modelOverride.helper",
        defaultValue: "Leave empty for the recommended default. A wrong value fails at the next transcription."
    )

    // MARK: - Optional voice field (TTS only) — nil-defaulted
    //
    // The TTS direction additionally holds a free-text voice override (the one
    // difference between the STT + TTS Advanced disclosures). All three are
    // nil-defaulted so the STT caller compiles untouched; the voice field renders
    // ABOVE the model field only when the full trio is supplied. Keeping the
    // markup INSIDE this component (not pushed back via a ViewBuilder) means the
    // two directions can't drift.

    /// The provider's pinned default voice — the voice `TextField` placeholder.
    /// nil → no voice field (STT).
    var voicePlaceholder: String? = nil
    /// The live voice text buffer, owned by the caller so the sibling "Speak a
    /// sample" button can persist the typed value before auditioning.
    var pendingVoice: Binding<String>? = nil
    /// Persist callback for the voice field. Fired on submit.
    var onSaveVoice: ((String) -> Void)? = nil
    /// Helper caption under the voice field. Defaults to the shared TTS string.
    var voiceHelper: LocalizedStringResource = LocalizedStringResource(
        "settings.voice.tts.voice.helper",
        defaultValue: "Leave empty for the default. Voice IDs are provider-specific (e.g. en_paul_neutral)."
    )

    /// Collapsed by default — the override is an advanced, rarely-touched field.
    @State private var expanded: Bool = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 4) {
                // Voice field (TTS only) — sits ABOVE the model field when the
                // caller supplies the full voice trio. Withheld (nil-default) for
                // the STT direction, which has no voice override.
                if let voicePlaceholder, let pendingVoice, let onSaveVoice {
                    Text(LocalizedStringResource("settings.tts.custom.voice.label", defaultValue: "Voice"))
                        .font(.subheadline)
                        .foregroundStyle(AppColors.textPrimary)
                    TextField("", text: pendingVoice, prompt: Text(voicePlaceholder))
                        .labelsHidden()
                        .font(.system(.body, design: .monospaced))
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.asciiCapable)
                        #endif
                        .autocorrectionDisabled()
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { onSaveVoice(pendingVoice.wrappedValue) }
                    Text(voiceHelper)
                        .font(.caption2)
                        .foregroundStyle(AppColors.textTertiary)
                }
                TextField("", text: $pendingModel, prompt: Text(placeholder))
                    .labelsHidden()
                    .font(.system(.body, design: .monospaced))
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.asciiCapable)
                    #endif
                    .autocorrectionDisabled()
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { onSave(pendingModel) }
                Text(helper)
                    .font(.caption2)
                    .foregroundStyle(AppColors.textTertiary)
                Button {
                    onSave(pendingModel)
                } label: {
                    Label(
                        LocalizedStringResource("settings.stt.provider.modelOverride.save",
                                                defaultValue: "Save model"),
                        systemImage: "checkmark"
                    )
                    .font(.subheadline.weight(.semibold))
                    .labelStyle(AccentGlyphActionLabelStyle())
                }
                .buttonStyle(.bordered)
            }
            .padding(.top, 4)
        } label: {
            VStack(alignment: .leading, spacing: 1) {
                Text(LocalizedStringResource("settings.stt.provider.modelOverride.label",
                                             defaultValue: "Advanced"))
                    .font(.subheadline)
                    .foregroundStyle(AppColors.textPrimary)
                Text(LocalizedStringResource("settings.stt.provider.modelOverride.labelHint",
                                             defaultValue: "Use a different model"))
                    .font(.caption2)
                    .foregroundStyle(AppColors.textTertiary)
            }
            .tappableDisclosureLabel($expanded)
        }
    }
}
