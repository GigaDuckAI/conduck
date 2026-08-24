// SPDX-License-Identifier: Apache-2.0

// Conduck
// CarPlayAttemptCancellationOutcomeTests.swift
//
// Locks the two things the CarPlay converse lane decides about a cancelled turn
// that nobody can see from the car: which terminal outcome its gateway-attempt
// row gets, and how long a cancel claim is allowed to mean anything.
//
// A background upload task that comes back `.cancelled` is two completely
// different events wearing the same URLError:
//
//   - the driver pressed End mid-think, and this process still holds the live
//     registry entry that proves it → `cancelled`;
//   - the app was force-quit and the system replayed the completion into a fresh
//     process whose registries are empty → NOBODY in this process cancelled
//     anything, so `unknown`: an authoritative callback that could not be
//     classified.
//
// WHY THE DISTINCTION IS RELEASE-RELEVANT rather than cosmetic: `cancelled` and
// `unknown` sit in different places in the dashboard's arithmetic. A cancelled
// attempt is a resolved one the user caused; an `unknown` is a resolved one
// nothing explains. Collapsing the second into the first would quietly tell a
// user they abandoned turns they never touched, and collapsing it into `failed`
// would blame a gateway that may well have answered a request whose reply died
// with the old process.
//
// The DERIVED `unconfirmed` state is a different claim again and is not this
// seam's business: it means only that this device holds no evidence, is computed
// at read time, and never reaches storage. See `GatewayAttemptEffectiveOutcome`.
//
// THE SECOND SEAM — the pending-dispatch cancel claim — is here because it fails
// across a boundary neither half can see. `endSession` cancels whatever token it
// is holding whether or not that turn is still live, so the ordinary end of a
// drive leaves a mark nothing consumes; the uploader that holds those marks is a
// process singleton, while the service that mints the tokens is built fresh on
// every CarPlay connect. Mint per instance and drive 2's k-th turn draws the
// token drive 1 ended on: the turn is dropped before it is ever sent, no error
// is spoken, and the ledger stores `cancelled` for a turn nobody cancelled.
// A process-lifetime mint plus a pruning recheck is what keeps a mark from
// outliving its turn.
//
// Pure seams over pure inputs: no session, no CarPlay scene, no store.

#if os(iOS)
import XCTest
@testable import Conduck

final class CarPlayAttemptCancellationOutcomeTests: XCTestCase {

    /// The driver's End, with the live claim still held.
    func testLiveClaimRecordsUserCancellation() {
        XCTAssertEqual(
            CarPlayConverseUploader.cancellationOutcome(liveClaimPresent: true),
            .cancelled
        )
    }

    /// The post-force-quit resurrect. Must NOT read as a user cancellation.
    func testAbsentClaimRecordsUnknownNotCancelled() {
        let outcome = CarPlayConverseUploader.cancellationOutcome(liveClaimPresent: false)
        XCTAssertEqual(outcome, .unknown)
        XCTAssertNotEqual(outcome, .cancelled)
    }

    /// Neither answer may be `failed`: a cancellation is not evidence the
    /// gateway did anything wrong, and the failure taxonomy is where the driver
    /// is told to go fix something.
    func testNeitherAnswerBlamesTheGateway() {
        for claim in [true, false] {
            XCTAssertNotEqual(
                CarPlayConverseUploader.cancellationOutcome(liveClaimPresent: claim),
                .failed,
                "A bare cancellation must never be recorded as a gateway failure"
            )
        }
    }

    /// Both answers are terminal — a cancelled attempt is never left looking
    /// live, whichever process is doing the classifying.
    func testBothAnswersAreTerminal() {
        for claim in [true, false] {
            XCTAssertTrue(
                CarPlayConverseUploader.cancellationOutcome(liveClaimPresent: claim).isTerminal
            )
        }
    }
}

/// The lifetime of a pending-dispatch cancel claim: a mark may stop the turn it
/// names and no other, ever.
@MainActor
final class CarPlayCancelClaimLifetimeTests: XCTestCase {

