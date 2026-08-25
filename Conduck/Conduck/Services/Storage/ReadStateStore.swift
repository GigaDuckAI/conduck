// SPDX-License-Identifier: Apache-2.0

// Conduck
// ReadStateStore.swift
//
// The read-state API every conversation-list surface calls, and the short-lived
// OPTIMISTIC OVERLAY that sits in front of it. It owns no durable truth.
//
// WHAT THE USER HAS SEEN IS AN ACCOUNT FACT, and it lives on the conversation
// record: `Conversation.lastViewedAt` and `Conversation.failureSeenAttemptID`
// are CloudKit-mirrored columns, so reading a thread on the iPad clears its dot
// on the phone, the Mac and the wrist. This class writes those columns through
// `ConversationStore` and reads them back off the record the caller already
// holds — it is a façade over a store, not a store.
//
// TWO MARKERS, STILL TWO SEPARATE FACTS, and collapsing them is the bug this
// shape exists to prevent:
//
//   • `markViewed`         — when was this thread last on screen? Drives the
//                            amber unseen-reply disc and the bold row. One
//                            AURAL exception: CarPlay marks on proven HEARD
//                            exposure (reply audio began + TTS settled
//                            `.finished` — `CarPlayRecordingService.speakReply`),
//                            since the car has no thread view. Same
//                            false-read-averse bias: anything short of a fully
//                            delivered reply stays unread.
//   • `acknowledgeFailure` — WHICH failure has been shown to the user? Drives
//                            whether the red mark has been retired.
//
// THE SECOND IS NOT DERIVABLE FROM THE FIRST. The read marker is re-stamped on
// every new tail in an open thread — including the user's own message, the
// instant it is sent. A failed turn's stamp is its `createdAt`, and failing
// bumps neither that nor the conversation's `lastActivityAt`. So by the time a
// send fails, the read marker is ALREADY newer than the turn it would have to
// acknowledge: reusing it would suppress the failure mark for everything sent
// from the composer, which is nearly every failure.
//
// THE ACKNOWLEDGEMENT IS AN IDENTITY, NOT A TIME. It names one
// `Message.deliveryAttemptID`, and the resolver accepts it only on exact
// equality (`ConversationActivity.swift` step 2b). That is what removes the
// destructive clear this class used to need: asking again mints a NEW attempt
// id, so the stored acknowledgement simply stops matching, and no writer has to
// race to un-say something. It also means acknowledgement gets NO optimistic
// overlay and no cutover fallback — an unacknowledged failure over-reports and
// costs one tap, while a silenced one is a message the user never learns did
// not send, and only the record can say which attempt was seen.
//
// ONE MIXED-FLEET CASE IS ACCEPTED RATHER THAN CLOSED, and it is the exception
// to "the safe direction" above, so it is stated here rather than left to be
// inferred. A retry performed by a device still running a build with no
// `deliveryAttemptID` writes only the status column, so the row keeps the
// identity the account already acknowledged instead of losing it: that build
// cannot put a key its model does not define into a CKRecord, and a key a save
// does not carry is left alone on the server rather than cleared. The
// re-failure then matches the stored acknowledgement and shows no mark on any
// UPDATED device — silent, which is the one outcome this design otherwise
// forbids. It cannot be fixed from here: the device that begins the new attempt
// runs none of this code, so no additional field it would have to bump helps,
// and no later reader can tell that record apart from one that simply was not
// retried. It lasts only until the last device updates. `ConversationActivity
// .swift` step 2b carries the full reasoning.
//
// WHY AN OVERLAY AT ALL. The durable write is a background-context save that
// then has to come back round as a fetch, so backing out of a thread would leave
// its row bold for as long as that takes. The overlay is this device's most
// recent local INTENT, folded into every read by `max`, alive only until the
// record carries it. It is a write-through echo, NOT a cache of the record: it
// is never consulted to answer what the account believes, only to move the
// answer forward while the save is in flight.
//
// RETIREMENT IS A RECONCILE STEP, NEVER A READ. Reads here are pure — a getter
// that mutated would fire an `@Observable` change from inside a SwiftUI `body`.
// `reconcile(with:)` is handed the list a surface has just fetched and runs on
// the SAME main-actor turn that surface assigns it, beside
// `InFlightTurnRegistry.reconcile()`, which exists for exactly that reason: a
// row must never render against fresh records and a stale overlay.
//
// THE HARD TTL STARTS AFTER THE STORE WRITE COMPLETES, not when the intent is
// recorded. The store's first touch has to open sqlite and CloudKit metadata,
// which on a cold wrist launch can sit tens of seconds behind; an entry whose
// write is still in flight must never expire, because expiring it would revert
// the row under the user and un-read a thread they are looking at.
//
// THE CUTOVER IS THE ONE ACCOUNT FACT THAT DOES NOT RIDE THE RECORD. It answers
// a question no conversation can: from what moment does the ABSENCE of a marker
// mean "not read" rather than "we were not recording yet"? Without it, the first
// launch after this feature ships would light up every conversation the user
// ever had. It travels in ONE iCloud key-value key through the `UbiquitousStore`
// seam, mirrored into local defaults so a read on a SwiftUI render pass is
// synchronous and works offline.
//
//   • MERGED BY `min`, NEVER `max` — `meetCutover`. The cutover is the EARLIEST
//     moment any of this account's devices could have been recording, so an iPad
//     set up last week must not drag it forward and mark a year of genuinely
//     unread replies as read everywhere. Adopt a remote value only if it is
//     EARLIER; push down, never up. `min` is idempotent, commutative and
//     associative, so the register self-heals whatever order values arrive in.
//   • NEVER WRITTEN INTO A CONVERSATION RECORD. A device stamp means "I was not
//     here before this date", not "the account read everything before this
//     date". Only an EXPLICIT per-conversation marker is ever folded.
//   • A FRESHLY CLAIMED VALUE IS PROVISIONAL until iCloud has actually spoken.
//     `SettingsManager.performInitialSync` documents the rule this obeys:
//     absence after `synchronize()` is NOT evidence the cloud key is absent —
//     KVS is empty on a device that has never completed a first download. So a
//     value minted in this launch is used locally but never seeded into the
//     register until either a real remote value arrives or an external change
//     proves the store has downloaded.
//   • A DEVICE WITH NO iCLOUD STAMPS, READS ITS OWN VALUE, AND PUSHES NOTHING.
//     That is coherent rather than degraded: with no iCloud there is no CloudKit
//     mirror either, so it is a single-device world and the local value IS the
//     account value.
//
// THE LEGACY DEVICE-LOCAL KEYS ARE A READ-SIDE FALLBACK, NOT A MIGRATION. There
// is no done-flag and no eager sweep: the initial CloudKit import is
// ASYNCHRONOUS, so a flag could commit before every conversation exists locally
// and would lose the marker of each one that had not arrived yet. Instead the
// old per-conversation read keys are loaded once, folded into records one
// conversation at a time as those conversations actually turn up in a fetch, and
// each key is deleted ONLY on a confirmed cover. Until then the key keeps
// answering reads, so nothing goes bold in the gap.
//
// THERE ARE TWO GAPS, AND THE SECOND ONE IS THE EASY ONE TO MISS. Confirmation
// means the RECORD carries the marker, not that this device has re-fetched the
// record: the fold deliberately posts no change notification, so the
// `ConversationRecord` snapshots a list is rendering still say `lastViewedAt ==
// nil` until something else triggers a reload. Dropping the key at that moment
// would take the marker out of `lastViewed`'s fold while nothing had replaced it
// — and because these reads happen inside a SwiftUI `body` over `@Observable`
// stored state, the whole list would repaint on the spot with a weaker answer:
// dozens of already-read rows going bold with an unseen disc, on the first
// launch after the upgrade, staying wrong on an idle list indefinitely. So a
// confirmed marker is HANDED TO THE OVERLAY rather than dropped
// (`completeFold`). The overlay is exactly the right home for it — this device's
// local echo of a value the store already holds — and it retires through the
// one mechanism that actually checks: `reconcile(with:)` step 1, when a fetched
// record is observed to carry it. Legacy FAILURE
// acknowledgements are deliberately NOT migrated at all — see `init`.
//
// MULTI-PROCESS SHAPE. The main app, the share extension, an App Intent and a
// background relaunch all run against the same App Group. Only the main app
// drains the legacy keys, and the per-conversation key layout means even a
// second drainer could not lose an UNRELATED key — there is no read-modify-write
// of a shared blob to lose it in. The durable markers have no such concern: they
// are columns, and the store serializes every write to them.

