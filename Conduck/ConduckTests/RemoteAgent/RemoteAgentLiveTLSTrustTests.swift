// SPDX-License-Identifier: Apache-2.0

// Conduck
// RemoteAgentLiveTLSTrustTests.swift
//
// The pinning tests that run against a REAL TLS handshake. Every other trust
// test in the suite drives a policy helper directly or stubs the transport with
// `MockURLProtocol` — which proves the LOGIC but can never prove that URLSession
// actually hands the challenge to the evaluator on the live lane. That
// distinction is the whole point: if the delegate is not wired to the session,
// requests keep succeeding, they just stop verifying the certificate. The bug
// looks exactly like success.
//
// The trick that makes it testable: `SecTrust` has no public constructor for an
// arbitrary chain, but nobody has to build one. Stand up a real HTTPS server
// with a self-signed cert on loopback and URLSession constructs a genuine
// `SecTrust` and hands it to the challenge handler. Constructing a
// `RemoteAgentTrustEvaluator(pinnedFingerprintHex:)` with a literal pin needs no
// Keychain and no App Group, so the pin path itself has no entitlement
// dependency (the macOS host still has to be signed to launch at all).
//
// TWO GROUPS, AND WHY THE FILE IS SPLIT THAT WAY
//
// The trust rule is that a pin is an ADDITIONAL restriction on a connection the
// system ALREADY trusts — it can never rescue an untrusted chain. So a pinned
// request over a chain the system rejects is cancelled BEFORE any digest is
// compared. The fixture's certificates are self-signed, i.e. untrusted by
// construction, and that single fact splits everything this file can prove:
//
//   GROUP A — no stub. The fixture's chain is genuinely untrusted, so these
//   prove the fail-closed property itself: an untrusted certificate is refused
//   no matter what the pin says, and the refusal is attributed to the
//   CERTIFICATE rather than to a key mismatch. This is the most important group
//   in the file — it is the only place the rule meets a real TLS stack.
//
//   GROUP B — `makeTrustStubbedForegroundSession` / `TrustStubbedFileLaneDelegate`
//   substitute a SUCCEEDING system-trust verdict for the one the loopback
//   fixture can never earn, standing in for "this device trusts this chain".
//   The handshake, the `SecTrust`, and every decision taken after it are still
//   real, so everything post-handshake stays testable: the pin compare, the
//   redirect policy, the converse send, the file lane's task-carried pin.
//   Without the substitution none of those code paths is reachable here at all.
//
// WHAT IS PROVEN HERE (each one live, end to end):
//   1. An untrusted chain is REFUSED even when the configured pin matches it
//      exactly — for EC P-256 AND RSA-2048, the two SPKI-prefix families the V1
//      table covers — and the refusal records `systemTrustRejected`, never
//      `pinRejected`.
//   2. The app's SPKI digest equals the canonical
//      `openssl x509 -pubkey | openssl pkey -pubin -outform DER | dgst -sha256`
//      value, computed here by OPENSSL — never by calling the app's own
//      `spkiDER(from:)`, so a drifting recipe fails instead of agreeing with
//      itself. The digest is captured before the trust branch, so a REFUSED
//      connection still carries it and the drift guard survives group A.
//   3. On a chain the system trusts, a MISMATCHED pin fails, is attributable to
//      the certificate (`.certMismatch` / `.remoteAgentCertMismatch`, not a
//      generic cancel), and the request body + bearer header never reach the
//      server (asserted against the fixture's own hit counter, not just the
//      client's error).
//   4. A cross-ORIGIN 3xx is refused — by port, by HOST NAME, and by scheme
//      downgrade — while a same-origin 3xx is still followed. The two HTTPS
//      listeners deliberately present THE SAME KEY, so the pin cannot tell them
//      apart and only the origin compare can refuse the hop. That is the
//      "same key is not same origin" limit the production comments call out,
//      turned into a test.
//   5. The macOS converse send path (the `makePinnedForegroundSession` recipe +
//      `RemoteAgentClient.send`) pins and refuses redirects on the LIVE hop.
//   6. The file lane's task-level challenge handler applies the pin carried on
//      `taskDescription`, host-blind, against a real challenge — refuses a
//      cross-origin 3xx on the `.default` session macOS actually ships, and
//      inherits the same fail-closed rule on an untrusted chain.
//
// WHAT IS NOT PROVEN — do not read this file as retiring these:
//   - APP TRANSPORT SECURITY. Loopback is ATS-EXEMPT (traffic routes via `lo0`),
//     so nothing here exercises ATS's own requirements. Every refusal below is
//     the APP's posture: our evaluator's explicit `SecTrustEvaluateWithError`
//     and its fail-closed branch, plus ordinary chain validation on the
//     default-handling path. That is the point — the app must refuse an
//     untrusted certificate on its own, not by relying on ATS to kill it, and
//     that is exactly the property a loopback fixture CAN test.
//   - iOS BACKGROUND sessions. `willPerformHTTPRedirection` is never delivered
//     there (SDK contract), and a mid-upload jetsam + relaunch still needs a
//     signed device. The host-blind task pin is the only pushback on that lane
//     and only its RESOLUTION is unit-tested
//     (`BackgroundFileTransferPinDurabilityTests`).
//   - A pin whose value comes from the Keychain / App Group on a signed device.
//     Every pin here is a literal.
//   - The macOS call SITES. They are `#if os(macOS)` branches inside the view
//     model / drainer with no injection seam; this file drives the same
//     composition they build (`RemoteAgentClientTests` locks that the factory
//     installs the evaluator and what its configuration is).
//   - A MITM holding a PUBLICLY-TRUSTED certificate. Group B's stub is the
//     closest this file gets: it says "the system trusts this chain" and then
//     shows the pin still refusing the wrong key. Against a real publicly-
//     trusted attacker cert an unpinned request would SUCCEED, which is why
//     `testAMismatchedPinOnATrustedChainStillClassifiesAsACertMismatch` asserts
//     on `evaluator.pinRejected` and on the classification, not merely on "it
//     failed" — verified by control: degrading the mismatch arm to
//     `.performDefaultHandling` leaves the request failing and fails ONLY that
//     assertion.
//
// HOW TO RUN — `scripts/run-live-tls-tests.sh`, NOT a plain `xcodebuild test`.
// The macOS test host is the sandboxed Conduck app, and the App Sandbox denies
// `bind()` to it and to every process it spawns, so the HTTPS fixture cannot be
// started from inside a test. The script starts it outside the sandbox and hands
// over the ports + the openssl-derived pins through the app's own container.
// Without a fixture every case here SKIPS with that instruction — visibly, and
// never as a pass. macOS-only: the sandbox is what forces the split, and the
// converse send path this locks is the macOS one.

