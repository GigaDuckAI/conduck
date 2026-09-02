// SPDX-License-Identifier: Apache-2.0

// ConduckTests
// WorkboardDeskUpsertTests.swift
//
// The one authoritative desk write. Work is a single surface owned by a
// compile-time id, so these cases hold the properties every capture lane
// depends on and no lane can verify for itself: the desk appears lazily at that
// exact id, a replayed capture returns its own card instead of a second one,
// two captures racing to create the desk converge on one board, deleting a card
// never takes the desk with it, and a legacy project row from an older build
// stays beside it untouched. The payload cases fix the repair boundary — bytes
// a row already claims are restored, bytes a row never claimed are refused.
//
// The adoption cases hold the upgrade boundary from both sides: a material a
// pre-desk build parked under a per-capture owner row is re-homed by a
// re-capture that can PROVE it is the same capture, because a refusal makes that
// capture fail on every replay for ever — and a re-capture that cannot prove it
// is refused, because a matching UUID alone would let one card's bytes overwrite
// another's.

import CryptoKit
import XCTest
@testable import Conduck

final class WorkboardDeskUpsertTests: XCTestCase {

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

    /// A card parked under a per-capture owner row a pre-desk build wrote, on
    /// the SYNCED lane so it has a blob an adopting capture could replace.
    /// Reaching that lane under a foreign owner takes two steps: the
    /// arbitrary-owner fixture only ever writes the vault, and a reattach is
    /// what re-decides the lane.
    private func parkSyncedCard(
        in store: ConversationStore,
        id: UUID,
        underOwner ownerID: UUID,
        envelopeID: UUID?,
        kind: WorkMaterialKind = .file,
        payload: Data
    ) async throws {
        _ = try await store.createWorkItem(
            WorkItemDraft(
                id: ownerID,
                captureEnvelopeID: envelopeID,
                content: WorkItemContent(title: "Captured by an older build")
            )
        )
        _ = try await store.addWorkMaterial(
            WorkMaterialDraft(
                id: id,
                kind: kind,
                title: "parked.txt",
                filename: "parked.txt",
                mimeType: "text/plain",
                payload: Data("placeholder".utf8)
            ),
            to: ownerID
        )
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("parked-\(UUID().uuidString).txt")
        try payload.write(to: source, options: .atomic)
        defer { try? FileManager.default.removeItem(at: source) }
        let ownerValue = try await store.fetchWorkItem(id: ownerID)
        let owner = try XCTUnwrap(ownerValue)
        _ = try await store.replaceWorkMaterialPayloadFile(
            id: id,
            from: source,
            byteSize: Int64(payload.count),
            filename: "parked.txt",
            mimeType: "text/plain",
            sourceDevice: "older-build",
            expectedOwnerRevision: WorkboardRevision.value(for: owner.updatedAt)
        )
    }


    // MARK: - Desk identity

    func testFirstCaptureCreatesTheDeskLazilyAtTheFixedIdentity() async throws {
        let store = isolated.make()
        let beforeCapture = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        XCTAssertNil(beforeCapture, "the desk must not exist before anything is captured")

        let material = try await store.upsertDeskMaterial(
            WorkMaterialDraft(kind: .note, title: "Ferry times", textContent: "07:30 and 19:10")
        )

        XCTAssertEqual(material.workItemID, Constants.workboardDeskItemID)
        let items = try await store.fetchWorkItems()
        XCTAssertEqual(items.map(\.id), [Constants.workboardDeskItemID])
        let desk = try XCTUnwrap(items.first)
        XCTAssertEqual(desk.materials.map(\.id), [material.id])
        XCTAssertEqual(desk.content.title, "",
                       "the desk carries no brief; nothing displays a title for it")
        XCTAssertEqual(desk.content.objective, "")
        XCTAssertNil(desk.captureEnvelopeID,
                     "the desk is named by its fixed id, never by a capture envelope")
    }

