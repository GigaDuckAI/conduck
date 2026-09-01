// SPDX-License-Identifier: Apache-2.0

// Conduck
// WorkboardRecords.swift
//
// Sendable values for the private desk. The Core Data model is deliberately
// relationship-free for these records: UUID links let a work item and its
// materials sync as independent CloudKit records, so a partially materialized
// board shows what has arrived instead of failing whole.

import Foundation

/// Bit-exact optimistic-concurrency token derived from a persisted `Date`. A
/// coarse millisecond floor can approve a different payload/metadata write that
/// happened inside the same tick, so the raw bit pattern is the token.
nonisolated enum WorkboardRevision {
    static func value(for date: Date) -> Int64 {
        Int64(bitPattern: date.timeIntervalSinceReferenceDate.bitPattern)
    }
}

// MARK: - Human-visible state

/// The four lanes an older build could write. The desk has no lifecycle, so
/// every projected record reads `.draft`; the enum survives because the column
/// does, and a row written before the desk must still round-trip.
nonisolated enum WorkItemState: String, CaseIterable, Codable, Sendable, Hashable {
    case draft
    case waiting
    case review
    case done
}

// MARK: - Work item

/// Length bounds every write is held to. The fields below are plain String
/// attributes on a CloudKit-mirrored row, and the Shortcuts/Siri lane can pipe a
/// whole document into one of them unattended. A record past CloudKit's
/// non-asset payload budget can never export, so the bound is refused at the
/// write boundary instead of truncated. It is derived from the capture
/// envelope's note bound so an ingress pre-check and the store agree exactly; a
/// drift between them would either strand text at the store or let the intent
/// reject what the store would accept.
nonisolated enum WorkItemContentLimits {
    static let maximumFieldCharacters = WorkCaptureEnvelope.maximumNoteCharacters
}

/// The editable fields of one brief. A full value (rather than a patch full of
/// nested optionals) makes autosave call sites explicit about what they retain.
nonisolated struct WorkItemContent: Sendable, Hashable, Codable {
    var title: String
    var objective: String
    var context: String
    var desiredOutcome: String
    var constraints: String
    var dueAt: Date?
    var preferredGatewayRef: String?
    var isPinned: Bool

    init(
        title: String = "",
        objective: String = "",
        context: String = "",
        desiredOutcome: String = "",
        constraints: String = "",
        dueAt: Date? = nil,
        preferredGatewayRef: String? = nil,
        isPinned: Bool = false
    ) {
        self.title = title
        self.objective = objective
        self.context = context
        self.desiredOutcome = desiredOutcome
        self.constraints = constraints
        self.dueAt = dueAt
        self.preferredGatewayRef = preferredGatewayRef
        self.isPinned = isPinned
    }
}

/// Creation request with a caller-owned id for idempotent capture imports.
nonisolated struct WorkItemDraft: Sendable, Hashable {
    let id: UUID
    /// Stable share/capture id. A repeated import returns the existing item.
    let captureEnvelopeID: UUID?
    var content: WorkItemContent
    let createdAt: Date

    init(
        id: UUID = UUID(),
        captureEnvelopeID: UUID? = nil,
        content: WorkItemContent = WorkItemContent(),
        createdAt: Date = Date()
    ) {
        self.id = id
        self.captureEnvelopeID = captureEnvelopeID
        self.content = content
        self.createdAt = createdAt
    }
}

/// Rich, UI-safe snapshot. Full material payload bytes are intentionally absent;
/// they are loaded only when a card is opened.
nonisolated struct WorkItemRecord: Identifiable, Sendable, Hashable {
    let id: UUID
    let content: WorkItemContent
    let createdAt: Date
    let updatedAt: Date
    /// Presentation-only position, deliberately independent from `updatedAt`.
    /// Equal values are valid after a concurrent CloudKit merge and are resolved
    /// deterministically in the UI.
    let boardOrder: Int64?
    let completedAt: Date?
    let captureEnvelopeID: UUID?
    let materials: [WorkMaterialRecord]
    let state: WorkItemState
}

/// Result of deliberately turning one existing chat turn into inert Work.
/// Attachment misses are explicit because server-only files cannot truthfully be
/// copied from a chat snapshot without downloading from the user's gateway.
nonisolated struct WorkMessageCaptureReceipt: Sendable, Hashable {
    let itemID: UUID
    let addedMaterialCount: Int
    let referencedOnlyMaterialCount: Int
    let failedMaterialCount: Int
    let wasAlreadyCaptured: Bool
}

// MARK: - Materials

