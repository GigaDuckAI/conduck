// SPDX-License-Identifier: Apache-2.0

// Conduck
// GatewayAttemptRecord.swift
//
// The domain vocabulary of the gateway-attempt ledger: what a transport hands
// the store before it dispatches (`GatewayAttemptDraft`), what it gets back to
// carry until the turn lands (`GatewayAttemptContext`), what it reports when
// the turn does land (`TerminalAttemptObservation`), and the `Sendable`
// snapshot the dashboard reads (`GatewayAttemptRecord`), mirroring
// `MessageRecord`'s KVC-tolerant `init(managedObject:)` for the same reason —
// every column in a CloudKit-mirrored model is optional, so every read here is
// nil-tolerant by construction.
//
// THE LEDGER IS CONTENT-FREE, AND THAT IS RELEASE-BLOCKING. It measures the
// `/v1/chat/completions` hop and nothing inside it: no prompt or reply text, no
// URL, host, token or display name, no provider error string, no HTTP status.
// `gatewayRef` is a `RemoteAgentRef.rawString` — the SLOT the user configured,
// never the endpoint behind it. The only strings that come off the wire arrive
// through `GatewayResponseMetadata`, already bounded and scanned there.
//
// THREE OF THE TOKEN COLUMNS ARE SUBSETS OF THE OTHERS, AND NOTHING MAY ADD
// THEM INTO A TOTAL. `reportedCachedInputTokens` and
// `reportedCacheWriteInputTokens` are parts of `reportedInputTokens`;
// `reportedReasoningOutputTokens` is part of `reportedOutputTokens`. Containment
// is documented and never enforced — a gateway reporting more cached input than
// input is stored exactly as it said, the same way an inconsistent
// `reportedTotalTokens` is — and nil on any of the three means the gateway
// reported nothing there, which no backfill will ever change.
//
// ONE DERIVATION LIVES HERE AND NOWHERE ELSE: an attempt's EFFECTIVE outcome.
// A row whose stored outcome is still `inFlight` is not evidence that a turn is
// running — attempts sync across devices while `URLSession` registries are
// device-local, so a Mac looking at an iPhone's live row can see only that it
// has no local task for it. Deriving `pending`/`unconfirmed` at read time is
// what keeps that ignorance from being written down, where it would race a
// later real success. Nothing in this file writes anything.
//
// IN the Watch target (pbxproj membership exception): the wrist uploader builds
// its own draft and its own terminal observation.

import Foundation
import CoreData

// MARK: - Closed vocabularies

/// What became of one dispatch. `inFlight` is the only non-terminal value and
/// the only one an insert ever writes; every attempt makes at most ONE terminal
/// transition out of it.
///
/// None of the terminal values claims anything about the gateway's side of the
/// hop: `failed` means Conduck observed a failure, not that the gateway did no
/// work, and `cancelled` means a user or a live lane stopped waiting, not that
/// nothing was generated or billed.
nonisolated enum GatewayAttemptOutcome: String, Sendable, Hashable, CaseIterable {
    /// Dispatched, no terminal callback yet.
    case inFlight
    /// A reply landed and the strict decoder accepted it.
    case succeeded
    /// A terminal failure was observed or classified.
    case failed
    /// An explicit user or live-lane cancellation.
    case cancelled
    /// An authoritative transport owner reached a terminal callback and could
    /// NOT classify it — a relaunched process seeing a cancellation whose live
    /// claim died with the old one, for instance. Distinct from the DERIVED
    /// `unconfirmed` below, which means only that this device lacks evidence
    /// and never reaches storage.
    case unknown

    /// Decode a stored value. An unrecognised string — a newer client's
    /// vocabulary arriving over CloudKit, a corrupt row — decodes as `unknown`
    /// rather than crashing or being silently dropped, because the row still
    /// counts as an attempt that happened.
    ///
    /// A nil raw value decodes as `unknown` too: every insert stamps
    /// `inFlight`, so a row with no outcome at all is a partially-materialised
    /// record, not a live turn, and treating it as live would leave it forever
    /// hedged.
    static func from(raw: String?) -> GatewayAttemptOutcome {
        guard let raw, let outcome = GatewayAttemptOutcome(rawValue: raw) else { return .unknown }
        return outcome
    }

    /// Whether this value ends the attempt. Only `inFlight` does not.
    var isTerminal: Bool { self != .inFlight }
}

