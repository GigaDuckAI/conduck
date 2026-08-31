// SPDX-License-Identifier: Apache-2.0

// ConduckTests
// WorkboardPersistenceTests.swift
//
// End-to-end in-memory Core Data coverage for Workboard capture idempotency,
// material privacy, the atomic prepare/retry boundary, honest state projection,
// immutable snapshots, duplication, and conversation-preserving deletion.

import XCTest
@testable import Conduck

final class WorkboardPersistenceTests: XCTestCase {
    func testPrepareRevalidatesApprovedRevisionAndNeverMovesUpdatedAtBackward() async throws {
        let store = ConversationStore(inMemory: true)
        let item = try await store.createWorkItem(
            WorkItemDraft(content: WorkItemContent(
                title: "Approved brief",
                objective: "Use only the approved version"
            ))
        )
        let snapshot = WorkBriefSnapshot(
            title: item.content.title,
            objective: item.content.objective,
            context: item.content.context,
            desiredOutcome: item.content.desiredOutcome,
            constraints: item.content.constraints,
            dueAt: item.content.dueAt,
            materials: []
        )
        let stalePreparation = WorkDispatchPreparation(
            workItemID: item.id,
            gatewayRef: "custom:v1:test",
            gatewayName: "Gateway",
            canonicalPrompt: "Approved packet",
            briefSnapshot: snapshot,
            expectedWorkItemRevision: WorkboardRevision.value(for: item.updatedAt),
            expectedMaterialVersions: [],
            sourceDevice: "test"
        )

        var changedContent = item.content
        changedContent.context = "A concurrent edit that must win"
        let changedValue = try await store.updateWorkItem(id: item.id, content: changedContent)
        let changed = try XCTUnwrap(changedValue)
        do {
            _ = try await store.prepareWorkDispatch(stalePreparation)
            XCTFail("A revision changed after preflight must abort before creating transport rows")
        } catch WorkboardStoreError.staleRevision {
            // Expected.
        }
        let absentConversation = try await store.fetchConversation(id: stalePreparation.conversationID)
        XCTAssertNil(absentConversation)
        let unchangedValue = try await store.fetchWorkItem(id: item.id)
        XCTAssertTrue(try XCTUnwrap(unchangedValue).dispatches.isEmpty)

        let currentValue = try await store.fetchWorkItem(id: item.id)
        let current = try XCTUnwrap(currentValue)
        let currentSnapshot = WorkBriefSnapshot(
            title: current.content.title,
            objective: current.content.objective,
            context: current.content.context,
            desiredOutcome: current.content.desiredOutcome,
            constraints: current.content.constraints,
            dueAt: current.content.dueAt,
            materials: []
        )
        let validPreparation = WorkDispatchPreparation(
            workItemID: item.id,
            gatewayRef: "custom:v1:test",
            gatewayName: "Gateway",
            canonicalPrompt: "Current packet",
            briefSnapshot: currentSnapshot,
            expectedWorkItemRevision: WorkboardRevision.value(for: current.updatedAt),
            expectedMaterialVersions: [],
            sourceDevice: "test",
            preparedAt: .distantPast
        )
        let prepared = try await store.prepareWorkDispatch(validPreparation)
        XCTAssertGreaterThan(prepared.workItem.updatedAt, changed.updatedAt)
    }

