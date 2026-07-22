// Conduck
// TextFileExtractor.swift
//
// V1.1 Core Attachments. Extracts plain text from a user-picked text/code
// file at a security-scoped URL. Chat Completions has NO portable file-input
// wire (dropped Sept 2025), so text files are extracted to text and spliced
// inline into the turn — works on ANY model. `.docx`/`.odt` are out of scope
// (no dependency-free iOS reader); `.rtf` is supported via `NSAttributedString`.
//
// Pure enum (no state) → unit-testable + Sendable. NO size cap (the user pays
// their own bill). Binary / undecodable input is rejected gracefully with
// `.undecodable` rather than splicing garbage.
//
// WATCH: not in the Watch compile set; `#if !os(watchOS)` is belt-and-
// suspenders (the Watch never imports files).

#if !os(watchOS)

import Foundation
// The RTF `NSAttributedString(data:options:documentAttributes:)` initializer +
// `.documentType` / `.rtf` live in UIKit (iOS/iPadOS) / AppKit (macOS), not in
// Foundation. Import the platform UI framework so the RTF branch resolves.
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Extracts plain text + a derived MIME type from a picked text/code file.
enum TextFileExtractor {
    /// One extracted text file: its decoded text, a derived MIME type
    /// (`text/plain` / `text/markdown` / `text/csv` / `application/json`), and
    /// the original filename (for the fenced splice label + the file chip).
    struct ExtractedFile: Sendable {
        let filename: String
        let mimeType: String
        let text: String
    }

    /// Extraction failures.
    enum ExtractError: Error {
        /// Could not start the security-scoped access (sandbox denied).
        case accessDenied
        /// Bytes are not valid UTF-8 text (binary / unsupported encoding), or
        /// RTF parsing failed.
        case undecodable
    }

    /// Read + decode a text/code file at a security-scoped `url`.
    ///
    /// - `.rtf` → `NSAttributedString(... documentType: .rtf).string` (plain
    ///   text, formatting dropped).
    /// - everything else → `String(data:encoding:.utf8)`; a nil decode (binary
    ///   or non-UTF-8) throws `.undecodable`.
    ///
    /// Security-scoped access is started + balanced with a `defer` stop.
    static func extract(from url: URL) throws -> ExtractedFile {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didAccess { url.stopAccessingSecurityScopedResource() }
        }

        let data = try Data(contentsOf: url)
        let ext = url.pathExtension.lowercased()
        let filename = url.lastPathComponent

        let text: String
        if ext == "rtf" {
            guard let attributed = try? NSAttributedString(
                data: data,
                options: [.documentType: NSAttributedString.DocumentType.rtf],
                documentAttributes: nil
            ) else {
                throw ExtractError.undecodable
            }
            text = attributed.string
        } else {
            guard let decoded = String(data: data, encoding: .utf8) else {
                throw ExtractError.undecodable
            }
            text = decoded
        }

        return ExtractedFile(
            filename: filename,
            mimeType: Self.mimeType(forExtension: ext),
            text: text
        )
    }

    // MARK: - Private

    /// Derive a stored MIME type from the file extension. RTF maps to
    /// `text/plain` because its content is stored as the EXTRACTED plain text
    /// (the snapshot's `isText` / splice path treats it as plain text).
    private static func mimeType(forExtension ext: String) -> String {
        switch ext {
        case "md", "markdown": return "text/markdown"
        case "csv": return "text/csv"
        case "json": return "application/json"
        case "txt", "rtf": return "text/plain"
        default: return "text/plain"
        }
    }
}

#endif
