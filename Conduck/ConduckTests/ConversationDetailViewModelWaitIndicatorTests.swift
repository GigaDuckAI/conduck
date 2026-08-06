// SPDX-License-Identifier: Apache-2.0

// Conduck
// ConversationDetailViewModelWaitIndicatorTests.swift
//
// The split between the send CLAIM and the answering DISPLAY.
//
// `isAwaitingReply` is the correctness latch: on macOS `sendUserTurn` and
// `retry` claim it synchronously on the MainActor before their first `await`, so
// two rapid hotkey captures can't both pass the guard. That claim lands several
// awaits before the user's turn is durably written — so driving the visible
// "{gateway} is answering…" row from it rendered the row ABOVE the bubble that
// provoked it, and asserted the gateway was working while the app was still
// downsizing attachments.
//
// `showsGatewayWaitIndicator` is the display gate, derived from
// `inFlightStartedAt` — which both send paths set immediately before the hop, on
// both platforms, and which every success / failure / cancel / early-landing
// release clears. These cases pin the contract between the two. They do NOT
// exercise the send path itself: `sendUserTurn` reaches `ConversationStore.shared`
// directly, so a true ordering integration test would need an injectable store.
// What they guard is the property that made the ordering wrong — a future
// "simplification" back to `isAwaitingReply` fails `testClaimAloneNeverShowsIndicator`.

import XCTest
@testable import Conduck

@MainActor
final class ConversationDetailViewModelWaitIndicatorTests: XCTestCase {

    private func makeViewModel() -> ConversationDetailViewModel {
        ConversationDetailViewModel(conversationID: UUID())
    }

    func testFreshViewModelShowsNoIndicator() {
        let vm = makeViewModel()
        XCTAssertFalse(vm.isAwaitingReply)
        XCTAssertNil(vm.inFlightStartedAt)
        XCTAssertFalse(vm.showsGatewayWaitIndicator,
                       "A VM that has never sent must not present an agent-side wait.")
    }

    /// THE regression guard. This is the exact state macOS occupies for the whole
    /// pre-dispatch window: claimed, nothing dispatched. Nothing the user reads as
    /// "the agent is working" may be true here.
    func testClaimAloneNeverShowsIndicator() {
        let vm = makeViewModel()
        vm.isAwaitingReply = true          // macOS's synchronous claim
        XCTAssertNil(vm.inFlightStartedAt) // ...taken before any dispatch
        XCTAssertFalse(vm.showsGatewayWaitIndicator,
                       "The answering row must stay hidden until the turn is dispatched — "
                       + "on macOS the claim precedes the user's own bubble.")
    }

    func testDispatchShowsIndicator() {
        let vm = makeViewModel()
        vm.isAwaitingReply = true
        vm.inFlightStartedAt = Date()
        XCTAssertTrue(vm.showsGatewayWaitIndicator)
    }

    /// Every terminal path — reply landed, failed, cancelled — nils
    /// `inFlightStartedAt`, so one assertion covers all three releases.
    func testReleasingTheTimestampHidesIndicator() {
        let vm = makeViewModel()
        vm.isAwaitingReply = true
        vm.inFlightStartedAt = Date()
        XCTAssertTrue(vm.showsGatewayWaitIndicator)

        vm.inFlightStartedAt = nil
        XCTAssertFalse(vm.showsGatewayWaitIndicator,
                       "The indicator must clear with the dispatch timestamp.")
    }

    /// `MacForegroundReplyLanding` releases the awaiting UI (nils the timestamp)
    /// BEFORE the send Task's `defer` clears `isAwaitingReply` and `inFlightTask`,
    /// so this ordering is reachable in production. The row must already be gone:
    /// the reply has landed.
    func testTimestampClearedBeforeClaimHidesIndicator() {
        let vm = makeViewModel()
        vm.isAwaitingReply = true
        vm.inFlightStartedAt = Date()

        vm.inFlightStartedAt = nil          // releaseAwaitingUI
        XCTAssertTrue(vm.isAwaitingReply)   // claim not yet released
        XCTAssertFalse(vm.showsGatewayWaitIndicator)
    }