import Foundation

// MARK: - The durable side

/// The record writes this class fronts, as a protocol so a suite can exercise
/// the overlay, the reconcile and the legacy drain without a persistent store.
///
/// The repo's rule is that a test host NEVER touches a real store, and
/// `ConversationStore`'s App-Group sqlite is one of the documented carve-outs
/// from the storage seam — it opens the shared container for real. Injecting the
/// writer is what keeps an overlay test from writing files next to the installed
/// app's.
protocol ConversationReadStateWriter: Sendable {
    func markConversationViewed(_ id: UUID, at: Date) async
    func acknowledgeConversationFailure(_ id: UUID, attemptID: UUID) async
    func markConversationViewedAndAcknowledged(_ id: UUID, at: Date, attemptID: UUID?) async
    func foldLegacyReadMarker(_ id: UUID, localMarker: Date) async -> ReadMarkerFoldOutcome
}

extension ConversationStore: ConversationReadStateWriter {}

// MARK: - Store

@Observable @MainActor
final class ReadStateStore {

    // MARK: - Singleton

    static let shared = ReadStateStore()

    /// Memory bound on the optimistic overlay. THIS IS A MEMORY GUARD, NOT A
    /// SEMANTIC CAP: the durable markers are columns on the conversation, so the
    /// marker count IS the conversation count and markers die with the record by
    /// cascade — there is nothing left for a cap to mean. Overlay entries are
    /// alive for the length of one save, so this ceiling is unreachable in
    /// normal use and exists only so a pathological loop cannot grow the
    /// dictionary without bound.
    static let maxOverlayEntries = 512

    /// How long a SETTLED overlay entry survives once the store has confirmed
    /// its write. The clock starts at confirmation, never at the intent — see
    /// the file header. Generous on purpose: the entry is harmless (it can only
    /// move a marker forward), and expiring one early un-reads a thread.
    static let overlaySettledTTL: TimeInterval = 300

    /// Legacy read keys folded per reconcile pass. The first launch after the
    /// upgrade can hold thousands, and dispatching one store round-trip per key
    /// in a single main-actor turn would stall the list fetch that triggered it.
    /// Undrained keys simply wait for the next pass; they still answer reads
    /// meanwhile, so the delay is invisible.
    static let maxLegacyFoldsPerPass = 25

    /// Ceiling on the legacy read keys carried in memory, oldest dropped first.
    ///
    /// Bounds the one residue this design cannot drain: a key whose conversation
    /// never reappears locally — deleted on another device before this one
    /// imported — has nothing to fold into, and absence from a fetch is not
    /// proof of deletion, so it can never be retired on that evidence alone. A
    /// real deletion IS authoritative and `forget(_:)` takes that path; this
    /// ceiling covers the rest.
    static let maxLegacyMarkers = 2_000

