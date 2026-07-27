// SPDX-License-Identifier: Apache-2.0

// Conduck
// STTProviderMetadata.swift
//
// Multi-provider STT expansion. UI display registry —
// kept separate from `STTProvider` (which is wire-protocol-only) so the
// Watch target can pull `STTProvider` without dragging UI-only types.
// This file is iOS+macOS only (display layer); Watch's downstream-only
// posture means it never renders the provider catalog.
//
// All 7 providers are registered here (6 frozen + the BYO custom OpenAI-
// compatible endpoint) — display copy is decoupled from wire-protocol
// conformance, which lives on `STTProvider`.

import Foundation

/// Display-layer metadata for an STT provider. `id` matches
/// `STTProvider.id` (and the Keychain account suffix). Console URL +
/// copy strings drive the Settings picker row.
struct STTProviderMetadata: Identifiable, Sendable {
    /// Matches `STTProvider.id`. DO NOT RENAME — see `STTProvider.swift`.
    let id: String

    /// Display name shown in the Settings picker row + onboarding key
    /// step. Keep short (fits a single iPhone row at default Dynamic Type).
    let displayName: String

    /// Provider's console / API-key dashboard URL. Tapping the row's
    /// "Get a key" affordance opens this.
    let consoleURL: URL

    /// Placeholder text for the API-key entry field. Includes the
    /// vendor-specific prefix when available (e.g. `"sk-..."`).
    let keyPlaceholder: LocalizedStringResource

    /// Short language-coverage note (1 line).
    let languageNote: LocalizedStringResource

    /// On-device transport flag — `true` for Apple's `SpeechAnalyzer`-backed
    /// provider, `false` for every network provider. `ProviderRow` branches
    /// on this to swap the SecureField + "Get a key" UX for a "Download
    /// model" lifecycle.
    let isOnDevice: Bool

    /// Explicit memberwise init with a defaulted `isOnDevice` parameter so
    /// the existing 5 cloud-provider registrations (Mistral, OpenAI,
    /// ElevenLabs, Gemini, Qwen) compile unchanged. Apple's registration
    /// passes `isOnDevice: true`. Swift's synthesised memberwise init
    /// would otherwise omit a `let isOnDevice: Bool = false` property
    /// from its parameter list, breaking the Apple call site.
    init(
        id: String,
        displayName: String,
        consoleURL: URL,
        keyPlaceholder: LocalizedStringResource,
        languageNote: LocalizedStringResource,
        isOnDevice: Bool = false
    ) {
        self.id = id
        self.displayName = displayName
        self.consoleURL = consoleURL
        self.keyPlaceholder = keyPlaceholder
        self.languageNote = languageNote
        self.isOnDevice = isOnDevice
    }
}

/// UI-display registry. 7 entries — the 6 frozen providers plus the BYO
/// custom OpenAI-compatible endpoint (`customOpenAI`). Each `id` mirrors an
/// `STTProvider` record (display↔wire ID parity).
enum STTProviderRegistry {
    /// Mistral Voxtral V2 — `voxtral-mini-2602`. EU jurisdiction;
    /// 13 languages; billing-fatal 429.
    // DO NOT RENAME — Keychain account suffixes depend on this string
    static let mistralVoxtral = STTProviderMetadata(
        id: "mistral-voxtral",
        displayName: "Mistral",
        consoleURL: URL(string: "https://console.mistral.ai/api-keys")!,
        keyPlaceholder: LocalizedStringResource(
            "settings.stt.provider.mistralVoxtral.placeholder",
            defaultValue: "Paste your Mistral API key"
        ),
        languageNote: LocalizedStringResource(
            "settings.stt.provider.mistralVoxtral.language",
            defaultValue: "13 languages · diarization + word timestamps"
        )
    )

    /// OpenAI `gpt-4o-transcribe` — broadest language coverage,
    /// transient 429 (rate-limited not billing).
    // DO NOT RENAME — Keychain account suffixes depend on this string
    static let openAI = STTProviderMetadata(
        id: "openai-gpt4o-transcribe",
        displayName: "OpenAI",
        consoleURL: URL(string: "https://platform.openai.com/api-keys")!,
        keyPlaceholder: LocalizedStringResource(
            "settings.stt.provider.openai.placeholder",
            defaultValue: "sk-..."
        ),
        languageNote: LocalizedStringResource(
            "settings.stt.provider.openai.language",
            defaultValue: "99+ languages · highest accuracy on long audio"
        )
    )

    /// ElevenLabs Scribe v2.
    // DO NOT RENAME — Keychain account suffixes depend on this string
    static let elevenLabs = STTProviderMetadata(
        id: "elevenlabs-scribe-v2",
        displayName: "ElevenLabs",
        consoleURL: URL(string: "https://elevenlabs.io/app/settings/api-keys")!,
        keyPlaceholder: LocalizedStringResource(
            "settings.stt.provider.elevenLabs.placeholder",
            defaultValue: "Paste your ElevenLabs API key"
        ),
        languageNote: LocalizedStringResource(
            "settings.stt.provider.elevenLabs.language",
            defaultValue: "99 languages · speaker labels + audio-event tags"
        )
    )

