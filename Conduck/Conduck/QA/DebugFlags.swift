// SPDX-License-Identifier: Apache-2.0

//
//  DebugFlags.swift
//  Conduck
//
//  Developer-only launch flags for the Xcode simulator/debug workflow.
//  Sibling to `QAMode` (same folder, same two-gate safety) but kept separate
//  because the semantics are OPPOSITE: `QAMode` lands a CONFIGURED app and
//  SKIPS onboarding; these flags are for iterating on first-run flows.
//
//  **Production safety (two gates), mirroring `QAMode`:**
//  1. The entire enum is wrapped `#if DEBUG`, so Release builds contain zero
//     `DebugFlags` symbols.
//  2. Every flag is additionally gated on a launch argument. A Debug build
//     launched WITHOUT the arg behaves byte-identically to today — no
//     persistent writes, real read-paths untouched.
//

#if DEBUG
import Foundation

enum DebugFlags {
    /// `-ConduckShowOnboarding` — force the onboarding wizard to appear on
    /// EVERY launch, regardless of the persisted `onboarding_completed` flag.
    /// A read-only override: it never writes `UserDefaults`, so unsetting the
    /// arg (untick the scheme checkbox) restores normal behavior immediately,
    /// and completing onboarding still lands the user in the app this session.
    ///
    /// This is the AMBIENT dev-convenience flag (it lives enabled in the shared
    /// scheme for onboarding iteration). The explicit "skip" intents below
    /// (`-ConduckQAMode`, `-ConduckSkipOnboarding`) BEAT it if both are set, so
    /// an automated QA launch is never trapped on first-run. See the precedence
    /// in `RootView.init()` (iOS) / `AppDelegate.didFinishLaunching` (macOS).
    ///
    /// Set it in Xcode ▸ Product ▸ Scheme ▸ Edit Scheme… ▸ Run ▸ Arguments
    /// ▸ "Arguments Passed On Launch".
    static let alwaysShowOnboarding: Bool =
        ProcessInfo.processInfo.arguments.contains("-ConduckShowOnboarding")

    /// `-ConduckSkipOnboarding` — skip the onboarding wizard on every launch
    /// WITHOUT any of `QAMode`'s other side effects (no seeded conversations, no
    /// gateway override, no QA banner, no Keychain skip). For QA agents that must
    /// exercise the REAL, unseeded app minus first-run (empty state, genuine
    /// settings persistence, etc.). Read-only override: never writes
    /// `UserDefaults`, so a plain re-launch still respects the persisted flag.
    ///
    /// Beats `-ConduckShowOnboarding` if both are set (an explicit skip intent
    /// wins over the ambient dev-convenience flag — same rationale as `QAMode`).
    static let skipOnboarding: Bool =
        ProcessInfo.processInfo.arguments.contains("-ConduckSkipOnboarding")

    // `-ConduckUncapCustomGateways` (lift the custom-gateway cap to the
    // badge-palette ceiling) is deliberately NOT declared here: the Watch
    // target compiles `Utilities/Constants.swift` — where the flag gates
    // `Constants.maxCustomGateways` — but not `QA/`. Recorded so this file
    // stays the index of developer launch flags.
}
#endif
