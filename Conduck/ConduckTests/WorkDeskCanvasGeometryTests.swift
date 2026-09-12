// SPDX-License-Identifier: Apache-2.0

// Geometry contracts for a zoomable desk: the finger remains over the same
// material, edge crossings do not silently create a project, and invalid sync
// coordinates cannot escape into drawing arithmetic.

import XCTest
@testable import Conduck

final class WorkDeskCanvasGeometryTests: XCTestCase {
    func testNewCaptureAfterDeletionAndRemountUsesVacantSlot() throws {
        let size = WorkDeskCanvasGeometry.cardBodySize
        let b = WorkDeskCanvasGeometry.defaultPoint(index: 1, columns: 3)
        let c = WorkDeskCanvasGeometry.defaultPoint(index: 2, columns: 3)
        let occupied = [b, c].map { WorkDeskCanvasGeometry.frame(at: $0, bodySize: size, scale: 0.72) }
        let added = try XCTUnwrap(WorkDeskCanvasGeometry.availablePoint(occupied: occupied, columns: 3, bodySize: size, scale: 0.72))
        XCTAssertEqual(added, WorkDeskCanvasGeometry.defaultPoint(index: 0, columns: 3))
        XCTAssertFalse(occupied.contains { $0.intersects(WorkDeskCanvasGeometry.frame(at: added, bodySize: size, scale: 0.72)) })
    }

    func testManuallyMovedCardAndProjectReserveTheirActualFrames() throws {
        let size = WorkDeskCanvasGeometry.cardBodySize
        let occupied = [CGRect(x: 15, y: 10, width: 500, height: 320)]
        let added = try XCTUnwrap(WorkDeskCanvasGeometry.availablePoint(occupied: occupied, columns: 3, bodySize: size, scale: 1))
        XCTAssertEqual(added, WorkDeskCanvasGeometry.defaultPoint(index: 2, columns: 3))
        XCTAssertFalse(occupied[0].intersects(WorkDeskCanvasGeometry.frame(at: added, bodySize: size, scale: 1)))
    }

    func testMovementConvertsScreenTranslationToDeskCoordinates() {
        let moved = WorkDeskCanvasGeometry.moved(WorkDeskPoint(x: 100, y: 200), by: CGSize(width: 40, height: -20), scale: 0.5)
        XCTAssertEqual(moved.x, 180)
        XCTAssertEqual(moved.y, 160)
    }

    func testZoomPreservesTheDeskPointUnderItsAnchor() {
        let before = WorkDeskCanvasTransform(scale: 0.8, offset: CGSize(width: -100, height: 30))
        let anchor = CGPoint(x: 150, y: 270)
        let point = WorkDeskPoint(x: Double((anchor.x - before.offset.width) / before.scale), y: Double((anchor.y - before.offset.height) / before.scale))
        let after = WorkDeskCanvasGeometry.zoomed(before, to: 1.3, anchor: anchor)
        let projected = WorkDeskCanvasGeometry.screenPoint(point, transform: after)
        XCTAssertEqual(projected.x, anchor.x, accuracy: 0.001)
        XCTAssertEqual(projected.y, anchor.y, accuracy: 0.001)
    }

    func testPassingAnEdgeDoesNotGroupButAnIntentionalOverlapDoes() {
        let targetID = UUID()
        let target = CGRect(x: 200, y: 100, width: 232, height: 282)
        XCTAssertNil(WorkDeskCanvasGeometry.overlapTarget(movingFrame: CGRect(x: 90, y: 100, width: 232, height: 282), candidates: [(targetID, target)]))
        XCTAssertEqual(WorkDeskCanvasGeometry.overlapTarget(movingFrame: CGRect(x: 200, y: 100, width: 232, height: 282), candidates: [(targetID, target)]), targetID)
    }

    func testClosestOverlappingTargetWinsIndependentOfCandidateOrder() {
        let near = UUID()
        let far = UUID()
        let candidates = [(far, CGRect(x: 110, y: 110, width: 232, height: 282)), (near, CGRect(x: 100, y: 100, width: 232, height: 282))]
        let moving = CGRect(x: 100, y: 100, width: 232, height: 282)
        XCTAssertEqual(WorkDeskCanvasGeometry.overlapTarget(movingFrame: moving, candidates: candidates), near)
        XCTAssertEqual(WorkDeskCanvasGeometry.overlapTarget(movingFrame: moving, candidates: Array(candidates.reversed())), near)
    }

