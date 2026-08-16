// SPDX-License-Identifier: Apache-2.0

// Conduck
// RemoteAgentRefMetadata.swift
//
// Custom-gateways. One PURE resolver for the display identity of a
// `RemoteAgentRef` (built-in or custom), reused by every surface — the
// per-conversation pickers, the Settings list, the Watch badge/Ask chooser,
// and the CarPlay gateway switcher — so built-in-vs-custom labeling is never
// re-derived per call site. Plus the badge color palette, and the one rule
// deciding whether a conversation list shows badges at all
// (`shouldShowBadges`) — it lives beside the monogram it depends on, because
// "should the list badge" and "can this ref render a badge" must never drift
// apart on any of the five list surfaces.
//
// TWO name forms, and the choice belongs to the SURFACE, not the caller's
// convenience. `displayName` is the full one — iPhone, iPad, Mac.
// `shortDisplayName` is bounded by `shortDisplayNameLimit` and is what the
// narrow and SPOKEN surfaces use: the wrist, the wheel, a notification title.
// The budget's derivation sits on the constant.
//
// Shared by the app AND Watch targets (Approach A membership exception) — the
// Watch list applies the identical rule, so a new file would be the wrong home
// for it (it would silently miss the Watch target).

import SwiftUI

/// Display-identity resolver for a `RemoteAgentRef`. Pure functions over a
/// supplied `[CustomGateway]` snapshot (no actor hop inside a SwiftUI `body`).
enum RemoteAgentRefMetadata {

    /// The label a custom gateway carries when its own name is unavailable —
    /// a deleted, forgotten or not-yet-synced roster entry. One definition, so
    /// "no name we can show" reads identically whether the entry is missing
    /// outright or present only as a retired badge.
    static var genericCustomName: String { String(localized: "Custom gateway") }

    /// The user-facing gateway name. Built-in → its `displayName`; custom →
    /// its roster `name` (falls back to a generic label if the roster entry
    /// is missing — e.g. a deleted / not-yet-synced custom).
    static func displayName(for ref: RemoteAgentRef, customs: [CustomGateway]) -> String {
        switch ref {
        case .builtin(let backend):
            return backend.displayName
        case .custom(let id):
            return customs.first(where: { $0.id == id })?.name ?? genericCustomName
        }
    }

    // MARK: - The short display form (narrow + spoken surfaces)

    /// The character budget for a name a NARROW or SPOKEN surface renders.
    ///
    /// Derived from the two measurements that bound those surfaces, not chosen
    /// for looks. A custom gateway's name is capped at 40 characters when it is
    /// saved (`SettingsViewModel.saveRemoteAgentConfig`), and the Watch in-thread
    /// error banner holds ROUGHLY 38 characters over its two lines — measured
    /// on-device and recorded in `ErrorSurfaceDriftGuardTests`, where three
    /// certificate verdicts at 101/124/129 characters are on record as having
    /// clipped inside it. So a sentence that names its instance — "Couldn't
    /// reach X." — is 18 characters of frame plus the name: at 40 it overflows
    /// the banner outright, at 16 it fits. That is the whole derivation.
    ///
    /// The budget also protects the SPOKEN lane, where the failure is different
    /// and worse: CarPlay reads error copy aloud through TTS at the wheel, and
    /// every character is time a driver spends listening. A name is the one part
    /// of that sentence Conduck does not write, so it is the one part that has to
    /// be bounded.
    static let shortDisplayNameLimit = 16

