// SPDX-License-Identifier: Apache-2.0

// Conduck
// GatewayBadgeVisibilityTests.swift
//
// Custom-gateways. Coverage for `RemoteAgentRefMetadata.shouldShowBadges` — the
// ONE rule deciding whether a conversation list renders per-row gateway badges,
// shared by the iPhone sheet, the iPad + macOS sidebars, CarPlay's Recent
// section, and the Watch list.
//
// The regression these pin: the rule used to be `configuredRefs.count >= 2`,
// which asks about SETTINGS when the list's question is about HISTORY. A user
// whose chats span four gateways but who has since forgotten three of them was
// left with one live gateway, a closed gate, and a list of visually identical
// rows — the exact moment the badge is most needed. `testForgottenBuiltIn…`
// below is that case.
//
// Pure static func over supplied snapshots — no signing, no App Group, no
// Keychain, no store.

import XCTest
@testable import Conduck

final class GatewayBadgeVisibilityTests: XCTestCase {

    // MARK: - Fixtures

    private let openclaw = RemoteAgentRef.builtin(.openclaw)
    private let hermes = RemoteAgentRef.builtin(.hermes)
    private let openrouter = RemoteAgentRef.builtin(.openrouter)

    private func custom(
        _ name: String,
        colorID: String = "indigo",
        monogram: String? = nil
    ) -> CustomGateway {
        CustomGateway(id: UUID(), name: name, model: nil, colorID: colorID, monogram: monogram)
    }

    private func shows(
        configured: [RemoteAgentRef] = [],
        history: [String] = [],
        customs: [CustomGateway] = []
    ) -> Bool {
        RemoteAgentRefMetadata.shouldShowBadges(
            configured: configured,
            conversationBackends: history,
            customs: customs
        )
    }

    // MARK: - The configured set alone

    func testNoGatewaysAndNoHistoryShowsNothing() {
        XCTAssertFalse(shows(),
                       "Nothing configured and nothing in the list: there is no identity to distinguish.")
    }

    func testSingleConfiguredGatewayShowsNothing() {
        XCTAssertFalse(shows(configured: [openclaw]),
                       "One gateway means an identical colored dot on every row — chrome with no information.")
    }

    func testTwoConfiguredGatewaysShowBadgesEvenWithEmptyHistory() {
        XCTAssertTrue(shows(configured: [openclaw, hermes]),
                      "A second gateway is configured, so the very next chat can differ — badge from the start.")
    }

    func testSameGatewayRepeatedIsStillOneIdentity() {
        XCTAssertFalse(shows(configured: [openclaw, openclaw], history: ["openclaw", "openclaw"]),
                       "Duplicates collapse: the count is of DISTINCT identities.")
    }

    // MARK: - History carries identities the settings no longer do

    func testForgottenBuiltInInHistoryStillCounts() {
        // THE bug this rule exists for. One gateway left configured, but the
        // list still holds chats from three others. A built-in keeps its
        // monogram + color for free (compiled into the enum), so those rows can
        // still render a badge — and must.
        XCTAssertTrue(
            shows(configured: [openclaw], history: ["hermes", "openrouter", "openclaw"]),
            "Forgetting a gateway does not merge its chats with the rest — the list still spans four identities."
        )
    }

    func testHistoryAloneWithNothingConfiguredStillCounts() {
        XCTAssertTrue(shows(configured: [], history: ["openclaw", "hermes"]),
                      "Forgetting the LAST gateway must not blank a mixed history.")
    }

    func testSingleGatewayHistoryShowsNothing() {
        XCTAssertFalse(shows(configured: [openclaw], history: ["openclaw", "openclaw", "openclaw"]),
                       "A one-gateway user with a long history still gets a badge-free list.")
    }

    // MARK: - Only refs that can actually RENDER count

    func testUnresolvableCustomInHistoryDoesNotCount() {
        // A custom whose roster entry is gone (forgotten / not-yet-synced)
        // resolves to an empty monogram, and `GatewayBadge` renders `EmptyView`
        // for it. Counting it would switch badges on for a list that then shows
        // ONE badge beside a blank gap — worse than showing none.
        let ghost = RemoteAgentRef.custom(UUID()).rawString
        XCTAssertFalse(
            shows(configured: [openclaw], history: ["openclaw", ghost], customs: []),
            "An unresolvable custom renders nothing, so it must not be what tips the count to two."
        )
    }

    func testResolvableCustomInHistoryDoesCount() {
        let gateway = custom("LiteLLM")
        XCTAssertTrue(
            shows(configured: [openclaw], history: ["openclaw", gateway.ref.rawString], customs: [gateway]),
            "A custom present in the roster resolves to a monogram, so it is a second identity."
        )
    }

    func testUnparseableBackendStringIsIgnored() {
        XCTAssertFalse(
            shows(configured: [openclaw], history: ["openclaw", "", "not-a-gateway", "custom_not-a-uuid"]),
            "Garbage / empty `backend` values are not identities."
        )
    }

    // MARK: - Dedup is by REF, never by monogram

    func testTwoCustomsSharingAMonogramAreStillTwoIdentities() {
        // Both derive "AI". They are two gateways with two colors, and the list
        // must badge — dedup on the monogram string would wrongly collapse them.
        let first = custom("AI box", colorID: "indigo")
        let second = custom("AIrelay", colorID: "pink")
        XCTAssertEqual(
            RemoteAgentRefMetadata.monogram(for: first.ref, customs: [first, second]),
            RemoteAgentRefMetadata.monogram(for: second.ref, customs: [first, second]),
            "Fixture precondition: these two must genuinely share a monogram."
        )
        XCTAssertTrue(
            shows(configured: [first.ref, second.ref], customs: [first, second]),
            "Same letters, different gateways, different colors — two identities."
        )
    }

    // MARK: - The configured set and the history are unioned, not compared

    func testOneConfiguredPlusOneDifferentInHistoryCounts() {
        let gateway = custom("LiteLLM")
        XCTAssertTrue(
            shows(configured: [gateway.ref], history: ["hermes"], customs: [gateway]),
            "The live gateway and the forgotten one are two identities even though neither set alone has two."
        )
    }
}
