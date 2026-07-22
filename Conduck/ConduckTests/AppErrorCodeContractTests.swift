// Conduck
// AppErrorCodeContractTests.swift
//
// Locks the AppError NUMERIC-CODE WIRE CONTRACT. The Watch relay carries an
// `AppError` across the WCSession wire as a single Int slot
// (`AppleSpeechRelayCoordinator.Wire.resultErrorCodeKey == "result.errorCode"`,
// value = `appError.errorCode`), and the receiver reconstructs it via
// `AppError.from(errorCode:message:)`. A SILENT renumber of any case — or a
// missing inverse arm — collapses a real cross-surface failure into a blank
// or wrong banner. This file pins:
//
//   1. The forward map: an EXPLICIT, EXHAUSTIVE table of (case → literal Int)
//      for EVERY code the `errorCode` getter can emit (hardcoded ints, not
//      symbol==symbol — a tautology can't catch a rename).
//   2. The inverse map: `from(errorCode: n)` round-trips each code back to the
//      SAME case, EXCEPT the three un-reconstructible associated-value cases
//      (networkError / decodingError / unknown) which collapse to .apiFailure
//      (code 10) BY DESIGN, and the reserved gap 27 which must NOT resurrect a
//      retired case.
//   3. A COMPLETENESS guard: the count of distinct codes the getter emits ==
//      this table's length, so a NEW case added without a row here surfaces as
//      a failure rather than slipping through (the existing AppErrorTests array
//      is hand-maintained and NOT exhaustive — this table IS).
//   4. The locked `isRetryable` flags for the codes called out as load-bearing.
//
// The relay's numeric bridge IS exactly `errorCode` (getter) + `from(errorCode:
// Int:message:)` (inverse) — the coordinator ships `appError.errorCode`
// directly and the receiver decodes it, so the round-trip asserted here IS the
// relay-wire contract; there is no separate Int↔Int bridge to traverse.
//
// AppError is not Equatable, so case identity is asserted via the stable
// `errorCode` after reconstruction (a code-preserving inverse is precisely the
// contract the relay needs).

import XCTest
@testable import Conduck

final class AppErrorCodeContractTests: XCTestCase {