    /// Turns of one drive, minted the way the recording service mints them and
    /// rechecked the way the uploader rechecks them. Returns the tokens; fails
    /// the test if any turn is refused dispatch.
    private func runDrive(turns: Int,
                          marks: inout Set<UInt64>,
                          file: StaticString = #filePath,
                          line: UInt = #line) -> [UInt64] {
        var tokens: [UInt64] = []
        for turn in 1...turns {
            let token = CarPlayRecordingService.mintTurnToken()
            tokens.append(token)
            XCTAssertFalse(
                CarPlayConverseUploader.consumeCancelClaim(from: &marks, turnToken: token),
                "Turn \(turn) was dropped before dispatch though nobody cancelled it",
                file: file,
                line: line
            )
        }
        return tokens
    }

    /// THE CROSS-SESSION SCENARIO. Drive 1 ends normally after its last turn has
    /// already completed, so `endSession` deposits a mark with no owner. Drive 2
    /// starts from a brand-new service in the same process and must dispatch
    /// every turn.
    func testStaleEndSessionMarkNeverDropsALaterDrivesTurn() {
        var marks = Set<UInt64>()

        let driveOne = runDrive(turns: 3, marks: &marks)
        // The driver taps End. The last turn's reply was spoken long ago, so
        // there is no task to cancel and no recheck left to consume the mark.
        CarPlayConverseUploader.markCancelClaim(in: &marks, turnToken: driveOne[2])
        XCTAssertEqual(marks, [driveOne[2]])

        // Scene disconnects, the service is dropped, a later drive builds a new
        // one. The tokens must not restart.
        let driveTwo = runDrive(turns: 3, marks: &marks)
        XCTAssertTrue(
            Set(driveOne).isDisjoint(with: Set(driveTwo)),
            "A new CarPlay session re-minted a token an earlier session had already spent"
        )
        XCTAssertTrue(marks.isEmpty, "The orphaned mark outlived the turn it named")
    }

    /// The generalised form: session N+1's k-th turn is the one that used to
    /// die whenever session N ended at turn count k. Every k must survive.
    func testNoTurnCountCollidesAcrossSessions() {
        for turnCount in 1...6 {
            var marks = Set<UInt64>()
            let ended = runDrive(turns: turnCount, marks: &marks)
            CarPlayConverseUploader.markCancelClaim(in: &marks, turnToken: ended[turnCount - 1])
            _ = runDrive(turns: turnCount, marks: &marks)
        }
    }

    /// The claim the mark exists for is untouched: a cancel that lands while the
    /// turn is still assembling — or awaiting the ledger insert — still stops
    /// the dispatch when the recheck reaches it.
    func testCancelBeforeDispatchStillStopsItsOwnTurn() {
        var marks = Set<UInt64>()
        let token = CarPlayRecordingService.mintTurnToken()
        CarPlayConverseUploader.markCancelClaim(in: &marks, turnToken: token)
        XCTAssertTrue(
            CarPlayConverseUploader.consumeCancelClaim(from: &marks, turnToken: token),
            "The driver's End must still beat a dispatch that has not resumed yet"
        )
        // Consumed exactly once — a second recheck of the same token is not a
        // second cancellation.
        XCTAssertFalse(CarPlayConverseUploader.consumeCancelClaim(from: &marks, turnToken: token))
    }

    /// Marks never accumulate for the life of the process: whichever side sees
    /// the next token prunes what it supersedes.
    func testClaimSetStaysBoundedAcrossManySessions() {
        var marks = Set<UInt64>()
        for _ in 1...50 {
            let ended = runDrive(turns: 2, marks: &marks)
            CarPlayConverseUploader.markCancelClaim(in: &marks, turnToken: ended[1])
            XCTAssertLessThanOrEqual(marks.count, 1)
        }
    }

    /// The mint itself, stated plainly: a token is handed out at most once in
    /// the process, so a leftover mark can never name a future turn.
    func testMintNeverRepeatsAToken() {
        var previous = CarPlayRecordingService.mintTurnToken()
        for _ in 1...100 {
            let next = CarPlayRecordingService.mintTurnToken()
            XCTAssertGreaterThan(next, previous)
            previous = next
        }
    }
}
#endif
