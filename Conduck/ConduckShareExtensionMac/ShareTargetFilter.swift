// Conduck
// ShareTargetFilter.swift  (ConduckShareExtensionMac appex)
//
// Pure, view-free search/threshold logic for the macOS Share Extension picker —
// extracted from `ShareView` so it's UNIT-TESTABLE without instantiating SwiftUI
// (the appex carries no test target of its own; the helper is compiled into the
// main-app `ConduckTests` bundle too, where `@testable import Conduck` resolves
// `ShareTargetsSnapshot.Gateway`/`.RecentConversation` to the byte-identical
// main-app mirror — same shape, so the same source compiles in both modules).
//
// NO SwiftUI / AppKit imports — pure Foundation over the snapshot value types.
// Keep it that way: the moment this file touches a view type it stops compiling
// into the test bundle.
//
// TEST REPRESENTATIVENESS: `ShareTargetFilterTests` exercises the CANONICAL
// `ShareTargetsSnapshot` (main-app target). The appex compiles the same source
// against its byte-identical MIRROR, so the test only stays representative as
// long as the mirror keeps the fields this filter reads (`displayName`/`label`)
// identical — which the `ShareTargetsSnapshotTests` 3-way drift guard enforces.

import Foundation

/// Search + visibility rules for the "Send to" picker. Stateless namespace —
/// every entry point is a pure function of its inputs (no stored picker state),
/// so `ShareView` stays a thin renderer and the matching logic gets covered by
/// `ShareTargetFilterTests` rather than UI QA.
enum ShareTargetFilter {

    /// The picker only grows a search field once the combined target count
    /// exceeds 8 — below that everything fits the fixed 600pt panel without one,
    /// so a field would just be clutter. Boundary: 8 → false, 9 → true.
    static func shouldShowSearch(gatewayCount: Int, recentCount: Int) -> Bool {
        gatewayCount + recentCount > 8
    }

    /// Filter the NEW-conversation gateway rows by the search query. An empty /
    /// whitespace-only query passes the list through UNCHANGED (the field is
    /// either hidden or cleared); a non-empty query case-insensitively matches
    /// the gateway's `displayName`.
    static func filterGateways(
        _ gateways: [ShareTargetsSnapshot.Gateway],
        query: String
    ) -> [ShareTargetsSnapshot.Gateway] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return gateways }
        return gateways.filter { $0.displayName.localizedCaseInsensitiveContains(needle) }
    }

    /// Filter the RECENT-chat rows by the search query. Same contract as
    /// `filterGateways`, matching the conversation's `label`.
    static func filterRecents(
        _ recents: [ShareTargetsSnapshot.RecentConversation],
        query: String
    ) -> [ShareTargetsSnapshot.RecentConversation] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return recents }
        return recents.filter { $0.label.localizedCaseInsensitiveContains(needle) }
    }
}
