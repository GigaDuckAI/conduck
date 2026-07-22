// Conduck
// STTBroadcastEnvelope.swift
//
// Atomic WCSession payload carrying { active preset ID, API key,
// monotonic timestamp } from iPhone → Watch. The envelope is the ONLY
// source of Watch STT state — `applicationContext` does not carry
// `sttActivePresetIDKVSKey`, which eliminates the torn-read race between
// the fast applicationContext channel and the queued transferUserInfo
// channel.
//
// Monotonic `timestamp` lets the Watch discard older envelopes that
// arrive out of order after a queue drain.
//
// Wire shape: dictionary (`[String: Any]`) rather than JSON string,
// because WCSession requires Plist-compatible top-level values. All
// fields use Plist-native types (String / TimeInterval).

import Foundation

/// Atomic STT-state envelope sent via `WCSession.transferUserInfo`.
struct STTBroadcastEnvelope: Codable, Sendable {
    /// Active preset ID (matches `STTProvider.id`).
    let presetID: String

    /// API key for the active preset. Optional — providers that need no
    /// auth (Apple on-device) broadcast with `nil` rather than an
    /// empty-string sentinel. Crosses the device
    /// boundary only via this envelope; never logged.
    let apiKey: String?

    /// Optional per-preset custom model override (Feature 1 — Custom STT).
    /// Nil = the provider's pinned default model. Like `apiKey`, omitted from
    /// the encoded dict entirely when nil (forward/back-compat: an older Watch
    /// build that never reads this key is unaffected; a newer iOS build that
    /// adds it doesn't break an older decode). Never logged.
    let customModel: String?

    // MARK: - TTS fields (cloud Text-to-Speech)
    //
    // Additive, omit-when-nil — SAME pattern as `customModel`. The active TTS
    // provider + its shared API key + the optional voice override ride the SAME
    // atomic envelope as the STT triple (resolved from `activeTTSSnapshot()` in
    // the same actor hop), so the Watch never observes a torn STT/TTS state.
    // Back-compat: legacy dicts with no TTS keys decode fine with nil TTS
    // fields; an older Watch build that never reads them is unaffected.

    /// Active TTS provider id (matches `TTSProvider.id`). Nil = no TTS state in
    /// this envelope (legacy sender, or a sender pre-TTS-foundation). The Watch
    /// falls back to its own default (`apple-tts`) when nil.
    let ttsProviderID: String?

    /// The active TTS provider's API key — read from the SAME `stt.apiKey.<…>`
    /// slot the vendor's STT uses (one key, both directions). Nil for keyless
    /// Apple TTS. Crosses the device boundary only via this envelope; never
    /// logged.
    let ttsApiKey: String?

    /// Optional per-provider TTS voice override (`tts.voice.<id>`). Nil = the
    /// provider's pinned `defaultVoice`. Never logged.
    let ttsVoice: String?

    /// Optional per-provider TTS MODEL override (`tts.customModel.<id>`). Nil =
    /// the provider's pinned `model`. Same omit-when-nil / tolerant-decode
    /// treatment as `ttsVoice` — a legacy Watch build that never reads it is
    /// unaffected; the wrist sends the override (instead of `provider.model`)
    /// when present. Never logged.
    let ttsCustomModel: String?

    /// Monotonic sender-side timestamp (`Date().timeIntervalSince1970`).
    /// Watch persists the highest seen timestamp and discards any
    /// envelope with `timestamp <= lastEnvelopeTimestamp` — defeats
    /// out-of-order queue drains after wake.
    let timestamp: TimeInterval

    /// Explicit memberwise init with `customModel` + the TTS fields defaulting
    /// to nil — keeps the pre-Custom-STT and pre-TTS call sites (which pass only
    /// presetID/apiKey[/customModel]/timestamp) compiling as the new fields are
    /// additive. Coexists with the synthesized `Codable` conformance.
    init(
        presetID: String,
        apiKey: String?,
        customModel: String? = nil,
        ttsProviderID: String? = nil,
        ttsApiKey: String? = nil,
        ttsVoice: String? = nil,
        ttsCustomModel: String? = nil,
        timestamp: TimeInterval
    ) {
        self.presetID = presetID
        self.apiKey = apiKey
        self.customModel = customModel
        self.ttsProviderID = ttsProviderID
        self.ttsApiKey = ttsApiKey
        self.ttsVoice = ttsVoice
        self.ttsCustomModel = ttsCustomModel
        self.timestamp = timestamp
    }

    /// Plist-compatible dict for `WCSession.transferUserInfo`.
    /// Omits the `"apiKey"` key entirely when nil — keyless providers
    /// (Apple on-device) MUST NOT broadcast an empty string, which the
    /// decode path would round-trip as `Optional.some("")` rather than
    /// `nil` and trigger keyless-vs-empty drift on the Watch side.
    func encodedDict() -> [String: Any] {
        var dict: [String: Any] = [
            "presetID": presetID,
            "timestamp": timestamp,
        ]
        if let apiKey {
            dict["apiKey"] = apiKey
        }
        // Same keyless-omit pattern as `apiKey`: a nil override broadcasts no
        // `"customModel"` key at all, so an older Watch decode is unaffected.
        if let customModel {
            dict["customModel"] = customModel
        }
        // TTS fields ride the same omit-when-nil pattern — a legacy Watch decode
        // that never reads them is unaffected; a keyless / no-override TTS state
        // broadcasts no key rather than an empty-string sentinel.
        if let ttsProviderID {
            dict["ttsProviderID"] = ttsProviderID
        }
        if let ttsApiKey {
            dict["ttsApiKey"] = ttsApiKey
        }
        if let ttsVoice {
            dict["ttsVoice"] = ttsVoice
        }
        if let ttsCustomModel {
            dict["ttsCustomModel"] = ttsCustomModel
        }
        return dict
    }

    /// Decode from the `[String: Any]` payload received on the Watch side.
    /// Returns nil if a required field (`presetID`, `timestamp`) is missing
    /// or wrong-type — the receiver MUST treat nil as "ignore this envelope"
    /// rather than crashing (forward-compat with future schema additions).
    /// `apiKey` is optional — a missing or wrong-typed key yields `nil`
    /// rather than failing the whole decode (keyless-provider envelopes
    /// from iOS 26+ broadcast no `"apiKey"` key at all).
    static func decode(from dict: [String: Any]) -> STTBroadcastEnvelope? {
        guard
            let presetID = dict["presetID"] as? String,
            let timestamp = dict["timestamp"] as? TimeInterval
        else {
            return nil
        }
        let apiKey = dict["apiKey"] as? String  // nil if missing or wrong type
        // Tolerant optional — a missing or wrong-typed `customModel` yields nil
        // (the provider's pinned default applies) rather than failing the decode.
        let customModel = dict["customModel"] as? String
        // TTS fields: same tolerant `as? String` — a legacy dict (no TTS keys)
        // decodes fine with all three nil (the Watch falls back to its default
        // TTS provider).
        let ttsProviderID = dict["ttsProviderID"] as? String
        let ttsApiKey = dict["ttsApiKey"] as? String
        let ttsVoice = dict["ttsVoice"] as? String
        let ttsCustomModel = dict["ttsCustomModel"] as? String
        return STTBroadcastEnvelope(
            presetID: presetID,
            apiKey: apiKey,
            customModel: customModel,
            ttsProviderID: ttsProviderID,
            ttsApiKey: ttsApiKey,
            ttsVoice: ttsVoice,
            ttsCustomModel: ttsCustomModel,
            timestamp: timestamp
        )
    }
}
