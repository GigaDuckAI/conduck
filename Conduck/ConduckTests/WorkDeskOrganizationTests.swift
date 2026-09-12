// SPDX-License-Identifier: Apache-2.0

// ConduckTests
// WorkDeskOrganizationTests.swift
//
// Real isolated-store coverage of the organization boundary: grouping and
// positioning never move captured materials, stale requests cannot invent
// projects, and a project deletion keeps every captured byte. Delayed read
// tests exercise the observable controller rather than assuming await order.

import XCTest
@testable import Conduck

final class WorkDeskOrganizationTests: XCTestCase {
    private let isolated = IsolatedWorkStores()

    override func tearDown() async throws {
        await isolated.cleanUp()
        try await super.tearDown()
    }

    func testProjectMembershipPositionPinAndBriefRoundTripWithoutEditingCapture() async throws {
        let store = isolated.make()
        let material = try await capture("First thought", in: store)
        let project = WorkDeskProjectRecord(title: "An idea", brief: "Explore the possibilities")
        try await store.applyWorkDeskMutation(.createProject(project, materialIDs: [material.id]))
        try await store.applyWorkDeskMutation(.moveMaterial(id: material.id, position: .init(x: 80, y: 120)))
        try await store.applyWorkDeskMutation(.pinMaterial(id: material.id, isPinned: true))
        try await store.applyWorkDeskMutation(.updateProject(
            id: project.id, title: "A better idea", brief: "Decide what to make next", preferredGatewayRef: "openrouter"
        ))
        try await store.applyWorkDeskMutation(.moveProject(id: project.id, position: .init(x: 360, y: 220)))
        try await store.applyWorkDeskMutation(.pinProject(id: project.id, isPinned: true))

        let snapshot = try await store.fetchWorkDeskOrganization()
        XCTAssertEqual(snapshot.projects.count, 1)
        XCTAssertEqual(snapshot.projects.first?.title, "A better idea")
        XCTAssertEqual(snapshot.projects.first?.brief, "Decide what to make next")
        XCTAssertEqual(snapshot.projects.first?.preferredGatewayRef, "openrouter")
        XCTAssertEqual(snapshot.projects.first?.position, WorkDeskPoint(x: 360, y: 220))
        XCTAssertEqual(snapshot.projects.first?.isPinned, true)
        XCTAssertEqual(snapshot.placements[material.id]?.projectID, project.id)
        XCTAssertEqual(snapshot.placements[material.id]?.position, WorkDeskPoint(x: 80, y: 120))
        XCTAssertEqual(snapshot.placements[material.id]?.isPinned, true)
        let unchanged = try await store.fetchWorkMaterial(id: material.id)
        XCTAssertEqual(unchanged, material, "organization is not a content revision or a change of owner")

        let fresh = try await capture("Captured from a shortcut later", in: store)
        let afterCapture = try await store.fetchWorkDeskOrganization()
        XCTAssertNil(afterCapture.placements[fresh.id], "capture remains independent and lands unfiled")
        XCTAssertEqual(afterCapture.placements, snapshot.placements)
        XCTAssertEqual(fresh.workItemID, Constants.workboardDeskItemID)
    }

    func testReassignmentResetsCoordinatesButKeepsPinAndPayload() async throws {
        let store = isolated.make()
        let material = try await store.upsertDeskMaterial(WorkMaterialDraft(
            kind: .file, title: "Notes", filename: "notes.txt", mimeType: "text/plain",
            payload: Data("The original private bytes".utf8)
        ))
        let a = WorkDeskProjectRecord(title: "First")
        let b = WorkDeskProjectRecord(title: "Second")
        try await store.applyWorkDeskMutation(.createProject(a, materialIDs: [material.id]))
        try await store.applyWorkDeskMutation(.createProject(b, materialIDs: []))
        try await store.applyWorkDeskMutation(.moveMaterial(id: material.id, position: .init(x: 50, y: 50)))
        try await store.applyWorkDeskMutation(.pinMaterial(id: material.id, isPinned: true))
        let reassigned = try await store.applyWorkDeskMutation(.assign(materialIDs: [material.id], projectID: b.id))
        XCTAssertNil(reassigned.placements[material.id]?.position)
        XCTAssertEqual(reassigned.placements[material.id]?.isPinned, true)
        let deleted = try await store.applyWorkDeskMutation(.deleteProject(id: b.id))
        XCTAssertNil(deleted.placements[material.id]?.projectID)
        XCTAssertNil(deleted.placements[material.id]?.position)
        XCTAssertEqual(deleted.projects.map(\.id), [a.id])
        XCTAssertEqual(deleted.deletedProjectIDs, [b.id])
        let reloaded = try await store.fetchWorkDeskOrganization()
        XCTAssertEqual(reloaded.deletedProjectIDs, [b.id], "later windows receive durable deletion evidence")
        let payload = try await store.loadWorkMaterialPayload(id: material.id)
        XCTAssertEqual(payload, Data("The original private bytes".utf8))
        let preserved = try await store.fetchWorkMaterial(id: material.id)
        XCTAssertEqual(preserved, material)

        do {
            try await store.applyWorkDeskMutation(.updateProject(id: b.id, title: "Stale editor", brief: "", preferredGatewayRef: nil))
            XCTFail("a deleted project cannot be recreated by a stale editor")
        } catch { XCTAssertEqual(error as? WorkDeskStoreError, .projectNotFound) }
        do {
            try await store.applyWorkDeskMutation(.assign(materialIDs: [material.id], projectID: b.id))
            XCTFail("a deleted destination cannot take new members")
        } catch { XCTAssertEqual(error as? WorkDeskStoreError, .projectNotFound) }
    }

