// SPDX-License-Identifier: Apache-2.0

//
//  BackgroundFileTransfer.swift
//  Conduck
//
//  Background URLSession driver for agent file transfer (upload / download /
//  probe / delete) against the user-run WebDAV file-server.
//
//  WHY a dedicated background session (separate from the converse session):
//  a multi-MB PUT/GET can take far longer than a chat completion and must
//  survive app suspension. iOS keeps a background URLSession alive across
//  suspension and relaunches the app (via ConduckApp's 4th .backgroundTask
//  handler) to deliver the result. We never reuse the converse session because
//  its short timeouts and data-task shape don't fit large file bodies.
//
//  STRUCTURE (cloned from BackgroundRemoteAgent):
//   - one shared URLSession built from a background configuration (iOS) or a
//     default configuration (macOS — desktop apps don't relaunch headlessly)
//   - an in-flight registry keyed by URLSessionTask.taskIdentifier
//   - each entry holds the snapshot (for the trust challenge), the per-task
//     onProgress closure (uploads), and the CheckedContinuation to resume
//   - urlSession(_:task:didSendBodyData:...) forwards upload progress
//   - urlSession(_:downloadTask:didFinishDownloadingTo:) moves the body to a
//     caller-owned temp URL before the system reclaims it
//   - urlSession(_:task:didCompleteWithError:) resumes the continuation
//   - urlSession(_:task:didReceive:) (challenge) routes to
//     RemoteAgentTrustEvaluator with the pin stamped onto the TASK at enqueue
//     (FileTransferBackgroundMetadata.pinnedFingerprintHex), applied host-blind
//     so a cross-origin redirect target must present the pinned key, and records
//     the evaluator's OWN verdicts in the per-task registry
//     (trustSignalsByTaskID) — the same shape CarPlayConverseUploader and
//     BackgroundRemoteAgent use, and the only way didCompleteWithError can tell
//     an untrusted CHAIN from a pinned KEY that disagreed from a key that cannot
//     be fingerprinted, once URLSession has flattened all three into a bare -999
//   - urlSession(_:task:willPerformHTTPRedirection:) refuses a cross-origin 3xx
//     — a real veto on macOS (.default session), never delivered on iOS
//     (background sessions always follow redirects)
//   - a stored completion handler bridges the .backgroundTask system callback
//
//  POLICY: fail-fast — NO auto-retry. A suspended background
//  uploadTask does not resume; the staged item + visible Retry control own
//  retry, not this driver.
//
//  ONE carve-out (NOT a retry budget): a nested-PUT 409 (missing parent
//  collection, RFC 4918 §9.7 — WebDAV never auto-creates it on PUT) triggers a
//  single MKCOL + one re-PUT. That is the WebDAV create-parent handshake
//  completing — a protocol step the server forces mid-transfer — not a retry of
//  a failed upload. Only 409 qualifies (405 = target is a collection / method
//  disallowed, which MKCOL cannot fix); everything else stays fail-fast. Same
//  lifecycle envelope as the relaunched-process drop below: the handshake is
//  guaranteed while the process executes, PAUSES across app suspension (resumes
//  on next foreground), and is NOT recoverable after process death.
//
//  THE STRICT LISTING LANE (`listCollection`) is the one lane whose answer
//  nothing downstream corrects — an entry it returns becomes a download chip the
//  user taps. So it runs on the ephemeral cert-pinned session and reads THAT
//  session's evaluator (a refused certificate must not degrade into "host is
//  down" — see `FileServerClient`'s header for the rule that governs every such
//  lane), bounds the body it will read, and requires the lane to answer a
//  sibling collection that cannot exist with a definite miss before any entry is
//  believed. The pure verdict rules live in `FileServerClient.parseListing`.
//
//  THE PRE-DISPATCH ABSENCE ASSERTION (`witnessCollectionAbsent`) is the only
//  thing this driver does BEFORE a turn is sent, as opposed to the uploads that
//  stage a turn's own attachments. Conduck NAMES the folder a reply's files go
//  in and creates nothing — an agent-created directory is owned by the agent,
//  and that is precisely what makes it writable — so the freshness evidence is a
//  `PROPFIND Depth: 0` that must come back `404`. It fails closed on every other
//  answer, and anything but `404` means this turn goes out without a location
//  line. Because every send waits on it — a pure-text turn included — it runs on
//  its own short deadline and reads no response body at all: the verdict is the
//  status line, and a probe the user never asked for must not be able to hold up
//  a turn or stream a login page into memory.
//
//  ITS ANSWER IS A TAXONOMY, NOT A BOOL (`FileServerAbsenceWitness`), and
//  `mintOutboxKey` turns it into an `OutboxMintOutcome` the caller can act on.
//  A lane that cannot return files at all and a lane that has gone dark both
//  produce no folder, but only the second is worth telling anyone about — and
//  the second must stop being probed once it has proved itself dark, which is
//  what `FileLaneWitnessBreaker` at the foot of this file bounds. Both types
//  carry their whole rationale in their own headers.
//
//  THE WITNESS NEVER DECIDES THE FIRST OF THOSE, and that is a rule rather than
//  an omission. It can only ever ask about the collection this turn is about to
//  name, which by construction is NOT THERE — that is the whole point of the
//  assertion — so a `405`/`501` from it is a fact about the route a missing path
//  is served by and not about the method the server performs. A path-scoped
//  `dav_methods` rule, a WAF, an SSO layer and a rewrite all produce exactly
//  that on a server that lists existing collections perfectly, and
//  `FileServerClient.probeListingCapability` refuses the same inference on the
//  same request for the same reason. The durable "this lane cannot list" verdict
//  therefore has ONE author, the staged Test Connection, which asks the served
//  root — a collection that certainly exists; `mintOutboxKey` reads that
//  persisted verdict and never writes one.
//
//  PRIVACY: never log URLs, tokens, credentials, storedKeys,
//  filenames, or reply bytes. Never reveal the credential in a thrown error.
//

import Foundation

/// Thread-safe bridge from Swift task cancellation to the URLSession task that
/// is created later on the transfer queue. Kept internal as the focused
/// lifecycle test seam.
///
/// The relay deliberately has NO access to the transfer continuation or the
/// `inFlight` registry. Cancellation can only cancel the underlying task; the
/// URLSession delegate's terminal callback remains the sole owner of registry
/// removal + continuation resume.
nonisolated final class BackgroundTransferCancellationRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var cancellationAction: (@Sendable () -> Void)?
    private var cancelled = false
    private var terminalClaimed = false

    /// Install the underlying-task cancellation. Returns false when the parent
    /// task was already cancelled, in which case the caller must not start I/O.
    func install(_ action: @escaping @Sendable () -> Void) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled else { return false }
        cancellationAction = action
        return true
    }

    func cancel() {
        let action: (@Sendable () -> Void)?
        lock.lock()
        if cancelled {
            action = nil
        } else {
            cancelled = true
            action = cancellationAction
            cancellationAction = nil
        }
        lock.unlock()
        action?()
    }

    /// Claim the delegate-owned terminal completion exactly once. The
    /// `inFlight` removal already makes duplicate URLSession callbacks harmless;
    /// this second, focused gate locks the continuation contract independently
    /// and gives lifecycle tests a deterministic seam.
    func claimTerminalCompletion() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !terminalClaimed else { return false }
        terminalClaimed = true
        cancellationAction = nil
        return true
    }
}

/// Background URLSession driver for file-server uploads/downloads + lightweight
/// probe/delete helpers.
final class BackgroundFileTransfer: NSObject {

    /// Shared singleton — one background session per app process.
    static let shared = BackgroundFileTransfer()

    // MARK: - Handshake sentinel

    /// Thrown through the upload continuation ONLY when an upload task completes
    /// with HTTP 409 (nested-PUT parent collection missing, RFC 4918 §9.7), so
    /// `uploadFile` can run the single MKCOL + re-PUT WebDAV create-parent
    /// handshake. NEVER escapes `uploadFile` — the second failure is mapped to
    /// `.fileTransferUploadFailed`. `Equatable` so the pure status-mapping seam
    /// is unit-testable.
    struct NestedPutParentMissing: Error, Equatable {}

    // MARK: - In-flight task tracking

    /// What a single in-flight task is doing — drives how `didCompleteWithError`
    /// resumes the continuation.
    private enum Kind {
        /// Upload: resume `(Void)` on success.
        case upload(CheckedContinuation<Void, Error>)
        /// Download: resume with the moved temp URL on success.
        case download(CheckedContinuation<URL, Error>)
    }

    /// One in-flight transfer: its kind/continuation, the snapshot used to build
    /// the trust evaluator on challenge, an optional progress sink (uploads), and
    /// — for downloads — the destination temp URL the body was moved to.
    private final class InFlightTransfer {
        let kind: Kind
        let snapshot: SettingsManager.FileTransferSnapshot
        let onProgress: (@Sendable (Double) -> Void)?
        /// Upload-only cancellation/terminal gate. Downloads do not currently
        /// expose parent-task cancellation through this driver.
        let cancellation: BackgroundTransferCancellationRelay?
        /// Set by `didFinishDownloadingTo` once the body is moved to a temp URL.
        var downloadedURL: URL?
        init(kind: Kind,
             snapshot: SettingsManager.FileTransferSnapshot,
             onProgress: (@Sendable (Double) -> Void)?,
             cancellation: BackgroundTransferCancellationRelay? = nil) {
            self.kind = kind
            self.snapshot = snapshot
            self.onProgress = onProgress
            self.cancellation = cancellation
        }
    }

    /// Registry of in-flight transfers keyed by `URLSessionTask.taskIdentifier`.
    /// Guarded by `queue` for thread-safe access from delegate callbacks.
    private var inFlight: [Int: InFlightTransfer] = [:]

    /// The verdicts each task's server-trust challenge reached, stored WHOLE.
    /// Recorded from the evaluator's own answer at challenge time because
    /// URLSession reports the resulting `cancelAuthenticationChallenge` as a bare
    /// `.cancelled` (-999) — from the code alone that is indistinguishable from a
    /// benign task cancellation and from every other refusal.
    ///
    /// One snapshot, not a set per verdict: the three refusals have three
    /// remedies, and only ONE of them (a pin that disagreed with a chain the
    /// system DID trust) carries the warning that the connection may be
    /// intercepted. Collapsing them tells a user whose key rotated to go obtain a
    /// trusted certificate they already have — or, in the other direction, warns
    /// a user whose only problem is an unhashable key algorithm that they are
    /// being intercepted. Kept in lockstep with
    /// `CarPlayConverseUploader.trustSignalsByTaskID`, so the same refused
    /// certificate reads identically on every lane. Guarded by `queue`.
    private var trustSignalsByTaskID: [Int: RemoteAgentTrustEvaluator.AttemptTrustSignals] = [:]

    /// Serial queue guarding `inFlight` and the per-task trust registry.
    private let queue = DispatchQueue(label: Constants.identityNamespace + ".bg-file-transfer")

    /// Stored completion handler from the system `.backgroundTask` callback.
    private var backgroundCompletionHandler: (() -> Void)?

    // MARK: - Init

    private override init() {
        super.init()
    }

