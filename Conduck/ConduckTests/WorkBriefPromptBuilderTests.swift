// SPDX-License-Identifier: Apache-2.0

// ConduckTests
// WorkBriefPromptBuilderTests.swift
//
// Golden contracts for the exact preview/snapshot/gateway prompt and the
// deterministic, fact-only Workboard briefing.

import XCTest
@testable import Conduck

final class WorkBriefPromptBuilderTests: XCTestCase {
    func testCanonicalPromptNormalizesAndOrdersEverySection() {
        let itemID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let lateID = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
        let earlyID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        let reviewBy = Date(timeIntervalSince1970: 1_800_000_000)

        let packet = WorkBriefPromptBuilder.build(
            workItemID: itemID,
            title: "  Courier comparison\r\n",
            objective: "Compare price and EU coverage.",
            context: "  Prefer primary sources.  ",
            constraints: "Use public pricing only.",
            desiredResult: "A short recommendation.",
            reviewBy: reviewBy,
            materials: [
                .init(id: lateID, kind: .file, label: "rates.pdf", mimeType: "application/pdf", byteSize: 42, sequence: 2),
                .init(id: earlyID, kind: .link, label: "Carrier", url: "https://example.com", sequence: 1)
            ]
        )

        XCTAssertEqual(packet.materialIDs, [earlyID, lateID])
        XCTAssertEqual(packet.canonicalPrompt, """
        Title
        Courier comparison

        What needs doing
        Compare price and EU coverage.

        Context
        Prefer primary sources.

        Constraints
        Use public pricing only.

        A good result includes
        A short recommendation.

        Review by
        2027-01-15T08:00:00Z

        Materials
        - [Link] Carrier
          https://example.com

        - [File] rates.pdf
          application/pdf, 42 bytes
        """)
    }

    func testEmptyOptionalSectionsAreOmittedAndSubstanceRuleCountsMaterials() {
        let packet = WorkBriefPromptBuilder.build(
            workItemID: UUID(),
            title: "",
            objective: "Do the thing",
            context: " \n ",
            constraints: "",
            desiredResult: "",
            reviewBy: nil,
            materials: []
        )

        XCTAssertEqual(packet.canonicalPrompt, "What needs doing\nDo the thing")
        XCTAssertFalse(WorkBriefPromptBuilder.isSubstantive(title: " ", objective: "", context: "", constraints: "", desiredResult: "", materialCount: 0))
        XCTAssertTrue(WorkBriefPromptBuilder.isSubstantive(title: " ", objective: "", context: "", constraints: "", desiredResult: "", materialCount: 1))
    }

    func testBriefingUsesOneDeterministicFactPacket() {
        let briefing = WorkboardBriefingBuilder.build(from: .init(
            repliesToReview: 2,
            failuresToReview: 1,
            waiting: 3,
            drafts: 4
        ))

        XCTAssertEqual(briefing.rows.map(\.count), [2, 1, 3, 4])
        XCTAssertEqual(
            briefing.spokenText,
            "Workboard update: 2 replies to review, 1 send needing attention, 3 requests waiting for replies, and 4 prepared drafts."
        )
    }

    func testEmptyBriefingDoesNotInventWork() {
        let briefing = WorkboardBriefingBuilder.build(from: .init(
            repliesToReview: -1,
            failuresToReview: 0,
            waiting: 0,
            drafts: 0
        ))

        XCTAssertTrue(briefing.rows.isEmpty)
        XCTAssertEqual(briefing.spokenText, "Your Workboard is clear. There is nothing open right now.")
    }
}
