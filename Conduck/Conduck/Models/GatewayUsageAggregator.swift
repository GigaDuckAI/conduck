// SPDX-License-Identifier: Apache-2.0

// Conduck
// GatewayUsageAggregator.swift
//
// The read half of the gateway-attempt ledger: everything the usage dashboard
// draws, derived in one pass over `[GatewayAttemptRecord]`. PURE — static
// functions over injected inputs, with `now`, the grace window and the calendar
// all passed in, so every number here is reproducible from a fixture and none
// of it depends on when the test happens to run.
//
// NOTHING IN THIS FILE WRITES, and that is the point rather than an accident of
// where the code sits. An open row is not evidence a turn is running: attempts
// sync across the user's devices while `URLSession` registries are device-local,
// so this device's ignorance about another device's row is a fact about THIS
// device. `GatewayAttemptEffectiveOutcome` turns that ignorance into a display
// state on every query; persisting it would race — and could beat — the real
// success arriving from the device that owns the task.
//
// THREE DENOMINATORS, DELIBERATELY DIFFERENT, and mixing them is the failure
// mode this file is shaped to prevent:
//   - `resolvedAttemptSuccessRate` divides by succeeded + failed ONLY, so a
//     cancellation or an unclassifiable landing can never be quietly counted as
//     a failure, and an unconfirmed row can never make reliability look better
//     than it is by inflating the denominator's healthy half.
//   - Token coverage divides by attempts that reached a STORED terminal
//     outcome — succeeded, failed, cancelled and unclassifiable alike. The
//     question the denominator asks is whether the attempt ENDED, not whether
//     it ended well, so a cancellation belongs in it exactly as a failure does.
//     Only rows with no stored ending are excluded — live, pending and
//     unconfirmed — because those have not yet had their opportunity to
//     report; an unconfirmed row is missing evidence, not a gateway that
//     declined to report.
//   - Turn counts divide by DISTINCT `userMessageID`, so retries move the
//     attempt numbers and leave the activity numbers alone.
//
// EVERY RATE IS OPTIONAL AND NIL MEANS UNAVAILABLE. A zero denominator yields
// nil, never 0.0 and never a NaN — "no attempts resolved yet" and "nothing
// succeeded" are different claims and the dashboard has to be able to tell them
// apart. The same rule governs token sums: a field NOBODY reported sums to nil,
// while a field every gateway reported as zero sums to 0.
//
// CONTENT-FREE, AND THAT IS RELEASE-BLOCKING. The only strings that reach these
// types are `gatewayRef` (a `RemoteAgentRef.rawString` — the configured SLOT,
// never the endpoint behind it), the requested model, and the bounded wire
// strings `GatewayResponseMetadata` already scanned. No text, no URL, no host,
// no token, no provider error, no status code. Nothing here logs.

import Foundation

// MARK: - Aggregate value types

