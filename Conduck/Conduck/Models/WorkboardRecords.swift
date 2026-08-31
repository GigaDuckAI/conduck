// SPDX-License-Identifier: Apache-2.0

// Conduck
// WorkboardRecords.swift
//
// Sendable values for the private Agent Workboard. The Core Data model is
// deliberately relationship-free for these records: UUID links let a work
// item and its immutable dispatch ledger sync independently from a conversation,
// while deleting either side can never cascade into the other. The state model
// is pure and human-owned: only an explicit completion produces Done; transport
// activity can ask for review but can never declare the objective complete.

import Foundation

// MARK: - Human-visible state

/// The four honest Workboard lanes. This is derived, never persisted.
nonisolated enum WorkItemState: String, CaseIterable, Codable, Sendable, Hashable {
    /// No dispatch is currently unresolved and no unreviewed result is waiting.
    case draft
    /// At least one prepared request is still awaiting a terminal result.
    case waiting
    /// A reply or failed delivery has not yet been acknowledged by the user.
    case review
    /// The user explicitly marked the objective complete.
    case done
}

/// What the linked conversation currently proves about one immutable dispatch.
nonisolated enum WorkDispatchActivity: Sendable, Hashable {
    /// A locally-created snapshot that has not crossed the prepare-for-send
    /// boundary. Tolerates a partially synced row without pretending it sent.
    case prepared
    /// The initial user turn exists (or its link has not synced yet) and no
    /// terminal result is present.
    case waiting
    /// The first agent reply after this dispatch's initial user turn.
    case replied(messageID: UUID)
    /// The exact user turn is `sent`, which Conduck writes only in the same
    /// transaction as a reply, but that reply row is not visible in this local
    /// fetch yet (for example during partial CloudKit materialization). Review
    /// stays armed and unacknowledgeable until the reply identity arrives.
    case replyPendingSync(userMessageID: UUID)
    /// The initial user turn is terminally failed. A nil attempt identity can
    /// be displayed but cannot be safely acknowledged; a later sync may fill it.
    case failed(messageID: UUID, attemptID: UUID?)
    /// The person explicitly deleted the linked Chat. The immutable brief/run
    /// remains visible, but it must never pretend an agent is still working.
    case conversationRemoved(conversationID: UUID)

    /// Stable identity stored by the acknowledgement. A reply's message id and
    /// a failure declaration's attempt id both re-arm when a genuinely new result
    /// appears. Nil is fail-closed: an unidentifiable failure stays in Review.
    var resultKey: String? {
        switch self {
        case .prepared, .waiting, .replyPendingSync:
            return nil
        case .replied(let messageID):
            return "reply:\(messageID.uuidString.lowercased())"
        case .failed(_, let attemptID):
            return attemptID.map { "failure:\($0.uuidString.lowercased())" }
        case .conversationRemoved(let conversationID):
            return "conversation-removed:\(conversationID.uuidString.lowercased())"
        }
    }

    var isReply: Bool {
        switch self {
        case .replied, .replyPendingSync: return true
        default: return false
        }
    }

    var isFailure: Bool {
        switch self {
        case .failed, .conversationRemoved: return true
        default: return false
        }
    }

    var isTerminal: Bool { isReply || isFailure }
}

/// Minimal facts consumed by the pure Workboard lane resolver.
nonisolated struct WorkDispatchStateFacts: Sendable, Hashable {
    let occurredAt: Date
    let activity: WorkDispatchActivity
    let acknowledgedResultKey: String?

    init(
        occurredAt: Date,
        activity: WorkDispatchActivity,
        acknowledgedResultKey: String? = nil
    ) {
        self.occurredAt = occurredAt
        self.activity = activity
        self.acknowledgedResultKey = acknowledgedResultKey
    }

    /// True only when this exact terminal result has not been acknowledged.
    var needsReview: Bool {
        guard activity.isTerminal else { return false }
        guard let current = activity.resultKey else { return true }
        return acknowledgedResultKey != current
    }
}

