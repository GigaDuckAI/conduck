// Conduck
// BackgroundRemoteAgent.swift
//
// Background URLSession path for the agent converse hop
// (`POST /v1/chat/completions`). Mirrors `BackgroundSTT`
// (Services/STTClient+Background.swift) structurally:
//   - `nonisolated final class … @unchecked Sendable` with `static let shared`
//   - lazy background `URLSession` re-materialized by `handleBackgroundEvents()`
//   - `uploadTask(with:fromFile:)` with the request body written to a temp file
//   - delegate `didCompleteWithError` `defer`-deletes the body file on
//     success OR failure
//   - recovery metadata in `task.taskDescription`
//     (`RemoteAgentBackgroundMetadata`) so a cross-launch resume can recover
//     the body path (cleanup) + conversation ID (where the reply lands)
//
// Why background (not foreground) for BOTH entry points: agent replies take
// 30 s – several minutes on self-hosted hardware. A foreground
// session is suspended the moment the user leaves the app (entry-1 headless
// Shortcut never foregrounds at all). The background session's
// `sessionSendsLaunchEvents` + 300 s/600 s timeouts cover the long compute
// window; when the app is frontmost on completion the delegate fires
// immediately with no relaunch. The in-app thread (entry 2, ContentView)
// uses the same path and observes in-flight + completion via the in-memory
// turn registry + the `.remoteAgentTurnDidComplete` / `.remoteAgentTurnDidFail`
// bus — one code path, no foreground/background branch.
//
// Trust pinning: the TASK-level `urlSession(_:task:didReceive:)` delegate
// recovers the turn's gateway identity (`refRawValue`) from the task's
// `taskDescription` metadata, then resolves that ref's pinned SHA-256
// fingerprint LIVE from the App-Group UserDefaults (the per-ref key
// SettingsManager writes), host-scopes it against the ref's configured URL,
// and delegates the actual compare to `RemoteAgentTrustEvaluator`. Mirrors
// the STT background sibling (`STTClient+Background.swift`). Per-challenge
// live resolution is relaunch-safe (a cross-launch-resumed task re-reads the
// durable pin), task-scoped (no host-collision across refs), custom-correct
// (keyed off the true ref, never the `.openclaw` status-map carrier), and
// honors a post-enqueue cert re-pin. The shared background session can carry
// concurrent in-flight turns to different gateways; each challenge pins its
// own ref's cert. Reading UserDefaults directly keeps the nonisolated
// delegate synchronous (no MainActor hop into SettingsManager).
//
// Privacy invariants (see the spec's Privacy & Security section): the bearer token is NEVER
// logged; reply bodies are never logged.

import Foundation
import UserNotifications
#if DEBUG
import os.log
#endif
#if canImport(UIKit)
import UIKit
#endif

