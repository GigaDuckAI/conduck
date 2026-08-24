// SPDX-License-Identifier: Apache-2.0

// Conduck
// GatewayResponseMetadataTests.swift
//
// The full tolerance matrix for the optional response-metadata parser. The
// contract it pins has two halves and both are load-bearing:
//
// 1. NOTHING A GATEWAY SENDS CAN MAKE THE PARSER THROW, and no single hostile
//    field may take a valid sibling down with it. The parser runs on the same
//    bytes as the strict reply decoder, so a `usage` block that fails to
//    validate must leave a perfectly good reply untouched.
// 2. A VALUE IS KEPT ONLY IF IT IS EXACTLY WHAT IT CLAIMS TO BE. A token count
//    is a non-negative JSON integer or it is nothing — Booleans, numeric
//    strings, floating-point literals and out-of-range values are all rejected
//    rather than coerced, because each of them has a coercion that looks like a
//    plausible number and would be stored as a fact forever.
//
// The Boolean case is the one worth stating out loud: `JSONSerialization`
// bridges `true` to an `NSNumber` whose `intValue` is 1, so the obvious
// `as? NSNumber` read records "one token" for a gateway that reported a flag.
// Only the CoreFoundation type id separates them, and this file is what keeps
// that check in place.

import XCTest
@testable import Conduck

final class GatewayResponseMetadataTests: XCTestCase {

    private func parse(_ json: String) -> GatewayResponseMetadata {
        GatewayResponseMetadata.parse(Data(json.utf8))
    }

    // MARK: - Absent / unusable bodies

    func testEmptyDataYieldsAnEmptyObservation() {
        let metadata = GatewayResponseMetadata.parse(Data())
        XCTAssertTrue(metadata.isEmpty)
        XCTAssertNil(metadata.reportedModel)
        XCTAssertNil(metadata.reportedTotalTokens)
    }

    func testNonJSONBodyYieldsAnEmptyObservation() {
        XCTAssertTrue(parse("<html>502 Bad Gateway</html>").isEmpty,
                      "an HTML error page is a complete response body and must parse to nothing "
                      + "rather than throw on a landing path that has no error handling left")
    }

