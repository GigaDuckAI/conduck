// SPDX-License-Identifier: Apache-2.0

// Conduck
// STTProviderTests.swift
//
// Multi-provider STT expansion. Deterministic unit tests
// over the provider registry + auth scheme + multipart builder field-name
// selection + response decoder + status-map differentiator. No URLSession,
// no Keychain — every test is pure-data.

import XCTest
@testable import Conduck

final class STTProviderTests: XCTestCase {

    // MARK: - Registry lookup

    func testRegistryLookupReturnsMistralForUnknownID() {
        let p = STTProvider.lookup(id: "garbage-no-such-provider")
        XCTAssertEqual(p.id, STTProvider.mistralVoxtral.id)
    }

    func testRegistryLookupReturnsCorrectProviderPerID() {
        XCTAssertEqual(STTProvider.lookup(id: "mistral-voxtral").id, "mistral-voxtral")
        XCTAssertEqual(STTProvider.lookup(id: "openai-gpt4o-transcribe").id, "openai-gpt4o-transcribe")
        XCTAssertEqual(STTProvider.lookup(id: "elevenlabs-scribe-v2").id, "elevenlabs-scribe-v2")
        XCTAssertEqual(STTProvider.lookup(id: "gemini-3-1-flash-lite").id, "gemini-3-1-flash-lite")
        // Qwen is UNLISTED — `lookup` searches `allRegistered`, so a
        // `qwen3-asr-flash` id now falls back to the Mistral default (the
        // `static let qwenASRFlash` definition is kept but not registered).
        XCTAssertEqual(STTProvider.lookup(id: "qwen3-asr-flash").id, STTProvider.mistralVoxtral.id)
    }

    // MARK: - Auth scheme per provider

    func testMistralAuthIsBearer() {
        XCTAssertEqual(STTProvider.mistralVoxtral.auth, .bearer)
    }

    func testElevenLabsAuthIsCustomHeader() {
        XCTAssertEqual(STTProvider.elevenLabsScribe.auth, .headerName("xi-api-key"))
    }

    func testGeminiAuthIsCustomHeader() {
        XCTAssertEqual(STTProvider.geminiFlashLite.auth, .headerName("x-goog-api-key"))
    }

    // MARK: - Auth scheme apply

    func testAuthSchemeAppliesBearerHeader() {
        var req = URLRequest(url: URL(string: "https://example.com")!)
        STTAuthScheme.bearer.apply(to: &req, apiKey: "sk-XYZ")

        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer sk-XYZ")
        XCTAssertNil(req.value(forHTTPHeaderField: "xi-api-key"))
        XCTAssertNil(req.value(forHTTPHeaderField: "x-goog-api-key"))
    }

    func testAuthSchemeAppliesCustomHeader() {
        var req = URLRequest(url: URL(string: "https://example.com")!)
        STTAuthScheme.headerName("xi-api-key").apply(to: &req, apiKey: "elv-ABC123")

        XCTAssertEqual(req.value(forHTTPHeaderField: "xi-api-key"), "elv-ABC123")
        XCTAssertNil(req.value(forHTTPHeaderField: "Authorization"))
    }

    // MARK: - Multipart field-name selection

    func testMultipartBuilderUsesOpenAICompatFieldNames() {
        let (_, body) = STTMultipartBuilder.build(
            audioData: Data([0x00, 0x01, 0x02]),
            audioMIME: "audio/mp4",
            audioFilename: "audio.m4a",
            model: "voxtral-mini-2602",
            language: "en",
            fieldNames: .openAICompat
        )

        let text = String(data: body, encoding: .utf8) ?? ""
        XCTAssertTrue(text.contains("name=\"model\""), "openAICompat must use field name 'model'")
        XCTAssertTrue(text.contains("name=\"language\""), "openAICompat must use field name 'language'")
        XCTAssertFalse(text.contains("name=\"model_id\""), "openAICompat must NOT use 'model_id'")
        XCTAssertFalse(text.contains("name=\"language_code\""), "openAICompat must NOT use 'language_code'")
        XCTAssertTrue(text.contains("name=\"file\""), "file field name expected")
    }

    func testMultipartBuilderUsesElevenLabsFieldNames() {
        let (_, body) = STTMultipartBuilder.build(
            audioData: Data([0x00, 0x01, 0x02]),
            audioMIME: "audio/mp4",
            audioFilename: "audio.m4a",
            model: "scribe_v2",
            language: "en",
            fieldNames: .elevenLabs
        )

        let text = String(data: body, encoding: .utf8) ?? ""
        XCTAssertTrue(text.contains("name=\"model_id\""), "elevenLabs must use 'model_id'")
        XCTAssertTrue(text.contains("name=\"language_code\""), "elevenLabs must use 'language_code'")
        // Check explicit field-name form (not subtring inside model_id):
        XCTAssertFalse(text.contains("name=\"model\"\r\n"), "elevenLabs must NOT use bare 'model' field name")
        XCTAssertFalse(text.contains("name=\"language\"\r\n"), "elevenLabs must NOT use bare 'language' field name")
        XCTAssertTrue(text.contains("name=\"file\""), "file field name expected")
    }

