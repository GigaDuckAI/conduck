import Foundation
import UserNotifications
import WatchKit

/// Background URLSession uploader for the watchOS STT pipeline.
/// Fallback used when the foreground client fails (timeout, app suspended).
/// The system daemon owns the upload, so progress continues even after the
/// app suspends (user lowers wrist).
///
/// AUDIO-CLEANUP MANDATE (load-bearing): the original captured audio file
/// AND the multipart-body temp file MUST both be deleted from disk on SUCCESS
/// or FAILURE. Audio path is recovered via `task.taskDescription` in the
/// `didCompleteWithError` delegate; multipart-body path is tracked in
/// `multipartTempFiles`. Both removals run in a single `defer` so a thrown
/// decode/parse error inside the completion handler cannot bypass them.
final class WatchAudioUploader: NSObject, URLSessionDataDelegate {
    static let shared = WatchAudioUploader()
    /// Background URLSession identifier — identity namespace + frozen
    /// `.watch.stt` suffix.
    /// MUST match the identifier passed to `.backgroundTask(.urlSession(...))`
    /// in `ConduckWatchApp.swift`, otherwise the system never wakes the
    /// app for completion delivery.
    static let sessionIdentifier = Constants.identityNamespace + ".watch.stt"

    /// Background URLSession identifier for the agent converse hop
    /// (`POST /v1/chat/completions`). Distinct from `.watch.stt` so STT and
    /// converse deliveries never cross-talk; the delegate routes by session
    /// identity (`session === converseSession`). MUST match the second
    /// `.backgroundTask(.urlSession(...))` handler in `ConduckWatchApp.swift`.
    static let converseSessionIdentifier = Constants.remoteAgentWatchConverseSessionIdentifier

    /// Accumulated response data per task (taskIdentifier → data).
    /// MAIN-CONFINED: mutated from the upload entry points (MainActor — this
    /// class inherits the target's `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`)
    /// and from the delegate callbacks, which BOTH sessions deliver on
    /// `OperationQueue.main` (see the session initializers) — one serial queue
    /// for every access. The iOS counterpart (`BackgroundSTT`) confines on a
    /// private queue instead because it is explicitly `nonisolated`; here the
    /// main queue IS the class's isolation, so it's the correct single queue.
    private var responseData: [Int: Data] = [:]

    /// Multipart-body temp files to clean up after upload completes
    /// (separate from the captured audio file recovered via `taskDescription`).
    /// MAIN-CONFINED — same contract as `responseData` above.
    private var multipartTempFiles: [Int: URL] = [:]

    /// Capture-supersede token per STT task (taskIdentifier → the
    /// `WatchRecordingService.captureGeneration` captured at enqueue).
    /// Consulted by `handleSTTCompletion` so a cancelled capture's transcript
    /// is dropped instead of chaining the converse hop into a thread the
    /// routing pins no longer describe. In-memory only — a task resurrected
    /// across a launch recovers nil and proceeds (no live machine could have
    /// cancelled it). MAIN-CONFINED — same contract as `responseData` above.
    private var sttTaskGenerations: [Int: Int] = [:]

    /// Which background session a `.backgroundTask(.urlSession)` wake targets.
    /// Keys the drain-waiter bookkeeping below — the Watch has TWO background
    /// sessions, unlike the single-session iOS `BackgroundRemoteAgent`.
    enum BackgroundWake {
        case stt
        case converse
    }

    /// Continuation-resumers registered by `handleBackgroundEvents(_:)` (the
    /// two `.backgroundTask(.urlSession)` closures in `ConduckWatchApp`).
    /// Resumed only when the matching session has delivered every queued
    /// delegate callback (`urlSessionDidFinishEvents`) AND every persistence
    /// task those callbacks spawned (reply append / STT→converse chain /
    /// failure surfacing) has completed — the OS may suspend or kill the
    /// process the moment the `.backgroundTask` closure returns, so resuming
    /// at didFinishEvents alone would race the store write. Arrays so two
    /// overlapping wakes can't orphan a continuation. MAIN-CONFINED — mirrors
    /// `BackgroundRemoteAgent.drainWaiters`, which queue-confines instead
    /// because that class is explicitly `nonisolated`.
    private var drainWaiters: [BackgroundWake: [() -> Void]] = [:]

    /// Wakes whose `urlSessionDidFinishEvents` has fired; consumed (removed)
    /// when that wake's drain waiters resume. MAIN-CONFINED.
    private var finishedEvents: Set<BackgroundWake> = []

    /// Count of in-flight persistence tasks spawned by delegate callbacks.
    /// Gates the drain waiters. SHARED across both sessions (one counter, not
    /// per-wake): an STT completion chains converse-enqueue work, so holding
    /// either wake until ALL in-flight persistence lands is the conservative
    /// correct gate. MAIN-CONFINED.
    private var pendingPersistenceCount = 0

