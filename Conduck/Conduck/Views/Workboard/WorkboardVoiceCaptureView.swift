// SPDX-License-Identifier: Apache-2.0

// Conduck
// WorkboardVoiceCaptureView.swift
//
// Explicit, interactive voice capture for the Work desk. It reuses Conduck's
// existing mic/STT state machine (including permission, on-device model
// self-heal, selected-provider routing, retry preservation and duration cap).
//
// THE WORDS ARE WHAT LANDS. The recorder parks the recording on this device
// before the speech hop and publishes the transcript as the card; the audio is
// deleted the moment those words are on the desk. So a transcription that fails
// leaves NOTHING on the board — the recording waits in the device-local retry
// queue, and the sheet's Try Again is what turns it into a card. Record Again,
// the separately labelled second action, hands that waiting recording back to
// the queue instead of ending it: it may be the only copy of what was said.
// Nothing here reaches a gateway.

#if !os(watchOS)

import SwiftUI

struct WorkboardVoiceCaptureView: View {
    let target: WorkboardVoiceTarget
    let onTranscript: @MainActor (String) -> Void
    let onCancel: @MainActor () -> Void

    // A transcription retry must return to inert Work capture. The recorder's
    // default remains Chat for the established conversation composers.
    @State private var recorder: InAppAudioRecorder
    private let onSavedInAllMaterials: @MainActor () -> Void

