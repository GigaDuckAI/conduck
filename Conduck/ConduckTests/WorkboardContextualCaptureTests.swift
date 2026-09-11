// SPDX-License-Identifier: Apache-2.0

// Contextual capture adds membership only to exact committed IDs. These use
// isolated live stores to exercise async scope changes, unrelated arrivals,
// and deleted destinations while retaining every successfully captured item.

import XCTest
@testable import Conduck

@MainActor
final class WorkboardContextualCaptureTests: XCTestCase {
    private let isolated = IsolatedWorkStores()
    private var inboxURLs: [URL] = []

    override func tearDown() async throws {
        for url in inboxURLs { try? FileManager.default.removeItem(at: url) }
        await isolated.cleanUp()
        try await super.tearDown()
    }

    private func dependencies(store: ConversationStore) -> WorkboardViewModel.Dependencies {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("contextual-work-capture-\(UUID().uuidString)")
        inboxURLs.append(url)
        return WorkboardLiveRepository(store: store, captureInbox: WorkCaptureInbox(baseURL: url),
            openMaterial: { _ in }).makeDependencies()
    }

    func testProjectThoughtRemainsCanonicalAndVisibleInAllMaterials() async throws {
        let store = isolated.make()
        let organization = WorkDeskOrganization(store: store)
        let workspace = WorkDeskWorkspaceState(organization: organization)
        let projectIDValue = await organization.createProject(title: "Launch")
        let projectID = try XCTUnwrap(projectIDValue)
        workspace.selectScope(.project(projectID))
        let target = WorkboardCaptureDestination(workspace: workspace)
        let model = WorkboardViewModel(dependencies: dependencies(store: store), deskWorkspace: workspace)

        let saved = await model.addThought("A useful thought", projectID: target.projectID)

        XCTAssertTrue(saved)
        let card = try XCTUnwrap(model.desk?.materials.first)
        XCTAssertEqual(organization.projectID(for: card.id), projectID)
        let persisted = try await store.fetchWorkMaterial(id: card.id)
        XCTAssertEqual(persisted?.workItemID, Constants.workboardDeskItemID)
        XCTAssertEqual(workspace.visibleMaterials(in: model.desk?.materials ?? []).map(\.id), [card.id])
        workspace.selectScope(.all)
        XCTAssertEqual(workspace.visibleMaterials(in: model.desk?.materials ?? []).map(\.id), [card.id])
    }

    func testGlobalSearchCapturesInAllMaterialsEvenWithUnderlyingProjectScope() async throws {
        let store = isolated.make()
        let organization = WorkDeskOrganization(store: store)
        let workspace = WorkDeskWorkspaceState(organization: organization)
        let projectIDValue = await organization.createProject(title: "Launch")
        let projectID = try XCTUnwrap(projectIDValue)
        workspace.selectScope(.project(projectID))
        workspace.search = "other idea"
        let target = WorkboardCaptureDestination(workspace: workspace)
        XCTAssertEqual(target, .all)
        let model = WorkboardViewModel(dependencies: dependencies(store: store), deskWorkspace: workspace)

        let saved = await model.addThought("New idea", projectID: target.projectID)

        XCTAssertTrue(saved)
        let card = try XCTUnwrap(model.desk?.materials.first)
        XCTAssertNil(organization.projectID(for: card.id))
        XCTAssertEqual(WorkboardCaptureDestination(workspace: nil), .all)
    }

