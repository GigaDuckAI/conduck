// SPDX-License-Identifier: Apache-2.0

// Conduck
// TTSDecodeChokepointTests.swift
//
// Locks the SHARED TTS response-decode chokepoint (`TTSProvider.ResponseShape`
// in Services/TTS/TTSProvider.swift) that iOS `TTSClient` + watchOS
// `WatchTTSClient` both route through. The contract under test:
//
//   - Gemini SAFETY-BLOCK vs EMPTY-AUDIO disambiguation: a 200 carrying
//     `promptFeedback.blockReason` + no candidates must decode to the
//     NON-retryable `ttsContentBlocked` (errorCode 41), NOT the retryable
//     `ttsEmptyAudio` (errorCode 38). A genuinely empty 200 → `ttsEmptyAudio`.
//     Getting this backwards either retries a hard-blocked reply forever or
//     burns the retry budget the preview model's text-token quirk depends on.
//   - `sampleRate(fromMimeType:)` must parse an in-range rate, and must REJECT
//     (→ nil, caller defaults 24000) a hostile/out-of-range/missing rate so the
//     downstream `wavWrappedPCM16` UInt32/byteRate conversions can never trap.
//   - A valid Gemini inline-audio payload → WAV/RIFF-wrapped PCM16 with a header
//     reflecting the RESOLVED sample rate.
//   - OpenRouter TTS `effectiveSpeechURL` is the composed literal
//     `openRouterBaseURLString + openRouterSpeechPath`.
//
// Pure value-type math — no network, no Keychain, no Core Data. Everything here
// is deterministic + headless. Error identity is asserted via the stable
// numeric `AppError.errorCode` (AppError carries associated `Error` payloads on
// other cases, so it is not `Equatable`; the numeric slot is the locked
// contract anyway — it crosses the wire and round-trips through `from(errorCode:)`).

import XCTest
@testable import Conduck

final class TTSDecodeChokepointTests: XCTestCase {

    // MARK: - Helpers

