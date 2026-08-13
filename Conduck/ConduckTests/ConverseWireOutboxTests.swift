// SPDX-License-Identifier: Apache-2.0

//
//  ConverseWireOutboxTests.swift
//  ConduckTests
//
//  WHERE THE OUTBOX LOCATION MAY AND MAY NOT APPEAR ON THE WIRE.
//
//  The line is a NEW splice in `assembleMessages` and nowhere else. The trap it
//  exists to hold shut: every `splice*Refs` helper runs once per REPLAYED prior
//  record and on BOTH roles, so a location clause inside one would duplicate
//  across the whole resent history — each copy naming the finished folder of a
//  turn that is already over. The agent would then be looking at four folders
//  and told all of them are "for this reply".
//
//  A past turn's DELIVERED file keeps riding the ordinary input-ref path under
//  its full key, and that is correct: it tells the agent where its own earlier
//  output lives.
//

import XCTest
@testable import Conduck

final class ConverseWireOutboxTests: XCTestCase {

    /// The lane a fixture's records claim to own, so `priorTurns` treats their
    /// storedKeys as reachable.
    private static let ownedLaneID = String(repeating: "b", count: 64)

    private static func encodeWire(
        _ messages: [ConverseRequest.Message]
    ) throws -> [[String: Any]] {
        let data = try JSONEncoder().encode(ConverseRequest(messages: messages, stream: false))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try XCTUnwrap(json["messages"] as? [[String: Any]])
    }

    private static func box(_ conversationID: UUID = UUID()) -> String {
        OutboxKey.mint(conversationID: conversationID)
    }

    private static func allText(_ wire: [[String: Any]]) -> String {
        wire.map { message -> String in
            if let text = message["content"] as? String { return text }
            guard let parts = message["content"] as? [[String: Any]] else { return "" }
            return parts.compactMap { $0["text"] as? String }.joined(separator: "\n")
        }.joined(separator: "\n")
    }

    // MARK: - Exactly once, newest turn only

    /// One dispatch names ONE folder, on the NEWEST turn, once.
    func testLineRidesTheNewestTurnExactlyOnce() throws {
        let box = Self.box()
        let wire = try Self.encodeWire(RemoteAgentClient.assembleMessages(
            priorTurns: [
                .init(role: "user", content: .text("first question")),
                .init(role: "assistant", content: .text("first answer")),
                .init(role: "user", content: .text("second question")),
                .init(role: "assistant", content: .text("second answer")),
            ],
            newUserText: "and now this",
            fileServerReady: true,
            outboxKey: box))

        XCTAssertEqual(Self.allText(wire).components(separatedBy: "Files you produce for this reply go in:").count - 1, 1,
                       "exactly one location on the whole request")
        for prior in wire.dropLast() {
            XCTAssertFalse(((prior["content"] as? String) ?? "").contains("[Conduck file transfer]"),
                           "a replayed prior turn never carries the location")
        }
        XCTAssertTrue(try XCTUnwrap(wire.last?["content"] as? String).hasSuffix(
            ConverseRequest.outboxLocationLine(box)),
                      "the location closes the newest turn's text body")
    }

    // MARK: - The two gates

    /// No ready lane → no line, even holding a key. Nothing could list the box,
    /// so naming it would be a promise with no reader.
    func testAbsentWhenTheLaneIsNotReady() throws {
        let wire = try Self.encodeWire(RemoteAgentClient.assembleMessages(
            priorTurns: [], newUserText: "q",
            fileServerReady: false, outboxKey: Self.box()))
        XCTAssertFalse(Self.allText(wire).contains("[Conduck file transfer]"),
                       "a lane-less turn carries no location")
    }

    /// A ready lane with NO key → no line either. `nil` here is what a lane that
    /// cannot hold a nested collection, or an unwitnessed absence, produces.
    func testAbsentWhenThereIsNoBox() throws {
        let wire = try Self.encodeWire(RemoteAgentClient.assembleMessages(
            priorTurns: [], newUserText: "q", fileServerReady: true))
        XCTAssertFalse(Self.allText(wire).contains("[Conduck file transfer]"),
                       "a ready lane with no box carries no location")
    }

    // MARK: - Never on a replayed turn (the duplication trap)

