// SPDX-License-Identifier: Apache-2.0

// Conduck
// CloudSTTTestSection.swift
//
// The "Record a test" surface for a CLOUD STT provider (Mistral / OpenAI /
// ElevenLabs / Gemini / OpenRouter), injected into the Speech-to-Text section of
// the provider detail (iOS `VoiceProviderDetailView` + macOS `MacVoiceVendorDetail`).
// It REPLACES the old "Test Connection" cheap key-check in that section: a real
// record → transcribe → show-the-transcript audition proves the key works AND
// shows quality on the user's own voice. The cheap key check still lives in
// Provider Access → "Validate & Save". This makes the cloud screen mirror Apple's
// `AppleSpeechTestSection` (which is itself the STT analogue of TTS "Speak a
// sample").
//
// All state lives in `SettingsViewModel.cloudSTTTester` (`CloudSTTTester`), which
// records via the shared `AudioRecorder`, transcribes over the network through
// `STTClient.transcribe` for the DISPLAYED provider, and never persists the
// audio/transcript. The elapsed timer ticks inside the leaf
// `LiveRecordingStatusIndicator` (`TimelineView`), so the tester's observed
// `state` stays stable during a capture.
//
// This is a plain content view (NOT its own `Section`) — it's mounted inside the
// existing "Speech-to-Text" `Section` via `ProviderConfigBody`'s record-test slot,
// so the section keeps its recommended-model line above and "Advanced" below.
//
// `#if !os(watchOS)` — depends on the non-watch `cloudSTTTester`.

#if !os(watchOS)

import SwiftUI

struct CloudSTTTestSection: View {
    @Bindable var viewModel: SettingsViewModel
    /// The STT preset id of the provider this screen configures (e.g. the
    /// Mistral / OpenAI slot). Drives the provider-scoped transcription.
    let presetID: String
    /// The provider's display name — for the record label and error copy.
    let providerName: String

    var body: some View {
        switch viewModel.cloudSTTTester.state {
        case .idle:
            recordButton(label: LocalizedStringResource(
                "settings.voice.cloudTest.record", defaultValue: "Record a test"))
        case .recording(let startedAt):
            recordingControls(startedAt: startedAt)
        case .transcribing:
            TranscribingIndicator()
        case .result(let text):
            resultView(text: text)
        case .failed(let message):
            failedView(message: message)
        }
    }

    // MARK: - Record / Record again

    private func recordButton(label: LocalizedStringResource) -> some View {
        Button {
            Task {
                await viewModel.cloudSTTTester.start(
                    presetID: presetID,
                    providerName: providerName,
                    language: viewModel.preferredLanguage,
                    customModel: viewModel.customModels[presetID]
                )
            }
        } label: {
            Label(label, systemImage: "mic")
                .font(.subheadline.weight(.semibold))
                .labelStyle(AccentGlyphActionLabelStyle())
        }
        .buttonStyle(.bordered)
    }

    // MARK: - Recording (live timer + Stop)

    private func recordingControls(startedAt: Date) -> some View {
        HStack(alignment: .center, spacing: 12) {
            LiveRecordingStatusIndicator(startedAt: startedAt)
            Spacer()
            Button(role: .destructive) {
                Task { await viewModel.cloudSTTTester.stop() }
            } label: {
                Label(
                    LocalizedStringResource("settings.voice.cloudTest.stop", defaultValue: "Stop"),
                    systemImage: "stop.fill"
                )
                .font(.subheadline.weight(.semibold))
            }
            .buttonStyle(.bordered)
        }
    }

    // MARK: - Result

    private func resultView(text: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(LocalizedStringResource(
                    "settings.voice.cloudTest.heard", defaultValue: "Heard"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppColors.textTertiary)
                Text(verbatim: "“\(text)”")
                    .font(.body)
                    .foregroundStyle(AppColors.textPrimary)
                    .multilineTextAlignment(.leading)
                    .textSelection(.enabled)
            }
            recordButton(label: LocalizedStringResource(
                "settings.voice.cloudTest.recordAgain", defaultValue: "Record again"))
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
                "settings.voice.cloudTest.recordAgain", defaultValue: "Record again"))
        }
    }
}

#endif // !os(watchOS)
