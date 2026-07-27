// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Pure routing decision for a HEADLESS capture trigger (Action Button /
/// ControlWidget press) draining into the mounted nav host. Extracted from
/// `WatchNoteView.drainCoordinatorIfNeeded` so the truth table is
/// unit-testable (`WatchHeadlessDrainDecisionTests`); the view keeps executing
/// the verdict's side effects (disabled toast, Ask-hint clear, nonce'd route
/// push, belt-and-suspenders service start). Plain-value inputs only — no
/// singleton reads — or the tests would inherit the view's coupling.
enum HeadlessDrainDecision: Equatable {
    /// A genuinely LIVE turn (arming / recording / uploading / waiting) owns
    /// the machine — never interrupt it. The view surfaces the drop (haptic +
    /// log); the press is otherwise fully silent.
    case refuse
    /// Master switch off — surface the watch-disabled error instead of
    /// recording. Checked AFTER the live-turn refuse: the view's error arm
    /// writes `state = .error` directly, which on a live `.recording` machine
    /// would orphan a hot mic (`stopRecording` guards `state == .recording`,
    /// so nothing could ever stop it). A turn already in flight finishes;
    /// the disable takes effect at the next idle press.
    case disabledError
    /// The resolved target is the thread ALREADY on screen — start capture
    /// directly on the mounted thread. Re-pushing the identical
    /// `.capture(.existing(id))` route is a SwiftUI no-op (the destination is
    /// reused, its one-shot auto-start `.task` never re-runs), so a push here
    /// would "just show the chat" without recording.
    case directStart
    /// Pop to root, push a fresh nonce'd `.capture` route, and start the
    /// capture from the service too (deterministic mic even if the pushed
    /// view's `.task` is delayed/cancelled by a racing re-trigger).
    case pushAndStart

    /// `state` gate: `.idle` and `.error` proceed — a lingering error from a
    /// prior turn must not permanently swallow the Action Button
    /// (`startCapture` dismisses the stale `.error` before recording).
    static func make(
        target: WatchCaptureTarget,
        displayedConversationID: UUID?,
        state: WatchRecordingState,
        watchEnabled: Bool
    ) -> HeadlessDrainDecision {
        switch state {
        case .idle, .error:
            break
        case .arming, .recording, .uploading, .waiting:
            return .refuse
        }
        guard watchEnabled else { return .disabledError }
        if case .existing(let id) = target, displayedConversationID == id {
            return .directStart
        }
        return .pushAndStart
    }
}
