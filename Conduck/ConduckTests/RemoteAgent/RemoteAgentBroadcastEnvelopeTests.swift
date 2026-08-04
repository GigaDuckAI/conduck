// SPDX-License-Identifier: Apache-2.0

// Conduck
// RemoteAgentBroadcastEnvelopeTests.swift
//
// Settings: Personal AI. Round-trip + tolerance tests for the
// `WCSession.transferUserInfo` envelope carrying Personal AI gateway
// state. Mirrors `STTBroadcastEnvelopeTests` shape — the envelopes share
// the same "plist-compatible dict + optional fields + monotonic
// timestamp" contract.

import XCTest
@testable import Conduck

final class RemoteAgentBroadcastEnvelopeTests: XCTestCase {

    // MARK: - Round-trip (full payload)

    func testEnvelopeFullRoundTrip() throws {
        let url = try XCTUnwrap(URL(string: "https://gateway.local:18789"))
        let original = RemoteAgentBroadcastEnvelope(
            backendRef: "openclaw",
            url: url,
            name: nil,
            model: nil,
            colorID: nil,
            monogram: nil,
            token: "bearer-test-token",
            certFingerprintHex: "deadbeef".padding(toLength: 64, withPad: "0", startingAt: 0),
            activeSessionID: "session-uuid-1",
            timestamp: 12345.6
        )

        let dict = original.encodedDict()
        let decoded = try XCTUnwrap(RemoteAgentBroadcastEnvelope.decode(from: dict))

        XCTAssertEqual(decoded.backendRef, original.backendRef)
        XCTAssertEqual(decoded.url, original.url)
        XCTAssertEqual(decoded.token, original.token)
        XCTAssertEqual(decoded.certFingerprintHex, original.certFingerprintHex)
        XCTAssertEqual(decoded.activeSessionID, original.activeSessionID)
        XCTAssertEqual(decoded.timestamp, original.timestamp, accuracy: 0.0001)
    }

    // MARK: - File-transfer availability (WS6b)

    /// `fileTransferAvailable` round-trips through the dict. The iPhone is the
    /// source of truth; the Watch reads it to know whether the bound gateway
    /// offers file transfer (always false-on-wrist — no upload/download UI).
    func testEnvelopeFileTransferAvailableRoundTrips() throws {
        let url = try XCTUnwrap(URL(string: "https://gateway.local:18789"))
        let original = RemoteAgentBroadcastEnvelope(
            backendRef: "openclaw", url: url, name: nil, model: nil, colorID: nil,
            monogram: nil, token: "t", certFingerprintHex: nil,
            fileTransferAvailable: true, activeSessionID: nil, timestamp: 1.0
        )
        let dict = original.encodedDict()
        XCTAssertEqual(dict["fileTransferAvailable"] as? Bool, true,
                       "encodedDict must always carry the file-transfer availability flag.")
        let decoded = try XCTUnwrap(RemoteAgentBroadcastEnvelope.decode(from: dict))
        XCTAssertTrue(decoded.fileTransferAvailable, "fileTransferAvailable must round-trip true.")
    }

    /// An un-upgraded iPhone broadcasts NO `fileTransferAvailable` key — the
    /// decoder defaults it to false rather than stranding the envelope.
    func testEnvelopeMissingFileTransferAvailableDefaultsFalse() throws {
        let dict: [String: Any] = [
            "backend": "openclaw",
            "url": "https://legacy.local",
            "timestamp": 5.0,
        ]
        let decoded = try XCTUnwrap(RemoteAgentBroadcastEnvelope.decode(from: dict))
        XCTAssertFalse(decoded.fileTransferAvailable,
                       "A dict missing the key must decode fileTransferAvailable as false (back-compat).")
    }

    // MARK: - File-lane identity courier

    /// The lane identity the wrist stamps onto its replies rides the envelope.
    /// Without it a Watch-originated turn is permanently ineligible for the
    /// retroactive output scan, so this key is the whole mechanism.
    func testEnvelopeFileTransferLaneIDRoundTrips() throws {
        let url = try XCTUnwrap(URL(string: "https://gateway.local:18789"))
        let laneID = String(repeating: "a1b2c3d4", count: 8)   // 64 lowercase hex
        let original = RemoteAgentBroadcastEnvelope(
            backendRef: "openclaw", url: url, name: nil, model: nil, colorID: nil,
            monogram: nil, token: "t", certFingerprintHex: nil,
            fileTransferAvailable: true, fileTransferLaneID: laneID,
            activeSessionID: nil, timestamp: 1.0
        )
        let dict = original.encodedDict()
        XCTAssertEqual(dict["fileTransferLaneID"] as? String, laneID,
                       "A ready lane must courier its durable identity on the wire.")
        let decoded = try XCTUnwrap(RemoteAgentBroadcastEnvelope.decode(from: dict))
        XCTAssertEqual(decoded.fileTransferLaneID, laneID,
                       "The lane identity must round-trip byte-exact — it is compared for equality.")
    }

