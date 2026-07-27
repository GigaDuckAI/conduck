// SPDX-License-Identifier: Apache-2.0

// Conduck
// AppErrorTests.swift
//
// First dedicated test file for `AppError`. Scoped to the new
// `.appleSpeechModelNotInstalled` case (code 18) — exhaustive coverage
// of legacy cases is deferred (existing taxonomy is covered indirectly
// by Shortcuts-end-to-end behavior).

import XCTest
@testable import Conduck

final class AppErrorTests: XCTestCase {

    // MARK: - Apple Speech model-not-installed (code 18)

    func testAppleSpeechModelNotInstalledErrorCodeIs18() {
        XCTAssertEqual(AppError.appleSpeechModelNotInstalled.errorCode, 18,
                       "Code 18 is reserved for Apple model-not-installed. Renumbering breaks Shortcuts users' saved error filters.")
    }

    func testAppleSpeechModelNotInstalledRoundTripFromNumericCode() {
        let resolved = AppError.from(errorCode: 18, message: nil)
        // AppError is not Equatable; compare via the stable errorCode.
        XCTAssertEqual(resolved.errorCode, 18,
                       "from(errorCode: 18, message:) must resolve to .appleSpeechModelNotInstalled.")
    }

    func testAppleSpeechModelNotInstalledIsNotRetryable() {
        // Model installation is a user-action (Settings → Download).
        // Auto-retry of the transcribe path won't summon the model —
        // surface a single banner + retry CTA in the UI.
        XCTAssertFalse(AppError.appleSpeechModelNotInstalled.isRetryable,
                       "Apple model-missing is user-actionable (download in Settings), not transport-transient. Must NOT retry.")
    }

    func testAppleSpeechModelNotInstalledHasUserFacingDescription() {
        let description = AppError.appleSpeechModelNotInstalled.errorDescription
        XCTAssertNotNil(description, "errorDescription must be non-nil — Shortcuts surfaces this as the failure banner.")
        XCTAssertTrue(description?.lowercased().contains("model") ?? false,
                      "errorDescription must mention 'model' so users can correlate with the Settings download row. Got: \(description ?? "nil")")
    }

    func testAppleSpeechModelNotInstalledRecoverySuggestionExists() {
        XCTAssertNotNil(AppError.appleSpeechModelNotInstalled.recoverySuggestion,
                        "recoverySuggestion must guide the user to the Settings download flow.")
    }

    // MARK: - Speech Recognition permission denied (code 51)
    //
    // Split out of `sttAuthFailed` (8): a TCC denial is fixed by a Settings
    // toggle, not a key re-paste, and the Watch relay decodes the numeric
    // slot — so 51 must round-trip exactly like 18 does.

    func testSpeechPermissionDeniedErrorCodeIs51() {
        XCTAssertEqual(AppError.speechPermissionDenied.errorCode, 51,
                       "Code 51 is reserved for Speech-Recognition-TCC-denied. Renumbering breaks the Watch relay wire decoder.")
    }

    func testSpeechPermissionDeniedRoundTripFromNumericCode() {
        let resolved = AppError.from(errorCode: 51, message: nil)
        // AppError is not Equatable; compare via the stable errorCode.
        XCTAssertEqual(resolved.errorCode, 51,
                       "from(errorCode: 51, message:) must resolve to .speechPermissionDenied.")
    }

    func testSpeechPermissionDeniedIsNotRetryable() {
        // Re-enabling Speech Recognition is a user action (Settings toggle).
        // Auto-retry can't flip TCC — surface a single banner + recovery.
        XCTAssertFalse(AppError.speechPermissionDenied.isRetryable,
                       "TCC-denied is user-actionable (Settings toggle), not transport-transient. Must NOT retry.")
    }

    func testSpeechPermissionDeniedHasUserFacingDescription() {
        XCTAssertNotNil(AppError.speechPermissionDenied.errorDescription,
                        "errorDescription must be non-nil — surfaced as the failure banner.")
    }

    func testSpeechPermissionDeniedRecoverySuggestionExists() {
        XCTAssertNotNil(AppError.speechPermissionDenied.recoverySuggestion,
                        "recoverySuggestion must point at Settings → Privacy & Security → Speech Recognition.")
    }

