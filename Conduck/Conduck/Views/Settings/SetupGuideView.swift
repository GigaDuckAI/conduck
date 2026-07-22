//  Conduck
//  SetupGuideView.swift
//
//  Re-runnable 3-step Setup Guide reached from Settings (iOS / iPadOS only).
//  Relocates the shortcut-install + trigger-binding flow OUT of first-run
//  onboarding so the user can run it any time (and re-run it per device,
//  since the shortcut syncs via iCloud but the trigger binding is local).
//
//    Step 1 — ShortcutStepView            (install the bundled Conduck shortcut)
//    Step 2 — ActionButtonStepView        (bind it to a hardware trigger)
//    Step 3 — EnableNotificationsStepView (prime + ask for notification auth —
//             a notification is the reply channel for the headless trigger just
//             bound; the explanatory soft-ask lives HERE, not in onboarding)
//
//  Presented as a `.fullScreenCover` from SettingsView. Mirrors
//  OnboardingContainerView's gradient + slide-transition + back-affordance
//  chrome for visual consistency.
//

import SwiftUI

/// Two-step paged Setup Guide. Step 1 installs the shortcut, Step 2 binds it
/// to a trigger. A back affordance moves between the steps; the top-trailing
/// Close button dismisses the sheet at any point.
struct SetupGuideView: View {
    @Environment(\.dismiss) private var dismiss

    /// 1-based step index (1 = shortcut, 2 = trigger binding, 3 = notifications).
    @State private var step: Int = 1

    /// Tracks navigation direction for the slide transition.
    private enum NavigationDirection { case forward, backward }
    @State private var navigationDirection: NavigationDirection = .forward

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [AppColors.gradientStart, AppColors.gradientEnd],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                progressIndicator
                    .padding(.top, 16)
                    .padding(.horizontal)

                stepContent
                    .id(step)
                    .transition(.asymmetric(
                        insertion: .move(edge: navigationDirection == .forward ? .trailing : .leading)
                            .combined(with: .opacity),
                        removal: .move(edge: navigationDirection == .forward ? .leading : .trailing)
                            .combined(with: .opacity)
                    ))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            // Back affordance — only on step 2 (step 1 has Close instead).
            .overlay(alignment: .topLeading) {
                if step > 1 {
                    Button(action: previousStep) {
                        Image(systemName: "arrow.left")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(AppColors.textEmphasis)
                            .frame(width: 44, height: 44)
                            .background(Circle().fill(AppColors.backgroundSecondary))
                    }
                    .accessibilityLabel(Text("Go Back")) // xcstrings: setup-guide
                    .padding(.top, 8)
                    .padding(.leading, 16)
                }
            }
            // Close affordance — always available to bail out of the guide.
            .overlay(alignment: .topTrailing) {
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(AppColors.textEmphasis)
                        .frame(width: 44, height: 44)
                        .background(Circle().fill(AppColors.backgroundSecondary))
                }
                .accessibilityLabel(Text("Close")) // xcstrings: setup-guide
                .padding(.top, 8)
                .padding(.trailing, 16)
            }
        }
    }

    // MARK: - Progress Indicator

    private var progressIndicator: some View {
        HStack(spacing: 8) {
            ForEach(1...3, id: \.self) { index in
                Capsule()
                    .fill(index <= step ? Color.accentColor : AppColors.disabled)
                    .frame(height: 4)
            }
        }
        .frame(maxWidth: 200)
        .animation(.easeInOut, value: step)
    }

    // MARK: - Step Content

    @ViewBuilder
    private var stepContent: some View {
        switch step {
        case 1:
            ShortcutStepView(onContinue: { advanceStep() })
        case 2:
            // Binding the headless trigger hands off to the notifications step —
            // a notification is the only channel a reply can reach the user on
            // that trigger, so the explanatory ask follows immediately.
            ActionButtonStepView(onDone: { advanceStep() })
        default:
            // Notification priming + the system auth prompt (its CTA), or "Not
            // now". Either path closes the guide.
            EnableNotificationsStepView(onContinue: { dismiss() })
        }
    }

    // MARK: - Navigation

    private func advanceStep() {
        navigationDirection = .forward
        withAnimation(.easeInOut(duration: 0.3)) {
            step = min(step + 1, 3)
        }
    }

    private func previousStep() {
        navigationDirection = .backward
        withAnimation(.easeInOut(duration: 0.3)) {
            step = max(step - 1, 1)
        }
    }
}

#Preview {
    SetupGuideView()
}
