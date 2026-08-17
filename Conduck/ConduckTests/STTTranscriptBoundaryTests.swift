// SPDX-License-Identifier: Apache-2.0

// Conduck
// STTTranscriptBoundaryTests.swift
//
// Pins the speech-to-text transcript boundary: a transcript from a
// user-configured BYO endpoint is untrusted remote text, and it reaches the
// composer, the persisted conversation, and the outbound wire. It must be
// well-formed by the time any of them sees it, and it must be made well-formed
// ONCE, at a point every provider passes through.
//
// The boundary is `STTResponse.init` (see `STTTranscript`), not a decoder:
// JSON-family providers bypass `STTResponseDecoder` entirely, and the
// in-process Apple route bypasses the whole network path — `InAppAudioRecorder`
// and `AppleSpeechRelayCoordinator` call `AppleSpeechRunner` directly, without
// going through `STTClient`. So these tests exercise EVERY provider family and
// then guard, against the sources, that no second definition of the boundary
// exists to drift from this one.
//
// Policy under test: NORMALIZE, NEVER REJECT. The user spoke words, not
// formatting scalars, so removing the non-spoken ones is a faithful rendering
// of the utterance; throwing the turn away over them would discard something
// the user actually said. Rejection is the identity-field policy
// (`PairingPayload.sanitizedDisplayText`), not the content policy.

import XCTest
@testable import Conduck

final class STTTranscriptBoundaryTests: XCTestCase {

    // MARK: - Fixtures

    /// RIGHT-TO-LEFT OVERRIDE: renders everything after it reversed, so a
    /// transcript can display as words the user never said.
    private let rightToLeftOverride = "\u{202E}"
    /// POP DIRECTIONAL FORMATTING — the terminator an override relies on.
    private let popDirectionalFormatting = "\u{202C}"
    /// FIRST STRONG ISOLATE, from the isolate family.
    private let firstStrongIsolate = "\u{2068}"
    /// LEFT-TO-RIGHT MARK.
    private let leftToRightMark = "\u{200E}"
    /// ESC — opens an ANSI escape sequence.
    private let escape = "\u{001B}"
    /// BEL.
    private let bell = "\u{0007}"
    /// DEL.
    private let delete = "\u{007F}"
    /// C1 control (the 8-bit form of the C0 set).
    private let c1Control = "\u{0085}"

    /// A hostile transcript that still carries a real utterance. Every route
    /// below is fed this exact string, and every route must yield `spokenWords`.
    ///
    /// Only the CONTROL scalars are hostile here, never printable payload: an
    /// ANSI sequence's `[31m` parameter bytes are ordinary characters, and the
    /// boundary is not in the business of guessing which printable runs the
    /// user did not say.
    private var hostileTranscript: String {
        "\(rightToLeftOverride)\(escape) book \(bell)the\(c1Control) flight\(delete)\(popDirectionalFormatting)"
    }

    /// What the user actually said, and the only thing any surface may show,
    /// store, or send.
    private let spokenWords = "book the flight"

    // MARK: - Network family: multipart (Mistral · OpenAI · ElevenLabs · BYO custom)

    // The BYO custom OpenAI-compatible endpoint — the untrusted surface this
    // whole boundary exists for — rides `.multipart` + the `openAICompat`
    // shape, so this is the primary threat route.

    func testMultipartOpenAICompatTranscriptIsNormalizedAtTheBoundary() throws {
        let body = try Self.jsonBody(["text": hostileTranscript, "language": "en"])
        let response = try STTResponseDecoder.decode(body, shape: .openAICompat)

        XCTAssertEqual(response.text, spokenWords,
                       "A multipart-family transcript must reach the caller normalized.")
        XCTAssertEqual(response.language, "en",
                       "Normalization touches the transcript only — the language echo is metadata.")
    }

    func testMultipartElevenLabsTranscriptIsNormalizedAtTheBoundary() throws {
        let body = try Self.jsonBody(["text": hostileTranscript, "language_code": "eng"])
        let response = try STTResponseDecoder.decode(body, shape: .elevenLabs)

        XCTAssertEqual(response.text, spokenWords)
        XCTAssertEqual(response.language, "eng")
    }

