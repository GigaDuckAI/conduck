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
// A FOURTH DENOMINATOR JOINS THEM FOR RELIABILITY, AND IT IS NARROWER THAN ALL
// OF THEM: `resolvedTurns` counts only turns whose FINAL attempt reached a
// stored terminal outcome. First-try delivery and retry recovery divide by it,
// because a turn still being retried has not yet delivered or failed to, and
// leaving it in either denominator would report an outcome it has not had.
//
// THE ACTIVITY BARS FOLD BY SPAN, AND EVERY FOLDED FIGURE IS RECOMPUTED FROM
// THE RECORDS. Ninety daily bars is a grey smear on a phone, so a wide window
// is cut into weeks or months — but a week is never the sum of its days'
// buckets. Turns are distinct `userMessageID`s inside the period, which is
// strictly fewer than the days' turn counts added up whenever a turn was
// retried across midnight, and rates stay pooled because a bucket stores counts
// rather than a ratio. The one asymmetry is deliberate and inherited from the
// daily bars: a turn straddling a period boundary is counted in BOTH periods
// while the range total counts it once, because it really was worked on in
// both.
//
// ONE RANKING BASIS PER LIST, NEVER MIXED. Heaviest threads and largest turns
// rank on gateway-REPORTED totals when any thread in range has one, and on
// calculated input+output components otherwise — never a per-thread choice
// between them, which would rank one thread's reported total against another's
// client-computed sum and call the comparison a ranking. Threads that cannot
// answer under the chosen basis are absent from the list rather than ranked at
// zero, and the basis travels with the list so the screen can name it.
//
// THE THREE TOKEN-DETAIL FIELDS ARE SUBSETS, NOT ADDITIONS. Cached input and
// cache-write input are parts of the reported input; reasoning output is part
// of the reported output. Nothing in this file adds one into a total, a volume
// or a ranking basis, and nothing downstream may either — doing so double-counts
// tokens the gateway already counted once. They are summed and covered exactly
// like the primary fields, against the SAME terminal-attempt denominator, and
// they change no existing number.
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
    /// Turns whose FINAL attempt — latest `startedAt` — reached a stored
    /// terminal outcome. The reliability denominator, and deliberately not
    /// `attemptedTurns`: a turn still being retried has not yet delivered or
    /// failed to, and counting it either way reports an outcome it has not had.
    let resolvedTurns: Int
    /// Resolved turns whose EARLIEST attempt succeeded — the turn landed
    /// without ever being retried. Over `resolvedTurns`.
    let firstAttemptDeliveredTurns: Int
    /// Resolved turns carrying more than one attempt. Kept apart from
    /// `retriedTurns` because the two answer different questions over different
    /// populations, and dividing recovery by the wider one would count turns
    /// that have not finished retrying as retries that failed to recover.
    let resolvedRetriedTurns: Int
    /// Retried, resolved turns whose FINAL attempt succeeded. Over
    /// `resolvedRetriedTurns`.
    let retriedTurnsRecovered: Int
    /// `succeeded / (succeeded + failed)`. Cancellations, unclassifiable
    /// landings and every derived state stay OUT of this denominator; nil when
    /// nothing resolved into either half.
    let resolvedAttemptSuccessRate: Double?
    /// Attempts linked to completed turns / completed turns — how many tries a
    /// turn that eventually worked actually took. Nil when nothing completed.
    let attemptsPerCompletedTurn: Double?
    /// Distinct conversations with a recorded attempt in range, INCLUDING
    /// conversations the user has since deleted — usage outlives the thread it
    /// describes, so a count named for live threads would be a lie the moment
    /// one is deleted. Rows that recorded no conversation are counted in every
    /// total above and in no thread.
    let threadsWithUsage: Int
    let outcomeMix: GatewayUsageOutcomeMix
    let tokens: GatewayUsageTokens
    let responseTime: GatewayUsageResponseTime
    /// Attempts whose gateway reported the reply was cut off at the length
    /// limit. Zero is a fine answer; it is not "unavailable".
    let truncatedReplies: Int
    /// The chart's bars, plus the period unit they were cut on.
    let activity: GatewayUsageActivity
    /// Attempts in range carrying a usable token figure — a gateway-reported
    /// total, else both components. THE RANGE'S OWN COUNT, over every attempt
    /// including the ones no bar can draw: an attempt with no start instant
    /// lands in no bucket, so summing the buckets would understate coverage and
    /// could report "no token data" for a range that plainly has some. The bars
    /// still draw dated attempts only; that asymmetry is the honest one.
    let tokenMeasuredAttempts: Int
    /// Per configured gateway SLOT, busiest first. Each carries its own
    /// per-model breakdown when more than one model was requested through it.
    let byGateway: [GatewayUsageGroup]
    /// Per requested model, across every gateway, busiest first.
    let byRequestedModel: [GatewayUsageGroup]
    /// Per device bucket, busiest first, keyed by `UsageDeviceBucket.rawValue`.
    /// Same shape as `byGateway` so one row view draws both.
    let deviceGroups: [GatewayUsageGroup]
    /// Failed attempts by Conduck's OWN error code, commonest first. Never a
    /// server code, status or message — the code is resolved to the app's user
    /// facing description at render time.
    let failureReasons: [FailureReasonCount]
    /// How the original turns were acquired, busiest first.
    let inputModes: [InputModeSlice]
    /// Heaviest threads, and the single basis they were ranked on.
    let threadRanking: ThreadRanking
    /// Heaviest individual turns, ranked on `threadRanking.basis` — the same
    /// basis, so a turn's figure and its thread's figure are comparable.
    let largestTurns: [TurnOutlier]
    /// What rode along with the turns: how many carried images or text files,
    /// and how much of the range could answer at all.
    let attachmentContext: AttachmentContext

    /// Nothing recorded in this range. The dashboard's empty state asks a
    /// wider question (nothing recorded EVER) and reads its own flag.
    var isEmpty: Bool { recordedAttempts == 0 }

    /// `deviceGroups` without the bucket that could not be attributed to a
    /// device — the LIST a by-device breakdown draws.
    ///
    /// There are five devices, and an "unrecorded" row is read as a sixth one.
    /// It is not: it is the attempts whose device the ledger never captured,
    /// which is a fact about measurement rather than about hardware. So this
    /// drops them from a LIST and from nothing else — they stay in
    /// `recordedAttempts` and in every rate on the screen. The computation
    /// above stays whole on purpose: the data layer keeps the honest bucket,
    /// and only the reading of it is narrowed.
    var attributedDeviceGroups: [GatewayUsageGroup] {
        deviceGroups.filter { $0.key != UsageDeviceBucket.unknown.rawValue }
    }

    /// Attempts in that unattributed bucket, or zero where there is none.
    ///
    /// The COMPLEMENT of `attributedDeviceGroups`, and the reason that filter
    /// is auditable: it is what lets a test assert the dropped attempts are
    /// still inside `recordedAttempts` rather than quietly gone. The by-device
    /// cards print it in their missing-mass footer when it is not zero — the
    /// one case where dropping the row from the list would leave the rows'
    /// shares visibly not adding up with nothing on screen saying why.
    var unattributedDeviceAttempts: Int {
        deviceGroups.first { $0.key == UsageDeviceBucket.unknown.rawValue }?.attempts ?? 0
    }

    /// `byGateway` without the group that recorded no slot at all — the LIST a
    /// by-gateway breakdown draws.
    ///
    /// The device rule, applied to the same shape of problem: a row reading
    /// "Not recorded" sits among the user's OWN gateways and is read as one of
    /// them. It is not — it is the attempts whose slot the ledger never
    /// captured, and no drill-down into it could say anything the user can act
    /// on. They leave the list and nothing else: `recordedAttempts` and every
    /// rate still hold them.
    var attributedGatewayGroups: [GatewayUsageGroup] {
        byGateway.filter { $0.key != nil }
    }

    /// The complement of `attributedGatewayGroups`, mirroring the device pair
    /// above for the same two reasons: it makes the filter auditable, and it is
    /// the count the by-gateway cards' missing-mass footer prints when the
    /// listed rows' shares do not reach the whole.
    var unattributedGatewayAttempts: Int {
        byGateway.first { $0.key == nil }?.attempts ?? 0
    }

    /// `inputModes` without the slice nothing observed. Beside Typed and Voice
    /// an "unrecorded" row reads as a third way of talking to the app; it is a
    /// gap in measurement instead, and the same rule sends it out of the list
    /// and out of nothing else.
    var attributedInputModes: [InputModeSlice] {
        inputModes.filter { $0.mode != .unknown }
    }

    static let empty = GatewayUsageSummary(
        recordedAttempts: 0,
        attemptedTurns: 0,
        completedTurns: 0,
        retriedTurns: 0,
        retryRate: nil,
        completedTurnRate: nil,
        resolvedTurns: 0,
        firstAttemptDeliveredTurns: 0,
        resolvedRetriedTurns: 0,
        retriedTurnsRecovered: 0,
        resolvedAttemptSuccessRate: nil,
        attemptsPerCompletedTurn: nil,
        threadsWithUsage: 0,
        outcomeMix: .empty,
        tokens: .empty,
        responseTime: .empty,
        truncatedReplies: 0,
        activity: .empty,
        tokenMeasuredAttempts: 0,
        byGateway: [],
        byRequestedModel: [],
        deviceGroups: [],
        failureReasons: [],
        inputModes: [],
        threadRanking: .empty,
        largestTurns: [],
        attachmentContext: .empty
    )
}

