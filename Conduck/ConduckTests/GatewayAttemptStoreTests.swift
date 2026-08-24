// SPDX-License-Identifier: Apache-2.0

// Conduck
// GatewayAttemptStoreTests.swift
//
// The gateway-attempt ledger's store contract, which is really a contract about
// what measurement is ALLOWED TO COST. Four rules carry the whole file:
//
//   • CAPTURE IS FAIL-OPEN. A begin that cannot insert returns nil and the turn
//     dispatches anyway; a landing whose attempt row never existed still lands
//     the reply and still flips the user turn. The ledger is auxiliary, so a
//     defect in it may cost a measurement and may never cost a message. The
//     hardest version of that — the combined SAVE itself throwing — is driven
//     here through the store's `#if DEBUG` fault-injection seam, because no data
//     shape can produce it (every attempt column is optional and unconstrained).
//   • EXACTLY ONE TERMINAL TRANSITION. An attempt leaves `inFlight` once. A
//     second callback — a relaunched process replaying a completion, a cancel
//     racing a success — finds a terminal row, writes nothing, and does not
//     insert a second reply either.
//   • REPLY IDEMPOTENCY DOES NOT DEPEND ON THE LEDGER. The dedupe is on
//     `agentMessageID`, so it holds with `attempt: nil` — a store whose only
//     duplicate guard were the attempt row would insert twice exactly when
//     measurement had already failed.
//   • ORPHANS ARE INVISIBLE, NOT DELETED. An attempt whose conversation this
//     device cannot resolve is filtered out of every read and left in the store,
//     because mirroring cannot tell "the parent was deleted" from "the parent
//     has not imported yet". These tests prove the distinction by RE-CREATING
//     the conversation under its original id: a filtered row reappears, a
//     deleted one does not.
//
// Each test builds its OWN isolated `inMemory` store (mirrors
// `ConversationStoreDedupeTests`) — no `.shared` singleton, no App Group sqlite.

import XCTest
import CoreData
@testable import Conduck

final class GatewayAttemptStoreTests: XCTestCase {

    private func makeStore() -> ConversationStore {
        ConversationStore(inMemory: true)
    }

    /// A conversation with one `sending` user turn — the shape every dispatch
    /// hands the ledger.
    private func seedTurn(
        in store: ConversationStore,
        conversationID: UUID? = nil
    ) async throws -> (conversationID: UUID, userMessageID: UUID) {
        let convo = try await store.createConversation(
            id: conversationID ?? UUID(), backend: "openclaw"
        )
        let user = try await store.appendMessage(
            role: "user",
            text: "how do I renew the cert",
            conversationID: convo.id,
            sourceDevice: "iphone-text",
            status: "sending"
        )
        return (convo.id, user.id)
    }

    private func makeDraft(
        attemptID: UUID = UUID(),
        conversationID: UUID,
        userMessageID: UUID,
        gatewayRef: String = "openclaw",
        origin: GatewayAttemptOrigin = .app,
        inputMode: GatewayInputMode = .text,
        requestedModel: String? = "glm-4.7"
    ) -> GatewayAttemptDraft {
        GatewayAttemptDraft(
            attemptID: attemptID,
            conversationID: conversationID,
            userMessageID: userMessageID,
            gatewayRef: gatewayRef,
            origin: origin,
            inputMode: inputMode,
            requestedModel: requestedModel
        )
    }

    private func makeMetadata() -> GatewayResponseMetadata {
        GatewayResponseMetadata(
            reportedModel: "glm-4.7",
            reportedResponseID: "chatcmpl-abc",
            finishReason: "stop",
            reportedInputTokens: 1_200,
            reportedOutputTokens: 340,
            reportedTotalTokens: 1_540
        )
    }

    // MARK: - Begin

    func testBeginOpensOneInFlightRowCarryingTheDraftsFacts() async throws {
        let store = makeStore()
        let seed = try await seedTurn(in: store)
        let draft = makeDraft(conversationID: seed.conversationID, userMessageID: seed.userMessageID)

        let context = await store.beginGatewayAttempt(draft: draft)
        let opened = try XCTUnwrap(context, "A begin against a live conversation must insert.")
        XCTAssertEqual(opened.attemptID, draft.attemptID,
                       "The candidate id the transport minted IS the row's id.")

        let stored = try await store.fetchGatewayAttempts()
        XCTAssertEqual(stored.count, 1)
        let row = try XCTUnwrap(stored.first)
        XCTAssertEqual(row.id, draft.attemptID)
        XCTAssertEqual(row.conversationID, seed.conversationID)
        XCTAssertEqual(row.userMessageID, seed.userMessageID)
        XCTAssertEqual(row.gatewayRef, "openclaw")
        XCTAssertEqual(row.origin, .app)
        XCTAssertEqual(row.inputMode, .text)
        XCTAssertEqual(row.requestedModel, "glm-4.7")
        XCTAssertEqual(row.outcome, .inFlight,
                       "An insert only ever stamps inFlight — a terminal value is a landing's to write.")
        XCTAssertEqual(row.startedAt, opened.startedAt,
                       "The context must report the instant the row actually carries.")
        XCTAssertNil(row.completedAt)
        XCTAssertEqual(row.recordVersion, GatewayAttemptRecord.currentRecordVersion)
        XCTAssertNil(row.reportedTotalTokens,
                     "Nothing has been reported yet — a fresh row must not fabricate a zero.")
    }

