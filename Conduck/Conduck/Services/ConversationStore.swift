// SPDX-License-Identifier: Apache-2.0

// Conduck
// ConversationStore.swift
//
// Actor wrapping an NSPersistentCloudKitContainer for the two-level
// Conversation / Message store. Key architectural choices:
//   - actor + `static let shared`
//   - lazy `ensureLoaded()` gate around `loadPersistentStores`:
//     async single-flight Task over an ASYNCHRONOUS store add, so
//     no thread blocks while sqlite + CloudKit metadata open
//   - ObjectTrump merge policy:
//     set per-write on each fresh background context; the
//     main-queue `viewContext` stays unconfigured + unused
//   - `NSPersistentHistoryTracking` + RemoteChange post option
//   - `.NSPersistentStoreRemoteChange` → single coalescing
//     `.conversationsDidChange` fan-in:
//     debounced (`RemoteChangeDebouncer`) so a mirroring import
//     storm surfaces as a handful of posts, not a 1:1 refetch fan
//   - two-level CRUD
//
// Read/write posture: every fetch AND every save runs on a FRESH
// `newBackgroundContext()` inside `perform` — never the main-queue
// `viewContext` — so an operation stuck behind CloudKit sync's sqlite
// activity stalls only its own background queue, never the UI thread. Only
// `Sendable` snapshots leave the perform block; a fresh context registers no
// objects, so each fetch materializes current committed store values with no
// merge-timing dependency, and each write commits before `postDidChange()`
// fires (observers refetch committed rows — read-your-own-write holds).
//
// Account-wide attention markers: `Conversation.lastViewedAt`,
// `failureSeenAttemptID` and `tailProjection` are ordinary mirrored columns, so
// what the user has already seen is a fact about the ACCOUNT rather than about
// one device. Every write path to them obeys one rule — WRITE, SAVE AND POST
// ONLY WHEN THE VALUE ACTUALLY MOVES. It is not an optimisation. A marker write
// that always looks like a change posts `.conversationsDidChange`, which reloads
// every list, which re-stamps the open thread, which writes again — a refetch
// loop locally and a CKRecord export per turn against the user's own iCloud
// (`MessageRecord.encodedNames` documents the same failure from the other end).
// The pair also has a single-transaction entry point, because the menu bar marks
// viewed AND acknowledges on one click and two calls would mean two saves, two
// exports and a reload that can land between them and paint the row half
// updated.
//
// No Spotlight indexing (`SpotlightIndexer` / the
// `FeatureFlags` gate) — conversations are not Spotlight-surfaced in V1.
//
// CloudKit posture: sync is ENABLED wherever the process actually carries the
// iCloud container entitlement — the `cloudKitContainerOptions` attach mirrors
// the local Core Data store into the user's OWN private CloudKit database
// (developer-blind, no backend). Every other host runs LOCAL-ONLY (plain
// `NSPersistentContainer`, `cloudKit: false`), because
// `NSPersistentCloudKitContainer` fatal-asserts on an unentitled host with no
// signed-in iCloud account / unregistered container: the Simulator always, and
// any native macOS build whose process lacks the entitlement (see
// `Constants.hasICloudContainerEntitlement`, which probes macOS only). The in-memory/on-disk test seam
// is local-only by definition. History tracking + remote-change posting stay
// ON in all configurations.
//
// App Group store location is load-bearing: the headless Shortcut / App
// Intent runs in a separate process and must read+write the SAME sqlite as
// the foreground app — so the store lives in the App Group container, not the
// per-process Application Support default.

import Foundation
import CoreData
import CloudKit
import os

/// Redacted, `Sendable` snapshot of one CloudKit mirroring event — safe to cross
/// the `ConversationStore` actor boundary (the underlying
/// `NSPersistentCloudKitContainer.Event` is a non-`Sendable` class). Carries
/// domain/code only — NEVER `error.localizedDescription` (which can leak record
/// names / paths). Defined HERE (not in `CloudSyncMonitor`, which is iOS/macOS
/// only) so it is visible wherever this shared store compiles, incl. watchOS.
struct SyncEventSummary: Sendable {
    enum Kind: String, Sendable {
        case setup
        case importEvent = "import"
        case exportEvent = "export"
        case unknown
    }

    let kind: Kind
    let succeeded: Bool
    let started: Date?
    let ended: Date?
    let errorDomain: String?
    let errorCode: Int?
    let storeID: String?
    /// True iff this event failed with `CKError.quotaExceeded` (iCloud storage
    /// full) — the one event-level error sticky + actionable enough to promote to
    /// the user-facing surface.
    let isQuotaExceeded: Bool

    init(event: NSPersistentCloudKitContainer.Event) {
        switch event.type {
        case .setup: kind = .setup
        case .import: kind = .importEvent
        case .export: kind = .exportEvent
        @unknown default: kind = .unknown
        }
        succeeded = event.succeeded
        started = event.startDate
        ended = event.endDate
        if let nsError = event.error as NSError? {
            errorDomain = nsError.domain
            errorCode = nsError.code
            isQuotaExceeded = nsError.domain == CKErrorDomain
                && nsError.code == CKError.Code.quotaExceeded.rawValue
        } else {
            errorDomain = nil
            errorCode = nil
            isQuotaExceeded = false
        }
        storeID = event.storeIdentifier
    }

    /// One-line redacted form for `os_log` + the diagnostic ring buffer.
    var redactedLine: String {
        let status = succeeded ? "ok" : "FAIL"
        let err = errorDomain.map { "\($0)#\(errorCode ?? 0)" } ?? "-"
        return "\(kind.rawValue) \(status) err=\(err)"
    }
}

/// What `cloneConversation` hands back: the new conversation plus the id of the
/// turn a caller may continue.
///
/// CROSS-TARGET: declared here (in `ConversationStore.swift`, already a Watch
/// membership exception) alongside the store, and deliberately pure Foundation —
/// no `RemoteAgentRef` / `SettingsManager`, which the Watch target cannot see.
/// The caller resolves lane identity and passes a plain `String?`.
struct CloneResult: Sendable {
    let conversation: ConversationRecord
    /// The cloned trailing user turn (stamped `failed`), or nil when the thread
    /// ends on an agent reply — i.e. nothing is awaiting a continuation.
    ///
    /// WHETHER to dispatch it is not decided here and is not derived from the
    /// source row's status: the user answers that question in the clone sheet
    /// before any of this runs. The store's job is to leave the turn in a state
    /// where BOTH answers work — see the `failed` rule on `cloneConversation`.
    let continuationMessageID: UUID?
}

/// What `foldLegacyReadMarker` tells its caller about ONE device-local read
/// marker it was asked to fold into the conversation record.
///
/// THE CALLER DELETES THE DEFAULTS KEY ONLY ON A CONFIRMATION, which is the
/// whole reason this is a return value rather than a fire-and-forget call. The
/// legacy key is the read-side fallback that keeps a row from going bold while
/// the fold is pending, so deleting it on anything less than "the record now
/// covers this" loses the marker outright — the conversation reverts to unread
/// on every device, with nothing left anywhere to recover it from. A failed
/// fold keeps its key, keeps answering reads, and is retried on the next pass.
///
/// CROSS-TARGET: declared here beside the store for the same reason
/// `CloneResult` is — pure Foundation, visible to the Watch target.
enum ReadMarkerFoldOutcome: Sendable, Hashable {
    /// The record's `lastViewedAt` is already at or past the local marker, so
    /// there was nothing to write. The key is covered and may be deleted.
    case alreadyCovered
    /// The record's `lastViewedAt` moved forward to the local marker and the
    /// save committed. The key is covered and may be deleted.
    case saved
    /// Nothing was committed — the store would not load, the conversation is not
    /// present locally (an import that has not landed yet is NOT a deletion), or
    /// the save threw. KEEP THE KEY.
    case failed
}

/// The decoded form of `Conversation.tailProjection`: which message is this
/// conversation's newest, when it was written, and whether it is a reply.
///
/// WHY THE COLUMN EXISTS AT ALL. The unseen test is "the tail is an agent reply
/// AND `lastActivityAt` is past the account's view marker". iOS and macOS answer
/// the first half with a lazy per-row tail fetch; the wrist deliberately projects
/// no role, because a per-row message fetch on the slowest device in the fleet is
/// exactly what its whole list design refuses to pay — so without a projection
/// carried ON the conversation row the Watch can never show an unseen mark at
/// all. One string on a record already in flight buys that.
///
/// WHY IT IS VERSIONED AND WHY IT IS VALIDATED AGAINST `lastActivityAt`. A bare
/// `lastMessageRole` column would go stale INVISIBLY in a mixed-version fleet: a
/// build that appends a reply, bumps `lastActivityAt` and never touches the role
/// leaves a perfectly well-formed value describing the wrong tail, and a newer
/// device would then withhold the mark for a genuinely unread reply. So the
/// envelope carries its own version, the tail's identity, the millisecond it was
/// written at and its role, and is VALID ONLY ON A FULL MATCH — recognised
/// version, parseable UUID, known role, parseable millisecond count, AND a
/// millisecond count equal to the conversation's own `lastActivityAt` quantised
/// the same way. Any mismatch in either direction is stale. That clause is what
/// makes a missed write detectable at all: nothing else in the string can
/// reveal that a message landed after it.
///
/// GRAMMAR — FROZEN ONCE `Conversations 10` DEPLOYS TO PRODUCTION CLOUDKIT:
///
///     tailProjection := version SEP messageID SEP milliseconds SEP role
///     version        := "1"                     (this build's `currentVersion`)
///     messageID      := `UUID.uuidString`       (uppercase hex + "-")
///     milliseconds   := `String(Int64)`         (SIGNED whole milliseconds since
///                                                the Unix epoch, decimal, no
///                                                padding — `milliseconds(from:)`)
///     role           := "user" | "agent"        (a `MessageRole` raw value)
///     SEP            := "|"
///
/// Exactly four fields — a rule about VERSION 1, not about the string. `read`
/// judges the version tag first, so a future version is free to carry a
/// different count and this build reports it unreadable rather than measuring it
/// against a grammar it does not belong to. The separator is chosen so it
/// cannot occur INSIDE a field: a UUID string is hex digits and hyphens, a role
/// is lowercase ASCII letters, the version is digits, and the millisecond count
/// is digits with at most a leading "-" — none of them can produce a `|`, so a
/// field can never swallow a separator and a split can never mis-align. SIGNED
/// rather than unsigned because a pre-1970 instant is representable in every
/// other layer of this app (an imported thread, a device whose clock was wrong,
/// `Date.distantPast`), and an encoding that cannot carry one would either
/// refuse the row or wrap it into the far future. Frozen means frozen: the
/// column is on the additive-only production schema and is read by builds that
/// will never learn a new shape, so a future change takes a NEW version tag and
/// leaves version 1 parsing exactly as it does here.
///
/// THE STAMP IS A CANONICAL INTEGER MILLISECOND COUNT, AND THAT IS THE WHOLE
/// DESIGN. The two sides of the validity clause do not cross CloudKit in the
/// same encoding: the envelope's stamp rides inside this String, which the
/// mirror carries byte for byte, while `lastActivityAt` rides as a CKRecord DATE
/// field, which Apple documents as milliseconds since the Unix epoch and does
/// NOT document as rounding or truncating. So this app does the quantising
/// FIRST, and never leaves a value where the two answers could differ: every
/// tail-producing write converts its proposed instant to one `Int64` millisecond
/// value, rebuilds a `Date` from that value, and stores THAT `Date` in both
/// `Message.createdAt` and `Conversation.lastActivityAt` while the integer goes
/// in the envelope (`canonical(_:)`). A value already sitting exactly on a
/// millisecond boundary is the one class of value rounding and truncation agree
/// about, so the mirror has nothing left to decide and the round trip is
/// lossless either way.
///
/// READ TIME COMPARES INTEGERS, NEVER DATES. `read` re-quantises whatever
/// `lastActivityAt` it was handed and compares that integer to the one the
/// string carried. Bit-exact `Date` equality would keep the clause hostage to
/// IEEE-754 and to Foundation's own 1970↔2001 epoch shift even after
/// quantisation — two additions and a division, each free to land a few hundred
/// nanoseconds off. Re-quantising absorbs all of it: the noise is under a
/// microsecond and a canonical stamp sits half a millisecond from the nearest
/// boundary, so the integer is recovered with a margin of roughly a thousand to
/// one.
///
/// AND THERE IS NO TOLERANCE WINDOW, DELIBERATELY. A window wide enough to hide
/// a quantisation disagreement is also wide enough to accept an envelope
/// describing the turn one step away in the clone loop's deliberate
/// one-millisecond-per-copied-turn spacing, so it trades a detectable staleness
/// for an undetectable one. Worse, a window PLUS a canonical form is two
/// mechanisms for one job, and the looser one silently defines the behaviour:
/// exactness at the shared precision would stop being tested the day it stopped
/// being what the code depends on.
///
/// WHAT QUANTISATION COSTS, stated rather than discovered later. Two writes into
/// one conversation inside the same millisecond would carry the SAME stamp
/// instead of differing by microseconds, and `Message.createdAt` is the only
/// order a thread has. `ConversationStore.appendStamp` is what stops that
/// happening — it settles each append at least one millisecond past the
/// conversation's own last activity — and it earns its keep beyond this file,
/// because `Message.createdAt` crosses the mirror at millisecond granularity
/// too, so sub-millisecond spacing was never visible to another device anyway.
/// Ties therefore survive only on rows written before that rule, or across two
/// devices settling one millisecond independently — and every site that picks a
/// message out of a conversation breaks them the SAME way: LARGER `Message.id`
/// wins, matching `FailedTurnProjection.isNewer`, which is the order the
/// unresolved-turn aggregate already published. `fetchConversationTail` and
/// `repairTailProjection` sort `createdAt` descending and `id` DESCENDING;
/// `fetchMessages` sorts both ascending, so its `last` element is that same row.
/// One order rather than two is what lets a surface acknowledge the failure the
/// list is painting: the tail an acknowledgement reads off `messages.last` and
/// the failure the aggregate selected must be the same message, or the stored
/// `failureSeenAttemptID` names an attempt no resolver will ever match and the
/// row stays red with nothing the user can do about it.
///
/// CROSS-TARGET: declared here beside the store (pure Foundation + `MessageRole`,
/// both Watch members) so the wrist can validate the same envelope the phone
/// writes.
nonisolated struct TailProjection: Sendable, Hashable {
    /// `Message.id` of the conversation's newest message.
    let messageID: UUID
    /// That message's `Message.createdAt`, rebuilt from the integer the envelope
    /// carried — so it is the canonical `Date` for that millisecond, which is
    /// bit-identical to the one the writing device stored in the row.
    let createdAt: Date
    /// That message's role — the half of the unseen test this column exists for.
    let role: MessageRole

    /// The only version this build writes. A higher one is another build's, and
    /// is reported `.unreadableVersion` rather than `.stale` so nothing here
    /// overwrites it (see `TailProjectionReading`).
    static let currentVersion = 1

    /// See the grammar in the type header. A `Character`, so `split` yields
    /// whole fields.
    static let separator: Character = "|"

    /// THE quantisation — the only place an instant becomes the envelope's
    /// integer, and the only definition of "the same instant" this file has.
    ///
    /// Rounds to nearest rather than truncating, so an instant already on a
    /// millisecond boundary is recovered exactly whichever direction the float
    /// noise of a transport or an epoch conversion nudged it. Truncation would
    /// spend the whole half-millisecond margin on one side and turn a stamp that
    /// came back a nanosecond light into a stamp one millisecond early.
    ///
    /// TOTAL, because it has to be. A partially-synced row can hand this a date
    /// built from a value no `Int64` can hold, and a trapping conversion would
    /// crash a list reload where reading one row as stale is the correct answer.
    static func milliseconds(from date: Date) -> Int64 {
        let scaled = (date.timeIntervalSince1970 * 1000).rounded()
        if let exact = Int64(exactly: scaled) { return exact }
        // NaN takes this branch too and lands on `.max`, which is a value no
        // real `lastActivityAt` can match — stale, which is what an unusable
        // stamp deserves.
        return scaled < 0 ? .min : .max
    }

    /// The canonical `Date` naming a millisecond value — the inverse of
    /// `milliseconds(from:)` across every value that method can produce.
    static func date(fromMilliseconds milliseconds: Int64) -> Date {
        Date(timeIntervalSince1970: Double(milliseconds) / 1000)
    }

    /// Snap an instant onto its millisecond. THE call every tail-producing write
    /// makes exactly once, before it stamps anything: the one returned value
    /// goes into `Message.createdAt` AND `Conversation.lastActivityAt`, so the
    /// two are bit-identical on this device and quantise to one integer on every
    /// other. Deriving them from two separate `Date()` reads, or quantising one
    /// half and not the other, is the exact skew the envelope's validity clause
    /// would then report as staleness.
    static func canonical(_ instant: Date) -> Date {
        date(fromMilliseconds: milliseconds(from: instant))
    }

    /// Encode the envelope for storage, or nil when the role is not one this
    /// build recognises.
    ///
    /// NIL RATHER THAN AN ENVELOPE CARRYING THE RAW ROLE STRING. An unknown role
    /// can never satisfy `read`, so storing one would produce a well-formed
    /// string that is stale by construction — a row permanently in the repair
    /// path, exporting a CKRecord for a value no reader can ever use. Nil is the
    /// honest answer: "no projection", which is exactly what a reader does with
    /// it. Unreachable from the write paths in practice (every role this store
    /// writes is a `MessageRole` raw value); it exists so a partially-synced row
    /// with a foreign role degrades instead of lying.
    static func encoded(messageID: UUID, createdAt: Date, role: String?) -> String? {
        guard let role = MessageRole(stored: role) else { return nil }
        return encoded(messageID: messageID, createdAt: createdAt, role: role)
    }

    /// Encode the envelope from an already-known role.
    ///
    /// Quantises `createdAt` rather than trusting it, so the envelope carries a
    /// millisecond value even if a caller ever hands this a stamp it did not
    /// take from `canonical(_:)`. For every caller in this store that is a no-op
    /// — the row was written from the same canonical `Date` — which is the point:
    /// the encoder cannot be the place the invariant is lost.
    static func encoded(messageID: UUID, createdAt: Date, role: MessageRole) -> String {
        [
            String(currentVersion),
            messageID.uuidString,
            String(milliseconds(from: createdAt)),
            role.rawValue
        ].joined(separator: String(separator))
    }

    /// Read a stored envelope against the conversation it belongs to.
    ///
    /// UNTRUSTED INPUT BY POSTURE, not just by caution: this string arrives from
    /// CloudKit, written by a build this one knows nothing about. Every field is
    /// parsed and the whole thing is cross-checked against `lastActivityAt`;
    /// there is no partial acceptance and no field is believed on its own.
    static func read(_ stored: String?, lastActivityAt: Date) -> TailProjectionReading {
        guard let stored, !stored.isEmpty else { return .stale }
        // `omittingEmptySubsequences: false` so an empty field is a field: a
        // string with a missing value must fail the count check or the role
        // parse, never silently re-align onto the neighbouring field.
        let fields = stored.split(separator: separator, omittingEmptySubsequences: false)
        // THE VERSION IS JUDGED BEFORE THE FIELD COUNT, and that order is the
        // whole reason the tag is first in the grammar. A newer build may change
        // the SHAPE of the envelope as well as the meaning of its fields — one
        // more field is the obvious next change — so measuring the count first
        // would report a version-2 envelope `.stale`, which is REPAIRABLE, and
        // this build would overwrite it with four version-1 fields while the
        // newer device restamped its own: the downgrade fight
        // `.unreadableVersion` exists to prevent, entered by accident, with the
        // newer field's information destroyed on every round trip. `split`
        // always yields at least one field for a non-empty string, so index 0 is
        // safe before any count check.
        guard let version = Int(fields[0]) else { return .stale }
        guard version == currentVersion else {
            // A FUTURE version is a different fact, not a wrong one, and it is
            // NOT repairable: rewriting it would start a downgrade fight — this
            // build stamps version 1, the newer device restamps its own, and the
            // two export a CKRecord at each other for as long as both exist.
            // Below-current cannot happen (1 is the first) and is malformed.
            return version > currentVersion ? .unreadableVersion : .stale
        }
        guard fields.count == 4 else { return .stale }
        guard let messageID = UUID(uuidString: String(fields[1])),
              let storedMilliseconds = Int64(fields[2]),
              let role = MessageRole(stored: String(fields[3])) else { return .stale }
        // THE CLAUSE THE WHOLE ENVELOPE EXISTS FOR. A build that appended a
        // message without writing this string left a valid-looking envelope
        // describing the previous tail; only the stamp can expose that. INTEGERS
        // on both sides: the string already carries one, and `lastActivityAt` is
        // re-quantised here rather than compared as a `Date`, so whatever the
        // mirror and the epoch conversion did to the double in transit is
        // absorbed instead of decided (see the type header).
        guard storedMilliseconds == milliseconds(from: lastActivityAt) else { return .stale }
        return .valid(
            TailProjection(
                messageID: messageID,
                createdAt: date(fromMilliseconds: storedMilliseconds),
                role: role
            )
        )
    }
}

/// What a stored tail envelope turned out to be. Three cases, because "cannot be
/// used" and "must not be rewritten" are different questions and only one of them
/// is answered by whether the string parsed.
nonisolated enum TailProjectionReading: Sendable, Hashable {
    /// A full match. `role` is authoritative for the unseen test.
    case valid(TailProjection)
    /// Absent, malformed, or describing a tail that is no longer the tail. The
    /// surfaces that can afford a per-row tail fetch (iOS, macOS) fall back to
    /// one and schedule `repairTailProjection`; the wrist, which cannot, shows
    /// no mark rather than guessing at one.
    case stale
    /// Written by a build newer than this one. Unusable here for the same reason
    /// `.stale` is — but it must NOT be repaired, because rewriting it downgrades
    /// a value the newer device will immediately restamp. Left alone, it simply
    /// waits for this device to be updated.
    case unreadableVersion

    /// The role a valid envelope proved, or nil in both unusable cases. The
    /// shape every consumer of `ConversationActivityInputs.tailRole` wants — nil
    /// there means NOT PROJECTED and suppresses the unseen branch, which is
    /// exactly the right answer for both.
    var role: MessageRole? {
        if case .valid(let projection) = self { return projection.role }
        return nil
    }

    /// Whether `repairTailProjection` may rewrite this. False for `.valid`
    /// (nothing to fix) and for `.unreadableVersion` (see above).
    var isRepairable: Bool {
        if case .stale = self { return true }
        return false
    }
}

/// A to-be-persisted attachment carrying the FULL bytes for the write. Built
/// by the VM (from `ImageProcessor` / `TextFileExtractor`) and handed to
/// `appendMessage`. Distinct from `AttachmentRecord` (the read snapshot, which
/// NEVER carries full image bytes). Sendable so it crosses the
/// `ConversationStore` actor boundary.
///
/// CROSS-TARGET: declared here (in `ConversationStore.swift`, already a Watch
/// membership exception) so the type is visible to the Watch target alongside
/// the store — even though the Watch never builds a draft (no image pipeline on
/// the wrist).
nonisolated struct AttachmentDraft: Sendable {
    /// `image/jpeg` for images; `text/*` / `application/json` for text files.
    let mimeType: String
    /// Original filename (text files — drives the bubble chip label). Nil for
    /// images (no meaningful name; the bubble shows a thumbnail).
    let filename: String?
    /// Full bytes: the JPEG for images, the extracted UTF-8 text bytes for
    /// text files. Stored in `Attachment.data` (external storage allowed).
    let data: Data
    /// Small preview JPEG (images only); nil for text files.
    let thumbnailData: Data?
    let width: Int
    let height: Int
    let byteSize: Int
    /// Render / wire order within the parent message (0-based).
    let sequence: Int
    /// True when this draft is a *server reference* (file transfer): the real
    /// bytes live on the user's own gateway file-server, so `data` is empty and
    /// `storedKey` addresses the uploaded blob. Defaulted so the existing image
    /// / text-file callers (which never set it) keep compiling unchanged.
    var isServerReference: Bool = false
    /// Opaque server-issued handle for the uploaded blob (`<shortid>__<name>`).
    /// PRIVACY: never log / display this raw — it is an opaque path token.
    var storedKey: String? = nil
    /// Bounded UTF-8 text preview bytes for a server-reference file (≤128 KiB),
    /// persisted into `Attachment.previewData`. Nil for images / non-previewable
    /// files. Defaulted so existing callers (which never set it) keep compiling.
    var previewData: Data? = nil
    /// Preview discriminator: `"text"` when `previewData` holds a text snapshot;
    /// nil otherwise. Persisted into `Attachment.previewKind`. Defaulted.
    var previewKind: String? = nil

    init(
        mimeType: String,
        filename: String? = nil,
        data: Data,
        thumbnailData: Data?,
        width: Int,
        height: Int,
        byteSize: Int,
        sequence: Int
    ) {
        self.mimeType = mimeType
        self.filename = filename
        self.data = data
        self.thumbnailData = thumbnailData
        self.width = width
        self.height = height
        self.byteSize = byteSize
        self.sequence = sequence
    }
}

// MARK: - Agent-file courier (phone → wrist fast lane)
//
// WHY THIS EXISTS. A turn dictated on the Watch is dispatched BY the Watch, so
// the reply TEXT is in the wrist's store within a second. The FILE the agent
// produced is not: the wrist deliberately never holds the file-server
// credential (it is written non-synchronizable, and the phone→watch relay
// carries no file-server secret), so the wrist can neither list the reply's
// output folder nor discover the file. Discovery is a credential-holding
// device's job — the phone opens the thread, runs the retroactive output scan,
// and patches an `Attachment` row on. That patch reaches the wrist only through
// CloudKit mirroring, measured at roughly seven minutes on watchOS.
//
// The courier closes that gap by shipping the row's METADATA — tens of bytes —
// over the WatchConnectivity link the two devices already share. It carries no
// credential, no URL, no file bytes and no preview bytes: the phone stays the
// only device that ever touches the file server, and the wrist gains a row it
// can DISPLAY, never one it can download.
//
// CROSS-TARGET, single-sourced: these types live in `ConversationStore.swift`
// because this file already carries BOTH iOS and watchOS target membership (the
// same reason `AttachmentDraft` is declared here). The relay's own wire enum is
// a literal duplicate across two single-target files and needs a source-reading
// drift guard to stay honest; this contract needs neither, because both sides
// compile the SAME declaration and a rename is a compile error rather than a
// silent runtime break.

/// One agent-produced file the PHONE discovered and attached, reduced to what a
/// wrist needs to draw a row. Deliberately a metadata-only projection of an
/// `Attachment`: it carries NO `data`, NO `thumbnailData` and NO `previewData`.
///
/// `attachmentID` is the identifier the phone minted for its own Core Data row.
/// Carrying it — rather than letting the wrist mint one — is what lets the
/// overlay recognize the authoritative row when CloudKit finally delivers it,
/// and keeps SwiftUI's `ForEach` identity continuous across the handover so the
/// row does not visibly pop.
///
/// PRIVACY: `storedKey` is an opaque server path token — never log it, never
/// render it raw.
nonisolated struct AttachedFileDescriptor: Sendable, Equatable, Codable, Identifiable {
    let conversationID: UUID
    let messageID: UUID
    /// The `Attachment.id` the phone minted. Doubles as this descriptor's identity.
    let attachmentID: UUID
    /// Non-empty by construction — a descriptor with no stored key cannot be
    /// matched against the CloudKit row that will supersede it, and
    /// `MessageRowFormatters.dedupedServerFiles` deliberately never collapses
    /// nil-key rows, so an unkeyed overlay row could not be retired at all.
    let storedKey: String
    let filename: String?
    let mimeType: String
    let byteSize: Int
    /// The sequence the phone ACTUALLY persisted (already clamped to the store's
    /// Integer 16 width), so the overlay row sorts exactly where the mirrored row
    /// will land and the handover reorders nothing.
    let sequence: Int
    /// The persisted preview discriminator, carried for completeness and forward
    /// compatibility. It is deliberately NOT applied to the rendered overlay row
    /// — see `AgentFileOverlay.synthesizedRecord(from:)`.
    let previewKind: String?
    /// The row's persisted `createdAt`. Carried, never re-synthesized at render
    /// time: `AttachmentRecord` equality includes it, and a fresh `Date()` per
    /// merge would make every refresh pass unequal and repaint the whole thread
    /// forever.
    let createdAt: Date

    var id: UUID { attachmentID }

    init(
        conversationID: UUID,
        messageID: UUID,
        attachmentID: UUID,
        storedKey: String,
        filename: String?,
        mimeType: String,
        byteSize: Int,
        sequence: Int,
        previewKind: String?,
        createdAt: Date
    ) {
        self.conversationID = conversationID
        self.messageID = messageID
        self.attachmentID = attachmentID
        self.storedKey = storedKey
        self.filename = filename
        self.mimeType = mimeType
        self.byteSize = byteSize
        self.sequence = sequence
        self.previewKind = previewKind
        self.createdAt = createdAt
    }
}

