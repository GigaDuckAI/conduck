// SPDX-License-Identifier: Apache-2.0

// Conduck
// AppleRelayPendingQueue.swift (Watch target)
//
// Deferred-relay queue for iPhone-relayed STT on Watch (Apple on-device + BYO custom
// endpoint). The queue is the DURABILITY layer of the claim-token design:
//
//   • ENQUEUE-FIRST: `WatchRecordingService.runRelay` persists an entry
//     (with its caller-minted `requestID`) BEFORE the first delivery attempt,
//     so process death never strands audio mid-relay.
//   • QUEUE-OWNED AUDIO: `enqueue` MOVES the clip into
//     `<App-Group container>/PendingRelay/<requestID>.m4a` — tmp is
//     OS-purgeable on a deferred timescale; the App-Group container is not.
//   • CLAIM = the exactly-once dispatch token: `claimEntry(requestID:)` is a
//     synchronous remove-and-return (deletes the audio, cancels any matching
//     outstanding WCSessionFileTransfer). Every converse hop / terminal
//     notification is preceded by a successful claim, so at most ONE agent
//     hop per requestID can ever happen — no matter how a live success, a
//     late `reconcile`, and a `drain` re-fire interleave.
//   • CONVERGENCE: re-fires reuse the entry's PERSISTED requestID, so the
//     iPhone's dedup ledger answers a retry from its reply cache instead of
//     re-transcribing.
//   • RETRYABLE ≠ TERMINAL: a failed attempt claims the entry — which DELETES
//     the user's audio — only when the verdict is terminal. Retryable verdicts
//     leave it queued for a later re-fire (`leavesEntryQueued(after:)`), and
//     `enforceCaps` is what stops that from being unbounded.
//
// **DESIGN CHOICE — separate queue, not an extension of WatchAudioUploader.**
//   `WatchAudioUploader` is tightly coupled to background URLSession,
//   provider transport (multipart/JSON), provider-specific decode, and a
//   shape-pinned `taskDescription` payload (`STTBackgroundTaskMetadata`).
//   A relay-pending entry has none of that surface — it's a plain audio
//   file URL + language hint. Cramming Apple-relay state into the
//   uploader would force conditional `transport == .inProcess` branches
//   into a URLSession-shaped class, muddy `multipartTempFiles` semantics
//   (which expects a body file alongside an audio file, not a single
//   audio file), and conflate cleanup ownership across two unrelated
//   delivery channels. The two queues are structurally cleaner separate.
//
// Persistence: `[Entry]` serializes to a single `Data` blob in App-Group
// UserDefaults. `Entry.requestID` is ADDITIVE Codable — legacy persisted
// blobs (pre-claim-token) decode `nil` and `drain()` mints + persists an id
// before re-firing them. Orphan sweep at init in BOTH directions (files
// with no entry → delete; entries with no file → drop) keeps the owned
// audio directory and the entry list mutually consistent across crashes.
//
//   • DESTINATION-SPECIFIC RETENTION: a WORK entry is the only copy of a
//     recording the person meant to keep, and there is no gateway waiting on
//     it, so it is exempt from both caps — it never ages out and is never
//     evicted to make room. The pressure is answered at the OTHER end instead:
//     a new Work capture is REFUSED while the queue is full
//     (`refusesNewWorkCapture(queueDepth:)`), which loses nothing, where an
//     eviction would delete audio that exists nowhere else. Chat entries keep
//     both caps unchanged — a transcript arriving a day after the ask has lost
//     its conversation, and the iPhone still holds nothing of it.
//
// Privacy invariant: never log file paths, language hints, audio bytes,
// transcripts, or full requestIDs (`prefix(8)` only).

import CryptoKit
import Foundation
import UserNotifications
import WatchConnectivity

/// Persistent FIFO queue of audio relays waiting on an iPhone verdict.
/// Singleton; main-actor isolated so the SwiftUI surface can read
/// `entryCount` without a hop and so claim/reconcile/drain serialize
/// against `WatchRecordingService` (also main-actor) by construction.
@MainActor
final class AppleRelayPendingQueue {
    static let shared = AppleRelayPendingQueue()

    /// Single persisted Entry. Codable so the whole list serializes to
    /// a single `Data` blob in UserDefaults.
    struct Entry: Codable, Equatable {
        let audioFilePath: String
        let language: String?
        let enqueuedAt: TimeInterval
        /// Custom-STT V1.x: which STT provider the iPhone should run for this
        /// relayed clip on a deferred re-fire. Nil ⇒ Apple on-device (the
        /// legacy path — a persisted v1 blob predating this field decodes nil,
        /// so old queued entries still route to Apple). `"custom-openai"` ⇒ the
        /// iPhone routes to the BYO custom endpoint, so a timed-out custom relay
        /// re-fires to the user's own server rather than silently switching to
        /// Apple. Never carries a key or URL.
        var providerID: String?
        /// Bound-thread pin for the deferred converse hop: the conversation the
        /// original capture was composed into (in-thread composer voice), or
        /// nil for headless captures — nil falls through the normal resolver on
        /// drain. Additive like `providerID` (a persisted blob predating this
        /// field decodes nil).
        var conversationID: String?
        /// The gateway the capture was ADDRESSED to, when the capture named one
        /// and no conversation existed yet — the Ask chooser's pick for a `.new`
        /// draft. Persisted for the same reason `conversationID` is: the reply
        /// that settles this entry may land in a process that never saw the
        /// pick, and without it the deferred hop falls through to the pointer /
        /// default arms and delivers words addressed to one gateway to another.
        /// Additive Codable (a blob predating the field decodes nil ⇒ resolve as
        /// before), and written ONLY for a chat entry with no pin, so every
        /// other entry's serialized shape is byte-identical to what it was.
        var backendRef: String?
        /// Claim-token correlation id — the SAME id every delivery attempt for
        /// this entry uses, so the iPhone dedup ledger converges retries onto
        /// one transcription. Additive Codable: a legacy blob decodes nil and
        /// `drain()` mints + persists one BEFORE the first re-fire.
        var requestID: String?
        /// Timestamp of the most recent delivery attempt (refreshed on every
        /// drain re-fire). Outstanding-transfer staleness is measured from
        /// THIS, never from the immutable `enqueuedAt` — measuring from
        /// enqueue would make every drain run cancel a possibly-healthy
        /// in-progress transfer once the entry crossed the 10-min mark,
        /// restarting big (>50 KB) clips from scratch forever (delivery
        /// livelock). Additive Codable like `requestID`: blobs predating the
        /// field decode nil → staleness falls back to `enqueuedAt`.
        var lastAttemptAt: TimeInterval?
        /// Where this capture lands once the iPhone answers — the raw value of
        /// `WatchCaptureDestination`. Additive Codable, and nil ⇒ `.chat`: a
        /// blob persisted before Work existed decodes nil and keeps its old
        /// meaning exactly. Stored ONLY for `.work`, so a chat entry's
        /// serialized shape is byte-identical to what it always was.
        ///
        /// This field is what makes the queue destination-aware AFTER a
        /// relaunch, which is the whole point: the reply that settles an entry
        /// may arrive in a process that never saw the capture, and it is this
        /// value — not any in-memory state — that keeps a Work capture out of
        /// the converse hop.
        var destination: String?

        /// Decoded destination, with the legacy reading built in.
        var captureDestination: WatchCaptureDestination {
            destination.flatMap(WatchCaptureDestination.init(rawValue:)) ?? .chat
        }
    }

    /// User-facing observable count for the recording view's "Sent ·
    /// awaiting iPhone" affordance. Read-only externally.
    private(set) var entryCount: Int = 0

    /// In-flight retry guard — prevents two simultaneous `drain()` runs
    /// (e.g., one from a reachability flip and one from an idle edge).
    private var isDraining = false

