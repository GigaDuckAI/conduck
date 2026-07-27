// SPDX-License-Identifier: Apache-2.0

// Conduck
// STTProvider.swift
//
// Multi-provider STT expansion. Value-type registry of
// supported STT providers. Each provider is a `static let` instance of
// `STTProvider`; `STTClient` dispatches by `transport` (multipart vs JSON)
// and calls into the per-provider modules (`STTMultipartBuilder` +
// `STTResponseDecoder` for multipart; `jsonBodyFactory` for JSON).
//
// The registry holds the 3 multipart-family providers (Voxtral V2, OpenAI
// gpt-4o-transcribe, ElevenLabs Scribe v2), the 2 JSON-family providers
// (Gemini 3.1 Flash-Lite, Qwen3-ASR-Flash), Apple on-device (`.inProcess`),
// and `customOpenAICompat` (BYO OpenAI-compatible endpoint, `dynamicEndpointKey`
// resolution) — see the marked comments in `allRegistered` below.
//
// LOCKED — all 7 provider IDs are user-visible-equivalent (drive Keychain
// account suffixes, KVS preset ID). Renaming orphans existing slots.

import Foundation

/// A speech-to-text provider's wire-level contract. Value type — held as
/// `static let` instances on this type, never instantiated by callers.
struct STTProvider: Sendable {
    enum Transport: Sendable, Equatable {
        case multipart
        case json
        /// In-process — no network. Apple on-device via `SpeechAnalyzer`
        /// is the first `.inProcess` conformance. Dispatch
        /// in `STTClient.transcribe` routes `.inProcess` providers to
        /// `provider.inProcessRunner!.transcribe(...)`, bypassing the
        /// multipart/JSON build + retry loop entirely.
        case inProcess
    }

    /// Stable provider identifier. **DO NOT RENAME** — drives the
    /// Keychain account suffix (`stt.apiKey.<id>`) and the KVS active-
    /// preset value. See `Constants.sttApiKeyKeychainAccount(for:)`.
    let id: String

    /// Transcription endpoint (POST target).
    let transcribeURL: URL

    /// Optional key-validation probe target (GET). `STTGETProbe` reads
    /// this; providers with a bespoke probe (Qwen via `QwenSTTProbe`)
    /// set this to nil and provide their own `probe:` value.
    let probeURL: URL?

    /// Wire-level model tag (e.g. `voxtral-mini-2602`,
    /// `gpt-4o-transcribe`, `scribe_v2`).
    let model: String

    /// How to attach the API key to outbound requests.
    let auth: STTAuthScheme

    /// Wire-format dispatch — multipart or JSON.
    let transport: Transport

    /// Per-provider audio size cap (bytes). The multipart-family providers
    /// share `Constants.maxAudioSize` (15 MB); JSON providers may differ (Qwen).
    let maxAudioBytes: Int

    /// Per-provider audio duration cap (seconds). The multipart-family
    /// providers share `Constants.maxAudioDuration` (300s / 5 min); JSON
    /// providers may differ for Qwen (hard 5-min API cap).
    let maxAudioSeconds: TimeInterval

    // MARK: Multipart family (nil for JSON providers)

    let multipartFieldNames: STTMultipartFieldNames?
    let responseShape: STTResponseShape?

    // MARK: JSON family (nil for multipart providers)

    /// JSON-family per-provider body builder + response decoder. Named
    /// static methods preserve stack-trace clarity vs closures. Nil for
    /// multipart providers.
    let jsonBodyFactory: STTJSONBodyFactory.Type?

    // MARK: Common

    /// Auth-validation probe. Default `STTGETProbe` (4 of 5 providers);
    /// Qwen uses `QwenSTTProbe`.
    let probe: STTProbe.Type

    /// HTTP-status → AppError mapping. Critical 429 differentiation
    /// (billing-fatal vs transient) is encoded here per provider.
    let statusMap: STTStatusMap

    // MARK: In-process family (nil for network providers)

    /// In-process runner metatype for `.inProcess` transports. Network
    /// providers (multipart / JSON) pass nil. Declared without a
    /// stored-property default because Swift's synthesised memberwise
    /// init omits `let` properties initialised in their declaration —
    /// the resulting init would not accept the parameter at the
    /// `appleOnDevice` call site. All 5 cloud registrations therefore
    /// pass `inProcessRunner: nil` explicitly. The `appleOnDevice`
    /// registration sets this to `AppleSpeechRunner.self`.
    let inProcessRunner: STTInProcessRunner.Type?