/// The user-facing surface the attempt actually ran from — which is the surface
/// running a RETRY, not the surface that produced the original turn. A retry
/// tapped in the main app is `app` however the turn was first spoken.
///
/// Dedicated surfaces win over workflow names: the wrist is `watch`, the head
/// unit is `carPlay`, a share sheet is `share`, the macOS popover and hotkey
/// are `menuBar`. `quickCapture` is reserved for iPhone/iPad App Intent,
/// Shortcut and Action-Button dispatch.
nonisolated enum GatewayAttemptOrigin: String, Sendable, Hashable, CaseIterable {
    case app
    case quickCapture
    case menuBar
    case share
    case watch
    case carPlay
    case unknown

    static func from(raw: String?) -> GatewayAttemptOrigin {
        guard let raw, let origin = GatewayAttemptOrigin(rawValue: raw) else { return .unknown }
        return origin
    }
}

/// How the ORIGINAL user turn was acquired — not how the retry was triggered,
/// because a retry creates no new input.
nonisolated enum GatewayInputMode: String, Sendable, Hashable, CaseIterable {
    case text
    case voice
    /// Text, images or files handed over by a share sheet, in any combination.
    case shared
    case unknown

    static func from(raw: String?) -> GatewayInputMode {
        guard let raw, let mode = GatewayInputMode(rawValue: raw) else { return .unknown }
        return mode
    }

    /// THE SOLE DERIVATION POINT for a retry's input mode, read off the failed
    /// turn's `Message.sourceDevice` tag.
    ///
    /// The tag is `<device>` or `<device>-<modality>` (`iphone-text`,
    /// `mac-voice`, `watch-voice`), split on the FIRST dash exactly as
    /// `MessageRowFormatters.baseDevice` splits it, so the device half is
    /// irrelevant here and only the suffix decides. A legacy tag with no suffix
    /// yields `unknown`, which is the honest answer: nothing recorded how that
    /// turn was typed or spoken.
    ///
    /// A SHARE-ORIGIN TURN ALSO YIELDS `unknown` TODAY, and that is not an
    /// oversight to fix here. The share lane stamps the plain device tag, so
    /// the suffix cannot tell a shared turn from a typed one; the lane passes
    /// `.shared` EXPLICITLY at dispatch, and this helper only ever runs as the
    /// retry fallback. The `shared` suffix is recognised so that a tag carrying
    /// one lands correctly rather than silently as `unknown`.
    static func from(sourceDevice: String) -> GatewayInputMode {
        guard let dash = sourceDevice.firstIndex(of: "-") else { return .unknown }
        return from(raw: String(sourceDevice[sourceDevice.index(after: dash)...]))
    }
}

/// The kind of hardware a dispatch ran on, as the ledger spells it. The stored
/// column carries the raw string rather than this type, so an older client
/// reading a newer client's row sees an unrecognised word and not a decode
/// failure; this enum is only the vocabulary and the ONE parse point.
///
/// `carplay` is parseable but never stamped: a CarPlay dispatch runs on the
/// iPhone and stamps `iphone`, and the CarPlay bucket is derived from
/// `originSurface` at read time. The word is recognised so that a legacy
/// `Message.sourceDevice` tag carrying it lands as CarPlay rather than as
/// nothing.
nonisolated enum GatewayAttemptDeviceClass: String, Sendable, Hashable, CaseIterable {
    case iphone
    case ipad
    case mac
    case watch
    case carplay

    /// THE SOLE DERIVATION POINT for a device class read off a
    /// `Message.sourceDevice` tag, mirroring `GatewayInputMode.from(sourceDevice:)`
    /// on the other half of the same tag.
    ///
    /// The tag is `<device>` or `<device>-<modality>`, split on the FIRST dash
    /// exactly as `MessageRowFormatters.baseDevice` splits it, so only the base
    /// word decides. An unrecognised word — a future device, a corrupt tag —
    /// yields nil, which is the honest answer: nothing here says what ran the
    /// turn, and guessing would put a real attempt in a bucket it never came
    /// from.
    static func from(sourceDevice: String?) -> String? {
        guard let sourceDevice else { return nil }
        let base = sourceDevice.prefix(while: { $0 != "-" })
        return GatewayAttemptDeviceClass(rawValue: String(base))?.rawValue
    }
}

