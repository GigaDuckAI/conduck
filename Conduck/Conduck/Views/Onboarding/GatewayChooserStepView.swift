// SPDX-License-Identifier: Apache-2.0

// Conduck
// GatewayChooserStepView.swift
//
// Gateway-first. The gateway is the only REQUIRED config
// (without it the core loop throws `remoteAgentNotConfigured`), so it leads.
// Now reached ONLY from the Settings guided-setup sheet
// (`GuidedGatewaySetupView`) — gateway setup is deferred out of first-run
// onboarding — so the sheet's own top-trailing Close is the exit; this view
// carries no "set up later" link.
//
// TWO SECTIONS, mirroring the Personal AI list's grouping:
//   "Your own AI" — the self-hosted server card (OpenClaw / Hermes → the
//     full-agent guided lane, via `onFullAgent`) and the Custom Gateway
//     card (any OpenAI-compatible endpoint, via `onCustom`).
//   "Hosted" — the OpenRouter card (`HostedModelGatewayStepView`), de-emphasized
//     and LAST (spec: OpenRouter is "never the default, visually separated").
//
// NEUTRAL by design: no card is badged or emphasized — we present a sensible
// ORDER (self-host first, hosted last) but never label a "recommended" winner.
// The full-agent card leads with the concrete product names (OpenClaw / Hermes),
// with "Runs on your own server" as its subtitle. `onCustom` is optional — when
// the user is already at the custom-gateway cap the container passes `nil` and
// the card is omitted (mirrors the list's disabled "Add custom gateway" row).
// The container owns routing; this view only reports the choice.

import SwiftUI

/// Guided-setup step that asks where Conduck should send your messages. The two
/// "own AI" cards plus the hosted card each hand the container one routing
/// branch (full-agent step / custom editor / hosted step).
struct GatewayChooserStepView: View {
    /// Self-hosted server branch (OpenClaw / Hermes) → the full-agent
    /// guided lane (readiness → helper → commands → scan/paste the
    /// `conduck-connect` setup code).
    let onFullAgent: () -> Void
    /// Custom model-server branch → the existing per-gateway editor (mint a
    /// draft + deep-link). `nil` when at the custom-gateway cap; the card is
    /// then hidden.
    let onCustom: (() -> Void)?
    /// Hosted-model branch (OpenRouter) → API key + model.
    let onHostedModel: () -> Void

    init(
        onFullAgent: @escaping () -> Void,
        onCustom: (() -> Void)? = nil,
        onHostedModel: @escaping () -> Void
    ) {
        self.onFullAgent = onFullAgent
        self.onCustom = onCustom
        self.onHostedModel = onHostedModel
    }

    var body: some View {
        VStack(spacing: 24) {
            // Character
            Image("conduck-astronaut")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .onboardingMascot()

            // Title
            Text("Where does your AI live?") // xcstrings: gateway-chooser
                .onboardingScaledFont(.title2, weight: .bold)
                .foregroundStyle(AppColors.textEmphasis)
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
                .padding(.horizontal, 32)

            // Choice cards — these ARE the actions, so they stay in the
            // scrollable content rather than a pinned footer. Grouped into two
            // sections (own AI first, hosted last). All cards are visually equal
            // (no badge, no emphasis); the only steer is section order.
            VStack(spacing: 20) {
                // Section 1 — the user's OWN AI (full self-hosted agents + any
                // custom OpenAI-compatible server they run).
                VStack(spacing: 12) {
                    sectionHeader("Your own AI") // xcstrings: gateway-chooser

                    OnboardingChoiceCard(
                        icon: "server.rack",
                        title: "OpenClaw or Hermes server", // xcstrings: gateway-chooser
                        subtitle: LocalizedStringResource(
                            "onboarding.gatewayChooser.selfHosted.subtitle",
                            defaultValue: "Runs on your own server — tools and file access."
                        ),
                        action: onFullAgent
                    )

                    // Hidden when the container is at the custom-gateway cap
                    // (`onCustom == nil`), matching the list's disabled Add row.
                    if let onCustom {
                        OnboardingChoiceCard(
                            icon: "cpu",
                            title: "An AI you built — or a custom server", // xcstrings: gateway-chooser
                            subtitle: "Anything OpenAI-compatible: Ollama, LiteLLM, and the like.", // xcstrings: gateway-chooser
                            action: onCustom
                        )
                    }
                }

                // Section 2 — third-party HOSTED models (OpenRouter), last.
                VStack(spacing: 12) {
                    sectionHeader("Hosted") // xcstrings: gateway-chooser

                    OnboardingChoiceCard(
                        icon: "cloud",
                        title: "OpenRouter with your key", // xcstrings: gateway-chooser
                        subtitle: "Start chatting in about a minute, no server setup required.", // xcstrings: gateway-chooser
                        action: onHostedModel
                    )
                }
            }
            .padding(.horizontal, 32)
        }
        .onboardingStepLayout {
            // No pinned footer: the cards ARE the actions, and there is no "set up
            // later" escape here (the guided-setup sheet owns a top-trailing Close).
            // The scaffold is still applied for its shared scroll/centering/width
            // treatment — an empty footer just yields the full viewport to the cards.
            EmptyView()
        }
    }

    /// A quiet, leading-aligned category label above a group of choice cards —
    /// the only chrome that distinguishes the "own AI" group from "Hosted".
    private func sectionHeader(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .onboardingScaledFont(.caption, weight: .semibold)
            .textCase(.uppercase)
            .foregroundStyle(AppColors.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 4)
            .accessibilityAddTraits(.isHeader)
    }
}

#Preview {
    ZStack {
        LinearGradient(
            colors: [AppColors.gradientStart, AppColors.gradientEnd],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()

        GatewayChooserStepView(
            onFullAgent: {},
            onCustom: {},
            onHostedModel: {}
        )
    }
}
