// SPDX-License-Identifier: Apache-2.0

//
//  ConduckApp.swift
//  Conduck
//
//  Lifecycle wiring. Wires the iOS WindowGroup, NotificationDelegate (foreground
//  banners — required for the macOS Shortcuts-foregrounding pattern),
//  SettingsManager.performInitialSync, PendingRetryStore.cleanupExpired, and
//  PhoneSessionManager activation.
//

import SwiftUI
import UserNotifications
#if canImport(WatchConnectivity)
import WatchConnectivity
#endif

// MARK: - Notification Presentation Decider (pure, testable)

/// Pure decision function for foreground banner suppression. Extracted from
/// `NotificationDelegate.willPresent` so the matrix (matching id / mismatching
/// id / empty set / missing key / non-string value / unparseable UUID) can be
/// unit-tested without standing up a `UNUserNotification` mock.
enum NotificationPresentationDecider {
    /// Returns true when the delegate should suppress the banner because the
    /// user is already viewing the target conversation. Falls back to `false`
    /// (present the banner) on any missing/malformed payload — banner is the
    /// safer default than silent-drop.
    static func shouldSuppress(userInfo: [AnyHashable: Any],
                               viewedConversationIDs: Set<UUID>) -> Bool {
        guard let raw = userInfo[NotificationDeepLink.conversationIDKey] as? String,
              let id = UUID(uuidString: raw) else { return false }
        return viewedConversationIDs.contains(id)
    }
}

// MARK: - Reply Auto-Speak Decider (pure, testable)

/// Pure decision function for the iOS notification-tap auto-speak ("speak
/// the reply when opened from its notification"). Extracted from
/// `NotificationDelegate.didReceive` so the matrix (reply vs. failure
/// identifier / toggle off / live CarPlay session / missing key / non-string
/// value / unparseable UUID) can be unit-tested without standing up a
/// `UNNotificationResponse` mock.
enum ReplyAutoSpeakDecider {
    /// Returns the conversation whose latest agent reply should auto-speak, or
    /// nil to stay silent. Non-nil ONLY when ALL hold:
    ///  - `requestIdentifier` carries `NotificationDeepLink.replyIdentifierPrefix`.
    ///    Why load-bearing: FAILURE notifications (`remoteAgent.failure.<uuid>`)
    ///    ALSO carry a `conversationIDKey` for tap-to-retry — without the prefix
    ///    test, tapping a failure would speak a stale PREVIOUS reply.
    ///  - userInfo's `conversationIDKey` parses as a UUID,
    ///  - `toggleOn` (the device-local Settings preference, read at tap time via
    ///    `SettingsManager.speakReplyOnNotificationOpenAtTap()`), and
    ///  - `!carPlayActive` (`CarPlayRecordingService.anySessionActive`). Why: a
    ///    live CarPlay voice session holds the audio route across its whole
    ///    multi-turn lifecycle; an in-app auto-speak would fight it mid-drive.
    /// Falls back to nil (stay silent) on any missing/malformed payload —
    /// silence is the safer default than speaking into the wrong context.
    static func conversationIDForAutoSpeak(requestIdentifier: String,
                                           userInfo: [AnyHashable: Any],
                                           toggleOn: Bool,
                                           carPlayActive: Bool) -> UUID? {
        guard toggleOn,
              !carPlayActive,
              requestIdentifier.hasPrefix(NotificationDeepLink.replyIdentifierPrefix),
              let raw = userInfo[NotificationDeepLink.conversationIDKey] as? String,
              let id = UUID(uuidString: raw) else { return nil }
        return id
    }
}

// MARK: - Notification Delegate

