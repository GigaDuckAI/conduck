// SPDX-License-Identifier: Apache-2.0

// Conduck
// ConversationActivity.swift
//
// The conversation-list ACTIVITY vocabulary: the value types every list surface
// (iPhone / iPad / Mac / Watch / CarPlay) resolves a row's state through, plus
// the one resolver and the one copy table they all share.
//
// A CONVERSATION IS NOT A TURN. Delivery state is derived from an aggregate of
// the conversation's UNRESOLVED user turns (`ConversationStore
// .fetchUnresolvedUserTurns`), never from the last message: two turns can be in
// flight in one conversation at once (a headless wrist relay racing an in-app
// send), and a reply resolving one of them says nothing about the other. The
// store documents the same hazard on its conversation-wide status flip.
//
// LAYERING NOTE: `ConversationActivityCopy` calls `ThinkingIndicator.label`
// (`Views/Conversation/MessageRowFormatters.swift`). Same module, both files are
// Watch-target members, both are pure Foundation — an accepted layering
// exception, taken so the list, the thread and the wrist say the same words for
// the same state instead of three near-miss strings.

import Foundation

// MARK: - Role

/// A stored `Message.role` as a value. The store keeps it a raw String
/// (CloudKit simplicity); this is the only place that string is interpreted.
/// Nil-tolerant: an unknown or partially-synced value is `nil`, never a guessed
/// default — a row that cannot prove its role must not drive a "You: " prefix
/// or an unviewed dot.
nonisolated enum MessageRole: String, Sendable, Hashable {
    case user
    case agent

    init?(stored: String?) {
        guard let stored, let role = MessageRole(rawValue: stored) else { return nil }
        self = role
    }
}

// MARK: - Delivery state

/// How confident THIS DEVICE is that an unresolved `sending` turn is being
/// worked on. Three cases because a `sending` row may have been written by
/// another device and mirrored here via CloudKit — this device cannot see that
/// request and must never claim the gateway is answering.
nonisolated enum WorkingConfidence: Sendable, Hashable {
    /// A turn for this conversation is running on THIS device.
    case live
    /// Stored `sending`, no local turn, still inside the grace window.
    case hedged
    /// Stored `sending`, no local turn, past the grace window.
    case stale
}

/// The DELIVERY half of a row's state — what the mark and the status word say.
/// `since` is the stamp the elapsed clock counts from.
nonisolated enum ConversationActivity: Sendable, Hashable {
    case idle
    case working(WorkingConfidence, since: Date)
    case answeredUnseen
    case failed
}

/// Delivery and attention are ORTHOGONAL — a single scalar would silently
/// discard one of two true facts. `activity` drives the mark + status word;
/// `hasUnseenReply` drives the bold title + brighter subtitle. `.answeredUnseen`
/// is what `activity` becomes when delivery is idle AND a reply is unseen, so
/// the four-state mark vocabulary survives while `failed + unseen` and
/// `working + unseen` stay representable.
///
/// `failureAcknowledged` is the SECOND attention fact, and it is deliberately
/// not folded into `activity` either. A seen failure is still a failure — the
/// message did not go — so the row keeps saying so; what it loses is the alert,
/// because the user has already been told. Meaningful only when `activity` is
/// `.failed`; false everywhere else. It is an ACCOUNT fact, not a per-surface
/// one: the acknowledgement rides on the conversation itself, so a failure
/// acknowledged on any device is acknowledged on all of them, the wrist
/// included.
nonisolated struct ConversationRowState: Sendable, Hashable {
    let activity: ConversationActivity
    let hasUnseenReply: Bool
    let failureAcknowledged: Bool

    init(
        activity: ConversationActivity,
        hasUnseenReply: Bool,
        failureAcknowledged: Bool = false
    ) {
        self.activity = activity
        self.hasUnseenReply = hasUnseenReply
        self.failureAcknowledged = failureAcknowledged
    }
}

// MARK: - Failed-turn projection

