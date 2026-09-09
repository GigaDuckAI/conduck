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
///
/// It speaks for a QUEUE, not for one recording. Retry takes the newest
/// waiting capture and the card stays up for whatever is behind it, so the
/// count has to be visible: without it a person who parked three recordings
/// sees one card, retries once, and reads the card that is still there as a
/// retry that failed silently.
struct PendingRetryCard: View {
    let isRetrying: Bool
    let retryErrorMessage: String?
    let onRetry: () -> Void
    /// Whether Retry is offered at all. Rides `AppError.isRetryable` for the
    /// failure the LAST attempt in this session hit — never the stored arming
    /// code, which describes one capture (the newest) while this card speaks for
    /// the queue behind it, and which cannot know what the person changed since
    /// it was written.
    ///
    /// The button is WITHHELD on a terminal verdict rather than disabled: the
    /// same preserved bytes go to the same configuration, so a certificate this
    /// device refuses, a rejected key or an endpoint that isn't an AI endpoint
    /// reaches the identical answer every time. A live Retry there re-fires into
    /// the refusal it just reported, and its spinner covers the one sentence the
    /// user needed to read. The host RESTORES it on every refresh, so fixing the
    /// server brings the button back — and so a capture waiting behind a
    /// terminal one is never withheld for a verdict that was not about it.
    var errorIsRetryable: Bool = true
    /// Troubleshoot affordance for the failure that armed this card — non-nil
    /// only when the preserved recording's error carries a code Diagnostics can
    /// help with (the failable `DiagnosticsFocus` init is the single filter,
    /// applied by the host). nil → no button (nil code or non-troubleshootable).
    var troubleshootFocus: DiagnosticsFocus? = nil
    /// How many recordings are waiting, the one this card's Retry would take
    /// included. Rendered only ABOVE one: at exactly one the headline already
    /// says a recording is waiting, and "1 recording waiting" beside it is the
    /// same sentence twice.
    let pendingCount: Int
    /// Ask the host to RESERVE the recording this card's Retry would take, so
    /// the question below is asked about one exact capture.
    ///
    /// It does not open the confirmation itself: the host does, by raising
    /// `confirmingDiscard` once it holds the reservation. A dialog raised first
    /// and resolved against "whatever is claimable now" is how a discard with a
    /// backlog deletes a recording the person was not looking at — the queue
    /// can change while the question is on screen, and another surface may be
    /// mid-retry on the newest capture.
    ///
    /// The affordance exists because a Work capture the desk never accepted is
    /// exempt from the transcription TTL — those bytes are the only copy of what
    /// somebody said, so nothing expires them — and without this the only way to
    /// be rid of one is to discard every waiting recording from Settings.
    let onDiscard: () -> Void
    /// Raised by the HOST once it holds the reservation, so the confirmation
    /// can only ever be answered about a capture this surface owns.
    @Binding var confirmingDiscard: Bool
    /// True when the desk ALREADY holds what the reserved capture produced — a
    /// Work capture whose words card is written and whose entry is holding only
    /// a leftover. Discarding that one costs the person nothing they said, so
    /// the confirmation may not borrow the finality of the sentence beside it.
    let discardKeepsRecordingInWork: Bool
    /// Delete the reserved recording.
    let onDiscardConfirmed: () -> Void
    /// Hand the reservation back untouched. Cancelling must cost the next tap —
    /// here, in the menu bar, or in a Shortcut — nothing at all.
    let onDiscardCancelled: () -> Void

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

            // What Retry does NOT say: that there is more than one of these.
            // The button takes the newest, so a card that stays up afterwards
            // has to have said why in advance.
            if pendingCount > 1 {
                Text(String(
                    localized: "pendingRetry.card.count",
                    defaultValue: "\(pendingCount) recordings waiting"
                ))
                .font(.caption2)
                .foregroundStyle(AppColors.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let retryErrorMessage {
                Text(retryErrorMessage)
                    .font(.caption2)
                    .foregroundStyle(AppColors.sunsetOrange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            HStack(spacing: 16) {
                // "Get help" affordance beneath Retry — the home-screen sibling
                // of the conversation banner's Troubleshoot button, shown only
                // when the failure has a code Diagnostics can help with.
                if let troubleshootFocus {
                    TroubleshootButton(focus: troubleshootFocus)
                }

                Button(role: .destructive) {
                    onDiscard()
                } label: {
                    Text(String(
                        localized: "pendingRetry.card.discard",
                        defaultValue: "Discard recording"
                    ))
                    .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(AppColors.textSecondary)
                .disabled(isRetrying)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .glassCardBackground(borderColor: AppColors.sunsetOrange.opacity(0.4))
        .confirmationDialog(
            String(
                localized: "pendingRetry.card.discard.confirm.title",
                defaultValue: "Discard this recording?"
            ),
            isPresented: $confirmingDiscard,
            titleVisibility: .visible
        ) {
            Button(
                String(
                    localized: "pendingRetry.card.discard.confirm.action",
                    defaultValue: "Discard"
                ),
                role: .destructive
            ) {
                onDiscardConfirmed()
            }
            Button(
                String(localized: "common.cancel", defaultValue: "Cancel"),
                role: .cancel
            ) {
                onDiscardCancelled()
            }
        } message: {
            Text(discardMessage)
        }
    }

    /// What the discard actually costs, which is not the same sentence for
    /// every waiting capture.
    ///
    /// A Chat capture, and a Work capture whose words never landed, exist only
    /// in the retry queue: discarding one deletes the only copy of what somebody
    /// said, and nothing reclaims it. That is the sentence below.
    ///
    /// The sibling is for a capture whose words ARE on the desk and whose entry
    /// is holding only what is left over — the recording, when a death landed
    /// between the words card and the clear, or the screenshot, when the
    /// recording was retired the moment the words landed. Telling that person
    /// their words cannot be recovered is false, and false in the direction that
    /// stops them tidying up. It may not say the recording is in Work either: no
    /// recording is ever on the desk.
    private var discardMessage: String {
        guard discardKeepsRecordingInWork else {
            return String(
                localized: "pendingRetry.card.discard.confirm.body",
                defaultValue: """
                    This deletes the recording from this device. It cannot be \
                    recovered.
                    """
            )
        }
        return String(
            localized: "pendingRetry.card.discard.confirm.body.published",
            defaultValue: """
                Your words are already on your desk. This removes only the \
                leftover copy this device kept.
                """
        )
    }
}