nonisolated enum WorkMaterialKind: String, CaseIterable, Codable, Sendable, Hashable {
    case note
    case link
    case image
    case file
    /// A voice recording kept as playable bytes. Its transcript, when speech
    /// recognition produces one, lands in `textContent` on this same material,
    /// so a failed transcription costs the words and never the recording.
    case audio
    /// A transcript captured by voice, carrying no recording of its own.
    case transcript
    /// Forward-compatible fallback for a kind this build cannot render richly.
    case unknown

    init(stored rawValue: String?) {
        self = rawValue.flatMap(Self.init(rawValue:)) ?? .unknown
    }
}

/// Where payload bytes live. The mode syncs; local availability does not.
nonisolated enum WorkMaterialStorageMode: String, CaseIterable, Codable, Sendable, Hashable {
    /// Text, a link, or metadata that intentionally has no binary payload.
    case metadataOnly
    /// External-binary Core Data asset mirrored in the user's private CloudKit.
    case syncedPayload
    /// App-Group vault on the source device; only metadata and an opaque key sync.
    case localVault

    init(stored rawValue: String?) {
        self = rawValue.flatMap(Self.init(rawValue:)) ?? .metadataOnly
    }
}

/// How much room one material's card claims on the board. Presentation only:
/// it is never part of a brief, a prompt, or a dispatch snapshot, so writing it
/// must not advance any revision. `standard` is the absent value — a row that
/// has never been resized stores nil, which keeps the CloudKit-mirrored column
/// empty for every card nobody has deliberately sized.
nonisolated enum WorkMaterialCardSize: String, CaseIterable, Codable, Sendable, Hashable {
    case small
    case standard
    case large

    /// A newer build may introduce a size this one cannot lay out. Falling back
    /// to the neutral middle keeps the board readable instead of dropping the
    /// card or guessing an extreme.
    init(stored rawValue: String?) {
        self = rawValue.flatMap(Self.init(rawValue:)) ?? .standard
    }

    /// Decoding is deliberately total. A size arriving from a newer build, or a
    /// null where a string was expected, is a layout hint — never a reason to
    /// fail the whole value that carries it.
    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        self = Self(stored: try? container.decode(String.self))
    }

    /// Value written to the row. Standard is absence, so a reset clears the
    /// column instead of leaving a synthetic marker behind.
    var storedValue: String? { self == .standard ? nil : rawValue }
}

/// Device-relative availability shown before dispatch. This prevents a locally
/// captured large file from simply disappearing when the card opens elsewhere.
nonisolated enum WorkMaterialAvailability: String, Codable, Sendable, Hashable {
    case metadataOnly
    case synced
    case availableLocally
    case unavailableOnThisDevice
    /// The row names synced bytes whose blob has not landed on this device yet.
    /// CloudKit materializes a material and its blob independently, so this is
    /// an ordinary arrival gap, not damage. It fails closed — the card renders
    /// from its metadata but cannot open, play or dispatch until bytes arrive.
    case syncedPending
}

/// Creation request. File/image content stays in the device-local vault; only
/// metadata enters the CloudKit-mirrored row. Callers never hand the store a
/// security-scoped URL.
nonisolated struct WorkMaterialDraft: Sendable {
    let id: UUID
    let kind: WorkMaterialKind
    let title: String
    let caption: String
    let textContent: String?
    let urlString: String?
    let filename: String?
    let mimeType: String?
    let payload: Data?
    let thumbnailData: Data?
    let width: Int?
    let height: Int?
    let byteSize: Int64?
    let sequence: Int
    let storageMode: WorkMaterialStorageMode
    let sourceDevice: String?
    /// Carried so duplicating a card reproduces the arrangement the person
    /// built. Every fresh capture leaves it at `standard`.
    let cardSize: WorkMaterialCardSize
    let createdAt: Date

    init(
        id: UUID = UUID(),
        kind: WorkMaterialKind,
        title: String = "",
        caption: String = "",
        textContent: String? = nil,
        urlString: String? = nil,
        filename: String? = nil,
        mimeType: String? = nil,
        payload: Data? = nil,
        thumbnailData: Data? = nil,
        width: Int? = nil,
        height: Int? = nil,
        byteSize: Int64? = nil,
        sequence: Int = 0,
        storageMode: WorkMaterialStorageMode? = nil,
        sourceDevice: String? = nil,
        cardSize: WorkMaterialCardSize = .standard,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.caption = caption
        self.textContent = textContent
        self.urlString = urlString
        self.filename = filename
        self.mimeType = mimeType
        self.payload = payload
        self.thumbnailData = thumbnailData
        self.width = width
        self.height = height
        self.byteSize = byteSize
        self.sequence = sequence
        self.storageMode = storageMode ?? (payload == nil ? .metadataOnly : .localVault)
        self.sourceDevice = sourceDevice
        self.cardSize = cardSize
        self.createdAt = createdAt
    }
}

