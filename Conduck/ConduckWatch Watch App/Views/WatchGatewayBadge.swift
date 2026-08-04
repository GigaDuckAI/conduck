// SPDX-License-Identifier: Apache-2.0

// Conduck
// WatchGatewayBadge.swift
//
// Compact per-conversation gateway monogram ("OC" / "H" / a custom's monogram)
// for the Watch conversation list rows. Derives the REF from the stored
// `ConversationRecord.backend` raw string; renders NOTHING when the ref is
// unknown/empty OR a custom whose roster entry is missing (deleted /
// not-yet-synced) so the row never shows a meaningless box.
//
// WHETHER a row badges at all is not decided here — the list owns that, via
// `RemoteAgentRefMetadata.shouldShowBadges`, so all five surfaces answer it
// identically. This view only renders the identity it is handed.
//
// Capsule HUGS its text, so monograms of different widths read as clean
// pill-tags rather than misaligned fixed-width chips. Tint distinguishes
// gateways at a glance: built-ins keep their reserved hues (OpenClaw orange,
// Hermes teal); customs use their assigned `RemoteAgentBadgePalette` color +
// roster monogram (NOT a UUID hash).

import SwiftUI

struct WatchGatewayBadge: View {
    let backendRawValue: String

    private var ref: RemoteAgentRef? {
        RemoteAgentRef(rawString: backendRawValue)
    }

    /// Monogram + tint + accessibility label for the resolved ref, or nil when
    /// the ref is unparseable OR a custom missing from the roster (deleted /
    /// never-synced) — both render nothing.
    ///
    /// Reads the BADGE roster, not the live one: a conversation outlives the
    /// gateway that created it, so a row bound to a forgotten custom must still
    /// draw the colour tag that told it apart. The live roster stays the routing
    /// and Ask-chooser index — a forgotten gateway is never a send target.
    ///
    /// Snapshotted ONCE into a local. Every read of it composes the reader's two
    /// stored rosters, and the custom branch below needs it four times — on a
    /// long wrist list that is four compositions per badge per body pass, on the
    /// slowest device in the fleet. Pure otherwise (no actor hop): both
    /// underlying properties are `@Observable`-tracked stored values, so the
    /// badge also re-renders when either changes.
    private var resolved: (monogram: String, tint: Color, label: String)? {
        guard let ref else { return nil }
        let customs = WatchSettingsReader.shared.gatewayBadgeRoster
        switch ref {
        case .builtin(let backend):
            return (backend.shortCode, RemoteAgentBadgePalette.color(for: ref, customs: customs), backend.displayName)
        case .custom(let id):
            // A custom with no roster entry (deleted / not-yet-synced) → nothing,
            // mirroring the built-in "unknown backend → render nothing" rule.
            guard customs.contains(where: { $0.id == id }) else { return nil }
            let monogram = RemoteAgentRefMetadata.monogram(for: ref, customs: customs)
            guard !monogram.isEmpty else { return nil }
            return (
                monogram,
                RemoteAgentBadgePalette.color(for: ref, customs: customs),
                RemoteAgentRefMetadata.displayName(for: ref, customs: customs)
            )
        }
    }

    var body: some View {
        if let resolved {
            Text(resolved.monogram)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(resolved.tint)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(resolved.tint.opacity(0.18)))
                .overlay(Capsule().stroke(resolved.tint.opacity(0.35), lineWidth: 0.5))
                .accessibilityLabel(Text(resolved.label))
        }
        // else: unknown/empty ref OR deleted custom → render nothing.
    }
}