    // MARK: - Network family: JSON (these BYPASS `STTResponseDecoder`)

    func testOpenRouterJSONTranscriptIsNormalizedAtTheBoundary() throws {
        let body = try Self.jsonBody(["text": hostileTranscript])
        let response = try OpenRouterSTT.decodeResponse(body)

        XCTAssertEqual(response.text, spokenWords,
                       "OpenRouter never touches STTResponseDecoder — it must still be normalized.")
    }

    func testGeminiJSONTranscriptIsNormalizedAtTheBoundary() throws {
        let body = try Self.jsonBody([
            "candidates": [["content": ["parts": [["text": hostileTranscript]]]]]
        ])
        let response = try GeminiSTT.decodeResponse(body)

        XCTAssertEqual(response.text, spokenWords)
    }

    func testQwenJSONTranscriptIsNormalizedAtTheBoundary() throws {
        let body = try Self.jsonBody([
            "output": ["choices": [["message": ["content": [["text": hostileTranscript]]]]]]
        ])
        let response = try QwenSTT.decodeResponse(body)

        XCTAssertEqual(response.text, spokenWords)
    }

    // MARK: - In-process family (Apple on-device)

    // The `.inProcess` route returns before the network path exists: no HTTP
    // response, no decoder, no status map. `STTClient.transcribe` hands the
    // audio to `provider.inProcessRunner` and returns whatever it builds, and
    // `InAppAudioRecorder` / `AppleSpeechRelayCoordinator` call the runner
    // DIRECTLY, without `STTClient` at all. The runner below stands in for
    // `AppleSpeechRunner` (which cannot run in a unit test — it needs the
    // Speech framework, an installed model, and real audio) and makes the same
    // `STTResponse` construction the real one makes.

    func testInProcessTranscriptIsNormalizedAtTheSameBoundary() async throws {
        let runner: STTInProcessRunner.Type = HostileInProcessRunner.self
        let response = try await runner.transcribe(
            audioFileURL: URL(fileURLWithPath: "/dev/null"),
            language: "en"
        )

        XCTAssertEqual(response.text, spokenWords,
                       "The in-process route bypasses every decoder — the type is what covers it.")
        XCTAssertEqual(response.language, "en")
    }

    func testAppleOnDeviceProviderStaysOnTheInProcessTransport() {
        // If this provider ever gained a network transport, the in-process
        // coverage above would stop describing the shipping Apple route.
        XCTAssertEqual(STTProvider.appleOnDevice.transport, .inProcess)
    }

    // MARK: - The boundary is the type

    func testConstructingAResponseNormalizesRegardlessOfRoute() {
        // Composer, `ConversationStore` and the outbound `ConverseRequest` all
        // read `STTResponse.text` and nothing else — there is no accessor for
        // the raw string, so this is what all three receive.
        let response = STTResponse(text: hostileTranscript, language: nil)

        XCTAssertEqual(response.text, spokenWords)
        XCTAssertFalse(response.text.unicodeScalars.contains { Self.isHostileScalar($0) },
                       "No hostile scalar may survive into stored or sent text.")
    }

    func testEveryRouteYieldsByteIdenticalText() throws {
        // Uniformity, stated directly: the same wire transcript decoded through
        // four different provider families produces the same string. A route
        // that normalized differently — or not at all — breaks here.
        let multipart = try STTResponseDecoder.decode(
            Self.jsonBody(["text": hostileTranscript]), shape: .openAICompat
        ).text
        let elevenLabs = try STTResponseDecoder.decode(
            Self.jsonBody(["text": hostileTranscript]), shape: .elevenLabs
        ).text
        let openRouter = try OpenRouterSTT.decodeResponse(
            Self.jsonBody(["text": hostileTranscript])
        ).text
        let gemini = try GeminiSTT.decodeResponse(
            Self.jsonBody(["candidates": [["content": ["parts": [["text": hostileTranscript]]]]]])
        ).text
        let inProcess = STTResponse(text: hostileTranscript, language: nil).text

        XCTAssertEqual(multipart, elevenLabs)
        XCTAssertEqual(multipart, openRouter)
        XCTAssertEqual(multipart, gemini)
        XCTAssertEqual(multipart, inProcess)
    }

