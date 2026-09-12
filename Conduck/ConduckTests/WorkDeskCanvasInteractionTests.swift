// SPDX-License-Identifier: Apache-2.0

// Spatial interaction contracts that do not require device input: a held group
// retains its shape, frontmost surfaces own drops, camera deltas compose, and
// old async work cannot restore a superseded interaction.

import XCTest
import SwiftUI
@testable import Conduck

@MainActor
final class WorkDeskCanvasInteractionTests: XCTestCase {
    func testPanAndZoomComposeWithoutRestoringCompetingStartOffsets() {
        let point = WorkDeskPoint(x: 220, y: 310)
        var transform = WorkDeskCanvasTransform(scale: 0.8, offset: CGSize(width: -30, height: 12))
        let firstAnchor = WorkDeskCanvasGeometry.screenPoint(point, transform: transform)
        transform = WorkDeskCanvasGeometry.zoomed(transform, to: 1.2, anchor: firstAnchor)
        transform = WorkDeskCanvasGeometry.panned(transform, by: CGSize(width: 17, height: -24))
        let movedAnchor = CGPoint(x: firstAnchor.x + 17, y: firstAnchor.y - 24)
        transform = WorkDeskCanvasGeometry.zoomed(transform, to: 0.95, anchor: movedAnchor)
        let result = WorkDeskCanvasGeometry.screenPoint(point, transform: transform)
        XCTAssertEqual(result.x, movedAnchor.x, accuracy: 0.001)
        XCTAssertEqual(result.y, movedAnchor.y, accuracy: 0.001)
    }

    func testMalformedNavigationNeverContaminatesTheViewport() {
        let valid = WorkDeskCanvasTransform(scale: 0.7, offset: CGSize(width: 10, height: -20))
        XCTAssertEqual(WorkDeskCanvasGeometry.panned(valid, by: CGSize(width: CGFloat.nan, height: 10)), valid)
        XCTAssertEqual(WorkDeskCanvasGeometry.zoomed(valid, to: .infinity, anchor: .zero), valid)
        XCTAssertEqual(WorkDeskCanvasGeometry.zoomed(valid, to: 1, anchor: CGPoint(x: CGFloat.nan, y: 0)), valid)
        let normalized = WorkDeskCanvasGeometry.panned(.init(scale: .nan, offset: CGSize(width: .infinity, height: -.infinity)), by: .zero)
        XCTAssertTrue(normalized.scale.isFinite)
        XCTAssertTrue(normalized.offset.width.isFinite)
        XCTAssertTrue(normalized.offset.height.isFinite)
    }

    func testGroupMovementClampsOneDeltaAndPreservesSpacingAtBothEdges() {
        let a = UUID(), b = UUID()
        let origins = [a: WorkDeskPoint(x: 20, y: 50), b: WorkDeskPoint(x: 200, y: 300)]
        let left = WorkDeskCanvasGeometry.translated(origins, by: CGSize(width: -50_000, height: -50_000))
        XCTAssertEqual(left[a], WorkDeskPoint(x: -20_000, y: -20_000))
        XCTAssertEqual(left[b], WorkDeskPoint(x: -19_820, y: -19_750))
        let right = WorkDeskCanvasGeometry.translated(origins, by: CGSize(width: 50_000, height: 50_000))
        XCTAssertEqual(right[b], WorkDeskPoint(x: 20_000, y: 20_000))
        XCTAssertEqual(right[a], WorkDeskPoint(x: 19_820, y: 19_750))
    }

    func testDraggingAcrossTheOriginKeepsTheObjectUnderThePointer() {
        let id = WorkDeskCanvasItemID.material(UUID())
        let start = WorkDeskCanvasTransform(scale: 0.8, offset: CGSize(width: 250, height: 200))
        var drag = WorkDeskCanvasDrag(lead: id, origins: [id: .init(x: 20, y: 30)], startTransform: start)
        drag.translation = CGSize(width: -160, height: -80)
        let moved = drag.positions(transform: start)[id]!
        XCTAssertEqual(moved, .init(x: -180, y: -70))
        let screen = WorkDeskCanvasGeometry.screenPoint(moved, transform: start)
        XCTAssertEqual(screen.x, 106, accuracy: 0.001)
        XCTAssertEqual(screen.y, 144, accuracy: 0.001)
    }

