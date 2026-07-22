// Conduck
// ConversationStoreLoadAndDebounceTests.swift
//
// The `ConversationStore` load/refresh responsiveness contract:
//   1. Sticky load failure — an unloadable store URL throws on the FIRST
//      touch and rethrows the same failure on every later touch (no hang,
//      no silent retry-thrash).
//   2. Single-flight first touch — N concurrent first reads share ONE load
//      task and all succeed (no deadlock, no double-load).
//   3. Read-after-write visibility — reads run on fresh background contexts
//      that register nothing, so a just-saved write is visible to the very
//      next fetch with no merge-timing dependency.
//   4. `RemoteChangeDebouncer` — trailing coalescing, the max-latency cap
//      under a continuous storm (incl. its synchronous enforcement at
//      schedule time), the never-dropped trailing edge, and main-actor
//      fire delivery.
//
// Each store test constructs its OWN isolated `inMemory` / temp-URL store
// (never `.shared`) — full per-test isolation, no wipe coordination.

import XCTest
import CoreData
@testable import Conduck

final class ConversationStoreLoadAndDebounceTests: XCTestCase {

    // MARK: - 1. Sticky load failure

    func testLoadFailureThrowsOnFirstAndEverySubsequentTouch() async {
        // A store URL whose parent directory does not exist — the store add
        // fails. The failed single-flight task is sticky: every touch rethrows,
        // and none of them hang.
        let bogus = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)/sub/store.sqlite")
        let store = ConversationStore(storeURL: bogus)

        do {
            _ = try await store.fetchConversations()
            XCTFail("First touch on an unloadable store must throw.")
        } catch {
            // Expected — the load failure surfaces to the first caller.
        }

        do {
            _ = try await store.fetchConversations()
            XCTFail("Second touch must rethrow the sticky load failure, not succeed or hang.")
        } catch {
            // Expected — same failed load task, same error, no retry-thrash.
        }
    }

    // MARK: - 2. Single-flight concurrent first touch

    func testConcurrentFirstTouchesShareOneLoadAndAllSucceed() async throws {
        let store = ConversationStore(inMemory: true)

        // 5 concurrent first reads: all of them race the initial load. The
        // single-flight task means they all await the SAME load and return —
        // a regression (e.g. a blocking gate) deadlocks or double-loads here.
        try await withThrowingTaskGroup(of: Int.self) { group in
            for _ in 0..<5 {
                group.addTask {
                    try await store.fetchConversations().count
                }
            }
            for try await count in group {
                XCTAssertEqual(count, 0, "A fresh in-memory store has no conversations.")
            }
        }
    }

    // MARK: - 3. Read-after-write visibility (fresh-background-context reads)

    func testWritesAreVisibleToTheImmediatelyFollowingRead() async throws {
        let store = ConversationStore(inMemory: true)

        let convo = try await store.createConversation(backend: "openclaw")
        let message = try await store.appendMessage(
            role: "user",
            text: "Hello agent",
            conversationID: convo.id,
            sourceDevice: "iphone"
        )

        // Reads materialize straight from the store's committed values — the
        // just-saved rows must be there with NO settling delay.
        let conversations = try await store.fetchConversations()
        XCTAssertEqual(conversations.map(\.id), [convo.id],
                       "createConversation must be visible to the immediately following fetch.")

        let messages = try await store.fetchMessages(for: convo.id)
        XCTAssertEqual(messages.map(\.id), [message.id],
                       "appendMessage must be visible to the immediately following fetch.")
        XCTAssertEqual(messages.first?.text, "Hello agent")
    }

    // MARK: - 4. RemoteChangeDebouncer

    @MainActor
    func testBurstOfSchedulesYieldsExactlyOneTrailingFire() async throws {
        var fires = 0
        var allOnMainThread = true
        let debouncer = RemoteChangeDebouncer(
            interval: .milliseconds(30),
            maxLatency: .milliseconds(90)
        ) {
            fires += 1
            allOnMainThread = allOnMainThread && Thread.isMainThread
        }

        // A synchronous burst — every schedule supersedes the previous timer,
        // so only the trailing edge fires.
        for _ in 0..<10 {
            debouncer.schedule()
        }

        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(fires, 1, "A burst must coalesce to exactly one trailing fire.")
        XCTAssertTrue(allOnMainThread, "Fires must land on the main actor/thread.")
    }

    @MainActor
    func testContinuousStormIsCappedByMaxLatency() async throws {
        var fires = 0
        let debouncer = RemoteChangeDebouncer(
            interval: .milliseconds(90),
            maxLatency: .milliseconds(150)
        ) {
            fires += 1
        }

        // Re-schedule faster than the 90 ms trailing interval for ~400 ms.
        // Pure trailing debounce would stay silent the whole time; the
        // max-latency cap must force at least one fire mid-storm.
        for _ in 0..<20 {
            debouncer.schedule()
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertGreaterThanOrEqual(
            fires, 1,
            "The max-latency cap must force a fire during a continuous storm."
        )

        // Let the storm's own trailing edge drain. Over ~400 ms of continuous
        // scheduling with a 150 ms cap, cap fires plus the final trailing fire
        // total at least two — a single fire would mean the cap collapsed to a
        // one-shot. (Exact counts are timing-dependent on a busy CI sim, so
        // the bound is deliberately loose; the never-dropped trailing edge is
        // pinned precisely by `testFinalScheduleAfterQuietAlwaysFires`.)
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertGreaterThanOrEqual(
            fires, 2,
            "A continuous storm must keep surfacing (cap fires + final trailing fire)."
        )
    }

    @MainActor
    func testCapFiresSynchronouslyAtScheduleTime() {
        var fires = 0
        let debouncer = RemoteChangeDebouncer(
            interval: .milliseconds(200),
            maxLatency: .milliseconds(50)
        ) {
            fires += 1
        }

        debouncer.schedule()
        // Busy-wait past the 50 ms cap WITHOUT suspending: the main actor
        // never yields, so the pending trailing task cannot run — this IS the
        // main-queue delivery-backlog scenario the synchronous cap exists for
        // (a scheduled fire task that never wins executor time).
        let start = ContinuousClock.now
        while start.duration(to: ContinuousClock.now) < .milliseconds(60) {}
        XCTAssertEqual(fires, 0, "The main actor never yielded — no task-based fire can have run.")

        // The window is past `maxLatency`: this schedule must fire INLINE on
        // this same actor turn (no sleep, no task hop before the assert).
        debouncer.schedule()
        XCTAssertEqual(fires, 1, "The max-latency cap must fire synchronously at schedule time.")
    }

    @MainActor
    func testFinalScheduleAfterQuietAlwaysFires() async throws {
        var fires = 0
        let debouncer = RemoteChangeDebouncer(
            interval: .milliseconds(30),
            maxLatency: .milliseconds(90)
        ) {
            fires += 1
        }

        debouncer.schedule()
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(fires, 1, "A lone schedule fires once after the trailing interval.")

        // A fresh window after quiet — the trailing edge fires again, exactly
        // once (the window state fully resets between bursts).
        debouncer.schedule()
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(fires, 2, "A schedule after quiet must always fire — the trailing edge is never dropped.")
    }
}
