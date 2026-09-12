// SPDX-License-Identifier: Apache-2.0

// The tour must never consume a capture intent, interrupt an existing editor,
// or change real Work content. These tests exercise the retained presentation
// state across delayed reads, overlapping owners, suspension and replay.

import XCTest
@testable import Conduck

@MainActor
final class WorkboardTutorialSessionTests: XCTestCase {
    private var available: WorkboardTutorialAvailability {
        .init(isActive: true, isReady: true, isBlocked: false)
    }

    func testLateAutomaticReadDoesNotDisplaceAStartedCapture() {
        let session = WorkboardTutorialSession()
        XCTAssertTrue(session.canEvaluateAutomatically(available))
        let recorder = UUID()
        session.setInteraction(owner: recorder, isBlocking: true, blocksAutomatic: false)
        session.resolveAutomaticDecision(true, availability: available)
        XCTAssertFalse(session.isRequested)
        XCTAssertFalse(session.hasEvaluatedAutomatic)
        session.removeInteraction(owner: recorder)
        session.resolveAutomaticDecision(true, availability: available)
        XCTAssertTrue(session.isPresented(available))
    }

    func testOverlappingPresentersReleaseOnlyTheirOwnBlocker() {
        let session = WorkboardTutorialSession()
        let source = UUID(), composer = UUID()
        session.setInteraction(owner: source, isBlocking: true, blocksAutomatic: false)
        session.setInteraction(owner: composer, isBlocking: true, blocksAutomatic: false)
        session.removeInteraction(owner: source)
        XCTAssertFalse(session.canEvaluateAutomatically(available))
        session.requestReplay()
        XCTAssertFalse(session.isPresented(available))
        session.removeInteraction(owner: composer)
        XCTAssertTrue(session.isPresented(available))
    }

    func testDirectedColdEntryStaysDeferredUntilAnotherWorkVisit() {
        let session = WorkboardTutorialSession()
        session.deferAutomaticForVisit()
        session.setDestinationActive(true)
        session.resolveAutomaticDecision(true, availability: available)
        XCTAssertFalse(session.hasEvaluatedAutomatic)
        XCTAssertFalse(session.isRequested)
        session.setDestinationActive(false)
        session.setDestinationActive(true)
        session.resolveAutomaticDecision(true, availability: available)
        XCTAssertTrue(session.isPresented(available))
    }

    func testSuspensionKeepsPageAndExampleChoicesWithoutAcknowledgement() {
        let session = WorkboardTutorialSession()
        session.setDestinationActive(true)
        session.resolveAutomaticDecision(true, availability: available)
        session.advance(); session.advance(); session.advance()
        session.includesResearch = true
        session.reviewsRequest = true
        var hidden = available
        hidden.isActive = false
        session.setDestinationActive(false)
        XCTAssertFalse(session.isPresented(hidden))
        XCTAssertFalse(session.acknowledge(hidden))
        session.setDestinationActive(true)
        XCTAssertTrue(session.isPresented(available))
        XCTAssertEqual(session.currentStep, 3)
        XCTAssertTrue(session.includesResearch)
        XCTAssertTrue(session.reviewsRequest)
    }

    func testNewCaptureSuspendsAnOpenTourForTheRestOfTheVisit() {
        let session = WorkboardTutorialSession()
        session.setDestinationActive(true)
        session.requestReplay()
        session.advance()
        session.deferAutomaticForVisit()
        XCTAssertFalse(session.isPresented(available))
        XCTAssertFalse(session.acknowledge(available))
        session.setDestinationActive(false)
        session.setDestinationActive(true)
        XCTAssertTrue(session.isPresented(available))
        XCTAssertEqual(session.currentStep, 1)
    }

    func testExistingDraftDefersAutomaticTourButDoesNotPreventExplicitHelp() {
        let session = WorkboardTutorialSession()
        let composer = UUID()
        session.setInteraction(owner: composer, isBlocking: false, blocksAutomatic: true)
        var editing = available
        editing.blocksAutomatic = true
        session.resolveAutomaticDecision(true, availability: editing)
        XCTAssertFalse(session.hasEvaluatedAutomatic)
        session.requestReplay()
        XCTAssertTrue(session.isPresented(editing))
        XCTAssertTrue(session.acknowledge(editing))
        XCTAssertTrue(session.hasAutomaticBlockers, "Finishing must not clear someone else's editor state")
    }

