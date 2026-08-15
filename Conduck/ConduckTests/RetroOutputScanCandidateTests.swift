// SPDX-License-Identifier: Apache-2.0

// Conduck
// RetroOutputScanCandidateTests.swift
//
// Locks the PURE decision halves of the retroactive output-file scan (the
// network + store plumbing is singleton/CloudKit-bound and covered by the
// founder's on-device QA):
//   • `ConversationDetailViewModel.retroScanCandidates(in:attempted:cap:)` —
//     the turn-selection filter: only explicitly-pending agent turns
//     (`outputScanDone == false`) carrying BOTH an exact durable output lane and
//     the folder that dispatch named, skipping ownerless legacy, already-scanned,
//     and already-attempted turns, newest-first and capped. A partial-success
//     turn (already carrying a server-ref chip while still pending) is STILL
//     selected so the rest of its folder can be delivered.
//   • `FileTransferOutputDetector.probeIsConclusive(_:)` — the per-outcome
//     DEFINITIVENESS predicate for the TAP-ONLY name search (did the server
//     answer at all?).
//   • `FileTransferOutputDetector.scanMayClose(...)` — the pass-level verdict
//     that actually decides whether `outputScanDone` may be stamped: real
//     evidence AND the turn's age gate open. Closing is permanent, so a
//     definite-but-too-early empty answer must not be allowed to do it.
//   • `ConversationDetailViewModel.holdVerdict(...)` — when a turn left PENDING
//     by a pass may be examined again: at its age gate, immediately (the pass
//     delivered a file, so the window has walked on), or after a stalled
//     interval (nothing closed, nothing found — re-running the identical request
//     against the identical lane learns nothing and spends the user's server).
//     The stalled interval WIDENS with the turn's consecutive-stall streak
//     (`retroStallBackoff`), which is what bounds a turn no pass can ever close.
//   • `retroScanParkSet` / `parkedRetroScanState` / `releasedRetroScanState` —
//     the ownership arithmetic behind the lane breaker's saving: which
//     candidates a suppressed pass must park, that a park moves attempt
//     ownership AND a dated hold together, and that a release hands back exactly
//     the held ids. An id dropped here is one a reload echo re-selects at once,
//     which is the difference between a bounded pass and an unbounded one.
//   • `FileLaneScanBreaker.laneKey(for:)` — that every repair a user can make
//     (URL, credential, certificate pin) lands on a clean lane, while the
//     mutable readiness/capability verdicts do not.
//   • `ConversationDetailViewModel.earliestHoldDeadline(in:)` /
//     `dueHoldIDs(in:asOf:)` — the one-timer, per-id scheduling policy for
//     turns whose attempt ownership is held: the timer wakes for the soonest
//     deadline and releases only the ids that are actually due, which is what
//     keeps a re-probe from asking the user's file server a question it has
//     already answered.
//
// Deterministic + headless: no network, no Core Data, no Keychain. Synthetic
// fixtures only; no real filenames/keys.

import XCTest
@testable import Conduck

@MainActor
final class RetroOutputScanCandidateTests: XCTestCase {

    // MARK: - Fixtures

    private let ownedLaneID = String(repeating: "w", count: 64)

    private func message(
        id: UUID = UUID(),
        role: String,
        sourceDevice: String,
        text: String = "",
        outputScanDone: Bool? = nil,
        outputScanLaneID: String? = nil,
        /// The folder this dispatch named. Defaults to "the row is complete";
        /// `nil` is the row a device synced ahead of the attribute, which the
        /// filter must select OUT rather than close.
        outputBoxKey: String? = "conv/out-box",
        storedKeys: [String] = []
    ) -> MessageRecord {
        let attachments = storedKeys.enumerated().map { index, key in
            AttachmentRecord(
                id: UUID(),
                mimeType: "application/octet-stream",
                filename: nil,
                thumbnailData: nil,
                extractedText: nil,
                width: 0,
                height: 0,
                byteSize: 0,
                sequence: index,
                createdAt: Date(timeIntervalSince1970: 0),
                isServerReference: true,
                storedKey: key
            )
        }
        return MessageRecord(
            id: id,
            role: role,
            text: text,
            createdAt: Date(timeIntervalSince1970: 0),
            sourceDevice: sourceDevice,
            outputScanDone: outputScanDone,
            outputScanLaneID: outputScanLaneID,
            outputBoxKey: outputScanLaneID == nil ? nil : outputBoxKey,
            attachments: attachments
        )
    }

    private func pendingAgent(
        id: UUID = UUID(),
        sourceDevice: String,
        text: String = "",
        storedKeys: [String] = []
    ) -> MessageRecord {
        message(
            id: id,
            role: "agent",
            sourceDevice: sourceDevice,
            text: text,
            outputScanDone: false,
            outputScanLaneID: ownedLaneID,
            storedKeys: storedKeys
        )
    }

