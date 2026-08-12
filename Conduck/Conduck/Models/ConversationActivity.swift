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
nonisolated struct ConversationRowState: Sendable, Hashable {
    let activity: ConversationActivity
    let hasUnseenReply: Bool

    init(activity: ConversationActivity, hasUnseenReply: Bool) {
        self.activity = activity
        self.hasUnseenReply = hasUnseenReply
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
    /// Newest unresolved `failed` USER turn in this conversation. Terminal and
    /// never cleared, so the resolver reports it only while it is still the
    /// conversation's last activity — see `ConversationActivityResolver.resolve`.
    let newestFailedAt: Date?
    /// Role of the newest message, when the surface projected it. `nil` means
    /// NOT PROJECTED (watchOS, CarPlay) — never "unknown role" — and suppresses
    /// the unseen branch entirely rather than guessing.
    let tailRole: MessageRole?

    init(
        lastActivityAt: Date,
        newestSendingAt: Date?,
        newestFailedAt: Date?,
        tailRole: MessageRole?
    ) {
        self.lastActivityAt = lastActivityAt
        self.newestSendingAt = newestSendingAt
        self.newestFailedAt = newestFailedAt
        self.tailRole = tailRole
    }

    /// The list surfaces. Both turn-state fields are nil unless the record came
    /// from `ConversationStore.fetchConversations(activity: .turnStates)`, and
    /// nil resolves to `.idle` — the row renders exactly as it does without the
    /// projection.
    init(record: ConversationRecord, tailRole: MessageRole?) {
        self.init(
            lastActivityAt: record.lastActivityAt,
            newestSendingAt: record.newestSendingAt,
            newestFailedAt: record.newestFailedAt,
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
            newestFailedAt: recent.newestFailedAt,
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
    /// - Parameter lastViewedAt: `nil` on a surface that does not track read
    ///   state (watchOS, CarPlay) → `hasUnseenReply` is always false there.
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
        let activity: ConversationActivity = {
            let sending = inputs.newestSendingAt
            // A `failed` turn is TERMINAL, and nothing in the app ever clears
            // one: only an explicit Retry on that exact bubble flips it back to
            // `sending`, so the stamp is monotone for the life of the install.
            // `sending` needs no such bound (the launch sweep resolves it just
            // past the grace), but an unbounded `failed` arm would paint a row
            // red FOREVER after a single offline send or a user-tapped Stop —
            // and, because a non-idle delivery state suppresses the fold to
            // `.answeredUnseen` in step 3, would also kill that conversation's
            // amber "new reply" disc permanently, on every device.
            //
            // So a failure is reported only while it is still the last thing
            // that happened here. Every message append — including the
            // successful re-ask that is how users actually recover, rather than
            // scrolling back to Retry — bumps `lastActivityAt` past it. A
            // failure that IS the tail compares EQUAL, not less: the append
            // writes `Message.createdAt` and `Conversation.lastActivityAt` from
            // one `now` in one transaction, and a status flip bumps neither.
            let failed = inputs.newestFailedAt.flatMap {
                $0 >= inputs.lastActivityAt ? $0 : nil
            }

            if let sending, failed == nil || sending > failed! {
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
        let unseen: Bool = {
            guard let lastViewedAt, inputs.tailRole == .agent else { return false }
            return inputs.lastActivityAt > lastViewedAt   // strict: equal is NOT unseen
        }()

        // 3. Fold to the four-state mark vocabulary, keeping `unseen` alongside.
        if case .idle = activity, unseen {
            return ConversationRowState(activity: .answeredUnseen, hasUnseenReply: true)
        }
        return ConversationRowState(activity: activity, hasUnseenReply: unseen)
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
