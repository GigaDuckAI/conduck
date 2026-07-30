// SPDX-License-Identifier: Apache-2.0

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
        // 502/503/504, the Cloudflare 521–526 band and 530 are deliberately NOT
        // in this list — they carry their own verdict (see the next test). What
        // remains is the class where the gateway's own application reported the
        // failure, so "check the gateway logs" is sound advice.
        for code in [500, 501, 505, 520, 527, 599] {
            XCTAssertEqual(map.map(code)?.errorCode, AppError.remoteAgentServerError.errorCode,
                           "HTTP \(code) must map to .remoteAgentServerError")
        }
    }

    func testRouteOutagesAreNotGenericServerErrors() {
        // These all mean something in the ROUTE answered on the gateway's behalf
        // after failing to reach it — so "read your gateway's logs" points the
        // user at a machine that saw nothing.
        //
        // The Cloudflare band is edge↔origin: 521 origin down, 522 connect
        // timeout, 523 origin unreachable, 524 origin silent, 525/526 origin TLS,
        // and 530 (error 1033) the hostname routing to no live origin at all —
        // the shape of an expired quick tunnel. 502/503/504 share it generically.
        for code in [502, 503, 504, 521, 522, 523, 524, 525, 526, 530] {
            XCTAssertEqual(map.map(code)?.errorCode, AppError.remoteAgentServiceUnavailable.errorCode,
                           "HTTP \(code) must map to .remoteAgentServiceUnavailable, not the generic 5xx")
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
        // 423 is not a session-lock signal — Conduck pins no session. It falls
        // through to the unmapped-status path, NOT a dedicated
        // `.remoteAgentSessionBusy` case (which does not exist).
        let mapped = map.map(423)
        XCTAssertNotNil(mapped, "423 still surfaces an error (not nil)")
        XCTAssertEqual(mapped?.errorCode, AppError.remoteAgentUnexpectedStatus(status: nil).errorCode,
                       "423 must fall through to the unmapped-status verdict (no 423/lock path).")
    }

    func testUnmappedStatusKeepsItsNumber() {
        // The whole point of 71: this arm used to hand its "Unknown error (HTTP
        // 423)" string to `.apiFailure`, whose `errorDescription` discards the
        // associated message — so every unmapped status rendered as the generic
        // "Something went wrong with the last request." The number must survive
        // into the copy the user actually reads.
        guard let mapped = map.map(423) as? AppError,
              case .remoteAgentUnexpectedStatus(let status) = mapped else {
            return XCTFail("423 must map to .remoteAgentUnexpectedStatus")
        }
        XCTAssertEqual(status, 423, "the unmapped-status verdict must carry the status it saw")
        XCTAssertTrue(mapped.errorDescription?.contains("423") == true,
                      "the number is the one actionable fact here — it must reach the user-facing copy")
    }

    func testUnmappedStatusWithoutANumberStillReads() {
        // A failure rebuilt from a persisted `failureCode` (or off the Watch
        // relay) has no status to show, and must not invent one such as "HTTP 0".
        let rebuilt = AppError.from(errorCode: 71, message: nil)
        guard case .remoteAgentUnexpectedStatus(let status) = rebuilt else {
            return XCTFail("code 71 must reconstruct as .remoteAgentUnexpectedStatus")
        }
        XCTAssertNil(status, "a reconstructed unmapped status has no number to carry")
        let copy = rebuilt.errorDescription ?? ""
        XCTAssertFalse(copy.isEmpty, "the number-less variant still needs copy")
        XCTAssertFalse(copy.contains("0"), "must not fabricate a status such as 'HTTP 0'")
    }

    func testUnmappedStatusNeverEchoesUntrustedText() {
        // 71 replaced `.apiFailure` on this arm precisely because `.apiFailure`'s
        // message is the collapse target for text arriving off the Watch relay
        // wire. Reconstruction must ignore that text entirely rather than parse
        // a status back out of it.
        let rebuilt = AppError.from(errorCode: 71, message: "HTTP 500 token sk-live-should-never-render")
        XCTAssertFalse(rebuilt.errorDescription?.contains("sk-live") == true,
                       "reconstruction must never echo relay-supplied text")
        guard case .remoteAgentUnexpectedStatus(let status) = rebuilt else {
            return XCTFail("code 71 must reconstruct as .remoteAgentUnexpectedStatus")
        }
        XCTAssertNil(status, "a status must never be recovered by parsing untrusted text")
    }
}