/// The WatchConnectivity payload shape for the courier. Plist-clean scalars
/// only (`String` / `Int` / `Double` / arrays / dictionaries) because both
/// `transferUserInfo` and `sendMessage` validate their payload against the
/// property-list types at send time.
///
/// DECODE POSTURE — tolerant, per-item. A payload from a NEWER phone may carry
/// keys this build has never heard of; those are ignored. An item missing an
/// optional display field decodes with a safe default. An item missing an
/// IDENTITY field (either UUID, or a non-empty stored key) is dropped on its
/// own — a single malformed item never rejects the batch, because the other
/// items in it are the files the user is waiting to see. A payload whose kind
/// does not match decodes to nothing, which is exactly how an OLDER wrist build
/// already behaves: it falls through to the settings-envelope decoder, finds
/// none of its keys, and no-ops.
nonisolated enum AttachedFileCourierWire {
    static let kindKey = "kind"
    static let kindValue = "conduck.agentFiles"
    /// Contract revision. Present so a future operation (a tombstone for an
    /// attachment deleted on the phone) can be added without ambiguity about
    /// what an older reader was allowed to assume.
    static let versionKey = "v"
    static let version = 1
    /// Operation discriminator. V1 emits only `upsert`; a reader that does not
    /// recognize the operation drops the batch rather than guessing.
    static let operationKey = "op"
    static let operationUpsert = "upsert"
    static let itemsKey = "items"

    static let conversationIDKey = "convo"
    static let messageIDKey = "msg"
    static let attachmentIDKey = "att"
    static let storedKeyKey = "key"
    static let filenameKey = "name"
    static let mimeTypeKey = "mime"
    static let byteSizeKey = "size"
    static let sequenceKey = "seq"
    static let previewKindKey = "preview"
    static let createdAtKey = "created"

    /// Fallback MIME for an item that arrived without one. Matches
    /// `AttachmentRecord.init(managedObject:)`'s own fallback so an overlay row
    /// and the mirrored row it will be replaced by classify identically.
    static let defaultMIMEType = "application/octet-stream"

    /// Ceiling on items per envelope. WatchConnectivity caps a payload at a few
    /// hundred KB; a descriptor is ~200 bytes, so this is nowhere near the wire
    /// limit — it exists so one pathological scan (an agent that wrote hundreds
    /// of files) sends several small envelopes instead of one the OS rejects
    /// wholesale, which would lose every row rather than delay some.
    static let maxItemsPerEnvelope = 32

    /// Split descriptors into ready-to-send envelopes, at most
    /// `maxItemsPerEnvelope` items each. Empty input yields no envelopes.
    static func envelopes(for descriptors: [AttachedFileDescriptor]) -> [[String: Any]] {
        stride(from: 0, to: descriptors.count, by: maxItemsPerEnvelope).map { start in
            let chunk = Array(descriptors[start..<min(start + maxItemsPerEnvelope, descriptors.count)])
            return [
                kindKey: kindValue,
                versionKey: version,
                operationKey: operationUpsert,
                itemsKey: chunk.map(item(for:))
            ]
        }
    }

    /// The per-item dictionary. This is the ONLY place a descriptor becomes wire
    /// bytes, so the allowlist of what may leave the phone is auditable in one
    /// screen — and `WatchAttachmentPushWireTests`
    /// (`testEnvelopeCarriesOnlyTheAllowlistedKeys`) pins it with SET EQUALITY,
    /// against both the all-optionals-present and the all-optionals-absent
    /// shape, so a future field cannot ride along unnoticed on either branch of
    /// the conditional puts below. The test name is load-bearing: a maintainer
    /// adding a field greps it, and a citation that resolves to nothing reads as
    /// "the pin was never written" — which is exactly the licence this function
    /// must never grant.
    static func item(for descriptor: AttachedFileDescriptor) -> [String: Any] {
        var item: [String: Any] = [
            conversationIDKey: descriptor.conversationID.uuidString,
            messageIDKey: descriptor.messageID.uuidString,
            attachmentIDKey: descriptor.attachmentID.uuidString,
            storedKeyKey: descriptor.storedKey,
            mimeTypeKey: descriptor.mimeType,
            byteSizeKey: descriptor.byteSize,
            sequenceKey: descriptor.sequence,
            createdAtKey: descriptor.createdAt.timeIntervalSinceReferenceDate
        ]
        if let filename = descriptor.filename { item[filenameKey] = filename }
        if let previewKind = descriptor.previewKind { item[previewKindKey] = previewKind }
        return item
    }

    /// Decode one received payload. Returns an empty array for anything that is
    /// not a recognized courier batch — the caller treats that as "not for me"
    /// and falls through to its other handlers.
    static func decode(_ payload: [String: Any]) -> [AttachedFileDescriptor] {
        guard payload[kindKey] as? String == kindValue else { return [] }
        // An unknown operation is NOT an upsert. Dropping is the safe direction:
        // a tombstone misread as an upsert would resurrect a deleted row.
        guard (payload[operationKey] as? String ?? operationUpsert) == operationUpsert else { return [] }
        guard let items = payload[itemsKey] as? [[String: Any]] else { return [] }
        return items.compactMap(descriptor(fromItem:))
    }

    /// One item → one descriptor, or nil when an identity field is missing or
    /// malformed. Display fields fall back rather than failing the item.
    static func descriptor(fromItem item: [String: Any]) -> AttachedFileDescriptor? {
        guard let conversationID = (item[conversationIDKey] as? String).flatMap(UUID.init(uuidString:)),
              let messageID = (item[messageIDKey] as? String).flatMap(UUID.init(uuidString:)),
              let attachmentID = (item[attachmentIDKey] as? String).flatMap(UUID.init(uuidString:)),
              let storedKey = item[storedKeyKey] as? String,
              !storedKey.isEmpty else {
            return nil
        }
        // `NSNumber` bridging: WatchConnectivity round-trips integers through
        // property-list numbers, so read them as `NSNumber` rather than `Int`.
        let byteSize = (item[byteSizeKey] as? NSNumber)?.intValue ?? 0
        let sequence = (item[sequenceKey] as? NSNumber)?.intValue ?? 0
        let created = (item[createdAtKey] as? NSNumber)?.doubleValue
        return AttachedFileDescriptor(
            conversationID: conversationID,
            messageID: messageID,
            attachmentID: attachmentID,
            storedKey: storedKey,
            filename: item[filenameKey] as? String,
            mimeType: item[mimeTypeKey] as? String ?? defaultMIMEType,
            byteSize: byteSize,
            sequence: sequence,
            previewKind: item[previewKindKey] as? String,
            // A missing timestamp still has to be STABLE across merges (see
            // `createdAt`'s note), so it pins to the reference date rather than
            // to "now".
            createdAt: Date(timeIntervalSinceReferenceDate: created ?? 0)
        )
    }
}

/// One inbox entry: a descriptor plus the moment this device received it.
/// `receivedAt` drives the age bound only — it is never rendered, and it is
/// deliberately NOT the row's `createdAt` (which is the phone's persisted value
/// and must survive re-receipt unchanged).
nonisolated struct AttachedFileInboxEntry: Sendable, Equatable, Codable {
    let descriptor: AttachedFileDescriptor
    let receivedAt: Date
}

/// The wrist's pending-file inbox, as a PURE value.
///
/// This is a fast cache, NOT a second persistence system, and the distinction
/// is the whole design. Nothing here is ever written into the Core Data store:
/// that store is CloudKit-mirrored on the wrist too, so a wrist-inserted
/// `Attachment` row would export as its OWN CKRecord — Core Data + CloudKit
/// mirroring does not unique on an `id` attribute — and the phone's row and the
/// wrist's row would then coexist permanently on every device the user owns.
/// The overlay instead lives beside the store and is merged in at READ time, so
/// the couriered row and the mirrored row can never both exist: the merge
/// retires the entry in the same pass that first sees the real row.
///
/// Bounded two ways, because an entry whose message never arrives (deleted on
/// another device, or a courier that outran a CloudKit import that then never
/// came) has nothing to retire it: oldest-first eviction past `maxEntries`, and
/// an absolute age cap at `maxEntryAge`. The trade-off is explicit — if the
/// authoritative row never syncs, the overlay row eventually disappears rather
/// than becoming a permanent phantom.
nonisolated struct AttachedFileInboxState: Sendable, Equatable, Codable {
    /// Entry ceiling. A handful of pending rows is the realistic steady state;
    /// this is headroom, not a working size.
    static let maxEntries = 64
    /// Age ceiling. Generous enough that a wrist left off the charger over a
    /// long weekend still shows what it was couriered, short enough that a row
    /// whose authoritative copy never syncs does not linger indefinitely.
    static let maxEntryAge: TimeInterval = 7 * 24 * 60 * 60

    private(set) var entries: [AttachedFileInboxEntry] = []

    init(entries: [AttachedFileInboxEntry] = []) {
        self.entries = entries
    }

    /// Identity of an entry for dedupe purposes: the message it belongs to plus
    /// the stored key. Deliberately NOT the attachment UUID alone — two devices
    /// running the retro scan concurrently can mint different UUIDs for the same
    /// file, and the user must see one row either way.
    private static func slot(_ descriptor: AttachedFileDescriptor) -> String {
        "\(descriptor.messageID.uuidString)|\(descriptor.storedKey)"
    }

    /// Absorb a courier batch. Returns whether the inbox actually changed —
    /// load-bearing, because the caller posts `.conversationsDidChange` on the
    /// strength of it, and the courier deliberately sends the SAME batch twice
    /// (queued + interactive). A re-delivery must cost nothing: no post, no
    /// refresh pass, no repaint.
    @discardableResult
    mutating func ingest(_ descriptors: [AttachedFileDescriptor], now: Date = Date()) -> Bool {
        var changed = false
        for descriptor in descriptors {
            let key = Self.slot(descriptor)
            if let index = entries.firstIndex(where: { Self.slot($0.descriptor) == key }) {
                // Same file, new metadata (e.g. a preview kind landed): take the
                // newer descriptor but keep the ORIGINAL receipt time, so a
                // re-push cannot indefinitely extend an entry's age bound.
                guard entries[index].descriptor != descriptor else { continue }
                entries[index] = AttachedFileInboxEntry(
                    descriptor: descriptor,
                    receivedAt: entries[index].receivedAt
                )
                changed = true
            } else {
                entries.append(AttachedFileInboxEntry(descriptor: descriptor, receivedAt: now))
                changed = true
            }
        }
        if purgeExpired(now: now) { changed = true }
        if entries.count > Self.maxEntries {
            // Oldest first — the newest couriered file is the one the user is
            // most likely still looking at.
            entries.sort { $0.receivedAt < $1.receivedAt }
            entries.removeFirst(entries.count - Self.maxEntries)
            changed = true
        }
        return changed
    }

    @discardableResult
    mutating func purgeExpired(now: Date = Date()) -> Bool {
        let before = entries.count
        entries.removeAll { now.timeIntervalSince($0.receivedAt) > Self.maxEntryAge }
        return entries.count != before
    }

    /// Drop entries whose authoritative row has landed. The merge decides which
    /// those are; this only applies the verdict.
    @discardableResult
    mutating func remove(attachmentIDs: Set<UUID>) -> Bool {
        guard !attachmentIDs.isEmpty else { return false }
        let before = entries.count
        entries.removeAll { attachmentIDs.contains($0.descriptor.attachmentID) }
        return entries.count != before
    }

    /// Drop every entry for a conversation this device just deleted. Without
    /// this the entries would survive, invisible (their messages are gone), until
    /// the age bound expired them.
    @discardableResult
    mutating func purgeConversation(_ conversationID: UUID) -> Bool {
        let before = entries.count
        entries.removeAll { $0.descriptor.conversationID == conversationID }
        return entries.count != before
    }

    func descriptors(forMessage messageID: UUID) -> [AttachedFileDescriptor] {
        entries.filter { $0.descriptor.messageID == messageID }.map(\.descriptor)
    }
}

/// Pure merge of couriered descriptors onto fetched message snapshots. No I/O,
/// no persistence, no isolation — so the entire convergence story is unit
/// testable without a store, a WCSession, or a view.
nonisolated enum AgentFileOverlay {

    /// Build the DISPLAY-ONLY row for a couriered descriptor.
    ///
    /// Every byte-bearing field is forced nil, and that is a correctness
    /// requirement rather than a shortcut:
    /// * `previewKind` — a `"text"` row classifies as `.viewableText`, which
    ///   makes it tappable into `WatchAttachmentTextView`; that viewer resolves
    ///   its content by fetching the attachment out of Core Data, where an
    ///   overlay row does not exist, so the tap would land on "no longer
    ///   available". Nil keeps it the passive `.serverPlaceholder` row until the
    ///   real row arrives with real bytes behind it.
    /// * `thumbnailData` — same reasoning, and the courier carries no bytes to
    ///   put there anyway.
    /// * `extractedText` — a server reference never has local bytes.
    ///
    /// The result is a pure function of the descriptor: merging twice produces
    /// equal records, which is what lets the view model's equality skip treat a
    /// no-op refresh as a no-op.
    static func synthesizedRecord(from descriptor: AttachedFileDescriptor) -> AttachmentRecord {
        AttachmentRecord(
            id: descriptor.attachmentID,
            mimeType: descriptor.mimeType,
            filename: descriptor.filename,
            thumbnailData: nil,
            extractedText: nil,
            width: 0,
            height: 0,
            byteSize: descriptor.byteSize,
            sequence: descriptor.sequence,
            createdAt: descriptor.createdAt,
            isServerReference: true,
            storedKey: descriptor.storedKey,
            previewKind: nil
        )
    }

    /// Merge `entries` into `messages`.
    ///
    /// For each message, an entry is RESOLVED when the fetched attachments
    /// already carry its stored key OR its attachment id — either proves the
    /// authoritative row has arrived, and the id check additionally catches a
    /// partially-mirrored row whose `storedKey` attribute has not landed yet
    /// (which the key check alone would miss, leaving a duplicate on screen).
    /// A resolved entry contributes no overlay row and is reported for pruning.
    /// Everything else is appended as a synthesized row.
    ///
    /// An entry whose message is not in `messages` is NEITHER rendered NOR
    /// resolved: the courier can legitimately outrun the message's own CloudKit
    /// import, so "message not here yet" must not be read as "row already
    /// landed". The age bound is what eventually retires those.
    static func merge(
        _ entries: [AttachedFileInboxEntry],
        into messages: [MessageRecord]
    ) -> (messages: [MessageRecord], resolved: Set<UUID>) {
        guard !entries.isEmpty else { return (messages, []) }

        var byMessage: [UUID: [AttachedFileDescriptor]] = [:]
        for entry in entries {
            byMessage[entry.descriptor.messageID, default: []].append(entry.descriptor)
        }

        var resolved: Set<UUID> = []
        let merged = messages.map { message -> MessageRecord in
            guard let descriptors = byMessage[message.id] else { return message }

            let presentKeys = Set(message.attachments.compactMap(\.storedKey))
            let presentIDs = Set(message.attachments.map(\.id))

            var additions: [AttachmentRecord] = []
            for descriptor in descriptors {
                if presentKeys.contains(descriptor.storedKey) || presentIDs.contains(descriptor.attachmentID) {
                    resolved.insert(descriptor.attachmentID)
                    continue
                }
                additions.append(synthesizedRecord(from: descriptor))
            }
            guard !additions.isEmpty else { return message }

            return MessageRecord(
                id: message.id,
                role: message.role,
                text: message.text,
                createdAt: message.createdAt,
                sourceDevice: message.sourceDevice,
                status: message.status,
                deliveryAttemptID: message.deliveryAttemptID,
                failureCode: message.failureCode,
                failureWireCode: message.failureWireCode,
                failureHadHistoryImages: message.failureHadHistoryImages,
                fileTransferLaneID: message.fileTransferLaneID,
                outputScanDone: message.outputScanDone,
                outputScanLaneID: message.outputScanLaneID,
                outputBoxKey: message.outputBoxKey,
                // Carried explicitly, like `deliveryAttemptID` above. This
                // rebuild is field-by-field against a memberwise init whose
                // later parameters all default, so an omission here COMPILES and
                // silently blanks the field on every row a couriered descriptor
                // touches — the census refusal the user was told about would
                // vanish the moment the wrist delivered a file, and a blanked
                // attempt identity would leave that turn's red mark unretirable
                // from the thread on every device.
                outputDeliveryOutcome: message.outputDeliveryOutcome,
                attachments: (message.attachments + additions).sorted { $0.sequence < $1.sequence }
            )
        }
        return (merged, resolved)
    }
}

extension Notification.Name {
    /// Posted by `ConversationStore` when THIS device's own write attached one
    /// or more agent-output files to an existing turn — never on a CloudKit
    /// import, which by definition already reached every device.
    ///
    /// The `userInfo` carries `[AttachedFileDescriptor]` under
    /// `ConversationStore.attachedFilesUserInfoKey`. A NotificationCenter seam
    /// rather than a direct call keeps this cross-target store ignorant of the
    /// iOS-only WatchConnectivity broadcaster that listens for it.
    static let agentFilesDidAttachLocally = Notification.Name("agentFilesDidAttachLocally")
}

/// Trailing-edge debouncer for the CloudKit remote-change fan-out. A mirroring
/// import batch delivers `.NSPersistentStoreRemoteChange` in dense bursts
/// (dozens per session in a field log); posting `.conversationsDidChange` 1:1
/// makes every list/thread observer refetch per notification. This coalesces a
/// burst to ONE trailing post, with a max-latency cap so a CONTINUOUS storm
/// still surfaces at least once per `maxLatency` — the UI keeps updating while
/// an import runs. The cap is enforced SYNCHRONOUSLY at `schedule()` time: a
/// schedule arriving with the window already at `maxLatency` fires inline on
/// the caller's main-actor turn, so a main-queue delivery backlog — where a
/// pending fire task never wins executor time before the next `schedule()`
/// supersedes it — cannot starve the cap down to trailing-only behavior. The
/// trailing edge is never dropped: the last `schedule()` of a burst always
/// eventually fires exactly once.
///
/// `@MainActor` because the remote-change observer callbacks land on
/// `queue: .main` and the fire closure posts a NotificationCenter notification
/// the UI observes — main isolation makes schedule/fire ordering trivially
/// serial (no lock). Interval, cap, and fire closure are injectable for tests.
/// Lives in this file so the shared iOS+watch target membership stays one file.
@MainActor
final class RemoteChangeDebouncer {
    private let interval: Duration
    private let maxLatency: Duration
    private let fire: @MainActor () -> Void

    /// In-flight trailing timer. Superseded (cancelled + replaced) by every
    /// new `schedule()`, so at most one fire is ever pending.
    private var pending: Task<Void, Never>?
    /// Start of the current coalescing window — anchors the max-latency cap.
    /// Set by the first `schedule()` of a burst, cleared when a fire lands.
    private var windowStart: ContinuousClock.Instant?

    init(
        interval: Duration = .milliseconds(300),
        maxLatency: Duration = .milliseconds(1000),
        fire: @escaping @MainActor () -> Void
    ) {
        self.interval = interval
        self.maxLatency = maxLatency
        self.fire = fire
    }

    /// Register one change. Restarts the trailing timer, with the deadline
    /// clamped to `windowStart + maxLatency` so it can never drift forever no
    /// matter how fast re-schedules arrive. A schedule that finds the window
    /// already at/past `maxLatency` fires INLINE (see the cap note on the class
    /// doc) — delegating that fire to a task would let a backed-up main queue
    /// starve it: each new `schedule()` cancels the pending task before it ever
    /// wins executor time, and the cap silently degrades to trailing-only.
    func schedule() {
        let now = ContinuousClock.now
        let start = windowStart ?? now
        windowStart = start
        if start.duration(to: now) >= maxLatency {
            // Cap reached — fire synchronously on this main-actor turn. Reset
            // the window state FIRST so the fire closure observes the same
            // post-fire state a trailing task fire leaves behind.
            pending?.cancel()
            pending = nil
            windowStart = nil
            fire()
            return
        }
        let deadline = min(now.advanced(by: interval), start.advanced(by: maxLatency))
        pending?.cancel()
        pending = Task { [weak self] in
            // Cancellation means a newer `schedule()` owns the fire, so this
            // task steps aside.
            try? await Task.sleep(until: deadline, clock: .continuous)
            guard let self, !Task.isCancelled else { return }
            self.pending = nil
            self.windowStart = nil
            self.fire()
        }
    }
}

