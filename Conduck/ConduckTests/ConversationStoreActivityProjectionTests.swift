// SPDX-License-Identifier: Apache-2.0

// Conduck
// ConversationStoreActivityProjectionTests.swift
//
// Locks the two store reads the conversation-list activity work added:
//   • `fetchUnresolvedUserTurns` / `fetchConversations(activity:)` — ONE
//     whole-store aggregate, reporting the newest `sending` and the newest
//     `failed` user turn SEPARATELY per conversation, so two overlapping turns
//     in one thread can never alias each other;
//   • `fetchConversationTail` — one row, totally ordered, no attachment faults.
//
// Each test builds its OWN isolated `inMemory` store (CloudKit OFF in the seam).
// Deterministic + headless; synthetic text only.

import XCTest
@testable import Conduck

final class ConversationStoreActivityProjectionTests: XCTestCase {

    private func makeStore() -> ConversationStore {
        ConversationStore(inMemory: true)
    }

    // MARK: - Projection opt-in

    func testDefaultProjectionLeavesBothDerivedFieldsNil() async throws {
        let store = makeStore()
        let convo = try await store.createConversation(backend: "openclaw")
        _ = try await store.appendMessage(
            role: "user", text: "hi", conversationID: convo.id,
            sourceDevice: "phone", status: "sending"
        )
        let plain = try await store.fetchConversations()
        XCTAssertEqual(plain.count, 1)
        XCTAssertNil(plain[0].newestSendingAt)
        XCTAssertNil(plain[0].newestFailedAt)
    }

    func testTurnStatesProjectionFillsTheSendingStamp() async throws {
        let store = makeStore()
        let convo = try await store.createConversation(backend: "openclaw")
        let turn = try await store.appendMessage(
            role: "user", text: "hi", conversationID: convo.id,
            sourceDevice: "phone", status: "sending"
        )
        let projected = try await store.fetchConversations(activity: .turnStates)
        XCTAssertEqual(projected[0].newestSendingAt, turn.createdAt)
        XCTAssertNil(projected[0].newestFailedAt)
    }

    // MARK: - Sibling safety

    func testAConversationHoldingBothReportsThemSeparately() async throws {
        let store = makeStore()
        let convo = try await store.createConversation(backend: "openclaw")
        let older = try await store.appendMessage(
            role: "user", text: "first", conversationID: convo.id,
            sourceDevice: "phone", status: "sending"
        )
        let newer = try await store.appendMessage(
            role: "user", text: "second", conversationID: convo.id,
            sourceDevice: "phone", status: "sending"
        )
        await store.failTurn(messageID: older.id, classification: nil)

        let turns = try await store.fetchUnresolvedUserTurns()
        let entry = try XCTUnwrap(turns[convo.id])
        XCTAssertEqual(entry.newestFailedAt, older.createdAt)
        XCTAssertEqual(entry.newestSendingAt, newer.createdAt)

        // And the derived state is WORKING, because the newest unresolved turn
        // wins — rendering the old failure red would be a lie.
        let record = try await store.fetchConversations(activity: .turnStates)[0]
        let state = ConversationActivityResolver.resolve(
            ConversationActivityInputs(record: record, tailRole: .user),
            locallyLiveSince: nil,
            lastViewedAt: nil,
            failureSeenAt: nil,
            now: newer.createdAt
        )
        guard case .working = state.activity else {
            return XCTFail("expected working, got \(state.activity)")
        }
    }

    func testTheNewestTurnOfEachStatusWins() async throws {
        let store = makeStore()
        let convo = try await store.createConversation(backend: "openclaw")
        let firstFailed = try await store.appendMessage(
            role: "user", text: "a", conversationID: convo.id,
            sourceDevice: "phone", status: "sending"
        )
        let secondFailed = try await store.appendMessage(
            role: "user", text: "b", conversationID: convo.id,
            sourceDevice: "phone", status: "sending"
        )
        await store.failTurn(messageID: firstFailed.id, classification: nil)
        await store.failTurn(messageID: secondFailed.id, classification: nil)

        let turns = try await store.fetchUnresolvedUserTurns()
        XCTAssertEqual(turns[convo.id]?.newestFailedAt, secondFailed.createdAt)
        XCTAssertNil(turns[convo.id]?.newestSendingAt)
    }

    // MARK: - What must NOT enter the aggregate

    func testAHeadlessNoteWithNoSendStateEntersNoAggregate() async throws {
        let store = makeStore()
        let convo = try await store.createConversation(backend: "openclaw")
        _ = try await store.appendMessage(
            role: "user", text: "wrist note", conversationID: convo.id,
            sourceDevice: "watch"          // status nil
        )
        let turns = try await store.fetchUnresolvedUserTurns()
        XCTAssertTrue(turns.isEmpty)

        let record = try await store.fetchConversations(activity: .turnStates)[0]
        XCTAssertNil(record.newestSendingAt)
        XCTAssertNil(record.newestFailedAt)
    }

