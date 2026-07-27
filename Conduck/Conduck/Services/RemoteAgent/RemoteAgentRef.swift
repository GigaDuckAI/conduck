// SPDX-License-Identifier: Apache-2.0

// Conduck
// RemoteAgentRef.swift
//
// Custom-gateways. A backend reference is EITHER a built-in gateway
// (OpenClaw / Hermes — `RemoteAgentBackend`, raw values LOCKED) OR a
// user-defined custom OpenAI-compatible gateway (`CustomGateway`, keyed by
// UUID). This is the single identity the whole app routes on:
// `Conversation.backend` stores `rawString`, every per-ref storage key is
// suffixed by `storageKeySuffix`, and the broadcast envelopes carry it.
//
// Migration-free by construction: a built-in's `rawString` == its
// `RemoteAgentBackend.rawValue` ("openclaw" / "hermes"), so every existing
// stored `Conversation.backend`, Keychain account, and default-pointer
// parses + routes exactly as before. Customs serialize to
// `"custom_<uuid>"` — a namespace provably disjoint from the two reserved
// keywords (a UUID-bearing string can never equal "openclaw"/"hermes").
//
// Pure value type — shared by the app AND Watch targets (Approach A
// membership exception in project.pbxproj), like `RemoteAgentBackend`.

import Foundation

/// A reference to the Personal AI gateway a conversation is bound to:
/// a built-in backend or a user-defined custom gateway.
enum RemoteAgentRef: Hashable, Sendable, Codable {
    case builtin(RemoteAgentBackend)
    case custom(UUID)

    /// The custom-ref serialization prefix. A UUID string can never collide
    /// with the two reserved built-in raw values, so the namespaces are
    /// provably disjoint. LOCKED — it is part of every persisted custom key.
    static let customPrefix = "custom_"

    /// The string persisted in `Conversation.backend`, the default-backend
    /// pointer, and the broadcast envelopes, and used to derive per-ref
    /// storage-key suffixes. Built-ins serialize to their EXISTING locked raw
    /// values (back-compat); customs to `"custom_<uuid-lowercased>"`.
    var rawString: String {
        switch self {
        case .builtin(let backend): return backend.rawValue
        case .custom(let id): return Self.customPrefix + id.uuidString.lowercased()
        }
    }

    /// Inverse of `rawString`. A reserved built-in raw value wins; a
    /// `"custom_"`-prefixed valid UUID is a custom; anything else is nil
    /// (the caller maps nil to `remoteAgentNotConfigured` — no reroute).
    init?(rawString: String) {
        if let backend = RemoteAgentBackend(rawValue: rawString) {
            self = .builtin(backend)
            return
        }
        guard rawString.hasPrefix(Self.customPrefix),
              let id = UUID(uuidString: String(rawString.dropFirst(Self.customPrefix.count))) else {
            return nil
        }
        self = .custom(id)
    }

    /// Suffix for per-ref storage keys (Keychain account, URL/cert
    /// UserDefaults). Equals `rawString`, so built-ins keep their EXACT
    /// existing key suffixes ("openclaw"/"hermes") — zero migration.
    var storageKeySuffix: String { rawString }

    var isBuiltin: Bool {
        if case .builtin = self { return true }
        return false
    }

    var customID: UUID? {
        if case .custom(let id) = self { return id }
        return nil
    }

    // MARK: - Codable (single-value container over `rawString`)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let ref = RemoteAgentRef(rawString: raw) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unrecognized RemoteAgentRef rawString: \(raw)"
            )
        }
        self = ref
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawString)
    }
}