    func testTwoConcurrentFirstCapturesBothLandOnOneDesk() async throws {
        let store = isolated.make()
        let dropped = WorkMaterialDraft(kind: .note, title: "Dropped", textContent: "from the app")
        let drained = WorkMaterialDraft(kind: .note, title: "Drained", textContent: "from the inbox")

        async let first: WorkMaterialRecord = store.upsertDeskMaterial(dropped)
        async let second: WorkMaterialRecord = store.upsertDeskMaterial(drained)
        let (landedFirst, landedSecond) = try await (first, second)

        XCTAssertEqual(
            Set([landedFirst.workItemID, landedSecond.workItemID]),
            [Constants.workboardDeskItemID]
        )
        let items = try await store.fetchWorkItems()
        XCTAssertEqual(items.count, 1,
                       "two first captures converge on one desk instead of forking the board")
        let desk = try XCTUnwrap(items.first)
        XCTAssertEqual(desk.id, Constants.workboardDeskItemID)
        XCTAssertEqual(Set(desk.materials.map(\.id)), [dropped.id, drained.id],
                       "the projection unions both captures")
        XCTAssertEqual(Set(desk.materials.map(\.sequence)), [0, 1],
                       "the write that owns the transaction ranks the pair rather than colliding it")
    }

    func testDeletingAMaterialLeavesTheDeskStanding() async throws {
        let store = isolated.make()
        let note = WorkMaterialDraft(kind: .note, title: "Scratch", textContent: "delete me")
        let material = try await store.upsertDeskMaterial(note)
        let createdValue = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        let created = try XCTUnwrap(createdValue)

        try await store.deleteWorkMaterial(id: material.id)

        let survivorValue = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        let survivor = try XCTUnwrap(
            survivorValue,
            "removing the last card must not remove the desk"
        )
        XCTAssertTrue(survivor.materials.isEmpty)
        XCTAssertEqual(survivor.createdAt, created.createdAt,
                       "the same desk row survives; it is not recreated")

        let later = try await store.upsertDeskMaterial(
            WorkMaterialDraft(kind: .note, title: "Next", textContent: "after the delete")
        )
        XCTAssertEqual(later.workItemID, Constants.workboardDeskItemID)
        let afterDelete = try await store.fetchWorkItems()
        XCTAssertEqual(afterDelete.count, 1)
    }

    func testDeskCoexistsWithALegacyProjectRow() async throws {
        let store = isolated.make()
        let legacyID = UUID()
        _ = try await store.createWorkItem(
            WorkItemDraft(id: legacyID, content: WorkItemContent(title: "Legacy project"))
        )

        let note = WorkMaterialDraft(kind: .note, title: "Desk note", textContent: "on the desk")
        let material = try await store.upsertDeskMaterial(note)

        XCTAssertEqual(material.workItemID, Constants.workboardDeskItemID)
        let items = try await store.fetchWorkItems()
        XCTAssertEqual(Set(items.map(\.id)), [legacyID, Constants.workboardDeskItemID])
        let legacy = try XCTUnwrap(items.first { $0.id == legacyID })
        XCTAssertEqual(legacy.content.title, "Legacy project",
                       "a row an older build wrote stays exactly as it was")
        XCTAssertTrue(legacy.materials.isEmpty,
                      "a desk capture never migrates itself onto a project row")
        let desk = try XCTUnwrap(items.first { $0.id == Constants.workboardDeskItemID })
        XCTAssertEqual(desk.materials.map(\.id), [note.id])
    }

    // MARK: - Idempotency

    func testReplayingOneCaptureReturnsTheSameCardWithoutASecondRow() async throws {
        let store = isolated.make()
        let payload = Data("harbour schedule".utf8)
        let draft = WorkMaterialDraft(
            kind: .file,
            title: "schedule.txt",
            filename: "schedule.txt",
            mimeType: "text/plain",
            payload: payload,
            byteSize: Int64(payload.count)
        )

        let first = try await store.upsertDeskMaterial(draft)
        let replayed = try await store.upsertDeskMaterial(draft)

        XCTAssertEqual(replayed.id, first.id)
        XCTAssertEqual(replayed.updatedAt, first.updatedAt,
                       "a replay of a card with readable bytes rewrites nothing")
        let rows = await store._workMaterialRowsForTesting(id: draft.id)
        XCTAssertEqual(rows.count, 1, "the replay must not add a physical row")
        let deskValue = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        let desk = try XCTUnwrap(deskValue)
        XCTAssertEqual(desk.materials.map(\.id), [draft.id])
        let storedPayload = try await store.loadWorkMaterialPayload(id: draft.id)
        XCTAssertEqual(storedPayload, payload)
    }

