// SPDX-License-Identifier: Apache-2.0

// Conduck
// ActiveViewTracker.swift
//
// Shared @MainActor registry of conversation IDs the user is currently viewing
// on screen (iPhone composer / iPad detail column / macOS main window). Drives
// delivery-time banner suppression in `NotificationDelegate.willPresent`: if a
// reply lands for a conversation the user is already looking at, the bubble
// renders in place and the banner is suppressed (no "double feedback").
//
// Each mounted thread owns a separate visibility claim. Chats and Work can
// display the same conversation, so an outgoing pane releases only its claim:
// its delayed hide must not erase the incoming pane's visibility. The public
// snapshot remains a set of conversation IDs for delivery-time decisions.
//
// Not used by the Watch target — `WatchConversationThreadView` lives in a
// different compile set and the Watch already returns `[]` from its own
// `willPresent` delegate when foregrounded. CarPlay has no banner site.

import Foundation

@MainActor
enum ActiveViewTracker {
    private static var ownersByConversation: [UUID: Set<UUID>] = [:]

    static var viewedConversationIDs: Set<UUID> {
        Set(ownersByConversation.keys)
    }

    /// Omitting an owner keeps the idempotent single-owner calling convention.
    /// Mounted thread views always supply their own stable identity.
    static func track(_ id: UUID, ownerID: UUID? = nil) {
        ownersByConversation[id, default: []].insert(ownerID ?? id)
    }

    static func untrack(_ id: UUID, ownerID: UUID? = nil) {
        ownersByConversation[id]?.remove(ownerID ?? id)
        if ownersByConversation[id]?.isEmpty == true {
            ownersByConversation.removeValue(forKey: id)
        }
    }

    /// Whether the user is currently viewing the given conversation on any
    /// scene/window.
    static func isViewing(_ id: UUID) -> Bool {
        ownersByConversation[id] != nil
    }

    /// Test-only reset hook. Clears the registry so test order doesn't leak
    /// state between cases.
    static func _resetForTesting() {
        ownersByConversation.removeAll()
    }
}