    func testAResolvedTurnLeavesTheAggregate() async throws {
        let store = makeStore()
        let convo = try await store.createConversation(backend: "openclaw")
        let turn = try await store.appendMessage(
            role: "user", text: "hi", conversationID: convo.id,
            sourceDevice: "phone", status: "sending"
        )
        await store.markPendingUserTurn(messageID: turn.id, to: "sent")
        let turns = try await store.fetchUnresolvedUserTurns()
        XCTAssertTrue(turns.isEmpty)
    }

    func testAnAgentRowNeverEntersTheAggregate() async throws {
        let store = makeStore()
        let convo = try await store.createConversation(backend: "openclaw")
        _ = try await store.appendMessage(
            role: "agent", text: "reply", conversationID: convo.id,
            sourceDevice: "phone", status: "sending"   // nonsensical, but must be ignored
        )
        let turns = try await store.fetchUnresolvedUserTurns()
        XCTAssertTrue(turns.isEmpty)
    }

    func testTheAggregateKeepsConversationsApart() async throws {
        let store = makeStore()
        let working = try await store.createConversation(backend: "openclaw")
        let broken = try await store.createConversation(backend: "hermes")
        _ = try await store.appendMessage(
            role: "user", text: "a", conversationID: working.id,
            sourceDevice: "phone", status: "sending"
        )
        let doomed = try await store.appendMessage(
            role: "user", text: "b", conversationID: broken.id,
            sourceDevice: "phone", status: "sending"
        )
        await store.failTurn(messageID: doomed.id, classification: nil)

        let turns = try await store.fetchUnresolvedUserTurns()
        XCTAssertNotNil(turns[working.id]?.newestSendingAt)
        XCTAssertNil(turns[working.id]?.newestFailedAt)
        XCTAssertNil(turns[broken.id]?.newestSendingAt)
        XCTAssertNotNil(turns[broken.id]?.newestFailedAt)
    }

    // MARK: - Tail

    func testTailReturnsTheNewestRow() async throws {
        let store = makeStore()
        let convo = try await store.createConversation(backend: "openclaw")
        _ = try await store.appendMessage(
            role: "user", text: "question", conversationID: convo.id, sourceDevice: "phone"
        )
        let reply = try await store.appendMessage(
            role: "agent", text: "answer", conversationID: convo.id, sourceDevice: "phone"
        )
        let fetched = try await store.fetchConversationTail(id: convo.id)
        let tail = try XCTUnwrap(fetched)
        XCTAssertEqual(tail.text, "answer")
        XCTAssertEqual(tail.role, "agent")
        XCTAssertEqual(tail.createdAt, reply.createdAt)
        XCTAssertEqual(MessageRole(stored: tail.role), .agent)
    }

    func testTailIsStableAcrossRepeatedFetches() async throws {
        let store = makeStore()
        let convo = try await store.createConversation(backend: "openclaw")
        for index in 0..<8 {
            _ = try await store.appendMessage(
                role: index.isMultiple(of: 2) ? "user" : "agent",
                text: "turn \(index)",
                conversationID: convo.id,
                sourceDevice: "phone"
            )
        }
        let initial = try await store.fetchConversationTail(id: convo.id)
        let first = try XCTUnwrap(initial)
        for _ in 0..<5 {
            let repeated = try await store.fetchConversationTail(id: convo.id)
            XCTAssertEqual(try XCTUnwrap(repeated), first)
        }
    }

    func testTailIsNilForAnEmptyConversation() async throws {
        let store = makeStore()
        let convo = try await store.createConversation(backend: "openclaw")
        let tail = try await store.fetchConversationTail(id: convo.id)
        XCTAssertNil(tail)
    }

    func testTailCarriesTheSendStateOfAFailedUserTurn() async throws {
        let store = makeStore()
        let convo = try await store.createConversation(backend: "openclaw")
        let turn = try await store.appendMessage(
            role: "user", text: "hi", conversationID: convo.id,
            sourceDevice: "phone", status: "sending"
        )
        await store.failTurn(messageID: turn.id, classification: nil)
        let fetched = try await store.fetchConversationTail(id: convo.id)
        let tail = try XCTUnwrap(fetched)
        XCTAssertEqual(tail.status, "failed")
    }

    // MARK: - Picker projection

    #if os(iOS) || os(macOS)
    func testPickerRowsOptIntoTheSameAggregate() async throws {
        let store = makeStore()
        let convo = try await store.createConversation(backend: "openclaw")
        let turn = try await store.appendMessage(
            role: "user", text: "hi", conversationID: convo.id,
            sourceDevice: "phone", status: "sending"
        )
        let plain = try await store.fetchRecentForPicker(limit: 5)
        XCTAssertNil(plain.first?.newestSendingAt)

        let projected = try await store.fetchRecentForPicker(limit: 5, includeTurnStates: true)
        XCTAssertEqual(projected.first?.newestSendingAt, turn.createdAt)
        XCTAssertNil(projected.first?.newestFailedAt)
    }
    #endif

