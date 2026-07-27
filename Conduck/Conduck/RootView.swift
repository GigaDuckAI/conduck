// SPDX-License-Identifier: Apache-2.0

//
//  RootView.swift
//  Conduck
//
//  Onboarding gate via conditional rendering.
//  Sits in front of ContentView (still the Hello-world stub pending
//  the conversation-thread REPLACE) and shows OnboardingContainerView
//  until the user completes (or a prior install already did).
//
//  Why conditional rendering (not .fullScreenCover): an @State binding
//  initialized to `true` from init() does not reliably drive a
//  fullScreenCover on iOS 26 — there's no false→true transition for the
//  presentation system to observe. Conditional rendering avoids the
//  presentation edge case entirely.
//
//  Sync seed: the onboarding flag is a single bool in the App Groups
//  suite that SettingsManager owns. Reading it directly here avoids a
//  launch flash without changing the canonical source of truth.
//

import SwiftUI

struct RootView: View {
    @State private var showOnboarding: Bool

    init() {
        let defaults = UserDefaults(suiteName: Constants.appGroupID) ?? .standard
        let completed = defaults.bool(forKey: Constants.onboardingCompletedKey)
        #if DEBUG
        // Explicit "skip onboarding" intents win over the ambient dev flag, so an
        // automated QA launch is never trapped on first-run:
        //   • QAMode (`-ConduckQAMode`)        → configured, seeded app, past first-run
        //   • `-ConduckSkipOnboarding`         → REAL, unseeded app, past first-run
        // Only when NEITHER is set does `-ConduckShowOnboarding` force the wizard
        // (interactive onboarding iteration). None of these write UserDefaults, so
        // a plain re-launch still respects the persisted `onboarding_completed`.
        if QAMode.isActive || DebugFlags.skipOnboarding {
            _showOnboarding = State(initialValue: false)
        } else if DebugFlags.alwaysShowOnboarding {
            _showOnboarding = State(initialValue: true)
        } else {
            _showOnboarding = State(initialValue: !completed)
        }
        #else
        _showOnboarding = State(initialValue: !completed)
        #endif
    }

    var body: some View {
        Group {
            if showOnboarding {
                OnboardingContainerView(onComplete: {
                    showOnboarding = false
                })
            } else {
                ContentView()
            }
        }
        // One-time backfill so EXISTING conversations get a denormalized
        // `titleSnippet` (the Watch + iOS list rows show it instead of a generic
        // label). Guarded internally by an App-Group flag — cheap to call every
        // launch; the snippets CloudKit-sync to the Watch.
        .task {
            #if DEBUG
            if QAMode.isActive {
                await QAMode.seedConversationsIfNeeded()
            }
            #endif
            await ConversationStore.shared.backfillTitleSnippetsIfNeeded()
        }
    }
}
