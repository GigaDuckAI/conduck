// SPDX-License-Identifier: Apache-2.0

// Conduck
// AttachmentDeliveryPlannerTests.swift
//
// The pure route planner for TEXT/code attachments. Full route matrix:
// small/large × server/no-server × within/over budget. Asserts the EXACT
// `{inline, serverCopy}` decision the composer + drainer act on. The planner is
// the single source of truth so the picker / entry point never decides
// semantics — these tests lock that contract.

import XCTest
@testable import Conduck

final class AttachmentDeliveryPlannerTests: XCTestCase {

    private let small = Constants.textInlineMaxBytes - 1
    private let atThreshold = Constants.textInlineMaxBytes        // ≤ threshold = small
    private let large = Constants.textInlineMaxBytes + 1
    private let fullBudget = Constants.textInlineTurnBudgetBytes

    // MARK: - No file-server → inline-only, never a server copy (no regression)

    func testNoServerSmall_inlineOnly() {
        let plan = AttachmentDeliveryPlanner.plan(
            extractedByteCount: small, fileServerPresent: false, inlineBudgetRemaining: fullBudget)
        XCTAssertEqual(plan, .init(inline: true, serverCopy: .none))
        XCTAssertNil(plan.inlineByteLimit, "regular text is never clamped")
    }

    func testNoServerLarge_inlineOnly() {
        // A server-less gateway inlines ANY size — the inline fence is the only
        // transport, so size is irrelevant (today's behavior, no regression).
        let plan = AttachmentDeliveryPlanner.plan(
            extractedByteCount: large, fileServerPresent: false, inlineBudgetRemaining: fullBudget)
        XCTAssertEqual(plan, .init(inline: true, serverCopy: .none))
        XCTAssertNil(plan.inlineByteLimit,
                     "REGRESSION LOCK: large regular text on a server-less gateway inlines UNLIMITED — only a webpage capture is clamped")
    }

    func testNoServerOverBudget_stillInlineOnly() {
        let plan = AttachmentDeliveryPlanner.plan(
            extractedByteCount: small, fileServerPresent: false, inlineBudgetRemaining: 0)
        XCTAssertEqual(plan, .init(inline: true, serverCopy: .none))
        XCTAssertNil(plan.inlineByteLimit, "regular text is never clamped")
    }

    // MARK: - Server + small + fits budget → DUAL (inline + preferred upload)

    func testServerSmallWithinBudget_dual() {
        let plan = AttachmentDeliveryPlanner.plan(
            extractedByteCount: small, fileServerPresent: true, inlineBudgetRemaining: fullBudget)
        XCTAssertEqual(plan, .init(inline: true, serverCopy: .preferred))
    }

    func testServerAtThresholdWithinBudget_dual() {
        // Exactly at the threshold counts as small (≤), so still dual.
        let plan = AttachmentDeliveryPlanner.plan(
            extractedByteCount: atThreshold, fileServerPresent: true, inlineBudgetRemaining: fullBudget)
        XCTAssertEqual(plan, .init(inline: true, serverCopy: .preferred))
    }

    func testServerSmallExactlyFitsRemainingBudget_dual() {
        // extracted == remaining budget → still fits (inline allowed).
        let plan = AttachmentDeliveryPlanner.plan(
            extractedByteCount: small, fileServerPresent: true, inlineBudgetRemaining: small)
        XCTAssertEqual(plan, .init(inline: true, serverCopy: .preferred))
    }

    // MARK: - Server + large → file-only (required, gates Send)

    func testServerLarge_fileOnlyRequired() {
        let plan = AttachmentDeliveryPlanner.plan(
            extractedByteCount: large, fileServerPresent: true, inlineBudgetRemaining: fullBudget)
        XCTAssertEqual(plan, .init(inline: false, serverCopy: .required))
    }

