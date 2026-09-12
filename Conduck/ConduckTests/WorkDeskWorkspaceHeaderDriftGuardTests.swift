// SPDX-License-Identifier: Apache-2.0
//
// Structural guard for one active Work collection and its named actions.
// Layout, selection and the conversation draft share a responsive action row;
// project context and saved conversations remain in the project title menu.
// These source checks protect ownership and discoverability, not rendered fit
// or pointer behavior. Mutation cases verify that each regression is rejected.

import XCTest

final class WorkDeskWorkspaceHeaderDriftGuardTests: XCTestCase {
    private static let path = "Conduck/Views/Workboard/WorkDeskWorkspaceView.swift"
    private static let layoutPath = "Conduck/Views/Workboard/WorkDeskLayoutControl.swift"

    struct Surfaces {
        var header: String
        var collection: String
        var actions: String
        var menu: String
        var primary: String
        var layout: String
        var selection: String
        var navigation: String
    }

    static func violations(_ source: Surfaces) -> [String] {
        var found: [String] = []
        let layoutControl = "WorkDeskLayoutControl"
        if occurrences(layoutControl, in: source.actions) != 1 {
            found.append("Material actions must own exactly one layout control")
        }
        for (name, body) in [("header", source.header), ("collection container", source.collection), ("project menu", source.menu)] {
            if body.contains(layoutControl) {
                found.append("The \(name) must not duplicate the material layout control")
            }
        }
        if !source.header.contains("materialControls") || !source.collection.contains("materialActions") {
            found.append("The header must expose the collection row and its actions")
        }
        if !source.actions.contains("selectionControls") || !source.collection.contains("selectionBar") {
            found.append("Selection and its bulk actions must remain accessible with the materials")
        }
        if !source.actions.contains("if workspace.isSelecting || !workspace.visibleMaterials(in: item.materials).isEmpty") {
            found.append("Done must remain available after filtering or moving every visible material")
        }
        if source.header.contains("selectionControls") || source.menu.contains("selectionControls") {
            found.append("Material selection must stay out of project actions")
        }
        if source.actions.contains("preparingProjectID") {
            found.append("Layout and selection controls must not start a conversation")
        }
        if !source.collection.contains("ViewThatFits") || !source.collection.contains("HStack") || !source.collection.contains("VStack")
            || occurrences("newConversationButton", in: source.collection) < 2 {
            found.append("Wide and stacked collection rows must retain the named conversation action")
        }
        if !source.menu.contains("workspace.editingContextProjectID = project.id")
            || !source.menu.contains("workspace.conversations(in: project.id)")
            || !source.menu.contains("workspace.selectConversation(conversation.id, projectID: project.id)") {
            found.append("Project context and saved conversations must remain reachable from the title menu")
        }
        if source.menu.contains("isProjectTrayPresented") || source.collection.contains("isProjectTrayPresented")
            || source.header.contains("isProjectTrayPresented") || source.actions.contains("isProjectTrayPresented") {
            found.append("The selected collection must own its title and controls without a second Home surface")
        }
        if !source.navigation.contains("!navigationIsExternal") || !source.navigation.contains("!workspace.showsSidebar") {
            found.append("Home navigation must be available on compact hosts and when a wide sidebar is hidden")
        }
        if !source.primary.contains("Text(") || !source.primary.contains("LocalizedStringResource(")
            || source.primary.contains("isCompact") {
            found.append("The primary action must retain a localized visible name at every width")
        }
        if !source.layout.contains("Text(renderedMode.title)") || source.layout.contains("if !compact") {
            found.append("The layout control must name the layout even in compact presentation")
        }
        if !source.selection.contains("WorkDeskMaterialConversationCopy.title(count: workspace.selectedIDs.count)")
            || !source.selection.contains("workspace.beginConversation(materialIDs: workspace.selectedIDs") {
            found.append("Selected materials must open a counted conversation draft using their exact identifiers")
        }
        if !source.selection.contains("else if workspace.scope == .all") {
            found.append("Creating a project from selected materials must remain an All materials action")
        }
        if !source.selection.contains("workspace.assignSelection(to:")
            || !source.selection.contains("workspace.organization.add(materialIDs: ids") {
            found.append("Selected materials must retain distinct move and add actions")
        }
        return found
    }

    private static func occurrences(_ token: String, in source: String) -> Int {
        source.components(separatedBy: token).count - 1
    }

    private func sources() throws -> Surfaces {
        let source = try RefusalLaneSource.source(at: Self.path)
        func property(_ name: String) throws -> String {
            try RefusalLaneSource.trailingClosure(after: "var \(name):", in: source, path: Self.path)
        }
        return Surfaces(
            header: try RefusalLaneSource.body(ofFunction: "header", in: source, path: Self.path),
            collection: try property("materialControls"),
            actions: try property("materialActions"),
            menu: try RefusalLaneSource.source(at: "Conduck/Views/Workboard/WorkDeskToolbarTitle.swift"),
            primary: try property("newConversationButton"),
            layout: try RefusalLaneSource.source(at: Self.layoutPath),
            selection: try property("selectionBar"),
            navigation: try property("showsHomeNavigation")
        )
    }

