//  CompletionStepView.swift
//  Conduck
//
//  Onboarding completion screen
//

import SwiftUI
#if os(macOS)
import ServiceManagement
#endif

struct CompletionStepView: View {
    let onFinish: () -> Void

    @State private var showCharacter = false
    #if os(macOS)
    // Pending desired preference (NOT a live mirror of SMAppService). Default ON
    // for this menu-bar/Dock-resident utility; the actual login-item registration
    // is committed only when the user taps "Let's go" (consent point), never on
    // appear — proactive on-appear registration is the App Review 2.4.5(iii) hook.
    @State private var launchAtLogin = true
    #endif

    var body: some View {
        VStack(spacing: 32) {
            // Character animation
            Image("conduck-disco")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .onboardingMascot(hero: true)
                .scaleEffect(showCharacter ? 1 : 0.3)
                .opacity(showCharacter ? 1 : 0)
                .animation(.spring(response: 0.5, dampingFraction: 0.6), value: showCharacter)

            // Title
            Text("You're almost ready.") // xcstrings: onboarding-cleanup
                .onboardingScaledFont(.title, weight: .bold)
                .foregroundStyle(AppColors.textEmphasis)
                .accessibilityAddTraits(.isHeader)

            // Handoff to the deferred gateway step: onboarding no longer sets up
            // the AI gateway (it's reached at point-of-need from the app's
            // unconfigured empty state), so the completion screen foreshadows it
            // rather than claiming global readiness.
            Text("Just connect your personal AI and you can start talking.") // xcstrings: onboarding-cleanup
                .onboardingScaledFont(.callout)
                .foregroundStyle(AppColors.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            // Nudge toward the device's recommended trigger setup. Tailored
            // per surface (Action Button / Back Tap / Control Center) and
            // omitted on Mac, where the keyboard shortcut is already set up
            // during onboarding. Strings live in `DeviceCapabilities`.
            if let tip = DeviceCapabilities.recommendedTriggerMethod.completionTip {
                Text(tip)
                    .onboardingScaledFont(.caption)
                    .foregroundStyle(AppColors.textTertiary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
        }
        .onboardingStepLayout {
            VStack(spacing: 12) {
                // Launch at Login toggle (macOS only)
                #if os(macOS)
                Toggle(isOn: $launchAtLogin) {
                    Label("Launch at Login", systemImage: "power") // xcstrings
                        .onboardingScaledFont(.subheadline)
                        .foregroundStyle(AppColors.textPrimary)
                }
                .toggleStyle(.checkbox)
                .padding(.horizontal, Constants.Layout.horizontalPadding)
                #endif

                // Finish button
                Button(action: finish) {
                    Text("Let's go") // xcstrings
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
            }
        }
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                showCharacter = true
            }
        }
    }

    /// Commit point for the completion screen. On macOS this applies the
    /// pending "Launch at Login" choice before finishing — registration happens
    /// here on the explicit "Let's go" tap, never while the screen is on display.
    private func finish() {
        #if os(macOS)
        commitLaunchAtLogin()
        #endif
        onFinish()
    }

    #if os(macOS)
    /// Apply the desired launch-at-login state, registering only the delta so a
    /// user who unchecks the box (or whose item is already registered) triggers
    /// no spurious system change or login-item notification.
    private func commitLaunchAtLogin() {
        let alreadyEnabled = SMAppService.mainApp.status == .enabled
        do {
            if launchAtLogin {
                if !alreadyEnabled { try SMAppService.mainApp.register() }
            } else {
                if alreadyEnabled { try SMAppService.mainApp.unregister() }
            }
        } catch {
            // Non-fatal: login-item registration is a convenience, not a gate.
        }
    }
    #endif

}

#Preview {
    ZStack {
        LinearGradient(
            colors: [AppColors.gradientStart, AppColors.gradientEnd],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()

        CompletionStepView(onFinish: {})
    }
}