#if os(macOS)

import Foundation
import XCTest
@testable import Conduck

final class RemoteAgentLiveTLSTrustTests: XCTestCase {

    /// The running fixture, or an `XCTSkip` naming the runner script. Re-read per
    /// test (it is one small JSON read); every assertion below is expressed as a
    /// DELTA on the fixture's hit counter, so a shared server leaks no state
    /// between cases.
    private var fixture: LoopbackTLSFixture!

    override func setUpWithError() throws {
        try super.setUpWithError()
        fixture = try LoopbackTLSFixture.loadOrSkip()
    }

    // MARK: - GROUP A — an untrusted chain is refused, whatever the pin says
    //
    // No stub anywhere in this group: the fixture's self-signed certificate is
    // the real subject. These are the cases that would have caught a pin being
    // treated as a licence to accept an untrusted chain.

    func testAnUntrustedChainIsRefusedEvenWhenTheECP256PinMatches() async throws {
        let before = try await fixture.hits()
        let (session, evaluator) = RemoteAgentClient.makePinnedForegroundSession(
            pinnedFingerprintHex: fixture.ecPin)
        defer { session.invalidateAndCancel() }

        _ = await fixture.expectTransportFailure(
            session: session,
            request: fixture.request(port: fixture.portA, path: "/probe/ec-match"))

        XCTAssertTrue(evaluator.systemTrustRejected,
                      "A pin is an ADDITIONAL restriction on a chain the system already trusts, never a rescue for one it rejects. A matching pin over an untrusted leaf must still be refused, and the refusal must be recorded as a TRUST rejection.")
        XCTAssertFalse(evaluator.pinRejected,
                       "The evaluator bails BEFORE comparing digests, so a pin that would have matched must not be reported as a key mismatch — the actionable problem is the untrusted certificate.")
        XCTAssertEqual(evaluator.presentedFingerprintHex, fixture.ecPin,
                       "DRIFT GUARD: the app's SPKI digest of a real EC P-256 leaf must equal the value openssl produces — that value is the pin users compute and paste. A wrong ASN.1 prefix would fail every real gateway. The digest is captured before the trust branch, so it is still populated on a REFUSED connection; that is what keeps this guard alive now that the connection is refused.")
        let after = try await fixture.hits()
        XCTAssertEqual(after.delta(from: before, key: "tlsA /probe/ec-match"), 0,
                       "Fail closed means fail before the body: the request must never reach a server whose certificate this device does not trust.")
    }

    func testAnUntrustedChainIsRefusedEvenWhenTheRSA2048PinMatches() async throws {
        let (session, evaluator) = RemoteAgentClient.makePinnedForegroundSession(
            pinnedFingerprintHex: fixture.rsaPin)
        defer { session.invalidateAndCancel() }

        _ = await fixture.expectTransportFailure(
            session: session,
            request: fixture.request(port: fixture.portRSA, path: "/probe/rsa-match"))

        XCTAssertTrue(evaluator.systemTrustRejected,
                      "The fail-closed rule is about the CHAIN, not about the key algorithm — an RSA leaf gets the same refusal as an EC one.")
        XCTAssertFalse(evaluator.pinRejected)
        XCTAssertEqual(evaluator.presentedFingerprintHex, fixture.rsaPin,
                       "DRIFT GUARD (RSA arm): the RSA-2048 SPKI prefix must produce the openssl digest too — RSA and EC are separate prefix entries in the V1 table and only a live cert of each proves both.")
    }

