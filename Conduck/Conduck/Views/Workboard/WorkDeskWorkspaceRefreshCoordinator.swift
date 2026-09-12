// SPDX-License-Identifier: Apache-2.0

// Conduck
// WorkDeskWorkspaceRefreshCoordinator.swift
//
// Project metadata and settings refresh independently of capture ingestion.
// A mounted but hidden Work workspace records changes without fetching them;
// returning drains the merged request after the mode transition. Only one
// pipeline runs at a time, with a trailing pass for changes received while it
// was reading. A started result reconciliation owns durable work and is never
// canceled just because the person opens Chats.

import Foundation

@MainActor
final class WorkDeskWorkspaceRefreshCoordinator {
    struct Request: OptionSet, Sendable {
        let rawValue: Int
        static let organization = Request(rawValue: 1 << 0)
        static let settings = Request(rawValue: 1 << 1)
        static let results = Request(rawValue: 1 << 2)
        static let all: Request = [.organization, .settings, .results]
    }

    private let delay: Duration
    private let refresh: @MainActor (Request) async -> Void
    private var pending: Request = []
    private var isActive = false
    private var isRefreshing = false
    private var task: Task<Void, Never>?

    init(
        delay: Duration = .milliseconds(180),
        refresh: @escaping @MainActor (Request) async -> Void
    ) {
        self.delay = delay
        self.refresh = refresh
    }

    func request(_ request: Request) {
        pending.formUnion(request)
        startIfNeeded()
    }

    func setActive(_ active: Bool) {
        isActive = active
        if !active && !isRefreshing {
            // Only cancel the delay. Its pending request remains available for
            // the next activation, and an obsolete task never clears a new one.
            task?.cancel()
            task = nil
        }
        startIfNeeded()
    }

    private func startIfNeeded() {
        guard isActive, !pending.isEmpty, task == nil else { return }
        let delay = delay
        task = Task { [weak self] in
            do { try await Task.sleep(for: delay) }
            catch { return }
            guard let self else { return }
            while isActive && !pending.isEmpty {
                let request = pending
                pending = []
                isRefreshing = true
                await refresh(request)
                isRefreshing = false
                guard isActive, !pending.isEmpty else { break }
                do { try await Task.sleep(for: delay) }
                catch { return }
            }
            task = nil
        }
    }
}
