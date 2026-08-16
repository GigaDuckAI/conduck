// SPDX-License-Identifier: Apache-2.0

// Conduck
// VoiceVendor.swift
//
// Cloud voice vendors — the merged "Voice" Settings display layer. Both
// directions ship across the vendors listed below, with Apple's on-device
// engine as the default and the fallback; `VoiceCapabilityStatus.coming`
// marks the per-direction exceptions, so a vendor's presence here is not
// evidence that both of its directions are live.
//
// A `VoiceVendor` GROUPS the two existing registries (STT + TTS) WITHOUT
// duplicating them: one row per vendor, ONE API key per vendor serving BOTH
// directions (speech-to-text AND text-to-speech), each direction with its own
// independent capability status. The user picks an active STT provider AND an
// active TTS provider independently; both reads the SAME Keychain slot.
//
// Migration-safe by construction: `sharedKeychainAccount` resolves to the
// EXISTING `stt.apiKey.<sttPresetID>` slot for every current vendor — there is
// NO new Keychain account and ZERO migration. Display copy (name / console URL
// / placeholder / language note) still comes from `STTProviderMetadata`; this
// type adds only the grouping + the per-direction capability statuses.
//
// iOS / macOS ONLY (display layer) — NOT the Watch target. The Watch's
// downstream-only posture never renders the vendor catalog (mirrors
// `STTProviderMetadata`'s scope).
//
// The vendor `id` is UI-only (drives `ForEach` identity + `navigationDestination`
// keying) — it is NOT a locked wire identifier. The LOCKED ids are the underlying
// `sttPresetID` (Keychain slot) + `ttsProviderID` (KVS active-TTS value).

import Foundation

/// Per-direction availability of a voice capability for a vendor.
enum VoiceCapabilityStatus: Sendable, Equatable {
    /// Shipped in v1 — the user can configure + activate this direction.
    case available
    /// Planned but not shipped — render a disabled "Soon" pill / "coming soon"
    /// row (Qwen TTS).
    case coming
    /// The vendor has no row for this direction at all (e.g. the custom
    /// OpenAI-compatible endpoint exposes no cloud TTS).
    case none
}

/// A voice vendor — the merged STT + TTS row in the unified "Voice" Settings
/// category. Value type; held only as `static let` registry entries.
struct VoiceVendor: Identifiable, Sendable {
    /// UI-only list / nav identity. NOT a locked wire id — see file header.
    let id: String

    /// Vendor display name (pulled from `STTProviderMetadata` at registration).
    let displayName: String

    /// The vendor's STT preset id (matches `STTProvider.id`), or nil if the
    /// vendor exposes no STT row. Every current vendor has one.
    let sttPresetID: String?

    /// The vendor's TTS provider id (matches `TTSProvider.id`), or nil if the
    /// vendor exposes no TTS row (Gemini / Qwen / Custom in v1).
    let ttsProviderID: String?

    /// Whether this vendor's STT direction is shippable in v1.
    let sttStatus: VoiceCapabilityStatus

    /// Whether this vendor's TTS direction is shippable in v1.
    let ttsStatus: VoiceCapabilityStatus

    /// On-device transport flag (Apple). Drives the "Local · offline" subtitle
    /// + the Apple model-lifecycle branch in the detail view.
    let isOnDevice: Bool

    /// The EXISTING Keychain account slot that holds this vendor's API key —
    /// the SAME `stt.apiKey.<sttPresetID>` slot the vendor's STT already uses.
    /// Cloud TTS reads this same slot (one key per vendor, both directions).
    /// Force-unwraps `sttPresetID` because every cloud vendor with a key field
    /// has an STT preset; Apple (no key) never calls this.
    var sharedKeychainAccount: String {
        Constants.sttApiKeyKeychainAccount(for: sttPresetID!)
    }

