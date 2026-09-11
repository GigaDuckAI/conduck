// SPDX-License-Identifier: Apache-2.0

// The choice UI never mutates during review and keeps retained cards visible
// without changing the person's layout preference or highlighting lost cards.

import XCTest
@testable import Conduck

@MainActor
final class WorkDeskProjectDeletionPresentationTests: XCTestCase {
    func testReviewIsReadOnlyAndLosingWorkFocusCancelsThePendingPresentation() async {
        let project = WorkDeskProjectRecord(title: "Review")
        let review = makeReview(project: project, visibleIDs: [UUID()])
        let counter = MutationCounter()
        let organization = WorkDeskOrganization(fetch: { .init(projects: [project]) },
            apply: { _ in await counter.increment(); return .init() }, reviewDeletion: { _ in review })
        let workspace = WorkDeskWorkspaceState(organization: organization)
        workspace.isActive = true
        workspace.deletingProjectID = project.id
        await workspace.prepareProjectDeletion(id: project.id)
        XCTAssertEqual(workspace.projectDeletionReview, review)
        let writes = await counter.count
        XCTAssertEqual(writes, 0)
        workspace.suspend()
        XCTAssertNil(workspace.projectDeletionReview)
        workspace.deletingProjectID = project.id
        await workspace.prepareProjectDeletion(id: project.id)
        XCTAssertNil(workspace.projectDeletionReview, "An inactive Work tab cannot present a deletion review")
    }

    func testKeepingRevealsCommittedPositionsAndOnlySelectsSurvivingCards() async {
        let project = WorkDeskProjectRecord(title: "Finished")
        let kept = WorkboardMaterialSnapshot(kind: .note, name: "Keep")
        let disappeared = UUID()
        let other = WorkboardMaterialSnapshot(kind: .note, name: "Other")
        let actual = WorkDeskPoint(x: 2400, y: -700)
        let snapshot = WorkDeskOrganizationSnapshot(placements: [kept.id: .init(materialID: kept.id, homePosition: actual)])
        let organization = WorkDeskOrganization(fetch: { snapshot }, apply: { _ in snapshot })
        await organization.reload()
        let workspace = WorkDeskWorkspaceState(organization: organization)
        workspace.selectScope(.project(project.id))
        let layout = workspace.layoutSession(for: .all)
        layout.mode = .list
        let session = workspace.canvasSession(for: .all)
        session.viewportSize = .init(width: 900, height: 600)
        let review = makeReview(project: project, visibleIDs: [kept.id, disappeared])
        workspace.finishProjectDeletion(review, keptMaterials: true, materials: [kept, other])
        XCTAssertEqual(workspace.scope, .all)
        XCTAssertEqual(workspace.selectedIDs, [kept.id])
        XCTAssertTrue(workspace.isSelecting)
        XCTAssertEqual(layout.mode, .list)
        XCTAssertEqual(workspace.materialRevealRequest?.materialID, kept.id)
        let expected = WorkDeskCanvasGeometry.fit(frames: [WorkDeskCanvasGeometry.frame(at: actual,
            bodySize: WorkDeskCanvasGeometry.cardBodySize, scale: 1)], viewport: session.viewportSize)
        XCTAssertEqual(session.transform, expected, "Use committed placement, not the stale review's proposed cluster")
    }

    func testDeletingMaterialsNeverHighlightsOrRevealsThem() async {
        let project = WorkDeskProjectRecord(title: "Removed")
        let material = WorkboardMaterialSnapshot(kind: .note, name: "Removed")
        let organization = WorkDeskOrganization(fetch: { .init() }, apply: { _ in .init() })
        let workspace = WorkDeskWorkspaceState(organization: organization)
        workspace.selectedIDs = [material.id]
        workspace.isSelecting = true
        workspace.finishProjectDeletion(makeReview(project: project, visibleIDs: [material.id]),
            keptMaterials: false, materials: [material])
        XCTAssertEqual(workspace.scope, .all)
        XCTAssertTrue(workspace.selectedIDs.isEmpty)
        XCTAssertFalse(workspace.isSelecting)
        XCTAssertNil(workspace.materialRevealRequest)
    }

    func testRevealWaitsForARealSpatialViewport() {
        let session = WorkDeskCanvasSession()
        let frames = [CGRect(x: 2100, y: -1500, width: 230, height: 190)]
        session.reveal(frames: frames)
        XCTAssertFalse(session.isInitialized)
        session.viewportSize = CGSize(width: 800, height: 600)
        session.applyPendingReveal()
        XCTAssertEqual(session.transform, WorkDeskCanvasGeometry.fit(frames: frames, viewport: session.viewportSize))
        XCTAssertTrue(session.isInitialized)
    }

    private func makeReview(project: WorkDeskProjectRecord, visibleIDs: [UUID]) -> WorkDeskProjectDeletionReview {
        .init(id: UUID(), projectID: project.id, projectTitle: project.title, materialIDs: visibleIDs,
            visibleMaterialIDs: visibleIDs, conversationCount: 0,
            retainedPositions: Dictionary(uniqueKeysWithValues: visibleIDs.map { ($0, WorkDeskPoint(x: 0, y: 0)) }),
            focusPoint: .init(x: 0, y: 0), project: project, assignedMaterialIDs: Set(visibleIDs),
            placementTokens: [:], materialTokens: [:])
    }

    private actor MutationCounter {
        var count = 0
        func increment() { count += 1 }
    }
}
