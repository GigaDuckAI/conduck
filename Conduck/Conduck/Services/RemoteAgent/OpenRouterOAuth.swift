// SPDX-License-Identifier: Apache-2.0

// Conduck
// OpenRouterOAuth.swift
//
// The PKCE machinery behind "Sign in with OpenRouter": it mints the
// authorization transaction, validates the callback the system web-auth sheet
// hands back, and performs the ONE code→key exchange. It owns no state, no
// key, and no UI — the issued key is returned once to the caller and never
// stored, logged, or echoed here.
//
// WHY A CUSTOM URL SCHEME AND NOT https (RFC 8252 §7.1). The redirect target is
// a PRIVATE-USE reverse-DNS scheme supplied by the build-identity layer
// (`CONDUCK_OAUTH_SCHEME` → the `ConduckOAuthCallbackScheme` Info.plist key),
// never a Universal Link. An https callback on Apple's platforms needs
// Associated Domains (`webcredentials`) plus an AASA file served from
// conduck.com and propagated through Apple's CDN, and the entitlement is only
// available to the Official build — so the Community build could not sign in at
// all. Worse is its FAILURE mode: when the association is not live, the OS
// falls back to opening the https URL, which sends the authorization CODE to a
// server we operate. Conduck operates no server that ever sees user
// credentials, and a fallback that quietly creates one is exactly the thing the
// no-backend posture exists to prevent. A bare `conduck:` scheme is rejected
// for the opposite reason: RFC 8252 requires a private-use scheme to be a
// domain the app controls, reversed.
//
// WHY SCHEME SQUATTING IS NOT THE THREAT IT LOOKS LIKE. The callback is
// delivered INSIDE the web-auth session, which returns the URL only to the app
// that started it — a second app registering the same scheme does not receive
// it. And the code alone is worthless: PKCE binds it to a verifier that never
// leaves this process, so an intercepted code cannot be exchanged.
//
// THE HANDLE IS THE NONCE. OpenRouter documents no `state` parameter, so the
// transaction handle (a fresh UUID) rides in the callback PATH and the whole
// expected callback — scheme AND path, exactly — is what `extractCode`
// validates. A callback that does not match the transaction that started it is
// refused, which is the same property `state` would have bought.
//
// RESIDUAL RISK, stated plainly: OpenRouter's own documentation shows https,
// localhost, and headless callbacks; custom schemes are tolerated in practice
// (Cline ships a `vscode://` callback) but are not contractual. If OpenRouter
// ever rejects the scheme, every failure path here still lands the user on the
// paste field with a message — the feature degrades, it does not trap.
//
// AND THE SHAPE MUST ROUND-TRIP UNCHANGED. `extractCode` requires the callback
// back exactly as it went out — single slash, no authority — so a provider that
// re-serialised it to the two-slash `scheme://oauth/openrouter/<handle>` form
// would fail EVERY sign-in. Measured against the live authorization endpoint,
// the single-slash `callback_url` survives OpenRouter's sign-in hop verbatim, so
// the strict comparison is kept rather than loosened on speculation: an
// equality this narrow is what stands in for the `state` parameter OpenRouter
// does not document, and widening it to normalise an authority back into the
// path would trade a checkable invariant for a guess. The failure mode is
// fail-closed and visible — the user lands on the paste field — and the first
// real sign-in on a device settles it either way.
//
// THE EXCHANGE IS ONE ATTEMPT, DELIBERATELY (D3). Exchanging a code CREATES a
// real API key in the user's OpenRouter account, so a retry is not free: it can
// mint a second key the user never asked for. Hence: exactly one `send`, an
// ephemeral session with no URL cache, a fixed timeout, redirects REFUSED (a
// 3xx completes the task instead of replaying the code somewhere else), the
// app-attribution headers, and NO `Authorization` header — the request is
// anonymous by construction. A timeout or a lost response is reported as
// `outcomeUnknown` rather than a failure, because OpenRouter may have created
// the key before the answer went missing; the caller must say so and must never
// retry silently.
//
// A CANCEL IS ONLY SILENT BEFORE THE SEND. `.cancelled` — the one outcome that
// shows the user nothing — is reachable only from the check that runs BEFORE the
// request is handed to the transport, where "nothing happened at OpenRouter" is
// provable. Once the request is in flight, a cancel (the step going away mid
// exchange, which on macOS is reachable because the auth window is separate from
// the app window) is indistinguishable from a timeout: `URLError.cancelled` and
// a `CancellationError` out of the transport both map to `outcomeUnknown`, so
// the user is told a key may exist rather than left with an orphan they were
// never shown — provided the step is still on screen to show it. The one cancel
// that comes from the step itself being torn down mid exchange (a sub-second
// window) loses the notice with the step; that is accepted rather than
// persisted, because the only durable home would be a second store for a
// message about a key this app no longer holds.
//
// NEVER LOGGED: the verifier, the code, and the issued key. No error case
// carries any of them, so no message built from an error can leak one.

