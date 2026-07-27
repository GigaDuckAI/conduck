// SPDX-License-Identifier: Apache-2.0

// Conduck
// WatchConversationViewModel.swift
//
// View model backing the Watch conversation browse (list + thread). Uses the
// deinit-safe `ObserverBox` observation pattern for a live refetch on
// `.conversationsDidChange`, matching the iOS `ConversationListViewModel`.
//
// Reads an injected `ConversationStore` (defaults to `.shared` — CloudKit-synced
// on device builds; the in-memory seam under test). The store is the single
// source of truth; this VM is a thin SwiftUI-facing cache.

import Foundation

/// Drives the Watch conversation list + selected thread. Refetches whenever
/// `.conversationsDidChange` fires (local write OR a merged CloudKit change).
@Observable
@MainActor
final class WatchConversationViewModel {
    var conversations: [ConversationRecord] = []
    var isLoading = false
    var loadError: String?

    /// Tier-2 whole-history content-search result: ids of conversations whose
    /// MESSAGE TEXT matches the active query. Filled by `runContentSearch(_:)`,
    /// cleared by `clearContentMatches()`. The list view unions it with the
    /// instant Tier-1 title/snippet match — identical search to iPhone/iPad/Mac.
    private(set) var contentMatchIDs: Set<UUID> = []
    /// True while a content-search predicate fetch is in flight (debounce
    /// elapsed, store query running). The list suppresses the "No matches"
    /// empty state while this is true so it doesn't flash before results land.
    private(set) var isSearchingContent = false
    /// Monotonic counter bumped when a refresh pass actually changes published
    /// data (list or open thread). Folded into the list's content-search
    /// `.task(id:)` key so an in-flight search re-runs when the data changes
    /// mid-search. NEVER bumped on a no-op pass — the key change cancels and
    /// restarts that search task, so a CloudKit remote-change echo of the
    /// wrist's own export must not re-key it.
    private(set) var changeGeneration = 0

    /// Messages for the currently-open thread (oldest → newest).
    var threadMessages: [MessageRecord] = []
    var isLoadingThread = false

    /// The conversation the open thread view is showing — set by
    /// `WatchConversationThreadView` on appear, cleared on disappear. Drives the
    /// mid-stream refresh on `.conversationsDidChange`: the agent reply lands via
    /// the background converse delegate's `appendMessage` (a separate Task), so
    /// the open thread view needs the notification-driven reload to surface it
    /// without a manual pull-to-refresh.
    var selectedConversationID: UUID?

    /// Holder so the observer detaches on `deinit` without touching main-actor
    /// state from a nonisolated context (verbatim iOS `ConversationListViewModel`).
    private final class ObserverBox {
        var observer: NSObjectProtocol?
        deinit {
            if let observer {
                NotificationCenter.default.removeObserver(observer)
            }
        }
    }
    private let observerBox = ObserverBox()

    /// Single-flight coalescing for `.conversationsDidChange`. A worker is in
    /// flight while `refreshInFlight`; `refreshDirty` records that at least one
    /// notification arrived since the worker last started a pass. One logical
    /// reply fires SEVERAL notifications (local user-turn save + local agent-reply
    /// save + the CloudKit remote-change echo of the wrist's own export), so
    /// without coalescing each one ran a full `fetchConversations` + full
    /// `fetchMessages` on the main actor. Collapsing the burst into one worker
    /// that re-runs iff re-dirtied mid-fetch is the whole win.
    private var refreshInFlight = false
    private var refreshDirty = false

    /// True once a fetch has completed SUCCESSFULLY. Distinguishes "list is
    /// empty because we haven't loaded yet" from "list is genuinely empty" —
    /// without it, every refresh pass on an empty store (debounced CloudKit
    /// echoes, delete-last-conversation echoes) re-infers first-population
    /// from `conversations.isEmpty` and flickers the empty state to a spinner.
    /// A failed fetch leaves it false so an empty-state retry still spins.
    private var hasCompletedInitialLoad = false

    /// Injected store seam — `.shared` in production, the in-memory container
    /// under test so refresh-machinery tests never touch the CloudKit store.
    private let store: ConversationStore

    init(store: ConversationStore = .shared) {
        self.store = store
        observerBox.observer = NotificationCenter.default.addObserver(
            forName: .conversationsDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // `queue: .main` runs this on the main thread; hop onto the actor to
            // touch the coalescing state, then let the worker do the fetching.
            Task { @MainActor [weak self] in self?.scheduleRefresh() }
        }
        Task { await reload() }
    }