// MARK: - Reliability, device and attachment slices

/// One failure code and how often it landed. The code is Conduck's own
/// `AppError.errorCode`: a stable local integer with a user-facing description
/// the app already owns, and NEVER the provider's message or HTTP status, which
/// the ledger refuses to store at all.
nonisolated struct FailureReasonCount: Sendable, Equatable, Identifiable {
    let appErrorCode: Int
    let count: Int

    var id: Int { appErrorCode }
}

/// How the original turns were acquired. Attempts and turns are reported
/// separately for the same reason they are everywhere else — a retried voice
/// turn is one turn's worth of speaking and two attempts' worth of load.
nonisolated struct InputModeSlice: Sendable, Equatable, Identifiable {
    let mode: GatewayInputMode
    let attempts: Int
    let turns: Int

    var id: String { mode.rawValue }
}

/// The device an attempt ran from, as the dashboard groups them. A BUCKET, not
/// a device identity: it is derived from the coarse hardware class and the
/// surface, never from a user-assigned device name, and it cannot distinguish
/// two iPhones.
///
/// CarPlay and the wrist are surfaces, not hardware — a CarPlay dispatch runs on
/// the iPhone and stamps `iphone` as its class — so the surface wins where it is
/// dedicated, which is what makes "By device" answer the question the user is
/// actually asking.
nonisolated enum UsageDeviceBucket: String, Sendable, Hashable, CaseIterable, Identifiable {
    case iphone
    case ipad
    case mac
    case watch
    case carPlay
    case unknown

    var id: String { rawValue }

    /// THE SOLE DERIVATION POINT. Dedicated surfaces first, then the class the
    /// dispatching device stamped, then the parent turn's `sourceDevice` tag as
    /// a fallback for rows written before the class existed. Anything else is
    /// `unknown` — an honest bucket, never folded into the commonest one.
    static func from(record: GatewayAttemptRecord) -> UsageDeviceBucket {
        switch record.origin {
        case .carPlay: return .carPlay
        case .watch: return .watch
        default: break
        }
        let stamped = record.originDeviceClass
            ?? GatewayAttemptDeviceClass.from(sourceDevice: record.fallbackSourceDevice)
        switch stamped?.lowercased() {
        case "iphone": return .iphone
        case "ipad": return .ipad
        case "mac": return .mac
        case "watch": return .watch
        // A CarPlay dispatch stamps `iphone`, so this arm only fires for a row
        // whose class came from a `carplay-` tagged turn. Recognised so it lands
        // in the bucket the user sees rather than silently as unknown.
        case "carplay": return .carPlay
        default: return .unknown
        }
    }
}

/// Heaviest threads plus the ONE basis they were ranked on. The basis is part of
/// the value because the screen has to name it: "ranked by gateway-reported
/// totals" and "ranked by calculated components" are different claims, and a
/// list that let each thread pick would be neither.
nonisolated struct ThreadRanking: Sendable, Equatable {
    enum Basis: Sendable, Equatable {
        /// `usage.total_tokens` exactly as the gateway reported it.
        case reportedTotals
        /// Input + output, summed by this client, for ranges where no gateway
        /// reported a total at all. Never mixed with the above.
        case calculatedComponents
    }

    let basis: Basis
    /// Heaviest first, capped at `GatewayUsageAggregator.maxRankedThreads`.
    /// Threads that reported nothing under `basis` are ABSENT rather than
    /// ranked at zero — a thread with no figure has not been measured, and
    /// drawing it last would read as the lightest one.
    let threads: [ThreadUsage]

    /// An empty ranking still names a basis so the type stays total; nothing
    /// renders a basis caption for an empty list.
    static let empty = ThreadRanking(basis: .reportedTotals, threads: [])
}

/// One conversation's measured usage. CONTENT-FREE like everything else here:
/// an id, timings, gateway slots and counts. The title the user reads is
/// resolved from the conversation at render time, and is simply absent when the
/// conversation is not there any more.
nonisolated struct ThreadUsage: Sendable, Equatable, Identifiable {
    let conversationID: UUID
    /// First and last attempt START in range — the span a row draws. Threads
    /// whose rows all lack a start instant are not ranked: a span cannot be
    /// invented from rows that cannot say when they ran.
    let earliestStart: Date
    let latestStart: Date
    /// Distinct `RemoteAgentRef` raw strings, in first-seen chronological
    /// order. A thread bound to one gateway has one entry; a cloned-and-switched
    /// thread has more, and the order is the order the user used them.
    let gatewayRefs: [String?]
    let attempts: Int
    let turns: Int
    /// The figure this thread was ranked on, under the list's single basis.
    let rankedTokens: Int
    /// Turns that reported anything under that basis — the numerator of the
    /// "N of M turns reported" caption, whose M is `turns`.
    let tokenReportedTurns: Int
    /// Inline images (current turn + replayed prior turns) summed over rows
    /// that MEASURED attachments at all. Nil when no row in the thread did:
    /// zero would claim the thread carried no images, which is a different
    /// statement from not having counted.
    let inlineImageCount: Int?
    let inlineTextFileCount: Int?
    /// Rows behind the two sums above — the coverage they are honest about.
    let attachmentMeasuredAttempts: Int

    var id: UUID { conversationID }
}

