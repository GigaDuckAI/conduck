// Conduck
// STTClient+Background.swift
//
// Background URLSession path for STT uploads, with per-provider dispatch via
// the `STTProvider` value type. Cross-
// launch survival: the provider ID rides in `task.taskDescription` as a
// JSON-encoded `STTBackgroundTaskMetadata` envelope so the delegate can
// recover both the audio path (for cleanup) and the status-map / decoder
// dispatch when the system relaunches us after a kill.
//
// Used by call sites that need to survive process suspension during upload
// (Shortcuts-process kill, deferred notification window). The Shortcut-entry
// path (`TranscribeIntent`) defaults to the foreground method because
// Shortcuts' ~30 s suspension budget comfortably fits the typical clip +
// round-trip — this background path is the explicit opt-in fallback for
// longer clips, risk-averse callers, and the Watch surface.
//
// Audio cleanup mandate (load-bearing): the URLSession delegate
// MUST `FileManager.removeItem(at:)` the audio file on BOTH success and
// failure paths. Recovery path: `task.taskDescription = <JSON metadata>`
// is set at upload-site so the delegate can rebuild the URL + recover the
// provider ID without holding a captured reference.
//
// Manager wires `ConduckApp.backgroundTask(.urlSession(...))` to
// `BackgroundSTT.shared.handleBackgroundCompletion(events:)`.

import Foundation

/// Background URLSession singleton + delegate for STT uploads.
///
/// Trust note (Custom STT, Feature 2): the shared background session cannot
/// carry a per-request delegate, so server-trust pinning for the BYO custom
/// endpoint is host-scoped inside the task-level
/// `urlSession(_:task:didReceive:)` challenge handler — it pins ONLY when the
/// challenge host matches the stored custom base-URL host AND the task's
/// recovered `STTBackgroundTaskMetadata.pinnedFingerprintHex` is non-nil. Every
/// other host (the 5 cloud providers) → `performDefaultHandling`, so cloud STT
/// is completely unaffected. The `dynamicEndpointKey == nil` invariant (cloud
/// never carries a pin) is protected by a test.
/// Lives outside the `STTClient` actor because URLSession delegate methods
/// are nonisolated by contract; running them through an actor would require
/// wrapping every callback. Explicitly `nonisolated` so the Swift 6 default
/// MainActor isolation in this module doesn't infect the delegate callbacks.
nonisolated final class BackgroundSTT: NSObject, @unchecked Sendable {
    static let shared = BackgroundSTT()

    /// Background URLSession identifier — identity namespace + frozen `.stt`
    /// suffix. Single-sourced: `ConduckApp.backgroundTask(.urlSession(...))`
    /// references THIS constant, so system-relaunch events always route back here.
    static let sessionIdentifier = Constants.identityNamespace + ".stt"

    /// Outstanding upload continuations keyed by `URLSessionTask.taskIdentifier`.
    /// Resumed exactly once by `urlSession(_:task:didCompleteWithError:)`.
    private var pendingContinuations: [Int: CheckedContinuation<STTResponse, Error>] = [:]

    /// Response data accumulator per task, in case the delegate splits the
    /// payload across multiple `didReceive data:` callbacks. Cleared by the
    /// completion callback after consumption.
    private var responseBuffers: [Int: Data] = [:]

    /// Body file URLs keyed by task identifier. Cleaned up alongside the
    /// audio file in `urlSession(_:task:didCompleteWithError:)`.
    fileprivate var bodyURLs: [Int: URL] = [:]

    /// Continuation-resumers registered by `handleBackgroundEvents()` (the
    /// SwiftUI `.backgroundTask(.urlSession)` closure) — resumed by
    /// `urlSessionDidFinishEvents(forBackgroundURLSession:)` once all queued
    /// delegate callbacks have drained, so the closure's `await` holds the
    /// process alive through the drain (incl. the audio-cleanup defer)
    /// instead of returning immediately and racing a suspend/kill.
    /// Queue-confined; array so overlapping wakes can't orphan a continuation.
    private var drainWaiters: [() -> Void] = []

    /// Set by `urlSessionDidFinishEvents`; consumed (reset) when the drain
    /// waiters resume. Covers the race where the system finishes replaying
    /// callbacks before `handleBackgroundEvents()` registers its waiter.
    /// Queue-confined.
    private var didFinishBackgroundEvents = false

    private let queue = DispatchQueue(label: Constants.identityNamespace + ".stt.bg")

    fileprivate lazy var session: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        config.sessionSendsLaunchEvents = true
        config.isDiscretionary = false
        // Raised to the shared 300/600 s ceiling (was 120/240) so a self-hosted
        // Whisper on modest hardware (the BYO custom endpoint) has headroom.
        // SAFE for cloud STT: a higher ceiling never slows a fast upload — it
        // only widens the worst-case window before a stuck request gives up.
        config.timeoutIntervalForRequest = Constants.customSTTRequestTimeout
        config.timeoutIntervalForResource = Constants.customSTTRequestTimeout * 2

        let opQueue = OperationQueue()
        opQueue.maxConcurrentOperationCount = 1
        opQueue.underlyingQueue = queue
        return URLSession(configuration: config, delegate: self, delegateQueue: opQueue)
    }()

    private override init() {
        super.init()
    }

    /// SwiftUI `.backgroundTask(.urlSession(...))` entry — call from the
    /// App's modifier closure. Materializes the lazy session (which
    /// re-attaches the system to our delegate) and AWAITS the drain:
    /// `urlSessionDidFinishEvents` resumes the registered waiter once every
    /// queued callback (response decode, continuation resume, audio/body
    /// cleanup) has been delivered. Returning before that point let the
    /// system suspend/kill the process mid-drain (the wake-handler race).
    func handleBackgroundEvents() async {
        // Touching `session` re-creates the URLSession with our delegate,
        // which is what causes pending delegate callbacks to drain.
        _ = session
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                self.drainWaiters.append { continuation.resume() }
                self.resumeDrainWaitersIfReady()
            }
        }
    }

    /// Resume the `.backgroundTask` waiters once the system reported all
    /// queued callbacks delivered. MUST be called on `queue`.
    ///
    /// FLAG LIFECYCLE: `didFinishBackgroundEvents` is consumed (reset) here on
    /// the resume path — see `BackgroundRemoteAgent.resumeDrainWaitersIfReady`
    /// for the full rationale. RESIDUAL WINDOW (accepted): a didFinishEvents
    /// that fires with no waiter registered (launch-time materialization
    /// draining leftovers) leaves the flag armed, so the NEXT wake's waiter
    /// resumes early once — a one-shot regression to pre-await behavior,
    /// never a hang.
    fileprivate func resumeDrainWaitersIfReady() {
        guard didFinishBackgroundEvents, !drainWaiters.isEmpty else { return }
        didFinishBackgroundEvents = false
        let waiters = drainWaiters
        drainWaiters = []
        for waiter in waiters { waiter() }
    }

    /// Mark the event stream drained (called by the delegate extension below).
    /// MUST be called on `queue`.
    fileprivate func markBackgroundEventsFinished() {
        didFinishBackgroundEvents = true
        resumeDrainWaitersIfReady()
    }
}

