// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Pure classifier for the background converse completion
/// (`WatchAudioUploader.handleConverseCompletion`) — the single arrival path
/// for EVERY agent reply when the app is suspended. Maps the raw completion
/// inputs to one verdict; the delegate stays a thin adapter that EXECUTES the
/// verdict (store append, pointer stamp, haptic, notification, failure
/// funnel), so the branch classification is unit-testable
/// (`WatchConverseCompletionVerdictTests`) without a real `URLSessionTask`.
///
/// `registryEntryPresent` is the in-memory `multipartTempFiles` presence read
/// — it drives the `.cancelled` disambiguation (live in-process cancel vs a
/// task resurrected across a launch) and MUST be read before the delegate's
/// cleanup `defer` removes the entry (ordering contract).
enum WatchConverseCompletionVerdict {

    /// Failure classes, kept as a KIND rather than a message: copy mapping
    /// and the per-branch forensic log lines stay in the watch adapter
    /// (`WatchAudioUploader.failureMessage(for:)`), which owns
    /// `WatchNetworkFailureCopy` + the localized fallback strings.
    enum FailureKind {
        /// Non-cancel transport error — the adapter maps honest connectivity
        /// copy via `WatchNetworkFailureCopy.transportFailureMessage`.
        case transport(Error)
        /// The delegate cancelled the task itself because the response body
        /// passed `Constants.maxBackgroundResponseBytes` (a peer fabricating a
        /// reply). Classified FIRST, ahead of the `.cancelled` disambiguation:
        /// our own cancel surfaces as `URLError.cancelled` WITH the registry
        /// entry still present, which is exactly the `.cleanupOnly` shape — so
        /// without this branch an over-cap reply dropped the user's spoken turn
        /// silently, no bubble and no Retry. Mirrors the per-task over-cap notes
        /// in `BackgroundRemoteAgent` / `CarPlayConverseUploader`.
        case responseOverCap
        /// The trust delegate refused the server-trust challenge because THIS
        /// DEVICE DOES NOT TRUST the presented chain. Usually reaches the
        /// completion as `URLError.cancelled` WITH the registry entry present —
        /// the same shape as a live in-process cancel, so without this branch a
        /// pinned gateway whose certificate the watch rejects dropped the user's
        /// spoken turn silently and left the live machine stuck in `.uploading`
        /// (App Transport Security may also refuse first, surfacing `-1200`; same
        /// verdict). TERMINAL: a pin can only tighten a chain the system already
        /// trusts, never rescue one, so nothing on the wrist changes the outcome.
        case certificateUntrusted
        /// The trust delegate refused the challenge because a configured pin did
        /// not match a chain the system DID trust. A DISTINCT kind from
        /// `.certificateUntrusted`, never merged with it: there the chain is
        /// rejected and the fix is a real certificate on the server; here the
        /// chain is fine and the KEY under it changed, which is what an
        /// intercepted connection looks like. Also terminal.
        case certificatePinMismatch
        /// The trust delegate refused because it could not COMPUTE the pin: the
        /// chain the system trusted carries a key algorithm outside Conduck's
        /// SPKI prefix table, so nothing was compared. A third distinct kind,
        /// merged with neither — `.certificateUntrusted` would send the user to
        /// replace a certificate this device accepts, and `.certificatePinMismatch`
        /// would warn about an interception that nothing here is evidence of.
        /// Also terminal: the key is the same on every attempt.
        case certificateKeyUnpinnable
        /// `.cancelled` with NO registry entry: the task was resurrected
        /// ACROSS A LAUNCH (after a force-quit every background task comes
        /// back as `.cancelled`, and the registry died with the old process).
        /// Nobody cancelled this turn — surface a failure, never a silent drop.
        case cancelledAcrossLaunch
        /// Completion delivered no `HTTPURLResponse`.
        case missingHTTPResponse
        /// The response BODY carried a classifiable rejection — a frozen
        /// adapter-contract wire code, or one of the body heuristics. Classified
        /// BEFORE `.httpStatus`, mirroring `RemoteAgentClient.decodeReply`, so one
        /// body means one verdict on every surface.
        ///
        /// Without this branch the wrist collapsed every body-derived diagnosis
        /// into a bare status: an `image_unsupported` decline, a model-not-found
        /// and a context overflow all rendered as the same generic status copy,
        /// which names no cause the user can act on — and the phone lane sitting
        /// beside it named all three.
        case classifiedBody(ClassifiedRemoteAgentFailure)
        /// The status map flagged a non-2xx HTTP status.
        case httpStatus(Int)
        /// 2xx body did not decode to `choices[0].message.content`.
        case undecodableReply
        /// Reply decoded but the metadata carried no usable conversationID —
        /// a reply with no home (anti-phantom-reply: soft failure, no
        /// success notification for a turn that isn't in any thread).
        case noConversationID
    }

    /// Agent reply decoded + routable — append, stamp (implicit turns only),
    /// haptic, notify.
    case reply(text: String, conversationID: UUID, stampsActiveConversation: Bool)
    /// Route into the failure funnel (live-machine takeover + notification).
    case failure(kind: FailureKind, conversationID: UUID?)
    /// Live in-process cancel (registry entry present) — drop silently: no
    /// agent bubble, no notification (cancel is not a failure). The user's
    /// turn is already in the store; only the delegate's cleanup runs.
    case cleanupOnly

