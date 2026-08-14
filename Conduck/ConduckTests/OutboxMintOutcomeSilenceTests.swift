// SPDX-License-Identifier: Apache-2.0

//
//  OutboxMintOutcomeSilenceTests.swift
//  ConduckTests
//
//  WHICH OUTBOX-MINT OUTCOMES ARE SILENT, asserted in one place for the whole
//  suite, plus the test-only predicate the rest of the suite reads that table
//  through.
//
//  WHY THE PREDICATE LIVES HERE AND NOT IN PRODUCTION. Nothing in the app asks
//  an `OutboxMintOutcome` whether it is a fault. Every dispatch surface takes
//  `.key` and discards the rest, and the thread's folder-less row is derived
//  independently in `ConversationDetailViewModel` from
//  `FileLaneWitnessBreaker.faultedSince` — lane-wide, and long after any one
//  turn's outcome has gone out of scope. A predicate sitting on the enum would
//  therefore be edited by a maintainer who believed they were changing what the
//  user sees, and would change nothing at all, with every test still passing.
//  The enum's own doc-comment table stays the human-readable contract; this
//  mirrors it for the suite, and because the mirror is an exhaustive switch a
//  newly added case still fails to compile until somebody classifies it.
//
//  Deterministic + headless: pure taxonomy assertions. No network, no store, no
//  clock.
//

import XCTest
@testable import Conduck

extension BackgroundFileTransfer.OutboxMintOutcome {

    /// Whether this outcome is one the user should be told about.
    ///
    /// A TEST MIRROR OF THE ENUM'S CONTRACT TABLE, never the production path —
    /// production has no such predicate, by design (see this file's header). Read
    /// it as "what the table says", and when the two disagree the table is right
    /// and this is the bug.
    var isActionableFault: Bool {
        switch self {
        case .witnessFailed, .witnessSuppressed: return true
        case .named, .noLane, .laneCannotReturn: return false
        }
    }
}

final class OutboxMintOutcomeSilenceTests: XCTestCase {

    /// The surfaced two: a lane the user configured and tested green that has
    /// stopped producing folders. The only case where a turn quietly loses a
    /// capability the user is entitled to expect.
    func testTheTwoFaultOutcomesAreTheOnesWorthAWord() {
        XCTAssertTrue(BackgroundFileTransfer.OutboxMintOutcome.witnessFailed.isActionableFault)
        XCTAssertTrue(BackgroundFileTransfer.OutboxMintOutcome.witnessSuppressed.isActionableFault,
                      "a suppressed turn still went out folder-less — the backoff hides the "
                      + "request, never the consequence")
    }

    /// The silent three, each silent because the user is not missing anything
    /// they were promised: no lane at all, a lane that cannot return files as a
    /// standing property, and a turn that got what it asked for.
    func testTheThreeSilentOutcomesDrawNothing() {
        for outcome: BackgroundFileTransfer.OutboxMintOutcome in [
            .named("conv/out-box"), .noLane, .laneCannotReturn
        ] {
            XCTAssertFalse(outcome.isActionableFault,
                           "\(outcome) is either a success or a standing configuration the File "
                           + "transfer page states plainly; a per-turn row about it is noise")
        }
    }

    /// Only `.named` puts anything on the wire, and it is the only outcome that
    /// is both silent and productive — the two properties are independent and
    /// this is the one place both are asserted together.
    func testOnlyANamedOutcomeCarriesAFolder() {
        XCTAssertEqual(BackgroundFileTransfer.OutboxMintOutcome.named("conv/out-box").key,
                       "conv/out-box")
        for outcome: BackgroundFileTransfer.OutboxMintOutcome in [
            .noLane, .laneCannotReturn, .witnessFailed, .witnessSuppressed
        ] {
            XCTAssertNil(outcome.key, "\(outcome) names no folder")
        }
    }
}
