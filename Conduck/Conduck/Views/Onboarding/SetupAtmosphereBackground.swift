// Conduck
// SetupAtmosphereBackground.swift
//
// Premium warm-dark backdrop for the setup surfaces (first-run onboarding +
// the guided gateway-setup sheet). Replaces the near-flat two-near-black
// `LinearGradient(gradientStart→gradientEnd)` those containers used to paint —
// that read as "boring", not as the app's most important moment.
//
// A STATIC 3×3 `MeshGradient` warm-black base, lit by a NEUTRAL key light
// behind the mascot and two faint cool corner ambients (depth, never a layer
// that reads as a color), plus an edge vignette to keep controls/footer
// legible. All layers are FULL-BLEED on every platform — the mascots are the
// only saturated color on screen; a tinted or width-capped wash behind them
// muddies the field and camouflages the yellow duck art.
//
// Motion is ONE arrival moment, then quiet: the key light fades in once
// (~0.8s) and holds. NO looping mesh drift — full-screen moving color reads
// as a screensaver. Under Reduce Motion the final composite renders immediately
// (never 0 → jump). Decorative → `accessibilityHidden`. The mascot's own ~6pt
// settle lives in the step view, not here (a background can't move a sibling).

import SwiftUI

struct SetupAtmosphereBackground: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Key-light entrance gate. Under Reduce Motion the layer's opacity is
    /// forced to its final value in `body` (so there is never a 0-opacity frame);
    /// otherwise this flips `false → true` once in `onAppear`, animating the fade.
    @State private var glowIn = false

    // Warm-black base inks (near-#121010, barely-perceptible spread).
    private let deepInk = Color(red: 0.047, green: 0.043, blue: 0.041)   // ~#0C0B0A corners
    private let counterBlue = Color(red: 0.35, green: 0.45, blue: 0.62)  // desaturated setup-blue
    private let keyGlow = Color(red: 0.92, green: 0.93, blue: 0.96)      // neutral, a hint cool

    var body: some View {
        ZStack {
            baseMesh                                   // full-window warm-black
            tintedGlows                                // neutral key light + cool ambients
            vignette                                   // full-window edge darken
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
        .onAppear {
            guard !reduceMotion else { return }        // Reduce Motion: opacity already final in body
            withAnimation(.easeOut(duration: 0.8)) { glowIn = true }
        }
    }

    // MARK: - Layers

    /// 3×3 warm-ink mesh: deepest at the corners, base along the edges, a hair of
    /// lift at the center. Barely perceptible — atmosphere, not decoration.
    private var baseMesh: some View {
        MeshGradient(
            width: 3,
            height: 3,
            points: [
                SIMD2<Float>(0.0, 0.0), SIMD2<Float>(0.5, 0.0), SIMD2<Float>(1.0, 0.0),
                SIMD2<Float>(0.0, 0.5), SIMD2<Float>(0.5, 0.5), SIMD2<Float>(1.0, 0.5),
                SIMD2<Float>(0.0, 1.0), SIMD2<Float>(0.5, 1.0), SIMD2<Float>(1.0, 1.0),
            ],
            colors: [
                deepInk, AppColors.background, deepInk,
                AppColors.background, AppColors.cardBackground, AppColors.background,
                deepInk, AppColors.background, deepInk,
            ]
        )
    }

    /// The lights: a neutral key light behind the mascot (the only animated
    /// layer) and two faint cool corner ambients — depth, never a color the eye
    /// can name. Fixed point radii + `UnitPoint` centers, so they neither
    /// stretch nor clip at any window size — full-bleed everywhere.
    private var tintedGlows: some View {
        ZStack {
            // Key light — behind the mascot zone, fading before the headline.
            RadialGradient(
                colors: [keyGlow.opacity(0.06), keyGlow.opacity(0)],
                center: UnitPoint(x: 0.5, y: 0.30),
                startRadius: 0,
                endRadius: 440
            )
            .opacity(reduceMotion ? 1 : (glowIn ? 1 : 0))

            // Cool pool, one lower corner.
            RadialGradient(
                colors: [counterBlue.opacity(0.05), .clear],
                center: UnitPoint(x: 0.85, y: 0.90),
                startRadius: 0,
                endRadius: 380
            )

            // Faint desaturated-blue counterlight, opposite corner — just depth.
            RadialGradient(
                colors: [counterBlue.opacity(0.04), .clear],
                center: UnitPoint(x: 0.15, y: 0.22),
                startRadius: 0,
                endRadius: 320
            )
        }
    }

    /// Edge vignette — clear center darkening to warm-black at the edges so
    /// controls and the pinned footer stay legible over the lit background.
    private var vignette: some View {
        RadialGradient(
            colors: [.clear, Color.black.opacity(0.22)],
            center: .center,
            startRadius: 140,
            endRadius: 660
        )
    }
}

#Preview {
    ZStack {
        SetupAtmosphereBackground()
        Text(verbatim: "Setup")
            .font(.largeTitle.bold())
            .foregroundStyle(AppColors.textEmphasis)
    }
}
