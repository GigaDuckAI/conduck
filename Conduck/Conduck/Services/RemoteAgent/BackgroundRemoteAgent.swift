// SPDX-License-Identifier: Apache-2.0

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
        /// Set by `cancel(conversationID:)` — i.e. WE asked for this task to
        /// stop. `URLError.cancelled` (-999) is reported identically whether the
        /// client cancelled or the peer reset the stream, so this flag is the
        /// only thing that tells the two apart on this lane.
        var cancelRequested = false
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
    /// Cross-launch resume needs nothing: the registry is empty in the new process and
    /// `entry == nil`, which already takes the resurrected-task failure path.
    /// Stores the WHOLE `AttemptTrustSignals` snapshot per task rather than a
    /// verdict per set: "untrusted certificate", "pinned key mismatch" and "key
    /// Conduck cannot fingerprint" are three verdicts with three remedies, and
    /// splitting them across sets both invites pairing one task's verdict with
    /// another's and drops `pinComparisonUnsupported` — the only thing that
    /// separates the third from an interception warning.
    private var trustSignalsByTaskID: [Int: RemoteAgentTrustEvaluator.AttemptTrustSignals] = [:]

    /// Task identifiers whose response body exceeded
    /// `Constants.maxBackgroundResponseBytes` and were cancelled for it. Same
    /// registry pattern as `trustSignalsByTaskID`, for the same reason: a bare
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
        // Count of this turn's server files whose bytes this dispatch cannot
        // reach (cross-lane clone) — see `RemoteAgentClient.assembleMessages`.
        // Threaded here too: on iOS the clone's auto-continuation dispatches
        // through the background session, so omitting it would drop the
        // disclosure on exactly the surface the reported bug happened on.
        newUserUnavailableFileCount: Int = 0,
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
                newUserUnavailableFileCount: newUserUnavailableFileCount,
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
            fileTransferLaneID: fileTransferSnapshot?.durableLaneID,
            // Dispatch-time fact for the SUCCESS record, by the same argument as
            // the line above: the delegate may land this reply after a relaunch,
            // and by then the live config may be a different gateway entirely.
            // Built from THIS request's own url/scheme/model — the values baked
            // into `request` above — not from a fresh settings read, which would
            // describe whatever the user edited to while the body was encoding.
            dispatchChatSignature: await SettingsManager.shared.gatewayChatSuccessSignature(
                for: ref, url: url, authScheme: authScheme, model: model
            )
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
            // Record the INTENT before asking the task to stop. The delegate
            // cannot otherwise tell our cancel from a peer-side stream reset,
            // and calling a reset a "cancel" suppresses the classification the
            // user needs — see the `.cancelled` branch in `didCompleteWithError`.
            self.inFlight[entry.taskIdentifier]?.cancelRequested = true
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
    /// A cancelled challenge — untrusted chain, pin mismatch, or a refused
    /// cross-host hop — reaches `didCompleteWithError` as `URLError.cancelled`,
    /// which is byte-identical to a user cancel. It is told apart by
    /// `trustSignalsByTaskID`, noted here and
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
        // A non-nil pin was recovered → enforce it ON TOP of system trust
        // (system rejects the chain → cancel; match → useCredential; mismatch →
        // cancel). Both the evaluation and the compare are delegated to the
        // generic evaluator.
        let evaluator = RemoteAgentTrustEvaluator(pinnedFingerprintHex: pin)
        let taskID = task.taskIdentifier
        evaluator.urlSession(session, didReceive: challenge) { disposition, credential in
            // Record the evaluator's OWN verdicts rather than inferring from the
            // disposition: a cancel here can mean either "this device does not
            // trust the chain" or "the pinned key did not match", and the two
            // must not be collapsed. Noted BEFORE the handler is forwarded so
            // the record is in place by the time URLSession reports the
            // resulting `.cancelled`.
            let signals = evaluator.attemptSignals
            if signals != .empty {
                self.queue.async { self.trustSignalsByTaskID[taskID] = signals }
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

            // Consume every per-task delegate note. Each records a reason THIS
            // delegate cancelled the task, and all of them surface as
            // `.cancelled` — so they must be read before the user-cancel
            // disambiguation below, and removed on every exit path so the sets
            // cannot grow.
            let trustSignals = self.trustSignalsByTaskID.removeValue(forKey: id) ?? .empty
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
                    // OUR certificate refusal (the task-level trust handler
                    // cancelled the challenge) — either an untrusted chain or a
                    // pinned-key mismatch. Classification is delegated to the ONE
                    // shared classifier the foreground hop uses, so the two
                    // converse lanes can never drift on what counts as a
                    // certificate failure. With no verdict recorded the classifier
                    // returns `.cancelled` and nothing below changes — the
                    // user-cancel arm is deliberately NOT broadened. The two
                    // classes stay APART: an untrusted chain is fixed on the
                    // server, a pin mismatch in Settings. Neither is retryable.
                    if trustSignals != .empty {
                        let certError: AppError?
                        switch RemoteAgentTrustEvaluator.classifyTransportError(
                            urlError.code,
                            signals: trustSignals
                        ) {
                        case .untrustedCert: certError = .remoteAgentCertUntrusted
                        case .certMismatch: certError = .remoteAgentCertMismatch
                        // Third class, kept apart from both: system trust
                        // passed and the pin was never compared, so neither a
                        // server fix nor an interception warning applies.
                        case .certKeyUnpinnable: certError = .remoteAgentCertKeyUnpinnable
                        case .timeout, .unreachable, .notEstablished, .offline, .cancelled: certError = nil
                        }
                        if let certError {
                            resolve(.failure(certError))
                            if let cid = conversationID {
                                self.postTurnFailed(conversationID: cid, userMessageID: userMessageID, error: certError, notifyUser: notifyUserOnFailure)
                            }
                            return
                        }
                    }
                    if urlError.code == .cancelled {
                        // -999 is THREE different events on this lane, and the
                        // wire cannot tell them apart. The registry can:
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
                        //
                        // entry PRESENT + `cancelRequested` → a live in-process
                        // cancel (user tapped Stop / session teardown). No agent
                        // bubble, no notification, NO `.remoteAgentTurnDidFail`
                        // post — but the cancelled turn itself flips to `failed`
                        // (below); the in-app caller's continuation receives
                        // `CancellationError`.
                        //
                        // entry PRESENT + NOT `cancelRequested` → nobody here
                        // asked for this. The PEER reset the stream mid-request
                        // (an HTTP/2 RST_STREAM from the gateway or something in
                        // front of it), which URLSession also reports as -999.
                        // Presence alone used to be read as "the user cancelled",
                        // which is the worst available answer: a cancel writes NO
                        // classification, so a genuine gateway failure rendered
                        // as the bare "wasn't delivered" with no cause, no
                        // Troubleshoot link and no Diagnostics record. Classify
                        // it as the transport failure it is.
                        if entry == nil {
                            if let cid = conversationID {
                                self.postTurnFailed(conversationID: cid, userMessageID: userMessageID, error: nil, notifyUser: true)
                            }
                            return
                        }
                        if entry?.cancelRequested != true {
                            let peerReset = AppError.remoteAgentUnreachable
                            if let cid = conversationID {
                                self.postTurnFailed(conversationID: cid, userMessageID: userMessageID, error: peerReset, notifyUser: notifyUserOnFailure)
                            }
                            resolve(.failure(peerReset))
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
                    dispatchChatSignature: metadata?.dispatchChatSignature,
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

    /// Internal, not private: `CarPlayConverseUploader` runs its own background
    /// session and must reach the SAME transport taxonomy. A second copy there
    /// is how the CarPlay lane drifted to a blanket `.remoteAgentUnreachable`
    /// for every non-certificate transport failure in the first place.
    static func mapURLError(_ error: URLError) -> AppError {
        switch error.code {
        case .timedOut:
            return .remoteAgentTimeout
        // Kept in lockstep with `RemoteAgentTrustEvaluator.classifyTransportError`'s
        // arms of the same names — this duplicate exists because a background
        // session's completion callback cannot read the evaluator's per-challenge
        // signals, not because the transport taxonomy differs. Change both.
        case .notConnectedToInternet:
            return .noInternetConnection
        case .cannotConnectToHost,
             .cannotFindHost,
             .dnsLookupFailed:
            return .remoteAgentNotEstablished
        case .networkConnectionLost,
             .resourceUnavailable:
            return .remoteAgentUnreachable
        case .serverCertificateUntrusted,
             .serverCertificateHasBadDate,
             .serverCertificateHasUnknownRoot,
             .serverCertificateNotYetValid:
            // The SYSTEM named the certificate as the cause and refused the
            // chain before any pin could apply — untrusted, not a mismatch. A
            // genuine pin mismatch reaches the caller with `pinRejected` set and
            // is classified there; this arm has no per-challenge signals to
            // read, so it must not claim a fingerprint disagreed.
            return .remoteAgentCertUntrusted
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
        /// Gateway config signature captured at DISPATCH (from the task
        /// metadata). nil = unknown / pre-upgrade blob → no success recorded,
        /// which is the fail-closed direction.
        dispatchChatSignature: String? = nil,
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

        // "Chat works from this device, under this config." Written only now —
        // the reply is decoded AND durably persisted, so the claim can never
        // outlive the turn backing it. The signature is the DISPATCH-time one
        // carried in the task metadata (this reply may be landing after a
        // relaunch); the setter drops it if the live config has since moved.
        if let ref, let dispatchChatSignature {
            await SettingsManager.shared.recordGatewayChatSuccess(
                for: ref,
                dispatchSignature: dispatchChatSignature
            )
        }

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
                // The landing probe fires within milliseconds of the reply, so
                // it is inside the turn's grace window by construction: it
                // attaches whatever already exists, and leaves the turn PENDING
                // rather than closing it on a 404 the file may be one second
                // away from disproving. A later thread open finishes the job.
                let scan = await FileTransferOutputDetector.reconciliationScan(
                    reply: reply,
                    conversationID: conversationID,
                    snapshot: captured,
                    excludedKeys: [],
                    turnCreatedAt: appended.createdAt
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
        content.title = failureNotificationTitle(for: error)
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
        // The certificate verdicts carry their REMEDY into the notification.
        // This is a headless turn: the user was not watching, so this push may
        // be the only place the verdict is read for hours. The cause alone
        // leaves an untrusted chain with no server-side fix to act on, and
        // strips the "may be intercepted" warning off a pin mismatch — that
        // sentence lives entirely in the remedy half. On an unpinnable key the
        // remedy carries the whole reassurance ("the certificate itself is fine
        // and this device trusts it"), so the cause alone reads as a server
        // fault the user would go hunting at whatever hour the push arrives.
        case .some(let appError) where Self.isCertificateVerdict(appError):
            content.body = appError.descriptionWithRecovery
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

    /// The failure notification's TITLE, derived from the error rather than
    /// fixed. A constant "Couldn't reach your personal AI" asserts a cause —
    /// the gateway was never reached — for every failure alike, and a
    /// certificate refusal is the case where that assertion does real damage:
    /// the connection DID reach the server, this device rejected what it
    /// presented, and the title sends the user hunting an outage on a machine
    /// that is running perfectly. The three certificate families keep separate
    /// titles for the reason they keep separate copy everywhere else — their
    /// remedies disagree: one is server-side, one is "stop and check", and one
    /// says the server is already correct.
    private static func failureNotificationTitle(for error: AppError?) -> String {
        switch error {
        case .some(.remoteAgentCertUntrusted), .some(.sttCustomCertUntrusted),
             .some(.ttsCustomCertUntrusted), .some(.fileTransferCertUntrusted):
            return String(localized: "remoteAgent.notification.failure.certUntrusted.title",
                          defaultValue: "Certificate not trusted")
        case .some(.remoteAgentCertMismatch), .some(.sttCustomCertMismatch),
             .some(.ttsCustomCertMismatch), .some(.fileTransferCertMismatch):
            return String(localized: "remoteAgent.notification.failure.certMismatch.title",
                          defaultValue: "Certificate doesn't match")
        case .some(.remoteAgentCertKeyUnpinnable), .some(.sttCustomCertKeyUnpinnable),
             .some(.ttsCustomCertKeyUnpinnable), .some(.fileTransferCertKeyUnpinnable):
            // Names the CHECK, never the certificate: this device trusted the
            // chain, so a title implying a bad certificate would contradict the
            // body's "the certificate itself is fine" one line later — and the
            // mismatch title above would announce a disagreement that never
            // happened.
            return String(localized: "remoteAgent.notification.failure.certKeyUnpinnable.title",
                          defaultValue: "Fingerprint can't be checked")
        // The reachability class — the only one the original title was ever
        // true for. `.networkError` / `.decodingError` / `.unknown` belong here
        // because the body above maps them to the unreachable copy, so title
        // and body have to agree.
        case .some(.remoteAgentUnreachable), .some(.remoteAgentTimeout),
             .some(.networkError), .some(.decodingError), .some(.unknown),
             .some(.noInternetConnection), .some(.requestTimeout),
             .some(.persistentNetworkFailure):
            return String(localized: "Couldn't reach your personal AI")  // xcstrings
        default:
            // Everything the gateway ANSWERED — and the nil case, where the
            // cause is unknown and must not be guessed at.
            return String(localized: "remoteAgent.notification.failure.title",
                          defaultValue: "No reply from your personal AI")
        }
    }

    /// The three certificate families across every lane. Grouped ONLY where all
    /// three share a property — here, that the half of their copy a user has to
    /// act on lives in `recoverySuggestion`, so a surface rendering the cause
    /// alone silently drops it. They are never collapsed into one message.
    private static func isCertificateVerdict(_ error: AppError) -> Bool {
        switch error {
        case .remoteAgentCertUntrusted, .sttCustomCertUntrusted,
             .ttsCustomCertUntrusted, .fileTransferCertUntrusted,
             .remoteAgentCertMismatch, .sttCustomCertMismatch,
             .ttsCustomCertMismatch, .fileTransferCertMismatch,
             .remoteAgentCertKeyUnpinnable, .sttCustomCertKeyUnpinnable,
             .ttsCustomCertKeyUnpinnable, .fileTransferCertKeyUnpinnable:
            return true
        default:
            return false
        }
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
///   - Distinct candidates are CAPPED (`maxCandidates`) so a chatty reply can't
///     fan out into dozens of probes against the user's home server, and the
///     first lane-wide probe failure abandons the rest of the turn's window.
///   - A pass that could not examine every eligible candidate, or that ran
///     before the turn's age gate opened, does NOT close the turn — see
///     `outputScanGrace`, `truncatedScanHorizon` and `scanMayClose`. Closing a
///     turn is permanent, so it is reserved for a pass that actually finished.
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

    /// Curated set of output-file extensions worth probing — document / data /
    /// archive / image / audio / code types an agent tool realistically WRITES.
    /// Lowercased for matching.
    ///
    /// THE LIST IS A PROSE-NOISE FILTER, not a MIME registry. The candidate
    /// regex enumerates every `<base>.<ext>` token in the reply; this set is the
    /// only thing standing between ordinary sentences ("e.g.", "v1.1",
    /// "example.com") and a GET against the user's home server. Every entry is
    /// therefore weighed on ONE question: how often does this appear as the tail
    /// of a `<base>.<ext>` token in prose that names no file?
    ///
    /// What a false candidate actually costs, because it bounds how strict this
    /// has to be: ONE ranged GET that returns 404. It can never produce a chip —
    /// the two-source rule needs a real file at the served root with that exact
    /// name. So the filter is tuned to keep NOISE proportionate, not to be
    /// airtight.
    ///
    /// ADMITTED, and why:
    ///   - Audio (`m4a`/`mp3`/`wav`/`flac`/`ogg`/`aac`/`opus`) — a voice-first
    ///     product whose agents synthesise speech and clips had no way to hand
    ///     one back. All are distinctive tails; none occur in prose.
    ///   - `ipynb` / `toml` — unambiguous artifact extensions with zero prose
    ///     shape. `ppt` restores the symmetry `doc`/`xls` already had with their
    ///     modern twins.
    ///   - `rtf` / `epub` — document deliverables a "write this up for me" turn
    ///     genuinely produces.
    ///   - `webp` — a modern raster output format the image set simply lacked;
    ///     it also earns a thumbnail (see `imagePreviewExtensions`).
    ///   - Languages (`go`/`rs`/`rb`/`kt`/`java`/`swift`/`cpp`/`hpp`/`css`/
    ///     `scss`/`tex`/`bat`/`ps1`, on top of the existing `py`/`js`/`ts`/
    ///     `sh`/`sql`) — the showcase gateways are CODING agents, so source
    ///     files are the modal deliverable. Short tails were weighed, not waved
    ///     through: a missing space after a full stop makes `Done.Go` a token,
    ///     so `go` costs occasional 404s. Admitted anyway, because `main.go` is
    ///     one of the most common agent deliverables there is and the cost of
    ///     the noise is a probe that cannot chip.
    ///
    /// REFUSED, and why:
    ///   - ONE-character tails (`c`, `h`, `r`, `m`) — the noise floor of ordinary
    ///     numbered prose ("section 4.c") swamps the signal.
    ///   - `env` — the canonical `.env` cannot match the regex anyway (no base
    ///     before the dot), while ordinary code prose (`process.env`) matches
    ///     every time. All noise, no coverage, and the artifact it would name is
    ///     a secrets file this app must never pull into the conversation store.
    ///   - `db` / `bin` / `dat` — generic, usually pre-existing, and carry no
    ///     evidence that the agent AUTHORED anything (the probe proves existence
    ///     only — see "WHAT THE PROBE PROVES" above).
    ///   - `sqlite` — legitimate but sensitive: accidentally chipping a live
    ///     workspace database is a worse mis-fire than chipping a stray document.
    ///   - Video (`mp4`/`mov`/`webm`) and config (`ini`/`cfg`/`conf`) — widening
    ///     handback to those artifact classes is a product decision, taken
    ///     deliberately or not at all.
    nonisolated static let outputAllowlist: Set<String> = [
        "pdf", "csv", "tsv", "json", "xml", "yaml", "yml", "toml", "txt", "md", "log",
        "zip", "tar", "gz", "png", "jpg", "jpeg", "gif", "svg", "webp",
        "xlsx", "xls", "docx", "doc", "pptx", "ppt", "html", "rtf", "epub",
        "m4a", "mp3", "wav", "flac", "ogg", "aac", "opus",
        "py", "js", "ts", "sh", "sql", "parquet", "ipynb",
        "go", "rs", "rb", "kt", "java", "swift", "cpp", "hpp", "css", "scss",
        "tex", "bat", "ps1"
    ]

    /// Maximum distinct candidates probed per reply — a fan-out budget, so a
    /// chatty reply can't fire dozens of GETs at the user's home server in one
    /// pass. Applied AFTER the inbound / already-chipped filters, so an echoed
    /// name can never displace a real output from the window.
    ///
    /// 10 rather than a handful: with the widened allowlist an honest coding
    /// reply routinely names the half-dozen files it touched BEFORE naming the
    /// deliverable, and a window that a normal reply overflows is a window that
    /// loses real outputs. Ten sequential probes is still a bounded worst case,
    /// and `detect` abandons the whole turn on the first lane-wide failure, so a
    /// dead server costs ONE probe, not ten.
    nonisolated static let maxCandidates = 10

    /// Lifetime ceiling on detector-minted chips for ONE message. Reached ⇒ the
    /// turn closes without probing: nothing further can be added, so further
    /// examination cannot change the outcome.
    ///
    /// This is what makes "a truncated pass stays open" safe. Every pass drops
    /// the keys already chipped on the message before applying `maxCandidates`,
    /// so confirmed files make the probe window WALK FORWARD through a long
    /// candidate list across passes. Without a ceiling, a reply naming hundreds
    /// of files that happen to exist at the served root could walk the whole
    /// list over repeated thread opens — minting unbounded chips and, worse,
    /// re-arming the per-pass preview download budget each time.
    ///
    /// TWICE `maxCandidates`, deliberately: at parity the walk would be an
    /// illusion, because every chip that advances the window's head also shrinks
    /// the remaining allowance that sets its tail, pinning the far end at the
    /// same candidate forever. A ceiling above the per-pass cap is what lets a
    /// long list actually be worked through.
    ///
    /// HOW FAR THE WALK ACTUALLY REACHES, because it bounds what
    /// `probeOrderedCandidates` has to get right. With `c` keys already chipped,
    /// a pass probes `min(maxCandidates, maxOutputChipsPerMessage - c)` further
    /// candidates, so the furthest plan-order position any pass can reach is
    /// `c + min(maxCandidates, maxOutputChipsPerMessage - c)` — maximised at
    /// `c == maxCandidates`, i.e. TWENTY. The reachable prefix is therefore
    /// `maxOutputChipsPerMessage` candidates deep, not the sum of the two
    /// constants, and everything past it is never asked about. That is precisely
    /// why probe ORDER is load-bearing rather than cosmetic.
    nonisolated static let maxOutputChipsPerMessage = maxCandidates * 2

    /// How long after an agent turn was created a probing pass must wait before
    /// it may PERMANENTLY close that turn. Inside the window a scan still
    /// attaches whatever it confirms — chips appear instantly — it just may not
    /// stamp the turn scanned, so a later pass re-probes.
    ///
    /// WHY A GRACE PERIOD AT ALL: the landing probe fires in the same async call
    /// as reply persistence, i.e. within milliseconds of the agent's last token.
    /// A file that lands a second later — a tool that flushes after it answers,
    /// or an rclone VFS directory cache that has not settled — reads as a
    /// definitive 404 and closes the turn forever. This project's own
    /// connect-doctor still needs a five-second retry loop to avoid exactly that
    /// false negative even with `--dir-cache-time 1s` configured; a product that
    /// trusts ONE instant probe is trusting something its own tooling does not.
    ///
    /// WHY 60 SECONDS: an order of magnitude of headroom over that observed
    /// five-second settling, plus room for modest inter-device clock skew, while
    /// still being short enough that the one useful terminal retry is not
    /// deferred into irrelevance. Longer windows (minutes) only enlarge the
    /// pending set; a valid agent that publishes files minutes after replying
    /// needs an explicit completion protocol, not a bigger heuristic.
    ///
    /// AN ATTEMPT COUNT WOULD NOT DO: a second pass can fire milliseconds after
    /// the first (a notification tap, a foreground reload, another store event)
    /// and permanently repeat the same stale 404. Only wall-clock age separates
    /// "asked again" from "asked later".
    ///
    /// ANCHOR + SKEW: the deadline is measured from the turn's persisted
    /// `createdAt`, which every device sees identically after sync — no new
    /// field, no schema change. It is a wall clock, so a device whose clock runs
    /// BEHIND the author's simply waits longer (safe), and one running AHEAD by
    /// more than the window can close a turn early (the pre-change behaviour).
    /// Automatic time on Apple devices makes a minute of skew unusual, and the
    /// bad direction degrades to today's semantics rather than to something new.
    nonisolated static let outputScanGrace: TimeInterval = 60

    /// The same rule for a TRUNCATED pass — one where more eligible candidates
    /// existed than `maxCandidates` allowed it to examine.
    ///
    /// A truncated examination is not a finished examination: the pass never
    /// looked at the tail, so stamping the turn complete throws away whatever is
    /// there. It therefore stays open far longer than an ordinary pass, and each
    /// later pass walks the window forward past the keys already chipped.
    ///
    /// WHY IT IS A HORIZON AND NOT "FOREVER": the window only advances when a
    /// probe CONFIRMS a file, so a reply whose first ten candidates are all
    /// misses would otherwise re-probe the identical ten on every thread open
    /// for the life of the conversation, learning nothing. That is not
    /// hypothetical — a coding agent listing eleven files it edited in
    /// subdirectories produces exactly that shape, because the regex can only
    /// see each path's last segment and the served root does not hold it. One
    /// hour keeps the turn recoverable for as long as the user is plausibly
    /// still working in that thread, then lets it close.
    nonisolated static let truncatedScanHorizon: TimeInterval = 60 * 60

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
    ///
    /// `turnCreatedAt` is the persisted `createdAt` of the agent turn being
    /// scanned — the grace anchor (see `outputScanGrace`). `scanStartedAt` is
    /// captured HERE, before any probe, and threaded through: a pass that began
    /// inside the grace window must stay pending no matter how long its probes
    /// take to finish, or a slow multi-probe pass could drift past the deadline
    /// and stamp the turn on the strength of an early 404.
    ///
    /// Extraction runs ONCE and its result is handed to `detect` — the reply
    /// text is adversary-controlled and the regex is linear-but-not-free at
    /// ~2.2 s/MiB in its worst surviving shape, so a second pass over the same
    /// string is a cost with no answer attached.
    static func reconciliationScan(
        reply: String,
        conversationID: UUID,
        snapshot: SettingsManager.FileTransferSnapshot,
        excludedKeys: Set<String>,
        turnCreatedAt: Date,
        scanStartedAt: Date = Date()
    ) async -> ReconciliationScan {
        let candidates = await extractCandidatesOffMainActor(from: reply)
        guard !candidates.isEmpty else {
            return ReconciliationScan(drafts: [], conclusive: true)
        }
        let inbound = await inboundStoredKeyTokens(conversationID: conversationID)
        let result = await detect(
            candidates: candidates,
            reply: reply,
            snapshot: snapshot,
            inboundTokens: inbound,
            excludedKeys: excludedKeys,
            turnCreatedAt: turnCreatedAt,
            scanStartedAt: scanStartedAt
        )
        return ReconciliationScan(drafts: result.drafts, conclusive: result.conclusive)
    }

    /// Convenience entry point that extracts candidates from `reply` and runs
    /// the core detector. Prefer the `candidates:` overload wherever the caller
    /// has already paid for an extraction — see `reconciliationScan`.
    static func detect(
        reply: String,
        snapshot: SettingsManager.FileTransferSnapshot,
        inboundTokens: Set<String>,
        excludedKeys: Set<String>,
        turnCreatedAt: Date,
        scanStartedAt: Date = Date()
    ) async -> (drafts: [AttachmentDraft], conclusive: Bool) {
        await detect(
            candidates: await extractCandidatesOffMainActor(from: reply),
            reply: reply,
            snapshot: snapshot,
            inboundTokens: inboundTokens,
            excludedKeys: excludedKeys,
            turnCreatedAt: turnCreatedAt,
            scanStartedAt: scanStartedAt
        )
    }

    /// Core detector on PRE-RESOLVED context — the seam the retroactive scan
    /// drives (it resolves the snapshot + inbound set ONCE for a whole pass, then
    /// calls this per candidate turn):
    ///   - `excludedKeys` drops candidates whose storedKey is already attached on
    ///     the TARGET message (retro dedupe BEFORE the probe, so an already-
    ///     chipped key can't eat a probe slot). It is exactly that message's
    ///     stored keys, which is why its COUNT is also read as the message's
    ///     chip census for `maxOutputChipsPerMessage`. Empty on the landing path
    ///     (a turn that did not exist a moment ago carries no chips).
    ///   - `turnCreatedAt` / `scanStartedAt` drive the age gate — see
    ///     `outputScanGrace`. `scanStartedAt` must be captured BEFORE the first
    ///     probe, never read as `Date()` after the loop.
    ///   - `reply` is the text `candidates` was extracted from, and is used for
    ///     ONE thing: ordering a window the cap cannot hold (see
    ///     `probeOrderedCandidates`). It carries no default — a caller that
    ///     forgot it would silently probe a raw prefix and re-open the tail-
    ///     starvation this ordering exists to close.
    ///
    /// CONCLUSIVENESS — the single question "may this pass permanently close the
    /// turn?" (see `scanMayClose`). Three ways to answer yes without probing at
    /// all, each because no future pass could learn anything more:
    ///   - nothing filename-shaped in the reply;
    ///   - nothing left after the inbound / already-chipped filters;
    ///   - the message already holds `maxOutputChipsPerMessage` chips.
    /// Otherwise the verdict needs the network, and then it needs every probe to
    /// have been definitive AND the age gate to have opened.
    ///
    /// FAIL-FAST ON THE FIRST LANE-WIDE PROBE FAILURE: `.unauthorized` /
    /// `.certRefused` / `.serverError` / `.unknown` are not key-specific — a
    /// wrong credential, an untrusted certificate, a server that is down.
    /// Firing the remaining probes at the same snapshot learns nothing and
    /// spends the user's home server (and, on a timeout, a 15-second budget
    /// each). The turn stays pending, so anything the abandoned probes would
    /// have found is found by the next pass.
    ///
    /// `.ambiguous` is the one non-definitive outcome that does NOT stop the
    /// pass — see `probeFailureIsLaneWide`. It is a fact about one key, and
    /// stopping on it would let a single unreadable filename permanently starve
    /// every real deliverable named after it.
    ///
    /// PRIVACY (see the spec's Privacy & Security section): never logs the reply text, candidate filenames,
    /// storedKeys, or the snapshot — no `print`/`os_log` in this path.
    static func detect(
        candidates: [String],
        reply: String,
        snapshot: SettingsManager.FileTransferSnapshot,
        inboundTokens: Set<String>,
        excludedKeys: Set<String>,
        turnCreatedAt: Date,
        scanStartedAt: Date = Date()
    ) async -> (drafts: [AttachmentDraft], conclusive: Bool) {
        // TWO PLANS, and the cheap one decides whether the second is worth
        // paying for. `probeOrderedCandidates` only changes WHICH candidates a
        // window holds when the cap actually cuts the list, so a reply that fits
        // never pays for the claim scan at all — and `reply` is the same string
        // `candidates` came from, threaded here rather than re-extracted.
        let rawPlan = probePlan(
            candidates: candidates,
            inboundTokens: inboundTokens,
            excludedKeys: excludedKeys
        )
        let plan: ProbePlan
        if rawPlan.truncated {
            plan = probePlan(
                candidates: candidates,
                inboundTokens: inboundTokens,
                excludedKeys: excludedKeys,
                claimTokens: await standaloneClaimTokensOffMainActor(
                    in: reply,
                    candidates: Set(candidates)
                )
            )
        } else {
            plan = rawPlan
        }
        // An empty window means there is nothing left for ANY pass to learn —
        // no filename in the reply, nothing eligible after the filters, or the
        // message already at its chip ceiling. Reply text is immutable, so a
        // later pass would reach the same answer: close the turn, no grace, no
        // network. See `probePlan`.
        guard !plan.window.isEmpty else { return ([], true) }

        var drafts: [AttachmentDraft] = []
        var everyProbeDefinitive = true
        for candidate in plan.window {
            // Size-returning probe so the download chip can render the file size
            // and gate a soft-confirm on very large downloads. Same ranged GET as
            // `probeExists`; `byteLength` is nil when the server omits a parseable
            // length (→ byteSize 0 = "unknown", chip shows no size + no gate).
            let (outcome, byteLength) = await BackgroundFileTransfer.shared.probeExistsWithLength(
                snapshot: snapshot,
                storedKey: candidate
            )
            // A lane-wide failure ends the turn's pass immediately; the turn
            // stays pending so a later open retries the whole window. A
            // key-LOCAL one (`.ambiguous`) only costs this candidate — the pass
            // keeps going, because the next filename in the same reply may be a
            // real deliverable and the window is re-probed in this same order
            // every time. See `probeFailureIsLaneWide`.
            guard probeIsConclusive(outcome) else {
                everyProbeDefinitive = false
                if probeFailureIsLaneWide(outcome) { break }
                continue
            }
            // Only a confirmed-present file chips; a mentioned-but-never-written
            // name (`.missing`) yields nothing.
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
        let conclusive = scanMayClose(
            turnCreatedAt: turnCreatedAt,
            scanStartedAt: scanStartedAt,
            everyProbeDefinitive: everyProbeDefinitive,
            truncated: plan.truncated
        )
        return (drafts, conclusive)
    }

    /// What a pass will actually probe, and whether it will have seen
    /// everything. Pure + content-free (never logged); `nonisolated` and
    /// internal so the cap / exclusion / truncation rules are testable without
    /// a file server.
    struct ProbePlan: Equatable, Sendable {
        /// The candidates this pass will probe. First-appearance order whenever
        /// the window holds every eligible candidate; when the cap cuts the
        /// list, `probeOrderedCandidates` decides which ones make it in. Empty
        /// ⇒ there is nothing left for any pass to learn (see `detect`).
        let window: [String]
        /// Eligible candidates existed that the window could not hold. The pass
        /// is therefore an INCOMPLETE examination of the reply.
        let truncated: Bool
    }

    /// `claimTokens` is the reply's STANDALONE delivery claims
    /// (`MissingOutputNotice.standaloneClaimTokens`), used only to order an
    /// OVERFLOWING window — see `probeOrderedCandidates`. Empty is always safe:
    /// it costs ordering quality, never correctness, and it is what the notice's
    /// window reconstruction passes (see below).
    ///
    /// WHY THE NOTICE MAY OMIT IT, stated here because the omission is invisible
    /// at that call site. `MissingOutputNotice.replyClaims` reconstructs this
    /// plan to decide whether a named file was definitively absent, and it must
    /// reconstruct what production actually probed. It still does, exactly:
    /// ordering is reached ONLY on the `eligible.count > budget` branch, which
    /// returns `truncated: true`, and `MissingOutputNotice.shouldSurface` refuses
    /// every truncated turn. On the branch a notice can survive, the window is
    /// the WHOLE eligible list and no ordering runs at all — so the two agree
    /// element for element, not merely as sets.
    nonisolated static func probePlan(
        candidates: [String],
        inboundTokens: Set<String>,
        excludedKeys: Set<String>,
        claimTokens: Set<String> = []
    ) -> ProbePlan {
        // Nothing filename-shaped to probe → closed. A marked turn is never
        // re-scanned, which is correct here: there is no output to find, and no
        // later pass over the same immutable reply text could disagree.
        guard !candidates.isEmpty else {
            return ProbePlan(window: [], truncated: false)
        }
        // The message already carries its lifetime allowance of chips, so no
        // probe could add one. Close it rather than re-probing forever.
        guard excludedKeys.count < maxOutputChipsPerMessage else {
            return ProbePlan(window: [], truncated: false)
        }
        // Drop the conversation's own inbound uploads AND any storedKey already
        // attached on the target message BEFORE the cap, so neither an echoed
        // inbound name nor an already-chipped output can become a duplicate chip
        // or eat a probe slot. This is also what makes the window WALK: keys
        // confirmed by an earlier pass fall out, exposing the next slice.
        let eligible = candidates
            .filter { !inboundTokens.contains($0) && !excludedKeys.contains($0) }
        guard !eligible.isEmpty else {
            return ProbePlan(window: [], truncated: false)
        }
        // A pass may only chip up to the message's REMAINING allowance, so a
        // walked window can never overshoot the lifetime ceiling.
        let budget = min(maxCandidates, maxOutputChipsPerMessage - excludedKeys.count)
        // The window holds everything eligible, so WHICH candidates it contains
        // cannot depend on order — and a pass that probes them all reaches the
        // same set of chips whatever sequence it asks in. Ordering is skipped
        // entirely here, which is also what keeps its cost off the common path.
        guard eligible.count > budget else {
            return ProbePlan(window: eligible, truncated: false)
        }
        return ProbePlan(
            window: Array(
                probeOrderedCandidates(eligible, claimTokens: claimTokens).prefix(budget)
            ),
            truncated: true
        )
    }

    /// The order an OVERFLOWING candidate list is probed in — a three-group
    /// STABLE partition, original relative order preserved inside each group and
    /// nothing dropped. Reached only from `probePlan`'s truncating branch.
    ///
    /// WHY ORDER IS A CORRECTNESS PROPERTY AND NOT A PREFERENCE. Taking a raw
    /// first-appearance prefix starves the tail of a long reply, and the tail is
    /// exactly where a coding agent puts its deliverable: it reports the files it
    /// touched, THEN names what it produced. Truncation keeps the turn open, but
    /// the window only WALKS when a probe CONFIRMS a file — so a window filled
    /// with ten names that do not exist at the served root never advances, and
    /// the turn closes at `truncatedScanHorizon` having never once asked about
    /// the artifact. Nothing about that failure is visible to the user.
    ///
    /// GROUP 1 — THE COMPATIBILITY RESERVE, and the reason this function exists.
    /// The extensions in `MissingOutputNotice.evidenceFloorAllowlist`, capped at
    /// `evidenceFloorMaxCandidates`, are precisely the rules the previous build
    /// probed under. Reserving the head of the window for them GUARANTEES that
    /// every candidate that build would have examined is still examined here —
    /// so widening `outputAllowlist` and raising `maxCandidates` cannot cost a
    /// handback that already worked. Without the reserve the widening is a
    /// regression by construction: ten newly-admitted `.go` names now displace
    /// the `.md` deliverable that used to be candidate #1.
    ///
    /// Those two constants are borrowed rather than restated because a second
    /// copy of a thirty-entry list is a copy that drifts. They carry a
    /// may-only-SHRINK maintenance rule for the notice's sake, which is the same
    /// direction this needs: the reserve must describe a build that shipped.
    ///
    /// GROUP 2 — STANDALONE DELIVERY CLAIMS among what the reserve did not take.
    /// This is what covers a deliverable whose extension the reserve does not
    /// know (audio, a notebook, a source file). The discriminator is structural,
    /// not linguistic — a filename alone on its line is a handover, one sharing
    /// its line with other words is a mention — and it is reused verbatim from
    /// `MissingOutputNotice.standaloneClaimTokens` rather than reimplemented, so
    /// there is ONE definition of "claim" in the product.
    /// `ConverseRequest.fileDeliveryInstruction` asks agents for exactly that
    /// shape, so a compliant agent lands in this group by construction.
    ///
    /// `ecosystemProseTokens` is subtracted because the line rule alone cannot
    /// tell a handover from a tech-stack bullet: a reply listing `- Node.js`,
    /// `- Next.js`, `- Vue.js` … produces ten perfectly standalone "claims" that
    /// would otherwise push a real deliverable out of the window. The notice
    /// applies the same subtraction at its own verdict; doing it here keeps the
    /// two callers' notion of a claim identical.
    ///
    /// GROUP 3 — everything else, still in first-appearance order. Non-claims are
    /// REORDERED, never discarded: they remain probeable on this pass and on
    /// every later one, and a reply with no claims at all is left exactly as it
    /// was.
    ///
    /// WHAT THIS COSTS, because a reordering can only ever move loss around: a
    /// deliverable that is neither reserve-eligible NOR standalone, in a reply
    /// whose other names are, is pushed further back than a raw prefix would have
    /// put it. The reserve bounds that to deliverables using one of the newly
    /// admitted extensions AND named in prose only — i.e. an agent ignoring the
    /// delivery instruction it was given in the same turn — while the shape it
    /// fixes is the modal one for the coding gateways this product showcases.
    ///
    /// DETERMINISTIC: `claimTokens` is only ever membership-tested, never
    /// iterated, so the output order is a function of `eligible` alone. Reply
    /// text is immutable, so repeated passes over the same turn build the same
    /// order and the walk cannot oscillate.
    ///
    /// COST: one pass over `eligible` with an extension lookup per element —
    /// negligible beside the extraction that produced the list, and beside the
    /// network probes it schedules. The claim SET is the priced part; see
    /// `standaloneClaimTokensOffMainActor`.
    ///
    /// Pure + content-free (never logged); `nonisolated` and internal so the
    /// ordering rules are testable without a file server.
    nonisolated static func probeOrderedCandidates(
        _ eligible: [String],
        claimTokens: Set<String>
    ) -> [String] {
        var reserved: [String] = []
        var claimed: [String] = []
        var incidental: [String] = []
        for candidate in eligible {
            if reserved.count < MissingOutputNotice.evidenceFloorMaxCandidates,
               MissingOutputNotice.evidenceFloorAllowlist
                   .contains(MissingOutputNotice.fileExtension(of: candidate)) {
                reserved.append(candidate)
            } else if claimTokens.contains(candidate),
                      !MissingOutputNotice.ecosystemProseTokens.contains(candidate.lowercased()) {
                claimed.append(candidate)
            } else {
                incidental.append(candidate)
            }
        }
        return reserved + claimed + incidental
    }

    /// Longest reply this will run the claim scan over. Above it a pass keeps
    /// the compatibility reserve and skips group 2 — i.e. it degrades to the
    /// ordering it would have had anyway, never to something worse.
    ///
    /// WHY A CEILING AT ALL: `standaloneClaimTokens` splits the reply into lines
    /// before it can classify any, and reply text is adversary-controlled up to
    /// the 16 MiB `Constants.maxBackgroundResponseBytes` transport ceiling. A
    /// body of bare newlines materialises one array element per byte — tens of
    /// millions of them, hundreds of megabytes of descriptors — which on a phone
    /// is a memory-pressure kill, not a slow scan. The CPU is the smaller half of
    /// that problem.
    ///
    /// WHY 1 MiB COSTS NOTHING REAL: it is a quarter-million words of reply text.
    /// An agent turn that long has already failed the user for other reasons, and
    /// the fallback still probes what the previous build probed.
    nonisolated static let maxClaimOrderingReplyBytes = 1 << 20

    /// The reply's standalone delivery claims, off the caller's thread and
    /// bounded. `probePlan` is `nonisolated`, which does NOT relocate execution —
    /// a nonisolated sync function runs on its caller's thread, and `detect` is
    /// main-actor (module default). Deriving claims inside the plan would
    /// therefore put an adversary-sized line scan on the main actor, so the
    /// derivation lives out here and the result is handed IN.
    ///
    /// COST (measured, `swiftc -O` arm64, per MiB of reply): 0.011 s on ordinary
    /// prose, 0.10 s on the worst shape for it — a body of bare newlines, one
    /// allocation per line. The extraction it accompanies is 2.27 s/MiB in its
    /// own worst surviving shape (`extractCandidates`), so on any reply where the
    /// regex is expensive this adds under 1%; on the newline shape, where the
    /// regex is nearly free, `maxClaimOrderingReplyBytes` is what bounds it.
    ///
    /// Callers pay this ONLY when `probePlan` reports truncation — an ordinary
    /// reply naming at most `maxCandidates` files never reaches it.
    ///
    /// Pure + content-free (never logged).
    nonisolated static func standaloneClaimTokensOffMainActor(
        in reply: String,
        candidates: Set<String>
    ) async -> Set<String> {
        guard !candidates.isEmpty, reply.utf8.count <= maxClaimOrderingReplyBytes else {
            return []
        }
        return await Task.detached(priority: .utility) {
            MissingOutputNotice.standaloneClaimTokens(in: reply, candidates: candidates)
        }.value
    }

    /// Whether a PROBING pass may permanently stamp `outputScanDone`. Pure +
    /// content-free; `nonisolated` so the test target can call it off the main
    /// actor. The three no-probe-needed closures live in `detect` — this answers
    /// only the case where the verdict came from the network.
    ///
    /// Two independent gates, both of which must open:
    ///   - EVIDENCE: every probe the pass attempted came back definitive. One
    ///     transient outcome and the pass learned nothing it can stand behind.
    ///   - AGE: the pass STARTED at or after the turn's deadline —
    ///     `createdAt + outputScanGrace`, or `+ truncatedScanHorizon` when the
    ///     pass could not examine every eligible candidate.
    ///
    /// The age gate is deliberately measured from when the pass STARTED. Ten
    /// sequential probes against a slow server can outlive the grace window on
    /// their own; reading the clock afterwards would let a 404 from the first
    /// millisecond close a turn purely because the pass took a while.
    nonisolated static func scanMayClose(
        turnCreatedAt: Date,
        scanStartedAt: Date,
        everyProbeDefinitive: Bool,
        truncated: Bool
    ) -> Bool {
        guard everyProbeDefinitive else { return false }
        let horizon = truncated ? truncatedScanHorizon : outputScanGrace
        return scanStartedAt >= turnCreatedAt.addingTimeInterval(horizon)
    }

    /// Whether a single probe outcome is DEFINITIVE — a real present/absent
    /// verdict (`.exists` / `.missing`). Everything else is not: the pass
    /// learned nothing about the file, so it stays pending for a later thread
    /// open. Pure + content-free; internal for the test target.
    ///
    /// Definitive is NOT the same as sufficient. A `.missing` is a real answer
    /// about this instant, and this instant may simply be too early — the age
    /// gate in `scanMayClose` is what decides whether the pass may act on it.
    ///
    /// `.certRefused` is non-definitive despite being TERMINAL for the attempt
    /// that produced it: the refusal says nothing about whether the file exists,
    /// and the user can fix the certificate, so a later open must re-probe
    /// rather than permanently stamp a scan that learned nothing.
    ///
    /// Definitiveness is a SEPARATE question from `probeFailureIsLaneWide`,
    /// which decides whether the rest of the window is still worth probing.
    static func probeIsConclusive(_ outcome: FileProbeOutcome) -> Bool {
        switch outcome {
        case .exists, .missing: return true
        case .unauthorized, .serverError, .certRefused, .ambiguous, .unknown: return false
        }
    }

    /// Whether a non-definitive outcome is a fact about the LANE rather than
    /// about the one key that produced it — i.e. whether the pass should stop.
    ///
    /// A wrong credential, an untrusted certificate, a server that is down, an
    /// endpoint that cannot answer sensibly: every remaining probe would meet
    /// the same wall, so firing them learns nothing and, on a timeout, spends 15
    /// seconds each against the user's home server.
    ///
    /// `.ambiguous` is the exception, and the reason this predicate is not just
    /// `!probeIsConclusive`. It means the lane answered fine and THIS key's
    /// answer was unusable — an HTML document under a `.pdf` name, a `206` whose
    /// body contradicts its own `Content-Range`. Treating that as lane-wide
    /// would let one unreadable filename starve every real deliverable named
    /// after it in the same reply, forever, since the window is re-probed in the
    /// same order on every pass. The turn still stays open either way.
    static func probeFailureIsLaneWide(_ outcome: FileProbeOutcome) -> Bool {
        switch outcome {
        case .ambiguous: return false
        case .exists, .missing, .unauthorized, .serverError, .certRefused, .unknown: return true
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
        case "toml": return "application/toml"
        case "txt", "log": return "text/plain"
        case "md": return "text/markdown"
        case "html": return "text/html"
        case "rtf": return "application/rtf"
        case "epub": return "application/epub+zip"
        case "zip": return "application/zip"
        case "tar": return "application/x-tar"
        case "gz": return "application/gzip"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "svg": return "image/svg+xml"
        case "m4a", "aac": return "audio/mp4"
        case "mp3": return "audio/mpeg"
        case "wav": return "audio/wav"
        case "flac": return "audio/flac"
        case "ogg", "opus": return "audio/ogg"
        case "xlsx": return "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
        case "xls": return "application/vnd.ms-excel"
        case "docx": return "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
        case "doc": return "application/msword"
        case "pptx": return "application/vnd.openxmlformats-officedocument.presentationml.presentation"
        case "ppt": return "application/vnd.ms-powerpoint"
        case "py": return "text/x-python"
        case "js": return "text/javascript"
        case "ts": return "application/typescript"
        case "sh": return "application/x-sh"
        case "bat": return "application/x-bat"
        case "ps1": return "application/x-powershell"
        case "sql": return "application/sql"
        case "parquet": return "application/vnd.apache.parquet"
        case "ipynb": return "application/x-ipynb+json"
        case "go": return "text/x-go"
        case "rs": return "text/x-rust"
        case "rb": return "text/x-ruby"
        case "kt": return "text/x-kotlin"
        case "java": return "text/x-java-source"
        case "swift": return "text/x-swift"
        case "cpp", "hpp": return "text/x-c++src"
        case "css": return "text/css"
        case "scss": return "text/x-scss"
        case "tex": return "application/x-tex"
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
    /// `webp` IS included — ImageIO has decoded it since long before this app's
    /// deployment floor, so an agent-produced WebP earns a wrist thumbnail like
    /// any other raster output.
    nonisolated static let imagePreviewExtensions: Set<String> =
        outputAllowlist.intersection(["png", "jpg", "jpeg", "gif", "webp"])

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
