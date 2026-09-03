// SPDX-License-Identifier: Apache-2.0

// Conduck
// STTAuthScheme.swift
//
// Per-provider auth scheme abstraction. Bearer covers Mistral / OpenAI /
// Qwen; headerName covers ElevenLabs (xi-api-key) + Gemini (x-goog-api-key).
//
// THE SINGLE HEADER SITE for voice: every STT / TTS request builder on every
// surface routes through `apply(to:apiKey:)`, so it is also where OpenRouter's
// app-attribution headers are stamped (`OpenRouterAttribution`). They ride here
// rather than in each builder because OpenRouter creates the app's public page
// and its rankings entry ONLY from those headers — a builder that forgot them
// would silently un-attribute its whole lane. Attribution is HOST-GATED and
// independent of the scheme: it is a property of the DESTINATION, so the
// OpenRouter voice endpoints carry it while the user's own custom endpoint,
// ElevenLabs and Gemini never do.

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
    /// `apply(to:apiKey:)` call writes no AUTH header for this scheme (the
    /// host-gated attribution stamp below still runs); callers MAY pass an
    /// empty `apiKey`.
    case none

    /// Apply the auth scheme to a `URLRequest` in place. Never logs / echoes
    /// the key. Caller is responsible for ensuring `apiKey` is non-empty
    /// for schemes that actually consume it (`.bearer`, `.headerName`).
    ///
    /// Then stamps OpenRouter's app-attribution headers, which are applied for
    /// EVERY case including `.none` — attribution follows the destination host,
    /// not the auth scheme. `OpenRouterAttribution` is itself host-gated, so
    /// this call is a no-op for every other vendor.
    func apply(to request: inout URLRequest, apiKey: String) {
        switch self {
        case .bearer:
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        case .headerName(let name):
            request.setValue(apiKey, forHTTPHeaderField: name)
        case .none:
            // Intentional no-op — in-process providers never hit the
            // network, so there's no request to authenticate.
            break
        }

        OpenRouterAttribution.apply(to: &request)
    }
}
