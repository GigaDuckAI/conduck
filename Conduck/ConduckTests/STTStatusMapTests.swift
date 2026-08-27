// SPDX-License-Identifier: Apache-2.0

// Conduck
// STTStatusMapTests.swift
//
// Existing `STTProviderTests` covers the
// load-bearing 429 differentiator (Mistral / OpenAI). This file fills
// two gaps:
//   1. `STTStatusMap.never` — the in-process (Apple) provider's status
//      map must return nil for every HTTP code. A regression here would
//      reintroduce HTTP-error-shaped failures into the Apple path, which
//      has no HTTP surface at all.
//   2. `sharedNon429` shared mapping — locks 4xx/5xx semantics for the
//      cloud providers so a future contributor can't quietly change one
//      shared code (e.g. 400 → noSpeechDetected) and break all providers.

import XCTest
@testable import Conduck

final class STTStatusMapTests: XCTestCase {

    // MARK: - never (Apple / in-process)

    func testNeverReturnsNilFor2xx() {
        for code in [200, 201, 204, 299] {
            XCTAssertNil(STTStatusMap.never.map(code, nil),
                         "STTStatusMap.never must return nil for any 2xx; got mapping for \(code)")
        }
    }

    func testNeverReturnsNilFor4xx() {
        for code in [400, 401, 403, 404, 413, 422, 429] {
            XCTAssertNil(STTStatusMap.never.map(code, nil),
                         "STTStatusMap.never must return nil for any 4xx (in-process has no HTTP surface); got mapping for \(code)")
        }
    }

    func testNeverReturnsNilFor5xx() {
        for code in [500, 502, 503, 599] {
            XCTAssertNil(STTStatusMap.never.map(code, nil),
                         "STTStatusMap.never must return nil for any 5xx; got mapping for \(code)")
        }
    }

    func testNeverIsIdempotentAcrossRandomCodes() {
        // Defensive against accidental edge-case carve-outs.
        for code in [0, 99, 100, 300, 301, 418, 451, 999] {
            XCTAssertNil(STTStatusMap.never.map(code, nil),
                         "STTStatusMap.never must return nil unconditionally; got mapping for \(code)")
        }
    }

    // MARK: - Shared 4xx mapping (locks cloud-provider contract)

    func testShared400MapsToAudioInvalidOnMultipartAudioProviders() {
        // 400 = unreadable body on the multipart audio endpoints, where the
        // request IS the recording. Gemini is deliberately excluded — see
        // `testGemini400BlamesTheRequestNotTheRecording`.
        for map in [STTStatusMap.mistral, .openAICompat, .elevenLabsScribe, .qwen] {
            XCTAssertEqual(map.map(400, nil)?.errorCode, AppError.audioInvalid.errorCode,
                           "400 must map to .audioInvalid on the multipart audio providers (shared semantics)")
        }
    }

    // MARK: - Gemini (Interactions API: request-shaped 4xx, body-aware 429)

    /// On the Interactions endpoint a 400 means the REQUEST was rejected
    /// (unknown model, bad config) — not that the microphone produced garbage.
    /// Sending the user to re-record is sending them to fix the one thing that
    /// is not broken.
    func testGemini400BlamesTheRequestNotTheRecording() {
        let mapped = STTStatusMap.gemini.map(400, nil)
        XCTAssertNotEqual(mapped?.errorCode, AppError.audioInvalid.errorCode,
                          "A rejected request must not be reported as a bad recording.")
        XCTAssertEqual(mapped?.isRetryable, false,
                       "400 is deterministic — retrying re-sends a request that cannot succeed.")
    }

    /// 404 = unknown/withdrawn model. Also deterministic, so also non-retryable.
    func testGemini404IsNonRetryable() {
        XCTAssertEqual(STTStatusMap.gemini.map(404, nil)?.isRetryable, false,
                       "An unknown model cannot become known by asking twice.")
    }

    /// Google returns 403 PERMISSION_DENIED for a disabled API or restricted
    /// key. `STTGETProbe` already calls that an auth failure; the hot path must
    /// agree, or the same key reads "Invalid key." in Settings and "Unknown
    /// error (HTTP 403)" mid-recording.
    func testGemini403IsAuthFailure() {
        XCTAssertEqual(STTStatusMap.gemini.map(403, nil)?.errorCode, AppError.sttAuthFailed.errorCode)
    }

    /// 429 splits on the STRUCTURED error code, never on message prose.
    func testGemini429SplitsQuotaFromRateLimit() {
        let quota = #"{"error":{"code":"quota_exceeded","message":"…"}}"#.data(using: .utf8)!
        XCTAssertEqual(STTStatusMap.gemini.map(429, quota)?.errorCode,
                       AppError.sttQuotaExceeded.errorCode,
                       "A spent quota is billing-fatal and must not be retried.")

        let rate = #"{"error":{"code":"rate_limit_exceeded","message":"…"}}"#.data(using: .utf8)!
        XCTAssertEqual(STTStatusMap.gemini.map(429, rate)?.errorCode,
                       AppError.sttTooManyRequests.errorCode,
                       "A transient rate limit must stay retryable.")
    }

