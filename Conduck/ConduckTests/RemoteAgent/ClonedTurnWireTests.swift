// SPDX-License-Identifier: Apache-2.0

// Conduck
// ClonedTurnWireTests.swift
//
// The reported bug, at the wire: a conversation carrying an image and a
// file-transfer PDF was cloned from one gateway to another, and the new gateway
// received neither the PDF nor any hint that a PDF had ever been attached.
//
// The subtle half is WHERE the disclosure has to happen. The honest
// "not available in the current file-transfer lane" note is emitted by
// `ConverseRequest.priorTurns` — but the turn being continued is the NEWEST
// turn, which `retry` deliberately excludes from that assembly and rebuilds in
// `RemoteAgentClient.assembleMessages` from resolved keys, inline image bytes,
// and text blocks. A detached tombstone matches none of those categories, so
// before `newUserUnavailableFileCount` existed the first dispatch after a clone
// dropped the file in total silence and let the model answer as though nothing
// had been attached — the exact failure the tombstone exists to prevent.
//
// `ConverseWireTests` already locks the PRIOR-turn half of this contract
// (`testPriorServerFileMismatchedLaneNeverExposesStoredKey`,
// `testPriorServerFileLegacyNilOwnerNeverExposesStoredKey`). This file locks the
// CURRENT-turn half and the assistant-role carve-out.

import XCTest
@testable import Conduck

final class ClonedTurnWireTests: XCTestCase {
    private static let laneA = String(repeating: "a", count: 64)
    private static let laneB = String(repeating: "b", count: 64)
    private static let foreignKey = "9f3c1d__Haiku.pdf"

    private static func wireContent(_ messages: [ConverseRequest.Message]) throws -> [String] {
        let data = try JSONEncoder().encode(ConverseRequest(messages: messages, stream: false))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let wire = try XCTUnwrap(json["messages"] as? [[String: Any]])
        return wire.map { message in
            if let text = message["content"] as? String { return text }
            // Parts form (image-bearing turn): concatenate the text parts.
            let parts = (message["content"] as? [[String: Any]]) ?? []
            return parts.compactMap { $0["text"] as? String }.joined(separator: "\n")
        }
    }

    private static func detachedServerFile() -> AttachmentRecord {
        // What the clone persists for a PDF whose key was minted on another
        // file lane: the file is still NAMED, but there is nothing to address.
        AttachmentRecord(
            id: UUID(),
            mimeType: "application/pdf",
            filename: "Haiku.pdf",
            thumbnailData: nil,
            extractedText: nil,
            width: 0,
            height: 0,
            byteSize: 11_264,
            sequence: 0,
            createdAt: Date(),
            isServerReference: true,
            storedKey: nil
        )
    }

    // MARK: - The current turn (the auto-continued clone)

    func testFirstDispatchAfterCloneDisclosesTheUnreachableFile() throws {
        let messages = RemoteAgentClient.assembleMessages(
            priorTurns: [],
            newUserText: "please check those two files. then write one .md and one .txt file explaining me the contents of both (just a summary)",
            newUserImageDataURIs: ["data:image/jpeg;base64,/9j/4AAQ"],
            newUserUnavailableFileCount: 1
        )
        let content = try Self.wireContent(messages)

        XCTAssertTrue(content[0].contains("not available in the current file-transfer lane"),
                      "The FIRST dispatch after a cross-lane clone must say the file is unreachable — otherwise the model answers 'please check those two files' having silently received one.")
        XCTAssertTrue(content[0].contains("Do not claim to have read or created them"),
                      "The note's instruction half is the part that stops a confident fabrication about a file the model never saw.")
        XCTAssertTrue(content[0].contains("please check those two files"),
                      "The user's own text must survive the splice.")
    }

    func testCurrentTurnNeverLeaksAForeignStoredKey() throws {
        // A key minted on lane A is an opaque path in another gateway's
        // namespace; naming it would send the new agent hunting for a file that
        // does not exist there.
        let messages = RemoteAgentClient.assembleMessages(
            priorTurns: [],
            newUserText: "summarize the pdf",
            newUserUnavailableFileCount: 1
        )
        let content = try Self.wireContent(messages)
        XCTAssertFalse(content[0].contains(Self.foreignKey))
        XCTAssertFalse(content[0].contains("working directory"),
                       "There is no reachable file, so the turn must not carry a 'saved as <key> in your working directory' line.")
    }

