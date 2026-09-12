// SPDX-License-Identifier: Apache-2.0

// A drag may cross several visible containers, but only the frontmost active
// destination can commit. These tests exercise real coordinate conversion and
// cancellation; they do not claim physical pointer or animation behavior.

import XCTest
@testable import Conduck

@MainActor final class WorkDeskTransferCoordinatorTests: XCTestCase {
    private let homeID = UUID()
    private let projectSurfaceID = UUID()
    private let projectID = UUID()
    private let material = WorkboardMaterialSnapshot(kind: .note, name: "A material")

    private func home(items: [WorkDeskTransferItemTarget] = []) -> WorkDeskTransferSurface {
        WorkDeskTransferSurface(id: homeID, location: .home, title: "Home",
            frame: CGRect(x: 0, y: 0, width: 1_200, height: 900), items: items)
    }

    private func start(_ coordinator: WorkDeskTransferCoordinator, at point: CGPoint,
                       sourceID: UUID? = nil, source: WorkDeskLocation = .home,
                       expected: WorkDeskLocationTokens? = nil) {
        coordinator.update(sourceSurfaceID: sourceID ?? homeID, source: source,
            leadMaterial: material, origins: [material.id: .init(x: 20, y: 30)],
            pointer: point, leadFrame: CGRect(x: point.x - 40, y: point.y - 50, width: 232, height: 238),
            expected: expected)
    }

    func testClosedProjectDropMovesFromHomeWithoutAssigningACanvasPosition() throws {
        let coordinator = WorkDeskTransferCoordinator()
        let folder = WorkDeskTransferItemTarget(id: .project(projectID), title: "Project",
            frame: CGRect(x: 300, y: 100, width: 304, height: 224), layer: 1)
        coordinator.register(home(items: [folder]))
        let expected: WorkDeskLocationTokens = [material.id: [.init(materialID: material.id, location: .home)]]
        start(coordinator, at: CGPoint(x: 400, y: 180), expected: expected)
        XCTAssertEqual(coordinator.highlightedProject(in: homeID), projectID)
        guard case .transfer(let request) = coordinator.release(sourceSurfaceID: homeID) else {
            return XCTFail("Expected a transfer")
        }
        XCTAssertEqual(request.materialIDs, [material.id])
        XCTAssertEqual(request.source, .home)
        XCTAssertEqual(request.destination, .project(projectID))
        XCTAssertEqual(request.expected, expected)
        XCTAssertTrue(request.positions.isEmpty)
        XCTAssertFalse(coordinator.isDragging)
    }

    func testDragStartTokensCannotBeRefreshedDuringTheGesture() throws {
        let coordinator = WorkDeskTransferCoordinator()
        coordinator.register(home())
        let first: WorkDeskLocationTokens = [material.id: [.init(materialID: material.id, location: .home, revision: UUID())]]
        let newer: WorkDeskLocationTokens = [material.id: [.init(materialID: material.id, location: .home, revision: UUID())]]
        start(coordinator, at: CGPoint(x: 100, y: 100), expected: first)
        start(coordinator, at: CGPoint(x: 110, y: 110), expected: newer)
        XCTAssertEqual(coordinator.drag?.expected, first)
    }

    func testTrayHeaderOccludesTheDeskButTrayInteriorReceivesDrops() {
        let coordinator = WorkDeskTransferCoordinator()
        coordinator.register(home())
        let chrome = UUID()
        coordinator.registerOcclusion(id: chrome, frame: CGRect(x: 500, y: 50, width: 600, height: 600), priority: 10)
        coordinator.register(WorkDeskTransferSurface(id: projectSurfaceID, location: .project(projectID), title: "Project",
            frame: CGRect(x: 520, y: 130, width: 560, height: 480), priority: 20))
        XCTAssertNil(coordinator.destination(at: CGPoint(x: 600, y: 80)))
        XCTAssertEqual(coordinator.destination(at: CGPoint(x: 600, y: 200))?.location, .project(projectID))
        XCTAssertEqual(coordinator.destination(at: CGPoint(x: 200, y: 200))?.location, .home)
        start(coordinator, at: CGPoint(x: 600, y: 80))
        guard case .cancelled = coordinator.release(sourceSurfaceID: homeID) else {
            return XCTFail("A drop on tray chrome must cancel")
        }
    }

