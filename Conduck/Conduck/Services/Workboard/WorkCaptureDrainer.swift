// SPDX-License-Identifier: Apache-2.0

// Conduck
// WorkCaptureDrainer.swift
//
// Imports the Workboard's inert App-Group capture queue into private Workboard
// persistence. Work is a single desk, so the drainer resolves no destination: a
// share-sheet capture, a menu-bar capture and a GigaAction voice note all land
// on `Constants.workboardDeskItemID` through `ConversationStore.upsertDeskMaterial`,
// and `targetWorkItemID` — which the share extension cannot resolve from its
// sandbox anyway — is never honoured as a destination: it is carried into the
// desk write as evidence only, naming the item a build before the single desk
// could have appended these same rows onto. Envelope and entry UUIDs are reused
// as database identities, so a crash after any individual write is repaired by
// replay rather than by making a second material.
//
// Two rules protect the bytes, because until a claim is acknowledged the queue
// holds the only copy of a shared file. A claim is acknowledged only once every
// material this capture wrote reads back out of the store — the row, and for a
// card that carries bytes a payload this device can actually READ, which is a
// complete blob row on the synced lane and a present leaf on the vault lane.
// And the claim's filesystem lease is renewed for as long as that import takes,
// so a large or slow capture cannot age past the queue's stale horizon and be
// reclaimed by another process mid-write. Losing that ownership is terminal: a
// renewal that proves another acquisition holds the claim cancels the import,
// which then writes no further material, acknowledges nothing, and releases
// nothing it no longer owns.
//
// One persistence failure is not retryable and must not be treated as one. A
// desk write refuses an id already held by a card of another kind, and that
// state never clears on its own — releasing the claim would requeue an entry
// that refuses identically on every drain and stops every capture behind it.
// So the card is published once more under
// `WorkMaterialCollisionEscape.materialID(forCapture:)`, and only a refusal of
// that id too retires the capture: its bytes are copied into `refused/` beside
// the queue before the entry is acknowledged, and the drain carries on.
//
// This type has no gateway dependency and no dispatch API: opening the app can
// drain captures, but can never turn one into network work.

#if !os(watchOS)

import Foundation