/// The conversation's newest unresolved `failed` USER turn, reduced to the
/// three facts a row needs, as ONE value.
///
/// WHY ONE VALUE AND NOT TWO FIELDS. The stamp and the attempt identity
/// describe the SAME turn, and carried separately they were free to skew. The
/// whole-store unresolved-turn aggregate is the only reader that knows WHICH
/// message is a conversation's newest failed one, so any surface obtaining the
/// identity from somewhere else — a later fetch, a different selector, a caller
/// that simply had no channel for it and passed nil — could name attempt F2
/// while the stamp still named F1. A stored acknowledgement for F2 would then
/// report F1 acknowledged, which is a failure the user never saw losing its
/// mark: the one direction this design forbids. Travelling as one value makes
/// that skew unrepresentable rather than merely discouraged.
///
/// It also removes the second half of the same defect. CarPlay and the menu-bar
/// picker read `ConversationStore.RecentConversation`, which had no channel for
/// an attempt id at all, so those two surfaces could only ever pass nil and
/// every failure stayed permanently unacknowledged on exactly the screens the
/// account-wide markers exist to keep consistent with the list beside them.
nonisolated struct FailedTurnProjection: Sendable, Hashable {
    /// `Message.id` of that turn. Optional because everything in a
    /// CloudKit-mirrored model is, and a nil is NOT a filter: dropping an
    /// id-less failed row from the aggregate would silently retire its red
    /// mark, so it is carried and simply loses every tie. Two id-less rows at
    /// one instant stay mutually ambiguous, which costs nothing — neither can
    /// be acknowledged, so both resolve red either way.
    let messageID: UUID?
    /// That turn's `Message.createdAt` — the stamp the resolver bounds the
    /// failed arm with.
    let createdAt: Date
    /// That turn's `Message.deliveryAttemptID`. The ONLY thing an
    /// acknowledgement is matched against, so a nil here can never be
    /// acknowledged and its failure stays marked — a row written before the
    /// attribute existed resolves red rather than silently. A turn RETRIED by a
    /// build that mints no identity is the one case that goes the other way; the
    /// resolver's step 2b states it in full.
    let deliveryAttemptID: UUID?

    init(messageID: UUID?, createdAt: Date, deliveryAttemptID: UUID?) {
        self.messageID = messageID
        self.createdAt = createdAt
        self.deliveryAttemptID = deliveryAttemptID
    }

    /// TOTAL ORDER over a conversation's failed turns: newer `createdAt` wins,
    /// and an exact tie is broken on `messageID.uuidString`.
    ///
    /// The tie-break is load-bearing, not tidiness. Selecting by fetch order
    /// decides WHICH identity the aggregate reports, and fetch order is not
    /// stable across devices or across two fetches on one device: two devices
    /// would report different ids for the same pair of same-instant failures,
    /// so an acknowledgement made on one could never match on the other; worse,
    /// one device could select differently between the fetch that fed an
    /// acknowledgement and the next fetch that resolves the row, leaving that
    /// conversation red with nothing the user can do to retire it.
    ///
    /// `uuidString` rather than raw `UUID` because `UUID` is not `Comparable`
    /// and the canonical string form is an ordering every device agrees on
    /// without depending on a store's byte layout or collation.
    func isNewer(than other: FailedTurnProjection) -> Bool {
        if createdAt != other.createdAt { return createdAt > other.createdAt }
        return (messageID?.uuidString ?? "") > (other.messageID?.uuidString ?? "")
    }
}

// MARK: - Resolver inputs

