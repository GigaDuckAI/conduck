// SPDX-License-Identifier: Apache-2.0

// Conduck
// TTSBodyFactoryTests.swift
//
// Cloud Text-to-Speech request-body shape. OpenAI uses `voice`; Mistral uses
// `voice_id` (NOT OpenAI-compatible — verified against docs.mistral.ai) — they
// are NO LONGER the same shape. ElevenLabs uses `{text, model_id}` (voice rides
// the URL, NOT the body).

import XCTest
@testable import Conduck

final class TTSBodyFactoryTests: XCTestCase {

    private func json(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: - OpenAI body (`voice`)

    func testOpenAISpeechBodyShape() throws {
        let data = try OpenAISpeechBody.buildRequestBody(
            text: "hello world", model: "gpt-4o-mini-tts", voice: "alloy"
        )
        let body = try json(data)
        XCTAssertEqual(body["model"] as? String, "gpt-4o-mini-tts")
        XCTAssertEqual(body["input"] as? String, "hello world")
        XCTAssertEqual(body["voice"] as? String, "alloy")
        XCTAssertEqual(body["response_format"] as? String, "mp3")
        XCTAssertEqual(Set(body.keys), ["model", "input", "voice", "response_format"],
                       "OpenAI body must carry exactly these 4 keys (voice field is `voice`).")
        XCTAssertNil(body["voice_id"], "OpenAI uses `voice`, never `voice_id`.")
    }

    // MARK: - Mistral body (`voice_id` — NOT the OpenAI shape)

    func testMistralSpeechBodyUsesVoiceId() throws {
        let data = try MistralSpeechBody.buildRequestBody(
            text: "bonjour", model: "voxtral-mini-tts-2603", voice: "en_paul_neutral"
        )
        let body = try json(data)
        XCTAssertEqual(body["model"] as? String, "voxtral-mini-tts-2603")
        XCTAssertEqual(body["input"] as? String, "bonjour")
        XCTAssertEqual(body["voice_id"] as? String, "en_paul_neutral",
                       "Mistral's voice field is `voice_id`, not `voice` (the bug being fixed).")
        XCTAssertEqual(body["response_format"] as? String, "mp3")
        XCTAssertEqual(Set(body.keys), ["model", "input", "voice_id", "response_format"],
                       "Mistral body must carry exactly these 4 keys (voice field is `voice_id`).")
        XCTAssertNil(body["voice"], "Mistral must NOT emit the OpenAI `voice` key.")
    }

    func testOpenAIAndMistralBodiesDiffer() throws {
        // Lock the regression: the two are NOT the same shape any more.
        let openai = try json(OpenAISpeechBody.buildRequestBody(
            text: "x", model: "m", voice: "v"))
        let mistral = try json(MistralSpeechBody.buildRequestBody(
            text: "x", model: "m", voice: "v"))
        XCTAssertTrue(openai.keys.contains("voice"))
        XCTAssertTrue(mistral.keys.contains("voice_id"))
        XCTAssertNotEqual(Set(openai.keys), Set(mistral.keys),
                          "OpenAI and Mistral request bodies must have distinct key sets.")
    }

    // MARK: - ElevenLabs body (voice rides the URL, not the body)

    func testElevenLabsBodyShape() throws {
        let data = try ElevenLabsTTSBody.buildRequestBody(
            text: "premium voice", model: "eleven_flash_v2_5", voice: "ignored-rides-url"
        )
        let body = try json(data)
        XCTAssertEqual(body["text"] as? String, "premium voice")
        XCTAssertEqual(body["model_id"] as? String, "eleven_flash_v2_5")
        XCTAssertEqual(Set(body.keys), ["text", "model_id"],
                       "ElevenLabs body must carry exactly {text, model_id} — voice rides the URL.")
        XCTAssertNil(body["voice"], "ElevenLabs must NOT put the voice in the body.")
    }

    // MARK: - Gemini body (nested :generateContent shape; model rides the URL)

    func testGeminiSpeechBodyNestedShape() throws {
        let data = try GeminiSpeechBody.buildRequestBody(
            text: "this is how your replies will sound",
            model: "ignored-rides-url",
            voice: "Kore"
        )
        let body = try json(data)

        // generationConfig.responseModalities == ["AUDIO"]
        let genConfig = try XCTUnwrap(body["generationConfig"] as? [String: Any])
        XCTAssertEqual(genConfig["responseModalities"] as? [String], ["AUDIO"],
                       "Gemini must request the AUDIO modality.")

        // generationConfig.speechConfig.voiceConfig.prebuiltVoiceConfig.voiceName == voice
        let speechConfig = try XCTUnwrap(genConfig["speechConfig"] as? [String: Any])
        let voiceConfig = try XCTUnwrap(speechConfig["voiceConfig"] as? [String: Any])
        let prebuilt = try XCTUnwrap(voiceConfig["prebuiltVoiceConfig"] as? [String: Any])
        XCTAssertEqual(prebuilt["voiceName"] as? String, "Kore",
                       "The resolved voice must land at prebuiltVoiceConfig.voiceName.")

        // contents[0].parts[0].text == "<directive>\n\n<text>". The text is
        // PREFIXED with the fixed "Say the following:" directive so Gemini's
        // prompt-safety classifier doesn't flag the bare reply as
        // PROHIBITED_CONTENT (a 200 with no candidates / no audio). Only the
        // text after the directive is spoken. See `GeminiSpeechBody`.
        let contents = try XCTUnwrap(body["contents"] as? [[String: Any]])
        let firstContent = try XCTUnwrap(contents.first)
        let parts = try XCTUnwrap(firstContent["parts"] as? [[String: Any]])
        let firstPart = try XCTUnwrap(parts.first)
        let expectedPrompt = "\(GeminiSpeechBody.synthesisDirective)\n\nthis is how your replies will sound"
        XCTAssertEqual(firstPart["text"] as? String, expectedPrompt,
                       "The spoken text must be prefixed with the synthesis directive at contents[0].parts[0].text.")
        XCTAssertTrue((firstPart["text"] as? String)?.hasSuffix("this is how your replies will sound") ?? false,
                      "The original text must be preserved verbatim after the directive.")

        // The model is NOT in the body — it rides the URL path.
        XCTAssertNil(body["model"], "Gemini model rides the URL path, not the body.")
    }
}
