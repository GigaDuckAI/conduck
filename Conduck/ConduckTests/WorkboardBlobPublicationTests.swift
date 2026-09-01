// SPDX-License-Identifier: Apache-2.0

// ConduckTests
// WorkboardBlobPublicationTests.swift
//
// The write half of byte sync: which lane a payload takes, and what a crash
// between the two durable steps is allowed to leave behind.
//
// The material row and its blob live in different stores, so they cannot commit
// as one transaction. Everything here holds the protocol that makes that
// survivable — the blob is durable BEFORE any card claims it, a replay repairs
// whichever half is missing instead of publishing a second card, a blob
// carrying other bytes is replaced in the same save that repoints the card, and
// a publication that is refused takes back the bytes it wrote and only those.
// None of it is observable from the projection: a card with one correct blob
// and a card with one correct blob plus three stale ones open identically.

import XCTest
import CryptoKit
@testable import Conduck

final class WorkboardBlobPublicationTests: XCTestCase {

    private func hex(_ payload: Data) -> String {
        SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
    }

    private func deskMaterials(
        _ store: ConversationStore
    ) async throws -> [WorkMaterialRecord] {
        try await store.fetchWorkItem(id: Constants.workboardDeskItemID)?.materials ?? []
    }

    // MARK: - Lane selection

    func testAPayloadUnderTheCeilingBecomesABlobTheCardNamesButDoesNotHold() async throws {
        let store = ConversationStore(inMemory: true)
        let payload = Data("zone rate card, revision four".utf8)
        let draft = WorkMaterialDraft(
            kind: .file,
            title: "rates.txt",
            filename: "rates.txt",
            mimeType: "text/plain",
            payload: payload,
            byteSize: Int64(payload.count)
        )

        let published = try await store.upsertDeskMaterial(draft)

        XCTAssertEqual(published.storageMode, .syncedPayload,
                       "bytes within the ceiling ride private CloudKit")
        XCTAssertNil(published.localVaultKey,
                     "a synced card keeps no second copy in the device-local vault")
        XCTAssertEqual(published.byteSize, Int64(payload.count))
        let payloadColumn = await store._workMaterialPayloadColumnForTesting(id: draft.id)
        XCTAssertNil(
            payloadColumn,
            "the payload column stays unwritten — bytes on the material row would ride its record too"
        )

        let blobs = await store._workMaterialBlobRowsForTesting(materialID: draft.id)
        XCTAssertEqual(blobs.count, 1)
        XCTAssertEqual(blobs.first?.byteSize, Int64(payload.count))
        XCTAssertEqual(blobs.first?.contentHash, hex(payload))
        XCTAssertEqual(blobs.first?.payloadByteCount, payload.count)

        let completeness = try await store.workMaterialBlobCompleteness(materialIDs: [draft.id])
        XCTAssertEqual(completeness[draft.id]?.isComplete, true)
        let loaded = try await store.loadWorkMaterialPayload(id: draft.id)
        XCTAssertEqual(loaded, payload)
        let reclaimed = try await store.reconcileWorkAssetVault()
        XCTAssertEqual(reclaimed, 0, "the synced lane stages nothing into the vault")
    }

    func testAPayloadAboveTheCeilingTakesTheVaultAndAReplayRestoresIt() async throws {
        let store = ConversationStore(inMemory: true)
        let payload = Data(
            repeating: 0x5A,
            count: Int(Constants.workboardSyncCeilingBytes) + 1
        )
        let draft = WorkMaterialDraft(
            kind: .file,
            title: "capture.bin",
            filename: "capture.bin",
            mimeType: "application/octet-stream",
            payload: payload,
            byteSize: Int64(payload.count)
        )

        let published = try await store.upsertDeskMaterial(draft)
        XCTAssertEqual(published.storageMode, .localVault,
                       "one byte over the ceiling is a device-local payload with reattach")
        XCTAssertEqual(published.availability, .availableLocally)
        let key = try XCTUnwrap(published.localVaultKey)
        let blobs = await store._workMaterialBlobRowsForTesting(materialID: draft.id)
        XCTAssertTrue(blobs.isEmpty, "nothing over the ceiling may reach the payload store")

        try await store.workAssetVault.remove(key)
        let damagedValue = try await deskMaterials(store).first
        let damaged = try XCTUnwrap(damagedValue)
        XCTAssertEqual(damaged.availability, .unavailableOnThisDevice)

        let repaired = try await store.upsertDeskMaterial(draft)
        XCTAssertEqual(repaired.availability, .availableLocally,
                       "a replay that still carries the bytes restores the lane the card claims")
        XCTAssertEqual(repaired.storageMode, .localVault,
                       "repair restores what a card promises; it never moves the payload")
        let restored = try await store.loadWorkMaterialPayload(id: draft.id)
        XCTAssertEqual(restored?.count, payload.count)
        let rows = await store._workMaterialRowsForTesting(id: draft.id)
        XCTAssertEqual(rows.count, 1, "repair restores bytes; it never adds a card")
    }

