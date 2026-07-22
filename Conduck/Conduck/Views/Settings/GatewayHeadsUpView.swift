// Conduck
// GatewayHeadsUpView.swift
//
// Guided-setup heads-up beat (iOS/iPadOS ONLY — the container's fork step routes
// macOS straight to readiness, since a Mac user is already at a computer). The
// steps that follow are desktop tasks rendered on a phone — running a shell
// command, pasting an adapter brief — so this single early screen sets the
// expectation ONCE: commands are coming, a computer is the comfortable place to
// run them, and the lane-correct conduck.com page has everything ready to copy.
// It replaces per-step "easier from a computer" cards (the adapter and commands
// steps used to each carry one, which read as the same nag twice).
//
// The URL is display-first (read it off the phone, type it on the computer),
// deliberately NOT a tappable Link — opening it on the phone is the exact detour
// this screen exists to prevent. Lane-correct is load-bearing: the custom lane's
// page carries the `--generic` command (and links the adapter contract); the
// full-agent page would pair the wrong service for a custom-lane user.
//
// Like every guided sub-step, the container paints the gradient + Back/Close
// chrome and owns routing; this view renders only the mascot / title / body card
// and pins its single filled CTA via `.onboardingStepLayout`.

import SwiftUI

struct GatewayHeadsUpView: View {
    /// The chosen lane (full-agent vs custom). Drives which site page the chip
    /// shows — `Constants.setupCommandPageURLDisplay(generic:)`.
    let lane: GatewaySetupLane
    /// Advance to the readiness step.
    let proceed: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            // Character — waving: the literal "heads up!" gesture.
            Image("conduck-waving")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .onboardingMascot()

            // Title
            Text(LocalizedStringResource(
                "gatewaySetup.headsUp.title",
                defaultValue: "Quick heads-up"
            ))
            .onboardingScaledFont(.title2, weight: .bold)
            .foregroundStyle(AppColors.textEmphasis)
            .multilineTextAlignment(.center)
            .accessibilityAddTraits(.isHeader)
            .padding(.horizontal, 32)

            bodyCard
        }
        .onboardingStepLayout {
            footer
        }
    }

    // MARK: - Body card

    /// The expectation-setter: commands ahead, a computer is comfier, and the
    /// lane-correct site page has everything. The URL renders as a quiet mono
    /// chip — "the thing to type", not a button — selectable so a power user can
    /// still copy/share it.
    private var bodyCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(LocalizedStringResource(
                "gatewaySetup.headsUp.body",
                defaultValue: "The next steps have you run a command in a terminal on your server. You can do everything from this phone — but it's easier from a computer."
            ))
            .onboardingScaledFont(.subheadline)
            .foregroundStyle(AppColors.textSecondary)
            .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 8) {
                Text(LocalizedStringResource(
                    "gatewaySetup.headsUp.pageLead",
                    defaultValue: "Everything you'll need is on this page:"
                ))
                .onboardingScaledFont(.footnote)
                .foregroundStyle(AppColors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

                Text(verbatim: Constants.setupCommandPageURLDisplay(generic: lane.isGeneric))
                    .onboardingScaledFont(.subheadline, weight: .semibold, design: .monospaced)
                    .foregroundStyle(AppColors.textEmphasis)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(AppColors.cardBackgroundElevated)
                    )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onboardingCardPadding()
        .glassCardBackground()
        .padding(.horizontal, 32)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("guidedSetup.headsUp.card")
    }

    // MARK: - Pinned footer (single filled CTA)

    private var footer: some View {
        Button(action: proceed) {
            Text(LocalizedStringResource(
                "gatewaySetup.headsUp.cta",
                defaultValue: "Got it — continue"
            ))
                .onboardingScaledFont(.headline)
                .foregroundColor(AppColors.textEmphasis)
                .frame(maxWidth: Constants.Layout.buttonMaxWidth)
                .padding(.vertical, 16)
                .background(Color.accentColor)
                .cornerRadius(14)
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, Constants.Layout.horizontalPadding)
        .accessibilityIdentifier("guidedSetup.headsUp.continue")
    }
}

#Preview("Full agent") {
    ZStack {
        LinearGradient(
            colors: [AppColors.gradientStart, AppColors.gradientEnd],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()

        GatewayHeadsUpView(lane: .fullAgent, proceed: {})
    }
}

#Preview("Custom") {
    ZStack {
        LinearGradient(
            colors: [AppColors.gradientStart, AppColors.gradientEnd],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()

        GatewayHeadsUpView(lane: .custom, proceed: {})
    }
}
