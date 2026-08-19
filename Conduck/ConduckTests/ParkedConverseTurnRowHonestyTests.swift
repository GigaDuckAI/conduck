// SPDX-License-Identifier: Apache-2.0

// Conduck
// ParkedConverseTurnRowHonestyTests.swift
//
// WHAT THE IN-FLIGHT ROW IS ALLOWED TO SAY WHILE NOTHING HAS BEEN SENT, driven
// through the composed types rather than through the pure resolver alone: a real
// `InFlightTurnRegistry` claim, a real `NetworkPathObserver` reading, a real
// `ConversationDetailViewModel`, and the same label projection the thread row and
// the conversation list row each perform.
//
// THE DEFECT THESE CASES EXIST FOR, reproduced on device before the fix:
//   • Airplane mode, send. No failure. The row read "LiteLLM is answering… 2:40",
//     and the real reply landed the instant the radio came back.
//   • Gateway URL `https://127.0.0.1:1` (refused on loopback). No failure. The
//     row read "Throwaway is answering… 1:39".
// Both are the same lie in two dresses: on iPhone the converse hop rides a
// background `URLSession`, which holds an un-sent request until a route exists
// and retries transport failures out of process, so the row named a gateway that
// had received nothing — beside an unbounded counter of a wait that gateway
// never had. `LiveTurnPhaseResolverTests` pins the decision; these pin the WIRING
// between the four types that have to agree for the row to be honest, which is
// exactly where the defect lived (the resolver was correct-by-absence: the thread
// hard-coded `.answering`).
//
// The clock is asserted as carefully as the words. A counter that silently folded
// five minutes of parked waiting into "is answering" is the same false claim in
// numeric form, so `.answering` counts from the HAND-OFF and the parked phases
// count from the claim.
//
// TWO THINGS THESE CASES DELIBERATELY DO NOT ASSERT, because the design forbids
// them: that anything fails, and that anything is re-sent. A parked turn is one
// dispatch that has not left yet — zero sends, not two — and connectivity
// returning must move the WORDS and nothing else. `AtMostOnceDispatchInvariantTests`
// owns that half.

import XCTest
@testable import Conduck

@MainActor
final class ParkedConverseTurnRowHonestyTests: XCTestCase {

    /// The founder's airplane-mode repro named this gateway, and a gateway name
    /// is the whole point: the parked phases must never carry one.
    private let gateway = "LiteLLM"

    private var registry: InFlightTurnRegistry { InFlightTurnRegistry.shared }

    override func setUp() async throws {
        try await super.setUp()
        InFlightTurnRegistry._resetForTesting()
        NetworkPathObserver._setPathUnsatisfiedForTesting(nil)
    }

    override func tearDown() async throws {
        InFlightTurnRegistry._resetForTesting()
        NetworkPathObserver._setPathUnsatisfiedForTesting(nil)
        try await super.tearDown()
    }

    // MARK: - Harness

    private func makeViewModel(_ id: UUID) -> ConversationDetailViewModel {
        let vm = ConversationDetailViewModel(conversationID: id)
        vm.backendDisplayName = gateway
        return vm
    }

    /// EXACTLY the projection `ConversationThreadView.thinkingIndicator`
    /// performs — the resolved phase, the VM's bound gateway name, and the same
    /// conservative `.sending` fallback. Restating it here is what makes these
    /// assertions statements about what a user READS rather than about an enum.
    private func threadRowWords(_ vm: ConversationDetailViewModel) -> String {
        ThinkingIndicator.label(
            phase: vm.liveTurnPhase ?? .sending,
            backendName: vm.backendDisplayName
        )
    }

    /// EXACTLY the projection the conversation list row performs for a `.live`
    /// row: `ConversationRowActivity.livePhase` into `ConversationActivityCopy`.
    private func listRowWords(_ conversationID: UUID) -> String {
        ConversationActivityCopy.working(
            .live,
            gatewayName: gateway,
            phase: ConversationRowActivity.livePhase(conversationID)?.phase ?? .answering
        )
    }

