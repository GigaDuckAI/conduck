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
// In-app capture may also publish an initial project placement in the material
// transaction. Replays preserve later user filing; a missing destination throws
// before insertion so callers can recover explicitly in All materials. Batches
// commit per card, preserving earlier filed captures if a later item fails.

import Foundation
import CoreData
import CryptoKit

// MARK: - Reorder rebase

/// The board a drag was planned on, as the store has to see it.
///
/// CANONICAL, never displayed. A folded pair is ONE card on screen and TWO
/// materials on disk, and a recording published before its picture is ranked
/// before it — so a board showing `other, picture` can stand over a stored
/// `recording, other, picture`. A baseline built from what was drawn would
/// disagree with the desk about an order nothing has changed.
nonisolated struct WorkboardReorderBaseline: Sendable, Hashable {
    /// Every logical material of the desk, in stored order, at plan time.
    let orderedIDs: [UUID]
    /// The picture each of those materials named, for the ones that named one.
    ///
    /// Ids alone cannot see a fold change. A recording arriving for a picture
    /// already on the board, or a picture arriving for a recording that was
    /// standing alone, both leave the baseline order intact as a prefix while
    /// silently repartitioning what the person is dragging between — so the
    /// links travel too, and either direction is a refusal.
    let attachments: [UUID: UUID]

    init(orderedIDs: [UUID], attachments: [UUID: UUID] = [:]) {
        self.orderedIDs = orderedIDs
        self.attachments = attachments
    }
}

/// Whether a drag planned on one board still means something on the board the
/// desk now holds, and if so what order to write.
///
/// A bare superset test — "every baseline id is still there" — is not enough
/// and was the defect this replaces: it passes on "somebody else reordered,
/// then something arrived", and writing the proposal then erases that reorder
/// without anybody seeing it happen. Requiring the baseline as a PREFIX is what
/// distinguishes an append from a rearrangement.
nonisolated enum WorkboardReorderRebase {
    /// The order to write, or nil when the desk has moved in a way this drag
    /// cannot be replayed onto.
    ///
    /// Conservative on purpose. A peer's material arriving with an earlier rank
    /// lands in the MIDDLE of the canonical order and is refused even though no
    /// old card changed places, because accepting it would need a placement
    /// rule for where the newcomer belongs relative to a rearrangement it never
    /// saw. A refusal is visible and costs one gesture; a wrong placement is
    /// invisible.
    static func rebased(
        proposed: [UUID],
        baseline: WorkboardReorderBaseline,
        current: [UUID],
        currentAttachments: [UUID: UUID]
    ) -> [UUID]? {
        let baselineIDs = baseline.orderedIDs
        let baselineSet = Set(baselineIDs)
        guard baselineSet.count == baselineIDs.count,
              Set(proposed).count == proposed.count,
              Set(proposed) == baselineSet else { return nil }
        guard Set(current).count == current.count,
              current.count >= baselineIDs.count,
              Array(current.prefix(baselineIDs.count)) == baselineIDs else { return nil }

        // A card the drag was planned on must still be the same MEMBER it was:
        // the same link, or the same absence of one.
        for id in baselineIDs where currentAttachments[id] != baseline.attachments[id] {
            return nil
        }

        let appended = Array(current.dropFirst(baselineIDs.count))
        // BOTH CANDIDATES OF EVERY LINK, because a raw id is not what the fold
        // resolves. `eligibleParentID` reads a link as the picture it names OR
        // as the one escape a colliding publication may have taken
        // (`WorkMaterialCollisionEscape`), so a check that compares raw ids
        // alone reads an escaped arrival as an unrelated newcomer while the
        // board quietly folds it into a card the drag was planned around.
        //
        // Refusing on the escape candidate can only over-refuse: this cannot
        // see the kind and ownership conditions the fold also applies, so a
        // derived id that happens to name an ineligible row costs one gesture,
        // where missing a real fold writes an order for a partition that no
        // longer exists.
        var named: Set<UUID> = []
        for target in baseline.attachments.values {
            named.insert(target)
            named.insert(WorkMaterialCollisionEscape.materialID(forCapture: target))
        }
        for id in appended {
            // A newcomer that folds INTO the dragged board, or that a dragged
            // card was already naming, changes which cards exist rather than
            // adding one after them.
            if let target = currentAttachments[id],
               baselineSet.contains(target)
                || baselineSet.contains(WorkMaterialCollisionEscape.materialID(forCapture: target)) {
                return nil
            }
            if named.contains(id) { return nil }
        }
        return proposed + appended
    }
}

#if CONDUCK_TESTING
/// One PHYSICAL `WorkMaterial` row, before deduplication collapses a
/// CloudKit-merged material to a single logical card. It carries the columns a
/// duplicate row can silently disagree about — its owner and its payload lane —
/// because whichever row wins the canonical read is what the person sees.
nonisolated struct WorkMaterialRowProbe: Sendable, Hashable {
    let workItemID: UUID?
    let sequence: Int32?
    let cardSize: String?
    let storageMode: String?
    let localVaultKey: String?
    /// The blob this row names on the synced lane. Per PHYSICAL row because a
    /// merged duplicate left naming another payload is exactly what the pairing
    /// has to make impossible.
    let contentHash: String?
    let byteSize: Int64?
    /// The picture this row's recording names. Per PHYSICAL row because the
    /// link decides whether the desk draws one card or two, and a duplicate
    /// that disagrees about it is the state the canonical ordering exists to
    /// settle.
    let attachedToMaterialID: UUID?
    let updatedAt: Date?
    /// Length of the presentation preview this row carries, never its bytes: a
    /// probe answers which rows got one, and a preview has no business crossing
    /// the actor boundary to be counted.
    let thumbnailByteCount: Int?
    /// The two columns a text write touches. The canonical read deduplicates,
    /// so a writer that reached one physical row and skipped a newer duplicate
    /// looks correct through the projection and is only visible here.
    let title: String?
    let textContent: String?
    let annotation: String?
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

/// What a capture knows about the row a material id it is re-publishing may
/// legitimately be parked under.
///
/// A build before the single desk hung captured materials off a per-capture
/// owner row, and re-homing those rows is what stops an upgrade replaying for
/// ever. But a material id alone is no evidence of that history: matching UUIDs
/// is all a desk capture would otherwise need to move — and, carrying bytes, to
/// overwrite the payload of — an unrelated card, including one whose owner row
/// CloudKit has not imported yet. So the caller states the capture this id
/// belongs to, and adoption proceeds only when the foreign owner row agrees.
nonisolated enum WorkMaterialLegacyProvenance: Sendable, Equatable {
    /// A share/import envelope being replayed.
    ///
    /// A pre-desk drain had TWO destinations for one envelope, and an upgrade
    /// meets both. With no explicitly chosen target it minted a Work item of its
    /// own and recorded the envelope's id on it. With a target the person had
    /// selected, it appended straight onto that item and wrote nothing on the
    /// owner row at all — so the envelope id identifies nothing there, and only
    /// the envelope's own `targetWorkItemID` can account for those rows.
    ///
    /// - Parameter legacyTargetWorkItemID: The item this envelope explicitly
    ///   named, when it named one. Nil for every targetless capture, which is
    ///   what the one-argument form below means.
    case captureEnvelope(UUID, legacyTargetWorkItemID: UUID?)
    /// A chat turn being re-captured. A pre-desk Chat → Work wrote the item
    /// under the message's own id AND recorded it as the capture envelope, so
    /// either column identifies it.
    case chatMessage(UUID)

    /// A replay of an envelope that named no target. Spelled as an overload so
    /// the two shapes read the same at a call site that has nothing to say
    /// about a target.
    static func captureEnvelope(_ id: UUID) -> Self {
        .captureEnvelope(id, legacyTargetWorkItemID: nil)
    }
}

/// Where a vault publication is being proved. The three sites commit different
/// shapes — a desk card, a card under an arbitrary owner, and a replacement over
/// a card that already had bytes — and each has its own answer to a leaf that
/// will not read back, so the proof is told which one is asking.
nonisolated enum WorkPublicationSite: Sendable {
    case deskPublish
    case arbitraryInsert
    case reattach
}

/// A capture whose card COMMITTED but whose payload the vault could not read
/// back afterwards.
///
/// It is a failure — nothing may report the capture durable, and the share
/// inbox must keep its copy — but the card is on the desk, reading
/// `.unavailableOnThisDevice`, so the error carries it. A caller that mints its
/// material id per attempt (a drop, a picked file) would otherwise retry under a
/// fresh id and leave the unreadable card standing beside the new one; carrying
/// the record lets it present and repair the card it already has.
nonisolated struct WorkMaterialCommittedUnavailableError: Error, Sendable {
    /// The card as it stands on the desk after the commit.
    let record: WorkMaterialRecord
}

/// What one bounded thumbnail-backfill pass did, so a caller (and a test) can
/// tell "there was nothing left to do" apart from "every candidate was refused".
/// The counts are LOGICAL cards, not physical rows: a card is one unit of work
/// however many rows CloudKit merged it into.
nonisolated struct WorkThumbnailRepairReport: Sendable, Equatable {
    /// Cards this pass attempted, after the permanently-undecodable ones were
    /// filtered out. Zero means the pass found nothing left to look at.
    let examined: Int
    /// Cards whose physical rows gained a preview in this pass.
    let filled: Int
    /// Cards whose bytes read back and are not an image. Remembered, so the
    /// next pass spends its window on the cards behind them.
    let undecodable: Int

    static let empty = WorkThumbnailRepairReport(examined: 0, filled: 0, undecodable: 0)
}

/// One legacy card the backfill may look at, named by the BYTES it claims
/// rather than by its id alone. The pairing is what makes a remembered failure
/// safe to keep: a reattach gives the card a different `contentHash`, so the
/// new payload gets its own attempt instead of inheriting the old verdict.
private nonisolated struct WorkThumbnailCandidate: Sendable, Hashable {
    let id: UUID
    let contentHash: String
    let byteSize: Int64
}

/// What reading and decoding one candidate's bytes settled.
private nonisolated enum WorkThumbnailDecodeOutcome: Sendable {
    case decoded(Data)
    /// The bytes are here and ImageIO will not make an image of them. That
    /// verdict is permanent for these bytes.
    case undecodable
    /// The blob has not landed on this device yet. Nothing is remembered: the
    /// bytes may still arrive, and a card that merely waited for iCloud must
    /// not be written off.
    case unavailable
}

/// Cards whose bytes this PROCESS has already proved undecodable, and the
/// exclusion that keeps two overlapping reconciles from decoding the same
/// window twice.
///
/// Process-lifetime rather than persisted, deliberately: a stored verdict would
/// be one more column on a model headed for CloudKit Production, and it could
/// never be withdrawn. Forgetting on relaunch costs one wasted decode per bad
/// card per launch, which is the cheaper mistake.
private actor WorkThumbnailBackfillMemory {
    private var undecodable: Set<WorkThumbnailCandidate> = []
    private var passesInFlight: Set<ObjectIdentifier> = []

    /// The candidates still worth decoding, in the order they were selected.
    func unresolved(_ candidates: [WorkThumbnailCandidate]) -> [WorkThumbnailCandidate] {
        candidates.filter { !undecodable.contains($0) }
    }

    func remember(_ candidate: WorkThumbnailCandidate) {
        undecodable.insert(candidate)
    }

    /// False while this store already has a pass running. Reconcile fires on
    /// appearance AND on every foreground, so without this a quick relaunch
    /// decodes the same window twice.
    func beginPass(_ store: ObjectIdentifier) -> Bool {
        passesInFlight.insert(store).inserted
    }

    func endPass(_ store: ObjectIdentifier) {
        passesInFlight.remove(store)
    }
}

private let workThumbnailBackfillMemory = WorkThumbnailBackfillMemory()

/// Cards one pass will read bytes for. The pass runs on a foreground reconcile,
/// so it has to finish in a moment and leave the rest to the next one.
private let workThumbnailRepairPassLimit = 96

/// Decodes in flight. ImageIO downsampling never suspends, so an unbounded
/// fan-out would hold every cooperative thread; and each job holds a
/// ceiling-sized payload while it runs, so the width is also the memory bound.
private let workThumbnailRepairDecodeWidth = 4

/// The preview bytes a row carries, digested ONCE and only if anything ever
/// asks.
///
/// Lazy because the ordering value is built for every material on every board
/// load, while the digest is consulted only when two physical rows of the SAME
/// card tie on every key before it — which is to say almost never. Hashing at
/// construction put a SHA-256 per card on the board's read path to answer a
/// question nobody was asking.
private final class WorkMaterialThumbnailDigest: @unchecked Sendable {
    private let lock = NSLock()
    private let data: Data?
    /// Outer nil means "not computed yet"; the inner optional is the answer.
    private var computed: String??

    init(data: Data?) {
        self.data = data
    }

    /// How much of a preview this row has, WITHOUT hashing anything: 0 for no
    /// column at all, 1 for a column that is present but empty, 2 for one with
    /// bytes in it.
    ///
    /// The ordering asks this BEFORE the digest, and that is not an
    /// optimisation. A digest is a hex string and orders lexicographically, so
    /// the hash of empty data — `e3b0c442…` — outranks plenty of real ones
    /// (`"one"` hashes to `7692…`). Ranking by digest alone therefore put an
    /// EMPTY preview above a real one, the exact opposite of what absence and
    /// emptiness are supposed to mean here. Emptiness is a tier, not a value.
    var presence: Int {
        guard let data else { return 0 }
        return data.isEmpty ? 1 : 2
    }

    /// `nil` for a row carrying no preview column at all. A column that is
    /// PRESENT but empty still has a digest — it is a real state of a row — but
    /// the ordering never compares it against a non-empty one, because
    /// `presence` has already separated them.
    var value: String? {
        lock.lock()
        defer { lock.unlock() }
        if let computed { return computed }
        let answer: String? = data.map { bytes in
            #if CONDUCK_TESTING
            WorkMaterialCanonicalOrder.recordDigestForTesting()
            #endif
            return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        }
        computed = answer
        return answer
    }

    /// Whether anything has asked yet. Test-facing: a board of singletons must
    /// never reach the hash.
    var hasComputed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return computed != nil
    }
}

/// The ONE total ordering of the physical rows behind one logical material.
///
/// TOTAL is the operative word. CloudKit cannot enforce Core Data uniqueness, so
/// one logical material can exist as several physical rows, and every reader has
/// to pick the same one — the board describing one duplicate while the payload,
/// the vault URL and the share gate answer from another is a card that shows one
/// thing and does another.
///
/// A tuple that can TIE does not achieve that on its own. Two readers reaching
/// for "the first of the equals" resolve a tie differently whenever their
/// candidate lists are ordered differently, and they are: the board sorts
/// materials by `(sequence, createdAt)` while a single-row read starts from a
/// timestamp-ordered fetch. Same rule, same rows, different answer — and a fully
/// tied fetch is not even stable against itself.
///
/// WHAT THE KEYS ARE. `revision` and `createdAt` first, then everything the
/// repository projects onto a card, then the row itself. The first four keys and
/// their order are fixed: changing them would change which duplicate an
/// already-decided card resolves to. Everything after exists to make ties
/// impossible, and each is a column two rows can genuinely differ on while
/// looking identical in the keys above it — the device-local lane names no blob,
/// so `contentHash` ties for two vault rows holding DIFFERENT bytes and
/// `localVaultKey` is what separates them; the lane, size, kind, text, address,
/// filename, mime type, caption, card size, companion link and preview each
/// drive availability or what the card draws.
///
/// `attachedToMaterialID` is here for the same reason as every other synced key
/// and one of its own: a duplicate pair that differs ONLY in the link would
/// otherwise be decided by `rowKey`, and `rowKey` is device-local — so one
/// device would draw the recording inside its picture while another drew two
/// cards, from the same two rows.
///
/// SYNCED VERSUS LOCAL. Every key except the last is a mirrored column, so two
/// devices compute the same value and agree on the winner without talking.
/// `rowKey` is the ONE device-local key and it is deliberately last: it can only
/// decide between rows that agree on every synced column, which no reader can
/// tell apart anyway.
///
/// EVERY COLUMN IS OPTIONAL IN THE MODEL, so every key carries presence rather
/// than a substituted default: absence sorts BELOW every present value,
/// including the empty string and zero, which are legitimate column values that
/// must not collide with "no column at all". `revision` is the one exception and
/// deliberately so — it IS the substituted value every reader compares
/// (`materialRevisionDate`), and giving it presence here would order rows
/// differently from the projection that reports them.
nonisolated struct WorkMaterialCanonicalOrder: Comparable, Sendable {
    /// `materialRevisionDate` — the substituted value, never the raw column.
    let revision: Date
    let createdAt: Date?
    let title: String?
    let contentHash: String?
    let localVaultKey: String?
    let storageMode: String?
    let byteSize: Int64?
    let kind: String?
    let textContent: String?
    let annotation: String?
    let urlString: String?
    let filename: String?
    let mimeType: String?
    let caption: String?
    let cardSize: String?
    /// The picture this row's recording names, if any.
    let attachedToMaterialID: UUID?
    /// The physical row, as a value. Unique by construction, which is what makes
    /// this ordering total — and DEVICE-LOCAL, which is why it is last.
    let rowKey: String

    /// `attachedToMaterialID` as an orderable, synced value. `UUID` states no
    /// `Comparable` conformance to rely on, and its canonical string is a fixed
    /// layout over `0-9A-F` — so two devices comparing this compare exactly the
    /// same characters in the same positions and reach the same verdict.
    private let attachedToKey: String?

    private let thumbnail: WorkMaterialThumbnailDigest

    init(
        revision: Date,
        createdAt: Date?,
        title: String?,
        contentHash: String?,
        localVaultKey: String?,
        storageMode: String?,
        byteSize: Int64?,
        kind: String?,
        textContent: String?,
        urlString: String?,
        filename: String?,
        mimeType: String?,
        caption: String?,
        cardSize: String?,
        attachedToMaterialID: UUID? = nil,
        thumbnailData: Data?,
        rowKey: String,
        annotation: String? = nil
    ) {
        self.revision = Self.ordered(revision) ?? .distantPast
        self.createdAt = Self.ordered(createdAt)
        self.title = title
        self.contentHash = contentHash
        self.localVaultKey = localVaultKey
        self.storageMode = storageMode
        self.byteSize = byteSize
        self.kind = kind
        self.textContent = textContent
        self.annotation = annotation
        self.urlString = urlString
        self.filename = filename
        self.mimeType = mimeType
        self.caption = caption
        self.cardSize = cardSize
        self.attachedToMaterialID = attachedToMaterialID
        attachedToKey = attachedToMaterialID?.uuidString
        self.rowKey = rowKey
        thumbnail = WorkMaterialThumbnailDigest(data: thumbnailData)
    }

    /// SHA-256 of the preview bytes, computed on first ask and kept. Reading it
    /// is what the digest exists for; nothing else should.
    var thumbnailDigest: String? { thumbnail.value }

    /// The preview tier — see `WorkMaterialThumbnailDigest.presence`. Free to
    /// read, and read before the digest.
    var previewPresence: Int { thumbnail.presence }

    /// The tier that has real bytes behind it, and therefore a digest worth
    /// comparing.
    static let previewPresent = 2

    /// Test-facing: whether this value has been asked for its digest yet.
    var hasComputedThumbnailDigest: Bool { thumbnail.hasComputed }

    static func < (lhs: WorkMaterialCanonicalOrder, rhs: WorkMaterialCanonicalOrder) -> Bool {
        if let decided = decide(lhs.revision, rhs.revision) { return decided }
        if let decided = decide(lhs.createdAt, rhs.createdAt) { return decided }
        if let decided = decide(lhs.title, rhs.title) { return decided }
        if let decided = decide(lhs.contentHash, rhs.contentHash) { return decided }
        if let decided = decide(lhs.localVaultKey, rhs.localVaultKey) { return decided }
        if let decided = decide(lhs.storageMode, rhs.storageMode) { return decided }
        if let decided = decide(lhs.byteSize, rhs.byteSize) { return decided }
        if let decided = decide(lhs.kind, rhs.kind) { return decided }
        if let decided = decide(lhs.textContent, rhs.textContent) { return decided }
        if let decided = decide(lhs.annotation, rhs.annotation) { return decided }
        if let decided = decide(lhs.urlString, rhs.urlString) { return decided }
        if let decided = decide(lhs.filename, rhs.filename) { return decided }
        if let decided = decide(lhs.mimeType, rhs.mimeType) { return decided }
        if let decided = decide(lhs.caption, rhs.caption) { return decided }
        if let decided = decide(lhs.cardSize, rhs.cardSize) { return decided }
        // The companion link, compared as its canonical string. Two rows that
        // agree on every key above and differ here are one recording imported
        // with and without its picture; deciding that by `rowKey` would make
        // the fold a device-local accident.
        if let decided = decide(lhs.attachedToKey, rhs.attachedToKey) { return decided }
        // LAST of the synced keys, and the only one that costs anything to read
        // — which is why every cheap key is asked first, and why even this key
        // is asked in two steps.
        //
        // The TIER first: no preview, an empty one, a real one. Comparing
        // digests alone got this backwards, because a digest is a hex string and
        // the hash of empty data outranks plenty of real ones.
        if let decided = decide(lhs.previewPresence, rhs.previewPresence) { return decided }
        // Only two rows that BOTH carry real preview bytes reach the hash.
        if lhs.previewPresence == WorkMaterialCanonicalOrder.previewPresent,
           let decided = decide(lhs.thumbnailDigest, rhs.thumbnailDigest) {
            return decided
        }
        return lhs.rowKey < rhs.rowKey
    }

    /// Derived from `<` rather than synthesised, for two reasons: the digest
    /// stays lazy (equality on the keys before it never reaches the hash), and
    /// the two operators cannot drift apart as keys are added.
    static func == (lhs: WorkMaterialCanonicalOrder, rhs: WorkMaterialCanonicalOrder) -> Bool {
        !(lhs < rhs) && !(rhs < lhs)
    }

    /// One key's verdict: `nil` when the two agree on it, otherwise the answer.
    /// Absence sorts BELOW every present value.
    private static func decide<Value: Comparable>(_ lhs: Value?, _ rhs: Value?) -> Bool? {
        switch (lhs, rhs) {
        case (nil, nil): return nil
        case (nil, _): return true
        case (_, nil): return false
        case (let left?, let right?): return left == right ? nil : left < right
        }
    }

    /// A date that can take part in a total order.
    ///
    /// `Date` comparison is `Double` comparison, and NaN is not ordered against
    /// anything — one NaN stamp would make the whole ordering intransitive and
    /// the "canonical" row would depend on comparison order again. A NaN is
    /// therefore treated as ABSENT, which is a position this ordering does
    /// define. It cannot arise from Core Data; it is guarded because the cost of
    /// being wrong is silent and the check is free.
    private static func ordered(_ date: Date?) -> Date? {
        guard let date else { return nil }
        guard !date.timeIntervalSinceReferenceDate.isNaN else {
            assertionFailure("a NaN date cannot take part in a total order")
            return nil
        }
        return date
    }

    #if CONDUCK_TESTING
    private static let digestCountLock = NSLock()
    nonisolated(unsafe) private static var digestCount = 0

    static func recordDigestForTesting() {
        digestCountLock.lock()
        defer { digestCountLock.unlock() }
        digestCount += 1
    }

    /// How many preview digests have been computed since the last reset. A
    /// board of cards with no duplicates must not move it.
    static var digestCountForTesting: Int {
        digestCountLock.lock()
        defer { digestCountLock.unlock() }
        return digestCount
    }

    static func resetDigestCountForTesting() {
        digestCountLock.lock()
        defer { digestCountLock.unlock() }
        digestCount = 0
    }
    #endif
}

