// SPDX-License-Identifier: Apache-2.0

// Conduck
// ParkedConverseLaneDriftGuardTests.swift
//
// SOURCE DRIFT GUARD for the four prohibitions that keep at-most-once dispatch a
// STRUCTURAL property of the iOS converse lane rather than an argument someone has
// to re-derive: nothing cancels a converse task on a client-owned deadline,
// nothing gates a dispatch on connectivity, the connectivity signal may only
// choose a word, and the ONE failure write a Stop is allowed to make posts no
// failure event.
//
// WHY A GUARD AND NOT REVIEW. Every one of these holds today by ABSENCE — there
// is no watchdog, no pre-flight, no timer. Absence is invisible in a diff: adding
// a 90-second deadline that cancels a task which "obviously" is not going
// anywhere reads like a fix for a hang, compiles, makes the app feel more
// responsive on a bad network, and breaks nothing a behavioural test can see —
// because the turn it kills is one the system was about to send, and the user
// finds out by paying for the same turn twice when they press the Try Again it
// offered them. That is the failure this file is aimed at, and the reason each
// case names the prohibition rather than the pattern.
//
// SCOPE. Comment-stripped source, read off disk via `#filePath` (the same idiom
// as `LoggingPrivacyDriftGuardTests` / `MarkdownAttachmentPolicyDriftGuardTests`),
// so prose that DISCUSSES a banned mechanism — and these files discuss all of
// them at length, on purpose — never trips a case.
//
// WHAT THIS GUARD DOES NOT DO. It does not check that the behaviour is right;
// `AtMostOnceDispatchInvariantTests` and `ParkedConverseTurnRowHonestyTests` own
// that. It checks that the mechanisms which would make the behaviour wrong are
// still absent, and that the one composition no unit test can reach — the store
// write inside a `URLSessionDataDelegate` callback — is still the composition
// those suites assert against.

import XCTest
@testable import Conduck

final class ParkedConverseLaneDriftGuardTests: XCTestCase {

    // MARK: - Sources

