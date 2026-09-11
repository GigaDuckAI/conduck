// SPDX-License-Identifier: Apache-2.0

// Conduck
// OpenRouterOAuthTests.swift
//
// Locks the PKCE contract behind "Sign in with OpenRouter". Three properties
// here are safety-critical rather than merely correct, and none of them fails
// visibly in normal use — only a test notices:
//
//   1. THE CHALLENGE IS REALLY S256. A verifier/challenge pair that is subtly
//      wrong (padding left on, the standard base64 alphabet instead of the
//      URL-safe one, hashing the bytes of a decoded verifier instead of its
//      ASCII) still LOOKS like PKCE and still round-trips through a permissive
//      server — while providing none of PKCE's protection. The RFC 7636
//      Appendix B vector is the only way to tell the difference.
//   2. THE CALLBACK IS THE NONCE. OpenRouter documents no `state` parameter, so
//      the full expected callback — scheme AND path, with the transaction's
//      handle in it — is the entire replay defence. Every way that check can be
//      weakened (a wrong handle, a smuggled authority component, a second
//      `code` an attacker hopes wins, a fragment) is asserted rejected.
//   3. THE EXCHANGE HAPPENS EXACTLY ONCE. Exchanging the code CREATES a real
//      API key in the user's OpenRouter account, so a retry is not free — it
//      mints a key the user never asked for. Every case below counts transport
//      invocations, failures included.
//
// Deterministic + headless: no network, no Keychain, no stores. The redirect
// tests install a `URLProtocol` stub into the REAL live-session configuration,
// and one of them drives the redirect through `URLSessionTaskDelegate` rather
// than merely returning a 3xx body — a stub that only ANSWERS with a 307 never
// consults the delegate, so it would pass with the delegate unwired. Only the
// delegate-driven case proves the policy the shipping transport actually
// installs.

import XCTest
@testable import Conduck

final class OpenRouterOAuthTests: XCTestCase {

    // MARK: - Helpers