/// Background URLSession singleton + delegate for the agent converse hop.
/// Lives outside the `RemoteAgentClient` actor because URLSession delegate
/// methods are nonisolated by contract. Explicitly `nonisolated` so the
/// Swift 6 default MainActor isolation in this module doesn't infect the
/// delegate callbacks (matches `BackgroundSTT`).
nonisolated final class BackgroundRemoteAgent: NSObject, @unchecked Sendable {
    static let shared = BackgroundRemoteAgent()

    /// Background URLSession identifier. Mirrors the value wired into
    /// `ConduckApp.backgroundTask(.urlSession(...))` — change in lockstep
    /// or the system-relaunch event won't route back here.
    static let sessionIdentifier = Constants.remoteAgentConverseSessionIdentifier

    // MARK: - In-flight registry (drives the in-app Cancel + thinking UX)

    /// In-flight turn descriptor. Tracks the underlying `URLSessionTask` so
    /// `cancel(conversationID:)` can cancel it, plus an optional continuation
    /// for in-app callers that await the reply directly.
    private struct InFlightTurn {
        let taskIdentifier: Int
        let conversationID: UUID
        var continuation: CheckedContinuation<String, Error>?
    }

    /// Outstanding turns keyed by `URLSessionTask.taskIdentifier`. Resolved
    /// exactly once by `urlSession(_:task:didCompleteWithError:)`.
    private var inFlight: [Int: InFlightTurn] = [:]

    /// Response data accumulator per task (delegate may split the payload
    /// across multiple `didReceive data:` callbacks).
    private var responseBuffers: [Int: Data] = [:]

    /// Body file URLs keyed by task identifier — cleaned up in
    /// `didCompleteWithError`. (Belt-and-suspenders alongside the
    /// `taskDescription` path so cleanup works even when the in-memory entry
    /// survives, i.e. no process kill.)
    private var bodyURLs: [Int: URL] = [:]

#if DEBUG
    /// DEBUG-only converse-latency observability: send timestamp keyed by task
    /// id, diffed at completion (`RemoteAgentDiagnostics`). Metadata only.
    private var diagSentAt: [Int: Date] = [:]
#endif

    /// Continuation-resumers registered by `handleBackgroundEvents()` (the
    /// SwiftUI `.backgroundTask(.urlSession)` closure). Resumed only when the
    /// system has delivered every queued delegate callback
    /// (`urlSessionDidFinishEvents`) AND every persistence task those
    /// callbacks spawned (reply append / status flip / notification) has
    /// completed — the OS may suspend or kill the process the moment the
    /// `.backgroundTask` closure returns, so returning at didFinishEvents
    /// alone would race the reply write. Array (not a single slot) so two
    /// overlapping wakes can't orphan a continuation. Queue-confined.
    private var drainWaiters: [() -> Void] = []

    /// Set by `urlSessionDidFinishEvents`; consumed (reset) when the drain
    /// waiters resume. Queue-confined.
    private var didFinishBackgroundEvents = false

    /// Count of in-flight persistence tasks spawned by delegate callbacks
    /// (`recordReply` / the failure status-flip). Gates the drain waiters.
    /// Queue-confined.
    private var pendingPersistenceCount = 0

    private let queue = DispatchQueue(label: Constants.identityNamespace + ".converse.bg")

    fileprivate lazy var session: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        config.sessionSendsLaunchEvents = true
        config.isDiscretionary = false
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

    /// SwiftUI `.backgroundTask(.urlSession(...))` entry — call from the
    /// App's modifier closure. Materializes the lazy session (which
    /// re-attaches the system to our delegate, draining pending callbacks)
    /// and then AWAITS until the drain is complete: `urlSessionDidFinishEvents`
    /// has fired AND the reply-persistence work the callbacks spawned has
    /// finished. Returning earlier would let the system suspend/kill the
    /// process mid-append and silently lose the reply (wake-handler race).
    func handleBackgroundEvents() async {
        // Touching `session` re-creates the URLSession with our delegate,
        // which is what causes pending delegate callbacks to drain.
        _ = session
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                self.drainWaiters.append { continuation.resume() }
                // didFinishEvents may already have fired (the system replays
                // callbacks as soon as the session re-materializes, racing this
                // registration on the same serial queue) — check immediately.
                self.resumeDrainWaitersIfReady()
            }
        }
    }

    // MARK: - Drain bookkeeping (queue-confined)

    /// Mark one persistence task as started. MUST be called on `queue`
    /// (delegate callbacks already are — the session's delegate OperationQueue
    /// underlies it).
    private func beginPersistenceWork() {
        pendingPersistenceCount += 1
    }

    /// Mark one persistence task as finished and resume drain waiters if the
    /// session has also finished delivering events. Safe from any context.
    private func endPersistenceWork() {
        queue.async {
            self.pendingPersistenceCount -= 1
            self.resumeDrainWaitersIfReady()
        }
    }

    /// Resume the `.backgroundTask` waiters when (a) the system reported all
    /// queued callbacks delivered and (b) no persistence task is still
    /// running. MUST be called on `queue`.
    ///
    /// FLAG LIFECYCLE: `didFinishBackgroundEvents` is consumed (reset) HERE,
    /// when waiters actually resume — not where it is set. That is deliberate:
    /// the system can finish replaying callbacks BEFORE the `.backgroundTask`
    /// closure registers its waiter (same wake, racing arrival on this serial
    /// queue), and a set-then-immediately-cleared flag would wedge that waiter
    /// forever. RESIDUAL WINDOW (accepted): if didFinishEvents ever fires in a
    /// process where NO waiter registers (e.g. a launch-time session
    /// materialization draining leftover events with no system wake), the flag
    /// stays armed and the NEXT wake's waiter resumes before its own events
    /// drain — a one-shot regression to the pre-await behavior (early return),
    /// never a hang; the persistence counter still gates any in-flight writes.
    private func resumeDrainWaitersIfReady() {
        guard didFinishBackgroundEvents, pendingPersistenceCount == 0, !drainWaiters.isEmpty else { return }
        didFinishBackgroundEvents = false
        let waiters = drainWaiters
        drainWaiters = []
        for waiter in waiters { waiter() }
    }

    // MARK: - Public API

    /// Issue a converse turn over the background session. The user turn is
    /// expected to already be appended to the store by the caller; this
    /// uploads the request and (on the delegate completion) appends the
    /// AGENT reply + fires the completion notification.
    ///
    /// Returns the agent reply text. The continuation resolves from the
    /// delegate — so an in-app caller `await`s the reply for its in-flight
    /// UX, while a headless caller can fire-and-forget (the delegate still
    /// appends + notifies even if the awaiting task is gone after a relaunch).
    ///
    /// - Throws: `AppError` from the `.remoteAgent*` family on failure, or
    ///   `CancellationError` if the turn was cancelled via
    ///   `cancel(conversationID:)`.
    @discardableResult
    func send(
        backend: RemoteAgentBackend,
        // The TRUE gateway identity (built-in OR custom). Distinct from
        // `backend`, which is the `.openclaw` status-map carrier for customs.
        // Threaded into the recovery metadata so the cert-pin trust delegate
        // resolves the correct per-ref pin after a cross-launch resume.
        // REQUIRED (no default) so every call site is compiler-forced to pass
        // it — a silent default is what let the cert-pin bug ship.
        ref: RemoteAgentRef,
        url: URL,
        token: String,
        authScheme: RemoteAgentAuthScheme = .bearer,
        model: String? = nil,
        priorTurns: [ConverseRequest.Message],
        newUserText: String,
        newUserImageDataURIs: [String] = [],
        newUserTextFileBlocks: [(filename: String, text: String)] = [],
        newUserServerFileRefs: [(originalName: String, storedKey: String)] = [],
        newUserImageFileRefs: [(storedKey: String, filename: String)] = [],
        newUserTextFileServerRefs: [(originalName: String, storedKey: String)] = [],
        conversationID: UUID,
        shareEnvelopeID: UUID? = nil,
        // The user `Message.id` of THIS turn, when the caller knows it (in-app
        // VM, headless intent, share drain). Threaded into the recovery
        // metadata so the delegate flips the EXACT turn's status instead of
        // the conversation-wide `markPendingUserTurns` (which aliases sibling
        // in-flight turns). Optional + defaulted → source-compatible.
        userMessageID: UUID? = nil,
        // True ONLY for headless quick captures (ConverseIntent, Watch
        // headless trigger): the delegate's success path then stamps the
        // per-device quick-capture pointer (`recordActiveConversation`).
        // Explicit surfaces (in-app VM, share drain, CarPlay) keep the
        // default `false` — they must never retarget the quick lane.
        // Threaded via the recovery metadata so a cross-launch resume keeps
        // the same provenance.
        stampsActiveConversation: Bool = false,
        // Headless callers (the Action-Button intent) pass `false` to
        // FIRE-AND-FORGET: enqueue the upload and return immediately instead of
        // awaiting the reply. The background delegate still records the reply +
        // fires the completion notification (success) or the failure
        // notification (failure), so delivery is unaffected — only the caller
        // stops blocking. In-app callers keep the default `true` (await for the
        // in-flight thinking UX).
        awaitReply: Bool = true
    ) async throws -> String {
        // Build the request + body file on disk (background uploads require a
        // file URL, not in-memory Data). The Authorization header is baked into
        // the enqueued task here (the recovery metadata only re-locates the reply
        // target, never rebuilds the request) — so the auth scheme is applied at
        // enqueue: `.bearer` sets the header, `.none` (keyless) omits it.
        let endpoint = url.appending(path: "v1/chat/completions")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = Constants.remoteAgentConverseRequestTimeout
        authScheme.apply(to: &request, token: token)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // Derived HERE from the ref (not threaded from callers): every
        // background dispatch surface — in-app VM, retry, share drain, headless
        // intents, Watch relay — funnels through this method, so deriving once
        // at the choke point means no caller can forget to pass it. Ready-gated
        // (`fileTransferReadySnapshot`, not the raw snapshot) to match the
        // routing/promotion call sites: an untested lane must not trigger the
        // instruction.
        let fileServerReady = await SettingsManager.shared.fileTransferReadySnapshot(for: ref) != nil

        let body = ConverseRequest(
            messages: RemoteAgentClient.assembleMessages(
                priorTurns: priorTurns,
                newUserText: newUserText,
                newUserImageDataURIs: newUserImageDataURIs,
                newUserTextFileBlocks: newUserTextFileBlocks,
                newUserServerFileRefs: newUserServerFileRefs,
                newUserImageFileRefs: newUserImageFileRefs,
                newUserTextFileServerRefs: newUserTextFileServerRefs,
                fileServerReady: fileServerReady
            ),
            stream: false,
            model: model
        )
        let bodyData = try JSONEncoder().encode(body)

        let bodyURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("conduck-converse-body-\(UUID().uuidString).json")
        try bodyData.write(to: bodyURL, options: [.atomic])

        let metadata = RemoteAgentBackgroundMetadata(
            bodyPath: bodyURL.path,
            conversationID: conversationID.uuidString,
            backendRawValue: backend.rawValue,
            refRawValue: ref.rawString,
            shareEnvelopeID: shareEnvelopeID,
            userMessageID: userMessageID,
            stampsActiveConversation: stampsActiveConversation,
            // Dispatch-time fact for the failure classification (the
            // delegate may classify after a relaunch, long after `priorTurns`
            // is gone): does this request carry historical image parts?
            requestHadHistoryImages: ConverseRequest.containsImageParts(priorTurns)
        )
        let metadataString: String
        do {
            metadataString = try metadata.encodedString()
        } catch {
            try? FileManager.default.removeItem(at: bodyURL)
            throw AppError.remoteAgentInvalidResponse
        }

#if DEBUG
        RemoteAgentDiagnostics.log.log("send(bg): convo=\(conversationID.uuidString, privacy: .public) \(RemoteAgentDiagnostics.shapeSummary(body.messages, bodyBytes: bodyData.count), privacy: .public)")
#endif

        // Fire-and-forget (headless): enqueue + return immediately, registering
        // NO continuation. The background URLSession is owned by the system, so
        // the upload completes — and the delegate delivers the reply +
        // notification — regardless of this process exiting right after. Returns
        // an empty string; headless callers ignore the value (the reply arrives
        // as a notification).
        if !awaitReply {
            let task = session.uploadTask(with: request, fromFile: bodyURL)
            task.taskDescription = metadataString
            register(
                continuation: nil,
                taskIdentifier: task.taskIdentifier,
                conversationID: conversationID,
                bodyFileURL: bodyURL
            )
            task.resume()
            return ""
        }

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            let task = session.uploadTask(with: request, fromFile: bodyURL)
            task.taskDescription = metadataString
            register(
                continuation: continuation,
                taskIdentifier: task.taskIdentifier,
                conversationID: conversationID,
                bodyFileURL: bodyURL
            )
            task.resume()
        }
    }

    // MARK: - Cancellation

    /// Cancel the in-flight turn for `conversationID`, if any. Cancels the
    /// underlying `URLSessionTask` so no stale reply lands later (the delegate
    /// sees `.cancelled`, drops the turn, and does NOT append an agent bubble).
    func cancel(conversationID: UUID) {
        queue.async {
            guard let entry = self.inFlight.values.first(where: { $0.conversationID == conversationID }) else {
                return
            }
            // Find the live task by identifier and cancel it. The delegate's
            // `didCompleteWithError` with a `.cancelled` URLError performs the
            // continuation resume + cleanup.
            self.session.getAllTasks { tasks in
                for task in tasks where task.taskIdentifier == entry.taskIdentifier {
                    task.cancel()
                }
            }
        }
    }

    // MARK: - Share-Extension drain reconcile

    /// Whether a converse task for `shareEnvelopeID` is currently LIVE on the
    /// background session (running OR suspended — i.e. not yet completed). The
    /// Share-Extension drainer calls this on relaunch BEFORE re-dispatching a
    /// share-originated turn: a live task means the prior process already sent
    /// it (leave it alone — the delegate will land the reply); no live task
    /// means the turn was either never sent or already completed, and the
    /// drainer's three-state envelope protocol decides (fail the turn + notify +
    /// delete, never auto-resend — at-most-once).
    ///
    /// Reads `session.allTasks` (the authoritative live set across a process
    /// relaunch — the in-memory `inFlight` registry is empty after a kill) and
    /// matches each task's decoded `taskDescription` metadata's `shareEnvelopeID`.
    /// `shareEnvelopeID == nil` callers never reach here (the drainer is the only
    /// caller and always passes a real envelope id).
    func hasLiveConverseTask(shareEnvelopeID: UUID) async -> Bool {
        let tasks = await session.allTasks
        return tasks.contains { task in
            guard let desc = task.taskDescription,
                  let meta = try? RemoteAgentBackgroundMetadata.decode(desc) else {
                return false
            }
            return meta.shareEnvelopeID == shareEnvelopeID
        }
    }

    // MARK: - Launch-time stale-"sending" sweep support

    /// Conversation IDs with a LIVE converse task on this background session
    /// (running OR suspended — not yet completed). Read from
    /// `session.allTasks` + each task's decoded `taskDescription` metadata
    /// (the authoritative cross-launch set; the in-memory registry is empty
    /// after a kill). The launch-time stale-`sending` sweep excludes these
    /// conversations — their turns will be resolved authoritatively by this
    /// delegate when the task completes.
    func liveConversationIDs() async -> Set<UUID> {
        let tasks = await session.allTasks
        return Set(tasks.compactMap { task in
            task.taskDescription
                .flatMap { try? RemoteAgentBackgroundMetadata.decode($0) }
                .flatMap { UUID(uuidString: $0.conversationID) }
        })
    }

    // MARK: - Registry helpers

    private func register(
        continuation: CheckedContinuation<String, Error>?,
        taskIdentifier: Int,
        conversationID: UUID,
        bodyFileURL: URL
    ) {
        queue.async {
            self.inFlight[taskIdentifier] = InFlightTurn(
                taskIdentifier: taskIdentifier,
                conversationID: conversationID,
                continuation: continuation
            )
            self.responseBuffers[taskIdentifier] = Data()
            self.bodyURLs[taskIdentifier] = bodyFileURL
#if DEBUG
            self.diagSentAt[taskIdentifier] = Date()
#endif
        }
    }
}