    // MARK: Dynamic-endpoint family (nil for all frozen providers)

    /// App-Group/KVS storage key holding the user-supplied BASE URL for a
    /// provider whose endpoint is NOT a compile-time constant. Nil for the
    /// 6 frozen providers (their `transcribeURL` is the real, fixed target);
    /// `"stt.custom.url"` for `customOpenAICompat`, whose `transcribeURL` is
    /// only a sentinel. **Declarative dispatch** — every request-build site
    /// branches on `dynamicEndpointKey != nil` rather than scattering
    /// `if id == "custom-openai"` checks, and the actual transcribe URL is
    /// resolved through `SettingsManager.customSTTTranscribeURL()`. Declared
    /// without a stored-property default (same memberwise-init rationale as
    /// `inProcessRunner` above) so all 6 frozen registrations pass
    /// `dynamicEndpointKey: nil` explicitly.
    let dynamicEndpointKey: String?

    // MARK: - Endpoint helpers

    /// Build the Gemini `generateContent` endpoint for a given model tag.
    /// Single source of truth used BOTH by the `geminiFlashLite` registry
    /// definition and by `effectiveTranscribeURL(customModel:)`, so the
    /// pinned-default URL and a user model override can never drift in path
    /// shape. Gemini is the one provider whose model lives in the URL path,
    /// not the request body.
    static func geminiEndpoint(model: String) -> URL {
        URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent")!
    }

    /// Resolve the effective model tag for a transcription. Returns the
    /// trimmed non-empty `customModel` override when present, else the
    /// pinned default `model`. `.inProcess` providers (Apple on-device)
    /// ALWAYS return `model` unchanged — there is no network model to
    /// override, and the sentinel `model` ("speechanalyzer") is never sent.
    func effectiveModel(customModel: String?) -> String {
        guard transport != .inProcess else { return model }
        if let override = customModel?.trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty {
            return override
        }
        return model
    }

    /// Resolve the effective transcribe URL for a transcription. Only the
    /// Gemini provider's model lives in the URL path, so a model override
    /// must rebuild the endpoint there; every other provider (including
    /// `customOpenAICompat`, whose dynamic base URL is resolved upstream via
    /// `SettingsManager.customSTTTranscribeURL()` — NOT here) returns
    /// `transcribeURL` unchanged. Pair with `effectiveModel(customModel:)`
    /// for the body/field model tag.
    func effectiveTranscribeURL(customModel: String?) -> URL {
        guard id == STTProvider.geminiFlashLite.id else { return transcribeURL }
        if let override = customModel?.trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty {
            return STTProvider.geminiEndpoint(model: override)
        }
        return transcribeURL
    }

    /// Whether this provider's model lives in the URL PATH (Gemini's
    /// `…/models/<model>:generateContent`) rather than the request body. Drives
    /// model-override sanitization (`SettingsViewModel.sanitizeModelTag`): a
    /// URL-path model MUST strip `/` (path-injection guard), while a body model
    /// (OpenRouter, the OpenAI/Mistral multipart family, Qwen, custom endpoints)
    /// may KEEP `/` — OpenRouter model IDs like `openai/whisper-large-v3`
    /// REQUIRE the slash. Gemini is the only model-in-URL STT provider today.
    var modelInURL: Bool { id == STTProvider.geminiFlashLite.id }

    // MARK: - Registered providers

    /// Mistral Voxtral V2 — `voxtral-mini-2602` (released 2026-02-04,
    /// drop-in upgrade from 2507: +5 languages → 13 total, +diarization,
    /// +word timestamps, +context biasing). Same multipart endpoint.
    /// LOCKED ID — preserves V1's existing Keychain slot.
    // DO NOT RENAME — Keychain account suffixes depend on this string
    static let mistralVoxtral = STTProvider(
        id: "mistral-voxtral",
        transcribeURL: URL(string: "https://api.mistral.ai/v1/audio/transcriptions")!,
        probeURL: URL(string: "https://api.mistral.ai/v1/models"),
        model: "voxtral-mini-2602",
        auth: .bearer,
        transport: .multipart,
        maxAudioBytes: 15 * 1024 * 1024,
        maxAudioSeconds: 300,
        multipartFieldNames: .openAICompat,
        responseShape: .openAICompat,
        jsonBodyFactory: nil,
        probe: STTGETProbe.self,
        statusMap: .mistral,
        inProcessRunner: nil,
        dynamicEndpointKey: nil
    )