    func testForegroundMaterialBlocksAHiddenFolder() {
        let coordinator = WorkDeskTransferCoordinator()
        let frame = CGRect(x: 300, y: 100, width: 250, height: 220)
        coordinator.register(home(items: [
            .init(id: .project(projectID), title: "Project", frame: frame, layer: 1),
            .init(id: .material(UUID()), title: "Covering card", frame: frame, layer: 2)
        ]))
        XCTAssertEqual(coordinator.destination(at: CGPoint(x: 400, y: 150))?.location, .home)
        XCTAssertNil(coordinator.destination(at: CGPoint(x: 400, y: 150))?.itemID)
    }

    func testDraggedMaterialItselfDoesNotHideTheReceivingFolder() {
        let coordinator = WorkDeskTransferCoordinator()
        let frame = CGRect(x: 300, y: 100, width: 250, height: 220)
        coordinator.register(home(items: [
            .init(id: .project(projectID), title: "Project", frame: frame, layer: 1),
            .init(id: .material(material.id), title: "Held card", frame: frame, layer: 2)
        ]))
        start(coordinator, at: CGPoint(x: 400, y: 150))
        XCTAssertEqual(coordinator.destination?.location, .project(projectID))
    }

    func testZoomControlsBlockBackgroundDrops() {
        let coordinator = WorkDeskTransferCoordinator()
        var surface = home()
        surface.exclusions = [CGRect(x: 900, y: 800, width: 250, height: 70)]
        coordinator.register(surface)
        XCTAssertNil(coordinator.destination(at: CGPoint(x: 1_000, y: 840)))
    }

    func testOutsideReleaseCancelsAndSourceDisappearanceCancelsHeldDrag() {
        let coordinator = WorkDeskTransferCoordinator()
        coordinator.register(home())
        start(coordinator, at: CGPoint(x: -100, y: 200))
        guard case .cancelled = coordinator.release(sourceSurfaceID: homeID) else {
            return XCTFail("Outside release must cancel")
        }
        start(coordinator, at: CGPoint(x: 100, y: 100))
        coordinator.removeSurface(id: homeID)
        XCTAssertNil(coordinator.drag)
        XCTAssertNil(coordinator.destination)
    }

    func testRemovingProjectSurfaceCannotDropThroughItsRemainingChrome() {
        let coordinator = WorkDeskTransferCoordinator()
        coordinator.register(home())
        let frame = CGRect(x: 500, y: 100, width: 500, height: 500)
        coordinator.registerOcclusion(id: UUID(), frame: frame, priority: 10)
        coordinator.register(.init(id: projectSurfaceID, location: .project(projectID), title: "Project", frame: frame, priority: 20))
        start(coordinator, at: CGPoint(x: 600, y: 200))
        XCTAssertEqual(coordinator.destination?.location, .project(projectID))
        coordinator.removeSurface(id: projectSurfaceID)
        XCTAssertNil(coordinator.destination)
    }

    func testSameSourceBackgroundRemainsAnOrdinaryPlacementDrag() {
        let coordinator = WorkDeskTransferCoordinator()
        coordinator.register(home())
        start(coordinator, at: CGPoint(x: 100, y: 100))
        XCTAssertTrue(coordinator.isLocal(to: homeID))
        guard case .local = coordinator.release(sourceSurfaceID: homeID) else {
            return XCTFail("Local placement belongs to the canvas")
        }
    }

