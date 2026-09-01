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

import Foundation
import CoreData

#if CONDUCK_TESTING
/// One PHYSICAL `WorkMaterial` row, before deduplication collapses a
/// CloudKit-merged material to a single logical card.
nonisolated struct WorkMaterialRowProbe: Sendable, Hashable {
    let sequence: Int32?
    let cardSize: String?
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
    /// CRASH REPAIR. Payload bytes and database rows cannot commit as one
    /// transaction, so an interrupted capture leaves a partial state a replay
    /// must repair rather than duplicate. Two are handled here: a material
    /// whose owner row never landed — the desk is re-ensured on every call, so
    /// a material stranded without it becomes visible again — and a material
    /// whose payload never landed, restaged from the bytes the replaying
    /// caller still carries. Bytes that are already readable are never
    /// rewritten, and a row that claims no payload is never given one: that is
    /// reattach, which `replaceWorkMaterialPayloadFile` owns. The synced-blob
    /// states — blob without material, material without blob — extend this
    /// same seam when payload bytes move into their own store.
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

    /// Payload bytes made durable before any row is written.
    private nonisolated struct StagedWorkMaterialBytes: Sendable {
        let storageMode: WorkMaterialStorageMode
        let byteSize: Int64
        let vaultKey: String?
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
        // Repair restores bytes a row already claims and cannot produce. It
        // never changes what a row claims: a `.metadataOnly` card gaining bytes
        // is a reattach, not a repair. The `.syncedPending` branch belongs to
        // the blob store and lands with it.
        let repairsPayload = existing.map {
            $0.storageMode == .localVault
                && $0.availability == .unavailableOnThisDevice
                && carriesBytes
        } ?? false

        let staged: StagedWorkMaterialBytes?
        if existing == nil || repairsPayload {
            staged = try await stageWorkMaterialBytes(
                id: draft.id,
                filename: draft.filename,
                payload: carriedPayload,
                declaredByteSize: draft.byteSize,
                declaredStorageMode: draft.storageMode,
                sourceFileURL: sourceFileURL,
                sourceFileByteSize: sourceFileByteSize,
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
                byteSize: draft.byteSize ?? 0,
                vaultKey: nil
            )
            onProgress(1)
        }

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
                    var repaired = false
                    if repairsPayload,
                       let staged,
                       staged.storageMode == .localVault,
                       let repairedKey = staged.vaultKey {
                        // CloudKit can materialize one logical material as
                        // several physical rows. Every one of them must name
                        // the bytes that just landed, or a later merge picks a
                        // row that still points at nothing.
                        for row in materialRows {
                            row.setValue(repairedKey, forKey: "localVaultKey")
                            row.setValue(NSNumber(value: staged.byteSize), forKey: "byteSize")
                            row.setValue(now, forKey: "updatedAt")
                        }
                        repaired = true
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

    /// Make payload bytes durable before any row names them. The vault leaf is
    /// derived from the MATERIAL id, so a replayed capture restages onto the
    /// same file instead of leaving an orphan behind for reconciliation.
    private func stageWorkMaterialBytes(
        id: UUID,
        filename: String?,
        payload: Data?,
        declaredByteSize: Int64?,
        declaredStorageMode: WorkMaterialStorageMode,
        sourceFileURL: URL?,
        sourceFileByteSize: Int64?,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> StagedWorkMaterialBytes {
        let suggestedExtension = filename.map { ($0 as NSString).pathExtension }
        if let sourceFileURL {
            let storedFile = try await workAssetVault.storeFileStreaming(
                at: sourceFileURL,
                id: id,
                suggestedExtension: suggestedExtension,
                expectedByteCount: sourceFileByteSize ?? declaredByteSize ?? -1,
                onProgress: onProgress
            )
            return StagedWorkMaterialBytes(
                storageMode: .localVault,
                byteSize: storedFile.byteCount,
                vaultKey: storedFile.key
            )
        }
        let byteSize = declaredByteSize ?? Int64(payload?.count ?? 0)
        let storageMode: WorkMaterialStorageMode = payload == nil
            ? declaredStorageMode : .localVault
        var vaultKey: String?
        if storageMode == .localVault, let payload {
            vaultKey = try await workAssetVault.store(
                payload,
                id: id,
                suggestedExtension: suggestedExtension
            )
        }
        onProgress(1)
        return StagedWorkMaterialBytes(
            storageMode: storageMode,
            byteSize: byteSize,
            vaultKey: vaultKey
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

    /// Add a material and update the parent card in one Core Data save. Payload
    /// bytes go to the explicit device-local vault; their row syncs metadata +
    /// availability instead of over-promising a CloudKit asset.
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

    /// Import a picker URL without materializing arbitrary bytes on the main
    /// actor. File bytes stream into the explicit device-local vault with
    /// cancellable progress; only metadata mirrors through private CloudKit.
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
    /// caption or title. Files stream to a new vault key; the old payload
    /// remains authoritative until the owner-revision CAS commits.
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
        let storedFile = try await workAssetVault.storeFileStreaming(
            at: sourceURL,
            id: UUID(),
            suggestedExtension: filename.map { ($0 as NSString).pathExtension },
            expectedByteCount: byteSize,
            onProgress: onProgress
        )
        let newKey = storedFile.key
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
                row.setValue(nil, forKey: "payload")
                row.setValue(WorkMaterialStorageMode.localVault.rawValue, forKey: "storageMode")
                row.setValue(newKey, forKey: "localVaultKey")
                row.setValue(sourceDevice, forKey: "sourceDevice")
                row.setValue(NSNumber(value: storedFile.byteCount), forKey: "byteSize")
                if let filename { row.setValue(filename, forKey: "filename") }
                if let mimeType { row.setValue(mimeType, forKey: "mimeType") }
                // Extracts and previews are user file content; the reattached
                // payload is device-local, so neither is carried into the
                // synced row.
                row.setValue(nil, forKey: "textContent")
                row.setValue(nil, forKey: "thumbnailData")
                let now = Date()
                row.setValue(now, forKey: "updatedAt")
                owner.setValue(now, forKey: "updatedAt")
                try context.save()
                return oldKey
            }
        } catch {
            try? await workAssetVault.remove(newKey)
            throw error
        }
        await workAssetVault.markReferenced(newKey)
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

    func loadWorkMaterialPayload(id: UUID) async throws -> Data? {
        try await ensureLoaded()
        let context = newReadContext()
        let payloadSource = try await context.perform { [context] () -> (WorkMaterialStorageMode, Data?, String?)? in
            guard let row = try Self.workMaterialRow(id: id, in: context) else { return nil }
            let mode = WorkMaterialStorageMode(stored: row.value(forKey: "storageMode") as? String)
            let data = mode == .syncedPayload ? row.value(forKey: "payload") as? Data : nil
            return (mode, data, row.value(forKey: "localVaultKey") as? String)
        }
        guard let payloadSource else { return nil }
        switch payloadSource.0 {
        case .metadataOnly:
            return nil
        case .syncedPayload:
            return payloadSource.1
        case .localVault:
            guard let key = payloadSource.2 else { return nil }
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

    /// One row, one vault probe. This sits on the material import/read-back hot
    /// path and is called once per image on every board load, so it must never
    /// project the whole board to answer a single id.
    private func fetchWorkMaterial(id: UUID) async throws -> WorkMaterialRecord? {
        try await ensureLoaded()
        let context = newReadContext()
        let stored = try await context.perform { [context] () -> StoredWorkMaterial? in
            try Self.workMaterialRow(id: id, in: context).map(StoredWorkMaterial.init)
        }
        guard let stored else { return nil }
        var availableLocalKeys: Set<String> = []
        if let key = stored.localVaultKey, await workAssetVault.contains(key) {
            availableLocalKeys.insert(key)
        }
        return stored.record(availableLocalKeys: availableLocalKeys)
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

        var availableLocalKeys: Set<String> = []
        for key in Set(stored.materials.compactMap(\.localVaultKey)) {
            if await workAssetVault.contains(key) { availableLocalKeys.insert(key) }
        }

        let canonicalItems = Self.deduplicatedWorkItems(stored.items)
        let canonicalMaterials = Self.deduplicatedWorkMaterials(stored.materials)
        let materialRecords = canonicalMaterials.map { $0.record(availableLocalKeys: availableLocalKeys) }
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
        row.setValue(storageMode == .syncedPayload ? draft.payload : nil, forKey: "payload")
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

        func record(availableLocalKeys: Set<String>) -> WorkMaterialRecord {
            let availability: WorkMaterialAvailability
            switch storageMode {
            case .metadataOnly:
                availability = .metadataOnly
            case .syncedPayload:
                availability = .synced
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

    private static func isInMemory(_ context: NSManagedObjectContext) -> Bool {
        context.persistentStoreCoordinator?.persistentStores
            .allSatisfy { $0.type == NSInMemoryStoreType } == true
    }
    #endif
}
