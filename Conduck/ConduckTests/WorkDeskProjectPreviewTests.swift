// SPDX-License-Identifier: Apache-2.0

// Explicit folder previews retain a live project list without taking over Home
// navigation. These cases exercise placement, dismissal and native-drag request
// ownership; native presentation, scrolling and pointer feel remain device QA.

import XCTest
@testable import Conduck

@MainActor
final class WorkDeskProjectPreviewTests: XCTestCase {
    private let anchor = CGRect(x: 80, y: 90, width: 220, height: 170)
    private let panel = CGRect(x: 314, y: 90, width: 380, height: 400)

    func testPreviewRemainsInsideEveryViewportEdgeAndVerySmallPositiveViewports() {
        let viewports: [CGSize] = [
            .init(width: 1_200, height: 800), .init(width: 320, height: 250),
            .init(width: 220, height: 180), .init(width: 1, height: 1), .init(width: 0.5, height: 0.75)
        ]
        for viewport in viewports {
            let bounds = CGRect(origin: .zero, size: viewport)
            let origins: [CGPoint] = [.zero, .init(x: viewport.width - 10, y: viewport.height - 10),
                                     .init(x: -800, y: -600), .init(x: 8_000, y: 6_000)]
            for origin in origins {
                let frame = WorkDeskProjectPreviewGeometry.frame(
                    anchor: CGRect(origin: origin, size: .init(width: 30, height: 20)),
                    viewport: viewport, materialCount: 100)
                XCTAssertTrue(frame.minX.isFinite && frame.maxX.isFinite && frame.minY.isFinite && frame.maxY.isFinite)
                XCTAssertGreaterThan(frame.width, 0)
                XCTAssertGreaterThan(frame.height, 0)
                XCTAssertTrue(bounds.contains(frame), "Preview \(frame) must fit within \(viewport)")
            }
        }
    }

    func testPreviewFlipsBesideFolderAndLongProjectsHaveABoundedScrollingFootprint() {
        let viewport = CGSize(width: 1_200, height: 800)
        let right = WorkDeskProjectPreviewGeometry.frame(anchor: anchor, viewport: viewport, materialCount: 5)
        XCTAssertGreaterThan(right.minX, anchor.maxX)
        let nearRight = CGRect(x: 1_000, y: 90, width: 100, height: 100)
        let left = WorkDeskProjectPreviewGeometry.frame(anchor: nearRight, viewport: viewport, materialCount: 5)
        XCTAssertLessThan(left.maxX, nearRight.minX)
        XCTAssertEqual(left.minY, nearRight.minY)
        let many = WorkDeskProjectPreviewGeometry.frame(anchor: anchor, viewport: viewport, materialCount: .max)
        XCTAssertEqual(many.size, right.size, "A large collection scrolls without expanding over the whole desk")
        let empty = WorkDeskProjectPreviewGeometry.frame(anchor: anchor, viewport: viewport, materialCount: 0)
        XCTAssertGreaterThan(empty.height, 0)
        XCTAssertLessThanOrEqual(empty.height, right.height)
        XCTAssertEqual(WorkDeskProjectPreviewGeometry.frame(anchor: anchor, viewport: viewport, materialCount: -1), empty)
    }

    func testInvalidViewportAndAnchorNeverProduceAnInvalidLayout() {
        let invalidViewports: [CGSize] = [.zero, .init(width: -1, height: 300),
            .init(width: CGFloat.nan, height: 300), .init(width: 300, height: CGFloat.infinity)]
        for viewport in invalidViewports {
            XCTAssertEqual(WorkDeskProjectPreviewGeometry.frame(anchor: anchor, viewport: viewport, materialCount: 3), .zero)
        }
        let invalidAnchors: [CGRect] = [.init(x: CGFloat.nan, y: 0, width: 30, height: 30),
            .init(x: 0, y: CGFloat.infinity, width: 30, height: 30),
            .init(x: CGFloat.greatestFiniteMagnitude, y: 0, width: CGFloat.greatestFiniteMagnitude, height: 30)]
        for invalid in invalidAnchors {
            XCTAssertEqual(WorkDeskProjectPreviewGeometry.frame(anchor: invalid,
                viewport: .init(width: 800, height: 600), materialCount: 3), .zero)
        }
    }

