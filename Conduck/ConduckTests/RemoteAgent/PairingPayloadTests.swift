// Conduck
// PairingPayloadTests.swift
//
// Covers `PairingPayload.parse(_:)` — the `conduck-setup:v1:<base64(JSON)>`
// pairing-string parser (`spec.md` "Gateway Setup & Pairing"). The error
// taxonomy is LOAD-BEARING for onboarding/Settings UI copy: notAPairingCode
// lets the scanner ignore unrelated QR codes, unsupportedVersion drives
// "update the app", insecureURL names the https violation, and everything
// else collapses to malformed. Test payloads use synthetic tokens /
// credentials only — never real secrets.

import XCTest
@testable import Conduck

final class PairingPayloadTests: XCTestCase {

    // MARK: - Fixtures & helpers

    /// 64 lowercase hex chars — a syntactically valid SPKI SHA-256.
    private let gatewayFP = String(repeating: "ab", count: 32)
    private let fileServerFP = String(repeating: "cd", count: 32)

    /// Build a pairing string from a JSON dict the way `conduck-connect`
    /// does (minified JSON → base64 → prefixed segments).
    private func pairingString(
        _ json: [String: Any],
        version: String = "v1"
    ) -> String {
        let data = try! JSONSerialization.data(withJSONObject: json)
        return "conduck-setup:\(version):\(data.base64EncodedString())"
    }

    /// Full valid payload — custom gateway with every optional field set.
    private func fullDict() -> [String: Any] {
        [
            "v": 1,
            "gateway": [
                "kind": "custom",
                "name": "Home Lab",
                "url": "https://gw.example.ts.net:18789",
                "auth": "bearer",
                "token": "tok-test-123",
                "certFP": gatewayFP,
                "model": "test-model",
            ],
            "fileServer": [
                "url": "https://files.example.ts.net:8443",
                "credential": "cred-test-456",
                "certFP": fileServerFP,
            ],
            "transport": "tailscale",
        ]
    }

    /// Minimal valid payload — built-in bearer gateway, nothing optional.
    private func minimalDict(kind: String = "openclaw") -> [String: Any] {
        [
            "v": 1,
            "gateway": [
                "kind": kind,
                "url": "https://gw.example.com",
                "auth": "bearer",
                "token": "tok-test-123",
            ],
        ]
    }

