// SPDX-License-Identifier: Apache-2.0

// Conduck
// ConversationStore+GatewayAttempts.swift
//
// The persistence half of the gateway-attempt ledger: opening a row at the
// final pre-transport boundary, closing it exactly once when a turn lands,
// reading it back for the dashboard, and deleting it only when the user asks.
// An extension of the SAME actor rather than a store of its own,
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
// loop `ConversationStore`'s header argues against. The exceptions are the
// explicit deletion — `purgeGatewayAttempts`, the one primitive that removes an
// attempt row, reached by the user clearing usage history and by `deleteAll`'s
// erase-everything — which no other attempt write accompanies.
//
// USAGE HISTORY OUTLIVES THE CONVERSATIONS IT DESCRIBES. Attempt rows are
// first-class: a row whose conversation is deleted, never imported, or
// unattributable stays readable and countable, and the ONLY things that remove
// one are the user clearing usage history and an erase-everything. Retention is
// temporal decoupling and nothing more — the rows never leave this private
// store, and they carry no more than they ever did.
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
    /// deliberate: the scalars are what a row carries on its own, and the
    /// relationship is an enrichment the read side uses when it happens to be
    /// there. A row with only the scalars is fully countable.
    ///
    /// The four attachment-shape counts are written as EXPLICIT ZEROES, never
    /// left absent. Nil on those columns means "this build did not measure",
    /// which is a claim only a row written before they existed may make; a
    /// dispatch that genuinely carried no image and no text file has to say so,
    /// or every coverage denominator on the dashboard silently shrinks.
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
            // The device that executed THIS dispatch, base word only — a retry
            // reflects the retry's device, never the turn's. Nil where the
            // surface cannot name one; the read side then falls back to the
            // user turn's own tag.
            row.setValue(draft.deviceClass, forKey: "originDeviceClass")
            row.setValue(
                NSNumber(value: draft.currentTurnInlineImageCount),
                forKey: "currentTurnInlineImageCount"
            )
            row.setValue(
                NSNumber(value: draft.priorTurnInlineImageCount),
                forKey: "priorTurnInlineImageCount"
            )
            row.setValue(
                NSNumber(value: draft.currentTurnInlineTextFileCount),
                forKey: "currentTurnInlineTextFileCount"
            )
            row.setValue(
                NSNumber(value: draft.priorTurnInlineTextFileCount),
                forKey: "priorTurnInlineTextFileCount"
            )
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

    // MARK: - Read

    /// Every attempt the dashboard may count, oldest start first.
    ///
    /// `from`/`to` bound `startedAt` inclusively; a row with no start instant is
    /// therefore outside every bounded range and inside the unbounded one, which
    /// is the honest reading — it happened, but it cannot be placed in time.
    ///
    /// NO ROW IS FILTERED OUT FOR ITS PARENT'S SAKE. An attempt whose
    /// conversation was deleted, has not imported yet, or was never named at all
    /// still counts: it measures a dispatch that really happened, and the
    /// dashboard describes the user's gateways rather than their kept threads.
    /// Thread-level grouping simply has nothing to hang an unattributed row on
    /// and leaves it out of that one view.
    ///
    /// `clearedThrough` is the synced clear cutoff, supplied by the caller from
    /// settings so this store stays settings-free. Rows at or before it are
    /// excluded from the moment the cutoff is set, whether or not the purge that
    /// follows has run — which is what makes a Clear on one device take effect
    /// on the next before any deletion syncs. An undated row is excluded too:
    /// "clear everything up to now" cannot mean "except the rows that cannot say
    /// when they happened", and the purge removes exactly the same set.
    ///
    /// The user turn is PREFETCHED because every row wants one field off it —
    /// `sourceDevice`, for the device bucket a row written before
    /// `originDeviceClass` existed cannot supply itself. Faulting that
    /// per-row over a hundred thousand rows is the difference between one fetch
    /// and a hundred thousand.
    func fetchGatewayAttempts(
        from: Date? = nil,
        to: Date? = nil,
        clearedThrough: Date? = nil
    ) async throws -> [GatewayAttemptRecord] {
        try await ensureLoaded()
        let context = newReadContext()
        return try await context.perform { [context] in
            let request = NSFetchRequest<NSManagedObject>(entityName: "GatewayAttempt")
            var clauses: [NSPredicate] = []
            if let from {
                clauses.append(NSPredicate(format: "startedAt >= %@", from as NSDate))
            }
            if let to {
                clauses.append(NSPredicate(format: "startedAt <= %@", to as NSDate))
            }
            if let clearedThrough {
                clauses.append(Self.notClearedPredicate(through: clearedThrough))
            }
            if !clauses.isEmpty {
                request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: clauses)
            }
            // Oldest first, so the daily buckets and the "measuring since"
            // caption read the same order the aggregator walks.
            request.sortDescriptors = [NSSortDescriptor(key: "startedAt", ascending: true)]
            request.relationshipKeyPathsForPrefetching = ["userMessage"]

            return try context.fetch(request).map { row -> GatewayAttemptRecord in
                var record = GatewayAttemptRecord(managedObject: row)
                // Enrichment, never storage: the tag belongs to the user turn,
                // and copying it into the attempt row would duplicate a fact
                // that is already there and can already change.
                record.fallbackSourceDevice =
                    (row.value(forKey: "userMessage") as? NSManagedObject)?
                    .value(forKey: "sourceDevice") as? String
                return record
            }
        }
    }

    /// When measurement began: the earliest `startedAt` still retained. One
    /// fetch of one row, because nothing about the row's parent can disqualify
    /// it any more.
    ///
    /// `clearedThrough` applies for the same reason it applies to the read
    /// above: a caption reading "measuring since" a date the user just cleared
    /// past would describe a period the dashboard no longer counts.
    func earliestGatewayAttemptStart(clearedThrough: Date? = nil) async throws -> Date? {
        try await ensureLoaded()
        let context = newReadContext()
        return try await context.perform { [context] in
            let request = NSFetchRequest<NSManagedObject>(entityName: "GatewayAttempt")
            var clauses = [NSPredicate(format: "startedAt != nil")]
            if let clearedThrough {
                clauses.append(NSPredicate(format: "startedAt > %@", clearedThrough as NSDate))
            }
            request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: clauses)
            request.sortDescriptors = [NSSortDescriptor(key: "startedAt", ascending: true)]
            request.fetchLimit = 1
            return try context.fetch(request).first?.value(forKey: "startedAt") as? Date
        }
    }

    /// The ids of every `Conversation` this device can currently resolve. The
    /// dashboard gates thread NAVIGATION on it — a heaviest-thread row whose
    /// conversation is absent renders without a chevron rather than pushing a
    /// screen onto nothing — and gates nothing else: absence never removes a
    /// row from a count, and never deletes anything.
    func liveConversationIDs() async -> Set<UUID> {
        do { try await ensureLoaded() } catch { return [] }
        let context = newReadContext()
        return await context.perform { [context] in
            Self.liveConversationIDs(in: context)
        }
    }

    // MARK: - Purge

    /// Delete every attempt row at or before `cutoff`, and report how many went.
    /// THE ONE WAY AN ATTEMPT ROW IS EVER DELETED — "Clear usage history" and
    /// the erase-everything both come through here, and nothing else removes a
    /// row at all.
    ///
    /// OBJECT-LEVEL DELETES, NOT `NSBatchDeleteRequest`. A batch delete bypasses
    /// the managed-object layer, and Apple does not guarantee it composes with
    /// CloudKit mirroring — an unexported tombstone is a clear that silently
    /// stops at the device it was tapped on, which is the opposite of what this
    /// primitive promises.
    ///
    /// Batched with a fetch LIMIT and never an OFFSET: the rows are being
    /// deleted as they are read, so every pass must start again at the top of
    /// what is left. An offset would skip exactly as many rows as the previous
    /// pass removed. The context is saved AND reset per batch so a hundred
    /// thousand rows never coexist in one context's registry.
    ///
    /// IDEMPOTENT AND RESUMABLE: a run interrupted halfway leaves the rows it
    /// already deleted deleted, and a later run finishes the job. Re-running
    /// against a store with nothing left costs one empty fetch and posts
    /// nothing.
    @discardableResult
    func purgeGatewayAttempts(through cutoff: Date) async throws -> Int {
        try await ensureLoaded()
        let context = newWriteContext()
        var deleted = 0
        while true {
            let batch: Int = try await context.perform { [context] in
                let request = NSFetchRequest<NSManagedObject>(entityName: "GatewayAttempt")
                request.predicate = Self.clearedPredicate(through: cutoff)
                request.fetchLimit = Self.gatewayAttemptPurgeBatchSize
                let rows = try context.fetch(request)
                guard !rows.isEmpty else { return 0 }
                for row in rows { context.delete(row) }
                try context.save()
                context.reset()
                return rows.count
            }
            if batch == 0 { break }
            deleted += batch
        }
        // One post for the whole purge: no `Message` write accompanies it, and
        // an open dashboard has to be told its totals moved exactly once.
        if deleted > 0 { await postDidChange() }
        return deleted
    }

    /// How many rows one purge pass materialises. An engineering bound on the
    /// context's registry, not a semantic one — the loop repeats until the
    /// predicate matches nothing, so the value only trades pass count against
    /// peak memory.
    static let gatewayAttemptPurgeBatchSize = 500

    /// Rows a clear cutoff covers. An UNDATED row is included: a cutoff means
    /// "everything up to now", and a row that cannot say when it happened
    /// cannot claim to have happened after. Reads and the purge share this so
    /// the set the dashboard stops counting is exactly the set that gets
    /// deleted.
    static func clearedPredicate(through cutoff: Date) -> NSPredicate {
        NSPredicate(format: "startedAt == nil OR startedAt <= %@", cutoff as NSDate)
    }

    /// The complement of `clearedPredicate` — what a read after a clear may
    /// still see.
    static func notClearedPredicate(through cutoff: Date) -> NSPredicate {
        NSPredicate(format: "startedAt != nil AND startedAt > %@", cutoff as NSDate)
    }

    #if DEBUG
    /// Test-only: clear an attempt row's `startedAt` to produce the undated row
    /// a half-materialised import really can deliver (`GatewayAttempt.startedAt`
    /// is `optional="YES"`). Nothing else can build one — every begin stamps the
    /// instant inside its own transaction — and the clear cutoff's treatment of
    /// such a row is otherwise unverifiable. Not used by app code.
    func debugClearGatewayAttemptStart(attemptID: UUID) async throws {
        try await ensureLoaded()
        let context = newWriteContext()
        try await context.perform { [context] in
            guard let row = Self.gatewayAttemptRow(id: attemptID, in: context) else { return }
            row.setValue(nil, forKey: "startedAt")
            try context.save()
        }
    }
    #endif

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
    /// The reported columns are written only when the gateway actually reported
    /// something. `GatewayResponseMetadata.isEmpty` collapses "the gateway
    /// reports no usage" and "the parse found nothing usable" into the one state
    /// they are.
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
            // The three DETAIL columns travel with the rest and never on their
            // own path: each is a SUBSET of a figure already written above —
            // cached and cache-write of the input, reasoning of the output — so
            // no reader may add one into a total. Nil stays nil; there is no
            // backfill and no derivation.
            row.setValue(
                metadata.reportedCachedInputTokens.map { NSNumber(value: $0) },
                forKey: "reportedCachedInputTokens"
            )
            row.setValue(
                metadata.reportedCacheWriteInputTokens.map { NSNumber(value: $0) },
                forKey: "reportedCacheWriteInputTokens"
            )
            row.setValue(
                metadata.reportedReasoningOutputTokens.map { NSNumber(value: $0) },
                forKey: "reportedReasoningOutputTokens"
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

    /// The ids of every `Conversation` this context can see. Built with a plain object fetch
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
