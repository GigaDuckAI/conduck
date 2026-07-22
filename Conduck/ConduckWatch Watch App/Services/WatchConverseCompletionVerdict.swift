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
        /// `.cancelled` with NO registry entry: the task was resurrected
        /// ACROSS A LAUNCH (after a force-quit every background task comes
        /// back as `.cancelled`, and the registry died with the old process).
        /// Nobody cancelled this turn — surface a failure, never a silent drop.
        case cancelledAcrossLaunch
        /// Completion delivered no `HTTPURLResponse`.
        case missingHTTPResponse
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

    static func make(
        metadata: RemoteAgentBackgroundMetadata?,
        httpStatus: Int?,
        body: Data?,
        transportError: Error?,
        registryEntryPresent: Bool
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
