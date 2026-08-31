// SPDX-License-Identifier: Apache-2.0

// ConduckTests
// WorkBriefPromptBuilderTests.swift
//
// Golden contracts for the exact preview/snapshot/gateway prompt, the one
// stored-material -> packet mapping both sides of that prompt consume, and the
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

    /// Two devices capturing offline both derive the same `sequence` from the
    /// order each can see, so a tie is normal rather than pathological. The
    /// board breaks it on `createdAt`, and the prompt has to break it the same
    /// way or the person approves one arrangement and the gateway gets another.
    func testTiedSequencesBreakOnCreatedAtBeforeIdentifier() {
        // The identifier tie-break alone would put `later` first.
        let earlyID = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
        let laterID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        let captured = Date(timeIntervalSince1970: 1_800_000_000)

        let packet = WorkBriefPromptBuilder.build(
            workItemID: UUID(),
            title: "",
            objective: "Decide",
            context: "",
            constraints: "",
            desiredResult: "",
            reviewBy: nil,
            materials: [
                .init(id: laterID, kind: .note, label: "Second", sequence: 3, createdAt: captured.addingTimeInterval(300)),
                .init(id: earlyID, kind: .note, label: "First", sequence: 3, createdAt: captured)
            ]
        )

        XCTAssertEqual(packet.materialIDs, [earlyID, laterID])

        // Identical timestamps still fall through to the stable identifier.
        let tied = WorkBriefPromptBuilder.build(
            workItemID: UUID(),
            title: "",
            objective: "Decide",
            context: "",
            constraints: "",
            desiredResult: "",
            reviewBy: nil,
            materials: [
                .init(id: earlyID, kind: .note, label: "Second", sequence: 3, createdAt: captured),
                .init(id: laterID, kind: .note, label: "First", sequence: 3, createdAt: captured)
            ]
        )

        XCTAssertEqual(tied.materialIDs, [laterID, earlyID])
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

    func testPacketFromRecordOmitsAnEmptyFileSizeAndKeepsARealOne() {
        let empty = WorkBriefFixtures.record(
            kind: .file,
            filename: "empty.txt",
            mimeType: "text/plain",
            byteSize: 0
        )
        let sized = WorkBriefFixtures.record(
            kind: .file,
            filename: "rates.pdf",
            mimeType: "application/pdf",
            byteSize: 42
        )

        XCTAssertNil(
            WorkBriefMaterialPacket(record: empty).byteSize,
            "zero is a valid empty file, and the preview never prints a size for one"
        )
        XCTAssertEqual(WorkBriefMaterialPacket(record: sized).byteSize, 42)
    }

    func testPacketLabelFallsThroughTitleFilenameHostThenKind() {
        let titled = WorkBriefFixtures.record(kind: .file, title: "DHL rate card", filename: "rates.pdf")
        let named = WorkBriefFixtures.record(kind: .file, title: "  \n ", filename: "rates.pdf")
        let hosted = WorkBriefFixtures.record(kind: .link, title: " ", urlString: "https://example.com/pricing")
        let bare = WorkBriefFixtures.record(kind: .image, title: " ", hasPayload: true)

        XCTAssertEqual(WorkBriefMaterialPacket(record: titled).label, "DHL rate card")
        XCTAssertEqual(WorkBriefMaterialPacket(record: named).label, "rates.pdf",
                       "a whitespace-only title is not a name")
        XCTAssertEqual(WorkBriefMaterialPacket(record: hosted).label, "example.com")
        XCTAssertEqual(WorkBriefMaterialPacket(record: bare).label,
                       String(localized: "workboard.material.image", defaultValue: "Image"))
    }

    func testPacketKindResolvesAnUnknownRecordByItsPayloadEvidence() {
        let filed = WorkBriefFixtures.record(kind: .unknown, filename: "mystery.bin", hasPayload: false)
        let carried = WorkBriefFixtures.record(kind: .unknown, hasPayload: true)
        let bare = WorkBriefFixtures.record(kind: .unknown, hasPayload: false)
        let spoken = WorkBriefFixtures.record(kind: .transcript, title: "Voice note")

        XCTAssertEqual(WorkBriefMaterialPacket(record: filed).kind, .file)
        XCTAssertEqual(WorkBriefMaterialPacket(record: carried).kind, .file)
        XCTAssertEqual(WorkBriefMaterialPacket(record: bare).kind, .note)
        XCTAssertEqual(WorkBriefMaterialPacket(record: spoken).kind, .note)
    }

    func testBriefingUsesOneDeterministicFactPacket() {
        let spoken = WorkboardBriefingBuilder.build(from: .init(
            repliesToReview: 2,
            failuresToReview: 5,
            waiting: 3,
            drafts: 4
        ))

        XCTAssertEqual(
            spoken,
            "Workboard update: 2 replies to review, 5 sends needing attention, 3 requests waiting for replies, and 4 prepared drafts."
        )
    }

    /// The singular lives in the catalog's `one` plural variation rather than in
    /// a Swift branch, and `en` is the SOURCE catalog Siri speaks — not a
    /// translation. Nothing else in the tree contains these four strings, so
    /// without this case a deleted or mistyped `one` block ships a green suite
    /// and Siri saying "1 replies to review".
    func testBriefingSpeaksTheCatalogsSingularForACountOfOne() {
        XCTAssertEqual(
            WorkboardBriefingBuilder.build(from: .init(
                repliesToReview: 1,
                failuresToReview: 1,
                waiting: 1,
                drafts: 1
            )),
            "Workboard update: 1 reply to review, 1 send needing attention, 1 request waiting for a reply, and 1 prepared draft."
        )
    }

    /// A zero count must DROP out of the sentence rather than be spoken as "0",
    /// and the kinds that survive must keep their declared order.
    func testBriefingSuppressesZeroCountsAndKeepsKindOrder() {
        XCTAssertEqual(
            WorkboardBriefingBuilder.build(from: .init(
                repliesToReview: 2,
                failuresToReview: 0,
                waiting: 3,
                drafts: 0
            )),
            "Workboard update: 2 replies to review and 3 requests waiting for replies."
        )

        XCTAssertEqual(
            WorkboardBriefingBuilder.build(from: .init(
                repliesToReview: 0,
                failuresToReview: 0,
                waiting: 0,
                drafts: 4
            )),
            "Workboard update: 4 prepared drafts."
        )
    }

    func testEmptyBriefingDoesNotInventWork() {
        let spoken = WorkboardBriefingBuilder.build(from: .init(
            repliesToReview: -1,
            failuresToReview: 0,
            waiting: 0,
            drafts: 0
        ))

        XCTAssertEqual(spoken, "Your Workboard is clear. There is nothing open right now.")
    }
}