// MARK: - Dispatch-time carriers

/// Everything the store needs to open an attempt row, assembled by the
/// transport immediately before it dispatches.
///
/// `attemptID` is a CANDIDATE: the transport mints it so it can be pre-encoded
/// into the background task's metadata before the row exists, and the row is
/// only ever opened once. If the insert fails, the id is simply never used —
/// capture is fail-open, so a dispatch always outranks its own measurement.
nonisolated struct GatewayAttemptDraft: Sendable, Hashable {
    let attemptID: UUID
    let conversationID: UUID
    let userMessageID: UUID
    /// `RemoteAgentRef.rawString` — `openclaw` / `hermes` / `openrouter` /
    /// `custom_<uuid>`. NEVER a URL, host, token or display label; the slot's
    /// name is resolved for display at render time, from settings.
    let gatewayRef: String
    let origin: GatewayAttemptOrigin
    let inputMode: GatewayInputMode
    /// The exact model value sent, or nil when the request carried none and the
    /// gateway's own default answered. Snapshotted because the setting it came
    /// from can change afterwards.
    let requestedModel: String?
    /// The device executing THIS dispatch, as a `GatewayAttemptDeviceClass` raw
    /// value — the RETRY device on a retry, never the device that produced the
    /// original turn. A CarPlay dispatch stamps `iphone`, because that is the
    /// hardware doing the work; `origin` already carries the surface. Nil when
    /// the transport had nothing to stamp, which reads as unmeasured rather
    /// than as an unknown device.
    let deviceClass: String?
    /// `image_url` parts belonging to the CURRENT user turn on this request,
    /// counted after final assembly so it measures what actually went out.
    let currentTurnInlineImageCount: Int
    /// Prior-turn `image_url` parts riding along on THIS request, after policy,
    /// compatibility and trimming decided how much history to replay.
    let priorTurnInlineImageCount: Int
    /// Text-file blocks actually spliced into the current turn. A failed
    /// extraction, an unavailable notice, and a file left as a server-side
    /// reference are all not inline and do not count; a file sent both ways
    /// counts once, here.
    let currentTurnInlineTextFileCount: Int
    /// Prior-turn text-file blocks re-spliced into THIS request.
    let priorTurnInlineTextFileCount: Int

    init(
        attemptID: UUID,
        conversationID: UUID,
        userMessageID: UUID,
        gatewayRef: String,
        origin: GatewayAttemptOrigin,
        inputMode: GatewayInputMode,
        requestedModel: String? = nil,
        deviceClass: String? = nil,
        currentTurnInlineImageCount: Int = 0,
        priorTurnInlineImageCount: Int = 0,
        currentTurnInlineTextFileCount: Int = 0,
        priorTurnInlineTextFileCount: Int = 0
    ) {
        self.attemptID = attemptID
        self.conversationID = conversationID
        self.userMessageID = userMessageID
        self.gatewayRef = gatewayRef
        self.origin = origin
        self.inputMode = inputMode
        self.requestedModel = requestedModel
        self.deviceClass = deviceClass
        self.currentTurnInlineImageCount = currentTurnInlineImageCount
        self.priorTurnInlineImageCount = priorTurnInlineImageCount
        self.currentTurnInlineTextFileCount = currentTurnInlineTextFileCount
        self.priorTurnInlineTextFileCount = priorTurnInlineTextFileCount
    }
}

/// What a successful open hands back: the identity the row was stored under and
/// the instant it was stamped with. The transport carries it until the turn
/// lands, then names it in the terminal observation.
nonisolated struct GatewayAttemptContext: Sendable, Hashable {
    let attemptID: UUID
    let startedAt: Date
}