    // MARK: - Right-to-left script is content, not formatting

    func testRightToLeftTranscriptsSurviveCharacterForCharacter() {
        // Stripping the SCRIPT instead of the explicit formatting controls would
        // render these languages as mojibake — a far worse outcome than the
        // spoof the strip exists to prevent.
        let transcripts = [
            "مرحبا بالعالم",                       // Arabic
            "שלום עולם",                            // Hebrew
            "سلام دنیا",                            // Persian
            "ہیلو دنیا",                            // Urdu
            "احجز الرحلة من فضلك"                   // Arabic, a real dictated sentence
        ]

        for transcript in transcripts {
            XCTAssertEqual(STTTranscript.normalized(transcript), transcript,
                           "RTL script must pass through untouched: \(transcript)")
            XCTAssertEqual(STTResponse(text: transcript, language: "ar").text, transcript)
        }
    }

    func testBidiControlsAreRemovedWithoutDisturbingTheRTLTextAroundThem() {
        let arabic = "مرحبا بالعالم"
        let spoofed = "\(rightToLeftOverride)\(arabic)\(popDirectionalFormatting)"

        XCTAssertEqual(STTTranscript.normalized(spoofed), arabic,
                       "The override goes; the Arabic stays.")
    }

    // MARK: - Normalization never empties a legitimate transcript

    func testLegitimateTranscriptsAreNeverEmptied() {
        let transcripts = [
            "book the flight",
            "Buche bitte den Flug für übermorgen.",
            "予約をお願いします",
            "мне нужен билет",
            "مرحبا",
            "3 tickets, seats 14A and 14B — window if possible",
            "call mum 👋",
            "\t  indented dictation  \n"
        ]

        for transcript in transcripts {
            let normalized = STTTranscript.normalized(transcript)
            XCTAssertFalse(normalized.isEmpty,
                           "Normalization emptied a legitimate transcript: \(transcript)")
        }
    }

    func testNormalizationKeepsEveryNonWhitespaceCharacter() {
        let transcript = "Buche bitte den Flug für übermorgen — 3 Sitze, 14A/14B. 予約 👋"
        let normalized = STTTranscript.normalized(transcript)

        let kept = normalized.filter { !$0.isWhitespace }
        let original = transcript.filter { !$0.isWhitespace }
        XCTAssertEqual(kept, original,
                       "Only whitespace may be reshaped — never a spoken character, never emoji.")
    }

    func testBreaksBecomeSpacesSoWordsAreNeverFused() {
        // A deleted break would run the words either side together and change
        // what the user is recorded as having said.
        XCTAssertEqual(STTTranscript.normalized("book the\nflight"), "book the flight")
        XCTAssertEqual(STTTranscript.normalized("book the\r\nflight"), "book the flight")
        XCTAssertEqual(STTTranscript.normalized("book the\tflight"), "book the flight")
        XCTAssertEqual(STTTranscript.normalized("book the\u{2028}flight"), "book the flight")
        XCTAssertEqual(STTTranscript.normalized("book the\u{2029}flight"), "book the flight")
    }

    func testRemovedScalarsNeverInventAWordBoundary() {
        // The opposite failure: a deleted control must NOT become a space, or a
        // provider could split one word into two in the user's own turn.
        XCTAssertEqual(STTTranscript.normalized("fli\(rightToLeftOverride)ght"), "flight")
        XCTAssertEqual(STTTranscript.normalized("fli\(bell)ght"), "flight")
        XCTAssertEqual(STTTranscript.normalized("fli\(leftToRightMark)ght"), "flight")
        XCTAssertEqual(STTTranscript.normalized("fli\(firstStrongIsolate)ght"), "flight")
    }