    func testCorruptCoordinatesAndZoomStayFiniteAndBounded() {
        let point = WorkDeskCanvasGeometry.bounded(WorkDeskPoint(x: .infinity, y: -.infinity))
        XCTAssertEqual(point.x, 0)
        XCTAssertEqual(point.y, 0)
        let outside = WorkDeskCanvasGeometry.bounded(WorkDeskPoint(x: -1, y: 90_000))
        XCTAssertEqual(outside.x, -1)
        XCTAssertEqual(outside.y, WorkDeskCanvasGeometry.coordinateLimit)
        XCTAssertEqual(WorkDeskCanvasGeometry.boundedScale(.nan), 1)
        XCTAssertEqual(WorkDeskCanvasGeometry.boundedScale(0), WorkDeskCanvasGeometry.minimumScale)
    }

    func testBackgroundCreationPointConvertsTheHoveredPositionAtAnyZoom() {
        for scale: CGFloat in [0.15, 0.8, 1.6] {
            let camera = WorkDeskCanvasTransform(scale: scale, offset: CGSize(width: 440, height: -150))
            let location = CGPoint(x: 180, y: 240)
            let point = WorkDeskCanvasGeometry.worldPoint(location, transform: camera)
            XCTAssertLessThan(point.x, 0)
            let rendered = WorkDeskCanvasGeometry.screenPoint(point, transform: camera)
            XCTAssertEqual(rendered.x, location.x, accuracy: 0.001)
            XCTAssertEqual(rendered.y, location.y, accuracy: 0.001)
        }
    }

    func testFitBringsSeparatedCardsIntoTheViewport() {
        let frames = [CGRect(x: 100, y: 70, width: 232, height: 282), CGRect(x: 660, y: 420, width: 232, height: 282)]
        let viewport = CGSize(width: 1_100, height: 850)
        let transform = WorkDeskCanvasGeometry.fit(frames: frames, viewport: viewport)
        for frame in frames {
            let topLeft = WorkDeskCanvasGeometry.screenPoint(WorkDeskPoint(x: frame.minX, y: frame.minY), transform: transform)
            XCTAssertGreaterThanOrEqual(topLeft.x, 0)
            XCTAssertGreaterThanOrEqual(topLeft.y, 0)
            XCTAssertLessThanOrEqual(topLeft.x + frame.width * transform.scale, viewport.width)
            XCTAssertLessThanOrEqual(topLeft.y + frame.height * transform.scale, viewport.height)
        }
    }

    func testNewDefaultSlotsDoNotMoveExistingSlots() {
        let existing = (0..<10).map { WorkDeskCanvasGeometry.defaultPoint(index: $0, columns: 3) }
        let afterCapture = (0..<11).map { WorkDeskCanvasGeometry.defaultPoint(index: $0, columns: 3) }
        XCTAssertEqual(existing, Array(afterCapture.prefix(10)))
    }

    func testFitCanShowFarApartMaterialsOnANarrowPhone() {
        let frames = [CGRect(x: 0, y: 0, width: 232, height: 238), CGRect(x: 20_000, y: 20_000, width: 232, height: 238)]
        let viewport = CGSize(width: 320, height: 480)
        let transform = WorkDeskCanvasGeometry.fit(frames: frames, viewport: viewport)
        XCTAssertLessThan(transform.scale, WorkDeskCanvasGeometry.overviewThreshold)
        for frame in frames {
            let topLeft = WorkDeskCanvasGeometry.screenPoint(WorkDeskPoint(x: frame.minX, y: frame.minY), transform: transform)
            XCTAssertGreaterThanOrEqual(topLeft.x, 0)
            XCTAssertGreaterThanOrEqual(topLeft.y, 0)
            XCTAssertLessThanOrEqual(topLeft.x + frame.width * transform.scale, viewport.width)
            XCTAssertLessThanOrEqual(topLeft.y + frame.height * transform.scale, viewport.height)
        }
    }

    func testZoomKeepsTheSamePartOfEveryCardUnderTheFocalPoint() {
        for size in [WorkDeskCanvasGeometry.cardBodySize, WorkDeskCanvasGeometry.projectBodySize] {
            for zoom: CGFloat in [0.02, 0.1, 0.59, 0.6, 1.4] {
                let point = WorkDeskPoint(x: -250, y: 180)
                let before = WorkDeskCanvasTransform(scale: zoom, offset: CGSize(width: 240, height: 110))
                let frame = WorkDeskCanvasGeometry.screenFrame(at: point, bodySize: size, transform: before)
                let anchor = CGPoint(x: frame.minX + frame.width * 0.37, y: frame.minY + frame.height * 0.62)
                let after = WorkDeskCanvasGeometry.zoomed(before, to: 0.9, anchor: anchor)
                let result = WorkDeskCanvasGeometry.screenFrame(at: point, bodySize: size, transform: after)
                XCTAssertEqual(result.minX + result.width * 0.37, anchor.x, accuracy: 0.000_001)
                XCTAssertEqual(result.minY + result.height * 0.62, anchor.y, accuracy: 0.000_001)
            }
        }
    }

