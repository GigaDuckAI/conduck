// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import WatchKit

/// One-time first-run notice, shown the very FIRST time the user opens the
/// Conduck watch app (gated by `WatchSettingsReader.hasSeenOnboarding()` in
/// `ConduckWatchApp`). Purely INFORMATIONAL — an honest expectation-set so a
/// slow first turn doesn't read as broken: the first one or two interactions
/// warm up before the wrist path settles. Deliberately bare (no hero art, no
/// title) so
/// the message + CTA fit a 40 mm screen WITHOUT scrolling.
///
/// Restrained to the watch idiom: near-black background, a single one-shot
/// opacity fade-in (no looping animation — see `WatchConversationThreadView`),
/// Reduce Motion honored. Rendered only while foreground-active AND with no
/// capture pending (the gate defers to `WatchRecordingCoordinator`), so an
/// Action-Button cold-launch is never interrupted. `onDone` fires on the
/// "Got it" tap ONLY — the caller persists the seen-flag there, so a killed
/// first launch re-shows.
struct WatchOnboardingView: View {
    let onDone: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            Text("Your first one or two interactions may need a moment to warm up. It settles after that.")
                .font(.caption)
                .foregroundStyle(AppColors.textSecondary)
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.7) // shrink-to-fit at large Dynamic Type so it never needs to scroll
                .opacity(appeared ? 1 : 0)
                .animation(entrance(delay: 0), value: appeared)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 6)
        .background(AppColors.background.ignoresSafeArea())
        .safeAreaInset(edge: .bottom) {
            Button {
                WKInterfaceDevice.current().play(.click)
                onDone()
            } label: {
                Text("Got it")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange) // matches the launchpad Ask button — the wrist's primary-action idiom
            .padding(.horizontal, 8)
            .padding(.bottom, 2)
            .opacity(appeared ? 1 : 0)
            .animation(entrance(delay: 0.06), value: appeared)
        }
        .onAppear {
            WatchLog.note(.nav, "onboarding.shown")
            // Spend the dwell time productively: nudge the iPhone→Watch identity/
            // settings courier so the first ask lands on a warmer path (the store
            // is already warmed in `ConduckWatchApp.init`). Fire-and-forget — the
            // same poke `WatchSetupView` issues while waiting for identity.
            Task { _ = await WatchIdentityResolver.shared.requestFromPhone() }
            appeared = true
        }
    }

    /// One-shot entrance curve; `nil` under Reduce Motion so the state change
    /// applies instantly (no fade).
    private func entrance(delay: Double) -> Animation? {
        reduceMotion ? nil : .easeInOut(duration: 0.2).delay(delay)
    }
}
