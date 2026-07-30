// SPDX-License-Identifier: Apache-2.0

// Conduck
// RemoteAgentVisionErrorTests.swift
//
// Locks the PRECEDENCE of `RemoteAgentClient`'s body-aware vision-error pass
// over the HTTP status map, end-to-end through the public `send(...)` actor
// API (`RemoteAgentClient.swift` `decodeReply` → `mapBodyError(status:body:)`
// runs BEFORE `backend.statusMap.map(...)`).
//
// Why this file exists separately from `AppErrorTests`: `AppErrorTests` already
// unit-tests `mapBodyError(status:body:)` in isolation, but it cannot prove
// the ORDERING inside `decodeReply` (which is `private static` and unreachable)
// — i.e. that a vision-incapable 400 surfaces .remoteAgentVisionUnsupported
// rather than the status map's generic-400 .apiFailure. That precedence is the
// load-bearing contract here, and it can only be observed by driving a real
// round-trip. `decodeReply` is private, so the path is exercised through
// `send(...)` with `MockURLProtocol` injected (no real network).
//
// Pinning discipline: those existing `mapBodyError` unit tests assert against
// `AppError.<case>.errorCode` (symbol-derived — a rename of the *code* wouldn't
// be caught). This file pins the thrown error to its HARDCODED numeric
// `errorCode` literal (32 = vision-unsupported, 33 = image-too-large,
// 10 = generic .apiFailure fallthrough), so a code reshuffle in `AppError.swift`
// breaks the test. `AppError` is not `Equatable`; `errorCode` is the
// comparison surface (`AppError.swift` `errorCode`).
//
// No Keychain is touched — `send` takes the token as a parameter — so this
// whole file runs unsigned + headless.

import XCTest
@testable import Conduck

final class RemoteAgentVisionErrorTests: XCTestCase {

    // A throwaway gateway base URL — the client appends `/v1/chat/completions`.
    // MockURLProtocol intercepts before any byte hits the network.
    private let gatewayURL = URL(string: "https://gateway.example.test:18789")!

