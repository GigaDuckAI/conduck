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
//
// One exception to "the store is the single source of truth", and it is
// deliberate: agent-output FILES. The wrist holds no file-server credential, so
// it can never discover a file the agent produced — the iPhone discovers it,
// attaches it, and CloudKit mirrors that row here minutes later. The iPhone also
// couriers the row's metadata over WatchConnectivity in about a second, and
// `WatchAttachmentInbox` holds it until the authoritative row lands. Every
// thread fetch here is merged through that inbox, which is also what retires an
// entry: the merge sees the real row and drops the couriered one in the same
// pass, so the two can never both render. See `WatchAttachmentInbox` for why
// this is an overlay and not a local Core Data write.

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

    /// Injected agent-file overlay. Every thread fetch is merged through it so a
    /// couriered file row shows immediately; the merge also retires entries whose
    /// authoritative row has arrived.
    private let attachmentInbox: WatchAttachmentInbox

    init(
        store: ConversationStore = .shared,
        attachmentInbox: WatchAttachmentInbox = .shared
    ) {
        self.store = store
        self.attachmentInbox = attachmentInbox
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
            // `.turnStates` adds exactly ONE query for the whole list (never one
            // per row — the wrist takes no per-row fetch), and it is also what
            // makes a status flip repaint at all: `sending → failed` writes only
            // `Message` columns and does not bump `lastActivityAt`, so without
            // the two derived fields the equality skip below would swallow it.
            let fresh = try await store.fetchConversations(activity: .turnStates)
            hasCompletedInitialLoad = true
            // Read-state housekeeping on the SAME main-actor turn the rows are
            // assigned, so a row never renders against fresh records and a stale
            // overlay. Two jobs, both PUSHES: retire the optimistic echoes these
            // records have caught up with, and fold the legacy device-local read
            // keys of the conversations that actually turned up. It has to
            // happen here because `ReadStateStore`'s reads are pure — a getter
            // that retired its own entry would mutate `@Observable` state from
            // inside a SwiftUI `body` — which leaves the fetch site the only
            // place retirement can occur. Unconditional, ahead of the equality
            // skip below: the TTL and the legacy drain still have work to do on
            // a pass whose list came back byte-identical.
            ReadStateStore.shared.reconcile(with: fresh)
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

    /// Resolve one list row's activity SYNCHRONOUSLY, for `body` — the row
    /// renders it in the date slot and in its trailing mark, so this must not
    /// await and must not fetch.
    ///
    /// EVERY ATTENTION INPUT COMES OFF THE RECORD, which is the whole reason the
    /// wrist can show a mark at all. `Conversation.lastViewedAt` and
    /// `Conversation.failureSeenAttemptID` are CloudKit-mirrored columns, so a
    /// thread read on the iPad arrives here already read, and a failure
    /// acknowledged on the Mac arrives here already acknowledged — with no
    /// wrist-local marker to keep, and no extra query. The Watch app has its own
    /// container, so a wrist-local marker could only ever have recorded
    /// wrist-viewing; riding the record is what removes that limitation instead
    /// of working around it.
    ///
    /// `tailRole` COMES FROM THE STORED TAIL ENVELOPE, NEVER FROM A MESSAGE
    /// QUERY. "Is the newest message a reply?" is otherwise a per-row message
    /// fetch on the slowest device in the fleet — the same cost these rows
    /// already refuse for a preview — and `Conversation.tailProjection` exists
    /// precisely so the wrist does not pay it.
    ///
    /// A STALE OR ABSENT ENVELOPE SUPPRESSES THE UNSEEN MARK RATHER THAN
    /// GUESSING AT IT. `TailProjectionReading.role` is nil for both cases, and
    /// nil means NOT PROJECTED, which makes the resolver withhold the unseen
    /// branch entirely. iOS and macOS answer a stale envelope with the lazy tail
    /// fetch they can afford and schedule a repair; the wrist has neither
    /// option, and guessing is the one answer that can fail in the unsafe
    /// direction — a guessed `.agent` would light an amber disc on the user's
    /// own last message, and a guessed `.user` would hide a genuinely unread
    /// reply. Showing nothing is the honest third answer, and the repair the
    /// phone schedules is what ends it.
    ///
    /// Failure acknowledgement takes no argument at all: it is an identity match
    /// against one delivery attempt, and both sides of that match — the failed
    /// turn's `deliveryAttemptID` and the conversation's `failureSeenAttemptID`
    /// — ride in on the record this method is handed. No device-local value
    /// could answer it, because no timestamp can say WHICH attempt was seen.
    ///
    /// `ReadStateStore.lastViewed` folds this device's OPTIMISTIC OVERLAY over
    /// the record's own marker by `max`. That overlay is what un-bolds a row on
    /// the same runloop turn the user backs out of a thread, instead of leaving
    /// it lit for as long as a background save plus a CloudKit import takes. It
    /// is a PURE read — retirement happens in `reload()`'s `reconcile`, never
    /// here, because an `@Observable` mutation from inside a SwiftUI `body` is a
    /// rendering error.
    ///
    /// `locallyLiveSince` is this wrist's own App-Group in-flight marker, read
    /// through `WatchRecordingService` rather than the raw defaults keys. It is
    /// what separates "a turn is running HERE" (→ "Answering…") from "some
    /// device wrote a `sending` row that CloudKit mirrored to me" (→ "Waiting
    /// for a reply…"). Neither is ever a reason to write.
    func rowState(for convo: ConversationRecord, now: Date = Date()) -> ConversationRowState {
        ConversationActivityResolver.resolve(
            ConversationActivityInputs(
                record: convo,
                tailRole: TailProjection.read(
                    convo.tailProjection,
                    lastActivityAt: convo.lastActivityAt
                ).role
            ),
            locallyLiveSince: WatchRecordingService.shared.liveTurnStartedAt(for: convo.id, now: now),
            lastViewedAt: ReadStateStore.shared.lastViewed(convo.id, stored: convo.lastViewedAt),
            now: now
        )
    }

    func delete(_ conversation: ConversationRecord) {
        Task {
            do {
                try await store.deleteConversation(id: conversation.id)
                // Drop any couriered file rows for this thread. Their messages
                // are gone, so nothing can ever prove their authoritative rows
                // landed — without this they would sit invisible until the
                // inbox's age bound expired them.
                attachmentInbox.purgeConversation(conversation.id)
                // Same rule for the read-state residue. The durable markers are
                // columns on the conversation and die with it by cascade, so
                // this drops only what is device-local: the optimistic echo, and
                // any legacy read key that can no longer fold now that its
                // record is gone. A real deletion is the ONE authoritative
                // signal that those are dead — absence from a fetch is not,
                // because an offline wrist launch reads a partial local mirror
                // long before the CloudKit import lands.
                ReadStateStore.shared.forget(conversation.id)
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
            threadMessages = attachmentInbox.merged(
                into: try await store.fetchMessages(for: conversationID)
            )
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
            // Merged through the agent-file inbox, which is what makes a
            // couriered file row surface HERE — the courier's ingest posts
            // `.conversationsDidChange`, the refresh worker calls this, and the
            // merged thread differs by value because `MessageRecord` equality
            // includes its attachments. Without the merge the notification would
            // fetch an unchanged thread and the equality skip below would
            // correctly swallow it, and the row would wait for CloudKit.
            let fresh = attachmentInbox.merged(
                into: try await store.fetchMessages(for: conversationID)
            )
            // Equality skip, same as `reload()` — an unchanged thread must not
            // re-render every visible bubble. The merge is a pure function of
            // (fetched rows, inbox entries), so a genuinely unchanged pass stays
            // equal and still skips.
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

    /// Total attachment rows across the open thread.
    ///
    /// The thread view snaps to the bottom on `threadMessages.count` changing —
    /// which a file landing on an EXISTING reply does not change, so the new row
    /// would draw below the fold on a wrist and the user would conclude nothing
    /// happened. This is the companion signal for exactly that case.
    var threadAttachmentCount: Int {
        threadMessages.reduce(0) { $0 + $1.attachments.count }
    }
}
