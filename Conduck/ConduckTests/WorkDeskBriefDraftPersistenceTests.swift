// SPDX-License-Identifier: Apache-2.0

// Request recovery is tested with injected memory stores and explicit temporary
// directories only. Reload never broadens selection, failed writes keep the
// previous record, and erased requests cannot return from retained view state.

import XCTest
@testable import Conduck

@MainActor
final class WorkDeskBriefDraftPersistenceTests: XCTestCase {
    private let gateway: RemoteAgentRef = .builtin(.hermes)

    func testAutosaveRestoresTaskDestinationSelectionsAndDisclosureWithoutProjectContext() throws {
        let storage = InMemoryWorkDeskBriefDraftStorage()
        let projectID = UUID()
        let original = draft(projectID, storage: storage)
        let words = WorkboardMaterialSnapshot(kind: .transcript, name: "Words", textContent: "Original words")
        let image = WorkboardMaterialSnapshot(kind: .image, name: "Image", companion: WorkboardCompanionSnapshot(words))
        let external = WorkboardMaterialSnapshot(kind: .note, name: "Outside")
        let leftOut = WorkboardMaterialSnapshot(kind: .note, name: "Private")
        original.brief = "Compare these carefully"
        original.selectedGateway = gateway
        original.materialsExpanded = false
        XCTAssertTrue(original.useOnlyMaterials([image.id], materials: [image, leftOut]))
        XCTAssertTrue(original.addMaterials([external], to: [image, leftOut]))
        original.excludedIDs.insert(leftOut.id)
        original.projectContext = "This must not be persisted"
        original.projectResultIDs.insert(leftOut.id)

        let reloaded = draft(projectID, storage: storage, context: "Current project context")
        XCTAssertEqual(reloaded.brief, original.brief)
        XCTAssertEqual(reloaded.selectedGateway, gateway)
        XCTAssertEqual(reloaded.materialsExpanded, false)
        XCTAssertEqual(reloaded.selectedMaterialIDs, [image.id, external.id])
        XCTAssertEqual(reloaded.additionalMaterialIDs, [external.id])
        XCTAssertEqual(reloaded.excludedIDs, [leftOut.id])
        XCTAssertEqual(reloaded.projectResultIDs, [leftOut.id])
        XCTAssertEqual(reloaded.projectContext, "Current project context")
        XCTAssertEqual(reloaded.includedCards(from: [image, external, leftOut]).first?.companion?.id, words.id)
        XCTAssertNil(reloaded.handoff.prepared)
        XCTAssertNil(reloaded.handoff.acceptedConversationID)
        let saved = try XCTUnwrap(storage.records[projectID])
        XCTAssertFalse(String(decoding: saved, as: UTF8.self).contains("This must not be persisted"))
    }

    func testRestoredExplicitSelectionNeverAddsNewCardsOrCompanionsAndRetainsMissingIDs() {
        let storage = InMemoryWorkDeskBriefDraftStorage(), projectID = UUID()
        let original = draft(projectID, storage: storage)
        var photo = WorkboardMaterialSnapshot(kind: .image, name: "Photo")
        let missing = WorkboardMaterialSnapshot(kind: .note, name: "Waiting for sync")
        XCTAssertTrue(original.useOnlyMaterials([photo.id, missing.id], materials: [photo, missing]))
        let reloaded = draft(projectID, storage: storage)
        let words = WorkboardMaterialSnapshot(kind: .transcript, name: "New words")
        photo.companion = WorkboardCompanionSnapshot(words)
        let arrival = WorkboardMaterialSnapshot(kind: .note, name: "New card")
        XCTAssertEqual(reloaded.includedCards(from: [photo, arrival]).map(\.id), [photo.id])
        XCTAssertNil(reloaded.includedCards(from: [photo]).first?.companion)
        XCTAssertTrue(reloaded.hasMissingSelectedMaterials(in: [photo, arrival]))
        XCTAssertTrue(reloaded.persistChanges())
        XCTAssertEqual(draft(projectID, storage: storage).selectedMaterialIDs, [photo.id, missing.id])
        reloaded.leaveOutMissingMaterials(in: [photo, arrival])
        XCTAssertEqual(draft(projectID, storage: storage).selectedMaterialIDs, [photo.id])
    }

