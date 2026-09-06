// SPDX-License-Identifier: Apache-2.0

// ConduckWatch Watch App
// WatchWorkCaptureView.swift
//
// The wrist's Work capture surface: speak a private thought, and it lands on
// the single Work desk the other devices read. Pushed from the Ask chooser's
// Add to Work row as `WatchRoute.workCapture(nonce:)`.
//
// THREE THINGS THIS SCREEN DELIBERATELY DOES NOT HAVE, each of them a rule
// rather than an omission:
//
// 1. No gateway chooser, and no gateway anywhere below it. A Work capture has
//    no conversation, no agent and no reply — the whole point of the desk is
//    that a private thought stays private. The screen is reached by a
//    per-press pick in the Ask chooser, so there is no mode to leave switched
//    on by accident.
// 2. No word for sending. Everything here SAVES; "send", "dispatch" and their
//    relatives describe a thing this lane cannot do, and reading one on a
//    private-capture screen is exactly the wrong reassurance.
// 3. No retry affordance on the TERMINAL LINE. Every outcome there is already
//    durable somewhere — on the desk, or on the wrist waiting for the iPhone —
//    so a "try again" would ask the user to re-record something that is not
//    lost. Only a refusal ends with nothing captured, and its sentence says
//    what to do instead. A recorder ERROR is not a terminal outcome and is the
//    one place the offer belongs: it can still be holding the recording, and
//    that is the case this screen must not send anywhere else to resolve.
//
// The recorder states mirror the in-thread chat capture overlay (arming →
// "Starting…", live ring + timer, then a saving spinner) so the wrist's two
// capture surfaces feel like one product; the copy and the terminal line are
// Work's own.

import SwiftUI
import WatchKit

struct WatchWorkCaptureView: View {
    /// The capture request this screen was pushed for — the
    /// `WatchRoute.workCapture` nonce. It lives in the ROUTE value, so a fresh
    /// tap always remounts this view (a value-equal route would be a
    /// NavigationStack no-op and the screen would sit on a stale outcome).
    let requestID: UUID

    @Bindable var recordingService: WatchRecordingService

    @Environment(\.dismiss) private var dismiss
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced

    /// One-shot latch for the terminal haptic. The outcome can be visible on
    /// the very first render (a refusal resolves synchronously with the start),
    /// so both `.onAppear` and `.onChange` announce — the latch is what keeps
    /// that from buzzing twice for one capture.
    @State private var announcedOutcome = false

    /// The terminal line THIS screen may show.
    ///
    /// The service holds one outcome, but the wrist can hold several deferred
    /// Work captures at once (they are exempt from both queue caps), so the
    /// capture that settles is routinely not the capture on screen. The service
    /// stamps each outcome with the nonce it belongs to; this is where that
    /// stamp is honoured, so a sibling's acknowledgement can post its banner
    /// without ever repainting this screen's line.
    private var outcome: WatchWorkCaptureOutcome? {
        guard recordingService.workCaptureID == requestID else { return nil }
        return recordingService.workCaptureOutcome
    }

    /// True while the microphone is being armed or is genuinely live for this
    /// capture — the window in which leaving the screen must DISCARD rather
    /// than abandon a hot recorder.
    private var isCapturing: Bool {
        outcome == nil && recordingService.isCapturing
    }

    var body: some View {
        Group {
            if let outcome {
                terminalView(outcome: outcome)
            } else if isLuminanceReduced {
                // Always On Display: red dot + timer only, matching the chat
                // capture overlay. A wrist-down capture must still read as
                // recording without lighting the whole panel.
                alwaysOnView
            } else {
                switch recordingService.state {
                case .arming:
                    startingView
                case .recording:
                    recordingView
                case .idle, .uploading, .waiting:
                    // `.idle` is the beat between the recorder stopping and the
                    // relay arming; the user has already spoken, so "saving" is
                    // the honest read of all three.
                    savingView
                case .error(let message):
                    messageView(
                        symbolName: "exclamationmark.triangle.fill",
                        tint: .orange,
                        text: message,
                        dismissesRecorderError: true
                    )
                }
            }
        }
        .navigationTitle(Self.screenTitle)
        .navigationBarTitleDisplayMode(.inline)
        // Back-nav is the discard affordance ONLY when there is nothing live to
        // discard. While the mic is hot the explicit cancel below is the single
        // exit, so a swipe cannot strand a running recorder off-screen.
        .navigationBarBackButtonHidden(isCapturing)
        .overlay(alignment: .topLeading) {
            if isCapturing && !isLuminanceReduced { cancelControl }
        }
        .onAppear {
            WatchLog.note(.capture, "work.capture.open", [
                "req": WatchLog.shortID(requestID),
                "state": recordingService.state.phaseKind
            ])
            announceOutcomeIfNeeded()
        }
        .onChange(of: recordingService.workCaptureOutcome) { _, _ in
            announceOutcomeIfNeeded()
        }
    }