/// Shows notifications as banners even when the app is in the foreground —
/// EXCEPT when the user is already viewing the target conversation thread
/// (delivery-time suppression via `ActiveViewTracker`).
///
/// Required on macOS where Shortcuts brings the app to the foreground to run
/// intents; iOS uses it to bubble-in-place instead of double-banner when the
/// reply lands on a thread the user is staring at.
///
/// `@MainActor`-isolated because the delegate reads the `@MainActor` static
/// `ActiveViewTracker.viewedConversationIDs`; without isolation the system
/// would invoke these methods on arbitrary queues and trigger Swift 6 strict-
/// concurrency violations.
@MainActor
private final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        let userInfo = notification.request.content.userInfo
        Task { @MainActor in
            #if DEBUG
            print("🔔 willPresent notification: \(notification.request.content.title)")
            #endif
            let suppress = NotificationPresentationDecider.shouldSuppress(
                userInfo: userInfo,
                viewedConversationIDs: ActiveViewTracker.viewedConversationIDs
            )
            // SILENT banner in the foreground. This delegate only runs while the
            // app is frontmost, so the user is already here — a chime is
            // redundant noise on top of a banner they can see. `.list` keeps the
            // notification retrievable in Notification Center afterwards, which
            // a bare `.banner` does not.
            completionHandler(suppress ? [] : [.banner, .list])
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        #if DEBUG
        print("🔔 didReceive notification tap: \(response.notification.request.identifier)")
        #endif
        // A reply-notification tap carries the target conversationID in
        // userInfo. Re-post on the in-app deep-link bus so RootView/ContentView
        // foregrounds + opens that thread (local fetch by ID; no URL scheme).
        let userInfo = response.notification.request.content.userInfo
        if let idString = userInfo[NotificationDeepLink.conversationIDKey] as? String {
            let requestIdentifier = response.notification.request.identifier
            // Retire the WHOLE conversation's banners, not just the tapped one.
            // The OS removes only the notification actually tapped, so a failure
            // banner sitting beside the reply banner for the same thread would
            // survive the user opening that thread.
            if let id = UUID(uuidString: idString) {
                NotificationDeepLink.clearDelivered(for: id)
            }
            DispatchQueue.main.async {
                #if !os(macOS)
                // Read-aloud (iOS/iPadOS only — macOS deep-links must NEVER
                // speak; the macOS read-aloud surface is the quick-lane arrival
                // toggle, not notification taps). Stage the auto-speak request
                // BEFORE the deep-link post: a thread host already mounted on
                // this conversation reacts to the post on this same main-thread
                // turn, so set-then-post ordering is what kills the
                // consume-before-set race. `assumeIsolated` is sound — this
                // closure runs on the main queue, and both the CarPlay flag and
                // the coordinator are `@MainActor`.
                MainActor.assumeIsolated {
                    if let target = ReplyAutoSpeakDecider.conversationIDForAutoSpeak(
                        requestIdentifier: requestIdentifier,
                        userInfo: userInfo,
                        toggleOn: SettingsManager.speakReplyOnNotificationOpenAtTap(),
                        carPlayActive: CarPlayRecordingService.anySessionActive
                    ) {
                        AutoSpeakMailbox.shared.request(target)
                    }
                }
                #endif
                NotificationCenter.default.post(
                    name: .openConversationDeepLink,
                    object: nil,
                    userInfo: [NotificationDeepLink.conversationIDKey: idString]
                )
            }
        }
        // Share Extension SUCCESS confirmation: the appex's "Shared to Conduck"
        // notification carries `shareEnvelopeID`. Tapping it should land the user
        // in the chat their share went to: drain THAT one envelope and deep-link
        // to the resolved/minted conversation. The actor serializes this against
        // the foreground `drain()`; idempotency holds via `manifest.uuid ==
        // Message.id`, so a concurrent drain never double-sends. (Share FAILURE
        // notifications carry the `conversationIDKey` instead — handled by the
        // deep-link branch above: a real UUID opens the failed turn's thread, an
        // empty string no-ops to foreground for a no-turn failure.)
        // A default-needs-setup notification carries no thread — the refusal
        // happened before any conversation existed. Its only useful destination
        // is the screen where the default is chosen, so arm the fix route and
        // let the app roots consume it. `GatewayFixRoute` is in-memory and
        // one-shot: a request that outlived the process and reopened Settings
        // days later would be a surprise. `assumeIsolated` is sound for the same
        // reason the auto-speak block above gives — the closure runs on the main
        // queue and `GatewayFixRoute` is `@MainActor`.
        if userInfo[NotificationDeepLink.openPersonalAIKey] != nil {
            DispatchQueue.main.async {
                MainActor.assumeIsolated { GatewayFixRoute.request() }
            }
        }
        if let envelopeID = userInfo[SharedInboxDrainer.shareEnvelopeIDKey] as? String {
            Task {
                let conversationID = await SharedInboxDrainer.shared.drainAndResolve(envelopeID: envelopeID)
                if let conversationID {
                    await MainActor.run {
                        NotificationCenter.default.post(
                            name: .openConversationDeepLink,
                            object: nil,
                            userInfo: [NotificationDeepLink.conversationIDKey: conversationID.uuidString]
                        )
                    }
                }
            }
        }
        completionHandler()
    }
}