    /// The words the row is FORBIDDEN to show before the request body departs —
    /// the exact string both device repros put on screen.
    private var theWorkingClaim: String {
        ThinkingIndicator.label(phase: .answering, backendName: gateway)
    }

    // MARK: - The original defect

    /// WOULD HAVE CAUGHT THE ORIGINAL DEFECT (airplane-mode repro). A turn is
    /// claimed, this device has no usable path, and nothing has been dispatched.
    /// Before the fix this row read "LiteLLM is answering… 2:40".
    func testAParkedTurnWithNoRouteOutNeverShowsTheWorkingCopy_wouldHaveCaughtTheOriginalDefect() {
        let id = UUID()
        registry.noteBegan(id, lane: .viewModel, isCancellable: true)
        NetworkPathObserver._setPathUnsatisfiedForTesting(true)

        let vm = makeViewModel(id)
        XCTAssertEqual(vm.liveTurnPhase, .waitingForNetwork)
        XCTAssertNil(vm.liveTurnDispatchedAt,
                     "nothing has left the device, so there is no hand-off to stamp")

        let words = threadRowWords(vm)
        XCTAssertNotEqual(
            words, theWorkingClaim,
            "the row claimed the gateway was working on a turn that has not left "
                + "the device — the exact sentence the airplane-mode repro put on "
                + "screen for 2:40 while nothing was in flight"
        )
        XCTAssertFalse(
            words.contains(gateway),
            "no gateway is involved in a device with no route out; naming the "
                + "user's server implicates it for their own radio"
        )
        XCTAssertEqual(words, listRowWords(id),
                       "the list row must not tell a different story than the thread")
    }

    /// WOULD HAVE CAUGHT THE ORIGINAL DEFECT (refused-host repro,
    /// `https://127.0.0.1:1`). The device HAS a route; the host simply refuses,
    /// and `nsurlsessiond` retries out of process, so no byte ever departs and no
    /// transport error surfaces. Before the fix this row read
    /// "Throwaway is answering… 1:39".
    ///
    /// The row must say `Sending…` here and NOT "Waiting for a connection…":
    /// claiming the device is offline when a route exists would be a different
    /// false statement, and — worse — an implicit claim of non-delivery.
    func testARefusedGatewayThatStillHasARouteNeverShowsTheWorkingCopy_wouldHaveCaughtTheOriginalDefect() {
        let id = UUID()
        registry.noteBegan(id, lane: .viewModel, isCancellable: true)
        NetworkPathObserver._setPathUnsatisfiedForTesting(false)

        let vm = makeViewModel(id)
        XCTAssertEqual(vm.liveTurnPhase, .sending)

        let words = threadRowWords(vm)
        XCTAssertNotEqual(
            words, theWorkingClaim,
            "a refused connection retried out of process has handed the gateway "
                + "nothing; the row may not say it is answering"
        )
        XCTAssertFalse(words.contains(gateway))
        XCTAssertEqual(words, ThinkingIndicator.label(phase: .sending, backendName: gateway))
        XCTAssertNotEqual(
            words,
            ThinkingIndicator.label(phase: .waitingForNetwork, backendName: gateway),
            "a route exists, so the row must not claim the device is offline — "
                + "that reading would send the user to check their radio while "
                + "their gateway is the thing refusing"
        )
        XCTAssertEqual(words, listRowWords(id))
    }

