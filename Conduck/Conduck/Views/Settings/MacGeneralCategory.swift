// SPDX-License-Identifier: Apache-2.0

#if os(macOS)
// Conduck
// MacGeneralCategory.swift
//
// macOS Settings → General category. Global app-wide pickers moved here from
// Personal AI for clean grouping: Session (continuation policy), Attachments
// (max image dimension). Plus Launch at
// Login — a `Toggle` bound to `SMAppService.mainApp.status` (same mechanism as
// `MenuBarController.toggleLaunchAtLogin`; no new entitlement).
//
// Sections are hand-drawn `SettingsCard`s (`MacSettingsCard.swift`), so a row's
// highlight reaches the card's edge; each row's inset comes from its own row
// style, inside its live frame. Nothing here pads a row from the outside — see
// that file's one rule.
//
// The card draws no `Form`, and this screen is the densest control mix in
// Settings, so each control carries the two things a grouped `Form` supplies
// for free and a `VStack` does not: the label/control SPLIT (label leading,
// control trailing — hand-laid here as `HStack { label; Spacer(); control }`
// with the control `labelsHidden`, and the same title standing in as its
// VoiceOver name), and the NATIVE control resolution (`.automatic` picks a
// checkbox outside a `Form`, hence the explicit `.toggleStyle(.switch)`).

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
            VStack(alignment: .leading, spacing: SettingsCardMetrics.sectionSpacing) {
                launchSection
                onLaunchSection
                if syncMonitor.iCloudUnavailable, let reason = syncMonitor.unavailableReason {
                    SettingsCard {
                        // A status block that owns its own inner button, not a
                        // single row action: it takes the passive treatment, so
                        // it gets the card's inset and pitch and no hover wash.
                        ICloudSyncSettingsRow(reason: reason)
                            .settingsCardPassiveRow()
                    } header: {
                        Text(LocalizedStringResource("sync.icloud.settings.header", defaultValue: "Sync"))
                    }
                }
                menuBarSection
                shortcutSection
            }
            .padding(28)
            // The reading rail goes on the card stack, after its gutter, so the
            // gutter sits inside the capped column and the `ScrollView` keeps a
            // full-width scroll surface.
            .macSettingsRail()
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

    // MARK: - Card row shapes

    /// One card row holding a `Toggle`: title leading, switch trailing.
    ///
    /// The title is laid out as a SIBLING of the control rather than as the
    /// `Toggle`'s own label, because outside a grouped `Form` a `Toggle` keeps
    /// its label glued to its control instead of splitting the two across the
    /// row. `.toggleStyle(.switch)` is likewise the `Form`'s doing: `.automatic`
    /// resolves to a CHECKBOX on macOS everywhere else, and `.tint` alone does
    /// not reshape the control.
    ///
    /// The whole row is a `Button` that flips the binding, which is what a
    /// grouped `Form` gives a `Toggle` for free: there the title IS the control's
    /// label, so clicking the words flips the switch. Splitting the label out
    /// costs that, and `.settingsCardRowButton()` hands it back — the row's wash
    /// then covers exactly what the row activates. The switch is drawn inside the
    /// label with `.allowsHitTesting(false)`, so a click on the switch itself
    /// reaches the same `Button` rather than firing a second, cancelling flip.
    ///
    /// `.accessibilityRepresentation` collapses the pair back into the single
    /// standard switch VoiceOver expects — without it the `Button` and the
    /// `Toggle` inside it are two elements for one setting.
    private func toggleRow(_ title: Text, isOn: Binding<Bool>) -> some View {
        Button {
            isOn.wrappedValue.toggle()
        } label: {
            HStack {
                title.foregroundStyle(AppColors.textPrimary)
                Spacer()
                Toggle(isOn: isOn) { EmptyView() }
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .tint(AppColors.brandAmber)
                    .allowsHitTesting(false)
            }
        }
        .settingsCardRowButton()
        .accessibilityRepresentation { Toggle(isOn: isOn) { title } }
    }

    /// One card row holding a `.menu` `Picker`: title leading, popup trailing.
    /// Same split, same hidden-label-as-VoiceOver-name reasoning as `toggleRow`.
    ///
    /// `.fixedSize()` pins the popup to its widest option; left to itself it
    /// stretches across whatever width the row offers, which a `Form` never
    /// gives it.
    ///
    /// Passive, unlike `toggleRow`: a popup opens on its own frame and no
    /// row-level action can raise its menu, so a wash across the whole row would
    /// invite a click the row cannot answer. The card's inset and height floor,
    /// no wash — the treatment the segmented "Ask with" row takes for the same
    /// reason.
    private func menuPickerRow<Value: Hashable, Options: View>(
        _ title: Text,
        selection: Binding<Value>,
        @ViewBuilder options: () -> Options
    ) -> some View {
        HStack {
            title.foregroundStyle(AppColors.textPrimary)
            Spacer()
            Picker(selection: selection, content: options) { title }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
        }
        .settingsCardPassiveRow()
    }

    // MARK: - Launch at Login

    private var launchSection: some View {
        SettingsCard {
            toggleRow(
                // Reuse the MenuBarController verbatim source string.
                Text(String(localized: "Launch at Login")),
                isOn: Binding(
                    get: { launchAtLogin },
                    set: { newValue in setLaunchAtLogin(newValue) }
                )
            )

            toggleRow(
                Text(String(localized: "Show in Dock")),
                isOn: Binding(
                    get: { showDockIcon },
                    set: { newValue in setShowDockIcon(newValue) }
                )
            )
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
        SettingsCard {
            // A recorder row is a FIELD, not a row-level action — clicking the
            // label does nothing, and the recorder arms only on its own box. So
            // it takes the passive treatment: the card's inset and height floor,
            // and no wash promising the whole row is clickable.
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
            .settingsCardPassiveRow()

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
            .settingsCardPassiveRow()
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
        SettingsCard {
            let inputSelection = Binding<MenuBarInputMode>(
                get: { menuBarInputMode },
                set: { newValue in setMenuBarInputMode(newValue) }
            )
            // One `Text` value used twice — as the visible title and as the
            // hidden picker label VoiceOver reads — so the two cannot drift.
            let inputModeTitle = Text(LocalizedStringResource(
                "settings.mac.general.inputMode.label",
                defaultValue: "Ask with"
            ))
            HStack {
                inputModeTitle.foregroundStyle(AppColors.textPrimary)
                Spacer()
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
                    inputModeTitle
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                // A segmented control takes every point of width it is offered,
                // so unpinned it swallows the row and shoves the title out.
                // Sized to its two segments it sits where a `Form` puts it.
                .fixedSize()
            }
            // A set of choices, not one row-level action — inset and height
            // floor, no wash.
            .settingsCardPassiveRow()

            let policySelection = Binding<SessionContinuationPolicy>(
                get: { viewModel.sessionContinuationPolicy },
                set: { newValue in Task { await viewModel.setSessionContinuationPolicy(newValue) } }
            )
            menuPickerRow(
                Text(LocalizedStringResource("settings.remoteAgent.sessionPolicy.label", defaultValue: "Add to last conversation")),
                selection: policySelection
            ) {
                ForEach(SessionContinuationPolicy.allCases.reversed()) { policy in
                    Text(policy.label).tag(policy)
                }
            }

            // Spoken output — the OUTPUT half of a menu-bar ask, paired with the
            // "Ask with" input row above. Engine config lives under Voice; this
            // is just the per-surface on/off. Device-local persist (the dock-icon
            // idiom): state first, then a fire-and-forget actor write.
            toggleRow(
                Text(LocalizedStringResource(
                    "settings.quickCapture.speakReplies.label",
                    defaultValue: "Speak replies"
                )),
                isOn: Binding(
                    get: { speakQuickLaneReplies },
                    set: { newValue in
                        speakQuickLaneReplies = newValue
                        Task { await SettingsManager.shared.setSpeakQuickLaneReplies(newValue) }
                    }
                )
            )

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
            }
            // The card row style, not the `Form` one: this row IS one action, so
            // its highlight runs to the card's edges instead of stopping at a
            // `Form`'s inset content box.
            .settingsCardRowButton()
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
        SettingsCard {
            let selection = Binding<OnLaunchMode>(
                get: { viewModel.onLaunchMode },
                set: { newValue in Task { await viewModel.setOnLaunchMode(newValue) } }
            )
            menuPickerRow(
                Text(LocalizedStringResource(
                    "settings.general.onLaunch.label",
                    defaultValue: "On launch"
                )),
                selection: selection
            ) {
                Text(LocalizedStringResource(
                    "settings.general.onLaunch.startNew",
                    defaultValue: "Start a new conversation"
                )).tag(OnLaunchMode.startNewConversation)
                Text(LocalizedStringResource(
                    "settings.general.onLaunch.resumeLast",
                    defaultValue: "Resume last conversation"
                )).tag(OnLaunchMode.resumeLastConversation)
            }
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
