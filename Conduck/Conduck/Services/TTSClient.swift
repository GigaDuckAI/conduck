// SPDX-License-Identifier: Apache-2.0

// Conduck
// TTSClient.swift
//
// Cloud Text-to-Speech client. Sibling of `Services/STTClient.swift` —
// mirrors its actor shape, retry-loop-with-per-error-budget, and URLError →
// AppError mapping, but inverted direction (text → audio bytes instead of
// audio file → text). Provider dispatch lives on the `TTSProvider` value type
// (URL, model, auth scheme, transport, body factory, status map) exactly as
// `STTClient` dispatches on `STTProvider`.
//
// Differences vs STTClient (all intentional):
//   - Returns in-memory `Data` (mp3 bytes), NEVER written to disk — a spoken
//     reply therefore has no on-disk lifetime to bound at all. There is no
//     temp-file cleanup contract because no file is ever created.
//   - The 5 frozen cloud providers use default ATS (`URLSession.shared`). The
//     6th, the BYO `custom-openai-tts` endpoint (`dynamicEndpointKey != nil`),
//     mirrors custom STT: a per-call ephemeral session with a
//     `RemoteAgentTrustEvaluator` (optional SHA-256 leaf-cert pin), a dynamically
//     resolved URL (base + `/v1/audio/speech`), an effective auth scheme + model
//     from its `CustomTTSConfig`, and the certificate mapping that reads the
//     evaluator's own signals (`ttsCustomCertUntrusted` when this device
//     rejected the chain, `ttsCustomCertMismatch` when a pin disagreed with a
//     chain it accepted).
//   - Tighter retry: the per-error `AppError.maxAttempts` caps
//     `ttsProviderUnreachable` at 2 (a failed spoken reply never burns more
//     than two attempts before the free, always-available Apple
//     `AVSpeechSynthesizer` fallback at the playback layer takes over).
//   - 429 honors `Retry-After`: a rate-limited synthesize waits the provider's
//     stated penalty (never less than the base 1 s) before its one retry —
//     a blind 1 s retry inside the penalty window always fails, which used to
//     downgrade the rest of a chunked reply to the Apple voice on low-RPM free
//     tiers. The chunk queue's lookahead runway absorbs the wait for tail
//     chunks; the head chunk is bounded by ReplyVoice's first-audio watchdog.
//     A penalty longer than `maxRetryAfterWait` (15 s) gives up IMMEDIATELY
//     (retrying inside the window is doomed — fall back to Apple now instead
//     of wasting the wait).
//
// Privacy invariants (load-bearing — see docs/ai-context/spec.md):
//   - The API key is NEVER logged, printed, or surfaced in a thrown error.
//   - The `text` (the agent reply being spoken) is NEVER logged.
//   - The synthesis URL is NEVER logged.

import Foundation

