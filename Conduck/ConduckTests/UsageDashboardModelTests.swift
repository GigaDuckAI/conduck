// SPDX-License-Identifier: Apache-2.0

// Conduck
// UsageDashboardModelTests.swift
//
// Coverage for the screen model that sits between the attempt ledger and the
// usage dashboard: what it publishes, what it refuses to publish, and the
// ORDER it does things in. The aggregator's arithmetic is locked next door in
// `GatewayUsageAggregatorTests`; nothing here re-derives a rate. What is
// locked here is the choreography, and every case below is a bug that would
// otherwise ship looking like a rendering glitch:
//
//   1. NO FLASH OF EMPTY. Aggregation runs off the main actor, so there is a
//      real window between "a load started" and "a summary exists". The
//      previous summary has to survive it — a dashboard that blanks itself on
//      every range change or CloudKit import reads as data loss.
//   2. THE NEWEST SELECTION WINS. A slow `.all` pass and a fast `.week` pass
//      can be in flight together (the first load runs outside the coalescing
//      task, so a range change genuinely races it). The stale one must publish
//      NOTHING, whichever finishes last.
//   3. THE CLEAR CUTOFF REACHES EVERY READ. Exclusion, not deletion, is what
//      makes the numbers correct the instant another device's clear syncs in,
//      and the boundary is exact: a row stamped AT the cutoff is cleared.
//   4. CUTOFF FIRST, PURGE SECOND, ONE RELOAD. That order is what makes Clear
//      account-wide; reversing it would leave a window where the rows are gone
//      locally but no other device has been told anything.
//   5. NAVIGATION IS GATED ON LIVE CONVERSATIONS AND NOTHING ELSE — absence
//      never removes a row from a count, it only takes the chevron away.
//
// Every case drives an injected `UsageDashboardSource` fake, an injected clock
// and a UTC calendar, exactly as the model's `DiagnosticsRunner`-style seam
// intends: no Core Data, no settings, no notifications from the store, and no
// dependence on when or where the suite runs.
//
// WAITS ARE MONOTONIC-CLOCK POLLS, NEVER `Task.yield` BUDGETS. The work being
// waited on hops to the generic executor and back, and a yield budget can drain
// without that hop ever being scheduled.

import XCTest

@testable import Conduck

@MainActor
final class UsageDashboardModelTests: XCTestCase {

    // MARK: - Scaffolding

    /// Fixed instant. Every window the model computes is derived from it, so
    /// the fixtures below can name exact offsets.
    private let now = Date(timeIntervalSince1970: 1_760_000_000)

    /// UTC gregorian — the range windows start at a START OF DAY, which moves
    /// with the runner's zone unless it is pinned.
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()

    private func makeModel(_ source: FakeUsageDashboardSource) -> UsageDashboardModel {
        let now = self.now
        return UsageDashboardModel(
            source: source,
            clock: { now },
            calendar: calendar
        )
    }

    /// One ledger row. Defaults to a succeeded attempt a minute old on
    /// `openclaw`; every case names only the fields it is actually about.
    private func attempt(
        id: UUID = UUID(),
        conversation: UUID? = UUID(),
        turn: UUID? = UUID(),
        gateway: String? = "openclaw",
        startedAt: Date? = nil,
        outcome: GatewayAttemptOutcome = .succeeded,
        origin: GatewayAttemptOrigin = .app,
        deviceClass: String? = nil,
        fallbackSourceDevice: String? = nil
    ) -> GatewayAttemptRecord {
        let started = startedAt ?? now.addingTimeInterval(-60)
        return GatewayAttemptRecord(
            id: id,
            conversationID: conversation,
            userMessageID: turn,
            gatewayRef: gateway,
            startedAt: started,
            completedAt: started.addingTimeInterval(2),
            outcome: outcome,
            origin: origin,
            originDeviceClass: deviceClass,
            fallbackSourceDevice: fallbackSourceDevice
        )
    }