    /// Thread-safe invocation counter. "Exactly one send" is the property under
    /// test in every exchange case, so it is counted, never assumed.
    nonisolated private final class CallCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func increment() {
            lock.lock()
            value += 1
            lock.unlock()
        }
        var count: Int {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    /// A deterministic transaction: the injected bytes make the verifier
    /// reproducible, so a body assertion can name it exactly.
    private static func fixtureTransaction(
        scheme: String = "com.example.conduck",
        byte: UInt8 = 0x2A
    ) throws -> OpenRouterOAuthTransaction {
        try OpenRouterOAuth.makeTransaction(
            scheme: scheme,
            randomBytes: { count in Array(repeating: byte, count: count) }
        )
    }

    nonisolated private static func httpResponse(_ status: Int) -> HTTPURLResponse {
        HTTPURLResponse(
            url: OpenRouterOAuth.exchangeURL,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
    }

    /// Run one exchange against a scripted transport and return both the result
    /// and how many times the transport was actually invoked.
    private func runExchange(
        code: String = "auth-code-123",
        transaction: OpenRouterOAuthTransaction,
        _ handler: @escaping @Sendable (URLRequest) throws -> (Data, URLResponse)
    ) async -> (result: Result<String, OpenRouterOAuthError>, sends: Int) {
        let counter = CallCounter()
        let transport = OpenRouterOAuthTransport { request in
            counter.increment()
            return try handler(request)
        }
        let result = await OpenRouterOAuth.exchange(
            code: code,
            transaction: transaction,
            transport: transport
        )
        return (result, counter.count)
    }

    private func expectFailure(
        _ result: Result<String, OpenRouterOAuthError>,
        _ expected: OpenRouterOAuthError,
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        switch result {
        case .success(let key):
            XCTFail("\(message): expected \(expected), got a key of \(key.count) characters.",
                    file: file, line: line)
        case .failure(let error):
            XCTAssertEqual(error, expected, message, file: file, line: line)
        }
    }

    // MARK: - PKCE primitives

    func testCodeChallengeMatchesRFC7636AppendixBVector() {
        // The published vector. If this fails, the challenge is not S256 —
        // whatever else it may be.
        XCTAssertEqual(
            OpenRouterOAuth.codeChallenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"),
            "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM",
            "code_challenge must be base64url(SHA256(ASCII(verifier))) per RFC 7636 Appendix B."
        )
    }

    func testBase64URLDropsPaddingAndUsesTheURLSafeAlphabet() {
        // 0xfb 0xff 0xfe encodes to "+//+" in standard base64 — every character
        // that must be substituted, in one vector.
        XCTAssertEqual(OpenRouterOAuth.base64URL(Data([0xFB, 0xFF, 0xFE])), "-__-",
                       "base64url uses '-' and '_' in place of '+' and '/'.")
        XCTAssertEqual(OpenRouterOAuth.base64URL(Data([0x00])), "AA",
                       "base64url is unpadded — '=' is not a legal character in a verifier.")
        XCTAssertEqual(OpenRouterOAuth.base64URL(Data([0x00, 0x00])), "AAA",
                       "…including the two-character padding case.")
        XCTAssertEqual(OpenRouterOAuth.base64URL(Data()), "",
                       "Empty in, empty out.")
    }

    func testVerifierIs43CharactersFromThe32ByteBudget() throws {
        let transaction = try Self.fixtureTransaction()
        XCTAssertEqual(OpenRouterOAuth.codeVerifierByteCount, 32,
                       "32 random bytes is 256 bits of entropy behind the verifier.")
        XCTAssertEqual(transaction.codeVerifier.count, 43,
                       "32 bytes base64url-encode to 43 characters — RFC 7636's minimum length.")
        XCTAssertFalse(transaction.codeVerifier.contains("="),
                       "A padded verifier is not a legal RFC 7636 verifier.")
        XCTAssertEqual(transaction.codeChallenge,
                       OpenRouterOAuth.codeChallenge(for: transaction.codeVerifier),
                       "The transaction's challenge must be the challenge OF its own verifier.")
    }

    func testMakeTransactionPropagatesRandomnessFailure() {
        // No fallback RNG: a system that cannot produce randomness must stop the
        // sign-in, not weaken it.
        XCTAssertThrowsError(
            try OpenRouterOAuth.makeTransaction(
                scheme: "com.example.conduck",
                randomBytes: { _ in throw OpenRouterOAuthError.randomnessUnavailable }
            )
        ) { error in
            XCTAssertEqual(error as? OpenRouterOAuthError, .randomnessUnavailable)
        }
    }

    func testMakeTransactionRejectsAnIllegalScheme() {
        // `URLComponents.scheme` RAISES on an illegal scheme rather than
        // returning an error, so the guard has to happen before it.
        // "cönduck" is the only fixture that reaches the non-ASCII arm — every
        // other rejection here is caught by the letter/digit/punctuation rule.
        for illegal in ["9conduck", "con duck", "con_duck", "", "-conduck", "cönduck", "conduck\u{0301}"] {
            XCTAssertThrowsError(try Self.fixtureTransaction(scheme: illegal),
                                 "'\(illegal)' is not a legal URL scheme.") { error in
                XCTAssertEqual(error as? OpenRouterOAuthError, .invalidCallback)
            }
        }
    }

    // MARK: - Transaction URLs

    func testCallbackURLIsTheRFC8252SingleSlashShape() throws {
        let transaction = try Self.fixtureTransaction()
        XCTAssertEqual(
            transaction.callbackURL.absoluteString,
            "com.example.conduck:/oauth/openrouter/\(transaction.handle.uuidString.lowercased())",
            "One slash after the colon: a private-use scheme carries no authority component."
        )
        XCTAssertNil(transaction.callbackURL.host(),
                     "A host would make the first path segment ambiguous.")
        XCTAssertEqual(OpenRouterOAuth.callbackPathPrefix, "/oauth/openrouter/")
    }

    func testAuthorizationURLCarriesTheCallbackAndTheS256Challenge() throws {
        let transaction = try Self.fixtureTransaction()
        let components = try XCTUnwrap(
            URLComponents(url: transaction.authorizationURL, resolvingAgainstBaseURL: false)
        )

        XCTAssertEqual(components.scheme, "https")
        XCTAssertEqual(components.host, OpenRouterOAuth.providerHost,
                       "The sheet opens on the provider host derived from the locked base URL.")
        XCTAssertEqual(components.path, "/auth")
        XCTAssertEqual(OpenRouterOAuth.authorizationPath, "/auth")

        let items = try XCTUnwrap(components.queryItems)
        let byName = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value) })
        XCTAssertEqual(byName["callback_url"], transaction.callbackURL.absoluteString,
                       "The callback must round-trip verbatim — it is what the provider returns to.")
        XCTAssertEqual(byName["code_challenge"], transaction.codeChallenge)
        XCTAssertEqual(byName["code_challenge_method"], "S256",
                       "Plain PKCE is not acceptable; only S256 binds the code to the verifier.")
        XCTAssertEqual(Set(byName.keys), ["callback_url", "code_challenge", "code_challenge_method"],
                       "No extra parameters ride along uninspected.")
        XCTAssertNil(byName["code_verifier"] ?? nil,
                     "The VERIFIER must never appear in the authorization URL — that is the secret.")
    }

    func testTwoTransactionsNeverShareAHandleOrAVerifier() throws {
        let first = try OpenRouterOAuth.makeTransaction(scheme: "com.example.conduck")
        let second = try OpenRouterOAuth.makeTransaction(scheme: "com.example.conduck")
        XCTAssertNotEqual(first.handle, second.handle)
        XCTAssertNotEqual(first.codeVerifier, second.codeVerifier,
                          "A repeated verifier would let one sign-in's code be replayed into another.")
    }

    func testProviderHostTracksTheLockedBaseURL() {
        // One derivation, not a second `openrouter.ai` literal — and it must
        // agree with the attribution gate, which derives from the same constant.
        XCTAssertEqual(OpenRouterOAuth.providerHost,
                       URL(string: Constants.openRouterBaseURLString)?.host()?.lowercased())
        XCTAssertEqual(OpenRouterOAuth.providerHost, OpenRouterAttribution.attributedHost)
        XCTAssertNotNil(OpenRouterOAuth.providerHost)
    }

    // MARK: - Callback scheme comes from the build identity

    func testCallbackSchemeIsReadFromTheInfoPlistKey() throws {
        // Value-agnostic on purpose: the scheme is build identity (Community vs
        // the private override), so the test asserts the SHAPE the RFC 8252
        // private-use rule requires, never a particular namespace.
        let scheme = try XCTUnwrap(
            OpenRouterOAuth.callbackScheme,
            "ConduckOAuthCallbackScheme must be present in the host app's Info.plist."
        )
        XCTAssertFalse(scheme.isEmpty)
        XCTAssertEqual(scheme, scheme.lowercased(), "URL schemes are compared lowercased.")
        XCTAssertTrue(scheme.contains("."),
                      "A private-use scheme is reverse-DNS — a bare word would be squattable.")
        XCTAssertTrue(OpenRouterOAuth.isLegalScheme(scheme),
                      "The build's scheme must satisfy the RFC 3986 scheme grammar.")

        let namespace = try XCTUnwrap(
            Bundle.main.object(forInfoDictionaryKey: "ConduckIdentityNamespace") as? String
        )
        XCTAssertEqual(scheme, namespace.lowercased(),
                       "CONDUCK_OAUTH_SCHEME is derived from CONDUCK_IDENTITY_NAMESPACE — "
                       + "if these drift, two builds could claim the same scheme.")
    }

    func testUrlTypesRegisterExactlyTheSchemeTheAppReads() throws {
        // LaunchServices registers CFBundleURLTypes; the app reads
        // ConduckOAuthCallbackScheme. A build where those disagree opens a sheet
        // that can never come back.
        let scheme = try XCTUnwrap(OpenRouterOAuth.callbackScheme)
        let types = try XCTUnwrap(
            Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]]
        )
        let registered = types.flatMap { ($0["CFBundleURLSchemes"] as? [String]) ?? [] }
        XCTAssertEqual(registered.map { $0.lowercased() }, [scheme],
                       "Exactly one scheme is claimed, and it is the one the app validates against.")
    }

    // MARK: - Callback validation

    func testExtractCodeAcceptsAWellFormedCallback() throws {
        let transaction = try Self.fixtureTransaction()
        let callback = URL(string: transaction.callbackURL.absoluteString + "?code=abc")!
        switch OpenRouterOAuth.extractCode(from: callback, for: transaction) {
        case .success(let code): XCTAssertEqual(code, "abc")
        case .failure(let error): XCTFail("Expected the code, got \(error).")
        }
    }

    func testExtractCodeMatchesTheSchemeCaseInsensitively() throws {
        let transaction = try Self.fixtureTransaction()
        let upper = "COM.EXAMPLE.CONDUCK:/oauth/openrouter/"
            + transaction.handle.uuidString.lowercased() + "?code=abc"
        switch OpenRouterOAuth.extractCode(from: URL(string: upper)!, for: transaction) {
        case .success(let code): XCTAssertEqual(code, "abc")
        case .failure(let error): XCTFail("Scheme comparison must be case-insensitive; got \(error).")
        }
    }

    func testExtractCodeReportsProviderDenial() throws {
        let transaction = try Self.fixtureTransaction()
        let denied = URL(string: transaction.callbackURL.absoluteString + "?error=access_denied")!
        switch OpenRouterOAuth.extractCode(from: denied, for: transaction) {
        case .success: XCTFail("A denial must never be read as a code.")
        case .failure(let error): XCTAssertEqual(error, .providerDenied(code: "access_denied"))
        }
    }

    func testExtractCodePrefersTheDenialOverACodeBesideIt() throws {
        // If the provider said no, a `code` in the same callback is not ours to
        // spend — reading it would be the replay this check exists to stop.
        let transaction = try Self.fixtureTransaction()
        let mixed = URL(string: transaction.callbackURL.absoluteString + "?code=abc&error=access_denied")!
        switch OpenRouterOAuth.extractCode(from: mixed, for: transaction) {
        case .success: XCTFail("A callback carrying ?error= must not yield a code.")
        case .failure(let error): XCTAssertEqual(error, .providerDenied(code: "access_denied"))
        }
    }

    func testExtractCodeRejectsEveryMalformedCallback() throws {
        let transaction = try Self.fixtureTransaction()
        let base = transaction.callbackURL.absoluteString
        let handle = transaction.handle.uuidString.lowercased()
        let overLength = String(repeating: "a", count: Constants.openRouterOAuthMaxCodeLength + 1)

        let rejected: [(String, String)] = [
            (base, "no query at all"),
            (base + "?code=", "an empty code"),
            (base + "?code=abc&code=def", "two code items — an attacker hoping the wrong one wins"),
            (base + "?state=abc", "a query with no code"),
            ("com.other.app:/oauth/openrouter/\(handle)?code=abc", "a different scheme"),
            ("com.example.conduck:/oauth/openrouter/\(UUID().uuidString.lowercased())?code=abc",
             "a different handle — the nonce did not match"),
            ("com.example.conduck:/oauth/other/\(handle)?code=abc", "a different path"),
            ("com.example.conduck://oauth/openrouter/\(handle)?code=abc",
             "an authority component smuggled in via a double slash"),
            // The three below carry the EXACT expected path, so the path guard
            // cannot catch them — the AUTHORITY guard is the only thing between a
            // hostile authorization page and an attacker-supplied code being
            // exchanged into the user's app. (`URLComponents` reports an empty
            // host rather than nil for the last two, so `host == nil` is what
            // rejects all three; the user/password/port checks beside it are
            // defence in depth against a future parser that disagrees.)
            ("com.example.conduck://evil.example/oauth/openrouter/\(handle)?code=abc",
             "a host beside a MATCHING path"),
            ("com.example.conduck://user:secret@/oauth/openrouter/\(handle)?code=abc",
             "userinfo beside a matching path"),
            ("com.example.conduck://:8080/oauth/openrouter/\(handle)?code=abc",
             "a port beside a matching path"),
            (base + "?code=abc#fragment", "a fragment"),
            (base + "?code=abc%0Adef", "a newline inside the code"),
            (base + "?code=abc%00def", "a NUL inside the code"),
            (base + "?code=abc%20def", "whitespace inside the code"),
            (base + "?code=" + overLength, "a code past the length ceiling"),
        ]

        for (string, why) in rejected {
            let url = try XCTUnwrap(URL(string: string), "fixture URL for \(why)")
            switch OpenRouterOAuth.extractCode(from: url, for: transaction) {
            case .success(let code):
                XCTFail("Accepted \(why) and returned a code of \(code.count) characters.")
            case .failure(let error):
                XCTAssertEqual(error, .invalidCallback, "Rejecting \(why)")
            }
        }
    }

    func testExtractCodeAcceptsACodeAtExactlyTheLengthCeiling() throws {
        let transaction = try Self.fixtureTransaction()
        let atLimit = String(repeating: "a", count: Constants.openRouterOAuthMaxCodeLength)
        let url = URL(string: transaction.callbackURL.absoluteString + "?code=" + atLimit)!
        switch OpenRouterOAuth.extractCode(from: url, for: transaction) {
        case .success(let code): XCTAssertEqual(code.count, Constants.openRouterOAuthMaxCodeLength)
        case .failure(let error): XCTFail("The ceiling is inclusive; got \(error).")
        }
    }

    func testExtractCodeTreatsTheCodeAsOpaque() throws {
        // No charset is imposed: the provider is free to change its encoding,
        // and a charset guess would break sign-in for everyone at once.
        let transaction = try Self.fixtureTransaction()
        let odd = "AbC-_.~123%2Fslash"
        let url = URL(string: transaction.callbackURL.absoluteString + "?code=" + odd)!
        switch OpenRouterOAuth.extractCode(from: url, for: transaction) {
        case .success(let code): XCTAssertEqual(code, "AbC-_.~123/slash")
        case .failure(let error): XCTFail("An opaque code must survive intact; got \(error).")
        }
    }

    // MARK: - Exchange request shape

    func testExchangeRequestIsAnAnonymousJSONPost() throws {
        let transaction = try Self.fixtureTransaction()
        let request = OpenRouterOAuth.exchangeRequest(code: "abc", transaction: transaction)

        XCTAssertEqual(request.url?.absoluteString,
                       Constants.openRouterBaseURLString + "/v1/auth/keys")
        XCTAssertEqual(OpenRouterOAuth.exchangePath, "/v1/auth/keys")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertEqual(request.timeoutInterval, Constants.openRouterOAuthExchangeTimeout)

        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"),
                     "There is no key yet — the exchange is anonymous by construction.")

        // Attribution rides here like on every other OpenRouter request.
        XCTAssertEqual(request.value(forHTTPHeaderField: "HTTP-Referer"),
                       Constants.openRouterAttributionReferer)
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-OpenRouter-Title"),
                       Constants.openRouterAttributionTitle)
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-OpenRouter-Categories"),
                       Constants.openRouterAttributionCategories)

        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: body) as? [String: String]
        )
        XCTAssertEqual(Set(json.keys), ["code", "code_verifier", "code_challenge_method"],
                       "Exactly the three documented fields — nothing else leaves with the code.")
        XCTAssertEqual(json["code"], "abc")
        XCTAssertEqual(json["code_verifier"], transaction.codeVerifier)
        XCTAssertEqual(json["code_challenge_method"], "S256")
    }

    // MARK: - Exchange outcomes (every one counts its sends)

    func testExchangeReturnsTheIssuedKey() async throws {
        let transaction = try Self.fixtureTransaction()
        let (result, sends) = await runExchange(transaction: transaction) { _ in
            (Data(#"{"key":"sk-or-v1-issued"}"#.utf8), Self.httpResponse(200))
        }
        switch result {
        case .success(let key): XCTAssertEqual(key, "sk-or-v1-issued")
        case .failure(let error): XCTFail("Expected the issued key, got \(error).")
        }
        XCTAssertEqual(sends, 1)
    }

    func testExchangeRejectsA200WithNoUsableKey() async throws {
        let transaction = try Self.fixtureTransaction()
        let bodies = [
            (#"{"ok":true}"#, "no key field"),
            (#"{"key":""}"#, "an empty key"),
            (#"{"key":"   "}"#, "a whitespace-only key"),
            ("not json at all", "a non-JSON body"),
            ("", "an empty body"),
        ]
        for (body, why) in bodies {
            let (result, sends) = await runExchange(transaction: transaction) { _ in
                (Data(body.utf8), Self.httpResponse(200))
            }
            expectFailure(result, .malformedResponse, "A 200 with \(why)")
            XCTAssertEqual(sends, 1, "Still exactly one send for \(why).")
        }
    }

    func testExchangeMapsEveryStatusItHasAMeaningFor() async throws {
        let transaction = try Self.fixtureTransaction()
        let cases: [(Int, OpenRouterOAuthError)] = [
            (400, .badRequest),
            (403, .rejected),
            (405, .methodNotAllowed),
            (429, .rateLimited),
            (500, .serverError(500)),
            (502, .serverError(502)),
            (418, .unexpectedStatus(418)),
            (301, .unexpectedStatus(301)),
        ]
        for (status, expected) in cases {
            let (result, sends) = await runExchange(transaction: transaction) { _ in
                (Data(), Self.httpResponse(status))
            }
            expectFailure(result, expected, "HTTP \(status)")
            XCTAssertEqual(sends, 1, "HTTP \(status) must not be retried.")
        }
    }

    func testTimeoutAndLostConnectionAreOutcomeUnknownNotFailure() async throws {
        // The request WAS sent: OpenRouter may have created the key and only the
        // answer went missing. Calling that "network error" would invite a retry
        // that mints a second key.
        let transaction = try Self.fixtureTransaction()
        for code in [URLError.Code.timedOut, .networkConnectionLost] {
            let (result, sends) = await runExchange(transaction: transaction) { _ in
                throw URLError(code)
            }
            expectFailure(result, .outcomeUnknown, "URLError \(code.rawValue)")
            XCTAssertEqual(sends, 1, "A lost outcome is never re-sent.")
        }
    }

    func testUnreachableNetworkIsAPlainNetworkFailure() async throws {
        let transaction = try Self.fixtureTransaction()
        for code in [URLError.Code.notConnectedToInternet, .cannotFindHost, .secureConnectionFailed] {
            let (result, sends) = await runExchange(transaction: transaction) { _ in
                throw URLError(code)
            }
            expectFailure(result, .network, "URLError \(code.rawValue)")
            XCTAssertEqual(sends, 1)
        }
    }

    /// A cancel that lands AFTER the request was handed to the transport is NOT
    /// the silent one. The exchange creates a real key at OpenRouter, so once
    /// the request is gone the outcome is genuinely unknown — reporting silence
    /// would drop the only notice the user ever gets that a key may now be
    /// sitting in their account, and this is the reachable case: the step's
    /// teardown cancels the sign-in task, and on macOS the app window stays
    /// clickable while the auth window is up.
    func testACancelAfterTheSendIsAnUnknownOutcome() async throws {
        let transaction = try Self.fixtureTransaction()

        let (structured, structuredSends) = await runExchange(transaction: transaction) { _ in
            throw CancellationError()
        }
        expectFailure(structured, .outcomeUnknown, "A cancel thrown from inside the send")
        XCTAssertEqual(structuredSends, 1)

        // URLSession reports a cancelled task as URLError.cancelled, and it only
        // has a task to cancel once the request reached it.
        let (urlLevel, urlSends) = await runExchange(transaction: transaction) { _ in
            throw URLError(.cancelled)
        }
        expectFailure(urlLevel, .outcomeUnknown, "A cancelled URLSession task")
        XCTAssertEqual(urlSends, 1)
    }

    /// The ONE silent cancel: observed before the request is built, so "nothing
    /// happened at OpenRouter" is provable rather than assumed. The task below
    /// is main-actor isolated like this test, so it cannot begin until the test
    /// suspends at `await task.value` — `cancel()` is therefore guaranteed to
    /// land first, with no sleep and no race.
    func testACancelBeforeTheSendIsSilentAndSendsNothing() async throws {
        let transaction = try Self.fixtureTransaction()
        let counter = CallCounter()
        let transport = OpenRouterOAuthTransport { _ in
            counter.increment()
            return (Data(), Self.httpResponse(200))
        }

        let task = Task {
            await OpenRouterOAuth.exchange(
                code: "abc",
                transaction: transaction,
                transport: transport
            )
        }
        task.cancel()
        let result = await task.value

        expectFailure(result, .cancelled, "A cancel observed before the send")
        XCTAssertEqual(counter.count, 0,
                       "Nothing may be sent once the sign-in is already cancelled.")
    }

    func testANonHTTPResponseIsMalformed() async throws {
        let transaction = try Self.fixtureTransaction()
        let (result, sends) = await runExchange(transaction: transaction) { request in
            (Data(), URLResponse(url: request.url!, mimeType: nil,
                                 expectedContentLength: 0, textEncodingName: nil))
        }
        expectFailure(result, .malformedResponse, "A response with no status line")
        XCTAssertEqual(sends, 1)
    }

    func testAnArbitraryThrownErrorIsANetworkFailure() async throws {
        struct Odd: Error {}
        let transaction = try Self.fixtureTransaction()
        let (result, sends) = await runExchange(transaction: transaction) { _ in throw Odd() }
        expectFailure(result, .network, "An unclassified transport error")
        XCTAssertEqual(sends, 1)
    }

    // MARK: - Live transport policy

    /// Stub that signals a redirect the way the URL loading system does —
    /// through `urlProtocol(_:wasRedirectedTo:redirectResponse:)`, which is the
    /// ONLY thing that makes `URLSession` consult
    /// `willPerformHTTPRedirection` on its delegate. A stub that merely ANSWERS
    /// with a 307 (as `MockURLProtocol` does) never reaches the delegate, so a
    /// test built on one passes whether or not the shipping transport installs
    /// the refusal — which is the coverage hole this class exists to close.
    ///
    /// The follow-up request is answered with a perfectly good key, so a session
    /// that DOES follow the redirect returns `.success` and the test fails loudly
    /// rather than merely counting differently.
    nonisolated final class RedirectingURLProtocol: URLProtocol {
        nonisolated(unsafe) static var startedURLs: [URL] = []
        static let elsewhere = URL(string: "https://example.invalid/elsewhere")!

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            let url = request.url!
            Self.startedURLs.append(url)
            if url == Self.elsewhere {
                // The redirect target, answering as a fully successful exchange.
                let response = HTTPURLResponse(
                    url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil
                )!
                let body = Data(#"{"key":"sk-or-followed-the-redirect"}"#.utf8)
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: body)
                client?.urlProtocolDidFinishLoading(self)
                return
            }
            let redirect = HTTPURLResponse(
                url: url,
                statusCode: 307,
                httpVersion: "HTTP/1.1",
                headerFields: ["Location": Self.elsewhere.absoluteString]
            )!
            client?.urlProtocol(
                self,
                wasRedirectedTo: URLRequest(url: Self.elsewhere),
                redirectResponse: redirect
            )
            client?.urlProtocol(self, didReceive: redirect, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }

    /// The delegate is WIRED, not merely written. Deleting it from
    /// `liveTransport(configuration:)` makes this test fail: the session follows
    /// the 307, the stub answers the target with a valid key, and the exchange
    /// reports `.success` — which in production is the authorization code AND
    /// the PKCE verifier handed to whatever the `Location` header named.
    func testTheShippingSessionRefusesARealRedirect() async throws {
        RedirectingURLProtocol.startedURLs = []
        defer { RedirectingURLProtocol.startedURLs = [] }

        let configuration = OpenRouterOAuthTransport.liveConfiguration()
        configuration.protocolClasses = [RedirectingURLProtocol.self]
        let transport = OpenRouterOAuthTransport.liveTransport(configuration: configuration)

        let transaction = try Self.fixtureTransaction()
        let result = await OpenRouterOAuth.exchange(
            code: "abc", transaction: transaction, transport: transport
        )

        if case .success = result {
            XCTFail("The redirect was followed — the refusal delegate is not installed on the shipping session.")
        }
        XCTAssertFalse(
            RedirectingURLProtocol.startedURLs.contains(RedirectingURLProtocol.elsewhere),
            "The redirect target was dialed: the code and the PKCE verifier left for a URL the app did not choose."
        )
        XCTAssertEqual(RedirectingURLProtocol.startedURLs, [OpenRouterOAuth.exchangeURL],
                       "Exactly one request left the app, to the endpoint the exchange chose.")
    }

    func testLiveConfigurationIsEphemeralCachelessAndTimeBounded() {
        let configuration = OpenRouterOAuthTransport.liveConfiguration()
        XCTAssertNil(configuration.urlCache,
                     "A code-bearing exchange must not be written to a URL cache.")
        XCTAssertEqual(configuration.requestCachePolicy, .reloadIgnoringLocalAndRemoteCacheData)
        XCTAssertEqual(configuration.timeoutIntervalForRequest,
                       Constants.openRouterOAuthExchangeTimeout)
        XCTAssertEqual(configuration.timeoutIntervalForResource,
                       Constants.openRouterOAuthExchangeTimeout)
        XCTAssertFalse(configuration.httpShouldSetCookies)
    }

    func testTheRedirectDelegateRefusesEveryRedirect() {
        // Asserted directly as well as through the session below, because a
        // URLProtocol stub can answer a 3xx without URLSession ever consulting
        // the delegate — the session-level test proves no second request is
        // made; this one proves the policy itself is "refuse".
        let delegate = OpenRouterOAuthRedirectRefusal()
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: URLRequest(url: OpenRouterOAuth.exchangeURL))
        let elsewhere = URL(string: "https://example.com/elsewhere")!
        let redirect = HTTPURLResponse(
            url: OpenRouterOAuth.exchangeURL,
            statusCode: 307,
            httpVersion: "HTTP/1.1",
            headerFields: ["Location": elsewhere.absoluteString]
        )!

        let decided = expectation(description: "redirect decision")
        delegate.urlSession(
            session,
            task: task,
            willPerformHTTPRedirection: redirect,
            newRequest: URLRequest(url: elsewhere)
        ) { followUp in
            XCTAssertNil(followUp, "An authorization code must never be replayed at a new URL.")
            decided.fulfill()
        }
        wait(for: [decided], timeout: 1)
        task.cancel()
    }

    func testLiveTransportDoesNotFollowA307() async throws {
        let counter = CallCounter()
        MockURLProtocol.requestHandler = { request in
            counter.increment()
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 307,
                httpVersion: "HTTP/1.1",
                headerFields: ["Location": "https://example.com/elsewhere"]
            )!
            return (response, Data())
        }
        defer { MockURLProtocol.requestHandler = nil }

        let configuration = OpenRouterOAuthTransport.liveConfiguration()
        configuration.protocolClasses = [MockURLProtocol.self]
        let transport = OpenRouterOAuthTransport.liveTransport(configuration: configuration)

        let transaction = try Self.fixtureTransaction()
        let result = await OpenRouterOAuth.exchange(
            code: "abc",
            transaction: transaction,
            transport: transport
        )

        switch result {
        case .success:
            XCTFail("A redirected exchange must never be reported as a issued key.")
        case .failure(let error):
            XCTAssertEqual(error, .unexpectedStatus(307),
                           "The 3xx itself is the outcome — it is not followed.")
        }
        XCTAssertEqual(counter.count, 1,
                       "Exactly one request left the app: the redirect target was never dialed.")
    }

    // MARK: - Key management deep link

    func testKeySettingsURLIsThePerKeyRoutePlusTheKeysSHA256() {
        // Vector: sha256("sk-or-v1-conduck-test-key"). The key itself never
        // leaves the device — only this digest, inside a URL the user opens.
        let url = OpenRouterOAuth.keySettingsURL(forKey: "sk-or-v1-conduck-test-key")
        XCTAssertEqual(
            url.absoluteString,
            "https://openrouter.ai/settings/keys/205029608c1ae79c989cca55e5362663ef323b3821540439e25f467dde1451e2"
        )
        XCTAssertTrue(url.absoluteString.hasPrefix(Constants.openRouterKeySettingsURLString + "/"),
                      "The deep link is the PER-KEY route plus one path component.")
        // The key LIST and a single key are different routes on OpenRouter's
        // site: `/keys/<digest>` resolves to neither, and this link is the whole
        // remedy for a key the exchange already created — it has to land.
        XCTAssertFalse(url.absoluteString.hasPrefix(Constants.openRouterKeysConsoleURLString + "/"),
                       "The per-key page is NOT the key-list console plus a path component.")
        XCTAssertFalse(url.absoluteString.contains("sk-or"),
                       "The key must not appear in a URL the user can see or share.")
    }

    func testKeySettingsURLIsLowercaseHexOfTheRightLength() {
        let url = OpenRouterOAuth.keySettingsURL(forKey: "another-key")
        let digest = url.lastPathComponent
        XCTAssertEqual(digest.count, 64, "SHA-256 is 32 bytes — 64 hex characters.")
        XCTAssertEqual(digest, digest.lowercased())
        XCTAssertTrue(digest.allSatisfy { $0.isHexDigit })
    }
}
