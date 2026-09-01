// SPDX-License-Identifier: Apache-2.0

// Conduck
// ConversationStore+Workboard.swift
//
// Private-CloudKit persistence for the desk: its editable row and its
// materials. Work rows use UUID foreign keys instead of Core Data relationships
// so a card and the conversation a capture came from sync and delete
// independently — CloudKit materializes each record on its own schedule, and a
// relationship would make a half-arrived board fail whole instead of showing
// what has landed. No method here performs network I/O.
//
// A material's bytes live in one of two places, decided by
// `WorkMaterialStoragePolicy`: a `WorkMaterialBlob` row in the payload store
// (`.syncedPayload`, so the bytes reach the person's other devices) or the
// device-local vault (`.localVault`, with reattach). The two stores cannot
// commit as one transaction, so every write here publishes the blob FIRST and
// names it from the material SECOND, and a replay repairs whichever half a
// crash left behind. `WorkMaterial.payload` is never written: bytes on the
// material row would ride its CKRecord and be realized by every board load.

import Foundation
import CoreData
import CryptoKit

#if CONDUCK_TESTING
/// One PHYSICAL `WorkMaterial` row, before deduplication collapses a
/// CloudKit-merged material to a single logical card.
nonisolated struct WorkMaterialRowProbe: Sendable, Hashable {
    let sequence: Int32?
    let cardSize: String?
    let updatedAt: Date?
}

/// One PHYSICAL `WorkMaterialBlob` row. `payloadByteCount` rather than the
/// bytes: a probe exists to prove which rows are there and which one wins, and
/// a ceiling-sized payload has no business crossing the actor boundary to be
/// counted.
nonisolated struct WorkMaterialBlobRowProbe: Sendable, Hashable {
    let byteSize: Int64?
    let contentHash: String?
    let payloadByteCount: Int?
    let createdAt: Date?
    let updatedAt: Date?
}
#endif

extension ConversationStore {

    // MARK: - Work items

    /// Insert one inert draft. A caller-supplied id and `captureEnvelopeID` make
    /// share/import retries idempotent without a Core Data unique constraint
    /// (CloudKit forbids one). Existing rows are returned untouched.
    func createWorkItem(_ draft: WorkItemDraft = WorkItemDraft()) async throws -> WorkItemRecord {
        try await ensureLoaded()
        let context = newWriteContext()
        let selectedID: UUID
        let created: Bool
        (selectedID, created) = try await context.perform { [context] in
            if let captureID = draft.captureEnvelopeID,
               let existing = try Self.workItemRow(captureEnvelopeID: captureID, in: context),
               let existingID = existing.value(forKey: "id") as? UUID {
                return (existingID, false)
            }
            if let existing = try Self.workItemRow(id: draft.id, in: context),
               let existingID = existing.value(forKey: "id") as? UUID {
                return (existingID, false)
            }

            let row = NSEntityDescription.insertNewObject(forEntityName: "WorkItem", into: context)
            row.setValue(draft.id, forKey: "id")
            row.setValue(draft.captureEnvelopeID, forKey: "captureEnvelopeID")
            try Self.apply(draft.content, to: row)
            row.setValue(draft.createdAt, forKey: "createdAt")
            row.setValue(draft.createdAt, forKey: "updatedAt")
            try context.save()
            return (draft.id, true)
        }
        if created { await postDidChange() }
        guard let record = try await fetchWorkItem(id: selectedID) else {
            throw WorkboardStoreError.itemNotFound
        }
        return record
    }

    func fetchWorkItems() async throws -> [WorkItemRecord] {
        try await fetchWorkItems(itemID: nil, captureEnvelopeID: nil)
    }

    func fetchWorkItem(id: UUID) async throws -> WorkItemRecord? {
        try await fetchWorkItems(itemID: id, captureEnvelopeID: nil).first
    }

    func fetchWorkItem(captureEnvelopeID: UUID) async throws -> WorkItemRecord? {
        try await fetchWorkItems(itemID: nil, captureEnvelopeID: captureEnvelopeID).first
    }

    /// Append one chat turn to the desk: its words become a note card and every
    /// attachment that can be copied becomes its own card. A file that lives
    /// only on the user's gateway is recorded as a reference instead, because a
    /// chat snapshot cannot truthfully copy bytes it never held.
    ///
    /// The message id is the note card's identity and every attachment keeps
    /// its own, so a retry after a process interruption repairs the same cards
    /// instead of publishing a second set. No Work item is minted: Chat → Work
    /// is a capture onto the one desk like every other surface, and
    /// `upsertDeskMaterial` decides desk identity, rank and idempotency. The
    /// turn's words are therefore always a card — the desk holds no brief field
    /// for a short turn to land in.
    func captureMessageToWork(
        _ message: MessageRecord,
        conversationID: UUID
    ) async throws -> WorkMessageCaptureReceipt {
        while workMessageCaptureClaims.contains(message.id) {
            try await Task.sleep(for: .milliseconds(40))
        }
        workMessageCaptureClaims.insert(message.id)
        defer { workMessageCaptureClaims.remove(message.id) }

        guard let persistedMessage = try await fetchMessage(
            id: message.id,
            in: conversationID
        ) else {
            throw WorkboardStoreError.itemNotFound
        }
        let conversation = try await fetchConversation(id: conversationID)
        let conversationTitle = await MainActor.run {
            conversation?.displayTitle
                ?? String(localized: "workboard.chatCapture.conversation", defaultValue: "Chat")
        }
        let messageText = persistedMessage.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let isUser = persistedMessage.role == "user"

        // Every card this turn publishes. Recognising a repeat from the desk's
        // own material ids is what replaces the per-turn item the capture used
        // to mint and then look up by capture identity.
        var expectedIDs = Set(persistedMessage.attachments.map(\.id))
        if !messageText.isEmpty { expectedIDs.insert(persistedMessage.id) }
        let desk = try await fetchWorkItem(id: Constants.workboardDeskItemID)
        var existingIDs = Set(desk?.materials.map(\.id) ?? [])
        let wasAlreadyCaptured = !existingIDs.isDisjoint(with: expectedIDs)

        var added = 0
        var referencedOnly = 0
        var failed = 0

        if !messageText.isEmpty, !existingIDs.contains(persistedMessage.id) {
            do {
                _ = try await upsertDeskMaterial(
                    WorkMaterialDraft(
                        id: persistedMessage.id,
                        kind: .note,
                        title: isUser
                            ? String(localized: "workboard.chatCapture.message", defaultValue: "Chat message")
                            : String(localized: "workboard.chatCapture.response", defaultValue: "Chat response"),
                        // The desk collects from every surface, so the card
                        // itself has to say which conversation it came from.
                        caption: String.localizedStringWithFormat(
                            String(localized: "workboard.chatCapture.context", defaultValue: "Captured from %@."),
                            conversationTitle
                        ),
                        textContent: messageText,
                        storageMode: .metadataOnly,
                        sourceDevice: persistedMessage.sourceDevice,
                        createdAt: persistedMessage.createdAt
                    )
                )
                existingIDs.insert(persistedMessage.id)
                added += 1
            } catch {
                failed += 1
            }
        }

        let payloads = try await loadLocalAttachmentPayloads(for: persistedMessage.id)
        // Rank is the desk write's to decide, so the cards are published in the
        // order they are meant to read: the turn's words, then its attachments.
        for attachment in persistedMessage.attachments.sorted(by: { $0.sequence < $1.sequence }) {
            guard !existingIDs.contains(attachment.id) else { continue }
            let name = attachment.filename
                ?? String(localized: "workboard.chatCapture.attachment", defaultValue: "Chat attachment")
            let material: WorkMaterialDraft
            if attachment.isServerReference {
                referencedOnly += 1
                material = WorkMaterialDraft(
                    id: attachment.id,
                    kind: .note,
                    title: name,
                    caption: String(
                        localized: "workboard.chatCapture.remote.caption",
                        defaultValue: "Available in the original chat"
                    ),
                    textContent: String.localizedStringWithFormat(
                        String(
                            localized: "workboard.chatCapture.remote.detail",
                            defaultValue: "%@ stays on your gateway. Open the original chat to retrieve it."
                        ),
                        name
                    ),
                    storageMode: .metadataOnly,
                    sourceDevice: persistedMessage.sourceDevice,
                    createdAt: attachment.createdAt
                )
            } else if let payload = payloads[attachment.id] {
                material = WorkMaterialDraft(
                    id: attachment.id,
                    kind: attachment.mimeType.hasPrefix("image/") ? .image : .file,
                    title: name,
                    filename: name,
                    mimeType: attachment.mimeType,
                    payload: payload,
                    thumbnailData: attachment.thumbnailData,
                    width: attachment.width,
                    height: attachment.height,
                    byteSize: Int64(payload.count),
                    sourceDevice: persistedMessage.sourceDevice,
                    createdAt: attachment.createdAt
                )
            } else {
                referencedOnly += 1
                material = WorkMaterialDraft(
                    id: attachment.id,
                    kind: .note,
                    title: name,
                    caption: String(
                        localized: "workboard.chatCapture.unavailable.caption",
                        defaultValue: "Reattach in Work"
                    ),
                    textContent: String.localizedStringWithFormat(
                        String(
                            localized: "workboard.chatCapture.unavailable.detail",
                            defaultValue: "%@ could not be copied from this device. Reattach it in Work if you need to send it."
                        ),
                        name
                    ),
                    storageMode: .metadataOnly,
                    sourceDevice: persistedMessage.sourceDevice,
                    createdAt: attachment.createdAt
                )
            }
            do {
                _ = try await upsertDeskMaterial(material)
                existingIDs.insert(attachment.id)
                added += 1
            } catch {
                failed += 1
            }
        }

        return WorkMessageCaptureReceipt(
            // Work is one desk, so the receipt names the desk rather than a
            // per-turn item: the banner's Open Work link resolves there.
            itemID: Constants.workboardDeskItemID,
            addedMaterialCount: added,
            referencedOnlyMaterialCount: referencedOnly,
            failedMaterialCount: failed,
            wasAlreadyCaptured: wasAlreadyCaptured
        )
    }

    // MARK: - Desk

