// Conduck
// MascotShuffleBagTests.swift
//
// Deterministic unit tests over `MascotShuffleBag` — the device-local
// shuffle-bag empty-state mascot picker. Uses an isolated `UserDefaults`
// suite via the `next(pool:defaults:)` test seam (removed in tearDown). No
// SwiftUI, no asset-catalog dependency — pure-data over a small fixed pool.

import XCTest
@testable import Conduck

final class MascotShuffleBagTests: XCTestCase {

    private let pool = ["a", "b", "c", "d"]
    private let suiteName = "MascotShuffleBagTests"
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        // Fresh, isolated suite per test (the previous test's tearDown removed it).
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    // MARK: - Full coverage before repeat

    func testFullCoverageBeforeRepeat() {
        var drawn: [String] = []
        for _ in 0..<pool.count {
            drawn.append(MascotShuffleBag.next(pool: pool, defaults: defaults))
        }

        XCTAssertEqual(Set(drawn), Set(pool),
                       "Drawing pool.count times must yield every pose exactly once.")
        XCTAssertEqual(drawn.count, Set(drawn).count,
                       "No pose may repeat within a single cycle.")
    }

    // MARK: - Reshuffle after exhaustion

    func testReshuffleAfterExhaustionCoversFullPoolAgain() {
        var firstCycle: [String] = []
        for _ in 0..<pool.count {
            firstCycle.append(MascotShuffleBag.next(pool: pool, defaults: defaults))
        }
        var secondCycle: [String] = []
        for _ in 0..<pool.count {
            secondCycle.append(MascotShuffleBag.next(pool: pool, defaults: defaults))
        }

        XCTAssertEqual(Set(firstCycle), Set(pool), "First cycle must cover the full pool.")
        XCTAssertEqual(Set(secondCycle), Set(pool),
                       "Second cycle (after exhaustion + reshuffle) must also cover the full pool.")
        XCTAssertEqual(secondCycle.count, Set(secondCycle).count,
                       "No pose may repeat within the second cycle either.")
    }

    // MARK: - No reshuffle-boundary repeat

    func testNoReshuffleBoundaryRepeat() {
        // Draw the whole deck, then one more (which forces a reshuffle). The last
        // pose of cycle 1 and the first pose of cycle 2 must differ.
        var drawn: [String] = []
        for _ in 0..<pool.count {
            drawn.append(MascotShuffleBag.next(pool: pool, defaults: defaults))
        }
        let acrossBoundary = MascotShuffleBag.next(pool: pool, defaults: defaults)

        XCTAssertNotEqual(drawn.last, acrossBoundary,
                          "The pose across the reshuffle boundary must not repeat the previous one.")
    }

    // MARK: - Stale-name pruning

    func testStaleNamesAreNeverReturned() {
        // Pre-seed the persisted deck with a name not in the current pool.
        defaults.set(["zzz-not-in-pool"] + pool, forKey: "mascot.emptyState.deck")

        // Draw more than enough to exhaust + reshuffle several times.
        for _ in 0..<(pool.count * 3) {
            let pose = MascotShuffleBag.next(pool: pool, defaults: defaults)
            XCTAssertTrue(pool.contains(pose),
                          "A stale deck entry not in the pool must never be returned (got \(pose)).")
        }
    }
}
