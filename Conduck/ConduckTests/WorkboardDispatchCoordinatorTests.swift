// SPDX-License-Identifier: Apache-2.0

// ConduckTests
// WorkboardDispatchCoordinatorTests.swift
//
// Contracts at the Workboard's final send boundary. Network transport is
// exercised by the existing conversation suites; these tests lock the
// optimistic token, the safe content-free refusal copy, and the refusals a
// send can reach without transport — above all the preview/dispatch prompt
// equality guard, which refuses a brief whenever the two prompt derivations
// disagree by a single byte.

import XCTest
@testable import Conduck

final class WorkboardDispatchCoordinatorTests: XCTestCase {
    private let briefTitle = "Courier comparison"
    private let briefObjective = "Compare price and EU coverage."

    private func makeItem(in store: ConversationStore) async throws -> WorkItemRecord {
        try await store.createWorkItem(WorkItemDraft(content: WorkItemContent(
            title: briefTitle,
            objective: briefObjective
        )))
    }

    /// A keyless Hermes is send-able on its URL alone, so the roster check holds
    /// on an unsigned run with no Keychain.
    private func makeCoordinator(
        store: ConversationStore,
        configuredGateway: Bool
    ) -> WorkboardDispatchCoordinator {
        let seed: [String: Any] = configuredGateway
            ? [
                "remoteAgent.url.hermes": "https://hermes.example.test:8642",
                "remoteAgent.authScheme.hermes": "none",
            ]
            : [:]
        return WorkboardDispatchCoordinator(
            store: store,
            settings: SettingsManager(dependencies: .inMemory(
                defaults: InMemoryDefaultsStore(seed: seed)
            ))
        )
    }

    private func previewPrompt(
        item: WorkItemRecord,
        materials: [WorkMaterialRecord]
    ) -> String {
        WorkboardPromptComposer.compose(
            item: WorkboardItemSnapshot(
                id: item.id,
                title: item.content.title,
                objective: item.content.objective,
                context: item.content.context,
                desiredResult: item.content.desiredOutcome,
                constraints: item.content.constraints,
                reviewBy: item.content.dueAt,
                materials: materials.map { WorkBriefFixtures.previewSnapshot($0) }
            ),
            includedMaterialIDs: Set(materials.map(\.id))
        )
    }

    func testReplyCorrelationUsesCanonicalIDTieBreakAndNextUserBoundary() throws {
        let timestamp = Date(timeIntervalSinceReferenceDate: 123)
        let workUserID = try XCTUnwrap(UUID(uuidString: "80000000-0000-0000-0000-000000000000"))
        let earlierAgentID = try XCTUnwrap(UUID(uuidString: "70000000-0000-0000-0000-000000000000"))
        let replyID = try XCTUnwrap(UUID(uuidString: "90000000-0000-0000-0000-000000000000"))
        let nextUserID = try XCTUnwrap(UUID(uuidString: "A0000000-0000-0000-0000-000000000000"))
        let laterAgentID = try XCTUnwrap(UUID(uuidString: "B0000000-0000-0000-0000-000000000000"))

        let messages = [
            WorkDispatchMessageFact(id: laterAgentID, role: "agent", createdAt: timestamp),
            WorkDispatchMessageFact(id: nextUserID, role: "user", createdAt: timestamp),
            WorkDispatchMessageFact(id: replyID, role: "agent", createdAt: timestamp),
            WorkDispatchMessageFact(id: earlierAgentID, role: "agent", createdAt: timestamp),
            WorkDispatchMessageFact(id: workUserID, role: "user", createdAt: timestamp),
        ]

        XCTAssertEqual(
            WorkDispatchReplyCorrelation.firstReplyID(
                workUserMessageID: workUserID,
                dispatchedAt: timestamp,
                messages: messages
            ),
            replyID,
            "an agent ordered before Work is ignored and the next user closes the reply window"
        )
    }

    func testRevisionDetectsSubMillisecondChanges() {
        let date = Date(timeIntervalSinceReferenceDate: 123.456_789)
        XCTAssertEqual(
            WorkboardRevision.value(for: date),
            Int64(bitPattern: date.timeIntervalSinceReferenceDate.bitPattern)
        )
        XCTAssertNotEqual(
            WorkboardRevision.value(for: date.addingTimeInterval(0.000_1)),
            WorkboardRevision.value(for: date)
        )
    }

    func testDispatchRefusalsDoNotEchoContentOrDestinations() {
        let errors: [WorkboardDispatchError] = [
            .itemChanged,
            .gatewayUnavailable,
            .materialChanged,
            .materialUnavailable,
            .fileServerRequired,
            .fileTransferFailed,
            .unsupportedMaterial,
            .previewMismatch,
            .alreadyStarted,
        ]
        for error in errors {
            let copy = error.localizedDescription
            XCTAssertFalse(copy.isEmpty)
            XCTAssertFalse(copy.contains("https://"))
            XCTAssertFalse(copy.contains("token"))
        }
    }