/// Everything the resolver reads, so the SAME resolver serves
/// `ConversationRecord` (the iOS/macOS/Watch lists) and
/// `ConversationStore.RecentConversation` (CarPlay, the menu-bar picker) with no
/// duplication and no fabricated records.
nonisolated struct ConversationActivityInputs: Sendable, Hashable {
    let lastActivityAt: Date
    /// Newest unresolved `sending` USER turn in this conversation, from the
    /// whole-store aggregate. NOT the tail.
    let newestSendingAt: Date?
    /// Newest unresolved `failed` USER turn in this conversation — its stamp
    /// and its attempt identity as one value, because they describe one turn
    /// (see `FailedTurnProjection`). Terminal and never cleared, so the resolver
    /// bounds it two ways: it is reported only while it is still the
    /// conversation's last activity, and it stops carrying a mark once the
    /// account has acknowledged THAT attempt. See
    /// `ConversationActivityResolver.resolve`.
    let newestFailed: FailedTurnProjection?
    /// The conversation's own `lastViewedAt`: when this thread was last looked
    /// at on ANY of the user's devices, mirrored in with the row. Nil = never
    /// viewed anywhere.
    let storedLastViewedAt: Date?
    /// The conversation's own `failureSeenAttemptID`: WHICH failure the account
    /// has acknowledged, as an identity rather than a time. Nil = none.
    let storedFailureSeenAttemptID: UUID?
    /// Role of the newest message, when the surface projected it. `nil` means
    /// NOT PROJECTED (watchOS, CarPlay) — never "unknown role" — and suppresses
    /// the unseen branch entirely rather than guessing.
    let tailRole: MessageRole?

    init(
        lastActivityAt: Date,
        newestSendingAt: Date?,
        newestFailed: FailedTurnProjection?,
        storedLastViewedAt: Date?,
        storedFailureSeenAttemptID: UUID?,
        tailRole: MessageRole?
    ) {
        self.lastActivityAt = lastActivityAt
        self.newestSendingAt = newestSendingAt
        self.newestFailed = newestFailed
        self.storedLastViewedAt = storedLastViewedAt
        self.storedFailureSeenAttemptID = storedFailureSeenAttemptID
        self.tailRole = tailRole
    }

    /// The list surfaces. Both turn-state fields are nil unless the record came
    /// from `ConversationStore.fetchConversations(activity: .turnStates)`, and
    /// nil resolves to `.idle` — the row renders exactly as it does without the
    /// projection. The two stored markers need no such caveat: they are columns
    /// on the conversation, so every fetch carries them.
    ///
    /// There is deliberately no attempt-id parameter beside `tailRole`. The
    /// identity rides inside `record.newestFailed` with the stamp it belongs
    /// to, so a caller cannot supply one that names a different turn, and a
    /// caller with no way to obtain one cannot silently pass nil and leave
    /// every acknowledged failure red.
    init(record: ConversationRecord, tailRole: MessageRole?) {
        self.init(
            lastActivityAt: record.lastActivityAt,
            newestSendingAt: record.newestSendingAt,
            newestFailed: record.newestFailed,
            storedLastViewedAt: record.lastViewedAt,
            storedFailureSeenAttemptID: record.failureSeenAttemptID,
            tailRole: tailRole
        )
    }

    #if os(iOS) || os(macOS)
    /// CarPlay + the menu-bar picker. `RecentConversation` itself is gated
    /// `#if os(iOS) || os(macOS)` in the store, so this initializer is too —
    /// the wrist has no picker read.
    init(recent: ConversationStore.RecentConversation, tailRole: MessageRole?) {
        self.init(
            lastActivityAt: recent.lastActivityAt,
            newestSendingAt: recent.newestSendingAt,
            newestFailed: recent.newestFailed,
            storedLastViewedAt: recent.lastViewedAt,
            storedFailureSeenAttemptID: recent.failureSeenAttemptID,
            tailRole: tailRole
        )
    }
    #endif
}

// MARK: - Resolver

