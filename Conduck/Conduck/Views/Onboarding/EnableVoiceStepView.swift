// SPDX-License-Identifier: Apache-2.0

// Conduck
// EnableVoiceStepView.swift
//
// Permission-UX rework (D1 + D2 baseline) — a voice-first priming onboarding
// step that requests the MICROPHONE up front (it's universal: every voice path,
// every provider, every surface needs it) and, when the active STT provider is
// Apple on-device, Speech Recognition back-to-back behind the same screen.
// During onboarding the provider is always Apple on-device (no STT step; Apple
// keyboard dictation is the default), so both prompts fire here — establishing
// the phone-side grants for ALL surfaces, including the ones that can never
// prompt later (Watch relay transcribes phone-side, CarPlay, headless).
//
// NON-BLOCKING: the gateway is the only REQUIRED config (spec invariant). A
// denial shows a soft "you can enable this later in Settings" note and STILL
// advances; a "Not now" affordance advances without prompting. Mirrors the
// scaffold/closure structure of the other onboarding steps.
//
// Placed after the gateway branch (and after the macOS menu-bar step), just
// before completion — see `OnboardingContainerView` / `OnboardingFlow`.

import SwiftUI

/// Onboarding step that primes + requests microphone (and, for Apple on-device
/// STT, Speech Recognition) access. `onContinue` advances the flow regardless
/// of the grant outcome.
struct EnableVoiceStepView: View {
    /// Advance to the next step. Called after the permission flow resolves
    /// (granted, denied, or skipped) — onboarding never hard-blocks on voice.
    let onContinue: () -> Void

    /// True once the user has tapped "Enable Voice" and been denied — flips
    /// in the soft "you can enable this later in Settings" note. Purely
    /// informational; the step still advances.
    @State private var micDenied = false

    /// Guards the CTA against a double-tap while the async permission flow runs.
    @State private var isRequesting = false

    init(onContinue: @escaping () -> Void) {
        self.onContinue = onContinue
    }

    var body: some View {
        VStack(spacing: 24) {
            Image("conduck-headphones")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .onboardingMascot(hero: true)

            VStack(spacing: 12) {
                Text("Talk to your AI") // xcstrings: enable-voice
                    .onboardingScaledFont(.title, weight: .bold)
                    .foregroundStyle(AppColors.textEmphasis)
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
                    .padding(.horizontal, 32)

                Text("Conduck needs your Microphone and Speech Recognition to turn speech into text.") // xcstrings: enable-voice
                    .onboardingScaledFont(.body)
                    .foregroundStyle(AppColors.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }

            if micDenied {
                // Soft, non-blocking — we still advance from "Enable Voice".
                Text("You can enable this later in Settings → Privacy.") // xcstrings: enable-voice
                    .onboardingScaledFont(.caption)
                    .foregroundStyle(AppColors.textTertiary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
        }
        .onboardingStepLayout {
            VStack(spacing: 12) {
                // Primary CTA — request mic, then (Apple-active) Speech
                // Recognition, then advance regardless of outcome.
                Button(action: requestAndAdvance) {
                    Text("Enable Voice") // xcstrings: enable-voice
                        .onboardingScaledFont(.headline)
                        .foregroundColor(AppColors.textEmphasis)
                        .frame(maxWidth: Constants.Layout.buttonMaxWidth)
                        .padding(.vertical, 16)
                        .background(Color.accentColor)
                        .cornerRadius(14)
                }
                .primaryCTAButton()
                .frame(maxWidth: .infinity)
                .disabled(isRequesting)

                // Secondary, de-emphasized — skip without prompting.
                Button(action: onContinue) {
                    Text("Not now") // xcstrings: enable-voice
                        .onboardingScaledFont(.subheadline, weight: .medium)
                        .foregroundColor(AppColors.textSecondary)
                        .frame(maxWidth: Constants.Layout.buttonMaxWidth)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                // Centred call-to-action: live area + hover wash (the label's own
                // frame/contentShape stay — off macOS this style IS `.plain`, so
                // they still carry the touch target).
                .settingsRowButton(alignment: .center)
                // Cap the LIVE width to the drawn button. The style stretches to
                // `.infinity`, so without this the entire footer band activates
                // "skip voice setup" — including a click 200pt clear of the words,
                // where no hover wash appears to warn that it would. `.infinity`
                // on iOS/watchOS, so touch layout is unchanged.
                .frame(maxWidth: Constants.Layout.buttonMaxWidth)
                .frame(maxWidth: .infinity)
                .disabled(isRequesting)
            }
            .padding(.horizontal, Constants.Layout.horizontalPadding)
        }
    }

    /// Request microphone, then Speech Recognition when the active provider is
    /// Apple on-device (B baseline), then advance — never hard-blocking. A
    /// denied mic flips the soft note before advancing.
    private func requestAndAdvance() {
        guard !isRequesting else { return }
        isRequesting = true
        Task {
            let micGranted = await VoicePermissions.requestMicrophone()
            #if !os(watchOS)
            // Only Apple on-device active triggers the Speech-Recognition prompt
            // (cloud providers no-op); during onboarding Apple is always active.
            if await SettingsManager.shared.getActiveSTTProvider().transport == .inProcess {
                _ = await VoicePermissions.ensureSpeechRecognitionForActiveProvider()
                // Warm the Standard model now (fire-and-forget) so the first mic
                // tap / CarPlay / Shortcut isn't a cold first-run race. The helper
                // self-gates on authorization granted just above + Apple active.
                Task { await AppleSpeechPreparer.prepareStandardIfAuthorized() }
            }
            #endif
            micDenied = !micGranted
            isRequesting = false
            // Advance regardless of grant outcome — voice is soft, gateway is
            // the only required config.
            onContinue()
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

        EnableVoiceStepView(onContinue: {})
    }
}