/// What a transport saw at the terminal boundary, captured BEFORE any async
/// landing work — `completedAt` in particular is stamped at the top of the
/// callback, so the elapsed time it closes measures the hop and not the
/// persistence that follows it.
///
/// `attemptID` is optional because a landing can be legitimately attempt-less:
/// a task dispatched by an older build carries no id in its metadata, and it
/// must land exactly as it always did, creating no row retroactively.
nonisolated struct TerminalAttemptObservation: Sendable {
    let attemptID: UUID?
    let completedAt: Date
    /// One of `succeeded` / `failed` / `cancelled` / `unknown`. Never
    /// `inFlight` — an observation exists because the attempt ended.
    let outcome: GatewayAttemptOutcome
    /// Conduck's own `AppError.errorCode` on a classified failure. Never a raw
    /// server code, status or message.
    let appErrorCode: Int?
    /// What the response body reported, when there was a body to read. Present
    /// on non-2xx landings too: a gateway can bill for work it failed to
    /// return.
    let metadata: GatewayResponseMetadata?

    init(
        attemptID: UUID?,
        completedAt: Date,
        outcome: GatewayAttemptOutcome,
        appErrorCode: Int? = nil,
        metadata: GatewayResponseMetadata? = nil
    ) {
        self.attemptID = attemptID
        self.completedAt = completedAt
        self.outcome = outcome
        self.appErrorCode = appErrorCode
        self.metadata = metadata
    }
}

// MARK: - Stored snapshot

