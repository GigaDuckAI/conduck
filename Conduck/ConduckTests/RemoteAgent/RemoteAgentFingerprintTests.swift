// SPDX-License-Identifier: Apache-2.0

// Conduck
// RemoteAgentFingerprintTests.swift
//
// Locks the SHA-256 public-key fingerprint computation used by
// `RemoteAgentTrustEvaluator` for self-signed-cert pinning. The full
// delegate path requires a real `SecTrust` object (opaque, no public
// constructor for arbitrary chains) — that integration test runs
// against a real Caddy/nginx instance during "Test Connection".
//
// Fixture: `ConduckTests/Resources/test-cert.der` is an 809-byte
// DER-encoded RSA-2048 self-signed cert. The expected public-key DER
// digest is precomputed and hardcoded below; any change to the fixture
// breaks this test deliberately (re-pin would require updating the
// constant).

import XCTest
@testable import Conduck

final class RemoteAgentFingerprintTests: XCTestCase {

    /// Expected SHA-256 (lowercase hex, no separators) of the test cert's
    /// public-key DER. Precomputed via:
    ///   openssl x509 -pubkey -in test-cert.pem -noout \
    ///     | openssl pkey -pubin -outform DER \
    ///     | shasum -a 256
    private let expectedPublicKeyDigest =
        "e79f26c30eecceb968407b38cfb7f5ad9cad4d33e90d16aa0a146cccee562867"

    /// Full-cert DER digest — included as a negative control. If we
    /// accidentally hashed the WHOLE cert instead of just the public key,
    /// this is what the test would (incorrectly) match against. Used in
    /// `testHashIsOverPublicKeyNotWholeCert` to catch that regression.
    private let fullCertDigest =
        "62b5af00388dbe7d5e4f15e028edaa86e3131f19647655388c0baee874cc44d1"

    func testFingerprintMatchesExpectedDigest() throws {
        // End-to-end SPKI digest path: parse the fixture cert, extract
        // the public key, wrap in the SPKI envelope (`spkiDER(from:)`),
        // and hash. The expected value is the SPKI digest — what users
        // see when they run `openssl x509 -pubkey | openssl pkey -pubin
        // -outform DER | shasum -a 256` against their gateway's cert.
        // Plain `SecKeyCopyExternalRepresentation` on Apple platforms
        // returns the RAW key body (PKCS#1 for RSA), NOT SPKI — those
        // hashes would mismatch the recipe users follow.
        let der = try loadFixtureDER()
        let cert = try XCTUnwrap(
            SecCertificateCreateWithData(nil, der as CFData),
            "Failed to parse fixture as a DER certificate"
        )
        let publicKey = try XCTUnwrap(
            SecCertificateCopyKey(cert),
            "Failed to extract public key from fixture cert"
        )
        let spki = try XCTUnwrap(
            RemoteAgentTrustEvaluator.spkiDER(from: publicKey),
            "spkiDER must return non-nil for a known RSA-2048 fixture"
        )

        let computed = RemoteAgentTrustEvaluator.sha256Hex(publicKeyDER: spki)
        XCTAssertEqual(
            computed,
            expectedPublicKeyDigest,
            "SPKI SHA-256 digest must match the locked fixture value (openssl recipe). Pinning regressions land here first."
        )
    }

    func testHashIsOverPublicKeyNotWholeCert() throws {
        // Defensive: ensure the helper never accidentally gets pointed at
        // the whole-cert DER. If a future refactor changes the pin shape
        // from "public-key DER" to "whole-cert DER", this test forces
        // explicit re-pinning.
        let der = try loadFixtureDER()
        let wholeCertHash = RemoteAgentTrustEvaluator.sha256Hex(publicKeyDER: der)
        XCTAssertEqual(wholeCertHash, fullCertDigest,
                       "Sanity: hashing the whole cert DER produces the documented full-cert digest")
        XCTAssertNotEqual(wholeCertHash, expectedPublicKeyDigest,
                          "Full-cert digest MUST differ from public-key digest — otherwise we cannot tell them apart in a regression")
    }

    func testEmptyInputProducesEmptyStringSHA256() {
        // RFC-mandated SHA-256 of empty input — locks the helper's
        // formatting (lowercase hex, no separators).
        let empty = RemoteAgentTrustEvaluator.sha256Hex(publicKeyDER: Data())
        XCTAssertEqual(
            empty,
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
            "Empty-input SHA-256 must match the RFC value, lowercase hex, no separators"
        )
    }

    // MARK: - Transport-error classification (the single source of truth)

