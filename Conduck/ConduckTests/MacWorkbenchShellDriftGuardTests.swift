// SPDX-License-Identifier: Apache-2.0
// Conduck
// MacWorkbenchShellDriftGuardTests.swift
//
// SOURCE DRIFT GUARD over the macOS window shell's Work / Chats arrangement.
//
// Four facts about that window are load-bearing, invisible in a diff, and
// verifiable only by eye on a signed Mac — this suite is the cheap half of that
// check. (1) Work owns a project rail inside its workspace, so the native Chat
// sidebar stays COLLAPSED while Work is active.
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

    func testVisitedWorkKeepsItsViewIdentityAcrossLongAndRapidRoundTrips() throws {
        let source = try shellSource()
        let mount = try RefusalLaneSource.trailingClosure(
            after: "private var mountsWorkLayer: Bool", in: source, path: Self.path
        )
        XCTAssertTrue(mount.contains("workDestinationIsActive || workLayerIsReady"))
        let activation = try RefusalLaneSource.trailingClosure(
            after: ".task(id: workDestinationIsActive)", in: source, path: Self.path
        )
        XCTAssertTrue(activation.contains("guard workDestinationIsActive else { return }"))
        XCTAssertTrue(activation.contains("workLayerIsReady = true"))
        XCTAssertEqual(source.components(separatedBy: "workLayerIsReady = false").count - 1, 1,
                       "Only the @State declaration may initialize the latch; leaving Work must not reset it")
        XCTAssertFalse(activation.contains("Task.sleep"),
                       "A delayed unmount discards scroll and thumbnail state after every visit")
    }

    func testModeChangeSuppressesSplitMotionWhileOnlyLayerOpacityDissolves() throws {
        let source = try shellSource()
        let split = try RefusalLaneSource.trailingClosure(
            after: "private var persistentSplitView: some View", in: source, path: Self.path
        )
        let transaction = try RefusalLaneSource.trailingClosure(
            after: ".transaction(value: workDestinationIsActive)", in: split, path: Self.path
        )
        XCTAssertTrue(transaction.contains("transaction.animation = nil"))
        XCTAssertTrue(transaction.contains("transaction.disablesAnimations = true"))

        let path = "Conduck/Views/Workboard/PersonalWorkbenchView.swift"
        let layers = try RefusalLaneSource.source(at: path)
        let modifier = try RefusalLaneSource.trailingClosure(
            after: "struct WorkbenchDestinationLayerModifier: ViewModifier", in: layers, path: path
        )
        let pixels = try RefusalLaneSource.trailingClosure(after: "body:", in: modifier, path: path)
        XCTAssertTrue(pixels.contains("animatedContent.opacity(isVisible ? 1 : 0)"))
        XCTAssertFalse(pixels.contains("frame("))
        XCTAssertFalse(pixels.contains("allowsHitTesting"))
        XCTAssertTrue(modifier.contains(".allowsHitTesting(isActive)"))
        XCTAssertTrue(modifier.contains(".accessibilityHidden(!isActive)"))
    }

    func testWorkReplacesOnlyTheDefaultToggleWithoutReplacingTheSplitView() throws {
        let source = try shellSource()
        let split = try RefusalLaneSource.trailingClosure(
            after: "private var persistentSplitView: some View", in: source, path: Self.path
        )
        XCTAssertEqual(split.components(separatedBy: "NavigationSplitView(columnVisibility:").count - 1, 1)
        XCTAssertTrue(split.contains(".toolbar(removing: workDestinationIsActive ? .sidebarToggle : nil)"),
                      "Only Work removes the native Chat toggle; nil restores the platform control in Chats")
        let sidebar = try RefusalLaneSource.trailingClosure(
            after: "NavigationSplitView(columnVisibility: splitColumnVisibility)", in: split, path: Self.path
        )
        XCTAssertTrue(sidebar.contains(".toolbar(removing: workDestinationIsActive ? .sidebarToggle : nil)"),
                      "Default sidebar removal must be attached to the sidebar column that owns it")
    }

    func testChatToolbarActionsAreHiddenAndRefuseStaleWorkTaps() throws {
        let source = try shellSource()
        let split = try RefusalLaneSource.trailingClosure(
            after: "private var persistentSplitView: some View", in: source, path: Self.path
        )
        let chat = try RefusalLaneSource.trailingClosure(
            after: "if chatDestinationIsActive", in: split, path: Self.path
        )
        XCTAssertTrue(chat.contains("LeadingToolbarChrome(column: .sidebar)"))
        XCTAssertTrue(chat.contains("toolbar.deleteAll"))
        let compose = try RefusalLaneSource.trailingClosure(
            after: "LeadingToolbarChrome(column: .sidebar)", in: chat, path: Self.path
        )
        let guardAt = try XCTUnwrap(compose.range(of: "guard chatDestinationIsActive else { return }")?.lowerBound)
        let actionAt = try XCTUnwrap(compose.range(of: "startNewConversation()")?.lowerBound)
        XCTAssertLessThan(guardAt, actionAt)
        XCTAssertFalse(compose.contains("activateChatsForToolbarAction"),
                       "A stale Work toolbar tap must not bridge itself into Chats")
        let work = try RefusalLaneSource.trailingClosure(
            after: "if workDestinationIsActive, let personalWorkbenchModel", in: split, path: Self.path
        )
        XCTAssertTrue(work.contains("WorkDeskSidebarToolbarButton("))
        XCTAssertFalse(work.contains("LeadingToolbarChrome"))
        XCTAssertFalse(work.contains("startNewConversation"))
    }

    func testWorkToolbarUsesTheSameCachedProjectNavigationAsItsDesk() throws {
        let source = try shellSource()
        XCTAssertTrue(source.contains("workspace: personalWorkbenchModel.workboardViewModel.deskWorkspace"))
        XCTAssertTrue(source.contains(".environment(\\.workDeskSidebarIsHosted, true)"))
        let path = "Conduck/Views/Workboard/WorkboardView.swift"
        let workSource = try RefusalLaneSource.source(at: path)
        let buttonStart = try XCTUnwrap(workSource.range(of: "struct WorkDeskSidebarToolbarButton"))
        let button = try RefusalLaneSource.trailingClosure(
            after: "var body: some View", in: String(workSource[buttonStart.lowerBound...]), path: path
        )
        XCTAssertTrue(button.contains("guard isActive else { return }"))
        XCTAssertTrue(button.contains("workspace.toggleProjectNavigation()"))
        XCTAssertTrue(button.contains(".disabled(!isActive)"))
        XCTAssertFalse(button.contains("chatColumnVisibility"))
        XCTAssertFalse(button.contains("startNewConversation"))
        XCTAssertFalse(button.contains(".pointerIconButton"),
                       "The system toolbar must keep its native button style")
    }

    func testIPadComposeAlreadyUsesItsActiveDestinationGateAndRejectsHiddenActions() throws {
        let path = "Conduck/Views/Conversation/ConversationLibraryView.swift"
        let source = try RefusalLaneSource.source(at: path)
        XCTAssertTrue(source.contains("if workbenchDestinationIsActive, !sidebarBarOnScreen"))
        let sidebar = try RefusalLaneSource.trailingClosure(
            after: "if workbenchDestinationIsActive", in: source, path: path
        )
        XCTAssertTrue(sidebar.contains("LeadingToolbarChrome(column: .sidebar)"))
        let action = try RefusalLaneSource.body(ofFunction: "startNewConversation", in: source, path: path)
        XCTAssertTrue(action.contains("guard workbenchDestinationIsActive else { return }"))
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