    /// `priorTurns` — the whole replay path — emits no location for ANY role,
    /// even when every replayed record carries server files of its own. The
    /// agent's OWN earlier output still replays under its full key, which is the
    /// half that must NOT be lost while closing this trap.
    func testReplayEmitsNoLocationForEitherRole() throws {
        let userFile = AttachmentRecord(
            id: UUID(), mimeType: "application/pdf", filename: "input.pdf",
            thumbnailData: nil, extractedText: nil, width: 0, height: 0,
            byteSize: 10, sequence: 0, createdAt: Date(),
            isServerReference: true, storedKey: "conv/a1b2c3d4__input.pdf")
        let agentFile = AttachmentRecord(
            id: UUID(), mimeType: "text/markdown", filename: "daylight.md",
            thumbnailData: nil, extractedText: nil, width: 0, height: 0,
            byteSize: 10, sequence: 0, createdAt: Date(),
            isServerReference: true,
            storedKey: "conv/out-0123456789abcdef0123456789abcdef/daylight.md")
        let records = [
            MessageRecord(id: UUID(), role: "user", text: "here you go",
                          createdAt: Date(), sourceDevice: "phone",
                          fileTransferLaneID: Self.ownedLaneID,
                          attachments: [userFile]),
            MessageRecord(id: UUID(), role: "agent", text: "wrote it",
                          createdAt: Date(), sourceDevice: "phone",
                          outputScanLaneID: Self.ownedLaneID,
                          attachments: [agentFile]),
        ]

        let wire = try Self.encodeWire(ConverseRequest.priorTurns(
            from: records,
            dataURIsByMessageID: [:],
            dispatchFileLaneID: Self.ownedLaneID))
        let text = Self.allText(wire)

        XCTAssertFalse(text.contains("[Conduck file transfer]"),
                       "no replayed record may carry a location, on either role")
        XCTAssertFalse(text.contains("Files you produce for this reply go in:"),
                       "no replayed record may carry the location's body either")
        XCTAssertTrue(text.contains("conv/out-0123456789abcdef0123456789abcdef/daylight.md"),
                      "the agent's OWN earlier output still replays under its full key")
    }

    /// Directly against the splice helpers: none of them may learn to emit a
    /// location. They are the surfaces that run per replayed record, so this is
    /// the guard at the level the mistake would actually be made.
    func testNoSpliceRefsHelperEmitsALocation() {
        let key = "conv/out-0123456789abcdef0123456789abcdef"
        let outputs = [
            ConverseRequest.spliceServerFileRefs(
                "base", serverFiles: [(originalName: "a.pdf", storedKey: "\(key)/a.pdf")]),
            ConverseRequest.spliceTextFileServerRefs(
                "base", textFiles: [(originalName: "a.txt", storedKey: "\(key)/a.txt")]),
            ConverseRequest.spliceImageServerRefs(
                "base", images: [(storedKey: "\(key)/a.jpg", filename: "a.jpg")]),
            ConverseRequest.spliceImageTextRefs(
                "base", images: [(storedKey: "\(key)/a.jpg", filename: "a.jpg")]),
        ]
        for output in outputs {
            XCTAssertFalse(output.contains("[Conduck file transfer]"),
                           "a per-record splice must never emit a scoping marker. Got: \(output)")
            XCTAssertFalse(output.contains("Files you produce for this reply go in:"),
                           "a per-record splice must never emit a location. Got: \(output)")
        }
    }

    // MARK: - Byte-shape locks

    /// A laneless turn is byte-identical to a build with no outbox concept at
    /// all: the body stays exactly `{messages, stream}` and the content stays a
    /// bare string. The common no-lane user pays nothing for this feature.
    func testLanelessTurnByteShapeIsUnchanged() throws {
        let messages = RemoteAgentClient.assembleMessages(
            priorTurns: [], newUserText: "plain question")
        let data = try JSONEncoder().encode(ConverseRequest(messages: messages, stream: false))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(json.keys), Set(["messages", "stream"]),
                       "a laneless body stays exactly {messages, stream}. Found: \(Array(json.keys))")
        let wire = try XCTUnwrap(json["messages"] as? [[String: Any]])
        XCTAssertEqual(wire[0]["content"] as? String, "plain question",
                       "a laneless turn gains no location bytes")
    }

    /// A boxed turn adds EXACTLY the location line and nothing else — no
    /// trailing whitespace, no second directive, no reflow of the base text.
    func testBoxedTurnAddsExactlyOneLineAndNothingElse() throws {
        let box = Self.box()
        let wire = try Self.encodeWire(RemoteAgentClient.assembleMessages(
            priorTurns: [], newUserText: "plain question",
            fileServerReady: true, outboxKey: box))
        XCTAssertEqual(try XCTUnwrap(wire[0]["content"] as? String),
                       "plain question\n\n" + ConverseRequest.outboxLocationLine(box),
                       "base text, one blank line, the location — nothing more")
    }

    /// The path rides BARE and whole: an agent that copies the line's tail must
    /// get a path it can `mkdir -p` and write into.
    func testPathRidesBareAndWhole() throws {
        let cid = UUID()
        let box = OutboxKey.mint(conversationID: cid)
        let wire = try Self.encodeWire(RemoteAgentClient.assembleMessages(
            priorTurns: [], newUserText: "q", fileServerReady: true, outboxKey: box))
        let content = try XCTUnwrap(wire[0]["content"] as? String)
        let tail = try XCTUnwrap(content.components(separatedBy: "go in: ").last)
        XCTAssertEqual(tail, box, "the tail of the line IS the path, unquoted and unclipped")
        XCTAssertTrue(tail.hasPrefix(cid.uuidString + "/"),
                      "including the conversation segment the separator would have been stripped from")
    }
}
