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
//   - not set up  → NOTHING. Absence is the signal; the caller dims the row
//                   name to `textSecondary` so empty rows recede.
//   - the default / active pick is NOT shown here — that lives in the one
//     canonical top selector (Voice STT/TTS selectors · Personal AI "Default
//     for new chats"). A row may add a quiet tertiary `caption` ("Default")
//     beside the check for at-a-glance scanning, but never a colored badge.
//
// Accent discipline: amber NEVER appears in a list row. It is reserved for the
// top selector value, a chooser's selected-row check, and the one primary Save.
// Status here is green-check-or-nothing, so lists read calm and professional.

import SwiftUI

/// A discrete configured/not-set status mark for a settings list row. Renders a
/// green checkmark when `configured`, nothing otherwise. An optional `caption`
/// (e.g. "Default") shows as quiet tertiary text before the check — never a
/// colored badge.
struct SettingsStatusMark: View {
    let configured: Bool
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
        }
    }
}