    func testAFailedFirstCaptureLeavesNoDeskRow() async throws {
        let store = isolated.make()
        let missingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-desk-capture-\(UUID().uuidString).pdf")

        do {
            _ = try await store.upsertDeskMaterial(
                WorkMaterialDraft(
                    kind: .file,
                    title: "missing.pdf",
                    filename: "missing.pdf",
                    mimeType: "application/pdf",
                    byteSize: -1
                ),
                sourceFileURL: missingURL,
                sourceFileByteSize: -1
            )
            XCTFail("an unreadable source must fail before anything is published")
        } catch {
            // Expected: preparation never reaches the write transaction.
        }

        let desk = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        XCTAssertNil(desk, "a failed first capture must not leave a half-created desk behind")
        let reclaimed = try await store.reconcileWorkAssetVault()
        XCTAssertEqual(reclaimed, 0, "the failed capture must clean its own staged bytes")
    }

    // MARK: - Compare-and-swap

    func testOwnerRevisionIsRefusedWhenStaleAndWhenTheDeskDoesNotExistYet() async throws {
        let store = isolated.make()
        let first = WorkMaterialDraft(kind: .note, title: "One", textContent: "first")

        do {
            _ = try await store.upsertDeskMaterial(first, expectedOwnerRevision: 7)
            XCTFail("a token for a desk that does not exist cannot be honestly compared")
        } catch WorkboardStoreError.staleRevision {
            // Expected.
        }
        let refusedDesk = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        XCTAssertNil(refusedDesk,
                     "the refused compare-and-swap must not create the desk")

        _ = try await store.upsertDeskMaterial(first)
        let deskValue = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        let desk = try XCTUnwrap(deskValue)
        let revision = WorkboardRevision.value(for: desk.updatedAt)

        _ = try await store.upsertDeskMaterial(
            WorkMaterialDraft(kind: .note, title: "Two", textContent: "second"),
            expectedOwnerRevision: revision
        )
        do {
            _ = try await store.upsertDeskMaterial(
                WorkMaterialDraft(kind: .note, title: "Three", textContent: "third"),
                expectedOwnerRevision: revision
            )
            XCTFail("a revision the board has already moved past must be refused")
        } catch WorkboardStoreError.staleRevision {
            // Expected.
        }

        let finalValue = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        let final = try XCTUnwrap(finalValue)
        XCTAssertEqual(final.materials.count, 2,
                       "the refused write leaves the desk exactly as the approved one left it")
    }

    // MARK: - Payload repair

    /// A capture within the sync ceiling takes the synced lane, so the payload a
    /// desk card can lose is its blob — the state the payload store's loss and a
    /// blob-after-material CloudKit import both produce. The desk's own property
    /// is that the repair stays one card: a replay carrying the bytes restores
    /// them in place rather than publishing a second row beside the pending one.
    func testReplayRepairsACardWhoseSyncedBytesAreGone() async throws {
        let store = isolated.make()
        let payload = Data("recovered rate card".utf8)
        let draft = WorkMaterialDraft(
            kind: .file,
            title: "rates.txt",
            filename: "rates.txt",
            mimeType: "text/plain",
            payload: payload,
            byteSize: Int64(payload.count)
        )

        let published = try await store.upsertDeskMaterial(draft)
        XCTAssertEqual(published.storageMode, .syncedPayload)
        XCTAssertEqual(published.availability, .synced)
        XCTAssertNil(published.localVaultKey,
                     "the synced lane stages nothing into the device-local vault")
        await store._deleteWorkMaterialBlobRowsForTesting(materialID: draft.id)

        let damagedValue = try await store
            .fetchWorkItem(id: Constants.workboardDeskItemID)?.materials.first
        let damaged = try XCTUnwrap(damagedValue)
        XCTAssertEqual(damaged.availability, .syncedPending)

        let repaired = try await store.upsertDeskMaterial(draft)

        XCTAssertEqual(repaired.id, draft.id)
        XCTAssertEqual(repaired.availability, .synced,
                       "a replay that still carries the bytes restores them")
        let repairedPayload = try await store.loadWorkMaterialPayload(id: draft.id)
        XCTAssertEqual(repairedPayload, payload)
        let rows = await store._workMaterialRowsForTesting(id: draft.id)
        XCTAssertEqual(rows.count, 1, "repair restores bytes; it never adds a card")
        let deskValue = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        let desk = try XCTUnwrap(deskValue)
        XCTAssertEqual(desk.materials.map(\.id), [draft.id])
    }

