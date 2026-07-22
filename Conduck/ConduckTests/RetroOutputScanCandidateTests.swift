// Conduck
// RetroOutputScanCandidateTests.swift
//
// Locks the PURE decision halves of the retroactive output-file scan (the
// network + store plumbing is singleton/CloudKit-bound and covered by the
// founder's on-device QA):
//   • `ConversationDetailViewModel.retroScanCandidates(in:attempted:cap:)` —
//     the turn-selection filter: only agent turns that landed on a headless
//     surface (Watch / CarPlay, which run no output detection), skipping
//     already-scanned + already-attempted turns, newest-first, capped. A
//     partial-success turn (already carries a server-ref chip but is unmarked)
//     is STILL selected — its missing candidates must retry.
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

    private func message(
        id: UUID = UUID(),
        role: String,
        sourceDevice: String,
        outputScanDone: Bool? = nil,
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
            text: "",
            createdAt: Date(timeIntervalSince1970: 0),
            sourceDevice: sourceDevice,
            outputScanDone: outputScanDone,
            attachments: attachments
        )
    }

    private var candidates: [MessageRecord] {
        // A mix spanning every disposition the filter must decide.
        [
            message(role: "agent", sourceDevice: "watch"),          // ✓ selected
            message(role: "agent", sourceDevice: "carplay"),        // ✓ selected
            message(role: "agent", sourceDevice: "iphone"),         // ✗ capable surface ran detection
            message(role: "agent", sourceDevice: "mac"),            // ✗ capable surface
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

    func testCapableSurfacesAndUserTurnsExcluded() {
        let out = ConversationDetailViewModel.retroScanCandidates(
            in: candidates, attempted: [], cap: 20
        )
        XCTAssertFalse(out.contains { $0.sourceDevice == "iphone" || $0.sourceDevice == "mac" },
                       "iphone/mac agent turns already ran landing-path detection")
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

    /// A suffixed `sourceDevice` (`watch-voice`) must still resolve to the base
    /// device via `baseDevice`, or a modality-tagged Watch turn would never scan.
    func testSuffixedSourceDeviceTolerated() {
        let m = message(role: "agent", sourceDevice: "watch-voice")
        let out = ConversationDetailViewModel.retroScanCandidates(
            in: [m], attempted: [], cap: 20
        )
        XCTAssertEqual(out.map(\.id), [m.id], "baseDevice strips the modality suffix")
    }

    /// PARTIAL-success turn: already carries a server-ref chip but is unmarked
    /// (a prior pass confirmed some files, then hit a transient probe on the
    /// rest). It MUST still be selected so the missing candidates retry.
    func testPartialSuccessTurnStillSelected() {
        let m = message(role: "agent", sourceDevice: "watch",
                        outputScanDone: nil, storedKeys: ["already__chipped.pdf"])
        let out = ConversationDetailViewModel.retroScanCandidates(
            in: [m], attempted: [], cap: 20
        )
        XCTAssertEqual(out.map(\.id), [m.id],
                       "having a server-ref attachment does NOT exclude an unmarked turn")
    }

    func testCapLimitsCount() {
        let many = (0..<30).map { _ in message(role: "agent", sourceDevice: "watch") }
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
            message(id: UUID(uuidString: "00000000-0000-0000-0000-00000000000\(i)")!,
                    role: "agent", sourceDevice: "watch")
        }
        let out = ConversationDetailViewModel.retroScanCandidates(
            in: ordered, attempted: [], cap: 20
        )
        XCTAssertEqual(out.map(\.id), ordered.reversed().map(\.id),
                       "candidates come back newest-first")
    }

    func testNewestSurviveTheCap() {
        let ordered = (0..<5).map { i in
            message(id: UUID(uuidString: "00000000-0000-0000-0000-00000000000\(i)")!,
                    role: "agent", sourceDevice: "watch")
        }
        let out = ConversationDetailViewModel.retroScanCandidates(
            in: ordered, attempted: [], cap: 2
        )
        // Input ids end in 0..4; newest (4,3) survive a cap of 2.
        XCTAssertEqual(out.map(\.id), [ordered[4].id, ordered[3].id])
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
