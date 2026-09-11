// SPDX-License-Identifier: Apache-2.0

// Conduck
// STTContainerDescriptionTests.swift
//
// One rule, on every STT upload lane: what a request CLAIMS its audio is must
// be read off the bytes it carries, never assumed.
//
// The pipeline is not M4A-only. `AudioCompressor` answers WAV whenever AAC
// encoding fails, passes a source container through untouched (CAF, from
// CarPlay's tap), and every retry lane re-uploads whatever it preserved. A
// hardcoded `audio/mp4` therefore mislabels exactly the recordings that
// already went wrong once, and the stricter providers refuse them — on every
// attempt at that capture, forever, which is a recording the user loses.
//
// Covered here: the two JSON-family body factories (`GeminiSTT` inline part,
// `QwenSTT` data-URI wrapper) and the BACKGROUND multipart lane, which streams
// from a file and so resolves its container from a short head rather than from
// the whole recording. The foreground multipart lane
// (`STTClient.multipartAudioPart(for:)`) is covered in `WorkboardVoiceLaneTests`.
//
// Ordinary AAC-in-MP4 must be described exactly as it always was — the M4A
// cases below are the regression guard on that, alongside the pinned wire
// expectations in `GeminiQwenSTTWireTests`.

import XCTest
@testable import Conduck

final class STTContainerDescriptionTests: XCTestCase {

    // MARK: - Fixtures (magic bytes only — `SourceAudioContainer.sniff` reads 12)

    /// ISO-BMFF: 4 size bytes, then the `ftyp` tag at 4..<8.
    private static let m4aBytes = Data([0x00, 0x00, 0x00, 0x18])
        + Data("ftypM4A ".utf8)
        + Data([0x00, 0x00, 0x00, 0x00])

    /// RIFF: "RIFF", 4 size bytes, "WAVE".
    private static let wavBytes = Data("RIFF".utf8)
        + Data([0x24, 0x00, 0x00, 0x00])
        + Data("WAVEfmt ".utf8)

    /// CoreAudio Format: "caff" at 0..<4.
    private static let cafBytes = Data("caff".utf8)
        + Data([0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])

    /// Neither — the sniff's `.m4a` fallback, which the recorders' dominant
    /// output makes the right default.
    private static let unrecognisedBytes = Data(repeating: 0xAB, count: 32)

