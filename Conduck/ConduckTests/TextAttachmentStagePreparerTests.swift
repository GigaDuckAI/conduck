// SPDX-License-Identifier: Apache-2.0

// Conduck
// TextAttachmentStagePreparerTests.swift
//
// Regression coverage for the VM-less first-turn bug: file-lane readiness is
// scoped to the selected gateway, not to ConversationDetailViewModel existence.
// These tests drive the shared preparation seam used by BOTH Apple composers.

#if os(iOS) || os(macOS)

import XCTest
@testable import Conduck

final class TextAttachmentStagePreparerTests: XCTestCase {
    private let fixedUUID = UUID(uuidString: "12345678-1234-1234-1234-123456789ABC")!

    private func sourceFile(name: String, bytes: Data) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TextAttachmentStagePreparerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try bytes.write(to: url, options: .atomic)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return url
    }

    private func removePreparedCopy(_ preparation: TextAttachmentStagePreparation) {
        guard let url = preparation.uploadRequest?.localURL else { return }
        try? FileManager.default.removeItem(at: url)
    }

    func testReadyNilVMLargeTextPreparesFlatServerUploadWithRawBytesAndNoInline() async throws {
        let text = String(repeating: "a", count: Constants.textInlineMaxBytes + 1)
        let rawBytes = Data(text.utf8)
        let source = try sourceFile(name: "vision-check.txt", bytes: rawBytes)
        let extracted = TextFileExtractor.ExtractedFile(
            filename: source.lastPathComponent,
            mimeType: "text/plain",
            text: text
        )

        let preparation = await TextAttachmentStagePreparer.prepare(
            sourceURL: source,
            extracted: extracted,
            fileServerReady: true,
            inlineBudgetRemaining: Constants.textInlineTurnBudgetBytes,
            folderCapable: true,
            conversationID: nil,
            uuid: fixedUUID
        )
        defer { removePreparedCopy(preparation) }

        XCTAssertNil(preparation.attachment.pendingAttachment,
                     "large text has no inline fallback before its upload lands")

        // A required server file intentionally cannot ride until its PUT lands;
        // stamp the deterministic upload result to inspect the exact pending
        // payload that Send will receive.
        var landed = preparation.attachment
        let upload = try XCTUnwrap(preparation.uploadRequest)
        landed.serverUploadState = .uploaded(storedKey: upload.storedKey)
        guard case let .serverFile(url, name, _, storedKey) = landed.pendingAttachment else {
            return XCTFail("expected landed .serverFile pending attachment")
        }
        XCTAssertEqual(url, upload.localURL)
        XCTAssertEqual(name, source.lastPathComponent)
        XCTAssertEqual(storedKey, "12345678__vision-check.txt")
        XCTAssertFalse(storedKey.contains("/"),
                       "VM-less first turns must mint a flat storedKey")
        XCTAssertEqual(try Data(contentsOf: upload.localURL), rawBytes,
                       "the eager upload must read the original raw bytes")
    }

    func testReadyNilVMSmallTextPreparesDualTextAndFlatRawUpload() async throws {
        let text = "small first-turn text"
        let rawBytes = Data(text.utf8)
        let source = try sourceFile(name: "notes.md", bytes: rawBytes)
        let extracted = TextFileExtractor.ExtractedFile(
            filename: source.lastPathComponent,
            mimeType: "text/markdown",
            text: text
        )

        let preparation = await TextAttachmentStagePreparer.prepare(
            sourceURL: source,
            extracted: extracted,
            fileServerReady: true,
            inlineBudgetRemaining: Constants.textInlineTurnBudgetBytes,
            folderCapable: true,
            conversationID: nil,
            uuid: fixedUUID
        )
        defer { removePreparedCopy(preparation) }

        guard case let .dualText(_, extractedText, filename, _, storedKeyBeforeUpload) =
                preparation.attachment.pendingAttachment else {
            return XCTFail("expected .dualText pending attachment")
        }
        XCTAssertEqual(extractedText, text)
        XCTAssertEqual(filename, "notes.md")
        XCTAssertNil(storedKeyBeforeUpload,
                     "the inline fallback is sendable while the preferred PUT runs")

        let upload = try XCTUnwrap(preparation.uploadRequest)
        XCTAssertEqual(upload.storedKey, "12345678__notes.md")
        XCTAssertFalse(upload.storedKey.contains("/"))
        XCTAssertEqual(try Data(contentsOf: upload.localURL), rawBytes,
                       "the server copy must preserve the picked file bytes")

        var landed = preparation.attachment
        landed.serverUploadState = .uploaded(storedKey: upload.storedKey)
        guard case let .dualText(_, _, _, _, storedKeyAfterUpload) = landed.pendingAttachment else {
            return XCTFail("expected landed .dualText pending attachment")
        }
        XCTAssertEqual(storedKeyAfterUpload, upload.storedKey)
    }

    func testNoReadyServerStaysInlineAndCreatesNoUploadRequest() async throws {
        let text = String(repeating: "z", count: Constants.textInlineMaxBytes + 1)
        let source = try sourceFile(name: "offline.txt", bytes: Data(text.utf8))
        let extracted = TextFileExtractor.ExtractedFile(
            filename: source.lastPathComponent,
            mimeType: "text/plain",
            text: text
        )

        let preparation = await TextAttachmentStagePreparer.prepare(
            sourceURL: source,
            extracted: extracted,
            fileServerReady: false,
            inlineBudgetRemaining: 0,
            folderCapable: true,
            conversationID: nil,
            uuid: fixedUUID
        )

        XCTAssertNil(preparation.uploadRequest)
        guard case let .textFile(url) = preparation.attachment.pendingAttachment else {
            return XCTFail("server-less text must remain inline-only")
        }
        XCTAssertEqual(url, source)
    }

    func testReadyEstablishedConversationKeepsNamespacedStoredKey() async throws {
        let conversationID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let text = String(repeating: "q", count: Constants.textInlineMaxBytes + 1)
        let source = try sourceFile(name: "existing.txt", bytes: Data(text.utf8))
        let preparation = await TextAttachmentStagePreparer.prepare(
            sourceURL: source,
            extracted: .init(
                filename: source.lastPathComponent,
                mimeType: "text/plain",
                text: text
            ),
            fileServerReady: true,
            inlineBudgetRemaining: Constants.textInlineTurnBudgetBytes,
            folderCapable: true,
            conversationID: conversationID,
            uuid: fixedUUID
        )
        defer { removePreparedCopy(preparation) }

        XCTAssertEqual(
            preparation.uploadRequest?.storedKey,
            "\(conversationID.uuidString)/12345678__existing.txt",
            "existing-chat uploads must preserve per-conversation namespacing"
        )
    }

    func testServerCopyPreservesOriginalEncodingAndLineEndingsNotExtractedText() async throws {
        let fixtures: [(name: String, raw: Data, extracted: String)] = [
            (
                "bom.txt",
                Data([0xEF, 0xBB, 0xBF]) + Data("alpha\n".utf8),
                "alpha\n"
            ),
            (
                "crlf.txt",
                Data("alpha\r\nomega\r\n".utf8),
                "alpha\nomega\n"
            ),
            (
                "lf.txt",
                Data("alpha\nomega\n".utf8),
                "ALPHA\nOMEGA\n"
            ),
            (
                "no-final-newline.txt",
                Data("alpha\nomega".utf8),
                "alpha\nomega\n"
            )
        ]

        for (index, fixture) in fixtures.enumerated() {
            let source = try sourceFile(name: fixture.name, bytes: fixture.raw)
            let preparation = await TextAttachmentStagePreparer.prepare(
                sourceURL: source,
                extracted: .init(
                    filename: fixture.name,
                    mimeType: "text/plain",
                    text: fixture.extracted
                ),
                fileServerReady: true,
                inlineBudgetRemaining: Constants.textInlineTurnBudgetBytes,
                folderCapable: false,
                conversationID: nil,
                uuid: UUID(
                    uuidString: String(
                        format: "00000000-0000-0000-0000-%012d",
                        index + 1
                    )
                )!
            )
            defer { removePreparedCopy(preparation) }

            let upload = try XCTUnwrap(preparation.uploadRequest)
            let copied = try Data(contentsOf: upload.localURL)
            XCTAssertEqual(
                copied,
                fixture.raw,
                "\(fixture.name) must retain the picked file's exact bytes"
            )
            XCTAssertNotEqual(
                copied,
                Data(fixture.extracted.utf8),
                "\(fixture.name) fixture must prove upload is not re-encoded extracted text"
            )
        }
    }
}

#endif
