// SPDX-License-Identifier: Apache-2.0

// Conduck
// PairingFileStageCaveatTests.swift
//
// The pairing wizard's file stage must grade an upload-only lane as a PASS and still
// say what the lane cannot do.
//
// THE TWO WRONG ANSWERS, and why the stage needs a third. Grading it FAILED tells a
// user whose import worked that it did not, and offers a "Try again" that cannot
// reach a different answer — the server named `PROPFIND` as a method it does not
// perform, which is a structural refusal a retry re-earns verbatim. Grading it an
// unqualified PASS draws a green tick over a lane that will never return a file, on
// the one screen the user is looking at while they decide setup is done. So the
// verdict keeps two axes, exactly as `FileTransferTestResult` does: `passed` reports
// the byte round-trip, `uploadsOnly` reports the direction the server refused.
//
// `PairingImportFlow` folds the second axis into `StageStatus.passed(caveat:)`, which
// is where the sheet reads it. The caveat's STRING is shared by key with the File
// transfer page's own staged checklist so the two checklists a user sees during one
// setup cannot describe the same server in two different ways.
//
// Deterministic + headless: `StubPairingImportEnvironment` (declared in
// `PairingImportFlowTests`) answers every seam locally. No network, no store.

import SwiftUI
import XCTest
@testable import Conduck

@MainActor
final class PairingFileStageCaveatTests: XCTestCase {

    private var env: StubPairingImportEnvironment!

    override func setUp() async throws {
        try await super.setUp()
        env = StubPairingImportEnvironment()
    }

    // MARK: - Fixtures

    /// A code that CARRIES a file-server block, so the flow runs the file stage at
    /// all (`visibleStages` and `runFileStageIfNeeded` both gate on it).
    private func codeWithFileServer() throws -> String {
        let dict: [String: Any] = [
            "v": 1,
            "gateway": ["kind": "openclaw", "url": "https://gw.example.test:18789", "auth": "none"],
            "fileServer": [
                "url": "https://gw.example.test:8443",
                "credential": "feedfacecafebeeffeedfacecafebeef"
            ]
        ]
        return "conduck-setup:v1:" + (try JSONSerialization.data(withJSONObject: dict)).base64EncodedString()
    }

    private func runToDone(_ flow: PairingImportFlow,
                           file: StaticString = #filePath, line: UInt = #line) async throws {
        flow.handleCode(try codeWithFileServer())
        for _ in 0..<500 where flow.phase != .review { await Task.yield() }
        XCTAssertEqual(flow.phase, .review, "the code should have reached the review card",
                       file: file, line: line)
        flow.connect()
        for _ in 0..<500 where flow.phase != .done { await Task.yield() }
        XCTAssertEqual(flow.phase, .done, "the staged run should have finished",
                       file: file, line: line)
    }

    // MARK: - The three verdicts

    /// A lane that proved BOTH directions says nothing extra. The caveat slot is
    /// explicit rather than defaulted so a stage that grows a partial state has to
    /// decide about it; here the decision is "there isn't one".
    func testAFullyProvenLanePassesWithNoCaveat() async throws {
        env.fileTestResult = PairingFileTestResult(
            passed: true, uploadsOnly: false, failureMessage: nil, retryable: true)
        let flow = PairingImportFlow(environment: env)

        try await runToDone(flow)

        XCTAssertEqual(flow.stageStatus[.file], .passed(caveat: nil))
    }

    /// THE REGRESSION. A pass, because every byte this stage exists to prove moved —
    /// and a sentence, because the sheet was the one surface drawing an unqualified
    /// green seal on a server that can only send.
    func testAnUploadOnlyLanePassesAndCarriesTheCaveat() async throws {
        env.fileTestResult = PairingFileTestResult(
            passed: true, uploadsOnly: true, failureMessage: nil, retryable: true)
        let flow = PairingImportFlow(environment: env)

        try await runToDone(flow)

        XCTAssertEqual(flow.stageStatus[.file], .passed(caveat: PairingImportFlow.uploadOnlyCaveat),
                       "The stage must pass AND say which half of the lane the user has.")
        XCTAssertNotEqual(flow.stageStatus[.file], .passed(caveat: nil),
                          "An unqualified pass here is the exact claim the spec forbids every screen reporting on this lane from making.")
    }

    /// The caveat is a STATEMENT, never a failure: nothing about it is retryable and
    /// nothing about it revokes the lane. A red cross here was the other wrong
    /// answer, and it is the one that costs the user their uploads.
    func testTheCaveatIsNotAFailure() async throws {
        env.fileTestResult = PairingFileTestResult(
            passed: true, uploadsOnly: true, failureMessage: nil, retryable: true)
        let flow = PairingImportFlow(environment: env)

        try await runToDone(flow)

        guard case .failed = flow.stageStatus[.file] ?? .pending else { return }
        XCTFail("An upload-only lane works; grading it failed tells a user whose import succeeded that it did not.")
    }

    /// A genuine failure still reads as one, and still carries its taxonomy.
    func testARealFailureIsUnaffected() async throws {
        env.fileTestResult = PairingFileTestResult(
            passed: false, uploadsOnly: false,
            failureMessage: "Couldn't reach the file server.", retryable: false)
        let flow = PairingImportFlow(environment: env)

        try await runToDone(flow)

        XCTAssertEqual(flow.stageStatus[.file],
                       .failed("Couldn't reach the file server.", retryable: false))
    }

