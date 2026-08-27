// SPDX-License-Identifier: Apache-2.0

//
//  WatchNetworkClient.swift
//  ConduckWatch Watch App
//
//  Foreground Mistral Voxtral STT client for the watchOS surface.
//
//  Mirror of iPhone's `Services/STTClient.swift` (single-attempt, no retry
//  loop). Watch foreground path is intentionally simpler than iPhone's: on
//  the wrist a 2-minute frontmost window covers the upload, and the
//  caller falls back to `WatchAudioUploader` background URLSession on any
//  thrown error. Retrying on the Watch foreground path would just burn
//  more of that 2-minute window before the inevitable background fallback.
//
//  Privacy invariants (docs/ai-context/spec.md):
//    - The API key is NEVER logged, printed, or echoed into thrown errors.
//    - Bearer header is set on `URLRequest` only; never extracted into a
//      String, never interpolated into a debug log.
//

import Foundation

/// Result of a successful Watch STT round-trip. Provider-agnostic shape;
/// mirrors `STTResponse` in iPhone's `STTClient.swift`. Redefined locally
/// because the Watch target does not opt into `Services/STTClient.swift`
/// via `PBXFileSystemSynchronizedBuildFileExceptionSet` (intentional —
/// pulling that file in would drag the iOS-specific `STTClient` actor
/// into the Watch binary).
///
/// It mirrors the TRANSCRIPT BOUNDARY too, and must: `STTResponseDecoder` and
/// the JSON-family decoders compile into this target and resolve against THIS
/// struct, and the wrist's foreground (`WatchNetworkClient`) and background
/// (`WatchAudioUploader`) lanes both end here. Both definitions delegate to the
/// one shared rule in `STTTranscript`, so the two targets cannot drift.
struct STTResponse: Sendable {
    /// Transcribed text, already normalized (see `STTTranscript.normalized`).
    let text: String

    let language: String?

    /// The only way to build an `STTResponse` — see the phone-side twin.
    /// `nonisolated` because the Watch background-session delegate constructs
    /// one off the main actor.
    nonisolated init(text: String, language: String?) {
        self.text = STTTranscript.normalized(text)
        self.language = language
    }
}

