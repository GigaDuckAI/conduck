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
    /// Whether Retry is offered at all. Rides `AppError.isRetryable` for the
    /// failure the card is currently reporting — the arming error at first, then
    /// whatever the last Retry attempt hit.
    ///
    /// The button is WITHHELD on a terminal verdict rather than disabled: the
    /// same preserved bytes go to the same configuration, so a certificate this
    /// device refuses, a rejected key or an endpoint that isn't an AI endpoint
    /// reaches the identical answer every time. A live Retry there re-fires into
    /// the refusal it just reported, and its spinner covers the one sentence the
    /// user needed to read. The host resets this from the store on every
    /// refresh, so fixing the server brings the button back.
    var errorIsRetryable: Bool = true
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

                // The headline says whether retrying is even on the table, so a
                // card with no button never reads as one whose button is missing.
                Text(errorIsRetryable
                     ? LocalizedStringResource("pendingRetry.headline",
                                               defaultValue: "Your last recording couldn't be sent.")
                     : LocalizedStringResource("pendingRetry.headline.terminal",
                                               defaultValue: "Your last recording couldn't be sent, and trying again would reach the same answer."))
                    .font(.caption)
                    .foregroundStyle(AppColors.textSecondary)

                Spacer()

                if errorIsRetryable {
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
