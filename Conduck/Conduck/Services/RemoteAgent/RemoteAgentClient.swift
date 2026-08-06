// SPDX-License-Identifier: Apache-2.0

// Conduck
// RemoteAgentClient.swift
//
// Foreground actor that issues the agent
// round-trip to the user's Personal AI gateway
// (`spec.md "Remote Agent Round-Trip"`). Backend-agnostic by design — under client-owned history (locked
// 2026-05-20) the request is byte-shape-identical for OpenClaw and Hermes:
// a STATELESS `POST /v1/chat/completions` carrying the FULL client-owned
// `messages[]` history. There is NO session header,
// NO `conversation` body field, NO per-backend dispatch.
//
// Pattern transferred from `STTClient.swift`:
//   - Actor singleton with `static let shared`.
//   - URLError → AppError mapping shape (`performRequest`).
//   - Per-call `Transport` injection — the client does NOT own its session.
//     Foreground call sites build one from `makePinnedForegroundSession(...)`
//     (ephemeral + converse timeouts + the `RemoteAgentTrustEvaluator`
//     delegate, so the user's per-ref cert pin and the cross-host-redirect
//     refusal apply on the LIVE send path, not just in Test Connection) and
//     hand the session and its evaluator across as ONE required value — see
//     `Transport` for why neither half may go missing.
//
// Out of scope for this foreground actor:
//   - Background URLSession upload (`ConverseUploadCoordinator`) — needs
//     the iOS capture intent as its first caller. The transfer is
//     ~1:1 from `STTClient+Background.swift`.
//   - Retry policy: there is NONE for the agent round-trip, by design.
//     `AppError.maxAttempts` is 1 for every `remoteAgent*` error and
//     `performRequest` maps ALL transport failures to those cases — the user
//     sees an explicit Try Again, never a silent re-spend of their own LLM
//     budget (never-silent-retry invariant).
//   - Store-derived history. The background coordinator supplies `priorTurns` assembled from the
//     `ConversationStore`; foreground callers pass prior turns directly.
//
// Privacy invariants (load-bearing — see the spec's Privacy & Security section):
//   - The bearer token is NEVER logged, printed, or surfaced in error
//     messages.
//   - When logging errors, redact the `Authorization` header and any
//     reply body content.

import Foundation
#if DEBUG
import os.log
#endif

