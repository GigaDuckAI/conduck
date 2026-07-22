// Conduck
// STTCustomModelTests.swift
//
// Custom-STT V1.x — Feature 1 (per-provider custom model override). Pure-data
// coverage of the two declarative resolution helpers on the `STTProvider` value
// type (`effectiveModel(customModel:)` / `effectiveTranscribeURL(customModel:)`),
// the multipart build path threading the override into the `model` field, and
// the `SettingsViewModel.sanitizeModelTag` allowlist (URL-path-injection guard).
//
// The Qwen JSON-body override + the Gemini URL-vs-body asymmetry live in the
// per-provider files (`Providers/QwenSTTProviderTests` / `GeminiSTTProviderTests`).
// No URLSession, no Keychain — every test is deterministic.

import XCTest
@testable import Conduck

final class STTCustomModelTests: XCTestCase {

    // MARK: - effectiveModel(customModel:)

    func testEffectiveModelNilOverrideReturnsDefault() {
        XCTAssertEqual(STTProvider.mistralVoxtral.effectiveModel(customModel: nil),
                       "voxtral-mini-2602",
                       "A nil override must fall back to the provider's pinned default model.")
    }

    func testEffectiveModelEmptyOverrideReturnsDefault() {
        XCTAssertEqual(STTProvider.mistralVoxtral.effectiveModel(customModel: ""),
                       "voxtral-mini-2602",
                       "An empty-string override must fall back to the pinned default.")
    }

    func testEffectiveModelWhitespaceOverrideReturnsDefault() {
        XCTAssertEqual(STTProvider.mistralVoxtral.effectiveModel(customModel: "   \n\t "),
                       "voxtral-mini-2602",
                       "A whitespace-only override must be treated as empty → pinned default.")
    }

    func testEffectiveModelCustomOverrideReturnsCustom() {
        XCTAssertEqual(STTProvider.mistralVoxtral.effectiveModel(customModel: "voxtral-mini-latest"),
                       "voxtral-mini-latest",
                       "A non-empty override must win over the pinned default.")
    }

    func testEffectiveModelTrimsSurroundingWhitespace() {
        XCTAssertEqual(STTProvider.openAITranscribe.effectiveModel(customModel: "  gpt-5o-transcribe  "),
                       "gpt-5o-transcribe",
                       "A surrounded override must be trimmed before use (no leading/trailing whitespace reaches the wire).")
    }

    func testEffectiveModelAppleSentinelUnchangedEvenWithOverride() {
        // Apple on-device is `.inProcess` — there is no network model to
        // override, and the sentinel `model` ("speechanalyzer") is never sent.
        // An override must be IGNORED.
        XCTAssertEqual(STTProvider.appleOnDevice.effectiveModel(customModel: "whatever-the-user-typed"),
                       "speechanalyzer",
                       "Apple on-device (.inProcess) must ALWAYS return its sentinel model unchanged — an override is meaningless on-device.")
    }

    func testEffectiveModelCustomProviderDefaultsToWhisper1() {
        XCTAssertEqual(STTProvider.customOpenAICompat.effectiveModel(customModel: nil),
                       "whisper-1",
                       "The BYO custom endpoint's pinned default model is `whisper-1`.")
        XCTAssertEqual(STTProvider.customOpenAICompat.effectiveModel(customModel: "faster-whisper-large-v3"),
                       "faster-whisper-large-v3",
                       "A custom-endpoint model override must win over the `whisper-1` default.")
    }

    // MARK: - effectiveTranscribeURL(customModel:) — Gemini

    func testEffectiveTranscribeURLGeminiOverrideContainsModelInPath() {
        let url = STTProvider.geminiFlashLite.effectiveTranscribeURL(customModel: "gemini-3.2-pro")
        XCTAssertTrue(url.absoluteString.contains("/models/gemini-3.2-pro:generateContent"),
                      "Gemini override must rebuild the URL to '/models/gemini-3.2-pro:generateContent'. Got: \(url.absoluteString)")
    }

    func testEffectiveTranscribeURLGeminiEmptyOverrideReturnsDefault() {
        let url = STTProvider.geminiFlashLite.effectiveTranscribeURL(customModel: "")
        XCTAssertEqual(url, STTProvider.geminiFlashLite.transcribeURL,
                       "An empty Gemini override must return the pinned default URL.")
    }

    func testEffectiveTranscribeURLGeminiNilOverrideReturnsDefault() {
        let url = STTProvider.geminiFlashLite.effectiveTranscribeURL(customModel: nil)
        XCTAssertEqual(url, STTProvider.geminiFlashLite.transcribeURL,
                       "A nil Gemini override must return the pinned default URL.")
    }

    // MARK: - effectiveTranscribeURL(customModel:) — non-Gemini

