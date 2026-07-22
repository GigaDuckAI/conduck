// Conduck
// AppleSpeechRelayCoordinator.swift (Watch target)
//
// Apple Native STT as the 6th provider. Watch-side coordinator
// for the "Option B" relay protocol: Watch ships its already-compressed
// .m4a recording to iPhone, awaits a transcript reply, and surfaces it to
// the caller as if it were a normal STT response. Correlation is by
// `requestID` — now a CLAIM TOKEN minted by the caller and persisted in
// `AppleRelayPendingQueue` BEFORE the first delivery attempt, so timeouts,
// retries, and process restarts all converge on the same id (the iPhone
// dedups by it and re-serves a cached verdict on a retry, never
// re-transcribing).
//
// Wire protocol (mirrors iOS-side coordinator — values must stay
// byte-for-byte identical; see the `Wire` enum):
//   Watch → iPhone, fast path (sendMessage, reachable + clip ≤ 50 KB):
//     ["requestID": UUID-string, "kind": "apple-speech-relay",
//      "audio": Data, "language": optional BCP-47 hint,
//      "providerID": optional, "replySendMessageOK": true]
//     replyHandler ACK = DELIVERY RECEIPT ONLY — the transcript ALWAYS
//     arrives via the async reply channel below (uniform path; the ACK is
//     never coupled to transcription duration).
//   Watch → iPhone, queued path (transferFile):
//     metadata = ["requestID": …, "kind": "apple-speech-relay",
//                 "language": …, "providerID": …, "replySendMessageOK": true]
//     plus a fire-and-forget wake-ping `sendMessage(["kind":
//     "apple-speech-relay-wake"])` when reachable so a suspended iPhone
//     app gets launched to service the queued file.
//   iPhone → Watch (sendMessage when reachable AND the request stamped
//   `replySendMessageOK`; else transferUserInfo):
//     ["requestID": UUID, "kind": "apple-speech-relay-reply",
//      "result.text": String]   on success
//     ["requestID": UUID, "kind": "apple-speech-relay-reply",
//      "result.errorCode": Int] on failure (AppError.errorCode)
//
// Timeout: 30 s for the Apple on-device path, 120 s for the BYO custom
// endpoint (network-bound on the iPhone side). On timeout we throw
// `AppError.sttProviderUnreachable` to the caller — the audio is ALREADY
// queued in `AppleRelayPendingQueue` (enqueue-first invariant), so the
// timeout is purely a UX signal ("will arrive later"), never a data-loss
// boundary. A reply landing AFTER the timeout no longer evaporates: with
// no continuation registered, `handleReply` routes the verdict to
// `AppleRelayPendingQueue.reconcile(requestID:outcome:)`, which claims the
// persisted entry and dispatches the deferred converse hop exactly once.
//
// Privacy invariant: never log audio bytes, transcripts, full request
// UUIDs (`prefix(8)` only), file paths, or language hints. DEBUG prints
// are state-only.

import Foundation
import WatchConnectivity

/// Terminal verdict parsed from an inbound relay reply. Factored out of
/// `handleReply` so the SAME parse feeds both delivery targets:
///   • live continuation → resume the awaiting `relay(...)` call (the
///     pre-timeout happy path);
///   • continuation ABSENT (timeout already fired, or the process was
///     relaunched since the request left) → hand the verdict to
///     `AppleRelayPendingQueue.reconcile(requestID:outcome:)` instead of
///     dropping it — the old "unknown request — dropping" path is exactly
///     why late replies never converged.
enum RelayReplyOutcome {
    case success(String)
    case failure(AppError)
}