    /// Lazily-built transfer session. The delegate is `self`.
    ///
    /// iOS: a background configuration so transfers survive suspension and the
    /// app is relaunched to finish them. macOS: a default configuration — a
    /// desktop app stays resident, and background sessions there bind to a
    /// LaunchAgent relaunch model we don't want.
    private lazy var session: URLSession = {
        let config: URLSessionConfiguration
        #if os(iOS)
        config = URLSessionConfiguration.background(withIdentifier: Constants.fileTransferSessionIdentifier)
        config.sessionSendsLaunchEvents = true
        #else
        config = URLSessionConfiguration.default
        #endif
        config.timeoutIntervalForRequest = Constants.fileTransferRequestTimeout
        config.timeoutIntervalForResource = Constants.fileTransferResourceTimeout
        config.isDiscretionary = false
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    // MARK: - Public API

    /// Upload `localURL`'s bytes to the file-server as `storedKey` and await
    /// completion. Forwards determinate progress via `onProgress` (0...1).
    ///
    /// The upload body is read from a temp file (background sessions require a
    /// file-based body); that temp file is removed once the task is enqueued —
    /// the system copies it into its own staging area. Fail-fast: a thrown
    /// error means the caller surfaces Retry; this driver never auto-retries.
    ///
    /// `shareEnvelopeID` + `sequence` (default nil) tag an upload that belongs
    /// to a Share-Extension drain, so the drainer's cross-launch reconcile
    /// (`hasLiveUploadTask(shareEnvelopeID:sequence:)`) can tell a still-running
    /// upload apart from one to re-PUT. The in-app composer leaves both nil.
    func uploadFile(localURL: URL,
                    snapshot: SettingsManager.FileTransferSnapshot,
                    storedKey: String,
                    shareEnvelopeID: UUID? = nil,
                    sequence: Int? = nil,
                    onProgress: @escaping @Sendable (Double) -> Void) async throws {
        // The system copies the body file into its own staging area when the
        // upload task is enqueued, so we can drop our temp copy right after.
        defer { try? FileManager.default.removeItem(at: localURL) }

        // Nested key (per-conversation folder) → create the parent collection
        // first. WebDAV servers don't auto-create it on PUT (rclone answers
        // 409); MKCOL is best-effort (405 = already exists, any failure falls
        // through) — the PUT below stays the authoritative verdict, and flat
        // keys skip this entirely (no-op inside the helper).
        await Self.ensureParentCollection(forStoredKey: storedKey, snapshot: snapshot)

        let request = FileServerClient.buildUploadRequest(
            snapshot: snapshot,
            storedKey: storedKey,
            contentLength: (try? localURL.resourceValues(forKeys: [.fileSizeKey]).fileSize))

        let metadata = FileTransferBackgroundMetadata(
            storedKey: storedKey,
            refSuffix: "",                 // resolved by caller's snapshot; recovery uses host match
            direction: .upload,
            shareEnvelopeID: shareEnvelopeID,
            sequence: sequence,
            // The pin rides the TASK so the trust handler can apply it host-blind
            // and survive a relaunch — see the property's doc.
            pinnedFingerprintHex: snapshot.certFingerprintHex)

        do {
            try await enqueueUpload(request: request, metadata: metadata, localURL: localURL, snapshot: snapshot, onProgress: onProgress)
        } catch is CancellationError {
            throw CancellationError()
        } catch is NestedPutParentMissing {
            // WebDAV create-parent handshake, second half (POLICY carve-out — see
            // header): the nested PUT 409'd despite the best-effort MKCOL above
            // (missing parent per RFC 4918 §9.7 — MKCOL raced, transiently failed,
            // or the folder was deleted between MKCOL and PUT). ONE explicit MKCOL
            // + ONE re-PUT (the function-scoped temp-file `defer` keeps the body on
            // disk for it), then fail-fast as always. A flat key cannot have a
            // missing parent — its 409 is not ours to fix.
            guard storedKey.contains("/") else {
                throw AppError.fileTransferUploadFailed
            }
            await Self.ensureParentCollection(forStoredKey: storedKey, snapshot: snapshot)
            do {
                try await enqueueUpload(request: request, metadata: metadata, localURL: localURL, snapshot: snapshot, onProgress: onProgress)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // A second sentinel lands here too: `mapTransferError` maps it
                // to the fallback (it is neither AppError nor URLError), so a
                // re-PUT that 409s again fails as .fileTransferUploadFailed —
                // ONE handshake, never a retry loop.
                throw Self.mapTransferError(error, fallback: .fileTransferUploadFailed)
            }
        } catch {
            throw Self.mapTransferError(error, fallback: .fileTransferUploadFailed)
        }
    }

    /// Best-effort MKCOL of a NESTED storedKey's parent collection on a fresh
    /// cert-pinned ephemeral session; no-op for flat keys (no "/"). The ONE
    /// definition of how the parent collection is derived and created — shared
    /// by the pre-emptive create before every nested PUT and the 409
    /// handshake's re-create, so the two can never drift.
    private static func ensureParentCollection(
        forStoredKey storedKey: String,
        snapshot: SettingsManager.FileTransferSnapshot
    ) async {
        guard let slash = storedKey.lastIndex(of: "/") else { return }
        // Best-effort, so the evaluator's verdict is deliberately not consulted:
        // the PUT that follows is the authoritative attempt, it runs on the
        // background session whose per-task notes DO carry the refusal, and it
        // is the one that reports to the user. A second report here would give
        // one refusal two voices.
        let (session, _) = makeEphemeralSession(snapshot: snapshot)
        defer { session.finishTasksAndInvalidate() }
        await FileServerClient.ensureCollection(
            snapshot: snapshot,
            collectionKey: String(storedKey[..<slash]),
            session: session)
    }

    /// Enqueue the prepared upload `request` on the background session and await
    /// completion; the continuation resumes from `didCompleteWithError`. The body
    /// is read from `localURL` (background sessions require a file-based body).
    /// Throws `NestedPutParentMissing` when the PUT completes 409 so `uploadFile`
    /// can run the create-parent handshake; any other failure surfaces as-is for
    /// the caller to map. Runs the enqueue on `queue` (no actor hop) so the
    /// `inFlight` write stays serialized with the delegate callbacks.
    private func enqueueUpload(request: URLRequest,
                               metadata: FileTransferBackgroundMetadata,
                               localURL: URL,
                               snapshot: SettingsManager.FileTransferSnapshot,
                               onProgress: @escaping @Sendable (Double) -> Void) async throws {
        let cancellation = BackgroundTransferCancellationRelay()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            do {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    queue.async {
                        let task = self.session.uploadTask(with: request, fromFile: localURL)
                        task.taskDescription = metadata.encoded()

                        let installed = cancellation.install { [weak task] in
                            task?.cancel()
                        }
                        guard installed else {
                            task.cancel()
                            continuation.resume(throwing: CancellationError())
                            return
                        }

                        self.inFlight[task.taskIdentifier] = InFlightTransfer(
                            kind: .upload(continuation),
                            snapshot: snapshot,
                            onProgress: onProgress,
                            cancellation: cancellation)
                        task.resume()
                    }
                }
            } catch {
                // A parent-task cancellation completes through URLSession as
                // URLError.cancelled. Preserve CancellationError for that
                // caller-owned path; a `.cancelled` with no parent cancellation
                // behind it stays available to the mapper, which now sees the
                // certificate verdict already resolved by the delegate.
                try Task.checkCancellation()
                throw error
            }
            // Cancellation may win immediately after the delegate resumed a
            // nominal success; make the parent task's verdict authoritative.
            try Task.checkCancellation()
        } onCancel: {
            cancellation.cancel()
        }
    }

    /// Download `storedKey` from the file-server and return a temp file URL the
    /// caller OWNS (must move or delete it). Fail-fast on any error.
    func downloadFile(snapshot: SettingsManager.FileTransferSnapshot,
                      storedKey: String) async throws -> URL {
        let request = FileServerClient.buildDownloadRequest(snapshot: snapshot, storedKey: storedKey)

        let metadata = FileTransferBackgroundMetadata(
            storedKey: storedKey,
            refSuffix: "",
            direction: .download,
            pinnedFingerprintHex: snapshot.certFingerprintHex)

        do {
            return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
                queue.async {
                    let task = self.session.downloadTask(with: request)
                    task.taskDescription = metadata.encoded()
                    self.inFlight[task.taskIdentifier] = InFlightTransfer(
                        kind: .download(continuation),
                        snapshot: snapshot,
                        onProgress: nil)
                    task.resume()
                }
            }
        } catch {
            // Download path → a download-direction fallback (NOT the upload code).
            throw Self.mapTransferError(error, fallback: .fileTransferServerError)
        }
    }

    /// Probe whether `storedKey` exists on the file-server (GET, never HEAD).
    ///
    /// Runs on an ephemeral, cert-pinned session with the short probe timeout —
    /// existence probes are interactive (chip-tap / retry-gate), not background
    /// work. Returns an outcome rather than throwing.
    ///
    /// The length-returning variant IS the implementation: one probe path means
    /// the retry gate and the output detector can never reach opposite verdicts
    /// about one file on one server, which is the only thing worse than either
    /// of them being wrong.
    func probeExists(snapshot: SettingsManager.FileTransferSnapshot,
                     storedKey: String) async -> FileProbeOutcome {
        await probeExistsWithLength(snapshot: snapshot, storedKey: storedKey).0
    }

    /// Existence probe that also returns the file's TOTAL byte length, so the
    /// download chip can render a size and gate a soft-confirm on a very large
    /// file. Never throws; size is `nil` when the evidence names none (caller
    /// treats nil as "unknown" → no size, no gate).
    ///
    /// THE VERDICT READS THE BODY — see `FileServerClient.classifyProbe` for the
    /// rules and why each one is shaped the way it is. This half owns the two
    /// things the pure classifier cannot do: the BOUNDED read
    /// (`collectProbeEvidence`), and the second request the classifier asks for
    /// when a bare `200` is all the server offered.
    ///
    /// THE NEGATIVE CONTROL, and what it costs. EVERY path to `.exists` goes
    /// through it: one more GET — same request shape, same session, a random key
    /// that cannot exist — and the candidate is refused unless the server 404s
    /// it. That is deliberately not reserved for suspicious-looking responses,
    /// because the response that needs it most looks perfect (see
    /// `FileServerClient.classifyProbe` on the `try_files` fallback).
    ///
    /// The cost lands only where a file is actually FOUND: a missing candidate
    /// 404s and pays nothing, so the common shape — a reply naming several files
    /// of which one exists — spends one extra round trip per CHIP, not per
    /// probe. A uniform-200 wall spends exactly one and then stops the search:
    /// a failed control is `.unknown`, which is lane-wide, so
    /// `FileTransferOutputDetector.probeNamedCandidates` abandons the rest of
    /// the window.
    ///
    /// TWO CALLERS, NEITHER AUTOMATIC ON A REPLY: the retry gate (re-checking
    /// the user's OWN uploaded inputs before a re-dispatch) and the user-tapped
    /// name search. Automatic output discovery lists one folder
    /// (`listCollection`) and never probes a name a reply wrote.
    ///
    /// PRIVACY (see the spec's Privacy & Security section): the evidence value
    /// carries the storedKey and up to a kilobyte of file content and is
    /// LOCAL — never logged, never thrown, never persisted. Only the enum
    /// escapes this function.
    func probeExistsWithLength(snapshot: SettingsManager.FileTransferSnapshot,
                               storedKey: String) async -> (FileProbeOutcome, Int64?) {
        let (session, evaluator) = Self.makeEphemeralSession(snapshot: snapshot)
        defer { session.finishTasksAndInvalidate() }
        return await Self.probeExistsWithLength(
            snapshot: snapshot, storedKey: storedKey, session: session, evaluator: evaluator)
    }

    /// The probe's whole decision procedure on a CALLER-SUPPLIED session —
    /// `internal static` so a `URLProtocol`-stubbed session can drive the real
    /// two-request sequence (candidate, then negative control) without a live
    /// file-server, the same seam shape `collectProbeEvidence` below uses.
    ///
    /// `evaluator` is nil for an injected session: a mock raises no server-trust
    /// challenge, so there are no verdicts to read and a transport failure can
    /// only be `.unknown`. Production always passes the evaluator that answered
    /// this attempt, because a certificate refusal and a benign cancellation are
    /// both a bare `-999` and only the evaluator can tell them apart.
    static func probeExistsWithLength(
        snapshot: SettingsManager.FileTransferSnapshot,
        storedKey: String,
        session: URLSession,
        evaluator: RemoteAgentTrustEvaluator?
    ) async -> (FileProbeOutcome, Int64?) {
        do {
            let evidence = try await Self.collectProbeEvidence(
                session: session,
                request: FileServerClient.buildProbeRequest(snapshot: snapshot, storedKey: storedKey),
                requestedKey: storedKey)
            switch FileServerClient.classifyProbe(evidence) {
            case let .settled(outcome, byteLength):
                return (outcome, byteLength)
            case let .needsNegativeControl(byteLength):
                let controlKey = FileServerClient.negativeControlKey(
                    forExtension: FileServerClient.probeKeyExtension(storedKey))
                let control = try await Self.collectProbeEvidence(
                    session: session,
                    request: FileServerClient.buildProbeRequest(snapshot: snapshot, storedKey: controlKey),
                    requestedKey: controlKey)
                guard FileServerClient.negativeControlProvesNotFound(status: control.status) else {
                    // The server answers a key that cannot exist with something
                    // other than "not found", so its 200 for the candidate says
                    // nothing about the candidate. `.unknown`, never `.missing`:
                    // we learned about the SERVER, not about the file, and a
                    // `.missing` here would close the turn on evidence we do not
                    // have.
                    return (.unknown, nil)
                }
                return (.exists, byteLength)
            }
        } catch {
            // A transport failure is never a definitive "missing", so no arm
            // here can produce one — callers must not false-delete. The split is
            // between a failure that may clear on its own and one that cannot:
            // ask the evaluator that answered this attempt's challenge, because
            // the code alone cannot say (a refusal and a benign cancellation are
            // both -999).
            let refusal = evaluator.flatMap { Self.certificateRefusal(error, evaluator: $0) }
            return (refusal == nil ? .unknown : .certRefused, nil)
        }
    }

    /// Issue one probe request and reduce its response to the pure
    /// `FileProbeEvidence` the verdict runs on. `internal static` so a
    /// `URLProtocol`-stubbed session can drive it without a live file-server.
    ///
    /// `bytes(for:)` (NOT `data(for:)`): the response headers arrive before the
    /// body, so the read can be stopped mid-stream. THE CAP IS THE WHOLE POINT —
    /// a BYO server that ignores `Range: bytes=0-0` and answers a full 200 would
    /// have `data(for:)` buffer the ENTIRE file into memory on a probe the user
    /// never asked for (a jetsam kill on iOS for a large enough output). One byte
    /// past `maxPrefixBytes` and the task is cancelled.
    ///
    /// CANCELLATION ORDER IS LOAD-BEARING: cancel, then leave the loop, and never
    /// touch the iterator again. `URLSessionTask.cancel()` returns immediately and
    /// completes the task later with `NSURLErrorCancelled`; asking the stream for
    /// another element after cancelling would surface that as a thrown `-999` —
    /// the same code a certificate refusal throws — and the caller's evaluator
    /// split would then have to tell our own cancellation apart from a real trust
    /// rejection. Not touching the stream means it never has to.
    ///
    /// A body that fails MID-STREAM throws rather than returning partial
    /// evidence. The bytes already in hand may look like a complete verdict
    /// (`<!doctype html` arrives in the first 15 of them), and a half-read
    /// response is exactly the case where the app knows least.
    static func collectProbeEvidence(
        session: URLSession,
        request: URLRequest,
        requestedKey: String,
        maxPrefixBytes: Int = Constants.fileServerProbeBodySniffBytes
    ) async throws -> FileProbeEvidence {
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            bytes.task.cancel()
            throw URLError(.badServerResponse)
        }
        var prefix = Data()
        prefix.reserveCapacity(maxPrefixBytes)
        var delivered: Int64 = 0
        var exceededCap = false
        for try await byte in bytes {
            delivered += 1
            guard prefix.count < maxPrefixBytes else {
                exceededCap = true
                bytes.task.cancel()
                break
            }
            prefix.append(byte)
        }
        return FileProbeEvidence(
            status: http.statusCode,
            contentRange: http.value(forHTTPHeaderField: "Content-Range"),
            contentLength: http.value(forHTTPHeaderField: "Content-Length"),
            contentType: http.value(forHTTPHeaderField: "Content-Type"),
            contentEncoding: http.value(forHTTPHeaderField: "Content-Encoding"),
            bodyPrefix: prefix,
            deliveredBytes: delivered,
            bodyExceededSniffCap: exceededCap,
            finalPathComponent: http.url?.lastPathComponent,
            requestedKey: requestedKey)
    }

    // MARK: - Strict directory listing (the authority on agent output)

    /// Create `collectionKey` and require that THIS call created it (`201`).
    ///
    /// **NOT CALLED ON THE DISPATCH PATH.** The per-dispatch output box is named
    /// by Conduck and created by the agent — see
    /// `FileServerClient.ensureFreshCollection`'s header for the ownership
    /// measurement that decided it, and `witnessCollectionAbsent` below for what
    /// supplies the freshness evidence instead.
    ///
    /// False on a collision, on any other status, and on every transport failure
    /// INCLUDING a certificate refusal — a refusal that reads as "not created"
    /// costs nothing a refusal that read as "created" would not cost far more.
    ///
    /// Runs on the same ephemeral cert-pinned session as the probes, so the
    /// MKCOL is subject to the pin like every other request in this lane.
    func ensureFreshCollection(
        snapshot: SettingsManager.FileTransferSnapshot,
        collectionKey: String
    ) async -> Bool {
        let (session, _) = Self.makeEphemeralSession(snapshot: snapshot)
        defer { session.finishTasksAndInvalidate() }
        return await FileServerClient.ensureFreshCollection(
            snapshot: snapshot, collectionKey: collectionKey, session: session)
    }

    /// PROPFIND `Depth: 0` the exact dispatch box and require a definite `404` —
    /// the pre-dispatch assertion that the folder this turn is about to name is
    /// NOT ALREADY THERE.
    ///
    /// THE ONE THING IT BUYS: a server-observed absence at the instant the turn
    /// starts. Without it the freshness of the box rests entirely on the mint's
    /// entropy, which is an argument about probability rather than an
    /// observation — and it would leave a catch-all host (one that answers every
    /// path) indistinguishable from a healthy one until a reply landed and files
    /// nobody wrote turned into download chips. `Depth: 0` because the question
    /// is about the collection itself; a listing of children would be a strictly
    /// larger answer to a smaller question.
    ///
    /// FAILS CLOSED, WITHOUT EXCEPTION. `false` on a `207` (collision, or a
    /// namespace that answers everything), on every other status, and on every
    /// transport failure including a refused certificate. A caller that gets
    /// `false` must NOT put the location line on the wire — freshness that was
    /// not witnessed is not freshness. The cost is one turn without automatic
    /// delivery; the manual affordance still reaches the files.
    ///
    /// NO TRUST TAXONOMY, on purpose — and the four-way answer does not change
    /// that. A refused certificate lands in `.unreachable` alongside a dead
    /// host, because the split this verdict draws is between "the lane cannot do
    /// this" and "the lane stopped doing this", not between causes of the
    /// second. `listCollection` is where a certificate refusal must keep its own
    /// name, because that verdict is rendered to the user as a cause; this one
    /// is rendered as a consequence ("this turn went out with no folder"), and
    /// naming the certificate here would put a TLS diagnosis under a chat
    /// bubble. It still runs on the pinned ephemeral session, so the pin applies
    /// exactly as it does to every other request in this lane.
    ///
    /// IT IS ON THE DISPATCH CRITICAL PATH, which the deadline reflects. Every
    /// send on a configured lane waits for this, INCLUDING a pure-text turn that
    /// was never going to involve a file, so it runs on
    /// `Constants.fileServerAbsenceWitnessTimeout` rather than the lane's
    /// interactive budget — see that constant for the sizing argument. A slow or
    /// dead file server therefore costs one turn's automatic delivery, never
    /// every turn's latency.
    ///
    /// PRIVACY: never logs the URL, the collection key, or the response.
    func witnessCollectionAbsent(
        snapshot: SettingsManager.FileTransferSnapshot,
        collectionKey: String
    ) async -> FileServerAbsenceWitness {
        let (session, _) = Self.makeEphemeralSession(
            snapshot: snapshot, timeout: Constants.fileServerAbsenceWitnessTimeout)
        defer { session.finishTasksAndInvalidate() }
        return await Self.witnessCollectionAbsent(
            snapshot: snapshot, collectionKey: collectionKey, session: session)
    }

    /// The assertion on a CALLER-SUPPLIED session — `internal static` so a
    /// `URLProtocol`-stubbed session can drive the real request without a live
    /// file server, the same seam shape as `listCollection`.
    static func witnessCollectionAbsent(
        snapshot: SettingsManager.FileTransferSnapshot,
        collectionKey: String,
        session: URLSession
    ) async -> FileServerAbsenceWitness {
        let request = FileServerClient.buildPropfindRequest(
            snapshot: snapshot,
            collectionKey: collectionKey,
            depth: 0,
            timeout: Constants.fileServerAbsenceWitnessTimeout)
        // THE BODY IS NEVER READ, because the verdict is a function of the status
        // line alone. Draining it would spend up to the listing cap of async
        // iterations on the dispatch critical path for bytes nothing inspects —
        // an SSO wall answering a 200 with its login page is the ordinary case —
        // and it would turn an over-cap `404` into "not witnessed", disabling
        // file return on a server that answered the question correctly.
        guard let status = try? await Self.statusOnlyResponse(
            session: session, request: request) else { return .unreachable }
        return FileServerClient.classifyAbsenceWitness(status: status)
    }

    /// Issue one request and take ONLY its status line, cancelling before a byte
    /// of the body is consumed.
    ///
    /// For the callers whose verdict the body cannot influence. `bytes(for:)`
    /// resumes when the HEADERS arrive, so cancelling the task before the first
    /// iteration ends the transfer having read no body at all — the iterator is
    /// then never touched, which is the same cancellation order the bounded
    /// readers use so our own cancel can never surface as the bare `-999` a
    /// certificate refusal throws.
    static func statusOnlyResponse(
        session: URLSession,
        request: URLRequest
    ) async throws -> Int {
        let (bytes, response) = try await session.bytes(for: request)
        bytes.task.cancel()
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return http.statusCode
    }

    /// Name the box for ONE dispatch and, when this device can, witness that it
    /// is not there yet. THE single seam every dispatch surface that holds the
    /// file-server credential goes through, so the mint, the capability gate and
    /// the freshness assertion can never drift apart between surfaces.
    ///
    /// A TYPED OUTCOME, NOT A BARE NIL, and that is the whole point of this
    /// function. Nil used to mean four unrelated things at once — no lane, a
    /// device that holds no file-server credential, a lane that cannot answer a
    /// PROPFIND at all, and a lane the user configured and tested green that has
    /// since stopped answering — and every call site collapsed them into "no
    /// folder named". The fourth is the only one the user can act on, and it was
    /// the one that disappeared: the reply said "Saved the haiku to rain.md",
    /// no file arrived, and nothing anywhere said why, forever.
    ///
    /// TWO GATES, AND ONLY TWO. The persisted `returnCapable` verdict decides
    /// whether this lane can EVER return a file — the staged test's structural
    /// finding, the same flag the wrist gates on — and the witness decides
    /// whether THIS turn's box is fresh. Nothing else is read, and in particular
    /// `folderCapable` is deliberately not: that flag records whether the lane
    /// accepts a NESTED PUT from the client, and the client neither creates this
    /// folder nor writes into it — the agent does. The only client operation the
    /// box ever sees is a PROPFIND, which is exactly what the witness issues, so
    /// the assertion below measures the capability that actually decides.
    /// Reading `folderCapable` here made two surfaces on ONE lane disagree: it
    /// withheld the box from phone, Mac and CarPlay while the Watch, which is
    /// never told the flag, named one anyway. `returnCapable` is the opposite
    /// case and belongs here for the mirror-image reason — the Watch IS told it,
    /// gates on it, and a phone that ignored it would be the surface out of
    /// step.
    ///
    /// FRESH ON EVERY CALL, which is what makes a RETRY safe: re-dispatching a
    /// stored turn names a new folder, so a file written late by the abandoned
    /// attempt can never surface as this turn's output.
    ///
    /// IT IS ALSO THE ONE PLACE THE WITNESS BREAKER IS FED, deliberately rather
    /// than at the call sites: every dispatch surface reaches the server through
    /// here, so a surface that forgets to report cannot exist, and a surface
    /// that never learns to read the outcome still pays the reduced cost and
    /// still contributes its evidence.
    ///
    /// The Watch does not call this and must not: it holds no file-server
    /// credential by design, and naming a path needs none. It calls
    /// `OutboxKey.mint` directly and skips the assertion.
    static func mintOutboxKey(
        conversationID: UUID,
        snapshot: SettingsManager.FileTransferSnapshot?
    ) async -> OutboxMintOutcome {
        guard let snapshot else { return .noLane }
        return await mintOutboxKey(conversationID: conversationID, snapshot: snapshot) { key in
            await Self.shared.witnessCollectionAbsent(snapshot: snapshot, collectionKey: key)
        }
    }

    /// The same seam on a CALLER-SUPPLIED session, so a `URLProtocol`-stubbed
    /// session can drive the real mint-then-witness sequence without a live file
    /// server. Production goes through the form above, which owns the
    /// short-deadline session.
    static func mintOutboxKey(
        conversationID: UUID,
        snapshot: SettingsManager.FileTransferSnapshot,
        session: URLSession
    ) async -> OutboxMintOutcome {
        await mintOutboxKey(conversationID: conversationID, snapshot: snapshot) { key in
            await Self.witnessCollectionAbsent(
                snapshot: snapshot, collectionKey: key, session: session)
        }
    }

    /// The decision procedure both entry points share, with the request itself
    /// injected. Factored out so the breaker consultation, the classification
    /// and the recording exist ONCE — a second copy is how a test seam and a
    /// production path start disagreeing about which outcomes are silent.
    private static func mintOutboxKey(
        conversationID: UUID,
        snapshot: SettingsManager.FileTransferSnapshot,
        witness: (String) async -> FileServerAbsenceWitness
    ) async -> OutboxMintOutcome {
        // THE DURABLE VERDICT GATES FIRST — before any process state, before any
        // request. `snapshot.returnCapable` is the staged Test Connection's
        // structural `405`/`501` finding, taken against the served root (a
        // collection that certainly exists), persisted per gateway and couriered
        // to the Watch, which gates its own mint on the very same flag. Reading
        // it here is what makes the phone, the Mac, CarPlay and the wrist agree
        // about one server: without it the credentialled surfaces re-discovered
        // the fact with a per-turn PROPFIND after every launch — and, once the
        // witness stopped being allowed to conclude incapability from a
        // non-existent collection, would have complained about it every turn.
        // Silent for the same reason `.laneCannotReturn` always is.
        //
        // NOTHING HERE WIDENS THE FLAG, and that is deliberate rather than a gap:
        // a gate on the dispatch critical path is the wrong place to spend a
        // probe, which is the whole reason it exists. The widener is
        // `FileTransferCapabilityRefresher`, which re-asks a narrowed lane once
        // per launch off this path and writes `true` back on proof — so a
        // repaired server heals itself without the user re-running a Test
        // Connection, and without any turn paying for the question.
        guard snapshot.returnCapable else { return .laneCannotReturn }

        let lane = FileLaneWitnessBreaker.laneKey(for: snapshot)
        switch FileLaneWitnessBreaker.shared.decide(lane: lane) {
        case .cannotReturn:
            // The staged verdict again, cached in-process — the breaker's only
            // author of this decision is `noteStagedVerdict`, and it covers the
            // window between a Test Connection settling the answer and the
            // commit hop's persisted flag reaching the snapshot above. Same
            // treatment: no request, no folder, and NOTHING SAID, because this
            // is a limitation the user can read in Settings rather than a fault,
            // and a per-turn complaint about a permanent property of their own
            // server is the definition of noise.
            return .laneCannotReturn
        case .cooldown:
            // The lane has failed enough times in a row that probing it again
            // this turn buys nothing but latency. The TURN is still folder-less,
            // so the caller still gets an actionable outcome — the backoff
            // suppresses the request, never the truth.
            return .witnessSuppressed
        case .probe:
            break
        }

        let key = OutboxKey.mint(conversationID: conversationID)
        switch await witness(key) {
        case .absent:
            FileLaneWitnessBreaker.shared.recordWitnessed(lane: lane)
            return .named(key)
        case .cannotAnswer:
            // A `405`/`501` HERE PROVES NOTHING, and refusing to conclude from
            // it is the entire reason this case is charged as a failure instead
            // of read as a verdict. The collection was minted moments ago and is
            // NOT THERE — witnessing exactly that is the job — so the answer
            // describes the route a missing path is served by, not the method
            // the server performs: a path-scoped `dav_methods` rule, a WAF, an
            // SSO layer, a rewrite. `probeListingCapability` refuses the same
            // inference on the same request, and letting the two disagree meant
            // one server was certified green in Settings and silently stamped
            // incapable for the rest of the process by its very next turn.
            //
            // `.answered` severity, from the existing model: the server DID
            // answer, so a second sample can still teach us something, and the
            // three-strike threshold is the right patience for an answer that
            // may be a rule in front of the server rather than the server.
            FileLaneWitnessBreaker.shared.recordFailure(lane: lane, severity: .answered)
            return .witnessFailed
        case .occupied:
            // A `207` for a path carrying fresh entropy. Charged as a soft
            // failure rather than a structural one: a genuine collision is
            // astronomically unlikely and the NEXT turn mints a different name,
            // so one occurrence self-heals and resets the streak, while a
            // namespace that answers everything occupies every name and reaches
            // the cooldown on its own.
            FileLaneWitnessBreaker.shared.recordFailure(lane: lane, severity: .answered)
            return .witnessFailed
        case .indeterminate:
            FileLaneWitnessBreaker.shared.recordFailure(lane: lane, severity: .answered)
            return .witnessFailed
        case .unreachable:
            // No HTTP response at all. A host that is not there will not be
            // there next turn either — and in this product the commonest cause
            // is a quick-tunnel hostname that rotated — so this opens the
            // cooldown on ONE observation instead of three.
            FileLaneWitnessBreaker.shared.recordFailure(lane: lane, severity: .unreachable)
            return .witnessFailed
        }
    }

    /// The pre-typed-outcome signature, kept as a one-line adapter.
    ///
    /// Not deprecated and not a wart: the dispatch surfaces that only need the
    /// folder name are better off asking for the folder name, and routing them
    /// through the adapter keeps the breaker fed for free — a caller cannot opt
    /// out of contributing evidence by ignoring the outcome. A surface that
    /// wants to SAY something about a failure calls `mintOutboxKey` directly.
    static func mintWitnessedOutboxKey(
        conversationID: UUID,
        snapshot: SettingsManager.FileTransferSnapshot?
    ) async -> String? {
        await mintOutboxKey(conversationID: conversationID, snapshot: snapshot).key
    }

    /// The adapter's caller-supplied-session twin, same contract.
    static func mintWitnessedOutboxKey(
        conversationID: UUID,
        snapshot: SettingsManager.FileTransferSnapshot,
        session: URLSession
    ) async -> String? {
        await mintOutboxKey(
            conversationID: conversationID, snapshot: snapshot, session: session).key
    }

    /// PROPFIND `Depth: 1` of ONE exact collection, believed only on a lane that
    /// proves it can say no.
    ///
    /// THE NEGATIVE CONTROL, and why it is shaped this way. A listing that is
    /// believed mints download chips with nothing downstream to correct it, so
    /// before any `.entries` verdict is returned this issues a SECOND PROPFIND —
    /// same method, same depth, same session — against a sibling collection
    /// under the same parent that cannot exist, and requires a definite `404`. A
    /// `207` there means the server answers everything, so its `207` for the
    /// real box says nothing about the real box.
    ///
    /// PER-LISTING, NEVER CACHED, AND IT DEFAULTS CLOSED. Not modelled on
    /// `folderCapable`, whose getter answers `true` when unset: that polarity is
    /// right for a capability the app narrows on proof and exactly wrong for a
    /// verdict that means "this lane DEMONSTRATED it can say no". A transport
    /// failure on the control disqualifies the listing rather than permitting
    /// it, because a control that never ran proved nothing. Uncached because the
    /// question is about the server as it is right now — a stored answer is an
    /// answer about a server that has since changed — and because caching it
    /// would need a persisted key, which the design deliberately does not have.
    ///
    /// `.absent` skips the control on purpose: a `404` for the box is itself the
    /// server saying no, and absence mints nothing, so there is no positive
    /// verdict for a control to corroborate.
    ///
    /// PRIVACY: never logs the URL, the collection key, entry names, or the
    /// body; only the verdict leaves this function.
    func listCollection(
        snapshot: SettingsManager.FileTransferSnapshot,
        collectionKey: String
    ) async -> FileServerListingVerdict {
        let (session, evaluator) = Self.makeEphemeralSession(snapshot: snapshot)
        defer { session.finishTasksAndInvalidate() }
        return await Self.listCollection(
            snapshot: snapshot, collectionKey: collectionKey, session: session, evaluator: evaluator)
    }

    /// The listing's whole decision procedure on a CALLER-SUPPLIED session —
    /// `internal static` so a `URLProtocol`-stubbed session can drive the real
    /// two-request sequence (the collection, then the negative control) without
    /// a live file-server, the same seam shape as `probeExistsWithLength`.
    ///
    /// `evaluator` is nil for an injected session: a mock raises no server-trust
    /// challenge, so there are no verdicts to read and a transport failure can
    /// only be `.transport`. Production always passes the evaluator that
    /// answered this attempt, because a certificate refusal and a benign
    /// cancellation are both a bare `-999` and only the evaluator can tell them
    /// apart — without it a refused certificate would reach the user as "your
    /// file server is unreachable".
    static func listCollection(
        snapshot: SettingsManager.FileTransferSnapshot,
        collectionKey: String,
        session: URLSession,
        evaluator: RemoteAgentTrustEvaluator?
    ) async -> FileServerListingVerdict {
        let requestedURL = FileServerClient.listingCollectionURL(
            snapshot: snapshot, collectionKey: collectionKey)
        let verdict: FileServerListingVerdict
        do {
            let answer = try await Self.boundedListingResponse(
                session: session,
                request: FileServerClient.buildPropfindRequest(
                    snapshot: snapshot, collectionKey: collectionKey, depth: 1))
            guard !answer.exceededCap else { return .unusable(.bodyTooLarge) }
            verdict = FileServerClient.parseListing(
                status: answer.status, body: answer.body, requestedURL: requestedURL)
        } catch {
            return .unusable(Self.listingTransportRefusal(error, evaluator: evaluator))
        }

        // Only a POSITIVE reading needs corroborating. `.absent` and every
        // refusal already fail closed on their own.
        guard case .entries = verdict else { return verdict }

        let controlKey = FileServerClient.negativeControlCollectionKey(siblingOf: collectionKey)
        do {
            let control = try await Self.boundedListingResponse(
                session: session,
                request: FileServerClient.buildPropfindRequest(
                    snapshot: snapshot, collectionKey: controlKey, depth: 1))
            guard FileServerClient.negativeControlProvesNotFound(status: control.status) else {
                return .unusable(.namespaceAnswersEverything)
            }
        } catch {
            return .unusable(Self.listingTransportRefusal(error, evaluator: evaluator))
        }
        return verdict
    }

    /// Issue one PROPFIND and read its body under a hard client-side cap.
    ///
    /// `bytes(for:)` (NOT `data(for:)`) for the reason `collectProbeEvidence`
    /// uses it: the headers arrive before the body, so the read can be stopped
    /// mid-stream. There is no bound on what a server may return for a PROPFIND
    /// — a catch-all host can answer with a multi-megabyte page — and buffering
    /// it whole on a listing the user never asked for is a jetsam risk on iOS.
    /// One byte past the cap and the task is cancelled and the answer is
    /// reported as over-cap, which the caller turns into a refusal rather than
    /// parsing the truncated prefix.
    ///
    /// CANCELLATION ORDER IS LOAD-BEARING — cancel, leave the loop, never touch
    /// the iterator again — so our own cancellation can never surface as the
    /// bare `-999` a certificate refusal throws.
    static func boundedListingResponse(
        session: URLSession,
        request: URLRequest,
        maxBytes: Int = FileServerClient.listingMaxBytes
    ) async throws -> (status: Int, body: Data, exceededCap: Bool) {
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            bytes.task.cancel()
            throw URLError(.badServerResponse)
        }
        var body = Data()
        var exceededCap = false
        for try await byte in bytes {
            guard body.count < maxBytes else {
                exceededCap = true
                bytes.task.cancel()
                break
            }
            body.append(byte)
        }
        return (http.statusCode, body, exceededCap)
    }

    /// Which refusal a listing transport failure represents. Routed through the
    /// SAME `RemoteAgentTrustEvaluator.classifyTransportError` every other probe
    /// in this lane reads, so the listing can never tell the user a different
    /// story about one certificate than the staged test does. No evaluator (an
    /// injected session) or no recorded verdict means no certificate claim.
    static func listingTransportRefusal(
        _ error: Error,
        evaluator: RemoteAgentTrustEvaluator?
    ) -> FileTransferListingRefusal {
        guard let evaluator, let urlError = error as? URLError else { return .transport }
        let signals = evaluator.attemptSignals
        guard signals != .empty else { return .transport }
        guard let refusal = FileServerClient.CertificateRefusal(
            RemoteAgentTrustEvaluator.classifyTransportError(urlError.code, signals: signals)
        ) else {
            return .transport
        }
        return .certificateRefused(refusal)
    }

    /// Best-effort delete of an orphaned `storedKey` (e.g. user cancelled a send
    /// after the upload landed). Never throws — orphan cleanup is non-critical.
    func deleteFile(snapshot: SettingsManager.FileTransferSnapshot,
                    storedKey: String) async {
        let request = FileServerClient.buildDeleteRequest(snapshot: snapshot, storedKey: storedKey)
        // Orphan cleanup has no caller to report to, so the evaluator's verdict
        // has nowhere to go. An orphan blob on the user's own server is harmless.
        let (session, _) = Self.makeEphemeralSession(snapshot: snapshot)
        defer { session.finishTasksAndInvalidate() }
        _ = try? await session.data(for: request)
    }

    // MARK: - Share-Extension drain reconcile

    /// Whether an upload task for `(shareEnvelopeID, sequence)` is currently
    /// LIVE on the transfer session (running OR suspended — not yet completed).
    /// The Share-Extension drainer calls this on relaunch BEFORE re-PUTting a
    /// share attachment: a live task means the prior process's upload is still
    /// in flight (DEFER — let it finish); no live task means re-PUT the same
    /// bytes to the deterministic key (idempotent — WebDAV PUT to the same path
    /// overwrites identical bytes, no orphan; the "upload recovery is
    /// a no-op post-kill" limit refers to the in-app composer path, whose only consumer
    /// — the staged tile — is gone after a kill; the drainer is the new consumer
    /// that DRIVES this reconcile).
    ///
    /// Reads `session.allTasks` (the authoritative live set across a process
    /// relaunch — the in-memory `inFlight` registry is empty after a kill) and
    /// matches each task's decoded `taskDescription` metadata on BOTH
    /// `shareEnvelopeID` and `sequence` (a single attachment's upload).
    func hasLiveUploadTask(shareEnvelopeID: UUID, sequence: Int) async -> Bool {
        let tasks = await session.allTasks
        return tasks.contains { task in
            guard let meta = FileTransferBackgroundMetadata.decoded(from: task.taskDescription),
                  meta.direction == .upload else {
                return false
            }
            return meta.shareEnvelopeID == shareEnvelopeID && meta.sequence == sequence
        }
    }

    // MARK: - Background event plumbing

    /// Store the system completion handler; called by ConduckApp's 4th
    /// `.backgroundTask` handler. Bridged back when the session finishes events.
    func handleBackgroundSessionEvents(completion: @escaping () -> Void) {
        queue.async {
            self.backgroundCompletionHandler = completion
            // Force the lazy session to materialize AFTER the handler is
            // stored: on a cold relaunch nothing else has touched `session`
            // yet, so without this the delegate is never re-attached, the
            // pending events never drain, `urlSessionDidFinishEvents` never
            // fires, and the ConduckApp continuation never resumes (wedged
            // background task). Ordering inside this `queue.async` guarantees
            // the handler is in place before the drained events can read it.
            _ = self.session
        }
    }

    // MARK: - Ephemeral session (probe / delete / MKCOL)

    /// A short-lived, cert-pinned session for interactive probe/delete/MKCOL
    /// requests, RETURNED WITH ITS EVALUATOR.
    /// The `RemoteAgentTrustEvaluator` IS the delegate (the session retains it
    /// until invalidated), so this lane gets the pin compare AND the cross-host
    /// redirect refusal from the one shared trust component instead of a
    /// look-alike wrapper that could drift from it. The pin is applied host-blind
    /// — a redirect target's cert cannot match, which is the fail-closed answer.
    ///
    /// WHY THE EVALUATOR COMES BACK OUT. All three of its refusals reach the
    /// caller as a bare `.cancelled` (-999), indistinguishable from a session
    /// teardown or a parent-task cancellation, and this lane installs the
    /// evaluator as the SESSION delegate — so `BackgroundFileTransfer`'s own
    /// per-task note registry, which is what keeps the background lane's
    /// verdicts attributable, never sees these challenges at all. Handing the
    /// reference back is the only record of whose refusal a -999 was. Mirrors
    /// `FileServerClient.makeProbeSession`, which returns the same pair for the
    /// same reason. The caller owns invalidation.
    ///
    /// `timeout` sets BOTH the per-request and the resource budget, and both,
    /// because either one alone leaves the other as the real ceiling. It is a
    /// parameter rather than a constant so the one probe that runs on the
    /// dispatch critical path (the absence witness) can carry a deadline sized
    /// for a liveness check instead of the interactive-download budget the rest
    /// of the lane wants.
    static func makeEphemeralSession(
        snapshot: SettingsManager.FileTransferSnapshot,
        timeout: TimeInterval = Constants.fileServerProbeTimeout
    ) -> (session: URLSession, evaluator: RemoteAgentTrustEvaluator) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        let evaluator = RemoteAgentTrustEvaluator(
            pinnedFingerprintHex: snapshot.certFingerprintHex)
        return (URLSession(configuration: config, delegate: evaluator, delegateQueue: nil), evaluator)
    }

    // MARK: - Error mapping

    /// Map a completed task's HTTP status to the error its continuation should
    /// throw (or `nil` for success). A pure seam so the status→error contract is
    /// unit-testable without a live session.
    ///
    /// - `nil` statusCode (a non-HTTP response) → `nil`: only an `HTTPURLResponse`
    ///   carries a status to map; a transport failure is the delegate's `error`
    ///   path, not this seam's.
    /// - 2xx → `nil` (success); 401/403 → auth failed; 404 → file unavailable;
    ///   5xx → server error.
    /// - 409 on an UPLOAD → `NestedPutParentMissing` (the create-parent handshake
    ///   signal — see the POLICY header); `uploadFile` catches it to MKCOL+re-PUT.
    /// - Everything else — including 409 on a DOWNLOAD and 405 on an upload —
    ///   → `.fileTransferUploadFailed` (the legacy default for both directions,
    ///   preserved verbatim; 405 stays here because MKCOL cannot fix it).
    static func completionError(statusCode: Int?, isUpload: Bool) -> Error? {
        guard let statusCode else { return nil }
        switch statusCode {
        case 200...299:          return nil
        case 401, 403:           return AppError.fileTransferAuthFailed
        case 404:                return AppError.fileTransferFileUnavailable
        case 409 where isUpload: return NestedPutParentMissing()
        case 500...599:          return AppError.fileTransferServerError
        default:                 return AppError.fileTransferUploadFailed
        }
    }

    /// The file-transfer error a completed task's transport `urlError` means
    /// GIVEN this delegate's own per-task trust notes, or `nil` when no note was
    /// recorded (the caller keeps the raw error). Pure over its inputs and
    /// `internal`, so the one distinction that a user acts on differently is
    /// unit-testable without a live server.
    ///
    /// The verdicts must never collapse into one another. An untrusted chain is
    /// fixed on the SERVER — give it a certificate this device would trust — and
    /// `.fileTransferCertUntrusted` says exactly that. A pin that disagreed with
    /// a chain the system DID trust is the interception case the pin exists to
    /// catch, and `.fileTransferCertMismatch` is the only message that warns the
    /// connection may be intercepted. Telling a user in that position to go
    /// obtain a trusted certificate points them at something they already have.
    ///
    /// Classification is delegated to `RemoteAgentTrustEvaluator`, the ONE
    /// classifier every lane shares, so the file lane cannot drift from the
    /// converse and STT lanes on the same refusal. The WHOLE snapshot travels
    /// here, not loose Bools: `pinComparisonUnsupported` is the only thing
    /// separating "Conduck cannot hash this key" from the interception warning,
    /// and a flattened form drops it silently.
    static func trustError(urlError: URLError,
                           signals: RemoteAgentTrustEvaluator.AttemptTrustSignals) -> AppError? {
        guard signals != .empty else { return nil }
        switch RemoteAgentTrustEvaluator.classifyTransportError(urlError.code, signals: signals) {
        case .untrustedCert: return .fileTransferCertUntrusted
        case .certMismatch:  return .fileTransferCertMismatch
        // Chain trusted, pin never compared — its own code so this lane never
        // borrows the mismatch warning for a certificate that is fine.
        case .certKeyUnpinnable: return .fileTransferCertKeyUnpinnable
        case .timeout, .unreachable, .notEstablished, .offline, .cancelled: return nil
        }
    }

    /// The certificate refusal an EPHEMERAL-session failure represents, or `nil`
    /// when the failure was anything else.
    ///
    /// The ephemeral lane installs the evaluator as the SESSION delegate, so its
    /// challenges never pass through this type's per-task note registry — the
    /// evaluator's own snapshot is the only record, and it is scoped to the one
    /// attempt the caller just awaited. Non-`URLError` failures are
    /// unclassifiable and take the conservative `nil`.
    ///
    /// Routed through `trustError` rather than re-deriving the split, so the
    /// interactive probes and the background transfers cannot come to different
    /// conclusions about one refusal.
    private static func certificateRefusal(
        _ error: Error,
        evaluator: RemoteAgentTrustEvaluator
    ) -> AppError? {
        guard let urlError = error as? URLError else { return nil }
        return trustError(urlError: urlError, signals: evaluator.attemptSignals)
    }

    /// Map a transport-layer error to the file-transfer AppError family.
    /// Never reveals credentials. `internal` so the code→error contract is
    /// unit-testable without a live session, like `completionError` above.
    ///
    /// It runs on the CALLER's side of the continuation, where the task — and
    /// therefore its trust notes — is out of reach, so it deliberately owns no
    /// trust disambiguation: `didCompleteWithError` has already resolved a noted
    /// refusal into an `AppError`, and the first line here passes that through.
    static func mapTransferError(_ error: Error, fallback: AppError) -> AppError {
        if let appError = error as? AppError { return appError }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .userAuthenticationRequired:
                return .fileTransferAuthFailed
            case .serverCertificateUntrusted,
                 .serverCertificateHasBadDate,
                 .serverCertificateHasUnknownRoot,
                 .serverCertificateNotYetValid:
                // The SYSTEM named the certificate as the cause. Reaching here
                // means no challenge recorded a note for this task (a reused
                // connection, or a rejection the stack made before any
                // challenge fired), so nothing compared a pinned digest and
                // "untrusted" is the whole of what is known.
                return .fileTransferCertUntrusted
            case .notConnectedToInternet,
                 .cannotConnectToHost,
                 .cannotFindHost,
                 .dnsLookupFailed,
                 .timedOut,
                 .networkConnectionLost,
                 .secureConnectionFailed:
                // GENERIC SSL failure (`-1200`) is NOT a cert-trust signal on
                // its own — with no note recorded it is a transient handshake
                // failure → unreachable, NOT a false cert verdict.
                return .fileTransferUnreachable
            default:
                // `.cancelled` (-999) lands here, and must NOT be read as a
                // certificate problem. Both of the evaluator's refusals set a
                // note and were resolved by `didCompleteWithError` before the
                // continuation threw; an un-noted -999 is a genuine
                // cancellation (parent task, session invalidation), and the
                // fallback is the honest "the transfer did not complete".
                // Folding it in with the certificate codes told every real pin
                // mismatch — a rotated key, or interception using a
                // publicly-trusted certificate — to go get a trusted
                // certificate, and dropped the one line that says the
                // connection may be intercepted.
                return fallback
            }
        }
        return fallback
    }
}

