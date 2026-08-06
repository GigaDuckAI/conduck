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
            XCTAssertNil(STTStatusMap.never.map(code),
                         "STTStatusMap.never must return nil for any 2xx; got mapping for \(code)")
        }
    }

    func testNeverReturnsNilFor4xx() {
        for code in [400, 401, 403, 404, 413, 422, 429] {
            XCTAssertNil(STTStatusMap.never.map(code),
                         "STTStatusMap.never must return nil for any 4xx (in-process has no HTTP surface); got mapping for \(code)")
        }
    }

    func testNeverReturnsNilFor5xx() {
        for code in [500, 502, 503, 599] {
            XCTAssertNil(STTStatusMap.never.map(code),
                         "STTStatusMap.never must return nil for any 5xx; got mapping for \(code)")
        }
    }

    func testNeverIsIdempotentAcrossRandomCodes() {
        // Defensive against accidental edge-case carve-outs.
        for code in [0, 99, 100, 300, 301, 418, 451, 999] {
            XCTAssertNil(STTStatusMap.never.map(code),
                         "STTStatusMap.never must return nil unconditionally; got mapping for \(code)")
        }
    }

    // MARK: - Shared 4xx mapping (locks cloud-provider contract)

    func testShared400MapsToAudioInvalidAcrossCloudProviders() {
        // 400 = unreadable body on Mistral/OpenAI/ElevenLabs/Gemini/Qwen.
        for map in [STTStatusMap.mistral, .openAICompat, .elevenLabsScribe, .gemini, .qwen] {
            XCTAssertEqual(map.map(400)?.errorCode, AppError.audioInvalid.errorCode,
                           "400 must map to .audioInvalid across all cloud providers (shared semantics)")
        }
    }

    func testShared401MapsToSttAuthFailed() {
        for map in [STTStatusMap.mistral, .openAICompat, .elevenLabsScribe, .gemini, .qwen] {
            XCTAssertEqual(map.map(401)?.errorCode, AppError.sttAuthFailed.errorCode,
                           "401 must map to .sttAuthFailed across all cloud providers")
        }
    }

    func testShared413MapsToAudioTooLarge() {
        for map in [STTStatusMap.mistral, .openAICompat, .elevenLabsScribe, .gemini, .qwen] {
            XCTAssertEqual(map.map(413)?.errorCode, AppError.audioTooLarge.errorCode,
                           "413 must map to .audioTooLarge across all cloud providers")
        }
    }

    func testShared5xxMapsToSttServerError() {
        for code in [500, 502, 503, 504] {
            for map in [STTStatusMap.mistral, .openAICompat, .elevenLabsScribe, .gemini, .qwen] {
                XCTAssertEqual(map.map(code)?.errorCode, AppError.sttServerError.errorCode,
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
        XCTAssertEqual(STTStatusMap.openRouter.map(402)?.errorCode,
                       AppError.sttQuotaExceeded.errorCode,
                       "OpenRouter 402 (out of credits) must map to .sttQuotaExceeded (non-retryable).")
    }

    func testOpenRouter429MapsToTooManyRequestsRetryable() {
        XCTAssertEqual(STTStatusMap.openRouter.map(429)?.errorCode,
                       AppError.sttTooManyRequests.errorCode,
                       "OpenRouter 429 is a transient rate-limit (retryable).")
    }

    func testOpenRouter400And404DoNotBlameAudio() {
        // A bad/unknown user-overridden model returns 400/404 — must NOT inherit
        // the shared `400 → audioInvalid` mapping that would wrongly blame the
        // recording. Routed to the generic unknown-status fallback instead.
        for code in [400, 404] {
            let mapped = STTStatusMap.openRouter.map(code)
            XCTAssertNotEqual(mapped?.errorCode, AppError.audioInvalid.errorCode,
                              "OpenRouter \(code) must NOT map to .audioInvalid (it's a bad request/model, not bad audio).")
            XCTAssertNotNil(mapped, "OpenRouter \(code) must still surface an error.")
        }
    }

    func testOpenRouterSharedCodesStillMap() {
        // Codes OpenRouter doesn't special-case fall through to the shared map.
        XCTAssertEqual(STTStatusMap.openRouter.map(401)?.errorCode, AppError.sttAuthFailed.errorCode,
                       "OpenRouter 401 falls through to shared .sttAuthFailed.")
        XCTAssertEqual(STTStatusMap.openRouter.map(503)?.errorCode, AppError.sttServerError.errorCode,
                       "OpenRouter 5xx falls through to shared .sttServerError.")
        XCTAssertNil(STTStatusMap.openRouter.map(200),
                     "OpenRouter 2xx returns nil (caller decodes the body).")
    }
}
