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
// Privacy invariant: never log file paths, language hints, audio bytes,
// transcripts, or full requestIDs (`prefix(8)` only).

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
    /// (iPhone gone for days) — keep the newest, evict the oldest.
    private static let maxEntryCount = 10

    /// Max queue residency. A transcript landing >24 h after the ask has lost
    /// its conversational context — surfacing it then is worse than telling
    /// the user it expired.
    private static let maxEntryAge: TimeInterval = 24 * 60 * 60

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
    @discardableResult
    func enqueue(
        requestID: String,
        audioFileURL: URL,
        language: String?,
        providerID: String? = nil,
        conversationID: UUID? = nil
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
                requestID: requestID,
                // The first attempt follows enqueue immediately (enqueue-first
                // in `runRelay`), so the nil→`enqueuedAt` staleness fallback
                // is exact for it; only drain re-fires stamp this.
                lastAttemptAt: nil
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

    /// Late-reply convergence: a verdict arrived with NO live continuation
    /// (the relay timed out, or the process restarted since the request
    /// left). Claim-token semantics decide what happens:
    ///
    ///   • `.failure(.sttProviderUnreachable)` → the iPhone itself signalled
    ///     "can't run this now" — leave the entry queued for a later drain.
    ///   • Live turn in progress (`canAcceptDeferredDispatch == false`) → do
    ///     NOT claim; leave the entry. The idle-edge drain re-fires with the
    ///     same requestID and the iPhone's reply cache answers instantly —
    ///     one cheap extra round trip in a rare race beats a third entry
    ///     lifecycle stage.
    ///   • Claim-nil → duplicate/evicted verdict → drop silently.
    ///   • `.success` → shared `completeEntry` (clears the deferral toast,
    ///     posts the transcript notification, dispatches the converse hop).
    ///   • `.failure(permanent)` → clear the deferral toast (its promise just
    ///     became false) + error notification (claim already removed the
    ///     entry + audio).
    func reconcile(requestID: String, outcome: RelayReplyOutcome) async {
        if case .failure(let error) = outcome,
           case .sttProviderUnreachable = error {
            return
        }
        guard WatchRecordingService.shared.canAcceptDeferredDispatch else {
            WatchLog.note(.queue, "queue.reconcile.deferred", ["id": WatchLog.shortID(requestID)])
            return
        }
        guard let entry = claimEntry(requestID: requestID) else {
            WatchLog.note(.queue, "queue.reconcile.drop", ["id": WatchLog.shortID(requestID)])
            return
        }
        switch outcome {
        case .success(let text):
            await completeEntry(entry, text: text)
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
                let text = try await AppleSpeechRelayCoordinator.shared.relay(
                    requestID: requestID,
                    audioFileURL: url,
                    language: entry.language,
                    providerID: entry.providerID,
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

                // Exactly-once: the claim IS the dispatch token. Claim-nil ⇒ a
                // racing reconcile already consumed this verdict → skip
                // silently (its hop is the one that counts).
                guard let claimed = claimEntry(requestID: requestID) else { continue }
                await completeEntry(claimed, text: text)
            } catch {
                // `AppError` has associated values, so Equatable is not
                // synthesized — `if case` is the canonical pattern match.
                if let appError = error as? AppError,
                   case .sttProviderUnreachable = appError {
                    // Still unreachable — stop draining; the next trigger will
                    // retry. Entry (and its outstanding transfer, if any)
                    // stays queued.
                    WatchLog.note(.queue, "queue.drain.unreachable", ["id": WatchLog.shortID(requestID)])
                    return
                }
                // Permanent failure for this entry (e.g. model not installed
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

    // MARK: - Shared success path

    /// The ONE success block — used by BOTH `drain()` and `reconcile(...)` so
    /// the two dispatch paths cannot diverge. Caller has ALREADY claimed the
    /// entry (entry removed, audio deleted, transfer cancelled).
    ///
    /// Clears the relay-deferral toast (its promise — "your transcript will
    /// arrive" — was just kept; provenance-gated inside the service so an
    /// unrelated error is never stomped), surfaces the transcript via local
    /// notification (the recording UI has long since dismissed by the time a
    /// queued relay completes), then dispatches the converse hop so the
    /// transcribed ask actually reaches the agent — mirroring the live
    /// `runRelay` → `startConverseHop` chain.
    private func completeEntry(_ entry: Entry, text: String) async {
        WatchLog.note(.queue, "queue.complete", ["id": WatchLog.shortID(entry.requestID ?? "")])
        postTranscriptNotification(text: text)
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
        await WatchRecordingService.shared.startDeferredConverseHop(
            transcript: text,
            boundTo: entry.conversationID.flatMap { UUID(uuidString: $0) }
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

    /// Enforce the 24 h max-age and 10-entry caps. Eviction = delete audio +
    /// cancel any outstanding transfer + post the expiry notification (the
    /// user's ask is being dropped — silent disposal would be a trust bug).
    /// Returns the surviving entries (persisted if anything was evicted).
    private func enforceCaps(_ entries: [Entry]) -> [Entry] {
        let now = Date().timeIntervalSince1970
        var kept: [Entry] = []
        var evicted: [Entry] = []
        for entry in entries {
            if now - entry.enqueuedAt > Self.maxEntryAge {
                evicted.append(entry)
                WatchLog.note(.queue, "queue.evict", ["id": WatchLog.shortID(entry.requestID ?? ""), "reason": "age"])
            } else {
                kept.append(entry)
            }
        }
        // Entries are FIFO-appended, so index 0 is the oldest.
        while kept.count > Self.maxEntryCount {
            let dropped = kept.removeFirst()
            evicted.append(dropped)
            WatchLog.note(.queue, "queue.evict", ["id": WatchLog.shortID(dropped.requestID ?? ""), "reason": "cap"])
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

    private func postTranscriptNotification(text: String) {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Conduck")
        content.body = text.isEmpty
            ? String(localized: "Transcription complete.")
            : text
        content.sound = .default
        let req = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(req)
    }

    /// Notification body for a failed relay, hostname-bearing cases collapsed to
    /// fixed copy.
    ///
    /// PRIVACY (never reveal gateway URLs — see the spec's Privacy & Security
    /// section): `.networkError` / `.decodingError` / `.unknown` interpolate the
    /// WRAPPED error's `localizedDescription`, and a cert-class `URLError` embeds
    /// the server hostname in that text. On the Watch that text renders on the
    /// wrist AND mirrors to the paired iPhone's lock screen — visible without an
    /// unlock — so those three map to the fixed `remoteAgentUnreachable` copy.
    /// Every other case already carries fixed, hostname-free copy and passes
    /// through UNCHANGED, which is what keeps this queue's real payloads
    /// (`.appleSpeechModelNotInstalled`, `.audioProcessingFailed`) on their own
    /// deliberate wording rather than a generic gateway message.
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
    private func postEvictionNotification() {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Conduck")
        // xcstrings: relay-convergence fix
        content.body = String(localized: "A queued recording couldn't reach your iPhone and has expired.")
        content.sound = .default
        let req = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(req)
    }
}