    func testAnotherRepresentationOfSameProjectCannotRefileMaterial() {
        let coordinator = WorkDeskTransferCoordinator()
        coordinator.register(home(items: [.init(id: .project(projectID), title: "Project",
            frame: CGRect(x: 100, y: 100, width: 300, height: 220), layer: 1)]))
        coordinator.register(.init(id: projectSurfaceID, location: .project(projectID), title: "Project",
            frame: CGRect(x: 600, y: 100, width: 500, height: 600), priority: 20))
        start(coordinator, at: CGPoint(x: 200, y: 150), sourceID: projectSurfaceID, source: .project(projectID))
        guard case .cancelled = coordinator.release(sourceSurfaceID: projectSurfaceID) else {
            return XCTFail("Same-location filing must cancel")
        }
    }

    func testProjectToHomeConvertsPointerGripIntoDestinationCoordinatesAndPreservesGroupSpacing() throws {
        let coordinator = WorkDeskTransferCoordinator()
        var root = home()
        root.transform = .init(scale: 0.4, offset: CGSize(width: 70, height: -50))
        coordinator.register(root)
        coordinator.register(.init(id: projectSurfaceID, location: .project(projectID), title: "Project",
            frame: CGRect(x: 650, y: 100, width: 500, height: 600), priority: 20))
        let other = UUID()
        let pointer = CGPoint(x: 350, y: 320)
        coordinator.update(sourceSurfaceID: projectSurfaceID, source: .project(projectID), leadMaterial: material,
            origins: [material.id: .init(x: 100, y: 200), other: .init(x: 380, y: 260)],
            pointer: pointer, leadFrame: CGRect(x: 292, y: 201, width: 232, height: 238))
        guard case .transfer(let request) = coordinator.release(sourceSurfaceID: projectSurfaceID) else {
            return XCTFail("Expected transfer onto Home")
        }
        let lead = try XCTUnwrap(request.positions[material.id])
        let second = try XCTUnwrap(request.positions[other])
        let screen = WorkDeskCanvasGeometry.screenPoint(lead, transform: root.transform)
        XCTAssertEqual(screen.x + 232 * 0.4 * 0.25, pointer.x, accuracy: 0.0001)
        XCTAssertEqual(screen.y + 238 * 0.4 * 0.5, pointer.y, accuracy: 0.0001)
        XCTAssertEqual(second.x - lead.x, 280, accuracy: 0.0001)
        XCTAssertEqual(second.y - lead.y, 60, accuracy: 0.0001)
    }

    func testReadableDestinationLeavesPositionSelectionToOrganization() throws {
        let coordinator = WorkDeskTransferCoordinator()
        coordinator.register(home())
        coordinator.register(.init(id: projectSurfaceID, location: .project(projectID), title: "Project",
            frame: CGRect(x: 600, y: 100, width: 500, height: 600), priority: 20, isSpatial: false))
        start(coordinator, at: CGPoint(x: 700, y: 200))
        guard case .transfer(let request) = coordinator.release(sourceSurfaceID: homeID) else {
            return XCTFail("Expected transfer to readable destination")
        }
        XCTAssertTrue(request.positions.isEmpty)
    }

    func testInvalidGeometryCannotBecomeADropDestination() {
        let coordinator = WorkDeskTransferCoordinator()
        coordinator.register(.init(id: homeID, location: .home, title: "Home",
            frame: CGRect(x: 0, y: 0, width: 0, height: 100)))
        XCTAssertNil(coordinator.destination(at: .zero))
        coordinator.register(home())
        XCTAssertNil(coordinator.destination(at: CGPoint(x: CGFloat.nan, y: 0)))
        XCTAssertNil(coordinator.destination(at: CGPoint(x: 0, y: CGFloat.infinity)))
    }

    func testInputExclusionCoordinatesFollowMovedTray() {
        let coordinator = WorkDeskTransferCoordinator()
        let id = UUID()
        coordinator.registerOcclusion(id: id, frame: CGRect(x: 500, y: 200, width: 500, height: 500), priority: 10)
        let frame = CGRect(x: 100, y: 50, width: 1_200, height: 900)
        XCTAssertEqual(coordinator.occludedRects(above: 0, in: frame), [CGRect(x: 400, y: 150, width: 500, height: 500)])
        XCTAssertTrue(coordinator.occludedRects(above: 20, in: frame).isEmpty)
        coordinator.removeOcclusion(id: id)
        XCTAssertTrue(coordinator.occludedRects(above: 0, in: frame).isEmpty)
    }

