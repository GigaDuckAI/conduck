// SPDX-License-Identifier: Apache-2.0

// Conduck
// RemoteAgentProbeBodyTests.swift
//
// Test Connection's VERDICT is decided by the response BODY, not the status
// code alone. This suite locks that down, because the failure it prevents is
// the worst kind: a gateway that cannot answer a single turn reporting a green
// "Connected".
//
// The motivating case, and the reason the strictness here is not paranoia:
// OpenClaw ships with its OpenAI chat endpoint DISABLED, and a disabled
// endpoint serves the Control-UI **HTML at HTTP 200** on `/v1/models`. A
// status-only probe reads that as success. `conduck-connect.sh` has guarded
// against it from the start (`models_is_json`); the app now does too.
//
// The pure-function cases drive `RemoteAgentClient.validateProbeBody` directly;
// the wire cases go through `testConnectionForTesting` + `MockURLProtocol` to
// prove the validator is actually reached from the real probe path.

import XCTest
@testable import Conduck

final class RemoteAgentProbeBodyTests: XCTestCase {

    private let baseURL = URL(string: "https://gateway.example.com")!
    private let token = "test-token"

    private var session: URLSession!

    override func setUp() {
        super.setUp()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        session = URLSession(configuration: config)
    }

    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        session = nil
        super.tearDown()
    }

    // MARK: - THE regression: HTML at 200 must not be a pass

    /// The endpoint-off trap, end to end on the wire. If this ever goes green
    /// again, Test Connection is lying to users about a dead gateway.
    func testHTMLBodyAt200IsNotAPass() async {
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200,
                httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/html"]
            )!
            return (response, Data("<!DOCTYPE html><html><body>OpenClaw Control UI</body></html>".utf8))
        }

        do {
            let outcome = try await RemoteAgentClient.shared.testConnectionForTesting(
                backend: .openclaw, url: baseURL, token: token, session: session
            )
            XCTFail("A 200 serving the Control-UI HTML must NOT pass — got \(outcome)")
        } catch let error as AppError {
            XCTAssertEqual(error.errorCode, AppError.remoteAgentEndpointUnexpectedResponse.errorCode,
                           "HTML at 200 must surface as endpoint-unexpected-response, not success.")
        } catch {
            XCTFail("Expected AppError, got \(type(of: error))")
        }
    }

    // MARK: - Verdict strictness (the LM Studio false green)

    /// `{"models":[…]}` is a REAL envelope — LM Studio's NATIVE `/api/v1/models`
    /// returns it — but its native chat route is not `/v1/chat/completions`.
    /// Accepting it as a verdict would green-light a base URL whose chat route
    /// does not exist. Tolerant DISCOVERY still accepts it (see the last test);
    /// the verdict must not.
    func testModelsEnvelopeIsRejectedByTheVerdictEvenThoughDiscoveryAcceptsIt() {
        let body = Data(#"{"models":[{"id":"qwen3"}]}"#.utf8)

        XCTAssertThrowsError(
            try RemoteAgentClient.validateProbeBody(body, shape: .modelListEnvelope),
            "A `models` envelope must NOT pass the verdict — it green-lights a base URL whose chat route may not exist."
        ) { error in
            XCTAssertEqual((error as? AppError)?.errorCode,
                           AppError.remoteAgentEndpointWrongEnvelope.errorCode,
                           "Valid JSON in the wrong shape is WRONG-ENVELOPE (62) — its copy names the `data`-array rule.")
        }

        XCTAssertEqual(RemoteAgentClient.parseModelIDs(from: body), ["qwen3"],
                       "Discovery stays tolerant of the same body — only the VERDICT is strict.")
    }

    // MARK: - modelListEnvelope

    func testPopulatedDataArrayPasses() throws {
        let outcome = try RemoteAgentClient.validateProbeBody(
            Data(#"{"data":[{"id":"llama3"}]}"#.utf8), shape: .modelListEnvelope
        )
        XCTAssertEqual(outcome, .ok)
    }

    /// An empty list is structurally valid — the route exists and speaks the
    /// protocol — but a gateway advertising zero models can't answer a turn, so
    /// it is a DISTINCT outcome rather than a flat green.
    func testEmptyDataArrayPassesAsNoModels() throws {
        let outcome = try RemoteAgentClient.validateProbeBody(
            Data(#"{"data":[]}"#.utf8), shape: .modelListEnvelope
        )
        XCTAssertEqual(outcome, .okNoModels)
        XCTAssertTrue(outcome.isSuccess, "No-models is a pass — the endpoint is real.")
    }

    func testEmptyBodyFails() {
        XCTAssertThrowsError(
            try RemoteAgentClient.validateProbeBody(Data(), shape: .modelListEnvelope),
            "An empty body (or a 204) proves the HOST answered, never that the AI route exists."
        ) { error in
            XCTAssertEqual((error as? AppError)?.errorCode,
                           AppError.remoteAgentEndpointUnexpectedResponse.errorCode,
                           "No JSON to judge → the not-JSON exit (58), not wrong-envelope.")
        }
    }

    func testMalformedJSONFails() {
        XCTAssertThrowsError(
            try RemoteAgentClient.validateProbeBody(Data(#"{"data":[}"#.utf8), shape: .modelListEnvelope)
        ) { error in
            XCTAssertEqual((error as? AppError)?.errorCode,
                           AppError.remoteAgentEndpointUnexpectedResponse.errorCode,
                           "Malformed JSON is not JSON — the not-JSON exit (58).")
        }
    }

    /// `{}` is perfectly valid JSON — so it takes the WRONG-ENVELOPE (62) exit,
    /// whose copy names the `data`-array rule instead of guessing "a web page".
    func testValidJSONWithoutTheEnvelopeFailsAsWrongEnvelope() {
        XCTAssertThrowsError(
            try RemoteAgentClient.validateProbeBody(Data(#"{"status":"ok"}"#.utf8), shape: .modelListEnvelope)
        ) { error in
            XCTAssertEqual((error as? AppError)?.errorCode,
                           AppError.remoteAgentEndpointWrongEnvelope.errorCode)
        }
    }

    func testBareArrayIsRejectedByTheVerdict() {
        XCTAssertThrowsError(
            try RemoteAgentClient.validateProbeBody(Data(#"["llama3"]"#.utf8), shape: .modelListEnvelope),
            "A bare array is a discovery-tolerant shape, not a verdict shape."
        ) { error in
            XCTAssertEqual((error as? AppError)?.errorCode,
                           AppError.remoteAgentEndpointWrongEnvelope.errorCode,
                           "A bare array IS JSON — it must take the wrong-envelope exit, not the not-JSON one.")
        }
    }

    // MARK: - keyEnvelope (OpenRouter /v1/key)

    func testKeyEnvelopeObjectPasses() throws {
        let outcome = try RemoteAgentClient.validateProbeBody(
            Data(#"{"data":{"label":"sk-or-…","limit":10}}"#.utf8), shape: .keyEnvelope
        )
        XCTAssertEqual(outcome, .ok)
    }

    func testKeyEnvelopeRejectsMissingData() {
        XCTAssertThrowsError(
            try RemoteAgentClient.validateProbeBody(Data(#"{}"#.utf8), shape: .keyEnvelope)
        )
    }

    /// `data` must be an OBJECT here. An ARRAY means we reached some other
    /// endpoint (e.g. a model list) — not the key-introspection route that is
    /// the only thing able to prove the API key.
    func testKeyEnvelopeRejectsAnArrayPayload() {
        XCTAssertThrowsError(
            try RemoteAgentClient.validateProbeBody(Data(#"{"data":[]}"#.utf8), shape: .keyEnvelope)
        )
    }

    // MARK: - 404 on the probe route

    /// Probe-only classification. The shared `RemoteAgentStatusMap` must NOT map
    /// 404, because on the SEND path a 404 can legitimately mean "that model
    /// doesn't exist" — the map sees only an Int and cannot tell them apart.
    func testProbe404MapsToEndpointNotFound() async {
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!
            return (response, Data())
        }

        do {
            _ = try await RemoteAgentClient.shared.testConnectionForTesting(
                backend: .openclaw, url: baseURL, token: token, session: session
            )
            XCTFail("A 404 on the probe route must throw")
        } catch let error as AppError {
            XCTAssertEqual(error.errorCode, AppError.remoteAgentEndpointNotFound.errorCode)
        } catch {
            XCTFail("Expected AppError, got \(type(of: error))")
        }
    }

    // MARK: - "model is required" (the empty-model custom gateway)

    /// Ollama / vLLM / a default-less LiteLLM reject a turn that names no model.
    /// A custom gateway's model field is `.optional`, so nothing blocks saving one
    /// empty — making this the commonest failure of a hand-configured gateway.
    func testModelRequiredBodyMapsAtBoth400And422() throws {
        let ollama = Data(#"{"error":{"message":"model is required"}}"#.utf8)
        XCTAssertEqual(
            RemoteAgentClient.mapBodyError(status: 400, body: ollama)?.errorCode,
            AppError.remoteAgentModelRequired.errorCode
        )

        // FastAPI-backed servers (vLLM, some LiteLLM deployments) answer 422, which
        // the body-aware pass ignored entirely until 422 joined its status guard.
        let vllm = Data(#"{"error":{"message":"you must provide a model parameter"}}"#.utf8)
        XCTAssertEqual(
            RemoteAgentClient.mapBodyError(status: 422, body: vllm)?.errorCode,
            AppError.remoteAgentModelRequired.errorCode,
            "A 422 validation envelope must reach the body-aware mapper."
        )
    }

    /// A WRONG model name and a MISSING one are different problems with different
    /// fixes ("check the name" vs "set one"), so they must not collapse together.
    func testWrongModelStillMapsToModelUnavailable() {
        let body = Data(#"{"error":{"message":"not a valid model id"}}"#.utf8)
        XCTAssertEqual(
            RemoteAgentClient.mapBodyError(status: 400, body: body)?.errorCode,
            AppError.remoteAgentModelUnavailable.errorCode
        )
    }
}
