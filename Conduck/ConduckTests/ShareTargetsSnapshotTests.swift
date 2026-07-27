// SPDX-License-Identifier: Apache-2.0

// Conduck
// ShareTargetsSnapshotTests.swift
//
// Share-Extension "Send to" picker contract `ShareTargetsSnapshot` (main-app writer
// ↔ appex reader): a full encode/decode round-trip, the TOLERANT decode (an empty /
// minimal snapshot default-fills + a malformed one → nil), the PINNED cross-process
// wire shape (ISO-8601 dates · frozen field names · `.sortedKeys` ordering), and a
// byte-identical-mirror guard that reads BOTH source files off disk and asserts the
// appex copy is identical to the canonical below their header blocks.
//
// Pure Foundation Codable + on-disk source reads — no Keychain, no signing, no store.
// Runs on any sim.

import XCTest
@testable import Conduck

final class ShareTargetsSnapshotTests: XCTestCase {

    // MARK: - Full round-trip

    func testEncodeDecodeRoundTripPreservesEveryField() throws {
        let convoID = UUID()
        let generated = Date(timeIntervalSince1970: 1_700_000_000)
        let lastActivity = Date(timeIntervalSince1970: 1_700_000_500)
        let original = ShareTargetsSnapshot(
            schemaVersion: 1,
            generatedAt: generated,
            gateways: [
                ShareTargetsSnapshot.Gateway(
                    ref: "openclaw",
                    displayName: "OpenClaw",
                    colorHex: "#3A86FF",
                    monogram: "OC",
                    configured: true
                ),
                ShareTargetsSnapshot.Gateway(
                    ref: "custom_55555555-5555-5555-5555-555555555555",
                    displayName: "Home Mac mini",
                    colorHex: "#FF006E",
                    monogram: "HM",
                    configured: false
                )
            ],
            recentConversations: [
                ShareTargetsSnapshot.RecentConversation(
                    id: convoID,
                    label: "Trip planning",
                    backendRef: "hermes",
                    lastActivityAt: lastActivity
                )
            ]
        )

        let data = try original.encoded()
        let decoded = try XCTUnwrap(ShareTargetsSnapshot.decode(data))

        XCTAssertEqual(decoded.schemaVersion, 1)
        XCTAssertEqual(decoded.generatedAt.timeIntervalSince1970, generated.timeIntervalSince1970, accuracy: 0.001)

        XCTAssertEqual(decoded.gateways.count, 2)
        let g0 = decoded.gateways[0]
        XCTAssertEqual(g0.ref, "openclaw")
        XCTAssertEqual(g0.displayName, "OpenClaw")
        XCTAssertEqual(g0.colorHex, "#3A86FF")
        XCTAssertEqual(g0.monogram, "OC")
        XCTAssertTrue(g0.configured)
        XCTAssertEqual(decoded.gateways[1].ref, "custom_55555555-5555-5555-5555-555555555555")
        XCTAssertFalse(decoded.gateways[1].configured)

        XCTAssertEqual(decoded.recentConversations.count, 1)
        let r0 = decoded.recentConversations[0]
        XCTAssertEqual(r0.id, convoID)
        XCTAssertEqual(r0.label, "Trip planning")
        XCTAssertEqual(r0.backendRef, "hermes")
        XCTAssertEqual(r0.lastActivityAt.timeIntervalSince1970, lastActivity.timeIntervalSince1970, accuracy: 0.001)
    }

    // MARK: - Tolerant decode (forward-compat)

    func testTolerantDecodeOfEmptySnapshotDefaultsToEmptyPicker() throws {
        // A snapshot with NO target arrays is a valid (empty) picker — every field
        // default-fills rather than throwing.
        let json = "{}"
        let decoded = try XCTUnwrap(ShareTargetsSnapshot.decode(Data(json.utf8)))
        XCTAssertEqual(decoded.schemaVersion, 1, "missing schemaVersion defaults to 1")
        XCTAssertEqual(decoded.gateways, [], "missing gateways defaults to empty")
        XCTAssertEqual(decoded.recentConversations, [], "missing recents defaults to empty")
    }

    func testTolerantGatewayDecodeDefaultsRenderFields() throws {
        // A gateway carrying only `ref` (the one required field) default-fills its
        // render values so a future schema addition can't break an old snapshot.
        let json = "{\"ref\":\"openclaw\"}"
        let decoded = try JSONDecoder().decode(ShareTargetsSnapshot.Gateway.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.ref, "openclaw")
        XCTAssertEqual(decoded.displayName, "")
        XCTAssertEqual(decoded.colorHex, "")
        XCTAssertEqual(decoded.monogram, "")
        XCTAssertFalse(decoded.configured)
    }