    private static let storageKey = "conduck.watch.applerelay.pending.v1"

    // MARK: - Tuning constants

    /// Hard cap on queued relays. The wrist flow is single-recording-at-a-
    /// time, so double digits of stranded asks means something is badly wrong
    /// (iPhone gone for days) — keep the newest, evict the oldest CHAT entry.
    /// Internal so the capture entry point can refuse a new WORK capture at the
    /// cap rather than evicting one (see `refusesNewWorkCapture`).
    static let maxEntryCount = 10

    /// Max queue residency for a CHAT entry. A transcript landing >24 h after
    /// the ask has lost its conversational context — surfacing it then is worse
    /// than telling the user it expired. A WORK entry has no conversation to go
    /// stale against and no second copy anywhere, so the age cap does not apply
    /// to it.
    static let maxEntryAge: TimeInterval = 24 * 60 * 60

    /// An outstanding `WCSessionFileTransfer` whose LAST ATTEMPT
    /// (`Entry.lastAttemptAt`, fallback `enqueuedAt`) is older than this is
    /// presumed wedged (the outbox normally clears in seconds-to-minutes
    /// once the phone is in range) — cancel it and re-fire fresh with the
    /// SAME requestID.
    private static let staleTransferRefireAge: TimeInterval = 10 * 60

    /// App-Group-scoped store so the queue is co-located with the other Watch
    /// persistence (Settings, identity, retry store).
    private var defaults: any DefaultsStore {
        SettingsDependencies.processDefault.defaults
    }

    // MARK: - Queue-owned audio storage

    private static let audioDirectoryName = "PendingRelay"