// MARK: - URLSessionTaskDelegate (progress + completion)

extension BackgroundFileTransfer: URLSessionTaskDelegate {

    /// TASK-level server-trust challenge handler — per-TASK pinning for the file
    /// lane. Mirrors `BackgroundRemoteAgent` / `CarPlayConverseUploader` /
    /// `STTClient+Background`, which all pin this way and for the same reasons.
    /// A session-level `urlSession(_:didReceive:)` takes precedence for
    /// server-trust challenges, so it is intentionally ABSENT here — only this
    /// task-level handler exists.
    ///
    /// The pin is recovered from the task's own `taskDescription` envelope (the
    /// snapshot's fingerprint, stamped at enqueue) and applied HOST-BLIND. That
    /// is the load-bearing part: this ONE session is a shared, multi-host
    /// registry, and resolving the pin by CHALLENGE HOST returned nil for a host
    /// no configured ref points at — so a cross-origin 3xx got default ATS and
    /// URLSession replayed the file bytes AND the `Authorization: Basic`
    /// credential to an endpoint the user never configured. Host-blind, that
    /// redirect target must present the PINNED key or the evaluator cancels.
    ///
    /// HONEST LIMIT (identical to `RemoteAgentTrustEvaluator.converseTaskPin`):
    /// a pin compare proves "same key", not "same origin" — a wildcard/multi-SAN
    /// cert or one key behind several proxy names satisfies it at another host,
    /// and URLSession may reuse a connection without raising a fresh challenge.
    /// It is a mitigation, not a redirect veto. The veto is
    /// `willPerformHTTPRedirection` below, which an iOS BACKGROUND session never
    /// receives. And an UNPINNED lane (the recommended Tailscale Serve /
    /// Let's Encrypt posture) has no mitigation here at all on iOS — point the
    /// app at the TERMINAL file-server URL, not one that redirects. Test
    /// Connection surfaces a redirecting endpoint rather than following it.
    ///
    /// nil pin (unpinned lane, or a pre-update task whose envelope has no pin
    /// field → `pinnedFingerprint(forHost:)`) → `performDefaultHandling`.
    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        answerTaskTrustChallenge(
            session, task: task, challenge: challenge,
            makeEvaluator: { RemoteAgentTrustEvaluator(pinnedFingerprintHex: $0) },
            completionHandler: completionHandler)
    }

    #if DEBUG
    /// TEST-ONLY entry into the delegate body above with the system-chain
    /// verdict substituted. It exists because a pin is an ADDITIONAL restriction
    /// on a chain the system already trusts: over an untrusted chain the
    /// evaluator fails closed before it ever compares a digest, so the loopback
    /// fixture's self-signed certificate cannot reach the pin compare, the
    /// redirect veto, or anything else that happens after a completed handshake.
    /// Substituting this one verdict stands in for "the device trusts this
    /// chain" while the handshake and the `SecTrust` stay genuine
    /// (`RemoteAgentLiveTLSTrustTests`, Group B).
    ///
    /// `#if DEBUG` IS the security control: `{ _ in true }` here switches chain
    /// validation off for the whole file lane, and loopback plus self-addressed
    /// IPs are ATS-exempt, so App Transport Security is not a backstop behind
    /// it. A Release or Archive build cannot compile a call to this method
    /// because the method is not in it. Same fence, same reason, as
    /// `RemoteAgentTrustEvaluator`'s test-only initializer.
    nonisolated func respondToTaskTrustChallenge(
        _ session: URLSession,
        task: URLSessionTask,
        challenge: URLAuthenticationChallenge,
        evaluateSystemTrust: @escaping @Sendable (SecTrust) -> Bool,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        answerTaskTrustChallenge(
            session, task: task, challenge: challenge,
            makeEvaluator: {
                RemoteAgentTrustEvaluator(pinnedFingerprintHex: $0,
                                          evaluateSystemTrust: evaluateSystemTrust)
            },
            completionHandler: completionHandler)
    }
    #endif

    /// The shared body: resolve the task's pin, answer the challenge through the
    /// evaluator `makeEvaluator` builds for it, and RECORD the evaluator's own
    /// verdict against the task before forwarding the disposition. An UNPINNED
    /// challenge never reaches the evaluator at all — see the guard below.
    ///
    /// The recording is load-bearing. Once `completionHandler` runs, URLSession
    /// reports a cancelled challenge to `didCompleteWithError` as a bare
    /// `.cancelled` (-999) — the same code a benign task cancellation produces,
    /// for BOTH of the evaluator's refusals. Reading `systemTrustRejected` /
    /// `pinRejected` off the evaluator here is what keeps "this device does not
    /// trust the certificate" and "the pinned key disagreed" apart all the way
    /// to the user, and the per-task registry is what carries them across a
    /// long-lived, multi-transfer session that builds a fresh evaluator per
    /// challenge.
    private nonisolated func answerTaskTrustChallenge(
        _ session: URLSession,
        task: URLSessionTask,
        challenge: URLAuthenticationChallenge,
        makeEvaluator: (String?) -> RemoteAgentTrustEvaluator,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        // Only server-trust challenges take the pinning path (client-cert /
        // HTTP-auth → default handling), mirroring `STTClient+Background`.
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        // No pin → default ATS, and NO note recorded, matching the three sibling
        // converse lanes. The evaluator's `SecTrustEvaluateWithError` call is
        // ADVISORY: it also fails when evaluation could not COMPLETE (an OCSP
        // fetch needing the network), and on the unpinned path the evaluator does
        // not cancel — the system stays authoritative and may well accept the
        // chain, so the transfer succeeds with a note on file. That note would
        // then be free to relabel an ordinary later failure — a user cancelling a
        // staged upload, say — as "this device doesn't trust your file server's
        // certificate". With a pin the evaluator CANCELS a rejected chain, so a
        // note can only ever describe a connection that was actually refused.
        // The unpinned untrusted case is surfaced instead by the certificate arm
        // in `mapTransferError`, which keys on the codes where the SYSTEM named
        // the certificate.
        guard let pin = Self.effectiveTaskPin(
            taskDescription: task.taskDescription,
            hostPin: pinnedFingerprint(forHost: challenge.protectionSpace.host)
        ) else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        let evaluator = makeEvaluator(pin)
        let taskID = task.taskIdentifier
        evaluator.urlSession(session, didReceive: challenge) { disposition, credential in
            // Noted BEFORE the disposition is forwarded, and synchronously, so
            // the note is on file by the time URLSession delivers the task's
            // terminal callback.
            let signals = evaluator.attemptSignals
            if signals != .empty {
                self.queue.sync { self.trustSignalsByTaskID[taskID] = signals }
            }
            completionHandler(disposition, credential)
        }
    }

    /// The pin stamped onto a task's `taskDescription` envelope at enqueue. nil
    /// for an unpinned lane (→ default ATS) or a pre-update envelope (→ the
    /// legacy host lookup). Pure over its input and `internal`, so the resolution
    /// is unit-testable without a live session (`SecTrust` has no test
    /// constructor, and a `URLSessionTask` cannot be constructed either).
    static func taskPin(taskDescription: String?) -> String? {
        guard let pin = FileTransferBackgroundMetadata
            .decoded(from: taskDescription)?
            .pinnedFingerprintHex,
              !pin.isEmpty
        else { return nil }
        return pin
    }

    /// The pin a challenge on this task is answered with: the task's own
    /// envelope first, the caller-resolved `hostPin` as the legacy fallback, and
    /// `nil` — meaning "unpinned, default-handle it" — when neither yields a
    /// non-empty value. An empty string is NOT a pin; treating it as one would
    /// build an evaluator that can record a trust note for a lane the user never
    /// pinned. Pure over its inputs, so that rule is unit-testable without the
    /// live session the delegate needs.
    static func effectiveTaskPin(taskDescription: String?, hostPin: String?) -> String? {
        if let pin = taskPin(taskDescription: taskDescription) { return pin }
        guard let hostPin, !hostPin.isEmpty else { return nil }
        return hostPin
    }

    /// Refuse a cross-ORIGIN redirect; follow a same-origin one unchanged.
    /// Delegates the origin compare to `RemoteAgentTrustEvaluator.sameOrigin`,
    /// the app's ONE definition, so this lane cannot drift from the sessions that
    /// install the evaluator directly (Test Connection, the probe/delete/MKCOL
    /// ephemeral sessions, macOS foreground converse).
    ///
    /// SCOPE — read this before trusting it: URLSession delivers this callback
    /// only on the macOS build, whose transfer session is a `.default`
    /// configuration. On iOS the session is a BACKGROUND configuration, and the
    /// SDK contract is explicit that redirects there "will always be followed and
    /// this method will not be called". So on iOS the only pushback on a
    /// cross-host hop is the host-blind pin above — with none at all when the
    /// lane is unpinned. This is a real veto on one platform, not a guard on
    /// both.
    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        // `response.url` is the URL that ANSWERED with the 3xx — the origin this
        // hop was actually talking to, which across a chain is not the original.
        let from = response.url ?? task.currentRequest?.url ?? task.originalRequest?.url
        guard let target = request.url,
              let source = from,
              RemoteAgentTrustEvaluator.sameOrigin(source, target),
              target.scheme?.lowercased() == "https"
        else {
            // nil completes the task with the 3xx itself, which
            // `completionError(statusCode:isUpload:)` already maps to a plain
            // transfer failure (a visible, retryable outcome).
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }

    /// Forward upload progress to the per-task `onProgress` sink (0...1).
    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64,
                    totalBytesExpectedToSend: Int64) {
        guard totalBytesExpectedToSend > 0 else { return }
        let progress = Double(totalBytesSent) / Double(totalBytesExpectedToSend)
        let sink = queue.sync { inFlight[task.taskIdentifier]?.onProgress }
        sink?(min(max(progress, 0), 1))
    }

    /// Resume the continuation on completion (success or failure).
    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        queue.async {
            // Consume the per-task trust snapshot before any early return below,
            // so the registry cannot grow across dropped or duplicate callbacks.
            let trustSignals = self.trustSignalsByTaskID.removeValue(forKey: task.taskIdentifier) ?? .empty

            // No in-flight entry → this task completed in a RELAUNCHED process
            // (the in-memory registry was lost when the prior process died). We
            // deliberately drop it rather than recover from `taskDescription`'s
            // `FileTransferBackgroundMetadata`: unlike a converse reply (persisted
            // to the store → recoverable), a file UPLOAD's only consumer is the
            // EPHEMERAL staged composer tile, which is gone after a process kill —
            // there is nothing to resume the result INTO. The bytes that landed
            // server-side are a harmless orphan on the user's own file-server. The
            // metadata is still written (forward-compat + parity with
            // `BackgroundRemoteAgent`); `decoded(from:)` stays available for a
            // future V1.1 recovery surface (e.g. the PROPFIND browser).
            guard let entry = self.inFlight.removeValue(forKey: task.taskIdentifier) else { return }
            guard entry.cancellation?.claimTerminalCompletion() ?? true else { return }

            // HTTP-status mapping for completed-but-non-2xx responses. `isUpload`
            // routes the 409 create-parent-handshake sentinel to uploads only —
            // a 409 on a download stays the legacy `.fileTransferUploadFailed`.
            let isUpload: Bool
            switch entry.kind {
            case .upload:   isUpload = true
            case .download: isUpload = false
            }
            let statusError = Self.completionError(
                statusCode: (task.response as? HTTPURLResponse)?.statusCode,
                isUpload: isUpload)

            // OUR certificate refusal, resolved HERE because this is the last
            // place that can still see the task and therefore its trust
            // snapshot. Every one of the evaluator's refusals reaches us as a
            // bare `.cancelled` (-999); the snapshot is the only thing that says
            // which one, and
            // resolving it into an `AppError` now means `mapTransferError` (on
            // the caller's side of the continuation) passes it straight
            // through. With no verdict recorded nothing changes.
            let resolvedError: Error?
            if let urlError = error as? URLError,
               let certError = Self.trustError(urlError: urlError, signals: trustSignals) {
                resolvedError = certError
            } else {
                resolvedError = error
            }

            switch entry.kind {
            case .upload(let continuation):
                if let resolvedError {
                    continuation.resume(throwing: resolvedError)
                } else if let statusError {
                    continuation.resume(throwing: statusError)
                } else {
                    continuation.resume(returning: ())
                }
            case .download(let continuation):
                if let resolvedError {
                    continuation.resume(throwing: resolvedError)
                } else if let statusError {
                    // Body (if any) was moved to a temp URL; clean it up.
                    if let url = entry.downloadedURL { try? FileManager.default.removeItem(at: url) }
                    continuation.resume(throwing: statusError)
                } else if let url = entry.downloadedURL {
                    continuation.resume(returning: url)
                } else {
                    continuation.resume(throwing: AppError.fileTransferUploadFailed)
                }
            }
        }
    }
}

