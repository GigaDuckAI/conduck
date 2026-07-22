// Conduck
// ElevenLabsSTTProvider.swift
//
// Bespoke POST probe for ElevenLabs Scribe v2. Replaces the default
// `STTGETProbe` because ElevenLabs API keys are scoped per-feature: a
// security-conscious user grants the Conduck key only `speech_to_text`
// and neither `user_read` (probe was `GET /v1/user` → 401) nor `models_read`
// (`GET /v1/models` → 401) is granted. The only scope guaranteed to work
// against a STT-only key is the STT endpoint itself, so the probe POSTs
// the bundled silent WAV to `provider.transcribeURL` and inspects only
// the HTTP status (200/4xx-non-auth → key reached server → success;
// 401 → auth failed; 5xx → server error).
//
// Asset reuse: `Resources/stt-probe-silent.wav` (100 ms, 8 kHz mono PCM,
// ~1.6 KB) — same shape as the Qwen probe's expected asset; intentionally
// shared so future Qwen probe rewire can point at the same file.

import Foundation

enum ElevenLabsSTTProbe: STTProbe {

    private static let probeAssetName = "stt-probe-silent"
    private static let probeAssetExt  = "wav"
    private static let probeAssetMIME = "audio/wav"
    private static let probeAssetFilename = "probe.wav"

    static func validate(apiKey: String, provider: STTProvider) async throws {
        guard let url = Bundle.main.url(forResource: probeAssetName,
                                        withExtension: probeAssetExt) else {
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
            model: provider.model,
            language: nil,
            fieldNames: fieldNames
        )

        var request = URLRequest(url: provider.transcribeURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("multipart/form-data; boundary=\(boundary)",
                         forHTTPHeaderField: "Content-Type")
        provider.auth.apply(to: &request, apiKey: apiKey)
        request.httpBody = body

        let response: URLResponse
        do {
            (_, response) = try await URLSession.shared.data(for: request)
        } catch is URLError {
            throw AppError.sttProviderUnreachable
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
            // 400 / 413 / 422 / 429 on a 100ms silent WAV still means the
            // key reached the server and was accepted at the auth layer.
            // Treat as success — the probe's only job is "key authenticates".
            return
        }
    }
}