// MARK: - macOS App (placeholder)

#if os(macOS)

@main
struct ConduckApp: App {
    // AppDelegate owns the menu-bar surface (NSStatusItem + MenuBarController
    // + DictationService) and all init-time tasks (performInitialSync,
    // cleanupExpired, onboarding-gate post). ConduckApp.macOS only owns the
    // Window scenes that AppDelegate's NotificationCenter posts open via
    // openWindow(id:). Launch sequence: `applicationWillFinishLaunching` forces
    // `.accessory` (so `main`'s `.automatic` scene mounts WITHOUT auto-opening a
    // window), then `applicationDidFinishLaunching` applies `.regular`
    // PERMANENTLY when "Show in Dock" is ON — Dock icon + top menu present from
    // launch, still with NO window auto-opened and NO focus steal. OFF → stays
    // `.accessory` (menu-bar-only). `main` keeps the default `.automatic` launch
    // behavior so under the launch `.accessory` policy it does NOT auto-foreground
    // — it opens on demand from the duck (which posts .openConversationsWindow).
    // The app persists after its window closes
    // (applicationShouldTerminateAfterLastWindowClosed → false in AppDelegate),
    // so the menu-bar item survives a closed window. Re-open `main` via the Dock
    // icon (applicationShouldHandleReopen) or the menu bar / popover.
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    private let notificationDelegate = NotificationDelegate()

    init() {
        // Foreground banner delegate stays App-scope (shared with iOS branch
        // posture); AppDelegate owns the rest of the init wiring on macOS.
        UNUserNotificationCenter.current().delegate = notificationDelegate

        // TTS key-arrival monitor — bounded foreground Keychain re-check that
        // converges a Mac still waiting on an iCloud-Keychain-synced voice key
        // (key arrival has NO OS notification). Observers only; the first
        // didBecomeActive performs the initial evaluation. Mirrors the iOS
        // init's wiring (the two App structs share no init code).
        Task { @MainActor in
            KeyArrivalMonitors.startAll()
        }

        // Stale-"sending" recovery sweep: macOS sends are FOREGROUND URLSession
        // — quitting the app mid-turn kills them with no background delegate to
        // ever flip the user turn off `sending`, so without this the bubble
        // spins forever and the Retry chip (which requires `failed`) never
        // appears. No live-task exclusion needed (no background converse
        // session exists on macOS); the 30-min grace window is documented on
        // the store method (covers cross-device CloudKit-synced in-flight turns).
        //
        // One-shot delayed RE-SWEEP (grace + 1 min): the launch sweep alone
        // can't heal a quit-mid-turn followed by a relaunch WITHIN the grace
        // window — the stranded turn isn't 30 min old yet at launch, and the
        // menu-bar app then runs for days without another launch. The re-sweep
        // catches it once it ages past the grace. Best-effort; cheap (one
        // fetch).
        Task {
            await ConversationStore.shared.sweepStaleSendingUserTurns()
            try? await Task.sleep(for: .seconds(31 * 60))
            await ConversationStore.shared.sweepStaleSendingUserTurns()
        }
    }