// MARK: - URLSessionDownloadDelegate (move body to caller-owned temp URL)

extension BackgroundFileTransfer: URLSessionDownloadDelegate {

    /// The system hands us a temp file that it deletes the moment this callback
    /// returns. Move it to our own temp URL (the caller owns cleanup) and stash
    /// the destination so `didCompleteWithError` can resume with it.
    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        // Only persist the body on a 2xx; a 4xx/5xx download body is an error
        // page we don't want to hand back as the "file".
        if let http = downloadTask.response as? HTTPURLResponse,
           !(200...299).contains(http.statusCode) {
            return
        }
        // The prefix is load-bearing: it is what makes this file reclaimable by
        // `TempScratchSweeper`. The caller owns cleanup, but a jetsam or crash
        // between here and the caller's `removeItem` strands downloaded agent
        // output in `tmp`, and a bare-UUID leaf matches no prefix rule that is
        // narrow enough to be safe — it would survive every future sweep.
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("conduck-download-\(UUID().uuidString)")
        do {
            try FileManager.default.moveItem(at: location, to: destination)
            queue.sync { inFlight[downloadTask.taskIdentifier]?.downloadedURL = destination }
        } catch {
            // Leave downloadedURL nil → didCompleteWithError throws fail-fast.
        }
    }
}

