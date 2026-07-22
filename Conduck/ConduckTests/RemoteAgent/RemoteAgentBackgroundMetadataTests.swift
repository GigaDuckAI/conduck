// Conduck
// RemoteAgentBackgroundMetadataTests.swift
//
// Round-trip coverage for the converse background-task recovery
// envelope (analogous to STTBackgroundTaskMetadata). The envelope rides in
// `URLSessionTask.taskDescription`; after a cross-launch resume the delegate
// must recover the body path (cleanup), conversation ID (reply target), and
// backend (status map).

import XCTest
@testable import Conduck

final class RemoteAgentBackgroundMetadataTests: XCTestCase {

    func testEncodeDecodeRoundTrip() throws {
        let original = RemoteAgentBackgroundMetadata(
            bodyPath: "/tmp/conduck-converse-body-ABC.json",
            conversationID: "11111111-2222-3333-4444-555555555555",
            backendRawValue: "openclaw"
        )
        let encoded = try original.encodedString()
        let decoded = try RemoteAgentBackgroundMetadata.decode(encoded)

        XCTAssertEqual(decoded.bodyPath, original.bodyPath)
        XCTAssertEqual(decoded.conversationID, original.conversationID)
        XCTAssertEqual(decoded.backendRawValue, original.backendRawValue)
    }

    func testEncodedStringIsValidJSON() throws {
        let meta = RemoteAgentBackgroundMetadata(
            bodyPath: "/tmp/x|y.json",  // path with `|` — JSON-safe (not delimiter-parsed)
            conversationID: "abc",
            backendRawValue: "hermes"
        )
        let encoded = try meta.encodedString()
        let data = try XCTUnwrap(encoded.data(using: .utf8))
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(obj?["bodyPath"] as? String, "/tmp/x|y.json")
        XCTAssertEqual(obj?["backendRawValue"] as? String, "hermes")
    }

    func testDecodeRejectsGarbage() {
        XCTAssertThrowsError(try RemoteAgentBackgroundMetadata.decode("not json"))
    }

    // MARK: - shareEnvelopeID (Share-Extension)

    func testShareEnvelopeIDRoundTrips() throws {
        let envelopeID = UUID()
        let original = RemoteAgentBackgroundMetadata(
            bodyPath: "/tmp/body.json",
            conversationID: "11111111-2222-3333-4444-555555555555",
            backendRawValue: "openclaw",
            shareEnvelopeID: envelopeID
        )
        let decoded = try RemoteAgentBackgroundMetadata.decode(original.encodedString())
        XCTAssertEqual(decoded.shareEnvelopeID, envelopeID,
                       "The share envelope id must survive the taskDescription round-trip.")
    }

    func testDefaultShareEnvelopeIDIsNil() throws {
        // The non-share callers (in-app, headless Shortcut, CarPlay) construct
        // the metadata WITHOUT a shareEnvelopeID — the defaulted init must leave
        // it nil and round-trip as nil.
        let original = RemoteAgentBackgroundMetadata(
            bodyPath: "/tmp/body.json",
            conversationID: "abc",
            backendRawValue: "hermes"
        )
        XCTAssertNil(original.shareEnvelopeID)
        let decoded = try RemoteAgentBackgroundMetadata.decode(original.encodedString())
        XCTAssertNil(decoded.shareEnvelopeID)
    }

    func testTolerantDecodeOfPreShareTaskDescription() throws {
        // A taskDescription written BEFORE shareEnvelopeID existed (key absent)
        // must still decode — the Optional's synthesized decoder uses
        // decodeIfPresent, so the field is nil, not a decode failure.
        let legacyJSON = """
        {"bodyPath":"/tmp/old.json","conversationID":"cid","backendRawValue":"openclaw"}
        """
        let decoded = try RemoteAgentBackgroundMetadata.decode(legacyJSON)
        XCTAssertEqual(decoded.bodyPath, "/tmp/old.json")
        XCTAssertEqual(decoded.backendRawValue, "openclaw")
        XCTAssertNil(decoded.shareEnvelopeID,
                     "A pre-field taskDescription must decode with shareEnvelopeID == nil (tolerant).")
    }