    // MARK: - Interrupted publications

    func testABlobLeftByACrashIsAdoptedByTheReplayRatherThanDuplicated() async throws {
        let store = ConversationStore(inMemory: true)
        let payload = Data("the screenshot that survived the crash".utf8)
        let draft = WorkMaterialDraft(
            kind: .image,
            title: "IMG.png",
            filename: "IMG.png",
            mimeType: "image/png",
            payload: payload,
            byteSize: Int64(payload.count)
        )

        try await store._publishDeskMaterialBlobOnlyForTesting(draft)

        let deskBefore = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        XCTAssertNil(deskBefore, "step one publishes bytes; no card exists yet to name them")
        let stranded = await store._workMaterialBlobRowsForTesting(materialID: draft.id)
        XCTAssertEqual(stranded.count, 1)
        XCTAssertEqual(stranded.first?.contentHash, hex(payload))

        let published = try await store.upsertDeskMaterial(draft)

        XCTAssertEqual(published.storageMode, .syncedPayload)
        let loaded = try await store.loadWorkMaterialPayload(id: draft.id)
        XCTAssertEqual(loaded, payload)
        let blobs = await store._workMaterialBlobRowsForTesting(materialID: draft.id)
        XCTAssertEqual(blobs.count, 1,
                       "the bytes were already durable, so the replay writes no second row")
        XCTAssertEqual(blobs.first?.createdAt, stranded.first?.createdAt,
                       "and it adopts the row the interrupted attempt left rather than replacing it")
    }

    func testACardWhosePayloadStoreWasLostIsIncompleteUntilAReplayRestagesIt() async throws {
        let store = ConversationStore(inMemory: true)
        let payload = Data("the note attached to the invoice".utf8)
        let draft = WorkMaterialDraft(
            kind: .file,
            title: "invoice.pdf",
            filename: "invoice.pdf",
            mimeType: "application/pdf",
            payload: payload,
            byteSize: Int64(payload.count)
        )
        _ = try await store.upsertDeskMaterial(draft)

        let dropped = await store._deleteWorkMaterialBlobRowsForTesting(materialID: draft.id)
        XCTAssertEqual(dropped, 1)

        let cardValue = try await deskMaterials(store).first
        let card = try XCTUnwrap(cardValue)
        XCTAssertEqual(card.storageMode, .syncedPayload,
                       "the card still claims the synced lane — losing the payload store is silent")
        let completeness = try await store.workMaterialBlobCompleteness(materialIDs: [draft.id])
        XCTAssertNil(completeness[draft.id],
                     "the data layer reports the payload as not yet complete")
        let missing = try await store.loadWorkMaterialPayload(id: draft.id)
        XCTAssertNil(missing, "and it refuses to answer with bytes it does not have")

        let repaired = try await store.upsertDeskMaterial(draft)
        XCTAssertEqual(repaired.storageMode, .syncedPayload)
        let restored = try await store.loadWorkMaterialPayload(id: draft.id)
        XCTAssertEqual(restored, payload)
        let rows = await store._workMaterialRowsForTesting(id: draft.id)
        XCTAssertEqual(rows.count, 1)
    }

