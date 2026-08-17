// SPDX-License-Identifier: Apache-2.0

// Conduck
// CheckNetworkIntent.swift
//
// The pre-flight. FIRST action in the bundled shortcut, and the one lane where a
// refusal genuinely arrives BEFORE the microphone — everything after this point
// has already taken the user's words.
//
// It checks TWO things, in this order:
//
//   1. THE DESTINATION. Whether this capture has somewhere to land. It asks the
//      question in the SAME ORDER `SharedInboxRouting.resolveOrMint` asks it —
//      live quick-capture pointer first, this device's "Default for new chats"
//      only when there is no live pointer — through the same helper, so the
//      guard and the router can never disagree about what would have happened.
//      A pointer at a gateway that is not set up HERE, or no chosen default at
//      all on a device where several gateways work, both dead-end a NEW chat
//      after the user has spoken; a capture that would have been appended to a
//      working conversation is refused by neither. This check is free (two
//      `SettingsManager` turns, no network), so it goes first.
//   2. THE CONNECTION. The original `NWPathMonitor` one-shot probe, unchanged:
//      offline means the upload would fail anyway.
//
// WHY THE CHECK LIVES HERE rather than in a new intent: an installed shortcut
// references an intent by its TYPE IDENTIFIER, not by its title. Every GigaAction
// shortcut already on a user's device therefore picks this up on the next launch
// with no re-import — a new intent would reach only people who rebuilt their
// shortcut by hand, which is nobody. The title and description are re-worded to
// match what it does; the type name stays.
//
// The intent declares BOTH modes. `.background` lets it run headlessly, which is
// the normal case; `.foreground(.dynamic)` lets it ASK to continue in the
// foreground when the only useful outcome is putting the user on the fix. That
// ask is a REQUEST, not a contract — the system may or may not re-perform the
// intent — so `GatewayFixRoute` is armed BEFORE the throw and correctness never
// depends on a second `perform()`.
//
// A `.readingUnreliable` verdict deliberately falls THROUGH to the network probe
// and is never refused: before first unlock every token-bearing gateway reads as
// gone, so refusing there would block a capture on a device that is perfectly
// well set up.

import AppIntents
import Foundation
import Network

/// Pre-recording readiness check — somewhere to land first, then connectivity.
/// Throws when the capture would dead-end, so the bundled Shortcut bails before
/// `Record Audio` opens the mic UI.
struct CheckNetworkIntent: AppIntent {
    static var title: LocalizedStringResource = "Check Conduck Is Ready"      // xcstrings

    static var description: IntentDescription = IntentDescription(
        LocalizedStringResource("Checks your connection and your default AI before recording, so nothing you say is wasted.")  // xcstrings
    )

    /// Runs headlessly by default, and may ask to continue in the foreground
    /// when the fix needs a screen. `IntentModes` is an OptionSet — membership,
    /// not order, is what it declares.
    static var supportedModes: IntentModes = [.background, .foreground(.dynamic)]

    // MARK: - Perform