/// Text-to-speech client. Provider-agnostic — dispatches on the `TTSProvider`
/// passed by the caller. v1 ships 4 cloud providers (OpenAI / Mistral /
/// ElevenLabs / Gemini); the Apple sentinel is handled at the playback layer and
/// NEVER reaches this actor (its `sharedKeySTTPresetID` is nil, so `ReplyVoice`
/// never fetches for it). Returns an audio container `Data` (mp3 for OpenAI /
/// Mistral / ElevenLabs, WAV-wrapped PCM for Gemini — see `ResponseShape`).
actor TTSClient {
    // MARK: - Singleton

    static let shared = TTSClient()
    private init() { }

    // MARK: - Retry Configuration

    /// Upper bound on retry attempts. The per-error `AppError.maxAttempts`
    /// decides the real cap — `ttsProviderUnreachable` is 2. A failed spoken
    /// reply is cheap to recover (Apple voice), so we never spin past 2.
    private let maxRetryAttempts = 2

    /// Delays before each retry attempt in seconds: [0, 1]. First attempt has
    /// no delay. A 429's `Retry-After` hint RAISES the pre-retry wait (never
    /// lowers it) up to `maxRetryAfterWait`.
    private let retryDelays: [TimeInterval] = [0, 1]

    /// Longest provider-stated `Retry-After` penalty we absorb before the one
    /// 429 retry. Sized to the chunk queue's runway: tail chunks ≥2 fetch
    /// while ~30 s+ of earlier audio is still playing, so the wait is
    /// inaudible there. The two runway-poor callers accept a bounded worst
    /// case as the price of keeping the chosen voice: tail 1 (fetch launches
    /// WITH the head's — runway ≈ head synth + playback ≈ 20 s, so a
    /// near-cap wait can cost a few seconds of first-seam silence, vs
    /// pre-Retry-After behavior downgrading the whole remainder to Apple) and
    /// the head/single-blob/preview paths (up to ~16 s in the pre-audio state,
    /// bounded by ReplyVoice's 45 s first-audio watchdog on reply turns; the
    /// settings preview shows its spinner throughout and the honored wait can
    /// make the sample actually play where the old blind retry was doomed).
    /// A stated penalty ABOVE the cap means even the honored retry would land
    /// inside the window — give up immediately instead.
    static let maxRetryAfterWait: TimeInterval = 15

    // MARK: - Synthesize (text → mp3 bytes)

    /// Synthesize spoken audio for `text` via `provider`. Returns the raw mp3
    /// bytes in memory (never written to disk). Caller (`ReplyVoice`)
    /// hands the `Data` to an `AVAudioPlayer` and releases it on completion.
    ///
    /// - Parameters:
    ///   - text: the text to speak (privacy-sensitive — never logged).
    ///   - provider: the TTS provider record (URL, model, auth, transport,
    ///     body factory, status map). Must NOT be the Apple sentinel
    ///     (`apple-tts`) — that provider has a nil `bodyFactory` and is handled
    ///     at the playback layer; passing it throws `ttsSynthesisFailed`.
    ///   - voice: optional per-provider voice override. Resolved via
    ///     `provider.effectiveVoice(override:)` → ride the body (OpenAI /
    ///     Mistral) or the URL path (ElevenLabs, via `effectiveSpeechURL`).
    ///   - customModel: optional per-provider MODEL override (`tts.customModel.<id>`)
    ///     for the 4 frozen cloud providers. Resolved via
    ///     `provider.effectiveModel(customModel:)` → rides the body (OpenAI /
    ///     Mistral) or the URL path (Gemini, via `effectiveSpeechURL`). IGNORED
    ///     for the custom endpoint (it uses `customConfig.model` — the override
    ///     must NEVER leak there). Nil → the provider's pinned default model.
    ///   - apiKey: bearer token / header value for the provider. Never logged.
    ///     May be empty for a keyless custom endpoint (`CustomTTSConfig.auth ==
    ///     .none`).
    ///   - customConfig: fully-resolved BYO-endpoint config — non-nil ONLY for
    ///     the custom provider (`provider.dynamicEndpointKey != nil`). Carries the
    ///     resolved synthesis URL, effective model + auth scheme, and optional
    ///     cert pin. Nil for the 5 frozen providers (zero behavior change).
    ///   - session: injectable for tests (`MockURLProtocol`). Defaults to the
    ///     shared session (default ATS). IGNORED for the custom endpoint, which
    ///     builds its own cert-pinned ephemeral session.
    /// - Returns: mp3 audio bytes (non-empty — `ttsEmptyAudio` is thrown if the
    ///   provider returns a 2xx with a zero-length body).
    /// - Throws: `AppError` — `ttsProviderUnreachable` (transient, retryable),
    ///   `ttsSynthesisFailed` (terminal 4xx/5xx), `ttsEmptyAudio` (empty 2xx),
    ///   `ttsCustomEndpointNotConfigured` / `ttsCustomCertUntrusted` /
    ///   `ttsCustomCertMismatch` (custom only),
    ///   or a transport error (`requestTimeout` / `noInternetConnection`).
    func synthesize(
        text: String,
        provider: TTSProvider,
        voice: String?,
        customModel: String? = nil,
        apiKey: String,
        customConfig: CustomTTSConfig? = nil,
        session: URLSession = .shared
    ) async throws -> Data {
        // The Apple sentinel never reaches here — it has no `bodyFactory` and is
        // played on-device. A nil factory means either Apple was misrouted here
        // or a future registry regression; surface a terminal error so the
        // playback layer falls back to Apple rather than spinning the retry loop.
        guard let factory = provider.bodyFactory else {
            throw AppError.ttsSynthesisFailed
        }

        // The BYO custom endpoint resolves its URL/model/auth/pin dynamically;
        // the 5 frozen providers use their immutable registry fields. Declarative
        // dispatch off `dynamicEndpointKey` — no scattered `if id == ...`.
        let isCustomEndpoint = provider.dynamicEndpointKey != nil

        let effVoice = provider.effectiveVoice(override: voice)

        // URL: the custom endpoint's target is the user's stored base URL with
        // `/v1/audio/speech` appended (carried in `customConfig.url`), NOT the
        // sentinel `provider.speechURL`. For ElevenLabs the voice rides the URL
        // path (+ output_format query); OpenAI / Mistral / Gemini use a fixed URL.
        // Model: the custom endpoint uses the REQUIRED user-set value from its
        // config (`/v1/audio/speech` mandates one that varies per server); the
        // frozen providers resolve the per-provider override-or-pinned-default
        // via `effectiveModel(customModel:)`. The per-provider override must
        // NEVER leak to the custom endpoint, so it is only consulted in the
        // `else` branch. Resolved BEFORE the URL so Gemini's model-in-URL rewrite
        // sees the same effective model.
        let effModel = isCustomEndpoint
            ? (customConfig?.model ?? provider.model)
            : provider.effectiveModel(customModel: customModel)

        // URL: the custom endpoint's target is the user's stored base URL with
        // `/v1/audio/speech` appended (carried in `customConfig.url`), NOT the
        // sentinel `provider.speechURL`. For ElevenLabs the voice rides the URL
        // path; for Gemini the MODEL rides the URL path (an override rebuilds the
        // endpoint); OpenAI / Mistral use a fixed URL (voice + model in the body).
        let effURL: URL
        if isCustomEndpoint {
            guard let resolved = customConfig?.url else {
                // Custom provider active but no base URL configured — surface the
                // typed "not configured" error so the user learns to set the URL
                // (preview) rather than a generic failure. In chat this maps to
                // the silent Apple fallback like any other throw.
                throw AppError.ttsCustomEndpointNotConfigured
            }
            effURL = resolved
        } else {
            // The per-provider model override (`customModel`) composes the Gemini
            // model-in-URL rewrite here in the same call as the ElevenLabs voice
            // rewrite. The override is NEVER passed for the custom endpoint.
            effURL = provider.effectiveSpeechURL(voice: effVoice, customModel: customModel)
        }

        var request = URLRequest(url: effURL)
        request.httpMethod = "POST"
        request.timeoutInterval = isCustomEndpoint ? Constants.customTTSRequestTimeout : Constants.requestTimeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try factory.buildRequestBody(
            text: text,
            model: effModel,
            voice: effVoice
        )

        // Auth — frozen providers use the immutable scheme (bearer / `xi-api-key`).
        // The custom endpoint uses the effective scheme from its config: `.bearer`
        // or `.none` (a keyless local server, where `apply` sets no header and the
        // empty `apiKey` is harmless). The key is set on the request object only;
        // never echoed into a log or a thrown error.
        let effAuth: STTAuthScheme = isCustomEndpoint ? (customConfig?.auth ?? provider.auth) : provider.auth
        effAuth.apply(to: &request, apiKey: apiKey)

        // Session/trust: the BYO custom endpoint gets a per-call ephemeral session
        // with a `RemoteAgentTrustEvaluator` (nil pin → system trust alone; pin
        // set → system trust AND a matching SHA-256 leaf key), torn down on exit.
        // The generic evaluator is
        // reused verbatim from STT / the gateway. Frozen providers keep the
        // injected/shared session (default ATS, zero behavior change). Only the
        // per-call custom session is owned here — never invalidate `.shared`.
        let effSession: URLSession
        let trustEvaluator: RemoteAgentTrustEvaluator?
        if isCustomEndpoint {
            let evaluator = RemoteAgentTrustEvaluator(pinnedFingerprintHex: customConfig?.certFingerprint)
            effSession = URLSession(configuration: .ephemeral, delegate: evaluator, delegateQueue: nil)
            trustEvaluator = evaluator
        } else {
            effSession = session
            trustEvaluator = nil
        }
        defer {
            if isCustomEndpoint {
                effSession.invalidateAndCancel()
            }
        }

        // Retry loop. Per-error `maxAttempts` caps it — `ttsProviderUnreachable`
        // is 2, so the loop runs at most twice before falling back to Apple at
        // the playback layer.
        var lastError: AppError = .ttsProviderUnreachable

        // Provider-stated 429 penalty (parsed `Retry-After`, seconds) from the
        // most recent response; consumed by the next attempt's pre-retry wait.
        var retryAfterHint: TimeInterval?

        for attempt in 0..<maxRetryAttempts {
            if attempt > 0 {
                let baseDelay = retryDelays[attempt]
                var delay = baseDelay
                if let hint = retryAfterHint {
                    // The provider named its penalty window. Too long to
                    // absorb → a retry inside the window is doomed; give up
                    // NOW (Apple fallback) instead of wasting the wait.
                    guard hint <= Self.maxRetryAfterWait else { break }
                    // Honor the stated wait, never retrying SOONER than the
                    // base pacing.
                    delay = max(hint, baseDelay)
                }
                retryAfterHint = nil
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                // Cancelled mid-wait (End pressed / turn superseded / watchdog
                // fired) — don't fire a pointless request for a dead turn.
                if Task.isCancelled { break }
            }

            do {
                let (data, response) = try await performRequest(request, session: effSession, trustEvaluator: trustEvaluator)
                // Capture the 429 penalty BEFORE the status map throws it away
                // (`parseResponse` sees only the status code, not headers).
                if let http = response as? HTTPURLResponse, http.statusCode == 429 {
                    retryAfterHint = Self.retryAfterSeconds(from: http.value(forHTTPHeaderField: "Retry-After"))
                }
                return try parseResponse(data: data, response: response, provider: provider)
            } catch let error as AppError {
                lastError = error

                // Non-retryable (auth, 4xx, empty audio) fails fast — the
                // playback layer falls back to Apple immediately.
                if !error.isRetryable {
                    throw error
                }

                // Respect the per-error retry budget. `attempt` is 0-indexed.
                if attempt + 1 >= error.maxAttempts {
                    break
                }
            } catch is CancellationError {
                // Propagate, never retry — the loop's own `if Task.isCancelled`
                // guard only covers a cancel that lands during the backoff wait,
                // not one that lands mid-request.
                throw CancellationError()
            } catch {
                lastError = .ttsProviderUnreachable
            }
        }

        throw lastError
    }

    // MARK: - Retry-After parsing

    /// Parse a `Retry-After` header into a wait in seconds. RFC 9110 allows
    /// two forms: delta-seconds (`"12"`, fractional tolerated) and an
    /// HTTP-date (`"Wed, 21 Oct 2015 07:28:00 GMT"` → seconds from `now`;
    /// the obsolete rfc850 + asctime date forms a recipient must also accept
    /// are covered). Returns nil for a missing/garbage/negative value (caller
    /// keeps the base pacing). Static + pure so tests hit it directly; `now`
    /// is injectable for the date forms.
    static func retryAfterSeconds(from header: String?, now: Date = Date()) -> TimeInterval? {
        guard let raw = header?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }

        // Delta-seconds — SHAPE-VALIDATED before the numeric parse. A bare
        // `TimeInterval(raw)` also accepts "1e20"/"inf"/hex-float forms, which
        // would masquerade as a huge "penalty" and skip the base-paced retry
        // the garbage→nil contract promises.
        if raw.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ".") }) {
            return TimeInterval(raw)   // nil for malformed digit runs ("1.2.3")
        }

        // HTTP-date forms, always read as GMT. POSIX locale so a device set to
        // a non-English locale still parses the English day/month names.
        // asctime pads a single-digit day with a second space — collapse runs.
        let normalized = raw.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        for pattern in [
            "EEE, dd MMM yyyy HH:mm:ss zzz",   // IMF-fixdate (the live form)
            "EEEE, dd-MMM-yy HH:mm:ss zzz",    // obsolete rfc850
            "EEE MMM d HH:mm:ss yyyy",         // obsolete asctime (no zone = GMT)
        ] {
            formatter.dateFormat = pattern
            if let date = formatter.date(from: normalized) {
                // A past date means the penalty lapsed — retry at base pacing.
                return max(0, date.timeIntervalSince(now))
            }
        }
        return nil
    }

    // MARK: - Private

    /// Execute the request on `session`, mapping URLError → AppError. Auth
    /// header lives on the request object; never echoed into a thrown error.
    ///
    /// `trustEvaluator` is non-nil ONLY for the BYO custom endpoint (mirrors
    /// `STTClient.performRequest`); the frozen cloud providers ride the injected
    /// session under plain ATS and collapse a cert failure to the transient
    /// `ttsProviderUnreachable`. The evaluator's signals are what make a
    /// certificate verdict legible at all: it fails closed on a chain this
    /// device rejects, and URLSession reports that cancel as a bare `.cancelled`
    /// (-999) that the code alone cannot tell from a user abort.
    private func performRequest(
        _ request: URLRequest,
        session: URLSession,
        trustEvaluator: RemoteAgentTrustEvaluator?
    ) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: request)
        } catch let error as URLError {
            if let trustEvaluator {
                // Instance form — one snapshot of the attempt that failed, and
                // the only form that can carry `pinComparisonUnsupported`
                // (mirrors `STTClient.performRequest`).
                switch trustEvaluator.classifyTransportError(error.code) {
                case .untrustedCert:
                    throw AppError.ttsCustomCertUntrusted
                case .certMismatch:
                    throw AppError.ttsCustomCertMismatch
                case .certKeyUnpinnable:
                    // System trust passed and the pin could not be computed for
                    // this key algorithm — its own code, so the remedy names
                    // the key type instead of raising an interception warning.
                    throw AppError.ttsCustomCertKeyUnpinnable
                case .blockedByATS:
                    // -1022: iOS refused the address before any connect, so this
                    // is neither a certificate verdict nor a reachability one.
                    // Lane-neutral code — the remedy is the same address advice
                    // on every lane.
                    throw AppError.insecureConnectionBlocked
                case .timeout, .unreachable, .notEstablished, .offline, .cancelled:
                    // No certificate verdict — fall through to the code mapping
                    // that owns the TTS taxonomy. A cold tunnel's generic
                    // `.secureConnectionFailed` lands here (both trust signals
                    // are POSITIVE) and stays transient; `.cancelled` lands on the
                    // arm below that preserves it as a cancel.
                    break
                }
            }
            switch error.code {
            case .timedOut:
                throw AppError.requestTimeout
            case .notConnectedToInternet, .networkConnectionLost:
                throw AppError.noInternetConnection
            case .cancelled:
                // The classifier already ruled out the evaluator's own refusals
                // above, so a `-999` reaching here is a genuine cancellation —
                // End pressed, the turn superseded, the first-audio watchdog.
                // Preserved AS a cancellation (mirroring
                // `RemoteAgentClient.mapTransportError`) rather than reported as
                // `.ttsProviderUnreachable`, which is RETRYABLE and reads as "the
                // provider is down": it spent the remaining attempt on a turn
                // nobody is listening to and then handed the playback layer a
                // provider verdict for something the provider never did. The
                // Apple fallback is unaffected — both `ReplyVoice` fetch sites
                // already return early on a cancelled turn before choosing a leg.
                throw CancellationError()
            default:
                // Generic transport failure → transient (one retry, then Apple).
                // URLError's `localizedDescription` carries no header material.
                throw AppError.ttsProviderUnreachable
            }
        } catch {
            throw AppError.ttsProviderUnreachable
        }
    }

    /// Map HTTP status → AppError via `provider.statusMap`; on 2xx return the
    /// audio bytes (throwing `ttsEmptyAudio` for a zero-length body). Never logs
    /// the request body, the audio, or the auth header.
    private func parseResponse(
        data: Data,
        response: URLResponse,
        provider: TTSProvider
    ) throws -> Data {
        guard let http = response as? HTTPURLResponse else {
            throw AppError.invalidResponse
        }

        if let mapped = provider.statusMap.map(http.statusCode) {
            throw mapped
        }

        // 2xx — decode the audio per the provider's response shape: raw bytes
        // (OpenAI / ElevenLabs) vs base64-in-JSON (Mistral `audio_data`). A
        // missing / empty / undecodable payload throws `ttsEmptyAudio` so the
        // playback layer falls back to Apple rather than handing garbage to
        // `AVAudioPlayer` (which fails opaquely). Never logs the body (privacy).
        return try provider.responseDecoding.decodeAudio(from: data)
    }
}