/// Foreground client for the Personal AI gateway round-trip
/// (`POST /v1/chat/completions`).
actor RemoteAgentClient {

    // MARK: - Singleton

    static let shared = RemoteAgentClient()
    private init() { }

    // MARK: - Transport (session + the evaluator that reads its verdict)

    /// The `URLSession` a send issues through, PAIRED with the trust evaluator
    /// installed on it. ONE required parameter, not two optional ones — that
    /// shape let a call site default to `URLSession.shared`, which cannot carry a
    /// delegate and so silently disabled BOTH the user's certificate pin and the
    /// cross-origin redirect refusal on a live send. A doc comment said exactly
    /// that; nothing enforced it, and "every caller is correct today" is not a
    /// property of an API.
    ///
    /// `.pinned(session:evaluator:)` is the only constructor a shipping build
    /// has, and it cannot be called without an evaluator. `.unevaluated` — a
    /// session with no verdict source, which is the honest description of a
    /// `MockURLProtocol` stub that raises no server-trust challenge — is fenced
    /// behind `#if DEBUG`, the same fence the other two trust seams use, so a
    /// Release or Archive build cannot COMPILE an unevaluated send at all.
    nonisolated struct Transport: Sendable {
        let session: URLSession
        let evaluator: RemoteAgentTrustEvaluator?

        private init(session: URLSession, evaluator: RemoteAgentTrustEvaluator?) {
            self.session = session
            self.evaluator = evaluator
        }

        /// The production shape: the pair `makePinnedForegroundSession` returns,
        /// carried across as a unit so the evaluator cannot be dropped in transit.
        static func pinned(
            session: URLSession,
            evaluator: RemoteAgentTrustEvaluator
        ) -> Transport {
            Transport(session: session, evaluator: evaluator)
        }

        #if DEBUG
        /// TEST-ONLY. A session with no evaluator: a mocked transport raises no
        /// server-trust challenge, so there is no verdict to read and `.empty` is
        /// the truthful snapshot. `#if DEBUG` IS the control — without it this is
        /// simply the old unsafe default wearing a name.
        static func unevaluated(session: URLSession) -> Transport {
            Transport(session: session, evaluator: nil)
        }
        #endif
    }

    // MARK: - Public API

    /// Issue a user turn to the configured gateway, sending the full
    /// client-owned conversation history. Returns the agent's reply text
    /// (`choices[0].message.content`). Throws an `AppError` from the
    /// `.remoteAgent*` family on failure.
    ///
    /// - Parameters:
    ///   - backend: which gateway speaks. Selects the base URL + setup
    ///     recipe only — the request shape is identical for every backend.
    ///   - url: BASE URL of the gateway (the method appends
    ///     `/v1/chat/completions` internally — callers pass the URL the
    ///     user saved in Settings, not the full endpoint).
    ///   - token: bearer token written via Keychain at Settings save-time.
    ///     Never logged.
    ///   - priorTurns: the active conversation's prior turns (oldest →
    ///     newest), assembled from the conversation store. The background
    ///     coordinator supplies these from the store; foreground callers pass them directly.
    ///     The client applies the trim policy to this array before
    ///     sending — only the last `Constants.contextMaxTurns` turns cross
    ///     the wire (older dropped from the SENT array only; the store
    ///     keeps everything).
    ///   - newUserText: the user's new turn (already STT-decoded). Always
    ///     appended after the trimmed prior turns as a `role: "user"` message.
    ///   - transport: the session to issue through and the evaluator installed on
    ///     it, as one value with NO default — see `Transport` for why the two
    ///     travel together and why there is nothing to fall back to. Production
    ///     builds it from `makePinnedForegroundSession(pinnedFingerprintHex:)`.
    ///     The evaluator is read AFTER the awaited request so a pin rejection is
    ///     told apart from a benign cancel (URLSession surfaces BOTH as
    ///     `.cancelled`).
    /// - Returns: the agent's reply text.
    /// - Throws: `AppError` — typically `.remoteAgentAuthFailed`,
    ///   `.remoteAgentServerError`, `.remoteAgentInvalidResponse`, or a
    ///   transport-mapped case.
    func send(
        backend: RemoteAgentBackend,
        url: URL,
        token: String,
        authScheme: RemoteAgentAuthScheme = .bearer,
        model: String? = nil,
        priorTurns: [ConverseRequest.Message] = [],
        newUserText: String,
        newUserImageDataURIs: [String] = [],
        newUserTextFileBlocks: [(filename: String, text: String)] = [],
        newUserServerFileRefs: [(originalName: String, storedKey: String)] = [],
        newUserImageFileRefs: [(storedKey: String, filename: String)] = [],
        newUserTextFileServerRefs: [(originalName: String, storedKey: String)] = [],
        // Count of this turn's server files whose bytes this dispatch cannot
        // reach (cross-lane clone) — see `assembleMessages`.
        newUserUnavailableFileCount: Int = 0,
        // True when the conversation's bound gateway has a READY file lane
        // (`fileTransferReadySnapshot != nil`) — appends the per-turn
        // file-delivery instruction to the newest user turn. REQUIRED (no
        // default) so every foreground call site is compiler-forced to decide:
        // a silent default here would drop the instruction from exactly one
        // dispatch surface and resurrect the lost-output-file bug there.
        fileServerReady: Bool,
        transport: Transport
    ) async throws -> String {
        let request = Self.buildRequest(
            url: url,
            token: token,
            authScheme: authScheme,
            model: model,
            priorTurns: priorTurns,
            newUserText: newUserText,
            newUserImageDataURIs: newUserImageDataURIs,
            newUserTextFileBlocks: newUserTextFileBlocks,
            newUserServerFileRefs: newUserServerFileRefs,
            newUserImageFileRefs: newUserImageFileRefs,
            newUserTextFileServerRefs: newUserTextFileServerRefs,
            newUserUnavailableFileCount: newUserUnavailableFileCount,
            fileServerReady: fileServerReady
        )

#if DEBUG
        let diagMessages = Self.assembleMessages(
            priorTurns: priorTurns,
            newUserText: newUserText,
            newUserImageDataURIs: newUserImageDataURIs,
            newUserTextFileBlocks: newUserTextFileBlocks,
            newUserServerFileRefs: newUserServerFileRefs,
            newUserImageFileRefs: newUserImageFileRefs,
            newUserTextFileServerRefs: newUserTextFileServerRefs,
            newUserUnavailableFileCount: newUserUnavailableFileCount,
            fileServerReady: fileServerReady
        )
        RemoteAgentDiagnostics.log.log("send(fg): \(RemoteAgentDiagnostics.shapeSummary(diagMessages, bodyBytes: request.httpBody?.count ?? 0), privacy: .public)")
        let diagStart = Date()
#endif

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await Self.performRequest(request, transport: transport)
        } catch {
#if DEBUG
            // The TRANSPORT half of the outcome log. Without it a foreground send
            // that never got a response left `send(fg)` with no counterpart at
            // all, and the only way to tell a timeout from a reset from a cancel
            // was to infer it from which copy the failed bubble rendered.
            RemoteAgentDiagnostics.log.log("fail(fg): stage=transport elapsed=\(String(format: "%.1f", Date().timeIntervalSince(diagStart)), privacy: .public)s \(RemoteAgentDiagnostics.outcomeToken(for: error), privacy: .public)")
#endif
            throw error
        }

#if DEBUG
        let diagHTTP = (response as? HTTPURLResponse)?.statusCode ?? -1
        // TRANSPORT-ONLY: `done(fg)` means bytes came back, NOT that the turn
        // succeeded. A 4xx/5xx, an unparseable body, or a wire-coded refusal all
        // log `done(fg)` and then a `fail(fg): stage=decode` below.
        RemoteAgentDiagnostics.log.log("done(fg): elapsed=\(String(format: "%.1f", Date().timeIntervalSince(diagStart)), privacy: .public)s http=\(diagHTTP, privacy: .public) respBytes=\(data.count, privacy: .public)")
#endif

        do {
            return try Self.decodeReply(data: data, response: response, backend: backend)
        } catch {
#if DEBUG
            RemoteAgentDiagnostics.log.log("fail(fg): stage=decode http=\(diagHTTP, privacy: .public) \(RemoteAgentDiagnostics.outcomeToken(for: error), privacy: .public)")
#endif
            throw error
        }
    }

    // MARK: - Private — context assembly (the single request-shaping point)

    /// Assemble the upstream `messages[]` from the active conversation's
    /// prior turns + the new user turn, applying the trim policy.
    ///
    /// **Trim policy:** include only the last `Constants.contextMaxTurns`
    /// prior turns in the SENT array; older turns are dropped from the wire
    /// only — the store keeps everything for display. The new user turn
    /// is always appended after the trimmed history. Images RIDE ALONG in the
    /// prior turns exactly like text (the `priorTurns` map already built
    /// `.parts` for image-bearing turns) and are bounded ONLY by this trim —
    /// there is no current-turn-only image rule (locked image-context
    /// decision; matches ChatGPT / Claude / Gemini retention).
    ///
    /// The new user turn's `Content` is built here: its text + any spliced
    /// fenced text-file blocks form the text body; when `newUserImageDataURIs`
    /// is non-empty the turn is `.parts([.text(spliced)] + image_url blocks)`,
    /// else a bare `.text(spliced)`.
    ///
    /// This is the only place conversation context is constructed; it is
    /// identical for every backend.
    static func assembleMessages(
        priorTurns: [ConverseRequest.Message],
        newUserText: String,
        newUserImageDataURIs: [String] = [],
        newUserTextFileBlocks: [(filename: String, text: String)] = [],
        newUserServerFileRefs: [(originalName: String, storedKey: String)] = [],
        newUserImageFileRefs: [(storedKey: String, filename: String)] = [],
        newUserTextFileServerRefs: [(originalName: String, storedKey: String)] = [],
        // Server-backed files attached to THIS turn whose bytes this dispatch
        // cannot reach — a cloned turn whose `storedKey`s were minted on another
        // file lane. `ConverseRequest.priorTurns` emits the honest
        // "not available in the current file-transfer lane" note for HISTORY,
        // but the newest turn is assembled here and is excluded from that pass,
        // so without this count the first dispatch after a cross-lane clone
        // would drop the file silently and let the model answer as if nothing
        // had been attached.
        //
        // DEFAULTED, unlike its `fileServerReady` sibling below — and the
        // difference is real, not laziness. `fileServerReady` is a property of
        // the GATEWAY, so every surface has an answer and a silent default hides
        // a wrong one. A detached reference can only be produced by RETRY over a
        // STORED row: every composing surface stages its files fresh against the
        // lane it is about to dispatch on (an un-uploadable file is blocked at
        // the composer as `.needsSetup`, never sent as a dangling reference), so
        // 0 is the truthful value there rather than an unexamined one. A future
        // surface that re-sends stored turns must pass this.
        newUserUnavailableFileCount: Int = 0,
        // READY file lane on the bound gateway → append the per-turn
        // file-delivery instruction (`ConverseRequest.fileDeliveryInstruction`)
        // to the NEWEST user turn only. Rides on attachment-LESS turns too —
        // "write me a report.md" with nothing attached is the turn the
        // reference splices can't cover. Defaulted `false` for tests and any
        // surface whose bound gateway has no ready lane; every lane-capable
        // dispatch surface (incl. CarPlay + Watch — a capable device that
        // later opens the thread renders a download chip for the voice turn
        // via the retroactive output-scan) passes it truthfully.
        fileServerReady: Bool = false,
        // The dispatch surface. `.spoken` (CarPlay + Watch) appends the
        // per-turn spoken-summary clause (`ConverseRequest.spokenSummaryInstruction`)
        // to the newest user turn AFTER the delivery instruction, telling the
        // agent to summarize spoken-friendly rather than recite file contents
        // aloud. Defaulted `.standard` so read-first surfaces (foreground
        // composer, ConverseIntent, background iOS) stay byte-identical.
        surface: ConverseRequest.Surface = .standard
    ) -> [ConverseRequest.Message] {
        let cap = Constants.contextMaxTurns
        let trimmed = priorTurns.count > cap
            ? Array(priorTurns.suffix(cap))
            : priorTurns

        // Build the new user turn's text body: base → text-file fenced blocks →
        // non-image server-file refs line → image server-file refs line (the
        // dual-image "also saved as …" block) → dual-text disk-ref line (the
        // dual-text "also on disk for file-tools" block). Every splice runs AFTER
        // the text-file splice + BEFORE the image parts below; the dual-text-ref
        // splice is LAST in the text body so the assembled-text order reads
        // base → text-file fences → non-image server refs → image refs →
        // dual-text disk refs. The image_url parts (which the inline vision path
        // reads) are appended after the text part unchanged.
        var splicedText = ConverseRequest.spliceText(
            newUserText,
            textFileBlocks: newUserTextFileBlocks
        )
        splicedText = ConverseRequest.spliceServerFileRefs(
            splicedText,
            serverFiles: newUserServerFileRefs
        )
        splicedText = ConverseRequest.spliceImageServerRefs(
            splicedText,
            images: newUserImageFileRefs
        )
        splicedText = ConverseRequest.spliceTextFileServerRefs(
            splicedText,
            textFiles: newUserTextFileServerRefs
        )
        // AFTER every reference splice, BEFORE the per-turn instructions: the
        // note is a fact about this turn's attachments (same position it holds
        // in `ConverseRequest.priorTurns`), while the instructions below are
        // directives that stay last.
        splicedText = ConverseRequest.spliceFileUnavailableNote(
            splicedText,
            fileCount: newUserUnavailableFileCount
        )
        // LAST in the text body, and ONLY here — never in the splice helpers
        // (they also run on replayed prior turns, which would duplicate the
        // instruction across the whole resent history). Order on the newest
        // turn: delivery instruction (when the lane is ready) THEN the spoken
        // clause (on a spoken surface) — so a spoken + ready turn carries both,
        // delivery first. The matrix: standard+notReady → neither;
        // standard+ready → delivery only; spoken+notReady → spoken only;
        // spoken+ready → delivery + spoken.
        if fileServerReady {
            splicedText = ConverseRequest.spliceFileDeliveryInstruction(splicedText)
        }
        if surface == .spoken {
            splicedText = ConverseRequest.spliceSpokenSummaryInstruction(splicedText)
        }

        let newUserMessage: ConverseRequest.Message
        if newUserImageDataURIs.isEmpty {
            newUserMessage = ConverseRequest.Message(role: "user", content: .text(splicedText))
        } else {
            let parts: [ConverseRequest.Part] =
                [.text(splicedText)] + newUserImageDataURIs.map { ConverseRequest.Part.imageURL($0) }
            newUserMessage = ConverseRequest.Message(role: "user", content: .parts(parts))
        }

        return trimmed + [newUserMessage]
    }

    // MARK: - Private — request construction

    /// Build the stateless `POST /v1/chat/completions` request carrying the
    /// full client-owned history. Identical for every backend — no session
    /// header, no `conversation` field (`spec.md "Remote Agent Round-Trip"`).
    private static func buildRequest(
        url: URL,
        token: String,
        authScheme: RemoteAgentAuthScheme = .bearer,
        model: String? = nil,
        priorTurns: [ConverseRequest.Message],
        newUserText: String,
        newUserImageDataURIs: [String] = [],
        newUserTextFileBlocks: [(filename: String, text: String)] = [],
        newUserServerFileRefs: [(originalName: String, storedKey: String)] = [],
        newUserImageFileRefs: [(storedKey: String, filename: String)] = [],
        newUserTextFileServerRefs: [(originalName: String, storedKey: String)] = [],
        // Count of this turn's unreachable server files — see `assembleMessages`.
        newUserUnavailableFileCount: Int = 0,
        fileServerReady: Bool = false
    ) -> URLRequest {
        // `URL.appending(path:)` (iOS 16+) preserves the user's optional
        // trailing slash and avoids URLComponents round-trip surprises.
        // Conduck deploys iOS 26.5+ so no `#available` guard.
        let endpoint = url.appending(path: "v1/chat/completions")

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = Constants.remoteAgentConverseRequestTimeout

        // `.bearer` sets the Authorization header; `.none` (keyless) omits it.
        // The caller's configured-gate guarantees a non-empty token for `.bearer`.
        authScheme.apply(to: &request, token: token)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body = ConverseRequest(
            messages: assembleMessages(
                priorTurns: priorTurns,
                newUserText: newUserText,
                newUserImageDataURIs: newUserImageDataURIs,
                newUserTextFileBlocks: newUserTextFileBlocks,
                newUserServerFileRefs: newUserServerFileRefs,
                newUserImageFileRefs: newUserImageFileRefs,
                newUserTextFileServerRefs: newUserTextFileServerRefs,
                newUserUnavailableFileCount: newUserUnavailableFileCount,
                fileServerReady: fileServerReady
            ),
            stream: false,
            model: model
        )

        // `ConverseRequest` is pure value-data (`String` + `Bool` — no
        // floats / dates / Data / custom encoders); `JSONEncoder.encode`
        // cannot fail for this shape. If a future refactor introduces a
        // fallible field, the runtime trap surfaces the regression loudly
        // rather than silently mis-categorising it as
        // `.remoteAgentInvalidResponse` (a response-side taxonomy that
        // would mislead the user).
        request.httpBody = try! JSONEncoder().encode(body)

        return request
    }

    // MARK: - Foreground pinning session (the ONE recipe)

    /// Build the converse-budget ephemeral cert-pinning session + its trust
    /// evaluator for a FOREGROUND send. The ONE session recipe for every
    /// foreground converse dispatch (macOS composer, macOS retry, macOS share
    /// drain) — mirrors `FileServerClient.makeProbeSession` so a timeout / TLS /
    /// cache-posture change lands in all of them at once instead of silently
    /// diverging per call site. **The caller owns invalidation** (the client
    /// does not own its session — every call site supplies one).
    ///
    /// Load-bearing details:
    ///   - Pass `pinnedFingerprintHex: nil` for an unpinned ref: the evaluator
    ///     then falls through to default ATS, which is the recommended posture
    ///     for a publicly-trusted gateway. The session is still delegate-bearing,
    ///     so the redirect policy applies and a later re-pin needs no new wiring.
    ///   - `.ephemeral`, not `.shared`: a converse hop must not deposit the
    ///     gateway's responses in the system URL cache or carry system cookies.
    ///   - The CONVERSE timeouts (300 s request / 600 s resource), NOT the 15 s
    ///     Test-Connection budget: a self-hosted LLM routinely thinks for
    ///     minutes, and a shorter ceiling kills a live turn as a phantom
    ///     "Network Offline". `.ephemeral` defaults to 60 s, so both must be set
    ///     explicitly.
    static func makePinnedForegroundSession(
        pinnedFingerprintHex: String?
    ) -> (session: URLSession, evaluator: RemoteAgentTrustEvaluator) {
        let evaluator = RemoteAgentTrustEvaluator(pinnedFingerprintHex: pinnedFingerprintHex)
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = Constants.remoteAgentConverseRequestTimeout
        config.timeoutIntervalForResource = Constants.remoteAgentConverseResourceTimeout
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        return (URLSession(configuration: config, delegate: evaluator, delegateQueue: nil), evaluator)
    }

    // MARK: - Private — transport

    /// Map a converse-hop transport `URLError` to the error the caller sees.
    /// Routed through `RemoteAgentTrustEvaluator.classifyTransportError` — the
    /// single source of truth every gateway probe already uses — so the converse
    /// hop and Test Connection can never drift on what counts as a cert failure.
    ///
    /// The signals come from the session's evaluator (no evaluator → `.empty`),
    /// which is what lets a PIN REJECTION be told apart from a
    /// benign cancel: the evaluator answers a mismatch with
    /// `cancelAuthenticationChallenge`, and URLSession surfaces that as
    /// `.cancelled` (-999) — byte-identical to the chat-thread Cancel button.
    /// Only a confirmed `pinRejected` upgrades `.cancelled` to a cert error; the
    /// default arm stays `CancellationError` so a user cancel never raises a
    /// spurious "Untrusted certificate" banner.
    ///
    /// `systemTrustRejected` comes from the same evaluator and is threaded
    /// through, not hardcoded: without it the lane a user actually converses on
    /// could never report a certificate problem at all. The cold-tunnel posture
    /// survives because both signals are POSITIVE — a transient
    /// `.secureConnectionFailed` (-1200) never reached a cert challenge, so both
    /// are false and it stays retryable.
    /// Every verdict comes from ONE `attemptSignals` snapshot off the evaluator
    /// that answered this attempt's challenge. There is deliberately no
    /// loose-Bool overload: any such surface silently drops
    /// `pinComparisonUnsupported`, and a key Conduck cannot fingerprint goes back
    /// to reporting as a possible interception.
    ///
    /// `isTaskCancelled` is REQUIRED and has no default, because a default is
    /// exactly how the bug it exists for got shipped. `URLError.cancelled`
    /// (-999) is not proof of a user cancel: a peer that resets the stream
    /// mid-request — a tunnel hiccup, a gateway dropping a large upload — is
    /// reported with the same code. Conduck is the only party that knows whether
    /// IT cancelled, and `Task.isCancelled` is that answer (`cancelInFlight()`
    /// cancels the enclosing task, and cancellation is sticky once set). Callers
    /// must read it INSIDE the catch, after the await failed — a value captured
    /// before the await is necessarily false and could never observe a Stop.
    static func mapTransportError(
        _ code: URLError.Code,
        signals: RemoteAgentTrustEvaluator.AttemptTrustSignals,
        isTaskCancelled: Bool
    ) -> Error {
        switch RemoteAgentTrustEvaluator.classifyTransportError(code, signals: signals) {
        case .timeout:
            return AppError.remoteAgentTimeout
        case .unreachable:
            return AppError.remoteAgentUnreachable
        case .notEstablished:
            return AppError.remoteAgentNotEstablished
        case .offline:
            // Reuses the existing generic offline case rather than minting a
            // gateway-flavoured twin: its copy ("No internet. Conduck needs
            // Wi-Fi or cellular to work.") is already exactly right, and it
            // correctly stops implicating the user's server.
            //
            // Verified safe for this lane: `shouldPreserveForRetry` is false for
            // code 3 (only `persistentNetworkFailure` and two STT cases are
            // true), so nothing gets queued into `PendingRetryStore`; and no
            // gateway send path reads `maxAttempts`, so its value of 3 cannot
            // resurrect automatic retries here. The never-silent-retry invariant
            // holds — retry stays a user tap.
            return AppError.noInternetConnection
        case .untrustedCert:
            // This device rejected the chain. NOT a mismatch: no pin disagreed,
            // nothing changed, and there is no pin to remove — removing one
            // would only fall back on the system trust that just refused. The
            // fix is on the server, and this case's copy names it.
            return AppError.remoteAgentCertUntrusted
        case .certMismatch:
            // A pin disagreed with a chain the system DID trust — the ONLY class
            // that may say the connection may be intercepted. The remedy is to
            // STOP and check, never to edit the pin: dropping it here switches off
            // the control that just caught something, and "the certificate
            // changed" is a guess this app has no evidence for. The one place
            // clearing a saved fingerprint is legitimate is
            // `.certKeyUnpinnable`, where nothing was caught because nothing was
            // compared.
            return AppError.remoteAgentCertMismatch
        case .certKeyUnpinnable:
            // System trust PASSED and the pin was never compared — the leaf's
            // key algorithm has no SPKI prefix Conduck can hash. Separate code
            // from `.certMismatch` so this user is never told their connection
            // may be intercepted over a certificate that is fine.
            return AppError.remoteAgentCertKeyUnpinnable
        case .cancelled:
            // A user-initiated task cancel (the chat-thread Cancel,
            // background-session teardown, structured-concurrency
            // cancellation) MUST NOT masquerade as a cert error. Re-throw as a
            // `CancellationError` so callers can treat it as a benign abort
            // distinct from any `.remoteAgent*` failure.
            //
            // But ONLY when this task was actually cancelled. A -999 with no
            // cancellation behind it came from the far side, and calling that a
            // cancel is the worst possible answer: the failure writers treat a
            // cancel as "not a gateway verdict" and persist NO classification,
            // so the turn renders the bare generic "wasn't delivered" copy with
            // no cause, no Troubleshoot, and — because Diagnostics filters on a
            // non-nil failure code — no record that it ever happened.
            // `.remoteAgentUnreachable` is the honest verdict: something
            // interrupted the connection, and delivery is UNCERTAIN (the request
            // may well have reached the gateway), which is precisely what that
            // case's copy says.
            guard isTaskCancelled else { return AppError.remoteAgentUnreachable }
            return CancellationError()
        }
    }

    /// Execute the request, mapping URLError → AppError. The bearer header
    /// is on the request object; we never echo request material into the
    /// thrown error.
    private static func performRequest(
        _ request: URLRequest,
        transport: Transport
    ) async throws -> (Data, URLResponse) {
        do {
            return try await transport.session.data(for: request)
        } catch let error as URLError {
            // `.empty` for a lane with no evaluator: no challenge was answered,
            // so there is no verdict to read — never a posture inferred from
            // whether a pin happens to be configured.
            //
            // `Task.isCancelled` is read HERE, after the await failed, so a Stop
            // tapped during the request is observed. (A peer reset and a Stop can
            // still race; the catch reports whichever is true when it runs.
            // Attributing that exactly would need a per-turn cancellation token,
            // which buys nothing the user can perceive.)
            throw mapTransportError(
                error.code,
                signals: transport.evaluator?.attemptSignals ?? .empty,
                isTaskCancelled: Task.isCancelled
            )
        } catch is CancellationError {
            // Preserve an upstream cancellation as-is rather than collapsing
            // it to `.remoteAgentUnreachable` — a cancelled turn is benign.
            throw CancellationError()
        } catch {
            // Non-URLError transport failure — collapse to unreachable.
            throw AppError.remoteAgentUnreachable
        }
    }

    // MARK: - Private — response decode

    /// Map HTTP status via the backend's status map; on 2xx decode the body
    /// and return `choices[0].message.content`. Never logs the body or
    /// auth material.
    private static func decodeReply(
        data: Data,
        response: URLResponse,
        backend: RemoteAgentBackend
    ) throws -> String {
        guard let http = response as? HTTPURLResponse else {
            throw AppError.remoteAgentInvalidResponse
        }

        // Body-aware mapping FIRST: a structured adapter wire code, or a
        // 400/404/413 whose body names the problem (no-vision model, image too
        // large, context overflow, bad model id). The `(Int)->` status map
        // never sees the body, so this dedicated pass runs before it — only
        // the specific bodies match (others fall through to the existing
        // status map unchanged). Thrown as `ClassifiedRemoteAgentFailure` so
        // the failure writers can persist the classification — catch
        // it BEFORE `catch let error as AppError`.
        if let classified = Self.classifyBodyError(status: http.statusCode, body: data) {
            throw classified
        }

        if let mapped = backend.statusMap.map(http.statusCode) {
            throw mapped
        }

        // 2xx — decode tolerant body, extract reply content.
        let decoded: ConverseResponse
        do {
            decoded = try JSONDecoder().decode(ConverseResponse.self, from: data)
        } catch {
            throw AppError.remoteAgentInvalidResponse
        }

        guard let reply = decoded.firstReplyContent else {
            throw AppError.remoteAgentInvalidResponse
        }
        return reply
    }

    // MARK: - Body-aware error mapping (shared by both send paths)

    /// Map a gateway rejection that only the response BODY can disambiguate to a
    /// concrete, non-retryable `AppError` (the `(Int)->AppError?` status map sees
    /// only the code). Called from BOTH `RemoteAgentClient.decodeReply` and the
    /// `BackgroundRemoteAgent` delegate, BEFORE the status map, so these surface
    /// a clear, actionable error instead of the generic retryable `.apiFailure`
    /// ("Something glitched on our end").
    ///
    /// Pure-status rejections (408/429) live in `RemoteAgentStatusMap` instead —
    /// they need no body and so apply to all four send paths automatically; this
    /// pass is only for the cases where the status alone is ambiguous (a 400 or
    /// 404 can mean several different things).
    ///
    /// Rules (only on 400 / 404 / 413), first match wins:
    /// 1. vision-unsupported — `/unsupported.*content/i`, `/image.*not.*support/i`,
    ///    `/support.*image/i`, or `/image.*input/i` → `.remoteAgentVisionUnsupported`.
    /// 2. image-too-large — status 413, or `/image.*too.*large/i` → `.remoteAgentImageTooLarge`.
    /// 3. context-too-long — `/maximum context length/i` or `/context_length_exceeded/i`
    ///    → `.remoteAgentContextTooLong` (history/attachments overflow the window).
    /// 4. model-unavailable — `/not a valid model/i`, `/no endpoints found for/i`,
    ///    or `/embedding model/i` → `.remoteAgentModelUnavailable` (typo'd / delisted /
    ///    non-chat model id; the user hand-types this).
    /// 5. otherwise `nil` (fall through to the existing status map).
    ///
    /// **Vision is checked first on purpose.** OpenRouter rejects an image to a
    /// text-only model with `404 "No endpoints found that support image input"`
    /// (matches `support.*image`), while a bad model id gives `404 "No endpoints
    /// found for <model>"` (matches `no endpoints found for`). Keeping vision
    /// ahead of model-unavailable keeps those two 404 shapes distinct.
    ///
    /// Matching prefers the structured top-level `error.message` (so OpenRouter's
    /// `metadata.raw` provider-wrapper text can't false-match), falling back to
    /// the whole-body string for gateways that don't use that envelope.
    ///
    /// Never logs the body (privacy — replies/errors are not logged).
    static func mapBodyError(status: Int, body: Data) -> AppError? {
        classifyBodyError(status: status, body: body)?.appError
    }

    /// Full-fidelity variant of `mapBodyError`: the mapped `AppError` PLUS the
    /// structured adapter-contract wire code when the body carried one.
    ///
    /// **Wire code first (revision 1.3).** A structured `error.code` matching
    /// the frozen `AdapterWireCode` vocabulary classifies EXACTLY, at any
    /// 4xx/5xx — the contract says clients key on the code, prose is free. An
    /// unknown / absent code falls through to the regex heuristics below,
    /// which keep their original narrow status gate (400/404/413 + the 422
    /// model-required carve-out) — a code upgrade must never widen what the
    /// heuristics can claim.
    static func classifyBodyError(status: Int, body: Data) -> ClassifiedRemoteAgentFailure? {
        if (400..<600).contains(status),
           let raw = Self.extractErrorCode(from: body),
           let code = AdapterWireCode(rawValue: raw) {
            return ClassifiedRemoteAgentFailure(appError: code.appError, wireCode: code)
        }
        guard let heuristic = Self.heuristicBodyError(status: status, body: body) else { return nil }
        return ClassifiedRemoteAgentFailure(appError: heuristic, wireCode: nil)
    }

    private static func heuristicBodyError(status: Int, body: Data) -> AppError? {
        // 422 is admitted ONLY for the model-required check below, never for the
        // rest of this pass. OpenAI-compatible servers built on FastAPI (vLLM,
        // several LiteLLM deployments) answer a MISSING `model` with an
        // Unprocessable-Entity validation envelope rather than a 400, so without
        // 422 those rejections skip the pass entirely and surface as the generic
        // retryable `.apiFailure`. But the eligibility of 400/404/413 for the
        // vision / image-size / context shapes is PINNED by test — a 422 must not
        // become vision-eligible just because its body happens to match. Hence the
        // narrow admission here and the wider guard for everything else.
        guard status == 400 || status == 404 || status == 413 || status == 422 else { return nil }

        // Prefer the structured `{"error":{"message":"…"}}` field; fall back to
        // the raw body for non-OpenAI-envelope gateways.
        let text = Self.extractErrorMessage(from: body)
            ?? String(data: body, encoding: .utf8)
            ?? ""

        func matchesModelRequired() -> Bool {
            text.range(of: "model is required", options: [.regularExpression, .caseInsensitive]) != nil
                || text.range(of: "model.*required.*propert", options: [.regularExpression, .caseInsensitive]) != nil
                || text.range(of: "must provide a model", options: [.regularExpression, .caseInsensitive]) != nil
                || text.range(of: "model parameter is required", options: [.regularExpression, .caseInsensitive]) != nil
                || text.range(of: "missing.*required.*model", options: [.regularExpression, .caseInsensitive]) != nil
        }

        // A model was not merely WRONG — none was sent at all, and this gateway
        // insists on one. Distinct from `.remoteAgentModelUnavailable` ("check the
        // model name") because there is no name to check: the fix is to SET one.
        // Ollama, vLLM, and a LiteLLM without a configured default all land here,
        // and it is the commonest failure of a hand-configured custom gateway —
        // whose model field is `.optional`, so nothing blocks an empty save.
        // Checked FIRST so it owns the 422 slot outright.
        if matchesModelRequired() {
            return .remoteAgentModelRequired
        }

        // Everything below is pinned to 400/404/413 (see the guard note above).
        guard status != 422 else { return nil }

        func matches(_ pattern: String) -> Bool {
            text.range(
                of: pattern,
                options: [.regularExpression, .caseInsensitive]
            ) != nil
        }

        if matches("unsupported.*content")
            || matches("image.*not.*support")
            || matches("support.*image")
            || matches("image.*input") {
            return .remoteAgentVisionUnsupported
        }

        // Image-too-large is a 400/413 concept; a 404 here never reaches this
        // branch (its only image-specific shape is the vision-unsupported one
        // matched above — a bare model-not-found 404 returns nil below).
        if status == 413 || matches("image.*too.*large") {
            return .remoteAgentImageTooLarge
        }

        if matches("maximum context length") || matches("context_length_exceeded") {
            return .remoteAgentContextTooLong
        }

        if matches("not a valid model")
            || matches("no endpoints found for")
            || matches("embedding model") {
            return .remoteAgentModelUnavailable
        }

        return nil
    }

    /// Pull the OpenAI/OpenRouter-style `error.message` string out of an error
    /// body, ignoring nested `metadata.raw` provider-wrapper text. Returns `nil`
    /// when the body isn't that envelope (caller falls back to the raw string).
    private static func extractErrorMessage(from body: Data) -> String? {
        struct Envelope: Decodable { struct Err: Decodable { let message: String? }; let error: Err? }
        return (try? JSONDecoder().decode(Envelope.self, from: body))?.error?.message
    }

    /// Pull the adapter-contract `error.code` out of an error body. Tolerates
    /// a numeric code (some OpenAI-compatible stacks send `"code": 400`) by
    /// stringifying it — a number never matches the frozen vocabulary, so it
    /// classifies as no-code rather than mis-decoding the whole envelope.
    private static func extractErrorCode(from body: Data) -> String? {
        struct Envelope: Decodable {
            struct Err: Decodable {
                let code: String?
                init(from decoder: Decoder) throws {
                    let container = try decoder.container(keyedBy: CodingKeys.self)
                    if let s = try? container.decode(String.self, forKey: .code) {
                        code = s
                    } else if let i = try? container.decode(Int.self, forKey: .code) {
                        code = String(i)
                    } else {
                        code = nil
                    }
                }
                private enum CodingKeys: String, CodingKey { case code }
            }
            let error: Err?
        }
        return (try? JSONDecoder().decode(Envelope.self, from: body))?.error?.code
    }
}
