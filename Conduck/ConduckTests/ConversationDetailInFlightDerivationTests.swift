// SPDX-License-Identifier: Apache-2.0

// Conduck
// ConversationDetailInFlightDerivationTests.swift
//
// The thread's in-flight state is DERIVED from `InFlightTurnRegistry`, not
// stored on the view model. That is what makes the wait indicator and Stop
// survive `ContentView.syncDetailVM()` discarding the VM on a navigation pop and
// minting a fresh one on the way back — the old behaviour was a new VM starting
// at `inFlightStartedAt == nil`, so a thread with a live request rendered no
// spinner and a composer that offered Send.
//
// The properties pinned here:
//   • a VM that dispatched NOTHING still shows the wait when this device holds a
//     claim for its conversation (the navigate-away-and-back case);
//   • Stop is offered ONLY for a claim registered as cancellable — a Mac cannot
//     cancel an iPhone-owned turn, and the macOS share drainer / CarPlay
//     uploader hold no cancel handle at all;
//   • the identity a Stop carries survives the round trip through
//     `cancelApplies`, so a cancel aimed at a registry-owned turn is not
//     silently dropped;
//   • overlapping claims: ending the OLDER one leaves the thread waiting;
//   • the macOS pre-dispatch window (claimed, nothing dispatched) still shows no
//     wait and no Stop — the regression `ConversationDetailViewModelWaitIndicatorTests`
//     guards, restated against the derived properties;
//   • a claim on another conversation, and an aged-out claim, are both invisible
//     here.
//
// These do NOT exercise the send path: `sendUserTurn` reaches
// `ConversationStore.shared` directly, so the registry is driven manually — the
// same seam production's `beginInFlight`/`endInFlight` use.

import XCTest
@testable import Conduck

@MainActor
final class ConversationDetailInFlightDerivationTests: XCTestCase {

    private var registry: InFlightTurnRegistry { InFlightTurnRegistry.shared }

    override func setUp() async throws {
        try await super.setUp()
        InFlightTurnRegistry._resetForTesting()
    }

    override func tearDown() async throws {
        InFlightTurnRegistry._resetForTesting()
        try await super.tearDown()
    }

    private func makeViewModel(_ id: UUID = UUID()) -> ConversationDetailViewModel {
        ConversationDetailViewModel(conversationID: id)
    }

    // MARK: - Navigate away and back

    /// THE fix. This VM dispatched nothing and owns no `Task`; the turn belongs
    /// to the instance the navigation stack threw away.
    func testAFreshViewModelInheritsALiveTurnFromTheRegistry() {
        let id = UUID()
        let started = Date()
        registry.noteBegan(id, lane: .viewModel, isCancellable: true, at: started)

        let vm = makeViewModel(id)
        XCTAssertNil(vm.inFlightStartedAt, "This instance dispatched nothing of its own.")
        XCTAssertEqual(vm.liveTurnStartedAt, started,
                       "The elapsed clock must count from when the TURN started, not from this VM's birth.")
        XCTAssertTrue(vm.showsGatewayWaitIndicator,
                      "Navigating away and back must not lose the spinner while the request is still running.")
        XCTAssertTrue(vm.canStopLiveTurn,
                      "A viewModel-lane claim is cancellable, so the composer keeps offering Stop.")
    }

    /// The claim ending is the ONLY bookkeeping — nothing has to reach back into
    /// a VM that may no longer exist.
    func testReleasingTheClaimClearsTheDerivedState() {
        let id = UUID()
        let token = registry.noteBegan(id, lane: .viewModel, isCancellable: true)
        let vm = makeViewModel(id)
        XCTAssertTrue(vm.showsGatewayWaitIndicator)

        registry.noteEnded(token)
        XCTAssertNil(vm.liveTurnStartedAt)
        XCTAssertFalse(vm.showsGatewayWaitIndicator)
        XCTAssertFalse(vm.canStopLiveTurn)
    }

    /// A claim on a neighbouring thread is not this thread's business.
    func testAClaimOnAnotherConversationIsInvisible() {
        registry.noteBegan(UUID(), lane: .viewModel, isCancellable: true)
        let vm = makeViewModel()
        XCTAssertNil(vm.liveTurnStartedAt)
        XCTAssertFalse(vm.showsGatewayWaitIndicator)
        XCTAssertFalse(vm.canStopLiveTurn)
    }

    /// A VM deallocated mid-flight cannot detach its own claim, so a leaked claim
    /// ages out rather than pinning a spinner forever.
    func testAnExpiredClaimNoLongerDrivesTheThread() {
        let id = UUID()
        registry.noteBegan(
            id,
            lane: .viewModel,
            isCancellable: true,
            at: Date().addingTimeInterval(-InFlightTurnRegistry.claimTTL - 60)
        )
        let vm = makeViewModel(id)
        XCTAssertNil(vm.liveTurnStartedAt)
        XCTAssertFalse(vm.showsGatewayWaitIndicator)
        XCTAssertFalse(vm.canStopLiveTurn)
    }

    // MARK: - Overlapping claims

