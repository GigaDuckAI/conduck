// Conduck
// OnboardingContainerView.swift
//
// Linear onboarding routing. Gateway setup is DEFERRED out of onboarding (it's
// the heaviest, most confusing step and demands a decision before the user has
// seen the app). The identical gateway-setup flow lives in Settings → Personal
// AI as a re-runnable "Guided Setup" (`GuidedGatewaySetupView`), reached at the
// moment of intent from the unconfigured empty state. So onboarding is a short,
// linear three-step flow on every platform:
//
//   welcome → enableVoice → completion
//
// NO STT step. On-device voice defaults to the Apple keyboard-dictation engine
// (`AppleOnDeviceEngineMode.dictation`) — no model download, works on first mic
// tap — so there is nothing to set up here. Switching to a cloud provider or
// the high-quality on-device model is an opt-in in Settings → Voice.
//
// `.enableVoice` is the voice-priming step (microphone + Apple-on-device Speech
// Recognition requested up front). It stays in onboarding because the Watch /
// CarPlay / headless-Shortcut paths can't reliably prompt for mic at point-of-
// use. Non-blocking.

import SwiftUI

/// Onboarding flow steps. Navigation is driven by `OnboardingFlow.orderedSteps`,
/// not raw enum order. There is no gateway step (deferred to Settings → Personal
/// AI) and no STT step (on-device voice defaults to keyboard dictation, no setup).
enum OnboardingStep: Int, CaseIterable {
    case welcome
    case enableVoice
    case completion
}

/// Which gateway lane the user picked on the chooser. No longer used by
/// onboarding (gateway setup is deferred), but retained as the shared
/// setup-routing type for the Settings → Personal AI "Guided Setup" flow
/// (`GuidedGatewaySetupView`, `PersonalAISettingsView`, `MacPersonalAICategory`).
enum GatewayPath {
    case selfHosted
    case hostedModel
    case later
    /// Deep link from a SAVED gateway's editor: open the guided flow directly at
    /// the Commands step with the target's lane, and lock the pairing import to
    /// that ref (a `.custom` target imports into the SAME custom gateway).
    case quickConnect(target: RemoteAgentRef)
}

/// Pure step-ordering for the onboarding machine. Extracted from
/// `OnboardingContainerView` so the flow is testable WITHOUT a View. The flow is
/// a fixed three-step linear sequence on every platform.
enum OnboardingFlow {
    /// The full ordered onboarding flow — used by back navigation.
    static let orderedSteps: [OnboardingStep] = [.welcome, .enableVoice, .completion]
}

/// Main onboarding container — linear step navigation with slide transitions.
struct OnboardingContainerView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var currentStep: OnboardingStep = .welcome

    /// Optional callback fired when onboarding completes. When provided,
    /// invoked in place of `dismiss()` — supports the conditional-rendering
    /// gate in `RootView` where there's no modal to dismiss. `#Preview` and
    /// any future modal presentation can pass `nil` to keep `dismiss()`.
    private let onComplete: (() -> Void)?

    init(onComplete: (() -> Void)? = nil) {
        self.onComplete = onComplete
    }

    /// Tracks navigation direction for slide transition
    private enum NavigationDirection {
        case forward, backward
    }
    @State private var navigationDirection: NavigationDirection = .forward

    var body: some View {
        ZStack {
            SetupAtmosphereBackground()

            VStack(spacing: 0) {
                stepContent
                    .id(currentStep)
                    .transition(.asymmetric(
                        insertion: .move(edge: navigationDirection == .forward ? .trailing : .leading)
                            .combined(with: .opacity),
                        removal: .move(edge: navigationDirection == .forward ? .leading : .trailing)
                            .combined(with: .opacity)
                    ))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .overlay(alignment: .topLeading) {
                if currentStep != .welcome {
                    Button(action: previousStep) {
                        Image(systemName: "arrow.left")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(AppColors.textEmphasis)
                            .frame(width: 44, height: 44)
                            .background(
                                Circle()
                                    .fill(AppColors.backgroundSecondary)
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("Go Back")) // xcstrings
                    #if os(macOS)
                    .padding(.top, 16)
                    .padding(.leading, 24)
                    #else
                    .padding(.top, 8)
                    .padding(.leading, 16)
                    #endif
                }
            }
        }
    }

    // MARK: - Step Content

    @ViewBuilder
    private var stepContent: some View {
        switch currentStep {
        case .welcome:
            WelcomeStepView(onContinue: { goTo(.enableVoice) })

        case .enableVoice:
            // Voice-priming step — requests microphone (and, for Apple
            // on-device STT, Speech Recognition) up front, then advances to
            // completion (non-blocking).
            EnableVoiceStepView(onContinue: { goTo(.completion) })

        case .completion:
            CompletionStepView(onFinish: { completeOnboarding() })
        }
    }

    // MARK: - Navigation

    /// Forward navigation to an explicit step with the standard slide.
    private func goTo(_ step: OnboardingStep) {
        navigationDirection = .forward
        withAnimation(.easeInOut(duration: 0.3)) {
            currentStep = step
        }
    }

    /// Back navigation walks `OnboardingFlow.orderedSteps`.
    private func previousStep() {
        navigationDirection = .backward
        withAnimation(.easeInOut(duration: 0.3)) {
            guard let idx = OnboardingFlow.orderedSteps.firstIndex(of: currentStep),
                  idx > 0 else { return }
            currentStep = OnboardingFlow.orderedSteps[idx - 1]
        }
    }

    private func completeOnboarding() {
        Task {
            await SettingsManager.shared.markOnboardingComplete()
            // Notification authorization is NOT requested in onboarding at all.
            // It's primed in the Setup Guide's headless-trigger flow (the
            // `EnableNotificationsStepView` step there), where a notification is
            // the reply channel. The lazy `NotificationPermissions.ensureRequested()`
            // backstops remain the safety net for an in-app-first user — fired at
            // the foreground moments that actually lead to a notification (first
            // committed foreground converse dispatch, share-drain recovery).
        }
        if let onComplete {
            onComplete()
        } else {
            dismiss()
        }
    }
}

#Preview {
    OnboardingContainerView()
}
