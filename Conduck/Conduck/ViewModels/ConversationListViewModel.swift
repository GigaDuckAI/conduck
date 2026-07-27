// SPDX-License-Identifier: Apache-2.0

// Conduck
// ConversationListViewModel.swift
//
// Observable view model backing the conversation LIST surface (iOS toolbar
// push, macOS library, Watch browse). Split 1→2 with
// `ConversationDetailViewModel`.
//
// `@Observable @MainActor` + the nested deinit-safe `ObserverBox` pattern — the
// box lets `deinit` detach the
// `.conversationsDidChange` observer without touching `@MainActor` state from
// a nonisolated context.

import Foundation
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif

/// Drives the conversation list: fetches from `ConversationStore.shared` and
/// re-fetches whenever `.conversationsDidChange` fires (local mutation OR a
/// merged CloudKit remote change).
@Observable
@MainActor
final class ConversationListViewModel {
    var conversations: [ConversationRecord] = []
    var isLoading = false
    var loadError: String?

    /// Monotonic counter bumped whenever `conversations` is (re)assigned — a
    /// local mutation, a delete, or a merged CloudKit remote change routed
    /// through `reload()`. The list view folds it into the content-search
    /// `.task(id:)` key so an in-flight whole-history search RE-RUNS when the
    /// underlying data changes mid-search (otherwise a search started before a
    /// new turn landed would show a stale match set).
    private(set) var changeGeneration = 0

    /// Holder so the observer can be detached on `deinit` without touching
    /// main-actor state from a nonisolated context (verbatim NotesViewModel).
    private final class ObserverBox {
        var observers: [NSObjectProtocol] = []

        deinit {
            for observer in observers {
                NotificationCenter.default.removeObserver(observer)
            }
        }
    }

    private let observerBox = ObserverBox()

    /// Coalescing guard for `.conversationsDidChange` → `reload()`. A CloudKit
    /// import storm posts that notification dozens of times in a beat; without
    /// this each post spawned its own `Task { reload() }`, stacking overlapping
    /// full-list refetches on the main actor. `scheduleReload()` collapses a
    /// burst into ≤2 reloads. `@ObservationIgnored` — pure bookkeeping.
    @ObservationIgnored private var reloadTask: Task<Void, Never>?
    @ObservationIgnored private var reloadPending = false

    init() {
        // `.conversationsDidChange` = a store mutation / merged CloudKit import.
        // `.conversationsNeedLocalRefresh` = a foreground snapshot re-read (no
        // store write, just re-display the latest local state). Both → reload().
        for name in [Notification.Name.conversationsDidChange, .conversationsNeedLocalRefresh] {
            observerBox.observers.append(
                NotificationCenter.default.addObserver(
                    forName: name,
                    object: nil,
                    queue: .main
                ) { [weak self] _ in
                    // Coalesce (not one `Task { reload() }` per post) — see
                    // `scheduleReload()`. `queue: .main` runs this on the main
                    // thread; hop into the actor to touch the guard state.
                    Task { @MainActor [weak self] in self?.scheduleReload() }
                }
            )
        }

        Task { await self.reload() }
    }

    // MARK: - Loading

    /// Coalesce a burst of `.conversationsDidChange` posts into ≤2 reloads (one
    /// in-flight + one trailing). Main-actor-serialized; no `await` between the
    /// pending-check and clearing `reloadTask`, so the tail is atomic.
    private func scheduleReload() {
        if reloadTask != nil {
            reloadPending = true
            return
        }
        reloadTask = Task { [weak self] in
            guard let self else { return }
            repeat {
                self.reloadPending = false
                await self.reload()
            } while self.reloadPending
            self.reloadTask = nil
        }
    }

    func reload() async {
        isLoading = true
        loadError = nil
        do {
            let fetched = try await ConversationStore.shared.fetchConversations()
            // Skip the reassignment + `changeGeneration` bump when a no-op import
            // echo re-fetches an identical list (the storm's cheapest exit); the
            // generation bump only needs to fire when the data actually changed.
            if fetched != conversations {
                conversations = fetched
                changeGeneration += 1
            }
        } catch {
            loadError = String(localized: "Couldn't load your conversations. Try again.")
        }
        isLoading = false
    }

    // MARK: - Mutations

    func delete(_ conversation: ConversationRecord) async {
        do {
            try await ConversationStore.shared.deleteConversation(id: conversation.id)
            conversations.removeAll { $0.id == conversation.id }
            changeGeneration += 1
        } catch {
            // Non-fatal — the notification will re-fetch on the next write.
        }
    }

    func deleteAll() async {
        do {
            try await ConversationStore.shared.deleteAll()
            conversations = []
            changeGeneration += 1
        } catch {
            loadError = String(localized: "Couldn't clear your conversations. Try again.")
        }
    }
}
