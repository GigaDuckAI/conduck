// Conduck
// PairingPayloadExportTests.swift
//
// Locks `PairingPayloadExport.serialize` to the `conduck-connect` wizard's
// python emission (`spec.md` "Pairing payload v1"). The three GOLDEN VECTORS
// are byte-for-byte fixtures produced by the shell emitter for known inputs —
// any drift (key order, escaping, base64) fails here. Plus: the python-style
// string escaper's unit cases, structural omission rules, the OpenRouter export
// guard, and a full export→parse round-trip proving the emitter and
// `PairingPayload.parse` stay byte-compatible.
//
// Pure logic — no signing / Keychain (the serializer + escaper are static; the
// OpenRouter guard trips before any actor read). Synthetic tokens only.

import XCTest
@testable import Conduck

final class PairingPayloadExportTests: XCTestCase {

    // MARK: - Fixtures

    /// 64 lowercase hex — a syntactically valid SPKI SHA-256.
    private let gatewayFP = String(repeating: "ab", count: 32)
    private let fileServerFP = String(repeating: "cd", count: 32)

    /// V1 — minimal openclaw, bearer, tailscale transport, file lane, no pins.
    private func vector1() -> PairingPayloadExport.Payload {
        PairingPayloadExport.Payload(
            gateway: PairingPayloadExport.Gateway(
                kind: .builtin(.openclaw),
                url: "https://gw.tail1234.ts.net:8443",
                authScheme: .bearer,
                token: "tok_ABC123",
                model: nil,
                certFP: nil
            ),
            transport: "tailscale",
            fileServer: PairingPayloadExport.FileServer(
                url: "https://gw.tail1234.ts.net:9443",
                credential: "a1b2c3d4e5f60718",
                certFP: nil
            )
        )
    }

    private let vector1Expected = "conduck-setup:v1:eyJ2IjoxLCJnYXRld2F5Ijp7ImtpbmQiOiJvcGVuY2xhdyIsInVybCI6Imh0dHBzOi8vZ3cudGFpbDEyMzQudHMubmV0Ojg0NDMiLCJhdXRoIjoiYmVhcmVyIiwidG9rZW4iOiJ0b2tfQUJDMTIzIn0sInRyYW5zcG9ydCI6InRhaWxzY2FsZSIsImZpbGVTZXJ2ZXIiOnsidXJsIjoiaHR0cHM6Ly9ndy50YWlsMTIzNC50cy5uZXQ6OTQ0MyIsImNyZWRlbnRpYWwiOiJhMWIyYzNkNGU1ZjYwNzE4In19"

    /// V2 — maximal custom: unicode name, "/"+"="+"+" in the token, model, BOTH
    /// cert pins, selfsigned transport. Exercises escaping + every optional key.
    private func vector2() -> PairingPayloadExport.Payload {
        PairingPayloadExport.Payload(
            gateway: PairingPayloadExport.Gateway(
                // "My Böx — lab": ö = U+00F6, em dash = U+2014 (spelled out so the
                // fixture can't drift to an en dash / precomposed variant).
                kind: .custom(name: "My B\u{00F6}x \u{2014} lab"),
                url: "https://ai.example.com",
                authScheme: .bearer,
                token: "sk-test/77+q==",
                model: "llama-3.3-70b",
                certFP: gatewayFP
            ),
            transport: "selfsigned",
            fileServer: PairingPayloadExport.FileServer(
                url: "https://ai.example.com:8444",
                credential: "deadbeefcafe0123",
                certFP: fileServerFP
            )
        )
    }

    private let vector2Expected = "conduck-setup:v1:eyJ2IjoxLCJnYXRld2F5Ijp7ImtpbmQiOiJjdXN0b20iLCJ1cmwiOiJodHRwczovL2FpLmV4YW1wbGUuY29tIiwiYXV0aCI6ImJlYXJlciIsIm5hbWUiOiJNeSBCXHUwMGY2eCBcdTIwMTQgbGFiIiwidG9rZW4iOiJzay10ZXN0Lzc3K3E9PSIsIm1vZGVsIjoibGxhbWEtMy4zLTcwYiIsImNlcnRGUCI6ImFiYWJhYmFiYWJhYmFiYWJhYmFiYWJhYmFiYWJhYmFiYWJhYmFiYWJhYmFiYWJhYmFiYWJhYmFiYWJhYmFiYWIifSwidHJhbnNwb3J0Ijoic2VsZnNpZ25lZCIsImZpbGVTZXJ2ZXIiOnsidXJsIjoiaHR0cHM6Ly9haS5leGFtcGxlLmNvbTo4NDQ0IiwiY3JlZGVudGlhbCI6ImRlYWRiZWVmY2FmZTAxMjMiLCJjZXJ0RlAiOiJjZGNkY2RjZGNkY2RjZGNkY2RjZGNkY2RjZGNkY2RjZGNkY2RjZGNkY2RjZGNkY2RjZGNkY2RjZGNkY2RjZGNkIn19"

