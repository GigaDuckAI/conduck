// Conduck
// STTAuthScheme.swift
//
// Per-provider auth scheme abstraction. Bearer covers Mistral / OpenAI /
// Qwen; headerName covers ElevenLabs (xi-api-key) + Gemini (x-goog-api-key).

import Foundation

/// Per-provider HTTP auth scheme. Applied to outbound `URLRequest` by
/// `STTClient` / Watch network client / probe code paths.
enum STTAuthScheme: Sendable, Equatable {
    /// Standard `Authorization: Bearer <key>` header. Used by Mistral
    /// Voxtral, OpenAI Transcribe, Qwen3-ASR-Flash (DashScope).
    case bearer

    /// Custom header carrying the key as its value. Used by ElevenLabs
    /// (`xi-api-key`) and Gemini (`x-goog-api-key`). Lowercase header names
    /// are vendor-spec-mandated — DO NOT title-case.
    case headerName(String)

    /// No auth header — used by in-process providers (Apple on-device STT)
    /// where authorization is enforced by Apple's TCC
    /// (Speech Recognition entitlement) instead of an HTTP header. The
    /// `apply(to:apiKey:)` call is a no-op for this scheme; callers MAY
    /// pass an empty `apiKey`.
    case none

    /// Apply the auth scheme to a `URLRequest` in place. Never logs / echoes
    /// the key. Caller is responsible for ensuring `apiKey` is non-empty
    /// for schemes that actually consume it (`.bearer`, `.headerName`).
    func apply(to request: inout URLRequest, apiKey: String) {
        switch self {
        case .bearer:
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        case .headerName(let name):
            request.setValue(apiKey, forHTTPHeaderField: name)
        case .none:
            // Intentional no-op — in-process providers never hit the
            // network, so there's no request to authenticate.
            return
        }
    }
}