    /// No ready lane → the key is ABSENT, not an empty-string sentinel: "key
    /// missing" is exactly what an un-upgraded sender produces, so both roads
    /// must decode to the same "no lane" answer.
    func testEnvelopeNilFileTransferLaneIDOmitsKey() throws {
        let url = try XCTUnwrap(URL(string: "https://gateway.local:18789"))
        let env = RemoteAgentBroadcastEnvelope(
            backendRef: "openclaw", url: url, name: nil, model: nil, colorID: nil,
            monogram: nil, token: "t", certFingerprintHex: nil,
            fileTransferAvailable: false, fileTransferLaneID: nil,
            activeSessionID: nil, timestamp: 1.0
        )
        XCTAssertNil(env.encodedDict()["fileTransferLaneID"],
                     "A laneless envelope must omit the key entirely (no empty-string sentinel).")
    }

    /// OLD iPhONE → NEW WATCH. A sender that predates the courier writes no
    /// `fileTransferLaneID` key; the envelope must still decode (readiness and
    /// every other field intact) with the lane simply absent. The wrist then
    /// behaves exactly as it did before the courier existed: instruction sent,
    /// reply unstamped, no scan — never a stranded envelope or a lost turn.
    func testEnvelopeMissingFileTransferLaneIDDecodesNil() throws {
        let dict: [String: Any] = [
            "backend": "openclaw",
            "url": "https://legacy.local",
            "timestamp": 5.0,
            "fileTransferAvailable": true,
        ]
        let decoded = try XCTUnwrap(RemoteAgentBroadcastEnvelope.decode(from: dict))
        XCTAssertNil(decoded.fileTransferLaneID,
                     "A dict missing the key must decode the lane as nil (back-compat).")
        XCTAssertTrue(decoded.fileTransferAvailable,
                      "The missing lane key must not disturb the readiness flag.")
    }

    /// NEW iPHONE → OLD WATCH is the mirror case, and it is safe for a
    /// structural reason: the decoder reads only the keys it knows, so an
    /// envelope carrying the new key still decodes on a build that has never
    /// heard of it. `testEnvelopeDecodeIgnoresUnknownKeys` locks that rule
    /// generally; this asserts it for THIS key by decoding a dict that also
    /// carries a future field alongside it.
    func testEnvelopeLaneIDSurvivesAlongsideUnknownFutureKeys() throws {
        let laneID = String(repeating: "f0", count: 32)
        let dict: [String: Any] = [
            "backend": "openclaw",
            "url": "https://gateway.local",
            "timestamp": 9.0,
            "fileTransferAvailable": true,
            "fileTransferLaneID": laneID,
            "somethingFromTheFuture": ["nested": 1],
        ]
        let decoded = try XCTUnwrap(RemoteAgentBroadcastEnvelope.decode(from: dict))
        XCTAssertEqual(decoded.fileTransferLaneID, laneID)
    }

    /// The id is an OPAQUE digest that is only ever compared for equality, so
    /// anything off-shape is already useless — rejecting it at the boundary
    /// bounds what a malformed or hostile payload can push into Watch
    /// `UserDefaults`, task metadata, and Core Data.
    func testEnvelopeMalformedLaneIDDecodesNil() throws {
        let malformed = [
            String(repeating: "a", count: 63),          // too short
            String(repeating: "a", count: 65),          // too long
            String(repeating: "A", count: 64),          // uppercase hex
            String(repeating: "z", count: 64),          // non-hex
            String(repeating: "\u{FF10}", count: 64),   // full-width digit look-alike
            "../../etc/passwd",                          // path-shaped
            "",                                          // empty
        ]
        for raw in malformed {
            let dict: [String: Any] = [
                "backend": "openclaw",
                "url": "https://gateway.local",
                "timestamp": 3.0,
                "fileTransferAvailable": true,
                "fileTransferLaneID": raw,
            ]
            let decoded = try XCTUnwrap(RemoteAgentBroadcastEnvelope.decode(from: dict))
            XCTAssertNil(decoded.fileTransferLaneID,
                         "An off-shape lane id must decode as no-lane, not be stored verbatim.")
            XCTAssertTrue(decoded.fileTransferAvailable,
                          "Rejecting the lane must not strand the envelope or its other fields.")
        }
    }

