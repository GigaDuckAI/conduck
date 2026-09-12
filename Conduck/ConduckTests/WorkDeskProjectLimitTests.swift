// SPDX-License-Identifier: Apache-2.0

// Active-project allowances are enforced by the real isolated store, including
// concurrent windows. Archiving frees capacity without removing membership,
// bytes or conversation history; a refusal commits no partial organization.

import XCTest
@testable import Conduck

final class WorkDeskProjectLimitTests: XCTestCase {
    private let isolated = IsolatedWorkStores()

    override func tearDown() async throws {
        await isolated.cleanUp()
        try await super.tearDown()
    }

    func testFourthProjectRefusedWithoutMovingSelectionAndArchiveRecyclesSlot() async throws {
        let store = isolated.make()
        let material = try await store.upsertDeskMaterial(.init(kind: .note, title: "Keep my filing"))
        let projects = (0..<Constants.maxActiveWorkProjects).map { WorkDeskProjectRecord(title: "Project \($0)") }
        for project in projects {
            try await store.applyWorkDeskMutation(.createProject(project, materialIDs: []))
        }
        try await store.applyWorkDeskMutation(.assign(materialIDs: [material.id], projectID: projects[0].id))
        let before = try await store.fetchWorkDeskOrganization()
        let fourth = WorkDeskProjectRecord(title: "Fourth")
        do {
            try await store.applyWorkDeskMutation(.createProject(fourth, materialIDs: [material.id]))
            XCTFail("A fourth active project must be refused before changing membership")
        } catch { XCTAssertEqual(error as? WorkDeskStoreError, .activeProjectLimitReached) }
        let refused = try await store.fetchWorkDeskOrganization()
        XCTAssertEqual(refused, before)

        try await store.applyWorkDeskMutation(.archiveProject(id: projects[0].id, isArchived: true))
        let created = try await store.applyWorkDeskMutation(.createProject(fourth, materialIDs: []))
        XCTAssertEqual(created.projects.count, Constants.maxActiveWorkProjects + 1)
        XCTAssertEqual(created.projects.filter { !$0.isArchived }.count, Constants.maxActiveWorkProjects)
        XCTAssertEqual(created.placements[material.id], before.placements[material.id])
        do {
            try await store.applyWorkDeskMutation(.archiveProject(id: projects[0].id, isArchived: false))
            XCTFail("Restore cannot exceed the active allowance")
        } catch { XCTAssertEqual(error as? WorkDeskStoreError, .activeProjectLimitReached) }
        let refusedRestore = try await store.fetchWorkDeskOrganization()
        XCTAssertEqual(refusedRestore, created)

        try await store.applyWorkDeskMutation(.archiveProject(id: fourth.id, isArchived: true))
        let restored = try await store.applyWorkDeskMutation(.archiveProject(id: projects[0].id, isArchived: false))
        XCTAssertEqual(restored.projects.first { $0.id == projects[0].id }?.isArchived, false)
        XCTAssertEqual(restored.projects.filter { !$0.isArchived }.count, Constants.maxActiveWorkProjects)
        let repeated = try await store.applyWorkDeskMutation(.archiveProject(id: projects[0].id, isArchived: false))
        XCTAssertEqual(repeated, restored, "Restoring an already-active project needs no extra slot or write")
    }

