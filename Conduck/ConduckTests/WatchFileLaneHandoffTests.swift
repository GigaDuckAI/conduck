// SPDX-License-Identifier: Apache-2.0

// Conduck
// WatchFileLaneHandoffTests.swift
//
// Locks the chain that makes a WATCH-originated agent reply eligible for the
// retroactive output-file scan. The wrist dispatches its own converse turns and
// asks the agent to hand a file back (the spoken clause names the file
// explicitly BECAUSE the user is on a compact device), but the wrist can never
// download one — files are an iPhone/iPad/Mac capability. Its only job is to
// record WHICH file lane the turn invited a file into, so a capable device can
// finish the job when the thread is next opened.
//
// That provenance travels three hops, each of which can only degrade to "no
// lane" and never to "the wrong lane":
//
//   1. iPhone → Watch     `RemoteAgentBroadcastEnvelope.fileTransferLaneID`
//                         (the wrist cannot derive it — the file-server
//                         credential never syncs there)
//   2. dispatch → landing `RemoteAgentBackgroundMetadata.fileTransferLaneID`
//                         (survives suspension + a cross-launch recycle, and
//                         pins the DISPATCH-time lane so a settings edit
//                         mid-turn cannot re-credit the reply)
//   3. landing → store    `Message.outputScanLaneID` + `outputBoxKey` +
//                         `outputScanDone = false` (the triple
//                         `retroScanCandidates` admits — the folder is what a
//                         capable device actually reads, and a row missing it
//                         is selected OUT rather than closed)
//
// Break any hop and the turn is not merely late — it is invisible to the scan
// PERMANENTLY, because a conclusive pass stamps `outputScanDone` for good and a
// row that never became a candidate never gets a second look.
//
// The hop BEFORE these — whether the wrist names a folder at all — lives in the
// watchOS target and is locked by `ConduckWatchTests/WatchOutboxMintGateTests`.
// It is gated on the lane identity, so the pair hop 3 requires is minted whole
// or not at all; the `box: nil` fixture below therefore models a row this device
// synced ahead of the attribute, never a dispatch that named a folder with no
// lane behind it.
//
// Deterministic + headless: no network, no Core Data, no Keychain, no WCSession.
// Production types end to end; synthetic lane digests and filenames only.

import XCTest
@testable import Conduck

@MainActor
final class WatchFileLaneHandoffTests: XCTestCase {

    // MARK: - Fixtures

    /// Canonical shape: 64 lowercase hex, what `FileTransferSnapshot.durableLaneID`
    /// emits. Two distinct lanes stand in for "before" and "after" a repoint.
    private let laneA = String(repeating: "ab", count: 32)
    private let laneB = String(repeating: "cd", count: 32)

    /// The wrist's converse envelope for a ref whose lane is READY.
    private func envelope(lane: String?, ready: Bool = true) throws -> RemoteAgentBroadcastEnvelope {
        RemoteAgentBroadcastEnvelope(
            backendRef: "openclaw",
            url: try XCTUnwrap(URL(string: "https://gateway.example.test")),
            name: nil, model: nil, colorID: nil, monogram: nil,
            token: "t", certFingerprintHex: nil,
            fileTransferAvailable: ready,
            fileTransferLaneID: lane,
            activeSessionID: nil,
            timestamp: 1.0
        )
    }

    /// The row the wrist's landing path writes: a plain agent append carrying
    /// the dispatch-time lane AND the folder the wrist named, exactly as
    /// `ConversationStore.appendMessage` materializes it (`outputScanDone` false
    /// iff an owner lane exists).
    ///
    /// The wrist names a folder with no credential and no round trip — naming a
    /// path needs neither — so both halves land together. `box: nil` stands in
    /// for the row a device syncs before that attribute arrives.
    private func watchReply(lane: String?, text: String, box: String? = "conv/out-abc") -> MessageRecord {
        MessageRecord(
            id: UUID(),
            role: "agent",
            text: text,
            createdAt: Date(timeIntervalSince1970: 0),
            sourceDevice: "watch",
            outputScanDone: lane == nil ? nil : false,
            outputScanLaneID: lane,
            outputBoxKey: lane == nil ? nil : box
        )
    }

