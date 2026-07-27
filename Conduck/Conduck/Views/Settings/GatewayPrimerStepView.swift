// SPDX-License-Identifier: Apache-2.0

// Conduck
// GatewayPrimerStepView.swift
//
// Step 0 of the guided gateway-setup flow (`GuidedGatewaySetupView`): the
// orientation beat that resets the surprising expectation "this app has no AI of
// its own." Conduck is the voice/interface; the AI is the user's — a gateway they
// run, any OpenAI-compatible endpoint, or OpenRouter with their own key. Without
// this reset, a scanning first-run user can tap a lane card, hit a scan-a-setup-
// code wall, and bounce ("what setup code? I just wanted to chat").
//
// Its headline ("How Conduck works") is an ORIENTATION title, NOT a task title —
// this is the ONLY non-task screen in the flow (every other step titles a job:
// "Where does your AI live?" · "Is your server running?" · "Create your setup code"
// · "Copy the setup command"). A task title here also collided head-on with the
// `fork`'s "Connect your AI server" three steps later. Keep the register.
//
// Shown only for a genuine unconfigured first-timer (gated in
// `GuidedGatewaySetupView`: unseen primer flag AND no configured gateway); a
// configured user re-running guided setup, or a lane deep-link, never sees it.
//
// THREE ranked exits: a PRIMARY filled "Guide me through it" (→ the chooser),
// a SECONDARY bordered "Set up manually" (→ the Personal AI list), and a TERTIARY
// link to the web setup guide (opens Safari WITHOUT dismissing the sheet). The
// container's top-trailing ✕ Close ("not now" → back to chat) is the fourth,
// unmarked, exit — Close never marks the primer seen, so it re-shows next time.
//
// Like every guided sub-step, the container paints the background + Back/Close
// chrome; this view renders the mascot / headline / body and pins its footer via
// `.onboardingStepLayout`. The mascot's one-time ~6pt settle lives here (the
// background's amber fade lives in `SetupAtmosphereBackground`).

import SwiftUI

struct GatewayPrimerStepView: View {
    /// PRIMARY — advance to the "Where does your AI live?" chooser.
    let onChoose: () -> Void
    /// SECONDARY — leave the guided flow for the Personal AI list (manual setup).
    let onManual: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Drives the mascot's one-time settle (offset + fade). Set true immediately
    /// under Reduce Motion (no animation).
    @State private var settled = false

    var body: some View {
        VStack(spacing: 24) {
            // Character — the master builder: you're the one in control of the AI.
            Image("conduck-card-tower")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .onboardingMascot(hero: true)
                .offset(y: settled ? 0 : 6)
                .opacity(settled ? 1 : 0)

            // Headline
            Text("How Conduck works") // xcstrings: gateway-primer
                .onboardingScaledFont(.title, weight: .bold)
                .foregroundStyle(AppColors.textEmphasis)
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
                .padding(.horizontal, 32)

            bodyCard
        }
        .onboardingStepLayout {
            footer
        }
        .onAppear {
            guard !reduceMotion else { settled = true; return }
            withAnimation(.easeOut(duration: 0.7)) { settled = true }
        }
    }

    // MARK: - Body

    /// The mental-model reset, ≤2 sentences. Deliberately does NOT name the three
    /// lanes — that would only spoil the chooser cards on the very next screen — and
    /// avoids the misleading universals: "host a model" (a self-hosted gateway
    /// usually calls a CLOUD model, so it implies the wrong thing) and "run a server"
    /// (false for the hosted OpenRouter lane).
    ///
    /// The remote-control image carries the whole invariant in one beat: the device
    /// in your hand is the control surface, the AI it drives is YOURS (you set it up,
    /// you run it, you pay for it). It survives every lane — a self-hosted agent, a
    /// custom endpoint, or a hosted model on your own key are all "the AI you set up
    /// and run yourself." Do NOT trade it for a literal enumeration of what the user
    /// must supply; the concrete asks land on the screens that actually ask for them.
    private var bodyCard: some View {
        Text("Conduck is a client, not an AI service — it has no AI of its own. Think of it like a remote control that talks to the AI you set up and run yourself.") // xcstrings: gateway-primer
            .onboardingScaledFont(.subheadline)
            .foregroundStyle(AppColors.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .onboardingCardPadding()
            .glassCardBackground()
            .padding(.horizontal, 32)
    }

    // MARK: - Pinned footer (3 ranked exits)

    private var footer: some View {
        VStack(spacing: 14) {
            // PRIMARY — filled accent CTA (matches the guided flow's other primary
            // CTAs, e.g. GatewayReadinessView).
            Button(action: onChoose) {
                Text("Guide me through it") // xcstrings: gateway-primer
                    .onboardingScaledFont(.headline)
                    .foregroundColor(AppColors.textEmphasis)
                    .frame(maxWidth: Constants.Layout.buttonMaxWidth)
                    .padding(.vertical, 16)
                    .background(Color.accentColor)
                    .cornerRadius(14)
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity)
            .accessibilityIdentifier("guidedSetup.primer.choose")

            // SECONDARY — quiet bordered action for the user who already knows what
            // they want and just wants the full control panel.
            Button(action: onManual) {
                Text("Set up manually") // xcstrings: gateway-primer
                    .onboardingScaledFont(.headline)
                    .foregroundColor(AppColors.textPrimary)
                    .frame(maxWidth: Constants.Layout.buttonMaxWidth)
                    .padding(.vertical, 16)
                    .background(
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(AppColors.border, lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity)
            .accessibilityIdentifier("guidedSetup.primer.manual")

            // TERTIARY — passive docs link. A `Link` opens Safari and does NOT
            // dismiss the sheet (mirrors WelcomeStepView.LegalFooterLinks), so the
            // user returns to the primer where they left it.
            Link(destination: URL(string: Constants.setupGuideURL)!) {
                Text("Read the setup guide ↗") // xcstrings: gateway-primer
                    .onboardingScaledFont(.footnote)
            }
            .tint(AppColors.textSecondary)
            .foregroundStyle(AppColors.textSecondary)
            .padding(.top, 2)
            .accessibilityIdentifier("guidedSetup.primer.docs")
        }
        .padding(.horizontal, Constants.Layout.horizontalPadding)
    }
}

#Preview {
    ZStack {
        SetupAtmosphereBackground()
        GatewayPrimerStepView(onChoose: {}, onManual: {})
    }
}
