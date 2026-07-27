// SPDX-License-Identifier: Apache-2.0

// Conduck
// ConverseRequestModelTests.swift
//
// Custom-gateways. The optional `model` field on `ConverseRequest` MUST be
// OMITTED from the encoded body when nil — built-ins (and every existing
// caller) pass nil, so the wire stays byte-identical to before (`{messages,
// stream}`). A custom gateway may set it, and then it appears as a top-level
// `"model"` string. This is the back-compat lock for the model-threading change.

import XCTest
@testable import Conduck

final class ConverseRequestModelTests: XCTestCase {

    private func encodedTopLevelKeys(_ request: ConverseRequest) throws -> Set<String> {
        let data = try JSONEncoder().encode(request)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return Set((object ?? [:]).keys)
    }

    private func makeMessages() -> [ConverseRequest.Message] {
        [ConverseRequest.Message(role: "user", content: .text("hi"))]
    }

    func testModelOmittedWhenNil() throws {
        let request = ConverseRequest(messages: makeMessages(), stream: false)
        let keys = try encodedTopLevelKeys(request)
        XCTAssertEqual(keys, ["messages", "stream"],
                       "Built-in / nil-model body must be exactly {messages, stream} — no \"model\" key, no null")
    }

    func testModelOmittedWhenNilExplicit() throws {
        let request = ConverseRequest(messages: makeMessages(), stream: false, model: nil)
        let keys = try encodedTopLevelKeys(request)
        XCTAssertFalse(keys.contains("model"))
    }

    func testModelPresentWhenSet() throws {
        let request = ConverseRequest(messages: makeMessages(), stream: false, model: "llama3")
        let keys = try encodedTopLevelKeys(request)
        XCTAssertEqual(keys, ["messages", "stream", "model"])

        let data = try JSONEncoder().encode(request)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(object?["model"] as? String, "llama3")
    }

    func testStreamIsFalseAndMessagesPreserved() throws {
        let request = ConverseRequest(messages: makeMessages(), stream: false, model: "gpt-4o")
        let data = try JSONEncoder().encode(request)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(object?["stream"] as? Bool, false)
        XCTAssertNotNil(object?["messages"] as? [Any])
    }
}
