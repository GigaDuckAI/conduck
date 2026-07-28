// SPDX-License-Identifier: Apache-2.0

// Conduck
// STTConnectionTestSuiteTests.swift
//
// Custom-STT V1.x — Feature 3 (rich staged Test Connection engine). Drives the
// `STTConnectionTestSuite.runForTesting(session:)` injection seam through a
// `MockURLProtocol`-backed `URLSession` so the three stages (reachability/TLS →
// auth → transcription round-trip + latency) resolve deterministically with NO
// real network. The existing bundled spoken clip (`stt-probe-spoken.m4a`) is
// loaded for the multipart body, but the response is fully mocked — so the silent
// vs spoken distinction doesn't matter for these unit tests (the SERVER's
// transcript text is whatever the handler returns).
//
// Also covers:
//   • A Bundle test that `stt-probe-spoken.m4a` resolves (catches a bundling
//     regression — the engine fails every stage loudly if the asset is gone).
//   • The loose fuzzy-match helper (token normalization, ≥50% threshold,
//     digit-vs-word tolerance).
//
// Privacy invariant under test: NO stage detail / reason / transcript ever
// carries the key — asserted indirectly by the engine surfacing only
// taxonomy-derived reasons (the engine never receives the key in a position it
// could echo).

import XCTest
@testable import Conduck

final class STTConnectionTestSuiteTests: XCTestCase {

    /// FULL transcribe URL the suite probes — the caller resolves base + path.
    private let probeURL = URL(string: "https://whisper.example.test:9000/v1/audio/transcriptions")!