    /// Durable audio home: `<App-Group container>/PendingRelay/`. The
    /// App-Group container is NOT subject to the tmp-directory purge policy,
    /// so a queued clip survives until WE delete it (claim / eviction /
    /// orphan sweep) — the old tmp-resident files could be reclaimed by the
    /// OS while an entry still pointed at them.
    private var audioDirectory: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: Constants.appGroupID)?
            .appendingPathComponent(Self.audioDirectoryName, isDirectory: true)
    }

    private init() {
        sweepOrphans()
    }

    // MARK: - Public API

    /// Persist a new relay entry BEFORE the first delivery attempt
    /// (enqueue-first invariant) and take ownership of the audio: the clip is
    /// MOVED from the caller's (purgeable tmp) URL into the queue-owned
    /// App-Group directory as `<requestID>.m4a`. Returns the queue-owned URL —
    /// callers MUST relay from the returned URL, not the one they passed in.
    ///
    /// `providerID` is additive (nil ⇒ Apple on-device); `conversationID`
    /// (additive, nil ⇒ headless) carries the bound-thread pin so the deferred
    /// converse hop lands in the conversation the user composed in.
    ///
    /// `destination` decides what a settled reply MEANS for this entry, and it
    /// is persisted rather than remembered: the reply may land in a process
    /// that never saw the capture.
    @discardableResult
    func enqueue(
        requestID: String,
        audioFileURL: URL,
        language: String?,
        providerID: String? = nil,
        conversationID: UUID? = nil,
        backendRef: String? = nil,
        destination: WatchCaptureDestination = .chat
    ) -> URL {
        let ownedURL = takeOwnership(of: audioFileURL, requestID: requestID)
        var entries = loadEntries()
        entries.append(
            Entry(
                audioFilePath: ownedURL.path,
                language: language,
                enqueuedAt: Date().timeIntervalSince1970,
                providerID: providerID,
                conversationID: conversationID?.uuidString,
                // A pin and a ref are mutually exclusive answers to "where does
                // this land": a pinned entry already names its conversation, and
                // that conversation names its own gateway.
                backendRef: conversationID == nil ? backendRef : nil,
                requestID: requestID,
                // The first attempt follows enqueue immediately (enqueue-first
                // in `runRelay`), so the nil→`enqueuedAt` staleness fallback
                // is exact for it; only drain re-fires stamp this.
                lastAttemptAt: nil,
                // Chat persists NOTHING here, so its blob keeps the shape it
                // had before Work existed and round-trips through the same
                // nil ⇒ chat reading a legacy blob takes.
                destination: destination == .chat ? nil : destination.rawValue
            )
        )
        save(entries)
        entryCount = entries.count
        WatchLog.note(.queue, "queue.enqueue", ["id": WatchLog.shortID(requestID), "depth": entries.count])
        return ownedURL
    }

    /// THE exactly-once dispatch token. Synchronously remove-and-return the
    /// entry for `requestID`: deletes its queue-owned audio file and cancels
    /// any matching outstanding `WCSessionFileTransfer` (a claimed entry must
    /// leave nothing in flight that could trigger a second verdict).
    ///
    /// Returns nil when no entry matches — the verdict was already consumed
    /// by a racing path (live success vs late reconcile vs drain re-fire) or
    /// the entry was evicted; callers treat claim-nil as "drop silently".
    func claimEntry(requestID: String) -> Entry? {
        var entries = loadEntries()
        guard let index = entries.firstIndex(where: { $0.requestID == requestID }) else {
            WatchLog.note(.queue, "queue.claim", ["id": WatchLog.shortID(requestID), "ok": false])
            return nil
        }
        let entry = entries.remove(at: index)
        save(entries)
        entryCount = entries.count
        WatchLog.note(.queue, "queue.claim", ["id": WatchLog.shortID(requestID), "ok": true])
        // Cancel BEFORE deleting the audio — a mid-flight transfer must be
        // CANCELLED, not left to fail on a file that just vanished under it.
        cancelOutstandingTransfers(requestID: requestID)
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: entry.audioFilePath))
        return entry
    }

    /// NON-DESTRUCTIVE lookup of the entry for `requestID`.
    ///
    /// The destination has to be known BEFORE the claim, and the claim is what
    /// returns the entry today. That ordering is load-bearing for exactly one
    /// case: a Work reply that carries no durability stamp must have its words
    /// on the desk before anything deletes the recording, so the settlement
    /// path reads the entry, decides, and only then claims.
    func peekEntry(requestID: String) -> Entry? {
        loadEntries().first { $0.requestID == requestID }
    }

    /// Late-reply convergence: a verdict arrived with NO live continuation
    /// (the relay timed out, or the process restarted since the request
    /// left). Claim-token semantics decide what happens:
    ///
    ///   • `.failure(retryable)` → what refused can still clear (the iPhone
    ///     signalled "can't run this now", its Keychain has not been unlocked,
    ///     the provider is down) — leave the entry queued for a later drain
    ///     (`leavesEntryQueued(after:)`).
    ///   • Live turn in progress (`canAcceptDeferredDispatch == false`) → do
    ///     NOT claim; leave the entry. The idle-edge drain re-fires with the
    ///     same requestID and the iPhone's reply cache answers instantly —
    ///     one cheap extra round trip in a rare race beats a third entry
    ///     lifecycle stage.
    ///   • Claim-nil → duplicate/evicted verdict → drop silently.
    ///   • `.success` → shared `settleSuccess`, which branches on the entry's
    ///     persisted destination: Chat claims and dispatches the converse hop;
    ///     Work claims and reports, and NEVER reaches a hop.
    ///   • `.failure(terminal)` → clear the deferral toast (its promise just
    ///     became false) + error notification (claim already removed the
    ///     entry + audio).
    func reconcile(requestID: String, outcome: RelayReplyOutcome) async {
        if case .failure(let error) = outcome {
            // Read the entry's PERSISTED destination BEFORE deciding: an
            // unacknowledged Work capture is retained after any failure, and the
            // claim below is what deletes the recording. Peeking is what makes
            // that possible — claiming is the only other way to see an entry,
            // and by then the audio is gone. A missing entry reads as chat,
            // which is what the claim-nil drop already assumes.
            let destination = peekEntry(requestID: requestID)?.captureDestination ?? .chat
            if Self.leavesEntryQueued(after: error, destination: destination) {
                WatchLog.note(.queue, "queue.reconcile.requeued", [
                    "id": WatchLog.shortID(requestID),
                    "code": error.errorCode
                ])
                return
            }
        }
        guard WatchRecordingService.shared.canAcceptDeferredDispatch else {
            WatchLog.note(.queue, "queue.reconcile.deferred", ["id": WatchLog.shortID(requestID)])
            return
        }
        if case .success(let reply) = outcome {
            // The success lane claims INSIDE the settlement, because a Work
            // entry's claim is conditional on a desk write succeeding first.
            await settleSuccess(requestID: requestID, reply: reply)
            return
        }
        guard claimEntry(requestID: requestID) != nil else {
            WatchLog.note(.queue, "queue.reconcile.drop", ["id": WatchLog.shortID(requestID)])
            return
        }
        switch outcome {
        case .success:
            // Handled above; the compiler wants the arm.
            return
        case .failure(let error):
            // Failure terminal must ALSO clear the deferral toast — leaving
            // "your transcript will arrive when it reconnects" on screen
            // after the verdict came back permanent would be a now-false
            // promise. Provenance-gated inside the service, so an unrelated
            // error toast is never stomped.
            WatchRecordingService.shared.clearRelayDeferralError()
            postErrorNotification(error: error)
        }
    }

    /// Drain all queued entries by re-firing the relay with each entry's
    /// PERSISTED requestID. Triggered by app launch, reachability flips, and
    /// every return-to-idle edge of the recording service (incl. dismissing
    /// the deferral toast — the old `.idle`-only gate deadlocked behind the
    /// timeout toast until the user tapped X). No-ops if a drain is already
    /// in flight or the queue is empty.
    func drain() async {
        guard !isDraining else { return }
        guard !loadEntries().isEmpty else { return }
        guard WCSession.default.activationState == .activated else { return }

        isDraining = true
        defer { isDraining = false }

        // Depth intentionally omitted — `enqueue`/`evict` already carry it, and
        // re-decoding the queue blob here purely for the field would be wasteful.
        WatchLog.note(.queue, "queue.drain.start")

        // Caps first, so a wedged backlog ages out instead of being retried
        // forever ahead of fresh asks.
        let entries = enforceCaps(loadEntries())

        for entry in entries {
            // Deferred dispatch must never clobber a LIVE turn: drain fires on
            // reachability flips + launch + idle edges — exactly when the user
            // may be re-engaging. The gate accepts `.idle` OR the relay-
            // deferral toast (which the deferred work itself resolves); any
            // other state → stop and LEAVE the remaining entries queued for
            // the next drain. This also serializes multi-entry drains: the
            // first dispatched hop moves the machine to `.waiting`, so entry 2
            // waits for a later drain instead of stomping entry 1's pin +
            // on-screen state.
            guard WatchRecordingService.shared.canAcceptDeferredDispatch else { return }

            // Defensive: the file may have vanished (legacy tmp-resident entry
            // purged by the OS; queue-owned files only vanish if WE deleted
            // them). No payload → nothing to re-fire.
            guard FileManager.default.fileExists(atPath: entry.audioFilePath) else {
                WatchLog.note(.queue, "queue.drop.missing", ["id": WatchLog.shortID(entry.requestID ?? "")])
                removeEntry(entry)
                continue
            }

            // Claim-token: re-fires MUST reuse the entry's persisted requestID
            // so the iPhone dedup ledger converges (a cached verdict answers a
            // retry instantly, never re-transcribing). Legacy blobs decode a
            // nil requestID — mint + persist one BEFORE the first re-fire so
            // even that attempt is convergeable.
            let requestID: String
            if let persisted = entry.requestID {
                requestID = persisted
            } else {
                requestID = UUID().uuidString
                persistRequestID(requestID, forLegacy: entry)
            }

            // A prior attempt's file transfer may still sit in the WCSession
            // outbox — re-sending would double-deliver, so SKIP this entry and
            // let the transfer land... unless the LAST ATTEMPT is old enough
            // that the transfer is presumed wedged → cancel + re-fire fresh.
            // Staleness is measured from `lastAttemptAt` (fallback
            // `enqueuedAt` for blobs predating the field), NOT the immutable
            // enqueue time — otherwise once an entry crossed 10 min, EVERY
            // drain run would cancel its possibly-healthy in-progress
            // transfer and restart from byte zero: delivery livelock for
            // exactly the big (>50 KB) clips that need the file channel.
            var justCancelledTransfer = false
            if let transfer = outstandingTransfer(requestID: requestID) {
                let lastAttempt = entry.lastAttemptAt ?? entry.enqueuedAt
                let age = Date().timeIntervalSince1970 - lastAttempt
                guard age > Self.staleTransferRefireAge else { continue }
                transfer.cancel()
                justCancelledTransfer = true
                WatchLog.note(.queue, "queue.transfer.refire", ["id": WatchLog.shortID(requestID)])
            }

            // Stamp the attempt BEFORE firing so the NEXT drain measures
            // staleness from THIS attempt, not the original enqueue.
            touchLastAttempt(requestID: requestID)

            let url = URL(fileURLWithPath: entry.audioFilePath)
            do {
                let reply = try await AppleSpeechRelayCoordinator.shared.relay(
                    requestID: requestID,
                    audioFileURL: url,
                    language: entry.language,
                    providerID: entry.providerID,
                    // Re-fires carry the PERSISTED destination, not a live
                    // reading: this drain may be running in a process that
                    // never saw the capture, and a Work capture that lost its
                    // stamp here would come back as a chat ask and reach a
                    // gateway.
                    destination: entry.captureDestination,
                    // Just-cancelled transfers may linger in
                    // `outstandingFileTransfers` (removal timing is
                    // undocumented) — without the bypass, `deliver` would see
                    // the zombie, send NOTHING, and burn a full reply timeout.
                    skipOutstandingCheck: justCancelledTransfer
                )
                // The relay await can span a user interaction — re-check the
                // gate before dispatching. Busy now → leave the entry queued
                // and stop; the next drain's re-fire hits the iPhone reply
                // cache, so no re-transcription happens.
                guard WatchRecordingService.shared.canAcceptDeferredDispatch else { return }

                // Exactly-once: the claim IS the dispatch token, and it lives
                // INSIDE the settlement because a Work entry only earns it
                // once its words are on the desk. Claim-nil ⇒ a racing
                // reconcile already consumed this verdict → skip silently
                // (its outcome is the one that counts).
                await settleSuccess(requestID: requestID, reply: reply)
            } catch {
                // A verdict the SAME bytes can still succeed against leaves the
                // entry queued AND stops the drain: what refused is the iPhone's
                // ability to serve any relay at all right now (out of range, a
                // Keychain that has not been unlocked, a provider outage), not
                // this one clip — so the entries behind it would buy the
                // identical answer at the price of a file transfer and a reply
                // timeout each. The next trigger retries; the persisted
                // requestID is unchanged, so the iPhone's ledger converges the
                // re-fire. The entry (and its outstanding transfer, if any)
                // stays put.
                if Self.leavesEntryQueued(after: error, destination: entry.captureDestination) {
                    WatchLog.note(.queue, "queue.drain.requeued", [
                        "id": WatchLog.shortID(requestID),
                        "code": (error as? AppError)?.errorCode ?? -1
                    ])
                    // A Work entry retained on a TERMINAL verdict is a statement
                    // about this one clip, not about the iPhone — and Work never
                    // ages out, so stopping here would wedge every entry behind
                    // it forever. Move on instead; the next trigger re-fires
                    // this one.
                    guard Self.sameBytesCanStillSucceed(after: error) else { continue }
                    return
                }
                // Terminal failure for this entry (e.g. model not installed
                // on iPhone). Claim FIRST (claim-nil ⇒ a racing reconcile beat
                // us to the verdict → skip), then notify. The claim already
                // removed the entry + audio + outstanding transfer.
                guard claimEntry(requestID: requestID) != nil else { continue }
                // Failure terminal must ALSO clear the deferral toast — its
                // promise just became false (provenance-gated; an unrelated
                // error is untouched).
                WatchRecordingService.shared.clearRelayDeferralError()
                let appErr = error as? AppError ?? AppError.audioProcessingFailed
                postErrorNotification(error: appErr)
            }
        }
    }

    // MARK: - Retryable vs terminal

    /// Whether a failed delivery attempt LEAVES the entry queued for a later
    /// re-fire, instead of claiming it — and a claim deletes the audio the user
    /// already spoke into.
    ///
    /// The question is the taxonomy's own: `AppError.isRetryable`, the property
    /// every retry affordance in the app gates on. A retryable verdict is one
    /// the IDENTICAL bytes still succeed against once something OUTSIDE the
    /// request changes — the iPhone comes back in range, its Keychain is
    /// unlocked after a reboot, the provider's outage clears. Claiming on one of
    /// those destroys a capture the next attempt would have delivered (I6).
    /// A terminal verdict — an empty key slot, a model that isn't installed,
    /// audio the provider can't process — returns the same answer on every
    /// re-fire, so the entry is claimed and the user is told.
    ///
    /// A non-`AppError` throw is terminal: nothing in the taxonomy vouches for
    /// a retry, and an unrecognised failure that kept its entry would re-fire on
    /// a verdict no one can reason about.
    ///
    /// UNBOUNDED QUEUEING is prevented by `enforceCaps`, which runs at the head
    /// of every drain that gets past `drain()`'s own guards — always before any
    /// entry reaches this predicate, never after it returns true. A CHAT capture
    /// stranded on a condition that never clears ages out at `maxEntryAge` and
    /// the user hears about it through `postEvictionNotification`. There is
    /// deliberately no attempt counter: a Keychain blackout can outlive dozens
    /// of idle edges before the user next unlocks their phone, and a count would
    /// give up on a capture that one unlock would have delivered.
    ///
    /// WORK ANSWERS THE QUESTION DIFFERENTLY, and it is the destination — not
    /// the error — that decides. A chat entry's audio is a means to a transcript
    /// the iPhone has already produced or will refuse to produce again; a WORK
    /// entry's audio is the thing itself, and until the iPhone says it published
    /// it (`result.work == true`) or its words are on the desk, this queue holds
    /// the only copy in existence. So a Work entry is retained after ANY failed
    /// delivery — retryable or terminal — because "terminal" describes the
    /// attempt, and no attempt's verdict is worth the person's recording. An old
    /// iPhone that answers a Work capture with a terminal code (it predates the
    /// destination, so it has no Work branch at all and kept nothing itself)
    /// must not take the wrist's copy down with it. Work entries are exempt from
    /// both caps, so the compensating bound is `refusesNewWorkCapture`, which
    /// refuses a NEW capture at capacity rather than evicting an old one.
    ///
    /// `static` for `notificationBody`'s reason — it makes the classification
    /// reachable from `ConduckWatchTests` without the singleton's disk-touching
    /// `init`. The default argument keeps the chat reading callable as the bare
    /// predicate it has always been.
    static func leavesEntryQueued(
        after error: Error,
        destination: WatchCaptureDestination = .chat
    ) -> Bool {
        if destination == .work { return true }
        return sameBytesCanStillSucceed(after: error)
    }

    /// Whether the IDENTICAL bytes can still succeed against this verdict once
    /// something OUTSIDE the request changes — the iPhone comes back in range,
    /// its Keychain is unlocked after a reboot, the provider's outage clears.
    /// The taxonomy's own `AppError.isRetryable`, the property every retry
    /// affordance in the app gates on.
    ///
    /// It answers a SECOND question the retention rule cannot: whether the
    /// whole drain should stop. A retryable verdict is one the iPhone gave about
    /// ITSELF — it cannot serve any relay right now — so every entry behind this
    /// one would buy the identical answer at the price of a file transfer and a
    /// reply timeout each. A verdict about this ONE clip (a Work entry retained
    /// on a terminal code) says nothing about the entries behind it, and
    /// stopping there would wedge them behind a Work entry that never ages out.
    ///
    /// A non-`AppError` throw is not retryable: nothing in the taxonomy vouches
    /// for it, and an unrecognised failure that halted the drain would strand
    /// every queued ask on a verdict no one can reason about.
    static func sameBytesCanStillSucceed(after error: Error) -> Bool {
        (error as? AppError)?.isRetryable ?? false
    }

    // MARK: - Settlement

    /// What a settled SUCCESS reply means for one queue entry. The ONE place
    /// the destination decides the onward path, so no call site can reason its
    /// way to sending a Work capture at a gateway.
    enum RelaySettlement: Equatable {
        /// Chat: claim the entry, then dispatch the deferred converse hop.
        case converseHop
        /// Work, and the iPhone says it published the RECORDING
        /// (`result.work == true`): claim the entry — the phone's copy is now
        /// the durable one — and report it saved.
        case workAcknowledged
        /// Work, the iPhone published the RECORDING, and it had no words to
        /// send with it: transcription settled against this clip, so no re-fire
        /// will produce any. Claims exactly as `workAcknowledged` does — the
        /// phone holds the durable copy either way — and differs only in what
        /// the person is told, because a card they must open their iPhone to
        /// finish is not the same event as a card that is done.
        case workRecordingOnly
        /// Work, with a transcript but no durability stamp: an iPhone build
        /// that predates the Work destination transcribed the clip and kept
        /// nothing. The words are all that can be rescued, so they are written
        /// to the desk FIRST and the entry is claimed only if that write lands.
        case workWordsOnly
        /// Chat locally, Work on the receipt. `result.work == true` is written
        /// by ONE line on the iPhone (`workSaved = workCardID != nil`), so a
        /// reply carrying it is a reply about a capture that reached the DESK —
        /// while this entry's own destination says gateway. Both readings
        /// cannot be true, and the queue may not resolve the disagreement by
        /// picking the one that sends: this lane exists to keep a private
        /// thought off a gateway, and the two mistakes do not cost the same
        /// (a retained entry is a delayed ask; a dispatched one is a thought
        /// the person deliberately kept private, spoken to an agent). So
        /// nothing is claimed, nothing is sent, and the recording stays exactly
        /// where it is. Unreachable while the two halves agree, which is why an
        /// ordinary chat reply — whose stamp is absent — never meets it.
        case receiptContradictsDestination
    }

    /// The classification, pure. Absent destination already read as `.chat` by
    /// `Entry.captureDestination`, so this sees only the two real answers.
    /// `hasWords` is defaulted so every existing call site — and every
    /// assertion written against them — keeps its two-argument spelling; only
    /// the reply that carries the stamp WITHOUT a transcript needs the third
    /// answer.
    static func settlement(
        for destination: WatchCaptureDestination,
        workSaved: Bool,
        hasWords: Bool = true
    ) -> RelaySettlement {
        switch destination {
        case .chat:
            // The stamp is a SECOND witness to the destination, and it is
            // consulted only to refuse: a chat entry whose reply says the
            // iPhone put this capture on the desk is one of the two readings
            // being wrong, and neither can be trusted enough to send.
            return workSaved ? .receiptContradictsDestination : .converseHop
        case .work:
            guard workSaved else { return .workWordsOnly }
            return hasWords ? .workAcknowledged : .workRecordingOnly
        }
    }

    /// Whether a reply carries anything worth putting on a card. Whitespace is
    /// not: a card whose text is a space reads as transcribed and is not, and
    /// the words-only lane's `prepare` refuses the same value.
    static func carriesWords(_ text: String) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Apply a settled success verdict in the order its destination requires.
    ///
    /// The effects arrive as CLOSURES rather than direct calls because the two
    /// contracts that matter here cannot otherwise be observed without a paired
    /// iPhone, an activated `WCSession` and this singleton's disk-touching
    /// `init`:
    ///
    ///   1. a Work entry NEVER reaches the converse hop — the one path from
    ///      this queue to a gateway;
    ///   2. a words-only Work reply claims — and a claim DELETES the recording
    ///      — only after the desk write has succeeded. Claiming first would
    ///      trade the user's audio for a note that may never be written.
    ///
    /// `claim` answers false when a racing path already consumed the verdict;
    /// every arm then does nothing, which is the exactly-once rule.
    @MainActor
    static func applySettledSuccess(
        destination: WatchCaptureDestination,
        reply: RelayReply,
        claim: () -> Bool,
        completeChat: (String) async -> Void,
        writeWorkWords: (String) async -> Bool,
        finishWork: (RelaySettlement) -> Void
    ) async -> RelaySettlementResult {
        let outcome = settlement(
            for: destination,
            workSaved: reply.workSaved,
            hasWords: carriesWords(reply.text)
        )
        switch outcome {
        case .receiptContradictsDestination:
            // BEFORE the claim, deliberately: the claim deletes the recording,
            // and the one thing that is certain here is that we do not know
            // where this capture belongs. Nothing is consumed, so a re-fire —
            // or an operator who fixes the stamp — still has everything.
            return .destinationContradicted
        case .converseHop:
            guard claim() else { return .superseded }
            await completeChat(reply.text)
            return .applied(.converseHop)
        case .workAcknowledged, .workRecordingOnly:
            // One arm for both: the stamp is the durability claim, and the
            // presence of words changes only the sentence `finishWork` shows.
            guard claim() else { return .superseded }
            finishWork(outcome)
            return .applied(outcome)
        case .workWordsOnly:
            // Write, THEN claim. A failed write leaves the entry — and the
            // recording — exactly where they were, so the next drain tries
            // again (and an updated iPhone answers with the stamp instead).
            guard await writeWorkWords(reply.text) else { return .workWordsUnwritten }
            guard claim() else { return .superseded }
            finishWork(.workWordsOnly)
            return .applied(.workWordsOnly)
        }
    }

    /// What `applySettledSuccess` actually did. Three answers rather than a
    /// bool because the two non-applied ones ask opposite things of the caller:
    /// a superseded verdict means this turn is over and someone else owns it,
    /// while unwritten words mean the entry — and the person's recording — are
    /// still here and still waiting.
    enum RelaySettlementResult: Equatable {
        case applied(RelaySettlement)
        /// A racing path (a live reply vs a late reconcile vs a drain re-fire)
        /// already claimed this verdict.
        case superseded
        /// A Work reply's words could not be written to the desk, so nothing
        /// was claimed and nothing was lost.
        case workWordsUnwritten
        /// The reply and the entry disagree about where this capture belongs,
        /// so it was neither claimed nor delivered. Distinct from
        /// `workWordsUnwritten` because it is not a transient write failure the
        /// next drain fixes — it is a fault, and the log line is the only thing
        /// anyone can act on.
        case destinationContradicted
    }

    /// The ONE settled-success path — used by BOTH `drain()` and
    /// `reconcile(...)` so the two dispatch paths cannot diverge on the
    /// question this queue exists to answer correctly.
    private func settleSuccess(requestID: String, reply: RelayReply) async {
        guard let entry = peekEntry(requestID: requestID) else {
            WatchLog.note(.queue, "queue.settle.drop", ["id": WatchLog.shortID(requestID)])
            return
        }
        let result = await Self.applySettledSuccess(
            destination: entry.captureDestination,
            reply: reply,
            claim: { self.claimEntry(requestID: requestID) != nil },
            completeChat: { text in await self.completeEntry(entry, text: text) },
            writeWorkWords: { text in
                await self.writeWorkWords(
                    text,
                    requestID: requestID,
                    // The capture's own moment, not the reply's: a deferred
                    // Work note that reads as "now" would sort above cards the
                    // person added while the watch was waiting.
                    createdAt: Date(timeIntervalSince1970: entry.enqueuedAt)
                )
            },
            finishWork: { self.finishWorkEntry(entry, settlement: $0) }
        )
        switch result {
        case .applied:
            return
        case .superseded:
            WatchLog.note(.queue, "queue.settle.drop", ["id": WatchLog.shortID(requestID)])
        case .workWordsUnwritten:
            // Deliberately silent on the wrist: the entry is untouched, so the
            // next drain re-fires it, and by then the iPhone may well answer
            // with the durability stamp instead.
            WatchLog.note(.queue, "queue.settle.requeued", ["id": WatchLog.shortID(requestID)])
        case .destinationContradicted:
            // Silent on the wrist for the same reason and one more: there is no
            // true sentence to show. Saying "saved to Work" or "sent" would
            // each assert the half of the disagreement we refused to pick.
            WatchLog.error(.queue, "queue.settle.destinationMismatch", [
                "id": WatchLog.shortID(requestID),
                "entry": entry.captureDestination.rawValue
            ])
        }
    }

    /// Terminal for a WORK entry: the audio is gone (the claim deleted it, or
    /// the iPhone holds the durable copy), so the only thing left is to say so.
    ///
    /// The banner posts unconditionally rather than only when the app is
    /// backgrounded: a Work relay settles minutes after the wrist went dark in
    /// the case this path exists for, and a duplicate line on screen costs far
    /// less than a silent one that never arrives.
    private func finishWorkEntry(_ entry: Entry, settlement: RelaySettlement) {
        WatchLog.note(.queue, "queue.work.settled", [
            "id": WatchLog.shortID(entry.requestID ?? ""),
            "how": String(describing: settlement)
        ])
        // Claim already deleted the queue-owned audio; belt-and-braces for a
        // degraded entry whose clip never made it into the owned directory.
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: entry.audioFilePath))
        postWorkNotification(settlement)
        // The banner is for the capture that settled; the on-screen line is for
        // whatever capture the wrist is SHOWING, so the claim token travels with
        // the settlement and the service decides whether the two are the same
        // one. A deferred queue holds several Work captures at once, and a line
        // that says "Saved to Work." over a different, still-undelivered
        // recording is the one lie this surface must never tell.
        WatchRecordingService.shared.noteWorkCaptureSettled(
            settlement,
            requestID: entry.requestID
        )
    }

    /// Write a relayed transcript to the Work desk as a note. Returns false —
    /// and writes nothing — when the words cannot be prepared or the store
    /// refuses, which is the caller's signal to KEEP the entry.
    ///
    /// The card id is derived from the claim token, so the retry this queue is
    /// built around REPAIRS one card instead of piling up duplicates:
    /// `upsertDeskMaterial` is idempotent on `id`, and every re-fire reuses the
    /// entry's persisted requestID.
    ///
    /// An empty or unpreparable transcript therefore parks the entry rather
    /// than destroying it. That is the right trade even though a Work entry
    /// never ages out: the only build that reaches this path is an iPhone that
    /// predates the Work destination, and updating it turns the very next
    /// re-fire into a stamped reply that settles the entry properly.
    ///
    /// Internal so the LIVE relay leg in `WatchRecordingService.runRelay` mints
    /// the SAME id for the same capture — two writers of one card would be two
    /// cards.
    func writeWorkWords(_ text: String, requestID: String, createdAt: Date) async -> Bool {
        do {
            let capture = try WatchWorkboardCaptureText.prepare(text)
            _ = try await ConversationStore.shared.upsertDeskMaterial(
                capture,
                id: WatchWorkRelayNoteIdentity.materialID(forRequestID: requestID),
                createdAt: createdAt
            )
            return true
        } catch {
            WatchLog.error(.queue, "queue.work.note.failed", ["id": WatchLog.shortID(requestID)])
            return false
        }
    }

    // MARK: - Shared success path (Chat)

    /// The CHAT success block. Caller has ALREADY claimed the
    /// entry (entry removed, audio deleted, transfer cancelled).
    ///
    /// Clears the relay-deferral toast (its promise — "your transcript will
    /// arrive" — was just kept; provenance-gated inside the service so an
    /// unrelated error is never stomped), confirms the transcription via local
    /// notification (the recording UI has long since dismissed by the time a
    /// queued relay completes), then dispatches the converse hop so the
    /// transcribed ask actually reaches the agent — mirroring the live
    /// `runRelay` → `startConverseHop` chain.
    private func completeEntry(_ entry: Entry, text: String) async {
        WatchLog.note(.queue, "queue.complete", [
            "id": WatchLog.shortID(entry.requestID ?? ""),
            // The BINDING SHAPE, because one of its four combinations is a
            // known degradation and is otherwise invisible in the field: an
            // entry written by a build that predates `backendRef` carries
            // neither a pin nor a gateway, so the replay mints against the
            // CURRENT default. Delivering it is the honest answer (see the
            // resolver's replay comment) but it is still a guess, and this is
            // the only line that says a guess was made. Never the values —
            // ids and refs stay out of the log.
            "bound": entry.conversationID != nil,
            "addressed": entry.backendRef != nil
        ])
        postTranscriptNotification()
        // Claim already deleted the queue-owned audio; belt-and-braces for a
        // degraded entry whose clip never made it into the owned directory.
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: entry.audioFilePath))
        // Close the idle window END-TO-END on MainActor:
        // `clearRelayDeferralError()` lands the machine on `.idle`, and
        // `startDeferredConverseHop` re-occupies it SYNCHRONOUSLY
        // (`state = .waiting` before its first await). Nothing between these
        // two calls may suspend — otherwise a concurrently scheduled drain
        // Task / late reconcile / user capture could slip through the
        // `canAcceptDeferredDispatch` gate and dispatch a SECOND concurrent
        // hop (state + in-flight-marker clobber).
        WatchRecordingService.shared.clearRelayDeferralError()
        await Self.deferredChatDispatch(
            text,
            entry.conversationID.flatMap { UUID(uuidString: $0) },
            // The gateway this capture was addressed to, when it named one. Read
            // off the ENTRY, never recovered from the current default or from
            // another capture's live hint — an explicit choice that cannot be
            // read back is not one this queue may guess at.
            entry.backendRef
        )
    }

    /// The deferred CHAT dispatch. A SEAM, for one reason: the defect this call
    /// site keeps having is a DROPPED ARGUMENT — the entry's pin, or the
    /// gateway it was addressed to, not handed over — and no pure helper can
    /// catch that, because a helper that computes the binding is still passed
    /// (or not passed) here. Substituting it is how a test reads what this
    /// queue actually hands the service.
    ///
    /// Default is the real hop, and the real hop is the ONLY production value.
    static var deferredChatDispatch: @MainActor (String, UUID?, String?) async -> Void = liveDeferredChatDispatch

    /// The production dispatch, named so a test can put it back.
    static let liveDeferredChatDispatch: @MainActor (String, UUID?, String?) async -> Void = {
        transcript, conversationID, backendRef in
        await WatchRecordingService.shared.startDeferredConverseHop(
            transcript: transcript,
            boundTo: conversationID,
            addressedTo: backendRef
        )
    }

    // MARK: - Audio ownership

    /// Move the caller's clip into the queue-owned directory as
    /// `<requestID>.m4a`. Copy fallback if the move fails; if BOTH fail the
    /// entry degrades to tracking the caller's original URL (still functional
    /// while the tmp file survives — strictly better than dropping the ask).
    private func takeOwnership(of audioFileURL: URL, requestID: String) -> URL {
        guard let dir = audioDirectory else { return audioFileURL }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let destination = dir
            .appendingPathComponent(requestID)
            .appendingPathExtension("m4a")
        // requestID is a fresh UUID, so destination collisions shouldn't
        // exist — clear defensively so a half-written crash leftover can't
        // fail the move.
        try? FileManager.default.removeItem(at: destination)
        do {
            try FileManager.default.moveItem(at: audioFileURL, to: destination)
            return destination
        } catch {
            do {
                try FileManager.default.copyItem(at: audioFileURL, to: destination)
                try? FileManager.default.removeItem(at: audioFileURL)
                return destination
            } catch {
                return audioFileURL
            }
        }
    }

    /// Init-time consistency sweep, both directions:
    ///   • entries whose audio no longer exists → drop (nothing to re-fire);
    ///   • files in the owned directory with no entry → delete (claim or
    ///     eviction crashed between the entry-list write and the file
    ///     delete; without the sweep these would leak forever).
    private func sweepOrphans() {
        var entries = loadEntries()
        let beforeCount = entries.count
        entries.removeAll { !FileManager.default.fileExists(atPath: $0.audioFilePath) }
        if entries.count != beforeCount {
            save(entries)
            WatchLog.note(.queue, "queue.orphan", ["entriesDropped": beforeCount - entries.count])
        }
        entryCount = entries.count

        guard let dir = audioDirectory,
              let files = try? FileManager.default.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: nil
              ) else { return }
        // Match on filename (queue-owned files are `<requestID>.m4a`, and the
        // entry's stored path basename equals it) — robust against
        // `/private/var` vs `/var` path-prefix aliasing.
        let ownedNames = Set(entries.map { URL(fileURLWithPath: $0.audioFilePath).lastPathComponent })
        var orphanFiles = 0
        for file in files where !ownedNames.contains(file.lastPathComponent) {
            try? FileManager.default.removeItem(at: file)
            orphanFiles += 1
        }
        if orphanFiles > 0 {
            WatchLog.note(.queue, "queue.orphan", ["filesDeleted": orphanFiles])
        }
    }

    // MARK: - Caps

    /// The caps, PURE. Extracted from `enforceCaps` so the one rule that has no
    /// other way of being observed — a WORK entry is never evicted, for age or
    /// for room — is unit-testable without the singleton's disk-touching
    /// `init`, an App Group container or a `WCSession`.
    ///
    /// Work is exempt on BOTH axes because eviction means deleting the only
    /// copy of a recording the person meant to keep, and unlike a chat ask
    /// there is no conversation for it to go stale against. The queue's
    /// unboundedness is answered at the entry point instead
    /// (`refusesNewWorkCapture(queueDepth:)`), which costs a refusal the person
    /// can act on rather than audio they cannot get back.
    ///
    /// Count eviction therefore drops the OLDEST CHAT entry (FIFO order, so the
    /// first chat entry in the list) and stops when there is none left to drop
    /// — a queue of ten Work entries simply stays at ten, and the next Work
    /// capture is refused up front.
    static func applyCaps(to entries: [Entry], now: TimeInterval) -> (kept: [Entry], evicted: [Entry]) {
        var kept: [Entry] = []
        var evicted: [Entry] = []
        for entry in entries {
            if entry.captureDestination == .chat, now - entry.enqueuedAt > maxEntryAge {
                evicted.append(entry)
            } else {
                kept.append(entry)
            }
        }
        while kept.count > maxEntryCount,
              let index = kept.firstIndex(where: { $0.captureDestination == .chat }) {
            evicted.append(kept.remove(at: index))
        }
        return (kept, evicted)
    }

    /// Whether a NEW Work capture must be refused before the microphone arms.
    ///
    /// Work entries are eviction-exempt, so an eleventh would either break the
    /// cap or force the queue to delete a recording that exists nowhere else.
    /// Refusing costs the person one sentence and nothing they had already
    /// said; accepting costs them a capture they can never recover.
    static func refusesNewWorkCapture(queueDepth: Int) -> Bool {
        queueDepth >= maxEntryCount
    }

    /// Enforce the caps. Eviction = delete audio + cancel any outstanding
    /// transfer + post the expiry notification (the user's ask is being dropped
    /// — silent disposal would be a trust bug). Only CHAT entries are ever
    /// evicted, so the notice's wording holds for everything it can describe.
    /// Returns the surviving entries (persisted if anything was evicted).
    private func enforceCaps(_ entries: [Entry]) -> [Entry] {
        let (kept, evicted) = Self.applyCaps(to: entries, now: Date().timeIntervalSince1970)
        for entry in evicted {
            WatchLog.note(.queue, "queue.evict", ["id": WatchLog.shortID(entry.requestID ?? "")])
        }
        guard !evicted.isEmpty else { return entries }
        save(kept)
        entryCount = kept.count
        for entry in evicted {
            // Cancel BEFORE deleting the audio — a mid-flight transfer must
            // be CANCELLED, not left to fail on a file that just vanished
            // under it.
            if let requestID = entry.requestID {
                cancelOutstandingTransfers(requestID: requestID)
            }
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: entry.audioFilePath))
        }
        // ONE notification regardless of how many aged out — a 10-entry
        // stale backlog must not fire 10 identical banners at once.
        postEvictionNotification()
        return kept
    }

    // MARK: - Outstanding-transfer correlation

    /// The WCSession outbox entry for `requestID`, if a prior attempt's file
    /// transfer is still pending delivery (metadata-matched on the claim
    /// token).
    private func outstandingTransfer(requestID: String) -> WCSessionFileTransfer? {
        WCSession.default.outstandingFileTransfers.first {
            ($0.file.metadata?[AppleSpeechRelayCoordinator.Wire.requestIDKey] as? String) == requestID
        }
    }

    /// Cancel every outbox transfer matching `requestID` (plural defensively —
    /// the sender's duplicate guard should make >1 impossible).
    private func cancelOutstandingTransfers(requestID: String) {
        for transfer in WCSession.default.outstandingFileTransfers
        where (transfer.file.metadata?[AppleSpeechRelayCoordinator.Wire.requestIDKey] as? String) == requestID {
            transfer.cancel()
        }
    }

    // MARK: - Persistence

    private func loadEntries() -> [Entry] {
        guard let data = defaults.data(forKey: Self.storageKey) else {
            return []
        }
        return (try? JSONDecoder().decode([Entry].self, from: data)) ?? []
    }

    private func save(_ entries: [Entry]) {
        if entries.isEmpty {
            defaults.removeObject(forKey: Self.storageKey)
        } else if let data = try? JSONEncoder().encode(entries) {
            defaults.set(data, forKey: Self.storageKey)
        }
    }

    private func removeEntry(_ entry: Entry) {
        var entries = loadEntries()
        entries.removeAll { $0 == entry }
        save(entries)
        entryCount = entries.count
    }

    /// Persist a freshly-minted requestID onto a LEGACY entry (decoded with
    /// requestID == nil) so its first re-fire — and every subsequent one —
    /// shares a stable claim token. Matched by full-entry equality, which is
    /// safe precisely because the target's requestID is nil (a claim-token
    /// entry can never equal it).
    private func persistRequestID(_ requestID: String, forLegacy entry: Entry) {
        var entries = loadEntries()
        guard let index = entries.firstIndex(where: { $0 == entry }) else { return }
        entries[index].requestID = requestID
        save(entries)
    }

    /// Stamp `lastAttemptAt` on the persisted copy of an entry (matched by
    /// claim token) right before a re-fire, so outstanding-transfer staleness
    /// is measured from the most recent attempt rather than the immutable
    /// enqueue time (see `Entry.lastAttemptAt`).
    private func touchLastAttempt(requestID: String) {
        var entries = loadEntries()
        guard let index = entries.firstIndex(where: { $0.requestID == requestID }) else { return }
        entries[index].lastAttemptAt = Date().timeIntervalSince1970
        save(entries)
    }

    // MARK: - Notifications

    /// Confirm that a queued relay finally transcribed, and that its ask is on
    /// its way to the agent.
    ///
    /// FIXED COPY — the transcript itself never reaches this body, for two
    /// independent reasons:
    ///   • It is UNTRUSTED text from a BYO speech endpoint, and a notification
    ///     body is an OS-owned, app-branded surface that persists in
    ///     Notification Center and mirrors to the paired iPhone's lock screen.
    ///     Bidi controls in it would make the displayed order disagree with the
    ///     string, which is the classic label-spoof primitive.
    ///   • Showing it would not be a meaningful confirmation anyway.
    ///     `completeEntry` dispatches the converse hop in the same beat, so
    ///     there is no window in which the user could read the transcript and
    ///     act on it — this banner reports what happened, it does not offer a
    ///     decision. The canonical transcript reaches the thread as the user
    ///     turn, where it is readable and editable-by-resend.
    ///
    /// (The reply notification takes the opposite route: agent reply text IS
    /// the point of that banner, so it is projected through
    /// `ReplySanitizer.displayLine` rather than replaced.)
    private func postTranscriptNotification() {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Conduck")
        // xcstrings
        content.body = String(localized: "Transcription complete. Sending to your AI.")
        content.sound = .default
        let req = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(req)
    }

    /// Notification body for a failed relay: hostname-bearing cases collapsed to
    /// fixed copy, and the one case whose shared copy names the wrong device
    /// given its own wrist-and-phone wording.
    ///
    /// PRIVACY (never reveal gateway URLs — see docs/ai-context/spec.md):
    /// `.networkError` / `.decodingError` / `.unknown` interpolate the
    /// WRAPPED error's `localizedDescription`, and a cert-class `URLError` embeds
    /// the server hostname in that text. On the Watch that text renders on the
    /// wrist AND mirrors to the paired iPhone's lock screen — visible without an
    /// unlock — so those three map to the fixed `remoteAgentUnreachable` copy.
    /// Every case that is not rewritten by an arm below already carries fixed,
    /// hostname-free copy and passes through UNCHANGED, which is what keeps this
    /// queue's real payloads (`.appleSpeechModelNotInstalled`,
    /// `.audioProcessingFailed`) on their own deliberate wording rather than a
    /// generic gateway message.
    ///
    /// Defensive: today's feeders cannot produce the three hazard cases — the
    /// relay wire carries an Int `errorCode` only, so `reconcile` rebuilds errors
    /// through `AppError.from(errorCode:message:)`, which cannot reconstruct an
    /// `Error` payload from an Int. This is the CHOKE POINT if a raw error is ever
    /// routed here, the same guarantee `BackgroundRemoteAgent.postFailureNotification`
    /// and `CarPlayConverseUploader.postFailureNotification` hold at their posters.
    ///
    /// `static` (rather than inlined at the sink like the two siblings) so
    /// `ConduckWatchTests` can regression-lock the mapping without a notification
    /// centre or the queue singleton's disk-touching `init`.
    static func notificationBody(for error: AppError, fallback: String) -> String {
        switch error {
        case .networkError, .decodingError, .unknown:
            return AppError.remoteAgentUnreachable.errorDescription ?? fallback
        // The three certificate families carry their REMEDY into the body, the
        // same carve-out `BackgroundRemoteAgent.postFailureNotification` holds.
        // `errorDescription` alone is the cause half, and each family keeps the
        // part the user must read in the other half: the server-side routes to a
        // trusted certificate, the "may be intercepted" warning, and — on an
        // unpinnable key — that the certificate is fine and this device trusts
        // it. This body mirrors to the paired iPhone's lock screen, which for a
        // queued relay may be the only place the verdict is ever read. Still
        // hostname-free: every remedy is fixed copy from `CertificateTrustCopy`,
        // so the privacy rule above holds.
        case .remoteAgentCertUntrusted, .sttCustomCertUntrusted,
             .ttsCustomCertUntrusted, .fileTransferCertUntrusted,
             .remoteAgentCertMismatch, .sttCustomCertMismatch,
             .ttsCustomCertMismatch, .fileTransferCertMismatch,
             .remoteAgentCertKeyUnpinnable, .sttCustomCertKeyUnpinnable,
             .ttsCustomCertKeyUnpinnable, .fileTransferCertKeyUnpinnable:
            return error.descriptionWithRecovery()
        // 75's shared copy says "this device", and this body renders in TWO
        // places where that phrase resolves to different hardware: the wrist,
        // where it reads as the watch, and the paired iPhone's lock screen it
        // mirrors to. The Keychain that could not answer for a RELAYED capture
        // is always the iPhone's, so the sentence names it outright rather than
        // leaning on a pronoun that has two candidates on either surface. It
        // ends on "record again" — not on the deferral toast's "your transcript
        // will arrive" — because a body only ever posts AFTER a claim, and a
        // claim has already deleted the audio.
        //
        // Defensive, like the interpolating cases above: `leavesEntryQueued`
        // keeps every retryable verdict (75 among them) off this poster
        // entirely, so no feeder reaches this arm today. It is the choke point
        // that stops the wrong-device sentence from arriving if one ever does.
        case .sttKeyUnreadable:
            // xcstrings
            return String(localized: "Your iPhone couldn't read its STT API key. Unlock your iPhone and record again.")
        default:
            // Cause-only ON PURPOSE, and NOT an instance of the cause-without-
            // remedy defect: this queue's reachable payloads
            // (`.appleSpeechModelNotInstalled`, `.audioProcessingFailed`) already
            // END in their own instruction, so `descriptionWithRecovery` would
            // print it twice ("… Record again. Record new audio."), which
            // `WatchNotificationPrivacyTests.testNonInterpolatingCasesKeepTheirOwnCopy`
            // locks against. The certificate families above are the carve-out
            // precisely because THEY carry the remedy in the other half.
            return error.errorDescription ?? fallback
        }
    }

    /// Terminal banner for a WORK relay that settled while the capture view was
    /// long gone (the deferred case this queue exists for).
    ///
    /// FIXED COPY on every arm, for the same reason `postTranscriptNotification`
    /// carries none: the transcript is untrusted text from a speech endpoint,
    /// and this body persists in Notification Center and mirrors to the paired
    /// iPhone's lock screen. The words themselves are on the desk, which is a
    /// surface that can render them safely.
    ///
    /// The two partial arms NAME the gap rather than claiming a clean save,
    /// and they name opposite halves of it. Words-only: the person's recording
    /// is genuinely gone from this lane, because their iPhone transcribed it on
    /// a build that had nowhere to put the audio. Recording-only: the card is
    /// playable on the desk and has no words on it, so the sentence sends them
    /// to the one surface that can add them. A banner is often the ONLY thing
    /// read on a deferred settlement, so a shared "Saved to Work." would leave
    /// half of these people believing a card is finished when it is not.
    private func postWorkNotification(_ settlement: RelaySettlement) {
        let body: String
        switch settlement {
        case .converseHop, .receiptContradictsDestination:
            // Neither settled anything on the desk, so neither has a banner.
            return
        case .workAcknowledged:
            body = String(
                localized: "watch.work.notification.saved",
                defaultValue: "Saved to Work."
            )
        case .workRecordingOnly:
            body = String(
                localized: "watch.work.notification.savedWithoutWords",
                defaultValue: "Saved to Work. Add the words on your iPhone."
            )
        case .workWordsOnly:
            body = String(
                localized: "watch.work.notification.wordsOnly",
                defaultValue: "Saved the words to Work. Update Conduck on your iPhone to keep recordings."
            )
        }
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Conduck")
        content.body = body
        content.sound = .default
        let req = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(req)
    }

    private func postErrorNotification(error: AppError) {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Conduck")
        content.body = Self.notificationBody(
            for: error,
            fallback: String(localized: "Could not process response.")
        )
        content.sound = .default
        let req = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(req)
    }

    /// Cap-eviction notice — the queued ask is being dropped (24 h age-out or
    /// 10-entry overflow), so tell the user rather than silently losing it.
    ///
    /// WORK entries never reach this poster: `applyCaps` exempts them from both
    /// caps, so the only recordings this sentence can ever describe are chat
    /// asks whose transcript was the whole point. A Work capture that could not
    /// be delivered is refused at the microphone instead, before anything is
    /// spoken into it.
    ///
    /// The sentence claims no CAUSE, because eviction has three and only one of
    /// them is a delivery problem: the clip may never have reached the iPhone,
    /// or it may have reached it every time and been refused by a Keychain that
    /// stayed locked for a day (`leavesEntryQueued` keeps that entry alive right
    /// up to the age cap), or it may have been pushed out by ten newer asks.
    /// What is true of all three — and what the user actually lost — is that the
    /// recording went untranscribed.
    private func postEvictionNotification() {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Conduck")
        // xcstrings
        content.body = String(localized: "A queued recording expired before your iPhone could transcribe it.")
        content.sound = .default
        let req = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(req)
    }
}