    private func serverRef(_ storedKey: String) -> AttachmentDraft {
        var draft = AttachmentDraft(
            mimeType: "application/pdf",
            filename: storedKey,
            data: Data(),
            thumbnailData: nil,
            width: 0,
            height: 0,
            byteSize: 0,
            sequence: 0
        )
        draft.isServerReference = true
        draft.storedKey = storedKey
        return draft
    }

    private var candidates: [MessageRecord] {
        // A mix spanning every disposition the filter must decide.
        [
            pendingAgent(sourceDevice: "watch"),                    // ✓ owned + pending
            pendingAgent(sourceDevice: "carplay"),                  // ✓ owned + pending
            message(role: "agent", sourceDevice: "iphone"),         // ✗ ownerless
            message(role: "agent", sourceDevice: "mac"),            // ✗ ownerless
            message(role: "user", sourceDevice: "watch"),           // ✗ user turn
            message(role: "agent", sourceDevice: "watch",
                    outputScanDone: true)                           // ✗ already scanned
        ]
    }

    // MARK: - retroScanCandidates

    func testSelectsWatchAndCarPlayAgentTurnsOnly() {
        let out = ConversationDetailViewModel.retroScanCandidates(
            in: candidates, attempted: [], cap: 20
        )
        XCTAssertEqual(out.count, 2, "only the watch + carplay agent turns qualify")
        let devices = Set(out.map(\.sourceDevice))
        XCTAssertEqual(devices, ["watch", "carplay"])
        XCTAssertTrue(out.allSatisfy { $0.role == "agent" })
    }

    func testOwnerlessWatchAndCarPlayLegacyNilAreExcluded() {
        let watch = message(role: "agent", sourceDevice: "watch", outputScanDone: nil)
        let carPlay = message(role: "agent", sourceDevice: "carplay", outputScanDone: nil)
        let out = ConversationDetailViewModel.retroScanCandidates(
            in: [watch, carPlay], attempted: [], cap: 20
        )
        XCTAssertTrue(out.isEmpty,
                      "ownerless legacy rows cannot prove which file-transfer lane to probe")
    }

    func testMacExplicitFalseIsSelected() {
        let pending = message(
            role: "agent",
            sourceDevice: "mac",
            outputScanDone: false,
            outputScanLaneID: String(repeating: "a", count: 64)
        )
        let out = ConversationDetailViewModel.retroScanCandidates(
            in: [pending], attempted: [], cap: 20
        )
        XCTAssertEqual(out.map(\.id), [pending.id],
                       "only a dispatch-latched pending Mac reply is recoverable")
    }

    func testLegacyMacNilIsExcluded() {
        let legacy = message(role: "agent", sourceDevice: "mac", outputScanDone: nil)
        let out = ConversationDetailViewModel.retroScanCandidates(
            in: [legacy], attempted: [], cap: 20
        )
        XCTAssertTrue(out.isEmpty,
                      "legacy/no-lane Mac nil must not trigger speculative probes")
    }

    func testMacFalseWithoutDurableLaneIsExcluded() {
        let legacyPending = message(
            role: "agent",
            sourceDevice: "mac",
            outputScanDone: false,
            outputScanLaneID: nil
        )
        let out = ConversationDetailViewModel.retroScanCandidates(
            in: [legacyPending], attempted: [], cap: 20
        )
        XCTAssertTrue(out.isEmpty,
                      "v6 false-without-lane rows cannot prove which server to probe")
    }

    func testOtherCapableSurfacesAndUserTurnsExcluded() {
        let out = ConversationDetailViewModel.retroScanCandidates(
            in: candidates, attempted: [], cap: 20
        )
        XCTAssertFalse(out.contains { $0.sourceDevice == "iphone" },
                       "iPhone agent turns already ran landing-path detection")
        XCTAssertFalse(out.contains { $0.role == "user" }, "user turns never carry outputs")
    }

    func testScannedTurnExcluded() {
        let scanned = message(role: "agent", sourceDevice: "watch", outputScanDone: true)
        let out = ConversationDetailViewModel.retroScanCandidates(
            in: [scanned], attempted: [], cap: 20
        )
        XCTAssertTrue(out.isEmpty, "outputScanDone == true is never re-scanned")
    }

    func testAttemptedTurnExcluded() {
        let m = message(role: "agent", sourceDevice: "watch")
        let out = ConversationDetailViewModel.retroScanCandidates(
            in: [m], attempted: [m.id], cap: 20
        )
        XCTAssertTrue(out.isEmpty, "a turn already attempted this instance is skipped")
    }

