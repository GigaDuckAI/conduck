// Conduck
// RemoteAgentAuthSchemeTests.swift
//
// Keyless-gateway support: the per-ref auth scheme (`.bearer` / `.none`) is an
// EXPLICIT, persisted, fail-closed choice — keyless is NEVER inferred from a
// missing token. These pure tests lock the two safety-critical primitives:
//   1. `RemoteAgentAuthScheme` — fail-closed default + header omission for `.none`.
//   2. `RemoteAgentBroadcastEnvelope` — the scheme rides the wire explicitly and
//      a MISSING wire key decodes to `.bearer` (an un-upgraded sender stays
//      authenticated; the Watch never goes keyless except on an explicit `.none`).
// SettingsManager persistence + the configured/route/send predicate that consume
// the scheme are exercised by the signed founder runtime gate (Keychain-bound).

import XCTest
@testable import Conduck

final class RemoteAgentAuthSchemeTests: XCTestCase {

    // MARK: - Fail-closed default

    func testFromRawValueDefaultsToBearer() {
        XCTAssertEqual(RemoteAgentAuthScheme.from(rawValue: nil), .bearer,
                       "A missing stored value MUST fail closed to .bearer.")
        XCTAssertEqual(RemoteAgentAuthScheme.from(rawValue: "garbage"), .bearer,
                       "An unrecognized raw value MUST fail closed to .bearer.")
        XCTAssertEqual(RemoteAgentAuthScheme.from(rawValue: "bearer"), .bearer)
        XCTAssertEqual(RemoteAgentAuthScheme.from(rawValue: "none"), .none)
        XCTAssertEqual(RemoteAgentAuthScheme.default, .bearer)
    }

    func testRequiresToken() {
        XCTAssertTrue(RemoteAgentAuthScheme.bearer.requiresToken)
        XCTAssertFalse(RemoteAgentAuthScheme.none.requiresToken,
                       "Keyless must NOT require a token.")
    }

    // MARK: - Header application (the core security behavior)

    func testBearerSetsAuthorizationHeader() {
        var request = URLRequest(url: URL(string: "https://gateway.local:18789/v1/chat/completions")!)
        RemoteAgentAuthScheme.bearer.apply(to: &request, token: "secret-token")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret-token")
    }

    func testNoneOmitsAuthorizationHeader() {
        var request = URLRequest(url: URL(string: "https://gateway.local:18789/v1/chat/completions")!)
        // Even if a (stale) token is somehow passed, `.none` MUST omit the header.
        RemoteAgentAuthScheme.none.apply(to: &request, token: "stale-token")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"),
                     "Keyless (.none) MUST send NO Authorization header, even with a token argument.")
    }

    // MARK: - Envelope wire — explicit scheme + fail-closed decode

    func testEnvelopeKeylessSchemeRoundTrips() throws {
        let url = try XCTUnwrap(URL(string: "https://ollama.tailnet.ts.net"))
        let original = RemoteAgentBroadcastEnvelope(
            backendRef: "custom_abc",
            url: url,
            name: "Mac mini",
            model: "llama3",
            colorID: nil,
            monogram: nil,
            token: nil,
            authScheme: .none,
            certFingerprintHex: nil,
            activeSessionID: nil,
            timestamp: 1.0
        )
        let dict = original.encodedDict()
        XCTAssertEqual(dict["authScheme"] as? String, "none",
                       "The keyless scheme MUST be explicit on the wire.")
        let decoded = try XCTUnwrap(RemoteAgentBroadcastEnvelope.decode(from: dict))
        XCTAssertEqual(decoded.authScheme, .none)
    }

    func testEnvelopeBearerSchemeIsAlwaysEncoded() throws {
        let url = try XCTUnwrap(URL(string: "https://gateway.local:18789"))
        let original = RemoteAgentBroadcastEnvelope(
            backendRef: "openclaw",
            url: url,
            name: nil, model: nil, colorID: nil, monogram: nil,
            token: "tok",
            authScheme: .bearer,
            certFingerprintHex: nil,
            activeSessionID: nil,
            timestamp: 2.0
        )
        XCTAssertEqual(original.encodedDict()["authScheme"] as? String, "bearer",
                       "authScheme is ALWAYS encoded (like fileTransferAvailable), never omitted.")
    }

    func testEnvelopeMissingAuthSchemeKeyDecodesToBearer() throws {
        // Simulate an un-upgraded sender: a payload with NO authScheme key.
        let dict: [String: Any] = [
            "backend": "openclaw",
            "url": "https://gateway.local:18789",
            "timestamp": 3.0,
            "token": "legacy-token",
        ]
        let decoded = try XCTUnwrap(RemoteAgentBroadcastEnvelope.decode(from: dict))
        XCTAssertEqual(decoded.authScheme, .bearer,
                       "A missing authScheme key MUST fail closed to .bearer (legacy sender stays authenticated; Watch never silently goes keyless).")
    }

    func testEnvelopeUnknownAuthSchemeDecodesToBearer() throws {
        let dict: [String: Any] = [
            "backend": "openclaw",
            "url": "https://gateway.local:18789",
            "timestamp": 4.0,
            "authScheme": "totally-bogus",
        ]
        let decoded = try XCTUnwrap(RemoteAgentBroadcastEnvelope.decode(from: dict))
        XCTAssertEqual(decoded.authScheme, .bearer)
    }

    // MARK: - Multi-envelope sub carries the scheme

    func testMultiEnvelopeSubCarriesKeylessScheme() throws {
        let url = try XCTUnwrap(URL(string: "https://ollama.tailnet.ts.net"))
        let keylessSub = RemoteAgentBroadcastEnvelope(
            backendRef: "custom_xyz",
            url: url,
            name: "Box", model: nil, colorID: nil, monogram: nil,
            token: nil,
            authScheme: .none,
            certFingerprintHex: nil,
            activeSessionID: nil,
            timestamp: 9.0
        )
        let multi = RemoteAgentMultiBroadcastEnvelope(
            backends: [keylessSub],
            defaultBackendRef: "custom_xyz",
            timestamp: 9.0,
            sessionPolicy: nil
        )
        let decoded = try XCTUnwrap(RemoteAgentMultiBroadcastEnvelope.decode(from: multi.encodedDict()))
        let decodedSub = try XCTUnwrap(decoded.backends.first)
        // Disambiguate from `Optional.none` — compare the non-optional scheme.
        XCTAssertEqual(decodedSub.authScheme, RemoteAgentAuthScheme.none,
                       "A keyless sub-envelope MUST round-trip its scheme through the multi-broadcast.")
    }
}
