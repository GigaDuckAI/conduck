// SPDX-License-Identifier: Apache-2.0

// Conduck
// ConversationRecord.swift
//
// Sendable snapshot of a stored `Conversation`, decoupled from the
// `NSManagedObject` so it is safe to pass across the `ConversationStore`
// actor boundary and into `@MainActor` SwiftUI view models. The defensive
// `init(managedObject:)` (KVC + nil-coalescing) tolerates the all-optional
// Core Data model required by `NSPersistentCloudKitContainer`.
//
// `displayTitle` is the one DERIVED member here, and it is a render-time
// projection: the stored strings it reads are untrusted (a title snippet
// derived from a transcript, possibly synced in from another device) so it
// answers them through `ReplySanitizer.displayLine` on the way out rather than
// rewriting anything in the store.

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
    /// The `RemoteAgentRef` raw string this conversation is bound to:
    /// `openclaw` / `hermes` / `openrouter` / `custom_<uuid>`. One binding for
    /// the life of the thread — Clone to switch, never rebind. LOCKED value
    /// set: it is a Core Data attribute carried through every model version,
    /// so a renamed case orphans conversations already on people's devices.
    /// Note the two senses of "backend" — this is the gateway KIND, never the
    /// "no backend" privacy claim, which is about servers WE operate.
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

    // TURN-STATE PROJECTION — derived, NOT Core Data attributes, NOT CloudKit
    // fields. Filled ONLY by `ConversationStore.fetchConversations(activity:)`
    // from the whole-store unresolved-turn aggregate. Nil everywhere else
    // (`fetchConversation(id:)`, tests), and nil resolves to `.idle` — the row
    // renders exactly as it does without the projection.
    //
    // These are also the ONLY reason a status flip re-renders a list: a
    // `sending → failed` transition changes no `Conversation` column and does
    // not bump `lastActivityAt` (the send-state writers touch `Message` columns
    // only), so without them `fetched != conversations` is false in both list
    // view models and nothing repaints.

    /// Newest still-`sending` USER turn in this conversation.
    let newestSendingAt: Date?
    /// Newest still-`failed` USER turn in this conversation.
    let newestFailedAt: Date?

    init(
        id: UUID,
        title: String?,
        createdAt: Date,
        lastActivityAt: Date,
        sessionID: String,
        backend: String,
        titleSnippet: String?,
        hideEarlierPhotos: Bool = false,
        newestSendingAt: Date? = nil,
        newestFailedAt: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.lastActivityAt = lastActivityAt
        self.sessionID = sessionID
        self.backend = backend
        self.titleSnippet = titleSnippet
        self.hideEarlierPhotos = hideEarlierPhotos
        self.newestSendingAt = newestSendingAt
        self.newestFailedAt = newestFailedAt
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
        // Derived, never stored: the aggregate that fills these runs over
        // `Message`, so a single-conversation materialization cannot know them.
        self.newestSendingAt = nil
        self.newestFailedAt = nil
    }

    /// Copy carrying this conversation's unresolved-turn stamps. The only
    /// writer is `ConversationStore.fetchConversations(activity: .turnStates)`,
    /// which reads them from ONE whole-store aggregate rather than a per-row
    /// fan-out.
    func withTurnStates(newestSendingAt: Date?, newestFailedAt: Date?) -> ConversationRecord {
        ConversationRecord(
            id: id,
            title: title,
            createdAt: createdAt,
            lastActivityAt: lastActivityAt,
            sessionID: sessionID,
            backend: backend,
            titleSnippet: titleSnippet,
            hideEarlierPhotos: hideEarlierPhotos,
            newestSendingAt: newestSendingAt,
            newestFailedAt: newestFailedAt
        )
    }

    /// Display title for the Watch conversation list rows AND the Watch thread
    /// top bar: human/server `title` → denormalized first-user-line
    /// `titleSnippet` → generic fallback. Centralizes the ladder both
    /// `WatchConversationListView` and `WatchConversationThreadView` use, so no
    /// per-row message fetch is needed on the wrist.
    ///
    /// Each stored rung is PROJECTED at read time, never merely trimmed. The
    /// snippet is derived from a user transcript that can come from a BYO speech
    /// endpoint, and one synced in from another device carries whatever that
    /// transcript carried — an unterminated bidi override in it renders the whole
    /// row backwards. Answering it at the render leaves storage canonical, so
    /// history already on the device needs no rewrite to be safe.
    var displayTitle: String {
        if let title = Self.projectedTitleRung(title) {
            return title
        }
        if let snippet = Self.projectedTitleRung(titleSnippet) {
            return snippet
        }
        return String(localized: "New conversation")  // xcstrings
    }

    /// One rung of the `displayTitle` ladder: an untrusted stored string reduced
    /// to a safe display line, or nil when it carries nothing renderable.
    ///
    /// Nil rather than the generic title is why this passes `fallback: ""`: a
    /// `title` of nothing but formatting controls must fall THROUGH to the
    /// snippet, not short-circuit the ladder and hide a good snippet behind "New
    /// conversation".
    private static func projectedTitleRung(_ text: String?) -> String? {
        guard let text else { return nil }
        let line = ReplySanitizer.displayLine(text, maxLength: .max, fallback: "")
        return line.isEmpty ? nil : line
    }
}
