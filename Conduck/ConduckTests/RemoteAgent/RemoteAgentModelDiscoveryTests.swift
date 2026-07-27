// SPDX-License-Identifier: Apache-2.0

// Conduck
// RemoteAgentModelDiscoveryTests.swift
//
// Custom-gateways. `RemoteAgentClient.parseModelIDs(from:)` extracts the model
// suggestion list from a `/v1/models` body for the custom-gateway editor. It
// must tolerate the common OpenAI-compatible shapes and degrade to `[]` on any
// unfamiliar payload (the Model field then stays free-text — never blocks).

import XCTest
@testable import Conduck

final class RemoteAgentModelDiscoveryTests: XCTestCase {

    func testParsesOpenAIDataShape() {
        let json = Data(#"{"object":"list","data":[{"id":"llama3","object":"model"},{"id":"mistral"}]}"#.utf8)
        XCTAssertEqual(RemoteAgentClient.parseModelIDs(from: json), ["llama3", "mistral"])
    }

    func testParsesModelsKeyVariant() {
        let json = Data(#"{"models":[{"id":"a"},{"id":"b"}]}"#.utf8)
        XCTAssertEqual(RemoteAgentClient.parseModelIDs(from: json), ["a", "b"])
    }

    func testParsesBareStringArray() {
        let json = Data(#"["x","y"]"#.utf8)
        XCTAssertEqual(RemoteAgentClient.parseModelIDs(from: json), ["x", "y"])
    }

    func testUnknownShapeReturnsEmpty() {
        XCTAssertEqual(RemoteAgentClient.parseModelIDs(from: Data(#"{"foo":"bar"}"#.utf8)), [])
    }

    func testNonJSONReturnsEmpty() {
        XCTAssertEqual(RemoteAgentClient.parseModelIDs(from: Data("not json".utf8)), [])
        XCTAssertEqual(RemoteAgentClient.parseModelIDs(from: Data()), [])
    }

    func testIgnoresEntriesWithoutID() {
        let json = Data(#"{"data":[{"id":"keep"},{"object":"model"},{"id":"keep2"}]}"#.utf8)
        XCTAssertEqual(RemoteAgentClient.parseModelIDs(from: json), ["keep", "keep2"])
    }
}
