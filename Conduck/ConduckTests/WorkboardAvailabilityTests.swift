// SPDX-License-Identifier: Apache-2.0

// ConduckTests
// WorkboardAvailabilityTests.swift
//
// The read half of byte sync: what a card is allowed to CLAIM about its bytes.
//
// A material row and its payload blob live in two stores that CloudKit
// materializes independently, so a card can legitimately arrive before its
// bytes. `storageMode == .syncedPayload` is therefore only the claim; the proof
// is a complete blob row. Everything here holds the consequences of that
// distinction — a card without one reads `.syncedPending`, cannot be opened,
// played or sent, and says so in the person's own words instead of asking to be
// reattached, which is what a device-local payload that is really gone asks for.
//
// Two more properties sit beside that, because neither is visible in what a
// card says. The projection answers its two questions ONCE for a whole board —
// counted here, since a per-card loop returns exactly the same cards while
// queueing a board's worth of round trips behind every other write in flight.
// And it answers the blob question from a metadata projection that never names
// `payload`: faulting a board's bytes in to ask how big they are is the exact
// cost the payload store exists to avoid, and that one stays a source guard
// because a fetch's projected columns leave no trace in its result.

import CloudKit
import CryptoKit
import XCTest
@testable import Conduck

@MainActor
final class WorkboardAvailabilityTests: XCTestCase {

    /// Every store here mints a vault directory of its own that nothing else
    /// removes; the fixture empties them when the class is done.
    private let isolated = IsolatedWorkStores()

    override func tearDown() async throws {
        await isolated.cleanUp()
        try await super.tearDown()
    }


    // MARK: - Helpers

    private func hex(_ payload: Data) -> String {
        SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
    }

    private func deskMaterials(
        _ store: ConversationStore
    ) async throws -> [UUID: WorkMaterialRecord] {
        let materials = try await store.fetchWorkItem(
            id: Constants.workboardDeskItemID
        )?.materials ?? []
        return Dictionary(uniqueKeysWithValues: materials.map { ($0.id, $0) })
    }

    private func syncedDraft(payload: Data, name: String) -> WorkMaterialDraft {
        WorkMaterialDraft(
            kind: .file,
            title: name,
            filename: name,
            mimeType: "application/octet-stream",
            payload: payload,
            byteSize: Int64(payload.count)
        )
    }

    /// The blob a card publishing these bytes names.
    private func pairing(of payload: Data) -> WorkMaterialBlobPairing {
        WorkMaterialBlobPairing(contentHash: hex(payload), byteSize: Int64(payload.count))
    }

    private var pendingCopy: String {
        String(localized: "workboard.material.syncPending", defaultValue: "Waiting for iCloud…")
    }

    private var reattachCopy: String {
        String(
            localized: "workboard.material.unavailableHere",
            defaultValue: "Reattach on this device to open"
        )
    }

