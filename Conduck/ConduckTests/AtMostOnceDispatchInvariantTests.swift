// SPDX-License-Identifier: Apache-2.0

// Conduck
// AtMostOnceDispatchInvariantTests.swift
//
// A TURN IS FAILED ONLY WHEN NON-DELIVERY IS PROVABLE. Everything else in the
// parked-converse design is presentation; this is the safety property, and these
// are the cases that defend it against a future change that looks like an
// improvement.
//
// WHY THE DIRECTION IS ASYMMETRIC, and why every case here is written around the
// asymmetry rather than around correctness in general. A turn wrongly left alive
// costs the user a row that keeps saying it is waiting, and a Stop they can press.
// A turn wrongly declared failed puts a Try Again chip beside a request the
// gateway may already hold — so the user re-sends a turn that is being answered,
// SPENDING THEIR MODEL BUDGET TWICE and, on an agent gateway with tools, letting
// the agent act on the world twice. There is no undo for either. That is the line
// this file exists to hold, and it is why every case that could go either way
// resolves to "leave it alone".
//
// THE HAZARD THIS DESIGN HAD TO NAVIGATE. On iPhone the converse hop rides a
// background `URLSession`: it waits for connectivity unconditionally, retries
// transport failures out of process, and neither is configurable. So a refused
// host, an unresolvable name and an aeroplane all look identical from inside the
// app — a live task that has sent nothing and reports no error. The tempting fix
// is a client-owned deadline that cancels such a task and calls it failed. It is
// rejected, and §4 of the design says why in full: after `resume()` the app owns
// no proof, `cancel()` on a background session is documented as asynchronous and
// is reported as sometimes not honoured at all, and Apple's undocumented
// background rate limiter can legitimately delay a headless dispatch past any
// deadline we could pick. A bound built on that would kill turns iOS was about to
// send.
//
// WHAT IS DRIVEN HERE: a real in-memory `ConversationStore` (CloudKit off in the
// seam), the real launch sweep with its real live-task exclusion set, the real
// `InFlightTurnRegistry` including `reconcile()`, the real `ConverseCancelVerdict`,
// and the real `AppError` code→copy round trip a persisted `failureCode` takes on
// its way to the user.
//
// THE ONE THING MIRRORED RATHER THAN CALLED is the four-line composition inside
// `BackgroundRemoteAgent`'s live-cancel branch — it lives inside a
// `URLSessionDataDelegate` callback that no unit test can deliver. `applyStopVerdict`
// below is that composition, and `ParkedConverseLaneDriftGuardTests` pins the
// delegate against it at source level, so the pair covers what a seam into the
// delegate would have: this file asserts what the composition DOES to a user's
// turn, the guard asserts the delegate still composes it that way.

import XCTest
@testable import Conduck

@MainActor
final class AtMostOnceDispatchInvariantTests: XCTestCase {

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

    private func makeStore() -> ConversationStore { ConversationStore(inMemory: true) }

    /// A conversation with one user turn sitting at `sending` — the state every
    /// parked turn is in.
    private func makePendingTurn(
        in store: ConversationStore
    ) async throws -> (conversationID: UUID, turn: MessageRecord) {
        let convo = try await store.createConversation(backend: "openclaw")
        let turn = try await store.appendMessage(
            role: "user", text: "book the table", conversationID: convo.id,
            sourceDevice: "phone", status: "sending"
        )
        return (convo.id, turn)
    }

    /// The launch sweep with every clock in the design collapsed — the turn
    /// stands in for one parked past the stale-`sending` grace, past the converse
    /// resource budget, past everything.
    ///
    /// THE PAUSE IS NOT DECORATION, and `ConversationStoreTests` carries the same
    /// one for the same reason: an append's stamp is quantised to its millisecond
    /// and then nudged one past the conversation's own last activity, so a turn
    /// written moments ago can sit a fraction of a millisecond in the FUTURE and
    /// miss a `cutoff` taken immediately after. Without it the sweep matches
    /// nothing at all — which makes the two "must not flip" cases below pass for
    /// the wrong reason, and makes the negative control that proves they mean
    /// something fail on whichever run happens to be fast enough.
    private func sweepWithEveryClockRunOut(
        _ store: ConversationStore,
        excluding: Set<UUID>
    ) async throws {
        try await Task.sleep(for: .milliseconds(10))
        await store.sweepStaleSendingUserTurns(
            olderThan: 0, excludingConversationIDs: excluding
        )
    }

