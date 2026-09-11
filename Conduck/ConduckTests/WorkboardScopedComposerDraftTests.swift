// SPDX-License-Identifier: Apache-2.0

// A half-written thought belongs to its capture scope, including the unfiled
// global-search lane. Resolve that scope synchronously so navigation cannot
// submit yesterday's project draft into today's destination. Delayed saves
// clear only their own unchanged draft; equal words elsewhere are independent.

import XCTest
import Observation
@testable import Conduck

@MainActor
final class WorkboardScopedComposerDraftTests: XCTestCase {
    private enum TestError: Error { case unexpectedCall }
    private final class ChangeFlag { var changed = false }

    func testEmptinessReadersIgnoreKeystrokesUntilNormalizedEmptinessChanges() {
        let model = makeViewModel()
        model.setComposerDraft("A thought")
        let flag = ChangeFlag()
        withObservationTracking {
            _ = model.hasComposerDraft
        } onChange: { MainActor.assumeIsolated { flag.changed = true } }

        model.setComposerDraft("A thought with more words")
        XCTAssertFalse(flag.changed)
        model.setComposerDraft(" \n ")
        XCTAssertTrue(flag.changed)
        XCTAssertFalse(model.hasComposerDraft)
    }

    func testProjectDraftsAndAllDraftSurviveScopeRoundTrips() {
        let model = makeViewModel()
        let first = WorkDeskScope.project(UUID())
        let second = WorkDeskScope.project(UUID())
        model.setComposerDraft("All thought")
        model.deskWorkspace.selectScope(first)
        XCTAssertEqual(model.composerDraft, "")
        XCTAssertFalse(model.hasComposerDraft)
        model.setComposerDraft("First thought")
        model.deskWorkspace.selectScope(second)
        model.setComposerDraft("  \n")
        XCTAssertFalse(model.hasComposerDraft)

        model.deskWorkspace.selectScope(.all)
        XCTAssertEqual(model.composerDraft, "All thought")
        XCTAssertTrue(model.hasComposerDraft)
        model.deskWorkspace.selectScope(first)
        XCTAssertEqual(model.composerDraft, "First thought")
        XCTAssertTrue(model.hasComposerDraft)
        model.deskWorkspace.selectScope(second)
        XCTAssertEqual(model.composerDraft, "  \n")
        XCTAssertFalse(model.hasComposerDraft)
    }

    func testEmptinessReadersIgnoreSearchEditsWithinSameScope() {
        let model = makeViewModel()
        model.setComposerDraft("All thought")
        model.deskWorkspace.selectScope(.project(UUID()))
        model.deskWorkspace.search = "first"
        let flag = ChangeFlag()
        withObservationTracking {
            _ = model.hasComposerDraft
        } onChange: { MainActor.assumeIsolated { flag.changed = true } }

        model.deskWorkspace.search = "first second"
        model.deskWorkspace.search = "  first second  "
        XCTAssertFalse(flag.changed)
        XCTAssertTrue(model.hasComposerDraft)

        model.deskWorkspace.search = " \n "
        XCTAssertTrue(flag.changed, "leaving search must subscribe to the project's draft")
        XCTAssertFalse(model.hasComposerDraft)
    }

    func testNavigationImmediatelyPreventsProjectDraftSubmittingIntoAll() async {
        let model = makeViewModel()
        let project = WorkDeskScope.project(UUID())
        model.deskWorkspace.selectScope(project)
        model.setComposerDraft("Only for this project")

        model.deskWorkspace.selectScope(.all)
        let destination = WorkboardCaptureDestination(workspace: model.deskWorkspace)
        let added = await model.addThought(model.composerDraft, projectID: destination.projectID)

        XCTAssertFalse(added)
        XCTAssertNil(model.desk)
        XCTAssertEqual(model.composerDraft(for: project), "Only for this project")
    }

    func testGlobalSearchUsesAllDraftAndRestoresProjectDraftOnExit() {
        let model = makeViewModel()
        let project = WorkDeskScope.project(UUID())
        model.setComposerDraft("An unfiled thought")
        model.deskWorkspace.selectScope(project)
        model.setComposerDraft("A project thought")
        model.deskWorkspace.search = "across projects"

        XCTAssertEqual(model.composerScope, .all)
        XCTAssertEqual(model.composerDraft, "An unfiled thought")
        model.setComposerDraft("Changed in search")
        model.deskWorkspace.search = ""

        XCTAssertEqual(model.composerScope, project)
        XCTAssertEqual(model.composerDraft, "A project thought")
        model.deskWorkspace.selectScope(.all)
        XCTAssertEqual(model.composerDraft, "Changed in search")
    }

