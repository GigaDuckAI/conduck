// SPDX-License-Identifier: Apache-2.0

// Conduck
// ShareTargetFilter.swift  (ConduckShareExtension appex)
//
// VERBATIM MIRROR of `ConduckShareExtensionMac/ShareTargetFilter.swift` below the
// header comment — pure, view-free search/threshold logic for the iOS Share
// Extension picker (the iOS "Send to" redesign reuses the same matching rules as
// macOS). The appex carries no test target of its own; the macOS copy is the one
// compiled into the main-app `ConduckTests` bundle, where `@testable import
// Conduck` resolves `ShareTargetsSnapshot.Gateway`/`.RecentConversation` to the
// byte-identical main-app mirror — so the existing `ShareTargetFilterTests` covers
// this logic for BOTH appexes.
//
// NO SwiftUI / UIKit imports — pure Foundation over the snapshot value types.
// Keep it that way: the moment this file touches a view type it stops compiling
// into the test bundle.
//
// DRIFT GUARD: `ShareTargetFilterTests.testAppexMirrorsAreByteIdenticalBelowHeader`
// asserts this file is byte-identical to the macOS copy below this header block —
// change one side and the build fails there. (This comment deliberately avoids the
// import line's literal text, which the guard uses as its header/body boundary.)

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