    private typealias Cls = RemoteAgentTrustEvaluator.TransportErrorClass
    private func classify(
        _ code: URLError.Code,
        hasPin: Bool = false,
        systemTrustRejected: Bool = false,
        pinRejected: Bool = false
    ) -> Cls {
        RemoteAgentTrustEvaluator.classifyTransportError(
            code, hasPin: hasPin, systemTrustRejected: systemTrustRejected, pinRejected: pinRejected)
    }

    func testClassifyTimeout() {
        XCTAssertEqual(classify(.timedOut), .timeout)
        XCTAssertEqual(classify(.timedOut, hasPin: true, pinRejected: true), .timeout,
                       "Timeout is a timeout regardless of pin/trust signals.")
    }

    func testClassifyUnreachableFamily() {
        for code in [URLError.Code.cannotConnectToHost, .notConnectedToInternet,
                     .networkConnectionLost, .cannotFindHost, .dnsLookupFailed, .resourceUnavailable] {
            XCTAssertEqual(classify(code), .unreachable, "\(code) must be unreachable")
        }
    }

    func testClassifySpecificCertCodesAreUnconditional() {
        // The system NAMED the cert as the cause → classify regardless of the
        // (defensive) trust signals.
        for code in [URLError.Code.serverCertificateUntrusted, .serverCertificateHasBadDate,
                     .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid] {
            XCTAssertEqual(classify(code, hasPin: false), .untrustedCert,
                           "\(code) with no pin → TOFU untrustedCert")
            XCTAssertEqual(classify(code, hasPin: true), .certMismatch,
                           "\(code) with a pin → certMismatch")
        }
    }

    // The regression: a GENERIC `.secureConnectionFailed` must NOT be a cert
    // problem unless the trust layer actually rejected the cert.
    func testClassifySecureConnectionFailed_noPin_transient_isUnreachable() {
        XCTAssertEqual(classify(.secureConnectionFailed, hasPin: false, systemTrustRejected: false),
                       .unreachable,
                       "Cold-tunnel handshake hiccup (no system rejection) must be retryable, NOT 'untrusted certificate'.")
    }

    func testClassifySecureConnectionFailed_noPin_systemRejected_isUntrusted() {
        XCTAssertEqual(classify(.secureConnectionFailed, hasPin: false, systemTrustRejected: true),
                       .untrustedCert,
                       "A genuine no-pin system rejection that surfaced as the generic code is still a TOFU opportunity.")
    }

    func testClassifySecureConnectionFailed_pin_transient_isUnreachable() {
        XCTAssertEqual(classify(.secureConnectionFailed, hasPin: true, pinRejected: false),
                       .unreachable,
                       "A pinned host on a cold tunnel must NOT falsely read as a cert MISMATCH (which implies MITM).")
    }

    func testClassifySecureConnectionFailed_pin_pinRejected_isCertMismatch() {
        XCTAssertEqual(classify(.secureConnectionFailed, hasPin: true, pinRejected: true),
                       .certMismatch,
                       "A pinned host where the evaluator confirmed the mismatch is a genuine cert mismatch.")
    }

    func testClassifyCancelled() {
        // No pin → the evaluator never cancels → a real task cancellation.
        XCTAssertEqual(classify(.cancelled, hasPin: false), .cancelled)
        // Pin set but no confirmed rejection → still a benign cancellation.
        XCTAssertEqual(classify(.cancelled, hasPin: true, pinRejected: false), .cancelled)
        // Pin set + evaluator confirmed the mismatch → cert mismatch.
        XCTAssertEqual(classify(.cancelled, hasPin: true, pinRejected: true), .certMismatch)
    }

    func testClassifyCancelledIgnoresSystemTrustRejected() {
        // `.cancelled` is disambiguated ONLY by `pinRejected` (the evaluator
        // cancels solely on a pin mismatch). `systemTrustRejected` is a no-pin
        // default-handling signal and must NOT turn a benign cancellation into
        // a cert outcome.
        XCTAssertEqual(classify(.cancelled, hasPin: false, systemTrustRejected: true), .cancelled,
                       "No-pin .cancelled is a task cancellation regardless of systemTrustRejected.")
        XCTAssertEqual(classify(.cancelled, hasPin: true, systemTrustRejected: true, pinRejected: false), .cancelled,
                       "Pin set + .cancelled without a confirmed pin mismatch stays a benign cancellation.")
    }

    func testClassifyUnknownCodeIsUnreachable() {
        XCTAssertEqual(classify(.badServerResponse), .unreachable)
        XCTAssertEqual(classify(.badURL), .unreachable)
    }

    // MARK: - Helpers

    private func loadFixtureDER() throws -> Data {
        let bundle = Bundle(for: type(of: self))
        let url = try XCTUnwrap(
            bundle.url(forResource: "test-cert", withExtension: "der"),
            "Fixture test-cert.der missing from test bundle Resources"
        )
        return try Data(contentsOf: url)
    }
}
