// SPDX-License-Identifier: Apache-2.0

// Conduck
// ATSTransportClassTests.swift
//
// Covers the `-1022` arm of `RemoteAgentTrustEvaluator.classifyTransportError`
// and the `AppError` it resolves to.
//
// WHY IT IS ITS OWN ARM, and why these assertions matter: App Transport
// Security refuses a plain-http request to a host iOS does not consider local
// from the URL STRING, before any TCP connect. Measured on iOS 26.5, an
// unroutable PUBLIC literal returns -1022 in 0.01 s — which is what proves the
// decision precedes the connect. So the class is never a reachability fact,
// never uncertain about delivery, and never retryable. Before this arm existed
// the code fell into `default: .unreachable`, which told the user to go and
// check a server the request never reached.

import XCTest
@testable import Conduck

final class ATSTransportClassTests: XCTestCase {

    private typealias Signals = RemoteAgentTrustEvaluator.AttemptTrustSignals

    /// The arm runs FIRST, so no trust verdict may alter it: nothing shook
    /// hands, which means any verdict in the snapshot belongs to a different
    /// attempt and must not colour this one.
    func testATSRefusalClassifiesAsBlockedByATSRegardlessOfTrustSignals() {
        XCTAssertEqual(
            RemoteAgentTrustEvaluator.classifyTransportError(
                .appTransportSecurityRequiresSecureConnection, signals: .empty),
            .blockedByATS)

        let systemRejected = Signals(
            systemTrustRejected: true,
            challengeRefused: true,
            pinRejected: false,
            pinComparisonUnsupported: false
        )
        XCTAssertEqual(
            RemoteAgentTrustEvaluator.classifyTransportError(
                .appTransportSecurityRequiresSecureConnection, signals: systemRejected),
            .blockedByATS,
            "No handshake happened, so an objection recorded on some other attempt must not turn this into a certificate verdict.")

        let pinRejected = Signals(
            systemTrustRejected: false,
            challengeRefused: true,
            pinRejected: true,
            pinComparisonUnsupported: false
        )
        XCTAssertEqual(
            RemoteAgentTrustEvaluator.classifyTransportError(
                .appTransportSecurityRequiresSecureConnection, signals: pinRejected),
            .blockedByATS)
    }

    /// The neighbouring classes must be untouched — this is the regression the
    /// classifier has already suffered once, in the other direction.
    func testOtherTransportClassesAreUnchanged() {
        XCTAssertEqual(RemoteAgentTrustEvaluator.classifyTransportError(.timedOut, signals: .empty), .timeout)
        XCTAssertEqual(RemoteAgentTrustEvaluator.classifyTransportError(.cannotFindHost, signals: .empty), .notEstablished)
        XCTAssertEqual(RemoteAgentTrustEvaluator.classifyTransportError(.notConnectedToInternet, signals: .empty), .offline)
        XCTAssertEqual(RemoteAgentTrustEvaluator.classifyTransportError(.secureConnectionFailed, signals: .empty), .unreachable,
                       "A cold tunnel's generic -1200 with no verdict recorded stays unreachable.")
    }

    /// Every code that means "the device's own route" classifies `.offline` —
    /// no network at all, cellular data denied, roaming off abroad, a call
    /// holding the radio. Leaving any of them to the `default:` unreachable arm
    /// re-opens the bug the class exists for: a failure that is entirely local
    /// reported as a problem with the user's server, and (on the file lane) a
    /// one-strike cooldown that suppresses the folder on the retry sent once
    /// the connection is back.
    func testDeviceSideRouteCodesAllClassifyOffline() {
        for code: URLError.Code in [
            .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff, .callIsActive
        ] {
            XCTAssertEqual(
                RemoteAgentTrustEvaluator.classifyTransportError(code, signals: .empty),
                .offline,
                "\(code) never left the device and says nothing about any server")
        }
    }

    func testBlockedByATSIsNotRetryable() {
        XCTAssertFalse(AppError.insecureConnectionBlocked.isRetryable,
                       "The verdict is computed from the URL string, so a retry is guaranteed to produce the same answer.")
        XCTAssertEqual(AppError.insecureConnectionBlocked.maxAttempts, 1)
        XCTAssertFalse(AppError.insecureConnectionBlocked.shouldPreserveForRetry,
                       "Preserving audio for a retry that cannot succeed only strands it.")
    }

    /// The background lane cannot read per-challenge signals, so it carries its
    /// own URL-code map. The two must stay in lockstep — that is stated in
    /// `mapURLError`'s comment and pinned here.
    func testBackgroundMapperAgreesWithTheClassifier() {
        XCTAssertEqual(
            BackgroundRemoteAgent.mapURLError(URLError(.appTransportSecurityRequiresSecureConnection)).errorCode,
            AppError.insecureConnectionBlocked.errorCode)
    }

    func testGatewayClientMapsItToTheLaneNeutralCode() {
        let mapped = RemoteAgentClient.mapTransportError(
            .appTransportSecurityRequiresSecureConnection,
            signals: .empty,
            isTaskCancelled: false)
        XCTAssertEqual((mapped as? AppError)?.errorCode, AppError.insecureConnectionBlocked.errorCode)
    }

    /// The copy: names Apple as the refuser ("Apple", not "iOS" — the string
    /// also renders on the Mac), names the fixes, and carries no jargon. It is
    /// also deliberately short — the cause line is a notification title and a
    /// Watch banner.
    func testCopyNamesThePlatformAndBothFixes() {
        let cause = AppError.insecureConnectionBlocked.errorDescription ?? ""
        let recovery = AppError.insecureConnectionBlocked.recoverySuggestion ?? ""
        XCTAssertTrue(cause.contains("Apple"))
        XCTAssertLessThanOrEqual(cause.count, 48, "The wrist holds roughly 38 characters over two lines.")
        XCTAssertTrue(recovery.contains("https://"))
        XCTAssertTrue(recovery.lowercased().contains("ip address"))
        for jargon in ["ATS", "App Transport Security", "-1022", "RFC1918"] {
            XCTAssertFalse(cause.contains(jargon), jargon)
            XCTAssertFalse(recovery.contains(jargon), jargon)
        }
    }

    /// A pasted diagnostics report must not read like a dead server.
    func testDiagnosticsSlugIsRegistered() {
        XCTAssertEqual(DiagnosticsExplainer.slug(forCode: AppError.insecureConnectionBlocked.errorCode),
                       "insecure-connection-blocked")
    }
}
