// SPDX-License-Identifier: Apache-2.0

// Conduck
// SettingsViewModel+TTS.swift
//
// Cloud Text-to-Speech — the TTS half of the merged "Voice" Settings
// view-model. Split into its own extension file to contain the growth
// (mirrors the STT / `personalAIRows` patterns in `SettingsViewModel.swift`).
//
// Key design parity with the STT side:
//   - `voiceProviderRows` is PRECOMPUTED from already-loaded snapshots
//     (`storedPresetIDs` / `activePresetID` / `activeTTSProviderID` /
//     `appleModelStates` / `isCustomSTTReady()`) so the SwiftUI `body` does
//     ZERO actor hops, exactly like `personalAIRows`.
//   - `sttConfigured` and `ttsConfigured` BOTH derive from the SAME
//     `storedPresetIDs` because a vendor's key is shared across both
//     directions — one saved key flips both "configured" pills.
//   - Two independent active pointers: `activePresetID` (STT) +
//     `activeTTSProviderID` (TTS). A vendor can be active for STT, TTS,
//     both, or neither.
//
// Privacy invariant: the API key flows only through `previewTTS(for:)`'s
// in-actor resolve → `ReplyVoice.previewSample(...)` and is NEVER surfaced to
// the View or any stored property.

import Foundation

/// One row in the merged "Voice" provider list — a vendor with TWO capability
/// pills (STT + TTS). Precomputed by `SettingsViewModel.voiceProviderRows` so
/// the View stays dumb (no actor hop, no branching in `body`). Derived entirely
/// from already-loaded snapshots.
struct VoiceProviderRow: Identifiable, Hashable {
    /// The `VoiceVendor.id` (UI list / nav identity).
    let vendorID: String
    let displayName: String

    /// STT: a key (or Apple model / custom config) is stored for this vendor.
    let sttConfigured: Bool
    /// STT: this vendor is the active speech-to-text provider.
    let sttActive: Bool
    /// TTS: a key is stored for this vendor (SAME shared key as `sttConfigured`).
    let ttsConfigured: Bool
    /// TTS: this vendor is the active text-to-speech provider.
    let ttsActive: Bool
    /// TTS: this vendor ships a usable TTS direction in v1 (`.available`).
    /// `false` for Qwen (`.coming`) + Custom (`.none`).
    let ttsAvailable: Bool
    /// True for a user-added per-uuid custom endpoint (`custom_<uuid>` id), false
    /// for the frozen built-in vendors. Precomputed so the list views partition
    /// into the "Providers" / "Custom endpoints" sections without per-row branching.
    let isCustom: Bool

    var id: String { vendorID }
}

// MARK: - Capability-first home derivations (presentation only)

/// Which voice direction a selector / chooser drives.
enum VoiceDirection: Sendable, Hashable {
    case stt
    case tts
}

/// A single vendor's credential state for the simplified Providers library row —
/// ONE pill per vendor (not two), so the row never implies two separate keys.
/// `notSet` means the vendor is keyless-ready-to-configure (cloud no key /
/// custom no URL); `soon` is reserved for a vendor with no shippable direction.
enum VoiceVendorCredentialState: Sendable, Equatable {
    /// On-device model installed / ready (Apple).
    case ready
    /// A shared key (cloud) or full custom config is stored.
    case keySaved
    /// No key / model / config yet.
    case notSet
    /// No shippable direction at all (reserved; no current vendor hits this).
    case soon
}

/// One row in a per-direction provider chooser (`VoiceActiveProviderPicker`).
/// Precomputed so the chooser view does ZERO actor hops — every flag derives
/// from the same already-loaded snapshots `voiceProviderRows` reads.
struct VoiceDirectionOption: Identifiable, Hashable {
    /// The `VoiceVendor.id` — list identity + deep-link key.
    let vendorID: String
    let displayName: String
    /// Whether this vendor can serve the direction in v1 (`.available`). When
    /// false the row is a disabled "Soon".
    let capable: Bool
    /// Whether the vendor is configured for this direction (shared key / model /
    /// custom config). Drives "activate" vs "Set up…".
    let configured: Bool
    /// Whether this vendor is the CURRENTLY active provider for the direction.
    let active: Bool
    /// Keyless on-device vendor (Apple) — always activatable, no "Set up".
    let isOnDevice: Bool

    var id: String { vendorID }
}