/// Actor managing per-request continuations for outbound relay requests
/// and inbound reply correlation. Single instance per process.
actor AppleSpeechRelayCoordinator {
    static let shared = AppleSpeechRelayCoordinator()

    /// Wire-protocol literals — kept identical to the iOS-side
    /// coordinator's `Wire` enum so a manual diff catches drift.
    enum Wire {
        static let kindKey = "kind"
        static let kindValue = "apple-speech-relay"
        static let replyKind = "apple-speech-relay-reply"
        static let requestIDKey = "requestID"
        static let languageKey = "language"
        static let resultTextKey = "result.text"
        static let resultErrorCodeKey = "result.errorCode"
        /// Custom-STT V1.x: which STT provider the iPhone should run for this
        /// relayed clip. Absent/nil ⇒ the iPhone transcribes with ITS current
        /// active provider — the iPhone is the settings authority, so a stale
        /// Watch config can't pin the relay to the wrong engine. For an
        /// Apple-active user that resolves to Apple on-device
        /// (`AppleSpeechRunner`), making the legacy "absent ⇒ Apple" meaning a
        /// strict subset. `"custom-openai"` ⇒ iPhone routes to
        /// `STTClient.transcribe(provider: .customOpenAICompat)` (it alone holds
        /// the base URL / cert pin / long timeout). Never carries a key or URL.
        static let providerIDKey = "providerID"
        /// Inline fast path: the compressed clip rides the interactive
        /// `sendMessage` channel as raw `Data` under this key (request
        /// payload only — never present in `transferFile` metadata).
        static let audioKey = "audio"
        /// Fire-and-forget wake-ping kind sent alongside a `transferFile`
        /// when the iPhone is reachable — `sendMessage` launches a suspended
        /// counterpart app, so the queued file gets serviced promptly instead
        /// of waiting for the next organic launch.
        static let wakeKind = "apple-speech-relay-wake"
        /// Capability stamp (Bool, `true`): this Watch build understands
        /// replies on the interactive `sendMessage` channel. Stamped into
        /// BOTH the inline payload and the `transferFile` metadata. The
        /// iPhone replies via `sendMessage` only when the request carried
        /// this key — stale-watch-build safety (an old build that never
        /// filled `didReceiveMessage` keeps getting `transferUserInfo`).
        static let supportsMessageReplyKey = "replySendMessageOK"
    }

    // MARK: - Tuning constants

    /// Reply-wait budget for the Apple on-device path (`providerID == nil`).
    /// The clip + transcription round-trip is local to the phone, so 30 s of
    /// silence means "not happening NOW" — the user gets the deferral toast
    /// while the queued entry keeps working in the background. A nil-provider
    /// relay may now include a fast cloud-STT hop on the iPhone (it transcribes
    /// with its active provider); 30 s stays correct because the timeout is a
    /// pure UX deferral (enqueue-first + late-reply reconcile mean no data
    /// loss), and the 120 s budget remains reserved for the explicitly-stamped
    /// BYO/Tailscale path.
    static let appleRelayReplyTimeoutSeconds: TimeInterval = 30

    /// Reply-wait budget for the BYO custom-endpoint relay (`providerID`
    /// present). That path is network-bound on the iPhone side (user's own
    /// server, possibly over Tailscale with a long upload), so 30 s would
    /// misread a slow-but-healthy transcription as "unreachable".
    static let customRelayReplyTimeoutSeconds: TimeInterval = 120

    /// Ceiling for the inline `sendMessage` fast path. WatchConnectivity's
    /// interactive channel has an undocumented payload cap (~64 KB); 50 KB
    /// of 16 kHz mono AAC ≈ 8 s of speech — the typical short ask. Bigger
    /// clips take the queued `transferFile` path.
    static let inlineAudioByteLimit = 50 * 1024

    /// Per-request continuation map. Key is the `requestID` UUID string.
    /// On reply or timeout we look up, remove, and resume.
    private var pending: [String: CheckedContinuation<String, Error>] = [:]

    private init() {}

    /// Relay an audio file to the iPhone for transcription. The iPhone runs
    /// either its current active provider (nil `providerID`) or — when
    /// `providerID == "custom-openai"` — the user's BYO custom OpenAI-compatible
    /// endpoint, depending on the `providerID` stamped into the relay payload.
    /// Returns the transcript text on success; throws on timeout or on a reply
    /// that carries an `errorCode`.
    ///
    /// `requestID` is CALLER-MINTED (the claim token): `WatchRecordingService`
    /// mints + enqueues it BEFORE calling here, and `AppleRelayPendingQueue.drain`
    /// re-fires with the entry's PERSISTED id — so every retry converges on the
    /// same id and the iPhone's dedup ledger can answer from cache instead of
    /// re-transcribing.
    ///
    /// `providerID` defaults to nil ⇒ the iPhone transcribes with ITS current
    /// active provider — the iPhone is the settings authority, so a Watch whose
    /// envelope queue hasn't drained can't pin the relay to a stale engine. For
    /// an Apple-active user that resolves to Apple on-device (the legacy
    /// meaning is a strict subset; no wire change). The Watch never holds the
    /// custom endpoint's URL / key / cert — only the iPhone does — so for the
    /// custom provider this relay is the ONLY transcription path on the wrist
    /// (a direct lookup would fall back to Mistral, a privacy bug guarded
    /// against in `WatchRecordingService`).
    ///
    /// `skipOutstandingCheck`: set ONLY by the drain's cancel+refire path,
    /// which has JUST cancelled this requestID's wedged file transfer.
    /// `WCSessionFileTransfer.cancel()`'s removal timing from
    /// `outstandingFileTransfers` is undocumented — if the zombie still
    /// showed up there, `deliver`'s duplicate guard would send NOTHING and
    /// burn a full reply timeout waiting on a transfer that will never land.
    ///
    /// Throws (caller surfaces):
    ///   - `.sttProviderUnreachable`: reply-wait timeout (30 s Apple / 120 s
    ///     custom). The entry is already persisted in the pending queue, so
    ///     this is a "won't happen NOW" signal, not a failure — the caller
    ///     shows the deferral toast and the reply reconciles when it lands.
    ///   - `.appleSpeechModelNotInstalled`: iPhone responded but the
    ///     model for `language` isn't installed (Apple path). User must open
    ///     iPhone Conduck → Settings to download.
    ///   - `.sttCustomEndpointNotConfigured`: iPhone responded but no custom
    ///     base URL is configured there (custom path).
    ///   - Other `AppError` cases as mapped from the iPhone-side `errorCode`.
    func relay(requestID: String, audioFileURL: URL, language: String?, providerID: String? = nil, skipOutstandingCheck: Bool = false) async throws -> String {
        var metadata: [String: Any] = [
            Wire.requestIDKey: requestID,
            Wire.kindKey: Wire.kindValue,
            // Capability stamp — see `Wire.supportsMessageReplyKey`. Goes in
            // BOTH the inline payload (built from this dict) and the
            // transferFile metadata so the iPhone can upgrade the reply
            // channel regardless of which request path was taken.
            Wire.supportsMessageReplyKey: true,
        ]
        if let language, !language.isEmpty {
            metadata[Wire.languageKey] = language
        }
        // Carry the provider ID only for the BYO custom endpoint — the Apple
        // path omits it so the legacy wire contract (and an older iPhone build)
        // is byte-for-byte unchanged.
        if let providerID, !providerID.isEmpty {
            metadata[Wire.providerIDKey] = providerID
        }

        // Per-provider reply budget: local Apple transcription vs the
        // network-bound custom-endpoint hop.
        let timeoutSeconds = providerID == nil
            ? Self.appleRelayReplyTimeoutSeconds
            : Self.customRelayReplyTimeoutSeconds

        // Schedule the timeout. If the reply lands first, we cancel the timer
        // by removing the continuation; if the timer fires first we resume
        // with .sttProviderUnreachable (the queued entry remains — see the
        // header).
        //
        // Continuation-registration ordering invariant: the timeout Task
        // closure starts on a non-actor context and sleeps before requesting
        // an actor hop via `await self?.fireTimeout`. By the time that hop
        // runs, the synchronous `pending[requestID] = continuation` below has
        // long since executed under actor isolation. If a 0-second timeout
        // variant is ever introduced, restructure so the continuation is
        // registered before the timeout Task is created.
        let timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.fireTimeout(for: requestID)
        }

        do {
            let text = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
                pending[requestID] = continuation
                // Deliver only AFTER the continuation is registered — the
                // inline path's reply can be near-instant, and a reply
                // racing an unregistered continuation would fall into the
                // reconcile path and double-handle a live request.
                deliver(
                    requestID: requestID,
                    audioFileURL: audioFileURL,
                    metadata: metadata,
                    skipOutstandingCheck: skipOutstandingCheck
                )
            }
            timeoutTask.cancel()
            return text
        } catch {
            timeoutTask.cancel()
            throw error
        }
    }

    /// Process an inbound reply payload. Called from `WatchSessionManager`
    /// for BOTH ingress channels — `session(_:didReceiveMessage:)` (the new
    /// interactive reply path) and `session(_:didReceiveUserInfo:)` (the
    /// queued path) — when `kind == "apple-speech-relay-reply"`.
    ///
    /// Continuation present → resume it (live request). ABSENT → the request
    /// timed out (or the process restarted since it left): route the verdict
    /// to `AppleRelayPendingQueue.reconcile` so the persisted entry converges
    /// instead of the reply being dropped — the drop is what made every
    /// post-timeout retry mint a fresh id and never converge.
    func handleReply(_ payload: [String: Any]) {
        guard let requestID = payload[Wire.requestIDKey] as? String else {
            #if DEBUG
            print("[Watch] Apple relay reply without requestID — dropping")
            #endif
            return
        }

        // Parse the verdict ONCE; both delivery targets consume the same
        // outcome. Malformed (neither text nor errorCode) ⇒ the upstream
        // wire contract was violated by something on the iPhone side.
        let outcome: RelayReplyOutcome
        if let text = payload[Wire.resultTextKey] as? String {
            outcome = .success(text)
        } else if let code = payload[Wire.resultErrorCodeKey] as? Int {
            // Map code → AppError. Code 18 is `.appleSpeechModelNotInstalled`;
            // unknown codes fall through to `.apiFailure` per the static
            // helper. We construct without a message — the receiver's
            // localized errorDescription is the user-facing surface.
            outcome = .failure(AppError.from(errorCode: code, message: nil))
        } else {
            outcome = .failure(.sttDecodingFailure)
        }

        if let continuation = pending.removeValue(forKey: requestID) {
            switch outcome {
            case .success(let text):
                continuation.resume(returning: text)
                #if DEBUG
                print("[Watch] Apple relay reply success (id=\(requestID.prefix(8)))")
                #endif
            case .failure(let err):
                continuation.resume(throwing: err)
                #if DEBUG
                print("[Watch] Apple relay reply error (id=\(requestID.prefix(8)))")
                #endif
            }
            return
        }

        // No live continuation — late reply or post-relaunch reply. Reconcile
        // against the persisted queue (claim-token semantics: claim-fail there
        // means a duplicate/evicted verdict and is dropped silently).
        #if DEBUG
        print("[Watch] Apple relay reply with no live continuation (id=\(requestID.prefix(8))) — reconciling")
        #endif
        Task { @MainActor in
            await AppleRelayPendingQueue.shared.reconcile(requestID: requestID, outcome: outcome)
        }
    }

    // MARK: - Delivery

    /// Channel selection for an outbound relay request. Runs synchronously
    /// under actor isolation right after the continuation is registered.
    ///
    ///   a. A prior attempt's file transfer is still in the WCSession outbox
    ///      for this requestID → send NOTHING (re-sending would double-deliver;
    ///      the existing transfer + the freshly armed continuation suffice).
    ///   b. Reachable AND the clip fits the interactive cap → inline
    ///      `sendMessage` with the audio bytes (the ~1–2 s fast path). The
    ///      replyHandler ACK is a delivery receipt ONLY; on errorHandler we
    ///      fall through to the queued file path with the SAME requestID.
    ///   c. Queued `transferFile` (+ capability stamp in metadata) plus a
    ///      fire-and-forget wake-ping when reachable so a suspended iPhone
    ///      app gets launched to service the file.
    private func deliver(requestID: String, audioFileURL: URL, metadata: [String: Any], skipOutstandingCheck: Bool) {
        let session = WCSession.default

        // (a) In-flight duplicate guard — keyed on the persisted claim token.
        // Bypassed when the caller (drain's cancel+refire) JUST cancelled the
        // matching transfer: `cancel()`'s removal from
        // `outstandingFileTransfers` has undocumented timing, and treating
        // the lingering zombie as "still in flight" would send nothing and
        // burn a full reply timeout.
        if !skipOutstandingCheck {
            let priorTransferOutstanding = session.outstandingFileTransfers.contains {
                ($0.file.metadata?[Wire.requestIDKey] as? String) == requestID
            }
            if priorTransferOutstanding {
                #if DEBUG
                print("[Watch] Apple relay: prior transfer still outstanding (id=\(requestID.prefix(8))) — waiting, not re-sending")
                #endif
                return
            }
        }

        // (b) Inline fast path. Size-check via resourceValues so we never
        // load a multi-MB clip into memory just to discover it doesn't fit.
        let byteCount = (try? audioFileURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? Int.max
        if session.isReachable,
           byteCount <= Self.inlineAudioByteLimit,
           let audioData = try? Data(contentsOf: audioFileURL) {
            var payload = metadata
            payload[Wire.audioKey] = audioData
            session.sendMessage(
                payload,
                replyHandler: { _ in
                    // ACK = delivery receipt only. The transcript ALWAYS
                    // arrives via the async reply channel (didReceiveMessage /
                    // didReceiveUserInfo) so the ACK latency is never coupled
                    // to transcription duration.
                },
                errorHandler: { [weak self] _ in
                    // Interactive send failed (counterpart suspended, channel
                    // dropped mid-flight) — fall back to the queued file path
                    // with the SAME requestID so the iPhone dedup ledger
                    // converges if both somehow arrive.
                    self?.sendViaFileTransfer(audioFileURL: audioFileURL, metadata: metadata)
                }
            )
            #if DEBUG
            print("[Watch] Apple relay request sent inline (id=\(requestID.prefix(8)))")
            #endif
            return
        }

        // (c) Queued file path.
        sendViaFileTransfer(audioFileURL: audioFileURL, metadata: metadata)
        #if DEBUG
        print("[Watch] Apple relay request queued (id=\(requestID.prefix(8)))")
        #endif
    }

    /// Queued delivery: `transferFile` survives reachability gaps and process
    /// suspension on both ends. The wake-ping rides the interactive channel
    /// when available — receiving a `sendMessage` launches a suspended
    /// counterpart app (file transfers alone may sit until the next organic
    /// launch). Fire-and-forget: no replyHandler, errors ignored (the file
    /// transfer is the delivery of record).
    ///
    /// `nonisolated` + synchronous so the inline path's errorHandler (which
    /// arrives on a WatchConnectivity system queue) can call it directly
    /// without an actor hop — WCSession itself is thread-safe.
    nonisolated private func sendViaFileTransfer(audioFileURL: URL, metadata: [String: Any]) {
        let session = WCSession.default
        _ = session.transferFile(audioFileURL, metadata: metadata)
        if session.isReachable {
            session.sendMessage([Wire.kindKey: Wire.wakeKind], replyHandler: nil, errorHandler: nil)
        }
    }

    // MARK: - Internal

    private func fireTimeout(for requestID: String) {
        guard let continuation = pending.removeValue(forKey: requestID) else {
            return
        }
        #if DEBUG
        print("[Watch] Apple relay timeout (id=\(requestID.prefix(8)))")
        #endif
        continuation.resume(throwing: AppError.sttProviderUnreachable)
    }
}
