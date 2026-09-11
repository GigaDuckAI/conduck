// SPDX-License-Identifier: Apache-2.0

// Conduck
// ShareTargetFilterTests.swift
//
// Pure-logic coverage for `ShareTargetFilter` — the Share Extension destination
// list's search/threshold/visibility helper and the two snapshot adapters the
// sheet's floor depends on (all held outside `ShareView` so they are testable
// without SwiftUI). Asserts the search-visibility boundary (8 → no field, 9 →
// field), the gateway/recent filters' empty-query passthrough + case-insensitive
// match + no-match → empty contract, and the two destination-list rules: when the
// legacy "New conversation" row is offered, and when a decoded-but-empty roster
// is TOLD instead. Then the preselection rule and the `preselectedTarget` adapter
// over it — which row opens highlighted, given the app's published default and
// the roster the snapshot carries — and `sendLabel`, which decides what the Send
// button names and when it can only say "Send now".
//
// `ShareTargetFilter.swift` physically lives in `ConduckShareExtensionMac/` (the
// appex consumes it) but is ALSO compiled into this test bundle, where
// `@testable import Conduck` resolves `ShareTargetsSnapshot.Gateway`/
// `.RecentConversation` to the main-app mirror — structurally identical to the
// appex copy, so the same source builds in both modules. Pure Foundation: no
// Keychain, no signing, no store. Runs on any sim / headless.

import XCTest
@testable import Conduck

final class ShareTargetFilterTests: XCTestCase {

    // MARK: - Fixtures

    private func gateway(
        _ name: String,
        ref: String = "openclaw",
        configured: Bool = true
    ) -> ShareTargetsSnapshot.Gateway {
        ShareTargetsSnapshot.Gateway(
            ref: ref,
            displayName: name,
            colorHex: "#3A86FF",
            monogram: String(name.prefix(2)).uppercased(),
            configured: configured
        )
    }