// MARK: - URLSessionDelegate (background events + legacy pin lookup)
//
// NO session-level `urlSession(_:didReceive:)` lives here, deliberately: it
// would take precedence over the TASK-level server-trust handler above, which is
// where the host-blind per-task pin is applied. Same shape as the three sibling
// background lanes.

extension BackgroundFileTransfer: URLSessionDelegate {

    /// Legacy host-keyed pin resolution, kept ONLY for a task enqueued by a build
    /// that predates `FileTransferBackgroundMetadata.pinnedFingerprintHex` and is
    /// still in flight across the update: the in-flight transfer's snapshot when
    /// one is live, else the durable per-ref pin read from App-Group defaults.
    ///
    /// The snapshot is the AUTHORITATIVE source while the process that enqueued
    /// the transfer is alive — it is the config the operation was started under,
    /// which is what `identitySignature` exists to guard against a mid-flight
    /// config edit. The durable fallback covers the case the snapshot cannot:
    /// iOS terminates the app mid-transfer and RELAUNCHES it to finish
    /// (`sessionSendsLaunchEvents = true` + `handleBackgroundSessionEvents` —
    /// a designed-for path, not a corner case), and the in-memory `inFlight`
    /// registry is empty after a kill. Without the fallback the resumed
    /// connection resolved no pin and degraded to default ATS, i.e. the user's
    /// file-server pin silently stopped applying across a relaunch.
    ///
    /// LIMIT (why the task-carried pin replaced it): keying off the CHALLENGE
    /// host means a redirect target the user never configured resolves to "no
    /// pin" and gets default ATS — the pin stops applying exactly where it
    /// matters. Current tasks take the host-blind path in the trust handler
    /// above; this one drains with the last pre-update transfer.
    private func pinnedFingerprint(forHost host: String) -> String? {
        let live = queue.sync { () -> String? in
            for entry in inFlight.values where entry.snapshot.baseURL.host == host {
                return entry.snapshot.certFingerprintHex
            }
            return nil
        }
        if let live { return live }
        return Self.durableFileServerPin(forHost: host)
    }