import CryptoKit
import Foundation
import Security

// MARK: - Transaction

/// One in-flight sign-in. Created before the web-auth sheet opens, kept by the
/// caller for exactly as long as that sheet is up, and consumed by the
/// exchange. `codeVerifier` is the PKCE secret: it stays in memory, never
/// reaches a view, a log, or the wire except as the exchange body.
nonisolated struct OpenRouterOAuthTransaction: Sendable, Equatable {
    /// The nonce. Rides in the callback path and identifies the transaction —
    /// and, later, the staged key it produced.
    let handle: UUID
    /// PKCE `code_verifier` — 43 base64url characters from 32 random bytes.
    let codeVerifier: String
    /// PKCE `code_challenge` — base64url(SHA256(verifier)), method `S256`.
    let codeChallenge: String
    /// The exact callback the provider must return to, scheme and path both.
    let callbackURL: URL
    /// The URL the web-auth sheet opens.
    let authorizationURL: URL
}

// MARK: - Errors

/// Every way a sign-in can end other than with a key. Deliberately granular on
/// the HTTP side: the caller shows a different sentence for "OpenRouter said
/// no", "OpenRouter is rate-limiting", and "we do not know what happened", and
/// only the last of those is allowed to say a key may exist anyway.
nonisolated enum OpenRouterOAuthError: Error, Equatable {
    /// The system refused to produce cryptographic randomness. There is no
    /// fallback RNG on purpose — a predictable verifier is a broken PKCE
    /// exchange, so the feature declines instead of degrading.
    case randomnessUnavailable
    /// The callback did not match the transaction that started it, carried no
    /// usable code, or the transaction's own URLs could not be formed.
    case invalidCallback
    /// The provider returned `?error=…` — the user declined, or OpenRouter
    /// refused the authorization. `code` is the provider's own token when it
    /// passed the same shape checks the authorization code must pass.
    case providerDenied(code: String?)
    /// HTTP 400 — OpenRouter did not accept the request shape.
    case badRequest
    /// HTTP 403 — OpenRouter rejected the exchange.
    case rejected
    /// HTTP 405 — the endpoint did not accept the method.
    case methodNotAllowed
    /// HTTP 429 — sign-ins are being rate-limited.
    case rateLimited
    /// HTTP 5xx, carrying the status so a report can be specific.
    case serverError(Int)
    /// Any other status the exchange does not have a meaning for.
    case unexpectedStatus(Int)
    /// A 2xx whose body was not the documented `{"key": …}`, or carried an
    /// empty key.
    case malformedResponse
    /// The request never reached OpenRouter.
    case network
    /// The request was SENT and the answer never arrived — a timeout or a lost
    /// connection. OpenRouter may have created the key. This is not a failure
    /// the app may retry on the user's behalf.
    case outcomeUnknown
    /// The sign-in was cancelled BEFORE the request left the app, so nothing
    /// was created at OpenRouter. Silent by contract — the only outcome that
    /// is. A cancel that lands after the send is `outcomeUnknown` instead.
    case cancelled
}

// MARK: - Transport

