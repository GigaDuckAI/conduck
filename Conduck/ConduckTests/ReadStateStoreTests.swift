// SPDX-License-Identifier: Apache-2.0

// Conduck
// ReadStateStoreTests.swift
//
// Locks the device-local read-state markers:
//   • an unstamped epoch treats EVERYTHING as viewed (a fresh install with an
//     imported iCloud history shows zero dots);
//   • `markViewed` is monotonic against a backwards clock and clamped against a
//     future `lastActivityAt`;
//   • deletion is explicit (`markDeleted`), never inferred from a fetch;
//   • the marker set is bounded, oldest dropped first.
//
// Every case builds its OWN `ReadStateStore` over a private
// `InMemoryDefaultsStore`, so nothing touches the process-wide singleton or the
// host's in-memory App Group.

import XCTest
@testable import Conduck

@MainActor
final class ReadStateStoreTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeStore(
        _ defaults: InMemoryDefaultsStore = InMemoryDefaultsStore()
    ) -> ReadStateStore {
        ReadStateStore(defaults: defaults)
    }

    private func markerKey(_ id: UUID) -> String {
        Constants.conversationReadStatePrefix + id.uuidString
    }

    // MARK: - Epoch

    func testEverythingIsViewedBeforeTheEpochIsStamped() {
        let store = makeStore()
        XCTAssertNil(store.lastViewed(UUID()))
    }

    func testAMarkerlessConversationResolvesToTheEpoch() {
        let store = makeStore()
        store.stampEpochIfNeeded(now: now)
        XCTAssertEqual(store.lastViewed(UUID()), now)
    }

    func testImportedHistoryStaysDark() {
        // THE imported-history guarantee: a conversation whose last activity
        // predates this device's first sight of the feature is viewed.
        let store = makeStore()
        store.stampEpochIfNeeded(now: now)
        let id = UUID()
        let state = ConversationActivityResolver.resolve(
            ConversationActivityInputs(
                lastActivityAt: now.addingTimeInterval(-86_400),
                newestSendingAt: nil,
                newestFailedAt: nil,
                tailRole: .agent
            ),
            locallyLiveSince: nil,
            lastViewedAt: store.lastViewed(id),
            now: now
        )
        XCTAssertFalse(state.hasUnseenReply)
    }

    func testAReplyAfterTheEpochIsUnseen() {
        let store = makeStore()
        store.stampEpochIfNeeded(now: now)
        let state = ConversationActivityResolver.resolve(
            ConversationActivityInputs(
                lastActivityAt: now.addingTimeInterval(60),
                newestSendingAt: nil,
                newestFailedAt: nil,
                tailRole: .agent
            ),
            locallyLiveSince: nil,
            lastViewedAt: store.lastViewed(UUID()),
            now: now.addingTimeInterval(60)
        )
        XCTAssertTrue(state.hasUnseenReply)
    }

    func testStampingIsIdempotent() {
        let store = makeStore()
        store.stampEpochIfNeeded(now: now)
        store.stampEpochIfNeeded(now: now.addingTimeInterval(10_000))
        XCTAssertEqual(store.lastViewed(UUID()), now)
    }

    func testTheEpochKeyIsNotMistakenForAMarker() {
        let defaults = InMemoryDefaultsStore()
        let first = makeStore(defaults)
        first.stampEpochIfNeeded(now: now)
        // The epoch key literally starts with the marker prefix; the reload
        // sweep must skip it rather than treat "epoch" as a conversation id.
        let reloaded = makeStore(defaults)
        XCTAssertTrue(reloaded.storedMarkers().isEmpty)
        XCTAssertEqual(reloaded.lastViewed(UUID()), now)
    }

    // MARK: - markViewed

    func testMarkViewedStoresAndSurvivesAReload() {
        let defaults = InMemoryDefaultsStore()
        let store = makeStore(defaults)
        store.stampEpochIfNeeded(now: now)
        let id = UUID()
        store.markViewed(id, lastActivityAt: nil, now: now.addingTimeInterval(120))

        XCTAssertEqual(store.lastViewed(id), now.addingTimeInterval(120))
        let reloaded = makeStore(defaults)
        XCTAssertEqual(reloaded.lastViewed(id), now.addingTimeInterval(120))
    }

    func testMarkViewedIsMonotonicAgainstABackwardsClock() {
        let store = makeStore()
        store.stampEpochIfNeeded(now: now)
        let id = UUID()
        store.markViewed(id, lastActivityAt: nil, now: now.addingTimeInterval(600))
        store.markViewed(id, lastActivityAt: nil, now: now)   // clock moved back
        XCTAssertEqual(store.lastViewed(id), now.addingTimeInterval(600))
    }

    func testAFutureLastActivityClampsToTheSkewGrace() {
        let store = makeStore()
        store.stampEpochIfNeeded(now: now)
        let id = UUID()
        let monthAhead = now.addingTimeInterval(30 * 86_400)
        store.markViewed(id, lastActivityAt: monthAhead, now: now)
        XCTAssertEqual(
            store.lastViewed(id),
            now.addingTimeInterval(ReadStateStore.clockSkewGrace)
        )
    }

    func testAModestlyAheadLastActivityIsAbsorbedExactly() {
        let store = makeStore()
        store.stampEpochIfNeeded(now: now)
        let id = UUID()
        let slightlyAhead = now.addingTimeInterval(90)
        store.markViewed(id, lastActivityAt: slightlyAhead, now: now)
        XCTAssertEqual(store.lastViewed(id), slightlyAhead)
    }

    func testAnOlderLastActivityDoesNotDragTheMarkerBackwards() {
        let store = makeStore()
        store.stampEpochIfNeeded(now: now)
        let id = UUID()
        store.markViewed(id, lastActivityAt: now.addingTimeInterval(-5_000), now: now)
        XCTAssertEqual(store.lastViewed(id), now)
    }

    // MARK: - markDeleted

    func testMarkDeletedRemovesExactlyOneKey() {
        let defaults = InMemoryDefaultsStore()
        let store = makeStore(defaults)
        store.stampEpochIfNeeded(now: now)
        let kept = UUID()
        let doomed = UUID()
        store.markViewed(kept, lastActivityAt: nil, now: now)
        store.markViewed(doomed, lastActivityAt: nil, now: now)

        store.markDeleted(doomed)

        XCTAssertEqual(store.storedMarkers().count, 1)
        XCTAssertNotNil(store.storedMarkers()[kept])
        XCTAssertNil(defaults.object(forKey: markerKey(doomed)))
        XCTAssertNotNil(defaults.object(forKey: markerKey(kept)))
        // Deleted, so it falls back to the epoch — not to "unseen".
        XCTAssertEqual(store.lastViewed(doomed), now)
    }

    func testMarkDeletedOnAnUnknownConversationIsANoOp() {
        let store = makeStore()
        store.stampEpochIfNeeded(now: now)
        store.markDeleted(UUID())
        XCTAssertTrue(store.storedMarkers().isEmpty)
    }

    // MARK: - Bound

    func testTheCapDropsTheOldestMarkersFirst() {
        let store = makeStore()
        store.stampEpochIfNeeded(now: now)
        var ids: [UUID] = []
        for index in 0..<ReadStateStore.maxMarkers {
            let id = UUID()
            ids.append(id)
            store.markViewed(id, lastActivityAt: nil, now: now.addingTimeInterval(Double(index)))
        }
        XCTAssertEqual(store.storedMarkers().count, ReadStateStore.maxMarkers)

        let newcomer = UUID()
        store.markViewed(newcomer, lastActivityAt: nil, now: now.addingTimeInterval(1_000_000))

        XCTAssertEqual(store.storedMarkers().count, ReadStateStore.maxMarkers)
        XCTAssertNil(store.storedMarkers()[ids[0]], "the oldest marker must be the one dropped")
        XCTAssertNotNil(store.storedMarkers()[ids[1]])
        XCTAssertNotNil(store.storedMarkers()[newcomer])
    }

    // MARK: - Orphans

    func testUnparsableKeysUnderThePrefixArePrunedOnLoad() {
        let defaults = InMemoryDefaultsStore(seed: [
            Constants.conversationReadStatePrefix + "not-a-uuid": 12.0,
            Constants.conversationReadStatePrefix + UUID().uuidString: "not-a-number",
            "unrelated.key": 7
        ])
        _ = makeStore(defaults)
        let survivors = defaults.dictionaryRepresentation().keys
            .filter { $0.hasPrefix(Constants.conversationReadStatePrefix) }
        XCTAssertTrue(survivors.isEmpty)
        XCTAssertNotNil(defaults.object(forKey: "unrelated.key"))
    }
}
