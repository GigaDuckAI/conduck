// SPDX-License-Identifier: Apache-2.0

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
        ("remoteAgentEndpointWrongEnvelope", .remoteAgentEndpointWrongEnvelope, 62),
        ("remoteAgentCertUntrusted",      .remoteAgentCertUntrusted,         63),
        ("sttCustomCertUntrusted",        .sttCustomCertUntrusted,           64),
        ("ttsCustomCertUntrusted",        .ttsCustomCertUntrusted,           65),
        ("fileTransferCertUntrusted",     .fileTransferCertUntrusted,        66),
        ("remoteAgentCertKeyUnpinnable",  .remoteAgentCertKeyUnpinnable,     67),
        ("sttCustomCertKeyUnpinnable",    .sttCustomCertKeyUnpinnable,       68),
        ("ttsCustomCertKeyUnpinnable",    .ttsCustomCertKeyUnpinnable,       69),
        ("fileTransferCertKeyUnpinnable", .fileTransferCertKeyUnpinnable,    70),
        // Gateway failure forensics. 71 carries a status on the way OUT but
        // reconstructs without one (a bare code cannot restore a second integer,
        // and the relay `message` is untrusted) — so the round-trip test below
        // treats it like the other lossy-associated-value cases.
        ("remoteAgentUnexpectedStatus",   .remoteAgentUnexpectedStatus(status: 503), 71),
        ("remoteAgentServiceUnavailable", .remoteAgentServiceUnavailable,    72),
        ("remoteAgentNotEstablished",     .remoteAgentNotEstablished,        73),
        // 74 carries a gateway DISPLAY NAME on the way out and reconstructs
        // without one, on 71's reasoning: a bare code cannot restore a String,
        // and the relay `message` is untrusted text that must never be parsed
        // back into copy. Unlike 71 it does NOT collapse to `.apiFailure` — it
        // round-trips to ITSELF with a nil name, whose copy is written to be
        // true on its own.
        ("remoteAgentDefaultNeedsSetup",  .remoteAgentDefaultNeedsSetup(gatewayName: "X"), 74),
        // 75 carries nothing, so it round-trips to itself exactly. It exists to
        // keep "the Keychain could not answer" out of 23, which asserts the slot
        // is EMPTY — a claim that is false on any device that has rebooted and
        // not yet been unlocked.
        ("sttKeyUnreadable",              .sttKeyUnreadable,                 75),
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
        // The getter emits codes 1...75 with 27 omitted (reserved gap), plus
        // the catch-all 99 — that is 74 + 1 = 75 distinct codes. If a NEW case
        // is added to AppError without a row in `forwardTable`, this count
        // diverges and forces a test update. (Computed independently of the
        // table to avoid the table validating itself.)
        //
        // The range grew to 74 because `.remoteAgentDefaultNeedsSetup` claimed
        // that slot, and to 75 because `.sttKeyUnreadable` claimed the next one.
        // This guard is written for exactly that event — a new case landing with
        // no wire row — so it did its job both times: the fix is to RECORD the
        // new code here, never to loosen the assertion.
        let expectedDistinctCodes = Set((1...75).filter { $0 != 27 }).union([99])
        XCTAssertEqual(expectedDistinctCodes.count, 75,
                       "Sanity: 1...75 minus the 27 gap plus 99 = 75 distinct codes.")

        let tableCodes = Self.forwardTable.map(\.code)
        XCTAssertEqual(Set(tableCodes).count, tableCodes.count,
                       "Forward table must have no duplicate codes (each case owns a unique slot).")
        XCTAssertEqual(Set(tableCodes), expectedDistinctCodes,
                       "Forward table must cover EXACTLY the codes the getter emits (1...75 except 27, plus 99). A diff here means a new/renamed/removed case is untested.")
        XCTAssertEqual(Self.forwardTable.count, 75,
                       "Forward table must enumerate all 75 emittable codes — a new AppError case without a row here is a wire-contract gap.")
    }

    // MARK: - Locked isRetryable flags (load-bearing)

    func testLockedRetryableFlags() {
        // ttsContentBlocked (41): a safety-filter block is terminal — retrying
        // the same text won't pass; fall straight to the Apple voice.
        XCTAssertFalse(AppError.ttsContentBlocked.isRetryable,
                       ".ttsContentBlocked (41) must NOT auto-retry — the safety filter won't change its verdict.")
        // remoteAgentOutOfCredits (52) / remoteAgentRateLimited (57): the test
        // for terminal is "the identical request meets the identical refusal",
        // and neither of these passes it. What refused is an account balance and
        // a rate-limit window — state OUTSIDE the request, which each code's own
        // copy instructs the user to change ("Add credits with your provider,
        // then try again"; "Wait a moment, then try again"). Withholding the
        // button gives that instruction and denies the means to obey it, and the
        // user pays in a stranded turn: every attachment re-picked and the prompt
        // retyped to send a request the provider accepts. Do NOT move these back
        // alongside 55/56 to tidy the block up.
        XCTAssertTrue(AppError.remoteAgentOutOfCredits.isRetryable,
                      ".remoteAgentOutOfCredits (52) must offer retry — a topped-up account answers the same request differently.")
        XCTAssertTrue(AppError.remoteAgentRateLimited.isRetryable,
                      ".remoteAgentRateLimited (57) must offer retry — a rate-limit window expires on its own.")
        // Retryable is not auto-retried. Both fall through `maxAttempts` to 1,
        // so the retry is the user's own tap and a premature one cannot burn
        // budget: 402 means there is no balance to spend, and 429 doesn't bill.
        XCTAssertEqual(AppError.remoteAgentOutOfCredits.maxAttempts, 1,
                       ".remoteAgentOutOfCredits (52) must stay at one attempt — the affordance is a tap, not a loop.")
        XCTAssertEqual(AppError.remoteAgentRateLimited.maxAttempts, 1,
                       ".remoteAgentRateLimited (57) must stay at one attempt — an automatic re-fire deepens the rate limit.")
        // Their neighbours in the same 55-57 block are the contrast: a wrong
        // model name and an overflowing history are facts OF the request, so
        // re-firing it unchanged reaches the identical answer.
        XCTAssertFalse(AppError.remoteAgentModelUnavailable.isRetryable,
                       ".remoteAgentModelUnavailable (55) is terminal — the same model name is still wrong.")
        XCTAssertFalse(AppError.remoteAgentContextTooLong.isRetryable,
                       ".remoteAgentContextTooLong (56) is terminal — the same history still overflows the window.")
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

    // MARK: - Certificate-not-trusted family (63-66)

    func testCertUntrustedCodesAreDistinctFromCertMismatch() {
        // The whole point of 63-66: a chain this device REJECTED must never
        // decode as a pin disagreement. Sharing a slot would put "update the
        // pinned fingerprint, or remove the pin to use system trust" — advice
        // that cannot work, because system trust is what refused — in front of
        // a user whose only real fix is on the server.
        let untrusted: [(String, AppError, Int)] = [
            ("remoteAgentCertUntrusted", .remoteAgentCertUntrusted, 63),
            ("sttCustomCertUntrusted", .sttCustomCertUntrusted, 64),
            ("ttsCustomCertUntrusted", .ttsCustomCertUntrusted, 65),
            ("fileTransferCertUntrusted", .fileTransferCertUntrusted, 66),
        ]
        let mismatchCodes = Set([
            AppError.remoteAgentCertMismatch.errorCode,
            AppError.sttCustomCertMismatch.errorCode,
            AppError.ttsCustomCertMismatch.errorCode,
            AppError.fileTransferCertMismatch.errorCode,
        ])
        for (name, error, code) in untrusted {
            XCTAssertEqual(error.errorCode, code, "\(name) must own code \(code).")
            XCTAssertFalse(mismatchCodes.contains(error.errorCode),
                           "\(name) must not share a code with the *CertMismatch family — the two carry opposite remedies.")
            XCTAssertEqual(AppError.from(errorCode: code, message: nil).errorCode, code,
                           "Code \(code) must round-trip through from(errorCode:) — the Watch relay decodes this slot.")
            XCTAssertFalse(error.isRetryable,
                           "\(name) is terminal — this device refuses the same certificate on every attempt.")
        }
    }

    func testCertUntrustedFamilyShipsOneSharedRemedy() {
        // One cause, one remedy. Four paraphrases of "get the server a trusted
        // certificate" would read as four different problems, so every lane
        // returns `CertificateTrustCopy.untrustedRemedy` verbatim.
        let remedy = CertificateTrustCopy.untrustedRemedy
        for error in [AppError.remoteAgentCertUntrusted, .sttCustomCertUntrusted,
                      .ttsCustomCertUntrusted, .fileTransferCertUntrusted] {
            XCTAssertEqual(error.recoverySuggestion, remedy,
                           "Code \(error.errorCode) must render the SHARED untrusted-certificate remedy verbatim.")
        }
    }

    // MARK: - Pin-mismatch family (30/35/43/47)

    func testCertMismatchFamilyShipsOneSharedRemedy() {
        // Same rule as the untrusted family, for the same reason. The mismatch
        // verdict now fires ONLY after the system accepted the chain, so every
        // lane is looking at the same interception shape and must say the same
        // thing. `.ttsCustomCertMismatch` is included deliberately: it used to
        // fall through to the generic "Try again." on a verdict its own
        // `isRetryable` calls terminal.
        let remedy = CertificateTrustCopy.pinMismatchRemedy
        for error in [AppError.remoteAgentCertMismatch, .sttCustomCertMismatch,
                      .ttsCustomCertMismatch, .fileTransferCertMismatch] {
            XCTAssertEqual(error.recoverySuggestion, remedy,
                           "Code \(error.errorCode) must render the SHARED pin-mismatch remedy verbatim.")
            XCTAssertFalse(error.isRetryable,
                           "Code \(error.errorCode) is terminal — the same key meets the same pin on every attempt.")
        }
    }

    func testCertMismatchCopyWarnsAndNeverOffersToDropThePin() {
        // The load-bearing half: a pin that disagreed with a TRUSTED chain is the
        // one case where pinning caught something real, so the copy must name the
        // risk — and must never suggest removing the control that caught it, or
        // claim a certificate changed when the app cannot know that.
        for error in [AppError.remoteAgentCertMismatch, .sttCustomCertMismatch,
                      .ttsCustomCertMismatch, .fileTransferCertMismatch] {
            let copy = "\(error.errorDescription ?? "") \(error.recoverySuggestion ?? "")".lowercased()
            XCTAssertTrue(copy.contains("intercepted"),
                          "Code \(error.errorCode) must warn that the connection may be intercepted.")
            XCTAssertFalse(copy.contains("remove the pin"),
                           "Code \(error.errorCode) must not offer to drop the pin that caught the problem.")
            XCTAssertFalse(copy.contains("changed."),
                           "Code \(error.errorCode) must not assert the certificate changed — nothing may have.")
            XCTAssertFalse(copy.contains("try again"),
                           "Code \(error.errorCode) is terminal — it must not invite a retry.")
            XCTAssertFalse(copy.contains("is running"),
                           "Code \(error.errorCode) must not send the user to check whether the server is running.")
        }
    }

    func testDescriptionWithRecoveryDropsTheGenericFallback() {
        // The single-line surfaces (the file-transfer checklist, the setup
        // guide's inline status, the pairing sheet's file stage) render this. It
        // must carry a real remedy and must NOT bolt "Try again." onto a verdict
        // that cannot be retried.
        XCTAssertEqual(AppError.fileTransferCertUntrusted.descriptionWithRecovery,
                       "\(AppError.fileTransferCertUntrusted.errorDescription ?? "") \(CertificateTrustCopy.untrustedRemedy)")
        // `.audioMissingData` carries no recovery arm, so it lands on the
        // generic fallback — which this property drops rather than appends.
        // (If it ever earns a real remedy, this fails and wants a case that
        // still falls through; it must not be relaxed into a tautology.)
        XCTAssertEqual(AppError.audioMissingData.descriptionWithRecovery,
                       AppError.audioMissingData.errorDescription)
    }

    /// 52 splits its copy the way the taxonomy intends — cause in
    /// `errorDescription`, remedy in `recoverySuggestion` — so the two-slot
    /// surfaces (Diagnostics' cause/fix rows, the gateway editor, Shortcuts'
    /// `NSLocalizedRecoverySuggestionErrorKey`) each get the half they render.
    /// Collapsing both halves back into the description strands those surfaces
    /// on the generic "Try again.", which tells a user with no credit to retry
    /// a request their provider will refuse identically every time.
    func testOutOfCreditsCarriesItsRemedyInTheRecoverySlot() throws {
        let remedy = try XCTUnwrap(AppError.remoteAgentOutOfCredits.recoverySuggestion)
        XCTAssertNotEqual(remedy, AppError.audioMissingData.recoverySuggestion,
                          "52 must ship its own remedy, not the generic fallback.")
        XCTAssertTrue(remedy.localizedCaseInsensitiveContains("credit"),
                      "52's remedy must name the balance the user has to top up. Got: \(remedy)")
        // The cause line states the symptom and nothing else. Leaving the
        // instruction in BOTH halves makes the rejoined single line say it twice.
        let cause = try XCTUnwrap(AppError.remoteAgentOutOfCredits.errorDescription)
        XCTAssertFalse(cause.localizedCaseInsensitiveContains("try again"),
                       "The cause line must not carry the remedy's call to action. Got: \(cause)")
        // The single-line surfaces rejoin the halves, so they read exactly as
        // they did when the description carried both sentences itself.
        XCTAssertEqual(AppError.remoteAgentOutOfCredits.descriptionWithRecovery,
                       "\(cause) \(remedy)")
    }

    func testCertUntrustedCopyNeverClaimsTheCertificateChanged() {
        // "changed" implies an active attack on a configuration the user never
        // touched. Nothing changed — the certificate was never trustable here.
        for error in [AppError.remoteAgentCertUntrusted, .sttCustomCertUntrusted,
                      .ttsCustomCertUntrusted, .fileTransferCertUntrusted] {
            let copy = "\(error.errorDescription ?? "") \(error.recoverySuggestion ?? "")".lowercased()
            XCTAssertFalse(copy.contains("changed"),
                           "Code \(error.errorCode) must not tell the user the certificate changed.")
            XCTAssertFalse(copy.contains("remove the pin"),
                           "Code \(error.errorCode) must not offer to drop the pin — system trust is what refused.")
            XCTAssertFalse(copy.contains("is running"),
                           "Code \(error.errorCode) must not send the user to check whether the server is running.")
        }
    }

    // MARK: - Key-cannot-be-fingerprinted family (67-70)

    private static let keyUnpinnableFamily: [AppError] = [
        .remoteAgentCertKeyUnpinnable, .sttCustomCertKeyUnpinnable,
        .ttsCustomCertKeyUnpinnable, .fileTransferCertKeyUnpinnable,
    ]

    func testCertKeyUnpinnableCodesAreDistinctFromBothCertificateRefusals() {
        // 67-70 exist because the other two families would both LIE here. The
        // chain is system-trusted and nothing disagreed with anything — Conduck
        // just cannot hash this key algorithm — so a mismatch code would warn of
        // interception that isn't happening, and an untrusted code would send the
        // user to fix a server that is already correct.
        let otherCertificateCodes = Set([
            AppError.remoteAgentCertMismatch.errorCode, AppError.sttCustomCertMismatch.errorCode,
            AppError.ttsCustomCertMismatch.errorCode, AppError.fileTransferCertMismatch.errorCode,
            AppError.remoteAgentCertUntrusted.errorCode, AppError.sttCustomCertUntrusted.errorCode,
            AppError.ttsCustomCertUntrusted.errorCode, AppError.fileTransferCertUntrusted.errorCode,
        ])
        for (error, code) in zip(Self.keyUnpinnableFamily, 67...70) {
            XCTAssertEqual(error.errorCode, code, "Code \(code) is reserved for this lane's unpinnable-key verdict.")
            XCTAssertFalse(otherCertificateCodes.contains(error.errorCode),
                           "Code \(code) must not share a slot with either certificate-refusal family.")
            XCTAssertEqual(AppError.from(errorCode: code, message: nil).errorCode, code,
                           "Code \(code) must round-trip through from(errorCode:) — the Watch relay decodes this slot.")
            XCTAssertFalse(error.isRetryable,
                           "Code \(code) is terminal — the same key meets the same prefix table on every attempt.")
        }
    }

    func testCertKeyUnpinnableFamilyShipsOneSharedRemedy() {
        // Same rule as the other two families: one cause, one remedy, verbatim.
        for error in Self.keyUnpinnableFamily {
            XCTAssertEqual(error.recoverySuggestion, CertificateTrustCopy.keyUnpinnableRemedy,
                           "Code \(error.errorCode) must render the SHARED unpinnable-key remedy verbatim.")
        }
    }

    func testCertKeyUnpinnableCopyNeverWarnsOfInterceptionAndDoesOfferToClearThePin() {
        // Both halves are load-bearing and pull in opposite directions from the
        // mismatch family's rules, which is why they are locked here.
        //
        // NEVER "intercepted": this arm is reached only after system trust
        // PASSED. A false interception warning on a good certificate is how users
        // learn to dismiss the real one.
        //
        // MUST offer clearing the saved fingerprint: that phrase is banned
        // everywhere else in the app because it normally means "switch off the
        // control that just caught something". Here nothing was caught, and
        // dropping the pin returns the connection to the system trust that is
        // already passing — so it is a real remedy, and a later reader deleting it
        // as a rule violation must trip this test.
        for error in Self.keyUnpinnableFamily {
            let copy = "\(error.errorDescription ?? "") \(error.recoverySuggestion ?? "")".lowercased()
            XCTAssertFalse(copy.contains("intercepted"),
                           "Code \(error.errorCode) must NOT warn of interception — system trust passed.")
            XCTAssertTrue(copy.contains("fingerprint"),
                          "Code \(error.errorCode) must name the fingerprint check as the thing that could not run.")
            XCTAssertTrue(copy.contains("clear the saved fingerprint"),
                          "Code \(error.errorCode) must keep the one legitimate offer to drop a pin — see the remedy's doc comment.")
            XCTAssertFalse(copy.contains("try again"),
                           "Code \(error.errorCode) is terminal — it must not invite a retry.")
            XCTAssertFalse(copy.contains("is running"),
                           "Code \(error.errorCode) must not send the user to check whether the server is running.")
            XCTAssertFalse(copy.contains("changed"),
                           "Code \(error.errorCode) must not assert the certificate changed — nothing did.")
        }
    }
}