    var body: some Scene {
        // Unified main window (the Claude-desktop shell): one Window hosting a
        // NavigationSplitView (New-conversation + gateway picker + conversation
        // list + identity footer) with Settings as a full-window mode swap
        // (`MacSettingsView` replaces the split view), not a sheet and not a
        // separate Window. Bound to the AppDelegate's
        // long-lived MenuBarCoordinator so it shares the popover's active VM
        // (live in-flight indicator) + DictationService (mic). `Window` is a
        // singleton → `openWindow(id:"main")` re-foregrounds, never duplicates.
        // Opened via the menu-bar context menu / popover affordance (both post
        // .openConversationsWindow) or a reply-notification tap
        // (.openConversationDeepLink → opens window + selects the thread).
        Window("Conduck", id: "main") {
            MainWindowView(coordinator: appDelegate.coordinator)
                .frame(minWidth: 880, minHeight: 600)
                .onReceive(NotificationCenter.default.publisher(for: .openOnboardingWindow)) { _ in
                    openWindow(id: "onboarding")
                }
                .onReceive(NotificationCenter.default.publisher(for: .openConversationsWindow)) { _ in
                    openWindow(id: "main")
                }
                .onReceive(NotificationCenter.default.publisher(for: .openConversationDeepLink)) { _ in
                    // Foreground the window when a reply-notification is tapped.
                    openWindow(id: "main")
                }
                .onReceive(NotificationCenter.default.publisher(for: .openGatewayFixRoute)) { _ in
                    // The Mac launches quiet (`.accessory`), so the window may
                    // not exist when the notification is tapped. Open it; the
                    // view layer consumes the route and navigates to
                    // Settings → Personal AI.
                    openWindow(id: "main")
                }
        }
        .defaultSize(width: 1100, height: 760)
        .defaultPosition(.center)
        .windowResizability(.contentMinSize)
        .windowToolbarStyle(.unified)
        // The app now has a real top menu bar (regular Dock app). These commands
        // extend it: TextEditingCommands routes ⌘A/⌘C/⌘V/⌘X to the composer
        // TextField + thread, and the two CommandGroups add ⌘, (Settings) and
        // ⌘N (New Conversation) — both reopen `main` and drive the same
        // NotificationCenter bus the menu-bar surface uses.
        .commands {
            TextEditingCommands()
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    appDelegate.coordinator.pendingSettingsCategory = nil
                    appDelegate.coordinator.pendingDiagnosticsFocus = nil   // root open: never a diagnostics deep-link
                    appDelegate.coordinator.pendingShowSettings = true
                    openWindow(id: "main")
                    NotificationCenter.default.post(name: .openSettingsWindow, object: nil)
                }
                .keyboardShortcut(",", modifiers: .command)
            }
            CommandGroup(replacing: .newItem) {
                Button("New Conversation") {
                    openWindow(id: "main")
                    NotificationCenter.default.post(name: .newConversation, object: nil)
                }
                .keyboardShortcut("n", modifiers: .command)
            }
        }
        // No `.defaultLaunchBehavior(.presented)` — under Option A launch is
        // always `.accessory` (quiet), so the default `.automatic` instantiates
        // the `main` scene's content (keeping its `.onReceive` subscribers alive
        // to catch .openConversationsWindow from the duck) WITHOUT foregrounding
        // the window. `.presented` would force `main` open at launch, breaking the
        // quiet menu-bar-utility experience. The window foregrounds (and the app
        // promotes to a Dock icon) only when opened on demand.

        // Onboarding window — auto-shown on first launch by AppDelegate
        // (posts .openOnboardingWindow if SettingsManager.hasCompletedOnboarding() is false).
        // Scene-based gate (NOT iOS RootView conditional — macOS Window semantics
        // are clean; iOS-specific .fullScreenCover init-true trap doesn't apply).
        Window("Conduck", id: "onboarding") {
            OnboardingContainerView(onComplete: {
                // Option A: launch is quiet, so after first-run onboarding the
                // `main` window is NOT already showing — opening it here lands the
                // user in the app instead of leaving just the menu-bar duck.
                // Posting `.openConversationsWindow` drives `main`'s `.onReceive`
                // (open). The Dock icon (if "Show in Dock" is ON) was already
                // applied at launch in `AppDelegate.didFinishLaunching`; opening a
                // window does not change the activation policy. Passing this
                // `onComplete` REPLACES the view's
                // internal `dismiss()`, so we must close the onboarding window
                // ourselves via `dismissWindow(id:)`.
                NotificationCenter.default.post(name: .openConversationsWindow, object: nil)
                dismissWindow(id: "onboarding")
            })
                .frame(minWidth: 600, minHeight: 650)
                .preferredColorScheme(.dark)
                .onReceive(NotificationCenter.default.publisher(for: .openSettingsWindow)) { _ in
                    // Settings is a sheet on the main window now. Raise the
                    // deferred-present flag before opening so MainWindowView.onAppear
                    // shows the sheet even though it isn't yet mounted to catch the
                    // live .openSettingsWindow bus.
                    appDelegate.coordinator.pendingDiagnosticsFocus = nil   // onboarding→root open: never a diagnostics deep-link
                    appDelegate.coordinator.pendingShowSettings = true
                    openWindow(id: "main")
                }
        }
        .defaultSize(width: 600, height: 650)
        .defaultPosition(.center)
        .windowToolbarStyle(.unifiedCompact(showsTitle: true))
        // `.automatic` (NOT `.suppressed`) — mirrors the `main` window: the launch
        // `.accessory` policy (forced in AppDelegate.applicationWillFinishLaunching)
        // keeps an `.automatic` Window instantiated-but-NOT-foregrounded at launch,
        // so onboarding does NOT auto-present, yet `openWindow(id: "onboarding")`
        // can foreground it ON DEMAND. `.suppressed` looked equivalent but is NOT:
        // a suppressed Window is never *created* at launch, and `openWindow` cannot
        // create-and-show it while the app is a background `.accessory` — so the
        // first-run / `-ConduckShowOnboarding` open was a silent no-op (verified
        // 2026-06-20). `.restorationBehavior(.disabled)` stops macOS restoring a
        // stale onboarding window on relaunch (which would trap the user back in
        // setup). Both are macOS 15+ APIs.
        .restorationBehavior(.disabled)
    }
}

