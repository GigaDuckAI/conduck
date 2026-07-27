// SPDX-License-Identifier: Apache-2.0

// Conduck
// TTSStatusMapTests.swift
//
// Cloud Text-to-Speech HTTP-status → AppError mapping. Four outcomes (the
// Apple fallback is free): transient transport/server (408/5xx) →
// `ttsProviderUnreachable`; rate-limit/quota (402/429) → `ttsRateLimited`; key
// rejected for TTS (401/403) → `ttsUnauthorized`; bad voice/request
// (400/404/422 + other 4xx) → `ttsSynthesisFailed`. 2xx → nil. Same map for
// OpenAI/Mistral + ElevenLabs.

import XCTest
@testable import Conduck

final class TTSStatusMapTests: XCTestCase {

    private func assertCode(_ map: TTSStatusMap, _ code: Int, _ expected: AppError?, line: UInt = #line) {
        let mapped = map.map(code)
        XCTAssertEqual(mapped?.errorCode, expected?.errorCode,
                       "HTTP \(code) → \(String(describing: mapped)) (expected \(String(describing: expected)))",
                       line: line)
    }

    func testSuccessReturnsNil() {
        for map in [TTSStatusMap.openAICompat, .elevenLabs] {
            assertCode(map, 200, nil)
            assertCode(map, 204, nil)
        }
    }

    func testTransientCodesMapToProviderUnreachable() {
        for map in [TTSStatusMap.openAICompat, .elevenLabs] {
            assertCode(map, 408, .ttsProviderUnreachable)
            assertCode(map, 500, .ttsProviderUnreachable)
            assertCode(map, 503, .ttsProviderUnreachable)
        }
    }

    func testRateLimitAndQuotaCodesMapToRateLimited() {
        // 402/429 = rate-limited or out of quota/credit. OpenAI's 429
        // `insufficient_quota` is account-side — it must NOT read as "check your
        // connection" (`ttsProviderUnreachable`).
        for map in [TTSStatusMap.openAICompat, .elevenLabs, .gemini] {
            assertCode(map, 402, .ttsRateLimited)
            assertCode(map, 429, .ttsRateLimited)
        }
    }

    func testAuthCodesMapToUnauthorized() {
        // 401/403 = key rejected for TTS (missing text-to-speech scope). Must be
        // its own class so the surfaced message points at the KEY, not the voice
        // ID — the ElevenLabs speech_to_text-only-key trap lands here as a 401.
        for map in [TTSStatusMap.openAICompat, .elevenLabs, .gemini] {
            assertCode(map, 401, .ttsUnauthorized)
            assertCode(map, 403, .ttsUnauthorized)
        }
    }

    func testBadVoiceOrRequestCodesMapToSynthesisFailed() {
        for map in [TTSStatusMap.openAICompat, .elevenLabs, .gemini] {
            assertCode(map, 400, .ttsSynthesisFailed)
            assertCode(map, 404, .ttsSynthesisFailed)  // Gemini returns 404 for an invalid voice name
            assertCode(map, 422, .ttsSynthesisFailed)
        }
    }

    func testNeverMapReturnsNilForEverything() {
        // The Apple sentinel never produces an HTTP status.
        assertCode(TTSStatusMap.never, 200, nil)
        assertCode(TTSStatusMap.never, 500, nil)
        assertCode(TTSStatusMap.never, 401, nil)
    }

    // MARK: - AppError retry semantics for the TTS cases

    func testProviderUnreachableIsRetryableCappedAtTwo() {
        XCTAssertTrue(AppError.ttsProviderUnreachable.isRetryable)
        XCTAssertEqual(AppError.ttsProviderUnreachable.maxAttempts, 2,
                       "A spoken reply must never burn more than 2 attempts before the Apple fallback.")
        XCTAssertFalse(AppError.ttsProviderUnreachable.shouldPreserveForRetry)
    }

    func testSynthesisFailedIsTerminal() {
        XCTAssertFalse(AppError.ttsSynthesisFailed.isRetryable)
        XCTAssertFalse(AppError.ttsSynthesisFailed.shouldPreserveForRetry)
    }

    func testUnauthorizedIsTerminal() {
        // A rejected/under-scoped key won't recover by retrying the same call.
        XCTAssertFalse(AppError.ttsUnauthorized.isRetryable)
        XCTAssertFalse(AppError.ttsUnauthorized.shouldPreserveForRetry)
    }

    func testRateLimitedRetriesOnceThenFallsBack() {
        // 429/402 may be a transient rate-limit OR a hard quota — one capped
        // retry is cheap (Apple fallback is free), but it's never queued.
        XCTAssertTrue(AppError.ttsRateLimited.isRetryable)
        XCTAssertEqual(AppError.ttsRateLimited.maxAttempts, 2)
        XCTAssertFalse(AppError.ttsRateLimited.shouldPreserveForRetry)
    }

    func testEmptyAudioIsRetryableButNeverPreserved() {
        // The Gemini preview model can return text tokens instead of audio on a
        // 200 → ttsEmptyAudio; a single retry usually self-heals before the Apple
        // fallback. Still never queued for later (a spoken reply isn't preserved).
        XCTAssertTrue(AppError.ttsEmptyAudio.isRetryable)
        XCTAssertEqual(AppError.ttsEmptyAudio.maxAttempts, 2)
        XCTAssertFalse(AppError.ttsEmptyAudio.shouldPreserveForRetry)
    }

    func testTTSErrorCodesRoundTrip() {
        XCTAssertEqual(AppError.ttsProviderUnreachable.errorCode, 36)
        XCTAssertEqual(AppError.ttsSynthesisFailed.errorCode, 37)
        XCTAssertEqual(AppError.ttsEmptyAudio.errorCode, 38)
        XCTAssertEqual(AppError.ttsUnauthorized.errorCode, 39)
        XCTAssertEqual(AppError.ttsRateLimited.errorCode, 40)
        XCTAssertEqual(AppError.from(errorCode: 36, message: nil).errorCode, 36)
        XCTAssertEqual(AppError.from(errorCode: 37, message: nil).errorCode, 37)
        XCTAssertEqual(AppError.from(errorCode: 38, message: nil).errorCode, 38)
        XCTAssertEqual(AppError.from(errorCode: 39, message: nil).errorCode, 39)
        XCTAssertEqual(AppError.from(errorCode: 40, message: nil).errorCode, 40)
    }
}
