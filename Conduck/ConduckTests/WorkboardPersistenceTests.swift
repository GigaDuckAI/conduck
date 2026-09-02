// SPDX-License-Identifier: Apache-2.0

// ConduckTests
// WorkboardPersistenceTests.swift
//
// End-to-end in-memory Core Data coverage for Work capture idempotency,
// material privacy, board arrangement (card size and material order), and the
// erase-everything boundary that keeps collected material while Chat goes.

import XCTest
@testable import Conduck

final class WorkboardPersistenceTests: XCTestCase {

    /// Every store here mints a vault directory of its own that nothing else
    /// removes; the fixture empties them when the class is done.
    private let isolated = IsolatedWorkStores()

    override func tearDown() async throws {
        await isolated.cleanUp()
        try await super.tearDown()
    }

    func testCaptureIdempotencyAndLocalMaterialPrivacy() async throws {
        let store = isolated.make()
        let captureID = UUID()
        let content = WorkItemContent(
            title: "Quarterly carrier review",
            objective: "Choose the best courier",
            context: "Estonian warehouse",
            desiredOutcome: "A recommendation with tradeoffs",
            constraints: "Primary sources only"
        )
        let first = try await store.createWorkItem(
            WorkItemDraft(captureEnvelopeID: captureID, content: content)
        )
        let repeated = try await store.createWorkItem(
            WorkItemDraft(id: UUID(), captureEnvelopeID: captureID, content: .init(title: "duplicate"))
        )
        XCTAssertEqual(repeated.id, first.id)
        XCTAssertEqual(repeated.content.title, content.title)

        let payload = Data("zone rates".utf8)
        let material = try await store.addWorkMaterial(
            WorkMaterialDraft(
                kind: .file,
                title: "DHL rate card",
                caption: "EU parcel pricing",
                textContent: "Zone based express service",
                filename: "rates.txt",
                mimeType: "text/plain",
                payload: payload
            ),
            to: first.id
        )
        XCTAssertEqual(material.availability, .availableLocally)
        XCTAssertEqual(material.storageMode, .localVault,
                       "the non-desk owner mint stays on the device-local lane; "
                       + "only a desk capture asks WorkMaterialStoragePolicy")
        XCTAssertNil(material.textContent,
                     "an extract of a local file must not enter the mirrored material row")
        let loadedPayload = try await store.loadWorkMaterialPayload(id: material.id)
        XCTAssertEqual(loadedPayload, payload)
    }

    /// Erasing every conversation is a Chat operation. Collected material is the
    /// person's own desk and outlives it.
    func testDeleteAllConversationsPreservesWorkMaterials() async throws {
        let store = isolated.make()
        let conversation = try await store.createConversation(backend: "test")
        _ = try await store.appendMessage(
            role: "user",
            text: "An ordinary chat turn",
            conversationID: conversation.id,
            sourceDevice: "phone"
        )
        let item = try await store.createWorkItem(
            WorkItemDraft(content: WorkItemContent(
                title: "Keep this brief",
                objective: "Preserve collected work"
            ))
        )
        let material = try await store.addWorkMaterial(
            WorkMaterialDraft(
                kind: .note,
                title: "Decision context",
                textContent: "Private note"
            ),
            to: item.id
        )

        try await store.deleteAll()

        let removedConversation = try await store.fetchConversation(id: conversation.id)
        XCTAssertNil(removedConversation)
        let preservedValue = try await store.fetchWorkItem(id: item.id)
        let preserved = try XCTUnwrap(preservedValue)
        XCTAssertEqual(preserved.materials.map(\.id), [material.id])
    }

    // MARK: - Board arrangement

