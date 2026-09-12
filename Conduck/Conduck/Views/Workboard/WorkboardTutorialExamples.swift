// SPDX-License-Identifier: Apache-2.0

// WorkboardTutorialExamples.swift
// Conduck
//
// Three compact, passive cues for the short Work introduction. They carry no
// sample state or actions. Each cue supplements one paragraph with familiar
// Work vocabulary; semantic text can wrap without a fixed card height.

import SwiftUI
#if os(macOS)
import KeyboardShortcuts
#endif

struct WorkboardTourCaptureCue: View {
    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: captureSymbol)
                .font(.title2)
                .foregroundStyle(AppColors.brandAmber)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 7) {
                #if os(macOS)
                Text(LocalizedStringResource(
                    "workdesk.tour.capture.mac.action", defaultValue: "Capture to Work…"
                ))
                .onboardingScaledFont(.headline)
                if let shortcut = KeyboardShortcuts.getShortcut(for: .captureToWork) {
                    Text(verbatim: shortcut.description)
                        .onboardingScaledFont(.subheadline)
                        .foregroundStyle(AppColors.textSecondary)
                }
                #else
                Text(LocalizedStringResource(
                    "workdesk.tour.example.add", defaultValue: "Add to Work"
                ))
                .onboardingScaledFont(.headline)
                #endif
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(AppColors.textPrimary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onboardingCardPadding()
        .glassCardBackground()
        .accessibilityElement(children: .combine)
    }

    private var captureSymbol: String {
        #if os(macOS)
        "menubar.rectangle"
        #else
        "square.and.arrow.up"
        #endif
    }
}

struct WorkboardTourProjectCue: View {
    var body: some View {
        HStack(spacing: 18) {
            Image(systemName: "folder.fill")
                .font(.largeTitle)
                .foregroundStyle(AppColors.brandTeal)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 7) {
                Text(LocalizedStringResource(
                    "workdesk.tour.example.project", defaultValue: "Website refresh"
                ))
                .onboardingScaledFont(.headline)
                Text(LocalizedStringResource(
                    "workdesk.tour.example.project.count", defaultValue: "2 materials"
                ))
                .onboardingScaledFont(.subheadline)
                .foregroundStyle(AppColors.textSecondary)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(AppColors.textPrimary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onboardingCardPadding()
        .glassCardBackground()
        .accessibilityElement(children: .combine)
    }
}

struct WorkboardTourRequestCue: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(LocalizedStringResource(
                "workdesk.tour.example.task", defaultValue: "Draft a clearer homepage."
            ))
            .onboardingScaledFont(.headline)
            .foregroundStyle(AppColors.textPrimary)
            Label {
                Text(LocalizedStringResource(
                    "workdesk.tour.example.project.count", defaultValue: "2 materials"
                ))
            } icon: {
                Image(systemName: "paperclip").accessibilityHidden(true)
            }
            .onboardingScaledFont(.subheadline)
            .foregroundStyle(AppColors.textSecondary)
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onboardingCardPadding()
        .glassCardBackground()
        .accessibilityElement(children: .combine)
    }
}