    /// Ordering test, and deliberately not symmetric: when a certificate is
    /// untrusted AND the pin disagrees, the verdict is `.untrustedCert`. Saying
    /// "certificate mismatch" there would imply a MITM the user cannot act on,
    /// when the truthful, actionable statement is that this device does not
    /// trust the certificate at all. Group B holds the counterpart — a
    /// mismatched pin on a TRUSTED chain still classifies as `.certMismatch`.
    func testAnUntrustedChainWithAMismatchedPinClassifiesAsUntrustedNotAsAMismatch() async throws {
        let before = try await fixture.hits()
        let (session, evaluator) = RemoteAgentClient.makePinnedForegroundSession(
            pinnedFingerprintHex: Self.impossiblePin)
        defer { session.invalidateAndCancel() }

        let error = await fixture.expectTransportFailure(
            session: session,
            request: fixture.request(port: fixture.portA, path: "/probe/mismatch"))
        let urlError = try XCTUnwrap(error as? URLError,
                                     "A cancelled server-trust challenge must surface as a URLError.")

        XCTAssertTrue(evaluator.systemTrustRejected,
                      "The system-trust evaluation runs on EVERY challenge now, pinned or not, so the untrusted chain is recorded even though a pin was configured.")
        XCTAssertFalse(evaluator.pinRejected,
                       "We never reach the comparison, so nothing may claim the key was wrong.")
        XCTAssertEqual(
            RemoteAgentTrustEvaluator.classifyTransportError(
                urlError.code, signals: evaluator.attemptSignals),
            .untrustedCert,
            "The live failure code (\(urlError.code.rawValue)) must classify as UNTRUSTED, not as unreachable/cancelled and not as a mismatch. `systemTrustRejected` outranks `pinRejected` precisely so this case reads as the certificate problem it is.")
        XCTAssertEqual(
            (RemoteAgentClient.mapTransportError(urlError.code, signals: evaluator.attemptSignals,
            isTaskCancelled: false
        ) as? AppError)?.errorCode,
            AppError.remoteAgentCertUntrusted.errorCode,
            "The user must see the UNTRUSTED-certificate error, whose remedy is on the server. A silent cancel here is the failure mode that looks like success; a mismatch here would send them to edit a fingerprint that was never consulted.")

        let after = try await fixture.hits()
        XCTAssertEqual(after.delta(from: before, key: "tlsA /probe/mismatch"), 0,
                       "The request must never reach the server: TLS is refused before the body and the `Authorization` header go out.")
    }

    /// The intrinsic control for the whole file: the fixture's cert is NOT
    /// trusted by this machine, so a request that carries no pin must fail. If it
    /// ever passes, the fixture has been trusted somehow (added to a keychain,
    /// say) and every group A refusal above stops meaning anything.
    ///
    /// HONEST SCOPE — this does NOT prove App Transport Security. Loopback is
    /// ATS-exempt, so ATS's own requirements never apply to any request in this
    /// file. What it proves is the APP's posture: the evaluator runs its explicit
    /// `SecTrustEvaluateWithError` on the unpinned path too and RECORDS the
    /// rejection (so the lanes a user converses on can report a certificate
    /// problem rather than a transient hiccup), and the connection is refused by
    /// ordinary chain validation on the default-handling path.
    func testAnUnpinnedRequestToTheSelfSignedFixtureIsRefusedAndRecordedAsUntrusted() async throws {
        let before = try await fixture.hits()
        let (session, evaluator) = RemoteAgentClient.makePinnedForegroundSession(
            pinnedFingerprintHex: nil)
        defer { session.invalidateAndCancel() }

        _ = await fixture.expectTransportFailure(
            session: session,
            request: fixture.request(port: fixture.portA, path: "/probe/no-pin"))

        XCTAssertTrue(evaluator.systemTrustRejected,
                      "System-trust evaluation must run on the NO-PIN challenge too — that is the signal that turns an opaque TLS failure into 'this device does not trust this certificate', which is a terminal, explained refusal rather than a retry.")
        XCTAssertFalse(evaluator.pinRejected,
                       "No pin configured means the evaluator never cancels for a key mismatch — the refusal came from the system on the default-handling path.")
        let after = try await fixture.hits()
        XCTAssertEqual(after.delta(from: before, key: "tlsA /probe/no-pin"), 0)
    }

    /// The file lane inherits the same rule, on the shipping delegate object
    /// itself — no forwarder, no stub. A task-carried pin that MATCHES the leaf
    /// still cannot buy an untrusted chain a transfer.
    func testFileLaneRefusesAnUntrustedChainEvenWhenTheTaskPinMatches() async throws {
        let before = try await fixture.hits()
        let session = fixture.fileLaneSession(delegate: BackgroundFileTransfer.shared)
        defer { session.invalidateAndCancel() }

        let outcome = await fixture.runFileLaneTask(
            session: session, port: fixture.portA, path: "/probe/file-untrusted",
            taskDescription: Self.fileLaneTaskDescription(pin: fixture.ecPin))

        XCTAssertNil(outcome.statusCode,
                     "An untrusted chain must abort the transfer at the TLS layer — no HTTP response at all, even with a matching pin.")
        let code = try XCTUnwrap(outcome.urlErrorCode,
                                 "Expected a transport failure, got: \(outcome.errorDescription ?? "success")")
        XCTAssertTrue(Self.certRejectionCodes.contains(code),
                      "A cancelled server-trust challenge must surface as a TLS/cancel failure the lane maps to a certificate error. Got \(code.rawValue).")
        let after = try await fixture.hits()
        XCTAssertEqual(after.delta(from: before, key: "tlsA /probe/file-untrusted"), 0,
                       "File bytes and the `Authorization: Basic` credential must never reach a server this device does not trust.")
    }

    // MARK: - GROUP B — post-handshake behaviour, over a stubbed trust verdict
    //
    // Everything below substitutes a SUCCEEDING system-trust verdict (see
    // `makeTrustStubbedForegroundSession`) for the one the loopback fixture can
    // never earn. The handshake is still real and the `SecTrust` is still real;
    // only the "does this device trust the chain" answer is supplied. Without it
    // the evaluator fails closed and none of these code paths is reachable.