    /// V3 — keyless custom, no lane, no model. No token key; no fileServer key.
    private func vector3() -> PairingPayloadExport.Payload {
        PairingPayloadExport.Payload(
            gateway: PairingPayloadExport.Gateway(
                kind: .custom(name: "Ollama box"),
                url: "https://ollama.lan.example.com",
                authScheme: .none,
                token: nil,
                model: nil,
                certFP: nil
            ),
            transport: "public",
            fileServer: nil
        )
    }

    private let vector3Expected = "conduck-setup:v1:eyJ2IjoxLCJnYXRld2F5Ijp7ImtpbmQiOiJjdXN0b20iLCJ1cmwiOiJodHRwczovL29sbGFtYS5sYW4uZXhhbXBsZS5jb20iLCJhdXRoIjoibm9uZSIsIm5hbWUiOiJPbGxhbWEgYm94In0sInRyYW5zcG9ydCI6InB1YmxpYyJ9"

    /// Strip the prefix, base64-decode, and return the raw minified JSON for
    /// structural inspection.
    private func decodedJSON(_ setupCode: String) -> String {
        XCTAssertTrue(setupCode.hasPrefix(PairingPayloadExport.stringPrefix))
        let base64 = String(setupCode.dropFirst(PairingPayloadExport.stringPrefix.count))
        guard let data = Data(base64Encoded: base64),
              let json = String(data: data, encoding: .utf8) else {
            XCTFail("base64/utf8 decode failed")
            return ""
        }
        return json
    }

    // MARK: - Golden vectors (byte-exact)

    func testVector1ByteExact() {
        XCTAssertEqual(PairingPayloadExport.serialize(vector1()), vector1Expected)
    }

    func testVector2ByteExact() {
        XCTAssertEqual(PairingPayloadExport.serialize(vector2()), vector2Expected)
    }

    func testVector3ByteExact() {
        XCTAssertEqual(PairingPayloadExport.serialize(vector3()), vector3Expected)
    }

    // MARK: - python-style string escaping

    func testEscaping_slashNotEscaped() {
        XCTAssertEqual(PairingPayloadExport.pythonJSONString("a/b"), "\"a/b\"")
        // The V2 token carries "/", "+", "=" — none are JSON-special, all verbatim.
        XCTAssertEqual(PairingPayloadExport.pythonJSONString("sk-test/77+q=="), "\"sk-test/77+q==\"")
    }

    func testEscaping_nonASCII() {
        XCTAssertEqual(PairingPayloadExport.pythonJSONString("\u{00F6}"), "\"\\u00f6\"")   // ö
        XCTAssertEqual(PairingPayloadExport.pythonJSONString("\u{2014}"), "\"\\u2014\"")   // em dash
        XCTAssertEqual(PairingPayloadExport.pythonJSONString("My B\u{00F6}x \u{2014} lab"),
                       "\"My B\\u00f6x \\u2014 lab\"")
    }

    func testEscaping_astralSurrogatePair() {
        // U+1F600 😀 → UTF-16 surrogate pair d83d/de00, each \u-escaped lowercase.
        XCTAssertEqual(PairingPayloadExport.pythonJSONString("\u{1F600}"), "\"\\ud83d\\ude00\"")
    }

    func testEscaping_quotesBackslashControls() {
        XCTAssertEqual(PairingPayloadExport.pythonJSONString("a\"b\\c"), "\"a\\\"b\\\\c\"")
        XCTAssertEqual(PairingPayloadExport.pythonJSONString("a\nb"), "\"a\\nb\"")
        XCTAssertEqual(PairingPayloadExport.pythonJSONString("a\tb"), "\"a\\tb\"")
        XCTAssertEqual(PairingPayloadExport.pythonJSONString("a\rb"), "\"a\\rb\"")
    }

    func testEscaping_delAndLowControl() {
        XCTAssertEqual(PairingPayloadExport.pythonJSONString("\u{7F}"), "\"\\u007f\"")   // DEL (>0x7E)
        XCTAssertEqual(PairingPayloadExport.pythonJSONString("\u{01}"), "\"\\u0001\"")   // SOH (<0x20)
    }

    // MARK: - Structural omission rules

    func testFileServerOmittedWhenLaneAbsent() {
        let json = decodedJSON(PairingPayloadExport.serialize(vector3()))
        XCTAssertFalse(json.contains("fileServer"))
        // ...and present when the lane exists.
        XCTAssertTrue(decodedJSON(PairingPayloadExport.serialize(vector1())).contains("\"fileServer\""))
    }

    func testKeylessOmitsTokenKey() {
        let json = decodedJSON(PairingPayloadExport.serialize(vector3()))
        XCTAssertFalse(json.contains("\"token\""))
        XCTAssertTrue(json.contains("\"auth\":\"none\""))
        // Bearer keeps the token key.
        XCTAssertTrue(decodedJSON(PairingPayloadExport.serialize(vector1())).contains("\"token\":\"tok_ABC123\""))
    }

