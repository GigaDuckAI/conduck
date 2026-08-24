// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import UserNotifications
import WatchConnectivity

/// Suppresses foreground notification banners. Background upload completions
/// still surface as native banners + sound (willPresent isn't called when the
/// app is suspended), so backgrounded delivery is unaffected.
///
/// Also handles a TAP on a delivered reply banner (`didReceive`): a suspended
/// reply arrives as a local notification carrying its `conversationID` (stamped
/// in `WatchAudioUploader.postNotification`). Tapping it deep-links the user
/// into that exact thread via `WatchReplyDeepLinkCoordinator`, which
/// `WatchNoteView` observes and drains into a `.capture(.existing(id))` push.
/// There is no `onOpenURL` on watchOS — this delegate IS the deep-link entry.
///
/// Conformances are `nonisolated` (the codebase's AV-delegate pattern — see
/// `WatchReplySpeaker`): the notification center calls back on its own queue,
/// and a MainActor-isolated conformance would force-sync each callback onto
/// the main thread. Only Sendable values cross to the MainActor hop.
private class WatchNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        // Only the default action (a tap on the banner) deep-links; dismiss
        // actions fall through to the completion handler with no navigation.
        // Payload extraction happens inside the hop (the conversationID key is
        // MainActor-isolated under the target's default isolation), so the
        // userInfo dict crosses as a Sendable plist bridge, never as-is.
        if response.actionIdentifier == UNNotificationDefaultActionIdentifier {
            let bridged = SendablePlistPayload(
                (response.notification.request.content.userInfo as? [String: Any]) ?? [:]
            )
            Task { @MainActor in
                guard let userInfo = bridged.dictionary(),
                      let raw = userInfo[WatchAudioUploader.notificationConversationIDKey] as? String,
                      let id = UUID(uuidString: raw) else { return }
                WatchLog.note(.nav, "notif.tap", ["keys": bridged.keyCount])
                WatchReplyDeepLinkCoordinator.shared.requestDeepLink(to: id)
            }
        }
        completionHandler()
    }
}

@main
struct ConduckWatchApp: App {
    private let notificationDelegate = WatchNotificationDelegate()
    @State private var hasIdentity: Bool
    @State private var showOnboarding: Bool