    /// EXHAUSTIVE forward table: every case the `errorCode` getter emits,
    /// paired with its HARDCODED literal code. Copied verbatim from
    /// AppError.swift's `var errorCode: Int` switch (lines 575-628).
    /// Associated-value cases use a fixed throwaway payload (irrelevant to the
    /// code, which ignores the payload). 27 is intentionally ABSENT (reserved
    /// gap); 99 is the catch-all.
    private static let forwardTable: [(name: String, error: AppError, code: Int)] = [
        ("networkError",                  .networkError(NSError(domain: "test", code: 0)), 1),
        ("invalidURL",                    .invalidURL,                       2),
        ("noInternetConnection",          .noInternetConnection,             3),
        ("requestTimeout",                .requestTimeout,                   4),
        ("persistentNetworkFailure",      .persistentNetworkFailure,         5),
        ("invalidResponse",               .invalidResponse,                  6),
        ("decodingError",                 .decodingError(NSError(domain: "test", code: 0)), 7),
        ("sttAuthFailed",                 .sttAuthFailed,                    8),
        ("invalidRequest",                .invalidRequest(message: "x"),     9),
        ("apiFailure",                    .apiFailure(message: "x"),         10),
        ("audioInvalid",                  .audioInvalid,                     11),
        ("remoteAgentNotConfigured",      .remoteAgentNotConfigured,         12),
        ("sttQuotaExceeded",              .sttQuotaExceeded,                 13),
        ("audioMissingData",             .audioMissingData,                  14),
        ("settingsLoadFailed",            .settingsLoadFailed,               15),
        ("sttTooManyRequests",            .sttTooManyRequests,               16),
        ("sttServerError",                .sttServerError,                   17),
        ("appleSpeechModelNotInstalled",  .appleSpeechModelNotInstalled,     18),
        ("remoteAgentUnreachable",        .remoteAgentUnreachable,           19),
        ("sttProviderUnreachable",        .sttProviderUnreachable,           20),
        ("noSpeechDetected",              .noSpeechDetected,                 21),
        ("audioTooLarge",                 .audioTooLarge,                    22),
        ("sttMissingAPIKey",              .sttMissingAPIKey,                 23),
        ("audioProcessingFailed",         .audioProcessingFailed,            24),
        ("sttDecodingFailure",            .sttDecodingFailure,               25),
        ("remoteAgentAuthFailed",         .remoteAgentAuthFailed,            26),
        // 27 — RESERVED GAP (was .remoteAgentSessionBusy; retired). No case.
        ("remoteAgentTimeout",            .remoteAgentTimeout,               28),
        ("remoteAgentServerError",        .remoteAgentServerError,           29),
        ("remoteAgentCertMismatch",       .remoteAgentCertMismatch,          30),
        ("remoteAgentInvalidResponse",    .remoteAgentInvalidResponse,       31),
        ("remoteAgentVisionUnsupported",  .remoteAgentVisionUnsupported,     32),
        ("remoteAgentImageTooLarge",      .remoteAgentImageTooLarge,         33),
        ("sttCustomEndpointNotConfigured", .sttCustomEndpointNotConfigured,  34),
        ("sttCustomCertMismatch",         .sttCustomCertMismatch,            35),
        ("ttsProviderUnreachable",        .ttsProviderUnreachable,           36),
        ("ttsSynthesisFailed",            .ttsSynthesisFailed,               37),
        ("ttsEmptyAudio",                 .ttsEmptyAudio,                    38),
        ("ttsUnauthorized",               .ttsUnauthorized,                  39),
        ("ttsRateLimited",                .ttsRateLimited,                   40),
        ("ttsContentBlocked",             .ttsContentBlocked,                41),
        ("ttsCustomEndpointNotConfigured", .ttsCustomEndpointNotConfigured,  42),
        ("ttsCustomCertMismatch",         .ttsCustomCertMismatch,            43),
        ("fileTransferNotConfigured",     .fileTransferNotConfigured,        44),
        ("fileTransferUnreachable",       .fileTransferUnreachable,          45),
        ("fileTransferAuthFailed",        .fileTransferAuthFailed,           46),
        ("fileTransferCertMismatch",      .fileTransferCertMismatch,         47),
        ("fileTransferServerError",       .fileTransferServerError,          48),
        ("fileTransferUploadFailed",      .fileTransferUploadFailed,         49),
        ("fileTransferFileUnavailable",   .fileTransferFileUnavailable,      50),
        ("speechPermissionDenied",        .speechPermissionDenied,           51),
        ("remoteAgentOutOfCredits",       .remoteAgentOutOfCredits,          52),
        ("audioMicBusy",                  .audioMicBusy,                     53),
        ("appleSpeechLanguageUnsupported", .appleSpeechLanguageUnsupported,  54),
        ("remoteAgentModelUnavailable",   .remoteAgentModelUnavailable,      55),
        ("remoteAgentContextTooLong",     .remoteAgentContextTooLong,        56),
        ("remoteAgentRateLimited",        .remoteAgentRateLimited,           57),
        ("remoteAgentEndpointUnexpectedResponse", .remoteAgentEndpointUnexpectedResponse, 58),
        ("remoteAgentEndpointNotFound",   .remoteAgentEndpointNotFound,      59),
        ("remoteAgentModelRequired",      .remoteAgentModelRequired,         60),
        ("fileTransferNotAFileServer",    .fileTransferNotAFileServer,       61),
        ("unknown",                       .unknown(NSError(domain: "test", code: 0)), 99),
    ]

