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
            defaultValue: "Conduck couldn't confirm a fresh folder on your file server for this message, so it never told the agent where to put files and nothing could come back with the reply. Anything the agent wrote went to its own working folder — if the reply names a file, you can search for it. Check your file server, then send again."))
    }

    /// The read-FAULT row's body, which sits one branch away in the same view and
    /// is drawn for a listing that could not be read at all. Pinned here rather
    /// than left unpinned because it is under the same obligation as the copy
    /// above and had the same class of defect — a sentence about a state the row
    /// cannot know.
    private var faultBody: String {
        String(localized: LocalizedStringResource(
            "thread.outputs.fault.body",
            defaultValue: "Conduck couldn't check whether this reply returned any files. It only ever reads that folder, so anything your agent put there is untouched."))
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

    // MARK: - The copy claims nothing about the AGENT's side of the wire

    /// A SECOND falseness, and a subtler one than the cause claims above: the row
    /// covers turns where the agent was never given a folder, which is not the
    /// same as the agent having been unable to write. An agent handed no outbox
    /// line writes wherever it normally writes — its own working directory — and
    /// the file is sitting there. Copy that says otherwise tells a user their
    /// work was destroyed when it was merely somewhere else, and it contradicts
    /// the *Search mentioned files* button drawn directly beside it, whose entire
    /// premise is that the file may exist under a name the reply mentions.
    func testTheBodyDoesNotClaimTheAgentCouldNotWrite() {
        for claim in ["nowhere to put", "nowhere to write", "nowhere to save",
                      "couldn't write", "could not write", "wasn't written", "was not written"] {
            XCTAssertFalse(
                body.lowercased().contains(claim),
                "The body must not assert \"\(claim)\": Conduck withheld a destination, it did not stop the agent from writing, and the search button beside this row exists because the file may well be on the server already.")
        }
    }

    /// And the positive obligation the claim above leaves behind: having declined
    /// to say the file is gone, the copy has to say where it actually is, or the
    /// button beside the row is an offer with no stated reason to accept it.
    func testTheBodyPointsAtWhereTheFileActuallyIs() {
        XCTAssertTrue(body.lowercased().contains("working folder"),
                      "The one place the file can be is the agent's own working folder; naming it is what makes the search offer legible.")
    }

    // MARK: - The read-fault row makes no claim about a folder it could not read

    /// The fault row is drawn precisely when the LISTING FAILED, so at the moment
    /// it renders the app knows nothing about the folder — not that it exists,
    /// not that it holds anything, not that it survived. A reassurance phrased as
    /// a fact about the folder ("the folder is still on your server") is a claim
    /// the failing pass had no way to establish, and it is false outright for the
    /// population where no folder was ever created.
    ///
    /// What the row MAY say is a fact about CONDUCK, which is true regardless of
    /// what the server did: this lane only ever reads.
    func testTheFaultBodyAssertsNothingAboutTheFolderItFailedToRead() {
        for claim in ["nothing is lost", "still on your server", "is still there",
                      "the folder is still", "your files are safe"] {
            XCTAssertFalse(
                faultBody.lowercased().contains(claim),
                "The fault row must not assert \"\(claim)\": the pass that drew it could not read the folder, so it cannot report on the folder's state.")
        }
        XCTAssertTrue(faultBody.lowercased().contains("reads"),
                      "The reassurance has to rest on what Conduck does — read-only access — which is knowable from inside the app and true on every path that draws this row.")
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

    /// The only genuinely silent answers are the two no status line can produce,
    /// so neither can ever be inferred from what the row has in hand.
    func testTheSilentAnswerIsUnreachableToTheClassifier() {
        for status in [200, 207, 301, 401, 403, 404, 405, 429, 500, 502, 504] {
            XCTAssertNotEqual(
                FileServerClient.classifyAbsenceWitness(status: status), .unreachable,
                "`.unreachable` describes the ABSENCE of a status line; a status \(status) can never mean it.")
            XCTAssertNotEqual(
                FileServerClient.classifyAbsenceWitness(status: status), .noObservation,
                "`.noObservation` describes a request that never asked; a status \(status) proves one did.")
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
    /// fault, and a witness that never reached the lane at all (an offline device,
    /// our own cancellation) proved nothing the copy could truthfully report; the
    /// copy above is never shown for any of them.
    func testTheSilentOutcomesDrawNoRow() {
        for outcome: BackgroundFileTransfer.OutboxMintOutcome in [
            .noLane, .laneCannotReturn, .noObservation
        ] {
            XCTAssertFalse(outcome.isActionableFault,
                           "\(outcome) is a standing configuration the settings screen states plainly, or a request this device never really made — a per-turn complaint about either is the noise this row was rebuilt to avoid.")
        }
        XCTAssertFalse(BackgroundFileTransfer.OutboxMintOutcome.named("conv/out-box").isActionableFault,
                       "A turn that got its folder has nothing to report.")
    }
}