    /// Each sub-envelope carries ITS OWN ref's lane, so a wrist turn bound to
    /// gateway B can never be stamped with gateway A's lane.
    func testMultiEnvelopePerSubLaneIdentity() throws {
        let laneA = String(repeating: "ab", count: 32)
        let laneB = String(repeating: "cd", count: 32)
        func sub(_ ref: String, lane: String?) throws -> RemoteAgentBroadcastEnvelope {
            RemoteAgentBroadcastEnvelope(
                backendRef: ref,
                url: try XCTUnwrap(URL(string: "https://\(ref).example.test")),
                name: nil, model: nil, colorID: nil, monogram: nil, token: "t",
                certFingerprintHex: nil, fileTransferAvailable: lane != nil,
                fileTransferLaneID: lane, activeSessionID: nil, timestamp: 7.0
            )
        }
        let multi = RemoteAgentMultiBroadcastEnvelope(
            backends: [
                try sub("openclaw", lane: laneA),
                try sub("hermes", lane: laneB),
                try sub("custom_\(UUID().uuidString)", lane: nil),
            ],
            defaultBackendRef: "openclaw",
            timestamp: 7.0,
            sessionPolicy: nil
        )
        let decoded = try XCTUnwrap(
            RemoteAgentMultiBroadcastEnvelope.decode(from: multi.encodedDict())
        )
        XCTAssertEqual(decoded.backends.count, 3)
        XCTAssertEqual(decoded.backends[0].fileTransferLaneID, laneA)
        XCTAssertEqual(decoded.backends[1].fileTransferLaneID, laneB)
        XCTAssertNil(decoded.backends[2].fileTransferLaneID,
                     "A ref with no ready lane carries none — refs never borrow each other's.")
    }

    // MARK: - Optional-field round-trip (token nil)

    func testEnvelopeNilTokenOmitsKeyInDict() throws {
        let url = try XCTUnwrap(URL(string: "https://gateway.local:18789"))
        let env = RemoteAgentBroadcastEnvelope(
            backendRef: "openclaw",
            url: url,
            name: nil,
            model: nil,
            colorID: nil,
            monogram: nil,
            token: nil,
            certFingerprintHex: nil,
            activeSessionID: nil,
            timestamp: 1.0
        )
        let dict = env.encodedDict()
        XCTAssertNil(dict["token"],
                     "Nil-token envelopes must omit the `\"token\"` key entirely from the dict — matches STT empty-string-sentinel-avoidance.")
        XCTAssertNil(dict["name"], "Nil name must omit the `\"name\"` key (built-in).")
        XCTAssertNil(dict["model"], "Nil model must omit the `\"model\"` key (built-in / gateway default).")
        XCTAssertNil(dict["colorID"], "Nil colorID must omit the `\"colorID\"` key (built-in).")
        XCTAssertNil(dict["monogram"], "Nil monogram must omit the `\"monogram\"` key (built-in).")
        XCTAssertNil(dict["certFingerprintHex"])
        XCTAssertNil(dict["activeSessionID"])
        // Required fields still present. A built-in still serializes its EXACT
        // locked raw value under the `"backend"` key (back-compat).
        XCTAssertEqual(dict["backend"] as? String, "openclaw")
        XCTAssertEqual(dict["url"] as? String, "https://gateway.local:18789")
        XCTAssertEqual(dict["timestamp"] as? TimeInterval, 1.0)
    }

    func testEnvelopeNilTokenRoundTrips() throws {
        let url = try XCTUnwrap(URL(string: "https://gateway.local:8642"))
        let original = RemoteAgentBroadcastEnvelope(
            backendRef: "hermes",
            url: url,
            name: nil,
            model: nil,
            colorID: nil,
            monogram: nil,
            token: nil,
            certFingerprintHex: nil,
            activeSessionID: nil,
            timestamp: 42.5
        )
        let dict = original.encodedDict()
        let decoded = try XCTUnwrap(RemoteAgentBroadcastEnvelope.decode(from: dict))
        XCTAssertEqual(decoded.backendRef, "hermes")
        XCTAssertNil(decoded.token, "Round-tripped token must remain nil, NOT promote to empty string.")
        XCTAssertNil(decoded.certFingerprintHex)
        XCTAssertNil(decoded.activeSessionID)
    }

    // MARK: - Optional-field round-trip (fingerprint nil)

