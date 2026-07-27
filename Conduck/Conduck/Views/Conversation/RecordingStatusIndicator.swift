// SPDX-License-Identifier: Apache-2.0

// Conduck
// RecordingStatusIndicator.swift
//
// Shared, surface-agnostic "you are recording" affordance: a pulsing red dot
// (`AppColors.error`, opacity 1.0↔0.3) + an `mm:ss` monospaced elapsed label,
// with an optional "1 min left" warning row. Pure SwiftUI + `AppColors` only —
// no recorder / service dependency, no `#if os` — so the iPhone/iPad composer,
// the macOS popover footer, and the macOS window composer all render the SAME
// dot+timer treatment. Each surface keeps its own Stop control + outer layout;
// only the dot/timer is shared (the reference look is the macOS popover's
// `recordingFooter`).
//
// Inputs are values, not bindings: `elapsed` (seconds the recording has run)
// and `nearMaxDuration` (true once within the soft-warning window of the max
// recording cap — drives the warning row + amber timer tint).

import SwiftUI

struct RecordingStatusIndicator: View {
    /// Seconds elapsed since recording began — formatted as `mm:ss`.
    let elapsed: TimeInterval
    /// True once within the soft-warning window of the max recording cap.
    /// Amber-tints the timer and surfaces the "1 min left" row.
    var nearMaxDuration: Bool = false

    @State private var isPulsing = false

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 8) {
                Circle()
                    .fill(AppColors.error)
                    .frame(width: 9, height: 9)
                    .opacity(isPulsing ? 1.0 : 0.3)
                    .animation(
                        .easeInOut(duration: 0.8).repeatForever(autoreverses: true),
                        value: isPulsing
                    )
                Text(formattedTime)
                    .font(.system(size: 16, weight: .light, design: .monospaced))
                    .foregroundStyle(nearMaxDuration ? AppColors.warning : AppColors.textPrimary)
                    .contentTransition(.numericText())
            }

            // Always present (reserves its height) but hidden until near the cap,
            // so the banner's geometry stays CONSTANT across the whole capture —
            // no single reflow when the warning appears. Keeps the recording
            // surface rock-stable (defense in depth atop the timer decoupling).
            Text(String(localized: LocalizedStringResource(
                "recording.oneMinuteLeft",
                defaultValue: "1 min left"
            )))
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(AppColors.warning)
            .opacity(nearMaxDuration ? 1 : 0)
            .accessibilityHidden(!nearMaxDuration)
        }
        .onAppear { isPulsing = true }
        .onDisappear { isPulsing = false }
        .accessibilityElement(children: .combine)
    }

    private var formattedTime: String {
        let totalSeconds = Int(max(0, elapsed))
        return String(format: "%d:%02d", totalSeconds / 60, totalSeconds % 60)
    }
}

// MARK: - Live (self-ticking) variant

/// Self-ticking wrapper around `RecordingStatusIndicator` for the in-app composer
/// mic. Owns its OWN per-second `TimelineView`, keyed off the capture's start
/// instant, so the recorder's observed `state` can stay STABLE during a capture
/// (`.recording(startedAt:)`) instead of re-publishing a fresh elapsed 10×/sec.
/// Only this leaf re-renders each second — the composer body and the chat pane it
/// sits beside no longer re-evaluate, which is what was driving the macOS
/// layout-recursion freeze. The duration cap is enforced by
/// `AVAudioRecorder.record(forDuration:)`; this is display only, so `elapsed` is
/// clamped (wall-clock can jump backward/forward). Mirrors the existing
/// `TimelineView` pattern in `ConversationThreadView`'s "thinking" clock.
struct LiveRecordingStatusIndicator: View {
    /// The capture's start instant.
    let startedAt: Date

    var body: some View {
        TimelineView(.periodic(from: startedAt, by: 1)) { context in
            let elapsed = max(0, min(
                context.date.timeIntervalSince(startedAt),
                Constants.maxAudioDuration
            ))
            RecordingStatusIndicator(
                elapsed: elapsed,
                nearMaxDuration: elapsed >= Constants.maxAudioDuration - Constants.maxAudioDurationWarningOffset
            )
        }
    }
}

// MARK: - Transcribing indicator (Part 2b)

