// Conduck
// RemoteAgentRefTests.swift
//
// Custom-gateways. `RemoteAgentRef` is the routing identity persisted in
// `Conversation.backend` + the per-ref storage-key suffixes + the broadcast
// envelopes. Its serialization is LOAD-BEARING: built-ins MUST round-trip to
// their locked raw values (migration-free), customs to `custom_<uuid>`, and
// the namespaces MUST be provably disjoint (a UUID string can never be read as
// a built-in, and a reserved keyword can never be read as a custom).

import XCTest
@testable import Conduck

final class RemoteAgentRefTests: XCTestCase {

    // MARK: - Built-in serialization (back-compat / migration-free)

    func testBuiltinRawStringEqualsBackendRawValue() {
        XCTAssertEqual(RemoteAgentRef.builtin(.openclaw).rawString, "openclaw")
        XCTAssertEqual(RemoteAgentRef.builtin(.hermes).rawString, "hermes")
    }

    func testStorageKeySuffixEqualsRawString() {
        for backend in RemoteAgentBackend.allCases {
            let ref = RemoteAgentRef.builtin(backend)
            XCTAssertEqual(ref.storageKeySuffix, ref.rawString)
            XCTAssertEqual(ref.storageKeySuffix, backend.rawValue,
                           "Built-in suffix must equal the locked raw value — else every existing stored key orphans")
        }
    }

    func testLegacyConversationBackendParsesToBuiltin() {
        // A pre-feature `Conversation.backend == "openclaw"` MUST still route.
        XCTAssertEqual(RemoteAgentRef(rawString: "openclaw"), .builtin(.openclaw))
        XCTAssertEqual(RemoteAgentRef(rawString: "hermes"), .builtin(.hermes))
    }

    // MARK: - Custom serialization

    func testCustomRawStringIsPrefixedLowercasedUUID() {
        let id = UUID()
        let ref = RemoteAgentRef.custom(id)
        XCTAssertEqual(ref.rawString, "custom_" + id.uuidString.lowercased())
        XCTAssertTrue(ref.rawString.hasPrefix(RemoteAgentRef.customPrefix))
    }

    func testCustomRawStringRoundTrips() {
        let id = UUID()
        let parsed = RemoteAgentRef(rawString: "custom_" + id.uuidString.lowercased())
        XCTAssertEqual(parsed, .custom(id))
        XCTAssertEqual(parsed?.customID, id)
    }

    // MARK: - Collision-safety (the two namespaces are disjoint)

    func testReservedKeywordsNeverParseAsCustom() {
        // "openclaw"/"hermes" parse as BUILT-IN, never custom.
        XCTAssertEqual(RemoteAgentRef(rawString: "openclaw")?.isBuiltin, true)
        XCTAssertNil(RemoteAgentRef(rawString: "openclaw")?.customID)
        XCTAssertNil(RemoteAgentRef(rawString: "hermes")?.customID)
    }

    func testGarbageRawStringsReturnNil() {
        XCTAssertNil(RemoteAgentRef(rawString: ""))
        XCTAssertNil(RemoteAgentRef(rawString: "nonsense"))
        XCTAssertNil(RemoteAgentRef(rawString: "custom_"))           // prefix but no UUID
        XCTAssertNil(RemoteAgentRef(rawString: "custom_not-a-uuid")) // prefix but invalid UUID
        XCTAssertNil(RemoteAgentRef(rawString: "openclaw_extra"))    // not a reserved keyword nor a custom
    }

    func testIsBuiltinAndCustomID() {
        XCTAssertTrue(RemoteAgentRef.builtin(.openclaw).isBuiltin)
        XCTAssertNil(RemoteAgentRef.builtin(.openclaw).customID)
        let id = UUID()
        XCTAssertFalse(RemoteAgentRef.custom(id).isBuiltin)
        XCTAssertEqual(RemoteAgentRef.custom(id).customID, id)
    }

    // MARK: - Codable (single-value container over rawString)

    func testCodableRoundTripBuiltin() throws {
        for backend in RemoteAgentBackend.allCases {
            let ref = RemoteAgentRef.builtin(backend)
            let data = try JSONEncoder().encode(ref)
            XCTAssertEqual(try JSONDecoder().decode(RemoteAgentRef.self, from: data), ref)
        }
    }

    func testCodableRoundTripCustom() throws {
        let ref = RemoteAgentRef.custom(UUID())
        let data = try JSONEncoder().encode(ref)
        XCTAssertEqual(try JSONDecoder().decode(RemoteAgentRef.self, from: data), ref)
    }

    func testCodableEncodesBareString() throws {
        // The single-value container encodes the rawString as a bare JSON string
        // (so envelopes / persistence stay human-legible + stable).
        let data = try JSONEncoder().encode(RemoteAgentRef.builtin(.openclaw))
        XCTAssertEqual(String(data: data, encoding: .utf8), "\"openclaw\"")
    }

    func testCodableRejectsGarbage() {
        let garbage = Data("\"nonsense\"".utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(RemoteAgentRef.self, from: garbage))
    }
}
