// SPDX-License-Identifier: Apache-2.0

// The shared General setting for automatic content sync. The switch states the
// account's requested preference; runtime status describes only this device.
// Confirmations disclose the other devices and retained cloud copies. Settings
// and secrets use their existing independent transports throughout a transition.

#if !os(watchOS)
import SwiftUI

struct ContentSyncSettingsSection: View {
    @State private var runtime = ContentSyncRuntime.shared
    @State private var monitor = CloudSyncMonitor.shared
    @State private var pendingEnabled = true
    @State private var showingConfirmation = false
    @State private var savingFailed = false

    private var selection: Binding<Bool> {
        Binding(get: { runtime.desiredEnabled }, set: { requestChange($0) })
    }

    var body: some View {
        group
            .confirmationDialog(
                Text(pendingEnabled == true
                    ? LocalizedStringResource("settings.contentSync.enable.title", defaultValue: "Turn on content sync?")
                    : LocalizedStringResource("settings.contentSync.disable.title", defaultValue: "Turn off content sync?")),
                isPresented: $showingConfirmation,
                titleVisibility: .visible
            ) {
                Button(pendingEnabled == true
                    ? LocalizedStringResource("settings.contentSync.enable.action", defaultValue: "Turn On")
                    : LocalizedStringResource("settings.contentSync.disable.action", defaultValue: "Turn Off")) {
                    do {
                        _ = try ContentSyncPreferenceStore.shared.setEnabled(pendingEnabled)
                        savingFailed = false
                    } catch {
                        savingFailed = true
                    }
                    showingConfirmation = false
                }
                Button(LocalizedStringResource("common.cancel", defaultValue: "Cancel"), role: .cancel) {
                    showingConfirmation = false
                }
            } message: {
                Text(ContentSyncPresentationPolicy.confirmation(enabling: pendingEnabled == true))
            }
            .task { runtime.start() }
    }

    private func requestChange(_ enabled: Bool) {
        pendingEnabled = enabled
        savingFailed = false
        showingConfirmation = true
    }

    @ViewBuilder private var group: some View {
        #if os(macOS)
        SettingsCard {
            Button { requestChange(!runtime.desiredEnabled) } label: {
                HStack {
                    Text(ContentSyncPresentationPolicy.toggleLabel)
                        .foregroundStyle(AppColors.textPrimary)
                    Spacer()
                    Toggle(isOn: selection) { EmptyView() }
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .tint(AppColors.brandAmber)
                        .allowsHitTesting(false)
                }
            }
            .settingsCardRowButton()
            .accessibilityRepresentation {
                Toggle(isOn: selection) { Text(ContentSyncPresentationPolicy.toggleLabel) }
            }
            information.settingsCardPassiveRow()
        } header: {
            Text(LocalizedStringResource("sync.icloud.settings.header", defaultValue: "Sync"))
        }
        #else
        Section {
            Toggle(isOn: selection) { Text(ContentSyncPresentationPolicy.toggleLabel) }
                .tint(AppColors.brandAmber)
            information
        } header: {
            Text(LocalizedStringResource("sync.icloud.settings.header", defaultValue: "Sync"))
        }
        #endif
    }

    private var information: some View {
        VStack(alignment: .leading, spacing: 10) {
            if savingFailed {
                Text(LocalizedStringResource("settings.contentSync.save.failed", defaultValue: "Couldn’t save the sync setting. Try again."))
                    .font(.caption)
                    .foregroundStyle(AppColors.sunsetOrange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(ContentSyncPresentationPolicy.explanation(enabled: runtime.desiredEnabled))
                .font(.caption)
                .foregroundStyle(AppColors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if runtime.state == .applying {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(runtime.statusMessage ?? LocalizedStringResource(
                        "settings.contentSync.applying", defaultValue: "Updating content sync on this device…"))
                        .font(.caption)
                }
            } else if let message = runtime.statusMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(runtime.state == .failed ? AppColors.sunsetOrange : AppColors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if runtime.state == .off {
                Text(LocalizedStringResource("settings.contentSync.effectiveOff", defaultValue: "Content sync is off on this device."))
                    .font(.caption)
                    .foregroundStyle(AppColors.textSecondary)
            }
            if runtime.state == .failed {
                Button(LocalizedStringResource("common.retry", defaultValue: "Try again")) {
                    Task { await runtime.retry() }
                }
                .inlineLinkButton()
            }
            if runtime.desiredEnabled, monitor.iCloudUnavailable, let reason = monitor.unavailableReason {
                ICloudSyncSettingsRow(reason: reason)
            }
        }
    }
}
#endif
