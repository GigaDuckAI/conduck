// SPDX-License-Identifier: Apache-2.0
// Conduck
// MacWorkbenchShellDriftGuardTests.swift
//
// SOURCE DRIFT GUARD over the macOS window shell's Work / Chats arrangement.
//
// Four facts about that window are load-bearing, invisible in a diff, and
// verifiable only by eye on a signed Mac — this suite is the cheap half of that
// check. (1) Work and Chats share one native sidebar and Settings footer, with
// retained navigation content in each mode. (2) Each mode remembers its own
// collapse state; native writes update only the active mode.
// (3) The Work/Chats section control is
// declared LAST on the detail side because toolbar items are collected in
// view-tree order: anything declared after it slides it sideways whenever that
// item comes or goes. (4) The centred principal item keeps the workspace
// identity in Work and a placeholder without a gateway — empty principal content
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

    func testBothDestinationsUseTheNativeToggleAndOnePersistentSplitView() throws {
        let source = try shellSource()
        let split = try RefusalLaneSource.trailingClosure(
            after: "private var persistentSplitView: some View", in: source, path: Self.path
        )
        XCTAssertEqual(split.components(separatedBy: "NavigationSplitView(columnVisibility:").count - 1, 1)
        XCTAssertFalse(split.contains(".toolbar(removing:"))
        XCTAssertFalse(split.contains("WorkDeskSidebarToolbarButton("))
        let sidebar = try RefusalLaneSource.trailingClosure(
            after: "private var mountedSidebarDestinations: some View", in: source, path: Self.path
        )
        XCTAssertTrue(sidebar.contains("WorkDeskSidebarView(viewModel: personalWorkbenchModel.workboardViewModel)"))
        XCTAssertEqual(sidebar.components(separatedBy: "identityFooter").count - 1, 1)
        XCTAssertTrue(sidebar.contains(".environment(\\.workbenchDestinationIsActive, workDestinationIsActive)"))
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
        XCTAssertFalse(split.contains("WorkDeskSidebarToolbarButton("),
                       "Work uses the same native sidebar toggle; it must not add another control")
    }

    func testWorkNativeSidebarKeepsTheComposerInTheDetailColumn() throws {
        let source = try shellSource()
        XCTAssertTrue(source.contains(".environment(\\.workDeskSidebarIsHosted, true)"))
        XCTAssertTrue(source.contains(".environment(\\.workDeskNavigationIsExternal, true)"))
        let path = "Conduck/Views/Workboard/WorkDeskWorkspaceView.swift"
        let workspace = try RefusalLaneSource.source(at: path)
        let layout = try RefusalLaneSource.trailingClosure(
            after: "private var workspaceLayout: some View", in: workspace, path: path
        )
        XCTAssertFalse(layout.contains("WorkDeskSidebarView("),
                       "An internal rail would end above the composer's full-width inset again")
        XCTAssertTrue(layout.contains("workspace.updateSidebarLayout(isInline: external)"))
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

    /// Native visibility follows the active destination's remembered choice.
    func testWorkVisibilityComesFromItsOwnRememberedSidebarState() throws {
        let source = try shellSource()
        let derivation = try RefusalLaneSource.trailingClosure(
            after: "private var effectiveColumnVisibility: NavigationSplitViewVisibility",
            in: source, path: Self.path
        )
        XCTAssertTrue(derivation.contains("workDestinationIsActive"))
        XCTAssertTrue(derivation.contains("deskWorkspace.showsSidebar ? .all : .detailOnly"))
        XCTAssertTrue(derivation.contains("return chatColumnVisibility"))
    }

    /// Nothing that happens while Work is on screen may rewrite the state Chat
    /// is restored to.
    func testWorkNeverWritesChatsRememberedSidebarState() throws {
        let source = try shellSource()
        let binding = try RefusalLaneSource.trailingClosure(
            after: "private var splitColumnVisibility: Binding<NavigationSplitViewVisibility>",
            in: source, path: Self.path
        )
        let work = try RefusalLaneSource.trailingClosure(
            after: "if workDestinationIsActive, let personalWorkbenchModel", in: binding, path: Self.path
        )
        XCTAssertTrue(work.contains("deskWorkspace.showsSidebar = newValue != .detailOnly"))
        XCTAssertFalse(work.contains("chatColumnVisibility ="))
        let chat = try RefusalLaneSource.trailingClosure(after: "else", in: binding, path: Self.path)
        XCTAssertTrue(chat.contains("chatColumnVisibility = newValue"))
        XCTAssertFalse(chat.contains("deskWorkspace.showsSidebar ="))
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

    /// Work's title and the no-gateway placeholder both preserve the slot.
    func testPrincipalSlotKeepsWorkIdentityAndNoGatewayPlaceholder() throws {
        let source = try shellSource()
        let content = try RefusalLaneSource.trailingClosure(
            after: "private var gatewayToolbarContent: some View",
            in: source,
            path: Self.path
        )
        let work = try RefusalLaneSource.trailingClosure(
            after: "if workDestinationIsActive, let personalWorkbenchModel",
            in: content, path: Self.path
        )
        XCTAssertTrue(work.contains("WorkDeskToolbarTitle(workspace: personalWorkbenchModel.workboardViewModel.deskWorkspace)"))
        let placeholder = try RefusalLaneSource.trailingClosure(
            after: "else if !coordinator.hasAnyConfiguredGateway",
            in: content, path: Self.path
        )
        XCTAssertTrue(placeholder.contains("Color.clear"))
        XCTAssertTrue(placeholder.contains(".frame(width: 1, height: 1)"))
    }
}