/// Every number the usage dashboard renders for one selected range, computed
/// once. Value type, `Equatable`, so a recompute that changes nothing can be
/// dropped rather than repainting the screen.
nonisolated struct GatewayUsageSummary: Sendable, Equatable {
    /// Attempts whose ledger insert SUCCEEDED and whose conversation is still
    /// retained. Never called "all dispatches": capture is fail-open, so a
    /// dispatch that could not be recorded still happened.
    let recordedAttempts: Int
    /// Distinct user turns with at least one recorded attempt. Retries do not
    /// move this.
    let attemptedTurns: Int
    /// Distinct user turns with at least one SUCCEEDED attempt.
    let completedTurns: Int
    /// Distinct user turns with more than one recorded attempt.
    let retriedTurns: Int
    /// `retriedTurns / attemptedTurns`, nil when no turn was attempted.
    let retryRate: Double?
    /// `completedTurns / attemptedTurns`, nil when no turn was attempted.
    let completedTurnRate: Double?
    /// `succeeded / (succeeded + failed)`. Cancellations, unclassifiable
    /// landings and every derived state stay OUT of this denominator; nil when
    /// nothing resolved into either half.
    let resolvedAttemptSuccessRate: Double?
    /// Attempts linked to completed turns / completed turns — how many tries a
    /// turn that eventually worked actually took. Nil when nothing completed.
    let attemptsPerCompletedTurn: Double?
    /// Distinct conversations with a recorded attempt in range. A
    /// MEASUREMENT-ERA count: a conversation whose turns all predate the ledger
    /// is retained history, not measured activity.
    let activeConversations: Int
    let outcomeMix: GatewayUsageOutcomeMix
    let tokens: GatewayUsageTokens
    let responseTime: GatewayUsageResponseTime
    /// Attempts whose gateway reported the reply was cut off at the length
    /// limit. Zero is a fine answer; it is not "unavailable".
    let truncatedReplies: Int
    /// One entry per day in the requested window, gaps filled with zeros, so a
    /// bar chart draws quiet days as quiet rather than closing the gap.
    let dailyActivity: [GatewayUsageDailyBucket]
    /// Per configured gateway SLOT, busiest first. Each carries its own
    /// per-model breakdown when more than one model was requested through it.
    let byGateway: [GatewayUsageGroup]
    /// Per requested model, across every gateway, busiest first.
    let byRequestedModel: [GatewayUsageGroup]

    /// Nothing recorded in this range. The dashboard's empty state asks a
    /// wider question (nothing recorded EVER) and reads its own flag.
    var isEmpty: Bool { recordedAttempts == 0 }

    static let empty = GatewayUsageSummary(
        recordedAttempts: 0,
        attemptedTurns: 0,
        completedTurns: 0,
        retriedTurns: 0,
        retryRate: nil,
        completedTurnRate: nil,
        resolvedAttemptSuccessRate: nil,
        attemptsPerCompletedTurn: nil,
        activeConversations: 0,
        outcomeMix: .empty,
        tokens: .empty,
        responseTime: .empty,
        truncatedReplies: 0,
        dailyActivity: [],
        byGateway: [],
        byRequestedModel: []
    )
}

/// The full effective-outcome distribution. Reported WHOLE — a high
/// `unconfirmed` count is exactly what stops a healthy-looking resolved success
/// rate from being read as the whole story.
nonisolated struct GatewayUsageOutcomeMix: Sendable, Equatable {
    /// Stored terminal outcomes.
    let succeeded: Int
    let failed: Int
    let cancelled: Int
    /// Stored `unknown`: an authoritative terminal callback that could not be
    /// classified. NOT the same as `unconfirmed` below.
    let unknown: Int
    /// Derived: this device holds a live task for the attempt.
    let inFlight: Int
    /// Derived: open, no local task, still inside the grace window.
    let pending: Int
    /// Derived: open, no local task, past the grace window. A statement about
    /// this device's evidence, never about the turn.
    let unconfirmed: Int

    /// Attempts that reached a stored terminal outcome — the token-coverage
    /// denominator, and the only rows anything here can claim to know about.
    var resolved: Int { succeeded + failed + cancelled + unknown }
    /// Attempts still running or unresolved from here.
    var open: Int { inFlight + pending + unconfirmed }
    var total: Int { resolved + open }

    static let empty = GatewayUsageOutcomeMix(
        succeeded: 0, failed: 0, cancelled: 0, unknown: 0,
        inFlight: 0, pending: 0, unconfirmed: 0
    )
}

/// One reported token field: what it sums to, and how much of the range
/// actually reported it. The two travel together because the sum alone is
/// misleading — 40,000 tokens over 12% of attempts is a different fact from
/// 40,000 over all of them.
nonisolated struct GatewayUsageTokenField: Sendable, Equatable {
    /// Nil when NO attempt in range reported this field. Zero means attempts
    /// reported it and it was zero. Never conflate the two.
    let sum: Int64?
    /// Terminal attempts carrying a value for this field.
    let reportingAttempts: Int
    /// Terminal attempts in range — the shared denominator.
    let coverageDenominator: Int

    /// Fraction of terminal attempts that reported this field, nil when nothing
    /// terminal is in range to have reported anything.
    var coverage: Double? {
        guard coverageDenominator > 0 else { return nil }
        return Double(reportingAttempts) / Double(coverageDenominator)
    }

    /// Whether the gateway told us anything at all about this field.
    var isReported: Bool { sum != nil }

    static let empty = GatewayUsageTokenField(
        sum: nil, reportingAttempts: 0, coverageDenominator: 0)
}

