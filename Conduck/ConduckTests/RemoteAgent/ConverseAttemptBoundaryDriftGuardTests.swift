// SPDX-License-Identifier: Apache-2.0

// Conduck
// ConverseAttemptBoundaryDriftGuardTests.swift
//
// SOURCE DRIFT GUARD for the four orderings that make the iOS converse lane's
// gateway-attempt ledger honest. Each of them is a property of WHERE a line
// sits, not of what any function returns, so none of them can be reached by a
// behavioural test: the composition they constrain is a background URLSession
// delegate plus an actor save, and the failure they prevent is a row that is
// silently wrong rather than a call that fails.
//
//   1. THE FINAL PRE-TRANSPORT BOUNDARY. Every preparation that can fail —
//      body encode, both task-metadata encodes, the file-lane revalidation —
//      completes BEFORE the ledger row is opened. Move the insert earlier and a
//      lane that moved between capture and dispatch is recorded as a failed
//      GATEWAY attempt, which is exactly the mislabelling the boundary exists to
//      rule out; leave an encode after it and a local failure strands a
//      phantom `inFlight` row nobody will ever close.
//
//   2. ONE RESUME, INSIDE THE CRITICAL SECTION. The Stop claim is read and the
//      task is created, registered and resumed in a single `queue` block. A
//      second `task.resume()` anywhere else, or a claim read separated from the
//      resume by so much as a queue hop, reopens the cancel-before-registration
//      race — the user taps Stop while the awaited insert is in flight and
//      watches the request leave anyway.
//
//   3. EXACT CANCELLATION. `cancel(userMessageID:)` matches the turn, not the
//      thread. Matching on the conversation picks whichever entry the registry
//      iterates to first, so with two overlapping turns it cancels one and
//      attributes the stop to the other — and the ledger's cancel attribution is
//      only ever as exact as the cancel that produced it.
//
//   4. ONE COMPLETION STAMP. `completedAt` is taken at the top of the terminal
//      callback and carried through the awaited store work. A fresh `Date()`
//      taken down inside the landing would fold this app's own persistence into
//      the response time the dashboard reports as the gateway's.
//
// SCOPE. Comment-stripped source read off disk via `#filePath`, the same idiom
// as `ParkedConverseLaneDriftGuardTests` — prose that DISCUSSES a banned
// ordering (this file's own subject files discuss all four at length) never
// trips a case.

import XCTest
@testable import Conduck

final class ConverseAttemptBoundaryDriftGuardTests: XCTestCase {

    // MARK: - Sources