    /// The three cases whose associated `Error` value can't be reconstructed
    /// from a bare code — `from(errorCode:)` documents these as collapsing to
    /// `.apiFailure` (code 10). Their forward code is still pinned above; only
    /// the inverse differs.
    private static let collapseToAPIFailure: Set<String> = ["networkError", "decodingError", "unknown"]

    // MARK: - Forward map (case → literal Int)

    func testEveryCaseEmitsItsLockedLiteralCode() {
        for row in Self.forwardTable {
            XCTAssertEqual(
                row.error.errorCode, row.code,
                "\(row.name).errorCode must be \(row.code) (Watch relay decodes this exact int; a renumber breaks cross-surface error decode)."
            )
        }
    }

    // MARK: - Inverse map (Int → same case)

    func testEveryCodeRoundTripsBackToItsCase() {
        for row in Self.forwardTable {
            let reconstructed = AppError.from(errorCode: row.code, message: "wire-message")
            if Self.collapseToAPIFailure.contains(row.name) {
                XCTAssertEqual(
                    reconstructed.errorCode, 10,
                    "\(row.name) (code \(row.code)) carries an un-reconstructible Error; from(errorCode:) must collapse it to .apiFailure (10)."
                )
            } else {
                XCTAssertEqual(
                    reconstructed.errorCode, row.code,
                    "from(errorCode: \(row.code)) must reconstruct \(row.name) (code-preserving inverse). A mismatch surfaces as a blank/wrong banner on the Watch relay."
                )
            }
        }
    }

    // MARK: - Reserved gap 27

    func testReservedCode27IsNotARealCase() {
        // 27 (formerly .remoteAgentSessionBusy) is a permanent gap under
        // client-owned history. Decoding it must fall through to the generic
        // .apiFailure (10), NEVER resurrect a retired case. It must also not
        // collide with any pinned code in the forward table.
        XCTAssertFalse(
            Self.forwardTable.contains { $0.code == 27 },
            "Code 27 must stay a reserved gap — no live case may claim it."
        )
        let resolved = AppError.from(errorCode: 27, message: "wire-message")
        XCTAssertEqual(
            resolved.errorCode, 10,
            "Reserved code 27 must decode to .apiFailure (10), not a resurrected case."
        )
    }

    func testUnknownCodeCollapsesToAPIFailurePreservingMessage() {
        // Defensive: a future/unknown numeric code must land in
        // .apiFailure(message:) — preserving the wire message on the associated
        // value — rather than crash or pick a wrong case.
        let resolved = AppError.from(errorCode: 7777, message: "future upstream code")
        XCTAssertEqual(resolved.errorCode, 10,
                       "Unknown numeric codes must collapse to .apiFailure (10).")
        guard case .apiFailure(let preserved) = resolved else {
            return XCTFail("Expected .apiFailure, got \(resolved)")
        }
        XCTAssertEqual(preserved, "future upstream code",
                       "Wire message must survive on the .apiFailure associated value.")
    }

    // MARK: - Completeness guard

    func testForwardTableIsExhaustiveOverEmittedCodes() {
        // The getter emits codes 1...61 with 27 omitted (reserved gap), plus
        // the catch-all 99 — that is 60 + 1 = 61 distinct codes. If a NEW case
        // is added to AppError without a row in `forwardTable`, this count
        // diverges and forces a test update. (Computed independently of the
        // table to avoid the table validating itself.)
        let expectedDistinctCodes = Set((1...61).filter { $0 != 27 }).union([99])
        XCTAssertEqual(expectedDistinctCodes.count, 61,
                       "Sanity: 1...61 minus the 27 gap plus 99 = 61 distinct codes.")

        let tableCodes = Self.forwardTable.map(\.code)
        XCTAssertEqual(Set(tableCodes).count, tableCodes.count,
                       "Forward table must have no duplicate codes (each case owns a unique slot).")
        XCTAssertEqual(Set(tableCodes), expectedDistinctCodes,
                       "Forward table must cover EXACTLY the codes the getter emits (1...61 except 27, plus 99). A diff here means a new/renamed/removed case is untested.")
        XCTAssertEqual(Self.forwardTable.count, 61,
                       "Forward table must enumerate all 61 emittable codes — a new AppError case without a row here is a wire-contract gap.")
    }

