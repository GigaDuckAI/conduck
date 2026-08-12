// SPDX-License-Identifier: Apache-2.0

// Conduck
// SharedInboxDrainer.swift
//
// Share-Extension — the main-app drainer that does the REAL work the
// thin appex deliberately skips (iOS 26 appex ~120 MB cap forbids decoding a
// 48 MP HEIC). The appex captures-and-queues: it copies each shared
// `NSItemProvider` representation into an App-Group inbox envelope + writes ONE
// `manifest.json`, then exits. On the next foregrounding (or a "Shared to
// Conduck" notification tap) the main app calls `drain()`, which classifies →
// (uploads) → appends → assembles → dispatches each envelope through the SAME
// shipped pipeline the in-app composer uses (`ConversationDetailViewModel`),
// so the wire is byte-identical.
//
// EXACTLY-ONCE posture: at-most-once gateway dispatch +
// idempotent uploads. Two crash windows, both closed by a three-state
// `processing/<uuid>/state.json`:
//   - the user `Message.id` IS the envelope `uuid`, so a re-append is a no-op
//     (`ConversationStore.appendMessage(id:)` dedupes) — re-draining never
//     produces a second user turn.
//   - the file-server upload key is DETERMINISTIC per attachment
//     (`FileServerClient.deterministicStoredKey`), so a re-PUT overwrites the
//     same bytes (WebDAV PUT is idempotent — no orphan).
//   - the converse dispatch is marked `submitted` DURABLY before it fires; on
//     relaunch a `submitted` envelope is reconciled (leave if a live task
//     exists, delete if a reply landed, ELSE flip the turn `failed` + notify +
//     delete — NEVER auto-resend, which would double-hit the user's own
//     gateway).
//
// FAILURE SURFACING: the CONVERSATION is the
// single recovery surface. A terminal failure splits two ways:
//   - turn-EXISTS (dispatch threw after the user turn was appended, or the
//     relaunch reconcile found a submitted-but-unanswered turn): flip THAT exact
//     turn to `failed` (inline failed bubble + Retry, which re-sends fully from
//     Core Data), post `.remoteAgentTurnDidFail` (the macOS menu-bar red dot)
//     and a USER notification deep-linking to the thread, then DELETE the
//     envelope. At-most-once holds: inline Retry re-sends from the store, never
//     from the (now-deleted) envelope, so deleting after the flip never
//     re-dispatches.
//   - NO-turn (failure before the user turn was appended — undecodable manifest,
//     routing fail, corrupt item, pre-append upload fail, needsFileServer): post
//     a USER notification stating it didn't send (no conversation deep-link —
//     there is no thread), then DELETE the envelope. Nothing was sent → trivially
//     at-most-once.
// There is no `failed/` quarantine graveyard and no Settings recovery list — a
// failure lands in the conversation (or a notification) the user already looks at.
//
// NO `NSFileCoordinator`: strict single-writer +
// atomic-rename. The appex writes ONLY under `tmp/<uuid>/` then one same-volume
// rename → `Inbox/<uuid>/`; ONLY the drainer moves published dirs into
// `processing/` or deletes them. Inbox originals are KEPT until the converse
// succeeds (the replay source); uploads use throwaway copies (`uploadFile`
// deletes its input).
//
// SEAMS (test injection, NO network in tests): the network-touching ops are
// behind small `Sendable` protocols — `ShareConverseDispatching` (converse send
// + live-task probe) and `ShareFileUploading` (file upload + live-task probe);
// production impls delegate to the shared singletons. Routing is injected as a
// closure defaulting to the shared `SharedInboxRouting.resolveOrMint` helper
// (no rule drift) so a test can supply a pre-resolved routing target WITHOUT a
// signed-build Keychain token write. `store` / `settings` default to `.shared`.

import Foundation
import UserNotifications
import UniformTypeIdentifiers
import os

/// What kicked a `drain()` — diagnostic only (logged, never gates behavior). Lets
/// the founder confirm in Xcode logs WHICH trigger fired (e.g. `shareWake` the
/// instant a share is queued, vs `appActive` only on a menu-bar click) when
/// chasing a "share didn't process until I clicked" report.
enum DrainTrigger: String, Sendable {
    case shareWake        // macOS Darwin wake from the appex (inactive-app drain)
    case appActive        // macOS applicationDidBecomeActive
    case launch           // macOS applicationDidFinishLaunching (cold-start queue)
    case foreground       // iOS ContentView.refreshOnForeground
    case unspecified
}

// MARK: - Injectable seams (network-touching ops)

/// Wraps the converse hop so tests run with NO network. Production delegates to
/// `BackgroundRemoteAgent.shared`; a mock returns a canned reply + a scripted
/// live-task answer. Mirrors `BackgroundRemoteAgent.send` / `hasLiveConverseTask`
/// one-to-one so the drainer never re-shapes the wire.
protocol ShareConverseDispatching: Sendable {
    /// Dispatch a share-originated converse turn. Returns the agent reply text.
    /// Landing is transport-split (see `LiveConverseDispatcher`): on **iOS** the
    /// BACKGROUND-session delegate appends the agent bubble + posts the completion
    /// notification (so a mid-await suspend just leaves the envelope in
    /// `processing/` for the relaunch reconcile); on **macOS** the dispatch uses
    /// the FOREGROUND in-process client and lands the reply itself (via the shared
    /// `BackgroundRemoteAgent.recordReply`) BEFORE returning — a background session
    /// would defer its completion delegate until the inactive menu-bar app is
    /// re-activated (the share-reply-cue bug). Either way the reply is landed by
    /// the time `dispatch` resolves successfully, so the drainer deletes the
    /// envelope on success.
    @discardableResult
    func dispatch(
        backend: RemoteAgentBackend,
        ref: RemoteAgentRef,
        url: URL,
        token: String,
        authScheme: RemoteAgentAuthScheme,
        model: String?,
        priorTurns: [ConverseRequest.Message],
        newUserText: String,
        newUserImageDataURIs: [String],
        newUserTextFileBlocks: [(filename: String, text: String)],
        newUserServerFileRefs: [(originalName: String, storedKey: String)],
        newUserImageFileRefs: [(storedKey: String, filename: String)],
        newUserTextFileServerRefs: [(originalName: String, storedKey: String)],
        fileTransferSnapshot: SettingsManager.FileTransferSnapshot?,
        conversationID: UUID,
        shareEnvelopeID: UUID
    ) async throws -> String

    /// Whether a converse task for `shareEnvelopeID` is LIVE on the background
    /// session (drives the relaunch reconcile: live → leave it alone).
    func hasLiveConverseTask(shareEnvelopeID: UUID) async -> Bool
}

/// Wraps the file-server upload so tests run with NO network. Production
/// delegates to `BackgroundFileTransfer.shared`; a mock records the
/// `(storedKey, sequence)` it was asked to upload + answers the live-task probe.
protocol ShareFileUploading: Sendable {
    /// Upload `localURL`'s bytes to `storedKey` on the bound file-server, tagged
    /// with `(shareEnvelopeID, sequence)` so the cross-launch reconcile can tell
    /// a still-running upload apart from one to re-PUT. `uploadFile` DELETES its
    /// input — the drainer always hands it a THROWAWAY copy (the inbox original
    /// is the replay source).
    func uploadFile(
        localURL: URL,
        snapshot: SettingsManager.FileTransferSnapshot,
        storedKey: String,
        shareEnvelopeID: UUID,
        sequence: Int
    ) async throws

    /// Whether an upload task for `(shareEnvelopeID, sequence)` is LIVE on the
    /// transfer session (drives the upload reconcile: live → DEFER the envelope).
    func hasLiveUploadTask(shareEnvelopeID: UUID, sequence: Int) async -> Bool
}

