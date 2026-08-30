// SPDX-License-Identifier: Apache-2.0

// ConduckTests
// WorkboardOrderingTests.swift
//
// Presentation-only board ordering is independent from lifecycle and brief
// activity. These tests lock the global project-strip behavior, pin cohorts,
// optimistic cross-device compare-and-swap, and idempotent retry semantics.

import XCTest
@testable import Conduck

final class WorkboardOrderingTests: XCTestCase {
    func testReorderPersistsWithoutAdvancingActivityAndReplayIsIdempotent() async throws {
        let store = ConversationStore(inMemory: true)
        let first = try await store.createWorkItem(WorkItemDraft(
            content: WorkItemContent(title: "First"),
            createdAt: Date(timeIntervalSince1970: 100)
        ))
        let second = try await store.createWorkItem(WorkItemDraft(
            content: WorkItemContent(title: "Second"),
            createdAt: Date(timeIntervalSince1970: 200)
        ))
        let third = try await store.createWorkItem(WorkItemDraft(
            content: WorkItemContent(title: "Third"),
            createdAt: Date(timeIntervalSince1970: 300)
        ))
        let beforeActivity = Dictionary(uniqueKeysWithValues: [first, second, third].map {
            ($0.id, $0.updatedAt)
        })
        let expectation = [first, second, third].map {
            WorkItemBoardPosition(id: $0.id, boardOrder: nil)
        }
        let request = WorkItemBoardReorder(
            movingItemID: third.id,
            expectedPinned: false,
            expectedPositions: expectation,
            orderedItemIDs: [third.id, first.id, second.id]
        )

        let reordered = try await store.reorderWorkItems(request)

        XCTAssertEqual(reordered.map(\.id), [third.id, first.id, second.id])
        XCTAssertEqual(reordered.map(\.boardOrder), [0, 1, 2])
        XCTAssertEqual(reordered.map(\.state), [.draft, .draft, .draft])
        for item in reordered {
            XCTAssertEqual(item.updatedAt, try XCTUnwrap(beforeActivity[item.id]),
                           "moving a card is not objective activity")
        }

        let replayed = try await store.reorderWorkItems(request)
        XCTAssertEqual(replayed.map(\.boardOrder), [0, 1, 2],
                       "losing the first response and replaying must remain successful")

        let staleDifferentOrder = WorkItemBoardReorder(
            movingItemID: first.id,
            expectedPinned: false,
            expectedPositions: expectation,
            orderedItemIDs: [first.id, third.id, second.id]
        )
        do {
            _ = try await store.reorderWorkItems(staleDifferentOrder)
            XCTFail("a stale device must not overwrite a newer board arrangement")
        } catch WorkboardStoreError.staleRevision {
            // Expected.
        }
    }

    func testProjectStripOrderIsGlobalAcrossLifecycleButAttentionOrderIsNot() throws {
        let draft = item(title: "Draft", state: .draft, boardOrder: 0)
        let review = item(title: "Needs You", state: .review, boardOrder: 1)
        let waiting = item(title: "Waiting", state: .waiting, boardOrder: 2)
        let pinned = item(title: "Pinned", state: .done, boardOrder: 0, isPinned: true)
        let items = [waiting, review, pinned, draft]

        XCTAssertEqual(
            WorkboardPresentationLogic.projectStripItems(
                items,
                filter: .all,
                searchText: ""
            ).map(\.id),
            [pinned.id, draft.id, review.id, waiting.id]
        )
        XCTAssertEqual(
            WorkboardPresentationLogic.visibleItems(
                items,
                filter: .all,
                searchText: ""
            ).map(\.id),
            [pinned.id, review.id, waiting.id, draft.id],
            "attention views continue to surface lifecycle facts"
        )

        let request = try XCTUnwrap(WorkboardBoardOrdering.request(
            moving: review.id,
            relativeTo: draft.id,
            placement: .before,
            in: items
        ))
        XCTAssertEqual(request.orderedItemIDs, [review.id, draft.id, waiting.id],
                       "a Needs You card can move among other projects without changing state")
        XCTAssertEqual(request.desiredPositions.map(\.boardOrder), [0, 1, 2])
        XCTAssertNil(WorkboardBoardOrdering.request(
            moving: review.id,
            relativeTo: pinned.id,
            placement: .before,
            in: items
        ), "pinning is a separate, explicit cohort")
        XCTAssertEqual(review.state, .review)
    }

    func testDirectionalMoveUsesTheSameGlobalPinCohort() throws {
        let first = item(title: "First", state: .draft, boardOrder: 0)
        let middle = item(title: "Middle", state: .review, boardOrder: 1)
        let last = item(title: "Last", state: .waiting, boardOrder: 2)
        let items = [last, first, middle]

        let earlier = try XCTUnwrap(WorkboardBoardOrdering.request(
            moving: middle.id,
            direction: .earlier,
            in: items
        ))
        XCTAssertEqual(earlier.orderedItemIDs, [middle.id, first.id, last.id])

        let later = try XCTUnwrap(WorkboardBoardOrdering.request(
            moving: middle.id,
            direction: .later,
            in: items
        ))
        XCTAssertEqual(later.orderedItemIDs, [first.id, last.id, middle.id])
        XCTAssertNil(WorkboardBoardOrdering.request(
            moving: first.id,
            direction: .earlier,
            in: items
        ))
    }

    func testDirectionalMoveTargetsTheNextVisibleCardWhileKeepingTheCompleteCohort() throws {
        let first = item(title: "First", state: .draft, boardOrder: 0)
        let hidden = item(title: "Hidden", state: .waiting, boardOrder: 1)
        let last = item(title: "Last", state: .review, boardOrder: 2)
        let items = [first, hidden, last]

        let request = try XCTUnwrap(WorkboardBoardOrdering.request(
            moving: last.id,
            direction: .earlier,
            in: items,
            visibleItemIDs: [first.id, last.id]
        ))

        XCTAssertEqual(request.orderedItemIDs, [last.id, first.id, hidden.id])
        XCTAssertEqual(Set(request.expectedPositions.map(\.id)), Set(items.map(\.id)),
                       "the store CAS still covers hidden projects")
    }

    func testConcurrentCloudMergeDuplicateRanksHaveAStableRecoveryOrder() {
        let earlierID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let laterID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let first = WorkboardItemSnapshot(
            id: laterID,
            title: "Later UUID",
            modifiedAt: Date(timeIntervalSince1970: 100),
            boardOrder: 4
        )
        let second = WorkboardItemSnapshot(
            id: earlierID,
            title: "Earlier UUID",
            modifiedAt: Date(timeIntervalSince1970: 100),
            boardOrder: 4
        )

        let order = WorkboardPresentationLogic.projectStripItems(
            [first, second],
            filter: .all,
            searchText: ""
        )

        XCTAssertEqual(order.map(\.id), [earlierID, laterID])
    }

    private func item(
        title: String,
        state: WorkboardItemState,
        boardOrder: Int64?,
        isPinned: Bool = false
    ) -> WorkboardItemSnapshot {
        WorkboardItemSnapshot(
            title: title,
            state: state,
            isPinned: isPinned,
            boardOrder: boardOrder
        )
    }
}