    // MARK: Pin compare, on a chain the system trusts

    func testAMatchingPinOnATrustedChainIsAccepted() async throws {
        let (session, evaluator) = Self.makeTrustStubbedForegroundSession(
            pinnedFingerprintHex: fixture.ecPin)
        defer { session.invalidateAndCancel() }

        let (data, response) = try await session.data(
            for: fixture.request(port: fixture.portA, path: "/probe/ec-match-trusted"))

        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200,
                       "A cert whose SPKI digest equals the configured pin, on a chain the device trusts, must be accepted — a pin that blocks the happy path is not a security control, it is an outage.")
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "MARKER-TLS-A")
        XCTAssertFalse(evaluator.pinRejected,
                       "A matching pin must not record a rejection.")
        XCTAssertFalse(evaluator.systemTrustRejected,
                       "Sanity check on the stub itself: if this were true the trust substitution is not in effect and the acceptance above proves nothing.")
    }

    /// The counterpart to group A's ordering test: strip the untrusted-chain
    /// confound and a mismatched pin must STILL be attributable to the
    /// certificate. This is the property that survives a MITM holding a
    /// publicly-trusted cert, so losing it would gut pinning entirely.
    func testAMismatchedPinOnATrustedChainStillClassifiesAsACertMismatch() async throws {
        let before = try await fixture.hits()
        let (session, evaluator) = Self.makeTrustStubbedForegroundSession(
            pinnedFingerprintHex: Self.impossiblePin)
        defer { session.invalidateAndCancel() }

        let error = await fixture.expectTransportFailure(
            session: session,
            request: fixture.request(port: fixture.portA, path: "/probe/mismatch-trusted"))
        let urlError = try XCTUnwrap(error as? URLError,
                                     "A cancelled server-trust challenge must surface as a URLError.")

        XCTAssertTrue(evaluator.pinRejected,
                      "The evaluator must RECORD that it cancelled for a pin mismatch — that flag is the only thing that tells a MITM apart from the user tapping Cancel.")
        XCTAssertFalse(evaluator.systemTrustRejected,
                       "The chain is trusted in this scenario; if this flips, the test has silently become group A's and the mismatch classification below is not being exercised.")
        XCTAssertEqual(
            RemoteAgentTrustEvaluator.classifyTransportError(
                urlError.code, signals: evaluator.attemptSignals),
            .certMismatch,
            "The live failure code (\(urlError.code.rawValue)) must classify as a certificate MISMATCH, not as unreachable/cancelled.")
        XCTAssertEqual(
            (RemoteAgentClient.mapTransportError(urlError.code, signals: evaluator.attemptSignals,
            isTaskCancelled: false
        ) as? AppError)?.errorCode,
            AppError.remoteAgentCertMismatch.errorCode,
            "The user must see 'certificate mismatch'. A silent cancel here is the failure mode that looks like success.")

        let after = try await fixture.hits()
        XCTAssertEqual(after.delta(from: before, key: "tlsA /probe/mismatch-trusted"), 0,
                       "The request must never reach the server: TLS is refused before the body and the `Authorization` header go out.")
    }

    // MARK: Redirect policy, live

    func testCrossOriginRedirectToADifferentPortIsRefused() async throws {
        let before = try await fixture.hits()
        let (session, _) = Self.makeTrustStubbedForegroundSession(
            pinnedFingerprintHex: fixture.ecPin)
        defer { session.invalidateAndCancel() }

        let (data, response) = try await session.data(
            for: fixture.request(port: fixture.portA, path: "/redirect/cross-port"))

        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 302,
                       "A refused redirect completes the task with the 3xx itself, which every caller already classifies as a failure.")
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("LEAK"))
        let after = try await fixture.hits()
        XCTAssertEqual(after.delta(from: before, key: "tlsB /v1/chat/completions"), 0,
                       "The redirect target must never be contacted. It presents THE SAME KEY as the origin, so the pin waves it through — only the origin compare stops the body + bearer header from being replayed there.")
    }

    func testCrossHostRedirectToTheSameListenerIsRefused() async throws {
        let before = try await fixture.hits()
        let (session, _) = Self.makeTrustStubbedForegroundSession(
            pinnedFingerprintHex: fixture.ecPin)
        defer { session.invalidateAndCancel() }

        let (_, response) = try await session.data(
            for: fixture.request(port: fixture.portA, path: "/redirect/cross-host"))

        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 302)
        let after = try await fixture.hits()
        XCTAssertEqual(after.delta(from: before, key: "tlsA /__leak"), 0,
                       "`localhost` and `127.0.0.1` resolve to the SAME listener with the SAME cert on the SAME port — only the host NAME differs. Refusing it proves the compare is on the origin triple, not on reachability or on the key.")
    }

    func testSchemeDowngradeRedirectIsRefused() async throws {
        let before = try await fixture.hits()
        let (session, _) = Self.makeTrustStubbedForegroundSession(
            pinnedFingerprintHex: fixture.ecPin)
        defer { session.invalidateAndCancel() }

        let (_, response) = try await session.data(
            for: fixture.request(port: fixture.portA, path: "/redirect/downgrade"))

        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 302)
        let after = try await fixture.hits()
        XCTAssertEqual(after.delta(from: before, key: "plain /__leak"), 0,
                       "https is an app-wide invariant; a 3xx must never be able to downgrade the hop to cleartext.")
    }

    /// The discriminator: the policy must not be a blanket redirect block, or
    /// every reverse proxy that canonicalises a path would break.
    func testSameOriginRedirectIsFollowed() async throws {
        let before = try await fixture.hits()
        let (session, _) = Self.makeTrustStubbedForegroundSession(
            pinnedFingerprintHex: fixture.ecPin)
        defer { session.invalidateAndCancel() }

        let (data, response) = try await session.data(
            for: fixture.request(port: fixture.portA, path: "/redirect/same-origin"))

        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200,
                       "A same-origin 3xx is ordinary and must be followed.")
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "MARKER-TLS-A")
        let after = try await fixture.hits()
        XCTAssertEqual(after.delta(from: before, key: "tlsA /ok"), 1,
                       "The redirect target on the same origin must actually be reached.")
    }

    // MARK: The macOS converse send path

    func testMacConverseSendRefusesAMismatchedPin() async throws {
        let before = try await fixture.hits()
        let (session, evaluator) = Self.makeTrustStubbedForegroundSession(
            pinnedFingerprintHex: Self.impossiblePin)
        defer { session.invalidateAndCancel() }

        do {
            _ = try await RemoteAgentClient.shared.send(
                backend: .openclaw,
                url: fixture.baseURL(port: fixture.portA),
                token: Self.bearerToken,
                newUserText: "hello",
                fileServerReady: false,
                transport: .pinned(session: session, evaluator: evaluator))
            XCTFail("A converse send against a mismatched pin must FAIL. Succeeding here means the send path is not pinning.")
        } catch {
            XCTAssertEqual(error.unwrappedAppError?.errorCode,
                           AppError.remoteAgentCertMismatch.errorCode,
                           "The live send must surface a certificate error, not a cancel or a generic 'unreachable'. Got: \(error)")
        }

        let after = try await fixture.hits()
        XCTAssertEqual(after.delta(from: before, key: "tlsA /v1/chat/completions"), 0,
                       "The conversation history and the bearer token must never leave the device when the pin does not match.")
    }

    func testMacConverseSendSucceedsOnAMatchingPin() async throws {
        let before = try await fixture.hits()
        let (session, evaluator) = Self.makeTrustStubbedForegroundSession(
            pinnedFingerprintHex: fixture.ecPin)
        defer { session.invalidateAndCancel() }

        let reply = try await RemoteAgentClient.shared.send(
            backend: .openclaw,
            url: fixture.baseURL(port: fixture.portA),
            token: Self.bearerToken,
            newUserText: "hello",
            fileServerReady: false,
            transport: .pinned(session: session, evaluator: evaluator))

        XCTAssertEqual(reply.text, "LIVE-REPLY-tlsA",
                       "A correctly pinned gateway on a trusted chain must still answer — a pin that blocks the happy path is not a security control, it is an outage.")
        let after = try await fixture.hits()
        XCTAssertEqual(after.delta(from: before, key: "tlsA /v1/chat/completions"), 1)
    }

    func testMacConverseSendDoesNotFollowACrossOriginRedirect() async throws {
        let before = try await fixture.hits()
        let (session, evaluator) = Self.makeTrustStubbedForegroundSession(
            pinnedFingerprintHex: fixture.ecPin)
        defer { session.invalidateAndCancel() }

        do {
            _ = try await RemoteAgentClient.shared.send(
                backend: .openclaw,
                // `/xredirect/v1/chat/completions` answers 302 → another origin.
                url: fixture.baseURL(port: fixture.portA).appending(path: "xredirect"),
                token: Self.bearerToken,
                newUserText: "hello",
                fileServerReady: false,
                transport: .pinned(session: session, evaluator: evaluator))
            XCTFail("A redirecting gateway must surface as a visible failure, never as a silently re-pointed turn.")
        } catch {
            // Which AppError the 302 lands on is the status/decode layer's
            // business; what this test owns is that the hop did not happen.
        }

        let after = try await fixture.hits()
        XCTAssertEqual(after.delta(from: before, key: "tlsB /v1/chat/completions"), 0,
                       "A 302 must not replay the full client-owned history + bearer header at a host the user never configured — even when that host presents the pinned key.")
    }

    // MARK: The file-transfer lane's task-level trust handler

    /// `BackgroundFileTransfer` IS the session delegate on the lane it drives.
    /// On macOS that session is a `.default` configuration — exactly what this
    /// test builds — so the handler under test here is the shipping one, driven
    /// by a real challenge with a real `SecTrust`
    /// (`TrustStubbedFileLaneDelegate` forwards INTO it and adds no policy).
    ///
    /// On iOS the same delegate runs on a BACKGROUND configuration. The pin
    /// compare is identical there, but the redirect callback is never delivered
    /// and a mid-upload relaunch cannot be reproduced in-process — that part
    /// still needs a signed device.
    func testFileLaneAppliesTheTaskCarriedPinToALiveChallenge() async throws {
        let before = try await fixture.hits()
        let delegate = TrustStubbedFileLaneDelegate()
        let session = fixture.fileLaneSession(delegate: delegate)
        defer { session.invalidateAndCancel() }

        let mismatch = await fixture.runFileLaneTask(
            session: session, port: fixture.portA, path: "/probe/file-mismatch",
            taskDescription: Self.fileLaneTaskDescription(pin: Self.impossiblePin))
        XCTAssertNil(mismatch.statusCode,
                     "A task-pin mismatch must abort the transfer at the TLS layer — no HTTP response at all.")
        let code = try XCTUnwrap(mismatch.urlErrorCode,
                                 "Expected a transport failure, got: \(mismatch.errorDescription ?? "success")")
        XCTAssertTrue(Self.certRejectionCodes.contains(code),
                      "A cancelled server-trust challenge must surface as one of the codes CFNetwork is observed to report for it. Got \(code.rawValue).")

        let match = await fixture.runFileLaneTask(
            session: session, port: fixture.portA, path: "/probe/file-match",
            taskDescription: Self.fileLaneTaskDescription(pin: fixture.ecPin))
        XCTAssertEqual(match.statusCode, 200,
                       "The same handler must ACCEPT the matching task-carried pin, or the lane is simply broken rather than pinned. Error: \(match.errorDescription ?? "none")")
        XCTAssertEqual(match.body.map { String(decoding: $0, as: UTF8.self) }, "MARKER-TLS-A")

        let after = try await fixture.hits()
        XCTAssertEqual(after.delta(from: before, key: "tlsA /probe/file-mismatch"), 0,
                       "File bytes and the `Authorization: Basic` credential must never reach a server that fails the pin.")
        XCTAssertEqual(after.delta(from: before, key: "tlsA /probe/file-match"), 1)
    }

    func testFileLaneRefusesACrossOriginRedirect() async throws {
        let before = try await fixture.hits()
        let delegate = TrustStubbedFileLaneDelegate()
        let session = fixture.fileLaneSession(delegate: delegate)
        defer { session.invalidateAndCancel() }

        let outcome = await fixture.runFileLaneTask(
            session: session, port: fixture.portA, path: "/redirect/cross-port",
            taskDescription: Self.fileLaneTaskDescription(pin: fixture.ecPin))

        XCTAssertEqual(outcome.statusCode, 302,
                       "A refused redirect completes the task with the 3xx itself. Error: \(outcome.errorDescription ?? "none")")
        let after = try await fixture.hits()
        XCTAssertEqual(after.delta(from: before, key: "tlsB /v1/chat/completions"), 0,
                       "macOS ships this lane on a `.default` session, so the redirect veto is real there and must hold. (iOS runs it on a background session, which never receives the callback — the host-blind pin is the only mitigation there.)")
    }

    // MARK: - Fixtures

    /// TEST-ONLY. The production foreground converse session recipe over an
    /// evaluator whose SYSTEM-TRUST verdict is stubbed to SUCCEED — group B's
    /// stand-in for "this device trusts this chain".
    ///
    /// WHY IT HAS TO EXIST: a pin is an ADDITIONAL restriction on a chain the
    /// system already trusts, so a pinned request over an untrusted chain is
    /// cancelled BEFORE any digest is compared. The fixture can only serve
    /// self-signed certificates and no test can make this machine trust one, so
    /// without the substitution nothing that happens AFTER a completed handshake
    /// — the pin compare, the redirect policy, the converse send — is reachable
    /// here at all. The handshake, the `SecTrust`, and every decision taken over
    /// it remain real; only the trust verdict is supplied.
    ///
    /// FENCED BY LIVING IN THE TEST TARGET: `private`, inside the test case, in a
    /// file the app target does not compile, so no production call site can reach
    /// it whatever the injection point's own access level allows. The
    /// `{ _ in true }` closure exists nowhere else; production gets
    /// `RemoteAgentTrustEvaluator`'s default, `SecTrustEvaluateWithError`.
    ///
    /// The CONFIGURATION is lifted off `RemoteAgentClient.makePinnedForegroundSession`
    /// rather than re-declared, so the shipping recipe (`.ephemeral`, the converse
    /// timeouts, the cache posture) is what these tests run on and a drift in it
    /// reaches them instead of quietly bypassing them. Only the delegate differs,
    /// which is the one thing that cannot be injected into that factory.
    private static func makeTrustStubbedForegroundSession(
        pinnedFingerprintHex: String?
    ) -> (session: URLSession, evaluator: RemoteAgentTrustEvaluator) {
        let (recipe, _) = RemoteAgentClient.makePinnedForegroundSession(
            pinnedFingerprintHex: pinnedFingerprintHex)
        let configuration = recipe.configuration
        recipe.invalidateAndCancel()

        let evaluator = RemoteAgentTrustEvaluator(
            pinnedFingerprintHex: pinnedFingerprintHex,
            evaluateSystemTrust: { _ in true })
        return (URLSession(configuration: configuration, delegate: evaluator, delegateQueue: nil),
                evaluator)
    }

    /// 64 hex chars no certificate will ever hash to.
    private static let impossiblePin = String(repeating: "ff", count: 32)

    /// A stand-in bearer. Never asserted on except by absence — the fixture's
    /// hit counter proves the request carrying it never went out.
    private static let bearerToken = "test-token-never-sent"

    /// The codes URLSession is observed to use for a challenge the delegate
    /// cancelled. Which one arrives is a CFNetwork detail (`.cancelled` in
    /// practice), so the assertion accepts the whole observed set.
    ///
    /// THIS SET IS NOT A MAPPING CLAIM. What the user is told comes from the
    /// per-task trust NOTE the lane's challenge handler recorded, not from the
    /// code: a pinned-key rejection over a chain the system trusted reaches them
    /// as `.fileTransferCertMismatch` on any of these three, and an untrusted
    /// chain as `.fileTransferCertUntrusted` on any of them. Without a note,
    /// `.secureConnectionFailed` deliberately stays `.fileTransferUnreachable` —
    /// a generic `-1200` is a cold-tunnel handshake hiccup as often as a trust
    /// rejection. `BackgroundFileTransferTrustVerdictTests` owns those mappings;
    /// this set is tolerated here only as codes the refusal may surface as.
    private static let certRejectionCodes: Set<URLError.Code> = [
        .cancelled, .secureConnectionFailed, .serverCertificateUntrusted,
    ]

    private static func fileLaneTaskDescription(pin: String) -> String {
        FileTransferBackgroundMetadata(
            storedKey: "abc123__note.txt",
            refSuffix: "openclaw",
            direction: .upload,
            pinnedFingerprintHex: pin
        ).encoded()!
    }
}

