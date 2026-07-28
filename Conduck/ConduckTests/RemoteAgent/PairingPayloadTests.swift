// SPDX-License-Identifier: Apache-2.0

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
//
// The payload carries NO certificate field, and the tests below lock that the
// parser has no path by which a code-supplied digest could become a value the
// app holds.

import XCTest
@testable import Conduck

final class PairingPayloadTests: XCTestCase {

    // MARK: - Fixtures & helpers

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
                "model": "test-model",
            ],
            "fileServer": [
                "url": "https://files.example.ts.net:8443",
                "credential": "cred-test-456",
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
        XCTAssertEqual(payload.model, "test-model")
        XCTAssertEqual(payload.transport, .tailscale)

        guard let fileServer = payload.fileServer else {
            XCTFail("fileServer block present in payload must decode non-nil")
            return
        }
        XCTAssertEqual(fileServer.url, URL(string: "https://files.example.ts.net:8443"))
        XCTAssertEqual(fileServer.credential, "cred-test-456")
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

    // MARK: - The payload names no certificate
    //
    // A pin can only ever be an ADDITIONAL restriction on a chain the system
    // already trusts, so a certificate field in an untrusted setup code could
    // only ask the app to lower its standards. There is no such field, and the
    // tolerant dict-decode means a hand-crafted code that adds one is not
    // rejected — it is IGNORED, which is the stronger property: the parser has
    // no path by which a code-supplied digest becomes a value the app holds.

    func testACertFPKeyInTheGatewayBlockIsIgnoredNotHonoured() {
        var dict = minimalDict()
        var gateway = dict["gateway"] as! [String: Any]
        gateway["certFP"] = String(repeating: "ab", count: 32)
        dict["gateway"] = gateway

        guard let payload = assertParses(pairingString(dict)) else { return }
        XCTAssertEqual(payload.kind, .builtin(.openclaw),
                       "The rest of the payload must parse normally around the ignored key.")
        XCTAssertEqual(payload.url, URL(string: "https://gw.example.com"))
    }

    func testACertFPKeyInTheFileServerBlockIsIgnoredNotHonoured() {
        var dict = minimalDict()
        dict["fileServer"] = [
            "url": "https://files.example.com",
            "credential": "cred-test-456",
            "certFP": String(repeating: "cd", count: 32),
        ]
        guard let payload = assertParses(pairingString(dict)) else { return }
        XCTAssertEqual(payload.fileServer?.url, URL(string: "https://files.example.com"))
        XCTAssertEqual(payload.fileServer?.credential, "cred-test-456")
    }

    /// `selfsigned` is not a transport this app can reach at all: App Transport
    /// Security refuses a private-CA or self-signed certificate on a remote host
    /// whatever the app's delegate returns. It must therefore read as an unknown
    /// hint — nil, no error — exactly like `"quantum-tunnel"` above.
    func testSelfsignedTransportIsUnknownAndDecodesToNil() {
        var dict = minimalDict()
        dict["transport"] = "selfsigned"
        guard let payload = assertParses(pairingString(dict)) else { return }
        XCTAssertNil(payload.transport,
                     "`selfsigned` names no supported exposure recipe — it must not map to a case.")
    }

    // MARK: - Display-string sanitization (name / model)
    //
    // `gateway.name` and `gateway.model` are the payload's only free-form text.
    // Both persist (roster name / model override) AND render — the name reaches
    // the import sheet's kindMismatch error verbatim, before the 40-char persist
    // truncation applies. A hand-crafted code must not be able to put control or
    // bidi scalars, or a kilobyte of text, on any of those surfaces. The parser
    // REJECTS rather than strips: a silently rewritten name would make the
    // imported gateway's identity differ from what the operator saw in their
    // terminal, which is the confusion the rule exists to prevent.

    /// Build a payload whose custom gateway carries `name`.
    private func dictWithName(_ name: String) -> [String: Any] {
        var dict = minimalDict(kind: "custom")
        var gateway = dict["gateway"] as! [String: Any]
        gateway["name"] = name
        dict["gateway"] = gateway
        return dict
    }

    /// Build a payload whose (built-in) gateway carries `model`.
    private func dictWithModel(_ model: String) -> [String: Any] {
        var dict = minimalDict()
        var gateway = dict["gateway"] as! [String: Any]
        gateway["model"] = model
        dict["gateway"] = gateway
        return dict
    }

    /// The scalars the sanitizer bars, each embedded MID-string so the
    /// whitespace trim can't be what rejects them.
    private let hostileScalars: [(String, String)] = [
        ("NUL (C0)", "\u{0000}"),
        ("LF (C0)", "\u{000A}"),
        ("ESC (C0)", "\u{001B}"),
        ("DEL", "\u{007F}"),
        ("NEL (C1)", "\u{0085}"),
        ("APC (C1)", "\u{009F}"),
        ("LRM (bidi)", "\u{200E}"),
        ("RLO (bidi override)", "\u{202E}"),
        ("LRI (bidi isolate)", "\u{2066}"),
        ("PDI (bidi isolate)", "\u{2069}"),
        ("LINE SEPARATOR", "\u{2028}"),
        ("PARAGRAPH SEPARATOR", "\u{2029}"),
    ]

    func testNameWithHostileScalarIsMalformed() {
        for (label, scalar) in hostileScalars {
            let name = "Home\(scalar)Lab"
            assertFails(pairingString(dictWithName(name)), with: .malformed,
                        "custom name carrying \(label) must reject the whole code")
        }
    }

    func testModelWithHostileScalarIsMalformed() {
        for (label, scalar) in hostileScalars {
            let model = "llama\(scalar)-3.3-70b"
            assertFails(pairingString(dictWithModel(model)), with: .malformed,
                        "model override carrying \(label) must reject the whole code")
        }
    }

    /// The spoof shape specifically: RLO reverses the run after it, so a name
    /// can render as a different gateway than the one being imported.
    func testNameWithBidiOverrideIsMalformed() {
        assertFails(pairingString(dictWithName("Home \u{202E}bal emoH")), with: .malformed,
                    "a right-to-left override is the display-spoof primitive")
    }

    /// A control scalar hides inside a single grapheme cluster — `"a\u{0000}"`
    /// is ONE Character — so this only rejects if the scan is scalar-level.
    func testNameWithControlScalarInsideGraphemeClusterIsMalformed() {
        let name = "Home\u{0301}\u{0000} Lab" // combining acute, then NUL
        XCTAssertLessThan(name.count, name.unicodeScalars.count,
                          "Fixture must actually collapse scalars into clusters")
        assertFails(pairingString(dictWithName(name)), with: .malformed,
                    "a control scalar hidden in a grapheme cluster must still reject")
    }

    func testNameAtCapParsesAndOverCapIsMalformed() {
        let atCap = String(repeating: "n", count: 120)
        guard let payload = assertParses(pairingString(dictWithName(atCap))) else { return }
        XCTAssertEqual(payload.kind, .custom(name: atCap),
                       "exactly-at-cap must import unchanged — the cap is a bound, not a truncation")

        assertFails(pairingString(dictWithName(atCap + "n")), with: .malformed,
                    "one scalar over the name cap must reject")
        assertFails(pairingString(dictWithName(String(repeating: "n", count: 5_000))),
                    with: .malformed, "an absurd name must never reach storage or a label")
    }

    func testModelAtCapParsesAndOverCapIsMalformed() {
        let atCap = String(repeating: "m", count: 200)
        guard let payload = assertParses(pairingString(dictWithModel(atCap))) else { return }
        XCTAssertEqual(payload.model, atCap)

        assertFails(pairingString(dictWithModel(atCap + "m")), with: .malformed,
                    "one scalar over the model cap must reject")
    }

    /// THE regression that matters most: the rule is a denylist of rendering
    /// controls, not an allowlist of scripts. Real gateway names are non-ASCII.
    func testLegitimateUnicodeNamesAndModelsStillParse() {
        let names = [
            "Küchen-Gateway",
            "日本語ゲートウェイ",
            "Домашний шлюз",
            "🦆 Duck Box",
            "My Böx — lab",
            "Ali's box (v2) #1 — 100% fine",
        ]
        for name in names {
            guard let payload = assertParses(pairingString(dictWithName(name))) else { continue }
            XCTAssertEqual(payload.kind, .custom(name: name),
                           "\"\(name)\" is an ordinary name and must import verbatim")
        }

        let models = [
            "hf.co/unsloth/Qwen2.5-Coder-32B-Instruct-GGUF:Q4_K_M",
            "meta-llama/Llama-3.3-70B-Instruct",
            "gpt-4.1-mini@2025-04-14",
            "モデル-1",
        ]
        for model in models {
            guard let payload = assertParses(pairingString(dictWithModel(model))) else { continue }
            XCTAssertEqual(payload.model, model,
                           "\"\(model)\" is a plausible machine-minted id and must survive whole")
        }
    }

    /// Sanitization runs AFTER the trim, so ordinary padding still imports
    /// clean rather than tripping the newline rule.
    func testNameAndModelStillTrimSurroundingWhitespace() {
        guard let named = assertParses(pairingString(dictWithName("  Home Lab \n"))) else { return }
        XCTAssertEqual(named.kind, .custom(name: "Home Lab"))

        guard let modeled = assertParses(pairingString(dictWithModel("\t llama-3.3-70b \r\n"))) else { return }
        XCTAssertEqual(modeled.model, "llama-3.3-70b")
    }

    /// A model that is whitespace-only still degrades to nil (optional hint),
    /// while a whitespace-only NAME still rejects (required field) — the
    /// sanitizer must not have changed either verdict.
    func testWhitespaceOnlyModelStillDegradesToNil() {
        guard let payload = assertParses(pairingString(dictWithModel("   \n  "))) else { return }
        XCTAssertNil(payload.model, "an empty-after-trim model is an absent hint, not an error")
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
