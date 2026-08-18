// SPDX-License-Identifier: Apache-2.0

// Conduck
// ConversationListViewModel.swift
//
// Observable view model backing the conversation LIST surface (iOS toolbar
// push, macOS library, Watch browse). Split 1→2 with
// `ConversationDetailViewModel`.
//
// `@Observable @MainActor` + the nested deinit-safe `ObserverBox` pattern — the
// box lets `deinit` detach the
// `.conversationsDidChange` observer without touching `@MainActor` state from
// a nonisolated context.

import Foundation
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif

/// Drives the conversation list: fetches from `ConversationStore.shared` and
/// re-fetches whenever `.conversationsDidChange` fires (local mutation OR a
/// merged CloudKit remote change).
@Observable
@MainActor
final class ConversationListViewModel {
    var conversations: [ConversationRecord] = []
    var isLoading = false
    var loadError: String?

    /// Monotonic counter bumped whenever `conversations` is (re)assigned — a
    /// local mutation, a delete, or a merged CloudKit remote change routed
    /// through `reload()`. The list view folds it into the content-search
    /// `.task(id:)` key so an in-flight whole-history search RE-RUNS when the
    /// underlying data changes mid-search (otherwise a search started before a
    /// new turn landed would show a stale match set).
    private(set) var changeGeneration = 0

    /// Holder so the observer can be detached on `deinit` without touching
    /// main-actor state from a nonisolated context (verbatim NotesViewModel).
    private final class ObserverBox {
        var observers: [NSObjectProtocol] = []

        deinit {
            for observer in observers {
                NotificationCenter.default.removeObserver(observer)
            }
        }
    }

    private let observerBox = ObserverBox()

    /// Coalescing guard for `.conversationsDidChange` → `reload()`. A CloudKit
    /// import storm posts that notification dozens of times in a beat; without
    /// this each post spawned its own `Task { reload() }`, stacking overlapping
    /// full-list refetches on the main actor. `scheduleReload()` collapses a
    /// burst into ≤2 reloads. `@ObservationIgnored` — pure bookkeeping.
    @ObservationIgnored private var reloadTask: Task<Void, Never>?
    @ObservationIgnored private var reloadPending = false

    init() {
        // `.conversationsDidChange` = a store mutation / merged CloudKit import.
        // `.conversationsNeedLocalRefresh` = a foreground snapshot re-read (no
        // store write, just re-display the latest local state). Both → reload().
        for name in [Notification.Name.conversationsDidChange, .conversationsNeedLocalRefresh] {
            observerBox.observers.append(
                NotificationCenter.default.addObserver(
                    forName: name,
                    object: nil,
                    queue: .main
                ) { [weak self] _ in
                    // Coalesce (not one `Task { reload() }` per post) — see
                    // `scheduleReload()`. `queue: .main` runs this on the main
                    // thread; hop into the actor to touch the guard state.
                    Task { @MainActor [weak self] in self?.scheduleReload() }
                }
            )
        }

        Task { await self.reload() }
    }

    // MARK: - Loading

    /// Coalesce a burst of `.conversationsDidChange` posts into ≤2 reloads (one
    /// in-flight + one trailing). Main-actor-serialized; no `await` between the
    /// pending-check and clearing `reloadTask`, so the tail is atomic.
    private func scheduleReload() {
        if reloadTask != nil {
            reloadPending = true
            return
        }
        reloadTask = Task { [weak self] in
            guard let self else { return }
            repeat {
                self.reloadPending = false
                await self.reload()
            } while self.reloadPending
            self.reloadTask = nil
        }
    }

    func reload() async {
        isLoading = true
        loadError = nil
        do {
            // `.turnStates` costs exactly ONE extra query for the whole list, not
            // one per conversation — and it is also what makes a status flip
            // repaint at all: `sending → failed` writes only `Message` columns
            // and does not bump `lastActivityAt`, so without the derived fields
            // the equality check below is false and nothing changes on screen.
            let fetched = try await ConversationStore.shared.fetchConversations(activity: .turnStates)
            // Re-run the liveness probes BEFORE assigning, so the registry and
            // the rows land in one main-actor turn — a row never renders against
            // fresh conversations and a stale claim set.
            await InFlightTurnRegistry.shared.reconcile()
            // Same rule, same turn, for the read-state overlay: retire the
            // optimistic echoes these records have caught up with, and let the
            // legacy device-local markers of the conversations that actually
            // turned up fold into their records. Both are pushes, never pulls —
            // `ReadStateStore`'s reads are pure so a SwiftUI `body` can call
            // them, which leaves this the only place retirement can happen.
            ReadStateStore.shared.reconcile(with: fetched)
            // Third pass over the same records, and the only one that writes to
            // the store: rewrite the tail envelopes that came back unusable.
            scheduleTailProjectionRepairs(for: fetched)
            // Skip the reassignment + `changeGeneration` bump when a no-op import
            // echo re-fetches an identical list (the storm's cheapest exit); the
            // generation bump only needs to fire when the data actually changed.
            if fetched != conversations {
                conversations = fetched
                changeGeneration += 1
            }
        } catch {
            loadError = String(localized: "Couldn't load your conversations. Try again.")
        }
        isLoading = false
    }

    /// How many stale tail envelopes one reload is allowed to repair.
    ///
    /// EVERY conversation that predates the envelope column reads stale, so the
    /// first launch after the attribute lands has the whole history to fix — an
    /// unbounded pass there would run one fetch, one write and one CKRecord
    /// export per conversation in a single burst, on the launch that is already
    /// paying for the model migration and the initial import. The cap spreads
    /// that across reloads instead: the store marks only what it ATTEMPTED, so
    /// whatever this pass leaves behind is picked up by the next one, and a
    /// conversation still unrepaired when the process ends is simply retried at
    /// the next launch. Nothing on this device waits for the result — the phone
    /// and the Mac already have the tail role from their own per-row fetch — so
    /// finishing late costs nothing here and costs the wrist one more reload.
    private static let maxTailProjectionRepairsPerReload = 25