// MARK: - URLSession delegate

extension BackgroundRemoteAgent: URLSessionDataDelegate {
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let id = dataTask.taskIdentifier
        queue.async {
            self.responseBuffers[id, default: Data()].append(data)
        }
    }

    /// TASK-level server-trust challenge handler — host-scoped per-ref pinning
    /// for the converse hop. The shared background session can carry concurrent
    /// turns to different gateways, so the pin MUST be resolved per task: recover
    /// the turn's `refRawValue` from `taskDescription` and look up that ref's
    /// pin (host-guarded) LIVE from App-Group defaults. nil → default ATS
    /// (unpinned gateway, or a built-in/custom on a publicly-trusted cert).
    /// Mirrors `STTClient+Background`'s task-level trust handler. NOTE: a
    /// session-level `urlSession(_:didReceive:)` would take precedence, so it is
    /// intentionally absent — only this task-level handler exists.
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
        // A non-nil pin was recovered → enforce it (match → useCredential;
        // mismatch → cancel). Compare delegated to the generic evaluator.
        let evaluator = RemoteAgentTrustEvaluator(pinnedFingerprintHex: pin)
        evaluator.urlSession(session, didReceive: challenge, completionHandler: completionHandler)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let id = task.taskIdentifier

        // Recover the metadata envelope from `taskDescription`. May be nil on
        // a foreign/older task; degrade gracefully (no cleanup, no append).
        let metadata: RemoteAgentBackgroundMetadata? = task.taskDescription.flatMap {
            try? RemoteAgentBackgroundMetadata.decode($0)
        }

        // Cleanup mandate (load-bearing): delete the request-body temp
        // file on EVERY exit path — success or failure.
        defer {
            if let bodyPath = metadata?.bodyPath {
                try? FileManager.default.removeItem(atPath: bodyPath)
            }
        }

        let backend: RemoteAgentBackend = metadata
            .flatMap { RemoteAgentBackend(rawValue: $0.backendRawValue) }
            ?? .openclaw
        let conversationID: UUID? = metadata.flatMap { UUID(uuidString: $0.conversationID) }
        // The exact user `Message.id` for per-message status flips; nil on old
        // taskDescription blobs / unthreaded callers → conversation-wide fallback.
        let userMessageID: UUID? = metadata?.userMessageID

        queue.async {
            if let bodyURL = self.bodyURLs.removeValue(forKey: id) {
                try? FileManager.default.removeItem(at: bodyURL)
            }

            let entry = self.inFlight.removeValue(forKey: id)
            let buffered = self.responseBuffers.removeValue(forKey: id) ?? Data()

            // A turn with no awaiting continuation is FIRE-AND-FORGET (the
            // headless Action-Button intent) — or a relaunched turn whose
            // continuation died. The Shortcut has already ended, so a converse
            // FAILURE must reach the user as a notification (below). The in-app
            // path keeps a live continuation and surfaces the error in the thread
            // UI instead, so it must NOT also push.
            let notifyUserOnFailure = entry?.continuation == nil

#if DEBUG
            let elapsed = self.diagSentAt.removeValue(forKey: id).map { Date().timeIntervalSince($0) } ?? -1
            let httpStatus = (task.response as? HTTPURLResponse)?.statusCode ?? -1
            RemoteAgentDiagnostics.log.log("done(bg): id=\(id, privacy: .public) elapsed=\(String(format: "%.1f", elapsed), privacy: .public)s http=\(httpStatus, privacy: .public) respBytes=\(buffered.count, privacy: .public) err=\(error?.localizedDescription ?? "nil", privacy: .public)")
#endif

            // Resolve the in-app continuation (if the awaiting task is still
            // alive) — defaults to a no-op closure for headless relaunches.
            let resolve: (Result<String, Error>) -> Void = { result in
                switch result {
                case .success(let reply): entry?.continuation?.resume(returning: reply)
                case .failure(let err): entry?.continuation?.resume(throwing: err)
                }
            }

            // --- Transport error path ---
            if let error {
                if let urlError = error as? URLError {
                    if urlError.code == .cancelled {
                        // Disambiguate by the in-memory registry:
                        //
                        // entry PRESENT → a live in-process cancel (user tapped
                        // Cancel / session teardown). No agent bubble, no
                        // notification, NO `.remoteAgentTurnDidFail` post —
                        // but the cancelled turn itself flips to `failed`
                        // (below); the in-app caller's continuation receives
                        // `CancellationError`.
                        //
                        // entry ABSENT → this task was resurrected ACROSS A
                        // LAUNCH (after a force-quit, ALL background tasks
                        // come back as `.cancelled`, and the registry died
                        // with the old process). Nobody cancelled this turn —
                        // treating it as a cancel left the user turn stuck at
                        // "sending" forever with no Retry. Map it to a
                        // cross-launch FAILURE: flip the turn to `failed`
                        // (Retry chip) + post the failure notification (no
                        // awaiting caller exists by definition). `error: nil`
                        // keeps the generic "wasn't delivered" copy.
                        if entry == nil {
                            if let cid = conversationID {
                                self.postTurnFailed(conversationID: cid, userMessageID: userMessageID, error: nil, notifyUser: true)
                            }
                            return
                        }
                        // LIVE cancel: flip the cancelled turn itself to
                        // `failed` — leaving it at `sending` stranded an
                        // eternal spinner until the launch sweep (the VM's
                        // CancellationError catch deliberately doesn't touch
                        // status). `failed` is the honest terminal: the Retry
                        // chip lets the user re-send. Exact-message flip when
                        // the id was threaded (a conversation-wide flip here
                        // would alias a sibling in-flight turn); NO failure
                        // notification and NO `.remoteAgentTurnDidFail` post —
                        // cancel is user-initiated, not a failure event.
                        if let cid = conversationID {
                            self.beginPersistenceWork()
                            Task {
                                if let mid = userMessageID {
                                    await ConversationStore.shared.markPendingUserTurn(messageID: mid, to: "failed")
                                } else {
                                    await ConversationStore.shared.markPendingUserTurns(conversationID: cid, to: "failed")
                                }
                                self.endPersistenceWork()
                            }
                        }
                        resolve(.failure(CancellationError()))
                        return
                    }
                    let mapped = Self.mapURLError(urlError)
                    resolve(.failure(mapped))
                    if let cid = conversationID {
                        self.postTurnFailed(conversationID: cid, userMessageID: userMessageID, error: mapped, notifyUser: notifyUserOnFailure)
                    }
                } else {
                    resolve(.failure(AppError.remoteAgentUnreachable))
                    if let cid = conversationID {
                        self.postTurnFailed(conversationID: cid, userMessageID: userMessageID, error: .remoteAgentUnreachable, notifyUser: notifyUserOnFailure)
                    }
                }
                return
            }

            // --- HTTP status mapping ---
            guard let http = task.response as? HTTPURLResponse else {
                resolve(.failure(AppError.remoteAgentInvalidResponse))
                if let cid = conversationID {
                    self.postTurnFailed(conversationID: cid, userMessageID: userMessageID, error: .remoteAgentInvalidResponse, notifyUser: notifyUserOnFailure)
                }
                return
            }

            // Body-aware mapping FIRST (mirrors RemoteAgentClient.decodeReply):
            // a structured adapter wire code, or a 400/404/413 whose body names
            // the problem (no-vision model, image too large, context overflow,
            // bad model id); the `(Int)->` status map never sees the body, so
            // this dedicated pass runs before it. The classified carrier (not
            // the bare AppError) rides both the continuation AND the failure
            // writer so the classification is persisted even when the
            // awaiting VM died with the process.
            if let classified = RemoteAgentClient.classifyBodyError(status: http.statusCode, body: buffered) {
                resolve(.failure(classified))
                if let cid = conversationID {
                    self.postTurnFailed(
                        conversationID: cid,
                        userMessageID: userMessageID,
                        error: classified.appError,
                        wireCode: classified.wireCode,
                        hadHistoryImages: metadata?.requestHadHistoryImages,
                        notifyUser: notifyUserOnFailure
                    )
                }
                return
            }

            if let mapped = backend.statusMap.map(http.statusCode) {
                resolve(.failure(mapped))
                if let cid = conversationID {
                    self.postTurnFailed(conversationID: cid, userMessageID: userMessageID, error: mapped, notifyUser: notifyUserOnFailure)
                }
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
                resolve(.failure(AppError.remoteAgentInvalidResponse))
                if let cid = conversationID {
                    self.postTurnFailed(conversationID: cid, userMessageID: userMessageID, error: .remoteAgentInvalidResponse, notifyUser: notifyUserOnFailure)
                }
                return
            }

            resolve(.success(reply))

            // Persist the agent reply + fire the completion notification.
            // Runs even for headless relaunches (no awaiting continuation).
            // Counted as persistence work so `handleBackgroundEvents()` holds
            // the `.backgroundTask` closure open until the append lands.
            // `.remoteAgentTurnDidComplete` only fires when the reply actually
            // persisted (recordReply returns false on an append failure —
            // announcing completion for a reply that isn't there would lie).
            if let cid = conversationID {
                self.beginPersistenceWork()
                Task {
                    // `recordReply` persists the reply, flips the user turn, runs
                    // output detection, fires the user reply notification, AND posts
                    // `.remoteAgentTurnDidComplete` (only when the reply actually
                    // persisted — see its tail). It is the SINGLE shared landing
                    // path: the iOS background delegate (here) and the macOS
                    // foreground share-drain dispatch (`LiveConverseDispatcher`) both
                    // call it, so a reply lands identically regardless of transport.
                    _ = await Self.recordReply(
                        reply,
                        conversationID: cid,
                        backendRawValue: metadata?.backendRawValue,
                        userMessageID: userMessageID,
                        stampsActiveConversation: metadata?.stampsActiveConversation ?? false
                    )
                    self.endPersistenceWork()
                }
            }
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        queue.async {
            self.didFinishBackgroundEvents = true
            self.resumeDrainWaitersIfReady()
        }
    }

    // MARK: - Error mapping (mirrors RemoteAgentClient.performRequest)

    private static func mapURLError(_ error: URLError) -> AppError {
        switch error.code {
        case .timedOut:
            return .remoteAgentTimeout
        case .cannotConnectToHost,
             .notConnectedToInternet,
             .networkConnectionLost,
             .cannotFindHost,
             .dnsLookupFailed,
             .resourceUnavailable:
            return .remoteAgentUnreachable
        case .serverCertificateUntrusted,
             .serverCertificateHasBadDate,
             .serverCertificateHasUnknownRoot,
             .serverCertificateNotYetValid:
            // The system NAMED the certificate as the cause → cert mismatch.
            return .remoteAgentCertMismatch
        case .secureConnectionFailed:
            // GENERIC SSL failure (`-1200`) — NOT a certificate-trust signal on
            // its own. This long-lived background session can't read the
            // trust-evaluator's per-challenge signals, so (like the foreground
            // converse hop) treat the generic code as a transient handshake
            // failure → retryable, NOT a false cert mismatch on a cold tunnel.
            return .remoteAgentUnreachable
        default:
            return .remoteAgentUnreachable
        }
    }

    // MARK: - Reply persistence + completion notification

    /// Append the agent reply to the conversation and — for headless quick
    /// captures ONLY (`stampsActiveConversation`) — bump the per-device
    /// active-conversation pointer. The pointer is IMPLICIT-ONLY: written by
    /// headless captures (intent, Watch), read by headless captures to choose
    /// a conversation; explicit surfaces (in-app thread, share drain, CarPlay)
    /// neither write nor depend on it — the in-app thread appends to the
    /// visible conversation regardless of the pointer/TTL. `sourceDevice` is
    /// the local device.
    /// Returns `true` when the reply was actually persisted; `false` when the
    /// append failed. On a real persist it ALSO posts `.remoteAgentTurnDidComplete`
    /// (the menu-bar reply-cue signal) as its last step — never on the
    /// append-failure path (announcing completion for a reply that isn't there
    /// would lie). SHARED LANDING PATH: called by the iOS background delegate AND
    /// the macOS foreground share-drain dispatch (`LiveConverseDispatcher`), so a
    /// reply lands identically (append → flip → detect → notify) on both
    /// transports. `internal static` (not `private`) so the drainer can reach it.
    static func recordReply(_ reply: String, conversationID: UUID, backendRawValue: String?, userMessageID: UUID?, stampsActiveConversation: Bool) async -> Bool {
        // CRASH-SAFETY ORDERING (load-bearing): persist the reply FIRST, flip
        // the user turn second, run anything slow (network probes) third, and
        // notify LAST. The old order flipped the user turn to `sent` and then
        // ran up to 5 output-detector network probes BEFORE the append — an OS
        // kill in that window left a `sent` user turn with no reply and no
        // redelivery (silent reply loss).

        // 1. Append the agent reply. Once this lands, a kill can't lose the turn.
        guard let appended = try? await ConversationStore.shared.appendMessage(
            role: "agent",
            text: reply,
            conversationID: conversationID,
            sourceDevice: SourceDevice.current
        ) else {
            // Append FAILED (conversation deleted on another device mid-flight,
            // or a store write failure). Mirror the CarPlay twin: EARLY-RETURN
            // with NO sent-flip and NO reply notification — flipping `sent`
            // would render a delivered turn with no reply, and the notification
            // would deep-link to a reply that isn't there. The user turn is
            // LEFT at `sending` (not flipped `failed`): in the dominant
            // deleted-conversation case the turn is gone with it anyway, and
            // `failed` would invite a Retry into a vanished thread; the
            // residual store-glitch case is resolved by the stale-`sending`
            // sweep (answered-turn guard can't apply — nothing persisted).
            return false
        }

        // 2. Authoritative send-state flip: clear the user turn's `sending`
        // spinner here (delegate path) so it can't stick after an OS
        // suspend+relaunch killed the foreground continuation that would
        // otherwise mark it sent. EXACT-message flip when the dispatch site
        // threaded the user `Message.id` (a conversation-wide flip aliases a
        // concurrent sibling turn's status); conversation-wide fallback for
        // old metadata blobs. No-op when the status already resolved.
        if let userMessageID {
            await ConversationStore.shared.markPendingUserTurn(messageID: userMessageID, to: "sent")
        } else {
            await ConversationStore.shared.markPendingUserTurns(conversationID: conversationID, to: "sent")
        }
        if stampsActiveConversation {
            await SettingsManager.shared.recordActiveConversation(conversationID)
        }

        // 3. Output detection (conservative): if the bound gateway has a
        // file-server configured AND the reply names an allowlisted output file
        // that probes `.exists`, attach it as a server-reference attachment to
        // the ALREADY-PERSISTED agent bubble so the thread can offer an inline
        // download chip. The common case (no file-server, or a reply with no
        // allowlisted filename) does ZERO network work — the detector returns
        // `[]` before any probe. A kill mid-probe now costs only the chips,
        // never the reply.
        let outputs = await FileTransferOutputDetector.detect(reply: reply, conversationID: conversationID)
        if !outputs.isEmpty {
            try? await ConversationStore.shared.addAttachments(messageID: appended.id, attachments: outputs)
        }

        // 4. Reply notification last. Resolve the TRUE bound ref from the
        // conversation row (`Conversation.backend` stores the ref rawString,
        // incl. `custom_<uuid>`) — the task metadata carries only the
        // status-map CARRIER raw value (`.openclaw` for customs), which would
        // mislabel a custom gateway's notification as "OpenClaw". Falls back
        // to the metadata value (correct for built-ins) when the conversation
        // row is gone. Tolerates old in-flight metadata unchanged.
        let refRawString = (try? await ConversationStore.shared.fetchConversation(id: conversationID))?.backend
            ?? backendRawValue
        await Self.postReplyNotification(reply, conversationID: conversationID, backendRawValue: refRawString)

        // 5. Completion signal LAST — the menu-bar reply cue (macOS) + any other
        // in-app observers. Reached ONLY on a real persist (past the
        // append-failure early-return). Fired here (was the delegate's separate
        // call) so the iOS background delegate and the macOS foreground
        // share-drain dispatch fire it identically, exactly once.
        await Self.postTurnCompleted(conversationID: conversationID)

        // 6. WS-2 preview enrichment (best-effort, DETACHED). Now that the chips
        // AND every completion step (notification, completion signal) have
        // persisted, spawn an UNSTRUCTURED task that pulls bounded preview
        // content and patches the rows. Detached so it never extends the counted
        // background-task lifetime the reply path depends on — the delegate's
        // persistence gate is satisfied the instant `recordReply` returns, and a
        // slow/failed download must never delay chip creation, the reply, or the
        // notifications. Fire-and-forget: if the OS suspends the app first, the
        // chips simply stay preview-less (no retry state machine, by design).
        if !outputs.isEmpty {
            let outputMessageID = appended.id
            Task.detached {
                await FileTransferOutputDetector.enrichPreviews(
                    drafts: outputs, messageID: outputMessageID, conversationID: conversationID)
            }
        }
        return true
    }

    /// The reply-notification title: in a multi-gateway setup (≥2 configured)
    /// it names the bound gateway so the user knows which agent answered before
    /// opening the app; otherwise the generic string. Falls back to generic on
    /// any unresolved ref (single-gateway, missing/unknown raw value).
    private static func replyNotificationTitle(backendRawValue: String?) async -> String {
        let generic = String(localized: "Reply from your personal AI")  // xcstrings
        guard await SettingsManager.shared.configuredRemoteAgentRefs().count >= 2,
              let raw = backendRawValue,
              let ref = RemoteAgentRef(rawString: raw) else { return generic }
        let customs = await SettingsManager.shared.customGateways()
        return RemoteAgentRefMetadata.displayName(for: ref, customs: customs)
    }

    /// Post the reply notification (≤200-char body) whose tap deep-links to
    /// the conversation. userInfo carries the conversationID for the
    /// `NotificationDelegate` deep-link.
    private static func postReplyNotification(_ reply: String, conversationID: UUID, backendRawValue: String?) async {
        let content = UNMutableNotificationContent()
        content.title = await Self.replyNotificationTitle(backendRawValue: backendRawValue)
        content.body = String(reply.prefix(200))
        content.sound = .default
        content.userInfo = [NotificationDeepLink.conversationIDKey: conversationID.uuidString]

        let request = UNNotificationRequest(
            identifier: NotificationDeepLink.replyIdentifierPrefix + conversationID.uuidString,
            content: content,
            trigger: nil
        )
        try? await UNUserNotificationCenter.current().add(request)
    }

    /// Post the FAILURE notification for a fire-and-forget headless turn whose
    /// Shortcut already ended — so a converse failure isn't silent. Tap
    /// deep-links to the conversation to retry. Only fired when no in-app caller
    /// is awaiting (the in-app path surfaces the error in the thread UI).
    ///
    /// `static` + internal (not `private`) so the OTHER fire-and-forget terminal
    /// failure sites whose caller has already returned can reuse this exact copy
    /// + identifier rather than replicate it: the share drainer (share sends run
    /// with `notifyUserOnFailure=false`, so the drainer must notify itself) and
    /// `ConverseIntent`'s pre-dispatch catch (the Shortcut throw alone wouldn't
    /// alert the user). The `remoteAgent.failure.` identifier prefix is
    /// load-bearing: `ReplyAutoSpeakDecider` excludes it from auto-speak (only
    /// `remoteAgent.reply.` taps speak), so a failure tap deep-links to the
    /// thread without speaking a stale prior reply.
    static func postFailureNotification(conversationID: UUID, error: AppError?) async {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Couldn't reach your personal AI")  // xcstrings
        // PRIVACY (never reveal gateway URLs — see the spec's Privacy & Security section): cases that
        // interpolate an UNDERLYING error's text (`.networkError` /
        // `.decodingError` / `.unknown` wrap a URLError whose description can
        // embed the gateway hostname) are mapped to the fixed
        // `remoteAgentUnreachable` copy. Every other case carries fixed,
        // hostname-free copy and passes through. Defensive: the delegate's
        // current mappings emit only fixed-copy cases, but this is the choke
        // point if a raw error is ever routed here.
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

    /// Post the turn-completion signal (`.remoteAgentTurnDidComplete`, userInfo
    /// `conversationID`) on the main queue. Called by `recordReply` as its LAST
    /// step on a successful persist — the SINGLE poster, shared by the iOS
    /// background delegate and the macOS foreground share-drain landing. The
    /// menu-bar reply cue (`MenuBarCoordinator`) observes this to raise the
    /// unread dot. `static` so it's reachable from the shared landing path + unit-
    /// testable without a store/network round-trip.
    static func postTurnCompleted(conversationID: UUID) async {
        await MainActor.run {
            NotificationCenter.default.post(
                name: .remoteAgentTurnDidComplete,
                object: nil,
                userInfo: [NotificationDeepLink.conversationIDKey: conversationID.uuidString]
            )
        }
    }

    /// Post the turn-FAILURE signal (`.remoteAgentTurnDidFail`, userInfo
    /// `conversationID`) on the main queue — the in-process bus the macOS
    /// menu-bar red dot observes (mirrors `postTurnCompleted`). `static` so the
    /// terminal failure sites whose caller has already returned (the share
    /// drainer's dispatch-failure / reconcile paths, `ConverseIntent`'s
    /// pre-dispatch catch) can raise the dot without an instance. The instance
    /// `postTurnFailed` delegate path posts the same name directly (it also
    /// carries an `errorCode`); this static carrier needs no error code.
    static func postTurnFailed(conversationID: UUID) async {
        await MainActor.run {
            NotificationCenter.default.post(
                name: .remoteAgentTurnDidFail,
                object: nil,
                userInfo: [NotificationDeepLink.conversationIDKey: conversationID.uuidString]
            )
        }
    }

    private func postTurnFailed(
        conversationID: UUID,
        userMessageID: UUID?,
        error: AppError?,
        wireCode: AdapterWireCode? = nil,
        hadHistoryImages: Bool? = nil,
        notifyUser: Bool
    ) {
        // Authoritative send-state flip on the delegate path (mirrors the
        // success path in `recordReply`): mark the pending user turn `failed`
        // so the bubble shows Retry even if the foreground continuation that
        // would have done so is gone after a suspend+relaunch. A live in-app
        // cancellation does NOT route here (it flips its exact turn in the
        // cancel mapping above); a post-kill resurrected `.cancelled` DOES —
        // that is a cross-launch failure.
        //
        // EXACT-message flip when the dispatch site threaded the user
        // `Message.id` (a conversation-wide flip would alias a concurrent
        // sibling turn — flipping a still-in-flight sibling to `failed` makes
        // its later success match nothing, leaving a delivered turn showing
        // Retry → duplicate send); conversation-wide fallback for old blobs.
        //
        // Counted as persistence work so `handleBackgroundEvents()` holds the
        // `.backgroundTask` closure open until the status flip + notification
        // land (this method is only called on `queue`, where the counter lives).
        beginPersistenceWork()
        Task {
            // The failure classification rides the same authoritative
            // flip (one save). The guarded `failTurn` transition converges
            // with the foreground VM's write regardless of order — a coded
            // classification is never lost to a plain `failed` that won the
            // race, and a resolved turn is never disturbed.
            let classification = error.map {
                ConversationStore.TurnFailureClassification(
                    failureCode: $0.errorCode,
                    wireCode: wireCode?.rawValue,
                    hadHistoryImages: hadHistoryImages
                )
            }
            if let userMessageID {
                await ConversationStore.shared.failTurn(messageID: userMessageID, classification: classification)
            } else {
                await ConversationStore.shared.failPendingUserTurns(conversationID: conversationID, classification: classification)
            }
            // Fire-and-forget headless turns (no awaiting caller) get a
            // user-facing failure notification so the error isn't silent now
            // that the Shortcut no longer blocks to surface it. The in-app
            // path (notifyUser == false) shows the error in the thread UI
            // instead — no duplicate push.
            if notifyUser {
                await Self.postFailureNotification(conversationID: conversationID, error: error)
            }
            self.endPersistenceWork()
        }
        DispatchQueue.main.async {
            var userInfo: [AnyHashable: Any] = [
                NotificationDeepLink.conversationIDKey: conversationID.uuidString
            ]
            if let error {
                userInfo[NotificationDeepLink.errorCodeKey] = error.errorCode
            }
            NotificationCenter.default.post(
                name: .remoteAgentTurnDidFail,
                object: nil,
                userInfo: userInfo
            )
        }
    }
}