    /// The per-ref file-server pin stored for whichever configured ref's
    /// file-server base URL lives on `host`, read LIVE from App-Group defaults.
    /// `nil` when no configured ref matches, or its pin is unset/empty (→ default
    /// ATS, correct for Tailscale Serve / Let's Encrypt).
    ///
    /// Enumerates the built-in refs plus the custom-gateway roster because the
    /// pin key is per-ref and the challenge only carries a host. Nonisolated
    /// synchronous defaults read — safe in a trust delegate (no MainActor hop
    /// into `SettingsManager`) and relaunch-safe by construction.
    ///
    /// EDGE (same as the Watch resolver): two file servers on the SAME host
    /// differing only by port cannot each get their own pin — `URL.host`
    /// ignores the port, so the first matching ref's pin wins. Distinct hosts is
    /// the documented pinning recipe.
    ///
    /// `internal` (not `private`) so `@testable import` can lock the durable
    /// resolution — the relaunch path itself needs a device, but the lookup is
    /// pure over App-Group defaults and must not silently regress.
    nonisolated static func durableFileServerPin(forHost host: String) -> String? {
        let defaults = SettingsDependencies.processDefault.defaults
        var refs: [RemoteAgentRef] = RemoteAgentBackend.allCases.map { .builtin($0) }
        if let data = defaults.data(forKey: Constants.customGatewaysRegistryKey),
           let roster = try? JSONDecoder().decode([CustomGateway].self, from: data) {
            refs.append(contentsOf: roster.map(\.ref))
        }
        for ref in refs {
            guard let urlString = defaults.string(forKey: Constants.fileServerURLKey(for: ref)),
                  let refHost = URL(string: urlString)?.host(percentEncoded: false),
                  refHost.caseInsensitiveCompare(host) == .orderedSame,
                  let pin = defaults.string(forKey: Constants.fileServerCertFingerprintKey(for: ref)),
                  !pin.isEmpty
            else { continue }
            return pin
        }
        return nil
    }

