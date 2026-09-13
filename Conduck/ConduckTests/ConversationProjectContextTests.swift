// SPDX-License-Identifier: Apache-2.0

// Conduck
// ConversationProjectContextTests.swift
//
// The host-side standing of the open thread's Work project, and the races it
// exists to survive: a thread switch while the previous read is in flight, a
// cancelled read, a read that fails. The rule under test is that an answer
// is only ever published FOR the conversation it was read for, and that not
// knowing draws nothing and locks nothing — never "ordinary chat".

import XCTest
@testable import Conduck

@MainActor
final class ConversationProjectContextTests: XCTestCase {

    /// A fetch the test releases by hand, one gate per conversation.
    private actor Gate {
        private var continuations: [UUID: CheckedContinuation<ConversationStore.WorkProjectThreadMark, Error>] = [:]
        private var waiters: [UUID: [CheckedContinuation<Void, Never>]] = [:]

        func hold(_ id: UUID) async throws -> ConversationStore.WorkProjectThreadMark {
            try await withCheckedThrowingContinuation { continuation in
                continuations[id] = continuation
                for waiter in waiters.removeValue(forKey: id) ?? [] { waiter.resume() }
            }
        }

        /// Suspend until `hold(id)` has parked, so a release cannot race the arrival.
        func awaitParked(_ id: UUID) async {
            if continuations[id] != nil { return }
            await withCheckedContinuation { waiters[id, default: []].append($0) }
        }

        func release(_ id: UUID, with result: Result<ConversationStore.WorkProjectThreadMark, Error>) {
            continuations.removeValue(forKey: id)?.resume(with: result)
        }
    }

    private func mark(_ project: WorkProjectMark, refusal: WorkProjectAccessError? = nil) -> ConversationStore.WorkProjectThreadMark {
        .init(resolution: .live(project), refusal: refusal)
    }

    private let projectA = WorkProjectMark(id: UUID(), title: "A", color: .amber, isArchived: false)
    private let projectB = WorkProjectMark(id: UUID(), title: "B", color: .sage, isArchived: true)

    func testUnresolvedDrawsNothingAndLocksNothing() {
        let context = ConversationProjectContext(fetch: { _ in throw CancellationError() })
        let id = UUID()
        XCTAssertNil(context.liveProject(for: id))
        XCTAssertNil(context.refusal(for: id))
        XCTAssertTrue(context.allowsNewTurns(for: id), "an ordinary chat is never locked for the beat its read takes")
    }

    func testAnAnswerIsOnlyEverPublishedForTheConversationItWasReadFor() async throws {
        let gate = Gate()
        let context = ConversationProjectContext(fetch: { id in try await gate.hold(id) })
        let a = UUID(), b = UUID()

        let first = Task { await context.refresh(conversationID: a) }
        await gate.awaitParked(a)
        let second = Task { await context.refresh(conversationID: b) }
        await gate.awaitParked(b)
        // B's answer lands first; A's late answer must not replace it.
        await gate.release(b, with: .success(mark(projectB, refusal: .archived)))
        await second.value
        await gate.release(a, with: .success(mark(projectA)))
        await first.value

        XCTAssertEqual(context.liveProject(for: b), projectB)
        XCTAssertEqual(context.refusal(for: b), .archived)
        XCTAssertNil(context.liveProject(for: a), "A's out-of-order completion was discarded")
        XCTAssertTrue(context.allowsNewTurns(for: a))
    }

    func testASnapshotOfAnotherThreadNeverDressesTheCurrentOne() async {
        let context = ConversationProjectContext(fetch: { [projectA] _ in
            .init(resolution: .live(projectA), refusal: .archived)
        })
        let a = UUID()
        await context.refresh(conversationID: a)
        XCTAssertEqual(context.refusal(for: a), .archived)
        XCTAssertNil(context.refusal(for: UUID()), "asked for another thread, the answer is nothing")
        XCTAssertTrue(context.allowsNewTurns(for: UUID()))
    }

    func testACancelledReadPublishesNothing() async throws {
        let gate = Gate()
        let context = ConversationProjectContext(fetch: { id in try await gate.hold(id) })
        let a = UUID()
        let task = Task { await context.refresh(conversationID: a) }
        await gate.awaitParked(a)
        task.cancel()
        await gate.release(a, with: .success(mark(projectA, refusal: .archived)))
        await task.value
        XCTAssertNil(context.liveProject(for: a))
        XCTAssertTrue(context.allowsNewTurns(for: a))
    }

    func testAFailedReadKeepsTheLastSnapshotForTheSameThreadOnly() async {
        final class Switch: @unchecked Sendable { var fails = false }
        let flag = Switch()
        let context = ConversationProjectContext(fetch: { [projectA] _ in
            if flag.fails { throw CancellationError() }
            return .init(resolution: .live(projectA), refusal: .archived)
        })
        let a = UUID()
        await context.refresh(conversationID: a)
        flag.fails = true
        await context.refresh(conversationID: a)
        XCTAssertEqual(context.refusal(for: a), .archived, "a transient failure cannot unlock an archived thread")
        XCTAssertEqual(context.liveProject(for: a), projectA, "…nor strip a known header")

        let b = UUID()
        await context.refresh(conversationID: b)
        XCTAssertNil(context.liveProject(for: b), "A's snapshot does not stand in for B")
        XCTAssertNil(context.liveProject(for: a), "and it is not kept once the host has moved on")
    }

    func testNilSelectionResets() async {
        let context = ConversationProjectContext(fetch: { [projectA] _ in
            .init(resolution: .live(projectA), refusal: nil)
        })
        let a = UUID()
        await context.refresh(conversationID: a)
        XCTAssertEqual(context.liveProject(for: a), projectA)
        await context.refresh(conversationID: nil)
        XCTAssertEqual(context.state, .unresolved)
    }
}
