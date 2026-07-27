// SPDX-License-Identifier: Apache-2.0

// Conduck
// CarPlayConversationLabel.swift
//
// Pure display helpers for the CarPlay conversation picker. Two pure
// functions, no platform import (compiles into EVERY target so
// `ConversationStore.fetchRecentForPicker` — which is platform-agnostic — can
// call `derive` on macOS/watchOS builds too, and so the logic is unit-testable
// in isolation). NOT gated `#if os(iOS)`: there is nothing CarPlay-specific in
// the code itself, only in its intended use.
//
// Driver-safety / entitlement contract (`spec.md "Per-Surface Behavior → Apple CarPlay"`): the
// picker shows a SHORT identifier (title or first-user-turn snippet) + a
// relative date — NEVER readable conversation content. `derive` produces only
// that short label; it must never surface the agent reply or a full thread.

import Foundation

/// Pure display-label + relative-date + cap helpers for the CarPlay picker.
enum CarPlayConversationLabel {

    /// Maximum characters in a derived snippet label. A CarPlay list row
    /// truncates anyway; capping here keeps the label a glanceable identifier
    /// rather than a sentence the driver is tempted to read.
    static let maxSnippetLength = 40

    /// Derive the picker row label: `title` (trimmed, non-empty) ?? a snippet
    /// of the first user turn ?? "New Conversation".
    ///
    /// - The first-user-turn snippet is the first line of the user's opening
    ///   message, whitespace-collapsed and capped at `maxSnippetLength` (with
    ///   an ellipsis when truncated). First *user* turn — never the agent reply
    ///   (entitlement: no readable agent content on CarPlay).
    /// - "New Conversation" is the floor: a freshly-minted conversation with no
    ///   title and no turns yet still renders a stable, non-empty row.
    static func derive(title: String?, firstUserTurnText: String?) -> String {
        if let title = title?.trimmingCharacters(in: .whitespacesAndNewlines),
           !title.isEmpty {
            return title
        }
        if let snippet = snippet(from: firstUserTurnText) {
            return snippet
        }
        // xcstrings: reuse existing key — avoids a casing-only symbol
        // collision with "New Conversation")
        return String(localized: "New conversation")
    }

    /// Collapse a raw first-user-turn string into a single-line, length-capped
    /// snippet. Returns nil when the input is nil / empty after trimming.
    static func snippet(from text: String?) -> String? {
        guard let text else { return nil }
        // First line only (a multi-line dictation reads as one thought here).
        let firstLine = text
            .components(separatedBy: .newlines)
            .first ?? text
        // Collapse internal whitespace runs to single spaces.
        let collapsed = firstLine
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        guard collapsed.count > maxSnippetLength else { return collapsed }
        let cutoff = collapsed.index(collapsed.startIndex, offsetBy: maxSnippetLength)
        // Trim a trailing partial word + space, then append an ellipsis.
        let truncated = String(collapsed[..<cutoff])
            .trimmingCharacters(in: .whitespaces)
        return truncated + "…"
    }

    /// Format a conversation's `lastActivityAt` as a short relative date for
    /// the row's `detailText` (e.g. "2 hr ago", "Yesterday", "3 days ago").
    /// `RelativeDateTimeFormatter` is locale-aware and glanceable — the right
    /// fit for a driver's quick scan. `now` is injectable for deterministic
    /// tests.
    static func relativeDate(_ date: Date, now: Date = Date()) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: now)
    }

    /// Cap a count to the picker's row budget. The scene reserves row 0 for
    /// "New voice chat", so the recent list gets `CPListTemplate.maximumItem-
    /// Count − 1` rows. Pure arithmetic, extracted so the cap is unit-tested
    /// without a `CarPlay` import (the framework constant isn't available in a
    /// non-iOS test slice, and the rule — "reserve one" — is what we verify).
    static func recentCap(maximumItemCount: Int) -> Int {
        max(0, maximumItemCount - 1)
    }
}
