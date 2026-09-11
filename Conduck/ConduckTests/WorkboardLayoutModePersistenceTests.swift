// SPDX-License-Identifier: Apache-2.0

// ConduckTests
// WorkboardLayoutModePersistenceTests.swift
//
// Every layout control drives the model's effective scope preference. The
// legacy raw key continues to mean All materials, preserving existing choices;
// project UUID slots survive relaunch independently. Reads and navigation must
// not persist defaults or temporary readable fallbacks, and only a successful
// organization snapshot's explicit tombstones may prune removed projects.
//
// The host is built with `CONDUCK_TESTING`, so the defaults these tests read
// and clear are the in-memory double the app itself is running on.

import XCTest
@testable import Conduck

@MainActor
final class WorkboardLayoutModePersistenceTests: XCTestCase {
    private enum TestError: Error { case unexpectedCall }

    private actor SnapshotGate {
        private var pending: CheckedContinuation<WorkDeskOrganizationSnapshot, Never>?
        private var startedWaiters: [CheckedContinuation<Void, Never>] = []

        func fetch() async -> WorkDeskOrganizationSnapshot {
            await withCheckedContinuation { continuation in
                pending = continuation
                for waiter in startedWaiters { waiter.resume() }
                startedWaiters.removeAll()
            }
        }

        func waitUntilStarted() async {
            if pending != nil { return }
            await withCheckedContinuation { startedWaiters.append($0) }
        }

        func finish() {
            pending?.resume(returning: WorkDeskOrganizationSnapshot())
            pending = nil
        }
    }

    override func setUp() async throws {
        try await super.setUp()
        TestStores.defaults.removeObject(forKey: Constants.workboardLayoutKey)
        clearProjectPreferences()
    }

    override func tearDown() async throws {
        TestStores.defaults.removeObject(forKey: Constants.workboardLayoutKey)
        clearProjectPreferences()
        try await super.tearDown()
    }

    // MARK: - Adoption

    func testLayoutModeDefaultsToSpatialDeskWithNothingStored() {
        XCTAssertEqual(makeViewModel().layoutMode, .desk)
    }

    func testLayoutModeAdoptsThePersistedModeOnConstruction() {
        WorkboardLayoutMode.list.save()

        XCTAssertEqual(makeViewModel().layoutMode, .list)
    }

    // MARK: - Persistence

    func testSettingLayoutModePersistsIt() {
        let viewModel = makeViewModel()

        viewModel.layoutMode = .list

        XCTAssertEqual(WorkboardLayoutMode.load(), .list)
    }

    func testAPersistedLayoutModeOutlivesTheModelThatWroteIt() {
        makeViewModel().layoutMode = .list

        // A relaunch is exactly this: a second model reading the same store.
        XCTAssertEqual(makeViewModel().layoutMode, .list)
    }

    func testSwitchingBackToTilesPersistsToo() {
        WorkboardLayoutMode.list.save()
        let viewModel = makeViewModel()

        viewModel.layoutMode = .tiles

        XCTAssertEqual(WorkboardLayoutMode.load(), .tiles)
        XCTAssertEqual(makeViewModel().layoutMode, .tiles)
    }

    /// Every case, through the STORE rather than only through `load()`.
    ///
    /// All materials falls back to Canvas on a missing or unreadable value, so a
    /// Canvas assertion taken on `load()` alone cannot tell a value that was
    /// written and read back from a value that was never written at all — the
    /// fallback answers Canvas for both. Reading the raw string out of the store
    /// separates them, and `allCases` keeps the pair of assertions honest when a
    /// third layout is added: a case whose `rawValue` collides or whose write
    /// never lands fails here instead of shipping as "it just opens in Tiles".
    func testEveryLayoutModeRoundTripsThroughItsStoredRawValue() {
        for mode in WorkboardLayoutMode.allCases {
            // Path 1 — the type's own writer.
            TestStores.defaults.removeObject(forKey: Constants.workboardLayoutKey)
            mode.save()

            XCTAssertEqual(
                TestStores.defaults.string(forKey: Constants.workboardLayoutKey), mode.rawValue,
                "\(mode) did not store its own raw value. Nothing is in the store for the next launch "
                + "to read, and `load()` will answer Canvas from its fallback whatever this case was."
            )
            XCTAssertEqual(
                WorkboardLayoutMode.load(), mode,
                "\(mode) did not survive a read back through `load()` — the value written and the "
                + "value parsed disagree."
            )
            XCTAssertEqual(
                makeViewModel().layoutMode, mode,
                "A model built after \(mode) was stored did not adopt it, so a relaunch opens the "
                + "desk in a layout the user did not choose."
            )

            // Path 2 — the model's setter, which is what either layout picker
            // actually drives. Run from a CLEARED store, so a case that happens
            // to match the fallback still has to prove it wrote something.
            TestStores.defaults.removeObject(forKey: Constants.workboardLayoutKey)
            makeViewModel().layoutMode = mode

            XCTAssertEqual(
                TestStores.defaults.string(forKey: Constants.workboardLayoutKey), mode.rawValue,
                "Assigning \(mode) on the view model stored nothing. The preference then lives only "
                + "in the model that made the change and dies with it — invisible on screen for as "
                + "long as that model is alive."
            )
            XCTAssertEqual(
                WorkboardLayoutMode.load(), mode,
                "Assigning \(mode) on the view model did not reach the value a next launch reads."
            )
        }
    }

