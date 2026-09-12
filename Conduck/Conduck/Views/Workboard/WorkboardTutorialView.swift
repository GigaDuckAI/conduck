// SPDX-License-Identifier: Apache-2.0

// WorkboardTutorialView.swift
// Conduck
//
// Four brief lessons shown on the first eligible Chat-to-Work visit. The
// presentation owner handles the device-local flag and interruptions.
// Each page has one paragraph and one passive visual; only Back, Next, Skip
// and Go to Work are interactive. Nothing captures, sends, creates material
// or focuses the composer. The setup scaffold keeps the footer reachable.

import SwiftUI

struct WorkboardTutorialView: View {
    @Bindable var session: WorkboardTutorialSession
    let onDone: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AccessibilityFocusState private var headingFocused: Bool

    var body: some View {
        ZStack {
            SetupAtmosphereBackground()
            VStack(spacing: 0) {
                chrome
                VStack(spacing: 28) {
                    introduction
                    lesson
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
                .onboardingStepLayout { footer }
                .environment(\.onboardingStepPlacement, .top)
                .id(session.currentStep)
                .transition(.opacity)
            }
        }
        .workboardDesktopSheetFrame(
            minWidth: 420, minHeight: 0, idealWidth: 600, idealHeight: 660,
            maxWidth: 680, maxHeight: 800
        )
        .task(id: session.currentStep) {
            headingFocused = false
            await Task.yield()
            guard !Task.isCancelled else { return }
            headingFocused = true
        }
    }

    private var chrome: some View {
        HStack(spacing: 12) {
            Button {
                changeStep { session.goBack() }
            } label: {
                Image(systemName: "chevron.left")
                    .font(.body.weight(.semibold))
                    .frame(width: 44, height: 44)
            }
            .pointerIconButton(size: 44, shape: .circle)
            .accessibilityLabel(Text(LocalizedStringResource(
                "workdesk.tour.back", defaultValue: "Previous step"
            )))
            .disabled(session.currentStep == 0)
            .opacity(session.currentStep == 0 ? 0 : 1)
            .accessibilityHidden(session.currentStep == 0)

            Spacer(minLength: 0)
            Text(LocalizedStringResource(
                "workdesk.tour.progress", defaultValue: "\(session.currentStep + 1) of 4"
            ))
            .font(.subheadline)
            .foregroundStyle(AppColors.textSecondary)
            .accessibilityLabel(Text(LocalizedStringResource(
                "workdesk.tour.progress.accessibility", defaultValue: "Step \(session.currentStep + 1) of 4"
            )))
            Spacer(minLength: 0)

            Button(action: onDone) {
                Text(LocalizedStringResource("workdesk.tour.skip", defaultValue: "Skip tour"))
                    .font(.subheadline)
                    .foregroundStyle(AppColors.textSecondary)
                    .padding(.vertical, 10)
            }
            .inlineLinkButton()
            .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 6)
        .frame(maxWidth: 620)
        .frame(maxWidth: .infinity)
    }

    private var introduction: some View {
        VStack(spacing: 12) {
            Text(title)
                .onboardingScaledFont(.title, weight: .bold)
                .foregroundStyle(AppColors.textEmphasis)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
                .accessibilityFocused($headingFocused)
            Text(subtitle)
                .onboardingScaledFont(.subheadline)
                .foregroundStyle(AppColors.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var lesson: some View {
        switch session.currentStep {
        case 0:
            Image("conduck-work-guide")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .onboardingMascot(hero: true)
                .accessibilityHidden(true)
        case 1:
            WorkboardTourCaptureCue()
        case 2:
            WorkboardTourProjectCue()
        default:
            WorkboardTourRequestCue()
        }
    }

    private var footer: some View {
        Button {
            if session.currentStep == 3 {
                onDone()
            } else {
                changeStep { session.advance() }
            }
        } label: {
            Text(session.currentStep == 3
                 ? LocalizedStringResource("workdesk.tour.done", defaultValue: "Go to Work")
                 : LocalizedStringResource("workdesk.tour.next", defaultValue: "Next"))
                .onboardingScaledFont(.headline)
                .foregroundStyle(AppColors.background)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 14))
        }
        .primaryCTAButton()
        .keyboardShortcut(.defaultAction)
        .padding(.horizontal, Constants.Layout.horizontalPadding)
        .accessibilityIdentifier("workboard-tour-next")
    }

    private func changeStep(_ update: () -> Void) {
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18), update)
    }

    private var title: LocalizedStringResource {
        switch session.currentStep {
        case 0: .init("workdesk.tour.collect.title", defaultValue: "A home for your next idea")
        case 1: .init("workdesk.tour.capture.title", defaultValue: "Catch it where you find it")
        case 2: .init("workdesk.tour.project.title", defaultValue: "Bring related ideas together")
        default: .init("workdesk.tour.request.title", defaultValue: "Give your AI the right context")
        }
    }

    private var subtitle: LocalizedStringResource {
        switch session.currentStep {
        case 0:
            .init("workdesk.tour.collect.subtitle", defaultValue: "Type or speak a thought, or add links, screenshots and files. Adding to Work doesn’t send them to your AI.")
        case 1:
            #if os(macOS)
            .init("workdesk.tour.capture.mac.brief", defaultValue: "Right-click the menu-bar duck and choose Capture to Work. Save a screenshot, a thought, or both.")
            #else
            .init("workdesk.tour.capture.phone.brief", defaultValue: "In another app, choose Share → Conduck → Add to Work. It will be waiting on Home.")
            #endif
        case 2:
            .init("workdesk.tour.project.subtitle", defaultValue: "Use Select to group related materials in a project. Open its folder to see them together.")
        default:
            .init("workdesk.tour.request.subtitle", defaultValue: "Start a new conversation in your project. Choose materials, write a task, then review and send to your chosen AI.")
        }
    }
}

#Preview {
    WorkboardTutorialView(session: WorkboardTutorialSession(), onDone: {})
}
