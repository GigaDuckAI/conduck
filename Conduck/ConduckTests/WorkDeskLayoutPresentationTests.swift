// SPDX-License-Identifier: Apache-2.0

// The named layout picker and the board must describe the same presentation.
// A temporary readable result never rewrites a stored spatial preference, and
// people retaining Tiles can still discover Desk directly in the header.

import XCTest
@testable import Conduck

@MainActor
final class WorkDeskLayoutPresentationTests: XCTestCase {
    func testDeskAndProjectHonorEverySavedLayout() {
        for mode in WorkboardLayoutMode.allCases {
            XCTAssertEqual(resolve(mode, spatial: true), mode)
        }
    }

    func testSearchAndAggregateViewsReportTheReadableFallback() {
        XCTAssertEqual(resolve(.desk, spatial: false), .list)
        XCTAssertEqual(resolve(.tiles, spatial: false), .tiles)
        XCTAssertEqual(resolve(.list, spatial: false), .list)
    }

    func testAccessibilityTextAlwaysReportsTheListThatIsRendered() {
        for mode in WorkboardLayoutMode.allCases {
            XCTAssertEqual(WorkDeskLayoutPresentation.resolved(
                preference: mode, supportsSpatialLayout: true, requiresAccessibleList: true
            ), .list)
        }
    }

    func testReturningFromSearchRestoresTheSpatialPreference() {
        let preference = WorkboardLayoutMode.desk
        XCTAssertEqual(resolve(preference, spatial: false), .list)
        XCTAssertEqual(resolve(preference, spatial: true), .desk)
    }

    func testHeaderExposesNamedControlAndBoardUsesTheSamePolicy() throws {
        let host = try RefusalLaneSource.source(at: "Conduck/Views/Workboard/WorkDeskWorkspaceView.swift")
        let header = try RefusalLaneSource.body(ofFunction: "header", in: host,
            path: "Conduck/Views/Workboard/WorkDeskWorkspaceView.swift")
        XCTAssertTrue(header.contains("WorkDeskLayoutControl("))
        let control = try RefusalLaneSource.source(at: "Conduck/Views/Workboard/WorkDeskLayoutControl.swift")
        XCTAssertTrue(control.contains("Text(renderedMode.title)"), "An icon-only menu hides the new desk again.")
        XCTAssertTrue(control.contains("viewModel.layoutMode = $0"))
        let board = try RefusalLaneSource.source(at: "Conduck/Views/Workboard/WorkDeskSourceBoard.swift")
        XCTAssertTrue(board.contains("WorkDeskLayoutPresentation.resolved("))
    }

    private func resolve(_ preference: WorkboardLayoutMode, spatial: Bool) -> WorkboardLayoutMode {
        WorkDeskLayoutPresentation.resolved(preference: preference,
            supportsSpatialLayout: spatial, requiresAccessibleList: false)
    }
}