    /// Suspends until `condition()` holds, failing by name rather than letting
    /// the caller's assertion report an expiry as a logic bug.
    ///
    /// `Task.sleep` on a monotonic `ContinuousClock`, not a `Task.yield()`
    /// budget: what is being waited on runs on the generic executor after a
    /// `@concurrent` hop, and a yield budget can drain in microseconds without
    /// that hop ever being scheduled.
    private func waitUntil(
        _ what: String,
        timeout: Duration = .seconds(10),
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: () -> Bool
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline, !Task.isCancelled {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(2))
        }
        XCTFail("timed out after \(timeout) waiting for \(what)", file: file, line: line)
    }

    /// Lets any already-scheduled work run, then returns — for the assertions
    /// that something did NOT happen. Monotonic sleep, same reason as above.
    private func settle(_ duration: Duration = .milliseconds(200)) async {
        try? await Task.sleep(for: duration)
    }

    // MARK: - 1. Loading state, and the empty flash that must never happen

    /// The whole load choreography in one case, because the property is about
    /// the TRANSITIONS and not any single value: empty before `start()`,
    /// loading-but-not-loaded during the first fetch, and — the part that
    /// regressed screens before — the PREVIOUS summary still standing during
    /// every fetch after it.
    func testLoadPublishesASummaryAndNeverFlashesEmptyMidFlight() async {
        let source = FakeUsageDashboardSource()
        source.rows = [attempt(), attempt(), attempt()]
        let firstFetch = Gate()
        let secondFetch = Gate()
        source.onAttempts { call in
            if call == 1 { await firstFetch.wait() }
            if call == 2 { await secondFetch.wait() }
        }
        let model = makeModel(source)

        XCTAssertTrue(model.summary.isEmpty, "Nothing is published before start().")
        XCTAssertFalse(model.hasLoaded, "The empty state must not be claimed before a load ran.")
        XCTAssertFalse(model.isLoading)

        let started = Task { await model.start() }
        await waitUntil("the first fetch to reach the source") { source.attemptsCallCount == 1 }

        XCTAssertTrue(model.isLoading, "The loading flag is raised BEFORE the off-actor hop.")
        XCTAssertFalse(
            model.hasLoaded,
            "`hasLoaded` gates the empty-state card and must stay false until a summary exists.")

        firstFetch.open()
        await started.value

        XCTAssertTrue(model.hasLoaded)
        XCTAssertFalse(model.isLoading)
        XCTAssertNil(model.loadError)
        XCTAssertEqual(model.summary.recordedAttempts, 3)
        XCTAssertEqual(model.records.count, 3)
        XCTAssertTrue(model.hasAnyRecordedAttempts)

        // The regression this case exists for: a second load must not blank the
        // screen while it walks the ledger.
        source.rows = [attempt()]
        model.refresh()
        await waitUntil("the second fetch to reach the source") { source.attemptsCallCount == 2 }

        XCTAssertTrue(model.isLoading, "A refresh raises the flag again.")
        XCTAssertTrue(model.hasLoaded, "`hasLoaded` never regresses once a load has landed.")
        XCTAssertFalse(
            model.summary.isEmpty,
            "The previous summary must survive the fetch+summarize hop — blanking it flashes the "
                + "empty state on every range change and every CloudKit import.")
        XCTAssertEqual(model.summary.recordedAttempts, 3, "Still the PREVIOUS load's numbers.")
        XCTAssertEqual(model.records.count, 3, "The drill-downs' raw records survive too.")

        secondFetch.open()
        await waitUntil("the second load to publish") { model.summary.recordedAttempts == 1 }
        XCTAssertEqual(model.records.count, 1)
        XCTAssertFalse(model.isLoading)
    }

    // MARK: - 2. The generation guard

    /// Races a slow `.month` load against a fast `.week` one, in the exact
    /// shape production produces it: `start()`'s load runs OUTSIDE the
    /// coalescing task, so a range change while it is in flight starts a second
    /// load concurrently rather than queueing behind it.
    ///
    /// The stale load finishes LAST here, which is the only ordering that can
    /// actually overwrite the user's newer selection.
    func testAStaleInFlightLoadCannotOverwriteANewerRangeSelection() async {
        let source = FakeUsageDashboardSource()
        let oldRow = attempt(startedAt: now.addingTimeInterval(-10 * 86_400))
        let recentRow = attempt(startedAt: now.addingTimeInterval(-86_400))
        source.rows = [oldRow, recentRow]

        let monthFetch = Gate()
        source.onAttempts { call in
            // Only the FIRST fetch — the `.month` one — is held.
            if call == 1 { await monthFetch.wait() }
        }
        let model = makeModel(source)
        XCTAssertEqual(model.range, .month, "The default range this case races against.")

        let firstLoad = Task { await model.start() }
        await waitUntil("the .month fetch to reach the source") { source.attemptsCallCount == 1 }

        model.range = .week
        await waitUntil("the .week fetch to reach the source") { source.attemptsCallCount == 2 }
        await waitUntil("the .week load to publish") { model.hasLoaded }

        XCTAssertEqual(
            model.records.map(\.id), [recentRow.id],
            "The 7-day window excludes the 10-day-old row.")

        // Now let the stale pass finish. It carries a full month of rows and an
        // older generation, and it must publish nothing at all.
        monthFetch.open()
        await firstLoad.value
        await settle()

        XCTAssertEqual(model.range, .week)
        XCTAssertEqual(
            model.records.map(\.id), [recentRow.id],
            "A load whose generation was superseded must not republish — otherwise a slow .all "
                + "pass overwrites the 7-day numbers the user is already looking at.")
        XCTAssertEqual(model.summary.recordedAttempts, 1)
        XCTAssertEqual(
            model.rangeStart,
            UsageDashboardModel.window(for: .week, now: now, calendar: calendar).from,
            "The published window has to describe the range the summary was computed for.")
        XCTAssertFalse(model.isLoading, "The newest load lowered the flag; the stale one left it.")
    }

    // MARK: - 3. The clear cutoff

    /// The cutoff has to reach BOTH reads — the attempts fetch and the
    /// "measuring since" probe — or the caption names a date the totals no
    /// longer count. The boundary is asserted exactly: at the cutoff is
    /// cleared, one second past it is not.
    func testClearedThroughIsAppliedToEveryReadWithAnExactBoundary() async {
        let cutoff = now.addingTimeInterval(-3_600)
        let source = FakeUsageDashboardSource()
        let beforeCutoff = attempt(startedAt: cutoff.addingTimeInterval(-1))
        let atCutoff = attempt(startedAt: cutoff)
        let justAfterCutoff = attempt(startedAt: cutoff.addingTimeInterval(1))
        let recent = attempt(startedAt: now.addingTimeInterval(-60))
        source.rows = [beforeCutoff, atCutoff, justAfterCutoff, recent]
        source.cutoff = cutoff

        let model = makeModel(source)
        await model.start()

        XCTAssertEqual(
            model.records.map(\.id), [justAfterCutoff.id, recent.id],
            "Rows at or before the cutoff are excluded; the boundary instant itself is CLEARED, "
                + "matching the store predicate the purge deletes on.")
        XCTAssertEqual(model.summary.recordedAttempts, 2)
        XCTAssertEqual(model.clearedThrough, cutoff, "The cutoff in force is published for the UI.")
        XCTAssertEqual(
            model.measurementStart, justAfterCutoff.startedAt,
            "\"Measuring since\" is the earliest VISIBLE row, not the earliest stored one.")

        XCTAssertEqual(
            source.attemptsCalls.map(\.clearedThrough), [cutoff],
            "The attempts read must carry the cutoff.")
        XCTAssertEqual(
            source.measurementStartCalls, [cutoff],
            "The measurement-start read must carry the same cutoff — a caption computed without "
                + "it would name a date the totals exclude.")
    }

    // MARK: - 4. Clearing

    /// The ordering contract, asserted as an ordering and not as an end state:
    /// the cutoff moves FIRST (that is what other devices honour), the purge
    /// follows, the progress flag is up for the whole of it, and exactly ONE
    /// reload lands afterwards.
    func testClearUsageHistoryAdvancesTheCutoffBeforePurgingThenReloadsOnce() async {
        let source = FakeUsageDashboardSource()
        source.rows = [attempt(), attempt()]
        let model = makeModel(source)
        await model.start()
        XCTAssertEqual(model.summary.recordedAttempts, 2)
        let loadsBeforeClear = source.attemptsCallCount

        let clearingWhilePurging = FlagBox()
        source.onPurge { _ in
            let live = await MainActor.run { model.isClearingUsageHistory }
            clearingWhilePurging.value = live
        }

        await model.clearUsageHistory()

        XCTAssertTrue(
            clearingWhilePurging.value,
            "The destructive row disables itself on this flag — it must be up while the purge runs.")
        XCTAssertFalse(model.isClearingUsageHistory, "And down again once the purge returns.")
        XCTAssertNil(model.clearUsageHistoryError)
        XCTAssertEqual(model.clearedThrough, now)

        let advanceIndex = source.events.firstIndex(of: .advance(to: now))
        let purgeIndex = source.events.firstIndex(of: .purge(through: now))
        XCTAssertNotNil(advanceIndex, "The cutoff must be advanced.")
        XCTAssertNotNil(purgeIndex, "And the rows purged.")
        if let advanceIndex, let purgeIndex {
            XCTAssertLessThan(
                advanceIndex, purgeIndex,
                "Cutoff FIRST, delete SECOND. Reversed, a device that was offline during the clear "
                    + "would never learn the rows were cleared at all.")
        }

        await waitUntil("the post-clear reload") { source.attemptsCallCount == loadsBeforeClear + 1 }
        await settle()
        XCTAssertEqual(
            source.attemptsCallCount, loadsBeforeClear + 1,
            "ONE reload after a clear — the purge's own change post coalesces into it.")
        XCTAssertEqual(
            source.attemptsCalls.last?.clearedThrough, now,
            "The reload reads under the new cutoff.")
        XCTAssertEqual(
            source.purgeCutoffs, [now],
            "The clear claims its own cutoff, so the convergence pass must not fire for it again.")
        XCTAssertEqual(model.summary.recordedAttempts, 0, "Everything was at or before the cutoff.")
    }

    /// A clear publishes what settings actually KEPT, not what it asked for.
    /// The merge rule is max, so a device carrying a newer cutoff stays on it —
    /// and the screen has to show that one or its numbers and its caption
    /// disagree.
    func testClearUsageHistoryPublishesTheCutoffSettingsActuallyKept() async {
        let newerCutoff = now.addingTimeInterval(3_600)
        let source = FakeUsageDashboardSource()
        source.cutoff = newerCutoff
        source.rows = [attempt()]
        let model = makeModel(source)
        await model.start()

        await model.clearUsageHistory()

        XCTAssertEqual(
            model.clearedThrough, newerCutoff,
            "The cutoff never regresses, and the model publishes the value that took effect.")
        XCTAssertEqual(source.purgeCutoffs, [newerCutoff], "The purge runs under the kept cutoff.")
    }

    /// A purge that throws leaves CORRECT numbers behind it — the rows are
    /// already excluded — and must hand the unfinished deletion to the next
    /// load rather than stranding it.
    func testAFailedPurgeReportsItselfAndLetsTheNextLoadFinishTheDeletion() async {
        let source = FakeUsageDashboardSource()
        source.rows = [attempt()]
        source.purgeFailure = TestPurgeError.failed
        let model = makeModel(source)
        await model.start()

        await model.clearUsageHistory()

        XCTAssertFalse(model.isClearingUsageHistory)
        XCTAssertNotNil(
            model.clearUsageHistoryError,
            "A failed deletion is reported — silently is the one way it may not fail.")
        XCTAssertEqual(model.clearedThrough, now, "The cutoff moved regardless, so reads are right.")

        await waitUntil("the purge to be retried by the next load's convergence pass") {
            source.purgeCutoffs.count == 2
        }
        XCTAssertEqual(
            source.purgeCutoffs, [now, now],
            "The failed clear released its claim on the cutoff so the next load retries it.")
    }

    /// A cutoff this device has not purged under yet means ANOTHER device
    /// cleared. The convergence pass runs once for it and then stops: the purge
    /// posts its own change notification, and a pass that re-fired on every
    /// publish would be an endless reload → purge → reload loop.
    func testTheConvergencePurgeFiresOncePerCutoffAndNotOnEveryLoad() async {
        let cutoff = now.addingTimeInterval(-7_200)
        let source = FakeUsageDashboardSource()
        source.cutoff = cutoff
        source.rows = [attempt(startedAt: now.addingTimeInterval(-60))]
        let model = makeModel(source)

        await model.start()
        await waitUntil("the convergence purge") { source.purgeCutoffs == [cutoff] }

        model.refresh()
        await waitUntil("the second load") { source.attemptsCallCount == 2 }
        await settle()

        XCTAssertEqual(
            source.purgeCutoffs, [cutoff],
            "One purge per cutoff. Re-firing it on every publish would loop against the purge's "
                + "own change post.")
    }

    // MARK: - 5. Thread navigation

    /// Liveness gates the CHEVRON and nothing else: an absent conversation
    /// still counts, it just cannot be opened — which is why the row says
    /// unavailable rather than deleted.
    func testLiveConversationIDsGateThreadNavigationWithoutGatingTheCounts() async {
        let liveThread = UUID()
        let absentThread = UUID()
        let source = FakeUsageDashboardSource()
        source.rows = [
            attempt(conversation: liveThread),
            attempt(conversation: absentThread)
        ]
        source.liveThreads = [liveThread]

        let model = makeModel(source)
        await model.start()

        XCTAssertEqual(model.liveConversationIDs, [liveThread])
        XCTAssertTrue(model.canOpenConversation(liveThread))
        XCTAssertFalse(
            model.canOpenConversation(absentThread),
            "Deleted, not yet imported or temporarily unavailable — all three read as no chevron.")
        XCTAssertEqual(
            model.summary.recordedAttempts, 2,
            "Liveness never removes a row from a count.")
        XCTAssertEqual(
            model.summary.threadsWithUsage, 2,
            "Usage outlives the thread it describes.")
    }

    // MARK: - 6. Drill-downs

    /// Both filters, over one fixture built so a wrong predicate cannot pass:
    /// the nil-gateway rows are their own group rather than an absence to drop,
    /// and the CarPlay row stamps `iphone` as its device class, so a filter
    /// reading the class instead of the bucket derivation lands it in the wrong
    /// group.
    func testGatewayAndDeviceSummariesFilterTheRangeRecords() async {
        let source = FakeUsageDashboardSource()
        source.rows = [
            attempt(gateway: "openclaw", deviceClass: "mac"),
            attempt(gateway: "openclaw", deviceClass: "iphone"),
            attempt(gateway: "hermes", deviceClass: "iphone"),
            attempt(gateway: "hermes", origin: .carPlay, deviceClass: "iphone"),
            attempt(gateway: nil, fallbackSourceDevice: "ipad-voice")
        ]
        let model = makeModel(source)
        await model.start()
        XCTAssertEqual(model.summary.recordedAttempts, 5)

        XCTAssertEqual(model.summary(forGateway: "openclaw").recordedAttempts, 2)
        XCTAssertEqual(model.summary(forGateway: "hermes").recordedAttempts, 2)
        XCTAssertEqual(
            model.summary(forGateway: nil).recordedAttempts, 1,
            "Attempts that recorded no gateway are a real group, not an absence to drop.")
        XCTAssertEqual(
            model.summary(forGateway: "openrouter").recordedAttempts, 0,
            "A gateway with nothing in range summarizes to zero, not to everything.")

        XCTAssertEqual(model.summary(forDevice: .mac).recordedAttempts, 1)
        XCTAssertEqual(
            model.summary(forDevice: .iphone).recordedAttempts, 2,
            "Two rows stamped `iphone` — the THIRD one also stamps `iphone` but ran from CarPlay, "
                + "and a derivation reading the class alone would land it here.")
        XCTAssertEqual(
            model.summary(forDevice: .carPlay).recordedAttempts, 1,
            "The surface wins over the hardware class for the dedicated buckets.")
        XCTAssertEqual(
            model.summary(forDevice: .ipad).recordedAttempts, 1,
            "A row with no stamped class falls back to the parent turn's own tag.")
        XCTAssertEqual(model.summary(forDevice: .watch).recordedAttempts, 0)
        XCTAssertEqual(model.summary(forDevice: .unknown).recordedAttempts, 0)

        let bucketed = UsageDeviceBucket.allCases
            .map { model.summary(forDevice: $0).recordedAttempts }
            .reduce(0, +)
        XCTAssertEqual(
            bucketed, model.summary.recordedAttempts,
            "Every row lands in exactly one bucket — a partition, not a filter.")
    }

    /// The memoization is invisible from the outside by design (a hit and a
    /// miss return the same value), so the keys are inspected directly. What
    /// matters is the INVALIDATION: a cached route surviving a publish would
    /// render a drill-down from a window the overview has already left.
    func testDrillDownSummariesAreCachedPerRouteAndDroppedOnEveryPublish() async {
        let source = FakeUsageDashboardSource()
        source.rows = [attempt(gateway: "openclaw", deviceClass: "mac"), attempt(gateway: "openclaw")]
        let model = makeModel(source)
        await model.start()

        XCTAssertTrue(model.debugCachedDrillDownRoutes.isEmpty, "Nothing is summarized eagerly.")

        XCTAssertEqual(model.summary(forGateway: "openclaw").recordedAttempts, 2)
        XCTAssertEqual(
            model.debugCachedDrillDownRoutes, [.gateway("openclaw")],
            "One entry per selection, keyed by route.")
        XCTAssertEqual(
            model.summary(forGateway: "openclaw").recordedAttempts, 2,
            "A cache hit answers identically.")
        XCTAssertEqual(model.debugCachedDrillDownRoutes, [.gateway("openclaw")])

        XCTAssertEqual(model.summary(forDevice: .mac).recordedAttempts, 1)
        XCTAssertEqual(
            model.debugCachedDrillDownRoutes, [.gateway("openclaw"), .device(.mac)],
            "Routes are cached independently of one another.")

        source.rows = [attempt(gateway: "openclaw")]
        model.refresh()
        await waitUntil("the reload to publish") { model.summary.recordedAttempts == 1 }

        XCTAssertTrue(
            model.debugCachedDrillDownRoutes.isEmpty,
            "Every publish drops the cache — a stale entry would draw numbers from a window the "
                + "overview has already moved off.")
        XCTAssertEqual(
            model.summary(forGateway: "openclaw").recordedAttempts, 1,
            "And the re-derived value describes the NEW range.")
    }

    // MARK: - 7. Deep link

    /// The hosts already close Settings on this notification, so the model's
    /// whole job is posting it with the key they read.
    func testOpenConversationPostsTheDeepLinkCarryingTheConversationID() async {
        let source = FakeUsageDashboardSource()
        let model = makeModel(source)
        let conversationID = UUID()

        let posted = expectation(description: "openConversationDeepLink")
        let observer = NotificationCenter.default.addObserver(
            forName: .openConversationDeepLink,
            object: nil,
            queue: .main
        ) { note in
            XCTAssertEqual(
                note.userInfo?[NotificationDeepLink.conversationIDKey] as? String,
                conversationID.uuidString,
                "The hosts read the id as a UUID STRING under this exact key.")
            posted.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        model.openConversation(conversationID)

        await fulfillment(of: [posted], timeout: 5)
    }
}

