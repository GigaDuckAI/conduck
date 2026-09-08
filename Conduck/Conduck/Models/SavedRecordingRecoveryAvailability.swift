// SPDX-License-Identifier: Apache-2.0

// Conduck
// SavedRecordingRecoveryAvailability.swift
//
// The ordinary menu-bar recovery action must not replace a live capture or an
// unsent request that still holds the only copy of its transcript. Keep that
// policy independent of the UI so its ordering can be tested without audio or
// access to the durable retry queue.

enum SavedRecordingRecoveryAvailability: Equatable {
    case busy
    case ready
    case empty

    static func resolve(isBusy: Bool, waitingCount: Int, hasUnsentRequest: Bool = false) -> Self {
        if isBusy || hasUnsentRequest { return .busy }
        return waitingCount > 0 ? .ready : .empty
    }
}
