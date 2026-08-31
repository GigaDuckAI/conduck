// SPDX-License-Identifier: Apache-2.0

// Conduck — watchOS unit-test target smoke test.
// Validates the ConduckWatchTests target compiles + runs on the watchOS
// Simulator. Real Watch-only contract tests live alongside this file.
import XCTest
import CoreData
@testable import ConduckWatch_Watch_App

final class ConduckWatchSmokeTests: XCTestCase {
    func testWatchTestTargetExecutes() {
        XCTAssertEqual(2 + 2, 4, "watchOS unit-test target is wired and executing on the watch simulator.")
    }

    func testWorkboardCaptureNormalizesAndBoundsItsTitle() throws {
        let firstLine = String(repeating: "a", count: 90)
        let capture = try WatchWorkboardCaptureText.prepare("  \(firstLine)\r\nMore detail  ")

        XCTAssertEqual(capture.title, String(repeating: "a", count: 72))
        XCTAssertEqual(capture.objective, "\(firstLine)\nMore detail")
        XCTAssertThrowsError(try WatchWorkboardCaptureText.prepare(" \n "))
    }

    func testWorkboardCaptureRefusesAnOversizedThoughtInsteadOfTruncatingIt() throws {
        let bound = WatchWorkboardCaptureText.maximumObjectiveCharacters
        let atBound = try WatchWorkboardCaptureText.prepare(String(repeating: "a", count: bound))
        XCTAssertEqual(atBound.objective.count, bound)

        XCTAssertThrowsError(
            try WatchWorkboardCaptureText.prepare(String(repeating: "a", count: bound + 1))
        ) { error in
            XCTAssertEqual(error as? WatchWorkboardCaptureError, .thoughtTooLong)
        }
    }

    func testWorkboardCapturePersistsOnlyAnInertBrief() async throws {
        let store = ConversationStore(inMemory: true)
        let capture = WatchWorkboardCapture(
            title: "Prepare launch review",
            objective: "Collect launch risks before deciding what to send."
        )

        let returnedTitle = try await store.createInertWatchWorkboardCapture(capture)
        let context = await store.newReadContext()
        let counts = try await context.perform { [context] in
            func count(_ entityName: String) throws -> Int {
                try context.count(for: NSFetchRequest<NSFetchRequestResult>(entityName: entityName))
            }
            let itemRequest = NSFetchRequest<NSDictionary>(entityName: "WorkItem")
            itemRequest.resultType = .dictionaryResultType
            itemRequest.propertiesToFetch = ["title", "objective", "preferredGatewayRef"]
            return (
                items: try context.fetch(itemRequest),
                dispatches: try count("WorkDispatch"),
                conversations: try count("Conversation"),
                messages: try count("Message")
            )
        }

        XCTAssertEqual(returnedTitle, capture.title)
        XCTAssertEqual(counts.items.count, 1)
        XCTAssertEqual(counts.items.first?["title"] as? String, capture.title)
        XCTAssertEqual(counts.items.first?["objective"] as? String, capture.objective)
        XCTAssertNil(counts.items.first?["preferredGatewayRef"] as? String)
        XCTAssertEqual(counts.dispatches, 0)
        XCTAssertEqual(counts.conversations, 0)
        XCTAssertEqual(counts.messages, 0)
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
