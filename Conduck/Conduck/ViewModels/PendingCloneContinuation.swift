// SPDX-License-Identifier: Apache-2.0

//
//  PendingCloneContinuation.swift
//  Conduck
//
//  One-shot authorization to continue a freshly cloned thread on its new
//  gateway. "Clone & continue on <gateway>" is a single tap that means two
//  things — fork the thread, and pick up where it stopped — but the fork and the
//  dispatch happen in different places: the SOURCE thread's sheet performs the
//  clone, while only the DESTINATION thread's view model can dispatch on it.
//  This carries the intent across that gap.
//
//  Deliberately NOT a global single slot drained from `reload()`:
//    - `reload()` runs on view-model init and on every CloudKit remote-change
//      fan-out, not when the destination becomes visible. A slot with no expiry
//      could fire hours later on an unrelated refresh of that thread.
//    - iOS suppresses a reply's push banner only once `ActiveViewTracker` has
//      registered the conversation as visible, so dispatching before the thread
//      appears can pop a banner and sound at a user who is already looking at
//      the answer.
//    - Two scenes (macOS window + menu-bar popover, or iPad split view) can
//      clone different conversations concurrently; one slot would clobber.
//
//  So: keyed per conversation, short-lived, and consumed from the visible
//  thread. `ConversationStore.beginRetry`'s compare-and-set remains the
//  at-most-once backstop if two surfaces ever race the same claim.
//

import Foundation

@MainActor
final class PendingCloneContinuation {
    static let shared = PendingCloneContinuation()

    /// How long an armed continuation stays valid. Long enough to survive the
    /// clone → deep-link → thread-appears hop on a cold, busy device; far too
    /// short to let a forgotten token fire on some later visit to the thread.
    /// The authorization is the user's tap, and a tap does not stay fresh.
    static let validity: TimeInterval = 30

    /// Two live phases, both of which must suppress the failed-turn row.
    /// Splitting them matters: `armed` expires (an authorization that never got
    /// claimed must not linger), while `dispatching` does NOT — a retry already
    /// in flight has no deadline, and timing it out would surface a delivery
    /// error for a delivery that is still happening.
    private enum Phase {
        case armed(messageID: UUID, expiresAt: Date)
        case dispatching(messageID: UUID)

        var messageID: UUID {
            switch self {
            case .armed(let id, _), .dispatching(let id): return id
            }
        }
    }

    private var phases: [UUID: Phase] = [:]

    private init() {}

    /// Authorize one automatic continuation of `messageID` in `conversationID`.
    /// Called BEFORE the caller navigates, so `isSuppressed` is already true at
    /// the destination's first render — ordering, not a race.
    func arm(conversationID: UUID, messageID: UUID, now: Date = Date()) {
        phases[conversationID] = .armed(
            messageID: messageID,
            expiresAt: now.addingTimeInterval(Self.validity)
        )
    }

    /// Should this row's delivery-error treatment be withheld — i.e. is its
    /// first delivery still pending or in flight?
    ///
    /// The cloned row is genuinely `failed` in the store (the correct fail-safe
    /// if the dispatch never happens), but "No reply — this message wasn't
    /// delivered" is a lie before any delivery has been attempted.
    ///
    /// PURE: no mutation, because this is read from `body` during a SwiftUI view
    /// update, and it is the SHARED answer — a second window showing the same
    /// conversation must not render a Try Again for a turn the first window is
    /// dispatching. That is why the dispatching phase lives here and not in a
    /// per-view `@State`.
    func isSuppressed(conversationID: UUID, messageID: UUID, now: Date = Date()) -> Bool {
        guard let phase = phases[conversationID], phase.messageID == messageID else {
            return false
        }
        switch phase {
        case .armed(_, let expiresAt): return expiresAt > now
        case .dispatching: return true
        }
    }

    /// Claim the continuation for `conversationID`, if one is live, moving it to
    /// `dispatching`. Consumes the authorization, so a second surface reaching
    /// here — or a later visit to the thread — gets nil rather than a second
    /// dispatch, while the row stays suppressed everywhere until `finish`.
    func take(conversationID: UUID, now: Date = Date()) -> UUID? {
        guard case .armed(let messageID, let expiresAt)? = phases[conversationID] else { return nil }
        guard expiresAt > now else {
            phases[conversationID] = nil
            return nil
        }
        phases[conversationID] = .dispatching(messageID: messageID)
        return messageID
    }

    /// The claim resolved (dispatched, or refused before dispatch). Clears the
    /// suppression so a continuation that genuinely failed shows the delivery
    /// row with its real verdict — the suppression must never outlive the
    /// attempt it exists to cover.
    func finish(conversationID: UUID) {
        phases[conversationID] = nil
    }

    #if DEBUG
    /// Test hook — the singleton outlives an individual test case.
    func resetForTesting() { phases.removeAll() }
    #endif
}
