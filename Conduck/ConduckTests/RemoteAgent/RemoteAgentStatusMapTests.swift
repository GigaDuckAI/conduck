// Conduck
// RemoteAgentStatusMapTests.swift
//
// Locks the SINGLE unified HTTP-status → AppError mapping. Under
// client-owned history (locked 2026-05-20) Conduck pins no server
// session, so it never contends OpenClaw's per-session write lock — there
// is no 423 / `remoteAgentSessionBusy` path and no per-backend
// differentiator. Both `RemoteAgentBackend` cases route through the same
// `RemoteAgentStatusMap.unified`; these tests guard against a regression
// that would reintroduce backend-specific status handling.

import XCTest
@testable import Conduck

final class RemoteAgentStatusMapTests: XCTestCase {

    private let map = RemoteAgentStatusMap.unified

    // MARK: - Auth (401 / 403)

    func test401MapsToAuthFailed() {
        XCTAssertEqual(map.map(401)?.errorCode, AppError.remoteAgentAuthFailed.errorCode,
                       "HTTP 401 must map to .remoteAgentAuthFailed")
    }

    func test403MapsToAuthFailed() {
        XCTAssertEqual(map.map(403)?.errorCode, AppError.remoteAgentAuthFailed.errorCode,
                       "HTTP 403 must map to .remoteAgentAuthFailed")
    }

    // MARK: - Server errors (5xx)

    func test5xxMapsToServerError() {
        for code in [500, 502, 503] {
            XCTAssertEqual(map.map(code)?.errorCode, AppError.remoteAgentServerError.errorCode,
                           "HTTP \(code) must map to .remoteAgentServerError")
        }
    }

    // MARK: - Payment required (402 — hosted provider out of credits)

    func test402MapsToOutOfCredits() {
        XCTAssertEqual(map.map(402)?.errorCode, AppError.remoteAgentOutOfCredits.errorCode,
                       "HTTP 402 must map to .remoteAgentOutOfCredits (OpenRouter out of credits), " +
                       "not the generic 'Unknown error (HTTP 402)' fallback.")
    }

    // MARK: - Request timeout (408 → existing timeout, no new string)

    func test408MapsToTimeout() {
        XCTAssertEqual(map.map(408)?.errorCode, AppError.remoteAgentTimeout.errorCode,
                       "HTTP 408 must reuse .remoteAgentTimeout, not the generic retryable .apiFailure.")
    }

    // MARK: - Rate limited (429 — provider rate-limit / free-tier daily cap)

    func test429MapsToRateLimited() {
        XCTAssertEqual(map.map(429)?.errorCode, AppError.remoteAgentRateLimited.errorCode,
                       "HTTP 429 must map to .remoteAgentRateLimited (OpenRouter free-tier caps), " +
                       "not the generic retryable .apiFailure.")
    }

    // MARK: - 2xx pass-through (caller decodes body)

    func test2xxReturnsNil() {
        for code in [200, 204] {
            XCTAssertNil(map.map(code), "HTTP \(code) must return nil (caller decodes body)")
        }
    }

    // MARK: - No 423 special-handling (client-owned history)

    func test423HasNoSpecialHandling() {
        // 423 is no longer a session-lock signal — Conduck pins no
        // session. It falls through to the generic non-2xx/non-auth/non-5xx
        // path (a localized .apiFailure carrying the raw code), NOT a
        // dedicated `.remoteAgentSessionBusy` case (which no longer exists).
        let mapped = map.map(423)
        XCTAssertNotNil(mapped, "423 still surfaces an error (not nil)")
        // Confirm it is the generic fallback, not a server error or auth.
        XCTAssertEqual(mapped?.errorCode, AppError.apiFailure(message: "").errorCode,
                       "423 must fall through to the generic .apiFailure fallback (no 423/lock path).")
    }
}
