// Conduck
// STTJSONBodyFactory.swift
//
// Static-protocol that per-provider JSON-family providers conform to
// (`GeminiSTT`, `QwenSTT`). Multipart providers do NOT conform —
// `STTProvider.transport` switches the dispatch in `STTClient`.
//
// Named static methods preferred over closures so stack traces show
// `GeminiSTT.buildRequestBody` rather than anonymous closures (closure
// debuggability).

import Foundation

/// JSON-family wire-format conformance. One enum per provider implements
/// these two static methods; `STTProvider.jsonBodyFactory` holds the
/// metatype reference (`GeminiSTT.self`, `QwenSTT.self`).
protocol STTJSONBodyFactory {
    /// Construct the provider-specific JSON request body. Audio is encoded
    /// per provider convention (Gemini: inline base64; Qwen: base64 in
    /// `audio` field of a chat-style message). `model` is the effective
    /// model tag (default or per-provider custom override, already resolved
    /// via `STTProvider.effectiveModel(customModel:)`): Qwen places it in the
    /// request body; Gemini ignores it (its model lives in the URL path, so
    /// the param is accepted only for signature parity).
    static func buildRequestBody(audioData: Data, language: String?, model: String) throws -> Data

    /// Decode the provider-specific JSON response into the uniform
    /// `STTResponse` shape (`text` + optional `language`). Throw
    /// `AppError.sttDecodingFailure` on shape mismatch.
    static func decodeResponse(_ data: Data) throws -> STTResponse
}