    func testActiveCollectionKeepsOneSetOfControlsAndProjectActions() throws {
        let found = Self.violations(try sources())
        XCTAssertTrue(found.isEmpty, found.joined(separator: "; "))
    }

    private static let valid = Surfaces(
        header: "materialControls",
        collection: "ViewThatFits { HStack { materialActions newConversationButton } VStack { materialActions newConversationButton } } selectionBar",
        actions: "WorkDeskLayoutControl() if workspace.isSelecting || !workspace.visibleMaterials(in: item.materials).isEmpty { selectionControls }",
        menu: "workspace.editingContextProjectID = project.id workspace.conversations(in: project.id) workspace.selectConversation(conversation.id, projectID: project.id) renameProject ungroupProject",
        primary: "Button {} label: { Text(LocalizedStringResource(key)) }",
        layout: "Text(renderedMode.title)",
        selection: "WorkDeskMaterialConversationCopy.title(count: workspace.selectedIDs.count) workspace.beginConversation(materialIDs: workspace.selectedIDs) else if workspace.scope == .all workspace.assignSelection(to: target) workspace.organization.add(materialIDs: ids)",
        navigation: "!navigationIsExternal || !workspace.showsSidebar"
    )

    func testValidatorAcceptsOneRowWithNamedResponsiveAction() {
        XCTAssertEqual(Self.violations(Self.valid), [])
    }

    func testDuplicatingLayoutInHeaderOrOverflowIsRejected() {
        for keyPath in [\Surfaces.header, \Surfaces.menu, \Surfaces.collection] {
            var changed = Self.valid
            changed[keyPath: keyPath] += " WorkDeskLayoutControl()"
            XCTAssertFalse(Self.violations(changed).isEmpty)
        }
    }

    func testRemovingOrDuplicatingTheMaterialLayoutControlIsRejected() {
        for actions in ["selectionControls", "WorkDeskLayoutControl() WorkDeskLayoutControl() selectionControls"] {
            var changed = Self.valid
            changed.actions = actions
            XCTAssertFalse(Self.violations(changed).isEmpty)
        }
    }

    func testHidingCollectionOrSelectionEntrancesIsRejected() {
        for keyPath in [\Surfaces.collection, \Surfaces.actions] {
            var changed = Self.valid
            changed[keyPath: keyPath] = ""
            XCTAssertFalse(Self.violations(changed).isEmpty)
        }
    }

    func testHidingDoneWhenTheVisibleCollectionBecomesEmptyIsRejected() {
        var changed = Self.valid
        changed.actions = changed.actions.replacingOccurrences(
            of: "workspace.isSelecting || ", with: ""
        )
        XCTAssertTrue(Self.violations(changed).contains(
            "Done must remain available after filtering or moving every visible material"
        ))
    }

    func testMovingSelectionIntoProjectMenuIsRejected() {
        var changed = Self.valid
        changed.menu += " selectionControls"
        XCTAssertFalse(Self.violations(changed).isEmpty)
    }

    func testStartingConversationThroughLayoutOrSelectionControlsIsRejected() {
        var changed = Self.valid
        changed.actions += " preparingProjectID"
        XCTAssertFalse(Self.violations(changed).isEmpty)
    }

    func testLosingContextOrSavedConversationsIsRejected() {
        var changed = Self.valid
        changed.menu = "renameProject deleteProject"
        XCTAssertFalse(Self.violations(changed).isEmpty)
    }

    func testLeavingTheTitleOrControlsOnHomeBehindAProjectIsRejected() {
        for keyPath in [\Surfaces.header, \Surfaces.menu, \Surfaces.collection, \Surfaces.actions] {
            var changed = Self.valid
            changed[keyPath: keyPath] += " isProjectTrayPresented"
            XCTAssertFalse(Self.violations(changed).isEmpty)
        }
    }

    func testHidingHomeNavigationWithTheSidebarIsRejected() {
        var changed = Self.valid
        changed.navigation = "!sidebarIsHosted"
        XCTAssertFalse(Self.violations(changed).isEmpty)
    }

    func testLosingAddWhileRetainingMoveIsRejected() {
        var changed = Self.valid
        changed.selection = changed.selection.replacingOccurrences(of: "workspace.organization.add(materialIDs: ids)", with: "")
        XCTAssertFalse(Self.violations(changed).isEmpty)
    }

    func testLosingTheExactSelectedMaterialActionIsRejected() {
        var changed = Self.valid
        changed.selection = "New conversation Create project"
        XCTAssertFalse(Self.violations(changed).isEmpty)
    }

    func testDroppingTheStackedConversationActionIsRejected() {
        var changed = Self.valid
        changed.collection = "ViewThatFits { HStack { materialActions newConversationButton } VStack { materialActions } } selectionBar"
        XCTAssertFalse(Self.violations(changed).isEmpty)
    }

    func testReplacingTheConversationNameWithAnIconIsRejected() {
        var changed = Self.valid
        changed.primary = "Button {} label: { Image(systemName: symbol) }"
        XCTAssertFalse(Self.violations(changed).isEmpty)
    }

    func testHidingTheLayoutNameAtCompactWidthsIsRejected() {
        var changed = Self.valid
        changed.layout = "if !compact { Text(renderedMode.title) }"
        XCTAssertFalse(Self.violations(changed).isEmpty)
    }
}