    func testDragFreezesMembersAndCompensatesForCameraMovement() {
        let a = WorkDeskCanvasItemID.material(UUID()), b = WorkDeskCanvasItemID.material(UUID())
        var origins = [a: WorkDeskPoint(x: 100, y: 200), b: WorkDeskPoint(x: 380, y: 240)]
        let start = WorkDeskCanvasTransform(scale: 0.8, offset: CGSize(width: -20, height: 10))
        var drag = WorkDeskCanvasDrag(lead: a, origins: origins, startTransform: start)
        origins[.material(UUID())] = .init(x: 500, y: 300)
        drag.translation = CGSize(width: 40, height: 16)
        let movedCamera = WorkDeskCanvasGeometry.panned(start, by: CGSize(width: -24, height: -8))
        let points = drag.positions(transform: movedCamera)
        XCTAssertEqual(points.count, 2)
        let before = WorkDeskCanvasGeometry.screenPoint(drag.origins[a]!, transform: start)
        let after = WorkDeskCanvasGeometry.screenPoint(points[a]!, transform: movedCamera)
        XCTAssertEqual(after.x, before.x + 40, accuracy: 0.001)
        XCTAssertEqual(after.y, before.y + 16, accuracy: 0.001)
        XCTAssertEqual(points[b]!.x - points[a]!.x, 280, accuracy: 0.001)
        XCTAssertEqual(points[b]!.y - points[a]!.y, 40, accuracy: 0.001)
    }

    func testVisibleMaterialWinsOverAHiddenProjectAndRaisingReversesIt() {
        let material = WorkDeskCanvasItemID.material(UUID()), project = WorkDeskCanvasItemID.project(UUID())
        let frame = CGRect(x: 100, y: 100, width: 232, height: 282)
        XCTAssertEqual(WorkDeskCanvasGeometry.foregroundTarget(movingFrame: frame, candidates: [
            .init(id: project, frame: frame, layer: 1), .init(id: material, frame: frame, layer: 2)
        ]), material)
        XCTAssertEqual(WorkDeskCanvasGeometry.foregroundTarget(movingFrame: frame, candidates: [
            .init(id: project, frame: frame, layer: 3), .init(id: material, frame: frame, layer: 2)
        ]), project)
    }

    func testForegroundEdgeDoesNotDropThroughIntoAHiddenSurface() {
        let back = WorkDeskCanvasItemID.project(UUID()), front = WorkDeskCanvasItemID.material(UUID())
        let moving = CGRect(x: 100, y: 100, width: 232, height: 282)
        XCTAssertNil(WorkDeskCanvasGeometry.foregroundTarget(movingFrame: moving, candidates: [
            .init(id: back, frame: moving, layer: 1),
            .init(id: front, frame: CGRect(x: moving.midX - 5, y: 100, width: 232, height: 282), layer: 2)
        ]))
    }

    func testOnlyAContinuousDwellOnTheCurrentTargetCanArmGrouping() {
        let first = WorkDeskCanvasItemID.material(UUID()), second = WorkDeskCanvasItemID.project(UUID())
        var hover = WorkDeskDropHover()
        hover.update(first)
        let oldGeneration = hover.generation
        XCTAssertFalse(hover.isReady)
        hover.update(second)
        hover.arm(generation: oldGeneration)
        XCTAssertFalse(hover.isReady)
        hover.arm(generation: hover.generation)
        XCTAssertTrue(hover.isReady)
        hover.update(nil)
        XCTAssertFalse(hover.isReady)
        hover.update(second)
        XCTAssertFalse(hover.isReady)
    }

    func testEmptyHoverResetDoesNotRestartItsDwellTaskAtPointerRate() {
        var hover = WorkDeskDropHover()
        let generation = hover.generation
        hover.reset()
        hover.update(nil)
        hover.reset()
        XCTAssertEqual(hover.generation, generation)
        hover.update(.material(UUID()))
        let targetGeneration = hover.generation
        hover.reset()
        XCTAssertNotEqual(hover.generation, targetGeneration)
        XCTAssertNil(hover.target)
    }

