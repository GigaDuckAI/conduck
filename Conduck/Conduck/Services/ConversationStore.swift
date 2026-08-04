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
// No Spotlight indexing (`SpotlightIndexer` / the
// `FeatureFlags` gate) — conversations are not Spotlight-surfaced in V1.
//
// CloudKit posture: sync is ENABLED on real device builds — the
// `cloudKitContainerOptions` attach mirrors the local Core Data store into
// the user's OWN private CloudKit database (developer-blind, no backend). The
// Simulator runs LOCAL-ONLY (plain `NSPersistentContainer`, `cloudKit: false`)
// because `NSPersistentCloudKitContainer` fatal-asserts on a sim with no
// signed-in iCloud account / unregistered container; the in-memory/on-disk
// test seam is local-only by definition. History tracking + remote-change
// posting stay ON in all configurations.
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
struct AttachmentDraft: Sendable {
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

    // MARK: - Errors

    /// Store-local errors. Kept here (not on `AppError`) so this store
    /// owns its own failure surface without touching the network taxonomy.
    enum StoreError: Error {
        /// `appendMessage` was handed a `conversationID` that does not exist
        /// in the store. Caller should mint a fresh conversation first.
        case conversationNotFound
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
        init(
            messageID: UUID,
            drafts: [AttachmentDraft],
            markScanned: Bool,
            expectedLaneID: String
        ) {
            self.messageID = messageID
            self.drafts = drafts
            self.markScanned = markScanned
            self.expectedLaneID = expectedLaneID
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

        // On the Simulator use a plain `NSPersistentContainer`: even with
        // `cloudKitContainerOptions` suppressed, `NSPersistentCloudKitContainer`
        // itself reaches `CKContainer.default()` during CloudKit metadata
        // migration once the on-disk store loads, which fatal-asserts
        // (`CKContainer.m:748`) on a sim with no iCloud entitlement and silently
        // kills the process. The base container exercises no CloudKit codepath.
        // Device builds keep the CloudKit container (sync is a signed/device gate).
        #if targetEnvironment(simulator)
        let container = NSPersistentContainer(name: "Conversations")
        #else
        let container = NSPersistentCloudKitContainer(name: "Conversations")
        #endif

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
            // PFCloudKitContainerProvider) on a Simulator with no signed-in
            // iCloud account / unregistered container, crashing every launch.
            // The Simulator is never where CloudKit sync is verified — that's a
            // signed, real-device founder gate — so run the
            // sim local-only, matching the test seam. Device builds keep sync on.
            #if targetEnvironment(simulator)
            ConversationStore.configureSyncOptions(on: description, cloudKit: false)
            #else
            ConversationStore.configureSyncOptions(on: description, cloudKit: true)
            #endif
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
    private func ensureLoaded() async throws {
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
    private func postDidChange() async {
        await MainActor.run {
            NotificationCenter.default.post(name: .conversationsDidChange, object: nil)
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
    private func newWriteContext() -> NSManagedObjectContext {
        let context = container.newBackgroundContext()
        context.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        return context
    }

    // MARK: - Conversation CRUD

    /// Create a fresh conversation bound to `backend`. Sets `id`,
    /// `createdAt` = now, `lastActivityAt` = now, a freshly-minted local
    /// `sessionID` (UUID string), and a nil `title`.
    func createConversation(backend: String) async throws -> ConversationRecord {
        try await ensureLoaded()
        let context = newWriteContext()
        let id = UUID()
        let now = Date()
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
        let now = Date()
        let sessionID = UUID().uuidString

        let outcome: (snippet: String?, continuationMessageID: UUID?)
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
            conversation.setValue(now, forKey: "lastActivityAt")
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

            // Copy turns in order, preserving relative timing via a small
            // increasing offset so `createdAt`-ascending render order matches
            // the original.
            var offset: TimeInterval = 0
            var lastInserted: NSManagedObject?
            var lastInsertedID: UUID?
            var lastInsertedRole: String?
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
                let createdAt = now.addingTimeInterval(offset)
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
                lastSourceStatus = sourceMessage.value(forKey: "status") as? String
                offset += 0.001

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
                continuationMessageID = lastInsertedID
            }

            try context.save()
            return (sourceTitleSnippet, continuationMessageID)
        }

        await postDidChange()

        return CloneResult(
            conversation: ConversationRecord(
                id: newID,
                title: nil,
                createdAt: now,
                lastActivityAt: now,
                sessionID: sessionID,
                backend: rawString,
                titleSnippet: outcome.snippet
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

    /// Fetch every conversation, most-recently-active first (`lastActivityAt`
    /// descending — the list sort key).
    func fetchConversations() async throws -> [ConversationRecord] {
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
        return records
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
    /// `Conversation.messages` removes its messages too.
    func deleteConversation(id: UUID) async throws {
        try await ensureLoaded()
        let context = newWriteContext()
        try await context.perform { [context] in
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

    /// Delete every conversation (and, via cascade, every message).
    func deleteAll() async throws {
        try await ensureLoaded()
        let context = newWriteContext()
        try await context.perform { [context] in
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
    func fetchRecentForPicker(limit: Int) async throws -> [RecentConversation] {
        try await ensureLoaded()
        guard limit > 0 else { return [] }
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
                    backend: record.backend
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
        attachments: [AttachmentDraft] = []
    ) async throws -> MessageRecord {
        try await ensureLoaded()

        let suppliedID = id
        let id = id ?? UUID()
        let now = Date()

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
        let dedupeHit: MessageRecord? = try await bgContext.perform { [bgContext] in
            if let suppliedID {
                let probe = NSFetchRequest<NSManagedObject>(entityName: "Message")
                probe.predicate = NSPredicate(format: "id == %@", suppliedID as CVarArg)
                probe.fetchLimit = 1
                if let existing = try bgContext.fetch(probe).first {
                    return MessageRecord(managedObject: existing)
                }
            }

            let convoRequest = NSFetchRequest<NSManagedObject>(entityName: "Conversation")
            convoRequest.predicate = NSPredicate(format: "id == %@", conversationID as CVarArg)
            convoRequest.fetchLimit = 1
            guard let conversation = try bgContext.fetch(convoRequest).first else {
                throw StoreError.conversationNotFound
            }

            let message = NSEntityDescription.insertNewObject(
                forEntityName: "Message", into: bgContext
            )
            message.setValue(id, forKey: "id")
            message.setValue(role, forKey: "role")
            message.setValue(text, forKey: "text")
            message.setValue(now, forKey: "createdAt")
            message.setValue(sourceDevice, forKey: "sourceDevice")
            message.setValue(status, forKey: "status")
            message.setValue(fileTransferLaneID, forKey: "fileTransferLaneID")
            // Explicit pending marker + owner identity, written in the SAME
            // transaction as the reply itself: a process death between the two
            // would otherwise leave a reply whose recovery lane was lost, which
            // is unrecoverable rather than merely late. Both stay nil without a
            // dispatch lane (see the parameter doc).
            if let outputScanLaneID {
                message.setValue(false, forKey: "outputScanDone")
                message.setValue(outputScanLaneID, forKey: "outputScanLaneID")
            }
            message.setValue(conversation, forKey: "conversation")

            for draft in attachments {
                Self.insertAttachment(draft, on: message, into: bgContext, at: now)
            }

            // Bump the parent's activity stamp so list sort reflects this turn.
            conversation.setValue(now, forKey: "lastActivityAt")

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
            return nil
        }

        if let dedupeHit { return dedupeHit }

        await postDidChange()

        return MessageRecord(
            id: id,
            role: role,
            text: text,
            createdAt: now,
            sourceDevice: sourceDevice,
            status: status,
            fileTransferLaneID: fileTransferLaneID,
            // Mirror the row just written: an owner identity always arrives
            // paired with the explicit `false` marker (same rule as
            // `completeAgentTurn`), so an in-memory record and a re-fetched one
            // agree on retro-scan eligibility.
            outputScanDone: outputScanLaneID == nil ? nil : false,
            outputScanLaneID: outputScanLaneID,
            attachments: Self.attachmentRecords(from: attachments, at: now)
        )
    }

    /// Complete a foreground agent turn in ONE background-context save: flip the
    /// just-sent USER message to `userStatus` (`sent`) AND insert the agent
    /// reply, then post a SINGLE `.conversationsDidChange`. Collapses the old
    /// two-call `updateStatus` + `appendMessage` sequence (two saves → two
    /// CloudKit exports → two reload posts) into one — the macOS foreground path
    /// used to fan those into the reload/merge storm that beachballed the UI.
    /// The user-status flip is a no-op if that id no longer resolves (deleted
    /// mid-flight on another device); the agent insert always runs. Returns the
    /// agent `MessageRecord` snapshot (same read-path contract as `appendMessage`).
    func completeAgentTurn(
        userMessageID: UUID,
        userStatus: String,
        agentText: String,
        conversationID: UUID,
        sourceDevice: String,
        agentMessageID: UUID = UUID(),
        outputScanLaneID: String? = nil,
        attachments: [AttachmentDraft] = []
    ) async throws -> MessageRecord {
        try await ensureLoaded()

        let now = Date()

        let bgContext = newWriteContext()
        try await bgContext.perform { [bgContext] in
            let convoRequest = NSFetchRequest<NSManagedObject>(entityName: "Conversation")
            convoRequest.predicate = NSPredicate(format: "id == %@", conversationID as CVarArg)
            convoRequest.fetchLimit = 1
            guard let conversation = try bgContext.fetch(convoRequest).first else {
                throw StoreError.conversationNotFound
            }

            // Flip the user turn out of `sending` (no-op if it no longer resolves).
            let userRequest = NSFetchRequest<NSManagedObject>(entityName: "Message")
            userRequest.predicate = NSPredicate(format: "id == %@", userMessageID as CVarArg)
            userRequest.fetchLimit = 1
            if let userMessage = try bgContext.fetch(userRequest).first {
                Self.applySendState(userStatus, to: userMessage)
            }

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
            // output probe runs. Persist the one-way lane identity + explicit
            // FALSE in the SAME transaction as the reply + sent flip. With no
            // dispatch lane, BOTH fields remain nil; false-without-identity is
            // therefore impossible for newly-written rows.
            if let outputScanLaneID {
                message.setValue(false, forKey: "outputScanDone")
                message.setValue(outputScanLaneID, forKey: "outputScanLaneID")
            }
            // `status` left unset → nil (agent replies carry no send-state, same
            // as the `appendMessage(status: nil)` agent-reply callers).
            message.setValue(conversation, forKey: "conversation")

            for draft in attachments {
                Self.insertAttachment(draft, on: message, into: bgContext, at: now)
            }

            // Bump the parent's activity stamp so list sort reflects this turn.
            // No `titleSnippet` capture — agent replies never set it (user turns only).
            conversation.setValue(now, forKey: "lastActivityAt")

            try bgContext.save()
        }

        await postDidChange()

        return MessageRecord(
            id: agentMessageID,
            role: "agent",
            text: agentText,
            createdAt: now,
            sourceDevice: sourceDevice,
            status: nil,
            outputScanDone: outputScanLaneID == nil ? nil : false,
            outputScanLaneID: outputScanLaneID,
            attachments: Self.attachmentRecords(from: attachments, at: now)
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
        try await bgContext.perform { [bgContext] in
            let request = NSFetchRequest<NSManagedObject>(entityName: "Message")
            request.predicate = NSPredicate(format: "id == %@", messageID as CVarArg)
            request.fetchLimit = 1
            guard let message = try bgContext.fetch(request).first else { return }
            Self.applySendState(status, to: message)
            try bgContext.save()
        }
        await postDidChange()
    }

    /// Single site for a send-state write. Setting `sent` ALSO clears
    /// the failure classification — the frozen rule is "clear on successful
    /// retry", so success is the only transition that erases it. `sending`
    /// deliberately KEEPS the old classification (a retry in flight still
    /// shows nothing — the row renders only for `failed` — but a NEW failure
    /// overwrites and a success clears; the stale value never surfaces).
    /// `failed` writes the fields explicitly in `failTurn` — plain callers
    /// (sweeps, cancellation) leave them untouched.
    private static func applySendState(_ status: String, to message: NSManagedObject) {
        message.setValue(status, forKey: "status")
        if status == "sent" {
            message.setValue(nil, forKey: "failureCode")
            message.setValue(nil, forKey: "failureWireCode")
            message.setValue(nil, forKey: "failureHadHistoryImages")
        }
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
    ///   generic failure IS the classification).
    /// - already `failed` with NO stored `failureCode` + incoming has one →
    ///   metadata upgraded in place (status untouched). This is the
    ///   delegate-lost-the-race case: a plain `failed` write landed first,
    ///   the coded write still must not be dropped.
    /// - anything else → no-op (a resolved turn is never disturbed — same
    ///   posture as `markPendingUserTurn`).
    ///
    /// `role == "user"` guard mirrors the other send-state writers.
    /// Non-throwing best-effort: failure writers run on cleanup paths.
    func failTurn(messageID: UUID, classification: TurnFailureClassification?) async {
        do { try await ensureLoaded() } catch { return }
        let context = newWriteContext()
        let changed: Bool = await context.perform { [context] in
            let request = NSFetchRequest<NSManagedObject>(entityName: "Message")
            request.predicate = NSPredicate(
                format: "id == %@ AND role == %@", messageID as CVarArg, "user"
            )
            request.fetchLimit = 1
            guard let message = (try? context.fetch(request))?.first else { return false }
            guard Self.applyFailure(classification, to: message) else { return false }
            try? context.save()
            return true
        }
        if changed { await postDidChange() }
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
    private static func applyFailure(
        _ classification: TurnFailureClassification?,
        to message: NSManagedObject
    ) -> Bool {
        let status = message.value(forKey: "status") as? String
        if status == "sending" {
            message.setValue("failed", forKey: "status")
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
            guard upgrades else { return false }
            message.setValue(classification.failureCode.map { NSNumber(value: $0) }, forKey: "failureCode")
            message.setValue(classification.wireCode, forKey: "failureWireCode")
            message.setValue(classification.hadHistoryImages.map { NSNumber(value: $0) }, forKey: "failureHadHistoryImages")
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
    /// GRACE WINDOW (default 30 min, deliberately conservative): the converse
    /// resource timeout is 600 s (the longest a turn can legitimately be in
    /// flight), but a `sending` turn may also have been written by ANOTHER
    /// device and arrived via CloudKit — its in-flight task is invisible here,
    /// so the threshold must comfortably exceed timeout + sync skew. 30 min
    /// does; the immediate post-kill case is handled separately by the
    /// resurrected-`.cancelled` mapping in the background delegates.
    ///
    /// Non-throwing (best-effort): a launch-time sweep must never block or
    /// fail the launch path. Posts `.conversationsDidChange` only when
    /// something actually flipped.
    func sweepStaleSendingUserTurns(
        olderThan interval: TimeInterval = 1800,
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
    ///   - set `outputScanDone = true` when `markScanned`.
    /// Returns whether ANY attachment was INSERTED — that is the caller's gate
    /// for preview enrichment, so it stays strictly about chips.
    ///
    /// Posts `.conversationsDidChange` ONCE, when either an attachment was
    /// inserted OR a turn's `outputScanDone` actually TRANSITIONED false → true.
    /// The marker is user-visible state now that `MissingOutputNotice` derives
    /// the "named a file, delivered nothing" row from it: without the second
    /// condition, a deferred grace-window pass that confirms the miss would
    /// write `true` to the store while every mounted thread kept rendering the
    /// stale `false`, and the row would appear only on the next unrelated
    /// reload. The post is gated on the TRANSITION, not on `markScanned` — a
    /// re-stamp of an already-true marker changes nothing, so a reload storm
    /// cannot be manufactured by repeatedly reconciling the same turn.
    func reconcileOutputScan(
        _ results: [OutputScanReconciliation]
    ) async throws -> Bool {
        guard !results.isEmpty else { return false }
        try await ensureLoaded()
        let bgContext = newWriteContext()
        let outcome: (inserted: Bool, changedVisibleState: Bool) = try await bgContext.perform { [bgContext] in
            var insertedAny = false
            var changedVisibleState = false
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
                    Self.applyDraft(draft, to: attachment, on: message, id: UUID(), sequence: nextSequence, at: now)
                    if let key = draft.storedKey { presentKeys.insert(key) }
                    nextSequence += 1
                    insertedAny = true
                    changedVisibleState = true
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
            return (insertedAny, changedVisibleState)
        }
        if outcome.changedVisibleState { await postDidChange() }
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
#endif

    /// Fetch a conversation's messages, oldest first (`createdAt` ascending —
    /// thread render order; a `sequence` tiebreaker is a V1.x concern).
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
                NSSortDescriptor(key: "createdAt", ascending: true)
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

    /// Derive a list-row title from a message body: first non-empty line,
    /// whitespace-trimmed, capped at ~60 characters (with an ellipsis when cut).
    /// Returns nil when the text is empty / whitespace-only (an attachment-only
    /// turn) so the caller skips the write and a later text turn can fill it.
    ///
    /// CROSS-TARGET: lives here (the store is a Watch membership exception) so
    /// both the write path and the backfill share one definition. Deliberately
    /// NOT `MessageRowFormatters.firstLineFallback` — that formatter is
    /// iOS-target-only and would break the Watch build.
    static func snippet(from text: String) -> String? {
        let firstLine = text
            .split(whereSeparator: \.isNewline)
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }?
            .trimmingCharacters(in: .whitespaces)
        guard let firstLine, !firstLine.isEmpty else { return nil }
        let cap = 60
        if firstLine.count <= cap { return firstLine }
        let truncated = firstLine.prefix(cap).trimmingCharacters(in: .whitespaces)
        return truncated + "…"
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