    func testACardMayClaimSyncedBytesThatHaveNotArrived() async throws {
        let store = ConversationStore(inMemory: true)
        // The state an import produces when the material record lands before
        // its blob record. The chip that renders it is the projection's, and it
        // reads exactly the completeness this asserts.
        let draft = WorkMaterialDraft(
            kind: .file,
            title: "arriving.bin",
            filename: "arriving.bin",
            mimeType: "application/octet-stream",
            storageMode: .syncedPayload
        )

        let published = try await store.upsertDeskMaterial(draft)

        XCTAssertEqual(published.storageMode, .syncedPayload)
        let blobs = await store._workMaterialBlobRowsForTesting(materialID: draft.id)
        XCTAssertTrue(blobs.isEmpty)
        let completeness = try await store.workMaterialBlobCompleteness(materialIDs: [draft.id])
        XCTAssertNil(completeness[draft.id])
        let loaded = try await store.loadWorkMaterialPayload(id: draft.id)
        XCTAssertNil(loaded)
    }

    // MARK: - Duplicates and disagreement

    func testDuplicateBlobsResolveToTheNewestCompleteRow() async throws {
        let store = ConversationStore(inMemory: true)
        let original = Data("the first device's copy".utf8)
        let draft = WorkMaterialDraft(
            kind: .file,
            title: "shared.txt",
            filename: "shared.txt",
            mimeType: "text/plain",
            payload: original,
            byteSize: Int64(original.count)
        )
        let published = try await store.upsertDeskMaterial(draft)

        let newer = Data("the second device's copy, imported later".utf8)
        await store._insertWorkMaterialBlobRowForTesting(
            materialID: draft.id,
            payload: newer,
            byteSize: Int64(newer.count),
            contentHash: hex(newer),
            updatedAt: published.updatedAt.addingTimeInterval(60)
        )
        let older = Data("a stale copy from a device that was offline".utf8)
        await store._insertWorkMaterialBlobRowForTesting(
            materialID: draft.id,
            payload: older,
            byteSize: Int64(older.count),
            contentHash: hex(older),
            updatedAt: published.updatedAt.addingTimeInterval(-60)
        )

        let loaded = try await store.loadWorkMaterialPayload(id: draft.id)
        XCTAssertEqual(loaded, newer)
        let completeness = try await store.workMaterialBlobCompleteness(materialIDs: [draft.id])
        XCTAssertEqual(completeness[draft.id]?.contentHash, hex(newer))
        let blobs = await store._workMaterialBlobRowsForTesting(materialID: draft.id)
        XCTAssertEqual(blobs.count, 3,
                       "reading resolves duplicates; it never deletes a CloudKit record to do it")
    }

    func testAnIncompleteBlobNeverWinsAndIsNeverDeleted() async throws {
        let store = ConversationStore(inMemory: true)
        let payload = Data("the whole payload".utf8)
        let draft = WorkMaterialDraft(
            kind: .file,
            title: "whole.txt",
            filename: "whole.txt",
            mimeType: "text/plain",
            payload: payload,
            byteSize: Int64(payload.count)
        )
        let published = try await store.upsertDeskMaterial(draft)

        // An arrival in progress: newer than the complete row, but carrying
        // neither a hash nor a size to prove its bytes are whole.
        await store._insertWorkMaterialBlobRowForTesting(
            materialID: draft.id,
            payload: Data("half".utf8),
            byteSize: 0,
            contentHash: "",
            updatedAt: published.updatedAt.addingTimeInterval(120)
        )

        let loaded = try await store.loadWorkMaterialPayload(id: draft.id)
        XCTAssertEqual(loaded, payload)
        let completeness = try await store.workMaterialBlobCompleteness(materialIDs: [draft.id])
        XCTAssertEqual(completeness[draft.id]?.contentHash, hex(payload))

        _ = try await store.upsertDeskMaterial(draft)
        let blobs = await store._workMaterialBlobRowsForTesting(materialID: draft.id)
        XCTAssertEqual(blobs.count, 2,
                       "an incomplete row is an import in flight, so no write may remove it")
    }