    func testProjectPeekDismissalCannotClearANewerOwner() {
        let coordinator = WorkDeskTransferCoordinator()
        let firstOwner = UUID(), secondOwner = UUID()
        let first = WorkDeskCanvasProject(record: .init(title: "First"), materialCount: 1)
        let second = WorkDeskCanvasProject(record: .init(title: "Second"), materialCount: 2)
        let frame = CGRect(x: 100, y: 80, width: 250, height: 80)
        coordinator.register(.init(id: firstOwner, location: .project(first.id), title: "First", frame: frame))
        coordinator.register(.init(id: secondOwner, location: .project(second.id), title: "Second", frame: frame))
        showPeek(coordinator, ownerID: firstOwner, project: first, frame: frame)
        showPeek(coordinator, ownerID: secondOwner, project: second, frame: frame)
        coordinator.hideProjectPeek(ownerID: firstOwner)
        XCTAssertEqual(coordinator.projectPeek?.ownerID, secondOwner)
        coordinator.removeSurface(id: firstOwner)
        XCTAssertEqual(coordinator.projectPeek?.project.id, second.id)
        coordinator.hideProjectPeek(ownerID: secondOwner)
        XCTAssertNil(coordinator.projectPeek)
    }

    func testProjectPeekDismissesOnSourceRemovalAndWorkspaceCancellation() {
        let coordinator = WorkDeskTransferCoordinator()
        let project = WorkDeskCanvasProject(record: .init(title: "Project"), materialCount: 3)
        let surface = WorkDeskTransferSurface(id: projectSurfaceID, location: .project(project.id), title: "Project",
            frame: CGRect(x: 100, y: 80, width: 250, height: 80))
        coordinator.register(surface)
        showPeek(coordinator, ownerID: projectSurfaceID, project: project, frame: surface.frame)
        coordinator.removeSurface(id: projectSurfaceID)
        XCTAssertNil(coordinator.projectPeek)
        coordinator.register(surface)
        showPeek(coordinator, ownerID: projectSurfaceID, project: project, frame: surface.frame)
        coordinator.cancel()
        XCTAssertNil(coordinator.projectPeek)
        coordinator.cancel()
        XCTAssertNil(coordinator.projectPeek)
    }

    func testSpatialDragDismissesPeekAndPreventsItReappearingMidDrag() {
        let coordinator = WorkDeskTransferCoordinator()
        coordinator.register(home())
        let project = WorkDeskCanvasProject(record: .init(id: projectID, title: "Project"), materialCount: 1)
        let surface = WorkDeskTransferSurface(id: projectSurfaceID, location: .project(projectID), title: "Project",
            frame: CGRect(x: 600, y: 100, width: 250, height: 80))
        coordinator.register(surface)
        showPeek(coordinator, ownerID: projectSurfaceID, project: project, frame: surface.frame)
        XCTAssertNotNil(coordinator.projectPeek)
        start(coordinator, at: CGPoint(x: 100, y: 100))
        XCTAssertNil(coordinator.projectPeek)
        showPeek(coordinator, ownerID: projectSurfaceID, project: project, frame: surface.frame)
        XCTAssertNil(coordinator.projectPeek)
    }

