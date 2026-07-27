// SPDX-License-Identifier: Apache-2.0

// Conduck
// CustomSTTEndpointTests.swift
//
// Custom-STT V1.x — Feature 2 (BYO OpenAI-compatible STT endpoint). Covers the
// pieces that are deterministic without a live server:
//   • AppError 34/35 numeric round-trip + non-retryable taxonomy.
//   • Endpoint resolution — base URL → `/v1/audio/transcriptions`, with/without
//     a trailing slash; unset → nil (the precondition for the typed
//     `sttCustomEndpointNotConfigured` throw).
//   • The unset-URL path actually throws `sttCustomEndpointNotConfigured` from
//     `STTClient.transcribe` BEFORE any network round-trip.
//   • The "trust-evaluator-only-for-custom" declarative invariant: only the
//     custom provider carries `dynamicEndpointKey != nil`, so only it selects a
//     pinning session — every cloud provider stays on `URLSession.shared`.
//
// The full staged Test suite (request shape, `.openAICompat` decode, TOFU, pin
// mismatch) is covered in `STTConnectionTestSuiteTests` via the MockURLProtocol
// seam. The live custom-server round-trip + iCloud-Keychain sync of the custom
// key are signed/hardware founder gates.
//
// App-Group UserDefaults writes are unsigned-safe; the API-key Keychain write
// is NOT exercised here (it needs the access-group entitlement → signed gate),
// so these tests never touch the `stt.apiKey.custom-openai` slot.

import XCTest
@testable import Conduck

final class CustomSTTEndpointTests: XCTestCase {

    /// App Groups UserDefaults — same suite `SettingsManager` uses internally.
    private let defaults: UserDefaults = {
        UserDefaults(suiteName: Constants.appGroupID) ?? UserDefaults.standard
    }()

    override func setUp() async throws {
        try await super.setUp()
        await wipeCustomSTTState()
    }

    override func tearDown() async throws {
        await wipeCustomSTTState()
        try await super.tearDown()
    }

    /// Wipe the non-secret custom-STT slots so each test starts clean — and so
    /// this suite does not LEAK into others. `setCustomSTTURL` dual-writes
    /// App-Group defaults AND iCloud KVS, so a defaults-only wipe leaves stale
    /// KVS values (and a possibly-triggered migration flag) that contaminate the
    /// order-sensitive migration suite (spec.md Testing Seams & Isolation). Clear BOTH stores.
    /// (The Keychain key slot is never written here — see the file header.)
    private func wipeCustomSTTState() async {
        let kvs = NSUbiquitousKeyValueStore.default
        for key in [
            Constants.customSTTURLKey,
            Constants.customSTTModelKey,
            Constants.customSTTCertFingerprintKey,
            Constants.customSTTAuthSchemeKey,
            Constants.customTTSModelKey,
            Constants.customVoiceEndpointMigratedKey,
            Constants.customVoiceEndpointsRegistryKey,
        ] {
            defaults.removeObject(forKey: key)
            kvs.removeObject(forKey: key)
        }
        await SettingsManager.shared.resetCustomVoiceEndpointMigrationLatchForTesting()
    }

    // MARK: - Custom TTS endpoint (shares the STT base URL + key + cert + auth)

    func testTTSCustomEndpointNotConfiguredErrorCodeIs42() {
        XCTAssertEqual(AppError.ttsCustomEndpointNotConfigured.errorCode, 42,
                       "Code 42 is reserved for .ttsCustomEndpointNotConfigured.")
    }

    func testTTSCustomCertMismatchErrorCodeIs43() {
        XCTAssertEqual(AppError.ttsCustomCertMismatch.errorCode, 43,
                       "Code 43 is reserved for .ttsCustomCertMismatch.")
    }

    func testTTSCustomEndpointCodes42And43RoundTrip() {
        for code in [42, 43] {
            let err = AppError.from(errorCode: code, message: "test")
            XCTAssertEqual(err.errorCode, code,
                           "Custom-TTS code \(code) must round-trip via from(errorCode:); got \(err.errorCode)")
        }
        if case .ttsCustomEndpointNotConfigured = AppError.from(errorCode: 42, message: nil) {} else {
            XCTFail("Code 42 must resolve to .ttsCustomEndpointNotConfigured")
        }
        if case .ttsCustomCertMismatch = AppError.from(errorCode: 43, message: nil) {} else {
            XCTFail("Code 43 must resolve to .ttsCustomCertMismatch")
        }
    }