    func testAReplayCarryingOtherBytesReplacesTheBlobPairedWithTheCard() async throws {
        let store = ConversationStore(inMemory: true)
        let materialID = UUID()
        let stale = Data("the bytes an interrupted attempt wrote".utf8)
        let current = Data("the bytes the capture actually carries now".utf8)
        func draft(_ payload: Data) -> WorkMaterialDraft {
            WorkMaterialDraft(
                id: materialID,
                kind: .file,
                title: "attachment.bin",
                filename: "attachment.bin",
                mimeType: "application/octet-stream",
                payload: payload,
                byteSize: Int64(payload.count)
            )
        }
        let first = try await store.upsertDeskMaterial(draft(stale))

        let replaced = try await store.upsertDeskMaterial(draft(current))

        XCTAssertEqual(replaced.byteSize, Int64(current.count))
        XCTAssertGreaterThan(replaced.updatedAt, first.updatedAt,
                             "the card is repointed in the save that retires the stale blob")
        let blobs = await store._workMaterialBlobRowsForTesting(materialID: materialID)
        XCTAssertEqual(blobs.count, 1)
        XCTAssertEqual(blobs.first?.contentHash, hex(current))
        let loaded = try await store.loadWorkMaterialPayload(id: materialID)
        XCTAssertEqual(loaded, current)
        let rows = await store._workMaterialRowsForTesting(id: materialID)
        XCTAssertEqual(rows.count, 1, "replacing a payload never publishes a second card")
    }

    func testAnIdenticalReplayWritesNothingAtAll() async throws {
        let store = ConversationStore(inMemory: true)
        let payload = Data("captured once, delivered twice".utf8)
        let draft = WorkMaterialDraft(
            kind: .file,
            title: "envelope.txt",
            filename: "envelope.txt",
            mimeType: "text/plain",
            payload: payload,
            byteSize: Int64(payload.count)
        )
        let published = try await store.upsertDeskMaterial(draft)
        let blobsBefore = await store._workMaterialBlobRowsForTesting(materialID: draft.id)

        let replayed = try await store.upsertDeskMaterial(draft)

        XCTAssertEqual(replayed.updatedAt, published.updatedAt,
                       "bytes that are already durable are not rewritten")
        let blobsAfter = await store._workMaterialBlobRowsForTesting(materialID: draft.id)
        XCTAssertEqual(blobsAfter, blobsBefore)
    }

    // MARK: - Refused publications

    func testARefusedPublicationTakesBackOnlyTheBytesItWrote() async throws {
        let store = ConversationStore(inMemory: true)
        let existingPayload = Data("the card the person already has".utf8)
        let materialID = UUID()
        func draft(_ payload: Data) -> WorkMaterialDraft {
            WorkMaterialDraft(
                id: materialID,
                kind: .file,
                title: "kept.txt",
                filename: "kept.txt",
                mimeType: "text/plain",
                payload: payload,
                byteSize: Int64(payload.count)
            )
        }
        _ = try await store.upsertDeskMaterial(draft(existingPayload))
        let deskValue = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        let desk = try XCTUnwrap(deskValue)
        let staleRevision = WorkboardRevision.value(for: desk.updatedAt) - 1

        let freshID = UUID()
        let freshPayload = Data("bytes for a card that is never published".utf8)
        do {
            _ = try await store.upsertDeskMaterial(
                WorkMaterialDraft(
                    id: freshID,
                    kind: .file,
                    title: "refused.txt",
                    filename: "refused.txt",
                    mimeType: "text/plain",
                    payload: freshPayload,
                    byteSize: Int64(freshPayload.count)
                ),
                expectedOwnerRevision: staleRevision
            )
            XCTFail("a write against a revision the board has moved past must be refused")
        } catch WorkboardStoreError.staleRevision {
            // Expected.
        }
        let refusedBlobs = await store._workMaterialBlobRowsForTesting(materialID: freshID)
        XCTAssertTrue(
            refusedBlobs.isEmpty,
            "the refused card's bytes name nothing, and the call that wrote them takes them back"
        )

        let rejectedPayload = Data("bytes that must not displace the existing ones".utf8)
        do {
            _ = try await store.upsertDeskMaterial(
                draft(rejectedPayload),
                expectedOwnerRevision: staleRevision
            )
            XCTFail("a refused replacement must not reach the card")
        } catch WorkboardStoreError.staleRevision {
            // Expected.
        }
        let blobs = await store._workMaterialBlobRowsForTesting(materialID: materialID)
        XCTAssertEqual(blobs.count, 1)
        XCTAssertEqual(blobs.first?.contentHash, hex(existingPayload),
                       "the blob the refused write found is left exactly as it was")
        let loaded = try await store.loadWorkMaterialPayload(id: materialID)
        XCTAssertEqual(loaded, existingPayload)
    }

