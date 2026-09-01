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

import XCTest
@testable import Conduck

final class WorkboardDeskUpsertTests: XCTestCase {

    // MARK: - Desk identity

    func testFirstCaptureCreatesTheDeskLazilyAtTheFixedIdentity() async throws {
        let store = ConversationStore(inMemory: true)
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
        let store = ConversationStore(inMemory: true)
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
        let store = ConversationStore(inMemory: true)
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
        let store = ConversationStore(inMemory: true)
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
        let store = ConversationStore(inMemory: true)
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
        let store = ConversationStore(inMemory: true)
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
        let store = ConversationStore(inMemory: true)
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
        let store = ConversationStore(inMemory: true)
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
        let store = ConversationStore(inMemory: true)
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

    func testAMaterialIdOwnedByAnotherItemIsRefusedRatherThanMoved() async throws {
        let store = ConversationStore(inMemory: true)
        let projectID = UUID()
        _ = try await store.createWorkItem(
            WorkItemDraft(id: projectID, content: WorkItemContent(title: "Legacy project"))
        )
        let sharedID = UUID()
        _ = try await store.addWorkMaterial(
            WorkMaterialDraft(id: sharedID, kind: .note, title: "Owned elsewhere", textContent: "x"),
            to: projectID
        )

        do {
            _ = try await store.upsertDeskMaterial(
                WorkMaterialDraft(id: sharedID, kind: .note, title: "Same id", textContent: "y")
            )
            XCTFail("a material id that already belongs to another row must not be reparented")
        } catch WorkboardStoreError.invalidMaterialOwner {
            // Expected.
        }

        let projectValue = try await store.fetchWorkItem(id: projectID)
        let project = try XCTUnwrap(projectValue)
        XCTAssertEqual(project.materials.map(\.id), [sharedID])
        XCTAssertEqual(project.materials.first?.title, "Owned elsewhere")
        let deskValue = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        XCTAssertNil(deskValue, "the refused write leaves no desk row behind either")
    }
}
