// SPDX-License-Identifier: Apache-2.0

// Conduck
// WorkCaptureDrainer.swift
//
// Imports the Workboard's inert App-Group capture queue into private Workboard
// persistence. Work is a single desk, so the drainer resolves no destination: a
// share-sheet capture, a menu-bar capture and a GigaAction voice note all land
// on `Constants.workboardDeskItemID` through `ConversationStore.upsertDeskMaterial`,
// and `targetWorkItemID` — which the share extension cannot resolve from its
// sandbox anyway — is carried by the envelope but never honoured here. Envelope
// and entry UUIDs are reused as database identities, so a crash after any
// individual write is repaired by replay rather than by making a second
// material.
//
// Two rules protect the bytes, because until a claim is acknowledged the queue
// holds the only copy of a shared file. A claim is acknowledged only once every
// material this capture wrote reads back out of the store — the row, and for a
// card that carries bytes a payload this device can actually READ, which is a
// complete blob row on the synced lane and a present leaf on the vault lane.
// And the claim's filesystem lease is renewed for as long as that import takes,
// so a large or slow capture cannot age past the queue's stale horizon and be
// reclaimed by another process mid-write.
//
// This type has no gateway dependency and no dispatch API: opening the app can
// drain captures, but can never turn one into network work.

#if !os(watchOS)

import Foundation

actor WorkCaptureDrainer {
    struct Report: Sendable, Equatable {
        let importedCaptureCount: Int
        let replayedCaptureCount: Int
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
            let persisted = try await withLeaseHeartbeat(for: claim) {
                do {
                    let persisted = try await persist(claim)
                    #if CONDUCK_TESTING
                    await importHoldForTesting?()
                    #endif
                    try await confirmDurablyImported(persisted)
                    try await inbox.acknowledge(claim)
                    return persisted
                } catch {
                    // Best effort is deliberately only for the ownership
                    // rollback. The original persistence error remains the
                    // useful diagnosis; a failed release is repaired by
                    // `reconcile` after relaunch.
                    try? await inbox.release(claim)
                    throw error
                }
            }
            if persisted.wasReplay {
                replayedCaptureCount += 1
            } else {
                importedCaptureCount += 1
            }
            importedMaterialCount += persisted.materialCount
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
    private func persist(_ claim: WorkCaptureInbox.Claim) async throws -> PersistedCapture {
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
            let note = try await store.upsertDeskMaterial(
                WorkMaterialDraft(
                    id: try Self.noteMaterialID(for: envelope),
                    kind: .note,
                    title: String(localized: "workboard.capture.note", defaultValue: "Share note"),
                    textContent: trimmedNote,
                    storageMode: .metadataOnly,
                    sourceDevice: sourceDevice,
                    createdAt: envelope.createdAt
                )
            )
            materialIDs.append(note.id)
        }

        for entry in envelope.entries.sorted(by: Self.entryOrder) {
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
                record = try await store.upsertDeskMaterial(
                    draft,
                    sourceFileURL: payloadURL,
                    sourceFileByteSize: byteSize
                )
                payloadBearingIDs.insert(record.id)
            } else {
                record = try await store.upsertDeskMaterial(draft)
            }
            materialIDs.append(record.id)
        }

        return PersistedCapture(
            wasReplay: wasReplay,
            materialIDs: materialIDs,
            payloadBearingIDs: payloadBearingIDs
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

    /// Run one claim's import under a lease this drainer keeps renewing.
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
    private func withLeaseHeartbeat<T>(
        for claim: WorkCaptureInbox.Claim,
        _ body: () async throws -> T
    ) async throws -> T {
        // Detached deliberately: a renewal is a hop onto the inbox actor and
        // must not have to wait for the executor the import it protects is
        // occupying.
        let heartbeat = Task.detached(
            priority: .utility
        ) { [inbox, leaseHeartbeatInterval, now] in
            while !Task.isCancelled {
                try? await Task.sleep(for: leaseHeartbeatInterval)
                guard !Task.isCancelled else { return }
                // A refusal never stops the beat. The claim may already be
                // gone — acknowledged, released, or taken over — in which case
                // the import's own next inbox call is what surfaces it; or the
                // marker may be momentarily unreadable, and giving up there
                // would disarm the protection this loop exists to provide for
                // the rest of a long import.
                try? await inbox.refreshLease(claim, now: now())
            }
        }
        defer { heartbeat.cancel() }
        return try await body()
    }

    // MARK: - Deterministic capture mapping

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

#endif