@MainActor
extension SettingsViewModel {

    // MARK: - Capability-first selector values

    /// Short display name of the active STT vendor for the home selector row
    /// (e.g. "Apple", not "Apple (On-Device)"). Public mirror of the private
    /// summary helper.
    var activeSTTVendorShortName: String {
        VoiceVendorRegistry.vendor(forSTTPresetID: activePresetID, customEndpoints: customVoiceEndpoints)?.shortDisplayName
            ?? activeProviderDisplayName
    }

    /// Short display name of the active TTS vendor for the home selector row.
    var activeTTSVendorShortName: String {
        VoiceVendorRegistry.vendor(forTTSProviderID: activeTTSProviderID, customEndpoints: customVoiceEndpoints)?.shortDisplayName
            ?? VoiceVendorRegistry.apple.shortDisplayName
    }

    // MARK: - Per-direction chooser options

    /// The ordered list of vendors for a per-direction chooser (`.stt` / `.tts`),
    /// each with its capable / configured / active flags. Apple first (mirrors
    /// `voiceProviderRows`). Pure over already-loaded snapshots — no actor hop.
    func directionOptions(for direction: VoiceDirection) -> [VoiceDirectionOption] {
        let rows = voiceProviderRows
        return VoiceVendorRegistry.vendors(customEndpoints: customVoiceEndpoints).compactMap { vendor in
            guard let row = rows.first(where: { $0.vendorID == vendor.id }) else { return nil }
            switch direction {
            case .stt:
                // Every listed vendor ships STT in v1 (`sttStatus == .available`).
                return VoiceDirectionOption(
                    vendorID: vendor.id,
                    displayName: vendor.displayName,
                    capable: vendor.sttStatus == .available,
                    configured: row.sttConfigured,
                    active: row.sttActive,
                    isOnDevice: vendor.isOnDevice
                )
            case .tts:
                return VoiceDirectionOption(
                    vendorID: vendor.id,
                    displayName: vendor.displayName,
                    capable: vendor.ttsStatus == .available,
                    configured: row.ttsConfigured,
                    active: row.ttsActive,
                    isOnDevice: vendor.isOnDevice
                )
            }
        }
    }

    // MARK: - Library row credential state (ONE pill per vendor)

    /// The single credential pill state for a vendor's Providers-library row.
    /// Collapses the old two-pill (STT + TTS) display into one — both directions
    /// share the same key, so one "Key saved" / "Ready" / "Not set" reading is
    /// the honest signal. Derived from the same shared-key snapshot.
    func credentialState(for vendorID: String) -> VoiceVendorCredentialState {
        guard let row = voiceProviderRows.first(where: { $0.vendorID == vendorID }) else {
            return .notSet
        }
        // `sttConfigured` IS the shared-key/config signal for every vendor
        // (Apple → model installed; cloud → key stored; custom → URL+key ready).
        if row.sttConfigured {
            if vendorID == "apple" { return .ready }
            // A configured KEYLESS custom endpoint stores no key — "Key saved"
            // would be a lie. Report "Ready" (configured + usable), matching the
            // truth that there's nothing secret to have saved.
            if let uuid = VoiceVendorRegistry.customVendorUUID(from: vendorID),
               (customSTTAuthSchemes[uuid] ?? .bearer) == .none {
                return .ready
            }
            return .keySaved
        }
        return .notSet
    }

    // MARK: - Merged "Voice" row derivation

    /// The ordered "Voice" vendor list for the merged Settings master — Apple
    /// first (mirrors `VoiceVendorRegistry.vendors(customEndpoints:)`). Each row carries both
    /// capability pills, precomputed from already-loaded snapshots so the View
    /// iterates a dumb array (no actor hop in `body`, mirroring `personalAIRows`).
    var voiceProviderRows: [VoiceProviderRow] {
        VoiceVendorRegistry.vendors(customEndpoints: customVoiceEndpoints).map { vendor in
            let sttConfigured = vendor.sttPresetID.map { isVendorSTTConfigured($0) } ?? false
            let sttActive = (vendor.sttPresetID == activePresetID)
            // The TTS "configured" pill derives from the SAME shared key as STT —
            // one saved vendor key flips both. A TTS-less vendor (Qwen/Custom) is
            // never TTS-configured.
            let ttsConfigured = (vendor.ttsStatus == .available) ? sttConfigured : false
            let ttsActive = (vendor.ttsProviderID != nil && vendor.ttsProviderID == activeTTSProviderID)
            return VoiceProviderRow(
                vendorID: vendor.id,
                displayName: vendor.displayName,
                sttConfigured: sttConfigured,
                sttActive: sttActive,
                ttsConfigured: ttsConfigured,
                ttsActive: ttsActive,
                ttsAvailable: vendor.ttsStatus == .available,
                isCustom: VoiceVendorRegistry.customVendorUUID(from: vendor.id) != nil
            )
        }
    }

