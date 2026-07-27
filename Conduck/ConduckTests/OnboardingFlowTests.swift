// SPDX-License-Identifier: Apache-2.0

// Conduck
// OnboardingFlowTests.swift
//
// Pure step-ordering coverage for the onboarding machine (`OnboardingFlow`). The
// ordering was extracted out of `OnboardingContainerView` precisely so it's
// testable without a View or a live platform.
//
// Gateway setup is DEFERRED out of onboarding — it lives in Settings → Personal
// AI as a re-runnable "Guided Setup", reached at point-of-need from the app's
// unconfigured empty state. So onboarding is a fixed three-step linear flow on
// every platform: welcome → enableVoice → completion. There is no gateway step
// and no STT step (on-device voice defaults to keyboard dictation, no setup);
// notification priming lives in the Setup Guide (`SetupGuideView`), not here.
//
// These structural assertions are the regression net: the `allCases` check
// guards against a gateway/STT/notification step ever leaking back into the enum,
// and the `orderedSteps` check pins the navigation order welcome-first /
// completion-last.

import XCTest
@testable import Conduck

final class OnboardingFlowTests: XCTestCase {

    /// The onboarding enum holds exactly the three linear steps — no gateway,
    /// STT, or notification cases. Catches a leftover/re-introduced case that a
    /// pure ordered-steps assertion would miss.
    func testOnboardingStepIsExactlyTheThreeLinearSteps() {
        XCTAssertEqual(OnboardingStep.allCases, [.welcome, .enableVoice, .completion])
    }

    /// The full navigation order is the fixed three-step flow, welcome-first and
    /// completion-last (what back-navigation walks).
    func testOrderedStepsIsWelcomeVoiceCompletion() {
        XCTAssertEqual(OnboardingFlow.orderedSteps, [.welcome, .enableVoice, .completion])
        XCTAssertEqual(OnboardingFlow.orderedSteps.first, .welcome)
        XCTAssertEqual(OnboardingFlow.orderedSteps.last, .completion)
    }
}
