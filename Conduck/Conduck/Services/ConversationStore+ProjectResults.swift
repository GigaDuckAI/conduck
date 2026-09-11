// SPDX-License-Identifier: Apache-2.0

// Project conversations keep their original gateway and reviewed first turn.
// Result capture reads only persisted assistant attachments, never reply URLs
// or prose, and performs no network requests. Its durable receipt shares the
// material's commit and survives deletion, so imports and launch recovery can
// retry without resurrecting cards or undoing later organization. Remote files
// remain references to their source conversation and original file lane.

import Foundation
import CoreData
import CryptoKit

nonisolated struct WorkDeskResultRecord: Identifiable, Hashable, Sendable {
    var id: UUID { materialID }
    let materialID: UUID
    let projectID: UUID
    let conversationID: UUID
    let messageID: UUID
    let attachmentID: UUID
    let gatewayRef: String
    let fileLaneID: String?
    let createdAt: Date
    var isRemoteReference: Bool = false
}

extension ConversationStore {
    func fetchProjectConversations(projectID: UUID) async throws -> [ConversationRecord] {
        try await fetchConversations(activity: .turnStates).filter { $0.projectID == projectID }
    }

    func fetchWorkDeskResults() async throws -> [UUID: WorkDeskResultRecord] {
        try await ensureLoaded()
        let context = newReadContext()
        return try await context.perform {
            guard context.persistentStoreCoordinator?.managedObjectModel.entitiesByName["WorkDeskResult"] != nil else { return [:] }
            let rows = try context.fetch(NSFetchRequest<NSManagedObject>(entityName: "WorkDeskResult"))
            var results: [UUID: WorkDeskResultRecord] = [:]
            for row in rows {
                guard let materialID = row.value(forKey: "materialID") as? UUID,
                      let projectID = row.value(forKey: "projectID") as? UUID,
                      let conversationID = row.value(forKey: "conversationID") as? UUID,
                      let messageID = row.value(forKey: "messageID") as? UUID,
                      let attachmentID = row.value(forKey: "attachmentID") as? UUID,
                      let gatewayRef = row.value(forKey: "gatewayRef") as? String else { continue }
                let record = WorkDeskResultRecord(materialID: materialID, projectID: projectID,
                    conversationID: conversationID, messageID: messageID, attachmentID: attachmentID,
                    gatewayRef: gatewayRef, fileLaneID: row.value(forKey: "fileLaneID") as? String,
                    createdAt: row.value(forKey: "createdAt") as? Date ?? .distantPast,
                    isRemoteReference: (row.value(forKey: "isRemoteReference") as? NSNumber)?.boolValue ?? false)
                if results[materialID].map({ $0.createdAt <= record.createdAt }) ?? true {
                    results[materialID] = record
                }
            }
            return results
        }
    }

    func hasWorkDeskResult(_ materialID: UUID) async throws -> Bool {
        let context = newReadContext()
        return try await context.perform { try Self.workDeskResultExists(materialID, in: context) }
    }

    private nonisolated static func workDeskResultExists(
        _ materialID: UUID, in context: NSManagedObjectContext
    ) throws -> Bool {
        guard context.persistentStoreCoordinator?.managedObjectModel.entitiesByName["WorkDeskResult"] != nil else { return false }
        let request = NSFetchRequest<NSManagedObject>(entityName: "WorkDeskResult")
        request.predicate = NSPredicate(format: "materialID == %@", materialID as CVarArg)
        request.fetchLimit = 1
        return try context.count(for: request) > 0
    }