enum WatchNetworkClient {
    /// Foreground STT upload. Returns on success; throws `AppError` on every
    /// failure (caller decides whether to fall back to background URLSession).
    ///
    /// Dispatches on `provider.transport` — multipart (Mistral / OpenAI /
    /// ElevenLabs) vs JSON (Gemini / Qwen). All wire-format details (endpoint,
    /// auth header, field names, response shape, 429 semantics) come from the
    /// supplied `STTProvider` value.
    ///
    /// Timeout 60s — generous for the Watch wrist-down scenario where the
    /// app stays foregrounded ~2 minutes after the wrist drops.
    ///
    /// `secrets` is the Keychain seam, defaulted to the process store — present
    /// so the two refusal arms below (both of which throw before a single byte
    /// leaves) can be driven in a test without a signed Keychain.
    static func uploadSTT(
        request: WatchSTTRequest,
        provider: STTProvider,
        secrets: any SecretStore = SettingsDependencies.processDefault.secrets
    ) async throws -> STTResponse {
        // Auth — fail fast, and say which failure it was. Per-preset Keychain
        // lookup (`forPresetID:`) so the key matches the provider we're about to
        // call, and TYPED so a locked Keychain is not reported as an empty one:
        // this watch stores the key `kSecAttrAccessibleAfterFirstUnlock`, so
        // before the first unlock after a reboot a perfectly good key reads back
        // as nothing. Code 23 asserts the slot is empty and is TERMINAL, which
        // on this lane deletes the recording the user just made
        // (`WatchRecordingService.runSTTUpload`); code 75 says only that the key
        // could not be READ, and is retryable, which is what routes the same
        // capture to the background fallback with the audio intact (I3, I6).
        let apiKey: String
        switch WatchIdentityResolver.sttAPIKeyReadResult(forPresetID: provider.id, secrets: secrets) {
        case .present(let key):
            apiKey = key
        case .missing:
            throw AppError.sttMissingAPIKey
        case .unreadable:
            throw AppError.sttKeyUnreadable
        }

        // Pre-flight size guard — local check avoids burning a round-trip
        // for an upload the provider would reject with 413 anyway.
        guard request.audioData.count <= provider.maxAudioBytes else {
            throw AppError.audioTooLarge
        }
        guard !request.audioData.isEmpty else {
            throw AppError.audioMissingData
        }

        // Effective transcribe URL — fixed per provider. No STT provider puts
        // its model in the URL path any more (Gemini was the last; its
        // Interactions endpoint is one URL for every model), so a per-preset
        // custom override (Feature 1) changes the BODY, never this URL. The
        // Watch never reaches the BYO `customOpenAICompat` provider (its
        // `dynamicEndpointKey != nil` audio is relayed to iPhone before this
        // path), so the dynamic-base-URL resolution that lives in iPhone's
        // `STTClient` is intentionally absent here.
        var urlRequest = URLRequest(url: provider.transcribeURL)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = 60
        urlRequest.networkServiceType = .responsiveData
        provider.auth.apply(to: &urlRequest, apiKey: apiKey)

        // Body construction branches on transport.
        let body: Data
        switch provider.transport {
        case .multipart:
            let boundary = "----ConduckWatch-\(UUID().uuidString)"
            urlRequest.setValue(
                "multipart/form-data; boundary=\(boundary)",
                forHTTPHeaderField: "Content-Type"
            )
            body = request.buildMultipartData(boundary: boundary)
        case .json:
            guard let factory = provider.jsonBodyFactory else {
                throw AppError.sttDecodingFailure
            }
            urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
            // Thread the effective model (custom override → pinned default)
            // into the JSON body. Both JSON providers consume it: Qwen as a
            // body tag, and Gemini likewise since its model moved out of the
            // URL path with the Interactions endpoint.
            body = try factory.buildRequestBody(
                audioData: request.audioData,
                language: request.language,
                model: request.model
            )
        case .inProcess:
            // `.inProcess` providers (Apple) are unreachable
            // on the Watch — no `SpeechAnalyzer` on watchOS. Apple-active
            // Watch recordings route through the
            // file-relay coordinator before this network path. Defensive
            // throw covers any race between envelope flip + dispatch.
            throw AppError.sttProviderUnreachable
        }

        let data: Data
        let response: URLResponse
        do {
            WatchLog.note(.stt, "stt.send", ["provider": provider.id, "bytes": request.audioData.count, "transport": "\(provider.transport)"])
            (data, response) = try await URLSession.shared.upload(for: urlRequest, from: body)
        } catch let error as URLError {
            WatchLog.error(.stt, "stt.transport", ["provider": provider.id, "urlError": error.code.rawValue])
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost:
                throw AppError.noInternetConnection
            case .timedOut:
                throw AppError.requestTimeout
            default:
                throw AppError.sttProviderUnreachable
            }
        } catch {
            throw AppError.sttProviderUnreachable
        }

        guard let http = response as? HTTPURLResponse else {
            throw AppError.invalidResponse
        }

        WatchLog.note(.stt, "stt.http", ["provider": provider.id, "status": http.statusCode, "respBytes": data.count])

        // Per-provider status mapping. nil = 2xx (decode below); non-nil =
        // throw the mapped AppError. Critical 429 differentiation
        // (billing-fatal Mistral/Gemini vs transient OpenAI/ElevenLabs/Qwen)
        // lives in the provider's `statusMap`.
        if let mapped = provider.statusMap.map(http.statusCode, data) {
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
            // Unreachable — no network response for in-process providers.
            // Exhaustiveness arm only.
            throw AppError.sttDecodingFailure
        }
    }
}
