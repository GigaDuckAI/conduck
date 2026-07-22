//
//  WatchTTSClient.swift
//  ConduckWatch Watch App
//
//  Cloud Text-to-Speech client for the watchOS surface. Thin mirror of
//  `WatchNetworkClient` (the Watch STT client): an `enum` with a single static
//  `synthesize` — single attempt, no retry loop, 60s transport timeout,
//  injectable `URLSession` (default `.shared`, mirroring the iOS `TTSClient`
//  seam so tests can stub the transport).
//
//  Why no retry (mirrors `WatchNetworkClient`): on the wrist a failed cloud
//  synthesis falls straight back to `AVSpeechSynthesizer` in `WatchReplySpeaker`
//  — Apple's voice is free, instant, offline. Retrying would just delay the
//  inevitable fallback. The caller treats ANY throw as "use Apple".
//
//  Why 60s: the transport clock owns NO user-facing wait — `WatchReplySpeaker`'s
//  20s first-audio watchdog bounds the pre-audio stall, and the chunk queue's
//  10s seam-stall grace bounds a tail fetch playback is actually blocked on.
//  What remains for the transport timeout is dead-socket hygiene on fetches
//  nobody is waiting for (a lookahead tail with playback runway still banked
//  ahead of it) — and there a TIGHTER clock is the bug: `.wristConservative`
//  plateau tails run ~480 chars ≈ 30s+ of synthesis at the segmenter's modeled
//  real-time rate, so a 30s bound would kill exactly the longest replies'
//  healthy tails mid-turn and downgrade the remainder to Apple for no
//  user-visible gain. 60s clears the modeled worst case over the jittery
//  BT→paired-iPhone relay while still reclaiming a genuinely dead connection.
//
//  Dispatches on the SHARED `TTSProvider` / `TTSBodyFactory` / `TTSStatusMap`
//  registry (these compile in the Watch target via the foundation's
//  `membershipExceptions` edit). The Apple sentinel (`apple-tts`) never reaches
//  here — `WatchReplySpeaker` plays it on-device.
//
//  Privacy invariants (docs/ai-context/spec.md "Privacy & Security"):
//    - The API key is NEVER logged, printed, or echoed into thrown errors.
//    - The `text` (agent reply) and the synthesis URL are NEVER logged.
//

import Foundation

enum WatchTTSClient {
    /// Synthesize spoken audio for `text` via `provider`. Returns the raw mp3
    /// bytes in memory (never written to disk). Single attempt; throws
    /// `AppError` on any failure (caller falls back to Apple on the wrist).
    ///
    /// - Parameters:
    ///   - text: the text to speak (privacy-sensitive — never logged).
    ///   - provider: the shared `TTSProvider` record. Must not be the Apple
    ///     sentinel (nil `bodyFactory` → `ttsSynthesisFailed`).
    ///   - voice: optional per-provider voice override (nil → provider default).
    ///   - customModel: optional per-provider MODEL override (nil → provider
    ///     default). Resolved via `effectiveModel` (body) / `effectiveSpeechURL`
    ///     (Gemini URL path) so the wrist honors the same override the phone
    ///     stores. Never reaches the BYO custom endpoint (Watch can't reach it).
    ///   - apiKey: bearer / header value for the provider. Never logged.
    ///   - session: injectable for tests (guard/error-mapping coverage without
    ///     a network). Defaults to the shared session (default ATS).
    /// - Returns: mp3 audio bytes (non-empty — `ttsEmptyAudio` on a 2xx empty body).
    static func synthesize(
        text: String,
        provider: TTSProvider,
        voice: String?,
        customModel: String? = nil,
        apiKey: String,
        session: URLSession = .shared
    ) async throws -> Data {
        guard let factory = provider.bodyFactory else {
            throw AppError.ttsSynthesisFailed
        }

        // The BYO custom endpoint (`dynamicEndpointKey != nil`) is iOS/macOS only:
        // its base URL + cert pin live in `SettingsManager` (not a Watch-target
        // member) and the server may be LAN/Tailscale-only, unreachable from the
        // wrist. Throw so `WatchReplySpeaker` falls back to the Apple voice —
        // mirrors the custom-STT relay-off-wrist posture (`WatchNetworkClient`).
        guard provider.dynamicEndpointKey == nil else {
            throw AppError.ttsCustomEndpointNotConfigured
        }

        let effVoice = provider.effectiveVoice(override: voice)
        // Per-provider model override → the body (OpenAI / Mistral) AND the Gemini
        // model-in-URL path (composed in `effectiveSpeechURL`). Resolved BEFORE the
        // URL so Gemini's URL rewrite sees the same effective model.
        let effModel = provider.effectiveModel(customModel: customModel)
        let effURL = provider.effectiveSpeechURL(voice: effVoice, customModel: customModel)

        var request = URLRequest(url: effURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.networkServiceType = .responsiveData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try factory.buildRequestBody(
            text: text,
            model: effModel,
            voice: effVoice
        )
        provider.auth.apply(to: &request, apiKey: apiKey)

        return try await performAndDecode(
            request: request,
            statusMap: provider.statusMap,
            decoding: provider.responseDecoding,
            session: session
        )
    }

    /// Network + status-map + body decode, OFF the main actor (`@concurrent`).
    /// The guards + request build above are sub-millisecond string/JSON work and
    /// stay on the caller's actor — the body factory and `STTAuthScheme.apply`
    /// (an `inout` request mutation) are main-actor-bound under the Watch
    /// target's MainActor default isolation. The decode is the real cost —
    /// Mistral's `.base64JSON` arm parses the whole multi-hundred-KB body — and
    /// must not stall the wrist UI at reply-arrival auto-speak, so it (and the
    /// response handling around it) runs on the concurrent pool.
    @concurrent
    private nonisolated static func performAndDecode(
        request: URLRequest,
        statusMap: TTSStatusMap,
        decoding: TTSProvider.ResponseShape,
        session: URLSession
    ) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            throw mapTransportError(error)
        } catch {
            throw AppError.ttsProviderUnreachable
        }

        guard let http = response as? HTTPURLResponse else {
            throw AppError.invalidResponse
        }
        if let mapped = statusMap.map(http.statusCode) {
            throw mapped
        }
        // 2xx — decode per the provider's response shape (raw bytes for OpenAI /
        // ElevenLabs, base64-in-JSON `audio_data` for Mistral). Shared with
        // iPhone's `TTSClient` so the wrist decodes Mistral identically.
        // Missing / empty / undecodable → `ttsEmptyAudio` (caller falls back to
        // Apple). Never logs the body.
        return try decoding.decodeAudio(from: data)
    }

    /// Pure transport `URLError` → `AppError` mapping — mirrors the iOS
    /// `TTSClient` contract exactly (`.timedOut` → `requestTimeout`, offline
    /// codes → `noInternetConnection`, everything else →
    /// `ttsProviderUnreachable`) so the surfaced cause can't drift between
    /// surfaces. `nonisolated` — pure and called from the `@concurrent` hop.
    nonisolated static func mapTransportError(_ error: URLError) -> AppError {
        switch error.code {
        case .notConnectedToInternet, .networkConnectionLost:
            return .noInternetConnection
        case .timedOut:
            return .requestTimeout
        default:
            return .ttsProviderUnreachable
        }
    }
}