    func testNameKeyCustomOnly() {
        // Custom carries a name; a built-in never does.
        XCTAssertTrue(decodedJSON(PairingPayloadExport.serialize(vector3())).contains("\"name\":\"Ollama box\""))
        XCTAssertFalse(decodedJSON(PairingPayloadExport.serialize(vector1())).contains("\"name\""))
    }

    func testModelOmittedWhenNilOrEmpty() {
        XCTAssertFalse(decodedJSON(PairingPayloadExport.serialize(vector1())).contains("\"model\""))
        XCTAssertTrue(decodedJSON(PairingPayloadExport.serialize(vector2())).contains("\"model\":\"llama-3.3-70b\""))
    }

    // MARK: - fileServer emitted only when url AND credential both non-empty

    // The serializer must honor the wizard's `if FS_URL and FS_CRED` truthiness
    // for EVERY representable input, not just the ones `makePayload` builds: a
    // non-nil FileServer with an empty url (or empty credential) omits the whole
    // block, byte-identically to `fileServer == nil`. Base payload = vector1's
    // gateway/transport with the lane swapped, so "block absent" is pinned
    // against the same reference bytes the golden vectors assert.

    func testFileServerEmptyURLOmitsBlock() {
        let base = vector1()
        let nilLane = PairingPayloadExport.serialize(
            PairingPayloadExport.Payload(
                gateway: base.gateway,
                transport: base.transport,
                fileServer: nil
            )
        )
        let emptyURL = PairingPayloadExport.serialize(
            PairingPayloadExport.Payload(
                gateway: base.gateway,
                transport: base.transport,
                fileServer: PairingPayloadExport.FileServer(
                    url: "",
                    credential: "a1b2c3d4e5f60718",
                    certFP: nil
                )
            )
        )
        XCTAssertEqual(emptyURL, nilLane)
        XCTAssertFalse(decodedJSON(emptyURL).contains("fileServer"))
    }

    func testFileServerEmptyCredentialOmitsBlock() {
        let base = vector1()
        let nilLane = PairingPayloadExport.serialize(
            PairingPayloadExport.Payload(
                gateway: base.gateway,
                transport: base.transport,
                fileServer: nil
            )
        )
        let emptyCred = PairingPayloadExport.serialize(
            PairingPayloadExport.Payload(
                gateway: base.gateway,
                transport: base.transport,
                fileServer: PairingPayloadExport.FileServer(
                    url: "https://gw.tail1234.ts.net:9443",
                    credential: "",
                    certFP: nil
                )
            )
        )
        XCTAssertEqual(emptyCred, nilLane)
        XCTAssertFalse(decodedJSON(emptyCred).contains("fileServer"))
    }

    // MARK: - Export → parse round-trip (byte-compatibility with the parser)

    func testRoundTripVector1() {
        assertRoundTrips(vector1(), expected: PairingPayload(
            kind: .builtin(.openclaw),
            url: URL(string: "https://gw.tail1234.ts.net:8443")!,
            authScheme: .bearer,
            token: "tok_ABC123",
            certFP: nil,
            model: nil,
            fileServer: PairingPayload.FileServer(
                url: URL(string: "https://gw.tail1234.ts.net:9443")!,
                credential: "a1b2c3d4e5f60718",
                certFP: nil
            ),
            transport: .tailscale
        ))
    }

    func testRoundTripVector2() {
        assertRoundTrips(vector2(), expected: PairingPayload(
            kind: .custom(name: "My B\u{00F6}x \u{2014} lab"),
            url: URL(string: "https://ai.example.com")!,
            authScheme: .bearer,
            token: "sk-test/77+q==",
            certFP: gatewayFP,
            model: "llama-3.3-70b",
            fileServer: PairingPayload.FileServer(
                url: URL(string: "https://ai.example.com:8444")!,
                credential: "deadbeefcafe0123",
                certFP: fileServerFP
            ),
            transport: .selfsigned
        ))
    }

    func testRoundTripVector3() {
        assertRoundTrips(vector3(), expected: PairingPayload(
            kind: .custom(name: "Ollama box"),
            url: URL(string: "https://ollama.lan.example.com")!,
            authScheme: .none,
            token: nil,
            certFP: nil,
            model: nil,
            fileServer: nil,
            transport: .publicCert
        ))
    }

    private func assertRoundTrips(
        _ payload: PairingPayloadExport.Payload,
        expected: PairingPayload,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let code = PairingPayloadExport.serialize(payload)
        switch PairingPayload.parse(code) {
        case .success(let parsed):
            XCTAssertEqual(parsed, expected, file: file, line: line)
        case .failure(let error):
            XCTFail("exported code failed to re-parse: \(error)", file: file, line: line)
        }
    }

    // MARK: - OpenRouter export guard

    func testOpenRouterExportRefused() async {
        do {
            _ = try await PairingPayloadExport.makePayload(for: .builtin(.openrouter))
            XCTFail("OpenRouter must never be exportable")
        } catch let error as PairingPayloadExport.ExportError {
            XCTAssertEqual(error, .notExportable)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }
}