    func testExplicitToggleClosesSameFolderAndNewOpenGetsANewRequest() throws {
        let state = WorkDeskProjectPreviewState()
        let first = UUID(), second = UUID()
        state.toggle(projectID: first, anchor: anchor, materialCount: 8)
        let original = try XCTUnwrap(state.request)
        XCTAssertEqual(original.projectID, first)
        XCTAssertEqual(original.anchor, anchor)
        XCTAssertEqual(original.initialMaterialCount, 8)
        state.updatePanelFrame(panel, requestID: original.id)
        state.toggle(projectID: second, anchor: anchor, materialCount: 4)
        let replacement = try XCTUnwrap(state.request)
        XCTAssertEqual(replacement.projectID, second)
        XCTAssertNotEqual(replacement.id, original.id)
        XCTAssertEqual(state.panelFrame, .zero)
        state.toggle(projectID: second, anchor: anchor)
        XCTAssertNil(state.request)
        state.toggle(projectID: first, anchor: anchor)
        XCTAssertNotEqual(state.request?.id, original.id)
    }

    func testUnmeasuredOrInvalidFolderCannotReplaceAnOpenPreview() throws {
        let state = WorkDeskProjectPreviewState()
        state.toggle(projectID: UUID(), anchor: anchor)
        let request = try XCTUnwrap(state.request)
        let invalid: [CGRect] = [.zero, .init(x: CGFloat.nan, y: 0, width: 20, height: 20),
            .init(x: 0, y: 0, width: CGFloat.infinity, height: 20),
            .init(x: CGFloat.greatestFiniteMagnitude, y: 0, width: CGFloat.greatestFiniteMagnitude, height: 20)]
        for frame in invalid {
            state.toggle(projectID: UUID(), anchor: frame)
            XCTAssertEqual(state.request, request)
        }
    }

    func testOutsideClickWaitsForMeasurementAndKeepsPanelAndFolderClicksInside() throws {
        let state = WorkDeskProjectPreviewState()
        state.toggle(projectID: UUID(), anchor: anchor)
        let request = try XCTUnwrap(state.request)
        state.dismissOutside(.zero)
        XCTAssertEqual(state.request, request)
        state.updatePanelFrame(panel, requestID: request.id)
        state.dismissOutside(.init(x: panel.midX, y: panel.midY))
        state.dismissOutside(.init(x: anchor.midX, y: anchor.midY))
        XCTAssertEqual(state.request, request)
        state.dismissOutside(.zero)
        XCTAssertNil(state.request)
        XCTAssertEqual(state.panelFrame, .zero)
    }

