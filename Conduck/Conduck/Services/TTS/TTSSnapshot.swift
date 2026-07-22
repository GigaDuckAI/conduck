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
// `APIKeyReadResult` is the typed primitive the old `getAPIKey → String?`
// collapsed: a nil used to mean "no key" OR "Keychain couldn't answer",
// which made a temporarily-unreadable credential indistinguishable from a
// genuinely-missing one (the honest-degraded-state UI and the outcome ring
// both need the difference). The classifier is a PURE function so it is
// testable without a signed Keychain.

import Foundation
import Security

// MARK: - Typed Keychain read

/// The typed result of one per-preset Keychain key read.
enum APIKeyReadResult: Equatable, Sendable {
    /// The slot holds a NON-EMPTY key. (An empty decoded string is never
    /// `.present` — playback requires a non-empty key, so empty classifies as
    /// `.unreadable(errSecDecode)`.)
    case present(String)
    /// The slot genuinely has no item (`errSecItemNotFound`) — the key was
    /// never entered on this device / hasn't synced / was cleared.
    case missing
    /// The Keychain could not return a usable key: any non-success,
    /// non-not-found `OSStatus` (locked keychain, auth failure, IPC error), or
    /// success with malformed/empty payload (mapped to `errSecDecode`).
    case unreadable(OSStatus)
}

extension APIKeyReadResult {
    /// PURE classifier for a `SecItemCopyMatching` result — extracted so the
    /// status → typed-state mapping is unit-testable on an unsigned simulator
    /// (where a live Keychain read can't run). `data` is the returned payload
    /// when `status == errSecSuccess`.
    static func classify(status: OSStatus, data: Data?) -> APIKeyReadResult {
        switch status {
        case errSecSuccess:
            guard let data,
                  let key = String(data: data, encoding: .utf8),
                  !key.isEmpty else {
                // Success with no/undecodable/empty payload — not a usable
                // key, not "missing" (an item EXISTS). Map to errSecDecode.
                return .unreadable(errSecDecode)
            }
            return .present(key)
        case errSecItemNotFound:
            return .missing
        default:
            return .unreadable(status)
        }
    }

    /// The ring-safe token for this state (no key material, ever).
    var keyState: APIKeyState {
        switch self {
        case .present: return .present
        case .missing: return .missing
        case .unreadable: return .unreadable
        }
    }
}

/// The privacy-safe key-state token that travels into snapshots, the outcome ring,
/// and Diagnostics — never the key itself, never the raw `OSStatus`.
enum APIKeyState: String, Equatable, Sendable {
    case present
    case missing
    case unreadable
    /// The provider needs no key: the Apple sentinel, or a keyless
    /// (`auth == .none`) BYO custom endpoint.
    case notRequired
}

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
