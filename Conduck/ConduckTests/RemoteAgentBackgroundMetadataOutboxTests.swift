// SPDX-License-Identifier: Apache-2.0

// Conduck
// RemoteAgentBackgroundMetadataOutboxTests.swift
//
// Locks `RemoteAgentBackgroundMetadata.outputBoxKey` — the channel that carries
// this turn's output folder across a process kill, since a relaunched delegate
// has nothing but `taskDescription` to tell it where the reply was told to
// write. Pins the ADDITIVE + TOLERANT contract every field in that envelope
// keeps:
//   • a `taskDescription` written by a build that never had the field still
//     decodes, with `outputBoxKey == nil` — a decode failure would strand the
//     whole in-flight turn, not just the folder;
//   • the value round-trips unchanged;
//   • omitting it at a construction site is legal and yields nil, so no existing
//     enqueue site had to change.
//
// Pure Codable coverage — no network, no session, no store.

import XCTest
@testable import Conduck

final class RemoteAgentBackgroundMetadataOutboxTests: XCTestCase {

    private let outboxKey = "6C5A2F1E-0000-4000-8000-000000000001/out-0123456789abcdef0123456789abcdef"

    func testOutputBoxKeyRoundTrips() throws {
        let metadata = RemoteAgentBackgroundMetadata(
            bodyPath: "/tmp/body.json",
            conversationID: UUID().uuidString,
            backendRawValue: "openclaw",
            fileTransferLaneID: String(repeating: "b", count: 64),
            outputBoxKey: outboxKey
        )

        let decoded = try RemoteAgentBackgroundMetadata.decode(metadata.encodedString())

        XCTAssertEqual(decoded.outputBoxKey, outboxKey)
        XCTAssertEqual(decoded.fileTransferLaneID, metadata.fileTransferLaneID)
        XCTAssertEqual(decoded.bodyPath, metadata.bodyPath)
    }

    func testMetadataWrittenBeforeTheFieldExistedStillDecodes() throws {
        // Byte-shape of a `taskDescription` enqueued by an older build: every
        // key it knew, and no `outputBoxKey`.
        let legacy = """
        {"bodyPath":"/tmp/body.json",\
        "conversationID":"6C5A2F1E-0000-4000-8000-000000000001",\
        "backendRawValue":"openclaw",\
        "refRawValue":"custom_6c5a2f1e-0000-4000-8000-000000000002",\
        "fileTransferLaneID":"\(String(repeating: "c", count: 64))"}
        """

        let decoded = try RemoteAgentBackgroundMetadata.decode(legacy)

        XCTAssertNil(decoded.outputBoxKey, "an absent key decodes to nil, never a decode failure")
        XCTAssertEqual(decoded.backendRawValue, "openclaw")
        XCTAssertEqual(decoded.fileTransferLaneID, String(repeating: "c", count: 64))
    }

    func testOmittingTheFieldAtConstructionYieldsNil() throws {
        let metadata = RemoteAgentBackgroundMetadata(
            bodyPath: "/tmp/body.json",
            conversationID: UUID().uuidString,
            backendRawValue: "hermes"
        )

        XCTAssertNil(metadata.outputBoxKey)
        XCTAssertNil(try RemoteAgentBackgroundMetadata.decode(metadata.encodedString()).outputBoxKey)
    }

    func testEncodedFormOmitsTheFieldWhenNil() throws {
        let metadata = RemoteAgentBackgroundMetadata(
            bodyPath: "/tmp/body.json",
            conversationID: UUID().uuidString,
            backendRawValue: "hermes"
        )

        // A nil Optional is omitted by the synthesized encoder, which is what
        // makes an older DECODER tolerate a newer writer symmetrically.
        XCTAssertFalse(try metadata.encodedString().contains("outputBoxKey"))
    }
}
