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
//
// The snippet's source is the user's own first turn, which can arrive from a BYO
// speech endpoint, and the row it lands in is read at a glance from a driver's
// seat. So the label is PROJECTED through `ReplySanitizer.displayLine` before it
// is capped — control and bidi scalars gone, breaks and whitespace runs
// collapsed to one space, RTL script untouched. Projecting before the cap is the
// load-bearing order: cutting first can leave a bidi opener with no terminator,
// governing everything still on the row.

import Foundation

/// Pure display-label + relative-date + cap helpers for the CarPlay picker.
enum CarPlayConversationLabel {

    /// Maximum characters in a derived snippet label. A CarPlay list row
    /// truncates anyway; capping here keeps the label a glanceable identifier
    /// rather than a sentence the driver is tempted to read.
    static let maxSnippetLength = 40

    /// Derive the picker row label: `title` (projected, non-empty) ?? a snippet
    /// of the first user turn ?? "New Conversation".
    ///
    /// - The first-user-turn snippet is the first line of the user's opening
    ///   message, projected to one display line and capped at `maxSnippetLength`
    ///   (with an ellipsis when truncated). First *user* turn — never the agent
    ///   reply (entitlement: no readable agent content on CarPlay).
    /// - "New Conversation" is the floor: a freshly-minted conversation with no
    ///   title and no turns yet — and one whose stored strings project away to
    ///   nothing — still renders a stable, non-empty row.
    static func derive(title: String?, firstUserTurnText: String?) -> String {
        if let title {
            // Projected, not merely trimmed — the projection subsumes the trim.
            // Uncapped, because a human/server title is a whole identifier and
            // the car's own row truncation is the only budget it has to meet.
            let projected = ReplySanitizer.displayLine(title, maxLength: .max, fallback: "")
            if !projected.isEmpty { return projected }
        }
        if let snippet = snippet(from: firstUserTurnText) {
            return snippet
        }
        // xcstrings: reuse existing key — avoids a casing-only symbol
        // collision with "New Conversation")
        return String(localized: "New conversation")
    }

    /// Collapse a raw first-user-turn string into a single-line, length-capped
    /// snippet. Returns nil when the input is nil, blank, or projects away to
    /// nothing (a line of pure formatting controls), so `derive` falls through to
    /// its floor rather than rendering a blank row.
    static func snippet(from text: String?) -> String? {
        guard let text else { return nil }
        // First line only (a multi-line dictation reads as one thought here).
        let firstLine = text
            .components(separatedBy: .newlines)
            .first ?? text
        // ONE character past the cap is all it takes to know the line was cut,
        // and asking for no more keeps the scan bounded however long the
        // untrusted input is.
        let projected = ReplySanitizer.displayLine(
            firstLine, maxLength: maxSnippetLength + 1, fallback: ""
        )
        guard !projected.isEmpty else { return nil }
        guard projected.count > maxSnippetLength else { return projected }
        // Second pass over an ALREADY-projected string, so it is a pure cap —
        // and it is what keeps the head from ending on a dangling space.
        let head = ReplySanitizer.displayLine(
            projected, maxLength: maxSnippetLength, fallback: ""
        )
        return head + "…"
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