// MARK: - Fakes

private enum TestPurgeError: Error {
    case failed
}

/// A `Bool` a nonisolated hook can hand back to the test body.
private final class FlagBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false

    var value: Bool {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}

/// A one-shot suspension the test opens by hand, so a load can be held exactly
/// where the model hops off the main actor. Opening before anyone waits is
/// fine — a later `wait()` returns immediately.
private final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        lock.lock()
        if isOpen {
            lock.unlock()
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            waiters.append(continuation)
            lock.unlock()
        }
    }

    func open() {
        lock.lock()
        isOpen = true
        let pending = waiters
        waiters = []
        lock.unlock()
        for continuation in pending { continuation.resume() }
    }
}

/// The ledger, the synced cutoff and this device's live-task probes, as one
/// scriptable fake. Lock-guarded rather than an actor so the test body can read
/// what happened synchronously between `await`s.
///
/// The read filters mirror the STORE's own predicates — bounded ranges exclude
/// an undated row, and the cutoff excludes rows at or before it — so the model
/// cases above exercise the real boundary rather than a convenient one.
private final class FakeUsageDashboardSource: UsageDashboardSource, @unchecked Sendable {

    enum Event: Equatable {
        case readCutoff
        case attempts(from: Date?, to: Date?, clearedThrough: Date?)
        case measurementStart(clearedThrough: Date?)
        case liveAttemptIDs
        case liveConversationIDs
        case advance(to: Date)
        case purge(through: Date)
    }

