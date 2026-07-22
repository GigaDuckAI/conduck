// Conduck
// MessageRecord.swift
//
// Sendable snapshot of a stored `Message`, decoupled from the
// `NSManagedObject` so it is safe to pass across the `ConversationStore`
// actor boundary and into `@MainActor` SwiftUI view models. The defensive
// `init(managedObject:)` (KVC + nil-coalescing) tolerates the all-optional
// Core Data model required by `NSPersistentCloudKitContainer`.
//
// V1.1 adds the `status` send-state field (`sending` / `sent` / `failed`;
// nil = legacy = treated as `sent`) and the `attachments` to-many
// (image/text-file attachments, ordered in code by `sequence` — the model
// relationship is unordered because CloudKit rejects `NSOrderedSet`).

import Foundation
import CoreData

/// Snapshot of a single persisted turn (one chat bubble). `role` is stored
/// as a String (`user` / `agent`) rather than a Core Data enum so CloudKit
/// keeps it simple. `sourceDevice` (`phone` / `watch` / `mac` / `carplay`)
/// lives on the message because each turn can originate from a different
/// device.
struct MessageRecord: Identifiable, Hashable, Sendable {
    let id: UUID
    /// `user` or `agent`.
    let role: String
    let text: String
    let createdAt: Date
    /// `phone` / `watch` / `mac` / `carplay`.
    let sourceDevice: String
    /// Send-state: `sending` / `sent` / `failed`. Nil = legacy turn (pre-V1.1)
    /// = treated as `sent` by the UI. Persisted on the user turn only; agent
    /// turns are written already-complete (status stays nil).
    let status: String?
    /// Failure classification: the `AppError.errorCode` the turn failed
    /// with. Nil while `sending`/`sent`, on legacy failed rows, and after a
    /// successful retry (cleared with the `sent` flip). NEVER a raw server
    /// value — always Conduck's own taxonomy code.
    let failureCode: Int?
    /// The adapter-contract wire `code` (`error.code`, revision 1.3 vocabulary)
    /// when the classification came from a structured code — nil when it came
    /// from the regex heuristics. Presence upgrades the row copy from hedged
    /// ("couldn't use the photo") to confident ("declined the photo"). Read
    /// through `AdapterWireCode(rawValue:)` — an unknown string means nil.
    let failureWireCode: String?
    /// Whether the FAILED request actually carried historical `image_url`
    /// parts (recorded at dispatch time from the assembled request — the
    /// image-history policy can demote stored images to file references, so
    /// a render-time thread scan would over-claim). Nil = unknown (legacy /
    /// pre-dispatch failure): poisoned copy falls back to the hedged variant.
    let failureHadHistoryImages: Bool?
    /// Whether the retroactive output-file scan has run to a CONCLUSIVE finish
    /// on this turn (v5 model). Set true only when every probe in a scan pass
    /// returned a definitive verdict, so a marked turn is never re-scanned;
    /// nil / false = never scanned or a transient probe failure (retry on the
    /// next thread open). Written only for the retro-scannable turns (agent
    /// replies that landed on Watch / CarPlay); stays nil everywhere else.
    let outputScanDone: Bool?
    /// Image / text-file attachments on this turn, ordered by `sequence`.
    /// Empty for text-only turns. The snapshots carry thumbnails + extracted
    /// text — never the full image bytes (loaded on demand).
    let attachments: [AttachmentRecord]

    init(
        id: UUID,
        role: String,
        text: String,
        createdAt: Date,
        sourceDevice: String,
        status: String? = nil,
        failureCode: Int? = nil,
        failureWireCode: String? = nil,
        failureHadHistoryImages: Bool? = nil,
        outputScanDone: Bool? = nil,
        attachments: [AttachmentRecord] = []
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.createdAt = createdAt
        self.sourceDevice = sourceDevice
        self.status = status
        self.failureCode = failureCode
        self.failureWireCode = failureWireCode
        self.failureHadHistoryImages = failureHadHistoryImages
        self.outputScanDone = outputScanDone
        self.attachments = attachments
    }

    /// Defensive bridge from the all-optional Core Data entity. Every field
    /// nil-coalesces so a partially-synced CloudKit row never crashes.
    init(managedObject: NSManagedObject) {
        self.id = (managedObject.value(forKey: "id") as? UUID) ?? UUID()
        self.role = (managedObject.value(forKey: "role") as? String) ?? "agent"
        self.text = (managedObject.value(forKey: "text") as? String) ?? ""
        self.createdAt = (managedObject.value(forKey: "createdAt") as? Date) ?? Date()
        self.sourceDevice = (managedObject.value(forKey: "sourceDevice") as? String) ?? "unknown"
        // `status` is nil-tolerant: a legacy row (no attribute / nil value) is
        // treated as `sent` by the UI, so a nil here is correct, not a default.
        self.status = managedObject.value(forKey: "status") as? String
        // Failure-classification fields (v4 model). All nil-tolerant: a v3 row (or a
        // partially-synced CloudKit row) simply has no classification, which
        // renders as the generic failure copy. `failureCode` is a non-scalar
        // Integer 32 → NSNumber through KVC.
        self.failureCode = (managedObject.value(forKey: "failureCode") as? NSNumber)?.intValue
        self.failureWireCode = managedObject.value(forKey: "failureWireCode") as? String
        self.failureHadHistoryImages = (managedObject.value(forKey: "failureHadHistoryImages") as? NSNumber)?.boolValue
        // `outputScanDone` (v5 model): nil-tolerant — a v4 row (or a partially-
        // synced CloudKit row) has no attribute, which reads as "never scanned"
        // (nil), the correct default. Non-scalar Boolean → NSNumber through KVC.
        self.outputScanDone = (managedObject.value(forKey: "outputScanDone") as? NSNumber)?.boolValue

        // Map the unordered `attachments` relationship into snapshots and sort
        // by `sequence` (the model relationship is NOT ordered — CloudKit
        // rejects `NSOrderedSet`). KVC-tolerant: a missing relationship or a
        // partially-synced set never crashes.
        if let set = managedObject.value(forKey: "attachments") as? Set<NSManagedObject> {
            self.attachments = set
                .map { AttachmentRecord(managedObject: $0) }
                .sorted { $0.sequence < $1.sequence }
        } else {
            self.attachments = []
        }
    }
}