    func testTolerantRecentConversationDecodeDefaultsFields() throws {
        // A recent carrying only `id` (the one required field) default-fills the rest.
        let id = UUID()
        let json = "{\"id\":\"\(id.uuidString)\"}"
        let decoded = try JSONDecoder().decode(ShareTargetsSnapshot.RecentConversation.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.id, id)
        XCTAssertEqual(decoded.label, "")
        XCTAssertEqual(decoded.backendRef, "")
    }

    func testMalformedSnapshotDecodesToNil() {
        // A garbage payload returns nil via `decode(_:)` (the appex then falls back
        // to its default target) instead of throwing.
        XCTAssertNil(ShareTargetsSnapshot.decode(Data("not json".utf8)),
                     "a malformed snapshot must decode to nil, not throw")
    }

    func testTolerantDecodeIgnoresUnknownFutureFields() throws {
        // A snapshot written by a NEWER app carries fields this build doesn't know —
        // they must be ignored, not rejected.
        let json = """
        {"schemaVersion":2,"futureFlag":true,"gateways":[],"recentConversations":[]}
        """
        let decoded = try XCTUnwrap(ShareTargetsSnapshot.decode(Data(json.utf8)))
        XCTAssertEqual(decoded.schemaVersion, 2, "a future schemaVersion is recorded, not rejected")
    }

    // MARK: - Pinned cross-process wire contract (main-app writer ↔ appex reader)