    /// Two publications carrying the same bytes for one material both insert:
    /// the presence check and the insert are separate operations, and
    /// `(materialID, contentHash, byteSize)` carries no uniqueness constraint —
    /// CloudKit forbids one — so the rows are equal in every column. A rollback
    /// matching on those columns therefore reclaims the other call's payload
    /// along with its own, and a card naming those bytes is left with nothing
    /// behind it.
    ///
    /// The state is staged here rather than raced: a peer's newer import makes
    /// the presence check miss the identical row that is already there, which
    /// is the same position a concurrent publication is in.
    func testARefusedPublicationLeavesAnIdenticalBlobItDidNotWrite() async throws {
        let store = ConversationStore(inMemory: true)
        let mine = Data("the bytes this capture carries".utf8)
        let draft = WorkMaterialDraft(
            kind: .file,
            title: "shared.txt",
            filename: "shared.txt",
            mimeType: "text/plain",
            payload: mine,
            byteSize: Int64(mine.count)
        )
        let published = try await store.upsertDeskMaterial(draft)

        let peer = Data("bytes another device published for the same card".utf8)
        await store._insertWorkMaterialBlobRowForTesting(
            materialID: draft.id,
            payload: peer,
            byteSize: Int64(peer.count),
            contentHash: hex(peer),
            updatedAt: published.updatedAt.addingTimeInterval(60)
        )

        let deskValue = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        let desk = try XCTUnwrap(deskValue)
        do {
            _ = try await store.upsertDeskMaterial(
                draft,
                expectedOwnerRevision: WorkboardRevision.value(for: desk.updatedAt) - 1
            )
            XCTFail("a write against a revision the board has moved past must be refused")
        } catch WorkboardStoreError.staleRevision {
            // Expected.
        }

        let blobs = await store._workMaterialBlobRowsForTesting(materialID: draft.id)
        XCTAssertEqual(
            blobs.count, 2,
            "the refusal takes back the row it inserted and leaves the identical one standing"
        )
        XCTAssertEqual(
            Set(blobs.compactMap(\.contentHash)), [hex(mine), hex(peer)],
            "a row this call did not write is not this call's to reclaim, however equal its columns"
        )
        let loaded = try await store.loadWorkMaterialPayload(id: draft.id)
        XCTAssertEqual(loaded, peer, "the newest complete row still answers for the card")
    }

    /// The same rule on the reattach path, which is the one with no in-process
    /// claim serializing it: two reattaches of one card can genuinely overlap.
    func testARefusedReattachTakesBackOnlyTheBlobRowItWrote() async throws {
        let store = ConversationStore(inMemory: true)
        let mine = Data("the copy this reattach carries".utf8)
        let draft = WorkMaterialDraft(
            kind: .file,
            title: "reattached.txt",
            filename: "reattached.txt",
            mimeType: "text/plain",
            payload: mine,
            byteSize: Int64(mine.count)
        )
        let published = try await store.upsertDeskMaterial(draft)
        let peer = Data("a newer copy imported from another device".utf8)
        await store._insertWorkMaterialBlobRowForTesting(
            materialID: draft.id,
            payload: peer,
            byteSize: Int64(peer.count),
            contentHash: hex(peer),
            updatedAt: published.updatedAt.addingTimeInterval(60)
        )

        let replacement = FileManager.default.temporaryDirectory
            .appendingPathComponent("blob-rollback-\(UUID().uuidString).txt")
        try mine.write(to: replacement, options: .atomic)
        defer { try? FileManager.default.removeItem(at: replacement) }

        let deskValue = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        let desk = try XCTUnwrap(deskValue)
        do {
            _ = try await store.replaceWorkMaterialPayloadFile(
                id: draft.id,
                from: replacement,
                byteSize: Int64(mine.count),
                filename: replacement.lastPathComponent,
                mimeType: "text/plain",
                sourceDevice: "test",
                expectedOwnerRevision: WorkboardRevision.value(for: desk.updatedAt) - 1
            )
            XCTFail("a reattach against a stale revision must be refused")
        } catch WorkboardStoreError.staleRevision {
            // Expected.
        }

        let blobs = await store._workMaterialBlobRowsForTesting(materialID: draft.id)
        XCTAssertEqual(blobs.count, 2)
        XCTAssertEqual(Set(blobs.compactMap(\.contentHash)), [hex(mine), hex(peer)])
    }

