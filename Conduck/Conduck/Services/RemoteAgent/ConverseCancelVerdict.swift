// SPDX-License-Identifier: Apache-2.0

// Conduck
// ConverseCancelVerdict.swift
//
// The at-most-once proof for the ONE failure write a user-initiated Stop is
// allowed to make on the iOS background converse lane. Foundation only — no
// URLSession, no network, no store — so the decision is unit-testable without a
// socket (`ConverseCancelVerdictTests`). Mirrors `WatchConverseCompletionVerdict`:
// the delegate stays a thin adapter that EXECUTES a verdict it did not reason
// about.
//
// THE PROBLEM IT SOLVES. `BackgroundRemoteAgent`'s live-cancel branch writes a
// bare `failed` with no classification, on the argument that a cancel is not a
// gateway verdict. That argument is right for a turn whose bytes left — the
// client genuinely does not know what happened at the other end. It is wrong
// for a turn whose bytes did NOT leave: there the client holds proof, and
// withholding it leaves the user staring at an unexplained failed row after
// stopping a turn that never went anywhere.
//
// WHY THIS CANNOT VIOLATE AT-MOST-ONCE DISPATCH
// (`docs/ai-context/spec.md` — "a turn is dispatched at most once — never more,
// possibly zero"). Six steps, all of which have to hold:
//
//  1. THE ONLY CALLER IS A USER-INITIATED STOP. Nothing in this design cancels
//     a converse task on the app's own initiative — no watchdog, no timer, no
//     path-triggered cancel — so there is no race between an app-invented
//     deadline and a delivery in progress.
//  2. THE PRECONDITION IS TWO INDEPENDENT ZERO READINGS, both taken after the
//     task has terminated. `anyBytesDeparted` is the in-process latch, set by
//     the FIRST byte (not the last) and never cleared. `countOfBytesSent` is
//     the cumulative total the URL loading system maintains on the task itself,
//     which covers out-of-process attempts this process never observed.
//  3. ZERO REQUEST-BODY BYTES ⇒ NON-DELIVERY. The converse hop is a single
//     `POST` whose entire semantic content is its body. A gateway that received
//     zero body bytes holds no parseable request: it cannot invoke a model,
//     cannot spend the user's budget, and cannot act on the world.
//  4. THE SAFETY LATCH IS THE `> 0` THRESHOLD, NEVER THE FULL-BODY ONE. A
//     partially-sent body is `.unknownDelivery`, not a proof. The display
//     latch (`bodyFullySent`, which drives "…is answering…") is never consulted
//     here — conflating the two is how a half-sent request would get declared
//     undelivered.
//  5. `.satisfied` IS NOT ACTED ON, AND IT NAMES NOTHING. The path reading has
//     exactly one power: to ADD the offline cause when the device provably had
//     no route out. It never selects a cause on its own. That asymmetry is
//     deliberate and it is the reason a wrong reading is cheap: `.unsatisfied`
//     is a fact this client can stand behind, while `.satisfied` proves
//     nothing at all — a captive portal reads `.satisfied`, and so does a
//     healthy network whose transfer daemon has simply not started pushing
//     bytes yet. So the satisfied arm names the only thing the counters
//     actually proved (the turn was stopped before it left) and never
//     implicates the far end. Wording is the WHOLE user-visible product of
//     this branch, so a cause the client cannot support is not a smaller
//     mistake than a wrong verdict — it is the same class of untrue statement
//     this file exists to remove, moved one screen later.
//  6. FAILURE DIRECTION IF THE COUNTERS WERE WRONG: a `failed` row with Try
//     Again beside a turn that did dispatch — exactly the hazard the invariant
//     exists to prevent, because the user would re-send a turn the gateway
//     already has, spending their model budget twice and possibly making the
//     agent act on the world twice. That is why BOTH signals are required, why
//     anything above absolute zero falls through to the unclassified terminal,
//     and why nothing else in this change writes a failure.

import Foundation

/// Whether a stopped converse turn's non-delivery is PROVABLE, and if so which
/// client-side cause to name.
enum ConverseCancelVerdict {

    enum Outcome {
        /// Nothing left this device. Classify the failed turn with a
        /// client-side cause the client can actually prove.
        case provableNonDelivery(AppError)
        /// One or more request-body bytes departed, so what the gateway holds
        /// is unknown. Terminal status flip only, with no classification —
        /// byte-for-byte the behaviour that shipped before this file existed.
        case unknownDelivery
    }

    /// - Parameters:
    ///   - anyBytesDeparted: the monotone in-process latch — has ANY
    ///     request-body byte been reported sent for this task, ever.
    ///   - countOfBytesSent: `URLSessionTask.countOfBytesSent`, the cumulative
    ///     total across attempts this process may not have witnessed.
    ///   - pathIsUnsatisfied: `NetworkPathObserver.pathIsUnsatisfiedNow()`.
    ///     Chooses the wording only; it can neither create nor withdraw a
    ///     proof.
    static func make(
        anyBytesDeparted: Bool,
        countOfBytesSent: Int64,
        pathIsUnsatisfied: Bool
    ) -> Outcome {
        // Either signal above absolute zero withdraws the proof. Deliberately
        // `> 0` and not a threshold: one byte on the wire is enough for the
        // gateway to have opened a request Conduck cannot see the end of.
        if anyBytesDeparted || countOfBytesSent > 0 {
            return .unknownDelivery
        }
        if pathIsUnsatisfied {
            // Reuses the generic offline case rather than minting a
            // gateway-flavoured twin: its copy already stops implicating the
            // user's server, which is right — the device had no route out, and
            // that is a cause this client can prove.
            return .provableNonDelivery(.noInternetConnection)
        }
        // A route existed and still nothing left. WHY is unknown and stays
        // unnamed: at least four distinct situations reach here — a refused or
        // unresolvable host, a captive-portal network that reads as connected,
        // a turn still parked behind the system's transfer scheduler, and a
        // Stop taken before the path monitor's first callback landed. Naming a
        // gateway-connection failure would pick one of the four and send the
        // user to re-check an address and a server that may be perfectly fine.
        // So this arm claims only the two facts that are proven: the user
        // stopped it, and nothing left the device.
        return .provableNonDelivery(.turnStoppedBeforeSend)
    }
}

extension ConverseCancelVerdict.Outcome: Equatable {
    /// Compared by `errorCode`, not by case: `AppError` carries associated
    /// `Error` values elsewhere in the enum and therefore cannot be `Equatable`
    /// itself. The code is the identity the store persists and the copy layer
    /// keys off, so it is the identity worth asserting in tests.
    static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.unknownDelivery, .unknownDelivery):
            return true
        case (.provableNonDelivery(let left), .provableNonDelivery(let right)):
            return left.errorCode == right.errorCode
        default:
            return false
        }
    }
}
