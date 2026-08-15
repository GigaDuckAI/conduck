// SPDX-License-Identifier: Apache-2.0

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
// Reached two ways. Pushed from the chooser it is an ordinary step with a Back
// arrow and a generic lane title. As the ENTRY step of an unconfigured `.custom`
// quick connect it has neither — the back-stack is empty there, which is fine
// because its two cards ARE the way forward and the container's ✕ is the way out —
// and it takes a `gatewayName` so the screen confirms WHICH gateway is being
// paired, the one thing the chooser's fork cannot know. Routing is identical from
// both entries, so the flow converges one step in.
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
    /// Names the gateway this fork was deep-linked to, so the screen confirms WHICH
    /// one is being paired. nil on the guided path (no gateway chosen yet) and for a
    /// draft with no name — both keep the lane title. Resolved by
    /// `GuidedGatewaySetupView.forkGatewayName`, which owns the nil rules.
    var gatewayName: String? = nil
    /// Primary branch — walk the user through creating a `conduck-connect` code.
    let onCreateCode: () -> Void
    /// Secondary branch — scan/paste a code the user already minted.
    let onHaveCode: () -> Void

    /// Lane-specific screen title — the fallback when no gateway is named.
    private var title: LocalizedStringKey {
        switch lane {
        case .fullAgent:
            return "Connect your AI server" // xcstrings: gateway-setup-fork
        case .custom:
            return "Connect your own server" // xcstrings: gateway-setup-fork
        }
    }

    /// The title as a `Text`, because its two forms resolve differently and only one
    /// of them may be looked up: the lane titles are catalog keys, while the named
    /// form is ALREADY formatted at runtime and must render verbatim — handing it to
    /// a `LocalizedStringKey` would send the user's own gateway name to the catalog
    /// as a lookup key and show whatever came back.
    private var titleText: Text {
        guard let gatewayName else { return Text(title) }
        // A NEW key, never a reword of the lane titles: a catalog value wins over
        // `defaultValue:`, so re-pointing an existing key's copy renders nothing
        // (`CLAUDE-apple.md` §4.5). Interpolation follows the same
        // `String(localized:)` + `String(format:)` shape as
        // `GatewayReadinessView.getServerSentence`.
        let template = String(localized: LocalizedStringResource(
            "gatewaySetup.fork.title.named",
            defaultValue: "Connect %@"
        ))
        return Text(verbatim: String(format: template, gatewayName))
    }

    var body: some View {
        VStack(spacing: 24) {
            // Character
            Image("conduck-scientist")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .onboardingMascot()

            // Title
            titleText
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

// The quick-connect entry: deep-linked to one named gateway, so the title confirms
// it instead of asking the generic lane question.
#Preview("Custom — named (quick connect)") {
    ZStack {
        LinearGradient(
            colors: [AppColors.gradientStart, AppColors.gradientEnd],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()

        GatewaySetupForkView(
            lane: .custom,
            gatewayName: "LiteLLM",
            onCreateCode: {},
            onHaveCode: {}
        )
    }
}
