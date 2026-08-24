// SPDX-License-Identifier: Apache-2.0

// Conduck — pure classification tests for the background converse completion
// (the wrist's single reply-arrival path when the app is suspended).
// `WatchConverseCompletionVerdict.make` is the extracted decision;
// `WatchAudioUploader.handleConverseCompletion` executes it as a thin adapter.
//
// Deliberately NOT re-tested here: `ConverseResponse` decode internals
// (ConverseWireTests) and `WatchNetworkFailureCopy` wording
// (WatchObservabilityTests) — this suite locks branch classification and
// ordering only: cancel disambiguation via registry presence, the two
// certificate refusals that also arrive as a cancel, transport vs HTTP vs
// decode, the missing-response guard, and the anti-phantom-reply
// conversationID guard.
//
// Also locks the SECOND pure translation of the same completion —
// `WatchAudioUploader.terminalObservation(...)`, what the gateway-attempt
// ledger records — so the measurement and the copy the user reads can never
// drift apart.

import XCTest
@testable import ConduckWatch_Watch_App

@MainActor
final class WatchConverseCompletionVerdictTests: XCTestCase {

    /// One recorded attempt snapshot. `challengeRefused` is derived: the
    /// delegate records a snapshot ONLY for a challenge it answered, so any
    /// verdict at all means the refusal was ours — which is exactly what the
    /// `.cancelled` arm needs in order not to read it as a user cancel.
    private func noted(systemTrustRejected: Bool = false,
                       pinRejected: Bool = false,
                       pinComparisonUnsupported: Bool = false)
    -> RemoteAgentTrustEvaluator.AttemptTrustSignals {
        .init(systemTrustRejected: systemTrustRejected,
              challengeRefused: true,
              pinRejected: pinRejected,
              pinComparisonUnsupported: pinComparisonUnsupported)
    }

    private let cid = UUID()

    private func metadata(conversationID: String? = nil, stamps: Bool? = nil) -> RemoteAgentBackgroundMetadata {
        RemoteAgentBackgroundMetadata(
            bodyPath: "/tmp/converse-body.json",
            conversationID: conversationID ?? cid.uuidString,
            backendRawValue: "openclaw",
            stampsActiveConversation: stamps
        )
    }