    // MARK: - Reattach moves a card between the lanes

    func testReattachingASmallFileMovesACardOffTheVaultOntoTheSyncedLane() async throws {
        let store = ConversationStore(inMemory: true)
        let item = try await store.createWorkItem()
        let original = try await store.addWorkMaterial(
            WorkMaterialDraft(
                kind: .file,
                title: "draft.txt",
                filename: "draft.txt",
                mimeType: "text/plain",
                payload: Data("the copy that stayed on one device".utf8)
            ),
            to: item.id
        )
        let oldKey = try XCTUnwrap(original.localVaultKey)

        let replacement = FileManager.default.temporaryDirectory
            .appendingPathComponent("blob-reattach-\(UUID().uuidString).txt")
        let bytes = Data("the copy that syncs".utf8)
        try bytes.write(to: replacement, options: .atomic)
        defer { try? FileManager.default.removeItem(at: replacement) }

        let ownerValue = try await store.fetchWorkItem(id: item.id)
        let owner = try XCTUnwrap(ownerValue)
        let reattachedValue = try await store.replaceWorkMaterialPayloadFile(
            id: original.id,
            from: replacement,
            byteSize: Int64(bytes.count),
            filename: replacement.lastPathComponent,
            mimeType: "text/plain",
            sourceDevice: "test",
            expectedOwnerRevision: WorkboardRevision.value(for: owner.updatedAt)
        )
        let reattached = try XCTUnwrap(reattachedValue)

        XCTAssertEqual(reattached.storageMode, .syncedPayload)
        XCTAssertNil(reattached.localVaultKey)
        let blobs = await store._workMaterialBlobRowsForTesting(materialID: original.id)
        XCTAssertEqual(blobs.count, 1)
        XCTAssertEqual(blobs.first?.contentHash, hex(bytes))
        let loaded = try await store.loadWorkMaterialPayload(id: original.id)
        XCTAssertEqual(loaded, bytes)
        let keptOldLeaf = await store.workAssetVault.contains(oldKey)
        XCTAssertFalse(keptOldLeaf,
                       "the lane a card leaves is cleared by the same write that moves it")
    }

    func testReattachingAnUnsyncableFileMovesACardOffTheSyncedLaneWithItsBlob() async throws {
        let store = ConversationStore(inMemory: true)
        let payload = Data("the synced copy".utf8)
        let draft = WorkMaterialDraft(
            kind: .file,
            title: "synced.txt",
            filename: "synced.txt",
            mimeType: "text/plain",
            payload: payload,
            byteSize: Int64(payload.count)
        )
        _ = try await store.upsertDeskMaterial(draft)
        let blobsBefore = await store._workMaterialBlobRowsForTesting(materialID: draft.id)
        XCTAssertEqual(blobsBefore.count, 1)

        // A zero-byte file has no measurable payload to sync, so the policy
        // sends it to the vault — the same answer an oversized file gets, for
        // the cost of an empty write.
        let replacement = FileManager.default.temporaryDirectory
            .appendingPathComponent("blob-reattach-empty-\(UUID().uuidString).bin")
        try Data().write(to: replacement, options: .atomic)
        defer { try? FileManager.default.removeItem(at: replacement) }

        let deskValue = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        let desk = try XCTUnwrap(deskValue)
        let revision = WorkboardRevision.value(for: desk.updatedAt)
        do {
            _ = try await store.replaceWorkMaterialPayloadFile(
                id: draft.id,
                from: replacement,
                byteSize: 0,
                filename: replacement.lastPathComponent,
                mimeType: "application/octet-stream",
                sourceDevice: "test",
                expectedOwnerRevision: revision - 1
            )
            XCTFail("a reattach against a stale revision must be refused")
        } catch WorkboardStoreError.staleRevision {
            // Expected.
        }
        let survivingPayload = try await store.loadWorkMaterialPayload(id: draft.id)
        XCTAssertEqual(survivingPayload, payload,
                       "a refused reattach leaves the payload the card still names")

        let reattachedValue = try await store.replaceWorkMaterialPayloadFile(
            id: draft.id,
            from: replacement,
            byteSize: 0,
            filename: replacement.lastPathComponent,
            mimeType: "application/octet-stream",
            sourceDevice: "test",
            expectedOwnerRevision: revision
        )
        let reattached = try XCTUnwrap(reattachedValue)

        XCTAssertEqual(reattached.storageMode, .localVault)
        XCTAssertNotNil(reattached.localVaultKey)
        let blobsAfter = await store._workMaterialBlobRowsForTesting(materialID: draft.id)
        XCTAssertTrue(blobsAfter.isEmpty,
                      "the card's payload left the synced lane, so its blob left with it")
        let emptied = try await store.loadWorkMaterialPayload(id: draft.id)
        XCTAssertEqual(emptied, Data())
    }