// MARK: - The loopback TLS fixture

/// Four listeners on 127.0.0.1, all bound on port 0, fronted by two self-signed
/// certificates generated at run time:
///
/// | listener | scheme | certificate | role |
/// |---|---|---|---|
/// | `tlsA`   | https | EC P-256 (identity 1) | the "gateway" |
/// | `tlsB`   | https | EC P-256 (identity 1 — **the same key**) | cross-origin redirect target |
/// | `tlsRSA` | https | RSA-2048 (identity 2) | the second SPKI prefix family |
/// | `plain`  | http  | — | scheme-downgrade redirect target |
///
/// `tlsB` sharing `tlsA`'s key is the load-bearing detail: a pin compare proves
/// "same key", not "same origin", so with identical keys the pin cannot refuse
/// the cross-origin hop and ONLY `willPerformHTTPRedirection` can. Give them
/// different keys and the redirect tests would pass for the wrong reason.
///
/// Every request is counted under `"<role> <path>"` and the tally is served at
/// `GET /__hits`, so a test asserts the redirect target was NEVER CONTACTED
/// rather than merely that the client reported an error.
///
/// WHY THIS TYPE ONLY READS A HANDOFF FILE: the macOS test host is the sandboxed
/// Conduck app, and the App Sandbox denies `bind()` to it and to every process
/// it spawns — a self-starting fixture dies with
/// `PermissionError: [Errno 1] Operation not permitted` before a socket exists.
/// The only entitlement that would lift that is
/// `com.apple.security.network.server`, which a client-only app must not ship to
/// make a test run. So `scripts/run-live-tls-tests.sh` starts the fixture
/// outside the sandbox and drops its ports + the openssl-derived pins into the
/// app's own container tmp, which the sandboxed test CAN read.
///
/// `nonisolated … @unchecked Sendable`: the module compiles with
/// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, and this is plain Foundation
/// state read once per test.
nonisolated final class LoopbackTLSFixture: @unchecked Sendable {

    /// `FileManager.temporaryDirectory` resolves to
    /// `~/Library/Containers/<bundle id>/Data/tmp` under the sandbox — the one
    /// directory both the runner script (outside) and the test (inside) can see.
    static var handoffURL: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("conduck-live-tls-fixture.json")
    }

    private struct Handoff: Decodable {
        let tlsA: Int
        let tlsB: Int
        let tlsRSA: Int
        let plain: Int
        let ecPin: String
        let rsaPin: String
    }

    let ecPin: String
    let rsaPin: String
    let portA: Int
    let portB: Int
    let portRSA: Int
    let portPlain: Int

    // MARK: Lifecycle

    /// The fixture for this run, or an `XCTSkip` naming exactly how to get one.
    /// A malformed handoff is a hard ERROR, not a skip: a pin that is not 64 hex
    /// would make every "match" assertion compare two mistakes.
    static func loadOrSkip() throws -> LoopbackTLSFixture {
        guard let data = try? Data(contentsOf: handoffURL) else {
            throw XCTSkip("""
                NOT RUN — no loopback TLS fixture is up, so nothing here was verified.
                These are the only tests that prove the certificate pin is ENFORCED on a \
                real TLS handshake (every other trust test drives a policy helper or a \
                MockURLProtocol stub). A plain `xcodebuild test` cannot run them: the \
                sandboxed macOS test host is denied bind(), so the fixture has to be \
                started from outside. Run:

                    scripts/run-live-tls-tests.sh

                Expected handoff file: \(handoffURL.path)
                """)
        }
        let handoff = try JSONDecoder().decode(Handoff.self, from: data)
        for pin in [handoff.ecPin, handoff.rsaPin] {
            guard pin.count == 64, pin.allSatisfy(\.isHexDigit) else {
                throw FixtureError("handoff pin is not a 64-char hex digest: '\(pin)'")
            }
        }
        return LoopbackTLSFixture(handoff: handoff)
    }

    private init(handoff: Handoff) {
        self.ecPin = handoff.ecPin
        self.rsaPin = handoff.rsaPin
        self.portA = handoff.tlsA
        self.portB = handoff.tlsB
        self.portRSA = handoff.tlsRSA
        self.portPlain = handoff.plain
    }

    // MARK: Requests

    func baseURL(port: Int) -> URL { URL(string: "https://127.0.0.1:\(port)")! }

    func request(port: Int, path: String) -> URLRequest {
        var request = URLRequest(url: URL(string: "https://127.0.0.1:\(port)\(path)")!)
        // Not the converse budget: a loopback listener that does not answer is a
        // bug to surface in seconds, not in five minutes.
        request.timeoutInterval = 15
        return request
    }

    /// Run a request that is EXPECTED to fail and return the error. Fails the
    /// calling test if it succeeds — a pinning test that silently tolerates
    /// success is the exact hazard this file exists to remove.
    func expectTransportFailure(session: URLSession, request: URLRequest,
                                file: StaticString = #filePath, line: UInt = #line) async -> Error? {
        do {
            let (_, response) = try await session.data(for: request)
            XCTFail("Expected the request to FAIL, but it completed with \((response as? HTTPURLResponse)?.statusCode ?? -1).",
                    file: file, line: line)
            return nil
        } catch {
            return error
        }
    }

    /// The file lane's macOS recipe verbatim: a `.default` session whose
    /// delegate makes the trust and redirect decisions.
    ///
    /// Group A passes `BackgroundFileTransfer.shared` — the shipping object
    /// itself, no wrapper. Group B passes `TrustStubbedFileLaneDelegate`, which
    /// forwards both callbacks straight into that same object's methods and only
    /// substitutes the system-trust verdict; the pin resolution, the pin compare
    /// and the redirect veto are still the shipping code either way.
    func fileLaneSession(delegate: URLSessionDelegate) -> URLSession {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 15
        // No cache: every assertion here is a hit-count DELTA, and a cached
        // response would satisfy the client without touching the server.
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.urlCache = nil
        return URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }

    /// What a file-lane task ended with, reduced to `Sendable` values so the
    /// completion handler can hand it back across the continuation.
    struct FileLaneOutcome: Sendable {
        let statusCode: Int?
        let body: Data?
        let urlErrorCode: URLError.Code?
        let errorDescription: String?
    }

    /// Drive one task on the file lane. The completion-handler form (not
    /// `data(for:)`) is required: the lane's pin rides on `taskDescription`,
    /// which can only be set on a task the caller owns before `resume()` — and
    /// URLSession still routes the auth challenge and the redirect to the
    /// session delegate for a completion-handler task.
    func runFileLaneTask(session: URLSession, port: Int, path: String,
                         taskDescription: String) async -> FileLaneOutcome {
        await withCheckedContinuation { continuation in
            let task = session.dataTask(with: request(port: port, path: path)) { data, response, error in
                let urlError = error as? URLError
                continuation.resume(returning: FileLaneOutcome(
                    statusCode: (response as? HTTPURLResponse)?.statusCode,
                    body: data,
                    urlErrorCode: urlError?.code,
                    errorDescription: error.map { "\($0)" }))
            }
            task.taskDescription = taskDescription
            task.resume()
        }
    }

    // MARK: Hit counter

    /// The fixture's own bookkeeping, fetched with a permissive delegate so it
    /// never depends on the code under test.
    func hits() async throws -> [String: Int] {
        let session = URLSession(configuration: .ephemeral,
                                 delegate: AcceptAnyTrust(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (data, _) = try await session.data(for: request(port: portA, path: "/__hits"))
        return try JSONDecoder().decode([String: Int].self, from: data)
    }

    struct FixtureError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { "Loopback TLS fixture: \(message)" }
    }
}