    func testBeginStoresTheScalarsEvenWhenTheUserMessageDoesNotResolve() async throws {
        let store = makeStore()
        let convo = try await store.createConversation(backend: "hermes")
        // No `Message` with this id — the relationship cannot be set, the
        // scalars still must be.
        let draft = makeDraft(conversationID: convo.id, userMessageID: UUID(), gatewayRef: "hermes")

        let context = await store.beginGatewayAttempt(draft: draft)
        XCTAssertNotNil(context, "A missing user row is not a reason to refuse the measurement.")

        let stored = try await store.fetchGatewayAttempts()
        XCTAssertEqual(stored.first?.userMessageID, draft.userMessageID)
        XCTAssertEqual(stored.first?.gatewayRef, "hermes")
    }

    func testBeginRefusesToOpenTheSameAttemptTwice() async throws {
        let store = makeStore()
        let seed = try await seedTurn(in: store)
        let draft = makeDraft(conversationID: seed.conversationID, userMessageID: seed.userMessageID)

        let first = await store.beginGatewayAttempt(draft: draft)
        XCTAssertNotNil(first)
        let second = await store.beginGatewayAttempt(draft: draft)
        XCTAssertNil(second, "One attempt id opens one row — a re-entrant begin is not a dispatch.")

        let stored = try await store.fetchGatewayAttempts()
        XCTAssertEqual(stored.count, 1)
    }

    // MARK: - Terminalize

    func testTerminalizeClosesAnInFlightRowWithTimingAndMetadata() async throws {
        let store = makeStore()
        let seed = try await seedTurn(in: store)
        let draft = makeDraft(conversationID: seed.conversationID, userMessageID: seed.userMessageID)
        _ = await store.beginGatewayAttempt(draft: draft)

        let completedAt = Date()
        await store.terminalizeGatewayAttempt(
            TerminalAttemptObservation(
                attemptID: draft.attemptID,
                completedAt: completedAt,
                outcome: .succeeded,
                metadata: makeMetadata()
            )
        )

        let stored = try await store.fetchGatewayAttempts()
        let row = try XCTUnwrap(stored.first)
        XCTAssertEqual(row.outcome, .succeeded)
        XCTAssertEqual(row.completedAt, completedAt)
        XCTAssertEqual(row.reportedModel, "glm-4.7")
        XCTAssertEqual(row.reportedResponseID, "chatcmpl-abc")
        XCTAssertEqual(row.finishReason, "stop")
        XCTAssertEqual(row.reportedInputTokens, 1_200)
        XCTAssertEqual(row.reportedOutputTokens, 340)
        XCTAssertEqual(row.reportedTotalTokens, 1_540)
    }

    func testTerminalizeIsUpdateOnlyAndNeverReopensATerminalRow() async throws {
        let store = makeStore()
        let seed = try await seedTurn(in: store)
        let draft = makeDraft(conversationID: seed.conversationID, userMessageID: seed.userMessageID)
        _ = await store.beginGatewayAttempt(draft: draft)

        let first = Date(timeIntervalSince1970: 1_800_000_000)
        await store.terminalizeGatewayAttempt(
            TerminalAttemptObservation(
                attemptID: draft.attemptID, completedAt: first, outcome: .cancelled
            )
        )
        // The late callback: a success arriving after the turn was cancelled.
        await store.terminalizeGatewayAttempt(
            TerminalAttemptObservation(
                attemptID: draft.attemptID,
                completedAt: first.addingTimeInterval(30),
                outcome: .succeeded,
                metadata: makeMetadata()
            )
        )

        let stored = try await store.fetchGatewayAttempts()
        let row = try XCTUnwrap(stored.first)
        XCTAssertEqual(row.outcome, .cancelled, "One terminal transition, and the first one wins.")
        XCTAssertEqual(row.completedAt, first)
        XCTAssertNil(row.reportedTotalTokens,
                     "A suppressed terminal write must not leak its metadata into the row either.")
    }

    func testTerminalizeStoresNoTokensWhenTheGatewayReportedNothing() async throws {
        let store = makeStore()
        let seed = try await seedTurn(in: store)
        let draft = makeDraft(conversationID: seed.conversationID, userMessageID: seed.userMessageID)
        _ = await store.beginGatewayAttempt(draft: draft)

        await store.terminalizeGatewayAttempt(
            TerminalAttemptObservation(
                attemptID: draft.attemptID,
                completedAt: Date(),
                outcome: .failed,
                appErrorCode: 42,
                metadata: GatewayResponseMetadata()
            )
        )

        let stored = try await store.fetchGatewayAttempts()
        let row = try XCTUnwrap(stored.first)
        XCTAssertEqual(row.outcome, .failed)
        XCTAssertEqual(row.appErrorCode, 42)
        XCTAssertNil(row.reportedModel)
        XCTAssertNil(row.reportedInputTokens)
        XCTAssertNil(row.reportedOutputTokens)
        XCTAssertNil(row.reportedTotalTokens,
                     "An empty parse is 'the gateway reported nothing', not six zeroes.")
    }

