// Conduck
// RemoteAgentClient+TestConnection.swift
//
// Settings: Personal AI. Interactive "Test Connection" probe
// used by `SettingsViewModel.validateAndSaveRemoteAgent(...)`. Distinct
// from `RemoteAgentClient.send(...)` (the converse hop) on three axes:
//
//   - Endpoint: `GET /v1/models` instead of `POST /v1/chat/completions`.
//     Both OpenClaw and Hermes expose `/v1/models` as the OpenAI-
//     compatible listing endpoint; 200 means token + connectivity are
//     OK; no audio / tokens are consumed.
//   - Timeout: 15 s short — user-visible spinner, NOT the 300 s converse
//     budget. The probe gives up fast so a typo / wrong URL surfaces a
//     red banner without leaving the user staring at a spinner.
//   - Session: per-call ephemeral `URLSession(configuration:delegate:delegateQueue:)`
//     so the `RemoteAgentTrustEvaluator` SPKI-pinning delegate gets
//     installed for THIS probe only (same pinning posture as `send(...)`).
//     Default session can't carry a per-call delegate.
//
// Privacy invariants (same as `send(...)`):
//   - Bearer token never logged or echoed into error messages.
//   - Thrown `AppError` is a taxonomy code only — no body / header content.

import Foundation

extension RemoteAgentClient {

    /// Outcome of a "Test Connection" probe. Distinguishes the two
    /// success-ish shapes the Settings UI must handle differently from a
    /// hard error (which is still `throw`n as `AppError`):
    ///
    ///   - `.ok` — publicly-trusted cert, or a configured pin that matched.
    ///     The save path persists the tuple and shows "Connected".
    ///   - `.untrustedCert(presentedFingerprintHex:)` — NO pin configured
    ///     AND the system rejected an untrusted self-signed cert. The UI
    ///     offers a one-tap TOFU "Trust & Save" using the captured leaf
    ///     SPKI fingerprint (`nil` when the key algorithm is outside the V1
    ///     prefix table — the banner then says "untrusted cert" with no
    ///     copyable hex).
    ///
    /// A *pin-mismatch* (pin already set, cert changed) is NOT a member of
    /// this enum — it still `throw`s `.remoteAgentCertMismatch` so the UI
    /// never auto-offers re-trust (that would defeat pinning).
    enum TestConnectionOutcome: Equatable, Sendable {
        case ok
        /// The route answered with a WELL-FORMED but EMPTY model list
        /// (`{"data":[]}`). Structurally the endpoint exists — so this is a pass,
        /// not a failure — but a gateway advertising zero models cannot answer a
        /// turn, and a flat green "Connected" would overclaim. Kept distinct so
        /// the editor can say so.
        case okNoModels
        case untrustedCert(presentedFingerprintHex: String?)

        /// Whether the probe proved a usable route (either success shape).
        var isSuccess: Bool {
            switch self {
            case .ok, .okNoModels: return true
            case .untrustedCert: return false
            }
        }
    }

    /// A `TestConnectionOutcome` PLUS the leaf SPKI the server actually presented.
    ///
    /// `TestConnectionOutcome` surfaces the presented fingerprint only on its
    /// `.untrustedCert` arm, because the editor's Test Connection needs it for
    /// exactly one purpose: offering one-tap TOFU when the system rejected a
    /// self-signed cert. On the SUCCESS arms the evaluator computes the digest and
    /// the outcome drops it.
    ///
    /// An inbound PAIRING import needs it on the success arm too. "Ordinary trust
    /// accepted the chain" and "the key on the wire is the one this code claims"
    /// are independent facts, and under enterprise TLS inspection the first is true
    /// while the second is false — see `PairingTrustDecision`. Without this readout
    /// that row is not merely unhandled, it is undecidable.
    struct TestConnectionReport: Equatable, Sendable {
        let outcome: TestConnectionOutcome
        /// Leaf SPKI SHA-256 (lowercase hex) captured on the server-trust
        /// challenge, on EVERY arm. `nil` when no challenge fired or the key
        /// algorithm is outside the V1 SPKI prefix table.
        let presentedFingerprintHex: String?
    }