    func testInvalidAndStalePanelMeasurementsCannotReplaceCurrentDismissalBounds() throws {
        let state = WorkDeskProjectPreviewState()
        state.toggle(projectID: UUID(), anchor: anchor)
        let old = try XCTUnwrap(state.request)
        state.toggle(projectID: UUID(), anchor: anchor)
        let current = try XCTUnwrap(state.request)
        state.updatePanelFrame(panel, requestID: current.id)
        state.updatePanelFrame(.init(x: 1, y: 1, width: 50, height: 50), requestID: old.id)
        XCTAssertEqual(state.panelFrame, panel)
        for invalid in [CGRect.zero, CGRect(x: CGFloat.nan, y: 0, width: 30, height: 30),
                        CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 30)] {
            state.updatePanelFrame(invalid, requestID: current.id)
            XCTAssertEqual(state.panelFrame, panel)
        }
        state.dismissOutside(.init(x: panel.midX, y: panel.midY))
        XCTAssertEqual(state.request, current)
    }

    func testNativeDragRetainsPreviewThroughOutsideReleaseAndOrdinaryDismissal() throws {
        let state = WorkDeskProjectPreviewState()
        state.toggle(projectID: UUID(), anchor: anchor)
        let request = try XCTUnwrap(state.request)
        state.updatePanelFrame(panel, requestID: request.id)
        let token = try XCTUnwrap(state.beginDrag(requestID: request.id))
        XCTAssertNil(state.beginDrag(requestID: request.id), "One native session must own the preview")
        state.dismissOutside(.zero)
        state.dismiss()
        state.toggle(projectID: UUID(), anchor: anchor)
        XCTAssertEqual(state.request, request)
        XCTAssertEqual(state.panelFrame, panel)
        state.endDrag(token: token)
        XCTAssertNil(state.dragToken)
        XCTAssertEqual(state.request, request, "Completing a move must leave contents available")
        state.dismissOutside(.zero)
        XCTAssertNil(state.request)
    }

    func testStaleDragCompletionsCannotEndANewerPreviewSession() throws {
        let state = WorkDeskProjectPreviewState()
        state.toggle(projectID: UUID(), anchor: anchor)
        let oldRequest = try XCTUnwrap(state.request)
        let oldToken = try XCTUnwrap(state.beginDrag(requestID: oldRequest.id))
        state.dismiss(force: true)
        XCTAssertNil(state.dragToken)
        state.toggle(projectID: UUID(), anchor: anchor)
        let current = try XCTUnwrap(state.request)
        XCTAssertNil(state.beginDrag(requestID: oldRequest.id))
        let token = try XCTUnwrap(state.beginDrag(requestID: current.id))
        for stale in [nil, oldToken, UUID()] {
            state.endDrag(token: stale)
            XCTAssertEqual(state.dragToken, token)
            XCTAssertEqual(state.request, current)
        }
        state.endDrag(token: token)
        state.endDrag(token: token)
        XCTAssertNil(state.dragToken)
        XCTAssertEqual(state.request, current)
    }

    func testNavigationSearchAndSuspensionForceDismissEvenDuringNativeDrag() async throws {
        for action in 0..<4 {
            let project = WorkDeskProjectRecord(title: "Project")
            let (workspace, _) = await makeWorkspace(snapshot: .init(projects: [project]))
            workspace.isActive = true
            workspace.projectPreview.toggle(projectID: project.id, anchor: anchor)
            let request = try XCTUnwrap(workspace.projectPreview.request)
            let token = try XCTUnwrap(workspace.projectPreview.beginDrag(requestID: request.id))
            switch action {
            case 0: workspace.selectScope(.project(project.id))
            case 1: workspace.search = "find material"
            case 2: workspace.suspend()
            default: workspace.selectConversation(UUID(), projectID: project.id)
            }
            XCTAssertNil(workspace.projectPreview.request)
            XCTAssertNil(workspace.projectPreview.dragToken)
            workspace.projectPreview.endDrag(token: token)
            XCTAssertNil(workspace.projectPreview.request)
        }
    }

    func testChangingExistingSearchClosesPreviewButReassigningSameQueryDoesNot() async throws {
        let project = WorkDeskProjectRecord(title: "Project")
        let (workspace, _) = await makeWorkspace(snapshot: .init(projects: [project]))
        workspace.search = "first"
        workspace.projectPreview.toggle(projectID: project.id, anchor: anchor)
        let request = try XCTUnwrap(workspace.projectPreview.request)
        workspace.search = "first"
        XCTAssertEqual(workspace.projectPreview.request, request)
        workspace.search = "second"
        XCTAssertNil(workspace.projectPreview.request)
    }

    func testReconciliationKeepsLiveEmptyProjectsAndDismissesOnlyTheRemovedProject() async throws {
        let project = WorkDeskProjectRecord(title: "Project"), other = WorkDeskProjectRecord(title: "Other")
        let (workspace, feed) = await makeWorkspace(snapshot: .init(projects: [project, other]))
        workspace.projectPreview.toggle(projectID: project.id, anchor: anchor)
        let request = try XCTUnwrap(workspace.projectPreview.request)
        await feed.replace(.init(projects: [project]))
        await workspace.organization.reload()
        workspace.reconcile(materials: [])
        XCTAssertEqual(workspace.projectPreview.request, request, "An empty project remains a useful drop target")
        let token = try XCTUnwrap(workspace.projectPreview.beginDrag(requestID: request.id))
        await feed.replace(.init())
        await workspace.organization.reload()
        workspace.reconcile(materials: [])
        XCTAssertNil(workspace.projectPreview.request)
        XCTAssertNil(workspace.projectPreview.dragToken)
        workspace.projectPreview.endDrag(token: token)
        XCTAssertNil(workspace.projectPreview.request)
    }

    func testLivePreviewListShowsEveryProjectMaterialInProjectOrderRegardlessOfHomeSearch() async throws {
        let project = WorkDeskProjectRecord(title: "Research")
        let materials = (0..<8).map { WorkboardMaterialSnapshot(kind: .note, name: "Material \($0)", sequence: $0) }
        let homeOnly = WorkboardMaterialSnapshot(kind: .note, name: "Home search match")
        let ordered = [materials[6], materials[1], materials[4], materials[0], materials[7], materials[3], materials[5], materials[2]]
        var locations: WorkDeskLocationTokens = [:]
        for (rank, material) in ordered.enumerated() {
            locations[material.id] = [.init(materialID: material.id, location: .project(project.id), sortRank: Double(rank))]
        }
        let (workspace, feed) = await makeWorkspace(snapshot: .init(projects: [project], materialLocations: locations))
        workspace.search = "Home search match"
        workspace.projectPreview.toggle(projectID: project.id, anchor: anchor, materialCount: ordered.count)
        let request = try XCTUnwrap(workspace.projectPreview.request)
        XCTAssertEqual(workspace.visibleMaterials(in: materials + [homeOnly]).map(\.id), [homeOnly.id])
        let allContents = workspace.visibleMaterials(in: materials + [homeOnly], scope: .project(request.projectID), search: "")
        XCTAssertEqual(allContents.map(\.id), ordered.map(\.id))
        XCTAssertGreaterThan(allContents.count, 3)
        XCTAssertEqual(workspace.scope, .all, "Previewing does not navigate away from Home")

        let arrival = WorkboardMaterialSnapshot(kind: .note, name: "New arrival")
        locations.removeValue(forKey: ordered[1].id)
        locations[arrival.id] = [.init(materialID: arrival.id, location: .project(project.id), sortRank: -1)]
        await feed.replace(.init(projects: [project], materialLocations: locations))
        await workspace.organization.reload()
        workspace.reconcile(materials: materials + [homeOnly, arrival])
        let liveContents = workspace.visibleMaterials(in: materials + [homeOnly, arrival], scope: .project(request.projectID), search: "")
        XCTAssertEqual(liveContents.map(\.id), [arrival.id] + ordered.filter { $0.id != ordered[1].id }.map(\.id))
        XCTAssertEqual(workspace.projectPreview.request, request, "Membership refresh must not close or replace the explicit preview")
    }

    private func makeWorkspace(snapshot: WorkDeskOrganizationSnapshot) async -> (WorkDeskWorkspaceState, PreviewOrganizationFeed) {
        let feed = PreviewOrganizationFeed(snapshot: snapshot)
        let organization = WorkDeskOrganization(fetch: { await feed.fetch() }, apply: { _ in await feed.fetch() })
        await organization.reload()
        return (WorkDeskWorkspaceState(organization: organization), feed)
    }
}

private actor PreviewOrganizationFeed {
    private var snapshot: WorkDeskOrganizationSnapshot
    init(snapshot: WorkDeskOrganizationSnapshot) { self.snapshot = snapshot }
    func fetch() -> WorkDeskOrganizationSnapshot { snapshot }
    func replace(_ snapshot: WorkDeskOrganizationSnapshot) { self.snapshot = snapshot }
}
