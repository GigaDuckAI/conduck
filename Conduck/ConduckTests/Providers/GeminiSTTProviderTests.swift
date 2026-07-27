// SPDX-License-Identifier: Apache-2.0

// Conduck
// GeminiSTTProviderTests.swift
//
// Tests the Gemini-specific
// JSON request builder + decoder. Verifies the safety-block branch (no
// candidates + promptFeedback.blockReason → audioProcessingFailed) and the
// multi-part text concatenation behavior.

import XCTest
@testable import Conduck

final class GeminiSTTProviderTests: XCTestCase {

    // MARK: - Decoder happy path

    func testGeminiDecoderHappyPath() throws {
        let json = #"""
        {"candidates":[{"content":{"parts":[{"text":"hello world"}]}}]}
        """#
        let data = json.data(using: .utf8)!
        let resp = try GeminiSTT.decodeResponse(data)

        XCTAssertEqual(resp.text, "hello world")
        XCTAssertNil(resp.language, "Gemini does not echo language → must be nil")
    }

    // MARK: - Safety block

    func testGeminiDecoderSafetyBlockThrowsAudioProcessingFailed() {
        let json = #"""
        {"promptFeedback":{"blockReason":"SAFETY"}}
        """#
        let data = json.data(using: .utf8)!

        XCTAssertThrowsError(try GeminiSTT.decodeResponse(data)) { error in
            guard let appErr = error as? AppError else {
                XCTFail("Expected AppError, got \(error)")
                return
            }
            guard case .audioProcessingFailed = appErr else {
                XCTFail("Expected .audioProcessingFailed (safety-block locked decision), got \(appErr)")
                return
            }
        }
    }

    // MARK: - Empty candidates (no safety block)

    func testGeminiDecoderEmptyCandidatesThrowsDecodingFailure() {
        let json = #"""
        {"candidates":[]}
        """#
        let data = json.data(using: .utf8)!

        XCTAssertThrowsError(try GeminiSTT.decodeResponse(data)) { error in
            guard let appErr = error as? AppError else {
                XCTFail("Expected AppError, got \(error)")
                return
            }
            guard case .sttDecodingFailure = appErr else {
                XCTFail("Expected .sttDecodingFailure for empty-candidates-no-feedback, got \(appErr)")
                return
            }
        }
    }

    // MARK: - Multi-part concatenation

    func testGeminiDecoderMultiPartConcatenates() throws {
        let json = #"""
        {"candidates":[{"content":{"parts":[{"text":"foo "},{"text":"bar"}]}}]}
        """#
        let data = json.data(using: .utf8)!
        let resp = try GeminiSTT.decodeResponse(data)

        XCTAssertEqual(resp.text, "foo bar",
                       "Gemini chunked transcripts (multiple parts) must concatenate in order.")
    }

    // MARK: - Request builder shape

    func testGeminiRequestBuilderIncludesBase64AndPrompt() throws {
        let audio = Data([0xDE, 0xAD, 0xBE, 0xEF])
        let body = try GeminiSTT.buildRequestBody(audioData: audio,
                                                  language: "en",
                                                  model: STTProvider.geminiFlashLite.model)

        // Decode as generic JSON to introspect shape.
        guard let json = try JSONSerialization.jsonObject(with: body) as? [String: Any],
              let contents = json["contents"] as? [[String: Any]],
              let first = contents.first,
              let parts = first["parts"] as? [[String: Any]]
        else {
            XCTFail("Gemini request body shape unexpected — could not parse contents[0].parts")
            return
        }

        XCTAssertEqual(parts.count, 2, "Gemini request must contain 2 parts: text prompt + inline_data")

        // First part = text prompt; must contain "Transcribe"
        let textPart = parts[0]
        guard let promptText = textPart["text"] as? String else {
            XCTFail("First part must be a text part with 'text' field")
            return
        }
        XCTAssertTrue(promptText.contains("Transcribe"),
                      "Defensive prompt must contain 'Transcribe' instruction. Got: \(promptText)")

        // Second part = inline_data with mime_type + base64 data
        let inlinePart = parts[1]
        guard let inline = inlinePart["inline_data"] as? [String: Any],
              let dataField = inline["data"] as? String else {
            XCTFail("Second part must contain inline_data.data (snake_case key)")
            return
        }
        XCTAssertEqual(dataField, "3q2+7w==",
                       "Base64 of 0xDEADBEEF must be '3q2+7w==' (RFC 4648 standard alphabet)")
    }

    // MARK: - Feature 1: model override bites the URL, NOT the body

    /// Gemini's model lives in the URL PATH, not the request body — so a custom
    /// model override must leave the body byte-identical to the default. (Qwen
    /// is the inverse: its override changes the body. This asymmetry is exactly
    /// why `buildRequestBody` accepts `model:` for signature parity but Gemini
    /// ignores it.)
    func testGeminiRequestBodyIsUnchangedByModelOverride() throws {
        let audio = Data([0xDE, 0xAD, 0xBE, 0xEF])
        let defaultBody = try GeminiSTT.buildRequestBody(
            audioData: audio, language: "en", model: STTProvider.geminiFlashLite.model)
        let overrideBody = try GeminiSTT.buildRequestBody(
            audioData: audio, language: "en", model: "gemini-9-ultra")

        // Compare SEMANTICALLY, not byte-for-byte. Foundation's JSONEncoder
        // does not guarantee a stable key order for keyed containers on Darwin
        // (the `inline_data` object's `mime_type`/`data` keys can serialise in
        // either order across calls), so a raw `Data` equality check is flaky.
        // Normalising through JSONSerialization with sorted keys strips the
        // ordering noise while still proving the bodies are otherwise identical
        // — i.e. the model override never reaches the body (it lives in the URL).
        func normalized(_ data: Data) throws -> Data {
            let object = try JSONSerialization.jsonObject(with: data)
            return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        }
        XCTAssertEqual(try normalized(defaultBody), try normalized(overrideBody),
                       "Gemini body must be IDENTICAL regardless of model — the model lives in the URL path, not the body.")
        XCTAssertFalse(String(data: overrideBody, encoding: .utf8)!.contains("gemini-9-ultra"),
                       "The model override must not leak into the Gemini request body.")
    }

    /// The same override that left the body untouched MUST rebuild the URL via
    /// `effectiveTranscribeURL` — `/models/<override>:generateContent`.
    func testGeminiModelOverrideRebuildsURL() {
        let url = STTProvider.geminiFlashLite.effectiveTranscribeURL(customModel: "gemini-9-ultra")
        XCTAssertTrue(url.absoluteString.contains("/models/gemini-9-ultra:generateContent"),
                      "Gemini override must rebuild the URL to '/models/gemini-9-ultra:generateContent'. Got: \(url.absoluteString)")
    }

    /// An empty override leaves the Gemini URL on the pinned default.
    func testGeminiEmptyOverrideKeepsDefaultURL() {
        let url = STTProvider.geminiFlashLite.effectiveTranscribeURL(customModel: "  ")
        XCTAssertEqual(url, STTProvider.geminiFlashLite.transcribeURL,
                       "Empty/whitespace override must keep the pinned default Gemini URL.")
        XCTAssertTrue(url.absoluteString.contains("/models/gemini-3.1-flash-lite:generateContent"),
                      "Default Gemini URL must carry the pinned `gemini-3.1-flash-lite` model. Got: \(url.absoluteString)")
    }
}
