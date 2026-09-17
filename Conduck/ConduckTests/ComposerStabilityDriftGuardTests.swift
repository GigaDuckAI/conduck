// SPDX-License-Identifier: Apache-2.0

// Conduck
// ComposerStabilityDriftGuardTests.swift
//
// Structural guard for the iPhone/iPad composer's stability invariants — the
// ones that keep the docked bar from flickering and that a view-rendering test
// cannot pin cheaply: the trailing control is resolved in ONE place, the send
// hold is raised before the host learns of acceptance and released on every
// path, the captured-intent contract survives, the capture slot keeps its two
// heights, the subdued send fades in a reserved slot, and the shared disc
// keeps the single-Button / single-Image identity its glyph morph needs.
//
// Assertions are scoped to the declaration they are about and compared on
// whitespace-normalized text, so an ordinary reformat does not trip them and
// a matching expression elsewhere in the file cannot satisfy them.

import XCTest
@testable import Conduck

final class ComposerStabilityDriftGuardTests: XCTestCase {
    private static let bar = "Conduck/Views/Conversation/iOSMessageComposerBar.swift"
    private static let disc = "Conduck/Views/Conversation/CaptureCircleButton.swift"
    private static let viewModel = "Conduck/ViewModels/ConversationDetailViewModel.swift"
    private static let macBar = "Conduck/Views/Conversation/MessageComposerBar.swift"

    // MARK: - Helpers

