// SPDX-License-Identifier: Apache-2.0

// Conduck
// SharedInboxUploadKeyTests.swift
//
// Share Extension — coverage for the deterministic per-attachment upload
// key (`FileServerClient.deterministicStoredKey`) + the file-transfer recovery
// metadata's new `shareEnvelopeID` / `sequence` fields. The key must be:
//   - stable for the same (envelopeID, sequence, originalName) → a relaunch
//     re-PUTs the SAME path (idempotent — WebDAV PUT overwrites identical bytes)
//   - collision-free across distinct sequences in one envelope (same filename)
//   - sanitized to the WebDAV-safe path-component set (others → `-`)
//
// Pure Foundation — no network, no Keychain, no signing.

import XCTest
@testable import Conduck

final class SharedInboxUploadKeyTests: XCTestCase {

    // MARK: - Shape

    func testKeyShapeIsShortHexDashSequenceDoubleUnderscoreName() {
        let uuid = try! XCTUnwrap(UUID(uuidString: "E621E1F8-C36C-495A-93FC-0C247A3E6E5F"))
        let key = FileServerClient.deterministicStoredKey(
            envelopeID: uuid, sequence: 2, originalName: "report.pdf"
        )
        XCTAssertEqual(key, "e621e1f8-2__report.pdf",
                       "Key = <first-8-of-uuid lowercased>-<sequence>__<sanitized name>.")
    }

    // MARK: - Determinism + collision-freedom

    func testKeyIsDeterministicForSameInputs() {
        let uuid = UUID()
        let a = FileServerClient.deterministicStoredKey(envelopeID: uuid, sequence: 0, originalName: "data.csv")
        let b = FileServerClient.deterministicStoredKey(envelopeID: uuid, sequence: 0, originalName: "data.csv")
        XCTAssertEqual(a, b, "Same (envelopeID, sequence, name) must recompute the SAME key (idempotent re-PUT).")
    }

    func testSameNameDifferentSequenceDoesNotCollide() {
        let uuid = UUID()
        let name = "photo.jpg"
        let s0 = FileServerClient.deterministicStoredKey(envelopeID: uuid, sequence: 0, originalName: name)
        let s1 = FileServerClient.deterministicStoredKey(envelopeID: uuid, sequence: 1, originalName: name)
        let s2 = FileServerClient.deterministicStoredKey(envelopeID: uuid, sequence: 2, originalName: name)
        XCTAssertEqual(Set([s0, s1, s2]).count, 3,
                       "Two same-named files in one envelope must get distinct keys (the <sequence> segment).")
    }

    func testPrefixVariesWithEnvelopeID() {
        let name = "x.txt"
        let a = FileServerClient.deterministicStoredKey(envelopeID: UUID(), sequence: 0, originalName: name)
        let b = FileServerClient.deterministicStoredKey(envelopeID: UUID(), sequence: 0, originalName: name)
        XCTAssertNotEqual(a, b, "Distinct envelopes must yield distinct keys (the 8-hex prefix).")
    }

    // MARK: - Sanitization

    func testSanitizesUnsafeCharactersToDash() {
        let uuid = try! XCTUnwrap(UUID(uuidString: "E621E1F8-C36C-495A-93FC-0C247A3E6E5F"))
        let key = FileServerClient.deterministicStoredKey(
            envelopeID: uuid, sequence: 0, originalName: "my report (final)/v2.pdf"
        )
        // Spaces, parens, and the slash all collapse to `-`; alnum/dot kept.
        XCTAssertEqual(key, "e621e1f8-0__my-report--final--v2.pdf")
        XCTAssertFalse(key.contains(" "))
        XCTAssertFalse(key.contains("/"))
        XCTAssertFalse(key.contains("("))
    }

    func testPreservesDotsDashesUnderscores() {
        let uuid = UUID()
        let key = FileServerClient.deterministicStoredKey(
            envelopeID: uuid, sequence: 1, originalName: "a.b-c_d.tar.gz"
        )
        XCTAssertTrue(key.hasSuffix("__a.b-c_d.tar.gz"),
                      "Dots / dashes / underscores in the original name must be preserved.")
    }

    func testEmptySanitizedNameFallsBackToFile() {
        let uuid = UUID()
        let key = FileServerClient.deterministicStoredKey(
            envelopeID: uuid, sequence: 0, originalName: "   "
        )
        // Three spaces → "---" is non-empty, so it is NOT the empty fallback; an
        // ACTUALLY-empty original name is the fallback case.
        XCTAssertTrue(key.hasSuffix("__---"))

        let keyEmpty = FileServerClient.deterministicStoredKey(
            envelopeID: uuid, sequence: 0, originalName: ""
        )
        XCTAssertTrue(keyEmpty.hasSuffix("__file"),
                      "An empty original name must fall back to `file` so the key is well-formed.")
    }

    // MARK: - FileTransferBackgroundMetadata share fields

    func testMetadataShareFieldsRoundTrip() throws {
        let envelopeID = UUID()
        let original = FileTransferBackgroundMetadata(
            storedKey: "e621e1f8-0__x.pdf",
            refSuffix: "openclaw",
            direction: .upload,
            shareEnvelopeID: envelopeID,
            sequence: 0
        )
        let encoded = try XCTUnwrap(original.encoded())
        let decoded = try XCTUnwrap(FileTransferBackgroundMetadata.decoded(from: encoded))
        XCTAssertEqual(decoded.shareEnvelopeID, envelopeID)
        XCTAssertEqual(decoded.sequence, 0)
        XCTAssertEqual(decoded.direction, .upload)
    }

    func testMetadataDefaultsShareFieldsToNil() throws {
        // The in-app composer's uploads construct metadata WITHOUT share fields.
        let original = FileTransferBackgroundMetadata(
            storedKey: "k", refSuffix: "", direction: .upload
        )
        XCTAssertNil(original.shareEnvelopeID)
        XCTAssertNil(original.sequence)
        let decoded = try XCTUnwrap(FileTransferBackgroundMetadata.decoded(from: original.encoded()))
        XCTAssertNil(decoded.shareEnvelopeID)
        XCTAssertNil(decoded.sequence)
    }

    func testMetadataTolerantDecodeOfPreShareTaskDescription() throws {
        // A taskDescription written before the share fields existed must decode
        // (Optional → decodeIfPresent → nil, not a decode failure).
        let legacy = #"{"storedKey":"k","refSuffix":"","direction":"upload"}"#
        let decoded = try XCTUnwrap(FileTransferBackgroundMetadata.decoded(from: legacy))
        XCTAssertEqual(decoded.storedKey, "k")
        XCTAssertNil(decoded.shareEnvelopeID)
        XCTAssertNil(decoded.sequence)
    }
}