/// A `Sendable` snapshot of one stored `GatewayAttempt`, decoupled from the
/// `NSManagedObject` so it crosses the `ConversationStore` actor boundary and
/// reaches `@MainActor` aggregation safely — the same contract `MessageRecord`
/// keeps, and the same defensive KVC reads, because every column in a
/// CloudKit-mirrored model is optional and a row can arrive half-materialised.
nonisolated struct GatewayAttemptRecord: Identifiable, Hashable, Sendable {
    /// What a NEW row's `recordVersion` is stamped with. It exists so a later
    /// client can change what an attempt MEANS — a different begin boundary, a
    /// different cancellation rule — without its rows mixing silently into an
    /// older client's totals.
    static let currentRecordVersion = 1

    let id: UUID
    /// The parent conversation at insertion time. Optional in storage, so a
    /// half-synced row can carry none — such a row is unattributable and the
    /// dashboard leaves it out rather than guessing.
    let conversationID: UUID?
    /// The user turn this attempt tried to deliver. Retries of one turn share
    /// it, which is how retry counts are derived; `wasRetry` is deliberately
    /// not stored.
    let userMessageID: UUID?
    /// `RemoteAgentRef.rawString`, the configured SLOT. Editing a custom slot
    /// can change its URL, auth and model while keeping the ref, so this groups
    /// by slot and never claims endpoint identity.
    let gatewayRef: String?
    /// Stamped at the final pre-transport boundary. Not proof that bytes
    /// crossed the wire — only that Conduck committed to sending.
    let startedAt: Date?
    /// Nil while the row is open, and nil forever on a row whose owner
    /// disappeared: a merely stale attempt is never stamped by anyone.
    let completedAt: Date?
    /// The STORED outcome. Read `effectiveOutcome(...)` for what to display —
    /// `inFlight` here means only that no terminal callback has been recorded.
    let outcome: GatewayAttemptOutcome
    /// `AppError.errorCode` on a failure. Kept per-attempt because the user
    /// message's own failure code is cleared by a later successful retry, which
    /// would otherwise erase the history of what went wrong.
    let appErrorCode: Int?
    let origin: GatewayAttemptOrigin
    let inputMode: GatewayInputMode
    let requestedModel: String?
    let reportedModel: String?
    let reportedResponseID: String?
    let finishReason: String?
    let reportedInputTokens: Int64?
    let reportedOutputTokens: Int64?
    let reportedTotalTokens: Int64?
    /// The three token-DETAIL columns, and the whole of what makes them
    /// different from the three above: each is a SUBSET of a figure already
    /// reported — cached and cache-write of the input, reasoning of the output.
    /// Nothing may add one into a total. Nil is the ordinary case: most gateways
    /// report none of them, and every row written before they existed carries
    /// nil forever, because there is no backfill.
    let reportedCachedInputTokens: Int64?
    let reportedCacheWriteInputTokens: Int64?
    let reportedReasoningOutputTokens: Int64?
    /// The measurement semantics the writing client used. Nil on a row written
    /// before the field existed.
    let recordVersion: Int?
    /// Whether the row actually CARRIED an outcome column. `outcome` reads
    /// `.unknown` when it did not, but absence is not a verdict: only a
    /// transport owner that reached a genuinely ambiguous terminal callback may
    /// persist `unknown` (research §6.5). A half-materialised row therefore
    /// derives `pending`/`unconfirmed` instead of passing itself off as an
    /// authoritative terminal answer no device ever gave.
    let hasStoredOutcome: Bool
    /// The device that ran this dispatch, as a `GatewayAttemptDeviceClass` raw
    /// value. Nil on a row written before the column existed, and on one whose
    /// transport had nothing to stamp — the dashboard falls back to
    /// `fallbackSourceDevice` and then to a "not recorded" bucket rather than
    /// guessing.
    let originDeviceClass: String?
    /// The four attachment counts are `Int?` for the reason the token columns
    /// are: nil is a row written before anything measured this, and an explicit
    /// 0 is a measured turn that carried nothing. Coverage captions are built
    /// on exactly that distinction, so collapsing them would claim every legacy
    /// row sent no attachments.
    let currentTurnInlineImageCount: Int?
    let priorTurnInlineImageCount: Int?
    let currentTurnInlineTextFileCount: Int?
    let priorTurnInlineTextFileCount: Int?
    /// The parent user turn's `Message.sourceDevice` tag, supplied by the STORE
    /// at fetch time and NEVER persisted on the attempt row — it is a read-time
    /// enrichment for rows that predate `originDeviceClass`, and the only field
    /// here that is not a column. A record built anywhere else leaves it nil,
    /// and nothing may write it back.
    var fallbackSourceDevice: String?

    init(
        id: UUID,
        conversationID: UUID?,
        userMessageID: UUID?,
        gatewayRef: String?,
        startedAt: Date?,
        completedAt: Date?,
        outcome: GatewayAttemptOutcome,
        appErrorCode: Int? = nil,
        origin: GatewayAttemptOrigin = .unknown,
        inputMode: GatewayInputMode = .unknown,
        requestedModel: String? = nil,
        reportedModel: String? = nil,
        reportedResponseID: String? = nil,
        finishReason: String? = nil,
        reportedInputTokens: Int64? = nil,
        reportedOutputTokens: Int64? = nil,
        reportedTotalTokens: Int64? = nil,
        reportedCachedInputTokens: Int64? = nil,
        reportedCacheWriteInputTokens: Int64? = nil,
        reportedReasoningOutputTokens: Int64? = nil,
        recordVersion: Int? = currentRecordVersion,
        hasStoredOutcome: Bool = true,
        originDeviceClass: String? = nil,
        currentTurnInlineImageCount: Int? = nil,
        priorTurnInlineImageCount: Int? = nil,
        currentTurnInlineTextFileCount: Int? = nil,
        priorTurnInlineTextFileCount: Int? = nil,
        fallbackSourceDevice: String? = nil
    ) {
        self.id = id
        self.conversationID = conversationID
        self.userMessageID = userMessageID
        self.gatewayRef = gatewayRef
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.outcome = outcome
        self.appErrorCode = appErrorCode
        self.origin = origin
        self.inputMode = inputMode
        self.requestedModel = requestedModel
        self.reportedModel = reportedModel
        self.reportedResponseID = reportedResponseID
        self.finishReason = finishReason
        self.reportedInputTokens = reportedInputTokens
        self.reportedOutputTokens = reportedOutputTokens
        self.reportedTotalTokens = reportedTotalTokens
        self.reportedCachedInputTokens = reportedCachedInputTokens
        self.reportedCacheWriteInputTokens = reportedCacheWriteInputTokens
        self.reportedReasoningOutputTokens = reportedReasoningOutputTokens
        self.recordVersion = recordVersion
        self.hasStoredOutcome = hasStoredOutcome
        self.originDeviceClass = originDeviceClass
        self.currentTurnInlineImageCount = currentTurnInlineImageCount
        self.priorTurnInlineImageCount = priorTurnInlineImageCount
        self.currentTurnInlineTextFileCount = currentTurnInlineTextFileCount
        self.priorTurnInlineTextFileCount = priorTurnInlineTextFileCount
        self.fallbackSourceDevice = fallbackSourceDevice
    }

    /// Defensive KVC read of a stored row. A missing `id` is replaced with a
    /// fresh one so the value stays `Identifiable`: a row that carries no
    /// identity can be counted but can never be matched against a live task or
    /// a later callback, and a fabricated id is no less unmatchable than nil
    /// while keeping every downstream type non-optional.
    ///
    /// The six `Integer 64` columns come through KVC as `NSNumber` because
    /// they are modelled non-scalar — which is the whole point: only an
    /// `NSNumber?` can tell a reported ZERO apart from NOTHING REPORTED, and a
    /// scalar column would read both as 0 and quietly claim every gateway
    /// reports its usage. The four `Integer 32` attachment columns are modelled
    /// non-scalar for the same reason, and `fallbackSourceDevice` is NOT read
    /// here — it lives on the parent turn, and only the store's fetch can reach
    /// it.
    init(managedObject: NSManagedObject) {
        self.id = (managedObject.value(forKey: "id") as? UUID) ?? UUID()
        self.conversationID = managedObject.value(forKey: "conversationID") as? UUID
        self.userMessageID = managedObject.value(forKey: "userMessageID") as? UUID
        self.gatewayRef = managedObject.value(forKey: "gatewayRef") as? String
        self.startedAt = managedObject.value(forKey: "startedAt") as? Date
        self.completedAt = managedObject.value(forKey: "completedAt") as? Date
        let storedOutcomeRaw = managedObject.value(forKey: "outcome") as? String
        self.outcome = GatewayAttemptOutcome.from(raw: storedOutcomeRaw)
        self.hasStoredOutcome = storedOutcomeRaw != nil
        self.appErrorCode = (managedObject.value(forKey: "appErrorCode") as? NSNumber)?.intValue
        self.origin = GatewayAttemptOrigin.from(
            raw: managedObject.value(forKey: "originSurface") as? String)
        self.inputMode = GatewayInputMode.from(
            raw: managedObject.value(forKey: "inputMode") as? String)
        self.requestedModel = managedObject.value(forKey: "requestedModel") as? String
        self.reportedModel = managedObject.value(forKey: "reportedModel") as? String
        self.reportedResponseID = managedObject.value(forKey: "reportedResponseID") as? String
        self.finishReason = managedObject.value(forKey: "finishReason") as? String
        self.reportedInputTokens =
            (managedObject.value(forKey: "reportedInputTokens") as? NSNumber)?.int64Value
        self.reportedOutputTokens =
            (managedObject.value(forKey: "reportedOutputTokens") as? NSNumber)?.int64Value
        self.reportedTotalTokens =
            (managedObject.value(forKey: "reportedTotalTokens") as? NSNumber)?.int64Value
        self.reportedCachedInputTokens =
            (managedObject.value(forKey: "reportedCachedInputTokens") as? NSNumber)?.int64Value
        self.reportedCacheWriteInputTokens =
            (managedObject.value(forKey: "reportedCacheWriteInputTokens") as? NSNumber)?.int64Value
        self.reportedReasoningOutputTokens =
            (managedObject.value(forKey: "reportedReasoningOutputTokens") as? NSNumber)?.int64Value
        self.recordVersion = (managedObject.value(forKey: "recordVersion") as? NSNumber)?.intValue
        self.originDeviceClass = managedObject.value(forKey: "originDeviceClass") as? String
        self.currentTurnInlineImageCount =
            (managedObject.value(forKey: "currentTurnInlineImageCount") as? NSNumber)?.intValue
        self.priorTurnInlineImageCount =
            (managedObject.value(forKey: "priorTurnInlineImageCount") as? NSNumber)?.intValue
        self.currentTurnInlineTextFileCount =
            (managedObject.value(forKey: "currentTurnInlineTextFileCount") as? NSNumber)?.intValue
        self.priorTurnInlineTextFileCount =
            (managedObject.value(forKey: "priorTurnInlineTextFileCount") as? NSNumber)?.intValue
        self.fallbackSourceDevice = nil
    }

    /// The nine reported columns viewed back as the value they were parsed
    /// from, so aggregation reads one shape whether it is looking at a fresh
    /// landing or a stored row.
    var reportedMetadata: GatewayResponseMetadata {
        GatewayResponseMetadata(
            reportedModel: reportedModel,
            reportedResponseID: reportedResponseID,
            finishReason: finishReason,
            reportedInputTokens: reportedInputTokens,
            reportedOutputTokens: reportedOutputTokens,
            reportedTotalTokens: reportedTotalTokens,
            reportedCachedInputTokens: reportedCachedInputTokens,
            reportedCacheWriteInputTokens: reportedCacheWriteInputTokens,
            reportedReasoningOutputTokens: reportedReasoningOutputTokens
        )
    }

    /// This row's display state, given what THIS device can see right now.
    /// Convenience over `GatewayAttemptEffectiveOutcome.derive`; identical
    /// rules, and equally free of side effects.
    func effectiveOutcome(
        isLocallyLive: Bool,
        now: Date,
        grace: TimeInterval = ConversationActivityResolver.staleSendingGrace
    ) -> GatewayAttemptEffectiveOutcome {
        GatewayAttemptEffectiveOutcome.derive(
            // A row with no outcome column is OPEN, not authoritatively
            // unknown — `inFlight` is exactly "no terminal callback recorded".
            storedOutcome: hasStoredOutcome ? outcome : .inFlight,
            startedAt: startedAt,
            isLocallyLive: isLocallyLive,
            now: now,
            grace: grace
        )
    }
}