nonisolated enum ConversationActivityResolver {
    /// How long an unresolved `sending` turn stays credible without a local
    /// turn. SINGLE SOURCE — `ConversationStore.sweepStaleSendingUserTurns`'s
    /// default reads this, so the display grace and the write grace cannot
    /// drift apart.
    static let staleSendingGrace: TimeInterval = 1800

    /// Resolve one row's delivery + attention state.
    ///
    /// - Parameter locallyLiveSince: `InFlightTurnRegistry.shared.liveSince(id)`
    ///   on iOS/macOS; the wrist's own App-Group in-flight marker on watchOS.
    ///   Authoritative for THIS device only, and NEVER a reason to write
    ///   anything — a reconciliation write based on "I don't see a task" would
    ///   be a write based on local ignorance about another device's turn.
    /// - Parameter lastViewedAt: THIS DEVICE's optimistic view marker, folded
    ///   together with the account-wide `inputs.storedLastViewedAt` by `max`.
    ///   It exists so leaving a thread un-bolds its row on the same runloop turn
    ///   instead of waiting on a store save plus a CloudKit import; the stored
    ///   value is the durable truth and outlives it. `nil` means this device
    ///   holds no such local intent — NOT that the surface tracks no read state
    ///   — and only both being nil suppresses the unseen branch outright.
    ///
    /// There is deliberately NO acknowledgement parameter beside it.
    /// Acknowledgement is an identity match against one delivery attempt (step
    /// 2b), and no device-local timestamp can say WHICH attempt was seen, so it
    /// is answered from `inputs` alone.
    static func resolve(
        _ inputs: ConversationActivityInputs,
        locallyLiveSince: Date?,
        lastViewedAt: Date?,
        now: Date = Date()
    ) -> ConversationRowState {
        // 1. DELIVERY — the NEWEST unresolved turn wins.
        //    Not "failed beats working": a conversation holding an old failed
        //    turn and a fresh sending turn is WORKING, and rendering it red
        //    would be a lie the moment the user re-sends. Both timestamps come
        //    from the same aggregate, so the comparison is total.
        //
        // A `failed` turn is TERMINAL, and nothing in the app ever clears one:
        // only an explicit Retry on that exact bubble flips it back to
        // `sending`, so the stamp is monotone for the life of the install.
        // `sending` needs no such bound (the launch sweep resolves it just past
        // the grace), but an unbounded `failed` arm would paint a row red
        // FOREVER after a single offline send or a user-tapped Stop — and,
        // because a non-idle delivery state suppresses the fold to
        // `.answeredUnseen` in step 3, would also kill that conversation's amber
        // "new reply" disc permanently, on every device.
        //
        // So a failure is reported only while it is still the last thing that
        // happened here. Every message append — including the successful re-ask
        // that is how users actually recover, rather than scrolling back to
        // Retry — bumps `lastActivityAt` past it. A failure that IS the tail
        // compares EQUAL, not less: the append writes `Message.createdAt` and
        // `Conversation.lastActivityAt` from one `now` in one transaction, and a
        // status flip bumps neither.
        //
        // AND THE COMPARISON IS ON INTEGERS, NEVER ON `Date`s — the same rule
        // `TailProjection.read` states at length, for the same reason, over the
        // same pair of values. These two halves are separate CKRecords: the
        // stamp belongs to a `Message`, the bound belongs to its `Conversation`,
        // and the mirror imports them in whatever batches it likes. A bit-exact
        // comparison therefore has a window in which one half has arrived and
        // the other has not — `ConversationStore.repairTailProjection` moves
        // both in one local save, and roughly half the rows it touches round
        // upward — and in that window an equal pair reads as LESS. The red mark
        // would vanish from the list, the menu bar and the wrist for a message
        // that never sent. Quantising both sides to the millisecond the mirror
        // itself carries makes the window invisible, and costs nothing anywhere
        // else: every stamp this build writes is already canonical, so the
        // quantisation is the identity on it.
        let failed = inputs.newestFailed.flatMap {
            TailProjection.milliseconds(from: $0.createdAt)
                >= TailProjection.milliseconds(from: inputs.lastActivityAt) ? $0 : nil
        }

        let activity: ConversationActivity = {
            let sending = inputs.newestSendingAt

            // Same quantisation on the sibling test, so "newer than the failure"
            // and "still the last thing that happened" cannot disagree about
            // what one millisecond contains.
            if let sending,
               failed == nil
                || TailProjection.milliseconds(from: sending)
                    > TailProjection.milliseconds(from: failed!.createdAt) {
                if let locallyLiveSince {
                    return .working(.live, since: locallyLiveSince)
                }
                return now.timeIntervalSince(sending) <= staleSendingGrace
                    ? .working(.hedged, since: sending)
                    : .working(.stale, since: sending)
            }
            if failed != nil { return .failed }

            // A local claim that PRECEDES its durable write. On macOS the user
            // row is written before the claim is taken, so this is not the
            // macOS foreground case; it covers the lanes that claim before the
            // row is visible to a list snapshot (the CarPlay upload, the share
            // drainer, and any reload that raced the append).
            if let locallyLiveSince { return .working(.live, since: locallyLiveSince) }
            return .idle
        }()

        // 2. ATTENTION — independent of delivery, and never inferred from a
        //    role this surface did not project.
        //
        //    The effective view time is the LATER of the account-wide stored
        //    marker and this device's optimistic overlay. Both are needed and
        //    neither subsumes the other: the overlay leads (it is set before the
        //    save it describes), the stored value both outlives it and arrives
        //    from the other devices. Taking `max` rather than preferring one
        //    means an out-of-order arrival can only ever move the marker
        //    FORWARD here, so a late-arriving older value cannot re-bold a row.
        let unseen: Bool = {
            let effectiveViewedAt = [inputs.storedLastViewedAt, lastViewedAt]
                .compactMap { $0 }
                .max()
            guard let effectiveViewedAt, inputs.tailRole == .agent else { return false }
            return inputs.lastActivityAt > effectiveViewedAt   // strict: equal is NOT unseen
        }()

        // 2b. The failure's SECOND bound: has the account already been shown
        //     THIS delivery attempt? IDENTITY, never recency — the stored
        //     acknowledgement names one `Message.deliveryAttemptID` and has to
        //     equal the failed turn's exactly.
        //
        //     A timestamp comparison cannot answer this question, which is why
        //     it is not used: asking again does NOT advance the failed turn's
        //     `createdAt`, so "acknowledged" and "acknowledged the PREVIOUS
        //     attempt" are indistinguishable by time — and under
        //     last-writer-wins that ends with a message which never sent showing
        //     no mark at all, permanently. Under identity a stale write can only
        //     ever name some other attempt, and an attempt nothing names is not
        //     acknowledged. Nothing has to CLEAR an acknowledgement either: a
        //     retry mints a new attempt id, and so does any writer that declares
        //     the failure afresh, so the stored one simply stops matching.
        //
        //     BOTH SIDES MUST BE PRESENT — `nil == nil` does NOT acknowledge. A
        //     failure carrying no attempt id — a row written before the
        //     attribute existed — stays red. That is the safe direction: an
        //     unacknowledged failure over-reports and costs one tap, while a
        //     silenced one is a message the user never learns did not send.
        //
        //     THE ONE CASE THAT DOES NOT LAND ON THE SAFE SIDE, written out
        //     because the rule above invites the opposite reading: a RETRY
        //     performed by a device still running a build that has no
        //     `deliveryAttemptID` at all. Its compare-and-set writes only
        //     `status`, so the row's identity does not become nil — it stays the
        //     SAME identity the account already acknowledged. (A client cannot
        //     put a key its model does not define into a CKRecord, and a key a
        //     save does not carry is left alone on the server rather than
        //     cleared, so nothing removes it either.) When that attempt fails
        //     too, the comparison below matches and the re-failure resolves
        //     ACKNOWLEDGED: silent on every updated device, and `failed` is
        //     terminal, so only another retry from a build that DOES mint gets
        //     the mark back. The pre-v10 device is the one screen that still
        //     shows red — it spends its own device-local acknowledgement at the
        //     retry — which is the reverse of every other divergence here and
        //     makes the mixed fleet disagree in the dangerous direction.
        //
        //     NOTHING IN THIS FILE CAN CLOSE IT, and no field added to the
        //     schema could either: the device that advances the attempt is the
        //     device running none of this code, so whatever it fails to mint it
        //     would equally fail to bump. Nor can it be detected after the fact
        //     — "acknowledged and untouched" and "acknowledged, re-attempted,
        //     re-failed" leave the record carrying byte-identical values. It is
        //     bounded instead by the rollout: it needs an acknowledgement made
        //     on an updated device and a retry made on one that is not, and it
        //     ends when the last device updates. Accepted deliberately, at the
        //     price of naming it here rather than letting the paragraph above be
        //     read as covering it.
        //
        //     Only the failure the row would actually paint is considered, and
        //     the identity is read off THAT SAME projection rather than passed
        //     in beside it — so a superseded failure cannot report itself
        //     acknowledged, and no caller can pair one turn's stamp with
        //     another turn's identity.
        let acknowledged: Bool = {
            guard let failed,
                  let seenAttemptID = inputs.storedFailureSeenAttemptID,
                  let failedAttemptID = failed.deliveryAttemptID else { return false }
            return seenAttemptID == failedAttemptID
        }()

        // 3. Fold to the four-state mark vocabulary, keeping both attention
        //    facts alongside.
        if case .idle = activity, unseen {
            return ConversationRowState(activity: .answeredUnseen, hasUnseenReply: true)
        }
        return ConversationRowState(
            activity: activity,
            hasUnseenReply: unseen,
            // Never claim acknowledgement on a row that is not reporting the
            // failure: a fresh `sending` turn outranks an older failure, and a
            // stale acknowledgement must not survive into that state.
            failureAcknowledged: activity == .failed && acknowledged
        )
    }
}