/// Single source of truth for Draft / Waiting / Review / Done.
nonisolated enum WorkItemStateResolver {
    static func resolve(
        completedAt: Date?,
        dispatches: [WorkDispatchStateFacts]
    ) -> WorkItemState {
        // Human completion always wins. A late transport callback must never
        // silently reopen or re-close the user's objective.
        if completedAt != nil { return .done }

        // Review has priority across ALL runs, not just the newest. Starting a
        // follow-up while an earlier response arrives must not hide that result.
        if dispatches.contains(where: \.needsReview) { return .review }

        guard let latest = dispatches.max(by: { $0.occurredAt < $1.occurredAt }) else {
            return .draft
        }
        switch latest.activity {
        case .waiting:
            return .waiting
        case .prepared, .replied, .replyPendingSync, .failed, .conversationRemoved:
            // A prepared row has not sent; an acknowledged terminal result
            // returns the still-open objective to Draft for refinement/reuse.
            return .draft
        }
    }
}

/// Minimal, persistence-free fact used to bind one Workboard dispatch to the
/// first agent turn before the next user turn. `Message.createdAt` can tie after
/// cross-device sync, so ordering always uses the repository-wide
/// `(createdAt, id)` rule instead of dates alone.
nonisolated struct WorkDispatchMessageFact: Sendable, Hashable {
    let id: UUID
    let role: String
    let createdAt: Date
}

nonisolated enum WorkDispatchReplyCorrelation {
    static func firstReplyID(
        workUserMessageID: UUID?,
        dispatchedAt: Date,
        messages: [WorkDispatchMessageFact]
    ) -> UUID? {
        let workUser = workUserMessageID.flatMap { id in
            messages.first { $0.id == id && $0.role == "user" }
        }
        let lowerDate = workUser?.createdAt ?? dispatchedAt
        let lowerID = workUser?.id.uuidString ?? ""

        func comesAfterLowerBound(_ message: WorkDispatchMessageFact) -> Bool {
            if message.createdAt != lowerDate { return message.createdAt > lowerDate }
            return message.id.uuidString > lowerID
        }

        let ordered = messages.sorted {
            ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString)
        }
        let nextUser = ordered.first { message in
            message.role == "user"
                && message.id != workUserMessageID
                && comesAfterLowerBound(message)
        }
        return ordered.first { message in
            guard message.role == "agent", comesAfterLowerBound(message) else { return false }
            guard let nextUser else { return true }
            return (message.createdAt, message.id.uuidString)
                < (nextUser.createdAt, nextUser.id.uuidString)
        }?.id
    }
}

// MARK: - Work item

/// Length bounds every brief write is held to. The fields below are plain
/// String attributes on a CloudKit-mirrored row, and the Shortcuts/Siri lane can
/// pipe a whole document into one of them unattended. A record past CloudKit's
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
/// they are loaded only for preview or dispatch.
nonisolated struct WorkItemRecord: Identifiable, Sendable, Hashable {
    let id: UUID
    let content: WorkItemContent
    let createdAt: Date
    let updatedAt: Date
    /// Presentation-only position within the item's pinned or unpinned cohort.
    /// It is deliberately independent from `updatedAt`: rearranging the board
    /// is not activity on the underlying objective and cannot invalidate an
    /// already-reviewed dispatch snapshot. Equal values are valid after a
    /// concurrent CloudKit merge and are resolved deterministically in the UI.
    let boardOrder: Int64?
    let completedAt: Date?
    let captureEnvelopeID: UUID?
    let currentDispatchID: UUID?
    let materials: [WorkMaterialRecord]
    let dispatches: [WorkDispatchRecord]
    let state: WorkItemState

    var latestDispatch: WorkDispatchRecord? {
        dispatches.max { lhs, rhs in lhs.occurredAt < rhs.occurredAt }
    }

    var unacknowledgedReplyCount: Int {
        dispatches.filter { $0.stateFacts.needsReview && $0.activity.isReply }.count
    }

    var unacknowledgedFailureCount: Int {
        dispatches.filter { $0.stateFacts.needsReview && $0.activity.isFailure }.count
    }
}

/// Bounded id/title/date projection of one open card. Deliberately carries no
/// material, run or availability fact: the cross-process share-targets snapshot
/// is rebuilt on the app's hottest notification bus and must never pay for the
/// whole board to publish a handful of picker rows.
nonisolated struct WorkItemSummary: Identifiable, Sendable, Hashable {
    let id: UUID
    let title: String
    let updatedAt: Date
}

/// One optimistic-concurrency fact for presentation-only board ordering. The
/// separate token means a drag never advances the brief's content revision.
nonisolated struct WorkItemBoardPosition: Sendable, Hashable {
    let id: UUID
    let boardOrder: Int64?

    init(id: UUID, boardOrder: Int64?) {
        self.id = id
        self.boardOrder = boardOrder
    }
}