    /// Issue `GET <url>/v1/models` against the configured gateway and
    /// return a `TestConnectionOutcome`. The test is binary on the wire
    /// (works / doesn't); the model list is not surfaced to the user
    /// (a model picker is deferred to a future release).
    ///
    /// - Parameters:
    ///   - backend: which gateway speaks (controls status-map dispatch).
    ///     Note: `/v1/models` does NOT carry session IDs, so unlike
    ///     `send(...)` there is no header-vs-body branch here.
    ///   - url: BASE URL of the gateway (this method appends
    ///     `/v1/models` internally).
    ///   - token: bearer token to test. Never logged.
    ///   - fingerprint: optional pinned SHA-256 hex. `nil` falls through
    ///     to default ATS chain validation. Hex is normalised lowercase
    ///     by the trust evaluator on compare.
    /// - Returns: `.ok` on success, or `.untrustedCert(...)` when no pin is
    ///   set and the system rejected a self-signed cert (TOFU opportunity).
    /// - Throws: `AppError` — typically `.remoteAgentAuthFailed`,
    ///   `.remoteAgentUnreachable`, `.remoteAgentCertMismatch` (pin set +
    ///   mismatch — never offered re-trust), `.remoteAgentTimeout`, or
    ///   `.remoteAgentServerError`.
    ///   - bodyShape: the JSON envelope a 2xx body must carry to PASS. Comes from
    ///     the DESCRIPTOR, not from `backend` — a custom gateway rides the
    ///     `.openclaw` carrier (for the status map) but has no descriptor of its
    ///     own, so the carrier cannot be trusted to imply the shape.
    ///     `SettingsViewModel.validateRemoteAgent` passes `descriptor.verdictBodyShape`
    ///     explicitly; the default is the model-list envelope, which is correct for
    ///     every self-hosted and custom gateway (only OpenRouter differs).
    @discardableResult
    func testConnection(
        backend: RemoteAgentBackend,
        url: URL,
        token: String,
        authScheme: RemoteAgentAuthScheme = .bearer,
        fingerprint: String?,
        probePath: String = Constants.remoteAgentModelsProbePath,
        bodyShape: RemoteAgentProbeBodyShape = .modelListEnvelope
    ) async throws -> TestConnectionOutcome {
        try await testConnectionReport(
            backend: backend,
            url: url,
            token: token,
            authScheme: authScheme,
            fingerprint: fingerprint,
            probePath: probePath,
            bodyShape: bodyShape
        ).outcome
    }

