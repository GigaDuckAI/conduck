// SPDX-License-Identifier: Apache-2.0

// Conduck
// WorkboardRecords.swift
//
// Sendable values for the private desk. The Core Data model is deliberately
// relationship-free for these records: UUID links let a work item and its
// materials sync as independent CloudKit records, so a partially materialized
// board shows what has arrived instead of failing whole.

import Foundation
import UniformTypeIdentifiers

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

/// The editable heading fields of a work item. The desk leaves both unwritten;
/// a full value (rather than a patch full of nested optionals) keeps autosave
/// call sites explicit about what they retain.
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
    /// Attachments this capture deliberately left in the chat. A recording is
    /// the only one: Work keeps audio only when the person adds it themselves
    /// through the Work pane. Counted rather than folded into `failed`, because
    /// nothing went wrong and there is nothing to try again.
    var refusedMaterialCount: Int = 0
    let wasAlreadyCaptured: Bool
}

// MARK: - Materials

nonisolated enum WorkMaterialKind: String, CaseIterable, Codable, Sendable, Hashable {
    case note
    case link
    case image
    case file
    /// An audio file a person attached in Work, or a recording written by an
    /// earlier build, kept as playable bytes. `textContent` carries words only
    /// where such a build attached them to the recording itself.
    case audio
    /// The words of a Work voice note, carrying no recording of its own — the
    /// recording is deleted once this card is written. Where the note named a
    /// screenshot, `attachedToMaterialID` folds this card into that picture's.
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
/// it is never part of the material's content, so writing it must not advance
/// any revision. `standard` is the absent value — a row that
/// has never been resized stores nil, which keeps the CloudKit-mirrored column
/// empty for every card nobody has deliberately sized.
///
/// THE BOARD GRANTS ONE FOOTPRINT, so this column is currently read and never
/// written by the desk: a stored `small` or `large` — from an older build, or
/// from a device still running one — decodes faithfully, syncs untouched and
/// renders `standard`. It stays in the schema, and every reader stays total,
/// because the uniform board is a product bet that has to be reversible on
/// evidence; `WorkboardFootprint` is the one switch that reverses it, and it
/// can only mean anything if nobody's stored size was rewritten in the
/// meantime.
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

/// Device-relative availability of a card's bytes. This prevents a locally
/// captured large file from simply disappearing when the card opens elsewhere.
nonisolated enum WorkMaterialAvailability: String, Codable, Sendable, Hashable {
    case metadataOnly
    case synced
    case availableLocally
    case unavailableOnThisDevice
    /// The row names synced bytes whose blob has not landed on this device yet.
    /// CloudKit materializes a material and its blob independently, so this is
    /// an ordinary arrival gap, not damage. It fails closed — the card renders
    /// from its metadata but cannot open or play until the bytes arrive.
    case syncedPending
}

/// Creation request. The row itself carries metadata only; where the bytes go
/// is `WorkMaterialStoragePolicy`'s decision, recorded in `storageMode`.
/// Callers never hand the store a security-scoped URL.
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
    /// The picture this recording belongs to, when one capture produced both.
    ///
    /// A PROMISE ABOUT IDENTITY, NOT ABOUT EXISTENCE. It is written on the
    /// RECORDING draft alone — never on a picture, never on a fallback note —
    /// and it names the id the picture of that same capture would take, set
    /// whenever the capture carried a picture when the recording published,
    /// even if the picture's own publication failed. A picture that lands later
    /// (a retry, a drain that escaped a collision) therefore needs no repair:
    /// the recording already names it.
    ///
    /// The two artifacts stay two materials with two ids and two payloads —
    /// this is the only thing that says they came from one press.
    let attachedToMaterialID: UUID?
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
        attachedToMaterialID: UUID? = nil,
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
        self.attachedToMaterialID = attachedToMaterialID
        self.createdAt = createdAt
    }

    /// The same card, describing the JPEG the desk write normalised its
    /// picture to instead of the bytes the capture handed over.
    ///
    /// Everything that names the payload's FORMAT follows the bytes: the mime
    /// type, the filename's extension and — because the export names a shared
    /// copy after the title before it consults anything else — the title's
    /// extension too, when the title carried one that names an image. A title
    /// that is a sentence, or ends in something the system cannot type, is left
    /// alone: rewriting "Meeting v1.2" would invent an extension it never had.
    /// Identity, rank, caption, provenance and the companion link are carried
    /// verbatim; what changed is the representation, not the card.
    func normalisedImage(jpeg: Data) -> WorkMaterialDraft {
        describedAsJPEG(payload: jpeg, byteSize: Int64(jpeg.count))
    }

    /// The same card with every name that states a format saying JPEG, and its
    /// bytes left exactly as they are — for a picture the desk write found
    /// already the shape it keeps, whose capture may still have named it
    /// `.png` or `.heic`.
    func renamedAsJPEG() -> WorkMaterialDraft {
        describedAsJPEG(payload: payload, byteSize: byteSize)
    }

    private func describedAsJPEG(payload: Data?, byteSize: Int64?) -> WorkMaterialDraft {
        WorkMaterialDraft(
            id: id,
            kind: kind,
            title: Self.renamingTypedExtension(of: title, to: "jpg") ?? title,
            caption: caption,
            textContent: textContent,
            urlString: urlString,
            filename: filename.map { Self.replacingExtension(of: $0, with: "jpg") },
            mimeType: "image/jpeg",
            payload: payload,
            thumbnailData: thumbnailData,
            width: width,
            height: height,
            byteSize: byteSize,
            sequence: sequence,
            storageMode: storageMode,
            sourceDevice: sourceDevice,
            cardSize: cardSize,
            attachedToMaterialID: attachedToMaterialID,
            createdAt: createdAt
        )
    }

    /// `name` with its extension swapped for `ext`, whatever the old one was —
    /// a filename always describes its bytes, so it always takes the new type.
    /// An extension that already names the same type is kept as spelled:
    /// `photo.jpeg` is not renamed `photo.jpg` for nothing.
    static func replacingExtension(of name: String, with ext: String) -> String {
        let current = (name as NSString).pathExtension
        if !current.isEmpty,
           let currentType = UTType(filenameExtension: current),
           let newType = UTType(filenameExtension: ext),
           !currentType.isDynamic,
           currentType == newType {
            return name
        }
        let stem = (name as NSString).deletingPathExtension
        return stem.isEmpty ? "\(name).\(ext)" : "\(stem).\(ext)"
    }

    /// `name` with its extension swapped for `ext` ONLY when the current one
    /// names a type the system knows — `.heic`, `.png`, but equally a
    /// misnamed `.pdf`, since the export names a shared copy after the title
    /// before it consults anything else and a JPEG must never leave as a
    /// `.pdf`. Nil when it names nothing, so a title that merely ends in a
    /// dot-something ("Meeting v1.2") keeps it.
    static func renamingTypedExtension(of name: String, to ext: String) -> String? {
        let current = (name as NSString).pathExtension
        guard !current.isEmpty,
              let type = UTType(filenameExtension: current),
              !type.isDynamic else { return nil }
        return replacingExtension(of: name, with: ext)
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
    /// On the synced lane, the hash of the exact bytes this card was published
    /// with — the other half of `WorkMaterialBlobPairing`. Nil on every other
    /// lane, and on a row written before the pairing existed.
    let contentHash: String?
    let localVaultKey: String?
    let sourceDevice: String?
    let sequence: Int
    /// Board presentation only. It is defaulted rather than required so no
    /// caller that describes a material's content has to state a layout fact.
    let cardSize: WorkMaterialCardSize
    /// The picture this recording belongs to — see
    /// `WorkMaterialDraft.attachedToMaterialID`. Nil on every card that is not
    /// a recording published beside a picture, and nil on every row written
    /// before the link existed. The named material may not exist yet, or ever:
    /// a reader resolves it, and renders the recording on its own when it
    /// cannot.
    let attachedToMaterialID: UUID?
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
        contentHash: String? = nil,
        localVaultKey: String?,
        sourceDevice: String?,
        sequence: Int,
        cardSize: WorkMaterialCardSize = .standard,
        attachedToMaterialID: UUID? = nil,
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
        self.contentHash = contentHash
        self.localVaultKey = localVaultKey
        self.sourceDevice = sourceDevice
        self.sequence = sequence
        self.cardSize = cardSize
        self.attachedToMaterialID = attachedToMaterialID
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

/// The blob a `.syncedPayload` material row names.
///
/// THE PAIRING INVARIANT: a material row records the `contentHash` and
/// `byteSize` of the exact bytes it was published with, and a blob answers for
/// that material only when both match — so a blob is adopted, read, or counted
/// as present for a card only when some publication of exactly those bytes
/// completed against that card.
///
/// WHY FINDING A COMPLETE BLOB UNDER THE MATERIAL'S ID IS NOT ENOUGH. The two
/// stores mirror through CloudKit independently, so a blob another device
/// inserted can reach this one BEFORE — or instead of — the material row that
/// names it, and that device can still take it back: a publication whose
/// material save fails rolls its own blob row back and exports the deletion. A
/// card committed here against those bytes would then wait for iCloud for ever,
/// with nothing left to wait for. Pairing makes the card's own publication the
/// evidence; a device that cannot find one publishes its own blob instead, and
/// duplicate rows carrying identical bytes are an accepted state.
///
/// A nil `contentHash` is a row written before the pairing existed. It names no
/// particular blob, so the newest complete one answers for it — there are no
/// such rows in production, and the tolerance costs nothing.
nonisolated struct WorkMaterialBlobPairing: Sendable, Hashable {
    let contentHash: String?
    let byteSize: Int64

    init(contentHash: String?, byteSize: Int64) {
        self.contentHash = contentHash
        self.byteSize = byteSize
    }

    /// Whether this blob is the payload the material names. Stated once, here:
    /// selection, availability and adoption all ask it through this method, so
    /// the read path and the write path cannot start disagreeing about which
    /// blob belongs to a card.
    func names(_ blob: WorkMaterialBlobRecord) -> Bool {
        guard let contentHash, !contentHash.isEmpty else { return true }
        return blob.contentHash == contentHash && blob.byteSize == byteSize
    }
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
    /// The two materials a group mutation named are not a folded pair: the
    /// child names no picture, names a DIFFERENT one, is not a recording, or
    /// the id it names does not resolve to a picture that could hold it.
    ///
    /// Distinct from `invalidMaterialOwner`, which answers for the desk a
    /// material sits on. This one answers for the relationship between two
    /// materials on the SAME desk, and it is a refusal rather than a repair:
    /// a caller that cannot prove the pair may not delete either half.
    case invalidMaterialCompanion
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
                defaultValue: "That text is longer than \(limit) characters. Shorten it, then try again."
            )
        case .itemNotFound,
             .staleRevision,
             .materialNotFound,
             .materialPayloadUnavailable,
             .invalidMaterialOwner,
             .identifierCollision,
             .invalidMaterialCompanion:
            return nil
        }
    }
}
