// SPDX-License-Identifier: Apache-2.0

// Conduck
// RemoteAgentSendFailureTests.swift
//
// The foreground converse hop's TERMINAL CARRIERS: what `RemoteAgentClient.send`
// hands back on success, what it throws on failure, and — the property that
// matters most — that widening those shapes changed nothing about how a failure
// is CLASSIFIED.
//
// Why this file exists as its own suite. The taxonomy a turn fails with drives
// the inline error row, the Troubleshoot deep link, the Retry affordance and the
// Diagnostics record; the send path used to throw that taxonomy bare, and now
// wraps it so the turn's timing and the gateway's own reported usage survive
// alongside it. A wrap is exactly the kind of change that looks free and is not:
// one handler still asking `error as? AppError` silently buckets every gateway
// verdict as `.remoteAgentUnreachable`, which tells a user with a rejected token
// to go check that their server is running. So the assertions below pin the
// unwrap seam itself (`unwrappedAppError` / `unwrappedWireCode` /
// `TurnFailureClassification.init(from:)`), not merely that a throw happened.
//
// The other half is the metadata: it is observed BESIDE the strict decode, on
// error bodies too, because a gateway can bill for work it then failed to
// return. A 500 that reports `usage` describes real spend, and a client that
// only reads usage off successes under-counts exactly the turns a user is most
// annoyed about.
//
// `MockURLProtocol` + `.unevaluated(session:)` — a mocked transport raises no
// server-trust challenge, so there is no verdict to read.

import XCTest
@testable import Conduck

final class RemoteAgentSendFailureTests: XCTestCase {

    private var session: URLSession!
    private let baseURL = URL(string: "https://gateway.example.test")!
    private let token = "secret-token-do-not-log"

