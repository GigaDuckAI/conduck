// SPDX-License-Identifier: Apache-2.0

// Conduck
// ConversationCopyFormatterTests.swift
//
// Pins the "Copy conversation" clipboard format: role-labeled turns joined by
// blank lines, agent Markdown verbatim, attachments as bracket placeholders —
// and the never-leak guarantee (no `storedKey`, no `extractedText` contents).

import XCTest
@testable import Conduck

final class ConversationCopyFormatterTests: XCTestCase {

    // MARK: - Fixtures

    private func message(
        role: String = "user",
        text: String = "",
        status: String? = nil,
        attachments: [AttachmentRecord] = []
    ) -> MessageRecord {
        MessageRecord(
            id: UUID(),
            role: role,
            text: text,
            createdAt: Date(timeIntervalSince1970: 1_000),
            sourceDevice: "phone",
            status: status,
            attachments: attachments)
    }

    private func attachment(
        mimeType: String,
        filename: String? = nil,
        extractedText: String? = nil,
        sequence: Int = 0,
        isServerReference: Bool = false,
        storedKey: String? = nil
    ) -> AttachmentRecord {
        AttachmentRecord(
            id: UUID(),
            mimeType: mimeType,
            filename: filename,
            thumbnailData: nil,
            extractedText: extractedText,
            width: 0,
            height: 0,
            byteSize: 0,
            sequence: sequence,
            createdAt: Date(timeIntervalSince1970: 1_000),
            isServerReference: isServerReference,
            storedKey: storedKey)
    }

    // MARK: - Turn labels + joining

    func testBuild_userAndAgentTurns_exactTranscript() {
        let out = ConversationCopyFormatter.build(
            messages: [
                message(role: "user", text: "hello there, please summarize"),
                message(role: "agent", text: "Here is the summary."),
            ],
            agentName: "OpenClaw")
        XCTAssertEqual(out, """
        You:
        hello there, please summarize

        OpenClaw:
        Here is the summary.
        """)
    }

    func testBuild_noTrailingNewline() {
        let out = ConversationCopyFormatter.build(
            messages: [message(role: "user", text: "hi")], agentName: "OpenClaw")
        XCTAssertFalse(out.hasSuffix("\n"))
    }

    func testBuild_blankAgentName_fallsBackToPersonalAI() {
        let out = ConversationCopyFormatter.build(
            messages: [message(role: "agent", text: "reply")], agentName: "   ")
        XCTAssertEqual(out, "\(String(localized: "Personal AI")):\nreply")
    }

    func testBuild_emptyMessages_emptyString() {
        XCTAssertEqual(ConversationCopyFormatter.build(messages: [], agentName: "OpenClaw"), "")
    }

    // MARK: - Attachment placeholders

    func testBuild_imageAttachment_placeholderWithoutFilename() {
        let out = ConversationCopyFormatter.build(
            messages: [message(text: "look at this",
                               attachments: [attachment(mimeType: "image/jpeg")])],
            agentName: "OpenClaw")
        XCTAssertEqual(out, "You:\nlook at this\n[Image attached]")
    }

    func testBuild_namedTextFile_placeholderCarriesFilename() {
        let out = ConversationCopyFormatter.build(
            messages: [message(text: "check the numbers",
                               attachments: [attachment(mimeType: "text/csv",
                                                        filename: "report.csv",
                                                        extractedText: "a,b,c")])],
            agentName: "OpenClaw")
        XCTAssertEqual(out, "You:\ncheck the numbers\n[File attached: report.csv]")
    }

    func testBuild_serverFile_namedAndNameless() {
        let named = ConversationCopyFormatter.build(
            messages: [message(text: "here",
                               attachments: [attachment(mimeType: "application/zip",
                                                        filename: "export.zip",
                                                        isServerReference: true,
                                                        storedKey: "ab12cd34__export.zip")])],
            agentName: "OpenClaw")
        XCTAssertEqual(named, "You:\nhere\n[File attached: export.zip]")

        let nameless = ConversationCopyFormatter.build(
            messages: [message(text: "here",
                               attachments: [attachment(mimeType: "application/octet-stream",
                                                        isServerReference: true,
                                                        storedKey: "ab12cd34__blob")])],
            agentName: "OpenClaw")
        XCTAssertEqual(nameless, "You:\nhere\n[File attached]")
    }

    func testBuild_multipleAttachments_placeholdersInOrder() {
        let out = ConversationCopyFormatter.build(
            messages: [message(text: "both",
                               attachments: [
                                   attachment(mimeType: "image/png", sequence: 0),
                                   attachment(mimeType: "application/pdf",
                                              filename: "paper.pdf", sequence: 1),
                               ])],
            agentName: "OpenClaw")
        XCTAssertEqual(out, "You:\nboth\n[Image attached]\n[File attached: paper.pdf]")
    }

    func testBuild_attachmentOnlyTurn_labelPlusPlaceholderNoBlankBodyLine() {
        let out = ConversationCopyFormatter.build(
            messages: [message(attachments: [attachment(mimeType: "image/jpeg")])],
            agentName: "OpenClaw")
        XCTAssertEqual(out, "You:\n[Image attached]")
    }

    func testBuild_emptyTurnWithoutAttachments_skipped() {
        let out = ConversationCopyFormatter.build(
            messages: [
                message(role: "user", text: "   "),
                message(role: "agent", text: "reply"),
            ],
            agentName: "OpenClaw")
        XCTAssertEqual(out, "OpenClaw:\nreply")
    }

    // MARK: - Markdown + leakage

    func testBuild_markdownPreservedVerbatim() {
        let markdown = """
        Here is the **summary**:

        - point one
        - point two

        ```swift
        let x = 1
        ```
        """
        let out = ConversationCopyFormatter.build(
            messages: [message(role: "agent", text: markdown)], agentName: "OpenClaw")
        XCTAssertEqual(out, "OpenClaw:\n\(markdown)")
    }

    func testBuild_neverLeaksStoredKeyOrExtractedText() {
        let out = ConversationCopyFormatter.build(
            messages: [message(text: "sensitive",
                               attachments: [attachment(mimeType: "text/plain",
                                                        filename: "notes.txt",
                                                        extractedText: "SECRET-CONTENTS",
                                                        storedKey: "deadbeef__notes.txt")])],
            agentName: "OpenClaw")
        XCTAssertFalse(out.contains("SECRET-CONTENTS"))
        XCTAssertFalse(out.contains("deadbeef__notes.txt"))
        XCTAssertTrue(out.contains("[File attached: notes.txt]"))
    }

    // MARK: - Send-state annotation

    func testBuild_failedTurn_appendsNotSent() {
        let out = ConversationCopyFormatter.build(
            messages: [message(text: "did this go out?", status: "failed")],
            agentName: "OpenClaw")
        XCTAssertEqual(out, "You:\ndid this go out?\n[Not sent]")
    }

    func testBuild_sendingAndSentTurns_noAnnotation() {
        let sending = ConversationCopyFormatter.build(
            messages: [message(text: "in flight", status: "sending")], agentName: "OpenClaw")
        XCTAssertEqual(sending, "You:\nin flight")

        let sent = ConversationCopyFormatter.build(
            messages: [message(text: "landed", status: "sent")], agentName: "OpenClaw")
        XCTAssertEqual(sent, "You:\nlanded")
    }
}