    /// The two parked states are not interchangeable: one is the user's radio,
    /// the other is their gateway not answering the door, and the remedies
    /// differ. A single "not sent yet" word for both would send an airplane-mode
    /// user to check their server.
    func testTheTwoParkedStatesReadDifferently() {
        let id = UUID()
        registry.noteBegan(id, lane: .viewModel, isCancellable: true)
        let vm = makeViewModel(id)

        NetworkPathObserver._setPathUnsatisfiedForTesting(true)
        let offlineWords = threadRowWords(vm)
        NetworkPathObserver._setPathUnsatisfiedForTesting(false)
        let refusedWords = threadRowWords(vm)

        XCTAssertNotEqual(offlineWords, refusedWords)
        for words in [offlineWords, refusedWords] {
            XCTAssertNotEqual(words, theWorkingClaim)
            XCTAssertFalse(words.contains(gateway))
        }
    }

    // MARK: - Connectivity returning

    /// THE STATE MACHINE'S CENTRAL TRANSITION. The radio comes back, the parked
    /// request departs, and the row is finally entitled to name the gateway —
    /// with NO new dispatch behind it. The claim the user has been watching is
    /// the same claim throughout: nothing re-enqueued, nothing re-sent, and the
    /// only thing that changed is what the row is allowed to say.
    func testConnectivityReturningMovesTheRowToWorkingWithoutANewDispatch() {
        let id = UUID()
        let claimed = Date().addingTimeInterval(-90)
        let token = registry.noteBegan(id, lane: .viewModel, isCancellable: true, at: claimed)
        NetworkPathObserver._setPathUnsatisfiedForTesting(true)

        let vm = makeViewModel(id)
        XCTAssertEqual(vm.liveTurnPhase, .waitingForNetwork)
        XCTAssertEqual(vm.liveTurnPhaseSince, claimed,
                       "while parked the clock reports how long the TURN has waited")

        // The radio returns, and the body departs. `noteDispatched` is the only
        // event: no second `noteBegan`, no re-enqueue, no new task.
        NetworkPathObserver._setPathUnsatisfiedForTesting(false)
        let handoff = Date()
        registry.noteDispatched(id, at: handoff)

        XCTAssertEqual(vm.liveTurnPhase, .answering)
        XCTAssertEqual(threadRowWords(vm), theWorkingClaim)
        XCTAssertEqual(listRowWords(id), theWorkingClaim)

        // ONE claim, still. Releasing the original token must take the whole row
        // dark — a second claim minted anywhere in that transition would leave
        // this conversation live and prove a second dispatch happened.
        registry.noteEnded(token)
        XCTAssertNil(
            vm.liveTurnStartedAt,
            "the turn that finally departed is the SAME turn that was parked; a "
                + "surviving claim here means something re-dispatched it"
        )
    }

    /// The clock restarts at the hand-off, and that is correct: the gateway's
    /// clock did not start until the body reached it. A counter that carried the
    /// parked minutes into "is answering" would report a wait the gateway never
    /// had.
    func testTheWorkingClockCountsFromTheHandoffNotFromTheParkedWait() {
        let id = UUID()
        let claimed = Date().addingTimeInterval(-300)
        let handoff = Date().addingTimeInterval(-5)
        registry.noteBegan(id, lane: .viewModel, isCancellable: true, at: claimed)
        NetworkPathObserver._setPathUnsatisfiedForTesting(true)

        let vm = makeViewModel(id)
        XCTAssertEqual(vm.liveTurnPhaseSince, claimed)

        NetworkPathObserver._setPathUnsatisfiedForTesting(false)
        registry.noteDispatched(id, at: handoff)
        XCTAssertEqual(vm.liveTurnPhase, .answering)
        XCTAssertEqual(
            vm.liveTurnPhaseSince, handoff,
            "5 minutes of airplane-mode parking beside \"is answering\" is the "
                + "same false claim in numeric form"
        )
        XCTAssertEqual(vm.liveTurnStartedAt, claimed,
                       "the claim itself is untouched — only the phase's stamp moved")
    }

