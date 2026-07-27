// SPDX-License-Identifier: Apache-2.0

// Conduck
// APIKeyReadResultTests.swift
//
// The PURE `APIKeyReadResult.classify(status:data:)` matrix — the typed
// primitive that replaced the old `getAPIKey → String?` nil-collapse (a nil
// used to mean "no key" OR "Keychain couldn't answer"). Because it is a pure
// function of an `OSStatus` + payload, the whole status→state mapping is
// testable on an UNSIGNED simulator, with no live `SecItemCopyMatching`.

#if !os(watchOS)
import XCTest
import Security
@testable import Conduck

@MainActor
final class APIKeyReadResultTests: XCTestCase {

    // MARK: - classify matrix

    func testSuccessWithValidUTF8IsPresent() {
        let data = Data("sk-live-abc123".utf8)
        XCTAssertEqual(APIKeyReadResult.classify(status: errSecSuccess, data: data),
                       .present("sk-live-abc123"),
                       "errSecSuccess + a non-empty UTF-8 payload is a present key.")
    }

    func testSuccessWithEmptyStringIsUnreadableDecode() {
        // An item EXISTS but its payload is empty — not usable, and NOT `.missing`
        // (that would claim the slot is absent). Mapped to errSecDecode.
        XCTAssertEqual(APIKeyReadResult.classify(status: errSecSuccess, data: Data("".utf8)),
                       .unreadable(errSecDecode),
                       "errSecSuccess + an empty payload classifies as .unreadable(errSecDecode).")
    }

    func testSuccessWithNilDataIsUnreadableDecode() {
        XCTAssertEqual(APIKeyReadResult.classify(status: errSecSuccess, data: nil),
                       .unreadable(errSecDecode),
                       "errSecSuccess + no payload classifies as .unreadable(errSecDecode).")
    }

    func testItemNotFoundIsMissing() {
        XCTAssertEqual(APIKeyReadResult.classify(status: errSecItemNotFound, data: nil),
                       .missing,
                       "errSecItemNotFound is a genuinely absent key → .missing.")
    }

    func testInteractionNotAllowedIsUnreadableWithThatStatus() {
        // A locked keychain / auth failure — the item may exist but couldn't be
        // returned. The RAW status is preserved (never collapsed to .missing).
        XCTAssertEqual(APIKeyReadResult.classify(status: errSecInteractionNotAllowed, data: nil),
                       .unreadable(errSecInteractionNotAllowed),
                       "A non-success, non-not-found status carries through as .unreadable(status).")
    }

    // MARK: - keyState projection (the ring-safe token)

    func testKeyStateProjectionDropsKeyMaterial() {
        XCTAssertEqual(APIKeyReadResult.present("sk-secret").keyState, .present,
                       ".present projects to the .present key-state token (no key material).")
        XCTAssertEqual(APIKeyReadResult.missing.keyState, .missing)
        XCTAssertEqual(APIKeyReadResult.unreadable(errSecInteractionNotAllowed).keyState, .unreadable,
                       "The raw OSStatus never leaks into the privacy-safe key-state token.")
    }
}
#endif