/// Actor wrapping `NSPersistentCloudKitContainer(name: "Conversations")`.
/// All access is awaited from outside. CRUD accepts / returns only `Sendable`
/// snapshot structs (`ConversationRecord` / `MessageRecord`) — an
/// `NSManagedObject` never crosses the actor boundary.
actor ConversationStore {
    // MARK: - Singleton

    /// Production singleton — store lives in the App Group container so the
    /// headless intent process and the foreground app share one sqlite.
    static let shared = ConversationStore()

    /// In-process retry claims close the actor-reentrancy window around
    /// `context.perform`. An actor method can accept another call while awaiting
    /// Core Data, so the persistent failed→sending predicate alone is not a
    /// same-process mutex. The store predicate remains the durable/cross-process
    /// gate; this set guarantees one local claimant reaches it at a time.
    private var retryClaims: Set<UUID> = []

    /// In-process terminal claims over `GatewayAttempt` rows — the same
    /// reentrancy guard as `retryClaims`, for the same reason, over the other
    /// one-shot transition this store owns. An attempt makes exactly ONE
    /// terminal transition out of `inFlight`, and the row's own `inFlight`
    /// predicate is the durable cross-process gate; this set is what keeps two
    /// local claimants — a landing delegate and a cancel path arriving in the
    /// same instant — from both reaching it across an `await`.
    ///
    /// Internal rather than private so the same actor's `+GatewayAttempts`
    /// extension, a sibling FILE that `private` does not reach, shares the one
    /// claim set with the combined landings in this file. A losing claimant
    /// never blocks a reply: it drops the MEASUREMENT and lands the turn.
    var terminalClaims: Set<UUID> = []

    #if DEBUG
    /// Whether attempt-bearing saves are currently rigged to fail. Set only
    /// through `debugSetAttemptBearingSaveFailure`, which carries the argument
    /// for the seam; compiled out of Release entirely.
    private var debugFailsAttemptBearingSaves = false

    /// What that seam throws. Deliberately NOT a `StoreError`: those are
    /// decisions this store made and are rethrown untouched, while a save
    /// failure is precisely what the fail-open retry is for — so the injected
    /// error has to travel the same path a real one does.
    struct DebugInjectedSaveFailure: Error {}
    #endif

    /// Conversations `repairTailProjection` has already been asked about in this
    /// process. THE LOOP GUARD, and it has to be here rather than in the caller:
    /// a repair is triggered by a surface noticing a stale envelope, and a
    /// conversation whose envelope CANNOT be made valid — no messages, a tail
    /// whose `createdAt` no longer matches `lastActivityAt`, a role this build
    /// does not know — would be noticed as stale by every reload for as long as
    /// the app runs. One attempt per conversation per launch bounds that to a
    /// single fetch, and a genuinely repairable row needs no second attempt
    /// because the first one fixed it.
    private var tailProjectionRepairsAttempted: Set<UUID> = []

    // MARK: - Errors

    /// Store-local errors. Kept here (not on `AppError`) so this store
    /// owns its own failure surface without touching the network taxonomy.
    enum StoreError: Error {
        /// `appendMessage` was handed a `conversationID` that does not exist
        /// in the store. Caller should mint a fresh conversation first.
        case conversationNotFound
        /// An attempt-correlated landing could not find the exact user turn it
        /// was sent to answer — deleted mid-flight, here or on another device.
        /// The reply is NOT inserted: a correlated landing knows precisely which
        /// turn it belongs to, and a reply with no question is worse than a
        /// missing one. The legacy no-attempt landing keeps its older tolerance
        /// and is never handed this.
        case userMessageNotFound
        /// A landing arrived for an attempt whose row is already terminal, and
        /// no reply carrying this dispatch's `agentMessageID` exists to return.
        /// The duplicate/late-callback rule: the turn was already concluded —
        /// cancelled before the callback, or closed by an earlier one — so
        /// nothing is written and nothing is recreated. Callers treat it as a
        /// benign no-op, NOT as a store failure to report or retry.
        case attemptAlreadyTerminal
    }

    /// One output-detector result to reconcile transactionally.
    /// `expectedLaneID` is a mandatory compare-and-set guard: attachments and
    /// the conclusive marker may be written only while the persisted reply
    /// still belongs to that exact dispatch-time file lane. Ownerless legacy
    /// rows cannot construct this value and therefore cannot enter mutation.
    struct OutputScanReconciliation: Sendable {
        let messageID: UUID
        let drafts: [AttachmentDraft]
        let markScanned: Bool
        let expectedLaneID: String
        /// What THIS pass observed about entries it did NOT hand over, or nil
        /// when it took no census at all — a listing that could not be read, a
        /// folder that is not there, and the root name search, which probes names
        /// one at a time and never sees a folder to refuse an entry from.
        ///
        /// REQUIRED rather than defaulted, and deliberately so: a caller that
        /// forgot this field would silently claim a clean folder it never
        /// listed, and silence about a withheld file is the entire defect this
        /// value exists to end. The compiler asking every future caller is worth
        /// more than the construction sites a default would save.
        let deliveryOutcome: OutputDeliveryOutcome?
        init(
            messageID: UUID,
            drafts: [AttachmentDraft],
            markScanned: Bool,
            expectedLaneID: String,
            deliveryOutcome: OutputDeliveryOutcome?
        ) {
            self.messageID = messageID
            self.drafts = drafts
            self.markScanned = markScanned
            self.expectedLaneID = expectedLaneID
            self.deliveryOutcome = deliveryOutcome
        }
    }

    // MARK: - Core Data Stack

    // Base type so the Simulator can use a plain `NSPersistentContainer` (the
    // device path still assigns an `NSPersistentCloudKitContainer` subclass).
    // The store is driven only through base-class API (loadPersistentStores /
    // newBackgroundContext / persistentStoreCoordinator), so no CloudKit-only
    // method is lost.
    private let container: NSPersistentContainer

    /// One-shot store-load task. Created by the first `ensureLoaded()` caller;
    /// every concurrent / later caller awaits this SAME task (single-flight).
    /// A failed task is sticky — its error rethrows to every subsequent
    /// caller, so a mis-provisioned store fails loudly instead of
    /// retry-thrashing on each touch.
    private var loadTask: Task<Void, Error>?

    // MARK: - Diagnostics

    /// Metadata-only store diagnostics — same `os.Logger` convention as the rest
    /// of the app (subsystem `Constants.identityNamespace`, one category per
    /// component; this shared file has no `WatchLog` visibility). Emits
    /// durations, row counts, and event counters ONLY — never conversation
    /// content, titles, ids, or CloudKit payloads.
    private static let log = Logger(subsystem: Constants.identityNamespace, category: "ConversationStore")

    /// Fetch passes quicker than this are not logged — steady-state reads must
    /// not spam the log. The signal a field baseline needs timestamps for is the
    /// SLOW pass (main-queue contention / attachment-heavy thread).
    private static let slowFetchThreshold: TimeInterval = 0.05

    /// Log one fetch pass when it exceeded `slowFetchThreshold`. `start` is
    /// taken BEFORE `context.perform`, so the duration includes the background
    /// queue hop + any sqlite contention (e.g. a CloudKit import holding the
    /// store busy) the caller actually waited on — the queueing delay is the
    /// signal, not noise. Duration + row count only.
    private static func logFetchIfSlow(_ pass: String, start: Date, rows: Int) {
        let elapsed = Date().timeIntervalSince(start)
        guard elapsed >= slowFetchThreshold else { return }
        log.notice("\(pass, privacy: .public) slow ms=\(Int(elapsed * 1000)) rows=\(rows)")
    }

    // MARK: - Init

    /// Production init — App Group on-disk store.
    private init() {
        #if DEBUG && !os(watchOS)
        // Screenshot mode (`-ConduckQAScreenshotMode`) must NEVER open the real
        // App Group store. On a signed real machine (the founder's Mac) that
        // store is the user's ACTUAL CloudKit-synced data: the idempotent seeder
        // skips a non-empty store, so real conversations appear instead of the
        // marketing seeds — and any accidental mutation would sync to the real
        // iCloud. Marketing captures therefore run against a fresh in-memory
        // store with CloudKit off (same shape as the test seam below); it dies
        // with the process. Plain QA mode keeps the production store so
        // persistence-sensitive QA flows still behave like the shipping app.
        if QAMode.isScreenshotMode {
            let container = NSPersistentContainer(name: "Conversations")
            if let description = container.persistentStoreDescriptions.first {
                description.type = NSInMemoryStoreType
                description.url = URL(fileURLWithPath: "/dev/null")
                ConversationStore.configureSyncOptions(on: description, cloudKit: false)
            }
            self.container = container
            return
        }
        #endif

        // CloudKit is attachable only where this process can actually reach the
        // container, and the penalty for getting it wrong is a silent kill rather
        // than an error: `NSPersistentCloudKitContainer` reaches
        // `CKContainer.default()` during CloudKit metadata migration once the
        // on-disk store loads, and that fatal-asserts (`CKContainer.m:748`) on an
        // unentitled host EVEN WITH `cloudKitContainerOptions` suppressed. Two
        // hosts qualify: the Simulator, and a native macOS build whose process
        // does not carry the container entitlement — an unsigned one in
        // practice, but the probe reads the entitlement rather than the
        // signature, so a mis-provisioned signed build lands here too (see
        // `Constants.hasICloudContainerEntitlement`; macOS sync is a signed
        // founder gate either way). Both fall back to the plain container,
        // which exercises no CloudKit codepath at all.
        #if targetEnvironment(simulator)
        let cloudKitUsable = false
        #else
        let cloudKitUsable = Constants.hasICloudContainerEntitlement
        #endif

        let container: NSPersistentContainer = cloudKitUsable
            ? NSPersistentCloudKitContainer(name: "Conversations")
            : NSPersistentContainer(name: "Conversations")

        if let description = container.persistentStoreDescriptions.first {
            // App Group store location (CRITICAL — see file header). The
            // headless Shortcut / App Intent runs in its own process and must
            // write this same sqlite. Fall back to the default location only
            // if the container URL is nil (mis-provisioned App Group); we log
            // and continue rather than crash so a dev build still runs.
            if let groupURL = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: Constants.appGroupID
            ) {
                description.url = groupURL.appendingPathComponent("Conversations.sqlite")
            } else {
                NSLog("[ConversationStore] App Group container URL is nil for \(Constants.appGroupID); falling back to default store location.")
            }

            // CloudKit mirroring fatal-asserts (EXC_BREAKPOINT in
            // PFCloudKitContainerProvider) on a host with no signed-in iCloud
            // account / unregistered container, crashing every launch. Neither
            // the Simulator nor an unsigned build is where CloudKit sync is
            // verified — that's a signed, real-device founder gate — so both run
            // local-only, matching the test seam.
            ConversationStore.configureSyncOptions(on: description, cloudKit: cloudKitUsable)
            if !cloudKitUsable {
                NSLog("[ConversationStore] CloudKit mirroring off (Simulator, or a build without the iCloud container entitlement) — conversations stay local to this device.")
            }
        }

        self.container = container
    }

    /// Testability seam — isolated store for unit tests so they never touch
    /// the App Group sqlite. `inMemory: true` uses an `NSInMemoryStoreType`
    /// (fresh, discarded at dealloc). A non-nil `storeURL` overrides the
    /// on-disk location (e.g. a per-test temp file) while keeping the SQLite
    /// type. CloudKit options are NOT attached here (tests are local-only by
    /// definition), but history-tracking stays on so the remote-change
    /// fan-in path is exercisable.
    ///
    /// Uses a plain `NSPersistentContainer` (NOT the CloudKit subclass) for the
    /// same reason the simulator production path does (see `init()` above): an
    /// `NSPersistentCloudKitContainer` validates that every store description is
    /// SQLite and rejects `NSInMemoryStoreType` with NSCocoaError 134060
    /// ("CloudKit integration is only supported for SQLite stores") on first
    /// load — even with `cloudKitContainerOptions` suppressed — and reaches
    /// `CKContainer.default()` (fatal-asserting on an unentitled host) for the
    /// on-disk variant. The store is driven only through base-class API, so no
    /// CloudKit method is lost; tests are local-only by definition.
    init(inMemory: Bool = false, storeURL: URL? = nil) {
        let container = NSPersistentContainer(name: "Conversations")

        if let description = container.persistentStoreDescriptions.first {
            if inMemory {
                description.type = NSInMemoryStoreType
                description.url = URL(fileURLWithPath: "/dev/null")
            } else if let storeURL {
                description.url = storeURL
            }
            // Tests are local-only by definition — never attach CloudKit (cloudKit: false).
            ConversationStore.configureSyncOptions(on: description, cloudKit: false)
        }

        self.container = container
    }

    /// Shared store-description configuration applied by every init. History
    /// tracking + remote-change posting stay ON in all configurations
    /// (harmless locally; required for CloudKit). The `cloudKit` flag attaches
    /// the CloudKit mirror to the user's own private iCloud database — ON for the
    /// production App Group store, OFF for the in-memory/on-disk test seam (tests
    /// stay local-only by definition).
    private static func configureSyncOptions(on description: NSPersistentStoreDescription, cloudKit: Bool) {
        if cloudKit {
            // Mirrors the local store into the user's private CloudKit database;
            // existing local conversations export on first launch, and turns from
            // the user's other devices import. Developer-blind (no backend).
            description.cloudKitContainerOptions = NSPersistentCloudKitContainerOptions(
                containerIdentifier: Constants.iCloudCloudKitContainerID
            )
        }

        description.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
        description.setOption(
            true as NSNumber,
            forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey
        )
    }

    // MARK: - Lifecycle

    /// Lazy-load the persistent stores on first use. Call explicitly at app
    /// launch if you want the store warmed before the UI needs it.
    func warmUp() async {
        _ = try? await ensureLoaded()
    }

    /// Await the one-time persistent-store load. Single-flight: the first
    /// caller creates `loadTask`; an async re-entry during the load awaits
    /// that SAME task, and a failed task rethrows its error to every later
    /// caller (sticky — pinned by
    /// `ConversationHistoryAssemblerTests.testAssembleThrowsWhenTheStoreCannotLoad`:
    /// the first touch rethrows the load failure rather than swallowing it).
    ///
    /// Internal rather than private so the same actor's `+GatewayAttempts`
    /// extension — a sibling FILE, which `private` does not reach — can gate its
    /// own entry points on the load the way every method here does. Not
    /// general-purpose module API.
    func ensureLoaded() async throws {
        let task: Task<Void, Error>
        if let loadTask {
            task = loadTask
        } else {
            // The unstructured Task inherits this actor's isolation, so the
            // load body runs on the store actor. Creating AND publishing the
            // task in one synchronous stretch (no suspension between the nil
            // check and the assignment) is what makes this single-flight.
            task = Task { try await self.performLoad() }
            loadTask = task
        }
        try await task.value
    }

    /// Load the persistent stores without ever blocking a thread: the store
    /// description(s) flip to `shouldAddStoreAsynchronously` and the container
    /// callback bridges through a checked continuation. On the wrist a
    /// first-touch load can sit tens of seconds behind CloudKit sync's sqlite
    /// activity — an awaiting caller merely suspends for that window instead
    /// of pinning an executor thread (and, transitively, the main actor).
    private func performLoad() async throws {
        let loadStart = Date()
        let descriptions = container.persistentStoreDescriptions
        for description in descriptions {
            description.shouldAddStoreAsynchronously = true
        }

        // `loadPersistentStores` calls back once per description, on an
        // arbitrary queue. First failure wins; success resumes only after the
        // LAST description lands. Lock-guarded so a late callback can never
        // double-resume the continuation.
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let state = OSAllocatedUnfairLock(initialState: (remaining: descriptions.count, resolved: false))
            container.loadPersistentStores { _, error in
                // nil = still pending (descriptions outstanding, or a late
                // callback after the `resolved` latch — either way, not this
                // callback's resume). First failure wins; success resolves only
                // once the LAST description lands; the latch makes a second
                // non-nil result — and thus a double-resume — impossible.
                let result: Result<Void, Error>? = state.withLock { state in
                    guard !state.resolved else { return nil }
                    if let error {
                        state.resolved = true
                        return .failure(error)
                    }
                    state.remaining -= 1
                    guard state.remaining <= 0 else { return nil }
                    state.resolved = true
                    return .success(())
                }
                if let result { continuation.resume(with: result) }
            }
        }

        // One-time milestone: what the first-touch store load (sqlite open +
        // CloudKit metadata on device) actually cost the first caller.
        // Duration only.
        Self.log.notice("store.load ms=\(Int(Date().timeIntervalSince(loadStart) * 1000))")

        // `viewContext` is deliberately UNCONFIGURED and UNUSED: every read AND
        // write in this file runs on a fresh `newBackgroundContext()` inside
        // `perform`, so nothing merges into (or saves from) the main-queue
        // context. Leaving auto-merge off also skips the per-save main-thread
        // merge pass a CloudKit import storm would otherwise fan onto the UI
        // queue for a context nobody reads. Anyone reintroducing `viewContext`
        // work must restore `automaticallyMergesChangesFromParent = true` +
        // an explicit merge policy here — without them a `viewContext` write
        // mutates stale snapshots and clobbers newer store rows on save.

        // Debounced fan-out target for remote arrivals. Constructed via
        // `MainActor.run` because the debouncer is `@MainActor` (its timing
        // state serializes with the observer callbacks, which land on
        // `queue: .main`) and an actor method cannot construct a main-isolated
        // object inline; one hop at load time, never per notification.
        let debouncer = await MainActor.run {
            RemoteChangeDebouncer {
                NotificationCenter.default.post(name: .conversationsDidChange, object: nil)
            }
        }

        // Fan remote CloudKit arrivals (when sync is enabled) into the same
        // `.conversationsDidChange` bus local mutations use, so view models
        // refetch when another device writes a turn — DEBOUNCED through
        // `RemoteChangeDebouncer`, so a dense mirroring-import storm coalesces
        // into a trailing post (capped at one per second of continuous churn)
        // instead of a 1:1 refetch fan. No Spotlight side-channel. The
        // per-notification counter log stays 1:1 so storm
        // density is measurable from a field log; lock-guarded because the
        // block is `@Sendable` even though `queue: .main` serializes it.
        let remoteChangeCount = OSAllocatedUnfairLock(initialState: 0)
        NotificationCenter.default.addObserver(
            forName: .NSPersistentStoreRemoteChange,
            object: container.persistentStoreCoordinator,
            queue: .main
        ) { _ in
            let n = remoteChangeCount.withLock { count -> Int in
                count += 1
                return count
            }
            Self.log.notice("remote.change n=\(n)")
            // `queue: .main` pins this block to the main thread even though it
            // is not statically main-isolated — `assumeIsolated` documents
            // (and runtime-asserts) that fact instead of paying a second hop.
            MainActor.assumeIsolated {
                debouncer.schedule()
            }
        }
    }

    /// Redacted, `Sendable` summaries of recent CloudKit mirroring events for the
    /// silent `CloudSyncMonitor` diagnostics. Runs the
    /// `NSPersistentCloudKitContainerEventRequest` on a fresh background context
    /// inside `perform` — the non-`Sendable` events never leave the block; only
    /// the `Sendable` snapshots return. Catches events that fired while the live
    /// observer was suspended. Empty when the store isn't a CloudKit container
    /// (Simulator / test seam) or on any failure — purely diagnostic, so it
    /// never throws into a caller's path.
    func recentSyncEventSummaries(limit: Int = 20) async -> [SyncEventSummary] {
        do { try await ensureLoaded() } catch { return [] }
        guard container is NSPersistentCloudKitContainer else { return [] }
        let context = container.newBackgroundContext()
        return await context.perform { [context] in
            let request = NSPersistentCloudKitContainerEventRequest.fetchEvents(after: .distantPast)
            request.resultType = .events
            guard
                let result = try? context.execute(request) as? NSPersistentCloudKitContainerEventResult,
                let events = result.result as? [NSPersistentCloudKitContainer.Event]
            else { return [] }
            return events.suffix(limit).map { SyncEventSummary(event: $0) }
        }
    }

    /// Post the local-mutation notification on the main actor. IMMEDIATE —
    /// never routed through `RemoteChangeDebouncer`: a user-visible local
    /// write must surface on the very next runloop turn; only the remote
    /// CloudKit fan-in coalesces.
    ///
    /// Internal rather than private for the same reason `ensureLoaded` is — the
    /// `+GatewayAttempts` extension is a sibling file, not a general caller.
    func postDidChange() async {
        await MainActor.run {
            NotificationCenter.default.post(name: .conversationsDidChange, object: nil)
        }
    }

    /// `userInfo` key carrying `[AttachedFileDescriptor]` on
    /// `.agentFilesDidAttachLocally`.
    nonisolated static let attachedFilesUserInfoKey = "agentFiles"

    /// Announce agent-output files THIS device just attached, so a listener that
    /// can reach another device (on iOS, `PhoneSessionManager`) can courier the
    /// metadata to a device that structurally cannot discover it. Main-actor
    /// posted for the same reason `postDidChange` is: observers are UI-adjacent
    /// and register on `queue: .main`.
    private func postAgentFilesDidAttach(_ descriptors: [AttachedFileDescriptor]) async {
        await MainActor.run {
            NotificationCenter.default.post(
                name: .agentFilesDidAttachLocally,
                object: nil,
                userInfo: [ConversationStore.attachedFilesUserInfoKey: descriptors]
            )
        }
    }

    /// Fresh per-call context for every store WRITE. Centralizes the
    /// load-bearing merge policy: `newBackgroundContext()` defaults to the
    /// throwing `NSErrorMergePolicy`, so a write site that forgot to set
    /// ObjectTrump would compile and pass conflict-free tests, then throw —
    /// or, on the `try?` best-effort paths, silently drop the save — the
    /// first time it collided with a concurrent CloudKit import. Background
    /// contexts can't be pre-configured on the container, so this factory is
    /// the single place the invariant lives. Never hand out
    /// `container.viewContext` — it is deliberately unconfigured (see
    /// `performLoad`). Reads don't come through here: a read-only context
    /// never saves, so no merge policy applies.
    ///
    /// Internal rather than private for the same reason `ensureLoaded` is — the
    /// `+GatewayAttempts` extension is a sibling file, not a general caller.
    func newWriteContext() -> NSManagedObjectContext {
        let context = container.newBackgroundContext()
        context.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        return context
    }

    /// Fresh per-call context for a store READ, with no merge policy for the
    /// reason above — a read-only context never saves. Exists only because the
    /// `+GatewayAttempts` extension cannot reach `container` from another file,
    /// and must not read through `newWriteContext`, which would blur where the
    /// merge-policy invariant applies. Every read path in THIS file keeps using
    /// `container.newBackgroundContext()` directly.
    func newReadContext() -> NSManagedObjectContext {
        container.newBackgroundContext()
    }

    // MARK: - Conversation CRUD

    /// Create a fresh conversation bound to `backend`. Sets `id`,
    /// `createdAt` = now, `lastActivityAt` = now, a freshly-minted local
    /// `sessionID` (UUID string), and a nil `title`.
    ///
    /// `id` defaults to a fresh UUID, which is what every ordinary caller
    /// wants. A caller passes its own only when it already committed to that
    /// identifier BEFORE the row existed — the composer mints file-server
    /// storage keys under `<conversationID>/` while the user is still staging
    /// attachments, so the row it later creates has to adopt the identifier the
    /// keys were minted against or that turn's first attachment lands in a
    /// folder no conversation owns.
    func createConversation(id: UUID = UUID(), backend: String) async throws -> ConversationRecord {
        try await ensureLoaded()
        let context = newWriteContext()
        // CANONICAL from the very first stamp this row carries, even though a
        // conversation with no messages has no envelope to validate. One rule
        // with no exceptions is the point: `lastActivityAt` is the value every
        // later envelope is checked against, so a store where some rows sit on a
        // millisecond boundary and some do not is a store whose readers would
        // have to know which writer produced a row before they could trust it.
        // See `TailProjection.canonical`.
        let now = TailProjection.canonical(Date())
        let sessionID = UUID().uuidString

        try await context.perform { [context] in
            let conversation = NSEntityDescription.insertNewObject(
                forEntityName: "Conversation", into: context
            )
            conversation.setValue(id, forKey: "id")
            conversation.setValue(nil, forKey: "title")
            conversation.setValue(now, forKey: "createdAt")
            conversation.setValue(now, forKey: "lastActivityAt")
            conversation.setValue(sessionID, forKey: "sessionID")
            conversation.setValue(backend, forKey: "backend")
            // No user turn yet — the snippet is captured on the first user
            // `appendMessage` (below). Set nil explicitly for clarity.
            conversation.setValue(nil, forKey: "titleSnippet")
            // No messages yet, so there is no tail to describe. Written
            // explicitly rather than left to the attribute's own absence,
            // because every OTHER site that touches `lastActivityAt` writes this
            // string in the same block and the one exception should be visible
            // as a decision rather than as an omission. Nil reads `.stale`,
            // which is the correct answer here — a surface falls back and finds
            // no tail either.
            conversation.setValue(nil, forKey: "tailProjection")
            try context.save()
        }

        await postDidChange()

        return ConversationRecord(
            id: id,
            title: nil,
            createdAt: now,
            lastActivityAt: now,
            sessionID: sessionID,
            backend: backend,
            titleSnippet: nil
        )
    }

    /// Clone an existing conversation onto a different gateway: create a NEW
    /// conversation bound to `toBackend` (a ref `rawString`) and copy the
    /// source conversation's turns (role / text / createdAt order) together
    /// with their attachments. The original is left untouched as a read-only
    /// archive.
    ///
    /// This is the "Clone & continue on <gateway>" recovery action (per the
    /// no-silent-reroute invariant — a thread's binding locks after its first
    /// turn, so switching gateways is a CLEAN CUT into a new thread, never a
    /// rebind that would hand a different agent a history it never produced).
    ///
    /// Attachments are DEEP-COPIED. Inline bytes (image JPEGs, extracted text)
    /// live in `Attachment.data` and re-encode on any gateway, so they always
    /// carry. A SERVER reference carries only when `targetFileLaneID` equals the
    /// lane that minted its `storedKey` — the lane is `SHA256(file-server URL +
    /// credential)`, NOT a gateway identity, so two gateways pointed at one
    /// WebDAV share a lane and the file genuinely still resolves. Otherwise the
    /// row is DETACHED: kept as a byte-less tombstone (`storedKey` nil, previews
    /// dropped) so the bubble still names the file and
    /// `ConverseRequest.spliceFileUnavailableNote` can tell the new gateway the
    /// file is unreachable rather than letting it silently vanish.
    ///
    /// INVARIANT: a cloned message never carries a `storedKey` without its
    /// owning lane, in either direction. A key with a nil/foreign lane fails
    /// `canAccessExistingBlob` closed and would refuse the user's Try Again with
    /// a bogus "file transfer isn't configured"; a foreign key also pollutes the
    /// retro-output detector's token set, which matches inbound keys WITHOUT a
    /// lane check and would suppress a legitimate output chip on the new
    /// gateway. `failureCode` / `failureWireCode` / `failureHadHistoryImages`
    /// are always dropped: `retry` re-asserts a stored terminal verdict, so a
    /// verdict rendered by the OLD gateway would make Try Again permanently
    /// self-refusing against a gateway that never issued it.
    ///
    /// A trailing user turn with no reply after it lands `failed` — the one
    /// structural rule covering a source turn that failed, one still `sending`,
    /// and a legacy nil. It is the state BOTH clone answers need: continue-now
    /// arms `beginRetry`'s `failed` → `sending` compare-and-set, and clone-only
    /// leaves an actionable Try Again instead of a delivered-looking dead row.
    /// It also stays in the thread either way, so a user who simply keeps typing
    /// carries it along in the next request's history (no status filter exists
    /// in `ConversationHistoryAssembler`) — the turn is never lost by declining
    /// to send it now.
    ///
    /// THE CLONE'S `lastActivityAt` IS ITS COPIED TAIL'S `createdAt`, NOT `now`.
    /// The copy loop preserves relative render order by advancing each turn one
    /// whole millisecond past `now`, so a clone stamped `lastActivityAt = now`
    /// claims the conversation's last activity happened BEFORE its own last
    /// message —
    /// an inconsistency no other write path can produce, since every append
    /// writes both halves from one `now`. It was invisible while nothing
    /// compared the two. `tailProjection` is validated by exactly that
    /// comparison, so a clone would have shipped an envelope that is stale in
    /// the transaction that wrote it, and every cloned thread would have been
    /// permanently mark-less on the wrist. The tail is also what a user's list
    /// sort should show: the fork's newest turn, not the instant the copy ran.
    ///
    /// CloudKit-store-compatible: uses the same `insertNewObject` +
    /// background-context save pattern as the existing CRUD (the mirror exports
    /// the new rows on the next sync).
    func cloneConversation(
        id: UUID,
        toBackend rawString: String,
        targetFileLaneID: String? = nil
    ) async throws -> CloneResult {
        try await ensureLoaded()
        let context = newWriteContext()
        let newID = UUID()
        // Canonical, and then every copied turn is derived from its INTEGER
        // millisecond value rather than from this `Date` (see the copy loop).
        let now = TailProjection.canonical(Date())
        let baseMilliseconds = TailProjection.milliseconds(from: now)
        let sessionID = UUID().uuidString

        let outcome: (snippet: String?, continuationMessageID: UUID?, lastActivityAt: Date, tailProjection: String?)
        outcome = try await context.perform { [context] in
            // Source conversation + its text turns (createdAt-ascending).
            let convoRequest = NSFetchRequest<NSManagedObject>(entityName: "Conversation")
            convoRequest.predicate = NSPredicate(format: "id == %@", id as CVarArg)
            convoRequest.fetchLimit = 1
            guard let source = try context.fetch(convoRequest).first else {
                throw StoreError.conversationNotFound
            }
            let sourceTitleSnippet = source.value(forKey: "titleSnippet") as? String

            let sourceHideEarlierPhotos = source.value(forKey: "hideEarlierPhotos") as? Bool ?? false

            let msgRequest = NSFetchRequest<NSManagedObject>(entityName: "Message")
            msgRequest.predicate = NSPredicate(format: "conversation.id == %@", id as CVarArg)
            msgRequest.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: true)]
            // The copy reads every message's attachments; without this the
            // relationship (and then each blob) faults one message at a time
            // inside the write transaction.
            msgRequest.relationshipKeyPathsForPrefetching = ["attachments"]
            let sourceMessages = try context.fetch(msgRequest)

            // New conversation bound to the target gateway.
            let conversation = NSEntityDescription.insertNewObject(
                forEntityName: "Conversation", into: context
            )
            conversation.setValue(newID, forKey: "id")
            // Title stays nil (gateways never give a real title; `titleSnippet`
            // drives the list label) — matches `createConversation`'s posture.
            conversation.setValue(nil, forKey: "title")
            conversation.setValue(now, forKey: "createdAt")
            // Provisional: overwritten below with the copied TAIL's `createdAt`
            // once the loop knows it (see the header). Written here anyway so a
            // source conversation with no copyable turns still leaves the
            // attribute populated rather than nil.
            conversation.setValue(now, forKey: "lastActivityAt")
            conversation.setValue(nil, forKey: "tailProjection")
            conversation.setValue(sessionID, forKey: "sessionID")
            conversation.setValue(rawString, forKey: "backend")
            conversation.setValue(sourceTitleSnippet, forKey: "titleSnippet")
            // "Keep chatting without photos" is a SAFETY switch the user threw
            // after a gateway choked on this thread's image history, and it must
            // survive the fork. Load-bearing now that attachments deep-copy: the
            // clone carries every image blob AND may auto-continue, so a reset
            // flag would replay the exact payload the user suppressed, on the
            // first request, unprompted.
            conversation.setValue(sourceHideEarlierPhotos, forKey: "hideEarlierPhotos")

            // Copy turns in order, one millisecond apart, so
            // `createdAt`-ascending render order matches the original.
            //
            // INTEGER ARITHMETIC, not repeated addition of a `TimeInterval`.
            // `baseMilliseconds + turnIndex` puts adjacent copies EXACTLY one
            // millisecond apart and lands every one of them on a millisecond
            // boundary, which is what the tail envelope's validity clause needs
            // (`TailProjection`). Accumulating 0.001 as a `Double` does neither:
            // 0.001 is not a binary fraction, so the running total drifts and
            // every copied turn sits at an instant no millisecond exactly names
            // — a thread long enough would eventually round two neighbours onto
            // one stamp, and the settled tail would be a value the envelope
            // could only approximate.
            var turnIndex: Int64 = 0
            var lastInserted: NSManagedObject?
            var lastInsertedID: UUID?
            var lastInsertedRole: String?
            var lastInsertedCreatedAt: Date?
            var lastSourceStatus: String?
            for sourceMessage in sourceMessages {
                // `Message.text` is optional in the model, so a partially-synced
                // CloudKit row can arrive with nil text. Coalesce (as
                // `MessageRecord` does on read) rather than skip: skipping would
                // silently drop that turn's ATTACHMENTS too, and — if it were the
                // trailing user turn — would leave the fork missing the user's
                // actual last message while mis-targeting the continuation at
                // the agent reply before it.
                let text = sourceMessage.value(forKey: "text") as? String ?? ""
                guard let role = sourceMessage.value(forKey: "role") as? String else { continue }
                let messageID = UUID()
                let createdAt = TailProjection.date(
                    fromMilliseconds: baseMilliseconds + turnIndex
                )
                let message = NSEntityDescription.insertNewObject(
                    forEntityName: "Message", into: context
                )
                message.setValue(messageID, forKey: "id")
                message.setValue(role, forKey: "role")
                message.setValue(text, forKey: "text")
                message.setValue(createdAt, forKey: "createdAt")
                message.setValue(sourceMessage.value(forKey: "sourceDevice"), forKey: "sourceDevice")
                // Cloned turns are historical — never `sending` (no in-flight).
                // The trailing user turn is re-stamped `failed` after the loop.
                message.setValue(nil, forKey: "status")
                message.setValue(conversation, forKey: "conversation")

                // Ownership grain matches the wire's exactly
                // (`ConverseRequest.fileLaneID(for:)`): a user row owns its
                // handed-off keys via `fileTransferLaneID`, an agent row owns
                // its scanned outputs via `outputScanLaneID`. Do not invent a
                // second grain — the two must agree or a row the wire trusts
                // could be detached here (or worse, the reverse).
                let sourceLaneKey = role == "agent" ? "outputScanLaneID" : "fileTransferLaneID"
                let sourceLaneID = sourceMessage.value(forKey: sourceLaneKey) as? String
                let laneCarries = sourceLaneID != nil && sourceLaneID == targetFileLaneID

                let copiedKeyCount = Self.copyAttachments(
                    from: sourceMessage,
                    to: message,
                    into: context,
                    laneCarries: laneCarries,
                    at: createdAt
                )
                // The lane rides along ONLY when a key actually did. Writing it
                // otherwise would leave a lane with nothing to own; omitting it
                // when a key carried would strand that key unusable.
                if copiedKeyCount > 0 {
                    message.setValue(targetFileLaneID, forKey: sourceLaneKey)
                    if role == "agent" {
                        // Preserved outputs are already scanned — re-arming would
                        // re-probe the file server for files it already adopted.
                        message.setValue(true, forKey: "outputScanDone")
                    }
                }

                lastInserted = message
                lastInsertedID = messageID
                lastInsertedRole = role
                lastInsertedCreatedAt = createdAt
                lastSourceStatus = sourceMessage.value(forKey: "status") as? String
                turnIndex += 1

                // Release the SOURCE row's blobs as soon as they are copied.
                // Everything here runs in one transaction, so without this an
                // image-heavy thread holds both sides — every faulted source
                // blob AND every dirty destination blob — resident until the
                // save. Re-faulting the source halves the peak; the destination
                // half is inherent to a single atomic save, which is the right
                // trade against a half-written clone.
                context.refresh(sourceMessage, mergeChanges: false)
            }

            // A trailing user turn has no reply in the clone and never will
            // unless something acts, so `failed` is true by construction — and
            // it is the affordance-bearing state (`deliveryErrorRow` + Try
            // Again). Mid-thread rows stay nil: an un-actionable Retry chip
            // above an existing agent reply would be nonsense.
            var continuationMessageID: UUID?
            if lastInsertedRole == "user", let lastInserted, lastSourceStatus != "sent" {
                // `sent` is excluded: that turn provably REACHED its gateway
                // (the status is only written when the reply lands), so a
                // missing agent row is a lost/partially-synced reply, not an
                // undelivered message. Stamping it `failed` would put "this
                // message wasn't delivered" under a message that was.
                lastInserted.setValue("failed", forKey: "status")
                // This stamp DECLARES a failure, so it mints — the same rule
                // every other failure writer follows (`mintDeliveryAttemptID`).
                // It is also the only identity this row will ever have until
                // something retries it: the copy loop above carries neither
                // `status` nor an attempt id across (cloned turns are
                // historical), so without a mint here the fork would carry a
                // `failed` turn with a nil identity — and a nil identity is
                // never matched by an acknowledgement, by design, so its mark
                // could never be retired. Fresh rather than inherited from the
                // source turn: that identity names an attempt made in another
                // thread against another gateway, and nothing about it is true
                // of this row.
                Self.mintDeliveryAttemptID(on: lastInserted)
                continuationMessageID = lastInsertedID
            }

            // Settle the conversation's activity stamp on the copied tail, and
            // build the tail envelope from that SAME row — see the header for
            // why `now` was wrong and why the two must be derived together.
            // Deriving them separately is how they drift: the envelope is valid
            // only while its millisecond equals `lastActivityAt`'s, so one
            // expression reading the tail and another reading the clock would
            // ship a clone whose projection is stale on arrival.
            var tailProjection: String?
            var settledActivityAt = now
            if let lastInsertedID, let lastInsertedCreatedAt {
                settledActivityAt = lastInsertedCreatedAt
                conversation.setValue(settledActivityAt, forKey: "lastActivityAt")
                tailProjection = TailProjection.encoded(
                    messageID: lastInsertedID,
                    createdAt: lastInsertedCreatedAt,
                    role: lastInsertedRole
                )
                conversation.setValue(tailProjection, forKey: "tailProjection")
            }

            try context.save()
            return (sourceTitleSnippet, continuationMessageID, settledActivityAt, tailProjection)
        }

        await postDidChange()

        return CloneResult(
            conversation: ConversationRecord(
                id: newID,
                title: nil,
                createdAt: now,
                // The snapshot reports what the ROW holds, never what this
                // method's clock said. A record disagreeing with its own row
                // would hand the caller a `lastActivityAt` the projection beside
                // it cannot validate against — the exact skew the settle above
                // exists to remove.
                lastActivityAt: outcome.lastActivityAt,
                sessionID: sessionID,
                backend: rawString,
                titleSnippet: outcome.snippet,
                tailProjection: outcome.tailProjection
            ),
            continuationMessageID: outcome.continuationMessageID
        )
    }

    /// Deep-copy `source`'s `Attachment` rows onto `destination`. Returns the
    /// number of copied rows that kept a non-empty `storedKey`, which is what
    /// tells the caller whether the owning lane may ride along.
    ///
    /// Routed through `applyDraft` rather than a hand-rolled `setValue` loop so
    /// the draft→column mapping stays at ONE site and can never drift between
    /// the append paths and this one.
    private static func copyAttachments(
        from source: NSManagedObject,
        to destination: NSManagedObject,
        into context: NSManagedObjectContext,
        laneCarries: Bool,
        at now: Date
    ) -> Int {
        // The relationship is an unordered `NSSet` (CloudKit rejects
        // `NSOrderedSet`) — `sequence` is the render/wire order, same as
        // `MessageRecord.init(managedObject:)`.
        guard let rows = source.value(forKey: "attachments") as? Set<NSManagedObject> else {
            return 0
        }
        let ordered = rows.sorted {
            ($0.value(forKey: "sequence") as? Int16 ?? 0) < ($1.value(forKey: "sequence") as? Int16 ?? 0)
        }

        var keptKeys = 0
        for row in ordered {
            let isServerReference = (row.value(forKey: "isServerReference") as? NSNumber)?.boolValue ?? false
            // TWO different consequences of a lane that does not carry, and
            // conflating them is a live bug:
            //
            //  - The KEY dies on EVERY row, not just server references. A
            //    dual-route inline image is an ordinary image row (bytes
            //    present, `isServerReference` false) that ALSO persisted an
            //    upload key, and `RetryFileReferenceResolver.hasRequiredStoredKeys`
            //    looks at ANY non-empty key. Leaving one on a lane-less clone
            //    makes the whole turn refuse Try Again with a bogus "file
            //    transfer isn't configured".
            //  - The BYTES are only unreachable for a server reference, whose
            //    `data` lives on the file server. An inline image keeps its
            //    bytes and rides the wire exactly as before; it just loses a key
            //    that no longer addresses anything.
            let keyDetached = !laneCarries
            let bytesUnreachable = isServerReference && !laneCarries

            var draft = AttachmentDraft(
                mimeType: row.value(forKey: "mimeType") as? String ?? "application/octet-stream",
                filename: row.value(forKey: "filename") as? String,
                data: bytesUnreachable ? Data() : (row.value(forKey: "data") as? Data ?? Data()),
                thumbnailData: bytesUnreachable ? nil : row.value(forKey: "thumbnailData") as? Data,
                width: Int(row.value(forKey: "width") as? Int32 ?? 0),
                height: Int(row.value(forKey: "height") as? Int32 ?? 0),
                byteSize: Int(row.value(forKey: "byteSize") as? Int64 ?? 0),
                sequence: Int(row.value(forKey: "sequence") as? Int16 ?? 0)
            )
            draft.isServerReference = isServerReference
            draft.storedKey = keyDetached ? nil : row.value(forKey: "storedKey") as? String
            draft.previewData = bytesUnreachable ? nil : row.value(forKey: "previewData") as? Data
            draft.previewKind = bytesUnreachable ? nil : row.value(forKey: "previewKind") as? String

            if draft.storedKey?.isEmpty == false { keptKeys += 1 }

            let attachment = NSEntityDescription.insertNewObject(
                forEntityName: "Attachment", into: context
            )
            applyDraft(
                draft,
                to: attachment,
                on: destination,
                id: UUID(),
                sequence: draft.sequence,
                at: now
            )
        }
        return keptKeys
    }

    // MARK: - Unresolved-turn aggregate (conversation-list activity)

    /// The unresolved USER turns of ONE conversation, reduced to what a list
    /// row needs: a stamp for the in-flight arm, and stamp-plus-identity for
    /// the failed one.
    nonisolated struct UnresolvedTurns: Sendable, Hashable {
        let newestSendingAt: Date?
        /// Stamp AND attempt identity of the newest failed turn, as one value
        /// — see `FailedTurnProjection`. The sending arm stays a bare date on
        /// purpose: nothing is ever acknowledged about a turn still in flight,
        /// so it carries no identity to skew.
        let newestFailed: FailedTurnProjection?
    }

    /// Whether `fetchConversations` also runs the unresolved-turn aggregate.
    ///   `.none`       — one query, today's exact behaviour. The DEFAULT.
    ///   `.turnStates` — plus ONE aggregate query, for the list surfaces.
    nonisolated enum ActivityProjection: Sendable {
        case none
        case turnStates
    }

    /// ONE whole-store query returning every UNRESOLVED user turn, keyed by
    /// conversation. Only `sending` and `failed` rows qualify. `sending` is
    /// genuinely transient (the launch sweep resolves it past the grace);
    /// `failed` is TERMINAL and nothing clears it short of an explicit Retry,
    /// so the set grows slowly over an install's life. That is a size fact, not
    /// a display fact — `ConversationActivityResolver` bounds the failed arm to
    /// failures that are still a conversation's last activity, so an old
    /// failure reported here does not pin a row red.
    ///
    /// SIBLING-SAFE BY CONSTRUCTION — this is the whole point. Deriving a
    /// conversation's delivery state from its LAST message is provably wrong
    /// when two turns overlap in one conversation, a case this store explicitly
    /// supports and warns about (see the `markPendingUserTurn` header). The
    /// aggregate reports the newest sending turn and the newest failed turn
    /// SEPARATELY, so a conversation holding both keeps both facts.
    func fetchUnresolvedUserTurns() async throws -> [UUID: UnresolvedTurns] {
        try await ensureLoaded()
        let context = container.newBackgroundContext()
        let start = Date()
        let (turns, rows): ([UUID: UnresolvedTurns], Int) = try await context.perform { [context] in
            let request = NSFetchRequest<NSManagedObject>(entityName: "Message")
            request.predicate = NSPredicate(
                format: "role == %@ AND (status == %@ OR status == %@)",
                "user", "sending", "failed"
            )
            // Prefetch the owning conversation so reading each row's id is not
            // an N-fault walk. NOT `propertiesToFetch` — projecting a
            // relationship keypath there is the documented trap (see
            // `searchConversationIDs`).
            request.relationshipKeyPathsForPrefetching = ["conversation"]
            let objects = try context.fetch(request)

            var sending: [UUID: Date] = [:]
            var failed: [UUID: FailedTurnProjection] = [:]
            for message in objects {
                guard let conversationID = (message.value(forKey: "conversation") as? NSManagedObject)?
                        .value(forKey: "id") as? UUID,
                      let createdAt = message.value(forKey: "createdAt") as? Date,
                      let status = message.value(forKey: "status") as? String else {
                    continue
                }
                if status == "sending" {
                    // A tie here is genuinely invisible: the sending arm reports
                    // only a stamp, so two turns at one instant yield the same
                    // value whichever wins.
                    if let existing = sending[conversationID], existing >= createdAt { continue }
                    sending[conversationID] = createdAt
                } else {
                    // The failed arm reports an IDENTITY, so the winner is
                    // chosen by an explicit total order (`isNewer(than:)`),
                    // never by which row this fetch happened to return first.
                    // Fetch order is not stable across devices or across two
                    // fetches on one device, and it would decide WHICH attempt
                    // id this conversation reports: two devices would then
                    // acknowledge different failures, and one device could
                    // select differently between the fetch that fed an
                    // acknowledgement and the next fetch that resolves the row
                    // — leaving that conversation red with no way for the user
                    // to retire it. The order lives on the value type rather
                    // than in an `NSSortDescriptor` so the tie-break is the
                    // documented `messageID.uuidString` comparison and not a
                    // store's byte layout or collation.
                    let candidate = FailedTurnProjection(
                        messageID: message.value(forKey: "id") as? UUID,
                        createdAt: createdAt,
                        deliveryAttemptID: message.value(forKey: "deliveryAttemptID") as? UUID
                    )
                    if let existing = failed[conversationID],
                       !candidate.isNewer(than: existing) { continue }
                    failed[conversationID] = candidate
                }
            }

            var merged: [UUID: UnresolvedTurns] = [:]
            for conversationID in Set(sending.keys).union(failed.keys) {
                merged[conversationID] = UnresolvedTurns(
                    newestSendingAt: sending[conversationID],
                    newestFailed: failed[conversationID]
                )
            }
            return (merged, objects.count)
        }
        Self.logFetchIfSlow("fetch.unresolvedTurns", start: start, rows: rows)
        return turns
    }

    /// Fetch every conversation, most-recently-active first (`lastActivityAt`
    /// descending — the list sort key).
    ///
    /// With `activity: .turnStates` the returned records also carry their
    /// unresolved-turn stamps, at a cost of exactly ONE additional query for the
    /// whole list — not one per conversation. Those derived fields are also what
    /// make a status flip repaint a list at all: a `sending → failed` transition
    /// writes only `Message` columns and does not bump `lastActivityAt`, so
    /// without them two consecutive fetches compare equal.
    func fetchConversations(
        activity: ActivityProjection = .none
    ) async throws -> [ConversationRecord] {
        try await ensureLoaded()
        let context = container.newBackgroundContext()
        let start = Date()
        let records: [ConversationRecord] = try await context.perform { [context] in
            let request = NSFetchRequest<NSManagedObject>(entityName: "Conversation")
            request.sortDescriptors = [
                NSSortDescriptor(key: "lastActivityAt", ascending: false)
            ]
            // Authoritative read by construction: a fresh background context
            // registers no objects, so this fetch materializes every row
            // straight from the store's current committed values — a
            // status/lastActivityAt flip saved by any write context is visible
            // to the very next fetch with no merge-timing dependency.
            let objects = try context.fetch(request)
            return objects.map { ConversationRecord(managedObject: $0) }
        }
        Self.logFetchIfSlow("fetch.conversations", start: start, rows: records.count)

        guard case .turnStates = activity else { return records }
        let turns = try await fetchUnresolvedUserTurns()
        guard !turns.isEmpty else { return records }
        return records.map { record in
            guard let turn = turns[record.id] else { return record }
            return record.withTurnStates(
                newestSendingAt: turn.newestSendingAt,
                newestFailed: turn.newestFailed
            )
        }
    }

    /// Fetch a single conversation by UUID, or nil if no row matches. One
    /// actor hop (predicate `id == %@`, `fetchLimit 1`). Required by the
    /// routing resolver to read a conversation's bound `backend` and route the
    /// turn to that gateway (per-conversation gateway binding) instead of the
    /// global default.
    func fetchConversation(id: UUID) async throws -> ConversationRecord? {
        try await ensureLoaded()
        let context = container.newBackgroundContext()
        return try await context.perform { [context] in
            let request = NSFetchRequest<NSManagedObject>(entityName: "Conversation")
            request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
            request.fetchLimit = 1
            guard let object = try context.fetch(request).first else {
                return nil
            }
            return ConversationRecord(managedObject: object)
        }
    }

    /// Resolve the `Conversation.id` the `Message` with `messageID` belongs to,
    /// or nil when no `Message` row carries that id (not yet appended / deleted).
    /// One actor hop (predicate `id == %@`, `fetchLimit 1`) reading the message's
    /// `conversation.id` relationship. Used by the Share-Extension
    /// notification-tap navigation path (`SharedInboxDrainer.drainAndResolve`):
    /// the shared turn's `Message.id` IS the envelope UUID, so this maps the
    /// envelope to the chat its turn landed in even when the foreground `drain()`
    /// (not this call) processed the envelope — durable, race-free navigation
    /// resolution. READ-ONLY: never mutates the store / re-dispatches.
    func conversationID(forMessageID messageID: UUID) async throws -> UUID? {
        try await ensureLoaded()
        let context = container.newBackgroundContext()
        return try await context.perform { [context] in
            let request = NSFetchRequest<NSManagedObject>(entityName: "Message")
            request.predicate = NSPredicate(format: "id == %@", messageID as CVarArg)
            request.fetchLimit = 1
            guard let object = try context.fetch(request).first,
                  let conversation = object.value(forKey: "conversation") as? NSManagedObject else {
                return nil
            }
            return conversation.value(forKey: "id") as? UUID
        }
    }

    /// Delete a single conversation by UUID. The `Cascade` delete rule on
    /// `Conversation.messages` removes its messages too, and the one on
    /// `Message.gatewayAttempts` removes the measurement rows linked to them.
    ///
    /// THE SCALAR ATTEMPT SWEEP IS NOT REDUNDANT WITH THAT CASCADE. An attempt
    /// row carries both a relationship to its user turn and a scalar
    /// `conversationID` snapshot, and only the scalar survives a row whose
    /// relationship was never set — a begin that ran before its message
    /// resolved, or a row imported ahead of the turn it belongs to. Those rows
    /// are invisible to the cascade and would outlive the history they measure,
    /// so they are deleted explicitly, in the SAME context and the same save:
    /// two saves would be two exports and a window where the conversation is
    /// gone and its measurements are not.
    ///
    /// This is the ONLY way an attempt is ever deleted — positive local deletion
    /// evidence. Mere absence of a parent never deletes one (see
    /// `fetchGatewayAttempts`).
    func deleteConversation(id: UUID) async throws {
        try await ensureLoaded()
        let context = newWriteContext()
        try await context.perform { [context] in
            for row in Self.gatewayAttemptRows(conversationID: id, in: context) {
                context.delete(row)
            }
            let request = NSFetchRequest<NSManagedObject>(entityName: "Conversation")
            request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
            let matches = try context.fetch(request)
            for object in matches {
                context.delete(object)
            }
            try context.save()
        }
        await postDidChange()
        #if !os(watchOS)
        // Per-device quick lane: a deleted conversation must not remain the
        // quick-capture target. (watchOS: no delete surface; resolvers already
        // tolerate a dangling pointer by minting fresh.)
        if await SettingsManager.shared.currentActiveConversationID() == id {
            await SettingsManager.shared.clearActiveConversation()
        }
        #endif
    }

    /// Delete every conversation (and, via cascade, every message), plus every
    /// gateway-attempt row.
    ///
    /// The attempt sweep is unconditional here rather than scalar-keyed: no
    /// conversation survives this call, so no attempt can survive it as anything
    /// but an orphan — including the relationship-less rows the cascade cannot
    /// see. Same context, same save, for the reason `deleteConversation` gives.
    func deleteAll() async throws {
        try await ensureLoaded()
        let context = newWriteContext()
        try await context.perform { [context] in
            for row in Self.allGatewayAttemptRows(in: context) {
                context.delete(row)
            }
            let request = NSFetchRequest<NSManagedObject>(entityName: "Conversation")
            let matches = try context.fetch(request)
            for object in matches {
                context.delete(object)
            }
            try context.save()
        }
        await postDidChange()
        #if !os(watchOS)
        // Every conversation is gone — whatever the quick-capture pointer
        // named is gone with it; clear unconditionally. (Gate required: this
        // file compiles into the Watch target, where SettingsManager doesn't
        // exist — see the picker-read gate below.)
        await SettingsManager.shared.clearActiveConversation()
        #endif
    }

    // MARK: - Picker read (CarPlay + the share-extension snapshot)
    //
    // iOS + macOS: consumers are the CarPlay scene (iOS app target) AND the
    // share-extension snapshot writer (`ShareTargetsSnapshotWriter.buildSnapshot`,
    // built on both iOS and macOS). Gated `#if os(iOS) || os(macOS)` — NOT the
    // Watch target, which SHARES this `ConversationStore.swift` via a pbxproj
    // membership exception but does NOT include `CarPlayConversationLabel.swift`
    // (its only dep here), so compiling this block on the wrist would reference a
    // symbol it lacks. `CarPlayConversationLabel.swift` itself is un-gated pure
    // Foundation, so it IS in the macOS build. No other-surface behavior change.
    #if os(iOS) || os(macOS)

    /// A recent conversation prepared for the CarPlay picker: the stored
    /// snapshot plus a *derived display label* (title ?? first-user-turn
    /// snippet ?? "New Conversation"). Computed inside the store so the picker
    /// renders ≤10 rows from ONE actor hop instead of N fetch-messages
    /// round-trips (CarPlay = iPhone CPU, not the wrist, but a cold-launch
    /// picker tap should not stall on a fan-out of fetches).
    ///
    /// Driver-safety / entitlement note: the label is a SHORT identifier
    /// (title or first-turn snippet), NEVER the message thread — CarPlay shows
    /// titles/dates only, never readable conversation content.
    struct RecentConversation: Identifiable, Hashable, Sendable {
        let id: UUID
        /// Derived display label — see `CarPlayConversationLabel.derive`.
        let label: String
        let lastActivityAt: Date
        /// `openclaw` / `hermes` — a conversation is bound to one backend.
        let backend: String
        /// Turn-state projection, filled only when the caller passed
        /// `includeTurnStates: true`. Same derived-not-stored contract as
        /// `ConversationRecord`'s pair; nil resolves to `.idle`.
        let newestSendingAt: Date?
        /// Stamp AND attempt identity together (`FailedTurnProjection`). These
        /// two surfaces are the reason it is one value: they have no per-row
        /// message fetch, so without an identity riding in with the stamp they
        /// could only ever resolve every failure as unacknowledged and
        /// contradict the conversation list sitting on the same screen.
        let newestFailed: FailedTurnProjection?
        /// The account-wide attention markers, copied verbatim off the stored
        /// row. STORED `Conversation` attributes, unlike the derived pair above
        /// — they are present on every read here, whatever `includeTurnStates`
        /// says, because the fetch materializes the record anyway.
        ///
        /// They are carried at all so the picker and the menu-bar list resolve a
        /// row through the SAME `ConversationActivityResolver` as the phone,
        /// from the same facts. Without them these two surfaces would answer
        /// "unseen" and "acknowledged" from nothing, and would contradict the
        /// conversation list sitting on the same screen.
        let lastViewedAt: Date?
        let failureSeenAttemptID: UUID?
        let tailProjection: String?

        init(
            id: UUID,
            label: String,
            lastActivityAt: Date,
            backend: String,
            newestSendingAt: Date? = nil,
            newestFailed: FailedTurnProjection? = nil,
            lastViewedAt: Date? = nil,
            failureSeenAttemptID: UUID? = nil,
            tailProjection: String? = nil
        ) {
            self.id = id
            self.label = label
            self.lastActivityAt = lastActivityAt
            self.backend = backend
            self.newestSendingAt = newestSendingAt
            self.newestFailed = newestFailed
            self.lastViewedAt = lastViewedAt
            self.failureSeenAttemptID = failureSeenAttemptID
            self.tailProjection = tailProjection
        }
    }

    /// Fetch the most-recently-active conversations for the CarPlay picker,
    /// each with a derived display label, capped at `limit` and sorted by
    /// `lastActivityAt` descending. ONE actor hop: the first user turn (used
    /// for the snippet fallback) is read inline per conversation against the
    /// same background context, so the caller never re-enters the actor per row.
    ///
    /// `limit` is the picker's row budget (the scene passes
    /// `CPListTemplate.maximumItemCount − 1`, reserving row 0 for "New voice
    /// chat"). Labels are derived via the pure `CarPlayConversationLabel`
    /// helper so the derivation is unit-testable in isolation.
    ///
    /// `includeTurnStates: false` keeps today's cost exactly. Passing true adds
    /// ONE whole-store aggregate query (never one per row) so the picker can
    /// render a closed vocabulary of delivery-status phrases beside each label.
    func fetchRecentForPicker(
        limit: Int,
        includeTurnStates: Bool = false
    ) async throws -> [RecentConversation] {
        try await ensureLoaded()
        guard limit > 0 else { return [] }
        let turns = includeTurnStates ? try await fetchUnresolvedUserTurns() : [:]
        let context = container.newBackgroundContext()
        return try await context.perform { [context] in
            let request = NSFetchRequest<NSManagedObject>(entityName: "Conversation")
            request.sortDescriptors = [
                NSSortDescriptor(key: "lastActivityAt", ascending: false)
            ]
            request.fetchLimit = limit
            let objects = try context.fetch(request)
            return objects.map { object -> RecentConversation in
                let record = ConversationRecord(managedObject: object)
                // First user turn (oldest) for the snippet fallback. Read
                // inline off the to-many relationship — no extra fetch round-
                // trip, no actor re-entry.
                let firstUserText: String? = {
                    guard let messages = object.value(forKey: "messages") as? Set<NSManagedObject> else {
                        return nil
                    }
                    let userTurns = messages
                        .compactMap { msg -> (Date, String, Bool)? in
                            guard (msg.value(forKey: "role") as? String) == "user",
                                  let text = msg.value(forKey: "text") as? String else {
                                return nil
                            }
                            let date = (msg.value(forKey: "createdAt") as? Date) ?? Date.distantFuture
                            // Does this turn carry an image attachment? Used so a
                            // photo-only first turn (empty text) yields a
                            // meaningful "[Image]" label instead of a blank row.
                            let hasImage: Bool = {
                                guard let atts = msg.value(forKey: "attachments") as? Set<NSManagedObject> else {
                                    return false
                                }
                                return atts.contains { ($0.value(forKey: "mimeType") as? String)?.hasPrefix("image/") == true }
                            }()
                            return (date, text, hasImage)
                        }
                        .sorted { $0.0 < $1.0 }
                    // Prefer the first user turn with non-empty text (a
                    // photo-only opening turn shouldn't blank the row label nor
                    // suppress a later text turn). If every user turn is
                    // text-empty but at least one carries an image, fall back to
                    // a localized "[Image]" marker. CarPlay still never renders
                    // readable thread content (entitlement contract).
                    if let firstWithText = userTurns.first(where: { !$0.1.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                        return firstWithText.1
                    }
                    if userTurns.contains(where: { $0.2 }) {
                        return String(localized: "[Image]")  // xcstrings: attachments
                    }
                    return userTurns.first?.1
                }()
                let label = CarPlayConversationLabel.derive(
                    title: record.title,
                    firstUserTurnText: firstUserText
                )
                return RecentConversation(
                    id: record.id,
                    label: label,
                    lastActivityAt: record.lastActivityAt,
                    backend: record.backend,
                    newestSendingAt: turns[record.id]?.newestSendingAt,
                    newestFailed: turns[record.id]?.newestFailed,
                    // Straight off the record — no aggregate, no extra fetch:
                    // `ConversationRecord(managedObject:)` above already read
                    // them from the row this loop is standing on.
                    lastViewedAt: record.lastViewedAt,
                    failureSeenAttemptID: record.failureSeenAttemptID,
                    tailProjection: record.tailProjection
                )
            }
        }
    }

    #endif

    // MARK: - Diagnostics read (forensics for the copyable report)

    /// One failed user turn, reduced to the classification facts the diagnostics
    /// report is allowed to carry. Deliberately NOT a `MessageRecord`: that type
    /// holds the turn's TEXT, and nothing with message content may travel toward
    /// `copyBlock()`. `backend` is the bound conversation's
    /// `RemoteAgentRef.rawString` (`openclaw` / `hermes` / `openrouter` /
    /// `custom_<uuid>`) — the report anonymizes customs to an ordinal, so the raw
    /// value stops here.
    struct FailedTurnSummary: Sendable {
        let failureCode: Int?
        let failureWireCode: String?
        let sourceDevice: String?
        let backend: String?
        let createdAt: Date
    }

    /// The newest failed user turns, bounded. Diagnostics' answer to its worst
    /// property: the pasteable report iterates PROBE results only, so it can read
    /// all-green while every real chat turn is failing — which is exactly the
    /// report a self-hoster sends when asking for help.
    ///
    /// Needs no new logging: `failureCode` / `failureWireCode` / `sourceDevice`
    /// are already persisted by `failTurn`, and the bound gateway is recoverable
    /// from the parent conversation's `backend`.
    ///
    /// NON-throwing by contract (`catch { return [] }`) — Diagnostics must never
    /// fail to render a report because a fetch lost a race with a CloudKit import.
    /// Relationship traversal stays INSIDE `perform`; the returned values are
    /// plain `Sendable` structs, never managed objects.
    func recentFailedTurnSummaries(limit: Int) async -> [FailedTurnSummary] {
        guard limit > 0 else { return [] }
        do {
            try await ensureLoaded()
        } catch {
            return []
        }
        let context = container.newBackgroundContext()
        do {
            return try await context.perform { [context] in
                let request = NSFetchRequest<NSManagedObject>(entityName: "Message")
                // `failureCode != nil` is what separates a GATEWAY failure from a
                // user CANCEL. Cancelling flips the turn to `failed` (so the Retry
                // chip appears and the row can't strand at `sending`) but writes no
                // classification, by design — a cancel is not a gateway verdict.
                // Without this clause every cancelled turn arrived in the pasted
                // support report as `send-failure … code=none`, manufacturing
                // failures the gateway never had. Fail closed in the same
                // direction as the orphan drop below: a failure nobody classified
                // is one nobody can act on.
                request.predicate = NSPredicate(
                    format: "status == %@ AND role == %@ AND failureCode != nil", "failed", "user"
                )
                request.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: false)]
                request.fetchLimit = limit
                // The parent is read for `backend`, so fault it in with the rows
                // rather than one round trip per message.
                request.relationshipKeyPathsForPrefetching = ["conversation"]
                return try context.fetch(request).compactMap { object -> FailedTurnSummary? in
                    // An orphaned row (no parent) can't be attributed to a
                    // gateway, and an unattributed failure line in a support
                    // report invites the wrong diagnosis — drop it.
                    guard let conversation = object.value(forKey: "conversation") as? NSManagedObject else {
                        return nil
                    }
                    return FailedTurnSummary(
                        failureCode: (object.value(forKey: "failureCode") as? Int32).map(Int.init),
                        failureWireCode: object.value(forKey: "failureWireCode") as? String,
                        sourceDevice: object.value(forKey: "sourceDevice") as? String,
                        backend: conversation.value(forKey: "backend") as? String,
                        createdAt: (object.value(forKey: "createdAt") as? Date) ?? Date.distantPast
                    )
                }
            }
        } catch {
            return []
        }
    }

    // MARK: - Message CRUD

    /// Append a message to an existing conversation and bump that
    /// conversation's `lastActivityAt` to now (so it floats to the top of the
    /// list). Throws `StoreError.conversationNotFound` if `conversationID`
    /// does not resolve — the caller is expected to `createConversation`
    /// first; a silent no-op would lose the user's turn, so we fail loudly.
    ///
    /// `id` (default nil) makes the append IDEMPOTENT on a caller-supplied
    /// message id. The Share-Extension drainer passes the share envelope's UUID
    /// as both the dedupe key AND the new `Message.id`, so re-draining the same
    /// envelope after a crash (or a duplicate drain trigger) never produces a
    /// second user turn:
    ///   - `id == nil` (the 5 existing callers): byte-identical to before — a
    ///     fresh `UUID()` is minted, no existence probe runs.
    ///   - `id` provided + a `Message` with that id ALREADY exists: a NO-OP —
    ///     return the existing message's `MessageRecord` snapshot WITHOUT
    ///     inserting a duplicate or re-bumping `lastActivityAt` (a re-bump would
    ///     wrongly float a stale thread on a benign re-drain).
    ///   - `id` provided + ABSENT: use it as the new message's id (instead of a
    ///     fresh `UUID()`).
    func appendMessage(
        id: UUID? = nil,
        role: String,
        text: String,
        conversationID: UUID,
        sourceDevice: String,
        status: String? = nil,
        fileTransferLaneID: String? = nil,
        /// The durable file-lane identity that OWNS this reply's output scan.
        /// Agent rows only, and only from a dispatch that latched a READY lane.
        /// Non-nil writes the explicit pending pair (`outputScanDone = false` +
        /// the identity) in the SAME insert, which is what makes the turn
        /// eligible for the retroactive scan; nil leaves BOTH fields nil, so
        /// `false`-without-identity is impossible for newly-written rows and an
        /// unprovable turn is never probed. Exists for the surfaces that persist
        /// a reply WITHOUT an exact user-turn id to flip (the Watch's standalone
        /// dispatch) — the paired-flip surfaces use `completeAgentTurn` instead.
        outputScanLaneID: String? = nil,
        /// The per-dispatch output folder this reply's turn was told to write
        /// into. Rides the SAME insert as `outputScanLaneID` for the reason in
        /// that write's comment: a lane without its folder is unrecoverable,
        /// not merely late. Persisted ONLY alongside a non-nil
        /// `outputScanLaneID` — a folder with no owning lane could never be
        /// listed against a proven server, so the pair is written or neither
        /// is. Nil on every surface that cannot mint one (the Watch has no
        /// file-server credential), and nil means UNKNOWN, which selects the
        /// row out of the automatic pass rather than closing it.
        outputBoxKey: String? = nil,
        attachments: [AttachmentDraft] = []
    ) async throws -> MessageRecord {
        try await ensureLoaded()

        let suppliedID = id
        let id = id ?? UUID()
        // Proposed by the clock, SETTLED inside the transaction against this
        // conversation's own last activity (`appendStamp`) — a millisecond
        // stamp has to be able to see the row it is being appended to. The one
        // settled value then goes into `Message.createdAt`, into the parent's
        // `lastActivityAt`, into the tail envelope's integer and into every
        // attachment row, so they are bit-identical locally and quantise to one
        // integer on every device that imports them.
        let proposedNow = Date()

        // ATTEMPT-START identity, minted here because a delivery attempt
        // begins here. It is NOT the row's identity for life: every writer that
        // later declares this turn `failed` re-mints, and the value an
        // acknowledgement is matched against is whichever failure declaration
        // wrote last (`mintDeliveryAttemptID` carries the argument, including
        // the trace that forces it).
        //
        // The start mint still earns its keep. A retryable row carries an
        // identity from the instant it exists rather than from the instant
        // something fails it, so a surface that reads the row before any
        // failure writer has run never sees a nameless attempt; and across the
        // mixed-version window, a build that predates the re-mint rule still
        // finds a non-nil identity on every row this one wrote.
        //
        // The one site that cannot route through the shared mint: the value is
        // needed OUTSIDE the transaction, so the row below and the
        // `MessageRecord` returned to the caller can be stamped from it.
        //
        // Only a USER turn actually being sent gets one. An agent reply, and a
        // headless capture written with no send state at all, have no attempt
        // to identify — and a nil identity is never matched by an
        // acknowledgement, which is the safe direction: it leaves a mark
        // standing rather than retiring one the user never saw.
        let deliveryAttemptID: UUID? = (role == "user" && status == "sending") ? UUID() : nil

        // Insert (+ any attachments) on a BACKGROUND context so the write never
        // blocks the main thread. Every chat write — user turn, plain agent
        // reply, or blob-bearing turn — goes off-main: a reply landing
        // mid-conversation must not stall the render/scroll pass (macOS
        // beachball). The next fetch reads it back from the store (a fresh
        // context materializes committed rows). Managed objects are
        // context-bound, so the Conversation is re-fetched INSIDE the `perform`.
        //
        // Dedupe-on-id (idempotent re-append): when the caller supplies an
        // `id` and a `Message` with that id already exists, return its snapshot
        // unchanged — no duplicate insert, no `lastActivityAt` re-bump, no
        // change post. The probe runs INSIDE the same `perform` as the insert
        // (same context, no suspension between probe and insert). NOT atomic
        // across two CONCURRENT same-id appends on separate fresh contexts
        // (CloudKit forbids model unique constraints), but the id-supplying
        // callers are the serialized inbox drainers, so that window is
        // unreachable in practice. Skipped entirely when `id == nil` (no probe
        // cost for the fresh-append callers).
        let bgContext = newWriteContext()
        // The settled stamp has to leave the transaction: the `MessageRecord`
        // returned below and its attachment snapshots must report the value the
        // row actually carries, not the clock this method read. A snapshot
        // disagreeing with its own row is the same class of defect as the
        // envelope disagreeing with `lastActivityAt`.
        let written: (dedupeHit: MessageRecord?, stamp: Date)
        written = try await bgContext.perform { [bgContext] in
            if let suppliedID {
                let probe = NSFetchRequest<NSManagedObject>(entityName: "Message")
                probe.predicate = NSPredicate(format: "id == %@", suppliedID as CVarArg)
                probe.fetchLimit = 1
                if let existing = try bgContext.fetch(probe).first {
                    return (MessageRecord(managedObject: existing), proposedNow)
                }
            }

            let convoRequest = NSFetchRequest<NSManagedObject>(entityName: "Conversation")
            convoRequest.predicate = NSPredicate(format: "id == %@", conversationID as CVarArg)
            convoRequest.fetchLimit = 1
            guard let conversation = try bgContext.fetch(convoRequest).first else {
                throw StoreError.conversationNotFound
            }

            let now = Self.appendStamp(proposed: proposedNow, appendingTo: conversation)

            let message = NSEntityDescription.insertNewObject(
                forEntityName: "Message", into: bgContext
            )
            message.setValue(id, forKey: "id")
            message.setValue(role, forKey: "role")
            message.setValue(text, forKey: "text")
            message.setValue(now, forKey: "createdAt")
            message.setValue(sourceDevice, forKey: "sourceDevice")
            message.setValue(status, forKey: "status")
            // Minted above, OUTSIDE this transaction, so the stored row and the
            // `MessageRecord` returned below carry the same identity. A
            // snapshot that disagreed with its own row would let a caller
            // acknowledge an attempt the store never recorded, which retires a
            // mark for a failure that is still standing.
            message.setValue(deliveryAttemptID, forKey: "deliveryAttemptID")
            message.setValue(fileTransferLaneID, forKey: "fileTransferLaneID")
            // Explicit pending marker + owner identity + the output folder the
            // dispatch named, written in the SAME transaction as the reply
            // itself: a process death between any two of them would otherwise
            // leave a reply whose recovery lane or destination folder was lost,
            // which is unrecoverable rather than merely late. All stay nil
            // without a dispatch lane (see the parameter docs).
            if let outputScanLaneID {
                message.setValue(false, forKey: "outputScanDone")
                message.setValue(outputScanLaneID, forKey: "outputScanLaneID")
                message.setValue(outputBoxKey, forKey: "outputBoxKey")
            }
            message.setValue(conversation, forKey: "conversation")

            for draft in attachments {
                Self.insertAttachment(draft, on: message, into: bgContext, at: now)
            }

            // Bump the parent's activity stamp so list sort reflects this turn,
            // and re-describe the tail in the SAME block. These two are one
            // fact: the envelope is valid only while its millisecond equals
            // `lastActivityAt`'s, so a site that bumps one without the other
            // leaves a well-formed string describing the previous tail — which
            // reads as "the newest message is still that user turn" and silently
            // withholds the unseen mark for a reply that did land. Both are
            // written from the SAME canonical `now` this insert stamped the
            // message with, so the equality holds by construction rather than by
            // luck — and holds on the devices that import the row too, because a
            // canonical stamp survives the mirror's millisecond quantisation
            // unchanged.
            conversation.setValue(now, forKey: "lastActivityAt")
            conversation.setValue(
                TailProjection.encoded(messageID: id, createdAt: now, role: role),
                forKey: "tailProjection"
            )

            // Denormalize a list-row title from the FIRST user turn only —
            // gateways never give us a real `title`, so this is what the
            // (per-row-fetch-averse) Watch list shows. Write once: skip when a
            // snippet already exists, and only for user turns (agent replies
            // never set it). Attachment turns can carry text too (captioned image).
            if role == "user",
               (conversation.value(forKey: "titleSnippet") as? String)?.isEmpty ?? true,
               let snip = Self.snippet(from: text) {
                conversation.setValue(snip, forKey: "titleSnippet")
            }

            try bgContext.save()
            return (nil, now)
        }

        if let dedupeHit = written.dedupeHit { return dedupeHit }
        let now = written.stamp

        await postDidChange()

        return MessageRecord(
            id: id,
            role: role,
            text: text,
            createdAt: now,
            sourceDevice: sourceDevice,
            status: status,
            deliveryAttemptID: deliveryAttemptID,
            fileTransferLaneID: fileTransferLaneID,
            // Mirror the row just written: an owner identity always arrives
            // paired with the explicit `false` marker (same rule as
            // `completeAgentTurn`), so an in-memory record and a re-fetched one
            // agree on retro-scan eligibility.
            outputScanDone: outputScanLaneID == nil ? nil : false,
            outputScanLaneID: outputScanLaneID,
            outputBoxKey: outputScanLaneID == nil ? nil : outputBoxKey,
            attachments: Self.attachmentRecords(from: attachments, at: now)
        )
    }

    /// Complete a foreground agent turn in ONE background-context save: flip the
    /// just-sent USER message to `userStatus` (`sent`), insert the agent reply,
    /// and — when the landing carries one — close its gateway-attempt row, then
    /// post a SINGLE `.conversationsDidChange`. Collapses the old two-call
    /// `updateStatus` + `appendMessage` sequence (two saves → two CloudKit
    /// exports → two reload posts) into one — the macOS foreground path used to
    /// fan those into the reload/merge storm that beachballed the UI. Returns
    /// the agent `MessageRecord` snapshot (same read-path contract as
    /// `appendMessage`).
    ///
    /// THE REPLY IS INSERTED AT MOST ONCE PER `agentMessageID`, and that
    /// guarantee owes nothing to the ledger. Every modern dispatch mints a
    /// deterministic id and carries it in its durable task metadata, so a
    /// duplicate callback — a relaunched process replaying a completion, a
    /// delegate and a foreground catch racing — probes, finds the reply it would
    /// have written, and returns it instead. This holds with `attempt == nil`,
    /// which is the whole point: the fail-open measurement layer must never be
    /// the only duplicate guard.
    ///
    /// TWO TOLERANCES, CHOSEN BY WHETHER THE LANDING IS CORRELATED. A legacy
    /// (`attempt == nil`) landing keeps the older rule — the user-status flip is
    /// a no-op if that id no longer resolves, and the reply lands anyway as long
    /// as the conversation does. A correlated landing knows exactly which turn
    /// it answers, so a missing user turn throws `userMessageNotFound` rather
    /// than parking a reply under a question the user deleted.
    ///
    /// MEASUREMENT IS FAIL-OPEN. When the combined save fails, the core reply is
    /// retried once, alone, in a fresh context, and only then is the attempt
    /// terminalization retried best-effort. A defect in the ledger cannot
    /// suppress a valid reply — the inverse ordering, which lets it, is the one
    /// failure mode this design exists to rule out. The store's own verdicts
    /// (`conversationNotFound`, `userMessageNotFound`, `attemptAlreadyTerminal`)
    /// are decisions, not save failures, and are rethrown untouched.
    func completeAgentTurn(
        userMessageID: UUID,
        userStatus: String,
        agentText: String,
        conversationID: UUID,
        sourceDevice: String,
        agentMessageID: UUID = UUID(),
        outputScanLaneID: String? = nil,
        /// The per-dispatch output folder this reply's turn was told to write
        /// into. Same rule as `appendMessage`: written in the SAME save as the
        /// lane identity, and only alongside a non-nil one.
        outputBoxKey: String? = nil,
        attachments: [AttachmentDraft] = [],
        /// What the transport observed at the terminal boundary, when it owns an
        /// attempt row to close. Nil for a legacy landing, for a dispatch whose
        /// begin never inserted, and for a pre-upgrade background blob — all
        /// three land exactly as they always did, and none of them fabricates a
        /// row after the fact.
        attempt: TerminalAttemptObservation? = nil
    ) async throws -> MessageRecord {
        try await ensureLoaded()

        guard let attempt, let attemptID = attempt.attemptID else {
            return try await landAgentTurn(
                userMessageID: userMessageID,
                userStatus: userStatus,
                agentText: agentText,
                conversationID: conversationID,
                sourceDevice: sourceDevice,
                agentMessageID: agentMessageID,
                outputScanLaneID: outputScanLaneID,
                outputBoxKey: outputBoxKey,
                attachments: attachments,
                attempt: nil,
                requiresExactUserMessage: false
            )
        }

        // A losing claimant drops the MEASUREMENT, never the turn: another local
        // owner is already writing this attempt's one terminal transition, so
        // this landing does its core work with no ledger reads or writes at all.
        guard terminalClaims.insert(attemptID).inserted else {
            return try await landAgentTurn(
                userMessageID: userMessageID,
                userStatus: userStatus,
                agentText: agentText,
                conversationID: conversationID,
                sourceDevice: sourceDevice,
                agentMessageID: agentMessageID,
                outputScanLaneID: outputScanLaneID,
                outputBoxKey: outputBoxKey,
                attachments: attachments,
                attempt: nil,
                requiresExactUserMessage: true
            )
        }
        defer { terminalClaims.remove(attemptID) }

        do {
            return try await landAgentTurn(
                userMessageID: userMessageID,
                userStatus: userStatus,
                agentText: agentText,
                conversationID: conversationID,
                sourceDevice: sourceDevice,
                agentMessageID: agentMessageID,
                outputScanLaneID: outputScanLaneID,
                outputBoxKey: outputBoxKey,
                attachments: attachments,
                attempt: attempt,
                requiresExactUserMessage: true
            )
        } catch let verdict as StoreError {
            // Not a save failure — a decision this store made about rows that do
            // or do not exist. Retrying it would only make it again.
            throw verdict
        } catch {
            // The combined save failed. Land the core turn alone, in a fresh
            // context, reading and writing no `GatewayAttempt` at all — the
            // reply is what the user is owed. The claim is still held, so the
            // best-effort measurement below is still this landing's to make.
            let record = try await landAgentTurn(
                userMessageID: userMessageID,
                userStatus: userStatus,
                agentText: agentText,
                conversationID: conversationID,
                sourceDevice: sourceDevice,
                agentMessageID: agentMessageID,
                outputScanLaneID: outputScanLaneID,
                outputBoxKey: outputBoxKey,
                attachments: attachments,
                attempt: nil,
                requiresExactUserMessage: true
            )
            await writeTerminalObservation(attempt)
            return record
        }
    }

    /// One pass of the agent-turn landing. Separated from `completeAgentTurn` so
    /// the fail-open retry can run the SAME transaction with the ledger switched
    /// off, rather than a second, subtly different one.
    ///
    /// `requiresExactUserMessage` carries the correlated/legacy tolerance split
    /// argued at `completeAgentTurn`.
    private func landAgentTurn(
        userMessageID: UUID,
        userStatus: String,
        agentText: String,
        conversationID: UUID,
        sourceDevice: String,
        agentMessageID: UUID,
        outputScanLaneID: String?,
        outputBoxKey: String?,
        attachments: [AttachmentDraft],
        attempt: TerminalAttemptObservation?,
        requiresExactUserMessage: Bool
    ) async throws -> MessageRecord {
        // Proposed by the clock, settled inside the transaction — one stamp for
        // the reply row, the parent's `lastActivityAt`, the tail envelope and
        // every attachment. Same rule as `appendMessage`, including why the
        // settled value has to travel back out for the returned snapshot.
        let proposedNow = Date()

        let bgContext = newWriteContext()
        #if DEBUG
        let injectedSaveFailure = debugFailsAttemptBearingSaves && attempt != nil
        #endif
        let landed: (existing: MessageRecord?, stamp: Date, wrote: Bool)
        landed = try await bgContext.perform { [bgContext] in
            let convoRequest = NSFetchRequest<NSManagedObject>(entityName: "Conversation")
            convoRequest.predicate = NSPredicate(format: "id == %@", conversationID as CVarArg)
            convoRequest.fetchLimit = 1
            guard let conversation = try bgContext.fetch(convoRequest).first else {
                throw StoreError.conversationNotFound
            }

            // Does this dispatch's reply already exist? Probed BEFORE anything
            // is written, in the same context as the insert it guards.
            let replyProbe = NSFetchRequest<NSManagedObject>(entityName: "Message")
            replyProbe.predicate = NSPredicate(format: "id == %@", agentMessageID as CVarArg)
            replyProbe.fetchLimit = 1
            let existingReply = try bgContext.fetch(replyProbe).first

            let userRequest = NSFetchRequest<NSManagedObject>(entityName: "Message")
            userRequest.predicate = NSPredicate(format: "id == %@", userMessageID as CVarArg)
            userRequest.fetchLimit = 1
            let userMessage = try bgContext.fetch(userRequest).first
            guard !requiresExactUserMessage || userMessage != nil else {
                throw StoreError.userMessageNotFound
            }

            // The duplicate/late-callback rule. An attempt makes exactly one
            // terminal transition, so a row that is already terminal says this
            // callback is not the first: suppress the terminal mutation AND the
            // reply insert. It is NOT the fail-open missing-row case — a missing
            // row means measurement never started, an already-terminal row means
            // this turn was already concluded, possibly by a cancel.
            //
            // Only a row that genuinely reads terminal suppresses anything:
            // `storedOutcomeIsTerminal` treats an ABSENT outcome column as open,
            // so a half-materialised row cannot cost the user a reply the
            // gateway really returned. Suppressing on unreadable measurement is
            // exactly the inversion the fail-open rule exists to forbid.
            var attemptRow: NSManagedObject?
            if let attemptID = attempt?.attemptID {
                attemptRow = Self.gatewayAttemptRow(id: attemptID, in: bgContext)
                if let attemptRow, Self.storedOutcomeIsTerminal(attemptRow) {
                    guard let existingReply else { throw StoreError.attemptAlreadyTerminal }
                    let flipped = userMessage.map { Self.applySendState(userStatus, to: $0) } ?? false
                    if flipped { try bgContext.save() }
                    return (MessageRecord(managedObject: existingReply), proposedNow, flipped)
                }
            }

            // Flip the user turn out of `sending` (a no-op if it no longer
            // resolves, on the legacy path that tolerates that).
            var wrote = false
            if let userMessage, Self.applySendState(userStatus, to: userMessage) {
                wrote = true
            }
            // Close the attempt in the SAME save as the reply. Update-only, and
            // only out of `inFlight`.
            if let attempt, let attemptRow,
               Self.applyTerminalObservation(attempt, to: attemptRow) {
                wrote = true
            }

            // The reply is already stored: return it untouched, and above all do
            // not re-bump `lastActivityAt` — a benign duplicate must not float a
            // settled thread back to the top of the list.
            if let existingReply {
                if wrote { try bgContext.save() }
                return (MessageRecord(managedObject: existingReply), proposedNow, wrote)
            }

            let now = Self.appendStamp(proposed: proposedNow, appendingTo: conversation)

            // Insert the agent reply (+ any output attachments) in the SAME save.
            let message = NSEntityDescription.insertNewObject(
                forEntityName: "Message", into: bgContext
            )
            message.setValue(agentMessageID, forKey: "id")
            message.setValue("agent", forKey: "role")
            message.setValue(agentText, forKey: "text")
            message.setValue(now, forKey: "createdAt")
            message.setValue(sourceDevice, forKey: "sourceDevice")
            // A macOS foreground dispatch that latched a READY file lane must
            // remain recoverable if the process exits before its asynchronous
            // output scan runs. Persist the one-way lane identity + explicit
            // FALSE + the output folder the dispatch named, in the SAME
            // transaction as the reply + sent flip. With no dispatch lane, ALL
            // THREE fields remain nil; false-without-identity and
            // folder-without-lane are therefore impossible for newly-written
            // rows.
            if let outputScanLaneID {
                message.setValue(false, forKey: "outputScanDone")
                message.setValue(outputScanLaneID, forKey: "outputScanLaneID")
                message.setValue(outputBoxKey, forKey: "outputBoxKey")
            }
            // `status` left unset → nil (agent replies carry no send-state, same
            // as the `appendMessage(status: nil)` agent-reply callers).
            message.setValue(conversation, forKey: "conversation")

            for draft in attachments {
                Self.insertAttachment(draft, on: message, into: bgContext, at: now)
            }

            // Bump the parent's activity stamp so list sort reflects this turn,
            // and re-describe the tail in the SAME block (same rule as
            // `appendMessage` — the envelope's millisecond must equal
            // `lastActivityAt`'s or the projection is stale on arrival, on this
            // device and on every device that imports the row). This is the site that
            // matters most for the wrist: an agent reply is the ONLY tail that
            // can make a row unseen, so a missed write here is precisely a
            // withheld mark for a reply the user has not read.
            // No `titleSnippet` capture — agent replies never set it (user turns only).
            conversation.setValue(now, forKey: "lastActivityAt")
            conversation.setValue(
                TailProjection.encoded(messageID: agentMessageID, createdAt: now, role: .agent),
                forKey: "tailProjection"
            )

            #if DEBUG
            if injectedSaveFailure { throw DebugInjectedSaveFailure() }
            #endif
            try bgContext.save()
            return (nil, now, true)
        }

        if landed.wrote { await postDidChange() }
        if let existing = landed.existing { return existing }
        let now = landed.stamp

        return MessageRecord(
            id: agentMessageID,
            role: "agent",
            text: agentText,
            createdAt: now,
            sourceDevice: sourceDevice,
            status: nil,
            outputScanDone: outputScanLaneID == nil ? nil : false,
            outputScanLaneID: outputScanLaneID,
            outputBoxKey: outputScanLaneID == nil ? nil : outputBoxKey,
            attachments: Self.attachmentRecords(from: attachments, at: now)
        )
    }

    /// The canonical stamp the next message appended to `conversation` carries:
    /// `proposed` snapped onto its millisecond, advanced if that millisecond is
    /// not strictly past the conversation's current `lastActivityAt`.
    ///
    /// WHY IT IS NOT JUST `TailProjection.canonical(Date())`. Quantising to
    /// milliseconds collapses every instant inside one millisecond onto one
    /// value, and `Message.createdAt` is the ONLY order this store keeps for a
    /// thread — the render fetch, the clone's copy loop and every tail pick sort
    /// on it. Two writes into one conversation inside the same millisecond would
    /// otherwise share a stamp and leave their order to whatever a fetch
    /// happened to return, which is stable neither across two fetches here nor
    /// across two devices. That is not a cost quantisation introduces, only one
    /// it makes visible: `Conversation.lastActivityAt` and `Message.createdAt`
    /// both cross CloudKit as DATE fields at millisecond granularity, so a pair
    /// of turns a few hundred microseconds apart already arrives on every OTHER
    /// device indistinguishable. Settling the stamp here fixes both ends at once
    /// — the thread has one order, and it is the same order everywhere.
    ///
    /// THE ADVANCE IS BOUNDED BY THE CONVERSATION'S OWN NEWEST ACTIVITY, never
    /// by a global clock or a monotonic counter: it moves the stamp exactly far
    /// enough to stay one millisecond ahead of the row it is being appended to,
    /// and it stops the moment real time overtakes that row again. So a burst
    /// spreads over as many milliseconds as it has turns and nothing else in the
    /// store is displaced. `lastActivityAt` is the right thing to measure
    /// against because every writer that adds a message writes it from this same
    /// stamp, which makes it the newest message's stamp by construction.
    ///
    /// AND THE ADVANCE ITSELF IS CAPPED, because `lastActivityAt` is not this
    /// device's value. It is a CloudKit-mirrored column, written from some other
    /// device's wall clock, so a peer whose clock is wrong can hand this a row
    /// dated arbitrarily far in the future — and following it unconditionally
    /// would make that offset PERMANENT: every later append into that
    /// conversation would inherit it and add a millisecond, so nothing would
    /// ever pull the row back to real time. Two things break at once when it
    /// does. `sweepStaleSendingUserTurns` fetches `createdAt < now - grace`, so
    /// a future-dated `sending` turn is never swept and its bubble keeps a
    /// spinner with no Retry for as long as the offset lasts; and
    /// `ReadStateStore.clamped` caps a view marker at `now + clockSkewGrace`, so
    /// a `lastActivityAt` further ahead than that can never be covered and the
    /// row is bold, discreet and pinned to the top of the list no matter how
    /// many times the user reads it.
    ///
    /// The cap is `clockSkewGrace` past the proposed instant — the SAME budget
    /// the read marker's clamp allows — and the pairing is the point rather
    /// than a coincidence: no stamp this store writes exceeds the ceiling a view
    /// marker is allowed to reach, so every conversation stays markable as read,
    /// and one further turn is all it takes to pull a poisoned row back inside
    /// it. Skew inside the budget is absorbed, which is what keeps ordinary
    /// multi-device drift from reordering a thread; skew beyond it is declined,
    /// and the append simply lands at real time. The residual cost falls
    /// entirely on the row that is already corrupt: its future-dated message
    /// keeps sorting after the new one, which is an inconsistency that row
    /// already carries and this cannot repair.
    private static func appendStamp(
        proposed: Date,
        appendingTo conversation: NSManagedObject
    ) -> Date {
        let proposedMilliseconds = TailProjection.milliseconds(from: proposed)
        guard let previous = conversation.value(forKey: "lastActivityAt") as? Date else {
            return TailProjection.date(fromMilliseconds: proposedMilliseconds)
        }
        let previousMilliseconds = TailProjection.milliseconds(from: previous)
        // `.max` can only arrive from a stamp no `Int64` could hold, i.e. a
        // corrupt row. Declining to advance past it keeps this total instead of
        // trapping on overflow; the row is unusable either way.
        let mustExceed = previousMilliseconds == .max
            ? previousMilliseconds
            : previousMilliseconds + 1
        // Saturating rather than wrapping, for the same reason: the addition is
        // unreachable in real time (the proposal is a wall clock) but has to
        // stay total for a corrupt one.
        let graceMilliseconds = Int64(ReadStateStore.clockSkewGrace * 1000)
        let ceiling = proposedMilliseconds > Int64.max - graceMilliseconds
            ? Int64.max
            : proposedMilliseconds + graceMilliseconds
        return TailProjection.date(
            fromMilliseconds: min(max(proposedMilliseconds, mustExceed), ceiling)
        )
    }

    /// Insert one `Attachment` row for `draft`, linked to `message`, into
    /// `context`. Shared by every write path (`appendMessage` /
    /// `completeAgentTurn`) so the blob-write mapping lives in one place.
    private static func insertAttachment(
        _ draft: AttachmentDraft,
        on message: NSManagedObject,
        into context: NSManagedObjectContext,
        at now: Date
    ) {
        let attachment = NSEntityDescription.insertNewObject(
            forEntityName: "Attachment", into: context
        )
        applyDraft(draft, to: attachment, on: message, id: UUID(), sequence: draft.sequence, at: now)
    }

    /// Single site that maps an `AttachmentDraft` onto an already-inserted
    /// `Attachment` managed object. Every write path (`insertAttachment` /
    /// `addAttachments` / `reconcileOutputScan`) funnels through here so the
    /// draft→column mapping — including the model-v6 `previewData` / `previewKind`
    /// keys — lives in ONE place and can never drift between paths. Only the two
    /// inputs that genuinely vary per site are parameters: `id` (a fresh UUID at
    /// every site) and `sequence` (the draft's own 0-based order for the append
    /// paths; the retro-scan-allocated value continuing after the message's
    /// existing max for `reconcileOutputScan`). `now` is the row's `createdAt`.
    private static func applyDraft(
        _ draft: AttachmentDraft,
        to attachment: NSManagedObject,
        on message: NSManagedObject,
        id: UUID,
        sequence: Int,
        at now: Date
    ) {
        attachment.setValue(id, forKey: "id")
        attachment.setValue(draft.mimeType, forKey: "mimeType")
        attachment.setValue(draft.filename, forKey: "filename")
        attachment.setValue(draft.data, forKey: "data")
        attachment.setValue(draft.thumbnailData, forKey: "thumbnailData")
        // `clamping:` on the narrowing conversions — the share-extension drain
        // path feeds these straight from the App-Group JSON manifest, where a
        // corrupt-but-decodable value (any valid Int) would otherwise trap the
        // drain on every subsequent launch.
        attachment.setValue(Int32(clamping: draft.width), forKey: "width")
        attachment.setValue(Int32(clamping: draft.height), forKey: "height")
        attachment.setValue(Int64(draft.byteSize), forKey: "byteSize")
        attachment.setValue(Int16(clamping: sequence), forKey: "sequence")
        attachment.setValue(draft.isServerReference, forKey: "isServerReference")
        attachment.setValue(draft.storedKey, forKey: "storedKey")
        attachment.setValue(draft.previewData, forKey: "previewData")
        attachment.setValue(draft.previewKind, forKey: "previewKind")
        attachment.setValue(now, forKey: "createdAt")
        attachment.setValue(message, forKey: "message")
    }

    /// Build the `AttachmentRecord` snapshots returned to a caller after a write.
    /// WITHOUT the full image bytes (thumbnail + metadata only; text files carry
    /// their decoded text), matching the read-path snapshot contract.
    private static func attachmentRecords(
        from attachments: [AttachmentDraft],
        at now: Date
    ) -> [AttachmentRecord] {
        attachments
            .sorted { $0.sequence < $1.sequence }
            .map { draft in
                let isImage = draft.mimeType.hasPrefix("image/")
                // Server references carry no local bytes — never decode `data`
                // (it's empty) into extractedText, and surface the ref flags so
                // the just-sent bubble renders the file chip correctly.
                let extracted = (isImage || draft.isServerReference)
                    ? nil
                    : String(data: draft.data, encoding: .utf8)
                return AttachmentRecord(
                    id: UUID(),
                    mimeType: draft.mimeType,
                    filename: draft.filename,
                    thumbnailData: draft.thumbnailData,
                    extractedText: extracted,
                    width: draft.width,
                    height: draft.height,
                    byteSize: draft.byteSize,
                    sequence: draft.sequence,
                    createdAt: now,
                    isServerReference: draft.isServerReference,
                    storedKey: draft.storedKey,
                    previewKind: draft.previewKind
                )
            }
    }

    /// Update a message's send-state `status` (`sending` → `sent` / `failed`).
    /// No-op if the message id does not resolve (e.g. deleted mid-flight on
    /// another device). Fires `.conversationsDidChange` so the bubble footer
    /// re-renders (spinner → sent / Retry). Writes on a BACKGROUND context so a
    /// status flip never blocks the main thread (see `appendMessage`).
    func updateStatus(messageID: UUID, status: String) async throws {
        try await ensureLoaded()
        let bgContext = newWriteContext()
        let changed: Bool = try await bgContext.perform { [bgContext] in
            let request = NSFetchRequest<NSManagedObject>(entityName: "Message")
            request.predicate = NSPredicate(format: "id == %@", messageID as CVarArg)
            request.fetchLimit = 1
            guard let message = try bgContext.fetch(request).first else { return false }
            guard Self.applySendState(status, to: message) else { return false }
            try bgContext.save()
            return true
        }
        guard changed else { return }
        await postDidChange()
    }

    /// Single site for a send-state write. Setting `sent` ALSO clears
    /// the failure classification — the frozen rule is "clear on successful
    /// retry", so success is the only transition that erases it. `sending`
    /// deliberately KEEPS the old classification (a retry in flight still
    /// shows nothing — the row renders only for `failed` — but a NEW failure
    /// overwrites and a success clears; the stale value never surfaces).
    /// `failed` writes the fields explicitly in `failTurn` — plain callers
    /// (sweeps, cancellation) leave them untouched. A REAL transition INTO
    /// `failed` also mints a fresh delivery attempt identity, because this
    /// writer is the one declaring that failure; a `failed` → `failed`
    /// re-write declares nothing and mints nothing. See
    /// `mintDeliveryAttemptID`.
    @discardableResult
    private static func applySendState(_ status: String, to message: NSManagedObject) -> Bool {
        let previousStatus = message.value(forKey: "status") as? String
        let clearsFailure = status == "sent"
            && (message.value(forKey: "failureCode") != nil
                || message.value(forKey: "failureWireCode") != nil
                || message.value(forKey: "failureHadHistoryImages") != nil)
        // A REDUNDANT WRITE IS NOT A WRITE. Re-applying the status a row already
        // carries, with no failure classification left to clear, declares
        // nothing new — so it must not dirty the object and must not export a
        // CKRecord. Reporting that lets the one caller that can be handed a
        // no-op skip its save and its change notification too.
        guard previousStatus != status || clearsFailure else { return false }
        message.setValue(status, forKey: "status")
        // A real transition into `failed` DECLARES the failure, so it stamps a
        // fresh identity even over one the row already carries. The
        // `previousStatus` guard is the whole idempotence story: re-writing
        // `failed` onto a row that is already `failed` declares nothing new, so
        // it must not mint — a mint there would relight a retired mark on every
        // redundant write and export a CKRecord for each one.
        if status == "failed", previousStatus != "failed" {
            mintDeliveryAttemptID(on: message)
        }
        if status == "sent" {
            message.setValue(nil, forKey: "failureCode")
            message.setValue(nil, forKey: "failureWireCode")
            message.setValue(nil, forKey: "failureHadHistoryImages")
        }
        return true
    }

    /// Stamp `message` with a FRESH delivery attempt identity. UNCONDITIONAL by
    /// design: an identity the row already carries is OVERWRITTEN, never
    /// preserved. Every writer that declares a user turn `failed` calls it —
    /// `applySendState`, both writing branches of `applyFailure`, the launch
    /// sweep and the two `markPendingUserTurn(s)` flips through
    /// `applySendState`, and the clone's synthetic `failed` stamp — and so does
    /// `beginRetry`, which starts the next attempt. So does the ONE writer that
    /// declares nothing and still republishes a failure: `repairTailProjection`,
    /// when it snaps a failed user tail's `createdAt` onto its millisecond. It
    /// is in this list because record-level last-writer-wins does not care what
    /// a writer meant — a save that carries `failed` plus an inherited identity
    /// is indistinguishable from a fresh declaration of that identity, which is
    /// precisely the ABA the trace below rules out.
    ///
    /// WHAT AN ACKNOWLEDGEMENT ACTUALLY MATCHES IS THE LATEST FAILURE
    /// DECLARATION, not one immutable id per semantic delivery attempt. That is
    /// the opposite of the intuitive rule, so it is stated first and argued
    /// below: `Message` rows converge under RECORD-LEVEL last-writer-wins, and
    /// under that rule a preserved identity is an ABA hazard, not a stability
    /// guarantee.
    ///
    /// THE TRACE THAT FORCES IT. Turn M is `sending` under identity A1 on
    /// devices A and B. A fails it, the user is shown the mark and acknowledges
    /// it, so the conversation stores `failureSeenAttemptID = A1`. B then goes
    /// offline still holding `sending`/A1. A retries: `beginRetry` mints A2, the
    /// send fails again, and A exports `failed`/A2 — the mark correctly returns.
    /// B relaunches; its launch sweep finds ITS OWN copy of M still `sending`
    /// past the grace, flips it to `failed`, and — were the existing id
    /// preserved — exports `failed`/A1 with a LATER record timestamp. The fleet
    /// converges on `failed`/A1 against an acknowledgement of A1, so a message
    /// that never sent, and whose second failure was never put in front of
    /// anyone, renders CLEAR. Permanently: `failed` is terminal, nothing writes
    /// that row again, and on the Watch the row shows nothing at all.
    ///
    /// A FRESH id closes it by making the stale writer's export self-defeating.
    /// B's sweep publishes an identity no acknowledgement can name, so whichever
    /// of the two records wins the merge, the stored acknowledgement matches
    /// neither and the mark stands. The residual cost is a bounded OVER-report —
    /// a straggling writer can re-arm a mark the user already retired, which
    /// costs one thread open — and that is the direction this app takes every
    /// time: an extra mark is a nuisance, a missing one is a message the user
    /// never learns did not send.
    ///
    /// IT SUBSUMES THE LEGACY CASE RATHER THAN SPECIAL-CASING IT. A turn written
    /// `sending` by a build older than this attribute reaches `failed` carrying
    /// no identity at all, and a failure with no identity can never be
    /// acknowledged, so it would stay marked for the life of the install. The
    /// same mint that runs for every other failure gives it one.
    ///
    /// CALLERS MUST GATE ON A REAL CHANGE. The mint is unconditional; CALLING it
    /// is not. A writer that changes nothing — a repeat `failed` write, a
    /// classification that upgrades nothing — must not reach this at all, or
    /// every no-op would relight the mark and export a CKRecord for it. Each
    /// call site carries that guard, and the guards are the reason this is not a
    /// write amplifier.
    private static func mintDeliveryAttemptID(on message: NSManagedObject) {
        message.setValue(UUID(), forKey: "deliveryAttemptID")
    }

    /// Flip every still-`sending` USER turn in a conversation to `status`
    /// (`sent` / `failed`). This is the AUTHORITATIVE send-state update for the
    /// iOS background converse path: the `BackgroundRemoteAgent` delegate runs
    /// even after an OS suspend+relaunch — when the foreground continuation that
    /// would have called `updateStatus(messageID:)` is gone — so without this
    /// the bubble spinner would stick on `sending` forever. Scoped to
    /// `status == "sending"` user turns, so it never disturbs already-resolved
    /// turns or headless captures (which are written `status == nil` = sent).
    /// Non-throwing (best-effort): a background-delegate cleanup must not throw.
    ///
    /// A flip to `failed` here DECLARES that failure — this writer is often the
    /// only one that ever will — so each flipped turn is stamped with a fresh
    /// delivery attempt identity via `applySendState`. The `sending`-only
    /// predicate is what keeps that from repeating: a turn already `failed` is
    /// not in the fetch, so it is neither re-written nor re-minted.
    func markPendingUserTurns(conversationID: UUID, to status: String) async {
        do { try await ensureLoaded() } catch { return }
        let context = newWriteContext()
        await context.perform { [context] in
            let request = NSFetchRequest<NSManagedObject>(entityName: "Message")
            request.predicate = NSPredicate(
                format: "conversation.id == %@ AND role == %@ AND status == %@",
                conversationID as CVarArg, "user", "sending"
            )
            let pending = (try? context.fetch(request)) ?? []
            guard !pending.isEmpty else { return }
            for message in pending { Self.applySendState(status, to: message) }
            try? context.save()
        }
        await postDidChange()
    }

    /// EXACT-message variant of `markPendingUserTurns`: flip ONE user turn off
    /// `sending`, addressed by its `Message.id`. Same guards as the
    /// conversation-wide flip — only a `role == "user"` message whose status is
    /// still `"sending"` is touched, so a turn that already resolved (or an
    /// agent message, or a foreign id) is never disturbed. Used by the
    /// background delegates when the dispatch site threaded the user
    /// `Message.id` through `RemoteAgentBackgroundMetadata.userMessageID`: the
    /// conversation-wide flip ALIASES sibling in-flight turns (two concurrent
    /// `sending` turns in one conversation — a long headless think + an in-app
    /// follow-up — and whichever resolves first would flip both, rendering a
    /// later-failing sibling as delivered or a later-succeeding one as Retry).
    /// Non-throwing (best-effort, delegate cleanup path); a missing /
    /// non-matching message id is a silent no-op.
    func markPendingUserTurn(messageID: UUID, to status: String) async {
        do { try await ensureLoaded() } catch { return }
        let context = newWriteContext()
        let flipped: Bool = await context.perform { [context] in
            let request = NSFetchRequest<NSManagedObject>(entityName: "Message")
            request.predicate = NSPredicate(
                format: "id == %@ AND role == %@ AND status == %@",
                messageID as CVarArg, "user", "sending"
            )
            request.fetchLimit = 1
            guard let message = (try? context.fetch(request))?.first else { return false }
            Self.applySendState(status, to: message)
            try? context.save()
            return true
        }
        if flipped { await postDidChange() }
    }

    // MARK: - Failure classification writers

    /// The failure classification carried into `failTurn` — Conduck's own
    /// `AppError.errorCode` plus the adapter-contract wire code (when the
    /// gateway sent one) plus whether the FAILED request actually carried
    /// historical image parts (recorded at dispatch time; a render-time thread
    /// scan would over-claim because the image-history policy can demote
    /// stored images to file references). NEVER raw server text.
    struct TurnFailureClassification: Sendable {
        let failureCode: Int?
        let wireCode: String?
        let hadHistoryImages: Bool?

        init(failureCode: Int?, wireCode: String? = nil, hadHistoryImages: Bool? = nil) {
            self.failureCode = failureCode
            self.wireCode = wireCode
            self.hadHistoryImages = hadHistoryImages
        }
    }

    /// ATOMIC failed-turn transition. One save covers status +
    /// classification, with an explicit upgrade rule so the racing writers
    /// (iOS background delegate vs foreground VM; macOS VM vs share drainer)
    /// converge on the richest classification regardless of order:
    ///
    /// - `sending` → `failed` + classification written (nils allowed — a
    ///   generic failure IS the classification) + a fresh delivery attempt
    ///   identity.
    /// - already `failed` with NO stored `failureCode` + incoming has one →
    ///   metadata upgraded in place (status untouched) + a fresh delivery
    ///   attempt identity. This is the delegate-lost-the-race case: a plain
    ///   `failed` write landed first, the coded write still must not be
    ///   dropped. The re-mint on an ALREADY-failed row is deliberate and is
    ///   argued at `applyFailure`.
    /// - anything else → no-op (a resolved turn is never disturbed — same
    ///   posture as `markPendingUserTurn`), and a no-op mints nothing.
    ///
    /// `role == "user"` guard mirrors the other send-state writers.
    /// Non-throwing best-effort: failure writers run on cleanup paths.
    ///
    /// `attempt` joins the gateway-attempt terminalization to the SAME save, on
    /// the same fail-open terms as `completeAgentTurn`: if the combined save
    /// fails, the classification is written again alone in a fresh context and
    /// only then is the measurement retried best-effort. A failed turn is still
    /// a turn the user has to be able to retry, so the ledger never gets to keep
    /// the Retry chip from appearing.
    func failTurn(
        messageID: UUID,
        classification: TurnFailureClassification?,
        attempt: TerminalAttemptObservation? = nil
    ) async {
        do { try await ensureLoaded() } catch { return }

        guard let attempt, let attemptID = attempt.attemptID else {
            await applyTurnFailure(messageID: messageID, classification: classification, attempt: nil)
            return
        }
        // Losing the claim drops the measurement, never the classification —
        // see `completeAgentTurn`.
        guard terminalClaims.insert(attemptID).inserted else {
            await applyTurnFailure(messageID: messageID, classification: classification, attempt: nil)
            return
        }
        defer { terminalClaims.remove(attemptID) }

        let saved = await applyTurnFailure(
            messageID: messageID, classification: classification, attempt: attempt
        )
        guard !saved else { return }
        await applyTurnFailure(messageID: messageID, classification: classification, attempt: nil)
        await writeTerminalObservation(attempt)
    }

    /// One pass of the failed-turn transition. Returns whether the pass got as
    /// far as a committed store — TRUE when it saved AND when it found nothing
    /// to write, since neither is a defect the caller can repair by retrying;
    /// FALSE only when a save actually threw, which is the fail-open trigger.
    @discardableResult
    private func applyTurnFailure(
        messageID: UUID,
        classification: TurnFailureClassification?,
        attempt: TerminalAttemptObservation?
    ) async -> Bool {
        let context = newWriteContext()
        #if DEBUG
        let injectedSaveFailure = debugFailsAttemptBearingSaves && attempt != nil
        #endif
        let pass: (changed: Bool, saved: Bool) = await context.perform { [context] in
            var changed = false
            let request = NSFetchRequest<NSManagedObject>(entityName: "Message")
            request.predicate = NSPredicate(
                format: "id == %@ AND role == %@", messageID as CVarArg, "user"
            )
            request.fetchLimit = 1
            if let message = (try? context.fetch(request))?.first,
               Self.applyFailure(classification, to: message) {
                changed = true
            }
            if let attempt, let attemptID = attempt.attemptID,
               let row = Self.gatewayAttemptRow(id: attemptID, in: context),
               Self.applyTerminalObservation(attempt, to: row) {
                changed = true
            }
            guard changed else { return (false, true) }
            #if DEBUG
            if injectedSaveFailure { return (false, false) }
            #endif
            do { try context.save() } catch { return (false, false) }
            return (true, true)
        }
        if pass.changed { await postDidChange() }
        return pass.saved
    }

    /// Conversation-wide variant of `failTurn` for callers without the exact
    /// message id (legacy background blobs): applies the transition to every
    /// still-`sending` user turn. Scoped to `sending` ONLY (mirrors
    /// `markPendingUserTurns`) — the metadata-upgrade branch is reserved for
    /// the exact-id writer; a wide writer running it would stamp this
    /// failure's classification onto OLD unrelated failed turns in the same
    /// conversation (a network-failed turn suddenly reading "Photo declined").
    func failPendingUserTurns(conversationID: UUID, classification: TurnFailureClassification?) async {
        do { try await ensureLoaded() } catch { return }
        let context = newWriteContext()
        let changed: Bool = await context.perform { [context] in
            let request = NSFetchRequest<NSManagedObject>(entityName: "Message")
            request.predicate = NSPredicate(
                format: "conversation.id == %@ AND role == %@ AND status == %@",
                conversationID as CVarArg, "user", "sending"
            )
            let candidates = (try? context.fetch(request)) ?? []
            var any = false
            for message in candidates where Self.applyFailure(classification, to: message) {
                any = true
            }
            guard any else { return false }
            try? context.save()
            return true
        }
        if changed { await postDidChange() }
    }

    /// The `failTurn` transition rule against one managed object. Returns
    /// whether anything was written. Upgrade = RICHEST WINS: an already-failed
    /// row accepts the incoming classification when it adds information the
    /// stored one lacks — a coded write over a code-less row, or a WIRE-coded
    /// write over a row whose stored classification has no wire code (the
    /// generic-first race: a foreground `unreachable` landing before the
    /// delegate's body-classified `image_unsupported` must not pin the row on
    /// hedged copy). Equal-or-poorer incoming → no-op.
    ///
    /// BOTH WRITING BRANCHES MINT a fresh `deliveryAttemptID`
    /// (`mintDeliveryAttemptID`); the no-op branch mints nothing. Returning
    /// false is therefore load-bearing beyond saving a write — it is what keeps
    /// an unchanging classification from relighting a retired mark.
    private static func applyFailure(
        _ classification: TurnFailureClassification?,
        to message: NSManagedObject
    ) -> Bool {
        let status = message.value(forKey: "status") as? String
        if status == "sending" {
            message.setValue("failed", forKey: "status")
            // This writer is DECLARING the failure, so it stamps a fresh
            // identity over whatever the row was carrying — see
            // `mintDeliveryAttemptID` for why preserving one is the defect
            // rather than the safeguard.
            mintDeliveryAttemptID(on: message)
            message.setValue(classification?.failureCode.map { NSNumber(value: $0) }, forKey: "failureCode")
            message.setValue(classification?.wireCode, forKey: "failureWireCode")
            message.setValue(classification?.hadHistoryImages.map { NSNumber(value: $0) }, forKey: "failureHadHistoryImages")
            return true
        }
        if status == "failed", let classification {
            let storedCodeMissing = message.value(forKey: "failureCode") == nil
            let storedWireMissing = message.value(forKey: "failureWireCode") == nil
            let upgrades = (storedCodeMissing && classification.failureCode != nil)
                || (storedWireMissing && classification.wireCode != nil)
            // An upgrade that upgrades nothing is not a write at all: no save,
            // no export, and above all no mint.
            guard upgrades else { return false }
            message.setValue(classification.failureCode.map { NSNumber(value: $0) }, forKey: "failureCode")
            message.setValue(classification.wireCode, forKey: "failureWireCode")
            message.setValue(classification.hadHistoryImages.map { NSNumber(value: $0) }, forKey: "failureHadHistoryImages")
            // A REAL upgrade mints too, and this is the counter-intuitive half
            // of the rule: the row is already `failed`, nothing new failed, and
            // the mark may already have been retired — yet leaving the identity
            // alone here reopens exactly the ABA the sweep case does. A device
            // that went offline holding the OLD, code-less copy of attempt A1
            // comes back, upgrades ITS row, and exports `failed`/A1 after the
            // fleet has already settled on `failed`/A2 from a retry it never
            // saw; against a standing acknowledgement of A1 that message goes
            // silent forever, and `failed` is terminal so nothing writes it
            // again. Re-minting makes the straggler's export name an attempt
            // nothing acknowledges, so the mark survives whichever record wins.
            mintDeliveryAttemptID(on: message)
            return true
        }
        return false
    }

    /// ATOMIC retry claim: compare-and-set `failed` → `sending` on one
    /// user turn. Returns false when the turn is not currently `failed` —
    /// i.e. a concurrent "Try again" / "Resend without photo" already claimed
    /// it (fail-fast: the loser aborts, never a double dispatch). KEEPS the
    /// stored classification (frozen rule: cleared only on success — see
    /// `applySendState`).
    ///
    /// MINTS A NEW `deliveryAttemptID` in the same compare-and-set, because
    /// this IS a new delivery attempt, and it deliberately does NOT touch the
    /// conversation's `failureSeenAttemptID`. That asymmetry is the whole
    /// design: there is no destructive clear anywhere in it. The stored
    /// acknowledgement stays exactly where it is and simply stops matching, so
    /// if this attempt fails too the mark re-arms by itself. Clearing instead
    /// would put back the entire class of bug the identity scheme exists to
    /// kill — a stale clear landing after a later acknowledgement, or a stale
    /// acknowledgement landing after a clear, silencing a live failure with no
    /// way for the user to get the mark back.
    func beginRetry(messageID: UUID) async -> Bool {
        guard retryClaims.insert(messageID).inserted else { return false }
        defer { retryClaims.remove(messageID) }

        do { try await ensureLoaded() } catch { return false }
        let context = newWriteContext()
        let claimed: Bool = await context.perform { [context] in
            let request = NSFetchRequest<NSManagedObject>(entityName: "Message")
            request.predicate = NSPredicate(
                format: "id == %@ AND role == %@ AND status == %@",
                messageID as CVarArg, "user", "failed"
            )
            request.fetchLimit = 1
            guard let message = (try? context.fetch(request))?.first else { return false }
            message.setValue("sending", forKey: "status")
            // New attempt, new identity — see the header. Nothing preserves the
            // old one: the acknowledgement that named it is now an
            // acknowledgement of an attempt this row no longer reports, which
            // is exactly how asking again re-arms the mark without any writer
            // having to clear anything. Routed through the shared mint so the
            // one rule — a fresh identity whenever this row's delivery story
            // materially moves — lives at a single site.
            Self.mintDeliveryAttemptID(on: message)
            try? context.save()
            return true
        }
        if claimed { await postDidChange() }
        return claimed
    }

    /// Persist the compatibility-mode flag ("Keep chatting without
    /// photos") on one conversation. Written BEFORE the next dispatch so the
    /// banner is visible before any substituted send.
    func setHideEarlierPhotos(conversationID: UUID, _ enabled: Bool) async {
        do { try await ensureLoaded() } catch { return }
        let context = newWriteContext()
        await context.perform { [context] in
            let request = NSFetchRequest<NSManagedObject>(entityName: "Conversation")
            request.predicate = NSPredicate(format: "id == %@", conversationID as CVarArg)
            request.fetchLimit = 1
            guard let conversation = (try? context.fetch(request))?.first else { return }
            conversation.setValue(enabled, forKey: "hideEarlierPhotos")
            try? context.save()
        }
        await postDidChange()
    }

    // MARK: - Account-wide attention markers
    //
    // The three writes below are what makes "I have already seen this" a fact
    // about the ACCOUNT instead of about one device: `lastViewedAt` and
    // `failureSeenAttemptID` are mirrored columns, so reading a thread on the
    // iPad retires its mark on the phone, the Mac and the wrist.
    //
    // ALL OF THEM ARE BEST-EFFORT AND NON-THROWING. A marker write happens
    // because the user opened a thread, and nothing about opening a thread may
    // fail on a store that will not load — the surface has already drawn.
    // `ReadStateStore`'s optimistic overlay carries the intent locally in the
    // meantime and the legacy fallback carries it across a relaunch, so a
    // dropped write costs a repeat stamp, never a lost read.
    //
    // EVERY ONE OF THEM SAVES AND POSTS ONLY WHEN A VALUE ACTUALLY MOVED. See
    // the file header: a write that always looks like a change is a local
    // refetch loop and a CKRecord export per turn, and a thread left open across
    // a long conversation re-stamps on every tail.

    /// Record that the account has looked at this conversation, as of `date`.
    ///
    /// MONOTONE AGAINST THE STORED VALUE, and against the STORED one rather than
    /// against any value the caller happens to hold — that is the point. The
    /// column is last-writer-wins across devices, so a marker that could move
    /// BACKWARD would let a delayed write carrying an older view time re-bold a
    /// thread that was read somewhere else. Comparing inside the transaction
    /// that writes makes moving backward unrepresentable on this device, which
    /// is as far as a record-level LWW field can be defended (the residual
    /// cross-device case is an accepted, self-repairing imperfection: it can
    /// only ever show one extra mark, never hide a reply).
    ///
    /// An equal stamp is NOT a move. A thread open across many landing tails
    /// re-stamps the same clamped value, and exporting a CKRecord for each of
    /// them is the write amplification this rule exists to prevent.
    func markConversationViewed(_ id: UUID, at date: Date) async {
        // NEVER AGAINST THE REAL STORE FROM A TEST HOST — the same seam split
        // `foldLegacyReadMarker` documents at length, and for the same reason.
        // These columns are CloudKit-mirrored, and the Core Data store they land
        // in is one of the storage seam's documented carve-outs: it is the real
        // App-Group sqlite with the mirror attached on every non-simulator
        // build. A signed macOS or on-device suite run reaching this through
        // `ReadStateStore.shared` — which every visibility seam does — would
        // stamp view markers onto the founder's own conversations and export
        // them to their private CloudKit zone. Gated on the STORE rather than on
        // the test host, so a suite driving an ephemeral
        // `ConversationStore(inMemory:)` still exercises the write.
        #if CONDUCK_TESTING
        guard container.persistentStoreDescriptions.first?.type == NSInMemoryStoreType else {
            return
        }
        #endif
        do { try await ensureLoaded() } catch { return }
        let context = newWriteContext()
        let moved: Bool = await context.perform { [context] in
            guard let conversation = Self.conversation(id: id, in: context) else { return false }
            guard Self.applyViewed(date, to: conversation) else { return false }
            try? context.save()
            return true
        }
        if moved { await postDidChange() }
    }

    /// Record that the account has been shown THIS delivery attempt's failure —
    /// the acknowledgement that retires the red mark on every device.
    ///
    /// `attemptID` is the `Message.deliveryAttemptID` of the failed turn the
    /// surface actually painted, taken from the same `FailedTurnProjection` that
    /// supplied its stamp so the two can never name different turns.
    ///
    /// DELIBERATELY NOT ROUTED THROUGH THE MONOTONE HELPER `markConversationViewed`
    /// USES. An acknowledgement is an IDENTITY, and identities have no order:
    /// there is no "later" UUID, and the newest attempt is not the largest one.
    /// The stored value is simply replaced, and it is replaced with the id the
    /// caller drew rather than with anything re-read here — a failure that
    /// imported seconds before the tap must not be acknowledged without ever
    /// having been on screen. Nothing needs clearing on retry either: a new
    /// attempt mints a new id and the stored acknowledgement stops matching by
    /// itself.
    ///
    /// NO TIMESTAMP is written, and this method deliberately does not also mark
    /// the conversation viewed. The two markers answer different questions and
    /// one is not evidence of the other; a surface that means both says so, via
    /// `markConversationViewedAndAcknowledged`.
    func acknowledgeConversationFailure(_ id: UUID, attemptID: UUID) async {
        // NEVER AGAINST THE REAL STORE FROM A TEST HOST — the same seam split
        // `foldLegacyReadMarker` documents at length, and for the same reason.
        // These columns are CloudKit-mirrored, and the Core Data store they land
        // in is one of the storage seam's documented carve-outs: it is the real
        // App-Group sqlite with the mirror attached on every non-simulator
        // build. A signed macOS or on-device suite run reaching this through
        // `ReadStateStore.shared` — which every visibility seam does — would
        // stamp view markers onto the founder's own conversations and export
        // them to their private CloudKit zone. Gated on the STORE rather than on
        // the test host, so a suite driving an ephemeral
        // `ConversationStore(inMemory:)` still exercises the write.
        #if CONDUCK_TESTING
        guard container.persistentStoreDescriptions.first?.type == NSInMemoryStoreType else {
            return
        }
        #endif
        do { try await ensureLoaded() } catch { return }
        let context = newWriteContext()
        let moved: Bool = await context.perform { [context] in
            guard let conversation = Self.conversation(id: id, in: context) else { return false }
            guard Self.applyAcknowledgement(attemptID, to: conversation) else { return false }
            try? context.save()
            return true
        }
        if moved { await postDidChange() }
    }

    /// Both markers in ONE transaction, for a surface where a single user action
    /// means both things at once.
    ///
    /// The macOS menu bar is that surface: clicking a row opens the thread AND
    /// dismisses its failure, one click, one intent. Calling the two methods
    /// above in sequence would produce two saves, two `.conversationsDidChange`
    /// posts and two CKRecord exports per opening, and would let a reload land
    /// between them and paint the row half-updated — viewed but still red, or
    /// the reverse.
    ///
    /// A NIL `attemptID` MARKS VIEWED AND ACKNOWLEDGES NOTHING. It is not a
    /// clear and not a wildcard: nil means the row had no failure to
    /// acknowledge, or one carrying no attempt identity, and writing nil into
    /// the column would ERASE an acknowledgement another device made — relighting
    /// the mark everywhere because someone opened a conversation.
    func markConversationViewedAndAcknowledged(_ id: UUID, at date: Date, attemptID: UUID?) async {
        // NEVER AGAINST THE REAL STORE FROM A TEST HOST — the same seam split
        // `foldLegacyReadMarker` documents at length, and for the same reason.
        // These columns are CloudKit-mirrored, and the Core Data store they land
        // in is one of the storage seam's documented carve-outs: it is the real
        // App-Group sqlite with the mirror attached on every non-simulator
        // build. A signed macOS or on-device suite run reaching this through
        // `ReadStateStore.shared` — which every visibility seam does — would
        // stamp view markers onto the founder's own conversations and export
        // them to their private CloudKit zone. Gated on the STORE rather than on
        // the test host, so a suite driving an ephemeral
        // `ConversationStore(inMemory:)` still exercises the write.
        #if CONDUCK_TESTING
        guard container.persistentStoreDescriptions.first?.type == NSInMemoryStoreType else {
            return
        }
        #endif
        do { try await ensureLoaded() } catch { return }
        let context = newWriteContext()
        let moved: Bool = await context.perform { [context] in
            guard let conversation = Self.conversation(id: id, in: context) else { return false }
            // Both are evaluated, never short-circuited: an acknowledgement must
            // land even when the view marker did not move (the user has seen
            // this failure either way), and the view marker must move even when
            // the acknowledgement is a no-op repeat.
            var changed = Self.applyViewed(date, to: conversation)
            if let attemptID, Self.applyAcknowledgement(attemptID, to: conversation) {
                changed = true
            }
            guard changed else { return false }
            try? context.save()
            return true
        }
        if moved { await postDidChange() }
    }

    /// Fold ONE conversation's legacy device-local read marker into its record,
    /// and SAY WHAT HAPPENED so the caller can delete that defaults key only on a
    /// confirmed cover.
    ///
    /// THE RETURN VALUE IS THE WHOLE POINT. The legacy key is a durable read-side
    /// fallback, not a migration input: while it exists it keeps answering reads,
    /// so nothing goes bold in the gap. A fire-and-forget call followed by an
    /// unconditional key deletion would drop the marker on the floor every time
    /// the record was not actually present or the save did not commit — and a
    /// lost read marker is not recoverable from anywhere, on any device. See
    /// `ReadMarkerFoldOutcome`.
    ///
    /// A MISSING CONVERSATION IS `.failed`, NOT `.alreadyCovered`. Absence from
    /// a fetch is not proof of deletion: the initial CloudKit import is
    /// asynchronous and an offline launch reads a partial local mirror, so the
    /// conversation this key belongs to may simply not have arrived yet. That is
    /// exactly the case a one-shot migration with a done-flag gets wrong, and
    /// keeping the key is how this design avoids it.
    ///
    /// Only the READ marker folds. Legacy failure acknowledgements are
    /// deliberately never migrated — a stale fold can silence a failure that
    /// re-occurred after the upgrade, and the safe direction is one extra red
    /// mark rather than a hidden one.
    func foldLegacyReadMarker(_ id: UUID, localMarker: Date) async -> ReadMarkerFoldOutcome {
        // NEVER AGAINST THE REAL STORE FROM A TEST HOST — the same seam split
        // `backfillTitleSnippetsIfNeeded` documents at length, and for the same
        // reason. The legacy markers live behind the storage seam (in-memory
        // doubles under `CONDUCK_TESTING`), the Core Data store they fold INTO
        // is one of the seam's documented carve-outs and is real, with the
        // CloudKit mirror attached on every non-simulator build. A signed macOS
        // or on-device suite run would therefore write view markers into the
        // founder's actual conversations and export them to their private
        // CloudKit zone. Gated on the STORE rather than on the test host, so a
        // suite driving an ephemeral `ConversationStore(inMemory:)` still
        // exercises the fold. `.failed` rather than `.alreadyCovered` because
        // nothing was covered: the caller keeps its key, which is the safe
        // direction in the one configuration where this cannot run.
        #if CONDUCK_TESTING
        guard container.persistentStoreDescriptions.first?.type == NSInMemoryStoreType else {
            return .failed
        }
        #endif
        do { try await ensureLoaded() } catch { return .failed }
        let context = newWriteContext()
        // The result is returned WITHOUT a `postDidChange()`, deliberately. The
        // value this commits is one the read path was ALREADY answering with,
        // and the caller keeps answering with it: `ReadStateStore.completeFold`
        // moves the marker from its legacy map into its overlay rather than
        // dropping it, so the same `max` produces the same answer and nothing on
        // this device renders differently. That handoff is what makes the
        // silence here correct — without it this method would be committing a
        // value only the record knows about, while the caller retired the only
        // copy the rendering list could see. Posting would instead fan a
        // whole-list refetch per folded key, and the first launch after the
        // upgrade folds them in batches. The other devices learn about it the
        // way they learn about every column: through the mirror.
        //
        // The save is `try`/`catch` rather than `try?` because the CALLER acts
        // on the answer: a dropped save reported as `.saved` deletes the only
        // remaining copy of that marker.
        return await context.perform { [context] in
            guard let conversation = Self.conversation(id: id, in: context) else { return .failed }
            guard Self.applyViewed(localMarker, to: conversation) else { return .alreadyCovered }
            do {
                try context.save()
            } catch {
                return .failed
            }
            return .saved
        }
    }

    /// Rewrite ONE conversation's stale tail envelope from its real tail, and
    /// canonicalise the pair of stamps that envelope is validated against.
    ///
    /// WHY A REPAIR EXISTS. A stale envelope is not self-healing: iOS and macOS
    /// fall back to a lazy per-row tail fetch and carry on, so nothing on those
    /// surfaces ever notices again — but the wrist has no fallback, and a single
    /// append by an older build (or by any writer that missed the projection)
    /// would leave that conversation permanently mark-less on the Watch. The
    /// repair is what closes that, and it costs one bounded write.
    ///
    /// WHY IT ALSO WRITES THE TWO STAMPS. This is the ONE path that describes a
    /// tail it did not write, so it is the one path that can be handed an
    /// instant sitting at an arbitrary offset inside its millisecond — a row an
    /// older build stamped from a bare `Date()`, which is every row that
    /// predates `TailProjection.canonical`. A non-canonical instant is precisely
    /// the value CloudKit's millisecond DATE field is free to quantise in a
    /// direction Apple does not document, so two devices holding two
    /// quantisations of one such stamp would compute envelopes a millisecond
    /// apart, each read the other's as stale, and rewrite it on every launch for
    /// as long as that conversation gets no new turn. Snapping the tail's
    /// `createdAt` and the conversation's `lastActivityAt` onto the same
    /// canonical `Date` — the value both quantisations agree about — is what
    /// makes the row converge instead. BOTH or neither: the resolver's failed
    /// arm bounds a terminal failure by `createdAt >= lastActivityAt` and relies
    /// on the tail comparing EQUAL, so moving one half by a fraction of a
    /// millisecond and not the other would silently retire a red mark for a
    /// message that never sent. For every row this build wrote it is a no-op —
    /// the stamps are already canonical — so the write is a one-time migration,
    /// not a recurring cost.
    ///
    /// IT CANNOT LOOP, by three independent constructions:
    ///   - one attempt per conversation per process (`tailProjectionRepairsAttempted`),
    ///     so a row that can never hold a valid envelope is tried once, not on
    ///     every reload;
    ///   - it saves only when something actually changes — a repair that
    ///     computes the string already stored and finds both stamps already
    ///     canonical writes nothing;
    ///   - it posts NO change notification. That is the important one: posting
    ///     would reload the lists, the reload would re-read the envelope, and a
    ///     row that still could not be made valid would ask for a repair again.
    ///     Nothing on this device is waiting for the result either — the surface
    ///     that noticed the staleness already has the tail role from its own
    ///     fallback fetch. The repair is for the devices that cannot fetch.
    ///
    /// THE SNAP IS BOUNDED BY THE MESSAGE BEHIND THE TAIL. Rounding to nearest
    /// can move a stamp EARLIER, and `Message.createdAt` is the only order a
    /// thread has, so on a legacy pair sharing one millisecond an unbounded snap
    /// could put the newest turn behind the one it answered. The repair reads
    /// two rows rather than one and declines outright when the move would cross
    /// the second — a row it cannot improve is left exactly as it is.
    ///
    /// REWRITING A FAILED USER TURN MINTS A FRESH DELIVERY ATTEMPT IDENTITY.
    /// This is the only writer in the file that materially updates a `Message`
    /// row it did not author, and under the record-level last-writer-wins that
    /// `Message` rows converge by, that save republishes the whole row — including
    /// a `status`/`deliveryAttemptID` pair this device may hold from before a
    /// retry it has not imported yet. Republishing a failure declaration IS a
    /// declaration as far as every other device is concerned, so it takes the
    /// same rule every other one does: see `mintDeliveryAttemptID`.
    ///
    /// A `.unreadableVersion` envelope is left ALONE — see `TailProjectionReading`:
    /// rewriting a newer build's value starts a downgrade fight across the
    /// mirror. A conversation whose real tail cannot produce a VALID envelope
    /// (its `createdAt` no longer names the same millisecond as `lastActivityAt`,
    /// which means a message is missing locally rather than that the string is
    /// wrong) is likewise left alone, stamps included: an envelope that is stale
    /// by construction is worse than the one already there, because it exports.
    ///
    /// Returns whether anything was written — for tests and diagnostics; every
    /// production caller can ignore it.
    @discardableResult
    func repairTailProjection(conversationID: UUID) async -> Bool {
        // NEVER AGAINST THE REAL STORE FROM A TEST HOST — the same seam split
        // `markConversationViewed` and `foldLegacyReadMarker` document, and this
        // path needs it MORE than they do: they move one attention column, while
        // this rewrites `Message.createdAt` and `Conversation.lastActivityAt`
        // and exports both records. `ConversationStore`'s App-Group sqlite is a
        // documented storage-seam carve-out — the real shared container, with
        // the CloudKit mirror attached on every non-simulator build — and this
        // is reachable from a test host through
        // `ConversationListViewModel.scheduleTailProjectionRepairs`, which
        // reaches `ConversationStore.shared`. Gated on the STORE rather than on
        // the test host, so a suite driving an ephemeral
        // `ConversationStore(inMemory:)` still exercises the repair. BEFORE the
        // memo, so a refused call does not also burn this conversation's one
        // attempt for the process.
        #if CONDUCK_TESTING
        guard container.persistentStoreDescriptions.first?.type == NSInMemoryStoreType else {
            return false
        }
        #endif
        guard !tailProjectionRepairsAttempted.contains(conversationID) else { return false }
        tailProjectionRepairsAttempted.insert(conversationID)
        do { try await ensureLoaded() } catch { return false }
        let context = newWriteContext()
        return await context.perform { [context] in
            guard let conversation = Self.conversation(id: conversationID, in: context),
                  let lastActivityAt = conversation.value(forKey: "lastActivityAt") as? Date else {
                return false
            }
            let stored = conversation.value(forKey: "tailProjection") as? String
            guard TailProjection.read(stored, lastActivityAt: lastActivityAt).isRepairable else {
                return false
            }

            // The real tail, and the message behind it — two rows, because the
            // snap below must not be allowed to cross the second one.
            //
            // THE `id` TIE-BREAK IS LOAD-BEARING NOW THAT STAMPS ARE QUANTISED.
            // Two turns written into one conversation inside the same
            // millisecond carry the SAME `createdAt`, so `createdAt` alone no
            // longer picks a row — fetch order would, and fetch order is not
            // stable across two fetches on one device, let alone across devices.
            // The envelope names ONE message id, so an unstable pick means two
            // devices writing two different envelopes at each other forever.
            // DESCENDING on the id, which is the same end of a tie as
            // `FailedTurnProjection.isNewer` (stamp, then the LARGER id), as
            // `fetchConversationTail` — the per-row fallback this envelope
            // stands in for on iOS and macOS — and as `fetchMessages`, whose
            // `last` element the thread acknowledges failures off. Four sites,
            // one order; see `TailProjection`'s header.
            let request = NSFetchRequest<NSManagedObject>(entityName: "Message")
            request.predicate = NSPredicate(
                format: "conversation.id == %@", conversationID as CVarArg
            )
            request.sortDescriptors = [
                NSSortDescriptor(key: "createdAt", ascending: false),
                NSSortDescriptor(key: "id", ascending: false)
            ]
            request.fetchLimit = 2
            let newest = (try? context.fetch(request)) ?? []
            let tail = newest.first
            let predecessorStamp = newest.dropFirst().first?
                .value(forKey: "createdAt") as? Date

            // Set only on the branch that is going to write an envelope: the
            // canonical `Date` for the millisecond this conversation's tail
            // names, which both stamps are then snapped onto.
            var canonicalStamp: Date?
            let repaired: String? = {
                // No messages at all — the correct envelope is no envelope, and
                // writing it clears a string that was describing a tail this
                // conversation does not have.
                guard let tail else { return nil }
                guard let messageID = tail.value(forKey: "id") as? UUID,
                      let createdAt = tail.value(forKey: "createdAt") as? Date,
                      TailProjection.milliseconds(from: createdAt)
                        == TailProjection.milliseconds(from: lastActivityAt),
                      let encoded = TailProjection.encoded(
                          messageID: messageID,
                          createdAt: createdAt,
                          role: tail.value(forKey: "role") as? String
                      )
                else { return stored }
                let candidate = TailProjection.canonical(createdAt)
                // THE SNAP MUST NOT REORDER THE THREAD. Rounding to nearest can
                // move the tail EARLIER, and `Message.createdAt` is the only
                // order a thread has, so a legacy pair sharing one millisecond
                // could land the newest turn behind the message it answered:
                // the thread would render the user's own turn above the reply
                // that preceded it, `fetchConversationTail` would return the
                // other row while this envelope named this one, and
                // `lastActivityAt` would sit behind its own newest message.
                // Leaving such a row entirely alone is the honest answer — it
                // keeps the imperfection it already has instead of adding a
                // worse one — and it costs only the wrist's mark on a row that
                // no build of this app could have written.
                //
                // Only a DOWNWARD snap can cross anything, so a row whose stamp
                // is already canonical is accepted without consulting the
                // neighbour at all — including one that legitimately shares the
                // tail's millisecond, which two devices settling one
                // millisecond independently can produce and which the `id`
                // tie-break already orders.
                let crossesPredecessor = candidate != createdAt
                    && (predecessorStamp.map { candidate <= $0 } ?? false)
                guard !crossesPredecessor else { return stored }
                canonicalStamp = candidate
                return encoded
            }()

            var changed = false
            if let canonicalStamp, let tail {
                // Both halves or neither — see the header. Guarded on exact
                // inequality rather than written unconditionally so a row this
                // build already stamped stays a pure envelope repair and exports
                // one record instead of two.
                if tail.value(forKey: "createdAt") as? Date != canonicalStamp {
                    tail.setValue(canonicalStamp, forKey: "createdAt")
                    // REWRITING A FAILED TURN REPUBLISHES ITS FAILURE, so it
                    // mints — see `mintDeliveryAttemptID`. `Message` rows
                    // converge under record-level last-writer-wins, so this
                    // save exports the whole row, `status` and
                    // `deliveryAttemptID` included, from whatever values this
                    // device happens to hold. On a device that has not yet
                    // imported a retry made elsewhere those are the PREVIOUS
                    // attempt's, and republishing them against a standing
                    // acknowledgement of that attempt would clear the mark for
                    // a message that never sent — the exact ABA the mint rule
                    // exists to close. A fresh identity makes the export
                    // self-defeating instead: no acknowledgement can name it,
                    // so the mark stands. The cost is the direction this app
                    // always takes — one already-retired mark can come back and
                    // cost a tap, once, on a row whose stamps predate
                    // `TailProjection.canonical`.
                    if tail.value(forKey: "role") as? String == "user",
                       tail.value(forKey: "status") as? String == "failed" {
                        Self.mintDeliveryAttemptID(on: tail)
                    }
                    changed = true
                }
                if lastActivityAt != canonicalStamp {
                    conversation.setValue(canonicalStamp, forKey: "lastActivityAt")
                    changed = true
                }
            }
            if repaired != stored {
                conversation.setValue(repaired, forKey: "tailProjection")
                changed = true
            }

            guard changed else { return false }
            try? context.save()
            return true
        }
    }

    #if CONDUCK_TESTING
    /// TEST SEAM — overwrite one conversation's stored tail envelope directly.
    ///
    /// WHY IT HAS TO EXIST. Every production writer of `tailProjection` writes it
    /// in the SAME transaction that bumps `lastActivityAt`, from one `now`, which
    /// is precisely the invariant that makes a stale envelope impossible to
    /// produce through the public API. So the one state `repairTailProjection`
    /// exists for — a well-formed envelope describing a tail this conversation
    /// has moved past, written by a build that did not know about the column —
    /// is unreachable from a test without a seam, and the repair's WRITE branch
    /// would go permanently unobserved: a suite could delete the whole repair
    /// and stay green while the wrist lost its marks on every mixed-fleet row.
    ///
    /// Compiled only under `CONDUCK_TESTING`, and gated on the in-memory store
    /// for the same reason the marker writers are: nothing here may reach the
    /// founder's real conversations from a signed suite run.
    func _setTailProjectionForTesting(_ value: String?, conversationID: UUID) async {
        guard container.persistentStoreDescriptions.first?.type == NSInMemoryStoreType else {
            return
        }
        do { try await ensureLoaded() } catch { return }
        let context = newWriteContext()
        await context.perform { [context] in
            guard let conversation = Self.conversation(id: conversationID, in: context) else { return }
            conversation.setValue(value, forKey: "tailProjection")
            try? context.save()
        }
    }

    /// TEST SEAM — put a conversation's activity stamp and its tail's
    /// `createdAt` at an arbitrary instant, ignoring the quantisation every
    /// production writer applies.
    ///
    /// WHY IT HAS TO EXIST, and it is the same argument as the seam above. A row
    /// whose stamps sit at an offset INSIDE their millisecond is precisely what
    /// `repairTailProjection`'s canonicalising branch exists for — it is every
    /// row written before `TailProjection.canonical` did, which is a user's
    /// entire existing history — and no public API can produce one, because
    /// every writer snaps first. Without a seam that branch is unreachable from
    /// a test: it could be deleted, or write one stamp and not the other, and
    /// both suites would stay green while every legacy conversation lost its
    /// mark on the wrist and every legacy failure lost its red mark everywhere.
    ///
    /// Writes those columns and NOTHING else — in particular it does not touch
    /// `tailProjection`, so a caller composes it with the seam above to build
    /// the exact pre-upgrade shape: a non-canonical pair and no envelope.
    ///
    /// `newestFirst` is applied to the conversation's messages in the same total
    /// order the repair picks them by — index 0 is the tail, index 1 the message
    /// behind it — so a caller can also build the one pair the repair has to
    /// REFUSE: two turns inside one millisecond whose tail rounds down past its
    /// own predecessor.
    ///
    /// Compiled only under `CONDUCK_TESTING`, and gated on the in-memory store
    /// for the same reason every other writer here is.
    func _setStampsForTesting(
        conversationID: UUID,
        lastActivityAt: Date,
        newestFirst: [Date]
    ) async {
        guard container.persistentStoreDescriptions.first?.type == NSInMemoryStoreType else {
            return
        }
        do { try await ensureLoaded() } catch { return }
        let context = newWriteContext()
        await context.perform { [context] in
            guard let conversation = Self.conversation(id: conversationID, in: context) else { return }
            conversation.setValue(lastActivityAt, forKey: "lastActivityAt")
            guard !newestFirst.isEmpty else {
                try? context.save()
                return
            }
            let request = NSFetchRequest<NSManagedObject>(entityName: "Message")
            request.predicate = NSPredicate(
                format: "conversation.id == %@", conversationID as CVarArg
            )
            // The same total order the repair itself uses, so index 0 is the row
            // the repair will pick.
            request.sortDescriptors = [
                NSSortDescriptor(key: "createdAt", ascending: false),
                NSSortDescriptor(key: "id", ascending: false)
            ]
            request.fetchLimit = newestFirst.count
            let rows = (try? context.fetch(request)) ?? []
            for (row, stamp) in zip(rows, newestFirst) {
                row.setValue(stamp, forKey: "createdAt")
            }
            try? context.save()
        }
    }
    #endif

    /// The one conversation row for `id`, or nil. Every marker write starts here,
    /// so the fetch shape (`id == %@`, `fetchLimit 1`) lives once.
    private static func conversation(
        id: UUID,
        in context: NSManagedObjectContext
    ) -> NSManagedObject? {
        let request = NSFetchRequest<NSManagedObject>(entityName: "Conversation")
        request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        request.fetchLimit = 1
        return (try? context.fetch(request))?.first
    }

    /// Move `lastViewedAt` forward to `date`, or report that it did not move.
    ///
    /// The single site the monotone rule lives at, shared by the plain write, the
    /// combined write and the legacy fold — three callers that must not be able
    /// to disagree about what "already seen" means. Returns false for an equal
    /// stamp as well as an older one: equal is not a change, and treating it as
    /// one is what turns a long-open thread into a CKRecord export per tail.
    ///
    /// ONLY EVER WRITES `lastViewedAt`. Never `lastActivityAt` — that column is
    /// what the list sorts on and what the unseen test compares against, so
    /// touching it here would float a thread to the top of the list for being
    /// READ and would silence the very reply the marker is being compared with.
    private static func applyViewed(_ date: Date, to conversation: NSManagedObject) -> Bool {
        if let stored = conversation.value(forKey: "lastViewedAt") as? Date, date <= stored {
            return false
        }
        conversation.setValue(date, forKey: "lastViewedAt")
        return true
    }

    /// Store `attemptID` as the acknowledged failure, or report that it was
    /// already the stored one.
    ///
    /// No ordering and no `max` — see `acknowledgeConversationFailure`. The only
    /// no-op is an exact repeat, which is the common case (a surface re-stamping
    /// the same row) and the one worth not exporting. ONLY EVER WRITES
    /// `failureSeenAttemptID`, for the same reason `applyViewed` writes only its
    /// own column.
    private static func applyAcknowledgement(
        _ attemptID: UUID,
        to conversation: NSManagedObject
    ) -> Bool {
        guard (conversation.value(forKey: "failureSeenAttemptID") as? UUID) != attemptID else {
            return false
        }
        conversation.setValue(attemptID, forKey: "failureSeenAttemptID")
        return true
    }

    /// Launch-time recovery sweep: flip USER turns stuck at `status ==
    /// "sending"` and older than `olderThan` seconds to `failed`, skipping any
    /// conversation in `excludingConversationIDs` (those have a LIVE background
    /// converse task — the delegate will resolve them authoritatively).
    ///
    /// ANSWERED-TURN GUARD: a kill between the reply-append and the user-turn
    /// flip (the background delegate appends the reply FIRST, crash-safety
    /// ordering) leaves a persisted reply above a still-`sending` user turn.
    /// Marking THAT turn `failed` would render a Retry chip under a landed
    /// reply → duplicate send. So a stale `sending` user turn with a LATER
    /// agent message in the same conversation flips to `sent` instead.
    ///
    /// WHY: a force-quit (or a macOS quit mid-foreground-send — macOS has no
    /// background URLSession delegate at all) kills the process before anything
    /// can flip the turn off `sending`, and the Retry chip requires
    /// `status == "failed"` — without this sweep the turn spins forever.
    ///
    /// GRACE WINDOW (`ConversationActivityResolver.staleSendingGrace`,
    /// deliberately conservative — single-sourced there so the WRITE grace and
    /// the list's DISPLAY grace cannot drift apart). THE GRACE IS NOT WHAT
    /// MAKES THIS SWEEP SAFE, and no duration would be: on iOS a turn dispatched
    /// over the background session can outlive any window, because that session
    /// waits for connectivity before it sends and nothing in the app bounds
    /// that wait. What makes the sweep safe is `excludingConversationIDs` — the
    /// live-task set collected from both background sessions immediately before
    /// each pass, which covers every turn whose delegate will still resolve it.
    ///
    /// The grace covers the case the exclusion set CANNOT see: a `sending` row
    /// written by ANOTHER device and arrived via CloudKit, whose in-flight task
    /// is invisible here. It has to exceed that device's own turn duration plus
    /// sync skew by a comfortable margin, and it is chosen for that. The
    /// immediate post-kill case is handled separately by the
    /// resurrected-`.cancelled` mapping in the background delegates.
    ///
    /// A flip to `failed` here DECLARES that failure, so the turn is stamped
    /// with a fresh delivery attempt identity through `applySendState` — even
    /// though the row this sweep is looking at was very often written by a
    /// DIFFERENT device. That is the case the mint rule exists for, and
    /// `mintDeliveryAttemptID` traces it: a sweep on a device that never saw the
    /// retry must not be able to publish the retry's predecessor identity as the
    /// row's final answer. The `sending`-only predicate keeps the sweep from
    /// touching, or re-minting, a turn that is already resolved.
    ///
    /// Non-throwing (best-effort): a launch-time sweep must never block or
    /// fail the launch path. Posts `.conversationsDidChange` only when
    /// something actually flipped.
    func sweepStaleSendingUserTurns(
        olderThan interval: TimeInterval = ConversationActivityResolver.staleSendingGrace,
        excludingConversationIDs: Set<UUID> = []
    ) async {
        do { try await ensureLoaded() } catch { return }
        let cutoff = Date().addingTimeInterval(-interval)
        let context = newWriteContext()
        let flipped: Bool = await context.perform { [context] in
            let request = NSFetchRequest<NSManagedObject>(entityName: "Message")
            request.predicate = NSPredicate(
                format: "role == %@ AND status == %@ AND createdAt < %@",
                "user", "sending", cutoff as NSDate
            )
            let stale = (try? context.fetch(request)) ?? []
            guard !stale.isEmpty else { return false }
            var didFlip = false
            for message in stale {
                let cid = (message.value(forKey: "conversation") as? NSManagedObject)?
                    .value(forKey: "id") as? UUID
                if let cid, excludingConversationIDs.contains(cid) {
                    continue
                }
                // Answered-turn guard (see header): a LATER agent message in
                // the same conversation means the reply landed but the kill
                // beat the status flip — this turn was delivered, mark `sent`.
                let answered: Bool = {
                    guard let cid,
                          let createdAt = message.value(forKey: "createdAt") as? Date else {
                        return false
                    }
                    let replyRequest = NSFetchRequest<NSManagedObject>(entityName: "Message")
                    replyRequest.predicate = NSPredicate(
                        format: "conversation.id == %@ AND role == %@ AND createdAt > %@",
                        cid as CVarArg, "agent", createdAt as NSDate
                    )
                    replyRequest.fetchLimit = 1
                    return ((try? context.count(for: replyRequest)) ?? 0) > 0
                }()
                Self.applySendState(answered ? "sent" : "failed", to: message)
                didFlip = true
            }
            if didFlip { try? context.save() }
            return didFlip
        }
        if flipped { await postDidChange() }
    }

    /// Attach additional drafts to an EXISTING message. Used by the background
    /// reply path's crash-safety ordering: the agent bubble is persisted FIRST
    /// (so a process kill can't lose the reply), and any output files the
    /// (network-probing, hence slow) `FileTransferOutputDetector` confirms are
    /// attached afterwards. Inserts + saves on a background context (same
    /// posture as the attachment branch of `appendMessage`); a missing message
    /// (deleted mid-flight on another device) is a silent no-op.
    func addAttachments(messageID: UUID, attachments: [AttachmentDraft]) async throws {
        guard !attachments.isEmpty else { return }
        try await ensureLoaded()
        let bgContext = newWriteContext()
        try await bgContext.perform { [bgContext] in
            let request = NSFetchRequest<NSManagedObject>(entityName: "Message")
            request.predicate = NSPredicate(format: "id == %@", messageID as CVarArg)
            request.fetchLimit = 1
            guard let message = try bgContext.fetch(request).first else { return }
            let now = Date()
            for draft in attachments {
                let attachment = NSEntityDescription.insertNewObject(
                    forEntityName: "Attachment", into: bgContext
                )
                Self.applyDraft(draft, to: attachment, on: message, id: UUID(), sequence: draft.sequence, at: now)
            }
            try bgContext.save()
        }
        await postDidChange()
    }

    /// Reconcile one retroactive output-scan pass in a SINGLE background-context
    /// save. Each result is one candidate turn: its confirmed output `drafts`
    /// (server references to chip) plus `markScanned` (whether the pass probed
    /// that turn conclusively — every probe returned a definitive verdict). For
    /// each message, inside the ONE save:
    ///   - re-fetch the message + its CURRENT attachments and insert only drafts
    ///     whose `storedKey` is NOT already present — a transaction-local dedupe
    ///     that closes the stale read-modify-write between the caller's pre-probe
    ///     snapshot and now (two devices' near-simultaneous passes can't double-
    ///     insert the same key; CloudKit has no distributed compare-and-set, so
    ///     the render layer still dedupes as belt-and-braces);
    ///   - allocate each inserted attachment's `sequence` continuing AFTER the
    ///     message's current max (the draft's own pass-local sequence is ignored);
    ///   - replace the output-delivery census (`deliveryOutcome`) when the result
    ///     carries one and it differs from the stored one. A nil census — no
    ///     listing was taken — writes nothing at all, so a transient outage can
    ///     never erase a standing refusal;
    ///   - set `outputScanDone = true` when `markScanned`.
    /// Returns whether ANY attachment was INSERTED — that is the caller's gate
    /// for preview enrichment, so it stays strictly about chips. An
    /// outcome-only write therefore returns `false`, which is not a failure.
    ///
    /// Also posts `.agentFilesDidAttachLocally` with a metadata descriptor for
    /// every row it INSERTED (never for a row it skipped as a duplicate, and
    /// never for a bare marker flip). That notification is what feeds the
    /// phone→wrist courier: this is the exact moment a credential-holding device
    /// learns of a file the wrist structurally cannot discover for itself, and
    /// the descriptors are built INSIDE the same transaction that wrote the rows
    /// so they report what was actually persisted — the real clamped `sequence`,
    /// the real `createdAt` — not what the caller proposed.
    ///
    /// Posts `.conversationsDidChange` ONCE, when an attachment was inserted, a
    /// turn's `outputScanDone` actually TRANSITIONED false → true, or a stored
    /// census actually CHANGED. The marker selects a turn INTO the automatic pass
    /// (`retroScanCandidates` requires `outputScanDone == false`), and that pass
    /// runs off each thread's in-memory `messages`. Without the second
    /// condition, a deferred grace-window pass that closes a turn would write
    /// `true` to the store while every mounted thread kept the stale `false` and
    /// went on re-listing a folder already settled, until some unrelated reload
    /// caught up. The post is gated on the TRANSITION, not on `markScanned` — a
    /// re-stamp of an already-true marker changes nothing, so a reload storm
    /// cannot be manufactured by repeatedly reconciling the same turn. The census
    /// is compared before it is written for that same reason, and its encoding is
    /// key-sorted so an identical census really does compare equal.
    func reconcileOutputScan(
        _ results: [OutputScanReconciliation]
    ) async throws -> Bool {
        guard !results.isEmpty else { return false }
        try await ensureLoaded()
        let bgContext = newWriteContext()
        let outcome: (inserted: Bool, changedVisibleState: Bool, descriptors: [AttachedFileDescriptor])
        outcome = try await bgContext.perform { [bgContext] in
            var insertedAny = false
            var changedVisibleState = false
            var descriptors: [AttachedFileDescriptor] = []
            let now = Date()
            for result in results {
                let request = NSFetchRequest<NSManagedObject>(entityName: "Message")
                request.predicate = NSPredicate(format: "id == %@", result.messageID as CVarArg)
                request.fetchLimit = 1
                // A message deleted mid-flight on another device is a silent skip.
                guard let message = try bgContext.fetch(request).first else { continue }
                // Exact-lane compare-and-set: a result obtained from lane A
                // must never mutate a reply persisted for lane B. Ownerless
                // legacy entries are never network-scanned or claimed.
                guard message.value(forKey: "outputScanLaneID") as? String
                    == result.expectedLaneID else {
                    continue
                }

                // Re-read the message's CURRENT attachments inside this save: the
                // present storedKeys (dedupe) + the max sequence (allocation base).
                let existing = (message.value(forKey: "attachments") as? Set<NSManagedObject>) ?? []
                var presentKeys = Set<String>()
                var maxSequence = -1
                for attachment in existing {
                    if let key = attachment.value(forKey: "storedKey") as? String {
                        presentKeys.insert(key)
                    }
                    if let seq = (attachment.value(forKey: "sequence") as? NSNumber)?.intValue {
                        maxSequence = max(maxSequence, seq)
                    }
                }

                // The owning conversation id, read once per message — it is the
                // wrist's routing key for a couriered descriptor (the wrist
                // resolves the thread, not the bare turn). A message with no
                // conversation cannot be couriered; it is still attached to
                // normally, and CloudKit remains its delivery path.
                let conversationID = (message.value(forKey: "conversation") as? NSManagedObject)?
                    .value(forKey: "id") as? UUID

                var nextSequence = maxSequence + 1
                for draft in result.drafts {
                    // Skip a storedKey already present (prior partial success OR a
                    // duplicate within this same pass — presentKeys grows below).
                    if let key = draft.storedKey, presentKeys.contains(key) { continue }
                    let attachment = NSEntityDescription.insertNewObject(
                        forEntityName: "Attachment", into: bgContext
                    )
                    // Sequence continues after the message's existing max — the
                    // draft's pass-local 0-based sequence is deliberately ignored.
                    let attachmentID = UUID()
                    Self.applyDraft(draft, to: attachment, on: message, id: attachmentID, sequence: nextSequence, at: now)
                    // Courier descriptor for exactly what was just written. The
                    // sequence is re-read through the SAME `Int16(clamping:)` the
                    // store applied, so the wrist sorts the overlay row where the
                    // mirrored row will actually land. A draft with no storedKey
                    // is skipped: an unkeyed overlay row could never be matched
                    // against its authoritative copy and so could never retire.
                    if let conversationID, let storedKey = draft.storedKey, !storedKey.isEmpty {
                        descriptors.append(AttachedFileDescriptor(
                            conversationID: conversationID,
                            messageID: result.messageID,
                            attachmentID: attachmentID,
                            storedKey: storedKey,
                            filename: draft.filename,
                            mimeType: draft.mimeType,
                            byteSize: draft.byteSize,
                            sequence: Int(Int16(clamping: nextSequence)),
                            previewKind: draft.previewKind,
                            createdAt: now
                        ))
                    }
                    if let key = draft.storedKey { presentKeys.insert(key) }
                    nextSequence += 1
                    insertedAny = true
                    changedVisibleState = true
                }

                // What this pass observed about entries it did NOT hand over,
                // written under the SAME lane compare-and-set as the chips and in
                // the SAME save: a folder's withheld entries are a fact about the
                // lane that listed it, so a result from lane B must no more be
                // able to state them than to attach a file from them — and a
                // census that landed without the rows it describes, or rows
                // without the census, would be unrecoverable rather than late.
                //
                // NIL IS NOT ZERO, and the row depends on it. A pass that took no
                // listing — an unreadable server, a folder that is not there, the
                // root name search that probes names one at a time — carries nil,
                // and a nil writes NOTHING. Writing zero for those would retire a
                // true standing refusal because someone's server blipped once.
                //
                // Read before write, exactly like the marker below: an unchanged
                // census is not a visible change, and a reload storm must not be
                // manufacturable by reconciling a settled turn repeatedly. That
                // comparison is only sound because `encodedNames` is DOUBLY
                // deterministic — key-sorted objects AND name-sorted entries. A
                // `PROPFIND` returns entries in the server's own directory order,
                // which changes after any unrelated create or unlink in that
                // folder, so without the entry sort an identical census would
                // re-encode differently, write, post a reload and push to
                // CloudKit on every thread open on every device, forever.
                if let outcome = result.deliveryOutcome {
                    let encodedNames = OutputDeliveryOutcome.encodedNames(outcome.typeRefusedEntries)
                    // Clamped BEFORE the comparison, not after. The columns are
                    // Integer 32, so a value that clamped on the way in would
                    // never read back equal to the one it was compared against —
                    // and every later pass would see a "change", write the same
                    // clamped number again, and post a reload. The census cannot
                    // exceed the listing's own entry ceiling, so this only ever
                    // bites a number that is already wrong; it costs nothing to
                    // make that case converge instead of oscillate.
                    let typeCount = Int(Int32(clamping: outcome.typeRefusedCount))
                    let shapeCount = Int(Int32(clamping: outcome.shapeRefusedCount))
                    let shapeOverlong = Int(Int32(clamping: outcome.shapeRefused.overlongCount))
                    let shapeWhitespace = Int(Int32(clamping: outcome.shapeRefused.whitespaceBoundedCount))
                    let undelivered = Int(Int32(clamping: outcome.undeliveredCount))
                    // The remainder's CAUSE, written beside its count and never
                    // apart from it. Nil means the cause is unknown, which is
                    // what a zero remainder and an unattributed one both read
                    // back as — and neither may be read as "a later pass will
                    // deliver these". Without this column the row had to guess
                    // permanence from `outputScanDone`, which also goes true when
                    // a truncated pass simply ages out past
                    // `truncatedScanHorizon`: a folder whose tail is still
                    // deliverable then claims the ceiling was hit and nothing
                    // more will come, under a "Check again" that would in fact
                    // deliver it.
                    let remainderIsRecoverable = outcome.remainder.isRecoverable
                    let storedTypeCount = (message.value(forKey: "outputRefusedTypeCount") as? NSNumber)?.intValue
                    let storedShapeCount = (message.value(forKey: "outputRefusedShapeCount") as? NSNumber)?.intValue
                    let storedShapeOverlong = (message.value(forKey: "outputRefusedShapeOverlongCount") as? NSNumber)?.intValue
                    let storedShapeWhitespace = (message.value(forKey: "outputRefusedShapeWhitespaceCount") as? NSNumber)?.intValue
                    let storedUndelivered = (message.value(forKey: "outputUndeliveredCount") as? NSNumber)?.intValue
                    let storedRecoverable = (message.value(forKey: "outputRemainderIsRecoverable") as? NSNumber)?.boolValue
                    let storedNames = message.value(forKey: "outputRefusedTypeNames") as? String
                    if storedTypeCount != typeCount
                        || storedShapeCount != shapeCount
                        || storedShapeOverlong != shapeOverlong
                        || storedShapeWhitespace != shapeWhitespace
                        || storedUndelivered != undelivered
                        || storedRecoverable != remainderIsRecoverable
                        || storedNames != encodedNames {
                        message.setValue(NSNumber(value: Int32(typeCount)), forKey: "outputRefusedTypeCount")
                        message.setValue(NSNumber(value: Int32(shapeCount)), forKey: "outputRefusedShapeCount")
                        message.setValue(NSNumber(value: Int32(shapeOverlong)), forKey: "outputRefusedShapeOverlongCount")
                        message.setValue(NSNumber(value: Int32(shapeWhitespace)), forKey: "outputRefusedShapeWhitespaceCount")
                        message.setValue(NSNumber(value: Int32(undelivered)), forKey: "outputUndeliveredCount")
                        // `map`, not a bare `NSNumber(value:)`: nil has to reach
                        // the column as nil, because that is the value the read
                        // side turns back into UNKNOWN.
                        message.setValue(
                            remainderIsRecoverable.map { NSNumber(value: $0) },
                            forKey: "outputRemainderIsRecoverable"
                        )
                        message.setValue(encodedNames, forKey: "outputRefusedTypeNames")
                        // A census IS user-visible state — it drives a standing
                        // row — so a census that actually changed has to say so,
                        // or the row appears only on the next unrelated reload.
                        // `insertedAny` is deliberately NOT touched: this method
                        // returns whether a CHIP was inserted, which gates preview
                        // enrichment, and an outcome-only write inserted none.
                        changedVisibleState = true
                    }
                }

                if result.markScanned {
                    // Read before write: only a real false → true transition is
                    // a visible change. Re-stamping an already-closed turn is a
                    // no-op that must not echo a reload.
                    let wasDone = (message.value(forKey: "outputScanDone") as? NSNumber)?.boolValue
                    if wasDone != true {
                        changedVisibleState = true
                    }
                    message.setValue(true, forKey: "outputScanDone")
                }
            }
            try bgContext.save()
            return (insertedAny, changedVisibleState, descriptors)
        }
        if outcome.changedVisibleState { await postDidChange() }
        // Fan out AFTER the save has committed and after the local refresh post,
        // so a courier can never describe a row this device would fail to show.
        if !outcome.descriptors.isEmpty {
            await postAgentFilesDidAttach(outcome.descriptors)
        }
        return outcome.inserted
    }

    /// Apply synced server-reference PREVIEWS onto already-persisted attachment
    /// rows in ONE background-context save (modeled on `reconcileOutputScan`:
    /// per-message fetch, transaction-local). Each patch names a message + a
    /// server-file `storedKey` and the preview payload found for it — a text
    /// preview (`previewData` + `previewKind`) and/or an image `thumbnailData`.
    /// For every server-reference row on that message whose `storedKey` matches,
    /// set ONLY the fields that are currently NIL on the row AND non-nil in the
    /// patch. Never clobber a preview/thumbnail already written: two devices can
    /// enrich the same row concurrently and CloudKit has no distributed
    /// compare-and-set, so the rule is FIRST-WRITER-WINS per field. Saves once;
    /// returns whether ANY field was actually written and posts
    /// `.conversationsDidChange` ONLY then (a no-op patch set must not echo a
    /// reload). PRIVACY: never logs storedKeys / filenames / preview content.
    func applyPreviews(
        _ patches: [(messageID: UUID, storedKey: String, previewData: Data?, previewKind: String?, thumbnailData: Data?)]
    ) async throws -> Bool {
        guard !patches.isEmpty else { return false }
        try await ensureLoaded()
        let bgContext = newWriteContext()
        let wroteAny: Bool = try await bgContext.perform { [bgContext] in
            var wrote = false
            for patch in patches {
                let request = NSFetchRequest<NSManagedObject>(entityName: "Message")
                request.predicate = NSPredicate(format: "id == %@", patch.messageID as CVarArg)
                request.fetchLimit = 1
                // A message deleted mid-flight on another device is a silent skip.
                guard let message = try bgContext.fetch(request).first else { continue }

                let existing = (message.value(forKey: "attachments") as? Set<NSManagedObject>) ?? []
                for attachment in existing {
                    guard (attachment.value(forKey: "isServerReference") as? Bool) == true,
                          (attachment.value(forKey: "storedKey") as? String) == patch.storedKey else { continue }

                    // First-writer-wins per field: write only when the patch
                    // supplies the field AND the row does not already hold it.
                    if let previewData = patch.previewData,
                       attachment.value(forKey: "previewData") == nil {
                        attachment.setValue(previewData, forKey: "previewData")
                        wrote = true
                    }
                    if let previewKind = patch.previewKind,
                       attachment.value(forKey: "previewKind") == nil {
                        attachment.setValue(previewKind, forKey: "previewKind")
                        wrote = true
                    }
                    if let thumbnailData = patch.thumbnailData,
                       attachment.value(forKey: "thumbnailData") == nil {
                        attachment.setValue(thumbnailData, forKey: "thumbnailData")
                        wrote = true
                    }
                }
            }
            try bgContext.save()
            return wrote
        }
        // No field written → no visible change → never echo a reload.
        if wroteAny { await postDidChange() }
        return wroteAny
    }

    /// Lazily fault the ONE attachment row's `previewData` blob and decode it as
    /// strict UTF-8. This is the Watch text viewer's on-demand load: the snapshot
    /// path (`AttachmentRecord`) DELIBERATELY never carries preview bytes — a
    /// file-rich thread must not fault a 128 KiB blob per row — so this faults the
    /// blob ONLY for the single attachment being opened. Returns nil on a missing
    /// row, a nil blob, or a UTF-8 decode failure (non-text bytes). Reads on a
    /// fresh background context; bytes cross the actor boundary as a `String`
    /// value (no managed object escapes).
    func fetchPreviewText(messageID: UUID, attachmentID: UUID) async -> String? {
        do { try await ensureLoaded() } catch { return nil }
        let context = container.newBackgroundContext()
        return await context.perform { [context] in
            let request = NSFetchRequest<NSManagedObject>(entityName: "Attachment")
            request.predicate = NSPredicate(
                format: "id == %@ AND message.id == %@",
                attachmentID as CVarArg, messageID as CVarArg
            )
            request.fetchLimit = 1
            guard let attachment = try? context.fetch(request).first,
                  let blob = attachment.value(forKey: "previewData") as? Data else {
                return nil
            }
            return String(data: blob, encoding: .utf8)
        }
    }

    /// Load the FULL bytes of every locally-backed image attachment on a
    /// message, ordered by `sequence`. Server-reference image chips are
    /// deliberately excluded: their bytes live only on the gateway, and
    /// treating their nil data as a local image mints an empty data URI on
    /// Retry and breaks viewer index alignment. The snapshot path never carries
    /// image bytes — this is the on-demand load for the full-screen viewer AND
    /// for assembling prior-turn image data-URIs at send time. Text-file bytes
    /// are already surfaced via `AttachmentRecord.extractedText`.
    ///
    /// Reads on a fresh background context — full image bytes must fault off
    /// the main queue; the bytes are copied into `Data` value types before
    /// crossing the actor boundary (no managed object escapes).
    func loadAttachmentData(for messageID: UUID) async throws -> [Data] {
        try await ensureLoaded()
        let context = container.newBackgroundContext()
        return try await context.perform { [context] in
            let request = NSFetchRequest<NSManagedObject>(entityName: "Attachment")
            request.predicate = NSPredicate(format: "message.id == %@", messageID as CVarArg)
            request.sortDescriptors = [NSSortDescriptor(key: "sequence", ascending: true)]
            let objects = try context.fetch(request)
            return objects.compactMap { obj -> Data? in
                guard let mime = obj.value(forKey: "mimeType") as? String,
                      mime.hasPrefix("image/"),
                      (obj.value(forKey: "isServerReference") as? NSNumber)?.boolValue != true,
                      let data = obj.value(forKey: "data") as? Data,
                      !data.isEmpty else { return nil }
                return data
            }
        }
    }

    // MARK: - Test Support

    /// Insert bare (attribute-less) `Conversation` + `Message` managed objects
    /// against the loaded model and bridge each through its defensive
    /// `init(managedObject:)`, WITHOUT saving. Exercises the nil-coalescing
    /// path on a real model entity (the snapshot structs' raison d'être) so a
    /// unit test doesn't have to reconstruct the compiled model out-of-band.
    /// Runs on a fresh background context like every other read — the pinned
    /// property is the defensive init against the compiled model, not the
    /// context flavor; the scratch objects never persist either way.
    /// Test-only seam — not used by app code.
    func defensiveSnapshotsFromBareObjects() async throws -> (ConversationRecord, MessageRecord) {
        try await ensureLoaded()
        let context = container.newBackgroundContext()
        return try await context.perform { [context] in
            let convo = NSEntityDescription.insertNewObject(
                forEntityName: "Conversation", into: context
            )
            let msg = NSEntityDescription.insertNewObject(
                forEntityName: "Message", into: context
            )
            let pair = (ConversationRecord(managedObject: convo), MessageRecord(managedObject: msg))
            // Discard the scratch objects — never persisted.
            context.delete(convo)
            context.delete(msg)
            return pair
        }
    }

