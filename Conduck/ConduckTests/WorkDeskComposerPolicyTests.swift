// SPDX-License-Identifier: Apache-2.0

// Composer presentation defaults and integration safeguards. These checks
// protect the reported missing gateway/split action-bar regressions without
// claiming rendered layout or real keyboard interaction from source tests.

import XCTest
@testable import Conduck

final class WorkDeskComposerPolicyTests: XCTestCase {
    func testSmallAndEmptyProjectsExposeTheirMaterialChoices() {
        for count in [0, 1, 3, 5] {
            XCTAssertTrue(WorkDeskComposerPolicy.materialsExpanded(total: count, preference: nil))
        }
        XCTAssertFalse(WorkDeskComposerPolicy.materialsExpanded(total: 6, preference: nil))
        XCTAssertFalse(WorkDeskComposerPolicy.materialsExpanded(total: 150, preference: nil))
    }

    func testChosenDisclosureStateWinsOverLaterArrivalsAndRemovals() {
        XCTAssertTrue(WorkDeskComposerPolicy.materialsExpanded(total: 150, preference: true))
        XCTAssertFalse(WorkDeskComposerPolicy.materialsExpanded(total: 0, preference: false))
        XCTAssertFalse(WorkDeskComposerPolicy.materialsExpanded(total: 3, preference: false))
    }

    func testFittedSheetContractsAndKeepsLongContentScrollable() {
        let short = WorkDeskComposerPolicy.sheetHeight(content: 250, header: 90, footer: 76)
        let long = WorkDeskComposerPolicy.sheetHeight(content: 2_000, header: 90, footer: 76)
        XCTAssertEqual(short, 416)
        XCTAssertEqual(long, WorkDeskComposerPolicy.maximumSheetHeight)
        // Larger accessibility chrome reduces the body's visible area instead
        // of growing the sheet off the display.
        XCTAssertEqual(WorkDeskComposerPolicy.sheetHeight(content: 2_000, header: 200, footer: 130), long)
    }

    func testGatewayAndBothActionsHaveExplicitLayoutOwners() throws {
        let path = "Conduck/Views/Workboard/WorkDeskBriefView.swift"
        let source = try RefusalLaneSource.source(at: path)
        let body = try RefusalLaneSource.trailingClosure(after: "var body: some View", in: source, path: path)
        let header = try RefusalLaneSource.trailingClosure(after: "private var header: some View", in: source, path: path)
        let footer = try RefusalLaneSource.trailingClosure(after: "private var footer: some View", in: source, path: path)
        XCTAssertTrue(body.contains("header"))
        XCTAssertTrue(header.contains("WorkDeskGatewayHeader(draft: draft)"))
        XCTAssertFalse(source.contains("ToolbarItem(placement: .principal)"), "A sheet may omit the principal toolbar slot.")
        XCTAssertFalse(source.contains("ToolbarItem(placement: .cancellationAction)"), "Close belongs alongside Review, never a second native action strip.")
        XCTAssertTrue(footer.contains("workdesk-handoff-close"))
        XCTAssertTrue(footer.contains("workdesk-handoff-review"))
        XCTAssertTrue(footer.contains("workdesk-handoff-back"))
        XCTAssertTrue(footer.contains("workdesk-handoff-send"))
    }

    func testMultilineTaskHasNoSendOnReturnAndReviewReadsFrozenPacket() throws {
        let path = "Conduck/Views/Workboard/WorkDeskBriefView.swift"
        let source = try RefusalLaneSource.source(at: path)
        let editor = try RefusalLaneSource.trailingClosure(after: "private var instructionEditor: some View", in: source, path: path)
        let review = try RefusalLaneSource.body(ofFunction: "review", in: source, path: path)
        XCTAssertTrue(editor.contains("axis: .vertical"))
        XCTAssertTrue(editor.contains(".textFieldStyle(.plain)"))
        XCTAssertFalse(editor.contains(".onSubmit"))
        XCTAssertFalse(source.contains(".keyboardShortcut(.defaultAction)"))
        XCTAssertTrue(source.contains(".scrollDismissesKeyboard(.interactively)"))
        for field in ["packet.task", "packet.projectContext", "packet.materials", "packet.prompt"] {
            XCTAssertTrue(review.contains(field))
        }
        XCTAssertFalse(review.contains("draft.brief"))
        XCTAssertFalse(review.contains("draft.projectContext"))
        XCTAssertFalse(review.contains("requestMaterials"))
    }
}