    func testCardSizeRoundTripsAndAnUnknownStoredSizeReadsAsStandard() async throws {
        let store = isolated.make()
        let item = try await store.createWorkItem(
            WorkItemDraft(content: WorkItemContent(title: "Arrangeable"))
        )
        let material = try await store.addWorkMaterial(
            WorkMaterialDraft(kind: .note, title: "A thought", textContent: "Keep this"),
            to: item.id
        )
        XCTAssertEqual(material.cardSize, .standard,
                       "a freshly captured card claims the neutral size")

        func storedSize() async throws -> WorkMaterialCardSize {
            let value = try await store.fetchWorkItem(id: item.id)
            let record = try XCTUnwrap(value)
            return try XCTUnwrap(record.materials.first { $0.id == material.id }).cardSize
        }

        try await store.setWorkMaterialCardSize(.large, materialID: material.id, itemID: item.id)
        let enlarged = try await storedSize()
        XCTAssertEqual(enlarged, .large)

        try await store.setWorkMaterialCardSize(.small, materialID: material.id, itemID: item.id)
        let shrunk = try await storedSize()
        XCTAssertEqual(shrunk, .small)

        try await store.setWorkMaterialCardSize(.standard, materialID: material.id, itemID: item.id)
        let reset = try await storedSize()
        XCTAssertEqual(reset, .standard)
        let resetColumns = await store._workMaterialRowsForTesting(id: material.id).map(\.cardSize)
        XCTAssertEqual(
            resetColumns, [nil],
            "returning to standard clears the column instead of leaving a marker"
        )

        await store._setWorkMaterialCardSizeColumnForTesting("colossal", materialID: material.id)
        let forward = try await storedSize()
        XCTAssertEqual(
            forward, .standard,
            "a size only a newer build knows must lay out, not disappear"
        )
        XCTAssertEqual(WorkMaterialCardSize(stored: nil), .standard)
        let decoded = try JSONDecoder().decode(
            WorkMaterialCardSize.self, from: Data(#""colossal""#.utf8)
        )
        XCTAssertEqual(
            decoded, .standard,
            "decoding a forward size is a layout fallback, never a thrown error"
        )
    }

    func testResizingACardIsInvisibleToDivergence() async throws {
        let store = isolated.make()
        let item = try await store.createWorkItem(
            WorkItemDraft(content: WorkItemContent(
                title: "Arranged brief",
                objective: "Keep the arrangement out of the revision"
            ))
        )
        let material = try await store.addWorkMaterial(
            WorkMaterialDraft(kind: .note, title: "Context note", textContent: "Approved text"),
            to: item.id
        )
        let approvedValue = try await store.fetchWorkItem(id: item.id)
        let approved = try XCTUnwrap(approvedValue)
        let approvedItemRevision = WorkboardRevision.value(for: approved.updatedAt)
        let approvedMaterial = try XCTUnwrap(approved.materials.first { $0.id == material.id })
        let approvedMaterialRevision = WorkboardRevision.value(for: approvedMaterial.updatedAt)

        try await store.setWorkMaterialCardSize(.small, materialID: material.id, itemID: item.id)

        let resizedValue = try await store.fetchWorkItem(id: item.id)
        let resized = try XCTUnwrap(resizedValue)
        XCTAssertEqual(resized.updatedAt, approved.updatedAt,
                       "a card size is not activity on the brief")
        XCTAssertEqual(WorkboardRevision.value(for: resized.updatedAt), approvedItemRevision)
        let resizedMaterial = try XCTUnwrap(resized.materials.first { $0.id == material.id })
        XCTAssertEqual(resizedMaterial.cardSize, .small)
        XCTAssertEqual(
            WorkboardRevision.value(for: resizedMaterial.updatedAt),
            approvedMaterialRevision,
            "a per-material revision feeds the capture CAS; resizing may not move it"
        )
    }

    func testResizingWritesEveryDuplicateRowAndRefusesAnotherItemsMaterial() async throws {
        let store = isolated.make()
        let item = try await store.createWorkItem(
            WorkItemDraft(content: WorkItemContent(title: "Merged card"))
        )
        let other = try await store.createWorkItem(
            WorkItemDraft(content: WorkItemContent(title: "Someone else's board"))
        )
        let material = try await store.addWorkMaterial(
            WorkMaterialDraft(kind: .note, title: "Duplicated by sync"),
            to: item.id
        )
        await store._duplicateWorkMaterialRowForTesting(id: material.id)
        let mergedRows = await store._workMaterialRowsForTesting(id: material.id)
        XCTAssertEqual(mergedRows.count, 2)

        try await store.setWorkMaterialCardSize(.large, materialID: material.id, itemID: item.id)
        let sizedRows = await store._workMaterialRowsForTesting(id: material.id)
        XCTAssertEqual(
            Set(sizedRows.map(\.cardSize)),
            ["large"],
            "whichever merged row wins the canonical read must report the chosen size"
        )

        do {
            try await store.setWorkMaterialCardSize(
                .small, materialID: material.id, itemID: other.id
            )
            XCTFail("resizing a card from a board that does not own it must be refused")
        } catch WorkboardStoreError.invalidMaterialOwner {
            // Expected.
        }
        do {
            try await store.setWorkMaterialCardSize(
                .small, materialID: UUID(), itemID: item.id
            )
            XCTFail("resizing a material that does not exist must be refused")
        } catch WorkboardStoreError.materialNotFound {
            // Expected.
        }
    }

    func testReorderingMaterialsRewritesSequenceAndAdvancesTheItemRevision() async throws {
        let store = isolated.make()
        let item = try await store.createWorkItem(
            WorkItemDraft(content: WorkItemContent(title: "Ordered brief"))
        )
        var ids: [UUID] = []
        for index in 0..<3 {
            let material = try await store.addWorkMaterial(
                WorkMaterialDraft(kind: .note, title: "Card \(index)", sequence: index),
                to: item.id
            )
            ids.append(material.id)
        }
        let beforeValue = try await store.fetchWorkItem(id: item.id)
        let before = try XCTUnwrap(beforeValue)
        XCTAssertEqual(before.materials.map(\.id), ids)

        let reordered = [ids[2], ids[0], ids[1]]
        let after = try await store.reorderWorkMaterials(
            itemID: item.id,
            orderedMaterialIDs: reordered
        )
        XCTAssertEqual(after.materials.map(\.id), reordered)
        XCTAssertEqual(after.materials.map(\.sequence), [0, 1, 2])
        XCTAssertGreaterThan(after.updatedAt, before.updatedAt,
                             "order is board content, so a drag is a real change")
        XCTAssertNotEqual(
            WorkboardRevision.value(for: after.updatedAt),
            WorkboardRevision.value(for: before.updatedAt)
        )

        // Replaying the same arrangement is a no-op, so an idle board cannot
        // keep advancing its own revision.
        let replayed = try await store.reorderWorkMaterials(
            itemID: item.id,
            orderedMaterialIDs: reordered
        )
        XCTAssertEqual(replayed.updatedAt, after.updatedAt)
    }

    func testReorderingWritesEveryDuplicateRowAndRefusesAnIncompleteOrStaleOrder() async throws {
        let store = isolated.make()
        let item = try await store.createWorkItem(
            WorkItemDraft(content: WorkItemContent(title: "Merged order"))
        )
        var ids: [UUID] = []
        for index in 0..<2 {
            let material = try await store.addWorkMaterial(
                WorkMaterialDraft(kind: .note, title: "Card \(index)", sequence: index),
                to: item.id
            )
            ids.append(material.id)
        }
        await store._duplicateWorkMaterialRowForTesting(id: ids[0])

        let reordered = [ids[1], ids[0]]
        _ = try await store.reorderWorkMaterials(itemID: item.id, orderedMaterialIDs: reordered)
        let movedRows = await store._workMaterialRowsForTesting(id: ids[0])
        XCTAssertEqual(
            Set(movedRows.map(\.sequence)),
            [1],
            "a duplicated row left at its old rank would resurrect the old order"
        )

        do {
            _ = try await store.reorderWorkMaterials(
                itemID: item.id,
                orderedMaterialIDs: [ids[0]]
            )
            XCTFail("an order naming only part of the board must be refused")
        } catch WorkboardStoreError.staleRevision {
            // Expected.
        }
        do {
            _ = try await store.reorderWorkMaterials(
                itemID: item.id,
                orderedMaterialIDs: [ids[0], ids[1]],
                expectedOwnerRevision: 1
            )
            XCTFail("a rewrite built on an order the person never saw must be refused")
        } catch WorkboardStoreError.staleRevision {
            // Expected.
        }
        do {
            _ = try await store.reorderWorkMaterials(
                itemID: UUID(),
                orderedMaterialIDs: []
            )
            XCTFail("reordering a card that does not exist must be refused")
        } catch WorkboardStoreError.itemNotFound {
            // Expected.
        }
    }
}
