// SPDX-License-Identifier: Apache-2.0

//
//  MenuBarGuideView.swift
//  Conduck
//
//  macOS Settings → General → Menu Bar "How to Use" guide. The keyboard-shortcut
//  explainer that used to be an onboarding step (`MenuBarStepView`), relocated to
//  Settings so it's reference material the user reaches on demand — not a first-run
//  gate. Presented as a fixed-size sheet from `MacGeneralCategory`; the footer's
//  "Done" button dismisses the sheet.
//

#if os(macOS)
import SwiftUI

struct MenuBarGuideView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            // Same gradient backdrop the onboarding container + Guided Setup sheet
            // use — without it the sheet falls back to the default macOS material.
            LinearGradient(
                colors: [AppColors.gradientStart, AppColors.gradientEnd],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 16) {
                // Character — keeps the menu-bar step's bespoke 110pt mascot.
                Image("conduck-laptop")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(height: 110)
                    .shadow(color: AppColors.brandAmber.opacity(0.3), radius: 20, y: 10)

                // Title
                Text("Menu Bar App") // xcstrings: onboarding-redesign
                    .onboardingScaledFont(.title, weight: .bold)
                    .foregroundStyle(AppColors.textEmphasis)
                    .accessibilityAddTraits(.isHeader)

                // Keyboard shortcuts card
                shortcutsCard
            }
            .onboardingStepLayout {
                // Done — dismisses the sheet (the guide gates nothing).
                Button(action: { dismiss() }) {
                    Text("Done") // xcstrings
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
            }
        }
    }

    // MARK: - Keyboard Shortcuts Card

    private var shortcutsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "command")
                    .foregroundStyle(.tint)
                Text("Keyboard Shortcut") // xcstrings: menubar-upgrade
                    .onboardingScaledFont(.headline)
                    .foregroundStyle(AppColors.textPrimary)
            }

            NumberedStepRow(number: 1, text: "⌘⇧1 — Ask by voice or text: press again to send") // xcstrings: menubar-upgrade
            NumberedStepRow(number: 2, text: "⌘⇧2 — Screenshot & Ask: drag a region, then ask; both send together") // xcstrings: menubar-upgrade
            NumberedStepRow(number: 3, text: "Press Esc to cancel") // xcstrings: menubar-upgrade

            HStack(spacing: 8) {
                Image(systemName: "lightbulb.fill")
                    .foregroundStyle(AppColors.warning)
                    .onboardingScaledFont(.caption)
                Text("Tip: You can customize these shortcuts in Settings.") // xcstrings: menubar-upgrade
                    .onboardingScaledFont(.caption)
                    .foregroundStyle(AppColors.textTertiary)
            }
            .padding(.top, 8)
        }
        .onboardingCardPadding()
        .glassCardBackground()
        .padding(.horizontal, 32)
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

        MenuBarGuideView()
    }
}
#endif