    /// MONOTONE. The path dropping again after the body departed must not walk
    /// the row back into a phase that implies nothing was sent: the gateway may
    /// well hold the turn and be working on it, and "Waiting for a connection…"
    /// there would be an implicit claim of non-delivery this client cannot make.
    func testTheRowNeverWalksBackOutOfWorkingWhenThePathDropsAgain() {
        let id = UUID()
        registry.noteBegan(id, lane: .viewModel, isCancellable: true)
        let handoff = Date().addingTimeInterval(-10)
        registry.noteDispatched(id, at: handoff)
        let vm = makeViewModel(id)
        XCTAssertEqual(vm.liveTurnPhase, .answering)

        NetworkPathObserver._setPathUnsatisfiedForTesting(true)
        XCTAssertEqual(vm.liveTurnPhase, .answering,
                       "departed bytes outrank the path reading, deliberately")
        XCTAssertEqual(vm.liveTurnPhaseSince, handoff)

        // An out-of-process connection retry re-reports departure later. The
        // stamp must not move, or the clock would silently restart mid-turn.
        registry.noteDispatched(id, at: Date().addingTimeInterval(60))
        XCTAssertEqual(vm.liveTurnPhaseSince, handoff)
    }

    // MARK: - The reaping horizon is not a cliff the row falls off

    /// A turn parked longer than `InFlightTurnRegistry.claimTTL` still gets its
    /// words right when the body finally departs. The departure edge fires ONCE
    /// per task, so a stamp dropped here is dropped forever: the row would read
    /// "Sending…" for the whole time the gateway was answering, and — with the
    /// radio blipping — "Waiting for a connection…", which asserts non-delivery
    /// of a turn the gateway demonstrably holds.
    ///
    /// `testTheRowNeverWalksBackOutOfWorkingWhenThePathDropsAgain` varies only
    /// the PATH reading; this pair varies claim AGE, which is the other way the
    /// monotonicity promise can be broken.
    func testADepartureAfterALongParkStillMovesTheRowToWorking() {
        let id = UUID()
        registry.noteBegan(
            id, lane: .viewModel, isCancellable: true,
            at: Date().addingTimeInterval(-InFlightTurnRegistry.claimTTL - 120)
        )
        NetworkPathObserver._setPathUnsatisfiedForTesting(false)

        let vm = makeViewModel(id)
        registry.noteDispatched(id, lane: .backgroundConverse, isCancellable: true)

        XCTAssertEqual(vm.liveTurnPhase, .answering)
        XCTAssertEqual(threadRowWords(vm), theWorkingClaim)
        XCTAssertEqual(listRowWords(id), theWorkingClaim,
                       "and the list must not be left hedging while the thread names the gateway")
    }

    /// The mirror image: a turn that DID depart keeps saying so once the claim
    /// is older than the horizon. Reaped on its birth date alone, this row
    /// walked backwards from "{Gateway} is answering… 2:00" to "Sending…" with
    /// the counter jumping to the whole elapsed wait.
    func testAWorkingRowDoesNotWalkBackwardsWhenTheClaimOutlivesTheHorizon() {
        let id = UUID()
        let claimed = Date().addingTimeInterval(-InFlightTurnRegistry.claimTTL - 60)
        let handoff = Date().addingTimeInterval(-120)
        registry.noteBegan(id, lane: .viewModel, isCancellable: true, at: claimed)
        registry.noteDispatched(id, at: handoff)
        NetworkPathObserver._setPathUnsatisfiedForTesting(false)

        let vm = makeViewModel(id)
        XCTAssertEqual(vm.liveTurnPhase, .answering)
        XCTAssertEqual(vm.liveTurnPhaseSince, handoff)
        XCTAssertEqual(threadRowWords(vm), theWorkingClaim)
        XCTAssertEqual(listRowWords(id), theWorkingClaim)
    }

    // MARK: - The two surfaces agree