    func testArchivePreservesBytesOrganizationAndConversationHistoryButRefusesNewWork() async throws {
        let store = isolated.make()
        let bytes = Data("Original private material".utf8)
        let material = try await store.upsertDeskMaterial(.init(kind: .file, title: "Reference",
            filename: "reference.txt", mimeType: "text/plain", payload: bytes))
        let project = WorkDeskProjectRecord(title: "Completed", brief: "Keep this context",
            preferredGatewayRef: "openrouter", position: .init(x: 42, y: 75), isPinned: true)
        try await store.applyWorkDeskMutation(.createProject(project, materialIDs: [material.id]))
        let conversation = try await store.createConversation(backend: "openrouter", projectID: project.id)
        let before = try await store.fetchWorkDeskOrganization()
        let archived = try await store.applyWorkDeskMutation(.archiveProject(id: project.id, isArchived: true))
        let saved = try XCTUnwrap(archived.projects.first)
        XCTAssertTrue(saved.isArchived)
        XCTAssertEqual(saved.title, project.title)
        XCTAssertEqual(saved.brief, project.brief)
        XCTAssertEqual(saved.preferredGatewayRef, project.preferredGatewayRef)
        XCTAssertEqual(saved.position, project.position)
        XCTAssertEqual(saved.isPinned, project.isPinned)
        XCTAssertEqual(archived.placements, before.placements)
        let payload = try await store.loadWorkMaterialPayload(id: material.id)
        let preserved = try await store.fetchWorkMaterial(id: material.id)
        let conversations = try await store.fetchProjectConversations(projectID: project.id)
        XCTAssertEqual(payload, bytes)
        XCTAssertEqual(preserved, material)
        XCTAssertEqual(conversations.map(\.id), [conversation.id])

        let loose = try await store.upsertDeskMaterial(.init(kind: .note, title: "New work"))
        do {
            try await store.applyWorkDeskMutation(.assign(materialIDs: [loose.id], projectID: project.id))
            XCTFail("An archived project cannot accept new filing")
        } catch { XCTAssertEqual(error as? WorkDeskStoreError, .projectArchived) }
        do {
            _ = try await store.createConversation(backend: "openrouter", projectID: project.id)
            XCTFail("An archived project cannot start a new handoff")
        } catch { XCTAssertEqual(error as? WorkDeskStoreError, .projectArchived) }
        let unchanged = try await store.fetchWorkDeskOrganization()
        XCTAssertEqual(unchanged, archived)
        // Harmless metadata correction and exporting do not consume capacity.
        let renamed = try await store.applyWorkDeskMutation(.updateProject(id: project.id,
            title: "Completed client work", brief: saved.brief, preferredGatewayRef: saved.preferredGatewayRef))
        XCTAssertEqual(renamed.projects.first?.isArchived, true)
    }

    func testSimultaneousWindowsCannotBothClaimLastSlot() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("work-limit-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = isolated.make(storeURL: directory.appendingPathComponent("store.sqlite"))
        let second = isolated.make(storeURL: directory.appendingPathComponent("store.sqlite"))
        for index in 0..<(Constants.maxActiveWorkProjects - 1) {
            try await first.applyWorkDeskMutation(.createProject(.init(title: "Existing \(index)"), materialIDs: []))
        }
        _ = try await second.fetchWorkDeskOrganization()
        let failures = await withTaskGroup(of: WorkDeskStoreError?.self) { group in
            for store in [first, second] {
                group.addTask {
                    do {
                        try await store.applyWorkDeskMutation(.createProject(.init(title: "Last slot"), materialIDs: []))
                        return nil
                    } catch { return error as? WorkDeskStoreError ?? .identifierCollision }
                }
            }
            var errors: [WorkDeskStoreError?] = []
            for await error in group { errors.append(error) }
            return errors
        }
        XCTAssertEqual(failures.filter { $0 == nil }.count, 1)
        XCTAssertEqual(failures.compactMap { $0 }, [.activeProjectLimitReached])
        let snapshot = try await first.fetchWorkDeskOrganization()
        XCTAssertEqual(snapshot.projects.count, Constants.maxActiveWorkProjects)
        try await second._unloadForTesting()
        try await first._unloadForTesting()
    }

    @MainActor
    func testAllProjectCreationDoorsKeepSelectionWhenAllowanceIsFull() async throws {
        let store = isolated.make()
        let organization = WorkDeskOrganization(store: store)
        for index in 0..<Constants.maxActiveWorkProjects { _ = await organization.createProject(title: "Existing \(index)") }
        let workspace = WorkDeskWorkspaceState(organization: organization)
        let selected = UUID()
        workspace.selectedIDs = [selected]
        workspace.beginProject(materialIDs: [selected], position: .init(x: 50, y: 75))
        XCTAssertNil(workspace.projectEditor)
        XCTAssertEqual(workspace.selectedIDs, [selected])
        XCTAssertTrue(organization.projectLimitRequested)
        XCTAssertNil(organization.errorMessage, "The typed limit opens Pro instead of an error alert")
        let first = try XCTUnwrap(organization.projects.first)
        let saved = await organization.setProjectArchived(true, id: first.id)
        XCTAssertTrue(saved)
        workspace.beginProject(materialIDs: [selected])
        XCTAssertNotNil(workspace.projectEditor)
        XCTAssertEqual(organization.archivedProjects.map(\.id), [first.id])
    }
}