// MARK: - Test-only delegates

/// Trusts anything. Used ONLY by the fixture's own `/__hits` bookkeeping, which
/// must not depend on the code under test.
private nonisolated final class AcceptAnyTrust: NSObject, URLSessionDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}

/// GROUP B's file-lane delegate. Forwards BOTH callbacks under test straight
/// into `BackgroundFileTransfer.shared`'s own methods and adds no policy of its
/// own: the pin resolution off `taskDescription`, the evaluator it builds, the
/// pin compare, and the cross-origin redirect veto are all the SHIPPING code.
/// The only substitution is the system-trust verdict passed to
/// `respondToTaskTrustChallenge` — the "this device trusts this chain" answer
/// the loopback fixture cannot earn, without which the lane fails closed before
/// it ever compares a digest or sees a 3xx.
///
/// It exists ONLY because the trust handler is a delegate callback with nowhere
/// to inject from the outside. Group A drives `BackgroundFileTransfer.shared`
/// directly, with no forwarder at all, so the shipping composition is still
/// exercised end to end somewhere in this file.
///
/// Living in the test target is one fence; `#if DEBUG` on
/// `respondToTaskTrustChallenge(…evaluateSystemTrust:)` is the other, and the
/// load-bearing one — the method it forwards to does not exist in a Release
/// build, so no shipping code can pass `{ _ in true }` even by accident.
///
/// The tasks driven through here carry a COMPLETION HANDLER, so URLSession never
/// delivers `didCompleteWithError` to a delegate and the trust note this records
/// on `BackgroundFileTransfer.shared` is never consumed. Harmless: that
/// singleton drives no real transfer in a test process, and each note is one
/// `Int`. Production tasks are delegate-driven and always reach the terminal
/// callback that consumes theirs.
private nonisolated final class TrustStubbedFileLaneDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {

    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        BackgroundFileTransfer.shared.respondToTaskTrustChallenge(
            session,
            task: task,
            challenge: challenge,
            evaluateSystemTrust: { _ in true },
            completionHandler: completionHandler)
    }

    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        BackgroundFileTransfer.shared.urlSession(
            session,
            task: task,
            willPerformHTTPRedirection: response,
            newRequest: request,
            completionHandler: completionHandler)
    }
}

private extension Dictionary where Key == String, Value == Int {
    /// How many times `key` was hit between two snapshots.
    func delta(from before: [String: Int], key: String) -> Int {
        (self[key] ?? 0) - (before[key] ?? 0)
    }
}

#endif
