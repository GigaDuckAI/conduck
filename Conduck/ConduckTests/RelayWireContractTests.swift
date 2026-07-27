// SPDX-License-Identifier: Apache-2.0

// Conduck
// RelayWireContractTests.swift
//
// Wire-contract pin, iOS SIDE ONLY.
// The relay `Wire` enum is deliberately DUPLICATED between the iOS
// coordinator (`Conduck/Services/AppleSpeechRelayCoordinator.swift`) and
// the Watch coordinator (`ConduckWatch Watch App/Services/
// AppleSpeechRelayCoordinator.swift`) — they share no source (synchronized-
// groups membership exceptions are non-functional, see the coordinator
// headers). A renamed literal on EITHER side silently breaks the relay
// with no compile error, so these tests pin the iOS enum to the RAW STRING
// values the wire contract specifies.
//
// SCOPE LIMIT (be honest about what this catches): the Watch target has NO
// test bundle, so a Watch-side `Wire` drift fails NOTHING here — only an
// iOS-side drift fails loudly. The Watch copy is verified by manual
// mirror-diff against these pinned literals until the planned
// shared-constants extraction at the
// next Watch↔iOS refactor makes the duplication impossible.
//
// Also asserts the reply-payload shapes byte-for-byte via
// `RelayReplyCache.CachedReply.payload(requestID:)` — the SINGLE payload
// site both fresh and cached replies are built from.
//
// PLATFORM GATE: `#if os(iOS)` (stricter than the usual `!os(watchOS)`)
// because `AppleSpeechRelayCoordinator` — and thus `Wire` — only exists
// when WatchConnectivity does, i.e. on iOS. A macOS test slice would not
// compile these references.

#if os(iOS)

import XCTest
@testable import Conduck

final class RelayWireContractTests: XCTestCase {

    private typealias Wire = AppleSpeechRelayCoordinator.Wire

    // MARK: - Literal pinning (the wire contract, raw strings on purpose)

    func testWireLiteralsMatchCrossTargetContract() {
        // Frozen literals — a legacy Watch build depends on every one of
        // these byte-for-byte.
        XCTAssertEqual(Wire.kindKey, "kind")
        XCTAssertEqual(Wire.kindValue, "apple-speech-relay")
        XCTAssertEqual(Wire.replyKind, "apple-speech-relay-reply")
        XCTAssertEqual(Wire.requestIDKey, "requestID")
        XCTAssertEqual(Wire.languageKey, "language")
        XCTAssertEqual(Wire.resultTextKey, "result.text")
        XCTAssertEqual(Wire.resultErrorCodeKey, "result.errorCode")
        XCTAssertEqual(Wire.providerIDKey, "providerID")
        // Relay audio + wake keys — mirrored on the Watch side.
        XCTAssertEqual(Wire.audioKey, "audio")
        XCTAssertEqual(Wire.wakeKind, "apple-speech-relay-wake")
        XCTAssertEqual(Wire.supportsMessageReplyKey, "replySendMessageOK")
    }

    func testSettingsPullKindMatchesCrossTargetContract() {
        // Settings-pull rides the existing "kind" dispatch
        // key but is NOT a Wire literal: it is homed in `Constants`, which
        // compiles into BOTH targets, so no manual Watch mirror exists to
        // drift. The Wire enums stay at exactly the 11 relay literals the
        // spec pins (asserted above) — do not grow them for this.
        XCTAssertEqual(Constants.settingsPullMessageKind, "settings-pull")
    }

    // MARK: - Reply payload round trip (success)

    func testSuccessReplyPayloadShape() {
        let payload = RelayReplyCache.CachedReply(text: "hello duck", errorCode: nil)
            .payload(requestID: "req-123")

        XCTAssertEqual(payload["kind"] as? String, "apple-speech-relay-reply")
        XCTAssertEqual(payload["requestID"] as? String, "req-123")
        XCTAssertEqual(payload["result.text"] as? String, "hello duck")
        XCTAssertNil(payload["result.errorCode"], "Success reply must not carry an error slot")
        XCTAssertEqual(
            payload.count, 3,
            "Success reply carries EXACTLY kind + requestID + result.text — extra keys are wire drift"
        )
    }

    // MARK: - Reply payload round trip (failure)

    func testErrorReplyPayloadShape() {
        // 18 = AppError.appleSpeechModelNotInstalled — the relay's most
        // user-visible failure code; any Int rides the same slot.
        let payload = RelayReplyCache.CachedReply(text: nil, errorCode: 18)
            .payload(requestID: "req-456")

        XCTAssertEqual(payload["kind"] as? String, "apple-speech-relay-reply")
        XCTAssertEqual(payload["requestID"] as? String, "req-456")
        XCTAssertEqual(payload["result.errorCode"] as? Int, 18)
        XCTAssertNil(payload["result.text"], "Error reply must not carry a text slot")
        XCTAssertEqual(
            payload.count, 3,
            "Error reply carries EXACTLY kind + requestID + result.errorCode — extra keys are wire drift"
        )
    }
}

#endif // os(iOS)