    /// `.../Conduck/Conduck` — the Xcode project container. `#filePath` →
    /// `.../Conduck/Conduck/ConduckTests/<thisFile>`.
    private func projectContainerURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // .../ConduckTests
            .deletingLastPathComponent()   // .../Conduck/Conduck
    }

    /// Every Swift file in the main app target's folder.
    private func appSourceURLs() throws -> [URL] {
        let root = projectContainerURL().appendingPathComponent("Conduck")
        guard let walker = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: nil
        ) else {
            XCTFail("could not walk \(root.path)")
            return []
        }
        return walker.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }

    private func codeOnly(at url: URL) throws -> String {
        codeOnly(try String(contentsOf: url, encoding: .utf8))
    }

    /// Strip Swift comments so prose arguing AGAINST a mechanism is not read as
    /// the mechanism. Conservative in the safe direction: a trailing `// note`
    /// after real code keeps the code, so a banned call cannot hide behind one.
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
        try codeOnly(at: projectContainerURL()
            .appendingPathComponent("Conduck/Services/RemoteAgent/BackgroundRemoteAgent.swift"))
    }

    private func networkPathObserverCode() throws -> String {
        try codeOnly(at: projectContainerURL()
            .appendingPathComponent("Conduck/Services/NetworkPathObserver.swift"))
    }

    // MARK: - No client-owned deadline

    /// PROHIBITION 1 — nothing in the app cancels a converse task on a timer.
    ///
    /// A deadline cannot be built here even in principle: after `resume()` the app
    /// owns no proof, `cancel()` on a background session is documented as
    /// asynchronous and is reported as sometimes not honoured, and Apple's
    /// undocumented background rate limiter — which grows with every background
    /// relaunch and has nothing to do with the network — can legitimately delay a
    /// headless dispatch past any number we could pick. So a "bound" would be a
    /// mechanism that sometimes does not fire, firing on turns iOS was about to
    /// send. The bound the user actually has is Stop, which is lit in every phase.
    func testNoTimerOrDeadlinePrimitiveExistsOnTheConverseLane() throws {
        let code = try backgroundRemoteAgentCode()
        for needle in ["asyncAfter(", "Task.sleep", "makeTimerSource", "Timer(", "Timer.scheduled", "DispatchWorkItem"] {
            XCTAssertFalse(
                code.contains(needle),
                "`\(needle)` appeared on the converse lane. A client-owned deadline "
                    + "that cancels a parked task fails turns the system was about "
                    + "to send, and offers the user a Try Again for a request that "
                    + "may be mid-flight. The wait is unbounded on purpose; Stop is "
                    + "the way out."
            )
        }
    }

    /// The rejected constant, pinned BY NAME. It was proposed, argued and
    /// declined; a future reader who reintroduces it under the same name is
    /// re-opening a settled decision without knowing it.
    func testNoUndispatchedTurnTimeoutConstantIsReintroduced() throws {
        for url in try appSourceURLs() {
            let code = try codeOnly(at: url).lowercased()
            XCTAssertFalse(
                code.contains("undispatchedturntimeout"),
                "\(url.lastPathComponent) reintroduces the undispatched-turn "
                    + "timeout. See the prohibition above — a bound built on a "
                    + "cancel that may not be honoured is not a bound."
            )
        }
    }

    // MARK: - No connectivity gate

    /// PROHIBITION 2 — `waitsForConnectivity` is never set, anywhere.
    ///
    /// It is IGNORED on a background session, so setting it advertises a contract
    /// the transport does not honour — and the next reader who finds it will
    /// reason from it. The same applies to the delegate callback that pairs with
    /// it: implementing `taskIsWaitingForConnectivity` on this lane would create a
    /// hook that never fires.
    func testWaitsForConnectivityIsNeverSet() throws {
        for url in try appSourceURLs() {
            let code = try codeOnly(at: url)
            XCTAssertFalse(
                code.contains("waitsForConnectivity"),
                "\(url.lastPathComponent) sets or reads `waitsForConnectivity`. It "
                    + "does nothing on a background session; the parked-wait "
                    + "behaviour is unconditional and is explained to the user "
                    + "instead of configured away."
            )
        }
        XCTAssertFalse(try backgroundRemoteAgentCode().contains("taskIsWaitingForConnectivity"))
    }

    /// PROHIBITION 3 — the connectivity reading is a NARRATOR. On the transport
    /// lane it is consulted exactly once, as the wording argument to the Stop
    /// verdict, and never before a dispatch decision.
    ///
    /// This is the case that stops a pre-flight from reappearing: "check the
    /// network before sending, and fail fast if there is none" is invariant-safe
    /// but user-hostile — it converts a deferred delivery that WORKS (the founder's
    /// airplane-mode repro ended with the real reply arriving the moment the radio
    /// returned) into a failure the user has to remember to retry, in exactly the
    /// situation this transport exists to serve.
    func testThePathReadingIsOnlyEverAWordChoice() throws {
        let lines = try backgroundRemoteAgentCode()
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { $0.contains("NetworkPathObserver") }
        XCTAssertEqual(
            lines.count, 1,
            "the converse lane reads the path in \(lines.count) places. Its whole "
                + "authority is choosing which already-proven failure a Stop names; "
                + "a second reading is almost certainly a gate, a cancel or a retry."
        )
        XCTAssertTrue(
            lines.first?.contains("pathIsUnsatisfied:") == true,
            "the one path reading must be the Stop verdict's wording argument"
        )
    }

    /// The observer acts on `.unsatisfied` and on nothing else. `.satisfied`
    /// promises nothing Apple documents — a captive portal reads `.satisfied` —
    /// so any design that let it AUTHORISE something would rest a correctness
    /// claim on an undocumented one.
    func testTheObserverActsOnlyOnAnUnsatisfiedPath() throws {
        let code = try networkPathObserverCode()
        XCTAssertTrue(code.contains(".unsatisfied"))
        XCTAssertFalse(
            code.replacingOccurrences(of: ".unsatisfied", with: "").contains(".satisfied"),
            "`.satisfied` authorises nothing, anywhere in this design"
        )
    }

    /// The narrator writes nothing, cancels nothing, and dispatches nothing. This
    /// is what makes a WRONG reading harmless: the worst it can do is put a
    /// slightly different sentence on a screen.
    func testTheObserverCanOnlyChangeAWord() throws {
        let code = try networkPathObserverCode()
        for needle in ["ConversationStore", "URLSession", "noteBegan", "noteDispatched", ".cancel(", "PendingRetryStore"] {
            XCTAssertFalse(
                code.contains(needle),
                "`\(needle)` in the path observer. It may change what a row SAYS "
                    + "and nothing else — that is the entire reason a wrong reading "
                    + "cannot cost a user a turn."
            )
        }
    }

    // MARK: - The one failure write

    /// PROHIBITION 4 — the at-most-once proof has exactly one caller, and it is
    /// the user-initiated Stop. Nothing else in the app may reach for it: a second
    /// caller would be some other authority deciding a turn never left, which is
    /// the decision this whole design exists to keep in one auditable place.
    func testTheStopVerdictHasExactlyOneCaller() throws {
        var callSites: [String] = []
        for url in try appSourceURLs() {
            let hits = try codeOnly(at: url)
                .components(separatedBy: "ConverseCancelVerdict.make(").count - 1
            callSites.append(contentsOf: Array(repeating: url.lastPathComponent, count: hits))
        }
        XCTAssertEqual(
            callSites, ["BackgroundRemoteAgent.swift"],
            "the proof is callable from \(callSites); it belongs to the live-cancel "
                + "branch alone"
        )
    }

    /// The composition `AtMostOnceDispatchInvariantTests` mirrors — pinned at
    /// source, because it lives inside a `URLSessionDataDelegate` callback no unit
    /// test can deliver. If the delegate stops routing the two outcomes to these
    /// two writers, that suite is asserting against a fiction and this case is the
    /// only thing that says so.
    ///
    /// ASSERTED PER ARM, not as a set of names present somewhere in the window.
    /// The two arms are near-identical two-line if/else pairs, so swapping their
    /// bodies is an entirely plausible mis-merge — and a presence check passes
    /// through it unchanged, because all four writers are still there. What
    /// ships from that swap is the exact hazard the invariant exists to prevent:
    /// a turn whose body already departed written with a "this never reached it"
    /// classification and a Retry chip, beside a request the gateway may be
    /// answering.
    func testTheStopBranchRoutesEachOutcomeToItsOwnStoreWriter() throws {
        let branch = try stopBranchSource()
        let split = try XCTUnwrap(
            branch.range(of: "case .provableNonDelivery"),
            "the Stop branch no longer distinguishes a proven non-delivery from "
                + "an unknown one at all"
        )
        let unknownArm = String(branch[branch.startIndex..<split.lowerBound])
        let provenArm = String(branch[split.lowerBound...])

        // UNKNOWN delivery — bytes left, so the app knows nothing about what the
        // gateway holds. Status flip only, with no cause attached.
        for needle in ["markPendingUserTurn(messageID:", "markPendingUserTurns(conversationID:"] {
            XCTAssertTrue(
                unknownArm.contains(needle),
                "the `.unknownDelivery` arm no longer calls `\(needle)`; it needs "
                    + "both an exact-id and a conversation-wide status writer."
            )
        }
        for needle in ["failTurn(", "failPendingUserTurns("] {
            XCTAssertFalse(
                unknownArm.contains(needle),
                "the `.unknownDelivery` arm calls `\(needle)`, which writes a "
                    + "CAUSE onto a turn whose bytes departed. The user is then "
                    + "told the request never arrived, beside a Try Again for a "
                    + "turn the gateway may already be answering — their model "
                    + "budget spent twice and their agent free to act on the "
                    + "world twice."
            )
        }

        // PROVEN non-delivery — nothing left the device, so the failure carries
        // the one client-side cause the counters actually support.
        for needle in ["failTurn(", "failPendingUserTurns("] {
            XCTAssertTrue(
                provenArm.contains(needle),
                "the `.provableNonDelivery` arm no longer calls `\(needle)`; a "
                    + "proven non-delivery that writes no cause leaves the user "
                    + "staring at an unexplained failed row."
            )
        }
        for needle in ["markPendingUserTurn(", "markPendingUserTurns("] {
            XCTAssertFalse(
                provenArm.contains(needle),
                "the `.provableNonDelivery` arm calls `\(needle)`, the "
                    + "unclassified writer — the classification this branch "
                    + "exists to add would be silently dropped."
            )
        }

        XCTAssertTrue(branch.contains("beginPersistenceWork"))
        XCTAssertTrue(branch.contains("endPersistenceWork"))
    }

    /// A user-initiated Stop is not a failure EVENT. No push may fire for it and
    /// the macOS menu-bar failure dot must not light — which is why the branch
    /// writes to the store directly instead of routing through `postTurnFailed`,
    /// the helper that does both.
    func testTheStopBranchPostsNoFailureEvent() throws {
        let branch = try stopBranchSource()
        for needle in ["postTurnFailed(", "notifyUser", "remoteAgentTurnDidFail", "scheduleFailureNotification", "UNUserNotification"] {
            XCTAssertFalse(
                branch.contains(needle),
                "`\(needle)` in the Stop branch. The user just asked for this turn "
                    + "to stop; telling them it failed — on their phone's lock "
                    + "screen, or with a red dot on another device — reports their "
                    + "own action back to them as a problem."
            )
        }
    }

    // MARK: - Stop actually reaches a task

    /// STOP IS THE ONLY BOUND ON THIS WAIT, which is the premise the whole
    /// design rests on — no timer, no watchdog, no pre-flight — so a Stop that
    /// quietly finds nothing takes the user's last exit away.
    ///
    /// The turn most likely to be parked is the one that outlived a process
    /// kill: it comes back through `reconcile()` as a live CANCELLABLE claim, so
    /// the thread lights a Stop for it, and it is precisely the turn the
    /// in-memory registry cannot see. Guarding the whole method on a registry
    /// entry left that Stop inert — no cancel, no completion, no failure, and a
    /// row counting forever with the launch sweep forbidden from touching it.
    ///
    /// Pinned at source because the fallback lives inside a `getAllTasks`
    /// completion no unit test can drive.
    func testStopFallsBackToTheSessionsOwnTaskSetWhenTheRegistryHasNoEntry() throws {
        let body = try cancelBodySource()
        XCTAssertFalse(
            body.contains("guard let entry"),
            "`cancel(conversationID:)` bails out when the in-memory registry has "
                + "no entry. That is the relaunched, parked turn — the one case "
                + "where Stop matters most — and it now does nothing at all."
        )
        XCTAssertTrue(
            body.contains("getAllTasks"),
            "the fallback must consult the session's own live task set, the only "
                + "source that survives a process kill"
        )
        XCTAssertTrue(
            body.contains("RemoteAgentBackgroundMetadata.decode"),
            "a resurrected task is matched to its conversation through the "
                + "recovery metadata; nothing else on the task carries the id"
        )
        XCTAssertTrue(
            body.contains("cancelRequestedTaskIDs"),
            "the Stop intent must be noted OUTSIDE the registry, or the "
                + "completion reads `entry == nil` and reports the user's own tap "
                + "back to them as a failure notification"
        )
    }

    /// The cross-launch FAILURE branch — notification, macOS failure dot — must
    /// stay gated on nobody here having asked for the stop. Ungated, a Stop on a
    /// relaunch-adopted turn pushes a "couldn't reach your AI" alert for an
    /// action the user just took deliberately.
    func testTheResurrectionFailureBranchIsGatedOnNoStopHavingBeenAsked() throws {
        let code = try backgroundRemoteAgentCode()
        XCTAssertTrue(
            code.contains("if entry == nil, !stopWasRequested {"),
            "the resurrected-task failure branch no longer excludes a Stop this "
                + "process asked for. A user-initiated Stop is not a failure "
                + "EVENT: no push may fire and the menu-bar red dot must not light."
        )
    }

    // MARK: - The row still asks

    /// THE DEFECT'S ACTUAL SITE. `ConversationThreadView.thinkingIndicator` used
    /// a hard-coded `.answering`, which is why a correct resolver would not have
    /// saved this row and why no behavioural test could see the bug: the view
    /// never asked. It must read the resolved phase, and it must read the
    /// phase-scoped stamp for its clock — a row with honest words and a counter
    /// that still includes the parked minutes is only half-fixed.
    func testTheThreadRowRendersTheResolvedPhaseAndNeverAHardCodedWorkingClaim() throws {
        let code = try codeOnly(at: projectContainerURL()
            .appendingPathComponent("Conduck/Views/Conversation/ConversationThreadView.swift"))
        XCTAssertTrue(code.contains("viewModel.liveTurnPhase"),
                      "the thread's in-flight row must ask what phase the turn is in")
        XCTAssertTrue(
            code.contains("viewModel.liveTurnPhaseSince"),
            "the elapsed clock must count from the PHASE's stamp — from the "
                + "hand-off once the body departed, from the claim before that"
        )
        XCTAssertFalse(
            code.contains(".answering"),
            "the thread names a phase literally. That is the original defect "
                + "verbatim: the row claimed the gateway was answering because it "
                + "was written to say so, not because anything had been sent."
        )
    }

    /// The list row resolves the same way, from the same registry facts, so the
    /// two surfaces cannot tell a user two different stories about one turn. Its
    /// only literal `.answering` is a FALLBACK for a row with no live claim at
    /// all — never an assertion about a turn.
    func testTheListRowResolvesTheSamePhaseFromTheSameFacts() throws {
        let code = try codeOnly(at: projectContainerURL()
            .appendingPathComponent("Conduck/Views/Conversation/ConversationActivityMark.swift"))
        XCTAssertTrue(code.contains("LiveTurnPhaseResolver.resolve("))
        XCTAssertEqual(
            code.components(separatedBy: ".answering").count,
            code.components(separatedBy: "?? .answering").count,
            "the list row states `.answering` outside a nil-fallback. The words "
                + "beside a live turn come from the resolver or they come from a guess."
        )
    }

    /// The launch sweep is the ONLY writer that can resolve a `sending` turn
    /// nobody stopped, so on the lane that parks it must always be handed the
    /// live-task set. Without it the sweep eventually declares a parked turn
    /// failed on its own initiative — a failure written while delivery is still
    /// possible, which is the one thing this design may never do.
    ///
    /// macOS branches are excluded on purpose: that platform sends on a
    /// foreground session, has no background converse session to exclude, and
    /// nothing there parks.
    func testEveryLaunchSweepOnTheParkingLaneCarriesTheLiveTaskSet() throws {
        let code = withoutMacOSBranches(
            try codeOnly(at: projectContainerURL().appendingPathComponent("Conduck/ConduckApp.swift"))
        )
        let calls = code.components(separatedBy: "sweepStaleSendingUserTurns(").dropFirst()
        XCTAssertFalse(calls.isEmpty, "the launch sweep wiring vanished entirely")
        for call in calls {
            XCTAssertTrue(
                call.prefix(220).contains("excludingConversationIDs:"),
                "a sweep runs with no live-task exclusion on a lane whose turns "
                    + "park. It would fail a turn that has not been sent yet and "
                    + "offer the user a Try Again for a request the system is still "
                    + "holding — the double-send this design exists to prevent."
            )
        }
    }

    /// Drop `#if os(macOS)` regions (keeping any `#else`), so a case can speak
    /// about the lane that actually parks.
    private func withoutMacOSBranches(_ code: String) -> String {
        var out = ""
        var depth = 0
        var skipping = 0
        for line in code.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#if") {
                depth += 1
                if skipping == 0, trimmed.contains("os(macOS)") { skipping = depth }
                continue
            }
            if trimmed.hasPrefix("#endif") {
                if skipping == depth { skipping = 0 }
                depth -= 1
                continue
            }
            if trimmed.hasPrefix("#else") {
                if skipping == depth { skipping = 0 }
                continue
            }
            if skipping == 0 {
                out.append(contentsOf: line)
                out.append("\n")
            }
        }
        return out
    }

    /// `cancel(conversationID:)`'s body, anchored on the two declarations that
    /// bracket it rather than on line numbers.
    private func cancelBodySource() throws -> String {
        let code = try backgroundRemoteAgentCode()
        let start = try XCTUnwrap(
            code.range(of: "func cancel(conversationID: UUID) {"),
            "the converse lane no longer exposes a cancel at all — Stop is the "
                + "user's only bound on a wait nothing else bounds"
        )
        let end = try XCTUnwrap(
            code.range(of: "func hasLiveConverseTask(", range: start.upperBound..<code.endIndex),
            "the anchor that ends the cancel body moved; re-point this helper"
        )
        return String(code[start.upperBound..<end.lowerBound])
    }

    /// The live-cancel branch's code, from the verdict to the cancellation the
    /// continuation resolves with. Anchored on the two statements that bracket it
    /// rather than on line numbers, so ordinary edits above and below do not move
    /// the window.
    private func stopBranchSource() throws -> String {
        let code = try backgroundRemoteAgentCode()
        let start = try XCTUnwrap(
            code.range(of: "ConverseCancelVerdict.make("),
            "the Stop branch no longer consults the at-most-once proof at all"
        )
        let end = try XCTUnwrap(
            code.range(of: "CancellationError()", range: start.upperBound..<code.endIndex),
            "the Stop branch must still resolve its continuation with a cancellation"
        )
        return String(code[start.lowerBound..<end.upperBound])
    }
}