// MARK: - Notification names + deep-link keys

extension Notification.Name {
    /// Posted (main thread) when a converse turn completes successfully and
    /// the agent reply has been persisted. userInfo carries the
    /// conversationID string under `NotificationDeepLink.conversationIDKey`.
    static let remoteAgentTurnDidComplete = Notification.Name("remoteAgentTurnDidComplete")

    /// Posted (main thread) when a converse turn fails (non-cancellation).
    /// userInfo carries the conversationID string + an `errorCode` Int.
    static let remoteAgentTurnDidFail = Notification.Name("remoteAgentTurnDidFail")

    /// Posted (main thread) by the `NotificationDelegate` on a reply-
    /// notification tap. userInfo carries the target conversationID string;
    /// ContentView observes + navigates to that thread (deep-link).
    static let openConversationDeepLink = Notification.Name("openConversationDeepLink")

    /// Posted (main thread, macOS only) when an agent reply lands for a
    /// conversation. userInfo carries the conversationID string. macOS surfaces
    /// replies via a menu-bar unread dot rather than a notification, so
    /// `MenuBarCoordinator` observes this to mark the thread unread (unless it's
    /// the one the popover is currently showing). Independent of the (now-
    /// removed) reply banner — it always fires on a macOS reply success.
    static let conversationReplyArrived = Notification.Name("conversationReplyArrived")
}