    func testEnvelopeNilFingerprintRoundTrips() throws {
        let url = try XCTUnwrap(URL(string: "https://gateway.example.test"))
        let original = RemoteAgentBroadcastEnvelope(
            backendRef: "openclaw",
            url: url,
            name: nil,
            model: nil,
            colorID: nil,
            monogram: nil,
            token: "tok",
            certFingerprintHex: nil,
            activeSessionID: "sess",
            timestamp: 99.9
        )
        let dict = original.encodedDict()
        let decoded = try XCTUnwrap(RemoteAgentBroadcastEnvelope.decode(from: dict))
        XCTAssertNil(decoded.certFingerprintHex,
                     "Nil fingerprint → ATS default trust posture; must NOT round-trip to empty string.")
        XCTAssertEqual(decoded.token, "tok")
        XCTAssertEqual(decoded.activeSessionID, "sess")
    }

    // MARK: - Defensive decoder (missing required fields)

    func testEnvelopeDecodeRejectsMissingFields() {
        XCTAssertNil(RemoteAgentBroadcastEnvelope.decode(from: [:]),
                     "Empty dict must yield nil — receiver treats as 'ignore envelope'.")
        XCTAssertNil(RemoteAgentBroadcastEnvelope.decode(from: ["backend": "openclaw"]),
                     "Missing url + timestamp must yield nil.")
        XCTAssertNil(RemoteAgentBroadcastEnvelope.decode(from: [
            "backend": "openclaw",
            "url": "https://x",
        ]), "Missing timestamp must yield nil even when backend + url present.")
        XCTAssertNil(RemoteAgentBroadcastEnvelope.decode(from: [
            "url": "https://x",
            "timestamp": 1.0,
        ]), "Missing backend must yield nil.")
    }

    func testEnvelopeDecodeAcceptsCustomRefString() throws {
        // Custom-gateways: the decoder no longer gates on
        // `RemoteAgentBackend(rawValue:)` — it accepts ANY non-empty ref string
        // (built-in OR "custom_<uuid>") so customs round-trip. The ref is parsed
        // downstream; an unparseable ref maps to `remoteAgentNotConfigured`, NOT
        // a decode failure that would strand the whole envelope.
        let customRef = "custom_\(UUID().uuidString.lowercased())"
        let dict: [String: Any] = [
            "backend": customRef,
            "url": "https://x",
            "timestamp": 1.0,
        ]
        let decoded = try XCTUnwrap(RemoteAgentBroadcastEnvelope.decode(from: dict),
                                    "A non-empty custom ref string MUST decode (customs round-trip the WCSession envelope).")
        XCTAssertEqual(decoded.backendRef, customRef)
    }

    func testEnvelopeDecodeRejectsEmptyBackendRef() {
        let dict: [String: Any] = [
            "backend": "",
            "url": "https://x",
            "timestamp": 1.0,
        ]
        XCTAssertNil(RemoteAgentBroadcastEnvelope.decode(from: dict),
                     "An EMPTY backendRef yields nil — the only ref gate the loosened decoder keeps.")
    }

    func testEnvelopeDecodeRejectsEmptyURL() {
        // `URL(string:)` returns nil for empty strings — the decoder
        // surfaces that as envelope-level nil rather than constructing
        // an invalid envelope. Whitespace-only / percent-encodable inputs
        // are accepted by URL(string:) on some SDK versions, so we test
        // only the strict empty-string rejection — the consumer
        // (RemoteAgentClient) is the ultimate validator on use.
        let dict: [String: Any] = [
            "backend": "openclaw",
            "url": "",
            "timestamp": 1.0,
        ]
        XCTAssertNil(RemoteAgentBroadcastEnvelope.decode(from: dict),
                     "Empty URL string yields nil — receiver MUST NOT crash on a missing URL.")
    }

    // MARK: - Forward-compat (unknown extra fields)

    func testEnvelopeDecodeIgnoresUnknownKeys() throws {
        let dict: [String: Any] = [
            "backend": "openclaw",
            "url": "https://gateway.local:18789",
            "timestamp": 1.0,
            "future_field_v2": "this should be ignored",
            "another_unknown": 42,
        ]
        let decoded = try XCTUnwrap(RemoteAgentBroadcastEnvelope.decode(from: dict),
                                    "Decoder MUST tolerate unknown extra keys — older Watch versions need to keep working when iPhone ships a newer schema.")
        XCTAssertEqual(decoded.backendRef, "openclaw")
        XCTAssertEqual(decoded.url.absoluteString, "https://gateway.local:18789")
        XCTAssertEqual(decoded.timestamp, 1.0)
    }

    // MARK: - Monotonic timestamp (receiver-side guard primitive)

