// SPDX-License-Identifier: Apache-2.0

import SwiftUI

/// Banner that appears on the home screen when an audio recording was
/// preserved (failed transcription, OS-killed App Intent, etc.) and is
/// available to retry from inside the app.
///
/// Mode-agnostic by design — works identically for transcribe and note
/// modes since both share the same recovery affordance ("tap Retry, we'll
/// re-run whatever was saved"). Routing happens inside `PendingRetryRunner`,
/// not here.
struct PendingRetryCard: View {
    let isRetrying: Bool
    let retryErrorMessage: String?
    let onRetry: () -> Void
    /// Troubleshoot affordance for the failure that armed this card — non-nil
    /// only when the preserved recording's error carries a code Diagnostics can
    /// help with (the failable `DiagnosticsFocus` init is the single filter,
    /// applied by the host). nil → no button (nil code or non-troubleshootable).
    var troubleshootFocus: DiagnosticsFocus? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Image(systemName: "exclamationmark.arrow.circlepath")
                    .foregroundStyle(AppColors.sunsetOrange)

                Text("Your last recording couldn't be sent.") // xcstrings
                    .font(.caption)
                    .foregroundStyle(AppColors.textSecondary)

                Spacer()

                Button {
                    onRetry()
                } label: {
                    if isRetrying {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text("Retry") // xcstrings
                            .font(.caption)
                            .fontWeight(.semibold)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(isRetrying)
            }

            if let retryErrorMessage {
                Text(retryErrorMessage)
                    .font(.caption2)
                    .foregroundStyle(AppColors.sunsetOrange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            // "Get help" affordance beneath Retry — the home-screen sibling of
            // the conversation banner's Troubleshoot button, shown only when the
            // failure has a code Diagnostics can help with.
            if let troubleshootFocus {
                TroubleshootButton(focus: troubleshootFocus)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(16)
        .glassCardBackground(borderColor: AppColors.sunsetOrange.opacity(0.4))
    }
}
