// Conduck
// STTProbe.swift
//
// Auth-validation probe abstraction. 4 of 5 providers (Mistral, OpenAI,
// ElevenLabs, Gemini) use `STTGETProbe` (default — GET `provider.probeURL`,
// status-only check). Qwen's `QwenSTTProbe` handles its own POST +
// silent-WAV asset because DashScope provides no cheap GET surface for key
// validation.
//
// Mirrors `STTClient.headProbe` (L79-120) semantics: 200 → success,
// 401 → `sttAuthFailed`, 5xx → `sttServerError`, network err →
// `sttProviderUnreachable`, non-HTTP → `invalidResponse`. Used at
// Settings-paste time (interactive — single attempt, no retry).

import Foundation

/// Per-provider key-validation probe. Conformances are enum types with a
/// single static `validate` method (named, not a closure — preserves
/// stack-trace clarity).
protocol STTProbe {
    /// Validate `apiKey` against `provider`. Throws on any failure;
    /// returns normally on success. Single-attempt — callers (Settings UI)
    /// expect fast-fail with a specific error.
    static func validate(apiKey: String, provider: STTProvider) async throws

    // The config-aware variant is phone/Mac-only: `CustomSTTConfig` lives in
    // `SettingsManager.swift`, which the Watch target doesn't compile — and no
    // probe ever runs on the wrist (probing is a Settings-paste / Diagnostics
    // affordance).
    #if !os(watchOS)
    /// Config-aware variant: `customConfig` carries the resolved BYO-endpoint
    /// facts (per-uuid URL, effective auth scheme, cert pin) the probe must
    /// honor. Frozen providers ignore it (default implementation delegates to
    /// the plain variant); `CustomOpenAISTTProbe` overrides.
    static func validate(apiKey: String, provider: STTProvider, customConfig: CustomSTTConfig?) async throws
    #endif
}

#if !os(watchOS)
extension STTProbe {
    static func validate(apiKey: String, provider: STTProvider, customConfig: CustomSTTConfig?) async throws {
        try await validate(apiKey: apiKey, provider: provider)
    }
}
#endif

/// Default probe — GET `provider.probeURL` with `provider.auth` applied,
/// inspect HTTP status. Used by Mistral / OpenAI / ElevenLabs / Gemini.
/// If `provider.probeURL` is nil (Qwen routes through `QwenSTTProbe`
/// instead), this is a no-op success — caller should not invoke this for
/// probe-less providers.
enum STTGETProbe: STTProbe {
    static func validate(apiKey: String, provider: STTProvider) async throws {
        guard let url = provider.probeURL else {
            // No probe URL configured — treat as success (caller is
            // expected to use the provider's bespoke probe instead).
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        provider.auth.apply(to: &request, apiKey: apiKey)

        let response: URLResponse
        do {
            (_, response) = try await URLSession.shared.data(for: request)
        } catch let error as URLError {
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost, .timedOut:
                throw AppError.sttProviderUnreachable
            default:
                throw AppError.sttProviderUnreachable
            }
        } catch {
            throw AppError.sttProviderUnreachable
        }

        guard let http = response as? HTTPURLResponse else {
            throw AppError.invalidResponse
        }

        switch http.statusCode {
        case 200..<300:
            return
        case 400, 401, 403:
            // Key-rejection codes. Most providers use 401, but Google's
            // Gemini API returns 400 `API_KEY_INVALID` for a bad key and
            // 403 `PERMISSION_DENIED` for a disabled-API / restricted key —
            // both are user-fixable auth problems, NOT transient outages.
            // The probe GET carries no request body, so a 400 here can only
            // be the key, never a malformed payload. Map all three to
            // `sttAuthFailed` ("Invalid key.") instead of the misleading
            // "having issues, try again" of `sttServerError`.
            throw AppError.sttAuthFailed
        case 500...599:
            throw AppError.sttServerError
        default:
            // Anything else (404, etc.) means the URL/model surface
            // changed under us — treat as a provider issue rather than a
            // user-fixable auth problem (matches STTClient.headProbe).
            throw AppError.sttServerError
        }
    }
}

/// No-op probe — used by in-process providers (Apple on-device STT)
/// where there is no API key to validate. The real
/// authorization check for Apple happens via `SFSpeechRecognizer.
/// requestAuthorization` at Settings-set-active time, and is re-checked
/// in the transcribe hot path; an explicit Settings-paste probe round-
/// trip is a category error for a keyless provider.
enum NoOpSTTProbe: STTProbe {
    static func validate(apiKey: String, provider: STTProvider) async throws {
        // Intentional no-op — keyless providers have nothing to probe.
        return
    }
}
