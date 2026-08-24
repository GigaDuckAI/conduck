// SPDX-License-Identifier: Apache-2.0

// Conduck
// ConversationStore+GatewayAttempts.swift
//
// The persistence half of the gateway-attempt ledger: opening a row at the
// final pre-transport boundary, closing it exactly once when a turn lands,
// reading it back for the dashboard, and deleting it with the history it
// describes. An extension of the SAME actor rather than a store of its own,
// because a terminal landing has to write the reply, the user turn's send state
// and the attempt row in ONE Core Data save — a second actor could not join
// that transaction, and two saves would be two CloudKit exports and a window
// where a reply exists with no measurement or the reverse.
//
// THE LEDGER IS AUXILIARY, AND EVERY RULE HERE FOLLOWS FROM THAT. A begin that
// cannot insert returns nil and the dispatch proceeds; a terminal write that
// cannot land leaves the row open and the reply still lands. Measurement never
// outranks the user's turn, which is why the dashboard says RECORDED attempts
// rather than claiming an infallible total.
//
// THE LEDGER IS ALSO CONTENT-FREE, AND THAT IS RELEASE-BLOCKING. Nothing this
// file writes touches prompt or reply text, a URL, a host, a token, a display
// name, a provider error string or an HTTP status. `gatewayRef` is a
// `RemoteAgentRef.rawString`; the three wire strings arrive already bounded and
// scanned by `GatewayResponseMetadata`. Never log any of it.
//
// NO `.conversationsDidChange` POST FROM AN ATTEMPT-ONLY WRITE. Every attempt
// write rides beside a `Message` write from the same lane — the user turn at
// dispatch, the reply or the failure flip at landing, the send-state flip on a
// cancel — and those post already. Posting again per dispatch would reload every
// list for a row no conversation surface renders, which is exactly the refetch
// loop `ConversationStore`'s header argues against. The one exception is the
// explicit `deleteGatewayAttempts` cleanup, which no other write accompanies.
//
// IN the Watch target: `ConduckWatch Watch App` shares `ConversationStore.swift`
// through a pbxproj membership exception, and this file has to travel with it —
// the wrist uploader opens its own attempts, and `ConversationStore.swift`
// itself calls the shared helpers below.

import Foundation
import CoreData

extension ConversationStore {

    // MARK: - Write

    /// Open one `inFlight` attempt row for `draft`, at the final pre-transport
    /// boundary and never earlier. Returns the context to carry until the turn
    /// lands, or nil when nothing was stored.
    ///
    /// BEST-EFFORT BY CONTRACT: a store that will not load, an insert that will
    /// not save, a row that already exists — all return nil, and the caller
    /// dispatches anyway with its nil-variant metadata. The one thing this must
    /// never do is fail a valid BYO-gateway request in order to measure it.
    ///
    /// `startedAt` is stamped INSIDE the transaction, so the elapsed time the
    /// terminal callback later closes measures the hop and not the actor hop in
    /// front of it. It is not proof that bytes crossed the wire — only that
    /// Conduck committed to sending.
    ///
    /// The scalar snapshots are ALWAYS written; the `userMessage` relationship
    /// is set only when the message resolves in this context. That asymmetry is
    /// deliberate: the relationship is what carries the cascade delete, and the
    /// scalars are what survive a row whose parent has not imported yet. A row
    /// with only the scalars is still countable and still deletable — see
    /// `deleteGatewayAttempts`.
    func beginGatewayAttempt(draft: GatewayAttemptDraft) async -> GatewayAttemptContext? {
        do { try await ensureLoaded() } catch { return nil }
        let context = newWriteContext()
        let openedAt: Date? = await context.perform { [context] in
            // One attempt id opens one row, ever. A re-entrant begin on the same
            // candidate id is not a second dispatch and must not become a second
            // recorded attempt.
            guard Self.gatewayAttemptRow(id: draft.attemptID, in: context) == nil else { return nil }

            let startedAt = Date()
            let row = NSEntityDescription.insertNewObject(
                forEntityName: "GatewayAttempt", into: context
            )
            row.setValue(draft.attemptID, forKey: "id")
            row.setValue(draft.conversationID, forKey: "conversationID")
            row.setValue(draft.userMessageID, forKey: "userMessageID")
            row.setValue(draft.gatewayRef, forKey: "gatewayRef")
            row.setValue(draft.origin.rawValue, forKey: "originSurface")
            row.setValue(draft.inputMode.rawValue, forKey: "inputMode")
            row.setValue(draft.requestedModel, forKey: "requestedModel")
            row.setValue(startedAt, forKey: "startedAt")
            row.setValue(GatewayAttemptOutcome.inFlight.rawValue, forKey: "outcome")
            // Stamped so a later client can change what an attempt MEANS
            // without its rows mixing silently into this one's totals.
            row.setValue(
                NSNumber(value: GatewayAttemptRecord.currentRecordVersion),
                forKey: "recordVersion"
            )

            let userRequest = NSFetchRequest<NSManagedObject>(entityName: "Message")
            userRequest.predicate = NSPredicate(format: "id == %@", draft.userMessageID as CVarArg)
            userRequest.fetchLimit = 1
            if let userMessage = (try? context.fetch(userRequest))?.first {
                row.setValue(userMessage, forKey: "userMessage")
            }

            do { try context.save() } catch { return nil }
            return startedAt
        }
        guard let openedAt else { return nil }
        return GatewayAttemptContext(attemptID: draft.attemptID, startedAt: openedAt)
    }