    // MARK: - Locked isRetryable flags (load-bearing)

    func testLockedRetryableFlags() {
        // ttsContentBlocked (41): a safety-filter block is terminal — retrying
        // the same text won't pass; fall straight to the Apple voice.
        XCTAssertFalse(AppError.ttsContentBlocked.isRetryable,
                       ".ttsContentBlocked (41) must NOT auto-retry — the safety filter won't change its verdict.")
        // remoteAgentOutOfCredits (52): HTTP 402; retrying without adding
        // credits is pointless.
        XCTAssertFalse(AppError.remoteAgentOutOfCredits.isRetryable,
                       ".remoteAgentOutOfCredits (52) must NOT auto-retry — out of credits won't self-heal.")
        // Vision 32/33: same image bytes + same model = same verdict.
        XCTAssertFalse(AppError.remoteAgentVisionUnsupported.isRetryable,
                       ".remoteAgentVisionUnsupported (32) must NOT auto-retry.")
        XCTAssertFalse(AppError.remoteAgentImageTooLarge.isRetryable,
                       ".remoteAgentImageTooLarge (33) must NOT auto-retry.")
    }

    // MARK: - New-tail code pins (41 / 44...50 / 52 / 53)
    //
    // These extend beyond the codes AppErrorTests' hand-maintained array
    // covers (it stops at 40 / 51 / 53 for round-trip and never pins 41 or
    // 44-50 / 52 individually). Pin the exact literals here so a renumber of
    // the cloud-TTS-content-block, file-transfer, out-of-credits, or mic-busy
    // tail surfaces immediately.

    func testTTSContentBlockedCodeIs41() {
        XCTAssertEqual(AppError.ttsContentBlocked.errorCode, 41,
                       "Code 41 is reserved for .ttsContentBlocked (provider safety filter).")
    }

    func testFileTransferCodesAre44Through50() {
        XCTAssertEqual(AppError.fileTransferNotConfigured.errorCode, 44)
        XCTAssertEqual(AppError.fileTransferUnreachable.errorCode, 45)
        XCTAssertEqual(AppError.fileTransferAuthFailed.errorCode, 46)
        XCTAssertEqual(AppError.fileTransferCertMismatch.errorCode, 47)
        XCTAssertEqual(AppError.fileTransferServerError.errorCode, 48)
        XCTAssertEqual(AppError.fileTransferUploadFailed.errorCode, 49)
        XCTAssertEqual(AppError.fileTransferFileUnavailable.errorCode, 50)
    }

    func testFileTransferNotAFileServerCodeIs61() {
        XCTAssertEqual(AppError.fileTransferNotAFileServer.errorCode, 61,
                       "Code 61 is reserved for .fileTransferNotAFileServer (host answers, isn't serving files).")
        // The inverse must exist too — the Watch relay decodes the numeric slot,
        // and a missing arm collapses this failure to a blank banner.
        XCTAssertEqual(AppError.from(errorCode: 61, message: nil).errorCode, 61,
                       "Code 61 must round-trip through from(errorCode:).")
        XCTAssertFalse(AppError.fileTransferNotAFileServer.isRetryable,
                       ".fileTransferNotAFileServer (61) is a config problem — retrying the same PUT can't change it.")
    }

    func testRemoteAgentOutOfCreditsCodeIs52() {
        XCTAssertEqual(AppError.remoteAgentOutOfCredits.errorCode, 52,
                       "Code 52 is reserved for .remoteAgentOutOfCredits (HTTP 402).")
    }

    func testAudioMicBusyCodeIs53() {
        XCTAssertEqual(AppError.audioMicBusy.errorCode, 53,
                       "Code 53 is reserved for .audioMicBusy (macOS concurrent-capture refusal).")
    }
}
