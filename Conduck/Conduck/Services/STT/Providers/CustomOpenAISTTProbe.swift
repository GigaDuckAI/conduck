// SPDX-License-Identifier: Apache-2.0

// Conduck
// CustomOpenAISTTProbe.swift
//
// Basic auth-layer probe for the BYO custom OpenAI-compatible STT endpoint
// (`STTProvider.customOpenAICompat` base prefix + its per-uuid instances).
// Mirrors the `ElevenLabsSTTProbe` / `QwenSTTProbe` "POST the bundled silent
// WAV, inspect HTTP status only" shape — the probe's only job is "the
// endpoint accepts requests at the auth layer", NOT "transcription succeeds"
// (the rich `STTConnectionTestSuite`, the custom endpoint's DEFAULT Test
// action, owns the real round-trip).
//
// Three structural differences from the frozen-provider probes, all resolved
// from the endpoint's OWN config (`CustomSTTConfig` — per-uuid slots for a
// `custom-openai_<uuid>` preset, the legacy singleton slots for the bare id),
// exactly like `STTClient.transcribe`:
//   - the transcribe URL is the user's stored base URL (never the sentinel
//     `provider.transcribeURL`, never the legacy slots for a per-uuid preset);
//   - auth is the endpoint's EFFECTIVE scheme (`.bearer` / `.none` for a
//     keyless local server) — never the immutable archetype default;
//   - the request runs on a per-call pinned session (`RemoteAgentTrustEvaluator`,
//     nil pin → system trust alone) so a pinned endpoint is held to the SAME
//     one certificate here as on the live transcribe path, instead of whatever
//     `URLSession.shared` would accept — and the evaluator's trust signals are
//     read back through `classifyTransportError`, the shared classifier the
//     other three custom-STT call sites use, so a terminal certificate refusal
//     is reported as one instead of as a transient outage.
//
// Privacy: the resolved URL and the key are NEVER logged or surfaced in an
// error — only HTTP-status-derived taxonomy cases are thrown.

import Foundation

enum CustomOpenAISTTProbe: STTProbe {

    /// Bundled silent-WAV asset (100 ms, 8 kHz mono PCM, ~1.6 KB) — shared
    /// with `ElevenLabsSTTProbe`. See `Conduck/Resources/stt-probe-silent.wav`.
    private static let probeAssetName = "stt-probe-silent"
    private static let probeAssetExt  = "wav"
    private static let probeAssetMIME = "audio/wav"
    private static let probeAssetFilename = "probe.wav"

    /// Config-less entry (protocol requirement): resolve the ACTIVE preset's
    /// config — per-uuid slots when `provider.id` carries a uuid, the legacy
    /// singleton slots otherwise — then delegate. Callers that already hold a
    /// resolved snapshot (Diagnostics) pass it via the config-aware variant.
    static func validate(apiKey: String, provider: STTProvider) async throws {
        let config: CustomSTTConfig
        if let uuid = STTProvider.customEndpointUUID(fromPresetID: provider.id) {
            config = await SettingsManager.shared.customSTTConfig(for: uuid)
        } else {
            config = CustomSTTConfig(
                url: await SettingsManager.shared.customSTTTranscribeURL(),
                model: await SettingsManager.shared.getCustomSTTModel(),
                auth: await SettingsManager.shared.getCustomSTTAuthScheme(),
                certFingerprint: await SettingsManager.shared.getCustomSTTCertFingerprint()
            )
        }
        try await validate(apiKey: apiKey, provider: provider, customConfig: config)
    }