/// The one network hop this file makes, injectable so the exchange can be
/// tested without a server. Production builds `.live`; tests substitute a
/// closure and count how many times it was called — "exactly once" is a
/// property of this feature, not an implementation detail.
nonisolated struct OpenRouterOAuthTransport: Sendable {
    let send: @Sendable (URLRequest) async throws -> (Data, URLResponse)

    /// The shipping transport: an ephemeral, cache-less, redirect-refusing
    /// session with the exchange timeout on both the request and the resource.
    static let live: OpenRouterOAuthTransport = liveTransport(configuration: liveConfiguration())

    /// The session configuration `.live` uses. Split out so a test can install
    /// a `URLProtocol` stub into `protocolClasses` and exercise the REAL
    /// session policy (redirect refusal, timeouts, no cache) rather than a
    /// hand-made lookalike.
    ///
    /// `.ephemeral` + `urlCache = nil`: an authorization code and the key it
    /// buys must not be written to the shared URL cache, and the session must
    /// not carry system cookies into an anonymous request.
    static func liveConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.timeoutIntervalForRequest = Constants.openRouterOAuthExchangeTimeout
        configuration.timeoutIntervalForResource = Constants.openRouterOAuthExchangeTimeout
        return configuration
    }

    /// Build a transport over `configuration`, installing the redirect refusal
    /// as the session delegate. TEST SEAM: production has exactly one caller
    /// (`.live`); a test passes a stubbed configuration so the delegate and the
    /// timeouts under test are the ones that ship.
    ///
    /// The session is captured by the returned closure, which is what keeps it
    /// — and therefore its strongly-held delegate — alive for the transport's
    /// lifetime.
    static func liveTransport(configuration: URLSessionConfiguration) -> OpenRouterOAuthTransport {
        let session = URLSession(
            configuration: configuration,
            delegate: OpenRouterOAuthRedirectRefusal(),
            delegateQueue: nil
        )
        return OpenRouterOAuthTransport { request in
            try await session.data(for: request)
        }
    }
}

/// Refuses EVERY redirect, same-origin included.
///
/// Unlike an ordinary request, this one carries an authorization code that is
/// good for creating a real API key, so there is no benign reason to replay it
/// at a URL the app did not choose. Answering the completion handler with `nil`
/// completes the task with the 3xx itself, which the exchange classifies as an
/// unexpected status — a visible, non-retried failure rather than a silent hop.
/// (`RemoteAgentTrustEvaluator` permits same-origin redirects because a user's
/// own gateway legitimately canonicalises paths; a fixed, app-supplied endpoint
/// has no such need.)
nonisolated final class OpenRouterOAuthRedirectRefusal: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

// MARK: - OpenRouterOAuth

/// Stateless PKCE helpers for the OpenRouter sign-in. Every value it needs
/// about OpenRouter is derived from `Constants.openRouterBaseURLString` and
/// `Constants.openRouterKeysConsoleURLString`, so there is no second
/// `openrouter.ai` literal to drift.
///
/// Main-actor isolated by the target default, deliberately left that way: it
/// reads `Constants` and stamps headers through `OpenRouterAttribution`, both of
/// which are, and its only caller is a view model. Nothing here blocks — the one
/// suspension point hands the request to `OpenRouterOAuthTransport`, which is
/// `nonisolated` and runs the hop off the main actor.
enum OpenRouterOAuth {

    // MARK: Endpoint shape

    /// Path prefix of the callback; the transaction handle is appended to it.
    /// The full callback is `<scheme>:/oauth/openrouter/<handle>` — ONE slash
    /// after the colon, which is the RFC 8252 private-use shape (no authority
    /// component, so no host to confuse with a path segment).
    nonisolated static let callbackPathPrefix = "/oauth/openrouter/"

    /// Where the web-auth sheet lands. Sits on the bare provider host, NOT on
    /// the `/api` root the wire endpoints use.
    nonisolated static let authorizationPath = "/auth"

    /// Appended to `Constants.openRouterBaseURLString` (which ends at `/api`)
    /// to form the code→key exchange endpoint.
    nonisolated static let exchangePath = "/v1/auth/keys"

    /// Number of random bytes behind the verifier. 32 bytes encode to 43
    /// base64url characters, the RFC 7636 minimum, and carry 256 bits.
    nonisolated static let codeVerifierByteCount = 32

    /// OpenRouter's host, derived from the one locked base-URL constant.
    /// `nil` only if that constant stops parsing, in which case no transaction
    /// can be built and the feature declines rather than dialing a guess.
    nonisolated static let providerHost: String? =
        URL(string: Constants.openRouterBaseURLString)?.host()?.lowercased()

