// SPDX-License-Identifier: Apache-2.0

// Conduck
// TTSProvider.swift
//
// Cloud Text-to-Speech foundation. Value-type registry of supported TTS
// providers, mirroring `Services/STT/STTProvider.swift` one-for-one. Each
// provider is a `static let` instance of `TTSProvider`; a later `TTSClient`
// dispatches by `transport` (`.openAISpeech` vs `.elevenLabs`) and calls into
// the per-transport request-body builder (`bodyFactory`).
//
// The registry GROUPS with the STT registry by re-using the same Keychain
// slot: a vendor's TTS key lives in its EXISTING `stt.apiKey.<sttPresetID>`
// slot (no new Keychain account, no iCloud-Keychain migration). The mapping
// lives on `sharedKeySTTPresetID` so `SettingsManager.activeTTSSnapshot()`
// can resolve the key in ONE actor hop without the UI layer needing to know
// the STT registry (avoids a circular dependency).
//
// LOCKED — all 5 provider IDs are user-visible-equivalent (drive the KVS
// active-TTS-provider value + the `tts.voice.<id>` override key). Renaming
// orphans a user's stored TTS selection + voice override.

import Foundation

/// A text-to-speech provider's wire-level contract. Value type — held as
/// `static let` instances on this type, never instantiated by callers.
struct TTSProvider: Sendable {
    /// Wire-format dispatch — how the synthesize request is built + where the
    /// voice rides (body vs URL path/query). `TTSClient` switches on this.
    enum Transport: Sendable, Equatable {
        /// OpenAI-style `POST /v1/audio/speech` with a JSON body carrying
        /// `{model, input, voice, response_format}`. Shared by OpenAI's
        /// `gpt-4o-mini-tts` AND Mistral's `voxtral-mini-tts-2603` (Mistral
        /// exposes an OpenAI-compatible `/v1/audio/speech` endpoint — voice is
        /// a named built-in preset in the body, same as OpenAI).
        case openAISpeech

        /// ElevenLabs `POST /v1/text-to-speech/{voice_id}?output_format=...`.
        /// The voice + output format ride the URL (path + query); the body
        /// carries only `{text, model_id}`. Auth via the `xi-api-key` header.
        case elevenLabs

        /// Google Gemini `:generateContent` — `POST
        /// /v1beta/models/{model}:generateContent` with a nested JSON body
        /// (`contents[].parts[].text` + `generationConfig.speechConfig`) and the
        /// audio returned INLINE (base64 under `candidates[0].content.parts[0].
        /// inlineData.data`), distinct from both shapes above. Auth via the
        /// `x-goog-api-key` header (shared with Gemini STT). Live via
        /// `geminiTTS`. Qwen remains the one provider that would also land here
        /// (DashScope-native) but is not yet shipped — the slot stays an
        /// extension point so it lands as one registry entry + one `bodyFactory`
        /// with zero `TTSClient` rewrite.
        case generateContent
    }

    /// Output audio container. Most cloud providers ship `.mp3` (universally
    /// playable via `AVAudioPlayer`, smallest clip size for short chat replies);
    /// Gemini ships `.wav` — its endpoint returns RAW HEADERLESS 16-bit/24 kHz/
    /// mono PCM, which `AVAudioPlayer(data:)` cannot open, so the decode
    /// chokepoint wraps it in a 44-byte WAV/RIFF container (see
    /// `ResponseShape.geminiInlineAudio` + `wavWrappedPCM16`). Purely
    /// descriptive — nothing exhaustively switches on `outputFormat`; it
    /// documents what the playback layer receives. Reserved as an enum so a
    /// future low-latency format (Opus streaming) is an additive case, not a
    /// Bool flip.
    enum OutputFormat: String, Sendable, Equatable {
        case mp3
        case wav
    }

    /// How the synthesize 2xx body carries the audio. NOT every "OpenAI-style"
    /// endpoint returns raw bytes — Mistral's `/v1/audio/speech` returns JSON
    /// with the mp3 base64-encoded under a named field, so a single response
    /// shape per provider is required (the request transport alone does not
    /// determine the response decode). `TTSClient` / `WatchTTSClient` switch on
    /// this when handling a 2xx response.
    enum ResponseShape: Sendable, Equatable {
        /// 2xx body IS the raw audio container bytes (mp3). OpenAI + ElevenLabs.
        case rawAudio

        /// 2xx body is JSON; the mp3 is base64-encoded under `field`. Mistral
        /// returns `{"audio_data":"<base64-mp3>", …}` (verified against
        /// docs.mistral.ai/capabilities/audio/text_to_speech/speech). `TTSClient`
        /// JSON-parses, reads `dict[field] as? String`, then base64-decodes.
        case base64JSON(field: String)