    private let lock = NSLock()
    private var storedRows: [GatewayAttemptRecord] = []
    private var storedCutoff: Date?
    private var storedLiveThreads: Set<UUID> = []
    private var storedLiveAttempts: Set<UUID> = []
    private var storedEvents: [Event] = []
    private var storedPurgeFailure: Error?
    private var attemptsHook: (@Sendable (Int) async -> Void)?
    private var purgeHook: (@Sendable (Date) async -> Void)?
    private var attempts = 0

    // MARK: Scripting

    var rows: [GatewayAttemptRecord] {
        get { lock.lock(); defer { lock.unlock() }; return storedRows }
        set { lock.lock(); storedRows = newValue; lock.unlock() }
    }

    var cutoff: Date? {
        get { lock.lock(); defer { lock.unlock() }; return storedCutoff }
        set { lock.lock(); storedCutoff = newValue; lock.unlock() }
    }

    var liveThreads: Set<UUID> {
        get { lock.lock(); defer { lock.unlock() }; return storedLiveThreads }
        set { lock.lock(); storedLiveThreads = newValue; lock.unlock() }
    }

    var liveAttempts: Set<UUID> {
        get { lock.lock(); defer { lock.unlock() }; return storedLiveAttempts }
        set { lock.lock(); storedLiveAttempts = newValue; lock.unlock() }
    }

