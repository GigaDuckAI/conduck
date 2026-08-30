// SPDX-License-Identifier: Apache-2.0

// ConduckTests
// ConversationStoreAtomicWorkCaptureTests.swift
//
// A provisional Work id is presentation state only. Its first durable source
// publishes the owner and material together, after any file bytes are safely
// staged; preparation and transaction failures must leave no partial card.

import XCTest
@testable import Conduck

final class ConversationStoreAtomicWorkCaptureTests: XCTestCase {
    func testInitialMaterialPublishesOwnerAndPayloadTogether() async throws {
        let store = ConversationStore(inMemory: true)
        let itemID = UUID()
        let materialID = UUID()
        let payload = Data("private launch notes".utf8)

        let created = try await store.createWorkItemWithInitialMaterial(
            WorkItemDraft(
                id: itemID,
                content: WorkItemContent(title: "Launch research")
            ),
            material: WorkMaterialDraft(
                id: materialID,
                kind: .file,
                title: "notes.txt",
                filename: "notes.txt",
                mimeType: "text/plain",
                payload: payload,
                byteSize: Int64(payload.count),
                sourceDevice: "test"
            )
        )

        XCTAssertEqual(created.id, itemID)
        XCTAssertEqual(created.content.title, "Launch research")
        XCTAssertEqual(created.materials.map(\.id), [materialID])
        XCTAssertEqual(created.materials.first?.workItemID, itemID)
        XCTAssertEqual(created.materials.first?.availability, .availableLocally)
        let loadedPayload = try await store.loadWorkMaterialPayload(id: materialID)
        XCTAssertEqual(loadedPayload, payload)

        let fetchedValue = try await store.fetchWorkItem(id: itemID)
        let fetched = try XCTUnwrap(fetchedValue)
        XCTAssertEqual(fetched.materials.map(\.id), [materialID])
    }

    func testUnreadableInitialFileCreatesNeitherOwnerNorMaterial() async throws {
        let store = ConversationStore(inMemory: true)
        let itemID = UUID()
        let materialID = UUID()
        let missingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-work-capture-\(UUID().uuidString).pdf")

        do {
            _ = try await store.createWorkItemWithInitialMaterial(
                WorkItemDraft(
                    id: itemID,
                    content: WorkItemContent(title: "Missing source")
                ),
                material: WorkMaterialDraft(
                    id: materialID,
                    kind: .file,
                    title: "missing.pdf",
                    filename: "missing.pdf",
                    mimeType: "application/pdf",
                    byteSize: -1,
                    sourceDevice: "test"
                ),
                sourceFileURL: missingURL,
                sourceFileByteSize: -1
            )
            XCTFail("an unreadable source must fail before publishing either row")
        } catch {
            // Expected: preparation never reaches the atomic Core Data save.
        }

        let storedOwner = try await store.fetchWorkItem(id: itemID)
        let storedMaterial = try await store.loadWorkMaterial(id: materialID)
        let reclaimedCount = try await store.reconcileWorkAssetVault()
        XCTAssertNil(storedOwner)
        XCTAssertNil(storedMaterial)
        XCTAssertEqual(reclaimedCount, 0)
    }

    func testTransactionRejectionRemovesStagedInitialBytes() async throws {
        let store = ConversationStore(inMemory: true)
        let itemID = UUID()
        _ = try await store.createWorkItem(WorkItemDraft(
            id: itemID,
            content: WorkItemContent(title: "Already durable")
        ))
        let payload = Data(repeating: 0xA5, count: 128)

        do {
            _ = try await store.createWorkItemWithInitialMaterial(
                WorkItemDraft(id: itemID),
                material: WorkMaterialDraft(
                    kind: .file,
                    title: "late.bin",
                    filename: "late.bin",
                    payload: payload,
                    byteSize: Int64(payload.count)
                )
            )
            XCTFail("an existing owner must reject the provisional-only boundary")
        } catch WorkboardStoreError.staleRevision {
            // Expected.
        }

        let existingValue = try await store.fetchWorkItem(id: itemID)
        let existing = try XCTUnwrap(existingValue)
        XCTAssertTrue(existing.materials.isEmpty)
        let reclaimedCount = try await store.reconcileWorkAssetVault()
        XCTAssertEqual(reclaimedCount, 0,
                       "the rejected transaction must clean its staged vault file")
    }
}

final class ConversationStoreWorkItemMutationTests: XCTestCase {
    func testMovingBetweenPinCohortsClearsTheOldBoardRank() async throws {
        let store = ConversationStore(inMemory: true)
        let first = try await store.createWorkItem(WorkItemDraft(
            content: WorkItemContent(title: "First")
        ))
        let second = try await store.createWorkItem(WorkItemDraft(
            content: WorkItemContent(title: "Second")
        ))
        let reorder = WorkItemBoardReorder(
            movingItemID: second.id,
            expectedPinned: false,
            expectedPositions: [first, second].map {
                WorkItemBoardPosition(id: $0.id, boardOrder: nil)
            },
            orderedItemIDs: [second.id, first.id]
        )
        let ranked = try await store.reorderWorkItems(reorder)
        let rankedFirst = try XCTUnwrap(ranked.first { $0.id == first.id })
        var pinnedContent = rankedFirst.content
        pinnedContent.isPinned = true

        let saved = try await store.saveWorkItemDraft(
            id: first.id,
            expectedRevision: revision(for: rankedFirst.updatedAt),
            content: pinnedContent,
            orderedMaterialIDs: []
        )

        XCTAssertTrue(saved.content.isPinned)
        XCTAssertNil(saved.boardOrder,
                     "a rank from the unpinned cohort must not leak into the pinned cohort")
        let unchangedPeer = try await store.fetchWorkItem(id: second.id)
        XCTAssertEqual(unchangedPeer?.boardOrder, 0)
    }

    private func revision(for date: Date) -> Int64 {
        Int64(bitPattern: date.timeIntervalSinceReferenceDate.bitPattern)
    }
}