    private func storedTurn(
        _ messageID: UUID, in conversationID: UUID, store: ConversationStore
    ) async throws -> MessageRecord {
        let messages = try await store.fetchMessages(for: conversationID)
        return try XCTUnwrap(messages.first { $0.id == messageID })
    }

    /// The live-cancel branch's composition, mirrored. Everything about WHICH
    /// outcome is reached comes from the real `ConverseCancelVerdict`; this only
    /// routes the outcome to the store writer the delegate routes it to.
    ///
    /// Deliberately posts nothing and notifies nobody, exactly as the delegate
    /// does: a user-initiated Stop is not a failure EVENT, so no push may fire
    /// and the macOS menu-bar failure dot must not light.
    @discardableResult
    private func applyStopVerdict(
        anyBytesDeparted: Bool,
        countOfBytesSent: Int64,
        pathIsUnsatisfied: Bool,
        store: ConversationStore,
        conversationID: UUID,
        userMessageID: UUID?
    ) async -> ConverseCancelVerdict.Outcome {
        let verdict = ConverseCancelVerdict.make(
            anyBytesDeparted: anyBytesDeparted,
            countOfBytesSent: countOfBytesSent,
            pathIsUnsatisfied: pathIsUnsatisfied
        )
        switch verdict {
        case .unknownDelivery:
            if let userMessageID {
                await store.markPendingUserTurn(messageID: userMessageID, to: "failed")
            } else {
                await store.markPendingUserTurns(conversationID: conversationID, to: "failed")
            }
        case .provableNonDelivery(let error):
            let classification = ConversationStore.TurnFailureClassification(
                failureCode: error.errorCode, wireCode: nil, hadHistoryImages: nil
            )
            if let userMessageID {
                await store.failTurn(messageID: userMessageID, classification: classification)
            } else {
                await store.failPendingUserTurns(
                    conversationID: conversationID, classification: classification
                )
            }
        }
        return verdict
    }

    // MARK: - THE INVARIANT

    /// THE MOST VALUABLE CASE IN THIS FILE. The device has a usable path and the
    /// host is merely refusing — the `https://127.0.0.1:1` repro, and equally the
    /// gateway that is down, the name that no longer resolves, and the turn
    /// waiting out iOS's background rate limiter. Nothing has departed, no error
    /// has surfaced, and the system is still retrying out of process.
    ///
    /// NOTHING IN THE APP MAY FAIL THAT TURN. The user did not ask for it to
    /// stop, so the app holds no proof of anything: a refused TCP connection this
    /// process can see is not proof that the retry behind it will not connect a
    /// second later, and an app-invented verdict here is a verdict about a
    /// request the app cannot observe.
    func testARefusedHostThatStillHasARouteIsNeverFailedByTheApp() async throws {
        let store = makeStore()
        let (conversationID, turn) = try await makePendingTurn(in: store)
        let attemptAtDispatch = turn.deliveryAttemptID

        // The lane's own report: this conversation is live, and its request body
        // has NOT departed. One value feeds both readers, exactly as
        // `ConduckApp` wires it — the registry (which drives the row) and the
        // launch sweep (the only writer that could resolve a `sending` turn).
        let laneReport: [UUID: Bool] = [conversationID: false]
        registry.addProbe(lane: .backgroundConverse, isCancellable: true) { laneReport }
        await registry.reconcile()
        NetworkPathObserver._setPathUnsatisfiedForTesting(false)

        // Let every clock in the design run out.
        try await sweepWithEveryClockRunOut(store, excluding: Set(laneReport.keys))

        let after = try await storedTurn(turn.id, in: conversationID, store: store)
        XCTAssertEqual(
            after.status, "sending",
            "the turn was declared failed while delivery was still possible. A "
                + "Try Again chip here invites the user to re-send a turn the "
                + "gateway may already be answering — double-spending their model "
                + "budget and letting an agent act on the world twice. Nothing "
                + "left this device, so nothing is proven, so nothing may be "
                + "written."
        )
        XCTAssertNil(after.failureCode,
                     "an unfailed turn carries no cause; there is nothing to classify")
        XCTAssertEqual(
            after.deliveryAttemptID, attemptAtDispatch,
            "a fresh delivery-attempt identity means some writer DECLARED this "
                + "turn failed — the mark the user is shown re-arms off exactly that"
        )

        // And the row is still honest about it rather than silently blank.
        XCTAssertEqual(ConversationRowActivity.livePhase(conversationID)?.phase, .sending)
    }