    /// How many voice vendors have a stored key / model / config — backs the
    /// Settings "Providers & Keys" row summary. Counts the shared-key signal
    /// (`sttConfigured`, which flips both directions) across built-in + custom
    /// rows. Pure over already-loaded snapshots — no actor hop.
    var configuredVoiceVendorCount: Int {
        voiceProviderRows.filter { $0.sttConfigured }.count
    }

    /// Whether a vendor's STT side is configured (a key / model / custom config
    /// is present), reading only cached snapshots — no actor hop. Apple → model
    /// installed; Custom → URL + (key or keyless) ready; cloud → key stored.
    /// Mirrors `isProviderReady`'s readiness gates but uses "has any stored
    /// config" semantics (a stored-but-inactive cloud key still counts as
    /// configured, exactly like the STT list's "Key saved" pill).
    private func isVendorSTTConfigured(_ presetID: String) -> Bool {
        if presetID == "apple-on-device" {
            #if os(watchOS)
            return false
            #else
            // Engine-aware, mirroring `isProviderReady`: standard dictation
            // shares the system keyboard-dictation model (no download) and is
            // the working default → always configured. Only the high-quality
            // engine gates on the per-language `SpeechTranscriber` model
            // (`appleTargetKey`, the same canonical key `checkAppleModelStatus`
            // writes). Without this short-circuit the default-on Apple vendor
            // shows as unconfigured and `configuredVoiceVendorCount` undercounts.
            if appleOnDeviceEngineMode == .dictation {
                return true
            }
            return appleModelStates[appleTargetKey] == .installed
            #endif
        }
        // A per-uuid custom endpoint → per-uuid readiness (URL + key/keyless).
        if let uuid = STTProvider.customEndpointUUID(fromPresetID: presetID) {
            return isCustomSTTReady(for: uuid)
        }
        return storedPresetIDs.contains(presetID)
    }

    // MARK: - Active TTS provider switching

    /// Switch the active TTS provider. Posts `.settingsDidChangeRemotely` via
    /// `SettingsManager` (→ Watch re-broadcast). Independent of the active STT
    /// preset. No-op upstream when `providerID` is already active.
    func setActiveTTS(providerID: String) async {
        await SettingsManager.shared.setActiveTTSProviderID(providerID)
        activeTTSProviderID = providerID
    }

    // MARK: - TTS voice override

    /// Refresh `ttsVoices` from `SettingsManager`. One actor hop per registered
    /// TTS provider (mirrors `refreshCustomModels`). Empty/absent overrides are
    /// omitted so the View's binding falls back to the placeholder default.
    func refreshTTSVoices() async {
        var next: [String: String] = [:]
        for provider in TTSProvider.allRegistered {
            if let voice = await SettingsManager.shared.getTTSVoice(forProviderID: provider.id),
               !voice.isEmpty {
                next[provider.id] = voice
            }
        }
        // Per-uuid custom endpoints' TTS providers are SYNTHESIZED on demand (not
        // in `allRegistered`), so hydrate each named endpoint's voice override
        // too — else `CustomSTTConfigBody` seeds an empty voice field and "Speak a
        // sample" would persist "" and silently wipe the saved override. Read the
        // roster from the store (not the VM property) so this is independent of
        // the `loadSettings` ordering (refreshTTSVoices runs before the property
        // is hydrated in `loadCustomSTTState`).
        for endpoint in await SettingsManager.shared.customVoiceEndpoints() {
            if let voice = await SettingsManager.shared.getTTSVoice(forProviderID: endpoint.ttsProviderID),
               !voice.isEmpty {
                next[endpoint.ttsProviderID] = voice
            }
        }
        ttsVoices = next
    }

