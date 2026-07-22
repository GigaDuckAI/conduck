// Conduck
// MenuBarInputMode.swift
//
// macOS-only user preference deciding how the menu-bar popover captures input
// when summoned (⌘⇧1 / menu-bar click / context menu / ⌘⇧2):
//   - `.voice` (default): summoning auto-starts a recording — today's flow.
//   - `.text`: summoning shows a focused text field instead; Return sends,
//     Shift+Return inserts a newline, the draft survives dismissal.
// Governs the INPUT LEG only — destination resolution, pointer stamping, and
// the agent round-trip are shared with voice. Persisted via `SettingsManager`
// (App Groups key `Constants.menuBarInputModeKey`, device-local — NEVER
// iCloud-synced: a per-machine ergonomic, mirroring `showDockIconKey`).

import Foundation

/// User preference for the macOS menu-bar popover's input mode. Raw values
/// are load-bearing (persisted) — do not rename.
enum MenuBarInputMode: String, CaseIterable, Codable, Sendable {
    /// Summoning the popover starts a voice recording immediately.
    case voice
    /// Summoning the popover shows a focused text field; no recording.
    case text

    static let `default`: MenuBarInputMode = .voice
}