    func testProjectAndAllMaterialsChoicesStayIndependentAcrossRelaunch() {
        let project = WorkDeskScope.project(UUID())
        let otherProject = WorkDeskScope.project(UUID())
        let model = makeViewModel()
        model.layoutMode = .tiles
        model.deskWorkspace.selectScope(project)
        model.layoutMode = .list

        model.deskWorkspace.selectScope(.all)
        XCTAssertEqual(model.layoutMode, .tiles)
        model.layoutMode = .desk
        model.deskWorkspace.selectScope(project)
        XCTAssertEqual(model.layoutMode, .list)
        model.deskWorkspace.selectScope(otherProject)
        XCTAssertEqual(model.layoutMode, .tiles)
        XCTAssertNil(TestStores.defaults.object(forKey: WorkboardLayoutMode.preferenceKey(for: otherProject)))

        let relaunched = makeViewModel()
        XCTAssertEqual(relaunched.layoutMode, .desk)
        relaunched.deskWorkspace.selectScope(project)
        XCTAssertEqual(relaunched.layoutMode, .list)
        XCTAssertEqual(TestStores.defaults.string(forKey: Constants.workboardLayoutKey), "desk")
        XCTAssertEqual(TestStores.defaults.string(forKey: WorkboardLayoutMode.preferenceKey(for: project)), "list")
    }

    func testEveryProjectChoiceIncludingCanvasOutlivesItsModel() {
        let scope = WorkDeskScope.project(UUID())
        for mode in WorkboardLayoutMode.allCases {
            let model = makeViewModel()
            model.deskWorkspace.selectScope(scope)
            model.layoutMode = mode
            XCTAssertEqual(TestStores.defaults.string(forKey: WorkboardLayoutMode.preferenceKey(for: scope)), mode.rawValue)
            let relaunched = makeViewModel()
            relaunched.deskWorkspace.selectScope(scope)
            XCTAssertEqual(relaunched.layoutMode, mode)
        }
        XCTAssertNil(TestStores.defaults.object(forKey: Constants.workboardLayoutKey))
    }

    func testScopeAndSearchNavigationNeverWritesStoredValues() {
        let remembered = WorkDeskScope.project(UUID())
        WorkboardLayoutMode.desk.save(for: remembered)
        WorkboardLayoutMode.list.save()
        let before = TestStores.defaults.dictionaryRepresentation() as NSDictionary
        let model = makeViewModel()

        for scope in [remembered, .project(UUID()), .all, remembered] {
            model.deskWorkspace.selectScope(scope)
            let preference = model.layoutMode
            model.deskWorkspace.search = "an idea"
            _ = WorkDeskLayoutPresentation.resolved(preference: model.layoutMode,
                supportsSpatialLayout: model.deskWorkspace.supportsSpatialLayout,
                requiresAccessibleList: false)
            XCTAssertEqual(model.layoutMode, .list, "search uses All materials' preference")
            model.deskWorkspace.search = ""
            XCTAssertEqual(model.layoutMode, preference)
            XCTAssertEqual(TestStores.defaults.dictionaryRepresentation() as NSDictionary, before)
        }
    }

    func testFirstProjectReadDefaultsToTilesWithoutCreatingAStoredEntry() {
        let model = makeViewModel()
        let project = WorkDeskScope.project(UUID())
        model.deskWorkspace.selectScope(project)
        XCTAssertEqual(model.layoutMode, .tiles)
        XCTAssertNil(TestStores.defaults.object(forKey: WorkboardLayoutMode.preferenceKey(for: project)))
        XCTAssertNil(TestStores.defaults.object(forKey: Constants.workboardLayoutKey))
    }

