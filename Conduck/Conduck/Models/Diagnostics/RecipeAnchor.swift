// SPDX-License-Identifier: Apache-2.0

// Conduck
// RecipeAnchor.swift
//
// The section of the public TLS/certificate recipe page that a given connection
// failure should land on — `Constants.connectRecipesURL` plus a `#fragment`.
//
// WHY THIS EXISTS. A self-hoster's very first connect attempt is where Apple's
// transport rules bite: the gateway needs a certificate this device already
// trusts (or a private-IP-literal plain-http address), and there is no
// "continue anyway". The taxonomy already names the cause precisely; what it
// could not do was hand the user the one page that says how to fix it. This
// enum is that hand-off, and nothing else — it makes no trust decision, softens
// no refusal, and never implies an override exists.
//
// THE FRAGMENTS ARE A CROSS-REPO CONTRACT. The other half is
// `website/src/lib/setup-anchors.ts` in the monorepo, whose postbuild guard
// PARSES THIS FILE and asserts both that the app-linked fragment set matches
// exactly and that the base URL is identical. Keep every raw value a plain
// string literal on its `case` line so that regex keeps working.
//
// APPEND-ONLY once a version shipping these links is public. An installed app
// keeps emitting the fragment it was built with, so renaming or removing one
// turns a shipped "How to fix this" link into a page that scrolls nowhere.
// Adding a case is free; changing an existing raw value is not. The page may
// grow sections of its own (`PAGE_ANCHORS` on the site side) — those are the
// page's business and never appear here.
//
// nil IS A REAL ANSWER. `init?(errorCode:)` returns nil for every failure the
// page cannot help with, and the surfaces render no link at all in that case.
// A link to a section that does not address the user's problem is worse than no
// link: it spends the one action a stuck user has left. The deliberate-nil
// families are enumerated below and locked by `RecipeAnchorContractTests`.

import Foundation

/// A named section of the public TLS/certificate recipe page.
///
/// The raw value IS the URL fragment — see the file header for the cross-repo
/// contract that constrains it.
enum RecipeAnchor: String, CaseIterable, Sendable {

    /// The chain is not one this device trusts — self-signed, a private CA, an
    /// expired leaf, or a missing intermediate. One umbrella section, because
    /// the four causes are indistinguishable to the user and share the same
    /// three server-side remedies. Codes 63-66 (gateway / custom STT / custom
    /// TTS / file server).
    case certUntrusted = "cert-untrusted"

    /// A configured pin disagreed with a chain the system otherwise trusts —
    /// an ordinary renewal, or an interception. Codes 30/35/43/47.
    case pinMismatch = "pin-mismatch"

    /// The certificate's public key is one this device cannot pin (neither an
    /// RSA nor a P-256/P-384 key the pinner understands). Codes 67-70.
    case pinKeyUnsupported = "pin-key-unsupported"

    /// The platform refused a plain-http address from its STRING, before any
    /// connection was attempted. Code 77, plus the pairing parser's
    /// `.insecureURL`, which is the same refusal reached one step earlier.
    case plainHTTPBlocked = "plain-http-blocked"

    /// Nothing answered. Codes 19/45/73 — deliberately including "connection
    /// never established", whose defining property is that the request may not
    /// have arrived.
    case unreachable = "unreachable"

    /// The request was accepted and then ran out of time. Its own section, not
    /// a fold into `unreachable`: the gateway may still be working, so retrying
    /// can duplicate work the user is paying for — a warning that has nowhere
    /// to live in the unreachable copy. Code 28.
    case timeout = "timeout"

    /// The credential was rejected — or a proxy/tunnel in front of the gateway
    /// rejected the request's Host header, which surfaces identically. Codes
    /// 26/46.
    case auth = "auth"

    /// Exposing a gateway to a device over Tailscale. Reached only from the
    /// pairing wizard's tailnet callout — no `AppError` maps here, because a
    /// tailnet gateway that fails does so as an ordinary unreachable/untrusted
    /// failure and deserves that section's answer.
    case tailscaleServe = "tailscale-serve"

    /// The full page URL for this section.
    var url: URL {
        // Both halves are compile-time constants under this file's own control,
        // and `RecipeAnchorContractTests` asserts every case's exact string.
        URL(string: Constants.connectRecipesURL + "#" + rawValue)!
    }

    /// The section for an `AppError.errorCode`, or nil when the page has
    /// nothing to offer.
    ///
    /// DELIBERATELY nil, by family:
    /// - **Not configured yet** (12, 34, 42, 44, 74) — the remedy is in the
    ///   app's own settings, not on a certificate page.
    /// - **Wrong endpoint shape** (58, 59, 60, 62) — the address answered; it
    ///   is simply not an OpenAI-compatible chat endpoint. The adapter guide
    ///   owns that, and this page would send the user hunting a TLS fault that
    ///   is not there.
    /// - **The server answered and said no** (29, 71, 72) — transport worked.
    /// - **Lane-ambiguous transport** (4, 20, 36) — these fire for the STT and
    ///   TTS lanes as well as the gateway, and the recipe page speaks about the
    ///   gateway's address. A section that may be about a different server is a
    ///   wrong answer half the time.
    /// - **Nothing was attempted** (76) — the user stopped the turn.
    /// - Everything else unlisted: local audio, permissions, provider quota,
    ///   device-local faults, and the generic catch-alls (1, 7, 10, 99), none
    ///   of which is a transport-configuration problem.
    init?(errorCode: Int) {
        switch errorCode {
        case 63, 64, 65, 66: self = .certUntrusted
        case 30, 35, 43, 47: self = .pinMismatch
        case 67, 68, 69, 70: self = .pinKeyUnsupported
        case 77: self = .plainHTTPBlocked
        case 19, 45, 73: self = .unreachable
        case 28: self = .timeout
        case 26, 46: self = .auth
        default: return nil
        }
    }
}