    // MARK: - stampsActiveConversation (per-device implicit-only pointer)

    func testStampsActiveConversationRoundTrips() throws {
        // A headless quick-capture dispatch threads `true`; the delegate's
        // success path reads it back after a cross-launch resume.
        let original = RemoteAgentBackgroundMetadata(
            bodyPath: "/tmp/body.json",
            conversationID: "11111111-2222-3333-4444-555555555555",
            backendRawValue: "openclaw",
            stampsActiveConversation: true
        )
        let decoded = try RemoteAgentBackgroundMetadata.decode(original.encodedString())
        XCTAssertEqual(decoded.stampsActiveConversation, true,
                       "The quick-capture stamp flag must survive the taskDescription round-trip.")
    }

    func testTolerantDecodeWithoutStampKeyPinsNoStampDefault() throws {
        // A taskDescription written BEFORE stampsActiveConversation existed
        // (key absent) must decode with nil — which every consumer maps to
        // FALSE (never stamp). Pins the no-stamp default for legacy in-flight
        // blobs across the redesign.
        let legacyJSON = """
        {"bodyPath":"/tmp/old.json","conversationID":"cid","backendRawValue":"openclaw"}
        """
        let decoded = try RemoteAgentBackgroundMetadata.decode(legacyJSON)
        XCTAssertNil(decoded.stampsActiveConversation,
                     "A pre-field taskDescription must decode with stampsActiveConversation == nil (no-stamp default).")
    }

    // MARK: - refRawValue (cert-pin per-ref identity carrier, audit B1)

    func testRefRawValueRoundTripsForCustomGateway() throws {
        // The TRUE gateway identity must survive the taskDescription round-trip
        // so the trust delegate resolves the correct per-ref pin after a
        // cross-launch resume. A custom ref is the load-bearing case: its
        // backendRawValue is "openclaw" (status-map carrier), so refRawValue is
        // the ONLY field that distinguishes it.
        let custom = RemoteAgentRef.custom(UUID())
        let original = RemoteAgentBackgroundMetadata(
            bodyPath: "/tmp/body.json",
            conversationID: "11111111-2222-3333-4444-555555555555",
            backendRawValue: "openclaw",   // carrier — same for every custom
            refRawValue: custom.rawString
        )
        let decoded = try RemoteAgentBackgroundMetadata.decode(original.encodedString())
        XCTAssertEqual(decoded.refRawValue, custom.rawString)
        XCTAssertEqual(RemoteAgentRef(rawString: try XCTUnwrap(decoded.refRawValue)), custom,
                       "The recovered refRawValue must parse back to the exact custom ref.")
        XCTAssertEqual(decoded.backendRawValue, "openclaw",
                       "backendRawValue stays the carrier — refRawValue is the true identity.")
    }

    func testDefaultRefRawValueIsNil() throws {
        let original = RemoteAgentBackgroundMetadata(
            bodyPath: "/tmp/body.json",
            conversationID: "abc",
            backendRawValue: "hermes"
        )
        XCTAssertNil(original.refRawValue)
        let decoded = try RemoteAgentBackgroundMetadata.decode(original.encodedString())
        XCTAssertNil(decoded.refRawValue)
    }

    func testTolerantDecodeWithoutRefKeyDecodesNil() throws {
        // A converse task enqueued BEFORE refRawValue existed (in-flight across
        // the upgrade) must still decode — refRawValue nil → the trust delegate
        // falls through to default ATS (the pre-fix behavior), never a crash.
        let legacyJSON = """
        {"bodyPath":"/tmp/old.json","conversationID":"cid","backendRawValue":"openclaw"}
        """
        let decoded = try RemoteAgentBackgroundMetadata.decode(legacyJSON)
        XCTAssertNil(decoded.refRawValue,
                     "A pre-field taskDescription must decode with refRawValue == nil (tolerant).")
    }
}
