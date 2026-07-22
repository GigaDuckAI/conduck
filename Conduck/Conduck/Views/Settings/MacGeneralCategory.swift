#if os(macOS)
// Conduck
// MacGeneralCategory.swift
//
// macOS Settings → General category. Global app-wide pickers moved here from
// Personal AI for clean grouping: Session (continuation policy), Attachments
// (max image dimension). Plus Launch at
// Login — a `Toggle` bound to `SMAppService.mainApp.status` (same mechanism as
// `MenuBarController.toggleLaunchAtLogin`; no new entitlement).

import AppKit
import KeyboardShortcuts
import SwiftUI
import ServiceManagement

struct MacGeneralCategory: View {
    @Bindable var viewModel: SettingsViewModel

    /// Mirror of `SMAppService.mainApp.status == .enabled`, refreshed on appear
    /// and after each toggle.
    @State private var launchAtLogin = false

    /// Mirror of `SettingsManager.getShowDockIcon()`, seeded on appear. Drives
    /// the "Show in Dock" toggle; ON = Dock app, OFF = menu-bar-only utility.
    @State private var showDockIcon = true

    /// Mirror of `SettingsManager.getMenuBarInputMode()`, seeded on appear.
    /// Voice = the popover auto-records on summon (default); Text = it opens a
    /// focused message field instead. Device-local, like Show in Dock.
    @State private var menuBarInputMode: MenuBarInputMode = .default

    /// Mirror of `SettingsManager.getSpeakQuickLaneReplies()`, seeded on appear.
    /// The OUTPUT side of a menu-bar ask — speak replies to menu-bar / shortcut /
    /// Screenshot & Ask captures on THIS Mac. Moved here from the Voice category
    /// so the whole menu-bar round-trip (input mode, threading, spoken output)
    /// lives in one place; the engine it depends on stays under Voice. Device-
    /// local (App Groups, never KVS — an office Mac stays silent while a home Mac
    /// speaks); the main-window lane never consults it.
    @State private var speakQuickLaneReplies = false

    /// Drives the "How to Use" guide sheet (the relocated menu-bar shortcut
    /// explainer, formerly an onboarding step). Presented as a fixed-size sheet,
    /// mirroring Personal AI's "Guided Setup".
    @State private var showingMenuBarGuide = false

    /// Shared `@Observable` iCloud-sync health. Surfaces a warning row ONLY when
    /// iCloud is in a user-actionable bad state; otherwise this screen is unchanged.
    @State private var syncMonitor = CloudSyncMonitor.shared