    /// THE NEGATIVE CONTROL, and the point of it is what protects the turn. The
    /// launch sweep resolves stale `sending` rows, and it would flip the very
    /// turn above — what holds it back is the LIVE-TASK EXCLUSION SET collected
    /// from the sessions at launch, not any claim about how long a turn can
    /// legitimately be in flight.
    ///
    /// That distinction is load-bearing because the resource-timeout constant was
    /// documented in four places as "the longest a turn can legitimately be in
    /// flight", and a background session falsifies it. Anyone who deletes the
    /// exclusion set because "the 600 s budget covers it" breaks this case.
    func testTheLiveTaskExclusionSetIsWhatProtectsAParkedTurnFromTheSweep() async throws {
        let store = makeStore()
        let (conversationID, turn) = try await makePendingTurn(in: store)

        // Same sweep, same turn, but the lane no longer reports the conversation
        // as live — i.e. the task really is gone.
        try await sweepWithEveryClockRunOut(store, excluding: [])

        let after = try await storedTurn(turn.id, in: conversationID, store: store)
        XCTAssertEqual(
            after.status, "failed",
            "with no live task behind it a stale `sending` row is a stranded turn "
                + "and must get its Retry affordance — if this stops flipping, the "
                + "protection above has become a leak instead of a guard"
        )
    }

    /// `InFlightTurnRegistry.claimTTL` borrows the converse resource timeout's
    /// value, and that borrowing has misled readers before: it is a REAPING
    /// HORIZON for a claim whose owning view model died, never a ceiling on a
    /// turn. A claim older than the TTL whose lane still reports the turn is
    /// re-minted by `reconcile()`, and the turn keeps running.
    func testAClaimAgeingPastItsTTLIsNotABoundOnTheTurn() async throws {
        let store = makeStore()
        let (conversationID, turn) = try await makePendingTurn(in: store)

        registry.noteBegan(
            conversationID, lane: .backgroundConverse, isCancellable: true,
            at: Date().addingTimeInterval(-InFlightTurnRegistry.claimTTL - 60)
        )
        XCTAssertNil(registry.liveSince(conversationID), "the stale claim has aged out")

        let laneReport: [UUID: Bool] = [conversationID: false]
        registry.addProbe(lane: .backgroundConverse, isCancellable: true) { laneReport }
        await registry.reconcile()

        XCTAssertNotNil(
            registry.liveSince(conversationID),
            "a turn the lane still reports is still live, whatever a claim's age says"
        )
        XCTAssertNil(registry.dispatchedSince(conversationID),
                     "and it still has not sent anything, so it still may not be called working")

        try await sweepWithEveryClockRunOut(store, excluding: Set(laneReport.keys))
        let after = try await storedTurn(turn.id, in: conversationID, store: store)
        XCTAssertEqual(after.status, "sending",
                       "an aged claim is a bookkeeping fact, never a verdict about a turn")
    }

    /// The numbers this design deliberately does not touch. Each was, or fed, a
    /// claim about how long a turn can be in flight; the design corrects the
    /// ARGUMENTS and leaves every value alone, so a diff that "tightens" one of
    /// them is changing behaviour nobody asked to change.
    func testTheDesignChangesNoTimeoutValue() {
        XCTAssertEqual(Constants.remoteAgentConverseResourceTimeout, 600)
        XCTAssertEqual(Constants.remoteAgentConverseRequestTimeout, 300)
        XCTAssertEqual(ConversationActivityResolver.staleSendingGrace, 1800)
        XCTAssertEqual(
            InFlightTurnRegistry.claimTTL, Constants.remoteAgentConverseResourceTimeout,
            "the claim horizon borrows this value; it does not derive a turn's lifetime from it"
        )
    }