    // MARK: - Recorder states

    private var startingView: some View {
        VStack(spacing: 8) {
            ProgressView()
                .tint(.orange)
            Text(String(localized: LocalizedStringResource(
                "watch.work.capture.starting",
                defaultValue: "Starting…"
            )))
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var recordingView: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle()
                    .stroke(Color.orange.opacity(0.3), lineWidth: 4)
                    .frame(width: 72, height: 72)
                Circle()
                    .fill(Color.red)
                    .frame(width: 22, height: 22)
            }

            WatchWorkRecordingTimer(recordingService: recordingService, font: .title2)

            if recordingService.nearMaxDuration {
                Text(String(localized: LocalizedStringResource(
                    "watch.work.capture.timeLeft",
                    defaultValue: "1 min left"
                )))
                .font(.caption2)
                .foregroundStyle(.orange)
                .transition(.opacity)
            }

            Button {
                WKInterfaceDevice.current().play(.click)
                recordingService.stopRecording()
            } label: {
                Text(String(localized: LocalizedStringResource(
                    "watch.work.capture.stop",
                    defaultValue: "Tap to Stop"
                )))
                .font(.caption)
            }
            .buttonStyle(.bordered)
        }
        .padding(.horizontal, 8)
        .animation(.easeInOut(duration: 0.2), value: recordingService.nearMaxDuration)
    }

    private var savingView: some View {
        VStack(spacing: 8) {
            ProgressView()
                .tint(.orange)
            Text(String(localized: LocalizedStringResource(
                "watch.work.capture.saving",
                defaultValue: "Saving to Work…"
            )))
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var alwaysOnView: some View {
        VStack(spacing: 6) {
            Circle()
                .fill(.red.opacity(0.6))
                .frame(width: 16, height: 16)
            if case .recording = recordingService.state {
                WatchWorkRecordingTimer(recordingService: recordingService, font: .title3)
            }
        }
    }

    // MARK: - Terminal line

    private func terminalView(outcome: WatchWorkCaptureOutcome) -> some View {
        messageView(
            symbolName: WatchWorkCaptureCopy.symbolName(for: outcome),
            tint: WatchWorkCaptureCopy.isReassuring(outcome) ? .green : .orange,
            text: WatchWorkCaptureCopy.terminalLine(for: outcome)
        )
    }

    /// Shared shape for every end-of-capture screen (terminal outcome AND a
    /// recorder error). SCROLLS on purpose: the deferred sentence is two lines
    /// on a 41mm face with large text, and a Done button pushed below the
    /// bezel is a screen with no exit.
    ///
    /// `dismissesRecorderError` is set by the RECORDER-ERROR case only, and it
    /// is what keeps one failure from being read twice: a terminal outcome is
    /// this screen's own line, but an error is the SERVICE's state, so clearing
    /// the outcome leaves `.error` standing and the launchpad re-presents the
    /// identical sentence the instant this screen pops.
    ///
    /// A failure that still HAS its audio is the reason there is a second
    /// button label rather than a second screen: the recovery is offered right
    /// here, on the error the person is reading, instead of by dismissing into
    /// the launchpad's copy of the same sentence. It is the launchpad's own
    /// rule (`canRetry` decides the word), moved to where the failure is shown.
    private func messageView(
        symbolName: String,
        tint: Color,
        text: String,
        dismissesRecorderError: Bool = false
    ) -> some View {
        // Read at BODY time for the label and again at TAP time for the act,
        // both from the same rule: `canRetry` turns false the moment the
        // preserved capture is consumed, and a button must never perform an act
        // the state it was drawn for no longer allows.
        let canRetry = recordingService.canRetry
        return ScrollView {
            VStack(spacing: 10) {
                Image(systemName: symbolName)
                    .font(.title3)
                    .foregroundStyle(tint)

                Text(text)
                    .font(.caption)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)

                Button {
                    let action = Self.messageAction(
                        showingRecorderError: dismissesRecorderError,
                        canRetry: recordingService.canRetry
                    )
                    if Self.perform(action, on: recordingService) { dismiss() }
                } label: {
                    Text(Self.buttonLabel(
                        showingRecorderError: dismissesRecorderError,
                        canRetry: canRetry
                    ))
                    .font(.caption)
                }
                .buttonStyle(.bordered)
            }
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Cancel

    /// Discard-and-leave, mirroring the chat capture overlay's cancel-X: the
    /// visible circle is chrome and aiming aid, the 44pt frame is the real hit
    /// region. Cancelling first and dismissing second means no recorder is ever
    /// left running behind a popped screen.
    private var cancelControl: some View {
        Button {
            WKInterfaceDevice.current().play(.click)
            recordingService.cancelRecording()
            dismiss()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
                .frame(width: 30, height: 30)
                .background(Circle().fill(.white.opacity(0.15)))
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(String(localized: LocalizedStringResource(
            "watch.work.capture.cancel",
            defaultValue: "Cancel"
        ))))
    }

    // MARK: - Haptics

    private func announceOutcomeIfNeeded() {
        guard !announcedOutcome, let outcome else { return }
        announcedOutcome = true
        WKInterfaceDevice.current().play(
            WatchWorkCaptureCopy.isReassuring(outcome) ? .success : .failure
        )
        WatchLog.note(.capture, "work.capture.outcome", [
            "req": WatchLog.shortID(requestID),
            "kind": WatchWorkCaptureCopy.logLabel(for: outcome)
        ])
    }

    private static let screenTitle = String(localized: LocalizedStringResource(
        "watch.work.capture.navigationTitle",
        defaultValue: "Add to Work"
    ))

    /// What the single button on an end-of-capture screen does.
    ///
    /// One value rather than a pair of booleans because the label and the
    /// effect have to agree: a button that says Try Again and dismisses the
    /// error deletes the recording it offered to re-send.
    enum MessageAction: Equatable {
        /// A terminal outcome. It is this screen's own line, so reading it is
        /// the whole of ending it.
        case done
        /// A recorder error with NOTHING left to retry. The error is the
        /// SERVICE's state, so clearing only the outcome leaves `.error`
        /// standing and the launchpad re-presents the identical sentence the
        /// instant this screen pops — one failure, read twice.
        case dismissErrorThenDone
        /// A recorder error whose audio is still on the wrist. The recovery
        /// belongs on the error the person is looking at: `dismissError()`
        /// DELETES the preserved capture, so this arm must not take it, and
        /// sending them to the launchpad to find the same sentence with a
        /// better button is a second reading of one failure.
        case retry
    }

    /// The action, pure.
    static func messageAction(showingRecorderError: Bool, canRetry: Bool) -> MessageAction {
        guard showingRecorderError else { return .done }
        return canRetry ? .retry : .dismissErrorThenDone
    }

    /// Run it against the service, and answer whether the screen goes.
    ///
    /// The service calls live HERE rather than in the button closure so the
    /// button's real effect — which of the two destructive service calls it
    /// makes, and whether it leaves the screen — is reachable from a test.
    @MainActor
    @discardableResult
    static func perform(_ action: MessageAction, on service: WatchRecordingService) -> Bool {
        switch action {
        case .retry:
            // Stay. `retry()` re-runs the preserved capture through the same
            // Work relay, and this screen renders its progress and its outcome.
            service.retry()
            return false
        case .dismissErrorThenDone:
            service.dismissError()
            service.clearWorkCaptureOutcome()
            return true
        case .done:
            // Drop the line now that it has been read. `startWorkCapture`
            // clears it too, so this is not what makes the NEXT capture
            // correct — it is what keeps a DEFERRED settlement arriving minutes
            // later from being mistaken for the capture the user just
            // acknowledged.
            service.clearWorkCaptureOutcome()
            return true
        }
    }

    /// The word on the button, from the SAME two facts the action is decided
    /// from — so a button can never say Try Again over an act that dismisses,
    /// and the retryability gate is readable at the label site rather than one
    /// call away. `Try Again` is the launchpad's own literal, so the two
    /// surfaces cannot drift into two names for one act.
    static func buttonLabel(showingRecorderError: Bool, canRetry: Bool) -> String {
        switch messageAction(showingRecorderError: showingRecorderError, canRetry: canRetry) {
        case .retry:
            return String(localized: "Try Again")  // xcstrings
        case .done, .dismissErrorThenDone:
            return String(localized: LocalizedStringResource(
                "watch.work.capture.done",
                defaultValue: "Done"
            ))
        }
    }
}

/// Outcome → copy, as a PURE function so the mapping is testable without a
/// recorder, a relay or a watch face. Cross-wiring two of these lines is the
/// failure that matters most — telling someone their thought is safe on the
/// desk when it is still sitting on their wrist — and it is invisible to any
/// test that only checks that "some line" rendered.
nonisolated enum WatchWorkCaptureCopy {
    /// The single sentence the wrist shows when a Work capture ends. A refusal
    /// carries its own already-resolved sentence, so it passes through verbatim
    /// rather than being flattened into one generic apology.
    static func terminalLine(for outcome: WatchWorkCaptureOutcome) -> String {
        switch outcome {
        case .saved:
            return String(localized: LocalizedStringResource(
                "watch.work.capture.saved",
                defaultValue: "Saved to Work."
            ))
        case .deferredToPhone:
            return String(localized: LocalizedStringResource(
                "watch.work.capture.deferred",
                defaultValue: "Saved on your watch. It reaches Work when your iPhone is nearby."
            ))
        case .savedWordsOnly:
            return String(localized: LocalizedStringResource(
                "watch.work.capture.savedWordsOnly",
                defaultValue: "Saved the words to Work. Update Conduck on your iPhone to keep recordings."
            ))
        case .savedWithoutWords:
            // The mirror of the line above, and the wording CarPlay already
            // speaks for the same state: the recording is on the desk, the
            // words are not, and the iPhone is where they get added.
            return String(localized: LocalizedStringResource(
                "watch.work.capture.savedWithoutWords",
                defaultValue: "Saved to Work. Add the words on your iPhone."
            ))
        case .refused(let reason):
            return reason
        }
    }

    /// SF Symbol for the terminal line. The two "it is on the desk" outcomes
    /// share the desk's own glyph, so the end of the flow visibly answers the
    /// row that began it.
    static func symbolName(for outcome: WatchWorkCaptureOutcome) -> String {
        switch outcome {
        case .saved, .savedWordsOnly, .savedWithoutWords: return "tray.and.arrow.down.fill"
        case .deferredToPhone: return "clock.arrow.circlepath"
        case .refused: return "exclamationmark.triangle.fill"
        }
    }

    /// True when the capture is safe — either on the desk already, or held on
    /// the wrist until the iPhone is nearby. Drives the success haptic and the
    /// green tint; a refusal is the only outcome that captured nothing.
    static func isReassuring(_ outcome: WatchWorkCaptureOutcome) -> Bool {
        switch outcome {
        case .saved, .deferredToPhone, .savedWordsOnly, .savedWithoutWords: return true
        case .refused: return false
        }
    }

    /// Diagnostics label — the case KIND only. A refusal's sentence can name a
    /// gateway or a queue state, so it never reaches the log.
    static func logLabel(for outcome: WatchWorkCaptureOutcome) -> String {
        switch outcome {
        case .saved: return "saved"
        case .deferredToPhone: return "deferred"
        case .savedWordsOnly: return "wordsOnly"
        case .savedWithoutWords: return "withoutWords"
        case .refused: return "refused"
        }
    }
}

/// Perf-isolated recording timer readout, for the same reason the chat capture
/// overlay has one: `recordingTime` ticks at 10 Hz, and reading it only inside
/// this leaf keeps that invalidation off the surrounding capture UI.
private struct WatchWorkRecordingTimer: View {
    @Bindable var recordingService: WatchRecordingService
    let font: Font

    private var formattedTime: String {
        let minutes = Int(recordingService.recordingTime) / 60
        let seconds = Int(recordingService.recordingTime) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    var body: some View {
        Text(formattedTime)
            .font(font.monospacedDigit())
            .foregroundStyle(recordingService.nearMaxDuration ? .orange : .primary)
    }
}