/// Stable identity for the note a WORDS-ONLY Work reply writes.
///
/// The card's id is a name-based UUID (RFC 4122 §4.3, version 5) over the
/// relay's claim token, in a namespace belonging to this lane alone. That is
/// what makes a retry SAFE: `ConversationStore.upsertDeskMaterial` is
/// idempotent on `id`, and every re-fire of a queue entry reuses its persisted
/// requestID — so a capture the drain tries three times repairs one card
/// instead of leaving three copies of the same thought on the desk. The
/// intent's default (a fresh UUID per call) is right for a Shortcut run, which
/// is a new capture every time, and wrong here.
///
/// Derivation, not storage, so a card written before a relaunch and a card
/// written after it collide on purpose.
enum WatchWorkRelayNoteIdentity {
    /// Namespace for wrist relay → Work notes. A frozen constant: the whole
    /// point is that a later launch, a later build and a different watch all
    /// derive the same id for the same claim token, so nothing about it may be
    /// computed from anything mutable.
    static let namespace = UUID(uuidString: "8E4D6C21-3F5B-4A7E-9C08-2B71D4F6A930")!

    static func materialID(forRequestID requestID: String) -> UUID {
        uuidV5(namespace: namespace, name: requestID)
    }

    /// RFC 4122 §4.3: SHA-1 over the namespace's 16 raw bytes followed by the
    /// name, truncated to 16 bytes, with the version (5) and variant (RFC 4122)
    /// fields overwritten. `Insecure.SHA1` is correct here and not a weakness:
    /// this is an identity derivation over a locally-minted UUID, never a
    /// signature or an authentication check.
    static func uuidV5(namespace: UUID, name: String) -> UUID {
        var hasher = Insecure.SHA1()
        withUnsafeBytes(of: namespace.uuid) { hasher.update(bufferPointer: $0) }
        hasher.update(data: Data(name.utf8))
        var bytes = Array(hasher.finalize())
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}
