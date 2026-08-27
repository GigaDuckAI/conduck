// SPDX-License-Identifier: Apache-2.0

// Conduck
// GeminiSTTProviderTests.swift
//
// Tests the Gemini-specific Interactions-API request builder + decoder.
//
// The centre of gravity here is the STRUCTURAL-ABSENCE vs EXPLICIT-EMPTY
// distinction. Those two cases used to collapse onto `noSpeechDetected`, and
// that collapse is what would have let a completely non-functional endpoint
// ship as a transcriber that quietly reported "no speech" on every recording
// (see `GeminiSTTProvider.swift` header). A missing text ITEM is a broken wire
// contract and must fail loudly; an empty text VALUE is a quiet room.

import XCTest
@testable import Conduck

final class GeminiSTTProviderTests: XCTestCase {

    private let audio = Data([0xDE, 0xAD, 0xBE, 0xEF])

    private func assertThrows(_ data: Data,
                              _ expected: AppError,
                              _ message: String,
                              file: StaticString = #filePath,
                              line: UInt = #line) {
        XCTAssertThrowsError(try GeminiSTT.decodeResponse(data), message, file: file, line: line) { error in
            guard let appErr = error as? AppError else {
                XCTFail("Expected AppError, got \(error)", file: file, line: line)
                return
            }
            XCTAssertEqual(appErr.errorCode, expected.errorCode, message, file: file, line: line)
        }
    }

    private func json(_ s: String) -> Data { s.data(using: .utf8)! }

    // MARK: - Decoder happy path