    // MARK: - Stop, from each parked state

    /// STOP IS THE BOUND. From the offline state the client holds a real proof —
    /// zero departed bytes on a device with no route out — so the failed turn is
    /// classified, and the classification round-trips into copy that already
    /// ships. Before this, stopping a parked turn left an unexplained failed row.
    func testStopFromTheWaitingStateFailsTheTurnWithTheOfflineErrorThatAlreadyHasCopy() async throws {
        let store = makeStore()
        let (conversationID, turn) = try await makePendingTurn(in: store)

        let verdict = await applyStopVerdict(
            anyBytesDeparted: false, countOfBytesSent: 0, pathIsUnsatisfied: true,
            store: store, conversationID: conversationID, userMessageID: turn.id
        )
        XCTAssertEqual(verdict, .provableNonDelivery(.noInternetConnection))

        let after = try await storedTurn(turn.id, in: conversationID, store: store)
        XCTAssertEqual(after.status, "failed")
        XCTAssertEqual(after.failureCode, 3)
        XCTAssertNil(after.failureWireCode, "a client-side verdict carries no gateway wire code")

        // The persisted code is what a surface reconstructs the sentence from.
        let reconstructed = AppError.from(errorCode: try XCTUnwrap(after.failureCode), message: nil)
        XCTAssertEqual(reconstructed.errorCode, AppError.noInternetConnection.errorCode)
        XCTAssertEqual(reconstructed.errorDescription, AppError.noInternetConnection.errorDescription)
        XCTAssertNotNil(reconstructed.errorDescription)
        XCTAssertNotNil(
            reconstructed.recoverySuggestion(in: .neutral),
            "the offline case ships a remedy; a classification with no copy behind "
                + "it would be worse than the bare failure it replaced"
        )
    }

    /// The same Stop with a route present names a DIFFERENT cause, and it must:
    /// sending an airplane-mode user to check their gateway is a remedy pointed
    /// at the wrong machine. But so is the reverse, and this is the case that
    /// holds that half — the client knows only that nothing left, never why, so
    /// the cause it writes may name the stop and nothing else. At least four
    /// situations reach here (a refused host, an unresolvable name, a
    /// captive-portal network that reads as connected, and a turn still waiting
    /// out iOS's background rate limiter behind a perfectly healthy gateway),
    /// and the row the user reads has to be true in all four.
    func testStopWithARoutePresentNamesTheStopItselfAndNoMachine() async throws {
        let store = makeStore()
        let (conversationID, turn) = try await makePendingTurn(in: store)

        let verdict = await applyStopVerdict(
            anyBytesDeparted: false, countOfBytesSent: 0, pathIsUnsatisfied: false,
            store: store, conversationID: conversationID, userMessageID: turn.id
        )
        XCTAssertEqual(verdict, .provableNonDelivery(.turnStoppedBeforeSend))

        let after = try await storedTurn(turn.id, in: conversationID, store: store)
        XCTAssertEqual(after.status, "failed")
        XCTAssertEqual(after.failureCode, 76)

        let reconstructed = AppError.from(errorCode: try XCTUnwrap(after.failureCode), message: nil)
        XCTAssertEqual(reconstructed.errorCode, AppError.turnStoppedBeforeSend.errorCode)
        XCTAssertNotEqual(
            reconstructed.errorDescription,
            AppError.noInternetConnection.errorDescription,
            "the two Stop causes must not collapse into one sentence — one is a "
                + "fact about the radio, the other only about the stop"
        )
        XCTAssertNotNil(reconstructed.recoverySuggestion(in: .neutral))

        // THE ROW THE USER ACTUALLY READS, on the lane where the wrong word is
        // most expensive: a self-hosted ref, where "check your gateway" is an
        // instruction the reader can act on and waste an evening following.
        let row = reconstructed.descriptionWithRecovery(for: .builtin(.openclaw))
        XCTAssertFalse(
            row.localizedCaseInsensitiveContains("gateway"),
            "the row sends the user to debug a server that was never contacted: \(row)"
        )
        XCTAssertNil(
            DeclinedTurnPresentation.classify(
                failureCode: after.failureCode,
                failureWireCode: nil,
                turnHasOwnImages: false,
                hadHistoryImages: nil,
                hasResendableNonPhotoContent: true,
                wordlessTurn: .absent,
                ref: .builtin(.openclaw)
            ).troubleshootCode,
            "a Troubleshoot link here files the turn into the Diagnostics "
                + "recent-failure list as evidence against a gateway that "
                + "answered nothing because nothing was asked"
        )
    }

