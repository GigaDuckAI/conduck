// SPDX-License-Identifier: Apache-2.0

// Conduck
// ShareTargetFilter.swift  (ConduckShareExtension appex)
//
// VERBATIM MIRROR of `ConduckShareExtensionMac/ShareTargetFilter.swift` below the
// header comment — pure, view-free search, threshold and destination-list rules
// for the iOS Share Extension's one destination list (the iOS sheet reuses the
// same rules as macOS). The appex carries no test target of its own; the macOS copy is the one
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
