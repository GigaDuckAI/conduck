// SPDX-License-Identifier: Apache-2.0

#if os(macOS)
// Conduck
// AppDelegate.swift
//
// macOS-agent — `NSApplicationDelegate` for the menu-bar surface. Owns the
// long-lived `MenuBarCoordinator` (owns the `DictationService`):
// the coordinator holds the `DictationService` + the active
// `ConversationDetailViewModel`, so the in-flight foreground agent `Task`
// survives popover teardown during the multi-minute wait.
//
// Wiring contract for `ConduckApp.swift` macOS branch (unified shell):
//   - `@NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate`
//   - `Window("Conduck", id: "main") { MainWindowView(coordinator: appDelegate.coordinator) }`
//     — the single Claude-desktop shell: NavigationSplitView (New + gateway
//     picker + conversation list + identity footer) with Settings as a
//     full-window mode swap (`MacSettingsView` replaces the split view), NOT a
//     sheet and NOT its own window.
//   - `Window("Conduck", id: "onboarding") { OnboardingContainerView(onComplete:) }`
//     — the onComplete posts `.openConversationsWindow` + dismisses the
//       onboarding window so first-run lands in the app (launch is quiet now).
//   - `.onReceive(.openOnboardingWindow / .openConversationsWindow /
//     .openConversationDeepLink)` → `openWindow(id:)` (Settings is posted on
//     `.openSettingsWindow` and consumed by MainWindowView's mode swap, not a window).
//   - `@Environment(\.openWindow) private var openWindow` at App scope.

import AppKit
import SwiftUI

