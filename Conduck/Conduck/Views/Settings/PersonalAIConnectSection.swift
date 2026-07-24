// Conduck
// PersonalAIConnectSection.swift
//
// The "Connect" section on the populated Personal AI screen — shared iOS + macOS
// so the setup affordance lives in ONE place. A single "Guided Setup" row (the
// lane chooser entry) — the front door for someone who doesn't yet know which
// gateway lane they want. Scanning/pasting a setup code is NOT a list-level row:
// the chooser's guided flow owns that step, while a gateway detail's Quick
// connect row deep-links the same flow to that specific ref.
//
// PROMINENCE IS CONDITIONAL (`emphasized`). This row is PERMANENT — it stays in
// Settings for a user who already has three gateways wired up — so it earns its
// loudness only while there is nothing configured, where it IS the primary action
// (and pairs with the amber "Not configured" default row directly above it). Once
// a gateway exists it relaxes to a calm blue utility row: a tinted, glinting
// "Guided Setup" CTA nagging a user who already connected would read as a banner,
// not an affordance.
//
// Emphasized = a blue-tinted row card (a cool card in a field of warm-grey ones)
// plus ONE sheen sweep on appear — a foil catching the light once, then still. A
// looping shimmer is deliberately avoided: perpetual motion in a settings list is
// visual noise, and the static treatment must carry the weight anyway because the
// sweep is suppressed under Reduce Motion.
//
// Presentation only: the action is owned by the caller (the platform file flips
// its guided-setup presentation @State).

import SwiftUI

/// The guided-setup row for the "Connect" section. Stateless w.r.t. app data; the
/// parent owns the action (present `GuidedGatewaySetupView` with `initialPath: nil`)
/// and resolves `emphasized`.
struct PersonalAIConnectRows: View {
    /// Emphasize the row (tinted card + one-shot sheen). Callers pass
    /// `hasLoadedRemoteAgentState && configuredRemoteAgentRefSet.isEmpty` — the
    /// hydration flag is load-bearing: `configuredRemoteAgentRefSet` is empty
    /// until the VM loads, so without it a CONFIGURED user would see the row
    /// flash emphasized (and fire a stray sweep) before settling.
    let emphasized: Bool
    /// Present the guided-setup chooser (`GuidedGatewaySetupView`, `initialPath: nil`).
    let onGuidedSetup: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Sheen travel, 0 (off the leading edge) → 1 (off the trailing edge).
    @State private var sweepPhase: CGFloat = 0
    /// One sweep per appearance — never a loop.
    @State private var hasSwept = false

    var body: some View {
        Button(action: onGuidedSetup) {
            HStack(spacing: 12) {
                Image(systemName: "wand.and.stars")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(AppColors.guidedSetupBlue)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 2) {
                    Text(
                        LocalizedStringResource(
                            "settings.personalAI.connect.guidedSetup.label",
                            defaultValue: "Guided Setup"
                        )
                    )
                    .font(.body.weight(.semibold))
                    .foregroundStyle(AppColors.guidedSetupBlue)

                    // Gives the row mass. Without it, "Guided Setup" is a short
                    // label floating alone in a tall card while every neighbouring
                    // row carries a value + chevron — which is most of why it read
                    // as passive text rather than the screen's primary action.
                    Text(
                        LocalizedStringResource(
                            "settings.personalAI.connect.guidedSetup.subtitle",
                            defaultValue: "Connect your AI in a few steps."
                        )
                    )
                    .font(.footnote)
                    .foregroundStyle(AppColors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                // Matches the navigable rows around it — this row goes somewhere,
                // so it should say so.
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(AppColors.textTertiary)
            }
            // Span the full row so the tap target isn't just the label's intrinsic
            // width — without this, a tap on the right (empty) half of the row
            // misses the button entirely.
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("settings.personalAI.guidedSetup")
        .padding(.vertical, 4)
        // `nil` restores the platform's default row card — the calm state. The
        // sheen lives in the row BACKGROUND rather than masked over the label, so
        // it cannot touch hit-testing or VoiceOver: the whole card catches the
        // light (a foil card tilted to a lamp), the text sits on top untouched.
        .listRowBackground(emphasisBackground)
        .onAppear { startSweepIfNeeded() }
        // `emphasized` flips false→true when the VM hydrates, which can land AFTER
        // `.onAppear` — so the sweep must also be armed on that transition, or the
        // unconfigured user (the only one it's for) would never see it.
        .onChange(of: emphasized) { _, _ in startSweepIfNeeded() }
    }

    // MARK: - Emphasis

    /// `nil` → default row card (calm). Typed `AnyView?` because `listRowBackground`
    /// keys "use the default" off a nil view, and `EmptyView` is NOT that — it would
    /// render a transparent row and strip the card entirely.
    private var emphasisBackground: AnyView? {
        guard emphasized else { return nil }
        return AnyView(
            ZStack {
                AppColors.guidedSetupBlue.opacity(0.16)
                if !reduceMotion {
                    sheen
                }
            }
            // Blend the sheen against the blue tint (not against whatever the list
            // paints behind the row), then clip the rotated band to the card.
            .compositingGroup()
            .clipped()
        )
    }

    /// One diagonal specular band, swept once across the card.
    private var sheen: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let band: CGFloat = 120

            LinearGradient(
                stops: [
                    .init(color: .white.opacity(0), location: 0),
                    .init(color: .white.opacity(0.30), location: 0.5),
                    .init(color: .white.opacity(0), location: 1)
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
            // Overheight so the rotated band still covers the card's full height.
            .frame(width: band, height: geo.size.height * 2.6)
            .rotationEffect(.degrees(18))
            // Center travels from fully off the leading edge to fully off the trailing one.
            .position(
                x: -band + sweepPhase * (width + band * 2),
                y: geo.size.height / 2
            )
            .blendMode(.plusLighter)
        }
        .allowsHitTesting(false)
    }

    /// Arms the single sweep. Idempotent — `hasSwept` makes a second call a no-op,
    /// so `.onAppear` + the hydration `.onChange` can both fire safely.
    private func startSweepIfNeeded() {
        guard emphasized, !reduceMotion, !hasSwept else { return }
        hasSwept = true
        // A beat of delay so the eye has landed on the screen before it glints.
        withAnimation(.easeInOut(duration: 1.15).delay(0.35)) {
            sweepPhase = 1
        }
    }
}