    /// OpenAI `gpt-4o-transcribe` — OpenAI-compatible multipart endpoint.
    // DO NOT RENAME — Keychain account suffixes depend on this string
    static let openAITranscribe = STTProvider(
        id: "openai-gpt4o-transcribe",
        transcribeURL: URL(string: "https://api.openai.com/v1/audio/transcriptions")!,
        probeURL: URL(string: "https://api.openai.com/v1/models"),
        model: "gpt-4o-transcribe",
        auth: .bearer,
        transport: .multipart,
        maxAudioBytes: 15 * 1024 * 1024,
        maxAudioSeconds: 300,
        multipartFieldNames: .openAICompat,
        responseShape: .openAICompat,
        jsonBodyFactory: nil,
        probe: STTGETProbe.self,
        statusMap: .openAICompat,
        inProcessRunner: nil,
        dynamicEndpointKey: nil
    )

    /// ElevenLabs Scribe v2 — `model_id` / `language_code` field names,
    /// `xi-api-key` header auth, returns `text` + `language_code` +
    /// `words[]` (words array ignored — text is pre-filtered).
    /// Bespoke probe (`ElevenLabsSTTProbe`): GET probes against `/v1/user`
    /// and `/v1/models` both require permissions (`user_read`, `models_read`)
    /// that narrow-scoped STT-only keys lack. Probe POSTs the bundled silent
    /// WAV to the transcribe endpoint instead — same scope (`speech_to_text`)
    /// the user is already required to grant.
    // DO NOT RENAME — Keychain account suffixes depend on this string
    static let elevenLabsScribe = STTProvider(
        id: "elevenlabs-scribe-v2",
        transcribeURL: URL(string: "https://api.elevenlabs.io/v1/speech-to-text")!,
        probeURL: nil,
        model: "scribe_v2",
        auth: .headerName("xi-api-key"),
        transport: .multipart,
        maxAudioBytes: 15 * 1024 * 1024,
        maxAudioSeconds: 300,
        multipartFieldNames: .elevenLabs,
        responseShape: .elevenLabs,
        jsonBodyFactory: nil,
        probe: ElevenLabsSTTProbe.self,
        statusMap: .elevenLabsScribe,
        inProcessRunner: nil,
        dynamicEndpointKey: nil
    )

    /// Google Gemini 3.1 Flash-Lite — JSON `generateContent` endpoint, base64
    /// inline audio, defensive verbatim-transcription prompt. Per-provider
    /// body factory in `Providers/GeminiSTTProvider.swift`.
    // DO NOT RENAME — Keychain account suffixes depend on this string
    static let geminiFlashLite = STTProvider(
        id: "gemini-3-1-flash-lite",
        transcribeURL: STTProvider.geminiEndpoint(model: "gemini-3.1-flash-lite"),
        probeURL: URL(string: "https://generativelanguage.googleapis.com/v1beta/models"),
        model: "gemini-3.1-flash-lite",
        auth: .headerName("x-goog-api-key"),
        transport: .json,
        // 20 MB JSON cap on the generativelanguage endpoint. Binary capped
        // at 14 MB so base64 (~19 MB) plus the JSON envelope (prompt + part
        // wrappers) stays comfortably under the request limit — a 15 MB
        // binary would leave zero headroom for the envelope.
        maxAudioBytes: 14 * 1024 * 1024,
        maxAudioSeconds: 300,
        multipartFieldNames: nil,
        responseShape: nil,
        jsonBodyFactory: GeminiSTT.self,
        probe: STTGETProbe.self,
        statusMap: .gemini,
        inProcessRunner: nil,
        dynamicEndpointKey: nil
    )

