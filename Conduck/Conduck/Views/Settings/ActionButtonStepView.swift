// SPDX-License-Identifier: Apache-2.0

//  Conduck
//  ActionButtonStepView.swift
//
//  Setup Guide — Step 2. Capability-aware trigger-binding step.
//  Binds the bundled "Conduck" shortcut to a hardware trigger
//  (Action Button / Back Tap / Control Center / Keyboard) so the user can
//  talk to their AI from any app without opening Conduck first.
//
//  Reached ONLY from SetupGuideView (Settings → Set up Action Button).
//

import SwiftUI
import Speech

/// Step 2 of the Settings Setup Guide. Picks the right trigger-binding
/// instructions for the current device via `DeviceCapabilities` and walks
/// the user through wiring the bundled `Conduck` shortcut to it.
struct ActionButtonStepView: View {
    /// The recommended trigger method for this device. Defaults to the
    /// device-derived value; the Setup Guide passes nothing and lets the
    /// view resolve it, but it's injectable for previews.
    let method: DeviceCapabilities.TriggerMethod

    /// Fired when the user confirms they've bound the shortcut. The Setup
    /// Guide uses this to dismiss the sheet.
    let onDone: () -> Void

    init(
        method: DeviceCapabilities.TriggerMethod = DeviceCapabilities.recommendedTriggerMethod,
        onDone: @escaping () -> Void
    ) {
        self.method = method
        self.onDone = onDone
    }

    /// Set true when the readiness preflight found Speech Recognition denied /
    /// restricted for an active Apple on-device provider — surfaces the inline
    /// repair text and BLOCKS the "ready" dismiss (the headless trigger would
    /// fail at runtime with no way to prompt).
    @State private var speechBlocked = false

    /// Guards the "I've Set It Up" CTA against a double-tap while the async
    /// readiness preflight runs.
    @State private var isFinishing = false

