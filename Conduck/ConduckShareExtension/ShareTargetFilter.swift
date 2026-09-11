// SPDX-License-Identifier: Apache-2.0

// Conduck
// ShareTargetFilter.swift  (ConduckShareExtension appex)
//
// VERBATIM MIRROR of `ConduckShareExtensionMac/ShareTargetFilter.swift` below the
// header comment — the pick type `ShareTarget` plus the pure, view-free search,
// threshold, destination-list, opening-pick and Send-label rules for the iOS
// Share Extension's one destination list (the iOS sheet reuses the
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

/// A send target: the row the sheet highlights when it opens, or the row a click
/// moved that highlight to. Constructing one AUTHORISES NOTHING — it names where
/// a send would go, and the share is dispatched only when the Send button (or its
/// keyboard shortcut) is pressed. Maps 1:1 to the `SharedInboxManifest` routing
/// fields the host writes (see `ShareViewController.commit(caption:target:)`):
///   - `.newConversation(nil)`           → legacy/default route (all refs nil)
///   - `.newConversation(.some(ref))`    → mint a new conversation bound to `ref`
///   - `.existing(id, backendRef)`       → append to an existing conversation
enum ShareTarget: Equatable {
    /// Start a NEW conversation. `gatewayRef == nil` is the legacy/default target
    /// (the drainer routes to the default gateway); a non-nil ref pins the gateway.
    case newConversation(gatewayRef: String?)
    /// Append to an EXISTING conversation, carrying its bound gateway ref as a
    /// fallback hint should the conversation be deleted before the drain runs.
    case existing(conversationID: UUID, backendRef: String)
}

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
    /// reads. Add to Work is an action on the sheet's floor, outside this rule,
    /// so the line never leaves the person with nowhere to go.
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

    /// The row the sheet opens with highlighted — a HIGHLIGHT, not a decision.
    /// Nothing is sent until the person presses the button that names it.
    enum PreselectedRoute: Equatable {
        /// Nothing highlighted: the Send button is disabled until a row is picked.
        case none
        /// A new conversation on this gateway ref, highlighted and named on the
        /// Send button.
        case gateway(ref: String)
    }

    /// Which row opens highlighted.
    ///
    /// - No snapshot decoded → `.none`. The roster is UNKNOWN, and the only row
    ///   on offer is the legacy nil-ref route, which the drainer may resolve to a
    ///   live quick-capture conversation — a place this sheet never named. It
    ///   stays clickable; it is never picked for the person.
    /// - Snapshot decoded → the app's published default when it is in the
    ///   configured list, else the first configured gateway (the in-app new-chat
    ///   picker's own fallback: a picker with nothing highlighted is worse than
    ///   one highlighted row the person can change), else `.none`.
    static func preselectedRoute(
        snapshotDecoded: Bool,
        defaultGatewayRef: String?,
        configuredGatewayRefs: [String]
    ) -> PreselectedRoute {
        guard snapshotDecoded else { return .none }
        if let defaultGatewayRef, configuredGatewayRefs.contains(defaultGatewayRef) {
            return .gateway(ref: defaultGatewayRef)
        }
        if let first = configuredGatewayRefs.first {
            return .gateway(ref: first)
        }
        return .none
    }

    /// The pick the sheet opens with — `preselectedRoute` applied to the snapshot
    /// the host handed in: `.none` → nil, `.gateway(ref)` → a new conversation on
    /// that ref. Only configured gateways count.
    static func preselectedTarget(snapshot: ShareTargetsSnapshot?) -> ShareTarget? {
        let route = preselectedRoute(
            snapshotDecoded: snapshot != nil,
            defaultGatewayRef: snapshot?.defaultGatewayRef,
            configuredGatewayRefs: (snapshot?.gateways ?? []).filter(\.configured).map(\.ref)
        )
        switch route {
        case .none: return nil
        case .gateway(let ref): return .newConversation(gatewayRef: ref)
        }
    }

    /// What the Send button names — the button is where the person decides, so it
    /// says where the share is going.
    enum SendLabel: Equatable {
        /// Nothing to name: no pick, the legacy nil-ref route (which the drainer
        /// resolves rather than the sheet), or a pick the snapshot does not list.
        case sendNow
        /// A listed gateway's `displayName`, or a listed recent chat's `label`.
        case sendTo(name: String)
        /// A listed recent chat whose label is empty. The view supplies its own
        /// "Conversation" fallback, which is a localized string this file cannot
        /// reach.
        case sendToUntitledChat
    }

    /// What the Send button names: a gateway's displayName for a new conversation
    /// on a listed ref, a chat's label for a listed recent (`.sendToUntitledChat`
    /// when the label is empty), and plain "Send now" for the legacy nil ref, an
    /// unlisted ref/row, an empty displayName, or no pick at all.
    ///
    /// Unlisted falls back rather than inventing a name: a ref the snapshot does
    /// not carry is one this sheet cannot describe, and a button that named it
    /// anyway would be naming a guess.
    static func sendLabel(
        for destination: ShareTarget?,
        snapshot: ShareTargetsSnapshot?
    ) -> SendLabel {
        guard let destination else { return .sendNow }
        switch destination {
        case .newConversation(let ref):
            guard let ref,
                  let gateway = (snapshot?.gateways ?? []).first(where: { $0.ref == ref }),
                  !gateway.displayName.isEmpty
            else { return .sendNow }
            return .sendTo(name: gateway.displayName)
        case .existing(let conversationID, _):
            guard let convo = (snapshot?.recentConversations ?? [])
                .first(where: { $0.id == conversationID })
            else { return .sendNow }
            return convo.label.isEmpty ? .sendToUntitledChat : .sendTo(name: convo.label)
        }
    }
}
