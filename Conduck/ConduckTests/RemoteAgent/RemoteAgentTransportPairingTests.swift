// SPDX-License-Identifier: Apache-2.0

// Conduck
// RemoteAgentTransportPairingTests.swift
//
// Locks that a converse send reads the trust verdict of the session it actually
// issued through.
//
// `RemoteAgentClient.send` used to take the session and the evaluator as two
// separate optional parameters defaulting to `URLSession.shared` and `nil`. A
// comment beside them said, correctly, that `.shared` cannot carry a delegate and
// so a production send on it silently disables pinning AND the cross-origin
// redirect refusal. Nothing enforced it: every call site happened to be right,
// and a new one could take the default and lose both controls with no diagnostic
// anywhere — the failure looks exactly like success.
//
// `Transport` makes the pair the only shape. What a test can prove at RUNTIME is
// the consequence: a `.pinned` transport carries its evaluator's verdict all the
// way into the error the user sees, and an `.unevaluated` one has no verdict to
// carry and must therefore report a `-999` as the benign cancel it is rather than
// inventing a certificate story. What a test cannot prove is the compile-time
// half — that a Release build has no way to build an unevaluated transport at all
// — because a test that could construct one would be the counter-example. That
// half is `#if DEBUG` on `Transport.unevaluated`, and this file exists to state
// where the line falls.
//
// Deterministic + headless: `MockURLProtocol` transport, a real `SecTrust` over
// the bundled fixture certificate, no network and no Keychain.

import XCTest
@testable import Conduck

final class RemoteAgentTransportPairingTests: XCTestCase {

    private var session: URLSession!
    private let baseURL = URL(string: "https://gateway.example.test")!

    override func setUp() {
        super.setUp()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        session = URLSession(configuration: config)
    }

    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        session.invalidateAndCancel()
        session = nil
        super.tearDown()
    }

    func testAPinnedTransportCarriesItsEvaluatorsVerdictIntoTheSurfacedError() async throws {
        // The evaluator refused a challenge because the pinned key disagreed with
        // a chain the system TRUSTED. URLSession reports that refusal as a bare
        // `-999`, byte-identical to the user tapping Cancel, so the verdict on the
        // evaluator is the ONLY thing that can tell the two apart — and it can
        // only be read if the transport carried the evaluator across.
        let trust = try fixtureTrust()
        let evaluator = RemoteAgentTrustEvaluator(
            pinnedFingerprintHex: String(repeating: "ab", count: 32),
            evaluateSystemTrust: { _ in true })
        XCTAssertEqual(evaluator.decide(serverTrust: trust), .cancel,
                       "Precondition: the fixture's key cannot match this pin, so the evaluator must refuse.")

        MockURLProtocol.requestHandler = { _ in throw URLError(.cancelled) }

        do {
            _ = try await RemoteAgentClient.shared.send(
                backend: .openclaw,
                url: baseURL,
                token: "test-token",
                newUserText: "hello",
                fileServerReady: false,
                transport: .pinned(session: session, evaluator: evaluator)
            )
            XCTFail("A refused challenge must not resolve as a reply.")
        } catch {
            XCTAssertEqual(error.unwrappedAppError?.errorCode,
                           AppError.remoteAgentCertMismatch.errorCode,
                           "The pin verdict must reach the user. A send that dropped the evaluator sees only -999 and reports a benign cancel — the interception signal, discarded. Got: \(error)")
        }
    }

    func testAnUnevaluatedTransportInfersNoCertificateVerdict() async {
        // The other half of the same property: with no evaluator there is no
        // verdict, and the mapping must NOT infer one. That property is
        // unchanged — but the expectation it used to be spelled with is not.
        //
        // This case previously asserted `CancellationError`, which conflated two
        // different events: `URLError.cancelled` (-999) is what a USER cancel
        // looks like AND what a peer-side stream reset looks like. Nothing here
        // cancels the enclosing task, so this is the peer case, and it must
        // classify as a transport failure — otherwise the failure writers persist
        // no classification at all and the turn renders the bare generic
        // "wasn't delivered" copy with no cause and no Diagnostics record. The
        // cancel half is covered by
        // `RemoteAgentClientTests.testUserCancelledTaskStillMapsToBenignCancellationError`.
        MockURLProtocol.requestHandler = { _ in throw URLError(.cancelled) }

        do {
            _ = try await RemoteAgentClient.shared.send(
                backend: .openclaw,
                url: baseURL,
                token: "test-token",
                newUserText: "hello",
                fileServerReady: false,
                transport: .unevaluated(session: session)
            )
            XCTFail("Expected the cancelled transport failure to propagate.")
        } catch {
            let code = error.unwrappedAppError?.errorCode
            XCTAssertEqual(code, AppError.remoteAgentUnreachable.errorCode,
                           "A -999 on a lane that answered no challenge must classify as unreachable. Got: \(error)")
            XCTAssertNotEqual(code, AppError.remoteAgentCertMismatch.errorCode,
                              "No evaluator means no verdict — a certificate error must never be inferred.")
            XCTAssertNotEqual(code, AppError.remoteAgentCertUntrusted.errorCode,
                              "No evaluator means no verdict — a certificate error must never be inferred.")
        }
    }

    func testAPinnedTransportKeepsTheEvaluatorItWasBuiltWith() {
        // The structural claim, asserted directly: the pair cannot be separated in
        // transit. `makePinnedForegroundSession` is the production source of both
        // halves, and the transport must hand back the same evaluator object — a
        // transport that quietly rebuilt or dropped it would read verdicts off an
        // evaluator that answered no challenge.
        let (pinnedSession, evaluator) = RemoteAgentClient.makePinnedForegroundSession(
            pinnedFingerprintHex: String(repeating: "cd", count: 32))
        defer { pinnedSession.invalidateAndCancel() }

        let transport = RemoteAgentClient.Transport.pinned(session: pinnedSession, evaluator: evaluator)

        XCTAssertTrue(transport.evaluator === evaluator,
                      "The transport must carry the evaluator installed on the session, not another one.")
        XCTAssertTrue(transport.session === pinnedSession)
    }

    // MARK: - Helpers

    private func fixtureTrust() throws -> SecTrust {
        let bundle = Bundle(for: type(of: self))
        let url = try XCTUnwrap(bundle.url(forResource: "test-cert", withExtension: "der"),
                                "Fixture test-cert.der missing from the test bundle Resources")
        let cert = try XCTUnwrap(SecCertificateCreateWithData(nil, try Data(contentsOf: url) as CFData),
                                 "Failed to parse the fixture as a DER certificate")
        var trust: SecTrust?
        let status = SecTrustCreateWithCertificates(cert, SecPolicyCreateBasicX509(), &trust)
        XCTAssertEqual(status, errSecSuccess, "SecTrustCreateWithCertificates failed (\(status))")
        return try XCTUnwrap(trust)
    }
}
