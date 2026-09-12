// SPDX-License-Identifier: Apache-2.0
//
// Structural guard for the Work project's two levels of controls. Layout and
// selection belong to the materials row; starting a conversation belongs to
// the project header or an explicitly counted selection action. Responsive
// alternatives reuse the same named action.
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
        if source.header.contains("selectionControls") || source.menu.contains("selectionControls") {
            found.append("Material selection must stay out of project actions")
        }
        if source.collection.contains("newConversationButton") || source.actions.contains("preparingProjectID") {
            found.append("Collection tools must not imply starting a conversation")
        }
        if !source.header.contains("ViewThatFits") || !source.header.contains("HStack") || !source.header.contains("VStack")
            || occurrences("newConversationButton", in: source.header) < 2 {
            found.append("Wide and stacked headers must retain the shared conversation action")
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
            selection: try property("selectionBar")
        )
    }

    func testProjectAndCollectionControlsKeepSeparateOwnership() throws {
        let found = Self.violations(try sources())
        XCTAssertTrue(found.isEmpty, found.joined(separator: "; "))
    }

    private static let valid = Surfaces(
        header: "ViewThatFits { HStack { newConversationButton } VStack { newConversationButton } } materialControls",
        collection: "materialActions selectionBar",
        actions: "WorkDeskLayoutControl() selectionControls",
        menu: "renameProject ungroupProject",
        primary: "Button {} label: { Text(LocalizedStringResource(key)) }",
        layout: "Text(renderedMode.title)",
        selection: "WorkDeskMaterialConversationCopy.title(count: workspace.selectedIDs.count) workspace.beginConversation(materialIDs: workspace.selectedIDs) else if workspace.scope == .all"
    )

    func testValidatorAcceptsSeparateControlsWithNamedResponsiveAction() {
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

    func testMovingSelectionIntoProjectMenuIsRejected() {
        var changed = Self.valid
        changed.menu += " selectionControls"
        XCTAssertFalse(Self.violations(changed).isEmpty)
    }

    func testPlacingConversationActionAmongCollectionToolsIsRejected() {
        var changed = Self.valid
        changed.collection += " newConversationButton"
        XCTAssertFalse(Self.violations(changed).isEmpty)
    }

    func testLosingTheExactSelectedMaterialActionIsRejected() {
        var changed = Self.valid
        changed.selection = "New conversation Create project"
        XCTAssertFalse(Self.violations(changed).isEmpty)
    }

    func testDroppingTheStackedConversationActionIsRejected() {
        var changed = Self.valid
        changed.header = "ViewThatFits { HStack { newConversationButton } VStack { projectIdentity } } materialControls"
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