    /// Google Gemini 3.1 Flash-Lite — JSON family, billing-fatal 429,
    /// supports inline-base64 audio.
    // DO NOT RENAME — Keychain account suffixes depend on this string
    static let gemini = STTProviderMetadata(
        id: "gemini-3-1-flash-lite",
        displayName: "Gemini",
        consoleURL: URL(string: "https://aistudio.google.com/apikey")!,
        keyPlaceholder: LocalizedStringResource(
            "settings.stt.provider.gemini.placeholder",
            defaultValue: "Paste your Gemini API key"
        ),
        languageNote: LocalizedStringResource(
            "settings.stt.provider.gemini.language",
            defaultValue: "100+ languages · transcribes via LLM (not pure ASR)"
        )
    )

    /// Alibaba Qwen3-ASR-Flash — JSON family, DashScope-hosted,
    /// Singapore default endpoint.
    // DO NOT RENAME — Keychain account suffixes depend on this string
    static let qwen = STTProviderMetadata(
        id: "qwen3-asr-flash",
        displayName: "Qwen",
        consoleURL: URL(string: "https://dashscope.console.alibabacloud.com/apiKey")!,
        keyPlaceholder: LocalizedStringResource(
            "settings.stt.provider.qwen.placeholder",
            defaultValue: "Paste your DashScope API key"
        ),
        languageNote: LocalizedStringResource(
            "settings.stt.provider.qwen.language",
            defaultValue: "11 languages · strongest on Mandarin / CJK"
        )
    )

    /// OpenRouter hosted voice — one account/key for chat (the hosted-model
    /// gateway) AND voice (STT + TTS). The model is user-overridable (the
    /// catalog grows over time); console URL points at the API-keys dashboard.
    // DO NOT RENAME — Keychain account suffix `stt.apiKey.openrouter-stt`
    // depends on this string.
    static let openRouter = STTProviderMetadata(
        id: "openrouter-stt",
        displayName: "OpenRouter",
        consoleURL: URL(string: "https://openrouter.ai/keys")!,
        keyPlaceholder: LocalizedStringResource(
            "settings.stt.provider.openRouter.placeholder",
            defaultValue: "sk-or-…"
        ),
        languageNote: LocalizedStringResource(
            "settings.stt.provider.openRouter.language",
            defaultValue: "Any compatible model · one key for chat + voice"
        )
    )

    /// Apple on-device Speech (iOS / iPadOS / macOS / CarPlay 26+; NOT on
    /// watchOS — see `STTProvider.appleOnDevice`). Default for fresh installs
    /// — placed FIRST in `all` so the Settings picker surfaces
    /// it as the recommended row. The console URL is informational (no API
    /// key console exists) — points to Apple's published support guide.
    // DO NOT RENAME — Keychain account suffix `stt.apiKey.apple-on-device`
    // depends on this string (even though the slot is never written).
    static let appleOnDevice = STTProviderMetadata(
        id: "apple-on-device",
        displayName: "Apple (On-Device)",
        consoleURL: URL(string: "https://support.apple.com/guide/iphone/use-dictation-iphd5cf94b3a/ios")!,
        keyPlaceholder: LocalizedStringResource(
            "settings.stt.provider.apple.placeholder",
            defaultValue: "No API key required"
        ),
        languageNote: LocalizedStringResource(
            "settings.stt.provider.apple.language.v2",
            defaultValue: "On-device · standard dictation, optional high-quality download"
        ),
        isOnDevice: true
    )

    /// Custom OpenAI-compatible STT endpoint — BYO self-hosted server. The
    /// 7th entry; `id` matches `STTProvider.customOpenAICompat`. Unlike the
    /// other 6 rows, configuration needs a URL + cert + auth scheme (not a
    /// single key), so its Settings row branches to a dedicated config body.
    /// The console URL is informational (no vendor console exists) — points
    /// to the OpenAI audio-transcription API reference the self-hosted
    /// servers emulate.
    // DO NOT RENAME — Keychain account suffix `stt.apiKey.custom-openai`
    // depends on this string.
    static let customOpenAI = STTProviderMetadata(
        id: "custom-openai",
        displayName: "Custom (OpenAI-compatible)",
        consoleURL: URL(string: "https://platform.openai.com/docs/api-reference/audio/createTranscription")!,
        keyPlaceholder: LocalizedStringResource(
            "settings.stt.provider.custom.placeholder",
            defaultValue: "Paste your endpoint's API key (optional for keyless servers)"
        ),
        languageNote: LocalizedStringResource(
            "settings.stt.provider.custom.language",
            defaultValue: "Self-hosted Whisper, faster-whisper, Speaches, LocalAI…"
        )
    )

    /// Full display order (matches Settings picker row order). Apple is FIRST
    /// — recommended default for fresh installs. Count is 7
    /// (the trailing `customOpenAI` BYO endpoint).
    static let all: [STTProviderMetadata] = [
        appleOnDevice,
        mistralVoxtral,
        openAI,
        elevenLabs,
        gemini,
        openRouter,
        // Qwen UNLISTED (pulled from the supported list — see
        // `STTProvider.allRegistered`). The `static let qwen` metadata is kept
        // so re-listing is a one-line revert; the wire/display parity test
        // requires this array to mirror `STTProvider.allRegistered` exactly.
        customOpenAI,
    ]

    /// Look up display metadata by provider ID. Returns nil for unknown
    /// IDs — callers (Settings UI) may render a graceful fallback.
    static func lookup(id: String) -> STTProviderMetadata? {
        all.first(where: { $0.id == id })
    }
}