    var purgeFailure: Error? {
        get { lock.lock(); defer { lock.unlock() }; return storedPurgeFailure }
        set { lock.lock(); storedPurgeFailure = newValue; lock.unlock() }
    }

    /// Runs inside `attempts`, with the 1-based call index — the seam the race
    /// cases hold one specific load open at.
    func onAttempts(_ hook: @escaping @Sendable (Int) async -> Void) {
        lock.lock()
        attemptsHook = hook
        lock.unlock()
    }

    /// Runs inside `purgeAttempts`, before it decides anything — where the
    /// clear-progress flag is sampled.
    func onPurge(_ hook: @escaping @Sendable (Date) async -> Void) {
        lock.lock()
        purgeHook = hook
        lock.unlock()
    }

    // MARK: Observations

    var events: [Event] {
        lock.lock(); defer { lock.unlock() }
        return storedEvents
    }

    var attemptsCallCount: Int {
        lock.lock(); defer { lock.unlock() }
        return attempts
    }

    var attemptsCalls: [(from: Date?, to: Date?, clearedThrough: Date?)] {
        events.compactMap {
            if case let .attempts(from, to, clearedThrough) = $0 {
                return (from, to, clearedThrough)
            }
            return nil
        }
    }

    var measurementStartCalls: [Date?] {
        events.compactMap {
            if case let .measurementStart(clearedThrough) = $0 { return clearedThrough }
            return nil
        }
    }

