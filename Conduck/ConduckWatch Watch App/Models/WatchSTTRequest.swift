// SPDX-License-Identifier: Apache-2.0

//
//  WatchSTTRequest.swift
//  ConduckWatch Watch App
//
//  Provider-aware STT request payload for the watchOS surface.
//  A provider-driven shape that delegates wire-format details to the shared
//  `STTMultipartBuilder` (for multipart-family providers).
//
//  Multipart-family providers (Mistral Voxtral V2, OpenAI gpt-4o-transcribe,
//  ElevenLabs Scribe v2) use `buildMultipartData` / `writeToFile`. JSON-
//  family providers (Gemini, Qwen3-ASR-Flash) do NOT go
//  through this type's body methods — `WatchNetworkClient` / `WatchAudioUploader`
//  call into `provider.jsonBodyFactory!` directly. This struct still carries
//  the audio + language + provider record across the two paths.
//

import Foundation

struct WatchSTTRequest {
    let audioData: Data
    let audioFormat: AudioFormat
    /// Optional ISO 639-1 language hint (e.g., `"en"`, `"de"`). When nil,
    /// the provider auto-detects from the audio.
    let language: String?

    /// Active STT provider. Drives wire format, endpoint, auth, and field
    /// names. Resolved by the caller (`WatchRecordingService`) from
    /// `WatchSettingsReader.shared.activePresetID`.
    let provider: STTProvider

    /// Optional per-preset custom model override (Feature 1 — Custom STT).
    /// Mirrors the iPhone broadcast (`STTBroadcastEnvelope.customModel`),
    /// surfaced Watch-ward via `WatchSettingsReader.activeCustomModel`. Nil =
    /// the provider's pinned default model. Trimmed/resolved through
    /// `provider.effectiveModel(customModel:)` below.
    let customModel: String?

    /// Wire-level model tag for the active provider, honoring a per-preset
    /// custom override when present (Feature 1). For the multipart family this
    /// drives the `model` form field; for the JSON family (Gemini, Qwen) it
    /// drives the body's model tag. No provider carries it in the URL any more.
    var model: String { provider.effectiveModel(customModel: customModel) }

    /// Explicit memberwise init with `customModel` defaulting to nil — keeps the
    /// field additive so any pre-Custom-STT construction (audio/format/language/
    /// provider) compiles unchanged. The live recording path threads the real
    /// override from `WatchSettingsReader.shared.activeCustomModel`.
    init(audioData: Data, audioFormat: AudioFormat, language: String?, provider: STTProvider, customModel: String? = nil) {
        self.audioData = audioData
        self.audioFormat = audioFormat
        self.language = language
        self.provider = provider
        self.customModel = customModel
    }

    /// Builds the complete multipart/form-data body in memory.
    /// Used by the foreground client (`WatchNetworkClient.uploadSTT`).
    /// Only valid for `provider.transport == .multipart`.
    ///
    /// Body assembly delegates to `STTMultipartBuilder`
    /// (which honors the caller-supplied boundary so the Content-Type header
    /// matches). No inline `Content-Disposition` strings remain in this file.
    func buildMultipartData(boundary: String) -> Data {
        let filename = "audio.\(audioFormat.fileExtension)"
        let fieldNames = provider.multipartFieldNames ?? .openAICompat
        let (_, body) = STTMultipartBuilder.build(
            audioData: audioData,
            audioMIME: audioFormat.mimeType,
            audioFilename: filename,
            model: model,
            language: language,
            fieldNames: fieldNames,
            boundary: boundary
        )
        return body
    }

    /// Writes the multipart body to a temporary file.
    /// Required for background URLSession `uploadTask(with:fromFile:)`.
    /// Caller owns cleanup of the returned URL (the background uploader
    /// tracks it in `multipartTempFiles` and removes it in the
    /// `didCompleteWithError` delegate).
    /// Only valid for `provider.transport == .multipart`.
    ///
    /// File assembly delegates to `STTMultipartBuilder
    /// .writeBodyFile` for the on-disk path. Audio is read fresh from a
    /// temporary input file rather than retained in memory (matches the
    /// background-URLSession RAM-pressure invariant on watchOS).
    func writeToFile(boundary: String) throws -> URL {
        // STTMultipartBuilder.writeBodyFile streams audio from a URL — write
        // our in-memory audioData out first so we can hand it a URL.
        let audioInputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("watch-stt-audio-\(UUID().uuidString)")
            .appendingPathExtension(audioFormat.fileExtension)
        try audioData.write(to: audioInputURL)
        defer { try? FileManager.default.removeItem(at: audioInputURL) }

        let fieldNames = provider.multipartFieldNames ?? .openAICompat
        let filename = "audio.\(audioFormat.fileExtension)"
        let (_, bodyFileURL) = try STTMultipartBuilder.writeBodyFile(
            audioFileURL: audioInputURL,
            audioMIME: audioFormat.mimeType,
            audioFilename: filename,
            model: model,
            language: language,
            fieldNames: fieldNames,
            boundary: boundary
        )
        return bodyFileURL
    }
}