    private func decodeBody(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: - Gemini (inline audio part)

    /// The inline part's `mime_type` follows the bytes, container by container.
    func testGeminiLabelsTheInlinePartWithTheContainerItIsSending() throws {
        let cases: [(Data, String)] = [
            (Self.m4aBytes, "audio/mp4"),
            (Self.wavBytes, "audio/wav"),
            (Self.cafBytes, "audio/x-caf"),
            (Self.unrecognisedBytes, "audio/mp4")
        ]

        for (audio, expected) in cases {
            let body = try GeminiSTT.buildRequestBody(audioData: audio,
                                                      language: nil,
                                                      model: STTProvider.gemini.model)
            let input = try XCTUnwrap(try decodeBody(body)["input"] as? [[String: Any]])
            let part = try XCTUnwrap(input.first { $0["type"] as? String == "audio" })
            XCTAssertEqual(part["mime_type"] as? String, expected,
                           "Gemini must describe the container it is actually sending.")
            XCTAssertEqual(part["data"] as? String, audio.base64EncodedString(),
                           "The label must travel with the very bytes it describes.")
        }
    }

    /// The WAV case is the one the finding is about: a compressed-to-WAV
    /// fallback labelled `audio/mp4` is refused by the endpoint, and the retry
    /// re-sends the same lie.
    func testGeminiNeverCallsWAVBytesAnM4APayload() throws {
        let body = try GeminiSTT.buildRequestBody(audioData: Self.wavBytes,
                                                  language: nil,
                                                  model: STTProvider.gemini.model)
        let raw = try XCTUnwrap(String(data: body, encoding: .utf8))
        XCTAssertFalse(raw.contains("audio\\/mp4"),
                       "A WAV payload must carry no MP4 claim anywhere in the body.")
    }

    /// Ordinary AAC-in-MP4 is described exactly as before: the same MIME, in
    /// the same key, with no other container name anywhere in the body.
    func testGeminiM4APayloadIsDescribedExactlyAsBefore() throws {
        let body = try GeminiSTT.buildRequestBody(audioData: Self.m4aBytes,
                                                  language: nil,
                                                  model: STTProvider.gemini.model)
        let raw = try XCTUnwrap(String(data: body, encoding: .utf8))
        // JSONEncoder escapes the solidus, hence `audio\/mp4`.
        XCTAssertTrue(raw.contains("\"mime_type\":\"audio\\/mp4\""),
                      "The M4A wire claim is unchanged, key and value both.")
        XCTAssertFalse(raw.contains("audio\\/wav"))
        XCTAssertFalse(raw.contains("audio\\/x-caf"))
    }

    // MARK: - Qwen (data-URI wrapper)

    /// The data URI's MIME follows the bytes. For M4A this asserts the WHOLE
    /// audio field byte for byte, which is the unchanged-behaviour lock.
    func testQwenWrapsTheDataURIWithTheContainerItIsSending() throws {
        let cases: [(Data, String)] = [
            (Self.m4aBytes, "audio/mp4"),
            (Self.wavBytes, "audio/wav"),
            (Self.cafBytes, "audio/x-caf"),
            (Self.unrecognisedBytes, "audio/mp4")
        ]

        for (audio, expected) in cases {
            let body = try QwenSTT.buildRequestBody(audioData: audio,
                                                    language: nil,
                                                    model: "qwen3-asr-flash")
            let input = try XCTUnwrap(try decodeBody(body)["input"] as? [String: Any])
            let messages = try XCTUnwrap(input["messages"] as? [[String: Any]])
            let content = try XCTUnwrap(messages[0]["content"] as? [[String: Any]])
            let uri = try XCTUnwrap(content[0]["audio"] as? String)
            XCTAssertEqual(uri, "data:\(expected);base64,\(audio.base64EncodedString())",
                           "DashScope reads the container off the data URI — it must be true.")
        }
    }

    // MARK: - Background multipart lane (streamed from a file)

    /// The background lane never loads the recording into memory, so it reads
    /// its container from a short head of the file — and must still reach the
    /// same answer the foreground lane reaches from the bytes themselves.
    func testTheBackgroundLaneDescribesTheFileItIsAboutToUpload() async throws {
        let cases: [(Data, String, String)] = [
            (Self.m4aBytes, "audio/mp4", "audio.m4a"),
            (Self.wavBytes, "audio/wav", "audio.wav"),
            (Self.cafBytes, "audio/x-caf", "audio.caf"),
            (Self.unrecognisedBytes, "audio/mp4", "audio.m4a")
        ]

        for (bytes, expectedMIME, expectedName) in cases {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("conduck-container-\(UUID().uuidString).bin")
            // A real recording is far longer than the head that is read; pad so
            // the test is not accidentally asserting on a 12-byte file.
            try (bytes + Data(repeating: 0x00, count: 4_096)).write(to: url, options: [.atomic])
            defer { try? FileManager.default.removeItem(at: url) }

            let part = await STTClient.backgroundAudioPart(forFileAt: url)
            XCTAssertEqual(part.mime, expectedMIME)
            XCTAssertEqual(part.filename, expectedName)

            // Identical to what the foreground lane answers for the same bytes:
            // one payload can never carry two descriptions.
            let foreground = await STTClient.multipartAudioPart(for: bytes)
            XCTAssertEqual(part.mime, foreground.mime)
            XCTAssertEqual(part.filename, foreground.filename)
        }
    }

    /// An unreadable path is the multipart builder's failure to report, not
    /// this helper's — it falls back to the sniff's own default rather than
    /// throwing a second, competing error.
    func testAMissingFileFallsBackToTheSniffDefaultRatherThanFailingHere() async {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("conduck-container-absent-\(UUID().uuidString).bin")
        let part = await STTClient.backgroundAudioPart(forFileAt: missing)
        XCTAssertEqual(part.mime, "audio/mp4")
        XCTAssertEqual(part.filename, "audio.m4a")
    }

    /// Call-site guard: the background upload must not reintroduce a fixed
    /// container claim. The Watch feeds this lane native AAC today, so a
    /// hardcoded pair passes every runtime test right up to the moment
    /// anything else feeds it — only the source settles it.
    func testTheBackgroundUploadHardcodesNoContainer() throws {
        let source = try Self.source("Conduck/Services/STTClient+Background.swift")
        let code = source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")

        XCTAssertFalse(code.contains("audioMIME: \"audio/mp4\""),
                       "The multipart part's MIME must come from the bytes, not a literal.")
        XCTAssertFalse(code.contains("audioFilename: \"audio.m4a\""),
                       "The multipart part's filename must come from the bytes, not a literal.")
        XCTAssertTrue(code.contains("backgroundAudioPart(forFileAt:"),
                      "The lane must resolve its container description before building the body.")
    }

    /// Call-site guard for the two JSON factories, for the same reason: a
    /// stored constant reads as harmless and is the exact defect.
    func testTheJSONProvidersHardcodeNoContainer() throws {
        for path in ["Conduck/Services/STT/Providers/GeminiSTTProvider.swift",
                     "Conduck/Services/STT/Providers/QwenSTTProvider.swift"] {
            let code = try Self.source(path)
                .split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("///") }
                .joined(separator: "\n")

            XCTAssertFalse(code.contains("= \"audio/mp4\""),
                           "\(path) must not store a fixed container claim.")
            XCTAssertTrue(code.contains("SourceAudioContainer.sniff(audioData)"),
                          "\(path) must read the container off the bytes it sends.")
        }
    }

    /// `.../Conduck` — the project container holding the app sources. Derived
    /// from this file's compile-time path so the source guards do not depend on
    /// the test runner's working directory.
    private static func source(_ relativePath: String) throws -> String {
        let container = URL(fileURLWithPath: #filePath)  // .../ConduckTests/<this>
            .deletingLastPathComponent()                 // .../ConduckTests
            .deletingLastPathComponent()                 // .../Conduck
        return try String(
            contentsOf: container.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }
}