#if DEBUG
    /// Test-only: clear a conversation's `titleSnippet` to simulate a legacy
    /// (pre-field) row for the backfill test. `#if DEBUG` so it never ships in a
    /// release binary (tests run in Debug). Not used by app code.
    func debugClearTitleSnippet(conversationID: UUID) async throws {
        try await ensureLoaded()
        let context = newWriteContext()
        try await context.perform { [context] in
            let request = NSFetchRequest<NSManagedObject>(entityName: "Conversation")
            request.predicate = NSPredicate(format: "id == %@", conversationID as CVarArg)
            request.fetchLimit = 1
            guard let conversation = try context.fetch(request).first else { return }
            conversation.setValue(nil, forKey: "titleSnippet")
            try context.save()
        }
    }

    /// Test-only: clear a message's `text` to simulate a partially-synced
    /// CloudKit row (`Message.text` is `optional="YES"` in the model, so this is
    /// a shape the store really can be handed). `#if DEBUG` so it never ships.
    /// Not used by app code.
    func debugClearMessageText(messageID: UUID) async throws {
        try await ensureLoaded()
        let context = newWriteContext()
        try await context.perform { [context] in
            let request = NSFetchRequest<NSManagedObject>(entityName: "Message")
            request.predicate = NSPredicate(format: "id == %@", messageID as CVarArg)
            request.fetchLimit = 1
            guard let message = try context.fetch(request).first else { return }
            message.setValue(nil, forKey: "text")
            try context.save()
        }
    }

    /// Test-only: clear an attempt row's `outcome` to simulate the
    /// half-materialised row the ledger's absent-column rule is written for
    /// (`GatewayAttempt.outcome` is `optional="YES"`, so a mirrored row really
    /// can arrive this way). `#if DEBUG` so it never ships. Not used by app code.
    func debugClearGatewayAttemptOutcome(attemptID: UUID) async throws {
        try await ensureLoaded()
        let context = newWriteContext()
        try await context.perform { [context] in
            guard let row = Self.gatewayAttemptRow(id: attemptID, in: context) else { return }
            row.setValue(nil, forKey: "outcome")
            try context.save()
        }
    }

    /// Test-only fault injection for the ONE branch the ledger exists to make
    /// survivable: the combined save failing while a reply is riding on it.
    /// Nothing else in the suite can produce that failure — every attempt column
    /// is optional and unconstrained, so no data shape makes Core Data refuse
    /// the save — which would leave the fail-open arm verified by reading only.
    ///
    /// Armed, a save carrying a `TerminalAttemptObservation` throws instead of
    /// committing. The core-only retry carries no observation and is therefore
    /// untouched, which is exactly the asymmetry the rule needs: the measurement
    /// pass fails, the reply still lands.
    func debugSetAttemptBearingSaveFailure(_ fails: Bool) {
        debugFailsAttemptBearingSaves = fails
    }
