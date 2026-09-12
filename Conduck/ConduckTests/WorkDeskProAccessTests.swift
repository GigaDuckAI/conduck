// SPDX-License-Identifier: Apache-2.0

// Real isolated project persistence under changing verified-access snapshots.
// No test writes the shared subscription owner. Expiry requires a deliberate
// retained-project choice; neither reads, failed writes nor renewal archives
// anything. Already accepted replies and pending captured words are preserved.

import XCTest
@testable import Conduck

final class WorkDeskProAccessTests: XCTestCase {
    private let isolated = IsolatedWorkStores()

    override func tearDown() async throws {
        await isolated.cleanUp()
        try await super.tearDown()
    }

    func testVerifiedProAllowsCreationAndRestorationBeyondFreeAllowance() async throws {
        let access = ProjectAccessFixture(.init(hasProAccess: true))
        let store = isolated.make(proAccessProvider: { access.value })
        let projects = try await createProjects(6, store: store)
        try await store.applyWorkDeskMutation(.archiveProject(id: projects[0].id, isArchived: true))
        let restored = try await store.applyWorkDeskMutation(.archiveProject(id: projects[0].id, isArchived: false))
        XCTAssertEqual(restored.projects.filter { !$0.isArchived }.count, 6)
        access.set(.init(hasExpiredSubscription: true))
        do {
            try await store.applyWorkDeskMutation(.createProject(.init(title: "After expiry"), materialIDs: []))
            XCTFail("An expired grant must be rechecked at the write boundary")
        } catch { XCTAssertEqual(error as? WorkDeskStoreError, .activeProjectLimitReached) }
        let preserved = try await store.fetchWorkDeskOrganization()
        XCTAssertEqual(preserved, restored)
    }

    func testExpiredSubscriberExplicitlyChoosesThreeWithoutLosingMaterialsOrHistory() async throws {
        let access = ProjectAccessFixture(.init(hasProAccess: true))
        let store = isolated.make(proAccessProvider: { access.value })
        let projects = try await createProjects(5, store: store)
        let material = try await store.upsertDeskMaterial(.init(kind: .note, title: "Original", textContent: "Keep these words"), projectID: projects[4].id)
        let conversation = try await store.createConversation(backend: "openrouter", projectID: projects[4].id)
        let accepted = try await store.appendMessage(id: UUID(), role: "user", text: "Already accepted", conversationID: conversation.id, sourceDevice: "test")
        let before = try await store.fetchWorkDeskOrganization()
        access.set(.init(hasExpiredSubscription: true))
        let expiryRead = try await store.fetchWorkDeskOrganization()
        XCTAssertEqual(expiryRead, before, "Reading never arbitrarily picks or archives projects")
        do {
            _ = try await store.appendMessage(role: "user", text: "Unchosen new work", conversationID: conversation.id, sourceDevice: "test")
            XCTFail("A fresh scoped turn pauses pending the user's active-project choice")
        } catch { XCTAssertEqual(error as? WorkDeskStoreError, .projectSelectionRequired) }
        let replayed = try await store.appendMessage(id: accepted.id, role: "user", text: "Already accepted", conversationID: conversation.id, sourceDevice: "test")
        XCTAssertEqual(replayed.id, accepted.id)
        _ = try await store.appendMessage(role: "agent", text: "The accepted reply still arrives", conversationID: conversation.id, sourceDevice: "test")
        let kept = Set(projects.prefix(Constants.maxActiveWorkProjects).map(\.id))
        let confirmed = try await store.applyWorkDeskMutation(.selectFreeProjects(keeping: kept, expectedActiveProjectIDs: Set(projects.map(\.id))))
        XCTAssertEqual(Set(confirmed.projects.filter { !$0.isArchived }.map(\.id)), kept)
        XCTAssertEqual(confirmed.projects.count, projects.count)
        XCTAssertEqual(confirmed.placements, before.placements)
        let preserved = try await store.fetchWorkMaterial(id: material.id)
        let history = try await store.fetchMessages(for: conversation.id)
        XCTAssertEqual(preserved, material)
        XCTAssertEqual(history.count, 2)
        let newConversation = try await store.createConversation(backend: "openrouter", projectID: projects[0].id)
        XCTAssertEqual(newConversation.projectID, projects[0].id)
    }

