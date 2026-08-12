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

    /// Probes report only conversation ids, so LANE AND CANCELLABILITY ARE
    /// DECLARED AT REGISTRATION — the registration site knows which session it
    /// is wiring. A CarPlay upload is not cancellable through
    /// `BackgroundRemoteAgent.cancel`, so it must not light a Stop button.
    typealias Probe = @Sendable () async -> Set<UUID>

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
    }

    private struct RegisteredProbe {
        let lane: Lane
        let isCancellable: Bool
        let probe: Probe
    }

    // MARK: - Singleton

    static let shared = InFlightTurnRegistry()

    /// == `Constants.remoteAgentConverseResourceTimeout` — the longest a turn
    /// can legitimately be in flight. A view model deallocated mid-flight cannot
    /// detach its own claim, so a leaked claim ages out instead of pinning a
    /// spinner forever.
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
    func reconcile() async {
        pruneExpired(now: Date())
        for registered in probes {
            let reported = await registered.probe()
            let now = Date()
            var next: [ClaimToken: Entry] = [:]
            var covered: Set<UUID> = []
            for (token, entry) in entries where entry.lane == registered.lane {
                guard reported.contains(entry.conversationID) else { continue }
                if let existing = next.first(where: { $0.value.conversationID == entry.conversationID }) {
                    // Keep the oldest claim for a conversation — it is the turn
                    // the user has been waiting on.
                    if existing.value.startedAt <= entry.startedAt { continue }
                    next.removeValue(forKey: existing.key)
                }
                next[token] = entry
                covered.insert(entry.conversationID)
            }
            for id in reported where !covered.contains(id) {
                next[ClaimToken()] = Entry(
                    conversationID: id,
                    startedAt: now,
                    lane: registered.lane,
                    isCancellable: registered.isCancellable
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

    @discardableResult
    func noteBegan(
        _ id: UUID,
        lane: Lane,
        isCancellable: Bool,
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
            isCancellable: isCancellable
        )
        return token
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

    private static func isExpired(_ entry: Entry, now: Date) -> Bool {
        now.timeIntervalSince(entry.startedAt) > claimTTL
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
