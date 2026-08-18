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
// Vocabulary — TWO states, and the count is the point:
//   - configured  → a small green `checkmark` (symbol only, no capsule, no
//                   label). The vendor/gateway has a usable key/model/config.
//   - not set up  → no status. Absence is the signal; the caller dims the row
//                   name to `textSecondary` so empty rows recede.
//   - the default / active pick is NOT shown here — that lives in the one
//     canonical top selector (Voice STT/TTS selectors · Personal AI "Default
//     for new chats"). A row may add a quiet tertiary `caption` ("Default")
//     for at-a-glance scanning, but never a colored badge.
//
// THERE IS NO THIRD STATE, and one may not be added back. A "Needs setup" line
// used to sit between them for a row holding stored state it cannot send on.
// It asserted a chore that does not exist: these lists are menus of optional
// things you MAY connect, so not connecting one is not an unfinished task. Worse,
// it asserted a chore the storage cannot even evidence — a key still crossing
// iCloud Keychain and a setup abandoned months ago read identically, so the words
// were as often a lie as a hint. Where that state genuinely needs explaining, the
// explanation lives at the point of use (the row's own editor), not in a list the
// user is scanning.
//
// The caption renders in BOTH states, including the one that shows no status at
// all. It used to be nested inside the configured branch, which hid it on the one
// row a user most needs to find: a default gateway that cannot send drew a dimmed
// name and nothing else — not even the word "Default" — while the selector above
// still named it. It is now the ONLY thing such a row shows, which is exactly the
// intended reading: this is the default, and it simply has no green check.
// Suppressing the caption on a first-run device is the CALLER's job, not this
// type's: only the caller knows whether the pointer names a gateway the user
// chose or the never-chosen built-in fallback.
//
// Accent discipline: amber NEVER appears in a list row. It is reserved for the
// top selector value, a chooser's selected-row check, and the one primary Save.
// Green is the single exception and it only ever means "this works".

import SwiftUI

/// A discrete status mark for a settings list row: a green checkmark when
/// `configured`, nothing otherwise. An optional `caption` (e.g. "Default") shows
/// as tertiary text before the check — never a colored badge.
struct SettingsStatusMark: View {
    let configured: Bool
    /// Optional quiet caption shown before the check (e.g. "Default"). Tertiary,
    /// uncolored — distinguishes the default/active row without a second accent.
    var caption: LocalizedStringResource? = nil

    /// The caption is hoisted OUT of the `configured` branch on purpose. Keeping
    /// it there meant the one row a user most needs to find — a default gateway
    /// that cannot send here — rendered as a dimmed name with nothing beside it,
    /// not even the word "Default", while the selector above still named it. The
    /// caption is now the ONLY thing such a row shows, which is the intended
    /// reading: it is the default, and it simply has no green check.
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
            }
        }
    }
}