    func testJSONArrayRootYieldsAnEmptyObservation() {
        XCTAssertTrue(parse(#"[{"model":"gpt-4o"}]"#).isEmpty,
                      "only a top-level object is observed — a model id nested inside an array is "
                      + "not the field the contract names")
    }

    func testReplyWithNoMetadataYieldsAnEmptyObservation() {
        let metadata = parse(#"{"choices":[{"message":{"role":"assistant","content":"hi"}}]}"#)
        XCTAssertTrue(metadata.isEmpty,
                      "a conformant gateway may report none of this; absence is not a failure")
    }

    // MARK: - The happy path

    func testFullUsageAndIdentityAreObserved() {
        let metadata = parse("""
        {
          "id": "chatcmpl-abc123",
          "model": "anthropic/claude-opus-4",
          "choices": [{"finish_reason": "stop",
                       "message": {"role": "assistant", "content": "hello"}}],
          "usage": {"prompt_tokens": 1200, "completion_tokens": 340, "total_tokens": 1540}
        }
        """)
        XCTAssertEqual(metadata.reportedResponseID, "chatcmpl-abc123")
        XCTAssertEqual(metadata.reportedModel, "anthropic/claude-opus-4")
        XCTAssertEqual(metadata.finishReason, "stop")
        XCTAssertEqual(metadata.reportedInputTokens, 1200)
        XCTAssertEqual(metadata.reportedOutputTokens, 340)
        XCTAssertEqual(metadata.reportedTotalTokens, 1540)
        XCTAssertFalse(metadata.isEmpty)
    }

    func testPartialUsageKeepsWhatWasReported() {
        let metadata = parse(#"{"usage":{"total_tokens":90}}"#)
        XCTAssertNil(metadata.reportedInputTokens)
        XCTAssertNil(metadata.reportedOutputTokens)
        XCTAssertEqual(metadata.reportedTotalTokens, 90)
    }

    func testExplicitZeroIsAReportedValueNotAnAbsence() {
        let metadata = parse(#"{"usage":{"prompt_tokens":0,"completion_tokens":0,"total_tokens":0}}"#)
        XCTAssertEqual(metadata.reportedInputTokens, 0)
        XCTAssertEqual(metadata.reportedOutputTokens, 0)
        XCTAssertEqual(metadata.reportedTotalTokens, 0)
        XCTAssertFalse(metadata.isEmpty,
                       "a reported zero is an observation — coverage must count this attempt as "
                       + "having reported, which is the distinction the non-scalar columns exist for")
    }

    func testUnknownTopLevelAndNestedFieldsAreIgnored() {
        let metadata = parse("""
        {
          "object": "chat.completion",
          "created": 1730000000,
          "system_fingerprint": "fp_9",
          "model": "m1",
          "usage": {"prompt_tokens": 5, "cached_tokens": 3, "cost": 0.004, "total_tokens": 9},
          "provider": {"name": "somewhere"}
        }
        """)
        XCTAssertEqual(metadata.reportedModel, "m1")
        XCTAssertEqual(metadata.reportedInputTokens, 5)
        XCTAssertEqual(metadata.reportedTotalTokens, 9)
        XCTAssertNil(metadata.reportedOutputTokens)
    }

    // MARK: - finish_reason

    func testFinishReasonComesFromTheFirstChoiceOnly() {
        let metadata = parse("""
        {"choices":[{"finish_reason":"length"},{"finish_reason":"stop"}]}
        """)
        XCTAssertEqual(metadata.finishReason, "length",
                       "the reply decoder keeps the first choice; a stop reason read off a later "
                       + "one would describe text nobody was shown")
    }

    func testTruncationIsReportedVerbatim() {
        XCTAssertEqual(parse(#"{"choices":[{"finish_reason":"length"}]}"#).finishReason, "length")
    }

    func testEmptyChoicesArrayLeavesFinishReasonNil() {
        XCTAssertNil(parse(#"{"choices":[]}"#).finishReason)
    }

    func testNonStringFinishReasonIsRejected() {
        XCTAssertNil(parse(#"{"choices":[{"finish_reason":7}]}"#).finishReason)
    }

    // MARK: - Numeric validation

    func testBooleanTokenCountIsRejected() {
        let metadata = parse(#"{"usage":{"prompt_tokens":true,"completion_tokens":false}}"#)
        XCTAssertNil(metadata.reportedInputTokens,
                     "JSONSerialization bridges `true` to an NSNumber whose intValue is 1 — without "
                     + "the CFBoolean check this reads back as a one-token prompt")
        XCTAssertNil(metadata.reportedOutputTokens)
    }

    func testNumericStringIsRejected() {
        XCTAssertNil(parse(#"{"usage":{"total_tokens":"42"}}"#).reportedTotalTokens)
    }

    func testFractionalNumberIsRejected() {
        XCTAssertNil(parse(#"{"usage":{"total_tokens":12.5}}"#).reportedTotalTokens)
    }

    func testFloatingPointSpellingOfAWholeNumberIsRejected() {
        XCTAssertNil(parse(#"{"usage":{"total_tokens":12.0}}"#).reportedTotalTokens,
                     "an integral VALUE written as a floating-point literal is still a double, and "
                     + "a double cannot carry every Int64 exactly — accepting it opens a silent "
                     + "rounding path")
        XCTAssertNil(parse(#"{"usage":{"total_tokens":1e3}}"#).reportedTotalTokens)
    }

    func testNegativeNumberIsRejected() {
        XCTAssertNil(parse(#"{"usage":{"prompt_tokens":-5}}"#).reportedInputTokens)
    }

    func testOverflowIsRejected() {
        // Int64.max + 1, and a value beyond UInt64 entirely.
        XCTAssertNil(parse(#"{"usage":{"total_tokens":9223372036854775808}}"#).reportedTotalTokens)
        XCTAssertNil(parse(#"{"usage":{"total_tokens":18446744073709551616}}"#).reportedTotalTokens)
    }

    func testInt64MaxItselfSurvives() {
        XCTAssertEqual(parse(#"{"usage":{"total_tokens":9223372036854775807}}"#).reportedTotalTokens,
                       Int64.max)
    }

    func testNullAndWrongShapesAreRejected() {
        let metadata = parse("""
        {"usage":{"prompt_tokens":null,"completion_tokens":[7],"total_tokens":{"n":7}}}
        """)
        XCTAssertNil(metadata.reportedInputTokens)
        XCTAssertNil(metadata.reportedOutputTokens)
        XCTAssertNil(metadata.reportedTotalTokens)
    }

    func testUsageThatIsNotAnObjectYieldsNoCounts() {
        let metadata = parse(#"{"model":"m1","usage":42}"#)
        XCTAssertEqual(metadata.reportedModel, "m1")
        XCTAssertNil(metadata.reportedTotalTokens)
    }

    func testOneMalformedFieldNeverErasesItsValidSiblings() {
        let metadata = parse("""
        {"model":"m1","id":"r1",
         "usage":{"prompt_tokens":10,"completion_tokens":"nope","total_tokens":30}}
        """)
        XCTAssertEqual(metadata.reportedInputTokens, 10)
        XCTAssertNil(metadata.reportedOutputTokens)
        XCTAssertEqual(metadata.reportedTotalTokens, 30,
                       "per-field validation is the whole reason this is not a Codable struct — a "
                       + "unit decode would have thrown all six away")
        XCTAssertEqual(metadata.reportedModel, "m1")
        XCTAssertEqual(metadata.reportedResponseID, "r1")
    }

    func testInconsistentExplicitTotalIsPreservedNotRepaired() {
        let metadata = parse("""
        {"usage":{"prompt_tokens":10,"completion_tokens":10,"total_tokens":999}}
        """)
        XCTAssertEqual(metadata.reportedTotalTokens, 999,
                       "a gateway reporting a total that disagrees with its components is reporting "
                       + "something real — cached tokens, a tool hop — and repairing it here would "
                       + "replace a gateway fact with a client guess nothing could tell apart")
    }

    // MARK: - String bounding

    func testOverlongModelIsRejectedNotTruncated() {
        let long = String(repeating: "m", count: GatewayResponseMetadata.maxWireStringLength + 1)
        XCTAssertNil(parse(#"{"model":"\#(long)"}"#).reportedModel,
                     "a silently shortened id names a model that does not exist")
    }

    func testModelAtExactlyTheCapSurvives() {
        let atCap = String(repeating: "m", count: GatewayResponseMetadata.maxWireStringLength)
        XCTAssertEqual(parse(#"{"model":"\#(atCap)"}"#).reportedModel, atCap)
    }

    func testControlAndBidiCharactersAreRejectedPerFieldOnly() {
        let metadata = parse("""
        {"model":"good\\u0000model","id":"safe-id","choices":[{"finish_reason":"st\\u202Eop"}],
         "usage":{"total_tokens":7}}
        """)
        XCTAssertNil(metadata.reportedModel,
                     "a NUL hides behind its base character in a grapheme cluster, so the scan runs "
                     + "over unicodeScalars")
        XCTAssertNil(metadata.finishReason,
                     "a right-to-left override makes one value render as another")
        XCTAssertEqual(metadata.reportedResponseID, "safe-id",
                       "rejection is per field: a hostile model id must not cost the response id")
        XCTAssertEqual(metadata.reportedTotalTokens, 7)
    }

    func testEmptyStringIsTheSameAsAbsent() {
        let metadata = parse(#"{"model":"","id":""}"#)
        XCTAssertNil(metadata.reportedModel)
        XCTAssertNil(metadata.reportedResponseID)
        XCTAssertTrue(metadata.isEmpty)
    }

    func testNonASCIIModelIdsSurvive() {
        XCTAssertEqual(parse(#"{"model":"モデル-7"}"#).reportedModel, "モデル-7",
                       "the guard is a denylist of rendering-control scalars, not an allowlist of "
                       + "scripts")
    }

    // MARK: - Failure bodies

    func testNonSuccessBodyStillYieldsItsUsage() {
        let metadata = parse("""
        {"error":{"message":"upstream exploded","code":"upstream_failure","type":"server_error"},
         "model":"m1","usage":{"prompt_tokens":88,"total_tokens":88}}
        """)
        XCTAssertEqual(metadata.reportedInputTokens, 88,
                       "a gateway can bill for work it then failed to return, so a failed turn's "
                       + "usage is exactly as real as a successful one's")
        XCTAssertEqual(metadata.reportedModel, "m1")
        XCTAssertNil(metadata.reportedOutputTokens)
    }

    func testInvalidReplyBodyStillYieldsItsMetadata() {
        // The strict decoder rejects this (no `choices[].message.content`);
        // the observation survives independently for the terminal owner.
        let metadata = parse(#"{"model":"m1","choices":[],"usage":{"total_tokens":5}}"#)
        XCTAssertEqual(metadata.reportedModel, "m1")
        XCTAssertEqual(metadata.reportedTotalTokens, 5)
    }

    // MARK: - Value semantics

    func testEqualityIsByValue() {
        let a = parse(#"{"model":"m1","usage":{"total_tokens":3}}"#)
        let b = parse(#"{"usage":{"total_tokens":3},"model":"m1"}"#)
        XCTAssertEqual(a, b, "key order is not a fact about the turn")
    }
}