    func testInvalidOrStaleChoiceAndRenewalNeverArchiveUnreviewedProjects() async throws {
        let access = ProjectAccessFixture(.init(hasProAccess: true))
        let store = isolated.make(proAccessProvider: { access.value })
        let projects = try await createProjects(5, store: store)
        let all = Set(projects.map(\.id))
        access.set(.init(hasExpiredSubscription: true))
        let before = try await store.fetchWorkDeskOrganization()
        for (keeping, reviewed) in [(all, all), (Set([UUID()]), all), (Set([projects[0].id]), Set(projects.dropLast().map(\.id)))] {
            do {
                try await store.applyWorkDeskMutation(.selectFreeProjects(keeping: keeping, expectedActiveProjectIDs: reviewed))
                XCTFail("Only a valid choice over the exact reviewed set may archive")
            } catch { XCTAssertEqual(error as? WorkDeskStoreError, .projectSelectionChanged) }
            let after = try await store.fetchWorkDeskOrganization()
            XCTAssertEqual(after, before)
        }
        access.set(.init(hasProAccess: true))
        do {
            try await store.applyWorkDeskMutation(.selectFreeProjects(keeping: [], expectedActiveProjectIDs: all))
            XCTFail("A choice opened before renewal must not archive anything after renewal")
        } catch { XCTAssertEqual(error as? WorkDeskStoreError, .projectSelectionChanged) }
        let renewed = try await store.fetchWorkDeskOrganization()
        XCTAssertEqual(renewed, before)
    }

    func testFreeImportedOverCapCollectionKeepsContentButRequiresExplicitActiveChoice() async throws {
        let access = ProjectAccessFixture(.init(hasProAccess: true))
        let store = isolated.make(proAccessProvider: { access.value })
        let projects = try await createProjects(5, store: store)
        let conversation = try await store.createConversation(backend: "openrouter", projectID: projects[4].id)
        let captured = try await store.upsertDeskMaterial(.init(kind: .note, title: "Existing workflow"), projectID: projects[4].id)
        let before = try await store.fetchWorkDeskOrganization()
        // Account changes and cold launches cannot bypass the allowance by
        // losing access to previous purchase history. No content is removed.
        access.set(.init())
        do {
            _ = try await store.appendMessage(role: "user", text: "Unchosen new work", conversationID: conversation.id, sourceDevice: "test")
            XCTFail("Losing purchase history cannot grant unlimited project activity")
        } catch { XCTAssertEqual(error as? WorkDeskStoreError, .projectSelectionRequired) }
        let preserved = try await store.fetchWorkDeskOrganization()
        XCTAssertEqual(preserved, before)
        XCTAssertEqual(preserved.placements[captured.id]?.projectID, projects[4].id)
        let renamed = try await store.applyWorkDeskMutation(.updateProject(id: projects[4].id,
            title: "Still editable", brief: "Preserved context", preferredGatewayRef: nil))
        XCTAssertEqual(renamed.projects.first { $0.id == projects[4].id }?.title, "Still editable")
        let kept = Set(projects.prefix(3).map(\.id))
        let selected = try await store.applyWorkDeskMutation(.selectFreeProjects(keeping: kept, expectedActiveProjectIDs: Set(projects.map(\.id))))
        XCTAssertEqual(Set(selected.projects.filter { !$0.isArchived }.map(\.id)), kept)
    }

    func testExpiryDuringVoicePublicationKeepsWordsInAllMaterialsAndReceiptOnReplay() async throws {
        let access = ProjectAccessFixture(.init(hasProAccess: true))
        let store = isolated.make(proAccessProvider: { access.value })
        let projects = try await createProjects(4, store: store)
        access.set(.init(hasExpiredSubscription: true))
        let captureID = UUID()
        let outcome = try await WorkVoiceCaptureCoordinator.publishTranscript("Keep pending words", forCapture: captureID,
            createdAt: Date(), projectID: projects[0].id, store: store)
        XCTAssertEqual(outcome, .wordsPublishedInAllMaterials(materialID: captureID))
        let replay = try await WorkVoiceCaptureCoordinator.publishTranscript("Keep pending words", forCapture: captureID,
            createdAt: Date(), projectID: projects[0].id, store: store)
        XCTAssertEqual(replay, outcome)
        let snapshot = try await store.fetchWorkDeskOrganization()
        XCTAssertNil(snapshot.placements[captureID])
        XCTAssertEqual(snapshot.projects.filter { !$0.isArchived }.count, 4)
    }

