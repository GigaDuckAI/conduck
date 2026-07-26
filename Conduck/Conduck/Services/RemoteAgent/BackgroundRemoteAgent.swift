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
// SettingsManager writes) and delegates the actual compare to
// `RemoteAgentTrustEvaluator`. Mirrors the STT background sibling
// (`STTClient+Background.swift`). Per-challenge live resolution is
// relaunch-safe (a cross-launch-resumed task re-reads the durable pin),
// task-scoped (keyed off the TASK, so concurrent turns to different gateways
// never read each other's pin), custom-correct (keyed off the true ref, never
// the `.openclaw` status-map carrier), and honors a post-enqueue cert re-pin.
// Reading UserDefaults directly keeps the nonisolated delegate synchronous
// (no MainActor hop into SettingsManager).
//
// The resolved pin is applied HOST-BLIND — the delegate never compares
// `challenge.protectionSpace.host` against the ref's configured URL, so the
// pin governs EVERY server-trust challenge the task raises, including one
// raised by a redirect target. Deliberate: a background session always follows
// redirects and never delivers `willPerformHTTPRedirection` (SDK contract), so
// this callback is the only point at which a background converse task can push
// back on a cross-host hop at all. Host-SCOPING would resolve "no pin" for the
// redirect host and degrade exactly that hop to default ATS — the pin ceasing
// to apply at the one moment it matters, with the full request body
// (conversation history + images + the bearer header) riding along.
//
// HONEST LIMIT — mitigation, not a redirect veto: a pin compare proves
// same-KEY, not same-ORIGIN. A wildcard / multi-SAN cert, or one private key
// deployed behind several proxy names, satisfies the pin at a different host,
// and URLSession may reuse a connection or a trust decision without raising a
// fresh challenge at all. The contract to give users is "point Conduck at the
// TERMINAL gateway URL, never at a redirector" (`spec.md`, Remote Agent
// Round-Trip → Redirect policy). Rationale in full on
// `RemoteAgentTrustEvaluator.converseTaskPin(for:metadata:)`.
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
    /// across multiple `didReceive data:` callbacks). Bounded by
    /// `Constants.maxBackgroundResponseBytes` — see `overCapTaskIDs`.
    private var responseBuffers: [Int: Data] = [:]

    /// Task identifiers whose server-trust challenge THIS delegate cancelled —
    /// a pinned-cert mismatch, or a cross-host hop that could not present the
    /// pinned key. Written by the task-level trust handler, consumed by
    /// `didCompleteWithError`.
    ///
    /// WHY it has to exist: URLSession reports a cancelled challenge as
    /// `URLError.cancelled` (-999), byte-identical to the user tapping Cancel,
    /// and this long-lived shared session cannot read the per-challenge
    /// evaluator instance the way the foreground hop does
    /// (`RemoteAgentClient.mapTransportError`). Without the note, a user under
    /// active MITM saw a plain "tap to retry" chip instead of an
    /// untrusted-certificate failure — the connection was refused either way, so
    /// this closes a LABELLING gap, not a hole in the trust boundary.
    ///
    /// Confined to `queue` (the delegate queue's `underlyingQueue`), so it is
    /// mutated with `queue.async` and NEVER `queue.sync` — the delegate
    /// callbacks already execute on `queue` and a sync hop would deadlock.
    /// Cross-launch resume needs nothing: the set is empty in the new process and
    /// `entry == nil`, which already takes the resurrected-task failure path.
    private var pinRejectedTaskIDs = Set<Int>()

    /// Task identifiers whose response body exceeded
    /// `Constants.maxBackgroundResponseBytes` and were cancelled for it. Same
    /// registry pattern as `pinRejectedTaskIDs`, for the same reason: a bare
    /// `task.cancel()` is indistinguishable from a user cancel, which would
    /// abort the turn with a Retry chip and NO error surfaced anywhere.
    /// Queue-confined.
    private var overCapTaskIDs = Set<Int>()

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
        // Exact configured lane that owns any storedKeys/history references on
        // this request. Unlike `fileTransferSnapshot` below, it need not be
        // READY: an existing blob remains usable after a failed re-test. It is
        // still revalidated against the raw saved tuple immediately before
        // enqueue so A-owned refs can never leak through replacement lane B.
        inputFileTransferSnapshot: SettingsManager.FileTransferSnapshot?,
        // Exact READY physical lane captured by the caller for THIS dispatch.
        // Nil means the file-delivery instruction is omitted and the reply has
        // no explicit output-scan lane. Never resolve a replacement here.
        fileTransferSnapshot: SettingsManager.FileTransferSnapshot?,
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

        // The caller captures ONE READY lane and threads it through. Re-resolving
        // by ref here could silently jump from lane A (which owns handed-off
        // storedKeys) to a newly configured lane B.
        let fileServerReady = fileTransferSnapshot != nil

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
            requestHadHistoryImages: ConverseRequest.containsImageParts(priorTurns),
            fileTransferLaneID: fileTransferSnapshot?.durableLaneID
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

        // Revalidate both independent lane roles immediately before task
        // creation. Existing-input ownership uses the raw configured snapshot;
        // new output promises require the still-READY snapshot. Neither may
        // jump to a replacement lane.
        if let inputFileTransferSnapshot {
            let current = await SettingsManager.shared.fileTransferSnapshot(for: ref)
            guard FileTransferLaneOwnership.samePhysicalLane(
                captured: inputFileTransferSnapshot,
                current: current
            ) else {
                try? FileManager.default.removeItem(at: bodyURL)
                throw AppError.fileTransferNotConfigured
            }
        }
        if let fileTransferSnapshot {
            guard let current = await SettingsManager.shared.fileTransferReadySnapshot(for: ref),
                  current.durableLaneID == fileTransferSnapshot.durableLaneID,
                  current.identitySignature == fileTransferSnapshot.identitySignature else {
                try? FileManager.default.removeItem(at: bodyURL)
                throw AppError.fileTransferNotConfigured
            }
        }

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
            // Already over cap and cancelled — drop straggler chunks the daemon
            // had already queued (re-accumulating them would defeat the cap).
            guard !self.overCapTaskIDs.contains(id) else { return }

            // BOUNDED accumulate. The body is gateway-controlled and was
            // previously appended with no ceiling at all, so a fabricated
            // multi-hundred-MB answer grew this dictionary until the OS jetsammed
            // the app. The verdict is recorded BEFORE `cancel()` so
            // `didCompleteWithError` can tell it from a user cancel, and the
            // partial buffer is dropped (it can never decode, and holding it
            // wastes exactly the memory we just refused to grow).
            let buffered = self.responseBuffers[id]?.count ?? 0
            guard buffered + data.count <= Constants.maxBackgroundResponseBytes else {
                self.overCapTaskIDs.insert(id)
                self.responseBuffers[id] = Data()
                dataTask.cancel()
                return
            }
            // Subscript-with-default `_modify` keeps the append in place; copying
            // the value out and back would make accumulation quadratic.
            self.responseBuffers[id, default: Data()].append(data)
        }
    }

    /// TASK-level server-trust challenge handler — per-ref pinning for the
    /// converse hop. The shared background session can carry concurrent turns to
    /// different gateways, so the pin MUST be resolved per task: recover the
    /// turn's `refRawValue` from `taskDescription` and look up that ref's pin
    /// LIVE from App-Group defaults. nil → default ATS (unpinned gateway, or a
    /// built-in/custom on a publicly-trusted cert). Mirrors
    /// `STTClient+Background`'s task-level trust handler. NOTE: a session-level
    /// `urlSession(_:didReceive:)` would take precedence, so it is intentionally
    /// absent — only this task-level handler exists.
    ///
    /// The resolved pin is applied HOST-BLIND, by design — rationale and honest
    /// limits on `converseTaskPin(for:metadata:)`. A background session always
    /// follows redirects and never delivers `willPerformHTTPRedirection`, so this
    /// callback is the only point at which a cross-host hop can be pushed back on.
    ///
    /// A cancelled challenge — pin mismatch OR a refused cross-host hop — reaches
    /// `didCompleteWithError` as `URLError.cancelled`, which is byte-identical to
    /// a user cancel. It is told apart by `pinRejectedTaskIDs`, noted here and
    /// consulted BEFORE that disambiguation, because this long-lived shared
    /// session cannot read the per-challenge evaluator instance the foreground
    /// hop reads.
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
        let taskID = task.taskIdentifier
        evaluator.urlSession(session, didReceive: challenge) { disposition, credential in
            // The evaluator answers `.cancelAuthenticationChallenge` ONLY on a
            // pinned-cert mismatch (or an SPKI it could not extract under a
            // configured pin), and it is reached only when a pin was recovered —
            // so a cancel HERE is a pin rejection, full stop. Noted BEFORE the
            // handler is forwarded so the record is in place by the time
            // URLSession reports the resulting `.cancelled`.
            if disposition == .cancelAuthenticationChallenge {
                self.queue.async { self.pinRejectedTaskIDs.insert(taskID) }
            }
            completionHandler(disposition, credential)
        }
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

            // Consume both per-task delegate notes. Each records a reason THIS
            // delegate cancelled the task, and both surface as `.cancelled` — so
            // they must be read before the user-cancel disambiguation below, and
            // removed on every exit path so the sets cannot grow.
            let pinRejected = self.pinRejectedTaskIDs.remove(id) != nil
            let responseOverCap = self.overCapTaskIDs.remove(id) != nil

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
                    // OUR over-cap cancel (`didReceive data:`) — a body past
                    // `Constants.maxBackgroundResponseBytes`, i.e. a peer
                    // fabricating a response, not a user abort. Surfaced as the
                    // ordinary invalid-response failure so the turn gets the
                    // normal Retry affordance instead of aborting silently.
                    if responseOverCap {
                        resolve(.failure(AppError.remoteAgentInvalidResponse))
                        if let cid = conversationID {
                            self.postTurnFailed(conversationID: cid, userMessageID: userMessageID, error: .remoteAgentInvalidResponse, notifyUser: notifyUserOnFailure)
                        }
                        return
                    }
                    // OUR pin rejection (the task-level trust handler cancelled
                    // the challenge). Classification is delegated to the ONE
                    // shared classifier the foreground hop uses, so the two
                    // converse lanes can never drift on what counts as a
                    // certificate failure. With `pinRejected == false` the
                    // classifier returns `.cancelled` and nothing below changes —
                    // the user-cancel arm is deliberately NOT broadened.
                    if pinRejected,
                       RemoteAgentTrustEvaluator.classifyTransportError(
                           urlError.code,
                           hasPin: true,
                           systemTrustRejected: false,
                           pinRejected: true
                       ) == .certMismatch {
                        resolve(.failure(AppError.remoteAgentCertMismatch))
                        if let cid = conversationID {
                            self.postTurnFailed(conversationID: cid, userMessageID: userMessageID, error: .remoteAgentCertMismatch, notifyUser: notifyUserOnFailure)
                        }
                        return
                    }
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

            // Persist the agent reply before resolving an awaiting in-app
            // success. `recordReply` invokes `didPersist` immediately after its
            // atomic reply-insert + user-sent transaction; optional output
            // probes continue afterward and do not hold the UI hostage.
            // Runs even for headless relaunches (no awaiting continuation).
            // Counted as persistence work so `handleBackgroundEvents()` holds
            // the `.backgroundTask` closure open until the append lands.
            // `.remoteAgentTurnDidComplete` only fires when the reply actually
            // persisted (recordReply returns false on an append failure —
            // announcing completion for a reply that isn't there would lie).
            guard let cid = conversationID else {
                resolve(.failure(AppError.remoteAgentInvalidResponse))
                return
            }
            self.beginPersistenceWork()
            Task {
                // `recordReply` is the SINGLE success writer. The callback
                // resumes the live continuation only after the atomic store
                // transaction has landed; a failed append returns false and
                // leaves the caller on the ordinary failure path.
                let persisted = await Self.recordReply(
                    reply,
                    conversationID: cid,
                    backendRawValue: metadata?.backendRawValue,
                    userMessageID: userMessageID,
                    stampsActiveConversation: metadata?.stampsActiveConversation ?? false,
                    fileTransferLaneID: metadata?.fileTransferLaneID,
                    didPersist: {
                        resolve(.success(reply))
                    }
                )
                if !persisted {
                    resolve(.failure(AppError.remoteAgentInvalidResponse))
                }
                self.endPersistenceWork()
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
    static func recordReply(
        _ reply: String,
        conversationID: UUID,
        backendRawValue: String?,
        userMessageID: UUID?,
        stampsActiveConversation: Bool,
        fileTransferLaneID: String? = nil,
        didPersist: (() -> Void)? = nil
    ) async -> Bool {
        let agentMessageID = UUID()
        let ownsOutputClaim = fileTransferLaneID != nil
            ? OutputScanClaimRegistry.shared.claim(agentMessageID)
            : false
        defer {
            if ownsOutputClaim {
                OutputScanClaimRegistry.shared.release(agentMessageID)
            }
        }
        // Persist the reply + exact user sent-flip + explicit output-scan lane
        // in ONE Core Data transaction whenever modern metadata identifies the
        // user turn. A process death can therefore never expose a sent user
        // bubble without its reply, or a reply whose recovery lane was lost.
        let appended: MessageRecord
        if let userMessageID {
            guard let completed = try? await ConversationStore.shared.completeAgentTurn(
                userMessageID: userMessageID,
                userStatus: "sent",
                agentText: reply,
                conversationID: conversationID,
                sourceDevice: SourceDevice.current,
                agentMessageID: agentMessageID,
                outputScanLaneID: fileTransferLaneID
            ) else {
                return false
            }
            appended = completed
        } else {
            // Backward compatibility for an in-flight pre-upgrade task whose
            // metadata has no exact user id. Preserve the legacy append then
            // conversation-wide status transition; no explicit lane can be
            // trusted for this old shape.
            guard let legacy = try? await ConversationStore.shared.appendMessage(
                role: "agent",
                text: reply,
                conversationID: conversationID,
                sourceDevice: SourceDevice.current
            ) else {
                return false
            }
            appended = legacy
            await ConversationStore.shared.markPendingUserTurns(
                conversationID: conversationID,
                to: "sent"
            )
        }
        // The durable reply + success transition now exist together. Release
        // an awaiting foreground caller here, before optional output probes.
        didPersist?()
        if stampsActiveConversation {
            await SettingsManager.shared.recordActiveConversation(conversationID)
        }

        // Resolve the true ref once for both exact-lane output recovery and the
        // notification title. New metadata may probe ONLY the currently READY
        // snapshot whose durable id matches the dispatch. Legacy nil metadata
        // does zero landing-path probing and remains ineligible for retroactive
        // network scans because its physical owner cannot be proven.
        let refRawString = (try? await ConversationStore.shared
            .fetchConversation(id: conversationID))?.backend ?? backendRawValue
        let ref = refRawString.flatMap(RemoteAgentRef.init(rawString:))

        // User-visible completion is released immediately after durable landing.
        // Output probes are optional recovery work and must never delay the
        // notification/menu-bar completion signal by their timeout budget.
        await Self.finishRecordedReply(
            reply,
            conversationID: conversationID,
            backendRawValue: refRawString
        )

        var outputs: [AttachmentDraft] = []
        var outputSnapshot: SettingsManager.FileTransferSnapshot?
        if let fileTransferLaneID, ownsOutputClaim {
            let hasCandidates =
                !(await FileTransferOutputDetector.extractCandidatesOffMainActor(from: reply)).isEmpty
            if !hasCandidates {
                _ = try? await ConversationStore.shared.reconcileOutputScan([
                    .init(
                        messageID: appended.id,
                        drafts: [],
                        markScanned: true,
                        expectedLaneID: fileTransferLaneID
                    )
                ])
            } else if let ref,
                      let captured = await SettingsManager.shared
                        .fileTransferReadySnapshot(for: ref),
                      captured.durableLaneID == fileTransferLaneID {
                let scan = await FileTransferOutputDetector.reconciliationScan(
                    reply: reply,
                    conversationID: conversationID,
                    snapshot: captured,
                    excludedKeys: []
                )
                guard let current = await SettingsManager.shared
                    .fileTransferReadySnapshot(for: ref),
                      current.durableLaneID == fileTransferLaneID else {
                    // Leave the explicit pending marker untouched. Restoring the
                    // original lane lets the same VM recover without probing B.
                    return true
                }
                outputs = scan.drafts
                outputSnapshot = captured
                _ = try? await ConversationStore.shared.reconcileOutputScan([
                    .init(
                        messageID: appended.id,
                        drafts: outputs,
                        markScanned: scan.conclusive,
                        expectedLaneID: fileTransferLaneID
                    )
                ])
            }
        }

        // Preview enrichment is pinned to the same exact captured lane when
        // modern metadata exists; it may never re-resolve a replacement.
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
            if let ref, let outputSnapshot {
                Task.detached {
                    await FileTransferOutputDetector.enrichPreviews(
                        drafts: outputs,
                        messageID: outputMessageID,
                        ref: ref,
                        snapshot: outputSnapshot
                    )
                }
            }
        }
        return true
    }

    private static func finishRecordedReply(
        _ reply: String,
        conversationID: UUID,
        backendRawValue: String?
    ) async {
        await Self.postReplyNotification(
            reply,
            conversationID: conversationID,
            backendRawValue: backendRawValue
        )
        await Self.postTurnCompleted(conversationID: conversationID)
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
/// for the small allowlisted subset, probes the user's file-server to see whether
/// a file by that name EXISTS in the served folder. Each confirmed file becomes a
/// server-reference `AttachmentDraft` on the AGENT bubble, which the thread
/// renders as an inline download chip; tapping the chip downloads the full file,
/// and `enrichPreviews` separately pulls a BOUNDED preview with no user action
/// (that is what makes an output viewable on the wrist).
///
/// WHAT THE PROBE PROVES — read this before trusting a chip. It proves EXISTENCE
/// at the served root, NOT AUTHORSHIP. The probe key is the filename the reply
/// text named, used verbatim (`snapshot.baseURL` + key), and nothing requires the
/// agent to have written it, or to have written it THIS turn:
///   - A reply naming any pre-existing file at the served root gets a chip for it.
///     Since the setup guidance tells the user to serve the AGENT'S WORKSPACE, that
///     includes their own working files, and `fileDeliveryInstruction` actively
///     trains agents to name files in prose — so a completely benign reply
///     ("I read your config.yaml") trips this routinely. The dominant real-world
///     symptom is a stray chip plus an unwanted preview, not an attack.
///   - Consequence to keep in view: a fabricated claim ("I've updated your
///     budget.csv") LOOKS verified, and up to a bounded slice of a non-output
///     workspace file is copied into the conversation store — i.e. into the user's
///     own iCloud and onto their Watch — with no tap. Everything stays inside the
///     user's trust domain (their device, their iCloud, their server, their
///     credential) and no content ever reaches the gateway: a detector-minted
///     draft is always `isServerReference`, and the wire splice carries only
///     `isText` attachments.
///   - A freshness gate (`Last-Modified` newer than the dispatching turn) was
///     considered and REJECTED: it contradicts the deliberate re-mention rule
///     below, it makes chip creation depend on clock agreement with a BYO
///     rclone/Caddy/nginx/NAS host (a silent-failure mode this file avoids
///     everywhere else — see `probeIsConclusive`), and it stops nothing, because
///     any agent with filesystem write can refresh an mtime.
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
///     a name the model INVENTED yields nothing. A name that happens to match a
///     real file at the served root DOES chip, whoever wrote it (see "WHAT THE
///     PROBE PROVES" above); the regex cannot emit `/`, so probes are confined to
///     the configured root — no traversal, and no reach into another
///     conversation's `<conversationID>/` upload namespace.
///   - When the bound gateway has NO file-server configured, the detector
///     returns `[]` IMMEDIATELY (zero probes) — the common case stays free.
///
/// PRIVACY (see the spec's Privacy & Security section): never logs the reply text,
/// candidate filenames, storedKeys, or the snapshot. Returns the structured
/// drafts; no `print`/`os_log` anywhere in this path.
enum FileTransferOutputDetector {
    struct ReconciliationScan {
        let drafts: [AttachmentDraft]
        let conclusive: Bool
    }

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

    /// True only while the ref still resolves to the exact lane captured by a
    /// dispatch/probe caller. The stable ID binds URL + credential across
    /// launches; the per-process signature additionally catches device-local
    /// pin changes during this run. Readiness/capability verdict changes do not
    /// repoint an already-dispatched file lane.
    static func configuredLaneStillMatches(
        ref: RemoteAgentRef,
        snapshot: SettingsManager.FileTransferSnapshot
    ) async -> Bool {
        guard let current = await SettingsManager.shared.fileTransferSnapshot(for: ref) else {
            return false
        }
        return current.durableLaneID == snapshot.durableLaneID
            && current.identitySignature == snapshot.identitySignature
    }

    /// Run a reconciliation scan against a caller-captured lane. This overload
    /// never resolves settings and therefore cannot silently jump from dispatch
    /// lane A to a later lane B. The caller owns pre/post identity guards.
    static func reconciliationScan(
        reply: String,
        conversationID: UUID,
        snapshot: SettingsManager.FileTransferSnapshot,
        excludedKeys: Set<String>
    ) async -> ReconciliationScan {
        guard !(await extractCandidatesOffMainActor(from: reply)).isEmpty else {
            return ReconciliationScan(drafts: [], conclusive: true)
        }
        let inbound = await inboundStoredKeyTokens(conversationID: conversationID)
        let result = await detect(
            reply: reply,
            snapshot: snapshot,
            inboundTokens: inbound,
            excludedKeys: excludedKeys
        )
        return ReconciliationScan(drafts: result.drafts, conclusive: result.conclusive)
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
        let candidates = await extractCandidatesOffMainActor(from: reply)
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
    ///
    /// COST — LOAD-BEARING (untrusted input): the pattern's `[A-Za-z0-9._-]+` is
    /// followed by a required `\.` that the class itself can match, so ICU
    /// backtracks O(n) per start position over O(n) start positions on a long
    /// unbroken run of those characters — quadratic (measured, `swiftc -O`
    /// arm64: 8 KB → 0.49 s, 16 KB → 1.95 s, 32 KB → 7.81 s, i.e. 4× input =
    /// 16× time). Reply text is adversary-controlled (a hostile gateway, or an
    /// honest agent prompt-injected by a page it read) and bounded only by the
    /// 16 MiB `Constants.maxBackgroundResponseBytes` transport ceiling, and the
    /// retro pass re-runs this over up to `retroScanCap` replies on EVERY thread
    /// open — so one poisoned reply, persisted and CloudKit-synced, otherwise
    /// burns CPU forever on every device (extrapolated: ~24 days at 16 MiB).
    /// Moving it off the main actor (`extractCandidatesOffMainActor`, still
    /// required) only relocates that; `boundedRunInput` is what BOUNDS it, to
    /// linear (measured 2.2 s/MiB in its worst SURVIVING shape).
    ///
    /// The pattern itself and the UNCAPPED contract stay deliberately unchanged:
    /// a bounded quantifier would alter match EXTENT, and a truncated token
    /// becomes the `storedKey` whose probe returns `.missing`, which is
    /// conclusive — i.e. it would stamp the turn scanned and lose a real output
    /// file forever. Capping the input length would lose a filename mentioned
    /// past the cap the same way. The bound is on input SHAPE instead, which
    /// costs no real candidate at all — see `boundedRunInput`.
    ///
    /// `nonisolated` so the off-actor wrapper can reach it (the app module
    /// defaults declarations to `@MainActor`).
    nonisolated static func extractCandidates(from reply: String) -> [String] {
        // `name.ext` where name is a safe token and ext is 1–8 alnum chars. The
        // allowlist filter below is what actually defeats prose false-positives;
        // the regex just enumerates filename-shaped tokens.
        let pattern = "[A-Za-z0-9._-]+\\.[A-Za-z0-9]{1,8}"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let scanned = boundedRunInput(reply)
        let range = NSRange(scanned.startIndex..<scanned.endIndex, in: scanned)

        var seen = Set<String>()
        var ordered: [String] = []
        for match in regex.matches(in: scanned, range: range) {
            guard let r = Range(match.range, in: scanned) else { continue }
            let token = String(scanned[r])
            guard let dot = token.lastIndex(of: ".") else { continue }
            let ext = token[token.index(after: dot)...].lowercased()
            guard outputAllowlist.contains(ext) else { continue }
            if seen.insert(token).inserted {
                ordered.append(token)
            }
        }
        return ordered
    }

    /// Longest run of `[A-Za-z0-9._-]` scalars `boundedRunInput` lets through.
    /// 255 is POSIX `NAME_MAX` — the byte ceiling on a filename on every server
    /// this app can talk to — so no run this bound drops could have held a
    /// storable name. That is what makes the bound free: it is not a guess at
    /// "how long a filename might be", it is the limit past which one cannot
    /// exist.
    nonisolated static let maxFilenameRunScalars = 255

    /// Replace every `[A-Za-z0-9._-]` run longer than `maxFilenameRunScalars`
    /// with a single space, leaving everything else byte-identical. Returns the
    /// input UNCHANGED (no copy) when no run is over budget — the case for every
    /// real reply, so real content pays one linear scan and nothing else.
    ///
    /// WHY this bound and not a length cap: the pattern's cost is quadratic in
    /// the length of ONE unbroken run, not in the reply, and a match can never
    /// span a run boundary (every character the pattern can match is in that
    /// class). Excising the over-long runs therefore turns the whole scan linear
    /// — measured `swiftc -O` arm64: 4 MiB of `a` + a real `report.pdf` goes
    /// from hours of backtracking to 0.008 s, and STILL returns `report.pdf`.
    ///
    /// WHY it loses nothing: a match starts at its run's start (the greedy `+`
    /// consumes to the run end, then backtracks to the last usable dot), so a
    /// name buried inside a longer run was never extractable in the first place
    /// — the token was the whole run. The only candidate an over-budget run can
    /// yield is therefore a >255-character token, which no file-server can hold
    /// and whose probe is a guaranteed `.missing`. A single space, not deletion,
    /// so two runs either side of an excision cannot fuse into a token that was
    /// never in the reply.
    ///
    /// RESIDUAL (accepted, and now LINEAR): a reply built entirely of maximal
    /// in-budget runs still costs ~2.2 s/MiB. Its input term is bounded at the
    /// transport layer by `Constants.maxBackgroundResponseBytes`, and this runs
    /// off the main actor, so the worst case is background CPU proportional to a
    /// body the peer already had to send — not the unbounded quadratic blow-up.
    ///
    /// Internal (not private) so the equivalence + cost contract is testable.
    nonisolated static func boundedRunInput(_ reply: String) -> String {
        func isTokenScalar(_ scalar: Unicode.Scalar) -> Bool {
            switch scalar {
            case "A"..."Z", "a"..."z", "0"..."9", ".", "_", "-": return true
            default: return false
            }
        }

        let scalars = reply.unicodeScalars
        // nil until the first over-budget run — the no-copy fast path.
        var excised: String?
        var copiedUpTo = scalars.startIndex
        var runStart = scalars.startIndex
        var runLength = 0

        func flushRun(endingAt runEnd: String.UnicodeScalarView.Index) {
            guard runLength > maxFilenameRunScalars else { return }
            if excised == nil { excised = "" }
            excised?.unicodeScalars.append(contentsOf: scalars[copiedUpTo..<runStart])
            excised?.unicodeScalars.append(" ")
            copiedUpTo = runEnd
        }

        var index = scalars.startIndex
        while index < scalars.endIndex {
            if isTokenScalar(scalars[index]) {
                if runLength == 0 { runStart = index }
                runLength += 1
            } else {
                flushRun(endingAt: index)
                runLength = 0
            }
            index = scalars.index(after: index)
        }
        flushRun(endingAt: scalars.endIndex)

        guard var excised else { return reply }
        excised.unicodeScalars.append(contentsOf: scalars[copiedUpTo...])
        return excised
    }

    /// `extractCandidates` on a detached executor — the ONE entry point every
    /// production caller uses. `detect` / `reconciliationScan` /
    /// `ConversationDetailViewModel.retroOutputScanRoute` are all MainActor
    /// (module default), and the retro pass runs the extraction over up to
    /// `retroScanCap` replies on every thread open, so calling it inline froze
    /// the UI for as long as the pattern took on a hostile reply. Detached (not
    /// merely `nonisolated`): a nonisolated sync function still executes on the
    /// caller's thread. Cheap to hop because the function is pure and
    /// content-free — it takes a `String` and returns tokens, touching no state.
    nonisolated static func extractCandidatesOffMainActor(from reply: String) async -> [String] {
        await Task.detached(priority: .utility) {
            extractCandidates(from: reply)
        }.value
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

    /// Preview enrichment pinned to the exact dispatch-time lane. There is no
    /// ownerless/current-lane fallback: a replacement gateway must never receive
    /// output-key reads from an earlier physical lane.
    nonisolated static func enrichPreviews(
        drafts: [AttachmentDraft],
        messageID: UUID,
        ref: RemoteAgentRef,
        snapshot: SettingsManager.FileTransferSnapshot
    ) async {
        guard !drafts.isEmpty,
              await configuredLaneStillMatches(ref: ref, snapshot: snapshot) else {
            return
        }
        var sourceBudget = perReplyPreviewSourceBudget
        var storedBudget = perReplyPreviewStoredBudget
        let patches = await buildPreviewPatches(
            for: drafts,
            messageID: messageID,
            snapshot: snapshot,
            sourceBudget: &sourceBudget,
            storedBudget: &storedBudget
        )
        guard !patches.isEmpty,
              await configuredLaneStillMatches(ref: ref, snapshot: snapshot) else {
            return
        }
        _ = try? await ConversationStore.shared.applyPreviews(patches)
    }
}
