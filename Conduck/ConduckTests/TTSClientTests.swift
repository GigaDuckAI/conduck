// SPDX-License-Identifier: Apache-2.0

// Conduck
// TTSClientTests.swift
//
// Cloud Text-to-Speech client round-trip via MockURLProtocol. Asserts the
// 2xx→Data, 2xx-empty→ttsEmptyAudio, 4xx/5xx→mapped, timeout→requestTimeout
// behavior, and that the auth header is set on the request (never logged — the
// test only inspects the URLRequest it captured, the client never echoes it).
//
// Per-test URLSession (NOT shared) — MockURLProtocol stores its handler
// statically, so a shared session would cross-contaminate. Teardown nils the
// handler for the same reason. Mirrors `RemoteAgentClientTests`.

import XCTest
@testable import Conduck

final class TTSClientTests: XCTestCase {

    private var session: URLSession!
    private let apiKey = "secret-key-do-not-log"

    override func setUp() {
        super.setUp()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        session = URLSession(configuration: config)
    }

    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        session.invalidateAndCancel()
        session = nil
        super.tearDown()
    }

    private func ok(_ request: URLRequest, body: Data) -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "audio/mpeg"]
        )!
        return (response, body)
    }

    private func status(_ request: URLRequest, _ code: Int, headers: [String: String]? = nil) -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(
            url: request.url!, statusCode: code, httpVersion: "HTTP/1.1", headerFields: headers
        )!
        return (response, Data("{\"error\":\"x\"}".utf8))
    }

    // MARK: - Happy path

    func testSuccessReturnsAudioBytes() async throws {
        let audio = Data([0xFF, 0xFB, 0x90, 0x00, 0x01, 0x02])  // mp3-ish bytes
        MockURLProtocol.requestHandler = { req in self.ok(req, body: audio) }

        let data = try await TTSClient.shared.synthesize(
            text: "hello", provider: .openAITTS, voice: nil, apiKey: apiKey, session: session
        )
        XCTAssertEqual(data, audio)
    }

    func testBearerAuthHeaderIsSet() async throws {
        var captured: URLRequest?
        MockURLProtocol.requestHandler = { req in
            captured = req
            return self.ok(req, body: Data([0x01]))
        }

        _ = try await TTSClient.shared.synthesize(
            text: "hi", provider: .openAITTS, voice: nil, apiKey: apiKey, session: session
        )
        let req = try XCTUnwrap(captured)
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer \(apiKey)")
        XCTAssertEqual(req.httpMethod, "POST")
        XCTAssertEqual(req.url?.absoluteString, "https://api.openai.com/v1/audio/speech")
    }

    func testElevenLabsHeaderAuthAndVoicePathURL() async throws {
        var captured: URLRequest?
        MockURLProtocol.requestHandler = { req in
            captured = req
            return self.ok(req, body: Data([0x01]))
        }

        _ = try await TTSClient.shared.synthesize(
            text: "hi", provider: .elevenLabsTTS, voice: "Rachel123", apiKey: apiKey, session: session
        )
        let req = try XCTUnwrap(captured)
        XCTAssertEqual(req.value(forHTTPHeaderField: "xi-api-key"), apiKey,
                       "ElevenLabs uses the xi-api-key header, not Bearer.")
        XCTAssertNil(req.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(req.url?.absoluteString,
                       "https://api.elevenlabs.io/v1/text-to-speech/Rachel123?output_format=mp3_44100_128")
    }

    // MARK: - Empty audio

    func testEmptySuccessBodyThrowsTTSEmptyAudio() async {
        MockURLProtocol.requestHandler = { req in self.ok(req, body: Data()) }
        do {
            _ = try await TTSClient.shared.synthesize(
                text: "x", provider: .openAITTS, voice: nil, apiKey: apiKey, session: session
            )
            XCTFail("Expected ttsEmptyAudio")
        } catch let e as AppError {
            XCTAssertEqual(e.errorCode, AppError.ttsEmptyAudio.errorCode)
        } catch {
            XCTFail("Expected AppError, got \(error)")
        }
    }

    // MARK: - Mistral base64-JSON response (NOT raw bytes)

    /// Helper: a 2xx JSON body (Mistral returns JSON, not raw audio).
    private func jsonOK(_ request: URLRequest, _ object: [String: Any]) -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        return (response, data)
    }

    func testMistralBase64JSONResponseIsDecoded() async throws {
        let audio = Data([0xFF, 0xFB, 0x90, 0x00, 0xDE, 0xAD])
        let b64 = audio.base64EncodedString()
        MockURLProtocol.requestHandler = { req in self.jsonOK(req, ["audio_data": b64]) }

        let data = try await TTSClient.shared.synthesize(
            text: "bonjour", provider: .mistralTTS, voice: nil, apiKey: apiKey, session: session
        )
        XCTAssertEqual(data, audio, "Mistral's base64 `audio_data` must be decoded back to the mp3 bytes.")
    }

    func testMistralSendsVoiceIdNotVoice() async throws {
        var captured: URLRequest?
        let audio = Data([0x01, 0x02])
        MockURLProtocol.requestHandler = { req in
            captured = req
            return self.jsonOK(req, ["audio_data": audio.base64EncodedString()])
        }
        _ = try await TTSClient.shared.synthesize(
            text: "bonjour", provider: .mistralTTS, voice: "en_paul_neutral", apiKey: apiKey, session: session
        )
        let req = try XCTUnwrap(captured)
        let body = try XCTUnwrap(req.httpBody ?? Self.readStreamBody(req))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["voice_id"] as? String, "en_paul_neutral",
                       "Mistral request must carry `voice_id`, not `voice`.")
        XCTAssertNil(json["voice"], "Mistral must NOT send the OpenAI `voice` field.")
        XCTAssertEqual(req.url?.absoluteString, "https://api.mistral.ai/v1/audio/speech")
    }

    func testMistralEmptyAudioDataFieldThrowsTTSEmptyAudio() async {
        MockURLProtocol.requestHandler = { req in self.jsonOK(req, ["audio_data": ""]) }
        await assertMistralEmptyAudio()
    }

    func testMistralMissingAudioDataFieldThrowsTTSEmptyAudio() async {
        MockURLProtocol.requestHandler = { req in self.jsonOK(req, ["unexpected": "shape"]) }
        await assertMistralEmptyAudio()
    }

    private func assertMistralEmptyAudio() async {
        do {
            _ = try await TTSClient.shared.synthesize(
                text: "x", provider: .mistralTTS, voice: nil, apiKey: apiKey, session: session
            )
            XCTFail("Expected ttsEmptyAudio")
        } catch let e as AppError {
            XCTAssertEqual(e.errorCode, AppError.ttsEmptyAudio.errorCode)
        } catch {
            XCTFail("Expected AppError, got \(error)")
        }
    }

    // MARK: - Gemini inlineData decode (PCM → WAV wrap)

    /// Build a synthetic Gemini `:generateContent` 200 body carrying base64 PCM
    /// at candidates[0].content.parts[0].inlineData.data with the given mimeType.
    private func geminiBody(pcm: Data, mimeType: String) -> Data {
        let object: [String: Any] = [
            "candidates": [
                ["content": ["parts": [
                    ["inlineData": ["mimeType": mimeType, "data": pcm.base64EncodedString()]],
                ]]],
            ],
        ]
        return (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    }

    /// The decode chokepoint is shared by iOS + watchOS, so test it directly
    /// (no auth/key plumbing). Gemini returns headerless PCM → must come back
    /// wrapped in a 44-byte WAV/RIFF container.
    func testGeminiDecodeWrapsPCMInWAVHeaderAt24kHz() throws {
        let pcm = Data([0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88])
        let body = geminiBody(pcm: pcm, mimeType: "audio/L16;rate=24000")

        let wav = try TTSProvider.geminiTTS.responseDecoding.decodeAudio(from: body)

        // "RIFF" at [0..4) and "WAVE" at [8..12).
        XCTAssertEqual(wav.subdata(in: 0..<4), Data("RIFF".utf8))
        XCTAssertEqual(wav.subdata(in: 8..<12), Data("WAVE".utf8))
        // Little-endian UInt32 sample-rate field at offset 24.
        XCTAssertEqual(Self.readLE32(wav, at: 24), 24000)
        // The 44-byte header then the original PCM, byte-for-byte.
        XCTAssertEqual(wav.count, 44 + pcm.count)
        XCTAssertEqual(wav.subdata(in: 44..<wav.count), pcm,
                       "The PCM samples must pass through unmodified (container packaging, not transcode).")
    }

    func testGeminiDecodeHonorsMimeTypeSampleRate16kHz() throws {
        let pcm = Data([0xAB, 0xCD, 0xEF, 0x01])
        let body = geminiBody(pcm: pcm, mimeType: "audio/L16;rate=16000")

        let wav = try TTSProvider.geminiTTS.responseDecoding.decodeAudio(from: body)

        XCTAssertEqual(Self.readLE32(wav, at: 24), 16000,
                       "The WAV header's sample-rate field must follow the inlineData mimeType.")
        XCTAssertEqual(wav.subdata(in: 44..<wav.count), pcm)
    }

    /// The LIVE wire form is lowercase with spaces (`audio/l16; rate=24000;
    /// channels=1`); the parser must be case/space tolerant, not only match the
    /// docs-form `audio/L16;rate=24000` the tests above use.
    func testGeminiDecodeParsesLowercaseSpacedMimeType() throws {
        let pcm = Data([0x01, 0x02, 0x03, 0x04])
        let body = geminiBody(pcm: pcm, mimeType: "audio/l16; rate=24000; channels=1")

        let wav = try TTSProvider.geminiTTS.responseDecoding.decodeAudio(from: body)

        XCTAssertEqual(Self.readLE32(wav, at: 24), 24000,
                       "The live lowercase/spaced mimeType form must parse to 24000.")
        XCTAssertEqual(wav.subdata(in: 44..<wav.count), pcm)
    }

    /// A missing / unparseable rate must fall back to 24000 (the verified default
    /// for gemini-3.1-flash-tts-preview) rather than emit a pitch-shifted clip.
    func testGeminiDecodeDefaultsTo24kHzWhenRateAbsent() throws {
        let pcm = Data([0x09, 0x08, 0x07, 0x06])
        let body = geminiBody(pcm: pcm, mimeType: "audio/L16")

        let wav = try TTSProvider.geminiTTS.responseDecoding.decodeAudio(from: body)

        XCTAssertEqual(Self.readLE32(wav, at: 24), 24000,
                       "A rate-less mimeType must default to 24000, not 0 or garbage.")
        XCTAssertEqual(wav.subdata(in: 44..<wav.count), pcm)
    }

    func testGeminiDecodeTextOnlyPartThrowsTTSEmptyAudio() {
        // The preview model occasionally returns a text token with no inlineData.
        let object: [String: Any] = [
            "candidates": [["content": ["parts": [["text": "hi"]]]]],
        ]
        let body = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        do {
            _ = try TTSProvider.geminiTTS.responseDecoding.decodeAudio(from: body)
            XCTFail("Expected ttsEmptyAudio for a parts:[{text}] body with no inlineData")
        } catch let e as AppError {
            XCTAssertEqual(e.errorCode, AppError.ttsEmptyAudio.errorCode)
        } catch {
            XCTFail("Expected AppError, got \(error)")
        }
    }

    /// Read a little-endian UInt32 from `data` at byte `offset`.
    private static func readLE32(_ data: Data, at offset: Int) -> UInt32 {
        let bytes = [UInt8](data.subdata(in: offset..<(offset + 4)))
        return UInt32(bytes[0]) | (UInt32(bytes[1]) << 8)
            | (UInt32(bytes[2]) << 16) | (UInt32(bytes[3]) << 24)
    }

    // MARK: - Error statuses

    func testAuth401MapsToUnauthorized() async {
        // A 401 is a key/scope rejection (e.g. an ElevenLabs speech_to_text-only
        // key on the TTS endpoint), NOT a voice problem — it must surface as the
        // distinct `ttsUnauthorized` class and must NOT auto-retry.
        var calls = 0
        MockURLProtocol.requestHandler = { req in calls += 1; return self.status(req, 401) }
        do {
            _ = try await TTSClient.shared.synthesize(
                text: "x", provider: .openAITTS, voice: nil, apiKey: apiKey, session: session
            )
            XCTFail("Expected ttsUnauthorized")
        } catch let e as AppError {
            XCTAssertEqual(e.errorCode, AppError.ttsUnauthorized.errorCode)
            XCTAssertEqual(calls, 1, "401 is terminal — the loop must not retry.")
        } catch {
            XCTFail("Expected AppError, got \(error)")
        }
    }

    func testServer500RetriesThenThrowsProviderUnreachable() async {
        var calls = 0
        MockURLProtocol.requestHandler = { req in
            calls += 1
            return self.status(req, 500)
        }
        do {
            _ = try await TTSClient.shared.synthesize(
                text: "x", provider: .mistralTTS, voice: nil, apiKey: apiKey, session: session
            )
            XCTFail("Expected ttsProviderUnreachable")
        } catch let e as AppError {
            XCTAssertEqual(e.errorCode, AppError.ttsProviderUnreachable.errorCode)
            // maxAttempts == 2 → the loop tries at most twice.
            XCTAssertEqual(calls, 2, "500 is retryable; the loop must try exactly 2 times before giving up.")
        } catch {
            XCTFail("Expected AppError, got \(error)")
        }
    }

    // MARK: - 429 Retry-After honor

    /// A 429 carrying a short `Retry-After` must wait it out and retry — the
    /// success on attempt 2 proves the penalty didn't get thrown away as a
    /// terminal failure (the old blind 1 s retry inside the penalty window).
    /// The hint is 2 s — DELIBERATELY above the base 1 s pacing, so the
    /// elapsed assertion can only pass if the wait came from the HEADER
    /// (a hint of 1 would be indistinguishable from ignoring it).
    func testRateLimit429HonorsShortRetryAfterThenSucceeds() async throws {
        let audio = Data([0x0A, 0x0B, 0x0C])
        var calls = 0
        MockURLProtocol.requestHandler = { req in
            calls += 1
            if calls == 1 {
                return self.status(req, 429, headers: ["Retry-After": "2"])
            }
            return self.ok(req, body: audio)
        }

        let start = Date()
        let data = try await TTSClient.shared.synthesize(
            text: "x", provider: .openAITTS, voice: nil, apiKey: apiKey, session: session
        )
        XCTAssertEqual(data, audio)
        XCTAssertEqual(calls, 2, "429 with an absorbable Retry-After must retry exactly once.")
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(start), 2.0,
                                    "The retry must wait the stated 2 s penalty, not the base 1 s pacing.")
    }

    /// A stated penalty beyond `maxRetryAfterWait` means the one retry is
    /// doomed — the client must give up IMMEDIATELY (single request, no
    /// 15 s dead wait) so the playback layer falls back to Apple now.
    func testRateLimit429LongRetryAfterGivesUpWithoutSecondAttempt() async {
        var calls = 0
        MockURLProtocol.requestHandler = { req in
            calls += 1
            return self.status(req, 429, headers: ["Retry-After": "300"])
        }
        let start = Date()
        do {
            _ = try await TTSClient.shared.synthesize(
                text: "x", provider: .openAITTS, voice: nil, apiKey: apiKey, session: session
            )
            XCTFail("Expected ttsRateLimited")
        } catch let e as AppError {
            XCTAssertEqual(e.errorCode, AppError.ttsRateLimited.errorCode)
            XCTAssertEqual(calls, 1, "A > cap penalty must NOT burn a doomed second attempt.")
            XCTAssertLessThan(Date().timeIntervalSince(start), 5.0,
                              "Giving up must be immediate — no capped-wait before the throw.")
        } catch {
            XCTFail("Expected AppError, got \(error)")
        }
    }

    /// A bare 429 (no header) keeps the legacy base pacing: one 1 s retry,
    /// then the rate-limited throw. Guards against the header path accidentally
    /// changing behavior for providers that never send Retry-After.
    func testRateLimit429WithoutHeaderRetriesAtBasePacing() async {
        var calls = 0
        MockURLProtocol.requestHandler = { req in
            calls += 1
            return self.status(req, 429)
        }
        do {
            _ = try await TTSClient.shared.synthesize(
                text: "x", provider: .openAITTS, voice: nil, apiKey: apiKey, session: session
            )
            XCTFail("Expected ttsRateLimited")
        } catch let e as AppError {
            XCTAssertEqual(e.errorCode, AppError.ttsRateLimited.errorCode)
            XCTAssertEqual(calls, 2, "Headerless 429 keeps the one base-paced retry.")
        } catch {
            XCTFail("Expected AppError, got \(error)")
        }
    }

    // MARK: - Retry-After parser

    func testRetryAfterParsesDeltaSeconds() {
        XCTAssertEqual(TTSClient.retryAfterSeconds(from: "12"), 12)
        XCTAssertEqual(TTSClient.retryAfterSeconds(from: "0"), 0)
        XCTAssertEqual(TTSClient.retryAfterSeconds(from: " 7 "), 7, "Whitespace-padded values must parse.")
        XCTAssertEqual(TTSClient.retryAfterSeconds(from: "1.5"), 1.5, "Fractional seconds are tolerated.")
    }

    func testRetryAfterRejectsGarbageAndNegatives() {
        XCTAssertNil(TTSClient.retryAfterSeconds(from: nil))
        XCTAssertNil(TTSClient.retryAfterSeconds(from: ""))
        XCTAssertNil(TTSClient.retryAfterSeconds(from: "soon"))
        XCTAssertNil(TTSClient.retryAfterSeconds(from: "-5"))
        // Double(String) alone would accept these as huge/infinite "penalties"
        // and trip the give-up-fast arm; the shape validation must reject them
        // so garbage keeps the documented base-paced retry.
        XCTAssertNil(TTSClient.retryAfterSeconds(from: "1e20"))
        XCTAssertNil(TTSClient.retryAfterSeconds(from: "inf"))
        XCTAssertNil(TTSClient.retryAfterSeconds(from: "0x1p60"))
        XCTAssertNil(TTSClient.retryAfterSeconds(from: "1.2.3"))
    }

    func testRetryAfterParsesHTTPDateRelativeToNow() {
        let now = Date(timeIntervalSince1970: 1_445_412_480)  // 2015-10-21 07:28:00 GMT
        let tenLater = "Wed, 21 Oct 2015 07:28:10 GMT"
        let parsed = TTSClient.retryAfterSeconds(from: tenLater, now: now)
        XCTAssertEqual(parsed ?? -1, 10, accuracy: 0.001,
                       "HTTP-date form must resolve to seconds-from-now.")
        // A date already in the past = penalty lapsed → 0, not negative/nil.
        let past = "Wed, 21 Oct 2015 07:27:00 GMT"
        XCTAssertEqual(TTSClient.retryAfterSeconds(from: past, now: now), 0)
    }

    /// RFC 9110 §5.6.7 obliges recipients to also accept the obsolete rfc850
    /// and asctime date forms (proxies/CDNs in front of BYO endpoints emit
    /// them) — an unparsed form silently reverts to the doomed blind retry.
    func testRetryAfterParsesObsoleteHTTPDateForms() {
        let now = Date(timeIntervalSince1970: 1_445_412_480)  // 2015-10-21 07:28:00 GMT
        let rfc850 = "Wednesday, 21-Oct-15 07:28:10 GMT"
        XCTAssertEqual(TTSClient.retryAfterSeconds(from: rfc850, now: now) ?? -1, 10, accuracy: 0.001,
                       "rfc850 form must parse.")
        // asctime: no zone (read as GMT), single-digit days space-padded.
        let asctime = "Wed Oct 21 07:28:10 2015"
        XCTAssertEqual(TTSClient.retryAfterSeconds(from: asctime, now: now) ?? -1, 10, accuracy: 0.001,
                       "asctime form must parse.")
        let asctimePadded = "Thu Oct  1 07:28:00 2015"
        XCTAssertNotNil(TTSClient.retryAfterSeconds(from: asctimePadded, now: now),
                        "asctime's double-space day padding must not break the parse.")
    }

    // MARK: - Transport errors

    func testTimeoutMapsToRequestTimeout() async {
        MockURLProtocol.requestHandler = { _ in throw URLError(.timedOut) }
        do {
            _ = try await TTSClient.shared.synthesize(
                text: "x", provider: .openAITTS, voice: nil, apiKey: apiKey, session: session
            )
            XCTFail("Expected requestTimeout")
        } catch let e as AppError {
            XCTAssertEqual(e.errorCode, AppError.requestTimeout.errorCode)
        } catch {
            XCTFail("Expected AppError, got \(error)")
        }
    }

    func testNoConnectionMapsToNoInternet() async {
        MockURLProtocol.requestHandler = { _ in throw URLError(.notConnectedToInternet) }
        do {
            _ = try await TTSClient.shared.synthesize(
                text: "x", provider: .openAITTS, voice: nil, apiKey: apiKey, session: session
            )
            XCTFail("Expected noInternetConnection")
        } catch let e as AppError {
            XCTAssertEqual(e.errorCode, AppError.noInternetConnection.errorCode)
        } catch {
            XCTFail("Expected AppError, got \(error)")
        }
    }

    func testAppleSentinelThrowsSynthesisFailed() async {
        // The Apple sentinel has a nil bodyFactory — it must never reach a real
        // request; surfacing a terminal error lets the playback layer fall back.
        MockURLProtocol.requestHandler = { req in self.ok(req, body: Data([0x01])) }
        do {
            _ = try await TTSClient.shared.synthesize(
                text: "x", provider: .appleTTS, voice: nil, apiKey: apiKey, session: session
            )
            XCTFail("Expected ttsSynthesisFailed for the Apple sentinel")
        } catch let e as AppError {
            XCTAssertEqual(e.errorCode, AppError.ttsSynthesisFailed.errorCode)
        } catch {
            XCTFail("Expected AppError, got \(error)")
        }
    }

    // MARK: - Helpers

    /// URLProtocol surfaces request bodies via `httpBodyStream` when URLSession
    /// upgrades `httpBody` to a stream. Reads to EOF. (Mirrors the helper in
    /// `RemoteAgentClientTests`.)
    private static func readStreamBody(_ request: URLRequest) -> Data? {
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 4096
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: bufferSize)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}
