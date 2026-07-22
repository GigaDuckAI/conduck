// Conduck
// LockedNetworkAndPairingLiteralsTests.swift
//
// Locks NETWORK + PAIRING wire literals against HARDCODED expected strings —
// a rename / typo / accidental "/v1" creep in any of these regresses the
// gateway round-trip, the OpenRouter hosted-model lane, OpenRouter TTS, the
// `conduck-connect` pairing import, or the file-server basic-auth identity,
// and these assertions FAIL loudly rather than letting a silent wire change
// ship. Every expectation is a verbatim literal copied from source, NOT a
// `symbol == symbol` tautology (which can never catch a rename).
//
// Specifically:
//   - `Constants.openRouterBaseURLString` MUST end at `/api`, NEVER `/api/v1`
//     (the client appends `/v1/...` — a doubled `/v1/v1/...` 404s).
//   - The chat-completions URL composed from that base is
//     `.../api/v1/chat/completions` (reproduced via the exact `appending(path:)`
//     seam `RemoteAgentClient.buildRequest` uses; that builder is `private`
//     so the composition is reconstructed from the same Foundation API + the
//     same path literal, then the absoluteString is pinned).
//   - OpenRouter TTS speech URL resolves to `.../api/v1/audio/speech`.
//   - Pairing scheme prefix `"conduck-setup:"` + version `"v1"` are pinned as
//     INDEPENDENT hand-built literals (the parser's `prefix` constant is
//     private; the existing PairingPayloadTests reconstruct the string from a
//     helper, which can't catch a prefix/version rename in source).
//   - `Constants.fileServerUsername` == "conduck".

import XCTest
@testable import Conduck

final class LockedNetworkAndPairingLiteralsTests: XCTestCase {

    // MARK: - OpenRouter base URL — locked, must end at /api (no /v1)

    func testOpenRouterBaseURLStringIsExactLockedLiteral() {
        XCTAssertEqual(Constants.openRouterBaseURLString, "https://openrouter.ai/api",
                       "OpenRouter API root is LOCKED — the client appends /v1/... itself.")
    }

    func testOpenRouterBaseURLHasNoTrailingV1() {
        // The doubled-path trap: if the base ever gains a trailing "/v1",
        // every appended "/v1/..." path becomes "/v1/v1/..." and 404s.
        XCTAssertFalse(Constants.openRouterBaseURLString.hasSuffix("/v1"),
                       "Base must NOT carry a trailing /v1 — appending /v1/chat/completions would double it.")
        XCTAssertTrue(Constants.openRouterBaseURLString.hasSuffix("/api"),
                      "Base must end at /api so the appended /v1 lands exactly once.")
    }

    func testBackendMetadataFixedURLForOpenRouterEqualsBase() {
        // The .openrouter descriptor's fixed endpoint must be authoritative AND
        // equal to the locked base string (no drift between the two sources).
        let metadata = RemoteAgentBackendRegistry.lookup(id: .openrouter)
        XCTAssertEqual(metadata.fixedURL?.absoluteString, "https://openrouter.ai/api",
                       "OpenRouter's fixed endpoint must equal the locked base URL string.")
        XCTAssertTrue(metadata.hidesURLField,
                      "OpenRouter has a fixed endpoint → the editor hides the URL field.")
    }

    // MARK: - Chat-completions path composition (doubled-/v1 trap)

    func testChatCompletionsURLComposesWithoutDoubledV1() {
        // `RemoteAgentClient.buildRequest` is private; it builds the endpoint via
        // `url.appending(path: "v1/chat/completions")`. Reproduce that EXACT seam
        // (same Foundation API + same path literal) against the OpenRouter base
        // and pin the resulting absoluteString. This is what would 404 if the
        // base regrew a "/v1".
        let base = URL(string: Constants.openRouterBaseURLString)!
        let endpoint = base.appending(path: "v1/chat/completions")

        XCTAssertEqual(endpoint.absoluteString,
                       "https://openrouter.ai/api/v1/chat/completions",
                       "Composed chat URL must be .../api/v1/chat/completions — exactly one /v1.")
        XCTAssertFalse(endpoint.absoluteString.contains("/v1/v1/"),
                       "The doubled-path trap must never fire: no /v1/v1/ segment.")
    }

    func testModelsAndKeyProbePathsAreLockedLiterals() {
        // Test Connection verdict + model-discovery paths. Pinned independently
        // so a rename to either surfaces here, not in a silent probe failure.
        XCTAssertEqual(Constants.remoteAgentModelsProbePath, "/v1/models")
        XCTAssertEqual(Constants.openRouterKeyProbePath, "/v1/key")
    }

    // MARK: - OpenRouter TTS speech path / effectiveSpeechURL

