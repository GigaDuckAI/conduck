// SPDX-License-Identifier: Apache-2.0

//  Conduck
//  WatchSetupGuideView.swift
//
//  iPhone-side Apple Watch setup guide (iOS / iPadOS only). Teaches the user
//  how to put Conduck on their wrist — the watch itself runs no on-wrist
//  onboarding. Reached from two entry points (both present this view via
//  `.fullScreenCover`):
//    1. Settings ▸ Apple Watch row (opens this walkthrough directly — there is
//       no intermediate Watch settings screen)
//    2. A one-time, dismissible home nudge (ContentView)
//
//  TWO paged steps: a welcome that confirms Conduck reaches the Watch (rides on
//  with the iPhone app + a manual add-from-Available-Apps fallback), then a
//  single "Add GigaAction to your Watch" step. Control Center and the Action
//  Button are two entry points to the SAME shipped `RecordNoteControl`
//  ControlWidget (display name "GigaAction") —
//  not two features — so either alone is sufficient. Control Center works on
//  EVERY Apple Watch and is the default path; the Action Button is Apple Watch
//  Ultra-only hardware, surfaced as a collapsed "Alternatively…" disclosure
//  (not a forced third step — the iPhone can't reliably detect a paired Ultra,
//  and the non-Ultra majority should never be marched through it). Gateway
//  reachability is NOT taught here — it's a deployment concern owned by the
//  gateway Guided-Setup disclosure (a tailnet-only gateway IS reachable from the
//  wrist via the paired iPhone's Tailscale — OS companion-routing — but unreachable
//  STANDALONE, iPhone off / out of range, since watchOS has no Tailscale client)
//  and surfaced at failure by `.remoteAgentUnreachable`; repeating it on this
//  UI-config screen was out of context. No allow-mic pre-step is taught: `RecordNoteIntent`
//  runs `.foreground(.immediate)`, so the first GigaAction press foregrounds the
//  Watch app and the system shows the mic prompt in-context — self-correcting.
//  Smart Stack / complications are out of scope (they'd need separate WidgetKit
//  widgets).
//
//  Uses the shared `onboardingStepLayout` scaffold (scroll body + PINNED footer)
//  so the Done button stays reachable even when the Ultra disclosure expands at
//  large Dynamic Type. Mirrors SetupGuideView's chrome (gradient + progress
//  capsules + slide transition + back/close affordances). Chatbot-reframed copy
//  — Conduck is a multi-turn AI client, NOT a note-dictation app.
//

#if os(iOS)
import SwiftUI

/// Two-step paged Watch setup guide. A back affordance moves from step 2 to
/// step 1; the top-trailing Close button dismisses the cover at any point.
struct WatchSetupGuideView: View {
    @Environment(\.dismiss) private var dismiss

    /// 1-based step index (1 = welcome, 2 = add GigaAction to the Watch).
    @State private var step: Int = 1

    /// Whether the Ultra-only Action Button alternative is expanded (step 2).
    @State private var showActionButtonAlternative = false

    private enum NavigationDirection { case forward, backward }
    @State private var navigationDirection: NavigationDirection = .forward