    /// Persist a per-provider TTS voice override. An empty / whitespace-only
    /// candidate clears the override (the provider's pinned `defaultVoice`
    /// applies). Refreshes `ttsVoices` so the row re-renders without a
    /// KVS round-trip. Mirrors `saveCustomModel(_:for:)`.
    func saveTTSVoice(_ voice: String, for providerID: String) async {
        let trimmed = voice.trimmingCharacters(in: .whitespacesAndNewlines)
        await SettingsManager.shared.setTTSVoice(trimmed.isEmpty ? nil : trimmed,
                                                 forProviderID: providerID)
        await refreshTTSVoices()
    }

    // MARK: - Per-provider TTS model override

    /// Refresh `ttsCustomModels` from `SettingsManager`. One actor hop per
    /// registered TTS provider (mirrors `refreshTTSVoices` / `refreshCustomModels`).
    /// Empty/absent overrides are omitted so the View's binding falls back to
    /// the placeholder default.
    func refreshTTSCustomModels() async {
        var next: [String: String] = [:]
        for provider in TTSProvider.allRegistered {
            if let model = await SettingsManager.shared.getTTSCustomModel(forProviderID: provider.id),
               !model.isEmpty {
                next[provider.id] = model
            }
        }
        ttsCustomModels = next
    }

    /// Persist a per-provider TTS MODEL override. Sanitizes the candidate to
    /// `^[A-Za-z0-9._-]+$` via the SHARED STT `sanitizeModelTag` (the Gemini
    /// URL-path-injection guard — Gemini TTS also rides the model in the URL).
    /// An empty / fully-stripped candidate clears the override (the provider's
    /// pinned `model` applies). Refreshes `ttsCustomModels` so the field
    /// re-renders without a KVS round-trip. Mirrors `saveCustomModel(_:for:)`.
    func saveTTSCustomModel(_ model: String, for providerID: String) async {
        // Body-model providers (OpenRouter et al.) keep `/`; URL-path models
        // (Gemini `.generateContent`) strip it — see `TTSProvider.modelInURL`.
        let sanitized = Self.sanitizeModelTag(model, allowsSlash: !TTSProvider.lookup(id: providerID).modelInURL)
        await SettingsManager.shared.setTTSCustomModel(sanitized.isEmpty ? nil : sanitized,
                                                       forProviderID: providerID)
        await refreshTTSCustomModels()
    }

    // MARK: - Custom TTS model

    /// Persist a named custom endpoint's TTS model (e.g. `tts-1`, `kokoro`). An
    /// empty / whitespace-only candidate clears it (the `"tts-1"` default
    /// applies). Reflects the trimmed value back into `customTTSModels[uuid]` so
    /// the field re-renders without a KVS round-trip. The URL/key/cert/auth are
    /// shared with custom STT — only this model (and the voice) are TTS-specific.
    func saveCustomTTSModel(_ model: String, for uuid: UUID) async {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        await SettingsManager.shared.setCustomTTSModel(trimmed.isEmpty ? nil : trimmed, for: uuid)
        customTTSModels[uuid] = trimmed
    }

    // MARK: - Preview ("Speak a sample")

