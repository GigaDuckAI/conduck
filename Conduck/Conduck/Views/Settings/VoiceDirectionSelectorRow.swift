// SPDX-License-Identifier: Apache-2.0

// Conduck
// VoiceDirectionSelectorRow.swift
//
// Capability-first Voice home — the two tappable "Active" selector rows
// (speech-to-text · text-to-speech). Each row reads as: leading direction glyph
// + capability label, trailing active-vendor `shortDisplayName` in `brandAmber`
// + chevron. Tapping opens a per-direction chooser (`VoiceActiveProviderPicker`)
// where the user activates a configured vendor or deep-links into an
// unconfigured one's detail.
//
// Shared iOS + macOS (sibling to `DefaultGatewaySelectorRow`): presentation
// only, no state, no actor hop — the caller passes the precomputed active-vendor
// name and owns the tap. The visual treatment matches the Personal AI "Default
// for new chats" selector (amber trailing value, tertiary chevron) so the two
// settings surfaces rhyme.

import SwiftUI

/// One capability selector row on the Voice home screen. Stateless; the parent
/// owns the tap (which presents the chooser) and supplies the active value.
struct VoiceDirectionSelectorRow: View {
    let direction: VoiceDirection
    /// Active vendor's short display name (e.g. "Apple", "OpenAI").
    let activeVendorName: String

    private var glyph: String {
        switch direction {
        case .stt: return "mic"
        case .tts: return "speaker.wave.2"
        }
    }

    private var label: LocalizedStringResource {
        switch direction {
        case .stt:
            return LocalizedStringResource("settings.voice.selector.stt", defaultValue: "Speech-to-Text")
        case .tts:
            return LocalizedStringResource("settings.voice.selector.tts", defaultValue: "Text-to-Speech")
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            Label {
                Text(label)
                    .foregroundStyle(AppColors.textPrimary)
            } icon: {
                Image(systemName: glyph)
                    .foregroundStyle(AppColors.brandAmber)
            }
            Spacer()
            Text(activeVendorName)
                .font(.body.weight(.semibold))
                .foregroundStyle(AppColors.brandAmber)
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(AppColors.textTertiary)
        }
        .contentShape(Rectangle())
    }
}
