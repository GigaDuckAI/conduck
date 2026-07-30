// SPDX-License-Identifier: Apache-2.0

// Conduck
// GatewayChatSuccess.swift
//
// "This gateway answered a real chat turn from THIS device, under THIS
// configuration." The one fact Diagnostics could never state: every existing
// check proves reachability, auth and envelope shape — none of them proves a
// turn completes. `GET /v1/models` greening while chat is broken (wrong model,
// model-required, vision unsupported, context limits) is the dominant
// silent-failure shape for a self-hoster.
//
// Deliberately NOT synced to iCloud KVS. "It worked from HERE" is the honest
// claim; a synced record would imply cellular, Watch or CarPlay reachability it
// never proved, and one device's success would silence another device's real
// problem. App-Group only, per ref, cleared with the per-ref wipe.

import Foundation
import CryptoKit

/// A recorded successful chat round-trip, bound to the configuration that
/// produced it.
///
/// The binding is what makes the record honest. Without it, editing a gateway's
/// URL or model would leave a success behind that the NEW configuration never
/// earned — so the record carries the signature of the config it was dispatched
/// under, and any reader compares before trusting it.
struct GatewayChatSuccess: Codable, Equatable, Sendable {

    /// Signature of the gateway configuration this success was DISPATCHED under.
    let signature: String

    /// When the reply landed and was persisted.
    let at: Date

    /// Config signature for a gateway ref. **SHA-256, never `Hasher`** —
    /// `Hasher` is seeded per process, so a stored value would compare unequal
    /// after every relaunch and this record would silently never match itself.
    ///
    /// Truncated to 8 bytes: this gates a correctness decision (is the stored
    /// success still about the current config?), so it wants more room than the
    /// 4-byte forensic tag `TTSOutcomeLog.configSignature` emits into a report.
    ///
    /// **The token is absent entirely** — not hashed, not even as a presence
    /// bool. Deliberate: rotating a token (or re-pairing the same server) does
    /// not change what the route proved, so it must not discard the record.
    /// Switching between keyless and bearer IS a real configuration change, and
    /// `authScheme` already captures exactly that.
    ///
    /// This is why the signature needs no credential-generation counter — the
    /// `FileTransferTestSignature` pattern carries one because a rotated
    /// file-server password genuinely invalidates the verdict earned under the
    /// old one (and that counter is in-memory per session besides, so it could
    /// not serve a durable record like this one).
    static func signature(
        url: URL,
        authScheme: RemoteAgentAuthScheme,
        model: String?,
        pinnedFingerprintHex: String?,
        kind: String
    ) -> String {
        let parts: [String] = [
            kind,
            url.absoluteString,
            String(describing: authScheme),
            model ?? "",
            // Presence only — a pin's VALUE is a per-device tightening, and its
            // arrival or removal is the part that changes what the route proves.
            (pinnedFingerprintHex?.isEmpty == false) ? "pinned" : "unpinned"
        ]
        let digest = SHA256.hash(data: Data(parts.joined(separator: "|").utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}