    static func validate(apiKey: String, provider: STTProvider, customConfig: CustomSTTConfig?) async throws {
        // Nil = the endpoint base URL isn't configured yet; surfaced as
        // `sttCustomEndpointNotConfigured` so the user learns to set the URL
        // rather than seeing a generic auth failure.
        guard let transcribeURL = customConfig?.url else {
            throw AppError.sttCustomEndpointNotConfigured
        }

        guard let url = Bundle.main.url(forResource: probeAssetName,
                                        withExtension: probeAssetExt) else {
            // Probe asset missing from bundle — surface as invalidResponse
            // so the founder/QA notices the bundling regression rather than
            // the user seeing a generic auth failure.
            throw AppError.invalidResponse
        }

        let wavData: Data
        do {
            wavData = try Data(contentsOf: url)
        } catch {
            throw AppError.invalidResponse
        }

        guard let fieldNames = provider.multipartFieldNames else {
            throw AppError.invalidResponse
        }

        let (boundary, body) = STTMultipartBuilder.build(
            audioData: wavData,
            audioMIME: probeAssetMIME,
            audioFilename: probeAssetFilename,
            model: customConfig?.model ?? provider.model,
            language: nil,
            fieldNames: fieldNames
        )

        var request = URLRequest(url: transcribeURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("multipart/form-data; boundary=\(boundary)",
                         forHTTPHeaderField: "Content-Type")
        // EFFECTIVE scheme — `.none` sends no Authorization header (keyless
        // local server); never the immutable archetype default.
        (customConfig?.auth ?? provider.auth).apply(to: &request, apiKey: apiKey)
        request.httpBody = body

        // Per-call pinned session, mirroring `STTClient.transcribe`'s custom
        // path (nil pin → system trust alone).
        let evaluator = RemoteAgentTrustEvaluator(pinnedFingerprintHex: customConfig?.certFingerprint)
        let session = URLSession(configuration: .ephemeral, delegate: evaluator, delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        let response: URLResponse
        do {
            (_, response) = try await session.data(for: request)
        } catch let urlError as URLError {
            throw transportError(urlError.code, signals: evaluator.attemptSignals)
        } catch {
            throw AppError.sttProviderUnreachable
        }

        guard let http = response as? HTTPURLResponse else {
            throw AppError.invalidResponse
        }

        switch http.statusCode {
        case 200..<300:
            return
        case 401, 403:
            throw AppError.sttAuthFailed
        case 500..<600:
            throw AppError.sttServerError
        default:
            // 400 / 413 / 422 / 429 on a 100 ms silent WAV still means the
            // request reached the server and was accepted at the auth layer.
            // Treat as success — the probe's only job is "endpoint accepts us".
            return
        }
    }

    /// The STT error a probe's transport `code` means, given the evaluator's
    /// trust signals read back after the awaited request returned. Pure over its
    /// inputs so the routing is unit-testable without a live endpoint.
    ///
    /// Routed through `RemoteAgentTrustEvaluator.classifyTransportError` — the
    /// same single source of truth as `STTClient.performRequest`,
    /// `STTClient+Background`, and `STTConnectionTestSuite` — because a
    /// certificate refusal is TERMINAL and `.sttProviderUnreachable` is
    /// retryable. The evaluator FAILS CLOSED on a chain this device rejects and
    /// URLSession reports that cancel as a bare `.cancelled` (-999); without the
    /// signals, a refusal the user has to fix on their own server is
    /// indistinguishable from a server that happens to be down, and gets
    /// retried instead of explained.
    /// Takes the whole `AttemptTrustSignals` snapshot rather than loose Bools:
    /// only the snapshot carries `pinComparisonUnsupported`, and without it a
    /// key Conduck cannot hash reports as a pin MISMATCH — an interception
    /// warning on a certificate the system accepted.
    static func transportError(
        _ code: URLError.Code,
        signals: RemoteAgentTrustEvaluator.AttemptTrustSignals
    ) -> AppError {
        switch RemoteAgentTrustEvaluator.classifyTransportError(code, signals: signals) {
        case .untrustedCert:
            return .sttCustomCertUntrusted
        case .certMismatch:
            return .sttCustomCertMismatch
        case .certKeyUnpinnable:
            // System trust passed and the digest could not be computed, so the
            // pin was never compared. Its own code — the probe must not report
            // a possible interception it has no evidence for.
            return .sttCustomCertKeyUnpinnable
        case .timeout, .unreachable, .cancelled:
            // No certificate verdict. A cold tunnel's generic
            // `.secureConnectionFailed` lands here (both signals are POSITIVE)
            // and keeps the probe's existing retryable outcome.
            return .sttProviderUnreachable
        }
    }
}