    func testBatchKeepsOriginalProjectWhenScopeChangesAndDoesNotAssignExternalArrival() async throws {
        let store = isolated.make()
        let organization = WorkDeskOrganization(store: store)
        let workspace = WorkDeskWorkspaceState(organization: organization)
        let originalIDValue = await organization.createProject(title: "Original")
        let originalID = try XCTUnwrap(originalIDValue)
        let otherIDValue = await organization.createProject(title: "Other")
        let otherID = try XCTUnwrap(otherIDValue)
        workspace.selectScope(.project(originalID))
        let target = WorkboardCaptureDestination(workspace: workspace)
        var deps = dependencies(store: store)
        let importMaterial = deps.importMaterial
        let loadDesk = deps.loadDesk
        let externalID = UUID()
        var insertedExternal = false
        deps.importMaterial = { revision, material, progress in
            let captured = try await importMaterial(revision, material, progress)
            if !insertedExternal {
                insertedExternal = true
                workspace.selectScope(.project(otherID))
                _ = try await store.upsertDeskMaterial(WorkMaterialDraft(
                    id: externalID, kind: .note, title: "External arrival", textContent: "Other device"
                ))
                // The refreshed desk includes an unrelated arrival. Taking a
                // before/after difference here would misassign its ID.
                let refreshed = try await loadDesk()
                return try XCTUnwrap(refreshed)
            }
            return captured
        }
        let model = WorkboardViewModel(dependencies: deps, deskWorkspace: workspace)
        let first = WorkboardMaterialImport(kind: .note, name: "First", textContent: "First")
        let second = WorkboardMaterialImport(kind: .link, name: "Second", urlString: "https://example.com")

        let report = await model.importMaterials([first, second], projectID: target.projectID)

        XCTAssertEqual(report, WorkboardImportReport(addedCount: 2, failedCount: 0))
        XCTAssertEqual(organization.projectID(for: first.id), originalID)
        XCTAssertEqual(organization.projectID(for: second.id), originalID)
        XCTAssertNil(organization.projectID(for: externalID))
        XCTAssertEqual(workspace.scope, .project(otherID))
    }

    func testDeletedProjectKeepsCaptureAndReportsPartialFailure() async throws {
        let store = isolated.make()
        let organization = WorkDeskOrganization(store: store)
        let workspace = WorkDeskWorkspaceState(organization: organization)
        let projectIDValue = await organization.createProject(title: "Temporary")
        let projectID = try XCTUnwrap(projectIDValue)
        workspace.selectScope(.project(projectID))
        let target = WorkboardCaptureDestination(workspace: workspace)
        var deps = dependencies(store: store)
        let importMaterial = deps.importMaterial
        deps.importMaterial = { revision, material, progress in
            let captured = try await importMaterial(revision, material, progress)
            _ = await organization.deleteProject(id: projectID)
            workspace.selectScope(.all)
            return captured
        }
        let model = WorkboardViewModel(dependencies: deps, deskWorkspace: workspace)
        let valid = WorkboardMaterialImport(kind: .note, name: "Kept", textContent: "Keep this")
        let invalid = WorkboardMaterialImport(kind: .file, name: "Missing bytes")

        let report = await model.importMaterials([valid, invalid], projectID: target.projectID)

        XCTAssertEqual(report, WorkboardImportReport(addedCount: 1, failedCount: 1))
        let saved = try await store.fetchWorkMaterial(id: valid.id)
        XCTAssertEqual(saved?.textContent, "Keep this")
        XCTAssertNil(organization.projectID(for: valid.id))
        let notice = try XCTUnwrap(model.notice)
        XCTAssertEqual(String(localized: notice.title), "Saved in All materials")
        XCTAssertTrue(notice.message.contains("1 added to All materials; 1 couldn’t be added"))
        XCTAssertNil(model.workspaceStatus)
    }

    func testDeletedProjectThoughtReturnsSuccessSoComposerDoesNotDuplicateIt() async throws {
        let store = isolated.make()
        let workspace = WorkDeskWorkspaceState(organization: WorkDeskOrganization(store: store))
        let projectID = UUID()
        let model = WorkboardViewModel(dependencies: dependencies(store: store), deskWorkspace: workspace)

        let saved = await model.addThought("Keep my thought", projectID: projectID)

        XCTAssertTrue(saved)
        XCTAssertEqual(model.desk?.materials.count, 1)
        XCTAssertEqual(String(localized: try XCTUnwrap(model.notice).title), "Saved in All materials")
    }
}
