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
//   - Per-call `URLSession` injection (foreground default; the background
//     coordinator passes a configured session).
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
    ///   - session: the `URLSession` to issue through. Defaults to
    ///     `.shared` for foreground tests + Mac/CarPlay callers;
    ///     the background coordinator passes a configured background session for
    ///     iOS + Watch.
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
        // True when the conversation's bound gateway has a READY file lane
        // (`fileTransferReadySnapshot != nil`) — appends the per-turn
        // file-delivery instruction to the newest user turn. REQUIRED (no
        // default) so every foreground call site is compiler-forced to decide:
        // a silent default here would drop the instruction from exactly one
        // dispatch surface and resurrect the lost-output-file bug there.
        fileServerReady: Bool,
        session: URLSession = .shared
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
            fileServerReady: fileServerReady
        )
        RemoteAgentDiagnostics.log.log("send(fg): \(RemoteAgentDiagnostics.shapeSummary(diagMessages, bodyBytes: request.httpBody?.count ?? 0), privacy: .public)")
        let diagStart = Date()
#endif

        let (data, response) = try await Self.performRequest(request, session: session)

#if DEBUG
        let diagHTTP = (response as? HTTPURLResponse)?.statusCode ?? -1
        RemoteAgentDiagnostics.log.log("done(fg): elapsed=\(String(format: "%.1f", Date().timeIntervalSince(diagStart)), privacy: .public)s http=\(diagHTTP, privacy: .public) respBytes=\(data.count, privacy: .public)")
#endif

        return try Self.decodeReply(data: data, response: response, backend: backend)
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

    // MARK: - Private — transport

    /// Execute the request, mapping URLError → AppError. The bearer header
    /// is on the request object; we never echo request material into the
    /// thrown error.
    private static func performRequest(
        _ request: URLRequest,
        session: URLSession
    ) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: request)
        } catch let error as URLError {
            switch error.code {
            case .timedOut:
                throw AppError.remoteAgentTimeout
            case .cannotConnectToHost,
                 .notConnectedToInternet,
                 .networkConnectionLost,
                 .cannotFindHost,
                 .dnsLookupFailed,
                 .resourceUnavailable:
                throw AppError.remoteAgentUnreachable
            case .serverCertificateUntrusted,
                 .serverCertificateHasBadDate,
                 .serverCertificateHasUnknownRoot,
                 .serverCertificateNotYetValid:
                // The system named the CERTIFICATE as the cause (and on the
                // live hop the cert was already trusted/pinned at pairing) →
                // surface as a cert mismatch so the user is told to re-check it.
                throw AppError.remoteAgentCertMismatch
            case .secureConnectionFailed:
                // GENERIC SSL failure (`-1200`) — NOT a certificate-trust
                // signal on its own. On the live converse hop (the cert was
                // validated at pairing time) this is almost always a transient
                // handshake hiccup over a cold tunnel → retryable. Do NOT
                // mislabel it as a cert mismatch (the unconditional `hasPin`-less
                // converse path can't tell a real rejection from a cold route).
                throw AppError.remoteAgentUnreachable
            case .cancelled:
                // A user-initiated task cancel (the chat-thread Cancel,
                // background-session teardown, structured-concurrency
                // cancellation) MUST NOT masquerade as a cert error.
                // Re-throw as a `CancellationError` so callers can treat it
                // as a benign abort distinct from any `.remoteAgent*`
                // failure. (Cert mismatch is handled above via the
                // dedicated server-certificate codes — never via .cancelled.)
                throw CancellationError()
            default:
                throw AppError.remoteAgentUnreachable
            }
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
