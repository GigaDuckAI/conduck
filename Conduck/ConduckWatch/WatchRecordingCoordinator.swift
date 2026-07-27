// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Bridges external recording triggers (ControlWidget intent, future surfaces)
/// to the per-view `WatchRecordingService` without depending on the SwiftUI
/// view hierarchy being mounted.
///
/// Rationale: `RecordNoteIntent` runs in the main app process for
/// `.foreground(.immediate)` and used to post a `NotificationCenter`
/// notification consumed by an `.onReceive` inside `WatchNoteView`. On a fresh
/// install the Watch Keychain is empty, so `ConduckWatchApp` renders
/// `WatchSetupView` instead, the observer never attaches, and the trigger is
/// silently dropped — surfacing as the system `"GigaNote" failed.` dialog.
/// This singleton holds the request across the identity-resolution wait and is
/// drained by whichever view is showing once it can act on it.
@MainActor
@Observable
final class WatchRecordingCoordinator {
    static let shared = WatchRecordingCoordinator()

    /// True when an external trigger has requested a recording start and no
    /// view has consumed it yet. Cleared by `consumePending()`.
    var pendingStart: Bool = false

    /// True while a recording is being initiated, recorded, or uploaded.
    /// Used to defer system alerts (notification permission) that would
    /// collide with the mic-permission prompt or the recording UI.
    var isRecordingFlowActive: Bool = false

    private init() {}

    /// Idempotent — sets the flag without resetting an in-flight request.
    func requestStart() {
        pendingStart = true
    }

    /// Atomic check-and-clear used by the view layer when ready to act.
    /// Returns true if a request was pending.
    func consumePending() -> Bool {
        guard pendingStart else { return false }
        pendingStart = false
        return true
    }
}
