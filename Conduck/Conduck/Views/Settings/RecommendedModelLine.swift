// SPDX-License-Identifier: Apache-2.0

// Conduck
// RecommendedModelLine.swift
//
// Voice Settings — the shared "Recommended model · <model>" caption. A small
// reusable subview extracted from `ProviderConfigBody.recommendedModelLine` so
// the STT (`ProviderConfigBody`) and TTS (`TTSCapabilityBody`) sections render
// the line IDENTICALLY (same markup, same key) — symmetry by shared leaf view,
// not by two parallel clones.
//
// The model token is data (monospaced, never localized); only the "Recommended
// model" label is a catalog string.
//
// NOTE: the `settings.stt.provider.recommendedModel` key is DIRECTION-NEUTRAL —
// the `stt.` prefix is HISTORICAL (the line was born in the STT path) and is now
// reused by TTS. DO NOT rename the key: a rename would orphan the catalog value
// (the runtime value wins over `defaultValue:`) for no user-visible gain.

import SwiftUI

/// Caption beneath a provider name stating the shipped default model, so the
/// bare vendor-name row stays clean while the config screen still says exactly
/// what runs. Shared by the STT + TTS sections.
struct RecommendedModelLine: View {
    /// The shipped default model token. nil/empty → label only.
    let model: String?

    var body: some View {
        HStack(spacing: 4) {
            Text(LocalizedStringResource("settings.stt.provider.recommendedModel", defaultValue: "Recommended model"))
                .font(.caption)
                .foregroundStyle(AppColors.textTertiary)
            if let model, !model.isEmpty {
                Text(verbatim: "·")
                    .font(.caption)
                    .foregroundStyle(AppColors.textTertiary)
                Text(model)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(AppColors.textSecondary)
            }
        }
    }
}
