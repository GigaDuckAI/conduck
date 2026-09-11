// SPDX-License-Identifier: Apache-2.0
// Conduck
// WorkDeskWorkspaceHeaderDriftGuardTests.swift
//
// SOURCE DRIFT GUARD over the Work desk's in-pane header.
//
// The header and the overflow menu are two places that can each draw the layout
// control, and width alone decides which of them should: the header draws it on
// anything but a narrow window, so an unconditional copy in the menu puts the
// same picker on screen twice inside one project. A narrow window is the case
// the header skips, and there the menu is the only door to it — so the menu's
// copy must exist, but only under `isCompact`.
//
// Presence assertions alone do NOT establish that. Two broken shapes satisfy
// "the menu mentions the control and the header mentions the control": a SECOND
// unconditional control in the menu (duplication returns), and a header whose
// control is replaced by something else while its condition stays (wide windows
// and every non-project scope lose the only door). So each side is pinned by
// COUNT and by ATTACHMENT to its condition, and every predicate runs through one
// validator that the mutation tests below drive over synthetic sources. A guard
// nobody has seen reject anything reads as coverage without being it.
//
// Scoped to the ONE declaration that owns each rule
// (`RefusalLaneSource.body(ofFunction:)`), because an unscoped `contains` over a
// 700-line view is satisfied by any unrelated statement in it.

import XCTest

final class WorkDeskWorkspaceHeaderDriftGuardTests: XCTestCase {

    private static let path = "Conduck/Views/Workboard/WorkDeskWorkspaceView.swift"
    private static let control = "WorkDeskLayoutControl"

    /// The header's own condition, verbatim. The control must be the FIRST thing
    /// inside it, so replacing the control while keeping the condition fails.
    private static let headerGate = "else if !workspace.isSelecting && (!isCompact || workspace.currentProject == nil) { \(control)"
    /// The menu's gate, same shape and the same reason.
    private static let menuGate = "if isCompact { \(control)"

