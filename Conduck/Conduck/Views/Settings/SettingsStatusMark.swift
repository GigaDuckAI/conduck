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
//   - not set up  → no status. Absence is the signal; the caller dims the row
//                   name to `textSecondary` so empty rows recede.
//   - the default / active pick is NOT shown here — that lives in the one
//     canonical top selector (Voice STT/TTS selectors · Personal AI "Default
//     for new chats"). A row may add a quiet tertiary `caption` ("Default")
//     for at-a-glance scanning, but never a colored badge.
//
// The caption renders in EVERY state, including the two that show no status at
// all. It used to be nested inside the configured branch, which hid it on the one
// row a user most needs to find: a default gateway that cannot send drew a dimmed
// name and nothing else — not even the word "Default" — while the selector above
// still named it. When both the caption and "Needs setup" render they are
// separated by a "·", because two tertiary captions 6pt apart read as one phrase.
// Suppressing the caption on a first-run device is the CALLER's job, not this
// type's: only the caller knows whether the pointer names a gateway the user
// chose or the never-chosen built-in fallback.
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

    /// The caption is hoisted OUT of the `configured` branch on purpose. Keeping
    /// it there meant the one row a user most needs to find — a default gateway
    /// that cannot send — rendered as a dimmed name with nothing beside it, not
    /// even the word "Default", while the selector above still named it. A row
    /// that says "Default · Needs setup" (or just "Default") is the whole repair
    /// path; hiding the label on exactly the broken row inverted it.
    var body: some View {
        HStack(spacing: 6) {
            if let caption {
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(AppColors.textTertiary)
            }
            if configured {
                Image(systemName: "checkmark")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppColors.success)
                    .accessibilityLabel(Text(LocalizedStringResource(
                        "settings.status.configured.a11y",
                        defaultValue: "Configured"
                    )))
            } else if incomplete {
                // Separator only when both halves render: two tertiary captions
                // 6pt apart read as one phrase ("Default Needs setup"). The check
                // needs none — a glyph reads as its own element.
                if caption != nil {
                    Text(verbatim: "·")
                        .font(.caption)
                        .foregroundStyle(AppColors.textTertiary)
                        .accessibilityHidden(true)
                }
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
}
