// SPDX-License-Identifier: Apache-2.0

// Conduck
// ConversationRecord.swift
//
// Sendable snapshot of a stored `Conversation`, decoupled from the
// `NSManagedObject` so it is safe to pass across the `ConversationStore`
// actor boundary and into `@MainActor` SwiftUI view models. The defensive
// `init(managedObject:)` (KVC + nil-coalescing) tolerates the all-optional
// Core Data model required by `NSPersistentCloudKitContainer`.

import Foundation
import CoreData

/// Snapshot of a persisted conversation thread. The `sessionID` is the
/// LOCAL conversation identity — never sent to the gateway under client-owned
/// history; retained for store identity + a future gateway-side
/// reconcile. `lastActivityAt` is the list sort key, bumped on
/// every appended message.
struct ConversationRecord: Identifiable, Hashable, Sendable {
    let id: UUID
    /// Optional human/server-generated headline. Nil falls back to a
    /// last-message preview at display time.
    let title: String?
    let createdAt: Date
    let lastActivityAt: Date
    /// Local conversation identity (UUID string). NOT sent on the wire.
    let sessionID: String
    /// `openclaw` / `hermes` — a conversation is bound to one backend.
    let backend: String
    /// Denormalized first-user-line snippet, written once on the first user
    /// turn (`ConversationStore.snippet(from:)`). Lets the Watch list show a
    /// meaningful row title without a per-row message fetch (no gateway gives
    /// us a real `title`). Nil = not yet captured (empty conversation, or a
    /// pre-backfill legacy row).
    let titleSnippet: String?
    /// Compatibility mode ("Keep chatting without photos"): when true,
    /// OUTBOUND requests replace this conversation's historical image parts
    /// with the canonical adapter-contract disclosure — stored history and the
    /// UI keep the full images, and the CURRENT turn's photos are never
    /// silently removed. Per-conversation (= per locked gateway), reversible
    /// ("Try photos again"). Nil (v3 row) == false.
    let hideEarlierPhotos: Bool

    init(
        id: UUID,
        title: String?,
        createdAt: Date,
        lastActivityAt: Date,
        sessionID: String,
        backend: String,
        titleSnippet: String?,
        hideEarlierPhotos: Bool = false
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.lastActivityAt = lastActivityAt
        self.sessionID = sessionID
        self.backend = backend
        self.titleSnippet = titleSnippet
        self.hideEarlierPhotos = hideEarlierPhotos
    }

    /// Defensive bridge from the all-optional Core Data entity. Every field
    /// nil-coalesces so a partially-synced CloudKit row (or a forward-compat
    /// schema gap) never produces a crash.
    init(managedObject: NSManagedObject) {
        self.id = (managedObject.value(forKey: "id") as? UUID) ?? UUID()
        self.title = managedObject.value(forKey: "title") as? String
        self.createdAt = (managedObject.value(forKey: "createdAt") as? Date) ?? Date()
        self.lastActivityAt = (managedObject.value(forKey: "lastActivityAt") as? Date)
            ?? (managedObject.value(forKey: "createdAt") as? Date)
            ?? Date()
        self.sessionID = (managedObject.value(forKey: "sessionID") as? String) ?? ""
        self.backend = (managedObject.value(forKey: "backend") as? String) ?? ""
        self.titleSnippet = managedObject.value(forKey: "titleSnippet") as? String
        // Compat flag (v4 model): nil (v3 row / partial sync) == false.
        self.hideEarlierPhotos = ((managedObject.value(forKey: "hideEarlierPhotos") as? NSNumber)?.boolValue) ?? false
    }

    /// Display title for the Watch conversation list rows AND the Watch thread
    /// top bar: human/server `title` → denormalized first-user-line
    /// `titleSnippet` → generic fallback. Centralizes the ladder both
    /// `WatchConversationListView` and `WatchConversationThreadView` use, so no
    /// per-row message fetch is needed on the wrist.
    var displayTitle: String {
        if let title = title?.trimmingCharacters(in: .whitespacesAndNewlines),
           !title.isEmpty {
            return title
        }
        if let snippet = titleSnippet?.trimmingCharacters(in: .whitespacesAndNewlines),
           !snippet.isEmpty {
            return snippet
        }
        return String(localized: "New conversation")  // xcstrings
    }
}