    private func makeMockSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }

    /// Install a handler that returns the given status + body for the round-trip.
    private func respond(status: Int, body: Data) {
        MockURLProtocol.requestHandler = { request in
            let resp = HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil
            )!
            return (resp, body)
        }
    }

    override func tearDown() async throws {
        MockURLProtocol.requestHandler = nil
        try await super.tearDown()
    }

    private func sendThrowingAppError(status: Int, body: Data) async throws -> AppError {
        respond(status: status, body: body)
        do {
            let reply = try await RemoteAgentClient.shared.send(
                backend: .openclaw,
                url: gatewayURL,
                token: "test-token",
                newUserText: "describe this image",
                fileServerReady: false,
                transport: .unevaluated(session: makeMockSession())
            )
            XCTFail("Expected an AppError throw for HTTP \(status); got a reply: \(reply)")
            throw AppError.remoteAgentInvalidResponse  // unreachable; keeps signature non-optional
        } catch let classified as ClassifiedRemoteAgentFailure {
            // Body-classified failures ride the classified carrier
            // (wire code + AppError); the taxonomy case is what these tests pin.
            return classified.appError
        } catch let error as AppError {
            return error
        }
    }

    // MARK: - mapBodyError eligibility, pinned to hardcoded literal codes

    /// Hardens the regex-eligibility contract with HARDCODED expected codes
    /// (the existing `AppErrorTests` pins these via `AppError.<case>.errorCode`,
    /// which can't catch a code-table reshuffle). Each realistic body exercises
    /// one source regex; the generic body must fall through (nil).
    func testMapVisionErrorEligibilityPinnedToLiteralCodes() {
        // /unsupported.*content/i → 32
        XCTAssertEqual(
            RemoteAgentClient.mapBodyError(
                status: 400,
                body: Data(#"{"error":{"message":"model does not support unsupported content type image_url"}}"#.utf8)
            )?.errorCode,
            32,
            "A 400 body matching /unsupported.*content/i must map to .remoteAgentVisionUnsupported (code 32)."
        )

        // /image.*not.*support/i → 32
        XCTAssertEqual(
            RemoteAgentClient.mapBodyError(
                status: 400,
                body: Data(#"{"error":{"message":"This image input is not supported by the selected model."}}"#.utf8)
            )?.errorCode,
            32,
            "A 400 body matching /image.*not.*support/i must map to .remoteAgentVisionUnsupported (code 32)."
        )

        // 413 (any body) → 33
        XCTAssertEqual(
            RemoteAgentClient.mapBodyError(status: 413, body: Data())?.errorCode,
            33,
            "A 413 must map to .remoteAgentImageTooLarge (code 33) regardless of body."
        )

        // /image.*too.*large/i on a 400 → 33
        XCTAssertEqual(
            RemoteAgentClient.mapBodyError(
                status: 400,
                body: Data(#"{"error":{"message":"The provided image is too large; max 20MB."}}"#.utf8)
            )?.errorCode,
            33,
            "A 400 body matching /image.*too.*large/i must map to .remoteAgentImageTooLarge (code 33)."
        )

        // OpenRouter's text-only-model rejection: 404 + "No endpoints found that
        // support image input" → 32. This is the EXACT body OpenRouter returns
        // for an image sent to a text-only model (e.g. deepseek/deepseek-v4-flash,
        // verified live 2026-06-22). The phrasing matches /support.*image/i, NOT
        // the OpenClaw/Hermes /image.*not.*support/i, and it arrives on a 404 —
        // both of which the pre-fix mapper missed, surfacing the generic
        // retryable .apiFailure ("Something glitched on our end") instead.
        XCTAssertEqual(
            RemoteAgentClient.mapBodyError(
                status: 404,
                body: Data(#"{"error":{"message":"No endpoints found that support image input","code":404}}"#.utf8)
            )?.errorCode,
            32,
            "OpenRouter's 404 'No endpoints found that support image input' must map to .remoteAgentVisionUnsupported (code 32)."
        )

        // /no endpoints found for/i (404, model-not-found) → 55 (model unavailable).
        // Distinct from the image-input 404 above (which is vision/32): "No
        // endpoints found for <model>" names no image, so vision misses and the
        // model-unavailable rule catches it. Verified live 2026-06-22.
        XCTAssertEqual(
            RemoteAgentClient.mapBodyError(
                status: 404,
                body: Data(#"{"error":{"message":"No endpoints found for anthropic/claude-3.5-haiku.","code":404}}"#.utf8)
            )?.errorCode,
            55,
            "A 404 'No endpoints found for <model>' must map to .remoteAgentModelUnavailable (code 55)."
        )

        // /not a valid model/i (400, typo'd model id) → 55.
        XCTAssertEqual(
            RemoteAgentClient.mapBodyError(
                status: 400,
                body: Data(#"{"error":{"message":"deepseek/deepseek-v4-flashhh is not a valid model ID","code":400}}"#.utf8)
            )?.errorCode,
            55,
            "A 400 '<model> is not a valid model ID' must map to .remoteAgentModelUnavailable (code 55)."
        )

        // /embedding model/i (400, wrong model type) → 55.
        XCTAssertEqual(
            RemoteAgentClient.mapBodyError(
                status: 400,
                body: Data(#"{"error":{"message":"openai/text-embedding-3-small is an embedding model and cannot be used with the chat/completions endpoint.","code":400}}"#.utf8)
            )?.errorCode,
            55,
            "A 400 '<model> is an embedding model…' must map to .remoteAgentModelUnavailable (code 55)."
        )

        // /maximum context length/i (400, history+attachments overflow) → 56.
        XCTAssertEqual(
            RemoteAgentClient.mapBodyError(
                status: 400,
                body: Data(#"{"error":{"message":"This endpoint's maximum context length is 1048576 tokens. However, you requested about 2000000 tokens.","code":400}}"#.utf8)
            )?.errorCode,
            56,
            "A 400 '…maximum context length is X…' must map to .remoteAgentContextTooLong (code 56)."
        )

        // Generic 400, no recognized signal → nil (fall through to status map).
        XCTAssertNil(
            RemoteAgentClient.mapBodyError(
                status: 400,
                body: Data(#"{"error":{"message":"Missing required parameter: messages."}}"#.utf8)
            ),
            "A generic 400 body (no recognized signal) must return nil so it falls through to the status map."
        )

        // Vision keyword on an ineligible status → nil (guard short-circuits).
        XCTAssertNil(
            RemoteAgentClient.mapBodyError(
                status: 422,
                body: Data(#"{"error":{"message":"unsupported content: image_url"}}"#.utf8)
            ),
            "A 422 must not be eligible for vision mapping even with a matching body."
        )
    }

    // MARK: - Precedence through the full send() round-trip (decodeReply is private)

    /// A vision-incapable 400 driven through the actor's full round-trip must
    /// surface .remoteAgentVisionUnsupported (32) — the body-aware pass wins
    /// over the status map, which would otherwise map a generic 400 to
    /// .apiFailure (code 10, the status-map `default` arm).
    func testSendVisionIncapable400YieldsVisionUnsupportedNotStatusMap() async throws {
        let error = try await sendThrowingAppError(
            status: 400,
            body: Data(#"{"error":{"message":"model does not support unsupported content (image_url)"}}"#.utf8)
        )
        XCTAssertEqual(
            error.errorCode, 32,
            "Body-aware vision mapping must take precedence: a vision-incapable 400 yields .remoteAgentVisionUnsupported (32), NOT the status map's generic-400 .apiFailure (10)."
        )
    }

    /// OpenRouter's text-only-model rejection driven through the full round-trip
    /// must surface .remoteAgentVisionUnsupported (32). The status map has NO
    /// dedicated 404 arm — it falls through to the generic .apiFailure (code 10,
    /// the retryable "Something glitched on our end" the user actually saw before
    /// this fix). This proves the body-aware pass now wins for the 404 shape too.
    func testSendOpenRouter404ImageInputYieldsVisionUnsupportedNotStatusMap() async throws {
        let error = try await sendThrowingAppError(
            status: 404,
            body: Data(#"{"error":{"message":"No endpoints found that support image input","code":404}}"#.utf8)
        )
        XCTAssertEqual(
            error.errorCode, 32,
            "OpenRouter's 404 image-input rejection must map to .remoteAgentVisionUnsupported (32), NOT the status map's generic .apiFailure (10)."
        )
    }

    /// OpenRouter's model-not-found 404 driven through the full round-trip must
    /// surface .remoteAgentModelUnavailable (55) — NOT the vision case (the body
    /// names no image) and NOT the status map's generic .apiFailure (10, the
    /// retryable banner the user saw before this fix). Distinct from the
    /// image-input 404 above, proving the two 404 shapes stay separated.
    func testSendOpenRouter404ModelNotFoundYieldsModelUnavailable() async throws {
        let error = try await sendThrowingAppError(
            status: 404,
            body: Data(#"{"error":{"message":"No endpoints found for anthropic/claude-3.5-haiku.","code":404}}"#.utf8)
        )
        XCTAssertEqual(
            error.errorCode, 55,
            "A 404 'No endpoints found for <model>' must map to .remoteAgentModelUnavailable (55), not vision (32) or the status map's .apiFailure (10)."
        )
    }

    /// A typo'd model id (400 "is not a valid model ID") through the full
    /// round-trip → .remoteAgentModelUnavailable (55). The most common BYO-key
    /// failure (the user hand-types the model name).
    func testSendInvalidModelId400YieldsModelUnavailable() async throws {
        let error = try await sendThrowingAppError(
            status: 400,
            body: Data(#"{"error":{"message":"deepseek/deepseek-v4-flashhh is not a valid model ID","code":400}}"#.utf8)
        )
        XCTAssertEqual(
            error.errorCode, 55,
            "A 400 '<model> is not a valid model ID' must map to .remoteAgentModelUnavailable (55), not the status map's .apiFailure (10)."
        )
    }

    /// A context-window overflow (400 "maximum context length…") through the
    /// full round-trip → .remoteAgentContextTooLong (56).
    func testSendContextTooLong400YieldsContextTooLong() async throws {
        let error = try await sendThrowingAppError(
            status: 400,
            body: Data(#"{"error":{"message":"This endpoint's maximum context length is 1048576 tokens. However, you requested about 2000000 tokens.","code":400}}"#.utf8)
        )
        XCTAssertEqual(
            error.errorCode, 56,
            "A 400 '…maximum context length is X…' must map to .remoteAgentContextTooLong (56), not the status map's .apiFailure (10)."
        )
    }

    /// A 413 driven through the full round-trip must surface
    /// .remoteAgentImageTooLarge (33). The status map has NO dedicated 413 arm
    /// (it would fall through to .apiFailure, code 10), so this both proves
    /// precedence AND that the image-too-large mapping exists. Body carries no
    /// vision keyword — the mapping must come from the 413 status arm.
    func testSend413YieldsImageTooLargeNotStatusMap() async throws {
        let error = try await sendThrowingAppError(
            status: 413,
            body: Data(#"{"error":{"message":"Payload too large."}}"#.utf8)
        )
        XCTAssertEqual(
            error.errorCode, 33,
            "A 413 must map to .remoteAgentImageTooLarge (33), taking precedence over the status map (which has no 413 arm and would emit .apiFailure code 10)."
        )
    }

    /// Control / negative of the precedence claim: a generic 400 with NO
    /// vision/size signal must NOT be hijacked by the vision pass — it falls
    /// through to the status map's generic-400 arm, .apiFailure (code 10).
    /// Precedence fires only for the multimodal-specific bodies.
    func testSendGeneric400FallsThroughToStatusMapUnexpectedStatus() async throws {
        let error = try await sendThrowingAppError(
            status: 400,
            body: Data(#"{"error":{"message":"Missing required parameter: messages."}}"#.utf8)
        )
        XCTAssertEqual(
            error.errorCode, 71,
            "A generic 400 (no vision signal) must fall through the vision pass to the status map's default arm → .remoteAgentUnexpectedStatus (code 71)."
        )
        // The precedence being pinned: the body-aware pass declined this body, so
        // the status map owns the verdict — and it keeps the number instead of
        // collapsing to the old generic "Something went wrong" copy.
        XCTAssertTrue(
            error.errorDescription?.contains("400") == true,
            "the unmapped-status verdict must surface the status it saw"
        )
    }
}
