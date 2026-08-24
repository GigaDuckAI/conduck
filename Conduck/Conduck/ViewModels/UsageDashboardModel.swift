// SPDX-License-Identifier: Apache-2.0

// Conduck
// UsageDashboardModel.swift
//
// Screen model for the Settings ▸ Usage dashboard. Owns the selected range,
// pulls the attempt ledger through `ConversationStore`, hands it to the pure
// `GatewayUsageAggregator`, and republishes one ready-to-render
// `GatewayUsageSummary`. Constructed once by each Settings host and injected
// into the content view — the `DiagnosticsRunner` posture — so switching
// sidebar categories does not rebuild an empty dashboard and refetch.
//
// IT NEVER WRITES. Not a repair pass, not a stale-row sweep, not a
// "reconciliation" of an attempt this device cannot find a task for. Attempts
// sync across the user's devices while `URLSession` registries are
// device-local, so an open row this Mac has no task for may be an iPhone's
// live turn; the honest answer is a DERIVED display state, recomputed on every
// load, and `GatewayAttemptEffectiveOutcome` is where that happens.
//
// THE FIRST LOAD IS DEFERRED, DELIBERATELY. The observer wiring happens at
// init because it is free, but nothing fetches until the view calls `start()`.
// The hosts build this model whether or not anyone opens Usage, and a Core Data
// sweep of the whole ledger on every Settings construction would be work for a
// screen nobody looked at. For the same reason the change observer stays inert
// until the first load: a CloudKit import storm must not drive refetches for an
// unopened screen.
//
// TWO START DATES, AND THEY ARE NOT THE SAME DATE. `measurementStart` is the
// earliest attempt the dashboard can still see; `activityHistoryStart` is the
// earliest conversation the user has kept. History that predates the ledger is
// real usage with no measurement behind it, so the coverage footer has to be
// able to say both — one number claiming to cover everything would be false for
// every user who upgraded into this feature.
//
// EVERY TOTAL DESCRIBES RETAINED HISTORY. Deleting a conversation deletes its
// attempts, and the numbers here move. That is the deletion contract working,
// not data loss.
//
// CONTENT-FREE, AND THAT IS RELEASE-BLOCKING. Nothing this model holds or
// renders touches prompt or reply text, a URL, a host, a token, a display name,
// a provider error string or an HTTP status. `gatewayRef` is a
// `RemoteAgentRef.rawString` — resolve it to a display name at render time, and
// never store the resolved name here.

import Foundation
import Observation

// MARK: - Data seam

/// Everything the dashboard reads, behind one seam so the model can be driven
/// from fixtures and so the platform-specific live-task probes stay out of it.
protocol UsageDashboardSource: Sendable {
    /// Recorded attempts whose `startedAt` falls in the window, oldest first.
    /// Attempts belonging to conversations the user deleted are already
    /// filtered out by the store.
    func attempts(from: Date?, to: Date?) async throws -> [GatewayAttemptRecord]

    /// Earliest VISIBLE attempt start — when measurement began, as far as
    /// retained history can still show it.
    func measurementStart() async throws -> Date?

    /// Earliest retained conversation. The start of activity history, which is
    /// older than measurement for anyone who used Conduck before the ledger.
    func activityHistoryStart() async throws -> Date?

    /// Attempt ids THIS device currently holds a live task for. Local evidence
    /// only: absence never means an attempt is dead, which is exactly why it
    /// can only ever produce a derived display state.
    func liveAttemptIDs() async -> Set<UUID>
}

