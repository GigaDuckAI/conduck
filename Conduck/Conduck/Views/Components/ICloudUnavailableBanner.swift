// SPDX-License-Identifier: Apache-2.0

// Conduck
// ICloudUnavailableBanner.swift
//
// The ONE quiet, user-actionable sync surface. Shown atop the conversation list
// ONLY when `CloudSyncMonitor` reports a state the user can FIX (iCloud signed
// out / restricted / storage full) AND the banner hasn't been dismissed this
// outage episode. Everything else about iCloud sync stays silent — this is the
// deliberate exception to "no status chrome." Dismissal is sticky for the episode
// (persisted) and resets automatically when the account recovers.

#if !os(watchOS)
import SwiftUI

/// Open the OS surface where the user fixes iCloud: the app's page in Settings
/// (iOS — no public deep link to the iCloud pane exists) / the Apple ID pane in
/// System Settings (macOS). Shared by the banner and the Settings status rows.
@MainActor
func openICloudSystemSettings() {
    #if os(iOS)
    if let url = URL(string: UIApplication.openSettingsURLString) {
        UIApplication.shared.open(url)
    }
    #elseif os(macOS)
    if let url = URL(string: "x-apple.systempreferences:com.apple.preferences.AppleIDPrefPane") {
        NSWorkspace.shared.open(url)
    }
    #endif
}

struct ICloudUnavailableBanner: View {
    let reason: CloudSyncMonitor.Reason
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.icloud")
                .foregroundStyle(AppColors.sunsetOrange)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 8) {
                Text(reason.bannerMessage)
                    .font(.caption)
                    .foregroundStyle(AppColors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button {
                    openICloudSystemSettings()
                } label: {
                    Text(LocalizedStringResource("sync.icloud.banner.openSettings", defaultValue: "Open Settings"))
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            Spacer(minLength: 0)

            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppColors.textTertiary)
            }
            .pointerIconButton()
            .accessibilityLabel(Text(LocalizedStringResource("sync.icloud.banner.dismiss", defaultValue: "Dismiss")))
        }
        .padding(16)
        .glassCardBackground(borderColor: AppColors.sunsetOrange.opacity(0.4))
        .padding(.horizontal)
        .padding(.top, 8)
    }
}

/// Settings-screen status row, shown only when iCloud is in a user-actionable bad
/// state. The persistent counterpart to the dismissible list banner: it stays
/// until the account recovers. Drop into a `Section` on iOS + macOS Settings.
struct ICloudSyncSettingsRow: View {
    let reason: CloudSyncMonitor.Reason

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.icloud")
                    .foregroundStyle(AppColors.sunsetOrange)
                Text(LocalizedStringResource("sync.icloud.settings.title", defaultValue: "iCloud Sync"))
                    .foregroundStyle(AppColors.textPrimary)
                Spacer()
                Text(LocalizedStringResource("sync.icloud.settings.statusOff", defaultValue: "Off"))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppColors.sunsetOrange)
            }
            Text(reason.settingsMessage)
                .font(.caption)
                .foregroundStyle(AppColors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                openICloudSystemSettings()
            } label: {
                Text(LocalizedStringResource("sync.icloud.banner.openSettings", defaultValue: "Open Settings"))
                    .font(.subheadline.weight(.semibold))
            }
            .buttonStyle(.bordered)
        }
    }
}
#endif