    var body: some View {
        VStack(spacing: 24) {
            Image("conduck-gaming")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .onboardingMascot(hero: true)

            // Title
            VStack(spacing: 12) {
                Text("Bind \(method.displayName)") // xcstrings: setup-guide
                    .onboardingScaledFont(.title, weight: .bold)
                    .foregroundStyle(AppColors.textEmphasis)
                    .accessibilityAddTraits(.isHeader)
            }

            // Instructions card
            instructionsCard

            // Speech-Recognition repair text — shown only when the readiness
            // preflight found it denied/restricted for an active Apple on-device
            // provider. The headless trigger can't prompt at runtime, so we
            // can't declare the setup "ready" until the user flips the toggle.
            if speechBlocked {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(AppColors.warning)
                        .onboardingScaledFont(.caption)
                    Text("Turn on Speech Recognition for Conduck in Settings → Privacy to finish setup.") // xcstrings: setup-guide
                        .onboardingScaledFont(.caption)
                        .foregroundStyle(AppColors.textSecondary)
                }
                .padding(.horizontal, 32)
            }
        }
        .onboardingStepLayout {
            // Done button — runs the readiness preflight (Speech Recognition for
            // an active Apple provider; notification authorization) BEFORE
            // declaring the trigger ready via `onDone`.
            Button(action: finish) {
                Text("I've Set It Up") // xcstrings: setup-guide
                    .onboardingScaledFont(.headline)
                    .foregroundColor(AppColors.textEmphasis)
                    .frame(maxWidth: Constants.Layout.buttonMaxWidth)
                    .padding(.vertical, 16)
                    .background(Color.accentColor)
                    .cornerRadius(14)
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity)
            .disabled(isFinishing)
            .padding(.horizontal, Constants.Layout.horizontalPadding)
        }
    }

    // MARK: - Readiness preflight

    /// PURE readiness decision — true iff the setup may be declared "ready" for
    /// the headless trigger. False ONLY when the active provider is Apple
    /// on-device AND Speech Recognition is denied/restricted (the headless path
    /// can't prompt at runtime, so it would fail). `.notDetermined` is treated
    /// as ready because the preflight requests it first; cloud providers are
    /// always ready. Extracted so the gate is unit-testable without live TCC.
    static func shouldDeclareReady(
        providerIsInProcess: Bool,
        status: SpeechReadinessStatus
    ) -> Bool {
        guard providerIsInProcess else { return true }
        switch status {
        case .denied, .restricted:
            return false
        case .authorized, .notDetermined:
            return true
        }
    }

    /// Minimal mirror of `SFSpeechRecognizerAuthorizationStatus` so the pure
    /// readiness gate is testable without importing Speech into the test target's
    /// view-under-test context (Speech is `#if !os(watchOS)`-gated).
    enum SpeechReadinessStatus {
        case notDetermined, denied, restricted, authorized
    }

    /// Run the readiness preflight, then hand off via `onDone`. (i) If Apple
    /// on-device STT is active and Speech Recognition is `.notDetermined`,
    /// request it; a denied/restricted result surfaces the repair text and
    /// BLOCKS the handoff. (ii) `onDone` (in the Setup Guide this advances to the
    /// notifications-priming step, which owns the notification ask). Cloud STT
    /// skips the speech step.
    private func finish() {
        guard !isFinishing else { return }
        isFinishing = true
        speechBlocked = false
        Task {
            #if !os(watchOS)
            let provider = await SettingsManager.shared.getActiveSTTProvider()
            if provider.transport == .inProcess {
                let status = await VoicePermissions.ensureSpeechRecognitionForActiveProvider()
                let readinessStatus: SpeechReadinessStatus
                switch status {
                case .denied: readinessStatus = .denied
                case .restricted: readinessStatus = .restricted
                case .authorized: readinessStatus = .authorized
                default: readinessStatus = .notDetermined
                }
                if !Self.shouldDeclareReady(providerIsInProcess: true, status: readinessStatus) {
                    speechBlocked = true
                    isFinishing = false
                    return
                }
                // Speech Recognition is authorized + Apple active — warm the
                // Standard model so the headless Action Button trigger isn't a
                // cold first-run race (fire-and-forget; never blocks finish).
                Task { await AppleSpeechPreparer.prepareStandardIfAuthorized() }
            }
            #endif
            isFinishing = false
            onDone()
        }
    }

    // MARK: - Instructions Card

    private var instructionsCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            switch method {
            case .actionButton:
                actionButtonInstructions
            case .backTap:
                backTapInstructions
            case .controlCenterShortcut:
                controlCenterInstructions
            case .keyboardShortcut:
                keyboardShortcutInstructions
            }
        }
        .onboardingCardPadding()
        .glassCardBackground()
        .padding(.horizontal, 32)
    }

    private var actionButtonInstructions: some View {
        VStack(alignment: .leading, spacing: 12) {
            NumberedStepRow(number: 1, text: "Open Settings") // xcstrings: setup-guide
            NumberedStepRow(number: 2, text: "Tap Action Button") // xcstrings: setup-guide
            NumberedStepRow(number: 3, text: "Select Shortcut") // xcstrings: setup-guide
            NumberedStepRow(number: 4, text: "Choose \"GigaAction\"") // xcstrings: setup-guide
        }
    }

    private var backTapInstructions: some View {
        VStack(alignment: .leading, spacing: 12) {
            NumberedStepRow(number: 1, text: "Open Settings") // xcstrings: setup-guide
            NumberedStepRow(number: 2, text: "Go to Accessibility") // xcstrings: setup-guide
            NumberedStepRow(number: 3, text: "Tap Touch") // xcstrings: setup-guide
            NumberedStepRow(number: 4, text: "Tap Back Tap") // xcstrings: setup-guide
            NumberedStepRow(number: 5, text: "Choose Double Tap") // xcstrings: setup-guide
            NumberedStepRow(number: 6, text: "Scroll to Shortcuts and select \"GigaAction\"") // xcstrings: setup-guide

            tipCallout(text: "Tip: Use Triple Tap if you get accidental triggers") // xcstrings: setup-guide
        }
    }

    private var controlCenterInstructions: some View {
        VStack(alignment: .leading, spacing: 12) {
            NumberedStepRow(number: 1, text: "Swipe down from the top-right corner of your screen") // xcstrings: setup-guide
            NumberedStepRow(number: 2, text: "Tap +, then \"Add a Control\"") // xcstrings: setup-guide
            NumberedStepRow(number: 3, text: "Find \"Shortcuts\" and tap \"Shortcut\"") // xcstrings: setup-guide
            NumberedStepRow(number: 4, text: "Select \"GigaAction\"") // xcstrings: setup-guide

            tipCallout(text: "Tip: You can resize and reposition the shortcut") // xcstrings: setup-guide
        }
    }

    private var keyboardShortcutInstructions: some View {
        VStack(alignment: .leading, spacing: 12) {
            NumberedStepRow(number: 1, text: "Open Shortcuts app") // xcstrings: setup-guide
            NumberedStepRow(number: 2, text: "Find \"GigaAction\" shortcut") // xcstrings: setup-guide
            NumberedStepRow(number: 3, text: "Right-click → Get Info") // xcstrings: setup-guide
            NumberedStepRow(number: 4, text: "Click \"Add Keyboard Shortcut\"") // xcstrings: setup-guide
            NumberedStepRow(number: 5, text: "Press your shortcut (e.g., ⌘⇧D)") // xcstrings: setup-guide

            tipCallout(text: "Tip: Choose a shortcut you'll remember easily") // xcstrings: setup-guide
        }
    }

    // MARK: - Tip Callout

    private func tipCallout(text: LocalizedStringKey) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "lightbulb.fill")
                .foregroundStyle(AppColors.warning)
                .onboardingScaledFont(.caption)
            Text(text)
                .onboardingScaledFont(.caption)
                .foregroundStyle(AppColors.textTertiary)
        }
        .padding(.top, 8)
    }
}

#Preview("Action Button") {
    ZStack {
        LinearGradient(
            colors: [AppColors.gradientStart, AppColors.gradientEnd],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()

        ActionButtonStepView(method: .actionButton, onDone: {})
    }
}

#Preview("Back Tap") {
    ZStack {
        LinearGradient(
            colors: [AppColors.gradientStart, AppColors.gradientEnd],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()

        ActionButtonStepView(method: .backTap, onDone: {})
    }
}

#Preview("Control Center (iPad)") {
    ZStack {
        LinearGradient(
            colors: [AppColors.gradientStart, AppColors.gradientEnd],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()

        ActionButtonStepView(method: .controlCenterShortcut, onDone: {})
    }
}