    /// The recovery case the lane breaker must never eat. Attempt ownership —
    /// including the parking a suppressed lane applies — is PER PRESENTATION,
    /// and the durable marker stays pending, so a turn whose file genuinely
    /// arrived late is selected again by the next thread open. A breaker that
    /// silenced a lane across presentations would show up here.
    func testPendingTurnIsSelectedAgainByAFreshPresentation() {
        let m = pendingAgent(sourceDevice: "watch")
        XCTAssertTrue(
            ConversationDetailViewModel.retroScanCandidates(
                in: [m], attempted: [m.id], cap: 20
            ).isEmpty,
            "parked or already-probed inside the presentation that parked it"
        )
        XCTAssertEqual(
            ConversationDetailViewModel.retroScanCandidates(
                in: [m], attempted: [], cap: 20
            ).map(\.id),
            [m.id],
            "a new presentation starts with no attempt ownership and re-selects it"
        )
    }

    /// A suffixed `sourceDevice` (`watch-voice`) remains eligible when the turn
    /// is explicitly pending and owns an exact durable lane.
    func testSuffixedSourceDeviceTolerated() {
        let m = pendingAgent(sourceDevice: "watch-voice")
        let out = ConversationDetailViewModel.retroScanCandidates(
            in: [m], attempted: [], cap: 20
        )
        XCTAssertEqual(out.map(\.id), [m.id])
    }

    /// PARTIAL-success turn: already carries a server-ref chip but is unmarked
    /// (a prior pass confirmed some files, then hit a transient probe on the
    /// rest). It MUST still be selected so the missing candidates retry.
    func testPartialSuccessTurnStillSelected() {
        let m = pendingAgent(
            sourceDevice: "watch",
            storedKeys: ["already__chipped.pdf"]
        )
        let out = ConversationDetailViewModel.retroScanCandidates(
            in: [m], attempted: [], cap: 20
        )
        XCTAssertEqual(out.map(\.id), [m.id],
                       "having a server-ref attachment does NOT exclude an unmarked turn")
    }

    func testCapLimitsCount() {
        let many = (0..<30).map { _ in pendingAgent(sourceDevice: "watch") }
        let out = ConversationDetailViewModel.retroScanCandidates(
            in: many, attempted: [], cap: 20
        )
        XCTAssertEqual(out.count, 20, "the pass is capped")
    }

    /// Newest-first: input is createdAt-ascending, so the filter reverses. With
    /// the cap biting, the NEWEST turns must survive (they matter most to a user
    /// who just opened the thread).
    func testNewestFirstOrdering() {
        let ordered = (0..<3).map { i in
            pendingAgent(
                id: UUID(uuidString: "00000000-0000-0000-0000-00000000000\(i)")!,
                sourceDevice: "watch"
            )
        }
        let out = ConversationDetailViewModel.retroScanCandidates(
            in: ordered, attempted: [], cap: 20
        )
        XCTAssertEqual(out.map(\.id), ordered.reversed().map(\.id),
                       "candidates come back newest-first")
    }

    func testNewestSurviveTheCap() {
        let ordered = (0..<5).map { i in
            pendingAgent(
                id: UUID(uuidString: "00000000-0000-0000-0000-00000000000\(i)")!,
                sourceDevice: "watch"
            )
        }
        let out = ConversationDetailViewModel.retroScanCandidates(
            in: ordered, attempted: [], cap: 2
        )
        // Input ids end in 0..4; newest (4,3) survive a cap of 2.
        XCTAssertEqual(out.map(\.id), [ordered[4].id, ordered[3].id])
    }

    // MARK: - durable lane routing

    // `retroOutputScanRoute` is PURE and synchronous: nothing about the reply's
    // text enters the decision any more, so a pass over `retroScanCap` turns no
    // longer pays an untrusted-input regex per candidate on every thread open.
    func testMacCandidateRoutesOnlyToMatchingCurrentLane() {
        let laneA = String(repeating: "a", count: 64)
        let turn = message(
            role: "agent",
            sourceDevice: "mac",
            text: "Done: output.pdf",
            outputScanDone: false,
            outputScanLaneID: laneA
        )

        let matchingLane = ConversationDetailViewModel.retroOutputScanRoute(
            for: turn,
            currentLaneID: laneA
        )
        XCTAssertEqual(matchingLane, .probeCurrentLane)

        let repointedLane = ConversationDetailViewModel.retroOutputScanRoute(
            for: turn,
            currentLaneID: String(repeating: "b", count: 64)
        )
        XCTAssertEqual(
            repointedLane,
            .deferUntilMatchingLane,
            "repointing A to B must result in zero B probes"
        )

        let removedLane = ConversationDetailViewModel.retroOutputScanRoute(
            for: turn,
            currentLaneID: nil
        )
        XCTAssertEqual(
            removedLane,
            .deferUntilMatchingLane,
            "removing the current lane leaves A recoverable when restored"
        )
    }

