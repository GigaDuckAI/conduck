// SPDX-License-Identifier: Apache-2.0

// Card labels do not host child buttons: SwiftUI routes that tap to the
// containing card. Metadata controls are sibling overlays, and the parent
// supplies their named accessibility actions independently of the anchors.

import XCTest

final class WorkDeskMetadataInteractionGuardTests: XCTestCase {
    private static func violations(labels: String, card: String, row: String, overlay: String) -> [String] {
        var errors: [String] = []
        if labels.contains("Button") { errors.append("Metadata labels must not contain nested buttons") }
        for (name, source) in [("card", card), ("row", row)] {
            if !source.contains(".workDeskMetadataControls(organizationActions)") {
                errors.append("The \(name) must host sibling metadata controls")
            }
        }
        if !overlay.contains("overlayPreferenceValue") || !overlay.contains("geometry[anchor]") {
            errors.append("Sibling controls must use the label's actual bounds")
        }
        return errors
    }

    func testImageTilesTextTilesAndRowsHostRealMetadataControls() throws {
        let source = try RefusalLaneSource.source(at: "Conduck/Views/Workboard/WorkDeskMaterialOrganizationActions.swift")
        let labels = try XCTUnwrap(source.components(separatedBy: "struct WorkDeskMaterialLocation: View").last?
            .components(separatedBy: "private enum WorkDeskMetadataAction").first)
        let card = try RefusalLaneSource.source(at: "Conduck/Views/Workboard/WorkboardCaptureCanvas.swift")
        let row = try RefusalLaneSource.source(at: "Conduck/Views/Workboard/WorkboardMaterialListRow.swift")
        XCTAssertEqual(Self.violations(labels: labels, card: card, row: row, overlay: source), [])
        XCTAssertTrue(card.contains("organizationActions.showsMetadata"), "Image tiles must not omit usage or unfiled labels")
        XCTAssertTrue(card.contains("actions.accessibilityMetadata"))
        XCTAssertTrue(row.contains("organizationActions.accessibilityMetadata"))
    }

    func testRemovingSiblingControlsOrNestingThemInLabelsIsRejected() {
        let valid = ".workDeskMetadataControls(organizationActions)"
        let overlay = "overlayPreferenceValue geometry[anchor]"
        XCTAssertFalse(Self.violations(labels: "Button(action: openProject)", card: valid, row: valid, overlay: overlay).isEmpty)
        XCTAssertFalse(Self.violations(labels: "Label(project)", card: "", row: valid, overlay: overlay).isEmpty)
        XCTAssertFalse(Self.violations(labels: "Label(project)", card: valid, row: "", overlay: overlay).isEmpty)
        XCTAssertFalse(Self.violations(labels: "Label(project)", card: valid, row: valid, overlay: "fixed guessed positions").isEmpty)
    }
}
