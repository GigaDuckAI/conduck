// ConduckWatchTests
// WatchDiagnosticsReporterTests.swift
//
// Wire-shape coverage for the Watch side of the iPhone → Watch
// `diagnostics-pull` health query: the pure `makeReply` core must stamp the
// schema version (the phone rejects a version-less reply as "unsupported"),
// carry every fact under its locked key, and stay plist-clean (WCSession
// rejects non-plist payloads at send time — a regression here would silently
// break the round trip). Pure — no live session, no permissions.

import XCTest
@testable import ConduckWatch_Watch_App

@MainActor
final class WatchDiagnosticsReporterTests: XCTestCase {

    private func makeReply(queueDepth: Int = 2) -> [String: Any] {
        WatchDiagnosticsReporter.makeReply(
            appVersion: "1.0",
            appBuild: "42",
            osVersion: "26.5.0",
            sttEnvelopeTs: 1234.5,
            agentEnvelopeTs: 6789.0,
            relayQueueDepth: queueDepth,
            micPermission: "granted",
            notificationPermission: "authorized",
            companionReachable: true
        )
    }

    /// Every locked key is present with its typed value — and `diag.v` carries
    /// the schema version (load-bearing: the phone's accept gate).
    func testMakeReplyShape() {
        typealias Key = Constants.WatchDiagnosticsReplyKey
        let reply = makeReply()

        XCTAssertEqual(reply[Key.version] as? Int, Key.schemaVersion)
        XCTAssertEqual(reply[Key.appVersion] as? String, "1.0")
        XCTAssertEqual(reply[Key.appBuild] as? String, "42")
        XCTAssertEqual(reply[Key.osVersion] as? String, "26.5.0")
        XCTAssertEqual(reply[Key.sttEnvelopeTs] as? Double, 1234.5)
        XCTAssertEqual(reply[Key.agentEnvelopeTs] as? Double, 6789.0)
        XCTAssertEqual(reply[Key.relayQueueDepth] as? Int, 2)
        XCTAssertEqual(reply[Key.micPermission] as? String, "granted")
        XCTAssertEqual(reply[Key.notificationPermission] as? String, "authorized")
        XCTAssertEqual(reply[Key.companionReachable] as? Bool, true)
        XCTAssertEqual(reply.count, 10, "exactly the ten locked keys — nothing extra rides the wire")
    }

    /// The payload must serialize as a binary plist — WCSession's send-time
    /// contract; a non-plist value (URL, Date in the wrong spot, custom type)
    /// would throw at send and read as a silent no-reply on the phone.
    func testMakeReplyIsPlistClean() {
        let reply = makeReply()
        XCTAssertNoThrow(
            try PropertyListSerialization.data(fromPropertyList: reply, format: .binary, options: 0),
            "the reply must be plist-serializable end-to-end"
        )
    }

    /// Relay queue depth threads through verbatim (the phone renders
    /// "N recordings waiting" from it).
    func testQueueDepthPassthrough() {
        typealias Key = Constants.WatchDiagnosticsReplyKey
        XCTAssertEqual(makeReply(queueDepth: 0)[Key.relayQueueDepth] as? Int, 0)
        XCTAssertEqual(makeReply(queueDepth: 7)[Key.relayQueueDepth] as? Int, 7)
    }

    /// Permission enum-name mappings stay the allowlisted primitives the phone
    /// (and the copy block) expect.
    func testPermissionNameMappings() {
        XCTAssertEqual(WatchDiagnosticsReporter.micPermissionName(.granted), "granted")
        XCTAssertEqual(WatchDiagnosticsReporter.micPermissionName(.denied), "denied")
        XCTAssertEqual(WatchDiagnosticsReporter.micPermissionName(.undetermined), "undetermined")
        XCTAssertEqual(WatchDiagnosticsReporter.notificationStatusName(.authorized), "authorized")
        XCTAssertEqual(WatchDiagnosticsReporter.notificationStatusName(.denied), "denied")
        XCTAssertEqual(WatchDiagnosticsReporter.notificationStatusName(.notDetermined), "notDetermined")
        XCTAssertEqual(WatchDiagnosticsReporter.notificationStatusName(.provisional), "provisional")
    }

    /// The one-shot reply wrapper delivers exactly once — the responder has a
    /// synchronous unknown-kind branch AND an async gather branch, so "at most
    /// one send wins" must be a hard guarantee, not a code-path promise.
    func testOneShotReplyDeliversExactlyOnce() {
        nonisolated(unsafe) var deliveries: [[String: Any]] = []
        let reply = WatchOneShotReply { payload in
            deliveries.append(payload)
        }
        reply.send(["first": 1])
        reply.send(["second": 2])
        reply.send([:])
        XCTAssertEqual(deliveries.count, 1, "only the first send may deliver")
        XCTAssertEqual(deliveries.first?["first"] as? Int, 1)
    }
}