    func testNewProjectInsertionUsesTheCurrentVisibleDeskCenter() {
        let session = WorkDeskCanvasSession()
        XCTAssertNil(session.projectInsertionPoint)
        session.receiveViewport(CGSize(width: 900, height: 640), owner: UUID(), isActive: true)
        session.transform = .init(scale: 0.8, offset: CGSize(width: 500, height: -300))
        let point = session.projectInsertionPoint!
        XCTAssertLessThan(point.x, 0, "The visible desk extends left of the original origin.")
        let frame = WorkDeskCanvasGeometry.screenFrame(at: point,
            bodySize: WorkDeskCanvasGeometry.projectBodySize, transform: session.transform)
        XCTAssertEqual(frame.midX, 450, accuracy: 0.001)
        XCTAssertEqual(frame.midY, 320, accuracy: 0.001)
        session.transform = .init(scale: 0.15, offset: CGSize(width: -700, height: -400))
        let overview = WorkDeskCanvasGeometry.screenFrame(at: session.projectInsertionPoint!,
            bodySize: WorkDeskCanvasGeometry.projectBodySize, transform: session.transform)
        XCTAssertEqual(overview.midX, 450, accuracy: 0.001)
        XCTAssertEqual(overview.midY, 320, accuracy: 0.001)
    }

    func testCancelledDwellCannotArmTheSameTargetAfterReentry() {
        let id = WorkDeskCanvasItemID.material(UUID())
        var hover = WorkDeskDropHover()
        hover.update(id)
        let cancelled = hover.generation
        hover.reset()
        hover.update(id)
        hover.arm(generation: cancelled)
        XCTAssertFalse(hover.isReady)
    }

    func testEarlierSaveCompletionCannotClearANewerDrag() {
        let a = WorkDeskCanvasItemID.material(UUID()), b = WorkDeskCanvasItemID.material(UUID())
        var pending = WorkDeskPendingPositions()
        let old = pending.begin([a: .init(x: 10, y: 20), b: .init(x: 80, y: 20)])
        let newerPoint = WorkDeskPoint(x: 300, y: 400)
        let newer = pending.begin([a: newerPoint])
        let completed = pending.finish(token: old)
        XCTAssertEqual(Set(completed.keys), [b])
        XCTAssertEqual(pending.positions[a], newerPoint)
        XCTAssertNil(pending.positions[b])
        XCTAssertEqual(pending.finish(token: newer)[a], newerPoint)
        XCTAssertTrue(pending.positions.isEmpty)
    }

    func testFailedBatchCanReleaseAllItsOptimisticPositionsTogether() {
        let a = WorkDeskCanvasItemID.material(UUID()), b = WorkDeskCanvasItemID.material(UUID())
        var pending = WorkDeskPendingPositions()
        let token = pending.begin([a: .init(x: 10, y: 20), b: .init(x: 80, y: 20)])
        XCTAssertEqual(pending.finish(token: token).count, 2)
        XCTAssertTrue(pending.positions.isEmpty)
        XCTAssertTrue(pending.finish(token: token).isEmpty)
    }

    func testReleasedCardKeepsItsForegroundOrderIncludingAgainstProjects() {
        let a = WorkDeskCanvasItemID.material(UUID()), b = WorkDeskCanvasItemID.material(UUID()), project = WorkDeskCanvasItemID.project(UUID())
        let session = WorkDeskCanvasSession()
        session.reconcile([project, a, b])
        session.bringToFront([a])
        XCTAssertGreaterThan(session.layer(for: a), session.layer(for: b))
        session.reconcile([project, a, b])
        XCTAssertGreaterThan(session.layer(for: a), session.layer(for: b))
        session.bringToFront([project])
        XCTAssertGreaterThan(session.layer(for: project), session.layer(for: a))
        XCTAssertLessThan(session.layer(for: project), WorkDeskCanvasGeometry.liftedLayer)
        XCTAssertLessThan(WorkDeskCanvasGeometry.liftedLayer + session.layer(for: a), WorkDeskCanvasGeometry.feedbackLayer)
    }