    func testReplyFilesArrivingDuringExpirySelectionStillJoinTheirOriginalProject() async throws {
        let access = ProjectAccessFixture(.init(hasProAccess: true))
        let store = isolated.make(proAccessProvider: { access.value })
        let projects = try await createProjects(4, store: store)
        let conversation = try await store.createConversation(backend: "hermes", projectID: projects[3].id)
        access.set(.init(hasExpiredSubscription: true))
        let bytes = Data("Late output".utf8)
        _ = try await store.appendMessage(role: "agent", text: "Result", conversationID: conversation.id, sourceDevice: "test",
            attachments: [.init(mimeType: "text/plain", filename: "result.txt", data: bytes, thumbnailData: nil,
                width: 0, height: 0, byteSize: bytes.count, sequence: 0)])
        await store.reconcileProjectResults()
        let desk = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        let result = try XCTUnwrap(desk?.materials.first)
        let payload = try await store.loadWorkMaterialPayload(id: result.id)
        let snapshot = try await store.fetchWorkDeskOrganization()
        XCTAssertEqual(payload, bytes)
        XCTAssertEqual(snapshot.placements[result.id]?.projectID, projects[3].id)
        XCTAssertTrue(snapshot.projects.allSatisfy { !$0.isArchived })
    }

    @MainActor
    func testAnotherWindowConsumingSlotPresentsTypedPaywallWithoutDiscardingOpenEditor() async throws {
        let access = ProjectAccessFixture(.init())
        let store = isolated.make(proAccessProvider: { access.value })
        _ = try await createProjects(2, store: store)
        let organization = WorkDeskOrganization(store: store, proAccessProvider: { access.value })
        await organization.reload()
        let workspace = WorkDeskWorkspaceState(organization: organization)
        workspace.beginProject(position: .init(x: 40, y: 70))
        workspace.editorTitle = "Pending project name"
        let editor = try XCTUnwrap(workspace.projectEditor)
        try await store.applyWorkDeskMutation(.createProject(.init(title: "Other window"), materialIDs: []))
        let denied = await organization.createProject(title: workspace.editorTitle, position: editor.position)
        XCTAssertNil(denied)
        XCTAssertTrue(organization.projectLimitRequested)
        XCTAssertEqual(workspace.editorTitle, "Pending project name")
        XCTAssertEqual(workspace.projectEditor?.id, editor.id)
        organization.projectLimitRequested = false
        access.set(.init(hasProAccess: true))
        let saved = await organization.createProject(title: workspace.editorTitle, position: editor.position)
        XCTAssertNotNil(saved)
        XCTAssertEqual(organization.projects.count, 4)
    }

    @MainActor
    func testPaywallCancellationPreservesSelectionAndVerifiedPurchaseResumesEditorOnly() async throws {
        let access = ProjectAccessFixture(.init())
        let store = isolated.make(proAccessProvider: { access.value })
        _ = try await createProjects(3, store: store)
        let organization = WorkDeskOrganization(store: store, proAccessProvider: { access.value })
        await organization.reload()
        let workspace = WorkDeskWorkspaceState(organization: organization)
        let selected = UUID()
        workspace.selectedIDs = [selected]
        let position = WorkDeskPoint(x: 230, y: 170)
        workspace.beginProject(materialIDs: [selected], position: position)
        XCTAssertTrue(organization.projectLimitRequested)
        organization.projectLimitRequested = false
        workspace.projectLimitDidDismiss()
        XCTAssertNil(workspace.projectEditor)
        XCTAssertEqual(workspace.selectedIDs, [selected])
        workspace.beginProject(materialIDs: [selected], position: position)
        access.set(.init(hasProAccess: true))
        organization.projectLimitRequested = false
        workspace.projectLimitDidDismiss()
        XCTAssertEqual(workspace.projectEditor?.materialIDs, [selected])
        XCTAssertEqual(workspace.projectEditor?.position, position)
        XCTAssertEqual(organization.projects.count, 3, "Purchase itself creates no project")
        workspace.editorTitle = "My draft"
        organization.requestProjectLimit()
        organization.projectLimitRequested = false
        workspace.projectLimitDidDismiss()
        XCTAssertEqual(workspace.editorTitle, "My draft")
    }

    func testArchivedProjectsRejectNewTurnsOnBothPlansAndPreserveAcceptedDelivery() async throws {
        for hasPro in [false, true] {
            let store = isolated.make(proAccessProvider: { .init(hasProAccess: hasPro) })
            let project = try await createProjects(1, store: store)[0]
            let conversation = try await store.createConversation(backend: "openrouter", projectID: project.id)
            let accepted = try await store.appendMessage(id: UUID(), role: "user", text: "Accepted before archive",
                conversationID: conversation.id, sourceDevice: "test", status: "sending")
            try await store.applyWorkDeskMutation(.archiveProject(id: project.id, isArchived: true))
            do {
                _ = try await store.appendMessage(role: "user", text: "Another project turn",
                    conversationID: conversation.id, sourceDevice: "test")
                XCTFail("An archived project must be restored before accepting new work on either plan")
            } catch { XCTAssertEqual(error as? WorkDeskStoreError, .projectArchived) }
            let replay = try await store.appendMessage(id: accepted.id, role: "user", text: "Accepted before archive",
                conversationID: conversation.id, sourceDevice: "test")
            XCTAssertEqual(replay, accepted, "Duplicate delivery remains idempotent after archive")
            _ = try await store.appendMessage(role: "agent", text: "Already dispatched reply",
                conversationID: conversation.id, sourceDevice: "test")
            let history = try await store.fetchMessages(for: conversation.id)
            XCTAssertEqual(history.map(\.text), ["Accepted before archive", "Already dispatched reply"])
            try await store.applyWorkDeskMutation(.archiveProject(id: project.id, isArchived: false))
            _ = try await store.appendMessage(role: "user", text: "Restored project turn",
                conversationID: conversation.id, sourceDevice: "test")
        }
    }