    nonisolated static func insertWorkDeskResult(
        _ source: WorkDeskResultRecord, in context: NSManagedObjectContext
    ) throws {
        guard try !workDeskResultExists(source.materialID, in: context) else {
            throw WorkboardStoreError.materialNotFound
        }
        // Reject a source that disappeared during local payload preparation.
        // Its original project may have been ungrouped: that is handled by the
        // placement check in this SAME transaction and leaves the chat intact.
        let request = NSFetchRequest<NSManagedObject>(entityName: "Attachment")
        request.predicate = NSPredicate(format: "id == %@ AND message.id == %@ AND message.conversation.id == %@",
            source.attachmentID as CVarArg, source.messageID as CVarArg, source.conversationID as CVarArg)
        guard let attachment = try context.fetch(request).first,
              let message = attachment.value(forKey: "message") as? NSManagedObject,
              ["agent", "assistant"].contains(message.value(forKey: "role") as? String ?? ""),
              (message.value(forKey: "projectResultExcluded") as? NSNumber)?.boolValue != true,
              let conversation = message.value(forKey: "conversation") as? NSManagedObject,
              conversation.value(forKey: "projectID") as? UUID == source.projectID,
              conversation.value(forKey: "backend") as? String == source.gatewayRef,
              message.value(forKey: "outputScanLaneID") as? String == source.fileLaneID,
              ((attachment.value(forKey: "isServerReference") as? NSNumber)?.boolValue ?? false) == source.isRemoteReference else {
            throw WorkboardStoreError.materialNotFound
        }
        let row = NSEntityDescription.insertNewObject(forEntityName: "WorkDeskResult", into: context)
        row.setValue(source.materialID, forKey: "materialID")
        row.setValue(source.projectID, forKey: "projectID")
        row.setValue(source.conversationID, forKey: "conversationID")
        row.setValue(source.messageID, forKey: "messageID")
        row.setValue(source.attachmentID, forKey: "attachmentID")
        row.setValue(source.gatewayRef, forKey: "gatewayRef")
        row.setValue(source.fileLaneID, forKey: "fileLaneID")
        row.setValue(source.createdAt, forKey: "createdAt")
        row.setValue(source.isRemoteReference, forKey: "isRemoteReference")
    }

    /// Only assistant attachment writes schedule a scoped local pass. Ordinary
    /// chat/attention/Work metadata writes never scan history. Load, explicit
    /// refresh and debounced successful CloudKit imports recover all project conversations.
    func scheduleProjectResultReconciliation(conversationID: UUID? = nil) {
        projectResultsNeedPass = true
        if let conversationID { projectResultPendingConversationIDs.insert(conversationID) }
        else { projectResultsNeedFullPass = true }
        guard projectResultTask == nil else { return }
        projectResultTask = Task { [weak self] in
            await self?.runProjectResultReconciliation()
        }
    }

    /// Work can await this on refresh; message persistence never waits for it.
    func reconcileProjectResults() async {
        scheduleProjectResultReconciliation()
        await projectResultTask?.value
    }

    private func runProjectResultReconciliation() async {
        var attempted: Set<UUID> = []
        while projectResultsNeedPass {
            projectResultsNeedPass = false
            let conversationIDs = projectResultsNeedFullPass ? nil : projectResultPendingConversationIDs
            projectResultsNeedFullPass = false
            projectResultPendingConversationIDs.removeAll()
            do { attempted.formUnion(try await capturePendingProjectResults(excluding: attempted, conversationIDs: conversationIDs)) }
            catch { /* Durable sources remain candidates on next refresh. */ }
        }
        projectResultTask = nil
    }

    #if CONDUCK_TESTING
    func _projectResultMessageFetchCountForTesting() async -> Int {
        await projectResultTask?.value
        return projectResultMessageFetchCount
    }
    #endif

    private nonisolated struct ProjectResultCandidate: Sendable {
        let conversation: ConversationRecord
        let message: MessageRecord
    }

