// SPDX-License-Identifier: Apache-2.0

// Conduck
// WatchAttachmentInbox.swift
//
// The wrist's fast lane for agent-produced files.
//
// A turn dictated here is dispatched from here, so the reply TEXT lands in the
// wrist's own store immediately. The FILE the agent wrote does not: the wrist
// never receives the file-server credential (it is stored non-synchronizable,
// and the phone→watch relay deliberately carries no file-server secret), so it
// cannot list the reply's output folder and cannot discover the file at all.
// The iPhone does that, patches an `Attachment` row on, and that row reaches
// the wrist only through CloudKit mirroring — minutes, in the field.
//
// So the iPhone ALSO couriers the row's metadata over WatchConnectivity, and
// this class is where it lands. It is a display cache, NOT a second store:
//
//   • Nothing here is ever written to Core Data. That store is CloudKit-mirrored
//     on the wrist too, and Core Data + CloudKit does not unique on an `id`
//     attribute — a wrist-inserted row would export as its own CKRecord and sit
//     beside the iPhone's forever, on every device the user owns.
//   • The overlay is merged in at READ time by `WatchConversationViewModel`, and
//     an entry is retired in the same pass that first sees its authoritative
//     row. Couriered row and mirrored row therefore never coexist, in either
//     direction of arrival.
//   • The wrist gains something it can DRAW. It gains no download path: watchOS
//     has no QuickLook here and no file-server credential, and the courier
//     carries no bytes to open.
//
// All the convergence logic is pure and lives in `AttachedFileInboxState` /
// `AgentFileOverlay` (declared in the cross-target `ConversationStore.swift`),
// so it is unit-testable without a WCSession, a store, or a view. This class is
// the thin shell: load, persist, purge, and the notification post.
//
// PRIVACY: entries hold a stored key (an opaque server path token) and a
// filename (user content). Neither is ever logged — the breadcrumbs here are
// counts only.

import Foundation

/// Persistent holding area for file metadata the iPhone couriered ahead of
/// CloudKit. Main-actor because every reader is a view model on the main actor
/// and the state is small enough that serializing through it costs nothing.
@MainActor
final class WatchAttachmentInbox {
    static let shared = WatchAttachmentInbox()

    /// App-Group defaults key. The inbox is persisted rather than held in
    /// memory because a courier can arrive while the app is backgrounded and the
    /// user may not open the thread until the next launch — an in-memory cache
    /// would drop exactly the row it exists to deliver.
    private static let storageKey = "watch.agentFileInbox.v1"

    /// Storage seam — the in-memory double under `CONDUCK_TESTING`, the real
    /// App-Group container in production. Never `UserDefaults(suiteName:)`
    /// directly (`scripts/check-storage-seam.sh` enforces that).
    private let defaults: any DefaultsStore

    private var state: AttachedFileInboxState

    init(defaults: any DefaultsStore = SettingsDependencies.processDefault.defaults) {
        self.defaults = defaults
        if let blob = defaults.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode(AttachedFileInboxState.self, from: blob) {
            state = decoded
        } else {
            // A corrupt or absent blob starts empty. There is nothing to
            // recover: every entry here is a cache of something CloudKit is
            // independently delivering.
            state = AttachedFileInboxState()
        }
        // Expire on load rather than only on ingest, so a wrist that receives no
        // further couriers still sheds stale entries.
        if state.purgeExpired() { persist() }
    }

    /// Absorb a courier batch. Returns whether the inbox actually changed, which
    /// is the caller's gate for posting `.conversationsDidChange`: the iPhone
    /// sends every batch twice (queued + interactive), and a re-delivery must
    /// cost no refresh pass and no repaint.
    ///
    /// Persists BEFORE returning, so a caller that posts on `true` can never
    /// drive a refresh against state that a crash would lose.
    @discardableResult
    func ingest(_ descriptors: [AttachedFileDescriptor]) -> Bool {
        guard !descriptors.isEmpty else { return false }
        guard state.ingest(descriptors) else { return false }
        persist()
        return true
    }

    /// Merge pending entries onto freshly fetched messages, and retire every
    /// entry whose authoritative row this fetch proves has landed.
    ///
    /// The prune persists silently — it posts NOTHING. Retiring an entry is by
    /// definition a no-op for what the user sees (the real row renders instead),
    /// and a post here would run the refresh worker in a loop against its own
    /// output.
    func merged(into messages: [MessageRecord]) -> [MessageRecord] {
        let outcome = AgentFileOverlay.merge(state.entries, into: messages)
        if state.remove(attachmentIDs: outcome.resolved) { persist() }
        return outcome.messages
    }

    /// Drop every entry belonging to a conversation this device deleted.
    /// Without it the entries survive invisibly — their messages are gone, so
    /// nothing can ever prove their rows landed — until the age bound expires
    /// them.
    func purgeConversation(_ conversationID: UUID) {
        if state.purgeConversation(conversationID) { persist() }
    }

    /// Pending entry count. Diagnostics/tests only — a count is metadata, the
    /// entries themselves are not.
    var pendingCount: Int { state.entries.count }

    private func persist() {
        guard let blob = try? JSONEncoder().encode(state) else { return }
        defaults.set(blob, forKey: Self.storageKey)
    }
}
