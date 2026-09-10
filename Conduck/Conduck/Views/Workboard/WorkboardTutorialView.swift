// SPDX-License-Identifier: Apache-2.0

// Conduck
// WorkboardTutorialView.swift
//
// The one-time duck beat shown on a first visit to Work. It carries the three
// things the board surface itself does not say in-place — collect from
// anywhere, arrange and resize freely, cards sync through your own iCloud — so
// the board can stay de-texted and the affordances still get taught once.
//
// The third line must stay inside `WorkMaterialStoragePolicy`'s truth: a payload
// over `Constants.workboardSyncCeilingBytes` is device-local behind a reattach,
// so the line names that lane rather than promising every byte on every device.
//
// Register: warm INSTRUCTION, not a pitch. The user already chose Conduck; this
// screen tells them how the board behaves and then gets out of the way. Chrome
// mirrors the app's other single-beat first-run screens (`GatewayPrimerStepView`,
// `EnableNotificationsStepView`): the gradient ground, `onboardingMascot` art,
// and `.onboardingStepLayout`'s scroll-plus-pinned-footer, so the ONE CTA is
// reachable at every Dynamic Type size.
//
// PERSISTENCE LIVES OUTSIDE THIS VIEW. It only reports acknowledgement through
// `onDone`; the presentation site (`WorkboardPresentationModifier`, Work's single
// sheet owner) writes `SettingsManager.markWorkboardTutorialSeen()` when the
// sheet goes away — covering the CTA, an iOS swipe-down and a macOS Escape with
// one rule, and never firing on mere appearance.

import SwiftUI

struct WorkboardTutorialView: View {
    /// Acknowledgement — the host dismisses the sheet and marks the flag seen.
    let onDone: () -> Void

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [AppColors.gradientStart, AppColors.gradientEnd],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 24) {
                // The painter duck: the board is a surface you compose on. Art is
                // decorative — the headline carries the meaning.
                Image("conduck-painter")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .onboardingMascot(hero: true)
                    .accessibilityHidden(true)

                Text(LocalizedStringResource(
                    "workboard.tutorial.title",
                    defaultValue: "How your board works"
                ))
                .onboardingScaledFont(.title, weight: .bold)
                .foregroundStyle(AppColors.textEmphasis)
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
                .padding(.horizontal, 32)

                points
            }
            .onboardingStepLayout {
                footer
            }
        }
        .workboardDesktopSheetFrame(minWidth: 420, minHeight: 560)
    }

    // MARK: - The three lines

    /// One line per affordance, in the order the work happens: gather, arrange,
    /// keep. Kept to a single clause each — a longer explainer here would just
    /// re-import the text the board surface was cleared of.
    private var points: some View {
        VStack(alignment: .leading, spacing: 14) {
            point(
                symbol: "tray.and.arrow.down.fill",
                text: LocalizedStringResource(
                    "workboard.tutorial.point.collect",
                    defaultValue: "Collect anything — files, screenshots, links and thoughts."
                )
            )
            point(
                symbol: "square.grid.2x2.fill",
                text: LocalizedStringResource(
                    "workboard.tutorial.point.arrange",
                    defaultValue: "Move cards by their handles. Overlap ideas to start a project, or use Select."
                )
            )
            point(
                symbol: "arrow.up.forward",
                text: LocalizedStringResource(
                    "workdesk.tutorial.prepare",
                    defaultValue: "Shape a project brief, choose your AI, then review before sending."
                )
            )
            point(
                symbol: "lock.shield.fill",
                text: LocalizedStringResource(
                    "workboard.tutorial.point.review",
                    defaultValue: "Cards sync through your own iCloud — very large files stay on the device that captured them."
                )
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onboardingCardPadding()
        .glassCardBackground()
        .padding(.horizontal, 32)
    }

    /// Icon + line row. Mirrors the `limitRow` idiom of the other first-run
    /// cards; the glyph is decorative, so the row reads as one label.
    private func point(symbol: String, text: LocalizedStringResource) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: symbol)
                .onboardingScaledFont(.subheadline)
                .foregroundStyle(AppColors.brandAmber)
                .frame(width: 22)
                .accessibilityHidden(true)
            Text(text)
                .onboardingScaledFont(.subheadline)
                .foregroundStyle(AppColors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - Pinned footer (one CTA)

    /// A single exit. `.defaultAction` lets Return acknowledge on macOS, where a
    /// one-button sheet has no other keyboard path out.
    private var footer: some View {
        Button(action: onDone) {
            Text(LocalizedStringResource(
                "workboard.tutorial.done",
                defaultValue: "Start collecting"
            ))
            .onboardingScaledFont(.headline)
            .foregroundColor(AppColors.textEmphasis)
            .frame(maxWidth: Constants.Layout.buttonMaxWidth)
            .padding(.vertical, 16)
            .background(Color.accentColor)
            .cornerRadius(14)
        }
        .primaryCTAButton()
        .keyboardShortcut(.defaultAction)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, Constants.Layout.horizontalPadding)
        .accessibilityIdentifier("workboard.tutorial.done")
    }
}

#Preview {
    WorkboardTutorialView(onDone: {})
}
