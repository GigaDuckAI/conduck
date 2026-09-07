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

    // MARK: - Companion link

    /// The link round-trips through the write door and the board projection,
    /// and two physical rows that disagree about it resolve to ONE row whatever
    /// order a reader's fetch hands them over in.
    ///
    /// The disagreement is ordinary: a recording published on one device before
    /// its screenshot existed and on another after it did merges into two rows
    /// alike in every other column. Whichever row wins decides whether the desk
    /// draws one card or two, so both selectors have to reach it and they have
    /// to reach it from a SYNCED column — which is the half the value-level
    /// case below owns.
    func testTwoDuplicateRowsDifferingOnlyInTheCompanionLinkConvergeOnOneRow() async throws {
        let store = isolated.make()
        let pictureID = UUID()
        let recording = try await store.upsertDeskMaterial(
            WorkMaterialDraft(
                kind: .audio,
                title: "Ship the carrier review",
                textContent: "Ship the carrier review by Friday"
            )
        )
        XCTAssertNil(
            recording.attachedToMaterialID,
            "a recording published with no picture belongs to none"
        )

        let attached = try await store.upsertDeskMaterial(
            WorkMaterialDraft(
                kind: .audio,
                title: "Ship the packaging review",
                textContent: "Ship the packaging review by Friday",
                attachedToMaterialID: pictureID
            )
        )
        XCTAssertEqual(
            attached.attachedToMaterialID, pictureID,
            "the write door and the projection have to carry the link the draft states"
        )
        let attachedRows = await store._workMaterialRowsForTesting(id: attached.id)
        XCTAssertEqual(
            Set(attachedRows.map(\.attachedToMaterialID)), [pictureID],
            "the link is written on the row, not only reported by the projection"
        )
        let plainRows = await store._workMaterialRowsForTesting(id: recording.id)
        XCTAssertEqual(
            plainRows.compactMap(\.attachedToMaterialID), [],
            "nothing may invent a picture for a recording that named none"
        )

        // The merge: one more physical row for the SAME logical recording,
        // identical but for the link.
        await store._duplicateWorkMaterialRowForTesting(
            id: recording.id,
            attachedToMaterialID: pictureID
        )
        let mergedRows = await store._workMaterialRowsForTesting(id: recording.id)
        XCTAssertEqual(mergedRows.count, 2)
        XCTAssertEqual(
            Set(mergedRows.map(\.title)).count, 1,
            "the two rows must differ in the link and in nothing else"
        )
        XCTAssertEqual(Set(mergedRows.map(\.updatedAt)).count, 1)
        XCTAssertEqual(Set(mergedRows.map(\.attachedToMaterialID)), [nil, pictureID])

        // Both selectors, each from its candidate list forward and reversed.
        let rowKeys = await store._canonicalRowKeysForTesting(id: recording.id)
        XCTAssertEqual(rowKeys.count, 4)
        XCTAssertEqual(
            Set(rowKeys).count, 1,
            "one card cannot be described by one duplicate and played from another"
        )

        let deskMaterials = try await store.fetchWorkItem(
            id: Constants.workboardDeskItemID
        )?.materials ?? []
        let resolved = try XCTUnwrap(deskMaterials.first { $0.id == recording.id })
        XCTAssertEqual(
            resolved.attachedToMaterialID, pictureID,
            "absence sorts below every present value, so the row that names a picture wins"
        )
        XCTAssertEqual(
            deskMaterials.filter { $0.id == recording.id }.count, 1,
            "deduplication still reports one card"
        )
    }

    /// The link is decided BEFORE `rowKey`.
    ///
    /// `rowKey` is the one device-local key in the ordering, so two rows left to
    /// it resolve differently on two devices — one drawing the recording inside
    /// its screenshot, the other drawing two cards, from the same two rows. This
    /// case pins the link ahead of it by giving the row keys the OPPOSITE order
    /// to the links: if the link stopped being compared, the loser would win.
    func testTheCanonicalOrderDecidesTheCompanionLinkBeforeTheDeviceLocalRowKey() {
        let pictureID = UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!
        let laterPictureID = UUID(uuidString: "00000000-0000-0000-0000-0000000000BB")!

        let unattached = canonicalOrder(attachedTo: nil, rowKey: "x-coredata:///WorkMaterial/p9")
        let attached = canonicalOrder(attachedTo: pictureID, rowKey: "x-coredata:///WorkMaterial/p1")
        XCTAssertTrue(
            unattached < attached,
            "a row that names a picture outranks one that names none, whatever its object id"
        )
        XCTAssertFalse(attached < unattached)
        XCTAssertNotEqual(unattached, attached,
                          "two rows that differ in the link are not interchangeable")

        // Two rows that both name a picture, and name DIFFERENT ones: still the
        // synced column, still not the object id.
        let earlier = canonicalOrder(attachedTo: pictureID, rowKey: "x-coredata:///WorkMaterial/p9")
        let later = canonicalOrder(attachedTo: laterPictureID, rowKey: "x-coredata:///WorkMaterial/p1")
        XCTAssertTrue(earlier < later)

        // Rows agreeing on the link fall through to the row key, as before.
        let sameLinkLowKey = canonicalOrder(attachedTo: pictureID,
                                            rowKey: "x-coredata:///WorkMaterial/p1")
        let sameLinkHighKey = canonicalOrder(attachedTo: pictureID,
                                             rowKey: "x-coredata:///WorkMaterial/p9")
        XCTAssertTrue(sameLinkLowKey < sameLinkHighKey)
        XCTAssertEqual(
            [unattached, attached, earlier, later].max()?.attachedToMaterialID,
            laterPictureID,
            "the maximum is what every reader takes as canonical"
        )
    }

    // MARK: - Group delete

    /// A folded pair leaves as ONE mutation: both cards, EVERY physical row of
    /// each, both blob lanes, one desk revision and one change notification.
    ///
    /// The duplicates are the half a projection-level assertion cannot see. A
    /// CloudKit merge leaves one logical card as several rows; a survivor would
    /// resurrect the card the person removed, and the board would report the
    /// delete as having worked until the next read.
    func testDeletingACompanionPairRemovesBothCardsAndBothBlobLanesInOneMutation() async throws {
        let store = isolated.make()
        let captureID = UUID()
        let pictureID = WorkVoiceScreenshotCoordinator.materialID(forCapture: captureID)

        let picture = try await store.upsertDeskMaterial(
            WorkMaterialDraft(
                id: pictureID,
                kind: .image,
                title: "screenshot.jpg",
                filename: "screenshot.jpg",
                mimeType: "image/jpeg",
                payload: Data("a screenshot of the carrier rates".utf8)
            )
        )
        let recording = try await store.upsertDeskMaterial(
            WorkMaterialDraft(
                id: captureID,
                kind: .audio,
                title: "Ship the carrier review",
                textContent: "Ship the carrier review by Friday",
                filename: "note.m4a",
                mimeType: "audio/m4a",
                payload: Data("the recorded words".utf8),
                attachedToMaterialID: pictureID
            )
        )
        let bystander = try await store.upsertDeskMaterial(
            WorkMaterialDraft(kind: .note, title: "Unrelated", textContent: "Keep me")
        )

        // The merge both members can arrive in.
        await store._duplicateWorkMaterialRowForTesting(
            id: recording.id, updatedAt: recording.updatedAt.addingTimeInterval(1)
        )
        await store._duplicateWorkMaterialRowForTesting(
            id: picture.id, updatedAt: picture.updatedAt.addingTimeInterval(1)
        )
        let childRowsBefore = await store._workMaterialRowsForTesting(id: recording.id)
        XCTAssertEqual(childRowsBefore.count, 2, "the fixture needs a duplicated recording row")
        let parentRowsBefore = await store._workMaterialRowsForTesting(id: picture.id)
        XCTAssertEqual(parentRowsBefore.count, 2, "the fixture needs a duplicated picture row")
        let childBlobsBefore = await store._workMaterialBlobRowsForTesting(materialID: recording.id)
        XCTAssertFalse(childBlobsBefore.isEmpty, "the fixture needs the recording on the synced lane")
        let parentBlobsBefore = await store._workMaterialBlobRowsForTesting(materialID: picture.id)
        XCTAssertFalse(parentBlobsBefore.isEmpty, "the fixture needs the picture on the synced lane")

        let deskBeforeValue = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        let deskBefore = try XCTUnwrap(deskBeforeValue)
        XCTAssertEqual(deskBefore.materials.count, 3)

        let posts = try await countingDeskChanges {
            try await store.deleteWorkMaterialGroup(
                parentID: picture.id,
                childID: recording.id,
                workItemID: Constants.workboardDeskItemID,
                expectedOwnerRevision: WorkboardRevision.value(for: deskBefore.updatedAt)
            )
        }
        XCTAssertEqual(
            posts, 1,
            "the pair is one mutation, so the board is told once — twice is the two-delete "
            + "shape this call exists to replace"
        )

        let childRowsAfter = await store._workMaterialRowsForTesting(id: recording.id)
        XCTAssertTrue(childRowsAfter.isEmpty, "every duplicate of the recording goes")
        let parentRowsAfter = await store._workMaterialRowsForTesting(id: picture.id)
        XCTAssertTrue(parentRowsAfter.isEmpty, "every duplicate of the picture goes")
        let childBlobsAfter = await store._workMaterialBlobRowsForTesting(materialID: recording.id)
        XCTAssertTrue(childBlobsAfter.isEmpty, "paired deletion is the only reclamation a blob has")
        let parentBlobsAfter = await store._workMaterialBlobRowsForTesting(materialID: picture.id)
        XCTAssertTrue(parentBlobsAfter.isEmpty)

        let deskAfterValue = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        let deskAfter = try XCTUnwrap(deskAfterValue)
        XCTAssertEqual(
            deskAfter.materials.map(\.id), [bystander.id],
            "a card that was never part of the pair is untouched"
        )
        XCTAssertGreaterThan(
            deskAfter.updatedAt, deskBefore.updatedAt,
            "removing cards is board content, so the desk revision moves"
        )
        XCTAssertNotEqual(
            WorkboardRevision.value(for: deskAfter.updatedAt),
            WorkboardRevision.value(for: deskBefore.updatedAt)
        )
    }

    /// Every distinct vault key across BOTH materials and across every physical
    /// row — never `.first`.
    ///
    /// Two duplicate rows of one card can name different leaves holding
    /// different bytes (the device-local lane names no blob, so nothing else
    /// separates them). A collector that stopped at the first key would leave a
    /// payload on disk that no card will ever reclaim again, because paired
    /// deletion is the only pass that ever removes one.
    func testGroupDeleteCollectsEveryVaultKeyAcrossBothMaterialsAndEveryRow() async throws {
        let store = isolated.make()
        let item = try await store.createWorkItem(
            WorkItemDraft(content: WorkItemContent(title: "Vault-lane pair"))
        )
        let captureID = UUID()
        let pictureID = WorkVoiceScreenshotCoordinator.materialID(forCapture: captureID)

        let picture = try await store.addWorkMaterial(
            WorkMaterialDraft(
                id: pictureID,
                kind: .image,
                title: "screenshot.jpg",
                filename: "screenshot.jpg",
                mimeType: "image/jpeg",
                payload: Data("screenshot bytes".utf8)
            ),
            to: item.id
        )
        let recording = try await store.addWorkMaterial(
            WorkMaterialDraft(
                id: captureID,
                kind: .audio,
                title: "Ship the carrier review",
                filename: "note.m4a",
                mimeType: "audio/m4a",
                payload: Data("recorded bytes".utf8),
                attachedToMaterialID: pictureID
            ),
            to: item.id
        )
        let bystander = try await store.addWorkMaterial(
            WorkMaterialDraft(
                kind: .file,
                title: "rates.txt",
                filename: "rates.txt",
                mimeType: "text/plain",
                payload: Data("zone rates".utf8)
            ),
            to: item.id
        )
        let pictureKey = try XCTUnwrap(picture.localVaultKey)
        let recordingKey = try XCTUnwrap(recording.localVaultKey)
        let bystanderKey = try XCTUnwrap(bystander.localVaultKey)

        // A second leaf under a duplicate row of the recording: the shape
        // `.first` gets wrong.
        let strandedLeaf = try await store.workAssetVault.store(
            bytes: Data("the other device's copy".utf8),
            id: UUID(),
            suggestedExtension: "m4a"
        )
        await store._duplicateWorkMaterialRowForTesting(
            id: recording.id,
            updatedAt: recording.updatedAt.addingTimeInterval(1),
            localVaultKey: strandedLeaf.key
        )
        let stagedKeys = [pictureKey, recordingKey, strandedLeaf.key]
        XCTAssertEqual(Set(stagedKeys).count, 3, "the three leaves have to be distinct")
        for key in stagedKeys + [bystanderKey] {
            let present = await store.workAssetVault.contains(key)
            XCTAssertTrue(present, "the fixture needs \(key) on disk")
        }

        let ownerValue = try await store.fetchWorkItem(id: item.id)
        let owner = try XCTUnwrap(ownerValue)
        try await store.deleteWorkMaterialGroup(
            parentID: picture.id,
            childID: recording.id,
            workItemID: item.id,
            expectedOwnerRevision: WorkboardRevision.value(for: owner.updatedAt)
        )

        for key in stagedKeys {
            let present = await store.workAssetVault.contains(key)
            XCTAssertFalse(
                present,
                "\(key) belonged to the pair, and a leaf nothing names is never reclaimed again"
            )
        }
        let survivor = await store.workAssetVault.contains(bystanderKey)
        XCTAssertTrue(survivor, "the third card's payload is not the pair's to remove")
        let refreshedValue = try await store.fetchWorkItem(id: item.id)
        let refreshed = try XCTUnwrap(refreshedValue)
        XCTAssertEqual(refreshed.materials.map(\.id), [bystander.id])
    }

    /// A token the person's board never saw refuses, and refuses BEFORE
    /// anything is deleted — then the same call with the real token goes
    /// through, which is what proves the refusal was the revision and not the
    /// pair.
    func testGroupDeleteRefusesAStaleRevisionAndDeletesNothing() async throws {
        let store = isolated.make()
        let pair = try await seedCompanionPair(in: store)

        do {
            try await store.deleteWorkMaterialGroup(
                parentID: pair.pictureID,
                childID: pair.recordingID,
                workItemID: Constants.workboardDeskItemID,
                expectedOwnerRevision: 1
            )
            XCTFail("a delete built on a revision the person never saw must be refused")
        } catch WorkboardStoreError.staleRevision {
            // Expected.
        }
        let childRows = await store._workMaterialRowsForTesting(id: pair.recordingID)
        XCTAssertEqual(childRows.count, 1, "a refused pair delete removes no row")
        let parentRows = await store._workMaterialRowsForTesting(id: pair.pictureID)
        XCTAssertEqual(parentRows.count, 1)
        let childBlobs = await store._workMaterialBlobRowsForTesting(materialID: pair.recordingID)
        XCTAssertFalse(childBlobs.isEmpty, "a refused pair delete retires no payload")
        let parentBlobs = await store._workMaterialBlobRowsForTesting(materialID: pair.pictureID)
        XCTAssertFalse(parentBlobs.isEmpty)

        // NEGATIVE CONTROL: the same pair, the real token.
        let deskValue = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        let desk = try XCTUnwrap(deskValue)
        try await store.deleteWorkMaterialGroup(
            parentID: pair.pictureID,
            childID: pair.recordingID,
            workItemID: Constants.workboardDeskItemID,
            expectedOwnerRevision: WorkboardRevision.value(for: desk.updatedAt)
        )
        let goneChild = await store._workMaterialRowsForTesting(id: pair.recordingID)
        XCTAssertTrue(goneChild.isEmpty)
        let goneParent = await store._workMaterialRowsForTesting(id: pair.pictureID)
        XCTAssertTrue(goneParent.isEmpty)
    }

    /// The whole truth table of pairs that are NOT a fold. Every one refuses
    /// with `invalidMaterialCompanion` (or `materialNotFound` for a member that
    /// is not on this desk at all) and every one leaves both named cards
    /// standing — a group delete that half-worked is the state this call exists
    /// to make impossible.
    func testGroupDeleteRefusesEveryPairThatIsNotAFoldAndDeletesNothing() async throws {
        let store = isolated.make()
        let desk = Constants.workboardDeskItemID

        let pictureA = try await store.upsertDeskMaterial(
            WorkMaterialDraft(kind: .image, title: "a.jpg", filename: "a.jpg",
                              mimeType: "image/jpeg", payload: Data("a".utf8))
        )
        let pictureB = try await store.upsertDeskMaterial(
            WorkMaterialDraft(kind: .image, title: "b.jpg", filename: "b.jpg",
                              mimeType: "image/jpeg", payload: Data("b".utf8))
        )
        let note = try await store.upsertDeskMaterial(
            WorkMaterialDraft(kind: .note, title: "Share note", textContent: "typed")
        )
        // An image that itself names a picture. Nothing in the publication lane
        // writes this, and the fold has to refuse it anyway: a chain is not a
        // fold, and following one would delete a card two hops from the tap.
        let chained = try await store.upsertDeskMaterial(
            WorkMaterialDraft(kind: .image, title: "c.jpg", filename: "c.jpg",
                              mimeType: "image/jpeg", payload: Data("c".utf8),
                              attachedToMaterialID: pictureB.id)
        )
        let linkedToA = try await store.upsertDeskMaterial(
            WorkMaterialDraft(kind: .audio, title: "words for a", filename: "a.m4a",
                              mimeType: "audio/m4a", payload: Data("wa".utf8),
                              attachedToMaterialID: pictureA.id)
        )
        let linkedToNote = try await store.upsertDeskMaterial(
            WorkMaterialDraft(kind: .audio, title: "words for a note", filename: "n.m4a",
                              mimeType: "audio/m4a", payload: Data("wn".utf8),
                              attachedToMaterialID: note.id)
        )
        let linkedToChained = try await store.upsertDeskMaterial(
            WorkMaterialDraft(kind: .audio, title: "words for a chain", filename: "c.m4a",
                              mimeType: "audio/m4a", payload: Data("wc".utf8),
                              attachedToMaterialID: chained.id)
        )
        let unlinked = try await store.upsertDeskMaterial(
            WorkMaterialDraft(kind: .audio, title: "words alone", filename: "u.m4a",
                              mimeType: "audio/m4a", payload: Data("wu".utf8))
        )
        // A recording on ANOTHER owner, linked to this desk's picture.
        let elsewhere = try await store.createWorkItem(
            WorkItemDraft(content: WorkItemContent(title: "Another brief"))
        )
        let foreign = try await store.addWorkMaterial(
            WorkMaterialDraft(kind: .audio, title: "words on another brief",
                              filename: "f.m4a", mimeType: "audio/m4a",
                              payload: Data("wf".utf8),
                              attachedToMaterialID: pictureA.id),
            to: elsewhere.id
        )

        func refuse(
            _ reason: String,
            parent: UUID,
            child: UUID,
            owner: UUID = desk,
            expecting expected: WorkboardStoreError = .invalidMaterialCompanion,
            line: UInt = #line
        ) async {
            do {
                try await store.deleteWorkMaterialGroup(
                    parentID: parent, childID: child, workItemID: owner
                )
                XCTFail(reason, line: line)
            } catch let error as WorkboardStoreError {
                XCTAssertEqual(error, expected, reason, line: line)
            } catch {
                XCTFail("\(reason) — got \(error)", line: line)
            }
        }

        await refuse(
            "a recording that names a DIFFERENT picture is not this picture's companion",
            parent: pictureB.id, child: linkedToA.id
        )
        await refuse(
            "a recording that names no picture at all folds into nothing",
            parent: pictureA.id, child: unlinked.id
        )
        await refuse(
            "a note is not a picture, so nothing folds into it",
            parent: note.id, child: linkedToNote.id
        )
        await refuse(
            "a picture that carries a link of its own is a chain, not a parent",
            parent: chained.id, child: linkedToChained.id
        )
        await refuse(
            "a picture is not a recording, so it can never be the child",
            parent: pictureB.id, child: pictureA.id
        )
        await refuse(
            "a card is not its own companion",
            parent: linkedToA.id, child: linkedToA.id
        )
        await refuse(
            "a recording on another owner is not this desk's to delete",
            parent: pictureA.id, child: foreign.id,
            expecting: .materialNotFound
        )
        await refuse(
            "a picture on another owner is not this desk's to delete",
            parent: pictureA.id, child: linkedToA.id, owner: elsewhere.id,
            expecting: .materialNotFound
        )

        for id in [pictureA.id, pictureB.id, note.id, chained.id,
                   linkedToA.id, linkedToNote.id, linkedToChained.id, unlinked.id] {
            let rows = await store._workMaterialRowsForTesting(id: id)
            XCTAssertEqual(rows.count, 1, "a refused pair delete removes no row")
        }
        // The typed note carries no payload, so it is the one card here with no
        // blob lane to retire.
        for id in [pictureA.id, pictureB.id, chained.id,
                   linkedToA.id, linkedToNote.id, linkedToChained.id, unlinked.id] {
            let blobs = await store._workMaterialBlobRowsForTesting(materialID: id)
            XCTAssertFalse(blobs.isEmpty, "a refused pair delete retires no payload")
        }
        let foreignRows = await store._workMaterialRowsForTesting(id: foreign.id)
        XCTAssertEqual(foreignRows.count, 1)

        // NEGATIVE CONTROL: the one pair in this fixture that IS a fold goes
        // through, so the eight refusals above are about the pairs and not
        // about the call being inert.
        try await store.deleteWorkMaterialGroup(
            parentID: pictureA.id, childID: linkedToA.id, workItemID: desk
        )
        let deletedChild = await store._workMaterialRowsForTesting(id: linkedToA.id)
        XCTAssertTrue(deletedChild.isEmpty)
        let deletedParent = await store._workMaterialRowsForTesting(id: pictureA.id)
        XCTAssertTrue(deletedParent.isEmpty)
    }

    /// FIRST ELIGIBLE, NEVER FIRST EXISTING.
    ///
    /// A wrong-kind row standing at the named id is exactly WHY the picture
    /// escaped to `WorkMaterialCollisionEscape.materialID(forCapture:)`. A
    /// resolution that stopped at that row would leave every collision-escaped
    /// pair permanently unfoldable and undeletable as a pair.
    func testGroupDeleteResolvesThroughTheCollisionEscapeAndRefusesTheOccupiedID() async throws {
        let store = isolated.make()
        let desk = Constants.workboardDeskItemID
        let captureID = UUID()
        let namedID = WorkVoiceScreenshotCoordinator.materialID(forCapture: captureID)
        let escapedID = WorkMaterialCollisionEscape.materialID(forCapture: namedID)

        // The occupant: a card of another kind already holding the id the
        // recording names.
        let occupant = try await store.upsertDeskMaterial(
            WorkMaterialDraft(id: namedID, kind: .note, title: "Share note",
                              textContent: "somebody else's card")
        )
        let picture = try await store.upsertDeskMaterial(
            WorkMaterialDraft(id: escapedID, kind: .image, title: "screenshot.jpg",
                              filename: "screenshot.jpg", mimeType: "image/jpeg",
                              payload: Data("escaped screenshot".utf8))
        )
        let recording = try await store.upsertDeskMaterial(
            WorkMaterialDraft(id: captureID, kind: .audio, title: "Ship the review",
                              filename: "note.m4a", mimeType: "audio/m4a",
                              payload: Data("words".utf8),
                              attachedToMaterialID: namedID)
        )

        do {
            try await store.deleteWorkMaterialGroup(
                parentID: occupant.id, childID: recording.id, workItemID: desk
            )
            XCTFail("the occupant of the named id is not the recording's picture")
        } catch WorkboardStoreError.invalidMaterialCompanion {
            // Expected.
        }
        let occupantRows = await store._workMaterialRowsForTesting(id: occupant.id)
        XCTAssertEqual(occupantRows.count, 1)

        try await store.deleteWorkMaterialGroup(
            parentID: picture.id, childID: recording.id, workItemID: desk
        )
        let goneChild = await store._workMaterialRowsForTesting(id: recording.id)
        XCTAssertTrue(goneChild.isEmpty, "the escaped picture is still the recording's companion")
        let goneParent = await store._workMaterialRowsForTesting(id: picture.id)
        XCTAssertTrue(goneParent.isEmpty)
        let survivingOccupant = await store._workMaterialRowsForTesting(id: occupant.id)
        XCTAssertEqual(
            survivingOccupant.count, 1,
            "the card that merely held the id was never part of the pair"
        )
    }

    /// A recording that names ITSELF is not a companion of anything, and the
    /// escape of its own id must not become a back door to that verdict.
    ///
    /// `escape(C)` is not `C`, so a validation that only stepped over the
    /// self-referential candidate would go on to the second one and accept the
    /// pair whenever a picture happens to sit at that derived id — deleting a
    /// recording that no press of Capture to Work ever paired with it, from the
    /// one control that promised to remove a card the person was looking at.
    /// The stored link is raw by contract, so a corrupt or synced row can carry
    /// a self-link that no lane writes.
    func testGroupDeleteRefusesASelfNamingRecordingEvenWithAPictureAtItsOwnEscape()
        async throws {
        let store = isolated.make()
        let desk = Constants.workboardDeskItemID
        let recordingID = UUID()
        let escapeOfItself = WorkMaterialCollisionEscape.materialID(forCapture: recordingID)

        let picture = try await store.upsertDeskMaterial(
            WorkMaterialDraft(id: escapeOfItself, kind: .image, title: "screenshot.jpg",
                              filename: "screenshot.jpg", mimeType: "image/jpeg",
                              payload: Data("unrelated screenshot".utf8))
        )
        let selfNaming = try await store.upsertDeskMaterial(
            WorkMaterialDraft(id: recordingID, kind: .audio, title: "Ship the review",
                              filename: "note.m4a", mimeType: "audio/m4a",
                              payload: Data("words".utf8),
                              attachedToMaterialID: recordingID)
        )
        XCTAssertEqual(
            selfNaming.attachedToMaterialID, recordingID,
            "the premise: the store keeps the link raw, self-link included"
        )

        do {
            try await store.deleteWorkMaterialGroup(
                parentID: picture.id, childID: selfNaming.id, workItemID: desk
            )
            XCTFail("a recording that names itself is nobody's companion")
        } catch WorkboardStoreError.invalidMaterialCompanion {
            // Expected.
        }
        for id in [picture.id, selfNaming.id] {
            let rows = await store._workMaterialRowsForTesting(id: id)
            XCTAssertEqual(rows.count, 1, "a refused pair delete removes no row")
            let blobs = await store._workMaterialBlobRowsForTesting(materialID: id)
            XCTAssertFalse(blobs.isEmpty, "a refused pair delete retires no payload")
        }

        // NEGATIVE CONTROL: that same picture IS a parent for a recording that
        // names it, so the refusal above is about the self-link and not about
        // the picture or the call being inert.
        let honest = try await store.upsertDeskMaterial(
            WorkMaterialDraft(kind: .audio, title: "later words", filename: "later.m4a",
                              mimeType: "audio/m4a", payload: Data("later".utf8),
                              attachedToMaterialID: escapeOfItself)
        )
        try await store.deleteWorkMaterialGroup(
            parentID: picture.id, childID: honest.id, workItemID: desk
        )
        let gonePicture = await store._workMaterialRowsForTesting(id: picture.id)
        XCTAssertTrue(gonePicture.isEmpty)
        let goneHonest = await store._workMaterialRowsForTesting(id: honest.id)
        XCTAssertTrue(goneHonest.isEmpty)
        let survivor = await store._workMaterialRowsForTesting(id: selfNaming.id)
        XCTAssertEqual(
            survivor.count, 1,
            "the self-naming recording was never part of the pair and still owns its payload"
        )
    }

    // MARK: - Group-delete fixtures

    private struct SeededCompanionPair {
        let pictureID: UUID
        let recordingID: UUID
    }

    /// One capture's two cards on the desk, both on the synced lane so each has
    /// a blob row a refusal can be shown not to have touched.
    private func seedCompanionPair(
        in store: ConversationStore
    ) async throws -> SeededCompanionPair {
        let captureID = UUID()
        let pictureID = WorkVoiceScreenshotCoordinator.materialID(forCapture: captureID)
        _ = try await store.upsertDeskMaterial(
            WorkMaterialDraft(
                id: pictureID, kind: .image, title: "screenshot.jpg",
                filename: "screenshot.jpg", mimeType: "image/jpeg",
                payload: Data("screenshot bytes".utf8)
            )
        )
        _ = try await store.upsertDeskMaterial(
            WorkMaterialDraft(
                id: captureID, kind: .audio, title: "Ship the carrier review",
                filename: "note.m4a", mimeType: "audio/m4a",
                payload: Data("recorded bytes".utf8),
                attachedToMaterialID: pictureID
            )
        )
        return SeededCompanionPair(pictureID: pictureID, recordingID: captureID)
    }

    /// A main-actor counter a `.conversationsDidChange` observer can bump.
    /// `@MainActor` makes it Sendable, so the observer block can capture it
    /// without a mutable-capture race — and the store posts that notification
    /// from the main actor, so the observer genuinely runs there.
    @MainActor
    private final class DeskChangeCounter {
        var count = 0
    }

    /// Run `body` with a live `.conversationsDidChange` observer and report how
    /// many times the store announced a change. Registered with a nil queue, so
    /// each post runs the block synchronously on the posting thread and the
    /// count is settled by the time the awaited call returns.
    private func countingDeskChanges(
        _ body: () async throws -> Void
    ) async rethrows -> Int {
        let counter = DeskChangeCounter()
        let token = NotificationCenter.default.addObserver(
            forName: .conversationsDidChange, object: nil, queue: nil
        ) { _ in MainActor.assumeIsolated { counter.count += 1 } }
        defer { NotificationCenter.default.removeObserver(token) }
        try await body()
        return await MainActor.run { counter.count }
    }

    /// One ordering value, with every key but the link and the row key held
    /// fixed — the shape two merged rows of one recording actually have.
    private func canonicalOrder(
        attachedTo: UUID?,
        rowKey: String
    ) -> WorkMaterialCanonicalOrder {
        WorkMaterialCanonicalOrder(
            revision: Date(timeIntervalSince1970: 1_800_000_000),
            createdAt: Date(timeIntervalSince1970: 1_800_000_000),
            title: "Ship the carrier review",
            contentHash: "sha256-recording",
            localVaultKey: nil,
            storageMode: "syncedPayload",
            byteSize: 9_001,
            kind: "audio",
            textContent: "Ship the carrier review by Friday",
            urlString: nil,
            filename: nil,
            mimeType: "audio/m4a",
            caption: "",
            cardSize: nil,
            attachedToMaterialID: attachedTo,
            thumbnailData: nil,
            rowKey: rowKey
        )
    }
}
