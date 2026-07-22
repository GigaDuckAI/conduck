// Conduck
// DataURIBuilderTests.swift
//
// V1.1 Core Attachments. Locks the `DataURIBuilder.jpegDataURI(from:)` wire
// contract: a `data:image/jpeg;base64,<base64>` URI whose base64 payload
// round-trips back to the ORIGINAL bytes (the only portable image input across
// arbitrary BYO gateways). Pure / deterministic — no platform guard needed
// (the builder is plain Foundation), but the source file is excluded from the
// Watch compile set; that's a membership concern, not a test concern.

import XCTest
@testable import Conduck

final class DataURIBuilderTests: XCTestCase {

    func testProducesJPEGDataURIPrefix() {
        let bytes = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10]) // JPEG SOI-ish bytes
        let uri = DataURIBuilder.jpegDataURI(from: bytes)
        XCTAssertTrue(uri.hasPrefix("data:image/jpeg;base64,"),
                      "URI must start with the fixed `data:image/jpeg;base64,` prefix. Got: \(uri.prefix(40))")
    }

    func testBase64PayloadRoundTripsToOriginalBytes() throws {
        // Use a non-trivial byte pattern (incl. 0x00 and high bytes) so a
        // truncation / encoding bug can't pass.
        let original = Data((0..<256).map { UInt8($0) })
        let uri = DataURIBuilder.jpegDataURI(from: original)

        let prefix = "data:image/jpeg;base64,"
        let base64 = try XCTUnwrap(uri.hasPrefix(prefix) ? String(uri.dropFirst(prefix.count)) : nil,
                                   "URI must carry the base64 body after the prefix.")
        let decoded = try XCTUnwrap(Data(base64Encoded: base64),
                                    "The payload after the prefix must be valid base64.")
        XCTAssertEqual(decoded, original,
                       "Decoding the base64 body must reproduce the original JPEG bytes exactly.")
    }

    func testEmptyDataStillProducesValidPrefixWithEmptyBody() {
        // Defensive: empty input is a degenerate but valid case — prefix present,
        // empty base64 body decodes to empty Data.
        let uri = DataURIBuilder.jpegDataURI(from: Data())
        XCTAssertEqual(uri, "data:image/jpeg;base64,",
                       "Empty bytes yield the bare prefix with an empty base64 body.")
        let body = String(uri.dropFirst("data:image/jpeg;base64,".count))
        XCTAssertEqual(Data(base64Encoded: body), Data(),
                       "Empty base64 body must decode to empty Data.")
    }
}