/// Keys for notification userInfo deep-link payloads.
enum NotificationDeepLink {
    /// userInfo key carrying the target conversation UUID string.
    static let conversationIDKey = "conversationID"
    /// userInfo key carrying an `AppError.errorCode` Int (turn-failed bus).
    static let errorCodeKey = "errorCode"
    /// Request-identifier prefix shared by every agent-REPLY notification
    /// (the iOS background delegate + the macOS in-app poster). Load-bearing
    /// contract: `ReplyAutoSpeakDecider` discriminates reply taps from
    /// FAILURE taps (`remoteAgent.failure.<uuid>` — which also carry a
    /// `conversationIDKey` for tap-to-retry) by this prefix, so a failure tap
    /// never auto-speaks a stale previous reply. Single-sourced here so the
    /// posting sites and the decider can't drift.
    static let replyIdentifierPrefix = "remoteAgent.reply."
}

// MARK: - Source device

/// The current device's `Message.sourceDevice` tag (`phone`/`ipad`/`mac`/
/// `watch`/`carplay`). Centralised so every converse caller stamps the same
/// value. Watch + CarPlay surfaces stamp their own value at their
/// call sites; the iOS app + intent use `.current`.
enum SourceDevice {
    static var current: String {
        #if os(macOS)
        return "mac"
        #elseif os(watchOS)
        return "watch"
        #else
        #if canImport(UIKit)
        if UIDevice.current.userInterfaceIdiom == .pad { return "ipad" }
        #endif
        return "iphone"
        #endif
    }
}