    func testTTSCustomEndpointCodesAreNotRetryable() {
        XCTAssertFalse(AppError.ttsCustomEndpointNotConfigured.isRetryable,
                       ".ttsCustomEndpointNotConfigured must NOT auto-retry — the user must set a URL.")
        XCTAssertFalse(AppError.ttsCustomCertMismatch.isRetryable,
                       ".ttsCustomCertMismatch must NOT auto-retry — a cert change away from the pin is a hard stop.")
    }

    /// TTS appends `/v1/audio/speech` onto the SAME base URL custom STT uses
    /// (one server, both directions). Trailing-slash tolerant.
    func testTTSSpeechURLAppendsPathOntoSharedBase() async {
        await SettingsManager.shared.setCustomSTTURL(URL(string: "https://voice.example.test:8880")!)
        let speech = await SettingsManager.shared.customTTSSpeechURL()
        XCTAssertEqual(speech?.absoluteString,
                       "https://voice.example.test:8880/v1/audio/speech",
                       "customTTSSpeechURL() must append /v1/audio/speech onto the shared custom-STT base.")
        // And the STT URL still resolves off the same base — proving they share it.
        let transcribe = await SettingsManager.shared.customSTTTranscribeURL()
        XCTAssertEqual(transcribe?.absoluteString,
                       "https://voice.example.test:8880/v1/audio/transcriptions",
                       "The STT and TTS URLs must derive from the SAME stored base.")
    }

    func testTTSSpeechURLTrailingSlashNoDoubleSlash() async {
        await SettingsManager.shared.setCustomSTTURL(URL(string: "https://voice.example.test/")!)
        let speech = await SettingsManager.shared.customTTSSpeechURL()
        XCTAssertEqual(speech?.absoluteString,
                       "https://voice.example.test/v1/audio/speech",
                       "A trailing slash on the base must not double-slash the TTS path.")
    }

    func testTTSSpeechURLNilWhenUnset() async {
        let speech = await SettingsManager.shared.customTTSSpeechURL()
        XCTAssertNil(speech,
                     "With no base URL stored, customTTSSpeechURL() must be nil (drives ttsCustomEndpointNotConfigured).")
    }

    func testCustomTTSModelDefaultsToTTS1() async {
        let model = await SettingsManager.shared.getCustomTTSModel()
        XCTAssertEqual(model, "tts-1", "Unset custom TTS model must default to tts-1.")
    }

    func testCustomTTSModelRoundTrips() async {
        await SettingsManager.shared.setCustomTTSModel("kokoro")
        let model = await SettingsManager.shared.getCustomTTSModel()
        XCTAssertEqual(model, "kokoro")
        // Empty clears back to the default.
        await SettingsManager.shared.setCustomTTSModel("")
        let cleared = await SettingsManager.shared.getCustomTTSModel()
        XCTAssertEqual(cleared, "tts-1", "Empty custom TTS model clears to the tts-1 default.")
    }

    /// `customTTSConfig()` assembles URL (TTS path) + model (TTS-specific) +
    /// auth + cert pin SHARED with the STT side in one hop.
    func testCustomTTSConfigResolvesSharedFieldsPlusTTSModel() async {
        await SettingsManager.shared.setCustomSTTURL(URL(string: "https://voice.example.test")!)
        await SettingsManager.shared.setCustomSTTAuthScheme(.none)
        await SettingsManager.shared.setCustomSTTCertFingerprint("ab12cd")
        await SettingsManager.shared.setCustomTTSModel("my-tts")

        let config = await SettingsManager.shared.customTTSConfig()
        XCTAssertEqual(config.url?.absoluteString, "https://voice.example.test/v1/audio/speech",
                       "Config URL must be the TTS synthesis URL.")
        XCTAssertEqual(config.model, "my-tts", "Config model must be the TTS-specific override.")
        XCTAssertEqual(config.auth, .none, "Config auth must be the SHARED custom-STT scheme.")
        XCTAssertEqual(config.certFingerprint, "ab12cd", "Config pin must be the SHARED custom-STT fingerprint.")
    }