extension ConversationStore {

    // MARK: - Work items

    #if CONDUCK_TESTING
    /// TEST SEAM — insert one inert Work item under an id the caller chooses.
    ///
    /// WHY IT HAS TO EXIST, AND WHY IT IS COMPILED OUT OF A SHIPPING BUILD.
    /// Work is one desk with a compile-time id, so nothing a person can do
    /// mints a second Work item; every capture surface publishes through
    /// `upsertDeskMaterial`. What a shipped build still MEETS is the rows a
    /// build before the single desk wrote — a per-capture owner row with
    /// materials hung off it — and the adoption path that re-homes them cannot
    /// be exercised without constructing that shape. Leaving an
    /// arbitrary-owner constructor in the shipping surface is what would let a
    /// future capture lane quietly mint a second board instead; under this flag
    /// the compiler, not a convention, is what forbids it.
    ///
    /// A caller-supplied id and `captureEnvelopeID` make a fixture idempotent
    /// without a Core Data unique constraint (CloudKit forbids one). Existing
    /// rows are returned untouched.
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
    #endif

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
    /// A RECORDING IS NOT CAPTURED. Chat legitimately carries audio, and Work
    /// keeps a recording only when the person adds one deliberately through the
    /// Work pane's own attachment button or a drop onto it. An audio attachment
    /// is therefore skipped here and counted on the receipt, so the turn's words
    /// and its other attachments still land and the caller can say what did not.
    /// Nothing is deleted: the recording stays in the chat, untouched.
    ///
    /// The message id is the note card's identity and every attachment keeps
    /// its own, so a retry after a process interruption repairs the same cards
    /// instead of publishing a second set — every attachment whose bytes this
    /// device still holds is republished on a repeat, because the store, not
    /// this lane, is what can tell a healthy card from one whose payload never
    /// landed. No Work item is minted: Chat → Work is a capture onto the one
    /// desk like every other surface, and `upsertDeskMaterial` decides desk
    /// identity, rank and idempotency. The turn's words are therefore always a
    /// card — the desk holds no brief field for a short turn to land in.
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
        var refused = 0

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
                    ),
                    legacyProvenance: .chatMessage(persistedMessage.id)
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
            // Refused BEFORE the desk is asked for anything, so no row, no
            // blob and no vault leaf is ever written for a recording. The
            // SHARED sniffer, so this door and the two that keep a recording
            // agree about what one is.
            guard !WorkCaptureEnvelope.isAudioPayload(
                mimeType: attachment.mimeType,
                typeIdentifier: nil,
                filename: attachment.filename
            ) else {
                refused += 1
                continue
            }
            let localPayload = payloads[attachment.id]
            let alreadyOnDesk = existingIDs.contains(attachment.id)
            // An attachment whose bytes this device still holds is republished
            // even when the desk already shows the card. `upsertDeskMaterial`
            // is what detects a payload that never landed — the blob half of a
            // publication interrupted by a crash, or a card whose bytes an
            // import has not brought yet — and restages it; skipping on the id
            // alone would report the turn as captured while its card stays
            // permanently unreadable. A healthy card takes the idempotent
            // no-op path instead. A card carrying no bytes has nothing to
            // repair, so it is still skipped.
            if alreadyOnDesk, localPayload == nil { continue }
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
            } else if let payload = localPayload {
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
                            defaultValue: "%@ could not be copied from this device. Reattach it in Work to open it."
                        ),
                        name
                    ),
                    storageMode: .metadataOnly,
                    sourceDevice: persistedMessage.sourceDevice,
                    createdAt: attachment.createdAt
                )
            }
            do {
                // The turn is what says where this attachment may have been
                // parked: a pre-desk capture hung both under an item named by
                // the message.
                _ = try await upsertDeskMaterial(
                    material,
                    legacyProvenance: .chatMessage(persistedMessage.id)
                )
                existingIDs.insert(attachment.id)
                // The counter keeps its meaning: cards this call put on the
                // desk. A repaired card was already there, and reporting it as
                // added would tell the person a second copy arrived.
                if !alreadyOnDesk { added += 1 }
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
            refusedMaterialCount: refused,
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
    /// second card. A build before the single desk parked those same ids under
    /// a per-capture owner row; a re-capture that can PROVE it is that same
    /// capture adopts its physical rows onto the desk rather than refusing
    /// them, because a refusal makes that capture fail on every replay for
    /// ever. The legacy owner row is left exactly where it is.
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
    /// CANCELLATION. A capture the person cancelled mid-flight must not land,
    /// and the check that decides it belongs at the MUTATION BOUNDARY inside the
    /// transaction — not at the caller. Everything between a caller's own check
    /// and this write can suspend for an unbounded time: the desk and material
    /// claims above spin, `ensureLoaded()` opens a store on first use, and the
    /// bytes are staged before the transaction opens. A press landing anywhere
    /// in there is answered here, where the row would otherwise be written, and
    /// `Task.isCancelled` cannot serve: inside a `context.perform` closure it
    /// answers about the queue's own task and reads `false` however hard the
    /// person pressed. Everything this call staged is taken back on the way out,
    /// exactly as a refusal is.
    ///
    /// - Parameter repairPayload: Bytes the caller still holds for a material
    ///   that already exists but cannot produce its payload. Falls back to
    ///   `draft.payload`, so an ordinary replay needs no second copy.
    /// - Parameter legacyProvenance: The capture this material id belongs to,
    ///   from a caller that knows it — the chat turn, or the share envelope
    ///   being replayed. It is the ONLY thing that licenses adoption of rows
    ///   parked under another owner; a caller that mints ids of its own passes
    ///   nil and a foreign owner is then refused outright.
    /// - Parameter expectedOwnerRevision: Compare-and-swap token supplied ONLY
    ///   by the view model's serialized board path, which knows which revision
    ///   the person was looking at. Every headless caller — drainer, App
    ///   Intent, chat capture — passes nil: none of them holds board state to
    ///   guard, and a refusal there would drop a capture the person already
    ///   made. Supplied against a desk that does not exist yet, it is refused:
    ///   a token for an absent row cannot be honestly compared.
    /// - Parameter authorization: The cancellation a Work voice capture's own
    ///   surface can still revoke while this write is in flight. Nil for every
    ///   caller with nothing to cancel, which is every caller but that lane.
    /// - Parameter projectID: The in-app destination frozen at capture launch.
    ///   A new card and its placement share one save, closing the crash window
    ///   between capture and filing. Existing cards never have their placement
    ///   changed by replay or payload repair: later user filing wins. A missing
    ///   project throws `projectNotFound` before insertion so the caller can
    ///   explicitly recover the capture in All materials and explain it.
    func upsertDeskMaterial(
        _ draft: WorkMaterialDraft,
        sourceFileURL: URL? = nil,
        sourceFileByteSize: Int64? = nil,
        repairPayload: Data? = nil,
        legacyProvenance: WorkMaterialLegacyProvenance? = nil,
        expectedOwnerRevision: Int64? = nil,
        authorization: WorkVoiceWriteAuthorization? = nil,
        projectID: UUID? = nil,
        resultSource: WorkDeskResultRecord? = nil,
        onProgress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> WorkMaterialRecord {
        try await publishWorkMaterial(
            draft,
            sourceFileURL: sourceFileURL,
            sourceFileByteSize: sourceFileByteSize,
            repairPayload: repairPayload,
            legacyProvenance: legacyProvenance,
            expectedOwnerRevision: expectedOwnerRevision,
            authorization: authorization,
            projectID: projectID,
            resultSource: resultSource,
            onProgress: onProgress
        )
        guard let record = try await fetchWorkMaterial(id: draft.id) else {
            throw WorkboardStoreError.materialNotFound
        }
        return record
    }

    /// The draft and bytes the desk actually publishes: the picture sized for
    /// the desk by `WorkMaterialImagePolicy`, or exactly what the caller handed
    /// over when the policy leaves it alone. On a normalisation the JPEG
    /// travels as `payload` and the file source is dropped, so staging measures
    /// the bytes it will store rather than comparing them with a length the
    /// capture declared for a file that is no longer the payload. Static so the
    /// policy's `@concurrent` work is awaited off this actor.
    private static func sizedForDesk(
        _ draft: WorkMaterialDraft,
        repairPayload: Data?,
        sourceFileURL: URL?,
        sourceFileByteSize: Int64?,
        existing: WorkMaterialRecord?
    ) async throws -> (
        draft: WorkMaterialDraft,
        payload: Data?,
        sourceFileURL: URL?,
        sourceFileByteSize: Int64?
    ) {
        let payload = repairPayload ?? draft.payload
        switch try await WorkMaterialImagePolicy.prepare(
            kind: draft.kind,
            payload: payload,
            sourceFileURL: sourceFileURL,
            declaredByteCount: sourceFileByteSize ?? draft.byteSize,
            existing: existing
        ) {
        case .normalised(let jpeg, _, _):
            return (draft.normalisedImage(jpeg: jpeg), jpeg, nil, nil)
        case .unchanged(.alreadyConforming):
            // The bytes ARE a JPEG of the desk's shape; only the capture's
            // names may still say otherwise. They follow the bytes, the bytes
            // stay exactly where they are.
            return (draft.renamedAsJPEG(), payload, sourceFileURL, sourceFileByteSize)
        case .unchanged:
            return (draft, payload, sourceFileURL, sourceFileByteSize)
        }
    }

    // MARK: - Materials

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
        /// This call inserted THIS row, named by its permanent object id. Only
        /// this call may delete it again: it knows the material never landed,
        /// which a background pass never can. The identity is the row rather
        /// than its `(materialID, contentHash, byteSize)` columns because those
        /// carry no uniqueness — a peer's import or a concurrent publication of
        /// the same bytes matches them too.
        case inserted(rowID: NSManagedObjectID)
    }

    /// What the single write transaction actually did, so the vault's staged-key
    /// guard and the change notification follow the database rather than the
    /// caller's intent.
    private nonisolated struct WorkMaterialWriteOutcome: Sendable {
        let insertedMaterial: Bool
        let repairedMaterial: Bool
        /// Physical rows of this material were re-homed from a legacy owner
        /// onto the desk. The card is new to the board even though no row was
        /// inserted, so the board has to be told.
        let adoptedMaterial: Bool
        let createdOwner: Bool
        /// Vault key the surviving material row names, which decides whether
        /// bytes staged by this call are referenced or garbage.
        let existingVaultKey: String?
        /// Whether a physical row of the card names the synced bytes this call
        /// staged, read after the transaction repointed what it may. False only
        /// for a stale replay against rows that were all newer and all kept
        /// their own pairing — the one case in which a blob this call inserted
        /// is named by nothing and is taken back.
        let stagedPayloadIsNamed: Bool
    }

    /// The shared write behind `upsertDeskMaterial`. Bytes are staged before
    /// the transaction opens, so a preparation failure never leaves a
    /// half-published card; the transaction then resolves the desk row, the
    /// material, its initial project placement and any payload repair in ONE
    /// save. Each batch item keeps its own transaction, so a later refusal
    /// leaves earlier cards durably filed without rolling their captures back.
    ///
    /// THREE mutexes cover the whole call, staging included. The DESK claim
    /// orders captures onto one board — vault keys are derived from the
    /// material id, so two replays of one capture would otherwise stream into
    /// the same leaf at once and interleave their bytes. The MATERIAL claim
    /// additionally orders this call against a reattach of the same card, which
    /// holds no desk claim: without it a reattach can insert a blob, suspend,
    /// and have this call adopt that blob (`.alreadyPresent`) and commit a card
    /// naming bytes the reattach's own rollback then deletes. Both are
    /// in-process; the PUBLICATION LOCK is the same exclusion between the app
    /// and the headless intent process, which share this store and mint the
    /// same deterministic capture ids. Acquisition order is desk, then
    /// material, then lock in this path and material-then-lock in the reattach,
    /// so there is no cycle. Serializing costs a wait; a card that loses its
    /// payload cannot be undone.
    private func publishWorkMaterial(
        _ incoming: WorkMaterialDraft,
        sourceFileURL incomingSourceFileURL: URL?,
        sourceFileByteSize incomingSourceFileByteSize: Int64?,
        repairPayload: Data?,
        legacyProvenance: WorkMaterialLegacyProvenance?,
        expectedOwnerRevision: Int64?,
        authorization: WorkVoiceWriteAuthorization?,
        projectID: UUID?,
        resultSource: WorkDeskResultRecord?,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws {
        if let annotation = incoming.annotation,
           annotation.count > WorkItemContentLimits.maximumFieldCharacters {
            throw WorkboardStoreError.contentTooLong
        }
        if let resultSource,
           resultSource.materialID != incoming.id || resultSource.projectID != projectID {
            throw WorkboardStoreError.invalidMaterialOwner
        }
        let ownerID = Constants.workboardDeskItemID

        while workInitialMaterialClaims.contains(ownerID) {
            try await Task.sleep(for: .milliseconds(40))
        }
        workInitialMaterialClaims.insert(ownerID)
        defer { workInitialMaterialClaims.remove(ownerID) }

        while workMaterialPublicationClaims.contains(incoming.id) {
            try await Task.sleep(for: .milliseconds(40))
        }
        workMaterialPublicationClaims.insert(incoming.id)
        defer { workMaterialPublicationClaims.remove(incoming.id) }

        try await ensureLoaded()

        // The same exclusion across PROCESSES, taken before anything is staged
        // or any blob is looked up and released only when this whole call is
        // done — the confirmation and every rollback included. It is what makes
        // "the blob row I inserted is the only blob row I may delete" true
        // between the app and the headless intent process, which share this
        // store and mint the same deterministic capture ids.
        let publicationHold = try await workMaterialPublicationLock?.acquire(
            materialID: incoming.id
        )
        defer { publicationHold?.release() }

        let existing = try await fetchWorkMaterial(id: incoming.id)
        // The receipt outlives a deleted card. Preserve deletion, but let the
        // normal revision-aware repair restore a still-existing card's bytes.
        var hasResultReceipt = false
        if resultSource != nil { hasResultReceipt = try await hasWorkDeskResult(incoming.id) }
        if hasResultReceipt, existing == nil { return }
        let newResultSource = hasResultReceipt ? nil : resultSource
        // A material id names ONE card, and a capture whose id already names a
        // card of another KIND is a collision, not a replay of it — wherever
        // that card sits, the desk included. Refused here, before anything is
        // staged, because staging is what does the damage: a vault leaf is
        // keyed by the material id, so the colliding card's bytes would be
        // overwritten on disk, and on the synced lane the repair branch would
        // publish these bytes over that card's payload and retire the blob it
        // was using. Every PHYSICAL row is checked again inside the
        // transaction, which is where the answer is authoritative.
        if let existing, existing.kind != incoming.kind {
            throw WorkboardStoreError.invalidMaterialOwner
        }
        // THE ONE PLACE A PICTURE IS SIZED FOR THE DESK. Every lane's image
        // lands here, so the cap is enforced by construction on the lanes that
        // have no UI to shrink from — the share inbox, the Shortcut, a paste.
        // Decided AFTER the existing card is known and BEFORE anything is
        // staged, because the policy's one data-safety rule needs the card: a
        // replay must reproduce the representation the row already names, or
        // the hash pairing below would retire a healthy blob as superseded.
        // Everything downstream — the repair lane, staging, the preview, the
        // transaction — reads the sized values and never the caller's.
        let sized = try await Self.sizedForDesk(
            incoming,
            repairPayload: repairPayload,
            sourceFileURL: incomingSourceFileURL,
            sourceFileByteSize: incomingSourceFileByteSize,
            existing: existing
        )
        let draft = sized.draft
        let sourceFileURL = sized.sourceFileURL
        let sourceFileByteSize = sized.sourceFileByteSize
        let carriedPayload = sized.payload
        let carriesBytes = carriedPayload != nil || sourceFileURL != nil
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

        // THE ONE PLACE A CAPTURED IMAGE GETS ITS PREVIEW. Every in-app
        // ingress — picker, drop, camera, the share/Shortcut drainer, chat
        // capture — lands here, so decoding once at this point is what gives
        // all of them a card that renders its own artwork instead of a type
        // glyph. Outside the write context on purpose: ImageIO never suspends,
        // and holding a Core Data transaction open across it would block every
        // other writer for the length of a decode.
        //
        // SYNCED LANE ONLY, because that is the only lane whose preview may be
        // persisted: the row is CloudKit-mirrored, so a thumbnail on a
        // device-local card would export file content the vault exists to keep
        // off the shared model. A vault image draws its preview transiently
        // instead, per board load, in the live repository.
        //
        // Only when NOTHING already answers for it: a draft that carries its
        // own thumbnail keeps it, and a replay against a card that already
        // exists writes no columns here at all — the repair paths repoint
        // bytes, they do not re-apply the draft.
        let publishedThumbnail: Data?
        if existing == nil,
           draft.kind == .image,
           draft.thumbnailData == nil,
           staged?.storageMode == .syncedPayload {
            publishedThumbnail = await Self.imagePresentationThumbnail(
                payload: carriedPayload,
                sourceFileURL: sourceFileURL
            )
        } else {
            publishedThumbnail = nil
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

        #if CONDUCK_TESTING
        // Inside the publication lock, between the two durable steps — the one
        // window in which a successor could adopt bytes this call can still take
        // back. See the seam's declaration for why nothing observable stands in
        // for it.
        await workMaterialPublicationLockHoldForTesting?(draft.id)
        #endif

        // STEP 2 OF THE PUBLICATION.
        let context = newWriteContext()
        let outcome: WorkMaterialWriteOutcome
        do {
            // New project membership joins deletion's queue only for the final
            // material save. Slow sizing/staging does not block desk gestures.
            // Material -> organization is the acquisition order on both paths.
            if projectID != nil { await acquireWorkDeskMutation() }
            defer { if projectID != nil { releaseWorkDeskMutation() } }
            let organizationHold = projectID != nil
                ? try await workMaterialPublicationLock?.acquireOrganization() : nil
            defer { organizationHold?.release() }
            outcome = try await context.perform { [context] () -> WorkMaterialWriteOutcome in
                // THE MUTATION BOUNDARY, and the last place a cancel can still
                // mean something. Everything above this line — the two claims,
                // the publication lock, `ensureLoaded()`, the sizing pass, the
                // staging, the blob save — can suspend, and a press that landed
                // in any of it is a promise about a card that must not exist.
                // Taken before the desk row is even resolved, because
                // `insertDeskRow` is itself a mutation. It THROWS rather than
                // reporting an outcome: nothing was attempted, so there is no
                // publication to report, and the `catch` below reclaims the
                // vault leaf and the blob row this call had already written.
                if authorization?.isCancelled == true { throw CancellationError() }
                var createdOwner = false
                let ownerRow: NSManagedObject
                if let row = try Self.workItemRow(id: ownerID, in: context) {
                    ownerRow = row
                } else {
                    guard expectedOwnerRevision == nil else {
                        throw WorkboardStoreError.staleRevision
                    }
                    ownerRow = Self.insertDeskRow(in: context)
                    createdOwner = true
                }

                if let expectedOwnerRevision {
                    guard let updatedAt = ownerRow.value(forKey: "updatedAt") as? Date,
                          Self.workRevision(for: updatedAt) == expectedOwnerRevision else {
                        throw WorkboardStoreError.staleRevision
                    }
                }

                let now = Date()
                if let resultSource = newResultSource {
                    // Same publication lock and transaction as the material;
                    // another process cannot land a receipt between these writes.
                    try Self.insertWorkDeskResult(resultSource, in: context)
                }
                let materialRows = try Self.workMaterialRows(id: draft.id, in: context)
                if let resultSource = newResultSource {
                    for row in materialRows {
                        row.setValue(resultSource.isRemoteReference ? "reference" : "file", forKey: "projectResultKind")
                    }
                }
                // Before anything else this transaction does with them: every
                // physical row this id names has to be the same kind of card
                // this capture is publishing, whoever owns it.
                try Self.requireMatchingKind(materialRows: materialRows, kind: draft.kind)
                // WHICH ROWS THIS PUBLICATION MAY REPOINT, read BEFORE the
                // transaction stamps any of them.
                //
                // A replay is not necessarily the newest thing that happened to
                // this card. The drainer replays an envelope captured minutes
                // ago, and the voice lane republishes a recording parked before
                // that; meanwhile another device can have reattached a NEW file
                // onto the same card, whose row arrives here ahead of its blob.
                // Normalising that row onto the replay's older bytes would
                // silently replace the person's newer file — and export the
                // replacement. So a row is only brought back onto these bytes
                // when it is NOT newer than the material this call is
                // publishing; a newer pairing is left waiting for its own blob,
                // which is what turns it `.synced` on its own.
                //
                // `draft.createdAt` is that timestamp: the envelope's
                // `createdAt` for the drainer, the recording's for a retry, the
                // chat turn's for a re-capture, and `Date()` for anything the
                // person is doing right now — so a fresh publication still
                // normalises every row, and only a stale one holds back.
                //
                // Read here rather than at the repair because ADOPTION below
                // stamps `now` on every re-homed row: a row this same call just
                // touched would otherwise read as a later publication than
                // itself and never be repaired.
                let publicationDate = draft.createdAt
                let rowsNotNewerThanThisPublication = materialRows.filter { row in
                    guard let stamp = row.value(forKey: "updatedAt") as? Date else { return true }
                    return stamp <= publicationDate
                }
                var adopted = false
                if !materialRows.isEmpty {
                    let owners = Set(
                        materialRows.compactMap { $0.value(forKey: "workItemID") as? UUID }
                    )
                    if owners != [ownerID] {
                        // LEGACY-OWNER ADOPTION. A build before the single desk
                        // stored a chat turn, its attachments and a partially
                        // drained envelope's entries as materials under a
                        // per-capture owner row, and those owner rows are
                        // deliberately kept rather than migrated. A re-capture
                        // that can prove it is that same capture therefore
                        // re-homes its physical rows onto the desk instead of
                        // refusing them: refusing makes the capture fail for
                        // good — the drainer replays the same envelope forever
                        // and the chat banner reports a card it can never
                        // publish. There is no background sweep, and the owner
                        // row left behind is never deleted, because deleting a
                        // valid CloudKit record exports that deletion to every
                        // other device.
                        //
                        // MATCHING UUIDS ARE NOT THAT PROOF. On the id alone a
                        // capture would re-home — and, carrying bytes, replace
                        // the payload of — a card that merely shares its
                        // identifier, including one whose own owner row this
                        // device has not imported yet. So the caller's stated
                        // provenance has to agree with every foreign owner row.
                        // (That the rows are the same KIND of card is settled
                        // above, for every row and every owner.)
                        try Self.requireAdoptable(
                            materialRows: materialRows,
                            deskID: ownerID,
                            provenance: legacyProvenance,
                            in: context
                        )
                        // One logical card holds one rank across every physical
                        // row, so a stray joins the rank its desk-side twin
                        // already has rather than minting a second one.
                        let rank: Int
                        if let twin = materialRows.first(where: {
                            $0.value(forKey: "workItemID") as? UUID == ownerID
                        }), let twinRank = (twin.value(forKey: "sequence") as? NSNumber)?.intValue {
                            rank = twinRank
                        } else {
                            rank = try Self.appendRank(forWorkItemID: ownerID, in: context)
                        }
                        for row in materialRows
                        where row.value(forKey: "workItemID") as? UUID != ownerID {
                            row.setValue(ownerID, forKey: "workItemID")
                            row.setValue(NSNumber(value: Int32(clamping: rank)), forKey: "sequence")
                            row.setValue(now, forKey: "updatedAt")
                            adopted = true
                        }
                        // A card joined the board, so the desk moved.
                        ownerRow.setValue(now, forKey: "updatedAt")
                    }
                    // CloudKit can materialize one logical material as several
                    // physical rows. Every one of them must name the bytes that
                    // just landed, or a later merge picks a row that still
                    // points at nothing.
                    var repaired = false
                    var stagedPayloadIsNamed = true
                    if let staged, let repairLane {
                        switch repairLane {
                        case .localVault:
                            if staged.storageMode == .localVault,
                               let repairedKey = staged.vaultKey {
                                // The lane is written along with the key, so a
                                // duplicate row that drifted onto the synced
                                // lane cannot keep claiming bytes the card no
                                // longer keeps there.
                                for row in materialRows {
                                    Self.pointAtLocalVault(
                                        row: row,
                                        vaultKey: repairedKey,
                                        byteSize: staged.byteSize,
                                        at: now
                                    )
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
                                //
                                // EXCEPT the blob a row this publication may NOT
                                // repoint still names. A replay that is older
                                // than a reattach on this card carries bytes the
                                // person has since replaced, and staging them
                                // must not retire the replacement: the newer row
                                // keeps naming it (below), so the blob it names
                                // has to survive this sweep too, or the card
                                // ends up pointing at nothing.
                                let pairingsNewerRowsName = materialRows
                                    .filter { !rowsNotNewerThanThisPublication.contains($0) }
                                    .compactMap { row -> (contentHash: String, byteSize: Int64)? in
                                        guard row.value(forKey: "storageMode") as? String
                                                == WorkMaterialStorageMode.syncedPayload.rawValue,
                                              let hash = row.value(forKey: "contentHash") as? String,
                                              let size = (row.value(forKey: "byteSize") as? NSNumber)?.int64Value
                                        else { return nil }
                                        return (hash, size)
                                    }
                                let superseded = try Self.deleteSupersededBlobRows(
                                    materialID: draft.id,
                                    keepingContentHash: contentHash,
                                    byteSize: staged.byteSize,
                                    protecting: pairingsNewerRowsName,
                                    in: context
                                )
                                // WHAT THE ROWS SAY DECIDES, NOT WHAT THIS CALL
                                // WROTE. An insertion or a superseded deletion
                                // says this publication changed the payload
                                // STORE; neither says anything about the
                                // physical rows. Two devices can publish
                                // different bytes under one material id, so a
                                // merge leaves rows naming different blobs, and
                                // the row naming the blob that never arrived
                                // keeps the card waiting for iCloud whenever it
                                // wins the canonical read. A replay carrying
                                // exactly these bytes would otherwise repair
                                // nothing: its blob is already here
                                // (`.alreadyPresent`, nothing inserted) and the
                                // blob the other row names is absent rather
                                // than superseded (nothing deleted), so the
                                // disagreement would survive every replay.
                                //
                                // ONLY over the rows this publication may
                                // repoint. A row newer than the material being
                                // replayed is another device's later
                                // publication, not a stale duplicate: it names
                                // bytes whose blob is still on its way, and
                                // dragging it onto these older bytes would
                                // throw away the file the person put there
                                // last.
                                let rowsDisagree = rowsNotNewerThanThisPublication.contains { row in
                                    !Self.namesSyncedPayload(
                                        row: row,
                                        contentHash: contentHash,
                                        byteSize: staged.byteSize
                                    )
                                }
                                if case .inserted = publishedBlob {
                                    repaired = true
                                } else if superseded > 0 {
                                    repaired = true
                                }
                                if rowsDisagree { repaired = true }
                                if repaired {
                                    for row in rowsNotNewerThanThisPublication {
                                        Self.pointAtSyncedPayload(
                                            row: row,
                                            contentHash: contentHash,
                                            byteSize: staged.byteSize,
                                            at: now
                                        )
                                    }
                                }
                                // Read AFTER the repoint: whether any physical
                                // row of this card now names the bytes this
                                // call staged. When none does — every row was
                                // newer than the replay and kept its own
                                // pairing — the blob this call inserted is
                                // named by nothing, and the caller takes it
                                // back rather than leaving a stray.
                                stagedPayloadIsNamed = materialRows.contains { row in
                                    Self.namesSyncedPayload(
                                        row: row,
                                        contentHash: contentHash,
                                        byteSize: staged.byteSize
                                    )
                                }
                            }
                        case .metadataOnly:
                            break
                        }
                    }
                    if createdOwner || repaired || adopted || newResultSource != nil { try context.save() }
                    return WorkMaterialWriteOutcome(
                        insertedMaterial: false,
                        repairedMaterial: repaired,
                        adoptedMaterial: adopted,
                        createdOwner: createdOwner,
                        existingVaultKey: materialRows.compactMap {
                            $0.value(forKey: "localVaultKey") as? String
                        }.first,
                        stagedPayloadIsNamed: stagedPayloadIsNamed
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
                // Only the insert lane may apply a capture destination. Every
                // replay/adoption/repair above keeps the person's later filing.
                // The helper validates before creating either placement or
                // material; a missing project follows the existing staged-byte
                // rollback and gives the caller an explicit recovery outcome.
                if let projectID {
                    try Self.placeNewDeskCapture(draft.id, projectID: projectID, in: context)
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
                    contentHash: staged.contentHash,
                    // Decoded above, outside this transaction. It is handed in
                    // rather than folded into the draft so the draft stays the
                    // caller's statement of the capture and this stays the
                    // store's own derivation from the bytes it staged.
                    thumbnailData: publishedThumbnail,
                    // Rank is decided here rather than by the caller: a headless
                    // capture cannot know how many cards the desk already holds,
                    // and reading the count outside this transaction would race
                    // the write it is meant to order.
                    sequence: try Self.appendRank(forWorkItemID: ownerID, in: context),
                    updatedAt: now,
                    to: row
                )
                if let resultSource = newResultSource {
                    row.setValue(resultSource.isRemoteReference ? "reference" : "file", forKey: "projectResultKind")
                }
                ownerRow.setValue(now, forKey: "updatedAt")
                try context.save()
                return WorkMaterialWriteOutcome(
                    insertedMaterial: true,
                    repairedMaterial: false,
                    adoptedMaterial: false,
                    createdOwner: createdOwner,
                    existingVaultKey: staged.vaultKey,
                    stagedPayloadIsNamed: true
                )
            }
        } catch {
            if let key = staged?.vaultKey { try? await workAssetVault.remove(key) }
            if case .inserted(let rowID) = publishedBlob {
                // The ONE place a blob may be deleted without its material.
                // This call inserted that exact row moments ago and knows the
                // card never landed, so it names nothing; a background sweep
                // cannot tell that state from a blob CloudKit imported ahead of
                // the material it belongs to, which is why no sweep exists.
                await deleteBlobRow(rowID)
            }
            throw error
        }

        if case .inserted(let rowID) = publishedBlob, !outcome.stagedPayloadIsNamed {
            // A stale replay: every row of this card was newer than the capture
            // being replayed and kept the bytes the person put there last, so
            // the blob this call wrote a moment ago is named by nothing. The
            // same rule as a refusal — this call inserted that exact row and
            // knows no card took it, which a sweep never could.
            await deleteBlobRow(rowID)
        }

        // STEP 3 of the publication protocol: the row naming this leaf has
        // committed, so the leaf itself has to read back before the capture may
        // be reported durable. A vault reclamation running in another process
        // between the copy and this save is exactly what the staging guard
        // exists to stop, and a publication it did not stop must surface as a
        // failure rather than as a card promising bytes the vault cannot serve.
        // A refusal KEEPS the guard, so the next reclamation cannot delete what
        // is left of the evidence.
        var publicationIsDurable = true
        if let key = staged?.vaultKey, let staged {
            if outcome.insertedMaterial
                || outcome.repairedMaterial
                || key == outcome.existingVaultKey {
                publicationIsDurable = await confirmVaultPublication(
                    site: .deskPublish,
                    materialID: draft.id,
                    key: key,
                    expectedByteCount: staged.byteSize
                )
            } else {
                try? await workAssetVault.remove(key)
            }
        }
        if outcome.insertedMaterial
            || outcome.repairedMaterial
            || outcome.adoptedMaterial
            || outcome.createdOwner || newResultSource != nil {
            await postDidChange()
        }
        guard publicationIsDurable else {
            // The card stays on the desk reading `.unavailableOnThisDevice`:
            // a replay of this same capture repairs it, and the drainer's
            // durability barrier keeps the queue copy until one does. The
            // committed card rides the error so a caller that minted this id
            // for this attempt repairs it instead of publishing a second one.
            throw await committedUnavailable(materialID: draft.id)
        }
    }

    /// Prove a published vault leaf, and report whether it may be called
    /// durable. Every `confirmPublication` in this file goes through here, so
    /// the measured size a write reported is what the proof compares against and
    /// a test can stand in the one window that is otherwise unreachable.
    private func confirmVaultPublication(
        site: WorkPublicationSite,
        materialID: UUID,
        key: String,
        expectedByteCount: Int64
    ) async -> Bool {
        #if CONDUCK_TESTING
        if let hook = publicationConfirmationHookForTesting,
           let forced = await hook(site, materialID, key, expectedByteCount) {
            return forced
        }
        #endif
        return await workAssetVault.confirmPublication(
            of: key,
            expectedByteCount: expectedByteCount
        )
    }

    /// The failure a committed-but-unprovable payload raises, carrying the card
    /// that is on the desk. Falls back to the plain error only if the row it
    /// just wrote cannot be read back, which is a different failure entirely.
    private func committedUnavailable(materialID: UUID) async -> Error {
        guard let record = try? await fetchWorkMaterial(id: materialID) else {
            return WorkboardStoreError.materialPayloadUnavailable
        }
        return WorkMaterialCommittedUnavailableError(record: record)
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
        let write = try await workAssetVault.store(
            bytes: payload,
            id: vaultID,
            suggestedExtension: suggestedExtension
        )
        onProgress(1)
        return StagedWorkMaterialBytes(
            storageMode: .localVault,
            // The length the LEAF holds, measured from disk by the write — not
            // the caller's declared size, which is a claim about bytes it may
            // never have handed over. The row records this number, and it is
            // what `confirmPublication` compares a truncated leaf against.
            byteSize: write.byteCount,
            vaultKey: write.key
        )
    }

    /// The small JPEG preview a synced image card carries, or nil when these
    /// bytes are not an image ImageIO can read.
    ///
    /// `@concurrent` is load-bearing, not tidiness. This is called from the
    /// store's own actor, and a plain `nonisolated async` function runs on its
    /// caller's executor — so the decode would happen ON the store, holding
    /// every queued read and write behind an uninterruptible ImageIO pass. This
    /// spelling is what puts it on the concurrent pool.
    ///
    /// A file URL is preferred over bytes in hand: `thumbnailOnly(fromFileAt:)`
    /// downsamples straight from disk, so a 100 MB capture never has to be
    /// mapped whole to produce a 256-pixel preview.
    @concurrent
    private nonisolated static func imagePresentationThumbnail(
        payload: Data?,
        sourceFileURL: URL?
    ) async -> Data? {
        if let sourceFileURL,
           let thumbnail = ImageProcessor.thumbnailOnly(fromFileAt: sourceFileURL) {
            return thumbnail
        }
        guard let payload else { return nil }
        return ImageProcessor.thumbnailOnly(from: payload)
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
    /// A blob already on this device is ADOPTED — nothing is written and there
    /// is nothing to take back — only when a committed material row for this id
    /// already names exactly these bytes. A row of bytes alone licenses nothing:
    /// it can be another device's publication whose material save then failed,
    /// and that device's rollback deletes the row and exports the deletion, so a
    /// card committed here against it would wait for iCloud for ever. Where
    /// there is no such card, this call publishes its OWN row, and rows carrying
    /// identical bytes for one material are an accepted state, resolved by the
    /// same newest-matching read that resolves a CloudKit merge.
    /// `WorkMaterialBlobPairing` states the whole rule.
    ///
    /// THE BOUND ON THOSE ROWS, STATED ACCURATELY: it is not a count. Every
    /// attempt that dies between this save and the material save — a crash or a
    /// jetsam, since a REFUSAL takes its own row back by object id — strands one
    /// more row, and the attempt after it strands another, because there is
    /// still no card to license adoption. `deleteSupersededBlobRows` never
    /// retires them: it deletes rows carrying OTHER bytes, and these carry the
    /// bytes the card eventually names. What retires them is the next
    /// publication or reattach putting DIFFERENT bytes on this card, and paired
    /// deletion when the card goes. So the bound is persistence, not arithmetic:
    /// one row per interrupted attempt, each at most the sync ceiling, standing
    /// until one of those two happens.
    ///
    /// NO SWEEP MAY CLOSE THAT. A pass over "blobs no card names" cannot tell
    /// this device's stranded attempt from a peer's blob that CloudKit imported
    /// ahead of the material naming it, and deleting the second exports the
    /// deletion of a payload that was merely early.
    ///
    /// Both halves read METADATA only — realizing blob rows to compare them
    /// would fault a ceiling-sized payload in to answer a question about its
    /// hash.
    private func publishWorkMaterialBlob(
        materialID: UUID,
        payload: Data,
        byteSize: Int64,
        contentHash: String
    ) async throws -> WorkMaterialBlobPublication {
        let pairing = WorkMaterialBlobPairing(contentHash: contentHash, byteSize: byteSize)
        if try await workMaterialRowNames(pairing, materialID: materialID),
           try await workMaterialBlobCompleteness(
               materialIDs: [materialID],
               pairedWith: [materialID: pairing]
           )[materialID] != nil {
            return .alreadyPresent
        }
        let context = newWriteContext()
        let insertedRowID = try await context.perform { [context] () -> NSManagedObjectID in
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
            //
            // The permanent id is claimed BEFORE the save so a rollback can name
            // this exact row. Nothing about the row's columns identifies it —
            // the presence check above and this insert are separate operations,
            // so two callers carrying the same bytes for one material can both
            // reach here and write rows that are equal in every column.
            try context.obtainPermanentIDs(for: [row])
            try context.save()
            return row.objectID
        }
        return .inserted(rowID: insertedRowID)
    }

    /// Whether a COMMITTED material row for this id already names exactly these
    /// bytes — the half of blob adoption that is about the CARD rather than
    /// about the payload store. Every physical row is asked, because any one of
    /// them naming the bytes is a publication that completed against this card.
    ///
    /// Metadata only. The material's `payload` column is never projected here,
    /// and never written anywhere.
    private func workMaterialRowNames(
        _ pairing: WorkMaterialBlobPairing,
        materialID: UUID
    ) async throws -> Bool {
        try await ensureLoaded()
        let context = newReadContext()
        return try await context.perform { [context] in
            let request = NSFetchRequest<NSDictionary>(entityName: "WorkMaterial")
            request.resultType = .dictionaryResultType
            request.propertiesToFetch = ["storageMode", "contentHash", "byteSize"]
            request.predicate = NSPredicate(format: "id == %@", materialID as CVarArg)
            for row in try context.fetch(request) {
                guard row["storageMode"] as? String
                        == WorkMaterialStorageMode.syncedPayload.rawValue,
                      let hash = row["contentHash"] as? String, !hash.isEmpty,
                      let size = (row["byteSize"] as? NSNumber)?.int64Value,
                      hash == pairing.contentHash, size == pairing.byteSize else { continue }
                return true
            }
            return false
        }
    }

    /// Which of these materials have a whole payload behind them, from ONE
    /// fetch that projects metadata and NEVER `payload`. Projecting the bytes
    /// would realize every blob on the board to answer a question about its
    /// size, which is the object-level faulting hazard the payload store exists
    /// to avoid.
    ///
    /// A material is answered for by the newest complete row THE MATERIAL NAMES
    /// (`pairedWith`, per `WorkMaterialBlobPairing`): CloudKit can import one
    /// logical blob as several physical rows and another device's republication
    /// as one more, so newest alone would hand a card bytes its own row does not
    /// describe. A row whose hash or size is still absent is an arrival in
    /// progress rather than a payload; completeness is
    /// `WorkMaterialBlobRecord.isComplete` and is never restated anywhere else.
    /// A material with no pairing supplied is answered for by any complete row.
    func workMaterialBlobCompleteness(
        materialIDs: Set<UUID>,
        pairedWith pairings: [UUID: WorkMaterialBlobPairing]
    ) async throws -> [UUID: WorkMaterialBlobRecord] {
        guard !materialIDs.isEmpty else { return [:] }
        try await ensureLoaded()
        #if CONDUCK_TESTING
        projectionBlobCompletenessCallsForTesting += 1
        #endif
        let unpaired = WorkMaterialBlobPairing(contentHash: nil, byteSize: 0)
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
                ), record.isComplete,
                      (pairings[record.materialID] ?? unpaired).names(record) else { continue }
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

    /// The bytes of the newest COMPLETE blob THE CARD NAMES, or nil while it is
    /// still waiting for them. Selection is the pairing rule the availability
    /// projection uses, asked through the same `WorkMaterialBlobPairing.names`
    /// — a card opens the payload it is counted as having, or nothing.
    ///
    /// This realizes the rows it walks, unlike the completeness projection: the
    /// caller is opening one card and wants its payload, so the fault it fires
    /// is the read it asked for. Duplicates are a transient CloudKit state, so
    /// the walk is one or two rows deep in practice.
    private func newestCompleteBlobPayload(
        materialID: UUID,
        pairedWith pairing: WorkMaterialBlobPairing
    ) async throws -> Data? {
        try await ensureLoaded()
        let context = newReadContext()
        return try await context.perform { [context] () -> Data? in
            for row in try Self.blobRows(materialID: materialID, in: context) {
                guard let record = Self.blobRecord(of: row), record.isComplete,
                      pairing.names(record) else { continue }
                return row.value(forKey: "payload") as? Data
            }
            return nil
        }
    }

    /// Take back the ONE blob row a refused publication inserted, named by the
    /// permanent object id that publication returned.
    ///
    /// Identity is the row, never `(materialID, contentHash, byteSize)`: that
    /// tuple carries no uniqueness constraint — CloudKit forbids one — so a
    /// peer's import of the same payload, or a second process publishing the
    /// same capture at the same instant, matches it exactly. Deleting by the
    /// columns would therefore reclaim bytes this call never wrote, and a card
    /// that named them would be left with no payload behind it.
    ///
    /// A row that has already gone (paired deletion took the whole material, or
    /// the store was rebuilt) is not an error: there is nothing left to reclaim.
    ///
    /// THE INVARIANT THIS RELIES ON. Deleting the row this call inserted is
    /// safe only while no OTHER publication can have adopted it in the meantime
    /// — a second writer that finds a complete blob takes it
    /// (`.alreadyPresent`) and inserts nothing, so its card would name a row
    /// this rollback removes. Two mechanisms together make that impossible, and
    /// both are held from before the blob is looked up through the row save,
    /// the confirmation and every rollback, on every path that can insert or
    /// adopt — the desk publication and the reattach:
    ///
    /// - `workMaterialPublicationClaims` orders publications inside ONE process
    ///   (two iPad scenes, a reattach against a replay).
    /// - `WorkMaterialPublicationLock` orders them ACROSS processes. The app and
    ///   the headless intent process share this store and mint the same
    ///   deterministic capture ids, so without it a successor could adopt a
    ///   predecessor's blob, pass its own durability barrier, and be left with
    ///   nothing when the predecessor rolled back — with the queue copy already
    ///   acknowledged and no replay left to repair from. That is a filesystem
    ///   lock rather than a publication-identity column because the column would
    ///   be a schema change to a model headed for CloudKit Production, and it
    ///   could never be withdrawn.
    ///
    /// The one thing neither reaches is a device that never took the lock at
    /// all: a peer's IMPORT can carry an identical blob row. That is why
    /// identity here is the object id and never the columns.
    private func deleteBlobRow(_ rowID: NSManagedObjectID) async {
        let context = newWriteContext()
        await context.perform { [context] in
            guard let row = try? context.existingObject(with: rowID) else { return }
            context.delete(row)
            try? context.save()
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
        protecting: [(contentHash: String, byteSize: Int64)] = [],
        in context: NSManagedObjectContext
    ) throws -> Int {
        var deleted = 0
        for row in try blobRows(materialID: materialID, in: context) {
            guard let record = blobRecord(of: row), record.isComplete else { continue }
            guard record.contentHash != contentHash || record.byteSize != byteSize else {
                continue
            }
            // A blob a NEWER row still names is not superseded by the bytes a
            // stale replay carries — it is the payload the person put on the
            // card last, and the row naming it is exactly the row this
            // publication may not repoint. Deleting it would leave that row
            // pointing at nothing, for ever.
            if protecting.contains(where: {
                $0.contentHash == record.contentHash && $0.byteSize == record.byteSize
            }) {
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
    ///
    /// A reattach that moves a card OFF the synced lane does NOT come through
    /// here: it retires the exact rows it took the card off, by object id,
    /// behind the swap (`retireReplacedBlobRows`). This predicate would take a
    /// peer's newly imported blob with them.
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
    ///
    /// `contentHash` and `byteSize` are written together and are what the card
    /// names — the pairing `WorkMaterialBlobPairing` states. Writing the lane
    /// without them would leave a card claiming synced bytes and naming no
    /// particular blob, which is the pre-pairing shape.
    private static func pointAtSyncedPayload(
        row: NSManagedObject,
        contentHash: String?,
        byteSize: Int64,
        at date: Date
    ) {
        row.setValue(nil, forKey: "payload")
        row.setValue(WorkMaterialStorageMode.syncedPayload.rawValue, forKey: "storageMode")
        row.setValue(nil, forKey: "localVaultKey")
        row.setValue(contentHash, forKey: "contentHash")
        row.setValue(NSNumber(value: byteSize), forKey: "byteSize")
        row.setValue(date, forKey: "updatedAt")
    }

    /// Whether one PHYSICAL row already names exactly these bytes on the synced
    /// lane — the row-side half of `WorkMaterialBlobPairing`, asked of the raw
    /// columns because a repair works on rows rather than on the one record the
    /// canonical read projects.
    ///
    /// It is the question a synced repair asks of every row: a row that answers
    /// no is naming a lane or a blob the card is not on, and only a write can
    /// bring it back into line.
    private static func namesSyncedPayload(
        row: NSManagedObject,
        contentHash: String,
        byteSize: Int64
    ) -> Bool {
        row.value(forKey: "storageMode") as? String
            == WorkMaterialStorageMode.syncedPayload.rawValue
            && row.value(forKey: "contentHash") as? String == contentHash
            && (row.value(forKey: "byteSize") as? NSNumber)?.int64Value == byteSize
    }

    /// Point one material row at the device-local vault. The mirror of
    /// `pointAtSyncedPayload`, and written to EVERY physical row for the same
    /// reason: a CloudKit-merged duplicate that kept claiming the lane the card
    /// has left would resurrect it the moment that row won the canonical read.
    ///
    /// Blob rows are not touched here. Retiring the bytes of a lane a card
    /// leaves belongs to the reattach that moves it, once its replacement is
    /// proved; a repair only restores what a card already claims.
    private static func pointAtLocalVault(
        row: NSManagedObject,
        vaultKey: String?,
        byteSize: Int64,
        at date: Date
    ) {
        row.setValue(nil, forKey: "payload")
        row.setValue(WorkMaterialStorageMode.localVault.rawValue, forKey: "storageMode")
        row.setValue(vaultKey, forKey: "localVaultKey")
        // A vault card names no blob. Leaving the hash behind would let a later
        // move back onto the synced lane inherit a pairing for bytes this card
        // no longer holds.
        row.setValue(nil, forKey: "contentHash")
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

    /// Refuse a publication whose material id already names a DIFFERENT kind of
    /// card — under ANY owner, the desk included.
    ///
    /// Two materials sharing a UUID is what an id collision looks like from
    /// here, and the owner is not what settles it. A colliding row already on
    /// the desk is otherwise read as an idempotent replay of itself: the caller
    /// is answered with a card it never published, the share drainer passes its
    /// durability barrier on that card's bytes and acknowledges the queue copy
    /// it was holding, and the capture is gone. Worse on the synced lane, where
    /// the repair branch would restage these bytes over that card's payload and
    /// retire the blob it was using — the collision would cost the person the
    /// card they had, not merely the one they were making.
    ///
    /// EVERY physical row, not the canonical one: a CloudKit-merged duplicate
    /// carrying another kind is the same collision.
    private static func requireMatchingKind(
        materialRows: [NSManagedObject],
        kind: WorkMaterialKind
    ) throws {
        for row in materialRows
        where row.value(forKey: "kind") as? String != kind.rawValue {
            throw WorkboardStoreError.invalidMaterialOwner
        }
    }

    /// Refuse an adoption the caller cannot account for.
    ///
    /// Every physical row parked away from the desk has to satisfy BOTH halves:
    ///
    /// 1. ITS OWNER ROW AGREES WITH THE CALLER. The caller states the capture
    ///    this material id belongs to; the foreign owner must carry that
    ///    capture's identity. A chat turn's pre-desk item was written under the
    ///    message's own id and recorded the message as its capture envelope, so
    ///    either column answers; a pre-desk drain recorded the envelope on the
    ///    item it minted. An owner row that is ABSENT refuses too, and
    ///    deliberately: CloudKit can import a material ahead of the item that
    ///    owns it, and adopting then would move — and, on the synced lane,
    ///    overwrite the payload of — a card whose real history has not arrived.
    ///    The capture is retried, and the replay adopts once the owner lands.
    ///
    ///    A pre-desk drain into an EXPLICITLY SELECTED item is the one shape
    ///    that carries no such column: it appended onto the item the person
    ///    picked and left that owner row untouched, so nothing on it names the
    ///    envelope. The envelope's own `targetWorkItemID` is what accounts for
    ///    those rows, and is accepted for exactly the owner it names — without
    ///    it a partially drained targeted capture is refused on every replay for
    ///    ever, which is the failure adoption exists to prevent.
    ///
    /// That the rows are the same KIND of card is NOT checked here. It is not a
    /// property of adoption at all — a colliding id is a collision under any
    /// owner, the desk included — so `requireMatchingKind` states it once, for
    /// every physical row, before this runs.
    ///
    /// A caller with no provenance (a drop, a picked file, a Shortcut run —
    /// every lane that mints its own ids) can never satisfy 1, which is the
    /// point: it has no history to adopt.
    private static func requireAdoptable(
        materialRows: [NSManagedObject],
        deskID: UUID,
        provenance: WorkMaterialLegacyProvenance?,
        in context: NSManagedObjectContext
    ) throws {
        guard let provenance else { throw WorkboardStoreError.invalidMaterialOwner }
        for row in materialRows {
            guard let owner = row.value(forKey: "workItemID") as? UUID, owner != deskID else {
                continue
            }
            guard let ownerRow = try workItemRow(id: owner, in: context) else {
                throw WorkboardStoreError.invalidMaterialOwner
            }
            let envelopeID = ownerRow.value(forKey: "captureEnvelopeID") as? UUID
            let matches: Bool
            switch provenance {
            case .captureEnvelope(let id, let legacyTargetWorkItemID):
                matches = envelopeID == id || owner == legacyTargetWorkItemID
            case .chatMessage(let id):
                matches = envelopeID == id || owner == id
            }
            guard matches else { throw WorkboardStoreError.invalidMaterialOwner }
        }
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

    #if CONDUCK_TESTING
    /// TEST SEAM — add a material to an arbitrary owner and update it in one
    /// Core Data save. Payload bytes always go to the explicit device-local
    /// vault.
    ///
    /// WHY IT HAS TO EXIST, AND WHY IT IS COMPILED OUT OF A SHIPPING BUILD.
    /// Every capture surface publishes onto the desk through
    /// `upsertDeskMaterial`, which is where `WorkMaterialStoragePolicy` decides
    /// the lane; this is the only way to mint a material under a NON-desk
    /// owner, which is the pre-desk shape the adoption path has to be tested
    /// against, and the only way to ask for a device-local payload under the
    /// ceiling. Both are fixtures. Behind the flag the compiler is what
    /// guarantees no shipped lane can name an arbitrary owner — a claim a
    /// convention cannot make.
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

        var byteSize = draft.byteSize ?? Int64(draft.payload?.count ?? 0)
        let storageMode: WorkMaterialStorageMode = draft.payload == nil
            ? draft.storageMode : .localVault

        var newVaultKey: String?
        if storageMode == .localVault, let payload = draft.payload {
            let write = try await workAssetVault.store(
                bytes: payload,
                id: draft.id,
                suggestedExtension: draft.filename.map { ($0 as NSString).pathExtension }
            )
            newVaultKey = write.key
            // Same rule as every other vault write: the row records the length
            // the leaf holds, so the draft's claim cannot become a size nothing
            // can confirm against.
            byteSize = write.byteCount
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

    /// TEST SEAM — import a URL under an arbitrary owner without materializing
    /// arbitrary bytes on the main actor. File bytes stream into the explicit
    /// device-local vault with cancellable progress; only metadata mirrors
    /// through private CloudKit. Same standing and the same reason as
    /// `addWorkMaterial` above.
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
        var publicationIsDurable = true
        if !inserted, let newVaultKey {
            try? await workAssetVault.remove(newVaultKey)
        } else if let newVaultKey {
            // Same rule as the desk publication: a committed row may not report
            // a payload the vault can no longer read back, and it is proved
            // against the length the write measured off the leaf.
            publicationIsDurable = await confirmVaultPublication(
                site: .arbitraryInsert,
                materialID: draft.id,
                key: newVaultKey,
                expectedByteCount: byteSize
            )
        }
        if inserted { await postDidChange() }
        guard publicationIsDurable else {
            throw await committedUnavailable(materialID: draft.id)
        }
        guard let record = try await fetchWorkMaterial(id: draft.id) else {
            throw WorkboardStoreError.materialNotFound
        }
        return record
    }
    #endif

    /// Reattach a file in place without changing material identity, order,
    /// caption or title.
    ///
    /// The arriving bytes re-decide the lane through
    /// `WorkMaterialStoragePolicy`, so a card whose payload was device-local
    /// moves onto the synced lane when a small file replaces it, and off it
    /// when a large one does. The lane a card leaves is cleared behind the
    /// swap, never in front of it: what the card still names is the person's
    /// only copy until the replacement is proved, so the rows point at the new
    /// lane first and the old bytes — the previous vault keys, the previous blob
    /// rows — are released only once the new leaf reads back. Between the two a
    /// card names one lane and bytes for another survive unreferenced; only a
    /// crash in that window leaves them, and nothing reads them.
    ///
    /// Nothing the card still names is disturbed before the owner-revision CAS
    /// commits either: the vault lane stages under a FRESH key, and the blob
    /// lane takes its own insert back if the CAS refuses.
    ///
    /// EVERY physical row of the material is written under ONE compare-and-swap
    /// — CloudKit can merge a card into several rows, and blob deletion is
    /// scoped to the logical id, so a row left behind on the old lane would
    /// either resurrect the payload this call replaced or claim a synced
    /// payload whose bytes this same save removed. Rows that disagree about
    /// their owner are refused rather than guessed at.
    ///
    /// THE NEW LEAF IS PROVED READABLE BEFORE THE SWAP, not after it. The bytes
    /// the card is giving up are the only copy it has — the picked file is the
    /// person's, not the app's — so a replacement that cannot be read back has
    /// to be refused while the old payload is still named by the row and still
    /// on disk. The proof does not release the staging guard: only the
    /// confirmation after the commit may do that, and until then a reclamation
    /// in another process must not be free to take the leaf. What remains
    /// after the swap is the narrow window in which a leaf proved seconds ago
    /// stops reading; the old keys are kept there, and the rows go back to what
    /// they named whenever putting them back is lossless.
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
        // The same claim the desk publication takes, for the same reason: this
        // path can adopt a blob another publication has already inserted but
        // not yet named, and without the claim that publication's own rollback
        // deletes the row this card would then be pointing at.
        while workMaterialPublicationClaims.contains(id) {
            try await Task.sleep(for: .milliseconds(40))
        }
        workMaterialPublicationClaims.insert(id)
        defer { workMaterialPublicationClaims.remove(id) }

        try await ensureLoaded()

        // And the cross-process half, for the same reason and on the same
        // terms as the desk publication: taken before anything is staged, held
        // through the swap, the confirmation and the compensating restore.
        let publicationHold = try await workMaterialPublicationLock?.acquire(materialID: id)
        defer { publicationHold?.release() }

        // Kind comes from the row: a reattach replaces bytes, never what the
        // card is.
        guard let existing = try await fetchWorkMaterial(id: id) else {
            throw WorkboardStoreError.materialNotFound
        }
        // A reattach REPLACES the card's bytes by design, so the picked
        // picture is sized for the desk against no existing pairing: what the
        // row named before is exactly what this call is retiring. Every name
        // that states a format — filename, mime type, and the title when it
        // carried an image extension — follows the bytes, or the export would
        // hand a JPEG out under the picked file's name.
        let replacement: (
            payload: Data?, sourceURL: URL?, byteSize: Int64,
            filename: String?, mimeType: String?, title: String?
        )
        switch try await WorkMaterialImagePolicy.prepare(
            kind: existing.kind,
            payload: nil,
            sourceFileURL: sourceURL,
            declaredByteCount: byteSize,
            existing: nil
        ) {
        case .normalised(let jpeg, _, _):
            replacement = (
                payload: jpeg,
                sourceURL: nil,
                byteSize: Int64(jpeg.count),
                filename: filename.map { WorkMaterialDraft.replacingExtension(of: $0, with: "jpg") },
                mimeType: "image/jpeg",
                title: WorkMaterialDraft.renamingTypedExtension(of: existing.title, to: "jpg")
            )
        case .unchanged(.alreadyConforming):
            // Already a JPEG of the desk's shape: staged from the file as it
            // is, but named for what it is — the card's title may still carry
            // the extension of the picture this one replaces.
            replacement = (
                payload: nil,
                sourceURL: sourceURL,
                byteSize: byteSize,
                filename: filename.map { WorkMaterialDraft.replacingExtension(of: $0, with: "jpg") },
                mimeType: "image/jpeg",
                title: WorkMaterialDraft.renamingTypedExtension(of: existing.title, to: "jpg")
            )
        case .unchanged:
            replacement = (
                payload: nil, sourceURL: sourceURL, byteSize: byteSize,
                filename: filename, mimeType: mimeType, title: nil
            )
        }
        let staged = try await stageWorkMaterialBytes(
            id: id,
            kind: existing.kind,
            filename: replacement.filename,
            payload: replacement.payload,
            declaredByteSize: replacement.byteSize,
            declaredStorageMode: .localVault,
            sourceFileURL: replacement.sourceURL,
            sourceFileByteSize: replacement.sourceURL == nil ? nil : replacement.byteSize,
            vaultKeyID: UUID(),
            onProgress: onProgress
        )
        let newKey = staged.vaultKey

        // Proved BEFORE anything the card names is disturbed, and without
        // releasing the staging guard: a leaf that cannot be opened must not
        // cost the person the payload it was replacing.
        if let newKey, await workAssetVault.readableKeys(among: [newKey]).isEmpty {
            try? await workAssetVault.remove(newKey)
            throw WorkboardStoreError.materialPayloadUnavailable
        }

        // The preview belongs to the bytes, so a reattach mints a new one on
        // the same terms the capture did — decoded from the file still on disk,
        // before the swap opens, and only for an image landing on the synced
        // lane. Everything else leaves the column cleared below, which is what
        // an unreadable preview of the payload the card just lost would be.
        let replacementThumbnail: Data?
        if existing.kind == .image, staged.storageMode == .syncedPayload {
            replacementThumbnail = await Self.imagePresentationThumbnail(
                payload: replacement.payload,
                sourceFileURL: replacement.sourceURL
            )
        } else {
            replacementThumbnail = nil
        }

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
        let swap: WorkMaterialReattachSwap
        do {
            swap = try await context.perform {
                [context] () -> WorkMaterialReattachSwap in
                // EVERY physical row, not the canonical one: a duplicate left
                // on the old lane still holds a storage mode, a key and a size,
                // and a later merge that lets it win the canonical read would
                // hand the person back the payload this call replaced — or, on
                // the way off the synced lane, a `.syncedPayload` claim whose
                // blobs this same save deleted.
                let rows = try Self.workMaterialRows(id: id, in: context)
                guard !rows.isEmpty else { throw WorkboardStoreError.materialNotFound }
                let owners = Set(rows.compactMap { $0.value(forKey: "workItemID") as? UUID })
                guard owners.count == 1, let ownerID = owners.first else {
                    // Rows disagreeing about their owner cannot be moved under
                    // one compare-and-swap, and picking one owner would decide
                    // the disagreement by accident.
                    throw WorkboardStoreError.invalidMaterialOwner
                }
                guard let owner = try Self.workItemRow(id: ownerID, in: context),
                      let ownerUpdatedAt = owner.value(forKey: "updatedAt") as? Date else {
                    throw WorkboardStoreError.materialNotFound
                }
                guard Self.workRevision(for: ownerUpdatedAt) == expectedOwnerRevision else {
                    throw WorkboardStoreError.staleRevision
                }
                let oldKeys = Set(rows.compactMap { $0.value(forKey: "localVaultKey") as? String })
                // Everything the swap is about to overwrite, per physical row,
                // so a post-commit refusal can put it back.
                let priorRows = rows.map(WorkMaterialRowSnapshot.init)
                var replacedBlobRowIDs: [NSManagedObjectID] = []
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
                    for row in rows {
                        Self.pointAtSyncedPayload(
                            row: row,
                            contentHash: staged.contentHash,
                            byteSize: staged.byteSize,
                            at: now
                        )
                    }
                case .localVault, .metadataOnly:
                    // The card's payload leaves the synced lane, and its blobs
                    // deliberately do NOT leave with it here. They are the only
                    // copy of what the card had, and the new leaf is not proved
                    // until after this save commits: deleting them now would
                    // mean a refused confirmation had already destroyed the
                    // payload it was replacing. They are retired in the
                    // follow-up operation once the leaf reads back — see
                    // `retireReplacedBlobRows` — and the rows that retirement
                    // may take are NAMED here, while the swap still holds them.
                    // Anything that arrives afterwards belongs to a
                    // republication on another device whose own material update
                    // has not landed yet, and is not this call's to reclaim.
                    let replaced = try Self.blobRows(materialID: id, in: context)
                    try context.obtainPermanentIDs(for: replaced)
                    replacedBlobRowIDs = replaced.map(\.objectID)
                    for row in rows {
                        Self.pointAtLocalVault(
                            row: row,
                            vaultKey: newKey,
                            byteSize: staged.byteSize,
                            at: now
                        )
                    }
                }
                for row in rows {
                    row.setValue(sourceDevice, forKey: "sourceDevice")
                    if let filename = replacement.filename { row.setValue(filename, forKey: "filename") }
                    if let mimeType = replacement.mimeType { row.setValue(mimeType, forKey: "mimeType") }
                    if let title = replacement.title { row.setValue(title, forKey: "title") }
                    // An extract describes the bytes that were here before, and
                    // this call is handed none for the bytes replacing them.
                    row.setValue(nil, forKey: "textContent")
                    // The old preview goes whatever happens. A replacement is
                    // written only where one was decoded — an image on the
                    // synced lane — so every other reattach still clears the
                    // column rather than leaving a picture of a payload the
                    // card no longer holds.
                    row.setValue(replacementThumbnail, forKey: "thumbnailData")
                }
                owner.setValue(now, forKey: "updatedAt")
                try context.save()
                return WorkMaterialReattachSwap(
                    oldVaultKeys: oldKeys,
                    priorRows: priorRows,
                    replacedBlobRowIDs: replacedBlobRowIDs
                )
            }
        } catch {
            if let newKey { try? await workAssetVault.remove(newKey) }
            if case .inserted(let rowID) = publishedBlob {
                // The card kept the payload it had, so the row this call
                // inserted names nothing. Same rule as a refused capture: only
                // the call that wrote a row knows that, and only that row goes.
                await deleteBlobRow(rowID)
            }
            throw error
        }

        var publicationIsDurable = true
        if let newKey {
            publicationIsDurable = await confirmVaultPublication(
                site: .reattach,
                materialID: id,
                key: newKey,
                expectedByteCount: staged.byteSize
            )
        }
        guard publicationIsDurable else {
            // The swap committed and the leaf will not read back. NOTHING the
            // card was using is released here — neither the old vault keys nor
            // the old blob rows: they are the only surviving copy of what the
            // person had, and releasing them would turn a failed reattach into
            // permanent loss.
            let restored = await restoreReplacedPayload(
                id: id,
                to: swap.priorRows,
                discardingBlob: publishedBlob
            )
            await postDidChange()
            if restored {
                // The card names what it named before, so nothing is committed
                // that a caller could adopt — this is an ordinary refusal.
                if let newKey { try? await workAssetVault.remove(newKey) }
                throw WorkboardStoreError.materialPayloadUnavailable
            }
            throw await committedUnavailable(materialID: id)
        }
        // Only now: the rows point at a leaf that has been proved, so the lane
        // they left can be released — the old vault keys, and the exact blob
        // rows the swap took the card off.
        await retireReplacedBlobRows(swap.replacedBlobRowIDs)
        for oldKey in swap.oldVaultKeys where oldKey != newKey {
            try? await workAssetVault.remove(oldKey)
        }
        await postDidChange()
        return try await fetchWorkMaterial(id: id)
    }

    /// Retire the blob rows a reattach took a card OFF, after its new leaf has
    /// been proved readable — named by the permanent object ids the swap
    /// sampled, never refetched by material id.
    ///
    /// A lane change is two logical operations rather than one, deliberately.
    /// The swap has to commit before the leaf can be confirmed, and the bytes
    /// the card is giving up are the only copy it has — so they outlive the
    /// swap and are released only once the replacement is known to serve. That
    /// gap is a window CloudKit can deliver into: a blob row imported from
    /// another device between the swap and this call is a republication whose
    /// own material update has not landed yet, and refetching by material id
    /// would delete it and EXPORT that deletion — leaving the peer's card
    /// waiting for iCloud for ever. So this reclaims exactly the rows that were
    /// there when the card left the lane, and nothing that arrived after.
    ///
    /// The cost is a bounded crash residue: a process that dies between the
    /// confirmation and this call leaves blob rows for a card that no longer
    /// claims the synced lane. Nothing reads them (a `.localVault` row answers
    /// from the vault, and the availability projection asks the blob store only
    /// about synced rows), the next reattach off the same card retires them, and
    /// a paired delete takes them with the material. That is strictly the
    /// cheaper mistake: the alternative — retiring them inside the swap — costs
    /// the person their payload every time a confirmation refuses. The one rule
    /// this does not bend is `deleteBlobRows`': a blob is reclaimed only
    /// together with, or behind, the material that names it, never by a sweep.
    private func retireReplacedBlobRows(_ rowIDs: [NSManagedObjectID]) async {
        guard !rowIDs.isEmpty else { return }
        let context = newWriteContext()
        await context.perform { [context] in
            var retired = 0
            for rowID in rowIDs {
                guard let row = try? context.existingObject(with: rowID) else { continue }
                context.delete(row)
                retired += 1
            }
            guard retired > 0 else { return }
            try? context.save()
        }
    }

    /// What the reattach's swap committed, for the operations that follow it:
    /// the vault leaves the rows stopped naming, every payload-bearing column
    /// as it stood, and the exact blob rows the card was taken off.
    private nonisolated struct WorkMaterialReattachSwap: Sendable {
        let oldVaultKeys: Set<String>
        /// The physical rows as they stood, each carrying its own prior
        /// `updatedAt` AND the `createdAt` a reader substitutes when that is
        /// absent.
        ///
        /// The rollback derives every restored stamp from the row's own
        /// EFFECTIVE revision (`restoredRevisionStamps`), so canonical order is
        /// preserved by the VALUES rather than by this array's order:
        /// re-sorting it changes nothing, and no row can be promoted past where
        /// it already stood. Carrying `createdAt` is what makes that true for an
        /// undated row as well — without it the rollback could only advance the
        /// raw column, and a row readers compare by `createdAt` would come out
        /// of the round trip at the revision it went in with.
        let priorRows: [WorkMaterialRowSnapshot]
        let replacedBlobRowIDs: [NSManagedObjectID]
    }

    /// One physical row's payload-bearing columns as they stood BEFORE a
    /// reattach overwrote them.
    private nonisolated struct WorkMaterialRowSnapshot: Sendable {
        let rowID: NSManagedObjectID
        let storageMode: String?
        let localVaultKey: String?
        let contentHash: String?
        let byteSize: Int64?
        let filename: String?
        let mimeType: String?
        let sourceDevice: String?
        let textContent: String?
        let thumbnailData: Data?
        let updatedAt: Date?
        /// Carried ONLY so the rollback can advance the revision a reader
        /// actually sees. It is never written back — `createdAt` is not a
        /// payload column and a restore has no business moving it.
        let createdAt: Date?

        /// The blob this row named, so a restore puts the card back on the
        /// payload it had rather than on whatever blob carries its id.
        var pairing: WorkMaterialBlobPairing {
            WorkMaterialBlobPairing(contentHash: contentHash, byteSize: byteSize ?? 0)
        }

        /// What every projection reports as this row's revision, substitutions
        /// included. The rollback advances THIS, not the raw column.
        var effectiveRevision: Date {
            ConversationStore.materialRevisionDate(updatedAt: updatedAt, createdAt: createdAt)
        }

        init(row: NSManagedObject) {
            rowID = row.objectID
            storageMode = row.value(forKey: "storageMode") as? String
            localVaultKey = row.value(forKey: "localVaultKey") as? String
            contentHash = row.value(forKey: "contentHash") as? String
            byteSize = (row.value(forKey: "byteSize") as? NSNumber)?.int64Value
            filename = row.value(forKey: "filename") as? String
            mimeType = row.value(forKey: "mimeType") as? String
            sourceDevice = row.value(forKey: "sourceDevice") as? String
            textContent = row.value(forKey: "textContent") as? String
            thumbnailData = row.value(forKey: "thumbnailData") as? Data
            updatedAt = row.value(forKey: "updatedAt") as? Date
            createdAt = row.value(forKey: "createdAt") as? Date
        }
    }

    /// Put a reattached card back on the payload it had, and report whether it
    /// was put back.
    ///
    /// ONLY WHEN THAT IS LOSSLESS — which is decided per physical row, against
    /// the lane that row claimed and the bytes that lane still holds:
    ///
    /// - `.localVault`: its leaf must still be readable. The swap staged under
    ///   a fresh key and released nothing before the confirmation, so it is.
    /// - `.syncedPayload`: a complete blob the row NAMED must still answer for
    ///   this material — the pairing, not merely some blob under its id. The
    ///   swap deliberately leaves the old blob rows standing until the new leaf
    ///   is proved (`retireReplacedBlobRows`), so it does.
    /// - `.metadataOnly`: the row claimed no payload, so putting it back claims
    ///   none either — nothing to check and nothing to lose.
    ///
    /// A row whose bytes are genuinely gone refuses, and that card keeps the new
    /// pointer with the failure reported as committed-but-unavailable: pointing
    /// it back at a payload nothing holds would be strictly worse than the
    /// unreadable leaf it names, which a reattach can at least replace.
    ///
    /// THE PAYLOAD GOES BACK; THE REVISION DOES NOT. Every column describing the
    /// bytes is restored verbatim — that is the guarantee — but `updatedAt` is
    /// stamped FRESH rather than put back, because it is the only thing any
    /// reader has to tell that these bytes moved. Restoring it makes the whole
    /// round trip invisible: a card read at revision A, replaced with B, then
    /// rolled back, reads as A again, so anything holding A believes nothing
    /// happened. That is not hypothetical for a reader that resolves BYTES by
    /// id separately from metadata — a share prepared against A can pick up B's
    /// bytes mid-flight and then pass a revision check against a restored A.
    ///
    /// FRESH PER ROW, NEVER LIFTED TO A SHARED CEILING. `updatedAt` is also the
    /// FIRST key that decides which physical row of a CloudKit-duplicated
    /// material is canonical (`workMaterialRows`), and two duplicates can
    /// legitimately name different blobs. Each row is therefore advanced beyond
    /// ITS OWN prior stamp and nothing else's, by `restoredRevisionStamps`.
    ///
    /// Both halves of that sentence fix a real defect. Putting the prior stamp
    /// back makes the round trip invisible. But giving every row one shared
    /// FRESH stamp is wrong in the other direction: it drags the LOSING
    /// duplicates up to the winner's level, and a later legitimate update of
    /// the winner row — a peer whose clock has since corrected, writing an
    /// ordinary `Date()` — then loses to a loser that was promoted for no
    /// reason, so the card serves bytes nobody wrote last. Advancing each row
    /// past its own stamp leaves the losers where they were, so any later write
    /// to the winner that clears the losers' own stamps still wins.
    ///
    private func restoreReplacedPayload(
        id: UUID,
        to priorRows: [WorkMaterialRowSnapshot],
        discardingBlob publishedBlob: WorkMaterialBlobPublication
    ) async -> Bool {
        guard !priorRows.isEmpty else { return false }
        let priorKeys = Set(priorRows.compactMap(\.localVaultKey))
        let readable = priorKeys.isEmpty
            ? []
            : await workAssetVault.readableKeys(among: priorKeys)
        // Per PAIRING rather than per material: merged rows can name different
        // publications, and each is restorable only if the blob it named is
        // still there. In practice this is one query.
        var provenPairings: Set<WorkMaterialBlobPairing> = []
        for prior in priorRows
        where prior.storageMode == WorkMaterialStorageMode.syncedPayload.rawValue {
            let pairing = prior.pairing
            guard !provenPairings.contains(pairing) else { continue }
            let completeness = try? await workMaterialBlobCompleteness(
                materialIDs: [id],
                pairedWith: [id: pairing]
            )
            if completeness?[id] != nil { provenPairings.insert(pairing) }
        }
        for prior in priorRows {
            // No lane column at all: the row claims no payload, so putting it
            // back claims none either.
            guard let rawLane = prior.storageMode else { continue }
            // A lane this build does not know cannot be judged lossless.
            guard let lane = WorkMaterialStorageMode(rawValue: rawLane) else { return false }
            switch lane {
            case .localVault:
                guard let key = prior.localVaultKey, readable.contains(key) else { return false }
            case .syncedPayload:
                guard provenPairings.contains(prior.pairing) else { return false }
            case .metadataOnly:
                continue
            }
        }

        // Each row advanced past its OWN effective revision — the value a
        // reader compares, substitutions included. See the revision paragraphs
        // above for why nothing here is lifted to a shared ceiling, and why an
        // undated row is not left alone.
        let restoredStamps = Self.restoredRevisionStamps(
            advancing: priorRows.map(\.effectiveRevision)
        )
        let context = newWriteContext()
        let restored = await context.perform { [context] () -> Bool in
            for (position, prior) in priorRows.enumerated() {
                guard let row = try? context.existingObject(with: prior.rowID) else {
                    return false
                }
                row.setValue(prior.storageMode, forKey: "storageMode")
                row.setValue(prior.localVaultKey, forKey: "localVaultKey")
                row.setValue(prior.contentHash, forKey: "contentHash")
                row.setValue(prior.byteSize.map(NSNumber.init(value:)), forKey: "byteSize")
                row.setValue(prior.filename, forKey: "filename")
                row.setValue(prior.mimeType, forKey: "mimeType")
                row.setValue(prior.sourceDevice, forKey: "sourceDevice")
                row.setValue(prior.textContent, forKey: "textContent")
                row.setValue(prior.thumbnailData, forKey: "thumbnailData")
                // NOT `prior.updatedAt`. The bytes are the card's again; the
                // revision has to say they moved — advanced past THIS row's own
                // effective revision, so no duplicate is promoted past where it
                // already stood and no undated row keeps the revision it had.
                row.setValue(restoredStamps[position], forKey: "updatedAt")
            }
            do {
                try context.save()
                return true
            } catch {
                return false
            }
        }
        if restored, case .inserted(let rowID) = publishedBlob {
            // The card is back on the vault lane, so the blob this call
            // inserted for the replacement names nothing. Same rule as every
            // other rollback: only the call that wrote a row may delete it.
            await deleteBlobRow(rowID)
        }
        return restored
    }

    /// The revision a READER sees for one material row.
    ///
    /// `updatedAt` is nullable, and a row that carries none is NOT revisionless:
    /// every projection substitutes `createdAt`, and the floor below that.
    /// ONE definition, shared by the projection readers consume
    /// (`StoredWorkMaterial`) and by the rollback that has to advance it —
    /// because a rollback that advanced the raw column while readers compared a
    /// substituted one would leave an undated row reading the SAME revision
    /// before and after, which is the whole thing that revision exists to deny.
    nonisolated static func materialRevisionDate(updatedAt: Date?, createdAt: Date?) -> Date {
        updatedAt ?? createdAt ?? .distantPast
    }

    /// The stamps a rollback writes: each row's OWN effective revision,
    /// advanced by one step.
    ///
    /// EFFECTIVE, not the raw column. `updatedAt` is nullable and every reader
    /// substitutes `createdAt` for a row that has none
    /// (`materialRevisionDate`), so leaving such a row alone would leave its
    /// revision unchanged across the whole round trip — and a share prepared
    /// before the replace would pass its equality check against bytes that had
    /// been swapped underneath. An undated row therefore comes out of a
    /// rollback carrying `createdAt + step` in `updatedAt`, which moves its
    /// revision and, as a bonus, makes the raw fetch ordering agree with the
    /// substituted ordering the projection uses.
    ///
    /// PER ROW, never relative to a shared ceiling — that is the rest of the
    /// rule, and together they buy three properties:
    ///
    ///   (a) THE CANONICAL WINNER IS UNCHANGED. Adding one step to every
    ///       effective revision is monotone, so rows that differed still differ
    ///       the same way — including a dated row against an undated one, which
    ///       are compared in that same substituted space. Rows that were EQUAL
    ///       stay equal, which is also correct: that tie was already settled by
    ///       `createdAt`/`title` and those are untouched.
    ///   (b) EVERY ROW'S REVISION MOVES, which is what a reader holding the
    ///       pre-replace revision needs in order to notice that these bytes
    ///       moved and came back.
    ///   (c) A LATER LEGITIMATE UPDATE OF THE WINNER STILL WINS. Each loser is
    ///       only one step above where it already was, so a subsequent write to
    ///       the winning row outranks every loser — including a peer's ordinary
    ///       `Date()` after its clock corrected, which can land far BELOW the
    ///       winner's own prior stamp.
    ///
    /// The residual on (c), stated because it is real: when two effective
    /// revisions were EQUAL, both rise by one step together, so an update
    /// landing inside that one step of the shared value is outranked. The
    /// window is `step` wide, it needs a write within a millisecond of the
    /// previous one, and the next write to either row clears it.
    ///
    /// `step` is a millisecond rather than the smallest representable increment
    /// on purpose. Property (b) is the one whose failure is SILENT — it
    /// re-opens the stale-share defect — and a millisecond survives any date
    /// rounding a CloudKit round trip could apply, where a single-ULP bump
    /// might not.
    ///
    /// Static and pure so all three properties are provable without a rollback.
    nonisolated static func restoredRevisionStamps(
        advancing priorRevisions: [Date],
        step: TimeInterval = 0.001
    ) -> [Date] {
        priorRevisions.map { $0.addingTimeInterval(step) }
    }

    /// A write stamp that is never BELOW what it replaces.
    ///
    /// `Date()` is not monotone against a synced row. A peer whose clock runs
    /// ahead writes an `updatedAt` in the future and CloudKit hands it to this
    /// device verbatim, so stamping with the local wall clock LOWERS the
    /// revision it is overwriting. Two places that costs something real:
    ///
    ///   * A MERGED CARD. The canonical row is picked by `revision` first, so
    ///     lowering the winner under a duplicate that is merely less far ahead
    ///     hands every read to the loser — the card changes its content, its
    ///     payload or its link because somebody moved it. Advancing past every
    ///     duplicate is what keeps the winner the winner.
    ///   * THE DESK'S OWN TOKEN. `workRevision(for:)` is a compare-and-swap
    ///     over this column, and a stamp that walks backwards can land on a
    ///     value some caller is still holding, which makes a stale token match
    ///     again.
    ///
    /// So: the local instant, or one step past the highest revision being
    /// stood on, whichever is later. `step` is a millisecond for the same
    /// reason `restoredRevisionStamps` uses one — it survives any date rounding
    /// a CloudKit round trip applies, where a single-ULP bump might not.
    ///
    /// Pure and static, so the property is provable without a store.
    nonisolated static func advancedWriteStamp(
        _ now: Date,
        notBelow priorRevisions: [Date],
        step: TimeInterval = 0.001
    ) -> Date {
        guard let ceiling = priorRevisions.max() else { return now }
        return max(now, ceiling.addingTimeInterval(step))
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
            try Self.requireOwnerRevision(expectedOwnerRevision, ownerID: owner, in: context)
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

    /// Invoked only after the reviewed project mutation validated its exact
    /// membership and canonical material revisions. Payload rows share its
    /// save; filesystem leaves are reclaimed by the caller only after success.
    /// Conversation attachments and result receipts are independent history.
    nonisolated static func deleteReviewedDeskMaterials(
        ids: [UUID], in context: NSManagedObjectContext
    ) throws -> [String] {
        var vaultKeys: Set<String> = []
        for id in ids {
            let rows = try workMaterialRows(id: id, ownedBy: Constants.workboardDeskItemID, in: context)
            guard !rows.isEmpty else { throw WorkDeskStoreError.staleProjectDeletion }
            vaultKeys.formUnion(rows.compactMap { $0.value(forKey: "localVaultKey") as? String })
            rows.forEach(context.delete)
            try deleteBlobRows(materialID: id, in: context)
        }
        if !ids.isEmpty, let owner = try workItemRow(id: Constants.workboardDeskItemID, in: context) {
            owner.setValue(advancedWriteStamp(Date(), notBelow: [owner.value(forKey: "updatedAt") as? Date].compactMap { $0 }),
                           forKey: "updatedAt")
        }
        return vaultKeys.sorted()
    }

    /// The desk's compare-and-swap, in ONE place.
    ///
    /// The token is the bit pattern of a `Date`, not a rounded timestamp
    /// (`workRevision(for:)`), and an owner row that carries no `updatedAt` at
    /// all refuses rather than matching: a token for a revision the row cannot
    /// state is not a comparison anybody made. Nil is not a wildcard the caller
    /// smuggles past a check — it means the caller holds no board state to
    /// guard, which every headless publication lane genuinely does not.
    ///
    /// Shared by the two deletes so the pair mutation cannot drift into
    /// comparing something subtly different from the single one; the group
    /// delete's whole reason for existing is that two separate deletes cannot
    /// share ONE such comparison.
    private static func requireOwnerRevision(
        _ expected: Int64?,
        ownerID: UUID,
        in context: NSManagedObjectContext
    ) throws {
        guard let expected else { return }
        guard let item = try workItemRow(id: ownerID, in: context),
              let updatedAt = item.value(forKey: "updatedAt") as? Date,
              workRevision(for: updatedAt) == expected else {
            throw WorkboardStoreError.staleRevision
        }
    }

    /// Every PHYSICAL row of one logical material THIS owner holds.
    ///
    /// Owner-scoped on purpose: a group mutation is a statement about one
    /// desk, and rows of the same logical id parked under a legacy owner are
    /// not this desk's to delete — the same boundary `deleteWorkMaterial`
    /// draws when it is given a `workItemID`. Sorted like every other
    /// duplicate fetch so a reader that does not run the canonical selection
    /// still sees a stable order.
    private static func workMaterialRows(
        id: UUID,
        ownedBy workItemID: UUID,
        in context: NSManagedObjectContext
    ) throws -> [NSManagedObject] {
        let request = NSFetchRequest<NSManagedObject>(entityName: "WorkMaterial")
        request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            NSPredicate(format: "id == %@", id as CVarArg),
            NSPredicate(format: "workItemID == %@", workItemID as CVarArg),
        ])
        request.sortDescriptors = [
            NSSortDescriptor(key: "updatedAt", ascending: false),
            NSSortDescriptor(key: "createdAt", ascending: false),
            NSSortDescriptor(key: "title", ascending: false),
        ]
        return try context.fetch(request)
    }

    /// The picture a recording's `attachedToMaterialID` actually resolves to on
    /// this desk, or nil when it resolves to none.
    ///
    /// TWO CANDIDATES AND NO MORE, in this order: the id the voice material
    /// names, then the one escape a colliding publication may have taken
    /// (`WorkMaterialCollisionEscape` — there is deliberately no second
    /// escape, so there is no third candidate).
    ///
    /// FIRST ELIGIBLE, NEVER FIRST EXISTING. A row of the wrong kind standing
    /// at the named id is precisely WHY the picture escaped, so a candidate
    /// that fails the conditions is skipped rather than ending the search;
    /// stopping at it would make collision recovery permanently unfoldable.
    ///
    /// A candidate is eligible when it is on THIS owner, is an `.image`, and
    /// names no picture of its own — a chain is not a fold. The kind is read
    /// from the CANONICAL row, the same one the board draws from, so the store
    /// and the board cannot disagree about what a duplicate-merged card is.
    ///
    /// A CHILD THAT NAMES ITSELF RESOLVES TO NOTHING, and this returns nil
    /// before either candidate is looked up rather than merely skipping the
    /// self-referential one: the escape of the child's OWN id is not the child,
    /// so a skip would let whatever picture happens to sit at that derived id
    /// validate a pair the board never folded and hand the group delete two
    /// cards that were never a pair. No lane writes a self-link; the stored
    /// value is raw, so a corrupt or synced row can carry one.
    ///
    /// The link is a promise about identity, not existence: a voice material
    /// whose picture never landed resolves to nil here and is a standalone
    /// card, which is correct rather than a defect.
    private static func eligibleCompanionPictureID(
        link: UUID,
        child: UUID,
        workItemID: UUID,
        in context: NSManagedObjectContext
    ) throws -> UUID? {
        guard link != child else { return nil }
        let candidates = [link, WorkMaterialCollisionEscape.materialID(forCapture: link)]
        for candidate in candidates {
            guard candidate != child else { continue }
            let rows = try workMaterialRows(id: candidate, ownedBy: workItemID, in: context)
            guard let row = canonicalRow(among: rows) else { continue }
            guard WorkMaterialKind(stored: row.value(forKey: "kind") as? String) == .image else {
                continue
            }
            guard row.value(forKey: "attachedToMaterialID") as? UUID == nil else { continue }
            return candidate
        }
        return nil
    }

    /// Delete a folded pair — a picture and the voice material that names it —
    /// as ONE mutation.
    ///
    /// WHY IT IS NOT TWO DELETES. `deleteWorkMaterial` advances the desk's
    /// `updatedAt`, so a second call carrying the token the person's board was
    /// holding is refused by the first call's own write. What that leaves is
    /// the worst outcome the card has: the picture gone and its voice material
    /// standing alone on the desk, delivered by the one control that offered
    /// to remove both. So the pair takes ONE transaction, ONE compare-and-swap,
    /// ONE timestamp and ONE save, and either both cards go or neither does.
    ///
    /// THE PAIR IS THE CALLER'S, AND IT IS ONLY VALIDATED HERE. `childID` is
    /// the companion the person was looking at; this call never re-picks a
    /// different child, because the board's own selection rule (lowest child
    /// UUID among several claimants) can move under a sync while a confirmation
    /// alert is up, and deleting a recording nobody pointed at is unrecoverable.
    /// What it does check is that the named pair IS a pair: the child is the
    /// press's voice material on this desk — an `.audio` or a `.transcript`,
    /// the two shapes the board folds — it names a picture, and that name
    /// resolves, through `eligibleCompanionPictureID` and the same two
    /// candidates the board folds by, to exactly `parentID`. Anything else is
    /// `WorkboardStoreError.invalidMaterialCompanion` and nothing is deleted.
    /// The kinds accepted here and the fold's own child condition are ONE rule
    /// in two places: a shape the board draws inside a picture and this refuses
    /// is a folded card whose Delete throws.
    ///
    /// EVERY PHYSICAL ROW of both materials goes, duplicates included: CloudKit
    /// can merge one logical card into several, and a survivor would resurrect
    /// the card the person removed. Both blob lanes are retired in the same
    /// save (`deleteBlobRows(materialID:in:)`) — paired deletion is still the
    /// only reclamation blobs have.
    ///
    /// VAULT KEYS ARE COLLECTED ACROSS BOTH MATERIALS AND ACROSS EVERY ROW,
    /// distinct, never `.first`: two duplicate rows can name different leaves
    /// holding different bytes, and a leaf nothing references is a payload no
    /// card will ever reclaim. The files go AFTER the save, because a file
    /// system is not part of the database transaction and bytes removed in
    /// front of a refused save would be bytes taken from cards still standing.
    ///
    /// WHAT IT DOES NOT DO. It does not sweep: a child published on another
    /// device concurrently with this deletion can still arrive afterwards and
    /// render standalone, owning its own payload. The owner revision is a local
    /// conflict check, not a distributed deletion marker.
    ///
    /// - Parameter parentID: The picture. Never re-derived.
    /// - Parameter childID: The voice material, exactly as displayed.
    /// - Parameter workItemID: The desk both must sit on.
    /// - Parameter expectedOwnerRevision: Compare-and-swap token, supplied by
    ///   the board path that knows which revision the person saw. Nil skips the
    ///   comparison, in the same sense it does for every other material
    ///   mutation here.
    func deleteWorkMaterialGroup(
        parentID: UUID,
        childID: UUID,
        workItemID: UUID,
        expectedOwnerRevision: Int64? = nil
    ) async throws {
        try await ensureLoaded()
        let context = newWriteContext()
        let vaultKeys = try await context.perform { [context] () -> [String] in
            // A card is not its own companion. Unreachable through the kind
            // checks below — one row cannot be both a voice material and an
            // `.image` — and stated anyway, because the deletion that follows
            // would otherwise be handed the same rows twice.
            guard parentID != childID else {
                throw WorkboardStoreError.invalidMaterialCompanion
            }
            let childRows = try Self.workMaterialRows(
                id: childID, ownedBy: workItemID, in: context
            )
            guard let childRow = Self.canonicalRow(among: childRows) else {
                throw WorkboardStoreError.materialNotFound
            }
            let childKind = WorkMaterialKind(stored: childRow.value(forKey: "kind") as? String)
            guard childKind == .audio || childKind == .transcript else {
                throw WorkboardStoreError.invalidMaterialCompanion
            }
            guard let link = childRow.value(forKey: "attachedToMaterialID") as? UUID else {
                throw WorkboardStoreError.invalidMaterialCompanion
            }
            let resolved = try Self.eligibleCompanionPictureID(
                link: link, child: childID, workItemID: workItemID, in: context
            )
            guard resolved == parentID else {
                throw WorkboardStoreError.invalidMaterialCompanion
            }
            // Non-empty by construction: the resolution above found a canonical
            // row for exactly this id on exactly this desk.
            let parentRows = try Self.workMaterialRows(
                id: parentID, ownedBy: workItemID, in: context
            )
            guard !parentRows.isEmpty else {
                throw WorkboardStoreError.materialNotFound
            }

            // The pair is proved before the token is compared, so a refusal
            // says which of the two things was wrong.
            try Self.requireOwnerRevision(
                expectedOwnerRevision, ownerID: workItemID, in: context
            )

            let rows = parentRows + childRows
            let keys = Set(rows.compactMap { $0.value(forKey: "localVaultKey") as? String })
            rows.forEach(context.delete)
            try Self.deleteBlobRows(materialID: parentID, in: context)
            try Self.deleteBlobRows(materialID: childID, in: context)
            // ONE timestamp for the pair. Two would be two revisions, and the
            // board would have to be told twice that one card went.
            if let item = try Self.workItemRow(id: workItemID, in: context) {
                item.setValue(Date(), forKey: "updatedAt")
            }
            try context.save()
            return keys.sorted()
        }
        for key in vaultKeys { try? await workAssetVault.remove(key) }
        // ONE notification, after both cards and both payloads are gone.
        await postDidChange()
    }

    /// Rank the board's cards through the SAME rewrite the editor's autosave
    /// uses, so the two surfaces cannot disagree about what order means. Order
    /// is canonical: it decides the dispatch prompt, so this deliberately
    /// advances the item's revision and an already-sent run is honestly marked
    /// as changed.
    ///
    /// TWO WAYS TO GUARD THE SAME WRITE, and a caller picks exactly one.
    ///
    /// `expectedOwnerRevision` is the plain compare-and-swap the other material
    /// mutations use: supplied, it refuses a rewrite built on an order the
    /// person never saw. It is the right guard for a caller that rewrites the
    /// desk wholesale.
    ///
    /// `baseline` is the drag's guard, and it REBASES rather than refuses. A
    /// drag is a direct-manipulation gesture the person has already completed,
    /// so answering an unrelated arrival with "your move did not happen" is a
    /// worse outcome than keeping the move and the arrival both. The baseline
    /// carries the canonical order the drag was planned on; the rewrite is
    /// accepted when the desk's current canonical order is still that baseline
    /// with new ids APPENDED, and the accepted order is then the proposed
    /// permutation followed by those new ids. A baseline therefore SUPERSEDES
    /// the revision token — the revision has necessarily moved in exactly the
    /// case the rebase exists to accept — so passing both is a caller error and
    /// the baseline wins.
    ///
    /// This is LOCAL validation, not a distributed compare-and-swap. Two
    /// devices reordering at once still merge through the store's ordinary
    /// record merge; what a baseline buys is that THIS device never writes an
    /// arrangement built on a board it can see has moved on.
    @discardableResult
    func reorderWorkMaterials(
        itemID: UUID,
        orderedMaterialIDs: [UUID],
        baseline: WorkboardReorderBaseline? = nil,
        expectedOwnerRevision: Int64? = nil
    ) async throws -> WorkItemRecord {
        try await ensureLoaded()
        let context = newWriteContext()
        let changed = try await context.perform { [context] in
            guard let owner = try Self.workItemRow(id: itemID, in: context) else {
                throw WorkboardStoreError.itemNotFound
            }
            let finalOrder: [UUID]
            if let baseline {
                let desk = try Self.canonicalMaterialOrder(workItemID: itemID, in: context)
                guard let rebased = WorkboardReorderRebase.rebased(
                    proposed: orderedMaterialIDs,
                    baseline: baseline,
                    current: desk.order,
                    currentAttachments: desk.attachments
                ) else {
                    throw WorkboardStoreError.staleRevision
                }
                finalOrder = rebased
            } else {
                if let expectedOwnerRevision {
                    guard let updatedAt = owner.value(forKey: "updatedAt") as? Date,
                          Self.workRevision(for: updatedAt) == expectedOwnerRevision else {
                        throw WorkboardStoreError.staleRevision
                    }
                }
                finalOrder = orderedMaterialIDs
            }
            let rewrite = try Self.rewriteWorkMaterialSequence(
                orderedMaterialIDs: finalOrder,
                workItemID: itemID,
                in: context
            )
            guard rewrite.didChange else { return false }
            let now = Date()
            owner.setValue(
                Self.advancedWriteStamp(
                    now,
                    notBelow: [owner.value(forKey: "updatedAt") as? Date].compactMap { $0 }
                ),
                forKey: "updatedAt"
            )
            // ONLY the canonical row of each changed material is stamped, and
            // never with a value below the rows it is standing on.
            //
            // Every PHYSICAL row is re-ranked — a duplicate left at its old rank
            // would resurrect the old order — but stamping them all with the
            // SAME instant flattens the `revision` key that decides which
            // duplicate a read answers from, and the tie then falls through to
            // `createdAt`, the title and the content hash. A merged card whose
            // duplicates disagree about any of those would silently swap which
            // one wins because somebody moved it. Advancing the winner alone
            // keeps it the winner.
            //
            // Advancing it PAST EVERY DUPLICATE is the other half, and a plain
            // `Date()` does not do it: a row synced from a device whose clock
            // ran ahead carries a future `updatedAt`, so the local instant
            // lowers the winner under a duplicate that is merely less far
            // ahead and promotes the loser — the same silent content swap, out
            // of the fix for it. See `advancedWriteStamp`.
            var rowsByID: [UUID: [NSManagedObject]] = [:]
            for material in rewrite.materials {
                guard let id = material.value(forKey: "id") as? UUID else { continue }
                rowsByID[id, default: []].append(material)
            }
            for rows in rowsByID.values where rows.contains(where: { $0.hasChanges }) {
                guard let winner = Self.canonicalRow(among: rows) else { continue }
                let priors = rows.map {
                    Self.materialRevisionDate(
                        updatedAt: $0.value(forKey: "updatedAt") as? Date,
                        createdAt: $0.value(forKey: "createdAt") as? Date
                    )
                }
                winner.setValue(
                    Self.advancedWriteStamp(now, notBelow: priors),
                    forKey: "updatedAt"
                )
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

    /// Edit only user-authored text on one existing material. File/link source
    /// content is never rewritten here, and user notes remain synced metadata
    /// even when the original payload is device-local. The material revision
    /// guards this edit independently of unrelated cards and layout changes.
    /// Publication locking serializes this writer with capture and reattach;
    /// every physical duplicate receives the edited fields, while the current
    /// canonical row keeps revision precedence over older source variants.
    func updateWorkMaterialText(
        id: UUID,
        textContent: String?,
        annotation: String?,
        expectedRevision: Int64
    ) async throws -> WorkMaterialRecord {
        guard [textContent, annotation].compactMap({ $0 }).allSatisfy({
            $0.count <= WorkItemContentLimits.maximumFieldCharacters
        }) else { throw WorkboardStoreError.contentTooLong }
        let savedAnnotation = annotation.flatMap {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0
        }
        while workMaterialPublicationClaims.contains(id) {
            try await Task.sleep(for: .milliseconds(40))
        }
        workMaterialPublicationClaims.insert(id)
        defer { workMaterialPublicationClaims.remove(id) }
        try await ensureLoaded()
        let hold = try await workMaterialPublicationLock?.acquire(materialID: id)
        defer { hold?.release() }
        let context = newWriteContext()
        // A concurrent import/delete must refuse this edit rather than let
        // object-trump merge silently replace a newer field or recreate a row.
        context.mergePolicy = NSErrorMergePolicy
        let changed = try await context.perform {
            let rows = try Self.workMaterialRows(id: id, in: context)
            guard let canonical = Self.canonicalRow(among: rows) else {
                throw WorkboardStoreError.materialNotFound
            }
            let owners = Set(rows.compactMap { $0.value(forKey: "workItemID") as? UUID })
            guard owners.count == 1, let ownerID = owners.first,
                  rows.allSatisfy({ $0.value(forKey: "workItemID") as? UUID == ownerID }),
                  canonical.entity.attributesByName["annotation"] != nil else {
                throw WorkboardStoreError.invalidMaterialOwner
            }
            let currentStamp = Self.materialRevisionDate(
                updatedAt: canonical.value(forKey: "updatedAt") as? Date,
                createdAt: canonical.value(forKey: "createdAt") as? Date)
            guard Self.workRevision(for: currentStamp) == expectedRevision else {
                throw WorkboardStoreError.staleRevision
            }
            if textContent != nil {
                guard rows.allSatisfy({ row in
                    let kind = WorkMaterialKind(stored: row.value(forKey: "kind") as? String)
                    let result = WorkMaterialProjectResultKind.decode(row.value(forKey: "projectResultKind") as? String)
                    return (kind == .note || kind == .transcript)
                        && result != .reference && result != .unknown
                        && WorkMaterialStorageMode(stored: row.value(forKey: "storageMode") as? String) == .metadataOnly
                }) else { throw WorkboardStoreError.invalidMaterialOwner }
            }
            let needsWrite = rows.contains { row in
                row.value(forKey: "annotation") as? String != savedAnnotation
                    || textContent.map { row.value(forKey: "textContent") as? String != $0 } == true
            }
            guard needsWrite else { return false }
            let stamp = Self.advancedWriteStamp(Date(), notBelow: rows.map {
                Self.materialRevisionDate(updatedAt: $0.value(forKey: "updatedAt") as? Date,
                                          createdAt: $0.value(forKey: "createdAt") as? Date)
            })
            // Older duplicates may carry different untouched source bytes,
            // names, ranks or companion links. Equal timestamps would let
            // those stale fields win the content tie-break after this edit.
            // Keep the previously canonical source strictly newer instead of
            // rewriting unrelated source metadata merely to edit a note.
            let canonicalStamp = rows.count > 1
                ? Self.advancedWriteStamp(stamp, notBelow: [stamp]) : stamp
            for row in rows {
                if let textContent {
                    let oldText = row.value(forKey: "textContent") as? String ?? ""
                    let oldDerivedTitle = WorkboardWorkspaceCaptureLogic.title(for: oldText)
                    if !oldDerivedTitle.isEmpty, row.value(forKey: "title") as? String == oldDerivedTitle {
                        row.setValue(WorkboardWorkspaceCaptureLogic.title(for: textContent), forKey: "title")
                    }
                    row.setValue(textContent, forKey: "textContent")
                }
                row.setValue(savedAnnotation, forKey: "annotation")
                row.setValue(row.objectID == canonical.objectID ? canonicalStamp : stamp, forKey: "updatedAt")
            }
            // The desk's membership and order have not changed. Touch only
            // these material rows, so simultaneous edits to other cards do
            // not contend on the shared owner row.
            do { try context.save() }
            catch let error as NSError {
                if error.domain == NSCocoaErrorDomain,
                   [NSManagedObjectMergeError, NSPersistentStoreSaveConflictsError].contains(error.code) {
                    throw WorkboardStoreError.staleRevision
                }
                throw error
            }
            return true
        }
        if changed { await postDidChange() }
        guard let material = try await fetchWorkMaterial(id: id) else {
            throw WorkboardStoreError.materialNotFound
        }
        return material
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

    /// Give synced image cards written before the import site decoded previews
    /// the preview a capture would mint today. One bounded pass; the caller is
    /// the desk's storage reconcile, which runs on appearance and on foreground.
    ///
    /// A PRESENTATION WRITE, so it stamps NO `updatedAt` — on the material or
    /// on the desk. That is the same contract `setWorkMaterialCardSize` holds
    /// and for the same reason: both revisions are derived from `updatedAt`, so
    /// stamping one would raise "Changed after this was sent" on a brief nobody
    /// touched because a thumbnail arrived, and would invalidate an approved
    /// preflight. Every PHYSICAL row is written, because CloudKit can merge one
    /// logical card into several and whichever wins the canonical read is what
    /// the person sees.
    ///
    /// THE SYNCED LANE ONLY. A vault card's preview may not be persisted at all
    /// — the row is CloudKit-mirrored and the bytes are meant to stay on this
    /// device — so a local image keeps the transient preview the live
    /// repository builds per board load and nothing here touches it.
    ///
    /// BOUNDED both ways: `workThumbnailRepairPassLimit` cards per pass, and
    /// `workThumbnailRepairDecodeWidth` decodes in flight. Bytes are read
    /// INSIDE each decode job rather than up front, so a pass holds four
    /// ceiling-sized payloads at once rather than ninety-six.
    ///
    /// UNDECODABLE CARDS ARE REMEMBERED for the life of the process. Without
    /// that, a mislabelled capture whose bytes are not an image sits at the
    /// head of every pass's window for ever and the cards behind it are never
    /// reached. The memory is keyed by the bytes the card names, so a reattach
    /// earns a fresh attempt.
    ///
    /// RE-VALIDATED AFTER THE DECODE. A reattach or a synced repair can commit
    /// while bytes are decoding, so the write refuses any row whose lane or
    /// pairing has moved since selection: a preview of a payload the card no
    /// longer holds is worse than no preview.
    @discardableResult
    func repairMissingWorkThumbnails() async -> WorkThumbnailRepairReport {
        guard (try? await ensureLoaded()) != nil else { return .empty }
        let pass = ObjectIdentifier(self)
        guard await workThumbnailBackfillMemory.beginPass(pass) else { return .empty }
        let report = await runWorkThumbnailRepairPass()
        await workThumbnailBackfillMemory.endPass(pass)
        return report
    }

    /// The pass itself, split out so the in-flight claim above is released on
    /// every exit without a `defer` that would have to spawn a task to do it.
    private func runWorkThumbnailRepairPass() async -> WorkThumbnailRepairReport {
        let context = newReadContext()
        let candidates = await context.perform { [context] () -> [WorkThumbnailCandidate] in
            let request = NSFetchRequest<NSDictionary>(entityName: "WorkMaterial")
            request.resultType = .dictionaryResultType
            // Metadata only, and `thumbnailData` is deliberately NOT among the
            // projected properties: asking for it would realize the preview of
            // every card that already has one to discover that it has one.
            request.propertiesToFetch = ["id", "contentHash", "byteSize"]
            request.predicate = NSPredicate(
                format: "kind == %@ AND storageMode == %@ AND thumbnailData == nil",
                WorkMaterialKind.image.rawValue,
                WorkMaterialStorageMode.syncedPayload.rawValue
            )
            // Newest first: the cards the person is looking at are the ones a
            // bounded pass should spend its window on.
            request.sortDescriptors = [NSSortDescriptor(key: "updatedAt", ascending: false)]
            var seen: Set<UUID> = []
            var found: [WorkThumbnailCandidate] = []
            for row in (try? context.fetch(request)) ?? [] {
                // One LOGICAL card per candidate. Duplicate physical rows are
                // repaired together by the write, so a merged card must not
                // spend two of the pass's slots.
                guard let id = row["id"] as? UUID, seen.insert(id).inserted,
                      let contentHash = row["contentHash"] as? String, !contentHash.isEmpty,
                      let byteSize = (row["byteSize"] as? NSNumber)?.int64Value else { continue }
                found.append(
                    WorkThumbnailCandidate(id: id, contentHash: contentHash, byteSize: byteSize)
                )
            }
            return found
        }

        // Filtered BEFORE the window is taken, which is the whole point of
        // remembering: the bound then applies to work that can still succeed.
        let jobs = Array(
            await workThumbnailBackfillMemory
                .unresolved(candidates)
                .prefix(workThumbnailRepairPassLimit)
        )
        guard !jobs.isEmpty else { return .empty }

        var previews: [(WorkThumbnailCandidate, Data)] = []
        var undecodable = 0
        let outcomes = await withTaskGroup(
            of: (WorkThumbnailCandidate, WorkThumbnailDecodeOutcome).self,
            returning: [(WorkThumbnailCandidate, WorkThumbnailDecodeOutcome)].self
        ) { group in
            var next = 0
            while next < jobs.count, next < workThumbnailRepairDecodeWidth {
                let job = jobs[next]
                group.addTask { (job, await self.decodeWorkThumbnail(for: job)) }
                next += 1
            }
            var values: [(WorkThumbnailCandidate, WorkThumbnailDecodeOutcome)] = []
            while let value = await group.next() {
                values.append(value)
                guard next < jobs.count else { continue }
                let job = jobs[next]
                group.addTask { (job, await self.decodeWorkThumbnail(for: job)) }
                next += 1
            }
            return values
        }
        for (candidate, outcome) in outcomes {
            switch outcome {
            case .decoded(let thumbnail):
                previews.append((candidate, thumbnail))
            case .undecodable:
                undecodable += 1
                await workThumbnailBackfillMemory.remember(candidate)
            case .unavailable:
                break
            }
        }

        let filled = await writeWorkThumbnails(previews)
        if filled > 0 { await postDidChange() }
        return WorkThumbnailRepairReport(
            examined: jobs.count,
            filled: filled,
            undecodable: undecodable
        )
    }

    /// Read one candidate's bytes and decode them, telling apart the two
    /// failures that matter: bytes that are not an image (permanent, and worth
    /// remembering) from bytes that have not arrived from iCloud yet
    /// (transient, and must not be written off).
    private func decodeWorkThumbnail(
        for candidate: WorkThumbnailCandidate
    ) async -> WorkThumbnailDecodeOutcome {
        // Paired to the CANDIDATE's own `(id, contentHash, byteSize)`, never
        // through `loadWorkMaterialPayload`: that loader answers for the
        // CANONICAL row, and a CloudKit merge can leave the canonical row on
        // other bytes — or on the vault lane entirely — while the row this
        // candidate stands for still names its own blob. The write below
        // accepts a row on the candidate's pairing alone, so a payload resolved
        // through any other row would persist one card's picture onto another
        // card's bytes, on a CloudKit-mirrored column.
        let paired = WorkMaterialBlobPairing(
            contentHash: candidate.contentHash,
            byteSize: candidate.byteSize
        )
        let blob = try? await newestCompleteBlobPayload(
            materialID: candidate.id,
            pairedWith: paired
        )
        // `?? nil` flattens the `Data??` a `try?` over an optional-returning
        // read produces: a throw and "no complete blob here yet" are the same
        // transient answer.
        guard let payload = blob ?? nil, !payload.isEmpty else {
            return .unavailable
        }
        guard let thumbnail = await Self.imagePresentationThumbnail(
            payload: payload,
            sourceFileURL: nil
        ) else {
            return .undecodable
        }
        return .decoded(thumbnail)
    }

    /// Write the decoded previews onto every physical row that still names the
    /// bytes they were decoded from, in ONE save and with no timestamp of any
    /// kind. Returns the number of LOGICAL cards that gained a preview.
    private func writeWorkThumbnails(
        _ previews: [(WorkThumbnailCandidate, Data)]
    ) async -> Int {
        guard !previews.isEmpty else { return 0 }
        let context = newWriteContext()
        return await context.perform { [context] () -> Int in
            var written = 0
            for (candidate, thumbnail) in previews {
                let rows = (try? Self.workMaterialRows(id: candidate.id, in: context)) ?? []
                var touched = false
                for row in rows {
                    // Authoritative HERE and nowhere earlier: between selection
                    // and this save a reattach can have moved the card onto
                    // other bytes, or off the synced lane entirely.
                    guard Self.namesSyncedPayload(
                        row: row,
                        contentHash: candidate.contentHash,
                        byteSize: candidate.byteSize
                    ), row.value(forKey: "thumbnailData") == nil else { continue }
                    row.setValue(thumbnail, forKey: "thumbnailData")
                    touched = true
                }
                if touched { written += 1 }
            }
            guard written > 0 else { return 0 }
            // No `updatedAt` on the rows and no touch on the desk row: see the
            // contract on `repairMissingWorkThumbnails`.
            try? context.save()
            return written
        }
    }

    /// One card and its bytes together; nil when no card carries that id, and a nil payload when the card's bytes have not arrived here yet.
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
        let payloadSource = try await context.perform {
            [context] () -> (WorkMaterialStorageMode, String?, WorkMaterialBlobPairing)? in
            guard let row = try Self.workMaterialRow(id: id, in: context) else { return nil }
            let mode = WorkMaterialStorageMode(stored: row.value(forKey: "storageMode") as? String)
            let pairing = WorkMaterialBlobPairing(
                contentHash: row.value(forKey: "contentHash") as? String,
                byteSize: (row.value(forKey: "byteSize") as? NSNumber)?.int64Value ?? 0
            )
            return (mode, row.value(forKey: "localVaultKey") as? String, pairing)
        }
        guard let payloadSource else { return nil }
        switch payloadSource.0 {
        case .metadataOnly:
            return nil
        case .syncedPayload:
            return try await newestCompleteBlobPayload(
                materialID: id,
                pairedWith: payloadSource.2
            )
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
    ///
    /// Internal rather than private because it is also the STORE TRUTH a
    /// surface has to consult before it hands a card's bytes outside the app.
    /// A board snapshot cannot answer that question: the desk reloads behind a
    /// debounce, so a card the store has already replaced or deleted is still
    /// on the board — and the bytes are then resolved from the store by id,
    /// which is how replacement bytes end up leaving under the previous
    /// revision's filename and type.
    func fetchWorkMaterial(id: UUID) async throws -> WorkMaterialRecord? {
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

        let vaultKeys = Set(materials.compactMap(\.localVaultKey))
        var availableLocalKeys: Set<String> = []
        if !vaultKeys.isEmpty {
            availableLocalKeys = await readableVaultKeys(among: vaultKeys)
        }

        // Only a card that CLAIMS synced bytes asks the payload store anything,
        // so the predicate carries exactly the ids whose answer is read — and
        // each carries the blob it names, so a card is present only when the
        // payload it published is there. `uniquingKeysWith` because one material
        // id can appear under two owners while a legacy row is being adopted;
        // both name the same bytes.
        let pairings = Dictionary(
            materials.compactMap { material -> (UUID, WorkMaterialBlobPairing)? in
                guard material.storageMode == .syncedPayload else { return nil }
                return (
                    material.id,
                    WorkMaterialBlobPairing(
                        contentHash: material.contentHash,
                        byteSize: material.byteSize
                    )
                )
            },
            uniquingKeysWith: { first, _ in first }
        )
        let completeBlobMaterialIDs = Set(
            try await workMaterialBlobCompleteness(
                materialIDs: Set(pairings.keys),
                pairedWith: pairings
            ).keys
        )

        return materials.map {
            $0.record(
                availableLocalKeys: availableLocalKeys,
                completeBlobMaterialIDs: completeBlobMaterialIDs
            )
        }
    }

    /// Which of these vault keys this device can actually serve — the ONE place
    /// availability asks the vault anything.
    ///
    /// Readability, not existence: a path that merely stats is not payload, and
    /// a card built on one would read `availableLocally` and license the
    /// drainer to drop the only other copy of the capture. And one call for the
    /// whole set, not one per card: each is a hop onto the vault actor, so a
    /// per-card loop queues a board's worth of round trips behind every write
    /// in flight, on the path a board refresh runs on.
    private func readableVaultKeys(among keys: Set<String>) async -> Set<String> {
        #if CONDUCK_TESTING
        projectionVaultReadabilityCallsForTesting += 1
        #endif
        return await workAssetVault.readableKeys(among: keys)
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
            // The SAME total ordering the single-row read uses. Comparing only
            // the three human-meaningful keys let a tie fall through to "keep
            // whichever arrived first", and this candidate list is ordered by
            // `(sequence, createdAt)` while that read's is ordered by timestamp
            // — so the two disagreed on exactly the rows where it mattered.
            if material.canonicalOrder > current.canonicalOrder {
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

    /// The one physical row of a material every single-row read answers from.
    ///
    /// The newest-wins rule is applied HERE rather than by the fetch, and that
    /// is the whole point of the function. `updatedAt` is nullable and every
    /// projection substitutes `createdAt` for a row that carries none
    /// (`materialRevisionDate`) — which no `NSSortDescriptor` can express. A
    /// descriptor on the raw column sorts NULL last, so an undated duplicate
    /// that the BOARD reads as the canonical row was the one row this read
    /// could never return: the desk described one duplicate while the payload,
    /// the vault URL and the share gate answered from the other. Comparing the
    /// substituted value closes that, and it is the same tuple
    /// `deduplicatedWorkMaterials` compares.
    ///
    /// There is no "first of the equals" rule here, because
    /// `WorkMaterialCanonicalOrder` is TOTAL: whatever order the fetch returns,
    /// the maximum is the same row, and it is the same row the projection
    /// selects from its own differently-ordered candidate list.
    private static func workMaterialRow(id: UUID, in context: NSManagedObjectContext) throws -> NSManagedObject? {
        canonicalRow(among: try workMaterialRows(id: id, in: context))
    }

    /// The selection itself, split from the fetch so both orders of the same
    /// candidate set are reachable from a test.
    nonisolated static func canonicalRow(among rows: [NSManagedObject]) -> NSManagedObject? {
        rows.max { canonicalOrder(of: $0) < canonicalOrder(of: $1) }
    }

    /// One physical row's place in `WorkMaterialCanonicalOrder`.
    ///
    /// Read straight off a managed object, from the RAW columns, and it is the
    /// only place an ordering is built: the projection routes through it too,
    /// so the two selectors cannot drift into computing a key differently. The
    /// raw columns matter — an enum that maps an unrecognised lane or kind onto
    /// a default would erase exactly the difference this ordering is trying to
    /// see.
    nonisolated static func canonicalOrder(of row: NSManagedObject) -> WorkMaterialCanonicalOrder {
        // Every row these selectors compare comes from a fetch on a fresh read
        // or write context, and the one caller that inserts (`upsertDeskMaterial`)
        // selects BEFORE it inserts — so no temporary id reaches a comparison.
        // A fetch CAN return pending inserts, which is why this is an assertion
        // about the callers rather than about fetches in general, and why it is
        // checked rather than asserted in prose.
        assert(
            !row.objectID.isTemporaryID,
            "a temporary object id is not stable, so it cannot decide a canonical row"
        )
        // The RAW columns, every one of them optional in the model — so the
        // ordering carries presence and never a substituted default. `revision`
        // is the exception and takes the substitution deliberately: it is the
        // value every reader compares.
        let createdAt = row.value(forKey: "createdAt") as? Date
        return WorkMaterialCanonicalOrder(
            revision: materialRevisionDate(
                updatedAt: row.value(forKey: "updatedAt") as? Date,
                createdAt: createdAt
            ),
            createdAt: createdAt,
            title: row.value(forKey: "title") as? String,
            contentHash: row.value(forKey: "contentHash") as? String,
            localVaultKey: row.value(forKey: "localVaultKey") as? String,
            storageMode: row.value(forKey: "storageMode") as? String,
            byteSize: (row.value(forKey: "byteSize") as? NSNumber)?.int64Value,
            kind: row.value(forKey: "kind") as? String,
            textContent: row.value(forKey: "textContent") as? String,
            urlString: row.value(forKey: "urlString") as? String,
            filename: row.value(forKey: "filename") as? String,
            mimeType: row.value(forKey: "mimeType") as? String,
            caption: row.value(forKey: "caption") as? String,
            cardSize: row.value(forKey: "cardSize") as? String,
            attachedToMaterialID: row.value(forKey: "attachedToMaterialID") as? UUID,
            thumbnailData: row.value(forKey: "thumbnailData") as? Data,
            rowKey: row.objectID.uriRepresentation().absoluteString,
            annotation: row.entity.attributesByName["annotation"] == nil ? nil : row.value(forKey: "annotation") as? String
        )
    }

    /// The desk's CANONICAL order and its companion links, read inside a write
    /// context.
    ///
    /// One logical material can hold several physical rows, so each id answers
    /// from `canonicalRow(among:)` — the same row every other read answers from
    /// — and the order is the same `(sequence, createdAt, id)` tuple the board's
    /// projection sorts by. A baseline compared against anything else would
    /// refuse arrangements the person is looking at.
    private static func canonicalMaterialOrder(
        workItemID: UUID,
        in context: NSManagedObjectContext
    ) throws -> (order: [UUID], attachments: [UUID: UUID]) {
        let request = NSFetchRequest<NSManagedObject>(entityName: "WorkMaterial")
        request.predicate = NSPredicate(format: "workItemID == %@", workItemID as CVarArg)
        var rowsByID: [UUID: [NSManagedObject]] = [:]
        for row in try context.fetch(request) {
            guard let id = row.value(forKey: "id") as? UUID else { continue }
            rowsByID[id, default: []].append(row)
        }
        var keyed: [(id: UUID, sequence: Int, createdAt: Date)] = []
        var attachments: [UUID: UUID] = [:]
        for (id, rows) in rowsByID {
            guard let winner = canonicalRow(among: rows) else { continue }
            keyed.append((
                id: id,
                sequence: (winner.value(forKey: "sequence") as? NSNumber)?.intValue ?? 0,
                createdAt: winner.value(forKey: "createdAt") as? Date ?? .distantPast
            ))
            if let named = winner.value(forKey: "attachedToMaterialID") as? UUID {
                attachments[id] = named
            }
        }
        let order = keyed
            .sorted { ($0.sequence, $0.createdAt, $0.id.uuidString) < ($1.sequence, $1.createdAt, $1.id.uuidString) }
            .map(\.id)
        return (order, attachments)
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
    ///
    /// `thumbnailData` overrides the draft's the same way and for a sibling
    /// reason: a preview the STORE decoded from the bytes it staged outranks
    /// one the caller did not supply. A draft that carries its own is left
    /// alone.
    private static func apply(
        _ draft: WorkMaterialDraft,
        workItemID: UUID,
        storageMode: WorkMaterialStorageMode,
        byteSize: Int64,
        localVaultKey: String?,
        contentHash: String? = nil,
        thumbnailData: Data? = nil,
        sequence: Int? = nil,
        updatedAt: Date,
        to row: NSManagedObject
    ) {
        row.setValue(draft.id, forKey: "id")
        row.setValue(workItemID, forKey: "workItemID")
        row.setValue(draft.kind.rawValue, forKey: "kind")
        row.setValue(draft.title, forKey: "title")
        row.setValue(draft.caption, forKey: "caption")
        if row.entity.attributesByName["annotation"] != nil { row.setValue(draft.annotation, forKey: "annotation") }
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
            storageMode == .syncedPayload ? (thumbnailData ?? draft.thumbnailData) : nil,
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
        // The blob this card names, on the lane that has one. See
        // `WorkMaterialBlobPairing`: a card claims the bytes it published, not
        // whatever blob happens to carry its id.
        row.setValue(storageMode == .syncedPayload ? contentHash : nil, forKey: "contentHash")
        row.setValue(draft.cardSize.storedValue, forKey: "cardSize")
        // Straight off the draft, unconditionally — including the nil that
        // every card but a companion recording carries. The lane that mints the
        // draft is the ONE place that decides whether a capture produced a
        // picture as well; this write may not second-guess it from columns
        // (a kind, a mime type) that describe the recording rather than the
        // press it came from.
        row.setValue(draft.attachedToMaterialID, forKey: "attachedToMaterialID")
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
        let annotation: String?
        let urlString: String?
        let filename: String?
        let mimeType: String?
        let thumbnailData: Data?
        let width: Int?
        let height: Int?
        let byteSize: Int64
        let storageMode: WorkMaterialStorageMode
        /// The blob this row names on the synced lane, read straight off the
        /// material so the availability batch can match without touching the
        /// payload store's bytes.
        let contentHash: String?
        let localVaultKey: String?
        let sourceDevice: String?
        let sequence: Int
        let cardSize: WorkMaterialCardSize
        /// The picture this recording named when it published. Projected raw —
        /// nothing here checks that the named material exists, is an image or
        /// even sits on this desk, because a link is a statement about the
        /// press, not about what has landed yet. Resolution belongs to the
        /// reader that draws the board.
        let attachedToMaterialID: UUID?
        let createdAt: Date
        let updatedAt: Date
        let projectResultKind: WorkMaterialProjectResultKind?
        /// Where this row sits in the one ordering both selectors use, built by
        /// `ConversationStore.canonicalOrder(of:)` from the row this was
        /// projected from — the SAME call the single-row read makes, so the two
        /// cannot compute a key differently. Nothing displays or persists it.
        let canonicalOrder: WorkMaterialCanonicalOrder

        init(_ row: NSManagedObject) {
            id = row.value(forKey: "id") as? UUID ?? UUID()
            workItemID = row.value(forKey: "workItemID") as? UUID ?? UUID()
            kind = WorkMaterialKind(stored: row.value(forKey: "kind") as? String)
            title = row.value(forKey: "title") as? String ?? ""
            caption = row.value(forKey: "caption") as? String ?? ""
            annotation = row.entity.attributesByName["annotation"] == nil ? nil : row.value(forKey: "annotation") as? String
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
            contentHash = row.value(forKey: "contentHash") as? String
            localVaultKey = row.value(forKey: "localVaultKey") as? String
            sourceDevice = row.value(forKey: "sourceDevice") as? String
            sequence = (row.value(forKey: "sequence") as? NSNumber)?.intValue ?? 0
            cardSize = WorkMaterialCardSize(stored: row.value(forKey: "cardSize") as? String)
            attachedToMaterialID = row.value(forKey: "attachedToMaterialID") as? UUID
            createdAt = row.value(forKey: "createdAt") as? Date ?? .distantPast
            updatedAt = ConversationStore.materialRevisionDate(
                updatedAt: row.value(forKey: "updatedAt") as? Date,
                createdAt: createdAt
            )
            projectResultKind = WorkMaterialProjectResultKind.decode(
                row.entity.attributesByName["projectResultKind"] == nil ? nil : row.value(forKey: "projectResultKind") as? String)
            canonicalOrder = ConversationStore.canonicalOrder(of: row)
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
                // is not the proof. Only a COMPLETE blob row THIS CARD NAMES is,
                // and `WorkMaterialBlobRecord.isComplete` plus
                // `WorkMaterialBlobPairing` are where those two rules live;
                // membership of this set already carries both.
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
                contentHash: contentHash,
                localVaultKey: localVaultKey,
                sourceDevice: sourceDevice,
                sequence: sequence,
                cardSize: cardSize,
                attachedToMaterialID: attachedToMaterialID,
                createdAt: createdAt,
                updatedAt: updatedAt,
                projectResultKind: projectResultKind,
                annotation: annotation
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
                    workItemID: row.value(forKey: "workItemID") as? UUID,
                    sequence: (row.value(forKey: "sequence") as? NSNumber)?.int32Value,
                    cardSize: row.value(forKey: "cardSize") as? String,
                    storageMode: row.value(forKey: "storageMode") as? String,
                    localVaultKey: row.value(forKey: "localVaultKey") as? String,
                    contentHash: row.value(forKey: "contentHash") as? String,
                    byteSize: (row.value(forKey: "byteSize") as? NSNumber)?.int64Value,
                    attachedToMaterialID: row.value(forKey: "attachedToMaterialID") as? UUID,
                    updatedAt: row.value(forKey: "updatedAt") as? Date,
                    thumbnailByteCount: (row.value(forKey: "thumbnailData") as? Data)?.count,
                    title: row.value(forKey: "title") as? String,
                    textContent: row.value(forKey: "textContent") as? String,
                    annotation: row.value(forKey: "annotation") as? String
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
    ///
    /// - Parameter updatedAt: Stamp for the copy. A duplicate that is NEWER than
    ///   the row a write touched is the only way to prove a write reached every
    ///   physical row: with equal stamps the canonical read picks the touched
    ///   row anyway, so a write that skipped the duplicate would still look
    ///   correct through the projection.
    /// - Parameters contentHash, byteSize: The PAIRING the copy names, when it
    ///   has to differ from the source's. Two offline devices publishing
    ///   different bytes under one material id is an ordinary merge, and it is
    ///   the only way one card ends up with physical rows naming different
    ///   blobs — a copy of the source's own columns cannot produce it, and no
    ///   public API can, because every repair writes every row together. Both
    ///   default to the source's value; neither can CLEAR a column, because the
    ///   states worth staging all name some blob.
    /// - Parameter localVaultKey: the leaf the copy names. Two DEVICE-LOCAL rows
    ///   name no blob at all, so they tie on `contentHash` while holding
    ///   different bytes — this is the only way to build that pair.
    /// - Parameter sequence: the rank the copy carries. Two devices can rank one
    ///   card differently before their orders converge, and rank is what decides
    ///   the BOARD's candidate order, so it is how a test makes the two
    ///   selectors see the same rows in different sequences.
    /// - Parameter attachedToMaterialID: the picture the copy names. A recording
    ///   that published on one device before its picture existed and on another
    ///   after is imported as two rows differing in NOTHING ELSE, and the
    ///   canonical ordering has to settle that from synced columns alone — this
    ///   is the only way to build the pair. Like `contentHash` it cannot CLEAR
    ///   the column; the source's own value is what a nil leaves standing.
    func _duplicateWorkMaterialRowForTesting(
        id: UUID,
        updatedAt: Date? = nil,
        contentHash: String? = nil,
        byteSize: Int64? = nil,
        localVaultKey: String? = nil,
        sequence: Int? = nil,
        attachedToMaterialID: UUID? = nil
    ) async {
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
            if let updatedAt { copy.setValue(updatedAt, forKey: "updatedAt") }
            if let contentHash { copy.setValue(contentHash, forKey: "contentHash") }
            if let byteSize { copy.setValue(NSNumber(value: byteSize), forKey: "byteSize") }
            if let localVaultKey { copy.setValue(localVaultKey, forKey: "localVaultKey") }
            if let sequence {
                copy.setValue(NSNumber(value: Int32(clamping: sequence)), forKey: "sequence")
            }
            if let attachedToMaterialID {
                copy.setValue(attachedToMaterialID, forKey: "attachedToMaterialID")
            }
            try? context.save()
        }
    }

    /// TEST SEAM — what each selector picks for one material, from the SAME
    /// candidate set, handed to it in both directions.
    ///
    /// WHY IT HAS TO EXIST. The property under test is that the projection and
    /// the single-row read return the SAME physical row, and neither is
    /// reachable from outside: one is a private static over a private
    /// projection type, the other a private fetch helper. Asserting it through
    /// the public API instead — compare the board's card to what the payload
    /// read serves — proves the two agree on THIS store's fetch order and says
    /// nothing about the other one, which is exactly the case that used to
    /// break. Reversing the candidate list is the only way to see it.
    ///
    /// - Returns: four row keys — the projection's winner and the single-row
    ///   read's, each from the candidate list forward and reversed. They must
    ///   all be the same string.
    func _canonicalRowKeysForTesting(id: UUID) async -> [String] {
        do { try await ensureLoaded() } catch { return [] }
        let context = newWriteContext()
        return await context.perform { [context] () -> [String] in
            guard Self.isInMemory(context) else { return [] }
            // The BOARD's candidate order: how `loadWorkboard` sorts materials
            // before projecting them.
            let request = NSFetchRequest<NSManagedObject>(entityName: "WorkMaterial")
            request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
            request.sortDescriptors = [
                NSSortDescriptor(key: "sequence", ascending: true),
                NSSortDescriptor(key: "createdAt", ascending: true),
            ]
            let rows = (try? context.fetch(request)) ?? []
            guard !rows.isEmpty else { return [] }
            let projected = rows.map(StoredWorkMaterial.init)

            func projectionWinner(_ candidates: [StoredWorkMaterial]) -> String? {
                Self.deduplicatedWorkMaterials(candidates)
                    .first { $0.id == id }?
                    .canonicalOrder.rowKey
            }
            func rowWinner(_ candidates: [NSManagedObject]) -> String? {
                Self.canonicalRow(among: candidates)?.objectID.uriRepresentation().absoluteString
            }

            return [
                projectionWinner(projected),
                projectionWinner(projected.reversed()),
                rowWinner(rows),
                rowWinner(rows.reversed()),
            ].compactMap { $0 }
        }
    }

    /// TEST SEAM — restamp the ONE physical row naming a given payload.
    ///
    /// WHY IT HAS TO EXIST. A peer updating its own mirrored row is the ordinary
    /// way `updatedAt` moves on ONE duplicate and not the others: CloudKit
    /// delivers that row's record and nothing else. No public API here can
    /// produce it, because every local write deliberately touches every physical
    /// row of a material — that is the invariant the duplicate-tolerant writes
    /// exist to hold. Without a seam, the whole question of whether a rollback
    /// leaves a later peer update able to win is unreachable, and it is exactly
    /// the question `restoredRevisionStamps` answers. Same in-memory gate as
    /// every other seam.
    ///
    /// - Parameter contentHash: names WHICH duplicate to restamp. It is what
    ///   distinguishes rows that carry different bytes, and therefore the only
    ///   handle on "the row the peer owns" that does not depend on fetch order.
    /// - Parameter updatedAt: `nil` CLEARS the column, which is the other state
    ///   no public API reaches: a row written before the column existed, or a
    ///   peer record that carries none. Readers substitute `createdAt` for it,
    ///   so it is the shape that makes "revisionless" rows testable.
    func _setWorkMaterialRowUpdatedAtForTesting(
        id: UUID,
        contentHash: String,
        updatedAt: Date?
    ) async {
        do { try await ensureLoaded() } catch { return }
        let context = newWriteContext()
        await context.perform { [context] in
            guard Self.isInMemory(context) else { return }
            let request = NSFetchRequest<NSManagedObject>(entityName: "WorkMaterial")
            request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
                NSPredicate(format: "id == %@", id as CVarArg),
                NSPredicate(format: "contentHash == %@", contentHash),
            ])
            for row in (try? context.fetch(request)) ?? [] {
                row.setValue(updatedAt, forKey: "updatedAt")
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

    /// TEST SEAM — clear the presentation preview on every physical row of one
    /// material.
    ///
    /// WHY IT HAS TO EXIST. A synced image card with no preview is precisely
    /// the LEGACY shape the backfill is for: rows written before the import
    /// site decoded one. Every public path now mints a preview at capture and
    /// at reattach, so that shape is unreachable through the shipping surface —
    /// which is what would leave the backfill, and its no-timestamp contract,
    /// untested until a real account produced the state. Same in-memory gate as
    /// every other seam: nothing here may reach the founder's real data.
    ///
    /// - Parameter contentHash: Clears only the rows naming THIS blob, when the
    ///   duplicates of one card have to end up in different states. A merge can
    ///   leave one physical row without a preview beside another that has one
    ///   and names other bytes, and that asymmetry is the only shape in which a
    ///   backfill can be caught decoding the wrong row's payload — every row
    ///   sharing one state hides it. Nil clears every row, as a legacy card is.
    func _clearWorkMaterialThumbnailForTesting(
        materialID: UUID,
        contentHash: String? = nil
    ) async {
        do { try await ensureLoaded() } catch { return }
        let context = newWriteContext()
        await context.perform { [context] in
            guard Self.isInMemory(context) else { return }
            let request = NSFetchRequest<NSManagedObject>(entityName: "WorkMaterial")
            request.predicate = NSPredicate(format: "id == %@", materialID as CVarArg)
            for row in (try? context.fetch(request)) ?? [] {
                if let contentHash,
                   row.value(forKey: "contentHash") as? String != contentHash { continue }
                row.setValue(nil, forKey: "thumbnailData")
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
