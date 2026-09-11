// SPDX-License-Identifier: Apache-2.0

// Conduck
// ComposerDropBatch.swift
//
// The value models + session bookkeeping behind every pane-wide drop target —
// the macOS conversation pane and the Work capture canvas both run their drops
// through `DropSession`. The pane owns the drop; the receiving surface owns
// staging. This file is the seam between them, and it is deliberately
// platform-agnostic (no AppKit, no SwiftUI, no `NSItemProvider`) so the
// ordering / finish-once / cancellation rules are unit-testable on the iOS-sim
// destination — the composer's own `View` internals are not.
//
// The session is generic over its item type: each surface resolves a drop into
// its OWN item value and tells the session, via `DropSessionItem`, how to read
// the app-owned artefact out of one. Everything the session itself enforces —
// slot order, resolve-once, hand-over-once, reclaim-on-reject — is written and
// tested exactly once.
//
// WHY a session at all: `.onDrop` requires every provider's load to BEGIN
// inside the drop action, but the loads complete later, out of order, and some
// never complete at all. `DropSession` holds one indexed slot per provider so
// results reassemble in the user's DROP order rather than completion order —
// the same invariant `stageServerFiles` enforces for the file importer, which
// the per-provider drop path used to violate.
//
// WHY object identity is the generation guard: a load callback closes over its
// own session. Cancelling that session makes every later `resolve` return
// `.rejected`, so a stale callback from a torn-down conversation can never
// mutate the session that replaced it. No integer generation counter to keep in
// sync.
//
// OWNERSHIP (load-bearing): a dropped file is copied into app-owned temp before
// it is published, because a decoded `file://` URL is only a reference to
// content the drag source owns and a file-promise may not outlive the drag.
// Every rejected/cancelled path therefore HANDS BACK the sources it dropped so
// the caller can delete them — nothing else knows they exist. `originalName`
// travels as its own field and is NEVER re-derived from the temp URL, whose
// leaf carries a `conduck-ftstage-<uuid>-` prefix that would otherwise surface
// to the user and to the agent as the filename.

import Foundation

/// A dropped file materialised into storage the app controls.
struct DroppedFileSource: Equatable {
    /// Where the bytes actually live now.
    let url: URL
    /// The name the user knows the file by. Kept separate from `url` because
    /// the staging copy's leaf is prefixed — see the file header.
    let originalName: String
    /// True when `url` is an app-owned temp the receiver must eventually
    /// delete. False for a user-owned URL (the file importer's picks), which
    /// must never be deleted.
    let isAppOwned: Bool
}

/// One resolved drop item, held in the position its provider occupied in the
/// original drop. `.failed` is a real, visible outcome — a load that errored or
/// timed out becomes a failed tile rather than silently vanishing from a drop
/// the user watched the app accept.
enum ResolvedDropItem: Equatable {
    case image(Data)
    case file(DroppedFileSource)
    case failed
}

/// A fully resolved drop, stamped with where it is allowed to land.
///
/// `destination` is what keeps a drop made on conversation A out of
/// conversation B. There is deliberately NO gateway stamp: the window cannot
/// resolve an active conversation's gateway synchronously (it lives on the
/// conversation's persisted backend), so the composer resolves it
/// authoritatively when it drains — the same thing the screenshot bridge does.
/// A stamp taken here would be the window's guess, and wrong exactly when the
/// composer has just mounted.
struct PendingDropBatch: Identifiable, Equatable {
    let id: UUID
    let destination: ComposerMountIdentity
    /// In original drop order.
    let items: [ResolvedDropItem]

    /// Every app-owned file this batch carries — what a discarding receiver
    /// must delete.
    var appOwnedSources: [DroppedFileSource] {
        items.compactMap(\.reclaimable)
    }
}

/// One surface's resolved-drop item, as a session sees it.
protocol DropSessionItem {
    /// The artefact a rejecting or cancelling session hands back.
    associatedtype Reclaimable
    /// The value the caller stamps on the session when it accepts the drop and
    /// reads back when it takes the batch — the mount a Chat drop belongs to,
    /// the up-front refusals a Work drop must still report.
    associatedtype Context

    /// The app-owned artefact this item carries, or nil when it owns nothing
    /// the app must clean up (raw bytes, a user-owned URL, a failure).
    var reclaimable: Reclaimable? { get }
}

/// What happened when a load result was offered to a session.
enum DropSessionResolution<Reclaimable> {
    /// Stored in its slot.
    case accepted
    /// The session was already finished or cancelled, the slot was already
    /// resolved, or the index is out of range. When `reclaim` is non-nil the
    /// caller MUST delete it — the session did not take ownership and nothing
    /// else knows the file exists.
    case rejected(reclaim: Reclaimable?)
}

extension DropSessionResolution: Equatable where Reclaimable: Equatable {}

extension ResolvedDropItem: DropSessionItem {
    typealias Context = ComposerMountIdentity

    var reclaimable: DroppedFileSource? {
        guard case .file(let source) = self, source.isAppOwned else { return nil }
        return source
    }
}

