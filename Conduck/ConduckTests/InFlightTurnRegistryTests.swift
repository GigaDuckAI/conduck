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
//   • a leaked claim ages out of every query at the TTL.

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
            [background]
        }

        await registry.reconcile()
        XCTAssertEqual(registry.liveIDs, [manual, background])

        // The same probe, now reporting nothing: its lane empties, the manual
        // claim survives untouched.
        let empty = InFlightTurnRegistry()
        empty.noteBegan(manual, lane: .viewModel, isCancellable: true, at: Date())
        empty.addProbe(lane: .backgroundConverse, isCancellable: true) { [] }
        await empty.reconcile()
        XCTAssertEqual(empty.liveIDs, [manual])
    }

    func testAReconciledLaneCarriesItsDeclaredCancellability() async {
        let registry = InFlightTurnRegistry()
        let carPlay = UUID()
        registry.addProbe(lane: .carPlay, isCancellable: false) { [carPlay] }
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
        registry.addProbe(lane: .backgroundConverse, isCancellable: true) { [id] }
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
        registry.addProbe(lane: .backgroundConverse, isCancellable: true) { [first] }
        registry.addProbe(lane: .backgroundConverse, isCancellable: true) { [second] }

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
        registry.addProbe(lane: .backgroundConverse, isCancellable: true) { [id] }
        registry.addProbe(lane: .carPlay, isCancellable: false) { [] }
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
            await MainActor.run { reports.fired ? [] : [id] }
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

    func testResetForTestingClearsTheSharedRegistry() {
        InFlightTurnRegistry.shared.noteBegan(UUID(), lane: .viewModel, isCancellable: true)
        XCTAssertEqual(InFlightTurnRegistry.shared.liveCount, 1)
        InFlightTurnRegistry._resetForTesting()
        XCTAssertEqual(InFlightTurnRegistry.shared.liveCount, 0)
    }
}