/// Production source: the shared store plus this device's live-task registries.
///
/// `nonisolated` because it is the DEFAULT ARGUMENT of a `@MainActor` init, and
/// a default argument is evaluated in the CALLER's context — a main-actor
/// memberwise init would be an isolation violation at every non-main call site.
/// Nothing here holds state; each method only awaits an actor.
nonisolated struct LiveUsageDashboardSource: UsageDashboardSource {
    func attempts(from: Date?, to: Date?) async throws -> [GatewayAttemptRecord] {
        try await ConversationStore.shared.fetchGatewayAttempts(from: from, to: to)
    }

    func measurementStart() async throws -> Date? {
        try await ConversationStore.shared.earliestGatewayAttemptStart()
    }

    /// Conversation rows only — no message fetch. `createdAt` is the cheapest
    /// honest floor on retained history, and the footer that renders it says
    /// "conversations you've kept" rather than claiming a turn count.
    func activityHistoryStart() async throws -> Date? {
        try await ConversationStore.shared.fetchConversations().map(\.createdAt).min()
    }

    /// iOS carries both background uploaders, and both can be holding a task
    /// across a relaunch that emptied every in-memory registry — hence
    /// `allTasks`, not the registries.
    ///
    /// macOS answers with nothing, and that is correct rather than missing
    /// coverage: the Mac dispatches through the FOREGROUND client, whose tasks
    /// are process-local and terminalize in-process within the same run, so a
    /// Mac's own open row is `pending` for as long as its turn is actually
    /// running. Reaching for `BackgroundRemoteAgent.shared` here would
    /// materialize a background session the Mac otherwise never creates, purely
    /// to be told it is empty.
    func liveAttemptIDs() async -> Set<UUID> {
        #if os(iOS)
        async let converse = BackgroundRemoteAgent.shared.liveAttemptIDs()
        async let carPlay = CarPlayConverseUploader.shared.liveAttemptIDs()
        return await converse.union(carPlay)
        #else
        return []
        #endif
    }
}

// MARK: - Model

@Observable
@MainActor
final class UsageDashboardModel {

    /// The windows the range picker offers. Day counts are named here and
    /// nowhere else.
    enum Range: String, CaseIterable, Identifiable, Sendable {
        case week
        case month
        case quarter
        case all

        static let weekDays = 7
        static let monthDays = 30
        static let quarterDays = 90

        var id: String { rawValue }

        /// Days INCLUDING today, or nil for the whole retained history.
        var days: Int? {
            switch self {
            case .week: return Self.weekDays
            case .month: return Self.monthDays
            case .quarter: return Self.quarterDays
            case .all: return nil
            }
        }

        var title: LocalizedStringResource {
            switch self {
            case .week: return LocalizedStringResource(
                "settings.usage.range.week", defaultValue: "7 days")
            case .month: return LocalizedStringResource(
                "settings.usage.range.month", defaultValue: "30 days")
            case .quarter: return LocalizedStringResource(
                "settings.usage.range.quarter", defaultValue: "90 days")
            case .all: return LocalizedStringResource(
                "settings.usage.range.all", defaultValue: "All")
            }
        }
    }

    // MARK: - Published state

    /// Selected window. Assigning it reloads; assigning the current value does
    /// nothing, so a picker that re-emits its selection costs no fetch.
    var range: Range = .month {
        didSet {
            guard oldValue != range, hasStarted else { return }
            scheduleReload()
        }
    }

    /// Everything the cards draw. `.empty` until the first load resolves, so
    /// the screen renders zeros rather than nil-checking every field.
    private(set) var summary: GatewayUsageSummary = .empty

    private(set) var isLoading = false

    /// Set when a fetch threw. The screen keeps the previous summary on screen
    /// beneath it — a transient store error should not blank the dashboard.
    private(set) var loadError: String?

    /// False until the first load resolves. The empty state must not flash
    /// before the data has had a chance to arrive.
    private(set) var hasLoaded = false

    /// Whether the ledger holds ANY visible attempt, independent of the
    /// selected range. This is what the empty-state card asks: "90 days shows
    /// nothing" and "nothing has ever been recorded" deserve different copy.
    private(set) var hasAnyRecordedAttempts = false

    /// Earliest attempt the dashboard can still see. Nil before the first load,
    /// and nil forever for a user whose measured conversations are all deleted.
    private(set) var measurementStart: Date?

    /// Earliest retained conversation. Shown only when it PREDATES
    /// `measurementStart`, where it is the whole point: activity older than the
    /// ledger is real and unmeasured.
    private(set) var activityHistoryStart: Date?

    /// The window the current `summary` actually describes. `start` is nil for
    /// `.all`; `end` is the instant every derived outcome was evaluated at.
    private(set) var rangeStart: Date?
    private(set) var rangeEnd: Date?

    /// True when retained history reaches back further than measurement does —
    /// the condition the coverage footer's second line exists for.
    var hasUnmeasuredHistory: Bool {
        guard let activityHistoryStart, let measurementStart else { return false }
        return activityHistoryStart < measurementStart
    }

    // MARK: - Dependencies

    private let source: any UsageDashboardSource
    private let clock: @Sendable () -> Date
    private let calendar: Calendar

    /// Holder so `deinit` can detach the observers without touching main-actor
    /// state from a nonisolated context (verbatim `ConversationListViewModel`).
    private final class ObserverBox {
        var observers: [NSObjectProtocol] = []

