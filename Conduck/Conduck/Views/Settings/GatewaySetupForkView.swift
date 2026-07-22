// Conduck
// GatewaySetupForkView.swift
//
// First step of the redesigned guided gateway-setup flow (`GuidedGatewaySetupView`).
// Fixes the #1 usability problem: users didn't know a `conduck-connect` setup code
// EXISTS, so they hunted for a scanner and stalled. This screen leads with CREATE
// (emphasis) — "we'll walk you through making one" — and demotes "I already have a
// code" to the secondary pick. Same view serves both self-hosted lanes
// (`GatewaySetupLane`); only the title and the optional manual-fallback differ.
//
// Mirrors `GatewayChooserStepView`'s contract with its container: the parent paints
// the gradient + Back/Close chrome and owns all routing; this view renders only the
// mascot/title/cards and hands each tap back through a closure. The fork offers ONLY
// the two guided branches — no manual-entry escape link. Hand-editing URL/token stays
// reachable outside the guide (a gateway row / "+ Add custom gateway" in the Personal
// AI list, and the primer's "Set up manually"), so the guided path stays a clean
// two-choice screen instead of a third, lower-success lane. The "you'll run a
// command — easier from a computer" expectation is NOT set here: on iPhone/iPad the
// create branch's very next screen is the dedicated heads-up step, which says it in
// full (a footnote here would be the same message twice, one tap apart).

import SwiftUI

/// Guided-setup fork asking HOW the user wants to connect: create a fresh setup
/// code (primary) or use one they already have. Each branch hands the container one
/// routing decision.
struct GatewaySetupForkView: View {
    /// Which self-hosted lane drives the copy (`fullAgent` vs `custom`).
    let lane: GatewaySetupLane
    /// Primary branch — walk the user through creating a `conduck-connect` code.
    let onCreateCode: () -> Void
    /// Secondary branch — scan/paste a code the user already minted.
    let onHaveCode: () -> Void

    /// Lane-specific screen title.
    private var title: LocalizedStringKey {
        switch lane {
        case .fullAgent:
            return "Connect your AI server" // xcstrings: gateway-setup-fork
        case .custom:
            return "Connect your own server" // xcstrings: gateway-setup-fork
        }
    }

    var body: some View {
        VStack(spacing: 24) {
            // Character
            Image("conduck-scientist")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .onboardingMascot()

            // Title
            Text(title)
                .onboardingScaledFont(.title2, weight: .bold)
                .foregroundStyle(AppColors.textEmphasis)
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
                .padding(.horizontal, 32)

            // Choice cards — these ARE the actions, so they live in the scrollable
            // content rather than the pinned footer. CREATE leads with emphasis
            // (the fix: surface that a setup code can be made here); "I already have
            // a code" is the secondary pick.
            VStack(spacing: 12) {
                OnboardingChoiceCard(
                    icon: "sparkles",
                    title: "Create a setup code", // xcstrings: gateway-setup-fork
                    subtitle: "We'll walk you through it, step by step.", // xcstrings: gateway-setup-fork
                    emphasis: true,
                    action: onCreateCode
                )

                OnboardingChoiceCard(
                    icon: "qrcode.viewfinder",
                    title: "I already have a code", // xcstrings: gateway-setup-fork
                    subtitle: "Scan or paste a code from conduck-connect.", // xcstrings: gateway-setup-fork
                    action: onHaveCode
                )
            }
            .padding(.horizontal, 32)
        }
        .onboardingStepLayout {
            // No pinned footer: the two cards ARE the actions. The scaffold still
            // applies for its shared scroll/centering/width treatment.
            EmptyView()
        }
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

        GatewaySetupForkView(
            lane: .fullAgent,
            onCreateCode: {},
            onHaveCode: {}
        )
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

        GatewaySetupForkView(
            lane: .custom,
            onCreateCode: {},
            onHaveCode: {}
        )
    }
}
