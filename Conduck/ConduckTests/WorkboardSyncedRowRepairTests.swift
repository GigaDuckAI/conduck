// SPDX-License-Identifier: Apache-2.0

// ConduckTests
// WorkboardSyncedRowRepairTests.swift
//
// What a synced REPAIR owes the physical rows behind one card, and what it owes
// the payload store behind them.
//
// CloudKit cannot enforce a Core Data uniqueness constraint, so one logical
// material can arrive as several physical rows — and two offline devices that
// published different bytes under one id leave rows naming DIFFERENT blobs. Only
// one of those blobs is necessarily here. A replay carrying the bytes that ARE
// here has to bring every row back onto them, because the row naming the absent
// blob decides what the card says the moment it wins the canonical read, and it
// wins whenever it is the newer one.
//
// The trap this class exists for is that the repair's own evidence says nothing
// about that. Inserting a blob and retiring a superseded one are facts about the
// payload STORE; a replay whose bytes are already present inserts nothing, and a
// blob that never arrived cannot be retired, so a repair keyed on either would
// find nothing to do and leave the disagreement standing on every replay for
// ever. What the ROWS say is the only thing that answers it.
//
// The last case is the other half: what the payload store is allowed to
// accumulate. Duplicate blob rows are an accepted state with a bound that is
// persistence rather than arithmetic, and it is written down here because a
// comment claiming "two rows" would be quietly wrong after the third crash.

import CryptoKit
import XCTest
@testable import Conduck

@MainActor
final class WorkboardSyncedRowRepairTests: XCTestCase {

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

    private func syncedDraft(
        id: UUID = UUID(),
        payload: Data,
        name: String
    ) -> WorkMaterialDraft {
        WorkMaterialDraft(
            id: id,
            kind: .file,
            title: name,
            filename: name,
            mimeType: "application/octet-stream",
            payload: payload,
            byteSize: Int64(payload.count)
        )
    }

    private func deskMaterials(
        _ store: ConversationStore
    ) async throws -> [UUID: WorkMaterialRecord] {
        let materials = try await store.fetchWorkItem(
            id: Constants.workboardDeskItemID
        )?.materials ?? []
        return Dictionary(uniqueKeysWithValues: materials.map { ($0.id, $0) })
    }

    // MARK: - A merge that leaves rows naming different blobs

    /// A replay carrying the bytes this device HAS repairs a card whose newest
    /// physical row names bytes it has not.
    ///
    /// The state is an ordinary merge: another device published different bytes
    /// under this material id, its row arrived, its blob did not. Nothing about
    /// that is damage — but the row is newer, so it is the one every canonical
    /// read picks, and the card it produces waits for iCloud with a payload
    /// sitting right there.
    ///
    /// The replay cannot notice it through the payload store. Its own bytes are
    /// already present, so the blob publication adopts and inserts nothing; the
    /// blob the other row names is ABSENT rather than superseded, so the
    /// retirement pass deletes nothing. A repair that asked either of them
    /// whether there was work to do would answer no on this replay and on every
    /// replay after it.
    func testAReplayRepairsARowNamingABlobThatNeverArrived() async throws {
        let store = isolated.make()
        let bytes = Data("the contract everyone kept editing".utf8)
        let draft = syncedDraft(payload: bytes, name: "contract.pdf")

        let published = try await store.upsertDeskMaterial(draft)
        XCTAssertEqual(published.availability, .synced)
        XCTAssertEqual(published.contentHash, hex(bytes))

        // The merge. A row naming a blob that is not here, stamped newer than
        // the row this device wrote, which is what makes it canonical.
        let strandedHash = hex(Data("what the other device published".utf8))
        await store._duplicateWorkMaterialRowForTesting(
            id: draft.id,
            updatedAt: published.updatedAt.addingTimeInterval(60),
            contentHash: strandedHash,
            byteSize: 4_096
        )

        let broken = try await deskMaterials(store)
        XCTAssertEqual(broken.count, 1, "duplicated rows are one card, never two")
        XCTAssertEqual(
            broken[draft.id]?.availability, .syncedPending,
            "the canonical row names a blob that is not here, so the card waits"
        )
        let unreadable = try await store.loadWorkMaterialPayload(id: draft.id)
        XCTAssertNil(
            unreadable,
            "and it will not answer with bytes its own row does not name"
        )

        let repaired = try await store.upsertDeskMaterial(draft)

        XCTAssertEqual(
            repaired.availability, .synced,
            "a replay carrying the bytes that are here must end the wait"
        )
        XCTAssertEqual(repaired.contentHash, hex(bytes))

        let rows = await store._workMaterialRowsForTesting(id: draft.id)
        XCTAssertEqual(rows.count, 2, "the merged row is normalised, never deleted")
        XCTAssertEqual(
            Set(rows.compactMap(\.contentHash)), [hex(bytes)],
            "EVERY physical row names the bytes the card holds, or the next merge picks one that points at nothing"
        )
        XCTAssertEqual(
            Set(rows.compactMap(\.byteSize)), [Int64(bytes.count)],
            "the pairing is both halves; a row keeping the other size names the blob no better"
        )
        XCTAssertEqual(
            Set(rows.compactMap(\.storageMode)),
            [WorkMaterialStorageMode.syncedPayload.rawValue],
            "and every row claims the lane the bytes are actually on"
        )

        let restored = try await store.loadWorkMaterialPayload(id: draft.id)
        XCTAssertEqual(restored, bytes)
        let board = try await deskMaterials(store)
        XCTAssertEqual(board[draft.id]?.availability, .synced)
        XCTAssertEqual(
            WorkboardLiveRepository.presentationAvailability(
                try XCTUnwrap(board[draft.id])
            ),
            .available,
            "the card opens again, which is the whole point of repairing it"
        )

        let blobs = await store._workMaterialBlobRowsForTesting(materialID: draft.id)
        XCTAssertEqual(
            blobs.count, 1,
            "the replay adopted the blob its own row already named rather than writing a second"
        )
    }