    func testRepairBytesOfferedToACardThatClaimsNoneAreRefused() async throws {
        let store = isolated.make()
        let note = WorkMaterialDraft(
            kind: .note,
            title: "Referenced only",
            textContent: "the original file stayed on the gateway",
            storageMode: .metadataOnly
        )
        let published = try await store.upsertDeskMaterial(note)
        XCTAssertEqual(published.storageMode, .metadataOnly)

        let replayed = try await store.upsertDeskMaterial(
            note,
            repairPayload: Data("late bytes".utf8)
        )

        XCTAssertEqual(replayed.storageMode, .metadataOnly,
                       "giving a metadata-only card bytes is a reattach, not a repair")
        XCTAssertEqual(replayed.availability, .metadataOnly)
        let refusedPayload = try await store.loadWorkMaterialPayload(id: note.id)
        XCTAssertNil(refusedPayload)
        let reclaimed = try await store.reconcileWorkAssetVault()
        XCTAssertEqual(reclaimed, 0, "refused bytes are never staged in the first place")
    }

    // MARK: - Legacy-owner adoption

    /// A build before the single desk parked a captured turn, its attachments
    /// and a partially drained envelope's entries under a per-capture owner
    /// row, and those rows are still on the devices that ran it. Refusing the
    /// id would make that capture fail on every replay for ever — the drainer
    /// retries the same envelope and the chat banner reports a card it can
    /// never publish — so an explicit re-capture re-homes the physical rows.
    /// The owner row they came from is a valid CloudKit record and stays.
    func testAMaterialUnderALegacyOwnerIsAdoptedByAnExplicitRecapture() async throws {
        let store = isolated.make()
        let legacyID = UUID()
        _ = try await store.createWorkItem(
            WorkItemDraft(
                id: legacyID,
                captureEnvelopeID: legacyID,
                content: WorkItemContent(title: "Captured by an older build")
            )
        )
        let sharedID = UUID()
        let parked = try await store.addWorkMaterial(
            WorkMaterialDraft(
                id: sharedID,
                kind: .note,
                title: "Owned elsewhere",
                textContent: "x"
            ),
            to: legacyID
        )

        let adopted = try await store.upsertDeskMaterial(
            WorkMaterialDraft(id: sharedID, kind: .note, title: "Same id", textContent: "y"),
            legacyProvenance: .captureEnvelope(legacyID)
        )

        XCTAssertEqual(adopted.workItemID, Constants.workboardDeskItemID)
        XCTAssertEqual(adopted.title, parked.title,
                       "adoption re-homes the card; it never rewrites what the card says")
        let rows = await store._workMaterialRowsForTesting(id: sharedID)
        XCTAssertEqual(rows.count, 1, "the card moves; it is never copied")
        XCTAssertEqual(Set(rows.compactMap(\.workItemID)), [Constants.workboardDeskItemID],
                       "every physical row of the card moves, or a merge undoes the adoption")

        let deskValue = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        let desk = try XCTUnwrap(deskValue)
        XCTAssertEqual(desk.materials.map(\.id), [sharedID])
        let legacyValue = try await store.fetchWorkItem(id: legacyID)
        let legacy = try XCTUnwrap(
            legacyValue,
            "the owner row an older build wrote is never deleted — it is a valid CloudKit record"
        )
        XCTAssertEqual(legacy.content.title, "Captured by an older build")
        XCTAssertTrue(legacy.materials.isEmpty)

        let replayed = try await store.upsertDeskMaterial(
            WorkMaterialDraft(id: sharedID, kind: .note, title: "Same id", textContent: "y"),
            legacyProvenance: .captureEnvelope(legacyID)
        )
        XCTAssertEqual(replayed.updatedAt, adopted.updatedAt,
                       "the capture after the adoption is an ordinary no-op")
        let settledRows = await store._workMaterialRowsForTesting(id: sharedID)
        XCTAssertEqual(settledRows.count, 1)
    }

