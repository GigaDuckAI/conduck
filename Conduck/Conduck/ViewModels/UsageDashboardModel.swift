// SPDX-License-Identifier: Apache-2.0

// Conduck
// UsageDashboardModel.swift
//
// Screen model for the Settings ▸ Usage dashboard. Owns the selected range,
// pulls the attempt ledger through `ConversationStore`, hands it to the pure
// `GatewayUsageAggregator`, and republishes one ready-to-render
// `GatewayUsageSummary` plus the raw records the drill-down screens re-slice.
// Constructed once by each Settings host and injected into the content view —
// the `DiagnosticsRunner` posture — so switching sidebar categories does not
// rebuild an empty dashboard and refetch.
//
// AGGREGATION RUNS OFF THE MAIN ACTOR. `summarize` is pure and static, and the
// `.all` range can hand it every retained attempt the account has ever minted;
// running that on the main actor would stall Settings while it walked. The
// fetch and the summarize both happen in a `@concurrent` hop and only the
// finished value type crosses back. The loading flags are raised BEFORE the hop
// and lowered after the publish, so the screen never flashes its empty state
// across the gap.
//
// IT NEVER WRITES TO THE LEDGER — with exactly one exception the user asked
// for. Not a repair pass, not a stale-row sweep, not a "reconciliation" of an
// attempt this device cannot find a task for. Attempts sync across the user's
// devices while `URLSession` registries are device-local, so an open row this
// Mac has no task for may be an iPhone's live turn; the honest answer is a
// DERIVED display state, recomputed on every load, and
// `GatewayAttemptEffectiveOutcome` is where that happens. The exception is
// "Clear usage history", below.
//
// CLEAR IS A CUTOFF FIRST AND A DELETE SECOND. Clearing advances the synced
// `gatewayUsageClearedThrough` date, which every read here already excludes on,
// and only then purges the rows underneath it. That ordering is what makes the
// action account-wide: a device that was offline when the user cleared mints
// nothing new below the cutoff, and the rows it does carry get excluded the
// instant the cutoff syncs in — then purged by the opportunistic convergence
// pass the next time anyone opens this screen. The purge is FAIL-OPEN
// throughout: it can be interrupted, resumed, or never run at all, and the
// numbers on screen are correct either way because exclusion, not deletion, is
// what the totals obey.
//
// THE FIRST LOAD IS DEFERRED, DELIBERATELY. The observer wiring happens at
// init because it is free, but nothing fetches until the view calls `start()`.
// The hosts build this model whether or not anyone opens Usage, and a Core Data
// sweep of the whole ledger on every Settings construction would be work for a
// screen nobody looked at. For the same reason the change observer stays inert
// until the first load: a CloudKit import storm must not drive refetches for an
// unopened screen.
//
// USAGE OUTLIVES CONVERSATIONS. Deleting a conversation leaves its attempt rows
// standing, so the totals here describe measured history rather than retained
// content. `liveConversationIDs` is the only thing that says whether a ranked
// thread can still be opened — absence means deleted, not-yet-imported, or
// temporarily unavailable, which is why the row it drives says "unavailable"
// rather than "deleted".
//
// CONTENT-FREE, AND THAT IS RELEASE-BLOCKING. Nothing this model holds or
// renders touches prompt or reply text, a URL, a host, a token, a display name,
// a provider error string or an HTTP status. `gatewayRef` is a
// `RemoteAgentRef.rawString` — resolve it to a display name at render time, and
// never store the resolved name here.

import Foundation
import Observation

// MARK: - Data seam

/// Everything the dashboard reads and the one thing it writes, behind one seam
/// so the model can be driven from fixtures and so the platform-specific
/// live-task probes stay out of it.
protocol UsageDashboardSource: Sendable {
    /// Recorded attempts whose `startedAt` falls in the window, oldest first.
    /// Rows at or below `clearedThrough` are excluded by the store.
    func attempts(from: Date?, to: Date?, clearedThrough: Date?) async throws -> [GatewayAttemptRecord]