// MARK: - File-transfer output detection

/// Conservative output-file detector for the file-transfer feature. After an
/// agent reply lands, this scans the reply text for filename-looking tokens and,
/// for the small allowlisted subset, probes the user's file-server to see if the
/// agent actually WROTE that file into its working folder. Each confirmed file
/// becomes a server-reference `AttachmentDraft` on the AGENT bubble, which the
/// thread renders as an inline download chip (the download itself happens on
/// chip tap).
///
/// Lives in this file (not its own) so it inherits `BackgroundRemoteAgent`'s
/// app-only target membership without a `project.pbxproj` edit — and so BOTH the
/// background delegate (`recordReply`) and the macOS foreground reply-append
/// (`ConversationDetailViewModel`) call the SAME `detect(...)`, keeping the two
/// reply paths' attachment behaviour identical.
///
/// CONSERVATIVE by design (false positives are worse than misses here):
///   - Only extensions in `outputAllowlist` survive the regex — this drops the
///     "e.g." / "v1.1" / "example.com" prose false-positives a bare
///     filename regex produces.
///   - The conversation's own INBOUND storedKeys are excluded: the turn text
///     tells the agent each uploaded file's stored name, so a reply merely
///     echoing it would otherwise probe `.exists` (the file IS on the server —
///     WE put it there) and chip the user's own upload back at them.
///   - Distinct candidates are CAPPED at 5 so a chatty reply can't fan out into
///     dozens of probes against the user's home server.
///   - A candidate is kept ONLY when it probes `.exists` (a real GET 200/206) —
///     a name the model mentioned but never wrote yields nothing.
///   - When the bound gateway has NO file-server configured, the detector
///     returns `[]` IMMEDIATELY (zero probes) — the common case stays free.
///
/// PRIVACY (see the spec's Privacy & Security section): never logs the reply text,
/// candidate filenames, storedKeys, or the snapshot. Returns the structured
/// drafts; no `print`/`os_log` anywhere in this path.
enum FileTransferOutputDetector {

    /// Curated set of output-file extensions worth probing. Deliberately narrow:
    /// document / data / archive / image / code types an agent tool realistically
    /// WRITES, chosen so common prose tokens ("e.g.", "v1.1", "example.com") with
    /// a non-file extension never reach the network. Lowercased for matching.
    private static let outputAllowlist: Set<String> = [
        "pdf", "csv", "tsv", "json", "xml", "yaml", "yml", "txt", "md", "log",
        "zip", "tar", "gz", "png", "jpg", "jpeg", "gif", "svg",
        "xlsx", "xls", "docx", "doc", "pptx", "html",
        "py", "js", "ts", "sh", "sql", "parquet"
    ]

    /// Maximum distinct candidates probed per reply (caps fan-out on a chatty
    /// reply that mentions many filenames).
    private static let maxCandidates = 5

    /// Detect server-written output files referenced verbatim in `reply` and
    /// confirmed present on the conversation's bound file-server. Returns the
    /// confirmed files as server-reference `AttachmentDraft`s (empty when no
    /// file-server is configured, no allowlisted token appears, or nothing
    /// probes `.exists`).
    ///
    /// The LANDING-PATH entry point (`recordReply`, the macOS foreground append):
    /// resolves the snapshot + inbound-exclusion set itself, passes NO
    /// pre-excluded keys (a landing turn has no attachments yet), and discards
    /// the conclusiveness verdict (landing never marks `outputScanDone` — that's
    /// the retro pass's job). Signature + behaviour are frozen so the two reply
    /// paths keep chipping identically.
    static func detect(reply: String, conversationID: UUID) async -> [AttachmentDraft] {
        // Resolve the bound ref → file-server snapshot. No file-server configured
        // → bail before any scan/probe (the common case pays nothing).
        let raw = try? await ConversationStore.shared.fetchConversation(id: conversationID)?.backend
        guard let ref = raw.flatMap({ RemoteAgentRef(rawString: $0) }),
              let snapshot = await SettingsManager.shared.fileTransferSnapshot(for: ref) else {
            return []
        }

        // Gate the inbound-exclusion fetch on a filename-shaped candidate
        // existing (the common no-candidate reply pays only the snapshot resolve
        // + one regex — no extra store fetch).
        guard !extractCandidates(from: reply).isEmpty else { return [] }

        let inbound = await inboundStoredKeyTokens(conversationID: conversationID)
        let (drafts, _) = await detect(
            reply: reply,
            snapshot: snapshot,
            inboundTokens: inbound,
            excludedKeys: []
        )
        return drafts
    }

