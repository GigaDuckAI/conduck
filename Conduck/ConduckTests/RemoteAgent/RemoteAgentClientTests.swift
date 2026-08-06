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
            transport: .unevaluated(session: session)
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
            transport: .unevaluated(session: session)
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
            transport: .unevaluated(session: session)
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
                newUserText: "hi", fileServerReady: false,
                transport: .unevaluated(session: self.session)
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
                newUserText: "hi", fileServerReady: false,
                transport: .unevaluated(session: self.session)
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
                newUserText: "hi", fileServerReady: false,
                transport: .unevaluated(session: self.session)
            )
        }
    }

    func testPeerCancelWithoutTaskCancellationIsUnreachableNotABenignCancel() async {
        // DELIBERATE REVERSAL of the old expectation. This case previously
        // asserted `CancellationError`, which was wrong in the one way that
        // costs the user the most: `URLError.cancelled` (-999) is ALSO what a
        // peer-side stream reset looks like, and treating that as "the user
        // cancelled" makes the failure writers persist NO classification. The
        // turn then renders the bare generic "wasn't delivered" copy with no
        // cause and no Troubleshoot, and Diagnostics — which filters on a
        // non-nil failure code — never records it at all.
        //
        // Nothing cancels the enclosing task here, so `Task.isCancelled` is
        // false and the -999 must classify as a transport failure.
        MockURLProtocol.requestHandler = { _ in
            throw URLError(.cancelled)
        }

        do {
            _ = try await RemoteAgentClient.shared.send(
                backend: .openclaw, url: baseURL, token: token,
                newUserText: "hi", fileServerReady: false,
                transport: .unevaluated(session: session)
            )
            XCTFail("Expected a thrown error for a cancelled request")
        } catch is CancellationError {
            XCTFail("A -999 with no task cancellation behind it is a PEER reset, not a user cancel — classifying it as a cancel is what made the failure unclassified and invisible to Diagnostics.")
        } catch let error as AppError {
            XCTAssertEqual(error.errorCode, AppError.remoteAgentUnreachable.errorCode,
                           "An interrupted connection must classify as unreachable (delivery UNCERTAIN), not vanish as a benign cancel.")
        } catch {
            XCTFail("Expected an AppError, got \(type(of: error)): \(error)")
        }
    }

    func testUserCancelledTaskStillMapsToBenignCancellationError() async {
        // The other half, and the reason the discriminator is `Task.isCancelled`
        // rather than a heuristic: when the app genuinely cancelled, -999 must
        // STILL be a benign `CancellationError` so the turn keeps its
        // status-only flip and no spurious gateway error is raised.
        MockURLProtocol.requestHandler = { _ in
            throw URLError(.cancelled)
        }

        // Cancel the enclosing task before the send observes the failure. The
        // task checks `Task.isCancelled` inside its URLError catch, so a task
        // cancelled up front is exactly the shape a Stop tap produces.
        let task = Task {
            try await RemoteAgentClient.shared.send(
                backend: .openclaw, url: self.baseURL, token: self.token,
                newUserText: "hi", fileServerReady: false,
                transport: .unevaluated(session: self.session)
            )
        }
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected a thrown error for a cancelled request")
        } catch is CancellationError {
            // Expected — a real cancel stays benign.
        } catch let error as AppError {
            XCTFail("A genuinely cancelled task must stay a CancellationError, not surface as \(error) — otherwise every Stop raises a gateway failure banner.")
        } catch {
            XCTFail("Expected CancellationError, got \(type(of: error)): \(error)")
        }
    }

    func testTrustSignalsOutrankTaskCancellationForCertClassification() async {
        // Precedence guard: a CONFIRMED pin rejection is reported as a cert
        // error even when the task is also cancelled. A MITM must never be able
        // to hide behind a concurrent Stop.
        let mapped = RemoteAgentClient.mapTransportError(
            .cancelled,
            signals: .init(systemTrustRejected: false,
                           challengeRefused: true,
                           pinRejected: true,
                           pinComparisonUnsupported: false),
            isTaskCancelled: true)
        XCTAssertEqual((mapped as? AppError)?.errorCode, AppError.remoteAgentCertMismatch.errorCode,
                       "Trust-signal arms must win over the cancellation discriminator.")
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

    /// An empty `data` array is a PASS with a caveat, not a failure: the route
    /// exists and speaks the protocol, but a gateway advertising zero models
    /// cannot answer a turn. Asserted here on the full wire path — the body
    /// verdict has its own unit test, and this one proves the distinct outcome
    /// survives the transport + status layers rather than collapsing to `.ok`.
    func testTestConnectionEmptyModelListPassesAsNoModels() async throws {
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data(#"{"data":[]}"#.utf8))
        }

        let outcome = try await RemoteAgentClient.shared.testConnectionForTesting(
            backend: .openclaw,
            url: baseURL,
            token: token,
            session: session
        )

        XCTAssertEqual(outcome, .okNoModels,
                       "A structurally valid but empty model list must stay distinguishable from a flat green.")
    }

    // MARK: - Pairing trust probe (unpinned; handshake-completion semantics)

    /// THE contract that separates this probe from Test Connection: a 401 proves
    /// the TLS handshake was accepted and the password was wrong — two completely
    /// different facts. Test Connection throws on 401, which would make the trust
    /// matrix read an ordinarily-trusted server as unreachable and refuse an
    /// import that should have proceeded.
    func testPairingTrustProbeTreatsAnyHTTPResponseAsHandshakeCompletion() async {
        for status in [200, 401, 403, 404, 500] {
            MockURLProtocol.requestHandler = { request in
                let response = HTTPURLResponse(url: request.url!, statusCode: status,
                                               httpVersion: nil, headerFields: nil)!
                return (response, Data(#"{"error":"nope"}"#.utf8))
            }

            let signals = await RemoteAgentClient.shared.pairingTrustProbeForTesting(
                url: baseURL, token: token, session: session)

            XCTAssertTrue(signals.requestCompleted,
                          "HTTP \(status) still proves the handshake was accepted.")
            XCTAssertNil(signals.transportClass,
                         "HTTP \(status) is not a transport failure.")
        }
    }

    /// A completed handshake means the system accepted the chain, so the import
    /// proceeds under ordinary trust and stores NO pin — retaining one would break
    /// the gateway at its next certificate renewal.
    func testPairingTrustProbeUnderOrdinaryTrustProceedsWithoutAPin() async {
        MockURLProtocol.requestHandler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
             Data(#"{"data":[]}"#.utf8))
        }

        let signals = await RemoteAgentClient.shared.pairingTrustProbeForTesting(
            url: baseURL, token: token, session: session)

        XCTAssertTrue(signals.requestCompleted)
        XCTAssertEqual(PairingTrustDecision.decide(signals), .useOrdinaryTrust)
    }

    func testPairingTrustProbeClassifiesAnUntrustedCertificate() async {
        MockURLProtocol.requestHandler = { _ in throw URLError(.serverCertificateUntrusted) }

        let signals = await RemoteAgentClient.shared.pairingTrustProbeForTesting(
            url: baseURL, token: token, session: session,
            systemTrustRejected: { true })

        XCTAssertFalse(signals.requestCompleted)
        XCTAssertEqual(signals.transportClass, .untrustedCert)
        // Terminal: a certificate the device does not trust cannot be pinned into
        // acceptance, so there is no arm the import can proceed past.
        XCTAssertEqual(PairingTrustDecision.decide(signals),
                       .blocked(.certificateNotPubliclyTrusted))
    }

    func testPairingTrustProbeReportsTransientFailureWithoutThrowing() async {
        MockURLProtocol.requestHandler = { _ in throw URLError(.timedOut) }

        let signals = await RemoteAgentClient.shared.pairingTrustProbeForTesting(
            url: baseURL, token: token, session: session)

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
            // 500, not 503: a 503 now carries the route-outage verdict, because
            // something answered but not the gateway's own application.
            let response = HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!
            return (response, Data())
        }

        await assertThrowsAppError(.remoteAgentServerError) {
            try await RemoteAgentClient.shared.testConnectionForTesting(
                backend: .openclaw, url: self.baseURL, token: self.token, session: self.session
            )
        }
    }

    func testTestConnectionRefusedConnectionMapsToNotEstablished() async {
        MockURLProtocol.requestHandler = { request in
            throw URLError(.cannotConnectToHost)
        }

        // The PROBE reports the same distinction the send path does, so Test
        // Connection and a failed chat never disagree about what went wrong.
        await assertThrowsAppError(.remoteAgentNotEstablished) {
            try await RemoteAgentClient.shared.testConnectionForTesting(
                backend: .openclaw, url: self.baseURL, token: self.token, session: self.session
            )
        }
    }

    func testTestConnectionDroppedConnectionStaysUncertain() async {
        MockURLProtocol.requestHandler = { request in
            throw URLError(.networkConnectionLost)
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
        // error — never auto-offer re-trust (that defeats pinning, and there
        // is no re-trust affordance anywhere in this app). (The mock bypasses
        // the real evaluator, so we inject `pinRejected: { true }` to
        // simulate the genuine-mismatch signal.)
        MockURLProtocol.requestHandler = { request in
            throw URLError(.cancelled)
        }

        await assertThrowsAppError(.remoteAgentCertMismatch) {
            try await RemoteAgentClient.shared.testConnectionForTesting(
                backend: .openclaw, url: self.baseURL, token: self.token,
                session: self.session, challengeRefused: true,
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
                session: self.session, challengeRefused: false
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
                session: self.session, challengeRefused: false,
                systemTrustRejected: { false }
            )
        }
    }

    func testTestConnectionSecureConnectionFailedSystemRejectedIsUntrustedCert() async throws {
        // A genuine no-pin rejection that surfaced via the GENERIC code must
        // still name the certificate — `systemTrustRejected` is the only thing
        // that tells it apart from a cold-tunnel hiccup carrying the same code.
        MockURLProtocol.requestHandler = { _ in throw URLError(.secureConnectionFailed) }
        let outcome = try await RemoteAgentClient.shared.testConnectionForTesting(
            backend: .openclaw, url: baseURL, token: token,
            session: session, challengeRefused: false,
            systemTrustRejected: { true }
        )
        XCTAssertEqual(outcome, .untrustedCert,
                       "A real system rejection must be reported as an untrusted certificate even via the generic code.")
    }

    func testTestConnectionSecureConnectionFailedPinTransientIsUnreachable() async {
        // Pinned host on a cold tunnel (no confirmed mismatch) → retryable,
        // NOT a false cert MISMATCH (which would imply a MITM).
        MockURLProtocol.requestHandler = { _ in throw URLError(.secureConnectionFailed) }
        await assertThrowsAppError(.remoteAgentUnreachable) {
            try await RemoteAgentClient.shared.testConnectionForTesting(
                backend: .openclaw, url: self.baseURL, token: self.token,
                session: self.session, challengeRefused: true,
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
                newUserText: "hi", fileServerReady: false,
                transport: .unevaluated(session: self.session)
            )
        }
    }

    func testSendSpecificCertCodeMapsToCertUntrusted() async {
        // A specific server-certificate code on the live hop names the CERTIFICATE
        // as the cause. With no pin on this session nothing could have
        // mismatched, so the user gets the untrusted-certificate error and its
        // server-side remedy — never "update the pinned fingerprint".
        MockURLProtocol.requestHandler = { _ in throw URLError(.serverCertificateUntrusted) }
        await assertThrowsAppError(.remoteAgentCertUntrusted) {
            try await RemoteAgentClient.shared.send(
                backend: .openclaw, url: self.baseURL, token: self.token,
                newUserText: "hi", fileServerReady: false,
                transport: .unevaluated(session: self.session)
            )
        }
    }

    func testTestConnectionUntrustedCertNoPinIsATerminalOutcomeNotAThrow() async throws {
        // NO pin set + the system rejected the certificate → `.untrustedCert`:
        // an explained refusal the UI can render, NOT a thrown error and NOT an
        // offer to trust it.
        MockURLProtocol.requestHandler = { request in
            throw URLError(.serverCertificateUntrusted)
        }

        let outcome = try await RemoteAgentClient.shared.testConnectionForTesting(
            backend: .openclaw, url: baseURL, token: token,
            session: session, challengeRefused: false
        )

        XCTAssertEqual(outcome, .untrustedCert,
                       "A no-pin certificate rejection must return the terminal .untrustedCert outcome, not throw.")
    }

    func testTestConnectionUnknownRootAlsoSurfacesTheSameTerminalOutcome() async throws {
        // A SECOND unambiguous certificate-rejection code, with neither trust
        // signal set. The classifier treats the whole `serverCertificate*` family
        // alike, so the user gets one refusal with one remedy however CFNetwork
        // words the failure — never a second, differently-shaped cert error.
        MockURLProtocol.requestHandler = { request in
            throw URLError(.serverCertificateHasUnknownRoot)
        }

        let outcome = try await RemoteAgentClient.shared.testConnectionForTesting(
            backend: .openclaw, url: baseURL, token: token,
            session: session, challengeRefused: false
        )

        XCTAssertEqual(outcome, .untrustedCert,
                       "Every code in the server-certificate family must land on .untrustedCert, not throw.")
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
        let mapped = RemoteAgentClient.mapTransportError(
            .cancelled,
            signals: .init(systemTrustRejected: false,
                           challengeRefused: true,
                           pinRejected: true,
                           pinComparisonUnsupported: false),
            isTaskCancelled: false)
        XCTAssertEqual((mapped as? AppError)?.errorCode, AppError.remoteAgentCertMismatch.errorCode,
                       "A pin mismatch must surface as a cert error, not vanish as a benign cancel — otherwise a MITM reads as 'the user cancelled'.")
    }

    func testCancelFromTheFailClosedTrustArmMapsToCertUntrusted() {
        // The evaluator cancels a PINNED challenge when the system rejects the
        // chain (fail closed), which URLSession reports as -999. Without the
        // `systemTrustRejected` signal that lands in the benign-cancel arm and
        // the user is told nothing at all — and it must NOT land on the
        // mismatch code either: the pinned fingerprint was never consulted, so
        // "update the pinned fingerprint" would be the wrong instruction.
        let mapped = RemoteAgentClient.mapTransportError(
            .cancelled,
            signals: .init(systemTrustRejected: true,
                           challengeRefused: true,
                           pinRejected: false,
                           pinComparisonUnsupported: false),
            isTaskCancelled: false)
        XCTAssertEqual((mapped as? AppError)?.errorCode, AppError.remoteAgentCertUntrusted.errorCode,
                       "A connection refused because this device does not trust the certificate must reach the user as an UNTRUSTED-certificate error, not as a pin mismatch or a silent cancel.")
    }

    func testCancelOnAPinnedSessionWithoutRejectionStaysBenign() {
        // REGRESSION GUARD: the user tapping Cancel on a PINNED gateway must
        // still be a benign `CancellationError`. Broadening the `.cancelled` arm
        // would raise a spurious "Untrusted certificate" banner on every cancel
        // and clobber any prior failure classification.
        let mapped = RemoteAgentClient.mapTransportError(
            .cancelled,
            signals: .init(systemTrustRejected: false,
                           challengeRefused: true,
                           pinRejected: false,
                           pinComparisonUnsupported: false),
            isTaskCancelled: true)
        XCTAssertTrue(mapped is CancellationError,
                      "Cancel with NEITHER trust signal set is a user abort, not a cert failure.")
    }

    func testUnpinnedTransportMapping() {
        // The unpinned converse path (every existing caller, incl. all tests).
        // The transport classes are untouched by the trust signals; the four
        // server-certificate codes name the CERTIFICATE, and with no pin
        // configured there is nothing that could have mismatched — so they are
        // untrusted-certificate, never mismatch.
        let expected: [(URLError.Code, Int?)] = [
            (.timedOut, AppError.remoteAgentTimeout.errorCode),
            // Delivery-certainty split. These three prove no connection ever
            // opened, so their copy may tell the user a retry is unlikely to
            // repeat gateway-side work.
            (.cannotConnectToHost, AppError.remoteAgentNotEstablished.errorCode),
            (.cannotFindHost, AppError.remoteAgentNotEstablished.errorCode),
            (.dnsLookupFailed, AppError.remoteAgentNotEstablished.errorCode),
            // THIS DEVICE has no route — must not implicate the user's server.
            (.notConnectedToInternet, AppError.noInternetConnection.errorCode),
            // Stay UNCERTAIN: a dropped connection may have delivered the request
            // first, and `.resourceUnavailable` is too vague to promise anything.
            (.networkConnectionLost, AppError.remoteAgentUnreachable.errorCode),
            (.resourceUnavailable, AppError.remoteAgentUnreachable.errorCode),
            (.serverCertificateUntrusted, AppError.remoteAgentCertUntrusted.errorCode),
            (.serverCertificateHasBadDate, AppError.remoteAgentCertUntrusted.errorCode),
            (.serverCertificateHasUnknownRoot, AppError.remoteAgentCertUntrusted.errorCode),
            (.serverCertificateNotYetValid, AppError.remoteAgentCertUntrusted.errorCode),
            // GENERIC SSL failure stays RETRYABLE — a cold tunnel produces it on
            // a perfectly-trusted cert, and with NEITHER trust signal set nothing
            // ever rejected a certificate.
            (.secureConnectionFailed, AppError.remoteAgentUnreachable.errorCode),
            (.badServerResponse, AppError.remoteAgentUnreachable.errorCode),
            // -999 with the task NOT cancelled is a PEER-side stream reset, not a
            // user abort — the two are byte-identical on the wire, and only the
            // cancellation state tells them apart. Reporting it as a cancel would
            // write no classification at all, leaving the turn with the bare
            // "wasn't delivered" copy and no Diagnostics record.
            (.cancelled, AppError.remoteAgentUnreachable.errorCode),
        ]
        // `isTaskCancelled: false` for the whole table because that is the state
        // every one of these codes actually occurs in — a timeout or a DNS
        // failure cannot be produced by a cancelled task. Asserting the table
        // under `true` would test a combination that never happens and would
        // leave the production default for `.cancelled` uncovered.
        for (code, expectedCode) in expected {
            let mapped = RemoteAgentClient.mapTransportError(
            code,
            signals: .init(systemTrustRejected: false,
                           challengeRefused: false,
                           pinRejected: false,
                           pinComparisonUnsupported: false),
            isTaskCancelled: false)
            XCTAssertEqual((mapped as? AppError)?.errorCode, expectedCode,
                           "Unpinned mapping drifted for \(code)")
        }

        // The other half of the -999 split, on the same unpinned lane: the task
        // WAS cancelled, so this is the user tapping Stop and must stay benign.
        let userCancel = RemoteAgentClient.mapTransportError(
            .cancelled,
            signals: .init(systemTrustRejected: false,
                           challengeRefused: false,
                           pinRejected: false,
                           pinComparisonUnsupported: false),
            isTaskCancelled: true)
        XCTAssertTrue(userCancel is CancellationError,
                      "A cancelled task's -999 is a user abort — surfacing it as a gateway failure would raise a banner on every Stop.")
    }

    func testGenericTLSFailureWithConfirmedPinRejectionIsCertMismatch() {
        // With a pin set AND the evaluator confirming it cancelled, the generic
        // `-1200` is a real mismatch rather than a cold-tunnel hiccup.
        let mapped = RemoteAgentClient.mapTransportError(
            .secureConnectionFailed,
            signals: .init(systemTrustRejected: false,
                           challengeRefused: true,
                           pinRejected: true,
                           pinComparisonUnsupported: false),
            isTaskCancelled: false)
        XCTAssertEqual((mapped as? AppError)?.errorCode, AppError.remoteAgentCertMismatch.errorCode)
    }

    func testGenericTLSFailureOnAPinnedSessionWithoutRejectionStaysRetryable() {
        let mapped = RemoteAgentClient.mapTransportError(
            .secureConnectionFailed,
            signals: .init(systemTrustRejected: false,
                           challengeRefused: true,
                           pinRejected: false,
                           pinComparisonUnsupported: false),
            isTaskCancelled: false)
        XCTAssertEqual((mapped as? AppError)?.errorCode, AppError.remoteAgentUnreachable.errorCode,
                       "A pinned gateway over a cold tunnel must stay retryable — NEITHER signal set means the trust layer never rejected anything.")
    }

    func testGenericTLSFailureWithSystemTrustRejectionIsCertUntrusted() {
        // The converse hop's own lane: -1200 with the evaluator reporting that
        // the device does not trust the chain. Hardcoding `systemTrustRejected:
        // false` here is what made a certificate problem unreportable on the
        // lane the user actually converses on.
        let mapped = RemoteAgentClient.mapTransportError(
            .secureConnectionFailed,
            signals: .init(systemTrustRejected: true,
                           challengeRefused: false,
                           pinRejected: false,
                           pinComparisonUnsupported: false),
            isTaskCancelled: false)
        XCTAssertEqual((mapped as? AppError)?.errorCode, AppError.remoteAgentCertUntrusted.errorCode,
                       "An untrusted certificate on the live converse hop must name the certificate, not read as 'unreachable, try again' and not as a pin mismatch.")
    }

    // MARK: - Transport taxonomy shared across the dispatch lanes

    /// Every lane must classify a transport failure the SAME way, because the
    /// distinction gates what the user is told about delivery: a refused
    /// connection or a dead hostname never opened a connection (73), airplane
    /// mode is the device's own fault (3), and a connection lost mid-flight may
    /// already have been executed by the far side (19).
    ///
    /// Pinned here because `CarPlayConverseUploader` now routes through this same
    /// mapper. It previously carried its own blanket `.remoteAgentUnreachable`
    /// for every non-certificate transport error, which told a driver to go
    /// investigate a gateway that had never been contacted.
    func testTransportErrorsClassifyByDeliveryCertainty() {
        let cases: [(URLError.Code, AppError)] = [
            (.cannotConnectToHost, .remoteAgentNotEstablished),
            (.cannotFindHost, .remoteAgentNotEstablished),
            (.dnsLookupFailed, .remoteAgentNotEstablished),
            (.notConnectedToInternet, .noInternetConnection),
            (.networkConnectionLost, .remoteAgentUnreachable),
            (.timedOut, .remoteAgentTimeout),
        ]
        for (code, expected) in cases {
            XCTAssertEqual(
                BackgroundRemoteAgent.mapURLError(URLError(code)).errorCode,
                expected.errorCode,
                "URLError \(code.rawValue) must classify as \(expected.errorCode) on every lane"
            )
        }
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
