// Conduck
// QwenSTTProvider.swift
//
// JSON-family provider for Alibaba's Qwen3-ASR-Flash via DashScope
// international endpoint.
// Contains both:
//   - `QwenSTT`      : `STTJSONBodyFactory` conformance (request + decode)
//   - `QwenSTTProbe` : `STTProbe`           conformance (silent-WAV POST)
//
// Wire shape (verified via DashScope docs — the documented
// `qwen-speech-recognition` page returned this canonical shape; the
// alternate `qwen3-asr-api` URL 404'd at fetch time):
//
//   request : {
//     model: "qwen3-asr-flash",
//     input: {
//       messages: [{
//         role: "user",
//         content: [{ audio: "data:audio/mp4;base64,<base64>" }]
//       }]
//     },
//     parameters: { asr_options: { language: "<lang|auto>", enable_itn: false } }
//   }
//
//   response: {
//     output: {
//       choices: [{
//         message: {
//           content: [{ text: "transcribed audio text here" }]
//         }
//       }]
//     }
//   }
//
// Note: docs show `content` as an **array of objects**, each with a `text`
// field. The decoder concatenates all `text` values from the first
// choice's content array (defensive against future chunking).
//
// Probe rationale (locked): DashScope has no cheap GET surface for key
// validation. We POST a bundled ~1.6 KB silent WAV and inspect ONLY the
// HTTP status (200 vs 401 vs 5xx). Body-ignored bypasses the
// `noSpeechDetected` / `audioInvalid` semantic traps that would otherwise
// false-positive on silence.

import Foundation

// MARK: - JSON body factory

enum QwenSTT: STTJSONBodyFactory {

    /// MIME prefix for the data-URI wrapper that DashScope expects on
    /// inline base64 audio. The pipeline emits AAC-in-MP4.
    private static let audioMIMEPrefix = "audio/mp4"

    static func buildRequestBody(audioData: Data, language: String?, model: String) throws -> Data {
        let base64 = audioData.base64EncodedString()
        let dataURI = "data:\(audioMIMEPrefix);base64,\(base64)"
        let lang = (language?.isEmpty == false) ? language! : "auto"

        let body = QwenRequest(
            // Effective model — the per-provider override (sanitized) when
            // the user typed one, else the pinned default `qwen3-asr-flash`.
            // The probe still validates against `provider.model`, by design.
            model: model,
            input: .init(
                messages: [
                    .init(role: "user", content: [.init(audio: dataURI)])
                ]
            ),
            parameters: .init(
                asrOptions: .init(language: lang, enableItn: false)
            )
        )

        return try JSONEncoder().encode(body)
    }

    static func decodeResponse(_ data: Data) throws -> STTResponse {
        let payload: QwenResponse
        do {
            payload = try JSONDecoder().decode(QwenResponse.self, from: data)
        } catch {
            throw AppError.sttDecodingFailure
        }

        guard let choice = payload.output?.choices?.first,
              let parts = choice.message?.content,
              !parts.isEmpty else {
            throw AppError.sttDecodingFailure
        }

        let joined = parts
            .compactMap { $0.text }
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if joined.isEmpty {
            // Present-but-empty transcript = no usable speech, surfaced
            // uniformly with the other providers (even though Qwen is parked /
            // unregistered, keep its empty path consistent so a future re-list
            // doesn't silently regress to the generic decode-failure message).
            throw AppError.noSpeechDetected
        }

        // DashScope does not echo back a detected language; the `language`
        // hint we sent in `parameters` is not surfaced on the response.
        return STTResponse(text: joined, language: nil)
    }
}

// MARK: - Probe (silent-WAV POST, HTTP-status-only check)

enum QwenSTTProbe: STTProbe {

    /// Name of the bundled silent-WAV asset (100 ms, 8 kHz mono PCM, ~1.6 KB).
    /// MUST be present in the main app bundle. See
    /// `Conduck/Resources/qwen-probe-silent.wav`.
    private static let probeAssetName = "qwen-probe-silent"
    private static let probeAssetExt  = "wav"
    private static let probeAssetMIME = "audio/wav"

    static func validate(apiKey: String, provider: STTProvider) async throws {
        // Load bundled probe asset.
        guard let url = Bundle.main.url(forResource: probeAssetName,
                                        withExtension: probeAssetExt) else {
            // Probe asset missing from bundle — surface as invalidResponse
            // so the founder/QA notices the bundling regression rather
            // than the user seeing a generic auth failure.
            throw AppError.invalidResponse
        }

        let wavData: Data
        do {
            wavData = try Data(contentsOf: url)
        } catch {
            throw AppError.invalidResponse
        }

        let base64 = wavData.base64EncodedString()
        let dataURI = "data:\(probeAssetMIME);base64,\(base64)"

        let body = QwenRequest(
            model: provider.model,
            input: .init(
                messages: [
                    .init(role: "user", content: [.init(audio: dataURI)])
                ]
            ),
            parameters: .init(
                asrOptions: .init(language: "auto", enableItn: false)
            )
        )

        let bodyData: Data
        do {
            bodyData = try JSONEncoder().encode(body)
        } catch {
            throw AppError.invalidResponse
        }

        var request = URLRequest(url: provider.transcribeURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        provider.auth.apply(to: &request, apiKey: apiKey)
        request.httpBody = bodyData

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

        // HTTP status-only check — body intentionally ignored. The probe
        // intent is "key authenticates", not "transcription succeeds".
        switch http.statusCode {
        case 200..<300:
            return
        case 401, 403:
            throw AppError.sttAuthFailed
        case 500..<600:
            throw AppError.sttServerError
        default:
            // 400 / 413 / 429 / etc. on a silent-WAV probe still mean the
            // key reached DashScope and was accepted at the auth layer.
            // Treat as success — the user just learned their key is good.
            return
        }
    }
}

// MARK: - Codable types (fileprivate — not part of public surface)

private struct QwenRequest: Encodable {
    let model: String
    let input: Input
    let parameters: Parameters

    struct Input: Encodable {
        let messages: [Message]
    }

    struct Message: Encodable {
        let role: String
        let content: [ContentItem]
    }

    struct ContentItem: Encodable {
        let audio: String
    }

    struct Parameters: Encodable {
        let asrOptions: AsrOptions

        enum CodingKeys: String, CodingKey {
            case asrOptions = "asr_options"
        }
    }

    struct AsrOptions: Encodable {
        let language: String
        let enableItn: Bool

        enum CodingKeys: String, CodingKey {
            case language
            case enableItn = "enable_itn"
        }
    }
}

private struct QwenResponse: Decodable {
    let output: Output?

    struct Output: Decodable {
        let choices: [Choice]?
    }

    struct Choice: Decodable {
        let message: Message?
    }

    struct Message: Decodable {
        let content: [ContentItem]?
    }

    struct ContentItem: Decodable {
        let text: String?
    }
}
