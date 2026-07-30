// SPDX-License-Identifier: Apache-2.0

// Conduck
// GatewayChatSuccessTests.swift
//
// The per-ref "a real chat turn completed from THIS device" record. Two
// properties carry the whole feature and both are easy to break silently:
//
//  1. The signature must be STABLE ACROSS PROCESSES. The obvious implementation
//     (`Hasher`) is seeded per launch, so a stored record would compare unequal
//     to its own config after every relaunch and the feature would appear to do
//     nothing — with no failing test and no crash. Pinned here.
//  2. The signature must MOVE when the configuration meaningfully moves, so an
//     edited gateway cannot inherit a success it never earned.
//
// Pure value type, no storage — runs on the unsigned sim.

import XCTest
@testable import Conduck

final class GatewayChatSuccessTests: XCTestCase {

    private let url = URL(string: "https://gateway.example/agent")!

    private func signature(
        url: URL? = nil,
        authScheme: RemoteAgentAuthScheme = .bearer,
        model: String? = "gpt-oss",
        pin: String? = nil,
        kind: String = "openclaw"
    ) -> String {
        GatewayChatSuccess.signature(
            url: url ?? self.url,
            authScheme: authScheme,
            model: model,
            pinnedFingerprintHex: pin,
            kind: kind
        )
    }

    // MARK: - stability (the `Hasher` trap)

    /// A cryptographic digest is deterministic across processes; `Hasher` is not.
    /// This test would still pass under `Hasher` WITHIN one process, so it also
    /// asserts the exact expected digest — the only form that catches a swap to a
    /// per-process hash.
    func testSignatureIsDeterministicAndNotAPerProcessHash() {
        let a = signature()
        let b = signature()
        XCTAssertEqual(a, b, "same inputs must yield the same signature")
        XCTAssertEqual(a.count, 16, "8 bytes rendered as hex — wide enough to gate a correctness decision")
        XCTAssertEqual(
            a,
            GatewayChatSuccess.signature(
                url: url, authScheme: .bearer, model: "gpt-oss",
                pinnedFingerprintHex: nil, kind: "openclaw"
            ),
            "the signature is a pure function of its inputs"
        )
        // A frozen expected value: `Hasher` cannot reproduce a fixed digest
        // across runs, so pinning one is what makes property (1) enforceable.
        XCTAssertEqual(a, "a6781f718ce705ee",
                       "SHA-256 over the canonical parts — a change here means the stored records of every existing user silently stop matching, so treat a failure as a migration question, not a test to update")
    }

    // MARK: - invalidation

    func testChangingTheURLInvalidates() {
        XCTAssertNotEqual(
            signature(),
            signature(url: URL(string: "https://gateway.example/other")!),
            "a different destination is a different thing to have proven"
        )
    }

    func testChangingTheModelInvalidates() {
        XCTAssertNotEqual(signature(), signature(model: "llama"))
        XCTAssertNotEqual(signature(model: nil), signature(model: "llama"),
                          "acquiring a required model is a real change")
    }

    func testSwitchingAuthSchemeInvalidates() {
        XCTAssertNotEqual(signature(), signature(authScheme: RemoteAgentAuthScheme.none),
                          "bearer → keyless changes what the route proves")
    }

    func testAddingOrRemovingAPinInvalidates() {
        XCTAssertNotEqual(signature(), signature(pin: "aa:bb:cc"),
                          "arriving at a pinned connection is a configuration change")
    }

    /// A pin's VALUE is a per-device tightening; what matters is whether one is in
    /// force. Rotating a certificate the user re-pins must not discard a proven
    /// route, so presence — not the hex — enters the signature.
    func testPinValueItselfDoesNotInvalidate() {
        XCTAssertEqual(signature(pin: "aa:bb:cc"), signature(pin: "dd:ee:ff"),
                       "pin PRESENCE is signed, never the fingerprint value")
    }

    func testDifferentRefsNeverShareASignature() {
        XCTAssertNotEqual(signature(kind: "openclaw"), signature(kind: "hermes"))
        XCTAssertNotEqual(
            signature(kind: "custom_\(UUID().uuidString)"),
            signature(kind: "custom_\(UUID().uuidString)"),
            "two custom gateways with identical settings are still different gateways"
        )
    }

    // MARK: - the record round-trips

    func testRecordCodableRoundTrip() throws {
        let record = GatewayChatSuccess(signature: signature(), at: Date(timeIntervalSince1970: 1_780_000_000))
        let decoded = try JSONDecoder().decode(
            GatewayChatSuccess.self,
            from: try JSONEncoder().encode(record)
        )
        XCTAssertEqual(decoded, record, "the stored form must survive a launch unchanged")
    }
}