extension STTClient {
    /// Background-session upload variant. Returns via URLSessionDelegate
    /// bridged through a `CheckedContinuation`. Audio file at `audioFileURL`
    /// is owned by the call site through to delegate completion; the
    /// delegate cleans up on success OR failure.
    ///
    /// - Parameters:
    ///   - audioFileURL: path to the audio file on disk (M4A AAC).
    ///   - apiKey: bearer / header value for the STT provider.
    ///   - language: optional ISO 639-1 hint (e.g., "en", "de"); nil = auto-detect.
    ///   - provider: the STT provider (wire format, auth, caps, decoder).
    ///   - customModel: optional per-preset model override (Feature 1); nil →
    ///     the provider's pinned default.
    ///   - customConfig: fully-resolved BYO-endpoint config — non-nil ONLY for
    ///     the custom provider. Carries the resolved transcribe URL, effective
    ///     auth scheme, and optional cert pin (the pin rides into
    ///     `STTBackgroundTaskMetadata` so the shared-session delegate can
    ///     host-scope it at challenge time). Nil for the 6 frozen providers.
    /// - Returns: `STTResponse` with transcribed text and (optional) language.
    /// - Throws: `AppError` — same taxonomy as foreground `transcribe(...)`.
    func transcribeBackground(
        audioFileURL: URL,
        apiKey: String,
        language: String?,
        provider: STTProvider,
        customModel: String? = nil,
        customConfig: CustomSTTConfig? = nil
    ) async throws -> STTResponse {
        // Pre-flight: size guard avoids burning the upload for a payload
        // the provider would reject anyway. We do NOT read the bytes into
        // memory here — `uploadTask(with:fromFile:)` requires file URL
        // for background sessions.
        let fileSize: Int
        do {
            let attrs = try FileManager.default.attributesOfItem(atPath: audioFileURL.path)
            fileSize = (attrs[.size] as? Int) ?? 0
        } catch {
            throw AppError.audioMissingData
        }

        guard fileSize > 0 else {
            throw AppError.audioMissingData
        }
        guard fileSize <= provider.maxAudioBytes else {
            // Clean up the oversized file before throwing — caller can't
            // satisfy our cleanup contract since we never created a task.
            try? FileManager.default.removeItem(at: audioFileURL)
            throw AppError.audioTooLarge
        }

        // Resolve the effective model + transcribe URL once (mirrors the
        // foreground path). The BYO custom provider's model comes from its OWN
        // dedicated config field (`customConfig.model`); the 6 frozen providers
        // use the generic per-preset override → default. Declarative dispatch
        // off `dynamicEndpointKey`: the custom provider targets the user's
        // stored base URL (carried in `customConfig.url`); Gemini rebuilds the
        // URL for a model override; every other provider keeps `transcribeURL`.
        let effModel = customConfig?.model ?? provider.effectiveModel(customModel: customModel)
        let effURL: URL
        if provider.dynamicEndpointKey != nil {
            guard let resolved = customConfig?.url else {
                try? FileManager.default.removeItem(at: audioFileURL)
                throw AppError.sttCustomEndpointNotConfigured
            }
            effURL = resolved
        } else {
            effURL = provider.effectiveTranscribeURL(customModel: customModel)
        }

        // Build the request body file on disk — background uploads must use
        // file URLs, not in-memory Data. Branch on transport.
        let bodyFileURL: URL
        var request = URLRequest(url: effURL)
        request.httpMethod = "POST"

        switch provider.transport {
        case .multipart:
            guard let fields = provider.multipartFieldNames else {
                try? FileManager.default.removeItem(at: audioFileURL)
                throw AppError.sttDecodingFailure
            }
            let boundary: String
            do {
                let result = try STTMultipartBuilder.writeBodyFile(
                    audioFileURL: audioFileURL,
                    audioMIME: "audio/mp4",
                    audioFilename: "audio.m4a",
                    model: effModel,
                    language: language,
                    fieldNames: fields
                )
                boundary = result.boundary
                bodyFileURL = result.bodyFileURL
            } catch {
                try? FileManager.default.removeItem(at: audioFileURL)
                throw AppError.audioMissingData
            }
            request.setValue(
                "multipart/form-data; boundary=\(boundary)",
                forHTTPHeaderField: "Content-Type"
            )

        case .json:
            guard let factory = provider.jsonBodyFactory else {
                try? FileManager.default.removeItem(at: audioFileURL)
                throw AppError.sttDecodingFailure
            }
            do {
                bodyFileURL = try Self.writeBackgroundJSONBody(
                    audioFileURL: audioFileURL,
                    language: language,
                    model: effModel,
                    factory: factory
                )
            } catch {
                try? FileManager.default.removeItem(at: audioFileURL)
                throw AppError.audioMissingData
            }
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        case .inProcess:
            // `.inProcess` providers (Apple on-device) have
            // no background-URLSession pathway — transcription runs
            // synchronously in-process via `AppleSpeechRunner`.
            // Reaching the background path means a caller routed
            // an Apple-active recording through the wrong dispatcher;
            // clean up + surface model-missing as the canonical error.
            try? FileManager.default.removeItem(at: audioFileURL)
            throw AppError.appleSpeechModelNotInstalled
        }

        // Apply the EFFECTIVE auth scheme — the custom provider uses
        // `customConfig.auth` (`.bearer` / `.none`), every frozen provider its
        // own `provider.auth`.
        let effAuth = customConfig?.auth ?? provider.auth
        effAuth.apply(to: &request, apiKey: apiKey)

        // Encode the recovery envelope for `task.taskDescription` so the
        // delegate can clean up the audio path, recover the provider status-map
        // / decoder dispatch, AND (custom endpoint only) recover the pinned
        // fingerprint at server-trust-challenge time after a cross-launch
        // resume. The pin is written ONLY for the custom provider — frozen
        // providers carry `nil` so the shared-session delegate's host-scope
        // check never pins a cloud host.
        let metadata = STTBackgroundTaskMetadata(
            audioPath: audioFileURL.path,
            providerID: provider.id,
            pinnedFingerprintHex: provider.dynamicEndpointKey != nil ? customConfig?.certFingerprint : nil
        )
        let metadataString: String
        do {
            metadataString = try metadata.encodedString()
        } catch {
            try? FileManager.default.removeItem(at: audioFileURL)
            try? FileManager.default.removeItem(at: bodyFileURL)
            throw AppError.sttDecodingFailure
        }

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<STTResponse, Error>) in
            let task = BackgroundSTT.shared.session.uploadTask(with: request, fromFile: bodyFileURL)
            // Audio-cleanup recovery: the delegate uses `taskDescription`
            // to rebuild the path + provider so cleanup + decoder dispatch
            // work even after a process relaunch (where in-memory captures
            // would be gone).
            task.taskDescription = metadataString
            BackgroundSTT.shared.register(
                continuation: continuation,
                taskIdentifier: task.taskIdentifier,
                bodyFileURL: bodyFileURL
            )
            task.resume()
        }
    }

    /// Build a JSON body via the provider's factory and write it to a temp
    /// file (background uploads require a file URL, not in-memory Data).
    /// Returns the body file URL — caller / delegate owns cleanup. `model` is
    /// the resolved effective model tag (per-preset override → default).
    private static func writeBackgroundJSONBody(
        audioFileURL: URL,
        language: String?,
        model: String,
        factory: STTJSONBodyFactory.Type
    ) throws -> URL {
        let audioData = try Data(contentsOf: audioFileURL)
        let body = try factory.buildRequestBody(audioData: audioData, language: language, model: model)

        let bodyURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("conduck-stt-body-\(UUID().uuidString).bin")
        try body.write(to: bodyURL, options: [.atomic])
        return bodyURL
    }
}