    /// `.../Conduck/Conduck` — the Xcode project container. `#filePath` →
    /// `.../Conduck/Conduck/ConduckTests/RemoteAgent/<thisFile>`.
    private func projectContainerURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // .../ConduckTests/RemoteAgent
            .deletingLastPathComponent()   // .../ConduckTests
            .deletingLastPathComponent()   // .../Conduck/Conduck
    }

    /// Strip Swift comments so an argument AGAINST an ordering is never read as
    /// the ordering. Conservative in the safe direction: a trailing `// note`
    /// after real code keeps the whole line, so nothing can hide behind one.
    private func codeOnly(_ source: String) -> String {
        var out = ""
        var inBlockComment = false
        for line in source.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if inBlockComment {
                if trimmed.contains("*/") { inBlockComment = false }
                continue
            }
            if trimmed.hasPrefix("//") { continue }
            if trimmed.hasPrefix("/*") {
                if !trimmed.contains("*/") { inBlockComment = true }
                continue
            }
            out.append(contentsOf: line)
            out.append("\n")
        }
        return out
    }

    private func backgroundRemoteAgentCode() throws -> String {
        codeOnly(try String(
            contentsOf: projectContainerURL()
                .appendingPathComponent("Conduck/Services/RemoteAgent/BackgroundRemoteAgent.swift"),
            encoding: .utf8
        ))
    }

    /// The source between `start` and the next `end` after it. Fails the test
    /// rather than returning nil, so a renamed anchor is a loud failure instead
    /// of a case that silently stops checking anything.
    private func span(
        of code: String, from start: String, to end: String,
        file: StaticString = #filePath, line: UInt = #line
    ) -> String {
        guard let open = code.range(of: start) else {
            XCTFail("anchor `\(start)` not found — this guard has gone stale", file: file, line: line)
            return ""
        }
        guard let close = code.range(of: end, range: open.upperBound..<code.endIndex) else {
            XCTFail("anchor `\(end)` not found after `\(start)`", file: file, line: line)
            return ""
        }
        return String(code[open.upperBound..<close.lowerBound])
    }

    // MARK: - 1. The final pre-transport boundary

    /// Nothing that can fail may run after the ledger insert. Asserted as a
    /// position: every fallible preparation's LAST occurrence sits above the
    /// insert. The needles are the four things `send` does that can actually
    /// throw — the body write, both metadata encodes, and the two lane
    /// revalidations that refuse a lane which moved.
    func testEveryFalliblePreparationPrecedesTheLedgerInsert() throws {
        let code = try backgroundRemoteAgentCode()
        guard let insert = code.range(of: "beginGatewayAttempt(") else {
            return XCTFail("`beginGatewayAttempt(` not found — the converse lane no longer measures.")
        }
        for needle in [
            "encodedString()",
            ".write(to: bodyURL",
            "mintWitnessedOutboxKey(",
            "fileTransferReadySnapshot(for: ref)",
            "AppError.fileTransferNotConfigured"
        ] {
            guard let last = code.range(of: needle, options: .backwards) else {
                return XCTFail("`\(needle)` not found — this guard has gone stale.")
            }
            XCTAssertLessThan(
                last.upperBound, insert.lowerBound,
                "`\(needle)` runs AFTER the gateway-attempt insert. A preparation that can "
                    + "fail below the boundary strands a phantom `inFlight` row that no "
                    + "terminal callback will ever close — and a local failure gets recorded "
                    + "as gateway usage."
            )
        }
    }

    /// The insert is best-effort in the direction that matters: a nil context
    /// selects the nil-variant metadata and the turn still dispatches. Pinned by
    /// requiring the fallback expression rather than by asserting an absence.
    func testAnUnmeasuredDispatchStillCarriesLandingMetadata() throws {
        let code = try backgroundRemoteAgentCode()
        XCTAssertTrue(
            code.contains("? unmeasuredMetadataString"),
            "The nil-variant fallback is gone. A ledger insert that fails must not take the "
                + "user's turn down with it — measurement is auxiliary."
        )
        XCTAssertTrue(
            code.contains("measuredMetadataString ?? unmeasuredMetadataString"),
            "The attempt-bearing encode is no longer fail-open. Its failure must degrade to "
                + "the nil-variant, not abort a valid BYO-gateway request."
        )
    }

    // MARK: - 2. One resume, inside the critical section

    func testExactlyOneConverseTaskResumeExists() throws {
        let code = try backgroundRemoteAgentCode()
        XCTAssertEqual(
            code.components(separatedBy: "task.resume()").count - 1, 1,
            "More than one `task.resume()` on the converse lane. Exactly one dispatch site can "
                + "be inside the critical section that reads the Stop claim; a second one is a "
                + "path where a cancelled turn leaves the device anyway."
        )
    }

    func testTheStopClaimIsReadInTheSameBlockThatResumes() throws {
        let code = try backgroundRemoteAgentCode()
        let body = span(of: code, from: "private func resumeOrRefuse(", to: "\n    private func armPendingDispatch")
        guard let claim = body.range(of: "pendingDispatchCancels.contains"),
              let resume = body.range(of: "task.resume()") else {
            return XCTFail("`resumeOrRefuse` no longer both reads the Stop claim and resumes the task.")
        }
        XCTAssertLessThan(
            claim.upperBound, resume.lowerBound,
            "The Stop claim is read after the task is resumed. The read and the resume have to "
                + "sit in one `queue` block, in that order, or a Stop arriving between them is lost."
        )
        XCTAssertTrue(
            body.contains("beginPersistenceWork()") && body.contains("endPersistenceWork()"),
            "A refused dispatch writes to the store outside the counted background-wake barrier. "
                + "The OS completion handler must not be released before that write lands."
        )
    }

    // MARK: - 3. Exact cancellation

    func testInFlightTurnCarriesTheExactUserMessageID() throws {
        let code = try backgroundRemoteAgentCode()
        XCTAssertTrue(
            code.contains("let userMessageID: UUID?"),
            "`InFlightTurn` no longer records the exact user Message.id. Without it the only "
                + "cancel available is the conversation-scoped one, which can stop the wrong "
                + "turn when two overlap."
        )
    }

    func testExactCancelMatchesTheTurnAndNotTheThread() throws {
        let code = try backgroundRemoteAgentCode()
        let body = span(of: code, from: "func cancel(userMessageID: UUID) {", to: "\n    func cancel(conversationID: UUID) {")
        XCTAssertTrue(
            body.contains("$0.userMessageID == userMessageID"),
            "`cancel(userMessageID:)` no longer matches the registry on the exact user "
                + "Message.id."
        )
        XCTAssertFalse(
            body.contains("$0.conversationID =="),
            "`cancel(userMessageID:)` fell back to matching on the conversation. With two "
                + "overlapping turns that cancels whichever entry iterates first and attributes "
                + "the stop to the other — which is the defect this signature exists to fix."
        )
        XCTAssertTrue(
            body.contains("pendingDispatchIDs.contains(userMessageID)"),
            "A Stop no longer reaches a dispatch that is still inside `send`. The awaited ledger "
                + "insert is a window in which no task exists yet, and only the pending claim "
                + "covers it."
        )
    }

    // MARK: - 4. One completion stamp

    func testTheTerminalCallbackStampsCompletionBeforeAnyPersistence() throws {
        let code = try backgroundRemoteAgentCode()
        let landing = span(
            of: code,
            from: "didCompleteWithError error: Error?) {",
            to: "func urlSessionDidFinishEvents"
        )
        guard let stamp = landing.range(of: "let completedAt = Date()"),
              let hop = landing.range(of: "queue.async {") else {
            return XCTFail("The terminal callback no longer stamps `completedAt` before its queue hop.")
        }
        XCTAssertLessThan(
            stamp.upperBound, hop.lowerBound,
            "`completedAt` is stamped after the queue hop. It has to be the first thing the "
                + "callback does, or the elapsed time the ledger records includes this app's own "
                + "scheduling and persistence rather than the gateway's work."
        )
        XCTAssertFalse(
            landing.contains("completedAt: Date()"),
            "A terminal observation in the landing reads the clock again instead of carrying the "
                + "stamp taken at the top of the callback."
        )
    }

    /// The observation is built from the ONE stamp, for every branch — success,
    /// classified failure, peer reset, cancel and the cross-launch ambiguous
    /// case alike.
    func testEveryLandingBranchCarriesTheSingleStamp() throws {
        let code = try backgroundRemoteAgentCode()
        let landing = span(
            of: code,
            from: "didCompleteWithError error: Error?) {",
            to: "func urlSessionDidFinishEvents"
        )
        XCTAssertTrue(
            landing.contains("completedAt: completedAt"),
            "The landing's terminal observation no longer carries the callback's own stamp."
        )
        // The relaunch rule: a `.cancelled` with no live claim is `unknown`, not
        // `cancelled` — this device cannot tell a user's Stop from a force-quit
        // resurrection, and guessing would race the owning device's real answer.
        XCTAssertTrue(
            landing.contains("observe(.unknown, nil)"),
            "The cross-launch ambiguous cancellation no longer records `unknown`. Recording it "
                + "as `cancelled` claims a Stop the user may never have made; recording it as "
                + "`failed` claims a verdict nobody reached."
        )
    }
}