    func testEnvelopeTimestampMonotonicOrdering() throws {
        let url = try XCTUnwrap(URL(string: "https://x"))
        let older = RemoteAgentBroadcastEnvelope(
            backendRef: "openclaw", url: url, name: nil, model: nil, colorID: nil,
            monogram: nil, token: nil,
            certFingerprintHex: nil, activeSessionID: nil, timestamp: 100.0
        )
        let newer = RemoteAgentBroadcastEnvelope(
            backendRef: "openclaw", url: url, name: nil, model: nil, colorID: nil,
            monogram: nil, token: nil,
            certFingerprintHex: nil, activeSessionID: nil, timestamp: 200.0
        )
        XCTAssertLessThan(older.timestamp, newer.timestamp,
                          "Watch uses `timestamp <= lastRemoteAgentEnvelopeTimestamp` to discard out-of-order drains; ordering primitive must work.")
    }

    // MARK: - Multi-gateway envelope

    /// Helper: a fully-populated per-ref sub-envelope, keyed by a ref string.
    private func makeSub(
        ref: String,
        urlString: String,
        token: String?,
        name: String? = nil,
        model: String? = nil,
        colorID: String? = nil,
        monogram: String? = nil,
        cert: String? = nil,
        session: String? = nil,
        timestamp: TimeInterval = 1.0
    ) throws -> RemoteAgentBroadcastEnvelope {
        let url = try XCTUnwrap(URL(string: urlString))
        return RemoteAgentBroadcastEnvelope(
            backendRef: ref,
            url: url,
            name: name,
            model: model,
            colorID: colorID,
            monogram: monogram,
            token: token,
            certFingerprintHex: cert,
            activeSessionID: session,
            timestamp: timestamp
        )
    }

    func testMultiEnvelopeArrayRoundTrip() throws {
        let openclaw = try makeSub(ref: "openclaw", urlString: "https://gw1.local:18789",
                                   token: "tok-openclaw",
                                   cert: "aa".padding(toLength: 64, withPad: "0", startingAt: 0),
                                   session: "sess-1")
        let hermes = try makeSub(ref: "hermes", urlString: "https://gw2.local:8642",
                                 token: "tok-hermes",
                                 cert: nil,
                                 session: "sess-1")
        let original = RemoteAgentMultiBroadcastEnvelope(
            backends: [openclaw, hermes],
            defaultBackendRef: "hermes",
            timestamp: 555.5,
            sessionPolicy: "minutes60"
        )

        let dict = original.encodedDict()
        // `backends` must encode as an array of per-ref dicts.
        let rawBackends = try XCTUnwrap(dict["backends"] as? [[String: Any]])
        XCTAssertEqual(rawBackends.count, 2)
        XCTAssertEqual(dict["defaultBackend"] as? String, "hermes")
        XCTAssertEqual(dict["timestamp"] as? TimeInterval, 555.5)
        XCTAssertEqual(dict["sessionPolicy"] as? String, "minutes60",
                       "Watch-effective session policy must encode for the courier.")

        let decoded = try XCTUnwrap(RemoteAgentMultiBroadcastEnvelope.decode(from: dict))
        XCTAssertEqual(decoded.defaultBackendRef, "hermes")
        XCTAssertEqual(decoded.timestamp, 555.5, accuracy: 0.0001)
        XCTAssertEqual(decoded.sessionPolicy, "minutes60")
        XCTAssertEqual(decoded.backends.count, 2)

        let dOpen = try XCTUnwrap(decoded.backends.first { $0.backendRef == "openclaw" })
        XCTAssertEqual(dOpen.url.absoluteString, "https://gw1.local:18789")
        XCTAssertEqual(dOpen.token, "tok-openclaw")
        XCTAssertEqual(dOpen.certFingerprintHex, openclaw.certFingerprintHex)
        XCTAssertEqual(dOpen.activeSessionID, "sess-1")

        let dHermes = try XCTUnwrap(decoded.backends.first { $0.backendRef == "hermes" })
        XCTAssertEqual(dHermes.url.absoluteString, "https://gw2.local:8642")
        XCTAssertEqual(dHermes.token, "tok-hermes")
        XCTAssertNil(dHermes.certFingerprintHex, "Nil cert must round-trip nil, not empty string.")
    }