    init() {
        // Touch the recording coordinator first so its singleton exists in
        // this process before `RecordNoteIntent.perform()` can run. Without
        // this, a cold-launch via the Action Button could race the singleton
        // construction.
        _ = WatchRecordingCoordinator.shared

        // Same cold-launch-ordering guard for the reply deep-link coordinator:
        // a tapped suspended-reply notification can fire `didReceive` before the
        // root view mounts, so the singleton must already exist to stash it.
        _ = WatchReplyDeepLinkCoordinator.shared

        UNUserNotificationCenter.current().delegate = notificationDelegate

        // Activate WCSession early
        WatchSessionManager.shared.activate()

        // Start iCloud KVS observer for identity
        Task {
            await WatchIdentityResolver.shared.startObserving()
        }

        // Ensure both background URLSessions are created (required for relaunch
        // delivery — STT hop AND the agent converse hop).
        _ = WatchAudioUploader.shared.backgroundSession
        _ = WatchAudioUploader.shared.converseSession

        // Resolve the ACCOUNT read cutover — the moment before which the absence
        // of a marker means "already seen" rather than "we were not recording
        // yet". Stamps a local value if this Watch has none, arms the iCloud
        // change feed, and meets whatever the account already holds by `min`.
        //
        // THE WRIST NEEDS THIS MOST. It is the last device of the fleet to be
        // set up and the one whose local storage is wiped by an unpair/re-pair,
        // so it is the likeliest to mint a cutover months later than the
        // account's real one. Without the meet, that late stamp would classify
        // every reply older than the re-pair as seen, and the wrist would show a
        // silent list while the phone showed dots.
        //
        // HERE, in deterministic app init — never from a SwiftUI `body`, which
        // both creates state during rendering and races the CloudKit import.
        // Idempotent, so the background-URLSession relaunches below re-run it
        // for free. Mirrors the iOS `ConduckApp.init` and macOS `AppDelegate`
        // wiring; watchOS shares no launch code with either.
        ReadStateStore.shared.resolveAccountCutover()

        // Warm the conversation store so the first capture's append/fetch isn't
        // blocked on lazy `loadPersistentStores` (the Watch is a
        // conversational surface backed by `ConversationStore`).
        Task { await ConversationStore.shared.warmUp() }

        // Stale-"sending" recovery. The wrist writes its user turn as `sending`
        // and lets the converse delegate resolve it — so a jetsam or a
        // force-quit mid-turn strands that turn at `sending`, with the Retry
        // chip (which requires `failed`) permanently out of reach. watchOS
        // jetsams a backgrounded app aggressively, which makes this the surface
        // that needs the sweep MOST, and the phone's own launch sweep cannot
        // cover it: live Watch tasks run in another process on another device
        // and are invisible there.
        //
        // Runs AFTER the two sessions are materialized above, so `allTasks`
        // already reports the tasks the relaunch resurrected.
        //
        // MESSAGE-LEVEL ONLY. It never touches a `GatewayAttempt` row: a device
        // that cannot find a local task has learned nothing about the attempt,
        // and writing that ignorance down would race the real answer arriving
        // from the device that owns the task. A stranded attempt is READ as
        // `unconfirmed` once its grace lapses, and repaired for free by any
        // later terminal callback or CloudKit sync.
        Task { await Self.sweepStaleWatchSends() }

        // Privacy hygiene — reclaim capture audio and request bodies an abnormal
        // termination stranded in `temporaryDirectory` (see TempScratchSweeper).
        // The wrist needs this MORE than the phone, not less: every cleanup for
        // `watch-capture-` / `watch-stt-audio-` / `stt-json-body-` /
        // `conduck-watch-converse-body-` is in-process, watchOS jetsams a
        // backgrounded app aggressively mid-upload, and the user has no way to
        // inspect or clear a Watch's `tmp` themselves.
        //
        // Runs on EVERY process launch — including the background-URLSession
        // relaunches below, which are the wrist's usual way back into memory
        // after the very jetsam that stranded the file. `sweepInBackground` puts
        // the scan on a background executor (a plain `Task { }` here would only
        // DEFER it — this initializer is main-actor isolated and a `Task`
        // inherits that); safe to race a rehydrated upload because the 24 h age
        // floor sits orders of magnitude above any resource timeout.
        TempScratchSweeper.sweepInBackground()

        // Synchronous Keychain check (~<1ms) to pick the right initial view
        _hasIdentity = State(initialValue: WatchIdentityResolver.hasKeychainIdentity())

        // Synchronous App-Group read (~<1ms) — show the one-time welcome on the
        // very first launch. The gate in `body` additionally defers to a pending
        // capture, and the seen-flag is written only on the "Got it" tap.
        _showOnboarding = State(initialValue: !WatchSettingsReader.shared.hasSeenOnboarding())

        #if DEBUG
        // Screenshot capture (`-ConduckWatchQAScreenshotMode`): land DIRECTLY on
        // the launchpad. Skip the identity/setup gate (the unsigned sim may hold
        // no Keychain identity, which would strand the capture on `WatchSetupView`)
        // and the one-time welcome. Both overrides are DEBUG + flag-gated, so a
        // Debug build without the flag — and every Release build — is unaffected.
        if WatchScreenshotSeed.isActive {
            _hasIdentity = State(initialValue: true)
            _showOnboarding = State(initialValue: false)
        }
        #endif
    }

