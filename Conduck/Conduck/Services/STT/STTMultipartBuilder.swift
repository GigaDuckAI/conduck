// Conduck
// STTMultipartBuilder.swift
//
// Shared multipart body construction for OpenAI-compatible (`file` /
// `model` / `language`) and ElevenLabs (`file` / `model_id` /
// `language_code`) STT endpoints.
//
// Mirrors `STTClient.swift` L297-331 logic but parameterizes field names
// via `STTMultipartFieldNames`. Two construction modes:
//   - `build(...)`  → in-memory `Data` body (foreground / small bodies)
//   - `writeBodyFile(...)` → on-disk body file (background URLSession path
//     for the Watch surface; caller owns cleanup of the returned URL).

import Foundation

/// Per-provider multipart field-name set. The wire shape is identical
/// across OpenAI/Mistral and ElevenLabs (one binary `file` part + two
/// text parts), only the form-field names differ.
struct STTMultipartFieldNames: Sendable, Equatable {
    /// Form-field name carrying the binary audio. All 3 providers use
    /// `"file"` — kept parameterized for future provider drift.
    let file: String

    /// Form-field name carrying the model tag. OpenAI/Mistral: `"model"`;
    /// ElevenLabs: `"model_id"`.
    let model: String

    /// Form-field name carrying the optional language hint. OpenAI/Mistral:
    /// `"language"` (ISO 639-1); ElevenLabs: `"language_code"`.
    let language: String

    /// OpenAI-compatible field set. Used by Mistral Voxtral V2 + OpenAI
    /// `gpt-4o-transcribe`.
    static let openAICompat = STTMultipartFieldNames(
        file: "file",
        model: "model",
        language: "language"
    )

    /// ElevenLabs Scribe v2 field set.
    static let elevenLabs = STTMultipartFieldNames(
        file: "file",
        model: "model_id",
        language: "language_code"
    )
}

/// Shared multipart body construction. Replaces the per-call-site copies
/// in `STTClient.buildMultipartBody` + `WatchSTTRequest.buildMultipartData`.
enum STTMultipartBuilder {
    /// Build an in-memory multipart body. Returns the generated boundary
    /// string and the assembled `Data` payload. Caller sets the
    /// `Content-Type: multipart/form-data; boundary=<boundary>` header
    /// using the returned boundary value.
    ///
    /// - Parameters:
    ///   - audioData: raw audio bytes (typically M4A AAC).
    ///   - audioMIME: MIME type for the audio part (`audio/mp4`, etc.).
    ///   - audioFilename: filename hint for the audio part (`audio.m4a`).
    ///   - model: provider-specific model tag (e.g. `voxtral-mini-2602`).
    ///   - language: optional ISO 639-1 hint; omitted entirely if nil/empty.
    ///   - fieldNames: per-provider form-field names.
    /// - Returns: `(boundary, body)` — caller propagates boundary to the
    ///   request's Content-Type header and assigns body to `httpBody`.
    static func build(
        audioData: Data,
        audioMIME: String,
        audioFilename: String,
        model: String,
        language: String?,
        fieldNames: STTMultipartFieldNames,
        boundary: String? = nil
    ) -> (boundary: String, body: Data) {
        // Caller-supplied boundary honored so the Content-Type header can be
        // constructed before this call (used by `WatchSTTRequest`). When
        // nil, generate one per the usual contract.
        let boundary = boundary ?? "----Conduck-\(UUID().uuidString)"
        var body = Data()

        func append(_ string: String) {
            if let data = string.data(using: .utf8) {
                body.append(data)
            }
        }

        // file (binary)
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"\(fieldNames.file)\"; filename=\"\(audioFilename)\"\r\n")
        append("Content-Type: \(audioMIME)\r\n\r\n")
        body.append(audioData)
        append("\r\n")

        // model
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"\(fieldNames.model)\"\r\n\r\n")
        append("\(model)\r\n")

        // language (optional)
        if let language = language, !language.isEmpty {
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"\(fieldNames.language)\"\r\n\r\n")
            append("\(language)\r\n")
        }

        append("--\(boundary)--\r\n")
        return (boundary, body)
    }

    /// Build the multipart body on-disk for use with background URLSession
    /// uploads (Watch surface — keeps RAM pressure flat). Writes to a
    /// unique file in `FileManager.default.temporaryDirectory`. **Caller
    /// owns cleanup** of the returned `bodyFileURL` (typically via
    /// `defer { try? FileManager.default.removeItem(at: bodyFileURL) }`
    /// after the upload task completes — see background delegate handler).
    ///
    /// Audio is streamed in via `audioFileURL` (read fresh each call) so
    /// the caller does not need to load the audio into memory.
    static func writeBodyFile(
        audioFileURL: URL,
        audioMIME: String,
        audioFilename: String,
        model: String,
        language: String?,
        fieldNames: STTMultipartFieldNames,
        boundary: String? = nil
    ) throws -> (boundary: String, bodyFileURL: URL) {
        let boundary = boundary ?? "----Conduck-\(UUID().uuidString)"
        let bodyFileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("stt-body-\(UUID().uuidString).bin")

        // Create empty file we can append to.
        FileManager.default.createFile(atPath: bodyFileURL.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: bodyFileURL) else {
            throw AppError.audioMissingData
        }
        defer { try? handle.close() }

        func write(_ string: String) throws {
            guard let data = string.data(using: .utf8) else { return }
            try handle.write(contentsOf: data)
        }

        let audioData = try Data(contentsOf: audioFileURL)

        try write("--\(boundary)\r\n")
        try write("Content-Disposition: form-data; name=\"\(fieldNames.file)\"; filename=\"\(audioFilename)\"\r\n")
        try write("Content-Type: \(audioMIME)\r\n\r\n")
        try handle.write(contentsOf: audioData)
        try write("\r\n")

        try write("--\(boundary)\r\n")
        try write("Content-Disposition: form-data; name=\"\(fieldNames.model)\"\r\n\r\n")
        try write("\(model)\r\n")

        if let language = language, !language.isEmpty {
            try write("--\(boundary)\r\n")
            try write("Content-Disposition: form-data; name=\"\(fieldNames.language)\"\r\n\r\n")
            try write("\(language)\r\n")
        }

        try write("--\(boundary)--\r\n")

        return (boundary, bodyFileURL)
    }
}