    /// Resource timeout for the STT background session. Unlike the converse
    /// session's long-compute budget (a self-hosted LLM legitimately thinks
    /// for minutes), an STT upload that hasn't finished in 5 minutes is dead —
    /// the background default (7 DAYS) parked a wedged upload in `.uploading`
    /// with nothing able to exit it. Generous enough for the Bluetooth→
    /// paired-iPhone relay routing and system-deferred transfers while
    /// suspended. Mirrored by the service's live-app `.uploading` watchdog.
    static let sttResourceTimeout: TimeInterval = 300

    lazy var backgroundSession: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        config.allowsCellularAccess = true
        // Resource timeout only — in background sessions, per-request timeouts
        // are retried internally by the system; the resource clock is the one
        // that reliably terminates a wedged task (delivered as a normal
        // `didCompleteWithError`, routing into the existing failure funnel).
        config.timeoutIntervalForResource = Self.sttResourceTimeout
        // `.main` delegate queue (NOT nil) — `delegateQueue: nil` gave each
        // session its own anonymous serial queue, racing the caller-side
        // `multipartTempFiles`/`responseData` writes (and each other's).
        return URLSession(configuration: config, delegate: self, delegateQueue: .main)
    }()

    /// Background URLSession for the agent converse hop. 300/600 s timeouts
    /// (LOAD-BEARING — self-hosted local-LLM compute on user hardware routinely
    /// takes 1–4 min; the iOS-default 60 s would kill in-flight turns as
    /// "Network Offline" while the gateway is still computing). `sessionSends-
    /// LaunchEvents = true` covers a relaunch when the reply lands after suspend.
    lazy var converseSession: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: Self.converseSessionIdentifier)
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        config.allowsCellularAccess = true
        config.timeoutIntervalForRequest = Constants.remoteAgentConverseRequestTimeout
        config.timeoutIntervalForResource = Constants.remoteAgentConverseResourceTimeout
        // `.main` for the same single-queue confinement as `backgroundSession`.
        return URLSession(configuration: config, delegate: self, delegateQueue: .main)
    }()

    private override init() {
        super.init()
    }

    // MARK: - Background-wake drain bridge (mirrors BackgroundRemoteAgent)

    /// SwiftUI `.backgroundTask(.urlSession(...))` entry — call from the App's
    /// modifier closures. Materializes the wake's lazy session (which
    /// re-attaches the system to our delegate, draining pending callbacks) and
    /// then AWAITS until the drain is complete: `urlSessionDidFinishEvents`
    /// has fired for that session AND every persistence task the callbacks
    /// spawned (reply append / converse-task resume / failure surfacing) has
    /// finished. Returning earlier would let the system suspend/kill the
    /// process mid-append and silently lose the turn — the former interim
    /// 4 s grace sleep approximated this window; the waiter replaces it with
    /// the real signal. Mirrors `BackgroundRemoteAgent.handleBackgroundEvents`,
    /// adapted to this class's MainActor confinement (no private queue).
    func handleBackgroundEvents(_ wake: BackgroundWake) async {
        // Touching the lazy session re-creates the URLSession with our
        // delegate, which is what causes pending delegate callbacks to drain.
        switch wake {
        case .stt: _ = backgroundSession
        case .converse: _ = converseSession
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            drainWaiters[wake, default: []].append { continuation.resume() }
            // didFinishEvents may already have fired (the sessions materialize
            // at App.init on a background relaunch, so the system can replay
            // callbacks before this registration runs) — check immediately.
            resumeDrainWaitersIfReady()
        }
    }

    // MARK: - Drain bookkeeping (main-confined)

    /// Mark one persistence task as started. Called from the delegate
    /// callbacks (main) before they spawn their MainActor persistence Task.
    private func beginPersistenceWork() {
        pendingPersistenceCount += 1
    }

    /// Mark one persistence task as finished and resume drain waiters if the
    /// session has also finished delivering events. Called at the end of the
    /// spawned MainActor Tasks (same confinement — no hop needed).
    private func endPersistenceWork() {
        pendingPersistenceCount -= 1
        resumeDrainWaitersIfReady()
    }

    /// Resume a wake's `.backgroundTask` waiters when (a) the system reported
    /// all of that session's queued callbacks delivered and (b) no persistence
    /// task is still running (shared gate — see `pendingPersistenceCount`).
    ///
    /// FLAG LIFECYCLE: a wake's `finishedEvents` membership is consumed
    /// (removed) here on the resume path — see
    /// `BackgroundRemoteAgent.resumeDrainWaitersIfReady` for the full
    /// rationale. RESIDUAL WINDOW (accepted): a didFinishEvents that fires
    /// with no waiter registered for that wake (launch-time session
    /// materialization in `ConduckWatchApp.init` draining leftover events)
    /// leaves the membership armed, so the NEXT wake's waiter resumes early
    /// once — a one-shot regression to pre-await behavior, never a hang; the
    /// persistence counter still gates in-flight writes.
    private func resumeDrainWaitersIfReady() {
        guard pendingPersistenceCount == 0 else { return }
        for wake in Array(finishedEvents) {
            guard let waiters = drainWaiters[wake], !waiters.isEmpty else { continue }
            finishedEvents.remove(wake)
            drainWaiters[wake] = []
            for waiter in waiters { waiter() }
        }
    }

    // MARK: - Upload: STT

    /// Uploads a pre-built `WatchSTTRequest` via background URLSession.
    /// Completion arrives later in the URLSession delegate, which surfaces
    /// the transcript via a local notification (the foreground UI may be
    /// suspended by then).
    ///
    /// Dispatches on `provider.transport`: multipart providers (Mistral /
    /// OpenAI / ElevenLabs) write the multipart body to a temp file;
    /// JSON providers (Gemini / Qwen) write a JSON body to a temp file.
    /// Either way, the body file URL is tracked in `multipartTempFiles`
    /// for cleanup, and the provider ID is JSON-encoded into
    /// `task.taskDescription` (alongside the audio path) via
    /// `STTBackgroundTaskMetadata` so the delegate can route decode dispatch
    /// even after the app process is recycled.
    ///
    /// NOTE on RAM: JSON-family providers base64-encode audio inline
    /// (~33% inflation). With the 10 MB cap on Qwen and 15 MB on Gemini,
    /// peak working set during body construction is ~20–25 MB. The body
    /// is written straight to disk via `try data.write(...)`, so the
    /// background daemon streams it from disk during upload.
    ///
    /// - Parameters:
    ///   - request: provider-shaped payload (audio + language).
    ///   - audioFileURL: original captured audio file on disk. Tracked via
    ///     `task.taskDescription` so the `didCompleteWithError` delegate can
    ///     recover the path and remove the file on success OR failure
    ///     (audio-cleanup mandate).
    ///   - provider: active STT provider (drives endpoint / auth / transport).
    ///   - generation: capture-supersede token
    ///     (`WatchRecordingService.captureGeneration` at enqueue) — lets the
    ///     completion drop a transcript whose capture was cancelled while the
    ///     daemon finished the upload.
    func uploadSTT(
        request: WatchSTTRequest,
        audioFileURL: URL,
        provider: STTProvider,
        generation: Int
    ) throws {
        guard let apiKey = WatchIdentityResolver.getSTTAPIKey(forPresetID: provider.id) else {
            throw AppError.sttMissingAPIKey
        }

        // Effective transcribe URL — a Gemini per-preset custom override
        // (Feature 1) rewrites the URL-path model here; every other provider
        // returns its fixed `transcribeURL`. The Watch never reaches the BYO
        // `customOpenAICompat` provider on this path (its audio is relayed to
        // iPhone), so the dynamic-base-URL resolution stays iPhone-only.
        var urlRequest = URLRequest(url: provider.effectiveTranscribeURL(customModel: request.customModel))
        urlRequest.httpMethod = "POST"
        provider.auth.apply(to: &urlRequest, apiKey: apiKey)

        let bodyFileURL: URL
        switch provider.transport {
        case .multipart:
            let boundary = UUID().uuidString
            urlRequest.setValue(
                "multipart/form-data; boundary=\(boundary)",
                forHTTPHeaderField: "Content-Type"
            )
            bodyFileURL = try request.writeToFile(boundary: boundary)
        case .json:
            guard let factory = provider.jsonBodyFactory else {
                throw AppError.sttDecodingFailure
            }
            urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
            bodyFileURL = try writeBackgroundJSONBody(
                factory: factory,
                audioData: request.audioData,
                language: request.language,
                model: request.model
            )
        case .inProcess:
            // `.inProcess` is unreachable on the Watch target
            // by construction — Apple `SpeechAnalyzer` isn't available
            // on watchOS, and Apple-active Watch recordings are routed
            // through `AppleSpeechRelayCoordinator` (file
            // relay to iPhone) before this uploader is ever consulted.
            // Defensive throw covers any race where the
            // envelope flips to Apple between recording start and
            // upload dispatch.
            throw AppError.sttProviderUnreachable
        }

        let task = backgroundSession.uploadTask(with: urlRequest, fromFile: bodyFileURL)
        // Cleanup hand-off: the audio path AND provider ID travel with
        // the task. JSON-encoded `STTBackgroundTaskMetadata` survives cross-
        // launch via `taskDescription` (the URLSession daemon preserves it
        // across app process recycles).
        let metadata = STTBackgroundTaskMetadata(
            audioPath: audioFileURL.path,
            providerID: provider.id
        )
        do {
            task.taskDescription = try metadata.encodedString()
        } catch {
            // Couldn't encode metadata — fall back to bare audio path so the
            // delegate can still clean up the audio file (provider lookup
            // will use the default in `STTProvider.lookup(id:)`).
            task.taskDescription = audioFileURL.path
        }
        multipartTempFiles[task.taskIdentifier] = bodyFileURL
        sttTaskGenerations[task.taskIdentifier] = generation
        task.resume()

        WatchLog.note(.stt, "stt.bg.start", ["task": task.taskIdentifier, "provider": provider.id])
    }

    /// Write a JSON-family request body to a temp file for background
    /// URLSession streaming. Mirrors `STTMultipartBuilder.writeBodyFile` for
    /// the multipart family; caller cleans up the returned URL via the
    /// `multipartTempFiles` registry.
    private func writeBackgroundJSONBody(
        factory: STTJSONBodyFactory.Type,
        audioData: Data,
        language: String?,
        model: String
    ) throws -> URL {
        let bodyData = try factory.buildRequestBody(audioData: audioData, language: language, model: model)
        let bodyFileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("stt-json-body-\(UUID().uuidString).json")
        try bodyData.write(to: bodyFileURL)
        return bodyFileURL
    }

    // MARK: - Upload: Converse (agent hop)

    /// Issue the agent converse turn over the background converse session
    /// (`POST /v1/chat/completions`). The user turn is expected to ALREADY be
    /// appended to the store by the caller (so the store is authoritative even
    /// if the reply never lands); this builds the request body, writes it to a
    /// tmp file, stamps `RemoteAgentBackgroundMetadata` onto `taskDescription`
    /// (body path + conversationID + backend, for cross-launch recovery), and
    /// starts the upload. ALWAYS background — never branch on `applicationState`
    /// for the agent hop (a wrist drop mid-think must not cancel the turn).
    ///
    /// Client-owned history: a STATELESS request carrying the FULL trimmed
    /// `messages[]`. No session header, no `conversation` field, no 423/lock path.
    ///
    /// Cleanup: the body tmp file is tracked in `multipartTempFiles` and
    /// removed in the single `defer` of `didCompleteWithError` on every path.
    ///
    /// `stampsActiveConversation` is the resolver's stamping verdict (no
    /// default — single call site, the caller must decide): true for IMPLICIT
    /// (headless / Ask / minted) turns, false for the pinned in-thread
    /// composer, which must not retarget the per-device quick-capture pointer.
    /// Rides `RemoteAgentBackgroundMetadata` so the reply-time stamp survives
    /// a cross-launch process recycle.
    ///
    /// - Throws: `AppError.remoteAgentNotConfigured` if URL/token absent;
    ///   `.remoteAgentInvalidResponse` if metadata/body encoding fails.
    func uploadConverse(
        ref: String,
        url: URL,
        token: String,
        authScheme: RemoteAgentAuthScheme = .bearer,
        model: String?,
        priorTurns: [ConverseRequest.Message],
        newUserText: String,
        conversationID: UUID,
        stampsActiveConversation: Bool
    ) throws {
        let endpoint = url.appending(path: "v1/chat/completions")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = Constants.remoteAgentConverseRequestTimeout
        // `.bearer` sets the header; `.none` (keyless) omits it.
        authScheme.apply(to: &request, token: token)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // The Watch is a SPOKEN surface — the reply is heard aloud / glanced on
        // the wrist — so hardcode `surface: .spoken` HERE (both dictated and
        // typed sends funnel through this one uploader; the clause's wording
        // covers a glanced-or-heard compact surface either way), keeping the
        // spoken clause out of every watch view file. The wrist can't evaluate
        // file-lane readiness itself (the credential never syncs to it), so it
        // reads the iPhone-couriered per-ref value; a ready lane also splices
        // the delivery instruction first (delivery → spoken).
        let fileServerReady = WatchSettingsReader.shared.remoteAgentFileTransferReady(for: ref)

        // `model` is threaded through for customs (built-ins pass nil → the
        // `"model"` key is OMITTED from JSON, byte-identical to today's wire).
        let body = ConverseRequest(
            messages: RemoteAgentClient.assembleMessages(
                priorTurns: priorTurns,
                newUserText: newUserText,
                fileServerReady: fileServerReady,
                surface: .spoken
            ),
            stream: false,
            model: model
        )
        let bodyData = try JSONEncoder().encode(body)

        let bodyURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("conduck-watch-converse-body-\(UUID().uuidString).json")
        try bodyData.write(to: bodyURL, options: [.atomic])

        let metadata = RemoteAgentBackgroundMetadata(
            bodyPath: bodyURL.path,
            conversationID: conversationID.uuidString,
            backendRawValue: ref,
            stampsActiveConversation: stampsActiveConversation
        )
        let metadataString: String
        do {
            metadataString = try metadata.encodedString()
        } catch {
            try? FileManager.default.removeItem(at: bodyURL)
            throw AppError.remoteAgentInvalidResponse
        }

        let task = converseSession.uploadTask(with: request, fromFile: bodyURL)
        task.taskDescription = metadataString
        // Track the body file for cleanup (belt-and-suspenders alongside
        // the `taskDescription` recovery path).
        multipartTempFiles[task.taskIdentifier] = bodyURL
        task.resume()

        WatchLog.note(.converse, "converse.bg.start", ["task": task.taskIdentifier])
    }

    // MARK: - URLSessionDataDelegate

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        var existing = responseData[dataTask.taskIdentifier] ?? Data()
        existing.append(data)
        responseData[dataTask.taskIdentifier] = existing
    }

    /// Server-trust challenge. The converse session pins against the gateway's
    /// stored SPKI fingerprint (self-signed support); the STT session
    /// uses default ATS handling (Mistral/etc. carry publicly-trusted certs).
    ///
    /// Build the evaluator HERE, reading the CURRENT
    /// fingerprint, rather than once in a property initializer. At a cold
    /// ControlWidget launch the in-memory fingerprint was nil until the durable
    /// stores hydrated it (`WatchSettingsReader`); a once-built evaluator would
    /// have captured that nil and failed to pin a self-signed gateway. A fresh
    /// read per challenge always sees the hydrated value (and any rotation).
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        if session === converseSession {
            // The converse session is shared across backends, so resolve
            // the pin for THIS challenge's host (not a single global fingerprint),
            // letting concurrent in-flight turns to different gateways each pin
            // their own self-signed cert.
            let host = challenge.protectionSpace.host
            let fingerprint = WatchSettingsReader.shared.remoteAgentCertFingerprint(forHost: host)
            let evaluator = RemoteAgentTrustEvaluator(pinnedFingerprintHex: fingerprint)
            evaluator.urlSession(session, didReceive: challenge, completionHandler: completionHandler)
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }

    /// System signal that every queued delegate callback for `session` has
    /// been delivered. Flags the matching wake and resumes its
    /// `.backgroundTask` waiters once the spawned persistence work has also
    /// drained. Delivered on `OperationQueue.main` like every callback here.
    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        finishedEvents.insert(session === converseSession ? .converse : .stt)
        resumeDrainWaitersIfReady()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        // Route by session identity: converse vs STT have separate completion
        // paths (different metadata envelope, different persistence + UX).
        if session === converseSession {
            handleConverseCompletion(task: task, error: error)
            return
        }

        let taskID = task.taskIdentifier

        // Capture-supersede token registered at enqueue. Nil for a task
        // resurrected across a launch — the registry died with the process,
        // and nothing live could have cancelled that capture, so it proceeds.
        let generation = sttTaskGenerations.removeValue(forKey: taskID)

        // Recover provider context + audio path from `taskDescription`. JSON-
        // encoded `STTBackgroundTaskMetadata` is the canonical form; the
        // raw-path fallback is the encoding-failure escape hatch from
        // `uploadSTT` (still lets us clean up the audio file even if we
        // can't recover the provider — falls back to `mistralVoxtral`).
        let (audioPath, provider): (String?, STTProvider) = {
            guard let desc = task.taskDescription, !desc.isEmpty else {
                return (nil, .mistralVoxtral)
            }
            if let meta = try? STTBackgroundTaskMetadata.decode(desc) {
                return (meta.audioPath, STTProvider.lookup(id: meta.providerID))
            }
            // Legacy / fallback: raw audio path with no provider info.
            return (desc, .mistralVoxtral)
        }()

        // AUDIO-CLEANUP MANDATE: BOTH temp files (audio + body) are removed
        // in a single `defer`, on success OR failure. A thrown decode error
        // inside `handleSTTCompletion` cannot bypass this.
        defer {
            responseData.removeValue(forKey: taskID)
            if let bodyURL = multipartTempFiles.removeValue(forKey: taskID) {
                try? FileManager.default.removeItem(at: bodyURL)
            }
            if let audioPath, !audioPath.isEmpty {
                try? FileManager.default.removeItem(at: URL(fileURLWithPath: audioPath))
            }
        }

        // Cancel-supersede gate for EVERY outcome of this task — failure
        // branches included: a cancelled capture's late transport error /
        // empty response / HTTP failure must not post a failure notification
        // or take over the machine (which may already be running a NEWER
        // turn — `handleBackgroundFailure`'s nil-conversationID takeover
        // can't disambiguate). Cleanup is owned by the `defer` above either
        // way. Same `.main`-delegate-queue `assumeIsolated` contract as
        // `handleSTTCompletion`.
        if let generation,
           generation != MainActor.assumeIsolated({ WatchRecordingService.shared.captureGeneration }) {
            WatchLog.note(.stt, "stt.bg.dropped", ["reason": "superseded", "provider": provider.id])
            return
        }

        if let error {
            WatchLog.error(.stt, "stt.bg.transport", ["domain": (error as NSError).domain, "code": (error as NSError).code])
            // The same companion-routing trap can sink a direct cloud-STT upload;
            // honest connectivity copy, generic fallback otherwise. STT tasks carry
            // no conversation binding → nil (the funnel still unsticks a live
            // `.uploading` machine).
            surfaceTurnFailure(
                message: WatchNetworkFailureCopy.transportFailureMessage(
                    for: error,
                    fallback: String(localized: "Recording could not be sent. Please try again.")
                ),
                conversationID: nil
            )
            return
        }

        // Parse server response — dispatch by provider transport.
        guard let data = responseData[taskID] else {
            // xcstrings
            surfaceTurnFailure(
                message: String(localized: "No response received from server."),
                conversationID: nil
            )
            return
        }

        // Apply provider's status map if we can read the HTTP status code.
        if let http = task.response as? HTTPURLResponse,
           let mapped = provider.statusMap.map(http.statusCode) {
            WatchLog.error(.stt, "stt.bg.http", ["provider": provider.id, "status": http.statusCode, "code": mapped.errorCode])
            // xcstrings
            surfaceTurnFailure(
                message: String(localized: "Recording could not be sent. Please try again."),
                conversationID: nil
            )
            return
        }

        handleSTTCompletion(data: data, provider: provider, generation: generation)
    }

    // MARK: - Completion Handler

    private func handleSTTCompletion(data: Data, provider: STTProvider, generation: Int?) {
        // Cancel-supersede gate (mirrors `runSTTUpload`'s): the user cancelled
        // this capture while the daemon finished the upload — drop the
        // transcript instead of chaining the converse hop into a thread the
        // routing pins no longer describe. File cleanup is owned by the
        // delegate's `defer` either way. `captureGeneration` is MainActor
        // state; this method runs on the sessions' `.main` delegate queue (the
        // class's confinement contract), so `assumeIsolated` reads it without
        // an async hop — and traps loudly if that contract is ever broken.
        if let generation,
           generation != MainActor.assumeIsolated({ WatchRecordingService.shared.captureGeneration }) {
            WatchLog.note(.stt, "stt.bg.dropped", ["reason": "superseded", "provider": provider.id])
            return
        }
        do {
            let response: STTResponse
            switch provider.transport {
            case .multipart:
                guard let shape = provider.responseShape else {
                    throw AppError.sttDecodingFailure
                }
                response = try STTResponseDecoder.decode(data, shape: shape)
            case .json:
                guard let factory = provider.jsonBodyFactory else {
                    throw AppError.sttDecodingFailure
                }
                response = try factory.decodeResponse(data)
            case .inProcess:
                // Unreachable — `.inProcess` providers never
                // produce a background-URLSession response on the Watch
                // (no network round-trip). The dispatch side rejects
                // these earlier; this arm covers the exhaustiveness
                // requirement only.
                throw AppError.sttDecodingFailure
            }
            let text = response.text

            // Privacy: never log the transcript itself.
            WatchLog.note(.stt, "stt.bg.decoded", ["provider": provider.id, "chars": text.count])

            // STT succeeded in the background. Chain the agent hop instead
            // of surfacing the bare transcript — the Watch is a conversational
            // surface. `startConverseHop` resolves/creates the conversation,
            // appends the user turn, and starts the background converse upload;
            // the converse delegate then appends the agent reply + notifies.
            // (The foreground state machine may already be torn down; the hop is
            // store-backed and notification-driven either way.)
            // Counted as persistence work so the STT wake's `.backgroundTask`
            // closure holds open through user-turn append + converse-task
            // resume — once the converse task is resumed it survives
            // suspension (owned by the system daemon).
            beginPersistenceWork()
            Task { @MainActor in
                await WatchRecordingService.shared.startConverseHop(transcript: text)
                endPersistenceWork()
            }
        } catch {
            // Surface the actual error's message — a 200-empty now decodes to
            // `.noSpeechDetected` ("Didn't catch any speech…") rather than a
            // generic "Could not process response." Covers the suspend→relaunch
            // background path. Privacy: log the stable error code, never content.
            let appError = error as? AppError
            WatchLog.error(.stt, "stt.bg.decode", ["code": appError?.errorCode ?? -1])
            surfaceTurnFailure(
                message: appError?.errorDescription
                    ?? String(localized: "Could not process response."),
                conversationID: nil
            )
        }
    }

    // MARK: - Completion Handler: Converse (agent hop)

    /// Converse-session completion. Mirrors the iOS `BackgroundRemoteAgent`
    /// shape: decode `choices[0].message.content`, append the AGENT reply to the
    /// `ConversationStore`, bump the active-conversation pointer (IMPLICIT
    /// turns only, per the metadata's `stampsActiveConversation` verdict),
    /// post a local notification (≤200 char) + `.success` haptic, and report
    /// the last-successful-turn timestamp to iPhone on success.
    ///
    /// Cleanup: a single `defer` removes the body tmp file on EVERY path
    /// (success / failure / cancel). No 423 / no lock-retry — client-owned
    /// history pins no server session (that case is retired).
    private func handleConverseCompletion(task: URLSessionTask, error: Error?) {
        let taskID = task.taskIdentifier

        // Recover the metadata envelope (body path + conversationID + backend)
        // from `taskDescription` — survives a cross-launch process recycle.
        let metadata: RemoteAgentBackgroundMetadata? = task.taskDescription.flatMap {
            try? RemoteAgentBackgroundMetadata.decode($0)
        }

        // Cleanup mandate (load-bearing): delete the request-body temp
        // file on EVERY exit path — success, failure, OR cancel. Pull both the
        // tracked-registry URL and the metadata path so cleanup works even when
        // the in-memory entry was lost to a relaunch.
        defer {
            responseData.removeValue(forKey: taskID)
            if let bodyURL = multipartTempFiles.removeValue(forKey: taskID) {
                try? FileManager.default.removeItem(at: bodyURL)
            }
            if let bodyPath = metadata?.bodyPath {
                try? FileManager.default.removeItem(atPath: bodyPath)
            }
        }

        // Classify FIRST via the pure `WatchConverseCompletionVerdict` (unit-
        // tested branch ordering: cancel disambiguation → transport → missing
        // response → status map → decode → conversationID), then EXECUTE the
        // verdict below. The registry-presence read for the `.cancelled`
        // disambiguation happens here, BEFORE the `defer` above removes the
        // entry (ordering contract).
        let verdict = WatchConverseCompletionVerdict.make(
            metadata: metadata,
            httpStatus: (task.response as? HTTPURLResponse)?.statusCode,
            body: responseData[taskID],
            transportError: error,
            registryEntryPresent: multipartTempFiles[taskID] != nil
        )

        switch verdict {
        case .cleanupOnly:
            // Live in-process cancel (session teardown) — drop the turn
            // silently: no agent bubble, no notification (cancel is not a
            // failure). The user's turn is already in the store; the defer
            // above still runs the cleanup.
            return

        case .failure(let kind, let conversationID):
            surfaceTurnFailure(
                message: failureMessage(for: kind),
                conversationID: conversationID
            )
            return

        case .reply(let reply, let cid, let stampsActiveConversation):
            // Persist the agent reply, bump the pointer, then (only on a successful
            // append) fire the haptic + notification + reverse-channel turn report.
            // Runs even for headless relaunches (no live foreground state machine).
            // Counted as persistence work so the converse wake's `.backgroundTask`
            // closure holds open until the append + notification land — returning
            // at didFinishEvents alone raced a suspend/kill against the store
            // write (the `defer` covers every exit, incl. the append-failed return).
            beginPersistenceWork()
            Task {
                defer { endPersistenceWork() }
                // Capture the appended message id so the auto-speak verdict can
                // stage the EXACT reply (id + text) — the open thread then speaks
                // this reply rather than re-deriving the latest agent bubble from a
                // not-yet-refreshed array (the follow-up stale-read bug).
                let appendedID: UUID
                do {
                    appendedID = try await ConversationStore.shared.appendMessage(
                        role: "agent",
                        text: reply,
                        conversationID: cid,
                        sourceDevice: "watch"
                    ).id
                } catch {
                    // Append failed (e.g. the conversation was deleted on another
                    // device mid-flight). Don't claim success.
                    WatchLog.error(.converse, "converse.bg.appendFail")
                    surfaceTurnFailure(
                        message: String(localized: "Couldn't read the reply from your personal AI."),
                        conversationID: cid
                    )
                    return
                }

                // Reply-time pointer refresh — IMPLICIT turns only (the resolver's
                // verdict rides the metadata). Old in-flight blobs decode nil →
                // no stamp: the pre-hop stamp already ran for implicit turns, so
                // one missed reply-time refresh is benign (the TTL window just
                // isn't extended by this reply).
                if stampsActiveConversation {
                    WatchSettingsReader.shared.recordActiveConversation(cid)
                }

                // Success haptic (best-effort; app may still be suspended).
                await MainActor.run {
                    WKInterfaceDevice.current().play(.success)
                    WatchRecordingService.shared.handleBackgroundReply(reply, conversationID: cid, messageID: appendedID)
                }

                // Reverse channel to the iPhone — Diagnostics reads it as
                // the Watch-turn recency. This is the SINGLE success funnel: every
                // Watch turn (voice, typed, Ask, deferred relay drain) resolves
                // through this converse completion, so the one call here covers
                // them all. A future reply path that bypasses the uploader must
                // call `reportSuccessfulTurn()` itself or the phone undercounts.
                WatchSessionManager.shared.reportSuccessfulTurn()

                // Local reply notification (≤200 char body). In a multi-gateway
                // setup (≥2 configured) the title names the bound gateway so the
                // wrist banner says which agent answered; else the generic string.
                let replyTitle: String = {
                    guard WatchSettingsReader.shared.configuredBackendRefs().count >= 2,
                          let raw = metadata?.backendRawValue,
                          let ref = RemoteAgentRef(rawString: raw) else {
                        return String(localized: "Reply from your personal AI")  // xcstrings
                    }
                    return RemoteAgentRefMetadata.displayName(
                        for: ref,
                        customs: WatchSettingsReader.shared.customGateways
                    )
                }()
                postNotification(
                    title: replyTitle,
                    body: String(reply.prefix(200)),
                    conversationID: cid,
                    backendRef: metadata?.backendRawValue
                )
            }
        }
    }

    /// Copy + forensics for a classified converse failure — the execution half
    /// of `WatchConverseCompletionVerdict.FailureKind`. The verdict stays pure;
    /// the localized strings and the per-branch log lines live here.
    private func failureMessage(for kind: WatchConverseCompletionVerdict.FailureKind) -> String {
        switch kind {
        case .transport(let error):
            WatchLog.error(.converse, "converse.bg.transport", ["domain": (error as NSError).domain, "code": (error as NSError).code])
            // Honest connectivity copy (incl. the watchOS companion-routing trap:
            // a nearby powered-on iPhone with no internet sinks the Watch's own
            // request — see WatchNetworkFailureCopy). Non-connectivity transport
            // errors keep the generic fallback.
            return WatchNetworkFailureCopy.transportFailureMessage(
                for: error,
                fallback: String(localized: "Couldn't reach your personal AI. Try again.")
            )
        case .cancelledAcrossLaunch, .missingHTTPResponse:
            return String(localized: "Couldn't reach your personal AI. Try again.")
        case .httpStatus(let status):
            WatchLog.error(.converse, "converse.bg.http", ["status": status])
            return String(localized: "Couldn't reach your personal AI. Try again.")
        case .undecodableReply:
            return String(localized: "Couldn't read the reply from your personal AI.")
        case .noConversationID:
            // anti-phantom-reply: a decoded reply with no home (metadata
            // decode failed) surfaces a soft failure instead of a success
            // notification for a turn that isn't in any thread.
            WatchLog.error(.converse, "converse.bg.noConvID")
            return String(localized: "Couldn't reach your personal AI. Try again.")
        }
    }

    // MARK: - Failure funnel

    /// Surface a failed background turn BOTH ways: route it into the live
    /// `WatchRecordingService` state machine (mirroring how
    /// `handleBackgroundReply` lands successes) AND post the notification.
    /// Load-bearing for the foreground case: `WatchNotificationDelegate`
    /// suppresses ALL foreground banners, so without the state transition a
    /// user watching the live "Thinking…" spinner gets ZERO feedback and
    /// `.waiting` persists until pop/relaunch (the 600 s stale-guard only runs
    /// on restore-from-idle). `conversationID` nil = unmatchable turn (STT
    /// tasks / a failed metadata decode) — the service still transitions a
    /// live waiting/uploading machine, it just can't conversation-match.
    private func surfaceTurnFailure(message: String, conversationID: UUID?) {
        // Counted as persistence work so a background wake's `.backgroundTask`
        // closure holds open until the failure lands in the live state machine.
        beginPersistenceWork()
        Task { @MainActor in
            WatchRecordingService.shared.handleBackgroundFailure(message, conversationID: conversationID)
            endPersistenceWork()
        }
        postNotification(title: String(localized: "Conduck"), body: message)
    }

    // MARK: - Notifications

    /// `conversationID` / `backendRef` (both optional) are stamped into
    /// `content.userInfo` so a TAP on a suspended-reply banner can deep-link into
    /// the exact thread (`WatchNotificationDelegate.didReceive` →
    /// `WatchReplyDeepLinkCoordinator`). Failure notifications pass nil (no thread
    /// to open). The keys are read back in `ConduckWatchApp`.
    static let notificationConversationIDKey = "conduck.notification.conversationID"
    static let notificationBackendRefKey = "conduck.notification.backendRef"

    private func postNotification(
        title: String,
        body: String,
        conversationID: UUID? = nil,
        backendRef: String? = nil
    ) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        var userInfo: [String: Any] = [:]
        if let conversationID {
            userInfo[Self.notificationConversationIDKey] = conversationID.uuidString
        }
        if let backendRef {
            userInfo[Self.notificationBackendRefKey] = backendRef
        }
        if !userInfo.isEmpty {
            content.userInfo = userInfo
        }

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request)
    }
}
