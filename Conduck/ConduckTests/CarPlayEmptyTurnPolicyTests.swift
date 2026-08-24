// SPDX-License-Identifier: Apache-2.0

// Conduck
// CarPlayEmptyTurnPolicyTests.swift
//
// Locks the retry-once rule for a CarPlay turn that came back with nothing in
// it — an empty transcript, or the speech provider's own "no speech detected".
//
// The rule is two-sided and both sides are load-bearing:
//
//   • ONE empty turn must NOT end the session. A throat clear, a passing truck,
//     a provider that trimmed a short answer to nothing — each of those used to
//     drop the driver straight back to the picker mid-conversation.
//   • TWO IN A ROW must end it. A cabin producing nothing but noise would
//     otherwise hold the audio route — and the car's radio — for another full
//     listening window on every attempt, for as long as the drive lasts.
//
// The counter is CONSECUTIVE, not cumulative: a session where every other turn
// works is a working session, and it must never accumulate its way into a
// sign-off. That reset is the service's job, so the sequence tests here model it
// the way the service does.

import XCTest
@testable import Conduck

final class CarPlayEmptyTurnPolicyTests: XCTestCase {

    // MARK: - The rule

    func testFirstEmptyTurnRetries() {
        XCTAssertEqual(CarPlayEmptyTurnPolicy.outcome(after: 0), .retryListening)
    }

    func testSecondConsecutiveEmptyTurnEndsTheSession() {
        XCTAssertEqual(CarPlayEmptyTurnPolicy.outcome(after: 1), .endSession)
    }

    func testTheBudgetIsTwo() {
        XCTAssertEqual(CarPlayEmptyTurnPolicy.maxConsecutiveEmptyTurns, 2)
    }

    func testCountAdvancesByOnePerEmptyTurn() {
        XCTAssertEqual(CarPlayEmptyTurnPolicy.nextCount(after: 0), 1)
        XCTAssertEqual(CarPlayEmptyTurnPolicy.nextCount(after: 1), 2)
    }

    // MARK: - Defensive edges

    func testACountAlreadyPastTheBudgetStillEnds() {
        // Unreachable through the service, which ends at two — but if a future
        // path ever lets the count run on, it must not wrap back into retrying.
        for prior in 2...10 {
            XCTAssertEqual(CarPlayEmptyTurnPolicy.outcome(after: prior), .endSession)
        }
    }

    func testANegativeCountIsClampedAndRetries() {
        XCTAssertEqual(CarPlayEmptyTurnPolicy.nextCount(after: -5), 1)
        XCTAssertEqual(CarPlayEmptyTurnPolicy.outcome(after: -5), .retryListening)
    }

    // MARK: - Sequences, as the session runs them

    /// Replays a session's turns through the policy exactly as the service does:
    /// `true` is an empty turn, `false` a good one, which resets the run.
    /// Returns the outcome of every empty turn, in order.
    private func replay(_ turns: [Bool]) -> [CarPlayEmptyTurnPolicy.Outcome] {
        var consecutiveEmptyTurns = 0
        var outcomes: [CarPlayEmptyTurnPolicy.Outcome] = []
        for isEmpty in turns {
            guard isEmpty else {
                consecutiveEmptyTurns = 0
                continue
            }
            outcomes.append(CarPlayEmptyTurnPolicy.outcome(after: consecutiveEmptyTurns))
            consecutiveEmptyTurns = CarPlayEmptyTurnPolicy.nextCount(after: consecutiveEmptyTurns)
        }
        return outcomes
    }

    func testEmptyThenEmptyRetriesOnceThenSignsOff() {
        XCTAssertEqual(replay([true, true]), [.retryListening, .endSession])
    }

    func testAGoodTurnBetweenTwoEmptiesResetsTheBudget() {
        // The failure this prevents: a twenty-minute conversation with one bad
        // turn early on ending abruptly on an unrelated bad turn later.
        XCTAssertEqual(
            replay([true, false, true]),
            [.retryListening, .retryListening]
        )
    }

    func testAGoodTurnAfterARetryRestoresTheFullBudget() {
        XCTAssertEqual(
            replay([true, false, true, true]),
            [.retryListening, .retryListening, .endSession]
        )
    }

    func testASessionThatStartsFreshRetriesAgain() {
        // A new session resets the count to zero, so the first empty turn of the
        // next drive is a retry no matter how the last one ended.
        XCTAssertEqual(replay([true, true]), [.retryListening, .endSession])
        XCTAssertEqual(replay([true]), [.retryListening])
    }

    func testAlternatingEmptiesNeverEndTheSession() {
        let outcomes = replay([true, false, true, false, true, false, true])
        XCTAssertEqual(outcomes.count, 4)
        XCTAssertTrue(outcomes.allSatisfy { $0 == .retryListening })
    }

    func testTheWorstCaseIsBoundedAtTwoListens() {
        // Sustained cabin noise: capture caps out, comes back empty, retries
        // once, comes back empty, signs off. No third window.
        let outcomes = replay(Array(repeating: true, count: 6))
        XCTAssertEqual(Array(outcomes.prefix(2)), [.retryListening, .endSession])
    }
}
