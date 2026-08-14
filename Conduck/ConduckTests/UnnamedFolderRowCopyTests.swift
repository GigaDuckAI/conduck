// SPDX-License-Identifier: Apache-2.0

// Conduck
// UnnamedFolderRowCopyTests.swift
//
// What the thread's folder-less row is ALLOWED TO SAY. `UnnamedOutputFolderRowTests`
// locks WHICH turns get the row; this file locks the one property of its copy that
// the selection rule cannot enforce — that every sentence on it is true of every
// outcome that can put it there.
//
// THE BUG IT EXISTS FOR. The row was titled "Your file server didn't answer" and was
// shown for every witness failure. Two of the three failing answers are cases where
// the server demonstrably DID answer: `.occupied` (a `2xx` claiming the freshly
// minted path is taken, or a `207` whose body does not say otherwise — a namespace
// that answers everything, or an answer nobody could read) and `.indeterminate` (a
// rejected credential, a `5xx`, a redirect). A fourth population never issued a
// request at all: the turns dispatched while the witness breaker's cooldown was open.
// So the title was false three ways, and its particular falseness was expensive — it
// sent a user whose server is responding perfectly off to debug reachability.
//
// The compliant multistatus miss is NOT among these populations, and that matters to
// the copy's scope rather than to its rule. A host that answers a PROPFIND of a
// nonexistent collection with an outer `207` whose inner response-level status is
// `404` is saying "not there" in the second form RFC 4918 allows, and
// `FileServerClient.classifyAbsenceWitness` reads it as `.absent` — that turn gets its
// folder and draws no row at all.
//
// THE RULE THE COPY NOW FOLLOWS is the one the neighbouring "Couldn't finish the
// check just now." already followed: when the causes are indistinguishable at the
// point of rendering, name NONE of them and say only what is true of all of them.
// The row is selected from a LANE-WIDE failure streak, so the outcome of any single
// turn is not available where the row is drawn — which is what makes the rule a
// correctness constraint here rather than a matter of taste.
//
// Deterministic + headless: pure string and taxonomy assertions. No network, no
// store, no clock. Synthetic fixtures only.

import XCTest
@testable import Conduck

final class UnnamedFolderRowCopyTests: XCTestCase {

    // MARK: - Fixtures

    // Resolved exactly the way `ConversationThreadView` resolves them, so a reword
    // in the view lands here as a failing assertion rather than as silent drift.

    private var title: String {
        String(localized: LocalizedStringResource(
            "thread.outputs.noFolder.title",
            defaultValue: "No folder for this reply"))
    }

    private var body: String {
        String(localized: LocalizedStringResource(
            "thread.outputs.noFolder.body",
            defaultValue: "Conduck couldn't confirm a fresh folder on your file server for this message, so the agent had nowhere to put files and nothing could come back with the reply. Check your file server, then send again."))
    }

    /// Phrases that pick ONE of the four causes. Each is false for at least one
    /// population the row covers, and the row cannot tell which population a given
    /// turn belongs to.
    private static let causeClaims = [
        "didn't answer", "did not answer", "no answer", "not answering",
        "unreachable", "can't be reached", "cannot be reached",
        "offline", "is down", "timed out", "no response"
    ]

    // MARK: - The copy claims no cause

    func testTitleNamesNoCause() {
        for claim in Self.causeClaims {
            XCTAssertFalse(
                title.lowercased().contains(claim),
                "The title must not assert \"\(claim)\": a server that answered `207` for the minted path, or `401`, or one that was never asked because the breaker was open, all draw this same row.")
        }
    }

    func testBodyNamesNoCause() {
        for claim in Self.causeClaims {
            XCTAssertFalse(
                body.lowercased().contains(claim),
                "The body must not assert \"\(claim)\" for the same reason the title must not.")
        }
    }

    /// What the copy is still obliged to do: state the consequence and point at the
    /// one place the user can act. A row that named no cause AND offered no remedy
    /// would have solved the honesty problem by saying nothing.
    func testCopyStillStatesTheConsequenceAndTheRemedy() {
        XCTAssertTrue(body.lowercased().contains("nothing could come back"),
                      "The user has to be told the reply could not carry files — that is the whole reason the row is drawn.")
        XCTAssertTrue(body.lowercased().contains("file server"),
                      "The remedy is on the file server (or the setup screen behind it), and it is the same remedy for all four causes.")
    }

    // MARK: - Why the copy cannot name a cause (the taxonomy premise)

    /// The premise, asserted rather than asserted-in-a-comment: two of the three
    /// witness answers that fail the freshness check describe a server that
    /// ANSWERED. This is not a re-test of the classifier's rules — it is the fact
    /// the copy above is written around, and it must fail here if it ever changes.
    func testTwoOfTheThreeFailingWitnessAnswersMeanTheServerAnswered() {
        XCTAssertEqual(
            FileServerClient.classifyAbsenceWitness(status: 207), .occupied,
            "A multistatus that does not say 'not there' is the server answering, clearly and on the record.")
        XCTAssertEqual(
            FileServerClient.classifyAbsenceWitness(status: 200), .occupied,
            "So is any other 2xx — a wall that answers everything is still answering.")
        XCTAssertEqual(
            FileServerClient.classifyAbsenceWitness(status: 401), .indeterminate,
            "A rejected credential is an answer; what it settles is nothing.")
        XCTAssertEqual(
            FileServerClient.classifyAbsenceWitness(status: 502), .indeterminate,
            "So is a bad gateway from a reverse proxy.")
    }

    /// The only genuinely silent answer is the one no status line can produce, so
    /// it can never be inferred from what the row has in hand.
    func testTheSilentAnswerIsUnreachableToTheClassifier() {
        for status in [200, 207, 301, 401, 403, 404, 405, 429, 500, 502, 504] {
            XCTAssertNotEqual(
                FileServerClient.classifyAbsenceWitness(status: status), .unreachable,
                "`.unreachable` describes the ABSENCE of a status line; a status \(status) can never mean it.")
        }
    }

    /// The fourth population, and the one that rules out any copy phrased as "we
    /// asked and…": a suppressed turn spent no request at all, and still goes out
    /// folder-less, and still draws the row.
    func testASuppressedTurnIsSurfacedWithoutAnyRequestHavingBeenMade() {
        let suppressed = BackgroundFileTransfer.OutboxMintOutcome.witnessSuppressed
        XCTAssertNil(suppressed.key,
                     "No folder on the wire — the fact the copy is allowed to state.")
        XCTAssertTrue(suppressed.isActionableFault,
                      "It draws the row, so the copy has to be true of a turn where nothing was asked of the server.")
    }

    /// And the outcomes that stay SILENT must not be dragged into the row's story:
    /// a lane that cannot list — structurally, or because it has proved it claims
    /// every fresh name — is a standing property of the user's own server, not a
    /// fault, so the copy above is never shown for it.
    func testTheSilentOutcomesDrawNoRow() {
        for outcome: BackgroundFileTransfer.OutboxMintOutcome in [.noLane, .laneCannotReturn] {
            XCTAssertFalse(outcome.isActionableFault,
                           "\(outcome) is a standing configuration the settings screen states plainly — a per-turn complaint about it is the noise this row was rebuilt to avoid.")
        }
        XCTAssertFalse(BackgroundFileTransfer.OutboxMintOutcome.named("conv/out-box").isActionableFault,
                       "A turn that got its folder has nothing to report.")
    }
}
