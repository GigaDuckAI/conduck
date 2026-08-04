// SPDX-License-Identifier: Apache-2.0

// Conduck
// SettingsStatusMark.swift
//
// The single discrete status indicator for every Settings list row — Voice
// providers AND Personal AI gateways, iOS + macOS. Replaces the old zoo of
// colored capsules ("Ready" / "Key saved" green, "Default" amber, "Configured"
// green, "Not set up" grey) with ONE quiet treatment per the founder's brief:
// "a discrete symbol like a green checkmark — more eye-pleasing, less text."
//
// Vocabulary (the ONLY status a list row ever shows):
//   - configured  → a small green `checkmark` (symbol only, no capsule, no
//                   label). The vendor/gateway has a usable key/model/config.
//   - incomplete  → the quiet tertiary words "Needs setup". Setup was started
//                   here but the row can't be used as it stands.
//   - not set up  → NOTHING. Absence is the signal; the caller dims the row
//                   name to `textSecondary` so empty rows recede.
//   - the default / active pick is NOT shown here — that lives in the one
//     canonical top selector (Voice STT/TTS selectors · Personal AI "Default
//     for new chats"). A row may add a quiet tertiary `caption` ("Default")
//     beside the check for at-a-glance scanning, but never a colored badge.
//
// The incomplete state exists because "never touched" and "half set up" were
// previously BOTH rendered as nothing, which is how a gateway holding a URL
// without its key stayed invisible in the Personal AI list while Diagnostics
// warned about it and told the user to come here and fix it.
//
// Accent discipline: amber NEVER appears in a list row. It is reserved for the
// top selector value, a chooser's selected-row check, and the one primary Save.
// So `incomplete` is deliberately WORDS, not an amber glyph — the information
// the list was missing, delivered without spending the accent. Diagnostics is
// where the same state earns its amber; a config list stays calm.

import SwiftUI

/// A discrete status mark for a settings list row: a green checkmark when
/// `configured`, quiet "Needs setup" text when `incomplete`, nothing otherwise.
/// An optional `caption` (e.g. "Default") shows as tertiary text before the
/// check — never a colored badge.
struct SettingsStatusMark: View {
    let configured: Bool
    /// Whether the row holds an unfinished setup. Ignored when `configured` —
    /// a usable row is never also incomplete.
    var incomplete: Bool = false
    /// Optional quiet caption shown before the check (e.g. "Default"). Tertiary,
    /// uncolored — distinguishes the default/active row without a second accent.
    var caption: LocalizedStringResource? = nil

    var body: some View {
        if configured {
            HStack(spacing: 6) {
                if let caption {
                    Text(caption)
                        .font(.caption)
                        .foregroundStyle(AppColors.textTertiary)
                }
                Image(systemName: "checkmark")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppColors.success)
                    .accessibilityLabel(Text(LocalizedStringResource(
                        "settings.status.configured.a11y",
                        defaultValue: "Configured"
                    )))
            }
        } else if incomplete {
            Text(LocalizedStringResource(
                "settings.status.incomplete",
                defaultValue: "Needs setup"
            ))
            .font(.caption)
            .foregroundStyle(AppColors.textTertiary)
            .accessibilityLabel(Text(LocalizedStringResource(
                "settings.status.incomplete.a11y",
                defaultValue: "Setup incomplete on this device"
            )))
        }
    }
}
