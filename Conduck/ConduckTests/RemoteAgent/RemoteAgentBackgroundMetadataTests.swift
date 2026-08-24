// SPDX-License-Identifier: Apache-2.0

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

    // MARK: - attemptID + agentMessageID (usage ledger + reply idempotency)

    func testAttemptAndAgentMessageIDsRoundTrip() throws {
        let attemptID = UUID()
        let agentMessageID = UUID()
        let original = RemoteAgentBackgroundMetadata(
            bodyPath: "/tmp/body.json",
            conversationID: "11111111-2222-3333-4444-555555555555",
            backendRawValue: "openclaw",
            attemptID: attemptID,
            agentMessageID: agentMessageID
        )
        let decoded = try RemoteAgentBackgroundMetadata.decode(original.encodedString())
        XCTAssertEqual(decoded.attemptID, attemptID,
                       "The ledger row's id must survive the taskDescription round-trip — it is "
                           + "the only channel that can close the row after a relaunch.")
        XCTAssertEqual(decoded.agentMessageID, agentMessageID,
                       "The reply's Message.id must survive the round-trip — a replayed "
                           + "completion deduplicates on it.")
    }

    func testDefaultAttemptAndAgentMessageIDsAreNil() throws {
        // The pre-ledger construction sites (CarPlay uploader, tests) must stay
        // byte-identical: both new fields default to nil and round-trip as nil.
        let original = RemoteAgentBackgroundMetadata(
            bodyPath: "/tmp/body.json",
            conversationID: "abc",
            backendRawValue: "hermes"
        )
        XCTAssertNil(original.attemptID)
        XCTAssertNil(original.agentMessageID)
        let decoded = try RemoteAgentBackgroundMetadata.decode(original.encodedString())
        XCTAssertNil(decoded.attemptID)
        XCTAssertNil(decoded.agentMessageID)
    }

    func testTolerantDecodeOfPreLedgerTaskDescription() throws {
        // THE UPGRADE CASE, and the one that has to be right: a converse task
        // enqueued by the previous build is still live when the ledger ships.
        // Its taskDescription has neither key, and it must land exactly as it
        // always did — attemptID nil (measure nothing, fabricate no row) and
        // agentMessageID nil (fall back to a freshly minted reply id).
        let legacyJSON = """
        {"bodyPath":"/tmp/old.json","conversationID":"cid","backendRawValue":"openclaw",\
        "refRawValue":"hermes","stampsActiveConversation":true,"outputBoxKey":"cid/out-ab12"}
        """
        let decoded = try RemoteAgentBackgroundMetadata.decode(legacyJSON)
        XCTAssertNil(decoded.attemptID,
                     "A pre-ledger taskDescription must decode with attemptID == nil (tolerant).")
        XCTAssertNil(decoded.agentMessageID,
                     "A pre-ledger taskDescription must decode with agentMessageID == nil (tolerant).")
        // Everything the old blob DID carry still arrives — the additive fields
        // must not have disturbed the existing keys.
        XCTAssertEqual(decoded.bodyPath, "/tmp/old.json")
        XCTAssertEqual(decoded.refRawValue, "hermes")
        XCTAssertEqual(decoded.stampsActiveConversation, true)
        XCTAssertEqual(decoded.outputBoxKey, "cid/out-ab12")
    }

    func testTolerantDecodeOfUnknownFutureKey() throws {
        // The mirror of the case above: a taskDescription written by a LATER
        // build (an extra key this one has never heard of) must still decode,
        // or an upgrade that lands mid-turn strands the reply.
        let futureJSON = """
        {"bodyPath":"/tmp/new.json","conversationID":"cid","backendRawValue":"openclaw",\
        "attemptID":"11111111-2222-3333-4444-555555555555","somethingNewer":42}
        """
        let decoded = try RemoteAgentBackgroundMetadata.decode(futureJSON)
        XCTAssertEqual(decoded.attemptID,
                       UUID(uuidString: "11111111-2222-3333-4444-555555555555"))
    }

    func testMeasuredAndUnmeasuredVariantsDifferOnlyByAttemptID() throws {
        // THE FAIL-OPEN CONTRACT, pinned. `send` pre-encodes both variants
        // before the ledger insert and picks one afterwards; if the insert
        // fails it attaches the nil-variant. That fallback is only safe while
        // the two envelopes are identical in every field the delegate needs to
        // land the reply — INCLUDING agentMessageID, because reply idempotency
        // must not depend on the ledger.
        let agentMessageID = UUID()
        let common: (UUID?) -> RemoteAgentBackgroundMetadata = { attemptID in
            RemoteAgentBackgroundMetadata(
                bodyPath: "/tmp/body.json",
                conversationID: "11111111-2222-3333-4444-555555555555",
                backendRawValue: "openclaw",
                refRawValue: "custom_22222222-3333-4444-5555-666666666666",
                shareEnvelopeID: nil,
                userMessageID: UUID(uuidString: "33333333-4444-5555-6666-777777777777"),
                stampsActiveConversation: false,
                requestHadHistoryImages: true,
                fileTransferLaneID: "lane-1",
                outputBoxKey: "cid/out-ab12",
                dispatchChatSignature: "sig",
                attemptID: attemptID,
                agentMessageID: agentMessageID
            )
        }
        let measured = try RemoteAgentBackgroundMetadata.decode(common(UUID()).encodedString())
        let unmeasured = try RemoteAgentBackgroundMetadata.decode(common(nil).encodedString())

        XCTAssertNotNil(measured.attemptID)
        XCTAssertNil(unmeasured.attemptID)
        XCTAssertEqual(measured.agentMessageID, unmeasured.agentMessageID,
                       "Reply idempotency must hold on the unmeasured variant too — the "
                           + "fail-open measurement layer can never be the only duplicate guard.")
        XCTAssertEqual(measured.bodyPath, unmeasured.bodyPath)
        XCTAssertEqual(measured.conversationID, unmeasured.conversationID)
        XCTAssertEqual(measured.backendRawValue, unmeasured.backendRawValue)
        XCTAssertEqual(measured.refRawValue, unmeasured.refRawValue)
        XCTAssertEqual(measured.userMessageID, unmeasured.userMessageID)
        XCTAssertEqual(measured.stampsActiveConversation, unmeasured.stampsActiveConversation)
        XCTAssertEqual(measured.requestHadHistoryImages, unmeasured.requestHadHistoryImages)
        XCTAssertEqual(measured.fileTransferLaneID, unmeasured.fileTransferLaneID)
        XCTAssertEqual(measured.outputBoxKey, unmeasured.outputBoxKey)
        XCTAssertEqual(measured.dispatchChatSignature, unmeasured.dispatchChatSignature)
    }

    func testAttemptIDIsNotDerivedFromAgentMessageID() throws {
        // Pins the separation the duplicate-guard argument rests on. If a future
        // change derived one from the other, a dispatch whose ledger insert
        // failed would carry no reply id either, and a replayed completion would
        // insert a second agent bubble.
        let meta = RemoteAgentBackgroundMetadata(
            bodyPath: "/tmp/body.json",
            conversationID: "cid",
            backendRawValue: "openclaw",
            attemptID: UUID(),
            agentMessageID: UUID()
        )
        XCTAssertNotEqual(meta.attemptID, meta.agentMessageID)
    }
}