/// Production converse seam — forwards to the shared background agent singleton.
private struct LiveConverseDispatcher: ShareConverseDispatching {
    @discardableResult
    func dispatch(
        backend: RemoteAgentBackend,
        ref: RemoteAgentRef,
        url: URL,
        token: String,
        authScheme: RemoteAgentAuthScheme,
        model: String?,
        priorTurns: [ConverseRequest.Message],
        newUserText: String,
        newUserImageDataURIs: [String],
        newUserTextFileBlocks: [(filename: String, text: String)],
        newUserServerFileRefs: [(originalName: String, storedKey: String)],
        newUserImageFileRefs: [(storedKey: String, filename: String)],
        newUserTextFileServerRefs: [(originalName: String, storedKey: String)],
        fileTransferSnapshot: SettingsManager.FileTransferSnapshot?,
        conversationID: UUID,
        shareEnvelopeID: UUID
    ) async throws -> String {
        // The drained user turn's `Message.id` IS the envelope uuid (the drain
        // appends with `id: manifest.uuid` for idempotency), so the same value is
        // the exact-flip target — the landing flips THIS turn's status instead of
        // a conversation-wide flip (which would alias a sibling in-flight turn).
        #if os(macOS)
        // macOS: FOREGROUND in-process client (parity with the in-app composer's
        // `#if os(macOS)` branch + the `BackgroundFileTransfer` macOS-`.default`
        // precedent). A background URLSession defers its completion delegate until
        // the inactive menu-bar app re-activates — so the reply never lands (and
        // the menu-bar dot never lights) until the user clicks. The in-process
        // session is not gated by app-active state; it completes immediately.
        // Revalidate the ONE snapshot captured by the drainer immediately
        // before the foreground send. Never re-resolve a replacement lane.
        if let fileTransferSnapshot {
            guard let current = await SettingsManager.shared.fileTransferReadySnapshot(for: ref),
                  current.durableLaneID == fileTransferSnapshot.durableLaneID,
                  current.identitySignature == fileTransferSnapshot.identitySignature else {
                throw AppError.fileTransferNotConfigured
            }
        }
        let fileServerReady = fileTransferSnapshot != nil
        // Pinning session for the LIVE hop (same recipe as the in-app composer's
        // macOS branch): `URLSession.shared` cannot carry a delegate, so a send
        // on it silently ignores the user's per-ref cert pin. Pin resolved from
        // the DISPATCHED ref at send time from the durable store. Session owned
        // here and invalidated on every exit path from this macOS branch.
        let (pinnedSession, trustEvaluator) = RemoteAgentClient.makePinnedForegroundSession(
            pinnedFingerprintHex: RemoteAgentTrustEvaluator.storedConversePin(for: ref)
        )
        defer { pinnedSession.invalidateAndCancel() }
        // Local liveness claim for the whole share turn. `isCancellable: false`
        // — a share drain exposes no cancel handle, so the UI must never offer
        // Stop for it.
        //
        // The claim SPANS PERSISTENCE, not just the network hop: the macOS quit
        // guard auto-resolves on `liveCount == 0`, and a claim released the
        // instant the response arrived would let the app quit inside the exact
        // `recordReply` window that exists to make the reply durable. Released
        // in a `defer` so a throw releases it too; ending a token twice is a
        // no-op, and a leaked claim ages out on the registry's TTL.
        let shareClaim = await MainActor.run {
            InFlightTurnRegistry.shared.noteBegan(
                conversationID,
                lane: .shareDrain,
                isCancellable: false
            )
        }
        defer {
            Task { @MainActor in InFlightTurnRegistry.shared.noteEnded(shareClaim) }
        }
        let reply = try await RemoteAgentClient.shared.send(
            backend: backend,
            url: url,
            token: token,
            authScheme: authScheme,
            model: model,
            priorTurns: priorTurns,
            newUserText: newUserText,
            newUserImageDataURIs: newUserImageDataURIs,
            newUserTextFileBlocks: newUserTextFileBlocks,
            newUserServerFileRefs: newUserServerFileRefs,
            newUserImageFileRefs: newUserImageFileRefs,
            newUserTextFileServerRefs: newUserTextFileServerRefs,
            fileServerReady: fileServerReady,
            transport: .pinned(session: pinnedSession, evaluator: trustEvaluator)
        )
        // Land in-process via the SHARED landing path (append → flip → output
        // detect → user reply notification → post `.remoteAgentTurnDidComplete`,
        // crash-safe order). `backendRawValue` is the carrier raw value — only a
        // fallback; `recordReply` resolves the TRUE bound ref from the
        // conversation row (which exists — the drain just appended to it). A share
        // never stamps the per-device quick-capture pointer. A `false` return
        // (agent-append failed, e.g. conversation deleted mid-flight) does NOT
        // throw — at-most-once: the gateway was already hit, never re-dispatch.
        _ = await BackgroundRemoteAgent.recordReply(
            reply,
            conversationID: conversationID,
            backendRawValue: backend.rawValue,
            userMessageID: shareEnvelopeID,
            stampsActiveConversation: false,
            fileTransferLaneID: fileTransferSnapshot?.durableLaneID
        )
        return reply
        #else
        // iOS: BACKGROUND session (survives the share-extension exit + app
        // suspension); its delegate lands the reply via the same `recordReply`.
        return try await BackgroundRemoteAgent.shared.send(
            backend: backend,
            ref: ref,
            url: url,
            token: token,
            authScheme: authScheme,
            model: model,
            priorTurns: priorTurns,
            newUserText: newUserText,
            newUserImageDataURIs: newUserImageDataURIs,
            newUserTextFileBlocks: newUserTextFileBlocks,
            newUserServerFileRefs: newUserServerFileRefs,
            newUserImageFileRefs: newUserImageFileRefs,
            newUserTextFileServerRefs: newUserTextFileServerRefs,
            inputFileTransferSnapshot: fileTransferSnapshot,
            fileTransferSnapshot: fileTransferSnapshot,
            conversationID: conversationID,
            shareEnvelopeID: shareEnvelopeID,
            userMessageID: shareEnvelopeID
        )
        #endif
    }

    func hasLiveConverseTask(shareEnvelopeID: UUID) async -> Bool {
        // macOS has no daemon-owned background converse task (the foreground
        // client is in-process), so this is always false there — a mid-send app
        // quit leaves a `submitted` envelope with no live task and no landed
        // reply → the relaunch reconcile FAILS its turn (flip `failed` + notify +
        // delete; at-most-once — never auto-resends, which would double-hit the
        // user's gateway).
        await BackgroundRemoteAgent.shared.hasLiveConverseTask(shareEnvelopeID: shareEnvelopeID)
    }
}

/// Production upload seam — forwards to the shared file-transfer singleton. The
/// `onProgress` sink is a no-op (the share path has no staged tile to drive).
private struct LiveFileUploader: ShareFileUploading {
    func uploadFile(
        localURL: URL,
        snapshot: SettingsManager.FileTransferSnapshot,
        storedKey: String,
        shareEnvelopeID: UUID,
        sequence: Int
    ) async throws {
        try await BackgroundFileTransfer.shared.uploadFile(
            localURL: localURL,
            snapshot: snapshot,
            storedKey: storedKey,
            shareEnvelopeID: shareEnvelopeID,
            sequence: sequence,
            onProgress: { _ in }
        )
    }

    func hasLiveUploadTask(shareEnvelopeID: UUID, sequence: Int) async -> Bool {
        await BackgroundFileTransfer.shared.hasLiveUploadTask(shareEnvelopeID: shareEnvelopeID, sequence: sequence)
    }
}

// MARK: - SharedInboxDrainer