        /// 2xx body is Gemini's `:generateContent` JSON; the audio is base64
        /// RAW HEADERLESS PCM (signed 16-bit LE, mono) at
        /// `candidates[0].content.parts[<first inlineData>].inlineData.data`,
        /// with the sample rate carried in the sibling `inlineData.mimeType`
        /// (e.g. `audio/L16;rate=24000`; live returns lowercase
        /// `audio/l16; rate=24000; channels=1`). Verified against
        /// ai.google.dev/gemini-api/docs/speech-generation + a sibling product
        /// running this exact model in production + a live curl probe.
        ///
        /// `AVAudioPlayer(data:)` (every Conduck playback surface) CANNOT open
        /// headerless PCM, so the decode arm wraps the bytes in a canonical
        /// 44-byte WAV/RIFF header (`wavWrappedPCM16`) before returning — the
        /// single shared chokepoint, so iOS `TTSClient` + watchOS `WatchTTSClient`
        /// both get a playable container with no player changes.
        ///
        /// The preview model occasionally returns a `{"text":…}` part with NO
        /// `inlineData` on a 200 (text tokens instead of audio) — that decodes to
        /// `ttsEmptyAudio`, which is now RETRYABLE (one ~1 s retry usually
        /// self-heals; see `AppError.maxAttempts`).
        case geminiInlineAudio

        /// Decode the mp3 bytes from a 2xx response body per this shape. Shared
        /// by `TTSClient` (iOS) + `WatchTTSClient` (wrist) so both decode Mistral
        /// identically. Throws `ttsEmptyAudio` on a missing/empty/undecodable
        /// payload (the playback layer falls back to Apple). Never logs the body
        /// (privacy). `nonisolated` — pure Data-in/Data-out with no shared
        /// state, so the Watch target's MainActor default isolation must not pin
        /// it to the main thread: the Mistral arm JSON-parses a multi-hundred-KB
        /// body, and `WatchTTSClient` runs it off-main (`@concurrent`) so the
        /// decode can't stall the wrist UI at reply-arrival auto-speak.
        nonisolated func decodeAudio(from data: Data) throws -> Data {
            switch self {
            case .rawAudio:
                // The body IS the mp3. Empty = provider anomaly → terminal.
                guard !data.isEmpty else { throw AppError.ttsEmptyAudio }
                return data

            case .base64JSON(let field):
                // JSON envelope with base64-encoded mp3 under `field`. A missing
                // field, empty string, or undecodable base64 → terminal (Apple
                // fallback) rather than handing garbage to `AVAudioPlayer`.
                guard
                    let obj = try? JSONSerialization.jsonObject(with: data),
                    let dict = obj as? [String: Any],
                    let b64 = dict[field] as? String,
                    !b64.isEmpty,
                    let audio = Data(base64Encoded: b64),
                    !audio.isEmpty
                else {
                    throw AppError.ttsEmptyAudio
                }
                return audio

            case .geminiInlineAudio:
                // Gemini `:generateContent` JSON. Walk
                // candidates[0].content.parts[] and take the FIRST part carrying
                // a non-empty, base64-decodable `inlineData.data` (the preview
                // model sometimes returns a leading `{"text":…}` part with no
                // `inlineData` — skip those). The bytes are RAW HEADERLESS PCM
                // (16-bit LE / mono); read the sample rate from the same part's
                // `inlineData.mimeType` (default 24000) and wrap in a WAV header
                // so `AVAudioPlayer` can open it. No PCM found → terminal-but-
                // -retryable `ttsEmptyAudio`. Never logs the body.
                guard
                    let obj = try? JSONSerialization.jsonObject(with: data),
                    let dict = obj as? [String: Any]
                else {
                    throw AppError.ttsEmptyAudio
                }

                // A prompt-level safety block returns a 200 with
                // `promptFeedback.blockReason` (e.g. PROHIBITED_CONTENT) and NO
                // `candidates` — name it `ttsContentBlocked` so the surfaced
                // message points at the safety filter, not the voice ID. (The
                // request prepends a "Say the following:" directive specifically
                // to dodge the bare-text block; this guards the residual case of
                // a genuinely-flagged reply.) Distinct from the preview model's
                // text-tokens-instead-of-audio quirk below, which stays the
                // retryable `ttsEmptyAudio`.
                if let feedback = dict["promptFeedback"] as? [String: Any],
                   feedback["blockReason"] != nil {
                    throw AppError.ttsContentBlocked
                }

                guard
                    let candidates = dict["candidates"] as? [[String: Any]],
                    let first = candidates.first,
                    let content = first["content"] as? [String: Any],
                    let parts = content["parts"] as? [[String: Any]]
                else {
                    throw AppError.ttsEmptyAudio
                }

                for part in parts {
                    guard
                        let inlineData = part["inlineData"] as? [String: Any],
                        let b64 = inlineData["data"] as? String,
                        !b64.isEmpty,
                        let pcm = Data(base64Encoded: b64),
                        !pcm.isEmpty
                    else {
                        continue
                    }
                    let rate = (inlineData["mimeType"] as? String)
                        .flatMap(Self.sampleRate(fromMimeType:)) ?? 24000
                    return Self.wavWrappedPCM16(pcm, sampleRate: rate, channels: 1)
                }

                // Every part was a text token / empty inlineData → no audio.
                throw AppError.ttsEmptyAudio
            }
        }

        // MARK: - Gemini PCM → WAV helpers