/// Shared record fixtures plus the snapshot the PREVIEW composes from, built by
/// calling the app's own record -> presentation mapping
/// (`WorkboardLiveRepository.presentationKind` / `.materialName`) rather than a
/// transcription of it. That is what makes the byte-identity test in
/// `WorkboardDispatchCoordinatorTests` meaningful: the send boundary refuses any
/// brief whose final prompt differs from the previewed one by a byte, so the two
/// derivations pinned against each other must be the two the app actually runs.
enum WorkBriefFixtures {
    static let workItemID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    static let timestamp = Date(timeIntervalSinceReferenceDate: 700_000)

    static func record(
        id: UUID = UUID(),
        kind: WorkMaterialKind,
        title: String = "",
        textContent: String? = nil,
        urlString: String? = nil,
        filename: String? = nil,
        mimeType: String? = nil,
        byteSize: Int64 = 0,
        hasPayload: Bool = true,
        sequence: Int = 0
    ) -> WorkMaterialRecord {
        WorkMaterialRecord(
            id: id,
            workItemID: workItemID,
            kind: kind,
            title: title,
            caption: "",
            textContent: textContent,
            urlString: urlString,
            filename: filename,
            mimeType: mimeType,
            thumbnailData: nil,
            width: nil,
            height: nil,
            byteSize: byteSize,
            hasPayload: hasPayload,
            storageMode: hasPayload ? .localVault : .metadataOnly,
            availability: hasPayload ? .availableLocally : .metadataOnly,
            localVaultKey: hasPayload ? "vault-\(id.uuidString)" : nil,
            sourceDevice: nil,
            sequence: sequence,
            createdAt: timestamp,
            updatedAt: timestamp
        )
    }

    /// Mirrors the field assignment of `WorkboardLiveRepository.materialSnapshot`
    /// for the fields the prompt reads, but the two decisions that can drift —
    /// kind and name — are taken by calling the repository itself.
    static func previewSnapshot(_ record: WorkMaterialRecord) -> WorkboardMaterialSnapshot {
        WorkboardMaterialSnapshot(
            id: record.id,
            kind: WorkboardLiveRepository.presentationKind(record),
            name: WorkboardLiveRepository.materialName(record),
            textContent: record.textContent,
            urlString: record.urlString,
            mimeType: record.mimeType,
            byteCount: record.byteSize > 0 ? record.byteSize : nil,
            availability: .available,
            sequence: record.sequence,
            createdAt: record.createdAt,
            revision: 0
        )
    }
}
