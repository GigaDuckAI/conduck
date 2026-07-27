// SPDX-License-Identifier: Apache-2.0

// Conduck
// STTClient.swift
//
// Async multipart-upload STT client: retry-loop with per-error budget, URL
// error → AppError mapping, JSON response decode.
//
// Provider dispatch (multi-provider):
//   - The `STTProvider` value type carries wire-level contract (URL, model,
//     auth scheme, transport, size/duration caps, multipart field names OR
//     JSON body factory, response shape, status-code mapping).
//   - Foreground `transcribe(...)` branches on `provider.transport` and
//     delegates body construction to `STTMultipartBuilder` or
//     `provider.jsonBodyFactory`, and response decode to `STTResponseDecoder`
//     or `provider.jsonBodyFactory`. Status mapping always via
//     `provider.statusMap` (load-bearing —
//     "Mistral 429 retried as OpenAI 429" is the regression we guard).
//   - The auth header is set via `provider.auth.apply(to:apiKey:)` so the
//     bearer-vs-headerName distinction (ElevenLabs `xi-api-key`, Gemini
//     `x-goog-api-key`) lives in the provider table, not here.
//
// Privacy invariants (load-bearing — see the spec.md "Privacy & Security" section):
//   - The API key is NEVER logged, printed, or surfaced in error messages.
//   - When logging errors, redact the `Authorization` / custom-auth header.
//
// Audio cleanup mandate (load-bearing):
//   - Foreground `transcribe(...)` deletes `audioFileURL` via `defer` at the
//     top of the method so the temp file is gone on success OR throw.
//   - The background variant (`STTClient+Background.swift`) recovers
//     `audioFileURL` via `STTBackgroundTaskMetadata` on `task.taskDescription`
//     and `removeItem` on both success and failure paths.

import Foundation
import AVFoundation
#if !os(watchOS)
// Speech framework is `@available(watchOS, unavailable)`; import only
// on platforms where `AppleSpeechRunner` compiles. Required so the
// `headProbe` Apple branch can pattern-match against the
// `SFSpeechRecognizerAuthorizationStatus` cases returned by
// `AppleSpeechRunner.requestAuthorization()`.
import Speech
#endif

/// Result of a successful STT round-trip. Provider-agnostic shape.
struct STTResponse: Sendable {
    /// Transcribed text.
    let text: String

    /// Detected (or echoed back) language code, if the provider returned one.
    /// May be nil for providers that don't return language metadata.
    let language: String?
}