    func testEmptyExplicitSelectionSurvivesReloadInsteadOfBecomingAllMaterials() {
        let storage = InMemoryWorkDeskBriefDraftStorage(), projectID = UUID()
        let card = WorkboardMaterialSnapshot(kind: .note, name: "Card")
        let original = draft(projectID, storage: storage)
        XCTAssertTrue(original.useOnlyMaterials([card.id], materials: [card]))
        original.setMaterialIncluded(false, id: card.id)
        let reloaded = draft(projectID, storage: storage)
        XCTAssertEqual(reloaded.selectedMaterialIDs, [])
        XCTAssertTrue(reloaded.includedCards(from: [card]).isEmpty)
    }

    func testWriteFailureKeepsLastSavedRequestAndRetrySavesNewText() throws {
        let storage = FailingStorage(), projectID = UUID()
        let original = draft(projectID, storage: storage)
        original.brief = "Saved"
        storage.failWrites = true
        original.brief = "New unsaved words"
        XCTAssertNotNil(original.persistenceError)
        XCTAssertFalse(original.persistChanges())
        XCTAssertFalse(original.isPersistenceUnavailable, "A failed write must leave editing available")
        XCTAssertEqual(draft(projectID, storage: storage).brief, "Saved")
        storage.failWrites = false
        XCTAssertTrue(original.persistChanges())
        XCTAssertNil(original.persistenceError)
        XCTAssertEqual(draft(projectID, storage: storage).brief, "New unsaved words")
    }

    func testReadFailureDoesNotOverwriteUnknownRequestAndRetryRestoresIt() {
        let storage = FailingStorage(), projectID = UUID()
        draft(projectID, storage: storage).brief = "Keep the previous request"
        storage.failReads = true
        let reloaded = draft(projectID, storage: storage)
        XCTAssertTrue(reloaded.isPersistenceUnavailable)
        XCTAssertNotNil(reloaded.persistenceError)
        reloaded.brief = "A late UI callback"
        XCTAssertFalse(reloaded.persistChanges())
        storage.failReads = false
        XCTAssertTrue(reloaded.persistChanges())
        XCTAssertFalse(reloaded.isPersistenceUnavailable)
        XCTAssertEqual(reloaded.brief, "Keep the previous request")
        XCTAssertEqual(draft(projectID, storage: storage).brief, "Keep the previous request")
    }

    func testUnreadableRecordIsNotReplacedAndCanBeExplicitlyDiscarded() {
        let storage = InMemoryWorkDeskBriefDraftStorage(), projectID = UUID()
        let originalBytes = Data("{ incomplete json".utf8)
        storage.records[projectID] = originalBytes
        let reloaded = draft(projectID, storage: storage)
        reloaded.brief = "No replacement"
        XCTAssertFalse(reloaded.persistChanges())
        XCTAssertEqual(storage.records[projectID], originalBytes)
        XCTAssertTrue(reloaded.discardUnsavedChanges())
        XCTAssertNil(storage.records[projectID])
        XCTAssertFalse(reloaded.isPersistenceUnavailable)
    }