    private static func squeezed(_ source: String) -> String {
        source.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Every violation of the one-door rule, given the two declarations' bodies.
    /// Shared by the real-source test and the mutation tests so they cannot drift
    /// apart: a validator only the happy path exercises proves nothing.
    static func violations(headerBody: String, menuBody: String) -> [String] {
        let header = squeezed(headerBody)
        let menu = squeezed(menuBody)
        var found: [String] = []

        let headerCount = header.components(separatedBy: control).count - 1
        let menuCount = menu.components(separatedBy: control).count - 1

        if headerCount != 1 {
            found.append("the header must draw the layout control exactly once, found \(headerCount)")
        }
        if menuCount != 1 {
            found.append("the overflow menu must draw the layout control exactly once, found \(menuCount)")
        }
        if !header.contains(headerGate) {
            found.append("the header's control must sit directly inside its width condition")
        }
        if !menu.contains(menuGate) {
            found.append("the menu's control must sit directly inside `if isCompact`")
        }
        if !header.contains("workspaceMenu(isCompact: isCompact)") {
            found.append("the menu must be handed the header's own isCompact")
        }
        // The menu call is reached only inside the project condition, so pinning
        // the call text alone is not enough: inverting this condition removes
        // Prepare AND the overflow from every project — taking a compact
        // project's only layout door with it — while the call still reads right.
        if !header.contains("if workspace.currentProject != nil && !workspace.isSearching && !workspace.isSelecting { Button") {
            found.append("Prepare and the overflow must stay behind the project condition")
        }
        return found
    }

    private func bodies() throws -> (header: String, menu: String) {
        let source = try RefusalLaneSource.source(at: Self.path)
        return (
            try RefusalLaneSource.body(ofFunction: "header", in: source, path: Self.path),
            try RefusalLaneSource.body(ofFunction: "workspaceMenu", in: source, path: Self.path)
        )
    }

    func testTheLayoutControlHasExactlyOneDoorInEveryWidthAndScope() throws {
        let (header, menu) = try bodies()
        let found = Self.violations(headerBody: header, menuBody: menu)
        XCTAssertTrue(found.isEmpty, "one-door rule broken: \(found.joined(separator: "; "))")
    }

    // MARK: - Mutations the guard must reject

    private static let goodHeader = """
        } else if !workspace.isSelecting && (!isCompact || workspace.currentProject == nil) {
            WorkDeskLayoutControl(viewModel: viewModel, supportsSpatialLayout: x)
        }
        if workspace.currentProject != nil && !workspace.isSearching && !workspace.isSelecting { Button }
        workspaceMenu(isCompact: isCompact)
        """
    private static let goodMenu = """
        Menu {
            if isCompact {
                WorkDeskLayoutControl(viewModel: viewModel, supportsSpatialLayout: x)
            }
        }
        """

    func testTheValidatorAcceptsTheShapeTheViewActuallyHas() {
        XCTAssertEqual(Self.violations(headerBody: Self.goodHeader, menuBody: Self.goodMenu), [])
    }

    /// The original defect: the menu drew the control unconditionally, so a wide
    /// project showed the same picker in the header and in the overflow.
    func testAnUngatedMenuControlIsRejected() {
        let menu = "Menu { WorkDeskLayoutControl(viewModel: viewModel, supportsSpatialLayout: x) }"
        XCTAssertFalse(Self.violations(headerBody: Self.goodHeader, menuBody: menu).isEmpty)
    }

    /// A SECOND control added beside the gated one restores duplication while the
    /// gate still reads correctly — the case a presence check cannot see.
    func testASecondMenuControlBesideTheGatedOneIsRejected() {
        // Written out rather than patched into `goodMenu`: a fixture built by
        // string surgery can silently fail to apply and leave the test asserting
        // about the UNMUTATED shape, which passes for the wrong reason.
        let menu = """
            Menu {
                if isCompact {
                    WorkDeskLayoutControl(viewModel: viewModel, supportsSpatialLayout: x)
                }
                WorkDeskLayoutControl(viewModel: viewModel, supportsSpatialLayout: x)
            }
            """
        XCTAssertEqual(menu.components(separatedBy: Self.control).count - 1, 2, "the fixture must carry two controls")
        XCTAssertFalse(Self.violations(headerBody: Self.goodHeader, menuBody: menu).isEmpty)
    }

    /// The header keeps its condition but stops drawing the control: wide windows
    /// and every non-project scope lose their only door, with the menu unchanged.
    func testAHeaderThatKeepsItsConditionButDropsTheControlIsRejected() {
        let header = Self.goodHeader.replacingOccurrences(
            of: "WorkDeskLayoutControl(viewModel: viewModel, supportsSpatialLayout: x)",
            with: "EmptyView()"
        )
        XCTAssertNotEqual(header, Self.goodHeader, "the mutation must actually apply")
        XCTAssertFalse(Self.violations(headerBody: header, menuBody: Self.goodMenu).isEmpty)
    }

    /// The control escapes its condition entirely and draws at every width, so a
    /// narrow project shows it in the header AND in the overflow.
    func testAHeaderControlMovedOutsideItsConditionIsRejected() {
        let header = """
            } else if !workspace.isSelecting && (!isCompact || workspace.currentProject == nil) {
                Spacer()
            }
            WorkDeskLayoutControl(viewModel: viewModel, supportsSpatialLayout: x)
            if workspace.currentProject != nil && !workspace.isSearching && !workspace.isSelecting { Button }
            workspaceMenu(isCompact: isCompact)
            """
        XCTAssertFalse(Self.violations(headerBody: header, menuBody: Self.goodMenu).isEmpty)
    }

    /// Inverting the project condition strips Prepare and the overflow from every
    /// project — and a compact project's only layout control with them — while
    /// every other predicate here still reads correctly.
    func testAnInvertedProjectConditionIsRejected() {
        let header = Self.goodHeader.replacingOccurrences(
            of: "if workspace.currentProject != nil && !workspace.isSearching && !workspace.isSelecting { Button",
            with: "if workspace.currentProject == nil && !workspace.isSearching && !workspace.isSelecting { Button"
        )
        XCTAssertNotEqual(header, Self.goodHeader, "the mutation must actually apply")
        XCTAssertFalse(Self.violations(headerBody: header, menuBody: Self.goodMenu).isEmpty)
    }

    /// The two sites stop sharing one width decision and can disagree about which
    /// of them is drawing.
    func testAMenuHandedItsOwnWidthDecisionIsRejected() {
        let header = Self.goodHeader.replacingOccurrences(
            of: "workspaceMenu(isCompact: isCompact)",
            with: "workspaceMenu(isCompact: true)"
        )
        XCTAssertNotEqual(header, Self.goodHeader, "the mutation must actually apply")
        XCTAssertFalse(Self.violations(headerBody: header, menuBody: Self.goodMenu).isEmpty)
    }
}
