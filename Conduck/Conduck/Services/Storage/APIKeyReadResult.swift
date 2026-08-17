// SPDX-License-Identifier: Apache-2.0

// Conduck
// APIKeyReadResult.swift
//
// The typed result of ONE Keychain key read, and the privacy-safe token that
// travels out of it.
//
// WHAT IT REPLACES. A `String?` read collapses two different facts into one
// nil: "the slot is empty" and "the Keychain could not answer". Keys are
// stored `kSecAttrAccessibleAfterFirstUnlock`, so on a rebooted,
// not-yet-unlocked device every slot reads exactly as if it were empty —
// which makes a nil-means-absent call site tell a correctly configured user
// they have no key. Anything that must not say that (the degraded-state UI,
// the outcome ring, the STT refusal lanes on both iPhone and Watch) reads the
// typed result instead.
//
// WHY IT LIVES BESIDE THE STORAGE SEAM rather than with either consumer: both
// the iPhone (`SettingsManager.apiKeyReadResult`) and the WATCH
// (`WatchIdentityResolver.sttAPIKeyReadResult`) classify their own
// `SecretStore.copyMatching` result, and the Watch app is a separate target
// that links almost none of the main app. One shared classifier is what keeps
// the two surfaces from drifting into different answers about the same slot;
// a per-target copy would be free to disagree. This file is therefore a
// MEMBER OF THE WATCH TARGET (`project.pbxproj`, the "Conduck" folder
// exception set) — keep it dependency-free (Foundation + Security only) so it
// stays cheap to share.
//
// `classify` is PURE so the status → verdict mapping is unit-testable on an
// unsigned simulator, where a live Keychain read cannot run at all.

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
