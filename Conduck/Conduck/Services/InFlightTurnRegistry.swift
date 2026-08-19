// SPDX-License-Identifier: Apache-2.0

// Conduck
// InFlightTurnRegistry.swift
//
// "Is a turn for this conversation running RIGHT NOW, on THIS device, and can I
// stop it?" — the thing `Message.status == "sending"` cannot tell you, because a
// `sending` row may have been written by another device and arrived here via
// CloudKit.
//
// NEVER A SOURCE OF WRITES ABOUT TURN STATE. A reconciliation write based on "I
// don't see a task" would be a write based on local ignorance: the turn may be
// alive on the device that dispatched it, and marking it failed here would offer
// Retry beside a live request. The only writers that resolve a stale `sending`
// row remain the launch sweeps.
//
// KEYED BY CLAIM TOKEN, NOT BY CONVERSATION. Two turns can overlap in one
// conversation (a Watch relay racing an in-app send, a share drain racing the
// popover). A conversation-keyed entry would let the second claim overwrite the
// first, and the first `end` delete the survivor — a row that stops spinning
// while a request is still running, and a quit guard that reports zero. It also
// makes a double-end safe: ending an already-ended token is a no-op that cannot
// touch a newer claim.
//
// HONEST LIMIT: `reconcile()` is async, so at cold launch the first frame of a
// thread whose turn came from a PREVIOUS process may render without an
// indicator for a few milliseconds. The persisted `sending` row covers the same
// turn from the list side.

import Foundation

@Observable @MainActor
final class InFlightTurnRegistry {

    // MARK: - Types

    /// Probes report, per live conversation, whether that conversation's
    /// request body has DEPARTED this device — the fact the thread row needs to
    /// stop claiming a gateway is working while nothing has been sent. Keys are
    /// the live conversations; the `Bool` is the departure flag.
    ///
    /// LANE AND CANCELLABILITY ARE STILL DECLARED AT REGISTRATION, not carried
    /// per entry — the registration site knows which session it is wiring, and
    /// a CarPlay upload is not cancellable through `BackgroundRemoteAgent.cancel`,
    /// so it must not light a Stop button.
    typealias Probe = @Sendable () async -> [UUID: Bool]

    enum Lane: Sendable, Hashable {
        /// Foreground view-model dispatch (macOS, and the iOS pre-dispatch window).
        case viewModel
        /// The macOS shared-inbox drainer — no cancel handle.
        case shareDrain
        /// Reconciled from the background converse session.
        case backgroundConverse
        /// Reconciled from the CarPlay converse uploader.
        case carPlay
    }

    /// Opaque claim identity. The raw value is deliberately unreachable outside
    /// this file: a caller that could mint or guess a token could end another
    /// lane's claim.
    struct ClaimToken: Sendable, Hashable {
        fileprivate let raw: UUID
        fileprivate init() { self.raw = UUID() }
    }

    struct Entry: Sendable, Equatable {
        let conversationID: UUID
        let startedAt: Date
        let lane: Lane
        let isCancellable: Bool
        /// When this turn's request body left the device, or nil while nothing
        /// has been sent yet. MONOTONE: set once and never cleared, which is
        /// what makes the system's out-of-process connection retries irrelevant
        /// to every reader — a retry that re-sends changes nothing, because the
        /// stamp was already taken on the first attempt.
        ///
        /// Distinct from `startedAt` because on iOS the two can be minutes
        /// apart: a background session waits for connectivity unconditionally,
        /// so a turn can be claimed long before a byte moves.
        var dispatchedAt: Date?
    }

    private struct RegisteredProbe {
        let lane: Lane
        let isCancellable: Bool
        let probe: Probe
    }

    // MARK: - Singleton

    static let shared = InFlightTurnRegistry()

    /// REAPING HORIZON FOR AN ORPHANED CLAIM — not a ceiling on turn duration,
    /// and it never was one. A view model deallocated mid-flight cannot detach
    /// its own claim, so a leaked claim ages out instead of pinning a spinner
    /// forever. A claim whose turn is genuinely still running can never age out:
    /// `reconcile()` re-mints one for every conversation its lane's probe still
    /// reports, stamped `now`, and `noteDispatched` mints one outright when a
    /// departure arrives for a conversation whose claims have all aged away.
    ///
    /// MEASURED FROM THE MOST RECENT EVIDENCE OF LIFE, not from the claim's
    /// birth — see `isExpired`. A departure stamp IS such evidence, and this
    /// distinction is load-bearing rather than cosmetic: with the horizon
    /// anchored to `startedAt` alone, a turn that parked and then departed lost
    /// its stamp at the horizon while the row was still on screen, and the
    /// thread walked BACKWARDS out of "…is answering…" into "Sending…" beside a
    /// clock that jumped. On the surfaces that stamp at claim time (macOS and
    /// the share drain, where the two dates are the same instant) the anchor is
    /// unchanged, so nothing about the horizon they have always had moves.
    ///
    /// The value is borrowed from `Constants.remoteAgentConverseResourceTimeout`
    /// because a claim outliving the converse budget by that margin is the leak
    /// this exists for — NOT because a turn cannot outlive it. On iOS a turn can:
    /// the background session waits for connectivity with no bound anyone here
    /// owns.
    static let claimTTL: TimeInterval = Constants.remoteAgentConverseResourceTimeout