    /// Derived, never mirrored — the two must not be able to disagree. A stored
    /// second Bool would drift on whichever release path forgot to write it.
    func testIndicatorTracksTimestampInBothDirections() {
        let vm = makeViewModel()
        for _ in 0..<3 {
            vm.inFlightStartedAt = Date()
            XCTAssertTrue(vm.showsGatewayWaitIndicator)
            vm.inFlightStartedAt = nil
            XCTAssertFalse(vm.showsGatewayWaitIndicator)
        }
    }

    /// The claim is free to be false while a timestamp is set (and vice versa);
    /// the display must follow the timestamp alone, never the claim.
    func testIndicatorIgnoresTheClaimEntirely() {
        let vm = makeViewModel()

        vm.isAwaitingReply = false
        vm.inFlightStartedAt = Date()
        XCTAssertTrue(vm.showsGatewayWaitIndicator)

        vm.isAwaitingReply = true
        XCTAssertTrue(vm.showsGatewayWaitIndicator,
                      "Setting the claim must not change the display gate.")

        vm.inFlightStartedAt = nil
        XCTAssertFalse(vm.showsGatewayWaitIndicator,
                       "Clearing the timestamp must hide the row even while claimed.")
    }

    // MARK: - Turn identity (qualified cancel)

    // The composer's trailing control morphs between Send and Stop, so a click
    // can be aimed at one and land after it has become the other. Capturing the
    // INTENT at render time fixes the Send half — a stale `.send` hits `send()`'s
    // own live guards and no-ops. The Stop half needs more: cancelling is
    // destructive, and a live `isInFlight` re-check does NOT distinguish "the
    // turn I meant" from "a different turn that started in the gap" (a Watch
    // relay, a Shortcut, or the quick-capture lane on this same VM can start
    // one). So Stop carries the turn's identity and the cancel is qualified by
    // it. These lock that decision.

    func testTheTurnTokenFollowsTheInFlightStamp() {
        let vm = makeViewModel()
        XCTAssertNil(vm.inFlightTurnToken, "A VM with nothing in flight names no turn.")

        let started = Date()
        vm.inFlightStartedAt = started
        XCTAssertEqual(vm.inFlightTurnToken, started,
                       "The token is DERIVED from the stamp — a separately-stored id would drift on the first clear site that forgot it.")

        vm.inFlightStartedAt = nil
        XCTAssertNil(vm.inFlightTurnToken)
    }

    func testAnUnqualifiedCancelAlwaysApplies() {
        // Teardown callers mean "stop whatever is running" and pass no token.
        XCTAssertTrue(ConversationDetailViewModel.cancelApplies(expecting: nil, current: Date()))
        XCTAssertTrue(ConversationDetailViewModel.cancelApplies(expecting: nil, current: nil))
    }

    func testAQualifiedCancelAppliesToItsOwnTurn() {
        let turn = Date()
        XCTAssertTrue(ConversationDetailViewModel.cancelApplies(expecting: turn, current: turn),
                      "The ordinary case: the Stop the user pressed reaches the turn it was rendered for.")
    }

    func testAQualifiedCancelIsDroppedOnceItsTurnHasResolved() {
        let turn = Date()
        XCTAssertFalse(ConversationDetailViewModel.cancelApplies(expecting: turn, current: nil),
                       "The turn already finished — there is nothing this click can legitimately stop.")
    }

    /// THE case a live `isInFlight` re-check cannot catch: something IS in
    /// flight, so the flag reads true, but it is not the turn the click meant.
    func testAQualifiedCancelNeverKillsABystanderTurn() {
        let intendedTurn = Date(timeIntervalSince1970: 1_000)
        let laterTurn = Date(timeIntervalSince1970: 2_000)
        XCTAssertFalse(
            ConversationDetailViewModel.cancelApplies(expecting: intendedTurn, current: laterTurn),
            "A stale Stop must not cancel a turn that started after it was rendered — that is a destructive action produced by a click aimed at something else.")
    }
}
