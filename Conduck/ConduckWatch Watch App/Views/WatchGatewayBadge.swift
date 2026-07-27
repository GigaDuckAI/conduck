// SPDX-License-Identifier: Apache-2.0

// Conduck
// WatchGatewayBadge.swift
//
// Compact per-conversation gateway monogram ("OC" / "H" / a custom's monogram)
// for the Watch conversation list rows AND the thread header. Derives the REF
// from the stored `ConversationRecord.backend` raw string; renders NOTHING when
// the ref is unknown/empty OR a custom whose roster entry is missing (deleted /
// not-yet-synced) so the row never shows a meaningless box.
//
// Capsule HUGS its text, so monograms of different widths read as clean
// pill-tags rather than misaligned fixed-width chips. Tint distinguishes
// gateways at a glance: built-ins keep their reserved hues (OpenClaw orange,
// Hermes teal); customs use their assigned `RemoteAgentBadgePalette` color +
// roster monogram (NOT a UUID hash).

import SwiftUI

struct WatchGatewayBadge: View {
    let backendRawValue: String

    /// The custom-gateway roster the Watch received via the multi-envelope —
    /// source of a custom's monogram + badge color. Read from the shared reader;
    /// pure (no actor hop) since `customGateways` is a plain published value.
    private var customs: [CustomGateway] {
        WatchSettingsReader.shared.customGateways
    }

    private var ref: RemoteAgentRef? {
        RemoteAgentRef(rawString: backendRawValue)
    }

    /// Monogram + tint + accessibility label for the resolved ref, or nil when
    /// the ref is unparseable OR a custom missing from the roster (deleted /
    /// never-synced) — both render nothing.
    private var resolved: (monogram: String, tint: Color, label: String)? {
        guard let ref else { return nil }
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