    /// `responseOverCap` and `trustSignals` are the delegate's own per-task
    /// notes, each recording a reason IT cancelled this task
    /// (`WatchAudioUploader.overCapTaskKeys` / `trustSignalsByTaskKey`). Both
    /// MUST be classified before the `.cancelled` disambiguation, which would
    /// otherwise read our own cancel as a live user cancel and drop the turn
    /// silently.
    ///
    /// `trustSignals` arrives WHOLE — the same snapshot the evaluator reached —
    /// because `pinComparisonUnsupported` is the only thing separating a key the
    /// watch cannot fingerprint from a key that disagreed, and the wrist is the
    /// surface least able to recover from being told the wrong one.
    static func make(
        metadata: RemoteAgentBackgroundMetadata?,
        httpStatus: Int?,
        body: Data?,
        transportError: Error?,
        registryEntryPresent: Bool,
        responseOverCap: Bool = false,
        trustSignals: RemoteAgentTrustEvaluator.AttemptTrustSignals = .empty
    ) -> WatchConverseCompletionVerdict {
        // Status-map carrier: a built-in ref maps to itself; a custom ref (or
        // garbage metadata) uses `.openclaw` — the map is `.unified` for every
        // ref, so the carrier only matters for `statusMap.map(...)`.
        let backend: RemoteAgentBackend = {
            if case .builtin(let b)? = metadata.flatMap({ RemoteAgentRef(rawString: $0.backendRawValue) }) {
                return b
            }
            return .openclaw
        }()
        let conversationID = metadata.flatMap { UUID(uuidString: $0.conversationID) }

        if let transportError {
            // OUR over-cap cancel, ahead of every other transport branch: it
            // arrives as `.cancelled` with the registry entry present, i.e.
            // indistinguishable from a live in-process cancel.
            if responseOverCap {
                return .failure(kind: .responseOverCap, conversationID: conversationID)
            }
            // OUR certificate refusal, likewise ahead of the `.cancelled`
            // disambiguation and for the identical reason: the trust delegate
            // cancelled the challenge, so this arrives as `.cancelled` with the
            // registry entry present. Mutually exclusive with the over-cap note
            // above — a refused challenge never gets far enough for a body.
            //
            // Classification is DELEGATED to the one shared classifier the
            // iPhone, CarPlay and STT lanes use, so the wrist cannot drift on
            // what counts as a certificate failure — and so a note left on a
            // task that nonetheless connected cannot mislabel an unrelated later
            // error: only the code arms the classifier accepts become a
            // certificate verdict, everything else falls through untouched.
            if trustSignals != .empty, let urlError = transportError as? URLError {
                switch RemoteAgentTrustEvaluator.classifyTransportError(
                    urlError.code,
                    signals: trustSignals
                ) {
                case .untrustedCert:
                    return .failure(kind: .certificateUntrusted, conversationID: conversationID)
                case .certMismatch:
                    return .failure(kind: .certificatePinMismatch, conversationID: conversationID)
                case .certKeyUnpinnable:
                    return .failure(kind: .certificateKeyUnpinnable, conversationID: conversationID)
                case .timeout, .unreachable, .notEstablished, .offline, .cancelled:
                    // Non-certificate classes fall through untouched, exactly as
                    // before: this arm exists so a trust note left on a task that
                    // nonetheless connected cannot mislabel an unrelated later
                    // error as a certificate failure.
                    break
                }
            }
            if let urlError = transportError as? URLError, urlError.code == .cancelled {
                return registryEntryPresent
                    ? .cleanupOnly
                    : .failure(kind: .cancelledAcrossLaunch, conversationID: conversationID)
            }
            return .failure(kind: .transport(transportError), conversationID: conversationID)
        }

        guard let httpStatus else {
            return .failure(kind: .missingHTTPResponse, conversationID: conversationID)
        }
        // Body-aware classification FIRST, in the same order as
        // `RemoteAgentClient.decodeReply`: the status map sees only the code, and a
        // 400 or 404 can mean several different things. The bytes are already in
        // hand here, and the classifier is watch-shared, so the wrist gets the same
        // named cause the phone does instead of a bare status.
        //
        // Order is the contract, not a preference — running the status map first
        // would swallow every one of these into `.httpStatus`, which is exactly the
        // behaviour this branch replaces. Pinned in
        // `WatchConverseCompletionVerdictTests`.
        if let body,
           let classified = RemoteAgentClient.classifyBodyError(status: httpStatus, body: body) {
            return .failure(kind: .classifiedBody(classified), conversationID: conversationID)
        }
        if backend.statusMap.map(httpStatus) != nil {
            return .failure(kind: .httpStatus(httpStatus), conversationID: conversationID)
        }

        guard let decoded = try? JSONDecoder().decode(ConverseResponse.self, from: body ?? Data()),
              let content = decoded.firstReplyContent else {
            return .failure(kind: .undecodableReply, conversationID: conversationID)
        }

        guard let conversationID else {
            return .failure(kind: .noConversationID, conversationID: nil)
        }

        return .reply(
            text: content,
            conversationID: conversationID,
            stampsActiveConversation: metadata?.stampsActiveConversation == true
        )
    }
}
