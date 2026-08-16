// SPDX-License-Identifier: Apache-2.0

// Conduck
// OnboardingChoiceCard.swift
//
// Shared tappable "choice card" for onboarding chooser steps (the STT chooser
// and the gateway chooser). Extracted from `STTChooserStepView`'s private
// `ChoiceCard` so both choosers render an identical card shape.
//
// `emphasis` promotes the card to a PRIMARY pick: a larger title and an
// accent-tinted border on the glass card — the same action color the card's
// icon and every primary CTA already speak (never amber, which the guided flow
// reserves for its one true caution). The gateway fork uses it for the
// walk-me-through primary card; the STT chooser leaves every card at the
// default (no emphasis), so its visual language is unchanged.
//
// `badge` is an OPTIONAL short capsule tag rendered trailing the title (e.g.
// "Recommended" / "Fastest"). Defaults to nil, so existing callers are
// unchanged. The gateway chooser uses it to flag the recommended + fastest
// picks without spending a whole subtitle line on it.

import SwiftUI

/// One tappable onboarding choice — an icon, a title + subtitle, and a trailing
/// chevron, on a glass card. Set `emphasis` for the prominent primary pick.
struct OnboardingChoiceCard: View {
    let icon: String
    // `LocalizedStringResource`, not `LocalizedStringKey`: a bare literal still
    // works at every call site, and a caller that needs a DOTTED catalog key
    // can pass one with its `defaultValue:` — which `LocalizedStringKey` cannot
    // express, so a self-keyed English sentence was the only option available.
    let title: LocalizedStringResource
    let subtitle: LocalizedStringResource
    var emphasis: Bool = false
    /// Optional short capsule tag shown trailing the title (nil hides it).
    var badge: LocalizedStringResource? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundStyle(.tint)
                    .frame(width: 32)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(title)
                            // The primary pick reads a notch larger so the
                            // self-host-first posture is visible at a glance.
                            .onboardingScaledFont(emphasis ? .title3 : .headline,
                                                  weight: emphasis ? .semibold : nil)
                            .foregroundStyle(AppColors.textPrimary)
                            // Wrap (never ellipsis-truncate) so a long title
                            // stays fully legible at large Dynamic Type sizes.
                            .fixedSize(horizontal: false, vertical: true)

                        // Subtle accent capsule tag (e.g. "Recommended"), only
                        // when the caller supplies one.
                        if let badge {
                            Text(badge)
                                .onboardingScaledFont(.caption2, weight: .semibold)
                                .foregroundStyle(Color.accentColor)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Capsule().fill(Color.accentColor.opacity(0.18)))
                        }
                    }

                    Text(subtitle)
                        .onboardingScaledFont(.caption)
                        .foregroundStyle(AppColors.textSecondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .onboardingScaledFont(.subheadline, weight: .semibold)
                    .foregroundStyle(AppColors.textTertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .onboardingCardPadding()
            // Emphasis draws the eye with an accent-tinted glass border (the
            // same action color the primary CTAs use), leaving the secondary
            // card plain.
            .glassCardBackground(borderColor: emphasis ? Color.accentColor.opacity(0.6) : nil,
                                 borderWidth: emphasis ? 1.5 : 1)
        }
        // 16 matches `glassCardBackground`'s own corner radius, so the pointer
        // hover/pressed wash lines up with the card's edge.
        .choiceCardButton(cornerRadius: 16)
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

        VStack(spacing: 14) {
            OnboardingChoiceCard(
                icon: "server.rack",
                title: "Connect my own server",
                subtitle: "OpenClaw, Hermes, or any OpenAI-compatible server.",
                emphasis: true,
                action: {}
            )
            OnboardingChoiceCard(
                icon: "cloud",
                title: "Use a hosted model",
                subtitle: "No server needed — just an OpenRouter API key.",
                action: {}
            )
        }
        .padding(.horizontal, 32)
    }
}
