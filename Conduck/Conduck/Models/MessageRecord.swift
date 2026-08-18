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
//
// `OutputDeliveryOutcome` and the three types it is built from
// (`RefusedOutputEntry`, `ShapeRefusalCensus`, `OutputRemainder`) live HERE
// rather than beside the detector that produces them, and the placement is
// load-bearing: this file is one of the Watch target's membership exceptions, so
// a type it references has to be compiled for watchOS too. A standalone file
// would need its own line in that exception set — i.e. a project-file edit — to
// say something this file can say for free.

import Foundation
import CoreData

/// One entry a SETTLED listing refused for its TYPE alone, retained so the
/// refusal can still be acted on after a relaunch.
///
/// The name is safe to keep and safe to show for exactly the reason the escape
/// hatch exists: the type test is the LAST guard the outbound name gate applies,
/// so an entry that reached it already passed every shape and addressability
/// guard — it is as displayable, and as addressable, as a delivered chip's
/// label. A SHAPE refusal never reaches this type at all; it is a bare count on
/// the outcome below, permanently.
///
/// `byteSize` rides along so a rescue download offered days later can still gate
/// a very large transfer without going back to the server for a second listing.
/// The `storedKey` deliberately does NOT: `<outputBoxKey>/<name>` rebuilds it
/// from a column the row already carries, and a second copy of a key is a second
/// thing that can drift away from the first.
///
/// The short coding keys are a storage decision, not a style one — this value is
/// JSON inside a CloudKit field, so every byte of key name is paid per entry per
/// device.
nonisolated struct RefusedOutputEntry: Codable, Hashable, Sendable {
    /// The server's own bytes, never repaired — a cleaned name addresses a file
    /// that does not exist.
    let name: String
    /// `<D:getcontentlength>` as the listing reported it; 0 means the server
    /// omitted it, exactly as it does on a delivered chip.
    let byteSize: Int

    private enum CodingKeys: String, CodingKey {
        case name = "n"
        case byteSize = "b"
    }
}

/// How many of a folder's SHAPE refusals were of which KIND, carried as ONE
/// value so no caller can hold half of it.
///
/// THE SPLIT EXISTS BECAUSE ONE SENTENCE WAS COVERING NINE GUARDS and was false
/// for the commonest of them. A long, ordinary filename — an agent deriving one
/// from a section heading — is refused by a length budget and nothing else, so
/// telling its author the name "could be read as an instruction, or hides itself
/// from a listing" describes an attack that did not happen. The classes come
/// from `FileServerClient.OutboxShapeRefusal`, which carries no name and no bytes
/// out of the listing, so counting them here costs the shape arm none of its
/// silence.
///
/// STILL NO NAMES. Every value this type can hold is a triple of integers; the
/// population it describes is exactly the one the outbound gate exists to keep
/// out of the app's own voice, and it has no rescue and no review.
nonisolated struct ShapeRefusalCensus: Hashable, Sendable {
    /// Refused because the name overran `storedKeyComponentMaxCharacters` or
    /// `storedKeyComponentMaxBytes`. ONE OF THE TWO ACTIONABLE CLASSES: the
    /// user can ask their agent for a shorter name and the file comes through.
    let overlongCount: Int
    /// Refused because the name opens or closes on a space. THE OTHER
    /// ACTIONABLE CLASS, and counted apart from `overlongCount` rather than
    /// folded in with it because the two ask the user for DIFFERENT things — a
    /// shorter name against a name without the stray space. Folding them would
    /// buy one column at the price of a sentence that names both causes when
    /// only one happened, which is the vagueness this split exists to remove.
    let whitespaceBoundedCount: Int
    /// Refused by any other shape guard — a path separator, an unaddressable
    /// scalar, a leading combining mark, a leading dot or dash, an empty name.
    /// THE RESIDUAL: not negotiable and not worth enumerating, because several
    /// specific sentences nobody can act on are worse than one true generic one.
    let unusableCount: Int

    /// A folder that was READ and held no shape refusal at all. Distinct from
    /// UNKNOWN, which is carried by the optional around the whole census — see
    /// `OutputDeliveryOutcome`.
    static let nothingRefused = ShapeRefusalCensus(
        overlongCount: 0, whitespaceBoundedCount: 0, unusableCount: 0
    )

    /// The population as a whole, which is what the row's own sentence counts.
    var total: Int { overlongCount + whitespaceBoundedCount + unusableCount }

    /// Clamps at zero on every arm: a negative census is not a smaller fact, it
    /// is a broken one.
    init(overlongCount: Int, whitespaceBoundedCount: Int, unusableCount: Int) {
        self.overlongCount = max(overlongCount, 0)
        self.whitespaceBoundedCount = max(whitespaceBoundedCount, 0)
        self.unusableCount = max(unusableCount, 0)
    }
}