    /// Two turns can overlap in one conversation (a Watch relay racing an in-app
    /// send). Ending the older must leave the thread waiting on the survivor — a
    /// conversation-keyed registry would strand a live request with no spinner.
    func testEndingTheOlderOfTwoClaimsLeavesTheThreadWaiting() {
        let id = UUID()
        let started = Date()
        let older = registry.noteBegan(id, lane: .viewModel, isCancellable: true, at: started)
        registry.noteBegan(id, lane: .backgroundConverse, isCancellable: true,
                           at: started.addingTimeInterval(20))
        let vm = makeViewModel(id)
        XCTAssertEqual(vm.liveTurnStartedAt, started,
                       "The clock reports the OLDEST live turn — the one the user has been waiting on.")

        registry.noteEnded(older)
        XCTAssertTrue(vm.showsGatewayWaitIndicator)
        XCTAssertEqual(vm.liveTurnStartedAt, started.addingTimeInterval(20))
    }

    // MARK: - Stop is offered only for a handle this device can use

    /// The macOS share drainer registers `isCancellable: false`: the turn is
    /// visible to this process but there is nothing to cancel it with.
    func testANonCancellableClaimShowsTheWaitButOffersNoStop() {
        let id = UUID()
        registry.noteBegan(id, lane: .shareDrain, isCancellable: false)
        let vm = makeViewModel(id)
        XCTAssertTrue(vm.showsGatewayWaitIndicator,
                      "The user must still see that the gateway is working.")
        XCTAssertFalse(vm.canStopLiveTurn,
                       "A Stop here would call a cancel with no handle behind it and do nothing.")
    }

    /// A CarPlay upload is not cancellable through `BackgroundRemoteAgent.cancel`
    /// either — and a cancellable sibling claim on the SAME conversation is what
    /// legitimately re-lights Stop.
    func testACancellableSiblingClaimRestoresStop() {
        let id = UUID()
        registry.noteBegan(id, lane: .carPlay, isCancellable: false)
        let vm = makeViewModel(id)
        XCTAssertFalse(vm.canStopLiveTurn)

        registry.noteBegan(id, lane: .backgroundConverse, isCancellable: true)
        XCTAssertTrue(vm.canStopLiveTurn,
                      "Some live claim on this conversation now carries a usable handle.")
    }

    /// This VM's own dispatch is always stoppable — it holds the `Task` (macOS)
    /// or the background session's conversation handle (iOS).
    func testThisInstancesOwnTurnIsAlwaysStoppable() {
        let vm = makeViewModel()
        vm.inFlightStartedAt = Date()
        XCTAssertTrue(vm.canStopLiveTurn)
        XCTAssertTrue(vm.showsGatewayWaitIndicator)
    }

    /// The stored stamp wins over the registry so the elapsed clock and the turn
    /// token agree with the turn this instance actually dispatched.
    func testThisInstancesOwnStampTakesPrecedence() {
        let id = UUID()
        let ownStamp = Date(timeIntervalSince1970: 2_000)
        registry.noteBegan(id, lane: .backgroundConverse, isCancellable: true)
        let vm = makeViewModel(id)
        vm.inFlightStartedAt = ownStamp
        XCTAssertEqual(vm.liveTurnStartedAt, ownStamp)
        XCTAssertEqual(vm.inFlightTurnToken, ownStamp)
    }

    // MARK: - The Stop a registry-owned turn renders must survive its own trip

    /// `cancelInFlight(expecting:)` drops a token that no longer names the live
    /// turn. A Stop rendered for a registry-owned turn carries that turn's stamp,
    /// so the comparison has to be against the DERIVED stamp — comparing to the
    /// (nil) stored one would drop every such cancel silently.
    func testAStopRenderedForARegistryOwnedTurnStillApplies() {
        let id = UUID()
        registry.noteBegan(id, lane: .backgroundConverse, isCancellable: true)
        let vm = makeViewModel(id)

        let rendered = vm.inFlightTurnToken   // what the composer captured
        XCTAssertNotNil(rendered)
        XCTAssertTrue(
            ConversationDetailViewModel.cancelApplies(expecting: rendered, current: vm.liveTurnStartedAt),
            "A Stop aimed at the turn on screen must reach it, whoever dispatched it."
        )
    }

    /// The bystander guard still holds across the derived stamp: once the turn
    /// the Stop was rendered for has resolved, the click stops nothing.
    func testAStopIsStillDroppedOnceItsTurnResolved() {
        let id = UUID()
        let token = registry.noteBegan(id, lane: .backgroundConverse, isCancellable: true)
        let vm = makeViewModel(id)
        let rendered = vm.inFlightTurnToken

        registry.noteEnded(token)
        XCTAssertFalse(
            ConversationDetailViewModel.cancelApplies(expecting: rendered, current: vm.liveTurnStartedAt),
            "Nothing is running; a late Stop must not be applied to whatever starts next."
        )
    }

    // MARK: - The pre-dispatch window is unchanged

    /// macOS claims `isAwaitingReply` synchronously, several awaits before the
    /// turn is dispatched. Nothing the user reads as "the agent is working" may
    /// be true there, and a Stop there would have no task behind it.
    func testTheClaimAloneStillShowsNoWaitAndNoStop() {
        let vm = makeViewModel()
        vm.isAwaitingReply = true
        XCTAssertFalse(vm.showsGatewayWaitIndicator,
                       "The registry is only claimed at dispatch, so the pre-dispatch window stays silent.")
        XCTAssertFalse(vm.canStopLiveTurn,
                       "The composer must render a disabled Send here, not a Stop that lies.")
    }
}
