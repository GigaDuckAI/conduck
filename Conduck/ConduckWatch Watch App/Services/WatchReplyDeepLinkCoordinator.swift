// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Holds a tapped suspended-reply notification's target conversation until a
/// view can act on it — the deep-link analogue of `WatchRecordingCoordinator`.
///
/// Rationale (mirrors the recording coordinator): a reply delivered while the
/// app is suspended arrives as a local notification. Tapping it fires
/// `UNUserNotificationCenterDelegate.didReceive` (wired on
/// `WatchNotificationDelegate`), which may run BEFORE `WatchNoteView` mounts on
/// a cold launch. There is no `onOpenURL` / deep-link path on watchOS, so this
/// observable singleton stashes the `conversationID` (read from the
/// notification's `userInfo`, stamped in `WatchAudioUploader.postNotification`)
/// across that ordering gap. `WatchNoteView` observes `pendingConversationID`
/// and drains it into a `.capture(.existing(id))` push, deep-linking the user
/// into the exact thread the reply landed in.
@MainActor
@Observable
final class WatchReplyDeepLinkCoordinator {
    static let shared = WatchReplyDeepLinkCoordinator()

    /// The conversation a tapped reply notification wants to open, or nil when
    /// none is pending. Set by `requestDeepLink(to:)`; cleared by
    /// `consumePending()`. Observed by `WatchNoteView`.
    private(set) var pendingConversationID: UUID?

    private init() {}

    /// Record a tapped-reply deep-link request. Idempotent: a second tap before
    /// the first drains simply overwrites the target (the latest tap wins).
    func requestDeepLink(to conversationID: UUID) {
        pendingConversationID = conversationID
    }

    /// Atomic check-and-clear used by the view layer when ready to navigate.
    /// Returns the pending conversation id (and clears it) or nil.
    func consumePending() -> UUID? {
        guard let id = pendingConversationID else { return nil }
        pendingConversationID = nil
        return id
    }
}