/// The three reported token fields, each summed and covered INDEPENDENTLY —
/// one generic coverage percentage would claim a completeness no gateway
/// promised.
nonisolated struct GatewayUsageTokens: Sendable, Equatable {
    let input: GatewayUsageTokenField
    let output: GatewayUsageTokenField
    /// `usage.total_tokens` exactly as reported, kept apart from any sum this
    /// client can compute. A gateway's inconsistent total is still its own
    /// statement about the turn.
    let reportedTotal: GatewayUsageTokenField

    /// Input + output, offered ONLY when no gateway-reported total exists and
    /// at least one component does. Label it "calculated known components"
    /// wherever it renders; it is not a gateway-reported total, it is never
    /// written back, and it silently omits whatever the gateway counted in its
    /// own total but reported in neither component.
    var calculatedKnownComponents: Int64? {
        guard reportedTotal.sum == nil else { return nil }
        guard input.sum != nil || output.sum != nil else { return nil }
        return GatewayUsageAggregator.saturatingSum(input.sum ?? 0, output.sum ?? 0)
    }

    /// No gateway in range reported any usage at all.
    var isEmpty: Bool {
        input.sum == nil && output.sum == nil && reportedTotal.sum == nil
    }

    static let empty = GatewayUsageTokens(input: .empty, output: .empty, reportedTotal: .empty)
}

/// Full-response time: dispatch to terminal callback. It is NOT model latency —
/// it contains OS scheduling, the network, the gateway's tool calls and however
/// many model calls the agent made on its way to a reply. The protocol is
/// non-streaming, so no earlier instant is observable.
nonisolated struct GatewayUsageResponseTime: Sendable, Equatable {
    /// Successful attempts with usable timing. Shown ALWAYS, beside every
    /// figure below, because a median over three samples is not a claim.
    let sampleCount: Int
    /// Type-7 median. Primary, because one 20-minute agent run drags a mean
    /// somewhere no turn actually landed.
    let median: TimeInterval?
    /// Type-7 p90, suppressed below `GatewayUsageAggregator.p90MinimumSamples`
    /// where the estimator is interpolating between the two slowest samples and
    /// would read as precision it does not have.
    let p90: TimeInterval?
    /// Secondary, and only ever secondary.
    let mean: TimeInterval?

    static let empty = GatewayUsageResponseTime(
        sampleCount: 0, median: nil, p90: nil, mean: nil)
}

/// One calendar day of activity. Attempts and turns are kept apart here for the
/// same reason they are everywhere else: three retries of one turn are one
/// turn's worth of activity and three attempts' worth of load.
nonisolated struct GatewayUsageDailyBucket: Sendable, Equatable, Identifiable {
    /// Start of day in the calendar the aggregation ran under.
    let day: Date
    let attempts: Int
    /// Distinct user turns attempted that day. A turn whose retries straddle
    /// midnight counts in both days; the range total counts it once.
    let turns: Int

    var id: Date { day }
}

/// A slice of the range — one gateway slot, or one requested model. Carries the
/// same shapes as the whole, so a card renders a group and the total with one
/// set of views.
nonisolated struct GatewayUsageGroup: Sendable, Equatable, Identifiable {
    /// A `RemoteAgentRef.rawString`, or a requested model string. Nil means the
    /// attempts did not record one — an older row, or a request that carried no
    /// model and let the gateway's own default answer. Resolve a ref to a
    /// display name at RENDER time; a stored name would be a stale copy of a
    /// setting the user can edit.
    let key: String?
    let attempts: Int
    let succeeded: Int
    let failed: Int
    /// Same denominator rule as the range total.
    let successRate: Double?
    let medianResponseTime: TimeInterval?
    /// Samples behind `medianResponseTime`.
    let responseSampleCount: Int
    let tokens: GatewayUsageTokens
    /// Per-requested-model breakdown WITHIN this gateway, populated only when
    /// more than one distinct model was requested through it — a single-model
    /// gateway's breakdown would just restate the row above it.
    let models: [GatewayUsageGroup]

    /// Stable identity that cannot collide with a real key: no `RemoteAgentRef`
    /// raw string and no model string can contain a control scalar (the wire
    /// strings are scanned for exactly that before they persist).
    var id: String { key ?? "\u{1}unattributed" }
}