    /// Speak a short sample through the given TTS provider so the user can audit
    /// the voice before committing. Resolves the SHARED key + the selected voice
    /// in-actor, then hands off to the other agent's `ReplyVoice.previewSample`.
    /// The key is NEVER surfaced. Sets `.checking` while in flight → `.valid`
    /// on a played sample, or `.invalid(message:)` on a cloud synth error.
    ///
    /// Unlike the chat read-aloud path, the PREVIEW fails LOUD: a cloud synth
    /// error does NOT silently fall back to Apple — so a misconfigured voice/key
    /// surfaces in the red footer instead of cheerfully speaking Apple. The
    /// `.failure` payload is mapped to a preview-appropriate, KEY-FREE message
    /// (we never reuse `ttsSynthesisFailed.errorDescription`, whose "…Using the
    /// built-in voice." copy is the chat-fallback wording and is wrong here, nor
    /// do we surface the provider's error body). The Apple provider previews
    /// via the synthesizer (nil key) and always reports `.valid`.
    func previewTTS(for providerID: String) async {
        ttsPreviewStates[providerID] = .checking

        // ONE atomic actor hop resolves provider / key / typed key-state / voice /
        // model / custom-config from the STORE. This replaces the old multi-read
        // path (the VM's `ttsVoices` / `ttsCustomModels` caches + a separate
        // `getAPIKey` + `customTTSConfig` call), which could diverge from the store
        // — a cache holding a value the store hasn't hydrated, or vice versa. The
        // preview must audit what the store will ACTUALLY use, so it reads the
        // store, not the caches.
        let snapshot = await SettingsManager.shared.ttsSnapshot(forProviderID: providerID)

        // PREFLIGHT — a cloud provider that REQUIRES a key but has none available
        // on this device fails LOUD here rather than calling `previewSample` (which
        // would silently synth the Apple voice and report success — the old
        // false-green). The snapshot returns `.notRequired` for the Apple sentinel
        // and a keyless custom endpoint, so only `.missing` / `.unreadable` gate.
        switch snapshot.keyState {
        case .missing, .unreadable:
            let message = snapshot.keyState == .missing
                ? String(
                    localized: "settings.voice.tts.preview.error.keyMissing",
                    defaultValue: "No API key for this provider is available on this device yet — paste it in the key field, or wait for iCloud Keychain to finish syncing."
                )
                : String(
                    localized: "settings.voice.tts.preview.error.keyUnreadable",
                    defaultValue: "The key couldn't be read from the Keychain right now — unlock the device and try again."
                )
            // Forensic ring: the preflight failure (previewSample is never called,
            // so it records nothing here — this is the ONE external record site).
            TTSOutcomeLog.shared.record(
                surface: .preview,
                stage: .key,
                outcome: .failedLoud,
                errorCode: nil,
                keyState: snapshot.keyState,
                configSignature: TTSOutcomeLog.configSignature(for: snapshot)
            )
            ttsPreviewStates[providerID] = .invalid(message: message)
            return
        case .present, .notRequired:
            break
        }

        // Hand off to the boundary the other agent owns. `previewSample` plays a
        // short clip (cloud → fetch+play; Apple/no-key → synth) and reports the
        // OUTCOME exactly once: `.success` on a played sample, `.failure(error)`
        // when a cloud synth throws (it does NOT silently fall back to Apple in
        // the preview path). Bridge that single outcome into the row's state.
        #if os(macOS)
        // A sample preview is user-initiated speech — silence the other macOS
        // speakers (a playing thread bubble) before it starts. `claim` excludes
        // the claimant, and `previewSample` itself supersedes any in-flight
        // turn on the shared instance.
        SpeechExclusivity.shared.claim(ReplyVoice.shared)
        #endif
        let outcome: Result<Void, AppError> = await withCheckedContinuation { continuation in
            ReplyVoice.shared.previewSample(
                providerID: providerID,
                voice: snapshot.voice,
                customModel: snapshot.customModel,
                apiKey: snapshot.apiKey,
                customConfig: snapshot.customConfig
            ) { result in
                continuation.resume(returning: result)
            }
        }

        switch outcome {
        case .success:
            ttsPreviewStates[providerID] = .valid
        case .failure(let error):
            ttsPreviewStates[providerID] = .invalid(message: Self.previewFailureMessage(for: error))
        }
    }