/// The "we're transcribing your speech" affordance shown the instant capture
/// stops (recording → processing): a small spinner + a localized "Transcribing…"
/// label. Surface-agnostic (no `#if os`) so the iPhone/iPad composer and the
/// macOS window composer crossfade the SAME row in from `RecordingStatusIndicator`.
/// The crossfade transition + Reduce-Motion gating live at each call site (which
/// owns the recording↔processing animation), so this view is pure presentation.
struct TranscribingIndicator: View {
    var body: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text(String(localized: LocalizedStringResource(
                "recording.transcribing",
                defaultValue: "Transcribing…"
            )))
            .font(.system(size: 13))
            .foregroundStyle(AppColors.textSecondary)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Preparing-voice indicator (mic self-heal — Workstream A)

/// The CALM "we're setting up on-device voice" affordance shown when the Apple
/// model self-heal kicks in (recording → preparingVoice): a quiet "Setting up
/// voice…" label with an UNOBTRUSIVE spinner. The label is the hero — progress is
/// NOT — so this stays visually consistent with `TranscribingIndicator` rather
/// than turning into a download UI. A determinate bar only appears once the
/// download reports a fraction AND it's clearly taking more than a moment
/// (`progress` past a small floor); otherwise an indeterminate spinner keeps the
/// moment quiet. Surface-agnostic (no `#if os`) so iOS + macOS composers render
/// the SAME row and crossfade it like the transcribing one.
struct PreparingVoiceIndicator: View {
    /// `nil` = indeterminate (request spin-up); `0…1` once the download reports.
    let progress: Double?

    /// Only surface the determinate bar once the download has clearly begun —
    /// a sub-floor fraction (or a near-instant install) stays a quiet spinner so
    /// the calm label leads. 0.02 ≈ "more than a flicker of progress."
    private var showsDeterminateBar: Bool {
        if let progress { return progress > 0.02 && progress < 1 }
        return false
    }

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                if showsDeterminateBar {
                    // Determinate, but small — sits BELOW the label as the
                    // secondary cue (see the bar row), so here just the label.
                    Text(label)
                        .font(.system(size: 13))
                        .foregroundStyle(AppColors.textSecondary)
                } else {
                    ProgressView()
                        .controlSize(.small)
                    Text(label)
                        .font(.system(size: 13))
                        .foregroundStyle(AppColors.textSecondary)
                }
            }

            if showsDeterminateBar, let progress {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .tint(AppColors.brandAmber)
                    .frame(maxWidth: 180)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var label: String {
        String(localized: LocalizedStringResource(
            "recording.preparingVoice",
            defaultValue: "Setting up voice…"
        ))
    }
}

// MARK: - Voice hard-failure recovery (Workstream A — A4)

/// The ONE contextual recovery a chat host offers after a GENUINE voice hard
/// failure (the language isn't supported on-device, or the model self-heal
/// couldn't complete). NOT shown for the missing-model case — that self-heals
/// upstream in `InAppAudioRecorder`. The host resolves which arm applies (cloud
/// key present vs not) and owns the action; this is the user-tapped affordance
/// only — never an automatic teleport.
enum VoiceRecoveryOption: Equatable {
    /// A cloud STT provider is already configured (a cloud preset has a key) —
    /// "Use cloud voice" switches the active preset to it (`presetID`).
    case useCloud(presetID: String)
    /// No cloud key configured — "Open Voice Settings" (user-initiated).
    case openVoiceSettings

    var buttonTitle: String {
        switch self {
        case .useCloud:
            return String(localized: LocalizedStringResource(
                "voice.recovery.useCloud",
                defaultValue: "Use cloud voice"
            ))
        case .openVoiceSettings:
            return String(localized: LocalizedStringResource(
                "voice.recovery.openSettings",
                defaultValue: "Open Voice Settings"
            ))
        }
    }
}

/// A single, calm recovery button rendered by a chat host below the composer's
/// inline error banner when a voice hard failure leaves a contextual next step.
/// Pure presentation — the host owns the `option` resolution + the `action`.
struct VoiceRecoveryButton: View {
    let option: VoiceRecoveryOption
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(option.buttonTitle)
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppColors.brandAmber)
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .accessibilityLabel(option.buttonTitle)
    }
}
