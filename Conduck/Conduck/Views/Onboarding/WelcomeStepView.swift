// SPDX-License-Identifier: Apache-2.0

//  WelcomeStepView.swift
//  Conduck
//
//  Welcome screen with feature highlights
//

import SwiftUI

struct WelcomeStepView: View {
    let onContinue: () -> Void

    var body: some View {
        VStack(spacing: 32) {
            // Character and title
            VStack(spacing: 16) {
                Image("conduck-sipping-coffee")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .onboardingMascot(hero: true)

                BrandedText.conduck()
                    .onboardingScaledFont(.largeTitle, weight: .bold)
                    .accessibilityAddTraits(.isHeader)
            }

            // Feature highlights
            VStack(alignment: .leading, spacing: 20) {
                FeatureRow(
                    icon: "lock.shield",
                    title: "Your gateway, your rules", // xcstrings: onboarding-redesign
                    description: "Connect to any OpenAI-compatible gateway." // xcstrings: onboarding-redesign
                )

                FeatureRow(
                    icon: "apps.iphone",
                    title: "Every Apple device", // xcstrings: onboarding-redesign
                    description: "iPhone, iPad, Mac, Watch and CarPlay." // xcstrings: onboarding-redesign
                )

                FeatureRow(
                    icon: "arrow.left.arrow.right",
                    title: "No middleman", // xcstrings: onboarding-redesign
                    description: "Conduck connects straight to your AI — we never see your data." // xcstrings: onboarding-redesign
                )
            }
            .padding(.horizontal, Constants.Layout.horizontalPadding)
        }
        .onboardingStepLayout {
            // Pinned footer — a sibling below the ScrollView, so it's ALWAYS
            // fully on-screen (never scrolls) at any Dynamic Type size, on every
            // device that shows this screen (iPhone / iPad / Mac). Holds the
            // primary CTA plus the quiet legal-link line.
            VStack(spacing: 14) {
                // Primary CTA — always enabled (no consent gate). Per-egress
                // disclosures live where data actually leaves the device: cloud-STT
                // provider setup and gateway setup (OpenRouter / self-hosted /
                // custom). On-device transcription is local and needs no consent;
                // the mic + speech-recognition purpose strings cover the system level.
                Button(action: onContinue) {
                    Text("Let's go") // xcstrings
                        .onboardingScaledFont(.headline)
                        .foregroundColor(AppColors.textEmphasis)
                        .frame(maxWidth: Constants.Layout.buttonMaxWidth)
                        .padding(.vertical, 16)
                        .background(Color.accentColor)
                        .cornerRadius(14)
                }
                .primaryCTAButton()
                .frame(maxWidth: .infinity)
                .padding(.horizontal, Constants.Layout.horizontalPadding)

                // Passive legal access — NOT a consent gate (the CTA above is
                // always enabled). Just makes the published Privacy Policy +
                // Terms reachable on first run, reinforcing the no-middleman
                // posture. Reuses the same URLs + string keys as Settings ▸ About.
                LegalFooterLinks()
            }
        }
    }
}

// MARK: - Legal Footer

/// Quiet "Privacy Policy · Terms of Service" line shown under the Welcome CTA.
/// Both open the publicly hosted documents (same `Constants` URLs as the
/// Settings ▸ About rows). Sized small and tinted secondary so it reads as a
/// passive footer, not a second action competing with the primary CTA.
private struct LegalFooterLinks: View {
    var body: some View {
        HStack(spacing: 6) {
            Link("Privacy Policy", destination: URL(string: Constants.privacyPolicyURL)!) // xcstrings

            Text(verbatim: "·")
                .accessibilityHidden(true)

            Link("Terms of Service", destination: URL(string: Constants.termsOfServiceURL)!) // xcstrings
        }
        .onboardingScaledFont(.footnote)
        .tint(AppColors.textSecondary)
        .foregroundStyle(AppColors.textSecondary)
        .padding(.horizontal, Constants.Layout.horizontalPadding)
    }
}

// MARK: - Feature Row

private struct FeatureRow: View {
    let icon: String
    let title: LocalizedStringKey
    let description: LocalizedStringKey

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: icon)
                // Leading row-icon in a fixed 32pt frame — leave at base size
                // (don't scale the glyph past its box); adjacent text still bumps.
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .onboardingScaledFont(.subheadline, weight: .semibold)
                    .foregroundStyle(AppColors.textPrimary)

                Text(description)
                    .onboardingScaledFont(.caption)
                    .foregroundStyle(AppColors.textSecondary)
            }
        }
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

        WelcomeStepView(onContinue: {})
    }
}