    var purgeCutoffs: [Date] {
        events.compactMap {
            if case let .purge(cutoff) = $0 { return cutoff }
            return nil
        }
    }

    // MARK: UsageDashboardSource

    func attempts(from: Date?, to: Date?, clearedThrough: Date?) async throws
        -> [GatewayAttemptRecord]
    {
        lock.lock()
        attempts += 1
        let call = attempts
        storedEvents.append(.attempts(from: from, to: to, clearedThrough: clearedThrough))
        let hook = attemptsHook
        lock.unlock()

        if let hook { await hook(call) }

        return visibleRows(from: from, to: to, clearedThrough: clearedThrough)
            .sorted { ($0.startedAt ?? .distantPast) < ($1.startedAt ?? .distantPast) }
    }

    func measurementStart(clearedThrough: Date?) async throws -> Date? {
        lock.lock()
        storedEvents.append(.measurementStart(clearedThrough: clearedThrough))
        lock.unlock()
        return visibleRows(from: nil, to: nil, clearedThrough: clearedThrough)
            .compactMap(\.startedAt)
            .min()
    }

    func liveAttemptIDs() async -> Set<UUID> {
        lock.lock(); defer { lock.unlock() }
        storedEvents.append(.liveAttemptIDs)
        return storedLiveAttempts
    }