    func testGroupReleasePreservesTheOrderOfOverlappingSiblings() {
        let a = WorkDeskCanvasItemID.material(UUID()), b = WorkDeskCanvasItemID.material(UUID()), lead = WorkDeskCanvasItemID.material(UUID())
        let session = WorkDeskCanvasSession()
        session.reconcile([a, b, lead])
        session.bringToFront([a])
        session.raiseGroup([a, lead, b], lead: lead)
        XCTAssertGreaterThan(session.layer(for: a), session.layer(for: b))
        XCTAssertGreaterThan(session.layer(for: lead), session.layer(for: a))
        session.raiseGroup([b, a, lead], lead: lead)
        XCTAssertGreaterThan(session.layer(for: a), session.layer(for: b))
    }

    func testFilteredMaterialsRetainTheirForegroundOrderWhenTheyReturn() {
        let a = WorkDeskCanvasItemID.material(UUID()), b = WorkDeskCanvasItemID.material(UUID())
        let session = WorkDeskCanvasSession()
        session.reconcile([a, b])
        session.bringToFront([a])
        session.reconcile([a])
        session.reconcile([a, b])
        XCTAssertGreaterThan(session.layer(for: a), session.layer(for: b))
    }

    func testStablePreviewRefreshesAccessibilityPositionWithoutCameraInputs() {
        let material = WorkboardMaterialSnapshot(kind: .note, name: "An idea", textContent: "Remember this")
        func preview(ordinal: Int, count: Int) -> WorkDeskStablePreview<EmptyView> {
            WorkDeskStablePreview(material: material, size: WorkDeskCanvasGeometry.cardBodySize,
                isSelecting: false, ordinal: ordinal, totalCount: count) { _, _ in EmptyView() }
        }
        XCTAssertEqual(preview(ordinal: 1, count: 3), preview(ordinal: 1, count: 3))
        XCTAssertNotEqual(preview(ordinal: 1, count: 3), preview(ordinal: 2, count: 3))
        XCTAssertNotEqual(preview(ordinal: 1, count: 3), preview(ordinal: 1, count: 4))
    }

    func testWorkspaceRetainsDistinctViewportsAcrossRemountsAndProjects() async {
        let organization = WorkDeskOrganization(fetch: { .init() }, apply: { _ in .init() })
        let workspace = WorkDeskWorkspaceState(organization: organization)
        let project = WorkDeskScope.project(UUID())
        let desk = workspace.canvasSession(for: .all), projectSession = workspace.canvasSession(for: project)
        desk.transform = .init(scale: 0.8, offset: CGSize(width: -180, height: -300))
        workspace.search = "An idea"
        workspace.suspend()
        XCTAssertTrue(workspace.canvasSession(for: .all) === desk)
        XCTAssertEqual(workspace.canvasSession(for: .all).transform.offset.width, -180)
        XCTAssertTrue(workspace.canvasSession(for: project) === projectSession)
        XCTAssertFalse(desk === projectSession)
        XCTAssertEqual(projectSession.transform, .init())
    }

    func testProjectCreatedByOverlapRetainsItsLocationThroughPickerDismissal() {
        let workspace = WorkDeskWorkspaceState(organization: .init(fetch: { .init() }, apply: { _ in .init() }))
        workspace.showsProjectPicker = true
        let point = WorkDeskPoint(x: 210, y: 140)
        workspace.beginProject(materialIDs: [UUID(), UUID()], position: point)
        XCTAssertEqual(workspace.pendingProjectEditor?.position, point)
        workspace.projectPickerDidDismiss()
        XCTAssertEqual(workspace.projectEditor?.position, point)
    }

    func testWholeCardSizeScalesContinuouslyThroughOverview() {
        for size in [WorkDeskCanvasGeometry.cardBodySize, WorkDeskCanvasGeometry.projectBodySize] {
            for scale: CGFloat in [0.01, 0.1, 0.3, 0.5999, 0.6001, 1, 1.6] {
                let rendered = WorkDeskCanvasGeometry.screenSize(bodySize: size, scale: scale)
                XCTAssertEqual(rendered.width, size.width * scale, accuracy: 0.000_001)
                XCTAssertEqual(rendered.height, size.height * scale, accuracy: 0.000_001)
            }
        }
    }