// MARK: - iOS / iPadOS App

#else

@main
struct ConduckApp: App {
    private let notificationDelegate = NotificationDelegate()
    /// Owns the share-targets snapshot regeneration observers for the app's
    /// lifetime (gateway/conversation changes → rewrite the appex picker's
    /// `share-targets.json`). Held as a stored property so its `NotificationCenter`
    /// observers aren't deallocated.
    private let shareTargetsObserver = ShareTargetsSnapshotObserver()

    init() {
        // 0. Share Extension snapshot. Write the initial "Send to" targets
        //    snapshot the appex picker reads, and start the change observers that
        //    keep it fresh.
        Task {
            await ShareTargetsSnapshotWriter.shared.regenerate()
        }
        shareTargetsObserver.start()

        // 1. iCloud KVS pull on first launch of a second device (identity +
        //    `stt.preferredLanguage` only — trimmed per Plan Q7D). The silent
        //    capability refresh (folder + return) chains AFTER it in the SAME
        //    task — it reads file-server flags this initial sync may have just
        //    hydrated.
        Task {
            await SettingsManager.shared.performInitialSync()
            await FileTransferCapabilityRefresher.refreshIfNeeded()
        }

        // 2. Privacy hygiene. Two independent reclaims, deliberately NOT chained
        //    into one task — they touch different containers, so nothing here
        //    orders against anything else:
        //      • pending retry audio older than 10 min (App Group storage) and
        //        aged Quick Look scratch downloads (>24 h). Both are actor
        //        methods, so both already run off the main actor.
        //      • orphaned capture audio / request bodies an abnormal termination
        //        left in `temporaryDirectory` (see TempScratchSweeper). Its
        //        `sweepInBackground` entry point owns the off-main guarantee: a
        //        plain `Task { }` here would only DEFER that shared-directory
        //        scan, because a Task created from this main-actor init inherits
        //        the same isolation.
        Task {
            await PendingRetryStore.shared.cleanupExpired()
            await AgentDownloadScratch.shared.sweep()
        }
        TempScratchSweeper.sweepInBackground()

        // 3. WatchConnectivity iPhone → Watch broadcast (identity + STT settings).
        #if canImport(WatchConnectivity)
        if WCSession.isSupported() {
            PhoneSessionManager.shared.activate()
        }
        #endif

        // 3b. TTS key-arrival monitor — bounded foreground Keychain re-check
        //     that converges a device still waiting on an iCloud-Keychain-
        //     synced voice key (key arrival has NO OS notification). Observers
        //     only; the first didBecomeActive performs the initial evaluation.
        //     Both platforms (macOS runs this same init).
        Task { @MainActor in
            KeyArrivalMonitors.startAll()
        }

        // 4. Foreground banner delegate (single registration point).
        UNUserNotificationCenter.current().delegate = notificationDelegate

        // 5. CarPlay settings cache — populate STT key + language hint at launch
        //    so the CarPlay scene reads from a main-actor cache instead of
        //    re-entering SettingsManager mid-turn (Keychain reads from CarPlay
        //    scene context have caused intermittent HFP-route-negotiation
        //    stalls). Refreshed on each app launch + SettingsManager
        //    change-observer fan-out (CarPlaySettings.refreshFromSettings).
        Task { @MainActor in
            await CarPlaySettings.shared.refreshFromSettings()
        }

        // 6. Stale-"sending" recovery sweep. A force-quit (or a crash) can
        //    strand a user turn at `sending` with no delegate left to resolve
        //    it — and the Retry chip requires `failed`. Flip stale turns
        //    (30-min grace, documented on the store method), EXCLUDING any
        //    conversation that still has a LIVE converse task on either
        //    background session (its delegate will resolve the turn
        //    authoritatively when the task completes). Touching the session
        //    singletons here also re-attaches their delegates early, which
        //    drains any pending completions from a prior process.
        //    One-shot delayed RE-SWEEP (grace + 1 min): a force-quit followed
        //    by a relaunch WITHIN the grace window leaves the stranded turn
        //    too young for the launch sweep; if the app then stays alive
        //    (foreground use), nothing else would heal it until the NEXT
        //    launch. Best-effort — iOS may suspend the process first (the
        //    sleep completes on resume if the deadline passed), in which case
        //    the next launch's sweep still owns it. Live tasks re-collected at
        //    re-sweep time (the original set is stale by then).
        Task {
            let liveConverse = await BackgroundRemoteAgent.shared.liveConversationIDs()
            let liveCarPlay = await CarPlayConverseUploader.shared.liveConversationIDs()
            await ConversationStore.shared.sweepStaleSendingUserTurns(
                excludingConversationIDs: liveConverse.union(liveCarPlay)
            )
            try? await Task.sleep(for: .seconds(31 * 60))
            let liveConverse2 = await BackgroundRemoteAgent.shared.liveConversationIDs()
            let liveCarPlay2 = await CarPlayConverseUploader.shared.liveConversationIDs()
            await ConversationStore.shared.sweepStaleSendingUserTurns(
                excludingConversationIDs: liveConverse2.union(liveCarPlay2)
            )
        }

        // 6b. Local in-flight liveness probes. The registry answers "is a turn
        //     for this conversation running RIGHT NOW, on THIS device, and can I
        //     stop it?" — which `Message.status == "sending"` cannot, because a
        //     `sending` row may have been written by another device and mirrored
        //     here. The two background sessions above already know the answer;
        //     these hand it to the registry.
        //
        //     CANCELLABILITY IS DECLARED HERE, at the site that knows which
        //     session it is wiring — a probe returning only `Set<UUID>` cannot
        //     carry it. A CarPlay upload is NOT cancellable through
        //     `BackgroundRemoteAgent.cancel`, so marking it cancellable would
        //     light a Stop button that does nothing.
        InFlightTurnRegistry.shared.addProbe(lane: .backgroundConverse, isCancellable: true) {
            await BackgroundRemoteAgent.shared.liveConversationIDs()
        }
        InFlightTurnRegistry.shared.addProbe(lane: .carPlay, isCancellable: false) {
            await CarPlayConverseUploader.shared.liveConversationIDs()
        }

        // 6c. Stamp this device's first sight of the unviewed-reply feature.
        //     HERE, in deterministic app init — never from a SwiftUI `body`.
        //     A body-stamped epoch both creates state during rendering and races
        //     the CloudKit import: a reply that imported at 10:00 would be
        //     classified as already-read because the first row happened to
        //     render at 10:01. Idempotent after the first launch.
        ReadStateStore.shared.stampEpochIfNeeded()

        // 7. Warm the conversation store at launch so NSPersistentCloudKitContainer
        //    starts mirroring immediately, rather than lazily when the list first
        //    appears — the earlier the stack loads, the sooner cross-device sync
        //    begins (mirrors the watchOS warm-up). Then start the SILENT iCloud-
        //    sync monitor (telemetry + the one user-actionable "iCloud unavailable"
        //    signal; no visible chrome otherwise).
        Task { await ConversationStore.shared.warmUp() }
        Task { @MainActor in CloudSyncMonitor.shared.start() }

        #if DEBUG
        print("🔔 NotificationDelegate set in ConduckApp.init()")
        #endif
    }

