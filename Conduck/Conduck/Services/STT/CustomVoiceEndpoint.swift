// SPDX-License-Identifier: Apache-2.0

// Conduck
// CustomVoiceEndpoint.swift
//
// Phase B — multiple named custom voice endpoints. The persisted ROSTER record
// for ONE user-defined custom OpenAI-compatible endpoint that serves STT and/or
// TTS on the SAME server (e.g. "Deepgram", "Whisper box"). Mirrors
// `CustomGateway` (the Personal AI custom-gateway roster record), minus the
// badge system — by locked decision these rows look IDENTICAL to built-in rows
// (plain circle + name + credential pill), so the record carries only `{id, name}`.
//
// The per-endpoint URL / key / cert / model / auth live in per-uuid storage
// slots keyed off the uuid (`Constants.customSTTURLKey(for:)` etc. +
// `stt.apiKey.<sttPresetID>`), NOT in this JSON — exactly the
// `CustomGateway` storage posture. The roster JSON (under
// `Constants.customVoiceEndpointsRegistryKey`) holds `{id, name}` only.
//
// Pure value type — shared by the app AND Watch targets (Approach A membership
// exception in project.pbxproj), like `CustomGateway` / `RemoteAgentRef`. The
// Watch never renders the roster (it only relays); membership keeps the type
// resolvable wherever `STTProvider` / `TTSProvider` synthesis is referenced.

import Foundation

/// One user-defined custom voice endpoint's roster entry. URL / key / cert /
/// model / auth are NOT here — they live in the per-uuid storage slots derived
/// from `id`. NO badge fields (locked decision: plain rows, no monogram).
struct CustomVoiceEndpoint: Codable, Sendable, Identifiable, Hashable {
    let id: UUID
    /// User-given label. Required at save. Drives the Voice-library row name +
    /// the per-endpoint vendor `displayName`.
    var name: String

    init(id: UUID, name: String) {
        self.id = id
        self.name = name
    }

    /// This endpoint's synthesized STT preset id (`custom-openai_<uuid>`) — the
    /// Keychain account suffix + `STTProvider.lookup(id:)` synthesis key.
    var sttPresetID: String { STTProvider.customEndpointID(for: id) }

    /// This endpoint's synthesized TTS provider id (`custom-openai-tts_<uuid>`)
    /// — the KVS active-TTS value + `TTSProvider.lookup(id:)` synthesis key.
    var ttsProviderID: String { TTSProvider.customEndpointID(for: id) }
}