    func testMultipartBuilderOmitsLanguageWhenNil() {
        let (_, body) = STTMultipartBuilder.build(
            audioData: Data([0x00, 0x01, 0x02]),
            audioMIME: "audio/mp4",
            audioFilename: "audio.m4a",
            model: "voxtral-mini-2602",
            language: nil,
            fieldNames: .openAICompat
        )

        let text = String(data: body, encoding: .utf8) ?? ""
        XCTAssertFalse(text.contains("name=\"language\""), "language part must be omitted when nil")
        XCTAssertFalse(text.contains("name=\"language_code\""), "language_code part must be omitted when nil")
    }

    // MARK: - Response decoder

    func testResponseDecoderOpenAIShape() throws {
        let data = #"{"text":"hello","language":"en"}"#.data(using: .utf8)!
        let resp = try STTResponseDecoder.decode(data, shape: .openAICompat)
        XCTAssertEqual(resp.text, "hello")
        XCTAssertEqual(resp.language, "en")
    }

    func testResponseDecoderElevenLabsShape() throws {
        let json = #"""
        {"text":"hello","language_code":"eng","language_probability":0.99,"words":[{"text":"hello","type":"word","start":0.0,"end":0.5}]}
        """#
        let data = json.data(using: .utf8)!
        let resp = try STTResponseDecoder.decode(data, shape: .elevenLabs)
        XCTAssertEqual(resp.text, "hello")
        XCTAssertEqual(resp.language, "eng")
    }

    func testResponseDecoderThrowsOnMissingText() {
        let payload = #"{"language":"en"}"#.data(using: .utf8)!

        for shape in [STTResponseShape.openAICompat, .elevenLabs] {
            XCTAssertThrowsError(try STTResponseDecoder.decode(payload, shape: shape)) { error in
                guard let appErr = error as? AppError else {
                    XCTFail("Expected AppError, got \(error)")
                    return
                }
                if case .sttDecodingFailure = appErr {
                    // pass
                } else {
                    XCTFail("Expected .sttDecodingFailure, got \(appErr) for shape \(shape)")
                }
            }
        }
    }

    func testResponseDecoderEmptyTextIsNoSpeech() {
        // A present-but-empty/whitespace `text` is a valid 2xx with no usable
        // transcript = "no speech", NOT a shape failure. Matches the JSON-family
        // providers (Gemini / OpenRouter) so every provider surfaces an empty
        // result uniformly instead of the multipart family silently returning "".
        let payloads = [
            #"{"text":""}"#,
            #"{"text":"   "}"#,
            #"{"text":"\n\t "}"#
        ].map { Data($0.utf8) }

        for shape in [STTResponseShape.openAICompat, .elevenLabs] {
            for payload in payloads {
                XCTAssertThrowsError(try STTResponseDecoder.decode(payload, shape: shape)) { error in
                    guard let appErr = error as? AppError, case .noSpeechDetected = appErr else {
                        return XCTFail("Expected .noSpeechDetected for shape \(shape), got \(error)")
                    }
                }
            }
        }
    }

    // MARK: - Status map (LOAD-BEARING)

    func testStatusMapMistral429IsQuotaExceededNonRetryable() {
        guard let err = STTStatusMap.mistral.map(429) else {
            XCTFail("Mistral 429 must produce an error")
            return
        }
        guard case .sttQuotaExceeded = err else {
            XCTFail("Mistral 429 must map to .sttQuotaExceeded, got \(err)")
            return
        }
        XCTAssertFalse(err.isRetryable,
                       "LOAD-BEARING: Mistral 429 (.sttQuotaExceeded) must be NON-retryable to avoid billing retries.")
    }

    func testStatusMapOpenAI429IsTooManyRequestsRetryable() {
        guard let err = STTStatusMap.openAICompat.map(429) else {
            XCTFail("OpenAI 429 must produce an error")
            return
        }
        guard case .sttTooManyRequests = err else {
            XCTFail("OpenAI 429 must map to .sttTooManyRequests, got \(err)")
            return
        }
        XCTAssertTrue(err.isRetryable,
                      "LOAD-BEARING: OpenAI 429 (.sttTooManyRequests) must be retryable (transient rate-limit).")
    }

    func testStatusMap2xxReturnsNil() {
        let maps: [STTStatusMap] = [.mistral, .openAICompat, .elevenLabsScribe, .gemini, .qwen]
        let codes = [200, 201, 204]
        for m in maps {
            for c in codes {
                XCTAssertNil(m.map(c), "2xx status \(c) must map to nil (caller decodes body)")
            }
        }
    }
}
