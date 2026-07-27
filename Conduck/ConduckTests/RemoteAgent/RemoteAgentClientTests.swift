// SPDX-License-Identifier: Apache-2.0

// Conduck
// RemoteAgentClientTests.swift
//
// Full round-trip tests of `RemoteAgentClient.send(...)` via
// MockURLProtocol. Each test scripts a single gateway response (status +
// body) and asserts the client either returns the expected reply text or
// throws the expected `AppError` case.
//
// Per-test URLSession creation (NOT shared) — MockURLProtocol stores its
// handler statically, so any shared session would cross-contaminate
// concurrent test execution. The teardown explicitly nils the handler
// for the same reason.

import XCTest
@testable import Conduck

final class RemoteAgentClientTests: XCTestCase {

    private var session: URLSession!
    private let baseURL = URL(string: "https://gateway.example.test")!
    private let token = "secret-token-do-not-log"

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

    // MARK: - Happy path — full client-owned history (backend-agnostic)

    func testHappyPathSendsFullHistoryWithNoSessionWireFields() async throws {
        var capturedRequest: URLRequest?
        var capturedBody: Data?

        MockURLProtocol.requestHandler = { request in
            capturedRequest = request
            // URLProtocol intercepts hide `httpBody`; the stream is set on
            // the request and must be read explicitly when needed.
            capturedBody = request.httpBody ?? Self.readStreamBody(request)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            let payload = #"{"choices":[{"message":{"content":"hi"}}]}"#
            return (response, Data(payload.utf8))
        }

        // A 2-turn prior history (user → agent); the client appends the new
        // user turn → a 3-message messages[] array on the wire.
        let prior: [ConverseRequest.Message] = [
            .init(role: "user", content: "first question"),
            .init(role: "assistant", content: "first answer"),
        ]

        let reply = try await RemoteAgentClient.shared.send(
            backend: .openclaw,
            url: baseURL,
            token: token,
            priorTurns: prior,
            newUserText: "follow-up",
            fileServerReady: false,
            session: session
        )

        XCTAssertEqual(reply, "hi")

        let req = try XCTUnwrap(capturedRequest)
        XCTAssertEqual(req.url?.path, "/v1/chat/completions",
                       "Request path must end in /v1/chat/completions")
        XCTAssertEqual(req.httpMethod, "POST")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer \(token)")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertNil(req.value(forHTTPHeaderField: "x-openclaw-session-key"),
                     "No session header may be sent under client-owned history")

