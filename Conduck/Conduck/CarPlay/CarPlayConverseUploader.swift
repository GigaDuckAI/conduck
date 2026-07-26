// Conduck
// CarPlayConverseUploader.swift
//
// Background URLSession + delegate for the CarPlay agent converse hop
// (`POST /v1/chat/completions`). A SECOND background session alongside the iOS
// `.converse` one (`BackgroundRemoteAgent`); routed by a distinct identifier
// (`Constants.remoteAgentCarPlayConverseSessionIdentifier`) so deliveries never
// cross-talk. Mirrors `WatchAudioUploader.uploadConverse` + its converse
// completion path structurally:
//   - build the request via shared `ConverseRequest` + `RemoteAgentClient.assembleMessages`
//   - write the body to a temp file (background uploads require a file URL)
//   - stamp `RemoteAgentBackgroundMetadata` (bodyPath + conversationID + backend)
//     onto `taskDescription` for cross-launch recovery
//   - cert-pin per-challenge via `RemoteAgentTrustEvaluator` (reading the CURRENT
//     fingerprint, not a once-built evaluator, so a cold-launch resume re-reads it)
//   - decode `ConverseResponse.firstReplyContent`, append the AGENT turn ONCE
//     (single owner — the delegate), bump the active-conversation pointer
//   - `defer`-remove the body temp file on EVERY path
//
// Why background (not foreground in a `beginBackgroundTask`): agent replies take
// 30 s–several minutes on self-hosted hardware. A background session
// survives app suspension and is NOT subject to the ~30 s `beginBackgroundTask`
// budget — so a turn started in CarPlay always completes + persists + syncs even
// when the driver navigates away to Maps mid-think. The reply is SPOKEN only
// when CarPlay is foreground on the Conduck voice template with the matching
// turn still active (Apple forbids unsolicited audio from a backgrounded app —
// the unsolicited-audio guard); otherwise it is persisted + synced silently.
//
// Privacy invariants (see the spec's "Privacy & Security" section): the bearer
// token is NEVER logged; reply bodies / gateway URLs are never logged.

#if os(iOS)
import Foundation
import UserNotifications

