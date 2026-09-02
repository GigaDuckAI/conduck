// SPDX-License-Identifier: Apache-2.0

// Conduck
// WorkboardSyncBannerPolicy.swift
//
// The desk's sync notice: whether to show one, and what it says.
//
// Whether is decided by ACCOUNT state — signed out, restricted, storage full —
// because those are the only states a person can act on and the only ones that
// hold for every card at once. A failed sync EVENT is deliberately not a
// trigger: card metadata and card bytes are mirrored from two separate stores,
// so the most recent failure can concern one payload while the rest of the desk
// is syncing normally, and a banner is a claim about all of it. That is why the
// only input here is `CloudSyncMonitor.Reason`, which exists for the three
// actionable account states and for nothing else.
//
// What it says is the desk's own sentence. The account is broken in one place,
// but the reader is looking at cards, and being told that "conversations" will
// not sync leaves them to work out whether the desk in front of them is
// affected. The chrome is deliberately identical to the conversation list's
// banner: one broken account must not look like two different problems.

#if !os(watchOS)
import SwiftUI

enum WorkboardSyncBannerPolicy {
    /// The sentence the desk's banner shows, or nil when it shows none. Both
    /// inputs come from the shared monitor: `showsBanner` already folds in the
    /// sticky per-outage dismissal, so the desk and the conversation list are
    /// dismissed together rather than charging the same interruption twice.
    static func message(
        showsBanner: Bool,
        reason: CloudSyncMonitor.Reason?
    ) -> LocalizedStringResource? {
        guard showsBanner, let reason else { return nil }
        return message(for: reason)
    }

    /// The desk's wording for one actionable account state.
    static func message(for reason: CloudSyncMonitor.Reason) -> LocalizedStringResource {
        switch reason {
        case .noAccount:
            return LocalizedStringResource(
                "workboard.sync.banner.noAccount",
                defaultValue: "iCloud is signed out — your cards won’t sync across your devices."
            )
        case .restricted:
            return LocalizedStringResource(
                "workboard.sync.banner.restricted",
                defaultValue: "iCloud is restricted on this device — your cards can’t sync."
            )
        case .quotaExceeded:
            return LocalizedStringResource(
                "workboard.sync.banner.quotaExceeded",
                defaultValue: "Your iCloud storage is full — new cards can’t sync to your other devices."
            )
        }
    }
}

/// The desk's banner. It takes its sentence rather than deriving one from the
/// account state, which is the whole difference between it and the conversation
/// list's banner — same chrome, same dismissal, same door into the OS setting
/// where the account is actually fixed.
struct WorkboardSyncBanner: View {
    let message: LocalizedStringResource
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.icloud")
                .foregroundStyle(AppColors.sunsetOrange)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 8) {
                Text(message)
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
#endif