        /// Parse the PCM sample rate from a Gemini `inlineData.mimeType`. The
        /// value is shaped like `audio/L16;rate=24000` (docs) or
        /// `audio/l16; rate=24000; channels=1` (live, lowercase + spaces); this
        /// lowercases, finds `rate=`, and reads the following run of digits.
        /// Returns `nil` if no `rate=` token / no digits (caller defaults 24000).
        /// `nonisolated` like its `decodeAudio` caller (pure string parse).
        nonisolated static func sampleRate(fromMimeType mime: String) -> Int? {
            let lower = mime.lowercased()
            guard let range = lower.range(of: "rate=") else { return nil }
            let digits = lower[range.upperBound...].prefix { $0.isNumber }
            // Bound to a sane PCM range — a malformed/hostile digit run that
            // parses but exceeds UInt32 (or overflows the byteRate math)
            // would trap in `wavWrappedPCM16`'s header conversions. The
            // response rides default ATS with no cert pin, so treat the
            // value as untrusted. Out-of-range → nil (caller defaults 24000).
            guard let rate = Int(digits), (8_000...384_000).contains(rate) else { return nil }
            return rate
        }

        /// Wrap raw signed-16-bit-LE PCM in a canonical 44-byte WAV/RIFF header
        /// and return `header + pcm`. This is binary CONTAINER PACKAGING, not a
        /// transcode (the PCM samples are copied through untouched) — the same
        /// category of work as base64-decoding Mistral's mp3. Living on this one
        /// shared chokepoint means both the iOS `TTSClient` and the watchOS
        /// `WatchTTSClient` get a container `AVAudioPlayer(data:)` can open from
        /// Gemini's headerless PCM, with zero player-layer changes.
        ///
        /// All multi-byte fields are little-endian (WAV spec). `byteRate` =
        /// `sampleRate * channels * 2` (2 bytes per 16-bit sample); `blockAlign`
        /// = `channels * 2`; `bitsPerSample` = 16.
        /// `nonisolated` like its `decodeAudio` caller (pure byte packaging).
        nonisolated static func wavWrappedPCM16(_ pcm: Data, sampleRate: Int, channels: Int) -> Data {
            let bitsPerSample = 16
            let byteRate = sampleRate * channels * (bitsPerSample / 8)
            let blockAlign = channels * (bitsPerSample / 8)

            var header = Data()
            header.reserveCapacity(44 + pcm.count)

            func appendLE16(_ value: UInt16) {
                var v = value.littleEndian
                withUnsafeBytes(of: &v) { header.append(contentsOf: $0) }
            }
            func appendLE32(_ value: UInt32) {
                var v = value.littleEndian
                withUnsafeBytes(of: &v) { header.append(contentsOf: $0) }
            }

            // RIFF chunk descriptor.
            header.append(contentsOf: Array("RIFF".utf8))
            appendLE32(UInt32(36 + pcm.count))            // ChunkSize
            header.append(contentsOf: Array("WAVE".utf8))

            // "fmt " sub-chunk (PCM, 16 bytes).
            header.append(contentsOf: Array("fmt ".utf8))
            appendLE32(16)                                 // Subchunk1Size (PCM)
            appendLE16(1)                                  // AudioFormat (1 = PCM)
            appendLE16(UInt16(channels))
            appendLE32(UInt32(sampleRate))
            appendLE32(UInt32(byteRate))
            appendLE16(UInt16(blockAlign))
            appendLE16(UInt16(bitsPerSample))

            // "data" sub-chunk.
            header.append(contentsOf: Array("data".utf8))
            appendLE32(UInt32(pcm.count))                  // Subchunk2Size

            header.append(pcm)
            return header
        }
    }

    /// Stable provider identifier. **DO NOT RENAME** — drives the KVS
    /// active-TTS-provider value (`Constants.ttsActiveProviderIDKVSKey`) and
    /// the per-provider voice-override key (`Constants.ttsVoiceKey(for:)`).
    let id: String

    /// Synthesis endpoint (POST target). For `.elevenLabs` this is a TEMPLATE
    /// whose `{voice_id}` segment + `output_format` query are filled by
    /// `effectiveSpeechURL(voice:)`; for `.openAISpeech` it is the final URL
    /// (voice rides the body).
    let speechURL: URL

    /// Wire-level model tag (e.g. `gpt-4o-mini-tts`, `voxtral-mini-tts-2603`,
    /// `eleven_flash_v2_5`).
    let model: String

    /// How to attach the API key to outbound requests. Reuses the STT auth
    /// abstraction verbatim — `.bearer` (OpenAI / Mistral), `.headerName`
    /// (ElevenLabs `xi-api-key`), `.none` (Apple sentinel — never hits the
    /// network).
    let auth: STTAuthScheme

    /// Wire-format dispatch — see `Transport`.
    let transport: Transport

    /// Per-transport request-body builder metatype. Nil for the Apple
    /// sentinel (handled at the player, never reaches `TTSClient`). Named
    /// static methods preserve stack-trace clarity (mirrors STT's
    /// `jsonBodyFactory`).
    let bodyFactory: TTSBodyFactory.Type?