    /// CloudKit can merge one card into several physical rows, and blob
    /// deletion is scoped to the LOGICAL material id. A reattach that wrote
    /// only the canonical row would therefore leave a duplicate still claiming
    /// `.syncedPayload` while this same save deleted the blobs behind it —
    /// unreadable the moment that row wins the canonical read.
    func testReattachWritesEveryDuplicateRowSoNoneResurrectsTheOldLane() async throws {
        let store = ConversationStore(inMemory: true)
        let payload = Data("the payload the card is about to lose".utf8)
        let draft = WorkMaterialDraft(
            kind: .file,
            title: "synced.txt",
            filename: "synced.txt",
            mimeType: "text/plain",
            payload: payload,
            byteSize: Int64(payload.count)
        )
        let published = try await store.upsertDeskMaterial(draft)
        XCTAssertEqual(published.storageMode, .syncedPayload)
        await store._duplicateWorkMaterialRowForTesting(
            id: draft.id,
            updatedAt: published.updatedAt.addingTimeInterval(3_600)
        )
        let mergedRows = await store._workMaterialRowsForTesting(id: draft.id)
        XCTAssertEqual(mergedRows.count, 2)

        // A zero-byte file has no measurable payload to sync, so the policy
        // sends it to the vault and the card leaves the synced lane.
        let replacement = FileManager.default.temporaryDirectory
            .appendingPathComponent("blob-merge-reattach-\(UUID().uuidString).bin")
        try Data().write(to: replacement, options: .atomic)
        defer { try? FileManager.default.removeItem(at: replacement) }

        let deskValue = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        let desk = try XCTUnwrap(deskValue)
        let reattachedValue = try await store.replaceWorkMaterialPayloadFile(
            id: draft.id,
            from: replacement,
            byteSize: 0,
            filename: replacement.lastPathComponent,
            mimeType: "application/octet-stream",
            sourceDevice: "test",
            expectedOwnerRevision: WorkboardRevision.value(for: desk.updatedAt)
        )
        let reattached = try XCTUnwrap(reattachedValue)

        XCTAssertEqual(reattached.storageMode, .localVault)
        XCTAssertEqual(reattached.availability, .availableLocally)
        let rows = await store._workMaterialRowsForTesting(id: draft.id)
        XCTAssertEqual(rows.count, 2, "a reattach replaces bytes; it never adds a row")
        XCTAssertEqual(
            Set(rows.compactMap(\.storageMode)), ["localVault"],
            "a row left on the synced lane would claim a payload this same save deleted"
        )
        XCTAssertEqual(Set(rows.map(\.localVaultKey)).count, 1)
        XCTAssertNotNil(rows.first?.localVaultKey)
        XCTAssertEqual(Set(rows.compactMap(\.byteSize)), [0])
        let blobs = await store._workMaterialBlobRowsForTesting(materialID: draft.id)
        XCTAssertTrue(blobs.isEmpty)
        let loaded = try await store.loadWorkMaterialPayload(id: draft.id)
        XCTAssertEqual(loaded, Data())
    }
}
