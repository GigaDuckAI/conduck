// SPDX-License-Identifier: Apache-2.0

// Conduck
// WorkDeskConversationResolver.swift
//
// The macOS window supplies its actual coordinator-owned conversation model.
// This makes the sender, the opened thread, and Stop share one live owner,
// without relying on SwiftUI's application delegate proxy or a global lookup.
// A missing owner fails closed. Other platforms retain their normal sender.

#if !os(watchOS)
import SwiftUI

nonisolated struct WorkDeskConversationResolver: Sendable {
    let resolve: @MainActor @Sendable (UUID) -> ConversationDetailViewModel?
    let reportVisible: @MainActor @Sendable (UUID, Bool) -> Void
    let retain: (@MainActor @Sendable (UUID, UUID) -> ConversationDetailViewModel?)?
    let release: @MainActor @Sendable (UUID) -> Void

    init(resolve: @escaping @MainActor @Sendable (UUID) -> ConversationDetailViewModel? = { _ in nil },
         reportVisible: @escaping @MainActor @Sendable (UUID, Bool) -> Void = { _, _ in },
         retain: (@MainActor @Sendable (UUID, UUID) -> ConversationDetailViewModel?)? = nil,
         release: @escaping @MainActor @Sendable (UUID) -> Void = { _ in }) {
        self.resolve = resolve
        self.reportVisible = reportVisible
        self.retain = retain
        self.release = release
    }
}

/// A registry lease follows the retained model, independent of window focus.
/// Releasing a closed workspace cannot leave a permanent coordinator owner.
final class WorkDeskConversationLease: Sendable {
    let ownerID: UUID
    private let release: @MainActor @Sendable (UUID) -> Void
    init(ownerID: UUID, release: @escaping @MainActor @Sendable (UUID) -> Void) {
        self.ownerID = ownerID
        self.release = release
    }
    deinit {
        let id = ownerID
        let release = release
        Task { @MainActor in release(id) }
    }
}

private struct WorkDeskOpenConversationKey: EnvironmentKey {
    static let defaultValue: (@MainActor (UUID) -> Void)? = nil
}

private struct WorkDeskConversationResolverKey: EnvironmentKey {
    static let defaultValue = WorkDeskConversationResolver()
}

extension EnvironmentValues {
    var workDeskOpenConversation: (@MainActor (UUID) -> Void)? {
        get { self[WorkDeskOpenConversationKey.self] }
        set { self[WorkDeskOpenConversationKey.self] = newValue }
    }
    var workDeskConversationResolver: WorkDeskConversationResolver {
        get { self[WorkDeskConversationResolverKey.self] }
        set { self[WorkDeskConversationResolverKey.self] = newValue }
    }
}
#endif