/// Deliverable entries a pass SAW and did not hand over, together with whether
/// any of them can still arrive — ONE value, because the count and its cause are
/// only ever true together.
///
/// WHY NOT A COUNT PLUS A FLAG: the row's whole job is to say either "ask again
/// and the rest come" or "these are not coming, save them by hand", and a caller
/// holding a bare count next to a bare `Bool?` can read the second as the first's
/// default. Here there is nothing to default: `.recoverable` cannot be spelled
/// without a pass having proved it, so a row that recorded a remainder without
/// recording its cause reads `.unknownCause` and can never be mistaken for a
/// promise.
///
/// `outputScanDone` IS NOT THIS QUESTION and cannot substitute for it. That
/// column says the turn is closed, and a truncated pass closes purely on AGE once
/// `truncatedScanHorizon` has elapsed — so a folder whose tail a later pass would
/// happily deliver reads as closed, and a row deriving permanence from it tells
/// the user the ceiling was hit and nothing more will come while "Check again"
/// would in fact deliver more.
nonisolated enum OutputRemainder: Hashable, Sendable {
    /// The pass handed over everything the folder held that it was willing to
    /// hand over. The ONLY value that may be read as "the folder is fully
    /// accounted for".
    case nothingLeft
    /// Left behind, and the message's lifetime chip allowance can still cover
    /// ALL of them — so a later pass, or the user's own "Check again", delivers
    /// the rest. The one case that may be phrased as a promise.
    case recoverable(count: Int)
    /// Left behind, and `maxOutputChipsPerMessage` means at least one of them
    /// will NEVER arrive on this message however often it is re-read. The
    /// escape hatch is the answer here, not another request.
    case ceilingCapped(count: Int)
    /// Left behind, cause not recorded — a row written by a build that did not
    /// record it. NEVER read as recoverable: an unproven promise is the one
    /// thing this type exists to make unspellable.
    case unknownCause(count: Int)

    /// Rebuild from the two persisted columns. A count at or below zero is
    /// `.nothingLeft` whatever the flag says, so "no remainder with a cause"
    /// is unrepresentable and the store's change comparison converges instead
    /// of oscillating.
    init(count: Int, isRecoverable: Bool?) {
        guard count > 0 else { self = .nothingLeft; return }
        switch isRecoverable {
        case .some(true): self = .recoverable(count: count)
        case .some(false): self = .ceilingCapped(count: count)
        case .none: self = .unknownCause(count: count)
        }
    }

    /// How many entries were left behind. 0 only on `.nothingLeft`.
    var count: Int {
        switch self {
        case .nothingLeft: return 0
        case .recoverable(let count), .ceilingCapped(let count), .unknownCause(let count):
            return count
        }
    }

    /// The persisted flag. Nil on BOTH `.nothingLeft` (nothing to attribute) and
    /// `.unknownCause` (nothing was attributed), which is what makes the
    /// column's nil mean UNKNOWN in exactly one direction and lets the pair
    /// round-trip unchanged.
    var isRecoverable: Bool? {
        switch self {
        case .nothingLeft, .unknownCause: return nil
        case .recoverable: return true
        case .ceilingCapped: return false
        }
    }
}