    /// Pinned default voice. OpenAI: a named built-in (`alloy`). Mistral: a
    /// voice slug from `GET /v1/audio/voices` (`en_paul_neutral`). ElevenLabs:
    /// a real premade `voice_id` (Aria — `9BWtsMINqrJLrRacOk9x`). Apple: empty
    /// sentinel (the system voice is chosen by `AVSpeechSynthesizer`, never via
    /// this field). NOT a locked storage key — only `id` is locked, so a
    /// `defaultVoice` change orphans nothing.
    let defaultVoice: String

    /// Output audio container — `.mp3` for all v1 cloud providers.
    let outputFormat: OutputFormat

    /// How the 2xx body carries the audio — `.rawAudio` (OpenAI / ElevenLabs)
    /// vs `.base64JSON` (Mistral). See `ResponseShape`.
    let responseDecoding: ResponseShape

    /// HTTP-status → AppError mapping for non-2xx synthesize responses.
    let statusMap: TTSStatusMap

    /// The EXISTING STT preset whose Keychain slot
    /// (`stt.apiKey.<sttPresetID>`) holds this vendor's API key. Cloud TTS
    /// reads the SAME slot the vendor's STT already uses — one key per vendor,
    /// both directions. Nil for the Apple sentinel (no key). Resolved in
    /// `SettingsManager.activeTTSSnapshot()`.
    let sharedKeySTTPresetID: String?

    /// For the BYO custom endpoint ONLY: the App-Groups/KVS key whose stored
    /// BASE URL resolves this provider's synthesis endpoint at request time
    /// (`SettingsManager.customTTSSpeechURL()` appends `/v1/audio/speech`).
    /// `nil` for the 5 frozen providers (their `speechURL` is the real, fixed
    /// target). Mirrors `STTProvider.dynamicEndpointKey`; `TTSClient` dispatches
    /// off `!= nil` for the dynamic-URL + cert-pin path. The custom TTS endpoint
    /// SHARES the custom STT endpoint's base URL (`stt.custom.url`), key, cert
    /// pin, and auth scheme — one server, both directions.
    let dynamicEndpointKey: String?

    // MARK: - Endpoint helpers

    /// Build the Gemini `:generateContent` SPEECH endpoint for a given model
    /// tag. Single source of truth used BOTH by the `geminiTTS` registry
    /// definition and by `effectiveSpeechURL(voice:customModel:)`, so the pinned
    /// default URL and a user model override can never drift in path shape.
    /// Gemini is the one TTS provider whose model lives in the URL path, not the
    /// request body. TTS is now the ONLY model-in-URL surface; STT moved to the
    /// fixed Interactions endpoint.
    static func geminiSpeechEndpoint(model: String) -> URL {
        URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent")!
    }

    // MARK: - Voice / model / endpoint helpers

    /// Resolve the effective voice for a synthesis. Returns the trimmed
    /// non-empty `override` (the user's per-provider voice pick) when present,
    /// else the pinned `defaultVoice`. Mirrors
    /// `STTProvider.effectiveModel(customModel:)`.
    func effectiveVoice(override: String?) -> String {
        if let override = override?.trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty {
            return override
        }
        return defaultVoice
    }

    /// Resolve the effective model tag for a synthesis. Returns the trimmed
    /// non-empty `customModel` override when present, else the pinned default
    /// `model`. The Apple sentinel (`bodyFactory == nil` — it never hits the
    /// network) ALWAYS returns `model` unchanged: there is no wire model to
    /// override, and the sentinel `model` (`avspeechsynthesizer`) is never sent.
    /// Mirrors `STTProvider.effectiveModel(customModel:)`.
    ///
    /// NOTE: the BYO custom endpoint's REQUIRED model is resolved separately from
    /// its `CustomTTSConfig` (`tts.custom.model`), NOT through this method — the
    /// per-provider override (`tts.customModel.<id>`) must never leak to it
    /// (`TTSClient` branches on `isCustomEndpoint`).
    func effectiveModel(customModel: String?) -> String {
        guard bodyFactory != nil else { return model }
        if let override = customModel?.trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty {
            return override
        }
        return model
    }