    func testArchivedRetryKeepsFailedAttemptIntactUntilProjectIsRestored() async throws {
        let store = isolated.make()
        let project = try await createProjects(1, store: store)[0]
        let conversation = try await store.createConversation(backend: "openrouter", projectID: project.id)
        let message = try await store.appendMessage(role: "user", text: "Previously failed",
            conversationID: conversation.id, sourceDevice: "test", status: "sending")
        try await store.updateStatus(messageID: message.id, status: "failed")
        let before = try await store.fetchMessages(for: conversation.id)
        try await store.applyWorkDeskMutation(.archiveProject(id: project.id, isArchived: true))
        let denied = await store.beginRetry(messageID: message.id)
        XCTAssertFalse(denied)
        let after = try await store.fetchMessages(for: conversation.id)
        XCTAssertEqual(after, before, "Refusal must not mint an attempt or clear the failed state")
        do {
            try await store.validateConversationProjectActivity(conversationID: conversation.id)
            XCTFail("The retry caller needs the restore remedy")
        } catch { XCTAssertEqual(error as? WorkDeskStoreError, .projectArchived) }
        try await store.applyWorkDeskMutation(.archiveProject(id: project.id, isArchived: false))
        let claimed = await store.beginRetry(messageID: message.id)
        XCTAssertTrue(claimed)
        let claimedMessages = try await store.fetchMessages(for: conversation.id)
        let retried = try XCTUnwrap(claimedMessages.first)
        XCTAssertEqual(retried.status, "sending")
        XCTAssertNotEqual(retried.deliveryAttemptID, before.first?.deliveryAttemptID)
    }

    func testFreeProjectChoicePausesExplicitRetriesUntilSelectionOrRenewal() async throws {
        for renew in [false, true] {
            let access = ProjectAccessFixture(.init(hasProAccess: true))
            let store = isolated.make(proAccessProvider: { access.value })
            let projects = try await createProjects(4, store: store)
            let conversation = try await store.createConversation(backend: "openrouter", projectID: projects[0].id)
            let message = try await store.appendMessage(role: "user", text: "Try again later",
                conversationID: conversation.id, sourceDevice: "test", status: "sending")
            try await store.updateStatus(messageID: message.id, status: "failed")
            let before = try await store.fetchMessages(for: conversation.id)
            access.set(.init())
            let denied = await store.beginRetry(messageID: message.id)
            XCTAssertFalse(denied)
            let after = try await store.fetchMessages(for: conversation.id)
            XCTAssertEqual(after, before)
            do {
                try await store.validateConversationProjectActivity(conversationID: conversation.id)
                XCTFail("The retry caller needs the active-selection remedy")
            } catch { XCTAssertEqual(error as? WorkDeskStoreError, .projectSelectionRequired) }
            if renew { access.set(.init(hasProAccess: true)) }
            else {
                try await store.applyWorkDeskMutation(.selectFreeProjects(keeping: [projects[0].id],
                    expectedActiveProjectIDs: Set(projects.map(\.id))))
            }
            let claimed = await store.beginRetry(messageID: message.id)
            XCTAssertTrue(claimed)
        }
    }

    private func createProjects(_ count: Int, store: ConversationStore) async throws -> [WorkDeskProjectRecord] {
        let projects = (0..<count).map { WorkDeskProjectRecord(title: "Project \($0)") }
        for project in projects { try await store.applyWorkDeskMutation(.createProject(project, materialIDs: [])) }
        return projects
    }
}

private final class ProjectAccessFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var snapshot: ProAccessSnapshot
    init(_ snapshot: ProAccessSnapshot) { self.snapshot = snapshot }
    var value: ProAccessSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return snapshot
    }
    func set(_ snapshot: ProAccessSnapshot) {
        lock.lock()
        defer { lock.unlock() }
        self.snapshot = snapshot
    }
}
