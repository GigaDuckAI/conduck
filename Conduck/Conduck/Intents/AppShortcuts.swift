// SPDX-License-Identifier: Apache-2.0

// Conduck
// AppShortcuts.swift
//

import AppIntents

/// App Shortcuts provider — makes intents automatically available in
/// Settings → Shortcuts so users can wire them to Action Button / Control
/// Center / Back Tap without writing a custom shortcut first.
struct ConduckShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        // Main capture-and-converse shortcut (Action Button / lock-screen widget).
        AppShortcut(
            intent: ConverseIntent(),
            phrases: [
                "Ask \(.applicationName)",                   // xcstrings
                "Talk to \(.applicationName)"                // xcstrings
            ],
            shortTitle: "GigaAction",                         // xcstrings
            systemImageName: "mic.fill"
        )

        // Readiness pre-check — the default gateway AND the connection. It must
        // stay the FIRST action in the bundled shortcut: a check that runs after
        // `Record Audio` cannot save the recording it exists to protect, and the
        // whole point is to refuse before the microphone rather than after.
        AppShortcut(
            intent: CheckNetworkIntent(),
            phrases: [
                "Check \(.applicationName) is ready"          // xcstrings
            ],
            shortTitle: "Check Conduck",                      // xcstrings
            systemImageName: "checkmark.shield"
        )
    }

    static var shortcutTileColor: ShortcutTileColor {
        .teal
    }
}