    func testPendingPeekCannotReappearAfterNavigationOrSourceReplacement() throws {
        let coordinator = WorkDeskTransferCoordinator()
        let project = WorkDeskCanvasProject(record: .init(title: "Project"), materialCount: 1)
        let surface = WorkDeskTransferSurface(id: projectSurfaceID, location: .project(project.id), title: "Project",
            frame: CGRect(x: 100, y: 80, width: 250, height: 80))
        coordinator.register(surface)
        let navigationToken = try XCTUnwrap(coordinator.beginProjectPeek(ownerID: projectSurfaceID))
        coordinator.cancel()
        coordinator.showProjectPeek(ownerID: projectSurfaceID, requestID: navigationToken,
            project: project, frame: surface.frame)
        XCTAssertNil(coordinator.projectPeek, "A dwell started before navigation must not publish afterward")
        let removalToken = try XCTUnwrap(coordinator.beginProjectPeek(ownerID: projectSurfaceID))
        coordinator.removeSurface(id: projectSurfaceID)
        XCTAssertNil(coordinator.beginProjectPeek(ownerID: projectSurfaceID))
        coordinator.register(surface)
        coordinator.showProjectPeek(ownerID: projectSurfaceID, requestID: removalToken,
            project: project, frame: surface.frame)
        XCTAssertNil(coordinator.projectPeek, "Reusing an owner after hiding Work does not revive its old request")
    }

    func testMovingPeekSourceInvalidatesPendingAndVisiblePreviews() throws {
        let coordinator = WorkDeskTransferCoordinator()
        let project = WorkDeskCanvasProject(record: .init(title: "Project"), materialCount: 1)
        var surface = WorkDeskTransferSurface(id: projectSurfaceID, location: .project(project.id), title: "Project",
            frame: CGRect(x: 100, y: 80, width: 250, height: 80))
        coordinator.register(surface)
        let token = try XCTUnwrap(coordinator.beginProjectPeek(ownerID: projectSurfaceID))
        let oldFrame = surface.frame
        surface = WorkDeskTransferSurface(id: surface.id, location: surface.location, title: surface.title,
            frame: surface.frame.offsetBy(dx: 0, dy: 80))
        coordinator.register(surface)
        coordinator.showProjectPeek(ownerID: projectSurfaceID, requestID: token, project: project, frame: oldFrame)
        XCTAssertNil(coordinator.projectPeek)
        coordinator.showProjectPeek(ownerID: projectSurfaceID, requestID: token, project: project, frame: surface.frame)
        XCTAssertNil(coordinator.projectPeek, "An invalidated request cannot substitute the newer frame")
        showPeek(coordinator, ownerID: projectSurfaceID, project: project, frame: surface.frame)
        XCTAssertEqual(coordinator.projectPeek?.frame, surface.frame)
        surface = WorkDeskTransferSurface(id: surface.id, location: surface.location, title: surface.title,
            frame: surface.frame.offsetBy(dx: 0, dy: 80))
        coordinator.register(surface)
        XCTAssertNil(coordinator.projectPeek, "Scrolling the source dismisses its visible floating preview")
    }

    func testPendingPeekCannotPublishAfterDragEnds() throws {
        let coordinator = WorkDeskTransferCoordinator()
        coordinator.register(home())
        let project = WorkDeskCanvasProject(record: .init(id: projectID, title: "Project"), materialCount: 1)
        let surface = WorkDeskTransferSurface(id: projectSurfaceID, location: .project(projectID), title: "Project",
            frame: CGRect(x: 600, y: 100, width: 250, height: 80))
        coordinator.register(surface)
        let token = try XCTUnwrap(coordinator.beginProjectPeek(ownerID: projectSurfaceID))
        start(coordinator, at: CGPoint(x: 100, y: 100))
        XCTAssertNil(coordinator.beginProjectPeek(ownerID: projectSurfaceID))
        _ = coordinator.release(sourceSurfaceID: homeID)
        coordinator.showProjectPeek(ownerID: projectSurfaceID, requestID: token, project: project, frame: surface.frame)
        XCTAssertNil(coordinator.projectPeek, "A drag invalidates prior hover work even after release")
    }

    private func showPeek(_ coordinator: WorkDeskTransferCoordinator, ownerID: UUID,
                          project: WorkDeskCanvasProject, frame: CGRect) {
        guard let request = coordinator.beginProjectPeek(ownerID: ownerID) else { return }
        coordinator.showProjectPeek(ownerID: ownerID, requestID: request, project: project, frame: frame)
    }

}