// MARK: - Aggregator

/// Turns stored attempts into everything the dashboard draws. Every entry point
/// is static and side-effect free.
nonisolated enum GatewayUsageAggregator {
    /// Below this many samples a p90 is interpolating between the two slowest
    /// observations, so it is withheld rather than drawn as a number.
    static let p90MinimumSamples = 20

    /// The `finish_reason` that means the reply was cut off at the length limit
    /// — the one value with a user-visible consequence. Compared
    /// case-insensitively: gateways vary, and the point is the user's truncated
    /// reply, not a string match.
    static let truncatedFinishReason = "length"

    /// Hard ceiling on generated daily buckets, so a nonsense range — a device
    /// with a wildly wrong clock, a corrupt stored date — costs a bounded array
    /// instead of a hang.
    static let maxDailyBuckets = 3_660

    /// Everything for one range, in a single pass.
    ///
    /// - Parameters:
    ///   - attempts: Recorded attempts already filtered to the range by the
    ///     store fetch. Order is irrelevant.
    ///   - liveAttemptIDs: Attempt ids THIS device currently holds a live task
    ///     for. Local, process-visible evidence only; its absence never means
    ///     an attempt is dead.
    ///   - now: Evaluation instant, injected so derived states are reproducible.
    ///   - activityRange: The window the daily buckets should span, gaps
    ///     included. Nil spans first to last observed attempt day only.
    ///   - calendar: Day boundaries. The user's own calendar in production.
    ///   - grace: Both the derived-state window and the ceiling on believable
    ///     attempt timing. The shared stale-send grace, not a second constant.
    static func summarize(
        attempts: [GatewayAttemptRecord],
        liveAttemptIDs: Set<UUID>,
        now: Date,
        activityRange: ClosedRange<Date>? = nil,
        calendar: Calendar = .current,
        grace: TimeInterval = ConversationActivityResolver.staleSendingGrace
    ) -> GatewayUsageSummary {
        let items = attempts.map { record in
            Classified(record: record, liveAttemptIDs: liveAttemptIDs, now: now, grace: grace)
        }

        let turns = turnCounts(for: items)
        let mix = outcomeMix(for: items)

        return GatewayUsageSummary(
            recordedAttempts: items.count,
            attemptedTurns: turns.attempted,
            completedTurns: turns.completed,
            retriedTurns: turns.retried,
            retryRate: ratio(turns.retried, turns.attempted),
            completedTurnRate: ratio(turns.completed, turns.attempted),
            resolvedAttemptSuccessRate: ratio(mix.succeeded, mix.succeeded + mix.failed),
            attemptsPerCompletedTurn: ratio(turns.attemptsOnCompletedTurns, turns.completed),
            activeConversations: Set(items.compactMap { $0.record.conversationID }).count,
            outcomeMix: mix,
            tokens: tokens(for: items),
            responseTime: responseTime(for: items),
            truncatedReplies: items.count(where: { $0.isTruncated }),
            dailyActivity: dailyActivity(for: items, range: activityRange, calendar: calendar),
            byGateway: gatewayGroups(for: items),
            byRequestedModel: modelGroups(for: items)
        )
    }

    // MARK: - Quantiles

    /// Type-7 linear-interpolation quantile — the estimator R, NumPy and every
    /// spreadsheet default to, so a figure here matches one a user computes
    /// themselves. `h = (n - 1) * p`, then interpolate between the surrounding
    /// order statistics.
    ///
    /// `sorted` MUST already be ascending; sorting here would hide a caller
    /// that forgot and pay for it on every group.
    static func quantile(sorted: [Double], probability p: Double) -> Double? {
        guard !sorted.isEmpty else { return nil }
        guard sorted.count > 1 else { return sorted[0] }
        let clamped = min(max(p, 0), 1)
        let h = Double(sorted.count - 1) * clamped
        let lower = h.rounded(.down)
        let index = Int(lower)
        guard index + 1 < sorted.count else { return sorted[sorted.count - 1] }
        return sorted[index] + (h - lower) * (sorted[index + 1] - sorted[index])
    }

    // MARK: - Arithmetic helpers

    /// A rate, or nil when the denominator is empty. NEVER 0.0 for "no data" —
    /// a zero success rate and an unmeasured one are opposite claims.
    static func ratio(_ numerator: Int, _ denominator: Int) -> Double? {
        guard denominator > 0 else { return nil }
        return Double(numerator) / Double(denominator)
    }

    /// Token sums saturate rather than trap. Reaching `Int64.max` would take
    /// more tokens than the species has produced; the guard exists so a corrupt
    /// mirrored row cannot crash the dashboard.
    static func saturatingSum(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? (rhs < 0 ? Int64.min : Int64.max) : sum
    }

    // MARK: - One attempt, classified

    /// An attempt plus the two facts every aggregate needs from it: how it
    /// reads from here right now, and whether its timing can be believed.
    private struct Classified {
        let record: GatewayAttemptRecord
        let effective: GatewayAttemptEffectiveOutcome
        /// Elapsed seconds, present only when both stamps exist and the
        /// interval is inside `0...grace`.
        ///
        /// OUT-OF-RANGE TIMING IS REJECTED, NOT CLAMPED. A negative interval
        /// means the two stamps came from devices whose clocks disagree, and an
        /// interval past the grace means a background upload waited for
        /// connectivity far longer than the hop took. Clamping either would
        /// invent a sample at the boundary and drag the median toward it;
        /// dropping them makes the sample count honest and leaves `n` visible
        /// beside every figure.
        let elapsed: TimeInterval?

        init(
            record: GatewayAttemptRecord,
            liveAttemptIDs: Set<UUID>,
            now: Date,
            grace: TimeInterval
        ) {
            self.record = record
            self.effective = record.effectiveOutcome(
                isLocallyLive: liveAttemptIDs.contains(record.id),
                now: now,
                grace: grace
            )
            if let startedAt = record.startedAt, let completedAt = record.completedAt {
                let interval = completedAt.timeIntervalSince(startedAt)
                self.elapsed = (interval >= 0 && interval <= grace) ? interval : nil
            } else {
                self.elapsed = nil
            }
        }

        var storedOutcome: GatewayAttemptOutcome? {
            guard case .terminal(let outcome) = effective else { return nil }
            return outcome
        }

        var isSucceeded: Bool { storedOutcome == .succeeded }

        /// Reached a stored terminal outcome, so it had its chance to report
        /// usage. The token-coverage denominator.
        var isResolved: Bool { effective.isResolved }

        /// A successful attempt whose timing survived the sanity window.
        var responseSample: Double? { isSucceeded ? elapsed : nil }

        var isTruncated: Bool {
            guard let reason = record.finishReason else { return false }
            return reason.compare(
                GatewayUsageAggregator.truncatedFinishReason,
                options: [.caseInsensitive]
            ) == .orderedSame
        }
    }

    // MARK: - Turn arithmetic

    /// Turn counts, all over DISTINCT `userMessageID`. An attempt that recorded
    /// no user message is counted as an attempt and belongs to no turn — it can
    /// never be matched to one, and inventing a turn for it would inflate
    /// exactly the number retries are kept out of.
    private static func turnCounts(
        for items: [Classified]
    ) -> (attempted: Int, completed: Int, retried: Int, attemptsOnCompletedTurns: Int) {
        var attemptsPerTurn: [UUID: Int] = [:]
        var completed: Set<UUID> = []
        for item in items {
            guard let turn = item.record.userMessageID else { continue }
            attemptsPerTurn[turn, default: 0] += 1
            if item.isSucceeded { completed.insert(turn) }
        }
        let attemptsOnCompletedTurns = completed.reduce(0) { $0 + (attemptsPerTurn[$1] ?? 0) }
        return (
            attempted: attemptsPerTurn.count,
            completed: completed.count,
            retried: attemptsPerTurn.count(where: { $0.value > 1 }),
            attemptsOnCompletedTurns: attemptsOnCompletedTurns
        )
    }

    // MARK: - Outcome mix

    private static func outcomeMix(for items: [Classified]) -> GatewayUsageOutcomeMix {
        var succeeded = 0, failed = 0, cancelled = 0, unknown = 0
        var inFlight = 0, pending = 0, unconfirmed = 0
        for item in items {
            switch item.effective {
            case .terminal(.succeeded): succeeded += 1
            case .terminal(.failed): failed += 1
            case .terminal(.cancelled): cancelled += 1
            case .terminal(.unknown): unknown += 1
            // `inFlight` is not a terminal value and `derive` never returns it
            // wrapped; the arm exists so the switch stays exhaustive without a
            // default that would swallow a future case.
            case .terminal(.inFlight): inFlight += 1
            case .inFlight: inFlight += 1
            case .pending: pending += 1
            case .unconfirmed: unconfirmed += 1
            }
        }
        return GatewayUsageOutcomeMix(
            succeeded: succeeded,
            failed: failed,
            cancelled: cancelled,
            unknown: unknown,
            inFlight: inFlight,
            pending: pending,
            unconfirmed: unconfirmed
        )
    }

    // MARK: - Tokens

    private static func tokens(for items: [Classified]) -> GatewayUsageTokens {
        let resolved = items.filter { $0.isResolved }
        return GatewayUsageTokens(
            input: tokenField(resolved) { $0.record.reportedInputTokens },
            output: tokenField(resolved) { $0.record.reportedOutputTokens },
            reportedTotal: tokenField(resolved) { $0.record.reportedTotalTokens }
        )
    }

    /// Sums one field over the already-filtered terminal attempts. A field no
    /// attempt reported stays nil — summing absence to zero is the single
    /// easiest way to claim a gateway reports usage when it reports nothing.
    ///
    /// TOKEN-BEARING FAILURES COUNT, and so do cancellations. A gateway that
    /// failed the turn — or was torn down part way through one — may still have
    /// done billable work, so the filter above is terminal-ness, not success.
    private static func tokenField(
        _ resolved: [Classified],
        _ field: (Classified) -> Int64?
    ) -> GatewayUsageTokenField {
        var sum: Int64?
        var reporting = 0
        for item in resolved {
            guard let value = field(item) else { continue }
            reporting += 1
            sum = saturatingSum(sum ?? 0, value)
        }
        return GatewayUsageTokenField(
            sum: sum,
            reportingAttempts: reporting,
            coverageDenominator: resolved.count
        )
    }

    // MARK: - Response time

    private static func responseTime(for items: [Classified]) -> GatewayUsageResponseTime {
        let samples = items.compactMap { $0.responseSample }.sorted()
        guard !samples.isEmpty else { return .empty }
        return GatewayUsageResponseTime(
            sampleCount: samples.count,
            median: quantile(sorted: samples, probability: 0.5),
            p90: samples.count >= p90MinimumSamples
                ? quantile(sorted: samples, probability: 0.9)
                : nil,
            mean: samples.reduce(0, +) / Double(samples.count)
        )
    }

    // MARK: - Daily activity

    /// Dense day buckets across `range`, or across the observed days when no
    /// range is given. Attempts with no `startedAt` are counted in the range
    /// totals but land in no bucket: a row that cannot say when it began cannot
    /// be drawn on a date axis, and assigning it to "today" would move a bar
    /// that describes a day it has nothing to do with.
    private static func dailyActivity(
        for items: [Classified],
        range: ClosedRange<Date>?,
        calendar: Calendar
    ) -> [GatewayUsageDailyBucket] {
        var attemptsPerDay: [Date: Int] = [:]
        var turnsPerDay: [Date: Set<UUID>] = [:]
        for item in items {
            guard let startedAt = item.record.startedAt else { continue }
            let day = calendar.startOfDay(for: startedAt)
            attemptsPerDay[day, default: 0] += 1
            if let turn = item.record.userMessageID {
                turnsPerDay[day, default: []].insert(turn)
            }
        }

        let firstDay: Date
        let lastDay: Date
        if let range {
            firstDay = calendar.startOfDay(for: range.lowerBound)
            lastDay = calendar.startOfDay(for: range.upperBound)
        } else {
            guard let earliest = attemptsPerDay.keys.min(),
                  let latest = attemptsPerDay.keys.max()
            else { return [] }
            firstDay = earliest
            lastDay = latest
        }
        guard firstDay <= lastDay else { return [] }

        var buckets: [GatewayUsageDailyBucket] = []
        var day = firstDay
        while day <= lastDay && buckets.count < maxDailyBuckets {
            buckets.append(
                GatewayUsageDailyBucket(
                    day: day,
                    attempts: attemptsPerDay[day] ?? 0,
                    turns: turnsPerDay[day]?.count ?? 0
                )
            )
            // RE-ANCHOR ON `startOfDay` AT EVERY STEP. Adding a day preserves
            // the wall-clock time it started from, and in a zone whose DST
            // transition happens AT midnight (America/Santiago, Asia/Beirut)
            // `startOfDay` for the transition date is 01:00 — so an
            // unnormalised walk carries that 01:00 forward for every later day,
            // matches none of the lookup keys above (always a `startOfDay`), and
            // stops a day early against a `lastDay` that is 00:00. Fixed
            // 86400-second arithmetic drifts the same way on every transition,
            // midnight or not.
            guard let next = calendar.date(byAdding: .day, value: 1, to: day)
            else { break }
            let following = calendar.startOfDay(for: next)
            guard following > day else { break }
            day = following
        }
        return buckets
    }

    // MARK: - Grouping

    private static func gatewayGroups(for items: [Classified]) -> [GatewayUsageGroup] {
        grouped(items, by: { $0.record.gatewayRef }).map { key, members in
            let modelKeys = Set(members.map { $0.record.requestedModel })
            return group(
                key: key,
                members: members,
                models: modelKeys.count > 1 ? modelGroups(for: members) : []
            )
        }
        .sorted(by: rank)
    }

    private static func modelGroups(for items: [Classified]) -> [GatewayUsageGroup] {
        grouped(items, by: { $0.record.requestedModel })
            .map { group(key: $0.key, members: $0.value, models: []) }
            .sorted(by: rank)
    }

    /// Groups by an OPTIONAL key without losing the nil bucket — attempts that
    /// recorded no gateway or no model are their own honest group, not silently
    /// dropped and not merged into whichever key happened to sort first.
    private static func grouped(
        _ items: [Classified],
        by key: (Classified) -> String?
    ) -> [String?: [Classified]] {
        var buckets: [String?: [Classified]] = [:]
        for item in items { buckets[key(item), default: []].append(item) }
        return buckets
    }

    private static func group(
        key: String?,
        members: [Classified],
        models: [GatewayUsageGroup]
    ) -> GatewayUsageGroup {
        let mix = outcomeMix(for: members)
        let samples = members.compactMap { $0.responseSample }.sorted()
        return GatewayUsageGroup(
            key: key,
            attempts: members.count,
            succeeded: mix.succeeded,
            failed: mix.failed,
            successRate: ratio(mix.succeeded, mix.succeeded + mix.failed),
            medianResponseTime: quantile(sorted: samples, probability: 0.5),
            responseSampleCount: samples.count,
            tokens: tokens(for: members),
            models: models
        )
    }

    /// Busiest first; ties broken on the key so a redraw never reshuffles rows
    /// under the user's cursor. The unattributed group sorts last within a tie.
    private static func rank(_ lhs: GatewayUsageGroup, _ rhs: GatewayUsageGroup) -> Bool {
        if lhs.attempts != rhs.attempts { return lhs.attempts > rhs.attempts }
        switch (lhs.key, rhs.key) {
        case (nil, nil): return false
        case (nil, _): return false
        case (_, nil): return true
        case (let left?, let right?): return left < right
        }
    }
}