    /// THE REPLY TEXT DOES NOT ROUTE. A reply that names files and one that
    /// names none take the identical route, because what the pass reads is the
    /// folder this dispatch named — never the prose. There is no local-conclusion
    /// shortcut left: a turn either gets its one listing or waits for its lane.
    func testReplyTextDoesNotChangeTheRoute() {
        let laneA = String(repeating: "a", count: 64)
        let named = ConversationDetailViewModel.retroOutputScanRoute(
            for: message(role: "agent", sourceDevice: "mac", text: "Done: output.pdf",
                         outputScanDone: false, outputScanLaneID: laneA),
            currentLaneID: laneA
        )
        let silent = ConversationDetailViewModel.retroOutputScanRoute(
            for: message(role: "agent", sourceDevice: "mac", text: "Done.",
                         outputScanDone: false, outputScanLaneID: laneA),
            currentLaneID: laneA
        )
        XCTAssertEqual(named, silent, "prose is not a routing input")
        XCTAssertEqual(silent, .probeCurrentLane)

        let noLane = ConversationDetailViewModel.retroOutputScanRoute(
            for: message(role: "agent", sourceDevice: "mac", text: "Done.",
                         outputScanDone: false, outputScanLaneID: laneA),
            currentLaneID: nil
        )
        XCTAssertEqual(noLane, .deferUntilMatchingLane,
                       "a filename-free reply waits for its lane like any other")
    }

    func testProductionExecutorPerformsZeroProbesForRemovedOrRepointedMacLane() async {
        let laneA = String(repeating: "a", count: 64)
        let laneB = String(repeating: "b", count: 64)
        let turn = message(
            role: "agent",
            sourceDevice: "mac",
            text: "Done: output.pdf",
            outputScanDone: false,
            outputScanLaneID: laneA
        )

        for currentLaneID: String? in [laneB, nil] {
            var laneChecks = 0
            var claims = 0
            var probes = 0
            let execution = await ConversationDetailViewModel
                .executeRetroOutputScanCandidate(
                    turn,
                    currentLaneID: currentLaneID,
                    snapshotAvailable: currentLaneID != nil,
                    laneStillMatches: {
                        laneChecks += 1
                        return true
                    },
                    claim: {
                        claims += 1
                        return true
                    },
                    didClaim: {},
                    list: { _, _ in
                        probes += 1
                        return .init(
                            drafts: [], conclusive: true, verdict: .entries([]),
                            refusedEntryCount: 0)
                    }
                )

            guard case .deferred = execution else {
                return XCTFail("a removed/repointed lane must stay pending")
            }
            XCTAssertEqual(laneChecks, 0,
                           "durable-ID rejection happens before any live lane check")
            XCTAssertEqual(claims, 0,
                           "a deferred row remains unattempted so restoring lane A can recover it")
            XCTAssertEqual(probes, 0,
                           "the production executor must not invoke the actual file-probe closure")
        }
    }

    func testProductionExecutorInvokesProbeOnceForMatchingMacLane() async {
        let laneA = String(repeating: "a", count: 64)
        let turn = message(
            role: "agent",
            sourceDevice: "mac",
            text: "Done: output.pdf",
            outputScanDone: false,
            outputScanLaneID: laneA
        )
        var probes = 0

        let execution = await ConversationDetailViewModel
            .executeRetroOutputScanCandidate(
                turn,
                currentLaneID: laneA,
                snapshotAvailable: true,
                laneStillMatches: { true },
                claim: { true },
                didClaim: {},
                list: { _, _ in
                    probes += 1
                    return .init(drafts: [], conclusive: true, verdict: .entries([]),
                                 refusedEntryCount: 0)
                }
            )

        guard case .listed = execution else {
            return XCTFail("the exact durable lane should reach the listing closure")
        }
        XCTAssertEqual(probes, 1)
    }

    func testOwnerlessLegacyWatchProbeDefersWithoutLaneIdentity() async {
        let currentLaneID = String(repeating: "w", count: 64)
        let turn = message(
            role: "agent",
            sourceDevice: "watch",
            text: "Done: watch-output.pdf",
            outputScanDone: nil,
            outputScanLaneID: nil
        )
        var probes = 0

        let execution = await ConversationDetailViewModel
            .executeRetroOutputScanCandidate(
                turn,
                currentLaneID: currentLaneID,
                snapshotAvailable: true,
                laneStillMatches: { true },
                claim: { true },
                didClaim: {},
                list: { _, _ in
                    probes += 1
                    return .init(
                        drafts: [self.serverRef("watch-output.pdf")],
                        conclusive: true,
                        verdict: .entries([]),
                        refusedEntryCount: 0
                    )
                }
            )

        guard case .deferred = execution else {
            return XCTFail("an ownerless legacy Watch turn must remain deferred")
        }
        XCTAssertEqual(probes, 0,
                       "without a durable dispatch-time lane, no server may be probed")
    }

    // MARK: - probeIsConclusive (per-outcome DEFINITIVENESS)