    func perform() async throws -> some IntentResult {
        // ONE snapshot turn. The verdict decides both what is refused and what
        // is said about it.
        let snap = await SettingsManager.shared.newChatPickerSnapshot()
        // The pointer arm, asked FIRST and through the router's own helper —
        // `resolveOrMint` reaches the default only when no live pointer answers.
        // The snapshot's `defaultRef` goes with it so both describe one instant.
        // A capture that continues a conversation on a gateway that is set up
        // here is not minting anything, so no verdict about the default may
        // refuse it; a conversation bound to a gateway that is NOT set up here
        // answers false and earns the refusal below, unchanged.
        let continuesLiveConversation = await SharedInboxRouting.liveQuickCaptureCanContinue(
            defaultRef: snap.defaultRef
        )
        if !continuesLiveConversation {
            switch snap.resolution {
            case .brokenDefault(let broken, _, let pointerIsParked):
                // Name the broken gateway — a DISPLAY NAME, never a URL — so the
                // user fixes the right one. A pointer the APP parked after a
                // Forget is not "your default AI": the user never chose it, and
                // may never have set it up, so it takes the unnamed sentence
                // instead of being blamed by name.
                guard !pointerIsParked else {
                    throw await refuse(
                        .remoteAgentDefaultNeedsSetup(gatewayName: nil),
                        dialog: Self.noDefaultDialog
                    )
                }
                let name = RemoteAgentRefMetadata.displayName(for: broken, customs: snap.badgeRoster)
                throw await refuse(
                    .remoteAgentDefaultNeedsSetup(gatewayName: name),
                    // xcstrings
                    dialog: String(localized: "Your default AI, \(name), isn't set up on this device. Open Conduck to pick a different one?")
                )
            case .selectionRequired:
                // Nothing to name: no default has been chosen at all.
                throw await refuse(
                    .remoteAgentDefaultNeedsSetup(gatewayName: nil),
                    dialog: Self.noDefaultDialog
                )
            case .nothingConfigured, .setupUnfinished:
                // Nothing can send and the reading IS trustworthy — code 12's
                // existing copy is exactly right, and there is no alternative
                // gateway to offer, so no foreground prompt either.
                throw AppError.remoteAgentNotConfigured
            case .usable, .adopted, .bootstrapped, .readingUnreliable:
                // `.readingUnreliable` is NOT refused: a Keychain blackout looks
                // identical to a deleted token from here, and blocking a capture
                // on a reading we cannot trust costs the user their words for
                // nothing. Let it fall through and fail closed later if it
                // really is broken.
                break
            }
        }

        let isConnected = await checkNetworkConnectivity()

        if isConnected {
            // Network available — shortcut continues to next action.
            return .result()
        } else {
            // No network — throw to stop the shortcut before recording.
            throw AppError.noInternetConnection
        }
    }

    // MARK: - Private Methods

    /// The sentence for a device that cannot say which AI a new chat would use.
    /// ONE literal for the two arms that own it — no default chosen at all, and
    /// a pointer the app parked on the user's behalf — because both describe the
    /// same fact and a second copy would let the two drift apart in translation.
    private static var noDefaultDialog: String {
        // xcstrings
        String(localized: "Conduck doesn't know which AI to use for new chats. Open Conduck to pick one?")
    }

    /// Ask — at most once per process — to continue in the foreground so the
    /// user lands on the fix, then hand back the error to throw.
    ///
    /// The route is armed BEFORE the error is returned on purpose: the
    /// foreground continuation is a REQUEST, not a contract, and a refusal that
    /// left no route armed would put the user back exactly where they started.
    /// If the system does re-perform this intent, the second pass reads the same
    /// snapshot and nothing else — the whole path is side-effect-free apart from
    /// that read, so a re-perform is safe.
    ///
    /// `claimForegroundPrompt()` is the once-per-process latch, so a repeated
    /// automation cannot nag its way through the same dialog over and over.
    /// Returns `any Error` because `needsToContinueInForegroundError` produces an
    /// `AppIntentError`, not an `AppError`.
    private func refuse(_ error: AppError, dialog: String) async -> any Error {
        // Short-circuit BEFORE the latch: a run that could never have shown the
        // dialog must not burn the one prompt this process is allowed.
        guard systemContext.currentMode.canContinueInForeground else { return error }
        guard await MainActor.run(body: { GatewayFixRoute.claimForegroundPrompt() }) else { return error }
        await MainActor.run { GatewayFixRoute.request() }
        return needsToContinueInForegroundError(IntentDialog(stringLiteral: dialog))
    }

    /// Check current network connectivity using NWPathMonitor.
    /// Returns immediately with current status (doesn't wait for changes).
    private func checkNetworkConnectivity() async -> Bool {
        await withCheckedContinuation { continuation in
            let monitor = NWPathMonitor()
            let queue = DispatchQueue(label: Constants.identityNamespace + ".networkcheck")
            // Single-fire latch, claimed BEFORE `cancel()` — `cancel()` stops
            // FUTURE deliveries but cannot un-enqueue a handler block already
            // dispatched onto the monitor's queue, and a second
            // `continuation.resume` is a hard `fatalError` in every build
            // configuration. Same primitive and same shape as
            // `DiagnosticsRunner.probeNetworkPath()`, the codebase's other
            // `NWPathMonitor` probe.
            let resumeOnce = LockedOnce()
            monitor.pathUpdateHandler = { [monitor] path in
                guard resumeOnce.claim() else { return }
                monitor.cancel()
                continuation.resume(returning: path.status == .satisfied)
            }

            monitor.start(queue: queue)
        }
    }
}
