// Conduck
// ImageFormatSniffer.swift
//
// Magic-number content sniffer for image bytes → (extension, MIME type). Used
// by the file-transfer route, which PUTs the ORIGINAL picked bytes (HEIC / PNG
// / DNG / JPEG, metadata intact) to the user's file-server so the agent's tools
// act on the real file — and therefore needs the file's TRUE extension + type.
//
// WHY SNIFF BYTES (not thread a `UTType` through the pickers): an image reaches
// staging from THREE source-distinct paths — `PhotosPicker` (Transferable
// `Data`, no URL / type metadata survives the load), `fileImporter` (a
// security-scoped URL with an extension), and drag-drop (raw `NSItemProvider`,
// `NSImage` data with no filename). Plumbing a reliable type identifier through
// all three is fragile (the PhotosPicker path has NO type at all). The bytes
// themselves are the single source of truth available on EVERY path, so we read
// the leading magic bytes once at staging and derive (ext, mime) from those —
// source-agnostic, no per-picker special-casing.
//
// Pure Foundation, no platform frameworks (ImageIO / UTType): harmless to
// compile cross-target (incl. a future Watch membership add — it never runs
// there, but it costs nothing if dragged in).

import Foundation

/// Detected on-disk format for image bytes: the file `ext` (no dot) the upload
/// names the file with, and the `mime` the agent's tooling sees. `bin` /
/// `application/octet-stream` is the fallback for unrecognised leading bytes
/// (the file still uploads under a safe generic extension — never blocks).
enum ImageFormatSniffer {

    /// The format derived from a `Data`'s leading bytes.
    struct Format: Equatable {
        /// File extension WITHOUT the leading dot (e.g. `"heic"`, `"png"`).
        let ext: String
        /// MIME type (e.g. `"image/heic"`, `"image/png"`).
        let mime: String
    }

    /// HEIF brand set (`ftyp` box major brand at bytes 8..<12) we treat as
    /// HEIC. Modern iPhone library photos are HEIC; `mif1`/`msf1` are the
    /// still-image HEIF brands; `hevc`/`hevx`/`heim`/`heis`/`heix` cover the
    /// HEVC-coded variants. Any of these → upload as `.heic`.
    private static let heifBrands: Set<String> = [
        "heic", "heix", "mif1", "msf1", "hevc", "heim", "heis", "hevx",
    ]

    /// Map a `Data`'s leading bytes to a `(ext, mime)` via magic numbers. Pure +
    /// total: any input returns SOME format (unknown → `.bin` /
    /// `application/octet-stream`), so it never throws and never blocks an
    /// upload. Reads at most the first 12 bytes.
    static func sniff(_ data: Data) -> Format {
        let bytes = [UInt8](data.prefix(12))

        // JPEG: FF D8 FF
        if bytes.starts(with: [0xFF, 0xD8, 0xFF]) {
            return Format(ext: "jpg", mime: "image/jpeg")
        }

        // PNG: 89 50 4E 47 0D 0A 1A 0A
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) {
            return Format(ext: "png", mime: "image/png")
        }

        // GIF: 47 49 46 38 ("GIF8")
        if bytes.starts(with: [0x47, 0x49, 0x46, 0x38]) {
            return Format(ext: "gif", mime: "image/gif")
        }

        // TIFF / DNG: little-endian `II*\0` (49 49 2A 00) or big-endian
        // `MM\0*` (4D 4D 00 2A). (Apple ProRAW DNG is a TIFF/EP container.)
        if bytes.starts(with: [0x49, 0x49, 0x2A, 0x00]) ||
           bytes.starts(with: [0x4D, 0x4D, 0x00, 0x2A]) {
            return Format(ext: "tiff", mime: "image/tiff")
        }

        // HEIC / HEIF: an ISO-BMFF `ftyp` box — bytes 4..<8 == "ftyp" AND the
        // major brand at 8..<12 is a HEIF brand. (Bytes 0..<4 are the box size,
        // not a fixed magic, so we anchor on the `ftyp` tag + brand.)
        if bytes.count >= 12,
           ascii(bytes, 4..<8) == "ftyp",
           let brand = ascii(bytes, 8..<12),
           heifBrands.contains(brand) {
            return Format(ext: "heic", mime: "image/heic")
        }

        // WEBP: RIFF container — bytes 0..<4 == "RIFF" AND 8..<12 == "WEBP"
        // (bytes 4..<8 are the little-endian file size, skipped).
        if bytes.count >= 12,
           ascii(bytes, 0..<4) == "RIFF",
           ascii(bytes, 8..<12) == "WEBP" {
            return Format(ext: "webp", mime: "image/webp")
        }

        return Format(ext: "bin", mime: "application/octet-stream")
    }

    /// Decode a fixed byte range of `bytes` as ASCII (used for the `ftyp` /
    /// brand / RIFF / WEBP four-char tags). Returns nil if the range is out of
    /// bounds or not valid ASCII.
    private static func ascii(_ bytes: [UInt8], _ range: Range<Int>) -> String? {
        guard range.upperBound <= bytes.count else { return nil }
        return String(bytes: bytes[range], encoding: .ascii)
    }
}