    var body: some View {
        ScrollView {
            Form {
                launchSection
                onLaunchSection
                if syncMonitor.iCloudUnavailable, let reason = syncMonitor.unavailableReason {
                    Section {
                        ICloudSyncSettingsRow(reason: reason)
                    } header: {
                        Text(LocalizedStringResource("sync.icloud.settings.header", defaultValue: "Sync"))
                    }
                }
                menuBarSection
                shortcutSection
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .padding(28)
        }
        .sheet(isPresented: $showingMenuBarGuide) {
            // Fixed frame so the guide never resizes the window — matches the
            // Guided Setup sheet's sizing (MacPersonalAICategory).
            MenuBarGuideView()
                .frame(width: 600, height: 650)
        }
        .onAppear {
            refreshLaunchAtLogin()
            Task { showDockIcon = await SettingsManager.shared.getShowDockIcon() }
            Task { menuBarInputMode = await SettingsManager.shared.getMenuBarInputMode() }
            Task { speakQuickLaneReplies = await SettingsManager.shared.getSpeakQuickLaneReplies() }
        }
    }

    // MARK: - Launch at Login

    private var launchSection: some View {
        Section {
            Toggle(isOn: Binding(
                get: { launchAtLogin },
                set: { newValue in setLaunchAtLogin(newValue) }
            )) {
                // Reuse the MenuBarController verbatim source string.
                Text(String(localized: "Launch at Login"))
                    .foregroundStyle(AppColors.textPrimary)
            }
            .tint(AppColors.brandAmber)

            Toggle(isOn: Binding(
                get: { showDockIcon },
                set: { newValue in setShowDockIcon(newValue) }
            )) {
                Text(String(localized: "Show in Dock"))
                    .foregroundStyle(AppColors.textPrimary)
            }
            .tint(AppColors.brandAmber)
        } header: {
            Text(LocalizedStringResource("settings.mac.general.title", defaultValue: "General"))
        } footer: {
            Text(LocalizedStringResource(
                "settings.mac.general.showInDock.footer",
                defaultValue: "Conduck always lives in the menu bar. Turn this on to also show a Dock icon; turn it off to run as a menu-bar-only utility."
            ))
        }
    }

    // MARK: - Keyboard Shortcut

    private var shortcutSection: some View {
        Section {
            HStack {
                Label(
                    // Mode-neutral name pairing with "Screenshot & Ask": ⌘⇧1 is
                    // the quick ask in BOTH input modes. Key name stays internal
                    // (`quickCapture.label`); the value is spliced in the catalog —
                    // rewording `defaultValue:` alone is inert (catalog trap).
                    title: { Text(LocalizedStringResource("settings.mac.general.shortcut.quickCapture.label", defaultValue: "Ask")) },
                    icon: { Image(systemName: "command") }
                )
                .foregroundStyle(AppColors.textPrimary)
                Spacer()
                KeyboardShortcuts.Recorder(for: .toggleVoiceCapture)
            }

            HStack {
                Label(
                    // Mode-neutral + matches the feature's menu-item name.
                    title: { Text(LocalizedStringResource("settings.mac.general.shortcut.screenshotAsk.label", defaultValue: "Screenshot & Ask")) },
                    icon: { Image(systemName: "rectangle.dashed.badge.record") }
                )
                .foregroundStyle(AppColors.textPrimary)
                Spacer()
                KeyboardShortcuts.Recorder(for: .captureRegionAndVoice)
            }
        } header: {
            Text(LocalizedStringResource("settings.mac.general.shortcut.header", defaultValue: "Keyboard Shortcut"))
        } footer: {
            Text(LocalizedStringResource(
                "settings.mac.general.shortcut.footerModes",
                defaultValue: "To change a shortcut, click it and press the keys together — one or more modifiers (⌘ ⌥ ⌃ ⇧) plus one regular key. Esc always cancels the request."
            ))
        }
    }

    // MARK: - Menu Bar (input mode + conversation continuation)

    private var menuBarSection: some View {
        Section {
            let inputSelection = Binding<MenuBarInputMode>(
                get: { menuBarInputMode },
                set: { newValue in setMenuBarInputMode(newValue) }
            )
            Picker(selection: inputSelection) {
                Text(LocalizedStringResource(
                    "settings.mac.general.inputMode.voice",
                    defaultValue: "Voice"
                )).tag(MenuBarInputMode.voice)
                Text(LocalizedStringResource(
                    "settings.mac.general.inputMode.text",
                    defaultValue: "Text"
                )).tag(MenuBarInputMode.text)
            } label: {
                Text(LocalizedStringResource(
                    "settings.mac.general.inputMode.label",
                    defaultValue: "Ask with"
                ))
                .foregroundStyle(AppColors.textPrimary)
            }
            .pickerStyle(.segmented)

            let policySelection = Binding<SessionContinuationPolicy>(
                get: { viewModel.sessionContinuationPolicy },
                set: { newValue in Task { await viewModel.setSessionContinuationPolicy(newValue) } }
            )
            Picker(selection: policySelection) {
                ForEach(SessionContinuationPolicy.allCases.reversed()) { policy in
                    Text(policy.label).tag(policy)
                }
            } label: {
                Text(LocalizedStringResource("settings.remoteAgent.sessionPolicy.label", defaultValue: "Add to last conversation"))
                    .foregroundStyle(AppColors.textPrimary)
            }
            .pickerStyle(.menu)

            // Spoken output — the OUTPUT half of a menu-bar ask, paired with the
            // "Ask with" input row above. Engine config lives under Voice; this
            // is just the per-surface on/off. Device-local persist (the dock-icon
            // idiom): state first, then a fire-and-forget actor write.
            Toggle(isOn: Binding(
                get: { speakQuickLaneReplies },
                set: { newValue in
                    speakQuickLaneReplies = newValue
                    Task { await SettingsManager.shared.setSpeakQuickLaneReplies(newValue) }
                }
            )) {
                Text(LocalizedStringResource(
                    "settings.quickCapture.speakReplies.label",
                    defaultValue: "Speak replies"
                ))
                .foregroundStyle(AppColors.textPrimary)
            }
            .tint(AppColors.brandAmber)

            // "How to Use" — the relocated menu-bar shortcut guide. Blue `.tint`
            // (NOT amber) to read as a setup/guide affordance, matching Personal
            // AI's "Guided Setup" (PersonalAIConnectSection).
            Button { showingMenuBarGuide = true } label: {
                Label(
                    LocalizedStringResource(
                        "settings.mac.general.menuBar.howToUse.label",
                        defaultValue: "How to Use"
                    ),
                    systemImage: "questionmark.circle"
                )
                .font(.body.weight(.semibold))
                .foregroundStyle(.tint)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } header: {
            Text(LocalizedStringResource("settings.quickCapture.header.mac", defaultValue: "Menu Bar"))
        } footer: {
            Text(LocalizedStringResource(
                "settings.quickCapture.footer.mac",
                defaultValue: "Last conversation: Pick a chat in the popover to override it. Spoken replies are read aloud with your Text-to-Speech voice."
            ))
        }
    }

    /// Persist the input-mode choice. Device-local via `SettingsManager`
    /// (which posts `.settingsDidChangeRemotely` — `MenuBarCoordinator`
    /// refreshes its observable mirror, so the very next summon uses the new
    /// mode; no app-delegate side effect needed, unlike Show in Dock).
    private func setMenuBarInputMode(_ mode: MenuBarInputMode) {
        menuBarInputMode = mode
        Task { await SettingsManager.shared.setMenuBarInputMode(mode) }
    }

    private func refreshLaunchAtLogin() {
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            #if DEBUG
            print("Launch at Login toggle failed: \(error)")
            #endif
        }
        // If macOS is gating the login item behind user approval (denied or
        // revoked in System Settings), guide the user straight to the Login Items
        // pane — otherwise the toggle silently snaps back to off and looks broken.
        if enabled, SMAppService.mainApp.status == .requiresApproval {
            SMAppService.openSystemSettingsLoginItems()
        }
        refreshLaunchAtLogin()
    }

    // MARK: - Show in Dock

    /// Persist the "Show in Dock" choice and apply it LIVE. Persistence goes
    /// through `SettingsManager` (the synchronous launch read picks it up next
    /// launch); the live side effect goes through `AppDelegate.applyDockVisibility`
    /// — reached via `NSApp.delegate`, the same app-level-side-effect-from-this-
    /// view precedent the Launch-at-Login toggle sets with its global
    /// `SMAppService.mainApp` calls.
    private func setShowDockIcon(_ show: Bool) {
        showDockIcon = show
        Task { await SettingsManager.shared.setShowDockIcon(show) }
        (NSApp.delegate as? AppDelegate)?.applyDockVisibility(show)
    }

    // MARK: - On launch

    private var onLaunchSection: some View {
        Section {
            let selection = Binding<OnLaunchMode>(
                get: { viewModel.onLaunchMode },
                set: { newValue in Task { await viewModel.setOnLaunchMode(newValue) } }
            )
            Picker(selection: selection) {
                Text(LocalizedStringResource(
                    "settings.general.onLaunch.startNew",
                    defaultValue: "Start a new conversation"
                )).tag(OnLaunchMode.startNewConversation)
                Text(LocalizedStringResource(
                    "settings.general.onLaunch.resumeLast",
                    defaultValue: "Resume last conversation"
                )).tag(OnLaunchMode.resumeLastConversation)
            } label: {
                Text(LocalizedStringResource(
                    "settings.general.onLaunch.label",
                    defaultValue: "On launch"
                ))
                .foregroundStyle(AppColors.textPrimary)
            }
            .pickerStyle(.menu)
        } header: {
            Text(LocalizedStringResource("settings.general.onLaunch.header", defaultValue: "Startup"))
        } footer: {
            Text(LocalizedStringResource(
                "settings.general.onLaunch.footer",
                defaultValue: "What you see when you open Conduck."
            ))
        }
    }

    // The "Couldn't send" share-recovery section moved to MacPersonalAICategory
    // (it mirrors the iOS placement under Personal AI).
}
#endif