    func testFitUsesFixedWorldBoundsAtDistantPositionsAndEveryStartingZoom() {
        let points = [WorkDeskPoint(x: -20_000, y: -20_000), WorkDeskPoint(x: 20_000, y: 20_000)]
        for viewport in [CGSize(width: 320, height: 480), CGSize(width: 320, height: 200), CGSize(width: 400, height: 220)] {
            let expected = WorkDeskCanvasGeometry.fit(frames: points.map {
                WorkDeskCanvasGeometry.frame(at: $0, bodySize: WorkDeskCanvasGeometry.cardBodySize, scale: 1)
            }, viewport: viewport)
            for startScale: CGFloat in [0.001, 0.1, 0.6, 1.6] {
                let transform = WorkDeskCanvasGeometry.fit(frames: points.map {
                    WorkDeskCanvasGeometry.frame(at: $0, bodySize: WorkDeskCanvasGeometry.cardBodySize, scale: startScale)
                }, viewport: viewport)
                XCTAssertEqual(transform, expected, "Fit must not depend on the previous zoom.")
                for point in points {
                    let frame = WorkDeskCanvasGeometry.screenFrame(at: point, bodySize: WorkDeskCanvasGeometry.cardBodySize, transform: transform)
                    XCTAssertGreaterThanOrEqual(frame.minX, 0)
                    XCTAssertGreaterThanOrEqual(frame.minY, 0)
                    XCTAssertLessThanOrEqual(frame.maxX, viewport.width)
                    XCTAssertLessThanOrEqual(frame.maxY, viewport.height)
                }
            }
        }
    }

    func testOffscreenPreviewCullingRetainsTheHeldCardAndNearEdges() {
        let viewport = CGSize(width: 390, height: 600)
        XCTAssertFalse(WorkDeskCanvasGeometry.shouldRender(CGRect(x: 900, y: 900, width: 232, height: 282), viewport: viewport, isInteracting: false))
        XCTAssertTrue(WorkDeskCanvasGeometry.shouldRender(CGRect(x: 900, y: 900, width: 232, height: 282), viewport: viewport, isInteracting: true))
        XCTAssertTrue(WorkDeskCanvasGeometry.shouldRender(CGRect(x: 400, y: 300, width: 232, height: 282), viewport: viewport, isInteracting: false))
    }

    func testDropInstructionStaysInsidePhoneAndMacViewports() {
        for viewport in [CGSize(width: 320, height: 480), CGSize(width: 1200, height: 800)] {
            for origin in [CGPoint(x: -80, y: -90), CGPoint(x: viewport.width - 10, y: viewport.height - 15),
                           CGPoint(x: viewport.width + 400, y: viewport.height + 400)] {
                let frame = WorkDeskCanvasGeometry.feedbackFrame(near: CGRect(origin: origin, size: CGSize(width: 232, height: 282)), viewport: viewport)
                XCTAssertGreaterThanOrEqual(frame.minX, 0)
                XCTAssertGreaterThanOrEqual(frame.minY, 0)
                XCTAssertLessThanOrEqual(frame.maxX, viewport.width)
                XCTAssertLessThanOrEqual(frame.maxY, viewport.height)
            }
        }
    }

    func testEdgePanningHasAStillCentreAndBoundedDirection() {
        let viewport = CGSize(width: 600, height: 700)
        XCTAssertEqual(WorkDeskCanvasGeometry.edgePanVelocity(at: CGPoint(x: 300, y: 300), viewport: viewport), .zero)
        let leading = WorkDeskCanvasGeometry.edgePanVelocity(at: .zero, viewport: viewport)
        XCTAssertGreaterThan(leading.width, 0)
        XCTAssertGreaterThan(leading.height, 0)
        let trailing = WorkDeskCanvasGeometry.edgePanVelocity(at: CGPoint(x: 700, y: 800), viewport: viewport)
        XCTAssertEqual(trailing.width, -360)
        XCTAssertEqual(trailing.height, -360)
    }