    /// JSON-encode a dictionary into the `Data` the decode chokepoint consumes.
    private func json(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object)
    }

    /// Extract the little-endian UInt32 at `offset` from a WAV header.
    private func le32(_ data: Data, at offset: Int) -> UInt32 {
        precondition(offset + 4 <= data.count)
        let bytes = Array(data[data.startIndex.advanced(by: offset)..<data.startIndex.advanced(by: offset + 4)])
        return UInt32(bytes[0]) | (UInt32(bytes[1]) << 8) | (UInt32(bytes[2]) << 16) | (UInt32(bytes[3]) << 24)
    }

    /// ASCII fourcc at `offset`.
    private func fourCC(_ data: Data, at offset: Int) -> String {
        let bytes = Array(data[data.startIndex.advanced(by: offset)..<data.startIndex.advanced(by: offset + 4)])
        return String(bytes: bytes, encoding: .ascii) ?? ""
    }

    // MARK: - Gemini safety-block vs empty-audio disambiguation

    func testGeminiSafetyBlockDecodesToContentBlockedNotEmptyAudio() throws {
        // 200 with a prompt-level safety block: promptFeedback.blockReason set,
        // candidates absent. Must surface the safety filter, NOT the retryable
        // empty-audio quirk.
        let payload = try json([
            "promptFeedback": ["blockReason": "PROHIBITED_CONTENT"]
        ])

        XCTAssertThrowsError(
            try TTSProvider.ResponseShape.geminiInlineAudio.decodeAudio(from: payload)
        ) { error in
            guard let appError = error as? AppError else {
                return XCTFail("Expected AppError, got \(error)")
            }
            // ttsContentBlocked is errorCode 41 (NON-retryable). Must NOT be the
            // retryable ttsEmptyAudio (38).
            XCTAssertEqual(appError.errorCode, 41,
                           "A promptFeedback.blockReason 200 must decode to ttsContentBlocked (41), not ttsEmptyAudio.")
        }
    }

    func testGeminiEmptyPayloadDecodesToEmptyAudio() throws {
        // A genuinely empty 200 (no promptFeedback, no candidates) → retryable
        // ttsEmptyAudio (38), distinct from the hard safety block above.
        let payload = try json([:])

        XCTAssertThrowsError(
            try TTSProvider.ResponseShape.geminiInlineAudio.decodeAudio(from: payload)
        ) { error in
            guard let appError = error as? AppError else {
                return XCTFail("Expected AppError, got \(error)")
            }
            XCTAssertEqual(appError.errorCode, 38,
                           "An empty Gemini 200 must decode to the retryable ttsEmptyAudio (38), not ttsContentBlocked.")
        }
    }

    func testGeminiTextTokenOnlyPartDecodesToEmptyAudio() throws {
        // The preview model's quirk: candidates present but the only part is a
        // text token with no inlineData → still the retryable ttsEmptyAudio (38),
        // NOT a content block.
        let payload = try json([
            "candidates": [
                ["content": ["parts": [["text": "sorry, here is the text"]]]]
            ]
        ])

        XCTAssertThrowsError(
            try TTSProvider.ResponseShape.geminiInlineAudio.decodeAudio(from: payload)
        ) { error in
            guard let appError = error as? AppError else {
                return XCTFail("Expected AppError, got \(error)")
            }
            XCTAssertEqual(appError.errorCode, 38,
                           "Text-token-only candidates must decode to the retryable ttsEmptyAudio (38).")
        }
    }

    // MARK: - sampleRate(fromMimeType:)

    func testSampleRateParsesInRangeMime() {
        // Docs-shaped mime: audio/L16;rate=24000.
        XCTAssertEqual(TTSProvider.ResponseShape.sampleRate(fromMimeType: "audio/L16;rate=24000"), 24000)
        // Live-shaped mime: lowercase + spaces + channels suffix.
        XCTAssertEqual(TTSProvider.ResponseShape.sampleRate(fromMimeType: "audio/l16; rate=16000; channels=1"), 16000)
    }

    func testSampleRateRejectsOutOfRangeAndMissingRate() {
        // Above the 8000...384000 clamp → nil (caller defaults 24000).
        XCTAssertNil(TTSProvider.ResponseShape.sampleRate(fromMimeType: "audio/l16;rate=99999999999"),
                     "A rate above the clamp ceiling must return nil so the caller defaults to 24000.")
        // Below the floor → nil.
        XCTAssertNil(TTSProvider.ResponseShape.sampleRate(fromMimeType: "audio/l16;rate=0"),
                     "rate=0 is below the 8000 floor and must return nil.")
        // No rate= token at all → nil.
        XCTAssertNil(TTSProvider.ResponseShape.sampleRate(fromMimeType: "audio/l16"),
                     "A mime with no rate= token must return nil.")
    }

    func testWavWrapDoesNotTrapOnDefaultRateAfterHostileMimeRejection() {
        // The hostile-mime path: sampleRate(...) returns nil, the chokepoint
        // defaults to 24000, then wraps. Reproduce that resolved-rate handoff and
        // assert the wrap completes (no UInt32/byteRate overflow trap) on a small
        // PCM buffer.
        let resolvedRate = TTSProvider.ResponseShape.sampleRate(fromMimeType: "audio/l16;rate=99999999999") ?? 24000
        XCTAssertEqual(resolvedRate, 24000, "Hostile rate must resolve to the 24000 default.")

        let pcm = Data([0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08])
        let wav = TTSProvider.ResponseShape.wavWrappedPCM16(pcm, sampleRate: resolvedRate, channels: 1)

        // 44-byte header + the PCM passthrough.
        XCTAssertEqual(wav.count, 44 + pcm.count)
        XCTAssertEqual(fourCC(wav, at: 0), "RIFF")
        XCTAssertEqual(fourCC(wav, at: 8), "WAVE")
    }

    // MARK: - Valid Gemini inline-audio → WAV-wrapped PCM16

    func testValidGeminiInlineAudioReturnsWavWrappedPCM16() throws {
        // 4 PCM samples (8 bytes, 16-bit LE). The chokepoint reads the rate from
        // inlineData.mimeType (16000, in range) and wraps in a WAV header.
        let pcm = Data([0x10, 0x20, 0x30, 0x40, 0x50, 0x60, 0x70, 0x80])
        let b64 = pcm.base64EncodedString()
        let payload = try json([
            "candidates": [
                ["content": ["parts": [
                    ["inlineData": [
                        "mimeType": "audio/L16;rate=16000",
                        "data": b64
                    ]]
                ]]]
            ]
        ])

        let wav = try TTSProvider.ResponseShape.geminiInlineAudio.decodeAudio(from: payload)

        // Canonical 44-byte header + the PCM, untouched.
        XCTAssertEqual(wav.count, 44 + pcm.count, "WAV output must be a 44-byte header + the PCM passthrough.")
        XCTAssertEqual(fourCC(wav, at: 0), "RIFF")
        XCTAssertEqual(fourCC(wav, at: 8), "WAVE")
        XCTAssertEqual(fourCC(wav, at: 12), "fmt ")
        XCTAssertEqual(fourCC(wav, at: 36), "data")

        // ChunkSize = 36 + dataLen; Subchunk2Size = dataLen.
        XCTAssertEqual(le32(wav, at: 4), UInt32(36 + pcm.count))
        XCTAssertEqual(le32(wav, at: 40), UInt32(pcm.count))

        // SampleRate field (offset 24) reflects the RESOLVED rate (16000), and
        // byteRate (offset 28) = sampleRate * channels(1) * 2.
        XCTAssertEqual(le32(wav, at: 24), 16000, "WAV header sample rate must reflect the mime-resolved rate.")
        XCTAssertEqual(le32(wav, at: 28), 16000 * 1 * 2, "byteRate = sampleRate * channels * 2 bytes-per-sample.")

        // The PCM bytes pass through unchanged after the 44-byte header.
        XCTAssertEqual(wav.suffix(pcm.count), pcm, "The PCM payload must be copied through untouched.")
    }

    // MARK: - OpenRouter TTS effectiveSpeechURL composed literal

    func testOpenRouterEffectiveSpeechURLIsComposedLiteral() {
        // openRouterBaseURLString ("https://openrouter.ai/api") + openRouterSpeechPath
        // ("/v1/audio/speech"). Transport is .openAISpeech → voice rides the body,
        // URL returns the fixed speechURL unchanged.
        let provider = TTSProvider.openRouterTTS
        let voice = provider.effectiveVoice(override: nil)
        let url = provider.effectiveSpeechURL(voice: voice)
        XCTAssertEqual(url.absoluteString, "https://openrouter.ai/api/v1/audio/speech",
                       "OpenRouter TTS endpoint must be the composed base + speech-path literal.")
    }
}
