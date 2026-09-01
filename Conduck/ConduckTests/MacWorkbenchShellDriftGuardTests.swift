// SPDX-License-Identifier: Apache-2.0
// Conduck
// MacWorkbenchShellDriftGuardTests.swift
//
// SOURCE DRIFT GUARD over the macOS window shell's Work / Chats arrangement.
//
// Four facts about that window are load-bearing, invisible in a diff, and
// verifiable only by eye on a signed Mac — this suite is the cheap half of that
// check. (1) Work is ONE desk with no list beside it, so the sidebar column is
// COLLAPSED for as long as Work is active and the desk gets the whole window.
// (2) Chat's own collapse state has to survive a round trip through Work, which
// means the forced collapse must never be written back into it — including by
// AppKit, which revises the visibility binding on its own when the window is
// resized past the two-column floor. (3) The Work/Chats section control is
// declared LAST on the detail side because toolbar items are collected in
// view-tree order: anything declared after it slides it sideways whenever that
// item comes or goes. (4) The centred principal item must keep a zero-area
// placeholder while Work is active — a principal item with empty content
// produces no `NSToolbarItem`, and the flexible spaces AppKit puts around one
// are the only thing holding the section control against the trailing edge.
//
// `MainWindowView` is `#if os(macOS)` and is never compiled by this suite, so
// each invariant is asserted where it is written, over the file's text with
// comments stripped (`RefusalLaneSource`). A guard that fails because the shape
// legitimately changed is a guard to update, not a bug to route around.

import XCTest

final class MacWorkbenchShellDriftGuardTests: XCTestCase {

    private static let path = "Conduck/Views/Conversation/MainWindowView.swift"

    private func shellSource() throws -> String {
        try RefusalLaneSource.source(at: Self.path)
    }

    /// The split view is driven by the DERIVED visibility, and that derivation
    /// collapses the column while Work is active.
    func testWorkCollapsesTheSidebarColumn() throws {
        let source = try shellSource()

        XCTAssertTrue(
            source.contains("NavigationSplitView(columnVisibility: splitColumnVisibility)"),
            "The split view no longer reads the derived visibility, so nothing collapses the sidebar "
            + "column for Work and the desk shares the window with an empty column."
        )

        let derivation = try RefusalLaneSource.trailingClosure(
            after: "private var effectiveColumnVisibility: NavigationSplitViewVisibility",
            in: source,
            path: Self.path
        )
        XCTAssertTrue(
            derivation.contains("workDestinationIsActive"),
            "`effectiveColumnVisibility` no longer depends on the destination, so Work cannot collapse "
            + "the column it has nothing to put in."
        )
        XCTAssertTrue(
            derivation.contains(".detailOnly"),
            "`effectiveColumnVisibility` no longer resolves to `.detailOnly`, so Work stops collapsing "
            + "the sidebar column."
        )
        XCTAssertTrue(
            derivation.contains("chatColumnVisibility"),
            "`effectiveColumnVisibility` no longer falls back to Chat's own state, so returning from "
            + "Work forces the column open over whatever the user chose."
        )
    }

    /// Nothing that happens while Work is on screen may rewrite the state Chat
    /// is restored to.
    func testWorkNeverWritesChatsRememberedSidebarState() throws {
        let source = try shellSource()
        let binding = try RefusalLaneSource.trailingClosure(
            after: "private var splitColumnVisibility: Binding<NavigationSplitViewVisibility>",
            in: source,
            path: Self.path
        )

        let guardAt = try XCTUnwrap(
            binding.range(of: "guard !workDestinationIsActive")?.lowerBound,
            "`splitColumnVisibility` accepts writes while Work is active. The section has no sidebar to "
            + "describe, so an AppKit write-back there silently becomes Chat's remembered state."
        )
        let writeAt = try XCTUnwrap(
            binding.range(of: "chatColumnVisibility = newValue")?.lowerBound,
            "`splitColumnVisibility` no longer records Chat's own collapse state, so a column the user "
            + "collapsed by hand reopens on the next section switch."
        )
        XCTAssertLessThan(
            guardAt, writeAt,
            "The write happens before the guard, which guards nothing."
        )
    }

    /// The section control keeps its measured trailing-most slot: declared after
    /// the Chat layer, and the last toolbar declaration in the detail column.
    func testSectionControlIsTheTrailingMostDetailSideToolbarItem() throws {
        let source = try shellSource()
        let mount = try RefusalLaneSource.trailingClosure(
            after: "private var mountedDetailDestinations: some View",
            in: source,
            path: Self.path
        )

        let chatLayerAt = try XCTUnwrap(
            mount.range(of: "detailColumn")?.lowerBound,
            "`mountedDetailDestinations` no longer mounts Chat's detail column."
        )
        let sectionAt = try XCTUnwrap(
            mount.range(of: "workbenchSectionPicker(for:")?.lowerBound,
            "`mountedDetailDestinations` no longer declares the Work/Chats control, so the section "
            + "switch loses its one persistent slot."
        )
        XCTAssertLessThan(
            chatLayerAt, sectionAt,
            "The section control is declared BEFORE Chat's layer. Toolbar items are collected in "
            + "view-tree order, so Chat's conditional Copy-conversation button then renders to its "
            + "right and drags the control sideways every time that button appears."
        )
        XCTAssertNil(
            mount.range(of: ".toolbar", range: sectionAt..<mount.endIndex),
            "A second toolbar declaration follows the section control in the detail column, which "
            + "moves it off the trailing edge."
        )
    }

    /// Work's principal slot stays occupied by a zero-area placeholder.
    func testPrincipalSlotKeepsAZeroAreaPlaceholderWhileWorkIsActive() throws {
        let source = try shellSource()
        let content = try RefusalLaneSource.trailingClosure(
            after: "private var gatewayToolbarContent: some View",
            in: source,
            path: Self.path
        )
        let branches = try XCTUnwrap(
            RefusalLaneSource.branches(
                ofIf: "if !chatDestinationIsActive || !coordinator.hasAnyConfiguredGateway {",
                in: content
            ),
            "`gatewayToolbarContent` no longer opens with the branch that covers Work and the "
            + "no-gateway case. If the condition legitimately changed, update this token."
        )
        XCTAssertTrue(
            branches.then.contains("Color.clear"),
            "The Work branch of the principal item no longer resolves to a placeholder. Empty content "
            + "produces no toolbar item at all, and the section control drops to the leading edge of "
            + "the content region the moment Work is shown."
        )
    }
}
