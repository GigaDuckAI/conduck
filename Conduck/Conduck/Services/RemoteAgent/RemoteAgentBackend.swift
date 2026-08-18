// SPDX-License-Identifier: Apache-2.0

// Conduck
// RemoteAgentBackend.swift
//
// Pure-data enum identifying the Personal AI
// gateway the user has configured. Under client-owned history (locked
// 2026-05-20) there is NO wire-level per-backend dispatch — both backends
// take the identical stateless `/v1/chat/completions` request with the
// full `messages[]` history (`docs/ai-context/spec.md`).
// The only per-backend differences are the base URL + setup recipe.
//
// Raw values `"openclaw"` and `"hermes"` are load-bearing — they are
// persisted as the Settings backend selection (`Constants.remoteAgentBackendKey`)
// and consumed by the Watch-side broadcast envelope. Renaming would orphan
// every install's existing config; treat as locked.

import Foundation

/// The Personal AI gateway backend the user has configured.
///
/// Two backends ship in V1: OpenClaw (reference; default) and Hermes
/// (gated behind `FeatureFlags.remoteAgentHermesEnabled` until verified).
/// Both speak an OpenAI-compatible `/v1/chat/completions` shape with an
/// identical stateless request — there is no per-backend wire difference
/// beyond the base URL.
enum RemoteAgentBackend: String, Codable, Sendable, CaseIterable {
    case openclaw
    case hermes

    /// OpenRouter — a third-party HOSTED-MODEL aggregator (OpenAI-compatible
    /// `/v1/chat/completions`). Unlike OpenClaw/Hermes (the user's OWN
    /// always-on server) this is a hosted service with a KNOWN fixed URL, so it
    /// is preconfigured: the user supplies only an API key + a model. It is a
    /// "lite" lane — no tools / file transfer / agent loop (those need a real
    /// gateway). Raw value `"openrouter"` is LOCKED (persisted in
    /// `Conversation.backend` + per-ref storage keys). Capability policies live
    /// on `RemoteAgentBackendMetadata`; gated in the Settings UI behind
    /// `FeatureFlags.remoteAgentOpenRouterEnabled`.
    case openrouter

    /// Default listening port for a freshly-installed gateway. Surfaced as
    /// the placeholder in the Settings URL field (`:18789` / `:8642`) so
    /// users running the upstream-recommended setup recognise the value.
    /// Sourced from `Constants.openclawDefaultPort` / `.hermesDefaultPort`
    /// to keep numeric literals out of UI strings.
    var defaultPort: Int {
        switch self {
        case .openclaw: return Constants.openclawDefaultPort
        case .hermes: return Constants.hermesDefaultPort
        // Unused: OpenRouter's URL is fixed (`endpoint == .fixed`) so the
        // port-bearing placeholder is never surfaced; 443 is the https default.
        case .openrouter: return 443
        }
    }

    /// Human-readable name for Settings pickers + onboarding copy.
    /// Hardcoded English — V1 is English-only;
    /// localisation lands with broader Settings polish.
    var displayName: String {
        switch self {
        case .openclaw: return "OpenClaw"
        case .hermes: return "Hermes"
        case .openrouter: return "OpenRouter"
        }
    }

    /// Compact monogram for the on-wrist gateway badge ("OC" / "H"). Display-only,
    /// English (V1 is English-only). Rendered in a
    /// content-hugging capsule (`WatchGatewayBadge`) so the asymmetric width
    /// reads as a clean pill-tag, not misalignment.
    var shortCode: String {
        switch self {
        case .openclaw: return "OC"
        case .hermes: return "H"
        case .openrouter: return "OR"
        }
    }

    /// The name a NARROW or SPOKEN surface uses — the wrist, the wheel, a
    /// notification title. All three built-in names already fit
    /// `RemoteAgentRefMetadata.shortDisplayNameLimit`, so this is `displayName`
    /// in practice; the `shortCode` arm is the last-resort floor that keeps the
    /// guarantee true by construction if a fourth built-in ever arrives with a
    /// longer name. Never abbreviate a name that fits — "OC" read aloud at the
    /// wheel is worse than "OpenClaw", and the point of the budget is to bound
    /// the line, not to shorten what is already short.
    var shortDisplayName: String {
        displayName.count <= RemoteAgentRefMetadata.shortDisplayNameLimit ? displayName : shortCode
    }

    /// HTTP status → `AppError` map. Both cases return the SINGLE unified
    /// map — there is no per-backend difference under client-owned history
    /// (no 423/session-lock path). The seam is retained as the
    /// single dispatch point so a future V1.x `.custom` backend
    /// can supply its own mapping
    /// without scattering `backend ==` branches across the client. This is
    /// data dispatch, not behaviour dispatch.
    var statusMap: RemoteAgentStatusMap {
        switch self {
        case .openclaw: return .unified
        case .hermes: return .unified
        case .openrouter: return .unified
        }
    }
}