    func testOrdinaryTurnIsUnchangedWhenNothingIsDetached() throws {
        // Defaulted 0 — every ordinary send has either a reachable key or no
        // file at all, and must stay byte-identical.
        let messages = RemoteAgentClient.assembleMessages(
            priorTurns: [],
            newUserText: "just a question"
        )
        XCTAssertEqual(try Self.wireContent(messages)[0], "just a question")
    }

    func testDetachedCountIsIgnoredWhenZero() throws {
        let messages = RemoteAgentClient.assembleMessages(
            priorTurns: [],
            newUserText: "just a question",
            newUserUnavailableFileCount: 0
        )
        XCTAssertEqual(try Self.wireContent(messages)[0], "just a question")
    }

    // MARK: - Prior turns (the cloned history)

    func testClonedPriorUserTurnStillCarriesTheNote() throws {
        let records = [
            MessageRecord(
                id: UUID(),
                role: "user",
                text: "here is the report",
                createdAt: Date(),
                sourceDevice: "mac",
                attachments: [Self.detachedServerFile()]
            )
        ]
        let turns = ConverseRequest.priorTurns(from: records, dispatchFileLaneID: Self.laneB).turns
        let content = try Self.wireContent(turns)
        XCTAssertTrue(content[0].contains("not available in the current file-transfer lane"),
                      "A cloned USER turn's detached file must still be disclosed in history.")
    }

    func testClonedPriorAgentTurnAlsoCarriesTheNote() throws {
        // A clone keeps the agent's own output chips for the archive while
        // owning no key on the new lane, so this shape is newly common. The note
        // fires on BOTH roles by design: its wording is "Do not claim to have
        // read OR CREATED them", and the "created" half exists precisely for an
        // agent-authored output the new lane cannot serve. Without it a cloned
        // thread would let the model keep referring to a chart it can no longer
        // produce. Same contract as
        // `ConverseWireTests.testAgentOutputMismatchedLaneNeverExposesStoredKey`.
        let records = [
            MessageRecord(
                id: UUID(),
                role: "agent",
                text: "I wrote the summary for you.",
                createdAt: Date(),
                sourceDevice: "mac",
                attachments: [Self.detachedServerFile()]
            )
        ]
        let turns = ConverseRequest.priorTurns(from: records, dispatchFileLaneID: Self.laneB).turns
        let content = try Self.wireContent(turns)
        XCTAssertTrue(content[0].contains("not available in the current file-transfer lane"),
                      "A cloned agent output the new lane cannot serve must be disclosed, not left implicitly claimable.")
        XCTAssertTrue(content[0].contains("I wrote the summary for you."),
                      "The reply text itself is untouched.")
    }

    func testSameLaneAgentOutputStillSplicesItsKey() throws {
        // The preserved-reference case: when both gateways point at one file
        // server the key is genuinely still valid and must keep working.
        let attachment = AttachmentRecord(
            id: UUID(),
            mimeType: "text/markdown",
            filename: "out.md",
            thumbnailData: nil,
            extractedText: nil,
            width: 0, height: 0, byteSize: 128, sequence: 0,
            createdAt: Date(),
            isServerReference: true,
            storedKey: "z__out.md"
        )
        let records = [
            MessageRecord(
                id: UUID(),
                role: "agent",
                text: "written",
                createdAt: Date(),
                sourceDevice: "mac",
                outputScanLaneID: Self.laneA,
                attachments: [attachment]
            )
        ]
        let turns = ConverseRequest.priorTurns(from: records, dispatchFileLaneID: Self.laneA).turns
        let content = try Self.wireContent(turns)
        XCTAssertTrue(content[0].contains("z__out.md"),
                      "A same-lane agent output is still addressable and must keep its reference.")
    }
}
