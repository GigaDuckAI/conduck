// SPDX-License-Identifier: Apache-2.0

// Conduck
// RemoteAgentAuthScheme.swift
//
// Per-gateway HTTP auth scheme for the remote-agent (Personal AI) layer. Mirrors
// `STTAuthScheme` on the custom-STT side, but gateway-scoped: a gateway either
// authenticates with a bearer token, or runs KEYLESS (no `Authorization` header
// — the user's network isolation, e.g. Tailscale / LAN, is the access control).
//
// LOAD-BEARING SAFETY: the scheme is an EXPLICIT, persisted choice — keyless is
// NEVER inferred from a missing/empty token. `getRemoteAgentToken` returns `nil`
// for BOTH "no token stored" AND "Keychain read failed", so inferring keyless
// from a nil token would let a transient read failure silently strip auth and,
// via the Watch broadcast, delete the Watch's stored token. The default is
// therefore `.bearer` — any legacy / missing / undecodable value FAILS CLOSED.
//
// THE SINGLE HEADER SITE: every gateway request builder on every surface routes
// through `apply(to:token:)`, so it is also where OpenRouter's app-attribution
// headers are stamped (`OpenRouterAttribution`). They ride here rather than in
// each builder because OpenRouter creates the app's public page and its
// rankings entry ONLY from those headers — a builder that forgot them would
// silently un-attribute its whole lane. Attribution is HOST-GATED, and
// deliberately independent of the scheme: it is a property of the DESTINATION,
// so a keyless (`.none`) gateway pointed at OpenRouter still carries it, while
// the user's own server never does.

import Foundation

/// How Conduck authenticates to a gateway. Persisted per-`RemoteAgentRef`
/// (`remoteAgent.authScheme.<suffix>`) and carried on `RemoteAgentSnapshot` +
/// the Watch broadcast envelopes.
enum RemoteAgentAuthScheme: String, Sendable, Equatable, Codable {
    /// `Authorization: Bearer <token>` — the default for every gateway
    /// (built-in and custom). A missing / undecodable stored value resolves to
    /// this so we never silently downgrade an authenticated gateway.
    case bearer

    /// No `Authorization` header — a keyless gateway on a private / restricted
    /// network. The user has EXPLICITLY opted out of token auth.
    case none

    /// The fail-closed default applied whenever no scheme is stored or a stored
    /// raw value can't be decoded.
    static let `default`: RemoteAgentAuthScheme = .bearer

    /// Parse a stored raw string, falling back to the fail-closed `.default`
    /// for nil / unrecognized input.
    static func from(rawValue: String?) -> RemoteAgentAuthScheme {
        guard let rawValue, let scheme = RemoteAgentAuthScheme(rawValue: rawValue) else {
            return .default
        }
        return scheme
    }

    /// Whether this scheme requires a non-empty bearer token to be considered
    /// configured / sendable. `.none` is keyless; `.bearer` needs the token.
    var requiresToken: Bool { self == .bearer }

    /// Apply the scheme to an outbound request in place. `.bearer` sets the
    /// header — the caller guarantees a non-empty `token` via the configured
    /// gate; `.none` omits it entirely. Never logs / echoes the token.
    ///
    /// Then stamps OpenRouter's app-attribution headers, which are applied for
    /// EVERY case including `.none` — a keyless request to OpenRouter is still
    /// a request to OpenRouter. `OpenRouterAttribution` is itself host-gated,
    /// so this call is a no-op for every other destination.
    func apply(to request: inout URLRequest, token: String) {
        switch self {
        case .bearer:
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        case .none:
            break
        }

        OpenRouterAttribution.apply(to: &request)
    }
}