    /// Core detector on PRE-RESOLVED context — the seam the retroactive scan
    /// drives (it resolves the snapshot + inbound set ONCE for a whole pass, then
    /// calls this per candidate turn). Same candidate extraction / allowlist /
    /// inbound-exclusion / cap-5 pipeline as the public entry point, plus:
    ///   - `excludedKeys` additionally drops candidates whose storedKey is already
    ///     attached on the TARGET message (retro dedupe BEFORE the probe, so an
    ///     already-chipped key can't eat a probe slot). Empty on the landing path.
    ///   - Reports `conclusive` = every probe attempted returned a DEFINITIVE
    ///     verdict (`.exists` / `.missing`); `.unauthorized` / `.serverError` /
    ///     `.unknown` ⇒ false (a transient failure the caller must retry, not
    ///     stamp as scanned). Zero candidates ⇒ conclusive true (nothing to probe).
    ///
    /// PRIVACY (see the spec's Privacy & Security section): never logs the reply text, candidate filenames,
    /// storedKeys, or the snapshot — no `print`/`os_log` in this path.
    static func detect(
        reply: String,
        snapshot: SettingsManager.FileTransferSnapshot,
        inboundTokens: Set<String>,
        excludedKeys: Set<String>
    ) async -> (drafts: [AttachmentDraft], conclusive: Bool) {
        let candidates = extractCandidates(from: reply)
        // Nothing filename-shaped to probe → definitively conclusive (a marked
        // turn will never be re-scanned, which is correct: there is no output).
        guard !candidates.isEmpty else { return ([], true) }

        // Drop the conversation's own inbound uploads AND any storedKey already
        // attached on the target message BEFORE the cap, so neither an echoed
        // inbound name nor an already-chipped output can become a duplicate chip
        // or eat a probe slot.
        let outputs = candidates
            .filter { !inboundTokens.contains($0) && !excludedKeys.contains($0) }
            .prefix(maxCandidates)
        guard !outputs.isEmpty else { return ([], true) }

        var drafts: [AttachmentDraft] = []
        var conclusive = true
        for candidate in outputs {
            // Size-returning probe so the download chip can render the file size
            // and gate a soft-confirm on very large downloads. Same ranged GET as
            // `probeExists`; `byteLength` is nil when the server omits a parseable
            // length (→ byteSize 0 = "unknown", chip shows no size + no gate).
            let (outcome, byteLength) = await BackgroundFileTransfer.shared.probeExistsWithLength(
                snapshot: snapshot,
                storedKey: candidate
            )
            // A single inconclusive probe (auth / 5xx / transport) unmarks the
            // whole pass so a later open retries — never stamps `outputScanDone`.
            if !probeIsConclusive(outcome) { conclusive = false }
            // Only a confirmed-present file chips; a mentioned-but-never-written
            // name (`.missing`) yields nothing but is still a conclusive verdict.
            guard outcome == .exists else { continue }
            var draft = AttachmentDraft(
                mimeType: mimeType(for: candidate),
                filename: candidate,
                data: Data(),
                thumbnailData: nil,
                width: 0,
                height: 0,
                byteSize: byteLength.map(Int.init) ?? 0,   // Int64 → Int (64-bit on-device); 0 = unknown
                sequence: drafts.count
            )
            draft.isServerReference = true
            draft.storedKey = candidate
            drafts.append(draft)
        }
        return (drafts, conclusive)
    }

    /// Whether a single probe outcome is DEFINITIVE for scan-completeness: only a
    /// real present/absent verdict (`.exists` / `.missing`) lets a retro pass mark
    /// the turn `outputScanDone`. `.unauthorized` / `.serverError` / `.unknown`
    /// are transient/inconclusive — the pass stays unmarked so a later thread
    /// open retries. Pure + content-free; internal for the test target.
    static func probeIsConclusive(_ outcome: FileProbeOutcome) -> Bool {
        switch outcome {
        case .exists, .missing: return true
        case .unauthorized, .serverError, .unknown: return false
        }
    }

    /// Scan `reply` for filename-looking tokens (`<base>.<ext>`), keep only those
    /// whose lowercased extension is in `outputAllowlist`, dedup preserving first
    /// appearance. UNCAPPED — `detect` applies `maxCandidates` AFTER the inbound
    /// exclusion, so an echoed inbound name never displaces a real output from
    /// the cap window. Pure + content-free (never logged). Internal (not
    /// private) for the test target.
    static func extractCandidates(from reply: String) -> [String] {
        // `name.ext` where name is a safe token and ext is 1–8 alnum chars. The
        // allowlist filter below is what actually defeats prose false-positives;
        // the regex just enumerates filename-shaped tokens.
        let pattern = "[A-Za-z0-9._-]+\\.[A-Za-z0-9]{1,8}"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(reply.startIndex..<reply.endIndex, in: reply)

        var seen = Set<String>()
        var ordered: [String] = []
        for match in regex.matches(in: reply, range: range) {
            guard let r = Range(match.range, in: reply) else { continue }
            let token = String(reply[r])
            guard let dot = token.lastIndex(of: ".") else { continue }
            let ext = token[token.index(after: dot)...].lowercased()
            guard outputAllowlist.contains(ext) else { continue }
            if seen.insert(token).inserted {
                ordered.append(token)
            }
        }
        return ordered
    }

    /// Fetch the conversation's messages and build the inbound-exclusion set.
    /// A store-fetch failure yields an EMPTY set — never blocks detection
    /// outright; the probe-exists gate still stands between any candidate and a
    /// chip.
    private static func inboundStoredKeyTokens(conversationID: UUID) async -> Set<String> {
        guard let messages = try? await ConversationStore.shared.fetchMessages(for: conversationID) else {
            return []
        }
        return inboundStoredKeyTokens(in: messages)
    }

    /// Pure core of the inbound-exclusion set (internal for the test target):
    /// the storedKey of every attachment on a NON-agent turn, plus — for a
    /// nested `<convID>/<key>` — its last path component, because the
    /// candidate regex can't match across `/` so a reply echoing a nested key
    /// only ever surfaces the filename segment. Agent-side attachments are NOT
    /// excluded: a later reply re-mentioning a genuine output file should still
    /// chip it. Non-`user` unknown roles count as inbound — the conservative
    /// direction (a wrongly-suppressed chip beats a wrong chip).
    static func inboundStoredKeyTokens(in messages: [MessageRecord]) -> Set<String> {
        var tokens = Set<String>()
        for message in messages where message.role != "agent" {
            for attachment in message.attachments {
                guard let key = attachment.storedKey else { continue }
                tokens.insert(key)
                if let slash = key.lastIndex(of: "/") {
                    tokens.insert(String(key[key.index(after: slash)...]))
                }
            }
        }
        return tokens
    }

    /// Best-effort MIME type from a filename's extension; defaults to
    /// `application/octet-stream` (the agent's tools wrote the real bytes — this
    /// only labels the download chip).
    private static func mimeType(for filename: String) -> String {
        guard let dot = filename.lastIndex(of: ".") else { return "application/octet-stream" }
        switch filename[filename.index(after: dot)...].lowercased() {
        case "pdf": return "application/pdf"
        case "csv": return "text/csv"
        case "tsv": return "text/tab-separated-values"
        case "json": return "application/json"
        case "xml": return "application/xml"
        case "yaml", "yml": return "application/yaml"
        case "txt", "log": return "text/plain"
        case "md": return "text/markdown"
        case "html": return "text/html"
        case "zip": return "application/zip"
        case "tar": return "application/x-tar"
        case "gz": return "application/gzip"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "svg": return "image/svg+xml"
        case "xlsx": return "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
        case "xls": return "application/vnd.ms-excel"
        case "docx": return "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
        case "doc": return "application/msword"
        case "pptx": return "application/vnd.openxmlformats-officedocument.presentationml.presentation"
        case "py": return "text/x-python"
        case "js": return "text/javascript"
        case "ts": return "application/typescript"
        case "sh": return "application/x-sh"
        case "sql": return "application/sql"
        case "parquet": return "application/vnd.apache.parquet"
        default: return "application/octet-stream"
        }
    }

    // MARK: - WS-2 preview enrichment

    /// A `ConversationStore.applyPreviews` patch tuple. Aliased so the builder's
    /// signature and its call sites can't drift from the store's shape.
    typealias PreviewPatch = (messageID: UUID, storedKey: String, previewData: Data?, previewKind: String?, thumbnailData: Data?)