    override func setUp() {
        super.setUp()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        session = URLSession(configuration: config)
    }

    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        session.invalidateAndCancel()
        session = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func respond(status: Int, body: String) {
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil
            )!
            return (response, Data(body.utf8))
        }
    }

    private func send() async throws -> RemoteAgentReply {
        try await RemoteAgentClient.shared.send(
            backend: .openclaw,
            url: baseURL,
            token: token,
            newUserText: "hello",
            fileServerReady: false,
            transport: .unevaluated(session: session)
        )
    }

    // MARK: - Success carries the turn's reported facts

    func testSuccessCarriesReportedMetadataAndTheHopsCompletionInstant() async throws {
        respond(status: 200, body: """
        {"id":"resp-9","model":"anthropic/claude-x","choices":[{"finish_reason":"stop",\
        "message":{"content":"hi"}}],"usage":{"prompt_tokens":120,"completion_tokens":34,\
        "total_tokens":154}}
        """)

        let before = Date()
        let reply = try await send()
        let after = Date()

        XCTAssertEqual(reply.text, "hi", "The strict decoder still owns the reply; metadata rides beside it.")
        let metadata = try XCTUnwrap(reply.metadata)
        XCTAssertEqual(metadata.reportedModel, "anthropic/claude-x")
        XCTAssertEqual(metadata.reportedResponseID, "resp-9")
        XCTAssertEqual(metadata.finishReason, "stop")
        XCTAssertEqual(metadata.reportedInputTokens, 120)
        XCTAssertEqual(metadata.reportedOutputTokens, 34)
        XCTAssertEqual(metadata.reportedTotalTokens, 154)
        XCTAssertGreaterThanOrEqual(reply.completedAt, before)
        XCTAssertLessThanOrEqual(reply.completedAt, after,
                                 "`completedAt` is stamped when the bytes arrive, so the elapsed time it closes measures the gateway hop and not the landing that follows it.")
    }

    func testAGatewayThatReportsNothingYieldsNilMetadataRatherThanAnEmptyOne() async throws {
        respond(status: 200, body: #"{"choices":[{"message":{"content":"hi"}}]}"#)

        let reply = try await send()

        XCTAssertEqual(reply.text, "hi")
        XCTAssertNil(reply.metadata,
                     "\"The gateway reported no usage\" must be ONE state, not an empty observation that later reads as a reported zero.")
    }

    func testAHostileUsageBlockCannotSinkAPerfectlyGoodReply() async throws {
        // The independence property in its sharpest form: `usage` is garbage in
        // every field, and the reply still lands. A `Codable` widening of the
        // response type would have thrown and taken the reply with it.
        respond(status: 200, body: """
        {"choices":[{"message":{"content":"hi"}}],\
        "usage":{"prompt_tokens":"120","completion_tokens":-4,"total_tokens":true}}
        """)

        let reply = try await send()

        XCTAssertEqual(reply.text, "hi")
        XCTAssertNil(reply.metadata,
                     "Every field failed validation independently, so nothing was worth keeping — and the reply was never at risk.")
    }

    // MARK: - Failure carries the same facts

    func testAFailedTurnStillReportsTheWorkTheGatewayDid() async throws {
        // A 500 AFTER the model ran. The tokens are spent either way, and a
        // ledger that only counts successes under-reports exactly the turns the
        // user is most annoyed about.
        respond(status: 500, body: """
        {"error":{"message":"upstream exploded"},"model":"m-1",\
        "usage":{"prompt_tokens":90,"completion_tokens":0,"total_tokens":90}}
        """)

        do {
            _ = try await send()
            XCTFail("A 500 must not resolve as a reply.")
        } catch let failure as RemoteAgentSendFailure {
            XCTAssertEqual(failure.appError.errorCode, AppError.remoteAgentServerError.errorCode)
            let metadata = try XCTUnwrap(failure.metadata,
                                         "A billed-but-failed turn is exactly the case this carrier exists for.")
            XCTAssertEqual(metadata.reportedInputTokens, 90)
            XCTAssertEqual(metadata.reportedTotalTokens, 90)
            XCTAssertEqual(metadata.reportedModel, "m-1")
        }
    }

    func testTheWireCodeSurvivesTheCarrierAndReachesThePersistedClassification() async throws {
        // The end-to-end version of the property, through the one mapping every
        // failure writer uses. If the carrier were invisible to
        // `init(from:)`, this would silently degrade to code 19 + no wire code —
        // a precisely classified refusal reported as "your server may be down".
        respond(status: 400, body: #"{"error":{"code":"context_too_long","message":"too long"}}"#)

        do {
            _ = try await send()
            XCTFail("A wire-coded 400 must not resolve as a reply.")
        } catch {
            XCTAssertEqual(error.unwrappedAppError?.errorCode,
                           AppError.remoteAgentContextTooLong.errorCode)
            XCTAssertEqual(error.unwrappedWireCode, .contextTooLong)

            let classification = ConversationStore.TurnFailureClassification(
                from: error, hadHistoryImages: true
            )
            XCTAssertEqual(classification.failureCode, AppError.remoteAgentContextTooLong.errorCode)
            XCTAssertEqual(classification.wireCode, AdapterWireCode.contextTooLong.rawValue)
            XCTAssertEqual(classification.hadHistoryImages, true)
        }
    }

    func testHeuristicClassificationKeepsItsCaseAndReportsNoWireCode() async throws {
        // The regex half of the classifier: no structured code in the body, so
        // the wire code is legitimately absent and the case comes from the
        // heuristics. Both halves must arrive exactly as they did before.
        respond(status: 404, body: #"{"error":{"message":"No endpoints found for zzz-9"}}"#)

        do {
            _ = try await send()
            XCTFail("A model-not-found 404 must not resolve as a reply.")
        } catch {
            XCTAssertEqual(error.unwrappedAppError?.errorCode,
                           AppError.remoteAgentModelUnavailable.errorCode)
            XCTAssertNil(error.unwrappedWireCode,
                         "No structured code was sent — inventing one would claim a confidence the body never gave.")
        }
    }

    func testAPreResponseFailureCarriesNoMetadataAtAll() async {
        // A timeout never reached a body. An empty observation here would count
        // a turn the gateway may never have seen.
        MockURLProtocol.requestHandler = { _ in throw URLError(.timedOut) }

        do {
            _ = try await send()
            XCTFail("A timeout must not resolve as a reply.")
        } catch let failure as RemoteAgentSendFailure {
            XCTAssertEqual(failure.appError.errorCode, AppError.remoteAgentTimeout.errorCode)
            XCTAssertNil(failure.metadata)
            XCTAssertNil(failure.wireCode)
        } catch {
            XCTFail("Expected the transport failure to arrive as the carrier, got \(type(of: error)): \(error)")
        }
    }

    // MARK: - A cancel is not a failure

    func testAGenuineCancelPropagatesUnwrapped() async {
        // LOAD-BEARING, and the reason `send` checks for it before wrapping:
        // every caller's `catch is CancellationError` arm flips the turn
        // status-only, writes no classification and closes the attempt as
        // `cancelled`. Wrapping a Stop would route it into the failure writers
        // instead — a gateway error banner for something the user did on purpose.
        MockURLProtocol.requestHandler = { _ in throw URLError(.cancelled) }

        let task = Task { try await self.send() }
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected the cancellation to propagate.")
        } catch is CancellationError {
            // Expected.
        } catch let failure as RemoteAgentSendFailure {
            XCTFail("A Stop must never arrive as a gateway verdict — it wrapped as \(failure.appError).")
        } catch {
            XCTFail("Expected CancellationError, got \(type(of: error)): \(error)")
        }
    }

    // MARK: - The unwrap seam, directly

    func testBothCarriersAnswerTheUnwrapHelpersIdentically() {
        let classified = ClassifiedRemoteAgentFailure(
            appError: .remoteAgentImageTooLarge, wireCode: .imageTooLarge
        )
        let sendFailure = RemoteAgentSendFailure(
            appError: .remoteAgentImageTooLarge,
            wireCode: .imageTooLarge,
            metadata: nil,
            completedAt: Date()
        )

        XCTAssertEqual(classified.unwrappedAppError?.errorCode, sendFailure.unwrappedAppError?.errorCode,
                       "Two carriers, one taxonomy — a handler must not be able to tell them apart.")
        XCTAssertEqual(classified.unwrappedWireCode, sendFailure.unwrappedWireCode)

        // A bare case still answers, and an unrelated error still buckets the
        // way the failure writers expect.
        XCTAssertEqual(AppError.remoteAgentAuthFailed.unwrappedAppError?.errorCode,
                       AppError.remoteAgentAuthFailed.errorCode)
        XCTAssertNil(AppError.remoteAgentAuthFailed.unwrappedWireCode)
        XCTAssertNil(CancellationError().unwrappedAppError,
                     "A cancel carries no taxonomy; `recordSendFailure` is never reached with one.")
        XCTAssertNil(URLError(.timedOut).unwrappedWireCode)
    }

    func testTheCarrierForwardsTheTaxonomysCopyRatherThanItsOwnTypeName() {
        let failure = RemoteAgentSendFailure(
            appError: .remoteAgentAuthFailed, wireCode: nil, metadata: nil, completedAt: Date()
        )

        XCTAssertEqual(failure.errorDescription, AppError.remoteAgentAuthFailed.errorDescription,
                       "A generic `error.localizedDescription` site must show the taxonomy's own words — never `Conduck.RemoteAgentSendFailure error 1`.")
        XCTAssertEqual(failure.recoverySuggestion, AppError.remoteAgentAuthFailed.recoverySuggestion)
    }
}