    func testEffectiveTranscribeURLNonGeminiOverrideUnchanged() {
        // Only Gemini's model lives in the URL path. For every other provider a
        // model override must NOT touch the URL (the override bites the body /
        // multipart `model` field instead).
        for provider in [STTProvider.mistralVoxtral,
                         STTProvider.openAITranscribe,
                         STTProvider.elevenLabsScribe,
                         STTProvider.qwenASRFlash,
                         STTProvider.customOpenAICompat] {
            let url = provider.effectiveTranscribeURL(customModel: "some-override")
            XCTAssertEqual(url, provider.transcribeURL,
                           "\(provider.id): a model override must NOT change the transcribe URL — only Gemini's model lives in the URL path.")
        }
    }

    // MARK: - geminiEndpoint(model:) single source of truth

    func testGeminiEndpointMatchesDefaultRegistryURL() {
        // The registry default URL is built via the SAME static helper the
        // override resolver uses — proving default + override can never drift.
        XCTAssertEqual(STTProvider.geminiEndpoint(model: "gemini-3.1-flash-lite"),
                       STTProvider.geminiFlashLite.transcribeURL,
                       "geminiEndpoint(model:) must reproduce the pinned default registry URL exactly (single source of truth).")
    }

    // MARK: - Multipart build carries the effective model

    /// The multipart build path takes an explicit `model:` arg — the call sites
    /// pass `provider.effectiveModel(customModel:)`. Feeding the resolved
    /// override here proves the override reaches the `model` form field.
    func testMultipartBuildCarriesOverrideModel() {
        let effModel = STTProvider.openAITranscribe.effectiveModel(customModel: "gpt-5o-transcribe")
        let (_, body) = STTMultipartBuilder.build(
            audioData: Data([0x00, 0x01, 0x02]),
            audioMIME: "audio/mp4",
            audioFilename: "audio.m4a",
            model: effModel,
            language: "en",
            fieldNames: .openAICompat
        )
        let text = String(data: body, encoding: .utf8) ?? ""
        XCTAssertTrue(text.contains("name=\"model\""),
                      "openAICompat multipart must carry a `model` field.")
        XCTAssertTrue(text.contains("gpt-5o-transcribe"),
                      "The OVERRIDE model tag must appear in the multipart body. Got body snippet without override.")
        XCTAssertFalse(text.contains("gpt-4o-transcribe"),
                       "The hardcoded default must NOT appear once the override is supplied.")
    }

    func testMultipartBuildCarriesDefaultModelWhenNoOverride() {
        let effModel = STTProvider.mistralVoxtral.effectiveModel(customModel: nil)
        let (_, body) = STTMultipartBuilder.build(
            audioData: Data([0x00, 0x01, 0x02]),
            audioMIME: "audio/mp4",
            audioFilename: "audio.m4a",
            model: effModel,
            language: nil,
            fieldNames: .openAICompat
        )
        let text = String(data: body, encoding: .utf8) ?? ""
        XCTAssertTrue(text.contains("voxtral-mini-2602"),
                      "With no override, the pinned default model tag must appear in the multipart body.")
    }

    // MARK: - sanitizeModelTag (^[A-Za-z0-9._-]+$ allowlist)

    func testSanitizeModelTagRejectsSlash() {
        // A `/` would let a Gemini override inject extra URL path segments
        // (the model lives in the URL path there). Must be stripped. Note `.`
        // is INSIDE the allowlist (`whisper-1.large` is a legit tag), so only
        // the slashes are removed here — the `..` survive as literal dots.
        XCTAssertEqual(SettingsViewModel.sanitizeModelTag("../../v1beta/models/evil"),
                       "....v1betamodelsevil",
                       "Every `/` must be stripped (no URL-path injection); allowlisted `.` chars survive.")
        XCTAssertFalse(SettingsViewModel.sanitizeModelTag("gpt/4o").contains("/"),
                       "A `/` must never survive sanitization.")
        XCTAssertEqual(SettingsViewModel.sanitizeModelTag("gpt/4o"), "gpt4o",
                       "The slash is removed, the rest concatenates.")
    }

    func testSanitizeModelTagRejectsQuestionMark() {
        // A `?` would let an override append a query string to the Gemini URL.
        let sanitized = SettingsViewModel.sanitizeModelTag("model?key=leak")
        XCTAssertFalse(sanitized.contains("?"),
                       "A `?` must be stripped — no query-string injection on the Gemini URL.")
        XCTAssertFalse(sanitized.contains("="),
                       "An `=` must be stripped too (it's outside the allowlist).")
        XCTAssertEqual(sanitized, "modelkeyleak")
    }

    func testSanitizeModelTagKeepsAllowedChars() {
        XCTAssertEqual(SettingsViewModel.sanitizeModelTag("gpt-4o.transcribe_v2-latest"),
                       "gpt-4o.transcribe_v2-latest",
                       "Letters, digits, `.`, `_`, `-` are all inside the allowlist and must survive.")
    }

    func testSanitizeModelTagTrimsAndEmptiesToClear() {
        XCTAssertEqual(SettingsViewModel.sanitizeModelTag("   "), "",
                       "Whitespace-only input must sanitize to empty (= clear the override).")
        XCTAssertEqual(SettingsViewModel.sanitizeModelTag("  whisper-1  "), "whisper-1",
                       "Surrounding whitespace must be trimmed.")
    }
}