    /// The user-facing gateway name, bounded by `shortDisplayNameLimit`.
    ///
    /// Use this on the wrist, at the wheel, and in a notification title. Use
    /// `displayName` on iPhone, iPad and Mac, where the layout can hold a name in
    /// full and truncating one would be a loss for nothing.
    ///
    /// Built-in → `RemoteAgentBackend.shortDisplayName` (its own name, with
    /// `shortCode` as the floor). Custom → its roster name, truncated; a custom
    /// with no usable name falls back to its monogram and then to the same
    /// generic label the rest of the app uses, so this never returns "".
    static func shortDisplayName(for ref: RemoteAgentRef, customs: [CustomGateway]) -> String {
        switch ref {
        case .builtin(let backend):
            return backend.shortDisplayName
        case .custom(let id):
            let name = (customs.first(where: { $0.id == id })?.name ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else {
                let monogram = monogram(for: ref, customs: customs)
                return monogram.isEmpty ? genericCustomName : monogram
            }
            return truncatedToShortLimit(name)
        }
    }

    /// Cut a name down to `shortDisplayNameLimit`, ellipsis included in the
    /// budget so the RESULT is what fits, not the input.
    ///
    /// A hard cut, not a word-boundary one. Custom names are frequently
    /// hostname-shaped (`hermes-vps-01-frankfurt`) with no word boundary to find,
    /// and a rule that sometimes trims to a word and sometimes does not gives two
    /// different answers for names that differ by one character — which on a
    /// surface the user compares two gateways on is worse than a predictable cut.
    /// Trailing separators are dropped so the result never reads "hermes-vps-…".
    static func truncatedToShortLimit(_ name: String) -> String {
        guard name.count > shortDisplayNameLimit else { return name }
        let head = name.prefix(shortDisplayNameLimit - 1)
        let trimmed = String(head).replacingOccurrences(
            of: #"[\s\-_.,;:/]+$"#, with: "", options: .regularExpression)
        // A name made ENTIRELY of separators past the cut would trim to nothing;
        // fall back to the untrimmed head so the form always carries characters.
        return (trimmed.isEmpty ? String(head) : trimmed) + "…"
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

    /// Whether a conversation LIST should render per-row gateway badges: true
    /// once the list can display TWO distinct gateway identities.
    ///
    /// The count spans the CONFIGURED set UNION the gateways the listed
    /// conversations were created with — not the configured set alone. A
    /// conversation stays bound to the gateway that created it
    /// (`Conversation.backend`), and forgetting that gateway does not merge it
    /// with the others; asking only "how many gateways are set up right now"
    /// blanks the badge on a mixed history the moment the user is down to one
    /// live gateway, which is exactly when the rows are hardest to tell apart.
    ///
    /// Two details are load-bearing:
    /// - Dedup by REF, never by monogram. Two gateways can carry the same
    ///   letters; they are still two identities and still two colors.
    /// - A ref that resolves to NO monogram does not count. `GatewayBadge`
    ///   renders `EmptyView` for one (a forgotten custom, whose roster entry is
    ///   gone), so counting it could switch badges on for a list that then
    ///   shows a single badge beside a blank gap — worse than showing none.
    ///
    /// Callers pass the same roster they hand the badge, so "can it render"
    /// here and "did it render" there are the same question. Single-gateway
    /// setups keep a badge-free list.
    ///
    /// This governs the BADGE only. The gateway pickers and switchers gate on
    /// `configuredRefs.count >= 2` for an unrelated reason — you cannot switch
    /// to a gateway you have forgotten — and that gate stays as it is.
    static func shouldShowBadges(
        configured: [RemoteAgentRef],
        conversationBackends: some Sequence<String>,
        customs: [CustomGateway]
    ) -> Bool {
        var identities: Set<RemoteAgentRef> = []
        for ref in configured where !monogram(for: ref, customs: customs).isEmpty {
            identities.insert(ref)
            if identities.count >= 2 { return true }
        }
        // Bails at the second identity — which the SINGLE-gateway case never
        // reaches, so that case scans the whole array every time. That is the
        // common case, so callers resolve this ONCE per list build; evaluating
        // it per row makes the scan quadratic in the number of conversations.
        for raw in conversationBackends {
            guard let ref = RemoteAgentRef(rawString: raw),
                  !monogram(for: ref, customs: customs).isEmpty
            else { continue }
            identities.insert(ref)
            if identities.count >= 2 { return true }
        }
        return false
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