    /// The safe default. A wrongly-transient 429 costs one retry against a
    /// request that does not bill; a wrongly-terminal one tells a merely
    /// rate-limited user to go top up an account that has money in it.
    func testGemini429DefaultsToTransientWithoutAConclusiveBody() {
        for body in [nil,
                     Data(),
                     "not json".data(using: .utf8)!,
                     #"{"error":{"code":403,"status":"RESOURCE_EXHAUSTED"}}"#.data(using: .utf8)!] as [Data?] {
            XCTAssertEqual(STTStatusMap.gemini.map(429, body)?.errorCode,
                           AppError.sttTooManyRequests.errorCode,
                           "Without a conclusive quota code, 429 must stay transient.")
        }
    }

    /// The legacy status is ambiguous between the two, so it must NOT be read
    /// as conclusive — that would re-introduce the wrong advice this split fixes.
    func testGeminiResourceExhaustedAloneIsNotTreatedAsHardQuota() {
        let legacy = #"{"error":{"code":429,"status":"RESOURCE_EXHAUSTED"}}"#.data(using: .utf8)!
        XCTAssertEqual(STTStatusMap.gemini.map(429, legacy)?.errorCode,
                       AppError.sttTooManyRequests.errorCode)
    }

    func testShared401MapsToSttAuthFailed() {
        for map in [STTStatusMap.mistral, .openAICompat, .elevenLabsScribe, .gemini, .qwen] {
            XCTAssertEqual(map.map(401, nil)?.errorCode, AppError.sttAuthFailed.errorCode,
                           "401 must map to .sttAuthFailed across all cloud providers")
        }
    }

    func testShared413MapsToAudioTooLarge() {
        for map in [STTStatusMap.mistral, .openAICompat, .elevenLabsScribe, .gemini, .qwen] {
            XCTAssertEqual(map.map(413, nil)?.errorCode, AppError.audioTooLarge.errorCode,
                           "413 must map to .audioTooLarge across all cloud providers")
        }
    }

    func testShared5xxMapsToSttServerError() {
        for code in [500, 502, 503, 504] {
            for map in [STTStatusMap.mistral, .openAICompat, .elevenLabsScribe, .gemini, .qwen] {
                XCTAssertEqual(map.map(code, nil)?.errorCode, AppError.sttServerError.errorCode,
                               "\(code) must map to .sttServerError across all cloud providers")
            }
        }
    }

    // MARK: - OpenRouter (distinct 402 / 429 / 400-404 semantics)

    func testOpenRouter402MapsToQuotaExceededNonRetryable() {
        // 402 = out of credits (billing-fatal), reusing an existing STT case
        // rather than adding one. Deliberately NOT the gateway's
        // `remoteAgentOutOfCredits` posture: `isRetryable` gates STTClient's
        // AUTOMATIC loop on this lane, so retryable here would re-ask a question
        // the account cannot answer — where on the gateway lane the same flag
        // only draws a button the user taps after topping up.
        XCTAssertEqual(STTStatusMap.openRouter.map(402, nil)?.errorCode,
                       AppError.sttQuotaExceeded.errorCode,
                       "OpenRouter 402 (out of credits) must map to .sttQuotaExceeded (non-retryable).")
    }

    func testOpenRouter429MapsToTooManyRequestsRetryable() {
        XCTAssertEqual(STTStatusMap.openRouter.map(429, nil)?.errorCode,
                       AppError.sttTooManyRequests.errorCode,
                       "OpenRouter 429 is a transient rate-limit (retryable).")
    }

    func testOpenRouter400And404DoNotBlameAudio() {
        // A bad/unknown user-overridden model returns 400/404 — must NOT inherit
        // the shared `400 → audioInvalid` mapping that would wrongly blame the
        // recording. Routed to the generic unknown-status fallback instead.
        for code in [400, 404] {
            let mapped = STTStatusMap.openRouter.map(code, nil)
            XCTAssertNotEqual(mapped?.errorCode, AppError.audioInvalid.errorCode,
                              "OpenRouter \(code) must NOT map to .audioInvalid (it's a bad request/model, not bad audio).")
            XCTAssertNotNil(mapped, "OpenRouter \(code) must still surface an error.")
        }
    }

    func testOpenRouterSharedCodesStillMap() {
        // Codes OpenRouter doesn't special-case fall through to the shared map.
        XCTAssertEqual(STTStatusMap.openRouter.map(401, nil)?.errorCode, AppError.sttAuthFailed.errorCode,
                       "OpenRouter 401 falls through to shared .sttAuthFailed.")
        XCTAssertEqual(STTStatusMap.openRouter.map(503, nil)?.errorCode, AppError.sttServerError.errorCode,
                       "OpenRouter 5xx falls through to shared .sttServerError.")
        XCTAssertNil(STTStatusMap.openRouter.map(200, nil),
                     "OpenRouter 2xx returns nil (caller decodes the body).")
    }
}