    /// The exchange endpoint. Force-unwrapped for the same reason
    /// `STTProviderMetadata` force-unwraps its console URLs: both halves are
    /// compile-time literals locked by `LockedNetworkAndPairingLiteralsTests`,
    /// so a nil here is a build defect, not a runtime condition.
    nonisolated static let exchangeURL = URL(string: Constants.openRouterBaseURLString + exchangePath)!

    /// OpenRouter's key-management console — where a user goes to see ALL their
    /// keys.
    nonisolated static let keysConsoleURL = URL(string: Constants.openRouterKeysConsoleURLString)!

    /// Parent of the page for ONE key. A different route from `keysConsoleURL`
    /// on OpenRouter's side, not a prefix of it — see
    /// `Constants.openRouterKeySettingsURLString`.
    nonisolated static let keySettingsBaseURL = URL(string: Constants.openRouterKeySettingsURLString)!

    // MARK: Availability

    /// The private-use callback scheme this BUILD claims, read from the
    /// `ConduckOAuthCallbackScheme` Info.plist key (fed by
    /// `CONDUCK_OAUTH_SCHEME`, itself the build's identity namespace). `nil`
    /// when the key is missing, empty, or not a legal URL scheme — the caller
    /// treats that as "sign-in unavailable" and shows only the paste field.
    /// Read fresh rather than cached so a host process without the key never
    /// bakes in a stale answer.
    static var callbackScheme: String? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "ConduckOAuthCallbackScheme") as? String
        else { return nil }
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard isLegalScheme(normalized) else { return nil }
        return normalized
    }

    /// RFC 3986 scheme grammar: `ALPHA *( ALPHA / DIGIT / "+" / "-" / "." )`,
    /// ASCII only. Validated BEFORE it reaches `URLComponents.scheme`, whose
    /// setter raises on an illegal scheme rather than returning an error.
    nonisolated static func isLegalScheme(_ scheme: String) -> Bool {
        guard let first = scheme.first, first.isASCII, first.isLetter else { return false }
        return scheme.allSatisfy { character in
            guard character.isASCII else { return false }
            return character.isLetter || character.isNumber
                || character == "." || character == "-" || character == "+"
        }
    }

    // MARK: Transaction

    /// Mint a fresh transaction for `scheme`.
    ///
    /// `randomBytes` is injectable so the verifier can be made deterministic in
    /// a test; production always uses `secureRandomBytes`, which has no
    /// fallback. Throws `.randomnessUnavailable` when randomness fails and
    /// `.invalidCallback` when the callback or authorization URL cannot be
    /// formed at all (an illegal scheme, or a provider host that stopped
    /// parsing) — both are "this build cannot start a secure sign-in", which is
    /// what the caller reports.
    static func makeTransaction(
        scheme: String,
        randomBytes: (Int) throws -> [UInt8] = secureRandomBytes
    ) throws -> OpenRouterOAuthTransaction {
        let normalizedScheme = scheme.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard isLegalScheme(normalizedScheme) else { throw OpenRouterOAuthError.invalidCallback }

        let handle = UUID()
        let verifier = base64URL(Data(try randomBytes(codeVerifierByteCount)))
        let challenge = codeChallenge(for: verifier)

        var callbackComponents = URLComponents()
        callbackComponents.scheme = normalizedScheme
        callbackComponents.path = callbackPathPrefix + handle.uuidString.lowercased()
        guard let callbackURL = callbackComponents.url else {
            throw OpenRouterOAuthError.invalidCallback
        }

        guard let host = providerHost else { throw OpenRouterOAuthError.invalidCallback }
        var authorizationComponents = URLComponents()
        authorizationComponents.scheme = "https"
        authorizationComponents.host = host
        authorizationComponents.path = authorizationPath
        authorizationComponents.queryItems = [
            URLQueryItem(name: "callback_url", value: callbackURL.absoluteString),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]
        guard let authorizationURL = authorizationComponents.url else {
            throw OpenRouterOAuthError.invalidCallback
        }

        return OpenRouterOAuthTransaction(
            handle: handle,
            codeVerifier: verifier,
            codeChallenge: challenge,
            callbackURL: callbackURL,
            authorizationURL: authorizationURL
        )
    }

    /// Cryptographically secure bytes, or nothing. A failure throws
    /// `.randomnessUnavailable`; there is deliberately no `arc4random` /
    /// `Int.random` fallback, because a verifier the attacker can predict
    /// silently removes the only protection PKCE provides.
    nonisolated static func secureRandomBytes(_ count: Int) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = bytes.withUnsafeMutableBytes { buffer -> Int32 in
            guard let base = buffer.baseAddress else { return errSecParam }
            return SecRandomCopyBytes(kSecRandomDefault, count, base)
        }
        guard status == errSecSuccess else { throw OpenRouterOAuthError.randomnessUnavailable }
        return bytes
    }

    /// base64url per RFC 4648 §5: `-` and `_` for `+` and `/`, no padding.
    nonisolated static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// PKCE `S256`: base64url(SHA256(ASCII(verifier))). Locked against the
    /// RFC 7636 Appendix B vector in the tests.
    nonisolated static func codeChallenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    // MARK: Callback

    /// Validate a callback URL against the transaction that started it and pull
    /// the authorization code out.
    ///
    /// The whole callback must match — scheme (case-insensitively, since the OS
    /// may normalize it) and path exactly, with no authority component, no
    /// fragment, and no second `code`. That equality is what substitutes for
    /// the `state` parameter OpenRouter does not document: a callback minted
    /// for another transaction, or one carrying an extra `code` an attacker
    /// hopes will be read instead of ours, fails here.
    ///
    /// The code itself is OPAQUE — no charset is imposed, because the provider
    /// is free to change its encoding. It is bounded (length, and no whitespace
    /// or control characters) so nothing header-splitting or unbounded can ride
    /// into the exchange body.
    static func extractCode(
        from callback: URL,
        for transaction: OpenRouterOAuthTransaction
    ) -> Result<String, OpenRouterOAuthError> {
        guard let received = URLComponents(url: callback, resolvingAgainstBaseURL: false),
              let expected = URLComponents(url: transaction.callbackURL, resolvingAgainstBaseURL: false)
        else { return .failure(.invalidCallback) }

        guard let receivedScheme = received.scheme?.lowercased(),
              let expectedScheme = expected.scheme?.lowercased(),
              receivedScheme == expectedScheme,
              received.path == expected.path,
              received.host == nil, received.user == nil,
              received.password == nil, received.port == nil,
              received.fragment == nil
        else { return .failure(.invalidCallback) }

        guard let items = received.queryItems, !items.isEmpty else {
            return .failure(.invalidCallback)
        }

        // `?error=` wins over anything else in the query: the provider has
        // already said no, and a code beside it would not be honoured.
        if let denial = items.first(where: { $0.name == "error" }) {
            let reason = denial.value.flatMap { isWellFormedOpaqueValue($0) ? $0 : nil }
            return .failure(.providerDenied(code: reason))
        }

        let codes = items.filter { $0.name == "code" }
        guard codes.count == 1, let code = codes[0].value, isWellFormedOpaqueValue(code) else {
            return .failure(.invalidCallback)
        }
        return .success(code)
    }

    /// Non-empty, bounded, and free of whitespace and control characters — the
    /// only shape constraints placed on provider-supplied opaque text.
    private static func isWellFormedOpaqueValue(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= Constants.openRouterOAuthMaxCodeLength else { return false }
        let forbidden = CharacterSet.whitespacesAndNewlines.union(.controlCharacters)
        return value.rangeOfCharacter(from: forbidden) == nil
    }

    // MARK: Exchange

    /// Build the exchange request. Anonymous by construction — no
    /// `Authorization` header is set, because there is no key yet and the code
    /// is the only credential. Carries the app-attribution headers via the same
    /// host-gated helper every other OpenRouter request uses.
    static func exchangeRequest(
        code: String,
        transaction: OpenRouterOAuthTransaction
    ) -> URLRequest {
        var request = URLRequest(url: exchangeURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = Constants.openRouterOAuthExchangeTimeout
        OpenRouterAttribution.apply(to: &request)
        // Three strings with explicit keys: `JSONEncoder` cannot fail on this,
        // and a silently body-less POST would be a worse failure than a trap.
        request.httpBody = try! JSONEncoder().encode(
            ExchangeBody(
                code: code,
                codeVerifier: transaction.codeVerifier,
                codeChallengeMethod: "S256"
            )
        )
        return request
    }

    /// Perform the exchange. EXACTLY ONE `send`, on every path — success,
    /// failure, timeout. There is no retry here and there must never be one:
    /// the code creates a real key, so a second attempt can mint a second key
    /// the user never asked for.
    ///
    /// A timeout or a lost connection maps to `.outcomeUnknown` rather than
    /// `.network` precisely because the request WAS sent: OpenRouter may have
    /// created the key and only the answer went missing, so the caller has to
    /// tell the user that instead of implying nothing happened.
    ///
    /// CANCELLATION IS SPLIT ON THAT SAME LINE. A cancel observed BEFORE the
    /// send is `.cancelled` — silent, because the code was never spent. A cancel
    /// observed after it is `.outcomeUnknown`, because from here the two are the
    /// same fact: the request is gone and the answer is not coming. Reporting
    /// the second silently would drop the only notice the user gets that a real
    /// key may now be sitting in their OpenRouter account.
    static func exchange(
        code: String,
        transaction: OpenRouterOAuthTransaction,
        transport: OpenRouterOAuthTransport = .live
    ) async -> Result<String, OpenRouterOAuthError> {
        // The ONE place a silent cancel is provable: nothing has been sent yet.
        guard !Task.isCancelled else { return .failure(.cancelled) }

        let request = exchangeRequest(code: code, transaction: transaction)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await transport.send(request)
        } catch is CancellationError {
            // Thrown from inside the send, so the request was already handed
            // over — same unknown outcome as a timeout, not a silent cancel.
            return .failure(.outcomeUnknown)
        } catch let error as URLError {
            switch error.code {
            case .timedOut, .networkConnectionLost, .cancelled:
                // URLSession reports a cancelled task as `URLError.cancelled`,
                // and it only has a task to cancel once the request reached it.
                return .failure(.outcomeUnknown)
            default:
                return .failure(.network)
            }
        } catch {
            return .failure(.network)
        }

        guard let http = response as? HTTPURLResponse else { return .failure(.malformedResponse) }
        switch http.statusCode {
        case 200...299: break
        case 400: return .failure(.badRequest)
        case 403: return .failure(.rejected)
        case 405: return .failure(.methodNotAllowed)
        case 429: return .failure(.rateLimited)
        case 500...599: return .failure(.serverError(http.statusCode))
        default: return .failure(.unexpectedStatus(http.statusCode))
        }

        guard let decoded = try? JSONDecoder().decode(ExchangeResponse.self, from: data) else {
            return .failure(.malformedResponse)
        }
        let key = decoded.key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return .failure(.malformedResponse) }
        return .success(key)
    }

    // MARK: Key management deep link

    /// The OpenRouter page for THIS key. OpenRouter addresses a key by the
    /// lowercase SHA-256 hex of the key itself — the same digest its
    /// provisioning API uses as a path parameter — so the link can be built
    /// entirely on-device: the key never leaves, only its digest, and only
    /// inside a URL the user opens themselves.
    ///
    /// This exists because the exchange creates the key immediately: a user who
    /// backs out afterwards has removed only Conduck's copy, and needs a way to
    /// delete the real one. It is therefore the ONE link that must land on a
    /// real page, which is why it is built on the per-key route rather than on
    /// the key-list console.
    static func keySettingsURL(forKey key: String) -> URL {
        let digest = SHA256.hash(data: Data(key.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return keySettingsBaseURL.appendingPathComponent(hex)
    }

    // MARK: - Wire shapes

    private struct ExchangeBody: Encodable {
        let code: String
        let codeVerifier: String
        let codeChallengeMethod: String

        enum CodingKeys: String, CodingKey {
            case code
            case codeVerifier = "code_verifier"
            case codeChallengeMethod = "code_challenge_method"
        }
    }

    private struct ExchangeResponse: Decodable {
        let key: String
    }
}