    func testFailedDiscardKeepsRequestAndSuccessfulDiscardClearsAllChoices() {
        let storage = FailingStorage(), projectID = UUID()
        let original = draft(projectID, storage: storage)
        original.brief = "Do not lose me"
        original.materialsExpanded = true
        original.selectedGateway = gateway
        storage.failRemovals = true
        XCTAssertFalse(original.discardUnsavedChanges())
        XCTAssertEqual(original.brief, "Do not lose me")
        XCTAssertNotNil(original.persistenceError)
        XCTAssertEqual(draft(projectID, storage: storage).brief, "Do not lose me")
        storage.failRemovals = false
        XCTAssertTrue(original.discardUnsavedChanges())
        XCTAssertEqual(original.brief, "")
        XCTAssertNil(original.materialsExpanded)
        XCTAssertNil(original.selectedGateway)
        XCTAssertNil(storage.records[projectID])
        original.brief = "A fresh draft"
        XCTAssertEqual(draft(projectID, storage: storage).brief, "A fresh draft")
    }

    func testErasureInvalidatesEveryRetainedSessionAndCannotResurrectFromCallbacks() throws {
        let storage = InMemoryWorkDeskBriefDraftStorage()
        let store = WorkDeskBriefDraftStore(storage: storage)
        let projectID = UUID()
        let first = draft(projectID, store: store), second = draft(projectID, store: store)
        first.brief = "Old request"
        try store.eraseAll()
        XCTAssertEqual(first.brief, "")
        XCTAssertEqual(second.brief, "")
        first.brief = "Late editor callback"
        second.excludedIDs.insert(UUID())
        XCTAssertFalse(first.persistChanges())
        XCTAssertTrue(first.persistedRequestWasRemoved)
        XCTAssertTrue(storage.records.isEmpty)
        let fresh = draft(projectID, store: store)
        fresh.brief = "New request"
        XCTAssertEqual(draft(projectID, storage: storage).brief, "New request")
    }

    func testProjectDeletionInvalidatesOldSessionsAndRefusesNewOnes() throws {
        let storage = InMemoryWorkDeskBriefDraftStorage()
        let store = WorkDeskBriefDraftStore(storage: storage)
        let projectID = UUID(), otherID = UUID()
        let old = draft(projectID, store: store)
        old.brief = "Removed"
        draft(otherID, store: store).brief = "Other project survives"
        try store.deleteProjects([projectID])
        old.brief = "Late value"
        XCTAssertFalse(old.persistChanges())
        XCTAssertNil(storage.records[projectID])
        let reopened = draft(projectID, store: store)
        reopened.brief = "Cannot recreate a deleted project"
        XCTAssertFalse(reopened.persistChanges())
        XCTAssertNil(storage.records[projectID])
        XCTAssertEqual(draft(otherID, storage: storage).brief, "Other project survives")
    }

    func testFailedProjectCleanupCanRetryWithoutRestoringItsInvalidatedDraft() throws {
        let storage = FailingStorage(), projectID = UUID()
        let store = WorkDeskBriefDraftStore(storage: storage)
        let old = draft(projectID, store: store)
        old.brief = "Removed project request"
        storage.failRemovals = true
        XCTAssertThrowsError(try store.deleteProjects([projectID]))
        XCTAssertTrue(old.persistedRequestWasRemoved)
        XCTAssertFalse(old.persistChanges())
        storage.failRemovals = false
        try store.deleteProjects([projectID])
        XCTAssertNil(storage.records[projectID])
    }

    func testStartingAnotherRequestRemovesOldRecordAndRestoresResultExclusions() {
        let storage = InMemoryWorkDeskBriefDraftStorage(), projectID = UUID()
        let original = draft(projectID, storage: storage), resultID = UUID()
        original.brief = "Old task"
        original.selectedGateway = gateway
        original.projectResultIDs = [resultID]
        original.materialsExpanded = false
        XCTAssertTrue(original.startAnotherConversation())
        XCTAssertNil(storage.records[projectID])
        XCTAssertEqual(original.brief, "")
        XCTAssertEqual(original.selectedGateway, gateway)
        XCTAssertEqual(original.excludedIDs, [resultID])
        XCTAssertNil(original.materialsExpanded)
    }