    /// Preview the custom endpoint's TTS from the EDITOR BUFFERS (no persist) —
    /// the buffer-until-Save companion to `previewTTS`. Builds the synthesis
    /// config from the per-uuid buffers (URL / model / auth / cert) + the explicit
    /// `voice` (the editor's `pendingTTSVoice` @State) so "Speak a sample" auditions
    /// exactly what's on screen even on a never-saved draft. The key comes from the
    /// SecureField buffer (`typedKey`) when present, else the stored slot — so a
    /// keyed endpoint with no fresh paste still auditions. Nothing here touches
    /// storage. Fails LOUD (no silent Apple fallback) like `previewTTS`.
    ///
    /// Privacy: `typedKey` / the resolved stored key flow only into `previewSample`;
    /// never logged, never surfaced.
    func previewCustomTTSFromBuffers(for uuid: UUID, voice: String, typedKey: String) async {
        let providerID = TTSProvider.customEndpointID(for: uuid)
        ttsPreviewStates[providerID] = .checking

        // Build the synthesis URL from the BUFFER base URL (may be unsaved). Fail
        // LOUD on an empty/invalid URL with a friendly, specific message rather
        // than silently substituting Apple — matches the always-tappable contract.
        let trimmedURL = (customSTTURLStrings[uuid] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedURL.isEmpty,
              let base = URL(string: trimmedURL),
              base.scheme?.lowercased() == "https" else {
            ttsPreviewStates[providerID] = .invalid(message: String(
                localized: "settings.stt.custom.url.invalid",
                defaultValue: "Enter the full endpoint URL including https://."
            ))
            return
        }
        let speechURL = base.appending(path: "v1/audio/speech")

        let auth = customSTTAuthSchemes[uuid] ?? .bearer
        let trimmedFingerprint = (customSTTCertFingerprints[uuid] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let model = (customTTSModels[uuid] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let config = CustomTTSConfig(
            url: speechURL,
            model: model.isEmpty ? "tts-1" : model,
            auth: auth,
            certFingerprint: trimmedFingerprint.isEmpty ? nil : trimmedFingerprint
        )

        // Resolve the key: a freshly-typed key wins; else the TYPED stored-slot
        // read (so a locked-Keychain slot reads as `.unreadable`, not "missing" —
        // the exact distinction the typed primitive exists for); `.none` auth
        // needs none.
        var apiKey: String? = nil
        var storedKeyState: APIKeyState = .notRequired
        if auth != .none {
            let typed = typedKey.trimmingCharacters(in: .whitespacesAndNewlines)
            if !typed.isEmpty {
                apiKey = typed
                storedKeyState = .present
            } else {
                switch await SettingsManager.shared.apiKeyReadResult(
                    forPresetID: STTProvider.customEndpointID(for: uuid)
                ) {
                case .present(let key):
                    apiKey = key
                    storedKeyState = .present
                case .missing:
                    storedKeyState = .missing
                case .unreadable:
                    storedKeyState = .unreadable
                }
            }
        }

        let trimmedVoice = voice.trimmingCharacters(in: .whitespacesAndNewlines)

        // PREFLIGHT — a KEYED custom endpoint (`auth != .none`) with no resolvable
        // key (neither the typed buffer nor a stored slot) fails LOUD rather than
        // calling `previewSample`, which would silently synth Apple and false-pass.
        // Keyless (`auth == .none`) endpoints are exempt (nothing to miss). The
        // signature is built from the BUFFER config the preview would actually use.
        if auth != .none, storedKeyState != .present {
            TTSOutcomeLog.shared.record(
                surface: .preview,
                stage: .key,
                outcome: .failedLoud,
                errorCode: nil,
                keyState: storedKeyState,
                configSignature: TTSOutcomeLog.configSignature(
                    providerID: providerID,
                    voice: trimmedVoice.isEmpty ? nil : trimmedVoice,
                    customModel: nil,
                    customConfig: config
                )
            )
            let message = storedKeyState == .unreadable
                ? String(
                    localized: "settings.voice.tts.preview.error.keyUnreadable",
                    defaultValue: "The key couldn't be read from the Keychain right now — unlock the device and try again."
                )
                : String(
                    localized: "settings.voice.tts.preview.error.keyMissing",
                    defaultValue: "No API key for this provider is available on this device yet — paste it in the key field, or wait for iCloud Keychain to finish syncing."
                )
            ttsPreviewStates[providerID] = .invalid(message: message)
            return
        }
        #if os(macOS)
        // Same arbitration as `previewTTS`: user-initiated preview silences the
        // other macOS speakers before it starts.
        SpeechExclusivity.shared.claim(ReplyVoice.shared)
        #endif
        let outcome: Result<Void, AppError> = await withCheckedContinuation { continuation in
            ReplyVoice.shared.previewSample(
                providerID: providerID,
                voice: trimmedVoice.isEmpty ? nil : trimmedVoice,
                customModel: nil,
                apiKey: apiKey,
                customConfig: config
            ) { result in
                continuation.resume(returning: result)
            }
        }

        switch outcome {
        case .success:
            ttsPreviewStates[providerID] = .valid
        case .failure(let error):
            ttsPreviewStates[providerID] = .invalid(message: Self.previewFailureMessage(for: error))
        }
    }

    /// Map a preview `AppError` to a preview-context, KEY-FREE message for the
    /// red footer. Four buckets: a 401/403 auth/scope rejection points at the KEY
    /// (the common ElevenLabs "speech_to_text-only key" trap surfaces here);
    /// a 402/429 rate-limit/quota points at the account's credit (OpenAI's
    /// `insufficient_quota` lands here, NOT under "check your connection");
    /// synthesis / empty-audio errors point at the voice field; transport /
    /// timeout errors point at connectivity. Never reuses the chat-fallback
    /// `errorDescription` ("…Using the built-in voice.") and never surfaces the
    /// provider's error body.
    private static func previewFailureMessage(for error: AppError) -> String {
        switch error {
        case .ttsProviderUnreachable, .requestTimeout, .noInternetConnection,
             .remoteAgentUnreachable, .remoteAgentTimeout, .networkError,
             .persistentNetworkFailure:
            return String(
                localized: "settings.voice.tts.preview.error.unreachable",
                defaultValue: "Couldn't reach the voice provider — check your connection."
            )
        case .ttsUnauthorized:
            return String(
                localized: "settings.voice.tts.preview.error.unauthorized",
                defaultValue: "This provider rejected the key for text-to-speech — check the key's permissions (ElevenLabs keys need a text-to-speech scope)."
            )
        case .ttsRateLimited:
            return String(
                localized: "settings.voice.tts.preview.error.rateLimited",
                defaultValue: "This provider is rate-limited or out of quota — top up the account's credit, or try again shortly."
            )
        case .ttsContentBlocked:
            return String(
                localized: "settings.voice.tts.preview.error.contentBlocked",
                defaultValue: "The provider's safety filter blocked this text — try different wording."
            )
        case .ttsCustomEndpointNotConfigured:
            return String(
                localized: "settings.voice.tts.preview.error.endpointNotConfigured",
                defaultValue: "Set your custom endpoint URL first (in the Speech-to-Text section above)."
            )
        case .ttsCustomCertMismatch:
            // The shared refusal + remedy, verbatim. The preview is one of the
            // few places a mismatch surfaces, so it carries the whole verdict —
            // the bare "didn't match" it replaced named neither the risk nor a
            // next step.
            return CertificateTrustCopy.pinMismatchRefusalWithRemedy
        case .ttsCustomCertUntrusted:
            // The shared refusal + remedy, verbatim — the preview must not
            // invent a shorter story for the one failure the user cannot fix
            // from this screen.
            return CertificateTrustCopy.untrustedRefusalWithRemedy
        case .ttsCustomCertKeyUnpinnable:
            // The shared refusal + remedy, verbatim, and its OWN arm: the
            // fallback below blames the voice name for a failure that never
            // reached synthesis, and the mismatch arm above would warn about
            // interception on a chain this device trusted. Only the digest could
            // not be computed.
            return CertificateTrustCopy.keyUnpinnableRefusalWithRemedy
        default:
            // ttsSynthesisFailed / ttsEmptyAudio and any other terminal — the
            // most likely cause in preview is a wrong voice name/ID.
            return String(
                localized: "settings.voice.tts.preview.error.synthesis",
                defaultValue: "Couldn't synthesize — check the voice name or ID for this provider."
            )
        }
    }

    // MARK: - Active-TTS display + summary

    /// Display name of the currently-active TTS provider — drives the
    /// voice-summary line. Resolves via the vendor registry (so "OpenAI", not
    /// "openai-tts"); falls back to "Apple" on an unknown id.
    var activeTTSProviderDisplayName: String {
        VoiceVendorRegistry.vendor(forTTSProviderID: activeTTSProviderID, customEndpoints: customVoiceEndpoints)?.displayName
            ?? VoiceVendorRegistry.apple.displayName
    }

    /// Short name of the active STT provider (e.g. "Apple", not
    /// "Apple (On-Device)") for the compact summaries. Falls back to the full
    /// STT display name if no vendor matches the active preset.
    private var activeSTTShortName: String {
        VoiceVendorRegistry.vendor(forSTTPresetID: activePresetID, customEndpoints: customVoiceEndpoints)?.shortDisplayName
            ?? activeProviderDisplayName
    }

    /// Short name of the active TTS provider for the compact summaries.
    private var activeTTSShortName: String {
        VoiceVendorRegistry.vendor(forTTSProviderID: activeTTSProviderID, customEndpoints: customVoiceEndpoints)?.shortDisplayName
            ?? VoiceVendorRegistry.apple.shortDisplayName
    }

    /// Short summary for the Settings root "Voice" row trailing status:
    /// "OpenAI · ElevenLabs" (STT provider · TTS provider). Short names keep it
    /// from truncating at iPhone width.
    var voiceSummaryShort: String {
        "\(activeSTTShortName) · \(activeTTSShortName)"
    }
}