    // MARK: - AppError 34 / 35 — numeric round-trip + taxonomy

    func testCustomEndpointNotConfiguredErrorCodeIs34() {
        XCTAssertEqual(AppError.sttCustomEndpointNotConfigured.errorCode, 34,
                       "Code 34 is reserved for .sttCustomEndpointNotConfigured. Renumbering breaks the Watch-relay wire decoder.")
    }

    func testCustomCertMismatchErrorCodeIs35() {
        XCTAssertEqual(AppError.sttCustomCertMismatch.errorCode, 35,
                       "Code 35 is reserved for .sttCustomCertMismatch.")
    }

    func testCustomEndpointCodes34And35RoundTrip() {
        // Same Watch-relay-wire contract as the other STT / remote-agent codes:
        // the numeric code must reconstruct its exact case via from(errorCode:).
        for code in [34, 35] {
            let err = AppError.from(errorCode: code, message: "test")
            XCTAssertEqual(err.errorCode, code,
                           "Custom-STT code \(code) must round-trip via from(errorCode:); got \(err.errorCode)")
        }
        if case .sttCustomEndpointNotConfigured = AppError.from(errorCode: 34, message: nil) {} else {
            XCTFail("Code 34 must resolve to .sttCustomEndpointNotConfigured")
        }
        if case .sttCustomCertMismatch = AppError.from(errorCode: 35, message: nil) {} else {
            XCTFail("Code 35 must resolve to .sttCustomCertMismatch")
        }
    }

    func testCustomEndpointCodesAreNotRetryable() {
        // A missing URL won't appear on a retry; a pinned-cert mismatch is a
        // hard security stop (auto-retry would defeat pinning). Both must
        // fast-fail the retry loop.
        XCTAssertFalse(AppError.sttCustomEndpointNotConfigured.isRetryable,
                       ".sttCustomEndpointNotConfigured must NOT auto-retry — the user must set a URL.")
        XCTAssertFalse(AppError.sttCustomCertMismatch.isRetryable,
                       ".sttCustomCertMismatch must NOT auto-retry — a cert change away from the pin is a hard stop.")
    }

    func testReservedCode27StillCollapsesToAPIFailure() {
        // 27 stays the reserved gap even after 34/35 were added — adding new
        // high codes must not accidentally resurrect the retired session-busy
        // case at 27.
        let resolved = AppError.from(errorCode: 27, message: "test")
        XCTAssertEqual(resolved.errorCode, AppError.apiFailure(message: "").errorCode,
                       "Reserved code 27 must still collapse to .apiFailure (it's a gap, not a live case).")
    }

    // MARK: - Endpoint resolution (path append, trailing-slash tolerant)

    func testTranscribeURLAppendsPathWithoutTrailingSlash() async {
        await SettingsManager.shared.setCustomSTTURL(URL(string: "https://whisper.example.test:9000")!)
        let resolved = await SettingsManager.shared.customSTTTranscribeURL()
        XCTAssertEqual(resolved?.absoluteString,
                       "https://whisper.example.test:9000/v1/audio/transcriptions",
                       "A base URL with no trailing slash must get `/v1/audio/transcriptions` appended cleanly.")
    }

    func testTranscribeURLAppendsPathWithTrailingSlash() async {
        await SettingsManager.shared.setCustomSTTURL(URL(string: "https://whisper.example.test:9000/")!)
        let resolved = await SettingsManager.shared.customSTTTranscribeURL()
        XCTAssertEqual(resolved?.absoluteString,
                       "https://whisper.example.test:9000/v1/audio/transcriptions",
                       "A base URL WITH a trailing slash must NOT double-slash — `URL.appending(path:)` collapses it.")
    }

    func testTranscribeURLAppendsPathOntoSubpathBase() async {
        // A user who runs Whisper behind a reverse-proxy subpath should still
        // get the OpenAI suffix appended onto their base.
        await SettingsManager.shared.setCustomSTTURL(URL(string: "https://host.example.test/whisper")!)
        let resolved = await SettingsManager.shared.customSTTTranscribeURL()
        XCTAssertEqual(resolved?.absoluteString,
                       "https://host.example.test/whisper/v1/audio/transcriptions",
                       "The OpenAI suffix must append onto a subpath base.")
    }

