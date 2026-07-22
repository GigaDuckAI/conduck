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

        // Network pre-check (first action in the bundled shortcut — must
        // run before `Record Audio` to short-circuit on no-connectivity).
        AppShortcut(
            intent: CheckNetworkIntent(),
            phrases: [
                "Check network in \(.applicationName)"        // xcstrings
            ],
            shortTitle: "Check Network",                      // xcstrings
            systemImageName: "wifi"
        )
    }

    static var shortcutTileColor: ShortcutTileColor {
        .teal
    }
}
