// SPDX-License-Identifier: Apache-2.0

// Adaptive tray geometry protects an exposed Home target on phones and room
// beside the project on wide windows. Navigation tests retain both independent
// camera sessions and prove search does not turn a project into a second copy.

import XCTest
@testable import Conduck

@MainActor
final class WorkDeskProjectTrayTests: XCTestCase {
    func testPhoneAndSplitIPadReserveAHomeReturnStrip() {
        for size in [CGSize(width: 375, height: 560), CGSize(width: 430, height: 680),
                     CGSize(width: 507, height: 700), CGSize(width: 740, height: 350)] {
            XCTAssertTrue(WorkDeskProjectTrayGeometry.isCompact(size))
            let frame = WorkDeskProjectTrayGeometry.frame(in: size, expanded: false)
            XCTAssertGreaterThanOrEqual(frame.minY, 44)
            XCTAssertGreaterThan(frame.height, 200)
            XCTAssertLessThanOrEqual(frame.maxX, size.width)
            XCTAssertLessThanOrEqual(frame.maxY, size.height)
        }
    }

    func testWideIPadAndMacKeepTheDeskExposedAtEveryTrayOffset() {
        for size in [CGSize(width: 834, height: 900), CGSize(width: 1024, height: 700),
                     CGSize(width: 1600, height: 900)] {
            for offset in [CGSize.zero, CGSize(width: -10000, height: -10000),
                           CGSize(width: 10000, height: 10000)] {
                let frame = WorkDeskProjectTrayGeometry.frame(in: size, expanded: false, offset: offset)
                XCTAssertGreaterThanOrEqual(size.width - frame.width, 160)
                XCTAssertGreaterThanOrEqual(frame.minX, 0)
                XCTAssertGreaterThanOrEqual(frame.minY, 0)
                XCTAssertLessThanOrEqual(frame.maxX, size.width)
                XCTAssertLessThanOrEqual(frame.maxY, size.height)
            }
        }
    }

    func testExpandedTrayStillLeavesTheHomeDropStrip() {
        let size = CGSize(width: 1024, height: 700)
        let frame = WorkDeskProjectTrayGeometry.frame(in: size, expanded: true)
        XCTAssertGreaterThanOrEqual(frame.minY, 44)
        XCTAssertGreaterThan(frame.width, 900)
        XCTAssertLessThanOrEqual(frame.maxY, size.height)
    }

    func testInvalidGeometryNeverEscapesIntoLayout() {
        XCTAssertEqual(WorkDeskProjectTrayGeometry.frame(in: .zero, expanded: false), .zero)
        XCTAssertEqual(WorkDeskProjectTrayGeometry.frame(in: CGSize(width: CGFloat.nan, height: 700), expanded: false), .zero)
        let frame = WorkDeskProjectTrayGeometry.frame(in: CGSize(width: 1000, height: 700), expanded: false,
            offset: CGSize(width: CGFloat.infinity, height: CGFloat.nan))
        XCTAssertTrue(frame.origin.x.isFinite && frame.origin.y.isFinite)
    }

    func testOpeningClosingAndSearchingKeepBothCameraSessions() async {
        let project = WorkDeskProjectRecord(title: "Research")
        let organization = WorkDeskOrganization(fetch: { .init(projects: [project]) }, apply: { _ in .init(projects: [project]) })
        await organization.reload()
        let workspace = WorkDeskWorkspaceState(organization: organization)
        let home = workspace.canvasSession(for: .all)
        let inside = workspace.canvasSession(for: .project(project.id))
        home.transform = WorkDeskCanvasTransform(scale: 0.48, offset: CGSize(width: 312, height: -90))
        inside.transform = WorkDeskCanvasTransform(scale: 0.9, offset: CGSize(width: -25, height: 76))
        let homeBefore = home.transform
        let insideBefore = inside.transform
        workspace.selectScope(.project(project.id))
        XCTAssertTrue(workspace.isProjectTrayPresented)
        workspace.search = "draft"
        XCTAssertFalse(workspace.isProjectTrayPresented)
        workspace.search = ""
        XCTAssertTrue(workspace.isProjectTrayPresented)
        workspace.selectScope(.all)
        XCTAssertFalse(workspace.isProjectTrayPresented)
        XCTAssertEqual(home.transform, homeBefore)
        XCTAssertEqual(inside.transform, insideBefore)
        XCTAssertTrue(workspace.canvasSession(for: .all) === home)
        XCTAssertTrue(workspace.canvasSession(for: .project(project.id)) === inside)
    }

    func testHomeAndProjectCanBePresentedWithoutChangingCaptureDestination() async {
        let project = WorkDeskProjectRecord(title: "Research")
        let shared = WorkboardMaterialSnapshot(kind: .note, name: "Shared")
        let loose = WorkboardMaterialSnapshot(kind: .note, name: "Loose")
        let snapshot = WorkDeskOrganizationSnapshot(projects: [project], materialLocations: [shared.id: [
            WorkDeskLocationRecord(materialID: shared.id, location: .project(project.id)),
            WorkDeskLocationRecord(materialID: shared.id, location: .home)
        ]])
        let organization = WorkDeskOrganization(fetch: { snapshot }, apply: { _ in snapshot })
        await organization.reload()
        let workspace = WorkDeskWorkspaceState(organization: organization)
        workspace.selectScope(.project(project.id))
        XCTAssertEqual(workspace.visibleMaterials(in: [shared, loose], scope: .all).map(\.id), [shared.id, loose.id])
        XCTAssertEqual(workspace.visibleMaterials(in: [shared, loose]).map(\.id), [shared.id])
        XCTAssertEqual(workspace.composerScope, .project(project.id))
        XCTAssertEqual(WorkboardCaptureDestination(workspace: workspace), .project(project.id, title: project.title))
        workspace.search = "Shared"
        XCTAssertEqual(workspace.visibleMaterials(in: [shared, loose]).map(\.id), [shared.id])
        XCTAssertEqual(workspace.composerScope, .all)
    }
}