    // MARK: - The caveat's copy

    /// Shared BY KEY with the File transfer page's staged checklist. Two checklists
    /// describing one server in two different sentences is exactly the drift the
    /// stored-verdict rule exists to prevent, and it would happen inside a single
    /// setup session.
    func testTheCaveatIsTheSameSentenceTheFileTransferChecklistUses() {
        let checklistCopy = String(localized: LocalizedStringResource(
            "fileTransfer.test.stage.listing.unsupported",
            defaultValue: "This server can't list folders. Sending files to the agent works; files the agent creates can't come back on their own."))

        XCTAssertEqual(PairingImportFlow.uploadOnlyCaveat, checklistCopy)
        XCTAssertTrue(PairingImportFlow.uploadOnlyCaveat.lowercased().contains("can't list folders"),
                      "The sentence has to name what the server refused, or the amber state is just an unexplained warning.")
    }

    // MARK: - The other stages

    /// The save and gateway stages have no second axis and must not acquire one by
    /// accident when the file stage does.
    func testTheOtherStagesPassUnqualified() async throws {
        env.fileTestResult = PairingFileTestResult(
            passed: true, uploadsOnly: true, failureMessage: nil, retryable: true)
        let flow = PairingImportFlow(environment: env)

        try await runToDone(flow)

        XCTAssertEqual(flow.stageStatus[.save], .passed(caveat: nil))
        XCTAssertEqual(flow.stageStatus[.gateway], .passed(caveat: nil))
    }

    /// The default is "nothing narrowed" — the polarity every other reader of this
    /// verdict uses, so an older construction site cannot silently invent a caveat.
    func testTheSecondAxisDefaultsToNoCaveat() {
        let result = PairingFileTestResult(passed: true, failureMessage: nil, retryable: true)
        XCTAssertFalse(result.uploadsOnly)
    }

    // MARK: - What the sheet actually draws
    //
    // Carrying the caveat through the flow proves nothing on its own: the sheet
    // read `.passed` without its payload for a whole wave, so the fix was plumbed
    // end to end and the user still saw an unqualified green tick. These assert
    // the RENDERING decision, which is why it lives on the status rather than
    // inside a private view method.

    /// A pass with nothing to report keeps the green tick, and its detail line is
    /// absent rather than empty — an empty string would still reserve the row.
    func testAnUnqualifiedPassDrawsTheGreenTick() {
        let status = PairingImportFlow.StageStatus.passed(caveat: nil)

        XCTAssertEqual(status.glyphSystemImage, "checkmark.circle.fill")
        XCTAssertEqual(status.glyphTint, AppColors.success)
        XCTAssertNil(status.detail)
    }

    /// THE REGRESSION, at the surface the user is looking at. Amber triangle, not
    /// a green tick, and the sentence rendered verbatim.
    func testAPassWithACaveatDrawsTheAmberTriangleAndTheSentence() {
        let status = PairingImportFlow.StageStatus.passed(caveat: PairingImportFlow.uploadOnlyCaveat)

        XCTAssertEqual(status.glyphSystemImage, "exclamationmark.triangle.fill",
                       "A green tick here is the sheet claiming both directions on a server that has one.")
        XCTAssertEqual(status.glyphTint, AppColors.warning)
        XCTAssertEqual(status.detail, PairingImportFlow.uploadOnlyCaveat,
                       "The caveat has to be rendered, not merely carried.")
        XCTAssertNotEqual(status.detailTint, AppColors.error,
                          "A caveat is a statement about the server, not a failure.")
    }

    /// The same amber treatment the File transfer page's checklist uses for the
    /// same fact. The user meets both screens inside one setup, so the two must
    /// not diverge on glyph or tint any more than they do on wording.
    func testTheCaveatTreatmentMatchesTheFileTransferPageBadge() {
        let status = PairingImportFlow.StageStatus.passed(caveat: PairingImportFlow.uploadOnlyCaveat)

        XCTAssertEqual(status.glyphSystemImage, GatewayFileLaneStatus.readyUploadsOnly.systemImage)
        XCTAssertEqual(status.glyphTint, GatewayFileLaneStatus.readyUploadsOnly.tint)
    }

    /// A failure still reads as a failure — red cross, red detail.
    func testAFailureDrawsTheRedCross() {
        let status = PairingImportFlow.StageStatus.failed("Couldn't reach the file server.", retryable: false)

        XCTAssertEqual(status.glyphSystemImage, "xmark.circle.fill")
        XCTAssertEqual(status.glyphTint, AppColors.error)
        XCTAssertEqual(status.detail, "Couldn't reach the file server.")
        XCTAssertEqual(status.detailTint, AppColors.error)
    }

    /// A running stage yields NO symbol, because the sheet puts a spinner in that
    /// slot. A symbol here would draw both.
    func testARunningStageHasNoGlyphSymbol() {
        XCTAssertNil(PairingImportFlow.StageStatus.running.glyphSystemImage)
        XCTAssertEqual(PairingImportFlow.StageStatus.pending.glyphSystemImage, "circle")
    }
}