    func liveConversationIDs() async -> Set<UUID> {
        lock.lock(); defer { lock.unlock() }
        storedEvents.append(.liveConversationIDs)
        return storedLiveThreads
    }

    func clearedThrough() async -> Date? {
        lock.lock(); defer { lock.unlock() }
        storedEvents.append(.readCutoff)
        return storedCutoff
    }

    /// Merge rule is max — a device holding a newer cutoff keeps it, and the
    /// value that took effect is what comes back.
    func advanceClearedThrough(to date: Date) async -> Date {
        lock.lock(); defer { lock.unlock() }
        storedEvents.append(.advance(to: date))
        let kept = max(storedCutoff ?? date, date)
        storedCutoff = kept
        return kept
    }

    func purgeAttempts(through cutoff: Date) async throws -> Int {
        lock.lock()
        storedEvents.append(.purge(through: cutoff))
        let hook = purgeHook
        lock.unlock()

        if let hook { await hook(cutoff) }

        lock.lock()
        if let failure = storedPurgeFailure {
            lock.unlock()
            throw failure
        }
        let kept = storedRows.filter { row in
            guard let started = row.startedAt else { return false }
            return started > cutoff
        }
        let removed = storedRows.count - kept.count
        storedRows = kept
        lock.unlock()
        return removed
    }

    // MARK: Store-shaped filtering

    /// An undated row is outside every bounded range (a nil column fails both
    /// comparisons in Core Data) and inside the clear cutoff (it cannot claim
    /// to have happened after one) — the same set the purge deletes.
    private func visibleRows(from: Date?, to: Date?, clearedThrough: Date?)
        -> [GatewayAttemptRecord]
    {
        lock.lock(); defer { lock.unlock() }
        return storedRows.filter { row in
            guard let started = row.startedAt else {
                return from == nil && to == nil && clearedThrough == nil
            }
            if let from, started < from { return false }
            if let to, started > to { return false }
            if let clearedThrough, started <= clearedThrough { return false }
            return true
        }
    }
}
