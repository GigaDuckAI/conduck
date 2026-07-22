// Conduck
// QwenSTTProviderTests.swift
//
// Tests the Qwen-specific
// (DashScope) JSON request builder + decoder. Verifies the verified chat-style
// response shape (`output.choices[0].message.content` is array of `{text}`),
// the `language=auto` default when no hint is provided, and the data-URI
// prefix on the audio field.

import XCTest
@testable import Conduck

final class QwenSTTProviderTests: XCTestCase {

    // MARK: - Decoder happy path (chat-style shape)

    func testQwenDecoderHappyPathFromChatShape() throws {
        let json = #"""
        {"output":{"choices":[{"message":{"content":[{"text":"hallo welt"}]}}]}}
        """#
        let data = json.data(using: .utf8)!
        let resp = try QwenSTT.decodeResponse(data)

        XCTAssertEqual(resp.text, "hallo welt")
        XCTAssertNil(resp.language, "Qwen does not echo language → must be nil")
    }

    // MARK: - Request builder: language=auto when nil

    func testQwenRequestBuilderLanguageAuto() throws {
        let body = try QwenSTT.buildRequestBody(audioData: Data([0x00, 0x01]),
                                                language: nil,
                                                model: STTProvider.qwenASRFlash.model)

        guard let json = try JSONSerialization.jsonObject(with: body) as? [String: Any],
              let params = json["parameters"] as? [String: Any],
              let asrOptions = params["asr_options"] as? [String: Any],
              let lang = asrOptions["language"] as? String
        else {
            XCTFail("Qwen request body shape unexpected — could not parse parameters.asr_options.language")
            return
        }

        XCTAssertEqual(lang, "auto",
                       "Qwen request builder must default language to 'auto' when caller passes nil.")
    }

    // MARK: - Request builder: model carried in body (Feature 1 override)

    func testQwenRequestBuilderUsesDefaultModelWhenNotOverridden() throws {
        let body = try QwenSTT.buildRequestBody(audioData: Data([0x00, 0x01]),
                                                language: nil,
                                                model: STTProvider.qwenASRFlash.model)

        guard let json = try JSONSerialization.jsonObject(with: body) as? [String: Any],
              let modelTag = json["model"] as? String
        else {
            XCTFail("Qwen request body shape unexpected — could not parse top-level model")
            return
        }
        XCTAssertEqual(modelTag, "qwen3-asr-flash",
                       "Default (un-overridden) Qwen body must carry the pinned `qwen3-asr-flash` model tag.")
    }

    /// Feature 1: a per-provider custom model override must be threaded into the
    /// Qwen JSON body's top-level `model` field, REPLACING the hardcoded default.
    /// The body factory takes `model:` from `provider.effectiveModel(customModel:)`
    /// at the call site, so feeding it directly here is equivalent.
    func testQwenRequestBuilderCarriesOverrideModel() throws {
        let override = STTProvider.qwenASRFlash.effectiveModel(customModel: "qwen3-asr-realtime")
        XCTAssertEqual(override, "qwen3-asr-realtime",
                       "effectiveModel must resolve the override before it reaches the body builder.")

        let body = try QwenSTT.buildRequestBody(audioData: Data([0x00, 0x01]),
                                                language: "en",
                                                model: override)

        guard let json = try JSONSerialization.jsonObject(with: body) as? [String: Any],
              let modelTag = json["model"] as? String
        else {
            XCTFail("Qwen request body shape unexpected — could not parse top-level model")
            return
        }
        XCTAssertEqual(modelTag, "qwen3-asr-realtime",
                       "Qwen JSON body must carry the OVERRIDE model tag, not the hardcoded `qwen3-asr-flash`.")
    }

    // MARK: - Request builder: data-URI prefix

    func testQwenRequestBuilderDataURIPrefix() throws {
        let body = try QwenSTT.buildRequestBody(audioData: Data([0xDE, 0xAD, 0xBE, 0xEF]),
                                                language: "en",
                                                model: STTProvider.qwenASRFlash.model)

        guard let json = try JSONSerialization.jsonObject(with: body) as? [String: Any],
              let input = json["input"] as? [String: Any],
              let messages = input["messages"] as? [[String: Any]],
              let firstMsg = messages.first,
              let content = firstMsg["content"] as? [[String: Any]],
              let firstContent = content.first,
              let audioStr = firstContent["audio"] as? String
        else {
            XCTFail("Qwen request body shape unexpected — could not parse input.messages[0].content[0].audio")
            return
        }

        XCTAssertTrue(audioStr.hasPrefix("data:audio/mp4;base64,"),
                      "Qwen audio field must be a data-URI with 'data:audio/mp4;base64,' prefix. Got: \(audioStr.prefix(40))…")
    }
}