    func testCaptureIdempotencyAndLocalMaterialPrivacy() async throws {
        let store = ConversationStore(inMemory: true)
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
                       "file bytes stay off the CloudKit model, even when small")
        XCTAssertNil(material.textContent,
                     "an extract of a local file must not enter the mirrored material row")
        XCTAssertNil(WorkMaterialSnapshot(record: material).textContent,
                     "immutable dispatch metadata must not reintroduce local file content")
        let loadedPayload = try await store.loadWorkMaterialPayload(id: material.id)
        XCTAssertEqual(loadedPayload, payload)
    }

    func testRecentWorkItemSummariesAreBoundedOpenAndModifiedFirst() async throws {
        let store = ConversationStore(inMemory: true)
        let oldest = try await store.createWorkItem(WorkItemDraft(
            content: WorkItemContent(title: "Oldest"),
            createdAt: Date(timeIntervalSince1970: 10)
        ))
        let middle = try await store.createWorkItem(WorkItemDraft(
            content: WorkItemContent(title: "Middle"),
            createdAt: Date(timeIntervalSince1970: 20)
        ))
        let newest = try await store.createWorkItem(WorkItemDraft(
            content: WorkItemContent(title: "Newest"),
            createdAt: Date(timeIntervalSince1970: 30)
        ))
        let completed = try await store.createWorkItem(WorkItemDraft(
            content: WorkItemContent(title: "Completed"),
            createdAt: Date(timeIntervalSince1970: 40)
        ))
        _ = try await store.completeWorkItem(id: completed.id)

        let summaries = try await store.fetchRecentWorkItemSummaries(limit: 8)
        XCTAssertEqual(summaries.map(\.id), [newest.id, middle.id, oldest.id],
                       "a completed card never reaches the share-extension picker")
        XCTAssertEqual(summaries.map(\.title), ["Newest", "Middle", "Oldest"])

        let bounded = try await store.fetchRecentWorkItemSummaries(limit: 2)
        XCTAssertEqual(bounded.map(\.id), [newest.id, middle.id])
        let none = try await store.fetchRecentWorkItemSummaries(limit: 0)
        XCTAssertTrue(none.isEmpty)
    }

    func testBriefFieldsBeyondTheSharedBoundAreRefusedNotTruncated() async throws {
        let store = ConversationStore(inMemory: true)
        let overlong = String(
            repeating: "a",
            count: WorkItemContentLimits.maximumFieldCharacters + 1
        )
        do {
            _ = try await store.createWorkItem(
                WorkItemDraft(content: WorkItemContent(title: "Too long", objective: overlong))
            )
            XCTFail("An unbounded objective must not reach the mirrored row")
        } catch WorkboardStoreError.contentTooLong {
            // Expected.
        }

        let item = try await store.createWorkItem(
            WorkItemDraft(content: WorkItemContent(title: "Bounded", objective: "Short"))
        )
        var overlongContext = item.content
        overlongContext.context = overlong
        do {
            _ = try await store.updateWorkItem(id: item.id, content: overlongContext)
            XCTFail("The same bound applies to every editable brief field")
        } catch WorkboardStoreError.contentTooLong {
            // Expected.
        }
        let unchangedValue = try await store.fetchWorkItem(id: item.id)
        let unchanged = try XCTUnwrap(unchangedValue)
        XCTAssertEqual(unchanged.content.objective, "Short")
        XCTAssertEqual(unchanged.content.context, "")
    }

    func testDuplicateCopiesMaterialsToFreshIdentitiesAndDistinctVaultKeys() async throws {
        let store = ConversationStore(inMemory: true)
        let item = try await store.createWorkItem(
            WorkItemDraft(content: WorkItemContent(title: "Reusable brief", objective: "Copy me"))
        )
        let note = try await store.addWorkMaterial(
            WorkMaterialDraft(kind: .note, title: "Decision note", textContent: "Keep this"),
            to: item.id
        )
        let payload = Data("original bytes".utf8)
        let file = try await store.addWorkMaterial(
            WorkMaterialDraft(
                kind: .file,
                title: "Rate card",
                filename: "rates.txt",
                mimeType: "text/plain",
                payload: payload,
                sequence: 1
            ),
            to: item.id
        )

        let duplicate = try await store.duplicateWorkItem(id: item.id)
        XCTAssertNotEqual(duplicate.id, item.id)
        XCTAssertTrue(duplicate.dispatches.isEmpty, "runs are history, never a template")
        XCTAssertEqual(duplicate.materials.map(\.title), [note.title, file.title])
        XCTAssertTrue(duplicate.materials.allSatisfy { $0.id != note.id && $0.id != file.id },
                      "a copied material must own a fresh identity")

        let copiedFile = try XCTUnwrap(duplicate.materials.first { $0.kind == .file })
        let copiedKey = try XCTUnwrap(copiedFile.localVaultKey)
        XCTAssertNotEqual(copiedKey, file.localVaultKey,
                          "each card owns its own vault leaf so deletion stays independent")
        XCTAssertEqual(copiedFile.availability, .availableLocally)
        XCTAssertEqual(copiedFile.byteSize, Int64(payload.count))
        let copiedPayload = try await store.loadWorkMaterialPayload(id: copiedFile.id)
        XCTAssertEqual(copiedPayload, payload)

        // Deleting the copy must not reclaim the source's bytes.
        try await store.deleteWorkItem(id: duplicate.id)
        let sourcePayload = try await store.loadWorkMaterialPayload(id: file.id)
        XCTAssertEqual(sourcePayload, payload)
        let sourceItemValue = try await store.fetchWorkItem(id: item.id)
        let sourceItem = try XCTUnwrap(sourceItemValue)
        XCTAssertEqual(sourceItem.materials.map(\.id), [note.id, file.id])
        let orphans = try await store.reconcileWorkAssetVault()
        XCTAssertEqual(orphans, 0)
    }

    func testDuplicateFailurePartWayThroughLeavesNoCardAndNoOrphanBytes() async throws {
        let store = ConversationStore(inMemory: true)
        let item = try await store.createWorkItem(
            WorkItemDraft(content: WorkItemContent(title: "Partly copyable"))
        )
        let payload = Data("copyable bytes".utf8)
        _ = try await store.addWorkMaterial(
            WorkMaterialDraft(
                kind: .file,
                title: "Copied first",
                filename: "first.txt",
                payload: payload,
                sequence: 0
            ),
            to: item.id
        )
        // A synced-lane row whose bytes never arrived from CloudKit: the copy
        // must refuse rather than hand back a card that silently lost material.
        _ = try await store.addWorkMaterial(
            WorkMaterialDraft(
                kind: .file,
                title: "Never materialized",
                filename: "second.txt",
                sequence: 1,
                storageMode: .syncedPayload
            ),
            to: item.id
        )

        do {
            _ = try await store.duplicateWorkItem(id: item.id)
            XCTFail("An unavailable payload must abort the whole duplication")
        } catch WorkboardStoreError.materialPayloadUnavailable {
            // Expected.
        }

        let items = try await store.fetchWorkItems()
        XCTAssertEqual(items.map(\.id), [item.id], "no partial duplicate may survive")
        let orphans = try await store.reconcileWorkAssetVault()
        XCTAssertEqual(orphans, 0, "the rolled-back copy must leave no vault file behind")
        let survivingFile = try XCTUnwrap(items.first?.materials.first)
        let sourcePayload = try await store.loadWorkMaterialPayload(id: survivingFile.id)
        XCTAssertEqual(sourcePayload, payload)
    }

    func testAtomicPrepareIsIdempotentAndStateFollowsExactMessageStatus() async throws {
        let store = ConversationStore(inMemory: true)
        let item = try await store.createWorkItem(
            WorkItemDraft(content: WorkItemContent(
                title: "Compare couriers",
                objective: "Recommend one provider",
                context: "Ship from Tallinn",
                desiredOutcome: "A short ranked table",
                constraints: "Cite sources"
            ))
        )
        let dispatchID = UUID()
        let conversationID = UUID()
        let messageID = UUID()
        let snapshot = WorkBriefSnapshot(
            title: item.content.title,
            objective: item.content.objective,
            context: item.content.context,
            desiredOutcome: item.content.desiredOutcome,
            constraints: item.content.constraints,
            dueAt: nil,
            materials: []
        )
        let preparation = WorkDispatchPreparation(
            dispatchID: dispatchID,
            workItemID: item.id,
            conversationID: conversationID,
            userMessageID: messageID,
            deliveryAttemptID: UUID(),
            gatewayRef: "custom:v1:test",
            gatewayName: "Studio Gateway",
            canonicalPrompt: "Compare couriers and return a cited ranked table.",
            briefSnapshot: snapshot,
            expectedWorkItemRevision: WorkboardRevision.value(for: item.updatedAt),
            expectedMaterialVersions: [],
            sourceDevice: "phone"
        )

        let first = try await store.prepareWorkDispatch(preparation)
        XCTAssertEqual(first.message.status, "failed", "prepare creates a retryable inert turn")
        XCTAssertNotNil(first.dispatch.dispatchedAt,
                        "committed rows have crossed the dispatch boundary")
        XCTAssertEqual(first.workItem.state, .review,
                       "dispatched + still failed needs attention until retry claims it")
        XCTAssertEqual(first.dispatch.promptSnapshot, preparation.canonicalPrompt)
        XCTAssertEqual(first.dispatch.briefSnapshot, snapshot)

        do {
            _ = try await store.prepareWorkDispatch(preparation)
            XCTFail("same caller id must not authorize a second network attempt")
        } catch WorkboardStoreError.identifierCollision {
            // Expected.
        }
        let repeatedUserMessageCount = try await store.fetchMessages(for: conversationID)
            .filter { $0.role == "user" }.count
        XCTAssertEqual(repeatedUserMessageCount, 1)

        let beganRetry = await store.beginRetry(messageID: messageID)
        let stateDuringRetry = try await store.fetchWorkItem(id: item.id)?.state
        XCTAssertTrue(beganRetry)
        XCTAssertEqual(stateDuringRetry, .waiting)

        try await store.updateStatus(messageID: messageID, status: "sent")
        let stateAfterSent = try await store.fetchWorkItem(id: item.id)?.state
        XCTAssertEqual(stateAfterSent, .review,
                       "sent proves a reply landed even if its row is temporarily not visible")
        do {
            _ = try await store.acknowledgeWorkDispatchReview(
                workItemID: item.id,
                dispatchID: dispatchID,
                expectedResultKey: "reply:\(UUID().uuidString.lowercased())"
            )
            XCTFail("A missing reply identity cannot be acknowledged away")
        } catch WorkboardStoreError.staleRevision {
            // Expected: `.replyPendingSync` has no result identity to approve.
        }
        let stateWithoutReplyIdentity = try await store.fetchWorkItem(id: item.id)?.state
        XCTAssertEqual(stateWithoutReplyIdentity, .review)

        _ = try await store.appendMessage(
            role: "agent",
            text: "Use carrier A.",
            conversationID: conversationID,
            sourceDevice: "gateway"
        )
        let repliedValue = try await store.fetchWorkItem(id: item.id)
        let replied = try XCTUnwrap(repliedValue)
        XCTAssertEqual(replied.state, .review)
        let replyKey = try XCTUnwrap(
            replied.dispatches.first { $0.id == dispatchID }?.activity.resultKey
        )
        _ = try await store.acknowledgeWorkDispatchReview(
            workItemID: item.id,
            dispatchID: dispatchID,
            expectedResultKey: replyKey
        )
        let stateAfterAcknowledgement = try await store.fetchWorkItem(id: item.id)?.state
        XCTAssertEqual(stateAfterAcknowledgement, .draft)

        _ = try await store.completeWorkItem(id: item.id)
        let completedState = try await store.fetchWorkItem(id: item.id)?.state
        XCTAssertEqual(completedState, .done)
        _ = try await store.reopenWorkItem(id: item.id)
        let reopenedState = try await store.fetchWorkItem(id: item.id)?.state
        XCTAssertEqual(reopenedState, .draft)

        try await store.deleteWorkItem(id: item.id)
        let deletedItem = try await store.fetchWorkItem(id: item.id)
        let survivingConversation = try await store.fetchConversation(id: conversationID)
        let survivingMessageCount = try await store.fetchMessages(for: conversationID).count
        XCTAssertNil(deletedItem)
        XCTAssertNotNil(survivingConversation,
                        "deleting the Workboard card must leave its Chat conversation intact")
        XCTAssertEqual(survivingMessageCount, 2)
    }

    func testReviewAcknowledgementTargetsOneExactRunAndLeavesSiblingResultVisible() async throws {
        let store = ConversationStore(inMemory: true)
        let item = try await store.createWorkItem(
            WorkItemDraft(content: WorkItemContent(
                title: "Launch comparison",
                objective: "Compare two launch plans"
            ))
        )
        let snapshot = WorkBriefSnapshot(
            title: item.content.title,
            objective: item.content.objective,
            context: "",
            desiredOutcome: "",
            constraints: "",
            dueAt: nil,
            materials: []
        )
        let first = WorkDispatchPreparation(
            workItemID: item.id,
            gatewayRef: "custom:v1:first",
            gatewayName: "First gateway",
            canonicalPrompt: "First run",
            briefSnapshot: snapshot,
            expectedWorkItemRevision: WorkboardRevision.value(for: item.updatedAt),
            expectedMaterialVersions: [],
            sourceDevice: "phone"
        )

        _ = try await store.prepareWorkDispatch(first)
        let afterFirstPreparationValue = try await store.fetchWorkItem(id: item.id)
        let afterFirstPreparation = try XCTUnwrap(afterFirstPreparationValue)
        let second = WorkDispatchPreparation(
            workItemID: item.id,
            gatewayRef: "custom:v1:second",
            gatewayName: "Second gateway",
            canonicalPrompt: "Second run",
            briefSnapshot: snapshot,
            expectedWorkItemRevision: WorkboardRevision.value(for: afterFirstPreparation.updatedAt),
            expectedMaterialVersions: [],
            sourceDevice: "mac"
        )
        _ = try await store.prepareWorkDispatch(second)
        try await store.updateStatus(messageID: first.userMessageID, status: "sent")
        try await store.updateStatus(messageID: second.userMessageID, status: "sent")
        _ = try await store.appendMessage(
            role: "agent",
            text: "First result",
            conversationID: first.conversationID,
            sourceDevice: "gateway"
        )
        _ = try await store.appendMessage(
            role: "agent",
            text: "Second result",
            conversationID: second.conversationID,
            sourceDevice: "gateway"
        )

        let beforeValue = try await store.fetchWorkItem(id: item.id)
        let before = try XCTUnwrap(beforeValue)
        let firstRun = try XCTUnwrap(before.dispatches.first { $0.id == first.dispatchID })
        let secondRun = try XCTUnwrap(before.dispatches.first { $0.id == second.dispatchID })
        let firstResultKey = try XCTUnwrap(firstRun.activity.resultKey)
        let secondResultKey = try XCTUnwrap(secondRun.activity.resultKey)
        XCTAssertTrue(firstRun.stateFacts.needsReview)
        XCTAssertTrue(secondRun.stateFacts.needsReview)

        _ = try await store.acknowledgeWorkDispatchReview(
            workItemID: item.id,
            dispatchID: first.dispatchID,
            expectedResultKey: firstResultKey
        )
        let afterFirstValue = try await store.fetchWorkItem(id: item.id)
        let afterFirst = try XCTUnwrap(afterFirstValue)
        XCTAssertFalse(try XCTUnwrap(
            afterFirst.dispatches.first { $0.id == first.dispatchID }
        ).stateFacts.needsReview)
        XCTAssertTrue(try XCTUnwrap(
            afterFirst.dispatches.first { $0.id == second.dispatchID }
        ).stateFacts.needsReview)
        XCTAssertEqual(afterFirst.state, .review)

        do {
            _ = try await store.acknowledgeWorkDispatchReview(
                workItemID: item.id,
                dispatchID: second.dispatchID,
                expectedResultKey: "reply:\(UUID().uuidString.lowercased())"
            )
            XCTFail("A stale result identity must not acknowledge a newer run")
        } catch WorkboardStoreError.staleRevision {
            // Expected compare-and-set refusal.
        }

        _ = try await store.acknowledgeWorkDispatchReview(
            workItemID: item.id,
            dispatchID: second.dispatchID,
            expectedResultKey: secondResultKey
        )
        let afterBoth = try await store.fetchWorkItem(id: item.id)?.state
        XCTAssertEqual(afterBoth, .draft)
    }

    func testWorkRunNeverClaimsReplyFromLaterOrdinaryTurn() async throws {
        let store = ConversationStore(inMemory: true)
        let item = try await store.createWorkItem(
            WorkItemDraft(content: WorkItemContent(
                title: "Bound this run",
                objective: "Keep result attribution exact"
            ))
        )
        let preparation = WorkDispatchPreparation(
            workItemID: item.id,
            gatewayRef: "custom:v1:test",
            gatewayName: "Gateway",
            canonicalPrompt: "Workboard request",
            briefSnapshot: WorkBriefSnapshot(
                title: item.content.title,
                objective: item.content.objective,
                context: "",
                desiredOutcome: "",
                constraints: "",
                dueAt: nil,
                materials: []
            ),
            expectedWorkItemRevision: WorkboardRevision.value(for: item.updatedAt),
            expectedMaterialVersions: [],
            sourceDevice: "test"
        )

        _ = try await store.prepareWorkDispatch(preparation)
        _ = try await store.appendMessage(
            role: "user",
            text: "An unrelated follow-up",
            conversationID: preparation.conversationID,
            sourceDevice: "test",
            status: "sent"
        )
        _ = try await store.appendMessage(
            role: "agent",
            text: "Reply to the unrelated follow-up",
            conversationID: preparation.conversationID,
            sourceDevice: "gateway"
        )

        let failedItemValue = try await store.fetchWorkItem(id: item.id)
        let failedItem = try XCTUnwrap(failedItemValue)
        let failedRun = try XCTUnwrap(
            failedItem.dispatches.first { $0.id == preparation.dispatchID }
        )
        guard case .failed(let messageID, _) = failedRun.activity else {
            return XCTFail("The exact failed Work turn must win over a later reply")
        }
        XCTAssertEqual(messageID, preparation.userMessageID)

        let failureKey = try XCTUnwrap(failedRun.activity.resultKey)
        _ = try await store.acknowledgeWorkDispatchReview(
            workItemID: item.id,
            dispatchID: preparation.dispatchID,
            expectedResultKey: failureKey
        )
        let acknowledgedValue = try await store.fetchWorkItem(id: item.id)
        let acknowledged = try XCTUnwrap(acknowledgedValue)
        XCTAssertFalse(try XCTUnwrap(
            acknowledged.dispatches.first { $0.id == preparation.dispatchID }
        ).stateFacts.needsReview)
    }

    func testSentWorkRunStopsLookingForReplyAtNextUserTurn() async throws {
        let store = ConversationStore(inMemory: true)
        let item = try await store.createWorkItem(
            WorkItemDraft(content: WorkItemContent(
                title: "Bound pending run",
                objective: "Do not steal the next answer"
            ))
        )
        let preparation = WorkDispatchPreparation(
            workItemID: item.id,
            gatewayRef: "custom:v1:test",
            gatewayName: "Gateway",
            canonicalPrompt: "Workboard request",
            briefSnapshot: WorkBriefSnapshot(
                title: item.content.title,
                objective: item.content.objective,
                context: "",
                desiredOutcome: "",
                constraints: "",
                dueAt: nil,
                materials: []
            ),
            expectedWorkItemRevision: WorkboardRevision.value(for: item.updatedAt),
            expectedMaterialVersions: [],
            sourceDevice: "test"
        )

        _ = try await store.prepareWorkDispatch(preparation)
        try await store.updateStatus(messageID: preparation.userMessageID, status: "sent")
        _ = try await store.appendMessage(
            role: "user",
            text: "A later ordinary message",
            conversationID: preparation.conversationID,
            sourceDevice: "test",
            status: "sent"
        )
        _ = try await store.appendMessage(
            role: "agent",
            text: "Only the ordinary message's reply",
            conversationID: preparation.conversationID,
            sourceDevice: "gateway"
        )

        let loadedValue = try await store.fetchWorkItem(id: item.id)
        let loaded = try XCTUnwrap(loadedValue)
        let run = try XCTUnwrap(loaded.dispatches.first { $0.id == preparation.dispatchID })
        guard case .replyPendingSync(let messageID) = run.activity else {
            return XCTFail("A reply after the next user turn must not be attributed to Work")
        }
        XCTAssertEqual(messageID, preparation.userMessageID)
    }

    func testDeleteAllConversationsPreservesBriefMaterialsAndTombstonesRun() async throws {
        let store = ConversationStore(inMemory: true)
        let item = try await store.createWorkItem(
            WorkItemDraft(content: WorkItemContent(
                title: "Keep this brief",
                objective: "Preserve prepared work"
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
        let itemWithMaterialValue = try await store.fetchWorkItem(id: item.id)
        let itemWithMaterial = try XCTUnwrap(itemWithMaterialValue)
        let preparation = WorkDispatchPreparation(
            workItemID: item.id,
            gatewayRef: "custom:v1:test",
            gatewayName: "Gateway",
            canonicalPrompt: "Preserve this immutable packet.",
            briefSnapshot: WorkBriefSnapshot(
                title: item.content.title,
                objective: item.content.objective,
                context: "",
                desiredOutcome: "",
                constraints: "",
                dueAt: nil,
                materials: [WorkMaterialSnapshot(record: material)]
            ),
            expectedWorkItemRevision: WorkboardRevision.value(for: itemWithMaterial.updatedAt),
            expectedMaterialVersions: [
                WorkboardMaterialVersion(
                    id: material.id,
                    revision: WorkboardRevision.value(for: material.updatedAt)
                )
            ],
            sourceDevice: "phone"
        )
        _ = try await store.prepareWorkDispatch(preparation)

        try await store.deleteAll()

        let preservedValue = try await store.fetchWorkItem(id: item.id)
        let preserved = try XCTUnwrap(preservedValue)
        XCTAssertEqual(preserved.materials.map(\.id), [material.id])
        let run = try XCTUnwrap(
            preserved.dispatches.first { $0.id == preparation.dispatchID }
        )
        guard case .conversationRemoved(let removedID) = run.activity else {
            return XCTFail("The preserved run must record that its Chat was removed")
        }
        XCTAssertEqual(removedID, preparation.conversationID)
        XCTAssertEqual(preserved.state, .review)
        let removedConversation = try await store.fetchConversation(id: preparation.conversationID)
        XCTAssertNil(removedConversation)
    }

    func testDeleteAllKeepsAnAlreadyTombstonedRunsOriginalRemovalDate() async throws {
        let store = ConversationStore(inMemory: true)
        let item = try await store.createWorkItem(
            WorkItemDraft(content: WorkItemContent(title: "Tombstoned once"))
        )
        let preparation = WorkDispatchPreparation(
            workItemID: item.id,
            gatewayRef: "custom:v1:test",
            gatewayName: "Gateway",
            canonicalPrompt: "One run, deleted early.",
            briefSnapshot: WorkBriefSnapshot(
                title: item.content.title,
                objective: "",
                context: "",
                desiredOutcome: "",
                constraints: "",
                dueAt: nil,
                materials: []
            ),
            expectedWorkItemRevision: WorkboardRevision.value(for: item.updatedAt),
            expectedMaterialVersions: [],
            sourceDevice: "phone"
        )
        _ = try await store.prepareWorkDispatch(preparation)

        try await store.deleteConversation(id: preparation.conversationID)
        let firstValue = try await store.fetchWorkItem(id: item.id)
        let firstRun = try XCTUnwrap(
            try XCTUnwrap(firstValue).dispatches.first { $0.id == preparation.dispatchID }
        )
        let firstRemovedAt = try XCTUnwrap(firstRun.conversationRemovedAt)

        try await store.deleteAll()

        let laterValue = try await store.fetchWorkItem(id: item.id)
        let laterRun = try XCTUnwrap(
            try XCTUnwrap(laterValue).dispatches.first { $0.id == preparation.dispatchID }
        )
        XCTAssertEqual(laterRun.conversationRemovedAt, firstRemovedAt,
                       "an erase-everything must not backdate history onto an older removal")
    }

    // MARK: - Board arrangement

    func testCardSizeRoundTripsAndAnUnknownStoredSizeReadsAsStandard() async throws {
        let store = ConversationStore(inMemory: true)
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

    func testResizingACardIsInvisibleToDivergenceAndToAnApprovedPreflight() async throws {
        let store = ConversationStore(inMemory: true)
        let item = try await store.createWorkItem(
            WorkItemDraft(content: WorkItemContent(
                title: "Sent brief",
                objective: "Answer exactly what was approved"
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
            "a per-material revision feeds preflight; resizing may not move it"
        )

        // The strongest statement of the same contract: a preflight approved
        // BEFORE the resize still sends afterwards.
        let snapshot = WorkBriefSnapshot(
            title: approved.content.title,
            objective: approved.content.objective,
            context: approved.content.context,
            desiredOutcome: approved.content.desiredOutcome,
            constraints: approved.content.constraints,
            dueAt: approved.content.dueAt,
            materials: [WorkMaterialSnapshot(record: approvedMaterial)]
        )
        let prepared = try await store.prepareWorkDispatch(WorkDispatchPreparation(
            workItemID: item.id,
            gatewayRef: "custom:v1:test",
            gatewayName: "Gateway",
            canonicalPrompt: "Approved packet",
            briefSnapshot: snapshot,
            expectedWorkItemRevision: approvedItemRevision,
            expectedMaterialVersions: [
                WorkboardMaterialVersion(id: material.id, revision: approvedMaterialRevision)
            ],
            sourceDevice: "test"
        ))
        XCTAssertNotNil(prepared.dispatch.dispatchedAt)
    }

    func testResizingWritesEveryDuplicateRowAndRefusesAnotherItemsMaterial() async throws {
        let store = ConversationStore(inMemory: true)
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
        let store = ConversationStore(inMemory: true)
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
                             "order decides the sent prompt, so a drag is a real change")
        XCTAssertNotEqual(
            WorkboardRevision.value(for: after.updatedAt),
            WorkboardRevision.value(for: before.updatedAt)
        )

        // Replaying the same arrangement is a no-op, so an idle board cannot
        // keep marking an already-sent brief as changed.
        let replayed = try await store.reorderWorkMaterials(
            itemID: item.id,
            orderedMaterialIDs: reordered
        )
        XCTAssertEqual(replayed.updatedAt, after.updatedAt)
    }

    func testReorderingWritesEveryDuplicateRowAndRefusesAnIncompleteOrStaleOrder() async throws {
        let store = ConversationStore(inMemory: true)
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

    func testDuplicatingACardKeepsTheArrangementItWasGiven() async throws {
        let store = ConversationStore(inMemory: true)
        let item = try await store.createWorkItem(
            WorkItemDraft(content: WorkItemContent(title: "Template"))
        )
        let material = try await store.addWorkMaterial(
            WorkMaterialDraft(kind: .note, title: "Wide note", textContent: "Body"),
            to: item.id
        )
        try await store.setWorkMaterialCardSize(.large, materialID: material.id, itemID: item.id)

        let copy = try await store.duplicateWorkItem(id: item.id)
        XCTAssertEqual(copy.materials.map(\.cardSize), [.large])
    }
}
