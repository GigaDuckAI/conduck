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

    // ACCOUNT-WIDE ATTENTION MARKERS — real `Conversation` attributes and real
    // CloudKit fields, mirrored to every device the user owns. Read that against
    // the TURN-STATE PROJECTION block directly below, which is the exact
    // opposite: derived per fetch, stored nowhere, gone the moment the fetch
    // that filled it is discarded. Folding the two groups together is the
    // mistake this note exists to stop — the "derived, cheap to drop, recompute
    // it later" reflex applied to one of these three silently discards a durable
    // synced fact that no later fetch can rebuild. They are also permanent: the
    // production CloudKit schema is additive-only, so none of the three can ever
    // be renamed or withdrawn.

    /// When this thread was last looked at, on ANY of the user's devices. Nil
    /// means never viewed anywhere — including every row written before this
    /// attribute existed, which is why nothing may read a nil as "seen".
    let lastViewedAt: Date?
    /// WHICH failure the account acknowledged: the `Message.deliveryAttemptID`
    /// of the failed turn the user was actually shown. An identity, never a
    /// time — asking again mints a new attempt ID on the retried turn and this
    /// stored one simply stops matching, which re-arms the red mark without
    /// anything having to clear a marker. Nil = nothing acknowledged here.
    ///
    /// WRITE-ONCE-FORWARD, and it is never written nil. A writer that cannot
    /// name an attempt does nothing at all: nil is not "acknowledge as of now"
    /// (there is no such fallback under identity) and it is not a value to
    /// store either, because writing it would ERASE an acknowledgement made on
    /// another device and relight the mark on all of them — a cross-device
    /// regression triggered by opening a conversation. The id a writer stores
    /// is the one on the failed turn it actually DREW; re-reading the aggregate
    /// at write time would let a failure that imported seconds before the tap
    /// be acknowledged without ever having been on screen.
    let failureSeenAttemptID: UUID?
    /// Versioned envelope naming this conversation's newest message — schema
    /// version, message id, its `createdAt`, its role — so a surface can answer
    /// "is the tail a reply?" from the conversation row alone. That question is
    /// otherwise a per-row message fetch, which is exactly what the wrist's
    /// whole list design refuses to pay.
    ///
    /// Untrusted on read and valid ONLY on a full match, `lastActivityAt`
    /// included: a build that appends a message without writing this string
    /// leaves a well-formed envelope describing the wrong tail, so any mismatch
    /// in either direction means stale rather than authoritative. Nil = never
    /// written.
    let tailProjection: String?

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
    /// Newest still-`failed` USER turn in this conversation — its stamp AND its
    /// `Message.deliveryAttemptID` as one value. They travel together because
    /// they describe one turn and an acknowledgement is matched against the
    /// identity while the mark is bounded by the stamp; split apart, a surface
    /// could pair one turn's stamp with another turn's identity and report a
    /// failure acknowledged that the user was never shown. See
    /// `FailedTurnProjection`.
    let newestFailed: FailedTurnProjection?

    init(
        id: UUID,
        title: String?,
        createdAt: Date,
        lastActivityAt: Date,
        sessionID: String,
        backend: String,
        titleSnippet: String?,
        hideEarlierPhotos: Bool = false,
        lastViewedAt: Date? = nil,
        failureSeenAttemptID: UUID? = nil,
        tailProjection: String? = nil,
        newestSendingAt: Date? = nil,
        newestFailed: FailedTurnProjection? = nil
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.lastActivityAt = lastActivityAt
        self.sessionID = sessionID
        self.backend = backend
        self.titleSnippet = titleSnippet
        self.hideEarlierPhotos = hideEarlierPhotos
        self.lastViewedAt = lastViewedAt
        self.failureSeenAttemptID = failureSeenAttemptID
        self.tailProjection = tailProjection
        self.newestSendingAt = newestSendingAt
        self.newestFailed = newestFailed
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
        // Account-wide attention markers (v10 model): nil-tolerant like every
        // field here, and a nil is the ABSENCE of a fact, never a default. A v9
        // row, and a CloudKit row that arrives before these attributes land,
        // both read nil — "nothing recorded", never "everything already seen".
        // Native UUID attributes, so there is no malformed-string parsing path
        // to get wrong; a non-UUID value simply reads nil.
        self.lastViewedAt = managedObject.value(forKey: "lastViewedAt") as? Date
        self.failureSeenAttemptID = managedObject.value(forKey: "failureSeenAttemptID") as? UUID
        self.tailProjection = managedObject.value(forKey: "tailProjection") as? String
        // Derived, never stored: the aggregate that fills these runs over
        // `Message`, so a single-conversation materialization cannot know them.
        self.newestSendingAt = nil
        self.newestFailed = nil
    }

    /// Copy carrying this conversation's unresolved-turn stamps. The only
    /// writer is `ConversationStore.fetchConversations(activity: .turnStates)`,
    /// which reads them from ONE whole-store aggregate rather than a per-row
    /// fan-out.
    ///
    /// EVERY OTHER FIELD IS CARRIED BY HAND HERE, and the three account-wide
    /// markers are the ones that hurt if they are not. This rebuilds the record
    /// from scratch and sits on the path of EVERY list fetch, so omitting
    /// `lastViewedAt` breaks no build and fails almost no test — it makes every
    /// row on every surface read a nil marker, a nil marker reads as "never
    /// viewed", and the entire list goes bold with an amber unseen disc on each
    /// answered thread. Omitting `failureSeenAttemptID` relights every failure
    /// the user already acknowledged, everywhere, for the same reason. Add a
    /// stored field to this struct and you add a line here.
    func withTurnStates(
        newestSendingAt: Date?,
        newestFailed: FailedTurnProjection?
    ) -> ConversationRecord {
        ConversationRecord(
            id: id,
            title: title,
            createdAt: createdAt,
            lastActivityAt: lastActivityAt,
            sessionID: sessionID,
            backend: backend,
            titleSnippet: titleSnippet,
            hideEarlierPhotos: hideEarlierPhotos,
            lastViewedAt: lastViewedAt,
            failureSeenAttemptID: failureSeenAttemptID,
            tailProjection: tailProjection,
            newestSendingAt: newestSendingAt,
            newestFailed: newestFailed
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