    func testWhitespaceRunsCollapseAndBothEndsAreTrimmed() {
        XCTAssertEqual(STTTranscript.normalized("   book    the     flight   "), "book the flight")
        XCTAssertEqual(STTTranscript.normalized("\n\n book \n\n the \n\n"), "book the")
    }

    func testNormalizationIsIdempotent() {
        let once = STTTranscript.normalized(hostileTranscript)
        XCTAssertEqual(STTTranscript.normalized(once), once,
                       "A transcript crossing the boundary twice must not degrade.")
    }

    // MARK: - The transcript is never truncated

    func testALongTranscriptIsNotTruncated() {
        // The transcript is the user's own words and it goes on the wire, so
        // the boundary is uncapped. Capping belongs to the LABEL surfaces,
        // which project their own render.
        let word = "flight "
        let repeats = 20_000
        let long = String(repeating: word, count: repeats)

        let normalized = STTTranscript.normalized(long)

        // One trailing space is trimmed; every word survives.
        XCTAssertEqual(normalized.count, word.count * repeats - 1)
        XCTAssertTrue(normalized.hasSuffix("flight"))
    }

    // MARK: - Empty after normalization is "no speech", never a blank turn

    func testAControlOnlyTranscriptSurfacesNoSpeechRatherThanABlankTurn() throws {
        // Non-empty on the wire, empty after the projection. Read raw, this
        // sails past the emptiness guards and lands as a blank user turn that
        // gets auto-dispatched from CarPlay or the wrist.
        let controlOnly = "\(rightToLeftOverride)\(escape)\(bell)\(delete)\(c1Control)"
        let body = try Self.jsonBody(["text": controlOnly])

        for shape in [STTResponseShape.openAICompat, .elevenLabs] {
            XCTAssertThrowsError(try STTResponseDecoder.decode(body, shape: shape)) { error in
                guard let appError = error as? AppError, case .noSpeechDetected = appError else {
                    return XCTFail("Expected .noSpeechDetected for shape \(shape), got \(error)")
                }
            }
        }

        XCTAssertThrowsError(try OpenRouterSTT.decodeResponse(body)) { error in
            guard let appError = error as? AppError, case .noSpeechDetected = appError else {
                return XCTFail("Expected .noSpeechDetected, got \(error)")
            }
        }

        let geminiBody = try Self.jsonBody([
            "candidates": [["content": ["parts": [["text": controlOnly]]]]]
        ])
        XCTAssertThrowsError(try GeminiSTT.decodeResponse(geminiBody)) { error in
            guard let appError = error as? AppError, case .noSpeechDetected = appError else {
                return XCTFail("Expected .noSpeechDetected, got \(error)")
            }
        }
    }

    func testWhitespaceOnlyTranscriptStillSurfacesNoSpeech() throws {
        // The pre-existing verdict, re-pinned: moving the guard onto the
        // normalized text must not weaken it.
        let body = try Self.jsonBody(["text": " \n\t "])
        XCTAssertThrowsError(try STTResponseDecoder.decode(body, shape: .openAICompat)) { error in
            guard let appError = error as? AppError, case .noSpeechDetected = appError else {
                return XCTFail("Expected .noSpeechDetected, got \(error)")
            }
        }
    }

    func testTheFallbackIsEmptySoNoAppOwnedTextEnterAUserTurn() {
        // `ReplySanitizer.displayLine` returns its fallback VERBATIM. A
        // placeholder here would be words the user never spoke, sent to the
        // agent as their own turn.
        XCTAssertEqual(STTTranscript.normalized(rightToLeftOverride), "")
        XCTAssertEqual(STTTranscript.normalized(""), "")
    }

    // MARK: - Source drift guard: exactly one rule, in exactly two definitions

    // `STTResponse` is declared twice — once for the phone/Mac targets and once
    // for the Watch target, which cannot link `STTClient.swift`. This test
    // target links only the former, so the Watch definition can only be pinned
    // against the source. Both must delegate to `STTTranscript`, and no THIRD
    // definition may appear: a struct with the same name and no normalization
    // would be a silent hole on whichever target compiled it.

