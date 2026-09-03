// SPDX-License-Identifier: Apache-2.0

// Conduck
// OpenRouterAttribution.swift
//
// The OpenRouter app-attribution headers, and the host gate that decides where
// they are allowed to go.
//
// WHY IT EXISTS: OpenRouter creates an app's public page and its rankings entry
// ONLY from three request headers — `HTTP-Referer` (required; the app's URL is
// its identity there), `X-OpenRouter-Title`, `X-OpenRouter-Categories`. Traffic
// that omits them is attributed to nobody, so the headers are the whole of the
// distribution surface OpenRouter offers. They are constant app identity — a
// URL, a name, two catalog words — carrying nothing user-derived and nothing
// device-derived, so sending them is not telemetry in either direction: nothing
// about the user or the device is described, and no data comes back.
//
// WHY IT IS HOST-GATED: most Conduck traffic goes to the USER'S OWN gateway or
// speech provider, and those servers have no business learning which app is
// talking to them — a self-hosted OpenClaw box behind Tailscale, a BYO
// OpenAI-compatible endpoint, ElevenLabs. Attribution is a property of the
// DESTINATION, never of the auth scheme or the caller, so this type answers one
// question — "is this request going to OpenRouter?" — and stays silent
// otherwise.
//
// The gate compares the request's host to the host of
// `Constants.openRouterBaseURLString`, the single locked source of OpenRouter's
// endpoint. It is an EXACT, case-insensitive equality, never a suffix match:
// `openrouter.ai.example.com` and `notopenrouter.ai` are somebody else's
// servers and must not receive these headers. Deriving the host from the same
// constant the client dials means a future base-URL change moves both together
// instead of silently unhooking attribution.

import Foundation

/// Applies OpenRouter's app-attribution headers to outbound requests that are
/// actually bound for OpenRouter. Called from the two auth seams
/// (`RemoteAgentAuthScheme.apply(to:token:)`,
/// `STTAuthScheme.apply(to:apiKey:)`), which every request builder on every
/// surface — phone, Mac, CarPlay, Watch — already routes through.
enum OpenRouterAttribution {

    /// Required by OpenRouter: the app URL that identifies the app.
    static let refererHeader = "HTTP-Referer"

    /// The app's display name on its OpenRouter page.
    static let titleHeader = "X-OpenRouter-Title"

    /// Comma-separated catalog categories (OpenRouter accepts at most two).
    static let categoriesHeader = "X-OpenRouter-Categories"

    /// The ONE host these headers may ever reach, lowercased for a
    /// case-insensitive comparison. Derived from `openRouterBaseURLString` —
    /// there is deliberately no second `openrouter.ai` literal in the app.
    /// `nil` only if that constant ever stops parsing as a URL with a host, in
    /// which case the gate closes and no request is attributed (fail closed:
    /// a missing app page is a nuisance, leaking app identity to an unintended
    /// server is not).
    static let attributedHost: String? =
        URL(string: Constants.openRouterBaseURLString)?.host()?.lowercased()

    /// Set the three attribution headers in place, but ONLY when `request` is
    /// addressed to `attributedHost`. Any other destination — the user's own
    /// gateway, a self-hosted server, a non-OpenRouter speech vendor, a
    /// lookalike host — is left exactly as it was. Never reads or echoes a
    /// token: the values are compile-time app identity.
    static func apply(to request: inout URLRequest) {
        guard let expectedHost = attributedHost,
              let requestHost = request.url?.host()?.lowercased(),
              requestHost == expectedHost
        else { return }

        request.setValue(Constants.openRouterAttributionReferer, forHTTPHeaderField: refererHeader)
        request.setValue(Constants.openRouterAttributionTitle, forHTTPHeaderField: titleHeader)
        request.setValue(Constants.openRouterAttributionCategories, forHTTPHeaderField: categoriesHeader)
    }
}