    private let stepCount = 2

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
                    .accessibilityLabel(Text("Go Back")) // xcstrings: watch-setup
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
                .accessibilityLabel(Text("Close")) // xcstrings: watch-setup
                .padding(.top, 8)
                .padding(.trailing, 16)
            }
        }
    }

    // MARK: - Progress Indicator

    private var progressIndicator: some View {
        HStack(spacing: 8) {
            ForEach(1...stepCount, id: \.self) { index in
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
        case 1:  welcomeStep
        default: gigaActionStep
        }
    }

    // MARK: - Step 1: Welcome / value

    private var welcomeStep: some View {
        VStack(spacing: 24) {
            Image("conduck-smartwatch-hologram")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .onboardingMascot(hero: true, scale: 1.15)

            Text("Conduck on Apple Watch") // xcstrings: watch-setup
                .onboardingScaledFont(.title, weight: .bold)
                .foregroundStyle(AppColors.textEmphasis)
                .multilineTextAlignment(.center)

            // The one genuinely useful thing this step can say: Conduck rides
            // onto the Watch with the iPhone app, plus the manual fallback if it
            // didn't. (Replaced a value-prop pitch — low information for the
            // space; the user already chose to set the Watch up.)
            VStack(alignment: .leading, spacing: 12) {
                WatchValueRow(
                    icon: "checkmark.circle",
                    title: "Installs automatically",
                    detail: "Comes with the iPhone app — no separate download."
                )
                WatchValueRow(
                    icon: "plus.circle",
                    title: "Don't see it?",
                    detail: "Open the Watch app on your iPhone and add Conduck from Available Apps."
                )
            }
            .padding(16)
            .glassCardBackground()
            .padding(.horizontal, 32)
        }
        .onboardingStepLayout {
            footerButton(title: "Next", action: nextStep) // xcstrings: watch-setup
        }
    }

    // MARK: - Step 2: Add GigaAction to your Watch (Control Center + Ultra alt)

    private var gigaActionStep: some View {
        VStack(spacing: 20) {
            Image("conduck-bench-press")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .onboardingMascot()

            Text("Add \(Self.gigaAction) to your Watch") // xcstrings: watch-setup
                .onboardingScaledFont(.title, weight: .bold)
                .foregroundStyle(AppColors.textEmphasis)
                .multilineTextAlignment(.center)

            controlCenterCard
            actionButtonAlternativeCard
        }
        .onboardingStepLayout {
            footerButton(title: "Done", action: { dismiss() }) // xcstrings: watch-setup
        }
    }

    /// The brand term "GigaAction" armored with zero-width word joiners (U+2060)
    /// between every letter. SwiftUI exposes no hyphenation toggle and ignores
    /// paragraph-style `hyphenationFactor`, so at large Dynamic Type it hyphenates
    /// the term mid-word ("GigaAc-tion") in the narrow numbered-step column. Word
    /// joiners forbid the internal break points hyphenation needs, so the term
    /// wraps whole instead. The joiners are zero-width (invisible); copy/paste of
    /// the rendered text still yields plain "GigaAction".
    private static let gigaAction: String = "GigaAction"
        .map(String.init)
        .joined(separator: "\u{2060}")

    /// Default, universal path — works on every Apple Watch.
    private var controlCenterCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Add to Control Center") // xcstrings: watch-setup
                    .onboardingScaledFont(.subheadline, weight: .semibold)
                    .foregroundStyle(AppColors.textPrimary)
                Text("Works on every Apple Watch") // xcstrings: watch-setup
                    .onboardingScaledFont(.caption2)
                    .foregroundStyle(AppColors.textTertiary)
            }

            NumberedStepRow(number: 1, text: "Press the side button to open Control Center") // xcstrings: watch-setup
            NumberedStepRow(number: 2, text: "Scroll down, tap Edit") // xcstrings: watch-setup
            NumberedStepRow(number: 3, text: "Tap the + button") // xcstrings: watch-setup
            NumberedStepRow(number: 4, text: "Find Conduck, tap \(Self.gigaAction)") // xcstrings: watch-setup
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onboardingCardPadding()
        .glassCardBackground()
        .padding(.horizontal, 32)
    }

    /// Apple Watch Ultra-only alternative — collapsed by default; binds the SAME
    /// GigaAction control to the physical Action Button.
    private var actionButtonAlternativeCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                withAnimation(.easeInOut(duration: 0.25)) {
                    showActionButtonAlternative.toggle()
                }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Apple Watch Ultra?") // xcstrings: watch-setup
                            .onboardingScaledFont(.subheadline, weight: .semibold)
                            .foregroundStyle(AppColors.textPrimary)
                        Text("Alternatively, bind the Action Button") // xcstrings: watch-setup
                            .onboardingScaledFont(.caption)
                            .foregroundStyle(AppColors.textSecondary)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(AppColors.textTertiary)
                        .rotationEffect(.degrees(showActionButtonAlternative ? 180 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Apple Watch Ultra Action Button setup")) // xcstrings: watch-setup
            .accessibilityHint(Text(showActionButtonAlternative ? "Collapse" : "Expand")) // xcstrings: watch-setup

            if showActionButtonAlternative {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Runs the same \(Self.gigaAction) — you only need one of these.") // xcstrings: watch-setup
                        .onboardingScaledFont(.caption)
                        .foregroundStyle(AppColors.textTertiary)

                    NumberedStepRow(number: 1, text: "Open Settings on your Watch") // xcstrings: watch-setup
                    NumberedStepRow(number: 2, text: "Tap Action Button") // xcstrings: watch-setup
                    NumberedStepRow(number: 3, text: "Set Action to Control") // xcstrings: watch-setup
                    NumberedStepRow(number: 4, text: "Tap Control, find Conduck") // xcstrings: watch-setup
                    NumberedStepRow(number: 5, text: "Select \(Self.gigaAction)") // xcstrings: watch-setup
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onboardingCardPadding()
        .glassCardBackground()
        .padding(.horizontal, 32)
    }

    // MARK: - Shared building blocks

    /// Footer CTA for the `onboardingStepLayout` scaffold (the scaffold owns the
    /// bottom padding + width caps, so this only styles the button itself).
    private func footerButton(title: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
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

    // MARK: - Navigation

    private func nextStep() {
        navigationDirection = .forward
        withAnimation(.easeInOut(duration: 0.3)) {
            step = min(step + 1, stepCount)
        }
    }

    private func previousStep() {
        navigationDirection = .backward
        withAnimation(.easeInOut(duration: 0.3)) {
            step = max(step - 1, 1)
        }
    }
}

// MARK: - Value Row

/// Icon + title + detail row for the welcome step's value props.
private struct WatchValueRow: View {
    let icon: String
    let title: LocalizedStringKey
    let detail: LocalizedStringKey

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                // Leading row-icon in a fixed 24pt frame — leave at base size
                // (don't scale the glyph past its box); adjacent text still bumps.
                .font(.subheadline)
                .foregroundStyle(.tint)
                .frame(width: 24)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .onboardingScaledFont(.subheadline, weight: .semibold)
                    .foregroundStyle(AppColors.textPrimary)

                Text(detail)
                    .onboardingScaledFont(.caption)
                    .foregroundStyle(AppColors.textTertiary)
            }

            Spacer()
        }
    }
}

#Preview("Welcome") {
    WatchSetupGuideView()
}
#endif