    /// Conversations this view model has already handed to the store's repair,
    /// so a later reload spends its budget on rows that have not been tried.
    ///
    /// THE BUDGET WOULD OTHERWISE BE PERMANENTLY CONSUMED BY ROWS THAT CANNOT BE
    /// FIXED. `repairTailProjection` refuses a second attempt per conversation
    /// per process and writes nothing for a row whose real tail cannot produce a
    /// valid envelope — a conversation cloned by a build that stamped
    /// `lastActivityAt = now` while its copied tail sits a few milliseconds
    /// past, for instance, which stays repairABLE-looking forever because the
    /// envelope never becomes valid. Selecting purely on `isRepairable`, as the
    /// budget's only filter, would pick those same rows on every single reload
    /// and never reach the twenty-sixth stale conversation — which would keep
    /// showing no mark on the wrist for the life of the install, the exact
    /// failure the repair was added to close.
    ///
    /// Process-scoped, exactly like the store's own memo, and unbounded only in
    /// the sense the conversation list is: one UUID per conversation this device
    /// actually holds.
    private var tailProjectionRepairsRequested: Set<UUID> = []

    /// Ask the store to rewrite the tail envelopes these records could not use.
    ///
    /// WHY THE LIST DOES THIS AT ALL. The envelope exists for the Watch, which
    /// cannot afford a per-row message fetch and therefore has no fallback: a
    /// single append by a build that did not write the envelope leaves that
    /// conversation permanently mark-less on the wrist. iOS and macOS never
    /// notice, because they fall back to the lazy per-row tail fetch they were
    /// already doing for the row subtitle — which is exactly why the repair has
    /// to be scheduled from a surface that does not need it. This is the one
    /// place that reads every conversation the account has, so it is the one
    /// place that can see every envelope that needs fixing.
    ///
    /// A FUTURE version's envelope is deliberately not in this set:
    /// `isRepairable` is true only for `.stale`, never `.unreadableVersion`, so
    /// this device cannot start a downgrade fight with a newer one over a value
    /// the newer one would immediately restamp.
    ///
    /// Fire-and-forget, off the reload's own turn: the repair takes the store's
    /// write path and nothing on screen is waiting for it. `repairTailProjection`
    /// carries its own once-per-conversation-per-process guard, writes only on a
    /// real change and posts no change notification, so this cannot feed itself
    /// a reload. The set mirrored here is what makes the BUDGET advance past the
    /// rows that guard silently refuses — see `tailProjectionRepairsRequested`.
    private func scheduleTailProjectionRepairs(for records: [ConversationRecord]) {
        var stale: [UUID] = []
        for record in records {
            guard stale.count < Self.maxTailProjectionRepairsPerReload else { break }
            guard !tailProjectionRepairsRequested.contains(record.id) else { continue }
            guard TailProjection.read(
                record.tailProjection,
                lastActivityAt: record.lastActivityAt
            ).isRepairable else { continue }
            stale.append(record.id)
        }
        tailProjectionRepairsRequested.formUnion(stale)
        guard !stale.isEmpty else { return }
        Task {
            for id in stale {
                await ConversationStore.shared.repairTailProjection(conversationID: id)
            }
        }
    }

    // MARK: - Row state

    /// The delivery + attention state one row renders, resolved SYNCHRONOUSLY —
    /// a SwiftUI `body` cannot await, and both sources are in-memory.
    ///
    /// - Parameter tailRole: the role of the conversation's newest message, or
    ///   nil while the row's lazy tail fetch is still in flight. Nil suppresses
    ///   the unseen branch rather than guessing, so a row shows delivery state
    ///   only and then repaints — the same shape as today's blank-then-filled
    ///   preview.
    func rowState(
        for convo: ConversationRecord,
        tailRole: MessageRole?,
        now: Date = Date()
    ) -> ConversationRowState {
        ConversationRowActivity.state(
            inputs: ConversationActivityInputs(record: convo, tailRole: tailRole),
            conversationID: convo.id,
            now: now
        )
    }

    // MARK: - Mutations

    func delete(_ conversation: ConversationRecord) async {
        do {
            try await ConversationStore.shared.deleteConversation(id: conversation.id)
            // The durable markers are columns on the conversation and die with
            // it by cascade, so this drops only the device-local residue: the
            // optimistic echo and any legacy key that can no longer fold. A real
            // deletion is the ONLY thing that drops either — absence from a
            // fetch is not a deletion signal, because an offline launch reads a
            // partial local mirror before the CloudKit import lands.
            ReadStateStore.shared.forget(conversation.id)
            conversations.removeAll { $0.id == conversation.id }
            changeGeneration += 1
        } catch {
            // Non-fatal — the notification will re-fetch on the next write.
        }
    }

    func deleteAll() async {
        do {
            let doomed = conversations.map(\.id)
            try await ConversationStore.shared.deleteAll()
            // Same rule as `delete(_:)`, applied to every row this surface just
            // destroyed: echoes and legacy keys for conversations that no longer
            // exist can never retire on their own, since nothing will ever fetch
            // the record that would retire them.
            for id in doomed { ReadStateStore.shared.forget(id) }
            conversations = []
            changeGeneration += 1
        } catch {
            loadError = String(localized: "Couldn't clear your conversations. Try again.")
        }
    }
}