    /// `probeIsConclusive` answers only "did the server give a real answer about
    /// this key?". A `.missing` does — but a definitive answer is not on its own
    /// SUFFICIENT to close a turn; `scanMayClose` below owns that decision,
    /// because a 404 collected milliseconds after the reply may simply have
    /// arrived before the agent's file did.
    func testDefinitiveOutcomes() {
        XCTAssertTrue(FileTransferOutputDetector.probeIsConclusive(.exists))
        XCTAssertTrue(FileTransferOutputDetector.probeIsConclusive(.missing),
                      "a not-found IS a real answer about this instant")
    }

    func testNonDefinitiveOutcomes() {
        XCTAssertFalse(FileTransferOutputDetector.probeIsConclusive(.unauthorized))
        XCTAssertFalse(FileTransferOutputDetector.probeIsConclusive(.serverError))
        XCTAssertFalse(FileTransferOutputDetector.probeIsConclusive(.certRefused))
        XCTAssertFalse(FileTransferOutputDetector.probeIsConclusive(.unknown),
                       "a transient/inconclusive probe must NOT let the pass mark scanned")
    }

    // MARK: - scanMayClose (pass-level AGE gate)

    private var grace: TimeInterval { FileTransferOutputDetector.outputScanGrace }
    private var truncatedHorizon: TimeInterval { FileTransferOutputDetector.truncatedScanHorizon }

    /// WHY this gate exists: the landing probe fires in the same async call as
    /// reply persistence, so without it an agent whose file lands a second late
    /// — or an rclone VFS directory cache that has not settled — closes the turn
    /// on a definitive 404 and loses that file forever.
    func testDefinitiveMissInsideGraceLeavesTheTurnPending() {
        let createdAt = Date()
        XCTAssertFalse(
            FileTransferOutputDetector.scanMayClose(
                turnCreatedAt: createdAt,
                scanStartedAt: createdAt,           // the landing probe: immediate
                everyProbeDefinitive: true,
                truncated: false
            ),
            "an instant, definitive pass must not be able to permanently close the turn"
        )
    }

    func testScanStartedJustBeforeTheDeadlineStillLeavesTheTurnPending() {
        let createdAt = Date()
        XCTAssertFalse(
            FileTransferOutputDetector.scanMayClose(
                turnCreatedAt: createdAt,
                scanStartedAt: createdAt.addingTimeInterval(grace - 1),
                everyProbeDefinitive: true,
                truncated: false
            )
        )
    }

    func testDefinitivePassAfterTheGraceWindowClosesTheTurn() {
        let createdAt = Date()
        XCTAssertTrue(
            FileTransferOutputDetector.scanMayClose(
                turnCreatedAt: createdAt,
                scanStartedAt: createdAt.addingTimeInterval(grace),
                everyProbeDefinitive: true,
                truncated: false
            ),
            "once the window has elapsed a definitive verdict is final"
        )
    }

    /// The gate reads when the pass STARTED, never the clock afterwards. Ten
    /// sequential probes against a slow server can outlive the grace window on
    /// their own; if the check ran after the loop, a 404 from the first
    /// millisecond would close the turn purely because the pass took a while.
    func testASlowPassThatBeganInsideGraceStillCannotClose() {
        let createdAt = Date()
        XCTAssertFalse(
            FileTransferOutputDetector.scanMayClose(
                turnCreatedAt: createdAt,
                scanStartedAt: createdAt.addingTimeInterval(1),   // started at +1s
                everyProbeDefinitive: true,
                truncated: false
            ),
            "the anchor is the pass's start, not however long its probes ran"
        )
    }

    /// A truncated examination is not a finished one: the pass never looked at
    /// the tail of the candidate list, so it holds the turn open far past the
    /// ordinary grace window while later passes walk the window forward.
    func testTruncatedPassDoesNotCloseAtTheOrdinaryGraceDeadline() {
        let createdAt = Date()
        XCTAssertFalse(
            FileTransferOutputDetector.scanMayClose(
                turnCreatedAt: createdAt,
                scanStartedAt: createdAt.addingTimeInterval(grace + 1),
                everyProbeDefinitive: true,
                truncated: true
            ),
            "a cut candidate list must not count as a completed scan"
        )
        XCTAssertTrue(
            FileTransferOutputDetector.scanMayClose(
                turnCreatedAt: createdAt,
                scanStartedAt: createdAt.addingTimeInterval(truncatedHorizon),
                everyProbeDefinitive: true,
                truncated: true
            ),
            "the extended window is a horizon, not 'forever' — re-probing an "
            + "identical all-miss window on every thread open learns nothing"
        )
    }

    /// A non-definitive probe outranks the clock: no amount of age makes an
    /// unauthorized/unreachable server into evidence about the file.
    func testNonDefinitiveProbeBlocksClosureAtAnyAge() {
        let createdAt = Date(timeIntervalSince1970: 0)
        XCTAssertFalse(
            FileTransferOutputDetector.scanMayClose(
                turnCreatedAt: createdAt,
                scanStartedAt: Date(),
                everyProbeDefinitive: false,
                truncated: false
            )
        )
    }