    /// The upgrade case the drainer meets: an envelope a pre-desk build drained
    /// halfway into an item of its own. Replaying it must land both entries on
    /// the desk — the drained one adopted, the undrained one published — so the
    /// queue copy can finally be acknowledged.
    func testAPartiallyDrainedPreRewriteEnvelopeReplaysCleanOntoTheDesk() async throws {
        let store = isolated.make()
        let envelopeID = UUID()
        let legacy = try await store.createWorkItem(
            WorkItemDraft(
                captureEnvelopeID: envelopeID,
                content: WorkItemContent(title: "Shared from Safari")
            )
        )
        let noteID = UUID()
        let fileID = UUID()
        let payload = Data("the half the older build managed to copy".utf8)
        _ = try await store.addWorkMaterial(
            WorkMaterialDraft(id: noteID, kind: .note, title: "Shared text", textContent: "the link"),
            to: legacy.id
        )
        _ = try await store.addWorkMaterial(
            WorkMaterialDraft(
                id: fileID,
                kind: .file,
                title: "receipt.txt",
                filename: "receipt.txt",
                mimeType: "text/plain",
                payload: payload
            ),
            to: legacy.id
        )
        // The entry the interrupted drain never reached.
        let undrainedID = UUID()

        _ = try await store.upsertDeskMaterial(
            WorkMaterialDraft(id: noteID, kind: .note, title: "Shared text", textContent: "the link"),
            legacyProvenance: .captureEnvelope(envelopeID)
        )
        _ = try await store.upsertDeskMaterial(
            WorkMaterialDraft(
                id: fileID,
                kind: .file,
                title: "receipt.txt",
                filename: "receipt.txt",
                mimeType: "text/plain",
                payload: payload
            ),
            legacyProvenance: .captureEnvelope(envelopeID)
        )
        _ = try await store.upsertDeskMaterial(
            WorkMaterialDraft(id: undrainedID, kind: .note, title: "Web page", textContent: "https://example.org"),
            legacyProvenance: .captureEnvelope(envelopeID)
        )

        let deskValue = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        let desk = try XCTUnwrap(deskValue)
        XCTAssertEqual(desk.materials.map(\.id), [noteID, fileID, undrainedID],
                       "the adopted entries keep the order the replay publishes them in")
        XCTAssertEqual(desk.materials.map(\.sequence), [0, 1, 2])
        let carried = try await store.loadWorkMaterialPayload(id: fileID)
        XCTAssertEqual(carried, payload, "an adopted card keeps the bytes it already had")

        let legacyValue = try await store.fetchWorkItem(id: legacy.id)
        let survivor = try XCTUnwrap(legacyValue)
        XCTAssertEqual(survivor.captureEnvelopeID, envelopeID)
        XCTAssertTrue(survivor.materials.isEmpty)
    }