    /// Short display name for the compact summary line / root-row trailing
    /// status, where the full "Apple (On-Device)" overflows. Strips the
    /// "(On-Device)" qualifier (only Apple carries one); every cloud vendor's
    /// `displayName` is already short ("OpenAI", "ElevenLabs", …).
    var shortDisplayName: String {
        displayName.replacingOccurrences(of: " (On-Device)", with: "")
    }

    /// Display metadata for this vendor's STT side (name / console URL /
    /// placeholder / language note / quirk). Resolved from the STT registry so
    /// the merged layer never duplicates copy. Nil only if `sttPresetID` is nil.
    var sttMetadata: STTProviderMetadata? {
        sttPresetID.flatMap { STTProviderRegistry.lookup(id: $0) }
    }
}

/// The unified vendor registry for the merged "Voice" Settings category.
/// Apple FIRST (the recommended default, mirrors `STTProviderRegistry.all`).
enum VoiceVendorRegistry {

    /// Apple on-device — STT via `SpeechAnalyzer`, TTS via `AVSpeechSynthesizer`.
    /// Both keyless, both the platform default + offline fallback.
    static let apple = VoiceVendor(
        id: "apple",
        displayName: STTProviderRegistry.appleOnDevice.displayName,
        sttPresetID: "apple-on-device",
        ttsProviderID: "apple-tts",
        sttStatus: .available,
        ttsStatus: .available,
        isOnDevice: true
    )

    /// OpenAI — STT `gpt-4o-transcribe`, TTS `gpt-4o-mini-tts`. One key.
    static let openAI = VoiceVendor(
        id: "openai",
        displayName: STTProviderRegistry.openAI.displayName,
        sttPresetID: "openai-gpt4o-transcribe",
        ttsProviderID: "openai-tts",
        sttStatus: .available,
        ttsStatus: .available,
        isOnDevice: false
    )

    /// Mistral — STT Voxtral, TTS `voxtral-mini-tts-2603`. One key.
    static let mistral = VoiceVendor(
        id: "mistral",
        displayName: STTProviderRegistry.mistralVoxtral.displayName,
        sttPresetID: "mistral-voxtral",
        ttsProviderID: "mistral-tts",
        sttStatus: .available,
        ttsStatus: .available,
        isOnDevice: false
    )

    /// ElevenLabs — STT Scribe v2, TTS Flash v2.5. One key.
    static let elevenLabs = VoiceVendor(
        id: "elevenlabs",
        displayName: STTProviderRegistry.elevenLabs.displayName,
        sttPresetID: "elevenlabs-scribe-v2",
        ttsProviderID: "elevenlabs-tts",
        sttStatus: .available,
        ttsStatus: .available,
        isOnDevice: false
    )

    /// Gemini — STT + TTS both shipped on one key. TTS via
    /// `gemini-3.1-flash-tts-preview` (`gemini-tts`): the user pastes one Gemini
    /// key for speech-to-text and gets text-to-speech from the same vendor, zero
    /// extra setup. Renders the active voice-field + "Speak a sample" TTS UI.
    static let gemini = VoiceVendor(
        id: "gemini",
        displayName: STTProviderRegistry.gemini.displayName,
        sttPresetID: "gemini-3-1-flash-lite",
        ttsProviderID: "gemini-tts",
        sttStatus: .available,
        ttsStatus: .available,
        isOnDevice: false
    )

    /// OpenRouter — STT + TTS on one key, shareable with the OpenRouter
    /// hosted-model gateway. STT via `/v1/audio/transcriptions` (JSON+base64),
    /// TTS via `/v1/audio/speech` (OpenAI-compatible). Both directions available.
    static let openRouter = VoiceVendor(
        id: "openrouter",
        displayName: STTProviderRegistry.openRouter.displayName,
        sttPresetID: "openrouter-stt",
        ttsProviderID: "openrouter-tts",
        sttStatus: .available,
        ttsStatus: .available,
        isOnDevice: false
    )

