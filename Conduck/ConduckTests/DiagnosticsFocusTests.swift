// Conduck
// DiagnosticsFocusTests.swift
//
// Coverage for `DiagnosticsFocus.init?` — the ONE filter that decides whether a
// "Troubleshoot" affordance appears. It returns nil for a nil code (a plain
// notice, e.g. a dropped attachment) and for any code whose reconstructed
// `AppError.isTroubleshootable == false`; otherwise it preserves the code + ref
// verbatim. Every error surface builds its focus through this init, so the
// "when does Troubleshoot show?" rule lives in exactly one place — pin it here.

import XCTest
@testable import Conduck

final class DiagnosticsFocusTests: XCTestCase {

    // MARK: - nil outcomes (no Troubleshoot affordance)

    func testNilErrorCodeYieldsNil() {
        // A plain notice with no error code (e.g. a dropped attachment) has
        // nothing to troubleshoot.
        XCTAssertNil(DiagnosticsFocus(errorCode: nil, ref: nil),
                     "A nil errorCode must produce no focus — there is nothing to troubleshoot.")
    }

    func testDenyListCodesYieldNil() {
        // Each reconstructs (via `AppError.from`) to a deny-list case, so the
        // failable init must reject it. Codes named alongside their case so a
        // renumbering that broke the mapping is obvious.
        let denyCodes: [(name: String, code: Int)] = [
            ("audioTooLarge",             AppError.audioTooLarge.errorCode),            // 22
            ("remoteAgentImageTooLarge",  AppError.remoteAgentImageTooLarge.errorCode), // 33
            ("remoteAgentContextTooLong", AppError.remoteAgentContextTooLong.errorCode),// 56
            ("audioMicBusy",              AppError.audioMicBusy.errorCode),             // 53
        ]
        for kase in denyCodes {
            XCTAssertNil(DiagnosticsFocus(errorCode: kase.code, ref: nil),
                         "Deny-list code \(kase.code) (\(kase.name)) must produce no focus.")
        }
    }

    // MARK: - non-nil outcome (Troubleshoot shows, fields preserved)

    func testTroubleshootableCodePreservesFields() {
        // 19 = remoteAgentUnreachable — an environmental failure Diagnostics can
        // reason about. The focus must survive AND carry the code + ref verbatim
        // so the screen opens focused on the right gateway.
        let focus = DiagnosticsFocus(errorCode: 19, ref: .builtin(.openclaw))
        XCTAssertNotNil(focus, "A troubleshootable code must produce a focus.")
        XCTAssertEqual(focus?.errorCode, 19,
                       "The focus must preserve the originating error code verbatim.")
        XCTAssertEqual(focus?.ref, .builtin(.openclaw),
                       "The focus must preserve the gateway ref verbatim so the screen focuses the right row.")
    }

    func testTroubleshootableCodeWithNilRefStillFocuses() {
        // A ref is optional — a headless/non-gateway failure still opens a focused
        // card (title falls back to "Last request"), so a nil ref must NOT block it.
        let focus = DiagnosticsFocus(errorCode: 19, ref: nil)
        XCTAssertNotNil(focus, "A troubleshootable code with no ref must still produce a focus.")
        XCTAssertEqual(focus?.errorCode, 19)
        XCTAssertNil(focus?.ref)
    }
}
