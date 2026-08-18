// SPDX-License-Identifier: Apache-2.0

// Conduck
// ConversationSearchFilter.swift
//
// Pure, Foundation-only search helpers shared by EVERY conversation-list
// surface (iPhone / iPad / Mac / Watch). No SwiftUI / CoreData import so the
// file compiles into all targets (the Watch pulls it in via one
// `project.pbxproj` membership exception) and the logic is unit-testable in
// isolation — mirrors `MessageRecord` / `ConversationRecord` / the
// `CarPlayConversationLabel` style for a pure shared Model file.
//
// Tier 1 of the unified search (`docs/ai-context/spec.md`): the INSTANT,
// in-memory match on `title` + first-user-line
// `titleSnippet`. Tier 2 (whole-history message-content match) is the
// async `ConversationStore.searchConversationIDs(containing:)` predicate
// fetch; the list unions the two. Keeping the trivial title/snippet rule here
// (not inlined per view) is what makes "same search everywhere" one helper
// instead of two divergent filter bodies.

import Foundation

/// Pure helpers for the shared conversation-list search. No retained state.
enum ConversationSearchFilter {

    /// Trim leading/trailing whitespace + newlines from a raw search field
    /// value. Returns `nil` when the result is empty so callers can treat
    /// "no query" uniformly (skip the predicate fetch, show the full list).
    /// Every Tier-1 / Tier-2 entry point normalizes through here so the empty
    /// case is decided in ONE place.
    static func normalizedQuery(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Tier-1 instant match: true iff `query` is contained
    /// (case- AND diacritic-insensitive) in a NON-BLANK `title` OR a NON-BLANK
    /// `titleSnippet`. The trim-guard means a whitespace-only stored field
    /// (e.g. `"   "`) never spuriously matches.
    ///
    /// Folding rule = `[.caseInsensitive, .diacriticInsensitive]`, deliberately
    /// matched to the Tier-2 content predicate's `CONTAINS[cd]` so the two tiers
    /// behave IDENTICALLY — typing "cafe" finds "Café" whether the match is in a
    /// title/snippet or in message content. (`localizedCaseInsensitiveContains`
    /// folds case but NOT diacritics — verified — so it is NOT used here; that
    /// would silently desync the two tiers.)
    ///
    /// Closes a real gap vs. the old per-surface filters: a conversation with a
    /// server `title` was not findable by its first-user-line `titleSnippet`,
    /// and vice-versa. Both are now searched, identically on every platform.
    ///
    /// Precondition: `query` is already `normalizedQuery`-normalized (non-empty,
    /// trimmed). Callers pass the normalized value.
    static func titleMatches(query: String, title: String?, titleSnippet: String?) -> Bool {
        if let title = title?.trimmingCharacters(in: .whitespacesAndNewlines),
           !title.isEmpty,
           foldedContains(title, query) {
            return true
        }
        if let snippet = titleSnippet?.trimmingCharacters(in: .whitespacesAndNewlines),
           !snippet.isEmpty,
           foldedContains(snippet, query) {
            return true
        }
        return false
    }

    /// Case- + diacritic-insensitive substring test (the Tier-1 folding rule,
    /// kept in one place so both the title and snippet checks stay in lockstep
    /// with the Tier-2 `[cd]` predicate).
    private static func foldedContains(_ haystack: String, _ needle: String) -> Bool {
        haystack.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }
}