nonisolated struct WorkMaterialRecord: Identifiable, Sendable, Hashable {
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
    let hasPayload: Bool
    let storageMode: WorkMaterialStorageMode
    let availability: WorkMaterialAvailability
    let localVaultKey: String?
    let sourceDevice: String?
    let sequence: Int
    /// Board presentation only. It is defaulted rather than required so no
    /// caller that describes a material's content has to state a layout fact.
    let cardSize: WorkMaterialCardSize
    let createdAt: Date
    let updatedAt: Date

    init(
        id: UUID,
        workItemID: UUID,
        kind: WorkMaterialKind,
        title: String,
        caption: String,
        textContent: String?,
        urlString: String?,
        filename: String?,
        mimeType: String?,
        thumbnailData: Data?,
        width: Int?,
        height: Int?,
        byteSize: Int64,
        hasPayload: Bool,
        storageMode: WorkMaterialStorageMode,
        availability: WorkMaterialAvailability,
        localVaultKey: String?,
        sourceDevice: String?,
        sequence: Int,
        cardSize: WorkMaterialCardSize = .standard,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.workItemID = workItemID
        self.kind = kind
        self.title = title
        self.caption = caption
        self.textContent = textContent
        self.urlString = urlString
        self.filename = filename
        self.mimeType = mimeType
        self.thumbnailData = thumbnailData
        self.width = width
        self.height = height
        self.byteSize = byteSize
        self.hasPayload = hasPayload
        self.storageMode = storageMode
        self.availability = availability
        self.localVaultKey = localVaultKey
        self.sourceDevice = sourceDevice
        self.sequence = sequence
        self.cardSize = cardSize
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// Metadata of one synced payload blob, projected without its bytes. The blob
/// lives in its own CloudKit-mirrored store, keyed to its material by UUID
/// rather than by a relationship — the two stores hold different entities and
/// Core Data forbids a relationship across configurations.
///
/// A blob row arrives independently of the material row it belongs to, in
/// either order, and a crash can leave one without the other. `isComplete` is
/// therefore the only thing that licenses reading bytes: an imported row whose
/// hash or size is still absent is an arrival in progress, not a payload.
nonisolated struct WorkMaterialBlobRecord: Identifiable, Sendable, Hashable {
    /// The material this payload belongs to. It is also the record's identity:
    /// duplicate blobs for one material are a legal transient state that the
    /// newest complete row resolves, so the material id — not a blob id — is
    /// what every reader looks up.
    var id: UUID { materialID }
    let materialID: UUID
    let byteSize: Int64
    /// Content hash of the exact bytes stored. A replayed capture whose hash
    /// disagrees with the stored row is a stale blob to replace, not a match.
    let contentHash: String
    let createdAt: Date
    let updatedAt: Date

    init(
        materialID: UUID,
        byteSize: Int64,
        contentHash: String,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.materialID = materialID
        self.byteSize = byteSize
        self.contentHash = contentHash
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// Whether the row proves a whole payload landed. Both facts are written in
    /// the same save as the bytes, so their presence is what distinguishes a
    /// finished blob from a partially materialized import.
    var isComplete: Bool { byteSize > 0 && !contentHash.isEmpty }
}

/// Payload + metadata loaded only when a card is opened.
nonisolated struct LoadedWorkMaterial: Sendable, Hashable {
    let record: WorkMaterialRecord
    let payload: Data?
}

nonisolated enum WorkboardStoreError: Error, Sendable, Equatable {
    case itemNotFound
    case staleRevision
    case contentTooLong
    case materialNotFound
    case materialPayloadUnavailable
    case invalidMaterialOwner
    case identifierCollision
}

/// Only the cases a PERSON can cause and can act on carry copy. The chat's
/// "Add to Work" notice renders `error.localizedDescription` verbatim, and
/// without this the bridged NSError fallback ("The operation couldn't be
/// completed…") is what it shows.
/// The rest stay nil on purpose: an internal invariant failure has no user
/// action, and inventing copy for one would dress a bug up as a decision.
extension WorkboardStoreError: LocalizedError {
    nonisolated var errorDescription: String? {
        switch self {
        case .contentTooLong:
            // Grouped by the reader's own locale ("16,000"), not by `%lld`,
            // which would print a bare 16000 the person has to count.
            let limit = WorkItemContentLimits.maximumFieldCharacters.formatted(.number)
            return String(
                localized: "workboard.error.contentTooLong",
                defaultValue: "That brief is longer than \(limit) characters. Shorten it, then try again."
            )
        case .itemNotFound,
             .staleRevision,
             .materialNotFound,
             .materialPayloadUnavailable,
             .invalidMaterialOwner,
             .identifierCollision:
            return nil
        }
    }
}