    /// Same probe as `testConnection(...)`, retaining the presented leaf
    /// fingerprint on EVERY arm.
    ///
    /// FILE-PRIVATE ON PURPOSE. It takes an arbitrary `fingerprint`, and a pairing
    /// caller that passed the payload's claim here would defeat the entire trust
    /// matrix (see `pairingTrustProbeReport`). Keeping it unreachable from outside
    /// this file means the unpinned requirement cannot be bypassed by a future
    /// caller — a stronger guarantee than a test, which only catches the callers
    /// it happens to know about. The two sanctioned entry points are
    /// `testConnection(...)` (drops the fingerprint) and `pairingTrustProbeReport(...)`
    /// (hardcodes `nil`).
    private func testConnectionReport(
        backend: RemoteAgentBackend,
        url: URL,
        token: String,
        authScheme: RemoteAgentAuthScheme = .bearer,
        fingerprint: String?,
        probePath: String = Constants.remoteAgentModelsProbePath,
        bodyShape: RemoteAgentProbeBodyShape = .modelListEnvelope
    ) async throws -> TestConnectionReport {
        // Per-call ephemeral session — install the pinning delegate ONLY
        // for the duration of this probe, never on `URLSession.shared`.
        let evaluator = RemoteAgentTrustEvaluator(pinnedFingerprintHex: fingerprint)
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = Constants.remoteAgentTestConnectionTimeout
        config.timeoutIntervalForResource = Constants.remoteAgentTestConnectionTimeout
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let session = URLSession(
            configuration: config,
            delegate: evaluator,
            delegateQueue: nil
        )
        defer { session.invalidateAndCancel() }

        let request = Self.buildTestConnectionRequest(url: url, token: token, authScheme: authScheme, probePath: probePath)
        // `hasPin` decides how a TLS-rejection URLError is classified:
        //   - no pin + system-rejected self-signed → `.untrustedCert(fp)`
        //     (TOFU opportunity — read the captured fp from the evaluator)
        //   - pin set + mismatch → throw `.remoteAgentCertMismatch`
        let hasPin = (fingerprint?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
        return try await Self.performTestConnection(
            request,
            session: session,
            backend: backend,
            bodyShape: bodyShape,
            hasPin: hasPin,
            presentedFingerprint: { evaluator.presentedFingerprintHex },
            systemTrustRejected: { evaluator.systemTrustRejected },
            pinRejected: { evaluator.pinRejected }
        )
    }

    /// The UNPINNED trust probe an inbound pairing import must use — the ONLY
    /// sanctioned entry point for `PairingTrustDecision`.
    ///
    /// UNPINNED IS LOAD-BEARING. Probing under the pin the payload carries would
    /// be silently self-defeating: the evaluator ACCEPTS on a pin match without
    /// ever consulting ordinary trust (`RemoteAgentTrustEvaluator.swift:406`), so
    /// a pin-accepted request is indistinguishable from "ordinary trust passed"
    /// — and the matrix would read a forged agreement as `.useOrdinaryTrust`. The
    /// pin a code carries is a CLAIM to be checked in software, never a pin to
    /// probe under. It is therefore not a parameter here; it is only carried
    /// through into the returned signals for comparison.
    ///
    /// NEVER THROWS, and deliberately says nothing about whether the gateway
    /// WORKS. It answers exactly one question — was the TLS handshake accepted,
    /// and by whom — because "unreachable" must be a verdict the matrix can
    /// reason about, not an error that aborts the decision.
    ///
    /// ANY HTTP RESPONSE MEANS COMPLETED, including 401 and 404: the handshake
    /// had already succeeded before the server could answer at all. This is why
    /// the probe cannot reuse `testConnection(...)`, which throws on those
    /// statuses and on a wrong body envelope — all AFTER the fact this function
    /// exists to capture. The functional check still runs separately, once the
    /// trust decision has been made and accepted.
    func pairingTrustProbe(
        url: URL,
        token: String,
        authScheme: RemoteAgentAuthScheme = .bearer,
        payloadPinHex: String?,
        probePath: String = Constants.remoteAgentModelsProbePath
    ) async -> PairingTrustProbeSignals {
        let evaluator = RemoteAgentTrustEvaluator(pinnedFingerprintHex: nil)
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = Constants.remoteAgentTestConnectionTimeout
        config.timeoutIntervalForResource = Constants.remoteAgentTestConnectionTimeout
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let session = URLSession(configuration: config, delegate: evaluator, delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        return await Self.performPairingTrustProbe(
            Self.buildTestConnectionRequest(url: url, token: token, authScheme: authScheme, probePath: probePath),
            session: session,
            payloadPinHex: payloadPinHex,
            presentedFingerprint: { evaluator.presentedFingerprintHex },
            systemTrustRejected: { evaluator.systemTrustRejected },
            pinRejected: { evaluator.pinRejected }
        )
    }

    /// Test-only injection seam for `pairingTrustProbe(...)` — drives the probe
    /// through a `MockURLProtocol`-backed session with the trust signals supplied
    /// as closures, since a mocked transport raises no server-trust challenge.
    func pairingTrustProbeForTesting(
        url: URL,
        token: String,
        authScheme: RemoteAgentAuthScheme = .bearer,
        payloadPinHex: String?,
        session: URLSession,
        presentedFingerprint: @escaping @Sendable () -> String? = { nil },
        systemTrustRejected: @escaping @Sendable () -> Bool = { false },
        pinRejected: @escaping @Sendable () -> Bool = { false },
        probePath: String = Constants.remoteAgentModelsProbePath
    ) async -> PairingTrustProbeSignals {
        await Self.performPairingTrustProbe(
            Self.buildTestConnectionRequest(url: url, token: token, authScheme: authScheme, probePath: probePath),
            session: session,
            payloadPinHex: payloadPinHex,
            presentedFingerprint: presentedFingerprint,
            systemTrustRejected: systemTrustRejected,
            pinRejected: pinRejected
        )
    }

    private static func performPairingTrustProbe(
        _ request: URLRequest,
        session: URLSession,
        payloadPinHex: String?,
        presentedFingerprint: @escaping @Sendable () -> String?,
        systemTrustRejected: @escaping @Sendable () -> Bool,
        pinRejected: @escaping @Sendable () -> Bool
    ) async -> PairingTrustProbeSignals {
        do {
            // Discard the response entirely. Status and body are the FUNCTIONAL
            // question, asked later by the existing gateway test; reaching this
            // line at all is the only fact this probe reports.
            _ = try await session.data(for: request)
            return PairingTrustProbeSignals(
                payloadPinHex: payloadPinHex,
                presentedFingerprintHex: presentedFingerprint(),
                requestCompleted: true
            )
        } catch let error as URLError {
            // `hasPin: false` matches the unpinned probe — a mismatch signal here
            // could only come from the evaluator, which has no pin to mismatch.
            return PairingTrustProbeSignals(
                payloadPinHex: payloadPinHex,
                presentedFingerprintHex: presentedFingerprint(),
                requestCompleted: false,
                transportClass: RemoteAgentTrustEvaluator.classifyTransportError(
                    error.code,
                    hasPin: false,
                    systemTrustRejected: systemTrustRejected(),
                    pinRejected: pinRejected()
                )
            )
        } catch {
            // Not a `URLError` — unclassifiable, so conservatively unreachable.
            return PairingTrustProbeSignals(
                payloadPinHex: payloadPinHex,
                presentedFingerprintHex: presentedFingerprint(),
                requestCompleted: false,
                transportClass: nil
            )
        }
    }

    /// Test-only injection seam — issues the probe through a caller-
    /// supplied `URLSession`. Production callers use `testConnection(...)`
    /// which constructs its own pinning session; tests use this to drive
    /// a `MockURLProtocol`-backed session without paying for a real
    /// network round-trip (and to control fingerprint pinning via the
    /// mock instead of a real `RemoteAgentTrustEvaluator` delegate).
    ///
    /// Marked `internal` (not `private`) so `@testable import` reaches it.
    /// Keep the public `testConnection(...)` overload as the only
    /// non-test entry point.
    ///
    /// - Parameters mirror the production overload, plus:
    ///   - hasPin: whether a pin is configured. Drives the no-pin →
    ///     `.untrustedCert` vs pin-set → `throw .remoteAgentCertMismatch`
    ///     classification of a TLS-rejection URLError. Defaults to `false`
    ///     (the common test case is "no pin set").
    ///   - presentedFingerprint: closure returning the leaf SPKI fp the
    ///     evaluator captured — tests pass a literal; production passes a
    ///     read of the real evaluator instance.
    @discardableResult
    func testConnectionForTesting(
        backend: RemoteAgentBackend,
        url: URL,
        token: String,
        authScheme: RemoteAgentAuthScheme = .bearer,
        session: URLSession,
        hasPin: Bool = false,
        presentedFingerprint: @escaping @Sendable () -> String? = { nil },
        systemTrustRejected: @escaping @Sendable () -> Bool = { false },
        pinRejected: @escaping @Sendable () -> Bool = { false },
        probePath: String = Constants.remoteAgentModelsProbePath,
        bodyShape: RemoteAgentProbeBodyShape = .modelListEnvelope
    ) async throws -> TestConnectionOutcome {
        try await testConnectionReportForTesting(
            backend: backend,
            url: url,
            token: token,
            authScheme: authScheme,
            session: session,
            hasPin: hasPin,
            presentedFingerprint: presentedFingerprint,
            systemTrustRejected: systemTrustRejected,
            pinRejected: pinRejected,
            probePath: probePath,
            bodyShape: bodyShape
        ).outcome
    }

    /// Report-returning counterpart of `testConnectionForTesting(...)`, so the
    /// success-path fingerprint retention the pairing trust matrix depends on is
    /// itself testable without a live TLS fixture.
    func testConnectionReportForTesting(
        backend: RemoteAgentBackend,
        url: URL,
        token: String,
        authScheme: RemoteAgentAuthScheme = .bearer,
        session: URLSession,
        hasPin: Bool = false,
        presentedFingerprint: @escaping @Sendable () -> String? = { nil },
        systemTrustRejected: @escaping @Sendable () -> Bool = { false },
        pinRejected: @escaping @Sendable () -> Bool = { false },
        probePath: String = Constants.remoteAgentModelsProbePath,
        bodyShape: RemoteAgentProbeBodyShape = .modelListEnvelope
    ) async throws -> TestConnectionReport {
        let request = Self.buildTestConnectionRequest(url: url, token: token, authScheme: authScheme, probePath: probePath)
        return try await Self.performTestConnection(
            request,
            session: session,
            backend: backend,
            bodyShape: bodyShape,
            hasPin: hasPin,
            presentedFingerprint: presentedFingerprint,
            systemTrustRejected: systemTrustRejected,
            pinRejected: pinRejected
        )
    }

    /// Build the `GET <url>/v1/models` request. `.bearer` sets the
    /// Authorization header; `.none` (keyless) omits it — a keyless gateway is
    /// probed with no auth (the user's network isolation is the access control).
    static func buildTestConnectionRequest(
        url: URL,
        token: String,
        authScheme: RemoteAgentAuthScheme = .bearer,
        probePath: String = Constants.remoteAgentModelsProbePath
    ) -> URLRequest {
        let endpoint = url.appending(path: probePath
            .trimmingCharacters(in: CharacterSet(charactersIn: "/")))

        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = Constants.remoteAgentTestConnectionTimeout
        authScheme.apply(to: &request, token: token)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    /// Execute the probe, mapping URLError + HTTP status to a
    /// `TestConnectionOutcome` (`.ok` / `.untrustedCert`) or a thrown
    /// `AppError`. Mirrors `performRequest` + `decodeReply` in
    /// `RemoteAgentClient` (transport mapping + status-map dispatch) but
    /// skips the body decode — `testConnection` is binary success/failure.
    ///
    /// TLS-rejection handling depends on `hasPin`:
    ///   - no pin set → the rejection is a TOFU opportunity → return
    ///     `.untrustedCert(presentedFingerprint())` (do NOT throw).
    ///   - pin set → the rejection means the cert changed away from the
    ///     pin → `throw .remoteAgentCertMismatch` (never offer re-trust).
    private static func performTestConnection(
        _ request: URLRequest,
        session: URLSession,
        backend: RemoteAgentBackend,
        bodyShape: RemoteAgentProbeBodyShape,
        hasPin: Bool,
        presentedFingerprint: @escaping @Sendable () -> String?,
        systemTrustRejected: @escaping @Sendable () -> Bool = { false },
        pinRejected: @escaping @Sendable () -> Bool = { false }
    ) async throws -> TestConnectionReport {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            // Classify via the single source of truth in `RemoteAgentTrustEvaluator`
            // — keeps user-facing error continuity across every gateway probe and
            // ensures a transient `.secureConnectionFailed` (cold tunnel) is NOT
            // mislabeled "untrusted certificate". Bearer header is on the request
            // object; we never echo request material into the thrown error.
            switch RemoteAgentTrustEvaluator.classifyTransportError(
                error.code,
                hasPin: hasPin,
                systemTrustRejected: systemTrustRejected(),
                pinRejected: pinRejected()
            ) {
            case .timeout:
                throw AppError.remoteAgentTimeout
            case .unreachable:
                throw AppError.remoteAgentUnreachable
            case .cancelled:
                // No-pin task cancellation. Test Connection is a one-shot tap
                // with no user-cancel surface → treat as a retryable transport
                // failure rather than a cert problem.
                throw AppError.remoteAgentUnreachable
            case .certMismatch:
                // Pin set + the evaluator confirmed a genuine mismatch → throw
                // (never auto-offer re-trust; that defeats pinning).
                throw AppError.remoteAgentCertMismatch
            case .untrustedCert:
                // No pin + the system genuinely rejected an untrusted cert →
                // TOFU opportunity: return the captured leaf fingerprint so the
                // UI can offer one-tap "Trust & Save".
                let presented = presentedFingerprint()
                return TestConnectionReport(
                    outcome: .untrustedCert(presentedFingerprintHex: presented),
                    presentedFingerprintHex: presented
                )
            }
        } catch {
            // Non-URLError transport failure — collapse to unreachable.
            throw AppError.remoteAgentUnreachable
        }

        guard let http = response as? HTTPURLResponse else {
            throw AppError.remoteAgentInvalidResponse
        }

        // A 404 on the PROBE route means the AI endpoint isn't mounted where we
        // looked — a route problem, not a request problem. Classified HERE rather
        // than in `RemoteAgentStatusMap` on purpose: the map is shared with
        // `send(...)`, where a 404 legitimately means "that MODEL doesn't exist"
        // (`mapBodyError` disambiguates it from the body). The map sees only an
        // Int — no operation, no path — so it cannot tell those apart. This call
        // site can: it knows it just asked for a fixed, well-known route.
        if http.statusCode == 404 {
            throw AppError.remoteAgentEndpointNotFound
        }

        // Reuse the unified status map so error mapping stays consistent
        // with `send(...)`. Test Connection in practice should only see
        // 200 / 401 / 5xx, but routing through the same dispatch point
        // preserves the single-dispatch-point rule.
        if let mapped = backend.statusMap.map(http.statusCode) {
            throw mapped
        }

        // 2xx is NOT sufficient. OpenClaw with its OpenAI chat endpoint disabled
        // (the OFF-by-default state) serves the Control-UI **HTML at HTTP 200** on
        // `/v1/models` — so a status-only verdict reports a gateway that cannot
        // answer a single turn as "Connected", and the user only discovers it when
        // their first message fails. The gateway must PROVE it speaks the protocol.
        //
        // The presented fingerprint is retained on this SUCCESS path too — the
        // pairing trust matrix compares it against the pin a scanned code claims,
        // and ordinary trust having accepted the chain does not answer that question.
        return TestConnectionReport(
            outcome: try Self.validateProbeBody(data, shape: bodyShape),
            presentedFingerprintHex: presentedFingerprint()
        )
    }

    /// Decide a 2xx probe's verdict from its BODY.
    ///
    /// Parses the bytes rather than trusting `Content-Type` — OpenAI-compatible
    /// gateways and the proxies in front of them mislabel JSON often enough that a
    /// header check would reject working setups.
    ///
    /// Strictness is deliberate and asymmetric to `parseModelIDs`:
    ///   - `parseModelIDs` (model-suggestion DISCOVERY) is tolerant — it accepts
    ///     `{"models":[…]}` and bare arrays, and degrades to `[]` on anything else,
    ///     because a missed suggestion only costs the user a free-text field.
    ///   - the VERDICT (here) accepts ONLY the canonical top-level `data`. A wrong
    ///     verdict costs the user a broken gateway that claims to work.
    /// Concretely: LM Studio's NATIVE `/api/v1/models` returns `{"models":[…]}`
    /// while its native chat route is NOT `/v1/chat/completions`. Accepting the
    /// tolerant shape here would green-light a base URL whose chat route does not
    /// exist — the exact false green this function exists to kill.
    static func validateProbeBody(
        _ data: Data,
        shape: RemoteAgentProbeBodyShape
    ) throws -> TestConnectionOutcome {
        // An empty body (or a 204) proves the HOST answered, never that the AI
        // route is there. Fail closed. Not-JSON-at-all (HTML page, plaintext)
        // is 58; valid JSON in the wrong shape is 62 — the split lets 62's copy
        // name the exact envelope rule, which is the likeliest failure of a
        // home-built custom adapter (`{"models":…}`, a bare array, `{}`).
        guard !data.isEmpty,
              let json = try? JSONSerialization.jsonObject(with: data)
        else {
            throw AppError.remoteAgentEndpointUnexpectedResponse
        }

        switch shape {
        case .modelListEnvelope:
            // `/v1/models` → top-level `data` is an ARRAY. An EMPTY array is
            // structurally valid (the route exists and speaks the protocol), so
            // it passes — but distinguishably: a gateway advertising no models
            // can't answer.
            guard let root = json as? [String: Any],
                  let models = root["data"] as? [Any]
            else {
                throw AppError.remoteAgentEndpointWrongEnvelope
            }
            return models.isEmpty ? .okNoModels : .ok

        case .keyEnvelope:
            // OpenRouter `/v1/key` → `data` is an OBJECT (the key's label/limits).
            // An array here means we reached some OTHER endpoint. Stays 58: this
            // is a Conduck-managed builtin route — the adapter-contract copy of
            // 62 would point its user at a page that can't help them.
            guard let root = json as? [String: Any],
                  root["data"] is [String: Any]
            else {
                throw AppError.remoteAgentEndpointUnexpectedResponse
            }
            return .ok
        }
    }

    // MARK: - Model discovery (custom-gateway editor suggestion list)

    /// Best-effort model discovery for the custom-gateway editor's Model-field
    /// suggestion list. Issues a cheap `GET /v1/models` (a listing endpoint — no
    /// tokens consumed) and parses the model IDs. Returns `[]` on ANY failure
    /// (the field degrades to free-text) — NEVER throws, NEVER blocks the save.
    /// The returned IDs are what the gateway ADVERTISES; whether each is loaded
    /// + active is the user's responsibility (surfaced in the field's helper
    /// copy — the "ghost model" caveat). Built-ins don't call this.
    func discoverModels(
        url: URL,
        token: String,
        authScheme: RemoteAgentAuthScheme = .bearer,
        fingerprint: String?
    ) async -> [String] {
        let evaluator = RemoteAgentTrustEvaluator(pinnedFingerprintHex: fingerprint)
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = Constants.remoteAgentTestConnectionTimeout
        config.timeoutIntervalForResource = Constants.remoteAgentTestConnectionTimeout
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let session = URLSession(configuration: config, delegate: evaluator, delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        let request = Self.buildTestConnectionRequest(url: url, token: token, authScheme: authScheme)
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            return []
        }
        return Self.parseModelIDs(from: data)
    }

    /// Parse model IDs from a `/v1/models` body. Pure + testable. Handles the
    /// OpenAI shape `{ "data": [{ "id": "..." }] }`, a `{ "models": [...] }`
    /// variant, and a bare `["id", ...]` array. Unknown shape → `[]`.
    static func parseModelIDs(from data: Data) -> [String] {
        guard let json = try? JSONSerialization.jsonObject(with: data) else { return [] }
        func ids(from array: [Any]) -> [String] {
            array.compactMap { element in
                if let string = element as? String { return string }
                if let dict = element as? [String: Any], let id = dict["id"] as? String { return id }
                return nil
            }
        }
        if let dict = json as? [String: Any] {
            if let dataArray = dict["data"] as? [Any] { return ids(from: dataArray) }
            if let modelsArray = dict["models"] as? [Any] { return ids(from: modelsArray) }
        }
        if let array = json as? [Any] { return ids(from: array) }
        return []
    }
}
