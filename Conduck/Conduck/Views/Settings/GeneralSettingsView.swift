// SPDX-License-Identifier: Apache-2.0

// Conduck
// GeneralSettingsView.swift
//
// iOS Settings master-detail — 2nd level. The "General" sub-screen pushed from
// the Settings root "General" row, mirroring the macOS `MacGeneralCategory`'s
// global-behavior grouping. Holds the two behavior prefs that used to sit
// inline at the Settings root:
//   - Startup — what you land on at cold launch (`OnLaunchMode`).
//   - Quick Captures — how long a headless quick capture keeps appending to the
//     same conversation (`SessionContinuationPolicy`).
// Moved here (out of `SettingsView`) so iOS mirrors macOS and the root reads as
// a clean list of destinations (General · Personal AI · Voice).

#if os(iOS)
import SwiftUI

struct GeneralSettingsView: View {
    @Bindable var viewModel: SettingsViewModel

    /// Shared `@Observable` iCloud-sync health. Surfaces a warning row ONLY when
    /// iCloud is in a user-actionable bad state; otherwise this screen is unchanged.
    @State private var syncMonitor = CloudSyncMonitor.shared

    /// iPad-only: show the Control Center setup-walkthrough card at the bottom.
    /// On iPhone the Setup card lives on the root `SettingsView` (the iPad has no
    /// sidebar Setup category — General is its natural home, its iPad scope being
    /// "Control Center & Lock Screen"). Defaults OFF so the iPhone sub-screen and
    /// the compact-iPad fallback are unchanged.
    var showSetupCard: Bool = false

    /// Drives the Control Center / Action Button setup walkthrough cover (iPad).
    @State private var showSetupGuide = false

    var body: some View {
        Form {
            startupSection
            quickCapturesSection
            if syncMonitor.iCloudUnavailable, let reason = syncMonitor.unavailableReason {
                Section {
                    ICloudSyncSettingsRow(reason: reason)
                } header: {
                    Text(LocalizedStringResource("sync.icloud.settings.header", defaultValue: "Sync"))
                }
            }
            if showSetupCard { setupCardSection }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .navigationTitle(Text(LocalizedStringResource("settings.general.section.title", defaultValue: "General")))
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(isPresented: $showSetupGuide) {
            SetupGuideView()
        }
    }

    // MARK: - Setup card (iPad — Control Center walkthrough)

    /// The Control Center setup-walkthrough card — accent-tinted "do this" island
    /// mirroring the iPhone root Setup card (title/icon track
    /// `DeviceCapabilities.recommendedTriggerMethod`, which is "Set up Control
    /// Center" on iPad). Opens the same `SetupGuideView`.
    private var setupCardSection: some View {
        let trigger = DeviceCapabilities.recommendedTriggerMethod
        return Section {
            Button {
                showSetupGuide = true
            } label: {
                HStack {
                    Image(systemName: trigger.setupCardIcon)
                        .font(.title2)
                        .foregroundStyle(.tint)
                        .frame(width: 32)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(trigger.setupCardTitle)
                            .font(.body)
                            .fontWeight(.medium)
                            .foregroundStyle(.tint)
                        Text("Talk to your AI from any app") // xcstrings: setup-guide
                            .font(.caption)
                            .foregroundStyle(AppColors.textSecondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(.tint)
                }
                .padding(.vertical, 4)
            }
        }
    }

    // MARK: - Startup (cold-launch landing UX)

    private var startupSection: some View {
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
            .tint(AppColors.brandAmber)
        } header: {
            Text(LocalizedStringResource("settings.general.onLaunch.header", defaultValue: "Startup"))
        } footer: {
            Text(LocalizedStringResource(
                "settings.general.onLaunch.footer",
                defaultValue: "What you see when you open Conduck."
            ))
        }
    }

    // MARK: - Quick Captures (headless continuation policy)

    private var quickCapturesSection: some View {
        Section {
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
            .tint(AppColors.brandAmber)
        } header: {
            if DeviceCapabilities.isiPad {
                Text(LocalizedStringResource("settings.quickCapture.header.ipad", defaultValue: "Control Center & Lock Screen"))
            } else {
                Text(LocalizedStringResource("settings.quickCapture.header.iphone", defaultValue: "Action Button & Control Center"))
            }
        } footer: {
            if DeviceCapabilities.isiPad {
                Text(LocalizedStringResource(
                    "settings.quickCapture.footer.ipad",
                    defaultValue: "Applies to asks from Control Center or the Lock Screen on this iPad. In-app messages use the conversation you have open."
                ))
            } else {
                Text(LocalizedStringResource(
                    "settings.quickCapture.footer.iphone",
                    defaultValue: "Applies to asks from the Action Button, Lock Screen, or Control Center on this iPhone. In-app messages use the conversation you have open."
                ))
            }
        }
    }

}

#Preview {
    NavigationStack {
        GeneralSettingsView(viewModel: SettingsViewModel())
    }
}
#endif