    func testForegroundFeedbackAndCachedPreviewsAreOwnedByCanvas() throws {
        let path = "Conduck/Views/Workboard/WorkDeskCanvas.swift"
        let source = try RefusalLaneSource.source(at: path)
        XCTAssertTrue(source.contains(".overlay { dropFeedback }"))
        XCTAssertTrue(source.contains(".zIndex(WorkDeskCanvasGeometry.feedbackLayer)"))
        XCTAssertTrue(source.contains(".allowsHitTesting(false)"))
        XCTAssertTrue(source.contains("WorkDeskStablePreview("))
        XCTAssertTrue(source.contains(".equatable()"))
        XCTAssertFalse(source.contains("MagnifyGesture()"), "Native pan/pinch must have one owner.")
        let card = try RefusalLaneSource.source(at: "Conduck/Views/Workboard/WorkDeskCard.swift")
        XCTAssertFalse(card.contains("workdesk.canvas.groupDrop"), "A card-local drop hint disappears under the held card.")
    }

    func testProjectCanvasOverlapsOnlyMoveCardsWhileAllMaterialsKeepsCreation() throws {
        let path = "Conduck/Views/Workboard/WorkDeskCanvas.swift"
        let source = try RefusalLaneSource.source(at: path)
        let candidates = try RefusalLaneSource.body(ofFunction: "cacheDropCandidates", in: source, path: path)
        XCTAssertTrue(candidates.contains("$0.isProject || onGroup != nil"),
                      "No material overlap target or dwell hint may appear without a grouping action")
        let finish = try RefusalLaneSource.body(ofFunction: "finishDrag", in: source, path: path)
        XCTAssertTrue(finish.contains("hover.target?.isProject == true || onGroup != nil"),
                      "A previously armed hover cannot group after the capability disappears")
        XCTAssertTrue(finish.contains("commitMove(points, memberships: finished.memberships)"))
        XCTAssertFalse(finish.contains("beginConversation"), "Dragging must never dispatch or prepare an AI request")
        let board = try RefusalLaneSource.source(at: "Conduck/Views/Workboard/WorkDeskSourceBoard.swift")
        XCTAssertTrue(board.contains("onGroup: isHome ?"))
        XCTAssertTrue(board.contains("workspace.beginProject(materialIDs: ids, position: point) } : nil"))
        XCTAssertTrue(board.contains("actions.startConversation()"), "A selected card must retain its explicit context action")
    }

    func testPendingCompletionRefreshesDropTargetsDuringAnotherDrag() throws {
        let path = "Conduck/Views/Workboard/WorkDeskCanvas.swift"
        let source = try RefusalLaneSource.source(at: path)
        for method in ["commitMove", "commitAssignment"] {
            let body = try RefusalLaneSource.body(ofFunction: method, in: source, path: path)
            let finish = try XCTUnwrap(body.range(of: "pending.finish(token: token)"))
            let refresh = try XCTUnwrap(body.range(of: "cacheDropCandidates(); updateDropTarget()"))
            XCTAssertLessThan(finish.lowerBound, refresh.lowerBound,
                "A failed pending target move must stop advertising its optimistic frame.")
        }
    }

    func testEdgePanUsesTheActualGripPointAtHighZoom() throws {
        let viewport = CGSize(width: 600, height: 700)
        let wideCard = WorkDeskCanvasGeometry.screenSize(bodySize: WorkDeskCanvasGeometry.cardBodySize, scale: 1.6)
        XCTAssertGreaterThan(wideCard.width, 350)
        XCTAssertGreaterThan(WorkDeskCanvasGeometry.edgePanVelocity(at: CGPoint(x: 5, y: 200), viewport: viewport).width, 0)
        XCTAssertLessThan(WorkDeskCanvasGeometry.edgePanVelocity(at: CGPoint(x: 595, y: 200), viewport: viewport).width, 0)
        let source = try RefusalLaneSource.source(at: "Conduck/Views/Workboard/WorkDeskCanvas.swift")
        XCTAssertTrue(source.contains("edgePanVelocity(at: dragPointer"))
        let grip = try RefusalLaneSource.source(at: "Conduck/Views/Workboard/WorkDeskCard.swift")
        XCTAssertTrue(grip.contains("onLocation(value.location)"))
    }
}