    /// `.../Conduck/Conduck` — the project container holding the app sources.
    /// Derived from this file's compile-time path so the source guards below do
    /// not depend on the test runner's working directory.
    private func source(_ relativePath: String) throws -> String {
        let container = URL(fileURLWithPath: #filePath)  // .../ConduckTests/<this>
            .deletingLastPathComponent()                 // .../ConduckTests
            .deletingLastPathComponent()                 // .../Conduck/Conduck
        return try String(
            contentsOf: container.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    // MARK: - Completeness is what decides availability

    func testACardWhoseBlobIsCompleteIsSyncedAndOpenable() async throws {
        let store = isolated.make()
        let payload = Data("the invoice that arrived whole".utf8)
        let draft = syncedDraft(payload: payload, name: "invoice.pdf")

        let published = try await store.upsertDeskMaterial(draft)
        XCTAssertEqual(published.storageMode, .syncedPayload)

        let board = try await deskMaterials(store)
        let card = try XCTUnwrap(board[draft.id])
        XCTAssertEqual(card.availability, .synced)
        XCTAssertTrue(card.hasPayload, "availability decides hasPayload; the two cannot disagree")
        XCTAssertEqual(
            WorkboardLiveRepository.presentationAvailability(card), .available,
            "bytes that landed may be opened"
        )

        let loaded = try await store.loadWorkMaterialPayload(id: draft.id)
        XCTAssertEqual(loaded, payload)

        let detail = WorkboardLiveRepository.materialDetail(card)
        XCTAssertFalse(
            detail?.contains(pendingCopy) == true,
            "a card that is not waiting says nothing about waiting"
        )
    }

    func testACardClaimingSyncedBytesWithNoBlobIsPendingAndCannotBeOpened() async throws {
        let store = isolated.make()
        let payload = Data("the screenshot that has not landed here yet".utf8)
        let draft = syncedDraft(payload: payload, name: "shot.png")
        _ = try await store.upsertDeskMaterial(draft)

        // The state losing the payload store produces, and the state CloudKit
        // produces every time a material record imports before its blob.
        let dropped = await store._deleteWorkMaterialBlobRowsForTesting(materialID: draft.id)
        XCTAssertEqual(dropped, 1)

        let board = try await deskMaterials(store)
        let card = try XCTUnwrap(board[draft.id])
        XCTAssertEqual(card.availability, .syncedPending)
        XCTAssertEqual(card.storageMode, .syncedPayload, "the row still claims the synced lane")
        XCTAssertFalse(card.hasPayload)

        let presented = WorkboardLiveRepository.presentationAvailability(card)
        XCTAssertEqual(
            presented, .syncPending,
            "an arrival gap is its own presentation state, never the reattach one"
        )
        XCTAssertNotEqual(
            presented, .unavailableOnThisDevice,
            "a card whose bytes are on their way must not offer to replace them"
        )
        XCTAssertFalse(
            presented.isAvailable,
            "pending bytes fail closed: nothing may be opened, played or sent from them"
        )

        let loaded = try await store.loadWorkMaterialPayload(id: draft.id)
        XCTAssertNil(loaded, "there is nothing behind the claim to read")

        let detail = try XCTUnwrap(WorkboardLiveRepository.materialDetail(card))
        XCTAssertTrue(
            detail.contains(pendingCopy),
            "an arrival gap is named as one, not as damage the person has to repair"
        )
        XCTAssertFalse(
            detail.contains(reattachCopy),
            "bytes that are on their way must never ask to be replaced"
        )
    }

    func testAnIncompleteBlobRowIsAnArrivalInProgressRatherThanAPayload() async throws {
        let store = isolated.make()
        let payload = Data("half an import".utf8)
        let draft = syncedDraft(payload: payload, name: "half.bin")
        _ = try await store.upsertDeskMaterial(draft)
        await store._deleteWorkMaterialBlobRowsForTesting(materialID: draft.id)

        // A row whose hash and size have not arrived. The bytes may even all be
        // there; nothing in the row proves they are.
        await store._insertWorkMaterialBlobRowForTesting(
            materialID: draft.id,
            payload: payload,
            byteSize: 0,
            contentHash: "",
            updatedAt: Date()
        )

        let board = try await deskMaterials(store)
        XCTAssertEqual(board[draft.id]?.availability, .syncedPending)

        let loaded = try await store.loadWorkMaterialPayload(id: draft.id)
        XCTAssertNil(loaded)

        let rows = await store._workMaterialBlobRowsForTesting(materialID: draft.id)
        XCTAssertEqual(rows.count, 1, "an incomplete row is never deleted to resolve a read")
    }

    func testDuplicateBlobRowsResolveToTheNewestCompleteRow() async throws {
        let store = isolated.make()
        let newest = Data("the bytes that won".utf8)
        let draft = syncedDraft(payload: newest, name: "merged.bin")
        _ = try await store.upsertDeskMaterial(draft)

        // CloudKit can import one logical blob as several physical rows: an
        // older complete one, and a newer one still missing its proof.
        let older = Data("the bytes that lost".utf8)
        await store._insertWorkMaterialBlobRowForTesting(
            materialID: draft.id,
            payload: older,
            byteSize: Int64(older.count),
            contentHash: hex(older),
            updatedAt: Date(timeIntervalSince1970: 1)
        )
        await store._insertWorkMaterialBlobRowForTesting(
            materialID: draft.id,
            payload: newest,
            byteSize: 0,
            contentHash: "",
            updatedAt: Date(timeIntervalSinceNow: 60)
        )

        let board = try await deskMaterials(store)
        XCTAssertEqual(
            board[draft.id]?.availability, .synced,
            "a newer incomplete row does not hide the complete one behind it"
        )

        let loaded = try await store.loadWorkMaterialPayload(id: draft.id)
        XCTAssertEqual(loaded, newest)

        let completeness = try await store.workMaterialBlobCompleteness(
            materialIDs: [draft.id],
            pairedWith: [draft.id: pairing(of: newest)]
        )
        let winner = try XCTUnwrap(completeness[draft.id])
        XCTAssertEqual(winner.contentHash, hex(newest), "the newest COMPLETE row answers")
        XCTAssertEqual(winner.byteSize, Int64(newest.count))

        let rows = await store._workMaterialBlobRowsForTesting(materialID: draft.id)
        XCTAssertEqual(rows.count, 3, "reading resolves duplicates; it never deletes one")
    }

    /// The pairing, from the READ side. A blob row carrying other bytes under
    /// this material's id — another device's republication, whose own material
    /// update has not landed here yet — is NEWER than the card's own, so a
    /// newest-complete-wins read would serve it. It is not what this card
    /// published, and until the row naming it arrives the card must go on
    /// answering with its own payload.
    func testANewerBlobCarryingOtherBytesIsNotThisCardsPayload() async throws {
        let store = isolated.make()
        let mine = Data("what this device published".utf8)
        let draft = syncedDraft(payload: mine, name: "shared.bin")
        let published = try await store.upsertDeskMaterial(draft)
        XCTAssertEqual(
            published.contentHash, hex(mine),
            "a synced card records the bytes it was published with"
        )

        let peer = Data("what another device published for the same card".utf8)
        await store._insertWorkMaterialBlobRowForTesting(
            materialID: draft.id,
            payload: peer,
            byteSize: Int64(peer.count),
            contentHash: hex(peer),
            updatedAt: published.updatedAt.addingTimeInterval(60)
        )

        let board = try await deskMaterials(store)
        XCTAssertEqual(board[draft.id]?.availability, .synced)
        let loaded = try await store.loadWorkMaterialPayload(id: draft.id)
        XCTAssertEqual(
            loaded, mine,
            "the card opens the payload its own row names, not the newest row under its id"
        )

        // And the card is pending — not quietly serving somebody else's bytes —
        // the moment its own payload is the one that is missing.
        await store._deleteWorkMaterialBlobRowsForTesting(materialID: draft.id)
        await store._insertWorkMaterialBlobRowForTesting(
            materialID: draft.id,
            payload: peer,
            byteSize: Int64(peer.count),
            contentHash: hex(peer),
            updatedAt: published.updatedAt.addingTimeInterval(60)
        )
        let afterLoss = try await deskMaterials(store)
        XCTAssertEqual(
            afterLoss[draft.id]?.availability, .syncedPending,
            "a complete blob that is not the one this card names proves nothing about it"
        )
        let unreadable = try await store.loadWorkMaterialPayload(id: draft.id)
        XCTAssertNil(unreadable)
    }

    // MARK: - The whole board, in one pass

    func testOneBoardPassAnswersEveryLaneCorrectly() async throws {
        let store = isolated.make()

        let landed = syncedDraft(payload: Data("landed".utf8), name: "landed.bin")
        let pending = syncedDraft(payload: Data("pending".utf8), name: "pending.bin")
        let vaulted = syncedDraft(
            payload: Data(repeating: 0x2A, count: Int(Constants.workboardSyncCeilingBytes) + 1),
            name: "oversized.bin"
        )
        let note = WorkMaterialDraft(kind: .note, title: "a thought", textContent: "a thought")

        _ = try await store.upsertDeskMaterial(landed)
        _ = try await store.upsertDeskMaterial(pending)
        let vaultedRecord = try await store.upsertDeskMaterial(vaulted)
        _ = try await store.upsertDeskMaterial(note)
        await store._deleteWorkMaterialBlobRowsForTesting(materialID: pending.id)

        let board = try await deskMaterials(store)
        XCTAssertEqual(board.count, 4)
        XCTAssertEqual(board[landed.id]?.availability, .synced)
        XCTAssertEqual(board[pending.id]?.availability, .syncedPending)
        XCTAssertEqual(
            board[vaulted.id]?.availability, .availableLocally,
            "a payload over the ceiling is device-local and is not waiting for anything"
        )
        XCTAssertEqual(board[note.id]?.availability, .metadataOnly)

        // A vault card whose leaf is gone asks for a REATTACH, never for
        // patience: nothing is on its way for it.
        let key = try XCTUnwrap(vaultedRecord.localVaultKey)
        try await store.workAssetVault.remove(key)

        let afterLoss = try await deskMaterials(store)
        XCTAssertEqual(afterLoss[vaulted.id]?.availability, .unavailableOnThisDevice)
        XCTAssertEqual(
            afterLoss[landed.id]?.availability, .synced,
            "one card losing its bytes says nothing about another's"
        )

        let vaultedBlobs = await store._workMaterialBlobRowsForTesting(materialID: vaulted.id)
        XCTAssertTrue(vaultedBlobs.isEmpty, "nothing over the ceiling reaches the payload store")
    }

    // MARK: - Structural guards

    func testTheAvailabilityProjectionNeverNamesThePayloadColumn() throws {
        let store = try source("Conduck/Services/ConversationStore+Workboard.swift")
        let declaration = try XCTUnwrap(
            store.range(of: "func workMaterialBlobCompleteness"),
            "the completeness projection is gone or renamed"
        )
        let body = String(store[declaration.lowerBound...].prefix(1_600))
        let properties = try XCTUnwrap(
            body.range(of: "propertiesToFetch = ["),
            "the completeness fetch no longer states what it projects"
        )
        let tail = String(body[properties.upperBound...])
        let projected = String(tail[..<(tail.firstIndex(of: "]") ?? tail.endIndex)])

        for property in ["materialID", "byteSize", "contentHash", "updatedAt"] {
            XCTAssertTrue(projected.contains(property), "availability needs \(property)")
        }
        XCTAssertFalse(
            projected.contains("payload"),
            """
            The completeness fetch projects `payload`. Asking how big a blob is \
            must never realize it: a board's worth of ceiling-sized payloads \
            would fault in on every refresh, which is the whole reason the bytes \
            live in a store of their own.
            """
        )
    }

    /// One board load asks each of its two questions ONCE, however many cards
    /// the board holds.
    ///
    /// Counted rather than read off the source, because the RESULT of a per-card
    /// loop is identical to the result of a batch: eight cards read the same
    /// either way, and the cost — one suspension on the vault actor and one
    /// fetch into the payload store per card, queued behind every write in
    /// flight on the path a board refresh runs on — is invisible to any
    /// assertion about what the cards say. The counters sit at the two calls
    /// themselves, so a loop that resolved key by key would report eight and
    /// four instead of one and one.
    func testAvailabilityIsResolvedOncePerFetchRatherThanOncePerCard() async throws {
        let store = isolated.make()
        // The desk has to exist before a card can be parked on it under the
        // vault lane; a small payload takes that lane only through the
        // arbitrary-owner fixture, which is what keeps this case cheap.
        _ = try await store.upsertDeskMaterial(
            WorkMaterialDraft(kind: .note, title: "first", textContent: "first")
        )
        for index in 0..<4 {
            _ = try await store.upsertDeskMaterial(
                syncedDraft(payload: Data("synced \(index)".utf8), name: "synced-\(index).bin")
            )
            _ = try await store.addWorkMaterial(
                WorkMaterialDraft(
                    kind: .file,
                    title: "vaulted-\(index).bin",
                    filename: "vaulted-\(index).bin",
                    mimeType: "application/octet-stream",
                    payload: Data("vaulted \(index)".utf8)
                ),
                to: Constants.workboardDeskItemID
            )
        }

        await store._resetProjectionBatchCountsForTesting()
        let board = try await deskMaterials(store)
        let counts = await store._projectionBatchCountsForTesting()

        XCTAssertEqual(board.count, 9)
        XCTAssertEqual(board.values.filter { $0.availability == .synced }.count, 4)
        XCTAssertEqual(board.values.filter { $0.availability == .availableLocally }.count, 4)
        XCTAssertEqual(
            counts.vaultReadability, 1,
            """
            The board resolved the vault \(counts.vaultReadability) times for 4 device-local \
            cards. Each is a hop onto the vault actor; card by card, a board's worth of them \
            queues behind every write in flight.
            """
        )
        XCTAssertEqual(
            counts.blobCompleteness, 1,
            """
            The board asked the payload store \(counts.blobCompleteness) times for 4 synced \
            cards. Completeness is one projection over the whole set, or the board pays a \
            fetch per card to learn what one fetch already knows.
            """
        )

        // A second pass is a second answer, not a cached one — the counter is
        // counting real calls, which is what makes the two above meaningful.
        _ = try await deskMaterials(store)
        let after = await store._projectionBatchCountsForTesting()
        XCTAssertEqual(after.vaultReadability, 2)
        XCTAssertEqual(after.blobCompleteness, 2)
    }

    // MARK: - Desk banner

    /// The banner is a function of ACCOUNT state and of nothing else. The only
    /// input `WorkboardSyncBannerPolicy` takes is `CloudSyncMonitor.Reason`,
    /// which exists for the three states a person can fix and for no sync EVENT
    /// — card metadata and card bytes are mirrored from two separate stores, so
    /// the most recent failure can concern one payload while the rest of the
    /// desk syncs normally, and a banner claims the whole desk is stuck.
    func testTheDeskBannerShowsOnlyForAnAccountStateThePersonCanFix() {
        XCTAssertNotNil(
            WorkboardSyncBannerPolicy.message(showsBanner: true, reason: .noAccount),
            "an actionable account state is exactly what the banner exists for"
        )
        XCTAssertNil(
            WorkboardSyncBannerPolicy.message(showsBanner: true, reason: nil),
            """
            No reason means no state the person can act on — a transient or \
            healthy account, which the monitor never turns into a `Reason`.
            """
        )
        XCTAssertNil(
            WorkboardSyncBannerPolicy.message(showsBanner: false, reason: .quotaExceeded),
            """
            The desk honours the same sticky per-outage dismissal the \
            conversation list does: one broken account, dismissed once.
            """
        )
    }

    /// The desk's banner says what a person looking at cards can check. Chat's
    /// wording is about conversations, and reusing it here leaves the reader to
    /// work out whether the desk in front of them is affected at all.
    func testTheDeskBannerNamesCardsRatherThanConversations() {
        for reason in [CloudSyncMonitor.Reason.noAccount, .restricted, .quotaExceeded] {
            let desk = String(localized: WorkboardSyncBannerPolicy.message(for: reason))

            XCTAssertFalse(
                desk.localizedCaseInsensitiveContains("conversation"),
                "the desk's \(reason) banner still talks about conversations: \(desk)"
            )
            XCTAssertTrue(
                desk.localizedCaseInsensitiveContains("card"),
                "the desk's \(reason) banner names nothing the reader can see: \(desk)"
            )
            XCTAssertNotEqual(
                desk,
                String(localized: reason.bannerMessage),
                "the desk's \(reason) banner is Chat's sentence again"
            )
        }

        // One slot showing the same sentence for "signed out", "restricted" and
        // "storage full" would say that something is wrong and nothing about
        // what to do.
        let desk = [CloudSyncMonitor.Reason.noAccount, .restricted, .quotaExceeded]
            .map { String(localized: WorkboardSyncBannerPolicy.message(for: $0)) }
        XCTAssertEqual(Set(desk).count, 3)
    }

    func testEachActionableAccountReasonSaysSomethingDifferent() {
        // `CloudSyncMonitorTests` already pins which account states are
        // actionable and that each carries copy. What the desk adds is that the
        // three read differently: one banner slot showing the same sentence for
        // "signed out", "restricted" and "storage full" would tell the person
        // that something is wrong and nothing about what to do.
        let reasons: [CloudSyncMonitor.Reason] = [.noAccount, .restricted, .quotaExceeded]
        let messages = reasons.map { String(localized: $0.bannerMessage) }

        XCTAssertEqual(Set(messages).count, reasons.count)
        XCTAssertEqual(CloudSyncMonitor.actionableReason(for: .noAccount), .noAccount)
        XCTAssertNil(
            CloudSyncMonitor.actionableReason(for: .temporarilyUnavailable),
            "a transient state the system retries never reaches the desk"
        )
    }
}