        deinit {
            for observer in observers {
                NotificationCenter.default.removeObserver(observer)
            }
        }
    }

    private let observerBox = ObserverBox()

    /// Coalescing guard: a CloudKit import posts `.conversationsDidChange`
    /// dozens of times in a beat, and one full-ledger aggregation per post
    /// would stack on the main actor. Collapses a burst into at most two loads
    /// — one in flight, one trailing. `@ObservationIgnored`: pure bookkeeping,
    /// nothing renders it.
    @ObservationIgnored private var reloadTask: Task<Void, Never>?
    @ObservationIgnored private var reloadPending = false

    /// Latch for the deferred first load. SwiftUI can fire a `.task` more than
    /// once for the same view identity (the `DiagnosticsRunner.runAutoReads`
    /// problem), and this screen's load is a whole-ledger fetch.
    @ObservationIgnored private var hasStarted = false

    init(
        source: any UsageDashboardSource = LiveUsageDashboardSource(),
        clock: @escaping @Sendable () -> Date = { Date() },
        calendar: Calendar = .current
    ) {
        self.source = source
        self.clock = clock
        self.calendar = calendar

        // `.conversationsDidChange` = a store mutation or a merged CloudKit
        // import. Attempt-only writes deliberately do NOT post it — every one
        // of them rides beside a `Message` write from the same lane, and that
        // write posts. `.conversationsNeedLocalRefresh` = a foreground snapshot
        // re-read. Both mean the ledger may have moved underneath us.
        for name in [Notification.Name.conversationsDidChange, .conversationsNeedLocalRefresh] {
            observerBox.observers.append(
                NotificationCenter.default.addObserver(
                    forName: name,
                    object: nil,
                    queue: .main
                ) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        guard let self, self.hasStarted else { return }
                        self.scheduleReload()
                    }
                }
            )
        }
    }

    // MARK: - Loading

    /// First load, once per model. Safe to call from a `.task` that re-fires.
    func start() async {
        guard !hasStarted else { return }
        hasStarted = true
        await reload()
    }

    /// Explicit user-driven refresh (pull-to-refresh, a retry button). Goes
    /// through the same coalescing path so it cannot stack on an import storm.
    func refresh() {
        guard hasStarted else { return }
        scheduleReload()
    }

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

    /// Fetch, aggregate, publish. Best-effort throughout: the two boundary
    /// dates are read independently of the attempts, so a failure to resolve
    /// one of them costs a caption line and not the dashboard.
    func reload() async {
        isLoading = true
        loadError = nil

        let now = clock()
        let window = Self.window(for: range, now: now, calendar: calendar)

        do {
            let attempts = try await source.attempts(from: window.from, to: now)
            let live = await source.liveAttemptIDs()
            let measured = try? await source.measurementStart()
            let history = try? await source.activityHistoryStart()

            measurementStart = measured
            activityHistoryStart = history
            rangeStart = window.from
            rangeEnd = now
            // `.all` has no fetched lower bound, so its chart spans from the
            // first thing ever measured — or, when nothing was, a single day,
            // which draws as one empty bar rather than an axis with no extent.
            let bucketStart = window.from ?? measured ?? now
            summary = GatewayUsageAggregator.summarize(
                attempts: attempts,
                liveAttemptIDs: live,
                now: now,
                activityRange: min(bucketStart, now)...now,
                calendar: calendar,
                grace: ConversationActivityResolver.staleSendingGrace
            )
            hasAnyRecordedAttempts = measured != nil || summary.recordedAttempts > 0
        } catch {
            // The previous summary stays on screen underneath the message: a
            // transient Core Data failure is a worse reason to blank a chart
            // than to leave one that is a few seconds stale.
            loadError = String(
                localized: "settings.usage.error.load",
                defaultValue: "Couldn't load your usage. Try again."
            )
        }

        hasLoaded = true
        isLoading = false
    }

    // MARK: - Window arithmetic

    /// The fetch window for a range. Bounded ranges start at the START OF DAY
    /// `days - 1` days back, so "7 days" means seven whole calendar bars ending
    /// with today rather than a rolling 168 hours that cuts the first bar in
    /// half.
    static func window(
        for range: Range,
        now: Date,
        calendar: Calendar
    ) -> (from: Date?, to: Date) {
        guard let days = range.days else { return (nil, now) }
        let today = calendar.startOfDay(for: now)
        let from = calendar.date(byAdding: .day, value: -(days - 1), to: today) ?? today
        return (from, now)
    }
}
