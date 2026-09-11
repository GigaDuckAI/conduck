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

    init(resolve: @escaping @MainActor @Sendable (UUID) -> ConversationDetailViewModel? = { _ in nil }) {
        self.resolve = resolve
    }
}

private struct WorkDeskConversationResolverKey: EnvironmentKey {
    static let defaultValue = WorkDeskConversationResolver()
}

extension EnvironmentValues {
    var workDeskConversationResolver: WorkDeskConversationResolver {
        get { self[WorkDeskConversationResolverKey.self] }
        set { self[WorkDeskConversationResolverKey.self] = newValue }
    }
}
#endif
