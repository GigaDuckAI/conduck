// SPDX-License-Identifier: Apache-2.0

// Work input usage is provenance of an accepted conversation snapshot, separate
// from the material's single project home and from assistant-output provenance.
// The receipt lives on the conversation, so deletion removes it naturally. A
// named surviving user message is required: CloudKit may deliver either half
// first. Reads project metadata and only those named message rows, never files,
// message text, or an unbounded scan of ordinary conversation history.

import Foundation
import CoreData

nonisolated struct WorkDeskMaterialUseRecord: Identifiable, Hashable, Sendable {
    var id: UUID { conversationID }
    let materialID: UUID
    let conversationID: UUID
    let gatewayRef: String
    let conversationTitle: String
    let sentAt: Date
}

extension ConversationStore {
    func fetchWorkDeskMaterialUses() async throws -> [UUID: [WorkDeskMaterialUseRecord]] {
        try await ensureLoaded()
        let context = newReadContext()
        return try await context.perform {
            guard context.persistentStoreCoordinator?.managedObjectModel.entitiesByName["Conversation"]?
                .attributesByName["workMaterialUsageJSON"] != nil else { return [:] }
            let request = NSFetchRequest<NSManagedObject>(entityName: "Conversation")
            request.predicate = NSPredicate(format: "workMaterialUsageJSON != nil")
            let candidates = try context.fetch(request).compactMap { row -> (NSManagedObject, WorkDeskMaterialUsage)? in
                guard let usage = WorkDeskMaterialUsage(json: row.value(forKey: "workMaterialUsageJSON") as? String),
                      row.value(forKey: "id") is UUID, row.value(forKey: "backend") is String else { return nil }
                return (row, usage)
            }
            guard !candidates.isEmpty else { return [:] }

            // A dictionary projection cannot fault a message's potentially
            // large text or attachments. Query only receipt-named message IDs;
            // the relationship object ID also proves the exact surviving owner.
            let messages = NSFetchRequest<NSDictionary>(entityName: "Message")
            messages.resultType = .dictionaryResultType
            messages.propertiesToFetch = ["id", "createdAt", "conversation"]
            messages.predicate = NSPredicate(format: "id IN %@ AND role == %@", candidates.map { $0.1.messageID }, "user")
            var accepted: [NSManagedObjectID: [UUID: Date]] = [:]
            for message in try context.fetch(messages) {
                guard let owner = message["conversation"] as? NSManagedObjectID,
                      let id = message["id"] as? UUID,
                      let date = message["createdAt"] as? Date else { continue }
                accepted[owner, default: [:]][id] = date
            }
            var byMaterial: [UUID: [UUID: WorkDeskMaterialUseRecord]] = [:]
            for (row, usage) in candidates {
                guard let sentAt = accepted[row.objectID]?[usage.messageID] else { continue }
                let conversation = ConversationRecord(managedObject: row)
                for input in usage.inputs {
                    let record = WorkDeskMaterialUseRecord(materialID: input.materialID,
                        conversationID: conversation.id, gatewayRef: conversation.backend,
                        conversationTitle: conversation.displayTitle, sentAt: sentAt)
                    byMaterial[input.materialID, default: [:]][conversation.id] = record
                }
            }
            return byMaterial.mapValues { records in
                records.values.sorted {
                    $0.sentAt == $1.sentAt ? $0.conversationID.uuidString < $1.conversationID.uuidString : $0.sentAt > $1.sentAt
                }
            }
        }
    }
}