    /// The list row and the thread read the same registry facts through the same
    /// resolver, so they can never disagree about whether the gateway has been
    /// handed anything. A user who sees "is answering" in the list and "Sending…"
    /// in the thread learns only that one of them is lying.
    func testTheListRowSaysTheSameWordsAsTheThreadInEveryPhase() {
        let id = UUID()
        registry.noteBegan(id, lane: .viewModel, isCancellable: true)
        let vm = makeViewModel(id)

        NetworkPathObserver._setPathUnsatisfiedForTesting(true)
        XCTAssertEqual(threadRowWords(vm), listRowWords(id))
        XCTAssertEqual(vm.liveTurnPhase, ConversationRowActivity.livePhase(id)?.phase)

        NetworkPathObserver._setPathUnsatisfiedForTesting(false)
        XCTAssertEqual(threadRowWords(vm), listRowWords(id))
        XCTAssertEqual(vm.liveTurnPhase, ConversationRowActivity.livePhase(id)?.phase)

        registry.noteDispatched(id)
        XCTAssertEqual(threadRowWords(vm), listRowWords(id))
        XCTAssertEqual(vm.liveTurnPhase, ConversationRowActivity.livePhase(id)?.phase)
    }

    // MARK: - The way out

    /// Nothing in the app bounds a parked wait, so the user's own way out has to
    /// be lit in EVERY phase. The wait indicator is likewise a claim that a turn
    /// is live HERE, never a claim that the gateway is working — so it stays up
    /// while parked, with honest words beside it.
    func testStopAndTheWaitIndicatorStayLitWhileParked() {
        let id = UUID()
        registry.noteBegan(id, lane: .viewModel, isCancellable: true)
        let vm = makeViewModel(id)

        for unsatisfied in [true, false] {
            NetworkPathObserver._setPathUnsatisfiedForTesting(unsatisfied)
            XCTAssertTrue(
                vm.canStopLiveTurn,
                "Stop is the ONLY bound on this wait; a phase that hid it would "
                    + "leave the user with no way out at all"
            )
            XCTAssertTrue(vm.showsGatewayWaitIndicator,
                          "the gate means a turn is live here, not that the gateway is working")
            XCTAssertNotNil(vm.inFlightTurnToken,
                            "a Stop rendered here must carry the identity `cancelInFlight` compares against")
        }
    }

    // MARK: - Across a relaunch

    /// A turn that outlived a process kill comes back through `reconcile()`, not
    /// through a claim this process minted. If the probe reports its body already
    /// departed, the row must resolve straight to the working copy — regressing a
    /// genuinely in-flight turn to "Sending…" for the rest of its life would be
    /// the mirror-image lie.
    func testARelaunchedTurnWhoseBodyAlreadyDepartedDoesNotRegressToSending() async {
        let id = UUID()
        registry.addProbe(lane: .backgroundConverse, isCancellable: true) { [id] in
            [id: true]
        }
        await registry.reconcile()

        NetworkPathObserver._setPathUnsatisfiedForTesting(false)
        let vm = makeViewModel(id)
        XCTAssertEqual(
            vm.liveTurnPhase, .answering,
            "the cross-launch `countOfBytesSent` read is what keeps a relaunch "
                + "from under-reporting a turn the gateway already has"
        )
        XCTAssertEqual(threadRowWords(vm), theWorkingClaim)
    }

    /// The same relaunch, with the probe reporting NOTHING has departed: the row
    /// stays on the conservative side rather than inheriting a claim it cannot
    /// support.
    func testARelaunchedTurnThatHasSentNothingStaysOnTheConservativeSide() async {
        let id = UUID()
        registry.addProbe(lane: .backgroundConverse, isCancellable: true) { [id] in
            [id: false]
        }
        await registry.reconcile()

        NetworkPathObserver._setPathUnsatisfiedForTesting(false)
        let vm = makeViewModel(id)
        XCTAssertEqual(vm.liveTurnPhase, .sending)
        XCTAssertNotEqual(threadRowWords(vm), theWorkingClaim)
        XCTAssertTrue(vm.canStopLiveTurn,
                      "the background converse lane registers a real cancel handle")
    }
}