    // MARK: - Hop 1 → 2: envelope to task metadata

    /// The couriered lane reaches the background task intact through a full
    /// wire + `taskDescription` round-trip. `taskDescription` is the ONLY thing
    /// that survives a mid-turn process kill, so the lane has to live there
    /// rather than in memory.
    func testCourieredLaneReachesTaskMetadata() throws {
        let decoded = try XCTUnwrap(
            RemoteAgentBroadcastEnvelope.decode(from: try envelope(lane: laneA).encodedDict())
        )
        let metadata = RemoteAgentBackgroundMetadata(
            bodyPath: "/tmp/body.json",
            conversationID: UUID().uuidString,
            backendRawValue: "openclaw",
            stampsActiveConversation: true,
            fileTransferLaneID: decoded.fileTransferLaneID
        )
        let recovered = try RemoteAgentBackgroundMetadata.decode(metadata.encodedString())
        XCTAssertEqual(recovered.fileTransferLaneID, laneA,
                       "The dispatch-time lane must survive the taskDescription round-trip.")
    }

    /// An IN-FLIGHT task enqueued before the courier existed decodes with no
    /// lane rather than failing — the reply still lands, it just can't be
    /// scanned. Missing evidence, never invented evidence.
    func testPreUpgradeTaskMetadataDecodesWithoutLane() throws {
        let legacyBlob = """
        {"bodyPath":"/tmp/body.json","conversationID":"\(UUID().uuidString)","backendRawValue":"openclaw"}
        """
        let recovered = try RemoteAgentBackgroundMetadata.decode(legacyBlob)
        XCTAssertNil(recovered.fileTransferLaneID,
                     "A pre-courier taskDescription must decode as no-lane, not throw.")
    }

    // MARK: - Hop 3: the stamped row is a retro-scan candidate

    /// THE defect this locks: a Watch reply stamped with its dispatch lane is
    /// admitted by the candidate filter. Unstamped, it is excluded forever.
    func testStampedWatchReplyIsRetroScanCandidate() throws {
        let decoded = try XCTUnwrap(
            RemoteAgentBroadcastEnvelope.decode(from: try envelope(lane: laneA).encodedDict())
        )
        let stamped = watchReply(lane: decoded.fileTransferLaneID, text: "Wrote report.pdf for you.")
        let out = ConversationDetailViewModel.retroScanCandidates(
            in: [stamped], attempted: [], cap: 20
        )
        XCTAssertEqual(out.map(\.id), [stamped.id],
                       "A Watch reply carrying its dispatch lane must be eligible for the retro scan.")
    }

    /// The pre-courier world, asserted as the thing that changed: a wrist reply
    /// with no lane is silently and permanently invisible to the scan.
    func testUnstampedWatchReplyIsNeverACandidate() {
        let unstamped = watchReply(lane: nil, text: "Wrote report.pdf for you.")
        let out = ConversationDetailViewModel.retroScanCandidates(
            in: [unstamped], attempted: [], cap: 20
        )
        XCTAssertTrue(out.isEmpty,
                      "Without a provable lane a wrist turn can never be scanned — that is the defect.")
    }

    /// A row that reached this device AHEAD of its folder attribute is selected
    /// OUT of the pass, never closed. Missing metadata means UNKNOWN: closing it
    /// would make "we have not been told yet" permanently indistinguishable from
    /// "there was nothing", on the device least able to know.
    func testWatchReplyWithoutABoxIsSelectedOutRatherThanClosed() {
        let laneOnly = watchReply(lane: laneA, text: "Wrote report.pdf for you.", box: nil)
        XCTAssertEqual(laneOnly.outputScanDone, false,
                       "The row stays PENDING — nothing about it is settled.")
        XCTAssertTrue(
            ConversationDetailViewModel.retroScanCandidates(in: [laneOnly], attempted: [], cap: 20).isEmpty,
            "No folder means no listing, and no marker either."
        )
    }