    /// Alibaba Qwen3-ASR-Flash via DashScope international. Bespoke
    /// silent-WAV probe (`QwenSTTProbe`) — DashScope has no cheap GET
    /// surface for key validation. Per-provider body factory + probe in
    /// `Providers/QwenSTTProvider.swift`.
    // DO NOT RENAME — Keychain account suffixes depend on this string
    static let qwenASRFlash = STTProvider(
        id: "qwen3-asr-flash",
        transcribeURL: URL(string: "https://dashscope-intl.aliyuncs.com/api/v1/services/aigc/multimodal-generation/generation")!,
        // No GET probe — `QwenSTTProbe` POSTs the bundled silent-WAV asset.
        probeURL: nil,
        model: "qwen3-asr-flash",
        auth: .bearer,
        transport: .json,
        // DashScope hard cap is 10 MB (smaller than the 15 MB shared by
        // the other 4 providers). Pre-flight gate in `STTClient` enforces.
        maxAudioBytes: 10 * 1024 * 1024,
        maxAudioSeconds: 300,
        multipartFieldNames: nil,
        responseShape: nil,
        jsonBodyFactory: QwenSTT.self,
        probe: QwenSTTProbe.self,
        statusMap: .qwen,
        inProcessRunner: nil,
        dynamicEndpointKey: nil
    )

    /// OpenRouter hosted transcription — `POST /api/v1/audio/transcriptions`
    /// (shipped 2026-05-01). JSON-family: base64 audio in `input_audio.data`
    /// with a sniffed `format`, `model` in the body (`OpenRouterSTT`). Same base
    /// URL + Bearer key the OpenRouter hosted-model GATEWAY uses, so a user who
    /// already pays OpenRouter for chat can use one account for voice too (the
    /// key may be cross-reused between the two — see SettingsViewModel). Default
    /// model `openai/whisper-large-v3` (undated, OpenRouter's own example);
    /// user-overridable (slash-bearing IDs preserved, see `modelInURL`).
    /// Key-validation probe is `GET /v1/key` (OpenRouter's `/v1/models` is PUBLIC
    /// — same reason the gateway probes `/v1/key`). 14 MB binary cap so base64
    /// (~19 MB) plus the JSON envelope stays under request limits (mirrors
    /// Gemini). 402 (out of credits) + 400/404 (bad model) handled by
    /// `.openRouter` status map.
    // DO NOT RENAME — Keychain account suffix `stt.apiKey.openrouter-stt` depends
    // on this string.
    static let openRouter = STTProvider(
        id: "openrouter-stt",
        transcribeURL: URL(string: Constants.openRouterBaseURLString + Constants.openRouterTranscriptionsPath)!,
        probeURL: URL(string: Constants.openRouterBaseURLString + Constants.openRouterKeyProbePath),
        model: "openai/whisper-large-v3",
        auth: .bearer,
        transport: .json,
        maxAudioBytes: 14 * 1024 * 1024,
        maxAudioSeconds: 300,
        multipartFieldNames: nil,
        responseShape: nil,
        jsonBodyFactory: OpenRouterSTT.self,
        probe: STTGETProbe.self,
        statusMap: .openRouter,
        inProcessRunner: nil,
        dynamicEndpointKey: nil
    )