    /// The WIDEST roster `SettingsManager.currentRemoteAgentMultiEnvelope()` can
    /// broadcast — every built-in plus a full custom-gateway roster (3 + 5 = 8
    /// refs today). Each sub-envelope must round-trip with its OWN url / token /
    /// model / name intact, and none may be dropped or collapsed onto a sibling.
    func testMultiEnvelopeRoundTripsFullGatewayRoster() throws {
        let builtins = try RemoteAgentBackend.allCases.enumerated().map { index, backend in
            try makeSub(ref: backend.rawValue,
                        urlString: "https://builtin\(index).local:1878\(index)",
                        token: "tok-\(backend.rawValue)",
                        model: "model-\(backend.rawValue)",
                        session: "sess-1")
        }
        let customs = try (0..<Constants.maxCustomGateways).map { index in
            try makeSub(ref: "custom_\(UUID().uuidString.lowercased())",
                        urlString: "https://custom\(index).local:90\(index)0",
                        token: "tok-custom-\(index)",
                        name: "Custom \(index)",
                        model: "model-custom-\(index)",
                        colorID: "slot\(index)",
                        monogram: "C\(index)",
                        session: "sess-1")
        }
        let all = builtins + customs
        let defaultRef = try XCTUnwrap(customs.first).backendRef

        let original = RemoteAgentMultiBroadcastEnvelope(
            backends: all,
            defaultBackendRef: defaultRef,
            timestamp: 777.0,
            sessionPolicy: "minutes30"
        )
        let dict = original.encodedDict()
        let rawBackends = try XCTUnwrap(dict["backends"] as? [[String: Any]])
        XCTAssertEqual(rawBackends.count, all.count, "Every sub-envelope must encode — none dropped.")

        let decoded = try XCTUnwrap(RemoteAgentMultiBroadcastEnvelope.decode(from: dict))
        XCTAssertEqual(decoded.backends.count, all.count)
        XCTAssertEqual(decoded.defaultBackendRef, defaultRef, "A custom default ref survives the wide roster.")
        XCTAssertEqual(decoded.sessionPolicy, "minutes30")
        XCTAssertEqual(Set(decoded.backends.map(\.backendRef)).count, all.count,
                       "Every ref stays distinct — no two sub-envelopes may collapse onto one.")

        for expected in all {
            let sub = try XCTUnwrap(decoded.backends.first { $0.backendRef == expected.backendRef },
                                    "Ref \(expected.backendRef) must survive the round-trip.")
            XCTAssertEqual(sub.url, expected.url)
            XCTAssertEqual(sub.token, expected.token)
            XCTAssertEqual(sub.model, expected.model)
            XCTAssertEqual(sub.name, expected.name)
            XCTAssertEqual(sub.colorID, expected.colorID)
            XCTAssertEqual(sub.monogram, expected.monogram)
            XCTAssertEqual(sub.activeSessionID, "sess-1")
        }
    }

    func testMultiEnvelopeOmittedOptionalSubFields() throws {
        // A sub-envelope with nil token/cert/session must omit those keys, and
        // the multi-envelope must still round-trip the survivors.
        let sub = try makeSub(ref: "openclaw", urlString: "https://gw.local:18789", token: nil)
        let original = RemoteAgentMultiBroadcastEnvelope(
            backends: [sub],
            defaultBackendRef: "openclaw",
            timestamp: 10.0,
            sessionPolicy: nil
        )
        let dict = original.encodedDict()
        let rawBackends = try XCTUnwrap(dict["backends"] as? [[String: Any]])
        let subDict = try XCTUnwrap(rawBackends.first)
        XCTAssertNil(subDict["token"])
        XCTAssertNil(subDict["certFingerprintHex"])
        XCTAssertNil(subDict["activeSessionID"])
        XCTAssertNil(dict["sessionPolicy"], "Nil sessionPolicy must omit the key (omit-nil posture).")

        let decoded = try XCTUnwrap(RemoteAgentMultiBroadcastEnvelope.decode(from: dict))
        let dSub = try XCTUnwrap(decoded.backends.first)
        XCTAssertNil(dSub.token)
        XCTAssertNil(decoded.sessionPolicy, "A missing sessionPolicy key must decode to nil (back-compat).")
        XCTAssertEqual(dSub.url.absoluteString, "https://gw.local:18789")
    }

    func testMultiEnvelopeSessionPolicyMissingDecodesNil() throws {
        // An OLD-iPhone envelope (no sessionPolicy key at all) must decode to a
        // nil sessionPolicy so an upgraded Watch keeps its prior cached value
        // instead of being stranded — the back-compat contract.
        let sub = try makeSub(ref: "openclaw", urlString: "https://gw.local:18789", token: "t")
        var dict = RemoteAgentMultiBroadcastEnvelope(
            backends: [sub], defaultBackendRef: "openclaw", timestamp: 9.0, sessionPolicy: "minutes15"
        ).encodedDict()
        XCTAssertEqual(dict["sessionPolicy"] as? String, "minutes15")
        dict.removeValue(forKey: "sessionPolicy")
        let decoded = try XCTUnwrap(RemoteAgentMultiBroadcastEnvelope.decode(from: dict))
        XCTAssertNil(decoded.sessionPolicy)
        XCTAssertEqual(decoded.defaultBackendRef, "openclaw")
    }

