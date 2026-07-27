// SPDX-License-Identifier: Apache-2.0

import SwiftUI

/// Shown when no user identity is available on the Watch.
/// The user needs to open Conduck on their iPhone to sync the identity.
///
/// If a recording was triggered (e.g. via the Action Button) before identity
/// arrived, this view surfaces a visible "Waiting for iPhone…" state so the
/// user knows the press was registered. The pending request is consumed by
/// `WatchNoteView.onAppear` once identity flips and the parent re-renders.
struct WatchSetupView: View {
    @State private var isChecking = false
    private let coordinator = WatchRecordingCoordinator.shared

    var body: some View {
        VStack(spacing: 12) {
            Image("conduck-avatar")
                .resizable()
                .scaledToFit()
                .frame(height: 50)
                .clipShape(Circle())

            if coordinator.pendingStart {
                Text("Waiting for iPhone to set up Conduck…")
                    .font(.caption)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.orange)
            } else {
                Text("Open Conduck on iPhone to get started")
                    .font(.caption)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }

            if isChecking || coordinator.pendingStart {
                ProgressView()
                    .tint(.orange)
                    .scaleEffect(0.8)
            }
        }
        .padding()
        .task {
            // Periodically check for identity arrival
            while !Task.isCancelled {
                isChecking = true
                if let _ = await WatchIdentityResolver.shared.getUserID() {
                    // Identity arrived — parent view will switch to the note UI
                    NotificationCenter.default.post(name: .watchIdentityDidChange, object: nil)
                    break
                }
                // Try real-time request from iPhone
                _ = await WatchIdentityResolver.shared.requestFromPhone()
                isChecking = false
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }
}
