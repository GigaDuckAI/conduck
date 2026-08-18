// SPDX-License-Identifier: Apache-2.0

// Conduck
// CheckNetworkIntent.swift
//
// The pre-flight. FIRST action in the bundled shortcut, and the one lane where a
// refusal genuinely arrives BEFORE the microphone — everything after this point
// has already taken the user's words.
//
// It checks THREE things, in this order — the two local reads first, the
// network probe last:
//
//   1. THE DESTINATION. Whether this capture has somewhere to land. It asks the
//      question in the SAME ORDER `SharedInboxRouting.resolveOrMint` asks it —
//      live quick-capture pointer first, this device's "Default for new chats"
//      only when there is no live pointer — through the same helper, so the
//      guard and the router can never disagree about what would have happened.
//      A pointer at a gateway that is not set up HERE, or no chosen default at
//      all on a device where several gateways work, both dead-end a NEW chat
//      after the user has spoken; a capture that would have been appended to a
//      working conversation is refused by neither. It costs two `SettingsManager`
//      turns and no network, so it goes first.
//   2. THE SPEECH-TO-TEXT KEY, and ONLY when its absence is PROVABLE. A cloud
//      preset with no key transcribes nothing, so `ConverseIntent` would refuse
//      a recording the user has already made. Refused here, the words are never
//      spoken. The check is `STTKeyReadiness.notConfigured` and nothing wider:
//      that verdict comes from `errSecItemNotFound`, the one Keychain status
//      that PROVES the slot is empty. A blackout (`.unreadable`) falls through
//      untouched for the same reason `.readingUnreliable` does below — see the
//      note at the foot of this header.
//   3. THE CONNECTION. The original `NWPathMonitor` one-shot probe, unchanged:
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
// AN UNREADABLE KEYCHAIN IS NEVER A REFUSAL HERE (I3), and both local checks
// obey that. A `.readingUnreliable` destination verdict and an `.unreadable` STT
// key verdict each fall THROUGH to the network probe: before first unlock every
// token-bearing gateway and every stored key reads exactly as if it were gone,
// so refusing on either would block a capture on a device that is perfectly well
// set up. The asymmetry with `ConverseIntent` is deliberate and runs the other
// way — there the words already exist, so a blackout is refused rather than
// spent on a transcription that cannot happen, and the recording is preserved.
// Here there is nothing to lose by letting the capture proceed.

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
            case .defaultUnavailable(let pointer, _, let pointerIsParked):
                // NAME the pointer — a DISPLAY NAME, never a URL — so the user
                // acts on the right one. The user invoked this, which is why a
                // name is owed here even though the quiet surfaces withhold it.
                //
                // A pointer the APP parked after a Forget is not "your default
                // AI": the user never chose it, so it takes the unnamed sentence
                // instead of being named at them.
                guard !pointerIsParked else {
                    throw await refuse(
                        .remoteAgentDefaultNeedsSetup(gatewayName: nil),
                        dialog: Self.noDefaultDialog
                    )
                }
                let name = RemoteAgentRefMetadata.displayName(for: pointer, customs: snap.badgeRoster)
                throw await refuse(
                    .remoteAgentDefaultNeedsSetup(gatewayName: name),
                    // xcstrings
                    dialog: String(localized: "Your default AI, \(name), isn't available on this device. Open Conduck to pick a different one?")
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

        // 2. THE KEY, on provable absence ONLY. A cloud preset whose slot is
        // genuinely empty cannot transcribe, and `ConverseIntent` would have to
        // refuse a recording that already exists — so refuse it here, before the
        // microphone. `.unreadable` is NOT refused (I3): a locked Keychain
        // answers identically to an empty one, and a device whose key is present
        // and correct must not be blocked on a reading nobody can trust.
        //
        // No `refuse(...)` foreground prompt: `GatewayFixRoute` lands the user on
        // the GATEWAY fix, which is the wrong screen for a voice key, and code
        // 23's own copy already names where the key goes.
        let stt = await SettingsManager.shared.activeSTTSnapshot()
        let keyReadiness = await STTKeyReadiness.resolve(
            presetID: stt.presetID,
            snapshotKey: stt.apiKey,
            provider: stt.provider,
            customConfig: stt.customConfig
        )
        if case .notConfigured = keyReadiness {
            throw AppError.sttMissingAPIKey
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

// MARK: - STT key readiness

/// What this device can honestly say about the ACTIVE speech-to-text preset's
/// API key. Lives here because the pre-flight owns the question, and is shared
/// verbatim with `ConverseIntent` so the lane that runs before the microphone
/// and the lane that runs after it can never disagree about the same slot.
///
/// The distinction this type exists to preserve. `activeSTTSnapshot()` hands
/// back `apiKey: String?`, and that nil collapses two different facts into one:
/// "there is no key" and "the Keychain could not answer". Keys are written
/// `kSecAttrAccessibleAfterFirstUnlock`, so on a rebooted, not-yet-unlocked
/// device every slot reads nil — and treating that as absence tells a correctly
/// configured user they have no key, then throws away the recording they just
/// made to prove it (I3, I6). `SettingsManager.apiKeyReadResult` already returns
/// the typed `APIKeyReadResult`; this type is the small amount of policy that
/// sits on top of it, and it is where each caller's asymmetric answer is
/// justified rather than repeated.
enum STTKeyReadiness: Equatable, Sendable {
    /// A usable key — or the empty string for a preset that needs none: an
    /// in-process provider (Apple on-device, authorised by TCC) or a keyless
    /// BYO endpoint (`auth == .none`).
    case ready(String)
    /// PROVABLE absence: `errSecItemNotFound`. The key was never entered on this
    /// device, hasn't synced in yet, or was cleared. This is the ONE verdict a
    /// pre-microphone refusal may be built on.
    case notConfigured
    /// The Keychain could not answer — locked before first unlock, an auth
    /// failure, an IPC error, or a success carrying an undecodable payload.
    /// NEVER proof of absence.
    case unreadable
}

extension STTKeyReadiness {

    /// Whether this preset needs a key at all. PURE, so the branch that decides
    /// nobody has to look at the Keychain is testable without one.
    static func requiresKey(provider: STTProvider, customConfig: CustomSTTConfig?) -> Bool {
        if provider.transport == .inProcess { return false }
        if customConfig?.auth == STTAuthScheme.none { return false }
        return true
    }

    /// Fold the snapshot's collapsed key and (when one was taken) the typed
    /// Keychain read into a verdict. PURE — the whole policy is here, so both
    /// intents share one answer and a real unit test can drive every arm.
    ///
    /// `typedRead` is nil when the caller had no reason to take one: either the
    /// preset needs no key, or the snapshot already carried a usable one. A nil
    /// alongside a preset that DOES need a key means nobody established which
    /// fact holds, and the only safe answer to "I don't know" is `.unreadable` —
    /// the arm that refuses nothing before the microphone and destroys nothing
    /// after it.
    static func classify(
        requiresKey: Bool,
        snapshotKey: String?,
        typedRead: APIKeyReadResult?
    ) -> STTKeyReadiness {
        guard requiresKey else { return .ready("") }
        if let key = snapshotKey, !key.isEmpty { return .ready(key) }
        switch typedRead {
        case .present(let key):
            // The slot answered on the second look — a Keychain that unlocked,
            // or a migration that completed, between the snapshot and now. Same
            // preset ID either way, so the key still pairs with the snapshot's
            // provider and using it is both correct and the kindest outcome.
            return .ready(key)
        case .missing:
            return .notConfigured
        case .unreadable:
            return .unreadable
        case nil:
            return .unreadable
        }
    }

    /// The live resolution: classify from an already-taken `activeSTTSnapshot()`,
    /// paying for the typed Keychain read ONLY on the path where the collapsed
    /// nil has to be explained. The happy path costs nothing extra, and the
    /// re-read names the SAME `presetID` the snapshot resolved, so the atomic
    /// (key, provider) pairing the snapshot exists to guarantee still holds.
    static func resolve(
        presetID: String,
        snapshotKey: String?,
        provider: STTProvider,
        customConfig: CustomSTTConfig?
    ) async -> STTKeyReadiness {
        let needsKey = requiresKey(provider: provider, customConfig: customConfig)
        guard needsKey, snapshotKey?.isEmpty ?? true else {
            return classify(requiresKey: needsKey, snapshotKey: snapshotKey, typedRead: nil)
        }
        let typed = await SettingsManager.shared.apiKeyReadResult(forPresetID: presetID)
        return classify(requiresKey: needsKey, snapshotKey: snapshotKey, typedRead: typed)
    }
}
