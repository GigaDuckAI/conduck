// SPDX-License-Identifier: Apache-2.0

// Conduck
// MessageActionButton.swift
//
// P3 — the reusable per-message footer action control (Speak / Copy) used by
// `MessageBubble.footer` in `ConversationThreadView.swift`. Two jobs:
//   1. A generous, platform-correct INVISIBLE hit region around a small visible
//      glyph (the old 12pt glyph had a sub-minimum tap target with zero slop).
//      iOS gets a full 44×44pt touch target (Apple HIG minimum is 44pt); macOS —
//      a precise-pointer surface — gets a tighter 28×24pt. `.contentShape` makes
//      the whole (otherwise transparent) frame tappable, not just the glyph.
//   2. A shared `PressableFooterButtonStyle` giving a subtle press-scale so the
//      controls feel tactile, Reduce-Motion aware (static under Reduce Motion).
//
// The control is content-agnostic: callers pass either a system-symbol name
// (Copy) or arbitrary label content (Speak, whose glyph is state-driven —
// idle/loading/playing — and includes a `ProgressView` in the loading state).
// Accessibility label is required so VoiceOver reads "Speak aloud" / "Loading" /
// "Stop" / "Copy" / "Copied" correctly.

import SwiftUI

// MARK: - Hit-region metrics (per platform)

/// Footer action-button hit-region size. iOS uses a full 44×44pt target (the HIG
/// minimum in both axes); macOS uses a tighter pointer-precise target.
/// Centralized so Speak + Copy stay identical.
private enum FooterHitRegion {
    #if os(macOS)
    static let width: CGFloat = 28
    static let height: CGFloat = 24
    #else
    static let width: CGFloat = 44
    static let height: CGFloat = 44
    #endif
}

// MARK: - MessageActionButton

/// A footer action button with a generous invisible hit region + press style.
/// Use the convenience `systemImage:` initializer for a plain state-less glyph
/// (Copy), or the `content:` initializer for state-driven label content (Speak).
struct MessageActionButton<Label: View>: View {
    /// VoiceOver label (already localized by the caller). Switches with state
    /// for the Speak control (Speak aloud / Loading / Stop).
    let accessibilityLabel: Text
    let action: () -> Void
    @ViewBuilder var label: () -> Label

    var body: some View {
        Button(action: action) {
            label()
                // The visible glyph sits centered inside a transparent frame
                // that is the actual tap target. `.contentShape(Rectangle())`
                // makes the whole frame (not just the glyph pixels) hittable.
                .frame(width: FooterHitRegion.width, height: FooterHitRegion.height)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableFooterButtonStyle())
        .accessibilityLabel(accessibilityLabel)
    }
}

extension MessageActionButton where Label == AnyView {
    /// Convenience for a plain state-less system-symbol glyph (Copy). The glyph
    /// is rendered at 16pt with the supplied tint.
    init(
        systemImage: String,
        size: CGFloat = 16,
        tint: Color,
        accessibilityLabel: Text,
        action: @escaping () -> Void
    ) {
        self.accessibilityLabel = accessibilityLabel
        self.action = action
        self.label = {
            AnyView(
                Image(systemName: systemImage)
                    .font(.system(size: size))
                    .foregroundStyle(tint)
            )
        }
    }
}

// MARK: - PressableFooterButtonStyle

/// Subtle press feedback for the footer action buttons: scales the glyph down
/// while pressed so the control feels tactile. Reduce-Motion aware — under
/// Reduce Motion the scale is pinned to 1.0 (no movement), so the state change
/// is instant + static. Shared by Speak + Copy for a consistent feel.
struct PressableFooterButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(scale(pressed: configuration.isPressed))
            .animation(reduceMotion ? nil : .spring(response: 0.25, dampingFraction: 0.6),
                       value: configuration.isPressed)
    }

    private func scale(pressed: Bool) -> CGFloat {
        guard pressed, !reduceMotion else { return 1.0 }
        return 0.88
    }
}