// MARK: - BackgroundSTT continuation registry + URLSession delegate

extension BackgroundSTT: URLSessionDataDelegate {
    fileprivate func register(
        continuation: CheckedContinuation<STTResponse, Error>,
        taskIdentifier: Int,
        bodyFileURL: URL
    ) {
        queue.async {
            self.pendingContinuations[taskIdentifier] = continuation
            self.responseBuffers[taskIdentifier] = Data()
            self.bodyURLs[taskIdentifier] = bodyFileURL
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let id = dataTask.taskIdentifier
        queue.async {
            self.responseBuffers[id, default: Data()].append(data)
        }
    }

    /// TASK-level server-trust challenge handler — host-scoped pinning for the
    /// BYO custom STT endpoint. The shared background session serves all 6+
    /// network providers, so pinning MUST be host-scoped: pin ONLY when the
    /// challenge host matches the stored custom base-URL host AND the task's
    /// recovered metadata carries a pin. Every other host (the 5 cloud
    /// providers) → `performDefaultHandling`, leaving cloud STT on default ATS,
    /// completely unaffected. The actual SHA-256 leaf-cert compare is delegated
    /// to a `RemoteAgentTrustEvaluator` (reused verbatim).
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        // Only server-trust challenges go through the pinning path. Anything
        // else (client-cert / HTTP-auth) → default handling.
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        // Recover the task's pin from `taskDescription`. nil pin (the 5 cloud
        // providers, or an unpinned custom endpoint) → default handling.
        let pin = task.taskDescription
            .flatMap { try? STTBackgroundTaskMetadata.decode($0) }?
            .pinnedFingerprintHex
        guard let pin, !pin.isEmpty else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        // Host-scope the pin: it applies ONLY to the configured custom STT
        // host. If the challenge is for any other host (defensive — should be
        // impossible since the pin only rides custom-endpoint tasks), fall
        // through to default handling rather than pinning the wrong host. The
        // custom base-URL host is read straight from App Group defaults (the
        // delegate is nonisolated and can't `await` the actor) — mirrors
        // `BackgroundRemoteAgent`'s defaults-read trust posture.
        let defaults = UserDefaults(suiteName: Constants.appGroupID) ?? .standard
        guard
            let baseURLString = defaults.string(forKey: Constants.customSTTURLKey),
            let customHost = URL(string: baseURLString)?.host(percentEncoded: false),
            challenge.protectionSpace.host == customHost
        else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        // Delegate the actual SPKI SHA-256 compare to the generic evaluator
        // (reused verbatim). It pins (match → useCredential; mismatch → cancel)
        // because a non-nil pin was recovered above.
        let evaluator = RemoteAgentTrustEvaluator(pinnedFingerprintHex: pin)
        evaluator.urlSession(session, didReceive: challenge, completionHandler: completionHandler)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let id = task.taskIdentifier

        // Recover the metadata envelope from `taskDescription`. May be nil if
        // an older/foreign task somehow lands here; in that case we degrade
        // gracefully (no audio cleanup, mistralVoxtral fallback for decode).
        let metadata: STTBackgroundTaskMetadata? = task.taskDescription.flatMap {
            try? STTBackgroundTaskMetadata.decode($0)
        }

        // Audio-cleanup mandate (load-bearing): delete the audio AND the
        // multipart/json body file on EVERY exit path — success or failure.
        if let audioPath = metadata?.audioPath {
            try? FileManager.default.removeItem(atPath: audioPath)
        }

        let provider: STTProvider = metadata
            .map { STTProvider.lookup(id: $0.providerID) }
            ?? .mistralVoxtral

        queue.async {
            if let bodyURL = self.bodyURLs.removeValue(forKey: id) {
                try? FileManager.default.removeItem(at: bodyURL)
            }

            guard let continuation = self.pendingContinuations.removeValue(forKey: id) else {
                self.responseBuffers.removeValue(forKey: id)
                return
            }

            let buffered = self.responseBuffers.removeValue(forKey: id) ?? Data()

            if let error {
                if let urlError = error as? URLError {
                    let isCustomEndpoint = provider.dynamicEndpointKey != nil
                    switch urlError.code {
                    case .notConnectedToInternet, .networkConnectionLost:
                        continuation.resume(throwing: AppError.noInternetConnection)
                    case .timedOut:
                        continuation.resume(throwing: AppError.requestTimeout)
                    case .serverCertificateUntrusted where isCustomEndpoint,
                         .serverCertificateHasBadDate where isCustomEndpoint,
                         .serverCertificateHasUnknownRoot where isCustomEndpoint,
                         .serverCertificateNotYetValid where isCustomEndpoint:
                        // Custom-endpoint pin mismatch (the delegate cancelled
                        // the challenge) surfaces as one of these SPECIFIC
                        // server-certificate codes. Cloud providers never pin →
                        // fall to default `.networkError`. The GENERIC
                        // `.secureConnectionFailed` is deliberately excluded: it
                        // also fires for transient cold-tunnel hiccups, so it
                        // falls through to the retryable `.networkError`.
                        continuation.resume(throwing: AppError.sttCustomCertMismatch)
                    default:
                        continuation.resume(throwing: AppError.networkError(urlError))
                    }
                } else {
                    continuation.resume(throwing: AppError.networkError(error))
                }
                return
            }

            // Map HTTP status → AppError via the recovered provider's status
            // map (load-bearing: Mistral 429 = billing-fatal, OpenAI 429 =
            // transient — never collapse).
            guard let http = task.response as? HTTPURLResponse else {
                continuation.resume(throwing: AppError.invalidResponse)
                return
            }

            if let mapped = provider.statusMap.map(http.statusCode) {
                continuation.resume(throwing: mapped)
                return
            }

            // 2xx — decode by transport.
            do {
                let response: STTResponse
                switch provider.transport {
                case .multipart:
                    guard let shape = provider.responseShape else {
                        continuation.resume(throwing: AppError.sttDecodingFailure)
                        return
                    }
                    response = try STTResponseDecoder.decode(buffered, shape: shape)
                case .json:
                    guard let factory = provider.jsonBodyFactory else {
                        continuation.resume(throwing: AppError.sttDecodingFailure)
                        return
                    }
                    response = try factory.decodeResponse(buffered)
                case .inProcess:
                    // Unreachable on the background-decode
                    // path — `.inProcess` providers never produce a
                    // URLSession response. Defensive resume covers the
                    // exhaustiveness requirement only.
                    continuation.resume(throwing: AppError.sttDecodingFailure)
                    return
                }
                continuation.resume(returning: response)
            } catch let appError as AppError {
                continuation.resume(throwing: appError)
            } catch {
                continuation.resume(throwing: AppError.sttDecodingFailure)
            }
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        queue.async {
            self.markBackgroundEventsFinished()
        }
    }
}