// MARK: - Read-time derivation

/// What an attempt looks like from HERE, right NOW. Derived on every query and
/// every render; NEVER persisted, and never the cause of a write.
///
/// THE TWO NON-TERMINAL STATES ARE NOT THE SAME CLAIM. `pending` says the
/// attempt is young enough that no conclusion is due. `unconfirmed` says the
/// grace has passed and this device has no evidence either way — which is a
/// statement about this device, not about the turn: an iOS background upload
/// can legitimately wait for connectivity far longer, and the origin device may
/// be answering it right now. That is exactly why neither may be written down.
/// A device that stored its own ignorance as `unknown` would race, and could
/// beat, the real success arriving from the device that owns the task.
///
/// `unconfirmed` stays OUT of resolved-reliability and token-coverage
/// denominators; a later terminal callback, or a terminal row syncing in from
/// the owning device, replaces it with no repair pass of any kind.
nonisolated enum GatewayAttemptEffectiveOutcome: Sendable, Hashable {
    /// The row carries a terminal outcome; nothing is being inferred.
    case terminal(GatewayAttemptOutcome)
    /// This device holds a live `URLSession` task for the attempt.
    case inFlight
    /// Open, no local task, still inside the grace window.
    case pending
    /// Open, no local task, past the grace window.
    case unconfirmed

    static func derive(
        storedOutcome: GatewayAttemptOutcome,
        startedAt: Date?,
        isLocallyLive: Bool,
        now: Date,
        grace: TimeInterval = ConversationActivityResolver.staleSendingGrace
    ) -> GatewayAttemptEffectiveOutcome {
        guard !storedOutcome.isTerminal else { return .terminal(storedOutcome) }
        if isLocallyLive { return .inFlight }
        // No start instant means no window to be inside. A row that cannot say
        // when it began cannot be called young.
        guard let startedAt else { return .unconfirmed }
        // ABSOLUTE distance, so the window is symmetric around now. A row
        // stamped by a device whose clock runs fast is future-dated here, and
        // an elapsed-only test would leave it `pending` FOREVER — the grace
        // would never expire because the interval only grows more negative.
        // Beyond the grace in either direction, the honest answer is the same:
        // this device does not know.
        return abs(now.timeIntervalSince(startedAt)) <= grace ? .pending : .unconfirmed
    }

    /// Whether the attempt is resolved enough to count in a rate. `pending` and
    /// `inFlight` are still running; `unconfirmed` is evidence this device does
    /// not have. Only a stored terminal outcome answers.
    var isResolved: Bool {
        if case .terminal = self { return true }
        return false
    }
}