    func testAtomicFileAdapterReloadsFromAnIsolatedDirectoryAndDeletesCleanly() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let projectID = UUID()
        let original = draft(projectID, storage: WorkDeskBriefDraftFileStorage(directory: directory))
        original.brief = "Recovered after reopening the file store"
        let restored = draft(projectID, storage: WorkDeskBriefDraftFileStorage(directory: directory))
        XCTAssertEqual(restored.brief, original.brief)
        XCTAssertTrue(restored.discardUnsavedChanges())
        XCTAssertEqual(draft(projectID, storage: WorkDeskBriefDraftFileStorage(directory: directory)).brief, "")
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).isEmpty)
    }

    func testRestoredWorkspaceRetainsExplicitResultChoiceAndExcludesLaterResults() async {
        let storage = InMemoryWorkDeskBriefDraftStorage()
        let store = WorkDeskBriefDraftStore(storage: storage)
        let project = WorkDeskProjectRecord(title: "Project")
        let known = WorkboardMaterialSnapshot(kind: .file, name: "Chosen result", projectResultKind: .file)
        let arriving = WorkboardMaterialSnapshot(kind: .file, name: "New result", projectResultKind: .file)
        let first = WorkDeskWorkspaceState(draftStore: store)
        first.reconcile(materials: [known])
        let original = first.briefDraft(for: project, resolver: .init())
        original.brief = "Discuss the result"
        original.setMaterialIncluded(true, id: known.id)
        XCTAssertTrue(original.isMaterialIncluded(known.id))

        let reopened = WorkDeskWorkspaceState(draftStore: WorkDeskBriefDraftStore(storage: storage))
        let restored = reopened.briefDraft(for: project, resolver: .init())
        reopened.reconcile(materials: [known, arriving])
        XCTAssertTrue(restored.isMaterialIncluded(known.id), "Reopening must keep a result the person explicitly included")
        XCTAssertFalse(restored.isMaterialIncluded(arriving.id), "A newly returned result still requires explicit inclusion")
        XCTAssertEqual(restored.brief, "Discuss the result")
    }

    func testTransientProjectAbsenceKeepsDraftWhileActualTombstoneRemovesIt() async {
        let storage = InMemoryWorkDeskBriefDraftStorage()
        let store = WorkDeskBriefDraftStore(storage: storage)
        let project = WorkDeskProjectRecord(title: "Project")
        let absent = WorkDeskOrganizationSnapshot()
        let organization = WorkDeskOrganization(fetch: { absent }, apply: { _ in absent })
        let workspace = WorkDeskWorkspaceState(organization: organization, draftStore: store)
        let original = workspace.briefDraft(for: project, resolver: .init())
        original.brief = "Waiting for the project to sync"
        await organization.reload()
        workspace.reconcile(materials: [])
        XCTAssertEqual(draft(project.id, storage: storage).brief, original.brief)
        WorkDeskWorkspaceState.pruneProjectSessions(deletedProjectIDs: [project.id])
        XCTAssertNil(storage.records[project.id])
        XCTAssertNil(workspace.briefDrafts[project.id])
        original.brief = "Late update from a dismissed sheet"
        XCTAssertFalse(original.persistChanges())
        XCTAssertNil(storage.records[project.id])
    }

    func testStaleWindowSuspensionNeverOverwritesTheNewerSavedRequest() throws {
        let storage = InMemoryWorkDeskBriefDraftStorage(), projectID = UUID()
        let store = WorkDeskBriefDraftStore(storage: storage)
        let first = draft(projectID, store: store)
        first.brief = "Original"
        let second = draft(projectID, store: store)
        first.brief = "Newer request in first window"
        second.suspendPresentation()
        XCTAssertEqual(draft(projectID, storage: storage).brief, "Newer request in first window")
        XCTAssertEqual(second.brief, "Original", "Another window never discards this editor's text")
        XCTAssertEqual(second.persistenceConflict?.current?.task, "Newer request in first window")
    }

    func testCompetingWindowEditsPreserveTextAndSelectionsUntilExplicitReplacement() throws {
        let storage = InMemoryWorkDeskBriefDraftStorage(), projectID = UUID()
        let store = WorkDeskBriefDraftStore(storage: storage)
        let first = draft(projectID, store: store)
        first.brief = "Original"
        let second = draft(projectID, store: store)
        first.brief = "First window task"
        let material = WorkboardMaterialSnapshot(kind: .note, name: "Second window card")
        second.brief = "Second window task"
        second.selectedGateway = gateway
        XCTAssertTrue(second.useOnlyMaterials([material.id], materials: [material]))
        XCTAssertEqual(draft(projectID, storage: storage).brief, "First window task")
        XCTAssertEqual(second.brief, "Second window task")
        XCTAssertEqual(second.selectedMaterialIDs, [material.id])
        let conflict = try XCTUnwrap(second.persistenceConflict)
        XCTAssertTrue(second.replacePersistedRequest(resolving: conflict))
        let saved = draft(projectID, storage: storage)
        XCTAssertEqual(saved.brief, "Second window task")
        XCTAssertEqual(saved.selectedGateway, gateway)
        XCTAssertEqual(saved.selectedMaterialIDs, [material.id])
    }

    func testReplacementAndReloadRefuseAnUnseenNewerRevision() throws {
        let storage = InMemoryWorkDeskBriefDraftStorage(), projectID = UUID()
        let store = WorkDeskBriefDraftStore(storage: storage)
        let first = draft(projectID, store: store)
        first.brief = "Original"
        let second = draft(projectID, store: store)
        first.brief = "First edit"
        second.brief = "Local conflict"
        let preview = try XCTUnwrap(second.persistenceConflict)
        first.brief = "Unseen edit while confirmation was open"
        XCTAssertFalse(second.replacePersistedRequest(resolving: preview))
        XCTAssertFalse(second.reloadPersistedRequest(resolving: preview))
        XCTAssertEqual(second.brief, "Local conflict")
        XCTAssertEqual(second.persistenceConflict?.current?.task, "Unseen edit while confirmation was open")
        XCTAssertEqual(draft(projectID, storage: storage).brief, "Unseen edit while confirmation was open")
        let currentPreview = try XCTUnwrap(second.persistenceConflict)
        XCTAssertTrue(second.reloadPersistedRequest(resolving: currentPreview))
        XCTAssertEqual(second.brief, "Unseen edit while confirmation was open")
    }

    func testRetiringOneWindowNeverClearsAnotherWindowsConflictingText() throws {
        let storage = InMemoryWorkDeskBriefDraftStorage(), projectID = UUID()
        let store = WorkDeskBriefDraftStore(storage: storage)
        let first = draft(projectID, store: store)
        first.brief = "Saved request"
        let second = draft(projectID, store: store)
        first.brief = "Ready to send"
        second.brief = "Independent unsaved request"
        XCTAssertTrue(first.clearPersistedRequest())
        XCTAssertNil(storage.records[projectID])
        XCTAssertEqual(second.brief, "Independent unsaved request")
        XCTAssertFalse(second.persistChanges())
        let conflict = try XCTUnwrap(second.persistenceConflict)
        XCTAssertNil(conflict.current)
        XCTAssertTrue(second.replacePersistedRequest(resolving: conflict))
        XCTAssertEqual(draft(projectID, storage: storage).brief, "Independent unsaved request")
    }

    func testStaleDiscardCannotEraseAnotherWindowsSavedRequest() throws {
        let storage = InMemoryWorkDeskBriefDraftStorage(), projectID = UUID()
        let store = WorkDeskBriefDraftStore(storage: storage)
        let first = draft(projectID, store: store)
        first.brief = "Original"
        let second = draft(projectID, store: store)
        first.brief = "Keep the newer request"
        XCTAssertFalse(second.discardUnsavedChanges())
        XCTAssertNotNil(second.persistenceConflict)
        XCTAssertEqual(second.brief, "Original")
        XCTAssertEqual(draft(projectID, storage: storage).brief, "Keep the newer request")
    }

    func testPendingSendIsDurableBeforeDispatchAndRecoveredAfterRetirementFailure() throws {
        let storage = FailingStorage(), projectID = UUID(), conversationID = UUID()
        let original = draft(projectID, storage: storage)
        original.brief = "The request might already be sent"
        XCTAssertTrue(original.markHandoffStarting(conversationID: conversationID))
        storage.failRemovals = true
        XCTAssertFalse(original.clearPersistedRequest())
        let restored = draft(projectID, storage: storage)
        XCTAssertEqual(restored.brief, "The request might already be sent")
        XCTAssertEqual(restored.interruptedHandoffID, conversationID)
        XCTAssertFalse(restored.markHandoffStarting(conversationID: UUID()))
        storage.failRemovals = false
        XCTAssertTrue(restored.reviewAfterInterruptedHandoff())
        XCTAssertNil(restored.interruptedHandoffID)
        XCTAssertEqual(draft(projectID, storage: storage).brief, original.brief)
        XCTAssertNil(draft(projectID, storage: storage).interruptedHandoffID)
    }

    func testFailedPreSendMarkerWriteNeverAuthorizesDispatch() {
        let storage = FailingStorage(), projectID = UUID()
        let original = draft(projectID, storage: storage)
        original.brief = "Not sent"
        storage.failWrites = true
        XCTAssertFalse(original.markHandoffStarting(conversationID: UUID()))
        XCTAssertNotNil(original.persistenceError)
        storage.failWrites = false
        XCTAssertNil(draft(projectID, storage: storage).interruptedHandoffID)
    }

    func testRefusedSendClearsMarkerOnlyAfterSuccessfulWrite() {
        let storage = FailingStorage(), projectID = UUID(), conversationID = UUID()
        let original = draft(projectID, storage: storage)
        original.brief = "Retry this task"
        XCTAssertTrue(original.markHandoffStarting(conversationID: conversationID))
        storage.failWrites = true
        original.markHandoffRefused(conversationID: conversationID)
        XCTAssertEqual(original.interruptedHandoffID, conversationID)
        XCTAssertEqual(draft(projectID, storage: storage).interruptedHandoffID, conversationID)
        storage.failWrites = false
        original.markHandoffRefused(conversationID: conversationID)
        XCTAssertNil(original.interruptedHandoffID)
        XCTAssertNil(draft(projectID, storage: storage).interruptedHandoffID)
        XCTAssertEqual(draft(projectID, storage: storage).brief, "Retry this task")
    }

    func testPendingSendCannotBeOverwrittenFromConflictConfirmation() throws {
        let storage = InMemoryWorkDeskBriefDraftStorage(), projectID = UUID()
        let store = WorkDeskBriefDraftStore(storage: storage)
        let first = draft(projectID, store: store)
        first.brief = "About to send"
        let second = draft(projectID, store: store)
        let conversationID = UUID()
        XCTAssertTrue(first.markHandoffStarting(conversationID: conversationID))
        second.brief = "A competing request"
        let conflict = try XCTUnwrap(second.persistenceConflict)
        XCTAssertFalse(conflict.canReplace)
        XCTAssertFalse(second.replacePersistedRequest(resolving: conflict))
        XCTAssertEqual(draft(projectID, storage: storage).interruptedHandoffID, conversationID)
        XCTAssertEqual(second.brief, "A competing request")
    }

    func testExplicitReloadNeverIncludesResultsUnknownToTheSavedRequest() throws {
        let storage = InMemoryWorkDeskBriefDraftStorage(), projectID = UUID()
        let store = WorkDeskBriefDraftStore(storage: storage)
        let first = draft(projectID, store: store)
        first.brief = "Saved before the result arrived"
        let second = draft(projectID, store: store)
        first.brief = "Another window edit without the result"
        let resultID = UUID()
        second.projectResultIDs.insert(resultID)
        second.excludedIDs.insert(resultID)
        let conflict = try XCTUnwrap(second.persistenceConflict)
        XCTAssertTrue(second.reloadPersistedRequest(resolving: conflict))
        XCTAssertTrue(second.excludedIDs.contains(resultID))
        XCTAssertTrue(second.projectResultIDs.contains(resultID))
        XCTAssertFalse(second.isMaterialIncluded(resultID))
        XCTAssertTrue(second.persistChanges())
        XCTAssertFalse(draft(projectID, storage: storage).isMaterialIncluded(resultID))
    }

    func testProjectMutationPreservesDraftCleanupFailureForTheWorkspace() async {
        let storage = FailingStorage(), projectID = UUID()
        let store = WorkDeskBriefDraftStore(storage: storage)
        let tombstone = WorkDeskOrganizationSnapshot(deletedProjectIDs: [projectID])
        let organization = WorkDeskOrganization(fetch: { .init() }, apply: { _ in tombstone })
        let workspace = WorkDeskWorkspaceState(organization: organization, draftStore: store)
        let project = WorkDeskProjectRecord(id: projectID, title: "Deleted project")
        workspace.briefDraft(for: project, resolver: .init()).brief = "Could not remove"
        storage.failRemovals = true
        let saved = await organization.assign(materialIDs: [UUID()], to: nil)
        XCTAssertTrue(saved)
        XCTAssertNotNil(organization.errorMessage, "A committed mutation must not erase the following cleanup failure")
        XCTAssertNotNil(storage.records[projectID], "The cleanup error reflects real retained bytes")
    }

    func testRetryingInitialReadKeepsResultsThatArrivedDuringFailureExcluded() {
        let storage = FailingStorage(), projectID = UUID()
        draft(projectID, storage: storage).brief = "Saved before a result arrived"
        storage.failReads = true
        let reopened = draft(projectID, storage: storage)
        let resultID = UUID()
        reopened.projectResultIDs.insert(resultID)
        reopened.excludedIDs.insert(resultID)
        storage.failReads = false
        XCTAssertTrue(reopened.persistChanges())
        XCTAssertEqual(reopened.brief, "Saved before a result arrived")
        XCTAssertTrue(reopened.projectResultIDs.contains(resultID))
        XCTAssertFalse(reopened.isMaterialIncluded(resultID))
        XCTAssertTrue(reopened.persistChanges())
        XCTAssertFalse(draft(projectID, storage: storage).isMaterialIncluded(resultID))
    }

    private func draft(_ projectID: UUID, storage: any WorkDeskBriefDraftStorage,
                       context: String = "Project context") -> WorkDeskBriefDraft {
        draft(projectID, store: WorkDeskBriefDraftStore(storage: storage), context: context)
    }

    private func draft(_ projectID: UUID, store: WorkDeskBriefDraftStore,
                       context: String = "Project context") -> WorkDeskBriefDraft {
        WorkDeskBriefDraft(brief: context, preferredGatewayRef: nil, projectID: projectID, persistence: store)
    }

    private final class FailingStorage: WorkDeskBriefDraftStorage {
        enum Failure: Error { case unavailable }
        var records: [UUID: Data] = [:]
        var failReads = false, failWrites = false, failRemovals = false
        func read(projectID: UUID) throws -> Data? {
            if failReads { throw Failure.unavailable }
            return records[projectID]
        }
        func write(_ data: Data, projectID: UUID) throws {
            if failWrites { throw Failure.unavailable }
            records[projectID] = data
        }
        func remove(projectID: UUID) throws {
            if failRemovals { throw Failure.unavailable }
            records.removeValue(forKey: projectID)
        }
        func eraseAll() throws {
            if failRemovals { throw Failure.unavailable }
            records.removeAll()
        }
    }
}