#endif

    /// Fetch a conversation's messages, oldest first — `createdAt` ascending,
    /// then `id` ascending, which is thread render order.
    ///
    /// THE `id` TIE-BREAK IS NOT COSMETIC, and it is the same total order every
    /// other message picker in this store uses (see `TailProjection`'s header).
    /// Stamps are whole milliseconds, and two devices settling one millisecond
    /// independently can land two turns on the same value, so `createdAt` alone
    /// leaves `last` to whatever the fetch happened to return. `last` is what
    /// `ConversationThreadView.acknowledgeVisibleFailure` reads the failed
    /// turn's `deliveryAttemptID` off, while the list paints the failure the
    /// aggregate selected with `FailedTurnProjection.isNewer` — larger stamp,
    /// then larger id. Without the tie-break those two can name different
    /// messages, and the acknowledgement then stores an identity the resolver
    /// compares against a different attempt: it never matches, so the row stays
    /// red permanently and re-opening the thread rewrites the same
    /// non-matching value.
    func fetchMessages(for conversationID: UUID) async throws -> [MessageRecord] {
        try await ensureLoaded()
        let context = container.newBackgroundContext()
        let start = Date()
        let records: [MessageRecord] = try await context.perform { [context] in
            let request = NSFetchRequest<NSManagedObject>(entityName: "Message")
            request.predicate = NSPredicate(
                format: "conversation.id == %@", conversationID as CVarArg
            )
            request.sortDescriptors = [
                NSSortDescriptor(key: "createdAt", ascending: true),
                NSSortDescriptor(key: "id", ascending: true)
            ]
            // Authoritative read by construction — see `fetchConversations`: a
            // fresh background context holds no registered objects, so a
            // `sending → sent` (or `failed`) flip saved by any write context is
            // read straight from the store on the next fetch. No stale-object
            // refresh dance, no merge-timing dependency — the reload is
            // deterministic (a user turn can never keep its "sending" spinner
            // after the reply already landed).
            let objects = try context.fetch(request)
            return objects.map { MessageRecord(managedObject: $0) }
        }
        Self.logFetchIfSlow("fetch.messages", start: start, rows: records.count)
        return records
    }

    /// The newest message of one conversation, reduced to what a LIST row needs.
    nonisolated struct ConversationTail: Sendable, Hashable {
        let role: String?
        let status: String?
        let createdAt: Date?
        let text: String
    }

    /// The NEWEST message of one conversation — ONE row, no attachment faults.
    ///
    /// Exists for the list's per-visible-row preview, which otherwise faults
    /// EVERY message of the conversation plus each one's `attachments` set and
    /// keeps only the last. Strictly cheaper than the fetch it replaces.
    ///
    /// The `id` tiebreaker on the sort is REQUIRED, not cosmetic: message
    /// timestamps are local wall clock quantised to whole milliseconds, so two
    /// turns written on two devices can share (or invert) a `createdAt`, and
    /// without a total order the chosen tail would flip between otherwise
    /// identical fetches. DESCENDING, so the row this returns is the one
    /// `FailedTurnProjection.isNewer` calls newest and the one `fetchMessages`
    /// returns last — see `TailProjection`'s header for why all three have to
    /// agree.
    func fetchConversationTail(id: UUID) async throws -> ConversationTail? {
        try await ensureLoaded()
        let context = container.newBackgroundContext()
        let start = Date()
        let tail: ConversationTail? = try await context.perform { [context] in
            let request = NSFetchRequest<NSManagedObject>(entityName: "Message")
            request.predicate = NSPredicate(
                format: "conversation.id == %@", id as CVarArg
            )
            request.sortDescriptors = [
                NSSortDescriptor(key: "createdAt", ascending: false),
                NSSortDescriptor(key: "id", ascending: false)
            ]
            request.fetchLimit = 1
            guard let message = try context.fetch(request).first else { return nil }
            return ConversationTail(
                role: message.value(forKey: "role") as? String,
                status: message.value(forKey: "status") as? String,
                createdAt: message.value(forKey: "createdAt") as? Date,
                text: (message.value(forKey: "text") as? String) ?? ""
            )
        }
        Self.logFetchIfSlow("fetch.conversationTail", start: start, rows: tail == nil ? 0 : 1)
        return tail
    }

    // MARK: - Content search

    /// Whole-history content search backing every surface's conversation list
    /// (iPhone / iPad / Mac / Watch). ONE Core Data predicate fetch; returns
    /// ONLY the ids of conversations whose message text matches `query` —
    /// anywhere in any thread, user AND agent turns, regardless of scroll
    /// position. No retained index, no schema change.
    ///
    /// Runs on a fresh background context (`newBackgroundContext()`) so the
    /// per-search scan never contends with the main thread. This is a
    /// LOCAL fetch against the synced SQLite store, so standard predicate
    /// support applies (CloudKit's server-side query limits are irrelevant to a
    /// local fetch). PRIVACY: never logs the query text or the results.
    func searchConversationIDs(containing query: String) async throws -> Set<UUID> {
        // Empty / whitespace-only query → no fetch (caller shows the full list).
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        try await ensureLoaded()
        let context = container.newBackgroundContext()
        return try await context.perform { [context] in
            let request = NSFetchRequest<NSDictionary>(entityName: "Conversation")
            request.resultType = .dictionaryResultType
            // `id` is a DIRECT Conversation attribute — projecting a relationship
            // keypath here would be the trap. `ANY` is required for the to-many
            // `messages` relationship; fetching `Conversation` yields one row per
            // matching conversation (no DISTINCT needed). `[cd]` =
            // case/diacritic-insensitive, deliberately matched to the Tier-1
            // `ConversationSearchFilter.titleMatches` folding
            // (`[.caseInsensitive, .diacriticInsensitive]`) so both tiers behave identically.
            request.propertiesToFetch = ["id"]
            request.predicate = NSPredicate(
                format: "ANY messages.text CONTAINS[cd] %@", trimmed
            )
            let rows = try context.fetch(request)
            var ids: Set<UUID> = []
            for row in rows {
                if let id = row["id"] as? UUID { ids.insert(id) }
            }
            return ids
        }
    }

    /// Every distinct `backend` raw string across the WHOLE conversation store,
    /// unparsed — an unrecognizable value comes back verbatim for the caller to
    /// resolve. Empty values are dropped: a partially-synced CloudKit row
    /// carries `""`, which names no gateway.
    ///
    /// Exists for CarPlay. The other list surfaces already hold every
    /// conversation in memory and derive the same set from that array, but
    /// CarPlay's picker fetches a CAPPED slice (`CarPlayConversationLabel
    /// .recentCap`), so deriving "how many gateways does this history span"
    /// from what it displays would answer a different question than the phone —
    /// two gateways whose only chats fall past the cap would silently drop the
    /// badge in the car and keep it everywhere else.
    ///
    /// A dictionary-result fetch of ONE attribute with `returnsDistinctResults`:
    /// SQLite returns one row per distinct value, so this costs a fraction of
    /// materializing the conversations, and CarPlay runs it once per picker
    /// refresh. `returnsDistinctResults` requires `.dictionaryResultType` —
    /// it is silently ignored on a managed-object fetch.
    func distinctBackends() async throws -> Set<String> {
        try await ensureLoaded()
        let context = container.newBackgroundContext()
        return try await context.perform { [context] in
            let request = NSFetchRequest<NSDictionary>(entityName: "Conversation")
            request.resultType = .dictionaryResultType
            request.propertiesToFetch = ["backend"]
            request.returnsDistinctResults = true
            let rows = try context.fetch(request)
            var backends: Set<String> = []
            for row in rows {
                if let backend = row["backend"] as? String, !backend.isEmpty {
                    backends.insert(backend)
                }
            }
            return backends
        }
    }

    // MARK: - Title snippet

    /// Characters kept in the stored snippet before an ellipsis is appended.
    static let titleSnippetMaxLength = 60

    /// Characters the truncation probe asks for BEYOND `titleSnippetMaxLength`.
    /// TWO, not one: the projection collapses a whitespace run into a separator
    /// that spends a character of the budget, and it refuses to end a line on that
    /// separator — so a one-character probe can be swallowed whole by a space at
    /// the boundary and come back exactly at the cap, indistinguishable from text
    /// that simply ended there. The ellipsis then goes missing from a snippet that
    /// really was cut, and the row claims a complete first line the user never
    /// sent. Two characters buy one CONTENT character past the cap whenever the
    /// projection has one, and a constant margin keeps the scan bounded however
    /// long the untrusted input is.
    private static let titleSnippetProbeMargin = 2

    /// Derive a list-row title from a message body: first non-empty line,
    /// projected to one safe display line, capped at `titleSnippetMaxLength`
    /// (with an ellipsis when cut). Returns nil when the text is empty,
    /// whitespace-only, or projects away to nothing — an attachment-only turn,
    /// or a line of pure formatting controls — so the caller skips the write and
    /// a later text turn can fill it.
    ///
    /// THE PROJECTION RUNS BEFORE THE CAP, and that order is the point. This
    /// snippet is derived from the user's own transcript, which can arrive from a
    /// BYO speech endpoint, so it is untrusted content:
    /// `ReplySanitizer.displayLine` removes the control and bidi scalars that
    /// would otherwise reorder or blank a headline, and cutting first can land
    /// between a bidi opener and its terminator, leaving the opener governing
    /// everything the row still shows. Only this derived field is projected — the
    /// message text itself stays byte-exact. Rows written before this projection
    /// existed (and rows synced in from another device) are answered again at the
    /// render boundary, so history needs no rewrite.
    ///
    /// CROSS-TARGET: lives here (the store is a Watch membership exception) so
    /// both the write path and the backfill share one definition. Deliberately
    /// NOT `MessageRowFormatters.firstLineFallback` — that helper is a DISPLAY
    /// fallback (first line even when blank, `maxHeadlineLength` cap) while this
    /// is a STORED denormalization (first NON-EMPTY line, a shorter cap, nil when
    /// the turn has no text so a later turn can fill it). Both types are Watch
    /// members, so the split is about semantics, not target membership.
    static func snippet(from text: String) -> String? {
        let firstLine = text
            .split(whereSeparator: \.isNewline)
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map(String.init)
        guard let firstLine else { return nil }
        // A fixed `titleSnippetProbeMargin` past the cap is all it takes to know
        // the line was cut, and asking for no more keeps the scan bounded however
        // long the untrusted input is.
        let projected = ReplySanitizer.displayLine(
            firstLine, maxLength: titleSnippetMaxLength + titleSnippetProbeMargin, fallback: ""
        )
        guard !projected.isEmpty else { return nil }
        guard projected.count > titleSnippetMaxLength else { return projected }
        // Second pass over an ALREADY-projected string, so it is a pure cap —
        // and it is what keeps the head from ending in whitespace.
        let head = ReplySanitizer.displayLine(
            projected, maxLength: titleSnippetMaxLength, fallback: ""
        )
        return head + "…"
    }

    /// One-time iOS backfill so the founder's EXISTING conversations also get a
    /// `titleSnippet` (otherwise the fix looks broken for current data). Guarded
    /// by an App-Group `UserDefaults` flag so it runs once per device. For each
    /// conversation with a nil/empty snippet, fetch its first user message and
    /// write `snippet(from:)`. Posts the change notification once at the end so
    /// the lists refresh. Safe to define cross-target (only the iOS launch seam
    /// calls it).
    func backfillTitleSnippetsIfNeeded() async {
        // NEVER AGAINST THE REAL STORE FROM A TEST HOST. This is the one place
        // the storage seam cuts a pair in half: the "already done" flag is
        // seamed, the Core Data store it guards is NOT (the real App-Group
        // sqlite, with the CloudKit mirror attached on every non-simulator
        // build). Under `CONDUCK_TESTING` the flag reads false from a fresh
        // in-memory store on EVERY run, so a signed macOS or on-device test run
        // would rewrite every title snippet in the developer's real conversation
        // database and export the change to their private CloudKit zone — then,
        // the flag having been written to the in-memory store, do it again next
        // invocation. Seaming the flag back to the real App Group would restore
        // the old no-op but put a live-container write back into the suite.
        //
        // Gated on the STORE, not on the test host, so a suite driving an
        // ephemeral `ConversationStore(inMemory:)` still exercises the migration.
        #if CONDUCK_TESTING
        guard container.persistentStoreDescriptions.first?.type == NSInMemoryStoreType else { return }
        #endif
        let flagKey = "conversationTitleSnippetBackfillDone"
        let defaults = SettingsDependencies.processDefault.defaults
        guard !defaults.bool(forKey: flagKey) else { return }

        do { try await ensureLoaded() } catch { return }
        let context = newWriteContext()
        await context.perform { [context] in
            let request = NSFetchRequest<NSManagedObject>(entityName: "Conversation")
            // Match nil OR empty snippet (a row written before this field shipped).
            request.predicate = NSPredicate(format: "titleSnippet == nil OR titleSnippet == %@", "")
            let conversations = (try? context.fetch(request)) ?? []
            guard !conversations.isEmpty else { return }

            for conversation in conversations {
                guard let convoID = conversation.value(forKey: "id") as? UUID else { continue }
                let msgRequest = NSFetchRequest<NSManagedObject>(entityName: "Message")
                msgRequest.predicate = NSPredicate(
                    format: "conversation.id == %@ AND role == %@", convoID as CVarArg, "user"
                )
                msgRequest.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: true)]
                msgRequest.fetchLimit = 1
                guard let firstUser = (try? context.fetch(msgRequest))?.first,
                      let text = firstUser.value(forKey: "text") as? String,
                      let snip = Self.snippet(from: text) else { continue }
                conversation.setValue(snip, forKey: "titleSnippet")
            }
            try? context.save()
        }

        defaults.set(true, forKey: flagKey)
        await postDidChange()
    }
}
