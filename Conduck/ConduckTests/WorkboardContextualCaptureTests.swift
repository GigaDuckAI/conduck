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
            // Delete before the atomic material write. A deletion after the
            // write is a subsequent organization choice, not capture failure.
            if organization.project(id: projectID) != nil {
                _ = await organization.deleteProject(id: projectID)
                workspace.selectScope(.all)
            }
            return try await importMaterial(revision, material, progress)
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
        XCTAssertTrue(notice.message.contains("1 added; 1 couldn’t be added"))
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

    func testBatchProbesDeletedProjectOnlyOnceEvenWhenFirstUnfiledWriteFails() async throws {
        for failFirstFallback in [false, true] {
            let store = isolated.make()
            let workspace = WorkDeskWorkspaceState(organization: WorkDeskOrganization(store: store))
            let deletedProjectID = UUID()
            var deps = dependencies(store: store)
            let importMaterial = deps.importMaterial
            var projectAttempts = 0
            var unfiledAttempts = 0
            deps.importMaterial = { revision, material, progress in
                if material.projectID != nil {
                    projectAttempts += 1
                    throw WorkDeskStoreError.projectNotFound
                }
                unfiledAttempts += 1
                if failFirstFallback, unfiledAttempts == 1 {
                    throw WorkboardLiveRepositoryError.missingPayload
                }
                return try await importMaterial(revision, material, progress)
            }
            let model = WorkboardViewModel(dependencies: deps, deskWorkspace: workspace)
            let batch = (0..<20).map {
                WorkboardMaterialImport(kind: .note, name: "Note \($0)", textContent: "Keep \($0)")
            }

            let report = await model.importMaterials(batch, projectID: deletedProjectID)

            XCTAssertEqual(projectAttempts, 1)
            XCTAssertEqual(unfiledAttempts, batch.count)
            XCTAssertEqual(report.addedCount, failFirstFallback ? 19 : 20)
            XCTAssertEqual(report.failedCount, failFirstFallback ? 1 : 0)
            XCTAssertEqual(model.desk?.materials.count, report.addedCount)
            XCTAssertEqual(String(localized: try XCTUnwrap(model.notice).title), "Saved in All materials")
            let organization = try await store.fetchWorkDeskOrganization()
            XCTAssertTrue(organization.placements.isEmpty)
        }
    }

    func testCaptureReplayPreservesLaterUserFiling() async throws {
        let store = isolated.make()
        let organization = WorkDeskOrganization(store: store)
        let workspace = WorkDeskWorkspaceState(organization: organization)
        let originalValue = await organization.createProject(title: "Original")
        let originalID = try XCTUnwrap(originalValue)
        let laterValue = await organization.createProject(title: "Later")
        let laterID = try XCTUnwrap(laterValue)
        let model = WorkboardViewModel(dependencies: dependencies(store: store), deskWorkspace: workspace)
        let material = WorkboardMaterialImport(kind: .note, name: "Kept", textContent: "Keep this")
        let first = await model.importMaterials([material], projectID: originalID)
        XCTAssertEqual(first.addedCount, 1)
        let moved = await organization.assign(materialIDs: [material.id], to: laterID)
        XCTAssertTrue(moved)

        let replay = await model.importMaterials([material], projectID: originalID)

        XCTAssertEqual(replay.addedCount, 1)
        XCTAssertEqual(model.desk?.materials.count, 1)
        XCTAssertEqual(organization.projectID(for: material.id), laterID)
    }

    func testDeletedDestinationAndFailedFallbackKeepComposerInput() async throws {
        let store = isolated.make()
        let workspace = WorkDeskWorkspaceState(organization: WorkDeskOrganization(store: store))
        let projectID = UUID()
        workspace.selectScope(.project(projectID))
        var deps = dependencies(store: store)
        deps.importMaterial = { _, material, _ in
            if material.projectID != nil { throw WorkDeskStoreError.projectNotFound }
            throw WorkboardLiveRepositoryError.missingPayload
        }
        let model = WorkboardViewModel(dependencies: deps, deskWorkspace: workspace)
        model.setComposerDraft("Keep my unfinished thought")

        let saved = await model.addThought(model.composerDraft, projectID: projectID)

        XCTAssertFalse(saved)
        XCTAssertEqual(model.composerDraft, "Keep my unfinished thought")
        XCTAssertNotNil(model.notice)
        let card = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        XCTAssertNil(card)
    }

    func testExternalInboxCaptureStaysUnfiledWithProjectOpen() async throws {
        let store = isolated.make()
        let organization = WorkDeskOrganization(store: store)
        let workspace = WorkDeskWorkspaceState(organization: organization)
        let projectValue = await organization.createProject(title: "Open project")
        let projectID = try XCTUnwrap(projectValue)
        workspace.selectScope(.project(projectID))
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("contextual-external-inbox-\(UUID().uuidString)")
        inboxURLs.append(root)
        let envelopes = [
            WorkCaptureEnvelope(note: "Shared outside the app", source: .shareExtension, entries: []),
            WorkCaptureEnvelope(note: "Menu bar capture", source: .app, entries: [])
        ]
        for envelope in envelopes {
            let directory = root.appendingPathComponent(envelope.id.uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try envelope.encoded().write(to: directory.appendingPathComponent("manifest.json"), options: .atomic)
        }
        let drainer = WorkCaptureDrainer(inbox: WorkCaptureInbox(baseURL: root),
            store: store, sourceDevice: "test-device")

        let report = try await drainer.drainAvailableCaptures()

        XCTAssertEqual(report.importedCaptureCount, envelopes.count)
        let snapshot = try await store.fetchWorkDeskOrganization()
        for envelope in envelopes {
            let material = try await store.fetchWorkMaterial(id: envelope.id)
            XCTAssertEqual(material?.workItemID, Constants.workboardDeskItemID)
            XCTAssertNil(snapshot.placements[envelope.id]?.projectID)
        }
        XCTAssertEqual(workspace.scope, .project(projectID))
    }

}
