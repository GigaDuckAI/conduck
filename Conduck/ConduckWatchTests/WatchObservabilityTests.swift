// SPDX-License-Identifier: Apache-2.0

// Conduck — watchOS observability spine tests.
//
// Covers the diagnostics primitives added with the Watch logging spine:
//   1. `WatchRecordingState.phaseKind` — the coarse phase label that drives the
//      state-transition chokepoint (and the guarantee it never surfaces the
//      `.error` message or `.waiting` Date).
//   2. `WatchLog.shortID` / `WatchLog.compose` — correlation-id truncation and
//      the metadata-only line format (the redaction contract).
import XCTest
@testable import ConduckWatch_Watch_App

@MainActor
final class WatchObservabilityTests: XCTestCase {

    // MARK: - State phase-kind (chokepoint guard logic)

    func testPhaseKindMapsEveryCase() {
        XCTAssertEqual(WatchRecordingState.idle.phaseKind, "idle")
        XCTAssertEqual(WatchRecordingState.arming.phaseKind, "arming")
        XCTAssertEqual(WatchRecordingState.recording.phaseKind, "recording")
        XCTAssertEqual(WatchRecordingState.uploading.phaseKind, "uploading")
        XCTAssertEqual(WatchRecordingState.waiting(startedAt: Date()).phaseKind, "waiting")
        XCTAssertEqual(WatchRecordingState.error(message: "boom").phaseKind, "error")
    }

    /// The chokepoint logs only when `oldKind != newKind`. A `.waiting`→`.waiting`
    /// re-assignment (deferred-relay occupancy) carries a different `Date` but the
    /// SAME phase label, so it must compare equal → no spurious log.
    func testSamePhaseDifferentPayloadIsEqualKind() {
        let a = WatchRecordingState.waiting(startedAt: Date())
        let b = WatchRecordingState.waiting(startedAt: Date().addingTimeInterval(5))
        XCTAssertEqual(a.phaseKind, b.phaseKind)

        let e1 = WatchRecordingState.error(message: "x")
        let e2 = WatchRecordingState.error(message: "y")
        XCTAssertEqual(e1.phaseKind, e2.phaseKind)
    }

    func testDistinctPhasesDiffer() {
        XCTAssertNotEqual(WatchRecordingState.idle.phaseKind,
                          WatchRecordingState.recording.phaseKind)
    }

    /// The phase label must NEVER embed the `.error` message text.
    func testPhaseKindNeverLeaksErrorMessage() {
        let secret = "user-private-transcript-fragment"
        XCTAssertFalse(WatchRecordingState.error(message: secret).phaseKind.contains("user-private"))
        XCTAssertEqual(WatchRecordingState.error(message: secret).phaseKind, "error")
    }

    // MARK: - WatchLog redaction / format

    func testShortIDTruncatesAndNeverExposesFullUUID() {
        let id = UUID()
        let short = WatchLog.shortID(id)
        XCTAssertEqual(short.count, 8)
        XCTAssertTrue(id.uuidString.hasPrefix(short))
        XCTAssertNotEqual(short, id.uuidString, "shortID must never be the full identifier")
    }

    func testComposeFormatsVettedFieldsInOrder() {
        XCTAssertEqual(
            WatchLog.compose("stt.http", ["status": 200, "respBytes": 512]),
            "stt.http status=200 respBytes=512"
        )
        XCTAssertEqual(
            WatchLog.compose("converse.send", ["turn": "ab12cd34", "priorTurns": 3]),
            "converse.send turn=ab12cd34 priorTurns=3"
        )
    }

    func testComposeWithNoFieldsIsBareEvent() {
        XCTAssertEqual(WatchLog.compose("thread.autostart", [:]), "thread.autostart")
    }
}

// MARK: - Transport-failure copy classifier

/// Pins the honest connectivity-message mapping (the watchOS companion-routing
/// trap: a nearby powered-on iPhone with no internet sinks the Watch's own
/// request, and there is no API bypass — so the only remedy is truthful copy).
/// Verifies the three truth constraints: -1009 alone gets the iPhone-aware hedge,
/// other connectivity codes get a generic hint, and any non-connectivity error
/// (incl. the deliberately-excluded DNS codes) passes the caller's fallback
/// through untouched so the hint never fires on a real gateway error.
final class WatchNetworkFailureCopyTests: XCTestCase {

    private let fallback = "FALLBACK-SENTINEL"
    private let genericHint = "Couldn't reach the internet. Check your connection and try again."

    func testNotConnectedToInternetReturnsHedgedIPhoneHint() {
        let msg = WatchNetworkFailureCopy.transportFailureMessage(
            for: URLError(.notConnectedToInternet), fallback: fallback)
        XCTAssertNotEqual(msg, fallback)
        XCTAssertNotEqual(msg, genericHint)
        // Hedged + names the workaround, never asserts the iPhone IS the cause.
        XCTAssertTrue(msg.contains("iPhone"))
        XCTAssertTrue(msg.contains("may be"))
        XCTAssertTrue(msg.contains("Wi-Fi"))
        XCTAssertFalse(msg.contains("personal AI"))
    }

    func testGenericConnectivityCodesReturnBroadHint() {
        for code in [URLError.Code.timedOut, .cannotConnectToHost, .networkConnectionLost] {
            let msg = WatchNetworkFailureCopy.transportFailureMessage(
                for: URLError(code), fallback: fallback)
            XCTAssertEqual(msg, genericHint, "code \(code.rawValue) should map to the generic hint")
            XCTAssertFalse(msg.contains("iPhone"), "broad hint must not point at the iPhone")
        }
    }

    func testNonConnectivityAndExcludedDNSPassThroughFallback() {
        // Excluded by design: DNS codes (-1003/-1006) are false-positive prone.
        XCTAssertEqual(
            WatchNetworkFailureCopy.transportFailureMessage(for: URLError(.cannotFindHost), fallback: fallback),
            fallback)
        XCTAssertEqual(
            WatchNetworkFailureCopy.transportFailureMessage(for: URLError(.dnsLookupFailed), fallback: fallback),
            fallback)
        // A cross-launch cancel and a non-URLError must not trip the hint either.
        XCTAssertEqual(
            WatchNetworkFailureCopy.transportFailureMessage(for: URLError(.cancelled), fallback: fallback),
            fallback)
        XCTAssertEqual(
            WatchNetworkFailureCopy.transportFailureMessage(for: NSError(domain: "Test", code: 42), fallback: fallback),
            fallback)
    }
}
