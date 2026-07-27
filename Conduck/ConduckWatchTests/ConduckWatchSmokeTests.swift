// SPDX-License-Identifier: Apache-2.0

// Conduck — watchOS unit-test target smoke test.
// Validates the ConduckWatchTests target compiles + runs on the watchOS
// Simulator. Real Watch-only contract tests live alongside this file.
import XCTest
@testable import ConduckWatch_Watch_App

final class ConduckWatchSmokeTests: XCTestCase {
    func testWatchTestTargetExecutes() {
        XCTAssertEqual(2 + 2, 4, "watchOS unit-test target is wired and executing on the watch simulator.")
    }
}

/// Watch-scoped official-identity drift guard — the wrist-side counterpart of
/// ConduckTests/OfficialIdentityLockTests, pinning the persistent identifiers
/// no iOS-hosted test can reach. Skips under a non-official (community) build
/// identity, same as the iOS lock suite.
final class OfficialIdentityWatchLockTests: XCTestCase {
    private static let officialNamespace = "ai.gigaduck.agentrelay"

    private func skipUnlessOfficial() throws {
        try XCTSkipUnless(Constants.identityNamespace == Self.officialNamespace,
                          "Official-identity lock — not applicable under a non-official (community) build identity")
    }

    /// Background-URLSession identifiers must never change across app updates —
    /// in-flight wrist uploads from the previous version would orphan.
    func testWatchSTTSessionIdentifierIsFrozen() throws {
        try skipUnlessOfficial()
        XCTAssertEqual(WatchAudioUploader.sessionIdentifier, "ai.gigaduck.agentrelay.watch.stt")
    }

    /// The control-widget kind lives in the WIDGET appex (not a valid test
    /// host), so read the built artifact embedded in this test's host app.
    /// The CamelCase bundle-id base is load-bearing: a lowercase namespace
    /// derivation would silently orphan every user-placed control.
    func testWidgetControlKindIsFrozenInEmbeddedAppex() throws {
        try skipUnlessOfficial()
        let plugins = try XCTUnwrap(Bundle.main.builtInPlugInsURL,
                                    "Test host has no PlugIns directory — expected the watch app with its embedded widget appex")
        let appex = try XCTUnwrap(Bundle(url: plugins.appendingPathComponent("ConduckWatchExtension.appex")),
                                  "Widget appex missing from the watch app test host")
        XCTAssertEqual(appex.object(forInfoDictionaryKey: "ConduckControlKind") as? String,
                       "ai.gigaduck.AgentRelay.watch.RecordNoteControl")
    }
}
