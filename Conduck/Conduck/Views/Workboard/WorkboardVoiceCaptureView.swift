// SPDX-License-Identifier: Apache-2.0

// Conduck
// WorkboardVoiceCaptureView.swift
//
// Explicit, interactive voice capture for the Work desk. It reuses Conduck's
// existing mic/STT state machine (including permission, on-device model
// self-heal, selected-provider routing, retry preservation and duration cap).
// The recorder publishes the recording as a playable card BEFORE the speech
// hop, so a transcription that fails costs the words and never the audio; the
// transcript is then written onto that same card. A capture that stopped part
// way is finished by Try Again — the same card, the same bytes — and only the
// separately labelled Record Again starts a second one. Nothing here reaches a
// gateway.

#if !os(watchOS)

import SwiftUI

struct WorkboardVoiceCaptureView: View {
    let target: WorkboardVoiceTarget
    let onTranscript: @MainActor (String) -> Void
    let onCancel: @MainActor () -> Void

    // A transcription retry must return to inert Work capture. The recorder's
    // default remains Chat for the established conversation composers.
    @State private var recorder = InAppAudioRecorder(retryDestination: .work)
    @State private var didStart = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    statusGlyph
                    statusCopy
                    controls
                    privacyCopy
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 20)
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
            }
            .background(AppColors.background.ignoresSafeArea())
            .navigationTitle(target.title)
            .workboardInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(LocalizedStringResource("common.cancel", defaultValue: "Cancel")) {
                        cancel()
                    }
                }
            }
        }
        .interactiveDismissDisabled(isBusy)
        .onChange(of: accessibilityStatusID) { _, _ in
            AccessibilityAnnouncer.announce(accessibilityStatusMessage)
        }
        .task {
            guard !didStart else { return }
            didStart = true
            recorder.onAutoStopResult = { result in
                handle(result)
            }
            await recorder.startRecording()
        }
        .onDisappear {
            switch recorder.state {
            case .recording:
                recorder.cancelRecording()
            case .processing, .preparingVoice:
                recorder.cancelProcessing()
            case .idle, .error:
                break
            }
        }
    }

    @ViewBuilder
    private var statusGlyph: some View {
        ZStack {
            Circle()
                .fill(glyphBackground)
                .frame(width: 112, height: 112)
            switch recorder.state {
            case .processing, .preparingVoice:
                ProgressView()
                    .controlSize(.large)
                    .tint(AppColors.background)
            case .error:
                Image(systemName: "exclamationmark.waveform.fill")
                    .font(.system(size: 38, weight: .semibold))
                    .foregroundStyle(AppColors.background)
            case .idle, .recording:
                Image(systemName: "waveform")
                    .font(.system(size: 40, weight: .semibold))
                    .foregroundStyle(AppColors.background)
                    .symbolEffect(.variableColor.iterative, isActive: isRecording && !reduceMotion)
            }
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var statusCopy: some View {
        VStack(spacing: 8) {
            switch recorder.state {
            case .idle:
                Text(LocalizedStringResource(
                    "workboard.voice.starting",
                    defaultValue: "Starting the microphone…"
                ))
            case .recording(let startedAt):
                Text(LocalizedStringResource(
                    "workboard.voice.listening",
                    defaultValue: "Listening"
                ))
                .font(.title2.weight(.semibold))
                TimelineView(.periodic(from: startedAt, by: 1)) { context in
                    let elapsed = max(0, min(
                        context.date.timeIntervalSince(startedAt),
                        Constants.maxAudioDuration
                    ))
                    // The recorder hard-stops at the cap, so the same warning
                    // window Chat shows has to reach this sheet too.
                    let isNearCap = elapsed
                        >= Constants.maxAudioDuration - Constants.maxAudioDurationWarningOffset
                    VStack(spacing: 4) {
                        Text(Self.elapsed(elapsed))
                            .font(.system(.title3, design: .monospaced, weight: .medium))
                            .foregroundStyle(isNearCap ? AppColors.warning : AppColors.textSecondary)
                            .accessibilityLabel(Text(LocalizedStringResource(
                                "workboard.voice.elapsed",
                                defaultValue: "Recording time"
                            )))
                            .accessibilityValue(Text(verbatim: Self.elapsed(elapsed)))
                        Text(LocalizedStringResource(
                            "recording.oneMinuteLeft",
                            defaultValue: "1 min left"
                        ))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(AppColors.warning)
                        .opacity(isNearCap ? 1 : 0)
                        .accessibilityHidden(!isNearCap)
                    }
                }
            case .processing:
                Text(LocalizedStringResource(
                    "workboard.voice.transcribing",
                    defaultValue: "Turning speech into text…"
                ))
                .font(.title3.weight(.semibold))
            case .preparingVoice(let progress):
                Text(LocalizedStringResource(
                    "workboard.voice.preparing",
                    defaultValue: "Preparing on-device voice…"
                ))
                .font(.title3.weight(.semibold))
                if let progress {
                    ProgressView(value: progress)
                        .frame(maxWidth: 260)
                        .tint(AppColors.brandAmber)
                }
            case .error(let error):
                Text(LocalizedStringResource(
                    "workboard.voice.error.title",
                    defaultValue: "Voice capture stopped"
                ))
                .font(.title3.weight(.semibold))
                Text(verbatim: error.localizedDescription)
                    .font(.subheadline)
                    .foregroundStyle(AppColors.textSecondary)
                    .multilineTextAlignment(.center)
            }
        }
        .foregroundStyle(AppColors.textPrimary)
        .multilineTextAlignment(.center)
    }

    @ViewBuilder
    private var controls: some View {
        switch recorder.state {
        case .recording:
            Button {
                Task { handle(await recorder.stopAndUpload()) }
            } label: {
                Label(
                    LocalizedStringResource("workboard.voice.stop", defaultValue: "Stop and Save"),
                    systemImage: "stop.fill"
                )
                .font(.headline)
                .frame(maxWidth: .infinity, minHeight: 52)
            }
            .buttonStyle(.borderedProminent)
            .tint(AppColors.brandAmber)
            .foregroundStyle(AppColors.background)
            .keyboardShortcut(.return, modifiers: .command)
        case .error(let error):
            if error.isRetryable {
                // Try Again finishes THIS capture — the recording it already
                // published, or the words it already recognized — and only
                // starts a new one when there is nothing left to finish.
                // Recording again is the separate action, because it leaves the
                // first card on the desk without its words and puts a second
                // one beside it.
                Button {
                    if recorder.canRetryWorkCapture {
                        Task { handle(await recorder.retryWorkCapture()) }
                    } else {
                        recorder.dismissError()
                        Task { await recorder.startRecording() }
                    }
                } label: {
                    Label(
                        LocalizedStringResource("workboard.voice.tryAgain", defaultValue: "Try Again"),
                        systemImage: "arrow.counterclockwise"
                    )
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 50)
                }
                .buttonStyle(.borderedProminent)
                .tint(AppColors.brandAmber)
                if recorder.canRetryWorkCapture {
                    Button {
                        recorder.dismissError()
                        Task { await recorder.startRecording() }
                    } label: {
                        Label(
                            LocalizedStringResource(
                                "workboard.voice.recordAgain",
                                defaultValue: "Record Again"
                            ),
                            systemImage: "mic.fill"
                        )
                        .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.bordered)
                }
            } else {
                Button(LocalizedStringResource("common.close", defaultValue: "Close")) {
                    cancel()
                }
                .buttonStyle(.borderedProminent)
                .tint(AppColors.brandAmber)
            }
        case .processing, .preparingVoice:
            Button(LocalizedStringResource(
                "workboard.voice.cancelTranscription",
                defaultValue: "Cancel Transcription"
            )) {
                recorder.cancelProcessing()
            }
            .buttonStyle(.bordered)
        case .idle:
            EmptyView()
        }
    }

    /// The sheet's privacy line. Two promises it may not make. It may not
    /// promise that nothing is sent: the words come from whichever speech
    /// provider the person configured, and `STTClient`'s table is mostly cloud
    /// vendors, so the recording leaves the device on every configuration
    /// except Apple's on-device engine. And it may not promise that the audio
    /// never reaches an AI: `STTProvider.openAI` is `gpt-4o-transcribe`,
    /// `STTProvider.gemini` is a Gemini model, and a custom OpenAI-compatible
    /// endpoint can be anything the person points it at — several selectable
    /// providers ARE AI models, some of them the same vendor serving the
    /// person's chat. What holds is the boundary the desk actually enforces:
    /// one destination, chosen by the person, used only for transcription, and
    /// no server of ours behind it.
    private var privacyCopy: some View {
        Label(
            LocalizedStringResource(
                "workboard.voice.privacy",
                defaultValue: "Keeps the recording on your private desk and adds the words when they’re ready. The audio goes only to the speech provider you chose, and only to be turned into words — never into a conversation, and never through a server of ours."
            ),
            systemImage: "lock.shield"
        )
        .font(.caption)
        .foregroundStyle(AppColors.textTertiary)
        .multilineTextAlignment(.center)
        .padding(.bottom, 4)
    }

    private var isRecording: Bool {
        if case .recording = recorder.state { return true }
        return false
    }

    private var isBusy: Bool {
        switch recorder.state {
        case .recording, .processing, .preparingVoice: return true
        case .idle, .error: return false
        }
    }

    private var glyphBackground: Color {
        if case .error = recorder.state { return AppColors.error }
        return AppColors.brandAmber
    }

    private var accessibilityStatusID: String {
        switch recorder.state {
        case .idle: return "idle"
        case .recording: return "recording"
        case .processing: return "processing"
        case .preparingVoice: return "preparing"
        case .error(let error): return "error-\(error.errorCode)"
        }
    }

    private var accessibilityStatusMessage: String {
        switch recorder.state {
        case .idle:
            return String(localized: "workboard.voice.starting", defaultValue: "Starting the microphone…")
        case .recording:
            return String(localized: "workboard.voice.listening", defaultValue: "Listening")
        case .processing:
            return String(localized: "workboard.voice.transcribing", defaultValue: "Turning speech into text…")
        case .preparingVoice:
            return String(localized: "workboard.voice.preparing", defaultValue: "Preparing on-device voice…")
        case .error(let error):
            return String.localizedStringWithFormat(
                String(
                    localized: "workboard.voice.error.accessibility",
                    defaultValue: "Voice capture stopped. %@"
                ),
                error.localizedDescription
            )
        }
    }

    private func handle(_ result: Result<String, AppError>) {
        switch result {
        case .success(let transcript):
            // The recording is already a card on the desk and the transcript is
            // already written onto it, so handing the same words to the
            // composer would put one utterance on the board twice. `onCancel`
            // is this sheet's only dismissal hook. The composer is reached only
            // when the capture turned out to own no recording at all — a
            // storage failure is an error state, not a success, so it never
            // arrives here.
            if recorder.workRecordingMaterialID != nil {
                onCancel()
            } else {
                onTranscript(transcript)
            }
        case .failure:
            // The recorder already owns the typed error state and retry lane,
            // and the recording it published before transcribing stands on the
            // desk either way.
            break
        }
    }

    private func cancel() {
        switch recorder.state {
        case .recording: recorder.cancelRecording()
        case .processing, .preparingVoice: recorder.cancelProcessing()
        case .idle, .error: break
        }
        onCancel()
    }

    /// Same `m:ss` shape the shared `RecordingStatusIndicator` renders, so one
    /// capture never reads differently in Work than it does in a conversation.
    private static func elapsed(_ interval: TimeInterval) -> String {
        let seconds = Int(max(0, interval))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

#endif
