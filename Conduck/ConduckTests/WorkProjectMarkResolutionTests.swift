// SPDX-License-Identifier: Apache-2.0

// Conduck
// WorkProjectMarkResolutionTests.swift
//
// The one live-project resolver and its three readers. A conversation's
// `projectID` is a durable identifier that outlives its project (deletion
// leaves an identity-only tombstone and the conversations keep the id), so
// "in a project" has to be resolved against the LIVE rows every time, and
// every surface has to resolve it the same way: the desk snapshot, the list
// marks, the wrist's identifiers, the CarPlay picker and the thread's own
// standing all sit on `canonicalLiveProjectRows`. These cases pin the rules
// that loop encodes (tombstone beats duplicate, newest duplicate wins,
// untitled row is not yet a project) against real isolated stores, and pin
// the colours a legacy project receives to EXPLICIT palette positions rather
// than to "whatever the other reader said" — two readers on one helper
// cannot catch a shared regression by agreeing with each other.

import XCTest
import CoreData
@testable import Conduck

final class WorkProjectMarkResolutionTests: XCTestCase {
    private let isolated = IsolatedWorkStores()

    override func tearDown() async throws {
        await isolated.cleanUp()
        try await super.tearDown()
    }

    /// A Pro store whose entitlement the test can withdraw mid-case.
    private final class AccessFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var pro: Bool
        init(pro: Bool) { self.pro = pro }
        var snapshot: ProAccessSnapshot {
            lock.lock(); defer { lock.unlock() }
            return .init(hasProAccess: pro)
        }
        func set(pro: Bool) { lock.lock(); self.pro = pro; lock.unlock() }
    }

    private func proStore() -> ConversationStore {
        isolated.make(proAccessProvider: { .init(hasProAccess: true) })
    }

    /// Insert a raw `WorkDeskProject` row the way a CloudKit import would —
    /// no mutation path, so duplicates and tombstones can be staged exactly.
    private func insertProjectRow(
        _ store: ConversationStore, id: UUID, title: String?, updatedAt: Date, createdAt: Date = Date(),
        colorID: String? = nil, archivedAt: Date? = nil, deletedAt: Date? = nil
    ) async throws {
        try await store.ensureLoaded()
        let context = await store.newWriteContext()
        try await context.perform {
            let row = NSEntityDescription.insertNewObject(forEntityName: "WorkDeskProject", into: context)
            row.setValue(id, forKey: "id")
            row.setValue(title, forKey: "title")
            row.setValue(updatedAt, forKey: "updatedAt")
            row.setValue(createdAt, forKey: "createdAt")
            row.setValue(colorID, forKey: "colorID")
            row.setValue(archivedAt, forKey: "archivedAt")
            row.setValue(deletedAt, forKey: "deletedAt")
            try context.save()
        }
    }

    // MARK: - resolve(_:) — the three answers

    func testResolveDistinguishesUnfiledUnsyncedLiveAndDeleted() {
        let live = WorkProjectMark(id: UUID(), title: "Q3 launch", color: .sage, isArchived: false)
        let deleted = UUID()
        let set = WorkProjectMarkSet(marks: [live.id: live], tombstonedIDs: [deleted])

        XCTAssertEqual(set.resolve(nil), .none, "no membership")
        XCTAssertEqual(set.resolve(live.id), .live(live))
        XCTAssertEqual(set.resolve(deleted), .none, "a deleted project's ghost membership draws nothing")
        XCTAssertEqual(set.resolve(UUID()), .unsynced, "an id with no row yet is a folder with no name, never hidden")
    }

    func testSymbolFollowsTheWorkSidebar() {
        let archived = WorkProjectMark(id: UUID(), title: "Old", color: .amber, isArchived: true)
        let active = WorkProjectMark(id: UUID(), title: "New", color: .amber, isArchived: false)
        XCTAssertNil(WorkProjectMarkResolution.none.symbolName, "an unfiled row reserves no slot")
        XCTAssertEqual(WorkProjectMarkResolution.unsynced.symbolName, "folder")
        XCTAssertEqual(WorkProjectMarkResolution.live(active).symbolName, "folder")
        XCTAssertEqual(WorkProjectMarkResolution.live(archived).symbolName, "archivebox")
    }

    // MARK: - The canonical rows

    func testTombstoneBeatsANewerLiveDuplicateAndUntitledRowsAreNotProjects() async throws {
        let store = proStore()
        let ghost = UUID(), arriving = UUID(), live = UUID()
        let now = Date()
        // A deleted project whose live duplicate re-imported LATER: still gone.
        try await insertProjectRow(store, id: ghost, title: nil, updatedAt: now, deletedAt: now)
        try await insertProjectRow(store, id: ghost, title: "Ghost", updatedAt: now.addingTimeInterval(60))
        // A row whose title has not arrived yet: not a project until it does.
        try await insertProjectRow(store, id: arriving, title: nil, updatedAt: now)
        try await insertProjectRow(store, id: live, title: "Live", updatedAt: now)

        let ids = try await store.fetchLiveWorkProjectIDs()
        XCTAssertEqual(ids, [live])

        let marks = try await store.fetchWorkProjectMarks()
        XCTAssertEqual(Set(marks.marks.keys), [live])
        XCTAssertEqual(marks.tombstonedIDs, [ghost])
        XCTAssertEqual(marks.resolve(ghost), .none)
        XCTAssertEqual(marks.resolve(arriving), .unsynced)
    }

    func testTheNewestDuplicateNamesAndColoursTheProject() async throws {
        let store = proStore()
        let id = UUID()
        let now = Date()
        try await insertProjectRow(store, id: id, title: "Older name", updatedAt: now, colorID: "coral")
        try await insertProjectRow(store, id: id, title: "Newer name", updatedAt: now.addingTimeInterval(1), colorID: "blue")

        let marks = try await store.fetchWorkProjectMarks()
        XCTAssertEqual(marks.marks[id], WorkProjectMark(id: id, title: "Newer name", color: .blue, isArchived: false))
        let organization = try await store.fetchWorkDeskOrganization()
        XCTAssertEqual(organization.projects.first { $0.id == id }?.title, "Newer name")
    }

    func testArchivedProjectsAreLiveWithTheArchivedFlag() async throws {
        let store = proStore()
        let project = WorkDeskProjectRecord(title: "Paused", color: .lavender)
        _ = try await store.applyWorkDeskMutation(.createProject(project, materialIDs: []))
        _ = try await store.applyWorkDeskMutation(.archiveProject(id: project.id, isArchived: true))

        let ids = try await store.fetchLiveWorkProjectIDs()
        XCTAssertEqual(ids, [project.id], "the glyph answers membership, not whether a new turn is allowed")
        let marks = try await store.fetchWorkProjectMarks()
        let mark = try XCTUnwrap(marks.marks[project.id])
        XCTAssertTrue(mark.isArchived)
        XCTAssertEqual(mark.color, .lavender)
    }

    /// The legacy colour pass, pinned to explicit palette positions in creation
    /// order — `leastUsed` cycles the palette in order and only reuses once the
    /// whole palette is spent — from BOTH readers.
    func testLegacyProjectsReceiveExplicitPaletteColoursInCreationOrder() async throws {
        let store = proStore()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        var ids: [UUID] = []
        for index in 0..<7 {
            let id = UUID()
            ids.append(id)
            try await insertProjectRow(store, id: id, title: "Legacy \(index)", updatedAt: base,
                                       createdAt: base.addingTimeInterval(Double(index)))
        }
        let expected: [WorkDeskProjectColor] = [.amber, .sage, .blue, .lavender, .coral, .slate, .amber]

        let marks = try await store.fetchWorkProjectMarks()
        XCTAssertEqual(ids.map { marks.marks[$0]?.color }, expected)

        let organization = try await store.fetchWorkDeskOrganization()
        XCTAssertEqual(ids.map { id in organization.projects.first { $0.id == id }?.color }, expected)
    }

    // MARK: - The thread's standing

    func testThreadMarkNamesTheProjectAndItsRefusal() async throws {
        let flag = AccessFlag(pro: true)
        let store = isolated.make(proAccessProvider: { flag.snapshot })
        let project = WorkDeskProjectRecord(title: "Q3 launch", color: .sage)
        _ = try await store.applyWorkDeskMutation(.createProject(project, materialIDs: []))
        let thread = try await store.createConversation(backend: "hermes", projectID: project.id)
        let plain = try await store.createConversation(backend: "hermes")

        var mark = try await store.workProjectThreadMark(conversationID: thread.id)
        XCTAssertEqual(mark.resolution, .live(WorkProjectMark(id: project.id, title: "Q3 launch", color: .sage, isArchived: false)))
        XCTAssertNil(mark.refusal)

        let plainMark = try await store.workProjectThreadMark(conversationID: plain.id)
        XCTAssertEqual(plainMark.resolution, .none)

        _ = try await store.applyWorkDeskMutation(.archiveProject(id: project.id, isArchived: true))
        mark = try await store.workProjectThreadMark(conversationID: thread.id)
        XCTAssertEqual(mark.resolution.liveMark?.isArchived, true)
        XCTAssertEqual(mark.refusal, .archived)
        var refusal = await store.workProjectActivityRefusal(projectID: project.id)
        XCTAssertEqual(refusal, .archived)

        _ = try await store.applyWorkDeskMutation(.archiveProject(id: project.id, isArchived: false))
        // Four active projects on a library that loses Pro: the choice is
        // pending, and every project thread waits for it.
        for index in 0..<3 {
            _ = try await store.applyWorkDeskMutation(.createProject(WorkDeskProjectRecord(title: "Extra \(index)"), materialIDs: []))
        }
        flag.set(pro: false)
        mark = try await store.workProjectThreadMark(conversationID: thread.id)
        XCTAssertEqual(mark.refusal, .selectionRequired)
        refusal = await store.workProjectActivityRefusal(projectID: project.id)
        XCTAssertEqual(refusal, .selectionRequired)
        flag.set(pro: true)
        mark = try await store.workProjectThreadMark(conversationID: thread.id)
        XCTAssertNil(mark.refusal)
        refusal = await store.workProjectActivityRefusal(projectID: project.id)
        XCTAssertNil(refusal)
    }

    func testADeletedProjectLeavesAGhostMembershipThatMarksNothing() async throws {
        let store = proStore()
        let project = WorkDeskProjectRecord(title: "Gone")
        _ = try await store.applyWorkDeskMutation(.createProject(project, materialIDs: []))
        let thread = try await store.createConversation(backend: "hermes", projectID: project.id)
        _ = try await store.applyWorkDeskMutation(.deleteProject(id: project.id))

        let kept = try await store.fetchConversation(id: thread.id)
        XCTAssertEqual(kept?.projectID, project.id,
                       "the conversation keeps the identifier — the row cannot tell a ghost apart on its own")
        let mark = try await store.workProjectThreadMark(conversationID: thread.id)
        XCTAssertEqual(mark.resolution, .none)
        XCTAssertNil(mark.refusal)
        let ids = try await store.fetchLiveWorkProjectIDs()
        XCTAssertEqual(ids, [])
    }

    func testAMissingConversationThrowsRatherThanReadingAsUnfiled() async throws {
        let store = proStore()
        do {
            _ = try await store.workProjectThreadMark(conversationID: UUID())
            XCTFail("a thread that cannot be read is not an ordinary chat")
        } catch let error as ConversationStore.WorkProjectThreadMarkError {
            XCTAssertEqual(error, .conversationMissing)
        }
    }

    // MARK: - The CarPlay picker

    func testRecentPickerRowsCarryLiveMembershipOnly() async throws {
        let store = proStore()
        let project = WorkDeskProjectRecord(title: "Live")
        _ = try await store.applyWorkDeskMutation(.createProject(project, materialIDs: []))
        let archived = WorkDeskProjectRecord(title: "Archived")
        _ = try await store.applyWorkDeskMutation(.createProject(archived, materialIDs: []))
        let doomed = WorkDeskProjectRecord(title: "Doomed")
        _ = try await store.applyWorkDeskMutation(.createProject(doomed, materialIDs: []))

        let inLive = try await store.createConversation(backend: "hermes", projectID: project.id)
        let inArchived = try await store.createConversation(backend: "hermes", projectID: archived.id)
        let inDoomed = try await store.createConversation(backend: "hermes", projectID: doomed.id)
        let plain = try await store.createConversation(backend: "hermes")
        // The threads exist first; an archived project accepts no new one.
        _ = try await store.applyWorkDeskMutation(.archiveProject(id: archived.id, isArchived: true))
        _ = try await store.applyWorkDeskMutation(.deleteProject(id: doomed.id))
        // An id this device holds no row for at all.
        let unsynced = try await store.createConversation(backend: "hermes")
        let context = await store.newWriteContext()
        try await context.perform {
            let request = NSFetchRequest<NSManagedObject>(entityName: "Conversation")
            request.predicate = NSPredicate(format: "id == %@", unsynced.id as CVarArg)
            try XCTUnwrap(context.fetch(request).first).setValue(UUID(), forKey: "projectID")
            try context.save()
        }

        let rows = try await store.fetchRecentForPicker(limit: 10)
        let byID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0.inLiveProject) })
        XCTAssertEqual(byID[inLive.id], true)
        XCTAssertEqual(byID[inArchived.id], true, "archived is live — the folder marks membership")
        XCTAssertEqual(byID[inDoomed.id], false, "a deleted project's ghost draws no folder in the car")
        XCTAssertEqual(byID[plain.id], false)
        XCTAssertEqual(byID[unsynced.id], false, "the car marks only what it can vouch for")
        // The name rides with the membership, stored as typed: the car's own
        // detail line projects and caps it.
        let titles = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0.projectTitle) })
        XCTAssertEqual(titles[inLive.id], "Live")
        XCTAssertEqual(titles[inArchived.id], "Archived")
        XCTAssertEqual(titles[inDoomed.id], .some(nil))
        XCTAssertEqual(titles[unsynced.id], .some(nil))
    }

    /// A mark can change under an UNCHANGED conversation list — the project
    /// row arrives, or its tombstone does — and the list has to repaint on it.
    @MainActor
    func testTheListModelRepaintsWhenOnlyTheMarksChange() async throws {
        // `ConversationListViewModel` reads the shared store; this pins the
        // set's equality, which is what its reload keys the repaint on.
        let mark = WorkProjectMark(id: UUID(), title: "Q3 launch", color: .amber, isArchived: false)
        let before = WorkProjectMarkSet()
        let arrived = WorkProjectMarkSet(marks: [mark.id: mark], tombstonedIDs: [])
        let deleted = WorkProjectMarkSet(marks: [:], tombstonedIDs: [mark.id])
        XCTAssertNotEqual(before, arrived)
        XCTAssertNotEqual(arrived, deleted)
        XCTAssertNotEqual(before, deleted, "a tombstone is a change even when no mark is drawn")
    }
}