    func testTranscribeURLNilWhenUnset() async {
        // No base URL stored → nil. This is the precondition the transcribe path
        // turns into the typed `sttCustomEndpointNotConfigured` error.
        let resolved = await SettingsManager.shared.customSTTTranscribeURL()
        XCTAssertNil(resolved,
                     "With no base URL stored, customSTTTranscribeURL() must be nil (drives sttCustomEndpointNotConfigured).")
    }

    // MARK: - Unset URL → sttCustomEndpointNotConfigured (pre-network throw)

    /// When the custom provider is selected but no base URL is configured,
    /// `STTClient.transcribe` must throw `.sttCustomEndpointNotConfigured`
    /// BEFORE building any request — proven by passing a `CustomSTTConfig` whose
    /// `url` is nil and asserting the typed throw on a real (cap-sized) clip.
    func testTranscribeThrowsNotConfiguredWhenCustomURLMissing() async throws {
        // Write a small valid audio temp file so the byte/empty guards pass and
        // execution reaches the URL-resolution guard.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("custom-stt-noconfig-\(UUID().uuidString).m4a")
        // 256 non-empty bytes — under the 25 MB cap, non-empty. (The duration
        // guard is best-effort and skips on a non-decodable clip.)
        try Data(repeating: 0xAB, count: 256).write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let config = CustomSTTConfig(url: nil, model: "whisper-1", auth: .none, certFingerprint: nil)

        do {
            _ = try await STTClient.shared.transcribe(
                audioFileURL: tmp,
                apiKey: "",
                language: nil,
                provider: .customOpenAICompat,
                customModel: nil,
                customConfig: config
            )
            XCTFail("transcribe must throw when the custom endpoint has no URL — it returned a response instead.")
        } catch let error as AppError {
            guard case .sttCustomEndpointNotConfigured = error else {
                XCTFail("Expected .sttCustomEndpointNotConfigured, got \(error).")
                return
            }
        }
    }

    // MARK: - Trust-evaluator-only-for-custom (declarative invariant)

    /// The session-selection branch in `STTClient.transcribe` keys ENTIRELY off
    /// `provider.dynamicEndpointKey != nil`: nil → `URLSession.shared` (no
    /// delegate, default ATS); non-nil → a per-call pinning session with a
    /// `RemoteAgentTrustEvaluator`. There is no per-call session-injection seam,
    /// so we protect the dispatch INPUT instead — only the custom provider may
    /// ever select the pinning path. A regression that flipped a cloud
    /// provider's key would route it through the pin; this test forbids it.
    func testOnlyCustomProviderSelectsPinningSession() {
        for provider in STTProvider.allRegistered {
            if provider.id == "custom-openai" {
                XCTAssertNotNil(provider.dynamicEndpointKey,
                                "custom-openai MUST carry a dynamicEndpointKey — it is the only provider routed through the pinning session.")
            } else {
                XCTAssertNil(provider.dynamicEndpointKey,
                             "\(provider.id) must have dynamicEndpointKey == nil → it stays on URLSession.shared / no pinning delegate.")
            }
        }
    }

    /// A pin fingerprint only ever reaches a trust evaluator for the custom
    /// provider, because `customConfig` (which carries `certFingerprint`) is
    /// resolved ONLY for the dynamic-endpoint provider in `activeSTTSnapshot()`.
    /// The evaluator with no pin performs default ATS — proving a nil pin is a
    /// no-op (correct for Tailscale Funnel / Let's Encrypt custom servers).
    func testTrustEvaluatorWithNilPinIsConstructible() {
        // Constructing the evaluator the custom path uses with a nil pin must
        // not crash — nil pin → default ATS chain validation.
        let evaluator = RemoteAgentTrustEvaluator(pinnedFingerprintHex: nil)
        XCTAssertNil(evaluator.presentedFingerprintHex,
                     "A freshly-constructed evaluator has captured no leaf fingerprint yet.")
    }
}
