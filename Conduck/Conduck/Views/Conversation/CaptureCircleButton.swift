// Conduck
// CaptureCircleButton.swift
//
// Part 2 — the premium FILLED-CIRCLE capture/send control shared by the iOS
// composer (compact + regular layouts) and the macOS window composer. Replaces
// the bare SF-Symbol glyph with an iMessage/WhatsApp-style coloured disc + a
// white glyph, so each state reads as a real, distinct button:
//
//   idle (mic)       → brandAmber circle + white "mic.fill"
//   recording (stop) → error-red circle + white "stop.fill" + a soft pulsing halo
//   processing       → disabled-grey circle + white "ellipsis"
//   send             → brandAmber circle + white "arrow.up" (disabled → grey)
//   in-flight stop    → neutral (textSecondary) circle + white "stop.fill"
//
// LOAD-BEARING IDENTITY (see iOSMessageComposerBar ~:232): the control is a
// SINGLE `Button` wrapping a SINGLE `Image(systemName:)`. That stable identity is
// what lets `.contentTransition(.symbolEffect(.replace))` MORPH the glyph on a
// state change instead of snap-replacing the whole view. The circle fill is a
// `.background`, so changing it never disturbs the Image's identity. Callers must
// keep passing one symbol string + one fill colour per state — do NOT branch into
// separate Buttons.
//
// Press feedback is a Reduce-Motion-aware scaleEffect via `CaptureButtonStyle`.
// The pulsing halo is also Reduce-Motion-aware (static ring when motion is off).

import SwiftUI

// MARK: - Capture circle button

/// A filled-circle capture/send control. One `Button` + one morphing `Image`.
struct CaptureCircleButton: View {
    /// SF Symbol for the glyph (e.g. "mic.fill", "stop.fill", "arrow.up",
    /// "ellipsis"). Drives `.contentTransition(.symbolEffect(.replace))`.
    let symbol: String
    /// The circle's fill colour (state-driven). The glyph is always white.
    let fillColor: Color
    /// True only in the RECORDING state — draws the soft pulsing halo. Static
    /// ring under Reduce Motion.
    var showsPulse: Bool = false
    /// True only when the glyph should run a repeating symbol pulse (recording).
    var animatesSymbol: Bool = false
    /// Diameter of the disc. 44 on iOS (hit-target), 32 on the denser macOS row.
    var diameter: CGFloat = 44
    /// Point size of the white glyph inside the disc.
    var glyphSize: CGFloat = 20
    let isDisabled: Bool
    let accessibilityLabel: String
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: glyphSize, weight: .semibold))
                .foregroundStyle(.white)
                .contentTransition(.symbolEffect(.replace))
                .symbolEffect(.pulse.byLayer, options: .repeating, isActive: animatesSymbol && !reduceMotion)
                .frame(width: diameter, height: diameter)
                .background(
                    Circle()
                        .fill(fillColor)
                        // The halo lives BEHIND the fill so it reads as a ring
                        // bleeding past the disc edge.
                        .background(pulseHalo)
                )
                .contentShape(Circle())
                .animation(.snappy(duration: 0.25), value: symbol)
                .animation(.easeInOut(duration: 0.2), value: fillColor)
        }
        .buttonStyle(CaptureButtonStyle(reduceMotion: reduceMotion))
        .disabled(isDisabled)
        .accessibilityLabel(Text(accessibilityLabel))
    }

    /// The recording-state halo: a soft expanding/contracting ring. Under Reduce
    /// Motion it collapses to a static faint ring (no animation).
    @ViewBuilder
    private var pulseHalo: some View {
        if showsPulse {
            PulseHalo(color: fillColor, diameter: diameter, reduceMotion: reduceMotion)
        }
    }
}

// MARK: - Pulse halo

/// A soft pulsing ring drawn behind the recording disc. Reduce-Motion → a static
/// faint ring (no repeating animation), so the state is still legible.
private struct PulseHalo: View {
    let color: Color
    let diameter: CGFloat
    let reduceMotion: Bool

    @State private var pulsing = false

    var body: some View {
        Circle()
            .fill(color.opacity(reduceMotion ? 0.25 : (pulsing ? 0.0 : 0.35)))
            .frame(width: diameter, height: diameter)
            .scaleEffect(reduceMotion ? 1.25 : (pulsing ? 1.6 : 1.0))
            .animation(
                reduceMotion ? nil : .easeOut(duration: 1.1).repeatForever(autoreverses: false),
                value: pulsing
            )
            .onAppear { if !reduceMotion { pulsing = true } }
            .allowsHitTesting(false)
    }
}

// MARK: - Press style

/// Press-state scale for the capture controls (~0.92). Reduce-Motion → no scale
/// (the button still functions; only the squish is suppressed).
struct CaptureButtonStyle: ButtonStyle {
    let reduceMotion: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect((configuration.isPressed && !reduceMotion) ? 0.92 : 1.0)
            .animation(reduceMotion ? nil : .spring(response: 0.25, dampingFraction: 0.6),
                       value: configuration.isPressed)
    }
}