    func testTerminalizeIsANoOpForAnAttemptThatWasNeverOpened() async throws {
        let store = makeStore()
        _ = try await seedTurn(in: store)

        await store.terminalizeGatewayAttempt(
            TerminalAttemptObservation(attemptID: UUID(), completedAt: Date(), outcome: .succeeded)
        )
        await store.terminalizeGatewayAttempt(
            TerminalAttemptObservation(attemptID: nil, completedAt: Date(), outcome: .succeeded)
        )

        let stored = try await store.fetchGatewayAttempts()
        XCTAssertTrue(stored.isEmpty,
                      "A terminal callback never RECREATES a row; measurement that never started stays absent.")
    }

    func testConcurrentTerminalizationsProduceExactlyOneTerminalWrite() async throws {
        let store = makeStore()
        let seed = try await seedTurn(in: store)
        let draft = makeDraft(conversationID: seed.conversationID, userMessageID: seed.userMessageID)
        _ = await store.beginGatewayAttempt(draft: draft)

        let cancelledAt = Date(timeIntervalSince1970: 1_800_000_000)
        let succeededAt = cancelledAt.addingTimeInterval(5)
        let cancel = TerminalAttemptObservation(
            attemptID: draft.attemptID, completedAt: cancelledAt, outcome: .cancelled
        )
        let success = TerminalAttemptObservation(
            attemptID: draft.attemptID, completedAt: succeededAt, outcome: .succeeded
        )
        // Two owners reaching the boundary together. Whichever wins, the row
        // must carry exactly ONE of them — never a blend, and never the second
        // overwriting the first.
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await store.terminalizeGatewayAttempt(cancel) }
            group.addTask { await store.terminalizeGatewayAttempt(success) }
        }

        let stored = try await store.fetchGatewayAttempts()
        let row = try XCTUnwrap(stored.first)
        switch row.outcome {
        case .cancelled:
            XCTAssertEqual(row.completedAt, cancelledAt)
        case .succeeded:
            XCTAssertEqual(row.completedAt, succeededAt)
        default:
            XCTFail("The row must carry one of the two observations, not \(row.outcome).")
        }
    }

    // MARK: - Half-materialised rows
    //
    // A row can arrive over CloudKit with its `outcome` column absent, and
    // WRITER AND READER HAVE TO MAKE THE SAME CALL ABOUT IT. The reader treats
    // absence as open (`hasStoredOutcome`), so the writer must too — reading it
    // as terminal instead would make the row permanently unclosable: no callback
    // could ever write it, and the dashboard would hedge it as `unconfirmed`
    // forever despite a real answer having been observed.

    func testATerminalCallbackClosesARowWhoseOutcomeColumnIsAbsent() async throws {
        let store = makeStore()
        let seed = try await seedTurn(in: store)
        let draft = makeDraft(conversationID: seed.conversationID, userMessageID: seed.userMessageID)
        let context = await store.beginGatewayAttempt(draft: draft)
        let opened = try XCTUnwrap(context)
        try await store.debugClearGatewayAttemptOutcome(attemptID: draft.attemptID)

        let halfStored = try await store.fetchGatewayAttempts()
        let half = try XCTUnwrap(halfStored.first)
        XCTAssertFalse(half.hasStoredOutcome, "The seam must really have removed the column.")
        XCTAssertEqual(
            half.effectiveOutcome(isLocallyLive: false, now: opened.startedAt.addingTimeInterval(1)),
            .pending,
            "The reader treats an absent outcome as open — the writer has to agree.")

        let completedAt = Date()
        await store.terminalizeGatewayAttempt(
            TerminalAttemptObservation(
                attemptID: draft.attemptID,
                completedAt: completedAt,
                outcome: .succeeded,
                metadata: makeMetadata()
            )
        )

        let stored = try await store.fetchGatewayAttempts()
        let row = try XCTUnwrap(stored.first)
        XCTAssertTrue(row.hasStoredOutcome)
        XCTAssertEqual(row.outcome, .succeeded,
                       "A row with no verdict stored is open, so the real verdict must land in it.")
        XCTAssertEqual(row.completedAt, completedAt)
        XCTAssertEqual(row.reportedTotalTokens, 1_540)
    }

    func testALandingForARowWithNoStoredOutcomeStillInsertsItsReply() async throws {
        let store = makeStore()
        let seed = try await seedTurn(in: store)
        let draft = makeDraft(conversationID: seed.conversationID, userMessageID: seed.userMessageID)
        _ = await store.beginGatewayAttempt(draft: draft)
        try await store.debugClearGatewayAttemptOutcome(attemptID: draft.attemptID)

        let completedAt = Date()
        // Unreadable measurement must never be mistaken for a concluded turn —
        // that inversion costs the user the reply the gateway actually returned.
        let record = try await store.completeAgentTurn(
            userMessageID: seed.userMessageID,
            userStatus: "sent",
            agentText: "Run certbot renew.",
            conversationID: seed.conversationID,
            sourceDevice: "iphone-text",
            agentMessageID: UUID(),
            attempt: TerminalAttemptObservation(
                attemptID: draft.attemptID, completedAt: completedAt, outcome: .succeeded
            )
        )

        XCTAssertEqual(record.text, "Run certbot renew.")
        let messages = try await store.fetchMessages(for: seed.conversationID)
        XCTAssertEqual(messages.count, 2, "The reply must land, not be suppressed as a duplicate.")
        XCTAssertEqual(messages.first(where: { $0.role == "user" })?.status, "sent")
        let stored = try await store.fetchGatewayAttempts()
        let row = try XCTUnwrap(stored.first)
        XCTAssertEqual(row.outcome, .succeeded)
        XCTAssertEqual(row.completedAt, completedAt)
    }

    // MARK: - completeAgentTurn: the combined save

    func testCompleteAgentTurnClosesTheLinkedAttemptInTheSameSave() async throws {
        let store = makeStore()
        let seed = try await seedTurn(in: store)
        let draft = makeDraft(conversationID: seed.conversationID, userMessageID: seed.userMessageID)
        _ = await store.beginGatewayAttempt(draft: draft)

        let completedAt = Date()
        _ = try await store.completeAgentTurn(
            userMessageID: seed.userMessageID,
            userStatus: "sent",
            agentText: "Run certbot renew.",
            conversationID: seed.conversationID,
            sourceDevice: "iphone-text",
            agentMessageID: UUID(),
            attempt: TerminalAttemptObservation(
                attemptID: draft.attemptID,
                completedAt: completedAt,
                outcome: .succeeded,
                metadata: makeMetadata()
            )
        )

        let messages = try await store.fetchMessages(for: seed.conversationID)
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages.first(where: { $0.role == "user" })?.status, "sent")

        let stored = try await store.fetchGatewayAttempts()
        let row = try XCTUnwrap(stored.first)
        XCTAssertEqual(row.outcome, .succeeded)
        XCTAssertEqual(row.completedAt, completedAt)
        XCTAssertEqual(row.reportedTotalTokens, 1_540)
    }

    func testCompleteAgentTurnLandsTheReplyWhenMeasurementNeverStarted() async throws {
        let store = makeStore()
        let seed = try await seedTurn(in: store)

        // The fail-open case: the transport minted an id, the begin insert never
        // landed, and the turn still has to complete exactly as it always did.
        let record = try await store.completeAgentTurn(
            userMessageID: seed.userMessageID,
            userStatus: "sent",
            agentText: "Run certbot renew.",
            conversationID: seed.conversationID,
            sourceDevice: "iphone-text",
            attempt: TerminalAttemptObservation(
                attemptID: UUID(), completedAt: Date(), outcome: .succeeded
            )
        )

        XCTAssertEqual(record.text, "Run certbot renew.")
        let messages = try await store.fetchMessages(for: seed.conversationID)
        XCTAssertEqual(messages.count, 2,
                       "A missing attempt row is a measurement no-op, not a lost reply.")
        XCTAssertEqual(messages.first(where: { $0.role == "user" })?.status, "sent")
        let stored = try await store.fetchGatewayAttempts()
        XCTAssertTrue(stored.isEmpty, "No row is fabricated after the fact.")
    }

    func testCompleteAgentTurnRequiresTheExactUserTurnWhenCorrelated() async throws {
        let store = makeStore()
        let seed = try await seedTurn(in: store)
        let draft = makeDraft(conversationID: seed.conversationID, userMessageID: seed.userMessageID)
        _ = await store.beginGatewayAttempt(draft: draft)

        do {
            _ = try await store.completeAgentTurn(
                userMessageID: UUID(),   // deleted mid-flight
                userStatus: "sent",
                agentText: "Run certbot renew.",
                conversationID: seed.conversationID,
                sourceDevice: "iphone-text",
                attempt: TerminalAttemptObservation(
                    attemptID: draft.attemptID, completedAt: Date(), outcome: .succeeded
                )
            )
            XCTFail("A correlated landing whose exact user turn is gone must not insert a reply.")
        } catch ConversationStore.StoreError.userMessageNotFound {
            // expected
        }

        let messages = try await store.fetchMessages(for: seed.conversationID)
        XCTAssertEqual(messages.count, 1, "Only the original user turn — no orphaned reply.")
    }

    func testCompleteAgentTurnKeepsTheLegacyToleranceWhenUncorrelated() async throws {
        let store = makeStore()
        let seed = try await seedTurn(in: store)

        // Byte-for-byte today's behavior: no attempt, missing user row, the
        // reply lands anyway because the conversation resolves.
        _ = try await store.completeAgentTurn(
            userMessageID: UUID(),
            userStatus: "sent",
            agentText: "Run certbot renew.",
            conversationID: seed.conversationID,
            sourceDevice: "iphone-text"
        )

        let messages = try await store.fetchMessages(for: seed.conversationID)
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages.first(where: { $0.role == "user" })?.status, "sending",
                       "The legacy flip is a no-op for an id that no longer resolves.")
    }

    // MARK: - completeAgentTurn: reply idempotency

    func testCompleteAgentTurnDedupesOnAgentMessageIDWithNoAttemptAtAll() async throws {
        let store = makeStore()
        let seed = try await seedTurn(in: store)
        let agentMessageID = UUID()

        let first = try await store.completeAgentTurn(
            userMessageID: seed.userMessageID,
            userStatus: "sent",
            agentText: "First landing.",
            conversationID: seed.conversationID,
            sourceDevice: "iphone-text",
            agentMessageID: agentMessageID
        )
        // The SAME dispatch replayed — different text, to prove nothing is
        // overwritten either.
        let second = try await store.completeAgentTurn(
            userMessageID: seed.userMessageID,
            userStatus: "sent",
            agentText: "Duplicate landing (must be ignored).",
            conversationID: seed.conversationID,
            sourceDevice: "iphone-text",
            agentMessageID: agentMessageID
        )

        XCTAssertEqual(second.id, first.id)
        XCTAssertEqual(second.text, "First landing.",
                       "Exactly-once reply insertion must hold with the ledger entirely absent.")
        let messages = try await store.fetchMessages(for: seed.conversationID)
        XCTAssertEqual(messages.filter { $0.role == "agent" }.count, 1)
    }

    func testCompleteAgentTurnDedupeStillFlipsTheUserTurn() async throws {
        let store = makeStore()
        let seed = try await seedTurn(in: store)
        let agentMessageID = UUID()

        _ = try await store.completeAgentTurn(
            userMessageID: seed.userMessageID,
            userStatus: "sent",
            agentText: "First landing.",
            conversationID: seed.conversationID,
            sourceDevice: "iphone-text",
            agentMessageID: agentMessageID
        )

        // A second `sending` turn in the same thread, answered by a landing that
        // reuses the already-stored reply id. The insert is skipped; the send
        // state still has to move, or the bubble spins forever.
        let secondUser = try await store.appendMessage(
            role: "user",
            text: "and after that?",
            conversationID: seed.conversationID,
            sourceDevice: "iphone-text",
            status: "sending"
        )
        _ = try await store.completeAgentTurn(
            userMessageID: secondUser.id,
            userStatus: "sent",
            agentText: "Duplicate landing (must be ignored).",
            conversationID: seed.conversationID,
            sourceDevice: "iphone-text",
            agentMessageID: agentMessageID
        )

        let messages = try await store.fetchMessages(for: seed.conversationID)
        XCTAssertEqual(messages.filter { $0.role == "agent" }.count, 1)
        XCTAssertEqual(messages.first(where: { $0.id == secondUser.id })?.status, "sent")
    }

    func testADuplicateCallbackReturnsTheStoredReplyAndLeavesTheAttemptAlone() async throws {
        let store = makeStore()
        let seed = try await seedTurn(in: store)
        let draft = makeDraft(conversationID: seed.conversationID, userMessageID: seed.userMessageID)
        _ = await store.beginGatewayAttempt(draft: draft)
        let agentMessageID = UUID()
        let firstCompletedAt = Date(timeIntervalSince1970: 1_800_000_000)

        _ = try await store.completeAgentTurn(
            userMessageID: seed.userMessageID,
            userStatus: "sent",
            agentText: "First landing.",
            conversationID: seed.conversationID,
            sourceDevice: "iphone-text",
            agentMessageID: agentMessageID,
            attempt: TerminalAttemptObservation(
                attemptID: draft.attemptID, completedAt: firstCompletedAt, outcome: .succeeded
            )
        )
        let replay = try await store.completeAgentTurn(
            userMessageID: seed.userMessageID,
            userStatus: "sent",
            agentText: "Replay (must be ignored).",
            conversationID: seed.conversationID,
            sourceDevice: "iphone-text",
            agentMessageID: agentMessageID,
            attempt: TerminalAttemptObservation(
                attemptID: draft.attemptID,
                completedAt: firstCompletedAt.addingTimeInterval(60),
                outcome: .succeeded
            )
        )

        XCTAssertEqual(replay.text, "First landing.")
        let messages = try await store.fetchMessages(for: seed.conversationID)
        XCTAssertEqual(messages.filter { $0.role == "agent" }.count, 1)
        let stored = try await store.fetchGatewayAttempts()
        let row = try XCTUnwrap(stored.first)
        XCTAssertEqual(row.completedAt, firstCompletedAt,
                       "A duplicate callback must not re-time an attempt that already closed.")
    }

    func testAnAlreadyTerminalAttemptSuppressesTheReplyEntirely() async throws {
        let store = makeStore()
        let seed = try await seedTurn(in: store)
        let draft = makeDraft(conversationID: seed.conversationID, userMessageID: seed.userMessageID)
        _ = await store.beginGatewayAttempt(draft: draft)

        // The user cancelled; the network answered anyway.
        let cancelledAt = Date(timeIntervalSince1970: 1_800_000_000)
        await store.terminalizeGatewayAttempt(
            TerminalAttemptObservation(
                attemptID: draft.attemptID, completedAt: cancelledAt, outcome: .cancelled
            )
        )

        do {
            _ = try await store.completeAgentTurn(
                userMessageID: seed.userMessageID,
                userStatus: "sent",
                agentText: "Late reply to a cancelled turn.",
                conversationID: seed.conversationID,
                sourceDevice: "iphone-text",
                agentMessageID: UUID(),
                attempt: TerminalAttemptObservation(
                    attemptID: draft.attemptID, completedAt: Date(), outcome: .succeeded
                )
            )
            XCTFail("A landing for an already-terminal attempt must insert nothing.")
        } catch ConversationStore.StoreError.attemptAlreadyTerminal {
            // expected — a benign no-op, not a store failure
        }

        let messages = try await store.fetchMessages(for: seed.conversationID)
        XCTAssertEqual(messages.count, 1, "No reply may appear under a turn the user cancelled.")
        let stored = try await store.fetchGatewayAttempts()
        let row = try XCTUnwrap(stored.first)
        XCTAssertEqual(row.outcome, .cancelled)
        XCTAssertEqual(row.completedAt, cancelledAt)
    }

    // MARK: - failTurn

    func testFailTurnClosesTheAttemptInTheSameSave() async throws {
        let store = makeStore()
        let seed = try await seedTurn(in: store)
        let draft = makeDraft(conversationID: seed.conversationID, userMessageID: seed.userMessageID)
        _ = await store.beginGatewayAttempt(draft: draft)

        let completedAt = Date()
        await store.failTurn(
            messageID: seed.userMessageID,
            classification: ConversationStore.TurnFailureClassification(
                failureCode: 17, wireCode: "image_unsupported"
            ),
            attempt: TerminalAttemptObservation(
                attemptID: draft.attemptID,
                completedAt: completedAt,
                outcome: .failed,
                appErrorCode: 17,
                metadata: makeMetadata()
            )
        )

        let messages = try await store.fetchMessages(for: seed.conversationID)
        XCTAssertEqual(messages.first(where: { $0.role == "user" })?.status, "failed")
        let stored = try await store.fetchGatewayAttempts()
        let row = try XCTUnwrap(stored.first)
        XCTAssertEqual(row.outcome, .failed)
        XCTAssertEqual(row.appErrorCode, 17)
        XCTAssertEqual(row.completedAt, completedAt)
        XCTAssertEqual(row.reportedTotalTokens, 1_540,
                       "A gateway can bill for work it then failed to return.")
    }

    func testFailTurnStillClassifiesWhenMeasurementNeverStarted() async throws {
        let store = makeStore()
        let seed = try await seedTurn(in: store)

        await store.failTurn(
            messageID: seed.userMessageID,
            classification: ConversationStore.TurnFailureClassification(failureCode: 17),
            attempt: TerminalAttemptObservation(
                attemptID: UUID(), completedAt: Date(), outcome: .failed, appErrorCode: 17
            )
        )

        let messages = try await store.fetchMessages(for: seed.conversationID)
        XCTAssertEqual(messages.first?.status, "failed",
                       "The Retry chip must never depend on the ledger.")
        let stored = try await store.fetchGatewayAttempts()
        XCTAssertTrue(stored.isEmpty)
    }

    func testFailTurnDoesNotReopenATerminalAttempt() async throws {
        let store = makeStore()
        let seed = try await seedTurn(in: store)
        let draft = makeDraft(conversationID: seed.conversationID, userMessageID: seed.userMessageID)
        _ = await store.beginGatewayAttempt(draft: draft)
        let cancelledAt = Date(timeIntervalSince1970: 1_800_000_000)
        await store.terminalizeGatewayAttempt(
            TerminalAttemptObservation(
                attemptID: draft.attemptID, completedAt: cancelledAt, outcome: .cancelled
            )
        )

        await store.failTurn(
            messageID: seed.userMessageID,
            classification: ConversationStore.TurnFailureClassification(failureCode: 17),
            attempt: TerminalAttemptObservation(
                attemptID: draft.attemptID, completedAt: Date(), outcome: .failed, appErrorCode: 17
            )
        )

        let messages = try await store.fetchMessages(for: seed.conversationID)
        XCTAssertEqual(messages.first?.status, "failed",
                       "The message transition is independent of the suppressed attempt write.")
        let stored = try await store.fetchGatewayAttempts()
        let row = try XCTUnwrap(stored.first)
        XCTAssertEqual(row.outcome, .cancelled)
        XCTAssertNil(row.appErrorCode)
    }

    // MARK: - Fail-open: the combined save itself failing
    //
    // The branch whose entire reason for existing is "a measurement defect must
    // never cost a reply". It cannot be reached by any input — the failure is a
    // Core Data save throwing — so these two drive it through the store's DEBUG
    // seam. The ORDER is what is under test: the core work is retried alone
    // first, and only then is the measurement retried best-effort.

    func testAFailedCombinedSaveStillLandsTheReplyExactlyOnceAndThenMeasuresIt() async throws {
        let store = makeStore()
        let seed = try await seedTurn(in: store)
        let draft = makeDraft(conversationID: seed.conversationID, userMessageID: seed.userMessageID)
        _ = await store.beginGatewayAttempt(draft: draft)

        let completedAt = Date()
        await store.debugSetAttemptBearingSaveFailure(true)
        let record = try await store.completeAgentTurn(
            userMessageID: seed.userMessageID,
            userStatus: "sent",
            agentText: "Run certbot renew.",
            conversationID: seed.conversationID,
            sourceDevice: "iphone-text",
            agentMessageID: UUID(),
            attempt: TerminalAttemptObservation(
                attemptID: draft.attemptID,
                completedAt: completedAt,
                outcome: .succeeded,
                metadata: makeMetadata()
            )
        )
        await store.debugSetAttemptBearingSaveFailure(false)

        XCTAssertEqual(record.text, "Run certbot renew.",
                       "The caller is still handed the reply it landed.")
        let messages = try await store.fetchMessages(for: seed.conversationID)
        XCTAssertEqual(messages.filter { $0.role == "agent" }.count, 1,
                       "The discarded context wrote nothing, so the retry inserts exactly one reply.")
        XCTAssertEqual(messages.first(where: { $0.role == "user" })?.status, "sent")

        let stored = try await store.fetchGatewayAttempts()
        let row = try XCTUnwrap(stored.first)
        XCTAssertEqual(row.outcome, .succeeded,
                       "The measurement is retried after the reply is safe — never instead of it.")
        XCTAssertEqual(row.completedAt, completedAt)
        XCTAssertEqual(row.reportedTotalTokens, 1_540)
    }

    func testAFailedCombinedSaveStillClassifiesAFailedTurnAndThenMeasuresIt() async throws {
        let store = makeStore()
        let seed = try await seedTurn(in: store)
        let draft = makeDraft(conversationID: seed.conversationID, userMessageID: seed.userMessageID)
        _ = await store.beginGatewayAttempt(draft: draft)

        let completedAt = Date()
        await store.debugSetAttemptBearingSaveFailure(true)
        await store.failTurn(
            messageID: seed.userMessageID,
            classification: ConversationStore.TurnFailureClassification(
                failureCode: 17, wireCode: "image_unsupported"
            ),
            attempt: TerminalAttemptObservation(
                attemptID: draft.attemptID,
                completedAt: completedAt,
                outcome: .failed,
                appErrorCode: 17
            )
        )
        await store.debugSetAttemptBearingSaveFailure(false)

        let messages = try await store.fetchMessages(for: seed.conversationID)
        XCTAssertEqual(messages.first(where: { $0.role == "user" })?.status, "failed",
                       "The Retry chip must appear even when the ledger's save threw.")
        let stored = try await store.fetchGatewayAttempts()
        let row = try XCTUnwrap(stored.first)
        XCTAssertEqual(row.outcome, .failed)
        XCTAssertEqual(row.appErrorCode, 17)
        XCTAssertEqual(row.completedAt, completedAt)
    }

    // MARK: - Deletion

    func testDeletingAConversationDeletesItsAttempts() async throws {
        let store = makeStore()
        let seed = try await seedTurn(in: store)
        let draft = makeDraft(conversationID: seed.conversationID, userMessageID: seed.userMessageID)
        _ = await store.beginGatewayAttempt(draft: draft)

        try await store.deleteConversation(id: seed.conversationID)
        // Re-create the thread under its ORIGINAL id: a merely FILTERED row
        // would become visible again here. Nothing does, so the row is gone.
        _ = try await store.createConversation(id: seed.conversationID, backend: "openclaw")

        let stored = try await store.fetchGatewayAttempts()
        XCTAssertTrue(stored.isEmpty, "Attempts live exactly as long as the history they measure.")
    }

    func testDeletingAConversationAlsoDeletesRelationshipLessAttempts() async throws {
        let store = makeStore()
        let convo = try await store.createConversation(backend: "openclaw")
        // No user `Message`, so no relationship and therefore no cascade — only
        // the explicit scalar sweep can reach this row.
        let draft = makeDraft(conversationID: convo.id, userMessageID: UUID())
        _ = await store.beginGatewayAttempt(draft: draft)

        try await store.deleteConversation(id: convo.id)
        _ = try await store.createConversation(id: convo.id, backend: "openclaw")

        let stored = try await store.fetchGatewayAttempts()
        XCTAssertTrue(stored.isEmpty,
                      "The scalar sweep is what covers a row the cascade cannot see.")
    }

    func testDeleteAllRemovesEveryAttemptIncludingRelationshipLessOnes() async throws {
        let store = makeStore()
        let linked = try await seedTurn(in: store)
        _ = await store.beginGatewayAttempt(
            draft: makeDraft(conversationID: linked.conversationID, userMessageID: linked.userMessageID)
        )
        let loose = try await store.createConversation(backend: "hermes")
        _ = await store.beginGatewayAttempt(
            draft: makeDraft(conversationID: loose.id, userMessageID: UUID(), gatewayRef: "hermes")
        )

        try await store.deleteAll()
        _ = try await store.createConversation(id: linked.conversationID, backend: "openclaw")
        _ = try await store.createConversation(id: loose.id, backend: "hermes")

        let stored = try await store.fetchGatewayAttempts()
        XCTAssertTrue(stored.isEmpty)
    }

    func testDeleteGatewayAttemptsRemovesRowsByScalarConversationID() async throws {
        let store = makeStore()
        let kept = try await seedTurn(in: store)
        let purged = try await seedTurn(in: store)
        _ = await store.beginGatewayAttempt(
            draft: makeDraft(conversationID: kept.conversationID, userMessageID: kept.userMessageID)
        )
        _ = await store.beginGatewayAttempt(
            draft: makeDraft(conversationID: purged.conversationID, userMessageID: purged.userMessageID)
        )

        await store.deleteGatewayAttempts(conversationID: purged.conversationID)

        let remaining = try await store.fetchGatewayAttempts()
        XCTAssertEqual(remaining.count, 1)
        XCTAssertEqual(remaining.first?.conversationID, kept.conversationID)
    }

    // MARK: - Orphan invisibility

    func testAnAttemptWhoseConversationIsAbsentIsInvisibleButNotDeleted() async throws {
        let store = makeStore()
        // A live conversation has to exist, or the filter would short-circuit
        // for a different reason than the one under test.
        _ = try await seedTurn(in: store)
        // A row that arrived ahead of the conversation it names — the
        // out-of-order import this rule exists for.
        let futureConversationID = UUID()
        let draft = makeDraft(conversationID: futureConversationID, userMessageID: UUID())
        _ = await store.beginGatewayAttempt(draft: draft)

        let hidden = try await store.fetchGatewayAttempts()
        XCTAssertTrue(hidden.isEmpty, "An unattributable attempt is left out of every read.")

        // The parent finally imports. The row must still be there.
        _ = try await store.createConversation(id: futureConversationID, backend: "openclaw")
        let visible = try await store.fetchGatewayAttempts()
        XCTAssertEqual(visible.count, 1)
        XCTAssertEqual(visible.first?.id, draft.attemptID,
                       "Absence of a parent is not evidence of deletion — the row was only hidden.")
    }

    // MARK: - Range reads

    func testFetchBoundsAttemptsOnTheirStartInstant() async throws {
        let store = makeStore()
        let seed = try await seedTurn(in: store)
        let draft = makeDraft(conversationID: seed.conversationID, userMessageID: seed.userMessageID)
        let context = await store.beginGatewayAttempt(draft: draft)
        let opened = try XCTUnwrap(context)

        let inside = try await store.fetchGatewayAttempts(
            from: opened.startedAt.addingTimeInterval(-1),
            to: opened.startedAt.addingTimeInterval(1)
        )
        XCTAssertEqual(inside.count, 1)

        let after = try await store.fetchGatewayAttempts(
            from: opened.startedAt.addingTimeInterval(60), to: nil
        )
        XCTAssertTrue(after.isEmpty)

        let before = try await store.fetchGatewayAttempts(
            from: nil, to: opened.startedAt.addingTimeInterval(-60)
        )
        XCTAssertTrue(before.isEmpty)
    }

    func testFetchReturnsAttemptsOldestFirst() async throws {
        let store = makeStore()
        let seed = try await seedTurn(in: store)
        let first = makeDraft(conversationID: seed.conversationID, userMessageID: seed.userMessageID)
        let second = makeDraft(conversationID: seed.conversationID, userMessageID: seed.userMessageID)
        _ = await store.beginGatewayAttempt(draft: first)
        _ = await store.beginGatewayAttempt(draft: second)

        let stored = try await store.fetchGatewayAttempts()
        XCTAssertEqual(stored.map(\.id), [first.attemptID, second.attemptID])
    }

    func testEarliestStartReportsTheOldestVisibleAttemptOnly() async throws {
        let store = makeStore()
        let empty = try await store.earliestGatewayAttemptStart()
        XCTAssertNil(empty, "An empty store has not started measuring anything.")

        // An orphan older than everything real: it must not become the date the
        // dashboard claims to be measuring since, because its history is gone.
        _ = await store.beginGatewayAttempt(
            draft: makeDraft(conversationID: UUID(), userMessageID: UUID())
        )
        let seed = try await seedTurn(in: store)
        let visible = makeDraft(conversationID: seed.conversationID, userMessageID: seed.userMessageID)
        let context = await store.beginGatewayAttempt(draft: visible)
        let opened = try XCTUnwrap(context)

        let earliest = try await store.earliestGatewayAttemptStart()
        XCTAssertEqual(earliest, opened.startedAt)
    }
}