    /// Resolve the effective synthesis URL for a given (already-resolved) voice
    /// AND optional model override. TWO independent URL rewrites COMPOSE here in
    /// one call so a caller never has to chain them (and they can't fall out of
    /// sync):
    ///   - ElevenLabs embeds the `voice_id` in the URL PATH and appends the
    ///     `output_format` query (voice + format are NOT in the body for that
    ///     transport).
    ///   - Gemini (`.generateContent`) embeds the MODEL in the URL PATH
    ///     (`/models/<model>:generateContent`) — a model override must rebuild
    ///     the endpoint there. Built from the shared `geminiSpeechEndpoint(model:)`
    ///     so default + override can't drift.
    /// OpenAI / Mistral / the custom endpoint return `speechURL` unchanged
    /// (voice + model ride the body). Pair with `effectiveVoice(override:)` +
    /// `effectiveModel(customModel:)`.
    ///
    /// The ElevenLabs rewrite percent-encodes the voice segment defensively
    /// (voice IDs are URL-safe today, but a user-pasted custom ID may not be)
    /// and falls back to `speechURL` if URL composition fails — a malformed
    /// override degrades to the template rather than crashing.
    func effectiveSpeechURL(voice: String, customModel: String? = nil) -> URL {
        switch transport {
        case .generateContent:
            // Gemini's model lives in the URL path. An override rebuilds the
            // endpoint via the shared helper; default returns the pinned URL.
            if let override = customModel?.trimmingCharacters(in: .whitespacesAndNewlines),
               !override.isEmpty {
                return Self.geminiSpeechEndpoint(model: override)
            }
            return speechURL

        case .elevenLabs:
            guard var components = URLComponents(url: speechURL, resolvingAgainstBaseURL: false) else {
                return speechURL
            }
            // `speechURL` path ends at `/v1/text-to-speech`; append the voice id.
            // Assign the RAW voice to `components.path` — the `URLComponents` →
            // `url` step percent-encodes disallowed characters exactly once.
            // Pre-encoding here would double-encode (e.g. a space → `%2520`).
            var path = components.path
            if !path.hasSuffix("/") { path += "/" }
            path += voice
            components.path = path
            components.queryItems = [URLQueryItem(name: "output_format", value: "mp3_44100_128")]
            return components.url ?? speechURL

        case .openAISpeech:
            // OpenAI / Mistral / custom — voice + model ride the body; the URL is
            // the fixed `speechURL` (custom resolves its dynamic URL upstream).
            return speechURL
        }
    }

    // MARK: - Registered providers

    /// Apple on-device TTS sentinel — `AVSpeechSynthesizer`. The DEFAULT and
    /// the offline/error fallback. Handled entirely at the playback layer
    /// (a later `SpeechPlayer` / `ReplyVoice`); NEVER reaches `TTSClient`
    /// (like STT's `.inProcess` Apple provider). URL/model are sentinels,
    /// never accessed; `bodyFactory`/`sharedKeySTTPresetID` are nil.
    // DO NOT RENAME — drives the KVS active-TTS-provider value + voice key.
    static let appleTTS = TTSProvider(
        id: "apple-tts",
        speechURL: URL(string: "x-apple-on-device://speech")!,
        model: "avspeechsynthesizer",
        auth: .none,
        transport: .openAISpeech,   // unused — sentinel never hits TTSClient
        bodyFactory: nil,
        defaultVoice: "",
        outputFormat: .mp3,
        responseDecoding: .rawAudio, // unused — sentinel never hits TTSClient
        statusMap: .never,
        sharedKeySTTPresetID: nil,
        dynamicEndpointKey: nil
    )

    /// OpenAI `gpt-4o-mini-tts` — steerable, low-latency. OpenAI-compatible
    /// `POST /v1/audio/speech`, JSON body `{model, input, voice,
    /// response_format:"mp3"}`, `Authorization: Bearer` auth. Default voice
    /// `alloy` (OpenAI's documented default). Reads the same Keychain key as
    /// OpenAI STT (`openai-gpt4o-transcribe`).
    // DO NOT RENAME — drives the KVS active-TTS-provider value + voice key.
    static let openAITTS = TTSProvider(
        id: "openai-tts",
        speechURL: URL(string: "https://api.openai.com/v1/audio/speech")!,
        model: "gpt-4o-mini-tts",
        auth: .bearer,
        transport: .openAISpeech,
        bodyFactory: OpenAISpeechBody.self,
        defaultVoice: "alloy",
        outputFormat: .mp3,
        // OpenAI's `/v1/audio/speech` returns the raw mp3 bytes directly.
        responseDecoding: .rawAudio,
        statusMap: .openAICompat,
        sharedKeySTTPresetID: "openai-gpt4o-transcribe",
        dynamicEndpointKey: nil
    )

    /// Mistral `voxtral-mini-tts-2603` — `POST /v1/audio/speech`. NOT fully
    /// OpenAI-compatible (verified against
    /// docs.mistral.ai/capabilities/audio/text_to_speech/speech) on two axes:
    ///   - REQUEST body uses `voice_id` (NOT `voice`): `{model, input, voice_id,
    ///     response_format:"mp3"}` → `MistralSpeechBody`.
    ///   - RESPONSE is JSON with the mp3 base64-encoded under `audio_data` (NOT
    ///     raw bytes) → `responseDecoding: .base64JSON("audio_data")`.
    /// The URL + auth + transport (`.openAISpeech` — voice in body, plain URL)
    /// + status map ARE the same as OpenAI; only the body field name + the
    /// response shape differ. Voices are SLUGS from `GET /v1/audio/voices` (10
    /// today, all English: `en_paul_{neutral,happy,sad,angry,excited,confident,
    /// cheerful,frustrated}`, `gb_oliver_neutral`, `gb_jane_sarcasm`). Mistral
    /// REQUIRES a voice — omitting `voice_id` → HTTP 400 ("Either ref_audio or
    /// voice must be provided"), so there is no server-side default. Default
    /// ships `en_paul_neutral` (live-curl-verified 200). Reads the same Keychain
    /// key as Mistral Voxtral STT (`mistral-voxtral`).
    // DO NOT RENAME — drives the KVS active-TTS-provider value + voice key.
    static let mistralTTS = TTSProvider(
        id: "mistral-tts",
        speechURL: URL(string: "https://api.mistral.ai/v1/audio/speech")!,
        model: "voxtral-mini-tts-2603",
        auth: .bearer,
        transport: .openAISpeech,
        bodyFactory: MistralSpeechBody.self,
        // Live-verified against the Mistral cloud API: voices are slugs from
        // `GET /v1/audio/voices`. `en_paul_neutral` → 200; both `neutral_female`
        // and `casual_male` → HTTP 404 `invalid_voice` (the latter two are the
        // SELF-HOSTED HuggingFace Voxtral model-card naming, a different surface
        // — that's where the prior wrong default came from).
        defaultVoice: "en_paul_neutral",
        outputFormat: .mp3,
        // Mistral returns JSON `{"audio_data":"<base64-mp3>"}`, not raw bytes.
        responseDecoding: .base64JSON(field: "audio_data"),
        statusMap: .openAICompat,
        sharedKeySTTPresetID: "mistral-voxtral",
        dynamicEndpointKey: nil
    )