    /// Runs of whitespace (including newlines) collapsed to one space, so a
    /// multi-line spelling of the same statement still matches.
    private func normalized(_ source: String) -> String {
        source.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// The brace-matched body that follows the first occurrence of `declaration`
    /// (a `var …: Type {` or `func …(` head), so an assertion is scoped to ONE
    /// declaration rather than the whole file.
    private func body(after declaration: String, in source: String) throws -> String {
        let head = try XCTUnwrap(source.range(of: declaration), "no `\(declaration)` declaration")
        let opening = try XCTUnwrap(source.range(of: "{", range: head.upperBound..<source.endIndex))
        var index = opening.upperBound
        let start = index
        var depth = 1
        while index < source.endIndex, depth > 0 {
            if source[index] == "{" { depth += 1 }
            if source[index] == "}" { depth -= 1 }
            index = source.index(after: index)
        }
        return String(source[start..<index])
    }

    // MARK: - Tests

    func testTheBarResolvesItsTrailingControlInOnePlace() throws {
        let bar = try RefusalLaneSource.source(at: Self.bar)
        XCTAssertTrue(bar.contains("ComposerTrailingControlResolver.resolve("))
        // The iPad card's PERSISTENT mic keeps its own small ladder by design
        // (it is a separate control, not the morph); the trailing ladder is gone.
        let flat = normalized(bar)
        XCTAssertEqual(flat.components(separatedBy: "case .recording: return \"stop.fill\"").count - 1, 1,
                       "only the regular layout's persistent mic resolves a glyph by hand")
        XCTAssertFalse(flat.contains("if isInFlight { return \"stop.fill\" }"),
                       "a second hand-rolled trailing ladder would drift from the resolver")
        XCTAssertFalse(bar.contains("showsSendControl"))
        XCTAssertFalse(bar.contains("animatesSymbol:"), "the glyph carries the replace transition and nothing else")
    }

    func testTheSendGateStillCoversEveryTermIncludingTheHold() throws {
        let bar = try RefusalLaneSource.source(at: Self.bar)
        let gate = normalized(try body(after: "var isSendDisabled: Bool", in: bar))
        for term in ["sendSubmissionInProgress", "viewModel?.isPreparingLiveTurn == true", "captureActive",
                     "hasLoadingAttachment", "hasBlockingUpload", "attachmentPreparationInProgress"] {
            XCTAssertTrue(gate.contains(term), "isSendDisabled lost `\(term)`")
        }
        let hold = normalized(try body(after: "var isSubmitting: Bool", in: bar))
        XCTAssertTrue(hold.contains("sendSubmissionInProgress || viewModel?.isPreparingLiveTurn == true"),
                      "the hold spans the bar's own submission window AND the VM's accepted-but-not-live window")
    }

    func testTheHoldIsRaisedBeforeAcceptanceAndReleasedOnEveryPath() throws {
        let source = normalized(try RefusalLaneSource.source(at: Self.viewModel))
        let raised = try XCTUnwrap(source.range(of: "isPreparingLiveTurn = true"))
        let accepted = try XCTUnwrap(source.range(of: "onLocalAcceptance?(true)"))
        XCTAssertLessThan(raised.lowerBound, accepted.lowerBound,
                          "the host clears the draft on acceptance; the hold must already be up")
        let released = try XCTUnwrap(source.range(of: "defer { isPreparingLiveTurn = false }"))
        XCTAssertLessThan(raised.upperBound, released.lowerBound)
        XCTAssertLessThan(released.upperBound, accepted.lowerBound,
                          "the defer is armed before acceptance so the pre-dispatch refusal cannot strand the hold")

        let begin = try body(after: "func beginInFlight(", in: source)
        XCTAssertTrue(begin.contains("isPreparingLiveTurn = false"), "going live hands the hold to the Stop control")
        let end = try body(after: "func endInFlight(", in: source)
        XCTAssertTrue(end.contains("isPreparingLiveTurn = false"))

        // NOT a Stop claim and NOT the wait indicator: the hold must never feed
        // the cancel gate or the thread's "a turn is live here" row.
        let canStop = try body(after: "var canStopLiveTurn: Bool", in: source)
        XCTAssertFalse(canStop.contains("isPreparingLiveTurn"))
        let wait = try body(after: "var showsGatewayWaitIndicator: Bool", in: source)
        XCTAssertFalse(wait.contains("isPreparingLiveTurn"))
    }

    func testTheCapturedIntentContractSurvives() throws {
        let bar = normalized(try RefusalLaneSource.source(at: Self.bar))
        XCTAssertTrue(bar.contains("let intent = trailingIntent(for: control)"))
        XCTAssertTrue(bar.contains("case .stop(let token): viewModel?.cancelInFlight(expecting: token)"))
        XCTAssertFalse(bar.contains("cancelInFlight(expecting: viewModel?.inFlightTurnToken)"),
                       "re-reading the token at action time is the late-tap hazard the capture exists to prevent")
        XCTAssertTrue(bar.contains("case .none: return nil"), "the held send carries no intent")
    }

    func testTheCaptureSlotKeepsItsTwoHeights() throws {
        let bar = try RefusalLaneSource.source(at: Self.bar)
        let slot = normalized(try body(after: "private var captureStatusBanner: some View", in: bar))
        let occupants = slot.components(separatedBy: "minHeight: captureSlotHeight, maxHeight: captureSlotHeight").count - 1
        XCTAssertEqual(occupants, 3, "recording, transcribing and preparing voice share one box")
        XCTAssertTrue(bar.contains("@ScaledMetric(relativeTo: .body) private var captureSlotHeight = Constants.composerCaptureSlotHeight"),
                      "the slot height scales with Dynamic Type like the rows it holds")
        let phase = normalized(try body(after: "private var captureBannerPhase: Int", in: bar))
        XCTAssertTrue(phase.contains("case .error: return 4"), "the capture error rides the same phase-keyed transaction")
        XCTAssertTrue(slot.contains(".opacity(showSlowTranscribeHint ? 1 : 0)"),
                      "the stall hint is a reserved line, never a new row")
        XCTAssertFalse(slot.contains("if showSlowTranscribeHint {"))
    }

    func testTheSubduedSendFadesInAReservedSlot() throws {
        let bar = try RefusalLaneSource.source(at: Self.bar)
        let slot = normalized(try body(after: "private var subduedSendButton: some View", in: bar))
        XCTAssertTrue(slot.hasPrefix(" if hasAttachments {") || slot.hasPrefix("if hasAttachments {"),
                      "the slot exists whenever attachments are staged")
        XCTAssertTrue(slot.contains(".opacity(showsSubduedSend ? 1 : 0)"))
        XCTAssertTrue(slot.contains(".allowsHitTesting(showsSubduedSend)"))
        XCTAssertTrue(slot.contains(".accessibilityHidden(!showsSubduedSend)"))
        XCTAssertFalse(slot.contains("if showsSubduedSend {"), "inserting the disc on the first keystroke moved the field")
    }

    func testTheDiscKeepsTheIdentityItsMorphNeeds() throws {
        let disc = try RefusalLaneSource.source(at: Self.disc)
        XCTAssertEqual(disc.components(separatedBy: "Button(action:").count - 1, 1)
        XCTAssertEqual(disc.components(separatedBy: "Image(systemName:").count - 1, 1)
        XCTAssertTrue(disc.contains(".contentTransition(.symbolEffect(.replace))"))
        XCTAssertFalse(disc.contains(".symbolEffect(.pulse"), "a second symbol effect on the same Image contends with the morph")
        XCTAssertFalse(disc.contains("repeatForever"), "the halo owns its clock via phaseAnimator")
        let mac = try RefusalLaneSource.source(at: Self.macBar)
        XCTAssertFalse(mac.contains("animatesSymbol:"))
    }
}