    /// The OTHER pre-desk drain, and the one a capture-envelope id cannot
    /// account for: an envelope the person aimed at a Work item they had
    /// already made. That drain appended straight onto the chosen item and
    /// wrote nothing about the envelope on its owner row, so the envelope id
    /// matches nothing there — and a replay carrying only the envelope is
    /// refused for ever, which is the failure adoption exists to prevent.
    ///
    /// What licenses it is the envelope's own `targetWorkItemID`, and only for
    /// the owner it names. The refusal half is asserted in the same case, from
    /// the same fixture: the replay that does not carry the target — which is
    /// every capture that mints its own ids, and was the only shape this
    /// provenance had — still cannot move these rows, and neither can one
    /// naming a different item.
    func testAPartiallyDrainedTargetedPreRewriteEnvelopeReplaysCleanOntoTheDesk() async throws {
        let store = isolated.make()
        let envelopeID = UUID()
        // The item the person picked in the share sheet: their own, made
        // before this envelope existed, carrying no capture identity at all.
        let target = try await store.createWorkItem(
            WorkItemDraft(content: WorkItemContent(title: "Trip receipts"))
        )
        XCTAssertNil(target.captureEnvelopeID,
                     "the shape under test is an owner row that names no capture")

        let noteID = UUID()
        let fileID = UUID()
        let payload = Data("the half the older build managed to copy".utf8)
        _ = try await store.addWorkMaterial(
            WorkMaterialDraft(id: noteID, kind: .note, title: "Share note", textContent: "the link"),
            to: target.id
        )
        _ = try await store.addWorkMaterial(
            WorkMaterialDraft(
                id: fileID,
                kind: .file,
                title: "receipt.txt",
                filename: "receipt.txt",
                mimeType: "text/plain",
                payload: payload
            ),
            to: target.id
        )
        // The entry the interrupted drain never reached.
        let undrainedID = UUID()

        func noteDraft() -> WorkMaterialDraft {
            WorkMaterialDraft(id: noteID, kind: .note, title: "Share note", textContent: "the link")
        }

        // Without the target the replay is refused — the old shape of this
        // provenance, and the state the finding describes: a capture that can
        // never be acknowledged.
        do {
            _ = try await store.upsertDeskMaterial(
                noteDraft(),
                legacyProvenance: .captureEnvelope(envelopeID)
            )
            XCTFail("an envelope id alone accounts for nothing on an item the person chose")
        } catch WorkboardStoreError.invalidMaterialOwner {
            // Expected.
        }
        // Nor does a target that is not the one this envelope named.
        do {
            _ = try await store.upsertDeskMaterial(
                noteDraft(),
                legacyProvenance: .captureEnvelope(envelopeID, legacyTargetWorkItemID: UUID())
            )
            XCTFail("a target the envelope did not name licenses nothing")
        } catch WorkboardStoreError.invalidMaterialOwner {
            // Expected.
        }
        let stillParked = await store._workMaterialRowsForTesting(id: noteID)
        XCTAssertEqual(Set(stillParked.compactMap(\.workItemID)), [target.id],
                       "a refused adoption leaves the card exactly where it was")

        let provenance = WorkMaterialLegacyProvenance.captureEnvelope(
            envelopeID,
            legacyTargetWorkItemID: target.id
        )
        _ = try await store.upsertDeskMaterial(noteDraft(), legacyProvenance: provenance)
        _ = try await store.upsertDeskMaterial(
            WorkMaterialDraft(
                id: fileID,
                kind: .file,
                title: "receipt.txt",
                filename: "receipt.txt",
                mimeType: "text/plain",
                payload: payload
            ),
            legacyProvenance: provenance
        )
        _ = try await store.upsertDeskMaterial(
            WorkMaterialDraft(
                id: undrainedID,
                kind: .note,
                title: "Web page",
                textContent: "https://example.org"
            ),
            legacyProvenance: provenance
        )

        let deskValue = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        let desk = try XCTUnwrap(deskValue)
        XCTAssertEqual(desk.materials.map(\.id), [noteID, fileID, undrainedID],
                       "the drained entries are adopted and the undrained one is published")
        let carried = try await store.loadWorkMaterialPayload(id: fileID)
        XCTAssertEqual(carried, payload, "an adopted card keeps the bytes it already had")

        let survivorValue = try await store.fetchWorkItem(id: target.id)
        let survivor = try XCTUnwrap(
            survivorValue,
            "the item the person made is a valid CloudKit record and is never deleted"
        )
        XCTAssertEqual(survivor.content.title, "Trip receipts")
        XCTAssertTrue(survivor.materials.isEmpty)
    }

    /// The other half of adoption, and the one that decides what a matching
    /// UUID is worth: nothing, on its own.
    ///
    /// A capture that names no capture of its own — every lane that mints its
    /// ids per attempt — and one that names a DIFFERENT capture both meet the
    /// same refusal, and the card they collided with keeps its owner, its bytes
    /// and its blob. Without that gate the second capture would re-home a card
    /// it has nothing to do with and, carrying bytes, replace the payload
    /// behind it.
    func testAMaterialIdParkedUnderAnUnrelatedOwnerIsRefusedRatherThanAdopted() async throws {
        let store = isolated.make()
        let sharedID = UUID()
        let legacyOwnerID = UUID()
        let theirEnvelope = UUID()
        let theirBytes = Data("the payload the parked card actually holds".utf8)
        try await parkSyncedCard(
            in: store,
            id: sharedID,
            underOwner: legacyOwnerID,
            envelopeID: theirEnvelope,
            payload: theirBytes
        )

        let myBytes = Data("bytes from a capture that has nothing to do with it".utf8)
        func collidingDraft() -> WorkMaterialDraft {
            WorkMaterialDraft(
                id: sharedID,
                kind: .file,
                title: "mine.txt",
                filename: "mine.txt",
                mimeType: "text/plain",
                payload: myBytes,
                byteSize: Int64(myBytes.count)
            )
        }

        do {
            _ = try await store.upsertDeskMaterial(collidingDraft())
            XCTFail("a capture that names no provenance has no history to adopt")
        } catch WorkboardStoreError.invalidMaterialOwner {
            // Expected.
        }
        do {
            _ = try await store.upsertDeskMaterial(
                collidingDraft(),
                legacyProvenance: .captureEnvelope(UUID())
            )
            XCTFail("a capture naming a different envelope must not adopt this card")
        } catch WorkboardStoreError.invalidMaterialOwner {
            // Expected.
        }

        let rows = await store._workMaterialRowsForTesting(id: sharedID)
        XCTAssertEqual(Set(rows.compactMap(\.workItemID)), [legacyOwnerID],
                       "the refused capture must not move a card it cannot account for")
        let blobs = await store._workMaterialBlobRowsForTesting(materialID: sharedID)
        XCTAssertEqual(blobs.count, 1)
        XCTAssertEqual(blobs.first?.contentHash, hex(theirBytes),
                       "a refused adoption must not replace the payload it collided with")
        let loaded = try await store.loadWorkMaterialPayload(id: sharedID)
        XCTAssertEqual(loaded, theirBytes)
        let desk = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        XCTAssertTrue(desk?.materials.isEmpty ?? true, "nothing reached the desk")

        // The capture that CAN account for it still adopts, so the refusal is
        // about provenance and not about adoption having been switched off.
        let adopted = try await store.upsertDeskMaterial(
            collidingDraft(),
            legacyProvenance: .captureEnvelope(theirEnvelope)
        )
        XCTAssertEqual(adopted.workItemID, Constants.workboardDeskItemID)
    }