    /// Publish one material onto the single Work desk. This is the ONE
    /// authoritative desk write: every capture surface — in-app drop, Chat →
    /// Work, the App Intent, the share-inbox drainer — routes through it, so
    /// desk identity, idempotency and crash repair are decided in exactly one
    /// place instead of once per surface.
    ///
    /// DESK IDENTITY. Work is a single surface, so its owner row carries the
    /// compile-time id `Constants.workboardDeskItemID` rather than a minted
    /// one: a capture from a headless process names the desk without first
    /// reading the store, and a replay after a crash names the same desk it
    /// named before. The row is created lazily by the first capture, holds no
    /// editable brief — title and objective stay nil, nothing displays them —
    /// and is never deleted; removing a material leaves the desk standing.
    ///
    /// WHY THERE IS NO DEDUP. CloudKit forbids a Core Data uniqueness
    /// constraint, so two processes capturing at once can each insert a
    /// physical desk row under that one id. Both writes must succeed:
    /// `deduplicatedWorkItems` projects one logical desk and the `workItemID
    /// IN` material fetch unions every physical row's materials, so a duplicate
    /// desk row is invisible rather than lossy. Deleting the loser would delete
    /// a valid CloudKit record and export that deletion to every other device.
    ///
    /// IDEMPOTENCY. `draft.id` is the material's identity and every capture
    /// lane mints it deterministically, so a replayed envelope or a retried
    /// intent finds its own material and gets it back instead of adding a
    /// second card.
    ///
    /// CRASH REPAIR. Payload bytes, the blob store and the material row cannot
    /// commit as one transaction, so an interrupted capture leaves a partial
    /// state a replay must repair rather than duplicate. Every one of them is
    /// handled here. A material whose owner row never landed: the desk is
    /// re-ensured on every call, so a material stranded without it becomes
    /// visible again. A blob with no material: the insert path publishes the
    /// card the bytes were waiting for. A material whose payload never landed,
    /// in either lane: restaged from the bytes the replaying caller still
    /// carries. A blob carrying different bytes under the same id: replaced in
    /// the save that repoints the card, so the card is never briefly readable
    /// as the wrong payload. Bytes that are already readable are never
    /// rewritten, and a row that claims no payload is never given one: that is
    /// reattach, which `replaceWorkMaterialPayloadFile` owns.
    ///
    /// - Parameter repairPayload: Bytes the caller still holds for a material
    ///   that already exists but cannot produce its payload. Falls back to
    ///   `draft.payload`, so an ordinary replay needs no second copy.
    /// - Parameter expectedOwnerRevision: Compare-and-swap token supplied ONLY
    ///   by the view model's serialized board path, which knows which revision
    ///   the person was looking at. Every headless caller — drainer, App
    ///   Intent, chat capture — passes nil: none of them holds board state to
    ///   guard, and a refusal there would drop a capture the person already
    ///   made. Supplied against a desk that does not exist yet, it is refused:
    ///   a token for an absent row cannot be honestly compared.
    func upsertDeskMaterial(
        _ draft: WorkMaterialDraft,
        sourceFileURL: URL? = nil,
        sourceFileByteSize: Int64? = nil,
        repairPayload: Data? = nil,
        expectedOwnerRevision: Int64? = nil,
        onProgress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> WorkMaterialRecord {
        try await publishWorkMaterial(
            draft,
            owner: .desk,
            sourceFileURL: sourceFileURL,
            sourceFileByteSize: sourceFileByteSize,
            repairPayload: repairPayload,
            expectedOwnerRevision: expectedOwnerRevision,
            onProgress: onProgress
        )
        guard let record = try await fetchWorkMaterial(id: draft.id) else {
            throw WorkboardStoreError.materialNotFound
        }
        return record
    }

    // MARK: - Materials

    /// Publish a brand-new Work item together with its first material in ONE
    /// Core Data save, refusing an id that already owns a row. Binary bytes are
    /// fully staged before the write context inserts either row, so neither row
    /// becomes locally visible or eligible for CloudKit export before both have
    /// committed. The two remain separate CloudKit records and may transiently
    /// import in either order on a peer; this boundary intentionally claims
    /// local transaction atomicity only.
    ///
    /// A picked file URL is consumed here while its security scope is active.
    /// Device-local bytes remain protected by the vault's staged-key guard
    /// until the database save commits; every pre-commit failure removes them.
    func createWorkItemWithInitialMaterial(
        _ itemDraft: WorkItemDraft,
        material draft: WorkMaterialDraft,
        sourceFileURL: URL? = nil,
        sourceFileByteSize: Int64? = nil,
        onProgress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> WorkItemRecord {
        try await publishWorkMaterial(
            draft,
            owner: .createNew(itemDraft),
            sourceFileURL: sourceFileURL,
            sourceFileByteSize: sourceFileByteSize,
            repairPayload: nil,
            expectedOwnerRevision: nil,
            onProgress: onProgress
        )
        guard let record = try await fetchWorkItem(id: itemDraft.id) else {
            throw WorkboardStoreError.itemNotFound
        }
        return record
    }

    /// Which row owns the material this write publishes.
    private nonisolated enum WorkMaterialOwnerPolicy: Sendable {
        /// The one desk: adopt its fixed-id row, or create it. Never refuses an
        /// owner that already exists — the desk is shared by every capture.
        case desk
        /// A brand-new item published together with its first material. Refuses
        /// an id, capture envelope or material that already has a row, because
        /// the caller believes it is minting all three.
        case createNew(WorkItemDraft)
    }

    /// Payload bytes made durable before any row is written. Exactly one lane
    /// carries them: `vaultKey` for `.localVault`, `blobPayload`/`contentHash`
    /// for `.syncedPayload`. Nothing is ever staged into both — the vault
    /// serves the local lane alone, so a synced card has no second copy to
    /// fall out of date.
    private nonisolated struct StagedWorkMaterialBytes: Sendable {
        let storageMode: WorkMaterialStorageMode
        let byteSize: Int64
        let vaultKey: String?
        /// Held in memory only until the blob row is saved. The sync ceiling is
        /// what bounds this, which is why an unmeasured payload never takes
        /// this lane.
        let blobPayload: Data?
        let contentHash: String?

        init(
            storageMode: WorkMaterialStorageMode,
            byteSize: Int64,
            vaultKey: String? = nil,
            blobPayload: Data? = nil,
            contentHash: String? = nil
        ) {
            self.storageMode = storageMode
            self.byteSize = byteSize
            self.vaultKey = vaultKey
            self.blobPayload = blobPayload
            self.contentHash = contentHash
        }
    }

    /// What the first publication step did with the payload bytes.
    private nonisolated enum WorkMaterialBlobPublication: Sendable {
        /// No bytes took the synced lane.
        case none
        /// A complete blob already carried these exact bytes, so nothing was
        /// written and there is nothing to take back.
        case alreadyPresent
        /// This call inserted the row. Only this call may delete it again: it
        /// knows the material never landed, which a background pass never can.
        case inserted(contentHash: String, byteSize: Int64)
    }

    /// What the single write transaction actually did, so the vault's staged-key
    /// guard and the change notification follow the database rather than the
    /// caller's intent.
    private nonisolated struct WorkMaterialWriteOutcome: Sendable {
        let insertedMaterial: Bool
        let repairedMaterial: Bool
        let createdOwner: Bool
        /// Vault key the surviving material row names, which decides whether
        /// bytes staged by this call are referenced or garbage.
        let existingVaultKey: String?
    }

    /// The shared write behind `upsertDeskMaterial` and the provisional
    /// boundary above. Bytes are staged before the transaction opens, so a
    /// preparation failure never leaves a half-published card; the transaction
    /// then resolves the owner, the material and any payload repair in ONE
    /// save.
    ///
    /// The in-process claim covers the whole call, staging included. Vault keys
    /// are derived from the material id, so two replays of one capture would
    /// otherwise stream into the same leaf at once and interleave their bytes.
    /// Captures onto one owner therefore serialize within a process —
    /// deliberate: a corrupted payload costs more than the wait, and a
    /// cross-process duplicate stays harmless under the union rule.
    private func publishWorkMaterial(
        _ draft: WorkMaterialDraft,
        owner policy: WorkMaterialOwnerPolicy,
        sourceFileURL: URL?,
        sourceFileByteSize: Int64?,
        repairPayload: Data?,
        expectedOwnerRevision: Int64?,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let ownerID: UUID
        switch policy {
        case .desk:
            ownerID = Constants.workboardDeskItemID
        case .createNew(let itemDraft):
            ownerID = itemDraft.id
        }

        while workInitialMaterialClaims.contains(ownerID) {
            try await Task.sleep(for: .milliseconds(40))
        }
        workInitialMaterialClaims.insert(ownerID)
        defer { workInitialMaterialClaims.remove(ownerID) }

        try await ensureLoaded()

        let carriedPayload = repairPayload ?? draft.payload
        let carriesBytes = carriedPayload != nil || sourceFileURL != nil
        let existing = try await fetchWorkMaterial(id: draft.id)
        // Repair restores the bytes a row already claims, in the lane it claims
        // them. It never changes the claim: a `.metadataOnly` card gaining
        // bytes is a reattach, not a repair, and a card whose payload outgrew
        // the sync ceiling is a reattach too — the bytes on offer cannot be the
        // payload that row promised.
        let repairLane: WorkMaterialStorageMode?
        if let existing, carriesBytes {
            switch existing.storageMode {
            case .localVault:
                repairLane = existing.availability == .unavailableOnThisDevice
                    ? .localVault : nil
            case .syncedPayload:
                // Whether the blob is actually missing, stale or already
                // correct is settled against its content hash once the bytes
                // are staged; a hash cannot be compared before it is computed.
                let measured = Self.measuredByteSize(
                    payload: carriedPayload,
                    sourceFileURL: sourceFileURL,
                    declared: sourceFileByteSize ?? draft.byteSize
                )
                repairLane = WorkMaterialStoragePolicy.mode(
                    kind: draft.kind,
                    byteSize: measured
                ) == .syncedPayload ? .syncedPayload : nil
            case .metadataOnly:
                repairLane = nil
            }
        } else {
            repairLane = nil
        }

        let staged: StagedWorkMaterialBytes?
        if existing == nil || repairLane != nil {
            staged = try await stageWorkMaterialBytes(
                id: draft.id,
                kind: draft.kind,
                filename: draft.filename,
                payload: carriedPayload,
                declaredByteSize: draft.byteSize,
                declaredStorageMode: draft.storageMode,
                sourceFileURL: sourceFileURL,
                sourceFileByteSize: sourceFileByteSize,
                forcedStorageMode: repairLane,
                onProgress: onProgress
            )
        } else if carriesBytes {
            // The material is already durable with readable bytes, so nothing
            // is restaged and there is no key to publish or reclaim.
            staged = nil
            onProgress(1)
        } else {
            staged = StagedWorkMaterialBytes(
                storageMode: draft.storageMode,
                byteSize: draft.byteSize ?? 0
            )
            onProgress(1)
        }

        // STEP 1 OF THE PUBLICATION. The blob commits in its own save, before
        // any material row claims `.syncedPayload`. The reverse order is the
        // one state a replay cannot repair from bytes it no longer holds: a
        // card promising a payload that was never written anywhere.
        let publishedBlob: WorkMaterialBlobPublication
        if let staged,
           staged.storageMode == .syncedPayload,
           let blobPayload = staged.blobPayload,
           let contentHash = staged.contentHash {
            publishedBlob = try await publishWorkMaterialBlob(
                materialID: draft.id,
                payload: blobPayload,
                byteSize: staged.byteSize,
                contentHash: contentHash
            )
        } else {
            publishedBlob = .none
        }

        // STEP 2 OF THE PUBLICATION.
        let context = newWriteContext()
        let outcome: WorkMaterialWriteOutcome
        do {
            outcome = try await context.perform { [context] () -> WorkMaterialWriteOutcome in
                var createdOwner = false
                let ownerRow: NSManagedObject
                switch policy {
                case .desk:
                    if let row = try Self.workItemRow(id: ownerID, in: context) {
                        ownerRow = row
                    } else {
                        guard expectedOwnerRevision == nil else {
                            throw WorkboardStoreError.staleRevision
                        }
                        ownerRow = Self.insertDeskRow(in: context)
                        createdOwner = true
                    }
                case .createNew(let itemDraft):
                    guard try Self.workItemRow(id: itemDraft.id, in: context) == nil else {
                        throw WorkboardStoreError.staleRevision
                    }
                    if let captureID = itemDraft.captureEnvelopeID,
                       try Self.workItemRow(captureEnvelopeID: captureID, in: context) != nil {
                        throw WorkboardStoreError.identifierCollision
                    }
                    guard try Self.workMaterialRow(id: draft.id, in: context) == nil else {
                        throw WorkboardStoreError.identifierCollision
                    }
                    let row = NSEntityDescription.insertNewObject(
                        forEntityName: "WorkItem",
                        into: context
                    )
                    row.setValue(itemDraft.id, forKey: "id")
                    row.setValue(itemDraft.captureEnvelopeID, forKey: "captureEnvelopeID")
                    try Self.apply(itemDraft.content, to: row)
                    row.setValue(itemDraft.createdAt, forKey: "createdAt")
                    row.setValue(Date(), forKey: "updatedAt")
                    ownerRow = row
                    createdOwner = true
                }

                if let expectedOwnerRevision {
                    guard let updatedAt = ownerRow.value(forKey: "updatedAt") as? Date,
                          Self.workRevision(for: updatedAt) == expectedOwnerRevision else {
                        throw WorkboardStoreError.staleRevision
                    }
                }

                let now = Date()
                let materialRows = try Self.workMaterialRows(id: draft.id, in: context)
                if !materialRows.isEmpty {
                    let owners = Set(
                        materialRows.compactMap { $0.value(forKey: "workItemID") as? UUID }
                    )
                    guard owners == [ownerID] else {
                        throw WorkboardStoreError.invalidMaterialOwner
                    }
                    // CloudKit can materialize one logical material as several
                    // physical rows. Every one of them must name the bytes that
                    // just landed, or a later merge picks a row that still
                    // points at nothing.
                    var repaired = false
                    if let staged, let repairLane {
                        switch repairLane {
                        case .localVault:
                            if staged.storageMode == .localVault,
                               let repairedKey = staged.vaultKey {
                                for row in materialRows {
                                    row.setValue(repairedKey, forKey: "localVaultKey")
                                    row.setValue(
                                        NSNumber(value: staged.byteSize), forKey: "byteSize"
                                    )
                                    row.setValue(now, forKey: "updatedAt")
                                }
                                repaired = true
                            }
                        case .syncedPayload:
                            if staged.storageMode == .syncedPayload,
                               let contentHash = staged.contentHash {
                                // Paired with the blob that just landed: a
                                // complete blob carrying different bytes for
                                // this material is a superseded attempt, and it
                                // goes in the same save that repoints the card.
                                let superseded = try Self.deleteSupersededBlobRows(
                                    materialID: draft.id,
                                    keepingContentHash: contentHash,
                                    byteSize: staged.byteSize,
                                    in: context
                                )
                                if case .inserted = publishedBlob {
                                    repaired = true
                                } else if superseded > 0 {
                                    repaired = true
                                }
                                if repaired {
                                    for row in materialRows {
                                        Self.pointAtSyncedPayload(
                                            row: row, byteSize: staged.byteSize, at: now
                                        )
                                    }
                                }
                            }
                        case .metadataOnly:
                            break
                        }
                    }
                    if createdOwner || repaired { try context.save() }
                    return WorkMaterialWriteOutcome(
                        insertedMaterial: false,
                        repairedMaterial: repaired,
                        createdOwner: createdOwner,
                        existingVaultKey: materialRows.compactMap {
                            $0.value(forKey: "localVaultKey") as? String
                        }.first
                    )
                }

                guard let staged else {
                    // The material this call read back was deleted before the
                    // transaction opened, so its bytes are no longer staged and
                    // publishing it here would write a card that promises a
                    // payload it cannot produce. A fresh capture of the same
                    // source takes the insert path instead.
                    throw WorkboardStoreError.materialNotFound
                }
                if staged.storageMode == .syncedPayload, let contentHash = staged.contentHash {
                    // An earlier interrupted attempt at this same capture can
                    // have left a complete blob carrying different bytes. It is
                    // retired in the save that publishes the card, so the card
                    // is never briefly readable as the wrong payload.
                    try Self.deleteSupersededBlobRows(
                        materialID: draft.id,
                        keepingContentHash: contentHash,
                        byteSize: staged.byteSize,
                        in: context
                    )
                }
                let row = NSEntityDescription.insertNewObject(
                    forEntityName: "WorkMaterial",
                    into: context
                )
                Self.apply(
                    draft,
                    workItemID: ownerID,
                    storageMode: staged.storageMode,
                    byteSize: staged.byteSize,
                    localVaultKey: staged.vaultKey,
                    // Rank is decided here rather than by the caller: a headless
                    // capture cannot know how many cards the desk already holds,
                    // and reading the count outside this transaction would race
                    // the write it is meant to order.
                    sequence: try Self.appendRank(forWorkItemID: ownerID, in: context),
                    updatedAt: now,
                    to: row
                )
                ownerRow.setValue(now, forKey: "updatedAt")
                try context.save()
                return WorkMaterialWriteOutcome(
                    insertedMaterial: true,
                    repairedMaterial: false,
                    createdOwner: createdOwner,
                    existingVaultKey: staged.vaultKey
                )
            }
        } catch {
            if let key = staged?.vaultKey { try? await workAssetVault.remove(key) }
            if case .inserted(let contentHash, let byteSize) = publishedBlob {
                // The ONE place a blob may be deleted without its material.
                // This call wrote those exact bytes moments ago and knows the
                // card never landed, so they name nothing; a background sweep
                // cannot tell that state from a blob CloudKit imported ahead of
                // the material it belongs to, which is why no sweep exists.
                try? await deleteBlobRows(
                    materialID: draft.id,
                    contentHash: contentHash,
                    byteSize: byteSize
                )
            }
            throw error
        }

        if let key = staged?.vaultKey {
            if outcome.insertedMaterial
                || outcome.repairedMaterial
                || key == outcome.existingVaultKey {
                await workAssetVault.markReferenced(key)
            } else {
                try? await workAssetVault.remove(key)
            }
        }
        if outcome.insertedMaterial || outcome.repairedMaterial || outcome.createdOwner {
            await postDidChange()
        }
    }

    /// Make payload bytes durable before any row names them, in the lane
    /// `WorkMaterialStoragePolicy` picks for their measured size. This is the
    /// ONE place a capture decides where bytes live, so the sync ceiling is
    /// enforced by construction on the lanes that have no UI to warn from — the
    /// share inbox and the headless intent.
    ///
    /// The vault leaf is derived from `vaultKeyID`, the MATERIAL id by default,
    /// so a replayed capture restages onto the same file instead of leaving an
    /// orphan behind for reconciliation. Reattach passes a fresh id instead,
    /// because the bytes a card still names must stay authoritative until its
    /// compare-and-swap commits.
    ///
    /// - Parameter forcedStorageMode: The lane a REPAIR stages into — the one
    ///   the existing row already claims. A repair restores what a card
    ///   promises; re-deciding the lane under it would move a payload the
    ///   person never touched. Nil lets the policy decide, which is what every
    ///   fresh capture does.
    private func stageWorkMaterialBytes(
        id: UUID,
        kind: WorkMaterialKind,
        filename: String?,
        payload: Data?,
        declaredByteSize: Int64?,
        declaredStorageMode: WorkMaterialStorageMode,
        sourceFileURL: URL?,
        sourceFileByteSize: Int64?,
        vaultKeyID: UUID? = nil,
        forcedStorageMode: WorkMaterialStorageMode? = nil,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> StagedWorkMaterialBytes {
        let suggestedExtension = filename.map { ($0 as NSString).pathExtension }
        let vaultID = vaultKeyID ?? id
        let expectedByteCount = sourceFileByteSize ?? declaredByteSize ?? -1

        if let sourceFileURL {
            let measured = Self.measuredByteSize(
                payload: nil,
                sourceFileURL: sourceFileURL,
                declared: sourceFileByteSize ?? declaredByteSize
            )
            let mode = forcedStorageMode
                ?? WorkMaterialStoragePolicy.mode(kind: kind, byteSize: measured)
            if mode == .syncedPayload {
                // Bounded by the sync ceiling, so the file is read whole: the
                // blob attribute takes a `Data`, and a payload at the ceiling
                // costs about its own size in peak memory.
                let bytes = try Data(contentsOf: sourceFileURL)
                let byteSize = Int64(bytes.count)
                guard WorkMaterialStoragePolicy.mode(kind: kind, byteSize: byteSize)
                        == .syncedPayload,
                      expectedByteCount < 0 || expectedByteCount == byteSize else {
                    // The file is not the payload the caller described. The
                    // streaming lane refuses the same disagreement rather than
                    // storing a copy under a size nothing can trust.
                    throw WorkboardStoreError.materialPayloadUnavailable
                }
                onProgress(1)
                return StagedWorkMaterialBytes(
                    storageMode: .syncedPayload,
                    byteSize: byteSize,
                    blobPayload: bytes,
                    contentHash: Self.contentHash(of: bytes)
                )
            }
            let storedFile = try await workAssetVault.storeFileStreaming(
                at: sourceFileURL,
                id: vaultID,
                suggestedExtension: suggestedExtension,
                expectedByteCount: expectedByteCount,
                onProgress: onProgress
            )
            return StagedWorkMaterialBytes(
                storageMode: .localVault,
                byteSize: storedFile.byteCount,
                vaultKey: storedFile.key
            )
        }

        guard let payload else {
            // No bytes at all: what the draft declares stands, including a
            // `.syncedPayload` claim with nothing behind it — that card reads
            // as pending until its blob arrives.
            onProgress(1)
            return StagedWorkMaterialBytes(
                storageMode: declaredStorageMode,
                byteSize: declaredByteSize ?? 0
            )
        }

        let measured = Int64(payload.count)
        let mode = forcedStorageMode
            ?? WorkMaterialStoragePolicy.mode(kind: kind, byteSize: measured)
        if mode == .syncedPayload {
            onProgress(1)
            return StagedWorkMaterialBytes(
                storageMode: .syncedPayload,
                // A blob's size is the proof its bytes are whole, so it is
                // measured here rather than taken from the caller's claim.
                byteSize: measured,
                blobPayload: payload,
                contentHash: Self.contentHash(of: payload)
            )
        }
        let vaultKey = try await workAssetVault.store(
            payload,
            id: vaultID,
            suggestedExtension: suggestedExtension
        )
        onProgress(1)
        return StagedWorkMaterialBytes(
            storageMode: .localVault,
            byteSize: declaredByteSize ?? measured,
            vaultKey: vaultKey
        )
    }

    // MARK: - Payload blobs

    /// The most authoritative size available for the bytes a call carries. The
    /// file on disk outranks the caller's claim: the lane has to be decided
    /// before anything is read, and a wrong claim would either strand a
    /// syncable payload in the vault or pull an oversized file into memory.
    private static func measuredByteSize(
        payload: Data?,
        sourceFileURL: URL?,
        declared: Int64?
    ) -> Int64 {
        if let sourceFileURL {
            if let size = try? sourceFileURL
                .resourceValues(forKeys: [.fileSizeKey]).fileSize {
                return Int64(size)
            }
            return declared ?? -1
        }
        if let payload { return Int64(payload.count) }
        return declared ?? 0
    }

    /// SHA-256 of the exact bytes a blob stores, lowercase hex. It is what
    /// tells a replay carrying the same payload apart from one carrying
    /// different bytes under the same material id — a size comparison cannot.
    private static func contentHash(of payload: Data) -> String {
        SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
    }

    /// STEP 1 of the publication protocol: make the payload durable in the blob
    /// store, in a save of its own, before any material row claims it.
    ///
    /// Superseded blobs are NOT retired here. They go in the material's save,
    /// so a card is never briefly readable as the wrong payload and a refused
    /// publication leaves the blob store exactly as it found it.
    ///
    /// The presence check reads METADATA only — realizing blob rows to compare
    /// them would fault a ceiling-sized payload in to answer a question about
    /// its hash.
    private func publishWorkMaterialBlob(
        materialID: UUID,
        payload: Data,
        byteSize: Int64,
        contentHash: String
    ) async throws -> WorkMaterialBlobPublication {
        let known = try await workMaterialBlobCompleteness(materialIDs: [materialID])[materialID]
        if let known, known.contentHash == contentHash, known.byteSize == byteSize {
            return .alreadyPresent
        }
        let context = newWriteContext()
        try await context.perform { [context] in
            let now = Date()
            let row = NSEntityDescription.insertNewObject(
                forEntityName: "WorkMaterialBlob",
                into: context
            )
            row.setValue(materialID, forKey: "materialID")
            row.setValue(payload, forKey: "payload")
            row.setValue(NSNumber(value: byteSize), forKey: "byteSize")
            row.setValue(contentHash, forKey: "contentHash")
            row.setValue(now, forKey: "createdAt")
            row.setValue(now, forKey: "updatedAt")
            // No `context.assign(_:to:)`: the entity belongs to exactly one
            // configuration, so Core Data routes the insert into the payload
            // store on its own.
            try context.save()
        }
        return .inserted(contentHash: contentHash, byteSize: byteSize)
    }

    /// Which of these materials have a whole payload behind them, from ONE
    /// fetch that projects metadata and NEVER `payload`. Projecting the bytes
    /// would realize every blob on the board to answer a question about its
    /// size, which is the object-level faulting hazard the payload store exists
    /// to avoid.
    ///
    /// A material is answered for only by the NEWEST COMPLETE row: CloudKit can
    /// import one logical blob as several physical rows, and a row whose hash
    /// or size is still absent is an arrival in progress, not a payload.
    /// Completeness is `WorkMaterialBlobRecord.isComplete` and is never
    /// restated anywhere else.
    func workMaterialBlobCompleteness(
        materialIDs: Set<UUID>
    ) async throws -> [UUID: WorkMaterialBlobRecord] {
        guard !materialIDs.isEmpty else { return [:] }
        try await ensureLoaded()
        let context = newReadContext()
        return try await context.perform { [context] in
            let request = NSFetchRequest<NSDictionary>(entityName: "WorkMaterialBlob")
            request.resultType = .dictionaryResultType
            request.propertiesToFetch = [
                "materialID", "byteSize", "contentHash", "createdAt", "updatedAt",
            ]
            request.predicate = NSPredicate(format: "materialID IN %@", Array(materialIDs))
            var newest: [UUID: WorkMaterialBlobRecord] = [:]
            for row in try context.fetch(request) {
                guard let record = Self.blobRecord(
                    materialID: row["materialID"] as? UUID,
                    byteSize: (row["byteSize"] as? NSNumber)?.int64Value,
                    contentHash: row["contentHash"] as? String,
                    createdAt: row["createdAt"] as? Date,
                    updatedAt: row["updatedAt"] as? Date
                ), record.isComplete else { continue }
                guard let current = newest[record.materialID] else {
                    newest[record.materialID] = record
                    continue
                }
                if (record.updatedAt, record.createdAt) > (current.updatedAt, current.createdAt) {
                    newest[record.materialID] = record
                }
            }
            return newest
        }
    }

    /// The bytes of the newest COMPLETE blob for one material, or nil while the
    /// card is still waiting for them.
    ///
    /// This realizes the rows it walks, unlike the completeness projection: the
    /// caller is opening one card and wants its payload, so the fault it fires
    /// is the read it asked for. Duplicates are a transient CloudKit state, so
    /// the walk is one or two rows deep in practice.
    private func newestCompleteBlobPayload(materialID: UUID) async throws -> Data? {
        try await ensureLoaded()
        let context = newReadContext()
        return try await context.perform { [context] () -> Data? in
            for row in try Self.blobRows(materialID: materialID, in: context) {
                guard Self.blobRecord(of: row)?.isComplete == true else { continue }
                return row.value(forKey: "payload") as? Data
            }
            return nil
        }
    }

    /// Take back blob rows carrying exactly the bytes this process just wrote,
    /// for a material that never landed. Scoped to that hash and size so a
    /// concurrently imported blob for the same material is left alone.
    private func deleteBlobRows(
        materialID: UUID,
        contentHash: String,
        byteSize: Int64
    ) async throws {
        let context = newWriteContext()
        try await context.perform { [context] in
            let request = NSFetchRequest<NSManagedObject>(entityName: "WorkMaterialBlob")
            request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
                NSPredicate(format: "materialID == %@", materialID as CVarArg),
                NSPredicate(format: "contentHash == %@", contentHash),
                NSPredicate(format: "byteSize == %@", NSNumber(value: byteSize)),
            ])
            // The payload is not read to delete the row that holds it.
            request.includesPropertyValues = false
            let rows = try context.fetch(request)
            guard !rows.isEmpty else { return }
            rows.forEach(context.delete)
            try context.save()
        }
    }

    /// Every physical blob row of one material, newest first — the same
    /// newest-wins ordering the material rows use, so a payload read and the
    /// completeness projection cannot disagree about which blob is canonical.
    private static func blobRows(
        materialID: UUID,
        in context: NSManagedObjectContext
    ) throws -> [NSManagedObject] {
        let request = NSFetchRequest<NSManagedObject>(entityName: "WorkMaterialBlob")
        request.predicate = NSPredicate(format: "materialID == %@", materialID as CVarArg)
        request.sortDescriptors = [
            NSSortDescriptor(key: "updatedAt", ascending: false),
            NSSortDescriptor(key: "createdAt", ascending: false),
        ]
        return try context.fetch(request)
    }

    /// Retire complete blob rows of this material that carry OTHER bytes.
    ///
    /// Incomplete rows are deliberately left standing: a row whose hash or size
    /// has not arrived is indistinguishable from an import still in flight, and
    /// deleting it would export the removal of a payload that is merely early.
    @discardableResult
    private static func deleteSupersededBlobRows(
        materialID: UUID,
        keepingContentHash contentHash: String,
        byteSize: Int64,
        in context: NSManagedObjectContext
    ) throws -> Int {
        var deleted = 0
        for row in try blobRows(materialID: materialID, in: context) {
            guard let record = blobRecord(of: row), record.isComplete else { continue }
            guard record.contentHash != contentHash || record.byteSize != byteSize else {
                continue
            }
            context.delete(row)
            deleted += 1
        }
        return deleted
    }

    /// Delete every blob of one material, in the caller's transaction.
    ///
    /// PAIRED DELETION IS THE ONLY WAY A BLOB IS EVER RECLAIMED. There is
    /// deliberately no orphan sweep: CloudKit can import a blob before the
    /// material that names it, so a pass removing "blobs with no material"
    /// would export the deletion of a payload that is merely early. Bytes
    /// stranded by a crash between the two publication steps are accepted
    /// residue — bounded by the sync ceiling and rare.
    @discardableResult
    private static func deleteBlobRows(
        materialID: UUID,
        in context: NSManagedObjectContext
    ) throws -> Int {
        let request = NSFetchRequest<NSManagedObject>(entityName: "WorkMaterialBlob")
        request.predicate = NSPredicate(format: "materialID == %@", materialID as CVarArg)
        // The payload is not read to delete the row that holds it.
        request.includesPropertyValues = false
        let rows = try context.fetch(request)
        rows.forEach(context.delete)
        return rows.count
    }

    /// Point one material row at the payload store. `payload` and
    /// `localVaultKey` are cleared together: a synced card has its bytes in
    /// exactly one place, and a stale vault key would let a reader answer from
    /// a file the card no longer describes.
    private static func pointAtSyncedPayload(
        row: NSManagedObject,
        byteSize: Int64,
        at date: Date
    ) {
        row.setValue(nil, forKey: "payload")
        row.setValue(WorkMaterialStorageMode.syncedPayload.rawValue, forKey: "storageMode")
        row.setValue(nil, forKey: "localVaultKey")
        row.setValue(NSNumber(value: byteSize), forKey: "byteSize")
        row.setValue(date, forKey: "updatedAt")
    }

    /// One blob row's metadata, never its bytes. Both readers — the projection
    /// and the payload walk — build the record here, so "complete" means one
    /// thing wherever it is asked.
    private static func blobRecord(of row: NSManagedObject) -> WorkMaterialBlobRecord? {
        blobRecord(
            materialID: row.value(forKey: "materialID") as? UUID,
            byteSize: (row.value(forKey: "byteSize") as? NSNumber)?.int64Value,
            contentHash: row.value(forKey: "contentHash") as? String,
            createdAt: row.value(forKey: "createdAt") as? Date,
            updatedAt: row.value(forKey: "updatedAt") as? Date
        )
    }

    private static func blobRecord(
        materialID: UUID?,
        byteSize: Int64?,
        contentHash: String?,
        createdAt: Date?,
        updatedAt: Date?
    ) -> WorkMaterialBlobRecord? {
        guard let materialID else { return nil }
        let created = createdAt ?? .distantPast
        return WorkMaterialBlobRecord(
            materialID: materialID,
            byteSize: byteSize ?? 0,
            contentHash: contentHash ?? "",
            createdAt: created,
            updatedAt: updatedAt ?? created
        )
    }

    /// The desk's owner row. It deliberately does not go through
    /// `apply(_ content:)`: the desk has no editable brief, so title, objective,
    /// context, desiredOutcome and constraints stay nil rather than becoming
    /// empty strings — nothing displays them, and an unwritten column keeps the
    /// CloudKit record to what the desk actually is.
    private static func insertDeskRow(in context: NSManagedObjectContext) -> NSManagedObject {
        let row = NSEntityDescription.insertNewObject(forEntityName: "WorkItem", into: context)
        let now = Date()
        row.setValue(Constants.workboardDeskItemID, forKey: "id")
        row.setValue(now, forKey: "createdAt")
        row.setValue(now, forKey: "updatedAt")
        return row
    }

    /// Rank one past the highest an owner already holds, so a new card lands at
    /// the end of the board it was dropped on.
    private static func appendRank(
        forWorkItemID id: UUID,
        in context: NSManagedObjectContext
    ) throws -> Int {
        let request = NSFetchRequest<NSManagedObject>(entityName: "WorkMaterial")
        request.predicate = NSPredicate(format: "workItemID == %@", id as CVarArg)
        request.sortDescriptors = [NSSortDescriptor(key: "sequence", ascending: false)]
        request.fetchLimit = 1
        let highest = try context.fetch(request).first
            .flatMap { ($0.value(forKey: "sequence") as? NSNumber)?.intValue }
        return (highest ?? -1) + 1
    }

    /// Add a material to an arbitrary owner and update it in one Core Data
    /// save. Payload bytes always go to the explicit device-local vault.
    ///
    /// NO CAPTURE SURFACE REACHES THIS — every one of them publishes onto the
    /// desk through `upsertDeskMaterial`, which is where
    /// `WorkMaterialStoragePolicy` decides the lane. What survives here is the
    /// only way to mint a material under a NON-desk owner, which several store
    /// tests need, and it deliberately stays on the local lane: a fixture that
    /// wants a device-local payload must be able to ask for one.
    func addWorkMaterial(
        _ draft: WorkMaterialDraft,
        to workItemID: UUID,
        expectedOwnerRevision: Int64? = nil
    ) async throws -> WorkMaterialRecord {
        try await ensureLoaded()

        if let existing = try await fetchWorkMaterial(id: draft.id) {
            guard existing.workItemID == workItemID else {
                throw WorkboardStoreError.invalidMaterialOwner
            }
            return existing
        }

        let byteSize = draft.byteSize ?? Int64(draft.payload?.count ?? 0)
        let storageMode: WorkMaterialStorageMode = draft.payload == nil
            ? draft.storageMode : .localVault

        var newVaultKey: String?
        if storageMode == .localVault, let payload = draft.payload {
            newVaultKey = try await workAssetVault.store(
                payload,
                id: draft.id,
                suggestedExtension: draft.filename.map { ($0 as NSString).pathExtension }
            )
        }

        return try await insertWorkMaterial(
            draft,
            to: workItemID,
            storageMode: storageMode,
            byteSize: byteSize,
            newVaultKey: newVaultKey,
            expectedOwnerRevision: expectedOwnerRevision
        )
    }

    /// Import a URL under an arbitrary owner without materializing arbitrary
    /// bytes on the main actor. File bytes stream into the explicit
    /// device-local vault with cancellable progress; only metadata mirrors
    /// through private CloudKit. Same standing as `addWorkMaterial`: no capture
    /// surface reaches it, and it stays on the local lane on purpose.
    func addWorkMaterialFile(
        _ draft: WorkMaterialDraft,
        from sourceURL: URL,
        byteSize: Int64,
        to workItemID: UUID,
        expectedOwnerRevision: Int64? = nil,
        onProgress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> WorkMaterialRecord {
        try await ensureLoaded()
        if let existing = try await fetchWorkMaterial(id: draft.id) {
            guard existing.workItemID == workItemID else {
                throw WorkboardStoreError.invalidMaterialOwner
            }
            return existing
        }
        let storedFile = try await workAssetVault.storeFileStreaming(
            at: sourceURL,
            id: draft.id,
            suggestedExtension: draft.filename.map { ($0 as NSString).pathExtension },
            expectedByteCount: byteSize,
            onProgress: onProgress
        )
        return try await insertWorkMaterial(
            draft,
            to: workItemID,
            storageMode: .localVault,
            byteSize: storedFile.byteCount,
            newVaultKey: storedFile.key,
            expectedOwnerRevision: expectedOwnerRevision
        )
    }

    private func insertWorkMaterial(
        _ draft: WorkMaterialDraft,
        to workItemID: UUID,
        storageMode: WorkMaterialStorageMode,
        byteSize: Int64,
        newVaultKey: String?,
        expectedOwnerRevision: Int64?
    ) async throws -> WorkMaterialRecord {

        let context = newWriteContext()
        let inserted: Bool
        do {
            inserted = try await context.perform { [context] in
                guard let owner = try Self.workItemRow(id: workItemID, in: context) else {
                    throw WorkboardStoreError.itemNotFound
                }
                if let expectedOwnerRevision {
                    guard let updatedAt = owner.value(forKey: "updatedAt") as? Date,
                          Self.workRevision(for: updatedAt) == expectedOwnerRevision else {
                        throw WorkboardStoreError.staleRevision
                    }
                }
                if let existing = try Self.workMaterialRow(id: draft.id, in: context) {
                    guard existing.value(forKey: "workItemID") as? UUID == workItemID else {
                        throw WorkboardStoreError.invalidMaterialOwner
                    }
                    return false
                }
                let now = Date()
                let row = NSEntityDescription.insertNewObject(forEntityName: "WorkMaterial", into: context)
                Self.apply(
                    draft,
                    workItemID: workItemID,
                    storageMode: storageMode,
                    byteSize: byteSize,
                    localVaultKey: newVaultKey,
                    updatedAt: now,
                    to: row
                )
                owner.setValue(now, forKey: "updatedAt")
                try context.save()
                return true
            }
        } catch {
            if let newVaultKey { try? await workAssetVault.remove(newVaultKey) }
            throw error
        }
        if !inserted, let newVaultKey {
            try? await workAssetVault.remove(newVaultKey)
        } else if let newVaultKey {
            await workAssetVault.markReferenced(newVaultKey)
        }
        if inserted { await postDidChange() }
        guard let record = try await fetchWorkMaterial(id: draft.id) else {
            throw WorkboardStoreError.materialNotFound
        }
        return record
    }

    /// Reattach a file in place without changing material identity, order,
    /// caption or title.
    ///
    /// The arriving bytes re-decide the lane through
    /// `WorkMaterialStoragePolicy`, so a card whose payload was device-local
    /// moves onto the synced lane when a small file replaces it, and off it
    /// when a large one does. Whichever lane it leaves is cleared in the same
    /// save that points it at the new one — the old blob rows, or the old vault
    /// key — so a card never names bytes in two places.
    ///
    /// Nothing the card still names is disturbed before the owner-revision CAS
    /// commits: the vault lane stages under a FRESH key, and the blob lane
    /// retires superseded rows inside the transaction and takes its own insert
    /// back if the CAS refuses.
    func replaceWorkMaterialPayloadFile(
        id: UUID,
        from sourceURL: URL,
        byteSize: Int64,
        filename: String?,
        mimeType: String?,
        sourceDevice: String?,
        expectedOwnerRevision: Int64,
        onProgress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> WorkMaterialRecord? {
        try await ensureLoaded()
        // Kind comes from the row: a reattach replaces bytes, never what the
        // card is.
        guard let existing = try await fetchWorkMaterial(id: id) else {
            throw WorkboardStoreError.materialNotFound
        }
        let staged = try await stageWorkMaterialBytes(
            id: id,
            kind: existing.kind,
            filename: filename,
            payload: nil,
            declaredByteSize: byteSize,
            declaredStorageMode: .localVault,
            sourceFileURL: sourceURL,
            sourceFileByteSize: byteSize,
            vaultKeyID: UUID(),
            onProgress: onProgress
        )
        let newKey = staged.vaultKey

        let publishedBlob: WorkMaterialBlobPublication
        if staged.storageMode == .syncedPayload,
           let blobPayload = staged.blobPayload,
           let contentHash = staged.contentHash {
            publishedBlob = try await publishWorkMaterialBlob(
                materialID: id,
                payload: blobPayload,
                byteSize: staged.byteSize,
                contentHash: contentHash
            )
        } else {
            publishedBlob = .none
        }

        let context = newWriteContext()
        let oldKey: String?
        do {
            oldKey = try await context.perform { [context] in
                guard let row = try Self.workMaterialRow(id: id, in: context),
                      let ownerID = row.value(forKey: "workItemID") as? UUID,
                      let owner = try Self.workItemRow(id: ownerID, in: context),
                      let ownerUpdatedAt = owner.value(forKey: "updatedAt") as? Date else {
                    throw WorkboardStoreError.materialNotFound
                }
                guard Self.workRevision(for: ownerUpdatedAt) == expectedOwnerRevision else {
                    throw WorkboardStoreError.staleRevision
                }
                let oldKey = row.value(forKey: "localVaultKey") as? String
                let now = Date()
                switch staged.storageMode {
                case .syncedPayload:
                    if let contentHash = staged.contentHash {
                        try Self.deleteSupersededBlobRows(
                            materialID: id,
                            keepingContentHash: contentHash,
                            byteSize: staged.byteSize,
                            in: context
                        )
                    }
                    Self.pointAtSyncedPayload(row: row, byteSize: staged.byteSize, at: now)
                case .localVault, .metadataOnly:
                    // The card's payload leaves the synced lane, so its blobs
                    // leave with it in this same save.
                    try Self.deleteBlobRows(materialID: id, in: context)
                    row.setValue(nil, forKey: "payload")
                    row.setValue(
                        WorkMaterialStorageMode.localVault.rawValue, forKey: "storageMode"
                    )
                    row.setValue(newKey, forKey: "localVaultKey")
                    row.setValue(NSNumber(value: staged.byteSize), forKey: "byteSize")
                    row.setValue(now, forKey: "updatedAt")
                }
                row.setValue(sourceDevice, forKey: "sourceDevice")
                if let filename { row.setValue(filename, forKey: "filename") }
                if let mimeType { row.setValue(mimeType, forKey: "mimeType") }
                // An extract and a preview describe the bytes that were here
                // before, and this call is handed neither for the bytes
                // replacing them.
                row.setValue(nil, forKey: "textContent")
                row.setValue(nil, forKey: "thumbnailData")
                owner.setValue(now, forKey: "updatedAt")
                try context.save()
                return oldKey
            }
        } catch {
            if let newKey { try? await workAssetVault.remove(newKey) }
            if case .inserted(let contentHash, let blobByteSize) = publishedBlob {
                // The card kept the payload it had, so the bytes this call
                // wrote name nothing. Same rule as a refused capture: only the
                // call that wrote them knows that.
                try? await deleteBlobRows(
                    materialID: id,
                    contentHash: contentHash,
                    byteSize: blobByteSize
                )
            }
            throw error
        }
        if let newKey { await workAssetVault.markReferenced(newKey) }
        if let oldKey, oldKey != newKey { try? await workAssetVault.remove(oldKey) }
        await postDidChange()
        return try await fetchWorkMaterial(id: id)
    }

    func deleteWorkMaterial(
        id: UUID,
        workItemID: UUID? = nil,
        expectedOwnerRevision: Int64? = nil
    ) async throws {
        try await ensureLoaded()
        let context = newWriteContext()
        let outcome = try await context.perform { [context] () -> (Bool, String?, UUID?) in
            let request = NSFetchRequest<NSManagedObject>(entityName: "WorkMaterial")
            if let workItemID {
                request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
                    NSPredicate(format: "id == %@", id as CVarArg),
                    NSPredicate(format: "workItemID == %@", workItemID as CVarArg),
                ])
            } else {
                request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
            }
            let rows = try context.fetch(request)
            guard !rows.isEmpty else { return (false, nil, nil) }
            let key = rows.compactMap { $0.value(forKey: "localVaultKey") as? String }.first
            let owners = Set(rows.compactMap { $0.value(forKey: "workItemID") as? UUID })
            guard owners.count == 1, let owner = owners.first else {
                throw WorkboardStoreError.invalidMaterialOwner
            }
            if let expectedOwnerRevision {
                guard let item = try Self.workItemRow(id: owner, in: context),
                      let updatedAt = item.value(forKey: "updatedAt") as? Date,
                      Self.workRevision(for: updatedAt) == expectedOwnerRevision else {
                    throw WorkboardStoreError.staleRevision
                }
            }
            rows.forEach(context.delete)
            // PAIRED DELETE. The card and its payload leave in ONE save, across
            // both stores, so no device is left holding bytes for a card that
            // no longer exists. This is the ONLY reclamation path blobs have —
            // see `deleteBlobRows(materialID:in:)` for why there is no sweep.
            // Reached only when a material row was actually deleted: a blob
            // whose material has not arrived yet is early, not orphaned.
            try Self.deleteBlobRows(materialID: id, in: context)
            if let item = try Self.workItemRow(id: owner, in: context) {
                item.setValue(Date(), forKey: "updatedAt")
            }
            try context.save()
            return (true, key, owner)
        }
        if let key = outcome.1 { try? await workAssetVault.remove(key) }
        if outcome.0 { await postDidChange() }
    }

    /// Rank the board's cards through the SAME rewrite the editor's autosave
    /// uses, so the two surfaces cannot disagree about what order means. Order
    /// is canonical: it decides the dispatch prompt, so this deliberately
    /// advances the item's revision and an already-sent run is honestly marked
    /// as changed. `expectedOwnerRevision` is optional in the same sense it is
    /// for the other material mutations here — supplied, it refuses a rewrite
    /// built on an order the person never saw.
    @discardableResult
    func reorderWorkMaterials(
        itemID: UUID,
        orderedMaterialIDs: [UUID],
        expectedOwnerRevision: Int64? = nil
    ) async throws -> WorkItemRecord {
        try await ensureLoaded()
        let context = newWriteContext()
        let changed = try await context.perform { [context] in
            guard let owner = try Self.workItemRow(id: itemID, in: context) else {
                throw WorkboardStoreError.itemNotFound
            }
            if let expectedOwnerRevision {
                guard let updatedAt = owner.value(forKey: "updatedAt") as? Date,
                      Self.workRevision(for: updatedAt) == expectedOwnerRevision else {
                    throw WorkboardStoreError.staleRevision
                }
            }
            let rewrite = try Self.rewriteWorkMaterialSequence(
                orderedMaterialIDs: orderedMaterialIDs,
                workItemID: itemID,
                in: context
            )
            guard rewrite.didChange else { return false }
            let now = Date()
            owner.setValue(now, forKey: "updatedAt")
            for material in rewrite.materials where material.hasChanges {
                material.setValue(now, forKey: "updatedAt")
            }
            try context.save()
            return true
        }
        if changed { await postDidChange() }
        guard let record = try await fetchWorkItem(id: itemID) else {
            throw WorkboardStoreError.itemNotFound
        }
        return record
    }

    /// Resize one card. Card size is a fact about the board, never about the
    /// brief: it is absent from every prompt and dispatch snapshot, so this
    /// writes NO timestamp on either the material or its item. That is the whole
    /// contract — both revisions are derived from `updatedAt`, so touching one
    /// would raise "Changed after this was sent" on an untouched brief and
    /// invalidate an approved preflight because somebody made a card bigger.
    /// Every physical row of the material is written, because CloudKit can
    /// merge one logical card into several and whichever row wins the canonical
    /// read must report the size the person chose.
    func setWorkMaterialCardSize(
        _ size: WorkMaterialCardSize,
        materialID: UUID,
        itemID: UUID
    ) async throws {
        try await ensureLoaded()
        let context = newWriteContext()
        let changed = try await context.perform { [context] in
            let request = NSFetchRequest<NSManagedObject>(entityName: "WorkMaterial")
            request.predicate = NSPredicate(format: "id == %@", materialID as CVarArg)
            let rows = try context.fetch(request)
            guard !rows.isEmpty else { throw WorkboardStoreError.materialNotFound }
            let owners = Set(rows.compactMap { $0.value(forKey: "workItemID") as? UUID })
            guard owners == [itemID] else {
                throw WorkboardStoreError.invalidMaterialOwner
            }
            let stored = size.storedValue
            var didChange = false
            for row in rows where row.value(forKey: "cardSize") as? String != stored {
                row.setValue(stored, forKey: "cardSize")
                didChange = true
            }
            guard didChange else { return false }
            try context.save()
            return true
        }
        if changed { await postDidChange() }
    }

    /// Pin or unpin one project. Pin is a fact about the board, never about the
    /// brief: it is absent from every prompt and dispatch snapshot, so this
    /// writes NO `updatedAt`. That is the whole contract — the brief revision is
    /// derived from `updatedAt`, so stamping it would raise "Changed after this
    /// was sent" on an untouched brief and invalidate an approved preflight
    func loadWorkMaterial(id: UUID) async throws -> LoadedWorkMaterial? {
        guard let record = try await fetchWorkMaterial(id: id) else { return nil }
        return LoadedWorkMaterial(record: record, payload: try await loadWorkMaterialPayload(id: id))
    }

    /// The bytes behind one card, from whichever lane it names. A
    /// `.syncedPayload` card answers from the newest COMPLETE blob and nil
    /// while it is still waiting for one; `WorkMaterial.payload` is not read,
    /// because it is not written.
    func loadWorkMaterialPayload(id: UUID) async throws -> Data? {
        try await ensureLoaded()
        let context = newReadContext()
        let payloadSource = try await context.perform { [context] () -> (WorkMaterialStorageMode, String?)? in
            guard let row = try Self.workMaterialRow(id: id, in: context) else { return nil }
            let mode = WorkMaterialStorageMode(stored: row.value(forKey: "storageMode") as? String)
            return (mode, row.value(forKey: "localVaultKey") as? String)
        }
        guard let payloadSource else { return nil }
        switch payloadSource.0 {
        case .metadataOnly:
            return nil
        case .syncedPayload:
            return try await newestCompleteBlobPayload(materialID: id)
        case .localVault:
            guard let key = payloadSource.1 else { return nil }
            return try? await workAssetVault.data(for: key)
        }
    }

    /// App-internal URL for snapshotting a device-local vault payload. Never
    /// expose it to an external opener/editor. Synced Core Data assets return
    /// nil; callers may materialize those bounded bytes into a temporary file.
    func localURLForWorkMaterial(id: UUID) async throws -> URL? {
        guard let record = try await fetchWorkMaterial(id: id),
              record.storageMode == .localVault,
              let key = record.localVaultKey else { return nil }
        return try await workAssetVault.url(for: key)
    }

    /// One row, one availability pass. This sits on the material
    /// import/read-back hot path and is called once per image on every board
    /// load, so it must never project the whole board to answer a single id.
    private func fetchWorkMaterial(id: UUID) async throws -> WorkMaterialRecord? {
        try await ensureLoaded()
        let context = newReadContext()
        let stored = try await context.perform { [context] () -> StoredWorkMaterial? in
            try Self.workMaterialRow(id: id, in: context).map(StoredWorkMaterial.init)
        }
        guard let stored else { return nil }
        return try await workMaterialRecords(for: [stored]).first
    }

    /// The ONE projection from stored rows to records, and therefore the one
    /// place a card's availability is decided. Both questions behind it — which
    /// vault leaves are on this device, and which synced payloads have a whole
    /// blob behind them — are asked ONCE for the whole batch.
    ///
    /// Per-row resolution is what this exists to prevent: each answer is a hop
    /// onto the vault actor or a fetch into the payload store, so asking card
    /// by card queues a board's worth of round trips behind every other write
    /// in flight, on the path a board refresh runs on.
    private func workMaterialRecords(
        for materials: [StoredWorkMaterial]
    ) async throws -> [WorkMaterialRecord] {
        guard !materials.isEmpty else { return [] }

        let vaultKeys = Array(Set(materials.compactMap(\.localVaultKey)))
        var availableLocalKeys: Set<String> = []
        if !vaultKeys.isEmpty {
            availableLocalKeys = Set(await workAssetVault.urls(for: vaultKeys).keys)
        }

        // Only a card that CLAIMS synced bytes asks the payload store anything,
        // so the predicate carries exactly the ids whose answer is read.
        let syncedIDs = Set(
            materials.compactMap { $0.storageMode == .syncedPayload ? $0.id : nil }
        )
        let completeBlobMaterialIDs = Set(
            try await workMaterialBlobCompleteness(materialIDs: syncedIDs).keys
        )

        return materials.map {
            $0.record(
                availableLocalKeys: availableLocalKeys,
                completeBlobMaterialIDs: completeBlobMaterialIDs
            )
        }
    }

    private func fetchWorkItems(
        itemID: UUID?,
        captureEnvelopeID: UUID?
    ) async throws -> [WorkItemRecord] {
        try await ensureLoaded()
        let context = newReadContext()
        let stored = try await context.perform { [context] () -> StoredWorkboard in
            let itemRequest = NSFetchRequest<NSManagedObject>(entityName: "WorkItem")
            if let itemID {
                itemRequest.predicate = NSPredicate(format: "id == %@", itemID as CVarArg)
            } else if let captureEnvelopeID {
                itemRequest.predicate = NSPredicate(
                    format: "captureEnvelopeID == %@", captureEnvelopeID as CVarArg
                )
            }
            itemRequest.sortDescriptors = [
                NSSortDescriptor(key: "isPinned", ascending: false),
                NSSortDescriptor(key: "updatedAt", ascending: false),
            ]
            let items = try context.fetch(itemRequest).map(StoredWorkItem.init)
            let itemIDs = Set(items.map(\.id))
            guard !itemIDs.isEmpty else { return StoredWorkboard(items: [], materials: []) }

            let materialRequest = NSFetchRequest<NSManagedObject>(entityName: "WorkMaterial")
            materialRequest.predicate = NSPredicate(format: "workItemID IN %@", Array(itemIDs))
            materialRequest.sortDescriptors = [
                NSSortDescriptor(key: "sequence", ascending: true),
                NSSortDescriptor(key: "createdAt", ascending: true),
            ]
            let materials = try context.fetch(materialRequest).map(StoredWorkMaterial.init)

            return StoredWorkboard(items: items, materials: materials)
        }

        // Deduplicate BEFORE resolving availability: a physically duplicated
        // CloudKit row is not a second card, so it must not become a second
        // vault probe or a second id in the blob predicate.
        let canonicalItems = Self.deduplicatedWorkItems(stored.items)
        let canonicalMaterials = Self.deduplicatedWorkMaterials(stored.materials)
        let materialRecords = try await workMaterialRecords(for: canonicalMaterials)
        let materialsByItem = Dictionary(grouping: materialRecords, by: \.workItemID)

        return canonicalItems.map { item in
            item.record(materials: materialsByItem[item.id] ?? [])
        }
    }

    /// CloudKit cannot enforce Core Data uniqueness constraints. Concurrent
    /// offline capture can therefore import physically duplicated rows carrying
    /// the same app-level UUID. Project one deterministic logical row without
    /// deleting either CloudKit record; later writes advance the chosen row and
    /// all material-order paths intentionally operate on every matching row.
    private static func deduplicatedWorkItems(_ items: [StoredWorkItem]) -> [StoredWorkItem] {
        var selected: [UUID: StoredWorkItem] = [:]
        var order: [UUID] = []
        for item in items {
            guard let current = selected[item.id] else {
                selected[item.id] = item
                order.append(item.id)
                continue
            }
            if (item.updatedAt, item.createdAt, item.content.title)
                > (current.updatedAt, current.createdAt, current.content.title) {
                selected[item.id] = item
            }
        }
        return order.compactMap { selected[$0] }
    }

    private static func deduplicatedWorkMaterials(
        _ materials: [StoredWorkMaterial]
    ) -> [StoredWorkMaterial] {
        struct Identity: Hashable {
            let itemID: UUID
            let materialID: UUID
        }
        var selected: [Identity: StoredWorkMaterial] = [:]
        var order: [Identity] = []
        for material in materials {
            let identity = Identity(itemID: material.workItemID, materialID: material.id)
            guard let current = selected[identity] else {
                selected[identity] = material
                order.append(identity)
                continue
            }
            if (material.updatedAt, material.createdAt, material.title)
                > (current.updatedAt, current.createdAt, current.title) {
                selected[identity] = material
            }
        }
        return order.compactMap { selected[$0] }
    }

    /// Reconcile the device-local vault against a complete, committed fetch of
    /// `WorkMaterial.localVaultKey`. The database is the authority only after
    /// the fetch succeeds; a load failure therefore deletes nothing. The vault
    /// separately protects keys still inside the file-to-row publication gap.
    @discardableResult
    func reconcileWorkAssetVault(
        using explicitVault: WorkAssetVault? = nil
    ) async throws -> Int {
        try await ensureLoaded()
        let context = newReadContext()
        let referencedKeys = try await context.perform { [context] () -> Set<String> in
            let request = NSFetchRequest<NSDictionary>(entityName: "WorkMaterial")
            request.resultType = .dictionaryResultType
            request.propertiesToFetch = ["localVaultKey"]
            return Set(
                try context.fetch(request).compactMap { row in
                    row["localVaultKey"] as? String
                }
            )
        }
        return await (explicitVault ?? workAssetVault).reclaimUnreferenced(keeping: referencedKeys)
    }

    // MARK: - Row helpers

    private static func workItemRow(id: UUID, in context: NSManagedObjectContext) throws -> NSManagedObject? {
        let request = NSFetchRequest<NSManagedObject>(entityName: "WorkItem")
        request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        request.sortDescriptors = [NSSortDescriptor(key: "updatedAt", ascending: false)]
        request.fetchLimit = 1
        return try context.fetch(request).first
    }

    private static func workItemRow(
        captureEnvelopeID: UUID,
        in context: NSManagedObjectContext
    ) throws -> NSManagedObject? {
        let request = NSFetchRequest<NSManagedObject>(entityName: "WorkItem")
        request.predicate = NSPredicate(
            format: "captureEnvelopeID == %@", captureEnvelopeID as CVarArg
        )
        request.sortDescriptors = [NSSortDescriptor(key: "updatedAt", ascending: false)]
        request.fetchLimit = 1
        return try context.fetch(request).first
    }

    /// EVERY physical row of one logical material, newest first. CloudKit can
    /// merge one card into several records under a single app-level id, so a
    /// write that has to survive that merge touches all of them rather than the
    /// canonical one alone.
    private static func workMaterialRows(
        id: UUID,
        in context: NSManagedObjectContext
    ) throws -> [NSManagedObject] {
        let request = NSFetchRequest<NSManagedObject>(entityName: "WorkMaterial")
        request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        request.sortDescriptors = [
            NSSortDescriptor(key: "updatedAt", ascending: false),
            NSSortDescriptor(key: "createdAt", ascending: false),
            NSSortDescriptor(key: "title", ascending: false),
        ]
        return try context.fetch(request)
    }

    private static func workMaterialRow(id: UUID, in context: NSManagedObjectContext) throws -> NSManagedObject? {
        let request = NSFetchRequest<NSManagedObject>(entityName: "WorkMaterial")
        request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        // Same newest-wins ordering `deduplicatedWorkMaterials` applies, so a
        // single-row read and the full projection agree on which physical row of
        // a CloudKit-duplicated material is canonical.
        request.sortDescriptors = [
            NSSortDescriptor(key: "updatedAt", ascending: false),
            NSSortDescriptor(key: "createdAt", ascending: false),
            NSSortDescriptor(key: "title", ascending: false),
        ]
        request.fetchLimit = 1
        return try context.fetch(request).first
    }

    /// The single sequence-rewrite the Workboard has. Both the editor's autosave
    /// and a board drag land here, so material order can never mean one thing in
    /// one surface and another elsewhere. `orderedMaterialIDs` must name every
    /// LOGICAL material of the item exactly once; CloudKit can materialize one
    /// logical material as several physical rows, so each of them is rewritten
    /// to the same rank and a stray duplicate is normalized rather than refused.
    /// Timestamps are the caller's business: this only decides ranks.
    private static func rewriteWorkMaterialSequence(
        orderedMaterialIDs: [UUID],
        workItemID: UUID,
        in context: NSManagedObjectContext
    ) throws -> (materials: [NSManagedObject], didChange: Bool) {
        let request = NSFetchRequest<NSManagedObject>(entityName: "WorkMaterial")
        request.predicate = NSPredicate(format: "workItemID == %@", workItemID as CVarArg)
        let materials = try context.fetch(request)
        var rowsByID: [UUID: [NSManagedObject]] = [:]
        for material in materials {
            guard let materialID = material.value(forKey: "id") as? UUID else {
                throw WorkboardStoreError.staleRevision
            }
            rowsByID[materialID, default: []].append(material)
        }
        guard orderedMaterialIDs.count == rowsByID.count,
              Set(orderedMaterialIDs) == Set(rowsByID.keys) else {
            throw WorkboardStoreError.staleRevision
        }

        var didChange = false
        for (index, materialID) in orderedMaterialIDs.enumerated() {
            guard let materialRows = rowsByID[materialID] else {
                throw WorkboardStoreError.staleRevision
            }
            let next = Int32(clamping: index)
            for material in materialRows {
                let current = (material.value(forKey: "sequence") as? NSNumber)?.int32Value
                guard current != next else { continue }
                material.setValue(NSNumber(value: next), forKey: "sequence")
                didChange = true
            }
        }
        return (materials, didChange)
    }

    private static func content(of row: NSManagedObject) -> WorkItemContent {
        WorkItemContent(
            title: row.value(forKey: "title") as? String ?? "",
            objective: row.value(forKey: "objective") as? String ?? "",
            context: row.value(forKey: "context") as? String ?? "",
            desiredOutcome: row.value(forKey: "desiredOutcome") as? String ?? "",
            constraints: row.value(forKey: "constraints") as? String ?? "",
            dueAt: row.value(forKey: "dueAt") as? Date,
            preferredGatewayRef: row.value(forKey: "preferredGatewayRef") as? String,
            isPinned: (row.value(forKey: "isPinned") as? NSNumber)?.boolValue ?? false
        )
    }

    /// Single write boundary for editable brief content, so every ingress —
    /// editor, share drain, Shortcuts/Siri — is held to the same field bound.
    /// An unattended writer can pipe a whole document into one field; refusing
    /// is honest, whereas truncating silently discards the user's text.
    private static func apply(_ content: WorkItemContent, to row: NSManagedObject) throws {
        let bounded = [
            content.title,
            content.objective,
            content.context,
            content.desiredOutcome,
            content.constraints,
        ]
        guard bounded.allSatisfy({
            $0.count <= WorkItemContentLimits.maximumFieldCharacters
        }) else {
            throw WorkboardStoreError.contentTooLong
        }
        let previousPinned = (row.value(forKey: "isPinned") as? NSNumber)?.boolValue ?? false
        if previousPinned != content.isPinned,
           row.value(forKey: "boardOrder") != nil {
            // Board rank belongs to exactly one pin cohort. Carrying it across
            // a pin mutation creates misleading gaps and cross-cohort rank
            // collisions, so the destination cohort assigns position afresh.
            row.setValue(nil, forKey: "boardOrder")
        }
        row.setValue(content.title, forKey: "title")
        row.setValue(content.objective, forKey: "objective")
        row.setValue(content.context, forKey: "context")
        row.setValue(content.desiredOutcome, forKey: "desiredOutcome")
        row.setValue(content.constraints, forKey: "constraints")
        row.setValue(content.dueAt, forKey: "dueAt")
        row.setValue(content.preferredGatewayRef, forKey: "preferredGatewayRef")
        row.setValue(NSNumber(value: content.isPinned), forKey: "isPinned")
    }

    /// `sequence` overrides the draft's own rank. A capture lane that cannot
    /// see the board — a headless intent, the share drainer — has no honest
    /// rank to state, so the write that owns the transaction decides it.
    private static func apply(
        _ draft: WorkMaterialDraft,
        workItemID: UUID,
        storageMode: WorkMaterialStorageMode,
        byteSize: Int64,
        localVaultKey: String?,
        sequence: Int? = nil,
        updatedAt: Date,
        to row: NSManagedObject
    ) {
        row.setValue(draft.id, forKey: "id")
        row.setValue(workItemID, forKey: "workItemID")
        row.setValue(draft.kind.rawValue, forKey: "kind")
        row.setValue(draft.title, forKey: "title")
        row.setValue(draft.caption, forKey: "caption")
        row.setValue(
            workboardSyncedTextContent(
                kind: draft.kind,
                storageMode: storageMode,
                proposed: draft.textContent
            ),
            forKey: "textContent"
        )
        row.setValue(draft.urlString, forKey: "urlString")
        row.setValue(draft.filename, forKey: "filename")
        row.setValue(draft.mimeType, forKey: "mimeType")
        // The payload column stays unwritten in every lane. Synced bytes live
        // in their own store so that a caption edit does not re-export them and
        // a board refresh does not realize them; writing them here as well
        // would give one payload two CKRecords and two chances to disagree.
        row.setValue(nil, forKey: "payload")
        // A thumbnail is still user file content. Keep it off the shared
        // model whenever the full payload is device-local.
        row.setValue(
            storageMode == .syncedPayload ? draft.thumbnailData : nil,
            forKey: "thumbnailData"
        )
        row.setValue(draft.width.map { NSNumber(value: Int32(clamping: $0)) }, forKey: "width")
        row.setValue(draft.height.map { NSNumber(value: Int32(clamping: $0)) }, forKey: "height")
        row.setValue(NSNumber(value: byteSize), forKey: "byteSize")
        row.setValue(
            NSNumber(value: Int32(clamping: sequence ?? draft.sequence)),
            forKey: "sequence"
        )
        row.setValue(storageMode.rawValue, forKey: "storageMode")
        row.setValue(localVaultKey, forKey: "localVaultKey")
        row.setValue(draft.cardSize.storedValue, forKey: "cardSize")
        row.setValue(draft.sourceDevice, forKey: "sourceDevice")
        row.setValue(draft.createdAt, forKey: "createdAt")
        row.setValue(updatedAt, forKey: "updatedAt")
    }

    private static func workRevision(for date: Date) -> Int64 {
        Int64(bitPattern: date.timeIntervalSinceReferenceDate.bitPattern)
    }

    /// `textContent` is part of the CloudKit-mirrored row. Notes/transcripts may
    /// live there, but an extract of a local file is still file content and must
    /// remain on its source device with the authoritative bytes.
    private static func workboardSyncedTextContent(
        kind: WorkMaterialKind,
        storageMode: WorkMaterialStorageMode,
        proposed: String?
    ) -> String? {
        guard storageMode != .localVault, kind != .file, kind != .image else {
            return nil
        }
        return proposed
    }

    // MARK: - Sendable row snapshots

    private nonisolated struct StoredWorkboard: Sendable {
        let items: [StoredWorkItem]
        let materials: [StoredWorkMaterial]
    }

    private nonisolated struct StoredWorkItem: Sendable {
        let id: UUID
        let content: WorkItemContent
        let createdAt: Date
        let updatedAt: Date
        let boardOrder: Int64?
        let completedAt: Date?
        let captureEnvelopeID: UUID?

        init(_ row: NSManagedObject) {
            id = row.value(forKey: "id") as? UUID ?? UUID()
            content = ConversationStore.content(of: row)
            createdAt = row.value(forKey: "createdAt") as? Date ?? .distantPast
            updatedAt = row.value(forKey: "updatedAt") as? Date ?? createdAt
            boardOrder = (row.value(forKey: "boardOrder") as? NSNumber)?.int64Value
            completedAt = row.value(forKey: "completedAt") as? Date
            captureEnvelopeID = row.value(forKey: "captureEnvelopeID") as? UUID
        }

        /// `state` is a constant. Work is one desk of collected material with no
        /// lifecycle to derive, and the column stays only so a row written by an
        /// older build still round-trips.
        func record(materials: [WorkMaterialRecord]) -> WorkItemRecord {
            WorkItemRecord(
                id: id,
                content: content,
                createdAt: createdAt,
                updatedAt: updatedAt,
                boardOrder: boardOrder,
                completedAt: completedAt,
                captureEnvelopeID: captureEnvelopeID,
                materials: materials,
                state: .draft
            )
        }
    }

    private nonisolated struct StoredWorkMaterial: Sendable {
        let id: UUID
        let workItemID: UUID
        let kind: WorkMaterialKind
        let title: String
        let caption: String
        let textContent: String?
        let urlString: String?
        let filename: String?
        let mimeType: String?
        let thumbnailData: Data?
        let width: Int?
        let height: Int?
        let byteSize: Int64
        let storageMode: WorkMaterialStorageMode
        let localVaultKey: String?
        let sourceDevice: String?
        let sequence: Int
        let cardSize: WorkMaterialCardSize
        let createdAt: Date
        let updatedAt: Date

        init(_ row: NSManagedObject) {
            id = row.value(forKey: "id") as? UUID ?? UUID()
            workItemID = row.value(forKey: "workItemID") as? UUID ?? UUID()
            kind = WorkMaterialKind(stored: row.value(forKey: "kind") as? String)
            title = row.value(forKey: "title") as? String ?? ""
            caption = row.value(forKey: "caption") as? String ?? ""
            textContent = ConversationStore.workboardSyncedTextContent(
                kind: kind,
                storageMode: WorkMaterialStorageMode(
                    stored: row.value(forKey: "storageMode") as? String
                ),
                proposed: row.value(forKey: "textContent") as? String
            )
            urlString = row.value(forKey: "urlString") as? String
            filename = row.value(forKey: "filename") as? String
            mimeType = row.value(forKey: "mimeType") as? String
            thumbnailData = row.value(forKey: "thumbnailData") as? Data
            width = (row.value(forKey: "width") as? NSNumber)?.intValue
            height = (row.value(forKey: "height") as? NSNumber)?.intValue
            byteSize = (row.value(forKey: "byteSize") as? NSNumber)?.int64Value ?? 0
            storageMode = WorkMaterialStorageMode(
                stored: row.value(forKey: "storageMode") as? String
            )
            localVaultKey = row.value(forKey: "localVaultKey") as? String
            sourceDevice = row.value(forKey: "sourceDevice") as? String
            sequence = (row.value(forKey: "sequence") as? NSNumber)?.intValue ?? 0
            cardSize = WorkMaterialCardSize(stored: row.value(forKey: "cardSize") as? String)
            createdAt = row.value(forKey: "createdAt") as? Date ?? .distantPast
            updatedAt = row.value(forKey: "updatedAt") as? Date ?? createdAt
        }

        /// Both sets are resolved once per fetch by `workMaterialRecords(for:)`
        /// and handed in whole. A row answers from them and reaches nothing
        /// else: a projection that could probe the filesystem or the payload
        /// store per card is the shape this signature refuses.
        func record(
            availableLocalKeys: Set<String>,
            completeBlobMaterialIDs: Set<UUID>
        ) -> WorkMaterialRecord {
            let availability: WorkMaterialAvailability
            switch storageMode {
            case .metadataOnly:
                availability = .metadataOnly
            case .syncedPayload:
                // The card names bytes in the payload store, which CloudKit
                // materializes independently of the material row — so the claim
                // is not the proof. Only a COMPLETE blob row is, and
                // `WorkMaterialBlobRecord.isComplete` is where that rule lives;
                // membership of this set already carries it.
                availability = completeBlobMaterialIDs.contains(id) ? .synced : .syncedPending
            case .localVault:
                availability = localVaultKey.map(availableLocalKeys.contains) == true
                    ? .availableLocally : .unavailableOnThisDevice
            }
            return WorkMaterialRecord(
                id: id,
                workItemID: workItemID,
                kind: kind,
                title: title,
                caption: caption,
                textContent: textContent,
                urlString: urlString,
                filename: filename,
                mimeType: mimeType,
                thumbnailData: thumbnailData,
                width: width,
                height: height,
                byteSize: byteSize,
                hasPayload: availability == .synced || availability == .availableLocally,
                storageMode: storageMode,
                availability: availability,
                localVaultKey: localVaultKey,
                sourceDevice: sourceDevice,
                sequence: sequence,
                cardSize: cardSize,
                createdAt: createdAt,
                updatedAt: updatedAt
            )
        }
    }

    #if CONDUCK_TESTING
    /// TEST SEAM — read the PHYSICAL rows behind one logical material.
    ///
    /// WHY IT HAS TO EXIST. Every read path deduplicates to one canonical row,
    /// which is exactly what hides the property the size and order writers are
    /// built for: that they touch EVERY duplicate. A projection-level assertion
    /// passes whether one row was written or all of them, so the duplicate
    /// tolerance could be deleted and the suite would stay green until a real
    /// account merged two records and a card silently reverted its size.
    ///
    /// Gated on the in-memory store for the same reason every other seam is:
    /// nothing here may reach the founder's real data from a signed suite run.
    func _workMaterialRowsForTesting(id: UUID) async -> [WorkMaterialRowProbe] {
        do { try await ensureLoaded() } catch { return [] }
        let context = newWriteContext()
        return await context.perform { [context] in
            guard Self.isInMemory(context) else { return [] }
            let request = NSFetchRequest<NSManagedObject>(entityName: "WorkMaterial")
            request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
            request.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: true)]
            return ((try? context.fetch(request)) ?? []).map { row in
                WorkMaterialRowProbe(
                    sequence: (row.value(forKey: "sequence") as? NSNumber)?.int32Value,
                    cardSize: row.value(forKey: "cardSize") as? String,
                    updatedAt: row.value(forKey: "updatedAt") as? Date
                )
            }
        }
    }

    /// TEST SEAM — add a second physical row carrying the same app-level UUID.
    ///
    /// WHY IT HAS TO EXIST. CloudKit cannot enforce Core Data uniqueness, so two
    /// offline devices can import one logical material as several rows. No
    /// public API can produce that state — every insert path refuses a colliding
    /// id — so the duplicate-tolerant writes have no reachable test without a
    /// seam. Same in-memory gate as above.
    func _duplicateWorkMaterialRowForTesting(id: UUID) async {
        do { try await ensureLoaded() } catch { return }
        let context = newWriteContext()
        await context.perform { [context] in
            guard Self.isInMemory(context) else { return }
            let request = NSFetchRequest<NSManagedObject>(entityName: "WorkMaterial")
            request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
            request.fetchLimit = 1
            guard let source = try? context.fetch(request).first else { return }
            let copy = NSEntityDescription.insertNewObject(
                forEntityName: "WorkMaterial", into: context
            )
            for name in source.entity.attributesByName.keys {
                copy.setValue(source.value(forKey: name), forKey: name)
            }
            try? context.save()
        }
    }

    /// TEST SEAM — write an arbitrary raw string into the `cardSize` column of
    /// every physical row of one material.
    ///
    /// WHY IT HAS TO EXIST. The size a NEWER build writes is by definition a
    /// value this build's enum does not contain, and the public setter accepts
    /// only values it does contain. Without a seam the lenient read is
    /// unreachable, and a card synced from a newer device would be free to
    /// vanish or crash the board with nothing to catch it.
    func _setWorkMaterialCardSizeColumnForTesting(_ rawValue: String?, materialID: UUID) async {
        do { try await ensureLoaded() } catch { return }
        let context = newWriteContext()
        await context.perform { [context] in
            guard Self.isInMemory(context) else { return }
            let request = NSFetchRequest<NSManagedObject>(entityName: "WorkMaterial")
            request.predicate = NSPredicate(format: "id == %@", materialID as CVarArg)
            for row in (try? context.fetch(request)) ?? [] {
                row.setValue(rawValue, forKey: "cardSize")
            }
            try? context.save()
        }
    }

    /// TEST SEAM — every PHYSICAL blob row of one material, newest first.
    ///
    /// WHY IT HAS TO EXIST. Duplicate blobs are a legal transient state that
    /// only the newest COMPLETE row resolves, and paired deletion has to leave
    /// none of them behind. Both facts are invisible through `loadWorkMaterial`
    /// — it answers with bytes, so one correct row and three stale ones read
    /// identically to one correct row.
    func _workMaterialBlobRowsForTesting(materialID: UUID) async -> [WorkMaterialBlobRowProbe] {
        do { try await ensureLoaded() } catch { return [] }
        let context = newReadContext()
        return await context.perform { [context] in
            guard Self.isInMemory(context) else { return [] }
            let rows = (try? Self.blobRows(materialID: materialID, in: context)) ?? []
            return rows.map { row in
                WorkMaterialBlobRowProbe(
                    byteSize: (row.value(forKey: "byteSize") as? NSNumber)?.int64Value,
                    contentHash: row.value(forKey: "contentHash") as? String,
                    payloadByteCount: (row.value(forKey: "payload") as? Data)?.count,
                    createdAt: row.value(forKey: "createdAt") as? Date,
                    updatedAt: row.value(forKey: "updatedAt") as? Date
                )
            }
        }
    }

    /// TEST SEAM — the raw `WorkMaterial.payload` column.
    ///
    /// WHY IT HAS TO EXIST. "The payload column stays unwritten" is a claim
    /// about a column no reader reads any more, so nothing in the projection
    /// can catch a regression that starts writing it again — the card would
    /// still open, and every byte would quietly ride the material's own
    /// CKRecord as well as its blob's.
    func _workMaterialPayloadColumnForTesting(id: UUID) async -> Data? {
        do { try await ensureLoaded() } catch { return nil }
        let context = newReadContext()
        return await context.perform { [context] in
            guard Self.isInMemory(context) else { return nil }
            let row = try? Self.workMaterialRow(id: id, in: context)
            return row?.value(forKey: "payload") as? Data
        }
    }

    /// TEST SEAM — insert one blob row directly, bypassing publication.
    ///
    /// WHY IT HAS TO EXIST. CloudKit can import one logical blob as several
    /// physical rows, and a row whose hash or size has not arrived is a legal
    /// in-flight state. No public API can produce either — publication refuses
    /// to write a second row for bytes it already has, and never writes an
    /// incomplete one — so newest-complete-wins and the leave-incomplete-rows
    /// rule have no reachable test without a seam.
    func _insertWorkMaterialBlobRowForTesting(
        materialID: UUID,
        payload: Data,
        byteSize: Int64,
        contentHash: String,
        updatedAt: Date
    ) async {
        do { try await ensureLoaded() } catch { return }
        let context = newWriteContext()
        await context.perform { [context] in
            guard Self.isInMemory(context) else { return }
            let row = NSEntityDescription.insertNewObject(
                forEntityName: "WorkMaterialBlob", into: context
            )
            row.setValue(materialID, forKey: "materialID")
            row.setValue(payload, forKey: "payload")
            row.setValue(NSNumber(value: byteSize), forKey: "byteSize")
            row.setValue(contentHash, forKey: "contentHash")
            row.setValue(updatedAt, forKey: "createdAt")
            row.setValue(updatedAt, forKey: "updatedAt")
            try? context.save()
        }
    }

    /// TEST SEAM — drop every blob of one material, leaving the card standing.
    ///
    /// WHY IT HAS TO EXIST. It is the state the payload store's loss produces —
    /// proven survivable and silent — and the one state no publication path can
    /// reach, because paired deletion always takes the material with the bytes.
    /// A card claiming `.syncedPayload` with nothing behind it is what the
    /// pending projection is for, so it has to be constructible.
    @discardableResult
    func _deleteWorkMaterialBlobRowsForTesting(materialID: UUID) async -> Int {
        do { try await ensureLoaded() } catch { return 0 }
        let context = newWriteContext()
        return await context.perform { [context] in
            guard Self.isInMemory(context) else { return 0 }
            let deleted = (try? Self.deleteBlobRows(materialID: materialID, in: context)) ?? 0
            try? context.save()
            return deleted
        }
    }

    /// TEST SEAM — run ONLY the first publication step of a desk capture.
    ///
    /// WHY IT HAS TO EXIST. The protocol's whole claim is that a process dying
    /// between the blob save and the material save leaves a repairable state.
    /// A crash runs no rollback, so the refusal paths cannot stand in for it,
    /// and hand-inserting a row would test a fixture rather than the code that
    /// writes blobs. This runs the real staging and the real blob publication
    /// and then stops where a crash would.
    func _publishDeskMaterialBlobOnlyForTesting(_ draft: WorkMaterialDraft) async throws {
        try await ensureLoaded()
        let probe = newReadContext()
        let isolated = await probe.perform { [probe] in Self.isInMemory(probe) }
        guard isolated else { return }
        let staged = try await stageWorkMaterialBytes(
            id: draft.id,
            kind: draft.kind,
            filename: draft.filename,
            payload: draft.payload,
            declaredByteSize: draft.byteSize,
            declaredStorageMode: draft.storageMode,
            sourceFileURL: nil,
            sourceFileByteSize: nil,
            onProgress: { _ in }
        )
        guard staged.storageMode == .syncedPayload,
              let payload = staged.blobPayload,
              let contentHash = staged.contentHash else { return }
        _ = try await publishWorkMaterialBlob(
            materialID: draft.id,
            payload: payload,
            byteSize: staged.byteSize,
            contentHash: contentHash
        )
    }

    private static func isInMemory(_ context: NSManagedObjectContext) -> Bool {
        context.persistentStoreCoordinator?.persistentStores
            .allSatisfy { $0.type == NSInMemoryStoreType } == true
    }
    #endif
}