    /// All background events for this session have been delivered — bridge the
    /// stored system completion handler back on the main queue.
    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        queue.async {
            let handler = self.backgroundCompletionHandler
            self.backgroundCompletionHandler = nil
            DispatchQueue.main.async { handler?() }
        }
    }
}


// MARK: - The pre-dispatch mint's outcome, and the lane state that bounds its cost

extension BackgroundFileTransfer {

    /// What naming a per-dispatch output folder produced. FIVE CASES, and the
    /// split between the silent three and the surfaced two is the contract:
    ///
    /// | Outcome | Folder on the wire | What the thread says |
    /// |---|---|---|
    /// | `.named` | yes | nothing (the chips speak for themselves) |
    /// | `.noLane` | no | nothing |
    /// | `.laneCannotReturn` | no | nothing |
    /// | `.witnessFailed` | no | the folder-less row |
    /// | `.witnessSuppressed` | no | the folder-less row |
    ///
    /// THE SILENT THREE ARE SILENT FOR THE SAME REASON: the user is not missing
    /// anything they were promised. No lane means they never asked for file
    /// return; a return-incapable lane is a limitation their Settings screen
    /// states plainly and no retry of the turn can change — repairing the server
    /// can, and `FileTransferCapabilityRefresher` notices when they do; a wrist
    /// turn is a device
    /// that holds no file-server credential by design. A row on any of those is
    /// a per-turn complaint about a standing, displayed, correct configuration.
    ///
    /// THE SURFACED TWO ARE SURFACED FOR THE OPPOSITE REASON: the lane WAS
    /// configured, WAS tested green, and stopped working. That is the one case
    /// where a turn quietly loses a capability the user is entitled to expect,
    /// and it is exactly the case that used to vanish.
    enum OutboxMintOutcome: Equatable, Sendable {
        /// A folder was named AND a server-observed absence witnessed it fresh.
        case named(String)
        /// No file lane on this dispatch — unconfigured, or a device (the
        /// Watch) that holds no file-server credential.
        case noLane
        /// The lane cannot answer a `PROPFIND` at all, so it can never return a
        /// file. A capability, not a fault — and one the STAGED test settled and
        /// persisted, never something this dispatch inferred.
        case laneCannotReturn
        /// The lane was probed this turn and did not witness the folder absent.
        case witnessFailed
        /// The lane has failed enough times in a row that it was not probed this
        /// turn. The turn is folder-less all the same.
        case witnessSuppressed

        /// The folder to put on the wire, or nil. The ONLY thing a caller that
        /// has nothing to say needs.
        var key: String? {
            if case .named(let key) = self { return key }
            return nil
        }

        /// Whether this outcome is a thing the user should be told about — the
        /// single predicate every surface asks, so "which outcomes are silent"
        /// is decided once here rather than re-derived per caller.
        var isActionableFault: Bool {
            switch self {
            case .witnessFailed, .witnessSuppressed: return true
            case .named, .noLane, .laneCannotReturn: return false
            }
        }
    }

