// SPDX-License-Identifier: Apache-2.0

// Conduck
// GatewayBadge.swift
//
// Custom-gateways. The shared visual identity badge for a `RemoteAgentRef`:
// a solid colored circle filled with the gateway's reserved/assigned hue and
// its 1–2 char white monogram (OpenClaw "OC", Hermes "H", a custom's derived
// or explicit monogram). Mirrors the Share-extension "Send to" picker badge
// (`ShareView.badge(monogram:fill:)`) so the in-app overview surfaces match
// what the user already sees there.
//
// Identity is resolved from the SAME pure helpers used everywhere else
// (`RemoteAgentRefMetadata` + `RemoteAgentBadgePalette`) — no per-call-site
// re-derivation. Renders nothing when the monogram can't resolve (a deleted /
// not-yet-synced custom gateway), so an orphaned thread shows no badge rather
// than a blank circle. Built-ins always resolve.
//
// App target only (iPhone / iPadOS / macOS + CarPlay). NOT a Watch member —
// the Watch keeps its own inline `WatchGatewayBadge`.

import SwiftUI

/// Solid colored circle + white bold monogram identifying a gateway.
struct GatewayBadge: View {
    /// The conversation's bound gateway.
    let ref: RemoteAgentRef
    /// Custom-gateway roster snapshot (resolves a custom's name / color /
    /// monogram; pass `[]` when only built-ins are in play).
    let customs: [CustomGateway]
    /// Outer diameter in points. List rows use the default; CarPlay rasterizes
    /// a slightly larger one (see `image(for:customs:diameter:)`).
    var diameter: CGFloat = 26

    var body: some View {
        let monogram = RemoteAgentRefMetadata.monogram(for: ref, customs: customs)
        if monogram.isEmpty {
            // Unresolvable custom (deleted / un-synced) → render nothing.
            EmptyView()
        } else {
            ZStack {
                Circle()
                    .fill(RemoteAgentBadgePalette.color(for: ref, customs: customs))
                Text(monogram)
                    .font(.system(size: diameter * 0.4, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
            }
            .frame(width: diameter, height: diameter)
            .accessibilityElement()
            // The gateway name is data / a brand noun, not a localizable
            // template — `verbatim` keeps it out of the string catalog.
            .accessibilityLabel(Text(verbatim: RemoteAgentRefMetadata.displayName(for: ref, customs: customs)))
        }
    }

    #if os(iOS)
    /// Rasterize the badge to a `UIImage` for a CarPlay `CPListItem` leading
    /// image. `@MainActor` because `ImageRenderer` requires it. Returns nil for
    /// an unresolvable ref (the row then renders with no image). Fixed `@3x`
    /// scale is sharp on every head-unit display (their scales vary).
    @MainActor
    static func image(for ref: RemoteAgentRef, customs: [CustomGateway], diameter: CGFloat = 30) -> UIImage? {
        guard !RemoteAgentRefMetadata.monogram(for: ref, customs: customs).isEmpty else { return nil }
        let renderer = ImageRenderer(content: GatewayBadge(ref: ref, customs: customs, diameter: diameter))
        renderer.scale = 3
        return renderer.uiImage
    }
    #endif
}