    // MARK: - Cost

    /// The guard rail for the whole design: the aggregate must be a CONSTANT
    /// number of queries regardless of conversation count. A per-conversation
    /// fan-out reintroduced by a future edit blows this budget by orders of
    /// magnitude rather than failing subtly.
    ///
    /// This one runs on `NSInMemoryStoreType`, which evaluates predicates by
    /// linear enumeration — so it catches a 1+N fan-out and says NOTHING about
    /// index behaviour. The SQLite twin below is what covers that.
    func testTurnStatesProjectionStaysWithinItsWallClockBudget() async throws {
        let store = makeStore()
        let ids = try await seedLargeStore(store, conversations: 200, messagesEach: 40)

        // Warm the store so the measurement is the fetch, not the first load.
        _ = try await store.fetchConversations()

        let start = Date()
        let projected = try await store.fetchConversations(activity: .turnStates)
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertEqual(projected.count, ids.count)
        XCTAssertTrue(
            projected.contains { $0.newestSendingAt != nil },
            "the seed leaves one unresolved turn per conversation"
        )
        XCTAssertLessThan(
            elapsed, 0.25,
            "fetchConversations(activity: .turnStates) must stay 2 queries, not 1 + N"
        )
    }

    /// The same budget against the store production actually uses. The model
    /// declares no `<fetchIndex>` (adding one needs a new model version, which is
    /// off-limits), so `role == "user" AND status IN {sending, failed}` is a
    /// SQLite table scan over every message this install has ever held — and it
    /// now runs on every list reload, on every surface. That risk was accepted
    /// with the wall-clock budget named as its guard; an in-memory store cannot
    /// be that guard, because it evaluates predicates by linear enumeration
    /// whatever the index state is.
    ///
    /// Deliberately smaller than the in-memory twin: the seed writes one SQLite
    /// transaction per message, so this measures the fetch on a realistic store
    /// without spending a minute filling it. The FETCH, not the seed, is timed.
    func testTurnStatesProjectionStaysWithinItsBudgetOnTheRealSQLiteStore() async throws {
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("activity-budget-\(UUID().uuidString).sqlite")
        defer {
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(
                    at: storeURL.deletingPathExtension()
                        .appendingPathExtension("sqlite\(suffix)")
                )
            }
        }
        let store = ConversationStore(inMemory: false, storeURL: storeURL)
        let ids = try await seedLargeStore(store, conversations: 60, messagesEach: 40)

        _ = try await store.fetchConversations()

        let start = Date()
        let projected = try await store.fetchConversations(activity: .turnStates)
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertEqual(projected.count, ids.count)
        XCTAssertTrue(projected.contains { $0.newestSendingAt != nil })
        XCTAssertLessThan(
            elapsed, 0.25,
            "the aggregate runs on every list reload — a scan this size must stay imperceptible"
        )
    }

    func testTailIsCheaperThanMaterializingTheWholeThread() async throws {
        let store = makeStore()
        let ids = try await seedLargeStore(store, conversations: 20, messagesEach: 40)
        let subject = try XCTUnwrap(ids.first)
        _ = try await store.fetchMessages(for: subject)

        // Averaged over several passes: two single-shot wall-clock readings on
        // a shared CI-ish machine are noise, and this assertion must fail for
        // the design reason, never for scheduling jitter.
        let passes = 10
        let messagesStart = Date()
        for _ in 0..<passes { _ = try await store.fetchMessages(for: subject) }
        let messagesElapsed = Date().timeIntervalSince(messagesStart) / Double(passes)

        let tailStart = Date()
        for _ in 0..<passes { _ = try await store.fetchConversationTail(id: subject) }
        let tailElapsed = Date().timeIntervalSince(tailStart) / Double(passes)

        XCTAssertLessThan(
            tailElapsed, messagesElapsed,
            "the tail read exists because it fetches ONE row instead of every message"
        )
    }

    /// Seed `conversations` threads of `messagesEach` turns, leaving exactly one
    /// unresolved `sending` user turn per thread so the aggregate has real work.
    private func seedLargeStore(
        _ store: ConversationStore,
        conversations: Int,
        messagesEach: Int
    ) async throws -> [UUID] {
        var ids: [UUID] = []
        for index in 0..<conversations {
            let convo = try await store.createConversation(
                backend: index.isMultiple(of: 2) ? "openclaw" : "hermes"
            )
            ids.append(convo.id)
            for turn in 0..<messagesEach {
                let isUser = turn.isMultiple(of: 2)
                _ = try await store.appendMessage(
                    role: isUser ? "user" : "agent",
                    text: "turn \(turn)",
                    conversationID: convo.id,
                    sourceDevice: "phone",
                    status: isUser ? "sent" : nil
                )
            }
            _ = try await store.appendMessage(
                role: "user",
                text: "in flight",
                conversationID: convo.id,
                sourceDevice: "phone",
                status: "sending"
            )
        }
        return ids
    }
}