    func testOrganizationTombstonesPruneOnlyExplicitlyRemovedProjects() async {
        let retained = WorkDeskProjectRecord(title: "Retained")
        let removed = UUID()
        WorkboardLayoutMode.list.save(for: .project(retained.id))
        WorkboardLayoutMode.desk.save(for: .project(removed))
        WorkboardLayoutMode.tiles.save()
        let organization = WorkDeskOrganization(
            fetch: { WorkDeskOrganizationSnapshot(projects: [retained], deletedProjectIDs: [removed]) },
            apply: { _ in throw TestError.unexpectedCall }
        )
        // Merely constructing an empty presentation does not prune anything.
        XCTAssertEqual(WorkboardLayoutMode.load(for: .project(removed)), .desk)
        await organization.reload()
        XCTAssertNil(TestStores.defaults.object(forKey: WorkboardLayoutMode.preferenceKey(for: .project(removed))))
        XCTAssertEqual(WorkboardLayoutMode.load(for: .project(retained.id)), .list)
        XCTAssertEqual(WorkboardLayoutMode.load(), .tiles)
    }

    func testSearchReadsAndWritesAllMaterialsLayoutThenRestoresProjectLayout() {
        let project = WorkDeskScope.project(UUID())
        WorkboardLayoutMode.tiles.save(for: project)
        WorkboardLayoutMode.desk.save()
        let model = makeViewModel()
        model.deskWorkspace.selectScope(project)
        XCTAssertEqual(model.layoutMode, .tiles)

        model.deskWorkspace.search = "global results"
        XCTAssertEqual(model.layoutMode, .desk)
        model.layoutMode = .list
        XCTAssertEqual(WorkboardLayoutMode.load(), .list)
        XCTAssertEqual(WorkboardLayoutMode.load(for: project), .tiles)

        model.deskWorkspace.search = ""
        XCTAssertEqual(model.layoutMode, .tiles)
        let relaunched = makeViewModel()
        XCTAssertEqual(relaunched.layoutMode, .list)
        relaunched.deskWorkspace.selectScope(project)
        XCTAssertEqual(relaunched.layoutMode, .tiles)
    }

    func testEachTombstoneIsPrunedOnlyOnceAcrossTheProcess() {
        let first = UUID(), second = UUID()
        WorkboardLayoutMode.list.save(for: .project(first))
        XCTAssertEqual(WorkboardLayoutMode.pruneProjectPreferences(deletedProjectIDs: [first]), [first])
        XCTAssertTrue(WorkboardLayoutMode.pruneProjectPreferences(deletedProjectIDs: [first]).isEmpty)
        XCTAssertEqual(WorkboardLayoutMode.pruneProjectPreferences(deletedProjectIDs: [first, second]), [second])
        XCTAssertTrue(WorkboardLayoutMode.pruneProjectPreferences(deletedProjectIDs: [first, second]).isEmpty)

        // A stale window cannot put the reclaimed preference back after the
        // once-only pass, even before that window sees its own tombstone.
        WorkboardLayoutMode.desk.save(for: .project(first))
        XCTAssertNil(TestStores.defaults.object(forKey: WorkboardLayoutMode.preferenceKey(for: .project(first))))
        XCTAssertEqual(WorkboardLayoutMode.load(for: .project(first)), .tiles)
    }

    func testTombstonePrunesCachedSessionsInEveryWindowButKeepsLiveAndAllDrafts() async {
        let deletedID = UUID()
        let deleted = WorkDeskScope.project(deletedID)
        let retained = WorkDeskScope.project(UUID())
        let first = makeViewModel(), second = makeViewModel()
        WorkboardLayoutMode.list.save(for: deleted)
        let oldFirstLayout = first.deskWorkspace.layoutSession(for: deleted)
        let oldSecondLayout = second.deskWorkspace.layoutSession(for: deleted)
        weak var firstDraft: WorkDeskComposerSession? = first.deskWorkspace.composerSession(for: deleted)
        weak var secondDraft: WorkDeskComposerSession? = second.deskWorkspace.composerSession(for: deleted)
        firstDraft?.setText("First window's deleted draft")
        secondDraft?.setText("Second window's deleted draft")
        let allDraft = first.deskWorkspace.composerSession(for: .all)
        allDraft.setText("All materials draft")
        let retainedDraft = second.deskWorkspace.composerSession(for: retained)
        retainedDraft.setText("Live project draft")
        let retainedLayout = second.deskWorkspace.layoutSession(for: retained)
        retainedLayout.mode = .desk

        let organization = WorkDeskOrganization(
            fetch: { WorkDeskOrganizationSnapshot(deletedProjectIDs: [deletedID]) },
            apply: { _ in throw TestError.unexpectedCall }
        )
        await organization.reload()

        XCTAssertNil(firstDraft, "deleted drafts must be released, not just cleared")
        XCTAssertNil(secondDraft)
        XCTAssertEqual(oldFirstLayout.mode, .tiles, "existing observers receive the reset too")
        XCTAssertEqual(oldSecondLayout.mode, .tiles)
        XCTAssertFalse(first.deskWorkspace.layoutSession(for: deleted) === oldFirstLayout)
        XCTAssertEqual(second.deskWorkspace.layoutSession(for: deleted).mode, .tiles)
        XCTAssertFalse(first.deskWorkspace.composerSession(for: deleted).hasDraft)
        XCTAssertTrue(first.deskWorkspace.composerSession(for: .all) === allDraft)
        XCTAssertEqual(allDraft.text, "All materials draft")
        XCTAssertTrue(second.deskWorkspace.composerSession(for: retained) === retainedDraft)
        XCTAssertEqual(retainedDraft.text, "Live project draft")
        XCTAssertTrue(second.deskWorkspace.layoutSession(for: retained) === retainedLayout)
        XCTAssertEqual(retainedLayout.mode, .desk)
    }

