// Conduck
// AppleSpeechTestSection.swift
//
// The "Try voice" section of the Apple provider detail (iOS + macOS): a live
// record → transcribe → show-the-transcript test, replacing the hollow "Test
// Connection → Connected" (an on-device, keyless provider is ALWAYS connected,
// so the only meaningful proof is to speak and see what Apple heard). It is the
// STT analogue of the TTS "Speak a sample" button, and it doubles as the A/B
// loop: switch engines above, re-record, feel the accuracy difference.
//
// All state lives in `SettingsViewModel.appleSpeechTester` (`AppleSpeechTester`),
// which records via the shared `AudioRecorder`, transcribes through
// `AppleSpeechRunner` with the EXPLICIT selected engine, and never persists the
// audio/transcript. The elapsed timer ticks inside the leaf
// `LiveRecordingStatusIndicator` (`TimelineView`), so the tester's observed
// `state` stays stable during a capture.
//
// `#if !os(watchOS)` — depends on the non-watch `appleSpeechTester`.

#if !os(watchOS)

import SwiftUI

struct AppleSpeechTestSection: View {
    @Bindable var viewModel: SettingsViewModel

    /// True when the CLAMPED active engine's model is installed and a test can run
    /// now — both engines (Standard included) must be ready, so the test honestly
    /// waits during a first-run "Preparing…" instead of firing into a cold model.
    private var canRecord: Bool {
        viewModel.appleTestCanRecord
    }

    var body: some View {
        Section {
            content
        } header: {
            Text(LocalizedStringResource("settings.voice.apple.test.header", defaultValue: "Try voice"))
        } footer: {
            Text(LocalizedStringResource(
                "settings.voice.apple.test.footer",
                defaultValue: "Uses the engine selected above and your speech language. Your recording isn't saved."
            ))
        }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.appleSpeechTester.state {
        case .idle:
            recordButton(label: LocalizedStringResource(
                "settings.voice.apple.test.record", defaultValue: "Record a test"))
        case .recording(let startedAt):
            recordingControls(startedAt: startedAt)
        case .transcribing:
            TranscribingIndicator()
        case .result(let text, let engine):
            resultView(text: text, engine: engine)
        case .failed(let message):
            failedView(message: message)
        }
    }

    // MARK: - Record / Record again

    private func recordButton(label: LocalizedStringResource) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                Task {
                    await viewModel.appleSpeechTester.start(
                        engine: viewModel.effectiveAppleEngine,
                        language: viewModel.preferredLanguage
                    )
                }
            } label: {
                Label(label, systemImage: "mic")
                    .font(.subheadline.weight(.semibold))
                    .labelStyle(AccentGlyphActionLabelStyle())
            }
            .buttonStyle(.bordered)
            .disabled(!canRecord)

            if !canRecord {
                Text(LocalizedStringResource(
                    "settings.voice.apple.test.needsModel",
                    defaultValue: "Setting up voice for this language — try again in a moment."
                ))
                .font(.caption)
                .foregroundStyle(AppColors.textTertiary)
            }
        }
    }

    // MARK: - Recording (live timer + Stop)

    private func recordingControls(startedAt: Date) -> some View {
        HStack(alignment: .center, spacing: 12) {
            LiveRecordingStatusIndicator(startedAt: startedAt)
            Spacer()
            Button(role: .destructive) {
                Task { await viewModel.appleSpeechTester.stop() }
            } label: {
                Label(
                    LocalizedStringResource("settings.voice.apple.test.stop", defaultValue: "Stop"),
                    systemImage: "stop.fill"
                )
                .font(.subheadline.weight(.semibold))
            }
            .buttonStyle(.bordered)
        }
    }

    // MARK: - Result

    private func resultView(text: String, engine: AppleOnDeviceEngineMode) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(LocalizedStringResource(
                        "settings.voice.apple.test.heard", defaultValue: "Apple heard"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AppColors.textTertiary)
                    Text(verbatim: "·")
                        .font(.caption)
                        .foregroundStyle(AppColors.textTertiary)
                    Text(engineCaption(engine))
                        .font(.caption)
                        .foregroundStyle(AppColors.textTertiary)
                }
                Text(verbatim: "“\(text)”")
                    .font(.body)
                    .foregroundStyle(AppColors.textPrimary)
                    .multilineTextAlignment(.leading)
                    .textSelection(.enabled)
            }
            recordButton(label: LocalizedStringResource(
                "settings.voice.apple.test.recordAgain", defaultValue: "Record again"))
        }
    }

    private func engineCaption(_ engine: AppleOnDeviceEngineMode) -> String {
        switch engine {
        case .dictation:
            return String(localized: LocalizedStringResource(
                "settings.voice.apple.test.via.standard", defaultValue: "via Standard"))
        case .highQuality:
            return String(localized: LocalizedStringResource(
                "settings.voice.apple.test.via.highQuality", defaultValue: "via High quality"))
        }
    }

    // MARK: - Failure

    private func failedView(message: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(AppColors.error)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(AppColors.error)
                    .multilineTextAlignment(.leading)
            }
            recordButton(label: LocalizedStringResource(
                "settings.voice.apple.test.recordAgain", defaultValue: "Record again"))
        }
    }
}

#endif // !os(watchOS)