    /// Process-local health state for the PRE-DISPATCH absence witness, so a
    /// file server that has stopped answering costs one turn's latency instead
    /// of every turn's.
    ///
    /// THE PROBLEM IT SOLVES. The witness sits on the dispatch critical path and
    /// every send waits for it — a pure-text turn that was never going to
    /// involve a file included. Against a lane that is simply gone that is the
    /// full `Constants.fileServerAbsenceWitnessTimeout` added to every message
    /// the user sends, indefinitely, for an answer that is not going to change.
    /// In this product the commonest cause is mundane: file-server URLs are
    /// frequently cloudflared quick tunnels whose hostname rotates on any tunnel
    /// restart, so a stale URL is the EXPECTED failure, not an exotic one.
    ///
    /// IT NEVER SWITCHES THE LANE OFF, and that is a spec-level constraint
    /// rather than a preference: the lane's own settings screen is the only
    /// place the user can repair it, and a lane the app disabled would take that
    /// control away at the exact moment it is needed. So this suppresses
    /// REQUESTS and nothing else — the configuration, the uploads, and what the
    /// thread says about a folder-less turn are all untouched.
    ///
    /// IT AUTHORS NO CAPABILITY EITHER, only caches one. `recordCannotReturn` is
    /// reachable exclusively through `noteStagedVerdict`, because the dispatch
    /// witness's `405`/`501` comes from a collection that certainly does NOT
    /// exist and therefore describes a route rather than the method (see this
    /// file's header). Everything else this type holds is a spending guess about
    /// whether another request is worth issuing — which is why it is safe for it
    /// to be process-local, and why it is never persisted or couriered: a guess
    /// about this instant, delivered late to another device, would withhold
    /// folders from a lane that recovered while the message was in flight.
    ///
    /// TWO THRESHOLDS, NOT ONE, because the two failure shapes deserve different
    /// patience. A lane that produced no HTTP response at all (`.unreachable`:
    /// DNS, refused, TLS, timeout) is the rotated-tunnel signature and opens the
    /// cooldown after ONE observation — three would spend ~12 s of the user's
    /// time to re-learn something already known. A lane that ANSWERED, with a
    /// rejected credential or a `5xx` or an occupied name, gets three: those are
    /// transient often enough that one sample is not a diagnosis, and a genuine
    /// one-in-a-billion name collision must not park a healthy lane.
    ///
    /// PROCESS-LOCAL AND UNPERSISTED, exactly like `FileLaneScanBreaker`. A
    /// relaunch buying one more probe is the cheapest possible escape for a lane
    /// that has since been repaired, and the spec is explicit that no
    /// missing-file verdict is persisted. The key is `durableLaneID` AND
    /// `identitySignature` together, so any edit to the URL, the credential or
    /// the device-local certificate pin lands on a brand-new key with a clean
    /// slate — "I just fixed my settings" needs no reset path, because the fixed
    /// lane is a different key. A passing staged Test Connection resets it
    /// outright on top of that, for the repairs that leave the identity
    /// untouched (a restarted server, a fixed reverse proxy, a DNS record).
    ///
    /// PRIVACY (see the spec's Privacy & Security section): the lane key is an
    /// opaque digest pair, never a URL and never a credential, and nothing in
    /// this type is logged, thrown, or persisted.
    nonisolated final class FileLaneWitnessBreaker: @unchecked Sendable {
        static let shared = FileLaneWitnessBreaker()

        /// What the mint should do about this lane, before it spends anything.
        enum Decision: Equatable {
            /// Issue the witness.
            case probe
            /// The STAGED test showed this lane incapable of answering a
            /// `PROPFIND`. Skip the request and stay silent.
            case cannotReturn
            /// This lane is inside its failure cooldown. Skip the request; the
            /// turn is still folder-less and the caller still says so.
            case cooldown
        }

        /// How much patience one failure earns. NOT a severity ranking of how
        /// bad the failure is — a ranking of how much a SECOND sample could
        /// still teach us.
        enum FailureSeverity: Equatable, Sendable {
            /// No HTTP response arrived. A host that is not there will not be
            /// there next turn.
            case unreachable
            /// The server answered, unhelpfully. Might not next turn.
            case answered

            /// Consecutive failures required before the cooldown opens.
            var opensAfter: Int {
                switch self {
                case .unreachable: return 1
                case .answered: return 3
                }
            }
        }

        /// One lane's witness state.
        ///
        /// TWO CLOCKS, on purpose. The cooldown is measured on
        /// `ContinuousClock` because a user-visible wall-clock correction must
        /// not collapse a backoff to zero or stretch it to a day. The streak's
        /// START is a wall-clock `Date` because its ONE consumer compares it
        /// against a message's `createdAt`, which is also wall clock — a
        /// monotonic instant cannot be compared with a stored date at all.
        private struct LaneState {
            /// nil = never measured. false = the server does not answer
            /// `PROPFIND`, which only the STAGED test may establish. true = it
            /// does, which a witnessed absence is enough to show.
            var returnCapable: Bool?
            var consecutiveFailures: Int = 0
            /// The `opensAfter` of the MOST RECENT failure. Held rather than
            /// recomputed so a streak that starts with two answered failures and
            /// then goes unreachable opens immediately, instead of waiting out a
            /// threshold set by evidence that is no longer the latest.
            var opensAfter: Int = FailureSeverity.answered.opensAfter
            /// How many rungs of `backoffLadder` this streak has climbed — i.e.
            /// how many of its failures arrived at or past the threshold that
            /// was in force AT THE TIME. COUNTED, never derived from
            /// `consecutiveFailures - opensAfter`, and that is the whole reason
            /// it exists: `opensAfter` is re-stamped by the LATEST failure, so a
            /// lane that answered unhelpfully twice (threshold 3, no cooldown
            /// yet) and then went unreachable (threshold 1) would compare a
            /// streak of three against a threshold of one and open its FIRST
            /// cooldown three rungs up — half an hour where five minutes was
            /// meant, on a lane the user may have repaired seconds ago.
            var pastThresholdFailures: Int = 0
            var lastFailureAt: ContinuousClock.Instant?
            /// When the CURRENT unbroken failure streak began. Cleared on any
            /// success. Nothing else in this type reads it.
            var streakStartedAt: Date?
        }

        /// The widening cadence a failing lane is re-probed on, indexed by how
        /// many failures past the threshold it has taken. Matches
        /// `FileLaneScanBreaker.faultBackoff` deliberately: the two breakers
        /// bound traffic to the SAME server, and a user watching one recover
        /// should not have to learn two different recovery rhythms.
        private static let backoffLadder: [TimeInterval] = [5 * 60, 15 * 60, 30 * 60, 60 * 60]

        /// Bound on tracked lanes. A wholesale clear is safe because this type
        /// parks nothing and owes nothing: a cleared breaker only means the next
        /// dispatch pays one probe again.
        private static let laneCeiling = 32

        private let lock = NSLock()
        private var lanes: [String: LaneState] = [:]

        private init() {}

        /// The identity a breaker entry is keyed on. Shares its shape with
        /// `FileLaneScanBreaker.laneKey(for:)` — `durableLaneID` alone would
        /// miss a certificate-pin change, which is device-local and deliberately
        /// excluded from the durable namespace id, and a pin change is one of
        /// the repairs that must reopen a suppressed lane instantly.
        static func laneKey(for snapshot: SettingsManager.FileTransferSnapshot) -> String {
            snapshot.durableLaneID + "\u{1}" + snapshot.identitySignature
        }

        static func backoff(pastThreshold: Int) -> TimeInterval {
            guard pastThreshold > 0 else { return backoffLadder[0] }
            return backoffLadder[min(pastThreshold, backoffLadder.count) - 1]
        }

        /// `decide` addressed by SNAPSHOT rather than by key, so a caller that
        /// holds the lane cannot key it differently from the way the mint does.
        func laneDecision(
            for snapshot: SettingsManager.FileTransferSnapshot,
            now: ContinuousClock.Instant = .now
        ) -> Decision {
            decide(lane: Self.laneKey(for: snapshot), now: now)
        }

        func decide(lane: String, now: ContinuousClock.Instant = .now) -> Decision {
            lock.lock()
            defer { lock.unlock() }
            guard let state = lanes[lane] else { return .probe }
            if state.returnCapable == false { return .cannotReturn }
            guard state.consecutiveFailures >= state.opensAfter,
                  let lastFailureAt = state.lastFailureAt else {
                return .probe
            }
            // The rung is the count this streak actually climbed, NOT the streak
            // length measured against the threshold the newest failure stamped —
            // those differ exactly when the severity changed mid-streak, and the
            // difference is rungs the user waits through that nobody meant them
            // to. Reaching here implies the latest failure was at or past the
            // threshold, so the count is at least one.
            let backoff = Self.backoff(pastThreshold: state.pastThresholdFailures)
            // Once the window expires ONE probe is allowed through — the
            // half-open step. It either succeeds and clears everything, or fails
            // and moves the ladder on one rung.
            return lastFailureAt.duration(to: now) < .seconds(backoff) ? .cooldown : .probe
        }

        /// The lane witnessed the folder absent: it is reachable, authorised,
        /// and speaks `PROPFIND`. Everything resets, including a previously
        /// recorded incapability — the app narrows on proof and must widen on
        /// proof too.
        func recordWitnessed(lane: String) {
            lock.lock()
            defer { lock.unlock() }
            evictIfNeeded()
            lanes[lane] = LaneState(returnCapable: true)
        }

        /// The lane answered that it does not implement `PROPFIND`. Recorded as
        /// a CAPABILITY rather than a failure, so it neither counts toward the
        /// streak nor decays out of a cooldown: there is nothing to wait for.
        ///
        /// ONLY `noteStagedVerdict` MAY REACH THIS, and the dispatch path
        /// deliberately cannot. The staged test asks the served root, a
        /// collection that certainly exists, which is the only question whose
        /// `405`/`501` answer is about the METHOD; the witness can only ask
        /// about a collection that by construction is not there, where the same
        /// answer is about the route. So this is a same-process cache of a
        /// verdict the staged test also persists — never a second, weaker author
        /// of one.
        func recordCannotReturn(lane: String) {
            lock.lock()
            defer { lock.unlock() }
            evictIfNeeded()
            lanes[lane] = LaneState(returnCapable: false)
        }

        /// One witness failure on `lane`.
        func recordFailure(
            lane: String,
            severity: FailureSeverity,
            now: ContinuousClock.Instant = .now,
            wallClock: Date = Date()
        ) {
            lock.lock()
            defer { lock.unlock() }
            evictIfNeeded()
            var state = lanes[lane] ?? LaneState(returnCapable: nil)
            state.consecutiveFailures += 1
            state.opensAfter = severity.opensAfter
            // A rung is climbed only by a failure that ARRIVES at or past the
            // threshold in force for it — evaluated after the re-stamp, so the
            // newest evidence sets the patience, and accumulated rather than
            // recomputed, so a threshold that drops mid-streak cannot back-date
            // rungs the lane never actually sat through.
            if state.consecutiveFailures >= state.opensAfter {
                state.pastThresholdFailures += 1
            }
            state.lastFailureAt = now
            if state.streakStartedAt == nil { state.streakStartedAt = wallClock }
            lanes[lane] = state
        }

        /// Apply the staged Test Connection's verdict. The one deliberate,
        /// user-watched measurement of this lane, so it supersedes whatever the
        /// dispatch path inferred — including a cooldown, which a passing test
        /// must clear outright or the user who just repaired their server would
        /// keep sending folder-less turns for up to an hour.
        func noteStagedVerdict(lane: String, returnCapable: Bool) {
            if returnCapable {
                recordWitnessed(lane: lane)
            } else {
                recordCannotReturn(lane: lane)
            }
        }

        /// When the lane's current unbroken failure streak began, or nil when it
        /// is not currently failing.
        ///
        /// THE CAUSALITY FILTER, and its only consumer is the thread's
        /// folder-less row. A turn that landed BEFORE this instant cannot have
        /// been folder-less because of this streak — it predates it — and
        /// without the comparison a single failure today would put the row under
        /// every wrist-originated turn in the thread's history, all of which are
        /// folder-less for a reason that is nobody's fault.
        ///
        /// Wall clock because a `MessageRecord.createdAt` is wall clock; there
        /// is no monotonic instant to compare it against. A clock correction can
        /// therefore mis-scope the row by the size of the correction, which
        /// costs a row that is shown or hidden and never a byte of data.
        func faultedSince(lane: String) -> Date? {
            lock.lock()
            defer { lock.unlock() }
            guard let state = lanes[lane], state.consecutiveFailures > 0 else { return nil }
            return state.streakStartedAt
        }

        /// Forget a lane entirely — an explicit user action saying it is worth
        /// another look right now.
        func reset(lane: String) {
            lock.lock()
            defer { lock.unlock() }
            lanes.removeValue(forKey: lane)
        }

        /// Test seam: drop everything. Production has no caller — a breaker that
        /// forgets on its own would forget mid-cooldown.
        func resetAll() {
            lock.lock()
            defer { lock.unlock() }
            lanes.removeAll()
        }

        /// Caller holds `lock`.
        private func evictIfNeeded() {
            guard lanes.count >= Self.laneCeiling else { return }
            lanes.removeAll()
        }
    }
}
