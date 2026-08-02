// SPDX-License-Identifier: Apache-2.0

// Conduck
// AppleEngineModeSection.swift
//
// The on-device Apple "Speech Recognition" section, shown inside the Apple
// provider detail on iOS and macOS (the `metadata.isOnDevice` vendor). A
// SYMMETRIC two-option selector — two peer rows, "Standard" and "Higher
// accuracy" — each owning its own readiness state and a leading checkmark on
// the active engine (keyed off the CLAMPED `effectiveAppleEngine`, so a synced
// `.highQuality` choice on a sub-A16 device shows the check on Standard).
//
// There is NO standalone status line (each row IS its own status) and NO
// "Manage in Settings" affordance (it dead-ended on the app permissions page;
// iOS owns model storage). "Preparing…" is always a calm spinner — `.failed`
// (red) is reserved for a genuine setup failure, and the row itself is the
// retry (re-tap re-runs prepare / download). Rows are disabled while a "Try
// voice" capture is in flight so a tap can't yank the engine mid-recording.
//
// Standard readiness lives in `viewModel.appleStandardModelState` (prepared
// proactively — see `SettingsViewModel.prepareStandardEngine`); High quality
// keeps the existing per-language `appleModelStates` download ledger and is
// rendered ONLY on devices that support it (`appleHighQualityAvailable`, A16+).
//
// `#if !os(watchOS)` — references the high-quality engine + download lifecycle,
// neither of which compiles on watchOS (downstream-only surface).

#if !os(watchOS)

import SwiftUI

/// The "Speech Recognition" `Section` for the on-device Apple provider: two
/// peer engine rows, each with its own readiness state + active checkmark.
struct AppleEngineModeSection: View {
    @Bindable var viewModel: SettingsViewModel

    /// High-quality install state for the CURRENT language target.
    private var hqState: AppleModelInstallState {
        viewModel.appleModelStates[viewModel.appleTargetKey] ?? .notDownloaded
    }

    /// A "Try voice" capture in flight — freeze engine selection so a tap can't
    /// switch the model out from under the recorder/transcriber.
    private var testerBusy: Bool {
        switch viewModel.appleSpeechTester.state {
        case .recording, .transcribing: return true
        case .idle, .result, .failed: return false
        }
    }

    var body: some View {
        Section {
            standardRow
            // High quality — supported devices only (A16+). Hidden entirely below
            // the floor (no disabled "Not available" row).
            if viewModel.appleHighQualityAvailable {
                higherAccuracyRow
            }
        } header: {
            Text(LocalizedStringResource(
                "settings.voice.apple.engine.header.v2",
                defaultValue: "Speech Recognition"
            ))
        } footer: {
            Text(LocalizedStringResource(
                "settings.voice.apple.engine.footer",
                defaultValue: "Apple speech runs on this device. No API key, and nothing leaves your device."
            ))
        }
    }

    // MARK: - Standard row (the default; auto-prepared)

    private var standardRow: some View {
        Button {
            // Activate Standard; `selectStandardEngine` also (re)prepares the model,
            // so a re-tap of a `.failed` row IS the retry — no nested button.
            Task { await viewModel.selectStandardEngine() }
        } label: {
            engineRow(
                title: LocalizedStringResource(
                    "settings.voice.apple.engine.standard.label",
                    defaultValue: "Standard"
                ),
                active: viewModel.effectiveAppleEngine == .dictation,
                state: standardStateLine
            )
        }
        .settingsRowButton()
        .disabled(testerBusy)
    }

    @ViewBuilder
    private var standardStateLine: some View {
        switch viewModel.appleStandardModelState {
        case .installed:
            readyLine
        case .downloading, .notDownloaded:
            // Both render as a calm "Preparing…" — never a scary error.
            preparingLine
        case .failed(let message, let retryable):
            errorLine(message: message, retryable: retryable)
        }
    }

    // MARK: - Higher-accuracy row (A16+ only)

    private var higherAccuracyRow: some View {
        Button {
            // Tap = select / download / commit / retry — `selectHighQualityEngine`
            // is idempotent and already serves the retry path.
            Task { await viewModel.selectHighQualityEngine() }
        } label: {
            engineRow(
                title: LocalizedStringResource(
                    "settings.voice.apple.engine.higher.label",
                    defaultValue: "Higher accuracy"
                ),
                active: viewModel.effectiveAppleEngine == .highQuality,
                state: higherAccuracyStateLine
            )
        }
        .settingsRowButton()
        .disabled(testerBusy)
    }

    @ViewBuilder
    private var higherAccuracyStateLine: some View {
        switch hqState {
        case .installed:
            VStack(alignment: .leading, spacing: 1) {
                readyLine
                Text(LocalizedStringResource(
                    "settings.voice.apple.engine.higher.storage",
                    defaultValue: "~100 MB on this device"
                ))
                .font(.caption2)
                .foregroundStyle(AppColors.textTertiary)
            }
        case .downloading(let progress):
            if progress > 0 {
                HStack(spacing: 6) {
                    ProgressView(value: progress).tint(AppColors.brandAmber).frame(maxWidth: 120)
                    Text(LocalizedStringResource(
                        "settings.voice.apple.engine.state.preparing",
                        defaultValue: "Preparing…"
                    ))
                    .font(.caption)
                    .foregroundStyle(AppColors.textSecondary)
                }
            } else {
                preparingLine
            }
        case .notDownloaded:
            Text(LocalizedStringResource(
                "settings.voice.apple.engine.higher.download",
                defaultValue: "Download · ~100 MB"
            ))
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(AppColors.brandAmber)
        case .failed(let message, let retryable):
            errorLine(message: message, retryable: retryable)
        }
    }

    // MARK: - Shared row chrome

    private func engineRow(
        title: LocalizedStringResource,
        active: Bool,
        state: some View
    ) -> some View {
        HStack(spacing: 12) {
            // Leading amber checkmark on the active engine (reuses the picker look).
            Image(systemName: "checkmark")
                .font(.body.weight(.semibold))
                .foregroundStyle(AppColors.brandAmber)
                .opacity(active ? 1 : 0)
                .frame(width: 18, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).foregroundStyle(AppColors.textPrimary)
                state
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }

    private var readyLine: some View {
        HStack(spacing: 4) {
            Image(systemName: "checkmark.circle.fill")
                .font(.caption2)
                .foregroundStyle(AppColors.success)
            Text(LocalizedStringResource(
                "settings.voice.apple.engine.state.ready",
                defaultValue: "Ready"
            ))
            .font(.caption)
            .foregroundStyle(AppColors.textSecondary)
        }
    }

    private var preparingLine: some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.small)
            Text(LocalizedStringResource(
                "settings.voice.apple.engine.state.preparing",
                defaultValue: "Preparing…"
            ))
            .font(.caption)
            .foregroundStyle(AppColors.textSecondary)
        }
    }

    @ViewBuilder
    private func errorLine(message: String, retryable: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(AppColors.error)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(AppColors.error)
                    .multilineTextAlignment(.leading)
            }
            if retryable {
                // The row itself is the retry (re-tap) — no nested button.
                Text(LocalizedStringResource(
                    "settings.voice.apple.engine.state.tapRetry",
                    defaultValue: "Tap to try again"
                ))
                .font(.caption2)
                .foregroundStyle(AppColors.brandAmber)
            }
        }
    }
}

#endif // !os(watchOS)