    /// Coalesce a `.conversationsDidChange` burst into a single in-flight worker.
    /// CORRECTNESS (load-bearing): the worker re-runs while `refreshDirty` — a
    /// notification landing MID-fetch (e.g. the agent reply arriving during the
    /// user-turn refetch) sets the flag and earns another pass, so a reply is
    /// NEVER dropped. It must coalesce, never *ignore*, notifications.
    private func scheduleRefresh() {
        refreshDirty = true
        guard !refreshInFlight else { return }
        refreshInFlight = true
        Task { [weak self] in
            guard let self else { return }
            while self.refreshDirty {
                self.refreshDirty = false
                let passStart = Date()
                var passChanged = await self.reload()
                // Mid-stream thread refresh: if a thread is open, the user's
                // typed/spoken turn AND the background-delivered agent reply both
                // fire `.conversationsDidChange` via `appendMessage`. Re-fetching
                // here lets the open bubble list reflect both without UI polling.
                if let id = self.selectedConversationID,
                   await self.refreshThread(for: id) {
                    passChanged = true
                }
                // Bump the change generation so an in-flight content search
                // (keyed on it in the list `.task(id:)`) re-runs against the
                // freshly-loaded data. Gated on a REAL change: a no-op pass
                // (e.g. the CloudKit echo of the wrist's own export) must not
                // cancel + restart the search task or re-key the list.
                if passChanged {
                    self.changeGeneration += 1
                }
                // Field baseline for the store-read rework: how long one full
                // refresh pass held the main actor and how much it re-read.
                // Counts + duration only — metadata, never content.
                WatchLog.note(.nav, "refresh.pass", [
                    "ms": Int(Date().timeIntervalSince(passStart) * 1000),
                    "convos": self.conversations.count,
                    "msgs": self.threadMessages.count
                ])
            }
            self.refreshInFlight = false
        }
    }

    // MARK: - List

    /// Refetch the conversation list. Returns whether `conversations` actually
    /// changed so the refresh worker can gate `changeGeneration` on it.
    @discardableResult
    func reload() async -> Bool {
        // The spinner gates only the FIRST load (no successful fetch yet:
        // initial load / empty-state retry after an error). Steady-state
        // refreshes never write `isLoading` — `@Observable` publishes every
        // write regardless of value, and a spinner toggle per refresh pass
        // forces two list re-evaluations even when nothing changed. Gating on
        // `hasCompletedInitialLoad` (not `conversations.isEmpty` alone) keeps
        // a genuinely EMPTY store's refresh passes from flickering the
        // "no conversations" empty state into a spinner on every echo.
        let firstPopulation = conversations.isEmpty && !hasCompletedInitialLoad
        if firstPopulation, !isLoading { isLoading = true }
        if loadError != nil { loadError = nil }
        var changed = false
        do {
            let fresh = try await store.fetchConversations()
            hasCompletedInitialLoad = true
            // Assign only on a REAL change — the records are Hashable value
            // snapshots, and `@Observable` invalidates on reassignment regardless
            // of equality, so a no-op pass (e.g. the CloudKit remote-change echo
            // of the wrist's own export) would re-render the whole list.
            if fresh != conversations {
                conversations = fresh
                changed = true
            }
        } catch {
            // xcstrings
            loadError = String(localized: "Couldn't load your conversations.")
        }
        if isLoading { isLoading = false }
        return changed
    }

    func delete(_ conversation: ConversationRecord) {
        Task {
            do {
                try await store.deleteConversation(id: conversation.id)
                conversations.removeAll { $0.id == conversation.id }
                changeGeneration += 1
            } catch {
                // Non-fatal — the change notification re-fetches on next write.
            }
        }
    }

    // MARK: - Content search (Tier 2)

    /// Run the whole-history content search for `query` (already normalized,
    /// non-empty) and store the matching conversation ids. Toggles
    /// `isSearchingContent` around the fetch so the list can suppress the "No
    /// matches" state until results land. Called from the list's debounced
    /// `.task(id:)` after the debounce + cancellation guard.
    func runContentSearch(_ query: String) async {
        isSearchingContent = true
        let ids = (try? await store.searchConversationIDs(containing: query)) ?? []
        guard !Task.isCancelled else { return }   // query changed during the fetch → drop the stale result
        contentMatchIDs = ids
        isSearchingContent = false
    }

    /// Raise the in-flight flag at the START of a debounced search (before the
    /// debounce sleep) so the list suppresses "No matches" across the whole
    /// pending window, not just the fetch — otherwise it flashes during the
    /// debounce when Tier-1 has no hits. Mirrors the iOS surface.
    func markSearchPending() {
        isSearchingContent = true
    }

    /// Clear the content-search result set (empty query). Also drops the
    /// in-flight flag so the empty store / no-query path renders cleanly.
    func clearContentMatches() {
        contentMatchIDs = []
        isSearchingContent = false
    }

    // MARK: - Thread

    /// Load a conversation's messages for the thread view. Graceful no-op if the
    /// conversation UUID was deleted on another device (returns an empty thread
    /// rather than erroring).
    func loadThread(for conversationID: UUID) async {
        isLoadingThread = true
        // Clear stale messages before the fetch so a re-load never flashes the
        // previous thread's bubbles while the new fetch is in flight.
        threadMessages = []
        do {
            threadMessages = try await store.fetchMessages(for: conversationID)
        } catch {
            threadMessages = []
        }
        isLoadingThread = false
    }

    /// Re-fetch the open thread WITHOUT clearing `threadMessages` first — used by
    /// the `.conversationsDidChange` observer so a mid-stream append (user turn,
    /// background-delivered agent reply) updates the visible bubble list without
    /// flashing it empty. Also leaves `isLoadingThread` untouched so the spinner
    /// doesn't re-fire on every reply. Returns whether the visible messages
    /// changed so the refresh worker can gate `changeGeneration` on it.
    @discardableResult
    func refreshThread(for conversationID: UUID) async -> Bool {
        do {
            let fresh = try await store.fetchMessages(for: conversationID)
            // Equality skip, same as `reload()` — an unchanged thread must not
            // re-render every visible bubble.
            if fresh != threadMessages {
                threadMessages = fresh
                return true
            }
        } catch {
            // Non-fatal — keep what's on screen rather than wiping it on a
            // transient fetch error.
        }
        return false
    }
}
