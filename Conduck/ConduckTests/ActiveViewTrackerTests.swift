// Conduck
// ActiveViewTrackerTests.swift
//
// Coverage for the shared @MainActor visibility registry. The tracker is a
// process-global static, so every test resets it via `_resetForTesting()` in
// setUp + tearDown to avoid order-dependent pollution.

import XCTest
@testable import Conduck

@MainActor
final class ActiveViewTrackerTests: XCTestCase {

    override func setUp() async throws {
        try await super.setUp()
        ActiveViewTracker._resetForTesting()
    }

    override func tearDown() async throws {
        ActiveViewTracker._resetForTesting()
        try await super.tearDown()
    }

    // MARK: - track / isViewing

    func testTrackAddsTheID() {
        let id = UUID()
        ActiveViewTracker.track(id)
        XCTAssertTrue(ActiveViewTracker.isViewing(id))
        XCTAssertTrue(ActiveViewTracker.viewedConversationIDs.contains(id))
    }

    func testIsViewingFalseBeforeTrack() {
        let id = UUID()
        XCTAssertFalse(ActiveViewTracker.isViewing(id))
    }

    // MARK: - untrack

    func testUntrackRemovesTheID() {
        let id = UUID()
        ActiveViewTracker.track(id)
        ActiveViewTracker.untrack(id)
        XCTAssertFalse(ActiveViewTracker.isViewing(id))
        XCTAssertFalse(ActiveViewTracker.viewedConversationIDs.contains(id))
    }

    // MARK: - Idempotence

    func testTrackIsIdempotent() {
        let id = UUID()
        ActiveViewTracker.track(id)
        ActiveViewTracker.track(id)
        ActiveViewTracker.track(id)
        XCTAssertEqual(ActiveViewTracker.viewedConversationIDs.count, 1,
                       "Re-tracking the same id must not duplicate the entry (Set semantics).")
    }

    func testUntrackingAbsentIDIsNoOp() {
        let absent = UUID()
        ActiveViewTracker.untrack(absent)   // never tracked
        XCTAssertEqual(ActiveViewTracker.viewedConversationIDs.count, 0)
        XCTAssertFalse(ActiveViewTracker.isViewing(absent))
    }

    // MARK: - Multiple distinct IDs (multi-window / multi-scene)

    func testMultipleIDsCoexist() {
        let a = UUID()
        let b = UUID()
        let c = UUID()
        ActiveViewTracker.track(a)
        ActiveViewTracker.track(b)
        ActiveViewTracker.track(c)

        XCTAssertTrue(ActiveViewTracker.isViewing(a))
        XCTAssertTrue(ActiveViewTracker.isViewing(b))
        XCTAssertTrue(ActiveViewTracker.isViewing(c))
        XCTAssertEqual(ActiveViewTracker.viewedConversationIDs.count, 3)

        // Untracking one doesn't disturb the others.
        ActiveViewTracker.untrack(b)
        XCTAssertTrue(ActiveViewTracker.isViewing(a))
        XCTAssertFalse(ActiveViewTracker.isViewing(b))
        XCTAssertTrue(ActiveViewTracker.isViewing(c))
        XCTAssertEqual(ActiveViewTracker.viewedConversationIDs.count, 2)
    }

    // MARK: - Reset hook

    func testResetClearsAllEntries() {
        ActiveViewTracker.track(UUID())
        ActiveViewTracker.track(UUID())
        ActiveViewTracker._resetForTesting()
        XCTAssertEqual(ActiveViewTracker.viewedConversationIDs.count, 0)
    }
}