        let body = try XCTUnwrap(capturedBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertFalse(json.keys.contains("conversation"),
                       "Body must NOT contain a `conversation` key. Got: \(Array(json.keys))")
        XCTAssertEqual(json["stream"] as? Bool, false)

        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 3, "Full history (2 prior + new user turn) must be sent")
        XCTAssertEqual(messages[0]["role"] as? String, "user")
        XCTAssertEqual(messages[0]["content"] as? String, "first question")
        XCTAssertEqual(messages[1]["role"] as? String, "assistant")
        XCTAssertEqual(messages[1]["content"] as? String, "first answer")
        XCTAssertEqual(messages[2]["role"] as? String, "user")
        XCTAssertEqual(messages[2]["content"] as? String, "follow-up")
    }

    func testHermesUsesIdenticalWireShape() async throws {
        // The request is byte-shape-identical for every backend — no
        // x-openclaw-session-key header, no `conversation` body field.
        var capturedRequest: URLRequest?
        var capturedBody: Data?

        MockURLProtocol.requestHandler = { request in
            capturedRequest = request
            capturedBody = request.httpBody ?? Self.readStreamBody(request)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            )!
            let payload = #"{"choices":[{"message":{"content":"hermes reply"}}]}"#
            return (response, Data(payload.utf8))
        }

        let reply = try await RemoteAgentClient.shared.send(
            backend: .hermes,
            url: baseURL,
            token: token,
            priorTurns: [],
            newUserText: "hello",
            fileServerReady: false,
            session: session
        )

        XCTAssertEqual(reply, "hermes reply")

        let req = try XCTUnwrap(capturedRequest)
        XCTAssertNil(req.value(forHTTPHeaderField: "x-openclaw-session-key"),
                     "Hermes MUST NOT send any session header (none exists under client-owned history)")

        let body = try XCTUnwrap(capturedBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertFalse(json.keys.contains("conversation"),
                       "Hermes body must NOT carry a `conversation` field. Got: \(Array(json.keys))")
        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 1, "Empty prior history → just the new user turn")
        XCTAssertEqual(messages[0]["role"] as? String, "user")
        XCTAssertEqual(messages[0]["content"] as? String, "hello")
    }

    // MARK: - Trim policy

    func testTrimPolicyCapsSentArrayAtContextMaxTurns() async throws {
        var capturedBody: Data?
        MockURLProtocol.requestHandler = { request in
            capturedBody = request.httpBody ?? Self.readStreamBody(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data(#"{"choices":[{"message":{"content":"ok"}}]}"#.utf8))
        }

        // Build a prior history LONGER than the cap. Only the last
        // `contextMaxTurns` prior turns should cross the wire; the new user
        // turn is always appended → sent count == cap + 1.
        let cap = Constants.contextMaxTurns
        let prior: [ConverseRequest.Message] = (0..<(cap + 10)).map { i in
            .init(role: i.isMultiple(of: 2) ? "user" : "assistant", content: "turn \(i)")
        }

        _ = try await RemoteAgentClient.shared.send(
            backend: .openclaw,
            url: baseURL,
            token: token,
            priorTurns: prior,
            newUserText: "newest",
            fileServerReady: false,
            session: session
        )

        let body = try XCTUnwrap(capturedBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, cap + 1,
                       "Sent array must be capped at contextMaxTurns prior turns + the new user turn")
        // The newest prior turn (index cap+9) must survive the trim; the
        // oldest (turn 0) must be dropped.
        XCTAssertEqual(messages.first?["content"] as? String, "turn 10",
                       "Trim keeps the SUFFIX (most recent) prior turns; turn 0..9 dropped")
        XCTAssertEqual(messages.last?["role"] as? String, "user")
        XCTAssertEqual(messages.last?["content"] as? String, "newest",
                       "New user turn is always the last message")
    }

    // MARK: - Error mapping

    func test401MapsToAuthFailed() async {
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!
            return (response, Data())
        }

        await assertThrowsAppError(.remoteAgentAuthFailed) {
            try await RemoteAgentClient.shared.send(
                backend: .openclaw, url: self.baseURL, token: self.token,
                newUserText: "hi", fileServerReady: false, session: self.session
            )
        }
    }

    func test500MapsToServerError() async {
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!
            return (response, Data())
        }

        await assertThrowsAppError(.remoteAgentServerError) {
            try await RemoteAgentClient.shared.send(
                backend: .openclaw, url: self.baseURL, token: self.token,
                newUserText: "hi", fileServerReady: false, session: self.session
            )
        }
    }

    func testMalformedJSONMapsToInvalidResponse() async {
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            // Decode failure — completely off-shape body.
            return (response, Data("not json at all".utf8))
        }

        await assertThrowsAppError(.remoteAgentInvalidResponse) {
            try await RemoteAgentClient.shared.send(
                backend: .openclaw, url: self.baseURL, token: self.token,
                newUserText: "hi", fileServerReady: false, session: self.session
            )
        }
    }

    func testCancelledDoesNotMapToCertMismatch() async {
        // CRITICAL FIX: a user-initiated / structured-concurrency cancel
        // must NOT surface as a cert error. The converse path re-throws it
        // as a benign CancellationError; cert-mismatch comes ONLY from the
        // trust-evaluator's server-certificate codes.
        MockURLProtocol.requestHandler = { _ in
            throw URLError(.cancelled)
        }

        do {
            _ = try await RemoteAgentClient.shared.send(
                backend: .openclaw, url: baseURL, token: token,
                newUserText: "hi", fileServerReady: false, session: session
            )
            XCTFail("Expected a thrown error for a cancelled request")
        } catch is CancellationError {
            // Expected — benign cancel, distinct from any .remoteAgent* case.
        } catch let error as AppError {
            XCTFail("Cancelled request must NOT map to an AppError (got \(error)); cert-mismatch must come only from the trust path")
        } catch {
            XCTFail("Expected CancellationError, got \(type(of: error)): \(error)")
        }
    }

    // MARK: - Helpers

    private func assertThrowsAppError(
        _ expected: AppError,
        file: StaticString = #file,
        line: UInt = #line,
        _ block: () async throws -> Void
    ) async {
        do {
            try await block()
            XCTFail("Expected throw of \(expected.errorCode) — got success", file: file, line: line)
        } catch let error as AppError {
            XCTAssertEqual(
                error.errorCode, expected.errorCode,
                "Expected error code \(expected.errorCode), got \(error.errorCode) (\(error))",
                file: file, line: line
            )
        } catch {
            XCTFail("Expected AppError, got \(type(of: error)): \(error)", file: file, line: line)
        }
    }

    // MARK: - Test Connection
    //
    // testConnection probes the gateway with `GET /v1/models` rather than
    // POSTing a converse. Status mapping reuses `backend.statusMap` (the
    // single unified map) so error mapping stays consistent with the
    // converse hop. Tests drive
    // `testConnectionForTesting(...)` so MockURLProtocol intercepts the
    // probe without standing up a real `RemoteAgentTrustEvaluator`-backed
    // ephemeral session (which we can't intercept from the test process).

    func testTestConnectionSuccessAndHeaderShape() async throws {
        var capturedRequest: URLRequest?
        MockURLProtocol.requestHandler = { request in
            capturedRequest = request
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200,
                httpVersion: "HTTP/1.1", headerFields: nil
            )!
            return (response, Data(#"{"data":[{"id":"llama3"}]}"#.utf8))
        }

        let outcome = try await RemoteAgentClient.shared.testConnectionForTesting(
            backend: .openclaw,
            url: baseURL,
            token: token,
            session: session
        )

        // A 2xx alone is NOT a pass — the body must carry the OpenAI model-list
        // envelope (see `validateProbeBody`). An EMPTY `data` array is a separate
        // outcome (`.okNoModels`), so this fixture advertises a model.
        XCTAssertEqual(outcome, .ok, "A 2xx probe with a populated model list must return .ok")

        let req = try XCTUnwrap(capturedRequest)
        XCTAssertEqual(req.httpMethod, "GET")
        XCTAssertEqual(req.url?.path, "/v1/models",
                       "Test Connection MUST hit /v1/models — OpenAI-compatible probe both backends expose.")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer \(token)",
                       "Bearer header MUST be set on the probe — the test verifies auth+connectivity.")
    }

    // The pairing trust matrix must compare the key on the wire against the pin a
    // scanned code claims EVEN WHEN ordinary trust already accepted the chain
    // (`PairingTrustDecision`). `TestConnectionOutcome` carries the presented
    // fingerprint only on its `.untrustedCert` arm, so the success arms would
    // otherwise discard it and make that comparison impossible.
    func testTestConnectionReportRetainsPresentedFingerprintOnSuccess() async throws {
        let liveKey = "a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f90"
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200,
                httpVersion: "HTTP/1.1", headerFields: nil
            )!
            return (response, Data(#"{"data":[{"id":"llama3"}]}"#.utf8))
        }

        let report = try await RemoteAgentClient.shared.testConnectionReportForTesting(
            backend: .openclaw,
            url: baseURL,
            token: token,
            session: session,
            presentedFingerprint: { liveKey }
        )

        XCTAssertEqual(report.outcome, .ok)
        XCTAssertEqual(report.presentedFingerprintHex, liveKey,
                       "The presented leaf fingerprint must survive the SUCCESS path, not just the untrusted-cert path.")
    }

    func testTestConnectionReportRetainsPresentedFingerprintOnEmptyModelList() async throws {
        let liveKey = "0f1e2d3c4b5a69788796a5b4c3d2e1f00f1e2d3c4b5a69788796a5b4c3d2e1f0"
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data(#"{"data":[]}"#.utf8))
        }

        let report = try await RemoteAgentClient.shared.testConnectionReportForTesting(
            backend: .openclaw,
            url: baseURL,
            token: token,
            session: session,
            presentedFingerprint: { liveKey }
        )

        XCTAssertEqual(report.outcome, .okNoModels)
        XCTAssertEqual(report.presentedFingerprintHex, liveKey,
                       "`.okNoModels` is a success arm too — it must retain the fingerprint.")
    }

    func testTestConnectionReportRetainsPresentedFingerprintOnUntrustedCert() async throws {
        let liveKey = "beef0123456789abcdefbeef0123456789abcdefbeef0123456789abcdefbeef"
        MockURLProtocol.requestHandler = { _ in
            throw URLError(.serverCertificateUntrusted)
        }

        let report = try await RemoteAgentClient.shared.testConnectionReportForTesting(
            backend: .openclaw,
            url: baseURL,
            token: token,
            session: session,
            presentedFingerprint: { liveKey },
            systemTrustRejected: { true }
        )

        XCTAssertEqual(report.outcome, .untrustedCert(presentedFingerprintHex: liveKey))
        XCTAssertEqual(report.presentedFingerprintHex, liveKey,
                       "The report's fingerprint must agree with the one embedded in the outcome — one capture, one value.")
    }

    // MARK: - Pairing trust probe (unpinned; handshake-completion semantics)

    /// THE contract that separates this probe from Test Connection: a 401 proves
    /// the TLS handshake was accepted and the password was wrong — two completely
    /// different facts. Test Connection throws on 401, which would make the trust
    /// matrix read an ordinarily-trusted server as unreachable and skip the
    /// pin-contradiction check entirely.
    func testPairingTrustProbeTreatsAnyHTTPResponseAsHandshakeCompletion() async {
        for status in [200, 401, 403, 404, 500] {
            MockURLProtocol.requestHandler = { request in
                let response = HTTPURLResponse(url: request.url!, statusCode: status,
                                               httpVersion: nil, headerFields: nil)!
                return (response, Data(#"{"error":"nope"}"#.utf8))
            }

            let signals = await RemoteAgentClient.shared.pairingTrustProbeForTesting(
                url: baseURL, token: token, payloadPinHex: nil, session: session)

            XCTAssertTrue(signals.requestCompleted,
                          "HTTP \(status) still proves the handshake was accepted.")
            XCTAssertNil(signals.transportClass,
                         "HTTP \(status) is not a transport failure.")
        }
    }

    func testPairingTrustProbeCarriesTheClaimAndThePresentedKey() async {
        let claimed = "a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f90"
        let live = "0f1e2d3c4b5a69788796a5b4c3d2e1f00f1e2d3c4b5a69788796a5b4c3d2e1f0"
        MockURLProtocol.requestHandler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
             Data(#"{"data":[]}"#.utf8))
        }

        let signals = await RemoteAgentClient.shared.pairingTrustProbeForTesting(
            url: baseURL, token: token, payloadPinHex: claimed, session: session,
            presentedFingerprint: { live })

        XCTAssertEqual(signals.payloadPinHex, claimed, "The claim must be carried through for comparison, never probed under.")
        XCTAssertEqual(signals.presentedFingerprintHex, live)
        // Wired end to end: this is the enterprise-inspection row.
        XCTAssertEqual(PairingTrustDecision.decide(signals), .blocked(.pinContradictsLiveServer))
    }

    func testPairingTrustProbeClassifiesAnUntrustedCertificate() async {
        MockURLProtocol.requestHandler = { _ in throw URLError(.serverCertificateUntrusted) }

        let signals = await RemoteAgentClient.shared.pairingTrustProbeForTesting(
            url: baseURL, token: token, payloadPinHex: nil, session: session,
            presentedFingerprint: { "beef0123456789abcdefbeef0123456789abcdefbeef0123456789abcdefbeef" },
            systemTrustRejected: { true })

        XCTAssertFalse(signals.requestCompleted)
        XCTAssertEqual(signals.transportClass, .untrustedCert)
    }

    func testPairingTrustProbeReportsTransientFailureWithoutThrowing() async {
        MockURLProtocol.requestHandler = { _ in throw URLError(.timedOut) }

        let signals = await RemoteAgentClient.shared.pairingTrustProbeForTesting(
            url: baseURL, token: token, payloadPinHex: nil, session: session)

        XCTAssertFalse(signals.requestCompleted)
        XCTAssertEqual(signals.transportClass, .timeout)
        XCTAssertEqual(PairingTrustDecision.decide(signals), .unreachable(.timeout),
                       "Unreachable must be a verdict the matrix can reason about, not an error that aborts the decision.")
    }

    func testTestConnectionUnauthorizedMapsToAuthFailed() async {
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!
            return (response, Data())
        }

        await assertThrowsAppError(.remoteAgentAuthFailed) {
            try await RemoteAgentClient.shared.testConnectionForTesting(
                backend: .openclaw, url: self.baseURL, token: self.token, session: self.session
            )
        }
    }

    func testTestConnectionServerErrorMapsToServerError() async {
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!
            return (response, Data())
        }

        await assertThrowsAppError(.remoteAgentServerError) {
            try await RemoteAgentClient.shared.testConnectionForTesting(
                backend: .openclaw, url: self.baseURL, token: self.token, session: self.session
            )
        }
    }

    func testTestConnectionUnreachableMapsToUnreachable() async {
        MockURLProtocol.requestHandler = { request in
            throw URLError(.cannotConnectToHost)
        }

        await assertThrowsAppError(.remoteAgentUnreachable) {
            try await RemoteAgentClient.shared.testConnectionForTesting(
                backend: .openclaw, url: self.baseURL, token: self.token, session: self.session
            )
        }
    }

    func testTestConnectionPinMismatchStillThrowsCertMismatch() async {
        // PIN SET + cert changed: `RemoteAgentTrustEvaluator` refuses the
        // mismatch via cancelAuthenticationChallenge → URLError(.cancelled)
        // AND sets `pinRejected`. With a pin configured this MUST stay a hard
        // error — never auto-offer re-trust (that defeats pinning). TOFU is
        // offered ONLY when no pin is set. (The mock bypasses the real
        // evaluator, so we inject `pinRejected: { true }` to simulate the
        // genuine-mismatch signal.)
        MockURLProtocol.requestHandler = { request in
            throw URLError(.cancelled)
        }

        await assertThrowsAppError(.remoteAgentCertMismatch) {
            try await RemoteAgentClient.shared.testConnectionForTesting(
                backend: .openclaw, url: self.baseURL, token: self.token,
                session: self.session, hasPin: true,
                pinRejected: { true }
            )
        }
    }

    func testTestConnectionCancelledNoPinIsRetryableNotCert() async {
        // No pin + `.cancelled` (the evaluator never cancels on the no-pin
        // path → this is a real task cancellation). Test Connection has no
        // user-cancel surface, so it surfaces as a retryable transport
        // failure — NOT a cert problem.
        MockURLProtocol.requestHandler = { _ in throw URLError(.cancelled) }
        await assertThrowsAppError(.remoteAgentUnreachable) {
            try await RemoteAgentClient.shared.testConnectionForTesting(
                backend: .openclaw, url: self.baseURL, token: self.token,
                session: self.session, hasPin: false
            )
        }
    }

    func testTestConnectionSecureConnectionFailedTransientIsUnreachable() async {
        // THE REGRESSION: a generic `.secureConnectionFailed` over a cold
        // tunnel (no system rejection) must be a retryable transport failure,
        // NOT a false "untrusted certificate" / pin offer.
        MockURLProtocol.requestHandler = { _ in throw URLError(.secureConnectionFailed) }
        await assertThrowsAppError(.remoteAgentUnreachable) {
            try await RemoteAgentClient.shared.testConnectionForTesting(
                backend: .openclaw, url: self.baseURL, token: self.token,
                session: self.session, hasPin: false,
                systemTrustRejected: { false }
            )
        }
    }

    func testTestConnectionSecureConnectionFailedSystemRejectedIsTOFU() async throws {
        // A genuine no-pin rejection that surfaced via the generic code (the
        // system DID reject) is still a TOFU opportunity.
        MockURLProtocol.requestHandler = { _ in throw URLError(.secureConnectionFailed) }
        let outcome = try await RemoteAgentClient.shared.testConnectionForTesting(
            backend: .openclaw, url: baseURL, token: token,
            session: session, hasPin: false,
            presentedFingerprint: { "abcabcabcabc1234" },
            systemTrustRejected: { true }
        )
        XCTAssertEqual(outcome, .untrustedCert(presentedFingerprintHex: "abcabcabcabc1234"),
                       "A real system rejection (systemTrustRejected) must still offer TOFU even via the generic code.")
    }

    func testTestConnectionSecureConnectionFailedPinTransientIsUnreachable() async {
        // Pinned host on a cold tunnel (no confirmed mismatch) → retryable,
        // NOT a false cert MISMATCH (which would imply a MITM).
        MockURLProtocol.requestHandler = { _ in throw URLError(.secureConnectionFailed) }
        await assertThrowsAppError(.remoteAgentUnreachable) {
            try await RemoteAgentClient.shared.testConnectionForTesting(
                backend: .openclaw, url: self.baseURL, token: self.token,
                session: self.session, hasPin: true,
                pinRejected: { false }
            )
        }
    }

    func testSendSecureConnectionFailedIsUnreachableNotCertMismatch() async {
        // Live converse hop with NO trust evaluator supplied (an unpinned ref, or
        // a mock session): a transient `.secureConnectionFailed` over a cold
        // tunnel must be retryable, NOT a false cert mismatch. Even WITH a
        // pinning session the converse hop keeps this posture unless the
        // evaluator confirms `pinRejected` — see
        // `testGenericTLSFailureOnAPinnedSessionWithoutRejectionStaysRetryable`.
        MockURLProtocol.requestHandler = { _ in throw URLError(.secureConnectionFailed) }
        await assertThrowsAppError(.remoteAgentUnreachable) {
            try await RemoteAgentClient.shared.send(
                backend: .openclaw, url: self.baseURL, token: self.token,
                newUserText: "hi", fileServerReady: false, session: self.session
            )
        }
    }

    func testSendSpecificCertCodeStillMapsToCertMismatch() async {
        // A specific server-certificate code on the live hop still surfaces as
        // a cert mismatch (the system named the cert as the cause).
        MockURLProtocol.requestHandler = { _ in throw URLError(.serverCertificateUntrusted) }
        await assertThrowsAppError(.remoteAgentCertMismatch) {
            try await RemoteAgentClient.shared.send(
                backend: .openclaw, url: self.baseURL, token: self.token,
                newUserText: "hi", fileServerReady: false, session: self.session
            )
        }
    }

    func testTestConnectionUntrustedCertNoPinReturnsTOFUOutcome() async throws {
        // NO pin set + system rejected an untrusted self-signed cert →
        // `.untrustedCert(fp)`: a TOFU opportunity, NOT a thrown error. The
        // captured leaf fingerprint comes from the evaluator (here injected
        // via the test closure).
        let presentedFP = "deadbeefcafef00d"
        MockURLProtocol.requestHandler = { request in
            throw URLError(.serverCertificateUntrusted)
        }

        let outcome = try await RemoteAgentClient.shared.testConnectionForTesting(
            backend: .openclaw, url: baseURL, token: token,
            session: session, hasPin: false,
            presentedFingerprint: { presentedFP }
        )

        XCTAssertEqual(outcome, .untrustedCert(presentedFingerprintHex: presentedFP),
                       "No-pin self-signed rejection must return .untrustedCert with the presented fingerprint (TOFU), not throw.")
    }

    func testTestConnectionUntrustedCertNoPinNoFingerprintStillReturnsTOFU() async throws {
        // Untrusted self-signed, NO pin, but the leaf key algorithm is
        // outside the V1 SPKI prefix table → evaluator captured nil. The
        // outcome is still `.untrustedCert(nil)` (untrusted, no copyable fp)
        // — the UI banner then offers manual pinning instead of one-tap.
        MockURLProtocol.requestHandler = { request in
            throw URLError(.serverCertificateHasUnknownRoot)
        }

        let outcome = try await RemoteAgentClient.shared.testConnectionForTesting(
            backend: .openclaw, url: baseURL, token: token,
            session: session, hasPin: false,
            presentedFingerprint: { nil }
        )

        XCTAssertEqual(outcome, .untrustedCert(presentedFingerprintHex: nil),
                       "Untrusted self-signed with an unsupported key algorithm must still surface .untrustedCert(nil), not throw.")
    }

    func testTestConnectionRequestUsesShortTimeout() {
        // Verify the public `buildTestConnectionRequest` stamps the short-timeout
        // Constant onto the request (load-bearing — the 300s converse
        // budget would leave the user staring at a spinner forever on a
        // wrong URL). Inspecting the request shape directly avoids
        // needing a real timeout to fire mid-test.
        let request = RemoteAgentClient.buildTestConnectionRequest(url: baseURL, token: token)
        XCTAssertEqual(
            request.timeoutInterval,
            Constants.remoteAgentTestConnectionTimeout,
            accuracy: 0.001,
            "Test Connection request must use Constants.remoteAgentTestConnectionTimeout (interactive spinner, NOT the 300s converse budget)."
        )
        XCTAssertEqual(request.timeoutInterval, 15.0,
                       "Drift guard: the locked Constants value is 15s — change here mirrors a change in Constants.swift.")
    }

    func testTestConnectionDoesNotLogToken() async {
        // Privacy invariant: the bearer token must NEVER appear in
        // thrown error messages. Force every error path and assert the
        // localized description / debug description never includes the
        // token literal.
        let secretToken = "super-secret-bearer-DO-NOT-LEAK"
        let cases: [(Int, AppError)] = [
            (401, .remoteAgentAuthFailed),
            (500, .remoteAgentServerError),
        ]
        for (status, expected) in cases {
            MockURLProtocol.requestHandler = { request in
                let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
                return (response, Data())
            }
            do {
                try await RemoteAgentClient.shared.testConnectionForTesting(
                    backend: .openclaw, url: baseURL, token: secretToken, session: session
                )
                XCTFail("Expected throw for status \(status)")
            } catch let error as AppError {
                XCTAssertEqual(error.errorCode, expected.errorCode)
                let message = "\(error)\n\(error.localizedDescription)\n\(error.errorUserInfo)"
                XCTAssertFalse(message.contains(secretToken),
                               "Bearer token leaked into AppError for status \(status). Surface: \(message)")
            } catch {
                XCTFail("Expected AppError for status \(status), got: \(error)")
            }
        }
    }

    // MARK: - Foreground pinning session (the macOS converse trust posture)
    //
    // `URLSession.shared` cannot carry a delegate, so a converse send issued on
    // it silently disables the user's cert pin AND the cross-host-redirect
    // refusal. Every production call site therefore builds its session from
    // `makePinnedForegroundSession(...)`; these lock that factory's contract.
    // (The call sites themselves are `#if os(macOS)` branches inside the VM /
    // drainer with no injection seam, so the factory is the assertable surface.)

    func testPinnedForegroundSessionInstallsTheTrustEvaluator() {
        let pin = String(repeating: "cd", count: 32)
        let (session, evaluator) = RemoteAgentClient.makePinnedForegroundSession(pinnedFingerprintHex: pin)
        defer { session.invalidateAndCancel() }

        XCTAssertTrue((session.delegate as? RemoteAgentTrustEvaluator) === evaluator,
                      "The returned session MUST carry the returned evaluator as its delegate — otherwise the pin and the redirect policy are dead code on the live send path. (Also a drift guard: the delegate must be the SHARED trust component, not a look-alike that could diverge from it.)")
        XCTAssertEqual(evaluator.pinnedFingerprintHex, pin,
                       "The resolved per-ref pin must reach the evaluator verbatim.")
    }

    func testPinnedForegroundSessionIsDelegateBearingEvenWithNoPin() {
        // An UNPINNED ref still gets a delegate-bearing session: the redirect
        // policy applies regardless of pinning, and it means a later re-pin needs
        // no new wiring at the call site.
        let (session, evaluator) = RemoteAgentClient.makePinnedForegroundSession(pinnedFingerprintHex: nil)
        defer { session.invalidateAndCancel() }
        XCTAssertNotNil(session.delegate,
                        "Even an unpinned foreground converse session must carry the evaluator (redirect policy + future re-pin).")
        XCTAssertNil(evaluator.pinnedFingerprintHex,
                     "nil pin → default ATS chain validation, the recommended posture for a publicly-trusted gateway.")
    }

    func testPinnedForegroundSessionUsesConverseTimeoutsNotTheProbeBudget() {
        let (session, _) = RemoteAgentClient.makePinnedForegroundSession(pinnedFingerprintHex: nil)
        defer { session.invalidateAndCancel() }
        let config = session.configuration
        XCTAssertEqual(config.timeoutIntervalForRequest,
                       Constants.remoteAgentConverseRequestTimeout, accuracy: 0.001,
                       "Load-bearing: a self-hosted LLM routinely thinks for minutes. `.ephemeral` defaults to 60s, so the 300s converse budget MUST be set explicitly or a live turn dies as a phantom 'Network Offline'.")
        XCTAssertEqual(config.timeoutIntervalForResource,
                       Constants.remoteAgentConverseResourceTimeout, accuracy: 0.001,
                       "The 600s resource ceiling must match the other converse lanes.")
        XCTAssertNotEqual(config.timeoutIntervalForRequest,
                          Constants.remoteAgentTestConnectionTimeout,
                          "Drift guard: never inherit Test Connection's 15s interactive budget on the send path.")
        XCTAssertEqual(config.requestCachePolicy, .reloadIgnoringLocalAndRemoteCacheData,
                       "A converse turn must never be answered from a cache (`.shared` previously carried the system cache + cookies onto this hop).")
    }

    // MARK: - Transport-error mapping (pin rejection vs. benign cancel)
    //
    // A pin mismatch is answered with `cancelAuthenticationChallenge`, which
    // URLSession surfaces as `.cancelled` (-999) — byte-identical to the
    // chat-thread Cancel button. Only a CONFIRMED `pinRejected` may upgrade it.

    func testCancelWithConfirmedPinRejectionMapsToCertMismatch() {
        let mapped = RemoteAgentClient.mapTransportError(.cancelled, hasPin: true, pinRejected: true)
        XCTAssertEqual((mapped as? AppError)?.errorCode, AppError.remoteAgentCertMismatch.errorCode,
                       "A pin mismatch must surface as a cert error, not vanish as a benign cancel — otherwise a MITM reads as 'the user cancelled'.")
    }

    func testCancelOnAPinnedSessionWithoutRejectionStaysBenign() {
        // REGRESSION GUARD: the user tapping Cancel on a PINNED gateway must
        // still be a benign `CancellationError`. Broadening the `.cancelled` arm
        // would raise a spurious "Untrusted certificate" banner on every cancel
        // and clobber any prior failure classification.
        let mapped = RemoteAgentClient.mapTransportError(.cancelled, hasPin: true, pinRejected: false)
        XCTAssertTrue(mapped is CancellationError,
                      "Cancel without a confirmed pin rejection is a user abort, not a cert failure.")
    }

    func testUnpinnedTransportMappingIsUnchanged() {
        // The unpinned converse path (every existing caller, incl. all tests)
        // must map EXACTLY as it did before the trust signals were threaded in.
        let expected: [(URLError.Code, Int?)] = [
            (.timedOut, AppError.remoteAgentTimeout.errorCode),
            (.cannotConnectToHost, AppError.remoteAgentUnreachable.errorCode),
            (.notConnectedToInternet, AppError.remoteAgentUnreachable.errorCode),
            (.networkConnectionLost, AppError.remoteAgentUnreachable.errorCode),
            (.cannotFindHost, AppError.remoteAgentUnreachable.errorCode),
            (.dnsLookupFailed, AppError.remoteAgentUnreachable.errorCode),
            (.resourceUnavailable, AppError.remoteAgentUnreachable.errorCode),
            (.serverCertificateUntrusted, AppError.remoteAgentCertMismatch.errorCode),
            (.serverCertificateHasBadDate, AppError.remoteAgentCertMismatch.errorCode),
            (.serverCertificateHasUnknownRoot, AppError.remoteAgentCertMismatch.errorCode),
            (.serverCertificateNotYetValid, AppError.remoteAgentCertMismatch.errorCode),
            // GENERIC SSL failure stays RETRYABLE — a cold tunnel produces it on
            // a perfectly-trusted cert, and the converse hop deliberately does
            // not consult `systemTrustRejected`.
            (.secureConnectionFailed, AppError.remoteAgentUnreachable.errorCode),
            (.badServerResponse, AppError.remoteAgentUnreachable.errorCode),
            (.cancelled, nil),   // nil = CancellationError, not an AppError
        ]
        for (code, expectedCode) in expected {
            let mapped = RemoteAgentClient.mapTransportError(code, hasPin: false, pinRejected: false)
            if let expectedCode {
                XCTAssertEqual((mapped as? AppError)?.errorCode, expectedCode,
                               "Unpinned mapping drifted for \(code)")
            } else {
                XCTAssertTrue(mapped is CancellationError,
                              "Unpinned `.cancelled` must stay a benign CancellationError")
            }
        }
    }

    func testGenericTLSFailureWithConfirmedPinRejectionIsCertMismatch() {
        // With a pin set AND the evaluator confirming it cancelled, the generic
        // `-1200` is a real mismatch rather than a cold-tunnel hiccup.
        let mapped = RemoteAgentClient.mapTransportError(.secureConnectionFailed, hasPin: true, pinRejected: true)
        XCTAssertEqual((mapped as? AppError)?.errorCode, AppError.remoteAgentCertMismatch.errorCode)
    }

    func testGenericTLSFailureOnAPinnedSessionWithoutRejectionStaysRetryable() {
        let mapped = RemoteAgentClient.mapTransportError(.secureConnectionFailed, hasPin: true, pinRejected: false)
        XCTAssertEqual((mapped as? AppError)?.errorCode, AppError.remoteAgentUnreachable.errorCode,
                       "A pinned gateway over a cold tunnel must stay retryable — `pinRejected == false` means the trust layer never rejected anything.")
    }

    // MARK: - Stream helpers (existing)

    /// URLProtocol surfaces request bodies via `httpBodyStream` when set
    /// via URLRequest's body-stream APIs (URLSession sometimes upgrades
    /// `httpBody` to a stream for large payloads). Reads to EOF.
    private static func readStreamBody(_ request: URLRequest) -> Data? {
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 4096
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: bufferSize)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}