    /// Flip user turns stranded at `sending` past the store's grace to `failed`,
    /// excluding every conversation this wrist still holds a live background
    /// task for — that task's delegate will resolve its turn authoritatively,
    /// and the exclusion, not the grace, is what makes the sweep safe for turns
    /// this device owns.
    ///
    /// The grace is what covers the turns it CANNOT see: a `sending` row written
    /// by the iPhone or the Mac and arrived by CloudKit, whose in-flight task is
    /// invisible from here. That blindness is symmetric — the phone's launch
    /// sweep is equally blind to live Watch tasks — and the grace is chosen to
    /// exceed a real turn's duration plus sync skew by a wide margin.
    ///
    /// Best-effort and non-throwing: a launch or a background wake must never
    /// block on it.
    private static func sweepStaleWatchSends() async {
        let live = await WatchAudioUploader.shared.liveConversationIDs()
        await ConversationStore.shared.sweepStaleSendingUserTurns(
            excludingConversationIDs: live
        )
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if showOnboarding
                    && !WatchRecordingCoordinator.shared.pendingStart
                    && !WatchRecordingCoordinator.shared.isRecordingFlowActive {
                    // First launch: the one-time welcome takes precedence over the
                    // identity gate (immediate first impression + expectation set).
                    // Skipped when the app cold-launched into a capture — reading
                    // the @Observable coordinator here means a capture that arrives
                    // mid-welcome (Action Button) also wins and swaps this out.
                    WatchOnboardingView(onDone: {
                        WatchSettingsReader.shared.markOnboardingSeen()
                        WatchLog.note(.nav, "onboarding.dismissed")
                        showOnboarding = false
                    })
                } else if hasIdentity {
                    WatchNoteView()
                } else {
                    WatchSetupView()
                }
            }
            .task {
                // Non-blocking background identity resolution
                if let _ = await WatchIdentityResolver.shared.resolveInBackground() {
                    hasIdentity = true
                }
            }
            .task {
                // Defer notification permission until UI is interactive — and
                // skip entirely if a recording was triggered by intent or is
                // in flight, otherwise this prompt would collide with the
                // mic-permission prompt and one could auto-dismiss the other.
                // The user gets the prompt on a subsequent launch when no
                // recording flow is active.
                try? await Task.sleep(for: .seconds(2))
                let coordinator = WatchRecordingCoordinator.shared
                guard !coordinator.pendingStart, !coordinator.isRecordingFlowActive else { return }
                let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
                guard status == .notDetermined else { return }
                try? await UNUserNotificationCenter.current().requestAuthorization(
                    options: [.alert, .sound]
                )
            }
            .task {
                // Initial drain at launch — covers the case
                // where iPhone was reachable when entries were enqueued
                // but the Watch then crashed/suspended before the
                // reachability-flip drain in `WatchSessionManager` fired.
                // `drain()` self-guards against re-entry and short-circuits
                // on empty queue or unactivated WCSession.
                await AppleRelayPendingQueue.shared.drain()
            }
            .onReceive(NotificationCenter.default.publisher(for: .watchIdentityDidChange)) { _ in
                hasIdentity = true
            }
            .task {
                // Screenshot capture only (`-ConduckWatchQAScreenshotMode`): inject
                // two keyless gateways + seed marketing conversations so the wrist
                // lands configured + populated. No-op without the flag; DEBUG-only.
                #if DEBUG
                await WatchScreenshotSeed.seedIfNeeded()
                #endif
            }
        }
        .backgroundTask(.urlSession(WatchAudioUploader.sessionIdentifier)) {
            // System wakes the app when the background STT upload completes
            // (session identifier namespace + `.watch.stt`).
            // `handleBackgroundEvents` rehydrates the URLSession (reconnecting
            // pending tasks to the delegate — response parsing, the
            // audio-cleanup mandate, chaining the agent hop) and HOLDS the
            // handler open until the system reports all callbacks delivered
            // AND the chained persistence work (decode → user-turn append →
            // converse-task resume) has landed. Returning earlier raced a
            // suspend/kill against that window and could drop the turn —
            // formerly an interim 4 s grace sleep, now the real drain signal
            // (mirrors BackgroundRemoteAgent's drain-waiter shape).
            #if DEBUG
            print("[Watch] Background STT URLSession task completed (id: \(WatchAudioUploader.sessionIdentifier))")
            #endif
            await WatchAudioUploader.shared.handleBackgroundEvents(.stt)
            // A wake is the wrist's usual way back into memory after the jetsam
            // that stranded a turn, so recovery runs here as well as at launch —
            // AFTER the drain, so a turn this very wake just resolved is already
            // off `sending` and a task still running is still in `allTasks`.
            await Self.sweepStaleWatchSends()
        }
        .backgroundTask(.urlSession(WatchAudioUploader.converseSessionIdentifier)) {
            // System wakes the app when the agent converse upload completes
            // (session identifier namespace + `.watch.converse`).
            // Same drain bridge as the STT handler: held open through the
            // delegate's reply persistence (decode → appendMessage → pointer
            // bump → notification) instead of the former interim 4 s grace.
            #if DEBUG
            print("[Watch] Background converse URLSession task completed (id: \(WatchAudioUploader.converseSessionIdentifier))")
            #endif
            await WatchAudioUploader.shared.handleBackgroundEvents(.converse)
            // Same post-drain recovery as the STT wake above.
            await Self.sweepStaleWatchSends()
        }
    }
}
