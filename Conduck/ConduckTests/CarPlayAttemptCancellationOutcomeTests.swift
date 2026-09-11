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
// A process-lifetime mint is what keeps a mark from ever naming a FUTURE turn;
// an age-bounded retention is what keeps leftovers from accumulating. What no
// consumer may do is drop a mark on another turn's behalf — turns overlap
// across the suspensions between the token mint and the wire, so a token that
// merely sorts lower is not a turn that has finished.
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
        CarPlayConverseUploader.markCancelClaim(in: &marks, turnToken: driveOne[2], outstanding: [])
        XCTAssertEqual(marks, [driveOne[2]])

        // Scene disconnects, the service is dropped, a later drive builds a new
        // one. The tokens must not restart.
        let driveTwo = runDrive(turns: 3, marks: &marks)
        XCTAssertTrue(
            Set(driveOne).isDisjoint(with: Set(driveTwo)),
            "A new CarPlay session re-minted a token an earlier session had already spent"
        )
        // The orphan is RETAINED — a mark is never dropped on another turn's
        // behalf, and no consumer can tell an orphan from a turn still
        // suspended above `uploadConverse`. What matters is what it costs:
        // nothing, because it names a token no future turn can draw. Age, not a
        // newer token, is what eventually retires it (`cancelClaimCeiling`).
        XCTAssertEqual(marks, [driveOne[2]],
                       "the orphan was dropped by a later turn, which is how a LIVE older claim was lost")
    }

    /// The generalised form: session N+1's k-th turn is the one that used to
    /// die whenever session N ended at turn count k. Every k must survive.
    func testNoTurnCountCollidesAcrossSessions() {
        for turnCount in 1...6 {
            var marks = Set<UInt64>()
            let ended = runDrive(turns: turnCount, marks: &marks)
            CarPlayConverseUploader.markCancelClaim(in: &marks, turnToken: ended[turnCount - 1], outstanding: [])
            _ = runDrive(turns: turnCount, marks: &marks)
        }
    }

    /// The claim the mark exists for is untouched: a cancel that lands while the
    /// turn is still assembling — or awaiting the ledger insert — still stops
    /// the dispatch when the recheck reaches it.
    func testCancelBeforeDispatchStillStopsItsOwnTurn() {
        var marks = Set<UInt64>()
        let token = CarPlayRecordingService.mintTurnToken()
        CarPlayConverseUploader.markCancelClaim(in: &marks, turnToken: token, outstanding: [])
        XCTAssertTrue(
            CarPlayConverseUploader.consumeCancelClaim(from: &marks, turnToken: token),
            "The driver's End must still beat a dispatch that has not resumed yet"
        )
        // Consumed exactly once — a second recheck of the same token is not a
        // second cancellation.
        XCTAssertFalse(CarPlayConverseUploader.consumeCancelClaim(from: &marks, turnToken: token))
    }

    /// Marks never accumulate for the life of the process — bounded by AGE
    /// rather than by whichever token happens to sort above them.
    func testClaimSetStaysBoundedAcrossManySessions() {
        var marks = Set<UInt64>()
        for _ in 1...50 {
            let ended = runDrive(turns: 2, marks: &marks)
            CarPlayConverseUploader.markCancelClaim(in: &marks, turnToken: ended[1], outstanding: [])
            XCTAssertLessThanOrEqual(marks.count, CarPlayConverseUploader.cancelClaimCeiling)
        }
        // Non-vacuity: 50 drives deposit 50 orphans, so the ceiling did the
        // bounding rather than the scenario never reaching it.
        XCTAssertEqual(marks.count, CarPlayConverseUploader.cancelClaimCeiling)
    }

    /// THE OVERLAPPING-TURN SCENARIO, and the reason a mark outlives every
    /// token but its own.
    ///
    /// Chat A mints its token and suspends between the mint and the wire — the
    /// file-lane revalidation and the outbox mint both sit there, and both can
    /// take as long as the store and the file server do. The driver presses
    /// End: A has no task yet, so the MARK is the entire cancellation. Chat B
    /// then starts and runs all the way to its own pre-dispatch recheck. If
    /// that recheck prunes what it sorts above, A resumes to find no claim and
    /// uploads the transcript the driver abandoned — a private thought sent to
    /// an AI after the session that would have carried it was ended.
    func testANewerTurnsRecheckNeverConsumesAnOlderSuspendedTurnsClaim() {
        var marks = Set<UInt64>()

        let a = CarPlayRecordingService.mintTurnToken()
        CarPlayConverseUploader.markCancelClaim(in: &marks, turnToken: a, outstanding: [])

        let b = CarPlayRecordingService.mintTurnToken()
        XCTAssertFalse(
            CarPlayConverseUploader.consumeCancelClaim(from: &marks, turnToken: b),
            "B was never cancelled, so its own recheck must let it dispatch"
        )

        XCTAssertTrue(
            CarPlayConverseUploader.consumeCancelClaim(from: &marks, turnToken: a),
            "A resumed to find its claim gone — B's recheck consumed it, and the transcript the driver ended on dispatched anyway"
        )
    }

    /// The mirror, through the depositing side. The driver ends B while A is
    /// still suspended; marking B must not retire A's claim.
    func testANewerTurnsCancellationNeverRetiresAnOlderSuspendedTurnsClaim() {
        var marks = Set<UInt64>()

        let a = CarPlayRecordingService.mintTurnToken()
        CarPlayConverseUploader.markCancelClaim(in: &marks, turnToken: a, outstanding: [])
        let b = CarPlayRecordingService.mintTurnToken()
        CarPlayConverseUploader.markCancelClaim(in: &marks, turnToken: b, outstanding: [])

        XCTAssertTrue(
            CarPlayConverseUploader.consumeCancelClaim(from: &marks, turnToken: a),
            "marking the newer turn retired the older one's claim, and the older turn dispatched"
        )
        XCTAssertTrue(
            CarPlayConverseUploader.consumeCancelClaim(from: &marks, turnToken: b),
            "the newer turn's own claim went missing"
        )
    }

    /// Retention is bounded by AGE among the ORPHANS, and the newest claims are
    /// the survivors. The empty `outstanding` set is the case this states: every
    /// attempt has exited, so age is the only thing left to sort them by.
    func testRetentionDropsTheOldestClaimsAndKeepsTheNewest() {
        var marks = Set<UInt64>()
        var tokens: [UInt64] = []
        for _ in 1...(CarPlayConverseUploader.cancelClaimCeiling + 20) {
            let token = CarPlayRecordingService.mintTurnToken()
            tokens.append(token)
            CarPlayConverseUploader.markCancelClaim(in: &marks, turnToken: token, outstanding: [])
        }
        XCTAssertEqual(marks.count, CarPlayConverseUploader.cancelClaimCeiling)
        XCTAssertEqual(
            marks,
            Set(tokens.suffix(CarPlayConverseUploader.cancelClaimCeiling)),
            "the ceiling dropped the newest claims — the ones still standing in front of a live dispatch"
        )
    }

    /// THE LONG DRIVE. The ceiling's victim is chosen by age, and the oldest
    /// mark is normally an orphan — but it is also exactly the mark of the turn
    /// that has been suspended since before every other one started. Chat A
    /// mints, suspends above `uploadConverse`, and the driver ends it; thirty-two
    /// later cancellations then evicted A's claim, and A resumed to find nothing
    /// standing in front of it and dispatched the abandoned transcript.
    ///
    /// RED without the `outstanding` retention: A is the lowest token, so it is
    /// the first thing the ceiling drops.
    func testAnOutstandingAttemptsClaimSurvivesAnyNumberOfLaterCancellations() {
        var marks = Set<UInt64>()

        let a = CarPlayRecordingService.mintTurnToken()
        let outstanding: Set<UInt64> = [a]
        CarPlayConverseUploader.markCancelClaim(in: &marks, turnToken: a, outstanding: outstanding)

        for _ in 1...(CarPlayConverseUploader.cancelClaimCeiling + 20) {
            let token = CarPlayRecordingService.mintTurnToken()
            CarPlayConverseUploader.markCancelClaim(in: &marks, turnToken: token, outstanding: outstanding)
        }

        XCTAssertTrue(
            CarPlayConverseUploader.consumeCancelClaim(from: &marks, turnToken: a),
            "A's claim was evicted while its dispatch was still suspended — it resumed, found nothing, and uploaded the transcript the driver ended on"
        )
    }

    /// The ceiling still bounds what it CAN bound. One live attempt is not a
    /// licence to keep every orphan: the set lands on the ceiling, and it is the
    /// oldest ORPHANS that went.
    func testTheCeilingStillRetiresOrphansAroundALiveClaim() {
        var marks = Set<UInt64>()

        let a = CarPlayRecordingService.mintTurnToken()
        let outstanding: Set<UInt64> = [a]
        CarPlayConverseUploader.markCancelClaim(in: &marks, turnToken: a, outstanding: outstanding)

        var orphans: [UInt64] = []
        for _ in 1...(CarPlayConverseUploader.cancelClaimCeiling + 20) {
            let token = CarPlayRecordingService.mintTurnToken()
            orphans.append(token)
            CarPlayConverseUploader.markCancelClaim(in: &marks, turnToken: token, outstanding: outstanding)
        }

        XCTAssertEqual(
            marks.count, CarPlayConverseUploader.cancelClaimCeiling,
            "retaining a live claim must not stop the ceiling retiring the orphans around it"
        )
        XCTAssertEqual(
            marks,
            Set([a]).union(orphans.suffix(CarPlayConverseUploader.cancelClaimCeiling - 1)),
            "the survivors are the live claim plus the newest orphans"
        )
    }

    /// A released attempt is an orphan again — the retention is bounded by the
    /// hop's own lifetime, not by a flag nobody clears.
    func testAReleasedAttemptsClaimBecomesEvictableAgain() {
        var marks = Set<UInt64>()

        let a = CarPlayRecordingService.mintTurnToken()
        CarPlayConverseUploader.markCancelClaim(in: &marks, turnToken: a, outstanding: [a])
        for _ in 1...CarPlayConverseUploader.cancelClaimCeiling {
            let token = CarPlayRecordingService.mintTurnToken()
            CarPlayConverseUploader.markCancelClaim(in: &marks, turnToken: token, outstanding: [a])
        }
        XCTAssertTrue(marks.contains(a))

        // A's hop exits. The next cancellation finds an over-ceiling set whose
        // oldest member is now provably orphaned.
        let later = CarPlayRecordingService.mintTurnToken()
        CarPlayConverseUploader.markCancelClaim(in: &marks, turnToken: later, outstanding: [])
        XCTAssertFalse(
            marks.contains(a),
            "a claim whose attempt has exited is retained forever — the ceiling stops bounding anything"
        )
    }

    /// THE PRODUCTION WIRING, executed rather than read. Every case above runs
    /// the static helpers on a local set, so a `cancel(turnToken:)` that stopped
    /// depositing marks — or that passed an empty `outstanding` — would pass all
    /// of them while real cancellation did nothing.
    ///
    /// RED against: deleting `markCancelClaim` from `cancel`; passing
    /// `outstanding: []` there; `beginPendingDispatch`/`endPendingDispatch`
    /// becoming no-ops.
    func testTheProductionCancelDepositsItsMarkAndKeepsItWhileTheDispatchIsOutstanding() {
        let uploader = CarPlayConverseUploader.shared
        uploader.resetDispatchCancellationState()
        defer { uploader.resetDispatchCancellationState() }

        let a = CarPlayRecordingService.mintTurnToken()
        uploader.beginPendingDispatch(turnToken: a)
        uploader.cancel(turnToken: a)
        XCTAssertTrue(
            uploader.hasPendingDispatchCancel(turnToken: a),
            "the driver's End deposited no mark, so a turn still assembling has nothing to recheck and dispatches anyway"
        )

        for _ in 1...(CarPlayConverseUploader.cancelClaimCeiling + 20) {
            uploader.cancel(turnToken: CarPlayRecordingService.mintTurnToken())
        }
        XCTAssertTrue(
            uploader.hasPendingDispatchCancel(turnToken: a),
            "a long drive's later cancellations evicted the claim of a dispatch that is still suspended"
        )

        uploader.endPendingDispatch(turnToken: a)
        uploader.cancel(turnToken: CarPlayRecordingService.mintTurnToken())
        XCTAssertFalse(
            uploader.hasPendingDispatchCancel(turnToken: a),
            "the exited attempt's mark is retained forever, so the ceiling no longer bounds the set"
        )
    }

    /// THE PRE-DISPATCH CONSUMER, executed — the last unexercised link in the
    /// chain the case above builds.
    ///
    /// Depositing a mark protects nothing on its own; the protection is the
    /// question `uploadConverse` asks between the ledger insert and
    /// `task.resume()`, and that function cannot be driven from this suite (a
    /// background `URLSession`, a live gateway, a ledger insert). Written inline
    /// there it was asserted only by reading the source, where a body that
    /// consumes the mark and then answers `false` reads exactly like one that
    /// refuses the dispatch — and answers `false` for the turn the driver just
    /// ended.
    ///
    /// RED against: `consumeDispatchCancelMark` returning a constant; consuming
    /// and answering `false`; consuming another turn's mark; answering `true`
    /// twice for one End; treating the `0` sentinel as a turn.
    func testTheProductionPreDispatchConsumerRefusesExactlyTheEndedTurnAndConsumesItOnce() throws {
        let uploader = CarPlayConverseUploader.shared
        uploader.resetDispatchCancellationState()
        defer { uploader.resetDispatchCancellationState() }

        let ended = CarPlayRecordingService.mintTurnToken()
        let other = CarPlayRecordingService.mintTurnToken()
        uploader.cancel(turnToken: ended)

        XCTAssertFalse(
            uploader.consumeDispatchCancelMark(turnToken: other),
            "a turn nobody ended is refused its dispatch — the driver's words never leave the car"
        )
        XCTAssertTrue(
            uploader.hasPendingDispatchCancel(turnToken: ended),
            "asking for one turn consumed another turn's mark; the ended turn now dispatches"
        )
        XCTAssertTrue(
            uploader.consumeDispatchCancelMark(turnToken: ended),
            "the turn the driver ended is dispatched anyway — a background upload, a spoken reply, and a turn they cancelled on the record"
        )
        XCTAssertFalse(
            uploader.hasPendingDispatchCancel(turnToken: ended),
            "the mark survives its own consumption, so the NEXT turn to reuse this token would be refused too"
        )
        XCTAssertFalse(
            uploader.consumeDispatchCancelMark(turnToken: ended),
            "one End refuses two dispatches — the mark is a claim, consumed in the asking"
        )
        XCTAssertFalse(
            uploader.consumeDispatchCancelMark(turnToken: 0),
            "the `no token yet` sentinel is treated as a turn; every unminted dispatch could then be refused by a mark that belongs to nobody"
        )

        // …and it is the consumer `uploadConverse` actually asks. Everything
        // above is only worth running while the dispatch path still routes
        // through it: inlined again, or called and its answer ignored, the
        // decision moves back to where no case can reach it.
        let uploaderSource = CarPlayVoiceTimingContractTests.normalisedCode(
            try RefusalLaneSource.source(at: "Conduck/CarPlay/CarPlayConverseUploader.swift")
        )
        XCTAssertTrue(
            uploaderSource.contains(
                "let cancelledBeforeDispatch = consumeDispatchCancelMark(turnToken: turnToken) "
                + "if cancelledBeforeDispatch {"
            ),
            "the pre-dispatch recheck no longer goes through the consumer this case executes — the one thing allowed between the ledger insert and `task.resume()` is untested again"
        )
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