    /// ElevenLabs Flash v2.5 — premium voice, lowest latency. `POST
    /// /v1/text-to-speech/{voice_id}?output_format=mp3_44100_128` with body
    /// `{text, model_id:"eleven_flash_v2_5"}`, `xi-api-key` header auth. The
    /// voice rides the URL PATH (see `effectiveSpeechURL`). Default voice
    /// `9BWtsMINqrJLrRacOk9x` (Aria — the current premade default). The prior
    /// default `21m00Tcm4TlvDq8ikWAM` (Rachel) is a LEGACY default on a
    /// deprecation clock (account-gated, hard-expires 2026-12-31) — replaced
    /// here so it can't break the same way later. Reads the same Keychain key as
    /// ElevenLabs Scribe STT (`elevenlabs-scribe-v2`).
    // DO NOT RENAME — drives the KVS active-TTS-provider value + voice key.
    static let elevenLabsTTS = TTSProvider(
        id: "elevenlabs-tts",
        // Template — `effectiveSpeechURL(voice:)` appends `/{voice_id}` +
        // `?output_format=mp3_44100_128`. The path stops at `/v1/text-to-speech`.
        speechURL: URL(string: "https://api.elevenlabs.io/v1/text-to-speech")!,
        model: "eleven_flash_v2_5",
        auth: .headerName("xi-api-key"),
        transport: .elevenLabs,
        bodyFactory: ElevenLabsTTSBody.self,
        defaultVoice: "9BWtsMINqrJLrRacOk9x",
        outputFormat: .mp3,
        // ElevenLabs streams the raw mp3 bytes back directly.
        responseDecoding: .rawAudio,
        statusMap: .elevenLabs,
        sharedKeySTTPresetID: "elevenlabs-scribe-v2",
        dynamicEndpointKey: nil
    )

    /// Google Gemini `gemini-3.1-flash-tts-preview` — same vendor + same key as
    /// Gemini STT. `POST /v1beta/models/{model}:generateContent` with a nested
    /// JSON body (`contents[].parts[].text` + `generationConfig.responseModalities:
    /// ["AUDIO"]` + `speechConfig.voiceConfig.prebuiltVoiceConfig.voiceName`) →
    /// `GeminiSpeechBody`. Auth is the `x-goog-api-key` header, IDENTICAL to the
    /// Gemini STT provider (`STTProvider` `gemini-3-1-flash-lite`,
    /// `auth: .headerName("x-goog-api-key")`) — no secret in the URL.
    ///
    /// The 2xx body is JSON with the audio base64 at
    /// `candidates[0].content.parts[0].inlineData.data`. That audio is RAW
    /// HEADERLESS PCM (signed 16-bit LE, 24000 Hz, mono); the decode chokepoint
    /// (`.geminiInlineAudio`) reads the rate from the sibling
    /// `inlineData.mimeType` and wraps the bytes in a 44-byte WAV header so
    /// `AVAudioPlayer` can open them. Hence `outputFormat: .wav`.
    ///
    /// Voices are TITLE-CASE prebuilt names from the docs (30: `Kore`, `Charon`,
    /// `Zephyr`, `Aoede`, …). Default `Kore` (clear/professional/neutral;
    /// live-verified 200 — user-overridable). An invalid voice → HTTP 404 →
    /// terminal `ttsSynthesisFailed` (fail-loud in the preview). The PREVIEW
    /// model occasionally returns text tokens instead of audio on a 200 → decodes
    /// to `ttsEmptyAudio`, now RETRYABLE (one ~1 s retry usually self-heals
    /// before any Apple fallback). `model` is preview — registry-pinned; bump the
    /// string on GA, but the `gemini-tts` id stays frozen. Reads the same
    /// Keychain slot as Gemini STT (`gemini-3-1-flash-lite`).
    // DO NOT RENAME — new LOCKED id driving the KVS active-TTS value + voice key.
    static let geminiTTS = TTSProvider(
        id: "gemini-tts",
        // Built via the SHARED `geminiSpeechEndpoint(model:)` so the pinned
        // default URL and a user model override (which rebuilds the same path)
        // can never drift.
        speechURL: TTSProvider.geminiSpeechEndpoint(model: "gemini-3.1-flash-tts-preview"),
        model: "gemini-3.1-flash-tts-preview",
        auth: .headerName("x-goog-api-key"),
        transport: .generateContent,
        bodyFactory: GeminiSpeechBody.self,
        defaultVoice: "Kore",
        outputFormat: .wav,
        responseDecoding: .geminiInlineAudio,
        statusMap: .gemini,
        sharedKeySTTPresetID: "gemini-3-1-flash-lite",
        dynamicEndpointKey: nil
    )