    /// The control that keeps the repair from becoming a write on every replay.
    ///
    /// A drainer replays the same envelope whenever a claim is retried, so a
    /// repair that rewrote agreeing rows would stamp `updatedAt` on both of them
    /// each time and export a CloudKit change for a card nothing happened to.
    /// Disagreement is what licenses the write; equality licenses nothing.
    func testAnIdenticalReplayOntoAgreeingRowsWritesNothing() async throws {
        let store = isolated.make()
        let bytes = Data("the invoice nobody argued about".utf8)
        let draft = syncedDraft(payload: bytes, name: "invoice.pdf")

        let published = try await store.upsertDeskMaterial(draft)
        await store._duplicateWorkMaterialRowForTesting(
            id: draft.id,
            updatedAt: published.updatedAt.addingTimeInterval(60)
        )
        let before = await store._workMaterialRowsForTesting(id: draft.id)
        XCTAssertEqual(before.count, 2)
        XCTAssertEqual(Set(before.compactMap(\.contentHash)), [hex(bytes)])

        _ = try await store.upsertDeskMaterial(draft)

        let after = await store._workMaterialRowsForTesting(id: draft.id)
        XCTAssertEqual(after.count, 2)
        XCTAssertEqual(
            Set(after.compactMap(\.updatedAt)), Set(before.compactMap(\.updatedAt)),
            "rows that already name these bytes are left exactly as they are"
        )
        let blobs = await store._workMaterialBlobRowsForTesting(materialID: draft.id)
        XCTAssertEqual(
            blobs.count, 1,
            "and the payload store is untouched too"
        )
    }

    // MARK: - What the payload store is allowed to accumulate

    /// The accurate bound on duplicate blob rows, measured rather than asserted
    /// in a comment.
    ///
    /// It is NOT a count. A process that dies between the blob save and the
    /// material save leaves its row behind — there is no card yet to license
    /// adoption, so the attempt after it writes another one, and so does the
    /// attempt after that. Nothing sweeps them: a pass over "blobs no card
    /// names" cannot tell this device's stranded attempt from a peer's blob that
    /// CloudKit imported ahead of the material naming it. What clears them is a
    /// publication putting DIFFERENT bytes on the card, and paired deletion when
    /// the card goes.
    ///
    /// This is a characterisation case, not a counterfactual: it fails if
    /// someone adds the sweep, changes adoption, or narrows the retirement — the
    /// three ways the sentence at `publishWorkMaterialBlob` could stop being
    /// true.
    func testStrandedBlobsAccumulatePerAttemptUntilDifferentBytesRetireThem() async throws {
        let store = isolated.make()
        let bytes = Data("the recording that kept dying at the same step".utf8)
        let draft = syncedDraft(payload: bytes, name: "take.bin")

        for _ in 0..<3 {
            try await store._publishDeskMaterialBlobOnlyForTesting(draft)
        }

        let stranded = await store._workMaterialBlobRowsForTesting(materialID: draft.id)
        XCTAssertEqual(
            stranded.count, 3,
            "one row per interrupted attempt — no card exists yet to license adopting the last one"
        )
        XCTAssertEqual(Set(stranded.compactMap(\.contentHash)), [hex(bytes)])

        let publishedValue = try await store.upsertDeskMaterial(draft)
        XCTAssertEqual(publishedValue.availability, .synced)
        let afterCard = await store._workMaterialBlobRowsForTesting(materialID: draft.id)
        XCTAssertEqual(
            afterCard.count, 4,
            "the attempt that finally committed wrote its own row too: it could not prove any card named those bytes"
        )
        let readBack = try await store.loadWorkMaterialPayload(id: draft.id)
        XCTAssertEqual(readBack, bytes)

        _ = try await store.upsertDeskMaterial(draft)
        let afterReplay = await store._workMaterialBlobRowsForTesting(materialID: draft.id)
        XCTAssertEqual(
            afterReplay.count, 4,
            "a replay now finds a card naming these bytes, so it adopts — and it retires none of the strays either"
        )

        let replacement = Data("the take that was finally used".utf8)
        let moved = try await store.upsertDeskMaterial(
            syncedDraft(id: draft.id, payload: replacement, name: "take.bin")
        )

        XCTAssertEqual(moved.contentHash, hex(replacement))
        let afterReplacement = await store._workMaterialBlobRowsForTesting(materialID: draft.id)
        XCTAssertEqual(
            afterReplacement.count, 1,
            "different bytes on the card are what retires them, in the save that repoints it"
        )
        XCTAssertEqual(afterReplacement.first?.contentHash, hex(replacement))
        let replacementBytes = try await store.loadWorkMaterialPayload(id: draft.id)
        XCTAssertEqual(replacementBytes, replacement)
    }
}