    // MARK: - State

    private var entries: [ClaimToken: Entry] = [:]
    private var probes: [RegisteredProbe] = []

    // MARK: - Probes

    /// Registered by the app entry point so this file never references
    /// `BackgroundRemoteAgent` / `CarPlayConverseUploader` and needs no `#if`.
    ///
    /// ONE PROBE PER LANE, ENFORCED HERE — a re-registration REPLACES the lane's
    /// probe rather than adding a second. `reconcile` clears a lane wholesale
    /// before re-populating it from that lane's probe, so two probes sharing a
    /// lane would make the second pass erase the first's conversations and only
    /// its own would survive. Enforcing the invariant at the one site that can
    /// break it is cheaper than making the reconcile loop merge across probes,
    /// and it also makes a double registration (an entry point that runs its
    /// wiring twice) idempotent instead of silently halving what the lane reports.
    func addProbe(lane: Lane, isCancellable: Bool, _ probe: @escaping Probe) {
        let registered = RegisteredProbe(lane: lane, isCancellable: isCancellable, probe: probe)
        if let existing = probes.firstIndex(where: { $0.lane == lane }) {
            probes[existing] = registered
        } else {
            probes.append(registered)
        }
    }

    /// Re-run every probe and REPLACE that probe's lane's entries. Never touches
    /// `.viewModel` / `.shareDrain` claims — those are owned by a live `Task`
    /// that will end its own token, and no probe can see them.
    ///
    /// A conversation the probe still reports keeps its EXISTING claim, so the
    /// elapsed clock counts from when the turn actually started rather than
    /// restarting on every list reload.
    ///
    /// A NO-OP RECONCILE MUTATES NOTHING. `entries` is an `@Observable` stored
    /// property and Observation's setter fires on every write with no equality
    /// check of its own, so an unconditional reassignment would invalidate every
    /// row that reads the registry — on a device with nothing in flight, twice
    /// per list reload. `ConversationListViewModel.reload` awaits this on the
    /// path whose whole point is a cheap exit during a CloudKit import storm.
    ///
    /// HONEST LIMIT: a claim ADOPTED here (a conversation a probe reports that
    /// this process holds no claim for — a turn that outlived a relaunch) is
    /// stamped `now`, because the probe reports ids and nothing knows when that
    /// turn actually began. Its elapsed clock therefore restarts from zero.
    /// Under-reporting is the deliberate direction: the alternative, anchoring
    /// to the durable turn's `createdAt`, over-reports by hours on a RETRY,
    /// which re-fires an old message row without touching its `createdAt`.
    /// The SAME limit extends to `dispatchedAt`: an adopted claim whose probe
    /// reports the body departed is stamped `now` too — we know THAT it
    /// dispatched, not WHEN.
    ///
    /// `dispatchedAt` on a SURVIVING claim is filled in here when the probe now
    /// reports departure and the claim has none, and is NEVER cleared —
    /// monotone, matching the delegate-side latches. Filling it in changes the
    /// entry, so the `next != current` guard below fires and the row updates.
    func reconcile() async {
        pruneExpired(now: Date())
        for registered in probes {
            let reported = await registered.probe()
            let now = Date()
            var next: [ClaimToken: Entry] = [:]
            var covered: Set<UUID> = []
            for (token, entry) in entries where entry.lane == registered.lane {
                guard let departed = reported[entry.conversationID] else { continue }
                var entry = entry
                if entry.dispatchedAt == nil, departed { entry.dispatchedAt = now }
                if let existing = next.first(where: { $0.value.conversationID == entry.conversationID }) {
                    // Keep the oldest claim for a conversation — it is the turn
                    // the user has been waiting on.
                    if existing.value.startedAt <= entry.startedAt { continue }
                    next.removeValue(forKey: existing.key)
                }
                next[token] = entry
                covered.insert(entry.conversationID)
            }
            for (id, departed) in reported where !covered.contains(id) {
                next[ClaimToken()] = Entry(
                    conversationID: id,
                    startedAt: now,
                    lane: registered.lane,
                    isCancellable: registered.isCancellable,
                    dispatchedAt: departed ? now : nil
                )
            }
            let current = entries.filter { $0.value.lane == registered.lane }
            guard next != current else { continue }
            var merged = entries.filter { $0.value.lane != registered.lane }
            for (token, entry) in next { merged[token] = entry }
            entries = merged
        }
    }