    /// Per-reply SOURCE-download budget: total bytes fetched from the user's
    /// file-server across ALL previews produced for ONE reply's draft batch.
    /// Caps how much a single chatty reply's outputs can pull from the home
    /// server. Counts ACTUAL received bytes (a range-truncated fetch counts its
    /// capped size).
    nonisolated static let perReplyPreviewSourceBudget: Int64 = 8 * 1024 * 1024   // 8 MiB
    /// Per-reply STORED-preview budget: total preview/thumbnail bytes actually
    /// PRODUCED (persisted) across one reply's batch. Caps on-device growth.
    nonisolated static let perReplyPreviewStoredBudget = 512 * 1024               // 512 KiB
    /// Hard per-image SOURCE fetch cap for the image lane (8 MiB): an image whose
    /// bytes exceed this never fully downloads (the fetch bails at the cap and
    /// yields nil → the item is skipped).
    nonisolated static let imagePreviewSourceMaxBytes: Int64 = 8 * 1024 * 1024    // 8 MiB

    /// The IMAGE subset of `outputAllowlist` whose bytes ImageIO can raster-
    /// decode into a thumbnail — DERIVED by intersecting the detector's own
    /// allowlist, so it can never name an extension the detector wouldn't chip
    /// (drop one from `outputAllowlist` and it drops here too). `svg` is in the
    /// allowlist but excluded: ImageIO cannot rasterize it (no thumbnail), so
    /// fetching one would burn an 8 MiB download only to fail the decode.
    nonisolated static let imagePreviewExtensions: Set<String> =
        outputAllowlist.intersection(["png", "jpg", "jpeg", "gif"])

    /// Build first-writer preview patches for `drafts` (one reply's output
    /// chips), SEQUENTIALLY in draft order — no parallel downloads. Pure
    /// orchestration over `BackgroundFileTransfer.fetchBounded` +
    /// `ImageProcessor.thumbnailOnly`; never throws, never logs. Budgets are
    /// `inout` so a retro pass can thread ONE shared budget across every reply in
    /// the pass. Text lane → `previewData` + kind `"text"` (strict UTF-8); image
    /// lane → `thumbnailData` only. Any per-item failure (fetch nil, invalid
    /// UTF-8, decode fail, over a hard max, or a KNOWN byteSize already over the
    /// remaining budget) skips that item and continues to later (possibly
    /// smaller) items; an exhausted budget stops the batch.
    ///
    /// PRIVACY (see the spec's Privacy & Security section): never logs filenames, storedKeys, or bytes.
    ///
    /// `fetch` is injectable for tests (default = the real bounded file-server
    /// GET) so the budget/eligibility/sequencing logic is unit-testable without a
    /// live server. `(snapshot, storedKey, maxBytes) -> (data, received)` — the
    /// budget is charged `received` on EVERY attempt (over-cap bail included), so
    /// N oversized outputs against a Range-ignoring server can't blow past the
    /// per-reply source ceiling.
    nonisolated static func buildPreviewPatches(
        for drafts: [AttachmentDraft],
        messageID: UUID,
        snapshot: SettingsManager.FileTransferSnapshot,
        sourceBudget: inout Int64,
        storedBudget: inout Int,
        fetch: (SettingsManager.FileTransferSnapshot, String, Int) async -> (data: Data?, received: Int64) = { snapshot, storedKey, maxBytes in
            await BackgroundFileTransfer.shared.fetchBounded(
                snapshot: snapshot, storedKey: storedKey, maxBytes: maxBytes)
        }
    ) async -> [PreviewPatch] {
        var patches: [PreviewPatch] = []

        for draft in drafts {
            // Budget exhausted → nothing more can be produced this batch.
            if sourceBudget <= 0 || storedBudget <= 0 { break }

            guard draft.isServerReference,
                  let storedKey = draft.storedKey,
                  let filename = draft.filename else { continue }
            // byteSize 0 == "unknown" (the probe couldn't parse a length) → still
            // eligible; the fetch cap protects. A KNOWN size is a pre-fetch filter.
            let knownSize: Int64? = draft.byteSize > 0 ? Int64(draft.byteSize) : nil

            // --- TEXT LANE ---
            if AttachmentRecord.isPreviewableTextFilename(filename),
               knownSize == nil || knownSize! <= Int64(AttachmentRecord.watchViewableTextByteCeiling) {
                // Known-too-big-for-remaining-budget → skip WITHOUT fetching, but
                // keep scanning for later smaller items.
                if let size = knownSize, size > sourceBudget || size > Int64(storedBudget) { continue }
                let cap = Int(min(Int64(AttachmentRecord.watchViewableTextByteCeiling), sourceBudget))
                guard cap > 0 else { continue }
                let (data, received) = await fetch(snapshot, storedKey, cap)
                sourceBudget -= received                      // charge bytes actually pulled, success OR over-cap bail
                guard let data else { continue }
                // Strict UTF-8 — reject binary/mislabelled or mid-codepoint-
                // truncated bytes rather than store an undecodable preview.
                guard String(data: data, encoding: .utf8) != nil else { continue }
                guard data.count <= storedBudget else { continue }
                storedBudget -= data.count
                patches.append((messageID, storedKey, data, "text", nil))
                continue
            }

            // --- IMAGE LANE ---
            if imagePreviewExtensions.contains(Self.fileExtension(of: filename)),
               knownSize == nil || knownSize! <= imagePreviewSourceMaxBytes {
                if let size = knownSize, size > sourceBudget { continue }
                let cap = Int(min(imagePreviewSourceMaxBytes, sourceBudget))
                guard cap > 0 else { continue }
                let (data, received) = await fetch(snapshot, storedKey, cap)
                sourceBudget -= received                      // charge bytes actually pulled, success OR over-cap bail
                guard let data else { continue }
                // Decode-as-validity: non-image bytes fail here → skip. Thumbnail
                // only (no wasted full-size decode); nil if over the 128 KiB max.
                guard let thumb = ImageProcessor.thumbnailOnly(from: data) else { continue }
                guard thumb.count <= storedBudget else { continue }
                storedBudget -= thumb.count
                patches.append((messageID, storedKey, nil, nil, thumb))
                continue
            }
        }
        return patches
    }

    /// Lowercased file extension of `filename` (empty when none). Local helper
    /// for the image lane — text eligibility uses `AttachmentRecord`'s own
    /// allowlist (`isPreviewableTextFilename`).
    nonisolated private static func fileExtension(of filename: String) -> String {
        guard let dot = filename.lastIndex(of: "."), dot != filename.index(before: filename.endIndex) else {
            return ""
        }
        return filename[filename.index(after: dot)...].lowercased()
    }

    /// Best-effort landing-path enrichment for ONE reply's output chips (WS-2):
    /// the detached tail spawned AFTER the chips + notifications persist.
    /// Re-resolves the bound ref's READY file-server snapshot, guards against a
    /// lane repoint (identity signature captured before, re-checked after the
    /// downloads — mirrors `runRetroOutputScan`), builds per-reply-budgeted
    /// patches, and applies them first-writer-wins. Aborts silently on a
    /// missing/unready lane or an identity drift; never throws; must never extend
    /// the reply path's background-task lifetime (callers spawn it detached).
    nonisolated static func enrichPreviews(
        drafts: [AttachmentDraft],
        messageID: UUID,
        conversationID: UUID
    ) async {
        guard !drafts.isEmpty else { return }
        guard let raw = try? await ConversationStore.shared.fetchConversation(id: conversationID)?.backend,
              let ref = RemoteAgentRef(rawString: raw),
              let snapshot = await SettingsManager.shared.fileTransferReadySnapshot(for: ref) else {
            return
        }
        let identityBefore = snapshot.identitySignature
        var sourceBudget = perReplyPreviewSourceBudget
        var storedBudget = perReplyPreviewStoredBudget
        let patches = await buildPreviewPatches(
            for: drafts, messageID: messageID, snapshot: snapshot,
            sourceBudget: &sourceBudget, storedBudget: &storedBudget)
        guard !patches.isEmpty else { return }
        // Lane-repoint guard: a URL/credential/pin change during the downloads
        // must not apply old-server previews to a now-different lane.
        guard let after = await SettingsManager.shared.fileTransferReadySnapshot(for: ref),
              after.identitySignature == identityBefore else {
            return
        }
        _ = try? await ConversationStore.shared.applyPreviews(patches)
    }
}
