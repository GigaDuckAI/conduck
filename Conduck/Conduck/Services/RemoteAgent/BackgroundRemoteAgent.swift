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
// WHAT THE BACKGROUND SESSION ALSO BUYS, AND WHY IT SHAPES THIS FILE. Process
// exit is only half of what this transport does. A background session ALWAYS
// WAITS FOR CONNECTIVITY and additionally re-attempts transport failures out of
// process, inside `nsurlsessiond`. NEITHER IS CONFIGURABLE:
// `waitsForConnectivity` and `urlSession(_:taskIsWaitingForConnectivity:)` are
// documented to do nothing here, so they appear nowhere in this tree and must
// stay that way — setting one advertises a contract that does not exist. The
// measured consequence: with the radio off, or with a gateway URL whose host
// refuses the connection, the upload does not fail. It parks, and the only
// bound on the park is `timeoutIntervalForResource`, whose coverage of a
// PRE-DISPATCH park Apple does not document.
//
// That is deliberate and it is good behaviour — a send made in a tunnel
// delivers itself when the radio comes back, which is exactly what a phone
// transport should do, and it is the reason nothing here fails an offline send
// and nothing here re-sends anything. What was NOT acceptable was the app
// narrating that park as "the gateway is working on it". So THIS FILE OWNS THE
// DEPARTURE FACTS: two monotone per-task latches fed by `didSendBodyData` (with
// the first response chunk as an unconditional backstop) and, across a
// relaunch, by `URLSessionTask.countOfBytesSent`. Until the body has actually
// left, the row says it is still sending — it never names the gateway. See
// `anyBytesDepartedTaskIDs` / `bodyFullySentTaskIDs`, and `LiveTurnPhaseResolver`
// for what the words become.
//
// NOTHING HERE BOUNDS AN UNDISPATCHED TURN, on purpose. Every bound the app
// could enforce would have to reach terminal state by asking `nsurlsessiond` to
// cancel — a request Apple documents as asynchronous and racy, and which the
// system's own background rate limiter (undocumented, and steeper after each
// background relaunch) would trip on turns iOS was about to send perfectly
// well. Killing those is at-most-once-safe but is a failure the app would be
// manufacturing out of a scheduling decision. The user's bound is Stop, which
// is lit in every phase and — when the byte counters prove nothing left — says
// so without blaming a machine it cannot see (`ConverseCancelVerdict`).
//
// THAT MAKES STOP LOAD-BEARING, so `cancel(conversationID:)` may never quietly
// find nothing. It looks in the in-memory registry first and falls back to the
// session's own live task set matched on recovery metadata, because the turn
// most likely to be parked is the one that outlived a process kill — and that
// is exactly the turn the registry cannot see.
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
// TERMINAL gateway URL, never at a redirector" (`docs/ai-context/spec.md`).
// Rationale in full on
// `RemoteAgentTrustEvaluator.converseTaskPin(for:metadata:)`.
//
// Privacy invariants (see docs/ai-context/spec.md): the bearer token is NEVER
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

    /// Task identifiers this process asked to stop, kept OUTSIDE the `inFlight`
    /// registry so a Stop works on a task that outlived a process kill.
    ///
    /// WHY IT CANNOT LIVE ON THE `InFlightTurn` ENTRY. A task the system
    /// resurrected in a new process has no entry — the registry died with the
    /// old process — and the same completion the resurrection path reads is the
    /// one a user's Stop produces. Without a note kept apart from the registry,
    /// `didCompleteWithError` reads `entry == nil` and takes the CROSS-LAUNCH
    /// FAILURE branch: it pushes a notification and lights the macOS failure dot
    /// to report the user's own tap back to them as a problem.
    ///
    /// A per-PROCESS set is sufficient and a durable one would be wrong: the
    /// Stop and the completion it causes always happen in the same process, and
    /// a note that survived a launch would silently convert a genuine
    /// resurrection into a "you stopped this" the user never did. Queue-confined
    /// like the sets around it, and removed on every completion path.
    private var cancelRequestedTaskIDs = Set<Int>()

    /// Task identifiers whose response body exceeded
    /// `Constants.maxBackgroundResponseBytes` and were cancelled for it. Same
    /// registry pattern as `trustSignalsByTaskID`, for the same reason: a bare
    /// `task.cancel()` is indistinguishable from a user cancel, which would
    /// abort the turn with a Retry chip and NO error surfaced anywhere.
    /// Queue-confined.
    private var overCapTaskIDs = Set<Int>()

    /// SAFETY LATCH — task identifiers for which AT LEAST ONE request-body byte
    /// has been reported sent. Set by `didSendBodyData` on any `totalBytesSent
    /// > 0`, and unconditionally by the first `didReceive data:` (a response
    /// body arriving is definitive proof the gateway has the request).
    ///
    /// MONOTONE: set once, never cleared until the task's own completion
    /// removes it. That is load-bearing, and it is what makes every layer of
    /// out-of-process retry inside `nsurlsessiond` — including the iOS-17+
    /// high-level background upload retry, whose idempotency policy Apple does
    /// not document — irrelevant to every decision downstream. If a retry
    /// re-sends, the latch was already set on the first attempt and nobody
    /// changes their mind.
    ///
    /// Its ONLY consumer is `ConverseCancelVerdict` — the `> 0` threshold is
    /// what withdraws the non-delivery proof, so it must never be raised to
    /// "the whole body went". Queue-confined, like the sets above.
    private var anyBytesDepartedTaskIDs = Set<Int>()

    /// DISPLAY LATCH — task identifiers whose request body is FULLY sent
    /// (`totalBytesSent >= totalBytesExpectedToSend`, falling back to the
    /// safety threshold when the expected length is unknown), or whose first
    /// response chunk has arrived.
    ///
    /// A DELIBERATELY DIFFERENT THRESHOLD from the safety latch, not a
    /// duplicate of it: a half-sent body means the gateway is still RECEIVING,
    /// not answering, so a row that flipped to "…is answering…" on the first
    /// byte of a large image upload would be telling a smaller version of the
    /// same lie. Consumed by `InFlightTurnRegistry.noteDispatched`, which is
    /// what moves the row off "Sending…".
    ///
    /// ACCEPTED CONSEQUENCE: if `nsurlsessiond` sends the body, the connection
    /// resets, and the task re-parks, the row keeps saying "answering".
    /// Un-latching would require observing a retry, for which Apple exposes no
    /// live signal. That is smaller and rarer than the defect being fixed, and
    /// the row still claims nothing it cannot support — bytes did leave.
    /// Queue-confined.
    private var bodyFullySentTaskIDs = Set<Int>()

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
        // Nil means no output box is minted, no location line rides, and the
        // reply has no explicit output-scan lane. Never resolve a replacement here.
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

        // Name THIS dispatch's output box and witness that it is not there yet.
        // Minted here, inside `send`, rather than by the callers: every path
        // that reaches this method is a distinct dispatch — including a retry of
        // a stored turn — so minting at the single enqueue point is what makes
        // "a retry gets a fresh box" true by construction rather than by six
        // call sites remembering. Nil (no ready lane, a lane that cannot hold a
        // nested collection, or an unwitnessed absence) means this turn carries
        // no location line and gets no automatic delivery.
        let outboxKey = await BackgroundFileTransfer.mintWitnessedOutboxKey(
            conversationID: conversationID,
            snapshot: fileTransferSnapshot
        )

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
                fileServerReady: fileServerReady,
                outboxKey: outboxKey
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
            // The folder named on the wire above, carried so the reply can be
            // persisted against it. THE ONLY channel that survives an
            // iOS/watchOS/CarPlay process kill mid-turn: without it a reply
            // landing after a relaunch knows its lane but not its folder, which
            // makes the turn unrecoverable rather than merely late.
            outputBoxKey: outboxKey,
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
    /// TWO WAYS TO FIND THE TASK, because Stop is the ONLY bound on a wait
    /// nothing else bounds and it may not be allowed to silently do nothing.
    ///
    /// The in-memory registry answers for a turn THIS process dispatched. It
    /// cannot answer for one the system resurrected across a launch — the
    /// registry died with the old process — and that turn is precisely the one
    /// most likely to be parked: it survived a kill, its row comes back through
    /// `reconcile()` as a live, cancellable claim, and the thread lights a Stop
    /// for it. Guarding on the registry alone left that Stop inert, with no
    /// completion, no failure and a row that kept counting forever.
    ///
    /// So a miss falls through to the session's own live task set, matched on
    /// the decoded recovery metadata — the same authoritative cross-launch
    /// source `hasLiveConverseTask` and `liveConversationIDs` read.
    func cancel(conversationID: UUID) {
        queue.async {
            // Record the INTENT before asking the task to stop. The delegate
            // cannot otherwise tell our cancel from a peer-side stream reset,
            // and calling a reset a "cancel" suppresses the classification the
            // user needs — see the `.cancelled` branch in `didCompleteWithError`.
            if let entry = self.inFlight.values.first(where: { $0.conversationID == conversationID }) {
                self.inFlight[entry.taskIdentifier]?.cancelRequested = true
                self.cancelRequestedTaskIDs.insert(entry.taskIdentifier)
                // Find the live task by identifier and cancel it. The delegate's
                // `didCompleteWithError` with a `.cancelled` URLError performs the
                // continuation resume + cleanup.
                self.session.getAllTasks { tasks in
                    for task in tasks where task.taskIdentifier == entry.taskIdentifier {
                        task.cancel()
                    }
                }
                return
            }
            self.session.getAllTasks { tasks in
                let matches = tasks.filter { task in
                    task.taskDescription
                        .flatMap { try? RemoteAgentBackgroundMetadata.decode($0) }
                        .flatMap { UUID(uuidString: $0.conversationID) } == conversationID
                }
                guard !matches.isEmpty else { return }
                // Note the intent on `queue` BEFORE cancelling: the completion
                // callback runs there too, so a note taken after `cancel()`
                // could lose the race and be read as a resurrection.
                self.queue.async {
                    for task in matches { self.cancelRequestedTaskIDs.insert(task.taskIdentifier) }
                    for task in matches { task.cancel() }
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

    /// Conversations with a LIVE converse task on this background session
    /// (running OR suspended — not yet completed), each mapped to whether that
    /// task's request body HAS LEFT THE DEVICE. Read from `session.allTasks` +
    /// each task's decoded `taskDescription` metadata (the authoritative
    /// cross-launch set; the in-memory registry is empty after a kill).
    ///
    /// TWO CONSUMERS, ONE WALK. The launch-time stale-`sending` sweep uses the
    /// KEYS — those turns will be resolved authoritatively by this delegate
    /// when the task completes, so the sweep must not touch them. The
    /// in-flight registry uses the VALUE, which is what lets a thread row
    /// re-opened after a relaunch say "…is answering…" for a turn that already
    /// went out instead of regressing to "Sending…" forever.
    ///
    /// The departure flag is read from the TASK's own counters, not from the
    /// in-process latches, because a task resumed in a new process will never
    /// re-fire `didSendBodyData` for bytes it already sent. It mirrors the
    /// display latch's threshold (whole body, falling back to any byte when the
    /// expected length is unknown) and is OR'd with the in-process latch, which
    /// is the only source that survives a `countOfBytesExpectedToSend` the
    /// system reports as unknown mid-transfer.
    func liveConversationIDs() async -> [UUID: Bool] {
        let tasks = await session.allTasks
        let latched = await withCheckedContinuation { (continuation: CheckedContinuation<Set<Int>, Never>) in
            queue.async { continuation.resume(returning: self.bodyFullySentTaskIDs) }
        }
        var live: [UUID: Bool] = [:]
        for task in tasks {
            guard let id = task.taskDescription
                .flatMap({ try? RemoteAgentBackgroundMetadata.decode($0) })
                .flatMap({ UUID(uuidString: $0.conversationID) }) else { continue }
            let expected = task.countOfBytesExpectedToSend
            let sent = task.countOfBytesSent
            let departed = latched.contains(task.taskIdentifier)
                || (expected > 0 ? sent >= expected : sent > 0)
            // Two tasks can share a conversation (an overlapping turn); ONE
            // departure is enough for the row to stop saying "Sending…" —
            // matching the registry, which reads the oldest claim and only ever
            // fills the stamp in.
            live[id] = (live[id] ?? false) || departed
        }
        return live
    }

    // MARK: - Registry helpers

    /// Latch the DISPLAY departure fact for one task and, on its FIRST set
    /// only, tell the in-flight registry this turn has actually dispatched.
    /// MUST be called on `queue` (every caller is a delegate callback, which
    /// already is).
    ///
    /// The conversation id comes from the in-memory entry when this process
    /// enqueued the task, and from the recovery metadata otherwise — the only
    /// channel a task resumed in a NEW process still has.
    ///
    /// NOT counted as persistence work: this writes in-memory UI state, not the
    /// store, so holding the `.backgroundTask` closure open for it would keep
    /// the process alive for a row nobody is looking at.
    private func noteBodyDeparted(taskIdentifier id: Int, taskDescription: String?) {
        guard bodyFullySentTaskIDs.insert(id).inserted else { return }
        let conversationID = inFlight[id]?.conversationID
            ?? taskDescription
                .flatMap { try? RemoteAgentBackgroundMetadata.decode($0) }
                .flatMap { UUID(uuidString: $0.conversationID) }
        guard let conversationID else { return }
        Task { @MainActor in
            // Lane and cancellability are passed explicitly because this is the
            // ONE caller whose claim can have aged out before the departure
            // arrives — a turn parked longer than the registry's reaping horizon
            // with no list reload in between — and the registry then has to mint
            // one from these two facts.
            InFlightTurnRegistry.shared.noteDispatched(
                conversationID, lane: .backgroundConverse, isCancellable: true)
        }
    }

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
            // Fresh task, fresh latches. `taskIdentifier` is unique only among
            // OUTSTANDING tasks in a session, so a leftover latch from a
            // completed task with the same id would claim a departure that
            // belongs to a different turn.
            self.anyBytesDepartedTaskIDs.remove(taskIdentifier)
            self.bodyFullySentTaskIDs.remove(taskIdentifier)
            self.cancelRequestedTaskIDs.remove(taskIdentifier)
            self.bodyURLs[taskIdentifier] = bodyFileURL
#if DEBUG
            self.diagSentAt[taskIdentifier] = Date()
#endif
        }
    }
}

// MARK: - URLSession delegate

extension BackgroundRemoteAgent: URLSessionDataDelegate {

    /// THE BYTE-DEPARTURE EDGE. The one signal that tells the app whether this
    /// device has actually sent anything for a turn, which is the difference
    /// between "the gateway is working on it" and "nothing has moved".
    ///
    /// Not a speculative bet on an undocumented callback: `BackgroundFileTransfer`
    /// already drives a real user-visible progress bar from this exact callback,
    /// with this exact `totalBytesExpectedToSend > 0` guard, on a
    /// background-configured session.
    ///
    /// Sets the safety latch on any byte and the display latch only on the
    /// whole body — see the two properties for why those thresholds differ. The
    /// display latch's FIRST set is also what pushes
    /// `InFlightTurnRegistry.noteDispatched`, so the row moves off "Sending…"
    /// at the moment the claim becomes true and not before.
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        let id = task.taskIdentifier
        let departed = totalBytesSent > 0
        // Unknown expected length (`NSURLSessionTransferSizeUnknown`) degrades
        // to the safety threshold rather than never latching: a row stuck on
        // "Sending…" through a healthy turn would be the honest-but-useless
        // failure mode, and any-byte is still a truthful floor.
        let fullySent = totalBytesExpectedToSend > 0
            ? totalBytesSent >= totalBytesExpectedToSend
            : departed
        guard departed else { return }
        // `taskDescription` is read here, on the delegate queue, and carried as
        // a plain String — decoding it is deferred to the one callback that
        // actually needs it, so the common progress tick costs no JSON parse.
        let description = task.taskDescription
        queue.async {
            self.anyBytesDepartedTaskIDs.insert(id)
            guard fullySent else { return }
            self.noteBodyDeparted(taskIdentifier: id, taskDescription: description)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let id = dataTask.taskIdentifier
        let description = dataTask.taskDescription
        queue.async {
            // BACKSTOP, and it is required rather than belt-and-braces: a
            // response body arriving is definitive proof the gateway has the
            // request, whatever `didSendBodyData` did or did not report for
            // this upload. Set BEFORE the over-cap early return below, so even
            // a fabricated over-cap reply still records that the turn departed.
            self.anyBytesDepartedTaskIDs.insert(id)
            self.noteBodyDeparted(taskIdentifier: id, taskDescription: description)

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
        // The URL loading system's own cumulative send counter, read once here
        // (off the serial queue, on the task, after it terminated). It covers
        // out-of-process attempts this process never witnessed, which is why
        // the Stop verdict requires it ALONGSIDE the in-process latch.
        let countOfBytesSent = task.countOfBytesSent

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
            // The safety latch, consumed on the same every-exit-path contract.
            // Read into a local BEFORE any branch below returns — the Stop
            // verdict is the only consumer, but the removal must happen for
            // every completion or the set grows for the process lifetime.
            let anyBytesDeparted = self.anyBytesDepartedTaskIDs.remove(id) != nil
            self.bodyFullySentTaskIDs.remove(id)
            // "This process asked for this task to stop." Consumed on the same
            // every-exit-path contract as the notes above, and read below
            // ALONGSIDE the registry entry rather than instead of it: an entry
            // that survived carries the flag itself, and a resurrected task can
            // only have this.
            let stopWasRequested = self.cancelRequestedTaskIDs.remove(id) != nil

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
                        // -1022 is not a certificate verdict — no handshake
                        // happened — but it IS terminal and it IS this lane's
                        // answer, so it resolves here rather than falling into
                        // the `.cancelled` disambiguation below.
                        case .blockedByATS: certError = .insecureConnectionBlocked
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
                        // wire cannot tell them apart. Two local notes can —
                        // the registry entry, and `cancelRequestedTaskIDs`,
                        // which is kept OUTSIDE the registry precisely so a
                        // Stop can be recognised on a task that has no entry:
                        //
                        // NO STOP ASKED FOR + entry ABSENT → this task was
                        // resurrected ACROSS A LAUNCH (after a force-quit, ALL
                        // background tasks come back as `.cancelled`, and the
                        // registry died with the old process). Nobody cancelled
                        // this turn — treating it as a cancel left the user turn
                        // stuck at "sending" forever with no Retry. Map it to a
                        // cross-launch FAILURE: flip the turn to `failed`
                        // (Retry chip) + post the failure notification (no
                        // awaiting caller exists by definition). `error: nil`
                        // keeps the generic "wasn't delivered" copy.
                        //
                        // A STOP WAS ASKED FOR (entry `cancelRequested`, or the
                        // out-of-registry note for a resurrected task) → a live
                        // in-process cancel: the user tapped Stop, or a session
                        // teardown asked. No agent bubble, no notification, NO
                        // `.remoteAgentTurnDidFail` post — but the cancelled turn
                        // itself flips to `failed` (below), carrying a
                        // client-side classification when and only when the byte
                        // counters prove nothing left this device; the in-app
                        // caller's continuation receives `CancellationError`
                        // (a resurrected task has none, so that resolve is a
                        // no-op there).
                        //
                        // entry PRESENT + NOTHING ASKED → nobody here
                        // asked for this. The PEER reset the stream mid-request
                        // (an HTTP/2 RST_STREAM from the gateway or something in
                        // front of it), which URLSession also reports as -999.
                        // Presence alone used to be read as "the user cancelled",
                        // which is the worst available answer: a cancel writes NO
                        // classification, so a genuine gateway failure rendered
                        // as the bare "wasn't delivered" with no cause, no
                        // Troubleshoot link and no Diagnostics record. Classify
                        // it as the transport failure it is.
                        if entry == nil, !stopWasRequested {
                            if let cid = conversationID {
                                self.postTurnFailed(conversationID: cid, userMessageID: userMessageID, error: nil, notifyUser: true)
                            }
                            return
                        }
                        if entry != nil, entry?.cancelRequested != true, !stopWasRequested {
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
                        // notification and NO `.remoteAgentTurnDidFail` post,
                        // in EITHER branch below — cancel is user-initiated,
                        // not a failure event, so the macOS menu-bar red dot
                        // must not light and no push may fire. That is also why
                        // neither branch routes through `postTurnFailed`, which
                        // does both.
                        //
                        // WHETHER THE FAILURE IS CLASSIFIED depends on one
                        // question: did anything leave this device? A cancel is
                        // not a gateway verdict — true, and that is why a turn
                        // whose bytes departed still gets today's bare status
                        // flip with no cause attached. But a turn with ZERO
                        // departed bytes is a verdict about THIS DEVICE'S OWN
                        // transport, which the client can prove and the user
                        // deserves to read instead of an unexplained failed
                        // row. `ConverseCancelVerdict` owns that decision and
                        // carries the at-most-once proof; it is a pure function
                        // precisely so the proof is testable without a socket.
                        if let cid = conversationID {
                            let verdict = ConverseCancelVerdict.make(
                                anyBytesDeparted: anyBytesDeparted,
                                countOfBytesSent: countOfBytesSent,
                                pathIsUnsatisfied: NetworkPathObserver.pathIsUnsatisfiedNow()
                            )
                            self.beginPersistenceWork()
                            Task {
                                switch verdict {
                                case .unknownDelivery:
                                    if let mid = userMessageID {
                                        await ConversationStore.shared.markPendingUserTurn(messageID: mid, to: "failed")
                                    } else {
                                        await ConversationStore.shared.markPendingUserTurns(conversationID: cid, to: "failed")
                                    }
                                case .provableNonDelivery(let error):
                                    let classification = ConversationStore.TurnFailureClassification(
                                        failureCode: error.errorCode,
                                        wireCode: nil,
                                        hadHistoryImages: nil
                                    )
                                    if let mid = userMessageID {
                                        await ConversationStore.shared.failTurn(
                                            messageID: mid, classification: classification
                                        )
                                    } else {
                                        await ConversationStore.shared.failPendingUserTurns(
                                            conversationID: cid, classification: classification
                                        )
                                    }
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
                    outputBoxKey: metadata?.outputBoxKey,
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
        case .appTransportSecurityRequiresSecureConnection:
            // -1022, FIRST, in lockstep with `classifyTransportError`. The URL
            // string was refused before any connect, so this names the address
            // rather than the server — and it must not fall into the
            // `default:` unreachable arm, which would tell the user to go and
            // check a machine nothing ever contacted.
            return .insecureConnectionBlocked
        case .timedOut:
            return .remoteAgentTimeout
        // Kept in lockstep with `RemoteAgentTrustEvaluator.classifyTransportError`'s
        // arms of the same names — this duplicate exists because a background
        // session's completion callback cannot read the evaluator's per-challenge
        // signals, not because the transport taxonomy differs. Change both.
        case .notConnectedToInternet:
            // UNREACHABLE ON THIS LANE, and kept anyway. A background session
            // waits for connectivity instead of failing, so an offline converse
            // send parks rather than arriving here as code -1009 — measured on
            // device with the radio off. The arm stays because this mapper is
            // shared: `CarPlayConverseUploader` calls it too, the taxonomy must
            // remain in lockstep with `classifyTransportError`, and deleting an
            // arm to reflect one lane's reachability would be the kind of local
            // truth that breaks the next caller. The offline case a USER can
            // actually reach on this lane is a Stop over zero departed bytes —
            // see `ConverseCancelVerdict`, which reaches the same `AppError`
            // and therefore the same copy.
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
        /// The folder THIS dispatch named on the wire, read back from the task
        /// metadata. Persisted with the reply so a later listing knows which
        /// folder to read — and so a DIFFERENT device, or the same one days
        /// later, can find it at all.
        ///
        /// Rides the same store transaction as `fileTransferLaneID` below, and
        /// is dropped by the store when that is nil. Pass BOTH or NEITHER: a
        /// folder with no owning lane names a path nothing is allowed to read.
        outputBoxKey: String? = nil,
        /// Gateway config signature captured at DISPATCH (from the task
        /// metadata). nil = unknown / pre-upgrade blob → no success recorded,
        /// which is the fail-closed direction.
        dispatchChatSignature: String? = nil,
        didPersist: (() -> Void)? = nil
    ) async -> Bool {
        let agentMessageID = UUID()
        // Persist the reply + exact user sent-flip + explicit output-scan lane
        // in ONE Core Data transaction whenever modern metadata identifies the
        // user turn. A process death can therefore never expose a sent user
        // bubble without its reply, or a reply whose recovery lane was lost.
        if let userMessageID {
            guard (try? await ConversationStore.shared.completeAgentTurn(
                userMessageID: userMessageID,
                userStatus: "sent",
                agentText: reply,
                conversationID: conversationID,
                sourceDevice: SourceDevice.current,
                agentMessageID: agentMessageID,
                outputScanLaneID: fileTransferLaneID,
                outputBoxKey: outputBoxKey
            )) != nil else {
                return false
            }
        } else {
            // Backward compatibility for an in-flight pre-upgrade task whose
            // metadata has no exact user id. Preserve the legacy append then
            // conversation-wide status transition; no explicit lane can be
            // trusted for this old shape.
            guard (try? await ConversationStore.shared.appendMessage(
                role: "agent",
                text: reply,
                conversationID: conversationID,
                sourceDevice: SourceDevice.current
            )) != nil else {
                return false
            }
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

        // NO OUTPUT DISCOVERY HERE, and no preview download. The reply's row now
        // carries the folder this dispatch named (`outputBoxKey`) alongside its
        // lane, so discovery is one listing of that exact folder — and the ONE
        // place that runs is `ConversationDetailViewModel`'s retro pass, which
        // owns the grace window, the per-turn hold ladder, the lane breaker and
        // the identity guards. A second copy here would be a weaker one that has
        // to be kept in step.
        //
        // It costs nothing in latency: the store save above posts
        // `.conversationsDidChange`, so an open thread lists the box in the same
        // beat. A thread that is not open lists it when the user opens it, which
        // is also the first moment a chip could be seen.
        //
        // Previews are built from the bytes a chip TAP downloads
        // (`FileTransferOutputDetector.previewPatchesForDownloadedFile`). Pulling
        // them here meant every landed reply — and every CloudKit import echo
        // behind it — copied slices of the user's files into their own iCloud and
        // onto their wrist for content nobody had opened.
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
    ///
    /// The SHORT form (`shortDisplayName`), even though this poster runs on the
    /// phone: a local notification is not a phone surface. It mirrors to the
    /// paired Watch and lands on a lock screen, where the title is one line
    /// beside the icon and the timestamp — and a custom gateway's name may be up
    /// to 40 characters. The narrow-surface rule is applied by DESTINATION, not
    /// by which process posts.
    private static func replyNotificationTitle(backendRawValue: String?) async -> String {
        let generic = String(localized: "remoteAgent.notification.reply.title", defaultValue: "Reply from your AI")
        guard await SettingsManager.shared.configuredRemoteAgentRefs().count >= 2,
              let raw = backendRawValue,
              let ref = RemoteAgentRef(rawString: raw) else { return generic }
        let customs = await SettingsManager.shared.customGateways()
        return RemoteAgentRefMetadata.shortDisplayName(for: ref, customs: customs)
    }

    /// Post the reply notification whose tap deep-links to the conversation.
    /// userInfo carries the conversationID for the `NotificationDelegate`
    /// deep-link.
    ///
    /// `static` + internal (not `private`) for the same reason
    /// `postFailureNotification` is: the macOS in-app reply path has no
    /// background delegate to land through, so `MenuBarCoordinator` posts this
    /// exact notification itself rather than replicating its copy, identifier
    /// and sound policy.
    ///
    /// The body is the agent's reply, which is untrusted text on an OS-owned,
    /// app-branded surface: it persists in Notification Center, mirrors to the
    /// paired Watch, and renders on a locked screen. So it goes through
    /// `ReplySanitizer.displayLine` — one line, no control or bidi scalars, cut
    /// to `Constants.replyNotificationBodyCharacterCount`. The cut is the
    /// projection's own parameter rather than a `prefix` around it because
    /// cutting FIRST can drop a bidi terminator and leave its opener governing
    /// everything the banner still shows. The stored reply is untouched — this
    /// is a derived string for one banner.
    static func postReplyNotification(_ reply: String, conversationID: UUID, backendRawValue: String?) async {
        let content = UNMutableNotificationContent()
        content.title = await Self.replyNotificationTitle(backendRawValue: backendRawValue)
        content.body = ReplySanitizer.displayLine(
            reply,
            maxLength: Constants.replyNotificationBodyCharacterCount,
            // A reply of nothing but control scalars projects to empty. A BLANK
            // banner reads as a bug in Conduck rather than as a bad reply, so
            // the fallback states the fact the banner exists to carry and sends
            // the user to the thread, where the canonical text still lives.
            fallback: String(localized: "remoteAgent.notification.reply.emptyBody",
                             defaultValue: "Your AI replied. Open Conduck to read it.")
        )
        // One chime per BURST, not one per reply — three agents answering within
        // 30 s produce three banners and one sound. The window is App-Group
        // state, because on iOS this method runs in a process the background
        // URLSession event relaunched, once per landing turn. It is spent only
        // when this banner can actually be heard: a foreground presentation has
        // its sound stripped by `NotificationDelegate.willPresent`, so consuming
        // there would silence the rest of the burst for nothing.
        content.sound = await MainActor.run { ReplyNotificationSoundPolicy.consumeChimeIfAudible() }
            ? .default
            : nil
        // Group every banner for one conversation under that conversation, so a
        // quiet hour of replies reads as N threads rather than N notifications.
        content.threadIdentifier = conversationID.uuidString
        // DRIFT GUARD, not a change: `.active` is already the default. Stating
        // it makes any future `.timeSensitive` an explicit, reviewable edit — a
        // reply that took four minutes to arrive is by definition not
        // time-sensitive, and does not earn a Focus-mode break-through.
        content.interruptionLevel = .active
        content.userInfo = [NotificationDeepLink.conversationIDKey: conversationID.uuidString]

        // Identifier is DETERMINISTIC per conversation: Apple replaces a
        // pending/delivered request that reuses one, so a second reply in the
        // SAME conversation supersedes the first banner (one live banner per
        // thread — what we want). `threadIdentifier` above is what groups
        // DIFFERENT conversations.
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
    ///
    /// `ref` is the gateway the turn was bound to, and it decides whether the
    /// remedy half of a certificate verdict — the only class that carries one
    /// into this body — describes a machine the reader owns. It defaults to nil
    /// and is RESOLVED from the conversation's own binding when omitted, because
    /// every caller here is headless: a push is often the only place the verdict
    /// is ever read, and no one is standing at a screen to reinterpret it.
    static func postFailureNotification(conversationID: UUID,
                                        error: AppError?,
                                        ref: RemoteAgentRef? = nil) async {
        var resolvedRef = ref
        if resolvedRef == nil {
            let raw = (try? await ConversationStore.shared.fetchConversation(id: conversationID))?.backend
            resolvedRef = raw.flatMap(RemoteAgentRef.init(rawString:))
        }
        let content = UNMutableNotificationContent()
        content.title = failureNotificationTitle(for: error)
        // PRIVACY (never reveal gateway URLs — see docs/ai-context/spec.md): cases that
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
            content.body = appError.descriptionWithRecovery(for: resolvedRef)
        // Defence in depth. 74 belongs on `postDefaultNeedsSetupNotification`
        // below, which is keyed to no conversation; if it ever reaches the
        // conversation-keyed poster anyway, the remedy still travels with it —
        // the cause alone ("your default AI isn't set up") leaves a user who was
        // not watching with nothing to act on.
        case .some(.remoteAgentDefaultNeedsSetup):
            content.body = error?.descriptionWithRecovery(for: resolvedRef) ?? fallback
        case .some(let appError):
            // The CAUSE dispatches on the same ref the certificate arm above
            // uses. Nine gateway-class causes name "your gateway", which is a
            // machine a hosted-lane reader does not run — and this push may be
            // the only place the verdict is ever read. `resolvedRef` is already
            // in hand, so there is no reason for this line to answer for a lane
            // the turn was not on.
            content.body = appError.errorDescription(for: resolvedRef) ?? fallback
        case nil:
            content.body = fallback
        }
        // FAILURES ALWAYS CHIME and never consume the reply burst window. A
        // burst is many agents answering at once — a reply phenomenon. A failure
        // is not, and it is the one thing worth hearing every time.
        content.sound = .default
        // Same grouping + drift guard as the reply poster, so a failure banner
        // lands in its conversation's thread rather than beside it.
        content.threadIdentifier = conversationID.uuidString
        content.interruptionLevel = .active
        content.userInfo = [NotificationDeepLink.conversationIDKey: conversationID.uuidString]

        let request = UNNotificationRequest(
            identifier: NotificationDeepLink.failureIdentifierPrefix + conversationID.uuidString,
            content: content,
            trigger: nil
        )
        try? await UNUserNotificationCenter.current().add(request)
    }

    /// Post the USER notification for a headless turn refused because THIS
    /// device's default gateway cannot take a new chat.
    ///
    /// Separate from `postFailureNotification` because that one is keyed to a
    /// conversation and this refusal happens BEFORE the mint: there is no thread
    /// to group under, no thread to deep-link to, and no per-conversation
    /// identifier to build. The empty `conversationIDKey` is the established
    /// no-navigation signal (`SharedInboxDrainer`'s no-turn poster uses the same
    /// shape); `openPersonalAIKey` is what routes the tap to the fix instead.
    static func postDefaultNeedsSetupNotification(error: AppError) async {
        let content = UNMutableNotificationContent()
        // Names what actually happened — nothing was sent because nowhere was
        // chosen — and asserts no outage. The gateway may be running perfectly;
        // "No reply from your personal AI" would send the user to check a
        // machine that never saw the request.
        content.title = String(localized: "remoteAgent.notification.defaultNeedsSetup.title",
                               defaultValue: "Nothing to send to")
        // The REMEDY travels with the cause, on the certificate arm's argument:
        // this is a headless turn the user was not watching, the push may be the
        // only place the verdict is read for hours, and "your default isn't set
        // up" without the fix leaves nothing to act on.
        content.body = error.descriptionWithRecovery()
        // A refusal that swallowed a capture is worth hearing — same posture as
        // the failure poster.
        content.sound = .default
        content.interruptionLevel = .active
        // No `threadIdentifier`: there is no thread.
        let userInfo: [AnyHashable: Any] = [
            NotificationDeepLink.conversationIDKey: "",
            NotificationDeepLink.openPersonalAIKey: true
        ]
        content.userInfo = userInfo

        let request = UNNotificationRequest(
            // FIXED identifier, for two reasons. Fixed at all, so a second
            // refusal REPLACES the first rather than stacking a pile of
            // identical banners. And outside the `remoteAgent.failure.` prefix,
            // so `NotificationDeepLink.clearDelivered(for:)` and
            // `ReplyAutoSpeakDecider` — both of which key on that prefix — are
            // untouched by it.
            identifier: "remoteAgent.defaultNeedsSetup",
            content: content,
            trigger: nil
        )
        try? await UNUserNotificationCenter.current().add(request)
    }

    /// The failure notification's TITLE, derived from the error rather than
    /// fixed. A constant "Couldn't reach your AI" asserts a cause —
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
            return String(localized: "remoteAgent.notification.unreachable.title", defaultValue: "Couldn't reach your AI")
        default:
            // Everything the gateway ANSWERED — and the nil case, where the
            // cause is unknown and must not be guessed at.
            return String(localized: "remoteAgent.notification.failure.title.v2",
                          defaultValue: "No reply from your AI")
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
    /// conversation from the FOREGROUND view-model path. userInfo carries the
    /// conversationID string. `MenuBarCoordinator` observes it and raises both
    /// macOS cues — the menu-bar unread dot and the reply banner — unless the
    /// popover or the active window is already showing that thread.
    ///
    /// The banner belongs to THIS notification and not to
    /// `.remoteAgentTurnDidComplete`: the share/background landing already posts
    /// its own banner inside `recordReply`, so the two events stay one-banner-
    /// per-reply only because each posts from its own path. Fires on every macOS
    /// foreground reply success.
    static let conversationReplyArrived = Notification.Name("conversationReplyArrived")
}

/// Keys for notification userInfo deep-link payloads.
enum NotificationDeepLink {
    /// userInfo key carrying the target conversation UUID string.
    static let conversationIDKey = "conversationID"
    /// userInfo key carrying an `AppError.errorCode` Int (turn-failed bus).
    static let errorCodeKey = "errorCode"

    /// userInfo flag asking the app to land on Settings → Personal AI rather
    /// than on a thread. Carried by the default-needs-setup notification, which
    /// is posted BEFORE any conversation exists — so there is no thread to open,
    /// and the only useful destination is the screen where the default is
    /// chosen. Read by the tap delegate in `ConduckApp`, which arms
    /// `GatewayFixRoute`; a key added only at the posting site would be read by
    /// nobody.
    static let openPersonalAIKey = "openPersonalAI"
    /// Request-identifier prefix shared by every agent-REPLY notification
    /// (the iOS background delegate + the macOS in-app poster). Load-bearing
    /// contract: `ReplyAutoSpeakDecider` discriminates reply taps from
    /// FAILURE taps (`remoteAgent.failure.<uuid>` — which also carry a
    /// `conversationIDKey` for tap-to-retry) by this prefix, so a failure tap
    /// never auto-speaks a stale previous reply. Single-sourced here so the
    /// posting sites and the decider can't drift.
    static let replyIdentifierPrefix = "remoteAgent.reply."

    /// Request-identifier prefix shared by every TURN-failure notification.
    /// Single-sourced beside its reply sibling for the same reason: the poster
    /// and `clearDelivered(for:)` must agree on the exact string, or opening a
    /// thread would leave its failure banner behind in Notification Center.
    static let failureIdentifierPrefix = "remoteAgent.failure."

    /// Retire this conversation's REPLY and FAILURE notifications — delivered
    /// and still-pending — because the user is now looking at the thread they
    /// point to. A banner that survives the thread being opened is a lie the
    /// user has to dismiss by hand.
    ///
    /// Removes BY DETERMINISTIC IDENTIFIER, never by enumerating
    /// `deliveredNotifications()`: the identifiers are constructed from the
    /// conversation id at post time, so the exact two strings are known here,
    /// and an enumeration would pay an async round-trip plus a filter to
    /// rediscover them.
    ///
    /// Both are removed, not just the reply: a failure banner sitting beside a
    /// reply banner for the same thread is exactly the pair that a tap on one
    /// leaves half-cleared (the OS removes only the notification actually
    /// tapped).
    ///
    /// Safe to call for a conversation with no notifications — removal of an
    /// unknown identifier is a no-op. `nonisolated` because
    /// `UNUserNotificationCenter` removal is thread-safe and one of the four
    /// call sites is the notification delegate's nonisolated tap handler.
    nonisolated static func clearDelivered(for conversationID: UUID) {
        let identifiers = [
            replyIdentifierPrefix + conversationID.uuidString,
            failureIdentifierPrefix + conversationID.uuidString,
        ]
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
    }
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