    /// Apple on-device speech recognition via `SpeechAnalyzer` +
    /// `SpeechTranscriber` (iOS / iPadOS / macOS / CarPlay 26+; NOT
    /// available on watchOS — Watch surfaces relay audio to iPhone).
    /// `inProcessRunner` is wired to `AppleSpeechRunner.self`. URL
    /// fields are sentinels (`x-apple-on-device://transcribe`) and are
    /// never accessed for `.inProcess` transports.
    ///
    /// `maxAudioBytes = .max` / `maxAudioSeconds = .infinity` document
    /// "no per-provider HTTP cap" — on-device transcription is bound
    /// only by `AVAudioFile` memory + Apple Speech's own internal limits,
    /// not by a vendor's request ceiling. **Sentinels must be the LARGEST
    /// permissible values**, NOT zero — `STTClient.transcribe` runs
    /// `audioData.count <= maxAudioBytes` BEFORE the transport switch,
    /// and `0` would inversely trip every non-empty recording with
    /// `audioTooLarge`, shadowing the `.inProcess` arm entirely.
    /// `.max` keeps the pre-flight guard a true no-op for Apple.
    // DO NOT RENAME — Keychain account suffixes depend on this string
    static let appleOnDevice = STTProvider(
        id: "apple-on-device",
        transcribeURL: URL(string: "x-apple-on-device://transcribe")!,
        probeURL: nil,
        model: "speechanalyzer",
        auth: .none,
        transport: .inProcess,
        maxAudioBytes: .max,
        maxAudioSeconds: .infinity,
        multipartFieldNames: nil,
        responseShape: nil,
        jsonBodyFactory: nil,
        probe: NoOpSTTProbe.self,
        statusMap: .never,
        // Wired to `AppleSpeechRunner.self`. The runner
        // file is excluded from the Watch target via pbxproj
        // membership exceptions; the metatype reference here compiles
        // on Watch only because `STTInProcessRunner.Type?` resolves
        // structurally (no Speech-framework symbol leak).
        //
        // Watch never reaches this branch at runtime — Watch ships
        // its own audio-relay coordinator that
        // forwards audio to iPhone for transcription. If a Watch
        // build ever DOES reach this dispatch site, `STTClient`'s
        // `.inProcess` arm throws a clear error rather than
        // attempting to load a runner that isn't compiled in.
        // Swift does NOT permit `#if` directives mid-argument-list in
        // an init/func call — the parser sees the directive as a stray
        // token and bails. Wrap the platform fork in an immediately-
        // invoked closure that evaluates to the right metatype on each
        // platform, keeping the call site syntactically valid.
        inProcessRunner: {
            #if os(watchOS)
            return nil
            #else
            return AppleSpeechRunner.self
            #endif
        }(),
        dynamicEndpointKey: nil
    )

    /// Custom OpenAI-compatible STT endpoint (BYO base URL + key). The 7th
    /// registered provider — id `"custom-openai"` is LOCKED (drives the
    /// Keychain account suffix `stt.apiKey.custom-openai`). Unlike the 6
    /// frozen providers, its `transcribeURL` is a SENTINEL
    /// (`x-conduck-custom://transcribe`) never hit directly: the real target
    /// is the user's stored base URL with `/v1/audio/transcriptions`
    /// appended, resolved at request time via
    /// `SettingsManager.customSTTTranscribeURL()` and dispatched off
    /// `dynamicEndpointKey != nil`. Wire shape mirrors OpenAI
    /// `gpt-4o-transcribe` (multipart `file`/`model`/`language`,
    /// `.openAICompat` response + status). Default `model` `"whisper-1"`
    /// (the de-facto self-hosted Whisper tag) is overridable via the
    /// custom-endpoint config. Default `auth` `.bearer`; the effective
    /// scheme (`.bearer` / `.none` for keyless local servers) is resolved
    /// from the snapshot's `CustomSTTConfig`, not this immutable struct.
    /// Caps match OpenAI (25 MB / 300 s).
    // DO NOT RENAME — Keychain account suffix `stt.apiKey.custom-openai`
    // depends on this string.
    static let customOpenAICompat = STTProvider(
        id: "custom-openai",
        transcribeURL: URL(string: "x-conduck-custom://transcribe")!,
        probeURL: nil,
        model: "whisper-1",
        auth: .bearer,
        transport: .multipart,
        maxAudioBytes: 25 * 1024 * 1024,
        maxAudioSeconds: 300,
        multipartFieldNames: .openAICompat,
        responseShape: .openAICompat,
        jsonBodyFactory: nil,
        // `CustomOpenAISTTProbe` is iOS/macOS-only — it resolves the user's
        // endpoint via `SettingsManager`, which is not a Watch-target member.
        // The Watch never probes the custom endpoint (it relays audio to the
        // iPhone), so substitute the no-op probe there. Mirrors the
        // `AppleSpeechRunner` `#if os(watchOS)` gate above. Swift forbids `#if`
        // mid-argument-list, hence the immediately-invoked closure.
        probe: {
            #if os(watchOS)
            return NoOpSTTProbe.self
            #else
            return CustomOpenAISTTProbe.self
            #endif
        }(),
        statusMap: .openAICompat,
        inProcessRunner: nil,
        dynamicEndpointKey: "stt.custom.url"
    )