/// Drains the App-Group share inbox: claims published envelopes, classifies +
/// uploads + appends + assembles + dispatches each, reconciles leftovers from a
/// prior process on relaunch, surfaces failures (turn-exists → flip+notify+
/// delete; no-turn → notify+delete), and janitors abandoned `tmp/`. An `actor`
/// so concurrent `drain()` calls
/// (foreground hook + notification tap firing near-simultaneously) serialize —
/// the per-envelope CLAIM (an atomic `moveItem` into `processing/`) is the
/// cross-process guard, the actor is the in-process one.
actor SharedInboxDrainer {

    // MARK: - Singleton

    /// Production singleton — inbox under the App-Group `Application Support`
    /// container, live network seams, shared store/settings.
    static let shared = SharedInboxDrainer()

    // MARK: - Dependencies (injectable for tests)

    /// The inbox BASE dir (`…/Application Support/Inbox`). The three sub-layers
    /// (`tmp/`, published envelopes, `processing/`) live under it.
    private let inboxBase: URL
    private let store: ConversationStore
    private let settings: SettingsManager
    private let dispatcher: any ShareConverseDispatching
    private let uploader: any ShareFileUploading
    /// Routing seam — defaults to the shared `SharedInboxRouting.resolveOrMint`
    /// helper (production: no rule drift vs. `ConverseIntent`). Injected as a
    /// closure so a test can return a PRE-RESOLVED target without a signed-build
    /// Keychain token write (the real helper requires a non-empty bearer token).
    /// Args: the manifest's three routing fields — `conversationID` (existing-
    /// thread pick), `newConversationGatewayRef` (new-on-gateway pick), and
    /// `selectedBackendRef` (the deleted-conversation mint fallback) — then the
    /// `settings` + `store`. Threaded through so the share picker's full target
    /// precedence reaches `resolveOrMint`.
    private let router: @Sendable (UUID?, String?, String?, SettingsManager, ConversationStore) async throws -> SharedInboxRouting.Resolved
    /// Per-gateway file-server snapshot lookup — defaults to
    /// `settings.fileTransferReadySnapshot(for:)` (READY = saved + staged Test
    /// Connection passed; a saved-but-failed server must not receive shared
    /// binaries). Injected as a closure so a test can
    /// return a canned snapshot WITHOUT a signed-build Keychain credential read
    /// (the real lookup needs the file-server credential from Keychain). NIL =
    /// no ready file-server for that gateway → a shared binary fails the envelope
    /// (notify the user it didn't send, then delete).
    private let fileTransferSnapshotProvider: @Sendable (RemoteAgentRef, SettingsManager) async -> SettingsManager.FileTransferSnapshot?

    /// Whether `inboxBase`'s scaffold (`tmp/`, `processing/`) has been created
    /// this process — created lazily on first drain (cheap idempotent
    /// `createDirectory(withIntermediateDirectories:)`).
    private var didScaffold = false

    /// Envelope UUIDs (`uuidString`) a LIVE `process(...)` call currently owns in
    /// THIS process. The cross-process / cross-drain CLAIM (the atomic `moveItem`
    /// into `processing/`) guards the INITIAL claim — only one mover wins. This
    /// in-process set additionally closes the reconcile-vs-live-process window:
    /// a near-simultaneous `drainAndResolve` (notification tap) and `drain()`
    /// (foreground) can interleave so that `reconcileProcessing` inspects a
    /// `processing/<uuid>/` dir that a live `process(...)` call already owns but
    /// whose `writeState(submitted:true)` hasn't been written yet — `readState`
    /// returns nil → the reconcile would (wrongly) re-run `process` and fire a
    /// SECOND `dispatcher.dispatch`, double-hitting the user's BYO gateway
    /// (`appendMessage` is idempotent but dispatch is NOT). Every entry is
    /// inserted SYNCHRONOUSLY at the claim point (same actor region as the
    /// `moveItem`, no `await` in between) so a concurrent reconcile always sees
    /// it, and cleared in `process`'s `defer` on every exit path. See the locked
    /// "never double-hit the gateway" invariant.
    private var inFlightEnvelopes: Set<String> = []

    /// True once a FULL `drain()` has completed in this process — the gate that
    /// arms `diagnosticStuckCount`'s published-envelope rule (envelope age runs
    /// from queue time, so a cold launch straight into Diagnostics would
    /// otherwise count hours-old-but-perfectly-normal shares as stuck before
    /// the foreground drain's claim pass ran).
    private var hasCompletedDrainThisProcess = false

    // MARK: - Tunables (sweep windows)

    /// Abandoned-appex-write TTL: a `tmp/<uuid>/` older than this never finished
    /// its publish rename (the appex crashed mid-write) → janitor deletes it.
    /// ~1h is generous vs. the appex's sub-second copy budget.
    private static let tmpStaleInterval: TimeInterval = 60 * 60

    // MARK: - Init

    /// Production init — resolves the App-Group inbox base, wires live seams.
    /// Falls back to the per-process Application Support dir if the App Group is
    /// mis-provisioned (entitlement missing) so a dev build still drains its own
    /// queue rather than crashing (mirrors `ConversationStore`'s fallback).
    private init() {
        self.inboxBase = Self.defaultInboxBase()
        self.store = .shared
        self.settings = .shared
        self.dispatcher = LiveConverseDispatcher()
        self.uploader = LiveFileUploader()
        self.router = { override, newGatewayRef, selectedBackendRef, settings, store in
            try await SharedInboxRouting.resolveOrMint(
                overrideConversationID: override,
                newConversationGatewayRef: newGatewayRef,
                selectedBackendRef: selectedBackendRef,
                settings: settings,
                store: store
            )
        }
        self.fileTransferSnapshotProvider = { ref, settings in
            await settings.fileTransferReadySnapshot(for: ref)
        }
    }

    /// Test init — inject the inbox base dir + the network seams (so tests run
    /// with NO network) + the routing closure (so tests skip the signed-build
    /// Keychain token write). `store` / `settings` default to `.shared`.
    init(
        inboxBase: URL,
        dispatcher: any ShareConverseDispatching,
        uploader: any ShareFileUploading,
        store: ConversationStore = .shared,
        settings: SettingsManager = .shared,
        router: @escaping @Sendable (UUID?, String?, String?, SettingsManager, ConversationStore) async throws -> SharedInboxRouting.Resolved = { override, newGatewayRef, selectedBackendRef, settings, store in
            try await SharedInboxRouting.resolveOrMint(
                overrideConversationID: override,
                newConversationGatewayRef: newGatewayRef,
                selectedBackendRef: selectedBackendRef,
                settings: settings,
                store: store
            )
        },
        fileTransferSnapshotProvider: @escaping @Sendable (RemoteAgentRef, SettingsManager) async -> SettingsManager.FileTransferSnapshot? = { ref, settings in
            await settings.fileTransferReadySnapshot(for: ref)
        }
    ) {
        self.inboxBase = inboxBase
        self.dispatcher = dispatcher
        self.uploader = uploader
        self.store = store
        self.settings = settings
        self.router = router
        self.fileTransferSnapshotProvider = fileTransferSnapshotProvider
    }

    /// Resolve the production inbox base: `<AppGroup>/Application Support/Inbox`.
    /// The appex writes into the SAME location, so this single source is
    /// load-bearing. Falls back to the per-process Application Support dir when
    /// the App Group container is nil (mis-provisioned entitlement).
    private static func defaultInboxBase() -> URL {
        let support: URL
        if let groupURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: Constants.appGroupID
        ) {
            support = groupURL.appendingPathComponent("Application Support", isDirectory: true)
        } else {
            NSLog("[SharedInboxDrainer] App Group container URL is nil for \(Constants.appGroupID); falling back to default Application Support.")
            support = (try? FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
            )) ?? FileManager.default.temporaryDirectory
        }
        return support.appendingPathComponent(Constants.sharedInboxDirectoryName, isDirectory: true)
    }

    /// The production inbox base (`<AppGroup>/Application Support/Inbox`), exposed
    /// so the macOS `ShareInboxWatcher` watches the IDENTICAL directory this actor
    /// drains — single source of truth, never hardcode the path twice.
    nonisolated static var productionInboxBase: URL { defaultInboxBase() }

    // MARK: - Inbox layout

    private var tmpDir: URL { inboxBase.appendingPathComponent("tmp", isDirectory: true) }
    private var processingDir: URL { inboxBase.appendingPathComponent("processing", isDirectory: true) }

    /// Create the inbox scaffold once per process (the appex creates `tmp/` on
    /// its side; the drainer owns `processing/`). Idempotent.
    private func ensureScaffold() {
        guard !didScaffold else { return }
        let fm = FileManager.default
        for dir in [inboxBase, tmpDir, processingDir] {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        didScaffold = true
    }

    // MARK: - Entry point

    /// Drain the inbox. Called by the app-active hooks (iOS foreground / macOS
    /// `applicationDidBecomeActive` / notification tap).
    ///
    /// Order is load-bearing:
    ///   1. RECONCILE leftovers in `processing/` FIRST (a prior process that
    ///      died mid-drain) — so a `submitted` envelope is resolved BEFORE any
    ///      fresh claim, and a `submitted==false` leftover re-runs Process
    ///      (idempotent).
    ///   2. CLAIM each PUBLISHED envelope (atomic move → `processing/`) and
    ///      process it.
    ///   3. JANITOR — sweep abandoned `tmp/`.
    func drain(trigger: DrainTrigger = .unspecified) async {
        ensureScaffold()

        // Diagnostic (no content — counts + trigger only): lets the founder confirm
        // in Xcode logs that a `shareWake` drain fires the INSTANT a share is queued
        // (no menu-bar click), and how many envelopes each drain sees. Snapshot the
        // two work-lists once for both the log and the loops below.
        let reconcileIDs = childEnvelopeIDs(of: processingDir)
        let publishedIDs = publishedEnvelopeIDs()
        #if DEBUG
        RemoteAgentDiagnostics.log.log("drain(\(trigger.rawValue, privacy: .public)): published=\(publishedIDs.count, privacy: .public) reconcile=\(reconcileIDs.count, privacy: .public)")
        #endif

        // Notification auth: a drain can fail a share and post a
        // user "couldn't send" notification below. This is a FOREGROUND moment
        // (the app just became active), so request notification permission if
        // still `.notDetermined` — otherwise a share-failure notification is
        // dropped. Idempotent + non-blocking: a no-op once determined.
        await NotificationPermissions.ensureRequested()

        // 1. Reconcile prior-process leftovers in processing/.
        for envelopeID in reconcileIDs {
            await reconcileProcessing(envelopeID)
        }

        // 2. Claim + process each published envelope. A published envelope is a
        //    direct child UUID dir of `inboxBase` (NOT tmp/processing/failed —
        //    those are reserved names, never valid UUIDs, so the UUID parse in
        //    `childEnvelopeIDs` already excludes them; the explicit skip is
        //    belt-and-suspenders).
        for envelopeID in publishedIDs {
            await claimAndProcess(envelopeID)
        }

        // 3. Janitor.
        janitor()

        // Arm the Diagnostics stuck-count's published-envelope rule: only after
        // a full drain has had its claim pass does "old AND still published"
        // mean the drain isn't claiming it (see `diagnosticStuckCount`).
        hasCompletedDrainThisProcess = true
    }

    /// Drain ONE specific published envelope (the confirmation-notification-tap
    /// path) and RETURN the conversation id its user turn landed in, so the
    /// `NotificationDelegate` can deep-link the user straight into that chat.
    ///
    /// Resolution order — ALWAYS returns the target id when one exists, no matter
    /// WHICH drainer actually processed the envelope (the founder Phase-D bug was
    /// a racy resolution: when the foreground `drain()` won the claim, this method
    /// raced ahead of the late `state.json` write and returned nil → no nav):
    ///   1. CASE A — still PUBLISHED → CLAIM + `process` → return its routed id.
    ///      A nil (pre-routing bail: undecodable manifest / not-configured) falls
    ///      through to the message fallback (there may already be a landed turn
    ///      from a prior partial run — cheap to check, harmless if absent).
    ///   2. CASE B/C — already claimed by a concurrent `drain()`, or already
    ///      deleted on success → resolve the target WITHOUT claiming / re-
    ///      processing / re-dispatching, via `resolveConversationID(forEnvelope:)`:
    ///        (i)  `state.json` conversationID — now written EARLY (right after
    ///             routing, `submitted: false`), so it's readable even mid-upload;
    ///        (ii) else POLL the durable message (`Message.id == envelope uuid`)
    ///             → its conversation, covering a slow binary upload that precedes
    ///             the append. Give up after the poll budget → nil (app just
    ///             opens, no nav — acceptable last resort).
    ///
    /// SAFE alongside `drain()` (the actor serializes both; the `moveItem` claim +
    /// `inFlightEnvelopes` set are the double-dispatch guards). The CASE B/C path
    /// is strictly READ-ONLY — it never claims, re-processes, or re-dispatches an
    /// envelope another drain owns.
    func drainAndResolve(envelopeID: String) async -> UUID? {
        ensureScaffold()
        guard let uuid = UUID(uuidString: envelopeID) else { return nil }

        let fm = FileManager.default
        let published = inboxBase.appendingPathComponent(uuid.uuidString, isDirectory: true)

        // CASE A — still PUBLISHED: claim + process this one envelope and capture
        // the resolved/minted conversation id from the routing Resolved.
        if fm.fileExists(atPath: published.path) {
            let claimed = processingDir.appendingPathComponent(uuid.uuidString, isDirectory: true)
            do {
                try fm.moveItem(at: published, to: claimed)
                // Mark in-flight SYNCHRONOUSLY in the same actor region as the claim
                // (no `await` between the `moveItem` and this insert) so a concurrent
                // `drain()`→`reconcileProcessing` never re-processes + re-dispatches
                // the envelope this call now owns.
                inFlightEnvelopes.insert(uuid.uuidString)
                if let id = await process(uuid, dir: claimed, existingState: nil) {
                    return id
                }
                // process returned nil (pre-routing bail) — fall through to the
                // durable-resolution fallback below.
            } catch {
                // Lost the claim race to a concurrent drain() — fall through to the
                // durable-resolution fallback below (that drain owns the dispatch).
            }
        }

        // CASE B/C — already claimed by a concurrent drain(), or already deleted on
        // success: resolve the target id durably (state.json → message poll),
        // never claiming / re-processing / re-dispatching.
        return await resolveConversationID(forEnvelope: uuid)
    }

    /// Resolve the conversation id an envelope's turn landed in WITHOUT touching
    /// the dispatch path (read-only). Tries the durable `state.json` (written
    /// EARLY at routing, `submitted: false`) first, then POLLS the durable message
    /// (`Message.id == envelope uuid` → its conversation) to cover the window
    /// where a concurrent `drain()` is still mid-upload before the append. Returns
    /// nil after the poll budget (the tap then just foregrounds without a
    /// deep-link — acceptable last resort).
    private func resolveConversationID(forEnvelope uuid: UUID) async -> UUID? {
        let dir = processingDir.appendingPathComponent(uuid.uuidString, isDirectory: true)

        // ~12 attempts × 150ms ≈ 1.8s — covers a slow binary upload (which precedes
        // the append) before giving up. Each attempt re-checks BOTH sources because
        // the concurrent drain writes state.json early (readable almost immediately)
        // but the message append lands later.
        let attempts = 12
        let delayNanos: UInt64 = 150 * 1_000_000
        for attempt in 0..<attempts {
            // (i) durable state.json — written right after routing succeeds.
            if let id = readState(from: dir)?.conversationID {
                return id
            }
            // (ii) durable message — the shared turn's id IS the envelope uuid.
            if let id = try? await store.conversationID(forMessageID: uuid) {
                return id
            }
            // Don't sleep after the final attempt.
            if attempt < attempts - 1 {
                try? await Task.sleep(nanoseconds: delayNanos)
            }
        }
        return nil
    }

    // MARK: - Claim + process

    /// Atomically CLAIM a published envelope (move `Inbox/<uuid>/` →
    /// `processing/<uuid>/`) then process it. The move IS the cross-process /
    /// cross-drain race guard: if it fails because the source is gone, another
    /// drain already claimed it — skip silently.
    private func claimAndProcess(_ envelopeID: UUID) async {
        let published = inboxBase.appendingPathComponent(envelopeID.uuidString, isDirectory: true)
        let claimed = processingDir.appendingPathComponent(envelopeID.uuidString, isDirectory: true)
        do {
            try FileManager.default.moveItem(at: published, to: claimed)
        } catch {
            // Lost the claim race (another drain moved it) or it vanished — skip.
            return
        }
        // Mark in-flight SYNCHRONOUSLY in the same actor region as the claim (no
        // `await` between the `moveItem` and this insert) so a concurrent
        // `reconcileProcessing` over `processing/` never re-processes this dir.
        inFlightEnvelopes.insert(envelopeID.uuidString)
        _ = await process(envelopeID, dir: claimed, existingState: nil)
    }

    /// Process a CLAIMED envelope (in `processing/<uuid>/`). `existingState` is
    /// the decoded `state.json` when this is a relaunch re-run of a
    /// `submitted==false` leftover (so we don't re-read it); nil on a fresh claim.
    ///
    /// Steps: decode manifest → resolve-or-mint routing →
    /// classify each item (image / text-file / binary→upload) → append the user
    /// turn (idempotent on the envelope UUID) → assemble prior+current wire
    /// material → durably mark `submitted` → dispatch → delete on success,
    /// on failure surface it + delete (turn-exists → flip the exact turn `failed`
    /// + notify + delete; no-turn → notify + delete).
    ///
    /// Returns the RESOLVED/MINTED conversation id once routing succeeds (so the
    /// confirmation-notification-tap path can deep-link the user into the target
    /// chat — `drainAndResolve`). Returns nil on any pre-routing bail
    /// (undecodable manifest / not-configured) — there is no conversation to open
    /// in those cases. NOTE: a non-nil return only means the turn was ROUTED +
    /// appended; a later dispatch failure still flips that turn `failed` + deletes
    /// the envelope but keeps the conversation id, so the tap still opens the
    /// thread the user's turn landed in.
    @discardableResult
    private func process(_ envelopeID: UUID, dir: URL, existingState: EnvelopeState?) async -> UUID? {
        // Own this envelope for the lifetime of the call so a concurrent
        // reconcile / drain never re-processes it (double-dispatch guard). Insert
        // is idempotent on the Set — the claim sites (`claimAndProcess` /
        // `drainAndResolve`) already inserted before calling; the
        // `reconcileProcessing` re-run path reaches here WITHOUT a prior claim, so
        // this insert also covers it. Cleared on EVERY exit via `defer`.
        inFlightEnvelopes.insert(envelopeID.uuidString)
        defer { inFlightEnvelopes.remove(envelopeID.uuidString) }

        let manifestURL = dir.appendingPathComponent("manifest.json")
        guard let manifestData = try? Data(contentsOf: manifestURL),
              let manifest = try? SharedInboxManifest.decode(manifestData) else {
            // An envelope without a decodable manifest can never be routed —
            // fail it (notify "couldn't send" + delete) rather than loop on it
            // forever. No turn was appended → no inline bubble.
            failNoTurn(envelopeID, dir: dir, reason: .couldNotSend)
            return nil
        }

        // --- Routing (resolve-or-mint via the shared helper) ---
        // Thread the manifest's full target precedence: an existing-conversation
        // pick (`conversationID`), a new-on-gateway pick
        // (`newConversationGatewayRef`), and the deleted-conversation mint
        // fallback hint (`selectedBackendRef`).
        let routed: SharedInboxRouting.Resolved
        do {
            routed = try await router(
                manifest.conversationID,
                manifest.newConversationGatewayRef,
                manifest.selectedBackendRef,
                settings,
                store
            )
        } catch {
            // Not-configured (no default URL/token, or the picked gateway/thread
            // is gone) — fail the whole envelope (notify + delete). No turn was
            // appended yet → no inline bubble; the generic "couldn't send" copy.
            failNoTurn(envelopeID, dir: dir, reason: .couldNotSend)
            return nil
        }

        // --- Persist the routed conversationID EARLY (navigation resolution) ---
        // The target conversation is KNOWN the moment routing succeeds — long
        // before the slow classify/upload/append/dispatch steps. Persist it NOW
        // (with `submitted: false`) so a near-simultaneous `drainAndResolve`
        // (notification-tap navigation) can read it from `state.json` even while
        // THIS call is still mid-upload (binary shares upload before the append) —
        // without that, the tap raced ahead of the later pre-dispatch
        // `submitted: true` write and resolved nil → no navigation (founder Phase-D
        // bug). `submitted: false` is consistent with crash-reconcile semantics: a
        // crash before dispatch → submitted==false → re-process on relaunch (the
        // in-flight guard prevents live double-processing). The pre-dispatch
        // `submitted: true` write below still seals the at-most-once dispatch
        // window.
        writeState(EnvelopeState(conversationID: routed.conversationID, submitted: false), into: dir)

        // Capture one READY lane for the whole envelope. Every upload, storedKey
        // owner marker, history splice, request instruction, and output scan
        // uses this immutable snapshot. The live dispatcher revalidates it
        // immediately before the actual send.
        let dispatchFileLane = await fileTransferSnapshotProvider(routed.ref, settings)

        // --- Classify each manifest item → drafts + wire material ---
        // Loaded from `processing/<uuid>/<relPath>` (the CLAIMED dir). A binary
        // routed to a server-less gateway FAILS the whole envelope (notify +
        // delete, never a partial send); a live in-flight upload DEFERS it.
        var drafts: [AttachmentDraft] = []
        var currentImageDataURIs: [String] = []
        var textFileBlocks: [(filename: String, text: String)] = []
        var serverFileRefs: [(originalName: String, storedKey: String)] = []
        /// DUAL-TEXT disk refs (this-turn): a small text file uploaded to the
        /// file-server rides inline AND splices an "also on disk" ref so the
        /// agent's tools reach the real file. Threaded into the dispatch as
        /// `newUserTextFileServerRefs` (mirrors the composer).
        var textFileServerRefs: [(originalName: String, storedKey: String)] = []
        /// DUAL-IMAGE disk refs (this-turn): an image dual-routed to the
        /// file-server rides inline (vision) AND uploads its ORIGINAL raw bytes,
        /// splicing a "saved as" ref (`spliceImageServerRefs`) so the agent's
        /// tools reach the byte-faithful file. Tuple order is `(storedKey,
        /// filename)` — the OPPOSITE of the text refs above; the element labels
        /// guard it. Threaded into the dispatch as `newUserImageFileRefs`
        /// (mirrors the composer's `.dualImage`).
        var imageFileServerRefs: [(storedKey: String, filename: String)] = []
        /// Running inline-text budget for the planner's per-turn cap (decremented
        /// in staged order as inline text files are accepted).
        var inlineTextBudgetRemaining = Constants.textInlineTurnBudgetBytes

        // Inline images use the same fixed cap as the composer path — the
        // "Max image dimension" setting was removed (vision cost is pixel-based;
        // 1568 is the sweet spot). Images DUAL-route exactly like the composer:
        // the downsized JPEG rides inline (vision) AND, when the bound gateway has
        // a file-server, the ORIGINAL raw bytes upload so the agent's tools act on
        // the byte-faithful file. Inline-only otherwise; a failed upload degrades
        // to inline-only (inline is the guaranteed fallback — never fails).
        let maxPixel = ImageProcessor.defaultMaxPixel

        for item in manifest.items.sorted(by: { $0.sequence < $1.sequence }) {
            let fileURL = dir.appendingPathComponent(item.relPath)
            // A published envelope should carry every item's bytes (the appex
            // publishes via an atomic rename). An unreadable/missing item ⇒ a
            // corrupt envelope — fail the WHOLE share rather than silently drop a
            // shared item (no partial-send without consent). Fails
            // BEFORE the user turn is appended → no thread to open (notify +
            // delete). Readability is checked WITHOUT reading the bytes — a
            // multi-GB shared video must never transit memory here: the image
            // branch reads its (small) bytes lazily, the text probe is
            // type/size-guarded, and the binary branch streams a file-to-file copy
            // into the upload.
            guard FileManager.default.isReadableFile(atPath: fileURL.path) else {
                failNoTurn(envelopeID, dir: dir, reason: .couldNotSend)
                return nil
            }
            let fileByteCount = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0

            switch classify(item) {
            case .image:
                // SIZE GUARD (mirror the composer's >100 MB image rule): the
                // inline-vision path below NEEDS the whole image in memory
                // (`Data(contentsOf:)` + `ImageProcessor.process`), so an image
                // over `fileTransferSoftConfirmBytes` (100 MB) must NOT be
                // heap-loaded here — a 500 MB TIFF would spike this actor's memory
                // just to downsize a thumbnail. Route it down the binary path
                // (streamed file-to-file copy → server file ref, NO inline Data
                // read, NO vision). **ONLY when a file-server is configured** — the
                // server route is the only way to send an oversized image WITHOUT
                // heap-loading it. With NO file-server there is no such route, so we
                // fall through to the inline path and send it inline exactly as
                // before (the rare, off-actor memory spike is the accepted trade —
                // failing the whole share would be a worse regression, since a
                // smaller image on the same server-less gateway still sends inline).
                // `fileByteCount` is the `.fileSizeKey` value read above (no bytes
                // touched); the presence check is a local settings read (no network).
                if fileByteCount > Constants.fileTransferSoftConfirmBytes,
                   dispatchFileLane != nil {
                    switch await handleBinaryItem(
                        item,
                        fileURL: fileURL,
                        fileByteCount: fileByteCount,
                        routed: routed,
                        manifest: manifest,
                        fileTransferSnapshot: dispatchFileLane
                    ) {
                    case .appended(let draft, let ref):
                        drafts.append(draft)
                        serverFileRefs.append(ref)
                    case .deferEnvelope:
                        return nil
                    case .failed(let reason):
                        failNoTurn(envelopeID, dir: dir, reason: reason)
                        return nil
                    }
                    continue
                }
                guard let bytes = try? Data(contentsOf: fileURL),
                      let processed = try? await ImageProcessor.shared.process(bytes, maxPixel: maxPixel) else {
                    // Bytes unreadable or undecodable (corrupt / unsupported).
                    // Fail the WHOLE envelope rather than silently dropping the
                    // user's image while sending the rest (no partial-send without
                    // consent). No turn appended yet → notify +
                    // delete. (No inline copy is possible → no graceful fallback.)
                    failNoTurn(envelopeID, dir: dir, reason: .couldNotSend)
                    return nil
                }
                // The inline vision draft is the GUARANTEED fallback — built as a
                // `var` so a successful dual upload can stamp its `storedKey`
                // (isServerReference STAYS false: inline bytes are retained, it
                // renders as an inline image, and `priorTurns` ages it via the
                // persisted key on later turns — same shape as the composer's dual).
                var imageDraft = AttachmentDraft(
                    mimeType: "image/jpeg",
                    data: processed.jpegData,
                    thumbnailData: processed.thumbnailData,
                    width: processed.width,
                    height: processed.height,
                    byteSize: processed.byteSize,
                    sequence: item.sequence
                )
                // DUAL-route when the bound gateway has a file-server: upload the
                // ORIGINAL raw bytes (true HEIC/PNG/DNG/JPEG, metadata intact) so the
                // agent's tools act on the byte-faithful file while it still SEES the
                // inline copy. Best-effort: ANY failure on the server-copy side
                // (snapshot race, throwaway copy, or upload) degrades to inline-only
                // — NEVER a failure (inline is the guaranteed fallback, mirroring
                // the composer's `.dualImage`, which never gates Send).
                if let ftSnapshot = dispatchFileLane {
                    // Real shared filename when present (deterministic across
                    // re-drains → idempotent re-PUT); else synthesize `image.<ext>`
                    // from the ORIGINAL bytes' sniffed format (also deterministic).
                    let filename = item.originalName ?? "image.\(ImageFormatSniffer.sniff(bytes).ext)"
                    let key = FileServerClient.deterministicStoredKey(
                        envelopeID: manifest.uuid,
                        sequence: item.sequence,
                        originalName: filename,
                        folder: ftSnapshot.folderCapable ? routed.conversationID.uuidString : nil
                    )
                    if await uploader.hasLiveUploadTask(shareEnvelopeID: manifest.uuid, sequence: item.sequence) {
                        // A prior process's upload for this attachment is still in
                        // flight — DEFER the whole envelope (no turn appended yet →
                        // nothing to deep-link). The next drain re-evaluates.
                        return nil
                    }
                    // `uploadFile` DELETES its input — hand it a THROWAWAY copy of the
                    // ORIGINAL bytes so the inbox original stays intact for replay.
                    let throwaway = FileManager.default.temporaryDirectory
                        .appendingPathComponent("conduck-share-imgupload-\(UUID().uuidString)")
                    do {
                        try FileManager.default.copyItem(at: fileURL, to: throwaway)
                        try await uploader.uploadFile(
                            localURL: throwaway,
                            snapshot: ftSnapshot,
                            storedKey: key,
                            shareEnvelopeID: manifest.uuid,
                            sequence: item.sequence
                        )
                        imageDraft.storedKey = key
                        imageFileServerRefs.append((storedKey: key, filename: filename))
                    } catch {
                        // GRACEFUL: the throwaway copy or upload failed — fall through
                        // to inline-only. The image still rides inline (the user can
                        // see it); no storedKey, no ref, no failure.
                        try? FileManager.default.removeItem(at: throwaway)
                    }
                }
                drafts.append(imageDraft)
                currentImageDataURIs.append(DataURIBuilder.jpegDataURI(from: processed.jpegData))

            case .undetermined:
                // Try the text-file extractor; success → TEXT (planner-routed).
                // Failure (`.undecodable`) → it's a BINARY → the file-server path.
                // GUARDED by a cheap pre-check: the probe is a WHOLE-FILE memory
                // read, so obviously-binary declared types (video / audio /
                // archive) and anything over `textProbeMaxBytes` go straight to
                // the binary branch (which streams). A "text" file that large
                // couldn't usefully ride inline anyway.
                if shouldAttemptTextProbe(item, byteCount: fileByteCount),
                   let extracted = try? TextFileExtractor.extract(from: fileURL),
                   let textData = extracted.text.data(using: .utf8) {
                    // Route text through the SAME planner as the composer so a
                    // shared `.md`/`.csv` lands IDENTICALLY: text+server small →
                    // dual (inline + upload); text+server large → file-only upload;
                    // text+no-server → inline (today's behavior). Routed by the
                    // EXTRACTED byte count.
                    let ftSnapshot = dispatchFileLane
                    // A capture the appex SYNTHESIZED (vs. a user-shared *.md that
                    // merely happens to be named that way — `sourceKind` is the
                    // identity, filename convention is not). Two webpage-only
                    // effects: the display filename prefers the appex's human-readable
                    // `originalName`, and on a server-less gateway the planner clamps
                    // the inline copy (see `plan.inlineByteLimit`).
                    let isWebpageCapture = item.sourceKind == WebPageCapture.sourceKindWebpage
                    // Chip / fence / upload-key label. Webpage → the appex's
                    // "Captured Page — <title>.md" (`originalName`); every other text
                    // item keeps the extractor's synthetic `att-N.md`, byte-identical
                    // to today. Shadowed onto `extracted` ONCE below so the PERSISTED
                    // `AttachmentDraft.filename` carries it — prior-turn replay reads
                    // that name on every later turn (`ConverseRequest` history
                    // assembly), not just this turn's splice.
                    let displayFilename = isWebpageCapture ? (item.originalName ?? extracted.filename) : extracted.filename
                    // From here `extracted.filename` IS the display name, so every
                    // consumer below reads it straight off `extracted` (no per-site
                    // substitution). Rebind once; `text`/`mimeType` pass through.
                    let extracted = TextFileExtractor.ExtractedFile(
                        filename: displayFilename,
                        mimeType: extracted.mimeType,
                        text: extracted.text
                    )
                    let plan = AttachmentDeliveryPlanner.plan(
                        extractedByteCount: textData.count,
                        fileServerPresent: ftSnapshot != nil,
                        inlineBudgetRemaining: inlineTextBudgetRemaining,
                        clampInlineWhenServerless: isWebpageCapture
                    )

                    if plan.serverCopy == .none {
                        // INLINE-ONLY (no file-server). Regular text rides UNLIMITED
                        // (today's behavior). A WEBPAGE capture instead carries a
                        // `plan.inlineByteLimit`: this client-owned-history protocol
                        // re-sends the FULL conversation every turn, so an unbounded
                        // page would tax every subsequent turn — clamp to the inline
                        // cap with an honest note (`truncatedForInline` counts the
                        // note's bytes INSIDE the cap → result ≤ limit). For regular
                        // text `inlineByteLimit` is nil, so `inlineText`/`inlineData`
                        // stay `extracted.text`/`textData` — byte-for-byte unchanged.
                        let inlineText: String
                        let inlineData: Data
                        if let limit = plan.inlineByteLimit, textData.count > limit {
                            inlineText = WebPageCapture.truncatedForInline(
                                extracted.text,
                                limit: limit,
                                originalByteCount: textData.count
                            )
                            inlineData = Data(inlineText.utf8)
                        } else {
                            inlineText = extracted.text
                            inlineData = textData
                        }
                        drafts.append(
                            AttachmentDraft(
                                mimeType: extracted.mimeType,
                                filename: extracted.filename,
                                data: inlineData,
                                thumbnailData: nil,
                                width: 0,
                                height: 0,
                                byteSize: inlineData.count,
                                sequence: item.sequence
                            )
                        )
                        textFileBlocks.append((filename: extracted.filename, text: inlineText))
                        inlineTextBudgetRemaining = max(0, inlineTextBudgetRemaining - inlineData.count)
                    } else if let ftSnapshot {
                        // SERVER copy needed (preferred dual, or required file-only).
                        // Upload the RAW file bytes (the agent's tools act on the
                        // byte-faithful original) under a deterministic key
                        // (idempotent re-PUT on replay). A live in-flight upload →
                        // DEFER the whole envelope.
                        let key = FileServerClient.deterministicStoredKey(
                            envelopeID: manifest.uuid,
                            sequence: item.sequence,
                            originalName: extracted.filename,
                            folder: ftSnapshot.folderCapable ? routed.conversationID.uuidString : nil
                        )
                        if await uploader.hasLiveUploadTask(shareEnvelopeID: manifest.uuid, sequence: item.sequence) {
                            return nil
                        }
                        let throwaway = FileManager.default.temporaryDirectory
                            .appendingPathComponent("conduck-share-upload-\(UUID().uuidString)")
                        do {
                            try FileManager.default.copyItem(at: fileURL, to: throwaway)
                            try await uploader.uploadFile(
                                localURL: throwaway,
                                snapshot: ftSnapshot,
                                storedKey: key,
                                shareEnvelopeID: manifest.uuid,
                                sequence: item.sequence
                            )
                        } catch {
                            try? FileManager.default.removeItem(at: throwaway)
                            if plan.inline {
                                // DUAL (small) text: inline is the GUARANTEED fallback
                                // — degrade to inline-only (drop the storedKey/ref),
                                // mirroring the composer's `.dualText` (never gates
                                // Send). NOT a failure; the text still rides inline.
                                drafts.append(
                                    AttachmentDraft(
                                        mimeType: extracted.mimeType,
                                        filename: extracted.filename,
                                        data: textData,
                                        thumbnailData: nil,
                                        width: 0,
                                        height: 0,
                                        byteSize: textData.count,
                                        sequence: item.sequence
                                    )
                                )
                                textFileBlocks.append((filename: extracted.filename, text: extracted.text))
                                inlineTextBudgetRemaining = max(0, inlineTextBudgetRemaining - textData.count)
                                continue
                            }
                            // FILE-ONLY (large / over-budget) has NO inline fallback —
                            // fail the whole envelope (notify + delete; no turn yet).
                            failNoTurn(envelopeID, dir: dir, reason: .couldNotSend)
                            return nil
                        }

                        if plan.inline {
                            // DUAL: persist an INLINE text draft that ALSO carries
                            // the upload `storedKey` (isServerReference STAYS false —
                            // `isText && storedKey != nil`, renders as a text chip,
                            // not a download chip), inline the fenced block, AND
                            // splice the "also on disk" dual-text ref.
                            var draft = AttachmentDraft(
                                mimeType: extracted.mimeType,
                                filename: extracted.filename,
                                data: textData,
                                thumbnailData: nil,
                                width: 0,
                                height: 0,
                                byteSize: textData.count,
                                sequence: item.sequence
                            )
                            draft.storedKey = key
                            drafts.append(draft)
                            textFileBlocks.append((filename: extracted.filename, text: extracted.text))
                            textFileServerRefs.append((originalName: extracted.filename, storedKey: key))
                            inlineTextBudgetRemaining = max(0, inlineTextBudgetRemaining - textData.count)
                        } else {
                            // FILE-ONLY (large / over-budget): a server-reference
                            // draft (empty data, no inline fence) + the imperative
                            // "in your working directory" ref.
                            var draft = AttachmentDraft(
                                mimeType: extracted.mimeType,
                                filename: extracted.filename,
                                data: Data(),
                                thumbnailData: nil,
                                width: 0,
                                height: 0,
                                byteSize: textData.count,
                                sequence: item.sequence
                            )
                            draft.isServerReference = true
                            draft.storedKey = key
                            drafts.append(draft)
                            serverFileRefs.append((originalName: extracted.filename, storedKey: key))
                        }
                    } else {
                        // Planner asked for a server copy but the snapshot vanished
                        // between the check and here (race) — fall back to inline.
                        drafts.append(
                            AttachmentDraft(
                                mimeType: extracted.mimeType,
                                filename: extracted.filename,
                                data: textData,
                                thumbnailData: nil,
                                width: 0,
                                height: 0,
                                byteSize: textData.count,
                                sequence: item.sequence
                            )
                        )
                        textFileBlocks.append((filename: extracted.filename, text: extracted.text))
                        inlineTextBudgetRemaining = max(0, inlineTextBudgetRemaining - textData.count)
                    }
                } else {
                    // BINARY — needs the bound gateway's file-server (streamed
                    // file-to-file upload → server-reference draft, NEVER a heap
                    // read). Handled by the shared `handleBinaryItem` helper so the
                    // oversized-image guard above and this branch route IDENTICALLY.
                    // NIL snapshot → fail the WHOLE envelope (never send the
                    // image/text subset silently; notify + delete). A
                    // live in-flight upload → DEFER the whole envelope (next drain
                    // retries). Upload fail → fail the whole envelope. No turn
                    // appended yet → any failure is a no-turn notify + delete.
                    switch await handleBinaryItem(
                        item,
                        fileURL: fileURL,
                        fileByteCount: fileByteCount,
                        routed: routed,
                        manifest: manifest,
                        fileTransferSnapshot: dispatchFileLane
                    ) {
                    case .appended(let draft, let ref):
                        drafts.append(draft)
                        serverFileRefs.append(ref)
                    case .deferEnvelope:
                        return nil
                    case .failed(let reason):
                        failNoTurn(envelopeID, dir: dir, reason: reason)
                        return nil
                    }
                }
            }
        }

        // --- User text = caption + the shared URLs (mirror text+urls combine) ---
        let userText = composeUserText(caption: manifest.caption, urls: manifest.urls)

        // --- Append the user turn (idempotent on the envelope UUID) ---
        // The envelope UUID is BOTH the dedupe key AND the new `Message.id`, so a
        // re-drain after a crash never produces a second user turn. `status:
        // "sending"` drives the bubble spinner until the delegate flips it.
        do {
            _ = try await store.appendMessage(
                id: manifest.uuid,
                role: "user",
                text: userText,
                conversationID: routed.conversationID,
                sourceDevice: SourceDevice.current,
                status: "sending",
                fileTransferLaneID: drafts.contains(where: { $0.storedKey?.isEmpty == false })
                    ? dispatchFileLane?.durableLaneID
                    : nil,
                attachments: drafts
            )
        } catch {
            // The conversation row vanished (rare CloudKit race) — the append
            // threw, so NO turn landed. Notify "couldn't send" + delete; never
            // lose the share silently.
            failNoTurn(envelopeID, dir: dir, reason: .couldNotSend)
            return nil
        }

        // The user's turn is now durably in `routed.conversationID` — from here on
        // every terminal path RETURNS this id so the confirmation-notification tap
        // can deep-link the user into the chat their share landed in (even if the
        // subsequent dispatch fails: the turn is still in that thread, flipped to
        // `failed` with inline Retry).
        let landedConversationID = routed.conversationID

        // --- Assemble prior turns (mirror sendUserTurn, shared assembler) ---
        // A continued thread that already contains images RETAINS them in
        // context (client-owned history — the locked image-context decision):
        // the assembler re-resolves each prior turn's image bytes into data-URIs
        // (EXCLUDING the just-appended user turn) and applies the bound ref's
        // `ImageHistoryPolicy` (inline window / disk-ref demotion / orphan
        // expiry). `try?` preserves the non-throwing posture (a store hiccup
        // dispatches with empty history rather than quarantining the share).
        let priorTurns = (try? await ConversationHistoryAssembler.assemble(
            conversationID: routed.conversationID,
            excludingUserMessageID: manifest.uuid,
            excludingNewUserText: userText,
            boundRef: routed.ref,
            dispatchFileLaneID: dispatchFileLane?.durableLaneID,
            store: store
        )) ?? []

        // --- Durably mark `submitted` BEFORE dispatch (mark-before-resume) ---
        // This is the crash-window seal: if the process dies after this write but
        // before/within dispatch, the relaunch reconcile sees `submitted==true`
        // and resolves at-most-once (leave / delete / fail-the-turn — never
        // resend).
        writeState(EnvelopeState(conversationID: routed.conversationID, submitted: true), into: dir)
        // Explicit surface — a share deliberately does NOT stamp the per-device
        // quick-capture pointer: routing above may passively LAND the share in
        // the quick thread (it reads the pointer), but a share never EXTENDS
        // or retargets the quick lane (implicit-only writes).

        // --- Dispatch the converse turn ---
        // Awaiting is correct: the delegate ALSO lands the reply + notification,
        // so a mid-await background just leaves the dir in processing/ for the
        // relaunch reconcile. On success → delete the envelope; on throw → flip
        // the exact turn `failed` (inline Retry) + red dot + deep-link
        // notification + delete (`failWithTurn`).
        do {
            _ = try await dispatcher.dispatch(
                backend: routed.snapshot.backend,
                ref: routed.snapshot.ref,
                url: routed.snapshot.url,
                token: routed.token,
                authScheme: routed.snapshot.authScheme,
                model: routed.snapshot.model,
                priorTurns: priorTurns,
                newUserText: userText,
                newUserImageDataURIs: currentImageDataURIs,
                newUserTextFileBlocks: textFileBlocks,
                newUserServerFileRefs: serverFileRefs,
                newUserImageFileRefs: imageFileServerRefs,
                newUserTextFileServerRefs: textFileServerRefs,
                fileTransferSnapshot: dispatchFileLane,
                conversationID: routed.conversationID,
                shareEnvelopeID: manifest.uuid
            )
            // SUCCESS — the delegate appended the agent bubble + notified; drop
            // the whole envelope (its replay source is no longer needed).
            try? FileManager.default.removeItem(at: dir)
            return landedConversationID
        } catch is CancellationError {
            // Cancelled (no in-app cancel exists on the share path, but the seam
            // could surface one) — leave the envelope in processing/ for the next
            // drain rather than fail it; the user turn stays `sending`.
            return landedConversationID
        } catch {
            // Dispatch threw AFTER the user turn was appended — the turn EXISTS.
            // Flip THAT exact turn (id == envelope uuid == `manifest.uuid`) to
            // `failed` (inline failed bubble + Retry re-sends from Core Data),
            // raise the menu-bar red dot, post a deep-linking notification, then
            // delete the envelope. The optimistic bubble would otherwise spin
            // forever (it only healed via a LATER turn's pending-flip). At-most-
            // once holds — inline Retry never re-uses the deleted envelope.
            // The thrown error + the dispatch-time history-image fact ride
            // along so the classification persists (macOS foreground
            // path — the iOS delegate writes its own).
            await failWithTurn(
                manifest.uuid,
                dir: dir,
                conversationID: routed.conversationID,
                error: error,
                requestHadHistoryImages: ConverseRequest.containsImageParts(priorTurns)
            )
            return landedConversationID
        }
    }

    // MARK: - Binary attachment handling

    /// Outcome of routing one item down the binary (server-file) path. Returned so
    /// BOTH call sites (the `.undetermined` binary branch AND the oversized-image
    /// guard in `.image`) share ONE upload/failure implementation instead of
    /// duplicating it — the caller owns the envelope-level side effects
    /// (accumulate / defer via `return nil` / `failNoTurn` + `return nil`).
    private enum BinaryOutcome {
        /// Uploaded — accumulate the server-reference draft + dispatch ref.
        case appended(draft: AttachmentDraft, serverFileRef: (originalName: String, storedKey: String))
        /// A prior process's upload for this attachment is still LIVE — the caller
        /// leaves the envelope in `processing/` for the next drain (no partial send).
        case deferEnvelope
        /// Terminal pre-append failure — the caller `failNoTurn`s the whole
        /// envelope with this reason (no file-server / upload fail).
        case failed(NoTurnFailure)
    }

    /// Route ONE item to the bound gateway's file-server as a server-reference
    /// attachment — a STREAMED file-to-file copy into the upload, NEVER a heap
    /// read of the bytes. Shared by the `.undetermined` binary branch and the
    /// oversized-image guard (an image over `fileTransferSoftConfirmBytes` must be
    /// treated exactly like a binary — no inline vision heap-load), so the two
    /// paths can't drift. Idempotent on replay (deterministic key → re-PUT).
    private func handleBinaryItem(
        _ item: SharedInboxManifestItem,
        fileURL: URL,
        fileByteCount: Int,
        routed: SharedInboxRouting.Resolved,
        manifest: SharedInboxManifest,
        fileTransferSnapshot: SettingsManager.FileTransferSnapshot?
    ) async -> BinaryOutcome {
        // NIL snapshot → the bound gateway has no file-server → fail the WHOLE
        // envelope (never send the rest silently).
        guard let ftSnapshot = fileTransferSnapshot else {
            return .failed(.needsFileServer)
        }
        let originalName = item.originalName ?? "file"
        // Per-conversation folder (every file a conversation receives lands under
        // `<conversationID>/`, composer + share alike), unless this gateway's
        // nested-PUT probe failed → flat key. Idempotent: a replay routes to the
        // SAME conversationID, so the folder segment is stable across re-mints.
        let key = FileServerClient.deterministicStoredKey(
            envelopeID: manifest.uuid,
            sequence: item.sequence,
            originalName: originalName,
            folder: ftSnapshot.folderCapable ? routed.conversationID.uuidString : nil
        )

        if await uploader.hasLiveUploadTask(shareEnvelopeID: manifest.uuid, sequence: item.sequence) {
            // A prior process's upload for this attachment is still in flight —
            // DEFER the whole envelope (the caller leaves it in processing/).
            return .deferEnvelope
        }

        // `uploadFile` DELETES its input — hand it a THROWAWAY copy so the inbox
        // original stays intact for replay.
        let throwaway = FileManager.default.temporaryDirectory
            .appendingPathComponent("conduck-share-upload-\(UUID().uuidString)")
        do {
            try FileManager.default.copyItem(at: fileURL, to: throwaway)
            try await uploader.uploadFile(
                localURL: throwaway,
                snapshot: ftSnapshot,
                storedKey: key,
                shareEnvelopeID: manifest.uuid,
                sequence: item.sequence
            )
        } catch {
            try? FileManager.default.removeItem(at: throwaway)
            // Upload failed (transport / HTTP) — fail the whole envelope.
            return .failed(.couldNotSend)
        }

        var draft = AttachmentDraft(
            mimeType: item.mimeType ?? "application/octet-stream",
            filename: originalName,
            data: Data(),
            thumbnailData: nil,
            width: 0,
            height: 0,
            byteSize: fileByteCount,
            sequence: item.sequence
        )
        draft.isServerReference = true
        draft.storedKey = key
        return .appended(draft: draft, serverFileRef: (originalName: originalName, storedKey: key))
    }

    // MARK: - Relaunch reconcile

    /// Reconcile an envelope found in `processing/` at the START of a drain — a
    /// prior process claimed it and then died (or is still mid-await; this drain
    /// only fires when the app is active again, so a same-process in-flight turn
    /// isn't here). Branches on the durable `state.json`:
    ///
    ///   - `submitted == true`:  (the converse was dispatched before the death)
    ///       · a LIVE converse task exists  → leave it (the delegate will land it)
    ///       · else a reply already landed   → SUCCESS → delete the dir
    ///       · else (no task, no reply)       → FAIL (at-most-once — NEVER
    ///         auto-resend; a resend would double-hit the user's gateway). The
    ///         user turn EXISTS (`submitted` is written AFTER the append), so flip
    ///         that exact turn `failed` + notify (deep-link) + delete the dir.
    ///   - `submitted == false` / no state:  re-run Process (idempotent — dedupe
    ///     append + idempotent re-PUT + the upload reconcile defers a live upload).
    private func reconcileProcessing(_ envelopeID: UUID) async {
        // A LIVE `process(...)` call in THIS run already owns this dir (e.g. a
        // notification-tap `drainAndResolve` claimed it and is mid-`await` before
        // `writeState(submitted:true)`). Re-processing it here would fire a SECOND
        // dispatch — double-hitting the user's gateway. The `moveItem` claim only
        // guards the INITIAL claim; this set guards the reconcile-vs-live window.
        // Checked SYNCHRONOUSLY before any `await` so the decision can't tear.
        if inFlightEnvelopes.contains(envelopeID.uuidString) {
            return
        }

        let dir = processingDir.appendingPathComponent(envelopeID.uuidString, isDirectory: true)
        let state = readState(from: dir)

        guard let state, state.submitted else {
            // submitted==false OR no state → re-run Process from scratch.
            await process(envelopeID, dir: dir, existingState: state)
            return
        }

        // submitted==true → at-most-once reconcile.
        if await dispatcher.hasLiveConverseTask(shareEnvelopeID: envelopeID) {
            // Still in flight (the prior process's background task survived) —
            // leave it; the delegate lands the reply + notification.
            return
        }

        // No live task. Did THIS share's reply land? Success iff an assistant
        // turn exists STRICTLY AFTER this share's user turn (id == envelopeID).
        // Checking "any agent message exists" would false-positive when the share
        // CONTINUED an existing thread that already held prior assistant turns —
        // we'd delete the envelope before this turn's reply arrived, silently
        // losing it. Comparing against the user turn's `createdAt` is
        // order-independent: a prior reply predates this user turn; this turn's
        // reply is appended after it. (A missing user turn — append never ran —
        // also correctly falls through to the failure path below.)
        if let conversationID = state.conversationID {
            let messages = (try? await store.fetchMessages(for: conversationID)) ?? []
            if let userTurn = messages.first(where: { $0.id == envelopeID }),
               messages.contains(where: { $0.role == "agent" && $0.createdAt > userTurn.createdAt }) {
                try? FileManager.default.removeItem(at: dir)
                return
            }
        }

        // Submitted, no live task, no landed reply → ambiguous → FAIL the turn
        // (at-most-once: never auto-resend). `submitted` is written AFTER the
        // append, so the user turn (id == envelopeID) exists → flip THAT exact
        // turn `failed` (inline failed bubble + Retry, which re-sends from Core
        // Data), raise the menu-bar red dot, notify (deep-link to the thread),
        // delete the envelope. If the conversationID is somehow absent there's no
        // thread to surface — still notify (don't drop the share silently), then
        // delete the dir.
        if let conversationID = state.conversationID {
            await failWithTurn(envelopeID, dir: dir, conversationID: conversationID)
        } else {
            failNoTurn(envelopeID, dir: dir, reason: .couldNotSend)
        }
    }

    // MARK: - Classification

    private enum ItemClass {
        /// UTType conforms to `public.image`, or the MIME type is `image/*`.
        case image
        /// Everything else — resolved at process time by trying
        /// `TextFileExtractor` (success → inline text; `.undecodable` → binary).
        case undetermined
    }

    /// Image vs. undetermined, from the manifest item's UTI / MIME. Text-vs-binary
    /// is NOT decided here — that needs the bytes (`TextFileExtractor` is the
    /// discriminator at process time), so non-image items fall to `.undetermined`.
    private func classify(_ item: SharedInboxManifestItem) -> ItemClass {
        if let uti = item.utTypeIdentifier,
           let type = UTType(uti),
           type.conforms(to: .image) {
            return .image
        }
        if let mime = item.mimeType, mime.hasPrefix("image/") {
            return .image
        }
        return .undetermined
    }

    /// Whether the text-vs-binary probe (`TextFileExtractor.extract`, a
    /// WHOLE-FILE memory read) may run on a shared `.undetermined` item. False
    /// for obviously-binary declared types (video / audio / archive) and anything
    /// over `Constants.textProbeMaxBytes` — those route straight to the binary
    /// branch (streamed copy + upload) without ever transiting memory.
    private func shouldAttemptTextProbe(_ item: SharedInboxManifestItem, byteCount: Int) -> Bool {
        // `.pdf` is excluded even though a rare all-ASCII PDF DECODES as UTF-8:
        // raw PDF markup is never useful inline text, and the text route would
        // silently skip the file-server transfer the user expects.
        if let uti = item.utTypeIdentifier, let type = UTType(uti),
           type.conforms(to: .audiovisualContent) || type.conforms(to: .archive)
            || type.conforms(to: .pdf) {
            return false
        }
        if let mime = item.mimeType,
           mime.hasPrefix("video/") || mime.hasPrefix("audio/") || mime == "application/pdf" {
            return false
        }
        return byteCount <= Constants.textProbeMaxBytes
    }

    /// Combine the user caption with the shared web URLs into the turn's text:
    /// caption first, then each URL on its own line. Either side may be empty (a
    /// photo-only share has no caption; a captioned-photo share has no URLs). De-
    /// duped + `file://`-rejected URLs are guaranteed by the appex's activation
    /// predicate, so no extra filtering here.
    private func composeUserText(caption: String, urls: [String]) -> String {
        let trimmedCaption = caption.trimmingCharacters(in: .whitespacesAndNewlines)
        var pieces: [String] = []
        if !trimmedCaption.isEmpty { pieces.append(trimmedCaption) }
        pieces.append(contentsOf: urls.filter { !$0.isEmpty })
        return pieces.joined(separator: "\n")
    }

    // MARK: - Three-state durability (state.json)

    /// The durable per-envelope drain state (`processing/<uuid>/state.json`).
    /// `submitted` is the mark-before-resume flag the relaunch reconcile branches
    /// on; `conversationID` records where the turn landed so the reconcile can
    /// look for the agent reply without re-routing.
    struct EnvelopeState: Codable, Sendable {
        let conversationID: UUID?
        let submitted: Bool
    }

    private func stateURL(in dir: URL) -> URL {
        dir.appendingPathComponent("state.json")
    }

    /// Write `state.json` DURABLY (atomic + complete file protection — matches
    /// `PendingRetryStore`'s posture; flagged for the deferred BG-drain path).
    private func writeState(_ state: EnvelopeState, into dir: URL) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: stateURL(in: dir), options: [.atomic, .completeFileProtection])
    }

    private func readState(from dir: URL) -> EnvelopeState? {
        // (state file lives alongside the manifest in the same envelope dir)
        guard let data = try? Data(contentsOf: stateURL(in: dir)) else { return nil }
        return try? JSONDecoder().decode(EnvelopeState.self, from: data)
    }

    // MARK: - Terminal failure (notify + delete; no quarantine graveyard)

    /// The no-turn failure reason — drives ONLY the notification copy. (No
    /// persisted marker, no recovery row: the envelope is deleted immediately.)
    private enum NoTurnFailure {
        /// A shared binary routed to a gateway with NO file-server configured —
        /// the whole envelope is failed (never a partial send).
        case needsFileServer
        /// Every other pre-append failure (undecodable manifest, routing fail,
        /// corrupt/undecodable item, file-only upload fail, conversation-row
        /// vanished) — generic "couldn't send" copy.
        case couldNotSend
    }

    /// Terminal failure for a share whose user turn was NEVER appended (the
    /// failure happened before the ~`appendMessage` site). There is no inline
    /// bubble to flip + no thread to deep-link, so post a USER notification
    /// stating it didn't send (the drainer notifies itself — share sends run with
    /// `notifyUser=false`, so `.remoteAgentTurnDidFail` alone would be silent),
    /// then DELETE the envelope. Nothing was sent → trivially at-most-once.
    private func failNoTurn(_ envelopeID: UUID, dir: URL, reason: NoTurnFailure) {
        postNoTurnFailureNotification(envelopeID: envelopeID, reason: reason)
        try? FileManager.default.removeItem(at: dir)
    }

    /// Terminal failure for a share whose user turn EXISTS in the conversation
    /// (dispatch threw after the append, or the relaunch reconcile found a
    /// submitted-but-unanswered turn). Flip THAT exact turn to `failed` (inline
    /// failed bubble + Retry, which re-sends fully from Core Data — never from the
    /// envelope), raise the macOS menu-bar red dot (`.remoteAgentTurnDidFail`),
    /// post a USER notification deep-linking to the thread (drainer-posted —
    /// share sends don't notify), then DELETE the envelope.
    ///
    /// AT-MOST-ONCE: deleting the envelope after the flip is safe because inline
    /// Retry re-dispatches from the store, NOT the envelope — the gateway was
    /// already hit (or attempted) exactly once and is never re-hit by this delete.
    private func failWithTurn(
        _ messageID: UUID,
        dir: URL,
        conversationID: UUID,
        error: Error? = nil,
        requestHadHistoryImages: Bool? = nil
    ) async {
        // EXACT-message flip (not the conversation-wide `markPendingUserTurns`):
        // a sibling in-flight turn in the same thread must keep its own lifecycle,
        // else its later success matches nothing and it shows a stale Retry.
        // With an error in hand, the guarded `failTurn` persists the
        // classification via the shared error→classification mapping (wire
        // code included when the gateway sent one); error-less callers
        // (relaunch reconcile) keep the status-only flip.
        if let error {
            await store.failTurn(
                messageID: messageID,
                classification: .init(from: error, hadHistoryImages: requestHadHistoryImages)
            )
        } else {
            await store.markPendingUserTurn(messageID: messageID, to: "failed")
        }
        // macOS menu-bar red dot (in-process bus; mirrors how the success path
        // posts `.remoteAgentTurnDidComplete`).
        await BackgroundRemoteAgent.postTurnFailed(conversationID: conversationID)
        // USER notification deep-linking into the failed turn's thread. The
        // `remoteAgent.failure.` identifier prefix is load-bearing: the delegate
        // deep-links it (real conversationID) but `ReplyAutoSpeakDecider` excludes
        // it from auto-speak (only `remoteAgent.reply.` taps speak).
        await BackgroundRemoteAgent.postFailureNotification(conversationID: conversationID, error: error?.unwrappedAppError)
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: - Janitor

    /// Sweep abandoned `tmp/<uuid>/` (>1h — an appex that crashed mid-write).
    /// NEVER touches a fresh `tmp/` (an appex write may be in progress) or a
    /// `processing/` dir (the reconcile owns those).
    private func janitor() {
        sweep(tmpDir, olderThan: Self.tmpStaleInterval)
    }

    /// Delete each child dir of `parent` whose modification date is older than
    /// `interval`. Modification date (not the manifest's `createdAt`) so a tmp/
    /// dir with no manifest yet (mid-write, then abandoned) is still sweepable.
    private func sweep(_ parent: URL, olderThan interval: TimeInterval) {
        let fm = FileManager.default
        guard let children = try? fm.contentsOfDirectory(
            at: parent, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]
        ) else { return }
        let cutoff = Date().addingTimeInterval(-interval)
        for child in children {
            let modified = (try? child.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
            if modified < cutoff {
                try? fm.removeItem(at: child)
            }
        }
    }

    // MARK: - Directory enumeration

    /// The PUBLISHED envelope IDs: direct child dirs of `inboxBase` whose name is
    /// a valid UUID. The two reserved sub-dirs (`tmp`/`processing`) are never
    /// valid UUIDs, so the parse already excludes them.
    private func publishedEnvelopeIDs() -> [UUID] {
        childEnvelopeIDs(of: inboxBase)
    }

    // MARK: - Diagnostics snapshot (read-only stuck-item count)

    /// How many shared items look STUCK — the Diagnostics screen's read-only
    /// probe. DRAINER-OWNED so the classification can't drift from the drain
    /// semantics it describes:
    ///   - a PUBLISHED envelope older than `threshold` counts ONLY once a full
    ///     `drain()` has completed in THIS process (`hasCompletedDrainThisProcess`)
    ///     — envelope age runs from when the SHARE was queued, so a share made
    ///     hours ago with the app closed is over-threshold at cold launch
    ///     BEFORE the foreground drain has had any chance to claim it; the
    ///     drain-completed gate is what makes "old AND still published" mean
    ///     "the drain isn't claiming it";
    ///   - a PROCESSING envelope older than `threshold` counts ONLY when it is
    ///     not owned by a live `process(...)` call in this run AND (for a
    ///     `submitted` one) no live background converse task exists — a
    ///     submitted envelope with a live task is a legitimately in-flight long
    ///     turn, never "stuck" (a naive age-only rule would false-warn on it).
    /// Envelope dirs keep their creation date across the claim move, so age =
    /// time since the share was queued. Mutates nothing.
    func diagnosticStuckCount(olderThan threshold: TimeInterval = 600) async -> Int {
        ensureScaffold()
        let fm = FileManager.default
        let now = Date()
        func age(of dir: URL) -> TimeInterval? {
            guard let created = (try? fm.attributesOfItem(atPath: dir.path))?[.creationDate] as? Date else {
                return nil
            }
            return now.timeIntervalSince(created)
        }

        var stuck = 0
        if hasCompletedDrainThisProcess {
            for id in publishedEnvelopeIDs() {
                let dir = inboxBase.appendingPathComponent(id.uuidString, isDirectory: true)
                if let age = age(of: dir), age > threshold { stuck += 1 }
            }
        }
        for id in childEnvelopeIDs(of: processingDir) {
            let dir = processingDir.appendingPathComponent(id.uuidString, isDirectory: true)
            guard let age = age(of: dir), age > threshold else { continue }
            if inFlightEnvelopes.contains(id.uuidString) { continue }
            if readState(from: dir)?.submitted == true,
               await dispatcher.hasLiveConverseTask(shareEnvelopeID: id) {
                continue
            }
            stuck += 1
        }
        return stuck
    }

    /// The child dirs of `parent` whose name parses as a UUID, returned as UUIDs.
    /// Non-UUID children (reserved sub-dirs, stray files) are skipped.
    private func childEnvelopeIDs(of parent: URL) -> [UUID] {
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: parent, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return [] }
        return children.compactMap { UUID(uuidString: $0.lastPathComponent) }
    }

    // MARK: - Notifications

    /// Post the USER notification for a NO-TURN share failure (no inline bubble
    /// exists, so this is the only surfacing). Carries NO conversation deep-link
    /// (`conversationIDKey == ""` → the delegate just foregrounds, no nav) — there
    /// is no thread the share landed in. The `remoteAgent.failure.` identifier
    /// prefix matches the turn-exists failure notifications (excluded from
    /// auto-speak). Localized strings inline (headless xcodebuild can't
    /// merge new xcstrings keys).
    private func postNoTurnFailureNotification(envelopeID: UUID, reason: NoTurnFailure) {
        let content = UNMutableNotificationContent()
        switch reason {
        case .needsFileServer:
            content.title = String(
                localized: "Couldn't send your file",
                defaultValue: "Couldn't send your file"
            )
            content.body = String(
                localized: "This gateway has no file server set up, so your file couldn't be sent. Add one in Settings, then share it again.",
                defaultValue: "This gateway has no file server set up, so your file couldn't be sent. Add one in Settings, then share it again."
            )
        case .couldNotSend:
            content.title = String(
                localized: "Couldn't send",
                defaultValue: "Couldn't send"
            )
            content.body = String(
                localized: "Conduck couldn't send what you shared. Try sharing it again.",
                defaultValue: "Conduck couldn't send what you shared. Try sharing it again."
            )
        }
        content.sound = .default
        // Empty conversation id → the delegate no-ops to foreground (no thread).
        content.userInfo = [NotificationDeepLink.conversationIDKey: ""]

        let request = UNNotificationRequest(
            identifier: "remoteAgent.failure.\(envelopeID.uuidString)",
            content: content,
            trigger: nil
        )
        Task { try? await UNUserNotificationCenter.current().add(request) }
    }

    /// userInfo key carrying a SUCCESS-path share envelope UUID — the appex sets
    /// this on the "Shared to Conduck" confirmation notification (the literal
    /// `"shareEnvelopeID"` it writes in `ShareViewController`). A tap routes
    /// through `drainAndResolve(envelopeID:)` → deep-link into the target chat.
    /// Single-sourced here so the main-app reader can't drift from the appex
    /// writer's literal.
    static let shareEnvelopeIDKey = "shareEnvelopeID"
}