/// Background URLSession singleton + delegate for the CarPlay converse hop.
/// `nonisolated final class @unchecked Sendable` because URLSession delegate
/// callbacks are nonisolated by contract (mirrors `BackgroundRemoteAgent`).
nonisolated final class CarPlayConverseUploader: NSObject, @unchecked Sendable {
    static let shared = CarPlayConverseUploader()

    /// Background URLSession identifier. MUST match the value wired into
    /// `ConduckApp.backgroundTask(.urlSession(...))` or the system never
    /// routes a relaunch completion back to this delegate.
    static let sessionIdentifier = Constants.remoteAgentCarPlayConverseSessionIdentifier

    // MARK: - Active-turn handoff (drives the speak-or-sync decision)

    /// The live recording service for the connected CarPlay scene, set when a
    /// session starts and cleared on session end / scene disconnect. Weak so a
    /// scene teardown doesn't leak the service. Touched only on the main actor
    /// (set from `CarPlayRecordingService`; read inside a `MainActor.run` hop
    /// in the completion handler). Guarded by `stateLock` for the cross-thread
    /// read of the identity check below.
    private weak var activeService: CarPlayRecordingService?

    /// The conversation + turn token of the in-flight CarPlay turn whose reply
    /// this delegate should attempt to SPEAK (foreground + matching). A reply
    /// that does not match (stale turn, or the session moved on) is persisted
    /// + synced only. Set on `register`, compared on completion.
    private struct InFlightTurn {
        let taskIdentifier: Int
        let conversationID: UUID
        /// Monotonic token minted by the recording service per turn — the
        /// stale-reply guard. A reply for an old `turnToken` never speaks even
        /// if the conversation matches.
        let turnToken: UInt64
    }

    private let stateLock = NSLock()
    private var inFlight: [Int: InFlightTurn] = [:]
    /// Bounded by `Constants.maxBackgroundResponseBytes` — see `overCapTaskIDs`.
    private var responseBuffers: [Int: Data] = [:]
    private var bodyURLs: [Int: URL] = [:]

    /// Task identifiers whose server-trust challenge THIS delegate cancelled (a
    /// pinned-cert mismatch, or a cross-host hop that could not present the
    /// pinned key). Kept in lockstep with `BackgroundRemoteAgent.pinRejectedTaskIDs`
    /// — the two converse lanes must label a refused certificate identically, or
    /// the same MITM reads as "untrusted certificate" in the app and "tap to
    /// retry" in the car. Guarded by `stateLock` like every other registry here.
    private var pinRejectedTaskIDs = Set<Int>()

    /// Task identifiers whose response body exceeded
    /// `Constants.maxBackgroundResponseBytes` and were cancelled for it. Needed
    /// for the same reason as `pinRejectedTaskIDs`: a bare `task.cancel()` is
    /// indistinguishable from the driver pressing End.
    private var overCapTaskIDs = Set<Int>()

    /// Drain bookkeeping for the `.backgroundTask(.urlSession)` wake handler
    /// (mirrors `BackgroundRemoteAgent`): waiters registered by
    /// `handleBackgroundEvents()`, resumed only when the system has delivered
    /// every queued delegate callback (`urlSessionDidFinishEvents`) AND every
    /// persistence task those callbacks spawned (reply append / status flip /
    /// failure notification) has completed — the OS may suspend/kill the
    /// process the moment the closure returns. All three are queue-confined
    /// (the delegate OperationQueue underlies `queue`).
    private var drainWaiters: [() -> Void] = []
    private var didFinishBackgroundEvents = false
    private var pendingPersistenceCount = 0

    private let queue = DispatchQueue(label: Constants.identityNamespace + ".carplay.converse.bg")

    fileprivate lazy var session: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        config.sessionSendsLaunchEvents = true
        config.isDiscretionary = false
        config.allowsCellularAccess = true
        config.timeoutIntervalForRequest = Constants.remoteAgentConverseRequestTimeout
        config.timeoutIntervalForResource = Constants.remoteAgentConverseResourceTimeout

        let opQueue = OperationQueue()
        opQueue.maxConcurrentOperationCount = 1
        opQueue.underlyingQueue = queue
        return URLSession(configuration: config, delegate: self, delegateQueue: opQueue)
    }()

    private override init() {
        super.init()
    }

    // MARK: - SwiftUI backgroundTask entry

    /// Bridge system-relaunch events into this singleton. Touching `session`
    /// re-attaches our delegate, which drains pending `didCompleteWithError`
    /// callbacks (incl. the body-cleanup defer + the agent-turn append) —
    /// then AWAIT until the drain is complete (`urlSessionDidFinishEvents` +
    /// all persistence work), so the system can't suspend/kill the process
    /// while the reply append is still in flight (wake-handler race).
    func handleBackgroundEvents() async {
        _ = session
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                self.drainWaiters.append { continuation.resume() }
                // didFinishEvents may already have fired before this waiter
                // registered (same serial queue, racing arrival) — check now.
                self.resumeDrainWaitersIfReady()
            }
        }
    }

    // MARK: - Drain bookkeeping (queue-confined)

    /// Mark one persistence task started. MUST be called on `queue` (delegate
    /// callbacks already are).
    private func beginPersistenceWork() {
        pendingPersistenceCount += 1
    }

    /// Mark one persistence task finished; resume drain waiters if ready.
    /// Safe from any context.
    private func endPersistenceWork() {
        queue.async {
            self.pendingPersistenceCount -= 1
            self.resumeDrainWaitersIfReady()
        }
    }

    /// Resume the `.backgroundTask` waiters when events finished AND no
    /// persistence task is still running. MUST be called on `queue`.
    ///
    /// FLAG LIFECYCLE: `didFinishBackgroundEvents` is consumed (reset) here on
    /// the resume path — see `BackgroundRemoteAgent.resumeDrainWaitersIfReady`
    /// for the full rationale. RESIDUAL WINDOW (accepted): a didFinishEvents
    /// that fires with no waiter registered (launch-time materialization
    /// draining leftovers) leaves the flag armed, so the NEXT wake's waiter
    /// resumes early once — a one-shot regression to pre-await behavior, never
    /// a hang; the persistence counter still gates in-flight writes.
    private func resumeDrainWaitersIfReady() {
        guard didFinishBackgroundEvents, pendingPersistenceCount == 0, !drainWaiters.isEmpty else { return }
        didFinishBackgroundEvents = false
        let waiters = drainWaiters
        drainWaiters = []
        for waiter in waiters { waiter() }
    }

    /// Conversation IDs with a LIVE converse task on this background session
    /// (running OR suspended). Mirrors `BackgroundRemoteAgent.liveConversationIDs`
    /// — consumed by the launch-time stale-`sending` sweep so it never flips a
    /// turn whose task is still in flight.
    func liveConversationIDs() async -> Set<UUID> {
        let tasks = await session.allTasks
        return Set(tasks.compactMap { task in
            task.taskDescription
                .flatMap { try? RemoteAgentBackgroundMetadata.decode($0) }
                .flatMap { UUID(uuidString: $0.conversationID) }
        })
    }

    // MARK: - Active service registration (main-actor only)

    /// The recording service registers itself as the speak target for the
    /// life of a session. Cleared on session end / scene disconnect so a
    /// reply that lands after the session ended takes the silent persist-only
    /// path (the unsolicited-audio guard).
    @MainActor
    func setActiveService(_ service: CarPlayRecordingService?) {
        stateLock.lock()
        activeService = service
        stateLock.unlock()
    }

    // MARK: - Upload

    /// Issue the CarPlay converse turn over the background session. The user
    /// turn is expected to ALREADY be appended to the store by the caller (so
    /// the store is authoritative even if the reply never lands). Builds the
    /// request body, writes it to a tmp file, stamps recovery metadata, and
    /// starts the upload.
    ///
    /// Client-owned history: a STATELESS request carrying the FULL trimmed
    /// `messages[]`. No session header, no `conversation` field, no 423/lock.
    ///
    /// - Throws: `AppError.remoteAgentInvalidResponse` if metadata/body encoding
    ///   fails (the caller maps it to an error TTS + session end).
    func uploadConverse(
        backend: RemoteAgentBackend,
        // The TRUE gateway identity (built-in OR custom). `backend` is the
        // `.openclaw` status-map carrier for customs, so it can't key the pin;
        // `ref` rides the recovery metadata so the trust delegate resolves the
        // correct per-ref pin. REQUIRED (no default) — compiler-forces the
        // caller to pass it.
        ref: RemoteAgentRef,
        url: URL,
        token: String,
        authScheme: RemoteAgentAuthScheme = .bearer,
        model: String?,
        priorTurns: [ConverseRequest.Message],
        newUserText: String,
        conversationID: UUID,
        // The user `Message.id` of THIS turn, when the caller threads it
        // (`CarPlayRecordingService.startConverseHop` append site). Rides the
        // recovery metadata so the delegate flips the EXACT turn's status —
        // the conversation-wide flip aliases a concurrent in-app sibling turn.
        // Optional + defaulted → source-compatible; nil falls back wide.
        userMessageID: UUID? = nil,
        // Stable one-way identity of THIS turn's exact READY file lane,
        // captured by the caller. Non-nil both enables the per-turn delivery
        // instruction and rides recovery metadata so a later capable device
        // probes only that physical lane; nil never guesses a replacement.
        fileTransferLaneID: String?,
        turnToken: UInt64
    ) throws {
        let endpoint = url.appending(path: "v1/chat/completions")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = Constants.remoteAgentConverseRequestTimeout
        // `.bearer` sets the header; `.none` (keyless) omits it.
        authScheme.apply(to: &request, token: token)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // `model` is threaded for customs (built-ins pass nil → the `"model"`
        // key is OMITTED from JSON, byte-identical to today's wire). CarPlay is
        // a SPOKEN surface (`surface: .spoken`) — the reply is heard aloud in
        // the car — so the newest turn carries the spoken-summary clause; when
        // the bound gateway also has a ready file lane, the delivery
        // instruction rides first (delivery → spoken).
        let body = ConverseRequest(
            messages: RemoteAgentClient.assembleMessages(
                priorTurns: priorTurns,
                newUserText: newUserText,
                fileServerReady: fileTransferLaneID != nil,
                surface: .spoken
            ),
            stream: false,
            model: model
        )
        let bodyData = try JSONEncoder().encode(body)

        let bodyURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("conduck-carplay-converse-body-\(UUID().uuidString).json")
        try bodyData.write(to: bodyURL, options: [.atomic])

        let metadata = RemoteAgentBackgroundMetadata(
            bodyPath: bodyURL.path,
            conversationID: conversationID.uuidString,
            backendRawValue: backend.rawValue,
            refRawValue: ref.rawString,
            userMessageID: userMessageID,
            // Dispatch-time fact for the failure classification (the
            // delegate classifies long after `priorTurns` is gone).
            requestHadHistoryImages: ConverseRequest.containsImageParts(priorTurns),
            fileTransferLaneID: fileTransferLaneID
        )
        let metadataString: String
        do {
            metadataString = try metadata.encodedString()
        } catch {
            try? FileManager.default.removeItem(at: bodyURL)
            throw AppError.remoteAgentInvalidResponse
        }

        let task = session.uploadTask(with: request, fromFile: bodyURL)
        task.taskDescription = metadataString

        let entry = InFlightTurn(
            taskIdentifier: task.taskIdentifier,
            conversationID: conversationID,
            turnToken: turnToken
        )
        stateLock.lock()
        inFlight[task.taskIdentifier] = entry
        responseBuffers[task.taskIdentifier] = Data()
        bodyURLs[task.taskIdentifier] = bodyURL
        stateLock.unlock()

        task.resume()

        #if DEBUG
        print("[CarPlay] Background converse upload started (task \(task.taskIdentifier))")
        #endif
    }

    // MARK: - Cancellation

    /// Cancel the in-flight CarPlay converse turn for `turnToken`, if any. The
    /// delegate sees `.cancelled` and drops the turn (no agent append, no TTS).
    /// Used by the recording service's End/Cancel terminal paths.
    func cancel(turnToken: UInt64) {
        stateLock.lock()
        let identifiers = inFlight.values
            .filter { $0.turnToken == turnToken }
            .map(\.taskIdentifier)
        stateLock.unlock()
        guard !identifiers.isEmpty else { return }
        session.getAllTasks { tasks in
            for task in tasks where identifiers.contains(task.taskIdentifier) {
                task.cancel()
            }
        }
    }
}