    // The main app and the appex are SEPARATE binaries, each carrying a VERBATIM
    // MIRROR of this type (appex copy: `ConduckShareExtension/ShareTargetsSnapshot.swift`).
    // They only interoperate while `encoded()` keeps producing the bytes both sides
    // decode. This freezes the load-bearing properties of that wire shape so a drift
    // on EITHER copy (date strategy, a field rename, key ordering) is caught here
    // instead of silently emptying the picker on device. Uses the PINNED `encoded()`
    // / `decode(_:)` — NOT a bare coder like the round-trip tests above.
    func testPinnedWireContractFreezesDateStrategyAndFieldNames() throws {
        let snapshot = ShareTargetsSnapshot(
            schemaVersion: 1,
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            gateways: [
                ShareTargetsSnapshot.Gateway(
                    ref: "openclaw", displayName: "OpenClaw",
                    colorHex: "#3A86FF", monogram: "OC", configured: true
                )
            ],
            recentConversations: [
                ShareTargetsSnapshot.RecentConversation(
                    id: UUID(uuidString: "66666666-6666-6666-6666-666666666666")!,
                    label: "Trip planning", backendRef: "hermes",
                    lastActivityAt: Date(timeIntervalSince1970: 1_700_000_500)
                )
            ]
        )
        let wire = String(decoding: try snapshot.encoded(), as: UTF8.self)

        // 1. Dates are ISO-8601 (the documented cross-process hazard). Compute the
        //    expected string the same way Foundation's `.iso8601` strategy does, so the
        //    assertion pins the STRATEGY without hardcoding a brittle literal — switch
        //    to `.secondsSince1970` and `wire` carries a number, failing here.
        let expectedGeneratedISO = ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertTrue(wire.contains("\"generatedAt\":\"\(expectedGeneratedISO)\""),
                      "generatedAt must serialize ISO-8601 via the pinned coder — wire: \(wire)")
        let expectedActivityISO = ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: 1_700_000_500))
        XCTAssertTrue(wire.contains("\"lastActivityAt\":\"\(expectedActivityISO)\""),
                      "lastActivityAt must serialize ISO-8601 via the pinned coder — wire: \(wire)")

        // 2. Every field name is frozen — a rename on either mirror breaks decode.
        for key in ["\"schemaVersion\"", "\"generatedAt\"", "\"gateways\"", "\"recentConversations\"",
                    "\"ref\"", "\"displayName\"", "\"colorHex\"", "\"monogram\"", "\"configured\"",
                    "\"id\"", "\"label\"", "\"backendRef\"", "\"lastActivityAt\""] {
            XCTAssertTrue(wire.contains(key), "wire contract missing key \(key) — wire: \(wire)")
        }

        // 3. `.sortedKeys` → deterministic bytes. Top-level `gateways` precedes
        //    `recentConversations` precedes `schemaVersion` (alphabetical).
        let gatewaysAt = try XCTUnwrap(wire.range(of: "\"gateways\""))
        let recentsAt = try XCTUnwrap(wire.range(of: "\"recentConversations\""))
        let schemaAt = try XCTUnwrap(wire.range(of: "\"schemaVersion\""))
        XCTAssertTrue(gatewaysAt.lowerBound < recentsAt.lowerBound,
                      "top-level keys must be sorted (.sortedKeys) for deterministic wire bytes")
        XCTAssertTrue(recentsAt.lowerBound < schemaAt.lowerBound,
                      "top-level keys must be sorted (.sortedKeys) for deterministic wire bytes")
        // Nested gateway keys are sorted too: `colorHex` precedes `ref`.
        let colorHexAt = try XCTUnwrap(wire.range(of: "\"colorHex\""))
        let refAt = try XCTUnwrap(wire.range(of: "\"ref\""))
        XCTAssertTrue(colorHexAt.lowerBound < refAt.lowerBound,
                      "nested keys must be sorted (.sortedKeys) too")

        // 4. Full loop through the PINNED coders preserves every field.
        let back = try XCTUnwrap(ShareTargetsSnapshot.decode(try snapshot.encoded()))
        XCTAssertEqual(back.schemaVersion, 1)
        XCTAssertEqual(back.generatedAt.timeIntervalSince1970, snapshot.generatedAt.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(back.gateways.first?.ref, "openclaw")
        XCTAssertEqual(back.gateways.first?.colorHex, "#3A86FF")
        XCTAssertEqual(back.recentConversations.first?.backendRef, "hermes")
        XCTAssertEqual(back.recentConversations.first?.label, "Trip planning")
    }

    // MARK: - Byte-identical mirror guard

    // The appex compiles its OWN copy of this contract; the two files are byte-
    // identical below their header comments (only the leading `// …` header block
    // differs). This reads BOTH source files off disk and asserts the appex mirror
    // is identical to the canonical from the first `import Foundation` onward — so a
    // change made to only one side (which would silently break the cross-process
    // wire) fails the build here. Anchored on this test file's own on-disk location
    // (`#filePath`) → sibling source dirs.
    func testAppexMirrorIsByteIdenticalToCanonicalBelowHeader() throws {
        let testDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let projectDir = testDir.deletingLastPathComponent()  // …/Conduck (the Xcode-project subdir)
        let canonicalURL = projectDir
            .appendingPathComponent("Conduck/Models/ShareTargetsSnapshot.swift")
        let iosMirrorURL = projectDir
            .appendingPathComponent("ConduckShareExtension/ShareTargetsSnapshot.swift")
        let macMirrorURL = projectDir
            .appendingPathComponent("ConduckShareExtensionMac/ShareTargetsSnapshot.swift")

        let canonical = try String(contentsOf: canonicalURL, encoding: .utf8)
        let iosMirror = try String(contentsOf: iosMirrorURL, encoding: .utf8)
        let macMirror = try String(contentsOf: macMirrorURL, encoding: .utf8)

        XCTAssertEqual(bodyBelowHeader(of: canonical), bodyBelowHeader(of: iosMirror),
                       "iOS appex mirror has drifted from the canonical below the header — the cross-process wire is at risk")
        XCTAssertEqual(bodyBelowHeader(of: canonical), bodyBelowHeader(of: macMirror),
                       "macOS appex mirror has drifted from the canonical below the header — the cross-process wire is at risk")
    }

    /// The contract body — everything from the first `import Foundation` line onward.
    /// Strips each file's leading comment header (the ONLY part allowed to differ
    /// between canonical and mirror) so the remainder can be compared verbatim.
    private func bodyBelowHeader(of source: String) -> Substring {
        guard let range = source.range(of: "import Foundation") else { return source[...] }
        return source[range.lowerBound...]
    }
}

// Equatable conformances are needed only by the `XCTAssertEqual([], …)` assertions
// above. Kept in the test file so the production types stay minimal.
extension ShareTargetsSnapshot.Gateway: Equatable {
    public static func == (lhs: ShareTargetsSnapshot.Gateway, rhs: ShareTargetsSnapshot.Gateway) -> Bool {
        lhs.ref == rhs.ref
            && lhs.displayName == rhs.displayName
            && lhs.colorHex == rhs.colorHex
            && lhs.monogram == rhs.monogram
            && lhs.configured == rhs.configured
    }
}

extension ShareTargetsSnapshot.RecentConversation: Equatable {
    public static func == (lhs: ShareTargetsSnapshot.RecentConversation, rhs: ShareTargetsSnapshot.RecentConversation) -> Bool {
        lhs.id == rhs.id
            && lhs.label == rhs.label
            && lhs.backendRef == rhs.backendRef
            && lhs.lastActivityAt == rhs.lastActivityAt
    }
}
