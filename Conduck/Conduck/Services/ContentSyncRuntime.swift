// SPDX-License-Identifier: Apache-2.0

// Main-app presentation of the shared store's sync lifecycle. The store itself
// owns observation and cross-process coordination, so Watch and headless
// Shortcuts enforce the same preference without constructing this UI facade.

import Foundation
import Observation

@MainActor
@Observable
final class ContentSyncRuntime {
    enum State: Equatable { case on, off, applying, failed }

    static let shared = ContentSyncRuntime()
    private(set) var desiredEnabled = (try? ContentSyncPreferenceStore.shared.readEnabled()) ?? true
    private(set) var state: State = .applying
    private(set) var statusMessage: LocalizedStringResource?
    @ObservationIgnored private var started = false
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    private init() {}

    func start() {
        guard !started else { return }
        started = true
        for name in [Notification.Name.contentSyncPreferenceDidChange, .contentSyncStateDidChange] {
            observers.append(NotificationCenter.default.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in await self?.refresh() }
            })
        }
        Task {
            await ConversationStore.shared.reconcileContentSyncPreference()
            await refresh()
        }
    }

    func retry() async {
        state = .applying
        statusMessage = nil
        await ConversationStore.shared.reconcileContentSyncPreference(forceRetry: true)
        await refresh()
    }

    private func refresh() async {
        let snapshot = await ConversationStore.shared.currentContentSyncState()
        desiredEnabled = snapshot.desiredEnabled
        switch snapshot.phase {
        case .on: state = .on
        case .off: state = .off
        case .applying: state = .applying
        case .failed: state = .failed
        }
        if snapshot.failure == .anotherProcess || snapshot.failure == .activeOperations
            || snapshot.failure == .policyUnavailable {
            state = .applying
        }
        switch snapshot.failure {
        case .anotherProcess:
            statusMessage = LocalizedStringResource(
                "sync.content.pendingOtherActivity",
                defaultValue: "Waiting for another Conduck session to stop syncing."
            )
        case .activeOperations:
            statusMessage = LocalizedStringResource(
                "sync.content.pendingSave",
                defaultValue: "Waiting for the current save to finish."
            )
        case .storage:
            statusMessage = LocalizedStringResource(
                "sync.content.changeFailed",
                defaultValue: "The sync change could not finish. Your saved data is kept. Try again."
            )
        case .unavailableInBuild:
            statusMessage = LocalizedStringResource(
                "sync.content.unavailableInBuild",
                defaultValue: "This build keeps content on this device because iCloud sync is unavailable."
            )
        case .policyUnavailable:
            statusMessage = LocalizedStringResource(
                "sync.content.policyUnavailable",
                defaultValue: "Waiting to read the sync setting. Your saved data is kept."
            )
        case nil:
            statusMessage = nil
        }
    }
}