    // MARK: - Claims

    /// - Parameter dispatchedAt: pass a stamp ONLY from a lane whose dispatch
    ///   is already a fact at registration time — the macOS foreground
    ///   transports, which hand the request to `URLSession.data(for:)` with no
    ///   byte edge to observe, so turn start IS their honest ceiling. The iOS
    ///   background lane must leave this nil and let `noteDispatched` stamp it
    ///   when bytes actually depart; passing it here would restore exactly the
    ///   claim this change exists to remove.
    @discardableResult
    func noteBegan(
        _ id: UUID,
        lane: Lane,
        isCancellable: Bool,
        dispatchedAt: Date? = nil,
        at: Date = Date()
    ) -> ClaimToken {
        // Prune relative to `at`, not to a second reading of the wall clock:
        // `at` defaults to now in production, and using it keeps the whole call
        // in ONE time frame so an injected clock stays coherent.
        pruneExpired(now: at)
        let token = ClaimToken()
        entries[token] = Entry(
            conversationID: id,
            startedAt: at,
            lane: lane,
            isCancellable: isCancellable,
            dispatchedAt: dispatchedAt
        )
        return token
    }

    /// Record that this conversation's request body has left the device.
    ///
    /// Stamps the EARLIEST non-expired claim for the conversation IN ANY LANE,
    /// not the caller's own lane: on iOS the composer mints a `.viewModel`
    /// claim several awaits before the background delegate sees the first byte,
    /// and that earlier claim is the one every surface reads. Stamping the
    /// background lane's own (later, reconcile-minted) claim instead would
    /// leave the row the user is watching permanently unstamped.
    ///
    /// CONVERSATION-SCOPED, NOT TURN-SCOPED — stated plainly because the
    /// distinction shows up when two turns overlap in one conversation. The
    /// departure of the younger turn lands on the older turn's claim, exactly
    /// as `BackgroundRemoteAgent.liveConversationIDs` OR-folds departure across
    /// the tasks sharing a conversation. That is the accepted design: the
    /// registry's whole vocabulary is per conversation, and the alternative —
    /// threading a task identity from the transport through to a claim token —
    /// buys a sharper answer for a rare shape at the cost of coupling the two.
    ///
    /// TOTAL: a departure is never dropped. When no non-expired claim survives
    /// — the turn parked longer than `claimTTL` and no list reload ran
    /// `reconcile()` in between — this MINTS one rather than returning. The
    /// caller's departure edge fires once per task and never again, so a
    /// dropped stamp is permanent for that turn: the row would say "Sending…"
    /// for the entire time the gateway was actually answering. The minted claim
    /// under-reports `startedAt` (it begins now), which is the same honest limit
    /// an adopted claim carries in `reconcile()` and the same safe direction.
    ///
    /// IDEMPOTENT and MONOTONE — a second call on an already-stamped claim
    /// writes nothing, so the `@Observable` storage is not invalidated by the
    /// repeated progress callbacks that drive it, and an out-of-process retry
    /// can never move the stamp forward.
    ///
    /// - Parameters:
    ///   - lane/isCancellable: used ONLY when a claim has to be minted. The
    ///     defaults name the one lane that can reach that case — the iOS
    ///     background converse session, whose claim can age out while its task
    ///     is still parked. The foreground transports stamp inside the same
    ///     call that creates their claim, so they always find one.
    func noteDispatched(
        _ id: UUID,
        lane: Lane = .backgroundConverse,
        isCancellable: Bool = true,
        at: Date = Date()
    ) {
        pruneExpired(now: at)
        let candidate = entries
            .filter { $0.value.conversationID == id && !Self.isExpired($0.value, now: at) }
            .min { $0.value.startedAt < $1.value.startedAt }
        guard let candidate else {
            entries[ClaimToken()] = Entry(
                conversationID: id,
                startedAt: at,
                lane: lane,
                isCancellable: isCancellable,
                dispatchedAt: at
            )
            return
        }
        guard candidate.value.dispatchedAt == nil else { return }
        var updated = candidate.value
        updated.dispatchedAt = at
        entries[candidate.key] = updated
    }