    func testZoomOutDoesNotMakeSeparateTilesOverlap() {
        for zoom: CGFloat in [0.001, 0.02, 0.1, 0.59, 1.6] {
            let transform = WorkDeskCanvasTransform(scale: zoom)
            let a = WorkDeskCanvasGeometry.screenFrame(at: .init(x: 0, y: 0), bodySize: WorkDeskCanvasGeometry.cardBodySize, transform: transform)
            let b = WorkDeskCanvasGeometry.screenFrame(at: .init(x: 300, y: 0), bodySize: WorkDeskCanvasGeometry.cardBodySize, transform: transform)
            XCTAssertFalse(a.intersects(b))
            XCTAssertEqual(b.minX - a.maxX, 68 * zoom, accuracy: 0.000_001)
        }
    }

    func testOverviewTouchReachChoosesNearbyCardsWithoutHidingTheirNeighbours() {
        let a = WorkDeskCanvasItemID.material(UUID()), b = WorkDeskCanvasItemID.project(UUID())
        let candidates = [WorkDeskDropCandidate(id: a, frame: CGRect(x: 0, y: 0, width: 4, height: 4), layer: 1),
                          WorkDeskDropCandidate(id: b, frame: CGRect(x: 10, y: 0, width: 4, height: 4), layer: 2)]
        XCTAssertEqual(WorkDeskCanvasGeometry.overviewTarget(at: CGPoint(x: 1, y: 1), candidates: candidates), a)
        XCTAssertEqual(WorkDeskCanvasGeometry.overviewTarget(at: CGPoint(x: 8, y: 8), candidates: candidates), b)
        XCTAssertEqual(WorkDeskCanvasGeometry.overviewTarget(at: CGPoint(x: 8, y: 8), candidates: candidates.reversed()), b)
        XCTAssertNil(WorkDeskCanvasGeometry.overviewTarget(at: CGPoint(x: 100, y: 100), candidates: candidates))
    }

    func testProjectHoverPreviewRemainsReadableAndInsideViewportAtEveryEdge() {
        let viewport = CGSize(width: 1_000, height: 700)
        for origin in [CGPoint(x: 0, y: 0), CGPoint(x: 950, y: 0), CGPoint(x: 0, y: 660), CGPoint(x: 950, y: 660)] {
            let frame = WorkDeskCanvasGeometry.projectPreviewFrame(near: CGRect(origin: origin, size: CGSize(width: 30, height: 20)),
                viewport: viewport, itemCount: 10)
            XCTAssertEqual(frame.width, 310)
            XCTAssertTrue(CGRect(origin: .zero, size: viewport).contains(frame))
        }
    }

    func testProjectPreviewFlipsLeftNearRightEdgeWithoutMovingItsFolder() {
        let folder = CGRect(x: 700, y: 100, width: 150, height: 110)
        let preview = WorkDeskCanvasGeometry.projectPreviewFrame(near: folder, viewport: CGSize(width: 1_000, height: 700), itemCount: 3)
        XCTAssertLessThan(preview.maxX, folder.minX)
        XCTAssertEqual(preview.minY, folder.minY)
    }

    func testProjectPreviewHandlesNarrowAndInvalidViewports() {
        let viewport = CGSize(width: 220, height: 180)
        let frame = WorkDeskCanvasGeometry.projectPreviewFrame(near: CGRect(x: 180, y: 100, width: 30, height: 20),
            viewport: viewport, itemCount: 50)
        XCTAssertTrue(CGRect(origin: .zero, size: viewport).contains(frame))
        XCTAssertEqual(WorkDeskCanvasGeometry.projectPreviewFrame(near: .zero, viewport: .zero, itemCount: 1), .zero)
        XCTAssertEqual(WorkDeskCanvasGeometry.projectPreviewFrame(near: .zero,
            viewport: CGSize(width: CGFloat.nan, height: 100), itemCount: 1), .zero)
    }

}
