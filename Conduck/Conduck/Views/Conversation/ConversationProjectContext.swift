// SPDX-License-Identifier: Apache-2.0

// Conduck
// ConversationProjectContext.swift
//
// What the open thread's Work project means for the screen around it: the
// mark to draw under the navigation bar, and whether the composer may take a
// new turn. ONE instance per Chats host (the iPhone/iPad shell, the Mac
// window), owned OUTSIDE the thread's `.id(vm.conversationID)` boundary so a
// thread switch does not re-mint it — every answer is bound to the
// conversation it was read for, and a host asks with the conversation it is
// showing NOW, so a snapshot of thread A can never dress thread B.
//
// The answer is advisory. The store's own write (`appendMessage`) still
// refuses an archived or selection-blocked project, and the send paths carry
// the typed reason for the turn that slips between a refresh and a tap. What
// this class adds is saying it BEFORE the tap: a locked bar instead of a
// failed send, a "Show in Work" line instead of a row that looks like any
// other chat.
//
// Not knowing is not "ordinary chat". A read that fails keeps the last
// snapshot for the SAME conversation and otherwise reports `.unresolved`,
// which draws nothing and locks nothing — the write path is what refuses, so
// a transient read failure can neither strip a known project header nor
// silently unlock an archived thread by pretending the thread is unfiled.

import Foundation
import Observation

@MainActor @Observable
final class ConversationProjectContext {
    enum State: Equatable {
        case unresolved
        case resolved(conversationID: UUID, resolution: WorkProjectMarkResolution, refusal: WorkProjectAccessError?)
    }

    private(set) var state: State = .unresolved

    @ObservationIgnored private var generation: UInt64 = 0
    @ObservationIgnored private let fetch: @Sendable (UUID) async throws -> ConversationStore.WorkProjectThreadMark

    init(fetch: @escaping @Sendable (UUID) async throws -> ConversationStore.WorkProjectThreadMark = { id in
        try await ConversationStore.shared.workProjectThreadMark(conversationID: id)
    }) {
        self.fetch = fetch
    }

    /// The live project mark for `conversationID`, or nil — including when the
    /// snapshot on hand describes some other thread.
    func liveProject(for conversationID: UUID?) -> WorkProjectMark? {
        resolution(for: conversationID)?.liveMark
    }

    func resolution(for conversationID: UUID?) -> WorkProjectMarkResolution? {
        guard let conversationID,
              case .resolved(let id, let resolution, _) = state, id == conversationID else { return nil }
        return resolution
    }

    /// Why a new turn in `conversationID` would be refused, or nil. Nil while
    /// unresolved: an ordinary chat is never locked for the beat its read
    /// takes, and the store refuses a project turn on its own regardless.
    func refusal(for conversationID: UUID?) -> WorkProjectAccessError? {
        guard let conversationID,
              case .resolved(let id, _, let refusal) = state, id == conversationID else { return nil }
        return refusal
    }

    func allowsNewTurns(for conversationID: UUID?) -> Bool {
        refusal(for: conversationID) == nil
    }

    /// Re-read for the thread the host shows now. Generation-guarded AND
    /// cancellation-checked before publishing: a fast A→B switch cancels A's
    /// task and starts B's, and neither an out-of-order completion nor a
    /// cancelled task may publish.
    func refresh(conversationID: UUID?) async {
        generation &+= 1
        let requested = generation
        guard let conversationID else {
            state = .unresolved
            return
        }
        do {
            let mark = try await fetch(conversationID)
            guard !Task.isCancelled, requested == generation else { return }
            state = .resolved(conversationID: conversationID, resolution: mark.resolution, refusal: mark.refusal)
        } catch {
            guard !Task.isCancelled, requested == generation else { return }
            // Keep what this same thread last read; a snapshot of another
            // thread never stands in for it.
            if case .resolved(let id, _, _) = state, id == conversationID { return }
            state = .unresolved
        }
    }

    func reset() {
        generation &+= 1
        state = .unresolved
    }
}
