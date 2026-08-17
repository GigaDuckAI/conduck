// SPDX-License-Identifier: Apache-2.0

// Conduck
// TTSSnapshot.swift
//
// The atomic TTS resolution value types (iOS / macOS target; the Watch reads
// its state second-hand from the broadcast envelope and never builds these).
//
// `TTSSnapshot` replaces the old five-field tuple that `activeTTSSnapshot()`
// returned: with the typed key state joining the resolution, a struct makes
// the key/key-state invariant explicit (`apiKey` is non-nil IFF `keyState ==
// .present`) and keeps the seam fakes honest. BOTH fields derive from ONE
// Keychain read — never two reads that could tear against a concurrent
// change.
//
// The typed key state this snapshot carries (`APIKeyReadResult` /
// `APIKeyState`) is declared in `Services/Storage/APIKeyReadResult.swift` —
// beside the storage seam, because the Watch target reads its own Keychain
// through the same classifier and links none of this file.

import Foundation

// MARK: - Atomic TTS snapshot

/// One provider's fully-resolved TTS configuration, resolved in a SINGLE
/// `SettingsManager` actor hop so provider / key / key-state / voice / model /
/// custom-config can never tear against a concurrent settings change.
/// INVARIANT: `apiKey != nil` ⇔ `keyState == .present` (both fields derive
/// from one `APIKeyReadResult`).
struct TTSSnapshot: Sendable {
    let providerID: String
    let apiKey: String?
    let keyState: APIKeyState
    let voice: String?
    let customModel: String?
    let customConfig: CustomTTSConfig?
}