/// Which way a single dropped provider should be read.
enum DropProviderRoute: Equatable {
    /// Read the file URL and run it through the shared staging classifier.
    case fileURL
    /// Read raw image bytes (an image-only provider, or a file-promise drag
    /// such as an image dragged out of Safari, which has no file URL).
    case imageData
    /// Nothing we can use.
    case unsupported
}

/// Accumulates one drop's loads into an ordered batch.
///
/// Not thread-safe by design — every mutation happens on the main actor, where
/// both the drop callback and the provider completions are hopped.
@MainActor
final class DropSession<Item: DropSessionItem> {
    let id = UUID()
    /// Stamped when the drop was accepted, never re-read from live state. For
    /// Chat this is what keeps a drop made on conversation A out of
    /// conversation B.
    let context: Item.Context

    private var slots: [Item?]
    private var isDead = false

    /// `count` is the number of providers whose loads the caller is about to
    /// start. A zero-provider drop is not a session.
    init(context: Item.Context, count: Int) {
        precondition(count > 0, "a drop session needs at least one provider")
        self.context = context
        self.slots = Array(repeating: nil, count: count)
    }

    var providerCount: Int { slots.count }

    /// True once every slot has a result. The batch is not handed over until
    /// the caller takes it.
    var isComplete: Bool { !isDead && slots.allSatisfy { $0 != nil } }

    /// True once the session has been cancelled or its batch taken. Late
    /// callbacks check this implicitly through `resolve`.
    var isFinished: Bool { isDead }

    /// Offer a load result for `index`. Idempotent per slot: the first result
    /// wins and every later one is rejected, so a completion racing its own
    /// timeout cannot double-store or leak a temp file.
    func resolve(index: Int, with item: Item) -> DropSessionResolution<Item.Reclaimable> {
        let reclaim = item.reclaimable
        guard !isDead, slots.indices.contains(index), slots[index] == nil else {
            return .rejected(reclaim: reclaim)
        }
        slots[index] = item
        return .accepted
    }

    /// Take the finished slots exactly once, closing the session. Returns nil
    /// while any slot is outstanding, so a caller can poll after every resolve.
    /// Each surface shapes these into its own batch value.
    func takeItems() -> [Item]? {
        guard isComplete else { return nil }
        let items = slots.compactMap { $0 }
        isDead = true
        return items
    }

    /// Abandon the session. Returns the app-owned artefacts already stored in
    /// slots so the caller can delete them; loads still in flight hand their own
    /// back through `resolve`'s `.rejected(reclaim:)`.
    @discardableResult
    func cancel() -> [Item.Reclaimable] {
        guard !isDead else { return [] }
        isDead = true
        return slots.compactMap { slot -> Item.Reclaimable? in slot?.reclaimable }
    }
}

extension DropSession where Item == ResolvedDropItem {
    /// The mount this drop is allowed to land on.
    var destination: ComposerMountIdentity { context }

    convenience init(destination: ComposerMountIdentity, count: Int) {
        self.init(context: destination, count: count)
    }

    /// Take the finished batch exactly once, closing the session.
    func takeBatch() -> PendingDropBatch? {
        guard let items = takeItems() else { return nil }
        return PendingDropBatch(id: id, destination: destination, items: items)
    }
}

/// Pure drop-routing decisions. Separated from the view so the matrix is
/// testable; the view supplies the provider facts.
enum ComposerDropRouting {

    /// Which representation to read from a provider offering these.
    ///
    /// FILE URL WINS when a provider offers both, which is the common Finder
    /// image drag. Reading such a drop as raw image bytes skips the file
    /// classifier — and with it the size guard that keeps a very large image on
    /// the streamed server route instead of loading it whole into memory for a
    /// thumbnail. A file-promise drag (an image dragged out of a web page) has
    /// no file URL and is the case `.imageData` exists for.
    static func route(hasFileURL: Bool, canLoadImage: Bool) -> DropProviderRoute {
        if hasFileURL { return .fileURL }
        if canLoadImage { return .imageData }
        return .unsupported
    }

    /// Whether a drop may be accepted at all right now.
    ///
    /// A drop is refused outright rather than accepted-then-swallowed while a
    /// send is in flight (staging would be discarded) or while another drop is
    /// still resolving (a second session would overwrite the first and orphan
    /// its temp files). Refusing shows the drag snapping back, which reads as
    /// "not now" — the previous behaviour accepted the drop and dropped it on
    /// the floor with no tile and no message.
    static func canAcceptDrop(hasActiveSession: Bool,
                              hasParkedBatch: Bool,
                              isDispatching: Bool) -> Bool {
        !hasActiveSession && !hasParkedBatch && !isDispatching
    }

    /// True when `url` is a DIRECTORY, resolved under its security scope.
    ///
    /// Checked BEFORE any copy: `FileManager.copyItem` recurses, so copying
    /// first and rejecting after would duplicate an entire dropped folder
    /// (`node_modules`, a movies library) into temp — minutes of I/O and a
    /// plausible out-of-disk — only to delete it again. `nonisolated` because
    /// the drop path runs it on the provider's completion queue, where the
    /// blocking metadata read belongs.
    nonisolated static func isDirectory(_ url: URL) -> Bool {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        return (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
    }
}