// MARK: - Shared copy

/// The status words every activity surface renders. Deliberately NOT
/// `nonisolated`: `working(_:gatewayName:)` calls `ThinkingIndicator.label`,
/// which is MainActor-isolated under `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`.
/// Every caller is view code already on the main actor, so the default isolation
/// costs nothing and no annotation churn is needed in files this type does not
/// own.
enum ConversationActivityCopy {
    /// Status words for a working row.
    ///   `.live`   → `ThinkingIndicator.label(phase: .answering, backendName:)`
    ///   `.hedged` → "Waiting for a reply…"
    ///   `.stale`  → "No reply yet"
    ///
    /// `.stale` states a fact about the SEND, never a claim about the agent:
    /// nothing is known to be running and nothing has been written. `.live`
    /// delegates so the list and the thread say the same words, including the
    /// empty-gateway-name fallback (a bare "Answering…", never " is answering…").
    static func working(_ confidence: WorkingConfidence, gatewayName: String) -> String {
        switch confidence {
        case .live:
            return ThinkingIndicator.label(phase: .answering, backendName: gatewayName)
        case .hedged:
            return String(localized: "activity.waitingForReply",
                          defaultValue: "Waiting for a reply…")  // xcstrings: chat-ui
        case .stale:
            return String(localized: "activity.noReplyYet",
                          defaultValue: "No reply yet")  // xcstrings: chat-ui
        }
    }

    /// The word for a turn that never left the device. Reuses
    /// `ConversationCopyFormatter`'s existing phrase for this exact state, and
    /// is deliberately NOT "No reply" — in a list that reads as "hasn't
    /// answered yet", the opposite of the truth.
    static var notSent: String {
        String(localized: "activity.notSent", defaultValue: "Not sent")  // xcstrings: chat-ui
    }

    /// Coarse elapsed for a list row: nil below 60 s, whole minutes above,
    /// FLOORED so the label never reads ahead of the truth. Locale-aware via
    /// `Duration.UnitsFormatStyle`. Pure + unit-testable.
    static func coarseElapsed(_ elapsed: TimeInterval) -> String? {
        guard elapsed >= 60 else { return nil }
        let wholeMinutes = Int(elapsed / 60)
        return Duration.seconds(wholeMinutes * 60).formatted(
            .units(
                allowed: [.hours, .minutes],
                width: .abbreviated,
                maximumUnitCount: 2,
                zeroValueUnits: .hide
            )
        )
    }
}
