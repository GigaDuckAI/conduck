// SPDX-License-Identifier: Apache-2.0

// Conduck
// InFlightTurnRegistryTests.swift
//
// Locks the properties the token keying exists for:
//   • two turns can overlap in ONE conversation and both stay live;
//   • ending the OLDER token leaves the newer one live (a conversation-keyed
//     registry would delete the survivor);
//   • ending a token twice is a no-op (the two known double-end sites);
//   • a probe's `reconcile()` replaces only ITS lane, never a manual claim;
//   • cancellability is a property of the claim, so a non-cancellable lane can
//     never light a Stop button;
//   • a leaked claim ages out of every query at the TTL;
//   • the DISPATCH stamp is monotone, lands on the claim the row actually
//     reads, and is never invented for a turn whose bytes have not left.

import XCTest
@testable import Conduck

@MainActor
final class InFlightTurnRegistryTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    override func tearDown() async throws {
        InFlightTurnRegistry._resetForTesting()
        try await super.tearDown()
    }

    // MARK: - Overlapping claims

    func testTwoClaimsOnOneConversationBothSurvive() {
        // `liveCount` reads the wall clock (no injectable `now` in its
        // contract), so this case anchors to real time.
        let registry = InFlightTurnRegistry()
        let id = UUID()
        let started = Date()
        let older = registry.noteBegan(id, lane: .viewModel, isCancellable: true, at: started)
        let newer = registry.noteBegan(id, lane: .shareDrain, isCancellable: false,
                                       at: started.addingTimeInterval(30))

        XCTAssertEqual(registry.liveSince(id), started)
        XCTAssertEqual(registry.liveCount, 1, "one CONVERSATION, two claims")

        registry.noteEnded(older)
        XCTAssertEqual(
            registry.liveSince(id),
            started.addingTimeInterval(30),
            "ending the older claim must not delete the newer one"
        )
        registry.noteEnded(newer)
        XCTAssertNil(registry.liveSince(id))
        XCTAssertEqual(registry.liveCount, 0)
    }

    func testEndingATokenTwiceIsANoOp() {
        let registry = InFlightTurnRegistry()
        let id = UUID()
        let first = registry.noteBegan(id, lane: .viewModel, isCancellable: true, at: now)
        registry.noteEnded(first)
        let second = registry.noteBegan(id, lane: .viewModel, isCancellable: true,
                                        at: now.addingTimeInterval(5))
        registry.noteEnded(first)   // the stale double-end
        XCTAssertEqual(
            registry.liveSince(id, now: now.addingTimeInterval(10)),
            now.addingTimeInterval(5),
            "a stale end must not touch a newer claim"
        )
        registry.noteEnded(second)
        XCTAssertEqual(registry.liveCount, 0)
    }

    func testLiveSinceReportsTheOldestLiveTurn() {
        let registry = InFlightTurnRegistry()
        let id = UUID()
        registry.noteBegan(id, lane: .viewModel, isCancellable: true, at: now.addingTimeInterval(90))
        registry.noteBegan(id, lane: .viewModel, isCancellable: true, at: now)
        XCTAssertEqual(registry.liveSince(id, now: now.addingTimeInterval(120)), now)
    }

    // MARK: - Cancellability

    func testCancellabilityIsPerClaim() {
        let registry = InFlightTurnRegistry()
        let uncancellable = UUID()
        registry.noteBegan(uncancellable, lane: .shareDrain, isCancellable: false, at: now)
        XCTAssertFalse(registry.isCancellable(uncancellable, now: now))
        XCTAssertNotNil(registry.liveSince(uncancellable, now: now))

        registry.noteBegan(uncancellable, lane: .viewModel, isCancellable: true, at: now)
        XCTAssertTrue(
            registry.isCancellable(uncancellable, now: now),
            "any cancellable claim is enough to offer Stop"
        )
    }

    // MARK: - Counts

    func testSoleLiveConversationIDIsNilWhenSeveralAreLive() {
        let registry = InFlightTurnRegistry()
        let first = UUID()
        registry.noteBegan(first, lane: .viewModel, isCancellable: true)
        XCTAssertEqual(registry.soleLiveConversationID, first)

        registry.noteBegan(UUID(), lane: .viewModel, isCancellable: true)
        XCTAssertNil(registry.soleLiveConversationID)
        XCTAssertEqual(registry.liveCount, 2)
    }

    // MARK: - TTL

    func testAnAgedClaimDropsOutOfEveryQuery() {
        let registry = InFlightTurnRegistry()
        let id = UUID()
        registry.noteBegan(id, lane: .viewModel, isCancellable: true, at: now)
        let past = now.addingTimeInterval(InFlightTurnRegistry.claimTTL + 1)
        XCTAssertNil(registry.liveSince(id, now: past))
        XCTAssertFalse(registry.isCancellable(id, now: past))
    }

    func testANewClaimPrunesAnAgedOneWithoutTouchingLiveSiblings() {
        let registry = InFlightTurnRegistry()
        let leaked = UUID()
        let fresh = UUID()
        registry.noteBegan(leaked, lane: .viewModel, isCancellable: true, at: now)
        registry.noteBegan(
            fresh,
            lane: .viewModel,
            isCancellable: true,
            at: now.addingTimeInterval(InFlightTurnRegistry.claimTTL + 1)
        )
        XCTAssertNil(registry.liveSince(leaked, now: now.addingTimeInterval(InFlightTurnRegistry.claimTTL + 1)))
        XCTAssertNotNil(registry.liveSince(fresh, now: now.addingTimeInterval(InFlightTurnRegistry.claimTTL + 1)))
    }

    func testLiveCountIgnoresAnExpiredClaim() {
        let registry = InFlightTurnRegistry()
        registry.noteBegan(
            UUID(),
            lane: .viewModel,
            isCancellable: true,
            at: Date().addingTimeInterval(-(InFlightTurnRegistry.claimTTL + 60))
        )
        XCTAssertEqual(registry.liveCount, 0)
        XCTAssertTrue(registry.liveIDs.isEmpty)
    }

    // MARK: - Probes

    func testReconcileReplacesOnlyItsOwnLane() async {
        let registry = InFlightTurnRegistry()
        let manual = UUID()
        let background = UUID()
        registry.noteBegan(manual, lane: .viewModel, isCancellable: true, at: Date())
        registry.addProbe(lane: .backgroundConverse, isCancellable: true) { [background] in
            [background: false]
        }

        await registry.reconcile()
        XCTAssertEqual(registry.liveIDs, [manual, background])

        // The same probe, now reporting nothing: its lane empties, the manual
        // claim survives untouched.
        let empty = InFlightTurnRegistry()
        empty.noteBegan(manual, lane: .viewModel, isCancellable: true, at: Date())
        empty.addProbe(lane: .backgroundConverse, isCancellable: true) { [:] }
        await empty.reconcile()
        XCTAssertEqual(empty.liveIDs, [manual])
    }

    func testAReconciledLaneCarriesItsDeclaredCancellability() async {
        let registry = InFlightTurnRegistry()
        let carPlay = UUID()
        registry.addProbe(lane: .carPlay, isCancellable: false) { [carPlay: false] }
        await registry.reconcile()
        XCTAssertNotNil(registry.liveSince(carPlay))
        XCTAssertFalse(
            registry.isCancellable(carPlay),
            "a CarPlay upload has no cancel handle, so Stop must stay hidden"
        )
    }

    func testReconcileKeepsTheOriginalStartForAStillReportedTurn() async {
        let registry = InFlightTurnRegistry()
        let id = UUID()
        registry.addProbe(lane: .backgroundConverse, isCancellable: true) { [id: false] }
        await registry.reconcile()
        let firstSeen = registry.liveSince(id)
        XCTAssertNotNil(firstSeen)

        await registry.reconcile()
        XCTAssertEqual(
            registry.liveSince(id),
            firstSeen,
            "the elapsed clock must not restart on every list reload"
        )
    }

    /// `reconcile` empties a lane before repopulating it from that lane's probe,
    /// so a second probe on the same lane would erase the first's conversations.
    /// Registration enforces one probe per lane instead, which also makes an
    /// entry point that runs its wiring twice idempotent.
    func testRegisteringASecondProbeOnALaneReplacesTheFirst() async {
        let registry = InFlightTurnRegistry()
        let first = UUID()
        let second = UUID()
        registry.addProbe(lane: .backgroundConverse, isCancellable: true) { [first: false] }
        registry.addProbe(lane: .backgroundConverse, isCancellable: true) { [second: false] }

        await registry.reconcile()
        XCTAssertEqual(
            registry.liveIDs,
            [second],
            "the surviving probe is the last registered, not a lane holding both"
        )

        // Other lanes are untouched by the replacement.
        let manual = UUID()
        registry.noteBegan(manual, lane: .viewModel, isCancellable: true, at: Date())
        await registry.reconcile()
        XCTAssertEqual(registry.liveIDs, [second, manual])
    }

    /// Observation's setter fires on EVERY write with no equality check of its
    /// own, and the list awaits `reconcile()` on the same path whose no-op
    /// early-exit exists to make a CloudKit import storm cheap. So a reconcile
    /// that changes nothing must write nothing: otherwise every visible row
    /// re-runs the resolver, rebuilds its VoiceOver label and re-lays its
    /// subviews, per storm echo, on a device with nothing in flight.
    private final class InvalidationFlag: @unchecked Sendable {
        var fired = false
    }

    func testANoOpReconcileInvalidatesNothing() async {
        let registry = InFlightTurnRegistry()
        let id = UUID()
        registry.addProbe(lane: .backgroundConverse, isCancellable: true) { [id: false] }
        registry.addProbe(lane: .carPlay, isCancellable: false) { [:] }
        await registry.reconcile()

        let flag = InvalidationFlag()
        withObservationTracking {
            _ = registry.liveIDs
        } onChange: {
            flag.fired = true
        }
        await registry.reconcile()
        XCTAssertFalse(flag.fired, "a reconcile that changes nothing must mutate nothing")
    }

    func testAReconcileThatChangesTheLaneDoesInvalidate() async {
        // The other half: the guard must not be so tight that a real change is
        // swallowed.
        let registry = InFlightTurnRegistry()
        let id = UUID()
        let reports = InvalidationFlag()
        registry.addProbe(lane: .backgroundConverse, isCancellable: true) { [id, reports] in
            await MainActor.run { reports.fired ? [:] : [id: false] }
        }
        await registry.reconcile()
        XCTAssertEqual(registry.liveIDs, [id])

        let flag = InvalidationFlag()
        withObservationTracking {
            _ = registry.liveIDs
        } onChange: {
            flag.fired = true
        }
        reports.fired = true          // the turn finished; the probe stops reporting it
        await registry.reconcile()
        XCTAssertTrue(flag.fired)
        XCTAssertTrue(registry.liveIDs.isEmpty)
    }

    // MARK: - Dispatch stamp

    /// The composer mints the `.viewModel` claim several awaits before the
    /// background delegate sees a byte, and that earliest claim is the one every
    /// surface reads. So the stamp has to land there, not on the lane that
    /// reported the departure.
    func testDispatchStampsTheEarliestClaimInAnyLane() {
        let registry = InFlightTurnRegistry()
        let id = UUID()
        registry.noteBegan(id, lane: .viewModel, isCancellable: true, at: now)
        registry.noteBegan(id, lane: .backgroundConverse, isCancellable: true,
                           at: now.addingTimeInterval(30))

        XCTAssertNil(registry.dispatchedSince(id, now: now.addingTimeInterval(40)))
        registry.noteDispatched(id, at: now.addingTimeInterval(45))
        XCTAssertEqual(
            registry.dispatchedSince(id, now: now.addingTimeInterval(50)),
            now.addingTimeInterval(45)
        )
    }

    /// Monotone: the repeated progress callbacks that drive `noteDispatched`
    /// must not move the stamp, or the elapsed clock would restart on every one.
    func testDispatchStampIsIdempotent() {
        let registry = InFlightTurnRegistry()
        let id = UUID()
        registry.noteBegan(id, lane: .viewModel, isCancellable: true, at: now)
        registry.noteDispatched(id, at: now.addingTimeInterval(10))
        registry.noteDispatched(id, at: now.addingTimeInterval(60))
        XCTAssertEqual(
            registry.dispatchedSince(id, now: now.addingTimeInterval(90)),
            now.addingTimeInterval(10),
            "a second departure report must not restart the answering clock"
        )
    }

    /// `dispatchedSince` reads the SAME claim `liveSince` picks. A younger
    /// sibling that has dispatched must not lend its stamp to the turn the user
    /// is actually waiting on.
    func testDispatchIsNotBorrowedFromAYoungerSiblingClaim() {
        let registry = InFlightTurnRegistry()
        let id = UUID()
        registry.noteBegan(id, lane: .viewModel, isCancellable: true, at: now)
        registry.noteBegan(id, lane: .shareDrain, isCancellable: false,
                           dispatchedAt: now.addingTimeInterval(31),
                           at: now.addingTimeInterval(30))

        XCTAssertEqual(registry.liveSince(id, now: now.addingTimeInterval(40)), now)
        XCTAssertNil(
            registry.dispatchedSince(id, now: now.addingTimeInterval(40)),
            "the oldest claim has sent nothing; the row must keep saying so"
        )
    }

    /// A departure for a conversation whose claims have ALL aged out must not be
    /// dropped. The departure edge fires once per task and never again, so a
    /// dropped stamp is permanent for that turn — the row would read "Sending…"
    /// for the entire time the gateway was actually answering, and the list row
    /// beside it would disagree.
    func testADepartureAfterEveryClaimAgedOutMintsOneRatherThanBeingLost() {
        let registry = InFlightTurnRegistry()
        let id = UUID()
        registry.noteBegan(id, lane: .viewModel, isCancellable: true, at: now)

        let departed = now.addingTimeInterval(InFlightTurnRegistry.claimTTL + 120)
        XCTAssertNil(registry.liveSince(id, now: departed), "the original claim has aged out")

        registry.noteDispatched(id, lane: .backgroundConverse, isCancellable: true, at: departed)
        XCTAssertEqual(registry.dispatchedSince(id, now: departed), departed)
        XCTAssertEqual(
            registry.liveSince(id, now: departed), departed,
            "the minted claim under-reports when the turn began, which is the "
                + "same honest limit an adopted claim carries"
        )
        XCTAssertTrue(registry.isCancellable(id, now: departed),
                      "a minted claim carries the caller's cancel handle, or Stop goes dark")
    }

    /// The reaping horizon counts from the LAST evidence of life, and a
    /// departure is evidence. Anchored on `startedAt` alone, a turn that parked
    /// and then departed lost its stamp mid-flight and the row walked backwards
    /// out of "…is answering…".
    func testAStampedClaimIsNotReapedOnTheHorizonMeasuredFromItsBirth() {
        let registry = InFlightTurnRegistry()
        let id = UUID()
        registry.noteBegan(id, lane: .viewModel, isCancellable: true, at: now)
        let handoff = now.addingTimeInterval(InFlightTurnRegistry.claimTTL - 60)
        registry.noteDispatched(id, at: handoff)

        // Past the claim's own birth horizon, inside the departure's.
        let later = now.addingTimeInterval(InFlightTurnRegistry.claimTTL + 60)
        XCTAssertEqual(registry.dispatchedSince(id, now: later), handoff)
        XCTAssertEqual(registry.liveSince(id, now: later), now)

        // And it still ages out eventually — this widens the horizon, it does
        // not remove it, or a leaked stamped claim would pin a spinner forever.
        let muchLater = handoff.addingTimeInterval(InFlightTurnRegistry.claimTTL + 60)
        XCTAssertNil(registry.liveSince(id, now: muchLater))
        XCTAssertNil(registry.dispatchedSince(id, now: muchLater))
    }

    /// The stamp is CONVERSATION-scoped, and this case says so out loud rather
    /// than leaving the header to promise more than the writer delivers: with
    /// two overlapping turns, the departure that arrives lands on the oldest
    /// claim whichever turn it belonged to. The background lane's own probe
    /// OR-folds departure across sibling tasks before `reconcile()` sees it, so
    /// tightening only this writer would not buy a turn-scoped answer anyway.
    func testTheDepartureStampIsConversationScopedNotTurnScoped() {
        let registry = InFlightTurnRegistry()
        let id = UUID()
        registry.noteBegan(id, lane: .viewModel, isCancellable: true, at: now)
        registry.noteBegan(id, lane: .backgroundConverse, isCancellable: true,
                           at: now.addingTimeInterval(30))

        registry.noteDispatched(id, at: now.addingTimeInterval(45))
        XCTAssertEqual(
            registry.dispatchedSince(id, now: now.addingTimeInterval(50)),
            now.addingTimeInterval(45),
            "the oldest claim carries the stamp — that is the documented scope, "
                + "and a change here means the transport started threading a "
                + "task identity through and the header needs rewriting with it"
        )
    }

    /// `liveCount` reads the wall clock, so this asserts through the injectable
    /// queries instead — the minted claim is what matters, not the ambient time
    /// the fixed `now` sits at.
    func testDispatchOnAnUnknownConversationMintsAClaimForIt() {
        let registry = InFlightTurnRegistry()
        let id = UUID()
        registry.noteDispatched(id, at: now)
        XCTAssertEqual(registry.liveSince(id, now: now), now)
        XCTAssertEqual(registry.dispatchedSince(id, now: now), now)
    }

    /// A turn that outlived a relaunch is adopted from the probe. When the probe
    /// reports the body departed we know THAT it dispatched, not WHEN — so the
    /// adopted claim is stamped `now`, the same honest limit `startedAt` carries.
    func testAnAdoptedClaimIsStampedOnlyWhenTheProbeReportsDeparture() async {
        let departed = UUID()
        let parked = UUID()
        let registry = InFlightTurnRegistry()
        registry.addProbe(lane: .backgroundConverse, isCancellable: true) { [departed, parked] in
            [departed: true, parked: false]
        }
        await registry.reconcile()
        XCTAssertNotNil(registry.dispatchedSince(departed))
        XCTAssertNil(registry.dispatchedSince(parked))
    }

    /// A surviving claim picks the stamp up the first time its probe reports the
    /// departure, and never puts it back down.
    func testReconcileFillsInAndNeverClearsTheDispatchStamp() async {
        let id = UUID()
        let registry = InFlightTurnRegistry()
        let reports = InvalidationFlag()
        registry.addProbe(lane: .backgroundConverse, isCancellable: true) { [id, reports] in
            await MainActor.run { [id: reports.fired] }
        }
        await registry.reconcile()
        XCTAssertNil(registry.dispatchedSince(id))

        reports.fired = true
        await registry.reconcile()
        let stamped = registry.dispatchedSince(id)
        XCTAssertNotNil(stamped)

        // The probe stops reporting departure (an out-of-process retry re-parked
        // the task). The stamp must not be withdrawn — the bytes did leave.
        reports.fired = false
        await registry.reconcile()
        XCTAssertEqual(registry.dispatchedSince(id), stamped)
    }

    func testResetForTestingClearsTheSharedRegistry() {
        InFlightTurnRegistry.shared.noteBegan(UUID(), lane: .viewModel, isCancellable: true)
        XCTAssertEqual(InFlightTurnRegistry.shared.liveCount, 1)
        InFlightTurnRegistry._resetForTesting()
        XCTAssertEqual(InFlightTurnRegistry.shared.liveCount, 0)
    }
}