    func testMultiEnvelopeMonotonicTimestamp() throws {
        let sub = try makeSub(ref: "openclaw", urlString: "https://x", token: "t")
        let older = RemoteAgentMultiBroadcastEnvelope(backends: [sub], defaultBackendRef: "openclaw", timestamp: 100.0, sessionPolicy: nil)
        let newer = RemoteAgentMultiBroadcastEnvelope(backends: [sub], defaultBackendRef: "openclaw", timestamp: 200.0, sessionPolicy: nil)
        XCTAssertLessThan(older.timestamp, newer.timestamp,
                          "Watch shares the high-water mark across single + multi envelopes; ordering must work.")
    }

    func testMultiEnvelopeDecodeIgnoresUnknownKeys() throws {
        let sub = try makeSub(ref: "openclaw", urlString: "https://gw.local:18789", token: "t")
        var dict = RemoteAgentMultiBroadcastEnvelope(
            backends: [sub], defaultBackendRef: "openclaw", timestamp: 7.0, sessionPolicy: nil
        ).encodedDict()
        dict["future_field_v6"] = "ignore me"
        dict["another_unknown"] = [1, 2, 3]
        let decoded = try XCTUnwrap(RemoteAgentMultiBroadcastEnvelope.decode(from: dict),
                                    "Multi-envelope decoder MUST tolerate unknown extra keys (forward-compat).")
        XCTAssertEqual(decoded.backends.count, 1)
        XCTAssertEqual(decoded.defaultBackendRef, "openclaw")
    }

    func testMultiEnvelopeDecodeDropsMalformedSubDict() throws {
        // One good sub-dict + one malformed (missing timestamp) → the good one
        // survives, the bad one is dropped (forward-compat per-sub tolerance).
        let good = try makeSub(ref: "openclaw", urlString: "https://gw.local:18789", token: "t").encodedDict()
        let bad: [String: Any] = ["backend": "hermes", "url": "https://gw2"]  // no timestamp
        let dict: [String: Any] = [
            "backends": [good, bad],
            "defaultBackend": "openclaw",
            "timestamp": 3.0,
        ]
        let decoded = try XCTUnwrap(RemoteAgentMultiBroadcastEnvelope.decode(from: dict))
        XCTAssertEqual(decoded.backends.count, 1, "Malformed sub-dict dropped; valid one survives.")
        XCTAssertEqual(decoded.backends.first?.backendRef, "openclaw")
    }

    func testMultiEnvelopeDecodeRejectsMissingRequiredFields() {
        XCTAssertNil(RemoteAgentMultiBroadcastEnvelope.decode(from: [:]),
                     "Empty dict → nil (receiver ignores).")
        XCTAssertNil(RemoteAgentMultiBroadcastEnvelope.decode(from: [
            "backends": [[String: Any]](),
            "timestamp": 1.0,
        ]), "Missing defaultBackend → nil.")
        XCTAssertNil(RemoteAgentMultiBroadcastEnvelope.decode(from: [
            "backends": [[String: Any]](),
            "defaultBackend": "openclaw",
        ]), "Missing timestamp → nil.")
        XCTAssertNil(RemoteAgentMultiBroadcastEnvelope.decode(from: [
            "defaultBackend": "openclaw",
            "timestamp": 1.0,
        ]), "Missing backends array → nil.")
        XCTAssertNil(RemoteAgentMultiBroadcastEnvelope.decode(from: [
            "backends": [[String: Any]](),
            "defaultBackend": "",
            "timestamp": 1.0,
        ]), "EMPTY defaultBackendRef → nil (the only ref gate the loosened decoder keeps).")
    }

    func testMultiEnvelopeDecodeAcceptsCustomDefaultRef() throws {
        // Custom-gateways: a custom default ref ("custom_<uuid>") round-trips —
        // the decoder no longer gates `defaultBackend` on `RemoteAgentBackend`.
        let customRef = "custom_\(UUID().uuidString.lowercased())"
        let dict: [String: Any] = [
            "backends": [[String: Any]](),
            "defaultBackend": customRef,
            "timestamp": 1.0,
        ]
        let decoded = try XCTUnwrap(RemoteAgentMultiBroadcastEnvelope.decode(from: dict),
                                    "A custom default ref MUST decode (a custom can be the default gateway).")
        XCTAssertEqual(decoded.defaultBackendRef, customRef)
    }

