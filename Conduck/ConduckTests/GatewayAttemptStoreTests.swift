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
//   • USAGE HISTORY OUTLIVES THE CONVERSATIONS IT DESCRIBES. Deleting a thread
//     deletes its content and leaves its attempt rows standing and countable —
//     including the rows whose conversation this device never saw at all. The
//     only things that remove a row are the user clearing usage history and an
//     erase-everything, and both go through the same purge.
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
        requestedModel: String? = "glm-4.7",
        deviceClass: String? = "iphone",
        currentTurnInlineImageCount: Int = 0,
        priorTurnInlineImageCount: Int = 0,
        currentTurnInlineTextFileCount: Int = 0,
        priorTurnInlineTextFileCount: Int = 0
    ) -> GatewayAttemptDraft {
        GatewayAttemptDraft(
            attemptID: attemptID,
            conversationID: conversationID,
            userMessageID: userMessageID,
            gatewayRef: gatewayRef,
            origin: origin,
            inputMode: inputMode,
            requestedModel: requestedModel,
            deviceClass: deviceClass,
            currentTurnInlineImageCount: currentTurnInlineImageCount,
            priorTurnInlineImageCount: priorTurnInlineImageCount,
            currentTurnInlineTextFileCount: currentTurnInlineTextFileCount,
            priorTurnInlineTextFileCount: priorTurnInlineTextFileCount
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

    // Three awaited helpers, because XCTest's assertion autoclosures are not
    // async — every store read has to be hoisted out of the assertion anyway,
    // and these keep that from crowding out what each test is actually saying.

    @discardableResult
    private func openAttempt(
        _ store: ConversationStore,
        _ draft: GatewayAttemptDraft,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws -> GatewayAttemptContext {
        let context = await store.beginGatewayAttempt(draft: draft)
        return try XCTUnwrap(context, "A begin against a loaded store must insert.",
                             file: file, line: line)
    }

    private func onlyAttempt(
        in store: ConversationStore,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws -> GatewayAttemptRecord {
        let rows = try await store.fetchGatewayAttempts()
        return try XCTUnwrap(rows.first, "Expected a stored attempt.", file: file, line: line)
    }

    private func attemptCount(in store: ConversationStore) async throws -> Int {
        try await store.fetchGatewayAttempts().count
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

    func testBeginPersistsTheDeviceClassAndTheAttachmentShapeItWasHanded() async throws {
        let store = makeStore()
        let seed = try await seedTurn(in: store)
        let draft = makeDraft(
            conversationID: seed.conversationID,
            userMessageID: seed.userMessageID,
            deviceClass: "ipad",
            currentTurnInlineImageCount: 2,
            priorTurnInlineImageCount: 5,
            currentTurnInlineTextFileCount: 1,
            priorTurnInlineTextFileCount: 3
        )

        _ = await store.beginGatewayAttempt(draft: draft)

        let row = try await onlyAttempt(in: store)
        XCTAssertEqual(row.originDeviceClass, "ipad",
                       "The device that executed THIS dispatch, not the turn's origin surface.")
        XCTAssertEqual(row.currentTurnInlineImageCount, 2)
        XCTAssertEqual(row.priorTurnInlineImageCount, 5)
        XCTAssertEqual(row.currentTurnInlineTextFileCount, 1)
        XCTAssertEqual(row.priorTurnInlineTextFileCount, 3)
    }

    func testBeginWritesExplicitZeroesForATurnThatCarriedNoAttachments() async throws {
        let store = makeStore()
        let seed = try await seedTurn(in: store)
        let draft = makeDraft(conversationID: seed.conversationID, userMessageID: seed.userMessageID)

        _ = await store.beginGatewayAttempt(draft: draft)

        let row = try await onlyAttempt(in: store)
        // Nil means "this build did not measure" and is a claim only a row
        // written before the columns existed may make. A plain text turn has to
        // say zero, or every coverage denominator silently shrinks.
        XCTAssertEqual(row.currentTurnInlineImageCount, 0)
        XCTAssertEqual(row.priorTurnInlineImageCount, 0)
        XCTAssertEqual(row.currentTurnInlineTextFileCount, 0)
        XCTAssertEqual(row.priorTurnInlineTextFileCount, 0)
    }

    func testFetchEnrichesEachRowWithItsUserTurnsSourceDevice() async throws {
        let store = makeStore()
        let seed = try await seedTurn(in: store)
        // No `deviceClass` of its own — exactly the legacy row whose bucket can
        // only come from the turn it belongs to.
        _ = await store.beginGatewayAttempt(
            draft: makeDraft(
                conversationID: seed.conversationID,
                userMessageID: seed.userMessageID,
                deviceClass: nil
            )
        )

        let row = try await onlyAttempt(in: store)
        XCTAssertNil(row.originDeviceClass)
        XCTAssertEqual(row.fallbackSourceDevice, "iphone-text",
                       "The enrichment is read off the linked turn at fetch time, never stored.")
    }

    func testFetchLeavesFallbackSourceDeviceEmptyWithNoLinkedTurn() async throws {
        let store = makeStore()
        let convo = try await store.createConversation(backend: "openclaw")
        _ = await store.beginGatewayAttempt(
            draft: makeDraft(conversationID: convo.id, userMessageID: UUID(), deviceClass: nil)
        )

        let row = try await onlyAttempt(in: store)
        XCTAssertNil(row.fallbackSourceDevice,
                     "Nothing is invented for a row whose turn never resolved.")
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

    // MARK: - Retention: usage outlives the history it measures

    func testDeletingAConversationLeavesItsAttemptsStandingAndCountable() async throws {
        let store = makeStore()
        let seed = try await seedTurn(in: store)
        let draft = makeDraft(conversationID: seed.conversationID, userMessageID: seed.userMessageID)
        _ = await store.beginGatewayAttempt(draft: draft)

        try await store.deleteConversation(id: seed.conversationID)

        let stored = try await store.fetchGatewayAttempts()
        XCTAssertEqual(stored.count, 1,
                       "Deleting a thread deletes its content, never the measurement of it.")
        let row = try XCTUnwrap(stored.first)
        XCTAssertEqual(row.id, draft.attemptID)
        XCTAssertEqual(row.conversationID, seed.conversationID,
                       "The scalar snapshot survives the parent it names.")
        XCTAssertEqual(row.gatewayRef, "openclaw")
        XCTAssertNil(row.fallbackSourceDevice,
                     "The linked turn went with the conversation — the relationship nullifies.")
    }

    func testDeletingAConversationLeavesRelationshipLessAttemptsStanding() async throws {
        let store = makeStore()
        let convo = try await store.createConversation(backend: "openclaw")
        // No user `Message`, so no relationship at all — the row is carried
        // entirely by its scalars.
        let draft = makeDraft(conversationID: convo.id, userMessageID: UUID())
        _ = await store.beginGatewayAttempt(draft: draft)

        try await store.deleteConversation(id: convo.id)

        let stored = try await store.fetchGatewayAttempts()
        XCTAssertEqual(stored.map(\.id), [draft.attemptID])
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

        // Erase-everything is the one deletion that takes the ledger with it,
        // and it goes through the same batched purge as a user-driven clear.
        try await store.deleteAll()

        let stored = try await store.fetchGatewayAttempts()
        XCTAssertTrue(stored.isEmpty)
    }

    // MARK: - Rows with no attribution at all

    func testAnAttemptWhoseConversationIsAbsentIsStillCounted() async throws {
        let store = makeStore()
        _ = try await seedTurn(in: store)
        // A row that arrived ahead of the conversation it names — deleted,
        // not yet imported, or temporarily unavailable are indistinguishable
        // from here, and none of them stops it counting as a dispatch.
        let futureConversationID = UUID()
        let draft = makeDraft(conversationID: futureConversationID, userMessageID: UUID())
        _ = await store.beginGatewayAttempt(draft: draft)

        let stored = try await store.fetchGatewayAttempts()
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(stored.first?.id, draft.attemptID)

        // The parent finally imports. Nothing about the row changes.
        _ = try await store.createConversation(id: futureConversationID, backend: "openclaw")
        let afterImport = try await attemptCount(in: store)
        XCTAssertEqual(afterImport, 1)
    }

    func testLiveConversationIDsReportsOnlyResolvableParents() async throws {
        let store = makeStore()
        let seed = try await seedTurn(in: store)
        // Two rows: one whose parent resolves right now, one whose parent never
        // will. Both must survive the delete below — the second assertion is
        // only worth making if a resolvable row was there to be swept.
        _ = try await openAttempt(store, makeDraft(
            conversationID: seed.conversationID, userMessageID: seed.userMessageID
        ))
        _ = await store.beginGatewayAttempt(
            draft: makeDraft(conversationID: UUID(), userMessageID: UUID())
        )

        let live = await store.liveConversationIDs()
        XCTAssertEqual(live, [seed.conversationID],
                       "Navigation is what this gates — never a count, and never a deletion.")

        try await store.deleteConversation(id: seed.conversationID)
        let afterDelete = await store.liveConversationIDs()
        XCTAssertTrue(afterDelete.isEmpty)
        let stillCounted = try await attemptCount(in: store)
        XCTAssertEqual(stillCounted, 2,
                       "Both rows still count — only the chevron goes away.")
    }

    // MARK: - The clear cutoff

    func testAClearCutoffExcludesRowsAtOrBeforeItFromBothReads() async throws {
        let store = makeStore()
        let seed = try await seedTurn(in: store)
        let old = try await openAttempt(store, makeDraft(
            conversationID: seed.conversationID, userMessageID: seed.userMessageID))
        let recent = try await openAttempt(store, makeDraft(
            conversationID: seed.conversationID, userMessageID: seed.userMessageID))
        // The cutoff lands ON the older row's instant — "cleared through" is
        // inclusive, or a clear tapped at the same millisecond as a dispatch
        // would leave that dispatch behind.
        let cutoff = old.startedAt

        let visible = try await store.fetchGatewayAttempts(clearedThrough: cutoff)
        XCTAssertEqual(visible.map(\.id), [recent.attemptID])
        let earliest = try await store.earliestGatewayAttemptStart(clearedThrough: cutoff)
        XCTAssertEqual(earliest, recent.startedAt,
                       "'Measuring since' has to move past a cleared period, not describe it.")
        let unfiltered = try await attemptCount(in: store)
        XCTAssertEqual(unfiltered, 2,
                       "Exclusion is the caller's cutoff, not a state of the store.")
    }

    func testAnUndatedRowIsExcludedByAnyCutoff() async throws {
        let store = makeStore()
        let seed = try await seedTurn(in: store)
        let draft = makeDraft(conversationID: seed.conversationID, userMessageID: seed.userMessageID)
        _ = await store.beginGatewayAttempt(draft: draft)
        try await store.debugClearGatewayAttemptStart(attemptID: draft.attemptID)

        let uncleared = try await attemptCount(in: store)
        XCTAssertEqual(uncleared, 1,
                       "With no cutoff an undated row is inside the unbounded range.")
        let visible = try await store.fetchGatewayAttempts(clearedThrough: Date())
        XCTAssertTrue(visible.isEmpty,
                      "'Clear everything up to now' cannot spare the rows that cannot say when.")
    }

    // MARK: - Purge

    func testPurgeWalksManyBatchesAndDeletesEveryRowThroughTheCutoff() async throws {
        let store = makeStore()
        let convo = try await store.createConversation(backend: "openclaw")
        // Three passes of the 500-row batch bound, so a loop that stopped after
        // one fetch — or that walked with an OFFSET and skipped what it had just
        // deleted — leaves rows behind and fails here.
        let rowCount = ConversationStore.gatewayAttemptPurgeBatchSize * 2 + 1
        for _ in 0..<rowCount {
            _ = await store.beginGatewayAttempt(
                draft: makeDraft(conversationID: convo.id, userMessageID: UUID())
            )
        }
        let seeded = try await attemptCount(in: store)
        XCTAssertEqual(seeded, rowCount)

        let deleted = try await store.purgeGatewayAttempts(through: Date())
        XCTAssertEqual(deleted, rowCount)
        let remaining = try await attemptCount(in: store)
        XCTAssertEqual(remaining, 0)
    }

    func testPurgeIsIdempotentAndSparesRowsAfterTheCutoff() async throws {
        let store = makeStore()
        let seed = try await seedTurn(in: store)
        let old = try await openAttempt(store, makeDraft(
            conversationID: seed.conversationID, userMessageID: seed.userMessageID))
        let kept = try await openAttempt(store, makeDraft(
            conversationID: seed.conversationID, userMessageID: seed.userMessageID))

        let first = try await store.purgeGatewayAttempts(through: old.startedAt)
        XCTAssertEqual(first, 1)
        // Re-running after an interruption must complete the job, not repeat it
        // or fail on rows that are already gone.
        let second = try await store.purgeGatewayAttempts(through: old.startedAt)
        XCTAssertEqual(second, 0)

        let remaining = try await store.fetchGatewayAttempts()
        XCTAssertEqual(remaining.map(\.id), [kept.attemptID])
    }

    // MARK: - The late reply to a turn that is gone
    //
    // Retention decoupling makes this case visible for the first time: the
    // attempt row now outlives the conversation, so a landing REFUSED because
    // its turn was deleted mid-flight used to leave a row reading open forever,
    // and the dashboard would hedge it as unconfirmed for a dispatch whose
    // ending the transport actually watched. The verdict still stands — no
    // reply, no notification, no speech — and the outcome is written anyway.

    func testALandingRefusedForAMissingUserTurnStillClosesItsAttempt() async throws {
        let store = makeStore()
        let seed = try await seedTurn(in: store)
        let draft = makeDraft(conversationID: seed.conversationID, userMessageID: seed.userMessageID)
        _ = await store.beginGatewayAttempt(draft: draft)

        let completedAt = Date()
        do {
            _ = try await store.completeAgentTurn(
                userMessageID: UUID(),   // deleted mid-flight
                userStatus: "sent",
                agentText: "Run certbot renew.",
                conversationID: seed.conversationID,
                sourceDevice: "iphone-text",
                attempt: TerminalAttemptObservation(
                    attemptID: draft.attemptID,
                    completedAt: completedAt,
                    outcome: .succeeded,
                    metadata: makeMetadata()
                )
            )
            XCTFail("The verdict must still be thrown — nothing may land under a deleted turn.")
        } catch ConversationStore.StoreError.userMessageNotFound {
            // expected
        }

        let messages = try await store.fetchMessages(for: seed.conversationID)
        XCTAssertEqual(messages.count, 1, "The reply content is discarded, not parked somewhere.")
        let row = try await onlyAttempt(in: store)
        XCTAssertEqual(row.outcome, .succeeded,
                       "The transport watched this dispatch end; the row has to say so.")
        XCTAssertEqual(row.completedAt, completedAt)
    }

    func testALandingRefusedForAMissingConversationStillClosesItsAttempt() async throws {
        let store = makeStore()
        let seed = try await seedTurn(in: store)
        let draft = makeDraft(conversationID: seed.conversationID, userMessageID: seed.userMessageID)
        _ = await store.beginGatewayAttempt(draft: draft)
        // The whole thread goes while the request is in the air. The attempt
        // row survives it — that is exactly what makes this case reachable.
        try await store.deleteConversation(id: seed.conversationID)

        let completedAt = Date()
        do {
            _ = try await store.completeAgentTurn(
                userMessageID: seed.userMessageID,
                userStatus: "sent",
                agentText: "Run certbot renew.",
                conversationID: seed.conversationID,
                sourceDevice: "iphone-text",
                attempt: TerminalAttemptObservation(
                    attemptID: draft.attemptID,
                    completedAt: completedAt,
                    outcome: .failed,
                    appErrorCode: 17
                )
            )
            XCTFail("A landing for a conversation that is gone must not recreate anything.")
        } catch ConversationStore.StoreError.conversationNotFound {
            // expected
        }

        let row = try await onlyAttempt(in: store)
        XCTAssertEqual(row.outcome, .failed)
        XCTAssertEqual(row.appErrorCode, 17)
        XCTAssertEqual(row.completedAt, completedAt)
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

    func testEarliestStartReportsTheOldestRetainedAttempt() async throws {
        let store = makeStore()
        let empty = try await store.earliestGatewayAttemptStart()
        XCTAssertNil(empty, "An empty store has not started measuring anything.")

        // An unattributable row older than everything else. It IS the date
        // measurement began — the dashboard measures dispatches, and this one
        // happened whether or not its thread is still here.
        let unattributed = try await openAttempt(
            store, makeDraft(conversationID: UUID(), userMessageID: UUID()))
        let seed = try await seedTurn(in: store)
        _ = await store.beginGatewayAttempt(
            draft: makeDraft(conversationID: seed.conversationID, userMessageID: seed.userMessageID)
        )

        let earliest = try await store.earliestGatewayAttemptStart()
        XCTAssertEqual(earliest, unattributed.startedAt)
    }
}

// MARK: - The synced clear cutoff
//
// What makes "Clear usage history" account-wide with no sixth CloudKit field:
// the cutoff travels through the settings channel, and every device excludes
// rows at or before it on sight. The rule the whole scheme rests on is that it
// only ever ADVANCES — a stale value arriving late, or a second device clearing
// a moment earlier, must never un-clear history the user already cleared.
final class GatewayUsageClearCutoffTests: XCTestCase {

    private func makeManager(
        defaults: InMemoryDefaultsStore = InMemoryDefaultsStore(),
        kvs: InMemoryUbiquitousStore = InMemoryUbiquitousStore()
    ) -> SettingsManager {
        SettingsManager(dependencies: .inMemory(
            defaults: defaults, ubiquitous: kvs, cloudAvailable: true
        ))
    }

    func testTheCutoffIsAbsentUntilSomethingIsCleared() async {
        let manager = makeManager()
        let stored = await manager.gatewayUsageClearedThrough()
        XCTAssertNil(stored, "An untouched install has cleared nothing — not 'cleared at 2001'.")
    }

    func testAdvancingWritesBothStoresAndReportsWhereItStands() async {
        let defaults = InMemoryDefaultsStore()
        let kvs = InMemoryUbiquitousStore()
        let manager = makeManager(defaults: defaults, kvs: kvs)
        let cleared = Date(timeIntervalSince1970: 1_800_000_000)

        let settled = await manager.advanceGatewayUsageClearedThrough(cleared)

        let readBack = await manager.gatewayUsageClearedThrough()
        XCTAssertEqual(settled, cleared)
        XCTAssertEqual(readBack, cleared)
        XCTAssertNotNil(kvs.object(forKey: "gatewayUsageClearedThrough"),
                        "The cutoff is what syncs — a local-only write clears one device.")
        XCTAssertNotNil(defaults.object(forKey: "gatewayUsageClearedThrough"),
                        "And the local mirror is what makes the exclusion survive a relaunch.")
    }

    func testTheCutoffNeverRegresses() async {
        let manager = makeManager()
        let later = Date(timeIntervalSince1970: 1_800_000_000)
        let earlier = later.addingTimeInterval(-3_600)

        _ = await manager.advanceGatewayUsageClearedThrough(later)
        let settled = await manager.advanceGatewayUsageClearedThrough(earlier)

        let readBack = await manager.gatewayUsageClearedThrough()
        XCTAssertEqual(settled, later, "An earlier cutoff would un-clear a cleared period.")
        XCTAssertEqual(readBack, later)
    }

    func testAPeersLaterCutoffWinsAndAnEarlierOneIsIgnored() async {
        let defaults = InMemoryDefaultsStore()
        let kvs = InMemoryUbiquitousStore()
        let manager = makeManager(defaults: defaults, kvs: kvs)
        let local = Date(timeIntervalSince1970: 1_800_000_000)
        _ = await manager.advanceGatewayUsageClearedThrough(local)

        let stale = local.addingTimeInterval(-600)
        kvs.set(stale.timeIntervalSinceReferenceDate, forKey: "gatewayUsageClearedThrough")
        let afterStale = await manager.gatewayUsageClearedThrough()
        XCTAssertEqual(afterStale, local,
                       "Max merge, in both directions — the transport orders nothing.")

        let peer = local.addingTimeInterval(600)
        kvs.set(peer.timeIntervalSinceReferenceDate, forKey: "gatewayUsageClearedThrough")
        let afterPeer = await manager.gatewayUsageClearedThrough()
        XCTAssertEqual(afterPeer, peer,
                       "A peer's clear has to take effect here without waiting for a purge.")
    }
}