    // MARK: - hold policy (when a pending turn may be asked again)

    private let holdBase = Date(timeIntervalSince1970: 1_000_000)

    /// Inside the grace window nothing the pass finds can close the turn, so
    /// the only instant worth waking for is the gate itself.
    func testTooYoungHoldsUntilTheAgeGate() {
        XCTAssertEqual(
            ConversationDetailViewModel.holdVerdict(
                passStartedAt: holdBase,
                turnCreatedAt: holdBase,
                confirmedAnything: false,
                consecutiveStalls: 1
            ),
            .untilAgeGate(holdBase.addingTimeInterval(grace))
        )
    }

    /// The age gate outranks a confirmed file: a young turn is held even when
    /// the pass chipped something, because it still cannot be closed.
    func testTooYoungHoldsEvenAfterConfirmingAFile() {
        guard case .untilAgeGate = ConversationDetailViewModel.holdVerdict(
            passStartedAt: holdBase.addingTimeInterval(grace - 1),
            turnCreatedAt: holdBase,
            confirmedAnything: true,
            consecutiveStalls: 1
        ) else {
            return XCTFail("the age gate decides before anything else")
        }
    }

    /// A confirmed file is excluded from the next window, so the window walks
    /// onto candidates nothing has probed — that pass is worth running now.
    func testConfirmedFileReleasesImmediately() {
        XCTAssertEqual(
            ConversationDetailViewModel.holdVerdict(
                passStartedAt: holdBase.addingTimeInterval(grace),
                turnCreatedAt: holdBase,
                confirmedAnything: true,
                consecutiveStalls: 4
            ),
            .release,
            "a confirmed file walks the window on, whatever the turn's stall history"
        )
    }

    /// THE case this policy exists for: an aged turn that closed nothing and
    /// confirmed nothing would otherwise re-run its identical window on every
    /// coalesced store echo — up to `maxCandidates` requests against the user's
    /// own file server, for as long as `truncatedScanHorizon` keeps it open.
    func testAgedPassThatFoundNothingIsStalled() {
        XCTAssertEqual(
            ConversationDetailViewModel.holdVerdict(
                passStartedAt: holdBase.addingTimeInterval(grace),
                turnCreatedAt: holdBase,
                confirmedAnything: false,
                consecutiveStalls: 1
            ),
            .stalled(retryAfter: ConversationDetailViewModel.retroStalledRetryInterval),
            "one stall costs the ordinary interval — a transient failure must not be punished"
        )
    }

    /// THE unbounded case, and why the interval widens at all. A probe that is
    /// non-definitive but NOT lane-wide (`.ambiguous`) leaves `scanMayClose`
    /// shut with no horizon that can ever close the turn, while the lane breaker
    /// measures the lane HEALTHY — it can answer `404`, the failure is about one
    /// key. A hostile gateway mints that deterministically (a `.pdf` whose bytes
    /// open as HTML), so without the ladder the turn is re-probed twelve times an
    /// hour for the mounted lifetime of the thread, learning nothing every time.
    func testAStallThatKeepsRepeatingIsAskedEverMoreSlowly() {
        var intervals: [TimeInterval] = []
        for stalls in 1...5 {
            let verdict = ConversationDetailViewModel.holdVerdict(
                passStartedAt: holdBase.addingTimeInterval(grace),
                turnCreatedAt: holdBase,
                confirmedAnything: false,
                consecutiveStalls: stalls
            )
            guard case .stalled(let retryAfter) = verdict else {
                return XCTFail("an aged pass that found nothing stalls, at every rung")
            }
            intervals.append(retryAfter)
        }
        let expected: [TimeInterval] = [5 * 60, 15 * 60, 30 * 60, 60 * 60, 60 * 60]
        XCTAssertEqual(
            intervals,
            expected,
            "the ladder widens to a ceiling and stays there — never latching shut"
        )
    }

    /// The ladder is anchored on the STREAK, never on the turn's age, and this
    /// is the case that decides it: a turn synced from another device can be
    /// months old and suffer its FIRST transient probe failure today. An
    /// age-keyed rule would meet that with the slowest cadence and leave a file
    /// that exists undiscovered for an hour.
    func testAnOldTurnStallingForTheFirstTimeGetsTheFastCadence() {
        XCTAssertEqual(
            ConversationDetailViewModel.holdVerdict(
                passStartedAt: holdBase.addingTimeInterval(90 * 24 * 60 * 60),
                turnCreatedAt: holdBase,
                confirmedAnything: false,
                consecutiveStalls: 1
            ),
            .stalled(retryAfter: ConversationDetailViewModel.retroStalledRetryInterval)
        )
    }