    private func recent(
        _ label: String,
        id: UUID = UUID()
    ) -> ShareTargetsSnapshot.RecentConversation {
        ShareTargetsSnapshot.RecentConversation(
            id: id,
            label: label,
            backendRef: "hermes",
            lastActivityAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    private func snapshot(
        gateways: [ShareTargetsSnapshot.Gateway] = [],
        recents: [ShareTargetsSnapshot.RecentConversation] = [],
        defaultGatewayRef: String? = nil
    ) -> ShareTargetsSnapshot {
        ShareTargetsSnapshot(
            schemaVersion: 2,
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            gateways: gateways,
            recentConversations: recents,
            defaultGatewayRef: defaultGatewayRef
        )
    }

    // MARK: - shouldShowSearch boundary

    func testShouldShowSearchIsFalseAtEightTotal() {
        // 8 total (5 gateways + 3 recents) → no search field.
        XCTAssertFalse(ShareTargetFilter.shouldShowSearch(gatewayCount: 5, recentCount: 3))
        // Exactly on the boundary from the other split too.
        XCTAssertFalse(ShareTargetFilter.shouldShowSearch(gatewayCount: 8, recentCount: 0))
        XCTAssertFalse(ShareTargetFilter.shouldShowSearch(gatewayCount: 0, recentCount: 0))
    }

    func testShouldShowSearchIsTrueAboveEightTotal() {
        // 9 total → search field appears.
        XCTAssertTrue(ShareTargetFilter.shouldShowSearch(gatewayCount: 6, recentCount: 3))
        XCTAssertTrue(ShareTargetFilter.shouldShowSearch(gatewayCount: 9, recentCount: 0))
        XCTAssertTrue(ShareTargetFilter.shouldShowSearch(gatewayCount: 0, recentCount: 9))
    }

    // MARK: - filterGateways

    func testFilterGatewaysEmptyQueryPassesThrough() {
        let list = [gateway("OpenClaw"), gateway("Hermes"), gateway("Home Mac mini")]
        XCTAssertEqual(ShareTargetFilter.filterGateways(list, query: "").map(\.displayName),
                       list.map(\.displayName))
        // Whitespace-only is also treated as empty (passthrough).
        XCTAssertEqual(ShareTargetFilter.filterGateways(list, query: "   ").map(\.displayName),
                       list.map(\.displayName))
    }

    func testFilterGatewaysCaseInsensitiveMatch() {
        let list = [gateway("OpenClaw"), gateway("Hermes"), gateway("Home Mac mini")]
        let matched = ShareTargetFilter.filterGateways(list, query: "hermes")
        XCTAssertEqual(matched.map(\.displayName), ["Hermes"])
        // Substring + mixed case both hit.
        let substring = ShareTargetFilter.filterGateways(list, query: "MAC")
        XCTAssertEqual(substring.map(\.displayName), ["Home Mac mini"])
    }

    func testFilterGatewaysNoMatchReturnsEmpty() {
        let list = [gateway("OpenClaw"), gateway("Hermes")]
        XCTAssertTrue(ShareTargetFilter.filterGateways(list, query: "zzz").isEmpty)
    }

    // MARK: - filterRecents

    func testFilterRecentsEmptyQueryPassesThrough() {
        let list = [recent("Trip planning"), recent("Grocery list"), recent("Standup notes")]
        XCTAssertEqual(ShareTargetFilter.filterRecents(list, query: "").map(\.label),
                       list.map(\.label))
        XCTAssertEqual(ShareTargetFilter.filterRecents(list, query: "\t\n").map(\.label),
                       list.map(\.label))
    }

    func testFilterRecentsCaseInsensitiveMatch() {
        let list = [recent("Trip planning"), recent("Grocery list"), recent("Standup notes")]
        let matched = ShareTargetFilter.filterRecents(list, query: "GROCERY")
        XCTAssertEqual(matched.map(\.label), ["Grocery list"])
        let substring = ShareTargetFilter.filterRecents(list, query: "plan")
        XCTAssertEqual(substring.map(\.label), ["Trip planning"])
    }

    func testFilterRecentsNoMatchReturnsEmpty() {
        let list = [recent("Trip planning"), recent("Grocery list")]
        XCTAssertTrue(ShareTargetFilter.filterRecents(list, query: "xyz").isEmpty)
    }

    // MARK: - Destination-list rules

    func testTheLegacyRowShowsOnlyWhenNoSnapshotDecoded() {
        // No snapshot decoded → the roster is UNKNOWN, not empty (the app may hold
        // a gateway the appex cannot see), so the legacy route stays on offer.
        XCTAssertTrue(ShareTargetFilter.showsLegacyNewConversationRow(snapshotDecoded: false))
        // A decoded snapshot names the roster, so the guessing row goes.
        XCTAssertFalse(ShareTargetFilter.showsLegacyNewConversationRow(snapshotDecoded: true))
    }

    func testTheNoAILineShowsOnlyForADecodedEmptyRoster() {
        // Decoded + nothing to send to → tell the person. Add to Work is a button
        // on the sheet's floor, outside this rule, so the line never leaves the
        // share with nowhere to go.
        XCTAssertTrue(ShareTargetFilter.showsNoAILine(snapshotDecoded: true,
                                                      gatewayCount: 0, recentCount: 0))
        // Undecoded is not empty — the legacy row covers that case instead.
        XCTAssertFalse(ShareTargetFilter.showsNoAILine(snapshotDecoded: false,
                                                       gatewayCount: 0, recentCount: 0))
        // Either list carrying a row means there IS something to send to.
        XCTAssertFalse(ShareTargetFilter.showsNoAILine(snapshotDecoded: true,
                                                       gatewayCount: 1, recentCount: 0))
        XCTAssertFalse(ShareTargetFilter.showsNoAILine(snapshotDecoded: true,
                                                       gatewayCount: 0, recentCount: 1))
    }

    // MARK: - Preselected route

    func testNoSnapshotPreselectsNothing() {
        // Undecoded means the roster is UNKNOWN, not empty: the app may hold a
        // gateway this sheet cannot see, and the only row on offer is the legacy
        // one, which the drainer may resolve to a conversation the sheet never
        // named. Nothing is picked for the person — even when a default and a
        // roster are handed in.
        XCTAssertEqual(
            ShareTargetFilter.preselectedRoute(
                snapshotDecoded: false,
                defaultGatewayRef: "hermes",
                configuredGatewayRefs: ["openclaw", "hermes"]
            ),
            .none
        )
    }

    func testTheAppsDefaultIsPreselectedWhenItIsListed() {
        // The published default wins over the roster's first entry — that is the
        // whole point of publishing it.
        XCTAssertEqual(
            ShareTargetFilter.preselectedRoute(
                snapshotDecoded: true,
                defaultGatewayRef: "openclaw",
                configuredGatewayRefs: ["openclaw", "hermes"]
            ),
            .gateway(ref: "openclaw")
        )
        // Including when it is not first, which is the case the fallback would
        // silently get wrong.
        XCTAssertEqual(
            ShareTargetFilter.preselectedRoute(
                snapshotDecoded: true,
                defaultGatewayRef: "hermes",
                configuredGatewayRefs: ["openclaw", "hermes", "custom_11111111-1111-1111-1111-111111111111"]
            ),
            .gateway(ref: "hermes")
        )
    }

    func testTheFirstGatewayIsPreselectedWithNoUsableDefault() {
        // No default published → fall back to the first configured gateway (the
        // in-app new-chat picker's own rule: one highlighted row the person can
        // change beats a picker highlighting nothing).
        XCTAssertEqual(
            ShareTargetFilter.preselectedRoute(
                snapshotDecoded: true,
                defaultGatewayRef: nil,
                configuredGatewayRefs: ["openclaw", "hermes"]
            ),
            .gateway(ref: "openclaw")
        )
        // A default naming a gateway this snapshot does not carry is the same
        // state as none at all — never a highlight on a row that isn't there.
        XCTAssertEqual(
            ShareTargetFilter.preselectedRoute(
                snapshotDecoded: true,
                defaultGatewayRef: "custom_22222222-2222-2222-2222-222222222222",
                configuredGatewayRefs: ["openclaw", "hermes"]
            ),
            .gateway(ref: "openclaw")
        )
    }

    func testADecodedEmptyRosterPreselectsNothing() {
        // Decoded and genuinely empty: there is nothing to send to, so nothing is
        // highlighted and the Send button stays disabled.
        XCTAssertEqual(
            ShareTargetFilter.preselectedRoute(
                snapshotDecoded: true,
                defaultGatewayRef: nil,
                configuredGatewayRefs: []
            ),
            .none
        )
        // A stale pointer cannot conjure a row out of an empty roster either.
        XCTAssertEqual(
            ShareTargetFilter.preselectedRoute(
                snapshotDecoded: true,
                defaultGatewayRef: "openclaw",
                configuredGatewayRefs: []
            ),
            .none
        )
    }

    // MARK: - preselectedTarget (the snapshot → opening pick adapter)

    func testNoSnapshotYieldsNoOpeningPick() {
        // The roster is UNKNOWN, not empty. The only row on offer is the legacy
        // nil-ref route, which the drainer may resolve to the app's live
        // quick-capture conversation — a place the sheet never named.
        XCTAssertNil(ShareTargetFilter.preselectedTarget(snapshot: nil))
    }

    func testADecodedEmptyRosterYieldsNoOpeningPick() {
        XCTAssertNil(ShareTargetFilter.preselectedTarget(snapshot: snapshot()))
    }

    func testTheOpeningPickSkipsAnUnconfiguredGateway() {
        // An unconfigured gateway has no URL or token, so a send to it is one the
        // drainer would refuse — it can never be what the sheet opens on, even
        // when it is listed first.
        let picked = ShareTargetFilter.preselectedTarget(
            snapshot: snapshot(gateways: [
                gateway("OpenClaw", ref: "openclaw", configured: false),
                gateway("Hermes", ref: "hermes"),
            ])
        )
        XCTAssertEqual(picked, .newConversation(gatewayRef: "hermes"))
    }

    func testTheOpeningPickIsTheAppsDefaultEvenWhenItIsNotFirst() {
        let picked = ShareTargetFilter.preselectedTarget(
            snapshot: snapshot(
                gateways: [gateway("OpenClaw", ref: "openclaw"), gateway("Hermes", ref: "hermes")],
                defaultGatewayRef: "hermes"
            )
        )
        XCTAssertEqual(picked, .newConversation(gatewayRef: "hermes"))
    }

    func testAnUnconfiguredPublishedDefaultFallsBackToTheFirstConfiguredGateway() {
        // The default is LISTED, so a rule that looked it up before applying the
        // configured filter would highlight it — and highlight a gateway the
        // drainer would refuse to send to. Only configured refs are candidates,
        // the published default included.
        let picked = ShareTargetFilter.preselectedTarget(
            snapshot: snapshot(
                gateways: [gateway("OpenClaw", ref: "openclaw", configured: false),
                           gateway("Hermes", ref: "hermes")],
                defaultGatewayRef: "openclaw"
            )
        )
        XCTAssertEqual(picked, .newConversation(gatewayRef: "hermes"))
        XCTAssertNotEqual(picked, .newConversation(gatewayRef: "openclaw"))
    }

    func testAnUnconfiguredPublishedDefaultWithNothingConfiguredYieldsNoOpeningPick() {
        // The same rule with no configured gateway to fall back to: a listed but
        // unusable default is not a pick, so the sheet opens on nothing and Send
        // stays disabled.
        XCTAssertNil(
            ShareTargetFilter.preselectedTarget(
                snapshot: snapshot(
                    gateways: [gateway("OpenClaw", ref: "openclaw", configured: false)],
                    defaultGatewayRef: "openclaw"
                )
            )
        )
    }

    func testAnUnlistedDefaultFallsBackToTheFirstConfiguredGateway() {
        // A stale pointer cannot highlight a row that isn't there.
        let picked = ShareTargetFilter.preselectedTarget(
            snapshot: snapshot(
                gateways: [gateway("OpenClaw", ref: "openclaw"), gateway("Hermes", ref: "hermes")],
                defaultGatewayRef: "custom_22222222-2222-2222-2222-222222222222"
            )
        )
        XCTAssertEqual(picked, .newConversation(gatewayRef: "openclaw"))
    }

    func testTheOpeningPickCarriesTheRefItNames() {
        // The ref is what the drainer binds the new conversation to, so the
        // adapter has to carry it through rather than merely report that
        // something is highlighted.
        let ref = "custom_11111111-1111-1111-1111-111111111111"
        let picked = ShareTargetFilter.preselectedTarget(
            snapshot: snapshot(gateways: [gateway("Home Mac mini", ref: ref)])
        )
        XCTAssertEqual(picked, .newConversation(gatewayRef: ref))
        XCTAssertNotEqual(picked, .newConversation(gatewayRef: nil))
    }

    // MARK: - sendLabel (what the Send button names)

    func testSendLabelIsSendNowWithNoPick() {
        XCTAssertEqual(
            ShareTargetFilter.sendLabel(for: nil, snapshot: snapshot(gateways: [gateway("OpenClaw")])),
            .sendNow
        )
    }

    func testSendLabelIsSendNowForTheLegacyNilRef() {
        // The nil-ref route is the drainer's to resolve, so the button cannot name
        // where it lands.
        XCTAssertEqual(
            ShareTargetFilter.sendLabel(
                for: .newConversation(gatewayRef: nil),
                snapshot: snapshot(gateways: [gateway("OpenClaw")])
            ),
            .sendNow
        )
    }

    func testSendLabelNamesAListedGateway() {
        XCTAssertEqual(
            ShareTargetFilter.sendLabel(
                for: .newConversation(gatewayRef: "hermes"),
                snapshot: snapshot(gateways: [gateway("OpenClaw", ref: "openclaw"),
                                              gateway("Hermes", ref: "hermes")])
            ),
            .sendTo(name: "Hermes")
        )
    }

    func testSendLabelFallsBackForAGatewayWithNoDisplayName() {
        // A tolerant decode default-fills `displayName` to "", and "Send to " is
        // worse than "Send now".
        XCTAssertEqual(
            ShareTargetFilter.sendLabel(
                for: .newConversation(gatewayRef: "hermes"),
                snapshot: snapshot(gateways: [gateway("", ref: "hermes")])
            ),
            .sendNow
        )
    }

    func testSendLabelFallsBackForAnUnlistedGatewayRef() {
        // A ref the snapshot does not carry is one this sheet cannot describe.
        XCTAssertEqual(
            ShareTargetFilter.sendLabel(
                for: .newConversation(gatewayRef: "custom_33333333-3333-3333-3333-333333333333"),
                snapshot: snapshot(gateways: [gateway("OpenClaw", ref: "openclaw")])
            ),
            .sendNow
        )
    }

    func testSendLabelNamesAListedRecentChat() {
        let id = UUID()
        XCTAssertEqual(
            ShareTargetFilter.sendLabel(
                for: .existing(conversationID: id, backendRef: "hermes"),
                snapshot: snapshot(recents: [recent("Trip planning", id: id)])
            ),
            .sendTo(name: "Trip planning")
        )
    }

    func testSendLabelReportsAnUntitledListedRecentChat() {
        // The view owns the "Conversation" fallback string; this rule only says
        // WHICH fallback applies, because the filter cannot reach a localized
        // string.
        let id = UUID()
        XCTAssertEqual(
            ShareTargetFilter.sendLabel(
                for: .existing(conversationID: id, backendRef: "hermes"),
                snapshot: snapshot(recents: [recent("", id: id)])
            ),
            .sendToUntitledChat
        )
    }

    func testSendLabelFallsBackForAnUnlistedRecentChat() {
        // A conversation deleted between snapshot and share still routes (the
        // manifest carries its backendRef), but the button will not name a row
        // that is no longer there.
        XCTAssertEqual(
            ShareTargetFilter.sendLabel(
                for: .existing(conversationID: UUID(), backendRef: "hermes"),
                snapshot: snapshot(recents: [recent("Trip planning")])
            ),
            .sendNow
        )
    }

    // MARK: - Byte-identical mirror guard (iOS appex ↔ macOS appex)

    // `ShareTargetFilter.swift` physically lives in BOTH appex folders (each appex
    // is a separate compilation module; only the macOS copy is the one pulled into
    // this test bundle). The matching rules MUST stay identical so the "Send to"
    // picker behaves the same on both platforms. This reads both source files off
    // disk and asserts they're byte-identical from the first `import Foundation`
    // onward — only the leading `// …` header block is allowed to differ. Anchored
    // on this test file's own on-disk location (`#filePath`) → sibling source dirs.
    func testAppexMirrorsAreByteIdenticalBelowHeader() throws {
        let testDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let projectDir = testDir.deletingLastPathComponent()  // …/Conduck (the Xcode-project subdir)
        let iosMirrorURL = projectDir
            .appendingPathComponent("ConduckShareExtension/ShareTargetFilter.swift")
        let macMirrorURL = projectDir
            .appendingPathComponent("ConduckShareExtensionMac/ShareTargetFilter.swift")

        let iosMirror = try String(contentsOf: iosMirrorURL, encoding: .utf8)
        let macMirror = try String(contentsOf: macMirrorURL, encoding: .utf8)

        XCTAssertEqual(bodyBelowHeader(of: macMirror), bodyBelowHeader(of: iosMirror),
                       "iOS appex ShareTargetFilter has drifted from the macOS copy below the header — the two pickers' search/threshold rules are out of sync")
    }

    /// The logic body — everything from the first `import Foundation` line onward.
    /// Strips each file's leading comment header (the ONLY part allowed to differ
    /// between the two appex mirrors) so the remainder can be compared verbatim.
    private func bodyBelowHeader(of source: String) -> Substring {
        guard let range = source.range(of: "import Foundation") else { return source[...] }
        return source[range.lowerBound...]
    }
}