/// Atomic reorder of one complete pin cohort as it appeared to the person.
/// Lifecycle remains derived and is never read or mutated here; pinning remains
/// editable brief content and is only an optimistic guard. Replaying an
/// already-applied request is a successful no-op even when its expectation has
/// since become stale.
nonisolated struct WorkItemBoardReorder: Sendable, Hashable {
    let movingItemID: UUID
    let expectedPinned: Bool
    let expectedPositions: [WorkItemBoardPosition]
    let orderedItemIDs: [UUID]

    init(
        movingItemID: UUID,
        expectedPinned: Bool,
        expectedPositions: [WorkItemBoardPosition],
        orderedItemIDs: [UUID]
    ) {
        self.movingItemID = movingItemID
        self.expectedPinned = expectedPinned
        self.expectedPositions = expectedPositions
        self.orderedItemIDs = orderedItemIDs
    }

    var desiredPositions: [WorkItemBoardPosition] {
        orderedItemIDs.enumerated().map { index, id in
            WorkItemBoardPosition(id: id, boardOrder: Int64(index))
        }
    }
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

/// Payload + metadata loaded only at the dispatch/preview boundary.
nonisolated struct LoadedWorkMaterial: Sendable, Hashable {
    let record: WorkMaterialRecord
    let payload: Data?
}

/// Exact per-material optimistic token approved in preflight. The owner row can
/// sync separately from a material in CloudKit, so both revisions are checked.
nonisolated struct WorkboardMaterialVersion: Hashable, Sendable {
    let id: UUID
    let revision: Int64
}

/// Immutable, locally captured dispatch input. Synced payload bytes are copied
/// into `payload`; a large local-vault payload is copied to a stable temporary
/// URL before any external upload begins. The coordinator owns URL cleanup.
nonisolated struct CapturedWorkMaterial: Sendable {
    let record: WorkMaterialRecord
    let payload: Data?
    let localFileURL: URL?
}

/// One transaction's exact editable brief plus every selected material. This is
/// the only value from which dispatch prompt, manifest and attachments are made.
nonisolated struct CapturedWorkDispatch: Sendable {
    let workItemID: UUID
    let content: WorkItemContent
    let updatedAt: Date
    let materials: [CapturedWorkMaterial]

    var temporaryFileURLs: [URL] { materials.compactMap(\.localFileURL) }
}

// MARK: - Immutable dispatch snapshot

/// Content-free manifest row frozen into a dispatch. Attachment bytes are deep-
/// copied into the conversation's initial message in the same transaction.
nonisolated struct WorkMaterialSnapshot: Codable, Sendable, Hashable {
    let id: UUID
    let kind: WorkMaterialKind
    let title: String
    let caption: String
    let textContent: String?
    let urlString: String?
    let filename: String?
    let mimeType: String?
    let byteSize: Int64
    let sequence: Int
    let storageMode: WorkMaterialStorageMode
    let sourceDevice: String?

    init(record: WorkMaterialRecord) {
        id = record.id
        kind = record.kind
        title = record.title
        caption = record.caption
        // A dispatch snapshot is itself CloudKit-mirrored. Never duplicate a
        // file extract into it, even if a malformed/older row contains one.
        textContent = record.kind == .file || record.kind == .image
            ? nil : record.textContent
        urlString = record.urlString
        filename = record.filename
        mimeType = record.mimeType
        byteSize = record.byteSize
        sequence = record.sequence
        storageMode = record.storageMode
        sourceDevice = record.sourceDevice
    }
}

/// Structured brief approved by the user. Versioned JSON lives beside the exact
/// canonical prompt, preserving both human structure and wire truth.
nonisolated struct WorkBriefSnapshot: Codable, Sendable, Hashable {
    static let currentVersion = 1

    let version: Int
    let title: String
    let objective: String
    let context: String
    let desiredOutcome: String
    let constraints: String
    let dueAt: Date?
    let materials: [WorkMaterialSnapshot]

    init(
        version: Int = Self.currentVersion,
        title: String,
        objective: String,
        context: String,
        desiredOutcome: String,
        constraints: String,
        dueAt: Date?,
        materials: [WorkMaterialSnapshot]
    ) {
        self.version = version
        self.title = title
        self.objective = objective
        self.context = context
        self.desiredOutcome = desiredOutcome
        self.constraints = constraints
        self.dueAt = dueAt
        self.materials = materials
    }
}

/// Persisted dispatch ledger row enriched with the linked turn's live activity.
nonisolated struct WorkDispatchRecord: Identifiable, Sendable, Hashable {
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
    let activity: WorkDispatchActivity

    var occurredAt: Date { dispatchedAt ?? createdAt }

    var stateFacts: WorkDispatchStateFacts {
        WorkDispatchStateFacts(
            occurredAt: occurredAt,
            activity: activity,
            acknowledgedResultKey: reviewAcknowledgedResultKey
        )
    }
}

/// Inputs to the final, atomic prepare-for-transport boundary. IDs are owned by
/// the caller, and a dispatch id that already exists is refused with
/// `identifierCollision` so a replayed preparation can never start a second
/// network attempt.
nonisolated struct WorkDispatchPreparation: Sendable {
    let dispatchID: UUID
    let workItemID: UUID
    let conversationID: UUID
    let userMessageID: UUID
    let deliveryAttemptID: UUID
    let gatewayRef: String
    let gatewayName: String
    let canonicalPrompt: String
    let briefSnapshot: WorkBriefSnapshot
    /// Exact editable-row token captured before any upload starts. The final
    /// transaction checks it again so a concurrent edit cannot be sent under an
    /// already-approved preview.
    let expectedWorkItemRevision: Int64
    /// Per-material tokens captured with the prompt. CloudKit can materialize a
    /// material independently from its owner row, so both levels are required.
    let expectedMaterialVersions: [WorkboardMaterialVersion]
    let sourceDevice: String
    let fileTransferLaneID: String?
    let attachments: [AttachmentDraft]
    let preparedAt: Date

    init(
        dispatchID: UUID = UUID(),
        workItemID: UUID,
        conversationID: UUID = UUID(),
        userMessageID: UUID = UUID(),
        deliveryAttemptID: UUID = UUID(),
        gatewayRef: String,
        gatewayName: String,
        canonicalPrompt: String,
        briefSnapshot: WorkBriefSnapshot,
        expectedWorkItemRevision: Int64,
        expectedMaterialVersions: [WorkboardMaterialVersion],
        sourceDevice: String,
        fileTransferLaneID: String? = nil,
        attachments: [AttachmentDraft] = [],
        preparedAt: Date = Date()
    ) {
        self.dispatchID = dispatchID
        self.workItemID = workItemID
        self.conversationID = conversationID
        self.userMessageID = userMessageID
        self.deliveryAttemptID = deliveryAttemptID
        self.gatewayRef = gatewayRef
        self.gatewayName = gatewayName
        self.canonicalPrompt = canonicalPrompt
        self.briefSnapshot = briefSnapshot
        self.expectedWorkItemRevision = expectedWorkItemRevision
        self.expectedMaterialVersions = expectedMaterialVersions
        self.sourceDevice = sourceDevice
        self.fileTransferLaneID = fileTransferLaneID
        self.attachments = attachments
        self.preparedAt = preparedAt
    }
}

/// What transport integration receives. Reaching this value means the rows are
/// newly committed and the run is already stamped as dispatched: the initial
/// turn is persisted `failed` for the retry pipeline's single network attempt,
/// so an interrupted hand-off surfaces as a reviewable run rather than a
/// silently stranded one.
nonisolated struct PreparedWorkDispatch: Sendable {
    let workItem: WorkItemRecord
    let dispatch: WorkDispatchRecord
    let conversation: ConversationRecord
    let message: MessageRecord
}

nonisolated enum WorkboardStoreError: Error, Sendable, Equatable {
    case itemNotFound
    case staleRevision
    case contentTooLong
    case materialNotFound
    case materialPayloadUnavailable
    case dispatchNotFound
    case invalidMaterialOwner
    case identifierCollision
    case snapshotEncodingFailed
}

/// Only the cases a PERSON can cause and can act on carry copy. Two app
/// surfaces render `error.localizedDescription` verbatim — the chat's "Add to
/// Work" notice and the editor's autosave alert — and without this the bridged
/// NSError fallback ("The operation couldn't be completed…") is what they show.
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
             .dispatchNotFound,
             .invalidMaterialOwner,
             .identifierCollision,
             .snapshotEncodingFailed:
            return nil
        }
    }
}