    // MARK: - Full numeric code round-trip
    //
    // Every code the `errorCode: Int` getter can emit must round-trip
    // through `from(errorCode:message:)`. The Watch's
    // `AppleSpeechRelayCoordinator.handleReply` is the sole decoder for
    // iPhone-side errors over the relay wire — a missing inverse mapping
    // collapses a user-visible failure into a blank banner. Cases with
    // un-reconstructible associated values (.networkError(Error),
    // .decodingError(Error), .unknown(Error)) intentionally fall through
    // to .apiFailure code 10; the inverse is documented in AppError.swift
    // and asserted as "code-after-round-trip ∈ {original, 10}".

    func testAllNumericErrorCodesRoundTripOrFallBackToAPIFailure() {
        let cases: [(name: String, error: AppError)] = [
            ("networkError",                AppError.networkError(NSError(domain: "test", code: 0))),
            ("invalidURL",                  .invalidURL),
            ("noInternetConnection",        .noInternetConnection),
            ("requestTimeout",              .requestTimeout),
            ("persistentNetworkFailure",    .persistentNetworkFailure),
            ("invalidResponse",             .invalidResponse),
            ("decodingError",               .decodingError(NSError(domain: "test", code: 0))),
            ("sttAuthFailed",               .sttAuthFailed),
            ("invalidRequest",              .invalidRequest(message: "x")),
            ("apiFailure",                  .apiFailure(message: "x")),
            ("audioInvalid",                .audioInvalid),
            ("sttQuotaExceeded",            .sttQuotaExceeded),
            ("audioMissingData",            .audioMissingData),
            ("settingsLoadFailed",          .settingsLoadFailed),
            ("sttTooManyRequests",          .sttTooManyRequests),
            ("sttServerError",              .sttServerError),
            ("appleSpeechModelNotInstalled", .appleSpeechModelNotInstalled),
            ("sttProviderUnreachable",      .sttProviderUnreachable),
            ("noSpeechDetected",            .noSpeechDetected),
            ("audioTooLarge",               .audioTooLarge),
            ("sttMissingAPIKey",            .sttMissingAPIKey),
            ("audioProcessingFailed",       .audioProcessingFailed),
            ("sttDecodingFailure",          .sttDecodingFailure),
            // Remote Agent taxonomy (codes 12, 19, 26, 28-31).
            // Code 27 is a reserved gap (.remoteAgentSessionBusy;
            // retired under client-owned history). Round-trip is
            // load-bearing for the Watch relay wire decoder — same contract
            // as the STT codes.
            ("remoteAgentNotConfigured",    .remoteAgentNotConfigured),
            ("remoteAgentUnreachable",      .remoteAgentUnreachable),
            ("remoteAgentAuthFailed",       .remoteAgentAuthFailed),
            ("remoteAgentTimeout",          .remoteAgentTimeout),
            ("remoteAgentServerError",      .remoteAgentServerError),
            ("remoteAgentCertMismatch",     .remoteAgentCertMismatch),
            ("remoteAgentInvalidResponse",  .remoteAgentInvalidResponse),
            // cloud TTS taxonomy (codes 36-40). Round-trip is load-bearing
            // for the Watch relay wire decoder — same contract as STT codes.
            ("ttsProviderUnreachable",      .ttsProviderUnreachable),
            ("ttsSynthesisFailed",          .ttsSynthesisFailed),
            ("ttsEmptyAudio",               .ttsEmptyAudio),
            ("ttsUnauthorized",             .ttsUnauthorized),
            ("ttsRateLimited",              .ttsRateLimited),
            // Speech Recognition TCC denied (code 51).
            ("speechPermissionDenied",      .speechPermissionDenied),
            // chat-ui-mac-freeze — macOS mic lease refused a concurrent capture (code 53).
            ("audioMicBusy",                .audioMicBusy),
            // Body/status-aware gateway taxonomy (codes 55-57).
            ("remoteAgentModelUnavailable", .remoteAgentModelUnavailable),
            ("remoteAgentContextTooLong",   .remoteAgentContextTooLong),
            ("remoteAgentRateLimited",      .remoteAgentRateLimited),
            ("unknown",                     .unknown(NSError(domain: "test", code: 0))),
        ]

        // Documented unreconstructible cases — round-trip lands on code 10
        // (.apiFailure) by design. See AppError.from(errorCode:message:).
        let collapseToAPIFailure: Set<String> = ["networkError", "decodingError", "unknown"]

        for kase in cases {
            let originalCode = kase.error.errorCode
            let resolved = AppError.from(errorCode: originalCode, message: "test")
            let resolvedCode = resolved.errorCode
            if collapseToAPIFailure.contains(kase.name) {
                XCTAssertEqual(
                    resolvedCode,
                    AppError.apiFailure(message: "").errorCode,
                    "\(kase.name) (code \(originalCode)) is documented to collapse to .apiFailure on inverse — got code \(resolvedCode)"
                )
            } else {
                XCTAssertEqual(
                    resolvedCode,
                    originalCode,
                    "\(kase.name) (code \(originalCode)) must round-trip via from(errorCode:) — got code \(resolvedCode). The Watch relay wire decoder depends on this; a mismatch surfaces as a blank banner."
                )
            }
        }
    }

