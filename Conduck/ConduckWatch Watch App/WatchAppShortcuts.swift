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
    }

    static var shortcutTileColor: ShortcutTileColor {
        .orange
    }
}