    /// OLD iPHONE → NEW WATCH. Readiness arrives (so the turn still carries the
    /// file-delivery instruction) but no lane does, so the reply lands
    /// unstamped: today's behavior preserved exactly, no crash, no lost turn.
    func testLegacyPhoneEnvelopeYieldsNoStamp() throws {
        let legacyDict: [String: Any] = [
            "backend": "openclaw",
            "url": "https://gateway.example.test",
            "timestamp": 1.0,
            "fileTransferAvailable": true,
        ]
        let decoded = try XCTUnwrap(RemoteAgentBroadcastEnvelope.decode(from: legacyDict))
        XCTAssertTrue(decoded.fileTransferAvailable,
                      "A legacy sender still asks for the file — only the provenance is missing.")
        let landed = watchReply(lane: decoded.fileTransferLaneID, text: "Wrote report.pdf for you.")
        XCTAssertTrue(
            ConversationDetailViewModel.retroScanCandidates(in: [landed], attempted: [], cap: 20).isEmpty,
            "A legacy-phone wrist turn must degrade to unscannable, never to a guessed lane."
        )
    }

    // MARK: - Routing: the stamp authorizes a probe of exactly ONE lane

    /// Stamped lane == the currently configured lane → the scan may probe.
    func testStampedWatchReplyProbesItsOwnLane() async {
        let route = ConversationDetailViewModel.retroOutputScanRoute(
            for: watchReply(lane: laneA, text: "Saved summary.md to the working directory."),
            currentLaneID: laneA
        )
        XCTAssertEqual(route, .probeCurrentLane,
                       "A matching lane is the only thing that authorizes a network probe.")
    }

    /// The user repoints the file server between the wrist dispatch and opening
    /// the thread. The stamp still names lane A, the device now has lane B, so
    /// the scan refuses: a missed chip, never a file pulled from an unrelated
    /// server. Restoring lane A later lets the same turn recover.
    func testRepointedLaneDefersRatherThanProbingTheWrongServer() async {
        let route = ConversationDetailViewModel.retroOutputScanRoute(
            for: watchReply(lane: laneA, text: "Saved summary.md to the working directory."),
            currentLaneID: laneB
        )
        XCTAssertEqual(route, .deferUntilMatchingLane,
                       "A wrist turn must never be finished against a lane it was not dispatched for.")
    }

    /// THE REPLY TEXT DOES NOT ROUTE. A wrist reply that names no file and one
    /// that names several take the identical route, because what a capable
    /// device reads is the folder this dispatch named — never the prose. The
    /// lane match is the whole decision.
    func testReplyTextDoesNotChangeTheRoute() {
        let named = ConversationDetailViewModel.retroOutputScanRoute(
            for: watchReply(lane: laneA, text: "Saved summary.md and notes.csv for you."),
            currentLaneID: laneA
        )
        let silent = ConversationDetailViewModel.retroOutputScanRoute(
            for: watchReply(lane: laneA, text: "All done — nothing to hand back."),
            currentLaneID: laneA
        )
        XCTAssertEqual(named, silent,
                       "Prose is not a routing input: both replies get the same one listing.")
        XCTAssertEqual(silent, .probeCurrentLane)
    }

    /// A lane the device no longer has defers whatever the reply says — the
    /// stamp creates no traffic against a server this turn was not dispatched to.
    func testMissingLaneDefersWhateverTheReplySays() {
        let route = ConversationDetailViewModel.retroOutputScanRoute(
            for: watchReply(lane: laneA, text: "All done — nothing to hand back."),
            currentLaneID: nil
        )
        XCTAssertEqual(route, .deferUntilMatchingLane,
                       "No matching lane means no listing, and no marker either.")
    }
}