    func testFromUnknownErrorCodeFallsBackToAPIFailure() {
        // Defensive: future provider error codes we haven't seen yet
        // should land in .apiFailure(message:) rather than crashing or
        // dropping into a different case. The associated `message` is
        // preserved on the case for logging / pattern-match callers, but
        // intentionally NOT surfaced in `errorDescription` (which returns
        // the canned localized "Something glitched on our end." string so
        // upstream provider-specific internals don't leak into the user
        // banner).
        let unknown = AppError.from(errorCode: 4242, message: "weird upstream")
        XCTAssertEqual(unknown.errorCode, AppError.apiFailure(message: "").errorCode,
                       "Unknown numeric codes must collapse to .apiFailure, not crash or return nil.")
        guard case .apiFailure(let preserved) = unknown else {
            XCTFail("Expected .apiFailure case, got \(unknown)")
            return
        }
        XCTAssertEqual(preserved, "weird upstream",
                       "Original wire message must survive on the .apiFailure associated value, even though errorDescription returns the canned banner copy.")
    }

    // MARK: - Remote Agent numeric codes

    func testRemoteAgentNumericCodesRoundTrip() {
        // Each remote-agent case must round-trip through from(errorCode:)
        // so the Watch relay wire decoder can reconstruct iPhone-side
        // failures. Mirrors the contract STT codes already enforce.
        // Code 27 is OMITTED — it is a reserved gap
        // (.remoteAgentSessionBusy; retired under client-owned history).
        for code in [12, 19, 26, 28, 29, 30, 31, 55, 56, 57] {
            let err = AppError.from(errorCode: code, message: "test")
            XCTAssertEqual(err.errorCode, code,
                           "Remote Agent code \(code) must round-trip via from(errorCode:); got \(err.errorCode)")
        }
    }

    func testReservedCode27DoesNotRoundTripToRemoteAgentCase() {
        // 27 is a reserved gap — decoding it must fall through to the
        // generic .apiFailure (code 10), NOT resurrect a retired case.
        let resolved = AppError.from(errorCode: 27, message: "test")
        XCTAssertEqual(resolved.errorCode, AppError.apiFailure(message: "").errorCode,
                       "Reserved code 27 must collapse to .apiFailure (it's a gap, not a live case).")
    }

    // MARK: - V1.1 multimodal (vision) codes 32 / 33

    func testVisionUnsupportedErrorCodeIs32() {
        XCTAssertEqual(AppError.remoteAgentVisionUnsupported.errorCode, 32,
                       "Code 32 is reserved for .remoteAgentVisionUnsupported (V1.1 Core Attachments).")
    }

    func testImageTooLargeErrorCodeIs33() {
        XCTAssertEqual(AppError.remoteAgentImageTooLarge.errorCode, 33,
                       "Code 33 is reserved for .remoteAgentImageTooLarge (V1.1 Core Attachments).")
    }

    func testVisionCodes32And33RoundTrip() {
        // Same Watch-relay-wire contract as the other remote-agent codes: the
        // numeric code must reconstruct its exact case via from(errorCode:).
        for code in [32, 33] {
            let err = AppError.from(errorCode: code, message: "test")
            XCTAssertEqual(err.errorCode, code,
                           "Vision code \(code) must round-trip via from(errorCode:); got \(err.errorCode)")
        }
        // Spot-check the case identity (not just the code).
        if case .remoteAgentVisionUnsupported = AppError.from(errorCode: 32, message: nil) {} else {
            XCTFail("Code 32 must resolve to .remoteAgentVisionUnsupported")
        }
        if case .remoteAgentImageTooLarge = AppError.from(errorCode: 33, message: nil) {} else {
            XCTFail("Code 33 must resolve to .remoteAgentImageTooLarge")
        }
    }

    func testVisionCodesAreNotRetryable() {
        // Retrying the same image bytes against the same model won't change the
        // verdict — both must be non-retryable (the user switches model or
        // picks a smaller source image; image dimension is no longer
        // user-configurable).
        XCTAssertFalse(AppError.remoteAgentVisionUnsupported.isRetryable,
                       ".remoteAgentVisionUnsupported must not auto-retry.")
        XCTAssertFalse(AppError.remoteAgentImageTooLarge.isRetryable,
                       ".remoteAgentImageTooLarge must not auto-retry.")
    }