    /// OpenRouter hosted speech — `POST /api/v1/audio/speech` (shipped
    /// 2026-05-01). OpenAI-compatible on the wire: `{model, input, voice,
    /// response_format:"mp3"}` → the SHARED `OpenAISpeechBody` (which sends
    /// `response_format:"mp3"`, side-stepping OpenRouter's `pcm` default) → raw
    /// mp3 bytes → `.rawAudio`. Same base URL + Bearer key as OpenRouter STT
    /// (`sharedKeySTTPresetID: "openrouter-stt"` — one key, both directions) and
    /// the OpenRouter hosted-model GATEWAY (cross-reusable). Default model
    /// `x-ai/grok-voice-tts-1.0` + voice `Eve` is founder-selected and
    /// funded-key-verified live (HTTP 200 → real mp3; all 5 Grok voices
    /// Eve/Ara/Rex/Sal/Leo return audio); user-overridable. mp3-capable (fits
    /// `OpenAISpeechBody`); single-provider hosted on OpenRouter. Several
    /// catalog entries do NOT fit and were ruled out: OpenAI `…-tts` IDs return
    /// "does not exist", Voxtral upstream-404s, and Gemini Flash TTS rejects
    /// `mp3` (pcm-only). NB Grok's voices are NOT `alloy` — that yields 404.
    // DO NOT RENAME — drives the KVS active-TTS value + `tts.voice.<id>` key.
    static let openRouterTTS = TTSProvider(
        id: "openrouter-tts",
        speechURL: URL(string: Constants.openRouterBaseURLString + Constants.openRouterSpeechPath)!,
        model: "x-ai/grok-voice-tts-1.0",
        auth: .bearer,
        transport: .openAISpeech,
        bodyFactory: OpenAISpeechBody.self,
        defaultVoice: "Eve",
        outputFormat: .mp3,
        responseDecoding: .rawAudio,
        statusMap: .openAICompat,
        sharedKeySTTPresetID: "openrouter-stt",
        dynamicEndpointKey: nil
    )

    /// Custom OpenAI-compatible TTS endpoint (BYO `/v1/audio/speech`). The 6th
    /// registered provider — id `"custom-openai-tts"` is LOCKED (drives the KVS
    /// active-TTS value + the `tts.voice.custom-openai-tts` override key). The
    /// TTS sibling of the `custom-openai` STT provider: it SHARES that endpoint's
    /// stored base URL (`stt.custom.url`), API key (`stt.apiKey.custom-openai`),
    /// optional cert-pin tightening, and auth scheme — one server, both
    /// directions (STT → `/v1/audio/transcriptions`, TTS → `/v1/audio/speech`).
    ///
    /// Like `STTProvider.customOpenAICompat`, its `speechURL` is a SENTINEL never
    /// hit directly: the real target is the user's base URL with
    /// `/v1/audio/speech` appended, resolved at request time via
    /// `SettingsManager.customTTSSpeechURL()` and dispatched off
    /// `dynamicEndpointKey != nil`. Wire shape mirrors OpenAI's
    /// `gpt-4o-mini-tts` (`{model, input, voice, response_format:"mp3"}` →
    /// `OpenAISpeechBody`, raw mp3 bytes → `.rawAudio`; live-verified 200 against
    /// `api.openai.com`). Unlike the 5 frozen providers (model pinned), the
    /// `/v1/audio/speech` `model` is REQUIRED and varies per server, so it is a
    /// user field (`tts.custom.model`, default `"tts-1"`) resolved from the
    /// snapshot's `CustomTTSConfig`, not this immutable `model`. The effective
    /// auth scheme (`.bearer` / `.none` for keyless local servers) also rides the
    /// config. iOS/macOS only — the Watch can't reach the BYO endpoint and falls
    /// back to Apple (mirrors custom-STT relay).
    // DO NOT RENAME — drives the KVS active-TTS value + `tts.voice.<id>` key.
    static let customOpenAITTS = TTSProvider(
        id: "custom-openai-tts",
        speechURL: URL(string: "x-conduck-custom-tts://synthesize")!,
        model: "tts-1",
        auth: .bearer,
        transport: .openAISpeech,
        bodyFactory: OpenAISpeechBody.self,
        defaultVoice: "alloy",
        outputFormat: .mp3,
        responseDecoding: .rawAudio,
        statusMap: .openAICompat,
        sharedKeySTTPresetID: "custom-openai",
        dynamicEndpointKey: "stt.custom.url"
    )