    func testCreateAndAssignValidateWholeSelectionBeforeWriting() async throws {
        let store = isolated.make()
        let material = try await capture("Existing", in: store)
        let project = WorkDeskProjectRecord(title: "Do not leave an empty shell")
        do {
            try await store.applyWorkDeskMutation(.createProject(project, materialIDs: [material.id, UUID()]))
            XCTFail("the stale selection must be refused atomically")
        } catch { XCTAssertEqual(error as? WorkDeskStoreError, .materialNotFound) }
        let empty = try await store.fetchWorkDeskOrganization()
        XCTAssertTrue(empty.projects.isEmpty)
        XCTAssertTrue(empty.placements.isEmpty)
        try await store.applyWorkDeskMutation(.createProject(project, materialIDs: []))
        do {
            try await store.applyWorkDeskMutation(.assign(materialIDs: [material.id, UUID()], projectID: project.id))
            XCTFail("one valid item must not be assigned when another went away")
        } catch { XCTAssertEqual(error as? WorkDeskStoreError, .materialNotFound) }
        let unassigned = try await store.fetchWorkDeskOrganization()
        XCTAssertNil(unassigned.placements[material.id])

        try await store.deleteWorkMaterial(id: material.id)
        do {
            try await store.applyWorkDeskMutation(.moveMaterial(id: material.id, position: .init(x: 1, y: 2)))
            XCTFail("a stale drag cannot create placement for a removed material")
        } catch { XCTAssertEqual(error as? WorkDeskStoreError, .materialNotFound) }
    }

    func testSimultaneousFirstGesturesPreserveBothIntents() async throws {
        let store = isolated.make()
        let material = try await capture("Multiwindow", in: store)
        async let move = store.applyWorkDeskMutation(.moveMaterial(id: material.id, position: .init(x: 45, y: 75)))
        async let pin = store.applyWorkDeskMutation(.pinMaterial(id: material.id, isPinned: true))
        _ = try await (move, pin)
        let snapshot = try await store.fetchWorkDeskOrganization()
        XCTAssertEqual(snapshot.placements[material.id]?.position, WorkDeskPoint(x: 45, y: 75))
        XCTAssertEqual(snapshot.placements[material.id]?.isPinned, true)
    }

    func testInitialSlotSeedingIsPersistentAndCannotOverwriteANewerMoveOrMembership() async throws {
        let store = isolated.make()
        let one = try await capture("First", in: store)
        let two = try await capture("Second", in: store)
        let project = WorkDeskProjectRecord(title: "A new project")
        try await store.applyWorkDeskMutation(.createProject(project, materialIDs: []))
        let seed = WorkDeskMutation.seedPositions(materials: [
            .init(materialID: one.id, projectID: nil, position: .init(x: 40, y: 80)),
            .init(materialID: two.id, projectID: nil, position: .init(x: 240, y: 80)),
            .init(materialID: UUID(), projectID: nil, position: .init(x: 900, y: 900)),
        ], projects: [project.id: .init(x: 500, y: 80), UUID(): .init(x: 900, y: 900)])
        let seeded = try await store.applyWorkDeskMutation(seed)
        XCTAssertEqual(seeded.placements.count, 2)
        XCTAssertEqual(seeded.placements[one.id]?.position, WorkDeskPoint(x: 40, y: 80))
        XCTAssertEqual(seeded.projects.first?.position, WorkDeskPoint(x: 500, y: 80))
        let repeated = try await store.applyWorkDeskMutation(seed)
        XCTAssertEqual(repeated, seeded, "an unchanged layout pass is not a write or activity stamp")

        try await store.applyWorkDeskMutation(.moveMaterial(id: one.id, position: .init(x: 111, y: 222)))
        try await store.applyWorkDeskMutation(.assign(materialIDs: [two.id], projectID: project.id))
        let late = try await store.applyWorkDeskMutation(seed)
        XCTAssertEqual(late.placements[one.id]?.position, WorkDeskPoint(x: 111, y: 222))
        XCTAssertNil(late.placements[two.id]?.position, "a slot planned on Desk cannot place a newly grouped item")
        XCTAssertEqual(late.placements[two.id]?.projectID, project.id)
        let grouped = try await store.applyWorkDeskMutation(.seedPositions(materials: [
            .init(materialID: two.id, projectID: project.id, position: .init(x: 40, y: 80)),
        ], projects: [:]))
        XCTAssertEqual(grouped.placements[two.id]?.position, WorkDeskPoint(x: 40, y: 80))
    }

