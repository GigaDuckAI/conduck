// SPDX-License-Identifier: Apache-2.0

// Conduck
// ImageFormatSnifferTests.swift
//
// Locks the magic-number → (ext, mime) mapping in `ImageFormatSniffer`. The
// file-transfer route PUTs the ORIGINAL picked bytes in their true format, so
// the upload must land on the user's server with the CORRECT extension + MIME —
// a mis-sniff would mislabel a HEIC as a JPEG (the agent's tooling would then
// mis-handle it). These tests synthesise only the LEADING bytes (a real codec
// payload isn't needed — the sniffer reads at most the first 12 bytes) so they
// stay deterministic + environment-independent (no HEIC encoder required).

import XCTest
@testable import Conduck

final class ImageFormatSnifferTests: XCTestCase {

    /// Build a `Data` from a magic-number prefix + a little padding (the sniffer
    /// only reads the head, but real files are never 4 bytes long).
    private func bytes(_ head: [UInt8], pad: Int = 8) -> Data {
        Data(head + Array(repeating: 0x00, count: pad))
    }

    /// Build a `Data` for an ISO-BMFF / RIFF container: a 4-byte box size, a
    /// 4-char tag, then a 4-char brand (ASCII → bytes).
    private func container(sizeOrTag: [UInt8], tag: String, brand: String) -> Data {
        Data(sizeOrTag + Array(tag.utf8) + Array(brand.utf8) + [0x00, 0x00, 0x00, 0x00])
    }

    func testJPEGMagic() {
        let f = ImageFormatSniffer.sniff(bytes([0xFF, 0xD8, 0xFF, 0xE0]))
        XCTAssertEqual(f, .init(ext: "jpg", mime: "image/jpeg"))
    }

    func testPNGMagic() {
        let f = ImageFormatSniffer.sniff(bytes([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]))
        XCTAssertEqual(f, .init(ext: "png", mime: "image/png"))
    }

    func testGIFMagic() {
        // "GIF8" (covers both GIF87a + GIF89a — the 4-byte prefix is shared).
        let f = ImageFormatSniffer.sniff(bytes([0x47, 0x49, 0x46, 0x38, 0x39, 0x61]))
        XCTAssertEqual(f, .init(ext: "gif", mime: "image/gif"))
    }

    func testTIFFLittleEndianMagic() {
        // II*\0 — also the container DNG (ProRAW) rides in.
        let f = ImageFormatSniffer.sniff(bytes([0x49, 0x49, 0x2A, 0x00]))
        XCTAssertEqual(f, .init(ext: "tiff", mime: "image/tiff"))
    }

    func testTIFFBigEndianMagic() {
        // MM\0*
        let f = ImageFormatSniffer.sniff(bytes([0x4D, 0x4D, 0x00, 0x2A]))
        XCTAssertEqual(f, .init(ext: "tiff", mime: "image/tiff"))
    }

    func testHEICBrandIsHeic() {
        // <size> "ftyp" "heic" — the canonical iPhone-library HEIC brand.
        let data = container(sizeOrTag: [0x00, 0x00, 0x00, 0x18], tag: "ftyp", brand: "heic")
        XCTAssertEqual(ImageFormatSniffer.sniff(data), .init(ext: "heic", mime: "image/heic"))
    }

    func testHEICBrandMif1() {
        // mif1 is the still-image HEIF brand — also mapped to heic.
        let data = container(sizeOrTag: [0x00, 0x00, 0x00, 0x18], tag: "ftyp", brand: "mif1")
        XCTAssertEqual(ImageFormatSniffer.sniff(data), .init(ext: "heic", mime: "image/heic"))
    }

    func testHEICBrandHeix() {
        let data = container(sizeOrTag: [0x00, 0x00, 0x00, 0x18], tag: "ftyp", brand: "heix")
        XCTAssertEqual(ImageFormatSniffer.sniff(data), .init(ext: "heic", mime: "image/heic"))
    }

    /// An `ftyp` box whose brand is NOT a HEIF brand (e.g. an MP4 `isom`) must
    /// NOT be claimed as HEIC — it falls through to the generic fallback.
    func testFtypNonHeifBrandFallsThrough() {
        let data = container(sizeOrTag: [0x00, 0x00, 0x00, 0x18], tag: "ftyp", brand: "isom")
        XCTAssertEqual(ImageFormatSniffer.sniff(data), .init(ext: "bin", mime: "application/octet-stream"))
    }

    func testWEBPMagic() {
        // "RIFF"(0..<4) <little-endian size>(4..<8) "WEBP"(8..<12) — the size
        // bytes are skipped by the sniffer (it anchors on RIFF + WEBP).
        let webp = Data(Array("RIFF".utf8) + [0x1A, 0x00, 0x00, 0x00] + Array("WEBP".utf8) + [0x00, 0x00])
        XCTAssertEqual(ImageFormatSniffer.sniff(webp), .init(ext: "webp", mime: "image/webp"))
    }

    /// Unknown leading bytes → the generic fallback (the file still uploads
    /// under a safe extension; sniffing never blocks).
    func testUnknownBytesFallBackToBin() {
        let f = ImageFormatSniffer.sniff(bytes([0x00, 0x01, 0x02, 0x03, 0x04, 0x05]))
        XCTAssertEqual(f, .init(ext: "bin", mime: "application/octet-stream"))
    }

    /// Truncated input (fewer than the bytes a container check needs) must not
    /// crash — it falls back rather than reading out of bounds.
    func testTruncatedInputDoesNotCrash() {
        XCTAssertEqual(ImageFormatSniffer.sniff(Data([0x47, 0x49])), // partial "GI"
                       .init(ext: "bin", mime: "application/octet-stream"))
        XCTAssertEqual(ImageFormatSniffer.sniff(Data()),
                       .init(ext: "bin", mime: "application/octet-stream"))
    }
}