    init(
        target: WorkboardVoiceTarget,
        projectID: UUID? = nil,
        onTranscript: @escaping @MainActor (String) -> Void,
        onCancel: @escaping @MainActor () -> Void,
        onSavedInAllMaterials: @escaping @MainActor () -> Void = {}
    ) {
        self.target = target
        self.onTranscript = onTranscript
        self.onCancel = onCancel
        self.onSavedInAllMaterials = onSavedInAllMaterials
        // State owns this launch's recorder, including the frozen destination.
        // Re-rendering the sheet cannot retarget a recording already spoken.
        _recorder = State(initialValue: InAppAudioRecorder(
            retryDestination: .work, workProjectID: projectID
        ))
    }
    @State private var didStart = false
    /// True once "Cancel Transcription" has stopped a hop on this capture.
    ///
    /// The recorder answers a cancel with `.idle` and NO banner — deliberately,
    /// because nothing failed — and `.idle` is also the state this sheet opens
    /// in. Without a second reading the two are indistinguishable, so a stopped
    /// transcription rendered as "Starting the microphone…" beside no controls
    /// at all: a dead end over a capture that still had a Try Again in it.
    ///
    /// Cleared by the sheet's own start and by a capture that FINISHED, and by
    /// nothing else — least of all by the press that offers to finish it: that
    /// press can be refused, and a refusal leaves the recorder `.idle` with the
    /// stopped state as the only thing standing between it and the dead end.
    @State private var transcriptionStopped = false
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
            transcriptionStopped = false
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
                if transcriptionStopped {
                    Text(LocalizedStringResource(
                        "workboard.voice.stopped.title",
                        defaultValue: "Transcription stopped"
                    ))
                    .font(.title3.weight(.semibold))
                    // ONE sentence, because there is one state to describe. A
                    // stopped transcription has put nothing on the desk — this
                    // lane publishes the words and only the words — so the
                    // recording is on this device and nowhere else, and Try
                    // Again is what turns it into a card. A receipt that asked
                    // the desk what it was holding would have nothing to read.
                    Text(LocalizedStringResource(
                        "workboard.voice.stopped.body",
                        defaultValue: "Your recording is still on this device. Try Again turns it into a note on your desk."
                    ))
                    .font(.subheadline)
                    .foregroundStyle(AppColors.textSecondary)
                    // The refusal changes no state, so without this the only
                    // thing a Try Again another surface is already serving would
                    // change is nothing at all — the same reason the `.error`
                    // arm carries the sentence.
                    if recorder.retryRefusedBusy {
                        Text(LocalizedStringResource(
                            "pendingRetry.card.busy",
                            defaultValue: "This recording is already being finished. Try again in a moment."
                        ))
                        .font(.footnote)
                        .foregroundStyle(AppColors.warning)
                    }
                } else {
                    Text(LocalizedStringResource(
                        "workboard.voice.starting",
                        defaultValue: "Starting the microphone…"
                    ))
                }
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
                // Try Again reserves this capture's parked recording before it
                // transcribes, and another surface — the retry card, a Shortcut
                // host — can be finishing that same recording. Nothing failed
                // and nothing was deleted, so this says what is true rather than
                // adding an error the recorder never raised. Same sentence the
                // retry card shows for the same state.
                if recorder.retryRefusedBusy {
                    Text(LocalizedStringResource(
                        "pendingRetry.card.busy",
                        defaultValue: "This recording is already being finished. Try again in a moment."
                    ))
                    .font(.footnote)
                    .foregroundStyle(AppColors.warning)
                    .multilineTextAlignment(.center)
                }
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
                // parked, or the words it already recognized — and only starts a
                // new one when there is nothing left to finish. Recording again
                // is the separate action, because it hands this capture back to
                // the retry queue with nothing of it on the desk, and a person
                // who meant "finish it" would be left looking for it there.
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
            // A stopped transcription is the ONE idle this sheet can be looked
            // at in, and the capture it stopped still owns a parked recording
            // and a reservation — so the action that finishes it belongs here,
            // not only in `.error`. Reached solely through `handle(_:)`, which
            // dismisses instead whenever there is nothing left to finish.
            if transcriptionStopped, recorder.canRetryWorkCapture {
                Button {
                    // The stopped state is NOT cleared here. `retryWorkCapture`
                    // can refuse before it starts — another surface holds this
                    // capture's reservation — and a refusal deliberately leaves
                    // the recorder exactly as it was, `.idle`. Cleared first,
                    // that returned the sheet to "Starting the microphone…" over
                    // no controls at all: a dead end raised by a press that
                    // changed nothing. A retry that DOES start moves the state
                    // to `.processing`, which this flag has no say over, and a
                    // finished one dismisses the sheet from `handle`.
                    Task { handle(await recorder.retryWorkCapture()) }
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
                Button(LocalizedStringResource("common.done", defaultValue: "Done")) {
                    cancel()
                }
                .buttonStyle(.bordered)
            } else {
                EmptyView()
            }
        }
    }

    /// The sheet's privacy line. It states where the recording LIVES — on this
    /// device, until the words replace it — because that is now the lane's
    /// defining property: the desk gets a note, never a voice file, so no
    /// recording made here is ever carried to another device.
    ///
    /// Two promises it may not make. It may not promise that nothing is sent:
    /// the words come from whichever speech provider the person configured, and
    /// `STTClient`'s table is mostly cloud vendors, so the recording leaves the
    /// device on every configuration except Apple's on-device engine. And it may not promise that the audio
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
                defaultValue: "Your recording stays on this device while it becomes words, and the words go to your private desk. The audio goes only to the speech provider you chose, and only to be turned into words — never into a conversation, and never through a server of ours."
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

    /// The refusal is folded in because it does NOT change `state`: a Try Again
    /// another surface is already serving leaves the error on screen exactly as
    /// it was, so without this the only thing that changed would be invisible to
    /// VoiceOver.
    private var accessibilityStatusID: String {
        let busy = recorder.retryRefusedBusy ? "-busy" : ""
        switch recorder.state {
        case .idle: return (transcriptionStopped ? "stopped" : "idle") + busy
        case .recording: return "recording" + busy
        case .processing: return "processing" + busy
        case .preparingVoice: return "preparing" + busy
        case .error(let error): return "error-\(error.errorCode)" + busy
        }
    }

    private var accessibilityStatusMessage: String {
        if recorder.retryRefusedBusy {
            return String(
                localized: "pendingRetry.card.busy",
                defaultValue: "This recording is already being finished. Try again in a moment."
            )
        }
        switch recorder.state {
        case .idle:
            guard !transcriptionStopped else {
                return String(
                    localized: "workboard.voice.stopped.title",
                    defaultValue: "Transcription stopped"
                )
            }
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
            // Nothing is stopped any more, and this sheet renders for as long as
            // its dismissal takes.
            transcriptionStopped = false
            // The words are already a card on the desk, so handing the same
            // words to the composer would put one utterance on the board twice.
            // `onCancel` is this sheet's only dismissal hook. The composer is
            // reached only when the capture produced no card at all — a storage
            // failure is an error state, not a success, so it never arrives
            // here.
            if recorder.workRecordingMaterialID != nil {
                if recorder.workCaptureSavedInAllMaterials { onSavedInAllMaterials() }
                onCancel()
            } else {
                onTranscript(transcript)
            }
        case .failure(let error):
            // A CANCELLED hop is not a failure and the recorder says so: it
            // returns to `.idle` with no banner, because "Cancel Transcription"
            // is a promise about the WORDS and the recording behind them is
            // parked and safe. What that leaves on screen is this sheet's
            // problem: `.idle` renders the startup line and no controls, so the
            // capture's own Try Again — the thing that would still put the words
            // on that card — became unreachable the moment the press landed.
            //
            // Two answers, decided by whether anything is left to finish. A
            // capture still in hand earns the stopped state and its Try Again; a
            // capture with nothing owed is a finished piece of work, and this
            // sheet's only dismissal hook is `onCancel`.
            if case .unknown(let underlying) = error, underlying is CancellationError {
                if recorder.canRetryWorkCapture {
                    transcriptionStopped = true
                } else {
                    onCancel()
                }
                return
            }
            // The recorder already owns the typed error state and retry lane,
            // and the recording it parked before transcribing is waiting in it
            // either way.
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
