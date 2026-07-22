// Conduck
// RemoteAgentRefMetadata.swift
//
// Custom-gateways. One PURE resolver for the display identity of a
// `RemoteAgentRef` (built-in or custom), reused by every surface — the
// per-conversation pickers, the Settings list, the Watch badge/Ask chooser,
// and the CarPlay gateway switcher — so built-in-vs-custom labeling is never
// re-derived per call site. Plus the badge color palette.
//
// Shared by the app AND Watch targets (Approach A membership exception).

import SwiftUI

/// Display-identity resolver for a `RemoteAgentRef`. Pure functions over a
/// supplied `[CustomGateway]` snapshot (no actor hop inside a SwiftUI `body`).
enum RemoteAgentRefMetadata {

    /// The user-facing gateway name. Built-in → its `displayName`; custom →
    /// its roster `name` (falls back to a generic label if the roster entry
    /// is missing — e.g. a deleted / not-yet-synced custom).
    static func displayName(for ref: RemoteAgentRef, customs: [CustomGateway]) -> String {
        switch ref {
        case .builtin(let backend):
            return backend.displayName
        case .custom(let id):
            return customs.first(where: { $0.id == id })?.name ?? String(localized: "Custom gateway")
        }
    }

    /// The 1–2 char badge monogram. Built-in → its `shortCode` ("OC"/"H");
    /// custom → its explicit `monogram`, else derived from its `name`.
    static func monogram(for ref: RemoteAgentRef, customs: [CustomGateway]) -> String {
        switch ref {
        case .builtin(let backend):
            return backend.shortCode
        case .custom(let id):
            guard let gateway = customs.first(where: { $0.id == id }) else { return "" }
            if let monogram = gateway.monogram, !monogram.isEmpty { return monogram }
            return deriveMonogram(from: gateway.name)
        }
    }

    /// Derive a 1–2 char uppercased monogram from a gateway name (first two
    /// alphanumerics; empty when the name has none).
    static func deriveMonogram(from name: String) -> String {
        let alphanumerics = name.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
        return String(String.UnicodeScalarView(alphanumerics.prefix(2))).uppercased()
    }
}

/// The fixed badge color palette. Built-ins have reserved colors held OUTSIDE
/// `customPalette` (OpenClaw = orange, Hermes = teal, OpenRouter = slate), so a
/// custom — auto-assigned the next unused `customPalette` entry at create time
/// — can never share a hue with a built-in. Two gateways never share a color,
/// and every one is legible on a black watch face. The stored `colorID` is a
/// stable key into this map — NOT a hashed/derived value — so the swatch is
/// deterministic and editable.
enum RemoteAgentBadgePalette {
    /// Built-in reserved colors (unchanged from the prior Watch badge tints).
    static let openclaw = Color.orange
    static let hermes = Color.teal
    /// OpenRouter (hosted-model backend) reserved badge tint — a neutral slate
    /// (#64748B) held OUTSIDE `customPalette` (like orange/teal), so it can
    /// never collide with a custom gateway's auto-assigned hue. INVARIANT:
    /// every built-in reserved color stays disjoint from `customPalette` —
    /// asserted in `ShareTargetsSnapshotWriterColorTests`.
    static let openrouter = Color(red: 100 / 255, green: 116 / 255, blue: 139 / 255)

    /// Ordered custom palette (Apple system colors, legible on black).
    /// `colorID` strings are LOCKED (persisted in the registry) — append,
    /// never reorder/rename.
    static let customPalette: [(id: String, color: Color)] = [
        ("indigo", .indigo),
        ("pink", .pink),
        ("green", .green),
        ("mint", .mint),
        ("blue", .blue),
        ("purple", .purple),
        ("brown", .brown),
        ("cyan", .cyan),
    ]

    /// Resolve a `colorID` to a Color; unknown / nil id → first custom slot.
    static func color(forID id: String?) -> Color {
        guard let id, let entry = customPalette.first(where: { $0.id == id }) else {
            return customPalette[0].color
        }
        return entry.color
    }

    /// The badge color for a ref. Built-ins use their reserved hue; customs
    /// use their assigned `colorID` (falling back to the first slot).
    static func color(for ref: RemoteAgentRef, customs: [CustomGateway]) -> Color {
        switch ref {
        case .builtin(let backend):
            switch backend {
            case .openclaw: return openclaw
            case .hermes: return hermes
            case .openrouter: return openrouter
            }
        case .custom(let id):
            return color(forID: customs.first(where: { $0.id == id })?.colorID)
        }
    }

    /// Pick the next unused custom palette id given the colors already taken by
    /// existing customs. Wraps to the first slot once all `customPalette` slots
    /// are used — so distinct auto-assigned colors are guaranteed only while
    /// `maxCustomGateways <= customPalette.count`.
    static func nextUnusedID(existing: [String]) -> String {
        let used = Set(existing)
        return customPalette.first(where: { !used.contains($0.id) })?.id ?? customPalette[0].id
    }
}
