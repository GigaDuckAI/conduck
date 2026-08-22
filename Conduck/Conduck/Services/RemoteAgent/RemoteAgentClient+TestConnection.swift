// SPDX-License-Identifier: Apache-2.0

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
    ///   - `.untrustedCert` — the system rejected the server's certificate.
    ///     TERMINAL: the UI explains the refusal and names the remedy (give
    ///     the server a certificate this device already trusts). It carries
    ///     no fingerprint, because there is nothing the app could do with
    ///     one — App Transport Security lets a pin TIGHTEN evaluation of a
    ///     chain the system already accepts, never rescue one it rejected,
    ///     so pinning the presented key would produce a gateway that fails
    ///     every request.
    ///
    /// A *pin mismatch* is NOT a member of this enum — it `throw`s
    /// `.remoteAgentCertMismatch`. It can only mean the system DID trust the
    /// chain and the presented key still disagreed, since an untrusted chain
    /// resolves to `.untrustedCert` above before any digest is compared.
    enum TestConnectionOutcome: Equatable, Sendable {
        case ok
        /// The route answered with a WELL-FORMED but EMPTY model list
        /// (`{"data":[]}`). Structurally the endpoint exists — so this is a pass,
        /// not a failure — but a gateway advertising zero models cannot answer a
        /// turn, and a flat green "Connected" would overclaim. Kept distinct so
        /// the editor can say so.
        case okNoModels
        case untrustedCert

        /// Whether the probe proved a usable route (either success shape).
        var isSuccess: Bool {
            switch self {
            case .ok, .okNoModels: return true
            case .untrustedCert: return false
            }
        }
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
    /// - Returns: `.ok` on success, or `.untrustedCert` when this device rejected
    ///   the server's certificate — WITH a pin configured just as much as
    ///   without one, because a pinned challenge over a chain the system refused
    ///   fails closed (terminal — see the enum).
    /// - Throws: `AppError` — typically `.remoteAgentAuthFailed`,
    ///   `.remoteAgentUnreachable`, `.remoteAgentCertMismatch` (the system
    ///   trusted the chain and the presented key still disagreed — never
    ///   offered re-trust, and removing the pin is never the remedy),
    ///   `.remoteAgentTimeout`, or `.remoteAgentServerError`.
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
        // The WHOLE snapshot of whatever verdict the evaluator reached on this
        // attempt — read as a closure because the challenge fires while the
        // request below is in flight. Passing the snapshot rather than loose
        // Bools is what lets Test Connection distinguish a key Conduck cannot
        // fingerprint from a key that disagreed; the editor is the surface most
        // likely to meet the first, since it is where a pin gets typed in.
        return try await Self.performTestConnection(
            request,
            session: session,
            backend: backend,
            bodyShape: bodyShape,
            signals: { evaluator.attemptSignals }
        )
    }

    /// The UNPINNED trust probe an inbound pairing import must use — the ONLY
    /// sanctioned entry point for `PairingTrustDecision`.
    ///
    /// UNPINNED IS LOAD-BEARING, and it is the ONLY way this probe runs — there
    /// is no fingerprint parameter to pass. The question the probe asks is
    /// exactly "does THIS DEVICE's trust store accept this server", and any pin
    /// installed for the probe would answer a different question: the evaluator
    /// accepts on a pin match, so a pin-accepted request would be
    /// indistinguishable from "ordinary trust passed".
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
            signals: { evaluator.attemptSignals }
        )
    }

    #if DEBUG
    /// Test-only injection seam for `pairingTrustProbe(...)` — drives the probe
    /// through a `MockURLProtocol`-backed session with the trust signals supplied
    /// as closures, since a mocked transport raises no server-trust challenge.
    ///
    /// `#if DEBUG` IS the fence, not the name. A caller-supplied session is a
    /// session with no evaluator on it and hand-written trust verdicts beside it —
    /// i.e. every trust answer this probe gives becomes whatever the caller says.
    /// "No production caller uses it" is call-site discipline; not existing in a
    /// Release or Archive build is enforcement, and it is the same fence
    /// `RemoteAgentTrustEvaluator`'s test-only initializer and
    /// `BackgroundFileTransfer.respondToTaskTrustChallenge` already stand behind.
    /// Nothing in the app links against it — `pairingTrustProbe(...)` builds its
    /// own session and calls the shared executor directly.
    func pairingTrustProbeForTesting(
        url: URL,
        token: String,
        authScheme: RemoteAgentAuthScheme = .bearer,
        session: URLSession,
        systemTrustRejected: @escaping @Sendable () -> Bool = { false },
        pinRejected: @escaping @Sendable () -> Bool = { false },
        probePath: String = Constants.remoteAgentModelsProbePath
    ) async -> PairingTrustProbeSignals {
        await Self.performPairingTrustProbe(
            Self.buildTestConnectionRequest(url: url, token: token, authScheme: authScheme, probePath: probePath),
            session: session,
            // `challengeRefused` stays false: this probe installs no pin, and an
            // unpinned challenge is never one the evaluator cancels.
            signals: {
                .init(systemTrustRejected: systemTrustRejected(),
                      challengeRefused: false,
                      pinRejected: pinRejected(),
                      pinComparisonUnsupported: false)
            }
        )
    }
    #endif

    private static func performPairingTrustProbe(
        _ request: URLRequest,
        session: URLSession,
        signals: @escaping @Sendable () -> RemoteAgentTrustEvaluator.AttemptTrustSignals
    ) async -> PairingTrustProbeSignals {
        do {
            // Discard the response entirely. Status and body are the FUNCTIONAL
            // question, asked later by the existing gateway test; reaching this
            // line at all is the only fact this probe reports.
            _ = try await session.data(for: request)
            return PairingTrustProbeSignals(requestCompleted: true)
        } catch let error as URLError {
            // The probe installs no pin, so the snapshot can only ever carry a
            // system verdict — there is nothing for a pin to disagree with and
            // no digest to fail to compute.
            return PairingTrustProbeSignals(
                requestCompleted: false,
                transportClass: RemoteAgentTrustEvaluator.classifyTransportError(error.code, signals: signals())
            )
        } catch {
            // Not a `URLError` — unclassifiable, so conservatively unreachable.
            return PairingTrustProbeSignals(
                requestCompleted: false,
                transportClass: nil
            )
        }
    }

    #if DEBUG
    /// Test-only injection seam — issues the probe through a caller-
    /// supplied `URLSession`. Production callers use `testConnection(...)`
    /// which constructs its own pinning session; tests use this to drive
    /// a `MockURLProtocol`-backed session without paying for a real
    /// network round-trip. The trust signals arrive as closures because a
    /// mocked transport raises no server-trust challenge, so there is no real
    /// `RemoteAgentTrustEvaluator` to read them off.
    ///
    /// `#if DEBUG` IS the fence: this method decides the probe's certificate
    /// verdict from its arguments rather than from a challenge, so a shipping
    /// build must not be able to reach it at all. `internal` keeps
    /// `@testable import` working inside that fence, and `testConnection(...)`
    /// stays the only entry point a Release build has.
    ///
    /// - Parameters mirror the production overload, plus the four verdicts an
    ///   attempt can reach, each as a closure and each defaulting to the
    ///   no-verdict value — so a test exercising a REFUSAL has to say which one.
    ///   They are assembled into the same `AttemptTrustSignals` the production
    ///   overload snapshots off its evaluator; which arms consult which verdict
    ///   is `classifyTransportError`'s own business and is documented there,
    ///   because restating that list here is how a seam's doc and the
    ///   classifier's doc drift into contradicting each other.
    ///   `challengeRefused` is the one a test reaching for "a pinned lane" most
    ///   likely wants: it is the positive record that the evaluator ANSWERED the
    ///   challenge with a cancel, which is what makes a `-999` attributable at
    ///   all. A pin's mere existence is not a substitute — it says nothing about
    ///   whether this attempt was refused.
    @discardableResult
    func testConnectionForTesting(
        backend: RemoteAgentBackend,
        url: URL,
        token: String,
        authScheme: RemoteAgentAuthScheme = .bearer,
        session: URLSession,
        challengeRefused: Bool = false,
        systemTrustRejected: @escaping @Sendable () -> Bool = { false },
        pinRejected: @escaping @Sendable () -> Bool = { false },
        pinComparisonUnsupported: @escaping @Sendable () -> Bool = { false },
        probePath: String = Constants.remoteAgentModelsProbePath,
        bodyShape: RemoteAgentProbeBodyShape = .modelListEnvelope
    ) async throws -> TestConnectionOutcome {
        let request = Self.buildTestConnectionRequest(url: url, token: token, authScheme: authScheme, probePath: probePath)
        return try await Self.performTestConnection(
            request,
            session: session,
            backend: backend,
            bodyShape: bodyShape,
            signals: {
                .init(systemTrustRejected: systemTrustRejected(),
                      challengeRefused: challengeRefused,
                      pinRejected: pinRejected(),
                      pinComparisonUnsupported: pinComparisonUnsupported())
            }
        )
    }
    #endif

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
    /// TLS-rejection handling depends on WHICH verdict `classifyTransportError`
    /// found, never on whether a pin merely exists — this device's own trust
    /// verdict wins regardless:
    ///   - `systemTrustRejected` → this device does not trust the server's
    ///     certificate → return `.untrustedCert` (do NOT throw — the UI
    ///     explains this one, with a remedy, rather than folding it into a
    ///     generic connection failure).
    ///   - system trust OK but `pinRejected` → the presented key does not
    ///     match the fingerprint the user typed in on an otherwise-trusted
    ///     certificate → `throw .remoteAgentCertMismatch`.
    ///   - system trust OK, `pinRejected`, and `pinComparisonUnsupported` → the
    ///     digest could not be COMPUTED, so nothing was compared →
    ///     `throw .remoteAgentCertKeyUnpinnable`. Reachable only because the
    ///     whole signals snapshot is threaded here; the loose-Bool form drops
    ///     that verdict and this user gets an interception warning instead.
    ///
    /// FILE-PRIVATE ON PURPOSE. This is the only executor that runs the probe
    /// under a caller-chosen pin, so keeping it unreachable from outside this
    /// file means the two sanctioned entry points are the only ways in:
    /// `testConnection(...)`, whose fingerprint comes from the Settings editor,
    /// and `testConnectionForTesting(...)`, the test seam. The pairing import
    /// does not route through here at all — `pairingTrustProbe(...)` has its own
    /// executor with no fingerprint parameter to pass, which is what makes
    /// "the pairing probe runs unpinned" a structural fact rather than a
    /// convention a future caller could break.
    private static func performTestConnection(
        _ request: URLRequest,
        session: URLSession,
        backend: RemoteAgentBackend,
        bodyShape: RemoteAgentProbeBodyShape,
        signals: @escaping @Sendable () -> RemoteAgentTrustEvaluator.AttemptTrustSignals
    ) async throws -> TestConnectionOutcome {
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
            switch RemoteAgentTrustEvaluator.classifyTransportError(error.code, signals: signals()) {
            case .blockedByATS:
                // -1022: the address never left the URL layer, so this is not a
                // verdict about the server and Test Connection must not report
                // one. The remedy is the address itself.
                throw AppError.insecureConnectionBlocked
            case .timeout:
                throw AppError.remoteAgentTimeout
            case .unreachable:
                throw AppError.remoteAgentUnreachable
            case .notEstablished:
                // The probe reports the same distinction the send path does, so
                // Test Connection and a failed chat agree on what went wrong.
                throw AppError.remoteAgentNotEstablished
            case .offline:
                throw AppError.noInternetConnection
            case .cancelled:
                // No-pin task cancellation. Test Connection is a one-shot tap
                // with no user-cancel surface → treat as a retryable transport
                // failure rather than a cert problem.
                throw AppError.remoteAgentUnreachable
            case .certMismatch:
                // Pin set + the evaluator confirmed a genuine mismatch → throw
                // (never auto-offer re-trust; that defeats pinning).
                throw AppError.remoteAgentCertMismatch
            case .certKeyUnpinnable:
                // System trust passed; the pin could not be COMPUTED for this
                // key algorithm, so nothing was compared. Thrown as its own code
                // so the editor states the key-type cause instead of an
                // interception warning the evidence does not support.
                throw AppError.remoteAgentCertKeyUnpinnable
            case .untrustedCert:
                // This device does not trust the server's certificate — true
                // whether or not a pin is configured, since `systemTrustRejected`
                // is checked before `pinRejected` in `classifyTransportError`.
                return .untrustedCert
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
        return try Self.validateProbeBody(data, shape: bodyShape)
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