/// One heavy turn. Carries its conversation so the screen can navigate to it,
/// and nothing that would describe what was asked.
nonisolated struct TurnOutlier: Sendable, Equatable, Identifiable {
    let conversationID: UUID
    let userMessageID: UUID
    /// The turn's EARLIEST attempt start — when the user asked, not when the
    /// last retry gave up.
    let startedAt: Date
    /// The slot the earliest attempt used.
    let gatewayRef: String?
    /// Summed across every attempt on the turn: a retry that reached the
    /// gateway was paid for whether or not its reply was kept.
    let tokens: Int
    let basis: ThreadRanking.Basis
    let inlineImageCount: Int?
    let inlineTextFileCount: Int?

    var id: UUID { userMessageID }
}

/// What rode along with the turns, and how much of the range can answer.
/// Attachment counts are stamped at INSERT, so every row written by a client
/// that records them can answer regardless of how the attempt ended — the
/// coverage denominator is `recordedAttempts`, not the terminal subset the
/// token fields use.
nonisolated struct AttachmentContext: Sendable, Equatable {
    /// Rows carrying attachment counts at all. Zero means the range predates
    /// the measurement, which is why every figure below travels with it.
    let measuredAttempts: Int
    /// Distinct turns the USER attached at least one image to. Replayed
    /// history never qualifies a turn — a follow-up that only carried an
    /// earlier image again must not read as one the user added an image to
    /// (that cost lives in `replayedImageTotal`, and counting it here too
    /// double-counted the same image across two rows).
    let turnsWithImages: Int
    /// Distinct turns whose measured rows carried extracted text files
    /// (payload semantics — fresh or replayed). Aggregated but not shown:
    /// the row read as file transfer to most users.
    let turnsWithTextFiles: Int
    /// Prior-turn images re-sent on later requests — the cost of image history,
    /// which is the one number that explains a slow, expensive thread.
    let replayedImageTotal: Int

    var isEmpty: Bool { measuredAttempts == 0 }

    static let empty = AttachmentContext(
        measuredAttempts: 0, turnsWithImages: 0, turnsWithTextFiles: 0, replayedImageTotal: 0)
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

/// The reported token fields, each summed and covered INDEPENDENTLY — one
/// generic coverage percentage would claim a completeness no gateway promised.
///
/// THREE PRIMARY FIELDS AND THREE DETAIL FIELDS, AND THE DIFFERENCE IS NOT
/// COSMETIC. `input`, `output` and `reportedTotal` are whole figures. The three
/// below are SUBSETS of them — cached and cache-write of the input, reasoning of
/// the output — so nothing here or anywhere downstream may add one into a total.
/// They also gate their own rows rather than the card: `isEmpty` keeps asking
/// only about the three primary fields, because a card that appeared for a
/// cached-token count alone would promise usage reporting a gateway never did.
nonisolated struct GatewayUsageTokens: Sendable, Equatable {
    let input: GatewayUsageTokenField
    let output: GatewayUsageTokenField
    /// `usage.total_tokens` exactly as reported, kept apart from any sum this
    /// client can compute. A gateway's inconsistent total is still its own
    /// statement about the turn.
    let reportedTotal: GatewayUsageTokenField
    /// Part of `input`. An efficiency fact and NEVER a saving — see
    /// `cacheWriteInput`.
    let cachedInput: GatewayUsageTokenField
    /// Part of `input`. Several providers bill a cache write at a PREMIUM over
    /// an ordinary prompt token, so nothing may present this as money saved.
    let cacheWriteInput: GatewayUsageTokenField
    /// Part of `output` — what the model spent thinking rather than answering.
    let reasoningOutput: GatewayUsageTokenField

    /// Whether any of the three detail fields was reported in range. The
    /// disclosure that draws them is hidden on false: an expander over three
    /// absent rows is a control that opens onto nothing.
    var hasReportedDetail: Bool {
        cachedInput.isReported || cacheWriteInput.isReported || reasoningOutput.isReported
    }

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

    /// No gateway in range reported any of the three PRIMARY figures. The
    /// detail fields are deliberately outside this question: they qualify the
    /// primaries rather than standing in for them.
    var isEmpty: Bool {
        input.sum == nil && output.sum == nil && reportedTotal.sum == nil
    }

    static let empty = GatewayUsageTokens(
        input: .empty,
        output: .empty,
        reportedTotal: .empty,
        cachedInput: .empty,
        cacheWriteInput: .empty,
        reasoningOutput: .empty
    )
}

/// Full-response time: dispatch to terminal callback. It is NOT model latency —
/// it contains OS scheduling, the network, the gateway's tool calls and however
/// many model calls the agent made on its way to a reply. The protocol is
/// non-streaming, so no earlier instant is observable.
nonisolated struct GatewayUsageResponseTime: Sendable, Equatable {
    /// Successful attempts with usable timing. Shown ALWAYS, beside every
    /// figure below, because an average over three samples is not a claim.
    let sampleCount: Int
    /// Type-7 p90, suppressed below `GatewayUsageAggregator.p90MinimumSamples`
    /// where the estimator is interpolating between the two slowest samples and
    /// would read as precision it does not have.
    let p90: TimeInterval?
    /// Arithmetic mean — the headline figure. The sample pool is already
    /// bounded by `ConversationActivityResolver.staleSendingGrace`, so a
    /// runaway attempt cannot land in it and drag the average.
    let mean: TimeInterval?

    static let empty = GatewayUsageResponseTime(
        sampleCount: 0, p90: nil, mean: nil)
}

/// The period ONE activity bar covers. Chosen by the aggregator from the span
/// it was asked for, never by the caller: the chart and the bucket arithmetic
/// have to agree about what a bar means, and a caller-supplied unit is a second
/// opinion waiting to disagree with the buckets it labels.
nonisolated enum UsageActivityUnit: String, Sendable, Hashable, CaseIterable {
    case day
    case week
    case month

    /// The calendar component the period is cut on. `weekOfYear` rather than
    /// `weekOfMonth` so a week is the user's own calendar week, unbroken across
    /// a month boundary.
    var component: Calendar.Component {
        switch self {
        case .day: return .day
        case .week: return .weekOfYear
        case .month: return .month
        }
    }
}

/// The activity buckets and the unit they were cut on, together. The unit is
/// part of the value because every caption the chart writes names it — "per
/// day" and "per week" are different claims about the same bars, and a unit
/// re-derived at render time is a second derivation that can disagree with the
/// buckets it describes.
nonisolated struct GatewayUsageActivity: Sendable, Equatable {
    let unit: UsageActivityUnit
    /// One entry per period in the requested window, gaps filled with zeros, so
    /// a bar chart draws quiet periods as quiet rather than closing the gap.
    let buckets: [GatewayUsageActivityBucket]

    var isEmpty: Bool { buckets.isEmpty }

    static let empty = GatewayUsageActivity(unit: .day, buckets: [])
}

/// One period of activity. Attempts and turns are kept apart here for the same
/// reason they are everywhere else: three retries of one turn are one turn's
/// worth of activity and three attempts' worth of load.
///
/// The chart draws one metric at a time from this bucket, so every field below
/// carries the same denominators the range totals use — a period's bar and the
/// headline above it have to be the same kind of number, or the chart quietly
/// contradicts the figure it sits under.
///
/// EVERY COUNT IS SUMMED, NEVER AVERAGED, which is what keeps a rate honest
/// after a fold: a week's success share is its succeeded count over its
/// resolved count, so a busy Monday outweighs a quiet Sunday exactly as it
/// should. A bucket that stored a rate would have to average seven of them and
/// would weight every day alike.
nonisolated struct GatewayUsageActivityBucket: Sendable, Equatable, Identifiable {
    /// Start of the period in the calendar the aggregation ran under, CLIPPED to
    /// the requested window — a 90-day range stays 90 days, so its first weekly
    /// bucket may begin mid-week rather than silently widening the range.
    let periodStart: Date
    /// Exclusive end of the span this bucket actually covers, clipped the same
    /// way. Equal to the natural period end except at the two ends of the range.
    let periodEnd: Date
    /// The natural period began BEFORE `periodStart` — a leading partial. The
    /// caption then names the covered span instead of the period.
    let startsMidPeriod: Bool
    /// The natural period ends AFTER `periodEnd` — the trailing period is still
    /// running, which is what earns a "so far" clause.
    let endsMidPeriod: Bool
    let attempts: Int
    /// Distinct user turns attempted in the period. A turn whose retries
    /// straddle the boundary counts in BOTH periods; the range total counts it
    /// once. The asymmetry is deliberate and the same one the daily buckets
    /// always had — a turn worked on across two days happened on both.
    let turns: Int
    /// Of `turns`, the ones with at least one SUCCEEDED attempt in the period —
    /// the same vocabulary as the range's `completedTurns`, judged from this
    /// period's own attempts. The bottom of the Turns stack.
    let completedTurns: Int
    /// Of `turns`, the ones with at least one FAILED attempt and NO succeeded
    /// attempt in the period. A turn that failed and then landed on a retry is
    /// completed, not failed — the retry is the story's ending.
    let failedTurns: Int
    /// The period's reliability denominator: attempts that landed SUCCEEDED or
    /// FAILED, and nothing else. Deliberately NARROWER than
    /// `GatewayUsageOutcomeMix.resolved`, which also holds cancellations and
    /// unclassifiable landings — this is the denominator
    /// `resolvedAttemptSuccessRate` divides by, so the per-period bars and the
    /// range's success rate answer the same question. A period of nothing but
    /// cancellations is zero here and draws NO bar, because a cancelled turn is
    /// not a turn that failed.
    let resolvedAttempts: Int
    /// Of `resolvedAttempts`, the ones that succeeded.
    let succeededAttempts: Int
    /// The period's best-available token volume: for each terminal attempt, its
    /// gateway-reported total, else its input + output when BOTH are present,
    /// else nothing. Bases are mixed WITHIN a period on purpose — this is a
    /// volume, not a ranking, and nothing is being ordered against anything —
    /// which is exactly why `tokenMeasuredAttempts` travels beside it.
    ///
    /// Zero is ambiguous on its own (nobody reported, or everybody reported
    /// zero); the coverage count tells the two apart, and naming the figure
    /// honestly on screen is the UI's job.
    let reportedTokens: Int
    /// Attempts behind `reportedTokens`, whose denominator is `attempts`. Zero
    /// means the period can say nothing about tokens.
    let tokenMeasuredAttempts: Int
    /// The period's attempts split by device bucket. NIL KEY IS "not recorded",
    /// matching the gateway split below, so one piece of chart code reads both
    /// dimensions under one rule. Sums EXACTLY to `attempts` — a stack that
    /// quietly totals below its own bar is a lie about the bar's height.
    let deviceAttempts: [String?: Int]
    /// The period's attempts split by gateway SLOT (`RemoteAgentRef.rawString`).
    /// Nil key is the slot the ledger never captured. Sums exactly to
    /// `attempts`.
    let gatewayAttempts: [String?: Int]
    /// The period's attempts split by REQUESTED model, verbatim wire strings.
    /// Nil key means the request carried no model and the gateway's own default
    /// answered — a real choice, not a measurement gap, which is why the chart
    /// names it "Gateway default" rather than "Not recorded". Sums exactly to
    /// `attempts`.
    let modelAttempts: [String?: Int]

    var id: Date { periodStart }

    /// Resolved attempts that did not succeed. The top half of the Results
    /// stack, and never a rate: a count cannot be inflated by a small
    /// denominator.
    var failedAttempts: Int { max(0, resolvedAttempts - succeededAttempts) }

    /// Attempts that landed neither succeeded nor failed — cancelled,
    /// unclassifiable, or still open. Named rather than painted red: they are
    /// not failures, and a bar segment coloured like one would read as one.
    var otherOutcomeAttempts: Int { max(0, attempts - resolvedAttempts) }

    /// Turns whose period attempts neither completed nor failed — cancelled,
    /// unclassifiable, or still open. The faint top of the Turns stack, so the
    /// bar's full height stays `turns`.
    var otherOutcomeTurns: Int { max(0, turns - completedTurns - failedTurns) }

    /// Everything past the period bounds defaults, so a bucket built by hand —
    /// a preview, a fixture for the turns-only path — states only what it means
    /// to. A zeroed bucket reads as a quiet period, which is what a gap is.
    init(
        periodStart: Date,
        periodEnd: Date? = nil,
        startsMidPeriod: Bool = false,
        endsMidPeriod: Bool = false,
        attempts: Int,
        turns: Int,
        completedTurns: Int = 0,
        failedTurns: Int = 0,
        resolvedAttempts: Int = 0,
        succeededAttempts: Int = 0,
        reportedTokens: Int = 0,
        tokenMeasuredAttempts: Int = 0,
        deviceAttempts: [String?: Int] = [:],
        gatewayAttempts: [String?: Int] = [:],
        modelAttempts: [String?: Int] = [:]
    ) {
        self.periodStart = periodStart
        self.periodEnd = periodEnd ?? periodStart
        self.startsMidPeriod = startsMidPeriod
        self.endsMidPeriod = endsMidPeriod
        self.attempts = attempts
        self.turns = turns
        self.completedTurns = completedTurns
        self.failedTurns = failedTurns
        self.resolvedAttempts = resolvedAttempts
        self.succeededAttempts = succeededAttempts
        self.reportedTokens = reportedTokens
        self.tokenMeasuredAttempts = tokenMeasuredAttempts
        self.deviceAttempts = deviceAttempts
        self.gatewayAttempts = gatewayAttempts
        self.modelAttempts = modelAttempts
    }
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
    let meanResponseTime: TimeInterval?
    /// Samples behind `meanResponseTime`.
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

    /// How many bars the finest unit may produce before the fold moves to a
    /// coarser one. Forty is the point past which a phone-width plot draws bars
    /// thinner than the gap between them — 90 daily bars is a grey smear, the
    /// same 90 days as 13 weekly bars is a shape.
    ///
    /// A CEILING ON THE FOLD, NOT ON THE CHART: months are the coarsest unit
    /// there is, so a ledger spanning decades exceeds this and is bounded by
    /// `maxActivityBuckets` instead.
    static let maxActivityBars = 40

    /// Hard ceiling on generated buckets, so a nonsense range — a device with a
    /// wildly wrong clock, a corrupt stored date — costs a bounded array
    /// instead of a hang.
    static let maxActivityBuckets = 3_660

    /// Ceiling on the ranked-thread list. The screen shows five and offers the
    /// rest; a ledger with tens of thousands of threads still costs one bounded
    /// array, and nobody scrolls past fifty.
    static let maxRankedThreads = 50

    /// Ceiling on the largest-turn list, which is only ever a drill-down's
    /// "heaviest few" rather than a browsable list.
    static let maxLargestTurns = 10

    /// Everything for one range, in a single pass.
    ///
    /// - Parameters:
    ///   - attempts: Recorded attempts already filtered to the range by the
    ///     store fetch. Order is irrelevant.
    ///   - liveAttemptIDs: Attempt ids THIS device currently holds a live task
    ///     for. Local, process-visible evidence only; its absence never means
    ///     an attempt is dead.
    ///   - now: Evaluation instant, injected so derived states are reproducible.
    ///   - activityRange: The window the activity buckets should span, gaps
    ///     included; its upper bound is what makes the trailing period read as
    ///     still running. Nil spans first to last observed attempt day only.
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
        let reliability = turnReliability(for: items)
        let ranking = threadRanking(for: items)

        return GatewayUsageSummary(
            recordedAttempts: items.count,
            attemptedTurns: turns.attempted,
            completedTurns: turns.completed,
            retriedTurns: turns.retried,
            retryRate: ratio(turns.retried, turns.attempted),
            completedTurnRate: ratio(turns.completed, turns.attempted),
            resolvedTurns: reliability.resolved,
            firstAttemptDeliveredTurns: reliability.firstAttemptDelivered,
            resolvedRetriedTurns: reliability.retried,
            retriedTurnsRecovered: reliability.recovered,
            resolvedAttemptSuccessRate: ratio(mix.succeeded, mix.succeeded + mix.failed),
            attemptsPerCompletedTurn: ratio(turns.attemptsOnCompletedTurns, turns.completed),
            threadsWithUsage: Set(items.compactMap { $0.record.conversationID }).count,
            outcomeMix: mix,
            tokens: tokens(for: items),
            responseTime: responseTime(for: items),
            truncatedReplies: items.count(where: { $0.isTruncated }),
            activity: activity(for: items, range: activityRange, calendar: calendar),
            tokenMeasuredAttempts: items.count(where: { bestAvailableTokens($0) != nil }),
            byGateway: gatewayGroups(for: items),
            byRequestedModel: modelGroups(for: items),
            deviceGroups: deviceGroups(for: items),
            failureReasons: failureReasons(for: items),
            inputModes: inputModes(for: items),
            threadRanking: ranking,
            largestTurns: largestTurns(for: items, basis: ranking.basis),
            attachmentContext: attachmentContext(for: items)
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
        /// invent a sample at the boundary and drag the average toward it;
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

        /// What rode along with this request, or nil when the row predates the
        /// counting. NOT filtered by outcome: the counts are stamped at insert,
        /// so an attempt that never landed still measured what it carried.
        ///
        /// A row that carries SOME of the four columns answers with the ones it
        /// has and zero for the rest — a half-materialised mirrored row is
        /// partial evidence, not absent evidence. Negative values from a corrupt
        /// column floor at zero; a negative attachment count is meaningless and
        /// would silently subtract from a neighbouring row's real one.
        var attachmentCounts: (images: Int, addedImages: Int, textFiles: Int, replayedImages: Int)? {
            let current = record.currentTurnInlineImageCount
            let prior = record.priorTurnInlineImageCount
            let currentFiles = record.currentTurnInlineTextFileCount
            let priorFiles = record.priorTurnInlineTextFileCount
            guard current != nil || prior != nil || currentFiles != nil || priorFiles != nil
            else { return nil }
            let priorImages = max(0, prior ?? 0)
            let addedImages = max(0, current ?? 0)
            // `images` is the payload total (added + replayed) — right for the
            // per-turn/thread rows, which explain what a request cost to carry.
            // `addedImages` is the user-action count the image-history card
            // uses, so a turn that only replayed history never reads as one
            // the user attached an image to.
            return (
                images: addedImages + priorImages,
                addedImages: addedImages,
                textFiles: max(0, currentFiles ?? 0) + max(0, priorFiles ?? 0),
                replayedImages: priorImages
            )
        }
    }

    /// Attempt order WITHIN one turn or thread: by start instant, then by id so
    /// two rows stamped in the same millisecond still order the same way on
    /// every device. A row with no start instant sorts LAST — it cannot be
    /// claimed to have been the first try, and treating it as the final one
    /// keeps a turn it belongs to from being called resolved on the strength of
    /// an earlier row.
    private static func chronological(_ lhs: Classified, _ rhs: Classified) -> Bool {
        let left = lhs.record.startedAt ?? .distantFuture
        let right = rhs.record.startedAt ?? .distantFuture
        if left != right { return left < right }
        return lhs.record.id.uuidString < rhs.record.id.uuidString
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

    /// Reliability over turns whose story is FINISHED. A turn is resolved when
    /// its final attempt — the latest one that started — reached a stored
    /// terminal outcome; everything below divides by that population.
    ///
    /// Deliberately NOT `turnCounts.retried`, which counts every attempted turn
    /// with a retry. Recovery divided by that number would count a turn still
    /// being retried as a retry that failed to recover, and the figure would
    /// improve on its own as unrelated rows landed.
    private static func turnReliability(
        for items: [Classified]
    ) -> (firstAttemptDelivered: Int, resolved: Int, retried: Int, recovered: Int) {
        var byTurn: [UUID: [Classified]] = [:]
        for item in items {
            guard let turn = item.record.userMessageID else { continue }
            byTurn[turn, default: []].append(item)
        }

        var firstAttemptDelivered = 0, resolved = 0, retried = 0, recovered = 0
        for (_, rows) in byTurn {
            let ordered = rows.sorted(by: chronological)
            guard let first = ordered.first, let last = ordered.last, last.isResolved
            else { continue }
            resolved += 1
            if first.isSucceeded { firstAttemptDelivered += 1 }
            if ordered.count > 1 {
                retried += 1
                if last.isSucceeded { recovered += 1 }
            }
        }
        return (firstAttemptDelivered, resolved, retried, recovered)
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
            reportedTotal: tokenField(resolved) { $0.record.reportedTotalTokens },
            // SAME helper, SAME terminal-attempt denominator. A detail field
            // measured against its own narrower population would read as better
            // covered than the figure it is a part of.
            cachedInput: tokenField(resolved) { $0.record.reportedCachedInputTokens },
            cacheWriteInput: tokenField(resolved) { $0.record.reportedCacheWriteInputTokens },
            reasoningOutput: tokenField(resolved) { $0.record.reportedReasoningOutputTokens }
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
            p90: samples.count >= p90MinimumSamples
                ? quantile(sorted: samples, probability: 0.9)
                : nil,
            mean: samples.reduce(0, +) / Double(samples.count)
        )
    }

    // MARK: - Activity buckets

    /// Dense period buckets across `range`, or across the observed days when no
    /// range is given. Attempts with no `startedAt` are counted in the range
    /// totals but land in no bucket: a row that cannot say when it began cannot
    /// be drawn on a date axis, and assigning it to "today" would move a bar
    /// that describes a period it has nothing to do with.
    ///
    /// A period is chosen by the attempt's START, so every metric on a bucket is
    /// "work begun in that period" — a turn dispatched before midnight and
    /// answered after it belongs to the day the user asked, which is the day
    /// they remember.
    ///
    /// COMPUTED FROM THE RECORDS, NEVER BY SUMMING DAILY BUCKETS. A week's turn
    /// count is its distinct `userMessageID`s, which is strictly less than the
    /// sum of its days' turn counts whenever a turn was retried across
    /// midnight; folding day totals would silently inflate it.
    private static func activity(
        for items: [Classified],
        range: ClosedRange<Date>?,
        calendar: Calendar
    ) -> GatewayUsageActivity {
        // Whole days either side, exactly as the daily buckets always did: a
        // window is a set of calendar days, and a bar that started three hours
        // into its first one would be short for a reason no reader can see.
        let firstDay: Date
        let lastDay: Date
        let coverageEnd: Date
        if let range {
            firstDay = calendar.startOfDay(for: range.lowerBound)
            lastDay = calendar.startOfDay(for: range.upperBound)
            // The REQUESTED end, not the end of its day: it is what makes the
            // trailing period "still running" rather than complete, and a
            // period rounded up to midnight would claim hours that have not
            // happened.
            coverageEnd = range.upperBound
        } else {
            let observed = items.compactMap { $0.record.startedAt }
                .map { calendar.startOfDay(for: $0) }
            guard let earliest = observed.min(), let latest = observed.max() else {
                return .empty
            }
            firstDay = earliest
            lastDay = latest
            // No window was asked for, so the last observed day is complete as
            // far as anything here can tell — nothing claims it is still going.
            coverageEnd = calendar.date(byAdding: .day, value: 1, to: latest)
                .map { calendar.startOfDay(for: $0) } ?? latest
        }
        guard firstDay <= lastDay else { return .empty }

        let unit = self.unit(from: firstDay, to: lastDay, calendar: calendar)

        // One pass over the records, keyed on the CLIPPED period start so the
        // lookup key and the bucket's own identity are the same value.
        var attemptsPer: [Date: Int] = [:]
        var turnsPer: [Date: Set<UUID>] = [:]
        var succeededTurnsPer: [Date: Set<UUID>] = [:]
        var failedTurnsPer: [Date: Set<UUID>] = [:]
        var resolvedPer: [Date: Int] = [:]
        var succeededPer: [Date: Int] = [:]
        var tokensPer: [Date: Int64] = [:]
        var tokenAttemptsPer: [Date: Int] = [:]
        var devicesPer: [Date: [String?: Int]] = [:]
        var gatewaysPer: [Date: [String?: Int]] = [:]
        var modelsPer: [Date: [String?: Int]] = [:]
        for item in items {
            guard let startedAt = item.record.startedAt,
                  startedAt >= firstDay,
                  calendar.startOfDay(for: startedAt) <= lastDay,
                  let interval = calendar.dateInterval(of: unit.component, for: startedAt)
            else { continue }
            let key = max(interval.start, firstDay)
            attemptsPer[key, default: 0] += 1
            if let turn = item.record.userMessageID {
                turnsPer[key, default: []].insert(turn)
            }
            // Succeeded and failed ONLY — see `resolvedAttempts`. A cancelled
            // or unclassifiable landing is neither a win nor a loss, and
            // letting it into the denominator would draw a bar that reads as a
            // bad period when nothing bad happened.
            if let outcome = item.storedOutcome, outcome == .succeeded || outcome == .failed {
                resolvedPer[key, default: 0] += 1
                if outcome == .succeeded { succeededPer[key, default: 0] += 1 }
                // The same two outcomes lifted to the TURN: a turn is judged
                // from this period's own attempts, and a failed set that later
                // proves to contain a success is corrected at emission.
                if let turn = item.record.userMessageID {
                    if outcome == .succeeded {
                        succeededTurnsPer[key, default: []].insert(turn)
                    } else {
                        failedTurnsPer[key, default: []].insert(turn)
                    }
                }
            }
            if let tokens = bestAvailableTokens(item) {
                tokenAttemptsPer[key, default: 0] += 1
                tokensPer[key] = saturatingSum(tokensPer[key] ?? 0, tokens)
            }
            let device = UsageDeviceBucket.from(record: item.record)
            // The unattributed device becomes the SAME nil key the gateway
            // split uses for its unattributed slot, so one piece of chart code
            // reads both dimensions under one rule.
            devicesPer[key, default: [:]][device == .unknown ? nil : device.rawValue, default: 0] += 1
            gatewaysPer[key, default: [:]][item.record.gatewayRef, default: 0] += 1
            modelsPer[key, default: [:]][item.record.requestedModel, default: 0] += 1
        }

        var buckets: [GatewayUsageActivityBucket] = []
        var cursor = firstDay
        while cursor <= lastDay && buckets.count < maxActivityBuckets {
            // `dateInterval` rather than a hand-rolled walk: it re-anchors on
            // every step, so a zone whose DST transition lands AT midnight
            // (America/Santiago, Asia/Beirut) — where `startOfDay` for the
            // transition date is 01:00 — still produces one bucket per local
            // period. Fixed 86400-second arithmetic drifts the same way on
            // every transition, midnight or not.
            guard let interval = calendar.dateInterval(of: unit.component, for: cursor),
                  interval.end > cursor
            else { break }
            let start = max(interval.start, firstDay)
            let end = min(interval.end, coverageEnd)
            buckets.append(
                GatewayUsageActivityBucket(
                    periodStart: start,
                    periodEnd: max(end, start),
                    startsMidPeriod: interval.start < start,
                    endsMidPeriod: interval.end > end,
                    attempts: attemptsPer[start] ?? 0,
                    turns: turnsPer[start]?.count ?? 0,
                    completedTurns: succeededTurnsPer[start]?.count ?? 0,
                    failedTurns: failedTurnsPer[start]?
                        .subtracting(succeededTurnsPer[start] ?? []).count ?? 0,
                    resolvedAttempts: resolvedPer[start] ?? 0,
                    succeededAttempts: succeededPer[start] ?? 0,
                    reportedTokens: Int(clamping: tokensPer[start] ?? 0),
                    tokenMeasuredAttempts: tokenAttemptsPer[start] ?? 0,
                    deviceAttempts: devicesPer[start] ?? [:],
                    gatewayAttempts: gatewaysPer[start] ?? [:],
                    modelAttempts: modelsPer[start] ?? [:]
                )
            )
            cursor = interval.end
        }
        return GatewayUsageActivity(unit: unit, buckets: buckets)
    }

    /// THE FINEST UNIT THAT STILL DRAWS AS A SHAPE. Days while there are few
    /// enough of them, then weeks, then months — one rule rather than a table
    /// keyed off the range picker, so `.all` over a two-year ledger and a
    /// hypothetical future range land on the same answer for the same reason.
    ///
    /// Months are the floor: there is no coarser unit, so a decade-long ledger
    /// exceeds `maxActivityBars` and is bounded by `maxActivityBuckets` instead.
    static func unit(from firstDay: Date, to lastDay: Date, calendar: Calendar) -> UsageActivityUnit {
        func spans(_ component: Calendar.Component) -> Int {
            guard let first = calendar.dateInterval(of: component, for: firstDay),
                  let last = calendar.dateInterval(of: component, for: lastDay)
            else { return Int.max }
            let steps = calendar.dateComponents(
                [component], from: first.start, to: last.start
            ).value(for: component) ?? Int.max
            return steps == Int.max ? Int.max : steps + 1
        }
        if spans(.day) <= maxActivityBars { return .day }
        if spans(.weekOfYear) <= maxActivityBars { return .week }
        return .month
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
        let samples = members.compactMap { $0.responseSample }
        return GatewayUsageGroup(
            key: key,
            attempts: members.count,
            succeeded: mix.succeeded,
            failed: mix.failed,
            successRate: ratio(mix.succeeded, mix.succeeded + mix.failed),
            meanResponseTime: samples.isEmpty
                ? nil
                : samples.reduce(0, +) / Double(samples.count),
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

    /// Same group shape as the gateway rows, keyed by bucket raw value, so the
    /// device rows and the gateway rows draw through one view.
    private static func deviceGroups(for items: [Classified]) -> [GatewayUsageGroup] {
        grouped(items, by: { UsageDeviceBucket.from(record: $0.record).rawValue })
            .map { group(key: $0.key, members: $0.value, models: []) }
            .sorted(by: rank)
    }

    // MARK: - Failure reasons and input modes

    /// FAILED attempts only, by Conduck's own error code. A failure whose code
    /// was never recorded is left out rather than bucketed as an unnamed
    /// reason: the list exists to be read as reasons, and a nameless row would
    /// be the largest bucket on any older range while explaining nothing.
    private static func failureReasons(for items: [Classified]) -> [FailureReasonCount] {
        var counts: [Int: Int] = [:]
        for item in items {
            guard item.storedOutcome == .failed, let code = item.record.appErrorCode
            else { continue }
            counts[code, default: 0] += 1
        }
        return counts
            .map { FailureReasonCount(appErrorCode: $0.key, count: $0.value) }
            .sorted {
                $0.count != $1.count ? $0.count > $1.count : $0.appErrorCode < $1.appErrorCode
            }
    }

    /// Every mode that appears, `unknown` included — a range whose turns mostly
    /// predate mode capture must SAY so rather than have its known modes add up
    /// to a whole they are not.
    private static func inputModes(for items: [Classified]) -> [InputModeSlice] {
        var attempts: [GatewayInputMode: Int] = [:]
        var turns: [GatewayInputMode: Set<UUID>] = [:]
        for item in items {
            let mode = item.record.inputMode
            attempts[mode, default: 0] += 1
            if let turn = item.record.userMessageID { turns[mode, default: []].insert(turn) }
        }
        return attempts
            .map {
                InputModeSlice(mode: $0.key, attempts: $0.value, turns: turns[$0.key]?.count ?? 0)
            }
            .sorted {
                $0.attempts != $1.attempts
                    ? $0.attempts > $1.attempts
                    : $0.mode.rawValue < $1.mode.rawValue
            }
    }

    // MARK: - Ranking basis

    /// What one attempt contributes under a basis, or nil when it cannot answer
    /// under that basis at all.
    ///
    /// TERMINAL ROWS ONLY, exactly as the token fields above: a row that has not
    /// ended has not had its chance to report, and letting an open row
    /// contribute would make a thread's rank change without any new work
    /// happening.
    private static func tokenContribution(
        _ item: Classified,
        basis: ThreadRanking.Basis
    ) -> Int64? {
        guard item.isResolved else { return nil }
        switch basis {
        case .reportedTotals:
            return item.record.reportedTotalTokens
        case .calculatedComponents:
            // BOTH components, never one: ranking a thread's input-only sum
            // against another's input+output would order them by which gateway
            // is chattier about its own accounting.
            guard let input = item.record.reportedInputTokens,
                  let output = item.record.reportedOutputTokens
            else { return nil }
            return saturatingSum(input, output)
        }
    }

    /// What ONE attempt can say about its own token cost, best evidence first:
    /// the gateway's reported total, else its input + output when both are
    /// present, else nothing. Nil means the attempt reported nothing usable —
    /// never zero, which would claim a free turn.
    ///
    /// Same preference order, and the same terminal-only gate, that
    /// `GatewayUsageTokens.calculatedKnownComponents` applies to a whole range:
    /// a client-computed sum is what you fall back to when no total was
    /// reported, never a thing you prefer. The difference is scope — this
    /// answers per attempt, so a range where some gateways total and others do
    /// not can still draw a day's volume instead of drawing nothing.
    ///
    /// FOR VOLUMES ONLY, never for ranking: `tokenContribution` with a single
    /// pinned basis is what orders threads and turns, precisely so one thread's
    /// reported total is never ranked against another's client sum.
    private static func bestAvailableTokens(_ item: Classified) -> Int64? {
        tokenContribution(item, basis: .reportedTotals)
            ?? tokenContribution(item, basis: .calculatedComponents)
    }

    /// ONE basis for the whole range, or nil when nothing can be ranked.
    /// Gateway-reported totals win wherever any thread has one — a client sum
    /// is a fallback for ranges no gateway totalled, never a per-thread
    /// alternative.
    ///
    /// Only rows that name a conversation are consulted: a basis chosen from
    /// unattributable rows would caption a list those rows can never appear in.
    private static func rankingBasis<S: Sequence>(
        for attributed: S
    ) -> ThreadRanking.Basis? where S.Element == Classified {
        if attributed.contains(where: { tokenContribution($0, basis: .reportedTotals) != nil }) {
            return .reportedTotals
        }
        if attributed.contains(where: {
            tokenContribution($0, basis: .calculatedComponents) != nil
        }) {
            return .calculatedComponents
        }
        return nil
    }

    // MARK: - Heaviest threads

    private static func threadRanking(for items: [Classified]) -> ThreadRanking {
        // Rows with no conversation are real attempts and count in every total
        // above; they simply cannot be attributed to a thread, and inventing a
        // thread for them would put a row on screen nothing can navigate to.
        var byThread: [UUID: [Classified]] = [:]
        for item in items {
            guard let conversation = item.record.conversationID else { continue }
            byThread[conversation, default: []].append(item)
        }
        // Lazily flattened: the basis question short-circuits on the first row
        // that can answer it, so a 100k-row range never materialises a copy.
        guard let basis = rankingBasis(for: byThread.values.lazy.flatMap({ $0 }))
        else { return .empty }

        let threads = byThread.compactMap { conversation, rows in
            threadUsage(conversation: conversation, rows: rows, basis: basis)
        }
        .sorted(by: heaviestFirst)
        .prefix(maxRankedThreads)

        return ThreadRanking(basis: basis, threads: Array(threads))
    }

    /// One thread's row, or nil when it cannot be ranked under this basis —
    /// nothing reported, or no attempt that can say when it ran.
    private static func threadUsage(
        conversation: UUID,
        rows: [Classified],
        basis: ThreadRanking.Basis
    ) -> ThreadUsage? {
        let ordered = rows.sorted(by: chronological)
        let starts = ordered.compactMap { $0.record.startedAt }
        guard let earliest = starts.first, let latest = starts.last else { return nil }

        var refs: [String?] = []
        var tokens: Int64 = 0
        var reported = false
        var reportedTurns: Set<UUID> = []
        var turns: Set<UUID> = []
        var images = 0, textFiles = 0, measured = 0

        for item in ordered {
            if !refs.contains(where: { $0 == item.record.gatewayRef }) {
                refs.append(item.record.gatewayRef)
            }
            if let turn = item.record.userMessageID { turns.insert(turn) }
            if let contribution = tokenContribution(item, basis: basis) {
                reported = true
                tokens = saturatingSum(tokens, contribution)
                if let turn = item.record.userMessageID { reportedTurns.insert(turn) }
            }
            if let counts = item.attachmentCounts {
                measured += 1
                images += counts.images
                textFiles += counts.textFiles
            }
        }
        guard reported else { return nil }

        return ThreadUsage(
            conversationID: conversation,
            earliestStart: earliest,
            latestStart: latest,
            gatewayRefs: refs,
            attempts: ordered.count,
            turns: turns.count,
            rankedTokens: Int(clamping: tokens),
            tokenReportedTurns: reportedTurns.count,
            inlineImageCount: measured > 0 ? images : nil,
            inlineTextFileCount: measured > 0 ? textFiles : nil,
            attachmentMeasuredAttempts: measured
        )
    }

    /// Heaviest first, then most recent, then on the id — so a redraw of two
    /// equally heavy threads never reshuffles them under the user's finger.
    private static func heaviestFirst(_ lhs: ThreadUsage, _ rhs: ThreadUsage) -> Bool {
        if lhs.rankedTokens != rhs.rankedTokens { return lhs.rankedTokens > rhs.rankedTokens }
        if lhs.latestStart != rhs.latestStart { return lhs.latestStart > rhs.latestStart }
        return lhs.conversationID.uuidString < rhs.conversationID.uuidString
    }

    // MARK: - Largest turns

    /// The heaviest individual turns under the SAME basis the thread list used,
    /// so a turn's figure and its thread's figure are the same kind of number.
    /// A turn needs both a conversation and a start instant: the row navigates,
    /// and it draws a date.
    private static func largestTurns(
        for items: [Classified],
        basis: ThreadRanking.Basis
    ) -> [TurnOutlier] {
        var byTurn: [UUID: [Classified]] = [:]
        for item in items {
            guard item.record.conversationID != nil, let turn = item.record.userMessageID
            else { continue }
            byTurn[turn, default: []].append(item)
        }

        let outliers = byTurn.compactMap { turn, rows -> TurnOutlier? in
            let ordered = rows.sorted(by: chronological)
            guard let first = ordered.first(where: { $0.record.startedAt != nil }),
                  let startedAt = first.record.startedAt,
                  let conversation = first.record.conversationID
            else { return nil }

            var tokens: Int64 = 0
            var reported = false
            var images = 0, textFiles = 0, measured = 0
            for item in ordered {
                if let contribution = tokenContribution(item, basis: basis) {
                    reported = true
                    tokens = saturatingSum(tokens, contribution)
                }
                if let counts = item.attachmentCounts {
                    measured += 1
                    images += counts.images
                    textFiles += counts.textFiles
                }
            }
            guard reported else { return nil }

            return TurnOutlier(
                conversationID: conversation,
                userMessageID: turn,
                startedAt: startedAt,
                gatewayRef: first.record.gatewayRef,
                tokens: Int(clamping: tokens),
                basis: basis,
                inlineImageCount: measured > 0 ? images : nil,
                inlineTextFileCount: measured > 0 ? textFiles : nil
            )
        }
        .sorted { lhs, rhs in
            if lhs.tokens != rhs.tokens { return lhs.tokens > rhs.tokens }
            if lhs.startedAt != rhs.startedAt { return lhs.startedAt > rhs.startedAt }
            return lhs.userMessageID.uuidString < rhs.userMessageID.uuidString
        }
        .prefix(maxLargestTurns)

        return Array(outliers)
    }

    // MARK: - Attachment context

    /// Coverage here is over ALL recorded attempts, not the terminal subset the
    /// token fields use, because the counts are stamped when the row opens: an
    /// attempt that never landed still measured what it carried.
    private static func attachmentContext(for items: [Classified]) -> AttachmentContext {
        var measured = 0
        var replayed = 0
        var turnsWithImages: Set<UUID> = []
        var turnsWithTextFiles: Set<UUID> = []
        for item in items {
            guard let counts = item.attachmentCounts else { continue }
            measured += 1
            replayed += counts.replayedImages
            // An unattributed row's attachments are counted in `measured` and in
            // no turn — there is no turn to count it as.
            guard let turn = item.record.userMessageID else { continue }
            if counts.addedImages > 0 { turnsWithImages.insert(turn) }
            if counts.textFiles > 0 { turnsWithTextFiles.insert(turn) }
        }
        return AttachmentContext(
            measuredAttempts: measured,
            turnsWithImages: turnsWithImages.count,
            turnsWithTextFiles: turnsWithTextFiles.count,
            replayedImageTotal: replayed
        )
    }
}