    /// THE INVARIANT AGAIN, on the Stop path. One byte on the wire withdraws the
    /// proof: the gateway may hold a request this client cannot see the end of.
    /// The turn still goes `failed` — leaving it spinning forever is not an
    /// option once the task is dead — but it carries NO cause, because the app
    /// does not know one.
    func testStopAfterASingleByteDepartedIsNeverClassifiedAsUndelivered() async throws {
        for (latch, counter) in [(true, Int64(0)), (false, Int64(1)), (true, Int64(4_096))] {
            let store = makeStore()
            let (conversationID, turn) = try await makePendingTurn(in: store)

            let verdict = await applyStopVerdict(
                anyBytesDeparted: latch, countOfBytesSent: counter,
                // Offline as well, to prove the path reading cannot manufacture a
                // proof the counters have already withdrawn.
                pathIsUnsatisfied: true,
                store: store, conversationID: conversationID, userMessageID: turn.id
            )
            XCTAssertEqual(verdict, .unknownDelivery)

            let after = try await storedTurn(turn.id, in: conversationID, store: store)
            XCTAssertEqual(after.status, "failed")
            XCTAssertNil(
                after.failureCode,
                "the turn was told the request never reached the gateway, on "
                    + "evidence that says the opposite (latch=\(latch), "
                    + "countOfBytesSent=\(counter)). A user who reads that and "
                    + "presses Try Again pays for the same turn twice and can make "
                    + "their agent act on the world twice."
            )
        }
    }

    /// A stopped turn is a turn the user can send again — deliberately, and by
    /// their own hand. This is the whole reason `failed` is written at all
    /// instead of leaving the row spinning: it is the affordance, not an
    /// automatic retry.
    func testAStoppedTurnKeepsItsRetryAffordance() async throws {
        let store = makeStore()
        let (conversationID, turn) = try await makePendingTurn(in: store)

        await applyStopVerdict(
            anyBytesDeparted: false, countOfBytesSent: 0, pathIsUnsatisfied: true,
            store: store, conversationID: conversationID, userMessageID: turn.id
        )
        let claimed = await store.beginRetry(messageID: turn.id)
        XCTAssertTrue(claimed, "Try Again must be able to claim a stopped turn")

        let after = try await storedTurn(turn.id, in: conversationID, store: store)
        XCTAssertEqual(after.status, "sending")
        XCTAssertNotEqual(
            after.deliveryAttemptID, turn.deliveryAttemptID,
            "a retry is a NEW delivery attempt — the user asked for the second send"
        )
    }

    /// The conversation-wide fallback (a relaunched turn whose metadata never
    /// carried a message id) must stay scoped to turns that are still pending.
    /// A Stop reaching backwards into an already-resolved turn would rewrite
    /// history the user has read.
    func testTheConversationWideStopOnlyTouchesTurnsThatAreStillPending() async throws {
        let store = makeStore()
        let convo = try await store.createConversation(backend: "openclaw")
        let settled = try await store.appendMessage(
            role: "user", text: "earlier", conversationID: convo.id,
            sourceDevice: "phone", status: "sent"
        )
        let pending = try await store.appendMessage(
            role: "user", text: "parked", conversationID: convo.id,
            sourceDevice: "phone", status: "sending"
        )

        await applyStopVerdict(
            anyBytesDeparted: false, countOfBytesSent: 0, pathIsUnsatisfied: true,
            store: store, conversationID: convo.id, userMessageID: nil
        )

        let settledAfter = try await storedTurn(settled.id, in: convo.id, store: store)
        XCTAssertEqual(
            settledAfter.status, "sent",
            "a delivered turn is not this Stop's business"
        )
        let after = try await storedTurn(pending.id, in: convo.id, store: store)
        XCTAssertEqual(after.status, "failed")
        XCTAssertEqual(after.failureCode, 3)
    }
}