    /// All providers known at registration time. Order is UI-display order
    /// (Apple first — the default). Gemini is LIVE via `.generateContent`; the
    /// BYO `custom-openai-tts` endpoint is appended LAST (mirrors the STT
    /// registry's `custom-openai` ordering). Qwen remains the one provider
    /// intentionally absent in v1 (its slot reserved on `.generateContent`).
    static let allRegistered: [TTSProvider] = [
        .appleTTS,
        .openAITTS,
        .mistralTTS,
        .elevenLabsTTS,
        .geminiTTS,
        .openRouterTTS,
        .customOpenAITTS,
    ]

    /// Whether this provider's model lives in the URL PATH (Gemini's
    /// `…/models/<model>:generateContent`, `transport == .generateContent`)
    /// rather than the request body. Drives model-override sanitization
    /// (`SettingsViewModel.sanitizeModelTag`): a URL-path model MUST strip `/`
    /// (path-injection guard); a body model (OpenRouter, OpenAI/Mistral
    /// `.openAISpeech`, custom endpoints) may KEEP `/` — OpenRouter model IDs
    /// like `x-ai/grok-voice-tts-1.0` REQUIRE the slash. Mirrors
    /// `SettingsViewModel.sanitizeModelTag(_:allowsSlash:)`.
    var modelInURL: Bool { transport == .generateContent }

    // MARK: - Multiple named custom endpoints (Phase B)
    //
    // The single `custom-openai-tts` provider above is the LEGACY
    // (migration-read) singleton. Phase B mints one synthesized provider per
    // user-named `CustomVoiceEndpoint`, identified by `custom-openai-tts_<uuid>`,
    // sharing the same endpoint server as the matching `custom-openai_<uuid>`
    // STT provider. The base prefix `custom-openai-tts` is preserved (every BYO
    // filter checking it keeps matching); synthesized providers are produced on
    // demand by `lookup(id:)` — `allRegistered` stays length-frozen.

    /// Per-instance provider-ID prefix for a named custom TTS endpoint:
    /// `custom-openai-tts_<uuid-lowercased>`. DISJOINT from the STT prefix
    /// `custom-openai_` (the STT base ends with the uuid-introducing `_`; here
    /// the `-tts` segment sits between the base and the `_`) and from the bare
    /// legacy `custom-openai-tts`. LOCKED — drives the KVS active-TTS value +
    /// the `tts.voice.custom-openai-tts_<uuid>` override key.
    static let customProviderPrefix = "custom-openai-tts_"

    /// Build the per-endpoint TTS provider id for a given endpoint uuid.
    static func customEndpointID(for uuid: UUID) -> String {
        customProviderPrefix + uuid.uuidString.lowercased()
    }

    /// Inverse of `customEndpointID(for:)`. Returns the endpoint uuid iff
    /// `id` is a per-endpoint custom TTS provider id. REJECTS the bare legacy
    /// `custom-openai-tts` (no `_<uuid>` suffix).
    static func customEndpointUUID(fromProviderID id: String) -> UUID? {
        guard id.hasPrefix(customProviderPrefix) else { return nil }
        return UUID(uuidString: String(id.dropFirst(customProviderPrefix.count)))
    }

    /// Value-copy of `self` with an overridden `id` + `dynamicEndpointKey` +
    /// `sharedKeySTTPresetID` — the synthesis primitive for per-uuid custom TTS
    /// providers. The `sharedKeySTTPresetID` MUST be the matching per-uuid STT
    /// preset id (`custom-openai_<uuid>`) so `activeTTSSnapshot()` reads THIS
    /// endpoint's key slot, not the singleton's — the load-bearing
    /// "one key, both directions" link. Every other field rides through
    /// unchanged from the `customOpenAITTS` template.
    func withCustom(id newID: String, dynamicEndpointKey newKey: String, sharedKeySTTPresetID newSharedKey: String) -> TTSProvider {
        TTSProvider(
            id: newID,
            speechURL: speechURL,
            model: model,
            auth: auth,
            transport: transport,
            bodyFactory: bodyFactory,
            defaultVoice: defaultVoice,
            outputFormat: outputFormat,
            responseDecoding: responseDecoding,
            statusMap: statusMap,
            sharedKeySTTPresetID: newSharedKey,
            dynamicEndpointKey: newKey
        )
    }

    /// Look up a provider by ID. A per-endpoint custom id
    /// (`custom-openai-tts_<uuid>`) SYNTHESIZES a provider off the
    /// `customOpenAITTS` template with its own per-uuid `dynamicEndpointKey`
    /// (`stt.custom.url.<uuid>`) AND `sharedKeySTTPresetID`
    /// (`custom-openai_<uuid>`, so the shared key resolves to THIS endpoint's
    /// slot). Otherwise falls back to `appleTTS` (the default + the keyless
    /// offline fallback) on miss — prevents call sites from handling nil when
    /// KVS carries an unknown provider ID. Mirrors `STTProvider.lookup`.
    static func lookup(id: String) -> TTSProvider {
        if let uuid = customEndpointUUID(fromProviderID: id) {
            return customOpenAITTS.withCustom(
                id: id,
                dynamicEndpointKey: Constants.customSTTURLKey(for: uuid),
                sharedKeySTTPresetID: STTProvider.customEndpointID(for: uuid)
            )
        }
        return allRegistered.first(where: { $0.id == id }) ?? .appleTTS
    }
}
