// SPDX-License-Identifier: Apache-2.0

// Conduck
// ShareTargetFilter.swift  (ConduckShareExtensionMac appex)
//
// Pure, view-free search, threshold and destination-list rules for the macOS
// Share Extension's one destination list — extracted from `ShareView` so they are
// UNIT-TESTABLE without instantiating SwiftUI
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

/// Search + visibility rules for the share sheet's destination list. Stateless
/// namespace — every entry point is a pure function of its inputs (no stored
/// picker state), so `ShareView` stays a thin renderer and the rules get covered
/// by `ShareTargetFilterTests` rather than UI QA.
enum ShareTargetFilter {

    /// The picker only grows a search field once the combined target count
    /// exceeds 8 — below that everything fits the fixed 600pt panel without one,
    /// so a field would just be clutter. Boundary: 8 → false, 9 → true.
    static func shouldShowSearch(gatewayCount: Int, recentCount: Int) -> Bool {
        gatewayCount + recentCount > 8
    }

    /// The legacy "New conversation" row (whose manifest refs are both nil, so
    /// the drainer routes to the default gateway) is offered only when NO
    /// snapshot decoded: the roster is unknown, not empty, and the app may hold
    /// a gateway the extension cannot see.
    static func showsLegacyNewConversationRow(snapshotDecoded: Bool) -> Bool {
        !snapshotDecoded
    }

    /// A decoded snapshot with no configured gateway and no recent chat is told
    /// in one line rather than offered a send that the drainer would refuse.
    /// "Available", not "set up": an empty roster is also what a stale snapshot
    /// reads. The Add to Work row is rendered outside this rule and stays.
    static func showsNoAILine(snapshotDecoded: Bool, gatewayCount: Int, recentCount: Int) -> Bool {
        snapshotDecoded && gatewayCount == 0 && recentCount == 0
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