    private func replyBody(_ text: String) -> Data {
        Data(#"{"choices":[{"message":{"content":"\#(text)"}}]}"#.utf8)
    }

    // MARK: - Happy path

    func testHappyReplyDecodesWithStampVerdict() {
        let verdict = WatchConverseCompletionVerdict.make(
            metadata: metadata(stamps: true), httpStatus: 200,
            body: replyBody("Hi there"), transportError: nil, registryEntryPresent: true
        )
        guard case .reply(let text, let conversationID, let stamps) = verdict else {
            return XCTFail("Expected .reply, got \(verdict)")
        }
        XCTAssertEqual(text, "Hi there")
        XCTAssertEqual(conversationID, cid)
        XCTAssertTrue(stamps)
    }

    /// Old in-flight metadata blobs decode `stampsActiveConversation` nil —
    /// they must never stamp the quick-capture pointer.
    func testNilStampVerdictDefaultsToNoStamp() {
        let verdict = WatchConverseCompletionVerdict.make(
            metadata: metadata(stamps: nil), httpStatus: 200,
            body: replyBody("ok"), transportError: nil, registryEntryPresent: true
        )
        guard case .reply(_, _, let stamps) = verdict else {
            return XCTFail("Expected .reply, got \(verdict)")
        }
        XCTAssertFalse(stamps)
    }

    // MARK: - Cancel disambiguation (registry presence)

    func testLiveCancelIsSilentCleanup() {
        let verdict = WatchConverseCompletionVerdict.make(
            metadata: metadata(), httpStatus: nil, body: nil,
            transportError: URLError(.cancelled), registryEntryPresent: true
        )
        guard case .cleanupOnly = verdict else {
            return XCTFail("A live in-process cancel must drop silently, got \(verdict)")
        }
    }

    func testCrossLaunchCancelSurfacesFailure() {
        let verdict = WatchConverseCompletionVerdict.make(
            metadata: metadata(), httpStatus: nil, body: nil,
            transportError: URLError(.cancelled), registryEntryPresent: false
        )
        guard case .failure(.cancelledAcrossLaunch, let conversationID) = verdict else {
            return XCTFail("A resurrected task's .cancelled must surface a failure, got \(verdict)")
        }
        XCTAssertEqual(conversationID, cid)
    }

    // MARK: - Over-cap cancel (must NOT read as a user cancel)

    /// THE regression this branch exists for: the delegate's own over-cap cancel
    /// arrives as `.cancelled` WITH the registry entry still present — byte-
    /// identical to a live in-process cancel, which drops the turn silently. It
    /// must classify as a visible failure instead, or the user's spoken turn
    /// disappears off the wrist with no error and no Retry.
    func testOverCapCancelWithLiveRegistryEntryIsNotSilentCleanup() {
        let verdict = WatchConverseCompletionVerdict.make(
            metadata: metadata(), httpStatus: nil, body: nil,
            transportError: URLError(.cancelled), registryEntryPresent: true,
            responseOverCap: true
        )
        guard case .failure(.responseOverCap, let conversationID) = verdict else {
            return XCTFail("An over-cap cancel must surface a failure, got \(verdict)")
        }
        XCTAssertEqual(conversationID, cid)
    }

    /// Over-cap outranks the cross-launch arm too: the cap verdict is the
    /// specific reason, and it holds whether or not the registry survived.
    func testOverCapOutranksCrossLaunchCancel() {
        let verdict = WatchConverseCompletionVerdict.make(
            metadata: metadata(), httpStatus: nil, body: nil,
            transportError: URLError(.cancelled), registryEntryPresent: false,
            responseOverCap: true
        )
        guard case .failure(.responseOverCap, _) = verdict else {
            return XCTFail("Over-cap must outrank the cross-launch cancel arm, got \(verdict)")
        }
    }

    /// The flag is inert on a healthy turn — it only ever arrives set when the
    /// delegate itself cancelled, so a 2xx reply must still decode normally.
    func testNotOverCapLeavesHappyPathUntouched() {
        let verdict = WatchConverseCompletionVerdict.make(
            metadata: metadata(stamps: true), httpStatus: 200,
            body: replyBody("Hi there"), transportError: nil,
            registryEntryPresent: true, responseOverCap: false
        )
        guard case .reply = verdict else {
            return XCTFail("Expected .reply, got \(verdict)")
        }
    }

    // MARK: - Certificate refusal (must NOT read as a user cancel)

    /// THE blocker this branch exists for: a PINNED gateway over a chain this
    /// device does not trust makes the evaluator fail closed and cancel the
    /// challenge, so the task completes as `.cancelled` WITH the registry entry
    /// still present — byte-identical to a live in-process cancel, which drops
    /// the turn silently. It must be a visible terminal failure instead, or the
    /// user's spoken turn vanishes off the wrist and the live machine stays
    /// stuck in `.uploading`.
    func testUntrustedCertificateCancelIsNotSilentCleanup() {
        let verdict = WatchConverseCompletionVerdict.make(
            metadata: metadata(), httpStatus: nil, body: nil,
            transportError: URLError(.cancelled), registryEntryPresent: true,
            trustSignals: noted(systemTrustRejected: true)
        )
        guard case .failure(.certificateUntrusted, let conversationID) = verdict else {
            return XCTFail("An untrusted-certificate cancel must surface a failure, got \(verdict)")
        }
        XCTAssertEqual(conversationID, cid)
    }

    /// A pin mismatch on a chain the system DID trust is a DIFFERENT verdict and
    /// must never collapse into the untrusted one: there the fix is a real
    /// certificate on the server, here the key changed under a still-trusted
    /// chain.
    func testPinMismatchCancelClassifiesSeparately() {
        let verdict = WatchConverseCompletionVerdict.make(
            metadata: metadata(), httpStatus: nil, body: nil,
            transportError: URLError(.cancelled), registryEntryPresent: true,
            trustSignals: noted(pinRejected: true)
        )
        guard case .failure(.certificatePinMismatch, let conversationID) = verdict else {
            return XCTFail("A pin-mismatch cancel must classify as certificatePinMismatch, got \(verdict)")
        }
        XCTAssertEqual(conversationID, cid)
    }

    /// Precedence is the shared classifier's: "this device does not trust this
    /// certificate" is the truthful, actionable statement when both are noted.
    func testUntrustedOutranksPinMismatchWhenBothNoted() {
        let verdict = WatchConverseCompletionVerdict.make(
            metadata: metadata(), httpStatus: nil, body: nil,
            transportError: URLError(.cancelled), registryEntryPresent: true,
            trustSignals: noted(systemTrustRejected: true, pinRejected: true)
        )
        guard case .failure(.certificateUntrusted, _) = verdict else {
            return XCTFail("systemTrustRejected must outrank pinRejected, got \(verdict)")
        }
    }

    /// ATS can refuse the connection itself before our cancel lands, surfacing
    /// `-1200` rather than `-999`. With the note set, both codes are the same
    /// verdict.
    func testSecureConnectionFailedWithTrustNoteIsUntrusted() {
        let verdict = WatchConverseCompletionVerdict.make(
            metadata: metadata(), httpStatus: nil, body: nil,
            transportError: URLError(.secureConnectionFailed), registryEntryPresent: true,
            trustSignals: noted(systemTrustRejected: true)
        )
        guard case .failure(.certificateUntrusted, _) = verdict else {
            return XCTFail("A noted -1200 must classify as certificateUntrusted, got \(verdict)")
        }
    }

    /// The cold-tunnel fence, on the wrist: a generic `-1200` with NEITHER note
    /// is a transient handshake failure (a cold Tailscale tunnel on a perfectly
    /// good certificate), and must stay an ordinary transport failure.
    func testSecureConnectionFailedWithNoNotesStaysTransport() {
        let verdict = WatchConverseCompletionVerdict.make(
            metadata: metadata(), httpStatus: nil, body: nil,
            transportError: URLError(.secureConnectionFailed), registryEntryPresent: true
        )
        guard case .failure(.transport, _) = verdict else {
            return XCTFail("An unsignalled -1200 must not claim a certificate problem, got \(verdict)")
        }
    }

    /// A GENUINE user cancel is byte-for-byte unchanged: no notes, registry
    /// entry present, still a silent cleanup. This is the fence that keeps the
    /// certificate branches from broadening the cancel arm.
    func testGenuineUserCancelWithNoNotesStaysSilentCleanup() {
        let verdict = WatchConverseCompletionVerdict.make(
            metadata: metadata(), httpStatus: nil, body: nil,
            transportError: URLError(.cancelled), registryEntryPresent: true,
            trustSignals: .empty
        )
        guard case .cleanupOnly = verdict else {
            return XCTFail("A genuine user cancel must still drop silently, got \(verdict)")
        }
    }

    /// A note that somehow rides a task which nonetheless connected must not
    /// hijack an unrelated later error: only the codes the shared classifier
    /// accepts become a certificate verdict.
    func testTrustNoteDoesNotHijackAnUnrelatedTransportError() {
        let verdict = WatchConverseCompletionVerdict.make(
            metadata: metadata(), httpStatus: nil, body: nil,
            transportError: URLError(.timedOut), registryEntryPresent: true,
            trustSignals: noted(systemTrustRejected: true)
        )
        guard case .failure(.transport(let error), _) = verdict else {
            return XCTFail("A timeout must stay a transport failure, got \(verdict)")
        }
        XCTAssertEqual((error as? URLError)?.code, .timedOut)
    }

    /// A key the watch cannot fingerprint is NOT the interception case. The
    /// wrist is the surface least able to act on a warning, so a false one there
    /// is the most expensive: reachable only because the registry stores the
    /// whole snapshot, since the loose-Bool form drops the verdict that says so.
    func testAnUnfingerprintableKeyIsItsOwnVerdictNotAMismatch() {
        let verdict = WatchConverseCompletionVerdict.make(
            metadata: metadata(), httpStatus: nil, body: nil,
            transportError: URLError(.cancelled), registryEntryPresent: true,
            trustSignals: noted(pinRejected: true, pinComparisonUnsupported: true)
        )
        guard case .failure(.certificateKeyUnpinnable, _) = verdict else {
            return XCTFail("System trust passed and nothing was compared — this must not read as a pin mismatch, got \(verdict)")
        }
    }

    /// Over-cap keeps its existing precedence — the two notes are mutually
    /// exclusive in practice (a refused challenge never yields a body), so the
    /// order only has to be stable, not clever.
    func testOverCapKeepsPrecedenceOverTrustNotes() {
        let verdict = WatchConverseCompletionVerdict.make(
            metadata: metadata(), httpStatus: nil, body: nil,
            transportError: URLError(.cancelled), registryEntryPresent: true,
            responseOverCap: true, trustSignals: noted(systemTrustRejected: true)
        )
        guard case .failure(.responseOverCap, _) = verdict else {
            return XCTFail("Over-cap must keep its precedence, got \(verdict)")
        }
    }

    // MARK: - Transport / HTTP / decode branches

    /// The field case: NSURLErrorDomain -1001 against the gateway.
    func testTimedOutTransportClassifies() {
        let verdict = WatchConverseCompletionVerdict.make(
            metadata: metadata(), httpStatus: nil, body: nil,
            transportError: URLError(.timedOut), registryEntryPresent: true
        )
        guard case .failure(.transport(let error), let conversationID) = verdict else {
            return XCTFail("Expected .transport failure, got \(verdict)")
        }
        XCTAssertEqual((error as? URLError)?.code, .timedOut)
        XCTAssertEqual(conversationID, cid)
    }

    func testMissingHTTPResponseGuards() {
        let verdict = WatchConverseCompletionVerdict.make(
            metadata: metadata(), httpStatus: nil, body: replyBody("orphan"),
            transportError: nil, registryEntryPresent: true
        )
        guard case .failure(.missingHTTPResponse, let conversationID) = verdict else {
            return XCTFail("No HTTPURLResponse must classify as missingHTTPResponse, got \(verdict)")
        }
        XCTAssertEqual(conversationID, cid)
    }

    func testMappedHTTPStatusClassifies() {
        let verdict = WatchConverseCompletionVerdict.make(
            metadata: metadata(), httpStatus: 500, body: replyBody("ignored"),
            transportError: nil, registryEntryPresent: true
        )
        guard case .failure(.httpStatus(let status), let conversationID) = verdict else {
            return XCTFail("A status-mapped code must classify as httpStatus, got \(verdict)")
        }
        XCTAssertEqual(status, 500)
        XCTAssertEqual(conversationID, cid)
    }

    func testUndecodableBodyClassifies() {
        let garbage = WatchConverseCompletionVerdict.make(
            metadata: metadata(), httpStatus: 200, body: Data("not json".utf8),
            transportError: nil, registryEntryPresent: true
        )
        guard case .failure(.undecodableReply, _) = garbage else {
            return XCTFail("Garbage 2xx body must classify as undecodableReply, got \(garbage)")
        }
        // Empty choices decodes but carries no reply — same class.
        let emptyChoices = WatchConverseCompletionVerdict.make(
            metadata: metadata(), httpStatus: 200, body: Data(#"{"choices":[]}"#.utf8),
            transportError: nil, registryEntryPresent: true
        )
        guard case .failure(.undecodableReply, _) = emptyChoices else {
            return XCTFail("Empty choices must classify as undecodableReply, got \(emptyChoices)")
        }
    }

    // MARK: - anti-phantom-reply

    func testGarbageMetadataYieldsAntiPhantomFailure() {
        let verdict = WatchConverseCompletionVerdict.make(
            metadata: nil, httpStatus: 200, body: replyBody("homeless reply"),
            transportError: nil, registryEntryPresent: true
        )
        guard case .failure(.noConversationID, let conversationID) = verdict else {
            return XCTFail("A decoded reply with no metadata home must be a soft failure, got \(verdict)")
        }
        XCTAssertNil(conversationID)
    }

    func testNonUUIDConversationIDYieldsAntiPhantomFailure() {
        let verdict = WatchConverseCompletionVerdict.make(
            metadata: metadata(conversationID: "not-a-uuid"), httpStatus: 200,
            body: replyBody("homeless reply"), transportError: nil, registryEntryPresent: true
        )
        guard case .failure(.noConversationID, _) = verdict else {
            return XCTFail("A non-UUID conversationID must be a soft failure, got \(verdict)")
        }
    }

    // MARK: - body-aware classification (ORDER is the contract)

    /// An adapter-contract wire code must classify EXACTLY, and must OUTRANK the
    /// status map. 400 is status-mapped, so if the map ran first this would come
    /// back as a bare `.httpStatus(400)` — which is precisely the behaviour the
    /// branch replaces: the wrist would name no cause while the phone named
    /// "this gateway can't accept photos".
    func testWireCodeBodyOutranksTheStatusMap() {
        let body = Data(#"{"error":{"code":"image_unsupported","message":"no vision"}}"#.utf8)
        let verdict = WatchConverseCompletionVerdict.make(
            metadata: metadata(), httpStatus: 400, body: body,
            transportError: nil, registryEntryPresent: true
        )
        guard case .failure(.classifiedBody(let classified), let conversationID) = verdict else {
            return XCTFail("A frozen wire code must classify as classifiedBody, got \(verdict)")
        }
        XCTAssertEqual(classified.wireCode, .imageUnsupported)
        XCTAssertEqual(classified.appError.errorCode, AppError.remoteAgentVisionUnsupported.errorCode,
                       "the wrist must reach the SAME taxonomy code the phone lane reaches")
        XCTAssertEqual(conversationID, cid)
    }

    /// Body classification also covers the heuristic (code-less) path — a gateway
    /// that sends prose instead of a contract code still gets a named cause.
    func testHeuristicBodyClassifiesWithoutAWireCode() {
        let body = Data(#"{"error":{"message":"This model's maximum context length is 8192 tokens"}}"#.utf8)
        let verdict = WatchConverseCompletionVerdict.make(
            metadata: metadata(), httpStatus: 400, body: body,
            transportError: nil, registryEntryPresent: true
        )
        guard case .failure(.classifiedBody(let classified), _) = verdict else {
            return XCTFail("A heuristic-matched body must classify as classifiedBody, got \(verdict)")
        }
        XCTAssertNil(classified.wireCode, "no contract code was sent, so none may be claimed")
        XCTAssertEqual(classified.appError.errorCode, AppError.remoteAgentContextTooLong.errorCode)
    }

    /// The fall-through must be INTACT: a non-2xx whose body says nothing
    /// classifiable still reaches the status map, exactly as before. A body pass
    /// that swallowed these would lose the 402/429-style terminal verdicts.
    func testUnclassifiableBodyStillFallsToTheStatusMap() {
        let verdict = WatchConverseCompletionVerdict.make(
            metadata: metadata(), httpStatus: 500, body: Data(#"{"error":{"message":"boom"}}"#.utf8),
            transportError: nil, registryEntryPresent: true
        )
        guard case .failure(.httpStatus(let status), _) = verdict else {
            return XCTFail("An unclassifiable body must fall through to httpStatus, got \(verdict)")
        }
        XCTAssertEqual(status, 500)
    }

    /// No body at all (the completion delivered none) must not change the verdict
    /// a status alone earns — the classifier is skipped, never fed empty bytes.
    func testNilBodyStillFallsToTheStatusMap() {
        let verdict = WatchConverseCompletionVerdict.make(
            metadata: metadata(), httpStatus: 429, body: nil,
            transportError: nil, registryEntryPresent: true
        )
        guard case .failure(.httpStatus(let status), _) = verdict else {
            return XCTFail("A nil body must fall through to httpStatus, got \(verdict)")
        }
        XCTAssertEqual(status, 429)
    }

    /// A 2xx reply is untouched by the new branch: the classifier's own status gate
    /// declines it, so the happy path still decodes. Guards against the body pass
    /// hijacking a successful turn whose reply text happens to contain matching
    /// prose.
    func testSuccessfulReplyMentioningAnErrorPhraseStillDecodes() {
        let verdict = WatchConverseCompletionVerdict.make(
            metadata: metadata(), httpStatus: 200,
            body: replyBody("your maximum context length is fine, and image_unsupported is not set"),
            transportError: nil, registryEntryPresent: true
        )
        guard case .reply(let text, let conversationID, _) = verdict else {
            return XCTFail("A 2xx reply must still decode as a reply, got \(verdict)")
        }
        XCTAssertTrue(text.contains("maximum context length"))
        XCTAssertEqual(conversationID, cid)
    }

    // MARK: - Ledger observation assembly
    //
    // `WatchAudioUploader.terminalObservation(for:attemptID:completedAt:reported:)`
    // is the second pure translation of the same completion — what the
    // gateway-attempt ledger records, beside what the user is shown. Locked here
    // so the two can never drift: a wrist turn that reads as a failure must not
    // be counted as a success, and the two cancellations must stay apart.

    /// A dispatch carrying no attempt id — a task enqueued by a build that
    /// predates the ledger — must produce NO observation. Landing it as one
    /// would fabricate a row for a dispatch nobody measured.
    func testNoAttemptIDProducesNoObservation() {
        let observation = WatchAudioUploader.terminalObservation(
            for: .reply(text: "hi", conversationID: cid, stampsActiveConversation: false),
            attemptID: nil,
            completedAt: Date(),
            reported: nil
        )
        XCTAssertNil(observation)
    }

    /// The decoded-reply verdict is the ONLY success, and it carries the
    /// gateway's reported usage through untouched — including on the fields the
    /// gateway chose to omit.
    func testReplyVerdictObservesSuccessAndCarriesReportedUsage() {
        let attemptID = UUID()
        let completedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let reported = GatewayResponseMetadata(
            reportedModel: "some-model",
            finishReason: "stop",
            reportedInputTokens: 11,
            reportedOutputTokens: 22
        )
        let observation = WatchAudioUploader.terminalObservation(
            for: .reply(text: "hi", conversationID: cid, stampsActiveConversation: true),
            attemptID: attemptID,
            completedAt: completedAt,
            reported: reported
        )
        XCTAssertEqual(observation?.attemptID, attemptID)
        XCTAssertEqual(observation?.outcome, .succeeded)
        XCTAssertEqual(observation?.completedAt, completedAt)
        XCTAssertNil(observation?.appErrorCode)
        XCTAssertEqual(observation?.metadata, reported)
    }

    /// A live in-process cancel (registry entry present) is `cancelled`. The
    /// Message still goes to `failed` so Retry appears — the two answers are
    /// deliberately different, and this pins the ledger's half.
    func testCleanupOnlyObservesCancelled() {
        let observation = WatchAudioUploader.terminalObservation(
            for: .cleanupOnly,
            attemptID: UUID(),
            completedAt: Date(),
            reported: nil
        )
        XCTAssertEqual(observation?.outcome, .cancelled)
        XCTAssertNil(observation?.appErrorCode)
    }

    /// The relaunch case is `unknown`, NOT `cancelled` and NOT `failed`. Every
    /// background task returns cancelled after a force-quit and the claim that
    /// would have said whether the user meant it died with the old process, so
    /// the only honest record is that the callback could not be classified.
    func testCancelledAcrossLaunchObservesUnknown() {
        let observation = WatchAudioUploader.terminalObservation(
            for: .failure(kind: .cancelledAcrossLaunch, conversationID: cid),
            attemptID: UUID(),
            completedAt: Date(),
            reported: nil
        )
        XCTAssertEqual(observation?.outcome, .unknown)
        XCTAssertNil(observation?.appErrorCode)
    }

    /// A certificate refusal arrives as `URLError.cancelled` too, and must NOT
    /// borrow either cancellation outcome: the delegate refused the task for a
    /// stated reason, which is a failure.
    func testCertificateRefusalObservesFailedNotCancelled() {
        for kind: WatchConverseCompletionVerdict.FailureKind in [
            .certificateUntrusted, .certificatePinMismatch, .certificateKeyUnpinnable,
            .responseOverCap, .insecureConnectionBlocked
        ] {
            let observation = WatchAudioUploader.terminalObservation(
                for: .failure(kind: kind, conversationID: cid),
                attemptID: UUID(),
                completedAt: Date(),
                reported: nil
            )
            XCTAssertEqual(observation?.outcome, .failed, "\(kind) must observe as failed")
        }
    }

    /// A mapped HTTP status carries Conduck's OWN error code — never the status
    /// itself, which is content the ledger may not store.
    func testMappedStatusCarriesAppErrorCodeNotTheStatus() {
        let observation = WatchAudioUploader.terminalObservation(
            for: .failure(kind: .httpStatus(429), conversationID: cid),
            attemptID: UUID(),
            completedAt: Date(),
            reported: nil
        )
        XCTAssertEqual(observation?.outcome, .failed)
        let expected = RemoteAgentStatusMap.unified.map(429)?.errorCode
        XCTAssertNotNil(expected)
        XCTAssertEqual(observation?.appErrorCode, expected)
        XCTAssertNotEqual(observation?.appErrorCode, 429)
    }

    /// A transport error proves no code, and guessing one would pin the row on
    /// copy the wrist cannot prove. Nil IS the classification.
    func testTransportFailureObservesFailedWithNoCode() {
        let observation = WatchAudioUploader.terminalObservation(
            for: .failure(kind: .transport(URLError(.timedOut)), conversationID: cid),
            attemptID: UUID(),
            completedAt: Date(),
            reported: nil
        )
        XCTAssertEqual(observation?.outcome, .failed)
        XCTAssertNil(observation?.appErrorCode)
    }

    /// A non-2xx body's reported usage is kept: a gateway can bill for work it
    /// then failed to return, so a failed turn's usage is as real as a
    /// successful one's.
    func testFailedTurnStillCarriesReportedUsage() {
        let reported = GatewayResponseMetadata(reportedInputTokens: 40, reportedTotalTokens: 40)
        let observation = WatchAudioUploader.terminalObservation(
            for: .failure(kind: .httpStatus(500), conversationID: cid),
            attemptID: UUID(),
            completedAt: Date(),
            reported: reported
        )
        XCTAssertEqual(observation?.metadata, reported)
    }

    // MARK: - Dispatch shape

    /// Shape coverage for the wrist's converse dispatch: it has to be `async
    /// throws` and take an explicit `inputMode`, because the ledger row is
    /// opened INSIDE it, at the last boundary before `resume()`. The closure is
    /// built and never invoked — calling it would start a real upload.
    func testUploadConverseTakesInputModeAndIsAwaitable() {
        let dispatch = {
            try await WatchAudioUploader.shared.uploadConverse(
                ref: "openclaw",
                url: URL(string: "https://example.invalid")!,
                token: "",
                model: nil,
                priorTurns: [],
                newUserText: "hi",
                conversationID: UUID(),
                userMessageID: UUID(),
                inputMode: .voice,
                stampsActiveConversation: false
            )
        }
        _ = dispatch
    }
}