    /// Build a fresh `MockURLProtocol`-backed session per test.
    private func makeMockSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }

    override func setUp() {
        super.setUp()
        // Every test installs its own handler; default to a failing guard so a
        // missing handler surfaces loudly rather than hanging.
        MockURLProtocol.requestHandler = nil
    }

    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    /// Convenience: run the suite through a mock session, discarding progress
    /// ticks (tests assert the FINAL result; progress is for live animation).
    /// `hasPin` maps to `challengeRefused` — a pin's existence was only ever a
    /// proxy for "the evaluator was on a path that CAN cancel", which is what the
    /// signal now records directly.
    private func runSuite(
        session: URLSession,
        auth: STTAuthScheme = .bearer,
        hasPin: Bool = false,
        systemTrustRejected: Bool = false,
        pinRejected: Bool = false,
        pinComparisonUnsupported: Bool = false
    ) async -> STTTestSuiteResult {
        await STTConnectionTestSuite.runForTesting(
            url: probeURL,
            token: "sk-test-key-never-surfaced",
            auth: auth,
            model: "whisper-1",
            session: session,
            signals: {
                .init(systemTrustRejected: systemTrustRejected,
                      challengeRefused: hasPin,
                      pinRejected: pinRejected,
                      pinComparisonUnsupported: pinComparisonUnsupported)
            },
            progress: { _ in }
        )
    }

    /// Build an HTTPURLResponse for a request with the given status (matches the
    /// `RemoteAgentClientTests` inline-from-`request.url!` convention). `static`
    /// so the `MockURLProtocol.requestHandler` closures don't capture `self`.
    private static func httpResponse(_ request: URLRequest, _ status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
    }

    private func status(of stage: STTTestStage, in result: STTTestSuiteResult) -> STTStageStatus? {
        result.stages.first(where: { $0.stage == stage })?.status
    }

    // MARK: - Happy path: reachable + 200 + text

    func testReachable200WithTextAllPassed() async {
        MockURLProtocol.requestHandler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
             Data(#"{"text":"testing one two three"}"#.utf8))
        }
        let result = await runSuite(session: makeMockSession())

        XCTAssertTrue(result.allPassed,
                      "A reachable server that returns 200 + non-empty transcript must pass all three stages.")
        XCTAssertEqual(result.transcript, "testing one two three",
                       "The server's transcript must be stored for the 'Heard:' card.")
        XCTAssertNotNil(result.latencyMS,
                        "Latency must be captured once the transcription POST completes.")
        if case .passed = status(of: .transcription, in: result) {} else {
            XCTFail("Transcription stage must be .passed on 200 + non-empty text.")
        }
    }

    // MARK: - 200 + empty text → transcription failed (the case silence can't catch)

    func test200EmptyTextTranscriptionFailed() async {
        MockURLProtocol.requestHandler = { req in
            (Self.httpResponse(req, 200), Data(#"{"text":""}"#.utf8))
        }
        let result = await runSuite(session: makeMockSession())

        XCTAssertFalse(result.allPassed,
                       "A 200 with an EMPTY transcript must NOT pass — this is the exact case silence cannot catch.")
        if case .passed = status(of: .reachability, in: result) {} else {
            XCTFail("Reachability must pass (the handshake completed).")
        }
        if case .passed = status(of: .auth, in: result) {} else {
            XCTFail("Auth must pass (200 is not 401/403).")
        }
        guard case .failed(let reason) = status(of: .transcription, in: result) else {
            return XCTFail("Transcription must be .failed on an empty transcript, got \(String(describing: status(of: .transcription, in: result))).")
        }
        // Must fail with the EMPTY-TRANSCRIPT reason, NOT the undecodable
        // ("isn't OpenAI-compatible") verdict — the decoder throws
        // `.noSpeechDetected` on empty, and the suite must map that to the
        // empty-transcript message, not swallow it as a decode failure.
        XCTAssertEqual(reason, STTConnectionTestSuite.emptyTranscriptReason,
                       "A 200-empty must surface the empty-transcript reason, not 'isn't OpenAI-compatible'.")
        XCTAssertNil(result.transcript,
                     "An empty transcript must NOT be stored as a 'heard' result.")
    }

    // MARK: - 200 + undecodable → transcription failed

    func test200UndecodableTranscriptionFailed() async {
        MockURLProtocol.requestHandler = { req in
            // Valid JSON, but missing the `text` field the .openAICompat decoder
            // requires → sttDecodingFailure inside the engine → .failed.
            (Self.httpResponse(req, 200), Data(#"{"not_text":"oops"}"#.utf8))
        }
        let result = await runSuite(session: makeMockSession())

        XCTAssertFalse(result.allPassed)
        if case .passed = status(of: .auth, in: result) {} else {
            XCTFail("Auth must pass before the body is decoded.")
        }
        guard case .failed = status(of: .transcription, in: result) else {
            return XCTFail("An undecodable body must fail the transcription stage.")
        }
    }

    // MARK: - 401 → auth failed, transcription not attempted

    func test401AuthFailedTranscriptionSkipped() async {
        MockURLProtocol.requestHandler = { req in
            (Self.httpResponse(req, 401), Data(#"{"error":"invalid key"}"#.utf8))
        }
        let result = await runSuite(session: makeMockSession())

        XCTAssertFalse(result.allPassed)
        if case .passed = status(of: .reachability, in: result) {} else {
            XCTFail("Reachability must pass — the handshake completed; only the STATUS is 401.")
        }
        guard case .failed = status(of: .auth, in: result) else {
            return XCTFail("A 401 must fail the auth stage.")
        }
        // The transcription stage must NOT be attempted (skipped) once auth fails.
        guard case .skipped = status(of: .transcription, in: result) else {
            return XCTFail("Transcription must be .skipped (not attempted) once auth fails, got \(String(describing: status(of: .transcription, in: result))).")
        }
        XCTAssertNil(result.transcript, "No transcript on an auth failure.")
    }

    func test403AlsoFailsAuth() async {
        MockURLProtocol.requestHandler = { req in
            (Self.httpResponse(req, 403), Data())
        }
        let result = await runSuite(session: makeMockSession())
        guard case .failed = status(of: .auth, in: result) else {
            return XCTFail("A 403 must also fail the auth stage.")
        }
    }

    // MARK: - 5xx → auth passed, transcription failed

    func test5xxAuthPassedTranscriptionFailed() async {
        MockURLProtocol.requestHandler = { req in
            (Self.httpResponse(req, 503), Data(#"{"error":"upstream model crashed"}"#.utf8))
        }
        let result = await runSuite(session: makeMockSession())

        XCTAssertFalse(result.allPassed)
        if case .passed = status(of: .auth, in: result) {} else {
            XCTFail("Auth must PASS on a 5xx (the key reached the auth layer; the server itself errored).")
        }
        guard case .failed = status(of: .transcription, in: result) else {
            return XCTFail("A 5xx must fail the transcription stage (surfaced AFTER auth passes).")
        }
    }

    // MARK: - Timeout → reachability failed

    func testTimeoutReachabilityFailed() async {
        MockURLProtocol.requestHandler = { _ in
            throw URLError(.timedOut)
        }
        let result = await runSuite(session: makeMockSession())

        XCTAssertFalse(result.allPassed)
        guard case .failed = status(of: .reachability, in: result) else {
            return XCTFail("A timeout must fail the reachability stage.")
        }
        // Auth + transcription cannot run after a reachability failure.
        guard case .skipped = status(of: .auth, in: result) else {
            return XCTFail("Auth must be .skipped after a reachability failure.")
        }
        guard case .skipped = status(of: .transcription, in: result) else {
            return XCTFail("Transcription must be .skipped after a reachability failure.")
        }
    }

    // MARK: - Untrusted certificate → reachability FAILED, terminally

    func testUntrustedCertNoPinReachabilityFailedWithRemedy() async {
        MockURLProtocol.requestHandler = { _ in
            // TLS rejection on a certificate this device doesn't trust.
            throw URLError(.serverCertificateUntrusted)
        }
        let result = await runSuite(session: makeMockSession(), hasPin: false)

        XCTAssertFalse(result.allPassed)
        guard case .failed(let reason) = status(of: .reachability, in: result) else {
            return XCTFail("A certificate this device doesn't trust must FAIL reachability — there is nothing the user can approve.")
        }
        XCTAssertEqual(reason, CertificateTrustCopy.untrustedRefusalWithRemedy,
                       "The refusal must name the server-side remedy, not leave the user guessing.")
    }

    /// The refusal is identical WITH a pin configured: a pin can only narrow a
    /// chain the system already accepted, so it never rescues a rejected one.
    func testUntrustedCertWithPinStillFailsAsUntrusted() async {
        MockURLProtocol.requestHandler = { _ in
            throw URLError(.serverCertificateHasUnknownRoot)
        }
        let result = await runSuite(
            session: makeMockSession(),
            hasPin: true,
            systemTrustRejected: true
        )
        guard case .failed(let reason) = status(of: .reachability, in: result) else {
            return XCTFail("A rejected chain must fail reachability whether or not a pin is set.")
        }
        XCTAssertEqual(reason, CertificateTrustCopy.untrustedRefusalWithRemedy,
                       "System-trust rejection outranks the pin verdict — the remedy is the certificate, not the fingerprint.")
    }

    // MARK: - Pin set + cert rejected → reachability failed (never re-trust)

    func testPinMismatchReachabilityFailed() async {
        MockURLProtocol.requestHandler = { _ in
            // With a pin set AND the evaluator confirming the mismatch
            // (`pinRejected`), a TLS rejection means the cert changed away from
            // the pin → hard fail (auto-re-trust would defeat pinning).
            throw URLError(.secureConnectionFailed)
        }
        let result = await runSuite(
            session: makeMockSession(),
            hasPin: true,
            pinRejected: true
        )

        XCTAssertFalse(result.allPassed)
        guard case .failed(let reason) = status(of: .reachability, in: result) else {
            return XCTFail("A pin mismatch must FAIL (not skip) reachability — never auto-offer re-trust.")
        }
        XCTAssertNotEqual(reason, CertificateTrustCopy.untrustedRefusalWithRemedy,
                          "A pin mismatch on a system-trusted chain must not be described as an untrusted certificate.")
    }

    func testSecureConnectionFailedTransientNoPinIsRetryable() async {
        // THE REGRESSION (STT path): a generic `.secureConnectionFailed` with
        // no system rejection is a cold-tunnel hiccup → reachability fails as a
        // retryable transport problem, NOT as a certificate verdict.
        MockURLProtocol.requestHandler = { _ in throw URLError(.secureConnectionFailed) }
        let result = await runSuite(
            session: makeMockSession(),
            hasPin: false,
            systemTrustRejected: false
        )
        guard case .failed(let reason) = status(of: .reachability, in: result) else {
            return XCTFail("A transient secure-connection failure must FAIL reachability.")
        }
        XCTAssertNotEqual(reason, CertificateTrustCopy.untrustedRefusalWithRemedy,
                          "A cold-tunnel hiccup must not be blamed on the certificate.")
    }

    // MARK: - 4xx other than 401/403 → transcription failed (request-shape rejection)

    func test422AuthPassedTranscriptionFailed() async {
        MockURLProtocol.requestHandler = { req in
            // 422 on a known-good clip = the server rejected the request shape
            // (wrong model / format), surfaced as a transcription failure.
            (Self.httpResponse(req, 422), Data(#"{"error":"unknown model"}"#.utf8))
        }
        let result = await runSuite(session: makeMockSession())
        if case .passed = status(of: .auth, in: result) {} else {
            XCTFail("A 422 must pass auth (not 401/403).")
        }
        guard case .failed = status(of: .transcription, in: result) else {
            return XCTFail("A 422 must fail the transcription stage (request-shape rejection).")
        }
    }

    // MARK: - No-auth scheme (keyless local server)

    func testNoAuthScheme200AllPassed() async {
        MockURLProtocol.requestHandler = { req in
            // A keyless server must receive NO Authorization header.
            XCTAssertNil(req.value(forHTTPHeaderField: "Authorization"),
                         ".none auth must not attach an Authorization header.")
            return (Self.httpResponse(req, 200), Data(#"{"text":"testing one two three"}"#.utf8))
        }
        let result = await runSuite(session: makeMockSession(), auth: .none)
        XCTAssertTrue(result.allPassed,
                      "A keyless (.none) local server returning 200 + transcript must pass all stages.")
    }

    // MARK: - Bundle: the spoken probe clip resolves (bundling-regression guard)

    func testSpokenProbeAssetResolvesInBundle() {
        // The engine fails every stage loudly if this asset is missing; catch
        // the bundling regression directly so CI flags the membership drop.
        let url = Bundle.main.url(forResource: "stt-probe-spoken", withExtension: "m4a")
        XCTAssertNotNil(url,
                        "stt-probe-spoken.m4a must be bundled into the app target — the rich Test suite POSTs it. A nil here = Copy-Bundle-Resources membership regression.")
        if let url {
            let data = try? Data(contentsOf: url)
            XCTAssertNotNil(data, "The bundled probe clip must be readable.")
            XCTAssertGreaterThan(data?.count ?? 0, 0, "The bundled probe clip must be non-empty.")
        }
    }

    // MARK: - Loose fuzzy-match helper

    func testLooselyMatchesExactPhrase() {
        XCTAssertTrue(STTConnectionTestSuite.looselyMatches("testing one two three",
                                                            expected: "testing one two three"),
                      "An exact match must pass.")
    }

    func testLooselyMatchesDigitForWord() {
        // The server emitted digits ("1 2 3") where the expected phrase uses
        // words ("one two three") — must still match (digit-or-word tolerant).
        XCTAssertTrue(STTConnectionTestSuite.looselyMatches("Testing 1 2 3.",
                                                            expected: "testing one two three"),
                      "Digit forms must satisfy word-form expected tokens.")
    }

    func testLooselyMatchesWordForDigit() {
        // Inverse: expected uses digits, server emitted words.
        XCTAssertTrue(STTConnectionTestSuite.looselyMatches("one two three",
                                                            expected: "1 2 3"),
                      "Word forms must satisfy digit-form expected tokens.")
    }

    func testLooselyMatchesAtFiftyPercentThreshold() {
        // 2 of the 4 expected tokens present = exactly 50% → must pass (≥50%).
        XCTAssertTrue(STTConnectionTestSuite.looselyMatches("testing one",
                                                            expected: "testing one two three"),
                      "Exactly 50% of expected tokens present must pass the ≥50% threshold.")
    }

    func testLooselyMatchesBelowThresholdFails() {
        // 1 of 4 expected tokens = 25% → below the ≥50% threshold.
        XCTAssertFalse(STTConnectionTestSuite.looselyMatches("testing",
                                                             expected: "testing one two three"),
                       "Only 25% of expected tokens present must NOT match (a fuzzy miss → soft pass upstream).")
    }

    func testLooselyMatchesIgnoresPunctuationAndCase() {
        XCTAssertTrue(STTConnectionTestSuite.looselyMatches("TESTING, One! TWO; three?",
                                                            expected: "testing one two three"),
                      "Matching must be case-insensitive and punctuation-stripped.")
    }

    func testTokenizeStripsPunctuationAndLowercases() {
        XCTAssertEqual(STTConnectionTestSuite.tokenize("Testing, 1 2 3!"),
                       ["testing", "1", "2", "3"],
                       "tokenize must lowercase, strip non-alphanumerics, and split on whitespace runs.")
    }

    func testTokenizeCollapsesMultipleSeparators() {
        XCTAssertEqual(STTConnectionTestSuite.tokenize("a   --  b"),
                       ["a", "b"],
                       "Runs of separators must collapse — no empty tokens.")
    }

    func testExpectedPhraseIsTheBundledClipPhrase() {
        XCTAssertEqual(STTConnectionTestSuite.expectedPhrase, "testing one two three",
                       "The expected phrase must match the bundled clip's spoken words (lowercase, digit-tolerant).")
    }
}
