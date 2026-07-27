// SPDX-License-Identifier: Apache-2.0

// Conduck
// AppleOnDeviceEngineMode.swift
//
// Which on-device Apple speech engine the single `apple-on-device` STT
// provider runs. ONE provider, two engines — chosen by this stored mode
// rather than a second registry entry (keeps the locked 7-provider
// registry + Keychain account map untouched).
//
//   .dictation   — iOS 26 `DictationTranscriber`, the standard keyboard-
//                  dictation engine. Shares the system dictation model, so
//                  the user's primary language is near-always already
//                  installed (no download) and it runs on a WIDE device
//                  range (no A16 floor). This is the DEFAULT: the mic "just
//                  works" on first tap.
//   .highQuality — iOS 26 `SpeechTranscriber`, the higher-accuracy model.
//                  Needs a one-time per-language download (AssetInventory)
//                  and an A16+ device (`SpeechTranscriber.isAvailable`).
//                  Opt-in only, from Settings → Voice → Apple.
//
// Plain enum (NO `#if os` guard): `SettingsManager` reads/writes it on every
// target, while only the non-watch `AppleSpeechRunner` maps it to a concrete
// transcriber. Raw values are PERSISTED (App-Group defaults + iCloud KVS) —
// treat them as LOCKED storage literals.
enum AppleOnDeviceEngineMode: String, Sendable, Equatable, CaseIterable {
    case dictation
    case highQuality

    /// Engine for a fresh install / any unset value.
    static let `default`: AppleOnDeviceEngineMode = .dictation

    /// Lenient decode of a persisted raw value → `.default` on nil/garbage,
    /// so a corrupt KVS write can never dead-end voice input.
    static func fromStored(_ raw: String?) -> AppleOnDeviceEngineMode {
        guard let raw, let mode = AppleOnDeviceEngineMode(rawValue: raw) else {
            return .default
        }
        return mode
    }

    /// The engine the device can ACTUALLY run, clamping a `.highQuality` choice
    /// down to `.dictation` when the high-quality `SpeechTranscriber` is
    /// unavailable (sub-A16). Mirrors the inline clamp in
    /// `AppleSpeechRunner.transcribe(...engine:)` so UI readiness, the install /
    /// readiness probes, the Try-voice gate, and the active-row checkmark all
    /// agree with what the runner will actually transcribe with. Pure (no Speech
    /// symbols) → callable on every target and unit-testable without hardware.
    /// NEVER applied to the PERSISTED/KVS raw value — sync stays verbatim so a
    /// capable device's `.highQuality` choice isn't clobbered by a sub-A16 peer.
    static func effectiveEngine(
        requested: AppleOnDeviceEngineMode,
        hqAvailable: Bool
    ) -> AppleOnDeviceEngineMode {
        (requested == .highQuality && !hqAvailable) ? .dictation : requested
    }
}
