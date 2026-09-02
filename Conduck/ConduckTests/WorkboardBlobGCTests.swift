// SPDX-License-Identifier: Apache-2.0

// ConduckTests
// WorkboardBlobGCTests.swift
//
// How synced payload bytes are reclaimed, and — just as load-bearing — when
// they must NOT be.
//
// Paired deletion is the only path: a card and its blob leave in one save, so
// no device is left holding bytes for a card that no longer exists. There is
// deliberately no orphan sweep, because CloudKit can import a blob before the
// material that names it and a sweep would export the deletion of a payload
// that is merely early. These cases pin both halves, plus the older invariant
// they must not break: erasing every conversation is a Chat operation and
// leaves the desk, its cards and now their payloads standing.

import XCTest
@testable import Conduck

final class WorkboardBlobGCTests: XCTestCase {

    /// Every store here mints a vault directory of its own that nothing else
    /// removes; the fixture empties them when the class is done.
    private let isolated = IsolatedWorkStores()

    override func tearDown() async throws {
        await isolated.cleanUp()
        try await super.tearDown()
    }


    private func syncedDraft(
        _ title: String,
        _ payload: Data,
        id: UUID = UUID()
    ) -> WorkMaterialDraft {
        WorkMaterialDraft(
            id: id,
            kind: .file,
            title: title,
            filename: title,
            mimeType: "text/plain",
            payload: payload,
            byteSize: Int64(payload.count)
        )
    }

    // MARK: - Paired deletion

    func testDeletingACardDeletesItsPayloadInTheSameOperation() async throws {
        let store = isolated.make()
        let payload = Data("the courier quote".utf8)
        let draft = syncedDraft("quote.txt", payload)
        let published = try await store.upsertDeskMaterial(draft)
        XCTAssertEqual(published.storageMode, .syncedPayload)

        try await store.deleteWorkMaterial(id: draft.id)

        let blobs = await store._workMaterialBlobRowsForTesting(materialID: draft.id)
        XCTAssertTrue(blobs.isEmpty, "the card's bytes leave with the card")
        let completeness = try await store.workMaterialBlobCompleteness(materialIDs: [draft.id])
        XCTAssertTrue(completeness.isEmpty)
        let loaded = try await store.loadWorkMaterialPayload(id: draft.id)
        XCTAssertNil(loaded)

        let deskValue = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        let desk = try XCTUnwrap(deskValue)
        XCTAssertTrue(desk.materials.isEmpty, "the desk itself is never deleted")
    }

    func testEveryPhysicalBlobOfOneCardLeavesWithIt() async throws {
        let store = isolated.make()
        let payload = Data("the canonical copy".utf8)
        let draft = syncedDraft("merged.txt", payload)
        let published = try await store.upsertDeskMaterial(draft)

        // What a CloudKit merge can leave behind: a second complete row, and a
        // third whose hash and size have not arrived.
        let duplicate = Data("another device's copy of the same card".utf8)
        await store._insertWorkMaterialBlobRowForTesting(
            materialID: draft.id,
            payload: duplicate,
            byteSize: Int64(duplicate.count),
            contentHash: "0f0f",
            updatedAt: published.updatedAt.addingTimeInterval(30)
        )
        await store._insertWorkMaterialBlobRowForTesting(
            materialID: draft.id,
            payload: Data("partial".utf8),
            byteSize: 0,
            contentHash: "",
            updatedAt: published.updatedAt.addingTimeInterval(45)
        )
        let before = await store._workMaterialBlobRowsForTesting(materialID: draft.id)
        XCTAssertEqual(before.count, 3)

        try await store.deleteWorkMaterial(id: draft.id)

        let after = await store._workMaterialBlobRowsForTesting(materialID: draft.id)
        XCTAssertTrue(after.isEmpty,
                      "deletion is by material id, so no merged duplicate is left behind")
    }

