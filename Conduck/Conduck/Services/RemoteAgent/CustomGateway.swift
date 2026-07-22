// Conduck
// CustomGateway.swift
//
// Custom-gateways. The persisted ROSTER record for one user-defined custom
// OpenAI-compatible gateway. Only `id` + `name` + `model` + badge fields
// live here (the registry JSON under `Constants.customGatewaysRegistryKey`,
// App-Group + iCloud-KVS dual-write); the URL / bearer token / cert
// fingerprint ride the SAME per-ref slots as the built-ins
// (`SettingsManager.getRemoteAgentURL(for:)` etc.) — i.e. the built-in
// storage posture, extended. See `spec.md "Settings & Storage"`.
//
// Pure value type — shared by the app AND Watch targets (Approach A
// membership exception in project.pbxproj).

import Foundation

/// One user-defined custom gateway's roster entry. URL/token/cert are NOT
/// here — they live in the per-ref storage slots keyed by `ref`.
struct CustomGateway: Codable, Sendable, Identifiable, Hashable {
    let id: UUID
    /// User-given label. Required at save. Drives the picker label + the
    /// default Watch/CarPlay badge monogram.
    var name: String
    /// Optional model name sent as the `"model"` field. Nil → omit (gateway
    /// default, identical to built-ins). Required by servers like vLLM/Ollama.
    var model: String?
    /// Badge color palette key (`RemoteAgentBadgePalette`). Nil → auto-assign
    /// the next unused palette slot at create time.
    var colorID: String?
    /// Badge monogram (1–2 chars). Nil → derive from `name`.
    var monogram: String?

    init(id: UUID, name: String, model: String? = nil, colorID: String? = nil, monogram: String? = nil) {
        self.id = id
        self.name = name
        self.model = model
        self.colorID = colorID
        self.monogram = monogram
    }

    var ref: RemoteAgentRef { .custom(id) }
}
