// SPDX-License-Identifier: Apache-2.0

import AppIntents

/// Watch-target App Shortcuts provider — forces `appintentsd` to index
/// `RecordNoteIntent` at install time rather than at first-launch. Without
/// this, the system can pre-flight-reject the ControlWidget's first cold
/// invocation on a fresh install ("GigaNote" failed. dialog) before
/// `perform()` ever runs.
///
/// Mirrors the iOS-target `ConduckShortcuts` provider; watch target only.
struct WatchAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: RecordNoteIntent(),
            phrases: [
                "Record a transcription with \(.applicationName)",
                "Capture audio in \(.applicationName)"
            ],
            shortTitle: "GigaAction",
            systemImageName: "note.text"
        )

        // Text-only preparation is intentionally its own action: unlike
        // GigaAction it opens no microphone and starts no AI turn. The phrases
        // name the wrist so this provider cannot collide in Siri with the
        // iPhone provider's identical action on a paired pair of devices.
        AppShortcut(
            intent: CaptureWorkboardIntent(),
            phrases: [
                "Add a thought to Work on my watch in \(.applicationName)",
                "Prepare work on my watch in \(.applicationName)"
            ],
            shortTitle: "Add to Work",
            systemImageName: "tray.and.arrow.down.fill"
        )
    }

    static var shortcutTileColor: ShortcutTileColor {
        .orange
    }
}
