// SPDX-License-Identifier: Apache-2.0

// Read-only local evidence for a Work send interrupted by app termination.
// An empty or missing conversation is unresolved, never proof that the gateway
// received nothing. Only a recorded user turn earns the Open conversation path;
// storage failures propagate separately so callers can offer a read retry.

#if !os(watchOS)
import Foundation

@MainActor
struct WorkDeskInterruptedHandoffLookup {
    var conversationExists: @MainActor (UUID) async throws -> Bool
    var userTurnExists: @MainActor (UUID) async throws -> Bool

    static var live: Self {
        Self(
            conversationExists: { id in
                try await ConversationStore.shared.fetchConversation(id: id) != nil
            },
            userTurnExists: { id in
                try await ConversationStore.shared.fetchMessages(for: id).contains { $0.role == "user" }
            }
        )
    }

    func existingConversationID(_ id: UUID) async throws -> UUID? {
        guard try await conversationExists(id), try await userTurnExists(id) else { return nil }
        return id
    }
}
#endif