/// macOS AppDelegate for menu bar setup and lifecycle management.
/// Conduck ALWAYS runs a menu-bar `NSStatusItem` duck (policy-independent). The
/// "Show in Dock" preference governs whether it ALSO shows a Dock icon + top
/// application menu (`.regular`) or stays a pure menu-bar utility (`.accessory`).
/// When ON (default), the Dock icon appears AT LAUNCH and stays (permanent),
/// independent of whether any window is open — applied in
/// `applicationDidFinishLaunching` WITHOUT opening a window or stealing focus.
/// When OFF, it stays `.accessory` forever. The SwiftUI `Window` scenes are
/// driven via `openWindow(id:)` — `"main"` and `"onboarding"` open on demand.
/// Settings is a `.sheet` on `"main"`, not a window.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Long-lived owner of `DictationService` + the active conversation VM.
    /// Exposed so `Conduck`'s `Window("main")` scene can bind to the
    /// same coordinator the popover uses. **Constructed EAGERLY** (not in
    /// `applicationDidFinishLaunching`): SwiftUI evaluates the `main`
    /// scene content — `MainWindowView(coordinator: appDelegate.coordinator)`
    /// — at launch, before `applicationDidFinishLaunching` runs, and
    /// `@NSApplicationDelegateAdaptor` is not observable, so a deferred/nil value
    /// would crash on force-unwrap (and never self-heal). An eager `let` is
    /// always valid whenever any scene reads it. The coordinator builds no
    /// AppKit UI in its init (just DictationService + observers); the
    /// `NSStatusItem` is still set up in `applicationDidFinishLaunching`.
    let coordinator = MenuBarCoordinator()
    private var menuBarController: MenuBarController?

    /// Owns the share-targets snapshot regeneration observers for the app's
    /// lifetime (gateway/conversation changes → rewrite the macOS share
    /// extension picker's `share-targets.json`). Held as a stored property so its
    /// `NotificationCenter` observers aren't deallocated. Mirrors the iOS
    /// `ConduckApp.shareTargetsObserver`.
    private let shareTargetsObserver = ShareTargetsSnapshotObserver()

    /// Watches the App-Group share inbox dir and drains the instant the macOS
    /// appex publishes — so a share made while this menu-bar app is INACTIVE
    /// processes without a menu-bar click. Owned for the app lifetime. See
    /// `ShareInboxWatcher` for why this is a file-system watch, not a Darwin wake.
    private let shareInboxWatcher = ShareInboxWatcher()

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Force `.accessory` here (before the scene graph mounts) so `main`'s
        // `.automatic` Window is instantiated-but-NOT-foregrounded — i.e. no
        // window auto-opens at launch, while its `.onReceive` subscribers stay
        // alive so the duck can open it on demand. The Dock icon (when "Show in
        // Dock" is ON) is added a moment later in `applicationDidFinishLaunching`,
        // AFTER the scene's no-present decision is locked — setting `.regular`
        // there does NOT retroactively open `main`. We must NOT set `.regular`
        // here: under `.regular`, `.automatic` would auto-open a window at launch.
        NSApp.setActivationPolicy(.accessory)
    }

    /// Apply the "Show in Dock" preference to the live app. `.regular` = Dock
    /// icon + top application menu + `NSStatusItem` duck; `.accessory` = no Dock
    /// icon / app menu, but the duck (and any open window) stay. This activation
    /// policy is the ONLY lever for Dock-icon + app-menu presence (macOS couples
    /// them); `LSUIElement` in Info.plist is left `false` and overridden here at
    /// runtime. This is the LIVE-toggle path (Settings → General OR the menu-bar
    /// menu item); the launch-time application lives in
    /// `applicationDidFinishLaunching`.
    func applyDockVisibility(_ show: Bool) {
        // Defer to the next run-loop tick: callers invoke this synchronously from
        // a SwiftUI `Toggle` `set` closure (Settings is a `.sheet` on `main`).
        // Mutating the activation policy mid-update rebuilds the global menu bar +
        // responder chain inside an active layout pass — AppKit logs "It's not
        // legal to call -layoutSubtreeIfNeeded … already being laid out" and the
        // change is silently dropped. Running it after SwiftUI settles is the fix.
        // Mirrors the `DispatchQueue.main.async` deferral in `MenuBarController`.
        DispatchQueue.main.async {
            NSApp.setActivationPolicy(show ? .regular : .accessory)
            if show {
                // `.accessory` → `.regular` is reliable; activate so the restored
                // Dock icon + top app menu come forward (AppKit does not
                // auto-foreground on a bare policy change).
                NSApp.activate(ignoringOtherApps: true)
            } else {
                // `.regular` → `.accessory` while the app is frontmost with a
                // visible key window leaves the Dock tile cached by the
                // WindowServer until the app next loses focus (reads as "nothing
                // happened"). Force an immediate drop with a hide → unhide cycle
                // that preserves the open window / sheet (capture it first —
                // `mainWindow` can go nil across the hide).
                let frontWindow = NSApp.keyWindow ?? NSApp.mainWindow
                NSApp.hide(nil)
                DispatchQueue.main.async {
                    NSApp.unhideWithoutActivation()
                    frontWindow?.makeKeyAndOrderFront(nil)
                }
            }
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // macOS 26 titlebar-glass mis-layout workaround (the mid-window band):
        // detect-and-correct sweeps after launch + window closes. No-op when
        // nothing is misplaced. See `TitlebarBandRepair`.
        TitlebarBandRepair.activate()

        #if DEBUG
        // Forensic capture for the macOS 26 stale scroll-edge band — no-op
        // without `-ConduckDumpHierarchy`. See `DebugHierarchyDump`.
        DebugHierarchyDump.scheduleIfRequested()
        #endif

        // Build the menu-bar UI subsystem (NSStatusItem + popover + global
        // shortcut) against the eagerly-constructed coordinator.
        let controller = MenuBarController(coordinator: coordinator)
        controller.setup()
        self.menuBarController = controller

        // "Show in Dock" ON → promote to a Dock app at launch (PERMANENT): Dock
        // icon + top app menu appear with NO window and NO focus grab (deliberately
        // no `NSApp.activate`). OFF → stay `.accessory` (menu-bar duck only).
        // Setting `.regular` here — AFTER the scene's no-present decision is locked
        // under the launch `.accessory` policy (see `applicationWillFinishLaunching`)
        // — does NOT retroactively open `main`. Foregrounding on a deliberate
        // window-open is handled by the call sites' own `NSApp.activate(...)`
        // (`MenuBarController.openConversationsWindow()` / `openSettings()` /
        // `applicationShouldHandleReopen`). Reads the synchronous launch-path pref
        // (no actor hop). The live toggle uses `applyDockVisibility(_:)`.
        if SettingsManager.showDockIconAtLaunch() {
            NSApp.setActivationPolicy(.regular)
        }

        // App startup tasks — mirror ConduckApp iOS branch ordering.
        // Share Extension snapshot: write the initial "Send to" targets snapshot
        // the macOS share extension picker reads, and start the change observers
        // that keep it fresh (gateway/conversation edits → rewrite). Mirrors the
        // iOS `ConduckApp.init` wiring.
        Task { await ShareTargetsSnapshotWriter.shared.regenerate() }
        shareTargetsObserver.start()

        // Share Extension WAKE (macOS): watch the App-Group inbox dir so a share
        // QUEUED while this menu-bar app is INACTIVE drains IMMEDIATELY — the watch
        // fires on the appex's publish (a durable on-disk event), independent of
        // app-active state / App Nap. Without it the drain only ran on
        // `applicationDidBecomeActive`, so a background share never processed until
        // the user clicked the menu-bar icon. Plus a cold-start drain for any
        // envelope queued while the app was fully quit (an accessory app may not
        // fire `didBecomeActive` at launch with no window). Both are no-ops on an
        // empty inbox; the actor serializes against the active-drain hook.
        shareInboxWatcher.start()
        Task { await SharedInboxDrainer.shared.drain(trigger: .launch) }
        // Initial sync, then the silent folder-capability refresh in the SAME
        // task (it reads file-server flags the sync may have just hydrated).
        Task {
            await SettingsManager.shared.performInitialSync()
            await FileTransferCapabilityRefresher.refreshIfNeeded()
        }
        // Privacy hygiene: expired retry audio + aged Quick Look scratch
        // downloads (>24 h — never on panel close, see AgentDownloadScratch).
        Task {
            await PendingRetryStore.shared.cleanupExpired()
            await AgentDownloadScratch.shared.sweep()
        }
        // Orphaned capture audio / request bodies an abnormal termination left in
        // `temporaryDirectory` (see TempScratchSweeper). Its own detached task,
        // NOT chained onto the one above: nothing orders against it (different
        // containers), and the shared-temp scan must not sit on a main-actor task.
        TempScratchSweeper.sweepInBackground()
        // One-time title-snippet backfill for EXISTING conversations (the iOS
        // `RootView.task` seam doesn't run on a Mac-only install). Idempotent via
        // an App-Group flag; the iOS branch guards the same way.
        Task { await ConversationStore.shared.backfillTitleSnippetsIfNeeded() }

        #if DEBUG
        // macOS mirror of the iOS `RootView.task` QA seed seam (RootView never
        // mounts on a Mac-only install, so without this a QA/screenshot launch
        // shows an empty list — screenshot mode's store is isolated in-memory
        // and starts empty by design). Ordering vs. the list's first fetch is
        // not load-bearing: every seeded write posts `.conversationsDidChange`,
        // which refreshes `ConversationListViewModel`.
        if QAMode.isActive {
            Task { await QAMode.seedConversationsIfNeeded() }
        }
        #endif

        // Warm the store at launch so NSPersistentCloudKitContainer starts
        // mirroring immediately (not lazily on first list appearance), then start
        // the SILENT iCloud-sync monitor (telemetry + the lone user-actionable
        // "iCloud unavailable" signal; no visible chrome otherwise). Mirrors the
        // iOS `ConduckApp.init` wiring.
        Task { await ConversationStore.shared.warmUp() }
        CloudSyncMonitor.shared.start()

        // Show onboarding on first launch. The 500 ms delay gives the
        // SwiftUI scene graph time to mount `.onReceive` subscribers in
        // `ConduckApp` before the notification fires.
        Task {
            let completed = await SettingsManager.shared.hasCompletedOnboarding()
            var shouldShow = !completed
            #if DEBUG
            // Mirror RootView.init() precedence (iOS). Explicit skip intents win
            // over the ambient dev flag so an automated QA launch is never trapped
            // on macOS first-run (this is also where macOS finally honors QAMode's
            // onboarding skip — the gate previously ignored it):
            //   QAMode / `-ConduckSkipOnboarding` → skip (override persisted flag)
            //   `-ConduckShowOnboarding`          → force-show, only if neither skip set
            // All read-only (no UserDefaults write).
            if QAMode.isActive || DebugFlags.skipOnboarding {
                shouldShow = false
            } else if DebugFlags.alwaysShowOnboarding {
                shouldShow = true
            }
            #endif
            if shouldShow {
                try? await Task.sleep(for: .milliseconds(500))
                await MainActor.run {
                    NSApp.activate(ignoringOtherApps: true)
                    NotificationCenter.default.post(name: .openOnboardingWindow, object: nil)
                }
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // The app is a real Dock app that stays running after the window closes so
        // the Dock icon + menu-bar item persist (click the Dock icon to reopen).
        false
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        // Share Extension drain hook (macOS). The drainer claims any published
        // envelopes the share extension queued and runs the real classify →
        // (upload) → append → assemble → dispatch work in-app. Foreground = the
        // App-Group container is unlocked, so `.completeFileProtection` reads
        // succeed. The actor serializes concurrent drains; an empty inbox is a
        // cheap no-op. Mirrors the iOS `ContentView.refreshOnForeground()` hook.
        // The inbox watch (see `shareInboxWatcher`) already drains a share queued
        // while inactive; this remains the belt-and-suspenders activation drain.
        Task { await SharedInboxDrainer.shared.drain(trigger: .appActive) }

        // Silent foreground catch-up. Re-read the local store into the on-screen
        // list + open thread (covers a CloudKit import that landed while the app
        // was inactive and whose remote-change post the VMs missed), and re-check
        // iCloud account/event health. The dedicated `.conversationsNeedLocalRefresh`
        // (NOT `.conversationsDidChange`) avoids the heavier share-target/menu-bar/
        // CarPlay side effects on every activation.
        NotificationCenter.default.post(name: .conversationsNeedLocalRefresh, object: nil)
        Task { await CloudSyncMonitor.shared.refresh() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        // Dock-icon click with no window up → reopen the main window via the same
        // notification bus the menu bar uses (proven to reopen `main` from a fully
        // closed state). Return true unconditionally so AppKit's default
        // bring-to-front still runs when a window is already visible.
        if !hasVisibleWindows {
            NSApp.activate(ignoringOtherApps: true)
            NotificationCenter.default.post(name: .openConversationsWindow, object: nil)
        }
        return true
    }
}
#endif