    /// Realistic device-clock skew this app absorbs. Deliberately small: it
    /// exists for minutes of drift, not for a broken clock.
    ///
    /// ONE BUDGET, TWO CLAMPS, AND THEY HAVE TO BE THE SAME NUMBER.
    /// `clamped(existing:reference:now:)` caps a view marker at `now + grace`,
    /// and `ConversationStore.appendStamp` caps the stamp it writes at
    /// `proposed + grace` when it is following a mirrored `lastActivityAt` from
    /// a peer with a wrong clock. Together those say: no activity stamp this app
    /// writes can land above the ceiling a view marker is allowed to reach, so
    /// every conversation stays markable as read. Raising one alone re-opens a
    /// row that can never be covered — permanently bold, permanently top of the
    /// list.
    ///
    /// `nonisolated` — `appendStamp` reads it from the store actor's write
    /// context, off the main actor.
    nonisolated static let clockSkewGrace: TimeInterval = 3_600

    // MARK: - Overlay entry

    /// One device-local view intent.
    private struct Overlay: Equatable {
        /// The marker this device wants the record to carry.
        var viewedAt: Date
        /// When the store CONFIRMED the write, or nil while it is still in
        /// flight. Nil is what makes an entry immortal until the save returns:
        /// the TTL cannot start on a value the store has not yet seen.
        var settledAt: Date?
    }

    // MARK: - State

    private let defaults: any DefaultsStore
    private let writer: any ConversationReadStateWriter

    /// The account register the cutover lives in, its change feed, and the
    /// answer to "does this device have an iCloud account at all" — all through
    /// the storage seam, never `NSUbiquitousKeyValueStore` directly
    /// (`scripts/check-storage-seam.sh` enforces it, and a test host that opened
    /// the real store would write into the developer's own iCloud account).
    private let ubiquitous: any UbiquitousStore
    private let cloudAvailability: any CloudAvailability
    private let changes: any KVSChangeSource

    /// The overlay, in an observable STORED property. `@Observable` reports
    /// changes to stored properties only, so a getter reaching a store directly
    /// would register no SwiftUI dependency and the row would never repaint when
    /// a thread is marked viewed.
    private var overlay: [UUID: Overlay] = [:]

    /// The account's read cutover, mirrored locally for synchronous reads.
    /// Everything older counts as viewed, which is what keeps an imported
    /// history from arriving bold. Applies to the READ marker only — see the
    /// header for why acknowledgement takes no such optimism.
    private var accountCutover: Date?

    /// Legacy device-local read markers still awaiting a fold. Durable: an entry
    /// leaves only when the store confirms the record covers it, or when the
    /// conversation is really deleted.
    private var legacyReadMarkers: [UUID: Date]

    /// Folds currently in flight, so a second reconcile arriving before the
    /// first store round-trip returns does not dispatch the same fold twice.
    private var foldsInFlight: Set<UUID> = []

    /// True when THIS launch minted `accountCutover` out of nothing, rather than
    /// loading a value a previous launch had already persisted. Half of the
    /// provisional test — see `cutoverIsProvisional`.
    private var cutoverMintedThisLaunch = false

    /// True once an external KVS change carrying remote values has been handled.
    /// This is the evidence that the store has downloaded, which is the ONLY
    /// thing that turns "the cutover key is absent" from silence into a fact.
    private var hasProcessedCloudDelivery = false

    /// Registration guard for the inbound arm. Idempotent so a relaunch-shaped
    /// second `resolveAccountCutover()` (an App Intent waking a suspended
    /// process, a macOS reopen) cannot stack observers.
    private var isObservingCloudCutover = false

    // MARK: - Init

    init(
        defaults: any DefaultsStore = SettingsDependencies.processDefault.defaults,
        writer: any ConversationReadStateWriter = ConversationStore.shared,
        ubiquitous: any UbiquitousStore = SettingsDependencies.processDefault.ubiquitous,
        cloudAvailability: any CloudAvailability = SettingsDependencies.processDefault.cloudAvailability,
        changes: any KVSChangeSource = SettingsDependencies.processDefault.changes
    ) {
        self.defaults = defaults
        self.writer = writer
        self.ubiquitous = ubiquitous
        self.cloudAvailability = cloudAvailability
        self.changes = changes

        // ONE prefix sweep at construction, not a per-read decode.
        var loaded: [UUID: Date] = [:]
        var doomedKeys: [String] = []
        let readPrefix = Constants.conversationReadStatePrefix
        let failurePrefix = Constants.conversationFailureSeenPrefix

        for (key, value) in defaults.dictionaryRepresentation() {
            // LEGACY FAILURE ACKNOWLEDGEMENTS ARE NEVER FOLDED, and this is the
            // one pass that already visits them, so it retires them instead.
            // Folding one is unsafe in the only direction that matters: the old
            // marker is a TIME and the new acknowledgement is an ATTEMPT
            // IDENTITY, so a fold would have to invent an identity for whatever
            // attempt happens to be failed right now — and a turn retried after
            // the upgrade keeps its `createdAt`, so that invented cover would
            // silence its re-failure permanently. The safe failure mode is one
            // extra red mark the user clears with a tap, not a hidden one, and
            // since nothing will ever read these again, keeping them would only
            // grow the App-Group domain forever.
            if key.hasPrefix(failurePrefix) {
                doomedKeys.append(key)
                continue
            }
            guard key.hasPrefix(readPrefix) else { continue }
            // The cutover mirror shares the read prefix and is not a marker.
            if key == Constants.conversationReadStateEpochKey { continue }

            // An orphan is a key under the prefix that cannot be a marker at all
            // — an unparsable id or a non-numeric value. That is garbage this
            // store wrote or a future format it does not understand; either way
            // keeping it only grows the sweep. A marker whose conversation has
            // not arrived yet is NOT an orphan: the CloudKit import is
            // asynchronous, and absence from a fetch is never a deletion signal.
            let suffix = String(key.dropFirst(readPrefix.count))
            guard let id = UUID(uuidString: suffix),
                  let seconds = (value as? NSNumber)?.doubleValue else {
                doomedKeys.append(key)
                continue
            }
            loaded[id] = Date(timeIntervalSince1970: seconds)
        }
        self.legacyReadMarkers = loaded

        let storedCutover = defaults.double(forKey: Constants.conversationReadStateEpochKey)
        self.accountCutover = storedCutover > 0 ? Date(timeIntervalSince1970: storedCutover) : nil

        for key in doomedKeys { defaults.removeObject(forKey: key) }
        boundLegacyMarkers()
    }