    /// Release one claim. Ending an already-ended (or expired-and-pruned) token
    /// is a no-op, which is what makes the known double-end sites safe.
    func noteEnded(_ token: ClaimToken) {
        entries.removeValue(forKey: token)
    }

    // MARK: - Queries

    /// EARLIEST non-expired claim for the conversation — so a row's elapsed
    /// clock reports the oldest live turn, which is the one the user is waiting
    /// on.
    func liveSince(_ id: UUID, now: Date = Date()) -> Date? {
        entries.values
            .filter { $0.conversationID == id && !Self.isExpired($0, now: now) }
            .map(\.startedAt)
            .min()
    }

    /// When the request body for the turn `liveSince` names left this device,
    /// or nil while nothing has been sent yet.
    ///
    /// Reads the SAME claim `liveSince` picks — deliberately, so the words and
    /// the number on a row always describe one claim. If that claim is unstamped
    /// but a LATER sibling claim in the same conversation carries a stamp of its
    /// own (a lane that stamps at creation), this returns nil rather than
    /// borrowing it.
    ///
    /// THE GUARANTEE THAT BUYS IS NARROWER THAN IT LOOKS, and the honest
    /// statement of it is: the stamp is conversation-scoped. `noteDispatched`
    /// writes a departure onto the conversation's OLDEST live claim whichever
    /// turn departed, and the background lane's probe OR-folds departure across
    /// the tasks sharing a conversation before `reconcile()` ever sees it. So
    /// with two overlapping turns the younger one's departure does move this
    /// row, and the read side cannot undo that — it only declines to reach
    /// ACROSS claims for a stamp. Sharpening it would mean carrying a task
    /// identity from the transport into a claim token, which is a design change
    /// and not a doc fix.
    func dispatchedSince(_ id: UUID, now: Date = Date()) -> Date? {
        entries.values
            .filter { $0.conversationID == id && !Self.isExpired($0, now: now) }
            .min { $0.startedAt < $1.startedAt }?
            .dispatchedAt
    }

    /// Whether ANY non-expired claim on this conversation carries a handle this
    /// device can actually use to stop the turn.
    func isCancellable(_ id: UUID, now: Date = Date()) -> Bool {
        entries.values.contains {
            $0.conversationID == id && $0.isCancellable && !Self.isExpired($0, now: now)
        }
    }

    /// Conversations with at least one non-expired claim.
    var liveIDs: Set<UUID> {
        let now = Date()
        return Set(
            entries.values
                .filter { !Self.isExpired($0, now: now) }
                .map(\.conversationID)
        )
    }

    /// The macOS quit guard's predicate: how many CONVERSATIONS hold ≥1
    /// non-expired claim. macOS registers no probes, so this is exactly "a turn
    /// this process owns". A stored `sending` row from another device is
    /// explicitly NOT a reason to block quit.
    var liveCount: Int { liveIDs.count }

    /// For the quit-guard copy when exactly one conversation is live.
    var soleLiveConversationID: UUID? {
        let ids = liveIDs
        return ids.count == 1 ? ids.first : nil
    }

    // MARK: - Expiry

    /// Anchored on the LATER of the claim's birth and its departure stamp.
    ///
    /// A departure is the strongest evidence this file ever gets that a turn is
    /// real and running — the device demonstrably put bytes on the wire for it —
    /// so reaping a claim a shorter interval after that than after a claim
    /// nothing has confirmed would have the horizon backwards. Anchoring on
    /// `startedAt` alone let a parked-then-departed turn lose its stamp while
    /// its row was still on screen, which walked the thread backwards out of
    /// "…is answering…" and re-implied that nothing had been sent.
    ///
    /// The lanes that stamp at claim time are unaffected: their two dates are
    /// the same instant, so `max` returns what the old expression returned.
    private static func isExpired(_ entry: Entry, now: Date) -> Bool {
        let anchor = max(entry.startedAt, entry.dispatchedAt ?? entry.startedAt)
        return now.timeIntervalSince(anchor) > claimTTL
    }

    /// Drop aged-out claims. Purely hygiene — every query already filters on
    /// expiry, so this only keeps the dictionary from growing across a long
    /// session on a surface (macOS) that registers no probes.
    private func pruneExpired(now: Date) {
        let stale = entries.filter { Self.isExpired($0.value, now: now) }
        guard !stale.isEmpty else { return }
        for (token, _) in stale { entries.removeValue(forKey: token) }
    }

    // MARK: - Testing

    static func _resetForTesting() {
        let registry = shared
        registry.entries.removeAll()
        registry.probes.removeAll()
    }
}
