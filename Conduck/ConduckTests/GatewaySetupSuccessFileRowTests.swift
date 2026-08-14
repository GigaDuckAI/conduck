// SPDX-License-Identifier: Apache-2.0

// Conduck
// GatewaySetupSuccessFileRowTests.swift
//
// The guided setup's final screen must tell the SAME story about a file lane that
// the gateway editor and the File transfer page tell.
//
// THE BUG IT EXISTS FOR. That screen derived its file row from
// `isFileTransferAvailable` — a Bool — while the question has three answers. A lane
// whose server accepts writes and reads and implements no directory listing (plain
// nginx with `dav_methods PUT DELETE`, a large ordinary population) PASSES the staged
// test and is therefore available, so the Bool said "on" and the user finished setup
// looking at an unqualified success for a capability they have exactly half of. The
// two other surfaces showed the amber "Uploads only" for the very same gateway at the
// very same moment. `.readyUploadsOnly` exists so that no surface has to remember to
// ask the second question, and its own doc comment names this screen as one of the
// three it keeps honest.
//
// The assertions are on the pure status→row mapping rather than on `body`, because
// the mapping is the whole of the defect and a `View`'s body is the one place it
// cannot be read back.
//
// Deterministic + headless: no view is instantiated, nothing is stored, nothing is
// probed.

import XCTest
@testable import Conduck

final class GatewaySetupSuccessFileRowTests: XCTestCase {

    private func text(_ status: GatewayFileLaneStatus) -> String {
        String(localized: GatewaySetupSuccessView.fileRowText(status))
    }

    // MARK: - The three answers

    func testAFullyProvenLaneReadsOn() {
        XCTAssertEqual(text(.ready), "File transfer · On")
        XCTAssertEqual(GatewaySetupSuccessView.fileRowIcon(.ready), "folder.fill")
        XCTAssertEqual(GatewaySetupSuccessView.fileRowTint(.ready), AppColors.textSecondary,
                       "The screen already carries a hero checkmark; a second green element would compete with it.")
    }

    /// THE REGRESSION. Amber, and the word "only" — never the unqualified success
    /// the Bool used to produce here.
    func testAnUploadOnlyLaneIsQualifiedRatherThanCelebrated() {
        XCTAssertEqual(text(.readyUploadsOnly), "File transfer · Uploads only")
        XCTAssertNotEqual(text(.readyUploadsOnly), text(.ready),
                          "A half lane and a whole lane must never render the same sentence.")
        XCTAssertEqual(GatewaySetupSuccessView.fileRowTint(.readyUploadsOnly), AppColors.warning,
                       "Amber is what the editor's badge and the File transfer page use for this state; three surfaces, one colour.")
        XCTAssertEqual(GatewaySetupSuccessView.fileRowIcon(.readyUploadsOnly), "exclamationmark.triangle.fill",
                       "A folder glyph of any fill would read as one of the two settled answers.")
    }

    /// Everything that is not a passing lane reads Off. The screen reports; it does
    /// not diagnose — the File transfer page one tap away does that.
    func testEveryUnprovenLaneReadsOff() {
        for status: GatewayFileLaneStatus in [.needsAttention, .saved, .recommended, .optional] {
            XCTAssertEqual(text(status), "File transfer · Off",
                           "\(status) has not proved the lane, so the summary must not imply it has.")
            XCTAssertEqual(GatewaySetupSuccessView.fileRowTint(status), AppColors.textSecondary)
        }
    }

    // MARK: - The row that is not drawn at all

    /// `.unsupported` is the hosted model, which has no file lane to report. The
    /// screen omits the row rather than claiming a state — so the mapping's answer
    /// for it is never rendered, and is asserted here only to keep the switch
    /// total and its answer non-committal if it ever is.
    func testAnUnsupportedLaneNeverClaimsReadiness() {
        XCTAssertNotEqual(text(.unsupported), text(.ready),
                          "The row is dropped for `.unsupported`; if that ever changes it must not arrive claiming a lane exists.")
    }
}