    /// Earliest VISIBLE attempt start — when measurement began, as far as the
    /// clear cutoff still lets the ledger show it.
    func measurementStart(clearedThrough: Date?) async throws -> Date?

    /// Attempt ids THIS device currently holds a live task for. Local evidence
    /// only: absence never means an attempt is dead, which is exactly why it
    /// can only ever produce a derived display state.
    func liveAttemptIDs() async -> Set<UUID>

    /// Conversations this device can currently resolve. Gates thread
    /// navigation only — never the counting.
    func liveConversationIDs() async -> Set<UUID>

    /// The synced clear cutoff, or nil when the user has never cleared.
    func clearedThrough() async -> Date?

    /// Move the cutoff forward and return the value that actually took effect.
    /// Never regresses: a device merging an older cutoff keeps the newer one.
    func advanceClearedThrough(to date: Date) async -> Date

    /// Delete every attempt at or below the cutoff. Idempotent and resumable —
    /// returns how many rows this pass removed.
    func purgeAttempts(through cutoff: Date) async throws -> Int
}

/// Production source: the shared store, the synced settings channel, and this
/// device's live-task registries.
///
/// `nonisolated` because it is the DEFAULT ARGUMENT of a `@MainActor` init, and
/// a default argument is evaluated in the CALLER's context — a main-actor
/// memberwise init would be an isolation violation at every non-main call site.
/// Nothing here holds state; each method only awaits an actor.
nonisolated struct LiveUsageDashboardSource: UsageDashboardSource {
    func attempts(from: Date?, to: Date?, clearedThrough: Date?) async throws -> [GatewayAttemptRecord] {
        try await ConversationStore.shared.fetchGatewayAttempts(
            from: from,
            to: to,
            clearedThrough: clearedThrough
        )
    }

    func measurementStart(clearedThrough: Date?) async throws -> Date? {
        try await ConversationStore.shared.earliestGatewayAttemptStart(clearedThrough: clearedThrough)
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

    func liveConversationIDs() async -> Set<UUID> {
        await ConversationStore.shared.liveConversationIDs()
    }

    func clearedThrough() async -> Date? {
        await SettingsManager.shared.gatewayUsageClearedThrough()
    }

    func advanceClearedThrough(to date: Date) async -> Date {
        await SettingsManager.shared.advanceGatewayUsageClearedThrough(date)
    }

    func purgeAttempts(through cutoff: Date) async throws -> Int {
        try await ConversationStore.shared.purgeGatewayAttempts(through: cutoff)
    }
}

// MARK: - Model

/// One load's worth of ledger, assembled off the main actor and crossing back
/// as one value. File-scoped and `nonisolated` on purpose: a type nested in the
/// `@MainActor` model would inherit that isolation and could not be built from
/// the background hop that produces it.
private nonisolated struct UsageDashboardLoad: Sendable {
    let records: [GatewayAttemptRecord]
    let summary: GatewayUsageSummary
    let measurementStart: Date?
    let liveAttemptIDs: Set<UUID>
    let liveConversationIDs: Set<UUID>
    let clearedThrough: Date?
    let chartRange: ClosedRange<Date>
}

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
    /// nothing, so a picker that re-emits its selection costs no fetch. The
    /// drill-down screens read the same model, so they follow the picker
    /// without carrying a range of their own.
    var range: Range = .month {
        didSet {
            guard oldValue != range, hasStarted else { return }
            scheduleReload()
        }
    }

    /// Everything the cards draw. `.empty` until the first load resolves, so
    /// the screen renders zeros rather than nil-checking every field.
    private(set) var summary: GatewayUsageSummary = .empty

    /// The records behind `summary`, kept so a drill-down can re-slice the
    /// range it is already showing instead of re-reading the store.
    private(set) var records: [GatewayAttemptRecord] = []

    /// Attempt ids this device holds a live task for, as of the last load.
    /// Republished so a drill-down summarizes under the same derived states the
    /// overview did rather than its own, later reading.
    private(set) var liveAttemptIDs: Set<UUID> = []

    /// Conversations this device can currently resolve. A ranked thread outside
    /// this set renders as unavailable and offers no navigation.
    private(set) var liveConversationIDs: Set<UUID> = []

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
    /// and nil after a clear that emptied the ledger.
    private(set) var measurementStart: Date?

    /// The synced clear cutoff in force for the numbers on screen.
    private(set) var clearedThrough: Date?

    /// True while "Clear usage history" is advancing the cutoff and purging.
    /// The destructive row disables itself on it.
    private(set) var isClearingUsageHistory = false

    /// Set when the purge threw. The cutoff has already moved by then, so the
    /// numbers are correct and only the row deletion is incomplete — which the
    /// next load's convergence pass finishes.
    private(set) var clearUsageHistoryError: String?

    /// The window the current `summary` actually describes. `start` is nil for
    /// `.all`; `end` is the instant every derived outcome was evaluated at.
    private(set) var rangeStart: Date?
    private(set) var rangeEnd: Date?

    // MARK: - Dependencies

    private let source: any UsageDashboardSource
    private let clock: @Sendable () -> Date
    private let calendar: Calendar

    /// Both the derived-state window and the ceiling on believable attempt
    /// timing. The shared stale-send grace, not a second constant.
    private let grace = ConversationActivityResolver.staleSendingGrace

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
    /// would stack. Collapses a burst into at most two loads — one in flight,
    /// one trailing. `@ObservationIgnored`: pure bookkeeping, nothing renders
    /// it.
    @ObservationIgnored private var reloadTask: Task<Void, Never>?
    @ObservationIgnored private var reloadPending = false

    /// Monotonic load token. The fetch+summarize hop is long enough that a
    /// range change can land mid-flight, and only the newest load may publish —
    /// otherwise a slow `.all` pass overwrites the 7-day numbers the user is
    /// already looking at.
    @ObservationIgnored private var loadGeneration = 0

    /// Latch for the deferred first load. SwiftUI can fire a `.task` more than
    /// once for the same view identity (the `DiagnosticsRunner.runAutoReads`
    /// problem), and this screen's load is a whole-ledger fetch.
    @ObservationIgnored private var hasStarted = false

    /// Memoized drill-down summaries for the CURRENT range. Dropped on every
    /// publish, so a route can never render numbers from a window the overview
    /// has already moved off. `@ObservationIgnored` because these are filled
    /// lazily from `body`, and an observed write there would loop.
    @ObservationIgnored private var drillDownCache: [UsageRoute: GatewayUsageSummary] = [:]

    /// The chart window the overview summarized under, reused so a drill-down's
    /// daily bars span the same days rather than only the days it happens to
    /// have rows for.
    @ObservationIgnored private var chartRange: ClosedRange<Date>?

    /// The cutoff the convergence purge has already been fired for. Stops the
    /// purge's own `postDidChange` from driving an endless reload → purge →
    /// reload loop, and stops an import storm from stacking purges.
    @ObservationIgnored private var purgedCutoff: Date?
    @ObservationIgnored private var isConvergencePurging = false

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
        // `.settingsDidChangeRemotely` carries the clear cutoff arriving from
        // another device, which moves the numbers without touching a row.
        for name in [
            Notification.Name.conversationsDidChange,
            .conversationsNeedLocalRefresh,
            .settingsDidChangeRemotely
        ] {
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

    /// Explicit user-driven refresh (pull-to-refresh, the error card's Try
    /// Again). Re-runs the same local read — there is nothing remote to retry —
    /// and goes through the coalescing path so it cannot stack on an import
    /// storm.
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

    /// Fetch, aggregate, publish. Best-effort throughout: `measurementStart` is
    /// read independently of the attempts, so a failure to resolve it costs a
    /// caption line and not the dashboard.
    func reload() async {
        loadGeneration += 1
        let generation = loadGeneration
        isLoading = true
        loadError = nil

        let now = clock()
        let window = Self.window(for: range, now: now, calendar: calendar)

        do {
            let loaded = try await Self.load(
                source: source,
                from: window.from,
                to: window.to,
                now: now,
                calendar: calendar,
                grace: grace
            )
            guard generation == loadGeneration else { return }
            publish(loaded, window: window, now: now)
        } catch {
            guard generation == loadGeneration else { return }
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

    /// `@concurrent` — and it has to be. This type is `@MainActor`, and under
    /// the target's `SWIFT_APPROACHABLE_CONCURRENCY` a bare `nonisolated async`
    /// static runs on the CALLER's executor, which here is the main actor; the
    /// annotation is the only spelling that reaches the generic executor. What
    /// it moves off the UI thread is the `summarize` pass, which for `.all` can
    /// walk every attempt the account has ever retained.
    @concurrent
    private nonisolated static func load(
        source: any UsageDashboardSource,
        from: Date?,
        to: Date,
        now: Date,
        calendar: Calendar,
        grace: TimeInterval
    ) async throws -> UsageDashboardLoad {
        // The cutoff gates the reads, so it is resolved before them rather than
        // beside them.
        let cutoff = await source.clearedThrough()

        async let liveAttemptsTask = source.liveAttemptIDs()
        async let liveThreadsTask = source.liveConversationIDs()
        let records = try await source.attempts(from: from, to: to, clearedThrough: cutoff)
        let measured = try? await source.measurementStart(clearedThrough: cutoff)
        let liveAttempts = await liveAttemptsTask
        let liveThreads = await liveThreadsTask

        // `.all` has no fetched lower bound, so its chart spans from the first
        // thing ever measured — or, when nothing was, a single day, which draws
        // as one empty bar rather than an axis with no extent.
        let bucketStart = from ?? measured ?? now
        let chartRange = min(bucketStart, now)...now

        let summary = GatewayUsageAggregator.summarize(
            attempts: records,
            liveAttemptIDs: liveAttempts,
            now: now,
            activityRange: chartRange,
            calendar: calendar,
            grace: grace
        )

        return UsageDashboardLoad(
            records: records,
            summary: summary,
            measurementStart: measured,
            liveAttemptIDs: liveAttempts,
            liveConversationIDs: liveThreads,
            clearedThrough: cutoff,
            chartRange: chartRange
        )
    }

    private func publish(_ loaded: UsageDashboardLoad, window: (from: Date?, to: Date), now: Date) {
        measurementStart = loaded.measurementStart
        clearedThrough = loaded.clearedThrough
        liveAttemptIDs = loaded.liveAttemptIDs
        liveConversationIDs = loaded.liveConversationIDs
        records = loaded.records
        rangeStart = window.from
        rangeEnd = now
        chartRange = loaded.chartRange
        summary = loaded.summary
        hasAnyRecordedAttempts = loaded.measurementStart != nil || loaded.summary.recordedAttempts > 0
        drillDownCache.removeAll(keepingCapacity: true)

        if let cutoff = loaded.clearedThrough {
            scheduleConvergencePurge(through: cutoff)
        }
    }

    // MARK: - Drill-downs

    /// The range's records narrowed to one gateway slot, summarized under the
    /// same rules as the whole. Filtering and re-summarizing is deliberate:
    /// there is one aggregator and one set of denominators, and a per-group
    /// code path would be a second definition of "success rate" to keep honest.
    func summary(forGateway ref: String?) -> GatewayUsageSummary {
        cachedSummary(for: .gateway(ref)) { $0.gatewayRef == ref }
    }

    func summary(forDevice bucket: UsageDeviceBucket) -> GatewayUsageSummary {
        cachedSummary(for: .device(bucket)) { UsageDeviceBucket.from(record: $0) == bucket }
    }

    /// Memoized per route for the life of one published range. Called from
    /// `body`, so the cache write must stay unobserved.
    private func cachedSummary(
        for route: UsageRoute,
        matching predicate: (GatewayAttemptRecord) -> Bool
    ) -> GatewayUsageSummary {
        // READ THE OBSERVED SOURCE BEFORE THE CACHE LOOKUP. A pushed drill-down
        // that hits the cache would otherwise touch no observed property at all
        // during its body, register no dependency on `records`, and stop
        // redrawing — leaving a screen frozen on a window the overview has
        // already left. The lookup itself is unobserved, so nothing else here
        // establishes it.
        let source = records
        if let cached = drillDownCache[route] { return cached }
        let subset = source.filter(predicate)
        let value = GatewayUsageAggregator.summarize(
            attempts: subset,
            liveAttemptIDs: liveAttemptIDs,
            now: rangeEnd ?? clock(),
            activityRange: chartRange,
            calendar: calendar,
            grace: grace
        )
        drillDownCache[route] = value
        return value
    }

    #if DEBUG
    /// Test-only window on the drill-down memoization. A cache HIT and a cache
    /// MISS return the same value, so "cached per selection, and dropped on
    /// every publish" is unobservable from the outside — and the second half of
    /// that is the load-bearing one: a surviving entry would draw a drill-down
    /// from a window the overview has already left. Nothing in the app reads
    /// this.
    var debugCachedDrillDownRoutes: Set<UsageRoute> { Set(drillDownCache.keys) }
    #endif

    /// Whether a ranked thread can still be opened. False means the parent is
    /// absent — deleted, not yet imported, or temporarily unavailable — which
    /// is why the row says unavailable rather than deleted.
    func canOpenConversation(_ id: UUID) -> Bool {
        liveConversationIDs.contains(id)
    }

    /// Leaves Settings for the thread. The hosts already close Settings on this
    /// notification, so nothing here dismisses anything itself.
    func openConversation(_ id: UUID) {
        NotificationCenter.default.post(
            name: .openConversationDeepLink,
            object: nil,
            userInfo: [NotificationDeepLink.conversationIDKey: id.uuidString]
        )
    }

    // MARK: - Clearing

    /// Clear usage history, account-wide. The cutoff moves FIRST — that is what
    /// every device honours, including one that is offline right now — and the
    /// local purge follows. A purge that throws leaves correct numbers behind
    /// it: the rows are already excluded, and the next load finishes the
    /// deletion.
    func clearUsageHistory() async {
        guard !isClearingUsageHistory else { return }
        isClearingUsageHistory = true
        clearUsageHistoryError = nil

        let cutoff = await source.advanceClearedThrough(to: clock())
        clearedThrough = cutoff
        // Claim the cutoff so the convergence pass does not fire for it again
        // after this reload publishes. A convergence pass still running under an
        // OLDER cutoff is harmless — it deletes a subset of what this one does,
        // and the primitive is idempotent.
        purgedCutoff = cutoff

        do {
            _ = try await source.purgeAttempts(through: cutoff)
        } catch {
            clearUsageHistoryError = String(
                localized: "settings.usage.error.clear",
                defaultValue: "Couldn't remove every record. Conduck will finish next time you open this screen."
            )
            // Let the next load retry the deletion rather than stranding it.
            purgedCutoff = nil
        }

        isClearingUsageHistory = false
        // One reload — the purge's own change post coalesces into this.
        scheduleReload()
    }

    /// Opportunistic, fail-open convergence: a cutoff this device has not
    /// purged under yet means another device cleared and the rows are still
    /// sitting here, excluded but stored. Detached from the load so a slow
    /// purge never delays the numbers, and silent on failure because the
    /// exclusion already made the screen correct.
    private func scheduleConvergencePurge(through cutoff: Date) {
        guard !isClearingUsageHistory, !isConvergencePurging, purgedCutoff != cutoff else { return }
        purgedCutoff = cutoff
        isConvergencePurging = true
        Task { [weak self, source] in
            _ = try? await source.purgeAttempts(through: cutoff)
            self?.isConvergencePurging = false
        }
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