// MARK: - URLSession delegate

extension CarPlayConverseUploader: URLSessionDataDelegate {
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let id = dataTask.taskIdentifier
        stateLock.lock()
        // BOUNDED accumulate (mirrors `BackgroundRemoteAgent`): the body is
        // gateway-controlled and was appended with no ceiling, so a fabricated
        // answer grew until the OS jetsammed the app. Straggler chunks after the
        // cancel are dropped; the verdict is recorded BEFORE `cancel()` so
        // `didCompleteWithError` can tell it from the driver pressing End.
        if overCapTaskIDs.contains(id) {
            stateLock.unlock()
            return
        }
        let buffered = responseBuffers[id]?.count ?? 0
        guard buffered + data.count <= Constants.maxBackgroundResponseBytes else {
            overCapTaskIDs.insert(id)
            responseBuffers[id] = Data()
            stateLock.unlock()
            dataTask.cancel()
            return
        }
        // Subscript-with-default `_modify` keeps the append in place; copying the
        // value out and back would make accumulation quadratic.
        responseBuffers[id, default: Data()].append(data)
        stateLock.unlock()
    }

    /// TASK-level server-trust challenge handler — per-ref pinning for the
    /// CarPlay converse hop (self-signed support). Recovers the turn's
    /// `refRawValue` from `taskDescription` and resolves that ref's pinned SPKI
    /// fingerprint LIVE from the App Group, so a pin set / rotated after launch
    /// is always honoured and a cross-launch resume re-reads the durable pin.
    /// nil → default ATS. The pin is applied HOST-BLIND so a cross-host redirect
    /// must present the pinned key (rationale + honest limits on
    /// `converseTaskPin(for:metadata:)`). Mirrors
    /// `BackgroundRemoteAgent` + `STTClient+Background`. A session-level
    /// handler would take precedence, so only this task-level one exists.
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let metadata = task.taskDescription.flatMap { try? RemoteAgentBackgroundMetadata.decode($0) }
        guard let pin = RemoteAgentTrustEvaluator.converseTaskPin(for: challenge, metadata: metadata) else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        let evaluator = RemoteAgentTrustEvaluator(pinnedFingerprintHex: pin)
        let taskID = task.taskIdentifier
        evaluator.urlSession(session, didReceive: challenge) { disposition, credential in
            // A cancel from the evaluator is a PIN REJECTION by construction (it
            // only cancels a server-trust challenge on a mismatch, and it is only
            // reached when a pin was recovered). Noted BEFORE the handler is
            // forwarded, because URLSession then reports plain `.cancelled` —
            // indistinguishable from the driver pressing End.
            if disposition == .cancelAuthenticationChallenge {
                self.stateLock.lock()
                self.pinRejectedTaskIDs.insert(taskID)
                self.stateLock.unlock()
            }
            completionHandler(disposition, credential)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let id = task.taskIdentifier

        // Recover the metadata envelope (body path + conversationID + backend)
        // from `taskDescription` — survives a cross-launch process recycle.
        let metadata: RemoteAgentBackgroundMetadata? = task.taskDescription.flatMap {
            try? RemoteAgentBackgroundMetadata.decode($0)
        }

        // Cleanup mandate (load-bearing): delete the request-body temp
        // file on EVERY exit path — success / failure / cancel. Pull both the
        // tracked-registry URL and the metadata path so cleanup works even when
        // the in-memory entry was lost to a relaunch.
        defer {
            stateLock.lock()
            responseBuffers.removeValue(forKey: id)
            let bodyURL = bodyURLs.removeValue(forKey: id)
            inFlight.removeValue(forKey: id)
            pinRejectedTaskIDs.remove(id)
            overCapTaskIDs.remove(id)
            stateLock.unlock()
            if let bodyURL {
                try? FileManager.default.removeItem(at: bodyURL)
            }
            if let bodyPath = metadata?.bodyPath {
                try? FileManager.default.removeItem(atPath: bodyPath)
            }
        }

        stateLock.lock()
        let entry = inFlight[id]
        let buffered = responseBuffers[id] ?? Data()
        // Read (the `defer` above clears) both per-task delegate notes. Each
        // records a reason THIS delegate cancelled the task, and both surface as
        // `.cancelled`, so they must be consulted before the End-vs-failure
        // disambiguation below.
        let pinRejected = pinRejectedTaskIDs.contains(id)
        let responseOverCap = overCapTaskIDs.contains(id)
        stateLock.unlock()

        // Resolve the status-map carrier backend from the stamped ref string. A
        // built-in ref maps to itself; a custom ref (or garbage) uses `.openclaw`
        // as the carrier — the status map is `.unified` for every ref, so the
        // carrier only matters for `statusMap.map(...)`, identical across all.
        let backend: RemoteAgentBackend = {
            if case .builtin(let b)? = metadata.flatMap({ RemoteAgentRef(rawString: $0.backendRawValue) }) {
                return b
            }
            return .openclaw
        }()
        let conversationID: UUID? = metadata.flatMap { UUID(uuidString: $0.conversationID) }
        // Exact user `Message.id` for per-message status flips; nil (old blobs
        // / caller not yet threading it) falls back to the conversation-wide
        // flip — which can alias a concurrent in-app sibling turn, hence the
        // exact path is preferred whenever available.
        let userMessageID: UUID? = metadata?.userMessageID
        // Exact dispatch-time file lane. Old in-flight metadata decodes nil and
        // intentionally gets no output-recovery work.
        let fileTransferLaneID = metadata?.fileTransferLaneID
        let turnToken = entry?.turnToken

        // --- Transport error path ---
        if let error {
            // OUR over-cap cancel — a body past
            // `Constants.maxBackgroundResponseBytes`, i.e. a peer fabricating a
            // response. Routed as an ordinary invalid-response failure (spoken by
            // `handleBackgroundError` when the scene is live, durable `failed`
            // turn with a Retry chip either way) rather than aborting silently.
            if error is URLError, responseOverCap {
                routeError(.remoteAgentInvalidResponse, conversationID: conversationID, userMessageID: userMessageID, turnToken: turnToken)
                return
            }
            // OUR pin rejection. Classification delegated to the ONE shared
            // classifier the foreground hop and `BackgroundRemoteAgent` use, so
            // the lanes cannot drift. With `pinRejected == false` the classifier
            // returns `.cancelled` and everything below is unchanged.
            if let urlError = error as? URLError,
               pinRejected,
               RemoteAgentTrustEvaluator.classifyTransportError(
                   urlError.code,
                   hasPin: true,
                   systemTrustRejected: false,
                   pinRejected: true
               ) == .certMismatch {
                routeError(.remoteAgentCertMismatch, conversationID: conversationID, userMessageID: userMessageID, turnToken: turnToken)
                return
            }
            if let urlError = error as? URLError, urlError.code == .cancelled {
                if entry == nil {
                    // Post-kill resurrect: after a force-quit, background tasks
                    // come back as `.cancelled` with no in-memory entry (the
                    // registry died with the old process). Nobody cancelled
                    // this turn — treating it as a cancel left the user turn
                    // stuck at "sending" forever. Flip it to `failed` (Retry
                    // chip in the iOS thread) + post the failure notification
                    // (`error: nil` → the generic "wasn't delivered" copy).
                    if let cid = conversationID {
                        beginPersistenceWork()
                        Task {
                            if let mid = userMessageID {
                                await ConversationStore.shared.markPendingUserTurn(messageID: mid, to: "failed")
                            } else {
                                await ConversationStore.shared.markPendingUserTurns(conversationID: cid, to: "failed")
                            }
                            await Self.postFailureNotification(conversationID: cid, error: nil)
                            self.endPersistenceWork()
                        }
                    }
                    return
                }
                // LIVE in-process cancel (End/Cancel mid-think — a common
                // driver action) or session teardown. The turn stays in the
                // store, but leaving it at `sending` stranded an eternal
                // spinner in the iPhone thread (mirrors the iOS in-app cancel,
                // which also flips now): mark it `failed` — the honest
                // terminal; the Retry chip lets the user re-send. NO failure
                // notification (user-initiated, not a failure event).
                if let cid = conversationID {
                    beginPersistenceWork()
                    Task {
                        if let mid = userMessageID {
                            await ConversationStore.shared.markPendingUserTurn(messageID: mid, to: "failed")
                        } else {
                            await ConversationStore.shared.markPendingUserTurns(conversationID: cid, to: "failed")
                        }
                        self.endPersistenceWork()
                    }
                }
                return
            }
            #if DEBUG
            print("[CarPlay] Converse upload failed: \(error.localizedDescription)")
            #endif
            routeError(.remoteAgentUnreachable, conversationID: conversationID, userMessageID: userMessageID, turnToken: turnToken)
            return
        }

        // --- HTTP status mapping ---
        guard let http = task.response as? HTTPURLResponse else {
            routeError(.remoteAgentInvalidResponse, conversationID: conversationID, userMessageID: userMessageID, turnToken: turnToken)
            return
        }
        // Body-aware mapping FIRST (parity with `RemoteAgentClient.decodeReply`
        // and the `BackgroundRemoteAgent` delegate — this uploader was the one
        // transport that skipped it, so a coded `image_unsupported` in the car
        // degraded to a generic 400): a structured adapter wire code or a
        // body-named 400/404/413 classifies exactly; the status map never sees
        // the body.
        if let classified = RemoteAgentClient.classifyBodyError(status: http.statusCode, body: buffered) {
            #if DEBUG
            print("[CarPlay] Converse body-classified: HTTP \(http.statusCode)")
            #endif
            routeError(
                classified.appError,
                conversationID: conversationID,
                userMessageID: userMessageID,
                turnToken: turnToken,
                wireCode: classified.wireCode,
                hadHistoryImages: metadata?.requestHadHistoryImages
            )
            return
        }
        if let mapped = backend.statusMap.map(http.statusCode) {
            #if DEBUG
            print("[CarPlay] Converse non-2xx: HTTP \(http.statusCode)")
            #endif
            routeError(mapped, conversationID: conversationID, userMessageID: userMessageID, turnToken: turnToken)
            return
        }

        // --- 2xx — decode reply ---
        let reply: String
        do {
            let decoded = try JSONDecoder().decode(ConverseResponse.self, from: buffered)
            guard let content = decoded.firstReplyContent else {
                throw AppError.remoteAgentInvalidResponse
            }
            reply = content
        } catch {
            routeError(.remoteAgentInvalidResponse, conversationID: conversationID, userMessageID: userMessageID, turnToken: turnToken)
            return
        }

        // Need a real conversation to land the reply in. A nil conversationID
        // means the metadata decode failed (pathological); there is no coherent
        // thread to append to, so route a soft error.
        guard let cid = conversationID else {
            routeError(.remoteAgentUnreachable, conversationID: nil, userMessageID: nil, turnToken: turnToken)
            return
        }

        // Persist the agent reply ONCE (single owner = this delegate), then
        // route to speak-or-sync. Runs even for headless relaunches. CarPlay
        // never touches the shared quick-capture pointer (implicit-only; the
        // session's continuation rides the service's in-memory
        // `sessionConversationID`, and the next turn reads that live var).
        // Counted as persistence work so `handleBackgroundEvents()` holds the
        // `.backgroundTask` closure open until the append lands (returning
        // earlier raced a suspend/kill against the reply write).
        beginPersistenceWork()
        Task {
            do {
                if let userMessageID {
                    _ = try await ConversationStore.shared.completeAgentTurn(
                        userMessageID: userMessageID,
                        userStatus: "sent",
                        agentText: reply,
                        conversationID: cid,
                        sourceDevice: "carplay",
                        outputScanLaneID: fileTransferLaneID
                    )
                } else {
                    // Backward-compatible landing for a pre-upgrade in-flight
                    // task. Its owner lane cannot be proven, so append without
                    // an output marker and use the legacy broad status flip.
                    _ = try await ConversationStore.shared.appendMessage(
                        role: "agent",
                        text: reply,
                        conversationID: cid,
                        sourceDevice: "carplay"
                    )
                    await ConversationStore.shared.markPendingUserTurns(
                        conversationID: cid,
                        to: "sent"
                    )
                }
            } catch {
                // Append failed (e.g. conversation deleted on another device
                // mid-flight). Don't claim success / don't speak.
                #if DEBUG
                print("[CarPlay] Converse reply append failed — dropping")
                #endif
                self.endPersistenceWork()
                return
            }
            // Route on scene state: foreground + voice root + matching active
            // in-flight turn → speak; else persist+sync only (NO TTS — the
            // unsolicited-audio guard). The recording service owns that check.
            await MainActor.run {
                self.stateLock.lock()
                let service = self.activeService
                self.stateLock.unlock()
                service?.handleBackgroundReply(
                    reply,
                    conversationID: cid,
                    turnToken: turnToken
                )
            }
            self.endPersistenceWork()
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        // Runs on the delegate queue (`queue`). Resume the `.backgroundTask`
        // waiters once persistence work (if any) also completes — see
        // `handleBackgroundEvents`.
        didFinishBackgroundEvents = true
        resumeDrainWaitersIfReady()
    }

    // MARK: - Error routing

    /// Route a converse error: flip the user turn to `failed` (Retry chip in
    /// the iOS thread), then hand the error to the live recording service so
    /// it can speak an error TTS + end the session — ONLY when foreground +
    /// matching (the service applies that guard). When NO live service exists
    /// (scene backgrounded / disconnected) the failure is NOT surfaced via a
    /// local notification (plan D5 #4 — the after-disconnect failure
    /// notification was cut as noise): the durable `failed` turn persists in
    /// the thread (Retry chip on next open), and connected-state failures are
    /// already spoken via TTS through `handleBackgroundError`. Called on the
    /// delegate queue (`queue`) — required for the persistence counter.
    private func routeError(
        _ error: AppError,
        conversationID: UUID?,
        userMessageID: UUID?,
        turnToken: UInt64?,
        wireCode: AdapterWireCode? = nil,
        hadHistoryImages: Bool? = nil
    ) {
        // Live-service PRESENCE only (a Bool) crosses executors here; the
        // service reference itself is read inside the MainActor hop below
        // (matches the pre-existing capture style).
        stateLock.lock()
        let hasLiveService = activeService != nil
        stateLock.unlock()

        if let cid = conversationID {
            beginPersistenceWork()
            Task {
                // Exact-message flip when the id was threaded (a wide flip
                // aliases a concurrent in-app sibling); fallback otherwise.
                // LOAD-BEARING: the failed turn is recorded to the store on
                // EVERY path (incl. `!hasLiveService`) so it survives for a
                // later Retry — only the notification side effect was removed.
                // The classification rides the same guarded flip, so a
                // gateway decline in the car explains itself when the user
                // later opens the thread on the phone.
                let classification = ConversationStore.TurnFailureClassification(
                    failureCode: error.errorCode,
                    wireCode: wireCode?.rawValue,
                    hadHistoryImages: hadHistoryImages
                )
                if let mid = userMessageID {
                    await ConversationStore.shared.failTurn(messageID: mid, classification: classification)
                } else {
                    await ConversationStore.shared.failPendingUserTurns(conversationID: cid, classification: classification)
                }
                self.endPersistenceWork()
            }
        }

        guard hasLiveService else { return }
        Task { @MainActor in
            self.stateLock.lock()
            let service = self.activeService
            self.stateLock.unlock()
            service?.handleBackgroundError(error, turnToken: turnToken)
        }
    }

    // MARK: - Failure notification (post-kill resurrect path)

    /// Failure notification for the POST-KILL RESURRECT case only — a turn that
    /// came back as `.cancelled` with no in-memory entry after a force-quit
    /// (`didCompleteWithError`, `entry == nil`), where nobody cancelled it and
    /// there is no live service or TTS to surface the failure. (The ordinary
    /// after-disconnect failure path in `routeError` no longer notifies — plan
    /// D5 #4 cut.) Mirrors `BackgroundRemoteAgent.postFailureNotification`. Tap
    /// deep-links to the conversation to retry. PRIVACY: interpolating error cases
    /// (`.networkError`/`.decodingError`/`.unknown` can embed the gateway
    /// hostname) map to the fixed `remoteAgentUnreachable` copy — defensive;
    /// this path currently only receives fixed-copy cases.
    private static func postFailureNotification(conversationID: UUID, error: AppError?) async {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Couldn't reach your personal AI")  // xcstrings
        let fallback = String(localized: "Your message wasn't delivered. Open Conduck to retry.")  // xcstrings
        switch error {
        case .some(.networkError), .some(.decodingError), .some(.unknown):
            content.body = AppError.remoteAgentUnreachable.errorDescription ?? fallback
        case .some(let appError):
            content.body = appError.errorDescription ?? fallback
        case nil:
            content.body = fallback
        }
        content.sound = .default
        content.userInfo = [NotificationDeepLink.conversationIDKey: conversationID.uuidString]

        let request = UNNotificationRequest(
            identifier: "remoteAgent.failure.\(conversationID.uuidString)",
            content: content,
            trigger: nil
        )
        try? await UNUserNotificationCenter.current().add(request)
    }
}
#endif