/// Speech-to-text client. Provider-agnostic — dispatches on the `STTProvider`
/// passed by the caller. V1 ships 5 cloud providers; per-preset Keychain +
/// active-preset KVS lookup happen at the caller (`SettingsManager`).
actor STTClient {
    // MARK: - Singleton

    static let shared = STTClient()
    private init() { }

    // MARK: - Retry Configuration

    /// Upper bound on retry attempts (per-error budget via `AppError.maxAttempts`
    /// decides the actual cap). Network blips use the full 3; upstream service
    /// outages stop at 2 (see `AppError.maxAttempts`).
    private let maxRetryAttempts = 3

    /// Delays before each retry attempt in seconds: [0, 1, 2].
    /// First attempt has no delay; total worst-case backoff = 3 s.
    private let retryDelays: [UInt64] = [0, 1, 2]

    // MARK: - Key-Validation Probe
    //
    // Method name `headProbe` is historical (was a HEAD request; Mistral
    // returns 405 for HEAD on `/v1/models`, so switched to GET). Kept as
    // `headProbe` to avoid churning `SettingsViewModel` call sites. Actual
    // wire behavior is delegated to `provider.probe` (`STTGETProbe` default;
    // Qwen ships `QwenSTTProbe`).

    /// Validate an API key against `provider`. Single attempt (no retry);
    /// probe is called interactively after the user pastes a key — fast-fail
    /// surfaces the real reason. Delegates to `provider.probe.validate(...)`.
    ///
    /// - Parameters:
    ///   - apiKey: bearer / header value to test.
    ///   - provider: the STT provider whose probe to run.
    ///   - customConfig: resolved BYO-endpoint config (Diagnostics passes its
    ///     snapshot's) — the custom probe honors its URL/auth/pin; frozen
    ///     providers ignore it. Nil → the custom probe resolves the active
    ///     preset's config itself.
    /// - Throws: per `STTProbe.validate` — typically `sttAuthFailed` on 401,
    ///   `sttProviderUnreachable` on network failure, `sttServerError` on 5xx.
    func headProbe(apiKey: String, provider: STTProvider, customConfig: CustomSTTConfig? = nil) async throws {
        // Apple on-device "probe" = TCC authorization request, not a
        // network round-trip. `provider.probe` (NoOpSTTProbe) is a
        // no-op for Apple; the real check is the system Speech-
        // Recognition permission dialog. Firing it at Settings-time
        // (when the user picks Apple as their active STT preset)
        // avoids a silent failure during the Shortcut headless path
        // later, where there's no UI to surface a permission prompt.
        // The runner re-checks TCC synchronously at transcribe-time
        // as the safety net for users who revoke between now and then.
        if provider.id == "apple-on-device" {
            #if !os(watchOS)
            let status = await AppleSpeechRunner.requestAuthorization()
            switch status {
            case .authorized:
                return
            case .denied, .restricted, .notDetermined:
                // TCC denial is `speechPermissionDenied` (51), never
                // `sttAuthFailed` (8): the fix is the Settings toggle,
                // not a key re-paste. Cloud 401s elsewhere keep 8.
                throw AppError.speechPermissionDenied
            @unknown default:
                throw AppError.speechPermissionDenied
            }
            #else
            // Watch never reaches the Apple-active probe path — Watch
            // ships its own audio-relay coordinator.
            // Defensive: surface permission-denied so a misrouted call
            // doesn't silently succeed.
            throw AppError.speechPermissionDenied
            #endif
        }
        try await provider.probe.validate(apiKey: apiKey, provider: provider, customConfig: customConfig)
    }

    // MARK: - Transcribe (multipart OR JSON upload)

    /// Foreground upload. Used by the iOS in-app mic + Shortcut path +
    /// macOS menu bar + CarPlay. Background-session variant lives in
    /// `STTClient+Background.swift` for the Watch surface.
    ///
    /// Audio cleanup contract (load-bearing): `audioFileURL` is deleted by
    /// this method via `defer` — succeed OR throw, the file does not survive.
    ///
    /// - Parameters:
    ///   - audioFileURL: path to the audio file on disk (M4A AAC).
    ///   - apiKey: bearer token / header value for the STT provider.
    ///   - language: optional ISO 639-1 hint (e.g., "en", "de"); nil = auto-detect.
    ///   - provider: the STT provider record (wire format, auth, caps, decoder).
    ///   - customModel: optional per-preset model override (Feature 1). Nil →
    ///     the provider's pinned default. Resolved by the caller from
    ///     `activeSTTSnapshot()`; threaded into the multipart / JSON model field
    ///     and (for Gemini) the URL path via `provider.effective*`.
    ///   - customConfig: fully-resolved BYO-endpoint config — non-nil ONLY for
    ///     the custom provider (`provider.dynamicEndpointKey != nil`). Carries
    ///     the resolved transcribe URL, effective auth scheme, and optional
    ///     cert pin. Nil for the 6 frozen providers (zero behavior change).
    /// - Returns: `STTResponse` with transcribed text and (optional) detected language.
    /// - Throws: `AppError` — retryability via `AppError.isRetryable` / `.maxAttempts`.
    func transcribe(
        audioFileURL: URL,
        apiKey: String,
        language: String?,
        provider: STTProvider,
        customModel: String? = nil,
        customConfig: CustomSTTConfig? = nil
    ) async throws -> STTResponse {
        // AUDIO CLEANUP MANDATE (load-bearing): foreground temp
        // file MUST be deleted on every exit path, success or throw.
        defer { try? FileManager.default.removeItem(at: audioFileURL) }

        // In-process providers (Apple on-device) bypass all network
        // machinery — no auth header, no size guard (the runner streams
        // via `AVAudioFile`, not full payload into RAM), no retry loop
        // (in-process errors are deterministic: model missing / auth
        // denied / corrupt audio — retries don't help). Settings-time
        // TCC prompt has already fired via `headProbe`; the runner
        // re-checks TCC synchronously inside `transcribe` as the safety
        // net for users who revoked permission between Settings-time
        // and now.
        if provider.transport == .inProcess {
            guard let runner = provider.inProcessRunner else {
                // Mis-configured registry entry — .inProcess without a
                // runner. Should be impossible if `STTProvider`
                // registration is sound; defensive throw catches any
                // future regression to a runner-less placeholder.
                throw AppError.sttDecodingFailure
            }
            return try await runner.transcribe(audioFileURL: audioFileURL, language: language)
        }

        // Load the audio bytes once; reused across retry attempts so a
        // retry doesn't re-read from disk (which would race the deferred
        // cleanup if a future caller changed this method's structure).
        let audioData: Data
        do {
            audioData = try Data(contentsOf: audioFileURL)
        } catch {
            throw AppError.audioMissingData
        }

        // Pre-flight size guard — per-provider cap (Qwen 10 MB, others 15 MB).
        guard audioData.count <= provider.maxAudioBytes else {
            throw AppError.audioTooLarge
        }
        guard !audioData.isEmpty else {
            throw AppError.audioMissingData
        }

        // Pre-flight duration guard. Skipped on failure — the upstream API
        // will still reject oversized clips with 413/422, this is a cheap
        // local optimization for the common case (Qwen hard 5-min cap).
        if let duration = try? await AVURLAsset(url: audioFileURL).load(.duration) {
            let seconds = CMTimeGetSeconds(duration)
            if seconds.isFinite, seconds > provider.maxAudioSeconds {
                throw AppError.audioTooLarge
            }
        }

        // Resolve the effective model once. The BYO custom provider's model
        // comes from its OWN dedicated config field (`customConfig.model`,
        // stored under `stt.custom.model`, default "whisper-1") surfaced in the
        // custom-endpoint UI — NOT the generic per-preset Advanced override slot
        // (`stt.customModel.*`), which would be a second competing source. The 6
        // frozen providers use the generic per-preset override → default.
        let effModel = customConfig?.model ?? provider.effectiveModel(customModel: customModel)

        // Resolve the effective transcribe URL. For the BYO custom provider the
        // target is the user's stored base URL with `/v1/audio/transcriptions`
        // appended (carried in `customConfig.url`) — NOT the sentinel
        // `provider.transcribeURL`. For Gemini the model lives in the URL path
        // so an override rebuilds the endpoint (`effectiveTranscribeURL`). Every
        // other provider returns its fixed `transcribeURL`. Declarative dispatch
        // off `dynamicEndpointKey` — no scattered `if id == "custom-openai"`.
        let effURL: URL
        if provider.dynamicEndpointKey != nil {
            guard let resolved = customConfig?.url else {
                // Custom provider active but no base URL configured — surface
                // the typed "not configured" error so the user learns to set
                // the URL rather than seeing a generic unreachable failure.
                throw AppError.sttCustomEndpointNotConfigured
            }
            effURL = resolved
        } else {
            effURL = provider.effectiveTranscribeURL(customModel: customModel)
        }

        // Build the request — branch on transport.
        var request = URLRequest(url: effURL)
        request.httpMethod = "POST"
        // The BYO custom endpoint (a self-hosted Whisper on modest hardware) may
        // take real time — give it the long 300 s timeout. Cloud STT keeps its
        // tight 120 s `requestTimeout` untouched (declarative off the dynamic
        // endpoint key — never widen cloud's budget).
        request.timeoutInterval = provider.dynamicEndpointKey != nil
            ? Constants.customSTTRequestTimeout
            : Constants.requestTimeout

        switch provider.transport {
        case .multipart:
            guard let fields = provider.multipartFieldNames else {
                // Mis-configured registry entry — multipart without field names.
                throw AppError.sttDecodingFailure
            }
            let (boundary, body) = STTMultipartBuilder.build(
                audioData: audioData,
                audioMIME: "audio/mp4",
                audioFilename: "audio.m4a",
                model: effModel,
                language: language,
                fieldNames: fields
            )
            request.setValue(
                "multipart/form-data; boundary=\(boundary)",
                forHTTPHeaderField: "Content-Type"
            )
            request.httpBody = body

        case .json:
            guard let factory = provider.jsonBodyFactory else {
                throw AppError.sttDecodingFailure
            }
            let body = try factory.buildRequestBody(audioData: audioData, language: language, model: effModel)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body

        case .inProcess:
            // Unreachable — `.inProcess` is intercepted at the top of
            // `transcribe` (early-return before data-load) and never
            // reaches the transport switch. Kept as a defensive throw
            // rather than an `assertionFailure` so a future refactor
            // that accidentally removes the early-return surfaces a
            // mapped error instead of a crash.
            throw AppError.sttDecodingFailure
        }

        // Apply auth. The custom provider uses its EFFECTIVE scheme from the
        // resolved config (`.bearer` / `.none` for keyless local servers) — NOT
        // the immutable `provider.auth`; every frozen provider uses its own.
        let effAuth = customConfig?.auth ?? provider.auth
        effAuth.apply(to: &request, apiKey: apiKey)

        // TRUST/SESSION: cloud providers (`dynamicEndpointKey == nil`) keep the
        // shared session (zero behavior change, default ATS). The BYO custom
        // provider gets a per-call session with a `RemoteAgentTrustEvaluator`
        // (nil pin → default ATS; pin set → SHA-256 leaf-cert pinning), torn
        // down on exit. The generic evaluator is reused verbatim.
        let session: URLSession
        if provider.dynamicEndpointKey != nil {
            let evaluator = RemoteAgentTrustEvaluator(pinnedFingerprintHex: customConfig?.certFingerprint)
            session = URLSession(configuration: .ephemeral, delegate: evaluator, delegateQueue: nil)
        } else {
            session = .shared
        }
        // Only the per-call custom session is owned here — never invalidate the
        // shared session.
        defer {
            if provider.dynamicEndpointKey != nil {
                session.invalidateAndCancel()
            }
        }

        // Retry loop with exponential backoff. Per-error `maxAttempts`
        // caps the loop — network blips get full 3, upstream outages get 2.
        var lastError: AppError = .sttProviderUnreachable

        for attempt in 0..<maxRetryAttempts {
            if attempt > 0 {
                let delaySeconds = retryDelays[attempt]
                try? await Task.sleep(nanoseconds: delaySeconds * 1_000_000_000)
            }

            do {
                let (data, response) = try await performRequest(
                    request,
                    session: session,
                    isCustomEndpoint: provider.dynamicEndpointKey != nil
                )
                return try parseResponse(data: data, response: response, provider: provider)
            } catch let error as AppError {
                lastError = error

                // Non-retryable errors fail fast — surface the real reason
                // (bad audio, auth failure, quota) rather than burning 9 s.
                if !error.isRetryable {
                    throw error
                }

                // Respect per-error retry budget. attempt is 0-indexed; once
                // we've used `error.maxAttempts` chances, break and surface.
                if attempt + 1 >= error.maxAttempts {
                    break
                }
            } catch {
                lastError = .networkError(error)
            }
        }

        // Transport-layer exhaustion collapses into persistentNetworkFailure
        // so PendingRetryStore callers see a single, save-for-retry-eligible
        // error.
        switch lastError {
        case .noInternetConnection, .networkError, .requestTimeout:
            throw AppError.persistentNetworkFailure
        default:
            throw lastError
        }
    }

    // MARK: - Private

    /// Execute the HTTP request on `session`, mapping URLError to AppError.
    /// Auth header is on the request object; we never echo it into thrown
    /// errors. `session` is `.shared` for cloud providers (default ATS, zero
    /// behavior change) and a per-call pinned ephemeral session for the BYO
    /// custom endpoint (see `transcribe(...)`).
    ///
    /// `isCustomEndpoint` is true ONLY for the BYO custom provider — it gates
    /// the server-certificate URLError → `sttCustomCertMismatch` mapping (the
    /// `RemoteAgentTrustEvaluator` cancels a pinned-fingerprint mismatch, which
    /// URLSession surfaces as one of the server-cert / secure-connection
    /// failures). Cloud providers can never hit the pin path, so their cert
    /// failures stay generic network errors (zero behavior change).
    private func performRequest(
        _ request: URLRequest,
        session: URLSession,
        isCustomEndpoint: Bool
    ) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: request)
        } catch let error as URLError {
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost:
                throw AppError.noInternetConnection
            case .timedOut:
                throw AppError.requestTimeout
            case .serverCertificateUntrusted where isCustomEndpoint,
                 .serverCertificateHasBadDate where isCustomEndpoint,
                 .serverCertificateHasUnknownRoot where isCustomEndpoint,
                 .serverCertificateNotYetValid where isCustomEndpoint:
                // Only the custom endpoint pins — a pinned-fingerprint mismatch
                // cancels the challenge, which URLSession reports as one of
                // these SPECIFIC server-certificate codes. The GENERIC
                // `.secureConnectionFailed` is deliberately NOT here: it also
                // fires for transient cold-tunnel handshake hiccups, so it must
                // fall through to a retryable `.networkError` rather than a
                // false hard cert mismatch.
                throw AppError.sttCustomCertMismatch
            default:
                // `.networkError` wraps the URLError — URLError's
                // `localizedDescription` does NOT contain header material.
                throw AppError.networkError(error)
            }
        } catch {
            throw AppError.networkError(error)
        }
    }

    /// Map HTTP status → AppError via `provider.statusMap`; on 2xx decode the
    /// body via the per-transport decoder. Never logs the request body or
    /// auth header.
    private func parseResponse(
        data: Data,
        response: URLResponse,
        provider: STTProvider
    ) throws -> STTResponse {
        guard let http = response as? HTTPURLResponse else {
            throw AppError.invalidResponse
        }

        if let mapped = provider.statusMap.map(http.statusCode) {
            throw mapped
        }

        // 2xx — decode by transport.
        switch provider.transport {
        case .multipart:
            guard let shape = provider.responseShape else {
                throw AppError.sttDecodingFailure
            }
            return try STTResponseDecoder.decode(data, shape: shape)
        case .json:
            guard let factory = provider.jsonBodyFactory else {
                throw AppError.sttDecodingFailure
            }
            return try factory.decodeResponse(data)
        case .inProcess:
            // `.inProcess` providers never
            // produce an `HTTPURLResponse` (no network round-trip). The
            // outer dispatch (line ~147) intercepts these before reaching
            // here; this arm exists only to keep the switch exhaustive.
            throw AppError.sttDecodingFailure
        }
    }
}
