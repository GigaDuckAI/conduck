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
//     so a cross-origin redirect target must present the pinned key
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

    /// Serial queue guarding `inFlight`.
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
        let session = makeEphemeralSession(snapshot: snapshot)
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
                // caller-owned path while leaving an unrelated `.cancelled`
                // transport verdict available for the cert-mismatch mapper.
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
    func probeExists(snapshot: SettingsManager.FileTransferSnapshot,
                     storedKey: String) async -> FileProbeOutcome {
        let request = FileServerClient.buildProbeRequest(snapshot: snapshot, storedKey: storedKey)
        let session = Self.makeEphemeralSession(snapshot: snapshot)
        defer { session.finishTasksAndInvalidate() }
        do {
            // `bytes(for:)` (NOT `data(for:)`): the response headers arrive
            // before the body, and the outcome is fully determined by the status
            // — so cancel the underlying task the instant we have the response,
            // BEFORE iterating the stream. A BYO server that ignores our
            // `Range: bytes=0-0` and answers a full 200 would otherwise have
            // `data(for:)` buffer the ENTIRE file into memory.
            let (bytes, response) = try await session.bytes(for: request)
            bytes.task.cancel()
            guard let http = response as? HTTPURLResponse else { return .unknown }
            return FileServerClient.parseProbeOutcome(status: http.statusCode)
        } catch {
            // A transport failure (unreachable / cert reject / cancel) is not a
            // definitive "missing"; report unknown so callers don't false-delete.
            return .unknown
        }
    }

    /// Existence probe variant that ALSO returns the file's total byte length.
    /// Used ONLY by the output-download detector so the chip can render the size
    /// and gate a soft-confirm on very large downloads. Issues the SAME ranged
    /// GET as `probeExists` and parses the total length from the SAME headers,
    /// but streams via `bytes(for:)` and cancels on the response so a
    /// `Range`-ignoring server's full 200 never buffers the whole file into
    /// memory. Never throws — mirrors `probeExists` on the outcome; size is `nil`
    /// when the length can't be determined (caller treats nil as "unknown" → no
    /// size, no gate).
    func probeExistsWithLength(snapshot: SettingsManager.FileTransferSnapshot,
                               storedKey: String) async -> (FileProbeOutcome, Int64?) {
        let request = FileServerClient.buildProbeRequest(snapshot: snapshot, storedKey: storedKey)
        let session = Self.makeEphemeralSession(snapshot: snapshot)
        defer { session.finishTasksAndInvalidate() }
        do {
            // See `probeExists`: `bytes(for:)` + immediate task cancel — the
            // total length comes from the response HEADERS (Content-Range on a
            // 206 / Content-Length on a 200), so the body is never needed.
            let (bytes, response) = try await session.bytes(for: request)
            bytes.task.cancel()
            guard let http = response as? HTTPURLResponse else { return (.unknown, nil) }
            let outcome = FileServerClient.parseProbeOutcome(status: http.statusCode)
            // Only a present file carries a meaningful length; other outcomes → nil.
            let size = outcome == .exists ? Self.parseProbeTotalLength(from: http) : nil
            return (outcome, size)
        } catch {
            // Same fail-closed contract as `probeExists`: transport failure is not
            // a definitive "missing", and it carries no size.
            return (.unknown, nil)
        }
    }

    /// Parse a file's TOTAL byte length from a ranged-probe (`bytes=0-0`) response.
    /// Prefers `Content-Range: bytes 0-0/<total>` (a 206 — rclone's answer to the
    /// range) and takes the total AFTER the slash; falls back to `Content-Length`
    /// (a 200, when the server ignored `Range` and returned the whole body — then
    /// Content-Length IS the full size). Returns `nil` when neither is parseable
    /// (e.g. a `*` total in Content-Range, or no length header at all).
    private static func parseProbeTotalLength(from http: HTTPURLResponse) -> Int64? {
        // 206: total is the segment after the final `/` in `bytes 0-0/<total>`.
        // NOTE: on a 206 the body is 1 byte, so `Content-Length` here is NOT the
        // total — Content-Range is the only correct source; check it first. A `*`
        // total (`bytes 0-0/*`, "complete-length unknown") or an absent
        // Content-Range on a 206 yields nil, NOT the 1-byte Content-Length below.
        if let contentRange = http.value(forHTTPHeaderField: "Content-Range"),
           let slash = contentRange.lastIndex(of: "/") {
            let totalPart = contentRange[contentRange.index(after: slash)...]
                .trimmingCharacters(in: .whitespaces)
            if let total = Int64(totalPart) { return total }
        }
        // Content-Length is the whole-file total ONLY on a 200 (server ignored the
        // Range → the FULL body came back). It must NEVER be trusted on a 206 (it
        // is the 1-byte range size) — gating on the status is what stops a large
        // ranged file being reported as 1 byte and bypassing the download confirm.
        if http.statusCode == 200,
           let contentLength = http.value(forHTTPHeaderField: "Content-Length"),
           let total = Int64(contentLength.trimmingCharacters(in: .whitespaces)) {
            return total
        }
        return nil
    }

    /// Bounded best-effort download of `storedKey`'s LEADING bytes for preview
    /// enrichment (WS-2). Returns `(data, received)`: `data` is the file content
    /// ONLY when the whole body arrived complete and ≤ `maxBytes` (else `nil` on
    /// any error, non-2xx, or the instant the accumulated bytes exceed
    /// `maxBytes`); `received` is the byte count ACTUALLY pulled off the server at
    /// exit, reported on EVERY outcome so the caller can charge its
    /// source-download budget honestly — 0 for a non-2xx (body never consumed),
    /// the partial count for a mid-stream transport error, and ~`maxBytes + 1`
    /// for the over-cap bail (a Range-ignoring 200 / lying `Content-Length` still
    /// cost that bandwidth even though no preview is returned).
    ///
    /// Ranged to `bytes=0-<maxBytes-1>` so a compliant server saves bandwidth,
    /// but the cap is enforced CLIENT-side and is the real safety: a server that
    /// ignores `Range` (full `200`) or lies about / omits `Content-Length` must
    /// NEVER buffer past the cap. Streams via `session.bytes(for:)` and cancels
    /// the underlying task the moment the running total crosses `maxBytes`, so a
    /// Range-ignoring 200 of a huge file reads at most `maxBytes + 1` bytes before
    /// bailing. A missing `Content-Length` stays eligible (the cap protects).
    ///
    /// PRIVACY: never logs the URL, storedKey, credential, or
    /// bytes — mirrors `probeExists`.
    func fetchBounded(snapshot: SettingsManager.FileTransferSnapshot,
                      storedKey: String,
                      maxBytes: Int) async -> (data: Data?, received: Int64) {
        guard maxBytes > 0 else { return (nil, 0) }
        // Reuse the download request builder (auth header + URL), then narrow it:
        // a leading-range GET on the interactive probe timeout (this is a small
        // best-effort preview fetch, not a bulk transfer).
        var request = FileServerClient.buildDownloadRequest(snapshot: snapshot, storedKey: storedKey)
        request.setValue("bytes=0-\(maxBytes - 1)", forHTTPHeaderField: "Range")
        request.timeoutInterval = Constants.fileServerProbeTimeout
        let session = Self.makeEphemeralSession(snapshot: snapshot)
        defer { session.finishTasksAndInvalidate() }
        return await Self.streamBounded(session: session, request: request, maxBytes: maxBytes)
    }

    /// Pure streaming/cap seam behind `fetchBounded` — `internal static` so a
    /// `URLProtocol`-stubbed session can unit-test the accumulation + hard-stop
    /// without a live file-server. Accepts only `200`/`206`; returns `(body,
    /// received)` iff the stream completed with total ≤ `maxBytes`. Returns
    /// `(nil, received)` the instant the total exceeds `maxBytes` (the
    /// Range-ignoring / lying-length guard — `received` ≈ `maxBytes + 1`, the
    /// bytes actually pulled), `(nil, 0)` on a non-2xx (body never consumed), and
    /// `(nil, partial)` on a mid-stream transport error. `received` is ALWAYS the
    /// bytes drained off the wire so the caller charges its budget on every
    /// attempt, success or not.
    static func streamBounded(session: URLSession, request: URLRequest, maxBytes: Int) async -> (data: Data?, received: Int64) {
        guard maxBytes > 0 else { return (nil, 0) }
        var received: Int64 = 0
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse,
                  http.statusCode == 200 || http.statusCode == 206 else {
                bytes.task.cancel()
                return (nil, 0)   // non-2xx: cancelled before the body → nothing pulled
            }
            var accumulated = Data()
            accumulated.reserveCapacity(min(maxBytes, 1 << 20))
            for try await byte in bytes {
                accumulated.append(byte)
                received += 1
                // HARD client-side stop: one byte past the cap → cancel + drop.
                // A Range-ignoring 200 (or a lying Content-Length) can never
                // buffer the whole file — we bail at maxBytes + 1, and report
                // those bytes as received so the budget is charged for them.
                if accumulated.count > maxBytes {
                    bytes.task.cancel()
                    return (nil, received)
                }
            }
            // Completed within the cap → the (possibly range-truncated) body.
            return (accumulated, received)
        } catch {
            // Transport failure / cancellation → no preview, but the partial
            // bytes drained before the error still cost bandwidth.
            return (nil, received)
        }
    }

    /// Best-effort delete of an orphaned `storedKey` (e.g. user cancelled a send
    /// after the upload landed). Never throws — orphan cleanup is non-critical.
    func deleteFile(snapshot: SettingsManager.FileTransferSnapshot,
                    storedKey: String) async {
        let request = FileServerClient.buildDeleteRequest(snapshot: snapshot, storedKey: storedKey)
        let session = Self.makeEphemeralSession(snapshot: snapshot)
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

    /// A short-lived, cert-pinned session for interactive probe/delete/MKCOL requests.
    /// The `RemoteAgentTrustEvaluator` IS the delegate (the session retains it
    /// until invalidated), so this lane gets the pin compare AND the cross-host
    /// redirect refusal from the one shared trust component instead of a
    /// look-alike wrapper that could drift from it. The pin is applied host-blind
    /// — a redirect target's cert cannot match, which is the fail-closed answer.
    private static func makeEphemeralSession(snapshot: SettingsManager.FileTransferSnapshot) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = Constants.fileServerProbeTimeout
        config.timeoutIntervalForResource = Constants.fileServerProbeTimeout
        let evaluator = RemoteAgentTrustEvaluator(
            pinnedFingerprintHex: snapshot.certFingerprintHex)
        return URLSession(configuration: config, delegate: evaluator, delegateQueue: nil)
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

    /// Map a transport-layer error to the file-transfer AppError family.
    /// Never reveals credentials.
    private static func mapTransferError(_ error: Error, fallback: AppError) -> AppError {
        if let appError = error as? AppError { return appError }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .userAuthenticationRequired:
                return .fileTransferAuthFailed
            case .serverCertificateUntrusted,
                 .serverCertificateHasBadDate,
                 .serverCertificateHasUnknownRoot,
                 .serverCertificateNotYetValid,
                 .cancelled:
                // The specific server-certificate codes name the cert as the
                // cause; `.cancelled` here is the trust-evaluator rejecting a
                // pinned mismatch (it cancels the auth challenge).
                return .fileTransferCertMismatch
            case .notConnectedToInternet,
                 .cannotConnectToHost,
                 .cannotFindHost,
                 .dnsLookupFailed,
                 .timedOut,
                 .networkConnectionLost,
                 .secureConnectionFailed:
                // GENERIC SSL failure (`-1200`) is NOT a cert-trust signal on
                // its own; this long-lived background session can't read the
                // per-challenge trust signals, so treat it as a transient
                // handshake failure → unreachable, NOT a false cert mismatch.
                return .fileTransferUnreachable
            default:
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
        // Only server-trust challenges take the pinning path (client-cert /
        // HTTP-auth → default handling), mirroring `STTClient+Background`.
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        let pin = Self.taskPin(taskDescription: task.taskDescription)
            ?? pinnedFingerprint(forHost: challenge.protectionSpace.host)
        let evaluator = RemoteAgentTrustEvaluator(pinnedFingerprintHex: pin)
        evaluator.urlSession(session, didReceive: challenge, completionHandler: completionHandler)
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

            switch entry.kind {
            case .upload(let continuation):
                if let error {
                    continuation.resume(throwing: error)
                } else if let statusError {
                    continuation.resume(throwing: statusError)
                } else {
                    continuation.resume(returning: ())
                }
            case .download(let continuation):
                if let error {
                    continuation.resume(throwing: error)
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
    /// differing only by port is an unsupported self-signed-pin case — `URL.host`
    /// ignores the port, so the first matching ref's pin wins. Distinct hosts is
    /// the documented pinning recipe.
    ///
    /// `internal` (not `private`) so `@testable import` can lock the durable
    /// resolution — the relaunch path itself needs a device, but the lookup is
    /// pure over App-Group defaults and must not silently regress.
    nonisolated static func durableFileServerPin(forHost host: String) -> String? {
        let defaults = UserDefaults(suiteName: Constants.appGroupID) ?? .standard
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

