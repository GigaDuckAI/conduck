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

    /// Every store here mints a vault directory of its own that nothing else
    /// removes; the fixture empties them when the class is done.
    private let isolated = IsolatedWorkStores()

    override func tearDown() async throws {
        await isolated.cleanUp()
        try await super.tearDown()
    }


    private func hex(_ payload: Data) -> String {
        SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
    }

    /// The blob a card publishing these bytes names.
    private func pairing(of payload: Data) -> WorkMaterialBlobPairing {
        WorkMaterialBlobPairing(contentHash: hex(payload), byteSize: Int64(payload.count))
    }

    private func deskMaterials(
        _ store: ConversationStore
    ) async throws -> [WorkMaterialRecord] {
        try await store.fetchWorkItem(id: Constants.workboardDeskItemID)?.materials ?? []
    }


    /// A desk card whose payload is device-local. A zero-length or oversized
    /// payload is what puts one there through the capture lane; the fixture
    /// route below is what makes a SMALL device-local payload possible, which
    /// is the shape a reattach has to be able to put back.
    private func vaultCard(
        in store: ConversationStore,
        payload: Data,
        name: String
    ) async throws -> WorkMaterialRecord {
        if try await store.fetchWorkItem(id: Constants.workboardDeskItemID) == nil {
            _ = try await store.upsertDeskMaterial(
                WorkMaterialDraft(kind: .note, title: "desk", textContent: "desk")
            )
        }
        return try await store.addWorkMaterial(
            WorkMaterialDraft(
                kind: .file,
                title: name,
                filename: name,
                mimeType: "application/octet-stream",
                payload: payload
            ),
            to: Constants.workboardDeskItemID
        )
    }

    /// A file on disk the reattach cases can hand over, cleaned up by the
    /// caller's `defer`.
    private func temporaryFile(_ bytes: Data, extension ext: String = "bin") throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("blob-publication-\(UUID().uuidString).\(ext)")
        try bytes.write(to: url, options: .atomic)
        return url
    }

    /// Take the leaf away between the save and the proof — the reclamation in
    /// another process that the staging guard exists to stop, arriving in the
    /// one window it cannot cover. Returning nil lets the REAL confirmation run
    /// over what the closure did, so the refusal is the production one.
    private func removeLeafBeforeConfirming(
        _ store: ConversationStore,
        at site: WorkPublicationSite
    ) async {
        let vault = await store.workAssetVault
        await store._setPublicationConfirmationHookForTesting { hitSite, _, key, _ in
            guard hitSite == site else { return nil }
            try? await vault.remove(key)
            return nil
        }
    }

    // MARK: - The row records what the leaf holds

    /// A vault row's `byteSize` is measured off the leaf, not taken from the
    /// caller. The two halves are one change: the confirmation compares the
    /// leaf against that column, so a column carrying a claim would either
    /// refuse a healthy publication or, left uncompared, let a truncated leaf
    /// pass as whole.
    func testAVaultRowRecordsTheBytesTheLeafHoldsRatherThanTheCallersClaim() async throws {
        let store = isolated.make()
        _ = try await store.upsertDeskMaterial(
            WorkMaterialDraft(kind: .note, title: "desk", textContent: "desk")
        )
        let payload = Data("twenty bytes exactly".utf8)
        let card = try await store.addWorkMaterial(
            WorkMaterialDraft(
                kind: .file,
                title: "claimed.bin",
                filename: "claimed.bin",
                mimeType: "application/octet-stream",
                payload: payload,
                // Deliberately wrong, and nothing downstream may believe it.
                byteSize: 9_999
            ),
            to: Constants.workboardDeskItemID
        )

        XCTAssertEqual(card.storageMode, .localVault)
        XCTAssertEqual(
            card.byteSize, Int64(payload.count),
            "the row records the length the leaf holds, never the size the caller declared"
        )
        let rows = await store._workMaterialRowsForTesting(id: card.id)
        XCTAssertEqual(Set(rows.compactMap(\.byteSize)), [Int64(payload.count)])
        XCTAssertEqual(
            card.availability, .availableLocally,
            "and the publication confirmed against that same number rather than the claim"
        )
        let loaded = try await store.loadWorkMaterialPayload(id: card.id)
        XCTAssertEqual(loaded, payload)
    }

    // MARK: - A leaf that will not read back after the row committed

    /// The refusal branch of a fresh desk capture. It runs after Core Data has
    /// committed, so the card is real and the person can see it — reporting a
    /// bare failure would leave a caller that minted this id for this attempt
    /// free to retry under a new one and strand the card it already published.
    func testAFreshPublicationThatCannotProveItsLeafReportsTheCommittedCard() async throws {
        let store = isolated.make()
        await removeLeafBeforeConfirming(store, at: .deskPublish)

        // A zero-length payload takes the device-local lane, which is the lane
        // with a leaf to lose.
        let draft = WorkMaterialDraft(
            kind: .file,
            title: "empty.bin",
            filename: "empty.bin",
            mimeType: "application/octet-stream",
            payload: Data()
        )
        let posted = expectation(forNotification: .conversationsDidChange, object: nil)

        do {
            _ = try await store.upsertDeskMaterial(draft)
            XCTFail("a payload the vault cannot read back is not a durable capture")
        } catch let failure as WorkMaterialCommittedUnavailableError {
            XCTAssertEqual(failure.record.id, draft.id)
            XCTAssertEqual(
                failure.record.availability, .unavailableOnThisDevice,
                "the error carries the card as it stands, which is the point of carrying it"
            )
        }
        await fulfillment(of: [posted], timeout: 2)

        let deskValue = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        let desk = try XCTUnwrap(deskValue)
        XCTAssertEqual(desk.materials.map(\.id), [draft.id],
                       "the card committed; the board must not be told otherwise")
        XCTAssertEqual(desk.materials.first?.availability, .unavailableOnThisDevice)

        // And it is repairable rather than a dead end: the replay carrying the
        // same bytes restores the lane the card claims.
        await store._setPublicationConfirmationHookForTesting(nil)
        let repaired = try await store.upsertDeskMaterial(draft)
        XCTAssertEqual(repaired.availability, .availableLocally)
        let rows = await store._workMaterialRowsForTesting(id: draft.id)
        XCTAssertEqual(rows.count, 1, "the repair is the same card, never a second one")
    }

    /// The same rule at the arbitrary-owner insert, which returns its record
    /// rather than re-reading it and so had its own way of hiding the card.
    func testAnArbitraryInsertThatCannotProveItsLeafReportsItsCommittedCard() async throws {
        let store = isolated.make()
        _ = try await store.upsertDeskMaterial(
            WorkMaterialDraft(kind: .note, title: "desk", textContent: "desk")
        )
        await removeLeafBeforeConfirming(store, at: .arbitraryInsert)

        let materialID = UUID()
        do {
            _ = try await store.addWorkMaterial(
                WorkMaterialDraft(
                    id: materialID,
                    kind: .file,
                    title: "inserted.bin",
                    filename: "inserted.bin",
                    mimeType: "application/octet-stream",
                    payload: Data("bytes that will not read back".utf8)
                ),
                to: Constants.workboardDeskItemID
            )
            XCTFail("an insert whose leaf cannot be proved is not a durable publication")
        } catch let failure as WorkMaterialCommittedUnavailableError {
            XCTAssertEqual(failure.record.id, materialID)
            XCTAssertEqual(failure.record.availability, .unavailableOnThisDevice)
        }

        let rows = await store._workMaterialRowsForTesting(id: materialID)
        XCTAssertEqual(rows.count, 1, "the row committed before the proof was asked for")
    }

    // MARK: - A reattach that cannot prove its leaf

    /// The bytes a reattach replaces are the only copy the card had — the
    /// picked file belongs to the person, not to the app. So a replacement
    /// whose leaf will not read back must not cost them the payload it was
    /// replacing: the old keys stay, and the rows go back to naming them.
    func testAReattachThatCannotProveItsLeafKeepsTheBytesItWasReplacing() async throws {
        let store = isolated.make()
        let original = Data("the copy the card already had".utf8)
        let card = try await vaultCard(in: store, payload: original, name: "original.bin")
        let oldKey = try XCTUnwrap(card.localVaultKey)

        let replacement = try temporaryFile(Data())
        defer { try? FileManager.default.removeItem(at: replacement) }
        await removeLeafBeforeConfirming(store, at: .reattach)

        let deskValue = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        let desk = try XCTUnwrap(deskValue)
        do {
            _ = try await store.replaceWorkMaterialPayloadFile(
                id: card.id,
                from: replacement,
                byteSize: 0,
                filename: replacement.lastPathComponent,
                mimeType: "application/octet-stream",
                sourceDevice: "test",
                expectedOwnerRevision: WorkboardRevision.value(for: desk.updatedAt)
            )
            XCTFail("a replacement the vault cannot read back must be reported as failed")
        } catch WorkboardStoreError.materialPayloadUnavailable {
            // Expected: nothing is left committed, so there is no card to adopt.
        }

        let rows = await store._workMaterialRowsForTesting(id: card.id)
        XCTAssertEqual(Set(rows.compactMap(\.localVaultKey)), [oldKey],
                       "the card names the payload it had before the failed swap")
        XCTAssertEqual(Set(rows.compactMap(\.storageMode)), ["localVault"])
        XCTAssertEqual(Set(rows.compactMap(\.byteSize)), [Int64(original.count)])
        let keptLeaf = await store.workAssetVault.contains(oldKey)
        XCTAssertTrue(keptLeaf, "the only surviving copy of the person's bytes stays on disk")
        let loaded = try await store.loadWorkMaterialPayload(id: card.id)
        XCTAssertEqual(loaded, original)
        let restoredValue = try await store
            .fetchWorkItem(id: Constants.workboardDeskItemID)?.materials
            .first { $0.id == card.id }
        let restored = try XCTUnwrap(restoredValue)
        XCTAssertEqual(restored.availability, .availableLocally)
        XCTAssertEqual(restored.filename, "original.bin",
                       "the metadata the swap overwrote comes back with the lane")
    }

    /// The same rule for a card whose payload was a BLOB, which is the harder
    /// half: the swap points the rows at the vault, and the old blob rows are
    /// the only copy of what the card had. They are therefore retired BEHIND
    /// the swap rather than inside it — a lane change is two logical operations
    /// — so a confirmation that refuses can put the card back on the synced
    /// lane with its bytes still there. Deleting them in the swap's own
    /// transaction would mean a reattach reported as FAILED had already
    /// destroyed the payload it was replacing, account-wide.
    func testAReattachOffTheSyncedLaneKeepsTheBlobItWasReplacing() async throws {
        let store = isolated.make()
        let payload = Data("the synced copy".utf8)
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

        let replacement = try temporaryFile(Data())
        defer { try? FileManager.default.removeItem(at: replacement) }
        await removeLeafBeforeConfirming(store, at: .reattach)

        let deskValue = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        let desk = try XCTUnwrap(deskValue)
        do {
            _ = try await store.replaceWorkMaterialPayloadFile(
                id: draft.id,
                from: replacement,
                byteSize: 0,
                filename: replacement.lastPathComponent,
                mimeType: "application/octet-stream",
                sourceDevice: "test",
                expectedOwnerRevision: WorkboardRevision.value(for: desk.updatedAt)
            )
            XCTFail("a replacement the vault cannot read back must be reported as failed")
        } catch WorkboardStoreError.materialPayloadUnavailable {
            // The card was put back, so nothing is committed for a caller to
            // adopt — an ordinary refusal, not a committed-but-unavailable one.
        }

        let rows = await store._workMaterialRowsForTesting(id: draft.id)
        XCTAssertEqual(Set(rows.compactMap(\.storageMode)), ["syncedPayload"],
                       "the card names the lane it was on before the failed swap")
        XCTAssertEqual(Set(rows.map(\.localVaultKey)), [nil])
        XCTAssertEqual(Set(rows.compactMap(\.byteSize)), [Int64(payload.count)])
        let blobs = await store._workMaterialBlobRowsForTesting(materialID: draft.id)
        XCTAssertEqual(blobs.count, 1,
                       "the only surviving copy of the person's bytes is still in the payload store")
        XCTAssertEqual(blobs.first?.contentHash, hex(payload))
        let survived = try await store.loadWorkMaterialPayload(id: draft.id)
        XCTAssertEqual(survived, payload)
        let restoredValue = try await store
            .fetchWorkItem(id: Constants.workboardDeskItemID)?.materials
            .first { $0.id == draft.id }
        let restored = try XCTUnwrap(restoredValue)
        XCTAssertEqual(restored.availability, .synced)
        XCTAssertEqual(restored.filename, "synced.txt",
                       "the metadata the swap overwrote comes back with the lane")

        // Still repairable by the person: a reattach that CAN be proved lands.
        await store._setPublicationConfirmationHookForTesting(nil)
        let recovered = Data("the copy that finally lands".utf8)
        let second = try temporaryFile(recovered, extension: "txt")
        defer { try? FileManager.default.removeItem(at: second) }
        let afterValue = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        let after = try XCTUnwrap(afterValue)
        _ = try await store.replaceWorkMaterialPayloadFile(
            id: draft.id,
            from: second,
            byteSize: Int64(recovered.count),
            filename: "recovered.txt",
            mimeType: "text/plain",
            sourceDevice: "test",
            expectedOwnerRevision: WorkboardRevision.value(for: after.updatedAt)
        )
        let loaded = try await store.loadWorkMaterialPayload(id: draft.id)
        XCTAssertEqual(loaded, recovered)
    }

    // MARK: - One publication per material at a time

    /// A payload and the row naming it commit separately, so a second writer
    /// arriving inside that gap finds a complete blob, adopts it without
    /// writing a row of its own, and commits a card the first writer's rollback
    /// then takes the bytes from. Two reattaches of one card across two iPad
    /// scenes are exactly that pair. The claim is what makes it impossible: no
    /// second caller may begin publishing this material's payload while another
    /// is still inside its own publication.
    ///
    /// Observed by completion order, because that is what mutual exclusion IS.
    /// The reattach holds for 400 ms after its save; the replay is launched
    /// 120 ms in and does no I/O of its own, so unclaimed it would finish while
    /// the reattach is still holding — which is the interleaving the finding
    /// describes, and which the recorded order refuses.
    func testOneMaterialsPayloadIsPublishedByOneCallerAtATime() async throws {
        let store = isolated.make()
        let original = Data("the copy the card already had".utf8)
        let card = try await vaultCard(in: store, payload: original, name: "contended.bin")
        let replacement = try temporaryFile(Data())
        defer { try? FileManager.default.removeItem(at: replacement) }

        let timeline = PublicationTimeline()
        await store._setPublicationConfirmationHookForTesting { site, _, _, _ in
            guard site == .reattach else { return nil }
            await timeline.append("reattach-held")
            try? await Task.sleep(for: .milliseconds(400))
            await timeline.append("reattach-released")
            return nil
        }

        let deskValue = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        let desk = try XCTUnwrap(deskValue)
        async let reattached: WorkMaterialRecord? = store.replaceWorkMaterialPayloadFile(
            id: card.id,
            from: replacement,
            byteSize: 0,
            filename: replacement.lastPathComponent,
            mimeType: "application/octet-stream",
            sourceDevice: "test",
            expectedOwnerRevision: WorkboardRevision.value(for: desk.updatedAt)
        )

        try await Task.sleep(for: .milliseconds(120))
        let replay = Task {
            _ = try await store.upsertDeskMaterial(
                WorkMaterialDraft(
                    id: card.id,
                    kind: .file,
                    title: "contended.bin",
                    filename: "contended.bin",
                    mimeType: "application/octet-stream",
                    payload: original
                )
            )
            await timeline.append("replay-done")
        }
        _ = try await reattached
        try await replay.value

        let events = await timeline.events
        XCTAssertEqual(
            events, ["reattach-held", "reattach-released", "replay-done"],
            """
            A second publication of this material's payload began while the first was still             inside its own. That is the window in which one caller adopts the other's blob and             the other's rollback deletes it.
            """
        )
    }

    // MARK: - Lane selection

    func testAPayloadUnderTheCeilingBecomesABlobTheCardNamesButDoesNotHold() async throws {
        let store = isolated.make()
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

        // The pairing, written in the same save as the lane: the card names the
        // bytes it published, so a blob that merely carries its id is not its
        // payload.
        XCTAssertEqual(published.contentHash, hex(payload))
        let rows = await store._workMaterialRowsForTesting(id: draft.id)
        XCTAssertEqual(
            Set(rows.compactMap(\.contentHash)), [hex(payload)],
            "every physical row names the blob, or a merge could resurrect an unpaired one"
        )

        let completeness = try await store.workMaterialBlobCompleteness(
            materialIDs: [draft.id],
            pairedWith: [draft.id: pairing(of: payload)]
        )
        XCTAssertEqual(completeness[draft.id]?.isComplete, true)
        let loaded = try await store.loadWorkMaterialPayload(id: draft.id)
        XCTAssertEqual(loaded, payload)
        let reclaimed = try await store.reconcileWorkAssetVault()
        XCTAssertEqual(reclaimed, 0, "the synced lane stages nothing into the vault")
    }

    func testAPayloadAboveTheCeilingTakesTheVaultAndAReplayRestoresIt() async throws {
        let store = isolated.make()
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
            // Deliberately wrong. A declared size is a claim about bytes the
            // caller may never have handed over, and a row that records the
            // claim gives `confirmPublication` nothing a truncated leaf could
            // fail against.
            byteSize: Int64(payload.count) + 4_096
        )

        let published = try await store.upsertDeskMaterial(draft)
        XCTAssertEqual(published.storageMode, .localVault,
                       "one byte over the ceiling is a device-local payload with reattach")
        XCTAssertEqual(published.availability, .availableLocally)
        XCTAssertEqual(published.byteSize, Int64(payload.count),
                       "the row records the length the leaf holds, not the caller's claim")
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

    /// A blob nobody's card names is not evidence, so the replay publishes its
    /// own and leaves the stranded row standing.
    ///
    /// It looks wasteful and is deliberate. This device cannot tell its own
    /// interrupted publication from a blob another device inserted and can still
    /// roll back — the two stores mirror independently, so a peer's blob arrives
    /// on its own — and a card committed against bytes a peer then deletes waits
    /// for iCloud for ever with nothing left to wait for. Rows carrying
    /// identical bytes cost one copy each until the card's bytes are replaced or
    /// the card is deleted; `WorkboardSyncedRowRepairTests` measures that bound,
    /// which is persistence rather than a count.
    func testABlobNoCardNamesIsNotAdoptedByTheReplayThatFindsIt() async throws {
        let store = isolated.make()
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
        XCTAssertEqual(published.availability, .synced)
        XCTAssertEqual(published.contentHash, hex(payload))
        let loaded = try await store.loadWorkMaterialPayload(id: draft.id)
        XCTAssertEqual(loaded, payload)
        let blobs = await store._workMaterialBlobRowsForTesting(materialID: draft.id)
        XCTAssertEqual(
            blobs.count, 2,
            "no card named those bytes, so the publication wrote a row of its own"
        )
        XCTAssertEqual(
            Set(blobs.compactMap(\.contentHash)), [hex(payload)],
            "both rows carry the same payload; the duplicate is the accepted cost"
        )
        XCTAssertTrue(
            blobs.contains { $0.createdAt == stranded.first?.createdAt },
            "and the row it found is left standing — deleting it would export a deletion"
        )

        // A second replay finds a card that DOES name these bytes, so it adopts
        // and writes nothing. That bounds REPLAY, not the state: an attempt that
        // dies again before its card commits strands another row, which is what
        // `WorkboardSyncedRowRepairTests` measures.
        _ = try await store.upsertDeskMaterial(draft)
        let afterSecondReplay = await store._workMaterialBlobRowsForTesting(materialID: draft.id)
        XCTAssertEqual(afterSecondReplay.count, 2)
    }

    func testACardWhosePayloadStoreWasLostIsIncompleteUntilAReplayRestagesIt() async throws {
        let store = isolated.make()
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
        let completeness = try await store.workMaterialBlobCompleteness(
            materialIDs: [draft.id],
            pairedWith: [draft.id: pairing(of: payload)]
        )
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
        let store = isolated.make()
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
        XCTAssertNil(published.contentHash,
                     "a card that carried no bytes names no blob; it is waiting for one")
        let blobs = await store._workMaterialBlobRowsForTesting(materialID: draft.id)
        XCTAssertTrue(blobs.isEmpty)
        let completeness = try await store.workMaterialBlobCompleteness(
            materialIDs: [draft.id],
            pairedWith: [:]
        )
        XCTAssertNil(completeness[draft.id])
        let loaded = try await store.loadWorkMaterialPayload(id: draft.id)
        XCTAssertNil(loaded)
    }

    // MARK: - Duplicates and disagreement

    /// Duplicates of the bytes a card NAMES resolve newest-first; complete rows
    /// carrying other bytes are not this card's payload at all.
    ///
    /// Both halves are the same rule. CloudKit imports one logical blob as
    /// several physical rows — identical copies, which the newest of answers —
    /// and it imports another device's republication as a row that is newer
    /// still. Only the material row says which bytes are the card's.
    func testDuplicatesOfTheNamedBytesResolveNewestFirstAndOtherBytesNeverWin() async throws {
        let store = isolated.make()
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

        // The same bytes, imported again as a second physical row.
        await store._insertWorkMaterialBlobRowForTesting(
            materialID: draft.id,
            payload: original,
            byteSize: Int64(original.count),
            contentHash: hex(original),
            updatedAt: published.updatedAt.addingTimeInterval(60)
        )
        // And a newer row carrying OTHER bytes: another device's republication,
        // whose material update has not landed here.
        let peer = Data("the second device's copy, imported later".utf8)
        await store._insertWorkMaterialBlobRowForTesting(
            materialID: draft.id,
            payload: peer,
            byteSize: Int64(peer.count),
            contentHash: hex(peer),
            updatedAt: published.updatedAt.addingTimeInterval(120)
        )

        let loaded = try await store.loadWorkMaterialPayload(id: draft.id)
        XCTAssertEqual(loaded, original, "the card opens the payload its own row names")
        let completeness = try await store.workMaterialBlobCompleteness(
            materialIDs: [draft.id],
            pairedWith: [draft.id: pairing(of: original)]
        )
        let winner = try XCTUnwrap(completeness[draft.id])
        XCTAssertEqual(winner.contentHash, hex(original))
        XCTAssertEqual(
            winner.updatedAt, published.updatedAt.addingTimeInterval(60),
            "among the rows the card names, the newest answers"
        )
        let blobs = await store._workMaterialBlobRowsForTesting(materialID: draft.id)
        XCTAssertEqual(blobs.count, 3,
                       "reading resolves duplicates; it never deletes a CloudKit record to do it")
    }

    func testAnIncompleteBlobNeverWinsAndIsNeverDeleted() async throws {
        let store = isolated.make()
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
        let completeness = try await store.workMaterialBlobCompleteness(
            materialIDs: [draft.id],
            pairedWith: [draft.id: pairing(of: payload)]
        )
        XCTAssertEqual(completeness[draft.id]?.contentHash, hex(payload))

        _ = try await store.upsertDeskMaterial(draft)
        let blobs = await store._workMaterialBlobRowsForTesting(materialID: draft.id)
        XCTAssertEqual(blobs.count, 2,
                       "an incomplete row is an import in flight, so no write may remove it")
    }

    func testAReplayCarryingOtherBytesReplacesTheBlobPairedWithTheCard() async throws {
        let store = isolated.make()
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
        let store = isolated.make()
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
        let store = isolated.make()
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
    /// the adoption check and the insert are separate operations, and
    /// `(materialID, contentHash, byteSize)` carries no uniqueness constraint —
    /// CloudKit forbids one — so the rows are equal in every column. A rollback
    /// matching on those columns therefore reclaims the other call's payload
    /// along with its own, and a card naming those bytes is left with nothing
    /// behind it.
    ///
    /// The state is staged here rather than raced: another device has already
    /// imported a row carrying exactly the bytes this refused replay writes,
    /// which is the same position a concurrent publication is in.
    func testARefusedPublicationLeavesAnIdenticalBlobItDidNotWrite() async throws {
        let store = isolated.make()
        let mine = Data("the bytes this capture carries".utf8)
        let materialID = UUID()
        func draft(_ payload: Data) -> WorkMaterialDraft {
            WorkMaterialDraft(
                id: materialID,
                kind: .file,
                title: "shared.txt",
                filename: "shared.txt",
                mimeType: "text/plain",
                payload: payload,
                byteSize: Int64(payload.count)
            )
        }
        let published = try await store.upsertDeskMaterial(draft(mine))

        // The identical row this refused replay is about to write, already here
        // from another device.
        let replay = Data("bytes a second capture of the same source carries".utf8)
        await store._insertWorkMaterialBlobRowForTesting(
            materialID: materialID,
            payload: replay,
            byteSize: Int64(replay.count),
            contentHash: hex(replay),
            updatedAt: published.updatedAt.addingTimeInterval(60)
        )

        let deskValue = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        let desk = try XCTUnwrap(deskValue)
        do {
            _ = try await store.upsertDeskMaterial(
                draft(replay),
                expectedOwnerRevision: WorkboardRevision.value(for: desk.updatedAt) - 1
            )
            XCTFail("a write against a revision the board has moved past must be refused")
        } catch WorkboardStoreError.staleRevision {
            // Expected.
        }

        let blobs = await store._workMaterialBlobRowsForTesting(materialID: materialID)
        XCTAssertEqual(
            blobs.count, 2,
            "the refusal takes back the row it inserted and leaves the identical one standing"
        )
        XCTAssertEqual(
            Set(blobs.compactMap(\.contentHash)), [hex(mine), hex(replay)],
            "a row this call did not write is not this call's to reclaim, however equal its columns"
        )
        let loaded = try await store.loadWorkMaterialPayload(id: materialID)
        XCTAssertEqual(
            loaded, mine,
            "the refused replay changed nothing, so the card still opens the bytes it named"
        )
    }

    /// The same rule on the reattach path, which is the one with no in-process
    /// claim serializing it: two reattaches of one card can genuinely overlap.
    func testARefusedReattachTakesBackOnlyTheBlobRowItWrote() async throws {
        let store = isolated.make()
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

        // Bytes neither row carries, so the reattach really does insert a blob
        // of its own for the refusal to take back.
        let arriving = Data("the copy the person picked in the importer".utf8)
        let replacement = FileManager.default.temporaryDirectory
            .appendingPathComponent("blob-rollback-\(UUID().uuidString).txt")
        try arriving.write(to: replacement, options: .atomic)
        defer { try? FileManager.default.removeItem(at: replacement) }

        let deskValue = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        let desk = try XCTUnwrap(deskValue)
        do {
            _ = try await store.replaceWorkMaterialPayloadFile(
                id: draft.id,
                from: replacement,
                byteSize: Int64(arriving.count),
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
        XCTAssertEqual(blobs.count, 2, "the row the refusal wrote is gone; the other two stay")
        XCTAssertEqual(Set(blobs.compactMap(\.contentHash)), [hex(mine), hex(peer)])
        let loaded = try await store.loadWorkMaterialPayload(id: draft.id)
        XCTAssertEqual(loaded, mine, "and the card still opens the payload it named")
    }

    // MARK: - Reattach moves a card between the lanes

    func testReattachingASmallFileMovesACardOffTheVaultOntoTheSyncedLane() async throws {
        let store = isolated.make()
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
        XCTAssertEqual(
            reattached.contentHash, hex(bytes),
            "a card arriving on the synced lane names the blob it arrived with"
        )
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
        let store = isolated.make()
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

    /// The retirement that follows a lane change takes the rows the card was
    /// ON, named by object id — never everything under the material id.
    ///
    /// The swap has to commit before its new leaf can be confirmed, and CloudKit
    /// delivers into that window: a blob imported there is another device's
    /// republication whose own material update has not arrived yet. Retiring by
    /// material id would delete it and EXPORT that deletion, so the peer's card
    /// would wait for iCloud for ever — for bytes this device threw away on its
    /// behalf.
    func testABlobImportedDuringTheConfirmationWindowIsNotRetiredWithTheOldOnes()
    async throws {
        let store = isolated.make()
        let payload = Data("the payload the card is leaving behind".utf8)
        let draft = WorkMaterialDraft(
            kind: .file,
            title: "leaving.txt",
            filename: "leaving.txt",
            mimeType: "text/plain",
            payload: payload,
            byteSize: Int64(payload.count)
        )
        let published = try await store.upsertDeskMaterial(draft)
        XCTAssertEqual(published.storageMode, .syncedPayload)

        // A zero-byte file has nothing to sync, so the card moves to the vault
        // and the retirement runs.
        let replacement = try temporaryFile(Data())
        defer { try? FileManager.default.removeItem(at: replacement) }

        // The peer's arrival, delivered between the swap's commit and the proof
        // of its new leaf. Returning nil lets the REAL confirmation run.
        let arriving = Data("what another device just published for this card".utf8)
        let arrivingHash = hex(arriving)
        await store._setPublicationConfirmationHookForTesting { site, materialID, _, _ in
            guard site == .reattach else { return nil }
            await store._insertWorkMaterialBlobRowForTesting(
                materialID: materialID,
                payload: arriving,
                byteSize: Int64(arriving.count),
                contentHash: arrivingHash,
                updatedAt: Date()
            )
            return nil
        }

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
        XCTAssertNil(reattached.contentHash, "a vault card names no blob")

        let blobs = await store._workMaterialBlobRowsForTesting(materialID: draft.id)
        XCTAssertEqual(
            blobs.compactMap(\.contentHash), [arrivingHash],
            """
            The retirement took the rows the swap found and only those. The row \
            that arrived inside the window belongs to a publication on another \
            device; deleting it here would export that deletion.
            """
        )
    }

    /// CloudKit can merge one card into several physical rows, and blob
    /// deletion is scoped to the LOGICAL material id. A reattach that wrote
    /// only the canonical row would therefore leave a duplicate still claiming
    /// `.syncedPayload` while this same save deleted the blobs behind it —
    /// unreadable the moment that row wins the canonical read.
    func testReattachWritesEveryDuplicateRowSoNoneResurrectsTheOldLane() async throws {
        let store = isolated.make()
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

/// Ordered events from inside a publication, so mutual exclusion can be
/// observed rather than argued for.
private actor PublicationTimeline {
    private(set) var events: [String] = []

    func append(_ event: String) {
        events.append(event)
    }
}
