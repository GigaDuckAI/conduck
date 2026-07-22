// Conduck
// WatchMessageComposerBar.swift
//
// Compact composer for `WatchConversationThreadView` — `[TextField][morph]`.
// Mirrors `iOSMessageComposerBar`'s compact-layout shape (single Button + single
// `Image(systemName:)` + `.contentTransition(.symbolEffect(.replace))` for the
// mic↔send morph). Sends turns INTO the open conversation on its stored backend
// via `WatchRecordingService.sendTypedText(_:into:)` (typed) /
// `startRecording(boundTo:)` (voice). Does NOT touch the always-new headless
// path (Action Button / ControlWidget / `GigaAction`).

import SwiftUI
import WatchKit

struct WatchMessageComposerBar: View {
    @Bindable var viewModel: WatchConversationViewModel
    let conversationID: UUID

    /// Live recorder state for the morph + busy gating. The shared singleton —
    /// same instance that the headless path drives — so the busy indicator
    /// surfaces correctly across surfaces.
    @State private var recordingService = WatchRecordingService.shared

    @State private var draft = ""
    @FocusState private var fieldFocused: Bool

    private var trimmedDraft: String {
        draft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var hasDraft: Bool { !trimmedDraft.isEmpty }

    /// True when THIS thread has a turn in flight (recording / STT / waiting).
    /// We gate on the bound-conversation id so a headless capture in another
    /// thread doesn't make THIS composer look busy.
    private var isInFlight: Bool {
        recordingService.isBusy && recordingService.inFlightConversationID == conversationID
    }

    /// True while audio capture is active in THIS thread.
    private var isRecording: Bool {
        if case .recording = recordingService.state,
           recordingService.inFlightConversationID == conversationID {
            return true
        }
        return false
    }

    /// Morph priority: in-flight (waiting/uploading) → recording → send (has
    /// draft) → mic (idle). Single computed symbol keeps the Button identity
    /// stable so `.symbolEffect(.replace)` plays — see iOSMessageComposerBar's
    /// load-bearing single-Image trick.
    private var trailingSymbol: String {
        if isRecording { return "stop.circle.fill" }
        if isInFlight { return "stop.circle.fill" }
        if hasDraft { return "arrow.up.circle.fill" }
        return "mic.circle.fill"
    }

    private var trailingTint: Color {
        if isRecording { return AppColors.error }
        if isInFlight { return AppColors.textSecondary }
        return AppColors.brandAmber
    }

    private var trailingAccessibilityLabel: LocalizedStringResource {
        if isRecording || isInFlight { return LocalizedStringResource("Stop") }
        if hasDraft { return LocalizedStringResource("Send message") }
        return LocalizedStringResource("Record voice message")
    }

    /// Compact shared height for both the field pill and the mic circle, so the
    /// composer reads as one tidy row (was a ~55pt slab next to a 40pt mic).
    private static let controlHeight: CGFloat = 36

    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            // Native watchOS field — kept for its tap-to-modal entry (tap →
            // system scribble/dictation/keyboard sheet); the inline field is just
            // a launcher + draft display. The default style's rounded chrome has a
            // tall intrinsic height that OVERFLOWS the layout frame (SwiftUI never
            // clips overflow), so a bare `.frame(maxHeight:)` left it towering over
            // the mic. We DON'T layer a custom shape (`.textFieldStyle(.plain)`
            // doesn't suppress the system chrome on watchOS → double-shape); instead
            // we bound the frame and `.clipShape` the chrome to a compact pill that
            // matches the mic. Clipping the chrome (not adding a shape) sidesteps the
            // double-shape artifact entirely.
            TextField(
                LocalizedStringResource("Message"),
                text: $draft
            )
            .font(.caption)
            .lineLimit(1)
            .truncationMode(.tail)
            .focused($fieldFocused)
            .disabled(isInFlight || isRecording)
            .controlSize(.small)
            .frame(maxWidth: .infinity, minHeight: Self.controlHeight, maxHeight: Self.controlHeight)
            .clipShape(RoundedRectangle(cornerRadius: Self.controlHeight / 2, style: .continuous))

            Button(action: trailingAction) {
                Image(systemName: trailingSymbol)
                    .font(.system(size: Self.controlHeight))
                    .foregroundStyle(trailingTint)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 40, height: 40)
                    .contentShape(Circle())
                    .animation(.snappy(duration: 0.25), value: trailingSymbol)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(trailingAccessibilityLabel))
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
    }

    // MARK: - Actions

    private func trailingAction() {
        if isRecording {
            WKInterfaceDevice.current().play(.click)
            recordingService.stopRecording()
            return
        }
        if isInFlight {
            WKInterfaceDevice.current().play(.click)
            recordingService.cancelRecording()
            return
        }
        if hasDraft {
            sendTyped()
        } else {
            startVoice()
        }
    }

    private func sendTyped() {
        let text = trimmedDraft
        guard !text.isEmpty else { return }
        fieldFocused = false
        Task {
            // Clear the draft only when the service ACCEPTED the send — a
            // busy no-op (e.g. a headless turn in flight for another thread)
            // must not silently discard what the user typed.
            if await recordingService.sendTypedText(text, into: conversationID) {
                draft = ""
            }
        }
    }

    private func startVoice() {
        switch recordingService.state {
        // `.error` recovers inside the bound wrapper (it dismisses the stale
        // error, then records) — without this the mic no-ops forever after a
        // failed turn, since nothing in the thread stack rendered the error.
        case .idle, .error: break
        default: return
        }
        fieldFocused = false
        recordingService.startRecording(boundTo: conversationID)
    }
}