    /// Qwen — STT available; TTS not shipped in v1 (DashScope-native, regional
    /// focus). Renders a "coming soon" TTS row.
    static let qwen = VoiceVendor(
        id: "qwen",
        displayName: STTProviderRegistry.qwen.displayName,
        sttPresetID: "qwen3-asr-flash",
        ttsProviderID: nil,
        sttStatus: .available,
        ttsStatus: .coming,
        isOnDevice: false
    )

    /// UI-id prefix for a per-endpoint custom voice vendor: `custom_<uuid>`.
    /// (NOT a wire id — only `sttPresetID` / `ttsProviderID` are locked.) Reused
    /// for the route parse (`customVendorUUID(from:)`).
    static let customVendorPrefix = "custom_"

    /// Build a per-endpoint custom vendor from a roster record. Display name =
    /// the user's endpoint name; per-uuid `sttPresetID` / `ttsProviderID`; UI id
    /// `custom_<uuid>`. Both directions available (one server, both directions).
    static func customVendor(for endpoint: CustomVoiceEndpoint) -> VoiceVendor {
        VoiceVendor(
            id: customVendorPrefix + endpoint.id.uuidString.lowercased(),
            displayName: endpoint.name,
            sttPresetID: endpoint.sttPresetID,
            ttsProviderID: endpoint.ttsProviderID,
            sttStatus: .available,
            ttsStatus: .available,
            isOnDevice: false
        )
    }

    /// Extract the endpoint uuid from a per-endpoint custom vendor UI id
    /// (`custom_<uuid>`). Nil for a built-in vendor id (`apple` / `openai` / …).
    static func customVendorUUID(from vendorID: String) -> UUID? {
        guard vendorID.hasPrefix(customVendorPrefix) else { return nil }
        return UUID(uuidString: String(vendorID.dropFirst(customVendorPrefix.count)))
    }

    /// The frozen built-in vendors (Apple first — recommended default). 5
    /// entries (Qwen unlisted). The custom endpoints are appended dynamically by
    /// `vendors(customEndpoints:)`.
    static let builtIns: [VoiceVendor] = [
        apple,
        openAI,
        mistral,
        elevenLabs,
        gemini,
        openRouter,
        // Qwen UNLISTED (pulled from the supported list — see
        // `STTProvider.allRegistered`). The `static let qwen` vendor is kept so
        // re-listing is a one-line revert.
    ]

    /// The full vendor list = built-ins + one vendor per named custom endpoint
    /// (in roster order, after the built-ins — mirrors the single custom's old
    /// trailing position). Pass the cached roster from the view-model so this
    /// stays a pure function (no actor hop in `body`).
    static func vendors(customEndpoints: [CustomVoiceEndpoint]) -> [VoiceVendor] {
        builtIns + customEndpoints.map(customVendor(for:))
    }

    /// Reverse lookup: the vendor owning a given STT preset id, roster-aware. A
    /// per-uuid custom preset id resolves to its named endpoint vendor; a
    /// built-in id resolves from `builtIns`. Nil for an unknown id.
    static func vendor(forSTTPresetID presetID: String, customEndpoints: [CustomVoiceEndpoint]) -> VoiceVendor? {
        vendors(customEndpoints: customEndpoints).first(where: { $0.sttPresetID == presetID })
    }

    /// Reverse lookup: the vendor owning a given TTS provider id, roster-aware.
    /// Nil for an unknown id or a TTS-less vendor.
    static func vendor(forTTSProviderID providerID: String, customEndpoints: [CustomVoiceEndpoint]) -> VoiceVendor? {
        vendors(customEndpoints: customEndpoints).first(where: { $0.ttsProviderID == providerID })
    }

    /// Look up a vendor by its UI id, roster-aware. A `custom_<uuid>` id resolves
    /// to its named endpoint vendor; a built-in id from `builtIns`. Nil for an
    /// unknown id (e.g. a deleted endpoint's stale route).
    static func lookup(id: String, customEndpoints: [CustomVoiceEndpoint]) -> VoiceVendor? {
        vendors(customEndpoints: customEndpoints).first(where: { $0.id == id })
    }
}