actor WorkCaptureDrainer {
    struct Report: Sendable, Equatable {
        let importedCaptureCount: Int
        let replayedCaptureCount: Int
        /// Captures the queue could not turn into cards, and no longer holds:
        /// a malformed envelope destroyed at claim time, or one the desk
        /// refused under both its own id and its escape id. Both are terminal,
        /// and both are the same thing to the person — a shared item that did
        /// not arrive — which is why one count carries them.
        let invalidCaptureCount: Int
        let importedMaterialCount: Int

        static let empty = Report(
            importedCaptureCount: 0,
            replayedCaptureCount: 0,
            invalidCaptureCount: 0,
            importedMaterialCount: 0
        )
    }

    private struct PersistedCapture: Sendable {
        let wasReplay: Bool
        /// Every material this capture published, in the order it was written.
        /// The acknowledgement barrier reads these back before the queue copy
        /// of the bytes is destroyed.
        let materialIDs: [UUID]
        /// The subset whose bytes came out of the claimed directory. Only these
        /// have to prove a readable payload before acknowledgement: a note, a
        /// shared text and a link carry their whole content in the row, so a
        /// payload requirement on them would refuse every valid capture.
        let payloadBearingIDs: Set<UUID>

        var materialCount: Int { materialIDs.count }
    }

    /// What one claim's import did. A refusal is not an error the drain stops
    /// on: that entry has left the queue, and the captures behind it still have
    /// to land in the same pass.
    private enum ImportOutcome: Sendable {
        case published(PersistedCapture)
        case refused
    }

    /// Both ids one card of a capture may be published under are held by cards
    /// of another kind. Terminal by construction: `WorkMaterialCollisionEscape`
    /// derives one escape and never a second, so there is nothing further to
    /// try and the entry may not go back into the queue.
    private struct TerminalCollision: Error {
        let materialID: UUID
        let escapeID: UUID

        /// Written beside the retired bytes. Forensic, never displayed: it is
        /// the only record of what a person shared and never received.
        var reason: String {
            """
            Refused: \(materialID.uuidString) and its escape id \
            \(escapeID.uuidString) both name a card of another kind.
            """
        }
    }

    /// Where a capture goes that can never become cards. A sibling of
    /// `processing/` inside the inbox root, and deliberately not named for a
    /// UUID: the inbox counts only UUID-named children of that root as pending
    /// work and reconciles only `processing/` and `tmp/`, so nothing here is
    /// ever claimed, requeued or swept.
    private static let refusedDirectoryName = "refused"

    private static let refusalReasonFilename = "refusal.txt"

    /// How often an active claim's lease is renewed. Deliberately several times
    /// below `WorkCaptureInbox.staleClaimHorizon` so that consecutive missed
    /// renewals — a suspended app, a device under load — still leave the claim
    /// covered, and never so close to it that a single late beat hands a
    /// directory this drainer is reading to another process.
    static let defaultLeaseHeartbeatInterval: Duration = .seconds(60)

    private let inbox: WorkCaptureInbox
    private let store: ConversationStore
    private let sourceDevice: String
    private let leaseHeartbeatInterval: Duration
    /// Timestamp written into each renewed lease. Injectable for the same
    /// reason `WorkCaptureInbox.claimNext(now:)` and `reconcile(now:)` are: the
    /// horizon this heartbeat exists to outrun is five minutes long, and no
    /// test can be made to wait one.
    private let now: @Sendable () -> Date

    init(
        inbox: WorkCaptureInbox = .shared,
        store: ConversationStore = .shared,
        sourceDevice: String,
        leaseHeartbeatInterval: Duration = WorkCaptureDrainer.defaultLeaseHeartbeatInterval,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.inbox = inbox
        self.store = store
        self.sourceDevice = sourceDevice
        self.leaseHeartbeatInterval = leaseHeartbeatInterval
        self.now = now
    }

    #if CONDUCK_TESTING
    /// TEST SEAM — hold one import open inside the region its lease covers.
    ///
    /// WHY IT HAS TO EXIST. The heartbeat's whole claim is about an import that
    /// outlives the stale horizon, and nothing else in this type can produce
    /// one: a bounded envelope persists in milliseconds. Without somewhere to
    /// hold an import open, ownership could only be observed by racing a
    /// sampler against a live drain, which measures timing rather than
    /// ownership — and the payload-disappearance the acknowledgement barrier
    /// refuses could not be staged at all, because it happens between the write
    /// and the barrier. Awaited between persistence and the barrier; nil on
    /// every production path.
    private var importHoldForTesting: (@Sendable () async -> Void)?

    func _setImportHoldForTesting(_ hold: (@Sendable () async -> Void)?) {
        importHoldForTesting = hold
    }

    /// TEST SEAM — hold one import open BETWEEN two of its material writes.
    ///
    /// WHY IT HAS TO EXIST. The interval the lease is FOR is the one in which a
    /// capture's bytes are read and stored, and that interval is inside
    /// `persist`: by the time the hold above is reached every byte of the
    /// capture is already written. Nothing else in this type can park an import
    /// there — a bounded envelope crosses that window in milliseconds — so a
    /// takeover racing a slow byte import, and the cancellation that must stop
    /// one, could otherwise only be raced rather than staged. The argument is
    /// the number of materials already written, so a test can park at exactly
    /// one write boundary. Nil on every production path.
    private var materialWriteHoldForTesting: (@Sendable (Int) async -> Void)?

    func _setMaterialWriteHoldForTesting(_ hold: (@Sendable (Int) async -> Void)?) {
        materialWriteHoldForTesting = hold
    }
    #endif

    /// Reconcile crash-stranded claims, then consume the queue oldest-first.
    /// Malformed captures have already been removed by `claimNext`; they do not
    /// prevent a later valid capture from importing. A persistence failure — or
    /// a capture whose payload does not read back — puts the active claim back
    /// before surfacing the error, preserving its bytes.
    func drainAvailableCaptures() async throws -> Report {
        _ = await inbox.reconcile()

        var importedCaptureCount = 0
        var replayedCaptureCount = 0
        var invalidCaptureCount = 0
        var importedMaterialCount = 0

        while true {
            // A cancelled drain claims nothing further. The capture it would
            // take could only be released again, and a queue entry is safest
            // exactly where its publisher left it.
            try Task.checkCancellation()
            let claim: WorkCaptureInbox.Claim?
            do {
                claim = try await inbox.claimNext()
            } catch let error as WorkCaptureInbox.InboxError {
                if case .invalidEnvelope = error {
                    invalidCaptureCount += 1
                    continue
                }
                throw error
            }

            guard let claim else { break }
            // Everything that touches the claimed directory happens under a
            // renewed lease — the release included, since it moves the very
            // files another process would otherwise be entitled to requeue.
            switch try await importUnderRenewedLease(claim) {
            case .published(let persisted):
                if persisted.wasReplay {
                    replayedCaptureCount += 1
                } else {
                    importedCaptureCount += 1
                }
                importedMaterialCount += persisted.materialCount
            case .refused:
                // The disposition a malformed envelope already gets: the queue
                // no longer holds it, the person is told one shared item did
                // not arrive, and the loop goes on to the captures behind it.
                // Unlike a malformed envelope its bytes still exist — this
                // drainer copied them out before the acknowledgement.
                invalidCaptureCount += 1
            }
        }

        return Report(
            importedCaptureCount: importedCaptureCount,
            replayedCaptureCount: replayedCaptureCount,
            invalidCaptureCount: invalidCaptureCount,
            importedMaterialCount: importedMaterialCount
        )
    }

    /// Publish one claimed capture onto the desk. Publication order is the
    /// order the cards appear in: the person's own note first, then the shared
    /// entries by their captured sequence. Rank itself is decided inside the
    /// desk write, which is the only place that can count the desk's existing
    /// cards without racing a concurrent capture.
    private func persist(
        _ claim: WorkCaptureInbox.Claim,
        ownership: ImportOwnership
    ) async throws -> PersistedCapture {
        let envelope = claim.envelope
        // A capture whose deterministic ids are already on the desk is the
        // replay of an import that was interrupted before its claim could be
        // acknowledged. The desk's material set answers that in one fetch.
        let expectedIDs = try Self.materialIDs(for: envelope)
        let existingIDs = Set(try await deskMaterials().map(\.id))
        let wasReplay = !existingIDs.isDisjoint(with: expectedIDs)

        var materialIDs: [UUID] = []
        var payloadBearingIDs: Set<UUID> = []

        // The share-sheet note is source material in its own right, and every
        // capture carries it onto the desk — including the first one ever made,
        // which has no earlier card to be read as an annotation of. Its UUID is
        // deterministic from the envelope, so a replay repairs the same card.
        let trimmedNote = envelope.note.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedNote.isEmpty {
            try await requireImportMayContinue(ownership, atMaterialBoundary: materialIDs.count)
            let note = try await upsertEscapingCollision(
                WorkMaterialDraft(
                    id: try Self.noteMaterialID(for: envelope),
                    kind: .note,
                    title: String(localized: "workboard.capture.note", defaultValue: "Share note"),
                    textContent: trimmedNote,
                    storageMode: .metadataOnly,
                    sourceDevice: sourceDevice,
                    createdAt: envelope.createdAt
                ),
                // Naming what a pre-desk drain of this same envelope could have
                // written is what licenses the desk write to re-home those
                // rows; without it a matching id is refused.
                legacyProvenance: Self.legacyProvenance(of: envelope)
            )
            materialIDs.append(note.id)
        }

        for entry in envelope.entries.sorted(by: Self.entryOrder) {
            try await requireImportMayContinue(ownership, atMaterialBoundary: materialIDs.count)
            let draft = try Self.materialDraft(
                for: entry,
                in: claim,
                sourceDevice: sourceDevice,
                createdAt: envelope.createdAt
            )
            let record: WorkMaterialRecord
            if let payloadURL = claim.payloadURL(for: entry) {
                let byteSize: Int64
                if let capturedByteCount = entry.byteCount {
                    byteSize = capturedByteCount
                } else {
                    byteSize = Int64(
                        try payloadURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                    )
                }
                record = try await upsertEscapingCollision(
                    draft,
                    sourceFileURL: payloadURL,
                    sourceFileByteSize: byteSize,
                    legacyProvenance: Self.legacyProvenance(of: envelope)
                )
                payloadBearingIDs.insert(record.id)
            } else {
                record = try await upsertEscapingCollision(
                    draft,
                    legacyProvenance: Self.legacyProvenance(of: envelope)
                )
            }
            materialIDs.append(record.id)
        }

        return PersistedCapture(
            wasReplay: wasReplay,
            materialIDs: materialIDs,
            payloadBearingIDs: payloadBearingIDs
        )
    }

    /// Publish one card of a capture, escaping an id collision exactly once.
    ///
    /// `invalidMaterialOwner` says this id is not this capture's to use: a card
    /// of another KIND already stands there, or a foreign owner row holds it
    /// and the envelope cannot prove the row is its own. Neither state clears
    /// on its own, so a release-and-retry loops for ever on the same refusal
    /// and — because the drain stops at the first error — every capture behind
    /// it never lands either. Republishing under
    /// `WorkMaterialCollisionEscape.materialID(forCapture:)` is what ends that:
    /// the id is derived from the colliding one, so this process, the headless
    /// intent process and any later replay all repair the same card instead of
    /// adding another.
    ///
    /// Nothing is staged before the first refusal — the desk write refuses a
    /// kind collision ahead of the bytes and rolls back a leaf or blob it
    /// staged before the transaction refused — so the queue file the escape
    /// re-reads is still exactly what the person shared.
    ///
    /// A refusal of the escape id too is TERMINAL and says so in its own type:
    /// the caller retires the capture rather than deriving a third id.
    private func upsertEscapingCollision(
        _ draft: WorkMaterialDraft,
        sourceFileURL: URL? = nil,
        sourceFileByteSize: Int64? = nil,
        legacyProvenance: WorkMaterialLegacyProvenance
    ) async throws -> WorkMaterialRecord {
        do {
            return try await store.upsertDeskMaterial(
                draft,
                sourceFileURL: sourceFileURL,
                sourceFileByteSize: sourceFileByteSize,
                legacyProvenance: legacyProvenance
            )
        } catch WorkboardStoreError.invalidMaterialOwner {
            let escaped = Self.escaping(draft)
            do {
                return try await store.upsertDeskMaterial(
                    escaped,
                    sourceFileURL: sourceFileURL,
                    sourceFileByteSize: sourceFileByteSize,
                    legacyProvenance: legacyProvenance
                )
            } catch WorkboardStoreError.invalidMaterialOwner {
                throw TerminalCollision(materialID: draft.id, escapeID: escaped.id)
            }
        }
    }

    /// The same card under its escape id. Every other field is carried across
    /// verbatim: what collided is the identity, not the content, and a capture
    /// that arrives under a different name is still the thing the person
    /// shared.
    private static func escaping(_ draft: WorkMaterialDraft) -> WorkMaterialDraft {
        WorkMaterialDraft(
            id: WorkMaterialCollisionEscape.materialID(forCapture: draft.id),
            kind: draft.kind,
            title: draft.title,
            caption: draft.caption,
            textContent: draft.textContent,
            urlString: draft.urlString,
            filename: draft.filename,
            mimeType: draft.mimeType,
            payload: draft.payload,
            thumbnailData: draft.thumbnailData,
            width: draft.width,
            height: draft.height,
            byteSize: draft.byteSize,
            sequence: draft.sequence,
            storageMode: draft.storageMode,
            sourceDevice: draft.sourceDevice,
            cardSize: draft.cardSize,
            createdAt: draft.createdAt
        )
    }

    /// The cards the desk currently holds, from ONE fetch. The projection
    /// unions every physical desk row, so a duplicate row imported from another
    /// device does not hide a card this drainer already wrote, and each record
    /// arrives carrying the availability that same pass resolved.
    private func deskMaterials() async throws -> [WorkMaterialRecord] {
        let desk = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        return desk?.materials ?? []
    }

    /// The acknowledgement barrier. `WorkCaptureInbox.acknowledge` is the only
    /// thing that deletes a capture's bytes, and for a shared file the queue
    /// holds the only copy — so nothing is acknowledged until everything this
    /// capture wrote reads back out of the store, and reads back WHOLE.
    ///
    /// Presence of the row is not that proof. The two payload lanes commit in
    /// their own transactions, so a card can exist while its bytes do not: a
    /// `.syncedPayload` card whose blob row never landed is `.syncedPending`,
    /// and a `.localVault` card whose leaf is gone is unavailable. Both would
    /// pass an id check and then lose the only surviving copy of the payload to
    /// the acknowledgement.
    ///
    /// One desk fetch answers both lanes for the whole capture, because
    /// `WorkMaterialRecord.hasPayload` is decided by the store's single
    /// availability pass — a complete blob row on the synced lane, a present
    /// leaf on the vault lane. Completeness is consumed here, never restated.
    ///
    /// Anything short of that throws, which releases the claim and leaves the
    /// bytes in the queue for a later replay to repair.
    private func confirmDurablyImported(_ capture: PersistedCapture) async throws {
        guard !capture.materialIDs.isEmpty else { return }
        let durable = Dictionary(
            try await deskMaterials().map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        for id in capture.materialIDs {
            guard let material = durable[id] else {
                throw WorkboardStoreError.materialNotFound
            }
            guard !capture.payloadBearingIDs.contains(id) || material.hasPayload else {
                throw WorkboardStoreError.materialPayloadUnavailable
            }
        }
    }

    /// The gate every material write and the durability barrier pass. A claim
    /// proven lost is terminal: another acquisition owns those bytes now, and
    /// one more card written under it is a second import of the same capture.
    /// A cancelled drain stops here too, rather than at whichever later `await`
    /// happens to notice.
    private func requireImportMayContinue(
        _ ownership: ImportOwnership,
        atMaterialBoundary boundary: Int? = nil
    ) async throws {
        #if CONDUCK_TESTING
        if let boundary { await materialWriteHoldForTesting?(boundary) }
        #endif
        if await ownership.hasLostClaim { throw WorkCaptureInbox.InboxError.staleClaim }
        try Task.checkCancellation()
    }

    /// Persist one claim, prove its bytes read back, and only then consume the
    /// queue copy. The two operations that end a claim — the acknowledgement
    /// that deletes it, the release that requeues it — may only run while this
    /// drainer still owns it, so both are gated on the shared terminal state
    /// rather than on the import merely having reached them.
    private func persistAndAcknowledge(
        _ claim: WorkCaptureInbox.Claim,
        ownership: ImportOwnership
    ) async throws -> ImportOutcome {
        do {
            let persisted = try await persist(claim, ownership: ownership)
            #if CONDUCK_TESTING
            await importHoldForTesting?()
            #endif
            try await requireImportMayContinue(ownership)
            try await confirmDurablyImported(persisted)
            // The claim ends here: `acknowledge` deletes the directory, so the
            // marker the heartbeat can no longer read afterwards is this
            // import's own finished work rather than another process's.
            guard await ownership.endImport() else {
                throw WorkCaptureInbox.InboxError.staleClaim
            }
            try await inbox.acknowledge(claim)
            return .published(persisted)
        } catch let collision as TerminalCollision {
            // The one persistence failure a replay cannot repair. Requeueing it
            // would put back an entry that refuses identically on every drain
            // and blocks every capture behind it, so the entry leaves the queue
            // — but only after its bytes are somewhere else, because nothing
            // here proves the person does not still want them.
            guard await ownership.endImport() else {
                throw WorkCaptureInbox.InboxError.staleClaim
            }
            do {
                try retireRefusedCapture(claim, reason: collision.reason)
                try await inbox.acknowledge(claim)
                return .refused
            } catch {
                // The bytes are not yet safe outside the queue, so the queue
                // keeps them: this drain surfaces the fault and the entry is
                // claimed again next time.
                try? await inbox.release(claim)
                throw error
            }
        } catch {
            // Best effort is deliberately only for the ownership rollback. The
            // original persistence error remains the useful diagnosis; a release
            // that cannot land abandons its own claim inside the inbox, so
            // `reconcile` can recover the directory without waiting for a
            // relaunch. A claim proven lost is released by nobody: requeueing a
            // directory another acquisition holds would hand away bytes it is
            // reading.
            if await ownership.endImport() {
                try? await inbox.release(claim)
            }
            throw error
        }
    }

    /// Copy a refused capture's bytes out of the queue, so the entry that can
    /// never become cards can be acknowledged without destroying them.
    ///
    /// The copy comes BEFORE the acknowledgement for the reason the whole
    /// durability barrier exists: `acknowledge` deletes the only copy of a
    /// shared file. What lands in `refused/` is the WHOLE claimed directory —
    /// manifest and every payload, including entries that did publish —
    /// because a capture is one unit of a person's intent and splitting it here
    /// would take a judgement this drainer cannot make. The lease is not
    /// carried across: it names an acquisition of a queue this directory has
    /// left.
    ///
    /// Nothing sweeps `refused/`. It fills only when a UUIDv5-derived escape id
    /// also lands on a card of another kind, which is not a state a working
    /// device reaches; leaving the bytes is the cheaper mistake than deleting
    /// something a person shared.
    ///
    /// Idempotent, and it deletes nothing it did not itself write. The
    /// retirement is named for the ENVELOPE rather than for the acquisition
    /// that took it, so a retirement whose acknowledgement then failed — the
    /// entry goes back to the queue and refuses again on the next drain —
    /// writes no second copy of the same bytes. Two captures cannot share that
    /// name: the queue refuses a publication under an id it already holds.
    private func retireRefusedCapture(
        _ claim: WorkCaptureInbox.Claim,
        reason: String
    ) throws {
        let fileManager = FileManager.default
        let refused = claim.directoryURL
            .deletingLastPathComponent()  // processing/
            .deletingLastPathComponent()  // the inbox root
            .appendingPathComponent(Self.refusedDirectoryName, isDirectory: true)
        try fileManager.createDirectory(at: refused, withIntermediateDirectories: true)
        let destination = refused.appendingPathComponent(
            claim.id.uuidString,
            isDirectory: true
        )
        if !fileManager.fileExists(atPath: destination.path) {
            try fileManager.copyItem(at: claim.directoryURL, to: destination)
            try? fileManager.removeItem(
                at: destination.appendingPathComponent(
                    WorkCaptureInbox.leaseFilename,
                    isDirectory: false
                )
            )
        }
        try Data(reason.utf8).write(
            to: destination.appendingPathComponent(
                Self.refusalReasonFilename,
                isDirectory: false
            ),
            options: .atomic
        )
    }

    /// Run one claim's import under a lease this drainer keeps renewing, and
    /// end that import the moment a renewal proves the claim is no longer its.
    ///
    /// `WorkCaptureInbox.staleClaimHorizon` is a filesystem fact other
    /// processes read: the app and a headless intent process both reconcile the
    /// same queue, and a claim whose lease has aged past the horizon is fair
    /// game to requeue. A validated envelope may carry up to
    /// `WorkCaptureEnvelope.maximumEnvelopeBytes`, so persistence alone can
    /// outlast the horizon on a slow device, and a suspended app can stretch
    /// any import arbitrarily. Restating ownership periodically is what keeps a
    /// second drainer out of a directory this one is still reading and writing
    /// out of. The renewal covers persistence, the acknowledgement barrier and
    /// whichever of `acknowledge` or `release` ends the claim.
    ///
    /// The renewal is a structured child rather than a detached task because
    /// the beat and the import have to end together in both directions. A
    /// cancelled drain must leave no beat restating ownership of a claim nobody
    /// is importing; and a proven takeover must reach the import, because a
    /// former owner that keeps writing is the one thing that makes the three
    /// clocks — renewal, stale horizon, vault grace — stop describing a single
    /// owner. A renewal is still a hop onto the inbox actor and never waits for
    /// the executor the import occupies.
    private func importUnderRenewedLease(
        _ claim: WorkCaptureInbox.Claim
    ) async throws -> ImportOutcome {
        let ownership = ImportOwnership()
        return try await withThrowingTaskGroup(of: ImportOutcome?.self) { group in
            group.addTask { [inbox, leaseHeartbeatInterval, now] in
                while !Task.isCancelled {
                    do {
                        try await Task.sleep(for: leaseHeartbeatInterval)
                    } catch {
                        return nil
                    }
                    guard !Task.isCancelled else { return nil }
                    do {
                        try await inbox.refreshLease(claim, now: now())
                    } catch WorkCaptureInbox.InboxError.staleClaim {
                        // The one refusal that ends the beat, and it ends the
                        // import with it. A claim is generation-scoped, so a
                        // marker this drainer can no longer prove it owns names
                        // another acquisition — trying again cannot undo that.
                        await ownership.recordLostClaim()
                        return nil
                    } catch {
                        // A momentarily unreadable or unwritable marker is
                        // transient, and giving up on it would disarm the
                        // protection for the rest of a long import.
                    }
                }
                return nil
            }
            group.addTask { try await self.persistAndAcknowledge(claim, ownership: ownership) }

            while let outcome = try await group.next() {
                if let imported = outcome {
                    group.cancelAll()
                    return imported
                }
                guard await ownership.hasLostClaim else { continue }
                // Cancel the import and let it unwind before the loss is
                // surfaced: it must write no further material, and the claim
                // must be left exactly where its new owner put it.
                group.cancelAll()
                _ = try? await group.next()
                throw WorkCaptureInbox.InboxError.staleClaim
            }
            // The import returns a capture or throws, so the group cannot run
            // dry while it is still the one thing being awaited.
            throw CancellationError()
        }
    }

    // MARK: - Deterministic capture mapping

    /// What a replay of this envelope may re-home. A pre-desk drain had two
    /// destinations: with no chosen target it minted a Work item of its own and
    /// recorded the envelope on it, and with one it appended straight onto the
    /// item the person picked, writing nothing on that owner row. The envelope
    /// id accounts for the first; only the envelope's own `targetWorkItemID`
    /// accounts for the second, which is why the target the drainer never
    /// honours as a destination is still carried here as evidence.
    private static func legacyProvenance(
        of envelope: WorkCaptureEnvelope
    ) -> WorkMaterialLegacyProvenance {
        .captureEnvelope(envelope.id, legacyTargetWorkItemID: envelope.targetWorkItemID)
    }

    private static func entryOrder(
        _ lhs: WorkCaptureEnvelope.Entry,
        _ rhs: WorkCaptureEnvelope.Entry
    ) -> Bool {
        if lhs.sequence != rhs.sequence { return lhs.sequence < rhs.sequence }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    /// Every database identity this capture will publish. Their presence on the
    /// desk is what tells a replay from a first import; the note ID is included
    /// only when a visible note will actually be written. Publication validation
    /// refuses an envelope with neither a note nor an entry, so this is never
    /// empty for a claimed capture.
    private static func materialIDs(for envelope: WorkCaptureEnvelope) throws -> Set<UUID> {
        var ids = Set(envelope.entries.map(\.id))
        if !envelope.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            ids.insert(try noteMaterialID(for: envelope))
        }
        return ids
    }

    /// Stable visible-note identity without expanding the cross-process manifest.
    /// Normally the envelope UUID itself is available. In the pathological case
    /// an entry already uses it, walk deterministic suffix variants; validation
    /// caps entries, so one of the first `maximumEntryCount + 1` variants must be
    /// free.
    private static func noteMaterialID(for envelope: WorkCaptureEnvelope) throws -> UUID {
        let entryIDs = Set(envelope.entries.map(\.id))
        if !entryIDs.contains(envelope.id) { return envelope.id }

        let raw = envelope.id.uuidString.lowercased()
        let prefix = String(raw.dropLast(2))
        let suffix = Int(raw.suffix(2), radix: 16) ?? 0
        for offset in 1...(WorkCaptureEnvelope.maximumEntryCount + 1) {
            let candidateString = prefix + String(format: "%02x", (suffix + offset) & 0xff)
            if let candidate = UUID(uuidString: candidateString), !entryIDs.contains(candidate) {
                return candidate
            }
        }
        // `entries` is bounded below the candidate count, so this is unreachable
        // for every validated envelope. Fail closed rather than ever letting an
        // ID collision make the note mask a different source material.
        throw WorkCaptureInbox.InboxError.invalidEnvelope(envelope.id, .duplicateEntry)
    }

    /// Map one envelope entry to its card. `sequence` is deliberately left at the
    /// draft default: the desk write assigns rank inside its own transaction.
    private static func materialDraft(
        for entry: WorkCaptureEnvelope.Entry,
        in claim: WorkCaptureInbox.Claim,
        sourceDevice: String,
        createdAt: Date
    ) throws -> WorkMaterialDraft {
        switch entry.kind {
        case .text:
            let text = entry.text ?? ""
            return WorkMaterialDraft(
                id: entry.id,
                kind: .note,
                title: entry.displayName
                    ?? String(localized: "workboard.capture.sharedText", defaultValue: "Shared text"),
                textContent: text,
                storageMode: .metadataOnly,
                sourceDevice: sourceDevice,
                createdAt: createdAt
            )

        case .url:
            let value = entry.text ?? ""
            let host = URLComponents(string: value)?.host
            return WorkMaterialDraft(
                id: entry.id,
                kind: .link,
                title: entry.displayName ?? host ?? value,
                urlString: value,
                storageMode: .metadataOnly,
                sourceDevice: sourceDevice,
                createdAt: createdAt
            )

        case .image, .file, .webPage:
            guard let payloadURL = claim.payloadURL(for: entry) else {
                throw WorkCaptureInbox.InboxError.invalidEnvelope(claim.id, .missingPayload)
            }
            let byteSize: Int64
            if let capturedByteCount = entry.byteCount {
                byteSize = capturedByteCount
            } else {
                byteSize = Int64(
                    try payloadURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                )
            }
            let isImage = entry.kind == .image
            let isWebPage = entry.kind == .webPage
            let fallbackTitle: String = {
                if isImage {
                    return String(localized: "workboard.capture.image", defaultValue: "Image")
                }
                if isWebPage {
                    return String(localized: "workboard.capture.webPage", defaultValue: "Web page")
                }
                return String(localized: "workboard.capture.file", defaultValue: "File")
            }()
            let filename = entry.displayName ?? entry.relativePath
            return WorkMaterialDraft(
                id: entry.id,
                kind: isImage ? .image : .file,
                title: entry.displayName ?? fallbackTitle,
                // A text extract is still the user's file content, and only the
                // metadata of a file enters the material row: the bytes are
                // staged by the storage path the desk write chooses.
                textContent: nil,
                filename: filename,
                mimeType: entry.mimeType,
                payload: nil,
                byteSize: byteSize,
                storageMode: .localVault,
                sourceDevice: sourceDevice,
                createdAt: createdAt
            )
        }
    }
}

/// The terminal state one import shares with the heartbeat renewing its claim.
/// A proven takeover has to reach the import — nothing else can stop it writing
/// a further material or acknowledging a claim another process now owns — and
/// the import has to be able to declare itself over, so that the marker its own
/// acknowledgement or release removes is never read back as a takeover.
private actor ImportOwnership {
    private var claimIsLost = false
    private var importHasEnded = false

    var hasLostClaim: Bool { claimIsLost }

    /// Record a takeover the heartbeat proved. Ignored once the import has
    /// ended: from that point the claim is being deleted or requeued by this
    /// drainer itself, and a refusal describes that rather than another
    /// acquisition.
    func recordLostClaim() {
        guard !importHasEnded else { return }
        claimIsLost = true
    }

    /// End the import, reporting whether it still owns its claim. Only an owner
    /// may acknowledge or release.
    func endImport() -> Bool {
        importHasEnded = true
        return !claimIsLost
    }
}

#endif