    func testAcknowledgedOrPreviouslySeenTourCanBeReplayedWithoutAutomaticRepeat() {
        let session = WorkboardTutorialSession()
        session.resolveAutomaticDecision(false, availability: available)
        XCTAssertFalse(session.isRequested)
        XCTAssertFalse(session.canEvaluateAutomatically(available))
        session.requestReplay()
        session.advance()
        XCTAssertTrue(session.acknowledge(available))
        XCTAssertFalse(session.isPresented(available))
        session.requestReplay()
        XCTAssertEqual(session.currentStep, 0)
        XCTAssertTrue(session.isPresented(available))
    }

    func testGoToWorkPreservesCurrentProjectConversationAndDrafts() {
        enum Unexpected: Error { case mutation }
        let workspace = WorkDeskWorkspaceState(organization: WorkDeskOrganization(
            fetch: { throw Unexpected.mutation }, apply: { _ in throw Unexpected.mutation }
        ))
        let model = WorkboardViewModel(dependencies: .init(
            loadDesk: { nil }, importMaterial: { _, _, _ in throw Unexpected.mutation },
            removeMaterial: { _, _ in throw Unexpected.mutation },
            replaceMaterial: { _, _, _, _ in throw Unexpected.mutation },
            openMaterial: { _ in XCTFail("Tour must not open a material") }
        ), deskWorkspace: workspace)
        let project = WorkDeskScope.project(UUID()), conversation = UUID()
        model.setComposerDraft("Keep the Home draft")
        workspace.selectScope(project)
        model.setComposerDraft("Keep the project draft")
        workspace.selectedConversationID = conversation
        model.tutorialSession.requestReplay()
        for _ in 0..<WorkboardTutorialSession.stepCount { model.tutorialSession.advance() }
        XCTAssertTrue(model.tutorialSession.acknowledge(available))
        XCTAssertEqual(workspace.scope, project)
        XCTAssertEqual(workspace.selectedConversationID, conversation)
        XCTAssertEqual(model.composerDraft(for: project), "Keep the project draft")
        XCTAssertEqual(model.composerDraft(for: .all), "Keep the Home draft")
        XCTAssertNil(model.desk, "Teaching examples must not create real cards")
    }

    func testLoadingOrWorkspaceModalKeepsAutomaticDecisionUnconsumed() {
        let session = WorkboardTutorialSession()
        var loading = available
        loading.isReady = false
        session.resolveAutomaticDecision(true, availability: loading)
        XCTAssertFalse(session.hasEvaluatedAutomatic)
        var modal = available
        modal.isBlocked = true
        session.resolveAutomaticDecision(true, availability: modal)
        XCTAssertFalse(session.hasEvaluatedAutomatic)
        session.requestReplay()
        XCTAssertFalse(session.acknowledge(modal))
        XCTAssertTrue(session.isPresented(available))
    }

    func testFastShareDefersTourBeforeNativeShareCanOpen() {
        enum Unexpected: Error { case mutation }
        var model: WorkboardViewModel!
        var shared = false
        model = WorkboardViewModel(dependencies: .init(
            loadDesk: { nil }, importMaterial: { _, _, _ in throw Unexpected.mutation },
            removeMaterial: { _, _ in throw Unexpected.mutation },
            replaceMaterial: { _, _, _, _ in throw Unexpected.mutation },
            openMaterial: { _ in },
            shareMaterial: { _ in
                shared = true
                XCTAssertTrue(model.tutorialSession.isDeferredForVisit,
                              "The share may open synchronously before a busy observer runs")
            }
        ))
        model.shareMaterial(WorkboardMaterialSnapshot(kind: .note, name: "Note", textContent: "Keep this"))
        XCTAssertTrue(shared)
        XCTAssertFalse(model.tutorialSession.canEvaluateAutomatically(available))
        model = nil
    }
}
