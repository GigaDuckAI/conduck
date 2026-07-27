// SPDX-License-Identifier: Apache-2.0

//  ShortcutStepView.swift
//  Conduck
//
//  Add Shortcut step using bundled signed shortcut file
//

import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif

struct ShortcutStepView: View {
    let onContinue: () -> Void

    @State private var showError = false

    var body: some View {
        VStack(spacing: 24) {
            // Character
            Image("conduck-laptop")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .onboardingMascot(hero: true)

            // Title and description
            VStack(spacing: 12) {
                Text("Add Shortcut") // xcstrings: setup-guide
                    .onboardingScaledFont(.title, weight: .bold)
                    .foregroundStyle(AppColors.textEmphasis)
                    .accessibilityAddTraits(.isHeader)

                Text("First step: tap Add Shortcut below. Takes a second.") // xcstrings: setup-guide
                    .onboardingScaledFont(.body)
                    .foregroundStyle(AppColors.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
        }
        .onboardingStepLayout {
            // Action buttons
            VStack(spacing: 12) {
                Button(action: addShortcut) {
                    HStack {
                        Image(systemName: "plus.square.on.square")
                        Text("Add Shortcut") // xcstrings
                    }
                    .onboardingScaledFont(.headline)
                    .foregroundColor(AppColors.textEmphasis)
                    .frame(maxWidth: Constants.Layout.buttonMaxWidth)
                    .padding(.vertical, 16)
                    .background(Color.accentColor)
                    .cornerRadius(14)
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)

                Button(action: onContinue) {
                    VStack(spacing: 4) {
                        Text("I've Added It") // xcstrings
                            .onboardingScaledFont(.subheadline, weight: .medium)
                            .foregroundColor(AppColors.textSecondary)
                        Text("Synced from another device") // xcstrings
                            .onboardingScaledFont(.caption2)
                            .foregroundColor(AppColors.textTertiary)
                    }
                    .frame(maxWidth: Constants.Layout.buttonMaxWidth)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(AppColors.borderSubtle, lineWidth: 1)
                    )
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 4)
            }
            .padding(.horizontal, Constants.Layout.horizontalPadding)
        }
        .alert("Error", isPresented: $showError) { // xcstrings
            Button("OK", role: .cancel) {} // xcstrings
        } message: {
            Text("Could not find the shortcut file. Please reinstall the app.") // xcstrings
        }
    }

    // MARK: - Actions

    private func addShortcut() {
        // PENDING DEPENDENCY: the bundled `GigaAction.shortcut` file must be
        // authored in the Shortcuts app (Check Network → Record Audio →
        // GigaAction) and dropped into `Resources/`. Until it lands this guard
        // fails gracefully → error alert.
        guard let bundleURL = Bundle.main.url(forResource: "GigaAction", withExtension: "shortcut") else {
            showError = true
            return
        }

        // Copy to temp location (required for UIApplication.open to work)
        let tempDir = FileManager.default.temporaryDirectory
        let tempURL = tempDir.appendingPathComponent("GigaAction.shortcut")

        // Remove existing if present
        try? FileManager.default.removeItem(at: tempURL)

        do {
            try FileManager.default.copyItem(at: bundleURL, to: tempURL)
            #if os(iOS)
            UIApplication.shared.open(tempURL)
            #else
            NSWorkspace.shared.open(tempURL)
            #endif
        } catch {
            showError = true
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

        ShortcutStepView(onContinue: {})
    }
}
