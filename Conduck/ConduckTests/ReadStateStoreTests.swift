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
//   • each marker set is bounded, oldest dropped first;
//   • the read marker and the failure-acknowledgement marker are INDEPENDENT —
//     writing one never moves the other, and neither can be derived from the
//     other. That last one is the point of the second set: the read marker is
//     stamped when the user's own message appears, so a failure read from it
//     would arrive pre-acknowledged and never show a mark at all.
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

    private func failureKey(_ id: UUID) -> String {
        Constants.conversationFailureSeenPrefix + id.uuidString
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
            failureSeenAt: store.lastFailureSeen(id),
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
            failureSeenAt: nil,
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

    func testUnparsableKeysUnderTheFailurePrefixArePrunedOnLoad() {
        let defaults = InMemoryDefaultsStore(seed: [
            Constants.conversationFailureSeenPrefix + "not-a-uuid": 12.0,
            Constants.conversationFailureSeenPrefix + UUID().uuidString: "not-a-number",
            "unrelated.key": 7
        ])
        _ = makeStore(defaults)
        let survivors = defaults.dictionaryRepresentation().keys
            .filter { $0.hasPrefix(Constants.conversationFailureSeenPrefix) }
        XCTAssertTrue(survivors.isEmpty)
        XCTAssertNotNil(defaults.object(forKey: "unrelated.key"))
    }

    // MARK: - markFailureSeen

    func testMarkFailureSeenStoresAndSurvivesAReload() {
        let defaults = InMemoryDefaultsStore()
        let store = makeStore(defaults)
        store.stampEpochIfNeeded(now: now)
        let id = UUID()
        store.markFailureSeen(id, failedAt: nil, now: now.addingTimeInterval(120))

        XCTAssertEqual(store.lastFailureSeen(id), now.addingTimeInterval(120))
        let reloaded = makeStore(defaults)
        XCTAssertEqual(reloaded.lastFailureSeen(id), now.addingTimeInterval(120))
    }

    func testMarkFailureSeenIsMonotonicAgainstABackwardsClock() {
        let store = makeStore()
        store.stampEpochIfNeeded(now: now)
        let id = UUID()
        store.markFailureSeen(id, failedAt: nil, now: now.addingTimeInterval(600))
        store.markFailureSeen(id, failedAt: nil, now: now)   // clock moved back
        XCTAssertEqual(store.lastFailureSeen(id), now.addingTimeInterval(600))
    }

    func testAFailureFromAClockAheadSiblingIsStillAcknowledgeable() {
        // THE reason the failure marker takes the failed turn's stamp at all: a
        // turn mirrored from a device whose clock runs a little ahead would
        // otherwise stay newer than the marker, and its row would stay red while
        // the user was looking straight at the error.
        let store = makeStore()
        store.stampEpochIfNeeded(now: now)
        let id = UUID()
        let slightlyAhead = now.addingTimeInterval(90)
        store.markFailureSeen(id, failedAt: slightlyAhead, now: now)
        XCTAssertEqual(store.lastFailureSeen(id), slightlyAhead)
    }

    func testAWildlyFutureFailureStampClampsToTheSkewGrace() {
        let store = makeStore()
        store.stampEpochIfNeeded(now: now)
        let id = UUID()
        store.markFailureSeen(id, failedAt: now.addingTimeInterval(30 * 86_400), now: now)
        XCTAssertEqual(
            store.lastFailureSeen(id),
            now.addingTimeInterval(ReadStateStore.clockSkewGrace)
        )
    }

    func testTheFailureCapDropsTheOldestMarkersFirst() {
        let store = makeStore()
        store.stampEpochIfNeeded(now: now)
        var ids: [UUID] = []
        for index in 0..<ReadStateStore.maxMarkers {
            let id = UUID()
            ids.append(id)
            store.markFailureSeen(id, failedAt: nil, now: now.addingTimeInterval(Double(index)))
        }
        XCTAssertEqual(store.storedFailureMarkers().count, ReadStateStore.maxMarkers)

        let newcomer = UUID()
        store.markFailureSeen(newcomer, failedAt: nil, now: now.addingTimeInterval(1_000_000))

        XCTAssertEqual(store.storedFailureMarkers().count, ReadStateStore.maxMarkers)
        XCTAssertNil(store.storedFailureMarkers()[ids[0]], "the oldest marker must be dropped")
        XCTAssertNotNil(store.storedFailureMarkers()[newcomer])
    }

    // MARK: - The two marker sets are independent

    func testMarkingViewedNeverAcknowledgesAFailure() {
        // THE defect this whole second marker exists to prevent. The read marker
        // is stamped the instant the user's own message appears — before the
        // send that will fail has failed — so if acknowledgement read from it,
        // every composer-sent failure would arrive pre-acknowledged and the red
        // mark would never appear at all.
        let store = makeStore()
        store.stampEpochIfNeeded(now: now)
        let id = UUID()
        store.markViewed(id, lastActivityAt: now, now: now)
        XCTAssertNil(store.lastFailureSeen(id), "reading a thread acknowledges nothing")
        XCTAssertNil(store.storedFailureMarkers()[id])
    }

    func testAcknowledgingAFailureNeverMovesTheReadMarker() {
        let store = makeStore()
        store.stampEpochIfNeeded(now: now)
        let id = UUID()
        store.markFailureSeen(id, failedAt: nil, now: now.addingTimeInterval(600))
        XCTAssertNil(store.storedMarkers()[id])
    }

    func testTheTwoSetsRoundTripSeparatelyThroughDefaults() {
        let defaults = InMemoryDefaultsStore()
        let store = makeStore(defaults)
        store.stampEpochIfNeeded(now: now)
        let id = UUID()
        store.markViewed(id, lastActivityAt: nil, now: now.addingTimeInterval(60))
        store.markFailureSeen(id, failedAt: nil, now: now.addingTimeInterval(600))

        let reloaded = makeStore(defaults)
        XCTAssertEqual(reloaded.lastViewed(id), now.addingTimeInterval(60))
        XCTAssertEqual(reloaded.lastFailureSeen(id), now.addingTimeInterval(600))
    }

    // MARK: - clearFailureSeen (Retry re-arms the mark)

    func testARetriedTurnCanGoRedAgain() {
        // THE retry regression. Retry writes only the status column, so the
        // failed turn keeps its original `createdAt` and the stamp the resolver
        // compares against never advances. Without spending the acknowledgement
        // here, one acknowledgement covers every re-failure that turn ever has —
        // and `markFailureSeen` is monotone, so nothing else could undo it.
        let store = makeStore()
        store.stampEpochIfNeeded(now: now)
        let id = UUID()
        let failedAt = now.addingTimeInterval(-600)   // frozen across the retry

        store.markFailureSeen(id, failedAt: failedAt, now: now)
        XCTAssertTrue(acknowledged(store, id, failedAt: failedAt))

        store.clearFailureSeen(id)

        XCTAssertFalse(
            acknowledged(store, id, failedAt: failedAt),
            "a re-failed turn must earn a fresh mark, not inherit the old acknowledgement"
        )
    }

    func testClearFailureSeenLeavesTheReadMarkerAlone() {
        // Retry is not a statement about having read the thread.
        let store = makeStore()
        store.stampEpochIfNeeded(now: now)
        let id = UUID()
        store.markViewed(id, lastActivityAt: nil, now: now.addingTimeInterval(600))
        store.markFailureSeen(id, failedAt: nil, now: now.addingTimeInterval(600))

        store.clearFailureSeen(id)

        XCTAssertEqual(store.lastViewed(id), now.addingTimeInterval(600))
        XCTAssertNil(store.storedFailureMarkers()[id])
    }

    func testAcknowledgementTakesNoEpochFallback() {
        // The asymmetry with `lastViewed`, locked. An epoch fallback would make
        // `clearFailureSeen` a no-op for any turn older than the epoch — which
        // is every turn a retry touches, since a retry never advances
        // `createdAt`.
        let store = makeStore()
        store.stampEpochIfNeeded(now: now)
        let id = UUID()
        XCTAssertNil(store.lastFailureSeen(id), "no marker means unacknowledged, never 'as of the epoch'")
        XCTAssertEqual(store.lastViewed(id), now, "the read marker still takes the epoch")
    }

    func testAPreEpochFailureStillCarriesItsMark() {
        // The silent-suppression class the missing fallback closes: a turn whose
        // `createdAt` predates this device's first launch — an imported failed
        // tail, or a pre-epoch `sending` turn the launch sweep later fails.
        let store = makeStore()
        store.stampEpochIfNeeded(now: now)
        XCTAssertFalse(
            acknowledged(store, UUID(), failedAt: now.addingTimeInterval(-86_400)),
            "a failure older than the epoch must still be able to show a mark"
        )
    }

    func testClearFailureSeenSurvivesAReload() {
        let defaults = InMemoryDefaultsStore()
        let store = makeStore(defaults)
        store.stampEpochIfNeeded(now: now)
        let id = UUID()
        store.markFailureSeen(id, failedAt: nil, now: now.addingTimeInterval(600))
        store.clearFailureSeen(id)

        let reloaded = makeStore(defaults)
        XCTAssertNil(reloaded.storedFailureMarkers()[id])
        XCTAssertNil(defaults.object(forKey: failureKey(id)))
    }

    func testClearFailureSeenOnAnUnknownConversationIsANoOp() {
        let store = makeStore()
        store.stampEpochIfNeeded(now: now)
        store.clearFailureSeen(UUID())
        XCTAssertTrue(store.storedFailureMarkers().isEmpty)
    }

    /// Ask the real resolver whether a failure at `failedAt` would still carry
    /// its mark, so these cases lock the END-TO-END answer rather than a
    /// timestamp comparison re-implemented in the test.
    private func acknowledged(_ store: ReadStateStore, _ id: UUID, failedAt: Date) -> Bool {
        ConversationActivityResolver.resolve(
            ConversationActivityInputs(
                lastActivityAt: failedAt,
                newestSendingAt: nil,
                newestFailedAt: failedAt,
                tailRole: .user
            ),
            locallyLiveSince: nil,
            lastViewedAt: store.lastViewed(id),
            failureSeenAt: store.lastFailureSeen(id),
            now: now
        ).failureAcknowledged
    }

    func testMarkDeletedClearsBothMarkers() {
        let defaults = InMemoryDefaultsStore()
        let store = makeStore(defaults)
        store.stampEpochIfNeeded(now: now)
        let id = UUID()
        store.markViewed(id, lastActivityAt: nil, now: now)
        store.markFailureSeen(id, failedAt: nil, now: now)

        store.markDeleted(id)

        XCTAssertTrue(store.storedMarkers().isEmpty)
        XCTAssertTrue(store.storedFailureMarkers().isEmpty)
        XCTAssertNil(defaults.object(forKey: markerKey(id)))
        XCTAssertNil(defaults.object(forKey: failureKey(id)))
    }
}