    // MARK: - Preview / dispatch prompt equality

    /// The send boundary compares the prompt the person approved against the one
    /// rebuilt from the store. Both derivations must agree on every material
    /// shape, or a routine attachment becomes an unexplainable, permanent
    /// refusal that reopening Review & Send cannot clear.
    func testPreviewAndDispatchDeriveByteIdenticalPromptsForEveryMaterialShape() {
        let fixtures: [(String, WorkMaterialRecord)] = [
            (
                "zero-byte file carrying a mime type",
                WorkBriefFixtures.record(
                    kind: .file,
                    filename: "empty.txt",
                    mimeType: "text/plain",
                    byteSize: 0
                )
            ),
            (
                "zero-byte image",
                WorkBriefFixtures.record(
                    kind: .image,
                    filename: "empty.png",
                    mimeType: "image/png",
                    byteSize: 0
                )
            ),
            (
                "blank title falling back to the filename",
                WorkBriefFixtures.record(
                    kind: .file,
                    title: "",
                    filename: "rates.pdf",
                    mimeType: "application/pdf",
                    byteSize: 4_096
                )
            ),
            (
                "whitespace-only title falling back to the link host",
                WorkBriefFixtures.record(
                    kind: .link,
                    title: "  \n ",
                    urlString: "https://example.com/pricing",
                    hasPayload: false
                )
            ),
            (
                "whitespace-only title with nothing else to name it",
                WorkBriefFixtures.record(kind: .note, title: " ", hasPayload: false)
            ),
            (
                "file row that still carries a cached extract",
                WorkBriefFixtures.record(
                    kind: .file,
                    title: "notes.txt",
                    textContent: "Zone based express service",
                    mimeType: "text/plain",
                    byteSize: 26
                )
            ),
            (
                "unknown kind with payload evidence",
                WorkBriefFixtures.record(kind: .unknown, title: "Mystery", hasPayload: true)
            ),
            (
                "unknown kind with no payload evidence",
                WorkBriefFixtures.record(kind: .unknown, title: "Mystery", hasPayload: false)
            ),
        ]

        for (shape, record) in fixtures {
            let dispatched = WorkBriefPromptBuilder.build(
                workItemID: WorkBriefFixtures.workItemID,
                title: briefTitle,
                objective: briefObjective,
                context: "",
                constraints: "",
                desiredResult: "",
                reviewBy: nil,
                materials: [WorkBriefMaterialPacket(record: record)]
            ).canonicalPrompt
            let previewed = WorkboardPromptComposer.compose(
                item: WorkboardItemSnapshot(
                    id: WorkBriefFixtures.workItemID,
                    title: briefTitle,
                    objective: briefObjective,
                    materials: [WorkBriefFixtures.previewSnapshot(record)]
                ),
                includedMaterialIDs: [record.id]
            )

            XCTAssertEqual(dispatched, previewed, "preview and dispatch disagree on a \(shape)")
            XCTAssertFalse(dispatched.contains("0 bytes"),
                           "an empty file has no size worth printing (\(shape))")
        }
    }

    // MARK: - Refusals reachable without transport

    func testDispatchRefusesAGatewayThisDeviceCannotSendThrough() async throws {
        let store = ConversationStore(inMemory: true)
        let item = try await makeItem(in: store)
        let coordinator = makeCoordinator(store: store, configuredGateway: false)
        let request = WorkboardDispatchRequest(
            itemID: item.id,
            expectedRevision: WorkboardRevision.value(for: item.updatedAt),
            gatewayRef: .custom(UUID()),
            prompt: previewPrompt(item: item, materials: []),
            includedMaterialIDs: []
        )

        do {
            _ = try await coordinator.dispatch(request, gatewayName: "Never configured")
            XCTFail("An unconfigured gateway must refuse before anything is written")
        } catch let error as WorkboardDispatchError {
            XCTAssertEqual(error, .gatewayUnavailable)
        }

        let untouchedValue = try await store.fetchWorkItem(id: item.id)
        let untouched = try XCTUnwrap(untouchedValue)
        XCTAssertTrue(untouched.dispatches.isEmpty, "a refusal before transport writes no run")
    }

