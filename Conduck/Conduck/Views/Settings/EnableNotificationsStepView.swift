// SPDX-License-Identifier: Apache-2.0

// Conduck
// EnableNotificationsStepView.swift
//
// Permission-UX — an explanatory NOTIFICATION priming step (the iOS-HIG "soft
// ask"). The FINAL step of the Setup Guide (`SetupGuideView`), right after the
// user binds a headless trigger (Control Center / Action Button / Back Tap /
// Keyboard Shortcut). Conduck's reply arrives seconds after an async round-trip
// to the user's gateway, and on those headless surfaces there is no live UI when
// it lands — a local notification is the ONLY feedback channel there (spec
// "Notification Presentation"). So we explain WHY, then let the user opt in via
// the CTA: the system dialog fires only when the user taps "Turn on
// Notifications".
//
// NON-BLOCKING: `onContinue` closes the guide regardless of grant. "Not now"
// records a deferral flag (`markNotificationsDeferred`) so the first in-app
// composer send doesn't immediately re-pop the OS dialog — the genuinely-headless
// backstops still ask. The lazy `NotificationPermissions.ensureRequested()` call
// sites remain as backstops (idempotent → no double prompt). Onboarding does NOT
// ask for notifications; this lives in the Setup Guide only. Mirrors the
// scaffold/closure structure of `EnableVoiceStepView`.

import SwiftUI

/// Setup-Guide step that primes + requests notification authorization. Mirrors
/// `EnableVoiceStepView`. `onContinue` finishes the guide regardless of the grant
/// outcome (we never hard-block on notifications).
struct EnableNotificationsStepView: View {
    /// Finish the Setup Guide. Called after the permission flow resolves
    /// (granted, denied, or skipped).
    let onContinue: () -> Void

    /// Guards the CTA against a double-tap while the async request runs.
    @State private var isRequesting = false

    init(onContinue: @escaping () -> Void) {
        self.onContinue = onContinue
    }

    var body: some View {
        VStack(spacing: 24) {
            Image("conduck-cowboy")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .onboardingMascot(hero: true)

            VStack(spacing: 12) {
                Text("Hear back from your AI") // xcstrings: enable-notifications
                    .onboardingScaledFont(.title, weight: .bold)
                    .foregroundStyle(AppColors.textEmphasis)
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
                    .padding(.horizontal, 32)

                Text("A notification is how Conduck reaches you the moment your reply is ready.") // xcstrings: enable-notifications
                    .onboardingScaledFont(.body)
                    .foregroundStyle(AppColors.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }

            // Operating notes for the headless trigger just bound — the quick
            // capture (Action Button / Back Tap / Control Center) records inside
            // the Shortcuts process, which iOS suspends on screen lock/dim and
            // throttles under Low Power Mode. Surfaced here per spec "Trigger
            // Architecture" accepted entry-1 ceilings (never a user surprise).
            goodToKnow
        }
        .onboardingStepLayout {
            VStack(spacing: 12) {
                // Primary CTA — fire the idempotent system prompt, then advance
                // regardless of outcome.
                Button(action: requestAndAdvance) {
                    Text("Turn on Notifications") // xcstrings: enable-notifications
                        .onboardingScaledFont(.headline)
                        .foregroundColor(AppColors.textEmphasis)
                        .frame(maxWidth: Constants.Layout.buttonMaxWidth)
                        .padding(.vertical, 16)
                        .background(Color.accentColor)
                        .cornerRadius(14)
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)
                .disabled(isRequesting)

                // Secondary, de-emphasized — skip without prompting. Records a
                // deferral so the next in-app send won't immediately re-ask.
                Button(action: skipAndAdvance) {
                    Text("Not now") // xcstrings: enable-notifications
                        .onboardingScaledFont(.subheadline, weight: .medium)
                        .foregroundColor(AppColors.textSecondary)
                        .frame(maxWidth: Constants.Layout.buttonMaxWidth)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)
                .disabled(isRequesting)
            }
            .padding(.horizontal, Constants.Layout.horizontalPadding)
        }
    }

    // MARK: - Good to know

    /// A subordinate info panel disclosing the headless quick-capture ceilings.
    /// Mirrors `ActionButtonStepView`'s instructions-card treatment (glass card)
    /// so it reads as the same visual language, kept de-emphasized under the
    /// notification ask. Shown for every trigger method (this is the shared final
    /// step), so iPad + iPhone Action Button + Back Tap all see it.
    private var goodToKnow: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Good to know") // xcstrings: enable-notifications
                .onboardingScaledFont(.caption, weight: .semibold)
                .foregroundStyle(AppColors.textTertiary)

            limitRow(icon: "lock.fill",
                     text: "Screen locks or dims — recording stops") // xcstrings: enable-notifications
            limitRow(icon: "battery.25percent",
                     text: "Low Power Mode — max 30s recording") // xcstrings: enable-notifications
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onboardingCardPadding()
        .glassCardBackground()
        .padding(.horizontal, 32)
    }

    /// One icon + caption row for the Good-to-know panel. Generalizes the
    /// `tipCallout` idiom (`ActionButtonStepView`) to take an SF Symbol.
    private func limitRow(icon: String, text: LocalizedStringKey) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(AppColors.warning)
                .onboardingScaledFont(.caption)
            Text(text)
                .onboardingScaledFont(.caption)
                .foregroundStyle(AppColors.textSecondary)
        }
    }

    /// Fire the idempotent notification-auth request, then finish — never
    /// hard-blocking (notifications are a soft grant; the gateway is the only
    /// required config).
    private func requestAndAdvance() {
        guard !isRequesting else { return }
        isRequesting = true
        Task {
            await NotificationPermissions.ensureRequested()
            isRequesting = false
            onContinue()
        }
    }

    /// Skip without prompting — record the deferral so the low-urgency in-app
    /// composer backstop doesn't immediately re-pop the OS dialog (the headless
    /// backstops still ask, since a notification is their only feedback channel),
    /// then finish.
    private func skipAndAdvance() {
        NotificationPermissions.markNotificationsDeferred()
        onContinue()
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

        EnableNotificationsStepView(onContinue: {})
    }
}