    private func capturePendingProjectResults(
        excluding attempted: Set<UUID>, conversationIDs: Set<UUID>?
    ) async throws -> Set<UUID> {
        var tried: Set<UUID> = []
        try await ensureLoaded()
        let context = newReadContext()
        let fetched: (candidates: [ProjectResultCandidate], queriedMessages: Bool) = try await context.perform {
            let model = context.persistentStoreCoordinator?.managedObjectModel
            guard model?.entitiesByName["Conversation"]?.attributesByName["projectID"] != nil,
                  model?.entitiesByName["WorkDeskResult"] != nil else { return ([], false) }
            // Resolve the small owner table FIRST. A predicate walking every
            // Message's conversation/attachments made ordinary chat writes
            // quadratic, even when there were no project conversations at all.
            let ownersRequest = NSFetchRequest<NSManagedObject>(entityName: "Conversation")
            if let conversationIDs {
                guard !conversationIDs.isEmpty else { return ([], false) }
                ownersRequest.predicate = NSPredicate(format: "projectID != nil AND id IN %@", Array(conversationIDs))
            } else {
                ownersRequest.predicate = NSPredicate(format: "projectID != nil")
            }
            let owners = try context.fetch(ownersRequest)
            guard !owners.isEmpty else { return ([], false) }
            let request = NSFetchRequest<NSManagedObject>(entityName: "Message")
            request.predicate = NSPredicate(format:
                "conversation IN %@ AND (role == %@ OR role == %@) AND attachments.@count > 0 AND (projectResultExcluded == nil OR projectResultExcluded == NO)", owners, "agent", "assistant")
            request.relationshipKeyPathsForPrefetching = ["conversation", "attachments"]
            request.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: true)]
            let candidates: [ProjectResultCandidate] = try context.fetch(request).compactMap { row in
                guard let conversation = row.value(forKey: "conversation") as? NSManagedObject else { return nil }
                return ProjectResultCandidate(conversation: ConversationRecord(managedObject: conversation),
                    message: MessageRecord(managedObject: row))
            }
            return (candidates, true)
        }
        #if CONDUCK_TESTING
        if fetched.queriedMessages { projectResultMessageFetchCount += 1 }
        #endif
        let candidates = fetched.candidates
        guard !candidates.isEmpty else { return [] }
        let organization = try await fetchWorkDeskOrganization()
        let liveProjects = Set(organization.projects.map(\.id))
        var completed = Set(try await fetchWorkDeskResults().keys)
        let desk = try await fetchWorkItem(id: Constants.workboardDeskItemID)
        let repairable = Set((desk?.materials ?? []).filter {
            $0.availability == .unavailableOnThisDevice || $0.availability == .syncedPending
        }.map(\.id))
        for candidate in candidates {
            guard let projectID = candidate.conversation.projectID, liveProjects.contains(projectID) else { continue }
            var payloads: [UUID: Data]?
            for attachment in candidate.message.attachments {
                guard !WorkCaptureEnvelope.isAudioPayload(mimeType: attachment.mimeType, typeIdentifier: nil, filename: attachment.filename) else { continue }
                let materialID = Self.projectResultMaterialID(attachment, message: candidate.message)
                guard !attempted.contains(materialID) else { continue }
                guard !completed.contains(materialID) || (!attachment.isServerReference && repairable.contains(materialID)) else { continue }
                let source = WorkDeskResultRecord(materialID: materialID, projectID: projectID,
                    conversationID: candidate.conversation.id, messageID: candidate.message.id,
                    attachmentID: attachment.id, gatewayRef: candidate.conversation.backend,
                    fileLaneID: candidate.message.outputScanLaneID, createdAt: attachment.createdAt,
                    isRemoteReference: attachment.isServerReference)
                let draft: WorkMaterialDraft
                let name = attachment.filename ?? String(localized: "workdesk.result.file", defaultValue: "Returned file")
                if attachment.isServerReference {
                    // Ownerless legacy refs cannot be represented as retrievable
                    // results, and no preview blob is mistaken for the real file.
                    guard source.fileLaneID != nil, attachment.storedKey != nil else { continue }
                    draft = WorkMaterialDraft(id: materialID, kind: .note, title: name,
                        caption: String(localized: "workdesk.result.remote", defaultValue: "On gateway · Open source conversation"),
                        storageMode: .metadataOnly, createdAt: attachment.createdAt)
                } else {
                    if payloads == nil { payloads = (try? await loadLocalAttachmentPayloads(for: candidate.message.id)) ?? [:] }
                    guard let data = payloads?[attachment.id] else { continue }
                    draft = WorkMaterialDraft(id: materialID, kind: attachment.mimeType.hasPrefix("image/") ? .image : .file,
                        title: name, caption: String(localized: "workdesk.result.saved", defaultValue: "From project conversation"),
                        filename: name, mimeType: attachment.mimeType, payload: data,
                        thumbnailData: attachment.thumbnailData, width: attachment.width, height: attachment.height,
                        byteSize: Int64(data.count), createdAt: attachment.createdAt)
                }
                tried.insert(materialID)
                do {
                    _ = try await upsertDeskMaterial(draft, projectID: projectID, resultSource: source)
                    completed.insert(materialID)
                } catch { /* One unavailable result cannot block later files. */ }
            }
        }
        return tried
    }

    /// CloudKit may produce duplicate attachment rows for the same confirmed
    /// server key. Use the owning turn/lane/key, not one device's row UUID.
    private nonisolated static func projectResultMaterialID(
        _ attachment: AttachmentRecord, message: MessageRecord
    ) -> UUID {
        guard attachment.isServerReference, let key = attachment.storedKey else { return attachment.id }
        let identity = [message.id.uuidString, message.outputScanLaneID ?? "", key].joined(separator: "\n")
        var bytes = Array(SHA256.hash(data: Data(identity.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}