    @discardableResult
    private func assertParses(
        _ string: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> PairingPayload? {
        switch PairingPayload.parse(string) {
        case .success(let payload):
            return payload
        case .failure(let error):
            XCTFail("Expected successful parse, got .\(error)", file: file, line: line)
            return nil
        }
    }

    private func assertFails(
        _ string: String,
        with expected: PairingParseError,
        _ message: String = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        switch PairingPayload.parse(string) {
        case .success:
            XCTFail("Expected .\(expected), got success. \(message)", file: file, line: line)
        case .failure(let error):
            XCTAssertEqual(error, expected, message, file: file, line: line)
        }
    }

    // MARK: - Valid payloads

    func testFullPayloadRoundTripAssertsEveryField() {
        guard let payload = assertParses(pairingString(fullDict())) else { return }

        XCTAssertEqual(payload.kind, .custom(name: "Home Lab"))
        XCTAssertEqual(payload.url, URL(string: "https://gw.example.ts.net:18789"))
        XCTAssertEqual(payload.authScheme, .bearer)
        XCTAssertEqual(payload.token, "tok-test-123")
        XCTAssertEqual(payload.certFP, gatewayFP)
        XCTAssertEqual(payload.model, "test-model")
        XCTAssertEqual(payload.transport, .tailscale)

        guard let fileServer = payload.fileServer else {
            XCTFail("fileServer block present in payload must decode non-nil")
            return
        }
        XCTAssertEqual(fileServer.url, URL(string: "https://files.example.ts.net:8443"))
        XCTAssertEqual(fileServer.credential, "cred-test-456")
        XCTAssertEqual(fileServer.certFP, fileServerFP)
    }

    func testOpenclawKindMapsToBuiltin() {
        guard let payload = assertParses(pairingString(minimalDict(kind: "openclaw"))) else { return }
        XCTAssertEqual(payload.kind, .builtin(.openclaw))
    }

    func testHermesKindMapsToBuiltin() {
        guard let payload = assertParses(pairingString(minimalDict(kind: "hermes"))) else { return }
        XCTAssertEqual(payload.kind, .builtin(.hermes))
    }

    func testCustomKindCarriesName() {
        var dict = minimalDict(kind: "custom")
        var gateway = dict["gateway"] as! [String: Any]
        gateway["name"] = "My Box"
        dict["gateway"] = gateway

        guard let payload = assertParses(pairingString(dict)) else { return }
        XCTAssertEqual(payload.kind, .custom(name: "My Box"))
    }

    func testCustomKindWithoutNameIsMalformed() {
        // Missing name entirely.
        assertFails(pairingString(minimalDict(kind: "custom")), with: .malformed,
                    "custom kind REQUIRES a nonempty name")

        // Name present but whitespace-only.
        var dict = minimalDict(kind: "custom")
        var gateway = dict["gateway"] as! [String: Any]
        gateway["name"] = "   "
        dict["gateway"] = gateway
        assertFails(pairingString(dict), with: .malformed,
                    "whitespace-only custom name must reject, not import an unnamed gateway")
    }

    func testUnknownKindIsMalformed() {
        assertFails(pairingString(minimalDict(kind: "skynet")), with: .malformed)
    }

    func testNonPairableBuiltinKindIsMalformed() {
        // "openrouter" is a real backend raw value, but pairing v1 permits only
        // openclaw / hermes / custom — the hosted-model lane is not QR-configurable.
        assertFails(pairingString(minimalDict(kind: "openrouter")), with: .malformed,
                    "a non-pairable builtin kind must reject, not configure the hosted lane")
    }

    // MARK: - Auth scheme & token

    func testKeylessGatewayParsesWithNilToken() {
        var dict = minimalDict()
        dict["gateway"] = [
            "kind": "openclaw",
            "url": "https://gw.example.com",
            "auth": "none",
        ]
        guard let payload = assertParses(pairingString(dict)) else { return }
        XCTAssertEqual(payload.authScheme, RemoteAgentAuthScheme.none)
        XCTAssertNil(payload.token)
    }

    func testKeylessGatewayDropsStrayToken() {
        // A stray token under explicit `.none` is DROPPED — keyless stays
        // an intentional token-free state, never a half-authenticated one.
        var dict = minimalDict()
        dict["gateway"] = [
            "kind": "openclaw",
            "url": "https://gw.example.com",
            "auth": "none",
            "token": "stray-token",
        ]
        guard let payload = assertParses(pairingString(dict)) else { return }
        XCTAssertEqual(payload.authScheme, RemoteAgentAuthScheme.none)
        XCTAssertNil(payload.token, "Stray token under auth=none must be dropped, not imported")
    }

    func testBearerWithMissingOrEmptyTokenIsMalformed() {
        var dict = minimalDict()
        dict["gateway"] = [
            "kind": "openclaw",
            "url": "https://gw.example.com",
            "auth": "bearer",
        ]
        assertFails(pairingString(dict), with: .malformed, "bearer REQUIRES a token")

        dict["gateway"] = [
            "kind": "openclaw",
            "url": "https://gw.example.com",
            "auth": "bearer",
            "token": "",
        ]
        assertFails(pairingString(dict), with: .malformed,
                    "empty-string token must reject — no empty-string sentinel auth")
    }

    func testAbsentAuthDefaultsToBearer() {
        // Fail-closed convention: no "auth" key → .bearer, so the token is
        // still required.
        var dict = minimalDict()
        dict["gateway"] = [
            "kind": "openclaw",
            "url": "https://gw.example.com",
            "token": "tok-test-123",
        ]
        guard let payload = assertParses(pairingString(dict)) else { return }
        XCTAssertEqual(payload.authScheme, .bearer)
        XCTAssertEqual(payload.token, "tok-test-123")

        // Absent auth + absent token → not configured → malformed.
        dict["gateway"] = [
            "kind": "openclaw",
            "url": "https://gw.example.com",
        ]
        assertFails(pairingString(dict), with: .malformed,
                    "absent auth defaults bearer, which requires a token")
    }

    // MARK: - File server

    func testNoFileServerYieldsNil() {
        guard let payload = assertParses(pairingString(minimalDict())) else { return }
        XCTAssertNil(payload.fileServer)
    }

    func testFileServerWithURLAndCredentialParses() {
        var dict = minimalDict()
        dict["fileServer"] = [
            "url": "https://files.example.com:8443",
            "credential": "cred-test-456",
        ]
        guard let payload = assertParses(pairingString(dict)) else { return }
        XCTAssertEqual(payload.fileServer?.url, URL(string: "https://files.example.com:8443"))
        XCTAssertEqual(payload.fileServer?.credential, "cred-test-456")
        XCTAssertNil(payload.fileServer?.certFP, "Absent fileServer.certFP must decode nil")
    }

    func testFileServerForwardCompatCertFPParses() {
        var dict = minimalDict()
        dict["fileServer"] = [
            "url": "https://files.example.com",
            "credential": "cred-test-456",
            "certFP": fileServerFP,
        ]
        guard let payload = assertParses(pairingString(dict)) else { return }
        XCTAssertEqual(payload.fileServer?.certFP, fileServerFP)
    }

    func testFileServerEmptyCredentialIsMalformed() {
        var dict = minimalDict()
        dict["fileServer"] = [
            "url": "https://files.example.com",
            "credential": "",
        ]
        assertFails(pairingString(dict), with: .malformed,
                    "fileServer block requires a nonempty credential")
    }

    // MARK: - Forward compat (unknown keys / transport)

    func testUnknownKeysAreIgnored() {
        var dict = fullDict()
        dict["futureTopLevel"] = ["nested": true]
        var gateway = dict["gateway"] as! [String: Any]
        gateway["futureGatewayHint"] = 42
        dict["gateway"] = gateway
        var fileServer = dict["fileServer"] as! [String: Any]
        fileServer["futureQuota"] = 1024
        dict["fileServer"] = fileServer

        guard let payload = assertParses(pairingString(dict)) else { return }
        XCTAssertEqual(payload.kind, .custom(name: "Home Lab"),
                       "Unknown keys must not disturb the known fields")
    }

    func testUnknownTransportYieldsNilButStillParses() {
        var dict = minimalDict()
        dict["transport"] = "quantum-tunnel"
        guard let payload = assertParses(pairingString(dict)) else { return }
        XCTAssertNil(payload.transport, "Unknown transport is a hint, never an error")
    }

    func testKnownTransportValuesMap() {
        let expectations: [(String, PairingPayload.Transport)] = [
            ("tailscale", .tailscale),
            ("funnel", .funnel),
            ("cloudflare", .cloudflare),
            ("public", .publicCert),
            ("selfsigned", .selfsigned),
        ]
        for (raw, expected) in expectations {
            var dict = minimalDict()
            dict["transport"] = raw
            guard let payload = assertParses(pairingString(dict)) else { continue }
            XCTAssertEqual(payload.transport, expected,
                           "transport \"\(raw)\" must map to .\(expected)")
        }
    }

    // MARK: - Versioning

    func testJSONVersionTwoIsUnsupported() {
        var dict = minimalDict()
        dict["v"] = 2
        assertFails(pairingString(dict), with: .unsupportedVersion,
                    "JSON v:2 means a newer conduck-connect — tell the user to update")
    }

    func testSegmentVersionTwoIsUnsupported() {
        assertFails(pairingString(minimalDict(), version: "v2"), with: .unsupportedVersion)
    }

    func testMissingJSONVersionIsMalformed() {
        var dict = minimalDict()
        dict.removeValue(forKey: "v")
        assertFails(pairingString(dict), with: .malformed,
                    "the wizard always writes \"v\"; its absence is corruption, not a version skew")
    }

    // MARK: - Prefix / base64 / JSON shape

    func testNonPairingInputIsNotAPairingCode() {
        assertFails("https://example.com/some-random-qr", with: .notAPairingCode)
        assertFails("random garbage !!!", with: .notAPairingCode)
        assertFails("", with: .notAPairingCode)
    }

    func testBadBase64IsMalformed() {
        assertFails("conduck-setup:v1:!!!not-base64!!!", with: .malformed)
    }

    func testBase64OfNonJSONIsMalformed() {
        let base64 = Data("not json at all".utf8).base64EncodedString()
        assertFails("conduck-setup:v1:\(base64)", with: .malformed)
    }

    // MARK: - https enforcement

    func testHTTPGatewayURLIsInsecure() {
        var dict = minimalDict()
        dict["gateway"] = [
            "kind": "openclaw",
            "url": "http://gw.example.com",
            "auth": "bearer",
            "token": "tok-test-123",
        ]
        assertFails(pairingString(dict), with: .insecureURL,
                    "http gateway must surface .insecureURL, not generic .malformed")
    }

    func testHTTPFileServerURLIsInsecure() {
        var dict = minimalDict()
        dict["fileServer"] = [
            "url": "http://files.example.com",
            "credential": "cred-test-456",
        ]
        assertFails(pairingString(dict), with: .insecureURL)
    }

    // MARK: - URL userinfo (BOTH URLs reject — one policy, no exceptions)

    /// A hand-crafted code (the parser's input is attacker-supplyable — a QR in
    /// the wild, a pasted string) must not be able to smuggle `user:password@`
    /// into the file-server URL: `executePairingImport` writes that URL verbatim
    /// into App-Group UserDefaults AND iCloud KVS, which is Apple-key
    /// server-side-encrypted, not the developer-blind Keychain path secrets ride.
    /// Rejecting at PARSE time is what keeps it out of both stores — nothing
    /// downstream of a `.failure` ever runs.
    func testFileServerURLWithUserinfoIsMalformed() {
        var dict = minimalDict()
        dict["fileServer"] = [
            "url": "https://u:p@files.example.com",
            "credential": "cred-test-456",
        ]
        assertFails(pairingString(dict), with: .malformed,
                    "user:password@ in the file-server URL must reject the code")
    }

    func testFileServerURLWithUserOnlyIsMalformed() {
        var dict = minimalDict()
        dict["fileServer"] = [
            "url": "https://admin@files.example.com",
            "credential": "cred-test-456",
        ]
        assertFails(pairingString(dict), with: .malformed,
                    "a bare username is still userinfo — no password needed to reject")
    }

    /// The rejection is the WHOLE payload, not a silent drop of the file lane.
    /// A lane-drop would hand the sheet a `.success` whose `fileServer` is nil:
    /// the gateway would import, file transfer would be silently absent, and the
    /// user would get no reason for either.
    func testFileServerUserinfoRejectsPayloadRatherThanDroppingTheLane() {
        var dict = minimalDict()
        dict["fileServer"] = [
            "url": "https://u:p@files.example.com",
            "credential": "cred-test-456",
        ]
        switch PairingPayload.parse(pairingString(dict)) {
        case .success(let payload):
            XCTFail("Userinfo file-server URL parsed; fileServer block "
                    + (payload.fileServer == nil ? "silently dropped" : "kept verbatim"))
        case .failure(let error):
            XCTAssertEqual(error, .malformed)
        }
    }

    /// NO asymmetry: the GATEWAY URL is held to the same `EndpointURLPolicy` as
    /// the file-server URL. A pairing string is untrusted input (anyone can
    /// hand-craft one), the gateway URL dual-writes verbatim into App-Group
    /// UserDefaults AND iCloud KVS, and it rides back out of any setup code this
    /// device later exports — so a `user:password@` gateway URL would park a
    /// plaintext password in the one store the privacy invariant says never
    /// holds one, and would make the apparent host differ from the real one on
    /// every surface that displays it.
    ///
    /// This deliberately removes URL-userinfo as a way to reach a gateway behind
    /// an HTTP-Basic reverse proxy. That capability was never specified, has no
    /// UI, and only ever worked for a keyless upstream (CFNetwork's 401 retry
    /// REPLACES the app's `Authorization: Bearer`). Supporting it properly means
    /// a first-class `.basic` auth scheme with the password in the Keychain.
    ///
    /// The app rejects on its OWN terms — it does not depend on `conduck-connect`
    /// having been aligned first. The wizard's interactive URL prompt still
    /// accepts userinfo today, so this case is reachable from a real wizard run,
    /// not only from a hand-crafted string.
    func testGatewayURLWithUserinfoIsMalformed() {
        var dict = minimalDict()
        dict["gateway"] = [
            "kind": "openclaw",
            "url": "https://proxyuser:proxypass@gw.example.com",
            "auth": "bearer",
            "token": "tok-test-123",
        ]
        assertFails(pairingString(dict), with: .malformed,
                    "user:password@ in the gateway URL must reject the code")
    }

    func testGatewayURLWithUserOnlyIsMalformed() {
        var dict = minimalDict()
        dict["gateway"] = [
            "kind": "openclaw",
            "url": "https://admin@gw.example.com",
            "auth": "bearer",
            "token": "tok-test-123",
        ]
        assertFails(pairingString(dict), with: .malformed,
                    "a bare username is still userinfo — no password needed to reject")
    }

    /// The host-confusion shape specifically: this connects to `evil.com` while
    /// reading as `gw.trusted.example` in a truncated single-line field.
    func testGatewayURLWhoseUserinfoImpersonatesAHostIsMalformed() {
        var dict = minimalDict()
        dict["gateway"] = [
            "kind": "openclaw",
            "url": "https://gw.trusted.example@evil.example.com",
            "auth": "bearer",
            "token": "tok-test-123",
        ]
        assertFails(pairingString(dict), with: .malformed,
                    "a userinfo segment shaped like a hostname is the whole point of the rule")
    }

    /// An `@` in the PATH is not userinfo — the policy parses, it does not scan
    /// for a literal character, so an ordinary address must still import.
    func testGatewayURLWithAtSignInPathStillParses() {
        var dict = minimalDict()
        dict["gateway"] = [
            "kind": "openclaw",
            "url": "https://gw.example.com/agents/a@b",
            "auth": "bearer",
            "token": "tok-test-123",
        ]
        guard let payload = assertParses(pairingString(dict)) else { return }
        XCTAssertEqual(payload.url.absoluteString, "https://gw.example.com/agents/a@b")
    }

    // MARK: - URL host (both URLs)
    //
    // `URL(string: "https://")` and `URL(string: "https:///v1")` both PARSE and
    // both carry a nil `URL.host`. Persisting one leaves a gateway that reports
    // itself configured and fails every request at the TLS layer, so the policy
    // requires a non-empty host. (Note `URLComponents.host` is `Optional("")`
    // for these — a `!= nil` test would let them through.)

    func testGatewayURLWithNoHostIsMalformed() {
        var dict = minimalDict()
        dict["gateway"] = [
            "kind": "openclaw",
            "url": "https:///v1",
            "auth": "bearer",
            "token": "tok-test-123",
        ]
        assertFails(pairingString(dict), with: .malformed,
                    "a hostless URL parses but can never be requested")
    }

    func testFileServerURLWithNoHostIsMalformed() {
        var dict = minimalDict()
        dict["fileServer"] = [
            "url": "https://",
            "credential": "cred-test-456",
        ]
        assertFails(pairingString(dict), with: .malformed,
                    "the file-server URL is held to the same host requirement")
    }

    // MARK: - certFP normalization

    func testCertFPWithColonsAndUppercaseNormalizes() {
        // openssl-style "AB:AB:…:AB" (32 uppercase pairs, colon-separated)
        // must normalize to bare lowercase 64-hex.
        let colonSeparated = Array(repeating: "AB", count: 32).joined(separator: ":")
        var dict = minimalDict()
        var gateway = dict["gateway"] as! [String: Any]
        gateway["certFP"] = colonSeparated
        dict["gateway"] = gateway

        guard let payload = assertParses(pairingString(dict)) else { return }
        XCTAssertEqual(payload.certFP, String(repeating: "ab", count: 32))
    }

    func testCertFPWrongLengthOrNonHexIsMalformed() {
        var dict = minimalDict()
        var gateway = dict["gateway"] as! [String: Any]

        gateway["certFP"] = String(repeating: "ab", count: 16) // 32 chars
        dict["gateway"] = gateway
        assertFails(pairingString(dict), with: .malformed, "32-hex certFP is wrong length")

        gateway["certFP"] = String(repeating: "zz", count: 32) // 64 chars, non-hex
        dict["gateway"] = gateway
        assertFails(pairingString(dict), with: .malformed, "non-hex certFP must reject")
    }

    // MARK: - Input tolerance

    func testSurroundingWhitespaceAndNewlinesTolerated() {
        let raw = "  \n\t" + pairingString(minimalDict()) + "\n  "
        guard let payload = assertParses(raw) else { return }
        XCTAssertEqual(payload.kind, .builtin(.openclaw))
    }

    func testPaddingStrippedBase64Tolerated() {
        // Force a payload whose base64 carries "=" padding (grow an
        // ignored junk key until it does), then strip the padding and
        // confirm the parser re-pads.
        var dict = minimalDict()
        var pad = ""
        var full = pairingString(dict)
        while !full.hasSuffix("=") {
            pad += "x"
            dict["_junk"] = pad
            full = pairingString(dict)
        }
        let stripped = full.replacingOccurrences(of: "=", with: "")
        XCTAssertNotEqual(stripped, full, "Fixture must actually have had padding")

        guard let payload = assertParses(stripped) else { return }
        XCTAssertEqual(payload.kind, .builtin(.openclaw))
    }
}
