// SPDX-License-Identifier: Apache-2.0

// A cheap copy-only preference snapshot. Work can draw hundreds of cards in
// one frame; each availability label must not refresh App Group defaults and
// lock the policy file. Canonical persistence gates still read the preference
// store. This cache refreshes once per announced change, and the Work host
// reloads its projections on the same notification.

import Foundation

nonisolated final class ContentSyncPresentationSnapshot: @unchecked Sendable {
    static let shared = ContentSyncPresentationSnapshot()

    private let lock = NSLock()
    private let preferences: ContentSyncPreferenceStore
    private let notifications: NotificationCenter
    private var enabled: Bool
    private var observers: [NSObjectProtocol] = []

    init(preferences: ContentSyncPreferenceStore = .shared, notifications: NotificationCenter = .default) {
        self.preferences = preferences
        self.notifications = notifications
        enabled = (try? preferences.readEnabled()) ?? true
        for name in [Notification.Name.contentSyncPreferenceDidChange, .contentSyncStateDidChange] {
            observers.append(notifications.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in
                // A transient lock refusal is not a saved OFF. Keep the last
                // good value; the runtime's recovery event retries this read.
                guard let self, let next = try? self.preferences.readEnabled() else { return }
                self.lock.lock()
                self.enabled = next
                self.lock.unlock()
            })
        }
    }

    deinit {
        for observer in observers { notifications.removeObserver(observer) }
    }

    var isEnabled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return enabled
    }
}