    func testEverySTTResponseDefinitionNormalizesThroughTheOneBoundary() throws {
        let container = projectContainerURL()
        guard let enumerator = FileManager.default.enumerator(
            at: container,
            includingPropertiesForKeys: nil
        ) else {
            throw XCTSkip("Source tree unreadable at \(container.path) — checkout-only guard.")
        }

        var definingFiles: [String] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            // Production sources only. A test double is free to declare
            // whatever it likes — it ships to nobody — and this file itself
            // carries the search token in a literal.
            guard !url.pathComponents.contains(where: { $0.hasSuffix("Tests") }) else { continue }
            guard let raw = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let code = strippingComments(raw)
            guard code.contains("struct STTResponse") else { continue }

            let relative = url.path.replacingOccurrences(of: container.path + "/", with: "")
            definingFiles.append(relative)
            XCTAssertTrue(
                code.contains("STTTranscript.normalized("),
                """
                \(relative) declares an `STTResponse` that does not route its text through \
                `STTTranscript.normalized`. Every provider result — network, JSON-family and \
                in-process — is constructed through this type, and that construction is the only \
                point that covers all of them. A definition without it silently ships raw remote \
                text to the composer, the conversation store and the wire.
                """
            )
        }

        guard !definingFiles.isEmpty else {
            throw XCTSkip("No `STTResponse` declaration found under \(container.path) — checkout-only guard.")
        }
        XCTAssertEqual(
            definingFiles.sorted(),
            [
                "Conduck/Services/STTClient.swift",
                "ConduckWatch Watch App/Services/WatchNetworkClient.swift"
            ],
            "A new `STTResponse` definition appeared. Add it to this list only after it normalizes."
        )
    }

    // MARK: - Helpers

    /// `.../Conduck/Conduck` — the project container holding every target's sources.
    private func projectContainerURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // .../ConduckTests
            .deletingLastPathComponent()   // .../Conduck/Conduck
    }

    /// Drops `//`-to-end-of-line so the prose explaining the boundary is never
    /// read as the boundary itself.
    private func strippingComments(_ source: String) -> String {
        source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> Substring in
                guard let marker = line.range(of: "//") else { return line }
                return line[line.startIndex..<marker.lowerBound]
            }
            .joined(separator: "\n")
    }

    /// Encode a provider response body. Built through `JSONSerialization` so the
    /// hostile scalars are escaped exactly the way a real server would escape
    /// them, rather than by hand-splicing them into a JSON string literal.
    private static func jsonBody(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object)
    }

    /// Independent restatement of the denylist, so the assertion is not the
    /// code under test grading itself.
    private static func isHostileScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x00...0x08, 0x0B, 0x0C, 0x0E...0x1F, 0x7F, 0x80...0x9F:
            return true
        case 0x200E, 0x200F, 0x202A...0x202E, 0x2066...0x2069:
            return true
        case 0x09, 0x0A, 0x0D, 0x2028, 0x2029:
            return true   // breaks: mapped to a space, so none may survive either
        default:
            return false
        }
    }
}

/// Stands in for `AppleSpeechRunner` on the `.inProcess` route, which no unit
/// test can drive (Speech framework, an installed model, real audio). It makes
/// the SAME `STTResponse(text:language:)` construction the real runner makes,
/// which is the whole point: the boundary is the type, so a runner gets it for
/// free without knowing the rule exists.
private enum HostileInProcessRunner: STTInProcessRunner {
    /// A transcript the way a compromised or simply sloppy engine could emit it.
    nonisolated static let rawTranscript =
        "\u{202E}\u{001B} book \u{0007}the\u{0085} flight\u{007F}\u{202C}"

    nonisolated static func transcribe(audioFileURL: URL, language: String?) async throws -> STTResponse {
        STTResponse(text: rawTranscript, language: language)
    }
}