    func testDispatchRefusesAPromptThatDriftedFromTheApprovedPreview() async throws {
        let store = ConversationStore(inMemory: true)
        let item = try await makeItem(in: store)
        let coordinator = makeCoordinator(store: store, configuredGateway: true)
        let request = WorkboardDispatchRequest(
            itemID: item.id,
            expectedRevision: WorkboardRevision.value(for: item.updatedAt),
            gatewayRef: .builtin(.hermes),
            prompt: "Title\nA brief the person never approved",
            includedMaterialIDs: []
        )

        do {
            _ = try await coordinator.dispatch(request, gatewayName: "Hermes")
            XCTFail("Only the exact approved prompt may be sent")
        } catch let error as WorkboardDispatchError {
            XCTAssertEqual(error, .previewMismatch)
        }

        let untouchedValue = try await store.fetchWorkItem(id: item.id)
        let untouched = try XCTUnwrap(untouchedValue)
        XCTAssertTrue(untouched.dispatches.isEmpty)
    }

    /// Idempotency lives entirely in the store: a dispatch id that already owns
    /// a run is refused, so a replayed press can never authorize a second send.
    func testDispatchRefusesAReplayedDispatchIdentifier() async throws {
        let store = ConversationStore(inMemory: true)
        let item = try await makeItem(in: store)
        let dispatchID = UUID()
        _ = try await store.prepareWorkDispatch(WorkDispatchPreparation(
            dispatchID: dispatchID,
            workItemID: item.id,
            gatewayRef: "custom:v1:test",
            gatewayName: "Gateway",
            canonicalPrompt: "Already sent",
            briefSnapshot: WorkBriefSnapshot(
                title: item.content.title,
                objective: item.content.objective,
                context: item.content.context,
                desiredOutcome: item.content.desiredOutcome,
                constraints: item.content.constraints,
                dueAt: item.content.dueAt,
                materials: []
            ),
            expectedWorkItemRevision: WorkboardRevision.value(for: item.updatedAt),
            expectedMaterialVersions: [],
            sourceDevice: "test"
        ))

        let currentValue = try await store.fetchWorkItem(id: item.id)
        let current = try XCTUnwrap(currentValue)
        let coordinator = makeCoordinator(store: store, configuredGateway: true)
        let request = WorkboardDispatchRequest(
            id: dispatchID,
            itemID: item.id,
            expectedRevision: WorkboardRevision.value(for: current.updatedAt),
            gatewayRef: .builtin(.hermes),
            prompt: previewPrompt(item: current, materials: []),
            includedMaterialIDs: []
        )

        do {
            _ = try await coordinator.dispatch(request, gatewayName: "Hermes")
            XCTFail("A replayed dispatch id must never start a second run")
        } catch let error as WorkboardDispatchError {
            XCTAssertEqual(error, .alreadyStarted)
        }

        let afterValue = try await store.fetchWorkItem(id: item.id)
        let after = try XCTUnwrap(afterValue)
        XCTAssertEqual(after.dispatches.count, 1, "the replay added no run")
    }

    /// The end-to-end proof for the equality suite above: an empty image is a
    /// legitimate stored material, and the send must get past the prompt guard
    /// and fail on the bytes themselves.
    func testAZeroByteImageReachesTheAttachmentLaneRatherThanThePromptGuard() async throws {
        let store = ConversationStore(inMemory: true)
        let item = try await makeItem(in: store)
        let material = try await store.addWorkMaterial(
            WorkMaterialDraft(
                kind: .image,
                filename: "empty.png",
                mimeType: "image/png",
                payload: Data()
            ),
            to: item.id
        )
        XCTAssertEqual(material.byteSize, 0)
        XCTAssertEqual(material.availability, .availableLocally)

        let currentValue = try await store.fetchWorkItem(id: item.id)
        let current = try XCTUnwrap(currentValue)
        let coordinator = makeCoordinator(store: store, configuredGateway: true)
        let request = WorkboardDispatchRequest(
            itemID: item.id,
            expectedRevision: WorkboardRevision.value(for: current.updatedAt),
            gatewayRef: .builtin(.hermes),
            prompt: previewPrompt(item: current, materials: [material]),
            includedMaterialIDs: [material.id],
            includedMaterialVersions: [WorkboardMaterialVersion(
                id: material.id,
                revision: WorkboardRevision.value(for: material.updatedAt)
            )]
        )

        do {
            _ = try await coordinator.dispatch(request, gatewayName: "Hermes")
            XCTFail("Empty bytes cannot become an image attachment")
        } catch let error as WorkboardDispatchError {
            XCTAssertEqual(
                error,
                .unsupportedMaterial,
                "an empty file's size is not a preview mismatch — the send must reach the attachment lane"
            )
        }

        let afterValue = try await store.fetchWorkItem(id: item.id)
        let after = try XCTUnwrap(afterValue)
        XCTAssertTrue(after.dispatches.isEmpty, "a pre-transport refusal writes no run")
    }
}
