// SPDX-License-Identifier: Apache-2.0

// Conduck
// TTSKeyArrivalMonitor.swift
//
// The ACTIVE TTS PROVIDER as a subject `KeyArrivalMonitor` can poll: the
// secret-free probe, plus its projection into the monitor's erased reading.
//
// The polling itself — the foreground-only window, the finite backoff, the
// single post on a timer-discovered arrival — lives in `KeyArrivalMonitor.swift`
// and is shared with the default-gateway subject. Its bounds are locked by
// design review; do not re-implement them here.
//
// Why this subject needs it: iCloud Keychain delivers a synced key
// opportunistically and posts no app-visible arrival event, so a device whose
// active cloud voice is still waiting on its key has nothing to converge on.
// Chat silently speaks Apple in the meantime (the never-go-silent contract), and
// the Watch, fed second-hand from this phone, does the same — until the user
// happens to touch Settings.

import Foundation

// MARK: - Probe value type

/// Device-local key availability of the ACTIVE TTS provider — the SECRET-FREE
/// projection of `SettingsManager.activeTTSSnapshot()` that the key-readiness
/// banner and this monitor consume. `keyState` speaks ONLY to local credential
/// availability (`.present` does not claim the provider works).
struct ActiveTTSKeyProbe: Sendable, Equatable {
    let providerID: String
    /// The shared `stt.apiKey.<presetID>` slot the provider reads — nil when
    /// no key is required. Part of the monitor's requirement fingerprint.
    let keySlotID: String?
    let keyState: APIKeyState

    /// The two states bounded polling can actually repair: a key that hasn't
    /// arrived yet, or one the Keychain couldn't return (locked
    /// pre-first-unlock is a legitimate transient per the
    /// `kSecAttrAccessibleAfterFirstUnlock` contract).
    var isDegraded: Bool { keyState == .missing || keyState == .unreadable }
}

extension ActiveTTSKeyProbe {
    /// This probe as the erased reading `KeyArrivalMonitor` polls.
    ///
    /// The requirement key pairs the provider with the key slot it reads: a poll
    /// window survives only while the SAME provider needs the SAME slot, so
    /// switching voices — or switching to a keyless one — retires it rather than
    /// leaving a window open on a question nobody is asking any more.
    ///
    /// The empty string marks "keyless", which is unambiguous because a real slot
    /// is always `stt.apiKey.<presetID>`; `providerID` is a registry id and
    /// carries no `|`. See `KeyArrivalProbeReading` on why a composed key owes
    /// that.
    var arrivalReading: KeyArrivalProbeReading {
        let reading: KeyArrivalReading
        switch keyState {
        case .present: reading = .arrived
        case .notRequired: reading = .notRequired
        case .missing, .unreadable: reading = .degraded
        }
        return KeyArrivalProbeReading(
            requirementKey: "tts:\(providerID)|\(keySlotID ?? "")",
            reading: reading
        )
    }
}
