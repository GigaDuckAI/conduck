// SPDX-License-Identifier: Apache-2.0

// Conduck
// RetroOutputScanCandidateTests.swift
//
// Locks the PURE decision halves of the retroactive output-file scan (the
// network + store plumbing is singleton/CloudKit-bound and covered by the
// founder's on-device QA):
//   • `ConversationDetailViewModel.retroScanCandidates(in:attempted:cap:)` —
//     the turn-selection filter: only explicitly-pending agent turns
//     (`outputScanDone == false`) with an exact durable output lane, skipping
//     ownerless legacy, already-scanned, and already-attempted turns,
//     newest-first and capped. A partial-success turn (already carrying a
//     server-ref chip while still pending) is STILL selected so its missing
//     candidates can retry.
//   • `FileTransferOutputDetector.probeIsConclusive(_:)` — the probe-outcome →
//     scan-completeness mapping that decides whether a pass may stamp
//     `outputScanDone` (only a definitive present/absent verdict does).
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

    // `retroOutputScanRoute` is `async` because the candidate extraction is
    // hopped off the main actor (its regex is superlinear in untrusted reply
    // length). Every awaited value is hoisted into a `let` BEFORE the assertion:
    // `XCTAssert*` autoclosures are not concurrency-aware and will not compile
    // with an `await` inside them.
    func testMacCandidateRoutesOnlyToMatchingCurrentLane() async {
        let laneA = String(repeating: "a", count: 64)
        let turn = message(
            role: "agent",
            sourceDevice: "mac",
            text: "Done: output.pdf",
            outputScanDone: false,
            outputScanLaneID: laneA
        )

        let matchingLane = await ConversationDetailViewModel.retroOutputScanRoute(
            for: turn,
            currentLaneID: laneA
        )
        XCTAssertEqual(matchingLane, .probeCurrentLane)

        let repointedLane = await ConversationDetailViewModel.retroOutputScanRoute(
            for: turn,
            currentLaneID: String(repeating: "b", count: 64)
        )
        XCTAssertEqual(
            repointedLane,
            .deferUntilMatchingLane,
            "repointing A to B must result in zero B probes"
        )

        let removedLane = await ConversationDetailViewModel.retroOutputScanRoute(
            for: turn,
            currentLaneID: nil
        )
        XCTAssertEqual(
            removedLane,
            .deferUntilMatchingLane,
            "removing the current lane leaves A recoverable when restored"
        )
    }

    func testFilenameFreeMacReplyIsConclusiveWithoutCurrentLane() async {
        let turn = message(
            role: "agent",
            sourceDevice: "mac",
            text: "Done.",
            outputScanDone: false,
            outputScanLaneID: String(repeating: "a", count: 64)
        )
        let route = await ConversationDetailViewModel.retroOutputScanRoute(
            for: turn,
            currentLaneID: nil
        )
        XCTAssertEqual(route, .conclusiveWithoutProbe)
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
                    probe: { _ in
                        probes += 1
                        return ([], true)
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
                probe: { _ in
                    probes += 1
                    return ([], true)
                }
            )

        guard case .probed = execution else {
            return XCTFail("the exact durable lane should reach the probe closure")
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
                probe: { _ in
                    probes += 1
                    return ([self.serverRef("watch-output.pdf")], true)
                }
            )

        guard case .deferred = execution else {
            return XCTFail("an ownerless legacy Watch turn must remain deferred")
        }
        XCTAssertEqual(probes, 0,
                       "without a durable dispatch-time lane, no server may be probed")
    }

    // MARK: - probeIsConclusive

    func testConclusiveOutcomes() {
        XCTAssertTrue(FileTransferOutputDetector.probeIsConclusive(.exists))
        XCTAssertTrue(FileTransferOutputDetector.probeIsConclusive(.missing),
                      "a definitive not-found still completes the scan")
    }

    func testInconclusiveOutcomes() {
        XCTAssertFalse(FileTransferOutputDetector.probeIsConclusive(.unauthorized))
        XCTAssertFalse(FileTransferOutputDetector.probeIsConclusive(.serverError))
        XCTAssertFalse(FileTransferOutputDetector.probeIsConclusive(.unknown),
                       "a transient/inconclusive probe must NOT let the pass mark scanned")
    }
}