    func testServerLarge_requiredEvenWithZeroBudget() {
        // Size dominates: a large file is `.required` regardless of budget.
        let plan = AttachmentDeliveryPlanner.plan(
            extractedByteCount: large, fileServerPresent: true, inlineBudgetRemaining: 0)
        XCTAssertEqual(plan, .init(inline: false, serverCopy: .required))
    }

    // MARK: - Server + small + OVER budget → uploaded but inline suppressed

    func testServerSmallOverBudget_preferredButSuppressed() {
        // Small enough to inline, but the turn's inline budget is already spent →
        // suppress the inline copy on the wire (the upload still happens so the
        // agent's tools reach it), serverCopy stays `.preferred` (never gates).
        let plan = AttachmentDeliveryPlanner.plan(
            extractedByteCount: small, fileServerPresent: true, inlineBudgetRemaining: 0)
        XCTAssertEqual(plan, .init(inline: false, serverCopy: .preferred))
    }

    func testServerSmallJustOverRemainingBudget_suppressed() {
        // extracted just exceeds the remaining budget by one byte → suppressed.
        let plan = AttachmentDeliveryPlanner.plan(
            extractedByteCount: small, fileServerPresent: true, inlineBudgetRemaining: small - 1)
        XCTAssertEqual(plan, .init(inline: false, serverCopy: .preferred))
    }

    // MARK: - Routing is by EXTRACTED byte count, not raw file size

    func testEmptyTextWithServer_dual() {
        // A 0-byte extraction (empty text) with a server is still dual (inline +
        // preferred) — degenerate but well-defined.
        let plan = AttachmentDeliveryPlanner.plan(
            extractedByteCount: 0, fileServerPresent: true, inlineBudgetRemaining: fullBudget)
        XCTAssertEqual(plan, .init(inline: true, serverCopy: .preferred))
    }

    // MARK: - Inline clamp (`clampInlineWhenServerless`) — applies ONLY when server-less

    func testWebpageNoServer_inlineClampedToTextInlineMax() {
        // The ONE case the flag changes: a Safari capture on a server-less
        // gateway still rides inline-only, but carries the clamp so the drainer
        // cuts it to the 32 KB cap (client-owned history re-sends every turn —
        // an unbounded page would tax the whole conversation).
        let plan = AttachmentDeliveryPlanner.plan(
            extractedByteCount: large, fileServerPresent: false,
            inlineBudgetRemaining: fullBudget, clampInlineWhenServerless: true)
        XCTAssertEqual(plan, .init(inline: true, serverCopy: .none,
                                   inlineByteLimit: Constants.textInlineMaxBytes))
    }

    func testWebpageNoServerSmall_stillCarriesClamp() {
        // The clamp is declared regardless of size (the drainer's cut is a
        // no-op under the cap) — the plan states policy, not measurement.
        let plan = AttachmentDeliveryPlanner.plan(
            extractedByteCount: small, fileServerPresent: false,
            inlineBudgetRemaining: fullBudget, clampInlineWhenServerless: true)
        XCTAssertEqual(plan, .init(inline: true, serverCopy: .none,
                                   inlineByteLimit: Constants.textInlineMaxBytes))
    }

    func testWebpageServerSmall_dualNoClamp() {
        // With a file server a capture routes EXACTLY like regular text: dual,
        // no clamp (the real bytes live on the server for the agent's tools).
        let plan = AttachmentDeliveryPlanner.plan(
            extractedByteCount: small, fileServerPresent: true,
            inlineBudgetRemaining: fullBudget, clampInlineWhenServerless: true)
        XCTAssertEqual(plan, .init(inline: true, serverCopy: .preferred))
        XCTAssertNil(plan.inlineByteLimit)
    }

    func testWebpageServerLarge_fileOnlyNoClamp() {
        let plan = AttachmentDeliveryPlanner.plan(
            extractedByteCount: large, fileServerPresent: true,
            inlineBudgetRemaining: fullBudget, clampInlineWhenServerless: true)
        XCTAssertEqual(plan, .init(inline: false, serverCopy: .required))
        XCTAssertNil(plan.inlineByteLimit)
    }
}
