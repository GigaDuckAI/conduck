// SPDX-License-Identifier: Apache-2.0

// Conduck
// STTTestSuiteResultView.swift
//
// Custom STT — Feature 3 — the rich staged Test Connection checklist, dropped
// into the Form on both the iOS provider detail and the macOS row via
// `ProviderConfigBody`. Renders an `STTTestSuiteResult`:
//
//   - One row per stage (reachability / auth / transcription) with a status
//     glyph — hollow circle (pending), spinner (running), green check
//     (passed), red x (failed), amber dash (skipped — an earlier stage blocked
//     it) — plus the stage's key-free detail line.
//   - A monospaced "Heard:" card with the server's transcript and the expected
//     phrase beneath, once stage ③ produced text.
//   - A latency line once the round-trip completed.
//
// Read-only by construction: every outcome the suite can produce is either a
// pass or a terminal explained failure, so this view offers no actions. A
// certificate the device rejects is one of those failures — the fix is on the
// server, and the stage reason names it.
//
// Platform-neutral — iOS and macOS render the identical checklist.
//
// Privacy: the ONLY transcript shown is the bundled known phrase; stage
// details are taxonomy-derived and never carry the key, URL, or user audio.

import SwiftUI

struct STTTestSuiteResultView: View {
    let result: STTTestSuiteResult

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(result.stages) { stage in
                stageRow(stage)
            }

            if let transcript = result.transcript {
                transcriptCard(transcript)
            }

            if let latency = result.latencyMS {
                latencyLine(latency)
            }
        }
    }

    // MARK: - Stage row

    @ViewBuilder
    private func stageRow(_ stage: STTTestStageResult) -> some View {
        HStack(alignment: .top, spacing: 10) {
            statusGlyph(for: stage.status)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(stageTitle(stage.stage))
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(AppColors.textPrimary)
                if let detail = detailText(for: stage) {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(detailColor(for: stage.status))
                        .multilineTextAlignment(.leading)
                }
            }
            Spacer()
        }
    }

    @ViewBuilder
    private func statusGlyph(for status: STTStageStatus) -> some View {
        switch status {
        case .pending:
            Image(systemName: "circle")
                .foregroundStyle(AppColors.textTertiary)
        case .running:
            ProgressView().controlSize(.small)
        case .passed:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(AppColors.success)
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(AppColors.error)
        case .skipped:
            // Amber dash — this stage never ran, so it says nothing about the
            // server. The stage that DID fail is the one carrying the verdict.
            Image(systemName: "minus.circle")
                .foregroundStyle(AppColors.warning)
        }
    }

    private func stageTitle(_ stage: STTTestStage) -> LocalizedStringResource {
        switch stage {
        case .reachability:
            return LocalizedStringResource("stt.test.stage.reachability",
                                           defaultValue: "Reachability & TLS")
        case .auth:
            return LocalizedStringResource("stt.test.stage.auth",
                                           defaultValue: "Authentication")
        case .transcription:
            return LocalizedStringResource("stt.test.stage.transcription",
                                           defaultValue: "Transcription")
        }
    }

    /// The per-stage detail string — the suite's own key-free reason for a
    /// failed or skipped stage, the stage's detail otherwise.
    private func detailText(for stage: STTTestStageResult) -> String? {
        switch stage.status {
        case .failed(let reason), .skipped(let reason):
            return reason
        case .passed, .pending, .running:
            return stage.detail
        }
    }

    private func detailColor(for status: STTStageStatus) -> Color {
        switch status {
        case .failed:
            return AppColors.error
        case .skipped:
            return AppColors.warning
        default:
            return AppColors.textTertiary
        }
    }

    // MARK: - Transcript card

    private func transcriptCard(_ transcript: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(LocalizedStringResource("stt.test.heard.label", defaultValue: "Heard:"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppColors.textSecondary)
            Text(transcript)
                .font(.system(.subheadline, design: .monospaced))
                .foregroundStyle(AppColors.textPrimary)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(AppColors.cardBackgroundElevated)
                )
            Text(String(
                format: String(localized: "stt.test.expected.label",
                               defaultValue: "Expected: %@"),
                STTConnectionTestSuite.expectedPhrase
            ))
                .font(.caption2)
                .foregroundStyle(AppColors.textTertiary)
        }
    }

    // MARK: - Latency

    private func latencyLine(_ latencyMS: Int) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "timer")
                .font(.caption)
                .foregroundStyle(AppColors.textTertiary)
            Text(String(
                format: String(localized: "stt.test.latency.label",
                               defaultValue: "Round-trip: %lld ms"),
                latencyMS
            ))
                .font(.caption)
                .foregroundStyle(AppColors.textTertiary)
        }
    }
}
