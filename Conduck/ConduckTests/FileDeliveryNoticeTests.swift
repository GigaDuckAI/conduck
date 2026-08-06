// SPDX-License-Identifier: Apache-2.0

// Conduck
// FileDeliveryNoticeTests.swift
//
// The selector behind the inbound "your file got there, and that is all Conduck
// can see" row. `FileDeliveryNotice` reads turn STRUCTURE and nothing else, so
// this file is about which shapes count as proof of a delivery — not about
// wording, and deliberately not about reply text, which the production code
// never touches.
//
// The cases that matter are the ones that LOOK delivered and are not. Two are
// real shapes the store produces, and both would put a "delivered" caption on a
// turn that delivered nothing:
//
//   • the CLONE TOMBSTONE — `ConversationStore.copyAttachments` keeps
//     `isServerReference` while detaching `storedKey` when the destination lane
//     does not carry, so the flag alone survives onto a turn whose file is
//     unreachable;
//   • the FAILED or IN-FLIGHT send — a turn can hold a fully uploaded server
//     reference while its request never landed, and a failed one already draws
//     the delivery-error row.
//
// The suppressed-but-genuine direction is asserted too (the dual-route uploads,
// which put bytes on the server while leaving `isServerReference` false), so the
// stated cost in `noticeTurnID` stays a decision rather than drifting into a bug.

import XCTest
@testable import Conduck

final class FileDeliveryNoticeTests: XCTestCase {

    // MARK: - Fixtures

    private let laneID = String(repeating: "a", count: 64)

    /// One turn. `serverFileKeys` builds the ordinary delivered attachment (flag
    /// AND key); `flagOnlyCount` builds the clone tombstone (flag, no key); and
    /// `keyOnlyKeys` builds the dual-route shape (key, no flag) — the three
    /// combinations the selector has to tell apart.
    private func turn(
        role: String = "user",
        status: String? = "sent",
        fileTransferLaneID: String? = nil,
        serverFileKeys: [String] = [],
        keyOnlyKeys: [String] = [],
        flagOnlyCount: Int = 0,
        secondsAfterEpoch: TimeInterval = 0
    ) -> MessageRecord {
        var attachments: [AttachmentRecord] = []
        func append(key: String?, isServerReference: Bool) {
            attachments.append(AttachmentRecord(
                id: UUID(),
                mimeType: "application/pdf",
                filename: key,
                thumbnailData: nil,
                extractedText: nil,
                width: 0,
                height: 0,
                byteSize: 0,
                sequence: attachments.count,
                createdAt: Date(timeIntervalSince1970: 0),
                isServerReference: isServerReference,
                storedKey: key
            ))
        }
        for key in serverFileKeys { append(key: key, isServerReference: true) }
        for key in keyOnlyKeys { append(key: key, isServerReference: false) }
        for _ in 0..<flagOnlyCount { append(key: nil, isServerReference: true) }
        return MessageRecord(
            id: UUID(),
            role: role,
            text: "",
            createdAt: Date(timeIntervalSince1970: secondsAfterEpoch),
            sourceDevice: "iphone",
            status: status,
            fileTransferLaneID: fileTransferLaneID ?? laneID,
            attachments: attachments
        )
    }

    /// A turn that satisfies every test — the baseline each negative case takes
    /// exactly one thing away from.
    private func deliveredTurn(secondsAfterEpoch: TimeInterval = 0) -> MessageRecord {
        turn(serverFileKeys: ["ab__report.pdf"], secondsAfterEpoch: secondsAfterEpoch)
    }

    // MARK: - The qualifying shape

    func testASentUserTurnWithAnOwnedServerFileQualifies() {
        XCTAssertTrue(FileDeliveryNotice.deliveredAFile(deliveredTurn()))
    }

    // MARK: - The shapes that must NOT qualify

    func testAgentTurnNeverQualifies() {
        XCTAssertFalse(FileDeliveryNotice.deliveredAFile(
            turn(role: "agent", serverFileKeys: ["ab__out.pdf"])
        ), "Only the user's own turn can carry an upload.")
    }

    func testFailedSendDoesNotQualify() {
        XCTAssertFalse(FileDeliveryNotice.deliveredAFile(
            turn(status: "failed", serverFileKeys: ["ab__report.pdf"])
        ), "A failed turn already draws the delivery-error row; it never also says delivered.")
    }