    func testMultiEnvelopeEmptyBackendsEdge() throws {
        // An empty backends array is a VALID decode (receiver treats as
        // 'no configured backends', not a crash).
        let dict: [String: Any] = [
            "backends": [[String: Any]](),
            "defaultBackend": "openclaw",
            "timestamp": 1.0,
        ]
        let decoded = try XCTUnwrap(RemoteAgentMultiBroadcastEnvelope.decode(from: dict))
        XCTAssertTrue(decoded.backends.isEmpty)
        XCTAssertEqual(decoded.defaultBackendRef, "openclaw")
        XCTAssertNil(decoded.clearAll,
                     "An empty array on its own is NOT a teardown — only the explicit flag is.")
    }

    // MARK: - Teardown flag (`clearAll`)

    func testMultiEnvelopeClearAllRoundTrips() throws {
        let envelope = RemoteAgentMultiBroadcastEnvelope(
            backends: [],
            defaultBackendRef: "openclaw",
            timestamp: 42.0,
            sessionPolicy: nil,
            clearAll: true
        )
        let decoded = try XCTUnwrap(RemoteAgentMultiBroadcastEnvelope.decode(from: envelope.encodedDict()))
        XCTAssertEqual(decoded.clearAll, true)
        XCTAssertTrue(decoded.backends.isEmpty)
    }

    func testMultiEnvelopeOmitsClearAllKeyWhenNotTearingDown() throws {
        let envelope = RemoteAgentMultiBroadcastEnvelope(
            backends: [],
            defaultBackendRef: "openclaw",
            timestamp: 1.0,
            sessionPolicy: nil
        )
        XCTAssertNil(envelope.encodedDict()["clearAll"],
                     "Omit-nil posture: a normal envelope carries no teardown key at all, so an old Watch sees exactly what it saw before.")
    }

    func testMultiEnvelopeAllSubDictsMalformedIsNotATeardown() throws {
        // THE landmine this flag exists to defuse. `decode` drops malformed
        // sub-dicts for forward-compat, so a future per-backend schema an older
        // Watch cannot parse also decodes to `backends == []`. If emptiness meant
        // teardown, a compatibility gap would silently destroy credentials.
        let dict: [String: Any] = [
            "backends": [["totally": "unparseable"], ["also": "junk"]],
            "defaultBackend": "openclaw",
            "timestamp": 1.0,
        ]
        let decoded = try XCTUnwrap(RemoteAgentMultiBroadcastEnvelope.decode(from: dict))
        XCTAssertTrue(decoded.backends.isEmpty, "Every sub-dict was dropped as malformed.")
        XCTAssertNil(decoded.clearAll,
                     "A receiver must never read its OWN parse failure as an instruction to wipe the user's gateways.")
    }

    func testMultiEnvelopeClearAllAlongsideBackendsIsRefused() throws {
        // Self-contradictory sender ("destroy everything" + here are gateways).
        // Resolve to the NON-destructive reading.
        let sub = try makeSub(ref: "openclaw", urlString: "https://gw.example.test",
                              token: nil, cert: nil, session: nil)
        let dict: [String: Any] = [
            "backends": [sub.encodedDict()],
            "defaultBackend": "openclaw",
            "timestamp": 1.0,
            "clearAll": true,
        ]
        let decoded = try XCTUnwrap(RemoteAgentMultiBroadcastEnvelope.decode(from: dict))
        XCTAssertNil(decoded.clearAll)
        XCTAssertEqual(decoded.backends.count, 1)
    }

    // MARK: - legacy single envelope still decodes (compat)

    func testLegacySingleEnvelopeStillDecodesAlongsideMulti() throws {
        // An un-upgraded iPhone broadcasts ONLY the single envelope; an upgraded
        // Watch falls back to it. Confirm the single decoder is unaffected by the
        // multi-envelope addition.
        let dict: [String: Any] = [
            "backend": "hermes",
            "url": "https://legacy.local:8642",
            "token": "legacy-tok",
            "timestamp": 88.0,
        ]
        let decoded = try XCTUnwrap(RemoteAgentBroadcastEnvelope.decode(from: dict))
        XCTAssertEqual(decoded.backendRef, "hermes")
        XCTAssertEqual(decoded.url.absoluteString, "https://legacy.local:8642")
        XCTAssertEqual(decoded.token, "legacy-tok")
        XCTAssertEqual(decoded.timestamp, 88.0, accuracy: 0.0001)
    }
}
