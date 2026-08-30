// SPDX-License-Identifier: Apache-2.0

// Conduck
// ConversationStore+Workboard.swift
//
// Private-CloudKit persistence for the personal Agent Workboard: editable
// briefs and materials, immutable dispatch snapshots, state derived from the
// exact linked conversation turn, full-text in-app search, and the one atomic
// prepare-for-transport boundary. Workboard rows use UUID foreign keys instead
// of Core Data relationships so deleting a card never deletes the conversation
// it created, and deleting a conversation never destroys the audit snapshot.
// No method here performs network I/O or silently chooses a gateway.

import Foundation
import CoreData

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
            Self.apply(draft.content, to: row)
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

    func fetchWorkItems(matching query: String = "") async throws -> [WorkItemRecord] {
        let records = try await fetchWorkItems(itemID: nil, captureEnvelopeID: nil)
        let tokens = Self.workSearchTokens(query)
        guard !tokens.isEmpty else { return records }
        return records.filter { Self.matchesWorkSearch($0, tokens: tokens) }
    }

    func fetchWorkItem(id: UUID) async throws -> WorkItemRecord? {
        try await fetchWorkItems(itemID: id, captureEnvelopeID: nil).first
    }

    func fetchWorkItem(captureEnvelopeID: UUID) async throws -> WorkItemRecord? {
        try await fetchWorkItems(itemID: nil, captureEnvelopeID: captureEnvelopeID).first
    }

    /// Persist one presentation-only project-strip reorder without advancing
    /// any brief revision or lifecycle fact. The request carries the complete
    /// pin cohort the person saw; comparison and rewrite are atomic in this
    /// local store and a replay is idempotent. CloudKit mirrors WorkItem rows as
    /// independent records, so simultaneous drags on different devices can
    /// merge into duplicate ranks. Presentation has a stable tie-breaker and the
    /// next local drag normalizes the complete cohort again.
    func reorderWorkItems(_ reorder: WorkItemBoardReorder) async throws -> [WorkItemRecord] {
        let orderedIDs = reorder.orderedItemIDs
        let orderedIDSet = Set(orderedIDs)
        let expectedIDs = reorder.expectedPositions.map(\.id)
        guard !orderedIDs.isEmpty,
              orderedIDSet.count == orderedIDs.count,
              orderedIDSet.contains(reorder.movingItemID),
              Set(expectedIDs) == orderedIDSet,
              Set(expectedIDs).count == expectedIDs.count else {
            throw WorkboardStoreError.staleRevision
        }

        let expectedByID = Dictionary(
            uniqueKeysWithValues: reorder.expectedPositions.map { ($0.id, $0) }
        )
        let desiredByID = Dictionary(
            uniqueKeysWithValues: reorder.desiredPositions.map { ($0.id, $0) }
        )

        try await ensureLoaded()
        let context = newWriteContext()
        let changed = try await context.perform { [context] in
            let request = NSFetchRequest<NSManagedObject>(entityName: "WorkItem")
            let rows = try context.fetch(request)
            var rowsByID: [UUID: [NSManagedObject]] = [:]
            for row in rows {
                guard let id = row.value(forKey: "id") as? UUID else { continue }
                rowsByID[id, default: []].append(row)
            }

            func boardOrder(of row: NSManagedObject) -> Int64? {
                (row.value(forKey: "boardOrder") as? NSNumber)?.int64Value
            }

            func preferredRow(in candidates: [NSManagedObject]) -> NSManagedObject? {
                candidates.max { lhs, rhs in
                    let left = (
                        lhs.value(forKey: "updatedAt") as? Date ?? .distantPast,
                        lhs.value(forKey: "createdAt") as? Date ?? .distantPast,
                        lhs.value(forKey: "title") as? String ?? ""
                    )
                    let right = (
                        rhs.value(forKey: "updatedAt") as? Date ?? .distantPast,
                        rhs.value(forKey: "createdAt") as? Date ?? .distantPast,
                        rhs.value(forKey: "title") as? String ?? ""
                    )
                    return left < right
                }
            }

            let canonicalRows = rowsByID.compactMapValues(preferredRow)
            let currentCohortIDs = Set(canonicalRows.compactMap { id, row in
                let isPinned = (row.value(forKey: "isPinned") as? NSNumber)?.boolValue
                    ?? false
                return isPinned == reorder.expectedPinned ? id : nil
            })
            for id in orderedIDs {
                guard let canonical = canonicalRows[id] else {
                    throw WorkboardStoreError.staleRevision
                }
                let isPinned = (canonical.value(forKey: "isPinned") as? NSNumber)?.boolValue
                    ?? false
                guard isPinned == reorder.expectedPinned else {
                    throw WorkboardStoreError.staleRevision
                }
            }

            // Check replay success before the optimistic expectation. A caller
            // retrying after losing the response must not turn success into a
            // misleading conflict merely because its old rank tokens are stale.
            let alreadyApplied = orderedIDs.allSatisfy { id in
                guard let desired = desiredByID[id]?.boardOrder,
                      let candidates = rowsByID[id] else {
                    return false
                }
                return candidates.allSatisfy { boardOrder(of: $0) == desired }
            }
            if alreadyApplied { return false }

            guard currentCohortIDs == orderedIDSet else {
                throw WorkboardStoreError.staleRevision
            }

            for id in orderedIDs {
                guard let canonical = canonicalRows[id],
                      let expected = expectedByID[id],
                      boardOrder(of: canonical) == expected.boardOrder else {
                    throw WorkboardStoreError.staleRevision
                }
            }

            for id in orderedIDs {
                guard let desired = desiredByID[id]?.boardOrder,
                      let candidates = rowsByID[id] else {
                    throw WorkboardStoreError.staleRevision
                }
                for row in candidates where boardOrder(of: row) != desired {
                    row.setValue(NSNumber(value: desired), forKey: "boardOrder")
                }
            }
            try context.save()
            return true
        }
        if changed { await postDidChange() }

        let recordsByID = Dictionary(
            uniqueKeysWithValues: try await fetchWorkItems().map { ($0.id, $0) }
        )
        guard orderedIDs.allSatisfy({ recordsByID[$0] != nil }) else {
            throw WorkboardStoreError.itemNotFound
        }
        return orderedIDs.compactMap { recordsByID[$0] }
    }

    /// Creates one editable, inert Work item from a chat turn. The message id is
    /// the capture identity and every attachment keeps its own id, so retrying
    /// after a process interruption repairs the same item instead of duplicating
    /// the card or any source. The originating gateway is only a preference for
    /// later preflight; this method has no transport path.
    func captureMessageToWork(
        _ message: MessageRecord,
        conversationID: UUID
    ) async throws -> WorkMessageCaptureReceipt {
        while workMessageCaptureClaims.contains(message.id) {
            try await Task.sleep(for: .milliseconds(40))
        }
        workMessageCaptureClaims.insert(message.id)
        defer { workMessageCaptureClaims.remove(message.id) }

        let previous = try await fetchWorkItem(captureEnvelopeID: message.id)
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
        let inferred = WorkboardWorkspaceCaptureLogic.title(for: messageText)
        let title: String
        let objective: String
        if isUser {
            title = inferred.isEmpty ? conversationTitle : inferred
            objective = messageText
        } else {
            title = String.localizedStringWithFormat(
                String(localized: "workboard.chatCapture.followUpTitle", defaultValue: "Follow up: %@"),
                conversationTitle
            )
            objective = String(
                localized: "workboard.chatCapture.followUpObjective",
                defaultValue: "Continue working from this response."
            )
        }

        let item = try await createWorkItem(WorkItemDraft(
            // Core Data + CloudKit cannot enforce uniqueness. Reusing the
            // source turn as both capture identity and item identity means two
            // offline devices still converge on one logical Work id; fetch and
            // mutation paths below tolerate duplicate physical rows.
            id: message.id,
            captureEnvelopeID: message.id,
            content: WorkItemContent(
                title: title,
                objective: objective,
                context: String.localizedStringWithFormat(
                    String(localized: "workboard.chatCapture.context", defaultValue: "Captured from %@."),
                    conversationTitle
                ),
                preferredGatewayRef: conversation?.backend
            ),
            createdAt: persistedMessage.createdAt
        ))

        var existingIDs = Set(item.materials.map(\.id))
        var added = 0
        var referencedOnly = 0
        var failed = 0

        if !isUser, !messageText.isEmpty, !existingIDs.contains(persistedMessage.id) {
            do {
                _ = try await addWorkMaterial(
                    WorkMaterialDraft(
                        id: persistedMessage.id,
                        kind: .note,
                        title: String(localized: "workboard.chatCapture.response", defaultValue: "Chat response"),
                        textContent: messageText,
                        sequence: 0,
                        storageMode: .metadataOnly,
                        sourceDevice: persistedMessage.sourceDevice,
                        createdAt: persistedMessage.createdAt
                    ),
                    to: item.id
                )
                existingIDs.insert(persistedMessage.id)
                added += 1
            } catch {
                failed += 1
            }
        }

        let payloads = try await loadLocalAttachmentPayloads(for: persistedMessage.id)
        let baseSequence = isUser ? 0 : 1
        for (offset, attachment) in persistedMessage.attachments.sorted(by: { $0.sequence < $1.sequence }).enumerated() {
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
                    sequence: baseSequence + offset,
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
                    sequence: baseSequence + offset,
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
                    sequence: baseSequence + offset,
                    storageMode: .metadataOnly,
                    sourceDevice: persistedMessage.sourceDevice,
                    createdAt: attachment.createdAt
                )
            }
            do {
                _ = try await addWorkMaterial(material, to: item.id)
                existingIDs.insert(attachment.id)
                added += 1
            } catch {
                failed += 1
            }
        }

        return WorkMessageCaptureReceipt(
            itemID: item.id,
            addedMaterialCount: added,
            referencedOnlyMaterialCount: referencedOnly,
            failedMaterialCount: failed,
            wasAlreadyCaptured: previous != nil
        )
    }

    /// Replace editable content as one coherent save. Dispatch snapshots remain
    /// byte-for-byte frozen and completion is not changed implicitly.
    func updateWorkItem(id: UUID, content: WorkItemContent) async throws -> WorkItemRecord? {
        try await ensureLoaded()
        let context = newWriteContext()
        let changed = try await context.perform { [context] in
            guard let row = try Self.workItemRow(id: id, in: context) else { return false }
            guard Self.content(of: row) != content else { return false }
            Self.apply(content, to: row)
            row.setValue(Date(), forKey: "updatedAt")
            try context.save()
            return true
        }
        if changed { await postDidChange() }
        return try await fetchWorkItem(id: id)
    }

    /// Compare-and-save the editable brief and its material order in one Core
    /// Data transaction. This is the autosave boundary used by the editor: a
    /// CloudKit/local write that lands after the editor opened cannot be
    /// overwritten between a separate revision check, content save and reorder.
    func saveWorkItemDraft(
        id: UUID,
        expectedRevision: Int64,
        content: WorkItemContent,
        orderedMaterialIDs: [UUID],
        createdAt: Date = Date()
    ) async throws -> WorkItemRecord {
        try await ensureLoaded()
        let context = newWriteContext()
        let changed = try await context.perform { [context] in
            if let row = try Self.workItemRow(id: id, in: context) {
                guard expectedRevision != 0,
                      let updatedAt = row.value(forKey: "updatedAt") as? Date,
                      Self.workRevision(for: updatedAt) == expectedRevision else {
                    throw WorkboardStoreError.staleRevision
                }

                let request = NSFetchRequest<NSManagedObject>(entityName: "WorkMaterial")
                request.predicate = NSPredicate(format: "workItemID == %@", id as CVarArg)
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
                if Self.content(of: row) != content {
                    Self.apply(content, to: row)
                    didChange = true
                }
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
                guard didChange else { return false }
                let now = Date()
                row.setValue(now, forKey: "updatedAt")
                for material in materials where material.hasChanges {
                    material.setValue(now, forKey: "updatedAt")
                }
                try context.save()
                return true
            }

            guard expectedRevision == 0, orderedMaterialIDs.isEmpty else {
                throw expectedRevision == 0
                    ? WorkboardStoreError.staleRevision
                    : WorkboardStoreError.itemNotFound
            }
            let row = NSEntityDescription.insertNewObject(forEntityName: "WorkItem", into: context)
            row.setValue(id, forKey: "id")
            Self.apply(content, to: row)
            row.setValue(createdAt, forKey: "createdAt")
            row.setValue(createdAt, forKey: "updatedAt")
            try context.save()
            return true
        }
        if changed { await postDidChange() }
        guard let record = try await fetchWorkItem(id: id) else {
            throw WorkboardStoreError.itemNotFound
        }
        return record
    }

    /// Human-owned completion. No transport callback calls this.
    func completeWorkItem(id: UUID, at completedAt: Date = Date()) async throws -> WorkItemRecord? {
        try await setWorkItemCompletion(id: id, completedAt: completedAt)
    }

    /// Reopen an objective without erasing any runs. If a result arrived while
    /// the card was Done, pure derivation exposes it in Review immediately.
    func reopenWorkItem(id: UUID) async throws -> WorkItemRecord? {
        try await setWorkItemCompletion(id: id, completedAt: nil)
    }

    private func setWorkItemCompletion(id: UUID, completedAt: Date?) async throws -> WorkItemRecord? {
        try await ensureLoaded()
        let context = newWriteContext()
        let changed = try await context.perform { [context] in
            guard let row = try Self.workItemRow(id: id, in: context) else { return false }
            let existing = row.value(forKey: "completedAt") as? Date
            guard existing != completedAt else { return false }
            row.setValue(completedAt, forKey: "completedAt")
            row.setValue(Date(), forKey: "updatedAt")
            try context.save()
            return true
        }
        if changed { await postDidChange() }
        return try await fetchWorkItem(id: id)
    }

    /// Acknowledge every terminal result currently visible for this card. The
    /// result identity is resolved and written in ONE Core Data transaction;
    /// a failure that re-mints its attempt id afterwards re-arms Review.
    @discardableResult
    func acknowledgeWorkItemReview(id: UUID, at acknowledgedAt: Date = Date()) async throws -> WorkItemRecord? {
        try await ensureLoaded()
        let context = newWriteContext()
        let changed = try await context.perform { [context] in
            guard try Self.workItemRow(id: id, in: context) != nil else { return false }
            let request = NSFetchRequest<NSManagedObject>(entityName: "WorkDispatch")
            request.predicate = NSPredicate(format: "workItemID == %@", id as CVarArg)
            var changed = false
            for dispatch in try context.fetch(request) {
                let activity = try Self.workDispatchActivity(for: dispatch, in: context)
                guard let resultKey = activity.resultKey else { continue }
                guard dispatch.value(forKey: "reviewAcknowledgedResultKey") as? String != resultKey else {
                    continue
                }
                dispatch.setValue(resultKey, forKey: "reviewAcknowledgedResultKey")
                dispatch.setValue(acknowledgedAt, forKey: "reviewAcknowledgedAt")
                changed = true
            }
            guard changed else { return false }
            try context.save()
            return true
        }
        if changed { await postDidChange() }
        return try await fetchWorkItem(id: id)
    }

    /// Acknowledge exactly one immutable run's currently visible result. An
    /// out-of-order reply on another run therefore remains in Review, and a new
    /// attempt/result identity on this run re-arms it automatically.
    @discardableResult
    func acknowledgeWorkDispatchReview(
        workItemID: UUID,
        dispatchID: UUID,
        expectedResultKey: String,
        at acknowledgedAt: Date = Date()
    ) async throws -> WorkItemRecord? {
        try await ensureLoaded()
        let context = newWriteContext()
        let changed = try await context.perform { [context] in
            guard try Self.workItemRow(id: workItemID, in: context) != nil else {
                throw WorkboardStoreError.itemNotFound
            }
            guard let dispatch = try Self.workDispatchRow(id: dispatchID, in: context),
                  dispatch.value(forKey: "workItemID") as? UUID == workItemID else {
                throw WorkboardStoreError.dispatchNotFound
            }
            let activity = try Self.workDispatchActivity(for: dispatch, in: context)
            guard activity.resultKey == expectedResultKey else {
                throw WorkboardStoreError.staleRevision
            }
            guard dispatch.value(forKey: "reviewAcknowledgedResultKey") as? String != expectedResultKey else {
                return false
            }
            dispatch.setValue(expectedResultKey, forKey: "reviewAcknowledgedResultKey")
            dispatch.setValue(acknowledgedAt, forKey: "reviewAcknowledgedAt")
            try context.save()
            return true
        }
        if changed { await postDidChange() }
        return try await fetchWorkItem(id: workItemID)
    }

    /// Duplicate editable intent and materials only. Runs are history, not a
    /// template, so the new card starts Draft. A local-only material unavailable
    /// on this device remains explicitly unavailable rather than disappearing.
    func duplicateWorkItem(id: UUID, at createdAt: Date = Date()) async throws -> WorkItemRecord {
        guard let source = try await fetchWorkItem(id: id) else {
            throw WorkboardStoreError.itemNotFound
        }
        var duplicatedContent = source.content
        duplicatedContent.isPinned = false
        let duplicate = try await createWorkItem(
            WorkItemDraft(content: duplicatedContent, createdAt: createdAt)
        )

        do {
            for material in source.materials {
                let payload = try await loadWorkMaterialPayload(id: material.id)
                if material.storageMode == .syncedPayload, payload == nil {
                    throw WorkboardStoreError.materialPayloadUnavailable
                }
                if material.availability == .availableLocally, payload == nil {
                    throw WorkboardStoreError.materialPayloadUnavailable
                }
                let draft = WorkMaterialDraft(
                    kind: material.kind,
                    title: material.title,
                    caption: material.caption,
                    textContent: material.textContent,
                    urlString: material.urlString,
                    filename: material.filename,
                    mimeType: material.mimeType,
                    payload: payload,
                    thumbnailData: material.thumbnailData,
                    width: material.width,
                    height: material.height,
                    byteSize: material.byteSize,
                    sequence: material.sequence,
                    storageMode: material.storageMode,
                    sourceDevice: material.sourceDevice,
                    createdAt: createdAt
                )
                _ = try await addWorkMaterial(draft, to: duplicate.id)
            }
        } catch {
            // The duplicate has never escaped this method. Remove the partial
            // card rather than returning a copy that silently dropped material.
            try? await deleteWorkItem(id: duplicate.id)
            throw error
        }
        guard let result = try await fetchWorkItem(id: duplicate.id) else {
            throw WorkboardStoreError.itemNotFound
        }
        return result
    }

    /// Remove the card, its materials, and its immutable dispatch ledger. Linked
    /// conversations/messages are deliberately untouched and remain in Chat.
    func deleteWorkItem(id: UUID) async throws {
        try await ensureLoaded()
        let context = newWriteContext()
        let removed = try await context.perform { [context] () -> (Bool, [String]) in
            var changed = false
            var vaultKeys: [String] = []
            for entity in ["WorkMaterial", "WorkDispatch"] {
                let request = NSFetchRequest<NSManagedObject>(entityName: entity)
                request.predicate = NSPredicate(format: "workItemID == %@", id as CVarArg)
                for row in try context.fetch(request) {
                    if entity == "WorkMaterial",
                       let key = row.value(forKey: "localVaultKey") as? String {
                        vaultKeys.append(key)
                    }
                    context.delete(row)
                    changed = true
                }
            }
            let itemRequest = NSFetchRequest<NSManagedObject>(entityName: "WorkItem")
            itemRequest.predicate = NSPredicate(format: "id == %@", id as CVarArg)
            for row in try context.fetch(itemRequest) {
                context.delete(row)
                changed = true
            }
            if changed { try context.save() }
            return (changed, vaultKeys)
        }
        for key in removed.1 { try? await workAssetVault.remove(key) }
        if removed.0 { await postDidChange() }
    }

    // MARK: - Materials

    /// Publish a provisional Work item together with its first material in ONE
    /// Core Data save. Binary bytes are fully staged before the write context
    /// inserts either row, so neither row becomes locally visible or eligible
    /// for CloudKit export before both have committed. The two remain separate
    /// CloudKit records and may transiently import in either order on a peer;
    /// this boundary intentionally claims local transaction atomicity only.
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
        while workInitialMaterialClaims.contains(itemDraft.id) {
            try await Task.sleep(for: .milliseconds(40))
        }
        workInitialMaterialClaims.insert(itemDraft.id)
        defer { workInitialMaterialClaims.remove(itemDraft.id) }

        try await ensureLoaded()

        let preparedDraft: WorkMaterialDraft
        let storageMode: WorkMaterialStorageMode
        let byteSize: Int64
        var stagedVaultKey: String?

        if let sourceFileURL {
            let reportedSize = sourceFileByteSize ?? draft.byteSize ?? -1
            if WorkAssetVault.shouldMirror(byteCount: reportedSize) {
                let scoped = sourceFileURL.startAccessingSecurityScopedResource()
                defer { if scoped { sourceFileURL.stopAccessingSecurityScopedResource() } }
                let payload = try Data(contentsOf: sourceFileURL, options: [.mappedIfSafe])
                byteSize = Int64(payload.count)
                storageMode = .syncedPayload
                preparedDraft = WorkMaterialDraft(
                    id: draft.id,
                    kind: draft.kind,
                    title: draft.title,
                    caption: draft.caption,
                    textContent: draft.textContent,
                    urlString: draft.urlString,
                    filename: draft.filename,
                    mimeType: draft.mimeType,
                    payload: payload,
                    thumbnailData: draft.thumbnailData,
                    width: draft.width,
                    height: draft.height,
                    byteSize: byteSize,
                    sequence: draft.sequence,
                    storageMode: .syncedPayload,
                    sourceDevice: draft.sourceDevice,
                    createdAt: draft.createdAt
                )
                onProgress(1)
            } else {
                let storedFile = try await workAssetVault.storeFileStreaming(
                    at: sourceFileURL,
                    id: UUID(),
                    suggestedExtension: draft.filename.map { ($0 as NSString).pathExtension },
                    expectedByteCount: reportedSize,
                    onProgress: onProgress
                )
                stagedVaultKey = storedFile.key
                byteSize = storedFile.byteCount
                storageMode = .localVault
                preparedDraft = draft
            }
        } else {
            byteSize = draft.byteSize ?? Int64(draft.payload?.count ?? 0)
            if draft.payload == nil {
                storageMode = draft.storageMode
            } else if draft.storageMode == .localVault
                        || !WorkAssetVault.shouldMirror(byteCount: byteSize) {
                storageMode = .localVault
            } else {
                storageMode = .syncedPayload
            }
            preparedDraft = draft
            if storageMode == .localVault, let payload = draft.payload {
                stagedVaultKey = try await workAssetVault.store(
                    payload,
                    id: UUID(),
                    suggestedExtension: draft.filename.map { ($0 as NSString).pathExtension }
                )
            }
            onProgress(1)
        }

        // Freeze the staged key before crossing into Core Data's sendable
        // context closure; it is mutable only during byte preparation above.
        let localVaultKey = stagedVaultKey
        let context = newWriteContext()
        do {
            try await context.perform { [context] in
                guard try Self.workItemRow(id: itemDraft.id, in: context) == nil else {
                    throw WorkboardStoreError.staleRevision
                }
                if let captureID = itemDraft.captureEnvelopeID,
                   try Self.workItemRow(captureEnvelopeID: captureID, in: context) != nil {
                    throw WorkboardStoreError.identifierCollision
                }
                guard try Self.workMaterialRow(id: preparedDraft.id, in: context) == nil else {
                    throw WorkboardStoreError.identifierCollision
                }

                let now = Date()
                let owner = NSEntityDescription.insertNewObject(
                    forEntityName: "WorkItem",
                    into: context
                )
                owner.setValue(itemDraft.id, forKey: "id")
                owner.setValue(itemDraft.captureEnvelopeID, forKey: "captureEnvelopeID")
                Self.apply(itemDraft.content, to: owner)
                owner.setValue(itemDraft.createdAt, forKey: "createdAt")
                owner.setValue(now, forKey: "updatedAt")

                let material = NSEntityDescription.insertNewObject(
                    forEntityName: "WorkMaterial",
                    into: context
                )
                Self.apply(
                    preparedDraft,
                    workItemID: itemDraft.id,
                    storageMode: storageMode,
                    byteSize: byteSize,
                    localVaultKey: localVaultKey,
                    updatedAt: now,
                    to: material
                )
                try context.save()
            }
        } catch {
            if let stagedVaultKey { try? await workAssetVault.remove(stagedVaultKey) }
            throw error
        }

        if let stagedVaultKey { await workAssetVault.markReferenced(stagedVaultKey) }
        await postDidChange()
        guard let record = try await fetchWorkItem(id: itemDraft.id) else {
            throw WorkboardStoreError.itemNotFound
        }
        return record
    }

    /// Add a material and update the parent card in one Core Data save. Large
    /// payloads automatically move to the explicit device-local vault; their
    /// row syncs metadata + availability instead of over-promising a CloudKit asset.
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
        let storageMode: WorkMaterialStorageMode
        if draft.payload == nil {
            storageMode = draft.storageMode
        } else if draft.storageMode == .localVault || !WorkAssetVault.shouldMirror(byteCount: byteSize) {
            storageMode = .localVault
        } else {
            storageMode = .syncedPayload
        }

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
        if WorkAssetVault.shouldMirror(byteCount: byteSize) {
            let scoped = sourceURL.startAccessingSecurityScopedResource()
            defer { if scoped { sourceURL.stopAccessingSecurityScopedResource() } }
            let payload = try Data(contentsOf: sourceURL, options: [.mappedIfSafe])
            let mirroredDraft = WorkMaterialDraft(
                id: draft.id,
                kind: draft.kind,
                title: draft.title,
                caption: draft.caption,
                textContent: draft.textContent,
                urlString: draft.urlString,
                filename: draft.filename,
                mimeType: draft.mimeType,
                payload: payload,
                thumbnailData: draft.thumbnailData,
                width: draft.width,
                height: draft.height,
                byteSize: byteSize,
                sequence: draft.sequence,
                sourceDevice: draft.sourceDevice,
                createdAt: draft.createdAt
            )
            onProgress(1)
            return try await addWorkMaterial(
                mirroredDraft,
                to: workItemID,
                expectedOwnerRevision: expectedOwnerRevision
            )
        }

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

    /// Metadata-only edit; payload bytes and storage provenance cannot be lost by
    /// an autosave. `replaceWorkMaterialPayload` owns that explicit transition.
    func updateWorkMaterial(id: UUID, edit: WorkMaterialEdit) async throws -> WorkMaterialRecord? {
        try await ensureLoaded()
        let context = newWriteContext()
        let outcome = try await context.perform { [context] () -> (Bool, UUID?) in
            guard let row = try Self.workMaterialRow(id: id, in: context) else {
                return (false, nil)
            }
            let storageMode = WorkMaterialStorageMode(
                stored: row.value(forKey: "storageMode") as? String
            )
            var persistedEdit = edit
            persistedEdit.textContent = Self.workboardSyncedTextContent(
                kind: edit.kind,
                storageMode: storageMode,
                proposed: edit.textContent
            )
            let existing = Self.materialEdit(of: row)
            guard existing != persistedEdit else {
                return (false, row.value(forKey: "workItemID") as? UUID)
            }
            row.setValue(persistedEdit.kind.rawValue, forKey: "kind")
            row.setValue(persistedEdit.title, forKey: "title")
            row.setValue(persistedEdit.caption, forKey: "caption")
            row.setValue(persistedEdit.textContent, forKey: "textContent")
            row.setValue(persistedEdit.urlString, forKey: "urlString")
            row.setValue(persistedEdit.filename, forKey: "filename")
            row.setValue(persistedEdit.mimeType, forKey: "mimeType")
            row.setValue(
                storageMode == .syncedPayload ? persistedEdit.thumbnailData : nil,
                forKey: "thumbnailData"
            )
            row.setValue(persistedEdit.width.map { NSNumber(value: Int32(clamping: $0)) }, forKey: "width")
            row.setValue(persistedEdit.height.map { NSNumber(value: Int32(clamping: $0)) }, forKey: "height")
            row.setValue(NSNumber(value: Int32(clamping: persistedEdit.sequence)), forKey: "sequence")
            let now = Date()
            row.setValue(now, forKey: "updatedAt")
            let ownerID = row.value(forKey: "workItemID") as? UUID
            if let ownerID, let item = try Self.workItemRow(id: ownerID, in: context) {
                item.setValue(now, forKey: "updatedAt")
            }
            try context.save()
            return (true, ownerID)
        }
        if outcome.0 { await postDidChange() }
        return try await fetchWorkMaterial(id: id)
    }

    /// Replace payload bytes and choose their safe storage lane from size. The
    /// new vault file is published before the row points at it; on save failure
    /// it is removed, and the old key is removed only after the save commits.
    func replaceWorkMaterialPayload(
        id: UUID,
        data: Data,
        sourceDevice: String?,
        expectedOwnerRevision: Int64? = nil,
        forceLocal: Bool = false,
        replacementFilename: String? = nil,
        replacementMIMEType: String? = nil,
        replacementTextContent: String? = nil,
        replacementThumbnailData: Data? = nil,
        updatesReplacementMetadata: Bool = false
    ) async throws -> WorkMaterialRecord? {
        try await ensureLoaded()
        guard let existing = try await fetchWorkMaterial(id: id) else { return nil }
        let byteSize = Int64(data.count)
        let storageMode: WorkMaterialStorageMode =
            (forceLocal || !WorkAssetVault.shouldMirror(byteCount: byteSize))
            ? .localVault : .syncedPayload
        var newKey: String?
        if storageMode == .localVault {
            newKey = try await workAssetVault.store(
                data,
                id: UUID(),
                suggestedExtension: existing.filename.map { ($0 as NSString).pathExtension }
            )
        }

        let context = newWriteContext()
        let oldKey: String?
        do {
            oldKey = try await context.perform { [context] in
                guard let row = try Self.workMaterialRow(id: id, in: context) else {
                    throw WorkboardStoreError.materialNotFound
                }
                if let expectedOwnerRevision {
                    guard let ownerID = row.value(forKey: "workItemID") as? UUID,
                          let owner = try Self.workItemRow(id: ownerID, in: context),
                          let ownerUpdatedAt = owner.value(forKey: "updatedAt") as? Date,
                          Self.workRevision(for: ownerUpdatedAt) == expectedOwnerRevision else {
                        throw WorkboardStoreError.staleRevision
                    }
                }
                let oldKey = row.value(forKey: "localVaultKey") as? String
                row.setValue(storageMode == .syncedPayload ? data : nil, forKey: "payload")
                row.setValue(storageMode.rawValue, forKey: "storageMode")
                row.setValue(newKey, forKey: "localVaultKey")
                row.setValue(sourceDevice, forKey: "sourceDevice")
                row.setValue(NSNumber(value: byteSize), forKey: "byteSize")
                if updatesReplacementMetadata {
                    if let replacementFilename {
                        row.setValue(replacementFilename, forKey: "filename")
                    }
                    if let replacementMIMEType {
                        row.setValue(replacementMIMEType, forKey: "mimeType")
                    }
                    let kind = WorkMaterialKind(stored: row.value(forKey: "kind") as? String)
                    row.setValue(
                        Self.workboardSyncedTextContent(
                            kind: kind,
                            storageMode: storageMode,
                            proposed: replacementTextContent
                        ),
                        forKey: "textContent"
                    )
                    row.setValue(
                        storageMode == .syncedPayload ? replacementThumbnailData : nil,
                        forKey: "thumbnailData"
                    )
                }
                let now = Date()
                row.setValue(now, forKey: "updatedAt")
                if let ownerID = row.value(forKey: "workItemID") as? UUID,
                   let owner = try Self.workItemRow(id: ownerID, in: context) {
                    owner.setValue(now, forKey: "updatedAt")
                }
                try context.save()
                return oldKey
            }
        } catch {
            if let newKey { try? await workAssetVault.remove(newKey) }
            throw error
        }
        if let newKey { await workAssetVault.markReferenced(newKey) }
        if let oldKey, oldKey != newKey { try? await workAssetVault.remove(oldKey) }
        await postDidChange()
        return try await fetchWorkMaterial(id: id)
    }

    /// Reattach a file in place without changing material identity, order,
    /// caption or title. Large files stream to a new vault key; the old payload
    /// remains authoritative until the owner-revision CAS commits.
    func replaceWorkMaterialPayloadFile(
        id: UUID,
        from sourceURL: URL,
        byteSize: Int64,
        filename: String?,
        mimeType: String?,
        textContent: String?,
        thumbnailData: Data?,
        sourceDevice: String?,
        expectedOwnerRevision: Int64,
        onProgress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> WorkMaterialRecord? {
        if WorkAssetVault.shouldMirror(byteCount: byteSize) {
            let scoped = sourceURL.startAccessingSecurityScopedResource()
            defer { if scoped { sourceURL.stopAccessingSecurityScopedResource() } }
            let data = try Data(contentsOf: sourceURL, options: [.mappedIfSafe])
            onProgress(1)
            return try await replaceWorkMaterialPayload(
                id: id,
                data: data,
                sourceDevice: sourceDevice,
                expectedOwnerRevision: expectedOwnerRevision,
                replacementFilename: filename,
                replacementMIMEType: mimeType,
                replacementTextContent: textContent,
                replacementThumbnailData: thumbnailData,
                updatesReplacementMetadata: true
            )
        }

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

    func reorderWorkMaterials(workItemID: UUID, orderedIDs: [UUID]) async throws {
        try await ensureLoaded()
        let context = newWriteContext()
        let changed = try await context.perform { [context] in
            let request = NSFetchRequest<NSManagedObject>(entityName: "WorkMaterial")
            request.predicate = NSPredicate(format: "workItemID == %@", workItemID as CVarArg)
            let rows = try context.fetch(request)
            var rowsByID: [UUID: [NSManagedObject]] = [:]
            for row in rows {
                guard let id = row.value(forKey: "id") as? UUID else { continue }
                rowsByID[id, default: []].append(row)
            }
            var changed = false
            for (index, id) in orderedIDs.enumerated() {
                guard let matchingRows = rowsByID[id] else { continue }
                let next = Int32(clamping: index)
                for row in matchingRows {
                    let current = (row.value(forKey: "sequence") as? NSNumber)?.int32Value
                    guard current != next else { continue }
                    row.setValue(NSNumber(value: next), forKey: "sequence")
                    row.setValue(Date(), forKey: "updatedAt")
                    changed = true
                }
            }
            guard changed else { return false }
            if let item = try Self.workItemRow(id: workItemID, in: context) {
                item.setValue(Date(), forKey: "updatedAt")
            }
            try context.save()
            return true
        }
        if changed { await postDidChange() }
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

    /// Capture the exact brief and every selected payload before dispatch does
    /// any external work. Owner/material revisions are checked in the same Core
    /// Data read transaction that copies synced bytes. Local-vault files are then
    /// snapshotted under the vault actor; replacement can only win before that
    /// copy (causing a safe failure) or after it (leaving the old snapshot intact).
    func captureWorkDispatch(
        workItemID: UUID,
        expectedRevision: Int64,
        dispatchID: UUID,
        includedMaterialIDs: [UUID],
        expectedMaterialVersions: [WorkboardMaterialVersion]
    ) async throws -> CapturedWorkDispatch {
        try await ensureLoaded()
        let selectedIDs = Set(includedMaterialIDs)
        let versionIDs = Set(expectedMaterialVersions.map(\.id))
        guard selectedIDs.count == includedMaterialIDs.count,
              versionIDs.count == expectedMaterialVersions.count,
              selectedIDs == versionIDs else {
            throw WorkboardStoreError.staleRevision
        }
        let expectedVersions = Dictionary(uniqueKeysWithValues: expectedMaterialVersions.map {
            ($0.id, $0.revision)
        })

        let context = newReadContext()
        let stored = try await context.perform { [context] () -> StoredDispatchCapture in
            guard let itemRow = try Self.workItemRow(id: workItemID, in: context) else {
                throw WorkboardStoreError.itemNotFound
            }
            guard let updatedAt = itemRow.value(forKey: "updatedAt") as? Date,
                  Self.workRevision(for: updatedAt) == expectedRevision else {
                throw WorkboardStoreError.staleRevision
            }
            guard try Self.workDispatchRow(id: dispatchID, in: context) == nil else {
                throw WorkboardStoreError.identifierCollision
            }

            let rows: [NSManagedObject]
            if selectedIDs.isEmpty {
                rows = []
            } else {
                let request = NSFetchRequest<NSManagedObject>(entityName: "WorkMaterial")
                request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
                    NSPredicate(format: "workItemID == %@", workItemID as CVarArg),
                    NSPredicate(format: "id IN %@", Array(selectedIDs)),
                ])
                rows = try context.fetch(request)
            }
            var rowsByID: [UUID: [NSManagedObject]] = [:]
            for row in rows {
                guard let id = row.value(forKey: "id") as? UUID else {
                    throw WorkboardStoreError.staleRevision
                }
                rowsByID[id, default: []].append(row)
            }
            guard Set(rowsByID.keys) == selectedIDs else {
                throw WorkboardStoreError.staleRevision
            }
            let captured = try selectedIDs.map { id -> StoredDispatchMaterial in
                guard let expectedRevision = expectedVersions[id],
                      let row = rowsByID[id]?.first(where: { candidate in
                          guard let updatedAt = candidate.value(forKey: "updatedAt") as? Date else {
                              return false
                          }
                          return Self.workRevision(for: updatedAt) == expectedRevision
                      }) else {
                    throw WorkboardStoreError.staleRevision
                }
                return StoredDispatchMaterial(row)
            }
            return StoredDispatchCapture(
                item: StoredWorkItem(itemRow),
                materials: captured.sorted {
                    if $0.material.sequence != $1.material.sequence {
                        return $0.material.sequence < $1.material.sequence
                    }
                    return $0.material.id.uuidString < $1.material.id.uuidString
                }
            )
        }

        var results: [CapturedWorkMaterial] = []
        var temporaryURLs: [URL] = []
        do {
            results.reserveCapacity(stored.materials.count)
            for captured in stored.materials {
                let material = captured.material
                let record: WorkMaterialRecord
                let localFileURL: URL?
                switch material.storageMode {
                case .metadataOnly:
                    guard material.kind == .note || material.kind == .link || material.kind == .transcript else {
                        throw WorkboardStoreError.materialPayloadUnavailable
                    }
                    record = material.record(availableLocalKeys: [])
                    localFileURL = nil
                case .syncedPayload:
                    guard captured.payload != nil else {
                        throw WorkboardStoreError.materialPayloadUnavailable
                    }
                    record = material.record(availableLocalKeys: [])
                    localFileURL = nil
                case .localVault:
                    guard let key = material.localVaultKey else {
                        throw WorkboardStoreError.materialPayloadUnavailable
                    }
                    let url = try await workAssetVault.snapshotFile(for: key)
                    temporaryURLs.append(url)
                    record = material.record(availableLocalKeys: [key])
                    localFileURL = url
                }
                results.append(CapturedWorkMaterial(
                    record: record,
                    payload: captured.payload,
                    localFileURL: localFileURL
                ))
            }
        } catch {
            for url in temporaryURLs { try? FileManager.default.removeItem(at: url) }
            throw error
        }
        return CapturedWorkDispatch(
            workItemID: stored.item.id,
            content: stored.item.content,
            updatedAt: stored.item.updatedAt,
            materials: results
        )
    }

    // MARK: - Atomic dispatch preparation

    /// Atomically freeze the exact approved brief, create its gateway-bound
    /// conversation, append the initial `sending` user turn + attachment copies,
    /// and reopen/point the work item. The returned `created` flag is the crash /
    /// retry guard: a repeated caller-owned dispatch id returns existing rows and
    /// must not trigger transport again. This method itself performs NO network I/O.
    func prepareWorkDispatch(_ preparation: WorkDispatchPreparation) async throws -> PreparedWorkDispatch {
        let snapshotData: Data
        do {
            snapshotData = try Self.workSnapshotEncoder().encode(preparation.briefSnapshot)
        } catch {
            throw WorkboardStoreError.snapshotEncodingFailed
        }

        try await ensureLoaded()
        guard let pretransactionItem = try await fetchWorkItem(id: preparation.workItemID) else {
            throw WorkboardStoreError.itemNotFound
        }
        let context = newWriteContext()
        let transaction = try await context.perform { [context] () -> (Bool, ConversationRecord, MessageRecord, Date) in
            if let existingDispatch = try Self.workDispatchRow(id: preparation.dispatchID, in: context) {
                guard existingDispatch.value(forKey: "workItemID") as? UUID == preparation.workItemID,
                      existingDispatch.value(forKey: "conversationID") as? UUID == preparation.conversationID,
                      existingDispatch.value(forKey: "userMessageID") as? UUID == preparation.userMessageID,
                      existingDispatch.value(forKey: "gatewayRef") as? String == preparation.gatewayRef,
                      existingDispatch.value(forKey: "gatewayNameSnapshot") as? String == preparation.gatewayName,
                      existingDispatch.value(forKey: "titleSnapshot") as? String == preparation.briefSnapshot.title,
                      existingDispatch.value(forKey: "promptSnapshot") as? String == preparation.canonicalPrompt,
                      existingDispatch.value(forKey: "briefSnapshotData") as? Data == snapshotData,
                      existingDispatch.value(forKey: "deliveryAttemptID") as? UUID == preparation.deliveryAttemptID,
                      let conversation = try Self.conversationRow(id: preparation.conversationID, in: context),
                      let message = try Self.messageRow(id: preparation.userMessageID, in: context),
                      conversation.value(forKey: "backend") as? String == preparation.gatewayRef,
                      message.value(forKey: "role") as? String == "user",
                      message.value(forKey: "text") as? String == preparation.canonicalPrompt,
                      message.value(forKey: "sourceDevice") as? String == preparation.sourceDevice,
                      message.value(forKey: "fileTransferLaneID") as? String == preparation.fileTransferLaneID,
                      Self.workAttachments(on: message, match: preparation.attachments) else {
                    throw WorkboardStoreError.identifierCollision
                }
                let createdAt = existingDispatch.value(forKey: "createdAt") as? Date
                    ?? preparation.preparedAt
                return (
                    false,
                    ConversationRecord(managedObject: conversation),
                    MessageRecord(managedObject: message),
                    createdAt
                )
            }

            guard let item = try Self.workItemRow(id: preparation.workItemID, in: context) else {
                throw WorkboardStoreError.itemNotFound
            }
            guard let currentUpdatedAt = item.value(forKey: "updatedAt") as? Date,
                  Self.workRevision(for: currentUpdatedAt) == preparation.expectedWorkItemRevision else {
                throw WorkboardStoreError.staleRevision
            }

            let snapshotMaterialIDs = Set(preparation.briefSnapshot.materials.map(\.id))
            let expectedMaterialIDs = Set(preparation.expectedMaterialVersions.map(\.id))
            guard snapshotMaterialIDs.count == preparation.briefSnapshot.materials.count,
                  expectedMaterialIDs.count == preparation.expectedMaterialVersions.count,
                  snapshotMaterialIDs == expectedMaterialIDs else {
                throw WorkboardStoreError.staleRevision
            }
            if !expectedMaterialIDs.isEmpty {
                let expectedVersions = Dictionary(uniqueKeysWithValues:
                    preparation.expectedMaterialVersions.map { ($0.id, $0.revision) }
                )
                let materialRequest = NSFetchRequest<NSManagedObject>(entityName: "WorkMaterial")
                materialRequest.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
                    NSPredicate(format: "workItemID == %@", preparation.workItemID as CVarArg),
                    NSPredicate(format: "id IN %@", Array(expectedMaterialIDs)),
                ])
                let materialRows = try context.fetch(materialRequest)
                var rowsByID: [UUID: [NSManagedObject]] = [:]
                for row in materialRows {
                    guard let id = row.value(forKey: "id") as? UUID else {
                        throw WorkboardStoreError.staleRevision
                    }
                    rowsByID[id, default: []].append(row)
                }
                guard Set(rowsByID.keys) == expectedMaterialIDs,
                      expectedMaterialIDs.allSatisfy({ id in
                          guard let expectedRevision = expectedVersions[id] else { return false }
                          return rowsByID[id]?.contains(where: { row in
                              guard let updatedAt = row.value(forKey: "updatedAt") as? Date else {
                                  return false
                              }
                              return Self.workRevision(for: updatedAt) == expectedRevision
                          }) == true
                      }) else {
                    throw WorkboardStoreError.staleRevision
                }
            }
            guard try Self.conversationRow(id: preparation.conversationID, in: context) == nil,
                  try Self.messageRow(id: preparation.userMessageID, in: context) == nil else {
                throw WorkboardStoreError.identifierCollision
            }

            let conversationCreatedAt = TailProjection.canonical(preparation.preparedAt)
            let conversation = NSEntityDescription.insertNewObject(
                forEntityName: "Conversation", into: context
            )
            conversation.setValue(preparation.conversationID, forKey: "id")
            conversation.setValue(nil, forKey: "title")
            conversation.setValue(conversationCreatedAt, forKey: "createdAt")
            conversation.setValue(conversationCreatedAt, forKey: "lastActivityAt")
            conversation.setValue(UUID().uuidString, forKey: "sessionID")
            conversation.setValue(preparation.gatewayRef, forKey: "backend")
            conversation.setValue(nil, forKey: "tailProjection")
            conversation.setValue(Self.snippet(from: preparation.canonicalPrompt), forKey: "titleSnippet")

            let messageCreatedAt = Self.appendStamp(
                proposed: preparation.preparedAt,
                appendingTo: conversation
            )
            let message = NSEntityDescription.insertNewObject(forEntityName: "Message", into: context)
            message.setValue(preparation.userMessageID, forKey: "id")
            message.setValue("user", forKey: "role")
            message.setValue(preparation.canonicalPrompt, forKey: "text")
            message.setValue(messageCreatedAt, forKey: "createdAt")
            message.setValue(preparation.sourceDevice, forKey: "sourceDevice")
            // Prepared, not dispatched. The existing retry pipeline owns the
            // failed→sending compare-and-set and therefore the one network
            // attempt; this transaction must not pre-claim it as in flight.
            message.setValue("failed", forKey: "status")
            message.setValue(preparation.deliveryAttemptID, forKey: "deliveryAttemptID")
            message.setValue(preparation.fileTransferLaneID, forKey: "fileTransferLaneID")
            message.setValue(conversation, forKey: "conversation")
            for draft in preparation.attachments {
                Self.insertAttachment(draft, on: message, into: context, at: messageCreatedAt)
            }
            conversation.setValue(messageCreatedAt, forKey: "lastActivityAt")
            conversation.setValue(
                TailProjection.encoded(
                    messageID: preparation.userMessageID,
                    createdAt: messageCreatedAt,
                    role: .user
                ),
                forKey: "tailProjection"
            )

            let dispatch = NSEntityDescription.insertNewObject(
                forEntityName: "WorkDispatch", into: context
            )
            dispatch.setValue(preparation.dispatchID, forKey: "id")
            dispatch.setValue(preparation.workItemID, forKey: "workItemID")
            dispatch.setValue(preparation.conversationID, forKey: "conversationID")
            dispatch.setValue(preparation.userMessageID, forKey: "userMessageID")
            dispatch.setValue(preparation.deliveryAttemptID, forKey: "deliveryAttemptID")
            dispatch.setValue(preparation.gatewayRef, forKey: "gatewayRef")
            dispatch.setValue(preparation.gatewayName, forKey: "gatewayNameSnapshot")
            dispatch.setValue(preparation.briefSnapshot.title, forKey: "titleSnapshot")
            dispatch.setValue(preparation.canonicalPrompt, forKey: "promptSnapshot")
            dispatch.setValue(snapshotData, forKey: "briefSnapshotData")
            dispatch.setValue(messageCreatedAt, forKey: "createdAt")
            dispatch.setValue(nil, forKey: "dispatchedAt")

            item.setValue(preparation.dispatchID, forKey: "currentDispatchID")
            item.setValue(nil, forKey: "completedAt")
            let nextUpdatedAt = Date(timeIntervalSinceReferenceDate: max(
                messageCreatedAt.timeIntervalSinceReferenceDate,
                currentUpdatedAt.timeIntervalSinceReferenceDate.nextUp
            ))
            item.setValue(nextUpdatedAt, forKey: "updatedAt")

            try context.save()
            return (
                true,
                ConversationRecord(managedObject: conversation),
                MessageRecord(managedObject: message),
                messageCreatedAt
            )
        }

        if transaction.0 { await postDidChange() }
        let fallbackDispatch = WorkDispatchRecord(
            id: preparation.dispatchID,
            workItemID: preparation.workItemID,
            conversationID: preparation.conversationID,
            userMessageID: preparation.userMessageID,
            gatewayRef: preparation.gatewayRef,
            gatewayNameSnapshot: preparation.gatewayName,
            titleSnapshot: preparation.briefSnapshot.title,
            promptSnapshot: preparation.canonicalPrompt,
            briefSnapshot: preparation.briefSnapshot,
            createdAt: transaction.3,
            dispatchedAt: nil,
            reviewAcknowledgedAt: nil,
            reviewAcknowledgedResultKey: nil,
            conversationRemovedAt: nil,
            activity: .prepared
        )
        let fallbackUpdatedAt = Date(timeIntervalSinceReferenceDate: max(
            transaction.3.timeIntervalSinceReferenceDate,
            pretransactionItem.updatedAt.timeIntervalSinceReferenceDate.nextUp
        ))
        let fallbackDispatches = pretransactionItem.dispatches.filter {
            $0.id != preparation.dispatchID
        } + [fallbackDispatch]
        let fallbackItem = WorkItemRecord(
            id: pretransactionItem.id,
            content: pretransactionItem.content,
            createdAt: pretransactionItem.createdAt,
            updatedAt: fallbackUpdatedAt,
            boardOrder: pretransactionItem.boardOrder,
            completedAt: nil,
            captureEnvelopeID: pretransactionItem.captureEnvelopeID,
            currentDispatchID: preparation.dispatchID,
            materials: pretransactionItem.materials,
            dispatches: fallbackDispatches,
            state: WorkItemStateResolver.resolve(
                completedAt: nil,
                dispatches: fallbackDispatches.map(\.stateFacts)
            )
        )
        let item = (try? await fetchWorkItem(id: preparation.workItemID)) ?? fallbackItem
        let dispatch = item.dispatches.first(where: { $0.id == preparation.dispatchID })
            ?? fallbackDispatch
        return PreparedWorkDispatch(
            created: transaction.0,
            workItem: item,
            dispatch: dispatch,
            conversation: transaction.1,
            message: transaction.2
        )
    }

    /// Cross the persisted dispatch boundary immediately before invoking the
    /// existing retry pipeline. Preparing stays Draft; once this stamp lands,
    /// retry's failed→sending CAS makes the card Waiting and sent/failed makes it
    /// Review. Repeated calls keep the first stamp so history cannot drift.
    @discardableResult
    func markWorkDispatchStarted(id: UUID, at startedAt: Date = Date()) async throws -> Bool {
        try await ensureLoaded()
        let context = newWriteContext()
        let changed = try await context.perform { [context] in
            guard let dispatch = try Self.workDispatchRow(id: id, in: context) else {
                throw WorkboardStoreError.dispatchNotFound
            }
            guard dispatch.value(forKey: "dispatchedAt") as? Date == nil else { return false }
            dispatch.setValue(startedAt, forKey: "dispatchedAt")
            try context.save()
            return true
        }
        if changed { await postDidChange() }
        return changed
    }

    // MARK: - Fetch + projection

    private func fetchWorkMaterial(id: UUID) async throws -> WorkMaterialRecord? {
        let records = try await fetchWorkItems(itemID: nil, captureEnvelopeID: nil)
        return records.lazy.flatMap(\.materials).first { $0.id == id }
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
            guard !itemIDs.isEmpty else { return StoredWorkboard(items: [], materials: [], dispatches: [], messages: []) }

            let materialRequest = NSFetchRequest<NSManagedObject>(entityName: "WorkMaterial")
            materialRequest.predicate = NSPredicate(format: "workItemID IN %@", Array(itemIDs))
            materialRequest.sortDescriptors = [
                NSSortDescriptor(key: "sequence", ascending: true),
                NSSortDescriptor(key: "createdAt", ascending: true),
            ]
            let materials = try context.fetch(materialRequest).map(StoredWorkMaterial.init)

            let dispatchRequest = NSFetchRequest<NSManagedObject>(entityName: "WorkDispatch")
            dispatchRequest.predicate = NSPredicate(format: "workItemID IN %@", Array(itemIDs))
            dispatchRequest.sortDescriptors = [NSSortDescriptor(key: "dispatchedAt", ascending: true)]
            let dispatches = try context.fetch(dispatchRequest).map(StoredWorkDispatch.init)

            let userIDs = dispatches.compactMap(\.userMessageID)
            let conversationIDs = dispatches.compactMap(\.conversationID)
            var messages: [StoredWorkMessage] = []
            if !userIDs.isEmpty || !conversationIDs.isEmpty {
                var clauses: [NSPredicate] = []
                if !userIDs.isEmpty {
                    clauses.append(NSPredicate(format: "id IN %@", userIDs))
                }
                if !conversationIDs.isEmpty {
                    clauses.append(NSPredicate(
                        format: "conversation.id IN %@ AND (role == %@ OR role == %@)",
                        conversationIDs, "agent", "user"
                    ))
                }
                let messageRequest = NSFetchRequest<NSManagedObject>(entityName: "Message")
                messageRequest.predicate = NSCompoundPredicate(orPredicateWithSubpredicates: clauses)
                messageRequest.sortDescriptors = [
                    NSSortDescriptor(key: "createdAt", ascending: true),
                    NSSortDescriptor(key: "id", ascending: true),
                ]
                messages = try context.fetch(messageRequest).map(StoredWorkMessage.init)
            }
            return StoredWorkboard(
                items: items,
                materials: materials,
                dispatches: dispatches,
                messages: messages
            )
        }

        var availableLocalKeys: Set<String> = []
        for key in Set(stored.materials.compactMap(\.localVaultKey)) {
            if await workAssetVault.contains(key) { availableLocalKeys.insert(key) }
        }

        let canonicalItems = Self.deduplicatedWorkItems(stored.items)
        let canonicalMaterials = Self.deduplicatedWorkMaterials(stored.materials)
        let materialRecords = canonicalMaterials.map { $0.record(availableLocalKeys: availableLocalKeys) }
        let userMessages = Dictionary(uniqueKeysWithValues: stored.messages.compactMap { message in
            message.role == "user" ? (message.id, message) : nil
        })
        let agentsByConversation = Dictionary(grouping: stored.messages.filter { $0.role == "agent" }) {
            $0.conversationID
        }
        let usersByConversation = Dictionary(grouping: stored.messages.filter { $0.role == "user" }) {
            $0.conversationID
        }

        let dispatchRecords = stored.dispatches.map { dispatch -> WorkDispatchRecord in
            let activity = Self.workDispatchActivity(
                dispatch: dispatch,
                userMessages: userMessages,
                usersByConversation: usersByConversation,
                agentsByConversation: agentsByConversation
            )
            return dispatch.record(activity: activity)
        }
        let materialsByItem = Dictionary(grouping: materialRecords, by: \.workItemID)
        let dispatchesByItem = Dictionary(grouping: dispatchRecords, by: \.workItemID)

        return canonicalItems.map { item in
            let materials = materialsByItem[item.id] ?? []
            let dispatches = dispatchesByItem[item.id] ?? []
            return item.record(materials: materials, dispatches: dispatches)
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

    private static func workMaterialRow(id: UUID, in context: NSManagedObjectContext) throws -> NSManagedObject? {
        let request = NSFetchRequest<NSManagedObject>(entityName: "WorkMaterial")
        request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        request.sortDescriptors = [NSSortDescriptor(key: "updatedAt", ascending: false)]
        request.fetchLimit = 1
        return try context.fetch(request).first
    }

    private static func workDispatchRow(id: UUID, in context: NSManagedObjectContext) throws -> NSManagedObject? {
        let request = NSFetchRequest<NSManagedObject>(entityName: "WorkDispatch")
        request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        request.fetchLimit = 1
        return try context.fetch(request).first
    }

    private static func conversationRow(id: UUID, in context: NSManagedObjectContext) throws -> NSManagedObject? {
        let request = NSFetchRequest<NSManagedObject>(entityName: "Conversation")
        request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        request.fetchLimit = 1
        return try context.fetch(request).first
    }

    private static func messageRow(id: UUID, in context: NSManagedObjectContext) throws -> NSManagedObject? {
        let request = NSFetchRequest<NSManagedObject>(entityName: "Message")
        request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        request.fetchLimit = 1
        return try context.fetch(request).first
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

    private static func apply(_ content: WorkItemContent, to row: NSManagedObject) {
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

    private static func apply(
        _ draft: WorkMaterialDraft,
        workItemID: UUID,
        storageMode: WorkMaterialStorageMode,
        byteSize: Int64,
        localVaultKey: String?,
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
        row.setValue(NSNumber(value: Int32(clamping: draft.sequence)), forKey: "sequence")
        row.setValue(storageMode.rawValue, forKey: "storageMode")
        row.setValue(localVaultKey, forKey: "localVaultKey")
        row.setValue(draft.sourceDevice, forKey: "sourceDevice")
        row.setValue(draft.createdAt, forKey: "createdAt")
        row.setValue(updatedAt, forKey: "updatedAt")
    }

    private static func workRevision(for date: Date) -> Int64 {
        Int64(bitPattern: date.timeIntervalSinceReferenceDate.bitPattern)
    }

    private static func materialEdit(of row: NSManagedObject) -> WorkMaterialEdit {
        let kind = WorkMaterialKind(stored: row.value(forKey: "kind") as? String)
        let storageMode = WorkMaterialStorageMode(
            stored: row.value(forKey: "storageMode") as? String
        )
        return WorkMaterialEdit(
            kind: kind,
            title: row.value(forKey: "title") as? String ?? "",
            caption: row.value(forKey: "caption") as? String ?? "",
            textContent: workboardSyncedTextContent(
                kind: kind,
                storageMode: storageMode,
                proposed: row.value(forKey: "textContent") as? String
            ),
            urlString: row.value(forKey: "urlString") as? String,
            filename: row.value(forKey: "filename") as? String,
            mimeType: row.value(forKey: "mimeType") as? String,
            thumbnailData: row.value(forKey: "thumbnailData") as? Data,
            width: (row.value(forKey: "width") as? NSNumber)?.intValue,
            height: (row.value(forKey: "height") as? NSNumber)?.intValue,
            sequence: (row.value(forKey: "sequence") as? NSNumber)?.intValue ?? 0
        )
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

    /// Exact immutable attachment packet comparison for an idempotent dispatch
    /// hit. Message delivery state may evolve, but the prepared bytes/refs may
    /// never differ under the same dispatch identity.
    private static func workAttachments(
        on message: NSManagedObject,
        match drafts: [AttachmentDraft]
    ) -> Bool {
        let rows = ((message.value(forKey: "attachments") as? Set<NSManagedObject>) ?? [])
            .sorted {
                ((($0.value(forKey: "sequence") as? NSNumber)?.intValue) ?? 0)
                    < ((($1.value(forKey: "sequence") as? NSNumber)?.intValue) ?? 0)
            }
        let expected = drafts.sorted { $0.sequence < $1.sequence }
        guard rows.count == expected.count else { return false }
        for (row, draft) in zip(rows, expected) {
            guard row.value(forKey: "mimeType") as? String == draft.mimeType,
                  row.value(forKey: "filename") as? String == draft.filename,
                  row.value(forKey: "data") as? Data == draft.data,
                  row.value(forKey: "thumbnailData") as? Data == draft.thumbnailData,
                  ((row.value(forKey: "width") as? NSNumber)?.intValue ?? 0) == draft.width,
                  ((row.value(forKey: "height") as? NSNumber)?.intValue ?? 0) == draft.height,
                  ((row.value(forKey: "byteSize") as? NSNumber)?.intValue ?? 0) == draft.byteSize,
                  ((row.value(forKey: "sequence") as? NSNumber)?.intValue ?? 0) == draft.sequence,
                  ((row.value(forKey: "isServerReference") as? NSNumber)?.boolValue ?? false) == draft.isServerReference,
                  row.value(forKey: "storedKey") as? String == draft.storedKey,
                  row.value(forKey: "previewData") as? Data == draft.previewData,
                  row.value(forKey: "previewKind") as? String == draft.previewKind else {
                return false
            }
        }
        return true
    }

    /// Transaction-local variant used by acknowledgement so result identity and
    /// the acknowledgement cannot race across two contexts.
    private static func workDispatchActivity(
        for dispatch: NSManagedObject,
        in context: NSManagedObjectContext
    ) throws -> WorkDispatchActivity {
        if dispatch.value(forKey: "conversationRemovedAt") as? Date != nil,
           let conversationID = dispatch.value(forKey: "conversationID") as? UUID {
            return .conversationRemoved(conversationID: conversationID)
        }
        guard dispatch.value(forKey: "dispatchedAt") as? Date != nil else { return .prepared }
        let userID = dispatch.value(forKey: "userMessageID") as? UUID
        let conversationID = dispatch.value(forKey: "conversationID") as? UUID
        let user = try userID.flatMap { try messageRow(id: $0, in: context) }
        let after = (user?.value(forKey: "createdAt") as? Date)
            ?? (dispatch.value(forKey: "dispatchedAt") as? Date)
            ?? .distantPast

        // The exact Workboard turn owns this run. A later reply in the same
        // conversation can never turn its durable failure into success.
        if let userID, let user,
           user.value(forKey: "status") as? String == "failed" {
            return .failed(
                messageID: userID,
                attemptID: user.value(forKey: "deliveryAttemptID") as? UUID
            )
        }

        if let conversationID {
            let messageRequest = NSFetchRequest<NSManagedObject>(entityName: "Message")
            messageRequest.predicate = NSPredicate(
                format: "conversation.id == %@ AND (role == %@ OR role == %@)",
                conversationID as CVarArg, "agent", "user"
            )
            messageRequest.sortDescriptors = [
                NSSortDescriptor(key: "createdAt", ascending: true),
                NSSortDescriptor(key: "id", ascending: true),
            ]
            let facts = try context.fetch(messageRequest).compactMap { row -> WorkDispatchMessageFact? in
                guard let id = row.value(forKey: "id") as? UUID,
                      let role = row.value(forKey: "role") as? String,
                      let createdAt = row.value(forKey: "createdAt") as? Date else {
                    return nil
                }
                return WorkDispatchMessageFact(id: id, role: role, createdAt: createdAt)
            }
            if let replyID = WorkDispatchReplyCorrelation.firstReplyID(
                workUserMessageID: userID,
                dispatchedAt: after,
                messages: facts
            ) {
                return .replied(messageID: replyID)
            }
        }

        guard let userID, let user else { return .waiting }
        switch user.value(forKey: "status") as? String {
        case "sent":
            return .replyPendingSync(userMessageID: userID)
        case "failed":
            // Handled before reply correlation so an unrelated later answer
            // can never override this exact transport outcome.
            return .failed(messageID: userID, attemptID: user.value(forKey: "deliveryAttemptID") as? UUID)
        default:
            return .waiting
        }
    }

    // MARK: - Search

    private static func workSearchTokens(_ query: String) -> [String] {
        normalizedWorkSearch(query)
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
    }

    private static func matchesWorkSearch(_ item: WorkItemRecord, tokens: [String]) -> Bool {
        var fields = [
            item.content.title,
            item.content.objective,
            item.content.context,
            item.content.desiredOutcome,
            item.content.constraints,
        ]
        for material in item.materials {
            fields += [
                material.title,
                material.caption,
                material.textContent ?? "",
                material.urlString ?? "",
                material.filename ?? "",
            ]
        }
        for dispatch in item.dispatches {
            fields += [
                dispatch.titleSnapshot,
                dispatch.promptSnapshot,
                dispatch.gatewayNameSnapshot,
            ]
        }
        let haystack = normalizedWorkSearch(fields.joined(separator: "\n"))
        return tokens.allSatisfy(haystack.contains)
    }

    private static func normalizedWorkSearch(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    private static func workSnapshotEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private static func workSnapshotDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }

    // MARK: - Sendable row snapshots

    private nonisolated struct StoredWorkboard: Sendable {
        let items: [StoredWorkItem]
        let materials: [StoredWorkMaterial]
        let dispatches: [StoredWorkDispatch]
        let messages: [StoredWorkMessage]
    }

    private nonisolated struct StoredDispatchCapture: Sendable {
        let item: StoredWorkItem
        let materials: [StoredDispatchMaterial]
    }

    private nonisolated struct StoredDispatchMaterial: Sendable {
        let material: StoredWorkMaterial
        let payload: Data?

        init(_ row: NSManagedObject) {
            material = StoredWorkMaterial(row)
            let mode = WorkMaterialStorageMode(stored: row.value(forKey: "storageMode") as? String)
            payload = mode == .syncedPayload ? row.value(forKey: "payload") as? Data : nil
        }
    }

    private nonisolated struct StoredWorkItem: Sendable {
        let id: UUID
        let content: WorkItemContent
        let createdAt: Date
        let updatedAt: Date
        let boardOrder: Int64?
        let completedAt: Date?
        let captureEnvelopeID: UUID?
        let currentDispatchID: UUID?

        init(_ row: NSManagedObject) {
            id = row.value(forKey: "id") as? UUID ?? UUID()
            content = ConversationStore.content(of: row)
            createdAt = row.value(forKey: "createdAt") as? Date ?? .distantPast
            updatedAt = row.value(forKey: "updatedAt") as? Date ?? createdAt
            boardOrder = (row.value(forKey: "boardOrder") as? NSNumber)?.int64Value
            completedAt = row.value(forKey: "completedAt") as? Date
            captureEnvelopeID = row.value(forKey: "captureEnvelopeID") as? UUID
            currentDispatchID = row.value(forKey: "currentDispatchID") as? UUID
        }

        func record(
            materials: [WorkMaterialRecord],
            dispatches: [WorkDispatchRecord]
        ) -> WorkItemRecord {
            WorkItemRecord(
                id: id,
                content: content,
                createdAt: createdAt,
                updatedAt: updatedAt,
                boardOrder: boardOrder,
                completedAt: completedAt,
                captureEnvelopeID: captureEnvelopeID,
                currentDispatchID: currentDispatchID,
                materials: materials,
                dispatches: dispatches,
                state: WorkItemStateResolver.resolve(
                    completedAt: completedAt,
                    dispatches: dispatches.map(\.stateFacts)
                )
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
                createdAt: createdAt,
                updatedAt: updatedAt
            )
        }
    }

    private nonisolated struct StoredWorkDispatch: Sendable {
        let id: UUID
        let workItemID: UUID
        let conversationID: UUID?
        let userMessageID: UUID?
        let gatewayRef: String
        let gatewayNameSnapshot: String
        let titleSnapshot: String
        let promptSnapshot: String
        let briefSnapshot: WorkBriefSnapshot?
        let createdAt: Date
        let dispatchedAt: Date?
        let reviewAcknowledgedAt: Date?
        let reviewAcknowledgedResultKey: String?
        let conversationRemovedAt: Date?

        init(_ row: NSManagedObject) {
            id = row.value(forKey: "id") as? UUID ?? UUID()
            workItemID = row.value(forKey: "workItemID") as? UUID ?? UUID()
            conversationID = row.value(forKey: "conversationID") as? UUID
            userMessageID = row.value(forKey: "userMessageID") as? UUID
            gatewayRef = row.value(forKey: "gatewayRef") as? String ?? ""
            gatewayNameSnapshot = row.value(forKey: "gatewayNameSnapshot") as? String ?? ""
            titleSnapshot = row.value(forKey: "titleSnapshot") as? String ?? ""
            promptSnapshot = row.value(forKey: "promptSnapshot") as? String ?? ""
            if let data = row.value(forKey: "briefSnapshotData") as? Data {
                briefSnapshot = try? ConversationStore.workSnapshotDecoder()
                    .decode(WorkBriefSnapshot.self, from: data)
            } else {
                briefSnapshot = nil
            }
            createdAt = row.value(forKey: "createdAt") as? Date ?? .distantPast
            dispatchedAt = row.value(forKey: "dispatchedAt") as? Date
            reviewAcknowledgedAt = row.value(forKey: "reviewAcknowledgedAt") as? Date
            reviewAcknowledgedResultKey = row.value(forKey: "reviewAcknowledgedResultKey") as? String
            conversationRemovedAt = row.value(forKey: "conversationRemovedAt") as? Date
        }

        func record(activity: WorkDispatchActivity) -> WorkDispatchRecord {
            WorkDispatchRecord(
                id: id,
                workItemID: workItemID,
                conversationID: conversationID,
                userMessageID: userMessageID,
                gatewayRef: gatewayRef,
                gatewayNameSnapshot: gatewayNameSnapshot,
                titleSnapshot: titleSnapshot,
                promptSnapshot: promptSnapshot,
                briefSnapshot: briefSnapshot,
                createdAt: createdAt,
                dispatchedAt: dispatchedAt,
                reviewAcknowledgedAt: reviewAcknowledgedAt,
                reviewAcknowledgedResultKey: reviewAcknowledgedResultKey,
                conversationRemovedAt: conversationRemovedAt,
                activity: activity
            )
        }
    }

    private nonisolated struct StoredWorkMessage: Sendable {
        let id: UUID
        let conversationID: UUID?
        let role: String
        let status: String?
        let createdAt: Date
        let deliveryAttemptID: UUID?

        init(_ row: NSManagedObject) {
            id = row.value(forKey: "id") as? UUID ?? UUID()
            conversationID = (row.value(forKey: "conversation") as? NSManagedObject)?
                .value(forKey: "id") as? UUID
            role = row.value(forKey: "role") as? String ?? ""
            status = row.value(forKey: "status") as? String
            createdAt = row.value(forKey: "createdAt") as? Date ?? .distantPast
            deliveryAttemptID = row.value(forKey: "deliveryAttemptID") as? UUID
        }
    }

    private static func workDispatchActivity(
        dispatch: StoredWorkDispatch,
        userMessages: [UUID: StoredWorkMessage],
        usersByConversation: [UUID?: [StoredWorkMessage]],
        agentsByConversation: [UUID?: [StoredWorkMessage]]
    ) -> WorkDispatchActivity {
        if dispatch.conversationRemovedAt != nil, let conversationID = dispatch.conversationID {
            return .conversationRemoved(conversationID: conversationID)
        }
        guard dispatch.dispatchedAt != nil else { return .prepared }
        let user = dispatch.userMessageID.flatMap { userMessages[$0] }
        let after = user?.createdAt ?? dispatch.dispatchedAt ?? .distantPast

        if let userID = dispatch.userMessageID, let user, user.status == "failed" {
            return .failed(messageID: userID, attemptID: user.deliveryAttemptID)
        }

        if let conversationID = dispatch.conversationID {
            let messages = (usersByConversation[conversationID] ?? [])
                + (agentsByConversation[conversationID] ?? [])
            let facts = messages.map {
                WorkDispatchMessageFact(id: $0.id, role: $0.role, createdAt: $0.createdAt)
            }
            if let replyID = WorkDispatchReplyCorrelation.firstReplyID(
                workUserMessageID: dispatch.userMessageID,
                dispatchedAt: after,
                messages: facts
            ) {
                return .replied(messageID: replyID)
            }
        }
        guard let userID = dispatch.userMessageID, let user else { return .waiting }
        switch user.status {
        case "sent":
            return .replyPendingSync(userMessageID: userID)
        case "failed":
            return .failed(messageID: userID, attemptID: user.deliveryAttemptID)
        default:
            return .waiting
        }
    }
}