    func testSessionRegistrationDoesNotRetainClosedWindows() {
        var model: WorkboardViewModel? = makeViewModel()
        weak var workspace: WorkDeskWorkspaceState? = model?.deskWorkspace
        weak var draft: WorkDeskComposerSession? = workspace?.composerSession(for: .project(UUID()))
        draft?.setText("Released with this window")
        model = nil
        XCTAssertNil(workspace)
        XCTAssertNil(draft)
    }

    func testCommittedProjectDeletionPrunesPreference() async {
        let project = UUID()
        WorkboardLayoutMode.list.save(for: .project(project))
        let organization = WorkDeskOrganization(
            fetch: { throw TestError.unexpectedCall },
            apply: { _ in WorkDeskOrganizationSnapshot(deletedProjectIDs: [project]) }
        )
        let deleted = await organization.deleteProject(id: project)
        XCTAssertTrue(deleted)
        XCTAssertNil(TestStores.defaults.object(forKey: WorkboardLayoutMode.preferenceKey(for: .project(project))))
    }

    func testFailedOrganizationLoadDoesNotPrunePreferences() async {
        let project = WorkDeskScope.project(UUID())
        WorkboardLayoutMode.list.save(for: project)
        let organization = WorkDeskOrganization(
            fetch: { throw TestError.unexpectedCall },
            apply: { _ in throw TestError.unexpectedCall }
        )
        await organization.reload()
        XCTAssertEqual(TestStores.defaults.string(forKey: WorkboardLayoutMode.preferenceKey(for: project)), "list")
    }

    func testOlderWindowSnapshotCannotPruneNewerWindowsProjectPreference() async {
        let project = WorkDeskProjectRecord(title: "Created elsewhere")
        let gate = SnapshotGate()
        let oldWindow = WorkDeskOrganization(
            fetch: { await gate.fetch() },
            apply: { _ in throw TestError.unexpectedCall }
        )
        let newWindow = WorkDeskOrganization(
            fetch: { WorkDeskOrganizationSnapshot(projects: [project]) },
            apply: { _ in throw TestError.unexpectedCall }
        )
        let oldLoad = Task { await oldWindow.reload() }
        await gate.waitUntilStarted()
        await newWindow.reload()
        let model = makeViewModel()
        model.deskWorkspace.selectScope(.project(project.id))
        model.layoutMode = .list

        // Window-local generation guards cannot reject an older snapshot
        // returned to another instance. It has no tombstone for this project.
        await gate.finish()
        await oldLoad.value

        XCTAssertEqual(TestStores.defaults.string(forKey:
            WorkboardLayoutMode.preferenceKey(for: .project(project.id))), "list")
        XCTAssertEqual(WorkboardLayoutMode.load(for: .project(project.id)), .list)
    }

    private func clearProjectPreferences() {
        for key in TestStores.defaults.dictionaryRepresentation().keys
            where key.hasPrefix(WorkboardLayoutMode.projectPreferencePrefix) {
            TestStores.defaults.removeObject(forKey: key)
        }
    }

    /// A board that only answers for its layout preference. Every desk
    /// operation throws or does nothing: none of them is reached here, and a
    /// stub that quietly succeeded would hide a test that started calling one.
    private func makeViewModel() -> WorkboardViewModel {
        let workspace = WorkDeskWorkspaceState(organization: WorkDeskOrganization(
            fetch: { throw TestError.unexpectedCall },
            apply: { _ in throw TestError.unexpectedCall }
        ))
        return WorkboardViewModel(dependencies: WorkboardViewModel.Dependencies(
            loadDesk: { nil },
            importMaterial: { _, _, _ in throw TestError.unexpectedCall },
            removeMaterial: { _, _ in throw TestError.unexpectedCall },
            replaceMaterial: { _, _, _, _ in throw TestError.unexpectedCall },
            openMaterial: { _ in }
        ), deskWorkspace: workspace)
    }
}