    // MARK: - Account cutover

    /// THE launch entry point for the account cutover, and the only one an app
    /// delegate should call. Stamps a local value if this device has none,
    /// arms the inbound change feed, and meets whatever the account register
    /// already holds.
    ///
    /// Called from deterministic app startup on EVERY surface — iOS
    /// (`ConduckApp.init`), macOS (`AppDelegate.applicationDidFinishLaunching`)
    /// and watchOS (`ConduckWatchApp.init`) — never from a SwiftUI `body`:
    /// creating state during rendering is both a SwiftUI error and a race with
    /// the CloudKit import, since a reply that imported at 10:00 would be
    /// classified read because the first row happened to render at 10:01.
    /// Idempotent, and cheap enough to run on a background relaunch.
    ///
    /// SYNCHRONOUS ON PURPOSE. `UbiquitousStore.synchronize()` schedules an
    /// exchange, it does not wait for a download, so there is nothing to await
    /// and an `async` shape here would only push the local stamp behind the
    /// first render for no gain. Everything the cloud actually delivers arrives
    /// later, through the change feed armed here.
    func resolveAccountCutover(now: Date = Date()) {
        stampAccountCutoverIfNeeded(now: now)
        // ARM FIRST, THEN MERGE. A delivery landing between the read below and a
        // later registration would be lost, and it is exactly the delivery a
        // provisional stamp is waiting for.
        observeAccountCutoverIfNeeded()
        ubiquitous.synchronize()
        mergeAccountCutoverWithCloud()
    }

    /// Seed the account read cutover if nothing has seeded it yet. Idempotent.
    ///
    /// PROVISIONAL. This writes only the local mirror, which is what a
    /// synchronous read needs on a device that is offline or has not hydrated
    /// iCloud yet. The account register is the authority and meets this value by
    /// `min`; until iCloud has actually spoken, the value stays here and is
    /// never seeded into the register — see `pushAccountCutoverDown(remote:)`.
    func stampAccountCutoverIfNeeded(now: Date = Date()) {
        guard accountCutover == nil else { return }
        accountCutover = now
        cutoverMintedThisLaunch = true
        defaults.set(now.timeIntervalSince1970, forKey: Constants.conversationReadStateEpochKey)
    }

    /// Adopt a cutover reconciled against the account register.
    ///
    /// The defaults KEY name is frozen (`conversationReadStateEpochKey`): it is
    /// a live key on installed devices, and renaming it would silently reset
    /// every one of them to an unstamped cutover.
    func applyAccountCutover(_ value: Date) {
        guard let merged = Self.meetCutover(accountCutover, value), merged != accountCutover else { return }
        accountCutover = merged
        defaults.set(merged.timeIntervalSince1970, forKey: Constants.conversationReadStateEpochKey)
    }

    /// Meet two views of the account cutover.
    ///
    /// **`min`, NEVER `max` — and a reader who assumes `max` will be wrong.**
    /// This value answers "from what moment does the ABSENCE of a marker mean
    /// NOT READ, rather than we were not recording yet", so the account's answer
    /// is the EARLIEST moment any of its devices could have been recording.
    /// Taking the later of two would let an iPad set up last week declare that
    /// everything before last week had been read, and every genuinely unread
    /// reply from the months before it would go silent on every device at once —
    /// permanently, because nothing ever re-bolds a row.
    ///
    /// `nil` means "this side has no opinion", so the other side wins outright:
    /// a device that has not stamped yet must not veto the account's value, and
    /// an empty register must not erase the device's.
    ///
    /// `min` is idempotent, commutative and associative, so the register
    /// self-heals whatever order values arrive in, however many devices push,
    /// and however many times the same value is re-applied.
    ///
    /// PURE AND STATIC so the meet can be tested without a store, a defaults
    /// double or an iCloud account.
    static func meetCutover(_ mine: Date?, _ theirs: Date?) -> Date? {
        guard let mine else { return theirs }
        guard let theirs else { return mine }
        return min(mine, theirs)
    }

    /// Handle an external change to the ubiquitous store — the inbound arm.
    ///
    /// DELIBERATELY NOT FILTERED ON `changedKeys`. Foundation supplies that list
    /// for a server change and an initial-sync change, and it names keys that
    /// CHANGED — it can never name the cutover key when the register genuinely
    /// does not hold one. Filtering on it would therefore drop the single
    /// delivery a provisional stamp is waiting for, and a fresh install would
    /// keep its own late cutover forever. The merge is idempotent and writes
    /// only when a value actually moves, so running it on an unrelated language
    /// or voice push costs one dictionary read.
    ///
    /// A quota violation or an account change carries no usable inbound delta
    /// (`KVSChangeReason.deliversRemoteValues`) and must not be mistaken for
    /// evidence that the store has downloaded.
    func handleAccountCutoverChange(_ change: KVSChange) {
        guard change.reason.deliversRemoteValues else { return }
        hasProcessedCloudDelivery = true
        mergeAccountCutoverWithCloud()
    }

