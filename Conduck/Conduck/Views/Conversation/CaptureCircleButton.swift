// SPDX-License-Identifier: Apache-2.0

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
//
// ONE effect on the glyph, deliberately. The glyph carries the `.replace`
// content transition and nothing else: a repeating symbol pulse stacked on the
// same `Image` toggled at the exact instant the glyph swapped (mic → stop, stop
// → ellipsis) and the two contended for one layer, which read as the button
// "morphing". Recording is already told twice — the red disc and the halo — and
// the composer's status row adds a third; the glyph stays still.

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
///
/// An auto-cycling `phaseAnimator` rather than a `repeatForever` animation
/// keyed on `@State` from `onAppear`: that form is re-issued only on appear and
/// stalls or restarts when an ancestor's transaction (the bar's attachment
/// spring, the slot crossfade) passes through mid-capture, while the animator
/// owns its own clock. The expand phase animates out; the reset phase has NO
/// animation, so the ring snaps back to the disc and expands again — the
/// original one-way pulse, not a breathing in-and-out.
private struct PulseHalo: View {
    let color: Color
    let diameter: CGFloat
    let reduceMotion: Bool

    var body: some View {
        Group {
            if reduceMotion {
                ring
                    .opacity(0.25)
                    .scaleEffect(1.25)
            } else {
                ring
                    .phaseAnimator([false, true]) { view, expanded in
                        view
                            .opacity(expanded ? 0.0 : 0.35)
                            .scaleEffect(expanded ? 1.6 : 1.0)
                    } animation: { expanded in
                        expanded ? Animation.easeOut(duration: 1.1) : nil
                    }
            }
        }
        .allowsHitTesting(false)
    }

    private var ring: some View {
        Circle()
            .fill(color)
            .frame(width: diameter, height: diameter)
    }
}

// MARK: - Press style

/// Press-state scale for the capture controls (~0.92). Reduce-Motion → no scale
/// (the button still functions; only the squish is suppressed).
struct CaptureButtonStyle: ButtonStyle {
    let reduceMotion: Bool

    func makeBody(configuration: Configuration) -> some View {
        #if os(macOS)
        HoverBody(configuration: configuration, reduceMotion: reduceMotion)
        #else
        configuration.label
            .scaleEffect((configuration.isPressed && !reduceMotion) ? 0.92 : 1.0)
            .animation(reduceMotion ? nil : .spring(response: 0.25, dampingFraction: 0.6),
                       value: configuration.isPressed)
        #endif
    }

    #if os(macOS)
    /// macOS adds POINTER feedback on top of the press scale: without it the two
    /// most-used controls in the app look identical whether the cursor is on the
    /// disc or 3pt off it. The disc paints an opaque, saturated fill, so it takes
    /// the brightness lift `PrimaryCTAButtonStyle` uses rather than a tint wash —
    /// a 7% overlay is invisible over that fill.
    ///
    /// A `ButtonStyle` is not a `View`, so `@State` cannot live on the style
    /// itself; hover tracking goes in this nested view, which is one.
    private struct HoverBody: View {
        let configuration: Configuration
        let reduceMotion: Bool

        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false

        var body: some View {
            configuration.label
                .scaleEffect((configuration.isPressed && !reduceMotion) ? 0.92 : 1.0)
                .brightness(brightness)
                .onHover { hovering = $0 }
                .animation(reduceMotion ? nil : .spring(response: 0.25, dampingFraction: 0.6),
                           value: configuration.isPressed)
                .animation(MacPointer.highlightAnimation, value: hovering)
        }

        /// `.clear`-equivalent when disabled: a highlight on an inert control is
        /// a lie about what a click would do.
        private var brightness: Double {
            guard isEnabled else { return 0 }
            if configuration.isPressed { return -0.07 }
            return hovering ? 0.10 : 0
        }
    }
    #endif
}
