// SPDX-License-Identifier: Apache-2.0

// Conduck
// SessionContinuationPolicy.swift
//
// The user-configurable "New conversation" policy that decides whether a
// HEADLESS quick capture (iOS Action Button, Apple Watch, macOS menu-bar
// popover/hotkey) continues the most-recent conversation or mints a fresh
// one. A pure-data enum persisted via `SettingsManager` (App Groups key
// `Constants.sessionContinuationPolicyKey`). GENUINELY PER-DEVICE: iPhone,
// iPad, and macOS each read+write their OWN App-Group value (no iCloud-KVS
// write — `handleiCloudChange` never mirrored this key inbound, so the devices
// were always independent). The Watch has NO settings UI of its own: it
// follows the iPhone via the multi-gateway broadcast envelope's `sessionPolicy`
// slot (the iPhone's Watch-specific override if set — see
// `watchSessionContinuationPolicyOverride` — else the iPhone's own value),
// mirroring how the per-device default gateway is couriered. Supersedes the
// previously fixed 30-minute active-session window.
//
// SCOPE: applies to headless quick captures only. CarPlay (explicit picker)
// and the in-app / conversations-window composers (append to the visible
// thread) ignore this policy — they pick the conversation directly.
//
// Resolver contract (load-bearing — see `SettingsManager.resolveActiveConversationID`
// + `WatchSettingsReader.resolveActiveConversationID`): the two extremes
// (`alwaysNew` / `alwaysContinue`) are handled by BRANCH, never by arithmetic.
// Modelling them as `ttl = 0` / `.infinity` and comparing `elapsed < ttl` is a
// bug: a backward clock jump (NTP correction) makes `elapsed` negative and
// `elapsed < 0` flips `alwaysNew` into "continue"; a NaN flips `alwaysContinue`
// into "reset." Hence `ttlSeconds` is `nil` for the extremes (`Optional`,
// not a sentinel) and the resolver switches on the case.

import Foundation

/// User preference deciding whether a headless quick capture continues the
/// most-recent conversation or starts a fresh one. Raw values are
/// load-bearing (persisted) — do not rename.
enum SessionContinuationPolicy: String, Codable, Sendable, CaseIterable, Identifiable {
    /// Every capture mints a fresh conversation (skew-immune — never compares
    /// against a stored timestamp).
    case alwaysNew
    /// Continue the most-recent conversation if the last activity was within
    /// 15 minutes; otherwise mint a fresh one.
    case minutes15
    /// Continue within 30 minutes (the default).
    case minutes30
    /// Continue within 60 minutes.
    case minutes60
    /// Never auto-expire — always continue the most-recent conversation (no
    /// comparison; the user starts a new one explicitly).
    case alwaysContinue

    var id: String { rawValue }

    /// Finite TTL window (seconds) for the timed cases. nil for the two
    /// extremes — they are handled by branch, NOT by arithmetic (see resolver).
    var ttlSeconds: TimeInterval? {
        switch self {
        case .alwaysNew, .alwaysContinue: return nil
        case .minutes15: return 900
        case .minutes30: return 1800
        case .minutes60: return 3600
        }
    }

    /// Default applied when no value is stored or the stored raw value is
    /// unknown (forward-compat). 30-minute window matches the legacy fixed
    /// active-session behavior it supersedes.
    static var `default`: SessionContinuationPolicy { .minutes30 }

    /// Localized menu label for this policy, shared by the iOS / macOS / Watch
    /// settings pickers (display polarity reads inverse to the case names).
    var label: LocalizedStringResource {
        switch self {
        case .alwaysNew:
            return LocalizedStringResource("settings.remoteAgent.sessionPolicy.alwaysNew", defaultValue: "Never")
        case .minutes15:
            return LocalizedStringResource("settings.remoteAgent.sessionPolicy.minutes15", defaultValue: "If within 15 min")
        case .minutes30:
            return LocalizedStringResource("settings.remoteAgent.sessionPolicy.minutes30", defaultValue: "If within 30 min")
        case .minutes60:
            return LocalizedStringResource("settings.remoteAgent.sessionPolicy.minutes60", defaultValue: "If within 60 min")
        case .alwaysContinue:
            return LocalizedStringResource("settings.remoteAgent.sessionPolicy.alwaysContinue", defaultValue: "Always")
        }
    }

    /// Single source of truth for the continue-vs-fresh decision, shared by
    /// BOTH headless resolvers (`SettingsManager.resolveActiveConversationID` on
    /// iOS/macOS, `WatchSettingsReader.resolveActiveConversationID` on watchOS).
    /// The enum is a member of both the app and Watch targets, so keeping the
    /// branch here — not copied into each resolver — guarantees the two surfaces
    /// can never drift, and the policy's own unit tests cover both call sites.
    ///
    /// The caller reads its own storage (App Groups on iOS/macOS, iCloud KVS on
    /// the Watch), validates the pointer (`id` present, `lastActivity > 0`), then
    /// delegates the decision here. Returns the stored `id` to continue, or nil
    /// to mint a fresh conversation. `now` is injectable for deterministic tests.
    /// Branch, never arithmetic, for the two extremes (see the type-level note).
    func resolvedConversationID(id: UUID, lastActivity: TimeInterval, now: Date) -> UUID? {
        switch self {
        case .alwaysNew:      return nil
        case .alwaysContinue: return id
        default:
            guard let ttl = ttlSeconds else { return id }
            // Clamp backward clock skew to 0 — a future `lastActivity` (negative
            // elapsed) is treated as "just now" and continues, never resets.
            let elapsed = max(0, now.timeIntervalSinceReferenceDate - lastActivity)
            return elapsed < ttl ? id : nil
        }
    }
}