    /// Close one attempt row that no core landing is closing for it — the
    /// cancel-before-dispatch paths, and the post-send cancel that keeps today's
    /// Message UX. Update-only, and only out of `inFlight`.
    ///
    /// Claimed through `terminalClaims` for the reason `beginRetry` claims
    /// retries: an actor method accepts another call while awaiting Core Data,
    /// so the row's own `inFlight` predicate is a durable cross-process gate but
    /// not a same-process mutex. A losing claimant does nothing at all — the
    /// holder is already writing this attempt's one terminal transition.
    func terminalizeGatewayAttempt(_ observation: TerminalAttemptObservation) async {
        guard let attemptID = observation.attemptID else { return }
        guard terminalClaims.insert(attemptID).inserted else { return }
        defer { terminalClaims.remove(attemptID) }
        do { try await ensureLoaded() } catch { return }
        await writeTerminalObservation(observation)
    }

    /// The unclaimed terminal write. Callers that already hold this attempt's
    /// `terminalClaims` entry — the combined landings in `ConversationStore.swift`
    /// retrying measurement after a fail-open core save — use this directly;
    /// everyone else goes through `terminalizeGatewayAttempt`.
    func writeTerminalObservation(_ observation: TerminalAttemptObservation) async {
        guard let attemptID = observation.attemptID else { return }
        let context = newWriteContext()
        await context.perform { [context] in
            guard let row = Self.gatewayAttemptRow(id: attemptID, in: context) else { return }
            guard Self.applyTerminalObservation(observation, to: row) else { return }
            try? context.save()
        }
    }

    /// Delete every attempt whose SCALAR `conversationID` names `conversationID`.
    /// The relationship cascade already removes attempts linked to a deleted
    /// conversation's messages; this covers the rows whose relationship was
    /// never set or has not imported, which the cascade cannot see.
    ///
    /// Posts on a real deletion, unlike every other write here: no `Message`
    /// write accompanies this one, so nothing else would tell an open dashboard
    /// its totals moved.
    func deleteGatewayAttempts(conversationID: UUID) async {
        do { try await ensureLoaded() } catch { return }
        let context = newWriteContext()
        let deleted: Bool = await context.perform { [context] in
            let rows = Self.gatewayAttemptRows(conversationID: conversationID, in: context)
            guard !rows.isEmpty else { return false }
            for row in rows { context.delete(row) }
            do { try context.save() } catch { return false }
            return true
        }
        if deleted { await postDidChange() }
    }

    // MARK: - Read

