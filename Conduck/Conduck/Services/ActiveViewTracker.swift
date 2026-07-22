// Conduck
// ActiveViewTracker.swift
//
// Shared @MainActor registry of conversation IDs the user is currently viewing
// on screen (iPhone composer / iPad detail column / macOS main window). Drives
// delivery-time banner suppression in `NotificationDelegate.willPresent`: if a
// reply lands for a conversation the user is already looking at, the bubble
// renders in place and the banner is suppressed (no "double feedback").
//
// `Set<UUID>` (not `UUID?`) because iPad multi-scene and macOS multi-window can
// have multiple threads visible simultaneously. Insert on `.onAppear`, remove
// on `.onDisappear`, contains-check at delivery time. Idempotent (Set semantics).
//
// Not used by the Watch target — `WatchConversationThreadView` lives in a
// different compile set and the Watch already returns `[]` from its own
// `willPresent` delegate when foregrounded. CarPlay has no banner site.

import Foundation

@MainActor
enum ActiveViewTracker {
    /// Conversation IDs currently visible to the user. Exposed `private(set)`
    /// so the delivery-time decider in `NotificationPresentationDecider` can
    /// snapshot the set; mutations only happen via `track(_:)` / `untrack(_:)`.
    private(set) static var viewedConversationIDs: Set<UUID> = []

    /// Mark `id` as currently being viewed. Idempotent — re-tracking the same
    /// id is a no-op (Set semantics).
    static func track(_ id: UUID) {
        viewedConversationIDs.insert(id)
    }

    /// Mark `id` as no longer visible. Idempotent — untracking an absent id is
    /// a no-op.
    static func untrack(_ id: UUID) {
        viewedConversationIDs.remove(id)
    }

    /// Whether the user is currently viewing the given conversation on any
    /// scene/window.
    static func isViewing(_ id: UUID) -> Bool {
        viewedConversationIDs.contains(id)
    }

    /// Test-only reset hook. Clears the registry so test order doesn't leak
    /// state between cases.
    static func _resetForTesting() {
        viewedConversationIDs.removeAll()
    }
}