    func testInFlightSendDoesNotQualify() {
        XCTAssertFalse(FileDeliveryNotice.deliveredAFile(
            turn(status: "sending", serverFileKeys: ["ab__report.pdf"])
        ), "A send that has not landed has not delivered anything yet.")
    }

    func testLegacyNilStatusDoesNotQualify() {
        XCTAssertFalse(FileDeliveryNotice.deliveredAFile(
            turn(status: nil, serverFileKeys: ["ab__report.pdf"])
        ), "A nil status predates the file-transfer route and is never evidence of a delivery.")
    }

    func testMissingLaneIdentityDoesNotQualify() {
        var attachments: [AttachmentRecord] = []
        attachments.append(AttachmentRecord(
            id: UUID(),
            mimeType: "application/pdf",
            filename: "ab__report.pdf",
            thumbnailData: nil,
            extractedText: nil,
            width: 0, height: 0, byteSize: 0, sequence: 0,
            createdAt: Date(timeIntervalSince1970: 0),
            isServerReference: true,
            storedKey: "ab__report.pdf"
        ))
        let ownerless = MessageRecord(
            id: UUID(),
            role: "user",
            text: "",
            createdAt: Date(timeIntervalSince1970: 0),
            sourceDevice: "iphone",
            status: "sent",
            fileTransferLaneID: nil,
            attachments: attachments
        )
        XCTAssertFalse(FileDeliveryNotice.deliveredAFile(ownerless),
                       "Without a latched lane there is no proof the handoff happened.")
    }

    func testCloneTombstoneDoesNotQualify() {
        XCTAssertFalse(FileDeliveryNotice.deliveredAFile(turn(flagOnlyCount: 1)),
                       """
                       A clone onto a lane that does not carry keeps `isServerReference` and \
                       detaches `storedKey`; that row addresses nothing on any server.
                       """)
    }

    func testEmptyStoredKeyIsTreatedAsDetached() {
        XCTAssertFalse(FileDeliveryNotice.deliveredAFile(turn(serverFileKeys: [""])),
                       "An empty key is a detached key, not a shorter one.")
    }

    func testDualRouteUploadIsSuppressedByDesign() {
        XCTAssertFalse(FileDeliveryNotice.deliveredAFile(turn(keyOnlyKeys: ["ab__notes.md"])),
                       """
                       The dual routes upload real bytes while leaving `isServerReference` false. \
                       Suppressing them is the stated cost in `noticeTurnID` — if this ever starts \
                       passing, that comment is wrong.
                       """)
    }

    func testTurnWithNoAttachmentsDoesNotQualify() {
        XCTAssertFalse(FileDeliveryNotice.deliveredAFile(turn()))
    }

    // MARK: - One row per conversation, on the newest qualifying turn

    func testPicksTheNewestQualifyingTurn() {
        let older = deliveredTurn(secondsAfterEpoch: 10)
        let newer = deliveredTurn(secondsAfterEpoch: 30)
        let thread = [
            older,
            turn(role: "agent", status: nil, secondsAfterEpoch: 20),
            newer,
            turn(role: "agent", status: nil, secondsAfterEpoch: 40),
        ]
        XCTAssertEqual(FileDeliveryNotice.noticeTurnID(in: thread), newer.id,
                       "The row belongs to the exchange in progress, not to thread history.")
    }

    func testSkipsNonQualifyingTurnsAfterAQualifyingOne() {
        let delivered = deliveredTurn(secondsAfterEpoch: 10)
        let thread = [
            delivered,
            turn(status: "failed", serverFileKeys: ["ab__later.pdf"], secondsAfterEpoch: 20),
            turn(flagOnlyCount: 1, secondsAfterEpoch: 30),
        ]
        XCTAssertEqual(FileDeliveryNotice.noticeTurnID(in: thread), delivered.id)
    }

    func testThreadWithNoDeliveryGetsNoNotice() {
        XCTAssertNil(FileDeliveryNotice.noticeTurnID(in: [
            turn(secondsAfterEpoch: 10),
            turn(role: "agent", status: nil, secondsAfterEpoch: 20),
        ]))
    }

    func testEmptyThreadGetsNoNotice() {
        XCTAssertNil(FileDeliveryNotice.noticeTurnID(in: []))
    }
}