    func testDelayedSuccessClearsOriginalScopeWithoutClearingEqualTextElsewhere() {
        let model = makeViewModel()
        let project = WorkDeskScope.project(UUID())
        model.deskWorkspace.selectScope(project)
        model.setComposerDraft("Same words")
        let capturedScope = model.composerScope
        let capturedText = model.composerDraft
        model.deskWorkspace.selectScope(.all)
        model.setComposerDraft("Same words")

        model.clearComposerDraft(capturedText, in: capturedScope)

        XCTAssertEqual(model.composerDraft, "Same words")
        XCTAssertEqual(model.composerDraft(for: project), "")
        model.deskWorkspace.selectScope(project)
        XCTAssertFalse(model.hasComposerDraft)
    }

    func testDelayedSuccessPreservesNewEditsInOriginalScope() {
        let model = makeViewModel()
        let project = WorkDeskScope.project(UUID())
        model.deskWorkspace.selectScope(project)
        model.setComposerDraft("First words")
        let captured = model.composerDraft
        model.setComposerDraft("First words and another idea")
        model.deskWorkspace.selectScope(.all)

        model.clearComposerDraft(captured, in: project)

        XCTAssertEqual(model.composerDraft(for: project), "First words and another idea")
    }

    func testFrozenVoiceFallbackRestoresVisibleOriginalDraftAfterNavigation() async throws {
        let record = WorkDeskProjectRecord(title: "Original")
        let organization = WorkDeskOrganization(
            fetch: { WorkDeskOrganizationSnapshot(projects: [record]) },
            apply: { _ in throw TestError.unexpectedCall }
        )
        let workspace = WorkDeskWorkspaceState(organization: organization)
        await organization.reload()
        let model = makeViewModel(workspace: workspace)
        let project = WorkDeskScope.project(record.id)
        model.deskWorkspace.selectScope(project)
        model.setComposerDraft("Typed")
        let recordingScope = model.composerScope
        model.deskWorkspace.selectScope(.all)
        model.setComposerDraft("Unfiled")

        model.receiveComposerTranscript("spoken", in: recordingScope)

        XCTAssertEqual(model.composerScope, project)
        XCTAssertEqual(model.composerDraft, "Typed\n\nspoken")
        XCTAssertEqual(model.composerDraft(for: .all), "Unfiled")
    }

    func testVoiceFallbackAfterProjectDeletionAppearsInAllMaterials() {
        let model = makeViewModel()
        model.setComposerDraft("Unfiled")
        let project = WorkDeskScope.project(UUID())
        model.deskWorkspace.selectScope(project)

        model.receiveComposerTranscript("Words from deleted project", in: project)

        XCTAssertEqual(model.composerScope, .all)
        XCTAssertEqual(model.composerDraft, "Unfiled\n\nWords from deleted project")
    }

    func testUnfiledVoiceFallbackLeavesGlobalSearchShowingTheWords() {
        let model = makeViewModel()
        model.deskWorkspace.selectScope(.project(UUID()))
        model.deskWorkspace.search = "find something"

        model.receiveComposerTranscript("Unfiled words", in: .all)

        XCTAssertEqual(model.deskWorkspace.search, "find something")
        XCTAssertEqual(model.composerScope, .all)
        XCTAssertEqual(model.composerDraft, "Unfiled words")
    }

    func testVoiceFallbackUsesAllWhenAnotherWindowKnowsProjectWasDeleted() async {
        let record = WorkDeskProjectRecord(title: "Stale project")
        let organization = WorkDeskOrganization(
            fetch: { WorkDeskOrganizationSnapshot(projects: [record]) },
            apply: { _ in throw TestError.unexpectedCall }
        )
        await organization.reload()
        let model = makeViewModel(workspace: WorkDeskWorkspaceState(organization: organization))
        let project = WorkDeskScope.project(record.id)
        model.deskWorkspace.selectScope(project)
        WorkboardLayoutMode.pruneProjectPreferences(deletedProjectIDs: [record.id])

        model.receiveComposerTranscript("Words must stay visible", in: project)

        XCTAssertEqual(model.composerScope, .all)
        XCTAssertEqual(model.composerDraft, "Words must stay visible")
    }

    func testRejectedThoughtLeavesItsOriginalDraftAvailable() async {
        let model = makeViewModel()
        let projectID = UUID()
        let scope = WorkDeskScope.project(projectID)
        model.deskWorkspace.selectScope(scope)
        model.setComposerDraft("Keep my words")

        let added = await model.addThought(model.composerDraft, projectID: projectID)

        XCTAssertFalse(added)
        XCTAssertEqual(model.composerDraft(for: scope), "Keep my words")
        XCTAssertTrue(model.hasComposerDraft)
    }

    private func makeViewModel(workspace: WorkDeskWorkspaceState? = nil) -> WorkboardViewModel {
        let workspace = workspace ?? WorkDeskWorkspaceState(organization: WorkDeskOrganization(
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