    /// Register the inbound arm exactly once.
    ///
    /// UNCONDITIONAL, like every other observer in this app: a user who signs
    /// into iCloud mid-session must not need a relaunch before sync resumes, and
    /// an observer on a dormant store costs nothing because no notification ever
    /// fires while signed out.
    private func observeAccountCutoverIfNeeded() {
        guard !isObservingCloudCutover else { return }
        isObservingCloudCutover = true
        changes.observe { [weak self] change in
            // The live source delivers on the main queue and the in-memory
            // double delivers inline on the caller's thread, so the hop is what
            // makes both safe against this main-actor class.
            Task { @MainActor in self?.handleAccountCutoverChange(change) }
        }
    }

    /// Meet the local mirror with the register, then decide whether anything
    /// goes back up.
    private func mergeAccountCutoverWithCloud() {
        let remote = cloudCutover()
        if let remote { applyAccountCutover(remote) }
        pushAccountCutoverDown(remote: remote)
    }

    /// The register's current value, or nil when it holds none.
    ///
    /// Presence is tested with `object(forKey:)` rather than by reading the
    /// `Double`: an absent numeric key reads as `0`, which is 1 January 1970 —
    /// a cutover so early that every conversation would arrive bold, and one
    /// that `min` would then lock in permanently across the whole account.
    private func cloudCutover() -> Date? {
        guard ubiquitous.object(forKey: Constants.conversationReadCutoverKVSKey) != nil else { return nil }
        let seconds = ubiquitous.double(forKey: Constants.conversationReadCutoverKVSKey)
        guard seconds > 0 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    /// Write this device's value into the register — ONLY ever downward.
    ///
    /// Two cases, and the second is where every hazard lives:
    ///
    ///   • The register holds a value and ours is EARLIER → lower it. This is
    ///     the whole point: the account converges on the earliest moment any
    ///     device could have been recording.
    ///   • The register holds nothing → seeding it is a real write on non-
    ///     evidence, so it is gated twice. `cutoverIsProvisional` blocks a value
    ///     this launch invented from being published before iCloud has spoken;
    ///     `cloudIsProvenLive` blocks a device with no account from publishing
    ///     at all. A premature seed would set the account's cutover to a value
    ///     LATER than the truth, hiding unread replies on every other device
    ///     until one of them next launched and pushed its own earlier value back
    ///     down — recoverable, but the recovery needs a launch that may be days
    ///     away.
    ///
    /// The register is never CLEARED here. Absence is not evidence of a delete
    /// (the same rule `SettingsManager.performInitialSync` states for gateway
    /// config), and `min` has no inverse: there is no value that undoes an
    /// earlier one.
    private func pushAccountCutoverDown(remote: Date?) {
        guard let local = accountCutover else { return }
        if let remote {
            guard local < remote else { return }
        } else {
            guard cloudIsProvenLive, !cutoverIsProvisional else { return }
        }
        ubiquitous.set(local.timeIntervalSince1970, forKey: Constants.conversationReadCutoverKVSKey)
    }

    /// A value minted in this launch that iCloud has not yet had a chance to
    /// contradict.
    ///
    /// `SettingsManager.performInitialSync` documents the rule: KVS is empty on
    /// a device that has never completed a first download, and `synchronize()`
    /// does not wait for one — so silence right after it is not evidence the key
    /// is absent. A value carried over from a previous launch has already
    /// survived a whole session's worth of downloading and is not provisional;
    /// one minted seconds ago has not.
    private var cutoverIsProvisional: Bool {
        cutoverMintedThisLaunch && !hasProcessedCloudDelivery
    }

    /// Whether this device has an iCloud account worth publishing to.
    ///
    /// The ubiquity token alone is NOT enough, and that is not a subtlety: it
    /// tracks iCloud DRIVE, which does not exist on watchOS, so it is ALWAYS nil
    /// on the wrist (the same trap `WatchIdentityResolver` documents, where the
    /// gate silently disabled the iCloud tier on every Watch). A delivered
    /// external change proves the store is live regardless of what the token
    /// says, and it is the wrist's only honest proof.
    private var cloudIsProvenLive: Bool {
        cloudAvailability.isAvailable || hasProcessedCloudDelivery
    }

    // MARK: - Read

    /// The effective "last looked at" for one conversation:
    /// `max(overlay, legacy fallback, stored, accountCutover)`.
    ///
    /// - Parameter stored: the record's own `lastViewedAt` — the account-wide
    ///   durable truth, mirrored in with the row the caller already holds. Nil
    ///   means never viewed on any device.
    ///
    /// FOUR SOURCES, ONE `max`, AND `max` IS NEVER WRONG HERE because every one
    /// of them is monotone: the overlay leads (it is recorded before the save it
    /// describes), the legacy key is a fact about a view that really happened,
    /// the record both outlives the overlay and arrives from the other devices,
    /// and the cutover is a floor under all three. Taking the latest means a
    /// value arriving out of order can only ever move the marker FORWARD, so a
    /// late import carrying an older time cannot re-bold a row the user just
    /// read.
    ///
    /// PURE. Nothing retires here — see `reconcile(with:)`.
    ///
    /// `nil` only when all four are absent, which is a device whose cutover has
    /// not been stamped yet; the resolver treats that as viewed, so a fresh
    /// install with an imported history shows zero dots.
    func lastViewed(_ conversationID: UUID, stored: Date?) -> Date? {
        [overlay[conversationID]?.viewedAt, legacyReadMarkers[conversationID], stored, accountCutover]
            .compactMap { $0 }
            .max()
    }

    /// The overlay as plain markers — tests + diagnostics.
    func overlayMarkers() -> [UUID: Date] { overlay.mapValues(\.viewedAt) }

    /// Legacy read markers still awaiting a fold — tests + diagnostics.
    func pendingLegacyMarkers() -> [UUID: Date] { legacyReadMarkers }

    /// The account read cutover this device currently believes in — tests +
    /// diagnostics.
    func currentAccountCutover() -> Date? { accountCutover }

    // MARK: - Write

    /// Record that the user has looked at this conversation.
    ///
    /// CLAMPED AND MONOTONIC — see `clamped(existing:reference:now:)`. The
    /// overlay is stamped first and the record write is dispatched behind it, so
    /// the row un-bolds on this runloop turn; the store applies its own monotone
    /// `max` against the stored value and saves only when that value actually
    /// moves, which is what keeps a thread open across many tails from exporting
    /// a CKRecord per tail.
    ///
    /// Fire-and-forget by design: a slow store load must never block the surface
    /// that stamped, and there is no user-visible failure to report — the legacy
    /// fallback and the next stamp both still hold the intent.
    func markViewed(_ conversationID: UUID, lastActivityAt: Date?, now: Date = Date()) {
        guard let marker = stampOverlay(conversationID, lastActivityAt: lastActivityAt, now: now) else { return }
        Task { [weak self, writer] in
            await writer.markConversationViewed(conversationID, at: marker)
            self?.settle(conversationID, marker: marker)
        }
    }

    /// Record that the user has been shown THIS delivery attempt's failure — the
    /// acknowledgement that retires the list's red mark, on every device.
    ///
    /// `attemptID` is `Message.deliveryAttemptID` of the failed turn the row is
    /// actually painting, taken from the same projection that supplied its
    /// stamp so the two can never name different turns.
    ///
    /// NIL IS A NO-OP, NOT A CLEAR AND NOT A WILDCARD. A failed turn carrying no
    /// attempt id is a row from before the attribute existed, or one this
    /// surface could not name, and nothing can acknowledge it: storing "seen
    /// nothing" would either mean nothing or, worse, match the next id-less
    /// failure by accident. It stays red, which is the safe direction. (A turn
    /// retried by a build that mints no identity is the opposite case — it
    /// keeps the OLD one rather than losing it; see the file header.)
    ///
    /// NO OVERLAY. Acknowledgement is an identity match against one attempt, and
    /// no device-local value can say which attempt the account has seen, so the
    /// mark retires when the record does.
    func acknowledgeFailure(_ conversationID: UUID, attemptID: UUID?) {
        guard let attemptID else { return }
        Task { [writer] in
            await writer.acknowledgeConversationFailure(conversationID, attemptID: attemptID)
        }
    }

    /// Both markers for a surface that does both on ONE user action — opening a
    /// thread from the menu bar is a single click that is simultaneously "I have
    /// looked at this" and "I have seen its failure".
    ///
    /// ONE TRANSACTION, not two calls. Two calls would produce two saves, two
    /// change notifications and two CKRecord exports for one click, and would
    /// let a reload land between them and render the row half-updated.
    func markViewedAndAcknowledgeFailure(
        _ conversationID: UUID,
        lastActivityAt: Date?,
        attemptID: UUID?,
        now: Date = Date()
    ) {
        // The clamp still decides the marker, but the acknowledgement must go
        // through even when the overlay does not move — the user has seen this
        // failure either way.
        let marker = stampOverlay(conversationID, lastActivityAt: lastActivityAt, now: now)
            ?? Self.clamped(existing: overlay[conversationID]?.viewedAt, reference: lastActivityAt, now: now)
        Task { [weak self, writer] in
            await writer.markConversationViewedAndAcknowledged(
                conversationID,
                at: marker,
                attemptID: attemptID
            )
            self?.settle(conversationID, marker: marker)
        }
    }

    /// Drop the in-memory echo for a conversation the user actually deleted.
    ///
    /// There is nothing durable to delete: the markers are columns on the
    /// conversation and die with it by cascade. What is left is this device's
    /// overlay entry, which would otherwise sit until its TTL, and the
    /// conversation's legacy key, which can never fold now that its record is
    /// gone. A real deletion is the ONE authoritative signal that the key is
    /// dead — absence from a fetch is not one, because an offline launch reads a
    /// partial local mirror before the CloudKit import lands.
    func forget(_ conversationID: UUID) {
        overlay.removeValue(forKey: conversationID)
        if legacyReadMarkers.removeValue(forKey: conversationID) != nil {
            defaults.removeObject(
                forKey: Constants.conversationReadStatePrefix + conversationID.uuidString
            )
        }
    }

    // MARK: - Reconcile

    /// Retire overlay entries the records have caught up with, and fold whatever
    /// legacy keys those records make foldable.
    ///
    /// CALLED WITH THE LIST A SURFACE HAS JUST FETCHED, on the same main-actor
    /// turn it assigns it — beside `InFlightTurnRegistry.reconcile()`, which
    /// exists for exactly that reason. Doing it here rather than inside a read
    /// is what keeps reads pure: an `@Observable` mutation from inside a SwiftUI
    /// `body` is a rendering error, and a read that retired its own overlay
    /// would race every other row's read in the same pass.
    ///
    /// ABSENCE FROM `records` MEANS NOTHING. Entries for conversations not in
    /// this fetch are left exactly as they are — a filtered list, a partial
    /// local mirror before the import lands, and a real deletion are
    /// indistinguishable from here, and only the last of them justifies dropping
    /// anything (`forget(_:)`).
    func reconcile(with records: [ConversationRecord], now: Date = Date()) {
        var survivors = overlay

        // 1. The record has caught up: it carries a marker at least as new as
        //    the intent, so the echo has nothing left to add.
        for record in records {
            guard let entry = survivors[record.id], let recorded = record.lastViewedAt else { continue }
            if recorded >= entry.viewedAt { survivors.removeValue(forKey: record.id) }
        }

        // 2. The hard TTL, counted from CONFIRMATION. An entry whose write is
        //    still in flight is skipped — expiring it would revert the row under
        //    a user whose save simply has not returned yet.
        for (id, entry) in survivors {
            guard let settledAt = entry.settledAt else { continue }
            if now.timeIntervalSince(settledAt) > Self.overlaySettledTTL {
                survivors.removeValue(forKey: id)
            }
        }

        if survivors != overlay { overlay = survivors }

        drainLegacyMarkers(against: records)
    }

    // MARK: - Legacy drain

    /// Fold the legacy read keys of the conversations in this fetch, a bounded
    /// batch at a time.
    ///
    /// PER CONVERSATION ACTUALLY PRESENT, never a sweep over the keys: a key
    /// whose conversation has not imported yet has nothing to fold into, and
    /// treating its absence as "nothing to do" is exactly the one-shot migration
    /// this design rejects.
    private func drainLegacyMarkers(against records: [ConversationRecord]) {
        guard !legacyReadMarkers.isEmpty else { return }
        var dispatched = 0
        for record in records {
            guard dispatched < Self.maxLegacyFoldsPerPass else { break }
            let id = record.id
            guard let marker = legacyReadMarkers[id], !foldsInFlight.contains(id) else { continue }
            foldsInFlight.insert(id)
            dispatched += 1
            Task { [weak self, writer] in
                let outcome = await writer.foldLegacyReadMarker(id, localMarker: marker)
                self?.completeFold(id, outcome: outcome)
            }
        }
    }

    /// CONFIRM, THEN HAND OVER, THEN DELETE. The key is removed only when the
    /// store has said the record covers it — `.saved` because it now does,
    /// `.alreadyCovered` because it already did. A `.failed` fold keeps the key,
    /// so it keeps answering reads and the next reconcile pass retries it;
    /// deleting on anything less than a confirmation is how a marker gets lost.
    ///
    /// AND CONFIRMATION IS NOT THE SAME EVENT AS THIS DEVICE SEEING THE RECORD.
    /// The fold posts no change notification (deliberately — one whole-list
    /// refetch per folded key, in batches, on the launch that is already paying
    /// for the migration), so the records this device is rendering still carry
    /// the old `lastViewedAt` when the confirmation lands. Removing the marker
    /// here without replacing it would drop it out of `lastViewed`'s fold while
    /// nothing else answered for it, and every row that legacy key covered would
    /// repaint bold on the spot. Handing it to the overlay keeps the answer
    /// identical — same value, same `max`, one map over instead of the other —
    /// and it inherits the retirement that actually checks: `reconcile(with:)`
    /// step 1 drops it when a FETCHED record is observed to carry it. Marked
    /// settled, because the write it echoes has already returned; nothing
    /// durable is lost if the process dies, since the record is what confirmed.
    private func completeFold(_ conversationID: UUID, outcome: ReadMarkerFoldOutcome) {
        foldsInFlight.remove(conversationID)
        switch outcome {
        case .alreadyCovered, .saved:
            if let marker = legacyReadMarkers.removeValue(forKey: conversationID) {
                adoptFoldedMarker(conversationID, marker: marker)
            }
            defaults.removeObject(
                forKey: Constants.conversationReadStatePrefix + conversationID.uuidString
            )
        case .failed:
            break
        }
    }

    /// Move a just-confirmed legacy marker into the overlay.
    ///
    /// `max` against whatever the overlay already holds, like every other fold
    /// in this file: a marker older than a live local intent adds nothing, and
    /// replacing a larger value with a smaller one is the one direction no
    /// source here is ever allowed to move. Replacing an UNSETTLED entry is safe
    /// — the in-flight `settle` is guarded on the marker still matching, so it
    /// becomes a no-op rather than starting a TTL on a value it did not write.
    private func adoptFoldedMarker(_ conversationID: UUID, marker: Date) {
        guard (overlay[conversationID]?.viewedAt ?? .distantPast) < marker else { return }
        overlay[conversationID] = Overlay(viewedAt: marker, settledAt: Date())
        boundOverlay()
    }

    // MARK: - Shared mechanics

    /// Stamp the overlay, returning the marker when it actually moved and nil
    /// when it did not.
    ///
    /// Nil is the COALESCING point: a thread open across many tails re-stamps
    /// with the same clamped value, and dispatching a store write per tail would
    /// export a CKRecord per tail for a value the record already holds.
    private func stampOverlay(
        _ conversationID: UUID,
        lastActivityAt: Date?,
        now: Date
    ) -> Date? {
        let existing = overlay[conversationID]?.viewedAt
        let marker = Self.clamped(existing: existing, reference: lastActivityAt, now: now)
        guard marker != existing else { return nil }
        overlay[conversationID] = Overlay(viewedAt: marker, settledAt: nil)
        boundOverlay()
        return marker
    }

    /// Start the TTL clock for an entry whose store write has returned.
    ///
    /// Guarded on the marker still matching: a newer stamp landed while this
    /// write was in flight means a LATER write is still in flight, and settling
    /// on the older confirmation would let the TTL expire an intent the store
    /// has not seen.
    private func settle(_ conversationID: UUID, marker: Date) {
        guard var entry = overlay[conversationID],
              entry.viewedAt == marker,
              entry.settledAt == nil else { return }
        entry.settledAt = Date()
        overlay[conversationID] = entry
    }

    /// CLAMPED AND MONOTONIC:
    ///     newMarker = max(existing, reference.map { min($0, now + grace) } ?? now)
    ///
    /// - THE MARKER IS ANCHORED TO WHAT IT HAS TO COVER, NOT TO THE CLOCK, and
    ///   that is what makes every "write only when the value moves" guard
    ///   downstream able to fire at all. `reference` is the conversation's
    ///   `lastActivityAt` — the exact value the unseen test compares against,
    ///   and the test is STRICT (`lastActivityAt > effectiveViewedAt`), so a
    ///   marker EQUAL to it already reads as seen. Anchoring at `Date()`
    ///   instead would produce a strictly larger value on every single call, so
    ///   `stampOverlay`'s `marker != existing` and `ConversationStore
    ///   .applyViewed`'s `date <= stored` could never be true: re-opening,
    ///   re-activating or re-stamping an UNCHANGED thread would save, post
    ///   `.conversationsDidChange` and export a CKRecord every time. One macOS
    ///   window activation alone drives two of those arms. With the anchor here,
    ///   a repeat view of a thread whose tail has not moved computes the
    ///   identical marker and writes nothing.
    /// - `max(existing, …)` — a local clock that moves backwards can never
    ///   resurrect already-acknowledged state, and a caller holding a STALE
    ///   `reference` (a thread whose messages have not loaded yet) can never
    ///   drag the marker back behind one that already covers more.
    /// - `min(reference, now + grace)` — a row mirrored from a device whose
    ///   clock is a month fast cannot poison this marker into the future and
    ///   suppress a month of genuinely new activity. The residual failure on
    ///   such a device is a stuck marker, not silence — and it is bounded from
    ///   the other side too: `ConversationStore.appendStamp` declines to follow
    ///   a mirrored `lastActivityAt` further than this same grace, so the next
    ///   turn into that conversation pulls its activity stamp back inside the
    ///   ceiling and the marker covers it again.
    /// - `?? now` — no reference at all (a conversation with no messages, or a
    ///   surface that stamped before its fetch landed) has nothing to anchor to,
    ///   and the clock is then the only honest answer.
    ///
    /// - `TailProjection.canonical` — the marker settles on the SAME millisecond
    ///   grid the activity stamps use. Both values cross the mirror as CloudKit
    ///   dates, so a marker carrying sub-millisecond precision can come back
    ///   from a peer quantised DOWNWARD, and the unseen test is strict: a marker
    ///   that covered its tail exactly would land a hair behind it and paint an
    ///   already-read row unread. Canonicalising the CANDIDATE rather than the
    ///   result keeps the `max` monotone even against a legacy off-grid value.
    ///
    /// PURE AND STATIC so it can be tested directly, without a store, a defaults
    /// double or an overlay: it is the one piece of arithmetic in this file that
    /// has to be right on a badly-behaved clock.
    static func clamped(existing: Date?, reference: Date?, now: Date) -> Date {
        let candidate = reference.map { min($0, now.addingTimeInterval(clockSkewGrace)) } ?? now
        return max(existing ?? .distantPast, TailProjection.canonical(candidate))
    }

    /// Memory guard on the overlay — see `maxOverlayEntries`.
    ///
    /// Drops the OLDEST settled entries first and NEVER an unsettled one: an
    /// entry whose write is still in flight is the only kind that can revert a
    /// row under the user, which makes the ceiling deliberately soft. Unsettled
    /// entries live for the length of one save, so the soft case does not
    /// survive a runloop turn in practice.
    private func boundOverlay() {
        guard overlay.count > Self.maxOverlayEntries else { return }
        let doomed = overlay
            .filter { $0.value.settledAt != nil }
            .sorted { $0.value.viewedAt < $1.value.viewedAt }
            .prefix(overlay.count - Self.maxOverlayEntries)
        for (id, _) in doomed { overlay.removeValue(forKey: id) }
    }

    /// Bound the undrainable residue — see `maxLegacyMarkers`. Oldest first: an
    /// old marker's conversation is far down a list sorted by activity, so it is
    /// the least likely to still matter, and dropping it costs at worst one row
    /// arriving bold once.
    private func boundLegacyMarkers() {
        guard legacyReadMarkers.count > Self.maxLegacyMarkers else { return }
        let doomed = legacyReadMarkers
            .sorted { $0.value < $1.value }
            .prefix(legacyReadMarkers.count - Self.maxLegacyMarkers)
        for (id, _) in doomed {
            legacyReadMarkers.removeValue(forKey: id)
            defaults.removeObject(forKey: Constants.conversationReadStatePrefix + id.uuidString)
        }
    }

    // MARK: - Testing

    /// Test-only reset hook. Clears the in-memory state AND the backing keys so
    /// test order cannot leak state through the shared instance.
    static func _resetForTesting() {
        let store = shared
        store.overlay.removeAll()
        store.legacyReadMarkers.removeAll()
        store.foldsInFlight.removeAll()
        store.accountCutover = nil
        store.cutoverMintedThisLaunch = false
        store.hasProcessedCloudDelivery = false
        for key in store.defaults.dictionaryRepresentation().keys
        where key.hasPrefix(Constants.conversationReadStatePrefix)
            || key.hasPrefix(Constants.conversationFailureSeenPrefix) {
            store.defaults.removeObject(forKey: key)
        }
        store.defaults.removeObject(forKey: Constants.conversationReadStateEpochKey)
        // The account register too — a suite that left a cutover in the shared
        // KVS double would hand the next one an account value it never set, and
        // `min` makes that stick rather than being overwritten.
        //
        // `isObservingCloudCutover` is deliberately NOT reset: the registration
        // it guards cannot be withdrawn, so clearing it would stack a second
        // observer on the same instance for every suite that reset.
        store.ubiquitous.removeObject(forKey: Constants.conversationReadCutoverKVSKey)
    }
}