    /// CloudKit can import a material row before the item that owns it. An
    /// owner row that cannot be read is therefore not evidence of anything, and
    /// adopting on the strength of a missing row is exactly how a capture would
    /// move a card whose real history has not arrived yet. The capture is
    /// refused; a later replay adopts once the owner lands.
    func testAdoptionIsRefusedWhileTheLegacyOwnerCannotAccountForTheCard() async throws {
        let store = isolated.make()
        let sharedID = UUID()
        let ownerID = UUID()
        // An owner row with no capture identity on it at all — the shape a row
        // whose `captureEnvelopeID` has not imported yet presents.
        _ = try await store.createWorkItem(
            WorkItemDraft(id: ownerID, content: WorkItemContent(title: "Half-arrived"))
        )
        _ = try await store.addWorkMaterial(
            WorkMaterialDraft(id: sharedID, kind: .note, title: "Parked", textContent: "x"),
            to: ownerID
        )

        do {
            _ = try await store.upsertDeskMaterial(
                WorkMaterialDraft(id: sharedID, kind: .note, title: "Mine", textContent: "y"),
                legacyProvenance: .captureEnvelope(UUID())
            )
            XCTFail("an owner row that names no capture cannot license an adoption")
        } catch WorkboardStoreError.invalidMaterialOwner {
            // Expected.
        }

        let rows = await store._workMaterialRowsForTesting(id: sharedID)
        XCTAssertEqual(Set(rows.compactMap(\.workItemID)), [ownerID])
    }

    /// Two different materials sharing one UUID is what an id collision looks
    /// like from inside the desk write. Re-homing across kinds would hand this
    /// capture's bytes to whatever the other card was, so the kinds have to
    /// agree even when the provenance does.
    func testAdoptionIsRefusedWhenTheParkedRowIsADifferentKindOfCard() async throws {
        let store = isolated.make()
        let sharedID = UUID()
        let ownerID = UUID()
        let envelopeID = UUID()
        _ = try await store.createWorkItem(
            WorkItemDraft(
                id: ownerID,
                captureEnvelopeID: envelopeID,
                content: WorkItemContent(title: "Captured by an older build")
            )
        )
        _ = try await store.addWorkMaterial(
            WorkMaterialDraft(
                id: sharedID,
                kind: .file,
                title: "receipt.txt",
                filename: "receipt.txt",
                mimeType: "text/plain",
                payload: Data("a file the older build copied".utf8)
            ),
            to: ownerID
        )

        do {
            _ = try await store.upsertDeskMaterial(
                WorkMaterialDraft(id: sharedID, kind: .note, title: "A note", textContent: "y"),
                legacyProvenance: .captureEnvelope(envelopeID)
            )
            XCTFail("a note must not adopt the rows of a file that shares its id")
        } catch WorkboardStoreError.invalidMaterialOwner {
            // Expected.
        }

        let rows = await store._workMaterialRowsForTesting(id: sharedID)
        XCTAssertEqual(Set(rows.compactMap(\.workItemID)), [ownerID])
        let loaded = try await store.loadWorkMaterialPayload(id: sharedID)
        XCTAssertEqual(loaded, Data("a file the older build copied".utf8))
    }
}