    /// Every attempt the dashboard may count, oldest start first.
    ///
    /// `from`/`to` bound `startedAt` inclusively; a row with no start instant is
    /// therefore outside every bounded range and inside the unbounded one, which
    /// is the honest reading — it happened, but it cannot be placed in time.
    ///
    /// ORPHANS ARE FILTERED, NEVER DELETED. An attempt whose `conversationID`
    /// does not resolve to a live `Conversation` is left out of the result and
    /// left alone in the store. Mirroring cannot distinguish "the parent was
    /// deleted" from "the parent has not imported yet", so absence is not
    /// evidence: deleting on it would sync permanent loss the first time a slow
    /// import outran the read. Such rows stay stored-but-invisible, which is the
    /// accepted convergence limit.
    func fetchGatewayAttempts(from: Date? = nil, to: Date? = nil) async throws -> [GatewayAttemptRecord] {
        try await ensureLoaded()
        let context = newReadContext()
        return try await context.perform { [context] in
            let live = Self.liveConversationIDs(in: context)
            guard !live.isEmpty else { return [] }

            let request = NSFetchRequest<NSManagedObject>(entityName: "GatewayAttempt")
            var clauses: [NSPredicate] = []
            if let from {
                clauses.append(NSPredicate(format: "startedAt >= %@", from as NSDate))
            }
            if let to {
                clauses.append(NSPredicate(format: "startedAt <= %@", to as NSDate))
            }
            if !clauses.isEmpty {
                request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: clauses)
            }
            // Oldest first, so the daily buckets and the "measuring since"
            // caption read the same order the aggregator walks.
            request.sortDescriptors = [NSSortDescriptor(key: "startedAt", ascending: true)]

            return try context.fetch(request).compactMap { row -> GatewayAttemptRecord? in
                guard
                    let conversationID = row.value(forKey: "conversationID") as? UUID,
                    live.contains(conversationID)
                else { return nil }
                return GatewayAttemptRecord(managedObject: row)
            }
        }
    }

    /// When measurement began: the earliest `startedAt` among attempts the
    /// dashboard can still see. Deliberately the VISIBLE earliest rather than
    /// the stored one — a caption reading "measuring since" a date whose
    /// conversation the user deleted would describe totals that no longer
    /// include it.
    ///
    /// Walks oldest-first and stops at the first row it can attribute, so the
    /// common answer costs one row. Only a store whose oldest attempts are all
    /// orphans walks further, and that is exactly the case where stopping early
    /// would give the wrong date.
    func earliestGatewayAttemptStart() async throws -> Date? {
        try await ensureLoaded()
        let context = newReadContext()
        return try await context.perform { [context] in
            let live = Self.liveConversationIDs(in: context)
            guard !live.isEmpty else { return nil }

            let request = NSFetchRequest<NSManagedObject>(entityName: "GatewayAttempt")
            request.predicate = NSPredicate(format: "startedAt != nil")
            request.sortDescriptors = [NSSortDescriptor(key: "startedAt", ascending: true)]
            for row in try context.fetch(request) {
                guard
                    let conversationID = row.value(forKey: "conversationID") as? UUID,
                    live.contains(conversationID)
                else { continue }
                return row.value(forKey: "startedAt") as? Date
            }
            return nil
        }
    }

    // MARK: - Shared row mechanics
    //
    // Internal rather than private because `ConversationStore.swift` — the same
    // actor, a sibling FILE, which `private` does not reach — joins attempt
    // terminalization to its own message transactions.

    /// Apply one terminal observation to a row. UPDATE-ONLY, and only out of
    /// `inFlight`: an attempt makes exactly one terminal transition, so an
    /// already-terminal row means a duplicate or late callback and is left
    /// exactly as it stands. Returns whether anything was written.
    ///
    /// "Already terminal" is decided by `storedOutcomeIsTerminal`, which is the
    /// same call the read side makes — see its own comment for why an ABSENT
    /// column is open and an unrecognised one is not.
    ///
    /// The six reported columns are written only when the gateway actually
    /// reported something. `GatewayResponseMetadata.isEmpty` collapses "the
    /// gateway reports no usage" and "the parse found nothing usable" into the
    /// one state they are.
    @discardableResult
    static func applyTerminalObservation(
        _ observation: TerminalAttemptObservation,
        to row: NSManagedObject
    ) -> Bool {
        guard !storedOutcomeIsTerminal(row) else { return false }

        row.setValue(observation.outcome.rawValue, forKey: "outcome")
        row.setValue(observation.completedAt, forKey: "completedAt")
        row.setValue(
            observation.appErrorCode.map { NSNumber(value: $0) },
            forKey: "appErrorCode"
        )

        if let metadata = observation.metadata, !metadata.isEmpty {
            row.setValue(metadata.reportedModel, forKey: "reportedModel")
            row.setValue(metadata.reportedResponseID, forKey: "reportedResponseID")
            row.setValue(metadata.finishReason, forKey: "finishReason")
            row.setValue(
                metadata.reportedInputTokens.map { NSNumber(value: $0) },
                forKey: "reportedInputTokens"
            )
            row.setValue(
                metadata.reportedOutputTokens.map { NSNumber(value: $0) },
                forKey: "reportedOutputTokens"
            )
            row.setValue(
                metadata.reportedTotalTokens.map { NSNumber(value: $0) },
                forKey: "reportedTotalTokens"
            )
        }
        return true
    }

    /// Whether `row`'s STORED outcome already closed this attempt — the one
    /// question every writer asks before touching a row, and the reason it lives
    /// here rather than being re-derived at each site.
    ///
    /// AN ABSENT COLUMN IS OPEN, matching the read side exactly
    /// (`GatewayAttemptRecord.hasStoredOutcome`). Absence is not a verdict: a
    /// row with no outcome at all is half-materialised — a CloudKit import
    /// caught mid-flight, a foreign writer — and reading it as terminal would
    /// make it permanently unclosable, refusing the owning device's real answer
    /// forever while the dashboard hedged the same row as `unconfirmed`.
    /// Writer and reader have to make the SAME call here or a row exists that
    /// neither can ever resolve.
    ///
    /// AN UNRECOGNISED STRING STAYS TERMINAL, which is the opposite case: some
    /// client did record a verdict, in a vocabulary this build does not know,
    /// and overwriting it would be this device guessing over a real answer.
    static func storedOutcomeIsTerminal(_ row: NSManagedObject) -> Bool {
        guard let raw = row.value(forKey: "outcome") as? String else { return false }
        return GatewayAttemptOutcome.from(raw: raw).isTerminal
    }

    /// The one attempt row carrying `id` in `context`, or nil. Never throws —
    /// every caller is on a path where a failed fetch and an absent row mean the
    /// same thing: no measurement.
    static func gatewayAttemptRow(id: UUID, in context: NSManagedObjectContext) -> NSManagedObject? {
        let request = NSFetchRequest<NSManagedObject>(entityName: "GatewayAttempt")
        request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        request.fetchLimit = 1
        return (try? context.fetch(request))?.first
    }

    /// Every attempt row whose SCALAR `conversationID` names `conversationID`.
    static func gatewayAttemptRows(
        conversationID: UUID,
        in context: NSManagedObjectContext
    ) -> [NSManagedObject] {
        let request = NSFetchRequest<NSManagedObject>(entityName: "GatewayAttempt")
        request.predicate = NSPredicate(format: "conversationID == %@", conversationID as CVarArg)
        return (try? context.fetch(request)) ?? []
    }

    /// Every attempt row in the store. Used only where every conversation is
    /// being deleted, so no row can survive as anything but an orphan.
    static func allGatewayAttemptRows(in context: NSManagedObjectContext) -> [NSManagedObject] {
        let request = NSFetchRequest<NSManagedObject>(entityName: "GatewayAttempt")
        return (try? context.fetch(request)) ?? []
    }

    /// The ids of every `Conversation` this context can see — the set an
    /// attempt has to name to be countable. Built with a plain object fetch
    /// rather than a dictionary/expression one: those are the fetch shapes the
    /// in-memory store the whole suite runs on does not support uniformly, and a
    /// read path that behaves differently under test than in production is worth
    /// less than the columns it saves faulting. Conversation counts are
    /// user-scale, and this runs once per dashboard read.
    static func liveConversationIDs(in context: NSManagedObjectContext) -> Set<UUID> {
        let request = NSFetchRequest<NSManagedObject>(entityName: "Conversation")
        let rows = (try? context.fetch(request)) ?? []
        return Set(rows.compactMap { $0.value(forKey: "id") as? UUID })
    }
}