/// What ONE listing of a reply's output folder established about the entries it
/// did not hand over, as persisted on the reply.
///
/// NIL IS NOT ZERO ANYWHERE THIS TYPE APPEARS, and the whole feature rests on
/// it. An all-zero value is a POSITIVE observation — "the folder was read and
/// nothing was withheld" — and it is what RETIRES a standing refusal, because
/// every pass recomputes the census over the whole folder. A nil outcome means
/// no census was taken at all, and writing zero in its place is the one mistake
/// that erases a true refusal on a five-second outage.
///
/// EVERY NUMBER HERE IS AN ABSOLUTE COUNT OF SOMETHING WITHHELD — never a
/// numerator, never a denominator. There is deliberately no delivered count and
/// no total: CloudKit can deliver a `Message` record and its `Attachment`
/// records at different moments, so "3 of 5" would contradict the visible chips
/// for however long the split lasts, while "2 files weren't delivered" stays
/// true throughout.
///
/// `nonisolated` because both codecs run inside a Core Data background
/// context's `perform` block — the store encodes there and the record decodes
/// there — and this project defaults an unannotated declaration to the main
/// actor.
nonisolated struct OutputDeliveryOutcome: Hashable, Sendable {
    /// Entries the listing refused for their TYPE alone, across the WHOLE
    /// folder. May exceed `typeRefusedEntries.count`, which is capped — the
    /// count is the census, the array is the offer, and they are allowed to
    /// disagree so the row can say "and N more" honestly.
    let typeRefusedCount: Int
    /// Entries refused for their SHAPE — a name that is not a single path
    /// component, carries an unaddressable scalar, opens on a dot / dash /
    /// combining mark, opens or closes on a space, or overruns a length budget —
    /// counted BY CLASS. Names, permanently, are not here: this is the
    /// population the gate exists to keep out of the app's own voice, so there
    /// is nothing to show and nothing to rescue. What the class buys is a TRUE
    /// sentence for the length refusal, which is benign and actionable and was
    /// being described as neither.
    let shapeRefused: ShapeRefusalCensus
    /// Deliverable entries the pass SAW and did not hand over because a budget
    /// ran out, together with whether any of them can still arrive — see
    /// `OutputRemainder` for why that cause is a field here and cannot be
    /// re-derived from `outputScanDone`.
    let remainder: OutputRemainder
    /// The retained offer — at most `maxRetainedRefusedNames` of the type-refused
    /// entries, SORTED BY NAME.
    ///
    /// Sorted, and not in listing order, because the order is a persisted fact:
    /// the store compares this array's ENCODING against the stored string to
    /// decide whether anything changed, and a WebDAV `PROPFIND` returns entries
    /// in whatever order the server's directory read produced — which on an
    /// ordinary ext4 box changes after any unrelated create or unlink in that
    /// folder. Unsorted, a census that is identical in every value re-encodes
    /// differently, writes, posts a reload and pushes to CloudKit, on every
    /// thread open, on every device, forever. The sort also fixes WHICH entries
    /// survive `maxRetainedRefusedNames`, so the offer itself stops depending on
    /// the server's mood.
    let typeRefusedEntries: [RefusedOutputEntry]

    /// The whole shape-refused population, which is the number the row's own
    /// sentence counts. Computed, so it can never disagree with its parts.
    var shapeRefusedCount: Int { shapeRefused.total }

    /// Deliverable entries left behind. Computed off `remainder` for the same
    /// reason: the count and its cause are one fact.
    var undeliveredCount: Int { remainder.count }

    /// The most names one outcome retains. Bounded for the same reason the
    /// delivery itself is: a folder holding more than a dozen files is a chatty
    /// agent or a hostile one, and neither earns an unbounded record in the
    /// user's own iCloud database, replicated to every device they own.
    static let maxRetainedRefusedNames = 12

    /// Whether this outcome has anything to say. An outcome that does not is
    /// still WRITTEN when it replaces one that did — that overwrite IS the
    /// retire, and it is the only one there is.
    var isSilent: Bool {
        typeRefusedCount == 0 && shapeRefusedCount == 0 && undeliveredCount == 0
    }

    /// Build an outcome, applying every bound at the ONE place they cannot be
    /// bypassed. The type count clamps at zero (a negative census is not a
    /// smaller fact, it is a broken one), and the retained array is SORTED
    /// BEFORE it is truncated — the count keeps the full census, so truncation
    /// loses the offer, never the claim, and the sort decides which part of the
    /// offer survives without asking the server what order it felt like today.
    init(
        typeRefusedCount: Int,
        shapeRefused: ShapeRefusalCensus,
        remainder: OutputRemainder,
        typeRefusedEntries: [RefusedOutputEntry]
    ) {
        self.typeRefusedCount = max(typeRefusedCount, 0)
        self.shapeRefused = shapeRefused
        self.remainder = remainder
        self.typeRefusedEntries = Array(
            Self.sortedByName(typeRefusedEntries).prefix(Self.maxRetainedRefusedNames)
        )
    }

    /// A TOTAL order over refused entries, so the same census always produces
    /// the same array whatever order the listing arrived in.
    ///
    /// On UTF-8 BYTES, not on `String`'s own comparison: this order is written
    /// into a synced field and compared against what a different OS version
    /// wrote, and byte order is the only one that cannot move under a collation
    /// or normalization change. `byteSize` breaks the tie so the order is total
    /// — `sorted(by:)` is not a stable sort, so two entries the predicate calls
    /// equal could otherwise swap between runs and re-arm the write loop the
    /// sort exists to close.
    static func sortedByName(_ entries: [RefusedOutputEntry]) -> [RefusedOutputEntry] {
        entries.sorted { lhs, rhs in
            if lhs.name.utf8.lexicographicallyPrecedes(rhs.name.utf8) { return true }
            if rhs.name.utf8.lexicographicallyPrecedes(lhs.name.utf8) { return false }
            return lhs.byteSize < rhs.byteSize
        }
    }

    // MARK: - The names blob

    /// Versioned envelope for the retained offer. Versioned so a later field can
    /// be added inside the existing column instead of costing a model version,
    /// and single-key-lettered for the same per-device byte reason as
    /// `RefusedOutputEntry`.
    private struct Envelope: Codable {
        let v: Int
        let e: [RefusedOutputEntry]

        /// The only version this build writes. A blob claiming a version this
        /// build does not know decodes to no entries rather than to guessed
        /// ones — degrade the row from "here they are" to "there were N", never
        /// to a name that means something else.
        static let currentVersion = 1
    }

    /// Encode the retained offer for storage, or nil when there is nothing to
    /// offer. Nil rather than an empty envelope so an outcome with no names
    /// stores no string at all — the counts alone carry the census.
    ///
    /// DETERMINISM IS LOAD-BEARING AND NOT COSMETIC, on BOTH axes, and it takes
    /// two independent things to get it. The store compares the encoded string
    /// against the stored one to decide whether anything changed; anything
    /// non-deterministic makes every pass a "change", which flips
    /// `changedVisibleState`, which posts `.conversationsDidChange`, which
    /// reloads, which rescans. On a turn still open that is a sync loop against
    /// the user's own iCloud, and no test that only checks values would see it.
    ///
    ///   - `.sortedKeys` fixes the order of the KEYS inside each object.
    ///   - `sortedByName` fixes the order of the ENTRIES in the array, which
    ///     `.sortedKeys` says nothing about. The array arrives in the server's
    ///     `PROPFIND` order — a directory read whose order an ordinary ext4 box
    ///     changes after any unrelated create or unlink in that folder — so
    ///     without this the same dozen names re-encode differently for no
    ///     reason at all.
    ///
    /// Sorted HERE as well as in `init`, because the two answer different
    /// questions: the initializer's sort decides which entries survive the
    /// retention cap, this one guarantees that ANY caller's array encodes to the
    /// same string as the same array in another order. A test that re-encodes
    /// one array can only see the second.
    ///
    /// `Constants.outputRefusedNamesMaxBytes` is enforced by DROPPING FROM THE
    /// TAIL and re-encoding rather than by estimating: the names are
    /// adversary-chosen and their encoded cost is not a function of their count.
    /// The tail is what goes because the array is sorted, so dropping from the
    /// tail is the one rule that yields the same surviving set whatever order
    /// the listing arrived in — which is the whole point of the sort above.
    /// Under today's name-length gate the loop exits on its first pass; it is the
    /// bound, not the common path.
    static func encodedNames(_ entries: [RefusedOutputEntry]) -> String? {
        guard !entries.isEmpty else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        var kept = Array(sortedByName(entries).prefix(maxRetainedRefusedNames))
        while !kept.isEmpty {
            guard let data = try? encoder.encode(
                Envelope(v: Envelope.currentVersion, e: kept)
            ) else { return nil }
            if data.count <= Constants.outputRefusedNamesMaxBytes {
                return String(decoding: data, as: UTF8.self)
            }
            kept.removeLast()
        }
        return nil
    }

    /// Decode the retained offer. FAILS TO EMPTY, never to a crash and never to
    /// nil-as-unknown: a blob this build cannot read means the names are gone,
    /// while the counts beside it are untouched and still true. The row degrades
    /// from "here they are" to "there were N" — the correct direction, and the
    /// reason the counts, never the array, are the UNKNOWN carrier.
    static func decodedNames(from json: String?) -> [RefusedOutputEntry] {
        guard let json, let data = json.data(using: .utf8),
              let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              envelope.v == Envelope.currentVersion else {
            return []
        }
        return Array(envelope.e.prefix(maxRetainedRefusedNames))
    }
}

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
    /// Identity of the delivery attempt this turn's `status` reports on.
    ///
    /// This is what an acknowledgement points AT: the red mark is retired only
    /// while `Conversation.failureSeenAttemptID` equals this exact value, so
    /// asking again re-arms the mark by minting a NEW id here rather than by
    /// clearing anything — which is what removes the whole class of "a stale
    /// write silenced a live failure" bug.
    ///
    /// MINTED WHERE AN ATTEMPT BEGINS AND WHERE ONE IS DECLARED FAILED, over
    /// whatever identity the row already carries: on insert as `sending`, on a
    /// retry's `failed → sending` compare-and-set, on the clone path's synthetic
    /// `failed` stamp (a row with no attempt behind it at all, so it is given
    /// one rather than inheriting the source turn's), and on every writer that
    /// declares a user turn `failed` — the plain send-state writer, the failure
    /// classifier including its classification upgrade, and the launch sweep for
    /// stale `sending` turns. `ConversationStore` owns all of them, and only a
    /// write that genuinely changes the row reaches the mint.
    ///
    /// SO WHAT AN ACKNOWLEDGEMENT MATCHES IS THE LATEST FAILURE DECLARATION,
    /// not one immutable id per semantic delivery. Preserving the id across a
    /// re-declaration is the tempting inversion, and it is the unsafe one:
    /// several authorities declare a single delivery failed — the writers above
    /// — and they run on DIFFERENT DEVICES against unreconciled replicas, while
    /// `Message` rows converge under record-level last-writer-wins. A device
    /// rejoining late would then republish, as the winning write, the identity
    /// the account has already acknowledged, for a failure whose latest attempt
    /// nobody was ever shown; `failed` is terminal, nothing touches that row
    /// again, and the message renders as though it sent. A fresh id makes that
    /// export self-defeating — it names something no acknowledgement can match,
    /// so the mark stands. The price is a bounded OVER-report, which costs one
    /// thread open, and that is the direction this app takes every time.
    /// `ConversationStore.mintDeliveryAttemptID` carries the full trace.
    ///
    /// Nil on agent turns, on a headless capture with no send at all, and on a
    /// row written before this attribute existed that no writer here has since
    /// declared failed. A nil can never be matched, so such a failure stays
    /// marked — the safe direction. The one compatibility case that runs the
    /// OTHER way is a RETRY performed by a build with no such attribute: it
    /// writes only the status column, so the row keeps the id the account
    /// already acknowledged and the re-failure resolves silent rather than red.
    /// `ConversationActivity.swift` step 2b states that exposure in full.
    let deliveryAttemptID: UUID?
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
    /// What the last listing of this reply's output folder did NOT hand over
    /// (v9 model), stored across six columns and read back as one value so a
    /// caller can never see half a census.
    ///
    /// Nil means UNKNOWN: a pre-v9 row, a row synced from a device that has not
    /// run this build, a Watch-originated turn with no folder to read, or a
    /// folder nobody has managed to read yet. An all-zero value means OBSERVED
    /// NONE — a different sentence, and the one that retires a standing row.
    ///
    /// Every EXISTING reply reads nil forever, and that is correct rather than a
    /// gap: a closed turn is never re-listed, so this is a promise about future
    /// replies, not a retroactive one.
    let outputDeliveryOutcome: OutputDeliveryOutcome?
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
        deliveryAttemptID: UUID? = nil,
        failureCode: Int? = nil,
        failureWireCode: String? = nil,
        failureHadHistoryImages: Bool? = nil,
        fileTransferLaneID: String? = nil,
        outputScanDone: Bool? = nil,
        outputScanLaneID: String? = nil,
        outputBoxKey: String? = nil,
        outputDeliveryOutcome: OutputDeliveryOutcome? = nil,
        attachments: [AttachmentRecord] = []
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.createdAt = createdAt
        self.sourceDevice = sourceDevice
        self.status = status
        self.deliveryAttemptID = deliveryAttemptID
        self.failureCode = failureCode
        self.failureWireCode = failureWireCode
        self.failureHadHistoryImages = failureHadHistoryImages
        self.fileTransferLaneID = fileTransferLaneID
        self.outputScanDone = outputScanDone
        self.outputScanLaneID = outputScanLaneID
        self.outputBoxKey = outputBoxKey
        self.outputDeliveryOutcome = outputDeliveryOutcome
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
        // `deliveryAttemptID` (v10 model): nil-tolerant, and a nil is the
        // ABSENCE of an identity rather than a default — an attempt nobody can
        // name is an attempt nobody can acknowledge, which leaves its failure
        // marked. Native UUID attribute, so a malformed value reads nil and
        // there is no string-parsing path to get wrong.
        self.deliveryAttemptID = managedObject.value(forKey: "deliveryAttemptID") as? UUID
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
        // The output-delivery census (v9 model): four non-scalar Integer 32
        // columns, one non-scalar Boolean and one JSON string, reassembled into
        // ONE optional so no caller can hold half a census. Non-scalar (→
        // NSNumber through KVC) for the same reason `failureCode` is: only that
        // form can tell an explicit ZERO — "the folder was read and nothing was
        // withheld" — apart from ABSENT, and this feature is entirely about that
        // distinction.
        //
        // PRESENCE IS DECIDED BY THE THREE POPULATION COUNTS and by nothing else.
        // The two columns below them are ATTRIBUTES OF a census — how many of the
        // shape refusals were merely long, and whether the remainder can still
        // arrive — so neither can bring a census into being. A row carrying only
        // an attribute would otherwise materialise an all-zero outcome, and
        // all-zero is the POSITIVE claim "the folder was read and nothing was
        // withheld", which such a row has not earned.
        //
        // A missing sibling reads as zero. This app writes every column in one
        // save, so a mixed row cannot originate here; the tolerant read is for a
        // row some other build wrote, and it fails toward SAYING something rather
        // than toward silence.
        let typeRefused = (managedObject.value(forKey: "outputRefusedTypeCount") as? NSNumber)?.intValue
        let shapeRefused = (managedObject.value(forKey: "outputRefusedShapeCount") as? NSNumber)?.intValue
        let undelivered = (managedObject.value(forKey: "outputUndeliveredCount") as? NSNumber)?.intValue
        if typeRefused == nil, shapeRefused == nil, undelivered == nil {
            self.outputDeliveryOutcome = nil
        } else {
            // The shape census stores its TOTAL plus the two ACTIONABLE subsets,
            // so the residual is a subtraction and the arms can never sum to
            // something other than the number the row's sentence counts. The
            // subsets are clamped into the total, and the second into what the
            // first left, for the same reason: a row whose subsets outran its
            // total is broken, and reading the overflow as "all of them were
            // merely long" would put a benign sentence on a hostile population.
            // Clamping toward the RESIDUAL is the safe direction — it can only
            // ever move a name into the class that offers the user nothing.
            let shapeTotal = max(shapeRefused ?? 0, 0)
            let overlong = min(
                max((managedObject.value(forKey: "outputRefusedShapeOverlongCount") as? NSNumber)?.intValue ?? 0, 0),
                shapeTotal
            )
            let whitespaceBounded = min(
                max((managedObject.value(forKey: "outputRefusedShapeWhitespaceCount") as? NSNumber)?.intValue ?? 0, 0),
                shapeTotal - overlong
            )
            self.outputDeliveryOutcome = OutputDeliveryOutcome(
                typeRefusedCount: typeRefused ?? 0,
                shapeRefused: ShapeRefusalCensus(
                    overlongCount: overlong,
                    whitespaceBoundedCount: whitespaceBounded,
                    unusableCount: shapeTotal - overlong - whitespaceBounded
                ),
                // Nil on the flag is UNKNOWN, never "recoverable": a remainder
                // whose cause was never recorded may not be turned into a promise
                // that a later pass will deliver it. `OutputRemainder` is what
                // makes that structural rather than a rule stated here.
                remainder: OutputRemainder(
                    count: undelivered ?? 0,
                    isRecoverable: (managedObject.value(forKey: "outputRemainderIsRecoverable") as? NSNumber)?.boolValue
                ),
                // Decoded ONCE, here, rather than at render time: `MessageRecord`
                // is compared on every repaint (that comparison is what repaints
                // a bubble at all), so a lazily-parsed blob would re-run a JSON
                // decode per row per frame — and would break the synthesized
                // `Hashable` this struct relies on.
                typeRefusedEntries: OutputDeliveryOutcome.decodedNames(
                    from: managedObject.value(forKey: "outputRefusedTypeNames") as? String
                )
            )
        }

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
