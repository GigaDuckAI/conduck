// Conduck
// ShareTargetFilterTests.swift
//
// Pure-logic coverage for `ShareTargetFilter` — the macOS Share Extension
// picker's search/threshold helper (extracted from `ShareView` so it's testable
// without SwiftUI). Asserts the search-visibility boundary (8 → no field, 9 →
// field) and the gateway/recent filters' empty-query passthrough +
// case-insensitive match + no-match → empty contract.
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

    private func gateway(_ name: String, ref: String = "openclaw") -> ShareTargetsSnapshot.Gateway {
        ShareTargetsSnapshot.Gateway(
            ref: ref,
            displayName: name,
            colorHex: "#3A86FF",
            monogram: String(name.prefix(2)).uppercased(),
            configured: true
        )
    }

    private func recent(_ label: String) -> ShareTargetsSnapshot.RecentConversation {
        ShareTargetsSnapshot.RecentConversation(
            id: UUID(),
            label: label,
            backendRef: "hermes",
            lastActivityAt: Date(timeIntervalSince1970: 1_700_000_000)
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