    func testOpenRouterSpeechPathIsLockedLiteral() {
        XCTAssertEqual(Constants.openRouterSpeechPath, "/v1/audio/speech",
                       "OpenRouter TTS rides /v1/audio/speech on the shared /api base.")
    }

    func testOpenRouterTTSEffectiveSpeechURLResolvesToSharedBasePlusSpeechPath() {
        // openrouter-tts shares the OpenRouter /api base + appends the speech
        // path. `effectiveSpeechURL` returns the fixed speechURL for an
        // openAISpeech transport with no custom-model override.
        let provider = TTSProvider.lookup(id: "openrouter-tts")
        XCTAssertEqual(provider.id, "openrouter-tts",
                       "lookup must resolve the locked openrouter-tts id (else it fell back to apple-tts).")

        let url = provider.effectiveSpeechURL(voice: "Eve")
        XCTAssertEqual(url.absoluteString,
                       "https://openrouter.ai/api/v1/audio/speech",
                       "OpenRouter TTS endpoint must be .../api/v1/audio/speech.")
    }

    // MARK: - Pairing scheme prefix + version (independent literals)

    /// Build a valid pairing string by HAND from the locked scheme prefix +
    /// version literals — deliberately NOT routed through the parser's own
    /// `prefix`/version constants (those are private, and reusing them would be
    /// tautological). The base64 body is computed in-test from a content dict;
    /// `JSONSerialization` key order is irrelevant to the parser.
    private func makePairingString(version: String, jsonObject: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: jsonObject)
        return "conduck-setup:" + version + ":" + data.base64EncodedString()
    }

    private func validGatewayDict() -> [String: Any] {
        [
            "v": 1,
            "gateway": [
                "kind": "openclaw",
                "url": "https://gw.example.test:18789",
                "auth": "bearer",
                "token": "abc123",
            ],
        ]
    }

    func testPairingParseSucceedsOnHandBuiltV1String() {
        let string = makePairingString(version: "v1", jsonObject: validGatewayDict())
        switch PairingPayload.parse(string) {
        case .success(let payload):
            XCTAssertEqual(payload.kind, .builtin(.openclaw),
                           "openclaw kind must map to the builtin backend.")
            XCTAssertEqual(payload.url.absoluteString, "https://gw.example.test:18789")
            XCTAssertEqual(payload.authScheme, .bearer)
            XCTAssertEqual(payload.token, "abc123")
        case .failure(let error):
            XCTFail("A hand-built conduck-setup:v1:<valid> string must parse, got \(error).")
        }
    }

    func testWrongSchemePrefixIsNotAPairingCode() {
        // Wrong prefix — pin against the parser's contract, not its private const.
        let body = try! JSONSerialization.data(withJSONObject: validGatewayDict()).base64EncodedString()
        let wrongScheme = "duck-connect:v1:" + body
        switch PairingPayload.parse(wrongScheme) {
        case .success:
            XCTFail("A non-conduck-setup prefix must NOT parse as a pairing code.")
        case .failure(let error):
            XCTAssertEqual(error, .notAPairingCode,
                           "Wrong scheme prefix → .notAPairingCode (scanner ignores unrelated QR).")
        }
    }

    func testWrongSegmentVersionIsUnsupportedVersion() {
        // Segment version "v2" with the correct prefix → unsupportedVersion.
        let string = makePairingString(version: "v2", jsonObject: validGatewayDict())
        switch PairingPayload.parse(string) {
        case .success:
            XCTFail("Version v2 must NOT parse — only v1 is supported.")
        case .failure(let error):
            XCTAssertEqual(error, .unsupportedVersion,
                           "Segment version != v1 → .unsupportedVersion (tell user to update).")
        }
    }

    func testNonBase64BodyIsMalformed() {
        switch PairingPayload.parse("conduck-setup:v1:!!!not-base64!!!") {
        case .success:
            XCTFail("Non-base64 body must NOT parse.")
        case .failure(let error):
            XCTAssertEqual(error, .malformed, "Bad base64 body → .malformed.")
        }
    }

    func testTruncatedGarbageStringIsRejected() {
        // A bare prefix with no version/body segment: the body becomes the
        // version segment ("" after the prefix) which is != "v1".
        switch PairingPayload.parse("conduck-setup:") {
        case .success:
            XCTFail("A truncated 'conduck-setup:' with no version/body must not parse.")
        case .failure(let error):
            XCTAssertEqual(error, .unsupportedVersion,
                           "Empty version segment after the prefix is not v1 → .unsupportedVersion.")
        }
    }

    // MARK: - File-server basic-auth username — locked literal

    func testFileServerUsernameIsLockedLiteral() {
        XCTAssertEqual(Constants.fileServerUsername, "conduck",
                       "File-server basic-auth username is a fixed non-secret constant the snippet + client agree on.")
    }
}