    // MARK: - mapBodyError (body-aware, both send paths)

    func test400UnsupportedContentMapsToVisionUnsupported() {
        let body = Data(#"{"error":{"message":"Unsupported content type in request"}}"#.utf8)
        let mapped = RemoteAgentClient.mapBodyError(status: 400, body: body)
        XCTAssertEqual(mapped?.errorCode, AppError.remoteAgentVisionUnsupported.errorCode,
                       "A 400 body matching /unsupported.*content/i must map to .remoteAgentVisionUnsupported.")
    }

    func test400ImageNotSupportedMapsToVisionUnsupported() {
        // The alternate phrasing the mapper also recognises: the regex is
        // /image.*not.*support/i, so the words must appear in that order
        // ("image" → "not" → "support").
        let body = Data(#"{"error":"Image content is not supported by this model"}"#.utf8)
        let mapped = RemoteAgentClient.mapBodyError(status: 400, body: body)
        XCTAssertEqual(mapped?.errorCode, AppError.remoteAgentVisionUnsupported.errorCode,
                       "A 400 body matching /image.*not.*support/i must map to .remoteAgentVisionUnsupported.")
    }

    func test413StatusMapsToImageTooLarge() {
        // A 413 maps to too-large regardless of body (payload-too-large is the
        // canonical signal).
        let mapped = RemoteAgentClient.mapBodyError(status: 413, body: Data())
        XCTAssertEqual(mapped?.errorCode, AppError.remoteAgentImageTooLarge.errorCode,
                       "Status 413 must map to .remoteAgentImageTooLarge.")
    }

    func test400ImageTooLargeBodyMapsToImageTooLarge() {
        let body = Data(#"{"error":"The image is too large to process"}"#.utf8)
        let mapped = RemoteAgentClient.mapBodyError(status: 400, body: body)
        XCTAssertEqual(mapped?.errorCode, AppError.remoteAgentImageTooLarge.errorCode,
                       "A 400 body matching /image.*too.*large/i must map to .remoteAgentImageTooLarge.")
    }

    func testPlain400UnrelatedBodyFallsThroughToNil() {
        // A generic 400 with no vision-specific phrasing must NOT be claimed by
        // the vision mapper — it falls through to the normal status map (nil).
        let body = Data(#"{"error":"missing required field: messages"}"#.utf8)
        XCTAssertNil(RemoteAgentClient.mapBodyError(status: 400, body: body),
                     "An unrelated 400 body must fall through (nil) to the existing status map.")
    }

    func testNon400Or413StatusReturnsNil() {
        // The mapper only inspects 400 / 413; everything else is nil so the
        // status map handles it.
        XCTAssertNil(RemoteAgentClient.mapBodyError(status: 401, body: Data(#"unsupported content"#.utf8)),
                     "A 401 must be ignored by the vision mapper even if the body matches.")
        XCTAssertNil(RemoteAgentClient.mapBodyError(status: 500, body: Data()),
                     "A 500 must be ignored by the vision mapper.")
        XCTAssertNil(RemoteAgentClient.mapBodyError(status: 200, body: Data()),
                     "A 200 must be ignored by the vision mapper.")
    }

    // MARK: - Cloud TTS codes 36 / 37 / 38

    func testTTSProviderUnreachableErrorCodeIs36() {
        XCTAssertEqual(AppError.ttsProviderUnreachable.errorCode, 36,
                       "Code 36 is reserved for .ttsProviderUnreachable (planned cloud TTS).")
    }

    func testTTSSynthesisFailedErrorCodeIs37() {
        XCTAssertEqual(AppError.ttsSynthesisFailed.errorCode, 37,
                       "Code 37 is reserved for .ttsSynthesisFailed (planned cloud TTS).")
    }

    func testTTSEmptyAudioErrorCodeIs38() {
        XCTAssertEqual(AppError.ttsEmptyAudio.errorCode, 38,
                       "Code 38 is reserved for .ttsEmptyAudio (planned cloud TTS).")
    }

    func testTTSUnauthorizedErrorCodeIs39() {
        XCTAssertEqual(AppError.ttsUnauthorized.errorCode, 39,
                       "Code 39 is reserved for .ttsUnauthorized (planned cloud TTS auth/scope).")
    }

    func testTTSRateLimitedErrorCodeIs40() {
        XCTAssertEqual(AppError.ttsRateLimited.errorCode, 40,
                       "Code 40 is reserved for .ttsRateLimited (planned cloud TTS 402/429 rate-limit/quota).")
    }

    func testTTSCodes36to40RoundTrip() {
        // Same Watch-relay-wire contract as the STT / remote-agent codes.
        for code in [36, 37, 38, 39, 40] {
            let err = AppError.from(errorCode: code, message: "test")
            XCTAssertEqual(err.errorCode, code,
                           "TTS code \(code) must round-trip via from(errorCode:); got \(err.errorCode)")
        }
        // Spot-check case identity (not just the code).
        if case .ttsProviderUnreachable = AppError.from(errorCode: 36, message: nil) {} else {
            XCTFail("Code 36 must resolve to .ttsProviderUnreachable")
        }
        if case .ttsSynthesisFailed = AppError.from(errorCode: 37, message: nil) {} else {
            XCTFail("Code 37 must resolve to .ttsSynthesisFailed")
        }
        if case .ttsEmptyAudio = AppError.from(errorCode: 38, message: nil) {} else {
            XCTFail("Code 38 must resolve to .ttsEmptyAudio")
        }
        if case .ttsUnauthorized = AppError.from(errorCode: 39, message: nil) {} else {
            XCTFail("Code 39 must resolve to .ttsUnauthorized")
        }
        if case .ttsRateLimited = AppError.from(errorCode: 40, message: nil) {} else {
            XCTFail("Code 40 must resolve to .ttsRateLimited")
        }
    }

    func testTTSProviderUnreachableIsRetryableWithCappedAttempts() {
        // Transient → ONE retry then fall back to Apple's voice. Capped at 2.
        XCTAssertTrue(AppError.ttsProviderUnreachable.isRetryable,
                      ".ttsProviderUnreachable must be retryable (transient transport/5xx).")
        XCTAssertLessThanOrEqual(AppError.ttsProviderUnreachable.maxAttempts, 2,
                                 ".ttsProviderUnreachable must cap at ≤ 2 attempts — the Apple fallback is free.")
    }

    func testTTSSynthesisFailedIsNotRetryable() {
        XCTAssertFalse(AppError.ttsSynthesisFailed.isRetryable,
                       ".ttsSynthesisFailed (bad voice/request) must not auto-retry.")
    }

    func testTTSUnauthorizedIsNotRetryable() {
        XCTAssertFalse(AppError.ttsUnauthorized.isRetryable,
                       ".ttsUnauthorized (401/403 — missing text-to-speech scope) must not auto-retry.")
    }

    func testTTSRateLimitedIsRetryableWithCappedAttempts() {
        // 402/429 — a transient rate-limit may clear; a hard quota won't, but the
        // single capped retry is cheap and the Apple fallback closes it out.
        XCTAssertTrue(AppError.ttsRateLimited.isRetryable,
                      ".ttsRateLimited must retry once before the Apple fallback.")
        XCTAssertEqual(AppError.ttsRateLimited.maxAttempts, 2,
                       ".ttsRateLimited caps at 2 attempts.")
    }

    func testTTSEmptyAudioIsRetryableWithCappedAttempts() {
        // The Gemini preview model can return text tokens instead of audio on a
        // 200 → ttsEmptyAudio; one ~1 s retry usually self-heals before the Apple
        // fallback. Shares the ttsProviderUnreachable single-retry budget.
        XCTAssertTrue(AppError.ttsEmptyAudio.isRetryable,
                      ".ttsEmptyAudio must retry once (Gemini preview text-token hiccup).")
        XCTAssertEqual(AppError.ttsEmptyAudio.maxAttempts, 2,
                       ".ttsEmptyAudio caps at 2 attempts — single retry then the Apple fallback.")
    }

    func testTTSCodesNeverPreserveForRetry() {
        // A failed SPOKEN reply is never queued — the text reply is already on
        // screen, and Apple's voice is the free fallback.
        XCTAssertFalse(AppError.ttsProviderUnreachable.shouldPreserveForRetry)
        XCTAssertFalse(AppError.ttsSynthesisFailed.shouldPreserveForRetry)
        XCTAssertFalse(AppError.ttsEmptyAudio.shouldPreserveForRetry)
        XCTAssertFalse(AppError.ttsUnauthorized.shouldPreserveForRetry)
        XCTAssertFalse(AppError.ttsRateLimited.shouldPreserveForRetry)
    }

}