    /// All providers known at registration time. Order is UI-display
    /// order in Settings picker.
    static let allRegistered: [STTProvider] = [
        .mistralVoxtral,
        .openAITranscribe,
        .elevenLabsScribe,
        .geminiFlashLite,
        .openRouter,
        // Qwen (`.qwenASRFlash`) deliberately UNLISTED — pulled from the
        // user-facing supported list pending a live wire-shape verification
        // (DashScope round-trip never exercised; only a status-only probe).
        // The `static let qwenASRFlash` definition + `QwenSTT`/`QwenSTTProbe`
        // + `STTStatusMap.qwen` are kept intact so re-listing is a one-line
        // revert here (and in `STTProviderMetadata.all` + `VoiceVendor.all`).
        .appleOnDevice,
        .customOpenAICompat,
    ]

    // MARK: - Multiple named custom endpoints (Phase B)
    //
    // The single `custom-openai` provider above is the LEGACY (migration-read)
    // singleton. Phase B mints one synthesized provider per user-named
    // `CustomVoiceEndpoint`, identified by `custom-openai_<uuid>`. The base
    // prefix `custom-openai` is preserved so every "is this a BYO endpoint?"
    // filter (onboarding, CarPlay) that checks `hasPrefix("custom-openai")`
    // keeps matching. Synthesized providers are produced on demand by
    // `lookup(id:)` — `allRegistered` stays length-frozen (7-provider invariant).

    /// Per-instance preset-ID prefix for a named custom STT endpoint:
    /// `custom-openai_<uuid-lowercased>`. The trailing `_` is what makes this
    /// DISJOINT from the TTS prefix `custom-openai-tts_` (char after the base is
    /// `-` for TTS, `_` for STT) and from the bare legacy `custom-openai`.
    /// LOCKED — drives the Keychain account suffix `stt.apiKey.custom-openai_<uuid>`.
    static let customPresetPrefix = "custom-openai_"

    /// Build the per-endpoint STT preset id for a given endpoint uuid.
    static func customEndpointID(for uuid: UUID) -> String {
        customPresetPrefix + uuid.uuidString.lowercased()
    }

    /// Inverse of `customEndpointID(for:)`. Returns the endpoint uuid iff `id`
    /// is a per-endpoint custom STT preset id. REJECTS the bare legacy
    /// `custom-openai` (no `_<uuid>` suffix) and the TTS prefix
    /// `custom-openai-tts_…` (its char after the base is `-`, not `_`).
    static func customEndpointUUID(fromPresetID id: String) -> UUID? {
        guard id.hasPrefix(customPresetPrefix) else { return nil }
        return UUID(uuidString: String(id.dropFirst(customPresetPrefix.count)))
    }

    /// Value-copy of `self` with an overridden `id` + `dynamicEndpointKey` —
    /// the synthesis primitive for per-uuid custom providers (no gateway
    /// analog; the registry has no per-instance constructor). Every other field
    /// rides through unchanged from the `customOpenAICompat` template.
    func withCustom(id newID: String, dynamicEndpointKey newKey: String) -> STTProvider {
        STTProvider(
            id: newID,
            transcribeURL: transcribeURL,
            probeURL: probeURL,
            model: model,
            auth: auth,
            transport: transport,
            maxAudioBytes: maxAudioBytes,
            maxAudioSeconds: maxAudioSeconds,
            multipartFieldNames: multipartFieldNames,
            responseShape: responseShape,
            jsonBodyFactory: jsonBodyFactory,
            probe: probe,
            statusMap: statusMap,
            inProcessRunner: inProcessRunner,
            dynamicEndpointKey: newKey
        )
    }

    /// Look up a provider by ID. A per-endpoint custom id
    /// (`custom-openai_<uuid>`) SYNTHESIZES a provider off the
    /// `customOpenAICompat` template with its own per-uuid `dynamicEndpointKey`
    /// (`stt.custom.url.<uuid>`). Otherwise falls back to `mistralVoxtral` (the
    /// V1 default) on miss — prevents call sites from having to handle nil when
    /// KVS carries an unknown preset ID (forward-compat with future providers
    /// shipped to other devices).
    static func lookup(id: String) -> STTProvider {
        if let uuid = customEndpointUUID(fromPresetID: id) {
            return customOpenAICompat.withCustom(
                id: id,
                dynamicEndpointKey: Constants.customSTTURLKey(for: uuid)
            )
        }
        return allRegistered.first(where: { $0.id == id }) ?? .mistralVoxtral
    }
}