    /// One ladder for both halves of the pair. The lane breaker widens how often
    /// a WALLED LANE is re-measured and this widens how often a going-nowhere
    /// TURN is re-probed; they answer the same question, and two ladders that
    /// must stay in step is a drift waiting to happen.
    func testTheStallLadderIsTheBreakerLadder() {
        for stalls in 0...6 {
            XCTAssertEqual(
                ConversationDetailViewModel.retroStallBackoff(forConsecutiveStalls: stalls),
                FileLaneScanBreaker.backoff(forConsecutiveFaults: stalls)
            )
        }
    }

    /// One timer, for the SOONEST held turn. An earlier wake is never wrong —
    /// it releases only what is due and re-arms for the rest — so the timer
    /// always tracks the first thing that can change.
    func testEarliestHoldDeadlineIsTheSoonestHold() {
        let holds = [
            UUID(): holdBase.addingTimeInterval(90),
            UUID(): holdBase.addingTimeInterval(60),
            UUID(): holdBase.addingTimeInterval(120)
        ]
        XCTAssertEqual(
            ConversationDetailViewModel.earliestHoldDeadline(in: holds),
            holdBase.addingTimeInterval(60)
        )
    }

    func testNoHoldsScheduleNothing() {
        XCTAssertNil(
            ConversationDetailViewModel.earliestHoldDeadline(in: [:]),
            "nothing waiting on the clock ⇒ no timer"
        )
    }

    /// WHY the deadlines are per id. One shared deadline releases every held
    /// turn at the soonest one, so a turn still inside its own window goes back
    /// to the reload path and re-asks the user's file server a question it
    /// answered moments ago. Only the due id is released here.
    func testWakeReleasesOnlyTheHoldsThatAreDue() {
        let due = UUID()
        let notYet = UUID()
        let holds = [
            due: holdBase.addingTimeInterval(60),
            notYet: holdBase.addingTimeInterval(300)
        ]
        XCTAssertEqual(
            ConversationDetailViewModel.dueHoldIDs(
                in: holds,
                asOf: holdBase.addingTimeInterval(60)
            ),
            [due],
            "a hold whose own window has not elapsed stays held"
        )
    }

    /// The deadline itself is inclusive: at the instant the window closes the
    /// question can have a different answer, which is the whole point of it.
    func testHoldIsDueAtItsDeadline() {
        let held = UUID()
        let holds = [held: holdBase]
        XCTAssertEqual(
            ConversationDetailViewModel.dueHoldIDs(in: holds, asOf: holdBase),
            [held]
        )
    }

    /// A wake that finds nothing due — the shape a backward wall-clock step
    /// produces — releases nothing and runs no pass; the caller re-arms.
    func testNothingIsDueBeforeAnyDeadline() {
        let holds = [UUID(): holdBase, UUID(): holdBase.addingTimeInterval(300)]
        XCTAssertTrue(
            ConversationDetailViewModel.dueHoldIDs(
                in: holds,
                asOf: holdBase.addingTimeInterval(-10)
            ).isEmpty
        )
    }

    // MARK: - park / release arithmetic (what makes the breaker's saving real)

    private func reconciliation(
        _ messageID: UUID,
        markScanned: Bool,
        drafts: [AttachmentDraft] = []
    ) -> ConversationStore.OutputScanReconciliation {
        .init(
            messageID: messageID,
            drafts: drafts,
            markScanned: markScanned,
            expectedLaneID: ownedLaneID
        )
    }

    /// THE arithmetic the request reduction rests on. A suppressed pass has to
    /// park every candidate it did not SETTLE — including the ones the loop
    /// never reached, which is the easy half to get wrong because they produced
    /// no result to iterate. An id left out here is an id the next
    /// `.conversationsDidChange` echo re-selects immediately, and the pass that
    /// was supposed to stop fans out again at a lane already shown to be unable
    /// to answer.
    func testParkSetIsEveryCandidateTheSuppressedPassDidNotSettle() {
        let closedLocally = UUID()      // listed and definitively finished
        let closedByProbe = UUID()      // probed and definitively finished
        let probedButOpen = UUID()      // probed, came back non-definitive
        let neverReached = UUID()       // the loop stopped before it

        XCTAssertEqual(
            ConversationDetailViewModel.retroScanParkSet(
                candidateIDs: [closedLocally, closedByProbe, probedButOpen, neverReached],
                listedResults: [
                    reconciliation(closedLocally, markScanned: true),
                    reconciliation(closedByProbe, markScanned: true),
                    reconciliation(probedButOpen, markScanned: false)
                ]
            ),
            [probedButOpen, neverReached]
        )
    }

    /// A probed turn that CONFIRMED a file but stayed open is still unsettled —
    /// its window has more to say. Parking is about whether the turn is finished,
    /// never about whether the pass got something out of it.
    func testAConfirmedButStillOpenTurnIsParked() {
        let confirmedStillOpen = UUID()
        XCTAssertEqual(
            ConversationDetailViewModel.retroScanParkSet(
                candidateIDs: [confirmedStillOpen],
                listedResults: [
                    reconciliation(
                        confirmedStillOpen,
                        markScanned: false,
                        drafts: [serverRef("out.pdf")]
                    )
                ]
            ),
            [confirmedStillOpen]
        )
    }

