// SPDX-License-Identifier: Apache-2.0

// Conduck
// TextFileExtractorTests.swift
//
// V1.1 Core Attachments. Locks `TextFileExtractor.extract(from:)`:
//   - a UTF-8 `.txt` decodes to the expected text + filename + derived mimeType
//   - an `.rtf` written via `NSAttributedString` extracts to its plain string
//   - binary / non-UTF-8 bytes throw `.undecodable` (never splice garbage)
//
// Files are created in `FileManager.default.temporaryDirectory`. Starting
// security-scoped access on a self-created temp URL is a no-op (returns false,
// the `defer` stop is balanced) — the extractor's `Data(contentsOf:)` still
// reads it fine, so these temp files exercise the real read path.
//
// NOT in the Watch compile set (`#if !os(watchOS)` mirrors the production file
// — the Watch never imports files).

#if !os(watchOS)

import XCTest
@testable import Conduck

final class TextFileExtractorTests: XCTestCase {

    private var tempURLs: [URL] = []

    override func tearDown() {
        for url in tempURLs { try? FileManager.default.removeItem(at: url) }
        tempURLs = []
        super.tearDown()
    }

    /// Write `data` to a uniquely-named temp file with `ext`, track it for
    /// teardown, return its URL.
    private func writeTempFile(name: String, ext: String, data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)")
            .appendingPathExtension(ext)
        try data.write(to: url)
        tempURLs.append(url)
        return url
    }

    // MARK: - UTF-8 plain text

    func testTxtFileDecodesTextFilenameAndMimeType() throws {
        let body = "Hello, world.\nLine two with Ünïcödé ✓"
        let url = try writeTempFile(name: "notes", ext: "txt", data: Data(body.utf8))

        let extracted = try TextFileExtractor.extract(from: url)

        XCTAssertEqual(extracted.text, body, "UTF-8 text must decode verbatim, including non-ASCII.")
        XCTAssertEqual(extracted.filename, url.lastPathComponent,
                       "filename must be the original last path component.")
        XCTAssertEqual(extracted.mimeType, "text/plain", ".txt maps to text/plain.")
    }

    func testCsvFileDerivesCsvMimeType() throws {
        let url = try writeTempFile(name: "data", ext: "csv", data: Data("a,b,c\n1,2,3".utf8))
        let extracted = try TextFileExtractor.extract(from: url)
        XCTAssertEqual(extracted.mimeType, "text/csv", ".csv maps to text/csv.")
        XCTAssertEqual(extracted.text, "a,b,c\n1,2,3")
    }

    func testJsonFileDerivesJsonMimeType() throws {
        let url = try writeTempFile(name: "payload", ext: "json", data: Data(#"{"k":1}"#.utf8))
        let extracted = try TextFileExtractor.extract(from: url)
        XCTAssertEqual(extracted.mimeType, "application/json", ".json maps to application/json.")
    }

    func testMarkdownFileDerivesMarkdownMimeType() throws {
        let url = try writeTempFile(name: "readme", ext: "md", data: Data("# Title".utf8))
        let extracted = try TextFileExtractor.extract(from: url)
        XCTAssertEqual(extracted.mimeType, "text/markdown", ".md maps to text/markdown.")
    }

    // MARK: - RTF → plain string

    func testRtfFileExtractsToPlainString() throws {
        let plain = "Bold and italic styled text"
        let attributed = NSAttributedString(string: plain)
        let rtfData = try attributed.data(
            from: NSRange(location: 0, length: attributed.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
        )
        let url = try writeTempFile(name: "styled", ext: "rtf", data: rtfData)

        let extracted = try TextFileExtractor.extract(from: url)

        // RTF formatting is dropped — only the plain string survives. Trim
        // trailing whitespace/newlines RTF round-trips can introduce.
        XCTAssertEqual(
            extracted.text.trimmingCharacters(in: .whitespacesAndNewlines),
            plain,
            "RTF must extract to its plain string (formatting dropped)."
        )
        XCTAssertEqual(extracted.mimeType, "text/plain",
                       "RTF stores its content as plain text → text/plain mimeType.")
    }

    // MARK: - Binary / non-UTF-8 rejection

    func testBinaryFileThrowsUndecodable() throws {
        // 0xFF 0xFE … is not valid UTF-8; the extractor must reject it rather
        // than splice garbage into the turn.
        let binary = Data([0xFF, 0xFE, 0x00, 0x80, 0x81, 0xC0, 0xC1])
        let url = try writeTempFile(name: "blob", ext: "txt", data: binary)

        XCTAssertThrowsError(try TextFileExtractor.extract(from: url)) { error in
            guard case TextFileExtractor.ExtractError.undecodable = error else {
                XCTFail("Expected .undecodable for non-UTF-8 bytes, got \(error)")
                return
            }
        }
    }
}

#endif