    var body: some Scene {
        WindowGroup {
            // In Release this compiles to exactly `RootView().preferredColorScheme(.dark)`
            // — byte-identical to a clean build. The QA banner is attached only in
            // DEBUG, and even then as a layout-neutral empty inset until `isActive`,
            // so a Debug ⌘R without `-ConduckQAMode` is visually unchanged.
            RootView()
                .preferredColorScheme(.dark)
                #if DEBUG
                .safeAreaInset(edge: .top) {
                    if QAMode.showsBanner {
                        QABanner()
                    }
                }
                #endif
        }
        // STT background URLSession — identifier single-sourced from
        // `BackgroundSTT.sessionIdentifier` (identity namespace + `.stt`).
        .backgroundTask(.urlSession(BackgroundSTT.sessionIdentifier)) {
            // Bridge system-relaunch events into the BackgroundSTT
            // singleton. Touching the session re-attaches our URLSessionDelegate,
            // which drains pending didCompleteWithError callbacks (including
            // the audio-cleanup defer). The call AWAITS until the delegate's
            // `urlSessionDidFinishEvents` fires — returning earlier let the
            // system suspend/kill the process mid-drain.
            await BackgroundSTT.shared.handleBackgroundEvents()
        }
        // Agent converse hop. Distinct identifier from `.stt` so delivery
        // never crosses talk. Re-materializing the session drains pending
        // converse completions — appends the agent reply to the store + fires
        // the reply notification (body-file cleanup). The call
        // AWAITS until the events drain AND the reply persistence completes
        // (the delegate signals after the store append, not merely after
        // didFinishEvents) — the await-until-done contract that prevents
        // silent reply loss on suspend/kill.
        .backgroundTask(.urlSession(Constants.remoteAgentConverseSessionIdentifier)) {
            await BackgroundRemoteAgent.shared.handleBackgroundEvents()
        }
        // CarPlay agent converse hop. A SECOND converse background session
        // (distinct identifier from the iOS `.converse` one) so CarPlay-turn
        // deliveries never cross-talk with iOS-thread deliveries. Re-materializing
        // the session drains pending CarPlay converse completions — appends the
        // agent reply to the store + routes it to speak-or-sync.
        // Same await-until-persisted contract as the `.converse` handler above.
        .backgroundTask(.urlSession(Constants.remoteAgentCarPlayConverseSessionIdentifier)) {
            await CarPlayConverseUploader.shared.handleBackgroundEvents()
        }
        // File transfer: agent file-server upload/download hop. A FOURTH
        // distinct background session (id `Constants.fileTransferSessionIdentifier`)
        // so multi-MB PUT/GET deliveries never cross-talk with the converse
        // sessions and survive app suspension. Bridges the system-relaunch
        // completion handler into BackgroundFileTransfer so its delegate can
        // drain pending upload/download completions (progress + body-file
        // cleanup) and resolve any awaiting send.
        .backgroundTask(.urlSession(Constants.fileTransferSessionIdentifier)) {
            await withCheckedContinuation { continuation in
                BackgroundFileTransfer.shared.handleBackgroundSessionEvents {
                    continuation.resume()
                }
            }
        }
    }
}

#endif
