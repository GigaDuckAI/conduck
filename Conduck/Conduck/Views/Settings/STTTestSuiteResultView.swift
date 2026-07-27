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
//     (passed), red x (failed), amber TOFU lock (skipped/untrusted-cert) —
//     plus the stage's key-free detail line.
//   - A monospaced "Heard:" card with the server's transcript and the expected
//     phrase beneath, once stage ③ produced text.
//   - A latency line once the round-trip completed.
//   - The reused "Trust & Save" affordance when an untrusted self-signed cert
//     is pending (iOS only — the gateway TOFU convention).
//
// Platform-neutral; UIKit-only modifiers are `#if os(iOS)`-gated. On macOS
// (no TOFU banner) the untrusted-cert stage is presented as `.failed` with a
// "pin under Advanced" hint, matching the gateway convention.
//
// Privacy: the ONLY transcript shown is the bundled known phrase; stage
// details are taxonomy-derived and never carry the key, URL, or user audio.

import SwiftUI

struct STTTestSuiteResultView: View {
    let result: STTTestSuiteResult

    /// "Trust & Save" callback — fired from the iOS TOFU affordance when the
    /// run skipped on an untrusted self-signed cert. nil → no affordance (e.g.
    /// a built-in provider's "Run full test", which never pins).
    var onTrustAndSave: (() -> Void)? = nil

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

            if result.pendingUntrustedCertFingerprint != nil {
                trustAffordance
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
            // Amber TOFU glyph — the server isn't proven broken; the user can
            // trust the self-signed cert to continue.
            Image(systemName: "lock.trianglebadge.exclamationmark")
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

    /// The per-stage detail string. On macOS, a `.skipped` reachability stage
    /// (untrusted cert) is rewritten to a "pin under Advanced" hint since there
    /// is no TOFU banner — matching the gateway convention.
    private func detailText(for stage: STTTestStageResult) -> String? {
        switch stage.status {
        case .failed(let reason):
            return reason
        case .skipped(let reason):
            #if os(macOS)
            if stage.stage == .reachability, result.pendingUntrustedCertFingerprint != nil {
                return String(localized: "stt.test.macUntrustedCert.hint",
                              defaultValue: "Self-signed certificate. Pin its fingerprint under Advanced to continue.")
            }
            #endif
            return reason
        case .passed:
            return stage.detail
        case .pending, .running:
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

    // MARK: - Trust & Save (iOS TOFU)

    @ViewBuilder
    private var trustAffordance: some View {
        #if os(iOS)
        if let fp = result.pendingUntrustedCertFingerprint, let onTrustAndSave {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "lock.trianglebadge.exclamationmark")
                        .foregroundStyle(AppColors.warning)
                    Text(LocalizedStringResource("stt.test.tofu.title",
                                                 defaultValue: "Untrusted certificate"))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AppColors.textPrimary)
                }
                if fp.isEmpty {
                    Text(LocalizedStringResource(
                        "stt.test.tofu.noFingerprint",
                        defaultValue: "This server uses a self-signed certificate with an unsupported key type. Pin it manually under Advanced, or use a publicly-trusted certificate."
                    ))
                        .font(.caption)
                        .foregroundStyle(AppColors.textSecondary)
                } else {
                    Text(LocalizedStringResource(
                        "stt.test.tofu.body",
                        defaultValue: "This server uses a self-signed certificate. Trust it once to pin its fingerprint on this device."
                    ))
                        .font(.caption)
                        .foregroundStyle(AppColors.textSecondary)
                    Text(fp)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(AppColors.textTertiary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                    Button {
                        onTrustAndSave()
                    } label: {
                        Label(
                            LocalizedStringResource("stt.test.tofu.trustButton", defaultValue: "Trust & Save"),
                            systemImage: "checkmark.shield.fill"
                        )
                        .font(.subheadline.weight(.semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(AppColors.brandAmber)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(AppColors.warning.opacity(0.10))
            )
        }
        #else
        // macOS: no TOFU banner — the untrusted-cert stage detail already
        // carries the "pin under Advanced" hint (see `detailText`).
        EmptyView()
        #endif
    }
}