    func testDeletingOneCardLeavesEveryOtherPayloadStanding() async throws {
        let store = isolated.make()
        let doomedPayload = Data("the card being removed".utf8)
        let keptPayload = Data("the card that stays".utf8)
        let doomed = syncedDraft("doomed.txt", doomedPayload)
        let kept = syncedDraft("kept.txt", keptPayload)
        _ = try await store.upsertDeskMaterial(doomed)
        _ = try await store.upsertDeskMaterial(kept)

        try await store.deleteWorkMaterial(id: doomed.id)

        let keptBlobs = await store._workMaterialBlobRowsForTesting(materialID: kept.id)
        XCTAssertEqual(keptBlobs.count, 1)
        let keptBytes = try await store.loadWorkMaterialPayload(id: kept.id)
        XCTAssertEqual(keptBytes, keptPayload)
        let deskValue = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        let desk = try XCTUnwrap(deskValue)
        XCTAssertEqual(desk.materials.map(\.id), [kept.id])
    }

    func testADeleteScopedToAnotherOwnerTouchesNeitherCardNorPayload() async throws {
        let store = isolated.make()
        let payload = Data("still on the desk".utf8)
        let draft = syncedDraft("safe.txt", payload)
        _ = try await store.upsertDeskMaterial(draft)

        try await store.deleteWorkMaterial(id: draft.id, workItemID: UUID())

        let blobs = await store._workMaterialBlobRowsForTesting(materialID: draft.id)
        XCTAssertEqual(blobs.count, 1,
                       "a delete that matched no card must not reclaim that card's bytes")
        let loaded = try await store.loadWorkMaterialPayload(id: draft.id)
        XCTAssertEqual(loaded, payload)
    }

    // MARK: - No orphan sweep

    func testABlobWhoseCardHasNotArrivedIsNeverSweptAway() async throws {
        let store = isolated.make()
        let payload = Data("bytes that arrived before their card".utf8)
        let draft = syncedDraft("early.txt", payload)
        try await store._publishDeskMaterialBlobOnlyForTesting(draft)

        // Every reclamation path in the store, run against a blob with no
        // material: a delete for that id, a delete for an unrelated card, and
        // the vault reconciler.
        try await store.deleteWorkMaterial(id: draft.id)
        _ = try await store.upsertDeskMaterial(syncedDraft("other.txt", Data("other".utf8)))
        let reclaimed = try await store.reconcileWorkAssetVault()
        XCTAssertEqual(reclaimed, 0)

        let blobs = await store._workMaterialBlobRowsForTesting(materialID: draft.id)
        XCTAssertEqual(blobs.count, 1,
                       "an early blob is not an orphan, and nothing may delete it on suspicion")

        let adopted = try await store.upsertDeskMaterial(draft)
        XCTAssertEqual(adopted.storageMode, .syncedPayload)
        let loaded = try await store.loadWorkMaterialPayload(id: draft.id)
        XCTAssertEqual(loaded, payload, "the card that finally arrives finds its bytes waiting")
    }

    // MARK: - Delete-all stays a Chat operation

    func testDeletingEveryConversationLeavesSyncedWorkPayloadsStanding() async throws {
        let store = isolated.make()
        let conversation = try await store.createConversation(backend: "test")
        _ = try await store.appendMessage(
            role: "user",
            text: "An ordinary chat turn",
            conversationID: conversation.id,
            sourceDevice: "phone"
        )
        let payload = Data("collected before the wipe".utf8)
        let draft = syncedDraft("collected.txt", payload)
        _ = try await store.upsertDeskMaterial(draft)

        try await store.deleteAll()

        let removed = try await store.fetchConversation(id: conversation.id)
        XCTAssertNil(removed)
        let deskValue = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        let desk = try XCTUnwrap(deskValue)
        XCTAssertEqual(desk.materials.map(\.id), [draft.id])
        let blobs = await store._workMaterialBlobRowsForTesting(materialID: draft.id)
        XCTAssertEqual(blobs.count, 1,
                       "erasing chats erases no collected material, and now no payload either")
        let loaded = try await store.loadWorkMaterialPayload(id: draft.id)
        XCTAssertEqual(loaded, payload)
    }
}
