// SPDX-License-Identifier: Apache-2.0

// Conduck
// MessageRecord.swift
//
// Sendable snapshot of a stored `Message`, decoupled from the
// `NSManagedObject` so it is safe to pass across the `ConversationStore`
// actor boundary and into `@MainActor` SwiftUI view models. The defensive
// `init(managedObject:)` (KVC + nil-coalescing) tolerates the all-optional
// Core Data model required by `NSPersistentCloudKitContainer`.
//
// The `attachments` to-many carries image/text-file attachments, ordered in
// code by `sequence` — the model relationship is unordered because CloudKit
// rejects `NSOrderedSet`.

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
    /// Send-state: `sending` / `sent` / `failed`. Stored on the store's own
    /// `Message` row and synced with it. Persisted on the USER turn only —
    /// agent turns are written already-complete, and a headless capture is
    /// written with no send at all, so nil means "no send state to show" and
    /// the UI treats it as `sent`.
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
    /// Stable one-way identity of the exact physical file lane that owns this
    /// USER turn's handed-off storedKeys. Nil for inline/text-only turns and
    /// legacy rows. Retry must fail closed unless the currently configured lane
    /// still has this identity.
    let fileTransferLaneID: String?
    /// Whether the retroactive output-file scan has run to a CONCLUSIVE finish
    /// on this turn (v5 model). Set true only when a pass both READ the turn's
    /// output folder and did so past the grace horizon (`scanMayClose`), so a
    /// marked turn is never re-listed; false = an explicitly pending scan, a
    /// folder the app could not read, or a pass that ran too early (retry on the
    /// next thread open). Every surface is admitted only by explicit false
    /// paired with `outputScanLaneID`, atomically stored with a reply whose
    /// dispatch latched a READY file lane. Legacy/ownerless nil rows stay
    /// excluded rather than guessing the currently configured server.
    let outputScanDone: Bool?
    /// Stable one-way identity of the exact file lane used by a recoverable
    /// dispatch — foreground Mac, in-app/background, CarPlay, and the Watch's
    /// standalone dispatch (which stamps the lane the iPhone couriered to it in
    /// the gateway envelope, since the wrist cannot derive one). Non-nil only
    /// when `outputScanDone == false` (or after that scan becomes true). Legacy
    /// rows remain nil and are not scanned: guessing the currently configured
    /// lane could attach a file from an unrelated server.
    let outputScanLaneID: String?
    /// The per-dispatch output folder this reply's turn was told to write into
    /// (`<conversationID>/out-<hex>`), stored verbatim so a different device —
    /// or this one days later — can list exactly that folder. Written in the
    /// SAME save as `outputScanLaneID`, which is what makes the pair
    /// recoverable rather than half-lost after a process death.
    ///
    /// Nil means UNKNOWN, never EMPTY. A row that syncs from CloudKit before
    /// this attribute lands, a Watch-originated turn (the wrist has no
    /// file-server credential, so it can neither mint nor create a folder), and
    /// every legacy row all read nil — and a nil selects the row OUT of the
    /// automatic pass rather than closing it, because "no folder recorded"
    /// cannot be distinguished from "folder recorded but not yet synced".
    let outputBoxKey: String?
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
        fileTransferLaneID: String? = nil,
        outputScanDone: Bool? = nil,
        outputScanLaneID: String? = nil,
        outputBoxKey: String? = nil,
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
        self.fileTransferLaneID = fileTransferLaneID
        self.outputScanDone = outputScanDone
        self.outputScanLaneID = outputScanLaneID
        self.outputBoxKey = outputBoxKey
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
        // `fileTransferLaneID` (v7 model): nil-tolerant. A legacy turn cannot
        // prove which physical lane owns its storedKeys, so retry treats a
        // server-reference legacy row conservatively.
        self.fileTransferLaneID = managedObject.value(forKey: "fileTransferLaneID") as? String
        // `outputScanDone` (v5 model): nil-tolerant — a v4 row (or a partially-
        // synced CloudKit row) has no attribute, which reads as nil. Candidate
        // selection requires explicit false PLUS the v7 durable lane on every
        // surface. Non-scalar Boolean → NSNumber.
        self.outputScanDone = (managedObject.value(forKey: "outputScanDone") as? NSNumber)?.boolValue
        // `outputScanLaneID` (v7 model): nil-tolerant. Any ownerless row cannot
        // prove which server accepted its dispatch and therefore stays excluded
        // from recovery.
        self.outputScanLaneID = managedObject.value(forKey: "outputScanLaneID") as? String
        // `outputBoxKey` (v8 model): nil-tolerant, and nil is UNKNOWN rather
        // than EMPTY. A v7 row, a Watch-originated turn, and a CloudKit row
        // that syncs before this attribute lands all read nil — none of them
        // has proven "this reply produced no files", so a nil selects the row
        // out of the automatic pass instead of closing it.
        self.outputBoxKey = managedObject.value(forKey: "outputBoxKey") as? String

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