    func testStaleProjectEditorCannotOverwriteACommittedRevision() async throws {
        let store = isolated.make()
        let project = WorkDeskProjectRecord(title: "Original")
        let created = try await store.applyWorkDeskMutation(.createProject(project, materialIDs: []))
        let first = try XCTUnwrap(created.projects.first)
        let updated = try await store.applyWorkDeskMutation(.updateProject(
            id: project.id, title: "Peer's title", brief: "Peer's brief", preferredGatewayRef: "hermes",
            expectedUpdatedAt: first.updatedAt
        ))
        do {
            try await store.applyWorkDeskMutation(.updateProject(
                id: project.id, title: "Stale title", brief: "My stale brief", preferredGatewayRef: "openrouter",
                expectedUpdatedAt: first.updatedAt
            ))
            XCTFail("stale editor must see a conflict, never silently replace the peer's text")
        } catch { XCTAssertEqual(error as? WorkDeskStoreError, .staleProject) }
        let preserved = try await store.fetchWorkDeskOrganization()
        XCTAssertEqual(preserved, updated)
    }

    func testInvalidNamesDoNotCreateProjectsAndCoordinatesAreBounded() async throws {
        let store = isolated.make()
        for title in [" ", "\n"] {
            do {
                try await store.applyWorkDeskMutation(.createProject(.init(title: title), materialIDs: []))
                XCTFail("a blank project title must be refused")
            } catch { XCTAssertEqual(error as? WorkDeskStoreError, .invalidTitle) }
        }
        do {
            try await store.applyWorkDeskMutation(.createProject(
                .init(title: "Long", brief: String(repeating: "a", count: WorkItemContentLimits.maximumFieldCharacters + 1)),
                materialIDs: []
            ))
            XCTFail("the brief must be bounded before storage")
        } catch { XCTAssertEqual(error as? WorkDeskStoreError, .contentTooLong) }
        XCTAssertEqual(WorkDeskPoint(x: .infinity, y: .nan), WorkDeskPoint(x: 0, y: 0))
        XCTAssertEqual(WorkDeskPoint(x: -20, y: .greatestFiniteMagnitude),
                       WorkDeskPoint(x: -20, y: WorkDeskPoint.coordinateLimit))
        let decoded = try JSONDecoder().decode(WorkDeskPoint.self, from: Data(#"{"x":-10,"y":30000}"#.utf8))
        XCTAssertEqual(decoded, WorkDeskPoint(x: -10, y: WorkDeskPoint.coordinateLimit))
    }

    @MainActor
    func testControllerReloadCannotOverwriteAnInterveningSave() async throws {
        let seam = DelayedDeskRead()
        let organization = WorkDeskOrganization(fetch: { await seam.fetch() }, apply: { mutation in
            await seam.apply(mutation)
        })
        let load = Task { await organization.reload() }
        await seam.waitForRead()
        let createdID = await organization.createProject(title: "Committed while loading")
        XCTAssertNotNil(createdID)
        await seam.finishRead()
        await load.value
        XCTAssertEqual(organization.projects.map(\.id), [createdID].compactMap { $0 })
    }

    @MainActor
    func testControllerReportsFailureWithoutPublishingAnUncommittedProject() async throws {
        let organization = WorkDeskOrganization(
            fetch: { .init() },
            apply: { _ in throw WorkDeskStoreError.materialNotFound }
        )
        let createdID = await organization.createProject(title: "Refused")
        XCTAssertNil(createdID)
        XCTAssertTrue(organization.projects.isEmpty)
        XCTAssertNotNil(organization.errorMessage)
        XCTAssertFalse(organization.isSaving)
    }

    private func capture(_ text: String, in store: ConversationStore) async throws -> WorkMaterialRecord {
        try await store.upsertDeskMaterial(WorkMaterialDraft(kind: .note, title: text, textContent: text))
    }
}

private actor DelayedDeskRead {
    private var read: CheckedContinuation<WorkDeskOrganizationSnapshot, Never>?
    private var observers: [CheckedContinuation<Void, Never>] = []
    private var snapshot = WorkDeskOrganizationSnapshot()

    func fetch() async -> WorkDeskOrganizationSnapshot {
        await withCheckedContinuation { continuation in
            read = continuation
            observers.forEach { $0.resume() }
            observers.removeAll()
        }
    }

    func waitForRead() async {
        if read != nil { return }
        await withCheckedContinuation { observers.append($0) }
    }

    func finishRead() {
        read?.resume(returning: .init())
        read = nil
    }

    func apply(_ mutation: WorkDeskMutation) -> WorkDeskOrganizationSnapshot {
        if case let .createProject(project, _, _) = mutation { snapshot.projects.append(project) }
        return snapshot
    }
}