    func testNothingIsParkedWhenEveryCandidateSettled() {
        let a = UUID()
        let b = UUID()
        XCTAssertTrue(
            ConversationDetailViewModel.retroScanParkSet(
                candidateIDs: [a, b],
                listedResults: [
                    reconciliation(a, markScanned: true),
                    reconciliation(b, markScanned: true)
                ]
            ).isEmpty
        )
    }

    /// A park moves BOTH halves or it is silently ineffective: the hold is what
    /// the wake reads, and the attempt ownership is what stops a reload echo
    /// from re-selecting the turn in the meantime.
    func testParkTakesOwnershipAndHoldsEveryParkedID() {
        let alreadyOwned = UUID()
        let parkedA = UUID()
        let parkedB = UUID()
        let deadline = holdBase.addingTimeInterval(900)

        let next = ConversationDetailViewModel.parkedRetroScanState(
            attempted: [alreadyOwned],
            holds: [:],
            parking: [parkedA, parkedB],
            until: deadline
        )
        XCTAssertEqual(next.attempted, [alreadyOwned, parkedA, parkedB])
        XCTAssertEqual(next.holds, [parkedA: deadline, parkedB: deadline])
    }

    /// The latest decision wins for an id already held — every hold is a fresh
    /// verdict from the pass that just examined that turn, and a widening lane
    /// backoff has to be able to push a deadline OUT.
    func testParkOverwritesAnEarlierHoldForTheSameID() {
        let held = UUID()
        let widened = holdBase.addingTimeInterval(3600)
        let next = ConversationDetailViewModel.parkedRetroScanState(
            attempted: [held],
            holds: [held: holdBase.addingTimeInterval(300)],
            parking: [held],
            until: widened
        )
        XCTAssertEqual(next.holds[held], widened)
    }

    /// A release hands back EXACTLY the held ids. An id that was attempted but
    /// never held belongs to a pass still deciding about it — handing that one
    /// back would let two passes probe one turn.
    func testReleaseHandsBackExactlyTheHeldIDs() {
        let held = UUID()
        let attemptedNotHeld = UUID()
        let next = ConversationDetailViewModel.releasedRetroScanState(
            attempted: [held, attemptedNotHeld],
            holds: [held: holdBase]
        )
        XCTAssertEqual(next.attempted, [attemptedNotHeld])
        XCTAssertTrue(next.holds.isEmpty, "the map empties — nothing is left waiting on a timer")
    }

    // MARK: - lane key derivation

    private func snapshot(
        base: String = "https://files.example.test",
        credential: String = "deadbeefdeadbeefdeadbeefdeadbeef",
        fingerprint: String? = nil
    ) -> SettingsManager.FileTransferSnapshot {
        SettingsManager.FileTransferSnapshot(
            baseURL: URL(string: base)!,
            username: Constants.fileServerUsername,
            credential: credential,
            certFingerprintHex: fingerprint,
            available: true,
            folderCapable: true
        )
    }

    /// The breaker is keyed on URL + credential AND the device-local certificate
    /// pin, so every repair a user can make lands on a brand-new key with a clean
    /// slate. A pin fix is the one that would otherwise move no tracked value and
    /// leave the lane suppressed after the user had already fixed it.
    func testLaneKeyMovesWithEitherHalfOfTheIdentity() {
        let base = snapshot()
        let key = FileLaneScanBreaker.laneKey(for: base)

        XCTAssertEqual(key, FileLaneScanBreaker.laneKey(for: snapshot()),
                       "an unchanged lane keeps its history")
        XCTAssertNotEqual(key, FileLaneScanBreaker.laneKey(for: snapshot(base: "https://other.example.test")))
        XCTAssertNotEqual(key, FileLaneScanBreaker.laneKey(for: snapshot(credential: "0123456789abcdef0123456789abcdef")))
        XCTAssertNotEqual(key, FileLaneScanBreaker.laneKey(for: snapshot(fingerprint: "AA:BB:CC")),
                          "a pin-only repair must reopen the lane")
    }

    /// Readiness and folder-capability are VERDICTS about a lane, not its
    /// identity — they move on their own as probes land, and letting them mint a
    /// new key would silently discard a backoff mid-window.
    func testLaneKeyIgnoresTheMutableVerdictFields() {
        let stable = SettingsManager.FileTransferSnapshot(
            baseURL: URL(string: "https://files.example.test")!,
            username: Constants.fileServerUsername,
            credential: "deadbeefdeadbeefdeadbeefdeadbeef",
            certFingerprintHex: nil,
            available: false,
            folderCapable: false
        )
        XCTAssertEqual(
            FileLaneScanBreaker.laneKey(for: stable),
            FileLaneScanBreaker.laneKey(for: snapshot())
        )
    }
}