    func testDecoderHappyPath() throws {
        let resp = try GeminiSTT.decodeResponse(json(#"""
        {"status":"completed","steps":[{"type":"model_output",
         "content":[{"type":"text","text":"hello world"}]}]}
        """#))
        XCTAssertEqual(resp.text, "hello world")
        XCTAssertNil(resp.language, "Gemini does not echo language → must be nil")
    }

    func testDecoderConcatenatesTextItemsWithinFinalStep() throws {
        let resp = try GeminiSTT.decodeResponse(json(#"""
        {"status":"completed","steps":[{"type":"model_output",
         "content":[{"type":"text","text":"foo "},{"type":"text","text":"bar"}]}]}
        """#))
        XCTAssertEqual(resp.text, "foo bar",
                       "Chunked transcripts must concatenate in order within the final model output.")
    }

    /// Only the LAST model output counts. Folding every text-bearing step
    /// together would duplicate an earlier partial — or a future thought/tool
    /// step — into the user's message.
    func testDecoderUsesOnlyFinalModelOutput() throws {
        let resp = try GeminiSTT.decodeResponse(json(#"""
        {"status":"completed","steps":[
         {"type":"thought","content":[{"type":"text","text":"IGNORE ME"}]},
         {"type":"model_output","content":[{"type":"text","text":"first pass"}]},
         {"type":"model_output","content":[{"type":"text","text":"final answer"}]}]}
        """#))
        XCTAssertEqual(resp.text, "final answer",
                       "Only the final model_output may reach the user; earlier steps must not be folded in.")
    }

    // MARK: - Structural absence vs explicit empty (the regression net)

    /// THE case this file exists for. `gemini-3.5-transcribe` on the OLD
    /// `:generateContent` endpoint answers HTTP 200 with `parts: [{}]` — a
    /// well-formed envelope carrying no text item at all. If that decodes as
    /// `noSpeechDetected`, a totally broken endpoint looks like silence and
    /// ships green.
    func testLegacyEmptyPartIsDecodingFailureNotNoSpeech() {
        assertThrows(json(#"{"candidates":[{"content":{"parts":[{}]},"finishReason":"STOP"}]}"#),
                     .sttDecodingFailure,
                     "`parts: [{}]` is structural absence — it must NEVER read as noSpeechDetected.")
    }

    func testCompletedWithNoModelOutputStepIsDecodingFailure() {
        assertThrows(json(#"{"status":"completed","steps":[{"type":"thought","content":[]}]}"#),
                     .sttDecodingFailure,
                     "A completed interaction with no model_output is a broken contract, not silence.")
    }

    func testCompletedWithNoTextItemIsDecodingFailure() {
        assertThrows(json(#"{"status":"completed","steps":[{"type":"model_output","content":[]}]}"#),
                     .sttDecodingFailure,
                     "A model output with no text item is structural absence, not silence.")
    }

    func testMissingStepsIsDecodingFailure() {
        assertThrows(json(#"{"status":"completed"}"#), .sttDecodingFailure,
                     "Missing `steps` is a broken contract.")
    }

    func testEmptyObjectIsDecodingFailure() {
        assertThrows(json("{}"), .sttDecodingFailure, "An empty object carries no verdict at all.")
    }

    /// A `type:"text"` item with NO `text` member is structural absence
    /// wearing the right label. `compactMap` alone erases it into "" and
    /// reports silence — the exact confusion this decoder exists to prevent.
    func testTextItemMissingItsValueIsDecodingFailureNotNoSpeech() {
        assertThrows(json(#"""
        {"status":"completed","steps":[{"type":"model_output",
         "content":[{"type":"text"}]}]}
        """#), .sttDecodingFailure,
                     "A text item without a `text` member is a broken contract, not silence.")
    }

    func testTextItemWithNullValueIsDecodingFailure() {
        assertThrows(json(#"""
        {"status":"completed","steps":[{"type":"model_output",
         "content":[{"type":"text","text":null}]}]}
        """#), .sttDecodingFailure,
                     "An explicit null `text` is absence, not an empty transcript.")
    }

    /// A response mixing one good item with one missing its value must NOT be
    /// silently accepted as a partial transcript — the user would send words
    /// they never finished saying.
    func testMixedValidAndMissingTextItemsIsDecodingFailure() {
        assertThrows(json(#"""
        {"status":"completed","steps":[{"type":"model_output",
         "content":[{"type":"text","text":"real words"},{"type":"text"}]}]}
        """#), .sttDecodingFailure,
                     "A partially-formed content array must fail, not truncate the user's sentence.")
    }

    /// The counterpart: an EXPLICIT text item that is empty really does mean
    /// the provider heard nothing.
    func testExplicitEmptyTextIsNoSpeechDetected() {
        assertThrows(json(#"""
        {"status":"completed","steps":[{"type":"model_output",
         "content":[{"type":"text","text":"   "}]}]}
        """#), .noSpeechDetected,
                     "An explicit but blank transcript is genuine silence.")
    }

    // MARK: - Status gate

    func testFailedWithSafetyCodeIsAudioProcessingFailed() {
        assertThrows(json(#"{"status":"failed","error":{"code":"safety"}}"#),
                     .audioProcessingFailed,
                     "A content refusal keeps the locked audioProcessingFailed mapping.")
    }

    func testFailedWithoutSafetyCodeIsServerError() {
        assertThrows(json(#"{"status":"failed","error":{"code":"internal"}}"#),
                     .sttServerError,
                     "A platform fault is a server error, not a content block.")
    }

    func testCancelledAndIncompleteNeverReturnPartialText() {
        for status in ["cancelled", "incomplete"] {
            assertThrows(json("""
            {"status":"\(status)","steps":[{"type":"model_output",
             "content":[{"type":"text","text":"half a sen"}]}]}
            """), .audioProcessingFailed,
                         "\(status): partial text must never be dispatched as the user's words.")
        }
    }

    func testInProgressIsProtocolFailure() {
        assertThrows(json(#"{"status":"in_progress","steps":[]}"#), .sttDecodingFailure,
                     "With store:false there is no id to poll — in_progress is a protocol failure.")
    }

    // MARK: - Request builder shape

    func testRequestCarriesModelStoreFalseAndVerbatimMode() throws {
        let body = try GeminiSTT.buildRequestBody(audioData: audio, language: nil,
                                                  model: STTProvider.gemini.model)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])

        XCTAssertEqual(json["model"] as? String, "gemini-3.5-transcribe",
                       "The model rides the BODY on the Interactions endpoint.")
        XCTAssertEqual(json["store"] as? Bool, false,
                       "store:false must be sent — the Interactions API retains requests by default.")

        let genConfig = try XCTUnwrap(json["generation_config"] as? [String: Any])
        let transcription = try XCTUnwrap(genConfig["transcription_config"] as? [String: Any])
        let mode = try XCTUnwrap(transcription["mode"] as? [String: Any])
        XCTAssertEqual(mode["type"] as? String, "verbatim",
                       "Verbatim is sent explicitly so a future default flip to `smart` cannot silently rewrite the user's words.")
        XCTAssertNil(transcription["language_codes"],
                     "With no hint set, language_codes must be OMITTED (auto-detect), not sent empty.")
    }

    func testRequestCarriesBase64AudioAndMIME() throws {
        let body = try GeminiSTT.buildRequestBody(audioData: audio, language: nil,
                                                  model: STTProvider.gemini.model)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let input = try XCTUnwrap(json["input"] as? [[String: Any]])

        let audioPart = try XCTUnwrap(input.first { $0["type"] as? String == "audio" })
        XCTAssertEqual(audioPart["data"] as? String, "3q2+7w==",
                       "Base64 of 0xDEADBEEF must be '3q2+7w==' (RFC 4648 standard alphabet)")
        XCTAssertEqual(audioPart["mime_type"] as? String, "audio/mp4",
                       "Matches the pipeline's AAC-in-MP4 output; snake_case key.")
    }

    func testLanguageHintRidesTranscriptionConfigNotThePrompt() throws {
        let body = try GeminiSTT.buildRequestBody(audioData: audio, language: "de",
                                                  model: STTProvider.gemini.model)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let transcription = try XCTUnwrap(
            (json["generation_config"] as? [String: Any])?["transcription_config"] as? [String: Any])

        XCTAssertEqual(transcription["language_codes"] as? [String], ["de"],
                       "The hint moved out of the prompt string into transcription_config.")
        XCTAssertFalse(String(data: body, encoding: .utf8)!.contains("Language: de"),
                       "The old prompt-appended hint channel must be gone.")
    }

    // MARK: - Prompt is conditional on the model

    /// The dedicated model ignores a text part entirely (measured) and rejects
    /// `system_instruction`, so we do not pay for one. A general model reached
    /// through the Advanced override still needs telling what job to do.
    func testDedicatedModelSendsNoPromptButOverrideDoes() throws {
        func inputTypes(model: String) throws -> [String] {
            let body = try GeminiSTT.buildRequestBody(audioData: audio, language: nil, model: model)
            let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
            return try XCTUnwrap(json["input"] as? [[String: Any]]).compactMap { $0["type"] as? String }
        }

        XCTAssertEqual(try inputTypes(model: STTProvider.gemini.model), ["audio"],
                       "The dedicated transcribe model must receive audio only.")
        XCTAssertEqual(try inputTypes(model: "gemini-3.1-flash-lite"), ["text", "audio"],
                       "A general model via the Advanced override still gets the task instruction.")
    }

    func testModelOverrideReachesTheBody() throws {
        let body = try GeminiSTT.buildRequestBody(audioData: audio, language: nil,
                                                  model: "gemini-9-ultra")
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["model"] as? String, "gemini-9-ultra",
                       "On the Interactions endpoint the override MUST reach the body — it no longer rides the URL.")
    }

    // MARK: - Legacy transition path

    /// A background upload started by the previous build can land after an
    /// update. Its old-shaped response must still decode, or the user loses a
    /// transcript they already spoke.
    func testLegacyGenerateContentResponseStillDecodes() throws {
        let resp = try GeminiSTT.decodeResponse(
            json(#"{"candidates":[{"content":{"parts":[{"text":"legacy in flight"}]}}]}"#))
        XCTAssertEqual(resp.text, "legacy in flight")
    }

    func testLegacySafetyBlockStillMaps() {
        assertThrows(json(#"{"promptFeedback":{"blockReason":"SAFETY"}}"#),
                     .audioProcessingFailed,
                     "The legacy safety-block branch keeps its locked mapping during the transition.")
    }
}
